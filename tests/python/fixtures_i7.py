"""Fixtures do planner de rede (I7.3 e I7.7).

Reproduzem o estado inicial do harness de mutadores
(`tests/lib/mutator-harness.sh:68-110`), porque é ele que congela a sequência
de efeitos da etapa 19 no oráculo I0. Vivem em módulo próprio porque o teste do
core (`test_network.py`) e o teste da CLI (`test_cli_domain.py`) precisam do
mesmo pedido de plano.

Todo valor aqui é `PUBLIC` (seção 3.9): nomes, MAC e endereços são inventados
para o teste e não descrevem nenhum host real.
"""
from __future__ import annotations

import copy
from typing import Mapping

import fixtures_i3 as fx

VM = "fixture-win11"
UPLINK_MAC = "aa:bb:cc:dd:ee:01"


def rota(
    *,
    tipo: str = "unicast",
    destino: str = "10.9.0.0/24",
    dev: str = "br0",
    protocolo: str = "kernel",
    escopo: str = "link",
    tabela: str = "main",
    metrica=None,
    origem: str = "",
    gateway: str = "",
) -> dict:
    return {
        "destination": destino,
        "device": dev,
        "gateway": gateway,
        "metric": metrica,
        "protocol": protocolo,
        "scope": escopo,
        "source": origem,
        "table": tabela,
        "type": tipo,
    }


def link(
    nome: str,
    *,
    kind: str = "",
    mac: str = "",
    master: str = "",
    operstate: str = "up",
    mtu: int = 1500,
    flags=None,
    addresses=None,
    wireless: bool = False,
) -> dict:
    return {
        "addresses": list(addresses or []),
        "flags": list(flags or ["BROADCAST", "MULTICAST", "UP"]),
        "kind": kind,
        "mac": mac,
        "master": master,
        "mtu": mtu,
        "name": nome,
        "operstate": operstate,
        "wireless": wireless,
    }


def artefato(*, scope: str, identifier: str, content: str, mode: int = 0o600) -> dict:
    return {
        "content": content,
        "device": 66306,
        "exists": True,
        "file_type": "regular",
        "gid": 0,
        "identifier": identifier,
        "inode": 4711,
        "mode": mode,
        "mtime_ns": 1_700_000_000_000_000_000,
        "nlink": 1,
        "scope": scope,
        "size": len(content.encode("utf-8")),
        "uid": 0,
    }


def consumidor(*, name: str, active: bool, interfaces) -> dict:
    return {
        "active": active,
        "interfaces": list(interfaces),
        "name": name,
        "xml": fx.domain().replace("fixture-win11", name),
    }

PLANO_REDE = "passthrough-nat"
PLANO_BRIDGE = "br0"
PLANO_BRIDGE_NAT = "virbr-vmnat"
PLANO_UPLINK = "enp3s0"
PLANO_MARCADOR = "vm-passthrough:60-rede-nat:v1"
PLANO_CIDR = "192.168.177.0/24"
PLANO_PERFIL = "vm-passthrough-bridge"
PLANO_CONF = "passthrough.conf"
PLANO_CAPACIDADES = [
    "domain-schema-validation",
    "host-link-inspection",
    "host-network-apply",
    "hypervisor-control",
    "text-extraction",
]

# Projeção provider -> efeito observável do oráculo I0. Ela vive AQUI, no teste,
# e não no plano: o plano não pode conter nome de ferramenta (I7.7). É esta
# tabela que prova que a sequência abstrata corresponde, verbo a verbo, aos 11
# efeitos NAT e aos 10 efeitos bridge de `tests/test-i0-mutators.sh:349` e
# `tests/test-i0-mutators.sh:360`.
PERFIL_ARQUIVO = "/etc/netplan/90-vm-passthrough-bridge.yaml"
CONF_ARQUIVO = "$H/project/passthrough.conf"
PROJECAO_PROVIDER = {
    "configuration-discard": "fs:rm:" + CONF_ARQUIVO,
    "configuration-publish": "custom:config-publish",
    "configuration-restore": "fs:cp:" + CONF_ARQUIVO,
    "domain-redefine": "virsh:define",
    "domain-restore": "virsh:define",
    "host-network-activate": "netplan:apply",
    "host-network-activate-reversible": "netplan:try",
    "host-profile-archive": "fs:cp:" + PERFIL_ARQUIVO,
    "host-profile-discard": "fs:rm:" + PERFIL_ARQUIVO,
    "host-profile-restore": "fs:cp:" + PERFIL_ARQUIVO,
    "host-profile-store": "fs:install:" + PERFIL_ARQUIVO,
    "network-activate": "virsh:net-start",
    "network-autostart-disable": "virsh:net-autostart",
    "network-autostart-enable": "virsh:net-autostart",
    "network-deactivate": "virsh:net-destroy",
    "network-define": "virsh:net-define",
    "network-recreate": "virsh:net-create",
    "network-redefine": "virsh:net-define",
    "network-undefine": "virsh:net-undefine",
}
EFEITOS_NAT = (
    ["custom:config-publish"] * 4
    + ["virsh:net-define", "virsh:net-start", "virsh:net-autostart", "virsh:define"]
    + ["custom:config-publish"] * 3
)
EFEITOS_BRIDGE = (
    ["custom:config-publish"] * 4
    + [
        "fs:install:" + PERFIL_ARQUIVO,
        "netplan:try",
        "netplan:apply",
        "virsh:define",
    ]
    + ["custom:config-publish"] * 2
)
ROLLBACK_NAT = (
    "virsh:net-destroy;virsh:net-undefine;virsh:define;"
    "fs:cp:$H/project/passthrough.conf"
)
ROLLBACK_BRIDGE = (
    "fs:rm:/etc/netplan/90-vm-passthrough-bridge.yaml;netplan:apply;"
    "virsh:define;fs:cp:$H/project/passthrough.conf"
)
# I7.7: nenhum destes pode aparecer em valor algum do plano.
TOKENS_DE_FERRAMENTA = (
    "/etc/netplan",
    "install -m",
    "ip route",
    "netplan",
    "nmcli",
    "systemd-networkd",
    "virsh",
    "wicked",
)

CONF_TEXTO = "".join(
    '%s="%s"\n' % par
    for par in (
        ("USUARIO_LINUX", "fixture"),
        ("VM_NAME", VM),
        ("REDE_MODO", "nat"),
        ("INTERFACE_FISICA", PLANO_UPLINK),
        ("REDE_BRIDGE", PLANO_BRIDGE),
        ("REDE_LIBVIRT", PLANO_REDE),
        ("REDE_BRIDGE_LIBVIRT", PLANO_BRIDGE_NAT),
        ("REDE_NAT_CIDR", PLANO_CIDR),
        ("VM_NIC_MAC", fx.NIC_MAC),
        ("VM_IP_FIXO", "192.168.177.10"),
        ("IP_FIXO_HOST", "192.168.177.1"),
    )
)
# Mesmo corpo que o heredoc de `etapas/60-rede-bridge.sh:1000-1014` produz. Ele
# entra no plano como CONTEÚDO do artefato, nunca como comando: o texto não
# menciona ferramenta alguma, e é isso que torna a intenção portável.
PERFIL_TEXTO = (
    "network:\n"
    "  version: 2\n"
    "  ethernets:\n"
    "    %s:\n"
    "      dhcp4: no\n"
    "      dhcp6: no\n"
    "  bridges:\n"
    "    %s:\n"
    "      interfaces: [%s]\n"
    "      dhcp4: yes\n"
    "      parameters:\n"
    "        stp: true\n"
    "        forward-delay: 4\n" % (PLANO_UPLINK, PLANO_BRIDGE, PLANO_UPLINK)
)
XML_NAT = fx.network(
    nome=PLANO_REDE,
    descricao=PLANO_MARCADOR,
    uuid="",
    forward=(
        "<forward mode='nat' dev='%s'><nat><port start='1024' end='65535'/>"
        "</nat></forward>" % PLANO_UPLINK
    ),
    bridge="<bridge name='%s' stp='on' delay='0'/>" % PLANO_BRIDGE_NAT,
    ips=(
        "<ip address='192.168.177.1' netmask='255.255.255.0'><dhcp>"
        "<range start='192.168.177.100' end='192.168.177.254'/>"
        "<host mac='%s' ip='192.168.177.10'/></dhcp></ip>" % fx.NIC_MAC
    ),
)
XML_ALHEIO = fx.network(
    nome=PLANO_REDE,
    descricao="rede de outro projeto",
    bridge="<bridge name='virbr9' stp='on' delay='0'/>",
)


def rede_plano(**overrides) -> dict:
    base = {
        "active": False,
        "active_xml": "",
        "autostart": False,
        "exists": False,
        "marker": "",
        "name": PLANO_REDE,
        "persistent": False,
        "persistent_xml": "",
    }
    base.update(overrides)
    return base


def rede_gerenciada(**overrides) -> dict:
    base = {
        "active": True,
        "active_xml": XML_NAT,
        "autostart": True,
        "exists": True,
        "marker": PLANO_MARCADOR,
        "name": PLANO_REDE,
        "persistent": True,
        "persistent_xml": XML_NAT,
    }
    base.update(overrides)
    return base


def snapshot_plano(**overrides) -> dict:
    """Host recém-preparado: sem bridge, sem rede libvirt e sem perfil dedicado."""
    base = {
        "bridge": {"exists": False, "name": PLANO_BRIDGE, "ports": []},
        "configuration": [
            artefato(scope="project", identifier=PLANO_CONF, content=CONF_TEXTO)
        ],
        "consumers": [],
        "foreign_networks": [],
        "libvirt_network": rede_plano(),
        "links": [
            link(PLANO_UPLINK, mac=UPLINK_MAC, addresses=["192.168.0.7/24"])
        ],
        "routes": [
            rota(
                destino="default",
                dev=PLANO_UPLINK,
                protocolo="dhcp",
                gateway="192.168.0.1",
            ),
            rota(destino="192.168.0.0/24", dev=PLANO_UPLINK, origem="192.168.0.7"),
        ],
        "schema_version": 1,
        "uplink": {"kind": "", "mac": UPLINK_MAC, "name": PLANO_UPLINK},
    }
    base.update(overrides)
    return copy.deepcopy(base)


def intencao_nat(**overrides) -> dict:
    base = snapshot_plano()
    base["mode"] = "nat"
    base["libvirt_network"] = rede_gerenciada()
    base.update(overrides)
    return copy.deepcopy(base)


def intencao_bridge(**overrides) -> dict:
    base = snapshot_plano()
    base["mode"] = "bridge"
    base["bridge"] = {"exists": True, "name": PLANO_BRIDGE, "ports": [PLANO_UPLINK]}
    base["links"] = [
        link(PLANO_UPLINK, mac=UPLINK_MAC, master=PLANO_BRIDGE),
        link(PLANO_BRIDGE, kind="bridge", mac=UPLINK_MAC, addresses=["192.168.0.7/24"]),
    ]
    base["routes"] = [
        rota(
            destino="default",
            dev=PLANO_BRIDGE,
            protocolo="dhcp",
            gateway="192.168.0.1",
        ),
        rota(destino="192.168.0.0/24", dev=PLANO_BRIDGE, origem="192.168.0.7"),
    ]
    base["configuration"] = [
        artefato(scope="host", identifier=PLANO_PERFIL, content=PERFIL_TEXTO),
        artefato(scope="project", identifier=PLANO_CONF, content=CONF_TEXTO),
    ]
    base.update(overrides)
    return copy.deepcopy(base)


def ajustes(**overrides) -> dict:
    base = {
        "capabilities": list(PLANO_CAPACIDADES),
        "configuration_identifier": PLANO_CONF,
        "host_ip": "",
        "host_profile": {
            "dhcp4": True,
            "forward_delay": 4,
            "identifier": PLANO_PERFIL,
            "member_dhcp4": False,
            "member_dhcp6": False,
            "scope": "host",
            "stp": True,
        },
        "marker": PLANO_MARCADOR,
        "nat_bridge": PLANO_BRIDGE_NAT,
        "nat_cidr": PLANO_CIDR,
        "uplink_effective": PLANO_UPLINK,
        "vm_ip": "",
    }
    base.update(overrides)
    return copy.deepcopy(base)


def alvo(**overrides) -> dict:
    base = {
        "active": False,
        "defined": True,
        "name": VM,
        "nic_mac": fx.NIC_MAC,
        "nic_match_count": 1,
        "nic_source": "default",
        "nic_source_type": "network",
        "xml": fx.domain(),
    }
    base.update(overrides)
    return copy.deepcopy(base)


def pedido_nat(**overrides) -> dict:
    base = {
        "intent": intencao_nat(),
        "schema_version": 1,
        "settings": ajustes(),
        "snapshot": snapshot_plano(),
        "target": alvo(),
    }
    base.update(overrides)
    return base


def pedido_bridge(**overrides) -> dict:
    base = {
        "intent": intencao_bridge(),
        "schema_version": 1,
        "settings": ajustes(host_ip="192.168.0.7", vm_ip="192.168.0.55"),
        "snapshot": snapshot_plano(),
        "target": alvo(),
    }
    base.update(overrides)
    return base


def precondicao(plano, identificador) -> dict:
    """Devolve a precondição de identificador estável pedida."""
    for item in plano["preconditions"]:
        if item["id"] == identificador:
            return item
    raise AssertionError("precondição ausente: %s" % identificador)


def efeitos(plano) -> list:
    return [PROJECAO_PROVIDER[item["verb"]] for item in plano["operations"]]


def efeitos_rollback(plano) -> str:
    return ";".join(PROJECAO_PROVIDER[item["verb"]] for item in plano["rollback"])


def textos(valor):
    """Percorre chaves e valores de texto do documento inteiro."""
    if isinstance(valor, str):
        yield valor
    elif isinstance(valor, Mapping):
        for chave, item in valor.items():
            yield chave
            yield from textos(item)
    elif isinstance(valor, list):
        for item in valor:
            yield from textos(item)


# --- I7.4: inventário de domínios e de redes libvirt -------------------------
# O Bash captura `virsh list --all --name`, o `dumpxml` de cada domínio e
# `virsh net-list --all`; estas fixtures reproduzem esse inventário já
# estruturado, que é o único formato que o core aceita.

OUTRA_VM = "outra-vm"
OUTRO_MAC = "52:54:00:aa:bb:cc"
REDE_TERCEIRO = "default"
BRIDGE_TERCEIRO = "virbr0"


def nic(
    *,
    mac: str = fx.NIC_MAC,
    source_type: str = "network",
    source: str = PLANO_REDE,
) -> dict:
    return {"mac": mac, "source": source, "source_type": source_type}


def dominio(
    nome: str,
    *,
    active: bool = False,
    defined: bool = True,
    interfaces=None,
) -> dict:
    return {
        "active": active,
        "defined": defined,
        "interfaces": [nic()] if interfaces is None else list(interfaces),
        "name": nome,
    }


def registro_rede(
    nome: str,
    *,
    marker: str = "",
    active: bool = True,
    persistent: bool = True,
    active_bridge: str = "",
    persistent_bridge: str = "",
) -> dict:
    return {
        "active": active,
        "active_bridge": active_bridge,
        "marker": marker,
        "name": nome,
        "persistent": persistent,
        "persistent_bridge": persistent_bridge,
    }


def rede_gerenciada_registro(**overrides) -> dict:
    base = dict(
        marker=PLANO_MARCADOR,
        active_bridge=PLANO_BRIDGE_NAT,
        persistent_bridge=PLANO_BRIDGE_NAT,
    )
    base.update(overrides)
    return registro_rede(PLANO_REDE, **base)


def inventario(**overrides) -> dict:
    """Alvo mais uma VM definida presa à rede gerenciada, o caso do oráculo I0."""
    base = {
        "bridges": [PLANO_BRIDGE_NAT],
        "domains": [dominio(VM), dominio(OUTRA_VM)],
        "marker": PLANO_MARCADOR,
        "network_name": PLANO_REDE,
        "networks": [rede_gerenciada_registro()],
        "schema_version": 1,
        "target": VM,
    }
    base.update(overrides)
    return copy.deepcopy(base)


def nic_xml(item: Mapping) -> str:
    """Renderiza a interface do inventário como o `<interface>` equivalente."""
    mac = (
        "<mac address='%s'/>" % item["mac"] if item["mac"] else ""
    )
    if item["source_type"] == "network":
        corpo = "<source network='%s'/>" % item["source"]
        tipo = "network"
    elif item["source_type"] == "bridge":
        corpo = "<source bridge='%s'/>" % item["source"]
        tipo = "bridge"
    elif item["source_type"] == "direct":
        corpo = "<source dev='%s' mode='bridge'/>" % item["source"]
        tipo = "direct"
    else:
        corpo = ""
        tipo = "user"
    return "<interface type='%s'>%s%s<model type='virtio'/></interface>" % (
        tipo,
        mac,
        corpo,
    )


def xml_dominio(item: Mapping) -> str:
    """XML do domínio do inventário, para conferir a paridade com o Bash."""
    return fx.domain(
        interfaces="".join(nic_xml(nic_item) for nic_item in item["interfaces"])
    ).replace("fixture-win11", item["name"])
