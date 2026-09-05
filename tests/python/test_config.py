"""Schema, parser, round-trip e persistência de `passthrough.conf` (I4).

Inclui a revalidação TOCTOU que deixou de ser observável por shim de `mv`: como
a publicação passou a ser `renameat` dentro do core, a corrida é montada aqui
chamando leitura e publicação separadamente e alterando o alvo no meio.
"""
import io
import os
import stat
import tempfile
import unittest

from passthrough_core import cli, config
from passthrough_core.errors import (
    ConflictError,
    DataError,
    MissingInputError,
    PersistenceError,
    UsageError,
)

ROUNDTRIP = """# fixture pública: comentários, ordem, espaços e quoting

USUARIO_LINUX='fixture'
VM_NAME="win11-fixture" # comentário de fim de linha
BOOTLOADER=grub
VM_RAM_MB="8192"
QCOW2_PATH="/vm/Windows 11.qcow2"
"""


class SchemaTests(unittest.TestCase):
    def test_toda_chave_tem_classe_declarada(self) -> None:
        for key, (validator, klass, description) in config.SCHEMA.items():
            self.assertIn(klass, config.DATA_CLASSES, key)
            self.assertTrue(callable(validator), key)
            self.assertTrue(description, key)

    def test_default_de_chave_desconhecida_e_secret(self) -> None:
        self.assertEqual(config.DEFAULT_DATA_CLASS, config.SECRET)
        self.assertEqual(config.data_class("CHAVE_QUE_NAO_EXISTE"), config.SECRET)

    def test_quantidade_e_unicidade(self) -> None:
        self.assertEqual(len(config.KEYS), len(set(config.KEYS)))
        self.assertEqual(len(config.KEYS), len(config.SCHEMA))

    def test_dispensas_com_efeito_real(self) -> None:
        # I4.8: só permanecem as duas que alteram comportamento documentado e
        # testado. As outras duas foram depreciadas por não alterarem nada.
        self.assertEqual(
            set(config.WAIVER_KEYS),
            {"WORKING_DISK_DISPENSADO", "HD1_DISPENSADO"},
        )

    def test_dispensas_depreciadas(self) -> None:
        # I9.12-D9: HUGEPAGES_1G entrou aqui em 05/09/2026, pelo mesmo mecanismo
        # das duas dispensas de I4.8. O oráculo anterior tinha só duas chaves.
        self.assertEqual(
            set(config.DEPRECATED_KEYS),
            {"AIRLOCK_DISPENSADO", "BACKUP_DISPENSADO", "HUGEPAGES_1G"},
        )
        for key, motivo in config.DEPRECATED_KEYS.items():
            self.assertNotIn(key, config.SCHEMA, key)
            self.assertTrue(motivo, key)

    def test_relacoes_declaradas(self) -> None:
        for caminho, dispensa in config.RELATIONS:
            self.assertIn(caminho, config.SCHEMA)
            self.assertIn(dispensa, config.WAIVER_KEYS)

    def test_identificadores_locais_classificados(self) -> None:
        # Caminhos, MAC, IP, BDF, usuário e nomes de rede/VM são identidade
        # local (seção 3.9); enum, inteiro e tamanho são públicos.
        for key in (
            "USUARIO_LINUX",
            "VM_NAME",
            "GPU_PCI_ID",
            "QCOW2_PATH",
            "VM_NIC_MAC",
            "VM_IP_FIXO",
            "AIRLOCK_DIR",
            "NVME_DEVICE",
        ):
            self.assertEqual(config.data_class(key), config.LOCAL_IDENTIFIER, key)
        for key in ("BOOTLOADER", "REDE_MODO", "VM_RAM_MB", "QCOW2_TAMANHO"):
            self.assertEqual(config.data_class(key), config.PUBLIC, key)

    def test_relatorio_de_schema(self) -> None:
        data = config.schema_report({})
        self.assertEqual(data["key_count"], len(config.SCHEMA))
        nomes = {
            data["key_%d_name" % index] for index in range(len(config.KEYS))
        }
        self.assertEqual(nomes, set(config.KEYS))
        for index in range(len(config.KEYS)):
            self.assertIn(data["key_%d_class" % index], config.DATA_CLASSES)

    def test_relatorio_nao_aceita_payload(self) -> None:
        with self.assertRaises(DataError):
            config.schema_report({"algo": "1"})


class ValidatorTests(unittest.TestCase):
    def aceita(self, key: str, *valores: str) -> None:
        for valor in valores:
            config.validate_value(key, valor)

    def recusa(self, key: str, *valores: str) -> None:
        for valor in valores:
            with self.assertRaises(DataError, msg="%s=%r" % (key, valor)):
                config.validate_value(key, valor)

    def test_vazio_sempre_aceito(self) -> None:
        for key in config.KEYS:
            config.validate_value(key, "")

    def test_usuario(self) -> None:
        self.aceita("USUARIO_LINUX", "charloso", "_sys", "a-b_c")
        self.recusa("USUARIO_LINUX", "Charloso", "1charles", "com espaço", "a" * 33)

    def test_vm_name(self) -> None:
        self.aceita("VM_NAME", "win11", "vwin11", "vm.1-teste")
        self.recusa("VM_NAME", "-inicio", "com espaço", "a" * 64)

    def test_bootloader_e_modo(self) -> None:
        self.aceita("BOOTLOADER", "grub", "kernelstub")
        self.recusa("BOOTLOADER", "systemd-boot", "GRUB")
        self.aceita("REDE_MODO", "bridge", "nat")
        self.recusa("REDE_MODO", "roteado")

    def test_bdf_e_vendor(self) -> None:
        self.aceita("GPU_PCI_ID", "0000:07:00.0", "0000:0A:00.7")
        self.recusa("GPU_PCI_ID", "07:00.0", "0000:07:00.8", "zzzz:07:00.0")
        self.aceita("GPU_VENDOR_DEVICE_ID", "10de:2504")
        self.recusa("GPU_VENDOR_DEVICE_ID", "10de:250", "10de-2504")

    def test_caminhos(self) -> None:
        self.aceita("NVME_DEVICE", "/dev/nvme0n1", "/mnt/disco com espaço")
        self.recusa(
            "NVME_DEVICE",
            "relativo",
            "/tmp/../etc",
            "/tmp/./x",
            "/tmp/x;y",
            "/tmp/x$y",
            "/tmp/x`y",
            '/tmp/x"y',
            "/tmp/x#y",
        )

    def test_artefato_de_vm(self) -> None:
        self.aceita("ISO_WINDOWS", "/vm/Win11.iso", "/vm/Windows 11.iso")
        self.recusa(
            "ISO_WINDOWS",
            "/home/alice/Win11.iso",
            "/vm/sub/Win11.iso",
            "/vm/",
            "/vm/a,b.iso",
        )

    def test_inteiros(self) -> None:
        self.aceita("VM_RAM_MB", "1024", "22528")
        self.recusa("VM_RAM_MB", "1023", "0", "12345678901", "8k", "-1")
        # I9.12-D9: HUGEPAGES_1G aceitava "0" e "22" pelo schema até `af07725`.
        # Agora ela não está mais no schema, e `validate_value` a recusa como
        # qualquer chave que não pertence à allowlist.
        with self.assertRaises(DataError):
            config.validate_value("HUGEPAGES_1G", "22")

    def test_politica_de_memoria(self) -> None:
        # I9.12-D8: eram quatro valores, com `hugetlb-1g-boot` no fim.
        self.aceita("MEMORIA_MODO", "normal", "hugetlb-2m", "hugetlb-1g")
        self.recusa("MEMORIA_MODO", "hugetlb-1g-boot", "hugetlb", "2m", "NORMAL")

    def test_tamanho_qcow2(self) -> None:
        self.aceita("QCOW2_TAMANHO", "250G", "1T", "500M")
        self.recusa("QCOW2_TAMANHO", "250", "0G", "250GB", "250g")

    def test_lista_de_cpus(self) -> None:
        self.aceita("CPUS_VM", "0", "2-5", "0-1,4-5", "1,3,5")
        # Valor vazio é o idioma de reset e é sempre aceito, por contrato.
        self.recusa("CPUS_VM", "5-2", "0,0", "0-1,1-2", "a-b", "0-")

    def test_mac_e_ipv4(self) -> None:
        self.aceita("VM_NIC_MAC", "52:54:00:ab:cd:ef", "52:54:00:AB:CD:EF")
        self.recusa("VM_NIC_MAC", "52:54:00:ab:cd", "5254.00ab.cdef")
        self.aceita("VM_IP_FIXO", "192.168.0.10", "10.0.0.1")
        self.recusa("VM_IP_FIXO", "192.168.0.256", "192.168.0", "1.2.3.4.5")

    def test_cidr_privado(self) -> None:
        self.aceita("REDE_NAT_CIDR", "10.20.30.0/24", "172.16.0.0/24", "192.168.77.0/24")
        self.recusa(
            "REDE_NAT_CIDR",
            "192.168.77.1/24",
            "192.168.77.0/16",
            "8.8.8.0/24",
            "172.32.0.0/24",
        )

    def test_grupo_dedicado(self) -> None:
        self.aceita("VM_STORAGE_GROUP", "vm-passthrough", "vm-passthrough-lab")
        self.recusa("VM_STORAGE_GROUP", "disk", "sudo", "libvirt", "vm-passthrough-")

    def test_interface_e_rede(self) -> None:
        self.aceita("INTERFACE_FISICA", "enp6s0", "wlp5s0")
        self.recusa("INTERFACE_FISICA", "interface-longa-demais", "-eth0")
        self.aceita("REDE_LIBVIRT", "passthrough-nat")

    def test_valores_de_dispensa(self) -> None:
        for key in config.WAIVER_KEYS:
            self.aceita(key, "sim", "nao")
            self.recusa(key, "yes", "true", "SIM", "1")

    def test_chave_desconhecida(self) -> None:
        with self.assertRaises(DataError) as contexto:
            config.validate_value("CHAVE_INEXISTENTE", "x")
        self.assertIn(config.SECRET, str(contexto.exception))

    def test_valor_gigante(self) -> None:
        with self.assertRaises(DataError):
            config.validate_value("AIRLOCK_DIR", "/" + "a" * 5000)

    def test_diagnostico_nao_publica_valor_bruto(self) -> None:
        canario = "CANARIO-SECRETO-I4-8fe21c"
        with self.assertRaises(DataError) as contexto:
            config.validate_value("VM_NAME", canario + " com espaço")
        mensagem = str(contexto.exception)
        self.assertNotIn(canario, mensagem)
        self.assertIn("VM_NAME", mensagem)
        self.assertIn(config.LOCAL_IDENTIFIER, mensagem)

    def test_validate_pair(self) -> None:
        data = config.validate_pair({"key": "VM_NAME", "value": "win11"})
        self.assertEqual(data["valid"], 1)
        self.assertEqual(data["data_class"], config.LOCAL_IDENTIFIER)
        with self.assertRaises(DataError):
            config.validate_pair({"key": "VM_NAME", "value": "com espaço"})
        with self.assertRaises(DataError):
            config.validate_pair({"key": "VM_NAME", "value": 7})
        with self.assertRaises(DataError):
            config.validate_pair({"value": "x"})


class LiteralTests(unittest.TestCase):
    def test_aspas_duplas_com_escapes_inertes(self) -> None:
        self.assertEqual(
            config.decode_literal(r'"barra\\ aspas\" dólar\$ crase\`"'),
            'barra\\ aspas" dólar$ crase`',
        )

    def test_dolar_nao_escapado_e_literal(self) -> None:
        # A expansão nunca acontece: o texto entra como dado.
        self.assertEqual(
            config.decode_literal('"$(touch /tmp/x)"'), "$(touch /tmp/x)"
        )

    def test_aspas_simples(self) -> None:
        self.assertEqual(config.decode_literal("'fixture'"), "fixture")
        self.assertEqual(config.decode_literal("'com $ cru'"), "com $ cru")

    def test_nao_cotado_restrito(self) -> None:
        self.assertEqual(config.decode_literal("grub"), "grub")
        self.assertEqual(config.decode_literal("/vm/a.iso"), "/vm/a.iso")
        self.assertEqual(config.decode_literal("grub # nota"), "grub")

    def test_nao_cotado_com_caractere_proibido(self) -> None:
        for bruto in ("com espaço", "a;b", "a|b", "a`b", "a$b", 'a"b'):
            with self.assertRaises(DataError, msg=bruto):
                config.decode_literal(bruto)

    def test_comentario_depois_do_literal(self) -> None:
        self.assertEqual(config.decode_literal('"x" # nota'), "x")
        self.assertEqual(config.decode_literal("'x'   "), "x")
        with self.assertRaises(DataError):
            config.decode_literal('"x" lixo')
        with self.assertRaises(DataError):
            config.decode_literal("'x' lixo")

    def test_literal_nao_fechado(self) -> None:
        with self.assertRaises(DataError):
            config.decode_literal('"aberto')
        with self.assertRaises(DataError):
            config.decode_literal("'aberto")

    def test_escape_nao_suportado(self) -> None:
        with self.assertRaises(DataError):
            config.decode_literal(r'"a\nb"')

    def test_vazio(self) -> None:
        self.assertEqual(config.decode_literal(""), "")
        self.assertEqual(config.decode_literal("   "), "")

    def test_round_trip_de_serializacao(self) -> None:
        for valor in (
            "simples",
            "com espaço",
            'barra\\ aspas" dólar$ crase`',
            "/vm/Windows 11.qcow2",
            "acentuação ção",
            "# não é comentário",
        ):
            serializado = config.encode_literal(valor)
            self.assertEqual(config.decode_literal(serializado), valor, valor)

    def test_encode_recusa_nao_texto(self) -> None:
        with self.assertRaises(DataError):
            config.encode_literal(7)


class DocumentTests(unittest.TestCase):
    def test_parse_preserva_estrutura(self) -> None:
        documento = config.parse_document(ROUNDTRIP)
        self.assertEqual(documento["values"]["VM_NAME"], "win11-fixture")
        self.assertEqual(documento["values"]["USUARIO_LINUX"], "fixture")
        self.assertEqual(documento["values"]["BOOTLOADER"], "grub")
        self.assertEqual(documento["values"]["QCOW2_PATH"], "/vm/Windows 11.qcow2")
        self.assertTrue(documento["final_newline"])
        self.assertEqual(documento["order"][0], "USUARIO_LINUX")
        self.assertEqual(documento["invalid"], [])

    def test_sem_newline_final(self) -> None:
        documento = config.parse_document('VM_NAME="x"')
        self.assertFalse(documento["final_newline"])
        self.assertEqual(documento["values"]["VM_NAME"], "x")

    def test_documento_vazio(self) -> None:
        documento = config.parse_document("")
        self.assertEqual(documento["values"], {})
        self.assertEqual(documento["lines"], [])

    def test_chave_com_espaco_antes_do_igual(self) -> None:
        documento = config.parse_document('VM_NAME  ="x"\n')
        self.assertEqual(documento["values"]["VM_NAME"], "x")

    def test_linha_indentada(self) -> None:
        documento = config.parse_document('   VM_NAME="x"\n')
        self.assertEqual(documento["values"]["VM_NAME"], "x")

    def test_chave_duplicada(self) -> None:
        with self.assertRaises(DataError) as contexto:
            config.parse_document('VM_NAME="a"\nVM_NAME="b"\n')
        self.assertIn("repetida na linha 2", str(contexto.exception))

    def test_chave_desconhecida(self) -> None:
        with self.assertRaises(DataError) as contexto:
            config.parse_document('CHAVE_NAO_PERMITIDA="x"\n')
        self.assertIn(config.SECRET, str(contexto.exception))

    def test_linha_invalida(self) -> None:
        with self.assertRaises(DataError) as contexto:
            config.parse_document("isto nao e chave=valor\n")
        self.assertIn("Linha 1", str(contexto.exception))

    def test_nul_recusado(self) -> None:
        with self.assertRaises(DataError):
            config.parse_document('VM_NAME="a\x00b"\n')

    def test_limite_de_linhas(self) -> None:
        with self.assertRaises(DataError):
            config.parse_document("# c\n" * (config.MAX_LINES + 1))

    def test_limite_de_bytes(self) -> None:
        with self.assertRaises(DataError):
            config.parse_document("#" + "a" * config.MAX_DOCUMENT_BYTES + "\n")

    def test_render_substitui_na_propria_linha(self) -> None:
        documento = config.parse_document(ROUNDTRIP)
        texto = config.render_document(documento, {"VM_NAME": "novo"})
        linhas = texto.split("\n")
        self.assertEqual(linhas[0], "# fixture pública: comentários, ordem, espaços e quoting")
        self.assertEqual(linhas[2], "USUARIO_LINUX='fixture'")
        self.assertEqual(linhas[3], 'VM_NAME="novo"')
        self.assertEqual(linhas[4], "BOOTLOADER=grub")

    def test_render_acrescenta_chave_nova(self) -> None:
        documento = config.parse_document('VM_NAME="x"\n')
        texto = config.render_document(documento, {"REDE_MODO": "nat"})
        self.assertEqual(texto, 'VM_NAME="x"\nREDE_MODO="nat"\n')

    def test_render_preserva_ausencia_de_newline(self) -> None:
        documento = config.parse_document('VM_NAME="x"')
        texto = config.render_document(documento, {"VM_NAME": "y"})
        self.assertEqual(texto, 'VM_NAME="y"')

    def test_render_ganha_newline_ao_acrescentar(self) -> None:
        documento = config.parse_document('VM_NAME="x"')
        texto = config.render_document(documento, {"REDE_MODO": "nat"})
        self.assertEqual(texto, 'VM_NAME="x"\nREDE_MODO="nat"\n')

    def test_render_recusa_chave_desconhecida(self) -> None:
        documento = config.parse_document('VM_NAME="x"\n')
        with self.assertRaises(DataError):
            config.render_document(documento, {"NAO_EXISTE": "x"})

    def test_render_recusa_valor_invalido(self) -> None:
        documento = config.parse_document('VM_NAME="x"\n')
        with self.assertRaises(DataError):
            config.render_document(documento, {"VM_RAM_MB": "12"})

    def test_render_recusa_valor_nao_texto(self) -> None:
        documento = config.parse_document('VM_NAME="x"\n')
        with self.assertRaises(DataError):
            config.render_document(documento, {"VM_RAM_MB": 4096})

    def test_build_document_round_trip(self) -> None:
        data, texto = config.build_document(
            {"text": ROUNDTRIP, "updates": {"VM_NAME": "novo", "REDE_MODO": "nat"}}
        )
        self.assertEqual(data["changed"], 1)
        self.assertEqual(data["update_count"], 2)
        recarregado = config.parse_document(texto)
        self.assertEqual(recarregado["values"]["VM_NAME"], "novo")
        self.assertEqual(recarregado["values"]["REDE_MODO"], "nat")
        self.assertEqual(recarregado["values"]["QCOW2_PATH"], "/vm/Windows 11.qcow2")

    def test_build_document_idempotente(self) -> None:
        data, texto = config.build_document(
            {"text": ROUNDTRIP, "updates": {"VM_NAME": "win11-fixture"}}
        )
        # A linha perde o comentário de fim de linha, exatamente como o
        # salvar_conf histórico fazia, então o texto muda uma vez e só uma.
        segundo, texto2 = config.build_document(
            {"text": texto, "updates": {"VM_NAME": "win11-fixture"}}
        )
        self.assertEqual(segundo["changed"], 0)
        self.assertEqual(texto, texto2)

    def test_build_document_pares_planos(self) -> None:
        data, texto = config.build_document(
            {"text": ROUNDTRIP, "set_vm_name": "por-pares"}
        )
        self.assertEqual(data["changed"], 1)
        self.assertIn('VM_NAME="por-pares"', texto)

    def test_build_document_sem_atualizacao(self) -> None:
        with self.assertRaises(DataError):
            config.build_document({"text": ROUNDTRIP})

    def test_build_document_updates_invalido(self) -> None:
        with self.assertRaises(DataError):
            config.build_document({"text": ROUNDTRIP, "updates": "x"})

    def test_inspect_config(self) -> None:
        data = config.inspect_config({"text": ROUNDTRIP})
        self.assertEqual(data["value_vm_name"], "win11-fixture")
        self.assertEqual(data["present_vm_name"], 1)
        self.assertEqual(data["present_iso_windows"], 0)
        self.assertEqual(data["value_iso_windows"], "")
        self.assertEqual(data["present_count"], 5)
        self.assertEqual(data["key_count"], len(config.SCHEMA))


class LegacyIsoTests(unittest.TestCase):
    LEGADO = (
        "# conf legado\n"
        'VM_NAME="win11"\n'
        'ISO_WINDOWS="/home/alice/Downloads/Win11.iso"\n'
        'ISO_VIRTIO="/vm/virtio-win.iso"\n'
    )

    def test_classifica_sem_abrir_caminho(self) -> None:
        data = config.legacy_scan({"text": self.LEGADO})
        self.assertEqual(data["iso_windows_state"], "invalida")
        self.assertEqual(data["iso_virtio_state"], "valida")
        self.assertEqual(data["needs_migration"], 1)
        self.assertEqual(data["scanned_keys"], 2)

    def test_nao_publica_o_valor_legado(self) -> None:
        data = config.legacy_scan({"text": self.LEGADO})
        for valor in data.values():
            self.assertNotIn("/home/alice", str(valor))

    def test_ausente_e_vazia(self) -> None:
        data = config.legacy_scan({"text": 'VM_NAME="x"\nISO_VIRTIO=""\n'})
        self.assertEqual(data["iso_windows_state"], "ausente")
        self.assertEqual(data["iso_virtio_state"], "vazia")
        self.assertEqual(data["needs_migration"], 0)

    def test_literal_malformado_conta_como_invalida(self) -> None:
        data = config.legacy_scan({"text": 'ISO_WINDOWS="aberto\n'})
        self.assertEqual(data["iso_windows_state"], "invalida")
        self.assertEqual(data["needs_migration"], 1)

    def test_duplicada(self) -> None:
        data = config.legacy_scan(
            {"text": 'ISO_WINDOWS="/vm/a.iso"\nISO_WINDOWS="/vm/b.iso"\n'}
        )
        self.assertEqual(data["iso_windows_state"], "duplicada")
        self.assertEqual(data["needs_migration"], 1)

    def test_ignora_linha_fora_do_formato(self) -> None:
        # O parser estrito é quem recusa o arquivo; o scanner só classifica ISOs.
        data = config.legacy_scan(
            {"text": "lixo sem igual\nCHAVE_DESCONHECIDA=1\nISO_WINDOWS=/vm/a.iso\n"}
        )
        self.assertEqual(data["iso_windows_state"], "valida")

    def test_texto_obrigatorio(self) -> None:
        with self.assertRaises(DataError):
            config.legacy_scan({})

    def test_tolerancia_permite_migrar(self) -> None:
        documento = config.parse_document(
            self.LEGADO, tolerate=("ISO_WINDOWS",)
        )
        self.assertEqual(documento["invalid"], ["ISO_WINDOWS"])
        self.assertNotIn("ISO_WINDOWS", documento["values"])
        texto = config.render_document(documento, {"ISO_WINDOWS": ""})
        recarregado = config.parse_document(texto)
        self.assertEqual(recarregado["values"]["ISO_WINDOWS"], "")

    def test_tolerancia_exige_novo_valor(self) -> None:
        with self.assertRaises(DataError) as contexto:
            config.build_document(
                {
                    "text": self.LEGADO,
                    "migrate_keys": ["ISO_WINDOWS"],
                    "updates": {"VM_NAME": "outro"},
                }
            )
        self.assertIn("sem novo valor", str(contexto.exception))

    def test_tolerancia_nao_vaza_para_outras_chaves(self) -> None:
        ruim = self.LEGADO + 'VM_RAM_MB="12"\n'
        with self.assertRaises(DataError):
            config.build_document(
                {
                    "text": ruim,
                    "migrate_keys": ["ISO_WINDOWS"],
                    "updates": {"ISO_WINDOWS": ""},
                }
            )

    def test_migrate_keys_fora_do_schema(self) -> None:
        with self.assertRaises(DataError):
            config.build_document(
                {
                    "text": self.LEGADO,
                    "migrate_keys": ["NAO_EXISTE"],
                    "updates": {"ISO_WINDOWS": ""},
                }
            )

    def test_migracao_publica_um_candidato_valido(self) -> None:
        data, texto = config.build_document(
            {
                "text": self.LEGADO,
                "migrate_keys": ["ISO_WINDOWS"],
                "updates": {"ISO_WINDOWS": "/vm/Win11.iso"},
            }
        )
        self.assertEqual(data["migrated_count"], 1)
        self.assertEqual(data["invalid_before"], 1)
        recarregado = config.parse_document(texto)
        self.assertEqual(recarregado["values"]["ISO_WINDOWS"], "/vm/Win11.iso")
        self.assertNotIn("/home/alice", texto)


class SensitiveFileTests(unittest.TestCase):
    """Política de arquivo e revalidação TOCTOU do caminho de publicação."""

    def setUp(self) -> None:
        self.raiz = tempfile.mkdtemp(prefix="i4-config.")
        os.chmod(self.raiz, 0o700)
        self.dir_fd = os.open(self.raiz, os.O_RDONLY | os.O_DIRECTORY)
        self.nome = "passthrough.conf"
        self.escrever(ROUNDTRIP, 0o600)

    def tearDown(self) -> None:
        os.close(self.dir_fd)
        for nome in os.listdir(self.raiz):
            caminho = os.path.join(self.raiz, nome)
            if os.path.islink(caminho) or os.path.isfile(caminho):
                os.unlink(caminho)
            else:
                os.rmdir(caminho)
        os.rmdir(self.raiz)

    def escrever(self, texto: str, modo: int = 0o600, nome: str | None = None) -> str:
        caminho = os.path.join(self.raiz, nome or self.nome)
        with io.open(caminho, "w", encoding="utf-8") as fluxo:
            fluxo.write(texto)
        os.chmod(caminho, modo)
        return caminho

    def ler(self, nome: str | None = None) -> str:
        with io.open(
            os.path.join(self.raiz, nome or self.nome), encoding="utf-8"
        ) as fluxo:
            return fluxo.read()

    # --- leitura --------------------------------------------------------------

    def test_leitura_normal(self) -> None:
        texto, estado = cli._read_sensitive(self.dir_fd, self.nome, required=False)
        self.assertEqual(texto, ROUNDTRIP)
        self.assertTrue(estado.exists)
        self.assertEqual(estado.mode, 0o600)

    def test_ausente_nao_obrigatorio(self) -> None:
        texto, estado = cli._read_sensitive(self.dir_fd, "nao-existe", required=False)
        self.assertEqual(texto, "")
        self.assertFalse(estado.exists)

    def test_ausente_obrigatorio(self) -> None:
        with self.assertRaises(MissingInputError):
            cli._read_sensitive(self.dir_fd, "nao-existe", required=True)

    def test_symlink_recusado(self) -> None:
        os.symlink(self.nome, os.path.join(self.raiz, "link.conf"))
        with self.assertRaises(UsageError):
            cli._read_sensitive(self.dir_fd, "link.conf", required=False)

    def test_hardlink_recusado(self) -> None:
        os.link(
            os.path.join(self.raiz, self.nome), os.path.join(self.raiz, "outro.conf")
        )
        with self.assertRaises(ConflictError) as contexto:
            cli._read_sensitive(self.dir_fd, self.nome, required=False)
        self.assertIn("mais de um link", str(contexto.exception))

    def test_modo_gravavel_por_outros_recusado(self) -> None:
        self.escrever(ROUNDTRIP, 0o666)
        with self.assertRaises(UsageError) as contexto:
            cli._read_sensitive(self.dir_fd, self.nome, required=False)
        self.assertIn("gravável por outros", str(contexto.exception))

    def test_modo_gravavel_por_grupo_aceito_e_apertado(self) -> None:
        # umask 002 produz 0664 legitimamente; a leitura aceita e a publicação
        # aperta o modo, nunca o afrouxa.
        self.escrever(ROUNDTRIP, 0o664)
        texto, estado = cli._read_sensitive(self.dir_fd, self.nome, required=False)
        self.assertEqual(estado.mode, 0o664)
        cli._publish_sensitive(self.dir_fd, self.nome, texto, estado)
        info = os.stat(os.path.join(self.raiz, self.nome))
        self.assertEqual(stat.S_IMODE(info.st_mode), 0o640)

    def test_modo_herdado_de_copia_manual_e_convergido(self) -> None:
        # 0755 é o que uma cópia manual do exemplo produz; a publicação retira
        # o acesso de terceiros sem apagar a intenção de dono/grupo.
        self.escrever(ROUNDTRIP, 0o755)
        texto, estado = cli._read_sensitive(self.dir_fd, self.nome, required=False)
        cli._publish_sensitive(self.dir_fd, self.nome, texto, estado)
        info = os.stat(os.path.join(self.raiz, self.nome))
        self.assertEqual(stat.S_IMODE(info.st_mode), 0o750)

    def test_modo_0600_permanece(self) -> None:
        texto, estado = cli._read_sensitive(self.dir_fd, self.nome, required=False)
        cli._publish_sensitive(self.dir_fd, self.nome, texto, estado)
        info = os.stat(os.path.join(self.raiz, self.nome))
        self.assertEqual(stat.S_IMODE(info.st_mode), 0o600)

    def test_diretorio_recusado(self) -> None:
        os.mkdir(os.path.join(self.raiz, "pasta.conf"), 0o700)
        with self.assertRaises(UsageError):
            cli._read_sensitive(self.dir_fd, "pasta.conf", required=False)

    def test_acima_do_limite(self) -> None:
        self.escrever("# " + "a" * config.MAX_DOCUMENT_BYTES + "\n")
        with self.assertRaises(DataError):
            cli._read_sensitive(self.dir_fd, self.nome, required=False)

    def test_bytes_invalidos(self) -> None:
        caminho = os.path.join(self.raiz, self.nome)
        with io.open(caminho, "wb") as fluxo:
            fluxo.write(b'VM_NAME="\xff\xfe"\n')
        os.chmod(caminho, 0o600)
        with self.assertRaises(DataError):
            cli._read_sensitive(self.dir_fd, self.nome, required=False)

    # --- publicação -----------------------------------------------------------

    def test_publicacao_preserva_modo_e_conteudo(self) -> None:
        self.escrever(ROUNDTRIP, 0o640)
        texto, estado = cli._read_sensitive(self.dir_fd, self.nome, required=False)
        documento = config.parse_document(texto)
        novo = config.render_document(documento, {"VM_NAME": "publicado"})
        escritos = cli._publish_sensitive(self.dir_fd, self.nome, novo, estado)
        self.assertEqual(escritos, len(novo.encode("utf-8")))
        self.assertEqual(self.ler(), novo)
        info = os.stat(os.path.join(self.raiz, self.nome))
        self.assertEqual(stat.S_IMODE(info.st_mode), 0o640)
        self.assertEqual(info.st_nlink, 1)

    def test_publicacao_cria_quando_ausente(self) -> None:
        estado = cli._SensitiveState(None)
        cli._publish_sensitive(self.dir_fd, "novo.conf", 'VM_NAME="x"\n', estado)
        info = os.stat(os.path.join(self.raiz, "novo.conf"))
        self.assertEqual(stat.S_IMODE(info.st_mode), 0o600)

    def test_publicacao_nao_deixa_temporario(self) -> None:
        texto, estado = cli._read_sensitive(self.dir_fd, self.nome, required=False)
        cli._publish_sensitive(self.dir_fd, self.nome, texto + "\n", estado)
        sobras = [nome for nome in os.listdir(self.raiz) if ".tmp." in nome]
        self.assertEqual(sobras, [])

    def test_conflito_por_troca_de_inode(self) -> None:
        texto, estado = cli._read_sensitive(self.dir_fd, self.nome, required=False)
        # Substituição concorrente entre a leitura e a publicação: o inode muda.
        substituto = os.path.join(self.raiz, "substituto")
        with io.open(substituto, "w", encoding="utf-8") as fluxo:
            fluxo.write('VM_NAME="concorrente"\n')
        os.chmod(substituto, 0o600)
        os.replace(substituto, os.path.join(self.raiz, self.nome))
        with self.assertRaises(ConflictError) as contexto:
            cli._publish_sensitive(self.dir_fd, self.nome, texto, estado)
        self.assertIn("mudou entre a leitura e a publicação", str(contexto.exception))
        self.assertEqual(self.ler(), 'VM_NAME="concorrente"\n')
        self.assertEqual([n for n in os.listdir(self.raiz) if ".tmp." in n], [])

    def test_conflito_por_link_count(self) -> None:
        texto, estado = cli._read_sensitive(self.dir_fd, self.nome, required=False)
        os.link(
            os.path.join(self.raiz, self.nome), os.path.join(self.raiz, "sombra.conf")
        )
        with self.assertRaises(ConflictError):
            cli._publish_sensitive(self.dir_fd, self.nome, texto, estado)
        self.assertEqual(self.ler(), ROUNDTRIP)

    def test_conflito_por_modo(self) -> None:
        texto, estado = cli._read_sensitive(self.dir_fd, self.nome, required=False)
        os.chmod(os.path.join(self.raiz, self.nome), 0o640)
        with self.assertRaises(ConflictError):
            cli._publish_sensitive(self.dir_fd, self.nome, texto, estado)

    def test_conflito_por_remocao(self) -> None:
        texto, estado = cli._read_sensitive(self.dir_fd, self.nome, required=False)
        os.unlink(os.path.join(self.raiz, self.nome))
        with self.assertRaises(ConflictError):
            cli._publish_sensitive(self.dir_fd, self.nome, texto, estado)

    def test_conflito_por_symlink_no_lugar(self) -> None:
        texto, estado = cli._read_sensitive(self.dir_fd, self.nome, required=False)
        os.unlink(os.path.join(self.raiz, self.nome))
        os.symlink("/etc/passwd", os.path.join(self.raiz, self.nome))
        with self.assertRaises(ConflictError):
            cli._publish_sensitive(self.dir_fd, self.nome, texto, estado)

    def test_candidato_acima_do_limite(self) -> None:
        _texto, estado = cli._read_sensitive(self.dir_fd, self.nome, required=False)
        gigante = "#" + "a" * config.MAX_DOCUMENT_BYTES + "\n"
        with self.assertRaises(DataError):
            cli._publish_sensitive(self.dir_fd, self.nome, gigante, estado)
        self.assertEqual(self.ler(), ROUNDTRIP)

    def test_nome_sensivel_recusa_formato(self) -> None:
        for nome in ("", "../fuga", "com/barra", "a" * 65, ".oculto"):
            with self.assertRaises(UsageError, msg=nome):
                cli._sensitive_name({"name": nome})
        self.assertEqual(cli._sensitive_name({"name": "passthrough.conf"}), "passthrough.conf")

    def test_dir_fd_invalido(self) -> None:
        for bruto in ("", "abc", "0", "1", "2", "99999"):
            with self.assertRaises(UsageError, msg=bruto):
                cli._resolve_dir_fd({"--dir-fd": bruto})
        with self.assertRaises(UsageError):
            cli._resolve_dir_fd({})

    def test_dir_fd_de_arquivo_recusado(self) -> None:
        descritor = os.open(os.path.join(self.raiz, self.nome), os.O_RDONLY)
        try:
            with self.assertRaises(UsageError):
                cli._resolve_dir_fd({"--dir-fd": str(descritor)})
        finally:
            os.close(descritor)

    def test_dir_fd_gravavel_por_grupo_aceito(self) -> None:
        os.chmod(self.raiz, 0o775)
        try:
            self.assertEqual(
                cli._resolve_dir_fd({"--dir-fd": str(self.dir_fd)}), self.dir_fd
            )
        finally:
            os.chmod(self.raiz, 0o700)

    def test_dir_fd_gravavel_por_outros_recusado(self) -> None:
        os.chmod(self.raiz, 0o777)
        try:
            with self.assertRaises(UsageError):
                cli._resolve_dir_fd({"--dir-fd": str(self.dir_fd)})
        finally:
            os.chmod(self.raiz, 0o700)

    def test_dir_fd_valido(self) -> None:
        self.assertEqual(
            cli._resolve_dir_fd({"--dir-fd": str(self.dir_fd)}), self.dir_fd
        )


if __name__ == "__main__":
    unittest.main()
