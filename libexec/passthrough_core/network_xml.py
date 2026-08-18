"""Inspeção do XML de rede libvirt (I3.4).

Módulo puro: recebe o XML capturado pelo Bash (`net-dumpxml`, ativo ou
persistente) e devolve fatos tipados. Ele não decide efeito, não escolhe
backend de rede do host e não gera plano: o planner backend-neutral e a
transação de rede são de I7.

O ponto sensível aqui é o marcador de propriedade: uma rede homônima sem o
marcador do projeto não é nossa e precisa ser preservada. Por isso o marcador
é comparado explicitamente e nunca inferido pelo nome da rede.
"""
from __future__ import annotations

import ipaddress
import re
from typing import Any, Mapping

from . import xmlutil
from .errors import DataError
from .protocol import safe_label

NETWORK_ROOT = "network"

_MAC = re.compile(r"^[0-9a-f]{2}(:[0-9a-f]{2}){5}$")
_INTERFACE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,14}$")
_NETWORK_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
_UUID = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
)

MAX_IP_ENTRIES = 8
MAX_DHCP_HOSTS = 64


def _require_text(payload: Mapping[str, Any], key: str) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or not value:
        raise DataError(
            "O campo %s é obrigatório e precisa ser texto." % safe_label(key)
        )
    return value


def _optional_text(payload: Mapping[str, Any], key: str) -> str:
    value = payload.get(key, "")
    if value is None:
        return ""
    if not isinstance(value, str):
        raise DataError("O campo %s precisa ser texto." % safe_label(key))
    return value


def _netmask_to_prefix(netmask: str) -> int:
    """Converte netmask pontuada em prefixo, recusando máscara não contígua."""
    try:
        network = ipaddress.IPv4Network("0.0.0.0/%s" % netmask, strict=False)
    except (ipaddress.AddressValueError, ipaddress.NetmaskValueError, ValueError) as error:
        raise DataError("netmask IPv4 inválida no XML de rede.") from error
    return network.prefixlen


def inspect_network(payload: Mapping[str, Any]) -> dict:
    """Projeta o XML de rede em fatos escalares e listas indexadas.

    Campos-chave para os consumidores atuais:

    * `marker_match`: 1 somente quando `/network/description` é exatamente o
      marcador declarado pelo chamador. Zero significa "não é gerenciada por
      este projeto" e o consumidor precisa preservar a rede;
    * `ip_<i>_*`: cada `<ip>` com endereço, prefixo normalizado e netmask, mais
      o intervalo de rede/broadcast calculado com `ipaddress`;
    * `dhcp_mac_count` e `dhcp_ip_count`: cardinalidade das reservas, para que
      nenhuma decisão dependa de "a primeira entrada".
    """
    xml = _require_text(payload, "xml")
    marker = _optional_text(payload, "marker")
    nic_mac = _optional_text(payload, "nic_mac")
    if nic_mac:
        nic_mac = nic_mac.strip().lower()
        if _MAC.match(nic_mac) is None:
            raise DataError("nic_mac fora do formato aa:bb:cc:dd:ee:ff.")
    vm_ip = _optional_text(payload, "vm_ip")
    if vm_ip:
        try:
            ipaddress.IPv4Address(vm_ip)
        except ipaddress.AddressValueError as error:
            raise DataError("vm_ip não é um IPv4 válido.") from error

    root = xmlutil.parse_document(xml, NETWORK_ROOT, "XML de rede")
    context = "XML de rede"
    name = xmlutil.text_of(xmlutil.exactly_one(root, "name", context))
    if _NETWORK_NAME.match(name) is None:
        raise DataError("nome de rede libvirt fora do formato aceito.")
    uuid_node = xmlutil.at_most_one(root, "uuid", context)
    uuid = xmlutil.text_of(uuid_node)
    if uuid and _UUID.match(uuid.lower()) is None:
        raise DataError("UUID inválido no XML de rede.")
    description_node = xmlutil.at_most_one(root, "description", context)
    description = xmlutil.text_of(description_node)
    forward = xmlutil.at_most_one(root, "forward", context)
    bridge = xmlutil.at_most_one(root, "bridge", context)
    bridge_name = xmlutil.attribute(bridge, "name")
    if bridge_name and _INTERFACE_NAME.match(bridge_name) is None:
        raise DataError("nome de bridge inválido no XML de rede.")
    forward_dev = xmlutil.attribute(forward, "dev")
    if forward_dev and _INTERFACE_NAME.match(forward_dev) is None:
        raise DataError("dispositivo de forward inválido no XML de rede.")

    data: dict[str, Any] = {
        "name": name,
        "uuid": uuid.lower(),
        "description": description,
        "marker_match": 1 if marker and description == marker else 0,
        "forward_count": len(xmlutil.direct(root, "forward")),
        "forward_mode": xmlutil.attribute(forward, "mode"),
        "forward_dev": forward_dev,
        "bridge_name": bridge_name,
        "bridge_stp": xmlutil.attribute(bridge, "stp"),
    }

    ip_nodes = xmlutil.direct(root, "ip")
    if len(ip_nodes) > MAX_IP_ENTRIES:
        raise DataError(
            "a rede declara %d blocos <ip>, acima do limite de %d."
            % (len(ip_nodes), MAX_IP_ENTRIES)
        )
    dhcp_mac_count = 0
    dhcp_mac_ip = ""
    dhcp_ip_count = 0
    dhcp_range_start = ""
    dhcp_range_end = ""
    dhcp_range_count = 0
    for index, ip_node in enumerate(ip_nodes):
        ip_context = "bloco <ip> na posição %d" % index
        address = xmlutil.attribute(ip_node, "address")
        family = xmlutil.attribute(ip_node, "family")
        prefix_text = xmlutil.attribute(ip_node, "prefix")
        netmask = xmlutil.attribute(ip_node, "netmask")
        data["ip_%d_family" % index] = family or "ipv4"
        data["ip_%d_address" % index] = address
        data["ip_%d_netmask" % index] = netmask
        prefix = 0
        network_address = ""
        broadcast = ""
        if address and (family in ("", "ipv4")):
            try:
                parsed = ipaddress.IPv4Address(address)
            except ipaddress.AddressValueError as error:
                raise DataError("%s: endereço IPv4 inválido." % ip_context) from error
            if prefix_text:
                if not prefix_text.isdigit() or not 0 <= int(prefix_text) <= 32:
                    raise DataError("%s: prefixo IPv4 inválido." % ip_context)
                prefix = int(prefix_text)
            elif netmask:
                prefix = _netmask_to_prefix(netmask)
            else:
                raise DataError("%s: sem prefixo nem netmask." % ip_context)
            network = ipaddress.IPv4Network("%s/%d" % (parsed, prefix), strict=False)
            network_address = str(network.network_address)
            broadcast = str(network.broadcast_address)
        data["ip_%d_prefix" % index] = prefix
        data["ip_%d_network" % index] = network_address
        data["ip_%d_broadcast" % index] = broadcast

        dhcp = xmlutil.at_most_one(ip_node, "dhcp", ip_context)
        if dhcp is None:
            continue
        ranges = xmlutil.direct(dhcp, "range")
        dhcp_range_count += len(ranges)
        if len(ranges) == 1:
            dhcp_range_start = xmlutil.attribute(ranges[0], "start")
            dhcp_range_end = xmlutil.attribute(ranges[0], "end")
        hosts = xmlutil.direct(dhcp, "host")
        if len(hosts) > MAX_DHCP_HOSTS:
            raise DataError(
                "%s: %d reservas DHCP, acima do limite de %d."
                % (ip_context, len(hosts), MAX_DHCP_HOSTS)
            )
        for host in hosts:
            host_mac = xmlutil.attribute(host, "mac").strip().lower()
            host_ip = xmlutil.attribute(host, "ip")
            if host_mac and _MAC.match(host_mac) is None:
                raise DataError("%s: MAC de reserva DHCP inválido." % ip_context)
            if nic_mac and host_mac == nic_mac:
                dhcp_mac_count += 1
                dhcp_mac_ip = host_ip
            if vm_ip and host_ip == vm_ip:
                dhcp_ip_count += 1

    data["ip_count"] = len(ip_nodes)
    data["dhcp_range_count"] = dhcp_range_count
    data["dhcp_range_start"] = dhcp_range_start
    data["dhcp_range_end"] = dhcp_range_end
    data["dhcp_mac_count"] = dhcp_mac_count
    data["dhcp_mac_ip"] = dhcp_mac_ip if dhcp_mac_count == 1 else ""
    data["dhcp_ip_count"] = dhcp_ip_count
    data["fingerprint"] = xmlutil.fingerprint(root)
    return data


def network_overlap(payload: Mapping[str, Any]) -> dict:
    """Diz se algum bloco `<ip>` da rede colide com o CIDR candidato.

    Usa `ipaddress` em vez de aritmética manual, e trata prefixo ausente pela
    netmask. Não decide nada: devolve a cardinalidade da colisão para que o
    Bash produza a mensagem e a recusa.
    """
    inspected = inspect_network(payload)
    candidate_text = _require_text(payload, "candidate_cidr")
    try:
        candidate = ipaddress.IPv4Network(candidate_text, strict=False)
    except (ipaddress.AddressValueError, ipaddress.NetmaskValueError, ValueError) as error:
        raise DataError("candidate_cidr não é um CIDR IPv4 válido.") from error
    overlaps = 0
    first_overlap = ""
    for index in range(int(inspected["ip_count"])):
        address = inspected.get("ip_%d_address" % index, "")
        prefix = inspected.get("ip_%d_prefix" % index, 0)
        if not address or not prefix:
            continue
        other = ipaddress.IPv4Network("%s/%d" % (address, prefix), strict=False)
        if other.overlaps(candidate):
            overlaps += 1
            if not first_overlap:
                first_overlap = str(other)
    return {
        "name": inspected["name"],
        "marker_match": inspected["marker_match"],
        "overlap_count": overlaps,
        "overlap_cidr": first_overlap,
        "candidate_cidr": str(candidate),
    }
