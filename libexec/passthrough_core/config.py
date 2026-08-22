"""Schema, parser e serializador de `passthrough.conf` (seções 3.3 e 3.9).

Módulo puro: recebe o texto do arquivo, devolve fatos tipados ou o texto de um
candidato. Quem abre, publica e revalida o arquivo é a CLI, no único caminho de
persistência autorizado pela seção 2.2 (configuração do usuário, sem `sudo`).

Três invariantes governam tudo aqui:

* o arquivo é **dado**, nunca código: nada é executado, nem interpolado, nem
  expandido. `$(...)`, backtick, `${...}` e diretivas shell são recusados;
* o schema é **fechado**: chave desconhecida, repetida, literal malformado ou
  valor fora do tipo é erro tipado, com arquivo/linha/chave/classe no
  diagnóstico e **sem o valor bruto**;
* comentários, linhas vazias, ordem e a política de newline final são
  preservados byte a byte no que não foi pedido para mudar.

Divergência deliberada registrada: os validadores de nome usam classes ASCII
explícitas. O Bash usava `[[:alnum:]]`, que sob locale UTF-8 aceitaria letras
acentuadas; o gate sempre roda em `LC_ALL=C`, onde `[[:alnum:]]` já é ASCII.
Adotar ASCII fecha o schema em vez de deixá-lo depender do locale do operador.
"""
from __future__ import annotations

import re
from typing import Any, Callable, Mapping

from .errors import DataError
from .protocol import safe_label

# --- Classificação de dados (seção 3.9) --------------------------------------
# Campo novo ou desconhecido assume SECRET até revisão: é o default fail-closed
# exigido por I4.1. Nenhuma chave deste schema é SECRET hoje, e isso é um fato
# do domínio, não descuido: o projeto não guarda senha, token nem chave privada
# no `passthrough.conf`. Chave/senha do Airlock vivem em arquivos do SSH.
SECRET = "SECRET"
LOCAL_IDENTIFIER = "LOCAL_IDENTIFIER"
RECOVERY_LOCATOR = "RECOVERY_LOCATOR"
PUBLIC = "PUBLIC"

DATA_CLASSES = (SECRET, LOCAL_IDENTIFIER, RECOVERY_LOCATOR, PUBLIC)
DEFAULT_DATA_CLASS = SECRET

MAX_DOCUMENT_BYTES = 256 * 1024
MAX_LINES = 4096
MAX_VALUE_LENGTH = 4096

# --- Validadores de valor ----------------------------------------------------
# Cada um espelha exatamente a função homônima de lib/common.sh. Valor vazio
# nunca chega aqui: o parser trata "" como "chave presente e sem valor", que é
# o idioma de reset do projeto.

_USER_NAME = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
_GROUP_NAME = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
_DEDICATED_GROUP = re.compile(r"^vm-passthrough(-[a-z0-9][a-z0-9_-]*)?$")
_LIBVIRT_NAME = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,62}$")
_INTERFACE_NAME = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,14}$")
_SYSTEMD_UNIT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.@:-]{0,254}$")
_PCI_BDF = re.compile(r"^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-7]$")
_PCI_VENDOR_DEVICE = re.compile(r"^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{4}$")
_MAC = re.compile(r"^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$")
_QCOW2_SIZE = re.compile(r"^[1-9][0-9]*[KMGTPE]$")
_CPU_LIST = re.compile(r"^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$")
_DECIMAL = re.compile(r"^[0-9]+$")

# Metacaracteres recusados em caminho absoluto, exatamente como no Bash.
_PATH_FORBIDDEN = set("$`\"'\\;|&<>#") | {"\n", "\r", "\t"}


def _integer_in_range(value: str, minimum: int, maximum: int) -> bool:
    if _DECIMAL.match(value) is None or len(value) > 10:
        return False
    number = int(value, 10)
    return minimum <= number <= maximum


def _safe_absolute_path(value: str) -> bool:
    if not value or len(value) > 4096 or not value.startswith("/"):
        return False
    if any(character in _PATH_FORBIDDEN for character in value):
        return False
    if "/../" in value or value.endswith("/..") or value == "/..":
        return False
    if "/./" in value or value.endswith("/.") or value == "/.":
        return False
    return True


def _vm_artifact_path(value: str) -> bool:
    """Filho direto canônico de `/vm`, sem vírgula (política de `virt-install`)."""
    if not _safe_absolute_path(value):
        return False
    if "," in value or not value.startswith("/vm/"):
        return False
    name = value[len("/vm/") :]
    return bool(name) and "/" not in name


def _ipv4(value: str) -> bool:
    parts = value.split(".")
    if len(parts) != 4:
        return False
    for octet in parts:
        if not 1 <= len(octet) <= 3 or _DECIMAL.match(octet) is None:
            return False
        if int(octet, 10) > 255:
            return False
    return True


def _private_cidr_24(value: str) -> bool:
    if "/" not in value:
        return False
    address, _, prefix = value.rpartition("/")
    if prefix != "24" or not _ipv4(address):
        return False
    first, second, _third, fourth = (int(part, 10) for part in address.split("."))
    if fourth != 0:
        return False
    if first == 10:
        return True
    if first == 172 and 16 <= second <= 31:
        return True
    return first == 192 and second == 168


def _cpu_list(value: str) -> bool:
    """Sem sobreposição, sem intervalo invertido e no máximo 4096 CPUs."""
    if _CPU_LIST.match(value) is None:
        return False
    seen: set[int] = set()
    for part in value.split(","):
        if "-" in part:
            start_text, _, end_text = part.partition("-")
            if not (
                _integer_in_range(start_text, 0, 65535)
                and _integer_in_range(end_text, 0, 65535)
            ):
                return False
            start, end = int(start_text, 10), int(end_text, 10)
        else:
            if not _integer_in_range(part, 0, 65535):
                return False
            start = end = int(part, 10)
        if start > end:
            return False
        for cpu in range(start, end + 1):
            if cpu in seen:
                return False
            seen.add(cpu)
            if len(seen) > 4096:
                return False
    return True


def _enum(*allowed: str) -> Callable[[str], bool]:
    permitted = frozenset(allowed)
    return lambda value: value in permitted


def _pattern(expression: re.Pattern[str]) -> Callable[[str], bool]:
    return lambda value: expression.match(value) is not None


def _ranged(minimum: int, maximum: int) -> Callable[[str], bool]:
    return lambda value: _integer_in_range(value, minimum, maximum)


def _csv_of(expression: re.Pattern[str], max_items: int) -> Callable[[str], bool]:
    """Lista separada por vírgula, sem itens vazios, cada um casando o padrão."""

    def check(value: str) -> bool:
        parts = value.split(",")
        if not parts or len(parts) > max_items:
            return False
        return all(expression.match(part) is not None for part in parts)

    return check


def _dedicated_group(value: str) -> bool:
    return (
        _GROUP_NAME.match(value) is not None
        and _DEDICATED_GROUP.match(value) is not None
    )


# --- Schema fechado ----------------------------------------------------------
# (validador, classe da seção 3.9, descrição do tipo para diagnóstico).
# A ordem desta tupla é a ordem canônica das chaves e é a mesma da allowlist
# histórica de lib/common.sh, para que nenhuma chave desapareça por omissão.

SCHEMA: dict[str, tuple[Callable[[str], bool], str, str]] = {
    "USUARIO_LINUX": (_pattern(_USER_NAME), LOCAL_IDENTIFIER, "nome de usuário"),
    "VM_NAME": (_pattern(_LIBVIRT_NAME), LOCAL_IDENTIFIER, "nome de domínio libvirt"),
    "BOOTLOADER": (_enum("kernelstub", "grub"), PUBLIC, "kernelstub ou grub"),
    "VM_STORAGE_GROUP": (_dedicated_group, PUBLIC, "grupo dedicado vm-passthrough"),
    "GPU_PCI_ID": (_pattern(_PCI_BDF), LOCAL_IDENTIFIER, "endereço PCI dddd:bb:ss.f"),
    "GPU_AUDIO_PCI_ID": (
        _pattern(_PCI_BDF),
        LOCAL_IDENTIFIER,
        "endereço PCI dddd:bb:ss.f",
    ),
    "GPU_VENDOR_DEVICE_ID": (
        _pattern(_PCI_VENDOR_DEVICE),
        LOCAL_IDENTIFIER,
        "vendor:device",
    ),
    "GPU_AUDIO_VENDOR_DEVICE_ID": (
        _pattern(_PCI_VENDOR_DEVICE),
        LOCAL_IDENTIFIER,
        "vendor:device",
    ),
    "IOMMU_GROUP_GPU": (_ranged(0, 65535), LOCAL_IDENTIFIER, "inteiro 0..65535"),
    "USB_CTRL_PCI_IDS": (
        _csv_of(_PCI_BDF, 8),
        LOCAL_IDENTIFIER,
        "lista de endereços PCI separada por vírgula",
    ),
    "USB_CTRL_VENDOR_DEVICE_IDS": (
        _csv_of(_PCI_VENDOR_DEVICE, 8),
        LOCAL_IDENTIFIER,
        "lista vendor:device separada por vírgula",
    ),
    "USB_CTRL_IOMMU_GROUP": (
        _ranged(0, 65535),
        LOCAL_IDENTIFIER,
        "inteiro 0..65535",
    ),
    "DM_SERVICE": (_pattern(_SYSTEMD_UNIT), PUBLIC, "unidade systemd"),
    "NVME_DEVICE": (_safe_absolute_path, LOCAL_IDENTIFIER, "caminho absoluto"),
    "WORKING_DISK_PATH": (_safe_absolute_path, LOCAL_IDENTIFIER, "caminho absoluto"),
    "WORKING_DISK_DISPENSADO": (_enum("sim", "nao"), PUBLIC, "sim ou nao"),
    "HD1_BY_ID_PATH": (_safe_absolute_path, LOCAL_IDENTIFIER, "caminho absoluto"),
    "HD1_DISPENSADO": (_enum("sim", "nao"), PUBLIC, "sim ou nao"),
    "QCOW2_PATH": (_vm_artifact_path, LOCAL_IDENTIFIER, "filho direto de /vm"),
    "QCOW2_TAMANHO": (_pattern(_QCOW2_SIZE), PUBLIC, "tamanho como 250G"),
    "VM_RAM_MB": (_ranged(1024, 1048576), PUBLIC, "inteiro 1024..1048576"),
    "VM_VCPUS": (_ranged(1, 65535), PUBLIC, "inteiro 1..65535"),
    "VM_CORES": (_ranged(1, 65535), PUBLIC, "inteiro 1..65535"),
    "VM_THREADS": (_ranged(1, 65535), PUBLIC, "inteiro 1..65535"),
    "CPUS_VM": (_cpu_list, PUBLIC, "lista de CPUs"),
    "CPUS_HOST": (_cpu_list, PUBLIC, "lista de CPUs"),
    "HUGEPAGES_1G": (_ranged(0, 1048576), PUBLIC, "inteiro 0..1048576"),
    "ISO_WINDOWS": (_vm_artifact_path, LOCAL_IDENTIFIER, "filho direto de /vm"),
    "ISO_VIRTIO": (_vm_artifact_path, LOCAL_IDENTIFIER, "filho direto de /vm"),
    "NVIDIA_DRIVER_EXE": (_vm_artifact_path, LOCAL_IDENTIFIER, "filho direto de /vm"),
    "REDE_MODO": (_enum("bridge", "nat"), PUBLIC, "bridge ou nat"),
    "INTERFACE_FISICA": (
        _pattern(_INTERFACE_NAME),
        LOCAL_IDENTIFIER,
        "nome de interface",
    ),
    "REDE_BRIDGE": (_pattern(_INTERFACE_NAME), LOCAL_IDENTIFIER, "nome de interface"),
    "REDE_LIBVIRT": (_pattern(_LIBVIRT_NAME), LOCAL_IDENTIFIER, "nome de rede libvirt"),
    "REDE_BRIDGE_LIBVIRT": (
        _pattern(_INTERFACE_NAME),
        LOCAL_IDENTIFIER,
        "nome de interface",
    ),
    "REDE_NAT_CIDR": (_private_cidr_24, LOCAL_IDENTIFIER, "CIDR privado /24"),
    "VM_NIC_MAC": (_pattern(_MAC), LOCAL_IDENTIFIER, "MAC aa:bb:cc:dd:ee:ff"),
    "VM_IP_FIXO": (_ipv4, LOCAL_IDENTIFIER, "IPv4"),
    "IP_FIXO_HOST": (_ipv4, LOCAL_IDENTIFIER, "IPv4"),
    "TRANSFER_USER": (_pattern(_USER_NAME), LOCAL_IDENTIFIER, "nome de usuário"),
    "AIRLOCK_DIR": (_safe_absolute_path, LOCAL_IDENTIFIER, "caminho absoluto"),
    "AIRLOCK_BIND": (_safe_absolute_path, LOCAL_IDENTIFIER, "caminho absoluto"),
    "BACKUPS_VM_DIR": (_safe_absolute_path, LOCAL_IDENTIFIER, "caminho absoluto"),
}

KEYS = tuple(SCHEMA)

# --- Dispensas e depreciação (REQ-WAIVERS, decidido em I4.8) ------------------
# As duas chaves que sobraram no schema não são "dispensa de etapa": são escolha
# de configuração entre montagens mutuamente exclusivas, com efeito real e
# testado (etapas 3, 7, 8, 14, 19 e 20). Elas nunca fazem uma etapa relatar
# conclusão sem execução: quando valem "sim", o estado real do host é "este
# fluxo não usa esse recurso", e é isso que o verificador diz.
WAIVER_KEYS = tuple(key for key in KEYS if key.endswith("_DISPENSADO"))

# AIRLOCK_DISPENSADO e BACKUP_DISPENSADO eram aceitas e não alteravam nada:
# nenhum pré-requisito, nenhum status, nenhuma execução. Uma flag que promete
# dispensa e não entrega é pior que a ausência dela, e o plano autoriza
# explicitamente removê-las por migração em vez de inventar semântica nova
# (REQ-WAIVERS: "ou removê-las com migração/depreciação segura"). O parser
# continua ACEITANDO as duas linhas para não derrubar configuração existente,
# mas o valor não é exposto a consumidor algum e a etapa 3 remove as linhas.
DEPRECATED_KEYS: dict[str, str] = {
    "AIRLOCK_DISPENSADO": (
        "nunca alterou pré-requisito, status ou execução da etapa 19; para não "
        "usar o Airlock, basta não executar a etapa, que continua relatando o "
        "estado real"
    ),
    "BACKUP_DISPENSADO": (
        "nunca alterou pré-requisito, status ou execução do backup; a etapa 20 "
        "e util/backup-vm.sh sempre decidiram pelo destino configurado"
    ),
}

# Relações entre chaves que o schema conhece mas não trata como fatais na
# carga: a etapa que possui a relação explica melhor como corrigir. A carga
# reporta o conflito para que nenhuma configuração editada à mão passe calada.
RELATIONS: tuple[tuple[str, str], ...] = (
    ("WORKING_DISK_PATH", "WORKING_DISK_DISPENSADO"),
    ("HD1_BY_ID_PATH", "HD1_DISPENSADO"),
)


def data_class(key: str) -> str:
    """Classe da seção 3.9 para a chave; desconhecida é SECRET (fail-closed)."""
    entry = SCHEMA.get(key)
    return entry[1] if entry is not None else DEFAULT_DATA_CLASS


def validate_value(key: str, value: str) -> None:
    """Valida um valor já decodificado. Valor vazio é sempre aceito (reset)."""
    entry = SCHEMA.get(key)
    if entry is None:
        raise DataError(
            "Chave desconhecida no schema de configuração: %s (classe assumida %s)."
            % (safe_label(key), DEFAULT_DATA_CLASS)
        )
    if value == "":
        return
    if len(value) > MAX_VALUE_LENGTH:
        raise DataError(
            "Valor de %s excede %d caracteres." % (safe_label(key), MAX_VALUE_LENGTH)
        )
    validator, klass, description = entry
    if not validator(value):
        # O valor bruto nunca entra no diagnóstico (I4.2): apenas a chave, o
        # tipo esperado e a classe de dado.
        raise DataError(
            "Valor inválido para %s: esperado %s (classe %s)."
            % (safe_label(key), description, klass)
        )


# --- Decodificação de literais ------------------------------------------------
# Espelha `_decodificar_literal_conf`: aceita "literal" com escapes inertes,
# 'literal' simples e literal não cotado restrito. Nada é executado.

_UNQUOTED_ALLOWED = re.compile(r"^[A-Za-z0-9_./:@,+%=-]*$")
_DOUBLE_ESCAPABLE = frozenset('\\"$`')


def _strip(value: str) -> str:
    return value.strip(" \t\n\r\f\v")


def _remainder_is_comment(rest: str) -> bool:
    trimmed = _strip(rest)
    return trimmed == "" or trimmed.startswith("#")


def decode_literal(raw: str) -> str:
    """Decodifica o lado direito de `CHAVE=`; erro tipado se malformado."""
    text = _strip(raw)
    if text == "":
        return ""
    if text[0] == '"':
        value: list[str] = []
        escaped = False
        for index in range(1, len(text)):
            character = text[index]
            if escaped:
                if character in _DOUBLE_ESCAPABLE:
                    value.append(character)
                    escaped = False
                    continue
                raise DataError("escape não suportado dentro de literal entre aspas")
            if character == "\\":
                escaped = True
            elif character == '"':
                if escaped or not _remainder_is_comment(text[index + 1 :]):
                    raise DataError("conteúdo inesperado depois do literal")
                return "".join(value)
            else:
                value.append(character)
        raise DataError("literal entre aspas duplas não foi fechado")
    if text[0] == "'":
        for index in range(1, len(text)):
            if text[index] == "'":
                if not _remainder_is_comment(text[index + 1 :]):
                    raise DataError("conteúdo inesperado depois do literal")
                return text[1:index]
        raise DataError("literal entre aspas simples não foi fechado")
    bare = _strip(text.split("#", 1)[0])
    if _UNQUOTED_ALLOWED.match(bare) is None:
        raise DataError("literal não cotado contém caractere não permitido")
    return bare


def encode_literal(value: str) -> str:
    """Serializa no subconjunto que `decode_literal` entende, sempre cotado."""
    if not isinstance(value, str):
        raise DataError("Somente texto pode ser serializado na configuração.")
    escaped = []
    for character in value:
        if character in _DOUBLE_ESCAPABLE:
            escaped.append("\\")
        escaped.append(character)
    return '"' + "".join(escaped) + '"'


# --- Documento ---------------------------------------------------------------

_KEY_LINE = re.compile(r"^([A-Z][A-Z0-9_]*)[ \t]*=(.*)$")


def parse_document(
    text: Any, label: str = "configuração", tolerate: Any = ()
) -> dict:
    """Analisa o arquivo inteiro e devolve estrutura e valores.

    Devolve `{"lines": [...], "values": {...}, "order": [...], "invalid": [...],
    "final_newline": bool}`. Cada linha é `{"kind": "key"|"other", ...}` para
    que a reescrita preserve comentários, vazios e ordem sem reinterpretar nada.

    `tolerate` é a única flexibilização do parser estrito e existe para
    REQ-CONF-ISO: as chaves listadas podem estar com literal malformado ou valor
    fora do tipo sem derrubar a leitura, porque a operação em curso vai
    substituí-las. O valor legado **não** é devolvido nem reaproveitado: ele
    entra apenas na lista `invalid`. Chave fora de `tolerate` continua fatal.
    """
    tolerated = frozenset(tolerate if not isinstance(tolerate, str) else tolerate.split("\n"))
    for key in tolerated:
        if key and key not in SCHEMA:
            raise DataError(
                "Chave fora do schema em tolerate: %s." % safe_label(key)
            )
    if not isinstance(text, str):
        raise DataError("O documento de %s precisa chegar como texto." % label)
    if len(text.encode("utf-8", "surrogatepass")) > MAX_DOCUMENT_BYTES:
        raise DataError(
            "O documento de %s excede %d bytes." % (label, MAX_DOCUMENT_BYTES)
        )
    final_newline = text.endswith("\n")
    body = text[:-1] if final_newline else text
    raw_lines = body.split("\n") if body != "" else []
    if len(raw_lines) > MAX_LINES:
        raise DataError(
            "O documento de %s excede %d linhas." % (label, MAX_LINES)
        )
    lines: list[dict] = []
    values: dict[str, str] = {}
    order: list[str] = []
    invalid: list[str] = []
    deprecated: dict[str, int] = {}
    for number, raw in enumerate(raw_lines, start=1):
        if "\x00" in raw:
            raise DataError("linha %d contém NUL; configuração recusada." % number)
        content = _strip(raw)
        if content == "" or content.startswith("#"):
            lines.append({"kind": "other", "text": raw})
            continue
        match = _KEY_LINE.match(content)
        if match is None:
            raise DataError(
                "Linha %d inválida: somente CHAVE=literal é permitido." % number
            )
        key = match.group(1)
        if key in DEPRECATED_KEYS:
            # Aceita sem expor: o valor não chega a consumidor algum e a linha
            # fica marcada para a etapa 3 removê-la na migração.
            if key in deprecated:
                raise DataError(
                    "Chave %s repetida na linha %d." % (safe_label(key), number)
                )
            try:
                legado = decode_literal(match.group(2))
            except DataError:
                legado = ""
            deprecated[key] = 1 if legado else 0
            lines.append({"kind": "key", "text": raw, "key": key})
            continue
        if key not in SCHEMA:
            raise DataError(
                "Chave desconhecida %s na linha %d (classe assumida %s)."
                % (safe_label(key), number, DEFAULT_DATA_CLASS)
            )
        if key in values or key in invalid:
            raise DataError(
                "Chave %s repetida na linha %d." % (safe_label(key), number)
            )
        tolerated_key = key in tolerated
        try:
            value = decode_literal(match.group(2))
        except DataError as error:
            if not tolerated_key:
                raise DataError(
                    "Literal inseguro ou malformado para %s na linha %d: %s."
                    % (safe_label(key), number, error.message)
                ) from error
            invalid.append(key)
            lines.append({"kind": "key", "text": raw, "key": key})
            continue
        try:
            validate_value(key, value)
        except DataError as error:
            if not tolerated_key:
                raise DataError(
                    "%s na linha %d." % (error.message.rstrip("."), number)
                ) from error
            invalid.append(key)
            lines.append({"kind": "key", "text": raw, "key": key})
            continue
        values[key] = value
        order.append(key)
        lines.append({"kind": "key", "text": raw, "key": key})
    return {
        "lines": lines,
        "values": values,
        "order": order,
        "invalid": invalid,
        "deprecated": deprecated,
        "final_newline": final_newline,
    }


def render_document(
    document: Mapping[str, Any],
    updates: Mapping[str, str],
    remove: Any = (),
) -> str:
    """Reescreve o documento aplicando `updates`, preservando todo o resto.

    Uma chave já presente é substituída **na própria linha**, o que preserva
    ordem e vizinhança; o comentário de fim de linha dessa chave é descartado,
    exatamente como o `salvar_conf` histórico fazia. Chave nova vai para o fim.
    A política de newline final é preservada: um arquivo que não terminava em
    newline continua sem terminar, salvo quando ganha linha nova.
    """
    for key, value in updates.items():
        if key not in SCHEMA:
            raise DataError(
                "Chave desconhecida na atualização: %s." % safe_label(key)
            )
        if not isinstance(value, str):
            raise DataError(
                "Valor de %s precisa ser texto na atualização." % safe_label(key)
            )
        validate_value(key, value)
    removals = frozenset(remove if not isinstance(remove, str) else remove.split("\n"))
    for key in removals:
        if key and key not in DEPRECATED_KEYS:
            raise DataError(
                "Somente chave depreciada pode ser removida: %s." % safe_label(key)
            )
        if key in updates:
            raise DataError(
                "Chave %s não pode ser removida e atualizada na mesma operação."
                % safe_label(key)
            )
    lines = list(document["lines"])
    applied: set[str] = set()
    rendered: list[str] = []
    for entry in lines:
        if entry["kind"] == "key" and entry["key"] in removals:
            continue
        if entry["kind"] == "key" and entry["key"] in updates and entry["key"] not in applied:
            key = entry["key"]
            rendered.append("%s=%s" % (key, encode_literal(updates[key])))
            applied.add(key)
            continue
        rendered.append(entry["text"])
    appended = [key for key in updates if key not in applied]
    for key in appended:
        rendered.append("%s=%s" % (key, encode_literal(updates[key])))
    if not rendered:
        return ""
    final_newline = bool(document["final_newline"]) or bool(appended)
    return "\n".join(rendered) + ("\n" if final_newline else "")


# --- Migração pré-parser de ISO legada (REQ-CONF-ISO) ------------------------
# Esta é a única leitura que acontece ANTES do parser estrito. Ela existe porque
# um valor legado inválido (ISO fora de /vm, por exemplo) bloquearia o parser e
# impediria o próprio fluxo de correção. Regras absolutas:
#
#   * lê somente atribuições literais de uma allowlist mínima;
#   * não abre, não resolve, não monta, não copia, não testa existência e não
#     privilegia o caminho legado: ele é texto;
#   * não reaproveita o valor antigo; apenas informa que ele precisa ser
#     substituído;
#   * qualquer linha que não caiba no formato é ignorada em silêncio, porque o
#     parser estrito é quem recusa o arquivo depois.

LEGACY_SCAN_KEYS = ("ISO_WINDOWS", "ISO_VIRTIO")


def legacy_scan(payload: Mapping[str, Any]) -> dict:
    """Classifica as chaves de ISO de um conf legado sem tocar em caminho algum.

    Para cada chave da allowlist mínima devolve `presente`, `vazia`, `valida`
    ou `invalida`, mais a contagem de chaves que exigem novo valor. O conteúdo
    do valor legado nunca é devolvido nem publicado.
    """
    text = payload.get("text")
    if not isinstance(text, str):
        raise DataError("O campo text é obrigatório e precisa ser texto.")
    if len(text.encode("utf-8", "surrogatepass")) > MAX_DOCUMENT_BYTES:
        raise DataError("O documento de configuração legada excede o limite.")
    estados: dict[str, str] = {key: "ausente" for key in LEGACY_SCAN_KEYS}
    duplicadas: dict[str, int] = {key: 0 for key in LEGACY_SCAN_KEYS}
    for raw in text.split("\n"):
        content = _strip(raw)
        if content == "" or content.startswith("#"):
            continue
        match = _KEY_LINE.match(content)
        if match is None:
            continue
        key = match.group(1)
        if key not in LEGACY_SCAN_KEYS:
            continue
        duplicadas[key] += 1
        try:
            value = decode_literal(match.group(2))
        except DataError:
            estados[key] = "invalida"
            continue
        if value == "":
            estados[key] = "vazia"
            continue
        validator = SCHEMA[key][0]
        estados[key] = "valida" if validator(value) else "invalida"
    data: dict[str, Any] = {}
    precisa_migrar = 0
    for key in LEGACY_SCAN_KEYS:
        estado = estados[key]
        if duplicadas[key] > 1:
            estado = "duplicada"
        data["iso_%s_state" % key.lower().replace("iso_", "")] = estado
        if estado in ("invalida", "duplicada"):
            precisa_migrar += 1
    data["needs_migration"] = precisa_migrar
    data["scanned_keys"] = len(LEGACY_SCAN_KEYS)
    return data


# --- Subcomandos puros -------------------------------------------------------


def _require_text(payload: Mapping[str, Any], key: str) -> str:
    value = payload.get(key)
    if not isinstance(value, str):
        raise DataError(
            "O campo %s é obrigatório e precisa ser texto." % safe_label(key)
        )
    return value


def _updates_from_payload(payload: Mapping[str, Any]) -> dict[str, str]:
    """Aceita `updates` aninhado (JSON) ou pares planos `set_<CHAVE>`."""
    raw = payload.get("updates")
    if isinstance(raw, dict):
        return {str(key): value for key, value in raw.items()}
    if raw is not None:
        raise DataError("O campo updates precisa ser um objeto JSON.")
    updates: dict[str, str] = {}
    for key, value in payload.items():
        if not key.startswith("set_"):
            continue
        name = key[len("set_") :].upper()
        if not isinstance(value, str):
            raise DataError(
                "Valor de %s precisa ser texto." % safe_label(key)
            )
        updates[name] = value
    return updates


def inspect_config(payload: Mapping[str, Any]) -> dict:
    """Carrega a configuração e projeta valores e metadados do schema."""
    text = _require_text(payload, "text")
    document = parse_document(text)
    conflicts = []
    for path_key, waiver_key in RELATIONS:
        if document["values"].get(path_key, "") and document["values"].get(
            waiver_key, ""
        ) == "sim":
            conflicts.append("%s+%s" % (path_key, waiver_key))
    data: dict[str, Any] = {
        "key_count": len(SCHEMA),
        "present_count": len(document["values"]),
        "final_newline": 1 if document["final_newline"] else 0,
        "line_count": len(document["lines"]),
        "deprecated_present": len(document["deprecated"]),
        "deprecated_with_value": sum(document["deprecated"].values()),
        "deprecated_keys": "\n".join(sorted(document["deprecated"])),
        "relation_conflicts": len(conflicts),
        "relation_conflict_keys": "\n".join(conflicts),
    }
    for key in KEYS:
        data["value_%s" % key.lower()] = document["values"].get(key, "")
        data["present_%s" % key.lower()] = 1 if key in document["values"] else 0
    return data


def schema_report(payload: Mapping[str, Any]) -> dict:
    """Publica o schema inteiro com a classe de cada chave (seção 3.9)."""
    if payload:
        raise DataError("O subcomando de schema não aceita campos no payload.")
    data: dict[str, Any] = {
        "key_count": len(SCHEMA),
        "waiver_count": len(WAIVER_KEYS),
        "deprecated_count": len(DEPRECATED_KEYS),
        "deprecated_keys": "\n".join(sorted(DEPRECATED_KEYS)),
    }
    for index, key in enumerate(KEYS):
        data["key_%d_name" % index] = key
        data["key_%d_class" % index] = SCHEMA[key][1]
    for index, key in enumerate(WAIVER_KEYS):
        data["waiver_%d_name" % index] = key
    return data


def validate_pair(payload: Mapping[str, Any]) -> dict:
    """Valida um par chave/valor contra o schema, sem tocar arquivo algum.

    Existe para que `validar_valor_conf` no shell continue sendo API pública sem
    reimplementar o schema. O valor bruto nunca aparece na resposta nem no
    diagnóstico: só a chave, a classe e o veredito.
    """
    key = _require_text(payload, "key")
    value = payload.get("value", "")
    if not isinstance(value, str):
        raise DataError("O campo value precisa ser texto.")
    validate_value(key, value)
    return {"key": key, "data_class": data_class(key), "valid": 1}


def _migrate_keys_from_payload(payload: Mapping[str, Any]) -> tuple[str, ...]:
    """Chaves cujo valor legado pode estar inválido e será substituído."""
    raw = payload.get("migrate_keys")
    if raw is None:
        return ()
    if isinstance(raw, str):
        items = [item for item in raw.split("\n") if item]
    elif isinstance(raw, list):
        items = []
        for item in raw:
            if not isinstance(item, str):
                raise DataError("migrate_keys aceita somente texto.")
            items.append(item)
    else:
        raise DataError("migrate_keys precisa ser lista ou texto.")
    for key in items:
        if key not in SCHEMA:
            raise DataError(
                "Chave fora do schema em migrate_keys: %s." % safe_label(key)
            )
    return tuple(items)


def _remove_keys_from_payload(payload: Mapping[str, Any]) -> tuple[str, ...]:
    """Chaves depreciadas cujas linhas devem sair do arquivo."""
    raw = payload.get("remove_keys")
    if raw is None:
        return ()
    if isinstance(raw, str):
        items = [item for item in raw.split("\n") if item]
    elif isinstance(raw, list):
        items = []
        for item in raw:
            if not isinstance(item, str):
                raise DataError("remove_keys aceita somente texto.")
            items.append(item)
    else:
        raise DataError("remove_keys precisa ser lista ou texto.")
    for key in items:
        if key not in DEPRECATED_KEYS:
            raise DataError(
                "Somente chave depreciada pode ser removida: %s." % safe_label(key)
            )
    return tuple(items)


def build_document(payload: Mapping[str, Any]) -> tuple[dict, str]:
    """Gera o texto candidato da configuração com as atualizações pedidas."""
    text = _require_text(payload, "text")
    migrate = _migrate_keys_from_payload(payload)
    document = parse_document(text, tolerate=migrate)
    updates = _updates_from_payload(payload)
    removals = _remove_keys_from_payload(payload)
    if not updates and not removals:
        raise DataError("nenhuma atualização de configuração foi declarada.")
    # Tolerância só existe para ser substituída: uma chave declarada em
    # migrate_keys sem novo valor deixaria o documento inválido depois da
    # publicação, então isso é erro de uso do próprio fluxo de migração.
    for key in migrate:
        if key not in updates:
            raise DataError(
                "Chave %s foi declarada para migração sem novo valor."
                % safe_label(key)
            )
    rendered = render_document(document, updates, removals)
    # Releitura do próprio candidato, agora **sem tolerância**: garante que o
    # texto emitido passa no parser estrito e que nenhum valor legado inválido
    # sobreviveu à migração.
    reparsed = parse_document(rendered, "configuração candidata")
    for key in removals:
        if key in reparsed["deprecated"]:
            raise DataError(
                "A chave depreciada %s sobreviveu à remoção." % safe_label(key)
            )
    for key, value in updates.items():
        if reparsed["values"].get(key, "") != value:
            raise DataError(
                "O candidato não reproduziu o valor de %s." % safe_label(key)
            )
    changed = 1 if rendered != text else 0
    data = {
        "changed": changed,
        "update_count": len(updates),
        "migrated_count": len(migrate),
        "removed_count": len(removals),
        "invalid_before": len(document["invalid"]),
        "present_count": len(reparsed["values"]),
        "final_newline": 1 if reparsed["final_newline"] else 0,
    }
    return data, rendered
