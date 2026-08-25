"""Snapshots e intenção de rede puros da fase I7.1.

O Bash captura todos os fatos e preserva os artefatos necessários à
recuperação. Este módulo recebe somente dados já capturados, valida um schema
fechado, normaliza coleções e calcula fingerprints determinísticos. Ele não
abre arquivos, não sonda o host, não escolhe provider e não produz comandos.

Validação de endereços/rotas, geração de planos, descoberta de consumidores e
execução transacional pertencem, respectivamente, às subetapas I7.2–I7.6.
"""
from __future__ import annotations

import hashlib
import json
import re
from typing import Any, Iterable, Mapping

from . import xmlutil
from .errors import DataError
from .protocol import safe_label

SCHEMA_VERSION = 1
MODES = frozenset({"bridge", "nat"})
CONFIGURATION_SCOPES = frozenset({"host", "project"})
SOURCE_TYPES = frozenset({"bridge", "direct", "network"})
STATE_FIELDS = (
    "uplink",
    "routes",
    "links",
    "bridge",
    "libvirt_network",
    "consumers",
    "configuration",
)
MAX_TEXT_BYTES = 4 * 1024 * 1024
MAX_ROUTES = 4096
MAX_LINKS = 4096
MAX_CONSUMERS = 1024
MAX_CONFIGURATIONS = 128
MAX_INTERFACES_PER_VM = 64
MAX_LIST_ITEMS = 4096
_INTERFACE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,14}$")
_ENTITY_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
_MAC = re.compile(r"^[0-9a-f]{2}(?::[0-9a-f]{2}){5}$")
_ALLOWED_CONTROLS = frozenset({"\n", "\r", "\t"})


def _mapping(value: Any, label: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise DataError("%s precisa ser um objeto." % label)
    if any(not isinstance(key, str) for key in value):
        raise DataError("%s contém chave que não é texto." % label)
    return value


def _closed(
    value: Any,
    required: Iterable[str],
    label: str,
) -> Mapping[str, Any]:
    payload = _mapping(value, label)
    required_set = frozenset(required)
    keys = frozenset(payload.keys())
    missing = sorted(required_set - keys)
    extra = sorted(keys - required_set)
    if missing:
        raise DataError(
            "%s sem campos obrigatórios: %s." % (label, ", ".join(missing))
        )
    if extra:
        raise DataError(
            "%s contém campos fora do schema fechado: %s."
            % (label, ", ".join(safe_label(item) for item in extra))
        )
    return payload


def _validate_text(value: str, label: str) -> str:
    try:
        encoded = value.encode("utf-8")
    except UnicodeEncodeError as error:
        raise DataError("%s contém Unicode inválido." % label) from error
    if len(encoded) > MAX_TEXT_BYTES:
        raise DataError("%s excede o limite de tamanho." % label)
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
    *,
    allow_empty: bool = False,
) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or (not allow_empty and not value):
        suffix = "" if allow_empty else " não vazio"
        raise DataError(
            "%s.%s precisa ser texto%s."
            % (label, safe_label(key), suffix)
        )
    return _validate_text(value, "%s.%s" % (label, safe_label(key)))


def _boolean(payload: Mapping[str, Any], key: str, label: str) -> bool:
    value = payload.get(key)
    if type(value) is not bool:
        raise DataError("%s.%s precisa ser booleano." % (label, safe_label(key)))
    return value


def _integer(
    payload: Mapping[str, Any],
    key: str,
    label: str,
    *,
    minimum: int = 0,
    allow_none: bool = False,
) -> int | None:
    value = payload.get(key)
    if allow_none and value is None:
        return None
    if type(value) is not int or value < minimum:
        raise DataError(
            "%s.%s precisa ser inteiro maior ou igual a %d%s."
            % (
                label,
                safe_label(key),
                minimum,
                " ou null" if allow_none else "",
            )
        )
    return value


def _list(value: Any, label: str, limit: int = MAX_LIST_ITEMS) -> list[Any]:
    if not isinstance(value, list):
        raise DataError("%s precisa ser uma lista." % label)
    if len(value) > limit:
        raise DataError("%s excede o limite de %d itens." % (label, limit))
    return value


def _interface_name(value: str, label: str) -> str:
    if _INTERFACE_NAME.fullmatch(value) is None:
        raise DataError("%s não é um nome de interface válido." % label)
    return value


def _entity_name(value: str, label: str) -> str:
    if _ENTITY_NAME.fullmatch(value) is None:
        raise DataError("%s não é um identificador válido." % label)
    return value


def _mac(value: str, label: str, *, allow_empty: bool = False) -> str:
    normalized = value.lower()
    if allow_empty and not normalized:
        return ""
    if _MAC.fullmatch(normalized) is None:
        raise DataError("%s não é um MAC no formato aa:bb:cc:dd:ee:ff." % label)
    return normalized


def _canonical(value: Any) -> str:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )


def _digest(value: Any) -> str:
    return hashlib.sha256(_canonical(value).encode("utf-8")).hexdigest()


def _normalized_text_list(
    value: Any,
    label: str,
    *,
    interface_names: bool = False,
) -> list[str]:
    result: list[str] = []
    for index, item in enumerate(_list(value, label)):
        item_label = "%s[%d]" % (label, index)
        if not isinstance(item, str) or not item:
            raise DataError("%s precisa ser texto não vazio." % item_label)
        normalized = _validate_text(item, item_label)
        if interface_names:
            normalized = _interface_name(normalized, item_label)
        result.append(normalized)
    if len(result) != len(set(result)):
        raise DataError("%s contém itens duplicados." % label)
    return sorted(result)


def _normalize_uplink(value: Any) -> dict:
    label = "uplink"
    payload = _closed(value, {"name", "kind", "mac"}, label)
    name = _interface_name(_text(payload, "name", label), "uplink.name")
    kind = _text(payload, "kind", label, allow_empty=True)
    mac = _mac(
        _text(payload, "mac", label, allow_empty=True),
        "uplink.mac",
        allow_empty=True,
    )
    return {"kind": kind, "mac": mac, "name": name}


def _normalize_route(value: Any, index: int) -> dict:
    label = "routes[%d]" % index
    fields = {
        "destination",
        "gateway",
        "device",
        "protocol",
        "scope",
        "table",
        "metric",
        "source",
    }
    payload = _closed(value, fields, label)
    device = _interface_name(
        _text(payload, "device", label), "%s.device" % label
    )
    return {
        "destination": _text(payload, "destination", label),
        "device": device,
        "gateway": _text(payload, "gateway", label, allow_empty=True),
        "metric": _integer(payload, "metric", label, allow_none=True),
        "protocol": _text(payload, "protocol", label, allow_empty=True),
        "scope": _text(payload, "scope", label, allow_empty=True),
        "source": _text(payload, "source", label, allow_empty=True),
        "table": _text(payload, "table", label, allow_empty=True),
    }


def _normalize_routes(value: Any) -> list[dict]:
    routes = [
        _normalize_route(item, index)
        for index, item in enumerate(_list(value, "routes", MAX_ROUTES))
    ]
    canonical = [_canonical(route) for route in routes]
    if len(canonical) != len(set(canonical)):
        raise DataError("routes contém rotas duplicadas.")
    return sorted(routes, key=_canonical)


def _normalize_link(value: Any, index: int) -> dict:
    label = "links[%d]" % index
    fields = {
        "name",
        "kind",
        "mac",
        "master",
        "operstate",
        "mtu",
        "flags",
        "addresses",
    }
    payload = _closed(value, fields, label)
    name = _interface_name(_text(payload, "name", label), "%s.name" % label)
    master = _text(payload, "master", label, allow_empty=True)
    if master:
        master = _interface_name(master, "%s.master" % label)
    mac = _mac(
        _text(payload, "mac", label, allow_empty=True),
        "%s.mac" % label,
        allow_empty=True,
    )
    return {
        "addresses": _normalized_text_list(
            payload["addresses"], "%s.addresses" % label
        ),
        "flags": _normalized_text_list(payload["flags"], "%s.flags" % label),
        "kind": _text(payload, "kind", label, allow_empty=True),
        "mac": mac,
        "master": master,
        "mtu": _integer(payload, "mtu", label),
        "name": name,
        "operstate": _text(payload, "operstate", label),
    }


def _normalize_links(value: Any) -> list[dict]:
    links = [
        _normalize_link(item, index)
        for index, item in enumerate(_list(value, "links", MAX_LINKS))
    ]
    names = [link["name"] for link in links]
    if len(names) != len(set(names)):
        raise DataError("links contém nomes duplicados.")
    return sorted(links, key=lambda item: item["name"])


def _normalize_bridge(value: Any) -> dict:
    label = "bridge"
    payload = _closed(value, {"name", "exists", "ports"}, label)
    name = _interface_name(_text(payload, "name", label), "bridge.name")
    exists = _boolean(payload, "exists", label)
    ports = _normalized_text_list(
        payload["ports"], "bridge.ports", interface_names=True
    )
    if not exists and ports:
        raise DataError("bridge ausente não pode declarar portas.")
    if name in ports:
        raise DataError("bridge não pode ser porta de si mesma.")
    return {"exists": exists, "name": name, "ports": ports}


def _xml_fingerprint(
    text: str,
    root_name: str,
    expected_name: str,
    label: str,
) -> str:
    if not text:
        return ""
    root = xmlutil.parse_document(text, root_name, label)
    name_node = xmlutil.exactly_one(root, "name", label)
    actual_name = xmlutil.text_of(name_node)
    if actual_name != expected_name:
        raise DataError(
            "%s identifica %s, mas o snapshot declara %s."
            % (label, safe_label(actual_name), safe_label(expected_name))
        )
    return xmlutil.fingerprint(root)


def _normalize_libvirt_network(value: Any) -> dict:
    label = "libvirt_network"
    fields = {
        "name",
        "exists",
        "active",
        "persistent",
        "autostart",
        "marker",
        "active_xml",
        "persistent_xml",
    }
    payload = _closed(value, fields, label)
    name = _entity_name(_text(payload, "name", label), "%s.name" % label)
    exists = _boolean(payload, "exists", label)
    active = _boolean(payload, "active", label)
    persistent = _boolean(payload, "persistent", label)
    autostart = _boolean(payload, "autostart", label)
    marker = _text(payload, "marker", label, allow_empty=True)
    active_xml = _text(payload, "active_xml", label, allow_empty=True)
    persistent_xml = _text(payload, "persistent_xml", label, allow_empty=True)

    if not exists:
        if active or persistent or autostart or active_xml or persistent_xml:
            raise DataError("rede libvirt ausente contém estado ou XML residual.")
    else:
        if not active and not persistent:
            raise DataError("rede libvirt existente, transitória e inativa é impossível.")
        if autostart and not persistent:
            raise DataError("rede libvirt transitória não pode ter autostart.")
        if active != bool(active_xml):
            raise DataError("estado ativo e XML ativo da rede libvirt divergem.")
        if persistent != bool(persistent_xml):
            raise DataError(
                "estado persistente e XML persistente da rede libvirt divergem."
            )
        _xml_fingerprint(active_xml, "network", name, "XML ativo de rede")
        _xml_fingerprint(
            persistent_xml,
            "network",
            name,
            "XML persistente de rede",
        )

    return {
        "active": active,
        "active_xml": active_xml,
        "autostart": autostart,
        "exists": exists,
        "marker": marker,
        "name": name,
        "persistent": persistent,
        "persistent_xml": persistent_xml,
    }


def _normalize_vm_interface(value: Any, vm_index: int, index: int) -> dict:
    label = "consumers[%d].interfaces[%d]" % (vm_index, index)
    payload = _closed(value, {"mac", "source_type", "source"}, label)
    source_type = _text(payload, "source_type", label)
    if source_type not in SOURCE_TYPES:
        raise DataError("%s.source_type não é suportado." % label)
    source = _text(payload, "source", label)
    if source_type in {"bridge", "direct"}:
        source = _interface_name(source, "%s.source" % label)
    else:
        source = _entity_name(source, "%s.source" % label)
    return {
        "mac": _mac(_text(payload, "mac", label), "%s.mac" % label),
        "source": source,
        "source_type": source_type,
    }


def _normalize_consumer(value: Any, index: int) -> dict:
    label = "consumers[%d]" % index
    payload = _closed(value, {"name", "active", "xml", "interfaces"}, label)
    name = _entity_name(_text(payload, "name", label), "%s.name" % label)
    xml = _text(payload, "xml", label)
    _xml_fingerprint(xml, "domain", name, "XML da VM consumidora")
    interfaces = [
        _normalize_vm_interface(item, index, interface_index)
        for interface_index, item in enumerate(
            _list(
                payload["interfaces"],
                "%s.interfaces" % label,
                MAX_INTERFACES_PER_VM,
            )
        )
    ]
    if not interfaces:
        raise DataError("%s não contém interface consumidora." % label)
    macs = [item["mac"] for item in interfaces]
    if len(macs) != len(set(macs)):
        raise DataError("%s contém MAC duplicado." % label)
    canonical = [_canonical(item) for item in interfaces]
    if len(canonical) != len(set(canonical)):
        raise DataError("%s contém interface duplicada." % label)
    return {
        "active": _boolean(payload, "active", label),
        "interfaces": sorted(interfaces, key=_canonical),
        "name": name,
        "xml": xml,
    }


def _normalize_consumers(value: Any) -> list[dict]:
    consumers = [
        _normalize_consumer(item, index)
        for index, item in enumerate(
            _list(value, "consumers", MAX_CONSUMERS)
        )
    ]
    names = [consumer["name"] for consumer in consumers]
    if len(names) != len(set(names)):
        raise DataError("consumers contém nomes de VM duplicados.")
    return sorted(consumers, key=lambda item: item["name"])


def _normalize_configuration(value: Any, index: int) -> dict:
    label = "configuration[%d]" % index
    fields = {
        "scope",
        "identifier",
        "exists",
        "content",
        "file_type",
        "device",
        "inode",
        "mode",
        "uid",
        "gid",
        "nlink",
        "size",
        "mtime_ns",
    }
    payload = _closed(value, fields, label)
    scope = _text(payload, "scope", label)
    if scope not in CONFIGURATION_SCOPES:
        raise DataError("%s.scope não é suportado." % label)
    identifier = _text(payload, "identifier", label)
    exists = _boolean(payload, "exists", label)
    content = _text(payload, "content", label, allow_empty=True)
    file_type = _text(payload, "file_type", label, allow_empty=True)
    metadata = {
        "device": _integer(payload, "device", label, allow_none=True),
        "gid": _integer(payload, "gid", label, allow_none=True),
        "inode": _integer(
            payload, "inode", label, minimum=1, allow_none=True
        ),
        "mode": _integer(payload, "mode", label, allow_none=True),
        "mtime_ns": _integer(payload, "mtime_ns", label, allow_none=True),
        "nlink": _integer(
            payload, "nlink", label, minimum=1, allow_none=True
        ),
        "size": _integer(payload, "size", label, allow_none=True),
        "uid": _integer(payload, "uid", label, allow_none=True),
    }
    if exists:
        if file_type != "regular":
            raise DataError("%s existente precisa ser arquivo regular." % label)
        if any(item is None for item in metadata.values()):
            raise DataError("%s existente possui metadados incompletos." % label)
        if metadata["nlink"] != 1:
            raise DataError("%s possui mais de um hardlink." % label)
        if metadata["mode"] > 0o7777:
            raise DataError("%s.mode contém bits fora das permissões." % label)
        if metadata["size"] != len(content.encode("utf-8")):
            raise DataError("%s.size diverge do conteúdo capturado." % label)
    elif content or file_type or any(item is not None for item in metadata.values()):
        raise DataError("%s ausente contém conteúdo ou metadados residuais." % label)
    return {
        "content": content,
        "device": metadata["device"],
        "exists": exists,
        "file_type": file_type,
        "gid": metadata["gid"],
        "identifier": identifier,
        "inode": metadata["inode"],
        "mode": metadata["mode"],
        "mtime_ns": metadata["mtime_ns"],
        "nlink": metadata["nlink"],
        "scope": scope,
        "size": metadata["size"],
        "uid": metadata["uid"],
    }


def _normalize_configurations(value: Any) -> list[dict]:
    configurations = [
        _normalize_configuration(item, index)
        for index, item in enumerate(
            _list(value, "configuration", MAX_CONFIGURATIONS)
        )
    ]
    identities = [
        (item["scope"], item["identifier"]) for item in configurations
    ]
    if len(identities) != len(set(identities)):
        raise DataError("configuration contém artefatos duplicados.")
    return sorted(
        configurations,
        key=lambda item: (item["scope"], item["identifier"]),
    )


def _validate_relations(state: Mapping[str, Any]) -> None:
    links = {item["name"]: item for item in state["links"]}
    uplink = state["uplink"]
    if uplink["name"] not in links:
        raise DataError("uplink não aparece na captura de links.")
    link_mac = links[uplink["name"]]["mac"]
    if uplink["mac"] and link_mac and uplink["mac"] != link_mac:
        raise DataError("MAC do uplink diverge do link correspondente.")

    for name, link in links.items():
        master = link["master"]
        if master and master not in links:
            raise DataError(
                "link %s referencia master ausente: %s."
                % (safe_label(name), safe_label(master))
            )
        if master == name:
            raise DataError("link não pode ser master de si mesmo.")
    for name in links:
        seen = {name}
        master = links[name]["master"]
        while master:
            if master in seen:
                raise DataError("hierarquia de masters contém ciclo.")
            seen.add(master)
            master = links[master]["master"]

    for route in state["routes"]:
        if route["device"] not in links:
            raise DataError(
                "rota referencia link ausente: %s."
                % safe_label(route["device"])
            )

    bridge = state["bridge"]
    bridge_name = bridge["name"]
    if bridge["exists"]:
        if bridge_name not in links:
            raise DataError("bridge existente não aparece na captura de links.")
        if links[bridge_name]["kind"] != "bridge":
            raise DataError("link da bridge não possui kind=bridge.")
        actual_ports = sorted(
            name for name, link in links.items() if link["master"] == bridge_name
        )
        if bridge["ports"] != actual_ports:
            raise DataError(
                "portas declaradas da bridge divergem dos masters dos links."
            )
    elif bridge_name in links:
        raise DataError("bridge ausente colide com um link existente.")

    network = state["libvirt_network"]
    for consumer in state["consumers"]:
        for interface in consumer["interfaces"]:
            if interface["source_type"] == "network":
                if not network["exists"] or interface["source"] != network["name"]:
                    raise DataError(
                        "VM consumidora referencia rede libvirt fora do snapshot."
                    )
            elif interface["source_type"] == "bridge":
                if not bridge["exists"] or interface["source"] != bridge["name"]:
                    raise DataError(
                        "VM consumidora referencia bridge fora do snapshot."
                    )
            elif interface["source"] not in links:
                raise DataError(
                    "VM consumidora referencia link direto ausente."
                )


def _normalize_state(payload: Mapping[str, Any]) -> dict:
    state = {
        "bridge": _normalize_bridge(payload["bridge"]),
        "configuration": _normalize_configurations(payload["configuration"]),
        "consumers": _normalize_consumers(payload["consumers"]),
        "libvirt_network": _normalize_libvirt_network(payload["libvirt_network"]),
        "links": _normalize_links(payload["links"]),
        "routes": _normalize_routes(payload["routes"]),
        "uplink": _normalize_uplink(payload["uplink"]),
    }
    _validate_relations(state)
    return state


def normalize_snapshot(value: Any) -> dict:
    """Valida e normaliza um snapshot completo capturado pelo Bash."""
    fields = set(STATE_FIELDS) | {"schema_version"}
    payload = _closed(value, fields, "snapshot")
    if (
        type(payload["schema_version"]) is not int
        or payload["schema_version"] != SCHEMA_VERSION
    ):
        raise DataError("Versão do schema de snapshot de rede não suportada.")
    return {"schema_version": SCHEMA_VERSION, **_normalize_state(payload)}


def normalize_intent(value: Any) -> dict:
    """Valida a intenção declarativa sem escolher backend ou gerar operações."""
    fields = set(STATE_FIELDS) | {"schema_version", "mode"}
    payload = _closed(value, fields, "intent")
    if (
        type(payload["schema_version"]) is not int
        or payload["schema_version"] != SCHEMA_VERSION
    ):
        raise DataError("Versão do schema de intenção de rede não suportada.")
    mode = payload["mode"]
    if not isinstance(mode, str) or mode not in MODES:
        raise DataError("Modo da intenção de rede precisa ser bridge ou nat.")
    return {
        "mode": mode,
        "schema_version": SCHEMA_VERSION,
        **_normalize_state(payload),
    }


def _semantic_state(value: Mapping[str, Any]) -> dict:
    projected = {field: value[field] for field in STATE_FIELDS}

    network = dict(value["libvirt_network"])
    network["active_xml"] = _xml_fingerprint(
        network["active_xml"],
        "network",
        network["name"],
        "XML ativo de rede",
    )
    network["persistent_xml"] = _xml_fingerprint(
        network["persistent_xml"],
        "network",
        network["name"],
        "XML persistente de rede",
    )
    projected["libvirt_network"] = network

    consumers: list[dict] = []
    for consumer in value["consumers"]:
        item = dict(consumer)
        item["xml"] = _xml_fingerprint(
            item["xml"],
            "domain",
            item["name"],
            "XML da VM consumidora",
        )
        consumers.append(item)
    projected["consumers"] = consumers
    return projected


def _fingerprints(normalized: Mapping[str, Any]) -> dict:
    semantic_state = _semantic_state(normalized)
    component_fingerprints = {
        field: _digest(semantic_state[field]) for field in STATE_FIELDS
    }
    semantic_document = {
        key: value
        for key, value in normalized.items()
        if key not in STATE_FIELDS
    }
    semantic_document.update(semantic_state)
    return {
        "components": component_fingerprints,
        "exact": _digest(normalized),
        "schema_version": SCHEMA_VERSION,
        "semantic": _digest(semantic_document),
    }


def snapshot_fingerprints(value: Any) -> dict:
    """Calcula digests exato, semântico e por componente do snapshot."""
    return _fingerprints(normalize_snapshot(value))


def intent_fingerprints(value: Any) -> dict:
    """Calcula digests determinísticos da intenção backend-neutral."""
    return _fingerprints(normalize_intent(value))
