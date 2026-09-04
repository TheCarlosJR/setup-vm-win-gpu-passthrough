"""Ciclo de vida dos recursos dedicados à VM (REQ-VM-RESOURCE-LIFECYCLE, I9.12).

Por que este módulo existe: até I9.12 a etapa 17 tratava reserva estática de
HugePages de 1 GiB no boot como o contrato, e o `--verificar` dela exigia
`HugePages_Total` exatamente igual a `HUGEPAGES_1G`. Medido no host em
03/09/2026, o efeito é 22 GiB de 30,3 GiB fora da RAM comum **com a VM
desligada**, e `MemAvailable` em 4 GiB: as páginas ficam livres para o hugetlb
e inacessíveis para todo o resto.

Uma correção de fato, medida em 03/09/2026 e que vale registrar porque a
intuição comum diz o contrário: reserva feita no boot **é** devolvível em
runtime neste kernel (`CONFIG_CONTIG_ALLOC=y`), e escrever `0` em
`nr_hugepages` devolveu 21,8 GiB sem reiniciar. O que a reserva no boot tem de
irreversível não é a página, é a POLÍTICA: sem mexer nos parâmetros de boot ela
volta a ser feita no próximo boot, esteja a VM ligada ou não. O requisito
inverte esse contrato — recurso dedicado é adquirido para o ciclo da VM e
devolvido ao host quando ela para.

Fronteira (seções 2.2 e 2.4 do PLANO-FINALIZACAO.md): este módulo é PURO. Ele
não lê sysfs, não escreve em lugar nenhum, não executa processo e não conhece
caminho de arquivo. O Bash captura a fotografia do host, entrega como TEXTO, e
aqui só acontece cálculo: planejar, provar pós-condição, diferenciar
fotografias e validar a máquina de estados. Quem adquire e devolve página é o
hook em Bash, que precisa continuar autossuficiente (decisão I9-D8).

Três invariantes que o módulo protege, e que são a razão de cada recusa:

  * **exatidão.** A operação devolve exatamente o delta que ela adquiriu.
    Nunca o pool inteiro: um pool preexistente (deste host, vindo do boot) ou
    de terceiro é baseline a preservar, não sobra a limpar.
  * **sem fallback silencioso.** 1 GiB, 2 MiB, THP e memória normal são modos
    distintos com garantias distintas. Aquisição parcial é FALHA, não
    degradação: o start é recusado e o baseline é restaurado, porque uma VM
    que sobe com metade das páginas prometidas mente sobre o próprio perfil.
  * **fail-closed em toda janela.** Consumidor externo, surplus em jogo, NUMA
    divergente, memória insuficiente, fotografia inconsistente e transição de
    estado inválida recusam a operação em vez de seguir adiante.
"""

from __future__ import annotations

import hashlib
from typing import Any, Mapping

from .errors import DataError
from .protocol import safe_label

KIB_PER_MIB = 1024
MIB_PER_GIB = 1024

# Modos de política, em ordem de preferência decidida em I9.12. A ordem não é
# estética: ela reflete confiabilidade de devolução, não desempenho.
MODE_NORMAL = "normal"
MODE_HUGETLB_2M = "hugetlb-2m"
MODE_HUGETLB_1G = "hugetlb-1g"
MODE_HUGETLB_1G_BOOT = "hugetlb-1g-boot"

MODES = (MODE_NORMAL, MODE_HUGETLB_2M, MODE_HUGETLB_1G, MODE_HUGETLB_1G_BOOT)

# Modos que adquirem e devolvem página em runtime. Fora desta tupla, o ciclo de
# vida não toca no pool: `normal` não usa hugetlb, e `hugetlb-1g-boot` recebe as
# páginas do boot e por definição NÃO as devolve (é o perfil legado opt-in,
# declaradamente não retornável).
RUNTIME_MODES = (MODE_HUGETLB_2M, MODE_HUGETLB_1G)

# Tamanho de página por modo, em kB, como o sysfs nomeia os diretórios
# (`hugepages-2048kB`, `hugepages-1048576kB`).
MODE_PAGE_KB = {
    MODE_HUGETLB_2M: 2048,
    MODE_HUGETLB_1G: 1048576,
    MODE_HUGETLB_1G_BOOT: 1048576,
}

# Estados da operação. O ciclo normal é PREPARED -> ACQUIRED -> VERIFIED ->
# RELEASING -> RELEASED; qualquer falha vai para RECOVERY_REQUIRED, que só sai
# por reconciliação explícita.
STATE_PREPARED = "PREPARED"
STATE_ACQUIRED = "ACQUIRED"
STATE_VERIFIED = "VERIFIED"
STATE_RELEASING = "RELEASING"
STATE_RELEASED = "RELEASED"
STATE_RECOVERY = "RECOVERY_REQUIRED"

STATES = (
    STATE_PREPARED,
    STATE_ACQUIRED,
    STATE_VERIFIED,
    STATE_RELEASING,
    STATE_RELEASED,
    STATE_RECOVERY,
)

# Transições autorizadas. Um dicionário fechado em vez de uma cadeia de `if`:
# a política de estados é dado auditável, e o que não está aqui é recusado.
# "" é o estado inicial (nenhuma operação registrada).
TRANSITIONS: dict[tuple[str, str], str] = {
    ("", "prepare"): STATE_PREPARED,
    (STATE_RELEASED, "prepare"): STATE_PREPARED,
    (STATE_PREPARED, "acquire"): STATE_ACQUIRED,
    (STATE_ACQUIRED, "verify"): STATE_VERIFIED,
    (STATE_VERIFIED, "release_begin"): STATE_RELEASING,
    (STATE_RELEASING, "release_done"): STATE_RELEASED,
    # Uma operação que preparou e ainda não adquiriu pode encerrar sem devolver
    # nada: é o caminho do start recusado antes da janela de aquisição.
    (STATE_PREPARED, "release_done"): STATE_RELEASED,
    # Falha explícita em qualquer ponto, e a reconciliação que tira do buraco.
    (STATE_RECOVERY, "reconcile"): STATE_RELEASED,
}

# `fail` é aceito a partir de qualquer estado real e sempre leva a
# RECOVERY_REQUIRED. Fica fora do dicionário porque é a única transição
# universal, e escrevê-la seis vezes esconderia essa propriedade.
EVENT_FAIL = "fail"

EVENTS = (
    "prepare",
    "acquire",
    "verify",
    "release_begin",
    "release_done",
    "reconcile",
    EVENT_FAIL,
)


# --- Fotografia do host -------------------------------------------------------
# O Bash entrega uma fotografia em TEXTO, um fato por linha, campos separados
# por TAB. Formato fechado, validado aqui:
#
#   pool<TAB><kb><TAB>nr|free|resv|surplus|overcommit<TAB><inteiro>
#   node<TAB><id><TAB><kb><TAB>nr|free<TAB><inteiro>
#   meminfo<TAB><campo><TAB><inteiro em kB>
#   thp<TAB>enabled|defrag<TAB><texto>
#   boot_id<TAB><texto>
#   nodes<TAB><inteiro>
#
# Linha vazia e linha iniciada por '#' são ignoradas. Tipo de registro
# desconhecido REPROVA a fotografia inteira, em vez de ser pulado: uma
# fotografia parcialmente entendida levaria a decidir sobre memória do host com
# dado que ninguém validou.

_POOL_FIELDS = ("nr", "free", "resv", "surplus", "overcommit")
_NODE_FIELDS = ("nr", "free")
_THP_FIELDS = ("enabled", "defrag")
_MEMINFO_MAX_KB = 1 << 40


def _integer(text: str, campo: str, minimo: int = 0, maximo: int = 1 << 32) -> int:
    """Inteiro canônico ASCII sem sinal.

    `isdigit()` sozinho não serve: `'²'.isdigit()` é True e `int('²')` levanta
    `ValueError`, que não é `DataError` e escaparia sem virar status tipado; e
    `'٢'` (dígito indo-arábico) seria aceito como 2, o que não é "canônico".
    A exigência de ASCII fecha os dois lados.

    `campo` é constante deste módulo, não dado do host, e por isso NÃO passa
    por `safe_label`: a expressão dele recusa espaço, e rótulos como "pool nr"
    sairiam redigidos, deixando quatro erros distintos com texto idêntico.
    """
    if not text or text.strip() != text:
        raise DataError("Valor de %s não é inteiro canônico." % campo)
    if not (text.isascii() and text.isdigit()):
        raise DataError("Valor de %s não é inteiro sem sinal." % campo)
    valor = int(text)
    if valor < minimo or valor > maximo:
        raise DataError(
            "Valor de %s fora da faixa %d..%d." % (campo, minimo, maximo)
        )
    return valor


def parse_snapshot(text: str) -> dict[str, Any]:
    """Interpreta a fotografia do host. Fail-closed em tudo que não reconhece."""
    if not isinstance(text, str):
        raise DataError("Fotografia de recursos precisa ser texto.")
    pools: dict[int, dict[str, int]] = {}
    nodes: dict[int, dict[int, dict[str, int]]] = {}
    meminfo: dict[str, int] = {}
    thp: dict[str, str] = {}
    boot_id = ""
    node_count = 0
    numero = 0
    for linha in text.split("\n"):
        numero += 1
        if linha == "" or linha.startswith("#"):
            continue
        if "\r" in linha:
            raise DataError("Linha %d da fotografia tem CR." % numero)
        campos = linha.split("\t")
        tipo = campos[0]
        if tipo == "pool":
            if len(campos) != 4:
                raise DataError("Linha %d: registro 'pool' precisa de 4 campos." % numero)
            kb = _integer(campos[1], "pool tamanho", 1)
            nome = campos[2]
            if nome not in _POOL_FIELDS:
                raise DataError(
                    "Linha %d: campo de pool desconhecido %s." % (numero, safe_label(nome))
                )
            pools.setdefault(kb, {})[nome] = _integer(campos[3], "pool %s" % nome)
        elif tipo == "node":
            if len(campos) != 5:
                raise DataError("Linha %d: registro 'node' precisa de 5 campos." % numero)
            node = _integer(campos[1], "node id", 0, 4095)
            kb = _integer(campos[2], "node tamanho", 1)
            nome = campos[3]
            if nome not in _NODE_FIELDS:
                raise DataError(
                    "Linha %d: campo de node desconhecido %s." % (numero, safe_label(nome))
                )
            nodes.setdefault(node, {}).setdefault(kb, {})[nome] = _integer(
                campos[4], "node %s" % nome
            )
        elif tipo == "meminfo":
            if len(campos) != 3:
                raise DataError("Linha %d: registro 'meminfo' precisa de 3 campos." % numero)
            campo = campos[1]
            if (
                not campo
                or len(campo) > 64
                or not all((c.isascii() and c.isalnum()) or c in "_()" for c in campo)
            ):
                raise DataError("Linha %d: campo de meminfo inválido." % numero)
            meminfo[campo] = _integer(campos[2], "meminfo %s" % campo, 0, _MEMINFO_MAX_KB)
        elif tipo == "thp":
            if len(campos) != 3:
                raise DataError("Linha %d: registro 'thp' precisa de 3 campos." % numero)
            if campos[1] not in _THP_FIELDS:
                raise DataError("Linha %d: campo de THP desconhecido." % numero)
            if len(campos[2]) > 128:
                raise DataError("Linha %d: valor de THP longo demais." % numero)
            thp[campos[1]] = campos[2]
        elif tipo == "boot_id":
            if len(campos) != 2:
                raise DataError("Linha %d: registro 'boot_id' precisa de 2 campos." % numero)
            boot_id = campos[1]
            if not boot_id or len(boot_id) > 128:
                raise DataError("Linha %d: boot_id vazio ou longo demais." % numero)
        elif tipo == "nodes":
            if len(campos) != 2:
                raise DataError("Linha %d: registro 'nodes' precisa de 2 campos." % numero)
            node_count = _integer(campos[1], "nodes", 1, 4096)
        else:
            raise DataError(
                "Linha %d: registro desconhecido %s na fotografia." % (numero, safe_label(tipo))
            )

    for kb, campos_pool in pools.items():
        faltando = [c for c in ("nr", "free", "resv", "surplus") if c not in campos_pool]
        if faltando:
            raise DataError(
                "Pool de %d kB sem os campos %s." % (kb, ", ".join(faltando))
            )
        # Coerência interna: livre nunca excede o total, e reservado tampouco.
        # Sem esta checagem, uma fotografia truncada viraria plano aritmético
        # plausível sobre estado impossível.
        if campos_pool["free"] > campos_pool["nr"] + campos_pool.get("surplus", 0):
            raise DataError(
                "Pool de %d kB tem free maior que nr mais surplus." % kb
            )
        if campos_pool["resv"] > campos_pool["nr"] + campos_pool.get("surplus", 0):
            raise DataError("Pool de %d kB tem resv maior que nr mais surplus." % kb)

    if node_count == 0:
        node_count = len(nodes) or 1
    if nodes and len(nodes) != node_count:
        raise DataError(
            "A fotografia declara %d nós NUMA e traz %d." % (node_count, len(nodes))
        )

    return {
        "pools": pools,
        "nodes": nodes,
        "meminfo": meminfo,
        "thp": thp,
        "boot_id": boot_id,
        "node_count": node_count,
    }


def fingerprint(snapshot: Mapping[str, Any]) -> str:
    """Identidade da MÁQUINA, não do estado do pool.

    Entram tamanho de página disponível, número de nós NUMA e RAM total; não
    entram `nr`/`free`/`resv`/`surplus`, que mudam a cada aquisição. É isso que
    permite comparar a fotografia da devolução com a do start e detectar
    "máquina diferente" sem acusar "pool mudou", que é o esperado.
    """
    pools = snapshot.get("pools") or {}
    meminfo = snapshot.get("meminfo") or {}
    partes = [
        "nodes=%d" % int(snapshot.get("node_count") or 0),
        "pools=%s" % ",".join(str(kb) for kb in sorted(pools)),
        "memtotal=%d" % int(meminfo.get("MemTotal", 0)),
    ]
    return hashlib.sha256("\n".join(partes).encode("utf-8")).hexdigest()


# --- Plano de aquisição -------------------------------------------------------


def _pool(snapshot: Mapping[str, Any], kb: int) -> dict[str, int] | None:
    return (snapshot.get("pools") or {}).get(kb)


def _pages_needed(vm_ram_mib: int, page_kb: int) -> tuple[int, str]:
    """Páginas necessárias, exigindo múltiplo exato do tamanho de página.

    Arredondar para cima daria à VM mais memória do que a configuração diz, e
    para baixo daria menos: as duas mentem sobre o plano. A etapa é quem
    negocia o valor com o operador; aqui a divisão inexata é erro.
    """
    page_mib = page_kb // KIB_PER_MIB
    if page_mib <= 0:
        return 0, "Tamanho de página inválido: %d kB." % page_kb
    if vm_ram_mib % page_mib != 0:
        return 0, (
            "VM_RAM_MB=%d não é múltiplo de %d MiB (tamanho da página)."
            % (vm_ram_mib, page_mib)
        )
    return vm_ram_mib // page_mib, ""


def _plan_vazio(mode: str) -> dict:
    # O conjunto de chaves é o MESMO do aceite. Resposta que muda de forma
    # conforme o veredicto obriga o consumidor a ler chave que pode não existir,
    # e sob o canal de pares isso vira string vazia silenciosa.
    dados: dict[str, Any] = {
        "valid": 1,
        "error": "",
        "mode": mode,
        "runtime": 0,
        "returnable": 0,
        "page_kb": 0,
        "pages_needed": 0,
        "baseline_nr": 0,
        "baseline_free": 0,
        "baseline_resv": 0,
        "baseline_surplus": 0,
        "acquire_delta": 0,
        "target_nr": 0,
        "node_count": 0,
        "fingerprint": "",
        # `transient` diz se a recusa depende do estado do pool NESTE instante.
        # Recusa transitória (consumidor externo, reserva, surplus, memória
        # disponível) pode desaparecer sozinha e deve ser reavaliada no start.
        # Recusa estrutural (modo, aritmética de página, ausência do pool,
        # NUMA) não muda por esperar, e por isso precisa BLOQUEAR o start em
        # vez de ser reavaliada — quem a reavaliaria é o hook, e ele não tem
        # como comprovar distribuição por nó NUMA sozinho (decisão I9-D8).
        "transient": 0,
    }
    return dados


def _recusar(dados: dict, motivo: str, transitoria: bool = False) -> dict:
    """Marca a recusa NO dicionário que já existe.

    Remontar o dicionário do zero era o que fazia as recusas posteriores à
    leitura da fotografia devolverem `fingerprint` vazio e `node_count` zero
    com os valores calculados ao alcance.
    """
    dados["valid"] = 0
    dados["error"] = motivo
    dados["transient"] = 1 if transitoria else 0
    return dados


def plan(payload: Mapping[str, Any]) -> dict:
    """Plano de aquisição para o start da VM.

    Devolve sempre o mesmo conjunto de campos, com `valid=0` e `error` quando
    recusa. Recusa é resultado legítimo e esperado: o chamador em Bash aborta o
    start com o motivo, e é isso que impede a VM de subir com meio perfil.
    """
    mode = _text(payload, "mode")
    if mode not in MODES:
        return _recusar(
            _plan_vazio(""),
            "Modo de memória desconhecido: %s. Aceitos: %s."
            % (safe_label(mode or "vazio"), ", ".join(MODES)),
        )

    runtime = 1 if mode in RUNTIME_MODES else 0
    # `returnable` é o que o requisito mede: o modo devolve o recurso ao host
    # quando a VM para? `normal` devolve porque nunca tirou; os modos de runtime
    # devolvem por construção; `hugetlb-1g-boot` não devolve, e mentir sobre
    # isso seria o pior resultado possível deste módulo.
    returnable = 0 if mode == MODE_HUGETLB_1G_BOOT else 1

    base = _plan_vazio(mode)
    base["runtime"] = runtime
    base["returnable"] = returnable
    base["page_kb"] = MODE_PAGE_KB.get(mode, 0)

    if mode == MODE_NORMAL:
        # Nada a planejar: a VM usa memória comum e o kernel devolve tudo quando
        # o QEMU termina. É o baseline do requisito, e não é caso degenerado.
        return base

    snapshot = parse_snapshot(_text(payload, "snapshot"))
    base["node_count"] = int(snapshot["node_count"])
    base["fingerprint"] = fingerprint(snapshot)
    page_kb = MODE_PAGE_KB[mode]
    vm_ram_mib = _require_integer(payload, "vm_ram_mib", 1, 1 << 30)

    pool = _pool(snapshot, page_kb)
    if pool is None:
        return _recusar(
            base,
            "O host não expõe pool de %d kB; o modo %s não está disponível aqui."
            % (page_kb, mode),
        )

    base.update(
        {
            "baseline_nr": pool["nr"],
            "baseline_free": pool["free"],
            "baseline_resv": pool["resv"],
            "baseline_surplus": pool["surplus"],
        }
    )

    pages, erro = _pages_needed(vm_ram_mib, page_kb)
    if erro:
        return _recusar(base, erro)
    base["pages_needed"] = pages

    if mode == MODE_HUGETLB_1G_BOOT:
        # Perfil legado: as páginas vêm do boot e o ciclo de vida não adquire
        # nem devolve nada. O que ele PODE fazer é provar que a reserva estática
        # cobre a necessidade, e recusar o start se não cobrir.
        if pool["nr"] < pages:
            return _recusar(
                base,
                "Reserva estática de %d páginas de %d kB é menor que as %d exigidas."
                % (pool["nr"], page_kb, pages),
            )
        return base

    # --- daqui para baixo, modos de runtime -----------------------------------
    # Consumidor externo: alguém já usa páginas deste pool. O requisito manda
    # abortar, e o motivo é que não há como distinguir "nossa" de "dele" na
    # devolução; o risco de tirar página de outra VM é inaceitável.
    em_uso = pool["nr"] - pool["free"]
    if em_uso > 0:
        return _recusar(
            base,
            "Pool de %d kB tem %d página(s) em uso por outro consumidor; start recusado."
            % (page_kb, em_uso),
            transitoria=True,
        )
    if pool["resv"] > 0:
        return _recusar(
            base,
            "Pool de %d kB tem %d página(s) reservada(s) por outro consumidor."
            % (page_kb, pool["resv"]),
            transitoria=True,
        )
    if pool["surplus"] > 0:
        # Surplus é página de overcommit, criada e destruída pelo kernel sob
        # demanda. Com surplus em jogo, `nr` deixa de descrever o que a operação
        # adquiriu, e a exatidão da devolução fica indemonstrável.
        return _recusar(
            base,
            "Pool de %d kB tem %d página(s) de surplus; a exatidão da devolução"
            " não pode ser provada." % (page_kb, pool["surplus"]),
            transitoria=True,
        )

    # Pool preexistente e totalmente livre (é o caso deste host, com 22 páginas
    # vindas do boot) é BASELINE a preservar. A operação só adquire o delta que
    # falta, e na devolução nunca desce abaixo dele.
    delta = pages - pool["nr"]
    if delta < 0:
        delta = 0
    base["acquire_delta"] = delta
    base["target_nr"] = pool["nr"] + delta

    if delta > 0:
        faltando = _memoria_insuficiente(snapshot, delta, page_kb)
        if faltando:
            return _recusar(base, faltando, transitoria=True)
        numa = _numa_incompativel(snapshot, delta, page_kb)
        if numa:
            return _recusar(base, numa)
    return base


def _memoria_insuficiente(
    snapshot: Mapping[str, Any], delta: int, page_kb: int
) -> str:
    """Recusa antes de tentar, quando a conta já não fecha.

    Não substitui a prova de pós-condição: o kernel pode falhar por
    fragmentação mesmo com `MemAvailable` suficiente, sobretudo em página de
    1 GiB, que exige contiguidade física. Serve para recusar cedo, com
    diagnóstico melhor do que "alocação parcial".
    """
    meminfo = snapshot.get("meminfo") or {}
    disponivel = meminfo.get("MemAvailable")
    if disponivel is None:
        return ""
    preciso_kb = delta * page_kb
    if disponivel < preciso_kb:
        return (
            "MemAvailable=%d kB não cobre %d página(s) de %d kB (%d kB)."
            % (disponivel, delta, page_kb, preciso_kb)
        )
    return ""


def _numa_incompativel(
    snapshot: Mapping[str, Any], delta: int, page_kb: int
) -> str:
    """Com mais de um nó, a distribuição precisa ser declarada e possível.

    Em host de um nó a checagem é trivialmente satisfeita, e é o único caso
    qualificado hoje. Com dois ou mais nós, o kernel distribui a escrita em
    `nr_hugepages` entre os nós sem garantia de simetria, e uma VM pinada a um
    nó pode receber página de outro; o requisito chama isso de NUMA divergente e
    manda recusar em vez de prometer o que não se controla.
    """
    node_count = int(snapshot.get("node_count") or 1)
    if node_count <= 1:
        return ""
    nodes = snapshot.get("nodes") or {}
    if not nodes:
        return (
            "O host declara %d nós NUMA e a fotografia não traz os contadores"
            " por nó; distribuição não pode ser comprovada." % node_count
        )
    if delta % node_count != 0:
        return (
            "Delta de %d página(s) não divide igualmente entre %d nós NUMA."
            % (delta, node_count)
        )
    for node in sorted(nodes):
        if page_kb not in nodes[node]:
            return (
                "Nó NUMA %d não expõe pool de %d kB; distribuição não pode ser"
                " comprovada." % (node, page_kb)
            )
    return ""


# --- Prova de pós-condição ----------------------------------------------------


def verify(payload: Mapping[str, Any]) -> dict:
    """Prova a pós-condição de uma janela, sem confiar no código de retorno.

    `phase=acquire` exige que o pool tenha crescido exatamente o delta e que as
    páginas novas estejam livres para o QEMU tomar. `phase=release` exige que o
    pool tenha voltado ao baseline em `nr`, `free`, `resv` e `surplus`. As duas
    exigem que a máquina seja a mesma, pelo fingerprint.
    """
    phase = _text(payload, "phase")
    if phase not in ("acquire", "release"):
        raise DataError(
            "Fase desconhecida para prova: %s." % safe_label(phase or "vazio")
        )
    antes = parse_snapshot(_text(payload, "before"))
    depois = parse_snapshot(_text(payload, "after"))
    page_kb = _require_integer(payload, "page_kb", 1, 1 << 30)
    delta = _require_integer(payload, "delta", 0, 1 << 20)

    dados: dict[str, Any] = {
        "valid": 1,
        "error": "",
        "phase": phase,
        "page_kb": page_kb,
        "delta": delta,
        "before_nr": 0,
        "after_nr": 0,
        "before_free": 0,
        "after_free": 0,
        "machine_changed": 0,
        # Declarado nas duas fases para a resposta ter forma única: as recusas
        # precoces (máquina mudou, pool ausente) acontecem antes de a fase de
        # devolução ler o baseline, e sem isto a mesma fase devolvia 10 ou 11
        # chaves conforme o motivo.
        "baseline_nr": 0,
    }

    if fingerprint(antes) != fingerprint(depois):
        dados["valid"] = 0
        dados["machine_changed"] = 1
        dados["error"] = (
            "A identidade da máquina mudou entre as duas fotografias; nada pode"
            " ser provado sobre o pool."
        )
        return dados

    pool_antes = _pool(antes, page_kb)
    pool_depois = _pool(depois, page_kb)
    if pool_antes is None or pool_depois is None:
        dados["valid"] = 0
        dados["error"] = "Pool de %d kB ausente em uma das fotografias." % page_kb
        return dados

    dados.update(
        {
            "before_nr": pool_antes["nr"],
            "after_nr": pool_depois["nr"],
            "before_free": pool_antes["free"],
            "after_free": pool_depois["free"],
        }
    )

    if phase == "acquire":
        esperado = pool_antes["nr"] + delta
        if pool_depois["nr"] != esperado:
            dados["valid"] = 0
            dados["error"] = (
                "Aquisição parcial ou excedente: nr=%d, esperado %d (baseline %d"
                " mais delta %d)."
                % (pool_depois["nr"], esperado, pool_antes["nr"], delta)
            )
            return dados
        if pool_depois["free"] < pool_antes["free"] + delta:
            dados["valid"] = 0
            dados["error"] = (
                "As %d página(s) adquiridas não estão livres: free=%d, esperado"
                " ao menos %d." % (delta, pool_depois["free"], pool_antes["free"] + delta)
            )
            return dados
        if pool_depois["surplus"] != pool_antes["surplus"]:
            dados["valid"] = 0
            dados["error"] = (
                "Surplus mudou de %d para %d durante a aquisição; o pool não é"
                " exato." % (pool_antes["surplus"], pool_depois["surplus"])
            )
            return dados
        return dados

    # phase == "release": o baseline é o de ANTES da aquisição, e é ele que a
    # fotografia de depois tem de reproduzir campo a campo.
    baseline_nr = _require_integer(payload, "baseline_nr", 0, 1 << 20)
    baseline_free = _require_integer(payload, "baseline_free", 0, 1 << 20)
    baseline_resv = _require_integer(payload, "baseline_resv", 0, 1 << 20)
    baseline_surplus = _require_integer(payload, "baseline_surplus", 0, 1 << 20)
    dados["baseline_nr"] = baseline_nr
    esperados = (
        ("nr", pool_depois["nr"], baseline_nr),
        ("free", pool_depois["free"], baseline_free),
        ("resv", pool_depois["resv"], baseline_resv),
        ("surplus", pool_depois["surplus"], baseline_surplus),
    )
    divergentes = ["%s=%d (esperado %d)" % (n, a, e) for n, a, e in esperados if a != e]
    if divergentes:
        dados["valid"] = 0
        dados["error"] = (
            "A devolução não reproduziu o baseline do pool de %d kB: %s."
            % (page_kb, "; ".join(divergentes))
        )
        return dados
    return dados


def plan_release(payload: Mapping[str, Any]) -> dict:
    """Quanto devolver, e as três recusas que impedem devolver o que não é nosso."""
    delta = _require_integer(payload, "delta", 0, 1 << 20)
    baseline_nr = _require_integer(payload, "baseline_nr", 0, 1 << 20)
    page_kb = _require_integer(payload, "page_kb", 1, 1 << 30)
    snapshot = parse_snapshot(_text(payload, "snapshot"))

    dados: dict[str, Any] = {
        "valid": 1,
        "error": "",
        "page_kb": page_kb,
        "delta": delta,
        "baseline_nr": baseline_nr,
        "current_nr": 0,
        "current_free": 0,
        "target_nr": baseline_nr,
    }
    pool = _pool(snapshot, page_kb)
    if pool is None:
        dados["valid"] = 0
        dados["error"] = "Pool de %d kB ausente; devolução não pode ser planejada." % page_kb
        return dados
    dados["current_nr"] = pool["nr"]
    dados["current_free"] = pool["free"]

    if delta == 0:
        # Nada foi adquirido: a devolução correta é não mexer no pool. Escrever
        # `nr_hugepages` "para garantir" zeraria pool de terceiro.
        dados["target_nr"] = pool["nr"]
        return dados
    if pool["nr"] < baseline_nr + delta:
        dados["valid"] = 0
        dados["error"] = (
            "Pool de %d kB tem nr=%d, menor que baseline %d mais delta %d;"
            " alguém mexeu no pool e a devolução exata é impossível."
            % (page_kb, pool["nr"], baseline_nr, delta)
        )
        return dados
    if pool["free"] < delta:
        # Página em uso na hora de devolver significa QEMU vivo ou vazamento. O
        # requisito manda provar domínio desligado e ausência de QEMU residual
        # ANTES desta janela; se chegou aqui, a prova falhou.
        dados["valid"] = 0
        dados["error"] = (
            "Só %d de %d página(s) estão livres no pool de %d kB; ainda há"
            " consumidor ativo." % (pool["free"], delta, page_kb)
        )
        return dados
    dados["target_nr"] = pool["nr"] - delta
    return dados


# --- Máquina de estados -------------------------------------------------------


def state(payload: Mapping[str, Any]) -> dict:
    """Valida uma transição e a reconciliação por boot ID.

    Boot ID é o que torna o requisito robusto a falta de energia: reboot limpa
    o pool inteiro, então um state de outro boot NÃO descreve página alguma
    para devolver. Tratá-lo como pendente faria o boot seguinte tentar reduzir
    `nr_hugepages` de um pool que não é dele.
    """
    atual = _text(payload, "state")
    if atual and atual not in STATES:
        raise DataError("Estado desconhecido: %s." % safe_label(atual))
    evento = _text(payload, "event")
    if evento not in EVENTS:
        raise DataError("Evento desconhecido: %s." % safe_label(evento or "vazio"))

    state_boot = _text(payload, "state_boot_id")
    boot_atual = _text(payload, "boot_id")

    dados: dict[str, Any] = {
        "valid": 1,
        "error": "",
        "state": atual,
        "event": evento,
        "next_state": "",
        "stale_boot": 0,
        "recovery": 0,
    }

    stale = bool(atual) and bool(state_boot) and bool(boot_atual) and state_boot != boot_atual
    if stale:
        dados["stale_boot"] = 1
        # State de outro boot: as páginas dele não existem mais. O único
        # movimento autorizado é reconciliar (descartar e voltar ao baseline
        # declarativo); qualquer outro evento em cima dele é recusado.
        if evento == "reconcile":
            dados["next_state"] = STATE_RELEASED
            return dados
        if evento == "prepare":
            dados["valid"] = 0
            dados["error"] = (
                "Existe state da operação de outro boot (%s) e o boot atual é"
                " %s; reconcilie o baseline antes de iniciar a VM."
                % (safe_label(state_boot), safe_label(boot_atual))
            )
            return dados
        dados["valid"] = 0
        dados["error"] = (
            "Evento '%s' recusado sobre state de outro boot; só 'reconcile' é"
            " autorizado." % evento
        )
        return dados

    if evento == EVENT_FAIL:
        dados["next_state"] = STATE_RECOVERY
        dados["recovery"] = 1
        return dados

    if atual == STATE_RECOVERY and evento != "reconcile":
        dados["valid"] = 0
        dados["recovery"] = 1
        dados["error"] = (
            "A operação está em RECOVERY_REQUIRED; nenhum ciclo novo começa"
            " antes da reconciliação."
        )
        return dados

    proximo = TRANSITIONS.get((atual, evento))
    if proximo is None:
        dados["valid"] = 0
        dados["error"] = "Transição inválida: %s + %s." % (
            atual or "(inicial)",
            evento,
        )
        return dados
    dados["next_state"] = proximo
    return dados


# --- Auxiliares de payload ----------------------------------------------------


def _text(payload: Mapping[str, Any], chave: str) -> str:
    valor = payload.get(chave, "")
    if valor is None:
        return ""
    if not isinstance(valor, str):
        raise DataError("Campo %s precisa ser texto." % chave)
    return valor


def _require_integer(
    payload: Mapping[str, Any], chave: str, minimo: int, maximo: int
) -> int:
    bruto = payload.get(chave, "")
    if isinstance(bruto, bool):
        raise DataError("Campo %s precisa ser inteiro." % chave)
    if isinstance(bruto, int):
        valor = bruto
    else:
        valor = _integer(_text(payload, chave), chave, minimo, maximo)
    if valor < minimo or valor > maximo:
        raise DataError(
            "Campo %s fora da faixa %d..%d." % (chave, minimo, maximo)
        )
    return valor


# --- Comandos da CLI ----------------------------------------------------------


def plan_command(payload: Mapping[str, Any]) -> Mapping[str, Any]:
    return plan(payload)


def verify_command(payload: Mapping[str, Any]) -> Mapping[str, Any]:
    return verify(payload)


def release_plan_command(payload: Mapping[str, Any]) -> Mapping[str, Any]:
    return plan_release(payload)


def state_command(payload: Mapping[str, Any]) -> Mapping[str, Any]:
    return state(payload)
