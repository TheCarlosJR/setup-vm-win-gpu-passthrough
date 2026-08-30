"""Plataforma, imutabilidade e eixos de fabricante (I8.1, I8.2, I8.7, I8.8).

Módulo puro: recebe capturas que o Bash já fez e devolve fatos tipados. Ele
não abre `/etc/os-release`, não executa `uname`, `lscpu` ou `lspci`, não
resolve caminho algum e não consulta o host. Todo caminho que aparecer no
payload é dado inerte: nenhuma função deste arquivo tem como abri-lo, porque
não existe aqui `open`, `os`, `pathlib`, `subprocess` nem `socket`.

Quatro responsabilidades, separadas de propósito:

* **parser** (`os_release_facts`): reproduz linha a linha o comportamento de
  `_plataforma_ler_os_release` (`lib/platform.sh:78-125`), com a mesma
  allowlist fechada, o mesmo desescape de aspas, a mesma recusa de chave
  repetida e as mesmas validações por campo. A malícia do arquivo continua
  inerte porque o conteúdo nunca é executado, apenas comparado com padrões;
* **classificação** (`support_state`): reproduz `_plataforma_detectar_imutabilidade`
  e `_plataforma_classificar_suporte` (`lib/platform.sh:163-230`), incluindo
  os textos de bloqueio, que são oráculo de gate e não podem mudar um byte;
* **eixo de CPU** (`cpu_vendor_fact`, I8.7): modela o fabricante como fato
  tipado a partir de dois snapshots independentes (`/proc/cpuinfo` e `lscpu`),
  com caso explícito de evidência conflitante. Esta fase **modela** o eixo;
  Intel continua bloqueada com a mensagem atual, byte a byte;
* **eixo de GPU** (`gpu_vendor_fact`, I8.8): modela o fabricante PCI como fato
  tipado a partir do snapshot de `lspci -Dnn` e da composição do grupo IOMMU.
  Também apenas modela: só NVIDIA continua suportada.

Estado tipado por campo, nunca default silencioso. Todo fato carrega três
chaves: valor normalizado, `_state` em {`detectado`, `inferido`,
`conflitante`, `ausente`, `desconhecido`} e `_evidence` com a origem da
evidência. Campo que o Bash não capturou vira `ausente`; campo que ficou para
trás porque a leitura abortou vira `desconhecido`, nunca `ausente`.

Contrato de publicação: quando `valid` é 0, **nenhum valor de campo pode ser
publicado** pela fachada. O fato tipado continua completo na resposta, para
que o diagnóstico diga qual campo estava bom e qual quebrou, mas
`_plataforma_ler_os_release` só atribui `PLATAFORMA_ID` e companhia depois de
todas as validações passarem, e é esse comportamento que precisa ser
preservado. Ler `id` com `valid=0` é usar a resposta errado.

Convenção de erro (a mesma de `cpu.py`): entrada estruturalmente inválida
(campo obrigatório ausente, campo fora do schema fechado, tipo errado) levanta
`DataError`, porque é defeito de chamada. Estado de host que simplesmente não
satisfaz a política devolve `valid=0` com `error` preenchido, porque é
diagnóstico para o operador, não falha do protocolo.

Todas as respostas são escalares (texto e inteiro). Nada de lista: a resposta
precisa atravessar o canal de pares `chave\\0valor\\0`, onde cada chave vira
maiúscula e cada valor precisa ser escalar e menor que 64 KiB. É por isso que
`ID_LIKE` viaja como texto mais uma contagem, e por isso nenhum nome de
capability (que tem ponto) pode virar chave de resposta.
"""
from __future__ import annotations

import re
from typing import Any, Iterable, Mapping

from .errors import DataError, InternalError
from .protocol import safe_label

SCHEMA_VERSION = 1

# --- Vocabulário de estado ----------------------------------------------------
# Fechado de propósito: um estado novo é uma decisão de projeto, não um efeito
# colateral de parser.

STATE_DETECTED = "detectado"
STATE_INFERRED = "inferido"
STATE_CONFLICTING = "conflitante"
STATE_ABSENT = "ausente"
STATE_UNKNOWN = "desconhecido"
FACT_STATES = frozenset(
    {STATE_DETECTED, STATE_INFERRED, STATE_CONFLICTING, STATE_ABSENT, STATE_UNKNOWN}
)

# Origem da evidência. Tokens de máquina (seção 3.10): nunca são traduzidos.
EVIDENCE_NONE = "none"
EVIDENCE_NOT_CAPTURED = "not-captured"
EVIDENCE_OS_RELEASE = "os-release"
EVIDENCE_UNAME = "uname-m"
EVIDENCE_VARIANT_ID = "variant-id"
EVIDENCE_OSTREE = "ostree-marker"
EVIDENCE_CPUINFO = "proc-cpuinfo"
EVIDENCE_LSCPU = "lscpu"
EVIDENCE_CPU_BOTH = "proc-cpuinfo+lscpu"
EVIDENCE_LSPCI = "lspci"
EVIDENCE_IOMMU = "iommu-group"
EVIDENCE_SYSTEMD_FIXTURE = "systemd-fixture"
EVIDENCE_SYSTEMCTL_SHOW = "systemctl-show"

# Estado da captura, declarado pelo Bash. Mesmo vocabulário de `inventory.py`
# e do harness de plataforma, para não inventar um terceiro dialeto.
SNAPSHOT_STATES = ("absent", "error", "present", "unavailable")
OS_RELEASE_SOURCE_STATES = ("absent", "present", "unreadable")

# --- Eixo de distribuição -----------------------------------------------------

SUPPORT_SUPPORTED = "supported"
SUPPORT_DIAGNOSTIC = "diagnostic-only"
SUPPORT_FAMILY = "family-unverified"
SUPPORT_BLOCKED = "blocked"

OS_RELEASE_KEYS = ("ID", "ID_LIKE", "VARIANT_ID", "VERSION_ID", "VERSION_CODENAME")
# Ordem de validação idêntica à de `lib/platform.sh:107-121`: o erro publicado
# é sempre o primeiro desta sequência, porque é o que o Bash publica hoje.
OS_RELEASE_FIELDS = (
    ("ID", "id"),
    ("ID_LIKE", "id_like"),
    ("VARIANT_ID", "variant_id"),
    ("VERSION_ID", "version_id"),
    ("VERSION_CODENAME", "version_codename"),
)

SUPPORTED_IDS = ("pop", "ubuntu")
PLANNED_IDS = ("arch", "cachyos", "debian", "fedora", "opensuse-tumbleweed")
# A ordem importa: é a ordem do laço de `lib/platform.sh:220`, e a primeira
# família encontrada é a que aparece na mensagem.
FAMILY_ORDER = ("ubuntu", "debian", "arch", "fedora", "rhel", "opensuse", "suse")
IMMUTABLE_VARIANTS = ("silverblue", "kinoite", "sericea", "onyx", "coreos")
PROFILES = {"ubuntu": "ubuntu", "pop": "pop-os"}
# I8.3: host imutável deixa de ser "sem perfil". Ele tem um perfil, e o perfil é
# diagnóstico: nada de mutação, mas identidade explícita em vez de campo vazio,
# que era indistinguível de "não classificado". O nome vive no canal de máquina
# (seção 3.10), junto de `supported`/`diagnostic-only`/`blocked`, e nunca chega
# ao `case` de atributos do provider, que só é alcançado com suporte pleno.
PROFILE_IMMUTABLE = "immutable-diagnostic"

# Espelho exato de `PLATAFORMA_CAPABILITIES_CONHECIDAS` (`lib/platform.sh:47`).
# São 21 entradas e continuam 21: o alias de I8.8 mora no mapa separado abaixo
# e não infla o array. Trocar o nome canônico é o passo de cutover, não este.
KNOWN_CAPABILITIES = (
    "inventory.write",
    "config.manage",
    "host.update",
    "gpu.driver",
    "packages.base",
    "storage.prepare",
    "virtualization.manage",
    "iommu.configure",
    "domain.create",
    "domain.console",
    "hooks.configure",
    "guest.driver",
    "usb.configure",
    "cpu.tune",
    "network.configure",
    "airlock.configure",
    "trim.configure",
    "backup.create",
    "snapshot.manage",
    "gpu.recover",
    "diagnostic.write",
)
# I8.8 pede `gpu.driver` como nome do eixo de GPU, com `nvidia.driver` aceito
# durante o cutover. Enquanto o canônico do Bash for `nvidia.driver`, o alias
# aponta na direção que preserva o comportamento atual; a inversão acontece no
# commit de cutover, junto com `tests/i1/mutators.tsv` e os chamadores.
# I8.8: o canônico é `gpu.driver`; `nvidia.driver` continua ACEITO como alias
# durante o cutover, e sai em I10. O alias não entra em KNOWN_CAPABILITIES,
# porque a contagem de 21 é conferida pelos testes de I1.
CAPABILITY_ALIASES = {"nvidia.driver": "gpu.driver"}

# --- Eixo de CPU (I8.7) -------------------------------------------------------

CPU_VENDOR_AMD = "AuthenticAMD"
CPU_VENDOR_INTEL = "GenuineIntel"
CPU_VENDORS = {CPU_VENDOR_AMD: "amd", CPU_VENDOR_INTEL: "intel"}
CPU_VENDOR_SUPPORTED = CPU_VENDOR_AMD
CPUINFO_KEY = "vendor_id"
LSCPU_KEY = "Vendor ID"

# --- Eixo de GPU (I8.8) -------------------------------------------------------

GPU_VENDORS = {"10de": "nvidia", "1002": "amd", "8086": "intel"}
GPU_VENDOR_LABELS = {"10de": "NVIDIA", "1002": "AMD", "8086": "Intel"}
GPU_VENDOR_SUPPORTED = "10de"
# Classe PCI 03xx é o controlador de display inteiro (VGA, XGA, 3D, outros).
# Classe 0403 é a função de áudio que acompanha a GPU no mesmo grupo IOMMU.
GPU_DISPLAY_CLASS_PREFIX = "03"
GPU_AUDIO_CLASS = "0403"

# --- Eixo de unidade systemd (I8.6) -------------------------------------------
# REQ-LIBVIRT-BACKEND: a resolução do backend (`libvirtd` monolítico ou
# `virtqemud` modular) é UMA só, e agora ela mora aqui. O Bash continua dono da
# sonda (`systemctl show`, que toca o host) e da leitura do arquivo de fixture;
# a CLASSIFICAÇÃO de cada unidade e o DESEMPATE entre elas passaram a ser
# decisão do core, para que nenhuma etapa possa reimplementá-las.

SERVICE_SOURCE_FIXTURE = "fixture"
SERVICE_SOURCE_PROBE = "probe"
SERVICE_SOURCES = (SERVICE_SOURCE_FIXTURE, SERVICE_SOURCE_PROBE)

# Ações autorizadas, no vocabulário que `ativar_unidade_systemd` consome.
UNIT_ACTION_NONE = "nenhuma"
UNIT_ACTION_ENABLE_NOW = "enable-now"
UNIT_ACTION_START = "start"

UNIT_LOAD_READY = "loaded"
UNIT_ACTIVE_STATES = ("active", "activating")
UNIT_FILE_ENABLE_NOW = ("enabled", "enabled-runtime", "disabled")
UNIT_FILE_START = (
    "static",
    "indirect",
    "generated",
    "linked",
    "linked-runtime",
    "alias",
)

# Escores de `_plataforma_classificar_unidade`, preservados no valor exato: o
# nível operacional domina (ativa vence habilitável vence apenas iniciável) e o
# bônus de socket só desempata dentro do mesmo nível, nunca entre níveis.
SCORE_ACTIVE = 100
SCORE_ENABLE_NOW = 50
SCORE_START = 25
SCORE_SOCKET_BONUS = 1
SOCKET_SUFFIX = ".socket"

# Formato autoritativo da fixture: `NOME|carga|ativo|sub|unitfile`. Continua
# aceito byte a byte, inclusive as tolerâncias do `read` do Bash (campo a menos
# vira vazio, `unitfile` vazio vira `disabled`, comentário e linha em branco
# são ignorados) e a recusa de campo extra.
FIXTURE_SEPARATOR = "|"
FIXTURE_FIELDS = 5
FIXTURE_DEFAULT_UNIT_FILE = "disabled"
# Unidade que a fixture não declara: exatamente o reset de
# `_plataforma_sondar_unidade_fixture`, que é o que o systemd também reporta.
FIXTURE_ABSENT = ("not-found", "inactive", "dead", "")

# Registro da sonda real, na ordem fixa que o Bash produz.
UNIT_RECORD_FIELDS = (
    "unit",
    "load_state",
    "active_state",
    "sub_state",
    "unit_file_state",
)

# --- Limites explícitos -------------------------------------------------------
# Nada trunca em silêncio: passar do limite é recusa tipada, nunca leitura
# parcial. Os valores reais ficam ordens de magnitude abaixo.

MAX_OS_RELEASE_BYTES = 256 * 1024
MAX_SNAPSHOT_BYTES = 1024 * 1024
MAX_LINES = 65536
MAX_PCI_RECORDS = 4096
MAX_IOMMU_RECORDS = 8192
# Campo curto: cabe qualquer token de estado, qualquer BDF e qualquer lixo que
# valha a pena classificar como `desconhecido` em vez de recusar de saída.
MAX_TOKEN_BYTES = 256
MAX_ARCH_LENGTH = 32
# A fixture systemd cabe folgada em 60 KiB (a real tem 4 linhas). O teto é
# menor que `MAX_PAIR_VALUE_BYTES` de propósito: a linha malformada volta
# INTEIRA em `error_field` para que a frase do Bash não mude um byte, e um
# teto maior deixaria a resposta estourar o canal de pares em vez de recusar a
# entrada com erro tipado.
MAX_SERVICE_FIXTURE_BYTES = 60 * 1024
MAX_SERVICE_FIXTURE_LINES = 4096
MAX_SERVICE_UNITS = 64

_ALLOWED_CONTROLS = frozenset({"\n", "\r", "\t"})
# `[[:space:]]` do Bash sob LC_ALL=C, que é o locale do gate.
_BASH_SPACE = " \t\n\v\f\r"

# Padrões idênticos aos de `lib/platform.sh:107-121`. `[[:alnum:]]` é resolvido
# como ASCII porque o gate roda sob LC_ALL=C; sob um locale UTF-8 o Bash
# aceitaria letra acentuada e aqui não. A diferença é fail-closed e nenhuma
# distribuição real depende dela.
_ID = re.compile(r"[a-z0-9][a-z0-9._-]*")
_ID_LIKE = re.compile(r"[a-z0-9._-]+(?:[ \t\v\f]+[a-z0-9._-]+)*")
_VARIANT_ID = re.compile(r"[a-z0-9][a-z0-9._-]*")
_VERSION_ID = re.compile(r"[A-Za-z0-9._-]+")
_VERSION_CODENAME = re.compile(r"[A-Za-z0-9._-]+")
_FIELD_PATTERNS = {
    "ID": _ID,
    "ID_LIKE": _ID_LIKE,
    "VARIANT_ID": _VARIANT_ID,
    "VERSION_ID": _VERSION_ID,
    "VERSION_CODENAME": _VERSION_CODENAME,
}

_ARCH = re.compile(r"[A-Za-z0-9_]{1,%d}" % MAX_ARCH_LENGTH)
_EXPECTED_ARCH = "x86_64"

_BDF = re.compile(r"(?:[0-9a-f]{4}:)?[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]")
_PCI_CLASS = re.compile(r"\[([0-9A-Fa-f]{4})\](?=:)")
_PCI_ID = re.compile(r"\[([0-9A-Fa-f]{4}):([0-9A-Fa-f]{4})\]")
_IOMMU_GROUP = re.compile(r"[0-9]{1,5}")

# Nome de unidade systemd. O alfabeto é o que o systemd aceita em nome de
# unidade (`@` de instância, `\x2d` de escape, `:` de gerador), fechado por
# allowlist: nome que não case não é classificado, é recusado com erro tipado,
# porque quem monta a lista é o perfil e não o host.
_UNIT_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9@:._\\-]{0,127}")

# --- Mensagens humanas --------------------------------------------------------
# As cinco primeiras são oráculo do gate I1 (`tests/test-i1-safety-envelope.sh:42`)
# e precisam sobreviver byte a byte: `CPU GenuineIntel bloqueada`,
# `diagnostic-only`, `não possui provider reconhecido`, `VARIANT_ID=silverblue`
# e `ostree`. Mudar qualquer uma delas reprova o gate, mesmo que o
# comportamento continue correto.

MSG_IMMUTABLE_VARIANT = "VARIANT_ID=%s identifica uma implantação imutável."
MSG_IMMUTABLE_OSTREE = (
    "Uma implantação ostree foi detectada; o host é tratado como imutável."
)
MSG_PLANNED = "ID=%s possui provider planejado, ainda restrito a diagnóstico."
MSG_FAMILY = "ID=%s declara ID_LIKE=%s, mas a derivação não foi verificada."
MSG_BLOCKED = "ID=%s não possui provider reconhecido."
MSG_NOT_SUPPORTED = "Mutação indisponível no nível %s: %s"
MSG_CAPABILITY_PROFILE = "Capability habilitada pelo perfil exato %s."
MSG_INTERNAL_PROFILE = (
    "Falha interna: support level habilitou um perfil sem provider exato (ID=%s)."
)

# O caminho do os-release é `LOCAL_IDENTIFIER` (seção 3.9) e por isso não
# atravessa a ponte. O Python devolve `error_code` mais `error_field` e o
# `lib/platform.sh` renderiza a frase que já publica hoje, com o caminho. Assim
# nenhum byte muda para o operador e nenhum caminho local entra no protocolo.
MSG_OS_RELEASE_MISSING = "os-release ausente ou ilegível."
MSG_OS_RELEASE_TOO_LARGE = "O os-release capturado excede o limite de %d linhas."
MSG_DUPLICATE_KEY = "Chave %s repetida no os-release."
MSG_INVALID_VALUE = "Valor inválido para %s no os-release."
MSG_INVALID_ID = "ID ausente ou inválido no os-release."
MSG_INVALID_FIELD = "%s inválido no os-release."

MSG_CPU_BLOCKED = (
    "CPU %s bloqueada: esta implementação oferece apenas AMD (amd_iommu=on/AMD-Vi). "
    "Intel e outros fabricantes não sofrerão qualquer mutação."
)
MSG_CPU_UNKNOWN = "Fabricante de CPU ausente ou não suportado: %s."
MSG_CPU_CONFLICT = "Mais de um fabricante de CPU foi reportado: %s e %s."
MSG_CPU_PROBE_UNAVAILABLE = "lscpu indisponível para identificar o fabricante da CPU."
MSG_CPU_PROBE_FAILED = "lscpu falhou ao identificar o fabricante da CPU."

MSG_GPU_BLOCKED = (
    "GPU %s bloqueada: esta implementação oferece apenas NVIDIA. O eixo de "
    "fabricante de GPU está modelado, não habilitado."
)
MSG_GPU_ABSENT = "Nenhuma função de vídeo foi encontrada na captura PCI."
MSG_GPU_CONFLICT = "Mais de um fabricante de GPU foi reportado: %s e %s."
MSG_GPU_UNKNOWN = "Fabricante de GPU ausente ou não reconhecido: %s."
MSG_GPU_AUDIO_ONLY = (
    "O grupo IOMMU tem função de áudio sem função de vídeo: o fabricante foi "
    "inferido e nenhuma promessa de retorno da GPU pode ser feita."
)
MSG_GPU_NOT_DISPLAY = "O dispositivo selecionado não é uma função de vídeo."
MSG_GPU_BDF_ABSENT = "O BDF selecionado não aparece na captura PCI."

# Mesma divisão de responsabilidade do os-release: o caminho da fixture e o
# nome do tipo de serviço são `LOCAL_IDENTIFIER`/prosa da fachada e ficam no
# Bash, que rerenderiza a frase com `error_code` e `error_field`. As frases
# abaixo existem para quem lê a resposta do core direto (JSON de diagnóstico).
MSG_UNIT_FIXTURE_MALFORMED = "Fixture systemd malformada: %s"
MSG_UNIT_FIXTURE_DUPLICATE = "Unidade %s repetida na fixture."
MSG_UNIT_NONE = "Nenhuma unidade ativa ou iniciável entre as candidatas: %s."


class _Rejected(Exception):
    """Rejeição de estado do host, com mensagem destinada ao operador.

    Existe pelo mesmo motivo de `_LayoutRejected` em `cpu.py`: separar o que é
    diagnóstico (devolve `valid=0`) do que é defeito de chamada (levanta).
    """

    def __init__(self, message: str, code: str, field: str = "") -> None:
        super().__init__(message)
        self.message = message
        self.code = code
        self.field = field


# --- Coerção de payload -------------------------------------------------------
# Todo valor chega como texto pelo canal de pares. A coerção é explícita e
# fail-closed; nada é interpretado por conversão direta sobre entrada crua.


def _mapping(value: Any, label: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise DataError("%s precisa ser um objeto." % label)
    if any(not isinstance(key, str) for key in value):
        raise DataError("%s contém chave que não é texto." % label)
    return value


def _closed(value: Any, required: Iterable[str], label: str) -> Mapping[str, Any]:
    payload = _mapping(value, label)
    required_set = frozenset(required)
    keys = frozenset(payload.keys())
    missing = sorted(required_set - keys)
    extra = sorted(keys - required_set)
    if missing:
        raise DataError("%s sem campos obrigatórios: %s." % (label, ", ".join(missing)))
    if extra:
        raise DataError(
            "%s contém campos fora do schema fechado: %s."
            % (label, ", ".join(safe_label(item) for item in extra))
        )
    return payload


def _validate_text(value: str, label: str, limit: int) -> str:
    try:
        encoded = value.encode("utf-8")
    except UnicodeEncodeError as error:
        raise DataError("%s contém Unicode inválido." % label) from error
    if len(encoded) > limit:
        raise DataError("%s excede o limite de %d bytes." % (label, limit))
    if "\x00" in value:
        raise DataError("%s contém NUL." % label)
    for character in value:
        if ord(character) < 32 and character not in _ALLOWED_CONTROLS:
            raise DataError("%s contém caractere de controle proibido." % label)
    return value


def _text(
    payload: Mapping[str, Any],
    key: str,
    label: str,
    limit: int,
    allow_empty: bool = True,
) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or (not allow_empty and not value):
        suffix = "" if allow_empty else " não vazio"
        raise DataError(
            "%s.%s precisa ser texto%s." % (label, safe_label(key), suffix)
        )
    return _validate_text(value, "%s.%s" % (label, safe_label(key)), limit)


def _enum(
    payload: Mapping[str, Any], key: str, allowed: Iterable[str], label: str
) -> str:
    value = _text(payload, key, label, MAX_TOKEN_BYTES, allow_empty=False)
    if value not in allowed:
        raise DataError(
            "%s.%s precisa ser um destes valores: %s."
            % (label, safe_label(key), ", ".join(sorted(allowed)))
        )
    return value


def _snapshot(
    payload: Mapping[str, Any],
    text_key: str,
    state_key: str,
    label: str,
    states: Iterable[str],
    limit: int,
    empty_is_state: bool = False,
) -> tuple[str, str]:
    """Par captura/estado, com a mesma coerência exigida por `inventory.py`.

    Declarar `present` sem conteúdo, ou conteúdo fora de `present`, é defeito
    de chamada: o Bash sabe exatamente o que capturou e precisa dizer. A
    exceção é o os-release, onde `empty_is_state` vale: um arquivo que existe
    e está vazio é estado de host legítimo, e o Bash de hoje o lê, não acha
    `ID` e recusa com diagnóstico. Transformar isso em erro de chamada mudaria
    o comportamento.
    """
    state = _enum(payload, state_key, states, label)
    text = _text(payload, text_key, label, limit)
    if state == "present" and not empty_is_state and not text.strip():
        raise DataError(
            "%s.%s declara present sem captura." % (label, safe_label(text_key))
        )
    if state != "present" and text:
        raise DataError(
            "%s.%s fora do estado present carrega dados."
            % (label, safe_label(text_key))
        )
    return text, state


def _fact(target: dict, name: str, value: Any, state: str, evidence: str) -> None:
    """Publica um fato como trio valor/estado/evidência.

    Nenhum fato entra na resposta sem os três: é essa regra que impede o
    default silencioso que I8.1 proíbe.
    """
    if state not in FACT_STATES:
        raise InternalError("Estado de fato desconhecido no core de plataforma.")
    target[name] = value
    target["%s_state" % name] = state
    target["%s_evidence" % name] = evidence


# --- Texto ---------------------------------------------------------------------


def _trim(value: str) -> str:
    return value.strip(_BASH_SPACE)


def _split_lines(text: str, limit: int = MAX_LINES) -> list[str]:
    """Divide como `while IFS= read -r linha || [ -n "$linha" ]`.

    Só `\\n` separa: `str.splitlines` também quebraria em `\\r`, `\\v`, `\\f` e
    em separadores Unicode, o que faria o Python enxergar linhas que o Bash
    nunca enxergou. O último bloco sem newline final continua sendo linha.
    """
    if not text:
        return []
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    if len(lines) > limit:
        raise _Rejected(
            MSG_OS_RELEASE_TOO_LARGE % limit, "capture_too_large"
        )
    return lines


def _decode_value(raw: str) -> str | None:
    """Desescapa exatamente como `_plataforma_decodificar_valor`.

    Só duas substituições, nesta ordem: `\\"` vira `"` e depois `\\\\` vira
    `\\`. Um desescapador genérico seria diferente: `\\n` continua sendo dois
    caracteres, como no Bash. Aspas simples são literais e nada dentro delas é
    interpretado. Newline ou CR embutido recusa o valor inteiro.
    """
    value = _trim(raw)
    if len(value) >= 2 and value.startswith('"') and value.endswith('"'):
        value = value[1:-1].replace('\\"', '"').replace("\\\\", "\\")
    elif len(value) >= 2 and value.startswith("'") and value.endswith("'"):
        value = value[1:-1]
    if "\n" in value or "\r" in value:
        return None
    return value


def _scan_os_release(text: str) -> tuple[dict[str, str], tuple[str, str] | None]:
    """Percorre o arquivo como o Bash percorre, e aborta onde ele aborta.

    Chave repetida e valor indecodificável interrompem a leitura na mesma
    linha em que o Bash interrompe. Por isso os campos que ficaram para trás
    não podem ser reportados como `ausente`: eles são `desconhecido`.
    """
    values: dict[str, str] = {}
    for raw_line in _split_lines(text):
        line = raw_line[:-1] if raw_line.endswith("\r") else raw_line
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        name, _, raw_value = line.partition("=")
        key = _trim(name)
        if key not in OS_RELEASE_KEYS:
            continue
        if key in values:
            return values, ("duplicate_key", key)
        decoded = _decode_value(raw_value)
        if decoded is None:
            return values, ("invalid_value", key)
        values[key] = decoded
    return values, None


def _architecture_fact(target: dict, arch_text: str) -> None:
    """Arquitetura vem do snapshot de `uname -m`, nunca do os-release.

    Token bem formado que este projeto não visa continua `detectado`: nós
    sabemos qual é. `desconhecido` fica reservado para snapshot inutilizável,
    que é o caso de um payload com travessia de caminho, por exemplo.
    """
    if not arch_text:
        _fact(target, "arch", "", STATE_ABSENT, EVIDENCE_NONE)
    elif _ARCH.fullmatch(arch_text) is not None:
        _fact(target, "arch", arch_text, STATE_DETECTED, EVIDENCE_UNAME)
    else:
        _fact(target, "arch", "", STATE_UNKNOWN, EVIDENCE_UNAME)
    target["arch_expected"] = 1 if target["arch"] == _EXPECTED_ARCH else 0


def _unknown_os_release(target: dict) -> None:
    for _key, name in OS_RELEASE_FIELDS:
        _fact(target, name, "", STATE_UNKNOWN, EVIDENCE_NONE)
    target["id_like_normalized"] = ""
    target["id_like_count"] = 0


def _os_release_result(text: str, text_state: str, arch_text: str) -> dict:
    result: dict[str, Any] = {}
    _architecture_fact(result, arch_text)
    result["fields_seen"] = 0

    if text_state != "present":
        _unknown_os_release(result)
        result.update(
            valid=0,
            error=MSG_OS_RELEASE_MISSING,
            error_code="os_release_missing",
            error_field="",
        )
        return result

    try:
        values, failure = _scan_os_release(text)
    except _Rejected as rejection:
        _unknown_os_release(result)
        result.update(
            valid=0,
            error=rejection.message,
            error_code=rejection.code,
            error_field=rejection.field,
        )
        return result

    result["fields_seen"] = len(values)
    failing_key = failure[1] if failure else ""
    for key, name in OS_RELEASE_FIELDS:
        if key == failing_key:
            # Duplicata é conflito declarado; valor indecodificável é campo que
            # ninguém consegue interpretar. Nos dois casos o valor não entra.
            state = (
                STATE_CONFLICTING if failure[0] == "duplicate_key" else STATE_UNKNOWN
            )
            _fact(result, name, "", state, EVIDENCE_OS_RELEASE)
        elif key in values:
            value = values[key]
            if _FIELD_PATTERNS[key].fullmatch(value) is not None:
                _fact(result, name, value, STATE_DETECTED, EVIDENCE_OS_RELEASE)
            else:
                _fact(result, name, "", STATE_UNKNOWN, EVIDENCE_OS_RELEASE)
        elif failure is not None:
            # A varredura parou antes de chegar aqui: dizer `ausente` seria
            # afirmar algo que ninguém observou.
            _fact(result, name, "", STATE_UNKNOWN, EVIDENCE_NONE)
        else:
            _fact(result, name, "", STATE_ABSENT, EVIDENCE_NONE)

    raw_id_like = result["id_like"]
    result["id_like_normalized"] = " ".join(raw_id_like.split())
    result["id_like_count"] = len(raw_id_like.split())

    error, code, field = _first_os_release_failure(values, failure)
    result.update(
        valid=0 if code else 1, error=error, error_code=code, error_field=field
    )
    return result


def _first_os_release_failure(
    values: Mapping[str, str], failure: tuple[str, str] | None
) -> tuple[str, str, str]:
    """Reproduz qual falha o Bash publica, e só ela.

    A varredura vem antes das validações por campo, e as validações seguem a
    ordem de `lib/platform.sh:107-121`. Quem publica mensagem diferente da
    primeira falha muda o diagnóstico do operador sem mudar o comportamento.
    """
    if failure is not None:
        code, key = failure
        if code == "duplicate_key":
            return MSG_DUPLICATE_KEY % key, code, key
        return MSG_INVALID_VALUE % key, code, key
    identifier = values.get("ID", "")
    if _ID.fullmatch(identifier) is None:
        return MSG_INVALID_ID, "invalid_id", "ID"
    for key, _name in OS_RELEASE_FIELDS[1:]:
        value = values.get(key, "")
        if value and _FIELD_PATTERNS[key].fullmatch(value) is None:
            return MSG_INVALID_FIELD % key, "invalid_field", key
    return "", "", ""


def os_release_facts(payload: Mapping[str, Any]) -> dict:
    """Normaliza o os-release capturado pelo Bash em fatos tipados (I8.1).

    O conteúdo chega pronto no payload. Um caminho no lugar do conteúdo é só
    texto que não casa com a allowlist: não existe aqui nenhuma função capaz
    de abrir arquivo.
    """
    label = "payload de os-release"
    data = _closed(payload, {"text", "text_state", "arch"}, label)
    text, text_state = _snapshot(
        data,
        "text",
        "text_state",
        label,
        OS_RELEASE_SOURCE_STATES,
        MAX_OS_RELEASE_BYTES,
        empty_is_state=True,
    )
    arch_text = _text(data, "arch", label, MAX_TOKEN_BYTES)
    return _os_release_result(text, text_state, arch_text)


# --- Imutabilidade e suporte ---------------------------------------------------


def _immutability(result: dict, variant_id: str, ostree_evidence: str) -> None:
    """Espelha `_plataforma_detectar_imutabilidade` (`lib/platform.sh:163`).

    `VARIANT_ID` é autoritativo e vem primeiro. A evidência ostree só entra
    quando o Bash a capturou: com fonte de os-release explícita (o caso das 11
    fixtures) ele não olha o marcador, e continuar não olhando preserva o
    comportamento atual. O estado registra que ninguém olhou, o que é
    diferente de ter olhado e não achado.
    """
    if variant_id in IMMUTABLE_VARIANTS:
        result["immutable"] = 1
        result["block_reason"] = MSG_IMMUTABLE_VARIANT % variant_id
        _fact(result, "immutable_source", variant_id, STATE_DETECTED, EVIDENCE_VARIANT_ID)
        return
    if ostree_evidence == "present":
        result["immutable"] = 1
        result["block_reason"] = MSG_IMMUTABLE_OSTREE
        _fact(result, "immutable_source", "ostree", STATE_DETECTED, EVIDENCE_OSTREE)
        return
    result["immutable"] = 0
    result["block_reason"] = ""
    if ostree_evidence == "absent":
        _fact(result, "immutable_source", "", STATE_ABSENT, EVIDENCE_OSTREE)
    else:
        _fact(result, "immutable_source", "", STATE_UNKNOWN, EVIDENCE_NOT_CAPTURED)


def _id_like_contains(id_like: str, family: str) -> bool:
    # `for item in $PLATAFORMA_ID_LIKE` divide por IFS padrão: mesma coisa que
    # `split()` sem argumento.
    return family in id_like.split()


def _classify_support(result: dict) -> None:
    """Espelha `_plataforma_classificar_suporte` (`lib/platform.sh:198`).

    Imutável primeiro, depois provider exato, depois provider planejado,
    depois família por `ID_LIKE`, depois bloqueio. Os textos são oráculo de
    gate: `diagnostic-only` e `não possui provider reconhecido` precisam
    aparecer exatamente assim.
    """
    identifier = result["id"]
    id_like = result["id_like"]
    if result["immutable"] == 1:
        result["support_level"] = SUPPORT_DIAGNOSTIC
        result["mutable"] = 0
        _fact(
            result,
            "support_source",
            identifier,
            STATE_DETECTED,
            result["immutable_source_evidence"],
        )
        return
    if identifier in SUPPORTED_IDS:
        result["support_level"] = SUPPORT_SUPPORTED
        result["mutable"] = 1
        result["block_reason"] = ""
        _fact(result, "support_source", identifier, STATE_DETECTED, EVIDENCE_OS_RELEASE)
        return
    if identifier in PLANNED_IDS:
        result["support_level"] = SUPPORT_DIAGNOSTIC
        result["mutable"] = 0
        result["block_reason"] = MSG_PLANNED % identifier
        _fact(result, "support_source", identifier, STATE_DETECTED, EVIDENCE_OS_RELEASE)
        return
    for family in FAMILY_ORDER:
        if _id_like_contains(id_like, family):
            result["support_level"] = SUPPORT_FAMILY
            result["mutable"] = 0
            result["block_reason"] = MSG_FAMILY % (identifier, id_like)
            # Derivação declarada e não verificada é inferência, não detecção.
            _fact(
                result, "support_source", family, STATE_INFERRED, EVIDENCE_OS_RELEASE
            )
            return
    result["support_level"] = SUPPORT_BLOCKED
    result["mutable"] = 0
    result["block_reason"] = MSG_BLOCKED % identifier
    _fact(result, "support_source", identifier, STATE_DETECTED, EVIDENCE_OS_RELEASE)


def support_state(payload: Mapping[str, Any]) -> dict:
    """Resolve distribuição, imutabilidade, perfil e nível de suporte (I8.2).

    A resposta mapeia um para um as globais que `plataforma_carregar` publica
    hoje, para que a troca de resolver de I8.4 não precise inventar tradução:
    `valid` é `PLATAFORMA_DETECTADA`, `error` é `PLATAFORMA_ERRO`,
    `block_reason` é `PLATAFORMA_BLOQUEIO_MOTIVO`.
    """
    label = "payload de plataforma"
    data = _closed(payload, {"text", "text_state", "arch", "ostree_evidence"}, label)
    text, text_state = _snapshot(
        data,
        "text",
        "text_state",
        label,
        OS_RELEASE_SOURCE_STATES,
        MAX_OS_RELEASE_BYTES,
        empty_is_state=True,
    )
    arch_text = _text(data, "arch", label, MAX_TOKEN_BYTES)
    ostree_evidence = _enum(
        data, "ostree_evidence", ("present", "absent", "not-captured"), label
    )

    result = _os_release_result(text, text_state, arch_text)
    if result["valid"] != 1:
        # Espelha o reset de `_plataforma_resetar_estado`: leitura sem
        # confiança não classifica nada e não publica motivo de bloqueio.
        result["immutable"] = 0
        _fact(result, "immutable_source", "", STATE_UNKNOWN, EVIDENCE_NONE)
        result["support_level"] = SUPPORT_BLOCKED
        result["mutable"] = 0
        result["block_reason"] = ""
        _fact(result, "support_source", "", STATE_UNKNOWN, EVIDENCE_NONE)
        result["profile"] = ""
        result["capability_reason"] = ""
        result["capabilities_known"] = len(KNOWN_CAPABILITIES)
        return result

    _immutability(result, result["variant_id"], ostree_evidence)
    _classify_support(result)

    if result["support_level"] == SUPPORT_SUPPORTED:
        profile = PROFILES.get(result["id"], "")
        if not profile:
            raise InternalError(MSG_INTERNAL_PROFILE % safe_label(result["id"]))
        result["profile"] = profile
        result["capability_reason"] = MSG_CAPABILITY_PROFILE % profile
    elif result["immutable"] == 1:
        result["profile"] = PROFILE_IMMUTABLE
        result["capability_reason"] = result["block_reason"]
        result["error"] = MSG_NOT_SUPPORTED % (
            result["support_level"],
            result["block_reason"],
        )
        result["error_code"] = "not_supported"
    else:
        result["profile"] = ""
        result["capability_reason"] = result["block_reason"]
        result["error"] = MSG_NOT_SUPPORTED % (
            result["support_level"],
            result["block_reason"],
        )
        result["error_code"] = "not_supported"
    result["capabilities_known"] = len(KNOWN_CAPABILITIES)
    return result


def resolve_capability(name: str) -> str:
    """Resolve o nome canônico de uma capability, aceitando o alias do cutover.

    Existe separado do array de 21 nomes de propósito: alias não é capability
    nova, e inflar `PLATAFORMA_CAPABILITIES_CONHECIDAS` mudaria a contagem que
    os testes de I1 conferem.
    """
    if not isinstance(name, str) or not name:
        raise DataError("Capability precisa ser texto não vazio.")
    canonical = CAPABILITY_ALIASES.get(name, name)
    if canonical not in KNOWN_CAPABILITIES:
        raise DataError("Capability desconhecida: %s." % safe_label(name))
    return canonical


# --- Eixo de fabricante de CPU (I8.7) ------------------------------------------


def _key_values(text: str, wanted: str) -> list[str]:
    """Coleta os valores de uma chave em saída `chave: valor`, na ordem lida.

    É o mesmo recorte de `plataforma_detectar_cpu_vendor`: `IFS=:` separa no
    primeiro dois-pontos e o resto da linha é o valor, depois aparado.
    """
    found: list[str] = []
    for line in _split_lines(text):
        if ":" not in line:
            continue
        name, _, value = line.partition(":")
        if _trim(name) != wanted:
            continue
        trimmed = _trim(value)
        if trimmed:
            found.append(trimmed)
    return found


def _distinct(values: Iterable[str]) -> list[str]:
    seen: list[str] = []
    for value in values:
        if value not in seen:
            seen.append(value)
    return seen


def cpu_vendor_fact(payload: Mapping[str, Any]) -> dict:
    """Fabricante de CPU como fato tipado, com duas evidências (I8.7).

    Duas fontes independentes existem para que a divergência entre elas seja
    um estado nomeado e não uma escolha silenciosa. Esta fase modela o eixo:
    `AuthenticAMD` continua sendo o único suportado e a recusa de Intel sai
    com a mesma frase de hoje, que é oráculo do gate I1.
    """
    label = "payload de vendor de CPU"
    data = _closed(
        payload,
        {"cpuinfo_text", "cpuinfo_state", "lscpu_text", "lscpu_state"},
        label,
    )
    cpuinfo_text, cpuinfo_state = _snapshot(
        data, "cpuinfo_text", "cpuinfo_state", label, SNAPSHOT_STATES, MAX_SNAPSHOT_BYTES
    )
    lscpu_text, lscpu_state = _snapshot(
        data, "lscpu_text", "lscpu_state", label, SNAPSHOT_STATES, MAX_SNAPSHOT_BYTES
    )

    # O eco da captura usa sufixo `_capture` de propósito: `_state` é o sufixo
    # reservado ao estado tipado do fato e não pode significar duas coisas.
    result: dict[str, Any] = {
        "cpuinfo_capture": cpuinfo_state,
        "lscpu_capture": lscpu_state,
    }
    try:
        cpuinfo_values = _distinct(_key_values(cpuinfo_text, CPUINFO_KEY))
        lscpu_values = _distinct(_key_values(lscpu_text, LSCPU_KEY))
    except _Rejected as rejection:
        _fact(result, "cpu_vendor", "", STATE_UNKNOWN, EVIDENCE_NONE)
        result.update(
            valid=0,
            error=rejection.message,
            error_code=rejection.code,
            cpu_vendor_family="",
            cpu_vendor_supported=0,
            cpuinfo_vendor="",
            lscpu_vendor="",
            cpuinfo_distinct=0,
            lscpu_distinct=0,
        )
        return result

    result["cpuinfo_vendor"] = cpuinfo_values[0] if cpuinfo_values else ""
    result["lscpu_vendor"] = lscpu_values[0] if lscpu_values else ""
    result["cpuinfo_distinct"] = len(cpuinfo_values)
    result["lscpu_distinct"] = len(lscpu_values)

    conflict: tuple[str, str] | None = None
    if len(cpuinfo_values) > 1:
        conflict = (cpuinfo_values[0], cpuinfo_values[1])
    elif len(lscpu_values) > 1:
        conflict = (lscpu_values[0], lscpu_values[1])
    elif cpuinfo_values and lscpu_values and cpuinfo_values[0] != lscpu_values[0]:
        conflict = (cpuinfo_values[0], lscpu_values[0])

    if conflict is not None:
        _fact(result, "cpu_vendor", "", STATE_CONFLICTING, EVIDENCE_CPU_BOTH)
        result.update(
            valid=0,
            error=MSG_CPU_CONFLICT % conflict,
            error_code="cpu_vendor_conflict",
            cpu_vendor_family="",
            cpu_vendor_supported=0,
        )
        return result

    if cpuinfo_values and lscpu_values:
        vendor, evidence = cpuinfo_values[0], EVIDENCE_CPU_BOTH
    elif cpuinfo_values:
        vendor, evidence = cpuinfo_values[0], EVIDENCE_CPUINFO
    elif lscpu_values:
        vendor, evidence = lscpu_values[0], EVIDENCE_LSCPU
    else:
        vendor, evidence = "", EVIDENCE_NONE

    if not vendor:
        _fact(result, "cpu_vendor", "", STATE_ABSENT, evidence)
        # As duas frases abaixo são as de `lib/platform.sh:695-698` e só valem
        # quando a sonda em si não produziu leitura.
        if cpuinfo_state != "present" and lscpu_state == "unavailable":
            error, code = MSG_CPU_PROBE_UNAVAILABLE, "cpu_probe_unavailable"
        elif cpuinfo_state != "present" and lscpu_state == "error":
            error, code = MSG_CPU_PROBE_FAILED, "cpu_probe_failed"
        else:
            error, code = MSG_CPU_UNKNOWN % STATE_UNKNOWN, "cpu_vendor_unknown"
        result.update(
            valid=0,
            error=error,
            error_code=code,
            cpu_vendor_family="",
            cpu_vendor_supported=0,
        )
        return result

    family = CPU_VENDORS.get(vendor, "")
    if not family:
        _fact(result, "cpu_vendor", vendor, STATE_UNKNOWN, evidence)
        result.update(
            valid=0,
            error=MSG_CPU_UNKNOWN % vendor,
            error_code="cpu_vendor_unknown",
            cpu_vendor_family="",
            cpu_vendor_supported=0,
        )
        return result

    _fact(result, "cpu_vendor", vendor, STATE_DETECTED, evidence)
    result["cpu_vendor_family"] = family
    if vendor == CPU_VENDOR_SUPPORTED:
        result.update(valid=1, error="", error_code="", cpu_vendor_supported=1)
    else:
        # Modelar, não habilitar: o vendor foi detectado com confiança, e
        # mesmo assim a recusa continua exatamente a de hoje.
        result.update(
            valid=1,
            error=MSG_CPU_BLOCKED % vendor,
            error_code="cpu_vendor_blocked",
            cpu_vendor_supported=0,
        )
    return result


# --- Eixo de fabricante de GPU (I8.8) ------------------------------------------


def _normalize_bdf(value: str) -> str:
    lowered = value.strip().lower()
    if _BDF.fullmatch(lowered) is None:
        raise _Rejected("BDF inválido na captura PCI.", "pci_invalid_bdf")
    return lowered if lowered.count(":") == 2 else "0000:" + lowered


def _parse_pci(text: str) -> list[dict]:
    """Interpreta `LC_ALL=C lspci -Dnn`, com o mesmo recorte de `inventory.py`.

    A classe vem de `[XXXX]:` e o par vendor/device do último `[XXXX:XXXX]` da
    linha, porque o nome comercial do produto também vem entre colchetes.
    """
    records: list[dict] = []
    seen: set[str] = set()
    for line in _split_lines(text):
        if not line.strip():
            continue
        pieces = line.split()
        bdf = _normalize_bdf(pieces[0])
        classes = _PCI_CLASS.findall(line)
        ids = _PCI_ID.findall(line)
        if len(classes) != 1 or not ids:
            raise _Rejected(
                "Linha PCI sem classe e vendor:device únicos.", "pci_malformed"
            )
        if bdf in seen:
            raise _Rejected("BDF duplicado na captura PCI.", "pci_duplicate_bdf")
        seen.add(bdf)
        records.append(
            {
                "bdf": bdf,
                "class": classes[0].lower(),
                "vendor": ids[-1][0].lower(),
                "device": ids[-1][1].lower(),
            }
        )
        if len(records) > MAX_PCI_RECORDS:
            raise _Rejected(
                "A captura PCI excede o limite de %d dispositivos."
                % MAX_PCI_RECORDS,
                "pci_too_large",
            )
    # Ordem por BDF, como em `inventory.py`: reordenar a captura não pode
    # mudar qual fabricante aparece primeiro em uma mensagem de conflito.
    records.sort(key=lambda item: tuple(int(part, 16) for part in re.split(r"[:.]", item["bdf"])))
    return records


def _parse_iommu(text: str) -> dict[str, str]:
    """Interpreta linhas `<grupo> <bdf>` capturadas de `/sys/kernel/iommu_groups`.

    O Bash resolve os links simbólicos e entrega pares literais; aqui só existe
    texto. Grupo fora da faixa ou BDF inválido é recusa tipada, nunca um
    dispositivo silenciosamente fora de grupo.
    """
    groups: dict[str, str] = {}
    for line in _split_lines(text):
        if not line.strip():
            continue
        pieces = line.split()
        if len(pieces) != 2:
            raise _Rejected(
                "Linha de grupo IOMMU com campos inesperados.", "iommu_malformed"
            )
        group, bdf_text = pieces
        if _IOMMU_GROUP.fullmatch(group) is None:
            raise _Rejected("Grupo IOMMU inválido na captura.", "iommu_invalid_group")
        bdf = _normalize_bdf(bdf_text)
        if bdf in groups:
            raise _Rejected("BDF duplicado na captura de grupos IOMMU.", "iommu_duplicate")
        groups[bdf] = str(int(group, 10))
        if len(groups) > MAX_IOMMU_RECORDS:
            raise _Rejected(
                "A captura de grupos IOMMU excede o limite de %d entradas."
                % MAX_IOMMU_RECORDS,
                "iommu_too_large",
            )
    return groups


def _is_display(record: Mapping[str, Any]) -> bool:
    return str(record["class"]).startswith(GPU_DISPLAY_CLASS_PREFIX)


def _is_audio(record: Mapping[str, Any]) -> bool:
    return record["class"] == GPU_AUDIO_CLASS


def _gpu_blank(result: dict, state: str, evidence: str, error: str, code: str) -> dict:
    _fact(result, "gpu_vendor", "", state, evidence)
    result.update(
        valid=0,
        error=error,
        error_code=code,
        gpu_vendor_label="",
        gpu_vendor_family="",
        gpu_vendor_supported=0,
    )
    return result


def _gpu_publish(result: dict, vendor: str, state: str, evidence: str) -> dict:
    if vendor not in GPU_VENDORS:
        # Vendor PCI legítimo que este projeto não modela: o eixo diz
        # `desconhecido` em vez de fingir que reconheceu.
        return _gpu_blank(
            result,
            STATE_UNKNOWN,
            evidence,
            MSG_GPU_UNKNOWN % vendor,
            "gpu_vendor_unknown",
        )
    _fact(result, "gpu_vendor", vendor, state, evidence)
    result["gpu_vendor_label"] = GPU_VENDOR_LABELS[vendor]
    result["gpu_vendor_family"] = GPU_VENDORS[vendor]
    if state == STATE_INFERRED:
        # Sem função de vídeo não existe entrega nem retomada, então nenhuma
        # inferência promove fabricante algum.
        result.update(
            valid=1,
            error=MSG_GPU_AUDIO_ONLY,
            error_code="gpu_audio_only",
            gpu_vendor_supported=0,
        )
        return result
    if vendor == GPU_VENDOR_SUPPORTED:
        result.update(valid=1, error="", error_code="", gpu_vendor_supported=1)
    else:
        # Modelar, não habilitar: fabricante reconhecido e ainda assim recusado.
        result.update(
            valid=1,
            error=MSG_GPU_BLOCKED % GPU_VENDOR_LABELS[vendor],
            error_code="gpu_vendor_blocked",
            gpu_vendor_supported=0,
        )
    return result


def gpu_vendor_fact(payload: Mapping[str, Any]) -> dict:
    """Fabricante de GPU como fato tipado, com grupo IOMMU (I8.8).

    `bdf` vazio pede varredura da captura inteira; `bdf` preenchido pergunta
    sobre o dispositivo já escolhido pelo operador. O BDF é
    `LOCAL_IDENTIFIER` (seção 3.9) e por isso nunca aparece em mensagem: as
    frases falam do dispositivo selecionado, não do endereço dele.
    """
    label = "payload de vendor de GPU"
    data = _closed(
        payload,
        {"pci_text", "pci_state", "iommu_text", "iommu_state", "bdf"},
        label,
    )
    pci_text, pci_state = _snapshot(
        data, "pci_text", "pci_state", label, SNAPSHOT_STATES, MAX_SNAPSHOT_BYTES
    )
    iommu_text, iommu_state = _snapshot(
        data, "iommu_text", "iommu_state", label, SNAPSHOT_STATES, MAX_SNAPSHOT_BYTES
    )
    selected = _text(data, "bdf", label, MAX_TOKEN_BYTES)

    result: dict[str, Any] = {
        "pci_capture": pci_state,
        "iommu_capture": iommu_state,
        "gpu_count": 0,
        "gpu_vendor_count": 0,
        "iommu_group": "",
    }
    try:
        chosen_bdf = ""
        if selected:
            if _BDF.fullmatch(selected.lower()) is None:
                raise _Rejected("BDF selecionado inválido.", "gpu_invalid_selection")
            chosen_bdf = _normalize_bdf(selected)
        records = _parse_pci(pci_text)
        groups = _parse_iommu(iommu_text)
    except _Rejected as rejection:
        return _gpu_blank(
            result, STATE_UNKNOWN, EVIDENCE_NONE, rejection.message, rejection.code
        )

    displays = [record for record in records if _is_display(record)]
    result["gpu_count"] = len(displays)
    result["gpu_vendor_count"] = len(_distinct(record["vendor"] for record in displays))

    if chosen_bdf:
        return _gpu_selected(result, chosen_bdf, records, groups)
    return _gpu_survey(result, records, displays, groups)


def _gpu_survey(
    result: dict, records: list[dict], displays: list[dict], groups: Mapping[str, str]
) -> dict:
    vendors = _distinct(record["vendor"] for record in displays)
    if len(vendors) > 1:
        return _gpu_blank(
            result,
            STATE_CONFLICTING,
            EVIDENCE_LSPCI,
            MSG_GPU_CONFLICT
            % (
                GPU_VENDOR_LABELS.get(vendors[0], vendors[0]),
                GPU_VENDOR_LABELS.get(vendors[1], vendors[1]),
            ),
            "gpu_vendor_conflict",
        )
    if len(vendors) == 1:
        return _gpu_publish(result, vendors[0], STATE_DETECTED, EVIDENCE_LSPCI)
    inferred = _infer_from_audio(result, records, groups, "")
    if inferred is not None:
        return inferred
    return _gpu_blank(
        result, STATE_ABSENT, EVIDENCE_LSPCI, MSG_GPU_ABSENT, "gpu_absent"
    )


def _gpu_selected(
    result: dict, selected: str, records: list[dict], groups: Mapping[str, str]
) -> dict:
    chosen = None
    for record in records:
        if record["bdf"] == selected:
            chosen = record
            break
    if chosen is None:
        return _gpu_blank(
            result, STATE_ABSENT, EVIDENCE_LSPCI, MSG_GPU_BDF_ABSENT, "gpu_bdf_absent"
        )
    result["iommu_group"] = groups.get(selected, "")
    if _is_display(chosen):
        return _gpu_publish(result, chosen["vendor"], STATE_DETECTED, EVIDENCE_LSPCI)
    if _is_audio(chosen):
        inferred = _infer_from_audio(result, records, groups, selected)
        if inferred is not None:
            return inferred
    return _gpu_blank(
        result, STATE_UNKNOWN, EVIDENCE_LSPCI, MSG_GPU_NOT_DISPLAY, "gpu_not_display"
    )


def _infer_from_audio(
    result: dict,
    records: list[dict],
    groups: Mapping[str, str],
    selected: str,
) -> dict | None:
    """Função de áudio sem função de vídeo no mesmo grupo IOMMU.

    Vale como evidência do fabricante, e apenas disso. Se o grupo tem uma
    função de vídeo, o fato deixa de ser inferido e passa a vir dela.
    """
    candidates = [record for record in records if _is_audio(record)]
    if selected:
        candidates = [record for record in candidates if record["bdf"] == selected]
    for audio in candidates:
        group = groups.get(audio["bdf"], "")
        members = [
            record
            for record in records
            if group and groups.get(record["bdf"], "") == group
        ]
        display_members = [record for record in members if _is_display(record)]
        if display_members:
            result["iommu_group"] = group
            return _gpu_publish(
                result, display_members[0]["vendor"], STATE_DETECTED, EVIDENCE_IOMMU
            )
        if audio["vendor"] in GPU_VENDORS:
            result["iommu_group"] = group
            return _gpu_publish(
                result, audio["vendor"], STATE_INFERRED, EVIDENCE_IOMMU
            )
    return None


# --- Eixo de unidade systemd (I8.6) --------------------------------------------
# `plataforma_resolver_servico` deixou de escolher. O Bash captura (fixture ou
# `systemctl show`) e chama uma vez; a classificação e o desempate acontecem
# aqui, num lugar só, para que `libvirt_backend_resolver` e as etapas que
# ativam unidade consumam a MESMA decisão. Nada aqui toca o host: as duas
# fontes chegam como texto inerte no payload.


def _service_fixture_fields(line: str) -> tuple[list[str], str]:
    """Reproduz `IFS='|' read -r nome carga ativo sub unitfile extra`.

    O Bash divide em cinco campos e joga TODO o resto no sexto, separadores
    inclusive, com uma exceção que decide o caso mais comum: se o resto contém
    exatamente um separador e ele é o último caractere, `read` o consome junto
    com a palavra e o sexto campo fica vazio. É por isso que
    `NOME|a|b|c|d|` é linha válida e `NOME|a|b|c|d||` não é.
    """
    parts = line.split(FIXTURE_SEPARATOR)
    head = parts[:FIXTURE_FIELDS]
    head = head + [""] * (FIXTURE_FIELDS - len(head))
    remainder = FIXTURE_SEPARATOR.join(parts[FIXTURE_FIELDS:])
    extra = "" if remainder in ("", FIXTURE_SEPARATOR) else remainder
    return head, extra


def _service_fixture_lines(text: str) -> list[str]:
    """Divide como `while IFS= read -r linha || [ -n "$linha" ]`."""
    if not text:
        return []
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    if len(lines) > MAX_SERVICE_FIXTURE_LINES:
        raise DataError(
            "A fixture systemd excede o limite de %d linhas."
            % MAX_SERVICE_FIXTURE_LINES
        )
    return lines


def _service_fixture_state(lines: list[str], unit: str) -> tuple[str, str, str, str]:
    """Estado de UMA unidade na fixture autoritativa.

    Varre a fixture inteira por unidade, como `_plataforma_sondar_unidade_fixture`
    fazia: é essa varredura que faz uma linha malformada em qualquer posição
    reprovar já na primeira unidade consultada, e uma duplicata reprovar só
    quando a unidade repetida é a consultada. A ordem das duas recusas é
    observável e por isso é preservada.
    """
    load, active, sub, unit_file = FIXTURE_ABSENT
    seen = 0
    for line in lines:
        if not line or line.startswith("#"):
            continue
        fields, extra = _service_fixture_fields(line)
        if extra:
            raise _Rejected(
                MSG_UNIT_FIXTURE_MALFORMED % line, "fixture_malformed", line
            )
        if fields[0] != unit:
            continue
        seen += 1
        if seen > 1:
            raise _Rejected(
                MSG_UNIT_FIXTURE_DUPLICATE % unit, "fixture_duplicate", unit
            )
        load, active, sub = fields[1], fields[2], fields[3]
        # Só a fixture aplica este default. A sonda real NÃO o aplica: lá,
        # `UnitFileState` vazio significa "sem arquivo de unidade" e a unidade
        # é descartada. Uniformizar os dois mudaria comportamento.
        unit_file = fields[4] or FIXTURE_DEFAULT_UNIT_FILE
    return load, active, sub, unit_file


def _classify_unit(
    unit: str, load_state: str, active_state: str, unit_file_state: str
) -> tuple[int, str] | None:
    """Escore e ação de uma unidade, ou `None` quando ela não concorre.

    Espelho exato de `_plataforma_classificar_unidade`: unidade que não está
    `loaded` não concorre; unidade ativa (ou ativando) não pede ação nenhuma;
    unidade com arquivo habilitável pede `enable-now`; unidade sem arquivo
    próprio, mas iniciável, pede `start`; qualquer outro `UnitFileState` não
    concorre. O bônus de socket é +1 e por isso jamais atravessa nível.
    """
    if load_state != UNIT_LOAD_READY:
        return None
    bonus = SCORE_SOCKET_BONUS if unit.endswith(SOCKET_SUFFIX) else 0
    if active_state in UNIT_ACTIVE_STATES:
        return SCORE_ACTIVE + bonus, UNIT_ACTION_NONE
    if unit_file_state in UNIT_FILE_ENABLE_NOW:
        return SCORE_ENABLE_NOW + bonus, UNIT_ACTION_ENABLE_NOW
    if unit_file_state in UNIT_FILE_START:
        return SCORE_START + bonus, UNIT_ACTION_START
    return None


def _service_scalar(value: str, label: str) -> str:
    """Campo de registro do canal de pares: escalar sem caractere de controle.

    `\\t` e `\\n` são separadores estruturais e `\\r` esconderia diferença
    invisível num estado systemd, então nenhum deles pode aparecer dentro de
    um campo.
    """
    for character in value:
        if ord(character) < 32 or ord(character) == 127:
            raise DataError("%s contém caractere de controle." % label)
    if len(value.encode("utf-8")) > MAX_TOKEN_BYTES:
        raise DataError("%s excede o limite de %d bytes." % (label, MAX_TOKEN_BYTES))
    return value


def _service_unit_order(text: str, label: str) -> list[str]:
    """Ordem de desempate: as unidades candidatas, na ordem que o Bash montou."""
    if not text:
        return []
    units = text.split("\n")
    if len(units) > MAX_SERVICE_UNITS:
        raise DataError(
            "%s.unit_order excede o limite de %d unidades." % (label, MAX_SERVICE_UNITS)
        )
    seen: set[str] = set()
    for index, unit in enumerate(units):
        item = "%s.unit_order[%d]" % (label, index)
        _service_scalar(unit, item)
        if _UNIT_NAME.fullmatch(unit) is None:
            raise DataError("%s não é um nome de unidade systemd." % item)
        if unit in seen:
            raise DataError("%s repete a unidade %s." % (item, safe_label(unit)))
        seen.add(unit)
    return units


def _service_unit_records(text: str, label: str) -> list[dict]:
    """Registros da sonda: `\\n` entre registros, `\\t` entre campos."""
    if not text:
        return []
    lines = text.split("\n")
    if len(lines) > MAX_SERVICE_UNITS:
        raise DataError(
            "%s.unit_states excede o limite de %d registros."
            % (label, MAX_SERVICE_UNITS)
        )
    records: list[dict] = []
    for index, line in enumerate(lines):
        item = "%s.unit_states[%d]" % (label, index)
        if not line:
            raise DataError("%s: registro vazio no canal de pares." % item)
        parts = line.split("\t")
        if len(parts) != len(UNIT_RECORD_FIELDS):
            raise DataError(
                "%s: registro com %d campos; o schema exige %d."
                % (item, len(parts), len(UNIT_RECORD_FIELDS))
            )
        record: dict = {}
        for name, raw in zip(UNIT_RECORD_FIELDS, parts):
            record[name] = _service_scalar(raw, "%s.%s" % (item, name))
        records.append(record)
    return records


def _service_blank(
    result: dict, evidence: str, error: str, code: str, field: str
) -> dict:
    """Recusa: nenhum campo de decisão é publicado, e o fato fica tipado."""
    _fact(result, "resolved_unit", "", STATE_ABSENT, evidence)
    result.update(
        valid=0,
        error=error,
        error_code=code,
        error_field=field,
        resolved_service="",
        resolved_action="",
        resolved_score=0,
    )
    return result


def service_unit_choice(payload: Mapping[str, Any]) -> dict:
    """Backend systemd autoritativo: classifica e desempata (I8.6).

    Entrada em schema fechado, com as duas fontes que o Bash sabe capturar:

    * `unit_order`: as unidades candidatas, já expandidas em `.socket` e
      `.service` pelo perfil, na ordem em que o Bash as consultaria. É essa
      ordem que decide o empate residual, porque o desempate é `>` estrito;
    * `service_source`: `fixture` quando a fonte autoritativa é o arquivo de
      teste, `probe` quando é `systemctl show`. Fonte declarada, nunca
      adivinhada por presença de campo;
    * `fixture_text`: a fixture `NOME|carga|ativo|sub|unitfile` inteira;
    * `unit_states`: um registro por unidade de `unit_order`, na mesma ordem,
      com os quatro valores que a sonda leu.

    Devolve a unidade escolhida, o serviço (o nome até o primeiro ponto, como
    `${unidade%%.*}`), a ação autorizada e o escore vencedor. Fixture
    malformada e unidade repetida são `valid=0` com código próprio, porque são
    estado de dado e não defeito de protocolo; nenhuma candidata elegível
    também é `valid=0`, e é a fachada que decide que isso é pendência (1) e
    não erro operacional (2).
    """
    label = "payload de resolução de unidade systemd"
    data = _closed(
        payload,
        {"service_source", "unit_order", "fixture_text", "unit_states"},
        label,
    )
    source = _enum(data, "service_source", SERVICE_SOURCES, label)
    order_text = _text(
        data, "unit_order", label, MAX_TOKEN_BYTES * MAX_SERVICE_UNITS
    )
    fixture_text = _text(data, "fixture_text", label, MAX_SERVICE_FIXTURE_BYTES)
    states_text = _text(
        data, "unit_states", label, MAX_TOKEN_BYTES * len(UNIT_RECORD_FIELDS) * MAX_SERVICE_UNITS
    )
    units = _service_unit_order(order_text, label)
    records = _service_unit_records(states_text, label)

    if source == SERVICE_SOURCE_FIXTURE:
        if records:
            raise DataError(
                "%s: a fonte fixture não aceita registros de sonda." % label
            )
        evidence = EVIDENCE_SYSTEMD_FIXTURE
    else:
        if fixture_text:
            raise DataError("%s: a fonte probe não aceita texto de fixture." % label)
        if len(records) != len(units):
            raise DataError(
                "%s: a sonda trouxe %d registros para %d unidades."
                % (label, len(records), len(units))
            )
        for index, unit in enumerate(units):
            if records[index]["unit"] != unit:
                raise DataError(
                    "%s.unit_states[%d] não corresponde à unidade candidata."
                    % (label, index)
                )
        evidence = EVIDENCE_SYSTEMCTL_SHOW

    result: dict[str, Any] = {
        "service_source": source,
        "unit_count": len(units),
    }
    lines = _service_fixture_lines(fixture_text)
    best_score = -1
    best_unit = ""
    best_action = ""
    for index, unit in enumerate(units):
        if source == SERVICE_SOURCE_FIXTURE:
            try:
                load, active, _sub, unit_file = _service_fixture_state(lines, unit)
            except _Rejected as rejection:
                return _service_blank(
                    result,
                    evidence,
                    rejection.message,
                    rejection.code,
                    rejection.field,
                )
        else:
            record = records[index]
            load = record["load_state"]
            active = record["active_state"]
            unit_file = record["unit_file_state"]
        verdict = _classify_unit(unit, load, active, unit_file)
        if verdict is None:
            continue
        score, action = verdict
        # `>` estrito: em empate de escore vence quem o perfil listou antes.
        if score > best_score:
            best_score, best_unit, best_action = score, unit, action

    if not best_unit:
        return _service_blank(
            result, evidence, MSG_UNIT_NONE % " ".join(units), "no_unit", ""
        )

    _fact(result, "resolved_unit", best_unit, STATE_DETECTED, evidence)
    result.update(
        valid=1,
        error="",
        error_code="",
        error_field="",
        resolved_service=best_unit.split(".", 1)[0],
        resolved_action=best_action,
        resolved_score=best_score,
    )
    return result
