"""Inspeção e geração de candidatos do XML de domínio libvirt (seção 3.5).

Módulo puro. Ele nunca chama `virsh`, `qemu-img` ou `virt-xml-validate`: recebe
o snapshot capturado pelo Bash, devolve fatos tipados ou o texto de um
candidato, e o Bash é quem valida com o schema do libvirt, aplica, relê e
compara.

Três regras estruturam todas as funções daqui:

* cardinalidade explícita: zero ou vários nós onde se espera exatamente um é
  erro tipado, nunca seleção do primeiro;
* conteúdo não gerenciado é preservado: as operações de candidato tocam apenas
  o que declaram gerenciar e recusam construções cuja semântica não modelamos
  (`maxMemory`, `numatune`, `<vcpus>` de hotplug, `<cpu><numa>`);
* comparação é semântica: fingerprint e diff usam a projeção canônica, não o
  texto serializado.
"""
from __future__ import annotations

import re
import xml.etree.ElementTree as ET
from typing import Any, Callable, Mapping

from . import xmlutil
from .errors import DataError
from .protocol import safe_label

DOMAIN_ROOT = "domain"

# Namespace próprio do projeto para metadata durável no XML inativo. Nomes
# namespaced não colidem com metadata de outras ferramentas e o libvirt
# preserva cada namespace de metadata independentemente.
METADATA_NAMESPACE = "https://github.com/vm-passthrough/metadata/1"
METADATA_PREFIX = "vmpass"
METADATA_ROOT = "{%s}passthrough" % METADATA_NAMESPACE
METADATA_INSTALL = "{%s}windows-install" % METADATA_NAMESPACE
METADATA_USB_BINDINGS = "{%s}usb-bindings" % METADATA_NAMESPACE
METADATA_USB_BINDING = "{%s}usb-binding" % METADATA_NAMESPACE

_BDF = re.compile(r"^([0-9a-f]{4}):([0-9a-f]{2}):([0-9a-f]{2})\.([0-7])$")
_MAC = re.compile(r"^[0-9a-f]{2}(:[0-9a-f]{2}){5}$")
_TARGET_DEV = re.compile(r"^[A-Za-z0-9_.-]{1,32}$")
_USB_ID = re.compile(r"^0x[0-9A-Fa-f]{4}$")
_HEX_DIGEST = re.compile(r"^[0-9a-f]{64}$")
_TIMESTAMP = re.compile(r"^[0-9]{8}-[0-9]{6}$")
_CPU_LIST = re.compile(r"^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$")

# Âncoras de ordem do schema do libvirt: um elemento novo entra antes do
# primeiro nome desta lista que já exista, para não invalidar a sequência.
_ANCHORS_CPUTUNE = (
    "numatune",
    "resource",
    "sysinfo",
    "os",
    "features",
    "cpu",
    "clock",
    "devices",
)
_ANCHORS_CPU = ("clock", "on_poweroff", "on_reboot", "on_crash", "pm", "devices")
_ANCHORS_MEMORY_BACKING = (
    "vcpu",
    "resource",
    "sysinfo",
    "os",
    "features",
    "cpu",
    "clock",
    "devices",
)
_ANCHORS_METADATA = (
    "memory",
    "currentMemory",
    "memoryBacking",
    "vcpu",
    "resource",
    "os",
    "features",
    "cpu",
    "clock",
    "devices",
)

_MEMORY_UNITS = {
    "b": 1,
    "bytes": 1,
    "kb": 1000,
    "k": 1024,
    "kib": 1024,
    "mb": 1000 ** 2,
    "m": 1024 ** 2,
    "mib": 1024 ** 2,
    "gb": 1000 ** 3,
    "g": 1024 ** 3,
    "gib": 1024 ** 3,
    "tb": 1000 ** 4,
    "t": 1024 ** 4,
    "tib": 1024 ** 4,
}


# --- Validação de campos do payload ------------------------------------------


def _require_text(payload: Mapping[str, Any], key: str) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or not value:
        raise DataError("O campo %s é obrigatório e precisa ser texto." % safe_label(key))
    return value


def _optional_text(payload: Mapping[str, Any], key: str, default: str = "") -> str:
    value = payload.get(key, default)
    if value is None:
        return default
    if not isinstance(value, str):
        raise DataError("O campo %s precisa ser texto." % safe_label(key))
    return value


def _require_int(payload: Mapping[str, Any], key: str, minimum: int = 0) -> int:
    """Inteiro do payload, aceitando também a forma textual do canal de pares.

    O canal `chave\\0valor\\0` entrega tudo como texto. Aceitar `"4"` além de
    `4` mantém um único schema para os dois transportes, sem afrouxar nada: só
    dígitos decimais passam, e o limite inferior continua sendo verificado.
    """
    value = payload.get(key)
    if isinstance(value, str):
        if not value.isdigit():
            raise DataError(
                "O campo %s precisa ser inteiro decimal." % safe_label(key)
            )
        value = int(value)
    if isinstance(value, bool) or not isinstance(value, int):
        raise DataError("O campo %s precisa ser inteiro." % safe_label(key))
    if value < minimum:
        raise DataError(
            "O campo %s precisa ser maior ou igual a %d." % (safe_label(key), minimum)
        )
    return value


def _require_list(payload: Mapping[str, Any], key: str) -> list:
    """Lista do payload; no canal de pares, itens separados por nova linha.

    Nenhum campo de lista deste módulo aceita valor com nova linha (são nomes
    de interface/bridge validados por expressão), então a separação é
    inequívoca e itens vazios são descartados.
    """
    value = payload.get(key, [])
    if value is None:
        return []
    if isinstance(value, str):
        return [item for item in value.split("\n") if item]
    if not isinstance(value, list):
        raise DataError("O campo %s precisa ser uma lista." % safe_label(key))
    return value


def normalize_bdf(value: str, field: str = "endereco_pci") -> tuple[str, str, str, str]:
    """Normaliza `dddd:bb:ss.f` e devolve os quatro componentes em minúsculas."""
    if not isinstance(value, str):
        raise DataError("O campo %s precisa ser texto." % safe_label(field))
    match = _BDF.match(value.strip().lower())
    if match is None:
        raise DataError(
            "Endereço PCI fora do formato dddd:bb:ss.f em %s." % safe_label(field)
        )
    return match.group(1), match.group(2), match.group(3), match.group(4)


def normalize_mac(value: str, field: str = "mac") -> str:
    """Normaliza o MAC para minúsculas, recusando qualquer outro formato."""
    if not isinstance(value, str):
        raise DataError("O campo %s precisa ser texto." % safe_label(field))
    lowered = value.strip().lower()
    if _MAC.match(lowered) is None:
        raise DataError("MAC fora do formato aa:bb:cc:dd:ee:ff em %s." % safe_label(field))
    return lowered


def _validate_target_dev(value: str, field: str) -> str:
    if _TARGET_DEV.match(value) is None:
        raise DataError(
            "Alvo de disco fora do formato aceito em %s." % safe_label(field)
        )
    return value


def _expand_cpu_list(spec: str, field: str) -> list[int]:
    """Expande `0-2,5` preservando a ordem declarada e recusando duplicidade."""
    if not isinstance(spec, str) or not spec:
        raise DataError("Lista de CPUs vazia em %s." % safe_label(field))
    if _CPU_LIST.match(spec) is None:
        raise DataError("Lista de CPUs inválida em %s." % safe_label(field))
    result: list[int] = []
    seen: set[int] = set()
    for part in spec.split(","):
        if "-" in part:
            start_text, _, end_text = part.partition("-")
            start, end = int(start_text), int(end_text)
            if start > end:
                raise DataError(
                    "Intervalo de CPUs invertido em %s." % safe_label(field)
                )
            values = range(start, end + 1)
        else:
            values = (int(part),)
        for value in values:
            if value in seen:
                raise DataError("CPU duplicada em %s." % safe_label(field))
            seen.add(value)
            result.append(value)
    return result


def _memory_bytes(text: str, unit: str, default_unit: str, context: str) -> int:
    key = (unit or default_unit).strip().lower()
    if key not in _MEMORY_UNITS:
        raise DataError("%s: unidade de memória não suportada." % context)
    stripped = (text or "").strip()
    if not stripped.isdigit():
        raise DataError("%s: valor de memória não é inteiro decimal." % context)
    return int(stripped) * _MEMORY_UNITS[key]


# --- Estrutura comum ---------------------------------------------------------


def _devices(root: ET.Element) -> ET.Element:
    return xmlutil.exactly_one(root, "devices", "XML de domínio")


def _reject_unmodeled_memory_topology(root: ET.Element) -> None:
    """Recusa construções cuja semântica esta fase não modela.

    Cada uma delas tem política própria (hotplug de RAM, política NUMA
    explícita, vCPU individual). Convergir automaticamente sobre elas apagaria
    decisão do operador, então a recusa é deliberada e precede toda mutação.
    """
    if xmlutil.direct(root, "maxMemory"):
        raise DataError(
            "reconfiguração automática com <maxMemory> não é suportada; revise "
            "hotplug de RAM manualmente"
        )
    if xmlutil.direct(root, "numatune"):
        raise DataError("reconfiguração automática com <numatune> não é suportada")
    if xmlutil.direct(root, "vcpus"):
        raise DataError(
            "o domínio possui <vcpus> de hotplug; remova/reconcilie essa política "
            "manualmente antes desta etapa"
        )


def _disk_records(root: ET.Element) -> list[dict]:
    """Projeta todos os discos com cardinalidade e alvos validados."""
    devices = _devices(root)
    records: list[dict] = []
    seen_targets: set[str] = set()
    for index, disk in enumerate(xmlutil.direct(devices, "disk")):
        context = "disco na posição %d" % index
        source = xmlutil.at_most_one(disk, "source", context)
        driver = xmlutil.at_most_one(disk, "driver", context)
        target = xmlutil.at_most_one(disk, "target", context)
        target_dev = xmlutil.attribute(target, "dev")
        if target_dev:
            if _TARGET_DEV.match(target_dev) is None:
                raise DataError("%s: alvo fora do formato aceito." % context)
            if target_dev in seen_targets:
                raise DataError("%s: alvo de disco duplicado no XML." % context)
            seen_targets.add(target_dev)
        records.append(
            {
                "index": index,
                "device": disk.get("device", ""),
                "type": disk.get("type", ""),
                "source_file": xmlutil.attribute(source, "file"),
                "source_dev": xmlutil.attribute(source, "dev"),
                "source_count": len(xmlutil.direct(disk, "source")),
                "driver_name": xmlutil.attribute(driver, "name"),
                "driver_type": xmlutil.attribute(driver, "type"),
                "driver_cache": xmlutil.attribute(driver, "cache"),
                "driver_discard": xmlutil.attribute(driver, "discard"),
                "driver_count": len(xmlutil.direct(disk, "driver")),
                "target_dev": target_dev,
                "target_bus": xmlutil.attribute(target, "bus"),
                "serial": xmlutil.text_of(xmlutil.at_most_one(disk, "serial", context)),
                "wwn": xmlutil.text_of(xmlutil.at_most_one(disk, "wwn", context)),
                "element": disk,
            }
        )
    return records


# --- Subcomando: disco QCOW2 alvo --------------------------------------------


def disk_target_state(payload: Mapping[str, Any]) -> dict:
    """Estado do disco cujo `source/@file` é exatamente `qcow2_path`.

    Substitui `xml_disco_qcow2_estado`: mesma política de cardinalidade e as
    mesmas três conclusões (`ativo`, `ausente`, erro tipado).
    """
    xml = _require_text(payload, "xml")
    qcow2 = _require_text(payload, "qcow2_path")
    root = xmlutil.parse_document(xml, DOMAIN_ROOT, "XML de domínio")
    records = _disk_records(root)
    matches = []
    for record in records:
        if record["device"] != "disk":
            continue
        if record["source_file"] != qcow2:
            continue
        # Cardinalidade maior que um já foi recusada em _disk_records; aqui
        # resta o caso de disco sem <source>, que não pode ser o alvo.
        if record["source_count"] != 1:
            raise DataError(
                "o disco candidato ao QCOW2 alvo não declara exatamente uma fonte"
            )
        matches.append(record)
    if len(matches) != 1:
        raise DataError(
            "discos device=disk com source/@file exato para QCOW2_PATH: %d; "
            "esperado 1" % len(matches)
        )
    target = matches[0]
    if target["driver_count"] != 1:
        raise DataError(
            "o disco alvo não declara exatamente um <driver>; esperado 1"
        )
    return {
        "state": "ativo" if target["driver_discard"] == "unmap" else "ausente",
        "discard": target["driver_discard"],
        "driver_type": target["driver_type"],
        "target_dev": target["target_dev"],
        "disk_count": len(records),
        "fingerprint": xmlutil.fingerprint(root),
    }


def disk_snapshot_plan(payload: Mapping[str, Any]) -> dict:
    """Mapa de `--diskspec` para snapshot interno, com cardinalidade exigida.

    Substitui o helper embutido em `util/snapshot-vm.sh`. O disco configurado
    entra como `internal`; todos os demais entram explicitamente como `no`.
    """
    xml = _require_text(payload, "xml")
    qcow2 = _require_text(payload, "qcow2_path")
    root = xmlutil.parse_document(xml, DOMAIN_ROOT, "XML inativo")
    records = [record for record in _disk_records(root) if record["device"] == "disk"]
    principals = 0
    data: dict[str, Any] = {}
    order = 0
    for record in records:
        if not record["target_dev"]:
            raise DataError("alvo de disco inválido ou ausente no XML")
        if record["source_file"] == qcow2:
            principals += 1
            if record["driver_type"] != "qcow2":
                raise DataError("o disco configurado não usa driver qcow2")
            mode = "internal"
        else:
            mode = "no"
        data["disk_%d_target" % order] = record["target_dev"]
        data["disk_%d_mode" % order] = mode
        order += 1
    if principals != 1:
        raise DataError(
            "o XML precisa usar QCOW2_PATH exatamente uma vez como disco ativo; "
            "um overlay externo ou configuração divergente exige "
            "consolidação/revisão manual"
        )
    if order == 0:
        raise DataError("nenhum disco de dados foi encontrado no XML inativo")
    data["disk_count"] = order
    return data


def disk_backup_target(payload: Mapping[str, Any]) -> dict:
    """Confirma que o QCOW2 configurado é exatamente o disco ativo do XML.

    Substitui o helper embutido em `util/backup-vm.sh`, preservando a mesma
    conclusão: cardinalidade diferente de um, ou driver diferente de qcow2,
    tornaria a cópia obsoleta e é recusada antes de copiar qualquer byte.
    """
    xml = _require_text(payload, "xml")
    qcow2 = _require_text(payload, "qcow2_path")
    root = xmlutil.parse_document(xml, DOMAIN_ROOT, "XML inativo")
    matches = [
        record
        for record in _disk_records(root)
        if record["device"] == "disk" and record["source_file"] == qcow2
    ]
    if len(matches) != 1:
        raise DataError(
            "QCOW2_PATH precisa ser exatamente o disco ativo no XML; um overlay "
            "externo ou caminho divergente tornaria a cópia obsoleta"
        )
    if matches[0]["driver_type"] != "qcow2":
        raise DataError("o disco ativo configurado não usa driver qcow2")
    sources: list[str] = []
    for record in _disk_records(root):
        for value in (record["source_file"], record["source_dev"]):
            if value and value != qcow2 and value not in sources:
                sources.append(value)
    data: dict[str, Any] = {
        "target_dev": matches[0]["target_dev"],
        "driver_type": matches[0]["driver_type"],
        "other_source_count": len(sources),
    }
    for index, value in enumerate(sources):
        data["other_source_%d" % index] = value
    nvram = _nvram_path(root)
    data["nvram_path"] = nvram
    return data


SNAPSHOT_ROOT = "domainsnapshot"


def snapshot_internal_state(payload: Mapping[str, Any]) -> dict:
    """Confirma que o snapshot é interno e possui exatamente um disco alvo.

    Substitui o helper embutido em `util/snapshot-vm.sh`. Snapshot externo e
    tipo desconhecido são recusados com o mesmo diagnóstico anterior, porque
    reverter/apagar automaticamente uma cadeia externa destruiria estado.
    """
    xml = _require_text(payload, "xml")
    root = xmlutil.parse_document(xml, SNAPSHOT_ROOT, "XML do snapshot")
    disks_container = xmlutil.at_most_one(root, "disks", "XML do snapshot")
    disks = xmlutil.direct(disks_container, "disk") if disks_container is not None else []
    external: list[str] = []
    internal: list[str] = []
    unknown = 0
    for index, disk in enumerate(disks):
        mode = disk.get("snapshot", "")
        name = disk.get("name", "")
        if mode == "external":
            external.append(name or "?")
        elif mode == "internal":
            if not name or _TARGET_DEV.match(name) is None:
                raise DataError(
                    "disco interno na posição %d sem nome de alvo válido" % index
                )
            internal.append(name)
        elif mode != "no":
            unknown += 1
    if external:
        raise DataError(
            "snapshot externo não é compatível com reverter/apagar "
            "automaticamente; %d disco(s) externo(s) presentes" % len(external)
        )
    if unknown:
        raise DataError(
            "tipos de snapshot não reconhecidos em %d disco(s)" % unknown
        )
    if len(internal) != 1:
        raise DataError(
            "esperado exatamente um disco interno; encontrados: %d" % len(internal)
        )
    return {
        "internal_target": internal[0],
        "disk_count": len(disks),
    }


def _nvram_path(root: ET.Element) -> str:
    os_nodes = xmlutil.at_most_one(root, "os", "XML de domínio")
    if os_nodes is None:
        return ""
    nvram = xmlutil.at_most_one(os_nodes, "nvram", "elemento os")
    return xmlutil.text_of(nvram)


# --- Subcomando: hostdev PCI e disco físico ----------------------------------


def hostdev_pci_state(payload: Mapping[str, Any]) -> dict:
    """Cardinalidade do hostdev PCI, separando total de conforme.

    Substitui `hostdev_estado_xml`: `total` conta qualquer hostdev cujo
    `source/address` case com o BDF; `exact` conta apenas os que também são
    `mode='subsystem' type='pci' managed='yes'`.
    """
    xml = _require_text(payload, "xml")
    dom, bus, slot, function = normalize_bdf(
        _require_text(payload, "pci_address"), "pci_address"
    )
    root = xmlutil.parse_document(xml, DOMAIN_ROOT, "XML de domínio")
    devices = _devices(root)
    total = 0
    exact = 0
    managed_values: list[str] = []
    for index, hostdev in enumerate(xmlutil.direct(devices, "hostdev")):
        context = "hostdev na posição %d" % index
        source = xmlutil.at_most_one(hostdev, "source", context)
        if source is None:
            continue
        for address in xmlutil.direct(source, "address"):
            if (
                _hex_equal(address.get("domain"), dom)
                and _hex_equal(address.get("bus"), bus)
                and _hex_equal(address.get("slot"), slot)
                and _hex_equal(address.get("function"), function)
            ):
                total += 1
                managed_values.append(hostdev.get("managed", ""))
                if (
                    hostdev.get("mode") == "subsystem"
                    and hostdev.get("type") == "pci"
                    and hostdev.get("managed") == "yes"
                ):
                    exact += 1
    return {
        "total": total,
        "exact": exact,
        "managed": managed_values[0] if len(managed_values) == 1 else "",
    }


def _hex_equal(actual: Any, expected: str) -> bool:
    """Compara valores hexadecimais do libvirt sem depender de formatação."""
    if not isinstance(actual, str) or not actual:
        return False
    text = actual.strip().lower()
    if text.startswith("0x"):
        text = text[2:]
    if not text or any(char not in "0123456789abcdef" for char in text):
        return False
    return int(text, 16) == int(expected, 16)


def disk_block_state(payload: Mapping[str, Any]) -> dict:
    """Cardinalidade do disco físico (HD1) por caminho e por alvo.

    Substitui `disco_estado_xml`, mantendo as três contagens que a etapa 14
    compara: fonte, conformidade exata de atributos e ocupação do alvo.
    """
    xml = _require_text(payload, "xml")
    block_path = _require_text(payload, "block_path")
    target_dev = _validate_target_dev(
        _optional_text(payload, "target_dev", "vdb"), "target_dev"
    )
    root = xmlutil.parse_document(xml, DOMAIN_ROOT, "XML de domínio")
    records = _disk_records(root)
    source_count = 0
    exact_count = 0
    target_count = 0
    for record in records:
        if record["source_dev"] == block_path:
            source_count += 1
            if (
                record["type"] == "block"
                and record["device"] == "disk"
                and record["driver_name"] == "qemu"
                and record["driver_type"] == "raw"
                and record["driver_cache"] == "none"
                and record["target_dev"] == target_dev
                and record["target_bus"] == "virtio"
            ):
                exact_count += 1
        if record["target_dev"] == target_dev:
            target_count += 1
    return {
        "source_count": source_count,
        "exact_count": exact_count,
        "target_count": target_count,
        "identity_count": sum(
            1 for record in records if record["serial"] or record["wwn"]
        ),
    }


# --- Subcomando: hostdev USB -------------------------------------------------


def usb_hostdev_list(payload: Mapping[str, Any]) -> dict:
    """Enumera hostdevs USB e vincula metadata I6 por alias estável."""
    xml = _require_text(payload, "xml")
    root = xmlutil.parse_document(xml, DOMAIN_ROOT, "XML de domínio")
    devices = _devices(root)
    metadata = xmlutil.at_most_one(root, "metadata", "XML de domínio")
    bindings_by_alias: dict[str, dict[str, str]] = {}
    binding_identities: set[str] = set()
    if metadata is not None:
        own = xmlutil.direct(metadata, METADATA_ROOT)
        if len(own) > 1:
            raise DataError("metadata do projeto duplicada no XML do domínio.")
        if own:
            containers = xmlutil.direct(own[0], METADATA_USB_BINDINGS)
            if len(containers) > 1:
                raise DataError("metadata de bindings USB duplicada.")
            if containers:
                for binding in xmlutil.direct(containers[0], METADATA_USB_BINDING):
                    alias_name = binding.get("alias", "")
                    digest = binding.get("identity-sha256", "")
                    kind = binding.get("identity-kind", "")
                    vendor_meta = binding.get("vendor", "")
                    product_meta = binding.get("product", "")
                    if not alias_name or alias_name in bindings_by_alias:
                        raise DataError("binding USB com alias ausente ou duplicado.")
                    if digest in binding_identities:
                        raise DataError("binding USB com identidade física duplicada.")
                    if _HEX_DIGEST.match(digest) is None or kind not in ("serial", "port"):
                        raise DataError("binding USB com identidade inválida.")
                    if _USB_ID.match(vendor_meta) is None or _USB_ID.match(product_meta) is None:
                        raise DataError("binding USB com VID/PID inválido.")
                    bindings_by_alias[alias_name] = {
                        "identity_kind": kind,
                        "identity_sha256": digest,
                        "vendor": vendor_meta.lower(),
                        "product": product_meta.lower(),
                    }
                    binding_identities.add(digest)
    data: dict[str, Any] = {}
    order = 0
    pair_bindings: dict[str, list[bool]] = {}
    matched_aliases: set[str] = set()
    for index, hostdev in enumerate(xmlutil.direct(devices, "hostdev")):
        if hostdev.get("type") != "usb":
            continue
        context = "hostdev USB na posição %d" % index
        source = xmlutil.exactly_one(hostdev, "source", context)
        vendor = xmlutil.at_most_one(source, "vendor", context)
        product = xmlutil.at_most_one(source, "product", context)
        address = xmlutil.at_most_one(source, "address", context)
        alias_node = xmlutil.at_most_one(hostdev, "alias", context)
        vendor_id = xmlutil.attribute(vendor, "id").lower()
        product_id = xmlutil.attribute(product, "id").lower()
        alias_name = xmlutil.attribute(alias_node, "name")
        if bool(vendor_id) != bool(product_id):
            raise DataError("%s: vendor e product precisam aparecer juntos." % context)
        if vendor_id and _USB_ID.match(vendor_id) is None:
            raise DataError("%s: vendor id fora do formato 0xNNNN." % context)
        if product_id and _USB_ID.match(product_id) is None:
            raise DataError("%s: product id fora do formato 0xNNNN." % context)
        bus = xmlutil.attribute(address, "bus")
        device = xmlutil.attribute(address, "device")
        if bool(bus) != bool(device) or bus and (
            re.fullmatch(r"(?:0x[0-9A-Fa-f]+|[0-9]+)", bus) is None
            or re.fullmatch(r"(?:0x[0-9A-Fa-f]+|[0-9]+)", device) is None
        ):
            raise DataError("%s: endereço bus/device inválido ou incompleto." % context)
        if not vendor_id and not bus:
            raise DataError(
                "%s: sem vendor/product nem endereço; discriminador ausente." % context
            )
        binding = bindings_by_alias.get(alias_name)
        if binding:
            matched_aliases.add(alias_name)
            if binding["vendor"] != vendor_id or binding["product"] != product_id:
                raise DataError("binding USB diverge do VID/PID do hostdev.")
        key = "%s:%s" % (vendor_id, product_id)
        pair_bindings.setdefault(key, []).append(binding is not None)
        data["usb_%d_vendor" % order] = vendor_id
        data["usb_%d_product" % order] = product_id
        data["usb_%d_bus" % order] = bus
        data["usb_%d_device" % order] = device
        data["usb_%d_managed" % order] = hostdev.get("managed", "")
        data["usb_%d_alias" % order] = alias_name
        data["usb_%d_identity_kind" % order] = binding["identity_kind"] if binding else ""
        data["usb_%d_identity_sha256" % order] = binding["identity_sha256"] if binding else ""
        order += 1
    orphaned = set(bindings_by_alias) - matched_aliases
    if orphaned:
        raise DataError("metadata USB órfã no XML do domínio.")
    data["usb_count"] = order
    data["ambiguous_pairs"] = sum(
        1 for bound in pair_bindings.values() if len(bound) > 1 and not all(bound)
    )
    return data


# --- Subcomando: interfaces --------------------------------------------------


def interface_state(payload: Mapping[str, Any]) -> dict:
    """Fatos de rede do domínio, sempre com cardinalidade explícita.

    Cobre os três usos do projeto sem nunca escolher `[1]`:

    * identificação da NIC gerenciada pelo MAC persistido;
    * descoberta do MAC quando o domínio tem exatamente uma NIC na rede dada
      (a etapa 12 usava `interface[...][1]`, o que violava a seção 3.5);
    * contagem de consumidores de uma rede/bridge (etapa 18).
    """
    xml = _require_text(payload, "xml")
    root = xmlutil.parse_document(xml, DOMAIN_ROOT, "XML de domínio")
    devices = _devices(root)
    mac_filter = payload.get("nic_mac")
    if mac_filter is not None and mac_filter != "":
        mac_filter = normalize_mac(mac_filter, "nic_mac")
    else:
        mac_filter = ""
    network_name = _optional_text(payload, "network_name")
    bridge_names = [
        _text_item(item, "bridge_names") for item in _require_list(payload, "bridge_names")
    ]
    max_items = _require_int(payload, "max_items", 1) if "max_items" in payload else 32

    data: dict[str, Any] = {}
    total = 0
    mac_count = 0
    consumer_count = 0
    network_matches: list[dict] = []
    matched: dict[str, Any] | None = None
    for index, interface in enumerate(xmlutil.direct(devices, "interface")):
        context = "interface na posição %d" % index
        mac_node = xmlutil.at_most_one(interface, "mac", context)
        source = xmlutil.at_most_one(interface, "source", context)
        model = xmlutil.at_most_one(interface, "model", context)
        raw_mac = xmlutil.attribute(mac_node, "address")
        mac = raw_mac.strip().lower()
        if mac and _MAC.match(mac) is None:
            raise DataError("%s: MAC fora do formato aceito." % context)
        record = {
            "mac": mac,
            "type": interface.get("type", ""),
            "network": xmlutil.attribute(source, "network"),
            "bridge": xmlutil.attribute(source, "bridge"),
            "dev": xmlutil.attribute(source, "dev"),
            "model": xmlutil.attribute(model, "type"),
            "has_mac": 1 if mac_node is not None else 0,
        }
        if total < max_items:
            data["nic_%d_mac" % total] = record["mac"]
            data["nic_%d_type" % total] = record["type"]
            data["nic_%d_network" % total] = record["network"]
            data["nic_%d_source" % total] = (
                record["network"] + record["bridge"] + record["dev"]
            )
        total += 1
        if mac_filter and mac == mac_filter:
            mac_count += 1
            matched = record
        if network_name and record["network"] == network_name:
            network_matches.append(record)
        if (network_name and record["network"] == network_name) or (
            record["bridge"] and record["bridge"] in bridge_names
        ):
            consumer_count += 1
    if total > max_items:
        raise DataError(
            "o domínio possui %d interfaces, acima do limite de %d desta chamada."
            % (total, max_items)
        )
    data["nic_count"] = total
    data["mac_count"] = mac_count
    data["consumer_count"] = consumer_count
    data["network_match_count"] = len(network_matches)
    data["network_match_mac"] = (
        network_matches[0]["mac"] if len(network_matches) == 1 else ""
    )
    data["mac_type"] = matched["type"] if matched and mac_count == 1 else ""
    data["mac_network"] = matched["network"] if matched and mac_count == 1 else ""
    data["mac_bridge"] = matched["bridge"] if matched and mac_count == 1 else ""
    data["mac_dev"] = matched["dev"] if matched and mac_count == 1 else ""
    data["mac_has_address"] = matched["has_mac"] if matched and mac_count == 1 else 0
    return data


def _text_item(value: Any, field: str) -> str:
    if not isinstance(value, str):
        raise DataError("Todos os itens de %s precisam ser texto." % safe_label(field))
    return value


# --- Subcomando: memória e HugePages ----------------------------------------


def memory_backing_state(payload: Mapping[str, Any]) -> dict:
    """Estado declarado de HugePages, sem inferir política.

    Substitui `xml_sem_hugepages`: cardinalidade de `memoryBacking`/`hugepages`
    e o tamanho exato da página declarada.
    """
    xml = _require_text(payload, "xml")
    root = xmlutil.parse_document(xml, DOMAIN_ROOT, "XML de domínio")
    backing = xmlutil.at_most_one(root, "memoryBacking", "XML de domínio")
    if backing is None:
        return {"backing_count": 0, "hugepages_count": 0, "page_count": 0, "page_bytes": 0}
    hugepages = xmlutil.direct(backing, "hugepages")
    if len(hugepages) > 1:
        raise DataError("<hugepages> duplicado em <memoryBacking>.")
    if not hugepages:
        return {"backing_count": 1, "hugepages_count": 0, "page_count": 0, "page_bytes": 0}
    pages = xmlutil.direct(hugepages[0], "page")
    page_bytes = 0
    if len(pages) == 1:
        page_bytes = _memory_bytes(
            pages[0].get("size", ""), pages[0].get("unit", ""), "KiB", "hugepages/page"
        )
    return {
        "backing_count": 1,
        "hugepages_count": 1,
        "page_count": len(pages),
        "page_bytes": page_bytes,
    }


# --- Subcomando: validação de CPU/HugePages ---------------------------------


def validate_cpu_pinning(payload: Mapping[str, Any]) -> dict:
    """Prova, no XML dado, o pinning e a topologia gerenciados pela etapa 16.

    Substitui `validar_xml_cpu_pinning` preservando cada recusa: cardinalidade,
    conjunto exato de CPUs, ordem canônica de vcpupin, modo/check/migratable,
    topologia, memória e o modo de HugePages pedido.
    """
    xml = _require_text(payload, "xml")
    vm_spec = _require_text(payload, "cpus_vm")
    host_spec = _require_text(payload, "cpus_host")
    vcpus = _require_int(payload, "vcpus", 1)
    cores = _require_int(payload, "cores", 1)
    threads = _require_int(payload, "threads", 1)
    ram_mb = _require_int(payload, "ram_mb", 1)
    huge_mode = _optional_text(payload, "hugepages_mode", "ignorar")
    if huge_mode not in ("sim", "nao", "ignorar"):
        raise DataError(
            "modo de HugePages inválido: %s" % safe_label(huge_mode)
        )

    expected_vm = _expand_cpu_list(vm_spec, "cpus_vm")
    expected_host = _expand_cpu_list(host_spec, "cpus_host")
    if len(expected_vm) != vcpus:
        raise DataError(
            "CPUS_VM possui %d CPUs, esperado %d" % (len(expected_vm), vcpus)
        )
    if cores * threads != vcpus:
        raise DataError("produto cores x threads diverge de vCPUs")

    root = xmlutil.parse_document(xml, DOMAIN_ROOT, "XML de domínio")
    if xmlutil.direct(root, "maxMemory") or xmlutil.direct(root, "numatune"):
        raise DataError(
            "maxMemory/numatune não são suportados pela validação automática "
            "desta etapa"
        )

    vcpu = xmlutil.exactly_one(root, "vcpu", "XML de domínio")
    if xmlutil.text_of(vcpu) != str(vcpus):
        raise DataError("<vcpu> diverge de %d" % vcpus)
    if vcpu.get("placement") != "static" or set(
        _expand_cpu_list(vcpu.get("cpuset", ""), "vcpu/@cpuset")
    ) != set(expected_vm):
        raise DataError("<vcpu> não possui placement estático e conjunto exato de CPUS_VM")
    if vcpu.get("current") not in (None, str(vcpus)):
        raise DataError("vcpu/@current limita a VM a uma cardinalidade diferente")
    if xmlutil.direct(root, "vcpus"):
        raise DataError(
            "<vcpus> de hotplug não é suportado automaticamente; a política "
            "precisa ser reconciliada manualmente"
        )

    cputune = xmlutil.exactly_one(root, "cputune", "XML de domínio")
    pins = xmlutil.direct(cputune, "vcpupin")
    if len(pins) != vcpus:
        raise DataError(
            "quantidade de vcpupin=%d, esperado %d" % (len(pins), vcpus)
        )
    seen: set[int] = set()
    for pin in pins:
        index_text = pin.get("vcpu", "")
        if not index_text.isdigit():
            raise DataError("vcpupin sem índice numérico")
        index = int(index_text)
        if index in seen or index >= vcpus:
            raise DataError("índice vcpupin duplicado/fora da faixa: %d" % index)
        seen.add(index)
        actual = _expand_cpu_list(pin.get("cpuset", ""), "vcpupin/@cpuset")
        if actual != [expected_vm[index]]:
            raise DataError(
                "vCPU %d está fora do pinning exato esperado para CPUS_VM" % index
            )
    if seen != set(range(vcpus)):
        raise DataError("vcpupin não cobre exatamente 0..VM_VCPUS-1")
    emulators = xmlutil.direct(cputune, "emulatorpin")
    if len(emulators) != 1 or set(
        _expand_cpu_list(emulators[0].get("cpuset", ""), "emulatorpin/@cpuset")
    ) != set(expected_host):
        raise DataError("emulatorpin não corresponde exatamente a CPUS_HOST")

    cpu = xmlutil.exactly_one(root, "cpu", "XML de domínio")
    if xmlutil.direct(cpu, "numa"):
        raise DataError("<cpu><numa> não é suportado pela validação automática desta etapa")
    if (
        cpu.get("mode") != "host-passthrough"
        or cpu.get("check") != "none"
        or cpu.get("migratable") != "off"
    ):
        raise DataError("modo/check/migratable da CPU não são os valores gerenciados")
    topology = xmlutil.exactly_one(cpu, "topology", "elemento cpu")
    expected_topology = {
        "sockets": "1",
        "dies": "1",
        "cores": str(cores),
        "threads": str(threads),
    }
    for key, value in expected_topology.items():
        if topology.get(key) != value:
            raise DataError(
                "topology/@%s divergiu do valor gerenciado %s" % (key, value)
            )

    memory = xmlutil.exactly_one(root, "memory", "XML de domínio")
    expected_bytes = ram_mb * 1024 * 1024
    if _memory_bytes(
        xmlutil.text_of(memory), memory.get("unit", ""), "KiB", "<memory>"
    ) != expected_bytes:
        raise DataError("<memory> não corresponde exatamente a VM_RAM_MB")
    current = xmlutil.at_most_one(root, "currentMemory", "XML de domínio")
    if current is not None and _memory_bytes(
        xmlutil.text_of(current), current.get("unit", ""), "KiB", "<currentMemory>"
    ) != expected_bytes:
        raise DataError("<currentMemory> não corresponde exatamente a VM_RAM_MB")

    backing = xmlutil.at_most_one(root, "memoryBacking", "XML de domínio")
    huge_nodes = xmlutil.direct(backing, "hugepages") if backing is not None else []
    if len(huge_nodes) > 1:
        raise DataError("<hugepages> duplicado em <memoryBacking>.")
    if huge_mode == "sim":
        if backing is None or len(huge_nodes) != 1:
            raise DataError("memoryBacking/hugepages precisa existir exatamente uma vez")
        pages = xmlutil.direct(huge_nodes[0], "page")
        if len(pages) != 1:
            raise DataError("hugepages precisa declarar exatamente uma página")
        if _memory_bytes(
            pages[0].get("size", ""), pages[0].get("unit", ""), "KiB", "hugepages/page"
        ) != 1024 ** 3:
            raise DataError("a página declarada no XML não tem exatamente 1 GiB")
    elif huge_mode == "nao" and huge_nodes:
        raise DataError("o XML ainda exige HugePages")

    return {
        "valid": 1,
        "vcpus": vcpus,
        "hugepages_count": len(huge_nodes),
        "fingerprint": xmlutil.fingerprint(root),
    }


# --- Subcomando: comparação semântica ---------------------------------------

# Projeções nomeadas: cada uma declara o que é gerenciado (e portanto pode
# divergir legitimamente) e o que precisa ser idêntico.
_PROJECTIONS: dict[str, tuple[tuple[str, tuple[str, ...], tuple[str, ...]], ...] | None] = {
    "full": None,
    "cpu-unmanaged": (
        ("cputune", ("vcpupin", "emulatorpin"), ()),
        ("memoryBacking", ("hugepages",), ()),
        ("cpu", ("topology",), ("mode", "check", "migratable")),
    ),
    "devices-unmanaged": (
        ("devices", ("disk", "hostdev", "interface", "graphics", "video"), ()),
        ("features", ("hyperv", "kvm"), ()),
    ),
}

PROJECTION_NAMES = tuple(sorted(_PROJECTIONS))


def compare_documents(payload: Mapping[str, Any]) -> dict:
    """Compara dois XML de domínio semanticamente, por projeção declarada.

    `full` prova equivalência total (usada para provar rollback). As projeções
    nomeadas provam que o conteúdo não gerenciado permaneceu idêntico enquanto
    o gerenciado mudou de propósito.
    """
    left_text = _require_text(payload, "left")
    right_text = _require_text(payload, "right")
    projection = _optional_text(payload, "projection", "full")
    if projection not in _PROJECTIONS:
        raise DataError(
            "projeção de comparação desconhecida: %s" % safe_label(projection)
        )
    left = xmlutil.parse_document(left_text, DOMAIN_ROOT, "XML anterior")
    right = xmlutil.parse_document(right_text, DOMAIN_ROOT, "XML observado")
    if projection == "full":
        equal = xmlutil.canonical(left) == xmlutil.canonical(right)
        difference = "" if equal else xmlutil.describe_difference(left, right)
    else:
        specification = _PROJECTIONS[projection]
        assert specification is not None
        left_projection = _project(left, specification)
        right_projection = _project(right, specification)
        equal = left_projection == right_projection
        difference = "" if equal else "projeção %s divergiu" % projection
    return {
        "equal": 1 if equal else 0,
        "difference": difference,
        "fingerprint_left": xmlutil.fingerprint(left),
        "fingerprint_right": xmlutil.fingerprint(right),
    }


def _project(
    root: ET.Element,
    specification: tuple[tuple[str, tuple[str, ...], tuple[str, ...]], ...],
) -> tuple:
    result = []
    for name, ignored_children, ignored_attributes in specification:
        node = xmlutil.at_most_one(root, name, "projeção de comparação")
        result.append(
            None
            if node is None
            else xmlutil.canonical(node, ignored_children, ignored_attributes)
        )
    return tuple(result)


def fingerprint_document(payload: Mapping[str, Any]) -> dict:
    """Fingerprint canônico do XML, para detectar mudança concorrente."""
    xml = _require_text(payload, "xml")
    root = xmlutil.parse_document(xml, DOMAIN_ROOT, "XML de domínio")
    return {"fingerprint": xmlutil.fingerprint(root)}


# --- Subcomando: metadata durável (REQ-WINDOWS-STATE, preparação) -----------


def metadata_state(payload: Mapping[str, Any]) -> dict:
    """Lê a metadata namespaced do projeto sem interpretar power/agent.

    I3 apenas modela a evidência durável de instalação e a vincula ao digest do
    QCOW2. A decisão de gravá-la e a separação instalado/ligado/agent são de
    I4/I9, então aqui não existe nenhuma inferência sobre estado da VM.
    """
    xml = _require_text(payload, "xml")
    expected_digest = _optional_text(payload, "qcow2_digest")
    if expected_digest and _HEX_DIGEST.match(expected_digest) is None:
        raise DataError("qcow2_digest precisa ser um sha256 hexadecimal.")
    root = xmlutil.parse_document(xml, DOMAIN_ROOT, "XML inativo")
    metadata = xmlutil.at_most_one(root, "metadata", "XML de domínio")
    data = {
        "metadata_present": 0,
        "install_present": 0,
        "install_digest": "",
        "install_recorded_at": "",
        "install_source": "",
        "digest_matches": 0,
        "foreign_child_count": 0,
    }
    if metadata is None:
        return data
    data["metadata_present"] = 1
    children = xmlutil.elements(metadata)
    own = [child for child in children if child.tag == METADATA_ROOT]
    data["foreign_child_count"] = len(children) - len(own)
    if len(own) > 1:
        raise DataError("metadata do projeto duplicada no XML do domínio.")
    if not own:
        return data
    install = xmlutil.at_most_one(own[0], METADATA_INSTALL, "metadata do projeto")
    if install is None:
        return data
    digest = install.get("qcow2-digest", "")
    recorded_at = install.get("recorded-at", "")
    source = install.get("source", "")
    if _HEX_DIGEST.match(digest) is None:
        raise DataError("metadata de instalação com digest inválido; revise o XML.")
    if _TIMESTAMP.match(recorded_at) is None:
        raise DataError("metadata de instalação com data inválida; revise o XML.")
    if source not in ("operador", "verificacao"):
        raise DataError("metadata de instalação com origem desconhecida.")
    data["install_present"] = 1
    data["install_digest"] = digest
    data["install_recorded_at"] = recorded_at
    data["install_source"] = source
    data["digest_matches"] = 1 if expected_digest and digest == expected_digest else 0
    return data


# --- Operações de candidato --------------------------------------------------


def _operation_disk_discard(root: ET.Element, options: Mapping[str, Any]) -> bool:
    """Ativa `discard` apenas no disco cujo `source/@file` é o QCOW2 alvo."""
    qcow2 = _require_text(options, "qcow2_path")
    value = _optional_text(options, "value", "unmap")
    if value != "unmap":
        raise DataError("o único valor de discard gerenciado é unmap.")
    records = [
        record
        for record in _disk_records(root)
        if record["device"] == "disk" and record["source_file"] == qcow2
    ]
    if len(records) != 1:
        raise DataError(
            "discos device=disk com source/@file exato para QCOW2_PATH: %d; "
            "esperado 1" % len(records)
        )
    disk = records[0]["element"]
    driver = xmlutil.exactly_one(disk, "driver", "disco alvo de discard")
    if driver.get("discard") == value:
        return False
    driver.set("discard", value)
    return True


def _operation_cpu_pinning(root: ET.Element, options: Mapping[str, Any]) -> bool:
    """Aplica pinning, topologia e página de 1 GiB preservando o não gerenciado."""
    vm_spec = _require_text(options, "cpus_vm")
    host_spec = _require_text(options, "cpus_host")
    vcpus = _require_int(options, "vcpus", 1)
    cores = _require_int(options, "cores", 1)
    threads = _require_int(options, "threads", 1)
    ram_mb = _require_int(options, "ram_mb", 1)
    vm_cpus = _expand_cpu_list(vm_spec, "cpus_vm")
    _expand_cpu_list(host_spec, "cpus_host")
    if len(vm_cpus) != vcpus:
        raise DataError(
            "CPUS_VM possui %d CPUs, mas VM_VCPUS=%d" % (len(vm_cpus), vcpus)
        )
    _reject_unmodeled_memory_topology(root)

    before = xmlutil.fingerprint(root)

    memory = xmlutil.exactly_one(root, "memory", "XML de domínio")
    memory.text = str(ram_mb)
    memory.set("unit", "MiB")
    current = xmlutil.at_most_one(root, "currentMemory", "XML de domínio")
    if current is not None:
        current.text = str(ram_mb)
        current.set("unit", "MiB")

    vcpu = xmlutil.exactly_one(root, "vcpu", "XML de domínio")
    vcpu.text = str(vcpus)
    vcpu.attrib.pop("current", None)
    vcpu.set("placement", "static")
    vcpu.set("cpuset", vm_spec)

    cputune = xmlutil.ensure_one(root, "cputune", _ANCHORS_CPUTUNE)
    for child in list(cputune):
        if child.tag in ("vcpupin", "emulatorpin"):
            cputune.remove(child)
    for index, physical in enumerate(vm_cpus):
        ET.SubElement(
            cputune, "vcpupin", {"vcpu": str(index), "cpuset": str(physical)}
        )
    ET.SubElement(cputune, "emulatorpin", {"cpuset": host_spec})

    cpu = xmlutil.ensure_one(root, "cpu", _ANCHORS_CPU)
    if xmlutil.direct(cpu, "numa"):
        raise DataError("reconfiguração automática com <cpu><numa> não é suportada")
    cpu.set("mode", "host-passthrough")
    cpu.set("check", "none")
    cpu.set("migratable", "off")
    for child in list(cpu):
        if child.tag == "topology":
            cpu.remove(child)
    ET.SubElement(
        cpu,
        "topology",
        {"sockets": "1", "dies": "1", "cores": str(cores), "threads": str(threads)},
    )

    backing = xmlutil.ensure_one(root, "memoryBacking", _ANCHORS_MEMORY_BACKING)
    for child in list(backing):
        if child.tag == "hugepages":
            backing.remove(child)
    hugepages = ET.Element("hugepages")
    hugepages.append(ET.Element("page", {"size": "1", "unit": "GiB"}))
    backing.insert(0, hugepages)
    return xmlutil.fingerprint(root) != before


def _operation_remove_hugepages(root: ET.Element, options: Mapping[str, Any]) -> bool:
    """Remove a exigência de HugePages, apagando `memoryBacking` só se vazio."""
    if options:
        raise DataError("a operação remove-hugepages não aceita opções.")
    backing = xmlutil.at_most_one(root, "memoryBacking", "XML de domínio")
    if backing is None:
        return False
    before = xmlutil.fingerprint(root)
    for child in list(backing):
        if child.tag == "hugepages":
            backing.remove(child)
    if (
        not xmlutil.elements(backing)
        and not backing.attrib
        and not (backing.text or "").strip()
    ):
        root.remove(backing)
    return xmlutil.fingerprint(root) != before


_VIDEO_TAGS = ("graphics", "video", "redirdev", "sound")


def _operation_remove_video(root: ET.Element, options: Mapping[str, Any]) -> bool:
    """Remove a saída gráfica virtual, incluindo o canal spicevmc.

    O backend `<audio type="none"/>` é preservado: o libvirt (observado no 12)
    renormaliza o domínio ao definir e persiste esse elemento mesmo sem som,
    então tratá-lo como resíduo faria a prova de releitura divergir em todo
    define e a transação reverteria uma remoção correta.
    """
    if options:
        raise DataError("a operação remove-video não aceita opções.")
    devices = _devices(root)
    before = xmlutil.fingerprint(root)
    for child in list(devices):
        if child.tag in _VIDEO_TAGS:
            devices.remove(child)
        elif child.tag == "audio" and child.get("type") != "none":
            devices.remove(child)
        elif child.tag == "channel" and child.get("type") == "spicevmc":
            devices.remove(child)
    return xmlutil.fingerprint(root) != before


def _operation_anti_code43(root: ET.Element, options: Mapping[str, Any]) -> bool:
    """Oculta o hypervisor para o driver NVIDIA (vendor_id + kvm/hidden)."""
    vendor_value = _optional_text(options, "vendor_id", "randomid123")
    if not re.match(r"^[A-Za-z0-9]{1,12}$", vendor_value):
        raise DataError("vendor_id do anti-Code 43 fora do formato aceito.")
    features = xmlutil.exactly_one(root, "features", "XML de domínio")
    before = xmlutil.fingerprint(root)
    hyperv = xmlutil.ensure_one(features, "hyperv")
    for child in list(hyperv):
        if child.tag == "vendor_id":
            hyperv.remove(child)
    ET.SubElement(hyperv, "vendor_id", {"state": "on", "value": vendor_value})
    kvm = xmlutil.ensure_one(features, "kvm")
    for child in list(kvm):
        if child.tag == "hidden":
            kvm.remove(child)
    ET.SubElement(kvm, "hidden", {"state": "on"})
    return xmlutil.fingerprint(root) != before


def _operation_nic_source(root: ET.Element, options: Mapping[str, Any]) -> bool:
    """Troca a fonte da NIC identificada pelo MAC, preservando o próprio MAC."""
    mac = normalize_mac(_require_text(options, "mac"), "mac")
    interface_type = _require_text(options, "type")
    if interface_type not in ("bridge", "network"):
        raise DataError("tipo de interface gerenciado apenas para bridge/network.")
    attribute = _require_text(options, "attribute")
    if attribute not in ("bridge", "network"):
        raise DataError("atributo de fonte gerenciado apenas para bridge/network.")
    value = _require_text(options, "value")
    if not re.match(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,31}$", value):
        raise DataError("valor de fonte da NIC fora do formato aceito.")
    devices = _devices(root)
    matches = []
    for index, interface in enumerate(xmlutil.direct(devices, "interface")):
        context = "interface na posição %d" % index
        mac_node = xmlutil.at_most_one(interface, "mac", context)
        if mac_node is None:
            continue
        if xmlutil.attribute(mac_node, "address").strip().lower() == mac:
            matches.append(interface)
    if len(matches) != 1:
        raise DataError(
            "o MAC gerenciado identifica %d interfaces; esperado exatamente 1"
            % len(matches)
        )
    interface = matches[0]
    before = xmlutil.fingerprint(root)
    interface.set("type", interface_type)
    for child in list(interface):
        if child.tag == "source":
            interface.remove(child)
    source = ET.Element("source", {attribute: value})
    children = list(interface)
    inserted = False
    for position, child in enumerate(children):
        if child.tag == "mac":
            interface.insert(position + 1, source)
            inserted = True
            break
    if not inserted:
        interface.insert(0, source)
    if xmlutil.at_most_one(interface, "mac", "interface gerenciada") is None:
        raise DataError("a edição da NIC não preservou o MAC; candidato recusado.")
    return xmlutil.fingerprint(root) != before


def _operation_install_metadata(root: ET.Element, options: Mapping[str, Any]) -> bool:
    """Grava a evidência durável de instalação vinculada ao digest do QCOW2."""
    digest = _require_text(options, "qcow2_digest")
    if _HEX_DIGEST.match(digest) is None:
        raise DataError("qcow2_digest precisa ser um sha256 hexadecimal.")
    recorded_at = _require_text(options, "recorded_at")
    if _TIMESTAMP.match(recorded_at) is None:
        raise DataError("recorded_at precisa usar o formato AAAAMMDD-HHMMSS.")
    source = _optional_text(options, "source", "operador")
    if source not in ("operador", "verificacao"):
        raise DataError("origem da evidência de instalação desconhecida.")
    metadata = xmlutil.ensure_one(root, "metadata", _ANCHORS_METADATA)
    before = xmlutil.fingerprint(root)
    own = xmlutil.direct(metadata, METADATA_ROOT)
    if len(own) > 1:
        raise DataError("metadata do projeto duplicada no XML do domínio.")
    if own:
        container = own[0]
    else:
        container = ET.SubElement(metadata, METADATA_ROOT)
    for child in list(container):
        if child.tag == METADATA_INSTALL:
            container.remove(child)
    ET.SubElement(
        container,
        METADATA_INSTALL,
        {"qcow2-digest": digest, "recorded-at": recorded_at, "source": source},
    )
    return xmlutil.fingerprint(root) != before


def _operation_usb_hostdev(root: ET.Element, options: Mapping[str, Any]) -> bool:
    """Converge um hostdev USB ligado à identidade I6 em metadata namespaced."""
    allowed = {
        "state", "identity_kind", "identity_sha256", "vendor", "product",
        "bus", "device",
    }
    extra = set(options) - allowed
    if extra:
        raise DataError("opção desconhecida na operação usb-hostdev: %s" % safe_label(sorted(extra)[0]))
    state = _require_text(options, "state")
    if state not in ("present", "absent"):
        raise DataError("state de usb-hostdev precisa ser present ou absent.")
    kind = _require_text(options, "identity_kind")
    digest = _require_text(options, "identity_sha256")
    vendor = _require_text(options, "vendor").lower()
    product = _require_text(options, "product").lower()
    if kind not in ("serial", "port") or _HEX_DIGEST.match(digest) is None:
        raise DataError("identidade estável inválida na operação usb-hostdev.")
    if not vendor.startswith("0x"):
        vendor = "0x" + vendor
    if not product.startswith("0x"):
        product = "0x" + product
    if _USB_ID.match(vendor) is None or _USB_ID.match(product) is None:
        raise DataError("VID/PID inválido na operação usb-hostdev.")
    bus = _optional_text(options, "bus")
    device = _optional_text(options, "device")
    if state == "present":
        if not bus.isdigit() or not device.isdigit() or int(bus) <= 0 or int(device) <= 0:
            raise DataError("usb-hostdev present exige bus/device decimais positivos.")
    elif bus or device:
        raise DataError("usb-hostdev absent não aceita bus/device efêmeros.")

    before = xmlutil.fingerprint(root)
    devices = _devices(root)
    alias_name = "ua-vmpass-usb-" + digest[:20]
    metadata = xmlutil.at_most_one(root, "metadata", "XML de domínio")
    own: ET.Element | None = None
    bindings: ET.Element | None = None
    binding_matches: list[ET.Element] = []
    bound_aliases: set[str] = set()
    if metadata is not None:
        own_nodes = xmlutil.direct(metadata, METADATA_ROOT)
        if len(own_nodes) > 1:
            raise DataError("metadata do projeto duplicada no XML do domínio.")
        own = own_nodes[0] if own_nodes else None
        if own is not None:
            binding_nodes = xmlutil.direct(own, METADATA_USB_BINDINGS)
            if len(binding_nodes) > 1:
                raise DataError("metadata de bindings USB duplicada.")
            bindings = binding_nodes[0] if binding_nodes else None
            if bindings is not None:
                for node in xmlutil.direct(bindings, METADATA_USB_BINDING):
                    node_digest = node.get("identity-sha256", "")
                    node_alias = node.get("alias", "")
                    if node_alias:
                        bound_aliases.add(node_alias)
                    if node_digest == digest or node_alias == alias_name:
                        binding_matches.append(node)
    if len(binding_matches) > 1:
        raise DataError("identidade USB duplicada na metadata.")

    hostdev_matches: list[ET.Element] = []
    address_owners: list[ET.Element] = []
    for hostdev in xmlutil.direct(devices, "hostdev"):
        if hostdev.get("type") != "usb":
            continue
        alias_node = xmlutil.at_most_one(hostdev, "alias", "hostdev USB")
        if xmlutil.attribute(alias_node, "name") == alias_name:
            hostdev_matches.append(hostdev)
        source = xmlutil.at_most_one(hostdev, "source", "hostdev USB")
        address = xmlutil.at_most_one(source, "address", "hostdev USB") if source is not None else None
        if state == "present" and xmlutil.attribute(address, "bus") == bus and xmlutil.attribute(address, "device") == device:
            address_owners.append(hostdev)
    if len(hostdev_matches) > 1:
        raise DataError("alias USB duplicado no XML do domínio.")

    if state == "absent":
        if not binding_matches and not hostdev_matches:
            return False
        if len(binding_matches) != 1 or len(hostdev_matches) != 1:
            raise DataError("binding USB órfão ou cardinalidade divergente na remoção.")
        devices.remove(hostdev_matches[0])
        assert bindings is not None
        bindings.remove(binding_matches[0])
        if not xmlutil.elements(bindings):
            assert own is not None
            own.remove(bindings)
        return xmlutil.fingerprint(root) != before

    if binding_matches:
        if address_owners and (len(address_owners) != 1 or address_owners[0] not in hostdev_matches):
            raise DataError("bus/device USB atual já pertence a outro hostdev.")
        binding = binding_matches[0]
        if binding.get("alias") != alias_name or binding.get("identity-kind") != kind \
            or binding.get("vendor", "").lower() != vendor or binding.get("product", "").lower() != product:
            raise DataError("metadata USB existente diverge da identidade pedida.")
        if len(hostdev_matches) != 1:
            raise DataError("metadata USB existente não possui exatamente um hostdev.")
        hostdev = hostdev_matches[0]
        source = xmlutil.exactly_one(hostdev, "source", "hostdev USB gerenciado")
        vendor_node = xmlutil.exactly_one(source, "vendor", "hostdev USB gerenciado")
        product_node = xmlutil.exactly_one(source, "product", "hostdev USB gerenciado")
        if vendor_node.get("id", "").lower() != vendor or product_node.get("id", "").lower() != product:
            raise DataError("hostdev USB existente diverge do binding.")
        address = xmlutil.at_most_one(source, "address", "hostdev USB gerenciado")
        if address is None:
            address = ET.SubElement(source, "address")
        address.set("bus", bus)
        address.set("device", device)
        hostdev.set("managed", "yes")
    else:
        if hostdev_matches:
            raise DataError("hostdev USB com alias gerenciado mas sem metadata.")
        legacy_matches: list[ET.Element] = []
        legacy_address_matches: list[ET.Element] = []
        for candidate in xmlutil.direct(devices, "hostdev"):
            if candidate.get("type") != "usb":
                continue
            candidate_alias = xmlutil.at_most_one(candidate, "alias", "hostdev USB legado")
            candidate_alias_name = xmlutil.attribute(candidate_alias, "name")
            # Alias ligado a outra identidade I6 nunca pode ser adotado. Alias
            # libvirt legado sem metadata, porém, é apenas decoração e pode ser
            # renomeado de forma cardinalizada.
            if candidate_alias_name in bound_aliases:
                continue
            candidate_source = xmlutil.exactly_one(candidate, "source", "hostdev USB legado")
            candidate_vendor = xmlutil.at_most_one(candidate_source, "vendor", "hostdev USB legado")
            candidate_product = xmlutil.at_most_one(candidate_source, "product", "hostdev USB legado")
            if xmlutil.attribute(candidate_vendor, "id").lower() == vendor \
                and xmlutil.attribute(candidate_product, "id").lower() == product:
                legacy_matches.append(candidate)
                candidate_address = xmlutil.at_most_one(
                    candidate_source, "address", "hostdev USB legado"
                )
                if xmlutil.attribute(candidate_address, "bus") == bus \
                    and xmlutil.attribute(candidate_address, "device") == device:
                    legacy_address_matches.append(candidate)

        legacy_match: ET.Element | None = None
        if len(legacy_address_matches) == 1:
            legacy_match = legacy_address_matches[0]
        elif len(legacy_address_matches) > 1:
            raise DataError("mais de um hostdev USB legado possui o mesmo endereço atual.")
        elif len(legacy_matches) == 1:
            legacy_match = legacy_matches[0]
        elif len(legacy_matches) > 1:
            raise DataError("mais de um hostdev USB legado possui o mesmo VID/PID sem endereço discriminador.")

        if address_owners and (
            len(address_owners) != 1 or address_owners[0] is not legacy_match
        ):
            raise DataError("bus/device USB atual já pertence a outro hostdev.")

        if legacy_match is not None:
            hostdev = legacy_match
            source = xmlutil.exactly_one(hostdev, "source", "hostdev USB legado")
            address = xmlutil.at_most_one(source, "address", "hostdev USB legado")
            if address is None:
                address = ET.SubElement(source, "address")
            address.set("bus", bus)
            address.set("device", device)
            candidate_alias = xmlutil.at_most_one(hostdev, "alias", "hostdev USB legado")
            if candidate_alias is None:
                ET.SubElement(hostdev, "alias", {"name": alias_name})
            else:
                candidate_alias.set("name", alias_name)
            hostdev.set("managed", "yes")
        else:
            hostdev = ET.SubElement(devices, "hostdev", {"mode": "subsystem", "type": "usb", "managed": "yes"})
            source = ET.SubElement(hostdev, "source")
            ET.SubElement(source, "vendor", {"id": vendor})
            ET.SubElement(source, "product", {"id": product})
            ET.SubElement(source, "address", {"bus": bus, "device": device})
            ET.SubElement(hostdev, "alias", {"name": alias_name})
        if metadata is None:
            metadata = xmlutil.ensure_one(root, "metadata", _ANCHORS_METADATA)
        if own is None:
            own = ET.SubElement(metadata, METADATA_ROOT)
        if bindings is None:
            bindings = ET.SubElement(own, METADATA_USB_BINDINGS)
        ET.SubElement(bindings, METADATA_USB_BINDING, {
            "alias": alias_name, "identity-kind": kind, "identity-sha256": digest,
            "vendor": vendor, "product": product,
        })
    # A projeção completa precisa continuar cardinalizada depois da edição.
    usb_hostdev_list({"xml": xmlutil.serialize(root)})
    return xmlutil.fingerprint(root) != before


OPERATIONS: dict[str, Callable[[ET.Element, Mapping[str, Any]], bool]] = {
    "anti-code43": _operation_anti_code43,
    "cpu-pinning": _operation_cpu_pinning,
    "disk-discard": _operation_disk_discard,
    "install-metadata": _operation_install_metadata,
    "nic-source": _operation_nic_source,
    "remove-hugepages": _operation_remove_hugepages,
    "remove-video": _operation_remove_video,
    "usb-hostdev": _operation_usb_hostdev,
}

OPERATION_NAMES = tuple(sorted(OPERATIONS))


def _normalize_operations(payload: Mapping[str, Any]) -> list[dict]:
    """Aceita as operações em JSON aninhado ou em pares planos.

    No canal de pares o Bash declara `op_count`, `op_<n>` com o nome e
    `op_<n>_<opcao>` com cada opção. A montagem acontece aqui, com schema
    fechado: chave `op_*` que não caiba nesse formato é erro, nunca ignorada em
    silêncio.
    """
    raw = payload.get("operations")
    if isinstance(raw, list):
        return [entry for entry in raw]
    if raw is not None:
        raise DataError("O campo operations precisa ser uma lista.")
    if "op_count" not in payload:
        raise DataError("nenhuma operação de candidato foi declarada.")
    total = _require_int(payload, "op_count", 1)
    if total > 8:
        raise DataError("mais de oito operações por candidato não são aceitas.")
    operations: list[dict] = []
    for index in range(total):
        name_key = "op_%d" % index
        if name_key not in payload:
            raise DataError(
                "operação declarada em op_count sem o nome correspondente."
            )
        options: dict[str, Any] = {}
        prefix = "op_%d_" % index
        for key, value in payload.items():
            if key.startswith(prefix):
                options[key[len(prefix) :]] = value
        operations.append({"op": payload[name_key], "options": options})
    declared = {"operations", "op_count", "xml"} | {
        "op_%d" % index for index in range(total)
    }
    for key in payload:
        if key in declared:
            continue
        if key.startswith("op_"):
            remainder = key[3:]
            head, _, tail = remainder.partition("_")
            if head.isdigit() and int(head) < total and tail:
                continue
            raise DataError(
                "chave de operação fora do formato op_<n>_<opcao>: %s"
                % safe_label(key)
            )
    return operations


def build_candidate(payload: Mapping[str, Any]) -> tuple[dict, str]:
    """Aplica as operações declaradas e devolve os fatos e o texto candidato.

    Nada é escrito aqui: quem publica o candidato é a CLI, no arquivo
    controlado que a ponte criou. O Bash valida com `virt-xml-validate` antes
    do primeiro `define`.
    """
    xml = _require_text(payload, "xml")
    operations = _normalize_operations(payload)
    if not operations:
        raise DataError("nenhuma operação de candidato foi declarada.")
    if len(operations) > 8:
        raise DataError("mais de oito operações por candidato não são aceitas.")
    root = xmlutil.parse_document(xml, DOMAIN_ROOT, "XML de origem")
    fingerprint_before = xmlutil.fingerprint(root)
    applied: list[str] = []
    changed = 0
    for entry in operations:
        if not isinstance(entry, dict):
            raise DataError("cada operação precisa ser um objeto JSON.")
        name = entry.get("op")
        if not isinstance(name, str) or name not in OPERATIONS:
            raise DataError("operação de candidato desconhecida: %s" % safe_label(name))
        if name in applied:
            raise DataError("operação repetida no mesmo candidato: %s" % safe_label(name))
        options = entry.get("options", {})
        if options is None:
            options = {}
        if not isinstance(options, dict):
            raise DataError("as opções de uma operação precisam ser um objeto JSON.")
        if OPERATIONS[name](root, options):
            changed = 1
        applied.append(name)
    candidate = xmlutil.serialize(root)
    # Releitura do próprio candidato: garante que o texto emitido é analisável
    # e que o fingerprint publicado descreve exatamente esses bytes.
    reparsed = xmlutil.parse_document(candidate, DOMAIN_ROOT, "XML candidato")
    data = {
        "changed": changed,
        "operation_count": len(applied),
        "fingerprint_before": fingerprint_before,
        "fingerprint_after": xmlutil.fingerprint(reparsed),
    }
    return data, candidate
