"""Inspeção cardinalizada e candidatos do XML de domínio (I3.1, I3.2, I3.3)."""
import unittest

from passthrough_core import domain_xml, xmlutil
from passthrough_core.errors import DataError

import fixtures_i3 as fx


class DiskTargetTests(unittest.TestCase):
    def test_discard_ausente(self) -> None:
        dados = domain_xml.disk_target_state(
            {"xml": fx.domain(), "qcow2_path": fx.QCOW2}
        )
        self.assertEqual(dados["state"], "ausente")
        self.assertEqual(dados["discard"], "")
        self.assertEqual(dados["target_dev"], "vda")
        self.assertEqual(dados["driver_type"], "qcow2")
        self.assertRegex(dados["fingerprint"], r"^[0-9a-f]{64}$")

    def test_discard_ativo(self) -> None:
        dados = domain_xml.disk_target_state(
            {"xml": fx.domain(discard="unmap"), "qcow2_path": fx.QCOW2}
        )
        self.assertEqual(dados["state"], "ativo")
        self.assertEqual(dados["discard"], "unmap")

    def test_alvo_ausente(self) -> None:
        with self.assertRaises(DataError) as contexto:
            domain_xml.disk_target_state(
                {"xml": fx.domain(), "qcow2_path": "/vm/outro.qcow2"}
            )
        self.assertIn("esperado 1", str(contexto.exception))

    def test_alvo_duplicado(self) -> None:
        duplicado = (
            "<disk type='file' device='disk'>"
            "<driver name='qemu' type='qcow2'/>"
            "<source file='%s'/><target dev='vdc' bus='virtio'/></disk>" % fx.QCOW2
        )
        with self.assertRaises(DataError) as contexto:
            domain_xml.disk_target_state(
                {"xml": fx.domain(extra_disks=duplicado), "qcow2_path": fx.QCOW2}
            )
        self.assertIn("esperado 1", str(contexto.exception))

    def test_fontes_duplicadas_no_alvo(self) -> None:
        xml = fx.domain().replace(
            "<source file='%s'/>" % fx.QCOW2,
            "<source file='%s'/><source file='%s'/>" % (fx.QCOW2, fx.QCOW2),
        )
        with self.assertRaises(DataError) as contexto:
            domain_xml.disk_target_state({"xml": xml, "qcow2_path": fx.QCOW2})
        # A recusa acontece na projeção dos discos, antes da seleção do alvo:
        # cardinalidade de <source> maior que um é sempre erro tipado.
        self.assertIn("<source> aparece 2 vezes", str(contexto.exception))

    def test_driver_duplicado_no_alvo(self) -> None:
        xml = fx.domain().replace(
            "<driver name='qemu' type='qcow2'/>",
            "<driver name='qemu' type='qcow2'/><driver name='qemu' type='raw'/>",
        )
        with self.assertRaises(DataError) as contexto:
            domain_xml.disk_target_state({"xml": xml, "qcow2_path": fx.QCOW2})
        self.assertIn("<driver> aparece 2 vezes", str(contexto.exception))

    def test_devices_duplicado(self) -> None:
        xml = fx.domain().replace("</devices>", "</devices><devices/>")
        with self.assertRaises(DataError):
            domain_xml.disk_target_state({"xml": xml, "qcow2_path": fx.QCOW2})

    def test_alvo_de_disco_duplicado_recusado(self) -> None:
        colidente = (
            "<disk type='file' device='cdrom'>"
            "<driver name='qemu' type='raw'/>"
            "<source file='/vm/x.iso'/><target dev='vda' bus='virtio'/></disk>"
        )
        with self.assertRaises(DataError) as contexto:
            domain_xml.disk_target_state(
                {"xml": fx.domain(extra_disks=colidente), "qcow2_path": fx.QCOW2}
            )
        self.assertIn("duplicado", str(contexto.exception))

    def test_campos_obrigatorios(self) -> None:
        with self.assertRaises(DataError):
            domain_xml.disk_target_state({"qcow2_path": fx.QCOW2})
        with self.assertRaises(DataError):
            domain_xml.disk_target_state({"xml": fx.domain()})


class HostdevTests(unittest.TestCase):
    def test_ausente(self) -> None:
        dados = domain_xml.hostdev_pci_state(
            {"xml": fx.domain(), "pci_address": fx.GPU_BDF}
        )
        self.assertEqual((dados["total"], dados["exact"]), (0, 0))

    def test_exato(self) -> None:
        dados = domain_xml.hostdev_pci_state(
            {"xml": fx.domain(hostdevs=fx.HOSTDEV_GPU), "pci_address": fx.GPU_BDF}
        )
        self.assertEqual((dados["total"], dados["exact"]), (1, 1))
        self.assertEqual(dados["managed"], "yes")

    def test_sem_managed(self) -> None:
        dados = domain_xml.hostdev_pci_state(
            {
                "xml": fx.domain(hostdevs=fx.HOSTDEV_GPU_SEM_MANAGED),
                "pci_address": fx.GPU_BDF,
            }
        )
        self.assertEqual((dados["total"], dados["exact"]), (1, 0))

    def test_duplicado(self) -> None:
        dados = domain_xml.hostdev_pci_state(
            {
                "xml": fx.domain(hostdevs=fx.HOSTDEV_GPU + fx.HOSTDEV_GPU),
                "pci_address": fx.GPU_BDF,
            }
        )
        self.assertEqual((dados["total"], dados["exact"]), (2, 2))
        self.assertEqual(dados["managed"], "")

    def test_hexadecimal_sem_prefixo_e_com_maiuscula(self) -> None:
        variante = fx.HOSTDEV_GPU.replace(
            "domain='0x0000' bus='0x0a' slot='0x00' function='0x0'",
            "domain='0000' bus='0xA' slot='0x0' function='0'",
        )
        dados = domain_xml.hostdev_pci_state(
            {"xml": fx.domain(hostdevs=variante), "pci_address": fx.GPU_BDF}
        )
        self.assertEqual((dados["total"], dados["exact"]), (1, 1))

    def test_bdf_invalido(self) -> None:
        for endereco in ("", "0a:00.0", "0000:0a:00.8", "zzzz:0a:00.0", "0000:0a:00"):
            with self.assertRaises(DataError):
                domain_xml.hostdev_pci_state(
                    {"xml": fx.domain(), "pci_address": endereco}
                )

    def test_endereco_com_hex_invalido_no_xml(self) -> None:
        ruim = fx.HOSTDEV_GPU.replace("bus='0x0a'", "bus='0xzz'")
        dados = domain_xml.hostdev_pci_state(
            {"xml": fx.domain(hostdevs=ruim), "pci_address": fx.GPU_BDF}
        )
        self.assertEqual(dados["total"], 0)


class DiskBlockTests(unittest.TestCase):
    def test_ausente(self) -> None:
        dados = domain_xml.disk_block_state(
            {"xml": fx.domain(), "block_path": fx.HD1}
        )
        self.assertEqual(
            (dados["source_count"], dados["exact_count"], dados["target_count"]),
            (0, 0, 0),
        )

    def test_exato(self) -> None:
        dados = domain_xml.disk_block_state(
            {"xml": fx.domain(extra_disks=fx.DISCO_HD1), "block_path": fx.HD1}
        )
        self.assertEqual(
            (dados["source_count"], dados["exact_count"], dados["target_count"]),
            (1, 1, 1),
        )

    def test_atributos_divergentes(self) -> None:
        divergente = fx.DISCO_HD1.replace("cache='none'", "cache='writeback'")
        dados = domain_xml.disk_block_state(
            {"xml": fx.domain(extra_disks=divergente), "block_path": fx.HD1}
        )
        self.assertEqual((dados["source_count"], dados["exact_count"]), (1, 0))

    def test_alvo_ocupado_por_outro_disco(self) -> None:
        outro = fx.DISCO_HD1.replace(fx.HD1, "/dev/disk/by-id/ata-OUTRO")
        dados = domain_xml.disk_block_state(
            {"xml": fx.domain(extra_disks=outro), "block_path": fx.HD1}
        )
        self.assertEqual((dados["source_count"], dados["target_count"]), (0, 1))

    def test_alvo_invalido(self) -> None:
        with self.assertRaises(DataError):
            domain_xml.disk_block_state(
                {"xml": fx.domain(), "block_path": fx.HD1, "target_dev": "vd b"}
            )

    def test_identidade_fisica_projetada(self) -> None:
        com_wwn = fx.DISCO_HD1.replace(
            "</disk>", "<wwn>0x5000c500a1b2c3d4</wwn><serial>FIXTURE1</serial></disk>"
        )
        dados = domain_xml.disk_block_state(
            {"xml": fx.domain(extra_disks=com_wwn), "block_path": fx.HD1}
        )
        self.assertEqual(dados["identity_count"], 1)


class UsbTests(unittest.TestCase):
    def test_sem_usb(self) -> None:
        dados = domain_xml.usb_hostdev_list({"xml": fx.domain()})
        self.assertEqual(dados["usb_count"], 0)
        self.assertEqual(dados["ambiguous_pairs"], 0)

    def test_um_dispositivo(self) -> None:
        dados = domain_xml.usb_hostdev_list(
            {"xml": fx.domain(hostdevs=fx.HOSTDEV_USB)}
        )
        self.assertEqual(dados["usb_count"], 1)
        self.assertEqual(dados["usb_0_vendor"], "0x046d")
        self.assertEqual(dados["usb_0_product"], "0xc52b")
        self.assertEqual(dados["usb_0_managed"], "yes")
        self.assertEqual(dados["ambiguous_pairs"], 0)

    def test_par_duplicado_marcado_como_ambiguo(self) -> None:
        dados = domain_xml.usb_hostdev_list(
            {"xml": fx.domain(hostdevs=fx.HOSTDEV_USB + fx.HOSTDEV_USB)}
        )
        self.assertEqual(dados["usb_count"], 2)
        self.assertEqual(dados["ambiguous_pairs"], 1)

    def test_endereco_fisico_como_discriminador(self) -> None:
        por_porta = (
            "<hostdev mode='subsystem' type='usb' managed='yes'>"
            "<source><address bus='1' device='4'/></source></hostdev>"
        )
        dados = domain_xml.usb_hostdev_list({"xml": fx.domain(hostdevs=por_porta)})
        self.assertEqual(dados["usb_0_bus"], "1")
        self.assertEqual(dados["usb_0_device"], "4")
        self.assertEqual(dados["usb_0_vendor"], "")

    def test_sem_discriminador_recusado(self) -> None:
        with self.assertRaises(DataError) as contexto:
            domain_xml.usb_hostdev_list(
                {"xml": fx.domain(hostdevs=fx.HOSTDEV_USB_SEM_DISCRIMINADOR)}
            )
        self.assertIn("discriminador", str(contexto.exception))

    def test_id_fora_do_formato(self) -> None:
        ruim = fx.HOSTDEV_USB.replace("0x046d", "046d")
        with self.assertRaises(DataError):
            domain_xml.usb_hostdev_list({"xml": fx.domain(hostdevs=ruim)})

    def test_source_duplicado(self) -> None:
        ruim = fx.HOSTDEV_USB.replace("</hostdev>", "<source/></hostdev>")
        with self.assertRaises(DataError):
            domain_xml.usb_hostdev_list({"xml": fx.domain(hostdevs=ruim)})

    def _usb_operation(self, state: str = "present", bus: str = "1", device: str = "7") -> dict:
        options = {
            "state": state, "identity_kind": "serial", "identity_sha256": "a" * 64,
            "vendor": "046d", "product": "c52b", "bus": bus, "device": device,
        }
        if state == "absent":
            options.update({"bus": "", "device": ""})
        return {"xml": fx.domain(), "operations": [{"op": "usb-hostdev", "options": options}]}

    def test_candidato_usb_presente_idempotente_e_renumerado(self) -> None:
        dados, candidato = domain_xml.build_candidate(self._usb_operation())
        self.assertEqual(dados["changed"], 1)
        projetado = domain_xml.usb_hostdev_list({"xml": candidato})
        self.assertEqual(projetado["usb_count"], 1)
        self.assertEqual(projetado["usb_0_identity_kind"], "serial")
        self.assertEqual(projetado["usb_0_identity_sha256"], "a" * 64)
        self.assertEqual((projetado["usb_0_bus"], projetado["usb_0_device"]), ("1", "7"))

        payload = self._usb_operation()
        payload["xml"] = candidato
        dados_2, candidato_2 = domain_xml.build_candidate(payload)
        self.assertEqual(dados_2["changed"], 0)
        self.assertEqual(candidato_2, candidato)

        payload["operations"][0]["options"].update({"bus": "4", "device": "22"})
        dados_3, candidato_3 = domain_xml.build_candidate(payload)
        self.assertEqual(dados_3["changed"], 1)
        projetado_3 = domain_xml.usb_hostdev_list({"xml": candidato_3})
        self.assertEqual((projetado_3["usb_0_bus"], projetado_3["usb_0_device"]), ("4", "22"))

    def test_candidato_usb_remove_exatamente_binding(self) -> None:
        _dados, candidato = domain_xml.build_candidate(self._usb_operation())
        payload = self._usb_operation("absent")
        payload["xml"] = candidato
        removido, xml_removido = domain_xml.build_candidate(payload)
        self.assertEqual(removido["changed"], 1)
        self.assertEqual(domain_xml.usb_hostdev_list({"xml": xml_removido})["usb_count"], 0)
        payload["xml"] = xml_removido
        no_op, _ = domain_xml.build_candidate(payload)
        self.assertEqual(no_op["changed"], 0)

    def test_dois_bindings_estaveis_do_mesmo_par_nao_sao_ambiguos(self) -> None:
        _first, xml_first = domain_xml.build_candidate(self._usb_operation())
        second = self._usb_operation(bus="2", device="8")
        second["xml"] = xml_first
        second["operations"][0]["options"]["identity_sha256"] = "b" * 64
        _data, xml_second = domain_xml.build_candidate(second)
        projected = domain_xml.usb_hostdev_list({"xml": xml_second})
        self.assertEqual(projected["usb_count"], 2)
        self.assertEqual(projected["ambiguous_pairs"], 0)

    def test_migra_hostdev_legado_com_alias_e_endereco_sem_duplicar(self) -> None:
        legacy = (
            "<hostdev mode='subsystem' type='usb' managed='yes'><source>"
            "<vendor id='0x046d'/><product id='0xc52b'/>"
            "<address bus='1' device='7'/></source><alias name='hostdev0'/></hostdev>"
        )
        payload = self._usb_operation()
        payload["xml"] = fx.domain(hostdevs=legacy)
        _data, migrated = domain_xml.build_candidate(payload)
        projected = domain_xml.usb_hostdev_list({"xml": migrated})
        self.assertEqual(projected["usb_count"], 1)
        self.assertEqual(projected["usb_0_identity_sha256"], "a" * 64)
        self.assertNotEqual(projected["usb_0_alias"], "hostdev0")

    def test_metadata_usb_orfa_e_duplicada_recusadas(self) -> None:
        metadata = (
            "<metadata><v:passthrough xmlns:v='%s'><v:usb-bindings>"
            "<v:usb-binding alias='ua-vmpass-usb-aaaaaaaaaaaaaaaaaaaa' identity-kind='serial' "
            "identity-sha256='%s' vendor='0x046d' product='0xc52b'/>"
            "</v:usb-bindings></v:passthrough></metadata>"
            % (domain_xml.METADATA_NAMESPACE, "a" * 64)
        )
        with self.assertRaises(DataError):
            domain_xml.usb_hostdev_list({"xml": fx.domain(metadata=metadata)})
        duplicada = metadata.replace("</v:usb-bindings>", metadata.split("<v:usb-bindings>", 1)[1].split("</v:usb-bindings>", 1)[0] + "</v:usb-bindings>")
        with self.assertRaises(DataError):
            domain_xml.usb_hostdev_list({"xml": fx.domain(metadata=duplicada)})


class InterfaceTests(unittest.TestCase):
    def test_uma_nic_identificada_por_mac(self) -> None:
        dados = domain_xml.interface_state(
            {"xml": fx.domain(), "nic_mac": fx.NIC_MAC, "network_name": "default"}
        )
        self.assertEqual(dados["nic_count"], 1)
        self.assertEqual(dados["mac_count"], 1)
        self.assertEqual(dados["mac_type"], "network")
        self.assertEqual(dados["mac_network"], "default")
        self.assertEqual(dados["network_match_count"], 1)
        self.assertEqual(dados["network_match_mac"], fx.NIC_MAC.lower())
        self.assertEqual(dados["consumer_count"], 1)
        self.assertEqual(dados["nic_0_mac"], fx.NIC_MAC.lower())

    def test_mac_maiusculo_no_xml_e_no_filtro(self) -> None:
        xml = fx.domain(
            interfaces="<interface type='network'>"
            "<mac address='52:54:00:AB:CD:EF'/><source network='default'/>"
            "</interface>"
        )
        dados = domain_xml.interface_state(
            {"xml": xml, "nic_mac": "52:54:00:ab:CD:ef"}
        )
        self.assertEqual(dados["mac_count"], 1)
        self.assertEqual(dados["nic_0_mac"], "52:54:00:ab:cd:ef")

    def test_zero_nics(self) -> None:
        dados = domain_xml.interface_state({"xml": fx.domain(interfaces="")})
        self.assertEqual(dados["nic_count"], 0)
        self.assertEqual(dados["network_match_count"], 0)
        self.assertEqual(dados["network_match_mac"], "")

    def test_duas_nics_na_mesma_rede_nao_elegem_a_primeira(self) -> None:
        duas = (
            "<interface type='network'><mac address='52:54:00:11:11:11'/>"
            "<source network='default'/></interface>"
            "<interface type='network'><mac address='52:54:00:22:22:22'/>"
            "<source network='default'/></interface>"
        )
        dados = domain_xml.interface_state(
            {"xml": fx.domain(interfaces=duas), "network_name": "default"}
        )
        self.assertEqual(dados["network_match_count"], 2)
        self.assertEqual(dados["network_match_mac"], "")

    def test_mac_duplicado(self) -> None:
        duplicado = (
            "<interface type='network'><mac address='%s'/>"
            "<source network='default'/></interface>" % fx.NIC_MAC
        ) * 2
        dados = domain_xml.interface_state(
            {"xml": fx.domain(interfaces=duplicado), "nic_mac": fx.NIC_MAC}
        )
        self.assertEqual(dados["mac_count"], 2)
        self.assertEqual(dados["mac_type"], "")

    def test_consumidores_por_bridge(self) -> None:
        bridge = (
            "<interface type='bridge'><mac address='52:54:00:33:33:33'/>"
            "<source bridge='br-vm'/></interface>"
        )
        dados = domain_xml.interface_state(
            {
                "xml": fx.domain(interfaces=bridge),
                "network_name": "vm-passthrough-nat",
                "bridge_names": ["br-outra", "br-vm"],
            }
        )
        self.assertEqual(dados["consumer_count"], 1)

    def test_bridge_names_em_texto_do_canal_de_pares(self) -> None:
        bridge = (
            "<interface type='bridge'><mac address='52:54:00:33:33:33'/>"
            "<source bridge='br-vm'/></interface>"
        )
        dados = domain_xml.interface_state(
            {"xml": fx.domain(interfaces=bridge), "bridge_names": "br-outra\nbr-vm"}
        )
        self.assertEqual(dados["consumer_count"], 1)

    def test_interface_sem_mac(self) -> None:
        sem_mac = "<interface type='network'><source network='default'/></interface>"
        dados = domain_xml.interface_state(
            {"xml": fx.domain(interfaces=sem_mac), "nic_mac": fx.NIC_MAC}
        )
        self.assertEqual(dados["nic_count"], 1)
        self.assertEqual(dados["mac_count"], 0)

    def test_mac_invalido_no_xml(self) -> None:
        ruim = "<interface type='network'><mac address='xx:yy'/></interface>"
        with self.assertRaises(DataError):
            domain_xml.interface_state({"xml": fx.domain(interfaces=ruim)})

    def test_limite_de_itens(self) -> None:
        muitas = "".join(
            "<interface type='network'><mac address='52:54:00:00:00:%02x'/>"
            "<source network='default'/></interface>" % indice
            for indice in range(5)
        )
        with self.assertRaises(DataError) as contexto:
            domain_xml.interface_state(
                {"xml": fx.domain(interfaces=muitas), "max_items": 3}
            )
        self.assertIn("limite", str(contexto.exception))

    def test_mac_do_payload_invalido(self) -> None:
        with self.assertRaises(DataError):
            domain_xml.interface_state({"xml": fx.domain(), "nic_mac": "52:54:00"})


class MemoryBackingTests(unittest.TestCase):
    def test_sem_backing(self) -> None:
        dados = domain_xml.memory_backing_state({"xml": fx.domain()})
        self.assertEqual(dados["hugepages_count"], 0)
        self.assertEqual(dados["backing_count"], 0)

    def test_com_pagina_de_1g(self) -> None:
        backing = (
            "<memoryBacking><hugepages><page size='1' unit='GiB'/></hugepages>"
            "</memoryBacking>"
        )
        dados = domain_xml.memory_backing_state(
            {"xml": fx.domain(memory_backing=backing)}
        )
        self.assertEqual(dados["hugepages_count"], 1)
        self.assertEqual(dados["page_bytes"], 1024 ** 3)

    def test_backing_sem_hugepages(self) -> None:
        backing = "<memoryBacking><locked/></memoryBacking>"
        dados = domain_xml.memory_backing_state(
            {"xml": fx.domain(memory_backing=backing)}
        )
        self.assertEqual((dados["backing_count"], dados["hugepages_count"]), (1, 0))

    def test_hugepages_duplicado(self) -> None:
        backing = (
            "<memoryBacking><hugepages/><hugepages/></memoryBacking>"
        )
        with self.assertRaises(DataError):
            domain_xml.memory_backing_state({"xml": fx.domain(memory_backing=backing)})

    def test_backing_duplicado(self) -> None:
        backing = "<memoryBacking/><memoryBacking/>"
        with self.assertRaises(DataError):
            domain_xml.memory_backing_state({"xml": fx.domain(memory_backing=backing)})


CPU_PINNING_OPTIONS = {
    "cpus_vm": "2-5",
    "cpus_host": "0-1,6-7",
    "vcpus": 4,
    "cores": 2,
    "threads": 2,
    "ram_mb": 8192,
}


def candidato_cpu(xml: str, **overrides) -> tuple[dict, str]:
    opcoes = dict(CPU_PINNING_OPTIONS)
    opcoes.update(overrides)
    return domain_xml.build_candidate(
        {"xml": xml, "operations": [{"op": "cpu-pinning", "options": opcoes}]}
    )


class CandidateCpuTests(unittest.TestCase):
    def test_gera_e_valida(self) -> None:
        dados, candidato = candidato_cpu(fx.domain())
        self.assertEqual(dados["changed"], 1)
        self.assertNotEqual(dados["fingerprint_before"], dados["fingerprint_after"])
        validado = domain_xml.validate_cpu_pinning(
            dict({"xml": candidato, "hugepages_mode": "sim"}, **CPU_PINNING_OPTIONS)
        )
        self.assertEqual(validado["valid"], 1)

    def test_preserva_conteudo_nao_gerenciado(self) -> None:
        cputune = "<cputune><shares>2048</shares><vcpupin vcpu='0' cpuset='9'/></cputune>"
        _dados, candidato = candidato_cpu(fx.domain(cputune=cputune))
        raiz = xmlutil.parse_document(candidato, "domain")
        no = xmlutil.exactly_one(raiz, "cputune", "ctx")
        self.assertEqual(
            xmlutil.text_of(xmlutil.exactly_one(no, "shares", "ctx")), "2048"
        )
        # O pinning antigo foi substituído pelo gerenciado, não acumulado.
        self.assertEqual(len(xmlutil.direct(no, "vcpupin")), 4)
        self.assertEqual(len(xmlutil.direct(no, "emulatorpin")), 1)

    def test_recusa_maxmemory(self) -> None:
        with self.assertRaises(DataError) as contexto:
            candidato_cpu(fx.domain(extra_root="<maxMemory slots='2'>16384</maxMemory>"))
        self.assertIn("maxMemory", str(contexto.exception))

    def test_recusa_numatune(self) -> None:
        with self.assertRaises(DataError):
            candidato_cpu(fx.domain(extra_root="<numatune><memory mode='strict'/></numatune>"))

    def test_recusa_vcpus_de_hotplug(self) -> None:
        with self.assertRaises(DataError) as contexto:
            candidato_cpu(
                fx.domain(extra_root="<vcpus><vcpu id='0' enabled='yes'/></vcpus>")
            )
        self.assertIn("hotplug", str(contexto.exception))

    def test_recusa_cpu_numa(self) -> None:
        with self.assertRaises(DataError):
            candidato_cpu(fx.domain(cpu="<cpu><numa><cell id='0'/></numa></cpu>"))

    def test_recusa_contagem_divergente(self) -> None:
        with self.assertRaises(DataError):
            candidato_cpu(fx.domain(), cpus_vm="2-4")

    def test_recusa_lista_invalida(self) -> None:
        for lista in ("", "5-2", "2,2", "a-b", "2--3", "2,"):
            with self.assertRaises(DataError):
                candidato_cpu(fx.domain(), cpus_vm=lista)

    def test_idempotencia_do_candidato(self) -> None:
        _dados, primeiro = candidato_cpu(fx.domain())
        dados, segundo = candidato_cpu(primeiro)
        self.assertEqual(primeiro, segundo)
        self.assertEqual(dados["changed"], 0)
        self.assertEqual(dados["fingerprint_before"], dados["fingerprint_after"])

    def test_currentmemory_acompanha(self) -> None:
        _dados, candidato = candidato_cpu(fx.domain(), ram_mb=4096)
        raiz = xmlutil.parse_document(candidato, "domain")
        atual = xmlutil.exactly_one(raiz, "currentMemory", "ctx")
        self.assertEqual(xmlutil.text_of(atual), "4096")
        self.assertEqual(atual.get("unit"), "MiB")


class ValidateCpuTests(unittest.TestCase):
    def setUp(self) -> None:
        _dados, self.candidato = candidato_cpu(fx.domain())

    def valida(self, xml: str, **overrides) -> dict:
        payload = dict({"xml": xml, "hugepages_mode": "sim"}, **CPU_PINNING_OPTIONS)
        payload.update(overrides)
        return domain_xml.validate_cpu_pinning(payload)

    def test_aprovado(self) -> None:
        self.assertEqual(self.valida(self.candidato)["valid"], 1)

    def test_hugepages_modo_nao(self) -> None:
        with self.assertRaises(DataError):
            self.valida(self.candidato, hugepages_mode="nao")

    def test_hugepages_modo_ignorar(self) -> None:
        self.assertEqual(self.valida(self.candidato, hugepages_mode="ignorar")["valid"], 1)

    def test_hugepages_modo_desconhecido(self) -> None:
        with self.assertRaises(DataError):
            self.valida(self.candidato, hugepages_mode="talvez")

    def test_vcpupin_duplicado(self) -> None:
        ruim = self.candidato.replace(
            '<vcpupin vcpu="1" cpuset="3" />', '<vcpupin vcpu="0" cpuset="3" />'
        )
        self.assertNotEqual(ruim, self.candidato)
        with self.assertRaises(DataError):
            self.valida(ruim)

    def test_ram_divergente(self) -> None:
        with self.assertRaises(DataError):
            self.valida(self.candidato, ram_mb=4096)

    def test_topologia_divergente(self) -> None:
        with self.assertRaises(DataError):
            self.valida(self.candidato, cores=4, threads=1)

    def test_emulatorpin_divergente(self) -> None:
        with self.assertRaises(DataError):
            self.valida(self.candidato, cpus_host="0-1")

    def test_memoria_com_unidade_equivalente(self) -> None:
        equivalente = self.candidato.replace(
            '<memory unit="MiB">8192</memory>', '<memory unit="KiB">8388608</memory>'
        )
        self.assertNotEqual(equivalente, self.candidato)
        self.assertEqual(self.valida(equivalente)["valid"], 1)

    def test_memoria_com_unidade_desconhecida(self) -> None:
        ruim = self.candidato.replace('<memory unit="MiB">', '<memory unit="parsecs">')
        with self.assertRaises(DataError):
            self.valida(ruim)

    def test_memoria_nao_inteira(self) -> None:
        ruim = self.candidato.replace(
            '<memory unit="MiB">8192</memory>', '<memory unit="MiB">8192.5</memory>'
        )
        with self.assertRaises(DataError):
            self.valida(ruim)

    def test_cputune_ausente(self) -> None:
        with self.assertRaises(DataError):
            self.valida(fx.domain())


class CandidateOtherTests(unittest.TestCase):
    def test_disk_discard(self) -> None:
        dados, candidato = domain_xml.build_candidate(
            {
                "xml": fx.domain(),
                "operations": [
                    {"op": "disk-discard", "options": {"qcow2_path": fx.QCOW2}}
                ],
            }
        )
        self.assertEqual(dados["changed"], 1)
        self.assertEqual(
            domain_xml.disk_target_state(
                {"xml": candidato, "qcow2_path": fx.QCOW2}
            )["state"],
            "ativo",
        )

    def test_disk_discard_idempotente(self) -> None:
        dados, _candidato = domain_xml.build_candidate(
            {
                "xml": fx.domain(discard="unmap"),
                "operations": [
                    {"op": "disk-discard", "options": {"qcow2_path": fx.QCOW2}}
                ],
            }
        )
        self.assertEqual(dados["changed"], 0)

    def test_disk_discard_valor_nao_gerenciado(self) -> None:
        with self.assertRaises(DataError):
            domain_xml.build_candidate(
                {
                    "xml": fx.domain(),
                    "operations": [
                        {
                            "op": "disk-discard",
                            "options": {"qcow2_path": fx.QCOW2, "value": "ignore"},
                        }
                    ],
                }
            )

    def test_remove_hugepages(self) -> None:
        backing = (
            "<memoryBacking><hugepages><page size='1' unit='GiB'/></hugepages>"
            "</memoryBacking>"
        )
        dados, candidato = domain_xml.build_candidate(
            {
                "xml": fx.domain(memory_backing=backing),
                "operations": [{"op": "remove-hugepages"}],
            }
        )
        self.assertEqual(dados["changed"], 1)
        raiz = xmlutil.parse_document(candidato, "domain")
        self.assertEqual(xmlutil.direct(raiz, "memoryBacking"), [])

    def test_remove_hugepages_preserva_backing_com_conteudo(self) -> None:
        backing = (
            "<memoryBacking><locked/><hugepages><page size='1' unit='GiB'/>"
            "</hugepages></memoryBacking>"
        )
        _dados, candidato = domain_xml.build_candidate(
            {
                "xml": fx.domain(memory_backing=backing),
                "operations": [{"op": "remove-hugepages"}],
            }
        )
        raiz = xmlutil.parse_document(candidato, "domain")
        no = xmlutil.exactly_one(raiz, "memoryBacking", "ctx")
        self.assertEqual([f.tag for f in xmlutil.elements(no)], ["locked"])

    def test_remove_hugepages_sem_backing_e_noop(self) -> None:
        dados, _candidato = domain_xml.build_candidate(
            {"xml": fx.domain(), "operations": [{"op": "remove-hugepages"}]}
        )
        self.assertEqual(dados["changed"], 0)

    def test_remove_video(self) -> None:
        canal = "<channel type='spicevmc'><target type='virtio'/></channel>"
        canal_agente = "<channel type='unix'><target type='virtio'/></channel>"
        dados, candidato = domain_xml.build_candidate(
            {
                "xml": fx.domain(
                    graphics="<graphics type='spice'/><video><model type='qxl'/></video>"
                    "<sound model='ich9'/><redirdev bus='usb' type='spicevmc'/>"
                    "<audio id='1' type='spice'/>"
                    + canal
                    + canal_agente
                ),
                "operations": [{"op": "remove-video"}],
            }
        )
        self.assertEqual(dados["changed"], 1)
        raiz = xmlutil.parse_document(candidato, "domain")
        dispositivos = xmlutil.exactly_one(raiz, "devices", "ctx")
        nomes = [filho.tag for filho in xmlutil.elements(dispositivos)]
        # O backend de áudio spice é gráfico por dependência e também sai.
        for proibido in ("graphics", "video", "sound", "redirdev", "audio"):
            self.assertNotIn(proibido, nomes)
        # O canal do guest agent não é gráfico e precisa sobreviver.
        canais = xmlutil.direct(dispositivos, "channel")
        self.assertEqual(len(canais), 1)
        self.assertEqual(canais[0].get("type"), "unix")

    def test_remove_video_idempotente(self) -> None:
        dados, _candidato = domain_xml.build_candidate(
            {"xml": fx.domain(graphics=""), "operations": [{"op": "remove-video"}]}
        )
        self.assertEqual(dados["changed"], 0)

    def test_remove_video_preserva_audio_none(self) -> None:
        # O libvirt (12) renormaliza o domínio ao definir e persiste
        # <audio type='none'/> mesmo sem som; a operação precisa preservá-lo
        # para que a prova de releitura pós-define convirja.
        dados, candidato = domain_xml.build_candidate(
            {
                "xml": fx.domain(
                    graphics="<graphics type='spice'/><video><model type='qxl'/></video>"
                    "<audio id='1' type='none'/>"
                ),
                "operations": [{"op": "remove-video"}],
            }
        )
        self.assertEqual(dados["changed"], 1)
        raiz = xmlutil.parse_document(candidato, "domain")
        dispositivos = xmlutil.exactly_one(raiz, "devices", "ctx")
        audios = xmlutil.direct(dispositivos, "audio")
        self.assertEqual(len(audios), 1)
        self.assertEqual(audios[0].get("type"), "none")

    def test_remove_video_idempotente_pos_define_libvirt(self) -> None:
        # Estado exato que o libvirt 12 devolve após definir o candidato sem
        # vídeo: nenhum elemento gráfico e o backend de áudio explícito none.
        dados, _candidato = domain_xml.build_candidate(
            {
                "xml": fx.domain(graphics="<audio id='1' type='none'/>"),
                "operations": [{"op": "remove-video"}],
            }
        )
        self.assertEqual(dados["changed"], 0)

    def test_anti_code43(self) -> None:
        dados, candidato = domain_xml.build_candidate(
            {"xml": fx.domain(), "operations": [{"op": "anti-code43"}]}
        )
        self.assertEqual(dados["changed"], 1)
        raiz = xmlutil.parse_document(candidato, "domain")
        features = xmlutil.exactly_one(raiz, "features", "ctx")
        hyperv = xmlutil.exactly_one(features, "hyperv", "ctx")
        vendor = xmlutil.exactly_one(hyperv, "vendor_id", "ctx")
        self.assertEqual(vendor.get("state"), "on")
        self.assertEqual(vendor.get("value"), "randomid123")
        kvm = xmlutil.exactly_one(features, "kvm", "ctx")
        self.assertEqual(xmlutil.exactly_one(kvm, "hidden", "ctx").get("state"), "on")
        # O ACPI original não pode ter sido perdido.
        self.assertEqual(len(xmlutil.direct(features, "acpi")), 1)

    def test_anti_code43_idempotente(self) -> None:
        _dados, primeiro = domain_xml.build_candidate(
            {"xml": fx.domain(), "operations": [{"op": "anti-code43"}]}
        )
        dados, segundo = domain_xml.build_candidate(
            {"xml": primeiro, "operations": [{"op": "anti-code43"}]}
        )
        self.assertEqual(dados["changed"], 0)
        self.assertEqual(primeiro, segundo)

    def test_anti_code43_vendor_invalido(self) -> None:
        with self.assertRaises(DataError):
            domain_xml.build_candidate(
                {
                    "xml": fx.domain(),
                    "operations": [
                        {"op": "anti-code43", "options": {"vendor_id": "com espaço"}}
                    ],
                }
            )

    def test_nic_source(self) -> None:
        dados, candidato = domain_xml.build_candidate(
            {
                "xml": fx.domain(),
                "operations": [
                    {
                        "op": "nic-source",
                        "options": {
                            "mac": fx.NIC_MAC,
                            "type": "bridge",
                            "attribute": "bridge",
                            "value": "br-vm",
                        },
                    }
                ],
            }
        )
        self.assertEqual(dados["changed"], 1)
        estado = domain_xml.interface_state(
            {"xml": candidato, "nic_mac": fx.NIC_MAC}
        )
        self.assertEqual(estado["mac_count"], 1)
        self.assertEqual(estado["mac_type"], "bridge")
        self.assertEqual(estado["mac_bridge"], "br-vm")
        self.assertEqual(estado["mac_has_address"], 1)

    def test_nic_source_preserva_model(self) -> None:
        _dados, candidato = domain_xml.build_candidate(
            {
                "xml": fx.domain(),
                "operations": [
                    {
                        "op": "nic-source",
                        "options": {
                            "mac": fx.NIC_MAC,
                            "type": "bridge",
                            "attribute": "bridge",
                            "value": "br-vm",
                        },
                    }
                ],
            }
        )
        estado = domain_xml.interface_state({"xml": candidato})
        self.assertEqual(estado["nic_count"], 1)
        raiz = xmlutil.parse_document(candidato, "domain")
        dispositivos = xmlutil.exactly_one(raiz, "devices", "ctx")
        interface = xmlutil.exactly_one(dispositivos, "interface", "ctx")
        self.assertEqual(
            xmlutil.attribute(xmlutil.exactly_one(interface, "model", "ctx"), "type"),
            "virtio",
        )

    def test_nic_source_mac_ambiguo(self) -> None:
        duplicado = (
            "<interface type='network'><mac address='%s'/>"
            "<source network='default'/></interface>" % fx.NIC_MAC
        ) * 2
        with self.assertRaises(DataError) as contexto:
            domain_xml.build_candidate(
                {
                    "xml": fx.domain(interfaces=duplicado),
                    "operations": [
                        {
                            "op": "nic-source",
                            "options": {
                                "mac": fx.NIC_MAC,
                                "type": "bridge",
                                "attribute": "bridge",
                                "value": "br-vm",
                            },
                        }
                    ],
                }
            )
        self.assertIn("esperado exatamente 1", str(contexto.exception))

    def test_operacao_desconhecida(self) -> None:
        with self.assertRaises(DataError):
            domain_xml.build_candidate(
                {"xml": fx.domain(), "operations": [{"op": "apagar-tudo"}]}
            )

    def test_operacao_repetida(self) -> None:
        with self.assertRaises(DataError):
            domain_xml.build_candidate(
                {
                    "xml": fx.domain(),
                    "operations": [{"op": "remove-video"}, {"op": "remove-video"}],
                }
            )

    def test_sem_operacao(self) -> None:
        with self.assertRaises(DataError):
            domain_xml.build_candidate({"xml": fx.domain(), "operations": []})
        with self.assertRaises(DataError):
            domain_xml.build_candidate({"xml": fx.domain()})

    def test_operacoes_combinadas(self) -> None:
        dados, candidato = domain_xml.build_candidate(
            {
                "xml": fx.domain(),
                "operations": [{"op": "remove-video"}, {"op": "anti-code43"}],
            }
        )
        self.assertEqual(dados["operation_count"], 2)
        raiz = xmlutil.parse_document(candidato, "domain")
        dispositivos = xmlutil.exactly_one(raiz, "devices", "ctx")
        self.assertEqual(xmlutil.direct(dispositivos, "video"), [])
        features = xmlutil.exactly_one(raiz, "features", "ctx")
        self.assertEqual(len(xmlutil.direct(features, "kvm")), 1)


class CandidatePairsTests(unittest.TestCase):
    """Montagem das operações pelo canal de pares (chaves planas)."""

    def test_operacao_unica(self) -> None:
        dados, candidato = domain_xml.build_candidate(
            {
                "xml": fx.domain(),
                "op_count": "1",
                "op_0": "disk-discard",
                "op_0_qcow2_path": fx.QCOW2,
            }
        )
        self.assertEqual(dados["changed"], 1)
        self.assertIn('discard="unmap"', candidato)

    def test_duas_operacoes(self) -> None:
        dados, _candidato = domain_xml.build_candidate(
            {
                "xml": fx.domain(),
                "op_count": "2",
                "op_0": "remove-video",
                "op_1": "anti-code43",
                "op_1_vendor_id": "randomid123",
            }
        )
        self.assertEqual(dados["operation_count"], 2)

    def test_inteiros_em_texto(self) -> None:
        dados, _candidato = domain_xml.build_candidate(
            {
                "xml": fx.domain(),
                "op_count": "1",
                "op_0": "cpu-pinning",
                "op_0_cpus_vm": "2-5",
                "op_0_cpus_host": "0-1,6-7",
                "op_0_vcpus": "4",
                "op_0_cores": "2",
                "op_0_threads": "2",
                "op_0_ram_mb": "8192",
            }
        )
        self.assertEqual(dados["changed"], 1)

    def test_nome_de_operacao_ausente(self) -> None:
        with self.assertRaises(DataError):
            domain_xml.build_candidate({"xml": fx.domain(), "op_count": "1"})

    def test_chave_fora_do_formato(self) -> None:
        with self.assertRaises(DataError) as contexto:
            domain_xml.build_candidate(
                {
                    "xml": fx.domain(),
                    "op_count": "1",
                    "op_0": "remove-video",
                    "op_x_valor": "1",
                }
            )
        self.assertIn("op_", str(contexto.exception))

    def test_indice_acima_do_declarado(self) -> None:
        with self.assertRaises(DataError):
            domain_xml.build_candidate(
                {
                    "xml": fx.domain(),
                    "op_count": "1",
                    "op_0": "remove-video",
                    "op_5_valor": "1",
                }
            )

    def test_limite_de_operacoes(self) -> None:
        with self.assertRaises(DataError):
            domain_xml.build_candidate({"xml": fx.domain(), "op_count": "9"})


class CompareTests(unittest.TestCase):
    def test_iguais(self) -> None:
        dados = domain_xml.compare_documents(
            {"left": fx.domain(), "right": fx.domain()}
        )
        self.assertEqual(dados["equal"], 1)
        self.assertEqual(dados["difference"], "")
        self.assertEqual(dados["fingerprint_left"], dados["fingerprint_right"])

    def test_divergentes(self) -> None:
        dados = domain_xml.compare_documents(
            {"left": fx.domain(), "right": fx.domain(discard="unmap")}
        )
        self.assertEqual(dados["equal"], 0)
        self.assertIn("driver", dados["difference"])
        self.assertNotEqual(dados["fingerprint_left"], dados["fingerprint_right"])

    def test_projecao_cpu_unmanaged_ignora_gerenciado(self) -> None:
        _dados, candidato = candidato_cpu(fx.domain())
        dados = domain_xml.compare_documents(
            {"left": fx.domain(), "right": candidato, "projection": "cpu-unmanaged"}
        )
        # cputune/memoryBacking/cpu não existiam na origem: a projeção difere de
        # propósito quando o elemento é criado.
        self.assertEqual(dados["equal"], 0)

    def test_projecao_cpu_unmanaged_estavel_entre_candidatos(self) -> None:
        cputune = "<cputune><shares>2048</shares></cputune>"
        _dados, primeiro = candidato_cpu(fx.domain(cputune=cputune))
        _dados, segundo = candidato_cpu(fx.domain(cputune=cputune), ram_mb=4096)
        dados = domain_xml.compare_documents(
            {"left": primeiro, "right": segundo, "projection": "cpu-unmanaged"}
        )
        self.assertEqual(dados["equal"], 1)

    def test_projecao_desconhecida(self) -> None:
        with self.assertRaises(DataError):
            domain_xml.compare_documents(
                {"left": fx.domain(), "right": fx.domain(), "projection": "tudo"}
            )

    def test_projecao_devices_unmanaged(self) -> None:
        esquerda = fx.domain()
        direita = fx.domain(hostdevs=fx.HOSTDEV_GPU, discard="unmap")
        dados = domain_xml.compare_documents(
            {"left": esquerda, "right": direita, "projection": "devices-unmanaged"}
        )
        self.assertEqual(dados["equal"], 1)

    def test_fingerprint_isolado(self) -> None:
        dados = domain_xml.fingerprint_document({"xml": fx.domain()})
        comparado = domain_xml.compare_documents(
            {"left": fx.domain(), "right": fx.domain()}
        )
        self.assertEqual(dados["fingerprint"], comparado["fingerprint_left"])


class SnapshotPlanTests(unittest.TestCase):
    def test_plano_com_hd1(self) -> None:
        dados = domain_xml.disk_snapshot_plan(
            {
                "xml": fx.domain(extra_disks=fx.DISCO_HD1 + fx.DISCO_CDROM),
                "qcow2_path": fx.QCOW2,
            }
        )
        self.assertEqual(dados["disk_count"], 2)
        self.assertEqual(dados["disk_0_target"], "vda")
        self.assertEqual(dados["disk_0_mode"], "internal")
        self.assertEqual(dados["disk_1_target"], "vdb")
        self.assertEqual(dados["disk_1_mode"], "no")

    def test_driver_divergente(self) -> None:
        xml = fx.domain().replace("type='qcow2'", "type='raw'")
        with self.assertRaises(DataError) as contexto:
            domain_xml.disk_snapshot_plan({"xml": xml, "qcow2_path": fx.QCOW2})
        self.assertIn("qcow2", str(contexto.exception))

    def test_qcow2_ausente(self) -> None:
        with self.assertRaises(DataError):
            domain_xml.disk_snapshot_plan(
                {"xml": fx.domain(), "qcow2_path": "/vm/outro.qcow2"}
            )

    def test_sem_alvo(self) -> None:
        xml = fx.domain().replace("<target dev='vda' bus='virtio'/>", "")
        with self.assertRaises(DataError):
            domain_xml.disk_snapshot_plan({"xml": xml, "qcow2_path": fx.QCOW2})


class SnapshotInternalTests(unittest.TestCase):
    def test_interno_unico(self) -> None:
        dados = domain_xml.snapshot_internal_state({"xml": fx.snapshot()})
        self.assertEqual(dados["internal_target"], "vda")
        self.assertEqual(dados["disk_count"], 2)

    def test_externo_recusado(self) -> None:
        with self.assertRaises(DataError) as contexto:
            domain_xml.snapshot_internal_state(
                {"xml": fx.snapshot(discos="<disk name='vda' snapshot='external'/>")}
            )
        self.assertIn("externo", str(contexto.exception))

    def test_tipo_desconhecido(self) -> None:
        with self.assertRaises(DataError) as contexto:
            domain_xml.snapshot_internal_state(
                {"xml": fx.snapshot(discos="<disk name='vda' snapshot='talvez'/>")}
            )
        self.assertIn("não reconhecidos", str(contexto.exception))

    def test_dois_internos(self) -> None:
        with self.assertRaises(DataError):
            domain_xml.snapshot_internal_state(
                {
                    "xml": fx.snapshot(
                        discos="<disk name='vda' snapshot='internal'/>"
                        "<disk name='vdb' snapshot='internal'/>"
                    )
                }
            )

    def test_nenhum_interno(self) -> None:
        with self.assertRaises(DataError):
            domain_xml.snapshot_internal_state(
                {"xml": fx.snapshot(discos="<disk name='vda' snapshot='no'/>")}
            )

    def test_nome_invalido(self) -> None:
        with self.assertRaises(DataError):
            domain_xml.snapshot_internal_state(
                {"xml": fx.snapshot(discos="<disk name='v da' snapshot='internal'/>")}
            )

    def test_raiz_errada(self) -> None:
        with self.assertRaises(DataError):
            domain_xml.snapshot_internal_state({"xml": fx.domain()})


class BackupTargetTests(unittest.TestCase):
    def test_alvo_unico(self) -> None:
        dados = domain_xml.disk_backup_target(
            {
                "xml": fx.domain(extra_disks=fx.DISCO_CDROM + fx.DISCO_HD1),
                "qcow2_path": fx.QCOW2,
            }
        )
        self.assertEqual(dados["target_dev"], "vda")
        self.assertEqual(dados["driver_type"], "qcow2")
        self.assertEqual(dados["other_source_count"], 2)
        fontes = {dados["other_source_0"], dados["other_source_1"]}
        self.assertEqual(fontes, {"/vm/windows.iso", fx.HD1})

    def test_nvram_projetada(self) -> None:
        dados = domain_xml.disk_backup_target(
            {
                "xml": fx.domain(
                    os_block="<os><type arch='x86_64'>hvm</type>"
                    "<nvram>/var/lib/libvirt/qemu/nvram/fixture_VARS.fd</nvram></os>"
                ),
                "qcow2_path": fx.QCOW2,
            }
        )
        self.assertEqual(
            dados["nvram_path"], "/var/lib/libvirt/qemu/nvram/fixture_VARS.fd"
        )

    def test_sem_nvram(self) -> None:
        dados = domain_xml.disk_backup_target(
            {"xml": fx.domain(), "qcow2_path": fx.QCOW2}
        )
        self.assertEqual(dados["nvram_path"], "")

    def test_overlay_externo_recusado(self) -> None:
        with self.assertRaises(DataError) as contexto:
            domain_xml.disk_backup_target(
                {"xml": fx.domain(), "qcow2_path": "/vm/overlay.qcow2"}
            )
        self.assertIn("exatamente o disco ativo", str(contexto.exception))

    def test_driver_divergente(self) -> None:
        xml = fx.domain().replace("type='qcow2'", "type='raw'")
        with self.assertRaises(DataError):
            domain_xml.disk_backup_target({"xml": xml, "qcow2_path": fx.QCOW2})


class MetadataTests(unittest.TestCase):
    """REQ-WINDOWS-STATE: I3 só modela a evidência durável, sem power/agent."""

    def metadata(self, digest: str = fx.DIGEST, quando: str = "20260817-120000",
                origem: str = "operador") -> str:
        return (
            "<metadata><vmpass:passthrough xmlns:vmpass='%s'>"
            "<vmpass:windows-install qcow2-digest='%s' recorded-at='%s' source='%s'/>"
            "</vmpass:passthrough></metadata>"
            % (domain_xml.METADATA_NAMESPACE, digest, quando, origem)
        )

    def test_sem_metadata(self) -> None:
        dados = domain_xml.metadata_state({"xml": fx.domain()})
        self.assertEqual(dados["metadata_present"], 0)
        self.assertEqual(dados["install_present"], 0)
        self.assertEqual(dados["digest_matches"], 0)

    def test_metadata_de_terceiro_preservada(self) -> None:
        outro = (
            "<metadata><outra:coisa xmlns:outra='https://exemplo/1'/></metadata>"
        )
        dados = domain_xml.metadata_state({"xml": fx.domain(metadata=outro)})
        self.assertEqual(dados["metadata_present"], 1)
        self.assertEqual(dados["install_present"], 0)
        self.assertEqual(dados["foreign_child_count"], 1)

    def test_instalacao_registrada(self) -> None:
        dados = domain_xml.metadata_state(
            {"xml": fx.domain(metadata=self.metadata()), "qcow2_digest": fx.DIGEST}
        )
        self.assertEqual(dados["install_present"], 1)
        self.assertEqual(dados["install_digest"], fx.DIGEST)
        self.assertEqual(dados["install_recorded_at"], "20260817-120000")
        self.assertEqual(dados["install_source"], "operador")
        self.assertEqual(dados["digest_matches"], 1)

    def test_digest_divergente_invalida_vinculo(self) -> None:
        dados = domain_xml.metadata_state(
            {"xml": fx.domain(metadata=self.metadata()), "qcow2_digest": "a" * 64}
        )
        self.assertEqual(dados["install_present"], 1)
        self.assertEqual(dados["digest_matches"], 0)

    def test_metadata_invalida_recusada(self) -> None:
        for digest, quando, origem in (
            ("curto", "20260817-120000", "operador"),
            (fx.DIGEST, "ontem", "operador"),
            (fx.DIGEST, "20260817-120000", "chute"),
        ):
            with self.assertRaises(DataError):
                domain_xml.metadata_state(
                    {"xml": fx.domain(metadata=self.metadata(digest, quando, origem))}
                )

    def test_digest_esperado_invalido(self) -> None:
        with self.assertRaises(DataError):
            domain_xml.metadata_state({"xml": fx.domain(), "qcow2_digest": "zz"})

    def test_candidato_grava_e_e_idempotente(self) -> None:
        opcoes = {
            "qcow2_digest": fx.DIGEST,
            "recorded_at": "20260817-120000",
            "source": "operador",
        }
        dados, candidato = domain_xml.build_candidate(
            {
                "xml": fx.domain(),
                "operations": [{"op": "install-metadata", "options": opcoes}],
            }
        )
        self.assertEqual(dados["changed"], 1)
        estado = domain_xml.metadata_state(
            {"xml": candidato, "qcow2_digest": fx.DIGEST}
        )
        self.assertEqual(estado["install_present"], 1)
        self.assertEqual(estado["digest_matches"], 1)
        repetido, segundo = domain_xml.build_candidate(
            {
                "xml": candidato,
                "operations": [{"op": "install-metadata", "options": opcoes}],
            }
        )
        self.assertEqual(repetido["changed"], 0)
        self.assertEqual(candidato, segundo)

    def test_candidato_preserva_metadata_de_terceiro(self) -> None:
        outro = "<metadata><outra:coisa xmlns:outra='https://exemplo/1'/></metadata>"
        _dados, candidato = domain_xml.build_candidate(
            {
                "xml": fx.domain(metadata=outro),
                "operations": [
                    {
                        "op": "install-metadata",
                        "options": {
                            "qcow2_digest": fx.DIGEST,
                            "recorded_at": "20260817-120000",
                        },
                    }
                ],
            }
        )
        estado = domain_xml.metadata_state({"xml": candidato})
        self.assertEqual(estado["foreign_child_count"], 1)
        self.assertEqual(estado["install_present"], 1)

    def test_candidato_recusa_dados_invalidos(self) -> None:
        for opcoes in (
            {"qcow2_digest": "curto", "recorded_at": "20260817-120000"},
            {"qcow2_digest": fx.DIGEST, "recorded_at": "2026-08-17"},
            {"qcow2_digest": fx.DIGEST, "recorded_at": "20260817-120000", "source": "x"},
        ):
            with self.assertRaises(DataError):
                domain_xml.build_candidate(
                    {
                        "xml": fx.domain(),
                        "operations": [{"op": "install-metadata", "options": opcoes}],
                    }
                )


if __name__ == "__main__":
    unittest.main()
