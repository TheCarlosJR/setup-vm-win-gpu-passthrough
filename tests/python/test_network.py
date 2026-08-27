"""Modelo de snapshot/intenção (I7.1) e aritmética de endereços (I7.2).

Duas metades: o schema fechado, as relações cruzadas e os fingerprints que
I7.1 entregou sem cobertura alguma, e o cálculo de endereços de I7.2, cuja
paridade com o Bash de hoje é oráculo explícito aqui.
"""
import copy
import ipaddress
import json
import unittest

from passthrough_core import network
from passthrough_core.errors import DataError

import fixtures_i3 as fx

REDE = "vm-passthrough-nat"
VM = "fixture-win11"
UPLINK_MAC = "aa:bb:cc:dd:ee:01"

# Rede NAT do harness de mutadores (tests/lib/mutator-harness.sh:101) e mais
# cinco sub-redes privadas, uma por borda de cada bloco RFC 1918.
PARIDADE_NAT = (
    ("192.168.177.0/24", "192.168.177"),
    ("10.0.0.0/24", "10.0.0"),
    ("10.255.255.0/24", "10.255.255"),
    ("172.16.0.0/24", "172.16.0"),
    ("172.31.255.0/24", "172.31.255"),
    ("192.168.124.0/24", "192.168.124"),
)


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
    }


def artefato(
    *,
    scope: str = "host",
    identifier: str = "01-bridge.yaml",
    content: str = "network: {}\n",
) -> dict:
    return {
        "content": content,
        "device": 66306,
        "exists": True,
        "file_type": "regular",
        "gid": 0,
        "identifier": identifier,
        "inode": 4711,
        "mode": 0o600,
        "mtime_ns": 1_700_000_000_000_000_000,
        "nlink": 1,
        "scope": scope,
        "size": len(content.encode("utf-8")),
        "uid": 0,
    }


def rede_libvirt(**overrides) -> dict:
    base = {
        "active": True,
        "active_xml": fx.network(),
        "autostart": True,
        "exists": True,
        "marker": fx.MARCADOR,
        "name": REDE,
        "persistent": True,
        "persistent_xml": fx.network(),
    }
    base.update(overrides)
    return base


def consumidor(**overrides) -> dict:
    base = {
        "active": True,
        "interfaces": [
            {
                "mac": fx.NIC_MAC,
                "source": REDE,
                "source_type": "network",
            }
        ],
        "name": VM,
        "xml": fx.domain(),
    }
    base.update(overrides)
    return base


def snapshot(**overrides) -> dict:
    base = {
        "bridge": {"exists": True, "name": "br0", "ports": ["enp3s0"]},
        "configuration": [artefato()],
        "consumers": [consumidor()],
        "libvirt_network": rede_libvirt(),
        "links": [
            link("enp3s0", mac=UPLINK_MAC, master="br0"),
            link("br0", kind="bridge", mac=UPLINK_MAC, addresses=["192.168.0.7/24"]),
            link("virbr9", kind="bridge", addresses=["192.168.77.1/24"]),
        ],
        "routes": [
            rota(destino="default", dev="enp3s0", protocolo="dhcp", tabela="main"),
            rota(destino="192.168.0.0/24", dev="br0", origem="192.168.0.7"),
        ],
        "schema_version": 1,
        "uplink": {"kind": "", "mac": UPLINK_MAC, "name": "enp3s0"},
    }
    base.update(overrides)
    return copy.deepcopy(base)


def intencao(**overrides) -> dict:
    base = snapshot()
    base["mode"] = "nat"
    base.update(overrides)
    return base


class SnapshotSchemaTests(unittest.TestCase):
    def test_snapshot_valido(self) -> None:
        normalizado = network.normalize_snapshot(snapshot())
        self.assertEqual(normalizado["schema_version"], 1)
        self.assertEqual(
            sorted(normalizado), sorted(("schema_version",) + network.STATE_FIELDS)
        )
        self.assertEqual(normalizado["uplink"]["name"], "enp3s0")

    def test_campo_obrigatorio_ausente(self) -> None:
        payload = snapshot()
        del payload["routes"]
        with self.assertRaises(DataError) as contexto:
            network.normalize_snapshot(payload)
        self.assertIn("sem campos obrigatórios", str(contexto.exception))

    def test_campo_extra_recusado(self) -> None:
        payload = snapshot()
        payload["extra"] = 1
        with self.assertRaises(DataError) as contexto:
            network.normalize_snapshot(payload)
        self.assertIn("fora do schema fechado", str(contexto.exception))

    def test_versao_de_schema_divergente(self) -> None:
        for valor in (0, 2, "1", True, None):
            with self.subTest(valor=valor):
                with self.assertRaises(DataError):
                    network.normalize_snapshot(snapshot(schema_version=valor))

    def test_snapshot_precisa_ser_objeto(self) -> None:
        for valor in ([], "x", 1, None):
            with self.subTest(valor=valor):
                with self.assertRaises(DataError):
                    network.normalize_snapshot(valor)

    def test_rota_com_campo_extra(self) -> None:
        ruim = rota()
        ruim["family"] = "ipv4"
        with self.assertRaises(DataError):
            network.normalize_snapshot(snapshot(routes=[ruim]))

    def test_rota_sem_type(self) -> None:
        ruim = rota()
        del ruim["type"]
        with self.assertRaises(DataError):
            network.normalize_snapshot(snapshot(routes=[ruim]))

    def test_tipo_de_rota_desconhecido(self) -> None:
        with self.assertRaises(DataError) as contexto:
            network.normalize_snapshot(
                snapshot(routes=[rota(tipo="multicast", dev="br0")])
            )
        self.assertIn("tipo de rota", str(contexto.exception))

    def test_rota_com_dispositivo_obrigatorio(self) -> None:
        for tipo in sorted(network.ROUTE_TYPES_WITH_DEVICE):
            with self.subTest(tipo=tipo):
                with self.assertRaises(DataError):
                    network.normalize_snapshot(
                        snapshot(routes=[rota(tipo=tipo, dev="")])
                    )

    def test_rota_sem_dispositivo_e_aceita(self) -> None:
        for tipo in ("blackhole", "prohibit", "throw", "unreachable"):
            with self.subTest(tipo=tipo):
                normalizado = network.normalize_snapshot(
                    snapshot(
                        routes=[
                            rota(
                                tipo=tipo,
                                destino="10.9.0.0/24",
                                dev="",
                                protocolo="",
                                escopo="",
                            )
                        ]
                    )
                )
                self.assertEqual(normalizado["routes"][0]["device"], "")

    def test_rotas_duplicadas(self) -> None:
        with self.assertRaises(DataError):
            network.normalize_snapshot(snapshot(routes=[rota(), rota()]))

    def test_links_com_nome_duplicado(self) -> None:
        payload = snapshot()
        payload["links"].append(link("br0", kind="bridge", mac=UPLINK_MAC))
        with self.assertRaises(DataError):
            network.normalize_snapshot(payload)

    def test_configuracao_duplicada(self) -> None:
        with self.assertRaises(DataError):
            network.normalize_snapshot(
                snapshot(configuration=[artefato(), artefato()])
            )

    def test_consumidor_com_mac_duplicado(self) -> None:
        interfaces = [
            {"mac": fx.NIC_MAC, "source": REDE, "source_type": "network"},
            {"mac": fx.NIC_MAC, "source": "virbr9", "source_type": "direct"},
        ]
        with self.assertRaises(DataError):
            network.normalize_snapshot(
                snapshot(consumers=[consumidor(interfaces=interfaces)])
            )

    def test_consumidor_sem_interface(self) -> None:
        with self.assertRaises(DataError):
            network.normalize_snapshot(
                snapshot(consumers=[consumidor(interfaces=[])])
            )

    def test_limite_de_rotas(self) -> None:
        excesso = [
            rota(destino="10.%d.%d.0/24" % (indice // 256, indice % 256))
            for indice in range(network.MAX_ROUTES + 1)
        ]
        with self.assertRaises(DataError) as contexto:
            network.normalize_snapshot(snapshot(routes=excesso))
        self.assertIn("limite", str(contexto.exception))

    def test_nome_de_interface_alinhado_ao_bash(self) -> None:
        # lib/common.sh:1823 aceita `_` como primeiro caractere.
        payload = snapshot()
        payload["links"].append(link("_veth0"))
        payload["routes"].append(rota(destino="10.8.0.0/24", dev="_veth0"))
        normalizado = network.normalize_snapshot(payload)
        self.assertIn("_veth0", [item["name"] for item in normalizado["links"]])

    def test_nome_de_interface_longo_demais(self) -> None:
        payload = snapshot()
        payload["links"].append(link("a" * 16))
        with self.assertRaises(DataError):
            network.normalize_snapshot(payload)

    def test_nome_de_interface_com_caractere_proibido(self) -> None:
        payload = snapshot()
        payload["links"].append(link("br 0"))
        with self.assertRaises(DataError):
            network.normalize_snapshot(payload)

    def test_nome_de_entidade_alinhado_ao_bash(self) -> None:
        # lib/common.sh:1828 aceita `_` como primeiro caractere do nome da rede.
        rede = "_rede_do_projeto"
        normalizado = network.normalize_snapshot(
            snapshot(
                consumers=[
                    consumidor(
                        interfaces=[
                            {
                                "mac": fx.NIC_MAC,
                                "source": rede,
                                "source_type": "network",
                            }
                        ]
                    )
                ],
                libvirt_network=rede_libvirt(
                    name=rede,
                    active_xml=fx.network(nome=rede),
                    persistent_xml=fx.network(nome=rede),
                ),
            )
        )
        self.assertEqual(normalizado["libvirt_network"]["name"], rede)

    def test_nome_de_entidade_no_limite(self) -> None:
        nome = "v" * 128
        payload = snapshot(
            libvirt_network=rede_libvirt(
                name=nome,
                active_xml=fx.network(nome=nome),
                persistent_xml=fx.network(nome=nome),
            ),
            consumers=[],
        )
        self.assertEqual(
            network.normalize_snapshot(payload)["libvirt_network"]["name"], nome
        )
        payload = snapshot(
            libvirt_network=rede_libvirt(
                name="v" * 129,
                active_xml=fx.network(nome="v" * 129),
                persistent_xml=fx.network(nome="v" * 129),
            ),
            consumers=[],
        )
        with self.assertRaises(DataError):
            network.normalize_snapshot(payload)

    def test_mac_fora_do_formato(self) -> None:
        payload = snapshot()
        payload["uplink"]["mac"] = "AA-BB-CC-DD-EE-01"
        with self.assertRaises(DataError):
            network.normalize_snapshot(payload)

    def test_texto_com_controle_proibido(self) -> None:
        payload = snapshot()
        payload["uplink"]["kind"] = "ether\x07"
        with self.assertRaises(DataError):
            network.normalize_snapshot(payload)


class OrderingTests(unittest.TestCase):
    def test_ordem_e_deterministica(self) -> None:
        rotas = [
            rota(destino="10.9.0.0/24"),
            rota(destino="10.1.0.0/24"),
            rota(destino="10.5.0.0/24"),
        ]
        direto = network.normalize_snapshot(snapshot(routes=rotas))
        invertido = network.normalize_snapshot(snapshot(routes=list(reversed(rotas))))
        self.assertEqual(direto, invertido)
        self.assertEqual(
            [item["destination"] for item in direto["routes"]],
            ["10.1.0.0/24", "10.5.0.0/24", "10.9.0.0/24"],
        )

    def test_links_ordenados_por_nome(self) -> None:
        normalizado = network.normalize_snapshot(snapshot())
        nomes = [item["name"] for item in normalizado["links"]]
        self.assertEqual(nomes, sorted(nomes))

    def test_configuracao_ordenada_por_escopo_e_identificador(self) -> None:
        artefatos = [
            artefato(scope="project", identifier="passthrough.conf"),
            artefato(scope="host", identifier="99-nat.yaml"),
            artefato(scope="host", identifier="01-bridge.yaml"),
        ]
        normalizado = network.normalize_snapshot(snapshot(configuration=artefatos))
        self.assertEqual(
            [(item["scope"], item["identifier"]) for item in normalizado["configuration"]],
            [
                ("host", "01-bridge.yaml"),
                ("host", "99-nat.yaml"),
                ("project", "passthrough.conf"),
            ],
        )

    def test_listas_de_texto_ordenadas_e_sem_duplicata(self) -> None:
        payload = snapshot()
        payload["links"][1]["addresses"] = ["192.168.0.9/24", "192.168.0.7/24"]
        normalizado = network.normalize_snapshot(payload)
        alvo = [item for item in normalizado["links"] if item["name"] == "br0"][0]
        self.assertEqual(alvo["addresses"], ["192.168.0.7/24", "192.168.0.9/24"])
        payload["links"][1]["addresses"] = ["192.168.0.7/24", "192.168.0.7/24"]
        with self.assertRaises(DataError):
            network.normalize_snapshot(payload)


class LibvirtNetworkCoherenceTests(unittest.TestCase):
    def test_rede_ausente_sem_residuo(self) -> None:
        normalizado = network.normalize_snapshot(
            snapshot(
                consumers=[],
                libvirt_network={
                    "active": False,
                    "active_xml": "",
                    "autostart": False,
                    "exists": False,
                    "marker": "",
                    "name": REDE,
                    "persistent": False,
                    "persistent_xml": "",
                },
            )
        )
        self.assertFalse(normalizado["libvirt_network"]["exists"])

    def test_rede_ausente_com_residuo(self) -> None:
        residuos = (
            {"active": True},
            {"persistent": True},
            {"autostart": True},
            {"active_xml": fx.network()},
            {"persistent_xml": fx.network()},
        )
        for residuo in residuos:
            with self.subTest(residuo=sorted(residuo)):
                base = {
                    "active": False,
                    "active_xml": "",
                    "autostart": False,
                    "exists": False,
                    "marker": "",
                    "name": REDE,
                    "persistent": False,
                    "persistent_xml": "",
                }
                base.update(residuo)
                with self.assertRaises(DataError):
                    network.normalize_snapshot(
                        snapshot(consumers=[], libvirt_network=base)
                    )

    def test_rede_transitoria_e_inativa_e_impossivel(self) -> None:
        with self.assertRaises(DataError) as contexto:
            network.normalize_snapshot(
                snapshot(
                    consumers=[],
                    libvirt_network=rede_libvirt(
                        active=False,
                        active_xml="",
                        autostart=False,
                        persistent=False,
                        persistent_xml="",
                    ),
                )
            )
        self.assertIn("transitória e inativa", str(contexto.exception))

    def test_autostart_exige_persistencia(self) -> None:
        with self.assertRaises(DataError) as contexto:
            network.normalize_snapshot(
                snapshot(
                    consumers=[],
                    libvirt_network=rede_libvirt(
                        autostart=True, persistent=False, persistent_xml=""
                    ),
                )
            )
        self.assertIn("autostart", str(contexto.exception))

    def test_estado_ativo_sem_xml_ativo(self) -> None:
        with self.assertRaises(DataError):
            network.normalize_snapshot(
                snapshot(consumers=[], libvirt_network=rede_libvirt(active_xml=""))
            )

    def test_estado_persistente_sem_xml_persistente(self) -> None:
        with self.assertRaises(DataError):
            network.normalize_snapshot(
                snapshot(consumers=[], libvirt_network=rede_libvirt(persistent_xml=""))
            )

    def test_xml_com_nome_divergente(self) -> None:
        with self.assertRaises(DataError) as contexto:
            network.normalize_snapshot(
                snapshot(
                    consumers=[],
                    libvirt_network=rede_libvirt(active_xml=fx.network(nome="outra")),
                )
            )
        self.assertIn("identifica", str(contexto.exception))

    def test_xml_de_vm_com_nome_divergente(self) -> None:
        with self.assertRaises(DataError):
            network.normalize_snapshot(
                snapshot(consumers=[consumidor(name="outra-vm")])
            )


class RelationTests(unittest.TestCase):
    def test_uplink_ausente_nos_links(self) -> None:
        payload = snapshot()
        payload["links"] = [
            item for item in payload["links"] if item["name"] != "enp3s0"
        ]
        payload["bridge"]["ports"] = []
        payload["routes"] = [rota(destino="192.168.0.0/24", dev="br0")]
        with self.assertRaises(DataError) as contexto:
            network.normalize_snapshot(payload)
        self.assertIn("uplink", str(contexto.exception))

    def test_mac_do_uplink_divergente(self) -> None:
        payload = snapshot()
        payload["uplink"]["mac"] = "aa:bb:cc:dd:ee:ff"
        with self.assertRaises(DataError) as contexto:
            network.normalize_snapshot(payload)
        self.assertIn("MAC do uplink", str(contexto.exception))

    def test_master_ausente(self) -> None:
        payload = snapshot()
        payload["links"][0]["master"] = "br9"
        payload["bridge"]["ports"] = []
        with self.assertRaises(DataError) as contexto:
            network.normalize_snapshot(payload)
        self.assertIn("master ausente", str(contexto.exception))

    def test_master_de_si_mesmo(self) -> None:
        payload = snapshot()
        payload["links"][2]["master"] = "virbr9"
        with self.assertRaises(DataError):
            network.normalize_snapshot(payload)

    def test_ciclo_de_masters(self) -> None:
        payload = snapshot(
            bridge={"exists": False, "name": "br1", "ports": []},
            consumers=[],
            libvirt_network=rede_libvirt(),
            links=[
                link("enp3s0", mac=UPLINK_MAC, master="veth0"),
                link("veth0", master="veth1"),
                link("veth1", master="enp3s0"),
            ],
            routes=[],
        )
        with self.assertRaises(DataError) as contexto:
            network.normalize_snapshot(payload)
        self.assertIn("ciclo", str(contexto.exception))

    def test_rota_referencia_link_ausente(self) -> None:
        payload = snapshot()
        payload["routes"].append(rota(destino="10.4.0.0/24", dev="tap9"))
        with self.assertRaises(DataError) as contexto:
            network.normalize_snapshot(payload)
        self.assertIn("link ausente", str(contexto.exception))

    def test_bridge_existente_ausente_nos_links(self) -> None:
        payload = snapshot()
        payload["links"] = [
            item for item in payload["links"] if item["name"] != "br0"
        ]
        payload["links"][0]["master"] = ""
        payload["bridge"]["ports"] = []
        payload["routes"] = [rota(destino="192.168.0.0/24", dev="enp3s0")]
        with self.assertRaises(DataError) as contexto:
            network.normalize_snapshot(payload)
        self.assertIn("bridge existente", str(contexto.exception))

    def test_link_da_bridge_sem_kind_bridge(self) -> None:
        payload = snapshot()
        payload["links"][1]["kind"] = ""
        with self.assertRaises(DataError) as contexto:
            network.normalize_snapshot(payload)
        self.assertIn("kind=bridge", str(contexto.exception))

    def test_portas_divergentes(self) -> None:
        payload = snapshot()
        payload["bridge"]["ports"] = ["enp3s0", "virbr9"]
        with self.assertRaises(DataError) as contexto:
            network.normalize_snapshot(payload)
        self.assertIn("portas declaradas", str(contexto.exception))

    def test_bridge_ausente_colide_com_link(self) -> None:
        payload = snapshot()
        payload["bridge"] = {"exists": False, "name": "br0", "ports": []}
        with self.assertRaises(DataError) as contexto:
            network.normalize_snapshot(payload)
        self.assertIn("colide", str(contexto.exception))

    def test_bridge_ausente_com_portas(self) -> None:
        with self.assertRaises(DataError):
            network.normalize_snapshot(
                snapshot(bridge={"exists": False, "name": "br1", "ports": ["enp3s0"]})
            )

    def test_bridge_porta_de_si_mesma(self) -> None:
        with self.assertRaises(DataError):
            network.normalize_snapshot(
                snapshot(bridge={"exists": True, "name": "br0", "ports": ["br0"]})
            )

    def test_consumidor_referencia_rede_fora_do_snapshot(self) -> None:
        interfaces = [
            {"mac": fx.NIC_MAC, "source": "outra-rede", "source_type": "network"}
        ]
        with self.assertRaises(DataError) as contexto:
            network.normalize_snapshot(
                snapshot(consumers=[consumidor(interfaces=interfaces)])
            )
        self.assertIn("rede libvirt fora do snapshot", str(contexto.exception))

    def test_consumidor_referencia_bridge_fora_do_snapshot(self) -> None:
        interfaces = [
            {"mac": fx.NIC_MAC, "source": "virbr9", "source_type": "bridge"}
        ]
        with self.assertRaises(DataError) as contexto:
            network.normalize_snapshot(
                snapshot(consumers=[consumidor(interfaces=interfaces)])
            )
        self.assertIn("bridge fora do snapshot", str(contexto.exception))

    def test_consumidor_referencia_link_direto_ausente(self) -> None:
        interfaces = [
            {"mac": fx.NIC_MAC, "source": "tap7", "source_type": "direct"}
        ]
        with self.assertRaises(DataError) as contexto:
            network.normalize_snapshot(
                snapshot(consumers=[consumidor(interfaces=interfaces)])
            )
        self.assertIn("link direto ausente", str(contexto.exception))

    def test_consumidor_por_bridge_aceito(self) -> None:
        interfaces = [{"mac": fx.NIC_MAC, "source": "br0", "source_type": "bridge"}]
        normalizado = network.normalize_snapshot(
            snapshot(consumers=[consumidor(interfaces=interfaces)])
        )
        self.assertEqual(
            normalizado["consumers"][0]["interfaces"][0]["source_type"], "bridge"
        )

    def test_source_type_desconhecido(self) -> None:
        interfaces = [{"mac": fx.NIC_MAC, "source": "br0", "source_type": "vepa"}]
        with self.assertRaises(DataError):
            network.normalize_snapshot(
                snapshot(consumers=[consumidor(interfaces=interfaces)])
            )


class ConfigurationTests(unittest.TestCase):
    def test_artefato_ausente_sem_residuo(self) -> None:
        vazio = {chave: None for chave in artefato()}
        vazio.update(
            {
                "content": "",
                "exists": False,
                "file_type": "",
                "identifier": "01-bridge.yaml",
                "scope": "host",
            }
        )
        normalizado = network.normalize_snapshot(snapshot(configuration=[vazio]))
        self.assertFalse(normalizado["configuration"][0]["exists"])

    def test_artefato_ausente_com_residuo(self) -> None:
        vazio = {chave: None for chave in artefato()}
        vazio.update(
            {
                "content": "resto\n",
                "exists": False,
                "file_type": "",
                "identifier": "01-bridge.yaml",
                "scope": "host",
            }
        )
        with self.assertRaises(DataError):
            network.normalize_snapshot(snapshot(configuration=[vazio]))

    def test_artefato_precisa_ser_regular(self) -> None:
        with self.assertRaises(DataError):
            network.normalize_snapshot(
                snapshot(configuration=[dict(artefato(), file_type="symlink")])
            )

    def test_artefato_com_hardlink(self) -> None:
        with self.assertRaises(DataError):
            network.normalize_snapshot(
                snapshot(configuration=[dict(artefato(), nlink=2)])
            )

    def test_artefato_com_modo_fora_das_permissoes(self) -> None:
        with self.assertRaises(DataError):
            network.normalize_snapshot(
                snapshot(configuration=[dict(artefato(), mode=0o100600)])
            )

    def test_artefato_com_tamanho_divergente(self) -> None:
        with self.assertRaises(DataError):
            network.normalize_snapshot(
                snapshot(configuration=[dict(artefato(), size=1)])
            )

    def test_escopo_desconhecido(self) -> None:
        with self.assertRaises(DataError):
            network.normalize_snapshot(
                snapshot(configuration=[dict(artefato(), scope="usuario")])
            )


class IntentTests(unittest.TestCase):
    def test_intencao_valida(self) -> None:
        for modo in sorted(network.MODES):
            with self.subTest(modo=modo):
                normalizado = network.normalize_intent(intencao(mode=modo))
                self.assertEqual(normalizado["mode"], modo)

    def test_modo_desconhecido(self) -> None:
        for modo in ("macvtap", "", None, 1):
            with self.subTest(modo=modo):
                with self.assertRaises(DataError):
                    network.normalize_intent(intencao(mode=modo))

    def test_intencao_sem_modo(self) -> None:
        with self.assertRaises(DataError):
            network.normalize_intent(snapshot())

    def test_snapshot_com_modo_e_recusado(self) -> None:
        with self.assertRaises(DataError):
            network.normalize_snapshot(intencao())


class FingerprintTests(unittest.TestCase):
    def test_estrutura(self) -> None:
        impressoes = network.snapshot_fingerprints(snapshot())
        self.assertEqual(
            sorted(impressoes), ["components", "exact", "schema_version", "semantic"]
        )
        self.assertEqual(impressoes["schema_version"], 1)
        self.assertRegex(impressoes["exact"], r"^[0-9a-f]{64}$")
        self.assertRegex(impressoes["semantic"], r"^[0-9a-f]{64}$")
        self.assertEqual(
            sorted(impressoes["components"]), sorted(network.STATE_FIELDS)
        )

    def test_fingerprint_exato_muda_com_mudanca_real(self) -> None:
        base = network.snapshot_fingerprints(snapshot())
        outro = network.snapshot_fingerprints(
            snapshot(
                routes=[
                    rota(destino="default", dev="enp3s0", protocolo="dhcp"),
                    rota(destino="192.168.0.0/24", dev="br0", origem="192.168.0.8"),
                ]
            )
        )
        self.assertNotEqual(base["exact"], outro["exact"])
        self.assertNotEqual(base["semantic"], outro["semantic"])
        self.assertNotEqual(base["components"]["routes"], outro["components"]["routes"])
        self.assertEqual(base["components"]["links"], outro["components"]["links"])

    def test_fingerprint_semantico_invariante_a_formatacao(self) -> None:
        equivalente = fx.network(
            bridge="<bridge   stp='on'  name='virbr9'   delay='0' />"
        )
        base = network.snapshot_fingerprints(snapshot())
        reformatado = network.snapshot_fingerprints(
            snapshot(libvirt_network=rede_libvirt(active_xml=equivalente))
        )
        self.assertNotEqual(base["exact"], reformatado["exact"])
        self.assertEqual(base["semantic"], reformatado["semantic"])
        self.assertEqual(
            base["components"]["libvirt_network"],
            reformatado["components"]["libvirt_network"],
        )

    def test_fingerprint_semantico_muda_com_xml_diferente(self) -> None:
        base = network.snapshot_fingerprints(snapshot())
        outro = network.snapshot_fingerprints(
            snapshot(
                libvirt_network=rede_libvirt(
                    active_xml=fx.network(
                        bridge="<bridge name='virbr9' stp='off' delay='0'/>"
                    )
                )
            )
        )
        self.assertNotEqual(base["semantic"], outro["semantic"])

    def test_fingerprint_invariante_a_ordem_de_entrada(self) -> None:
        payload = snapshot()
        invertido = snapshot()
        invertido["links"] = list(reversed(invertido["links"]))
        invertido["routes"] = list(reversed(invertido["routes"]))
        self.assertEqual(
            network.snapshot_fingerprints(payload),
            network.snapshot_fingerprints(invertido),
        )

    def test_fingerprint_da_intencao_depende_do_modo(self) -> None:
        nat = network.intent_fingerprints(intencao(mode="nat"))
        bridge = network.intent_fingerprints(intencao(mode="bridge"))
        self.assertNotEqual(nat["exact"], bridge["exact"])
        self.assertNotEqual(nat["semantic"], bridge["semantic"])
        self.assertEqual(nat["components"], bridge["components"])


class NatAddressTests(unittest.TestCase):
    def test_paridade_com_derivar_parametros_nat(self) -> None:
        for cidr, prefixo in PARIDADE_NAT:
            with self.subTest(cidr=cidr):
                dados = network.nat_addresses({"cidr": cidr})
                # Mesma concatenação de `etapas/60-rede-bridge.sh:530-533`.
                self.assertEqual(dados["nat_gateway"], "%s.1" % prefixo)
                self.assertEqual(dados["nat_vm_ip"], "%s.10" % prefixo)
                self.assertEqual(dados["nat_dhcp_inicio"], "%s.100" % prefixo)
                self.assertEqual(dados["nat_dhcp_fim"], "%s.254" % prefixo)
                self.assertEqual(dados["nat_network"], "%s.0" % prefixo)
                self.assertEqual(dados["nat_broadcast"], "%s.255" % prefixo)
                self.assertEqual(dados["nat_cidr"], cidr)
                self.assertEqual(dados["nat_netmask"], "255.255.255.0")
                self.assertEqual(dados["nat_prefix"], 24)
                self.assertEqual(dados["nat_dhcp_count"], 155)
                self.assertEqual(dados["family"], "ipv4")

    def test_ip_do_host_e_o_gateway_virtual(self) -> None:
        # `etapas/60-rede-bridge.sh:1553` grava IP_FIXO_HOST=$NAT_GATEWAY.
        dados = network.nat_addresses({"cidr": "192.168.177.0/24"})
        self.assertEqual(dados["nat_host_ip"], dados["nat_gateway"])

    def test_saida_e_escalar(self) -> None:
        dados = network.nat_addresses({"cidr": "192.168.177.0/24"})
        for chave, valor in dados.items():
            with self.subTest(chave=chave):
                self.assertIsInstance(valor, (str, int))
                self.assertRegex(chave.upper(), r"^[A-Z][A-Z0-9_]{0,63}$")

    def test_schema_fechado(self) -> None:
        with self.assertRaises(DataError):
            network.nat_addresses({})
        with self.assertRaises(DataError):
            network.nat_addresses({"cidr": "10.0.0.0/24", "modo": "nat"})
        with self.assertRaises(DataError):
            network.nat_addresses({"cidr": 24})

    def test_prefixo_nao_suportado(self) -> None:
        for cidr in ("192.168.177.0/25", "192.168.0.0/16", "10.0.0.1/32"):
            with self.subTest(cidr=cidr):
                with self.assertRaises(DataError) as contexto:
                    network.nat_addresses({"cidr": cidr})
                self.assertIn("prefixo", str(contexto.exception))

    def test_cidr_precisa_ser_endereco_de_rede(self) -> None:
        with self.assertRaises(DataError) as contexto:
            network.nat_addresses({"cidr": "192.168.177.5/24"})
        self.assertIn("endereço de rede", str(contexto.exception))

    def test_rede_nao_privada_recusada(self) -> None:
        for cidr in (
            "11.0.0.0/24",
            "172.15.0.0/24",
            "172.32.0.0/24",
            "192.169.0.0/24",
            "169.254.1.0/24",
            "127.0.0.0/24",
            "100.64.0.0/24",
        ):
            with self.subTest(cidr=cidr):
                with self.assertRaises(DataError) as contexto:
                    network.nat_addresses({"cidr": cidr})
                self.assertIn("privada", str(contexto.exception))

    def test_ipv6_recusado(self) -> None:
        for cidr in ("fd00::/64", "::/0", "2001:db8::1/128"):
            with self.subTest(cidr=cidr):
                with self.assertRaises(DataError) as contexto:
                    network.nat_addresses({"cidr": cidr})
                self.assertIn("IPv6", str(contexto.exception))

    def test_formato_invalido_recusado(self) -> None:
        for cidr in (
            "192.168.177.0",
            "192.168.177.0/24/24",
            "192.168.177/24",
            "192.168.177.0.1/24",
            "192.168.177.256/24",
            "192.168.177.0/",
            "/24",
            " 192.168.177.0/24",
            "192.168.177.0/24 ",
        ):
            with self.subTest(cidr=cidr):
                with self.assertRaises(DataError):
                    network.nat_addresses({"cidr": cidr})

    def test_zero_a_esquerda_recusado(self) -> None:
        with self.assertRaises(DataError) as contexto:
            network.nat_addresses({"cidr": "192.168.010.0/24"})
        self.assertIn("zero à esquerda", str(contexto.exception))

    def test_prefixo_com_zero_a_esquerda_recusado(self) -> None:
        # O Bash leria `/024` como octal 20 dentro de `$(( ))`.
        with self.assertRaises(DataError) as contexto:
            network.nat_addresses({"cidr": "192.168.177.0/024"})
        self.assertIn("zero à esquerda", str(contexto.exception))

    def test_prefixo_fora_da_faixa(self) -> None:
        for cidr in ("192.168.177.0/33", "192.168.177.0/-1", "192.168.177.0/x"):
            with self.subTest(cidr=cidr):
                with self.assertRaises(DataError):
                    network.nat_addresses({"cidr": cidr})


class AddressCheckTests(unittest.TestCase):
    def test_par_valido(self) -> None:
        dados = network.address_check(
            {"cidr": "192.168.0.7/24", "host_ip": "192.168.0.7", "vm_ip": "192.168.0.55"}
        )
        self.assertEqual(dados["accepted"], 1)
        self.assertEqual(dados["host_matches_cidr"], 1)
        self.assertEqual(dados["vm_unicast"], 1)
        self.assertEqual(dados["distinct"], 1)
        self.assertEqual(dados["cidr"], "192.168.0.0/24")
        self.assertEqual(dados["interface_address"], "192.168.0.7")
        self.assertEqual(dados["network"], "192.168.0.0")
        self.assertEqual(dados["broadcast"], "192.168.0.255")
        self.assertEqual(dados["netmask"], "255.255.255.0")
        self.assertEqual(dados["usable_first"], "192.168.0.1")
        self.assertEqual(dados["usable_last"], "192.168.0.254")
        self.assertEqual(dados["usable_count"], 254)

    def test_host_fora_do_cidr_da_interface(self) -> None:
        dados = network.address_check(
            {"cidr": "192.168.0.7/24", "host_ip": "192.168.0.8", "vm_ip": "192.168.0.55"}
        )
        self.assertEqual(dados["host_matches_cidr"], 0)
        self.assertEqual(dados["accepted"], 0)

    def test_vm_nao_unicast(self) -> None:
        for vm in ("192.168.0.0", "192.168.0.255"):
            with self.subTest(vm=vm):
                dados = network.address_check(
                    {"cidr": "192.168.0.7/24", "host_ip": "192.168.0.7", "vm_ip": vm}
                )
                self.assertEqual(dados["vm_unicast"], 0)
                self.assertEqual(dados["accepted"], 0)

    def test_vm_em_outro_prefixo(self) -> None:
        dados = network.address_check(
            {"cidr": "192.168.0.7/24", "host_ip": "192.168.0.7", "vm_ip": "10.0.0.5"}
        )
        self.assertEqual(dados["vm_in_cidr"], 0)
        self.assertEqual(dados["vm_unicast"], 0)
        self.assertEqual(dados["accepted"], 0)

    def test_vm_igual_ao_host(self) -> None:
        dados = network.address_check(
            {"cidr": "192.168.0.7/24", "host_ip": "192.168.0.7", "vm_ip": "192.168.0.7"}
        )
        self.assertEqual(dados["distinct"], 0)
        self.assertEqual(dados["accepted"], 0)

    def test_prefixos_sem_unicast(self) -> None:
        for cidr in ("10.0.0.1/31", "10.0.0.1/32"):
            with self.subTest(cidr=cidr):
                dados = network.address_check(
                    {"cidr": cidr, "host_ip": "10.0.0.1", "vm_ip": "10.0.0.1"}
                )
                self.assertEqual(dados["usable_count"], 0)
                self.assertEqual(dados["usable_first"], "")
                self.assertEqual(dados["usable_last"], "")
                self.assertEqual(dados["vm_unicast"], 0)

    def test_recusas_explicitas(self) -> None:
        casos = (
            {"cidr": "fd00::/64", "host_ip": "192.168.0.7", "vm_ip": "192.168.0.8"},
            {"cidr": "192.168.0.7/24", "host_ip": "fd00::1", "vm_ip": "192.168.0.8"},
            {"cidr": "192.168.0.7/24", "host_ip": "192.168.0.7", "vm_ip": "::1"},
            {"cidr": "192.168.0.7", "host_ip": "192.168.0.7", "vm_ip": "192.168.0.8"},
            {"cidr": "192.168.0.7/24", "host_ip": "", "vm_ip": "192.168.0.8"},
        )
        for caso in casos:
            with self.subTest(caso=sorted(caso.items())):
                with self.assertRaises(DataError):
                    network.address_check(caso)

    def test_schema_fechado(self) -> None:
        with self.assertRaises(DataError):
            network.address_check({"cidr": "10.0.0.1/24", "host_ip": "10.0.0.1"})
        with self.assertRaises(DataError):
            network.address_check(
                {
                    "cidr": "10.0.0.1/24",
                    "host_ip": "10.0.0.1",
                    "vm_ip": "10.0.0.2",
                    "iface": "br0",
                }
            )


def gerenciada(**overrides) -> dict:
    base = {
        "bridge": "virbr9",
        "cidr": "192.168.177.0/24",
        "family": "ipv4",
        "gateway": "192.168.177.1",
        "present": True,
    }
    base.update(overrides)
    return base


AUSENTE = {
    "bridge": "",
    "cidr": "",
    "family": "",
    "gateway": "",
    "present": False,
}


def auditar(rotas, *, candidata: str = "192.168.177.0/24", managed=None) -> dict:
    return network.route_audit(
        {
            "candidate_cidr": candidata,
            "managed": gerenciada() if managed is None else managed,
            "routes": list(rotas),
        }
    )


def por_destino(dados: dict, destino: str) -> dict:
    for indice in range(dados["route_count"]):
        if dados["route_%d_destination" % indice] == destino:
            return {
                chave[len("route_%d_" % indice):]: valor
                for chave, valor in dados.items()
                if chave.startswith("route_%d_" % indice)
            }
    raise AssertionError("destino %s ausente na auditoria" % destino)


class RouteAuditExceptionTests(unittest.TestCase):
    def test_tres_classes_legitimas(self) -> None:
        rotas = [
            rota(tipo="unicast", destino="192.168.177.0/24", dev="virbr9"),
            rota(tipo="local", destino="192.168.177.1", dev="virbr9", escopo="host"),
            rota(tipo="broadcast", destino="192.168.177.0", dev="virbr9"),
            rota(tipo="broadcast", destino="192.168.177.255", dev="virbr9"),
        ]
        dados = auditar(rotas)
        self.assertEqual(dados["exception_count"], 4)
        self.assertEqual(dados["overlap_count"], 4)
        self.assertEqual(dados["collision_count"], 0)
        self.assertEqual(dados["collision"], 0)
        self.assertEqual(dados["collision_first_index"], -1)
        self.assertEqual(dados["collision_first_destination"], "")
        for destino in (
            "192.168.177.0/24",
            "192.168.177.1/32",
            "192.168.177.0/32",
            "192.168.177.255/32",
        ):
            with self.subTest(destino=destino):
                self.assertEqual(por_destino(dados, destino)["kernel_exception"], 1)

    def test_dispositivo_errado_colide(self) -> None:
        rotas = [rota(tipo="unicast", destino="192.168.177.0/24", dev="br0")]
        dados = auditar(rotas)
        self.assertEqual(dados["exception_count"], 0)
        self.assertEqual(dados["collision_count"], 1)
        self.assertEqual(dados["collision_first_device"], "br0")

    def test_gateway_errado_colide(self) -> None:
        rotas = [rota(tipo="local", destino="192.168.177.9", dev="virbr9")]
        dados = auditar(rotas)
        self.assertEqual(dados["exception_count"], 0)
        self.assertEqual(dados["collision_count"], 1)
        self.assertEqual(dados["collision_first_destination"], "192.168.177.9/32")

    def test_destino_fora_da_rede_gerenciada_colide(self) -> None:
        rotas = [rota(tipo="unicast", destino="192.168.177.128/25", dev="virbr9")]
        dados = auditar(rotas)
        self.assertEqual(dados["exception_count"], 0)
        self.assertEqual(dados["collision_count"], 1)

    def test_destino_nao_canonico_nao_e_excecao(self) -> None:
        # O Bash compara o destino como texto, então `192.168.177.5/24` não é a
        # rota conectada exata da rede gerenciada.
        rotas = [rota(tipo="unicast", destino="192.168.177.5/24", dev="virbr9")]
        dados = auditar(rotas)
        self.assertEqual(dados["exception_count"], 0)
        self.assertEqual(dados["collision_count"], 1)

    def test_broadcast_precisa_de_prefixo_32(self) -> None:
        rotas = [rota(tipo="broadcast", destino="192.168.177.255/31", dev="virbr9")]
        dados = auditar(rotas)
        self.assertEqual(dados["exception_count"], 0)
        self.assertEqual(dados["collision_count"], 1)

    def test_protocolo_diferente_de_kernel_colide(self) -> None:
        for protocolo in ("static", "boot", "dhcp", ""):
            with self.subTest(protocolo=protocolo):
                rotas = [
                    rota(
                        tipo="unicast",
                        destino="192.168.177.0/24",
                        dev="virbr9",
                        protocolo=protocolo,
                    )
                ]
                dados = auditar(rotas)
                self.assertEqual(dados["exception_count"], 0)
                self.assertEqual(dados["collision_count"], 1)

    def test_classe_outra_nunca_e_excecao(self) -> None:
        for tipo in ("blackhole", "prohibit", "throw", "unreachable"):
            with self.subTest(tipo=tipo):
                rotas = [
                    rota(
                        tipo=tipo,
                        destino="192.168.177.0/24",
                        dev="virbr9",
                        protocolo="kernel",
                    )
                ]
                dados = auditar(rotas)
                self.assertEqual(por_destino(dados, "192.168.177.0/24")["class"], "outra")
                self.assertEqual(dados["exception_count"], 0)
                self.assertEqual(dados["collision_count"], 1)

    def test_sem_rede_gerenciada_nao_ha_excecao(self) -> None:
        rotas = [
            rota(tipo="unicast", destino="192.168.177.0/24", dev="virbr9"),
            rota(tipo="local", destino="192.168.177.1", dev="virbr9"),
        ]
        dados = auditar(rotas, managed=AUSENTE)
        self.assertEqual(dados["has_exceptions"], 0)
        self.assertEqual(dados["managed_present"], 0)
        self.assertEqual(dados["exception_count"], 0)
        self.assertEqual(dados["collision_count"], 2)


class RouteAuditOverlapTests(unittest.TestCase):
    def test_rotas_disjuntas_nao_colidem(self) -> None:
        rotas = [
            rota(tipo="unicast", destino="10.0.0.0/8", dev="br0"),
            rota(tipo="unicast", destino="192.168.0.0/24", dev="br0"),
            rota(tipo="local", destino="127.0.0.1", dev="lo", escopo="host"),
        ]
        dados = auditar(rotas, managed=AUSENTE)
        self.assertEqual(dados["overlap_count"], 0)
        self.assertEqual(dados["collision_count"], 0)
        self.assertEqual(dados["route_count"], 3)

    def test_candidata_dentro_de_rota_maior(self) -> None:
        rotas = [rota(tipo="unicast", destino="192.168.0.0/16", dev="br0")]
        dados = auditar(rotas, managed=AUSENTE)
        self.assertEqual(dados["collision_count"], 1)
        self.assertEqual(dados["collision_first_destination"], "192.168.0.0/16")

    def test_rota_dentro_da_candidata(self) -> None:
        rotas = [rota(tipo="unicast", destino="192.168.177.64/26", dev="br0")]
        dados = auditar(rotas, managed=AUSENTE)
        self.assertEqual(dados["collision_count"], 1)

    def test_endereco_nu_vira_barra_32(self) -> None:
        rotas = [rota(tipo="local", destino="192.168.177.9", dev="br0", escopo="host")]
        dados = auditar(rotas, managed=AUSENTE)
        self.assertEqual(dados["route_0_destination"], "192.168.177.9/32")
        self.assertEqual(dados["route_0_network"], "192.168.177.9/32")
        self.assertEqual(dados["collision_count"], 1)

    def test_default_e_ignorado(self) -> None:
        rotas = [
            rota(
                tipo="unicast",
                destino="default",
                dev="br0",
                protocolo="dhcp",
                escopo="",
                gateway="192.168.0.1",
            )
        ]
        dados = auditar(rotas, managed=AUSENTE)
        self.assertEqual(dados["skipped_count"], 1)
        self.assertEqual(dados["route_0_class"], "default")
        self.assertEqual(dados["route_0_skipped"], 1)
        self.assertEqual(dados["route_0_overlaps"], 0)
        self.assertEqual(dados["collision_count"], 0)

    def test_rota_zero_barra_zero_explicita_colide(self) -> None:
        # Borda preservada do Bash: `default` é ignorado, `0.0.0.0/0` não.
        rotas = [rota(tipo="unicast", destino="0.0.0.0/0", dev="br0")]
        dados = auditar(rotas, managed=AUSENTE)
        self.assertEqual(dados["skipped_count"], 0)
        self.assertEqual(dados["collision_count"], 1)

    def test_rota_sem_dispositivo_ainda_colide(self) -> None:
        rotas = [
            rota(
                tipo="blackhole",
                destino="192.168.177.0/24",
                dev="",
                protocolo="",
                escopo="",
            )
        ]
        dados = auditar(rotas, managed=AUSENTE)
        self.assertEqual(dados["route_0_device"], "")
        self.assertEqual(dados["collision_count"], 1)

    def test_primeira_colisao_segue_a_ordem_canonica(self) -> None:
        rotas = [
            rota(tipo="unicast", destino="192.168.177.192/26", dev="br0"),
            rota(tipo="unicast", destino="192.168.177.0/26", dev="br0"),
            rota(tipo="unicast", destino="192.168.177.64/26", dev="br0"),
        ]
        dados = auditar(rotas, managed=AUSENTE)
        invertido = auditar(list(reversed(rotas)), managed=AUSENTE)
        self.assertEqual(dados, invertido)
        self.assertEqual(dados["collision_count"], 3)
        self.assertEqual(dados["collision_first_index"], 0)
        self.assertEqual(dados["collision_first_destination"], "192.168.177.0/26")

    def test_resumo_da_candidata(self) -> None:
        dados = auditar([], managed=AUSENTE, candidata="192.168.177.32/27")
        self.assertEqual(dados["candidate_cidr"], "192.168.177.32/27")
        self.assertEqual(dados["candidate_network"], "192.168.177.32")
        self.assertEqual(dados["candidate_broadcast"], "192.168.177.63")
        self.assertEqual(dados["route_count"], 0)

    def test_candidata_nao_canonica_e_mascarada(self) -> None:
        # `cidr_intervalo` (lib/common.sh:2160) mascara os bits de host.
        dados = auditar([], managed=AUSENTE, candidata="192.168.177.77/24")
        self.assertEqual(dados["candidate_cidr"], "192.168.177.0/24")


class RouteAuditRefusalTests(unittest.TestCase):
    def test_candidata_ipv6(self) -> None:
        with self.assertRaises(DataError) as contexto:
            auditar([], managed=AUSENTE, candidata="fd00::/64")
        self.assertIn("IPv6", str(contexto.exception))

    def test_candidata_sem_prefixo(self) -> None:
        with self.assertRaises(DataError):
            auditar([], managed=AUSENTE, candidata="192.168.177.0")

    def test_familia_nao_suportada(self) -> None:
        for familia in ("ipv6", "IPV4", "inet", ""):
            with self.subTest(familia=familia):
                with self.assertRaises(DataError) as contexto:
                    auditar([], managed=gerenciada(family=familia))
                self.assertIn("família", str(contexto.exception))

    def test_rede_gerenciada_ausente_com_residuo(self) -> None:
        for residuo in ("bridge", "cidr", "family", "gateway"):
            with self.subTest(residuo=residuo):
                ausente = dict(AUSENTE)
                ausente[residuo] = "x" if residuo != "family" else "ipv4"
                with self.assertRaises(DataError) as contexto:
                    auditar([], managed=ausente)
                self.assertIn("residual", str(contexto.exception))

    def test_cidr_gerenciado_nao_canonico(self) -> None:
        with self.assertRaises(DataError) as contexto:
            auditar([], managed=gerenciada(cidr="192.168.177.1/24"))
        self.assertIn("canônico", str(contexto.exception))

    def test_gateway_gerenciado_nao_unicast(self) -> None:
        for gateway in ("192.168.177.0", "192.168.177.255", "10.0.0.1"):
            with self.subTest(gateway=gateway):
                with self.assertRaises(DataError) as contexto:
                    auditar([], managed=gerenciada(gateway=gateway))
                self.assertIn("unicast", str(contexto.exception))

    def test_bridge_gerenciada_invalida(self) -> None:
        with self.assertRaises(DataError):
            auditar([], managed=gerenciada(bridge="virbr 9"))

    def test_destino_de_rota_ipv6(self) -> None:
        rotas = [rota(tipo="unicast", destino="fd00::/64", dev="br0")]
        with self.assertRaises(DataError) as contexto:
            auditar(rotas, managed=AUSENTE)
        self.assertIn("IPv6", str(contexto.exception))

    def test_destino_de_rota_invalido(self) -> None:
        for destino in ("10.0.0.999/24", "10.0.0.0/33", "10.0.0.0/024", "010.0.0.0/8"):
            with self.subTest(destino=destino):
                with self.assertRaises(DataError):
                    auditar(
                        [rota(tipo="unicast", destino=destino, dev="br0")],
                        managed=AUSENTE,
                    )

    def test_schema_fechado_da_auditoria(self) -> None:
        with self.assertRaises(DataError):
            network.route_audit({"candidate_cidr": "10.0.0.0/24", "routes": []})
        with self.assertRaises(DataError):
            network.route_audit(
                {
                    "candidate_cidr": "10.0.0.0/24",
                    "managed": AUSENTE,
                    "routes": [],
                    "tabela": "all",
                }
            )
        with self.assertRaises(DataError):
            network.route_audit(
                {
                    "candidate_cidr": "10.0.0.0/24",
                    "managed": dict(AUSENTE, extra=1),
                    "routes": [],
                }
            )
        with self.assertRaises(DataError):
            network.route_audit(
                {
                    "candidate_cidr": "10.0.0.0/24",
                    "managed": AUSENTE,
                    "routes": {},
                }
            )


class ParsingHelperTests(unittest.TestCase):
    def test_familia_suportada(self) -> None:
        self.assertEqual(network.require_supported_family("ipv4", "x"), "ipv4")

    def test_parse_de_endereco(self) -> None:
        self.assertEqual(str(network.parse_ipv4_address("10.0.0.1", "x")), "10.0.0.1")
        with self.assertRaises(DataError):
            network.parse_ipv4_address("10.0.0.01", "x")

    def test_parse_de_cidr_devolve_literal_e_mascara(self) -> None:
        endereco, prefixo, rede = network.parse_ipv4_cidr("192.168.9.5/24", "x")
        self.assertEqual(str(endereco), "192.168.9.5")
        self.assertEqual(prefixo, 24)
        self.assertEqual(str(rede), "192.168.9.0/24")

    def test_unicast_estrito_como_no_bash(self) -> None:
        rede = ipaddress.IPv4Network("192.168.0.0/24")
        for endereco, esperado in (
            ("192.168.0.0", False),
            ("192.168.0.1", True),
            ("192.168.0.254", True),
            ("192.168.0.255", False),
            ("192.168.1.1", False),
        ):
            with self.subTest(endereco=endereco):
                self.assertEqual(
                    network._is_unicast_in(ipaddress.IPv4Address(endereco), rede),
                    esperado,
                )

    def test_blocos_privados_sao_os_do_bash(self) -> None:
        self.assertEqual(
            [str(bloco) for bloco in network.PRIVATE_BLOCKS],
            ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"],
        )


class DeterminismTests(unittest.TestCase):
    def _canonico(self, valor) -> str:
        return json.dumps(valor, ensure_ascii=False, sort_keys=True, separators=(",", ":"))

    def test_mesma_entrada_mesma_saida(self) -> None:
        rotas = [
            rota(tipo="unicast", destino="192.168.177.0/24", dev="virbr9"),
            rota(tipo="local", destino="192.168.177.1", dev="virbr9", escopo="host"),
            rota(tipo="unicast", destino="10.0.0.0/8", dev="br0"),
            rota(tipo="unicast", destino="default", dev="br0", protocolo="dhcp"),
        ]
        chamadas = (
            lambda: network.nat_addresses({"cidr": "192.168.177.0/24"}),
            lambda: network.address_check(
                {
                    "cidr": "192.168.177.1/24",
                    "host_ip": "192.168.177.1",
                    "vm_ip": "192.168.177.10",
                }
            ),
            lambda: auditar(rotas),
            lambda: network.normalize_snapshot(snapshot()),
            lambda: network.snapshot_fingerprints(snapshot()),
            lambda: network.intent_fingerprints(intencao()),
        )
        for indice, chamada in enumerate(chamadas):
            with self.subTest(chamada=indice):
                primeira = self._canonico(chamada())
                segunda = self._canonico(chamada())
                self.assertEqual(primeira, segunda)

    def test_entrada_nao_e_mutada(self) -> None:
        payload = snapshot()
        antes = self._canonico(payload)
        network.snapshot_fingerprints(payload)
        self.assertEqual(self._canonico(payload), antes)


if __name__ == "__main__":
    unittest.main()
