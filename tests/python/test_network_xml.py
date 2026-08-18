"""Inspeção do XML de rede libvirt (I3.4)."""
import unittest

from passthrough_core import network_xml
from passthrough_core.errors import DataError

import fixtures_i3 as fx


class InspectTests(unittest.TestCase):
    def test_rede_gerenciada_completa(self) -> None:
        dados = network_xml.inspect_network(
            {
                "xml": fx.network(),
                "marker": fx.MARCADOR,
                "nic_mac": fx.NIC_MAC,
                "vm_ip": "192.168.77.10",
            }
        )
        self.assertEqual(dados["name"], "vm-passthrough-nat")
        self.assertEqual(dados["marker_match"], 1)
        self.assertEqual(dados["forward_count"], 1)
        self.assertEqual(dados["forward_mode"], "nat")
        self.assertEqual(dados["forward_dev"], "enp3s0")
        self.assertEqual(dados["bridge_name"], "virbr9")
        self.assertEqual(dados["bridge_stp"], "on")
        self.assertEqual(dados["ip_count"], 1)
        self.assertEqual(dados["ip_0_address"], "192.168.77.1")
        self.assertEqual(dados["ip_0_prefix"], 24)
        self.assertEqual(dados["ip_0_network"], "192.168.77.0")
        self.assertEqual(dados["ip_0_broadcast"], "192.168.77.255")
        self.assertEqual(dados["dhcp_range_count"], 1)
        self.assertEqual(dados["dhcp_range_start"], "192.168.77.100")
        self.assertEqual(dados["dhcp_range_end"], "192.168.77.254")
        self.assertEqual(dados["dhcp_mac_count"], 1)
        self.assertEqual(dados["dhcp_mac_ip"], "192.168.77.10")
        self.assertEqual(dados["dhcp_ip_count"], 1)
        self.assertRegex(dados["fingerprint"], r"^[0-9a-f]{64}$")

    def test_rede_homonima_sem_marcador(self) -> None:
        dados = network_xml.inspect_network(
            {"xml": fx.network(descricao="outra ferramenta"), "marker": fx.MARCADOR}
        )
        self.assertEqual(dados["marker_match"], 0)
        self.assertEqual(dados["description"], "outra ferramenta")

    def test_rede_sem_descricao(self) -> None:
        dados = network_xml.inspect_network(
            {"xml": fx.network(descricao=None), "marker": fx.MARCADOR}
        )
        self.assertEqual(dados["marker_match"], 0)
        self.assertEqual(dados["description"], "")

    def test_marcador_nao_informado_nunca_casa(self) -> None:
        dados = network_xml.inspect_network({"xml": fx.network()})
        self.assertEqual(dados["marker_match"], 0)

    def test_prefixo_derivado_da_netmask(self) -> None:
        ips = "<ip address='10.20.30.1' netmask='255.255.254.0'/>"
        dados = network_xml.inspect_network({"xml": fx.network(ips=ips)})
        self.assertEqual(dados["ip_0_prefix"], 23)
        self.assertEqual(dados["ip_0_network"], "10.20.30.0")

    def test_prefixo_explicito(self) -> None:
        ips = "<ip address='10.20.30.1' prefix='30'/>"
        dados = network_xml.inspect_network({"xml": fx.network(ips=ips)})
        self.assertEqual(dados["ip_0_prefix"], 30)
        self.assertEqual(dados["ip_0_broadcast"], "10.20.30.3")

    def test_ip_sem_prefixo_nem_netmask(self) -> None:
        with self.assertRaises(DataError) as contexto:
            network_xml.inspect_network({"xml": fx.network(ips="<ip address='10.0.0.1'/>")})
        self.assertIn("sem prefixo", str(contexto.exception))

    def test_netmask_invalida(self) -> None:
        ips = "<ip address='10.0.0.1' netmask='255.0.255.0'/>"
        with self.assertRaises(DataError):
            network_xml.inspect_network({"xml": fx.network(ips=ips)})

    def test_endereco_invalido(self) -> None:
        ips = "<ip address='10.0.0.999' netmask='255.255.255.0'/>"
        with self.assertRaises(DataError):
            network_xml.inspect_network({"xml": fx.network(ips=ips)})

    def test_ipv6_ignorado_no_calculo_mas_reportado(self) -> None:
        ips = (
            "<ip family='ipv6' address='fd00::1' prefix='64'/>"
            "<ip address='192.168.77.1' netmask='255.255.255.0'/>"
        )
        dados = network_xml.inspect_network({"xml": fx.network(ips=ips)})
        self.assertEqual(dados["ip_count"], 2)
        self.assertEqual(dados["ip_0_family"], "ipv6")
        self.assertEqual(dados["ip_0_prefix"], 0)
        self.assertEqual(dados["ip_1_family"], "ipv4")
        self.assertEqual(dados["ip_1_prefix"], 24)

    def test_dois_blocos_ip_nao_elegem_o_primeiro(self) -> None:
        ips = (
            "<ip address='192.168.77.1' netmask='255.255.255.0'/>"
            "<ip address='192.168.88.1' netmask='255.255.255.0'/>"
        )
        dados = network_xml.inspect_network({"xml": fx.network(ips=ips)})
        self.assertEqual(dados["ip_count"], 2)
        self.assertEqual(dados["ip_1_address"], "192.168.88.1")

    def test_reserva_dhcp_duplicada(self) -> None:
        ips = (
            "<ip address='192.168.77.1' netmask='255.255.255.0'><dhcp>"
            "<host mac='%s' ip='192.168.77.10'/>"
            "<host mac='%s' ip='192.168.77.11'/>"
            "</dhcp></ip>" % (fx.NIC_MAC, fx.NIC_MAC)
        )
        dados = network_xml.inspect_network(
            {"xml": fx.network(ips=ips), "nic_mac": fx.NIC_MAC}
        )
        self.assertEqual(dados["dhcp_mac_count"], 2)
        self.assertEqual(dados["dhcp_mac_ip"], "")

    def test_dois_ranges_no_mesmo_ip(self) -> None:
        ips = (
            "<ip address='192.168.77.1' netmask='255.255.255.0'><dhcp>"
            "<range start='192.168.77.100' end='192.168.77.150'/>"
            "<range start='192.168.77.200' end='192.168.77.250'/>"
            "</dhcp></ip>"
        )
        dados = network_xml.inspect_network({"xml": fx.network(ips=ips)})
        self.assertEqual(dados["dhcp_range_count"], 2)
        self.assertEqual(dados["dhcp_range_start"], "")

    def test_dhcp_duplicado_no_ip(self) -> None:
        ips = (
            "<ip address='192.168.77.1' netmask='255.255.255.0'>"
            "<dhcp/><dhcp/></ip>"
        )
        with self.assertRaises(DataError):
            network_xml.inspect_network({"xml": fx.network(ips=ips)})

    def test_forward_duplicado_e_reportado(self) -> None:
        with self.assertRaises(DataError):
            network_xml.inspect_network(
                {
                    "xml": fx.network(
                        forward="<forward mode='nat'/><forward mode='route'/>"
                    )
                }
            )

    def test_bridge_duplicada(self) -> None:
        with self.assertRaises(DataError):
            network_xml.inspect_network(
                {"xml": fx.network(bridge="<bridge name='a'/><bridge name='b'/>")}
            )

    def test_nome_de_rede_invalido(self) -> None:
        with self.assertRaises(DataError):
            network_xml.inspect_network({"xml": fx.network(nome="rede com espaço")})

    def test_nome_de_bridge_invalido(self) -> None:
        with self.assertRaises(DataError):
            network_xml.inspect_network(
                {"xml": fx.network(bridge="<bridge name='br com espaço'/>")}
            )

    def test_uuid_invalido(self) -> None:
        with self.assertRaises(DataError):
            network_xml.inspect_network({"xml": fx.network(uuid="não-uuid")})

    def test_sem_uuid(self) -> None:
        dados = network_xml.inspect_network({"xml": fx.network(uuid="")})
        self.assertEqual(dados["uuid"], "")

    def test_mac_de_reserva_invalido(self) -> None:
        ips = (
            "<ip address='192.168.77.1' netmask='255.255.255.0'><dhcp>"
            "<host mac='zz' ip='192.168.77.10'/></dhcp></ip>"
        )
        with self.assertRaises(DataError):
            network_xml.inspect_network({"xml": fx.network(ips=ips)})

    def test_limite_de_blocos_ip(self) -> None:
        ips = "".join(
            "<ip address='10.0.%d.1' netmask='255.255.255.0'/>" % indice
            for indice in range(network_xml.MAX_IP_ENTRIES + 1)
        )
        with self.assertRaises(DataError) as contexto:
            network_xml.inspect_network({"xml": fx.network(ips=ips)})
        self.assertIn("limite", str(contexto.exception))

    def test_limite_de_reservas_dhcp(self) -> None:
        hosts = "".join(
            "<host mac='52:54:00:00:%02x:%02x' ip='10.0.0.%d'/>"
            % (indice // 256, indice % 256, indice % 250 + 2)
            for indice in range(network_xml.MAX_DHCP_HOSTS + 1)
        )
        ips = (
            "<ip address='10.0.0.1' netmask='255.255.0.0'><dhcp>"
            + hosts
            + "</dhcp></ip>"
        )
        with self.assertRaises(DataError):
            network_xml.inspect_network({"xml": fx.network(ips=ips)})

    def test_raiz_errada(self) -> None:
        with self.assertRaises(DataError):
            network_xml.inspect_network({"xml": fx.domain()})

    def test_payload_incompleto(self) -> None:
        with self.assertRaises(DataError):
            network_xml.inspect_network({})

    def test_mac_do_payload_invalido(self) -> None:
        with self.assertRaises(DataError):
            network_xml.inspect_network({"xml": fx.network(), "nic_mac": "zz"})

    def test_vm_ip_do_payload_invalido(self) -> None:
        with self.assertRaises(DataError):
            network_xml.inspect_network({"xml": fx.network(), "vm_ip": "300.1.1.1"})


class OverlapTests(unittest.TestCase):
    def test_sem_colisao(self) -> None:
        dados = network_xml.network_overlap(
            {"xml": fx.network(), "candidate_cidr": "192.168.88.0/24"}
        )
        self.assertEqual(dados["overlap_count"], 0)
        self.assertEqual(dados["overlap_cidr"], "")

    def test_colisao_exata(self) -> None:
        dados = network_xml.network_overlap(
            {"xml": fx.network(), "candidate_cidr": "192.168.77.0/24"}
        )
        self.assertEqual(dados["overlap_count"], 1)
        self.assertEqual(dados["overlap_cidr"], "192.168.77.0/24")

    def test_colisao_por_contencao(self) -> None:
        dados = network_xml.network_overlap(
            {"xml": fx.network(), "candidate_cidr": "192.168.0.0/16"}
        )
        self.assertEqual(dados["overlap_count"], 1)

    def test_cidr_candidato_invalido(self) -> None:
        for candidato in ("", "192.168.77.0/33", "10.0.0.0/x", "nada"):
            with self.assertRaises(DataError):
                network_xml.network_overlap(
                    {"xml": fx.network(), "candidate_cidr": candidato}
                )

    def test_ipv6_nao_participa(self) -> None:
        ips = "<ip family='ipv6' address='fd00::1' prefix='64'/>"
        dados = network_xml.network_overlap(
            {"xml": fx.network(ips=ips), "candidate_cidr": "192.168.77.0/24"}
        )
        self.assertEqual(dados["overlap_count"], 0)


if __name__ == "__main__":
    unittest.main()
