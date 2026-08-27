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

I7.3 acrescentou o planner determinístico: precondições com identificador
estável, operações abstratas ordenadas, pós-condições e rollback inverso, tudo
sobre o payload recebido. I7.7 mantém a intenção independente de backend: o
plano descreve um artefato `{escopo, identificador, conteúdo, modo}` e
parâmetros declarativos de perfil, nunca uma ferramenta, um caminho ou um
comando. Nenhum YAML é interpretado aqui e nenhum parser de YAML nasce aqui.

I7.4 acrescentou a detecção de consumidores por MAC, cardinalidade e marcador
sobre o inventário de domínios que o Bash captura, mais as duas evidências que
faltavam ao snapshot para fechar precondições abertas em I7.3: se o link é
estação sem fio e quais redes libvirt de terceiros existem (nome, marcador,
bridge por estado). A execução transacional pertence a I7.6.
"""
from __future__ import annotations

import hashlib
import ipaddress
import json
import re
from typing import Any, Iterable, Mapping

from . import config, network_xml, xmlutil
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
    "foreign_networks",
    "consumers",
    "configuration",
)
# I7.4: interface de inventário bruto pode não ter fonte compartilhada alguma
# (`type='user'`, `type='vhostuser'`, NIC de hostdev). Ela é representada com
# `source_type` explícito em vez de fonte vazia adivinhada.
INVENTORY_SOURCE_TYPES = frozenset(SOURCE_TYPES | {"other"})
MAX_TEXT_BYTES = 4 * 1024 * 1024
MAX_ROUTES = 4096
MAX_LINKS = 4096
MAX_CONSUMERS = 1024
MAX_CONFIGURATIONS = 128
MAX_INTERFACES_PER_VM = 64
MAX_LIST_ITEMS = 4096
# I7.4: `virsh net-list --all` de um host real tem dezenas de entradas; o teto
# existe só para impedir payload absurdo, como os demais desta seção.
MAX_NETWORKS = 256
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
        "wireless",
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
        # I7.4: evidência de `interface_wifi` (`lib/common.sh:2243`), que testa
        # a existência de `/sys/class/net/NOME/wireless`. O Python nunca sonda
        # `/sys`: quem captura é o Bash, e o campo é obrigatório para que um
        # captor que esqueça a evidência falhe alto em vez de aprovar bridge
        # sobre Wi-Fi por omissão.
        "wireless": _boolean(payload, "wireless", label),
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


def _normalize_network_record(value: Any, index: int, prefix: str) -> dict:
    """Uma rede libvirt vizinha, como `validar_bridge_libvirt_disponivel` a vê.

    O Bash (`etapas/60-rede-bridge.sh:1357-1379`) percorre `virsh net-list
    --all --name`, consulta ativa/persistente e captura o XML de CADA estado,
    porque `net-edit` pode deixar a bridge persistente diferente da ativa. Por
    isso a bridge aqui é declarada POR ESTADO, e a recusa consegue nomear o
    estado exatamente como a mensagem histórica faz.
    """
    label = "%s[%d]" % (prefix, index)
    fields = {
        "active",
        "active_bridge",
        "marker",
        "name",
        "persistent",
        "persistent_bridge",
    }
    payload = _closed(value, fields, label)
    name = _entity_name(_text(payload, "name", label), "%s.name" % label)
    active = _boolean(payload, "active", label)
    persistent = _boolean(payload, "persistent", label)
    if not active and not persistent:
        raise DataError(
            "%s não está ativa nem persistente; a rede não existiria." % label
        )
    bridges: dict[str, str] = {}
    for key, present in (("active_bridge", active), ("persistent_bridge", persistent)):
        bridge = _text(payload, key, label, allow_empty=True)
        if bridge:
            if not present:
                raise DataError(
                    "%s.%s exige o estado correspondente." % (label, key)
                )
            bridge = _interface_name(bridge, "%s.%s" % (label, key))
        bridges[key] = bridge
    return {
        "active": active,
        "active_bridge": bridges["active_bridge"],
        "marker": _text(payload, "marker", label, allow_empty=True),
        "name": name,
        "persistent": persistent,
        "persistent_bridge": bridges["persistent_bridge"],
    }


def _normalize_network_records(value: Any, prefix: str) -> list[dict]:
    records = [
        _normalize_network_record(item, index, prefix)
        for index, item in enumerate(_list(value, prefix, MAX_NETWORKS))
    ]
    names = [item["name"] for item in records]
    if len(names) != len(set(names)):
        raise DataError("%s contém nomes de rede duplicados." % prefix)
    return sorted(records, key=lambda item: item["name"])


def _record_bridges(record: Mapping[str, Any]) -> list[str]:
    """Bridges declaradas pela rede, sem repetição e em ordem canônica."""
    return sorted(
        {record["active_bridge"], record["persistent_bridge"]} - {""}
    )


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
    # I7.4: `foreign_networks` são as OUTRAS redes libvirt do host. A rede
    # gerenciada nunca aparece nas duas listas, exatamente como o laço do Bash
    # pula `$REDE_LIBVIRT` (`etapas/60-rede-bridge.sh:1360`).
    foreign = {item["name"] for item in state["foreign_networks"]}
    if network["name"] in foreign:
        raise DataError(
            "foreign_networks repete a rede gerenciada: %s."
            % safe_label(network["name"])
        )
    for consumer in state["consumers"]:
        for interface in consumer["interfaces"]:
            if interface["source_type"] == "network":
                # Consumidor de rede de terceiros é REPRESENTÁVEL: o Bash lista
                # todas as VMs do host, e uma delas pode estar presa a uma rede
                # que não é a gerenciada. A validação continua onde é legítima:
                # a fonte precisa ser uma rede que o snapshot conhece.
                managed = network["exists"] and interface["source"] == network["name"]
                if not managed and interface["source"] not in foreign:
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
        "foreign_networks": _normalize_network_records(
            payload["foreign_networks"], "foreign_networks"
        ),
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

    Aceita o payload aninhado ou o mapa plano do canal de pares
    (`_accept_route_audit_pairs`, I7.5); o schema fechado é o mesmo nos dois.
    """
    label = "route_audit"
    data = _closed(
        _accept_route_audit_pairs(payload),
        {"candidate_cidr", "managed", "routes"},
        label,
    )
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


# --- I7.4: consumidores por MAC, cardinalidade e marcador --------------------
# O Bash captura o inventário (`virsh list --all --name`, `dumpxml`, `virsh
# net-list`) e passa os fatos; aqui só há classificação determinística. Duas
# perguntas DIFERENTES da etapa 19 continuam separadas de propósito:
#
# * `listar_consumidores_rede_gerenciada` (`etapas/60-rede-bridge.sh:921`) olha
#   TODAS as VMs do `--all` e bloqueia a conversão NAT -> bridge;
# * `rede_nat_usada_por_outra_vm_ativa` (`etapas/60-rede-bridge.sh:1383`) olha
#   só as ATIVAS e bloqueia o restart da rede NAT.
#
# Unificar a detecção não pode unificar a decisão: o relatório publica os dois
# conjuntos, e é o chamador que escolhe qual usar.

CONSUMER_SCHEMA_VERSION = 1
# Como UMA interface consome o recurso gerenciado. Toda classe é explícita;
# ausência de classe é string vazia, nunca um default implícito.
CONSUMER_MATCH_KINDS = (
    "bridge",  # <source bridge='...'> em uma das bridges candidatas
    "direct",  # macvtap <source dev='...'> sobre uma bridge candidata
    "marker",  # outra rede libvirt com o marcador exato, ou a bridge dela
    "network",  # a rede gerenciada, pelo nome, com o marcador confirmado
    "unknown-network",  # homônima que o inventário não conhece (fail-closed)
    "unmanaged-network",  # homônima SEM o marcador: não é nossa
)
# Consumo do recurso QUE ESTE PROJETO GERENCIA. `unmanaged-network` fica fora
# de propósito: rede homônima sem o marcador não é nossa e destruí-la nunca
# esteve em questão.
CONSUMER_OWNED_KINDS = frozenset(
    {"bridge", "direct", "marker", "network", "unknown-network"}
)
# Paridade exata com `CONSU_CONSUMER_COUNT` (`domain_xml.interface_state`), que
# conta `source/@network == network_name` mais `source/@bridge in bridge_names`,
# sem consultar marcador algum e sem olhar `source/@dev`.
CONSUMER_PARITY_KINDS = frozenset(
    {"bridge", "network", "unknown-network", "unmanaged-network"}
)
CONSUMER_ANOMALIES = (
    "domain-without-interface",
    "mac-missing",
    "mac-repeated",
    "mac-shared",
    "network-unknown",
)


def _normalize_inventory_interface(value: Any, domain_index: int, index: int) -> dict:
    label = "domains[%d].interfaces[%d]" % (domain_index, index)
    payload = _closed(value, {"mac", "source_type", "source"}, label)
    source_type = _text(payload, "source_type", label)
    if source_type not in INVENTORY_SOURCE_TYPES:
        raise DataError("%s.source_type não é suportado." % label)
    source = _text(payload, "source", label, allow_empty=True)
    if source_type == "other":
        if source:
            raise DataError(
                "%s sem fonte compartilhada não pode declarar source." % label
            )
    elif not source:
        raise DataError("%s.source precisa ser texto não vazio." % label)
    elif source_type in {"bridge", "direct"}:
        source = _interface_name(source, "%s.source" % label)
    else:
        source = _entity_name(source, "%s.source" % label)
    return {
        # MAC vazio é ESTADO TIPADO: `<interface>` sem `<mac address=...>` é
        # legal no XML inativo e o libvirt sorteia um no start. A identidade da
        # NIC não existe nesse caso, e o relatório diz isso em vez de inventar.
        "mac": _mac(
            _text(payload, "mac", label, allow_empty=True),
            "%s.mac" % label,
            allow_empty=True,
        ),
        "source": source,
        "source_type": source_type,
    }


def _normalize_inventory_domain(value: Any, index: int) -> dict:
    label = "domains[%d]" % index
    payload = _closed(value, {"name", "active", "defined", "interfaces"}, label)
    name = _entity_name(_text(payload, "name", label), "%s.name" % label)
    active = _boolean(payload, "active", label)
    defined = _boolean(payload, "defined", label)
    if not active and not defined:
        raise DataError(
            "%s não está ativo nem definido; o domínio não seria listado." % label
        )
    interfaces = [
        _normalize_inventory_interface(item, index, interface_index)
        for interface_index, item in enumerate(
            _list(payload["interfaces"], "%s.interfaces" % label, MAX_INTERFACES_PER_VM)
        )
    ]
    return {
        "active": active,
        "defined": defined,
        # Domínio SEM NIC é representável e vira anomalia tipada no relatório:
        # ele existe no `--all` e simplesmente não consome rede alguma.
        "interfaces": sorted(interfaces, key=_canonical),
        "name": name,
    }


def normalize_consumer_request(value: Any) -> dict:
    """Valida o inventário fechado de domínios e redes já capturado pelo Bash.

    Como o planner, aceita o objeto aninhado ou o mapa plano do canal de pares
    (`_accept_consumer_pairs`, I7.5) sem afrouxar campo algum do schema.
    """
    value = _accept_consumer_pairs(value)
    fields = {
        "bridges",
        "domains",
        "marker",
        "network_name",
        "networks",
        "schema_version",
        "target",
    }
    payload = _closed(value, fields, "consumers")
    if (
        type(payload["schema_version"]) is not int
        or payload["schema_version"] != CONSUMER_SCHEMA_VERSION
    ):
        raise DataError("Versão do schema de consumidores não suportada.")
    target = _text(payload, "target", "consumers", allow_empty=True)
    if target:
        target = _entity_name(target, "consumers.target")
    domains = [
        _normalize_inventory_domain(item, index)
        for index, item in enumerate(
            _list(payload["domains"], "consumers.domains", MAX_CONSUMERS)
        )
    ]
    names = [item["name"] for item in domains]
    if len(names) != len(set(names)):
        raise DataError("consumers.domains contém domínios duplicados.")
    return {
        "bridges": _normalized_text_list(
            payload["bridges"], "consumers.bridges", interface_names=True
        ),
        "domains": sorted(domains, key=lambda item: item["name"]),
        # Marcador vazio tornaria "sem marcador" indistinguível de "nosso"; a
        # etapa sempre tem `REDE_MARCADOR` (`etapas/60-rede-bridge.sh:22`).
        "marker": _text(payload, "marker", "consumers"),
        "network_name": _entity_name(
            _text(payload, "network_name", "consumers"), "consumers.network_name"
        ),
        "networks": _normalize_network_records(
            payload["networks"], "consumers.networks"
        ),
        "schema_version": CONSUMER_SCHEMA_VERSION,
        "target": target,
    }


def _consumer_context(
    *,
    marker: str,
    network_name: str,
    network_known: bool,
    network_owned: bool,
    bridges: Iterable[str],
    networks: Iterable[Mapping[str, Any]],
) -> dict:
    """Fecha o vocabulário usado para classificar cada interface.

    `network_owned` chega pronto porque a propriedade da rede gerenciada é
    provada de formas diferentes conforme o chamador: o planner já a derivou do
    XML por `network_xml.inspect_network`, e o subcomando a deriva do marcador
    capturado. Em ambos a comparação é de IGUALDADE EXATA, nunca prefixo.
    """
    marker_networks = {
        item["name"]
        for item in networks
        if item["name"] != network_name and item["marker"] == marker
    }
    marker_bridges: set[str] = set()
    for item in networks:
        if item["name"] in marker_networks:
            marker_bridges.update(_record_bridges(item))
    known = {item["name"] for item in networks}
    if network_known:
        known.add(network_name)
    return {
        "bridges": frozenset(bridges),
        "known_networks": frozenset(known),
        "marker_bridges": frozenset(marker_bridges),
        "marker_networks": frozenset(marker_networks),
        "network_known": bool(network_known),
        "network_name": network_name,
        "network_owned": bool(network_owned),
    }


def _classify_interface(
    interface: Mapping[str, Any], context: Mapping[str, Any]
) -> str:
    """Classe de consumo de UMA interface; string vazia quando não consome."""
    source_type = interface["source_type"]
    source = interface["source"]
    if source_type == "network":
        if source == context["network_name"]:
            if not context["network_known"]:
                return "unknown-network"
            return "network" if context["network_owned"] else "unmanaged-network"
        if source in context["marker_networks"]:
            return "marker"
        return ""
    if source_type in {"bridge", "direct"}:
        if source in context["bridges"]:
            return "bridge" if source_type == "bridge" else "direct"
        if source in context["marker_bridges"]:
            return "marker"
    return ""


def _anomaly(kind: str, subject: str, detail: str) -> dict:
    if kind not in CONSUMER_ANOMALIES:
        raise InternalError("Anomalia de consumidor fora do vocabulário.")
    return {"detail": detail, "kind": kind, "subject": subject}


def _consumer_records(
    domains: Iterable[Mapping[str, Any]],
    target: str,
    context: Mapping[str, Any],
) -> dict:
    """Classifica o inventário inteiro em consumidores, MACs e anomalias."""
    consumers: list[dict] = []
    anomalies: list[dict] = []
    macs: dict[str, dict] = {}
    kind_totals = {kind: 0 for kind in CONSUMER_MATCH_KINDS}
    interface_total = 0
    target_seen = False
    target_interfaces = 0
    target_matches = 0
    target_parity = 0

    for domain in domains:
        name = domain["name"]
        # A VM alvo é identificada pelo NOME, nunca pelo MAC: o oráculo I0
        # semeia `other-vm` como cópia de `vm.xml` (tests/lib/mutator-harness.
        # sh:497-508), então alvo e consumidor compartilham o MESMO MAC. Excluir
        # por MAC apagaria o consumidor que a etapa precisa recusar.
        is_target = bool(target) and name == target
        target_seen = target_seen or is_target
        interfaces = domain["interfaces"]
        interface_total += len(interfaces)
        if not interfaces:
            anomalies.append(_anomaly("domain-without-interface", name, ""))
        matched: list[dict] = []
        kinds: set[str] = set()
        parity = 0
        for interface in interfaces:
            kind = _classify_interface(interface, context)
            owned = kind in CONSUMER_OWNED_KINDS
            if (
                interface["source_type"] == "network"
                and interface["source"] not in context["known_networks"]
            ):
                anomalies.append(
                    _anomaly("network-unknown", name, interface["source"])
                )
            if interface["mac"]:
                record = macs.setdefault(
                    interface["mac"],
                    {
                        "domains": set(),
                        "interface_count": 0,
                        "mac": interface["mac"],
                        "match_count": 0,
                        "match_domains": set(),
                    },
                )
                record["domains"].add(name)
                record["interface_count"] += 1
                if owned and not is_target:
                    record["match_count"] += 1
                    record["match_domains"].add(name)
            else:
                anomalies.append(_anomaly("mac-missing", name, interface["source"]))
            if kind:
                # `match_kinds` guarda TODA classe encontrada, inclusive a que
                # não é nossa: é ela que explica por que a VM aparece na lista
                # sem bloquear nada.
                kinds.add(kind)
                if not is_target:
                    kind_totals[kind] += 1
            if kind in CONSUMER_PARITY_KINDS:
                parity += 1
            if owned:
                matched.append(interface)
        if is_target:
            target_interfaces = len(interfaces)
            target_matches = len(matched)
            target_parity = parity
            continue
        if not matched and not parity:
            continue
        consumers.append(
            {
                "active": 1 if domain["active"] else 0,
                "defined": 1 if domain["defined"] else 0,
                "interface_count": len(interfaces),
                "macs": sorted(item["mac"] for item in matched),
                "match_count": len(matched),
                "match_kinds": sorted(kinds),
                "name": name,
                "parity_count": parity,
                # Domínio ativo e não persistente: some no próximo desligamento,
                # mas aparece no `--all` e bloqueia igual.
                "transient": 1 if domain["active"] and not domain["defined"] else 0,
            }
        )

    for mac, record in macs.items():
        if len(record["domains"]) > 1:
            anomalies.append(
                _anomaly("mac-shared", mac, ",".join(sorted(record["domains"])))
            )
        if record["interface_count"] > len(record["domains"]):
            anomalies.append(
                _anomaly("mac-repeated", mac, ",".join(sorted(record["domains"])))
            )

    mac_records = [
        {
            "domain_count": len(record["domains"]),
            "domains": sorted(record["domains"]),
            "interface_count": record["interface_count"],
            "mac": record["mac"],
            "match_count": record["match_count"],
            "match_domain_count": len(record["match_domains"]),
            "shared": 1 if len(record["domains"]) > 1 else 0,
        }
        for record in macs.values()
    ]
    return {
        "anomalies": sorted(
            anomalies, key=lambda item: (item["kind"], item["subject"], item["detail"])
        ),
        "consumers": sorted(consumers, key=lambda item: item["name"]),
        "interface_total": interface_total,
        "kind_totals": kind_totals,
        "macs": sorted(mac_records, key=lambda item: item["mac"]),
        "target_interfaces": target_interfaces,
        "target_matches": target_matches,
        "target_parity": target_parity,
        "target_seen": target_seen,
    }


def _consumer_summary(records: Mapping[str, Any], domain_count: int) -> dict:
    consumers = records["consumers"]
    owned = [item for item in consumers if item["match_count"]]
    active = [item for item in owned if item["active"]]
    kinds = records["kind_totals"]
    counted = {kind: kinds[kind] for kind in CONSUMER_OWNED_KINDS}
    anomaly_totals = {kind: 0 for kind in CONSUMER_ANOMALIES}
    for item in records["anomalies"]:
        anomaly_totals[item["kind"]] += 1
    return {
        "active_consumer_count": len(active),
        "active_consumer_names": [item["name"] for item in active],
        "anomaly_count": len(records["anomalies"]),
        "consumer_interface_count": sum(item["match_count"] for item in owned),
        "consumer_mac_count": sum(
            1 for item in records["macs"] if item["match_count"]
        ),
        # "Definida" tem aqui o mesmo alcance que em `virsh list --all`: toda VM
        # do inventário, inclusive a transitória que está ligada. É esse o
        # conjunto que recusa a conversão NAT -> bridge.
        "defined_consumer_count": len(owned),
        "defined_consumer_names": [item["name"] for item in owned],
        "direct_match_count": counted["direct"],
        "domain_count": domain_count,
        "domain_without_interface_count": anomaly_totals["domain-without-interface"],
        "interface_count": records["interface_total"],
        "mac_missing_count": anomaly_totals["mac-missing"],
        "mac_repeated_count": anomaly_totals["mac-repeated"],
        "mac_shared_count": anomaly_totals["mac-shared"],
        "marker_match_count": counted["marker"],
        "network_match_count": counted["network"],
        "network_unknown_count": anomaly_totals["network-unknown"],
        # Paridade byte a byte com a soma de `CONSU_CONSUMER_COUNT` sobre as
        # mesmas VMs; a divergência deliberada está nos campos `direct_*`,
        # `marker_*` e `unmanaged_*`.
        "parity_consumer_count": sum(item["parity_count"] for item in consumers),
        "parity_target_count": records["target_parity"],
        "target_interface_count": records["target_interfaces"],
        "target_match_count": records["target_matches"],
        "target_present": 1 if records["target_seen"] else 0,
        "transient_consumer_count": sum(item["transient"] for item in owned),
        "unknown_network_match_count": counted["unknown-network"],
        "unmanaged_match_count": kinds["unmanaged-network"],
    }


def consumer_report(payload: Mapping[str, Any]) -> dict:
    """Detecta consumidores da rede gerenciada por MAC, bridge e marcador.

    Devolve documento fechado e ordenado: quem consome, com quantas NICs, com
    quais MACs, por qual caminho, e o que ficou anômalo. Nenhuma decisão é
    tomada aqui — a etapa continua escolhendo entre o conjunto "definido" e o
    conjunto "ativo", que saem separados de propósito.
    """
    request = normalize_consumer_request(payload)
    networks = request["networks"]
    marker = request["marker"]
    name = request["network_name"]
    managed = next((item for item in networks if item["name"] == name), None)
    context = _consumer_context(
        marker=marker,
        network_name=name,
        network_known=managed is not None,
        network_owned=managed is not None and managed["marker"] == marker,
        bridges=request["bridges"],
        networks=networks,
    )
    records = _consumer_records(request["domains"], request["target"], context)
    return {
        "anomalies": records["anomalies"],
        "bridges": sorted(context["bridges"]),
        "consumers": records["consumers"],
        "macs": records["macs"],
        "marker_bridges": sorted(context["marker_bridges"]),
        "marker_networks": sorted(context["marker_networks"]),
        "network_known": 1 if context["network_known"] else 0,
        "network_name": name,
        "network_owned": 1 if context["network_owned"] else 0,
        "schema_version": CONSUMER_SCHEMA_VERSION,
        "summary": _consumer_summary(records, len(request["domains"])),
        "target": request["target"],
    }


def network_consumers(payload: Mapping[str, Any]) -> dict:
    """Projeta o relatório no canal escalar da ponte, como `network-plan`."""
    report = consumer_report(payload)
    summary = report["summary"]
    data: dict[str, Any] = {
        "network_known": report["network_known"],
        "network_name": report["network_name"],
        "network_owned": report["network_owned"],
        "report_sha256": _digest(report),
        "schema_version": report["schema_version"],
        "target": report["target"],
    }
    data.update(summary)
    data["active_consumer_names"] = "\n".join(summary["active_consumer_names"])
    data["defined_consumer_names"] = "\n".join(summary["defined_consumer_names"])
    data["bridges"] = "\n".join(report["bridges"])
    data["marker_bridges"] = "\n".join(report["marker_bridges"])
    data["marker_networks"] = "\n".join(report["marker_networks"])
    data["consumer_count"] = len(report["consumers"])
    data["mac_count"] = len(report["macs"])
    for index, consumer in enumerate(report["consumers"]):
        prefix = "consumer_%d_" % index
        data[prefix + "active"] = consumer["active"]
        data[prefix + "defined"] = consumer["defined"]
        data[prefix + "interface_count"] = consumer["interface_count"]
        data[prefix + "macs"] = "\n".join(consumer["macs"])
        data[prefix + "match_count"] = consumer["match_count"]
        data[prefix + "match_kinds"] = "\n".join(consumer["match_kinds"])
        data[prefix + "name"] = consumer["name"]
        data[prefix + "parity_count"] = consumer["parity_count"]
        data[prefix + "transient"] = consumer["transient"]
    for index, record in enumerate(report["macs"]):
        prefix = "mac_%d_" % index
        data[prefix + "domain_count"] = record["domain_count"]
        data[prefix + "domains"] = "\n".join(record["domains"])
        data[prefix + "interface_count"] = record["interface_count"]
        data[prefix + "mac"] = record["mac"]
        data[prefix + "match_count"] = record["match_count"]
        data[prefix + "match_domain_count"] = record["match_domain_count"]
        data[prefix + "shared"] = record["shared"]
    for index, anomaly in enumerate(report["anomalies"]):
        prefix = "anomaly_%d_" % index
        data[prefix + "detail"] = anomaly["detail"]
        data[prefix + "kind"] = anomaly["kind"]
        data[prefix + "subject"] = anomaly["subject"]
    return data


# --- I7.3 e I7.7: plano determinístico, abstrato e backend-neutral -----------
# Nada abaixo produz comando, caminho de binário, nome de ferramenta ou
# fragmento de linha de comando. Uma operação do plano é VERBO + ALVO +
# ARGUMENTOS ESCALARES; quem traduz verbo em comando é o provider Bash (I7.5).
#
# I7.7: a configuração de rede do host é modelada como artefato abstrato
# `{escopo, identificador, conteúdo, modo}` mais os parâmetros declarativos do
# perfil (bridge, membro, DHCP, STP, atraso de encaminhamento). O identificador
# é um nome lógico, nunca um caminho: qual arquivo e qual ferramenta o
# materializam é decisão do provider. Nenhum YAML é interpretado aqui — o Bash
# de hoje apenas GERA o texto por heredoc e o compara com uma comparação de
# bytes, então não existe parser a remover e nenhum nasce neste módulo.

PLAN_SCHEMA_VERSION = 1

# Capacidades abstratas exigidas pela etapa. O provider é quem sabe qual
# executável fornece cada uma; o plano só nomeia a capacidade.
CAPABILITIES = frozenset(
    {
        "domain-schema-validation",
        "host-link-inspection",
        "host-network-apply",
        "hypervisor-control",
        "text-extraction",
    }
)
REQUIRED_CAPABILITIES = {
    "bridge": (
        "domain-schema-validation",
        "host-link-inspection",
        "host-network-apply",
        "hypervisor-control",
        "text-extraction",
    ),
    "nat": (
        "domain-schema-validation",
        "host-link-inspection",
        "hypervisor-control",
        "text-extraction",
    ),
}
PLAN_RESOURCE_TYPES = frozenset(
    {
        "domain",
        "host-network-profile",
        "libvirt-network",
        "project-configuration",
    }
)
PLAN_VERBS = frozenset(
    {
        "configuration-publish",
        "configuration-restore",
        "domain-redefine",
        "domain-restore",
        "host-network-activate",
        "host-network-activate-reversible",
        "host-profile-archive",
        "host-profile-discard",
        "host-profile-restore",
        "host-profile-store",
        "network-activate",
        "network-autostart-disable",
        "network-autostart-enable",
        "network-deactivate",
        "network-define",
        "network-recreate",
        "network-redefine",
        "network-undefine",
    }
)
SEVERITIES = frozenset({"refuse", "warn"})
# Componentes cujo fingerprint pode ser exigido antes de aplicar ou de
# restaurar (D-NET-CONCURRENCY). `target` é a VM gerenciada, que não faz parte
# do estado compartilhado de I7.1 e por isso tem digest próprio.
REVALIDATION_COMPONENTS = tuple(sorted(STATE_FIELDS + ("target",)))
PROJECT_SCOPE = "project"
NAT_NETMASK = "255.255.255.0"
NAT_PORT_START = 1024
NAT_PORT_END = 65535
# Prova exigida depois da restauração inteira da rede libvirt
# (`etapas/60-rede-bridge.sh:347-362`).
NETWORK_STATE_PROOF = (
    "existence_persistence_activity_and_autostart_equal_the_capture"
)


def _normalize_target(value: Any) -> dict:
    """Normaliza a VM gerenciada pela etapa.

    Ela não entra em `consumers`: aquele conjunto é, por construção do Bash, o
    das OUTRAS VMs que consomem a rede gerenciada (`listar_consumidores_rede_
    gerenciada`, `etapas/60-rede-bridge.sh:921`, já exclui `VM_NAME`). Manter a
    VM alvo fora dele preserva o modelo fechado de I7.1 e ainda deixa o plano
    decidir se a fonte da NIC precisa mudar.
    """
    label = "target"
    fields = {
        "active",
        "defined",
        "name",
        "nic_mac",
        "nic_match_count",
        "nic_source",
        "nic_source_type",
        "xml",
    }
    payload = _closed(value, fields, label)
    name = _entity_name(_text(payload, "name", label), "target.name")
    defined = _boolean(payload, "defined", label)
    active = _boolean(payload, "active", label)
    mac = _mac(_text(payload, "nic_mac", label), "target.nic_mac")
    match_count = _integer(payload, "nic_match_count", label)
    source_type = _text(payload, "nic_source_type", label, allow_empty=True)
    source = _text(payload, "nic_source", label, allow_empty=True)
    xml = _text(payload, "xml", label, allow_empty=True)
    if source_type and source_type not in SOURCE_TYPES:
        raise DataError("target.nic_source_type não é suportado.")
    if bool(source_type) != bool(source):
        raise DataError(
            "target.nic_source_type e target.nic_source precisam ser "
            "declarados juntos."
        )
    if source_type in {"bridge", "direct"}:
        source = _interface_name(source, "target.nic_source")
    elif source_type == "network":
        source = _entity_name(source, "target.nic_source")
    if not defined:
        if active or match_count or source_type or xml:
            raise DataError("target ausente contém estado residual.")
    else:
        if not xml:
            raise DataError("target definido precisa transportar o XML inativo.")
        _xml_fingerprint(xml, "domain", name, "XML da VM alvo")
        if match_count > MAX_INTERFACES_PER_VM:
            raise DataError("target.nic_match_count excede o limite de interfaces.")
        if source_type and match_count == 0:
            raise DataError("target declara fonte de NIC sem NIC correspondente.")
    return {
        "active": active,
        "defined": defined,
        "name": name,
        "nic_mac": mac,
        "nic_match_count": match_count,
        "nic_source": source,
        "nic_source_type": source_type,
        "xml": xml,
    }


def _normalize_host_profile(value: Any) -> dict:
    """Parâmetros declarativos do perfil de rede do host (I7.7).

    Descrevem a topologia pretendida sem nomear backend: bridge, membro,
    endereçamento automático e temporização de encaminhamento. Um provider
    futuro pode renderizar isso em qualquer formato; o conteúdo textual vem da
    intenção, não daqui.
    """
    label = "settings.host_profile"
    fields = {
        "dhcp4",
        "forward_delay",
        "identifier",
        "member_dhcp4",
        "member_dhcp6",
        "scope",
        "stp",
    }
    payload = _closed(value, fields, label)
    scope = _text(payload, "scope", label)
    if scope not in CONFIGURATION_SCOPES:
        raise DataError("%s.scope não é suportado." % label)
    identifier = _text(payload, "identifier", label)
    if "/" in identifier:
        raise DataError(
            "%s.identifier é um nome lógico; caminho é decisão do provider."
            % label
        )
    return {
        "dhcp4": _boolean(payload, "dhcp4", label),
        "forward_delay": _integer(payload, "forward_delay", label),
        "identifier": identifier,
        "member_dhcp4": _boolean(payload, "member_dhcp4", label),
        "member_dhcp6": _boolean(payload, "member_dhcp6", label),
        "scope": scope,
        "stp": _boolean(payload, "stp", label),
    }


def _normalize_settings(value: Any) -> dict:
    label = "settings"
    fields = {
        "capabilities",
        "configuration_identifier",
        "host_ip",
        "host_profile",
        "marker",
        "nat_bridge",
        "nat_cidr",
        "uplink_effective",
        "vm_ip",
    }
    payload = _closed(value, fields, label)
    capabilities = _normalized_text_list(
        payload["capabilities"], "settings.capabilities"
    )
    unknown = sorted(set(capabilities) - CAPABILITIES)
    if unknown:
        raise DataError(
            "settings.capabilities declara capacidade desconhecida: %s."
            % ", ".join(safe_label(item) for item in unknown)
        )
    identifier = _text(payload, "configuration_identifier", label)
    if "/" in identifier:
        raise DataError(
            "settings.configuration_identifier é um nome lógico; caminho é "
            "decisão do provider."
        )
    uplink_effective = _text(payload, "uplink_effective", label, allow_empty=True)
    if uplink_effective:
        uplink_effective = _interface_name(
            uplink_effective, "settings.uplink_effective"
        )
    host_ip = _text(payload, "host_ip", label, allow_empty=True)
    vm_ip = _text(payload, "vm_ip", label, allow_empty=True)
    if host_ip:
        host_ip = str(parse_ipv4_address(host_ip, "settings.host_ip"))
    if vm_ip:
        vm_ip = str(parse_ipv4_address(vm_ip, "settings.vm_ip"))
    return {
        "capabilities": capabilities,
        "configuration_identifier": identifier,
        "host_ip": host_ip,
        "host_profile": _normalize_host_profile(payload["host_profile"]),
        "marker": _text(payload, "marker", label),
        "nat_bridge": _interface_name(
            _text(payload, "nat_bridge", label), "settings.nat_bridge"
        ),
        "nat_cidr": _text(payload, "nat_cidr", label, allow_empty=True),
        "uplink_effective": uplink_effective,
        "vm_ip": vm_ip,
    }


def normalize_plan_request(value: Any) -> dict:
    """Valida o payload fechado do planner e normaliza cada parte.

    Aceita as duas formas do mesmo pedido: o objeto aninhado e o mapa plano do
    canal de pares, que `_accept_plan_pairs` (I7.5) monta na mesma estrutura
    antes de qualquer validação. O schema fechado abaixo continua idêntico.
    """
    value = _accept_plan_pairs(value)
    fields = {"schema_version", "snapshot", "intent", "target", "settings"}
    payload = _closed(value, fields, "plan")
    if (
        type(payload["schema_version"]) is not int
        or payload["schema_version"] != PLAN_SCHEMA_VERSION
    ):
        raise DataError("Versão do schema de plano de rede não suportada.")
    request = {
        "intent": normalize_intent(payload["intent"]),
        "schema_version": PLAN_SCHEMA_VERSION,
        "settings": _normalize_settings(payload["settings"]),
        "snapshot": normalize_snapshot(payload["snapshot"]),
        "target": _normalize_target(payload["target"]),
    }
    intent = request["intent"]
    settings = request["settings"]
    if intent["uplink"]["name"] != request["snapshot"]["uplink"]["name"]:
        raise DataError(
            "A intenção declara um uplink diferente do capturado no snapshot."
        )
    snapshot_network = request["snapshot"]["libvirt_network"]["name"]
    if intent["libvirt_network"]["name"] != snapshot_network:
        raise DataError(
            "A intenção declara uma rede libvirt diferente da capturada."
        )
    if intent["bridge"]["name"] == settings["nat_bridge"]:
        raise DataError(
            "A bridge do host e a bridge da rede libvirt não podem ter o "
            "mesmo nome."
        )
    return request


def _artifact(items: Iterable[Mapping[str, Any]], scope: str, identifier: str):
    for item in items:
        if item["scope"] == scope and item["identifier"] == identifier:
            return item
    return None


def _project_values(artifact) -> dict:
    """Projeta as chaves da configuração do projeto já capturada.

    Reusa o parser estrito de `config` (o mesmo de `config-load`), que lê
    `CHAVE=literal` e nada mais. Não há leitura de arquivo: o texto vem do
    snapshot.
    """
    if artifact is None or not artifact["exists"]:
        return {}
    document = config.parse_document(
        artifact["content"], "configuração do projeto"
    )
    return dict(document["values"])


def _managed_facts(network: Mapping[str, Any], marker: str) -> dict:
    """Lê propriedade, bridge, UUID e sub-rede da rede libvirt capturada.

    Espelha `rede_gerenciada` (`etapas/60-rede-bridge.sh:536`): quando a rede é
    persistente o oráculo é o XML persistente; caso contrário, o ativo.
    """
    empty = {
        "current_bridge": "",
        "current_gateway": "",
        "current_network": "",
        "current_prefix": 0,
        "current_uuid": "",
        "owned": False,
    }
    if not network["exists"]:
        return empty
    xml = network["persistent_xml"] or network["active_xml"]
    if not xml:
        return empty
    data = network_xml.inspect_network({"xml": xml, "marker": marker})
    return {
        "current_bridge": data["bridge_name"],
        "current_gateway": data.get("ip_0_address", ""),
        "current_network": data.get("ip_0_network", ""),
        "current_prefix": data.get("ip_0_prefix", 0),
        "current_uuid": data["uuid"],
        "owned": data["marker_match"] == 1,
    }


def _nat_definition_matches(xml: str, expected: Mapping[str, Any]) -> bool:
    """Reproduz as quatorze igualdades de `rede_nat_xml_confere`
    (`etapas/60-rede-bridge.sh:596-609`) sobre um XML já capturado."""
    if not xml:
        return False
    data = network_xml.inspect_network(
        {
            "xml": xml,
            "marker": expected["marker"],
            "nic_mac": expected["mac"],
            "vm_ip": expected["vm_ip"],
        }
    )
    return bool(
        data["marker_match"] == 1
        and data["forward_count"] == 1
        and data["forward_mode"] == "nat"
        and data["forward_dev"] == expected["device"]
        and data["bridge_name"] == expected["bridge"]
        and data["ip_count"] == 1
        and data.get("ip_0_address", "") == expected["gateway"]
        and data.get("ip_0_netmask", "") == expected["netmask"]
        and data["dhcp_range_count"] == 1
        and data["dhcp_range_start"] == expected["dhcp_start"]
        and data["dhcp_range_end"] == expected["dhcp_end"]
        and data["dhcp_mac_count"] == 1
        and data["dhcp_mac_ip"] == expected["vm_ip"]
        and data["dhcp_ip_count"] == 1
    )


def _bridge_runtime_ok(links: Mapping[str, Any], bridge: str, member: str) -> bool:
    """Espelha `bridge_runtime_confere` (`etapas/60-rede-bridge.sh:511`):
    bridge presente, administrativamente UP e uplink escravizado a ela."""
    link = links.get(bridge)
    if link is None or "UP" not in link["flags"]:
        return False
    uplink = links.get(member)
    return uplink is not None and uplink["master"] == bridge


def _plan_facts(request: Mapping[str, Any]) -> dict:
    snapshot = request["snapshot"]
    intent = request["intent"]
    target = request["target"]
    settings = request["settings"]
    mode = intent["mode"]
    links = {item["name"]: item for item in snapshot["links"]}
    uplink = intent["uplink"]["name"]
    current = snapshot["libvirt_network"]
    facts: dict[str, Any] = {
        "foreign_networks": snapshot["foreign_networks"],
        "host_bridge": intent["bridge"]["name"],
        "links": links,
        "marker": settings["marker"],
        "mode": mode,
        "nat_bridge": settings["nat_bridge"],
        "network_exists": current["exists"],
        "network_name": intent["libvirt_network"]["name"],
        "uplink": uplink,
    }
    facts.update(_managed_facts(current, settings["marker"]))

    project = _artifact(
        snapshot["configuration"],
        PROJECT_SCOPE,
        settings["configuration_identifier"],
    )
    facts["project_artifact"] = project
    facts["project_values"] = _project_values(project)

    profile = settings["host_profile"]
    facts["profile_current"] = _artifact(
        snapshot["configuration"], profile["scope"], profile["identifier"]
    )
    facts["profile_desired"] = _artifact(
        intent["configuration"], profile["scope"], profile["identifier"]
    )

    others = [
        item for item in snapshot["consumers"] if item["name"] != target["name"]
    ]
    facts["consumers_other"] = others
    # I7.4: a separação definida/ativa saiu daqui e passou a vir do relatório,
    # que classifica cada NIC antes de contar VM alguma.
    facts["consumer_summary"] = _consumer_facts(facts)

    if mode == "nat":
        addresses = nat_addresses({"cidr": settings["nat_cidr"]})
        expected = {
            "bridge": settings["nat_bridge"],
            "device": uplink,
            "dhcp_end": addresses["nat_dhcp_fim"],
            "dhcp_start": addresses["nat_dhcp_inicio"],
            "gateway": addresses["nat_gateway"],
            "mac": target["nic_mac"],
            "marker": settings["marker"],
            "netmask": NAT_NETMASK,
            "vm_ip": addresses["nat_vm_ip"],
        }
        facts["addresses"] = addresses
        facts["expected"] = expected
        facts["persistent_matches"] = bool(
            current["exists"]
            and current["persistent"]
            and _nat_definition_matches(current["persistent_xml"], expected)
        )
        facts["active_matches"] = bool(
            current["exists"]
            and current["active"]
            and _nat_definition_matches(current["active_xml"], expected)
        )
        facts["needs_define"] = not (
            current["exists"] and current["persistent"] and facts["persistent_matches"]
        )
        facts["needs_restart"] = bool(
            facts["needs_define"]
            or (current["active"] and not facts["active_matches"])
        )
        # A exceção `proto kernel` só existe quando a rede substituída é nossa
        # e tem IPv4. Fora disso a identidade vai vazia, porque
        # `_normalize_managed_network` recusa resíduo em rede ausente.
        excecao = bool(facts["owned"] and facts["current_network"])
        managed = {
            "bridge": facts["current_bridge"] if excecao else "",
            "cidr": (
                "%s/%d" % (facts["current_network"], facts["current_prefix"])
                if excecao
                else ""
            ),
            "family": "ipv4" if excecao else "",
            "gateway": facts["current_gateway"] if excecao else "",
            "present": excecao,
        }
        facts["route_audit"] = route_audit(
            {
                "candidate_cidr": settings["nat_cidr"],
                "managed": managed,
                "routes": [dict(item) for item in snapshot["routes"]],
            }
        )
        facts["desired_source_type"] = "network"
        facts["desired_source"] = facts["network_name"]
    else:
        facts["addresses"] = {}
        facts["expected"] = {}
        facts["persistent_matches"] = False
        facts["active_matches"] = False
        facts["needs_define"] = False
        facts["needs_restart"] = False
        facts["route_audit"] = {}
        facts["desired_source_type"] = "bridge"
        facts["desired_source"] = facts["host_bridge"]
        desired = facts["profile_desired"]
        current_profile = facts["profile_current"]
        facts["profile_content_equal"] = bool(
            desired is not None
            and current_profile is not None
            and current_profile["exists"]
            and desired["exists"]
            and current_profile["content"] == desired["content"]
        )
        facts["profile_runtime_ok"] = _bridge_runtime_ok(
            links, facts["host_bridge"], uplink
        )
        facts["needs_apply"] = not (
            facts["profile_content_equal"] and facts["profile_runtime_ok"]
        )

    facts["domain_converged"] = bool(
        target["defined"]
        and target["nic_match_count"] == 1
        and target["nic_source_type"] == facts["desired_source_type"]
        and target["nic_source"] == facts["desired_source"]
    )
    return facts


def _configuration_targets(request: Mapping[str, Any], facts: Mapping[str, Any]):
    """Ordena as publicações de configuração como a etapa 19 as executa.

    Estágio um: as três chaves de nomes gravadas antes de tocar em qualquer
    recurso (`etapas/60-rede-bridge.sh:794-796`) e o MAC persistido por
    `garantir_vm_nic_mac`. Estágio dois: os endereços gravados no final do
    caminho escolhido.
    """
    intent = request["intent"]
    settings = request["settings"]
    target = request["target"]
    stage_one = (
        ("REDE_BRIDGE", intent["bridge"]["name"]),
        ("REDE_LIBVIRT", intent["libvirt_network"]["name"]),
        ("REDE_BRIDGE_LIBVIRT", settings["nat_bridge"]),
        ("VM_NIC_MAC", target["nic_mac"]),
    )
    if facts["mode"] == "nat":
        addresses = facts["addresses"]
        stage_two = (
            ("REDE_NAT_CIDR", addresses["nat_cidr"]),
            ("VM_IP_FIXO", addresses["nat_vm_ip"]),
            ("IP_FIXO_HOST", addresses["nat_gateway"]),
        )
    else:
        stage_two = tuple(
            item
            for item in (
                ("VM_IP_FIXO", settings["vm_ip"]),
                ("IP_FIXO_HOST", settings["host_ip"]),
            )
            if item[1]
        )
    return stage_one, stage_two


def _precondition(
    identifier: str,
    requires: str,
    evidence: str,
    subject: str,
    satisfied: bool,
    *,
    severity: str = "refuse",
    detail: str = "",
) -> dict:
    if severity not in SEVERITIES:
        raise InternalError("Severidade de precondição fora do vocabulário.")
    return {
        "detail": detail,
        "evidence": evidence,
        "id": identifier,
        "requires": requires,
        "satisfied": 1 if satisfied else 0,
        "severity": severity,
        "subject": subject,
    }


def _foreign_bridge_owner(facts: Mapping[str, Any]) -> str:
    """Rede de terceiros que já declara a bridge pretendida, com o estado.

    Espelha o laço de `validar_bridge_libvirt_disponivel`
    (`etapas/60-rede-bridge.sh:1357-1379`), que percorre as OUTRAS redes
    libvirt e recusa nomeando o estado do XML onde a bridge apareceu. A ordem é
    canônica: redes por nome e, dentro de cada uma, ativo antes de persistente,
    como o Bash monta `estados_xml`.
    """
    bridge = facts["nat_bridge"]
    for record in facts["foreign_networks"]:
        for state, key in (
            ("active", "active_bridge"),
            ("persistent", "persistent_bridge"),
        ):
            if record[key] == bridge:
                return "%s:%s" % (record["name"], state)
    return ""


def _consumer_facts(facts: Mapping[str, Any]) -> dict:
    """Relatório de consumidores (I7.4) sobre o snapshot já normalizado.

    Mesma pergunta de `listar_consumidores_rede_gerenciada`
    (`etapas/60-rede-bridge.sh:921`) e de `rede_nat_usada_por_outra_vm_ativa`
    (`etapas/60-rede-bridge.sh:1383`): consumo por nome de rede ou por uma das
    duas bridges (a atual da rede e a pretendida). A diferença entre as duas é
    o CONJUNTO, não a detecção, e é por isso que o relatório publica os dois.

    `consumers[]` do snapshot é, por construção do Bash, a listagem `virsh list
    --all --name` sem a VM alvo: estar na lista já é o bucket "definida". O
    bucket "ativa" sai do campo `active` de cada VM.
    """
    bridges = {facts["nat_bridge"]}
    if facts["current_bridge"]:
        bridges.add(facts["current_bridge"])
    context = _consumer_context(
        marker=facts["marker"],
        network_name=facts["network_name"],
        network_known=facts["network_exists"],
        network_owned=facts["owned"],
        bridges=bridges,
        networks=facts["foreign_networks"],
    )
    domains = [
        {
            "active": consumer["active"],
            "defined": True,
            "interfaces": consumer["interfaces"],
            "name": consumer["name"],
        }
        for consumer in facts["consumers_other"]
    ]
    records = _consumer_records(domains, "", context)
    return _consumer_summary(records, len(domains))


def _plan_preconditions(
    request: Mapping[str, Any], facts: Mapping[str, Any]
) -> list[dict]:
    intent = request["intent"]
    settings = request["settings"]
    snapshot = request["snapshot"]
    target = request["target"]
    mode = facts["mode"]
    links = facts["links"]
    network = snapshot["libvirt_network"]
    checks: list[dict] = []

    missing = sorted(set(REQUIRED_CAPABILITIES[mode]) - set(settings["capabilities"]))
    checks.append(
        _precondition(
            "P-CAPABILITIES-AVAILABLE",
            "required_capabilities_present",
            "settings.capabilities",
            "host-tooling",
            not missing,
            detail=",".join(missing),
        )
    )
    project = facts["project_artifact"]
    checks.append(
        _precondition(
            "P-CONFIGURATION-PRESENT",
            "project_configuration_artifact_exists",
            "snapshot.configuration",
            settings["configuration_identifier"],
            project is not None and project["exists"],
        )
    )
    checks.append(
        _precondition(
            "P-DOMAIN-DEFINED",
            "managed_domain_is_defined",
            "target.defined",
            target["name"],
            target["defined"],
        )
    )
    checks.append(
        _precondition(
            "P-DOMAIN-STOPPED",
            "managed_domain_is_not_running",
            "target.active",
            target["name"],
            not target["active"],
        )
    )
    checks.append(
        _precondition(
            "P-DOMAIN-NIC-UNIQUE",
            "exactly_one_interface_matches_persisted_mac",
            "target.nic_match_count",
            target["nic_mac"],
            target["nic_match_count"] == 1,
            detail=str(target["nic_match_count"]),
        )
    )
    checks.append(
        _precondition(
            "P-UPLINK-PRESENT",
            "intended_uplink_exists_in_capture",
            "snapshot.links",
            facts["uplink"],
            facts["uplink"] in links,
        )
    )
    if mode == "nat":
        effective = settings["uplink_effective"]
        checks.append(
            _precondition(
                "P-UPLINK-EFFECTIVE",
                "intended_uplink_carries_the_effective_ipv4_route",
                "settings.uplink_effective",
                facts["uplink"],
                bool(effective) and effective == facts["uplink"],
                detail=effective,
            )
        )
        master = links[facts["uplink"]]["master"] if facts["uplink"] in links else ""
        detail = ""
        if master:
            detail = (
                "host-bridge" if master == facts["host_bridge"] else "foreign-master"
            )
        checks.append(
            _precondition(
                "P-UPLINK-NOT-ENSLAVED",
                "intended_uplink_is_not_a_bridge_port",
                "snapshot.links[uplink].master",
                facts["uplink"],
                not master,
                detail=detail,
            )
        )
    # D-NET-UNMANAGED-BRIDGE: rede homônima sem o marcador deste projeto recusa
    # nos DOIS modos. O plano já modelava a recusa em I7.3; em I7.6 a etapa
    # parou de mascarar o fato na captura (declarava a rede alheia como slot
    # gerenciado ausente no modo bridge) e passou a consumir esta precondição
    # nos dois caminhos.
    if not network["exists"]:
        owned_detail = ""
    else:
        owned_detail = "owned" if facts["owned"] else "unmanaged"
    checks.append(
        _precondition(
            "P-LIBVIRT-NETWORK-OWNED",
            "homonymous_libvirt_network_carries_the_project_marker",
            "snapshot.libvirt_network.persistent_xml",
            facts["network_name"],
            (not network["exists"]) or facts["owned"],
            detail=owned_detail,
        )
    )
    if mode == "nat":
        bridge_link = facts["nat_bridge"] in links
        checks.append(
            _precondition(
                "P-LIBVIRT-BRIDGE-OWNED",
                "existing_libvirt_bridge_belongs_to_the_managed_network",
                "snapshot.links",
                facts["nat_bridge"],
                (not bridge_link)
                or (facts["owned"] and facts["current_bridge"] == facts["nat_bridge"]),
            )
        )
        # Só o conjunto ATIVO bloqueia o restart, como
        # `rede_nat_usada_por_outra_vm_ativa` (`etapas/60-rede-bridge.sh:1383`).
        blocking = (
            list(facts["consumer_summary"]["active_consumer_names"])
            if facts["needs_restart"]
            else []
        )
        checks.append(
            _precondition(
                "P-NETWORK-CONSUMERS-ABSENT",
                "no_other_running_domain_consumes_the_managed_network",
                "snapshot.consumers",
                facts["network_name"],
                not blocking,
                detail=",".join(blocking),
            )
        )
        owner = _foreign_bridge_owner(facts)
        checks.append(
            _precondition(
                "P-LIBVIRT-BRIDGE-UNIQUE",
                "no_other_libvirt_network_declares_the_intended_bridge",
                "snapshot.foreign_networks",
                facts["nat_bridge"],
                not owner,
                detail=owner,
            )
        )
        audit = facts["route_audit"]
        checks.append(
            _precondition(
                "P-ROUTE-COLLISION-FREE",
                "candidate_subnet_does_not_overlap_an_existing_route",
                "snapshot.routes",
                settings["nat_cidr"],
                audit["collision_count"] == 0,
                detail=audit["collision_first_destination"],
            )
        )
    else:
        # Aqui o conjunto é o DEFINIDO (`virsh list --all`), ativo ou não, como
        # `listar_consumidores_rede_gerenciada` (`etapas/60-rede-bridge.sh:921`).
        blocking = (
            list(facts["consumer_summary"]["defined_consumer_names"])
            if network["exists"] and facts["owned"]
            else []
        )
        checks.append(
            _precondition(
                "P-NETWORK-CONSUMERS-ABSENT",
                "no_other_defined_domain_consumes_the_managed_network",
                "snapshot.consumers",
                facts["network_name"],
                not blocking,
                detail=",".join(blocking),
            )
        )
        wireless = facts["uplink"] in links and links[facts["uplink"]]["wireless"]
        checks.append(
            _precondition(
                "P-UPLINK-NOT-WIRELESS",
                "intended_uplink_is_not_a_wireless_station",
                "snapshot.links[uplink].wireless",
                facts["uplink"],
                facts["uplink"] in links and not wireless,
                detail=(
                    "wireless"
                    if wireless
                    else ("" if facts["uplink"] in links else "absent")
                ),
            )
        )
        desired = facts["profile_desired"]
        checks.append(
            _precondition(
                "P-HOST-PROFILE-DECLARED",
                "intent_declares_the_host_network_profile_artifact",
                "intent.configuration",
                settings["host_profile"]["identifier"],
                desired is not None and desired["exists"] and bool(desired["content"]),
            )
        )
        checks.append(
            _precondition(
                "P-BRIDGE-MEMBER-DECLARED",
                "intended_bridge_declares_the_uplink_as_its_only_port",
                "intent.bridge.ports",
                facts["host_bridge"],
                intent["bridge"]["exists"]
                and intent["bridge"]["ports"] == [facts["uplink"]],
            )
        )
    return checks


def _text_digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _scalar_arguments(arguments: Mapping[str, Any], label: str) -> dict:
    result: dict[str, Any] = {}
    for key in sorted(arguments):
        value = arguments[key]
        if not isinstance(key, str) or not key.replace("_", "").isalnum():
            raise InternalError("Argumento com nome inválido em %s." % label)
        if isinstance(value, bool):
            value = 1 if value else 0
        if not isinstance(value, (str, int)):
            raise InternalError(
                "O plano só transporta argumentos escalares (%s)." % label
            )
        result[key] = value
    return result


def _plan_operations(request: Mapping[str, Any], facts: Mapping[str, Any]):
    snapshot = request["snapshot"]
    settings = request["settings"]
    target = request["target"]
    network = snapshot["libvirt_network"]
    mode = facts["mode"]
    values = facts["project_values"]
    operations: list[dict] = []
    postconditions: list[dict] = []

    def emit(
        verb: str,
        resource_type: str,
        resource: str,
        arguments: Mapping[str, Any],
        *,
        converged: bool,
        revalidate: Iterable[str],
        proofs: Iterable[tuple],
    ) -> None:
        if verb not in PLAN_VERBS:
            raise InternalError("Verbo fora do vocabulário do plano: %s." % verb)
        if resource_type not in PLAN_RESOURCE_TYPES:
            raise InternalError("Recurso fora do vocabulário do plano.")
        index = len(operations) + 1
        identifier = "OP-%02d-%s" % (index, verb.upper().replace("-", "_"))
        components = sorted(set(revalidate))
        for component in components:
            if component not in REVALIDATION_COMPONENTS:
                raise InternalError("Componente de revalidação desconhecido.")
        proof_ids: list[str] = []
        for kind, requires, evidence, subject in proofs:
            proof_id = "PC-OP-%02d-%s" % (index, kind)
            proof_ids.append(proof_id)
            postconditions.append(
                {
                    "evidence": evidence,
                    "id": proof_id,
                    "requires": requires,
                    "scope": "operation",
                    "step": identifier,
                    "subject": subject,
                }
            )
        operations.append(
            {
                "arguments": _scalar_arguments(arguments, identifier),
                "converged": 1 if converged else 0,
                "id": identifier,
                "index": index,
                "mutating": 0 if converged else 1,
                "postconditions": proof_ids,
                "resource": resource,
                "resource_type": resource_type,
                "revalidate": components,
                "undo": [],
                "verb": verb,
            }
        )

    def publish(key: str, value: str) -> None:
        emit(
            "configuration-publish",
            "project-configuration",
            settings["configuration_identifier"],
            {"key": key, "value": value},
            converged=key in values and values[key] == value,
            revalidate=["configuration"],
            proofs=[
                (
                    "CONFIGURATION-VALUE",
                    "configuration_key_holds_intended_value",
                    "configuration.values",
                    key,
                )
            ],
        )

    stage_one, stage_two = _configuration_targets(request, facts)
    for key, value in stage_one:
        publish(key, value)

    state = {
        "active": network["active"],
        "autostart": network["autostart"],
        "exists": network["exists"],
        "persistent": network["persistent"],
    }
    if mode == "nat":
        addresses = facts["addresses"]
        definition = {
            "bridge": facts["nat_bridge"],
            "bridge_delay": 0,
            "bridge_stp": 1,
            "dhcp_end": addresses["nat_dhcp_fim"],
            "dhcp_start": addresses["nat_dhcp_inicio"],
            "family": "ipv4",
            "forward_device": facts["uplink"],
            "forward_mode": "nat",
            "forward_port_end": NAT_PORT_END,
            "forward_port_start": NAT_PORT_START,
            "gateway": addresses["nat_gateway"],
            "marker": settings["marker"],
            "name": facts["network_name"],
            "netmask": NAT_NETMASK,
            "prefix": addresses["nat_prefix"],
            "reservation_ip": addresses["nat_vm_ip"],
            "reservation_mac": target["nic_mac"],
            "uuid": facts["current_uuid"],
        }
        if facts["needs_define"]:
            if state["exists"] and not state["persistent"] and state["active"]:
                # Instância transitória ativa precisa desaparecer antes de
                # ganhar definição persistente (`etapas/60-rede-bridge.sh:1508-1512`).
                emit(
                    "network-deactivate",
                    "libvirt-network",
                    facts["network_name"],
                    {"reason": "transient-instance-blocks-definition"},
                    converged=False,
                    revalidate=["consumers", "libvirt_network"],
                    proofs=[
                        (
                            "NETWORK-INACTIVE",
                            "managed_network_is_not_running",
                            "libvirt_network.active",
                            facts["network_name"],
                        )
                    ],
                )
                state["active"] = False
                state["exists"] = False
            emit(
                "network-define",
                "libvirt-network",
                facts["network_name"],
                definition,
                converged=False,
                revalidate=["libvirt_network"],
                proofs=[
                    (
                        "NETWORK-PERSISTENT",
                        "persistent_definition_matches_the_intended_nat_topology",
                        "libvirt_network.persistent_xml",
                        facts["network_name"],
                    )
                ],
            )
            state["exists"] = True
            state["persistent"] = True
        if (
            network["active"]
            and (facts["needs_define"] or not facts["active_matches"])
            and state["active"]
        ):
            emit(
                "network-deactivate",
                "libvirt-network",
                facts["network_name"],
                {"reason": "backend-restart"},
                converged=False,
                revalidate=["consumers", "libvirt_network"],
                proofs=[
                    (
                        "NETWORK-INACTIVE",
                        "managed_network_is_not_running",
                        "libvirt_network.active",
                        facts["network_name"],
                    )
                ],
            )
            state["active"] = False
        if not state["active"]:
            emit(
                "network-activate",
                "libvirt-network",
                facts["network_name"],
                {"bridge": facts["nat_bridge"]},
                converged=False,
                revalidate=["libvirt_network"],
                proofs=[
                    (
                        "NETWORK-ACTIVE",
                        "active_backend_matches_the_persistent_definition",
                        "libvirt_network.active_xml",
                        facts["network_name"],
                    )
                ],
            )
            state["active"] = True
        if not state["autostart"]:
            emit(
                "network-autostart-enable",
                "libvirt-network",
                facts["network_name"],
                {"enabled": 1},
                converged=False,
                revalidate=["libvirt_network"],
                proofs=[
                    (
                        "NETWORK-AUTOSTART",
                        "managed_network_starts_with_the_host",
                        "libvirt_network.autostart",
                        facts["network_name"],
                    )
                ],
            )
            state["autostart"] = True
    else:
        profile = settings["host_profile"]
        desired = facts["profile_desired"]
        current = facts["profile_current"]
        if network["exists"] and facts["owned"]:
            if state["autostart"]:
                emit(
                    "network-autostart-disable",
                    "libvirt-network",
                    facts["network_name"],
                    {"enabled": 0},
                    converged=False,
                    revalidate=["libvirt_network"],
                    proofs=[
                        (
                            "NETWORK-AUTOSTART-OFF",
                            "managed_network_does_not_start_with_the_host",
                            "libvirt_network.autostart",
                            facts["network_name"],
                        )
                    ],
                )
                state["autostart"] = False
            if state["active"]:
                emit(
                    "network-deactivate",
                    "libvirt-network",
                    facts["network_name"],
                    {"reason": "host-bridge-migration"},
                    converged=False,
                    revalidate=["consumers", "libvirt_network"],
                    proofs=[
                        (
                            "NETWORK-INACTIVE",
                            "managed_network_is_not_running",
                            "libvirt_network.active",
                            facts["network_name"],
                        )
                    ],
                )
                state["active"] = False
        if facts["needs_apply"]:
            if current is not None and current["exists"]:
                emit(
                    "host-profile-archive",
                    "host-network-profile",
                    profile["identifier"],
                    {
                        "content_sha256": _text_digest(current["content"]),
                        "mode": current["mode"],
                        "scope": profile["scope"],
                    },
                    converged=False,
                    revalidate=["configuration"],
                    proofs=[
                        (
                            "PROFILE-ARCHIVED",
                            "archived_copy_matches_the_previous_artifact",
                            "configuration.content",
                            profile["identifier"],
                        )
                    ],
                )
            if not facts["profile_content_equal"]:
                emit(
                    "host-profile-store",
                    "host-network-profile",
                    profile["identifier"],
                    {
                        "bridge": facts["host_bridge"],
                        "content": desired["content"],
                        "content_sha256": _text_digest(desired["content"]),
                        "dhcp4": profile["dhcp4"],
                        "family": "ipv4",
                        "forward_delay": profile["forward_delay"],
                        "member": facts["uplink"],
                        "member_dhcp4": profile["member_dhcp4"],
                        "member_dhcp6": profile["member_dhcp6"],
                        "mode": desired["mode"],
                        "scope": profile["scope"],
                        "stp": profile["stp"],
                    },
                    converged=False,
                    revalidate=["configuration"],
                    proofs=[
                        (
                            "PROFILE-CONTENT",
                            "stored_artifact_matches_the_intended_content",
                            "configuration.content",
                            profile["identifier"],
                        ),
                        (
                            "PROFILE-MODE",
                            "stored_artifact_keeps_the_intended_mode",
                            "configuration.mode",
                            profile["identifier"],
                        ),
                    ],
                )
            emit(
                "host-network-activate-reversible",
                "host-network-profile",
                profile["identifier"],
                {
                    "bridge": facts["host_bridge"],
                    "member": facts["uplink"],
                    "revert_without_confirmation": 1,
                },
                converged=False,
                revalidate=["links", "routes"],
                proofs=[
                    (
                        "PROFILE-REVERSIBLE",
                        "operator_confirmed_the_reversible_activation",
                        "links",
                        facts["host_bridge"],
                    )
                ],
            )
            emit(
                "host-network-activate",
                "host-network-profile",
                profile["identifier"],
                {"bridge": facts["host_bridge"], "member": facts["uplink"]},
                converged=False,
                revalidate=["links", "routes"],
                proofs=[
                    (
                        "BRIDGE-RUNTIME",
                        "bridge_is_up_and_owns_the_uplink_as_a_port",
                        "links",
                        facts["host_bridge"],
                    )
                ],
            )

    if not facts["domain_converged"]:
        emit(
            "domain-redefine",
            "domain",
            target["name"],
            {
                "nic_mac": target["nic_mac"],
                "source": facts["desired_source"],
                "source_type": facts["desired_source_type"],
            },
            converged=False,
            revalidate=["target"],
            proofs=[
                (
                    "DOMAIN-NIC-SOURCE",
                    "interface_with_the_persisted_mac_points_to_the_intended_source",
                    "target.nic_source",
                    target["nic_mac"],
                )
            ],
        )

    for key, value in stage_two:
        publish(key, value)

    touched = {item["resource_type"] for item in operations}
    return operations, postconditions, touched, state


def _plan_rollback(
    request: Mapping[str, Any],
    facts: Mapping[str, Any],
    touched: Iterable[str],
    state: Mapping[str, Any],
):
    """Sequência inversa explícita, na ordem que `executar_rollback`
    (`etapas/60-rede-bridge.sh:385`) já executa: perfil de rede do host, rede
    libvirt, domínio e configuração do projeto.

    O plano é estático, então a restauração é dimensionada pelo pior caso: o
    conjunto de recursos que o plano inteiro tocaria. É exatamente a situação
    que o oráculo I0 congela ao sinalizar depois da última operação mutante.

    D-NET-ROLLBACK-DIVERGE: cada passo carrega a própria prova e
    `on_divergence=fatal`. Nenhum passo aceita o código de retorno da
    ferramenta como evidência, nem mesmo a restauração do domínio, que hoje
    confia no rc (`etapas/60-rede-bridge.sh:365-371`).
    """
    snapshot = request["snapshot"]
    settings = request["settings"]
    target = request["target"]
    network = snapshot["libvirt_network"]
    touched = set(touched)
    steps: list[dict] = []
    postconditions: list[dict] = []

    def emit(
        verb: str,
        resource_type: str,
        resource: str,
        arguments: Mapping[str, Any],
        *,
        revalidate: Iterable[str],
        proofs: Iterable[tuple],
    ) -> None:
        if verb not in PLAN_VERBS:
            raise InternalError("Verbo fora do vocabulário do plano: %s." % verb)
        index = len(steps) + 1
        identifier = "RB-%02d-%s" % (index, verb.upper().replace("-", "_"))
        components = sorted(set(revalidate))
        for component in components:
            if component not in REVALIDATION_COMPONENTS:
                raise InternalError("Componente de revalidação desconhecido.")
        proof_ids: list[str] = []
        for kind, requires, evidence, subject in proofs:
            proof_id = "PC-RB-%02d-%s" % (index, kind)
            proof_ids.append(proof_id)
            postconditions.append(
                {
                    "evidence": evidence,
                    "id": proof_id,
                    "requires": requires,
                    "scope": "rollback",
                    "step": identifier,
                    "subject": subject,
                }
            )
        steps.append(
            {
                "arguments": _scalar_arguments(arguments, identifier),
                "id": identifier,
                "index": index,
                "on_divergence": "fatal",
                "postconditions": proof_ids,
                "resource": resource,
                "resource_type": resource_type,
                "revalidate": components,
                "verb": verb,
            }
        )

    profile = settings["host_profile"]
    if "host-network-profile" in touched:
        current = facts["profile_current"]
        if current is not None and current["exists"]:
            emit(
                "host-profile-restore",
                "host-network-profile",
                profile["identifier"],
                {
                    "content_sha256": _text_digest(current["content"]),
                    "mode": current["mode"],
                    "scope": profile["scope"],
                },
                revalidate=["configuration"],
                proofs=[
                    (
                        "PROFILE-DIGEST",
                        "restored_artifact_digest_equals_the_captured_digest",
                        "configuration.content",
                        profile["identifier"],
                    ),
                    (
                        "PROFILE-RENDERABLE",
                        "restored_profile_is_renderable_before_activation",
                        "configuration.content",
                        profile["identifier"],
                    ),
                ],
            )
        else:
            emit(
                "host-profile-discard",
                "host-network-profile",
                profile["identifier"],
                {"scope": profile["scope"]},
                revalidate=["configuration"],
                proofs=[
                    (
                        "PROFILE-ABSENT",
                        "partial_artifact_no_longer_exists",
                        "configuration",
                        profile["identifier"],
                    ),
                    (
                        "PROFILE-RENDERABLE",
                        "remaining_profiles_are_renderable_before_activation",
                        "configuration",
                        profile["identifier"],
                    ),
                ],
            )
        emit(
            "host-network-activate",
            "host-network-profile",
            profile["identifier"],
            {"member": facts["uplink"], "restore": 1},
            revalidate=["links", "routes"],
            proofs=[
                (
                    "LINK-TOPOLOGY",
                    "link_topology_equals_the_captured_topology",
                    "links",
                    facts["uplink"],
                )
            ],
        )

    if "libvirt-network" in touched:
        if state["active"]:
            emit(
                "network-deactivate",
                "libvirt-network",
                facts["network_name"],
                {"reason": "rollback"},
                revalidate=["libvirt_network"],
                proofs=[
                    (
                        "NETWORK-INACTIVE",
                        "managed_network_is_not_running",
                        "libvirt_network.active",
                        facts["network_name"],
                    )
                ],
            )
        if state["persistent"]:
            emit(
                "network-undefine",
                "libvirt-network",
                facts["network_name"],
                {"reason": "rollback"},
                revalidate=["libvirt_network"],
                proofs=[
                    (
                        "NETWORK-UNDEFINED",
                        "definition_created_by_this_run_no_longer_exists",
                        "libvirt_network.persistent",
                        facts["network_name"],
                    )
                ],
            )
        if network["exists"]:
            if network["persistent"]:
                if network["active"]:
                    emit(
                        "network-recreate",
                        "libvirt-network",
                        facts["network_name"],
                        {"from": "captured-active-definition"},
                        revalidate=["libvirt_network"],
                        proofs=[
                            (
                                "NETWORK-ACTIVE-CAPTURE",
                                "running_backend_equals_the_captured_active_definition",
                                "libvirt_network.active_xml",
                                facts["network_name"],
                            )
                        ],
                    )
                emit(
                    "network-redefine",
                    "libvirt-network",
                    facts["network_name"],
                    {"from": "captured-persistent-definition"},
                    revalidate=["libvirt_network"],
                    proofs=[
                        (
                            "NETWORK-PERSISTENT-CAPTURE",
                            "persistent_definition_equals_the_captured_definition",
                            "libvirt_network.persistent_xml",
                            facts["network_name"],
                        )
                    ],
                )
                emit(
                    "network-autostart-enable"
                    if network["autostart"]
                    else "network-autostart-disable",
                    "libvirt-network",
                    facts["network_name"],
                    {"enabled": 1 if network["autostart"] else 0},
                    revalidate=["libvirt_network"],
                    proofs=[
                        (
                            "NETWORK-AUTOSTART-CAPTURE",
                            "autostart_equals_the_captured_value",
                            "libvirt_network.autostart",
                            facts["network_name"],
                        )
                    ],
                )
            elif network["active"]:
                emit(
                    "network-recreate",
                    "libvirt-network",
                    facts["network_name"],
                    {"from": "captured-active-definition"},
                    revalidate=["libvirt_network"],
                    proofs=[
                        (
                            "NETWORK-ACTIVE-CAPTURE",
                            "transient_instance_equals_the_captured_definition",
                            "libvirt_network.active_xml",
                            facts["network_name"],
                        )
                    ],
                )
        # Revalidação das quatro flags depois da restauração inteira
        # (`etapas/60-rede-bridge.sh:347-362`).
        if not steps:
            raise InternalError(
                "Plano tocou a rede libvirt sem produzir passo de restauração."
            )
        last = steps[-1]
        proof_id = "PC-RB-%02d-NETWORK-STATE" % last["index"]
        last["postconditions"] = list(last["postconditions"]) + [proof_id]
        postconditions.append(
            {
                "evidence": "libvirt_network",
                "id": proof_id,
                "requires": NETWORK_STATE_PROOF,
                "scope": "rollback",
                "step": last["id"],
                "subject": facts["network_name"],
            }
        )

    if "domain" in touched:
        emit(
            "domain-restore",
            "domain",
            target["name"],
            {"from": "captured-inactive-definition"},
            revalidate=["target"],
            proofs=[
                (
                    "DOMAIN-FINGERPRINT",
                    "restored_definition_fingerprint_equals_the_captured_fingerprint",
                    "target.xml",
                    target["name"],
                )
            ],
        )

    if "project-configuration" in touched:
        project = facts["project_artifact"]
        if project is None or not project["exists"]:
            # `P-CONFIGURATION-PRESENT` já recusou o plano nesse caso, então
            # chegar aqui seria plano inconsistente, não configuração criada
            # pela metade.
            raise InternalError(
                "Plano publicou configuração sem artefato capturado."
            )
        emit(
            "configuration-restore",
            "project-configuration",
            settings["configuration_identifier"],
            {
                "content_sha256": _text_digest(project["content"]),
                "mode": project["mode"],
                "scope": PROJECT_SCOPE,
            },
            revalidate=["configuration"],
            proofs=[
                (
                    "CONFIGURATION-DIGEST",
                    "restored_configuration_digest_equals_the_captured_digest",
                    "configuration.content",
                    settings["configuration_identifier"],
                )
            ],
        )
    return steps, postconditions


def _plan_postconditions(
    request: Mapping[str, Any], facts: Mapping[str, Any]
) -> list[dict]:
    """Provas do plano inteiro, além das de cada operação."""
    settings = request["settings"]
    target = request["target"]
    entries: list[tuple] = []
    if facts["mode"] == "nat":
        addresses = facts["addresses"]
        entries.extend(
            (
                (
                    "NETWORK-PERSISTENT",
                    "persistent_definition_matches_the_intended_nat_topology",
                    "libvirt_network.persistent_xml",
                    facts["network_name"],
                ),
                (
                    "NETWORK-ACTIVE",
                    "active_backend_matches_the_persistent_definition",
                    "libvirt_network.active_xml",
                    facts["network_name"],
                ),
                (
                    "NETWORK-AUTOSTART",
                    "managed_network_starts_with_the_host",
                    "libvirt_network.autostart",
                    facts["network_name"],
                ),
                (
                    "ADDRESS-PAIR",
                    "host_and_domain_addresses_share_the_effective_prefix",
                    "links",
                    "%s %s %s"
                    % (
                        facts["nat_bridge"],
                        addresses["nat_vm_ip"],
                        addresses["nat_gateway"],
                    ),
                ),
            )
        )
    else:
        entries.append(
            (
                "BRIDGE-RUNTIME",
                "bridge_is_up_and_owns_the_uplink_as_a_port",
                "links",
                facts["host_bridge"],
            )
        )
        if settings["vm_ip"] and settings["host_ip"]:
            entries.append(
                (
                    "ADDRESS-PAIR",
                    "host_and_domain_addresses_share_the_effective_prefix",
                    "links",
                    "%s %s %s"
                    % (facts["host_bridge"], settings["vm_ip"], settings["host_ip"]),
                )
            )
    entries.append(
        (
            "DOMAIN-NIC-SOURCE",
            "interface_with_the_persisted_mac_points_to_the_intended_source",
            "target.nic_source",
            target["nic_mac"],
        )
    )
    entries.append(
        (
            "CONFIGURATION-CONVERGED",
            "every_published_key_holds_the_intended_value",
            "configuration.values",
            settings["configuration_identifier"],
        )
    )
    return [
        {
            "evidence": evidence,
            "id": "PC-PLAN-%s" % kind,
            "requires": requires,
            "scope": "plan",
            "step": "",
            "subject": subject,
        }
        for kind, requires, evidence, subject in entries
    ]


def build_plan(payload: Mapping[str, Any]) -> dict:
    """Devolve o plano determinístico de rede a partir de snapshot e intenção.

    O plano é fechado, ordenado e não depende de hora, aleatoriedade, ordem de
    dicionário ou ambiente: a mesma entrada produz o mesmo documento byte a
    byte. Quando uma precondição de recusa falha, o plano não traz operação,
    pós-condição nem rollback: recusa é fail-closed, não plano parcial.
    """
    request = normalize_plan_request(payload)
    facts = _plan_facts(request)
    preconditions = _plan_preconditions(request, facts)
    blocking = ""
    failed = 0
    for check in preconditions:
        if check["satisfied"]:
            continue
        failed += 1
        if check["severity"] == "refuse" and not blocking:
            blocking = check["id"]
    operations: list[dict] = []
    postconditions: list[dict] = []
    rollback: list[dict] = []
    if not blocking:
        operations, operation_proofs, touched, state = _plan_operations(
            request, facts
        )
        rollback, rollback_proofs = _plan_rollback(request, facts, touched, state)
        undo: dict[str, list[str]] = {}
        for step in rollback:
            undo.setdefault(step["resource_type"], []).append(step["id"])
        for operation in operations:
            operation["undo"] = list(undo.get(operation["resource_type"], []))
        postconditions = (
            operation_proofs
            + _plan_postconditions(request, facts)
            + rollback_proofs
        )
    target = dict(request["target"])
    target["xml"] = _xml_fingerprint(
        target["xml"], "domain", target["name"], "XML da VM alvo"
    )
    mutating = sum(item["mutating"] for item in operations)
    return {
        "family": "ipv4",
        "fingerprints": {
            "intent": _fingerprints(request["intent"]),
            "snapshot": _fingerprints(request["snapshot"]),
            "target": _digest(target),
        },
        "mode": facts["mode"],
        "operations": operations,
        "postconditions": postconditions,
        "preconditions": preconditions,
        "rollback": rollback,
        "schema_version": PLAN_SCHEMA_VERSION,
        "summary": {
            "accepted": 0 if blocking else 1,
            "blocking_precondition": blocking,
            "converged_count": len(operations) - mutating,
            "failed_precondition_count": failed,
            "mutating_count": mutating,
            "operation_count": len(operations),
            "postcondition_count": len(postconditions),
            "precondition_count": len(preconditions),
            "rollback_count": len(rollback),
        },
    }


def network_plan(payload: Mapping[str, Any]) -> dict:
    """Projeta o plano no canal escalar da ponte, como `network-route-audit`.

    O canal de pares só transporta escalares, então o documento estruturado é
    achatado com índices estáveis. `plan_sha256` prende a projeção ao plano
    inteiro: I7.5 pode comparar o digest antes de executar qualquer verbo.
    """
    plan = build_plan(payload)
    summary = plan["summary"]
    fingerprints = plan["fingerprints"]
    data: dict[str, Any] = {
        "accepted": summary["accepted"],
        "blocking_precondition": summary["blocking_precondition"],
        "converged_count": summary["converged_count"],
        "failed_precondition_count": summary["failed_precondition_count"],
        "family": plan["family"],
        "fingerprint_intent_exact": fingerprints["intent"]["exact"],
        "fingerprint_intent_semantic": fingerprints["intent"]["semantic"],
        "fingerprint_snapshot_exact": fingerprints["snapshot"]["exact"],
        "fingerprint_snapshot_semantic": fingerprints["snapshot"]["semantic"],
        "fingerprint_target": fingerprints["target"],
        "mode": plan["mode"],
        "mutating_count": summary["mutating_count"],
        "operation_count": summary["operation_count"],
        "plan_sha256": _digest(plan),
        "postcondition_count": summary["postcondition_count"],
        "precondition_count": summary["precondition_count"],
        "rollback_count": summary["rollback_count"],
        "schema_version": plan["schema_version"],
    }
    for field in STATE_FIELDS:
        data["fingerprint_component_%s" % field] = fingerprints["snapshot"][
            "components"
        ][field]
    for index, check in enumerate(plan["preconditions"]):
        prefix = "precondition_%d_" % index
        data[prefix + "detail"] = check["detail"]
        data[prefix + "evidence"] = check["evidence"]
        data[prefix + "id"] = check["id"]
        data[prefix + "requires"] = check["requires"]
        data[prefix + "satisfied"] = check["satisfied"]
        data[prefix + "severity"] = check["severity"]
        data[prefix + "subject"] = check["subject"]
    for index, operation in enumerate(plan["operations"]):
        prefix = "operation_%d_" % index
        data[prefix + "arguments"] = "\n".join(sorted(operation["arguments"]))
        data[prefix + "converged"] = operation["converged"]
        data[prefix + "id"] = operation["id"]
        data[prefix + "mutating"] = operation["mutating"]
        data[prefix + "postconditions"] = "\n".join(operation["postconditions"])
        data[prefix + "resource"] = operation["resource"]
        data[prefix + "resource_type"] = operation["resource_type"]
        data[prefix + "revalidate"] = "\n".join(operation["revalidate"])
        data[prefix + "undo"] = "\n".join(operation["undo"])
        data[prefix + "verb"] = operation["verb"]
        for name, value in operation["arguments"].items():
            data[prefix + "argument_" + name] = value
    for index, step in enumerate(plan["rollback"]):
        prefix = "rollback_%d_" % index
        data[prefix + "arguments"] = "\n".join(sorted(step["arguments"]))
        data[prefix + "id"] = step["id"]
        data[prefix + "on_divergence"] = step["on_divergence"]
        data[prefix + "postconditions"] = "\n".join(step["postconditions"])
        data[prefix + "resource"] = step["resource"]
        data[prefix + "resource_type"] = step["resource_type"]
        data[prefix + "revalidate"] = "\n".join(step["revalidate"])
        data[prefix + "verb"] = step["verb"]
        for name, value in step["arguments"].items():
            data[prefix + "argument_" + name] = value
    for index, proof in enumerate(plan["postconditions"]):
        prefix = "postcondition_%d_" % index
        data[prefix + "evidence"] = proof["evidence"]
        data[prefix + "id"] = proof["id"]
        data[prefix + "requires"] = proof["requires"]
        data[prefix + "scope"] = proof["scope"]
        data[prefix + "step"] = proof["step"]
        data[prefix + "subject"] = proof["subject"]
    data["operation_ids"] = "\n".join(
        item["id"] for item in plan["operations"]
    )
    data["rollback_ids"] = "\n".join(item["id"] for item in plan["rollback"])
    return data


# --- I7.5: adaptador do canal de pares para o schema fechado ------------------
# O Bash não constrói JSON (seção 3.8) e o canal `chave\0valor\0` decodifica
# para `dict[str, str]` (`protocol.decode_request_pairs`). Este adaptador é a
# única ponte entre aquele mapa plano e as estruturas aninhadas que
# `normalize_snapshot`, `normalize_plan_request`, `normalize_consumer_request`
# e `route_audit` exigem. Ele MONTA a estrutura e entrega; nenhum normalizador
# foi afrouxado para acomodar o transporte, e o schema fechado continua sendo
# a autoridade sobre o que é válido.
#
# Existem exatamente três formas de valor no canal:
#
# * escalar  -> par simples, sem caractere de controle algum (nem `\t`, nem
#               `\n`, nem `\r`, nem DEL);
# * coleção  -> UM par, registros separados por `\n` e campos separados por
#               `\t`, em ordem fixa (as tuplas `PAIRS_*_FIELDS` abaixo);
# * blob     -> par próprio com chave indexada. XML e conteúdo de arquivo de
#               configuração contêm `\t` e `\n` por natureza e por isso NUNCA
#               entram em registro.
#
# Dentro de um registro, uma sub-lista de escalares (`links.flags`,
# `links.addresses`) é separada por `,`; uma lista de escalares que já tem par
# próprio (`bridge_ports`, `settings_capabilities`, `bridges`) é separada por
# `\n`. Item vazio é recusado pelo normalizador, então `a,,b` e `a\n\nb` são
# erro tipado, nunca item silencioso.
#
# O índice de um blob é a posição do registro na coleção DECLARADA, antes de
# qualquer ordenação do normalizador. Os índices precisam ser contíguos e
# começar em zero: índice ausente vira "par obrigatório ausente" e índice extra
# vira "par fora do schema fechado".
#
# Orçamento de pares (`protocol.MAX_REQUEST_PAIRS`, 256): um pedido de plano
# gasta 65 pares fixos (20 do snapshot, 21 da intenção, 8 do alvo, 15 dos
# ajustes e 1 da versão do schema) mais 2 por VM consumidora de cada estado
# (o XML e as interfaces) e 1 por artefato de configuração de cada estado. Com
# os 1 a 2 artefatos reais do projeto isso cabe em 256 até 46 VMs consumidoras,
# ordens de grandeza acima de um host de passthrough. Por isso
# `MAX_REQUEST_PAIRS` continua em 256, e o teste do orçamento prende os 67/68
# pares dos pedidos reais para que a conta não possa envelhecer em silêncio.

PAIRS_RECORD_SEPARATOR = "\n"
PAIRS_FIELD_SEPARATOR = "\t"
PAIRS_ITEM_SEPARATOR = ","

# Ordem fixa dos campos de cada registro. O Bash precisa produzir exatamente
# esta ordem; contagem diferente é erro tipado, nunca campo adivinhado.
PAIRS_ROUTE_FIELDS = (
    "destination",
    "device",
    "gateway",
    "metric",
    "protocol",
    "scope",
    "source",
    "table",
    "type",
)
PAIRS_LINK_FIELDS = (
    "addresses",
    "flags",
    "kind",
    "mac",
    "master",
    "mtu",
    "name",
    "operstate",
    "wireless",
)
PAIRS_NETWORK_RECORD_FIELDS = (
    "active",
    "active_bridge",
    "marker",
    "name",
    "persistent",
    "persistent_bridge",
)
PAIRS_CONSUMER_FIELDS = ("active", "name")
PAIRS_INTERFACE_FIELDS = ("mac", "source", "source_type")
PAIRS_CONFIGURATION_FIELDS = (
    "device",
    "exists",
    "file_type",
    "gid",
    "identifier",
    "inode",
    "mode",
    "mtime_ns",
    "nlink",
    "scope",
    "size",
    "uid",
)
PAIRS_DOMAIN_FIELDS = ("active", "defined", "name")

# Domínio de um escalar do canal: nenhum caractere de controle. `\t` e `\n`
# são separadores estruturais, `\r` esconderia diferença invisível num digest
# e DEL não pertence a nome, MAC, endereço ou enumeração alguma.
_PAIRS_CONTROL = frozenset(chr(code) for code in range(32)) | {"\x7f"}
# Inteiro decimal sem zero à esquerda: `mtime_ns` chega a 19 dígitos e `mode`
# viaja em DECIMAL, não em octal (o Bash converte com `$(( 8#$octal ))`).
_PAIRS_INTEGER = re.compile(r"^(?:0|[1-9][0-9]{0,18})$")
_PAIRS_DIGEST = re.compile(r"^[0-9a-f]{64}$")


def _pairs_payload(value: Any, label: str) -> dict | None:
    """Devolve o mapa plano quando a chamada veio do canal de pares.

    A discriminação é total e não depende de marcador algum: o canal de pares
    decodifica para `dict[str, str]`, logo NENHUM valor dele é objeto ou lista;
    todo pedido aninhado destes subcomandos, ao contrário, carrega pelo menos
    um objeto ou uma lista obrigatória no schema fechado. Não existe payload
    que satisfaça as duas formas, então nenhuma das duas precisa ser afrouxada.
    """
    payload = _mapping(value, label)
    if any(isinstance(item, (Mapping, list)) for item in payload.values()):
        return None
    for key, item in payload.items():
        if not isinstance(item, str):
            raise DataError(
                "%s: o canal de pares só transporta texto; %s não é texto."
                % (label, safe_label(key))
            )
    return dict(payload)


def _pairs_scalar(value: str, label: str) -> str:
    for character in value:
        if character in _PAIRS_CONTROL:
            raise DataError(
                "%s contém caractere de controle no canal de pares." % label
            )
    return value


def _pairs_take(source: dict, key: str, label: str) -> str:
    if key not in source:
        raise DataError(
            "%s: par obrigatório ausente no canal de pares: %s."
            % (label, safe_label(key))
        )
    return source.pop(key)


def _pairs_text(source: dict, key: str, label: str) -> str:
    # O diagnóstico cita a CHAVE do par, que é o que o produtor Bash escreve,
    # e não um caminho de schema que ele não conhece.
    return _pairs_scalar(_pairs_take(source, key, label), key)


def _pairs_flag(value: str, label: str) -> bool:
    if value == "1":
        return True
    if value == "0":
        return False
    raise DataError("%s precisa ser 0 ou 1 no canal de pares." % label)


def _pairs_integer(
    value: str, label: str, *, allow_none: bool = False
) -> int | None:
    if not value:
        if allow_none:
            return None
        raise DataError(
            "%s precisa ser inteiro decimal no canal de pares." % label
        )
    if _PAIRS_INTEGER.fullmatch(value) is None:
        raise DataError(
            "%s precisa ser inteiro decimal sem zero à esquerda no canal de "
            "pares." % label
        )
    return int(value)


def _pairs_digest(value: str, label: str) -> str:
    if _PAIRS_DIGEST.fullmatch(value) is None:
        raise DataError("%s precisa ser um SHA-256 em minúsculas." % label)
    return value


def _pairs_items(value: str, label: str) -> list[str]:
    """Sub-lista de escalares dentro de um registro, separada por vírgula."""
    if not value:
        return []
    return value.split(PAIRS_ITEM_SEPARATOR)


def _pairs_lines(
    value: str, label: str, limit: int = MAX_LIST_ITEMS
) -> list[str]:
    """Lista de escalares em par próprio, separada por nova linha."""
    if not value:
        return []
    items = value.split(PAIRS_RECORD_SEPARATOR)
    if len(items) > limit:
        raise DataError("%s excede o limite de %d itens." % (label, limit))
    for index, item in enumerate(items):
        _pairs_scalar(item, "%s[%d]" % (label, index))
    return items


def _pairs_records(
    value: str, fields: tuple, label: str, limit: int
) -> list[dict]:
    """Registros de uma coleção: `\\n` entre registros, `\\t` entre campos."""
    if not value:
        return []
    lines = value.split(PAIRS_RECORD_SEPARATOR)
    if len(lines) > limit:
        raise DataError("%s excede o limite de %d registros." % (label, limit))
    records: list[dict] = []
    for index, line in enumerate(lines):
        item_label = "%s[%d]" % (label, index)
        if not line:
            raise DataError("%s: registro vazio no canal de pares." % item_label)
        parts = line.split(PAIRS_FIELD_SEPARATOR)
        if len(parts) != len(fields):
            raise DataError(
                "%s: registro com %d campos; o schema exige %d."
                % (item_label, len(parts), len(fields))
            )
        record: dict = {}
        for name, raw in zip(fields, parts):
            record[name] = _pairs_scalar(raw, "%s.%s" % (item_label, name))
        records.append(record)
    return records


def _pairs_exhausted(source: dict, label: str) -> None:
    if source:
        raise DataError(
            "%s: pares fora do schema fechado do canal: %s."
            % (label, ", ".join(safe_label(key) for key in sorted(source)))
        )


def _expand_routes(value: str, label: str) -> list[dict]:
    routes: list[dict] = []
    for index, record in enumerate(
        _pairs_records(value, PAIRS_ROUTE_FIELDS, label, MAX_ROUTES)
    ):
        item = "%s[%d]" % (label, index)
        routes.append(
            {
                "destination": record["destination"],
                "device": record["device"],
                "gateway": record["gateway"],
                "metric": _pairs_integer(
                    record["metric"], "%s.metric" % item, allow_none=True
                ),
                "protocol": record["protocol"],
                "scope": record["scope"],
                "source": record["source"],
                "table": record["table"],
                "type": record["type"],
            }
        )
    return routes


def _expand_links(value: str, label: str) -> list[dict]:
    links: list[dict] = []
    for index, record in enumerate(
        _pairs_records(value, PAIRS_LINK_FIELDS, label, MAX_LINKS)
    ):
        item = "%s[%d]" % (label, index)
        links.append(
            {
                "addresses": _pairs_items(
                    record["addresses"], "%s.addresses" % item
                ),
                "flags": _pairs_items(record["flags"], "%s.flags" % item),
                "kind": record["kind"],
                "mac": record["mac"],
                "master": record["master"],
                "mtu": _pairs_integer(record["mtu"], "%s.mtu" % item),
                "name": record["name"],
                "operstate": record["operstate"],
                "wireless": _pairs_flag(
                    record["wireless"], "%s.wireless" % item
                ),
            }
        )
    return links


def _expand_network_records(value: str, label: str) -> list[dict]:
    records: list[dict] = []
    for index, record in enumerate(
        _pairs_records(value, PAIRS_NETWORK_RECORD_FIELDS, label, MAX_NETWORKS)
    ):
        item = "%s[%d]" % (label, index)
        records.append(
            {
                "active": _pairs_flag(record["active"], "%s.active" % item),
                "active_bridge": record["active_bridge"],
                "marker": record["marker"],
                "name": record["name"],
                "persistent": _pairs_flag(
                    record["persistent"], "%s.persistent" % item
                ),
                "persistent_bridge": record["persistent_bridge"],
            }
        )
    return records


def _expand_interfaces(value: str, label: str) -> list[dict]:
    return [
        {
            "mac": record["mac"],
            "source": record["source"],
            "source_type": record["source_type"],
        }
        for record in _pairs_records(
            value, PAIRS_INTERFACE_FIELDS, label, MAX_INTERFACES_PER_VM
        )
    ]


def _expand_state(source: dict, prefix: str, *, mode: bool) -> dict:
    """Monta um estado (snapshot ou intenção) a partir dos pares planos.

    Chaves consumidas, com `P` = `snapshot_` ou `intent_`:

    * `P_schema_version`      inteiro decimal;
    * `P_mode`                só na intenção: `bridge` ou `nat`;
    * `P_uplink_name`         nome de interface;
    * `P_uplink_kind`         texto, pode ser vazio;
    * `P_uplink_mac`          MAC minúsculo ou vazio;
    * `P_routes`              coleção `PAIRS_ROUTE_FIELDS`;
    * `P_links`               coleção `PAIRS_LINK_FIELDS`;
    * `P_bridge_name`         nome de interface;
    * `P_bridge_exists`       `0`/`1`;
    * `P_bridge_ports`        lista por nova linha;
    * `P_libvirt_network_name`, `_exists`, `_active`, `_persistent`,
      `_autostart`, `_marker`  escalares (`0`/`1` nos quatro booleanos);
    * `P_libvirt_network_active_xml`, `P_libvirt_network_persistent_xml`
      blobs;
    * `P_foreign_networks`    coleção `PAIRS_NETWORK_RECORD_FIELDS`;
    * `P_consumers`           coleção `PAIRS_CONSUMER_FIELDS`;
    * `P_consumer_I_xml`      blob, um por registro de `P_consumers`;
    * `P_consumer_I_interfaces` coleção `PAIRS_INTERFACE_FIELDS`, uma por
      registro de `P_consumers`;
    * `P_configuration`       coleção `PAIRS_CONFIGURATION_FIELDS`;
    * `P_configuration_I_content` blob, um por registro de `P_configuration`.
    """
    label = prefix
    prefix_key = "%s_" % prefix

    def key(suffix: str) -> str:
        return prefix_key + suffix

    def text(suffix: str) -> str:
        return _pairs_text(source, key(suffix), label)

    def blob(suffix: str) -> str:
        return _pairs_take(source, key(suffix), label)

    state: dict[str, Any] = {}
    state["schema_version"] = _pairs_integer(
        text("schema_version"), "%s.schema_version" % label
    )
    if mode:
        state["mode"] = text("mode")
    state["uplink"] = {
        "kind": text("uplink_kind"),
        "mac": text("uplink_mac"),
        "name": text("uplink_name"),
    }
    state["routes"] = _expand_routes(
        _pairs_take(source, key("routes"), label), "%s.routes" % label
    )
    state["links"] = _expand_links(
        _pairs_take(source, key("links"), label), "%s.links" % label
    )
    state["bridge"] = {
        "exists": _pairs_flag(
            text("bridge_exists"), "%s.bridge.exists" % label
        ),
        "name": text("bridge_name"),
        "ports": _pairs_lines(
            _pairs_take(source, key("bridge_ports"), label),
            "%s.bridge.ports" % label,
        ),
    }
    network_label = "%s.libvirt_network" % label
    state["libvirt_network"] = {
        "active": _pairs_flag(
            text("libvirt_network_active"), "%s.active" % network_label
        ),
        "active_xml": blob("libvirt_network_active_xml"),
        "autostart": _pairs_flag(
            text("libvirt_network_autostart"), "%s.autostart" % network_label
        ),
        "exists": _pairs_flag(
            text("libvirt_network_exists"), "%s.exists" % network_label
        ),
        "marker": text("libvirt_network_marker"),
        "name": text("libvirt_network_name"),
        "persistent": _pairs_flag(
            text("libvirt_network_persistent"), "%s.persistent" % network_label
        ),
        "persistent_xml": blob("libvirt_network_persistent_xml"),
    }
    state["foreign_networks"] = _expand_network_records(
        _pairs_take(source, key("foreign_networks"), label),
        "%s.foreign_networks" % label,
    )
    consumers: list[dict] = []
    for index, record in enumerate(
        _pairs_records(
            _pairs_take(source, key("consumers"), label),
            PAIRS_CONSUMER_FIELDS,
            "%s.consumers" % label,
            MAX_CONSUMERS,
        )
    ):
        item = "%s.consumers[%d]" % (label, index)
        consumers.append(
            {
                "active": _pairs_flag(record["active"], "%s.active" % item),
                "interfaces": _expand_interfaces(
                    _pairs_take(
                        source, key("consumer_%d_interfaces" % index), label
                    ),
                    "%s.interfaces" % item,
                ),
                "name": record["name"],
                "xml": _pairs_take(source, key("consumer_%d_xml" % index), label),
            }
        )
    state["consumers"] = consumers
    configurations: list[dict] = []
    for index, record in enumerate(
        _pairs_records(
            _pairs_take(source, key("configuration"), label),
            PAIRS_CONFIGURATION_FIELDS,
            "%s.configuration" % label,
            MAX_CONFIGURATIONS,
        )
    ):
        item = "%s.configuration[%d]" % (label, index)
        entry: dict[str, Any] = {
            "content": _pairs_take(
                source, key("configuration_%d_content" % index), label
            ),
            "exists": _pairs_flag(record["exists"], "%s.exists" % item),
            "file_type": record["file_type"],
            "identifier": record["identifier"],
            "scope": record["scope"],
        }
        for name in (
            "device",
            "gid",
            "inode",
            "mode",
            "mtime_ns",
            "nlink",
            "size",
            "uid",
        ):
            entry[name] = _pairs_integer(
                record[name], "%s.%s" % (item, name), allow_none=True
            )
        configurations.append(entry)
    state["configuration"] = configurations
    return state


def _expand_target(source: dict) -> dict:
    """Alvo da etapa. Todo campo é par próprio; `target_xml` é blob.

    Ordem das chaves: `target_active`, `target_defined`, `target_name`,
    `target_nic_mac`, `target_nic_match_count`, `target_nic_source`,
    `target_nic_source_type`, `target_xml`.
    """
    label = "target"
    return {
        "active": _pairs_flag(
            _pairs_text(source, "target_active", label), "target.active"
        ),
        "defined": _pairs_flag(
            _pairs_text(source, "target_defined", label), "target.defined"
        ),
        "name": _pairs_text(source, "target_name", label),
        "nic_mac": _pairs_text(source, "target_nic_mac", label),
        "nic_match_count": _pairs_integer(
            _pairs_text(source, "target_nic_match_count", label),
            "target.nic_match_count",
        ),
        "nic_source": _pairs_text(source, "target_nic_source", label),
        "nic_source_type": _pairs_text(source, "target_nic_source_type", label),
        "xml": _pairs_take(source, "target_xml", label),
    }


def _expand_settings(source: dict) -> dict:
    """Ajustes da etapa; `settings_capabilities` é lista por nova linha."""
    label = "settings"
    profile = "settings.host_profile"
    return {
        "capabilities": _pairs_lines(
            _pairs_take(source, "settings_capabilities", label),
            "settings.capabilities",
        ),
        "configuration_identifier": _pairs_text(
            source, "settings_configuration_identifier", label
        ),
        "host_ip": _pairs_text(source, "settings_host_ip", label),
        "host_profile": {
            "dhcp4": _pairs_flag(
                _pairs_text(source, "settings_host_profile_dhcp4", label),
                "%s.dhcp4" % profile,
            ),
            "forward_delay": _pairs_integer(
                _pairs_text(
                    source, "settings_host_profile_forward_delay", label
                ),
                "%s.forward_delay" % profile,
            ),
            "identifier": _pairs_text(
                source, "settings_host_profile_identifier", label
            ),
            "member_dhcp4": _pairs_flag(
                _pairs_text(
                    source, "settings_host_profile_member_dhcp4", label
                ),
                "%s.member_dhcp4" % profile,
            ),
            "member_dhcp6": _pairs_flag(
                _pairs_text(
                    source, "settings_host_profile_member_dhcp6", label
                ),
                "%s.member_dhcp6" % profile,
            ),
            "scope": _pairs_text(source, "settings_host_profile_scope", label),
            "stp": _pairs_flag(
                _pairs_text(source, "settings_host_profile_stp", label),
                "%s.stp" % profile,
            ),
        },
        "marker": _pairs_text(source, "settings_marker", label),
        "nat_bridge": _pairs_text(source, "settings_nat_bridge", label),
        "nat_cidr": _pairs_text(source, "settings_nat_cidr", label),
        "uplink_effective": _pairs_text(
            source, "settings_uplink_effective", label
        ),
        "vm_ip": _pairs_text(source, "settings_vm_ip", label),
    }


def _accept_plan_pairs(value: Any) -> Any:
    """Aceita o pedido de plano aninhado ou o mesmo pedido em pares planos.

    Pares consumidos: `schema_version`, o bloco `snapshot_*`, o bloco
    `intent_*` (com `intent_mode`), o bloco `target_*` e o bloco `settings_*`.
    """
    payload = _pairs_payload(value, "plan")
    if payload is None:
        return value
    request = {
        "intent": _expand_state(payload, "intent", mode=True),
        "schema_version": _pairs_integer(
            _pairs_text(payload, "schema_version", "plan"),
            "plan.schema_version",
        ),
        "settings": _expand_settings(payload),
        "snapshot": _expand_state(payload, "snapshot", mode=False),
        "target": _expand_target(payload),
    }
    _pairs_exhausted(payload, "plan")
    return request


def _accept_snapshot_pairs(value: Any) -> Any:
    """Aceita `{"snapshot": {...}}` ou o bloco `snapshot_*` em pares."""
    payload = _pairs_payload(value, "snapshot")
    if payload is None:
        return _closed(value, {"snapshot"}, "snapshot")["snapshot"]
    state = _expand_state(payload, "snapshot", mode=False)
    _pairs_exhausted(payload, "snapshot")
    return state


def _accept_consumer_pairs(value: Any) -> Any:
    """Aceita o inventário aninhado ou o mesmo inventário em pares planos.

    Pares consumidos: `schema_version`, `marker`, `network_name`, `target`,
    `bridges` (lista por nova linha), `networks` (coleção
    `PAIRS_NETWORK_RECORD_FIELDS`), `domains` (coleção `PAIRS_DOMAIN_FIELDS`) e
    `domain_I_interfaces` (coleção `PAIRS_INTERFACE_FIELDS`, uma por registro
    de `domains`).
    """
    payload = _pairs_payload(value, "consumers")
    if payload is None:
        return value
    label = "consumers"
    domains: list[dict] = []
    domain_records = _pairs_records(
        _pairs_take(payload, "domains", label),
        PAIRS_DOMAIN_FIELDS,
        "consumers.domains",
        MAX_CONSUMERS,
    )
    for index, record in enumerate(domain_records):
        item = "consumers.domains[%d]" % index
        domains.append(
            {
                "active": _pairs_flag(record["active"], "%s.active" % item),
                "defined": _pairs_flag(record["defined"], "%s.defined" % item),
                "interfaces": _expand_interfaces(
                    _pairs_take(payload, "domain_%d_interfaces" % index, label),
                    "%s.interfaces" % item,
                ),
                "name": record["name"],
            }
        )
    request = {
        "bridges": _pairs_lines(
            _pairs_take(payload, "bridges", label), "consumers.bridges"
        ),
        "domains": domains,
        "marker": _pairs_text(payload, "marker", label),
        "network_name": _pairs_text(payload, "network_name", label),
        "networks": _expand_network_records(
            _pairs_take(payload, "networks", label), "consumers.networks"
        ),
        "schema_version": _pairs_integer(
            _pairs_text(payload, "schema_version", label),
            "consumers.schema_version",
        ),
        "target": _pairs_text(payload, "target", label),
    }
    _pairs_exhausted(payload, label)
    return request


def _accept_route_audit_pairs(value: Any) -> Any:
    """Aceita a auditoria aninhada ou a mesma auditoria em pares planos.

    Pares consumidos: `candidate_cidr`, `managed_present`, `managed_family`,
    `managed_cidr`, `managed_gateway`, `managed_bridge` e `routes` (coleção
    `PAIRS_ROUTE_FIELDS`).
    """
    payload = _pairs_payload(value, "route_audit")
    if payload is None:
        return value
    label = "route_audit"
    request = {
        "candidate_cidr": _pairs_text(payload, "candidate_cidr", label),
        "managed": {
            "bridge": _pairs_text(payload, "managed_bridge", label),
            "cidr": _pairs_text(payload, "managed_cidr", label),
            "family": _pairs_text(payload, "managed_family", label),
            "gateway": _pairs_text(payload, "managed_gateway", label),
            "present": _pairs_flag(
                _pairs_text(payload, "managed_present", label),
                "route_audit.managed.present",
            ),
        },
        "routes": _expand_routes(
            _pairs_take(payload, "routes", label), "route_audit.routes"
        ),
    }
    _pairs_exhausted(payload, label)
    return request


def _accept_revalidation_pairs(value: Any) -> tuple:
    """Aceita a revalidação aninhada ou a mesma em pares planos.

    Forma aninhada: `{"snapshot": {...}, "expected": {"components": {...},
    "exact": ..., "semantic": ...}}`. Forma plana: o bloco `snapshot_*` mais
    `expected_exact`, `expected_semantic` e `expected_component_CAMPO` para
    cada campo de `STATE_FIELDS`. As chaves `expected_*` são exatamente o que
    `network-snapshot` devolveu em `FINGERPRINT_EXACT`, `FINGERPRINT_SEMANTIC`
    e `FINGERPRINT_COMPONENT_CAMPO`.
    """
    label = "revalidation"
    payload = _pairs_payload(value, label)
    if payload is None:
        data = _closed(value, {"expected", "snapshot"}, label)
        expected = _closed(
            data["expected"],
            {"components", "exact", "semantic"},
            "%s.expected" % label,
        )
        components = _closed(
            expected["components"],
            set(STATE_FIELDS),
            "%s.expected.components" % label,
        )
        return data["snapshot"], {
            "components": {
                field: _pairs_digest(
                    _text(components, field, "%s.expected.components" % label),
                    "%s.expected.components.%s" % (label, field),
                )
                for field in STATE_FIELDS
            },
            "exact": _pairs_digest(
                _text(expected, "exact", "%s.expected" % label),
                "%s.expected.exact" % label,
            ),
            "semantic": _pairs_digest(
                _text(expected, "semantic", "%s.expected" % label),
                "%s.expected.semantic" % label,
            ),
        }
    state = _expand_state(payload, "snapshot", mode=False)
    expected = {
        "components": {
            field: _pairs_digest(
                _pairs_text(payload, "expected_component_%s" % field, label),
                "%s.expected_component_%s" % (label, field),
            )
            for field in STATE_FIELDS
        },
        "exact": _pairs_digest(
            _pairs_text(payload, "expected_exact", label),
            "%s.expected_exact" % label,
        ),
        "semantic": _pairs_digest(
            _pairs_text(payload, "expected_semantic", label),
            "%s.expected_semantic" % label,
        ),
    }
    _pairs_exhausted(payload, label)
    return state, expected


def network_snapshot(payload: Mapping[str, Any]) -> dict:
    """Normaliza o estado capturado e projeta os fingerprints no canal escalar.

    Devolve o digest exato, o semântico e um por componente de `STATE_FIELDS`,
    que é exatamente o que o Bash guarda para chamar `network-revalidate`
    depois, mais as cardinalidades que a etapa usa para diagnóstico.
    """
    normalized = normalize_snapshot(_accept_snapshot_pairs(payload))
    prints = _fingerprints(normalized)
    bridge = normalized["bridge"]
    network = normalized["libvirt_network"]
    data: dict[str, Any] = {
        "bridge_exists": 1 if bridge["exists"] else 0,
        "bridge_name": bridge["name"],
        "bridge_port_count": len(bridge["ports"]),
        "bridge_ports": "\n".join(bridge["ports"]),
        "configuration_count": len(normalized["configuration"]),
        "consumer_count": len(normalized["consumers"]),
        "consumer_names": "\n".join(
            item["name"] for item in normalized["consumers"]
        ),
        "fingerprint_exact": prints["exact"],
        "fingerprint_semantic": prints["semantic"],
        "foreign_network_count": len(normalized["foreign_networks"]),
        "foreign_network_names": "\n".join(
            item["name"] for item in normalized["foreign_networks"]
        ),
        "libvirt_network_active": 1 if network["active"] else 0,
        "libvirt_network_autostart": 1 if network["autostart"] else 0,
        "libvirt_network_exists": 1 if network["exists"] else 0,
        "libvirt_network_marker": network["marker"],
        "libvirt_network_name": network["name"],
        "libvirt_network_persistent": 1 if network["persistent"] else 0,
        "link_count": len(normalized["links"]),
        "route_count": len(normalized["routes"]),
        "schema_version": normalized["schema_version"],
        "uplink_mac": normalized["uplink"]["mac"],
        "uplink_name": normalized["uplink"]["name"],
    }
    for field in STATE_FIELDS:
        data["fingerprint_component_%s" % field] = prints["components"][field]
    return data


def network_revalidate(payload: Mapping[str, Any]) -> dict:
    """Recaptura contra fingerprints guardados e nomeia o que divergiu.

    A comparação é por componente, além do exato e do semântico, para que a
    etapa recuse com conflito citando exatamente o que mudou entre a captura e
    a publicação. Nada aqui decide o efeito: quem recusa é o Bash.
    """
    state, expected = _accept_revalidation_pairs(payload)
    normalized = normalize_snapshot(state)
    prints = _fingerprints(normalized)
    divergent = sorted(
        field
        for field in STATE_FIELDS
        if prints["components"][field] != expected["components"][field]
    )
    exact_match = 1 if prints["exact"] == expected["exact"] else 0
    semantic_match = 1 if prints["semantic"] == expected["semantic"] else 0
    data: dict[str, Any] = {
        "divergent_components": "\n".join(divergent),
        "divergent_count": len(divergent),
        "exact_match": exact_match,
        "expected_exact": expected["exact"],
        "expected_semantic": expected["semantic"],
        "fingerprint_exact": prints["exact"],
        "fingerprint_semantic": prints["semantic"],
        "matches": 1 if not divergent and exact_match and semantic_match else 0,
        "schema_version": normalized["schema_version"],
        "semantic_match": semantic_match,
    }
    for field in STATE_FIELDS:
        data["component_%s_match" % field] = 0 if field in divergent else 1
        data["expected_component_%s" % field] = expected["components"][field]
        data["fingerprint_component_%s" % field] = prints["components"][field]
    return data
