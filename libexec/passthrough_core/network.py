"""Snapshots, intenção e cálculo de endereços de rede puros (I7.1 e I7.2).

O Bash captura todos os fatos e preserva os artefatos necessários à
recuperação. Este módulo recebe somente dados já capturados, valida um schema
fechado, normaliza coleções e calcula fingerprints determinísticos. Ele não
abre arquivos, não sonda o host, não escolhe provider e não produz comandos.

I7.2 acrescentou a aritmética de endereços com `ipaddress`: derivação NAT
(gateway, DHCP, IP do host, IP da VM, broadcast), conferência do par
host/VM contra um prefixo e auditoria de rotas com a exceção `proto kernel`.
Nada aqui decide efeito: as funções devolvem medidas e cardinalidades para
que o Bash produza a mensagem e a recusa, como já faz `network_xml`.

Geração de planos, descoberta de consumidores e execução transacional
pertencem, respectivamente, às subetapas I7.3–I7.6.
"""
from __future__ import annotations

import hashlib
import ipaddress
import json
import re
from typing import Any, Iterable, Mapping

from . import xmlutil
from .errors import DataError, InternalError
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
# I7.2: alinhado a `nome_interface_valido` (lib/common.sh:1823), que aceita `_`
# como primeiro caractere. Sem o `_` inicial um nome legítimo para o Bash
# viraria DataError quando I7.5 ligar o snapshot real. O conjunto continua
# restrito a ASCII de propósito: `[[:alnum:]]` do Bash depende de locale e um
# nome com caractere não ASCII seria interpolado em XML, YAML e comandos.
_INTERFACE_NAME = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,14}$")
# I7.2: o `_` inicial também foi alinhado a `nome_rede_libvirt_valido`
# (lib/common.sh:1828). O limite de 128 é mantido de propósito, acima dos 63 do
# Bash e dos 64 de network_xml.py:26: aqueles validam nomes que ESTE projeto
# cria, enquanto o snapshot também transporta redes e VMs de terceiros já
# existentes no host, cujo nome o Bash nunca validou. Apertar aqui recusaria
# captura legítima; o nome que o projeto cria continua limitado pelo Bash.
_ENTITY_NAME = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$")
_MAC = re.compile(r"^[0-9a-f]{2}(?::[0-9a-f]{2}){5}$")
_ALLOWED_CONTROLS = frozenset({"\n", "\r", "\t"})

# --- I7.2: vocabulário de rotas e limites de endereçamento -------------------
# `ip -4 route show table all` prefixa a linha com o tipo, exceto no unicast da
# tabela main, onde o token é omitido. O Bash reproduz isso em
# `etapas/60-rede-bridge.sh:1224-1236`; aqui o tipo é campo explícito do
# snapshot, porque `scope` e `protocol` não distinguem `local` de `broadcast`.
ROUTE_TYPES = frozenset(
    {
        "blackhole",
        "broadcast",
        "local",
        "prohibit",
        "throw",
        "unicast",
        "unreachable",
    }
)
# `unreachable`, `prohibit`, `blackhole` e `throw` não têm `dev`; as demais têm.
ROUTE_TYPES_WITH_DEVICE = frozenset({"broadcast", "local", "unicast"})
# Classes do oráculo Bash (`etapas/60-rede-bridge.sh:1226-1231`).
ROUTE_CLASSES = {
    "blackhole": "outra",
    "broadcast": "broadcast",
    "local": "local",
    "prohibit": "outra",
    "throw": "outra",
    "unicast": "conectada",
    "unreachable": "outra",
}
KERNEL_EXCEPTION_CLASSES = frozenset({"broadcast", "conectada", "local"})
DEFAULT_DESTINATION = "default"
KERNEL_PROTOCOL = "kernel"
SUPPORTED_FAMILIES = frozenset({"ipv4"})
NAT_PREFIXLEN = 24
NAT_GATEWAY_OFFSET = 1
NAT_VM_OFFSET = 10
NAT_DHCP_START_OFFSET = 100
NAT_DHCP_END_OFFSET = 254
# `cidr_privado_24_valido` (lib/common.sh:2218) aceita exatamente estes três
# blocos; `IPv4Network.is_private` é mais largo (127/8, 169.254/16, 100.64/10)
# e não serve como oráculo.
PRIVATE_BLOCKS = (
    ipaddress.IPv4Network("10.0.0.0/8"),
    ipaddress.IPv4Network("172.16.0.0/12"),
    ipaddress.IPv4Network("192.168.0.0/16"),
)
# Decimal pontuado sem zero à esquerda. O Bash aceita `010.0.0.0` porque usa
# `10#$octeto`, mas `derivar_parametros_nat` concatena texto e produziria
# `010.0.0.1`, que a glibc lê como octal: endereço diferente do pretendido.
# Recusar é fail-closed e não perde nenhum produtor real.
_IPV4_TEXT = re.compile(r"^(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}$")
_PREFIX_TEXT = re.compile(r"^(?:[0-9]|[12][0-9]|3[0-2])$")


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
    # I7.2: `type` entrou no schema fechado porque a exceção `proto kernel`
    # (`etapas/60-rede-bridge.sh:1173-1192`) é decidida pela classe da rota, e
    # nem `scope` nem `protocol` separam `local` de `broadcast`. Pelo mesmo
    # motivo `device` passou a ser opcional: `unreachable`, `prohibit`,
    # `blackhole` e `throw` não têm `dev` algum e o Bash mesmo assim as compara
    # contra a candidata. Nenhum produtor existia antes desta subetapa, então a
    # extensão não quebra consumidor nenhum.
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
        "type",
    }
    payload = _closed(value, fields, label)
    route_type = _text(payload, "type", label)
    if route_type not in ROUTE_TYPES:
        raise DataError("%s.type não é um tipo de rota suportado." % label)
    device = _text(
        payload,
        "device",
        label,
        allow_empty=route_type not in ROUTE_TYPES_WITH_DEVICE,
    )
    if device:
        device = _interface_name(device, "%s.device" % label)
    return {
        "destination": _text(payload, "destination", label),
        "device": device,
        "gateway": _text(payload, "gateway", label, allow_empty=True),
        "metric": _integer(payload, "metric", label, allow_none=True),
        "protocol": _text(payload, "protocol", label, allow_empty=True),
        "scope": _text(payload, "scope", label, allow_empty=True),
        "source": _text(payload, "source", label, allow_empty=True),
        "table": _text(payload, "table", label, allow_empty=True),
        "type": route_type,
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
        # I7.2: rota sem `dev` (blackhole/prohibit/throw/unreachable) não
        # referencia link algum; só as demais precisam existir na captura.
        if route["device"] and route["device"] not in links:
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


# --- I7.2: aritmética de endereços com `ipaddress` ---------------------------
# Nenhuma derivação abaixo concatena texto. O Bash de hoje monta
# `${prefixo}.1/.10/.100/.254` (`etapas/60-rede-bridge.sh:525-534`), o que só
# funciona porque `cidr_privado_24_valido` garante /24 com último octeto 0.
# Aqui o mesmo resultado sai de soma inteira sobre o endereço de rede, e a
# paridade byte a byte é oráculo do teste.


def _looks_ipv6(text: str) -> bool:
    for parser in (ipaddress.ip_network, ipaddress.ip_address):
        try:
            return parser(text).version == 6
        except ValueError:
            continue
    return False


def parse_ipv4_address(value: str, label: str) -> ipaddress.IPv4Address:
    """Converte texto em IPv4, recusando IPv6 e formato ambíguo."""
    if ":" in value or _looks_ipv6(value):
        raise DataError(
            "%s declara endereço IPv6; este core só trata IPv4." % label
        )
    if _IPV4_TEXT.fullmatch(value) is None:
        raise DataError(
            "%s não é um IPv4 decimal pontuado sem zero à esquerda." % label
        )
    try:
        return ipaddress.IPv4Address(value)
    except ipaddress.AddressValueError as error:
        raise DataError("%s não é um endereço IPv4 válido." % label) from error


def parse_ipv4_cidr(
    value: str, label: str
) -> tuple[ipaddress.IPv4Address, int, ipaddress.IPv4Network]:
    """Devolve (endereço literal, prefixo, rede mascarada) de um CIDR IPv4.

    O endereço literal é preservado porque a exceção `proto kernel` do Bash
    compara o destino como texto: `192.168.9.5/24` não é `192.168.9.0/24` para
    aquele teste, mesmo que as duas formas denotem a mesma rede.
    """
    if ":" in value or _looks_ipv6(value):
        raise DataError(
            "%s declara CIDR IPv6; este core só trata IPv4." % label
        )
    if value.count("/") != 1:
        raise DataError("%s precisa estar na forma ENDERECO/PREFIXO." % label)
    address_text, prefix_text = value.split("/", 1)
    address = parse_ipv4_address(address_text, label)
    if _PREFIX_TEXT.fullmatch(prefix_text) is None:
        # I7.2: o Bash aceita `/024` e o reinterpreta como octal 20 dentro de
        # `$(( ))`, produzindo uma máscara /20 para um texto que qualquer
        # leitor entende como /24. A borda não é preservada: recusar é a única
        # leitura segura, e nenhum produtor real emite prefixo com zero à
        # esquerda.
        raise DataError(
            "%s declara prefixo IPv4 fora da faixa 0-32 ou com zero à esquerda."
            % label
        )
    prefix = int(prefix_text)
    return address, prefix, ipaddress.IPv4Network((address, prefix), strict=False)


def require_supported_family(value: str, label: str) -> str:
    """Recusa família de endereços que este core ainda não trata."""
    if value not in SUPPORTED_FAMILIES:
        raise DataError(
            "%s declara família não suportada: %s; este core só trata ipv4."
            % (label, safe_label(value))
        )
    return value


def _is_private_v4(network: ipaddress.IPv4Network) -> bool:
    return any(network.subnet_of(block) for block in PRIVATE_BLOCKS)


def _is_unicast_in(
    address: ipaddress.IPv4Address, network: ipaddress.IPv4Network
) -> bool:
    """Espelha `ipv4_unicast_em_cidr` (lib/common.sh:2184): estritamente entre
    o endereço de rede e o de broadcast, o que deixa /31 e /32 sem unicast."""
    return (
        int(network.network_address)
        < int(address)
        < int(network.broadcast_address)
    )


def nat_addresses(payload: Mapping[str, Any]) -> dict:
    """Deriva os endereços da rede NAT a partir do CIDR privado /24.

    Paridade exata com `derivar_parametros_nat`
    (`etapas/60-rede-bridge.sh:525-534`): as chaves `nat_gateway`,
    `nat_vm_ip`, `nat_dhcp_inicio` e `nat_dhcp_fim` projetam, no canal de
    pares, exatamente as variáveis `NAT_GATEWAY`, `NAT_VM_IP`,
    `NAT_DHCP_INICIO` e `NAT_DHCP_FIM` que o Bash exporta hoje. O IP do host é
    o próprio gateway virtual (`etapas/60-rede-bridge.sh:1553`), e a netmask e
    o broadcast saem de `ipaddress` em vez de ficarem literais no XML.
    """
    label = "nat"
    data = _closed(payload, {"cidr"}, label)
    text = _text(data, "cidr", label)
    address, prefix, network = parse_ipv4_cidr(text, "nat.cidr")
    if prefix != NAT_PREFIXLEN:
        raise DataError(
            "nat.cidr exige prefixo /%d; o prefixo /%d não é suportado."
            % (NAT_PREFIXLEN, prefix)
        )
    if address != network.network_address:
        raise DataError(
            "nat.cidr precisa ser o endereço de rede, com o último octeto 0."
        )
    if not _is_private_v4(network):
        raise DataError(
            "nat.cidr precisa ser privada RFC 1918 (10/8, 172.16/12 ou "
            "192.168/16)."
        )
    base = int(network.network_address)
    derived = {
        "nat_gateway": ipaddress.IPv4Address(base + NAT_GATEWAY_OFFSET),
        "nat_vm_ip": ipaddress.IPv4Address(base + NAT_VM_OFFSET),
        "nat_dhcp_inicio": ipaddress.IPv4Address(base + NAT_DHCP_START_OFFSET),
        "nat_dhcp_fim": ipaddress.IPv4Address(base + NAT_DHCP_END_OFFSET),
    }
    for name, value in derived.items():
        if not _is_unicast_in(value, network):
            raise InternalError(
                "Derivação NAT produziu endereço não unicast em %s." % name
            )
    result = {name: str(value) for name, value in derived.items()}
    result.update(
        {
            "family": "ipv4",
            "nat_broadcast": str(network.broadcast_address),
            "nat_cidr": str(network),
            "nat_dhcp_count": NAT_DHCP_END_OFFSET - NAT_DHCP_START_OFFSET + 1,
            "nat_host_ip": str(derived["nat_gateway"]),
            "nat_netmask": str(network.netmask),
            "nat_network": str(network.network_address),
            "nat_prefix": prefix,
        }
    )
    return result


def address_check(payload: Mapping[str, Any]) -> dict:
    """Confere o par host/VM contra um prefixo IPv4 já observado.

    Espelha o corpo do laço de `validar_ips_interface_rede`
    (`lib/common.sh:2192-2216`): o host precisa ser exatamente o endereço que
    a interface carrega naquele CIDR, e a VM precisa ser um unicast distinto
    dentro do mesmo prefixo. Como em `network_xml.network_overlap`, nada é
    decidido aqui: as cardinalidades voltam para o Bash formular a recusa.
    """
    label = "address_check"
    data = _closed(payload, {"cidr", "host_ip", "vm_ip"}, label)
    address, prefix, network = parse_ipv4_cidr(
        _text(data, "cidr", label), "address_check.cidr"
    )
    host = parse_ipv4_address(
        _text(data, "host_ip", label), "address_check.host_ip"
    )
    vm = parse_ipv4_address(_text(data, "vm_ip", label), "address_check.vm_ip")
    first = int(network.network_address) + 1
    last = int(network.broadcast_address) - 1
    usable = last - first + 1
    host_matches = 1 if host == address else 0
    host_unicast = 1 if _is_unicast_in(host, network) else 0
    vm_unicast = 1 if _is_unicast_in(vm, network) else 0
    distinct = 1 if vm != host else 0
    return {
        "accepted": 1 if host_matches and vm_unicast and distinct else 0,
        "broadcast": str(network.broadcast_address),
        "cidr": str(network),
        "distinct": distinct,
        "family": "ipv4",
        "host_ip": str(host),
        "host_matches_cidr": host_matches,
        "host_unicast": host_unicast,
        "interface_address": str(address),
        "netmask": str(network.netmask),
        "network": str(network.network_address),
        "prefix": prefix,
        "usable_count": usable if usable > 0 else 0,
        "usable_first": str(ipaddress.IPv4Address(first)) if usable > 0 else "",
        "usable_last": str(ipaddress.IPv4Address(last)) if usable > 0 else "",
        "vm_in_cidr": 1 if vm in network else 0,
        "vm_ip": str(vm),
        "vm_unicast": vm_unicast,
    }


def _normalize_managed_network(value: Any) -> dict:
    """Identidade da rede gerenciada que autoriza a exceção `proto kernel`.

    Corresponde ao que `preparar_excecoes_rotas_rede_atual`
    (`etapas/60-rede-bridge.sh:1127-1171`) monta a partir do XML ativo:
    bridge, CIDR derivado do endereço IPv4 e o próprio endereço como gateway.
    Quando não há exceção (`TEM_EXCECOES_ROTA_REDE_ATUAL=0`), o produtor envia
    `present=false` e nenhum resíduo.
    """
    label = "managed"
    fields = {"present", "family", "cidr", "gateway", "bridge"}
    data = _closed(value, fields, label)
    present = _boolean(data, "present", label)
    family = _text(data, "family", label, allow_empty=True)
    cidr = _text(data, "cidr", label, allow_empty=True)
    gateway = _text(data, "gateway", label, allow_empty=True)
    bridge = _text(data, "bridge", label, allow_empty=True)
    if not present:
        if family or cidr or gateway or bridge:
            raise DataError(
                "rede gerenciada ausente contém identidade residual."
            )
        return {
            "bridge": "",
            "broadcast": "",
            "cidr": "",
            "family": "",
            "gateway": "",
            "network": None,
            "network_address": "",
            "prefix": 0,
            "present": False,
        }
    require_supported_family(family, "managed.family")
    bridge = _interface_name(bridge, "managed.bridge")
    address, prefix, network = parse_ipv4_cidr(cidr, "managed.cidr")
    if address != network.network_address:
        raise DataError(
            "managed.cidr precisa ser o endereço de rede canônico; o Bash o "
            "deriva com inteiro_para_ipv4_rede antes de comparar."
        )
    gateway_address = parse_ipv4_address(gateway, "managed.gateway")
    if not _is_unicast_in(gateway_address, network):
        raise DataError(
            "managed.gateway precisa ser um unicast dentro de managed.cidr."
        )
    return {
        "bridge": bridge,
        "broadcast": str(network.broadcast_address),
        "cidr": str(network),
        "family": family,
        "gateway": str(gateway_address),
        "network": network,
        "network_address": str(network.network_address),
        "prefix": prefix,
        "present": True,
    }


def _kernel_exception(
    route: Mapping[str, Any],
    route_class: str,
    address: ipaddress.IPv4Address,
    prefix: int,
    managed: Mapping[str, Any],
) -> bool:
    """Reproduz `rota_kernel_exata_da_rede_atual`
    (`etapas/60-rede-bridge.sh:1173-1192`), inclusive a exigência de `dev`
    igual à bridge da rede gerenciada e de `proto kernel` na linha.

    As comparações do Bash são de texto sobre o destino já normalizado, então
    aqui elas viram igualdade de endereço literal mais prefixo: `192.168.9.5/24`
    continua não sendo exceção da rede `192.168.9.0/24`, como lá.
    """
    if not managed["present"]:
        return False
    if route_class not in KERNEL_EXCEPTION_CLASSES:
        return False
    if route["device"] != managed["bridge"]:
        return False
    if route["protocol"] != KERNEL_PROTOCOL:
        return False
    network = managed["network"]
    if route_class == "conectada":
        return address == network.network_address and prefix == managed["prefix"]
    if route_class == "local":
        return str(address) == managed["gateway"] and prefix == 32
    if route_class == "broadcast":
        return prefix == 32 and address in (
            network.network_address,
            network.broadcast_address,
        )
    return False


def route_audit(payload: Mapping[str, Any]) -> dict:
    """Classifica cada rota e mede a sobreposição com o CIDR candidato.

    Espelha o laço de rotas de `detectar_colisao_subrede`
    (`etapas/60-rede-bridge.sh:1220-1260`): destino `default` é ignorado,
    endereço nu vira `/32`, a exceção `proto kernel` da rede gerenciada é a
    única sobreposição tolerada e qualquer outra é colisão. A ordem é a das
    rotas já normalizadas (canônica e estável), então `collision_first_index`
    é determinístico.
    """
    label = "route_audit"
    data = _closed(payload, {"candidate_cidr", "managed", "routes"}, label)
    _address, _prefix, candidate = parse_ipv4_cidr(
        _text(data, "candidate_cidr", label), "route_audit.candidate_cidr"
    )
    managed = _normalize_managed_network(data["managed"])
    routes = _normalize_routes(data["routes"])

    result: dict[str, Any] = {}
    skipped_count = 0
    exception_count = 0
    overlap_count = 0
    collision_count = 0
    collision_first_index = -1
    collision_first_destination = ""
    collision_first_device = ""
    for index, route in enumerate(routes):
        prefix_key = "route_%d_" % index
        destination = route["destination"]
        route_class = ROUTE_CLASSES[route["type"]]
        result[prefix_key + "type"] = route["type"]
        result[prefix_key + "device"] = route["device"]
        if destination == DEFAULT_DESTINATION:
            # I7.2: borda preservada. O Bash ignora o destino textual
            # `default`, mas NÃO ignora um `0.0.0.0/0` escrito por extenso,
            # que então colide com qualquer candidata.
            skipped_count += 1
            result[prefix_key + "class"] = "default"
            result[prefix_key + "destination"] = DEFAULT_DESTINATION
            result[prefix_key + "network"] = ""
            result[prefix_key + "skipped"] = 1
            result[prefix_key + "kernel_exception"] = 0
            result[prefix_key + "overlaps"] = 0
            result[prefix_key + "collision"] = 0
            continue
        route_label = "routes[%d].destination" % index
        text = destination if "/" in destination else "%s/32" % destination
        address, prefix, network = parse_ipv4_cidr(text, route_label)
        exception = _kernel_exception(route, route_class, address, prefix, managed)
        overlaps = network.overlaps(candidate)
        collision = bool(overlaps and not exception)
        if exception:
            exception_count += 1
        if overlaps:
            overlap_count += 1
        if collision:
            collision_count += 1
            if collision_first_index < 0:
                collision_first_index = index
                collision_first_destination = text
                collision_first_device = route["device"]
        result[prefix_key + "class"] = route_class
        result[prefix_key + "destination"] = text
        result[prefix_key + "network"] = str(network)
        result[prefix_key + "skipped"] = 0
        result[prefix_key + "kernel_exception"] = 1 if exception else 0
        result[prefix_key + "overlaps"] = 1 if overlaps else 0
        result[prefix_key + "collision"] = 1 if collision else 0

    result.update(
        {
            "candidate_broadcast": str(candidate.broadcast_address),
            "candidate_cidr": str(candidate),
            "candidate_network": str(candidate.network_address),
            "collision": 1 if collision_count else 0,
            "collision_count": collision_count,
            "collision_first_destination": collision_first_destination,
            "collision_first_device": collision_first_device,
            "collision_first_index": collision_first_index,
            "exception_count": exception_count,
            "has_exceptions": 1 if managed["present"] else 0,
            "managed_bridge": managed["bridge"],
            "managed_broadcast": managed["broadcast"],
            "managed_cidr": managed["cidr"],
            "managed_gateway": managed["gateway"],
            "managed_network": managed["network_address"],
            "managed_prefix": managed["prefix"],
            "managed_present": 1 if managed["present"] else 0,
            "overlap_count": overlap_count,
            "route_count": len(routes),
            "skipped_count": skipped_count,
        }
    )
    return result
