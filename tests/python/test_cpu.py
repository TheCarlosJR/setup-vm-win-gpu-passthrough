"""Topologia, partição de CPU e plano de memória (I5.1, I5.2, I5.3)."""
import unittest

from passthrough_core import cpu
from passthrough_core.errors import DataError

# SMT2 em dois sockets, IDs intercalados: o caso que quebra qualquer heurística
# baseada só no número do core, porque o ID de CORE se repete entre sockets.
MULTISOCKET = "\n".join(
    (
        "0,0,0,0,Y",
        "4,0,0,0,Y",
        "1,1,0,0,Y",
        "5,1,0,0,Y",
        "2,0,1,1,Y",
        "6,0,1,1,Y",
        "3,1,1,1,Y",
        "7,1,1,1,Y",
    )
)

# IDs esparsos com uma CPU offline: a offline não pode ser alocada nem contada.
ESPARSA = "\n".join(("0,0,0,0,Y", "2,0,0,0,Y", "4,1,0,0,Y", "6,1,0,0,Y", "8,2,0,0,N"))

# Oito cores, um thread por core: exercita o teto de dois cores para o host.
OITO_CORES = "\n".join("%d,%d,0,0,Y" % (indice, indice) for indice in range(8))


class ListaCpusTests(unittest.TestCase):
    def test_expande_preservando_ordem_declarada(self) -> None:
        self.assertEqual(cpu.parse_cpu_list("0-2,5,8-9"), [0, 1, 2, 5, 8, 9])
        self.assertEqual(cpu.parse_cpu_list("5,0"), [5, 0])

    def test_recusa_sintaxe_intervalo_e_duplicacao(self) -> None:
        for texto in ("", "a", "0,,1", "3-1", "0-1,1", "0 1", "-1", "0-"):
            with self.subTest(texto=texto):
                self.assertIsNone(cpu.parse_cpu_list(texto))

    def test_recusa_cardinalidade_acima_do_limite(self) -> None:
        self.assertIsNone(cpu.parse_cpu_list("0-%d" % cpu.MAX_CPU_ENTRIES))


class TopologiaTests(unittest.TestCase):
    def test_canonicaliza_e_mede(self) -> None:
        dados = cpu.topology_snapshot({"csv": MULTISOCKET})
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["online_count"], 8)
        self.assertEqual(dados["online_set"], "0,1,2,3,4,5,6,7")
        self.assertEqual(dados["core_count"], 4)
        self.assertEqual(dados["socket_count"], 2)
        self.assertEqual(dados["threads_per_core"], 2)
        self.assertEqual(dados["homogeneous"], 1)
        self.assertEqual(dados["boot_core"], "0:0")
        self.assertEqual(dados["boot_core_cpus"], "0,4")
        self.assertRegex(dados["fingerprint"], r"^[0-9a-f]{64}$")

    def test_offline_nao_entra_no_conjunto(self) -> None:
        dados = cpu.topology_snapshot({"csv": ESPARSA})
        self.assertEqual(dados["online_set"], "0,2,4,6")
        self.assertEqual(dados["core_count"], 2)

    def test_fingerprint_ignora_ordem_das_linhas(self) -> None:
        invertida = "\n".join(reversed(MULTISOCKET.splitlines()))
        self.assertEqual(
            cpu.topology_snapshot({"csv": MULTISOCKET})["fingerprint"],
            cpu.topology_snapshot({"csv": invertida})["fingerprint"],
        )

    def test_fingerprint_muda_quando_uma_cpu_sai_de_linha(self) -> None:
        alterada = MULTISOCKET.replace("7,1,1,1,Y", "7,1,1,1,N")
        self.assertNotEqual(
            cpu.topology_snapshot({"csv": MULTISOCKET})["fingerprint"],
            cpu.topology_snapshot({"csv": alterada})["fingerprint"],
        )

    def test_recusa_estado_online_desconhecido(self) -> None:
        dados = cpu.topology_snapshot({"csv": "0,0,0,0,talvez"})
        self.assertEqual(dados["valid"], 0)
        self.assertIn("ONLINE desconhecido", dados["error"])
        self.assertEqual(dados["fingerprint"], "")

    def test_recusa_colunas_inesperadas_e_cpu_repetida(self) -> None:
        self.assertIn(
            "colunas inesperadas",
            cpu.topology_snapshot({"csv": "0,0,0,0,Y,extra"})["error"],
        )
        self.assertIn(
            "mais de uma vez",
            cpu.topology_snapshot({"csv": "0,0,0,0,Y\n0,1,0,0,Y"})["error"],
        )

    def test_recusa_topologia_sem_cpu_online(self) -> None:
        self.assertIn(
            "Nenhuma CPU online",
            cpu.topology_snapshot({"csv": "0,0,0,0,N"})["error"],
        )

    def test_csv_ausente_e_defeito_de_chamada(self) -> None:
        with self.assertRaises(DataError):
            cpu.topology_snapshot({})


class LayoutTests(unittest.TestCase):
    def validar(self, cpus_vm: str, cpus_host: str, vcpus: str, cores: str,
                threads: str, csv: str = MULTISOCKET) -> dict:
        return cpu.validate_layout(
            {
                "csv": csv,
                "cpus_vm": cpus_vm,
                "cpus_host": cpus_host,
                "vcpus": vcpus,
                "cores": cores,
                "threads": threads,
            }
        )

    def test_particao_valida(self) -> None:
        dados = self.validar("0,4,1,5", "2,6,3,7", "4", "2", "2")
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["error"], "")
        self.assertEqual(dados["online_set"], "0,1,2,3,4,5,6,7")
        self.assertEqual(dados["vm_cpu_count"], 4)
        self.assertEqual(dados["vm_core_count"], 2)
        self.assertEqual(dados["host_core_count"], 2)

    def test_ids_esparsos_sao_validos(self) -> None:
        self.assertEqual(self.validar("0,2", "4,6", "2", "1", "2", ESPARSA)["valid"], 1)

    def test_recusa_siblings_intercalados(self) -> None:
        dados = self.validar("0,1,4,5", "2,6,3,7", "4", "2", "2")
        self.assertEqual(dados["valid"], 0)
        self.assertIn("ordem canônica", dados["error"])

    def test_recusa_core_fisico_dividido(self) -> None:
        # 0 e 2 são siblings do mesmo core; dar 0 à VM e 2 ao host parte o core.
        dados = self.validar("0,4", "2,6", "2", "1", "2", ESPARSA)
        self.assertEqual(dados["valid"], 0)
        self.assertIn("dividido entre VM e host", dados["error"])

    def test_recusa_cpu_offline_alocada(self) -> None:
        dados = self.validar("0,8", "2,4,6", "2", "1", "2", ESPARSA)
        self.assertIn("não está online", dados["error"])

    def test_recusa_sobreposicao_e_omissao(self) -> None:
        self.assertIn(
            "simultaneamente",
            self.validar("0,2", "2,4,6", "2", "1", "2", ESPARSA)["error"],
        )
        self.assertIn(
            "não pode haver omissões",
            self.validar("0,2", "4", "2", "1", "2", ESPARSA)["error"],
        )

    def test_recusa_produto_de_topologia_divergente(self) -> None:
        self.assertIn(
            "VM_CORES x VM_THREADS",
            self.validar("0,2", "4,6", "2", "2", "2", ESPARSA)["error"],
        )

    def test_recusa_host_sem_core_inteiro(self) -> None:
        dados = self.validar("0,4,1,5,2,6,3,7", "", "8", "4", "2")
        self.assertEqual(dados["valid"], 0)
        # A lista vazia é recusada antes, pela sintaxe; o contrato é que em
        # nenhum caminho a VM fique com todos os cores.
        self.assertNotEqual(dados["error"], "")

    def test_recusa_vcpus_incoerente_com_a_lista(self) -> None:
        # Produto coerente (2 x 2 = 4), cobertura completa, lista com 2 CPUs.
        self.assertIn(
            "mas VM_VCPUS=",
            self.validar("0,4", "1,5,2,6,3,7", "4", "2", "2")["error"],
        )

    def test_mensagens_de_campo_invalido(self) -> None:
        self.assertIn("VM_VCPUS inválido", self.validar("0,4", "1,5", "x", "1", "2")["error"])
        self.assertIn("VM_CORES inválido", self.validar("0,4", "1,5", "2", "x", "2")["error"])
        self.assertIn("VM_THREADS inválido", self.validar("0,4", "1,5", "2", "1", "x")["error"])


class PlanoPinningTests(unittest.TestCase):
    def test_limites_sem_escolha_do_operador(self) -> None:
        dados = cpu.plan_pinning({"csv": MULTISOCKET})
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["planned"], 0)
        self.assertEqual(dados["total_cores"], 4)
        self.assertEqual(dados["threads_per_core"], 2)
        # Menos de seis cores: o host mantém exatamente um core completo.
        self.assertEqual(dados["max_vm_cores"], 3)
        self.assertEqual(dados["default_vm_cores"], 3)
        self.assertEqual(dados["boot_core_cpus"], "0,4")
        self.assertEqual(dados["cpus_vm"], "")

    def test_host_guarda_dois_cores_quando_ha_folga(self) -> None:
        dados = cpu.plan_pinning({"csv": OITO_CORES})
        self.assertEqual(dados["total_cores"], 8)
        self.assertEqual(dados["max_vm_cores"], 6)

    def test_proposta_reserva_o_core_de_housekeeping(self) -> None:
        dados = cpu.plan_pinning({"csv": MULTISOCKET, "vm_cores": "2"})
        self.assertEqual(dados["planned"], 1)
        self.assertEqual(dados["cpus_host"], "0,4,1,5")
        self.assertEqual(dados["cpus_vm"], "2,6,3,7")
        self.assertEqual(dados["vcpus"], 4)
        self.assertEqual(dados["host_core_count"], 2)

    def test_proposta_passa_no_proprio_validador(self) -> None:
        for vm_cores in ("1", "2", "3"):
            with self.subTest(vm_cores=vm_cores):
                plano = cpu.plan_pinning({"csv": MULTISOCKET, "vm_cores": vm_cores})
                veredicto = cpu.validate_layout(
                    {
                        "csv": MULTISOCKET,
                        "cpus_vm": plano["cpus_vm"],
                        "cpus_host": plano["cpus_host"],
                        "vcpus": str(plano["vcpus"]),
                        "cores": vm_cores,
                        "threads": str(plano["threads_per_core"]),
                    }
                )
                self.assertEqual(veredicto["valid"], 1, veredicto["error"])

    def test_proposta_e_deterministica(self) -> None:
        primeira = cpu.plan_pinning({"csv": MULTISOCKET, "vm_cores": "2"})
        invertida = "\n".join(reversed(MULTISOCKET.splitlines()))
        segunda = cpu.plan_pinning({"csv": invertida, "vm_cores": "2"})
        self.assertEqual(primeira["cpus_vm"], segunda["cpus_vm"])
        self.assertEqual(primeira["cpus_host"], segunda["cpus_host"])

    def test_recusa_acima_do_teto(self) -> None:
        dados = cpu.plan_pinning({"csv": MULTISOCKET, "vm_cores": "4"})
        self.assertEqual(dados["valid"], 0)
        self.assertIn("entre 1 e 3", dados["error"])

    def test_recusa_host_com_um_unico_core(self) -> None:
        dados = cpu.plan_pinning({"csv": "0,0,0,0,Y\n4,0,0,0,Y"})
        self.assertEqual(dados["valid"], 0)
        self.assertIn("integralmente com o host", dados["error"])

    def test_recusa_smt_heterogeneo(self) -> None:
        heterogenea = "0,0,0,0,Y\n4,0,0,0,Y\n1,1,0,0,Y"
        dados = cpu.plan_pinning({"csv": heterogenea})
        self.assertEqual(dados["valid"], 0)
        self.assertIn("SMT heterogênea", dados["error"])

    def test_recusa_cpu_zero_offline(self) -> None:
        # SMT homogêneo (um thread por core) para isolar a ausência da CPU 0.
        sem_zero = "0,0,0,0,N\n1,1,0,0,Y\n2,2,0,0,Y"
        dados = cpu.plan_pinning({"csv": sem_zero})
        self.assertEqual(dados["valid"], 0)
        self.assertIn("CPU lógica 0", dados["error"])


class PlanoMemoriaTests(unittest.TestCase):
    def test_reserva_minima_maxima_e_teto(self) -> None:
        pequeno = cpu.memory_plan({"total_mib": "8192"})
        self.assertEqual(pequeno["reserve_mib"], 4096)
        self.assertEqual(pequeno["max_vm_mib"], 4096)
        medio = cpu.memory_plan({"total_mib": "24576"})
        self.assertEqual(medio["reserve_mib"], 6144)
        self.assertEqual(medio["max_vm_mib"], 18432)
        grande = cpu.memory_plan({"total_mib": "65536"})
        self.assertEqual(grande["reserve_mib"], 8192)
        self.assertEqual(grande["max_vm_mib"], 57344)

    def test_teto_alinhado_a_1_gib(self) -> None:
        dados = cpu.memory_plan({"total_mib": "16000"})
        self.assertEqual(dados["max_vm_mib"] % 1024, 0)
        self.assertEqual(dados["max_vm_gib"], dados["max_vm_mib"] // 1024)

    def test_host_sem_folga_zera_o_teto(self) -> None:
        self.assertEqual(cpu.memory_plan({"total_mib": "4096"})["max_vm_mib"], 0)

    def test_ram_valida_dentro_do_teto(self) -> None:
        # I9.12-D9: este caso conferia também `hugepages_1g == 22`, derivado
        # aqui. A derivação saiu para `resources.py`, que a faz por modo; o que
        # este plano ainda garante é a RAM válida, múltipla e dentro do teto.
        dados = cpu.memory_plan({"total_mib": "32768", "vm_ram_mib": "22528"})
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["checked"], 1)
        self.assertEqual(dados["vm_ram_mib"], 22528)
        self.assertNotIn("hugepages_1g", dados)

    def test_hugepages_1g_no_payload_e_ignorada(self) -> None:
        """I9.12-D9: a chave saiu do contrato de entrada deste plano.

        Oráculo anterior: `hugepages_1g="20"` com `vm_ram_mib="22528"` recusava
        com "HUGEPAGES_1G=20 diverge de VM_RAM_MB/1024". Agora o campo não é
        lido, e um conf antigo que ainda o carregue não muda o veredito. Quem
        recusa contagem incoerente hoje é `resources.plan`, pelo tamanho de
        página do modo escolhido.
        """
        dados = cpu.memory_plan(
            {"total_mib": "32768", "vm_ram_mib": "22528", "hugepages_1g": "20"}
        )
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["error"], "")

    def test_hugepages_1g_sozinha_nao_dispara_conferencia(self) -> None:
        # Oráculo anterior: só `hugepages_1g` já ligava `checked=1`.
        dados = cpu.memory_plan({"total_mib": "32768", "hugepages_1g": "22"})
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["checked"], 0)

    def test_recusa_ram_nao_multipla_de_1_gib(self) -> None:
        dados = cpu.memory_plan({"total_mib": "32768", "vm_ram_mib": "20000"})
        self.assertIn("não é múltiplo", dados["error"])

    def test_recusa_ram_acima_do_teto(self) -> None:
        dados = cpu.memory_plan({"total_mib": "32768", "vm_ram_mib": "30720"})
        self.assertIn("excede o teto", dados["error"])

    def test_recusa_ram_fora_da_faixa(self) -> None:
        self.assertIn(
            "VM_RAM_MB inválido",
            cpu.memory_plan({"total_mib": "32768", "vm_ram_mib": "512"})["error"],
        )

    def test_total_ausente_e_defeito_de_chamada(self) -> None:
        with self.assertRaises(DataError):
            cpu.memory_plan({})


class ClassificacaoDeErroTests(unittest.TestCase):
    """Estado do host recusado devolve veredicto; chamada errada levanta."""

    def test_estado_recusado_nao_levanta(self) -> None:
        for chamada in (
            lambda: cpu.topology_snapshot({"csv": "lixo"}),
            lambda: cpu.validate_layout({"csv": "lixo"}),
            lambda: cpu.plan_pinning({"csv": "lixo"}),
        ):
            with self.subTest(chamada=chamada):
                self.assertEqual(chamada()["valid"], 0)

    def test_campo_de_tipo_errado_levanta(self) -> None:
        with self.assertRaises(DataError):
            cpu.validate_layout({"csv": MULTISOCKET, "cpus_vm": 4})


if __name__ == "__main__":
    unittest.main()
