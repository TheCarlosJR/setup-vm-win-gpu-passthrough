"""Inventário e identidades físicas puras da fase I6.

Este módulo nunca sonda o host nem abre caminhos. Ele recebe capturas já feitas
pelo Bash, valida schemas fechados, normaliza os fatos e devolve planos
Declarativos. Publicação, confirmação, revalidação e efeitos continuam no Bash.
"""
from __future__ import annotations

import hashlib
import json
import re
from typing import Any, Iterable, Mapping

from .errors import ConflictError, DataError
from .protocol import safe_label

SCHEMA_VERSION = 1
STATES = frozenset({"present", "absent", "unavailable", "error", "empty"})
REASONS = {
    "present": frozenset({""}),
    "empty": frozenset({""}),
    "absent": frozenset({"not_found"}),
    "unavailable": frozenset(
        {"probe_missing", "permission_denied", "legacy_not_captured"}
    ),
    "error": frozenset({"probe_failed", "malformed_capture"}),
}
FACT_NAMES = ("cpu", "memory", "pci", "disks", "usb", "interfaces", "boot")
COLLECTION_FACTS = frozenset({"pci", "disks", "usb", "interfaces"})
CPU_FIELDS = (
    ("Architecture", "architecture", str),
    ("CPU(s)", "cpu_count", int),
    ("On-line CPU(s) list", "online", str),
    ("Thread(s) per core", "threads_per_core", int),
    ("Core(s) per socket", "cores_per_socket", int),
    ("Socket(s)", "sockets", int),
    ("Model name", "model", str),
)
MAX_TEXT_BYTES = 4 * 1024 * 1024
MAX_ITEMS = 4096
_HEX4 = re.compile(r"^[0-9a-f]{4}$")
_HEX64 = re.compile(r"^[0-9a-f]{64}$")
_BDF = re.compile(r"^(?:[0-9a-f]{4}:)?[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$")
_MAJMIN = re.compile(r"^[0-9]+:[0-9]+$")
_MAC = re.compile(r"^[0-9a-f]{2}(?::[0-9a-f]{2}){5}$")
_EXECUTABLE = re.compile(
    r"(?:\$\(|\$\{|`|^#!|^[ \t]*(?:source|eval|exec|bash|sh|sudo)(?:[ \t]|$))",
    re.MULTILINE,
)
_SECTION = re.compile(r"^== ([^=\r\n]+) ==$", re.MULTILINE)
_V1_RECORD = re.compile(r"^(CPU|RAM_MIB|PCI|DISK)\|", re.MULTILINE)
_ALLOWED_CONTROLS = frozenset({"\n", "\r", "\t"})


def _closed(payload: Mapping[str, Any], required: Iterable[str], optional: Iterable[str] = ()) -> None:
    required_set = frozenset(required)
    allowed = required_set | frozenset(optional)
    missing = sorted(required_set - payload.keys())
    extra = sorted(payload.keys() - allowed)
    if missing:
        raise DataError("Campos obrigatórios ausentes: %s." % ", ".join(missing))
    if extra:
        raise DataError(
            "Campos fora do schema fechado: %s."
            % ", ".join(safe_label(item) for item in extra)
        )


def _text(payload: Mapping[str, Any], key: str, allow_empty: bool = True) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or (not allow_empty and not value):
        raise DataError("O campo %s precisa ser texto%s." % (safe_label(key), " não vazio" if not allow_empty else ""))
    _validate_text(value, key)
    return value


def _validate_text(value: str, label: str, hostile: bool = False) -> None:
    if len(value.encode("utf-8")) > MAX_TEXT_BYTES:
        raise DataError("O campo %s excede o limite." % safe_label(label))
    if "\x00" in value:
        raise DataError("O campo %s contém NUL." % safe_label(label))
    for character in value:
        if ord(character) < 32 and character not in _ALLOWED_CONTROLS:
            raise DataError("O campo %s contém controle proibido." % safe_label(label))
    if hostile and _EXECUTABLE.search(value):
        raise DataError("O relatório contém forma executável proibida.")


def _canonical(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _digest(value: Any) -> str:
    return hashlib.sha256(_canonical(value).encode("utf-8")).hexdigest()


def _json_text(value: str, label: str) -> Any:
    try:
        return json.loads(value)
    except (TypeError, ValueError) as error:
        raise DataError("%s não contém JSON válido." % safe_label(label)) from error


def _state(state: Any, reason: Any, raw_data: str, value: Any, collection: bool) -> dict:
    if not isinstance(state, str) or state not in STATES:
        raise DataError("Estado de fato desconhecido.")
    if not isinstance(reason, str) or reason not in REASONS[state]:
        raise DataError("Razão incompatível com o estado %s." % state)
    if state == "present":
        if not raw_data.strip():
            raise DataError("Fato presente sem captura.")
        if value is None or (collection and not value):
            raise DataError("Fato presente sem valor normalizado.")
    elif raw_data:
        raise DataError("Fato fora do estado present carrega dados.")
    if state == "empty":
        value = [] if collection else None
    elif state != "present":
        value = None
    return {"reason": reason, "state": state, "value": value}


def _parse_key_values(text: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = key.strip()
        if key in result:
            raise DataError("Chave duplicada em captura de CPU.")
        result[key] = value.strip()
    return result


def _parse_cpu(text: str) -> dict:
    fields = _parse_key_values(text)
    value: dict[str, Any] = {}
    for source, target, kind in CPU_FIELDS:
        raw = fields.get(source, "")
        if not raw:
            raise DataError("Captura de CPU sem o campo obrigatório %s." % source)
        if kind is int:
            if not raw.isdigit() or int(raw) <= 0:
                raise DataError("Topologia de CPU contém inteiro inválido.")
            value[target] = int(raw)
        else:
            value[target] = " ".join(raw.split())
    total = value["threads_per_core"] * value["cores_per_socket"] * value["sockets"]
    if total != value["cpu_count"]:
        raise DataError("Topologia de CPU incoerente com a contagem total.")
    return value


def _parse_memory(text: str) -> dict:
    matches = re.findall(r"(?m)^MemTotal:\s*([0-9]+)\s+kB\s*$", text)
    if len(matches) != 1:
        raise DataError("Captura de memória sem MemTotal único.")
    kib = int(matches[0])
    if kib <= 0:
        raise DataError("MemTotal precisa ser positivo.")
    return {"total_mib": kib // 1024}


def _normalize_bdf(value: str) -> str:
    lowered = value.strip().lower()
    if _BDF.fullmatch(lowered) is None:
        raise DataError("BDF inválido na captura PCI.")
    return lowered if lowered.count(":") == 2 else "0000:" + lowered


def _parse_pci(text: str) -> list[dict]:
    records: list[dict] = []
    seen: set[str] = set()
    for line in text.splitlines():
        if not line.strip():
            continue
        pieces = line.split()
        bdf = _normalize_bdf(pieces[0])
        classes = re.findall(r"\[([0-9A-Fa-f]{4})\](?=:)", line)
        ids = re.findall(r"\[([0-9A-Fa-f]{4}:[0-9A-Fa-f]{4})\]", line)
        if len(classes) != 1 or not ids:
            raise DataError("Linha PCI sem classe e vendor:device únicos.")
        if bdf in seen:
            raise DataError("BDF duplicado na captura PCI.")
        seen.add(bdf)
        records.append(
            {"bdf": bdf, "class": classes[0].lower(), "vendor_device": ids[-1].lower()}
        )
    return sorted(records, key=lambda item: tuple(int(part, 16) for part in re.split(r"[:.]", item["bdf"])))


def _parse_by_id(text: str) -> dict[str, list[str]]:
    by_major: dict[str, list[str]] = {}
    seen: set[str] = set()
    for line in text.splitlines():
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) != 2:
            raise DataError("Mapa by-id fora do formato basename<TAB>major:minor.")
        name, major = parts
        if not re.fullmatch(r"[A-Za-z0-9_.:+-]{1,255}", name) or _MAJMIN.fullmatch(major) is None:
            raise DataError("Mapa by-id contém alias ou major:minor inválido.")
        if name in seen or "-part" in name:
            raise DataError("Mapa by-id contém alias duplicado ou de partição.")
        seen.add(name)
        by_major.setdefault(major, []).append(name)
    return {key: sorted(value) for key, value in by_major.items()}


def _parse_udev(text: str) -> tuple[dict[str, dict[str, str]], list[dict[str, str]]]:
    by_major: dict[str, dict[str, str]] = {}
    usb: list[dict[str, str]] = []
    record: dict[str, str] = {}

    def finish() -> None:
        nonlocal record
        if not record:
            return
        major = record.get("MAJOR", "") + ":" + record.get("MINOR", "")
        # major:minor só é único DENTRO de um namespace de dispositivo: o major
        # 7 de bloco (loop0, loop1, ...) e o major 7 de caractere (/dev/vcs,
        # /dev/vcs1, ...) coexistem no mesmo banco udev sem qualquer conflito
        # real. Este mapa é consumido somente para enriquecer discos, logo um
        # registro que se declara de outro subsistema nunca entra nele. Quem não
        # declara subsistema algum mantém o tratamento anterior, e a checagem de
        # conflito continua valendo para os que entram.
        subsystem = record.get("SUBSYSTEM", "block")
        if _MAJMIN.fullmatch(major) and subsystem == "block":
            allowed = {
                key: value
                for key, value in record.items()
                if key
                in {
                    "DEVNAME",
                    "ID_WWN_WITH_EXTENSION",
                    "ID_WWN",
                    "ID_SERIAL",
                    "ID_SERIAL_SHORT",
                    "ID_VENDOR_ID",
                    "ID_MODEL_ID",
                    "ID_PATH",
                    "DEVPATH",
                    "BUSNUM",
                    "DEVNUM",
                    "DEVTYPE",
                }
            }
            previous = by_major.get(major)
            if previous is not None and previous != allowed:
                raise DataError("Banco udev contém major:minor conflitante.")
            by_major[major] = allowed
        if record.get("DEVTYPE") == "usb_device" and record.get("ID_VENDOR_ID") and record.get("ID_MODEL_ID"):
            usb.append(dict(record))
        record = {}

    for line in text.splitlines() + [""]:
        if not line:
            finish()
            continue
        if line.startswith("P: "):
            record["DEVPATH"] = line[3:].strip()
        elif line.startswith("E: ") and "=" in line[3:]:
            key, value = line[3:].split("=", 1)
            if key in record and record[key] != value:
                raise DataError("Banco udev contém propriedade conflitante.")
            record[key] = value.strip()
    return by_major, usb


def _flatten_lsblk(raw: Any) -> tuple[dict[str, dict], dict[str, set[str]]]:
    if not isinstance(raw, dict) or set(raw) != {"blockdevices"} or not isinstance(raw["blockdevices"], list):
        raise DataError("Captura lsblk JSON fora do schema esperado.")
    nodes: dict[str, dict] = {}
    parents: dict[str, set[str]] = {}

    def walk(item: Any, parent: str = "") -> None:
        if not isinstance(item, dict):
            raise DataError("Nó lsblk precisa ser objeto.")
        normalized = {str(key).lower(): value for key, value in item.items()}
        major = normalized.get("maj:min", normalized.get("maj_min", ""))
        if not isinstance(major, str) or _MAJMIN.fullmatch(major) is None:
            raise DataError("Nó lsblk sem major:minor válido.")
        children = normalized.pop("children", []) or []
        if not isinstance(children, list):
            raise DataError("children do lsblk precisa ser lista.")
        kept = {
            key: normalized.get(key, "")
            for key in ("name", "kname", "path", "type", "size", "model", "serial", "wwn", "pkname")
        }
        previous = nodes.get(major)
        if previous is not None and previous != kept:
            raise DataError("Nó lsblk duplicado com propriedades conflitantes.")
        nodes[major] = kept
        if parent:
            parents.setdefault(major, set()).add(parent)
        for child in children:
            walk(child, major)

    for top in raw["blockdevices"]:
        walk(top)
    if len(nodes) > MAX_ITEMS:
        raise DataError("Captura lsblk excede a cardinalidade aceita.")
    return nodes, parents


def _clean_wwn(value: Any) -> str:
    if not isinstance(value, str):
        return ""
    lowered = value.strip().lower()
    return lowered[2:] if lowered.startswith("0x") else lowered


def _disk_records(block_json: str, by_id_text: str, udev_text: str) -> tuple[list[dict], dict[str, dict], dict[str, set[str]]]:
    nodes, parents = _flatten_lsblk(_json_text(block_json, "block_json"))
    by_id = _parse_by_id(by_id_text)
    udev, _ = _parse_udev(udev_text)
    disks: list[dict] = []
    identities: dict[str, dict] = {}
    for major, node in nodes.items():
        if node["type"] != "disk":
            continue
        props = udev.get(major, {})
        wwn_extension = _clean_wwn(props.get("ID_WWN_WITH_EXTENSION", ""))
        wwn = _clean_wwn(props.get("ID_WWN", "") or node.get("wwn", ""))
        serial = str(props.get("ID_SERIAL_SHORT", "") or props.get("ID_SERIAL", "") or node.get("serial", "")).strip()
        aliases = by_id.get(major, [])
        if wwn_extension:
            kind, identity = "wwn_extension", wwn_extension
        elif wwn:
            kind, identity = "wwn", wwn
        elif serial:
            kind, identity = "serial", serial
        elif aliases:
            kind, identity = "by_id", aliases[0]
        else:
            kind, identity = "", ""
        try:
            size = int(node.get("size", 0) or 0)
        except (TypeError, ValueError) as error:
            raise DataError("Tamanho de disco inválido no lsblk.") from error
        record = {
            "by_id": aliases,
            "bytes": size,
            "identity": identity,
            "identity_kind": kind,
            "major_minor": major,
            "model": " ".join(str(node.get("model", "")).split()),
            "serial": serial,
            "wwn": wwn,
            "wwn_extension": wwn_extension,
        }
        if identity:
            key = kind + ":" + identity
            stable = {field: record[field] for field in ("identity_kind", "identity", "serial", "wwn", "wwn_extension")}
            previous = identities.get(key)
            if previous is not None:
                # Uma identidade persistente precisa apontar para um único nó
                # físico. Mesmo evidência textual idêntica em major:minor
                # distintos é clone/ambiguidade, nunca equivalência segura.
                raise DataError("Dois discos físicos compartilham a mesma identidade estável.")
            identities[key] = stable
        disks.append(record)
    disks.sort(key=lambda item: (item["identity_kind"], item["identity"], item["major_minor"]))
    return disks, nodes, parents


def _parse_usb_json(value: Any) -> list[dict]:
    if not isinstance(value, list) or len(value) > MAX_ITEMS:
        raise DataError("Captura USB precisa ser uma lista limitada.")
    allowed = {"vendor", "product", "serial", "port", "bus", "device", "id_path", "devpath", "controller", "port_chain"}
    result: list[dict] = []
    for entry in value:
        if not isinstance(entry, dict) or not set(entry) <= allowed:
            raise DataError("Registro USB fora do schema fechado.")
        vendor = str(entry.get("vendor", "")).strip().lower().removeprefix("0x")
        product = str(entry.get("product", "")).strip().lower().removeprefix("0x")
        if _HEX4.fullmatch(vendor) is None or _HEX4.fullmatch(product) is None:
            raise DataError("Registro USB contém VID/PID inválido.")
        serial = str(entry.get("serial", "")).strip()
        port = str(entry.get("port", "") or entry.get("id_path", "") or entry.get("devpath", "")).strip()
        if not port and entry.get("controller") and entry.get("port_chain"):
            port = "%s/%s" % (entry["controller"], entry["port_chain"])
        bus = str(entry.get("bus", "")).strip()
        device = str(entry.get("device", "")).strip()
        if bus and not bus.isdigit() or device and not device.isdigit():
            raise DataError("Registro USB contém bus/device inválido.")
        result.append({"vendor": vendor, "product": product, "serial": serial, "port": port, "bus": int(bus) if bus else 0, "device": int(device) if device else 0})
    return result


def _usb_records(text: str) -> list[dict]:
    stripped = text.lstrip()
    if stripped.startswith("["):
        records = _parse_usb_json(_json_text(text, "usb_data"))
    else:
        _by_major, raw = _parse_udev(text)
        records = []
        for entry in raw:
            vendor = entry.get("ID_VENDOR_ID", "").lower()
            product = entry.get("ID_MODEL_ID", "").lower()
            if _HEX4.fullmatch(vendor) is None or _HEX4.fullmatch(product) is None:
                raise DataError("Banco udev contém VID/PID USB inválido.")
            bus = entry.get("BUSNUM", "").lstrip("0") or "0"
            device = entry.get("DEVNUM", "").lstrip("0") or "0"
            if not bus.isdigit() or not device.isdigit():
                raise DataError("Banco udev contém bus/device USB inválido.")
            records.append({"vendor": vendor, "product": product, "serial": entry.get("ID_SERIAL_SHORT", "").strip(), "port": entry.get("ID_PATH", "").strip() or entry.get("DEVPATH", "").strip(), "bus": int(bus), "device": int(device)})
    normalized: list[dict] = []
    identities: dict[tuple[str, str], dict] = {}
    for record in records:
        if record["serial"]:
            kind = "serial"
            raw_identity = "usb-serial\0%s\0%s\0%s" % (record["vendor"], record["product"], record["serial"])
        elif record["port"]:
            kind = "port"
            raw_identity = "usb-port\0%s\0%s\0%s" % (record["port"], record["vendor"], record["product"])
        else:
            kind = "unavailable"
            raw_identity = ""
        digest = hashlib.sha256(raw_identity.encode("utf-8")).hexdigest() if raw_identity else ""
        item = dict(record)
        item.update({"identity_kind": kind, "identity_sha256": digest})
        if digest:
            key = (kind, digest)
            previous = identities.get(key)
            stable = {name: item[name] for name in ("vendor", "product", "serial", "port")}
            if previous is not None and previous != stable:
                raise DataError("Identidade USB repetida com evidência conflitante.")
            identities[key] = stable
        normalized.append(item)
    normalized.sort(key=lambda item: (item["identity_kind"], item["identity_sha256"], item["vendor"], item["product"], item["bus"], item["device"]))
    return normalized


def _parse_interfaces(text: str) -> list[dict]:
    raw = _json_text(text, "interfaces_data")
    if not isinstance(raw, list) or len(raw) > MAX_ITEMS:
        raise DataError("Captura de interfaces precisa ser uma lista limitada.")
    result: list[dict] = []
    seen: set[str] = set()
    for item in raw:
        if not isinstance(item, dict):
            raise DataError("Registro de interface precisa ser objeto.")
        name = str(item.get("ifname", item.get("name", ""))).strip()
        mac = str(item.get("address", item.get("mac", ""))).strip().lower()
        permanent = str(item.get("permaddr", item.get("permanent_mac", ""))).strip().lower()
        key = permanent or mac
        if not name or _MAC.fullmatch(key) is None or (mac and _MAC.fullmatch(mac) is None):
            raise DataError("Registro de interface sem nome/MAC válido.")
        if key in seen:
            raise DataError("MAC físico duplicado na captura de interfaces.")
        seen.add(key)
        result.append({"key": key, "kind": str(item.get("link_type", item.get("kind", "")) or "ether"), "mac": mac, "name": name, "permanent_mac": permanent})
    return sorted(result, key=lambda item: (item["key"], item["name"]))


def _parse_boot(text: str) -> dict:
    values: dict[str, str] = {}
    for line in text.splitlines():
        if "=" not in line:
            raise DataError("Captura de boot fora do formato CHAVE=valor.")
        key, value = line.split("=", 1)
        if key in values:
            raise DataError("Captura de boot contém chave duplicada.")
        values[key] = value.strip()
    if set(values) != {"FIRMWARE", "SECURE_BOOT", "BOOTLOADER"}:
        raise DataError("Captura de boot incompleta ou com chave desconhecida.")
    if values["FIRMWARE"] not in {"uefi", "bios"} or values["SECURE_BOOT"] not in {"enabled", "disabled", "unknown"} or values["BOOTLOADER"] not in {"grub", "kernelstub", "unknown"}:
        raise DataError("Captura de boot contém valor desconhecido.")
    return {"firmware": values["FIRMWARE"], "secure_boot": values["SECURE_BOOT"], "bootloader": values["BOOTLOADER"]}


def _fact(payload: Mapping[str, Any], name: str, parser: Any, data_key: str | None = None) -> dict:
    key = data_key or name + "_data"
    state = payload[name + "_state"]
    reason = payload[name + "_reason"]
    raw = _text(payload, key)
    value = parser(raw) if state == "present" else None
    return _state(state, reason, raw, value, name in COLLECTION_FACTS)


def normalize_capture(payload: Mapping[str, Any]) -> dict:
    required = {
        "schema_version", "cpu_state", "cpu_reason", "cpu_data",
        "memory_state", "memory_reason", "memory_data", "memory_report",
        "pci_state", "pci_reason", "pci_data", "disks_state", "disks_reason",
        "block_json", "block_by_id_map", "udev_database", "usb_state",
        "usb_reason", "usb_data", "interfaces_state", "interfaces_reason",
        "interfaces_data", "boot_state", "boot_reason", "boot_data",
        "baseboard_report", "bios_report", "iommu_report",
    }
    _closed(payload, required)
    if str(payload["schema_version"]) != str(SCHEMA_VERSION):
        raise DataError("Versão do schema de captura não suportada.")
    facts: dict[str, dict] = {}
    facts["cpu"] = _fact(payload, "cpu", _parse_cpu)
    facts["memory"] = _fact(payload, "memory", _parse_memory)
    facts["pci"] = _fact(payload, "pci", _parse_pci)
    disk_data = _text(payload, "block_json")
    if payload["disks_state"] == "present":
        disk_value, _nodes, _parents = _disk_records(disk_data, _text(payload, "block_by_id_map"), _text(payload, "udev_database"))
    else:
        disk_value = None
    facts["disks"] = _state(payload["disks_state"], payload["disks_reason"], disk_data, disk_value, True)
    facts["usb"] = _fact(payload, "usb", _usb_records)
    facts["interfaces"] = _fact(payload, "interfaces", _parse_interfaces)
    facts["boot"] = _fact(payload, "boot", _parse_boot)
    snapshot = {"facts": facts, "schema_version": SCHEMA_VERSION}
    _validate_snapshot(snapshot)
    return snapshot


def _normalized_text(value: Any, label: str, allow_empty: bool = True) -> str:
    if not isinstance(value, str) or (not allow_empty and not value):
        raise DataError("Valor textual inválido em %s." % label)
    _validate_text(value, label)
    return value


def _validate_normalized_value(name: str, value: Any) -> None:
    """Valida integralmente o schema aninhado carregado do marcador V2."""
    if name == "cpu":
        keys = {target for _source, target, _kind in CPU_FIELDS}
        if not isinstance(value, dict) or set(value) != keys:
            raise DataError("Fato CPU normalizado fora do schema fechado.")
        for _source, target, kind in CPU_FIELDS:
            item = value[target]
            if kind is int:
                if type(item) is not int or item <= 0:
                    raise DataError("Fato CPU contém inteiro inválido.")
            else:
                _normalized_text(item, "cpu.%s" % target, False)
        if value["threads_per_core"] * value["cores_per_socket"] * value["sockets"] != value["cpu_count"]:
            raise DataError("Fato CPU normalizado contém topologia incoerente.")
        return

    if name == "memory":
        if not isinstance(value, dict) or set(value) != {"total_mib"} \
            or type(value["total_mib"]) is not int or value["total_mib"] <= 0:
            raise DataError("Fato de memória normalizado fora do schema fechado.")
        return

    if name == "boot":
        if not isinstance(value, dict) or set(value) != {"firmware", "secure_boot", "bootloader"}:
            raise DataError("Fato de boot normalizado fora do schema fechado.")
        if value["firmware"] not in {"uefi", "bios"} \
            or value["secure_boot"] not in {"enabled", "disabled", "unknown"} \
            or value["bootloader"] not in {"grub", "kernelstub", "unknown"}:
            raise DataError("Fato de boot normalizado contém valor desconhecido.")
        return

    if not isinstance(value, list) or not value or len(value) > MAX_ITEMS:
        raise DataError("Coleção normalizada %s possui cardinalidade inválida." % name)

    if name == "pci":
        seen: set[str] = set()
        for item in value:
            if not isinstance(item, dict) or set(item) != {"bdf", "class", "vendor_device"}:
                raise DataError("Registro PCI normalizado fora do schema fechado.")
            bdf = _normalized_text(item["bdf"], "pci.bdf", False)
            if _normalize_bdf(bdf) != bdf or bdf in seen \
                or _HEX4.fullmatch(_normalized_text(item["class"], "pci.class", False)) is None \
                or re.fullmatch(r"[0-9a-f]{4}:[0-9a-f]{4}", _normalized_text(item["vendor_device"], "pci.vendor_device", False)) is None:
                raise DataError("Registro PCI normalizado inválido ou duplicado.")
            seen.add(bdf)
        expected = sorted(value, key=lambda item: tuple(int(part, 16) for part in re.split(r"[:.]", item["bdf"])))
        if value != expected:
            raise DataError("Coleção PCI normalizada fora da ordem canônica.")
        return

    if name == "disks":
        live_keys = {"by_id", "bytes", "identity", "identity_kind", "major_minor", "model", "serial", "wwn", "wwn_extension"}
        legacy_keys = live_keys - {"major_minor"}
        majors: set[str] = set()
        identities: set[tuple[str, str]] = set()
        for item in value:
            item_keys = set(item) if isinstance(item, dict) else set()
            if not isinstance(item, dict) or (item_keys != live_keys and item_keys != legacy_keys):
                raise DataError("Registro de disco normalizado fora do schema fechado.")
            if type(item["bytes"]) is not int or item["bytes"] <= 0:
                raise DataError("Registro de disco contém tamanho inválido.")
            aliases = item["by_id"]
            if not isinstance(aliases, list) or len(aliases) > MAX_ITEMS \
                or any(not isinstance(alias, str) or not alias for alias in aliases) \
                or len(set(aliases)) != len(aliases):
                raise DataError("Registro de disco contém aliases inválidos.")
            for field in ("identity", "identity_kind", "model", "serial", "wwn", "wwn_extension"):
                _normalized_text(item[field], "disk.%s" % field)
            kind = item["identity_kind"]
            identity = item["identity"]
            expected_identity = {
                "wwn_extension": item["wwn_extension"], "wwn": item["wwn"],
                "serial": item["serial"], "by_id": aliases[0] if aliases else "",
                "": "", "legacy": "",
            }
            if kind not in expected_identity or identity != expected_identity[kind] \
                or kind in {"wwn_extension", "wwn", "serial", "by_id"} and not identity:
                raise DataError("Registro de disco contém identidade incoerente.")
            if identity and (kind, identity) in identities:
                raise DataError("Coleção de discos contém identidade estável duplicada.")
            if identity:
                identities.add((kind, identity))
            major = item.get("major_minor", "")
            if major:
                if not isinstance(major, str) or _MAJMIN.fullmatch(major) is None or major in majors:
                    raise DataError("Registro de disco contém major:minor inválido ou duplicado.")
                majors.add(major)
        expected = sorted(value, key=lambda item: (item["identity_kind"], item["identity"], item.get("major_minor", "")))
        if value != expected:
            raise DataError("Coleção de discos fora da ordem canônica.")
        return

    if name == "usb":
        keys = {"vendor", "product", "serial", "port", "bus", "device", "identity_kind", "identity_sha256"}
        identities: set[tuple[str, str]] = set()
        for item in value:
            if not isinstance(item, dict) or set(item) != keys:
                raise DataError("Registro USB normalizado fora do schema fechado.")
            vendor = _normalized_text(item["vendor"], "usb.vendor", False)
            product = _normalized_text(item["product"], "usb.product", False)
            serial = _normalized_text(item["serial"], "usb.serial")
            port = _normalized_text(item["port"], "usb.port")
            kind = _normalized_text(item["identity_kind"], "usb.identity_kind", False)
            digest = _normalized_text(item["identity_sha256"], "usb.identity_sha256")
            if _HEX4.fullmatch(vendor) is None or _HEX4.fullmatch(product) is None \
                or type(item["bus"]) is not int or item["bus"] < 0 \
                or type(item["device"]) is not int or item["device"] < 0:
                raise DataError("Registro USB normalizado contém endereço ou VID/PID inválido.")
            if kind == "serial":
                raw = "usb-serial\0%s\0%s\0%s" % (vendor, product, serial)
                if not serial:
                    raise DataError("Identidade USB serial sem serial.")
            elif kind == "port":
                raw = "usb-port\0%s\0%s\0%s" % (port, vendor, product)
                if not port:
                    raise DataError("Identidade USB por porta sem porta.")
            elif kind == "unavailable" and not digest and not serial and not port:
                raw = ""
            else:
                raise DataError("Identidade USB normalizada incoerente.")
            expected_digest = hashlib.sha256(raw.encode("utf-8")).hexdigest() if raw else ""
            if digest != expected_digest or digest and (kind, digest) in identities:
                raise DataError("Digest USB inválido ou duplicado.")
            if digest:
                identities.add((kind, digest))
        expected = sorted(value, key=lambda item: (item["identity_kind"], item["identity_sha256"], item["vendor"], item["product"], item["bus"], item["device"]))
        if value != expected:
            raise DataError("Coleção USB fora da ordem canônica.")
        return

    if name == "interfaces":
        keys = {"key", "kind", "mac", "name", "permanent_mac"}
        seen: set[str] = set()
        for item in value:
            if not isinstance(item, dict) or set(item) != keys:
                raise DataError("Registro de interface normalizado fora do schema fechado.")
            key = _normalized_text(item["key"], "interface.key", False)
            mac = _normalized_text(item["mac"], "interface.mac")
            permanent = _normalized_text(item["permanent_mac"], "interface.permanent_mac")
            _normalized_text(item["name"], "interface.name", False)
            _normalized_text(item["kind"], "interface.kind", False)
            if _MAC.fullmatch(key) is None or mac and _MAC.fullmatch(mac) is None \
                or permanent and _MAC.fullmatch(permanent) is None \
                or key != (permanent or mac) or key in seen:
                raise DataError("Registro de interface normalizado inválido ou duplicado.")
            seen.add(key)
        if value != sorted(value, key=lambda item: (item["key"], item["name"])):
            raise DataError("Coleção de interfaces fora da ordem canônica.")
        return

    raise DataError("Fato normalizado desconhecido.")


def _validate_snapshot(snapshot: Any) -> dict:
    if not isinstance(snapshot, dict) or set(snapshot) != {"schema_version", "facts"} or snapshot.get("schema_version") != SCHEMA_VERSION:
        raise DataError("Snapshot fora do schema fechado I6.")
    facts = snapshot.get("facts")
    if not isinstance(facts, dict) or set(facts) != set(FACT_NAMES):
        raise DataError("Snapshot com conjunto de fatos inválido.")
    for name in FACT_NAMES:
        fact = facts[name]
        if not isinstance(fact, dict) or set(fact) != {"state", "reason", "value"}:
            raise DataError("Fato %s fora do schema fechado." % name)
        state = fact["state"]
        reason = fact["reason"]
        if state not in STATES or reason not in REASONS[state]:
            raise DataError("Fato %s contém estado/razão incompatível." % name)
        if state == "present" and fact["value"] is None:
            raise DataError("Fato presente sem valor.")
        if state == "present":
            _validate_normalized_value(name, fact["value"])
        if state == "empty" and fact["value"] != ([] if name in COLLECTION_FACTS else None):
            raise DataError("Fato vazio contém valor incompatível.")
        if state not in {"present", "empty"} and fact["value"] is not None:
            raise DataError("Fato indisponível contém valor.")
    return snapshot


def _section_map(report: str) -> dict[str, str]:
    matches = list(_SECTION.finditer(report))
    if not matches:
        raise DataError("Relatório sem seções reconhecíveis.")
    sections: dict[str, str] = {}
    for index, match in enumerate(matches):
        name = match.group(1).strip()
        if name in sections:
            raise DataError("Relatório contém seção duplicada.")
        start = match.end() + (1 if report[match.end():].startswith("\n") else 0)
        end = matches[index + 1].start() if index + 1 < len(matches) else len(report)
        sections[name] = report[start:end].rstrip("\r\n")
    return sections


def _unavailable_facts() -> dict[str, dict]:
    return {name: {"state": "unavailable", "reason": "legacy_not_captured", "value": None} for name in ("usb", "interfaces", "boot")}


def _parse_v1_identity(text: str, source_format: str = "current-v1") -> tuple[dict, str]:
    cpu_raw: dict[str, str] = {}
    memory: int | None = None
    pci: list[dict] = []
    disks: list[dict] = []
    pci_seen: set[str] = set()
    disk_seen: set[tuple[str, str, int]] = set()
    for line in text.splitlines():
        if not line:
            continue
        parts = line.split("|")
        if parts[0] == "CPU" and len(parts) == 3:
            if parts[1] in cpu_raw:
                raise DataError("Identidade atual contém chave CPU duplicada.")
            cpu_raw[parts[1]] = parts[2]
        elif parts[0] == "RAM_MIB" and len(parts) == 2:
            if memory is not None or not parts[1].isdigit() or int(parts[1]) <= 0:
                raise DataError("Identidade atual contém RAM inválida ou duplicada.")
            memory = int(parts[1])
        elif parts[0] == "PCI" and len(parts) == 4:
            bdf = _normalize_bdf(parts[1])
            if bdf in pci_seen or not re.fullmatch(r"[0-9A-Fa-f]{4}", parts[2]) or not re.fullmatch(r"[0-9A-Fa-f]{4}:[0-9A-Fa-f]{4}", parts[3]):
                raise DataError("Identidade atual contém PCI inválido ou duplicado.")
            pci_seen.add(bdf)
            pci.append({"bdf": bdf, "class": parts[2].lower(), "vendor_device": parts[3].lower()})
        elif parts[0] == "DISK" and len(parts) == 2:
            fields = dict(re.findall(r"([A-Z_]+)=\"([^\"]*)\"", parts[1]))
            if set(fields) != {"BYTES", "MODEL", "SERIAL", "TYPE"} or fields["TYPE"] != "disk" or not fields["BYTES"].isdigit():
                raise DataError("Identidade atual contém disco inválido.")
            stable = (fields["SERIAL"], fields["MODEL"], int(fields["BYTES"]))
            if stable in disk_seen:
                raise DataError("Identidade atual contém disco duplicado.")
            disk_seen.add(stable)
            disks.append({"by_id": [], "bytes": int(fields["BYTES"]), "identity": fields["SERIAL"], "identity_kind": "serial" if fields["SERIAL"] else "legacy", "model": " ".join(fields["MODEL"].split()), "serial": fields["SERIAL"], "wwn": "", "wwn_extension": ""})
        else:
            raise DataError("Registro desconhecido na identidade atual.")
    lscpu_text = "\n".join("%s: %s" % (source, cpu_raw.get(source, "")) for source, _target, _kind in CPU_FIELDS)
    if memory is None or not pci or not disks:
        raise DataError("Identidade atual incompleta.")
    facts = {
        "cpu": {"state": "present", "reason": "", "value": _parse_cpu(lscpu_text)},
        "memory": {"state": "present", "reason": "", "value": {"total_mib": memory}},
        "pci": {"state": "present", "reason": "", "value": sorted(pci, key=lambda item: item["bdf"])},
        "disks": {"state": "present", "reason": "", "value": sorted(disks, key=lambda item: (item["identity_kind"], item["identity"], item["bytes"]))},
        **_unavailable_facts(),
    }
    snapshot = {"facts": facts, "schema_version": SCHEMA_VERSION}
    return _validate_snapshot(snapshot), source_format


def _legacy_memory(text: str) -> int:
    total = 0
    for number, unit in re.findall(r"(?m)^\s*Size:\s*([0-9]+)\s+(MB|GB|TB)\s*$", text):
        multiplier = {"MB": 1, "GB": 1024, "TB": 1024 * 1024}[unit]
        total += int(number) * multiplier
    if total <= 0:
        raise DataError("Seção RAM legada sem módulos válidos.")
    return total


def _legacy_disks(text: str) -> list[dict]:
    lines = [line for line in text.splitlines() if line.strip()]
    if len(lines) < 2:
        raise DataError("Seção de discos legada truncada.")
    header = lines[0].split()
    for required in ("SIZE", "TYPE", "MODEL", "SERIAL"):
        if required not in header:
            raise DataError("Cabeçalho legado de discos incompleto.")
    result: list[dict] = []
    for line in lines[1:]:
        columns = line.split()
        if len(columns) < 4 or "disk" not in columns:
            continue
        type_index = columns.index("disk")
        if type_index < 1:
            raise DataError("Linha legada de disco malformada.")
        size_text = columns[type_index - 1]
        match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)([KMGTPE]?)", size_text)
        if match is None:
            raise DataError("Tamanho legado de disco inválido.")
        multiplier = {"": 1, "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4, "P": 1024**5, "E": 1024**6}[match.group(2)]
        size = int(float(match.group(1)) * multiplier)
        tail = columns[type_index + 1:]
        serial = tail[-1] if tail else ""
        model = " ".join(tail[:-1]) if len(tail) > 1 else ""
        result.append({"by_id": [], "bytes": size, "identity": serial, "identity_kind": "serial" if serial else "legacy", "model": model, "serial": serial, "wwn": "", "wwn_extension": ""})
    if not result:
        raise DataError("Seção de discos legada sem discos físicos.")
    return sorted(result, key=lambda item: (item["identity_kind"], item["identity"], item["bytes"]))


def _validate_v2_envelope(snapshot: dict, sections: Mapping[str, str]) -> None:
    """Confere o envelope humano redundante contra o snapshot autoritativo.

    Um relatório V2 é uma unidade completa: remover uma seção ou alterar seu
    corpo não pode deixar o marcador JSON autorizando dados diferentes dos que
    o operador enxerga.
    """
    expected_sections = {
        "HARDWARE IDENTITY", "CPU", "RAM", "BASEBOARD", "BIOS", "PCI",
        "BLOCK DEVICES", "USB", "INTERFACES", "BOOT",
        "IOMMU/DMAR (pré-configuração)",
    }
    if set(sections) != expected_sections:
        raise DataError("Envelope INVENTORY_V2 truncado ou com seção desconhecida.")

    facts = snapshot["facts"]

    def require_body(name: str, fact_name: str) -> str:
        body = sections[name]
        state = facts[fact_name]["state"]
        if state == "present" and not body.strip():
            raise DataError("Envelope V2 diverge: seção presente está vazia.")
        if state != "present" and body.strip():
            raise DataError("Envelope V2 diverge do estado declarado do fato.")
        return body

    for section_name, fact_name in (
        ("CPU", "cpu"), ("RAM", "memory"), ("PCI", "pci"),
        ("BLOCK DEVICES", "disks"), ("USB", "usb"),
        ("INTERFACES", "interfaces"), ("BOOT", "boot"),
    ):
        body = require_body(section_name, fact_name)
        if facts[fact_name]["state"] != "present":
            continue
        value = facts[fact_name]["value"]
        if isinstance(value, list):
            rendered: Any = [
                _json_text(line, section_name) for line in body.splitlines() if line
            ]
        else:
            rendered = _json_text(body, section_name)
        if rendered != value:
            raise DataError("Envelope V2 diverge do fato %s canônico." % fact_name)


def parse_report_text(report: str) -> tuple[dict, str]:
    _validate_text(report, "report_text", hostile=True)
    sections = _section_map(report)
    required = {"CPU", "RAM", "PCI", "BLOCK DEVICES"}
    if not required <= sections.keys():
        raise DataError("Relatório truncado: seção obrigatória ausente.")
    identity = sections.get("HARDWARE IDENTITY", "")
    markers = [line for line in identity.splitlines() if line.startswith("INVENTORY_V2|")]
    if markers:
        if len(markers) != 1 or len(identity.splitlines()) != 1:
            raise DataError("Bloco INVENTORY_V2 duplicado ou acompanhado de dados extras.")
        snapshot = _validate_snapshot(_json_text(markers[0].split("|", 1)[1], "INVENTORY_V2"))
        _validate_v2_envelope(snapshot, sections)
        return snapshot, "v2"
    records = "\n".join(line for line in identity.splitlines() if _V1_RECORD.match(line))
    if records:
        if len(records.splitlines()) != len([line for line in identity.splitlines() if line]):
            raise DataError("Bloco de identidade atual contém registro desconhecido.")
        return _parse_v1_identity(records)
    cpu = _parse_cpu(sections["CPU"])
    memory = _legacy_memory(sections["RAM"])
    pci = _parse_pci(sections["PCI"])
    disks = _legacy_disks(sections["BLOCK DEVICES"])
    facts = {
        "cpu": {"state": "present", "reason": "", "value": cpu},
        "memory": {"state": "present", "reason": "", "value": {"total_mib": memory}},
        "pci": {"state": "present", "reason": "", "value": pci},
        "disks": {"state": "present", "reason": "", "value": disks},
        **_unavailable_facts(),
    }
    return _validate_snapshot({"facts": facts, "schema_version": SCHEMA_VERSION}), "legacy-v0"


def _identity_projection(snapshot: dict) -> dict:
    facts = snapshot["facts"]
    projection: dict[str, Any] = {}
    for name in FACT_NAMES:
        fact = facts[name]
        if fact["state"] != "present":
            projection[name] = {"state": fact["state"]}
            continue
        value = fact["value"]
        if name == "disks":
            value = [{key: item.get(key, "") for key in ("identity_kind", "identity", "wwn_extension", "wwn", "serial")} for item in value]
        elif name == "usb":
            value = [{key: item.get(key, "") for key in ("identity_kind", "identity_sha256", "vendor", "product")} for item in value]
        elif name == "interfaces":
            value = [{"key": item["key"], "kind": item["kind"]} for item in value]
        projection[name] = {"state": "present", "value": value}
    return projection


def fingerprints(snapshot: dict) -> tuple[str, str, str]:
    validated = _validate_snapshot(snapshot)
    snapshot_fingerprint = _digest(validated)
    identity_fingerprint = _digest(_identity_projection(validated))
    decision_projection = {name: _identity_projection(validated)[name] for name in ("cpu", "memory", "pci", "disks", "interfaces", "boot")}
    return snapshot_fingerprint, identity_fingerprint, _digest(decision_projection)


def _summary(snapshot: dict, source_format: str) -> dict:
    snap, identity, decision = fingerprints(snapshot)
    coverage = ",".join(name for name in FACT_NAMES if snapshot["facts"][name]["state"] in {"present", "empty"})
    data: dict[str, Any] = {
        "valid": 1, "error": "", "schema_version": SCHEMA_VERSION,
        "source_format": source_format, "coverage": coverage,
        "snapshot_fingerprint": snap, "identity_fingerprint": identity,
        "decision_fingerprint": decision,
    }
    for name in FACT_NAMES:
        data[name + "_state"] = snapshot["facts"][name]["state"]
    return data


def _render_fact_body(fact: Mapping[str, Any]) -> str:
    if fact["state"] != "present":
        return ""
    value = fact["value"]
    if isinstance(value, list):
        return "\n".join(_canonical(item) for item in value)
    return _canonical(value)


def render_report(payload: Mapping[str, Any]) -> tuple[dict, str]:
    snapshot = normalize_capture(payload)
    marker = "INVENTORY_V2|" + _canonical(snapshot)
    facts = snapshot["facts"]
    sections = [
        ("HARDWARE IDENTITY", marker), ("CPU", _render_fact_body(facts["cpu"])),
        ("RAM", _render_fact_body(facts["memory"])),
        ("BASEBOARD", payload["baseboard_report"]),
        ("BIOS", payload["bios_report"]), ("PCI", _render_fact_body(facts["pci"])),
        ("BLOCK DEVICES", _render_fact_body(facts["disks"])),
        ("USB", _render_fact_body(facts["usb"])),
        ("INTERFACES", _render_fact_body(facts["interfaces"])),
        ("BOOT", _render_fact_body(facts["boot"])),
        ("IOMMU/DMAR (pré-configuração)", payload["iommu_report"]),
    ]
    report = "".join("== %s ==\n%s\n" % (name, body) for name, body in sections)
    data = _summary(snapshot, "v2")
    data.update({"fact_count": len(FACT_NAMES), "bytes_written": len(report.encode("utf-8")), "sha256": hashlib.sha256(report.encode("utf-8")).hexdigest()})
    return data, report


def parse_command(payload: Mapping[str, Any]) -> dict:
    _closed(payload, {"report_text"})
    snapshot, source = parse_report_text(_text(payload, "report_text", False))
    return _summary(snapshot, source)


def _parse_any(text: str) -> tuple[dict, str]:
    if text.lstrip().startswith("== "):
        return parse_report_text(text)
    return _parse_v1_identity(text, "capture-v1")


def diff_command(payload: Mapping[str, Any]) -> dict:
    _closed(payload, {"expected_report", "actual_capture"})
    expected, expected_format = _parse_any(_text(payload, "expected_report", False))
    actual, actual_format = _parse_any(_text(payload, "actual_capture", False))
    changes: list[dict[str, str]] = []
    physical = state_changed = coverage_changed = 0
    for name in FACT_NAMES:
        old = expected["facts"][name]
        new = actual["facts"][name]
        if old["state"] != new["state"]:
            coverage_changed = 1
            old_known = old["state"] in {"present", "empty"}
            new_known = new["state"] in {"present", "empty"}
            # Enriquecer um relatório legado sem cobertura é compatível. Perder
            # evidência antes conhecida, ou trocar entre estados incertos, é
            # fail-closed e exige redetecção.
            if (old_known and not new_known) or (old_known == new_known):
                state_changed = 1
            changes.append({"category": "coverage", "path": name, "old_state": old["state"], "new_state": new["state"], "message": "cobertura do fato mudou"})
            continue
        if old["state"] != "present":
            continue
        if name == "memory":
            old_mib = old["value"]["total_mib"]
            new_mib = new["value"]["total_mib"]
            tolerance = max(old_mib // 20, 1024)
            equal = old_mib - tolerance <= new_mib <= old_mib + tolerance
        elif name in {"disks", "usb", "interfaces"}:
            old_value = _identity_projection(expected)[name]
            new_value = _identity_projection(actual)[name]
            equal = old_value == new_value
        else:
            equal = old["value"] == new["value"]
        if not equal:
            physical = 1
            changes.append({"category": "physical", "path": name, "old_state": old["state"], "new_state": new["state"], "message": "identidade física relevante mudou"})
    format_only = int(not changes and expected_format != actual_format)
    data: dict[str, Any] = {
        "equal": int(not changes), "physical_changed": physical,
        "state_changed": state_changed, "coverage_changed": coverage_changed,
        "format_only": format_only, "requires_redetect": int(bool(physical or state_changed)),
        "change_count": len(changes),
    }
    for index, change in enumerate(changes):
        for key, value in change.items():
            data["change_%d_%s" % (index, key)] = value
    return data


def _role_members(value: str) -> list[str]:
    members = [item.strip() for item in re.split(r"[\n,]+", value) if item.strip()]
    if len(members) > 64 or any(not (_MAJMIN.fullmatch(item) or re.fullmatch(r"/dev/[A-Za-z0-9_./:+-]+", item)) for item in members):
        raise DataError("Lista de membros de papel de disco inválida.")
    return members


def _disk_ancestors(member: str, nodes: dict[str, dict], parents: dict[str, set[str]]) -> set[str]:
    lookup = {major: major for major in nodes}
    for major, node in nodes.items():
        for key in ("name", "kname", "path"):
            value = str(node.get(key, ""))
            if value:
                lookup[value] = major
                lookup["/dev/" + value.removeprefix("/dev/")] = major
    start = lookup.get(member)
    if start is None:
        raise DataError("Membro de papel não existe na captura de blocos.")
    found: set[str] = set()
    pending = [start]
    visited: set[str] = set()
    while pending:
        current = pending.pop()
        if current in visited:
            continue
        visited.add(current)
        if nodes[current]["type"] == "disk":
            found.add(current)
        else:
            upstream = set(parents.get(current, set()))
            pkname = str(nodes[current].get("pkname", ""))
            if pkname:
                for major, node in nodes.items():
                    if pkname in {node.get("name"), node.get("kname")}:
                        upstream.add(major)
            pending.extend(upstream)
    if not found:
        raise DataError("Papel de disco sem ancestral físico comprovado.")
    return found


def disk_plan_command(payload: Mapping[str, Any]) -> dict:
    required = {"block_json", "block_by_id_map", "udev_database", "system_members", "working_members", "hd1_members"}
    optional = {"expected_system_fingerprint", "expected_working_fingerprint", "expected_hd1_fingerprint"}
    _closed(payload, required, optional)
    block_json = _text(payload, "block_json", False)
    disks, nodes, parents = _disk_records(block_json, _text(payload, "block_by_id_map"), _text(payload, "udev_database"))
    by_major = {item["major_minor"]: item for item in disks}
    role_sets: dict[str, set[str]] = {}
    states: dict[str, str] = {}
    fingerprints_by_role: dict[str, str] = {}
    for role in ("system", "working", "hd1"):
        members = _role_members(_text(payload, role + "_members"))
        if not members:
            role_sets[role] = set()
            states[role] = "absent"
            fingerprints_by_role[role] = ""
            continue
        majors: set[str] = set()
        for member in members:
            majors.update(_disk_ancestors(member, nodes, parents))
        if role == "hd1" and len(majors) != 1:
            raise DataError("HD1 precisa resolver para exatamente um disco físico.")
        identities: set[str] = set()
        for major in majors:
            record = by_major.get(major)
            if record is None or not record["identity"]:
                raise DataError("Papel de disco sem identidade física estável.")
            identities.add(record["identity_kind"] + ":" + record["identity"])
        role_sets[role] = identities
        states[role] = "present"
        fingerprints_by_role[role] = _digest(sorted(identities))
        expected = payload.get("expected_" + role + "_fingerprint", "")
        if expected:
            if not isinstance(expected, str) or _HEX64.fullmatch(expected) is None:
                raise DataError("Fingerprint esperado de papel inválido.")
            if expected != fingerprints_by_role[role]:
                raise ConflictError("A identidade física do papel %s mudou durante a revalidação." % role)
    conflicts: list[tuple[str, str, str]] = []
    for left, right in (("system", "working"), ("system", "hd1"), ("working", "hd1")):
        for identity in sorted(role_sets[left] & role_sets[right]):
            conflicts.append((left, right, hashlib.sha256(identity.encode("utf-8")).hexdigest()))
    data: dict[str, Any] = {"valid": int(not conflicts), "error": "papéis de disco colidem" if conflicts else "", "conflict_count": len(conflicts)}
    for role in ("system", "working", "hd1"):
        data[role + "_state"] = states[role]
        data[role + "_fingerprint"] = fingerprints_by_role[role]
    for index, (left, right, identity) in enumerate(conflicts):
        data["conflict_%d_left" % index] = left
        data["conflict_%d_right" % index] = right
        data["conflict_%d_identity" % index] = identity
    return data


def usb_resolve_command(payload: Mapping[str, Any]) -> dict:
    required = {"usb_data", "mode", "vendor", "product", "identity_kind", "identity_sha256", "expected_bus", "expected_device"}
    _closed(payload, required)
    mode = _text(payload, "mode", False)
    if mode not in {"select", "resolve", "compare"}:
        raise DataError("Modo de resolução USB desconhecido.")
    vendor = _text(payload, "vendor", False).lower().removeprefix("0x")
    product = _text(payload, "product", False).lower().removeprefix("0x")
    if _HEX4.fullmatch(vendor) is None or _HEX4.fullmatch(product) is None:
        raise DataError("VID/PID do seletor USB inválido.")
    records = _usb_records(_text(payload, "usb_data", False))
    candidates = [item for item in records if item["vendor"] == vendor and item["product"] == product]
    identity_kind = _text(payload, "identity_kind")
    identity_sha = _text(payload, "identity_sha256")
    expected_bus = _text(payload, "expected_bus")
    expected_device = _text(payload, "expected_device")
    if expected_bus and not expected_bus.isdigit() or expected_device and not expected_device.isdigit():
        raise DataError("Bus/device esperado inválido.")
    if mode == "select":
        if expected_bus and expected_device:
            candidates = [item for item in candidates if item["bus"] == int(expected_bus) and item["device"] == int(expected_device)]
    else:
        if identity_kind not in {"serial", "port"} or _HEX64.fullmatch(identity_sha) is None:
            raise DataError("Identidade USB esperada inválida.")
        candidates = [item for item in candidates if item["identity_kind"] == identity_kind and item["identity_sha256"] == identity_sha]
    error = ""
    valid = 1
    selected: dict[str, Any] | None = None
    if len(candidates) != 1:
        valid = 0
        error = "identidade USB ausente" if not candidates else "identidade USB ambígua"
    else:
        selected = candidates[0]
        if selected["identity_kind"] not in {"serial", "port"}:
            valid = 0
            error = "USB sem serial nem porta física comprovada"
        same_identity = [item for item in records if item["identity_kind"] == selected["identity_kind"] and item["identity_sha256"] == selected["identity_sha256"]]
        if len(same_identity) != 1:
            valid = 0
            error = "identidade USB duplicada"
    item = selected or {"identity_kind": "", "identity_sha256": "", "vendor": vendor, "product": product, "port": "", "bus": 0, "device": 0}
    renumbered = int(bool(valid and expected_bus and expected_device and (item["bus"] != int(expected_bus) or item["device"] != int(expected_device))))
    return {
        "valid": valid, "error": error, "match_count": len(candidates),
        "identity_kind": item["identity_kind"], "identity_sha256": item["identity_sha256"],
        "vendor": item["vendor"], "product": item["product"], "port": item["port"],
        "bus": item["bus"], "device": item["device"], "renumbered": renumbered,
    }
