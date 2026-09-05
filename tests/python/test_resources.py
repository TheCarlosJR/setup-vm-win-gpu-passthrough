"""Ciclo de vida dos recursos dedicados à VM (REQ-VM-RESOURCE-LIFECYCLE, I9.12).

Cada caso afirma o CÓDIGO (`valid`, ou o tipo da exceção) **e** o conteúdo do
diagnóstico. Um módulo que recusa pelo motivo errado é tão ruim quanto um que
aceita: o operador lê o motivo, aborta o start por causa dele e recupera o host
guiado por ele.

Esta suíte nasceu em 03/09/2026 com cinco testes vermelhos de propósito, que
fixavam quatro defeitos reais de `resources.py`. Os quatro foram corrigidos no
mesmo dia e os testes viraram asserção do comportamento certo; o docstring de
cada um guarda qual era o defeito, para que ninguém leia o caso como
paranoia e o remova. São eles:

  * `ParseSnapshotInteiroTests.test_recusa_digito_unicode_nao_decimal`
  * `ParseSnapshotInteiroTests.test_recusa_digito_unicode_decimal_nao_ascii`
  * `ParseSnapshotInteiroTests.test_diagnostico_de_inteiro_nomeia_o_campo`
  * `StateCicloTests.test_estado_inicial_e_nomeado_na_transicao_invalida`
  * `ContratoDeChavesTests.test_plan_tem_as_mesmas_chaves_aceitando_e_recusando`
  * `ContratoDeChavesTests.test_verify_release_tem_as_mesmas_chaves_aceitando_e_recusando`

Um teste `_hoje_` sobreviveu, e é o único: `ContratoDeChavesTests.
test_plan_recusado_hoje_nao_devolve_o_fingerprint_calculado`. Ele fixa
comportamento que já foi RELATADO como defeito e ainda não foi corrigido, pelo
mesmo motivo dos cinco originais: obrigar a correção a ser deliberada.
"""
import ast
import builtins
import unittest
from pathlib import Path

from passthrough_core import resources
from passthrough_core.errors import DataError
from passthrough_core.protocol import REDACTED_LABEL

PAGE_2M = 2048
PAGE_1G = 1048576

# Números do host de desenvolvimento medidos em 03/09/2026 e citados pelo
# requisito: 30,3 GiB de RAM, 22 páginas de 1 GiB vindas do boot e apenas
# 4 GiB de MemAvailable. É o estado que motivou o requisito, e serve de fixture.
MEMTOTAL_KB = 31722704
MEMAVAIL_APERTADA_KB = 4143904
MEMAVAIL_FOLGADA_KB = 20971520


def linhas_pool(kb, nr, free, resv=0, surplus=0, overcommit=None):
    linhas = [
        "pool\t%d\tnr\t%d" % (kb, nr),
        "pool\t%d\tfree\t%d" % (kb, free),
        "pool\t%d\tresv\t%d" % (kb, resv),
        "pool\t%d\tsurplus\t%d" % (kb, surplus),
    ]
    if overcommit is not None:
        linhas.append("pool\t%d\tovercommit\t%d" % (kb, overcommit))
    return linhas


def linhas_node(node, kb, nr, free):
    return [
        "node\t%d\t%d\tnr\t%d" % (node, kb, nr),
        "node\t%d\t%d\tfree\t%d" % (node, kb, free),
    ]


def foto(
    pools=(),
    nodes=(),
    node_count=1,
    memtotal=MEMTOTAL_KB,
    memavailable=MEMAVAIL_FOLGADA_KB,
    boot_id="boot-a",
    thp=True,
):
    """Monta uma fotografia canônica do host, no formato TAB fechado."""
    linhas = ["# fotografia de recursos"]
    if node_count is not None:
        linhas.append("nodes\t%d" % node_count)
    if boot_id is not None:
        linhas.append("boot_id\t%s" % boot_id)
    if memtotal is not None:
        linhas.append("meminfo\tMemTotal\t%d" % memtotal)
    if memavailable is not None:
        linhas.append("meminfo\tMemAvailable\t%d" % memavailable)
    if thp:
        linhas.append("thp\tenabled\t[madvise]")
        linhas.append("thp\tdefrag\tmadvise")
    for pool in pools:
        linhas.extend(linhas_pool(*pool))
    for node in nodes:
        linhas.extend(linhas_node(*node))
    linhas.append("")
    return "\n".join(linhas)


# Host de um nó com os dois pools expostos: 2 MiB zerado e 1 GiB com as 22
# páginas do boot, todas livres. É o baseline de terceiro que o requisito manda
# preservar, e não sobra a limpar.
HOST = foto(pools=((PAGE_2M, 0, 0), (PAGE_1G, 22, 22)))

# O mesmo host, mas com a memória disponível que ele realmente tem hoje.
HOST_APERTADO = foto(
    pools=((PAGE_2M, 0, 0), (PAGE_1G, 22, 22)), memavailable=MEMAVAIL_APERTADA_KB
)

# Só o pool de 1 GiB, para os casos que precisam de pool ausente.
SO_1G = foto(pools=((PAGE_1G, 22, 22),))


def plano(mode, snapshot=HOST, vm_ram_mib=22528, **extra):
    payload = {"mode": mode, "snapshot": snapshot, "vm_ram_mib": vm_ram_mib}
    payload.update(extra)
    return resources.plan(payload)


# --- A. parse_snapshot --------------------------------------------------------


class ParseSnapshotFormatoTests(unittest.TestCase):
    def test_formato_valido_completo(self) -> None:
        texto = "\n".join(
            ["# comentário", ""]
            + ["nodes\t2", "boot_id\tboot-a"]
            + ["meminfo\tMemTotal\t%d" % MEMTOTAL_KB, "meminfo\tMemAvailable\t4143904"]
            + ["thp\tenabled\t[madvise]", "thp\tdefrag\tmadvise"]
            + linhas_pool(PAGE_1G, 22, 20, resv=1, surplus=0, overcommit=3)
            + linhas_pool(PAGE_2M, 0, 0)
            + linhas_node(0, PAGE_1G, 12, 11)
            + linhas_node(1, PAGE_1G, 10, 9)
            + [""]
        )
        dados = resources.parse_snapshot(texto)
        self.assertEqual(
            dados["pools"][PAGE_1G],
            {"nr": 22, "free": 20, "resv": 1, "surplus": 0, "overcommit": 3},
        )
        self.assertEqual(dados["pools"][PAGE_2M], {"nr": 0, "free": 0, "resv": 0, "surplus": 0})
        self.assertEqual(dados["nodes"][0][PAGE_1G], {"nr": 12, "free": 11})
        self.assertEqual(dados["nodes"][1][PAGE_1G], {"nr": 10, "free": 9})
        self.assertEqual(dados["meminfo"], {"MemTotal": MEMTOTAL_KB, "MemAvailable": 4143904})
        self.assertEqual(dados["thp"], {"enabled": "[madvise]", "defrag": "madvise"})
        self.assertEqual(dados["boot_id"], "boot-a")
        self.assertEqual(dados["node_count"], 2)
        self.assertEqual(
            sorted(dados),
            ["boot_id", "meminfo", "node_count", "nodes", "pools", "thp"],
        )

    def test_comentario_e_linha_vazia_sao_ignorados_sem_deslocar_a_numeracao(self) -> None:
        dados = resources.parse_snapshot("# nada\n\n\nnodes\t1\n")
        self.assertEqual(dados["node_count"], 1)
        self.assertEqual(dados["pools"], {})
        # A linha ruim é a quarta do texto e o diagnóstico precisa dizer isso,
        # senão o operador procura o erro na linha errada da fotografia.
        with self.assertRaises(DataError) as capturado:
            resources.parse_snapshot("# nada\n\n\npool\t2048\tnr")
        self.assertIn("Linha 4:", str(capturado.exception))

    def test_fotografia_precisa_ser_texto(self) -> None:
        for valor in (None, 7, b"nodes\t1", ["nodes\t1"]):
            with self.subTest(valor=valor):
                with self.assertRaises(DataError) as capturado:
                    resources.parse_snapshot(valor)
                self.assertIn("precisa ser texto", str(capturado.exception))

    def test_registro_desconhecido_reprova_a_fotografia_inteira(self) -> None:
        texto = "\n".join(["nodes\t1", "cgroup\t/machine.slice\t1"])
        with self.assertRaises(DataError) as capturado:
            resources.parse_snapshot(texto)
        mensagem = str(capturado.exception)
        self.assertIn("Linha 2: registro desconhecido cgroup na fotografia.", mensagem)

    def test_registro_desconhecido_com_texto_hostil_nao_vaza(self) -> None:
        with self.assertRaises(DataError) as capturado:
            resources.parse_snapshot("$(id) /etc/shadow\t1")
        mensagem = str(capturado.exception)
        self.assertIn(REDACTED_LABEL, mensagem)
        self.assertNotIn("shadow", mensagem)

    def test_cr_na_linha_reprova(self) -> None:
        with self.assertRaises(DataError) as capturado:
            resources.parse_snapshot("nodes\t1\r\nboot_id\tboot-a")
        self.assertIn("Linha 1 da fotografia tem CR.", str(capturado.exception))

    def test_cr_isolado_tambem_reprova(self) -> None:
        with self.assertRaises(DataError) as capturado:
            resources.parse_snapshot("\r")
        self.assertIn("tem CR", str(capturado.exception))


class ParseSnapshotContagemDeCamposTests(unittest.TestCase):
    """Cada tipo de registro tem aridade fixa, e o erro precisa nomear o tipo."""

    CASOS = (
        ("pool", "pool\t2048\tnr", "registro 'pool' precisa de 4 campos."),
        ("pool", "pool\t2048\tnr\t1\textra", "registro 'pool' precisa de 4 campos."),
        ("node", "node\t0\t2048\tnr", "registro 'node' precisa de 5 campos."),
        ("node", "node\t0\t2048\tnr\t1\tx", "registro 'node' precisa de 5 campos."),
        ("meminfo", "meminfo\tMemTotal", "registro 'meminfo' precisa de 3 campos."),
        ("meminfo", "meminfo\tMemTotal\t1\t2", "registro 'meminfo' precisa de 3 campos."),
        ("thp", "thp\tenabled", "registro 'thp' precisa de 3 campos."),
        ("thp", "thp\tenabled\ta\tb", "registro 'thp' precisa de 3 campos."),
        ("boot_id", "boot_id", "registro 'boot_id' precisa de 2 campos."),
        ("boot_id", "boot_id\ta\tb", "registro 'boot_id' precisa de 2 campos."),
        ("nodes", "nodes", "registro 'nodes' precisa de 2 campos."),
        ("nodes", "nodes\t1\t2", "registro 'nodes' precisa de 2 campos."),
    )

    def test_aridade_errada_reprova_nomeando_o_registro(self) -> None:
        for tipo, linha, esperado in self.CASOS:
            with self.subTest(tipo=tipo, linha=linha):
                with self.assertRaises(DataError) as capturado:
                    resources.parse_snapshot(linha)
                self.assertIn("Linha 1: " + esperado, str(capturado.exception))

    def test_campo_desconhecido_em_pool_e_node(self) -> None:
        with self.assertRaises(DataError) as capturado:
            resources.parse_snapshot("pool\t2048\tmempolicy\t1")
        self.assertIn(
            "Linha 1: campo de pool desconhecido mempolicy.", str(capturado.exception)
        )
        with self.assertRaises(DataError) as capturado:
            resources.parse_snapshot("node\t0\t2048\tresv\t1")
        self.assertIn(
            "Linha 1: campo de node desconhecido resv.", str(capturado.exception)
        )

    def test_campo_de_thp_desconhecido_e_valor_longo(self) -> None:
        with self.assertRaises(DataError) as capturado:
            resources.parse_snapshot("thp\tshmem_enabled\tnever")
        self.assertIn("Linha 1: campo de THP desconhecido.", str(capturado.exception))
        with self.assertRaises(DataError) as capturado:
            resources.parse_snapshot("thp\tenabled\t%s" % ("x" * 129))
        self.assertIn("Linha 1: valor de THP longo demais.", str(capturado.exception))
        # 128 continua aceito: o limite é fronteira, não aproximação.
        dados = resources.parse_snapshot("thp\tenabled\t%s" % ("x" * 128))
        self.assertEqual(dados["thp"]["enabled"], "x" * 128)

    def test_boot_id_vazio_e_longo_demais(self) -> None:
        for valor in ("", "b" * 129):
            with self.subTest(tamanho=len(valor)):
                with self.assertRaises(DataError) as capturado:
                    resources.parse_snapshot("boot_id\t%s" % valor)
                self.assertIn(
                    "Linha 1: boot_id vazio ou longo demais.", str(capturado.exception)
                )
        dados = resources.parse_snapshot("boot_id\t%s" % ("b" * 128))
        self.assertEqual(dados["boot_id"], "b" * 128)

    def test_campo_de_meminfo_com_caractere_invalido(self) -> None:
        for campo in ("Mem-Total", "Mem Total", "Mem:Total", "", "Mem/Total", "../etc"):
            with self.subTest(campo=campo):
                with self.assertRaises(DataError) as capturado:
                    resources.parse_snapshot("meminfo\t%s\t1" % campo)
                self.assertIn(
                    "Linha 1: campo de meminfo inválido.", str(capturado.exception)
                )

    def test_campo_de_meminfo_valido_aceita_parenteses_e_sublinhado(self) -> None:
        dados = resources.parse_snapshot(
            "meminfo\tHugePages_Total\t22\nmeminfo\tActive(anon)\t7"
        )
        self.assertEqual(dados["meminfo"], {"HugePages_Total": 22, "Active(anon)": 7})


class ParseSnapshotInteiroTests(unittest.TestCase):
    """Inteiro canônico: sem sinal, sem espaço, sem vazio, dentro da faixa."""

    def test_recusa_sinal_espaco_vazio_e_nao_numerico(self) -> None:
        casos = (
            ("pool\t2048\tnr\t-1", "Valor de pool nr não é inteiro sem sinal."),
            ("pool\t2048\tnr\t+1", "Valor de pool nr não é inteiro sem sinal."),
            ("pool\t2048\tnr\tmuitas", "Valor de pool nr não é inteiro sem sinal."),
            ("pool\t2048\tnr\t0x10", "Valor de pool nr não é inteiro sem sinal."),
            ("pool\t2048\tnr\t1.0", "Valor de pool nr não é inteiro sem sinal."),
            ("pool\t2048\tnr\t 1", "Valor de pool nr não é inteiro canônico."),
            ("pool\t2048\tnr\t1 ", "Valor de pool nr não é inteiro canônico."),
            ("pool\t2048\tnr\t", "Valor de pool nr não é inteiro canônico."),
        )
        for linha, esperado in casos:
            with self.subTest(linha=linha):
                with self.assertRaises(DataError) as capturado:
                    resources.parse_snapshot(linha)
                self.assertIn(esperado, str(capturado.exception))

    def test_recusa_fora_de_faixa_em_cada_registro(self) -> None:
        casos = (
            ("pool\t2048\tnr\t4294967297", "pool nr fora da faixa 0..4294967296"),
            ("pool\t0\tnr\t1", "pool tamanho fora da faixa 1..4294967296"),
            ("node\t4096\t2048\tnr\t1", "node id fora da faixa 0..4095"),
            ("node\t0\t0\tnr\t1", "node tamanho fora da faixa 1..4294967296"),
            (
                "meminfo\tMemTotal\t1099511627777",
                "meminfo MemTotal fora da faixa 0..1099511627776",
            ),
            ("nodes\t0", "nodes fora da faixa 1..4096"),
            ("nodes\t4097", "nodes fora da faixa 1..4096"),
        )
        for linha, esperado in casos:
            with self.subTest(linha=linha):
                with self.assertRaises(DataError) as capturado:
                    resources.parse_snapshot(linha)
                self.assertIn(esperado, str(capturado.exception))

    def test_zero_e_limite_superior_sao_aceitos(self) -> None:
        dados = resources.parse_snapshot("\n".join(linhas_pool(PAGE_2M, 0, 0)))
        self.assertEqual(dados["pools"][PAGE_2M]["nr"], 0)
        dados = resources.parse_snapshot("meminfo\tMemTotal\t1099511627776")
        self.assertEqual(dados["meminfo"]["MemTotal"], 1 << 40)

    def test_recusa_digito_unicode_nao_decimal(self) -> None:
        """Foi defeito até 03/09/2026: `'²'.isdigit()` é verdadeiro.

        A validação era só `str.isdigit()` e a conversão `int('²')` levantava
        `ValueError`, que não é `DataError`, não vira status tipado e derrubava
        o processo em vez de recusar a fotografia. Hoje `_integer` exige
        `isascii()` junto, e os dois lados fecham.
        """
        for digito in ("²", "⑤", "½"):
            with self.subTest(digito=digito):
                with self.assertRaises(DataError) as capturado:
                    resources.parse_snapshot("pool\t2048\tnr\t%s" % digito)
                self.assertEqual(
                    str(capturado.exception),
                    "Valor de pool nr não é inteiro sem sinal.",
                )

    def test_recusa_digito_unicode_decimal_nao_ascii(self) -> None:
        """O outro lado do mesmo defeito, que até 03/09/2026 aceitava calado.

        `'٢'` (indo-arábico) e `'１２'` (largura plena) passam por `isdigit()` e
        por `int()`, então viravam 2 e 12 sem ninguém notar. Fotografia com
        contagem de página em dígito não ASCII não é fotografia do Bash: é
        entrada adulterada, e recusar é a única leitura segura.
        """
        for digito, valor in (("٢", 2), ("１２", 12)):
            with self.subTest(digito=digito):
                texto = "\n".join(linhas_pool(PAGE_2M, 0, 0)).replace(
                    "pool\t2048\tnr\t0", "pool\t2048\tnr\t%s" % digito
                )
                self.assertEqual(int(digito), valor)  # o int() aceitaria
                with self.assertRaises(DataError) as capturado:
                    resources.parse_snapshot(texto)
                self.assertEqual(
                    str(capturado.exception),
                    "Valor de pool nr não é inteiro sem sinal.",
                )

    def test_diagnostico_de_inteiro_nomeia_o_campo(self) -> None:
        """Foi defeito até 03/09/2026: o rótulo passava por `safe_label`.

        `_integer` recebe rótulos fixos do próprio módulo (`pool nr`,
        `pool tamanho`, `node id`, `meminfo MemTotal`), e a expressão de
        `safe_label` não aceita espaço: **todo** erro de inteiro em pool, node e
        meminfo saía como "Valor de <valor redigido>", indistinguível entre si.
        Rótulo não é dado do host; redigi-lo só destruía o diagnóstico.
        """
        with self.assertRaises(DataError) as capturado:
            resources.parse_snapshot("pool\t2048\tnr\t-1")
        self.assertEqual(
            str(capturado.exception), "Valor de pool nr não é inteiro sem sinal."
        )

    def test_cada_erro_de_inteiro_nomeia_um_campo_diferente(self) -> None:
        """Quatro registros, quatro rótulos: é o que separa um motivo do outro."""
        esperados = {
            "pool\t2048\tnr\t-1": "Valor de pool nr não é inteiro sem sinal.",
            "pool\tx\tnr\t1": "Valor de pool tamanho não é inteiro sem sinal.",
            "node\ta\t2048\tnr\t1": "Valor de node id não é inteiro sem sinal.",
            "meminfo\tMemTotal\t-1": (
                "Valor de meminfo MemTotal não é inteiro sem sinal."
            ),
        }
        obtidas = set()
        for linha, esperado in esperados.items():
            with self.subTest(linha=linha):
                with self.assertRaises(DataError) as capturado:
                    resources.parse_snapshot(linha)
                self.assertEqual(str(capturado.exception), esperado)
                obtidas.add(str(capturado.exception))
        self.assertEqual(len(obtidas), len(esperados))

    def test_rotulo_com_e_sem_espaco_e_nomeado_igualmente(self) -> None:
        """`nodes` sempre coube em `safe_label`; `pool nr` e `node tamanho` não.

        O caso existe porque essa assimetria foi o sintoma que revelou o defeito
        de 03/09/2026: um único rótulo aparecia e os demais sumiam.
        """
        esperados = {
            "nodes\t0": "Valor de nodes fora da faixa 1..4096.",
            "pool\t2048\tnr\t4294967297": (
                "Valor de pool nr fora da faixa 0..4294967296."
            ),
            "node\t0\t0\tnr\t1": (
                "Valor de node tamanho fora da faixa 1..4294967296."
            ),
        }
        for linha, esperado in esperados.items():
            with self.subTest(linha=linha):
                with self.assertRaises(DataError) as capturado:
                    resources.parse_snapshot(linha)
                self.assertEqual(str(capturado.exception), esperado)

    def test_rotulo_de_meminfo_e_o_unico_que_vem_do_host(self) -> None:
        """Achado NOVO-2 de 03/09/2026, corrigido no mesmo dia.

        Dos rótulos passados a `_integer`, só `"meminfo %s" % campo` carrega
        dado da fotografia, e tirar `safe_label` dali tirou junto o teto de 64
        caracteres e a exigência de ASCII. A reposição foi feita onde é o lugar
        dela, a validação do parser, e não na mensagem: campo longo demais ou
        fora de ASCII agora é fotografia inválida, e não diagnóstico com o
        nome do campo ecoado inteiro.
        """
        for campo in ("A" * 65, "MemÃo_ロク", "Mem Total", "Mem/Total"):
            with self.subTest(campo=campo):
                with self.assertRaises(DataError) as capturado:
                    resources.parse_snapshot("meminfo\t%s\t123" % campo)
                self.assertEqual(
                    str(capturado.exception),
                    "Linha 1: campo de meminfo inválido.",
                )
                self.assertNotIn(campo, str(capturado.exception))
        # O limite é de tamanho, não de forma: 64 caracteres ainda entram, e o
        # diagnóstico de valor continua nomeando o campo.
        aceito = resources.parse_snapshot("meminfo\t%s\t123" % ("A" * 64))
        self.assertEqual(aceito["meminfo"]["A" * 64], 123)
        with self.assertRaises(DataError) as capturado:
            resources.parse_snapshot("meminfo\tMemTotal\t-1")
        self.assertEqual(
            str(capturado.exception),
            "Valor de meminfo MemTotal não é inteiro sem sinal.",
        )


class ParseSnapshotCoerenciaTests(unittest.TestCase):
    def test_pool_sem_campo_obrigatorio(self) -> None:
        completo = linhas_pool(PAGE_1G, 22, 22, resv=0, surplus=0)
        for indice, ausente in enumerate(("nr", "free", "resv", "surplus")):
            with self.subTest(ausente=ausente):
                parcial = [l for i, l in enumerate(completo) if i != indice]
                with self.assertRaises(DataError) as capturado:
                    resources.parse_snapshot("\n".join(parcial))
                self.assertIn(
                    "Pool de 1048576 kB sem os campos %s." % ausente,
                    str(capturado.exception),
                )

    def test_pool_com_overcommit_apenas_ainda_reprova_listando_os_quatro(self) -> None:
        with self.assertRaises(DataError) as capturado:
            resources.parse_snapshot("pool\t2048\tovercommit\t3")
        self.assertIn(
            "Pool de 2048 kB sem os campos nr, free, resv, surplus.",
            str(capturado.exception),
        )

    def test_free_maior_que_nr_mais_surplus(self) -> None:
        with self.assertRaises(DataError) as capturado:
            resources.parse_snapshot("\n".join(linhas_pool(PAGE_1G, 22, 23)))
        self.assertIn(
            "Pool de 1048576 kB tem free maior que nr mais surplus.",
            str(capturado.exception),
        )
        # Com surplus, o mesmo free passa a ser possível e precisa ser aceito.
        dados = resources.parse_snapshot("\n".join(linhas_pool(PAGE_1G, 22, 23, surplus=1)))
        self.assertEqual(dados["pools"][PAGE_1G]["free"], 23)

    def test_resv_maior_que_nr_mais_surplus(self) -> None:
        with self.assertRaises(DataError) as capturado:
            resources.parse_snapshot("\n".join(linhas_pool(PAGE_1G, 22, 22, resv=23)))
        self.assertIn(
            "Pool de 1048576 kB tem resv maior que nr mais surplus.",
            str(capturado.exception),
        )
        dados = resources.parse_snapshot(
            "\n".join(linhas_pool(PAGE_1G, 22, 22, resv=23, surplus=1))
        )
        self.assertEqual(dados["pools"][PAGE_1G]["resv"], 23)

    def test_numero_de_nos_declarado_divergente(self) -> None:
        texto = "\n".join(["nodes\t3"] + linhas_node(0, PAGE_1G, 1, 1) + linhas_node(1, PAGE_1G, 1, 1))
        with self.assertRaises(DataError) as capturado:
            resources.parse_snapshot(texto)
        self.assertIn("A fotografia declara 3 nós NUMA e traz 2.", str(capturado.exception))

    def test_sem_registro_nodes_a_contagem_vem_dos_registros_node(self) -> None:
        texto = "\n".join(linhas_node(0, PAGE_1G, 1, 1) + linhas_node(1, PAGE_1G, 1, 1))
        self.assertEqual(resources.parse_snapshot(texto)["node_count"], 2)

    def test_sem_nada_declarado_a_contagem_e_um(self) -> None:
        self.assertEqual(resources.parse_snapshot("")["node_count"], 1)

    def test_nodes_declarado_sem_registros_node_nao_reprova_aqui(self) -> None:
        """A checagem só compara quando há registros `node`; a recusa é do NUMA."""
        dados = resources.parse_snapshot("nodes\t2")
        self.assertEqual(dados["node_count"], 2)
        self.assertEqual(dados["nodes"], {})


class FingerprintTests(unittest.TestCase):
    def test_identifica_a_maquina_e_nao_o_estado_do_pool(self) -> None:
        antes = foto(pools=((PAGE_1G, 22, 22),))
        depois = foto(pools=((PAGE_1G, 30, 25, 2, 0),))
        self.assertEqual(
            resources.fingerprint(resources.parse_snapshot(antes)),
            resources.fingerprint(resources.parse_snapshot(depois)),
        )

    def test_muda_com_topologia_tamanho_de_pagina_ou_ram_total(self) -> None:
        base = resources.fingerprint(resources.parse_snapshot(HOST))
        variantes = (
            foto(pools=((PAGE_2M, 0, 0), (PAGE_1G, 22, 22)), memtotal=MEMTOTAL_KB - 4),
            foto(pools=((PAGE_1G, 22, 22),)),
            foto(
                pools=((PAGE_2M, 0, 0), (PAGE_1G, 22, 22)),
                nodes=((0, PAGE_1G, 11, 11), (1, PAGE_1G, 11, 11)),
                node_count=2,
            ),
        )
        for variante in variantes:
            with self.subTest(variante=variante.splitlines()[1]):
                self.assertNotEqual(
                    base, resources.fingerprint(resources.parse_snapshot(variante))
                )

    def test_e_hexadecimal_de_64_e_deterministico(self) -> None:
        dados = resources.parse_snapshot(HOST)
        self.assertRegex(resources.fingerprint(dados), r"^[0-9a-f]{64}$")
        self.assertEqual(resources.fingerprint(dados), resources.fingerprint(dados))


# --- B. plan ------------------------------------------------------------------


class PlanModosTests(unittest.TestCase):
    def test_normal_nao_toca_no_pool_e_devolve_o_recurso(self) -> None:
        dados = resources.plan({"mode": "normal"})
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["error"], "")
        self.assertEqual(dados["mode"], "normal")
        self.assertEqual(dados["runtime"], 0)
        self.assertEqual(dados["returnable"], 1)
        self.assertEqual(dados["page_kb"], 0)
        self.assertEqual(dados["pages_needed"], 0)
        self.assertEqual(dados["acquire_delta"], 0)
        self.assertEqual(dados["target_nr"], 0)

    def test_hugetlb_2m_e_modo_de_runtime_retornavel(self) -> None:
        dados = plano("hugetlb-2m", vm_ram_mib=8192)
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["runtime"], 1)
        self.assertEqual(dados["returnable"], 1)
        self.assertEqual(dados["page_kb"], PAGE_2M)
        self.assertEqual(dados["pages_needed"], 4096)
        self.assertEqual(dados["acquire_delta"], 4096)
        self.assertEqual(dados["target_nr"], 4096)

    def test_hugetlb_1g_e_modo_de_runtime_retornavel(self) -> None:
        dados = plano("hugetlb-1g", vm_ram_mib=22528)
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["runtime"], 1)
        self.assertEqual(dados["returnable"], 1)
        self.assertEqual(dados["page_kb"], PAGE_1G)
        self.assertEqual(dados["pages_needed"], 22)

    def test_perfil_de_reserva_estatica_saiu_do_catalogo(self) -> None:
        """I9.12-D8: `hugetlb-1g-boot` foi REMOVIDO do catálogo de modos.

        Oráculo anterior (árvore de `af07725`): o modo era aceito com
        `valid=1`, `runtime=0`, `returnable=0`, `page_kb=1048576`,
        `pages_needed=22` e `baseline_nr=22`. Agora ele é apenas mais um texto
        desconhecido, e recusa como qualquer outro: `valid=0`, `transient=0`
        (recusa estrutural, que esperar não conserta), e o campo `mode` volta
        vazio porque a recusa acontece antes de ler a fotografia.
        """
        dados = plano("hugetlb-1g-boot", vm_ram_mib=22528)
        self.assertEqual(dados["valid"], 0)
        self.assertEqual(dados["transient"], 0)
        self.assertEqual(dados["mode"], "")
        self.assertIn("Modo de memória desconhecido: hugetlb-1g-boot.", dados["error"])
        self.assertNotIn("hugetlb-1g-boot", dados["error"].split("Aceitos:")[1])
        self.assertNotIn("hugetlb-1g-boot", resources.MODES)

    def test_matriz_dos_tres_modos(self) -> None:
        # I9.12: eram quatro modos até `af07725`; `hugetlb-1g-boot` saiu por D8.
        esperado = {
            "normal": (0, 1, 0),
            "hugetlb-2m": (1, 1, PAGE_2M),
            "hugetlb-1g": (1, 1, PAGE_1G),
        }
        self.assertEqual(sorted(esperado), sorted(resources.MODES))
        for mode, (runtime, returnable, page_kb) in esperado.items():
            with self.subTest(mode=mode):
                dados = plano(mode, vm_ram_mib=2048 if mode == "hugetlb-2m" else 22528)
                self.assertEqual(dados["valid"], 1)
                self.assertEqual(dados["runtime"], runtime)
                self.assertEqual(dados["returnable"], returnable)
                self.assertEqual(dados["page_kb"], page_kb)

    def test_modo_desconhecido_recusa_listando_os_aceitos(self) -> None:
        dados = resources.plan({"mode": "hugetlb-4k", "snapshot": HOST, "vm_ram_mib": 1024})
        self.assertEqual(dados["valid"], 0)
        self.assertEqual(dados["mode"], "")
        self.assertIn("Modo de memória desconhecido: hugetlb-4k.", dados["error"])
        self.assertIn("normal, hugetlb-2m, hugetlb-1g.", dados["error"])

    def test_modo_vazio_e_modo_nao_texto(self) -> None:
        dados = resources.plan({})
        self.assertEqual(dados["valid"], 0)
        self.assertIn("Modo de memória desconhecido: vazio.", dados["error"])
        with self.assertRaises(DataError) as capturado:
            resources.plan({"mode": 2})
        self.assertIn("Campo mode precisa ser texto.", str(capturado.exception))

    def test_modo_com_texto_hostil_nao_vaza_no_diagnostico(self) -> None:
        dados = resources.plan({"mode": "; rm -rf /"})
        self.assertEqual(dados["valid"], 0)
        self.assertIn(REDACTED_LABEL, dados["error"])
        self.assertNotIn("rm -rf", dados["error"])


class PlanPoolPreexistenteTests(unittest.TestCase):
    """I9.12: era `PlanBootModeTests`, do perfil de reserva estática removido por D8.

    O que o perfil legado provava continua valendo e continua provado, agora
    pelo modo de runtime `hugetlb-1g` sobre um pool que o boot deixou pronto:
    pool que já cobre a necessidade é BASELINE de terceiro, o delta é 0 e a
    operação não adquire nada. O que MUDOU é que o pool insuficiente deixou de
    ser recusa ("reserva estática menor que o necessário") e passou a ser
    aquisição do delta que falta, porque em runtime o modo pode crescer o pool.
    """

    def test_pool_preexistente_menor_que_o_necessario_adquire_o_delta(self) -> None:
        # Oráculo anterior: `hugetlb-1g-boot` recusava com "Reserva estática de
        # 8 páginas de 1048576 kB é menor que as 22 exigidas."
        pequena = foto(pools=((PAGE_1G, 8, 8),))
        dados = plano("hugetlb-1g", snapshot=pequena, vm_ram_mib=22528)
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["runtime"], 1)
        self.assertEqual(dados["returnable"], 1)
        self.assertEqual(dados["pages_needed"], 22)
        self.assertEqual(dados["baseline_nr"], 8)
        self.assertEqual(dados["acquire_delta"], 14)
        self.assertEqual(dados["target_nr"], 22)

    def test_pool_preexistente_exato_nao_adquire_nada(self) -> None:
        dados = plano("hugetlb-1g", snapshot=SO_1G, vm_ram_mib=22528)
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["error"], "")
        self.assertEqual(dados["returnable"], 1)
        self.assertEqual(dados["acquire_delta"], 0)
        self.assertEqual(dados["target_nr"], 22)

    def test_pool_preexistente_maior_e_baseline_a_preservar(self) -> None:
        dados = plano("hugetlb-1g", snapshot=SO_1G, vm_ram_mib=8192)
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["pages_needed"], 8)
        self.assertEqual(dados["baseline_nr"], 22)
        self.assertEqual(dados["acquire_delta"], 0)
        # Nunca desce abaixo do que já existia: o alvo é o baseline, não 8.
        self.assertEqual(dados["target_nr"], 22)

    def test_consumidor_externo_no_pool_preexistente_recusa(self) -> None:
        """I9.12: aqui a remoção do perfil legado MUDA o veredito, e para melhor.

        Oráculo anterior: com `hugetlb-1g-boot`, 22 páginas em uso por outra VM
        NÃO impediam o plano (`valid=1`), porque aquele modo não adquiria nem
        devolvia nada e só conferia cobertura. Em runtime o consumidor externo
        volta a ser o que o requisito manda: recusa, e transitória, porque
        depende do pool naquele instante e o hook a reavalia no start.
        """
        ocupado = foto(pools=((PAGE_1G, 22, 0, 0, 0),))
        dados = plano("hugetlb-1g", snapshot=ocupado, vm_ram_mib=22528)
        self.assertEqual(dados["valid"], 0)
        self.assertEqual(dados["transient"], 1)
        self.assertEqual(dados["baseline_free"], 0)
        self.assertIn(
            "Pool de 1048576 kB tem 22 página(s) em uso por outro consumidor;"
            " start recusado.",
            dados["error"],
        )


class PlanRuntimeTests(unittest.TestCase):
    def test_pool_inexistente_no_host(self) -> None:
        dados = plano("hugetlb-2m", snapshot=SO_1G, vm_ram_mib=8192)
        self.assertEqual(dados["valid"], 0)
        self.assertIn(
            "O host não expõe pool de 2048 kB; o modo hugetlb-2m não está disponível aqui.",
            dados["error"],
        )
        self.assertEqual(dados["page_kb"], PAGE_2M)
        self.assertEqual(dados["baseline_nr"], 0)

    def test_vm_ram_nao_multipla_do_tamanho_de_pagina(self) -> None:
        dados = plano("hugetlb-1g", vm_ram_mib=22529)
        self.assertEqual(dados["valid"], 0)
        self.assertIn(
            "VM_RAM_MB=22529 não é múltiplo de 1024 MiB (tamanho da página).",
            dados["error"],
        )
        self.assertEqual(dados["pages_needed"], 0)
        self.assertEqual(dados["acquire_delta"], 0)

    def test_vm_ram_impar_recusa_ate_no_pool_de_2_mib(self) -> None:
        dados = plano("hugetlb-2m", vm_ram_mib=4097)
        self.assertEqual(dados["valid"], 0)
        self.assertIn("não é múltiplo de 2 MiB", dados["error"])

    def test_vm_ram_ausente_ou_fora_de_faixa_levanta(self) -> None:
        for payload in (
            {"mode": "hugetlb-1g", "snapshot": HOST},
            {"mode": "hugetlb-1g", "snapshot": HOST, "vm_ram_mib": 0},
            {"mode": "hugetlb-1g", "snapshot": HOST, "vm_ram_mib": True},
        ):
            with self.subTest(payload=sorted(payload)):
                with self.assertRaises(DataError):
                    resources.plan(payload)

    def test_consumidor_externo_com_paginas_em_uso(self) -> None:
        ocupado = foto(pools=((PAGE_1G, 22, 14),))
        dados = plano("hugetlb-1g", snapshot=ocupado, vm_ram_mib=22528)
        self.assertEqual(dados["valid"], 0)
        self.assertIn(
            "Pool de 1048576 kB tem 8 página(s) em uso por outro consumidor;"
            " start recusado.",
            dados["error"],
        )
        self.assertEqual(dados["baseline_nr"], 22)
        self.assertEqual(dados["baseline_free"], 14)
        self.assertEqual(dados["acquire_delta"], 0)

    def test_pool_inteiramente_livre_nao_e_consumidor_externo(self) -> None:
        """Fronteira exata: `nr == free` é baseline preservável, não uso alheio."""
        dados = plano("hugetlb-1g", snapshot=SO_1G, vm_ram_mib=22528)
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["error"], "")

    def test_reserva_de_terceiro_recusa(self) -> None:
        reservado = foto(pools=((PAGE_1G, 22, 22, 3, 0),))
        dados = plano("hugetlb-1g", snapshot=reservado, vm_ram_mib=22528)
        self.assertEqual(dados["valid"], 0)
        self.assertIn(
            "Pool de 1048576 kB tem 3 página(s) reservada(s) por outro consumidor.",
            dados["error"],
        )

    def test_surplus_recusa_por_indemonstrabilidade(self) -> None:
        com_surplus = foto(pools=((PAGE_1G, 22, 24, 0, 2),))
        dados = plano("hugetlb-1g", snapshot=com_surplus, vm_ram_mib=22528)
        self.assertEqual(dados["valid"], 0)
        self.assertIn("tem 2 página(s) de surplus", dados["error"])
        self.assertIn("a exatidão da devolução não pode ser provada", dados["error"])

    def test_memoria_disponivel_insuficiente(self) -> None:
        dados = plano("hugetlb-1g", snapshot=HOST_APERTADO, vm_ram_mib=30720)
        self.assertEqual(dados["valid"], 0)
        self.assertIn(
            "MemAvailable=4143904 kB não cobre 8 página(s) de 1048576 kB (8388608 kB).",
            dados["error"],
        )
        self.assertEqual(dados["acquire_delta"], 8)
        self.assertEqual(dados["baseline_nr"], 22)

    def test_memoria_exatamente_suficiente_e_aceita(self) -> None:
        justa = foto(pools=((PAGE_1G, 0, 0),), memavailable=2 * PAGE_1G)
        self.assertEqual(plano("hugetlb-1g", snapshot=justa, vm_ram_mib=2048)["valid"], 1)
        curta = foto(pools=((PAGE_1G, 0, 0),), memavailable=2 * PAGE_1G - 1)
        self.assertEqual(plano("hugetlb-1g", snapshot=curta, vm_ram_mib=2048)["valid"], 0)

    def test_sem_memavailable_a_checagem_nao_dispara(self) -> None:
        sem = foto(pools=((PAGE_1G, 0, 0),), memavailable=None)
        dados = plano("hugetlb-1g", snapshot=sem, vm_ram_mib=22528)
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["acquire_delta"], 22)

    def test_pool_preexistente_que_ja_cobre_a_necessidade(self) -> None:
        """Delta 0 e baseline intacto: o pool do boot é de terceiro, não sobra."""
        dados = plano("hugetlb-1g", snapshot=SO_1G, vm_ram_mib=8192)
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["pages_needed"], 8)
        self.assertEqual(dados["baseline_nr"], 22)
        self.assertEqual(dados["acquire_delta"], 0)
        self.assertEqual(dados["target_nr"], 22)

    def test_pool_preexistente_parcial_adquire_so_o_que_falta(self) -> None:
        dados = plano("hugetlb-1g", snapshot=SO_1G, vm_ram_mib=30720)
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["pages_needed"], 30)
        self.assertEqual(dados["baseline_nr"], 22)
        self.assertEqual(dados["acquire_delta"], 8)
        self.assertEqual(dados["target_nr"], 30)

    def test_baseline_completo_acompanha_o_plano_aceito(self) -> None:
        dados = plano("hugetlb-1g", snapshot=SO_1G, vm_ram_mib=30720)
        self.assertEqual(dados["baseline_free"], 22)
        self.assertEqual(dados["baseline_resv"], 0)
        self.assertEqual(dados["baseline_surplus"], 0)
        self.assertEqual(dados["node_count"], 1)
        self.assertRegex(dados["fingerprint"], r"^[0-9a-f]{64}$")

    def test_fotografia_invalida_levanta_em_vez_de_planejar(self) -> None:
        with self.assertRaises(DataError):
            plano("hugetlb-1g", snapshot="lixo\t1", vm_ram_mib=1024)


# --- C. NUMA ------------------------------------------------------------------


class PlanNumaTests(unittest.TestCase):
    def test_host_de_um_no_satisfaz_trivialmente(self) -> None:
        um_no = foto(pools=((PAGE_1G, 0, 0),), node_count=1)
        dados = plano("hugetlb-1g", snapshot=um_no, vm_ram_mib=8192)
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["node_count"], 1)
        self.assertEqual(dados["acquire_delta"], 8)

    def test_dois_nos_sem_registros_node_recusa(self) -> None:
        sem_nos = foto(pools=((PAGE_1G, 0, 0),), node_count=2)
        dados = plano("hugetlb-1g", snapshot=sem_nos, vm_ram_mib=8192)
        self.assertEqual(dados["valid"], 0)
        self.assertIn(
            "O host declara 2 nós NUMA e a fotografia não traz os contadores por"
            " nó; distribuição não pode ser comprovada.",
            dados["error"],
        )
        self.assertEqual(dados["acquire_delta"], 8)

    def test_delta_que_nao_divide_igualmente_recusa(self) -> None:
        dois = foto(
            pools=((PAGE_1G, 0, 0),),
            nodes=((0, PAGE_1G, 0, 0), (1, PAGE_1G, 0, 0)),
            node_count=2,
        )
        dados = plano("hugetlb-1g", snapshot=dois, vm_ram_mib=3072)
        self.assertEqual(dados["valid"], 0)
        self.assertIn(
            "Delta de 3 página(s) não divide igualmente entre 2 nós NUMA.",
            dados["error"],
        )

    def test_no_sem_o_pool_do_tamanho_pedido_recusa_nomeando_o_no(self) -> None:
        misto = foto(
            pools=((PAGE_1G, 0, 0),),
            nodes=((0, PAGE_1G, 0, 0), (1, PAGE_2M, 0, 0)),
            node_count=2,
        )
        dados = plano("hugetlb-1g", snapshot=misto, vm_ram_mib=4096)
        self.assertEqual(dados["valid"], 0)
        self.assertIn(
            "Nó NUMA 1 não expõe pool de 1048576 kB; distribuição não pode ser"
            " comprovada.",
            dados["error"],
        )

    def test_dois_nos_simetricos_com_delta_par_passa(self) -> None:
        dois = foto(
            pools=((PAGE_1G, 0, 0),),
            nodes=((0, PAGE_1G, 0, 0), (1, PAGE_1G, 0, 0)),
            node_count=2,
        )
        dados = plano("hugetlb-1g", snapshot=dois, vm_ram_mib=4096)
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["error"], "")
        self.assertEqual(dados["acquire_delta"], 4)
        self.assertEqual(dados["node_count"], 2)

    def test_delta_zero_nao_aciona_a_checagem_numa(self) -> None:
        """Sem aquisição não há distribuição a comprovar; recusar seria ruído."""
        dois = foto(pools=((PAGE_1G, 22, 22),), node_count=2)
        dados = plano("hugetlb-1g", snapshot=dois, vm_ram_mib=8192)
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["acquire_delta"], 0)


# --- D. verify ----------------------------------------------------------------


ANTES_AQUISICAO = foto(pools=((PAGE_1G, 22, 22),))
DEPOIS_AQUISICAO = foto(pools=((PAGE_1G, 30, 30),))


def prova(phase, before, after, page_kb=PAGE_1G, delta=8, **extra):
    payload = {
        "phase": phase,
        "before": before,
        "after": after,
        "page_kb": page_kb,
        "delta": delta,
    }
    payload.update(extra)
    return resources.verify(payload)


class VerifyAquisicaoTests(unittest.TestCase):
    def test_aquisicao_exata(self) -> None:
        dados = prova("acquire", ANTES_AQUISICAO, DEPOIS_AQUISICAO)
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["error"], "")
        self.assertEqual(dados["phase"], "acquire")
        self.assertEqual(dados["before_nr"], 22)
        self.assertEqual(dados["after_nr"], 30)
        self.assertEqual(dados["before_free"], 22)
        self.assertEqual(dados["after_free"], 30)
        self.assertEqual(dados["machine_changed"], 0)

    def test_aquisicao_parcial_reprova(self) -> None:
        parcial = foto(pools=((PAGE_1G, 27, 27),))
        dados = prova("acquire", ANTES_AQUISICAO, parcial)
        self.assertEqual(dados["valid"], 0)
        self.assertIn(
            "Aquisição parcial ou excedente: nr=27, esperado 30 (baseline 22 mais"
            " delta 8).",
            dados["error"],
        )
        self.assertEqual(dados["after_nr"], 27)

    def test_aquisicao_excedente_reprova(self) -> None:
        excedente = foto(pools=((PAGE_1G, 33, 33),))
        dados = prova("acquire", ANTES_AQUISICAO, excedente)
        self.assertEqual(dados["valid"], 0)
        self.assertIn("nr=33, esperado 30", dados["error"])

    def test_nenhuma_pagina_adquirida_reprova(self) -> None:
        dados = prova("acquire", ANTES_AQUISICAO, ANTES_AQUISICAO)
        self.assertEqual(dados["valid"], 0)
        self.assertIn("nr=22, esperado 30", dados["error"])

    def test_paginas_adquiridas_que_nao_ficaram_livres(self) -> None:
        presas = foto(pools=((PAGE_1G, 30, 25),))
        dados = prova("acquire", ANTES_AQUISICAO, presas)
        self.assertEqual(dados["valid"], 0)
        self.assertIn(
            "As 8 página(s) adquiridas não estão livres: free=25, esperado ao"
            " menos 30.",
            dados["error"],
        )

    def test_surplus_que_mudou_durante_a_janela(self) -> None:
        com_surplus = foto(pools=((PAGE_1G, 30, 30, 0, 2),))
        dados = prova("acquire", ANTES_AQUISICAO, com_surplus)
        self.assertEqual(dados["valid"], 0)
        self.assertIn(
            "Surplus mudou de 0 para 2 durante a aquisição; o pool não é exato.",
            dados["error"],
        )

    def test_delta_zero_com_pool_intacto_e_aquisicao_valida(self) -> None:
        dados = prova("acquire", ANTES_AQUISICAO, ANTES_AQUISICAO, delta=0)
        self.assertEqual(dados["valid"], 1)


class VerifyDevolucaoTests(unittest.TestCase):
    BASELINE = {
        "baseline_nr": 22,
        "baseline_free": 22,
        "baseline_resv": 0,
        "baseline_surplus": 0,
    }

    def test_baseline_reproduzido_campo_a_campo(self) -> None:
        dados = prova(
            "release", DEPOIS_AQUISICAO, ANTES_AQUISICAO, **self.BASELINE
        )
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["error"], "")
        self.assertEqual(dados["phase"], "release")
        self.assertEqual(dados["before_nr"], 30)
        self.assertEqual(dados["after_nr"], 22)
        self.assertEqual(dados["baseline_nr"], 22)

    def test_cada_campo_divergente_e_nomeado_sozinho(self) -> None:
        casos = (
            ("nr", foto(pools=((PAGE_1G, 23, 22),)), "nr=23 (esperado 22)"),
            ("free", foto(pools=((PAGE_1G, 22, 21),)), "free=21 (esperado 22)"),
            ("resv", foto(pools=((PAGE_1G, 22, 22, 1, 0),)), "resv=1 (esperado 0)"),
            ("surplus", foto(pools=((PAGE_1G, 22, 22, 0, 1),)), "surplus=1 (esperado 0)"),
        )
        outros = {"nr=", "free=", "resv=", "surplus="}
        for campo, depois, trecho in casos:
            with self.subTest(campo=campo):
                dados = prova("release", DEPOIS_AQUISICAO, depois, **self.BASELINE)
                self.assertEqual(dados["valid"], 0)
                self.assertIn(
                    "A devolução não reproduziu o baseline do pool de 1048576 kB:",
                    dados["error"],
                )
                self.assertIn(trecho, dados["error"])
                for outro in outros - {campo + "="}:
                    self.assertNotIn(outro, dados["error"])

    def test_varios_campos_divergentes_aparecem_juntos(self) -> None:
        depois = foto(pools=((PAGE_1G, 26, 24, 1, 1),))
        dados = prova("release", DEPOIS_AQUISICAO, depois, **self.BASELINE)
        self.assertEqual(dados["valid"], 0)
        for trecho in (
            "nr=26 (esperado 22)",
            "free=24 (esperado 22)",
            "resv=1 (esperado 0)",
            "surplus=1 (esperado 0)",
        ):
            self.assertIn(trecho, dados["error"])

    def test_devolucao_abaixo_do_baseline_tambem_reprova(self) -> None:
        """Zerar pool de terceiro é falha, não limpeza bem-sucedida."""
        zerado = foto(pools=((PAGE_1G, 0, 0),))
        dados = prova("release", DEPOIS_AQUISICAO, zerado, **self.BASELINE)
        self.assertEqual(dados["valid"], 0)
        self.assertIn("nr=0 (esperado 22)", dados["error"])

    def test_baseline_ausente_ou_invalido_levanta(self) -> None:
        for chave in ("baseline_nr", "baseline_free", "baseline_resv", "baseline_surplus"):
            with self.subTest(chave=chave):
                incompleto = dict(self.BASELINE)
                del incompleto[chave]
                with self.assertRaises(DataError):
                    prova("release", DEPOIS_AQUISICAO, ANTES_AQUISICAO, **incompleto)

    def test_baseline_aceita_inteiro_e_texto_com_o_mesmo_resultado(self) -> None:
        texto = {chave: str(valor) for chave, valor in self.BASELINE.items()}
        self.assertEqual(
            prova("release", DEPOIS_AQUISICAO, ANTES_AQUISICAO, **self.BASELINE),
            prova("release", DEPOIS_AQUISICAO, ANTES_AQUISICAO, **texto),
        )


class VerifyComumTests(unittest.TestCase):
    BASELINE = VerifyDevolucaoTests.BASELINE

    def test_fingerprint_diferente_em_cada_fase(self) -> None:
        outra_maquina = foto(pools=((PAGE_1G, 30, 30),), memtotal=MEMTOTAL_KB - 8)
        for phase, extra in (("acquire", {}), ("release", self.BASELINE)):
            with self.subTest(phase=phase):
                dados = prova(phase, ANTES_AQUISICAO, outra_maquina, **extra)
                self.assertEqual(dados["valid"], 0)
                self.assertEqual(dados["machine_changed"], 1)
                self.assertIn(
                    "A identidade da máquina mudou entre as duas fotografias; nada"
                    " pode ser provado sobre o pool.",
                    dados["error"],
                )
                self.assertEqual(dados["before_nr"], 0)
                self.assertEqual(dados["after_nr"], 0)

    def test_pool_ausente_nas_duas_fotografias(self) -> None:
        for phase, extra in (("acquire", {}), ("release", self.BASELINE)):
            with self.subTest(phase=phase):
                dados = prova(
                    phase, ANTES_AQUISICAO, ANTES_AQUISICAO, page_kb=PAGE_2M, **extra
                )
                self.assertEqual(dados["valid"], 0)
                self.assertEqual(dados["machine_changed"], 0)
                self.assertIn(
                    "Pool de 2048 kB ausente em uma das fotografias.", dados["error"]
                )

    def test_pool_ausente_em_uma_so_aparece_como_maquina_mudada(self) -> None:
        """Comportamento declarado: o conjunto de tamanhos entra no fingerprint.

        Um pool que some entre as duas fotografias muda a identidade da máquina
        antes de virar "pool ausente", e é isso que o diagnóstico diz.
        """
        sem_pool = foto(pools=())
        dados = prova("acquire", ANTES_AQUISICAO, sem_pool)
        self.assertEqual(dados["valid"], 0)
        self.assertEqual(dados["machine_changed"], 1)
        self.assertIn("identidade da máquina mudou", dados["error"])

    def test_fase_desconhecida_levanta(self) -> None:
        for phase, esperado in (
            ("acquired", "Fase desconhecida para prova: acquired."),
            ("", "Fase desconhecida para prova: vazio."),
            ("RELEASE", "Fase desconhecida para prova: RELEASE."),
        ):
            with self.subTest(phase=phase):
                with self.assertRaises(DataError) as capturado:
                    prova(phase, ANTES_AQUISICAO, DEPOIS_AQUISICAO)
                self.assertIn(esperado, str(capturado.exception))

    def test_page_kb_e_delta_invalidos_levantam(self) -> None:
        for chave, valor in (("page_kb", 0), ("delta", -1), ("page_kb", "abc")):
            with self.subTest(chave=chave, valor=valor):
                with self.assertRaises(DataError):
                    prova(
                        "acquire",
                        ANTES_AQUISICAO,
                        DEPOIS_AQUISICAO,
                        **{chave: valor},
                    )

    def test_fotografia_invalida_levanta(self) -> None:
        with self.assertRaises(DataError):
            prova("acquire", "cgroup\t1", DEPOIS_AQUISICAO)


# --- E. plan_release ----------------------------------------------------------


def devolucao(snapshot, delta=8, baseline_nr=22, page_kb=PAGE_1G):
    return resources.plan_release(
        {
            "snapshot": snapshot,
            "delta": delta,
            "baseline_nr": baseline_nr,
            "page_kb": page_kb,
        }
    )


class PlanReleaseTests(unittest.TestCase):
    def test_delta_zero_nao_mexe_no_pool(self) -> None:
        """Escrever `nr_hugepages` "para garantir" zeraria pool de terceiro."""
        dados = devolucao(SO_1G, delta=0, baseline_nr=22)
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["error"], "")
        self.assertEqual(dados["current_nr"], 22)
        self.assertEqual(dados["target_nr"], 22)
        self.assertEqual(dados["target_nr"], dados["current_nr"])

    def test_delta_zero_com_baseline_zero_preserva_pool_de_terceiro(self) -> None:
        terceiro = foto(pools=((PAGE_1G, 7, 7),))
        dados = devolucao(terceiro, delta=0, baseline_nr=0)
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["target_nr"], 7)

    def test_devolucao_normal_volta_exatamente_ao_baseline(self) -> None:
        dados = devolucao(foto(pools=((PAGE_1G, 30, 30),)), delta=8, baseline_nr=22)
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["current_nr"], 30)
        self.assertEqual(dados["current_free"], 30)
        self.assertEqual(dados["target_nr"], 22)

    def test_devolucao_de_pool_inteiro_quando_o_baseline_era_zero(self) -> None:
        dados = devolucao(foto(pools=((PAGE_1G, 8, 8),)), delta=8, baseline_nr=0)
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["target_nr"], 0)

    def test_nr_menor_que_baseline_mais_delta(self) -> None:
        dados = devolucao(foto(pools=((PAGE_1G, 25, 25),)), delta=8, baseline_nr=22)
        self.assertEqual(dados["valid"], 0)
        self.assertIn(
            "Pool de 1048576 kB tem nr=25, menor que baseline 22 mais delta 8;"
            " alguém mexeu no pool e a devolução exata é impossível.",
            dados["error"],
        )
        self.assertEqual(dados["target_nr"], 22)

    def test_free_menor_que_o_delta_indica_consumidor_ativo(self) -> None:
        dados = devolucao(foto(pools=((PAGE_1G, 30, 3),)), delta=8, baseline_nr=22)
        self.assertEqual(dados["valid"], 0)
        self.assertIn(
            "Só 3 de 8 página(s) estão livres no pool de 1048576 kB; ainda há"
            " consumidor ativo.",
            dados["error"],
        )
        self.assertEqual(dados["current_free"], 3)

    def test_free_exatamente_igual_ao_delta_e_devolvivel(self) -> None:
        dados = devolucao(foto(pools=((PAGE_1G, 30, 8),)), delta=8, baseline_nr=22)
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["target_nr"], 22)

    def test_pool_ausente(self) -> None:
        dados = devolucao(SO_1G, delta=8, baseline_nr=22, page_kb=PAGE_2M)
        self.assertEqual(dados["valid"], 0)
        self.assertIn(
            "Pool de 2048 kB ausente; devolução não pode ser planejada.",
            dados["error"],
        )
        self.assertEqual(dados["current_nr"], 0)
        self.assertEqual(dados["target_nr"], 22)

    def test_campos_ausentes_ou_invalidos_levantam(self) -> None:
        completo = {"snapshot": SO_1G, "delta": 8, "baseline_nr": 22, "page_kb": PAGE_1G}
        for chave in ("delta", "baseline_nr", "page_kb"):
            with self.subTest(chave=chave):
                incompleto = dict(completo)
                del incompleto[chave]
                with self.assertRaises(DataError):
                    resources.plan_release(incompleto)

    def test_aceita_inteiro_e_texto_com_o_mesmo_resultado(self) -> None:
        inteiro = devolucao(foto(pools=((PAGE_1G, 30, 30),)))
        texto = resources.plan_release(
            {
                "snapshot": foto(pools=((PAGE_1G, 30, 30),)),
                "delta": "8",
                "baseline_nr": "22",
                "page_kb": str(PAGE_1G),
            }
        )
        self.assertEqual(inteiro, texto)


# --- F. Máquina de estados ----------------------------------------------------


def transicao(state, event, **extra):
    payload = {"state": state, "event": event}
    payload.update(extra)
    return resources.state(payload)


class StateCicloTests(unittest.TestCase):
    def test_ciclo_feliz_inteiro(self) -> None:
        esperado = (
            ("", "prepare", "PREPARED"),
            ("PREPARED", "acquire", "ACQUIRED"),
            ("ACQUIRED", "verify", "VERIFIED"),
            ("VERIFIED", "release_begin", "RELEASING"),
            ("RELEASING", "release_done", "RELEASED"),
            ("RELEASED", "prepare", "PREPARED"),
        )
        atual = ""
        for origem, evento, destino in esperado:
            with self.subTest(origem=origem, evento=evento):
                self.assertEqual(atual, origem)
                dados = transicao(atual, evento)
                self.assertEqual(dados["valid"], 1)
                self.assertEqual(dados["error"], "")
                self.assertEqual(dados["next_state"], destino)
                self.assertEqual(dados["stale_boot"], 0)
                self.assertEqual(dados["recovery"], 0)
                atual = dados["next_state"]

    def test_start_recusado_antes_da_aquisicao_encerra_sem_devolver(self) -> None:
        dados = transicao("PREPARED", "release_done")
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["next_state"], "RELEASED")

    def test_double_acquire(self) -> None:
        dados = transicao("ACQUIRED", "acquire")
        self.assertEqual(dados["valid"], 0)
        self.assertEqual(dados["next_state"], "")
        self.assertIn("Transição inválida: ACQUIRED + acquire.", dados["error"])

    def test_double_release(self) -> None:
        dados = transicao("RELEASED", "release_done")
        self.assertEqual(dados["valid"], 0)
        self.assertIn("Transição inválida: RELEASED + release_done.", dados["error"])
        dados = transicao("RELEASED", "release_begin")
        self.assertEqual(dados["valid"], 0)
        self.assertIn("Transição inválida: RELEASED + release_begin.", dados["error"])

    def test_transicoes_invalidas_diversas(self) -> None:
        casos = (
            ("", "acquire"),
            ("", "verify"),
            ("", "release_done"),
            ("", "reconcile"),
            ("PREPARED", "verify"),
            ("PREPARED", "release_begin"),
            ("PREPARED", "prepare"),
            ("ACQUIRED", "release_done"),
            ("VERIFIED", "verify"),
            ("RELEASING", "acquire"),
        )
        for origem, evento in casos:
            with self.subTest(origem=origem, evento=evento):
                dados = transicao(origem, evento)
                self.assertEqual(dados["valid"], 0)
                self.assertEqual(dados["next_state"], "")
                self.assertIn(
                    "Transição inválida: %s + %s."
                    % (origem or "(inicial)", evento),
                    dados["error"],
                )

    def test_estado_inicial_e_nomeado_na_transicao_invalida(self) -> None:
        """Foi defeito até 03/09/2026: `safe_label("(inicial)")` redigia.

        O rótulo `(inicial)` é escolha do módulo para o estado vazio, e a
        expressão de `safe_label` não aceita parêntese. A recusa mais comum do
        ciclo — evento fora de ordem sem operação registrada — saía como
        "Transição inválida: <valor redigido> + acquire", sem dizer que não
        havia operação alguma.
        """
        dados = transicao("", "acquire")
        self.assertEqual(dados["valid"], 0)
        self.assertEqual(dados["error"], "Transição inválida: (inicial) + acquire.")
        self.assertNotIn(REDACTED_LABEL, dados["error"])

    def test_a_tabela_de_transicoes_nao_tem_atalho_nao_testado(self) -> None:
        autorizadas = set(resources.TRANSITIONS)
        for origem in ("",) + resources.STATES:
            for evento in resources.EVENTS:
                if evento == resources.EVENT_FAIL:
                    continue
                dados = transicao(origem, evento)
                esperado = (origem, evento) in autorizadas and not (
                    origem == resources.STATE_RECOVERY and evento != "reconcile"
                )
                self.assertEqual(dados["valid"], 1 if esperado else 0)


class StateFalhaERecuperacaoTests(unittest.TestCase):
    def test_fail_a_partir_de_cada_estado_leva_a_recovery(self) -> None:
        for origem in ("",) + resources.STATES:
            with self.subTest(origem=origem):
                dados = transicao(origem, "fail")
                self.assertEqual(dados["valid"], 1)
                self.assertEqual(dados["next_state"], "RECOVERY_REQUIRED")
                self.assertEqual(dados["recovery"], 1)
                self.assertEqual(dados["error"], "")

    def test_recovery_recusa_qualquer_evento_que_nao_seja_reconcile(self) -> None:
        for evento in ("prepare", "acquire", "verify", "release_begin", "release_done"):
            with self.subTest(evento=evento):
                dados = transicao("RECOVERY_REQUIRED", evento)
                self.assertEqual(dados["valid"], 0)
                self.assertEqual(dados["recovery"], 1)
                self.assertEqual(dados["next_state"], "")
                self.assertIn(
                    "A operação está em RECOVERY_REQUIRED; nenhum ciclo novo"
                    " começa antes da reconciliação.",
                    dados["error"],
                )

    def test_reconcile_e_a_unica_saida(self) -> None:
        dados = transicao("RECOVERY_REQUIRED", "reconcile")
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["next_state"], "RELEASED")

    def test_reconcile_fora_de_recovery_nao_e_atalho(self) -> None:
        for origem in ("", "PREPARED", "ACQUIRED", "VERIFIED", "RELEASING", "RELEASED"):
            with self.subTest(origem=origem):
                dados = transicao(origem, "reconcile")
                self.assertEqual(dados["valid"], 0)


class StateEntradaInvalidaTests(unittest.TestCase):
    def test_estado_desconhecido_levanta(self) -> None:
        for estado in ("RECOVERED", "prepared", "RECOVERY", "0"):
            with self.subTest(estado=estado):
                with self.assertRaises(DataError) as capturado:
                    transicao(estado, "prepare")
                self.assertIn(
                    "Estado desconhecido: %s." % estado, str(capturado.exception)
                )

    def test_evento_desconhecido_levanta(self) -> None:
        for evento, rotulo in (("start", "start"), ("", "vazio"), ("PREPARE", "PREPARE")):
            with self.subTest(evento=evento):
                with self.assertRaises(DataError) as capturado:
                    transicao("PREPARED", evento)
                self.assertIn(
                    "Evento desconhecido: %s." % rotulo, str(capturado.exception)
                )

    def test_estado_e_evento_nao_texto_levantam(self) -> None:
        with self.assertRaises(DataError):
            resources.state({"state": 1, "event": "prepare"})
        with self.assertRaises(DataError):
            resources.state({"state": "PREPARED", "event": ["prepare"]})

    def test_estado_hostil_nao_vaza_no_diagnostico(self) -> None:
        with self.assertRaises(DataError) as capturado:
            transicao("$(rm -rf /) PREPARED", "prepare")
        mensagem = str(capturado.exception)
        self.assertIn(REDACTED_LABEL, mensagem)
        self.assertNotIn("rm -rf", mensagem)


class StateBootIdTests(unittest.TestCase):
    OUTRO_BOOT = {"state_boot_id": "boot-antigo", "boot_id": "boot-atual"}

    def test_prepare_sobre_state_de_outro_boot_exige_reconciliacao(self) -> None:
        dados = transicao("ACQUIRED", "prepare", **self.OUTRO_BOOT)
        self.assertEqual(dados["valid"], 0)
        self.assertEqual(dados["stale_boot"], 1)
        self.assertEqual(dados["next_state"], "")
        self.assertIn(
            "Existe state da operação de outro boot (boot-antigo) e o boot atual"
            " é boot-atual; reconcilie o baseline antes de iniciar a VM.",
            dados["error"],
        )

    def test_reconcile_sobre_state_de_outro_boot_e_aceito(self) -> None:
        for origem in resources.STATES:
            with self.subTest(origem=origem):
                dados = transicao(origem, "reconcile", **self.OUTRO_BOOT)
                self.assertEqual(dados["valid"], 1)
                self.assertEqual(dados["stale_boot"], 1)
                self.assertEqual(dados["next_state"], "RELEASED")
                self.assertEqual(dados["error"], "")

    def test_qualquer_outro_evento_sobre_state_de_outro_boot_recusa(self) -> None:
        for evento in ("acquire", "verify", "release_begin", "release_done", "fail"):
            with self.subTest(evento=evento):
                dados = transicao("ACQUIRED", evento, **self.OUTRO_BOOT)
                self.assertEqual(dados["valid"], 0)
                self.assertEqual(dados["stale_boot"], 1)
                self.assertIn(
                    "Evento '%s' recusado sobre state de outro boot; só"
                    " 'reconcile' é autorizado." % evento,
                    dados["error"],
                )

    def test_boot_antigo_prevalece_sobre_fail(self) -> None:
        """`fail` é universal, mas não sobre state que não descreve este boot."""
        dados = transicao("ACQUIRED", "fail", **self.OUTRO_BOOT)
        self.assertEqual(dados["valid"], 0)
        self.assertEqual(dados["next_state"], "")
        self.assertEqual(dados["recovery"], 0)

    def test_mesmo_boot_id_nao_dispara_a_checagem(self) -> None:
        dados = transicao(
            "PREPARED", "acquire", state_boot_id="boot-a", boot_id="boot-a"
        )
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["stale_boot"], 0)
        self.assertEqual(dados["next_state"], "ACQUIRED")

    def test_sem_boot_id_nos_dois_lados_a_checagem_nao_dispara(self) -> None:
        for extra in (
            {},
            {"state_boot_id": "", "boot_id": ""},
            {"state_boot_id": "boot-antigo"},
            {"boot_id": "boot-atual"},
            {"state_boot_id": "boot-antigo", "boot_id": ""},
            {"state_boot_id": "", "boot_id": "boot-atual"},
        ):
            with self.subTest(extra=sorted(extra.items())):
                dados = transicao("PREPARED", "acquire", **extra)
                self.assertEqual(dados["valid"], 1)
                self.assertEqual(dados["stale_boot"], 0)
                self.assertEqual(dados["next_state"], "ACQUIRED")

    def test_sem_state_registrado_o_boot_divergente_nao_bloqueia_o_start(self) -> None:
        dados = transicao("", "prepare", **self.OUTRO_BOOT)
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["stale_boot"], 0)
        self.assertEqual(dados["next_state"], "PREPARED")

    def test_boot_id_hostil_nao_vaza_no_diagnostico(self) -> None:
        dados = transicao(
            "ACQUIRED",
            "prepare",
            state_boot_id="/etc/shadow ; id",
            boot_id="boot-atual",
        )
        self.assertEqual(dados["valid"], 0)
        self.assertIn(REDACTED_LABEL, dados["error"])
        self.assertNotIn("shadow", dados["error"])


# --- G. Propriedades gerais ---------------------------------------------------


class PurezaDoModuloTests(unittest.TestCase):
    """O módulo não escreve em disco e não chama processo, por construção."""

    def _fonte(self) -> ast.Module:
        return ast.parse(Path(resources.__file__).read_text(encoding="utf-8"))

    def test_nao_importa_os_sys_pathlib_nem_subprocess(self) -> None:
        proibidos = {
            "os", "sys", "pathlib", "subprocess", "shutil", "tempfile", "socket",
            "importlib", "ctypes", "multiprocessing", "signal", "io",
        }
        permitidos = {"hashlib", "typing", "__future__"}
        importados = set()
        for no in ast.walk(self._fonte()):
            if isinstance(no, ast.Import):
                for alias in no.names:
                    importados.add(alias.name.split(".")[0])
            elif isinstance(no, ast.ImportFrom):
                if no.level:
                    self.assertIn(no.module, {"errors", "protocol"})
                else:
                    importados.add((no.module or "").split(".")[0])
        self.assertEqual(importados & proibidos, set())
        self.assertLessEqual(importados, permitidos)

    def test_nao_cita_construtor_de_efeito(self) -> None:
        nomes = {"open", "eval", "exec", "compile", "__import__", "input", "breakpoint"}
        atributos = {
            "open", "system", "popen", "spawn", "fork", "remove", "unlink",
            "rename", "mkdir", "read_text", "write_text", "read_bytes",
            "write_bytes", "write", "run", "check_output",
        }
        for no in ast.walk(self._fonte()):
            if isinstance(no, ast.Name):
                self.assertNotIn(no.id, nomes)
            if isinstance(no, ast.Attribute):
                self.assertNotIn(no.attr, atributos)

    def test_nenhuma_entrada_abre_caminho(self) -> None:
        original = builtins.open

        def recusar(*args, **kwargs):
            raise AssertionError("o core tentou abrir um caminho: %r" % (args,))

        builtins.open = recusar
        try:
            self.assertEqual(plano("hugetlb-1g", snapshot=SO_1G, vm_ram_mib=30720)["valid"], 1)
            self.assertEqual(
                prova("acquire", ANTES_AQUISICAO, DEPOIS_AQUISICAO)["valid"], 1
            )
            self.assertEqual(devolucao(foto(pools=((PAGE_1G, 30, 30),)))["valid"], 1)
            self.assertEqual(transicao("PREPARED", "acquire")["valid"], 1)
            with self.assertRaises(DataError):
                resources.parse_snapshot("../../etc/shadow\t1")
        finally:
            builtins.open = original

    def test_travessia_em_boot_id_e_thp_nao_vira_caminho(self) -> None:
        original = builtins.open

        def recusar(*args, **kwargs):
            raise AssertionError("o core tentou abrir um caminho: %r" % (args,))

        builtins.open = recusar
        try:
            dados = resources.parse_snapshot(
                "boot_id\t../../etc/shadow\nthp\tenabled\t/proc/self/mem"
            )
            self.assertEqual(dados["boot_id"], "../../etc/shadow")
            self.assertEqual(dados["thp"]["enabled"], "/proc/self/mem")
        finally:
            builtins.open = original


class DeterminismoTests(unittest.TestCase):
    def test_duas_chamadas_iguais_devolvem_resultado_igual(self) -> None:
        chamadas = (
            lambda: plano("hugetlb-1g", snapshot=SO_1G, vm_ram_mib=30720),
            lambda: plano("hugetlb-2m", snapshot=HOST, vm_ram_mib=8193),
            lambda: plano("normal"),
            lambda: prova("acquire", ANTES_AQUISICAO, DEPOIS_AQUISICAO),
            lambda: prova(
                "release",
                DEPOIS_AQUISICAO,
                ANTES_AQUISICAO,
                **VerifyDevolucaoTests.BASELINE,
            ),
            lambda: devolucao(foto(pools=((PAGE_1G, 30, 30),))),
            lambda: devolucao(foto(pools=((PAGE_1G, 25, 25),))),
            lambda: transicao("PREPARED", "acquire"),
            lambda: transicao("RECOVERY_REQUIRED", "acquire"),
            lambda: resources.parse_snapshot(HOST),
        )
        for indice, chamada in enumerate(chamadas):
            with self.subTest(indice=indice):
                primeira = chamada()
                segunda = chamada()
                self.assertEqual(primeira, segunda)
                self.assertEqual(list(primeira), list(segunda))

    def test_ordem_dos_registros_na_fotografia_nao_muda_o_plano(self) -> None:
        linhas = [l for l in SO_1G.split("\n") if l]
        invertida = "\n".join(reversed(linhas))
        self.assertEqual(
            plano("hugetlb-1g", snapshot=SO_1G, vm_ram_mib=30720),
            plano("hugetlb-1g", snapshot=invertida, vm_ram_mib=30720),
        )

    def test_terminador_final_ausente_nao_muda_nada(self) -> None:
        self.assertEqual(
            resources.parse_snapshot(SO_1G), resources.parse_snapshot(SO_1G.strip("\n"))
        )


class ContratoDeChavesTests(unittest.TestCase):
    """O consumidor em Bash lê campo fixo; chave que some vira leitura vazia."""

    def test_verify_acquire_tem_as_mesmas_chaves_aceitando_e_recusando(self) -> None:
        aceita = prova("acquire", ANTES_AQUISICAO, DEPOIS_AQUISICAO)
        recusas = (
            prova("acquire", ANTES_AQUISICAO, foto(pools=((PAGE_1G, 27, 27),))),
            prova("acquire", ANTES_AQUISICAO, foto(pools=((PAGE_1G, 30, 25),))),
            prova("acquire", ANTES_AQUISICAO, ANTES_AQUISICAO, page_kb=PAGE_2M),
            prova(
                "acquire",
                ANTES_AQUISICAO,
                foto(pools=((PAGE_1G, 30, 30),), memtotal=1),
            ),
        )
        for indice, recusa in enumerate(recusas):
            with self.subTest(indice=indice):
                self.assertEqual(sorted(aceita), sorted(recusa))

    def test_plan_release_tem_as_mesmas_chaves_aceitando_e_recusando(self) -> None:
        aceita = devolucao(foto(pools=((PAGE_1G, 30, 30),)))
        recusas = (
            devolucao(foto(pools=((PAGE_1G, 25, 25),))),
            devolucao(foto(pools=((PAGE_1G, 30, 3),))),
            devolucao(SO_1G, page_kb=PAGE_2M),
        )
        for indice, recusa in enumerate(recusas):
            with self.subTest(indice=indice):
                self.assertEqual(sorted(aceita), sorted(recusa))

    def test_state_tem_as_mesmas_chaves_aceitando_e_recusando(self) -> None:
        aceita = transicao("PREPARED", "acquire")
        recusas = (
            transicao("ACQUIRED", "acquire"),
            transicao("RECOVERY_REQUIRED", "acquire"),
            transicao(
                "ACQUIRED", "prepare", state_boot_id="boot-antigo", boot_id="boot-atual"
            ),
        )
        for indice, recusa in enumerate(recusas):
            with self.subTest(indice=indice):
                self.assertEqual(sorted(aceita), sorted(recusa))

    def test_plan_tem_as_mesmas_chaves_aceitando_e_recusando(self) -> None:
        """Foi defeito até 03/09/2026: a recusa devolvia 11 chaves e o aceite 15.

        Faltavam `baseline_resv`, `baseline_surplus`, `node_count` e
        `fingerprint` em **toda** recusa de `plan`. O `fingerprint` era o pior
        deles: é ele que a devolução compara depois. As cinco rotas de recusa
        entram aqui porque o defeito valia para todas, e o caso de uma só não
        provaria isso.
        """
        aceita = plano("hugetlb-1g", snapshot=SO_1G, vm_ram_mib=30720)
        self.assertEqual(len(aceita), 16)
        recusas = (
            resources.plan({"mode": "invalido"}),
            plano("hugetlb-2m", snapshot=SO_1G, vm_ram_mib=8192),
            plano("hugetlb-1g", snapshot=SO_1G, vm_ram_mib=30721),
            plano("hugetlb-1g", snapshot=foto(pools=((PAGE_1G, 22, 14),)), vm_ram_mib=22528),
            plano("hugetlb-1g", snapshot=HOST_APERTADO, vm_ram_mib=30720),
        )
        for indice, recusa in enumerate(recusas):
            with self.subTest(indice=indice):
                self.assertEqual(recusa["valid"], 0)
                self.assertEqual(sorted(aceita), sorted(recusa))

    def test_plan_recusado_devolve_o_fingerprint_calculado(self) -> None:
        """Achado NOVO-1 de 03/09/2026, corrigido no mesmo dia.

        A primeira correção do contrato de chaves acertou a FORMA e não o
        CONTEÚDO: `fingerprint` e `node_count` passaram a existir na recusa,
        mas com valor neutro, porque a recusa remontava o dicionário do zero e
        descartava o que já tinha sido calculado. Agora a recusa MARCA o
        dicionário existente. Nas rotas que recusam ANTES de ler a fotografia
        (modo desconhecido) o vazio continua sendo a resposta certa, e o caso
        cobre as duas pontas.
        """
        dados = resources.parse_snapshot(SO_1G)
        real = resources.fingerprint(dados)
        pool_parcial = foto(pools=((PAGE_1G, 22, 14),))
        # I9.12: era `foto(pools=((PAGE_1G, 8, 8),))` recusada pelo perfil de
        # reserva estática. Em runtime esse pool curto é aceitável (adquire o
        # delta), então o que recusa aqui é a RAM: 14 páginas de 1 GiB não
        # cabem nos 3,95 GiB de `MemAvailable` deste host.
        pool_curto_sem_ram = foto(
            pools=((PAGE_1G, 8, 8),), memavailable=MEMAVAIL_APERTADA_KB
        )
        depois_de_ler = (
            (plano("hugetlb-2m", snapshot=SO_1G, vm_ram_mib=8192), SO_1G),
            (plano("hugetlb-1g", snapshot=SO_1G, vm_ram_mib=30721), SO_1G),
            (plano("hugetlb-1g", snapshot=pool_parcial, vm_ram_mib=22528), pool_parcial),
            (plano("hugetlb-1g", snapshot=HOST_APERTADO, vm_ram_mib=30720), HOST_APERTADO),
            (
                plano("hugetlb-1g", snapshot=pool_curto_sem_ram, vm_ram_mib=22528),
                pool_curto_sem_ram,
            ),
        )
        for indice, (recusa, fotografia) in enumerate(depois_de_ler):
            with self.subTest(indice=indice):
                esperado = resources.fingerprint(resources.parse_snapshot(fotografia))
                self.assertEqual(recusa["valid"], 0)
                self.assertEqual(recusa["fingerprint"], esperado)
                self.assertEqual(recusa["node_count"], 1)
        # O aceite calcula os dois, então o dado existe e está ao alcance.
        aceite = plano("hugetlb-1g", snapshot=SO_1G, vm_ram_mib=30720)
        self.assertEqual(aceite["fingerprint"], real)
        self.assertEqual(aceite["node_count"], 1)
        # Antes de ler a fotografia, vazio é a resposta certa.
        self.assertEqual(resources.plan({"mode": "invalido"})["fingerprint"], "")

    def test_verify_release_tem_as_mesmas_chaves_aceitando_e_recusando(self) -> None:
        """Foi defeito até 03/09/2026: `baseline_nr` só entrava mais tarde.

        As duas recusas precoces da fase de devolução (fingerprint divergente e
        pool ausente) saíam antes de `dados["baseline_nr"] = baseline_nr`, e a
        mesma fase devolvia 10 ou 11 chaves conforme o motivo da recusa. As duas
        rotas entram aqui porque as duas exibiam o defeito.
        """
        baseline = VerifyDevolucaoTests.BASELINE
        aceita = prova("release", DEPOIS_AQUISICAO, ANTES_AQUISICAO, **baseline)
        recusas = (
            prova(
                "release",
                DEPOIS_AQUISICAO,
                foto(pools=((PAGE_1G, 22, 22),), memtotal=1),
                **baseline,
            ),
            prova(
                "release", ANTES_AQUISICAO, ANTES_AQUISICAO, page_kb=PAGE_2M, **baseline
            ),
            prova(
                "release",
                DEPOIS_AQUISICAO,
                foto(pools=((PAGE_1G, 23, 22),)),
                **baseline,
            ),
        )
        for indice, recusa in enumerate(recusas):
            with self.subTest(indice=indice):
                self.assertEqual(recusa["valid"], 0)
                self.assertEqual(sorted(aceita), sorted(recusa))

    def test_verify_tem_a_mesma_forma_nas_duas_fases(self) -> None:
        """A forma única é o que permite ao Bash ler a resposta sem saber a fase."""
        aquisicao = prova("acquire", ANTES_AQUISICAO, DEPOIS_AQUISICAO)
        devolucao_ = prova(
            "release", DEPOIS_AQUISICAO, ANTES_AQUISICAO, **VerifyDevolucaoTests.BASELINE
        )
        self.assertEqual(sorted(aquisicao), sorted(devolucao_))
        self.assertIn("baseline_nr", aquisicao)


class ComandosDaCliTests(unittest.TestCase):
    """Os wrappers da CLI não podem acrescentar política própria."""

    def test_wrappers_devolvem_o_mesmo_que_as_funcoes(self) -> None:
        plan_payload = {"mode": "hugetlb-1g", "snapshot": SO_1G, "vm_ram_mib": 30720}
        self.assertEqual(
            resources.plan_command(plan_payload), resources.plan(plan_payload)
        )
        verify_payload = {
            "phase": "acquire",
            "before": ANTES_AQUISICAO,
            "after": DEPOIS_AQUISICAO,
            "page_kb": PAGE_1G,
            "delta": 8,
        }
        self.assertEqual(
            resources.verify_command(verify_payload), resources.verify(verify_payload)
        )
        release_payload = {
            "snapshot": foto(pools=((PAGE_1G, 30, 30),)),
            "delta": 8,
            "baseline_nr": 22,
            "page_kb": PAGE_1G,
        }
        self.assertEqual(
            resources.release_plan_command(release_payload),
            resources.plan_release(release_payload),
        )
        state_payload = {"state": "PREPARED", "event": "acquire"}
        self.assertEqual(
            resources.state_command(state_payload), resources.state(state_payload)
        )


class ClassificacaoDeErroTests(unittest.TestCase):
    """Estado do host recusado devolve veredicto; chamada errada levanta."""

    def test_estado_recusado_nao_levanta(self) -> None:
        for chamada in (
            lambda: plano("hugetlb-1g", snapshot=HOST_APERTADO, vm_ram_mib=30720),
            lambda: prova("acquire", ANTES_AQUISICAO, ANTES_AQUISICAO),
            lambda: devolucao(foto(pools=((PAGE_1G, 25, 25),))),
            lambda: transicao("ACQUIRED", "acquire"),
        ):
            with self.subTest(chamada=chamada):
                self.assertEqual(chamada()["valid"], 0)

    def test_fotografia_ou_campo_invalido_levanta(self) -> None:
        for chamada in (
            lambda: plano("hugetlb-1g", snapshot="cgroup\t1", vm_ram_mib=1024),
            lambda: prova("acquire", "cgroup\t1", DEPOIS_AQUISICAO),
            lambda: devolucao("cgroup\t1"),
            lambda: transicao("PREPARED", "start"),
        ):
            with self.subTest(chamada=chamada):
                with self.assertRaises(DataError):
                    chamada()


if __name__ == "__main__":
    unittest.main()
