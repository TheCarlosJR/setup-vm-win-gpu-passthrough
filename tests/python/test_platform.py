"""Plataforma, imutabilidade e eixos de fabricante (I8.1, I8.2, I8.7, I8.8)."""
import ast
import builtins
import unittest
from pathlib import Path

from passthrough_core import platform
from passthrough_core.errors import DataError

UBUNTU = "\n".join(
    (
        'NAME="Ubuntu"',
        "ID=ubuntu",
        "ID_LIKE=debian",
        'VERSION_ID="26.04"',
        "VERSION_CODENAME=resolute",
        "",
    )
)

# Conteúdo real das 11 fixtures de `tests/fixtures/platform/*/os-release`, com
# os valores esperados de `expected.env`. A cópia é conferida byte a byte pelo
# teste de sincronia sempre que a árvore de fixtures estiver acessível.
FIXTURES = {
    "ubuntu": {
        "text": 'NAME="Ubuntu"\nVERSION="26.04 LTS (Resolute Raccoon)"\nID=ubuntu\nID_LIKE=debian\nVERSION_ID="26.04"\nVERSION_CODENAME=resolute\nPRETTY_NAME="Ubuntu 26.04 LTS"\nHOME_URL="https://www.ubuntu.com/"\n',
        "state": "present",
        "id": "ubuntu",
        "id_like": "debian",
        "version_id": "26.04",
        "version_codename": "resolute",
        "immutable": "false",
        "support": platform.SUPPORT_SUPPORTED,
        "profile": "ubuntu",
    },
    "pop-os": {
        "text": 'NAME="Pop!_OS"\nVERSION="22.04 LTS"\nID=pop\nID_LIKE="ubuntu debian"\nVERSION_ID="22.04"\nVERSION_CODENAME=jammy\nPRETTY_NAME="Pop!_OS 22.04 LTS"\nHOME_URL="https://pop.system76.com"\n',
        "state": "present",
        "id": "pop",
        "id_like": "ubuntu debian",
        "version_id": "22.04",
        "version_codename": "jammy",
        "immutable": "false",
        "support": platform.SUPPORT_SUPPORTED,
        "profile": "pop-os",
    },
    "debian": {
        "text": 'PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"\nNAME="Debian GNU/Linux"\nVERSION_ID="12"\nVERSION="12 (bookworm)"\nVERSION_CODENAME=bookworm\nID=debian\nID_LIKE=debian\nHOME_URL="https://www.debian.org/"\n',
        "state": "present",
        "id": "debian",
        "id_like": "debian",
        "version_id": "12",
        "version_codename": "bookworm",
        "immutable": "false",
        "support": platform.SUPPORT_DIAGNOSTIC,
        "profile": "",
    },
    "arch": {
        "text": 'NAME="Arch Linux"\nPRETTY_NAME="Arch Linux"\nID=arch\nBUILD_ID=rolling\nANSI_COLOR="38;2;23;147;209"\nHOME_URL="https://archlinux.org/"\n',
        "state": "present",
        "id": "arch",
        "id_like": "",
        "version_id": "",
        "version_codename": "",
        "immutable": "false",
        "support": platform.SUPPORT_DIAGNOSTIC,
        "profile": "",
    },
    "cachyos": {
        "text": 'NAME="CachyOS"\nPRETTY_NAME="CachyOS"\nID=cachyos\nID_LIKE=arch\nBUILD_ID=rolling\nANSI_COLOR="38;2;0;255;255"\nHOME_URL="https://cachyos.org/"\n',
        "state": "present",
        "id": "cachyos",
        "id_like": "arch",
        "version_id": "",
        "version_codename": "",
        "immutable": "false",
        "support": platform.SUPPORT_DIAGNOSTIC,
        "profile": "",
    },
    "fedora": {
        "text": 'NAME="Fedora Linux"\nVERSION="42 (Workstation Edition)"\nID=fedora\nVERSION_ID=42\nVERSION_CODENAME=""\nPLATFORM_ID="platform:f42"\nPRETTY_NAME="Fedora Linux 42 (Workstation Edition)"\nVARIANT="Workstation Edition"\nVARIANT_ID=workstation\n',
        "state": "present",
        "id": "fedora",
        "id_like": "",
        "version_id": "42",
        "version_codename": "",
        "immutable": "false",
        "support": platform.SUPPORT_DIAGNOSTIC,
        "profile": "",
    },
    "opensuse": {
        "text": 'NAME="openSUSE Tumbleweed"\nID="opensuse-tumbleweed"\nID_LIKE="opensuse suse"\nVERSION_ID="20250301"\nPRETTY_NAME="openSUSE Tumbleweed"\nANSI_COLOR="0;32"\nHOME_URL="https://www.opensuse.org/"\n',
        "state": "present",
        "id": "opensuse-tumbleweed",
        "id_like": "opensuse suse",
        "version_id": "20250301",
        "version_codename": "",
        "immutable": "false",
        "support": platform.SUPPORT_DIAGNOSTIC,
        "profile": "",
    },
    "unknown-derivative": {
        "text": 'NAME="Nebula Linux"\nPRETTY_NAME="Nebula Linux 1"\nID=nebula\nID_LIKE="ubuntu debian"\nVERSION_ID="1"\nVERSION_CODENAME=aurora\nHOME_URL="https://invalid.example/nebula"\n',
        "state": "present",
        "id": "nebula",
        "id_like": "ubuntu debian",
        "version_id": "1",
        "version_codename": "aurora",
        "immutable": "false",
        "support": platform.SUPPORT_FAMILY,
        "profile": "",
    },
    "unknown-distro": {
        "text": 'NAME="Orion Experimental OS"\nPRETTY_NAME="Orion Experimental OS 9"\nID=orion\nVERSION_ID="9"\nVERSION_CODENAME=unknown\nHOME_URL="https://invalid.example/orion"\n',
        "state": "present",
        "id": "orion",
        "id_like": "",
        "version_id": "9",
        "version_codename": "unknown",
        "immutable": "false",
        "support": platform.SUPPORT_BLOCKED,
        "profile": "",
    },
    "malicious-os-release": {
        "text": 'NAME="Hostile fixture"\nID=hostile\nID_LIKE="ubuntu debian"\nVERSION_ID="1"\nVERSION_CODENAME=$(printf \'payload-in-command-substitution\')\nPRETTY_NAME="`printf \'payload-in-backticks\'`"\nUNSAFE_VALUE=$(printf \'payload-in-unknown-key\')\nprintf \'PLATFORM_FIXTURE_PAYLOAD_EXECUTED\\n\'\nprintf -v PLATFORM_FIXTURE_BUILTIN_EXECUTED 1\n',
        "state": "malformed",
        "id": "",
        "id_like": "",
        "version_id": "",
        "version_codename": "",
        "immutable": "false",
        "support": platform.SUPPORT_BLOCKED,
        "profile": "",
    },
    "immutable": {
        "text": 'NAME="Fedora Linux"\nVERSION="42 (Silverblue)"\nID=fedora\nVERSION_ID=42\nVERSION_CODENAME=""\nPLATFORM_ID="platform:f42"\nPRETTY_NAME="Fedora Linux 42.20250301.0 (Silverblue)"\nVARIANT="Silverblue"\nVARIANT_ID=silverblue\n',
        "state": "present",
        "id": "fedora",
        "id_like": "",
        "version_id": "42",
        "version_codename": "",
        "immutable": "true",
        "support": platform.SUPPORT_DIAGNOSTIC,
        # I8.3: era `""`. Host imutável deixou de ser "sem perfil" e passou a ter
        # perfil próprio, diagnóstico: campo vazio era indistinguível de "não
        # classificado", e essa ambiguidade é o que a tarefa mandou fechar.
        "profile": platform.PROFILE_IMMUTABLE,
    },
}

# Um payload que tenta transformar campo de conteúdo em caminho. Se algum dia
# alguém abrir um caminho aqui, é este texto que aparece no rastro.
TRAVESSIA = "../../../../etc/shadow"

CPUINFO_AMD = "\n".join(
    (
        "processor\t: 0",
        "vendor_id\t: AuthenticAMD",
        "model name\t: AMD Ryzen 9 5900X 12-Core Processor",
        "processor\t: 1",
        "vendor_id\t: AuthenticAMD",
        "",
    )
)
CPUINFO_INTEL = CPUINFO_AMD.replace("AuthenticAMD", "GenuineIntel")
LSCPU_AMD = "\n".join(
    (
        "Architecture:                    x86_64",
        "Vendor ID:                       AuthenticAMD",
        "Model name:                      AMD Ryzen 9 5900X 12-Core Processor",
        "",
    )
)
LSCPU_INTEL = LSCPU_AMD.replace("AuthenticAMD", "GenuineIntel")

PCI_NVIDIA = "\n".join(
    (
        "0000:00:00.0 Host bridge [0600]: Advanced Micro Devices, Inc. [AMD] Root Complex [1022:1480]",
        "0000:01:00.0 VGA compatible controller [0300]: NVIDIA Corporation AD104 [GeForce RTX 4070] [10de:2786] (rev a1)",
        "0000:01:00.1 Audio device [0403]: NVIDIA Corporation AD104 High Definition Audio Controller [10de:22bc] (rev a1)",
        "",
    )
)
PCI_AMD = "\n".join(
    (
        "0000:00:00.0 Host bridge [0600]: Advanced Micro Devices, Inc. [AMD] Root Complex [1022:1480]",
        "0000:03:00.0 VGA compatible controller [0300]: Advanced Micro Devices, Inc. [AMD/ATI] Navi 21 [Radeon RX 6800] [1002:73bf] (rev c1)",
        "0000:03:00.1 Audio device [0403]: Advanced Micro Devices, Inc. [AMD/ATI] Navi 21 HDMI Audio [1002:ab28]",
        "",
    )
)
PCI_INTEL = "\n".join(
    (
        "0000:00:02.0 VGA compatible controller [0300]: Intel Corporation AlderLake-S GT1 [8086:4680] (rev 0c)",
        "",
    )
)
PCI_SEM_VIDEO = "\n".join(
    (
        "0000:00:00.0 Host bridge [0600]: Advanced Micro Devices, Inc. [AMD] Root Complex [1022:1480]",
        "0000:01:00.1 Audio device [0403]: NVIDIA Corporation AD104 High Definition Audio Controller [10de:22bc] (rev a1)",
        "",
    )
)
PCI_DOIS_FABRICANTES = "\n".join(
    (
        "0000:01:00.0 VGA compatible controller [0300]: NVIDIA Corporation AD104 [GeForce RTX 4070] [10de:2786] (rev a1)",
        "0000:03:00.0 VGA compatible controller [0300]: Advanced Micro Devices, Inc. [AMD/ATI] Navi 21 [Radeon RX 6800] [1002:73bf] (rev c1)",
        "",
    )
)
IOMMU_NVIDIA = "\n".join(("14 0000:01:00.0", "14 0000:01:00.1", "0 0000:00:00.0", ""))
IOMMU_SO_AUDIO = "\n".join(("14 0000:01:00.1", "0 0000:00:00.0", ""))


def os_release_payload(text, state="present", arch="x86_64"):
    return {"text": text, "text_state": state, "arch": arch}


def support_payload(text, state="present", arch="x86_64", ostree="not-captured"):
    return {
        "text": text,
        "text_state": state,
        "arch": arch,
        "ostree_evidence": ostree,
    }


def cpu_payload(cpuinfo="", lscpu="", cpuinfo_state=None, lscpu_state=None):
    return {
        "cpuinfo_text": cpuinfo,
        "cpuinfo_state": cpuinfo_state or ("present" if cpuinfo else "absent"),
        "lscpu_text": lscpu,
        "lscpu_state": lscpu_state or ("present" if lscpu else "absent"),
    }


def gpu_payload(pci="", iommu="", bdf="", pci_state=None, iommu_state=None):
    return {
        "pci_text": pci,
        "pci_state": pci_state or ("present" if pci else "absent"),
        "iommu_text": iommu,
        "iommu_state": iommu_state or ("present" if iommu else "absent"),
        "bdf": bdf,
    }


def servico_payload(
    unidades=("libvirtd.socket", "libvirtd.service", "virtqemud.socket", "virtqemud.service"),
    fixture="",
    estados=(),
    source=None,
):
    """Monta o payload do canal de pares como `lib/platform.sh` monta.

    `estados` é a coleção da sonda: uma tupla por unidade, na mesma ordem de
    `unidades`, com os quatro valores lidos. Sem `estados`, a fonte é a
    fixture autoritativa.
    """
    registros = "\n".join("\t".join(item) for item in estados)
    return {
        "service_source": source or ("probe" if estados else "fixture"),
        "unit_order": "\n".join(unidades),
        "fixture_text": fixture,
        "unit_states": registros,
    }


def sonda(unidade, carga="loaded", ativo="inactive", sub="dead", arquivo=""):
    return (unidade, carga, ativo, sub, arquivo)


def publicado(dados, campo):
    """Espelha o que `lib/platform.sh` publica hoje nas globais.

    `_plataforma_ler_os_release` só atribui `PLATAFORMA_ID` e companhia depois
    de todas as validações passarem: leitura recusada deixa as globais no
    estado do reset. O fato tipado continua completo na resposta, mas a
    fachada não pode consumir valor de campo quando `valid` é 0.
    """
    return dados[campo] if dados["valid"] == 1 else ""


def sem_linha(text, prefixo):
    return "\n".join(
        linha for linha in text.split("\n") if not linha.startswith(prefixo)
    )


class ParserOsReleaseTests(unittest.TestCase):
    def test_normaliza_os_release_completo(self) -> None:
        dados = platform.os_release_facts(os_release_payload(UBUNTU))
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["error"], "")
        self.assertEqual(dados["id"], "ubuntu")
        self.assertEqual(dados["id_state"], platform.STATE_DETECTED)
        self.assertEqual(dados["id_evidence"], platform.EVIDENCE_OS_RELEASE)
        self.assertEqual(dados["id_like"], "debian")
        self.assertEqual(dados["id_like_count"], 1)
        self.assertEqual(dados["version_id"], "26.04")
        self.assertEqual(dados["version_codename"], "resolute")
        self.assertEqual(dados["variant_id_state"], platform.STATE_ABSENT)
        self.assertEqual(dados["fields_seen"], 4)

    def test_chave_fora_da_allowlist_e_linha_sem_igual_sao_ignoradas(self) -> None:
        texto = UBUNTU + 'UNSAFE_VALUE=$(printf oops)\nsem-igual\n# comentario=1\n'
        dados = platform.os_release_facts(os_release_payload(texto))
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["fields_seen"], 4)

    def test_cada_campo_ausente_tem_estado_proprio(self) -> None:
        esperado = {
            "ID": ("id", 0, "invalid_id"),
            "ID_LIKE": ("id_like", 1, ""),
            "VERSION_ID": ("version_id", 1, ""),
            "VERSION_CODENAME": ("version_codename", 1, ""),
        }
        for chave, (nome, valido, codigo) in esperado.items():
            with self.subTest(chave=chave):
                dados = platform.os_release_facts(
                    os_release_payload(sem_linha(UBUNTU, chave + "="))
                )
                self.assertEqual(dados["%s_state" % nome], platform.STATE_ABSENT)
                self.assertEqual(dados["%s_evidence" % nome], platform.EVIDENCE_NONE)
                self.assertEqual(dados[nome], "")
                self.assertEqual(dados["valid"], valido)
                self.assertEqual(dados["error_code"], codigo)

    def test_variant_id_ausente_nao_vira_default(self) -> None:
        dados = platform.os_release_facts(os_release_payload(UBUNTU))
        self.assertEqual(dados["variant_id"], "")
        self.assertEqual(dados["variant_id_state"], platform.STATE_ABSENT)

    def test_cada_campo_duplicado_vira_conflitante(self) -> None:
        for chave in platform.OS_RELEASE_KEYS:
            with self.subTest(chave=chave):
                # Duas ocorrências da mesma chave, com valores diferentes: é o
                # conflito que o Bash recusa antes de validar campo algum.
                texto = "ID=ubuntu\n%s=alfa\n%s=beta\n" % (chave, chave)
                dados = platform.os_release_facts(os_release_payload(texto))
                nome = dict(platform.OS_RELEASE_FIELDS)[chave]
                self.assertEqual(dados["valid"], 0)
                self.assertEqual(dados["error_code"], "duplicate_key")
                self.assertEqual(dados["error_field"], chave)
                self.assertEqual(dados["%s_state" % nome], platform.STATE_CONFLICTING)
                self.assertEqual(dados[nome], "")

    def test_duplicata_com_valor_igual_tambem_e_conflito(self) -> None:
        dados = platform.os_release_facts(os_release_payload(UBUNTU + "ID=ubuntu\n"))
        self.assertEqual(dados["error_code"], "duplicate_key")
        self.assertEqual(dados["id_state"], platform.STATE_CONFLICTING)

    def test_campos_apos_o_aborto_sao_desconhecidos_nao_ausentes(self) -> None:
        texto = "ID=ubuntu\nID=ubuntu\nVERSION_ID=26.04\n"
        dados = platform.os_release_facts(os_release_payload(texto))
        self.assertEqual(dados["id_state"], platform.STATE_CONFLICTING)
        self.assertEqual(dados["version_id_state"], platform.STATE_UNKNOWN)
        self.assertEqual(dados["version_id_evidence"], platform.EVIDENCE_NONE)

    def test_valor_com_cr_embutido_e_recusado(self) -> None:
        texto = 'ID=ubuntu\nVERSION_ID="26\r04"\n'
        dados = platform.os_release_facts(os_release_payload(texto))
        self.assertEqual(dados["valid"], 0)
        self.assertEqual(dados["error_code"], "invalid_value")
        self.assertEqual(dados["error_field"], "VERSION_ID")
        self.assertEqual(dados["version_id_state"], platform.STATE_UNKNOWN)

    def test_cr_no_fim_da_linha_e_removido(self) -> None:
        dados = platform.os_release_facts(
            os_release_payload("ID=ubuntu\r\nVERSION_ID=26.04\r\n")
        )
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["version_id"], "26.04")

    def test_valor_invalido_por_padrao_fica_desconhecido(self) -> None:
        casos = (
            ("ID=Ubuntu\n", "invalid_id", "ID", "id"),
            ("ID=ubuntu\nID_LIKE=Debian\n", "invalid_field", "ID_LIKE", "id_like"),
            (
                "ID=ubuntu\nVARIANT_ID=Server\n",
                "invalid_field",
                "VARIANT_ID",
                "variant_id",
            ),
            (
                "ID=ubuntu\nVERSION_ID=26 04\n",
                "invalid_field",
                "VERSION_ID",
                "version_id",
            ),
            (
                "ID=ubuntu\nVERSION_CODENAME=resolute!\n",
                "invalid_field",
                "VERSION_CODENAME",
                "version_codename",
            ),
        )
        for texto, codigo, campo, nome in casos:
            with self.subTest(campo=campo):
                dados = platform.os_release_facts(os_release_payload(texto))
                self.assertEqual(dados["valid"], 0)
                self.assertEqual(dados["error_code"], codigo)
                self.assertEqual(dados["error_field"], campo)
                self.assertEqual(dados["%s_state" % nome], platform.STATE_UNKNOWN)

    def test_primeira_falha_publicada_segue_a_ordem_do_bash(self) -> None:
        # ID inválido e VERSION_ID inválido ao mesmo tempo: o Bash publica ID.
        dados = platform.os_release_facts(
            os_release_payload("ID=Ubuntu\nVERSION_ID=26 04\n")
        )
        self.assertEqual(dados["error_code"], "invalid_id")
        # Duplicata acontece na varredura, antes de qualquer validação.
        dados = platform.os_release_facts(
            os_release_payload("ID=Ubuntu\nVERSION_ID=1\nVERSION_ID=2\n")
        )
        self.assertEqual(dados["error_code"], "duplicate_key")
        self.assertEqual(dados["error_field"], "VERSION_ID")

    def test_aspas_duplas_sao_desescapadas_como_no_bash(self) -> None:
        casos = (
            ('ID_LIKE="ubuntu debian"', "ubuntu debian"),
            ("ID_LIKE='ubuntu debian'", "ubuntu debian"),
            ('VERSION_ID="26.04"', "26.04"),
        )
        for linha, esperado in casos:
            with self.subTest(linha=linha):
                dados = platform.os_release_facts(
                    os_release_payload("ID=ubuntu\n%s\n" % linha)
                )
                nome = "id_like" if "ID_LIKE" in linha else "version_id"
                self.assertEqual(dados[nome], esperado)

    def test_aspas_simples_nao_desescapam(self) -> None:
        # Dentro de aspas simples, `\\"` continua sendo dois caracteres.
        dados = platform.os_release_facts(
            os_release_payload("ID=ubuntu\nVERSION_CODENAME='a\\\"b'\n")
        )
        self.assertEqual(dados["error_code"], "invalid_field")
        self.assertEqual(dados["version_codename_state"], platform.STATE_UNKNOWN)

    def test_id_like_normalizado_preserva_o_texto_bruto(self) -> None:
        dados = platform.os_release_facts(
            os_release_payload('ID=nebula\nID_LIKE="ubuntu   debian"\n')
        )
        self.assertEqual(dados["id_like"], "ubuntu   debian")
        self.assertEqual(dados["id_like_normalized"], "ubuntu debian")
        self.assertEqual(dados["id_like_count"], 2)

    def test_os_release_ausente_ou_ilegivel(self) -> None:
        for estado in ("absent", "unreadable"):
            with self.subTest(estado=estado):
                dados = platform.os_release_facts(os_release_payload("", estado))
                self.assertEqual(dados["valid"], 0)
                self.assertEqual(dados["error_code"], "os_release_missing")
                self.assertEqual(dados["id_state"], platform.STATE_UNKNOWN)
                self.assertEqual(dados["fields_seen"], 0)

    def test_os_release_presente_e_vazio_e_estado_de_host(self) -> None:
        # O arquivo existe e está vazio: o Bash lê, não acha ID e recusa com
        # diagnóstico. Virar erro de chamada mudaria o comportamento.
        dados = platform.os_release_facts(os_release_payload("", "present"))
        self.assertEqual(dados["valid"], 0)
        self.assertEqual(dados["error_code"], "invalid_id")
        self.assertEqual(dados["id_state"], platform.STATE_ABSENT)

    def test_id_like_aceita_tabulacao_como_separador(self) -> None:
        dados = platform.os_release_facts(
            os_release_payload('ID=nebula\nID_LIKE="ubuntu\tdebian"\n')
        )
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["id_like_count"], 2)
        self.assertEqual(dados["id_like_normalized"], "ubuntu debian")

    def test_captura_acima_do_limite_de_linhas(self) -> None:
        texto = "\n".join("#" for _ in range(platform.MAX_LINES + 1))
        dados = platform.os_release_facts(os_release_payload(texto))
        self.assertEqual(dados["valid"], 0)
        self.assertEqual(dados["error_code"], "capture_too_large")


class ArquiteturaTests(unittest.TestCase):
    def test_arquitetura_vem_do_snapshot_do_bash(self) -> None:
        casos = (
            ("x86_64", platform.STATE_DETECTED, 1),
            ("aarch64", platform.STATE_DETECTED, 0),
            ("i686", platform.STATE_DETECTED, 0),
            ("ppc64le", platform.STATE_DETECTED, 0),
            ("riscv64", platform.STATE_DETECTED, 0),
        )
        for arquitetura, estado, esperada in casos:
            with self.subTest(arquitetura=arquitetura):
                dados = platform.os_release_facts(
                    os_release_payload(UBUNTU, arch=arquitetura)
                )
                self.assertEqual(dados["arch"], arquitetura)
                self.assertEqual(dados["arch_state"], estado)
                self.assertEqual(dados["arch_evidence"], platform.EVIDENCE_UNAME)
                self.assertEqual(dados["arch_expected"], esperada)

    def test_arquitetura_nao_capturada(self) -> None:
        dados = platform.os_release_facts(os_release_payload(UBUNTU, arch=""))
        self.assertEqual(dados["arch_state"], platform.STATE_ABSENT)
        self.assertEqual(dados["arch_evidence"], platform.EVIDENCE_NONE)
        self.assertEqual(dados["arch_expected"], 0)

    def test_arquitetura_nunca_e_inferida_do_arquivo(self) -> None:
        # O os-release cita x86_64, o snapshot diz aarch64: vale o snapshot.
        texto = UBUNTU + 'PRETTY_NAME="Ubuntu x86_64"\n'
        dados = platform.os_release_facts(os_release_payload(texto, arch="aarch64"))
        self.assertEqual(dados["arch"], "aarch64")

    def test_snapshot_inutilizavel_vira_desconhecido(self) -> None:
        for texto in (TRAVESSIA, "x86_64\nx86_64", "arquitetura com espaço"):
            with self.subTest(texto=texto):
                dados = platform.os_release_facts(
                    os_release_payload(UBUNTU, arch=texto)
                )
                self.assertEqual(dados["arch"], "")
                self.assertEqual(dados["arch_state"], platform.STATE_UNKNOWN)
                self.assertEqual(dados["arch_evidence"], platform.EVIDENCE_UNAME)


class NenhumCaminhoAbertoTests(unittest.TestCase):
    """Prova dupla: o módulo não sabe abrir caminho e não tenta abrir nenhum."""

    def _fonte(self) -> ast.Module:
        return ast.parse(Path(platform.__file__).read_text(encoding="utf-8"))

    def test_modulo_nao_importa_nada_alem_do_minimo(self) -> None:
        permitidos = {"re", "typing", "__future__"}
        for no in ast.walk(self._fonte()):
            if isinstance(no, ast.Import):
                for alias in no.names:
                    self.assertIn(alias.name.split(".")[0], permitidos)
            elif isinstance(no, ast.ImportFrom):
                if no.level:
                    self.assertIn(no.module, {"errors", "protocol"})
                else:
                    self.assertIn((no.module or "").split(".")[0], permitidos)

    def test_modulo_nao_cita_construtor_de_efeito(self) -> None:
        nomes = {"open", "eval", "exec", "compile", "__import__", "input", "breakpoint"}
        atributos = {
            "open",
            "system",
            "popen",
            "spawn",
            "fork",
            "remove",
            "unlink",
            "rename",
            "mkdir",
            "read_text",
            "write_text",
            "read_bytes",
            "write_bytes",
        }
        for no in ast.walk(self._fonte()):
            if isinstance(no, ast.Name):
                self.assertNotIn(no.id, nomes)
            if isinstance(no, ast.Attribute):
                self.assertNotIn(no.attr, atributos)

    def test_payload_com_travessia_nao_abre_nada(self) -> None:
        original = builtins.open

        def recusar(*args, **kwargs):
            raise AssertionError("o core tentou abrir um caminho: %r" % (args,))

        builtins.open = recusar
        try:
            facts = platform.os_release_facts(
                os_release_payload(TRAVESSIA, arch=TRAVESSIA)
            )
            self.assertEqual(facts["valid"], 0)
            self.assertEqual(facts["error_code"], "invalid_id")
            self.assertEqual(facts["arch_state"], platform.STATE_UNKNOWN)

            suporte = platform.support_state(support_payload(TRAVESSIA))
            self.assertEqual(suporte["valid"], 0)
            self.assertEqual(suporte["support_level"], platform.SUPPORT_BLOCKED)

            cpu = platform.cpu_vendor_fact(cpu_payload(lscpu=TRAVESSIA))
            self.assertEqual(cpu["cpu_vendor_state"], platform.STATE_ABSENT)

            gpu = platform.gpu_vendor_fact(
                gpu_payload(pci=TRAVESSIA, bdf="0000:01:00.0")
            )
            self.assertEqual(gpu["valid"], 0)
            self.assertEqual(gpu["gpu_vendor_state"], platform.STATE_UNKNOWN)
        finally:
            builtins.open = original

    def test_travessia_em_bdf_nao_vira_caminho(self) -> None:
        dados = platform.gpu_vendor_fact(
            gpu_payload(pci=PCI_NVIDIA, iommu=IOMMU_NVIDIA, bdf=TRAVESSIA)
        )
        self.assertEqual(dados["valid"], 0)
        self.assertEqual(dados["error_code"], "gpu_invalid_selection")


class FixturesDePlataformaTests(unittest.TestCase):
    """As 11 fixtures reais de `tests/fixtures/platform`, sem promover suporte."""

    def test_as_onze_fixtures(self) -> None:
        self.assertEqual(len(FIXTURES), 11)
        for nome, caso in FIXTURES.items():
            with self.subTest(caso=nome):
                dados = platform.support_state(support_payload(caso["text"]))
                if caso["state"] == "malformed":
                    self.assertEqual(dados["valid"], 0)
                else:
                    self.assertEqual(dados["valid"], 1)
                self.assertEqual(publicado(dados, "id"), caso["id"])
                self.assertEqual(publicado(dados, "id_like"), caso["id_like"])
                self.assertEqual(publicado(dados, "version_id"), caso["version_id"])
                self.assertEqual(
                    publicado(dados, "version_codename"), caso["version_codename"]
                )
                self.assertEqual(
                    dados["immutable"], 1 if caso["immutable"] == "true" else 0
                )
                self.assertEqual(dados["support_level"], caso["support"])
                self.assertEqual(dados["profile"], caso["profile"])
                self.assertEqual(
                    dados["mutable"],
                    1 if caso["support"] == platform.SUPPORT_SUPPORTED else 0,
                )

    def test_leitura_recusada_nao_publica_campo_algum(self) -> None:
        # O fato tipado continua dizendo que o ID foi lido e é válido, mas a
        # leitura como um todo foi recusada, então a fachada não publica nada.
        dados = platform.support_state(
            support_payload(FIXTURES["malicious-os-release"]["text"])
        )
        self.assertEqual(dados["valid"], 0)
        self.assertEqual(dados["id"], "hostile")
        self.assertEqual(dados["id_state"], platform.STATE_DETECTED)
        self.assertEqual(publicado(dados, "id"), "")

    def test_fixture_hostil_e_inerte(self) -> None:
        caso = FIXTURES["malicious-os-release"]
        dados = platform.support_state(support_payload(caso["text"]))
        self.assertEqual(dados["error_code"], "invalid_field")
        self.assertEqual(dados["error_field"], "VERSION_CODENAME")
        # A substituição de comando entrou como texto e não foi para lugar
        # nenhum: o campo foi recusado e o valor não aparece no resultado.
        for valor in dados.values():
            self.assertNotIn("payload-in-command-substitution", str(valor))
            self.assertNotIn("payload-in-backticks", str(valor))
            self.assertNotIn("payload-in-unknown-key", str(valor))

    def test_fixtures_embutidas_batem_com_a_arvore(self) -> None:
        raiz = None
        for candidato in Path(__file__).resolve().parents:
            alvo = candidato / "fixtures" / "platform"
            if alvo.is_dir():
                raiz = alvo
                break
            alvo = candidato / "tests" / "fixtures" / "platform"
            if alvo.is_dir():
                raiz = alvo
                break
        if raiz is None:
            self.skipTest("árvore de fixtures indisponível neste contexto")
        for nome, caso in FIXTURES.items():
            with self.subTest(caso=nome):
                arquivo = raiz / nome / "os-release"
                self.assertEqual(
                    arquivo.read_text(encoding="utf-8"),
                    caso["text"],
                    "a cópia embutida divergiu da fixture %s" % nome,
                )


class SuporteTests(unittest.TestCase):
    def test_ubuntu_e_pop_sao_os_unicos_suportados(self) -> None:
        for identificador, perfil in (("ubuntu", "ubuntu"), ("pop", "pop-os")):
            with self.subTest(id=identificador):
                dados = platform.support_state(
                    support_payload("ID=%s\n" % identificador)
                )
                self.assertEqual(dados["support_level"], platform.SUPPORT_SUPPORTED)
                self.assertEqual(dados["mutable"], 1)
                self.assertEqual(dados["profile"], perfil)
                self.assertEqual(dados["block_reason"], "")
                self.assertEqual(dados["error"], "")
                self.assertEqual(
                    dados["capability_reason"],
                    "Capability habilitada pelo perfil exato %s." % perfil,
                )

    def test_provider_planejado_fica_em_diagnostico(self) -> None:
        for identificador in platform.PLANNED_IDS:
            with self.subTest(id=identificador):
                dados = platform.support_state(
                    support_payload("ID=%s\n" % identificador)
                )
                self.assertEqual(dados["support_level"], platform.SUPPORT_DIAGNOSTIC)
                self.assertEqual(dados["mutable"], 0)
                self.assertEqual(
                    dados["block_reason"],
                    "ID=%s possui provider planejado, ainda restrito a diagnóstico."
                    % identificador,
                )
                # Oráculo do gate I1: o nível precisa aparecer na mensagem.
                self.assertIn("diagnostic-only", dados["error"])

    def test_familia_por_id_like_e_inferencia(self) -> None:
        dados = platform.support_state(
            support_payload('ID=nebula\nID_LIKE="ubuntu debian"\n')
        )
        self.assertEqual(dados["support_level"], platform.SUPPORT_FAMILY)
        self.assertEqual(dados["support_source"], "ubuntu")
        self.assertEqual(dados["support_source_state"], platform.STATE_INFERRED)
        self.assertEqual(
            dados["block_reason"],
            "ID=nebula declara ID_LIKE=ubuntu debian, mas a derivação não foi verificada.",
        )

    def test_primeira_familia_da_ordem_vence(self) -> None:
        dados = platform.support_state(
            support_payload('ID=nebula\nID_LIKE="suse debian"\n')
        )
        self.assertEqual(dados["support_source"], "debian")

    def test_distro_sem_provider_e_bloqueada(self) -> None:
        dados = platform.support_state(support_payload("ID=orion\n"))
        self.assertEqual(dados["support_level"], platform.SUPPORT_BLOCKED)
        # Oráculo do gate I1.
        self.assertEqual(
            dados["block_reason"], "ID=orion não possui provider reconhecido."
        )

    def test_imutabilidade_por_variant_id(self) -> None:
        for variante in platform.IMMUTABLE_VARIANTS:
            with self.subTest(variante=variante):
                dados = platform.support_state(
                    support_payload("ID=fedora\nVARIANT_ID=%s\n" % variante)
                )
                self.assertEqual(dados["immutable"], 1)
                self.assertEqual(dados["support_level"], platform.SUPPORT_DIAGNOSTIC)
                self.assertEqual(
                    dados["immutable_source_evidence"], platform.EVIDENCE_VARIANT_ID
                )
                self.assertEqual(
                    dados["block_reason"],
                    "VARIANT_ID=%s identifica uma implantação imutável." % variante,
                )
        # Oráculo do gate I1, byte a byte.
        dados = platform.support_state(
            support_payload("ID=fedora\nVARIANT_ID=silverblue\n")
        )
        self.assertIn("VARIANT_ID=silverblue", dados["block_reason"])

    def test_perfil_imutavel_nao_habilita_nem_vira_provider(self) -> None:
        # I8.3: o perfil diagnóstico é identidade, não permissão. Ele nunca pode
        # coincidir com um perfil de provider, porque o `case` de atributos da
        # fachada é indexado pelo nome do perfil: se colidisse, um host imutável
        # herdaria pacote, serviço e estratégia de driver de um alvo mutável.
        dados = platform.support_state(
            support_payload("ID=fedora\nVARIANT_ID=silverblue\n")
        )
        self.assertEqual(dados["profile"], platform.PROFILE_IMMUTABLE)
        self.assertNotIn(platform.PROFILE_IMMUTABLE, platform.PROFILES.values())
        self.assertEqual(dados["mutable"], 0)
        self.assertEqual(dados["support_level"], platform.SUPPORT_DIAGNOSTIC)
        self.assertEqual(dados["capability_reason"], dados["block_reason"])
        self.assertEqual(dados["error_code"], "not_supported")

    def test_imutabilidade_por_evidencia_ostree(self) -> None:
        dados = platform.support_state(
            support_payload("ID=ubuntu\n", ostree="present")
        )
        self.assertEqual(dados["immutable"], 1)
        self.assertEqual(dados["support_level"], platform.SUPPORT_DIAGNOSTIC)
        self.assertEqual(dados["mutable"], 0)
        # I8.3: era `""`; imutável por evidência ostree também recebe o perfil
        # diagnóstico, pela mesma razão da fixture Silverblue.
        self.assertEqual(dados["profile"], platform.PROFILE_IMMUTABLE)
        # Oráculo do gate I1.
        self.assertIn("ostree", dados["block_reason"])
        self.assertEqual(
            dados["immutable_source_evidence"], platform.EVIDENCE_OSTREE
        )

    def test_variant_id_vence_a_ausencia_de_marcador(self) -> None:
        dados = platform.support_state(
            support_payload("ID=fedora\nVARIANT_ID=silverblue\n", ostree="absent")
        )
        self.assertEqual(dados["immutable"], 1)
        self.assertEqual(
            dados["immutable_source_evidence"], platform.EVIDENCE_VARIANT_ID
        )

    def test_evidencia_ostree_nao_capturada_e_estado_proprio(self) -> None:
        dados = platform.support_state(support_payload("ID=ubuntu\n"))
        self.assertEqual(dados["immutable"], 0)
        self.assertEqual(dados["immutable_source_state"], platform.STATE_UNKNOWN)
        self.assertEqual(
            dados["immutable_source_evidence"], platform.EVIDENCE_NOT_CAPTURED
        )
        self.assertEqual(dados["support_level"], platform.SUPPORT_SUPPORTED)

    def test_marcador_ausente_e_diferente_de_marcador_nao_consultado(self) -> None:
        dados = platform.support_state(support_payload("ID=ubuntu\n", ostree="absent"))
        self.assertEqual(dados["immutable_source_state"], platform.STATE_ABSENT)
        self.assertEqual(dados["immutable_source_evidence"], platform.EVIDENCE_OSTREE)

    def test_leitura_sem_confianca_nao_classifica(self) -> None:
        dados = platform.support_state(support_payload("", "absent"))
        self.assertEqual(dados["valid"], 0)
        self.assertEqual(dados["support_level"], platform.SUPPORT_BLOCKED)
        self.assertEqual(dados["mutable"], 0)
        self.assertEqual(dados["block_reason"], "")
        self.assertEqual(dados["profile"], "")
        self.assertEqual(dados["error_code"], "os_release_missing")

    def test_mensagem_de_nivel_espelha_o_bash(self) -> None:
        dados = platform.support_state(support_payload("ID=fedora\n"))
        self.assertEqual(
            dados["error"],
            "Mutação indisponível no nível diagnostic-only: %s"
            % dados["block_reason"],
        )
        self.assertEqual(dados["error_code"], "not_supported")


class CapabilityTests(unittest.TestCase):
    def test_o_array_conhecido_continua_com_vinte_e_uma_entradas(self) -> None:
        self.assertEqual(len(platform.KNOWN_CAPABILITIES), 21)
        self.assertEqual(
            len(set(platform.KNOWN_CAPABILITIES)), len(platform.KNOWN_CAPABILITIES)
        )
        self.assertEqual(
            platform.support_state(support_payload("ID=ubuntu\n"))[
                "capabilities_known"
            ],
            21,
        )

    def test_alias_resolve_fora_do_array(self) -> None:
        self.assertNotIn("nvidia.driver", platform.KNOWN_CAPABILITIES)
        self.assertEqual(platform.resolve_capability("nvidia.driver"), "gpu.driver")
        self.assertEqual(platform.resolve_capability("gpu.driver"), "gpu.driver")

    def test_capability_desconhecida_e_defeito_de_chamada(self) -> None:
        for nome in ("", "gpu.tudo", "NVIDIA.DRIVER", 3):
            with self.subTest(nome=nome):
                with self.assertRaises(DataError):
                    platform.resolve_capability(nome)

    def test_nome_de_capability_nunca_vira_chave_de_resposta(self) -> None:
        # Chave de resposta é maiusculizada e precisa casar `[A-Z][A-Z0-9_]*`;
        # ponto não passa. Por isso capability só pode ser valor.
        dados = platform.support_state(support_payload("ID=ubuntu\n"))
        for chave in dados:
            self.assertNotIn(".", chave)
            self.assertRegex(chave.upper(), r"^[A-Z][A-Z0-9_]{0,63}$")


class CpuVendorTests(unittest.TestCase):
    def test_amd_detectada_pelas_duas_fontes(self) -> None:
        dados = platform.cpu_vendor_fact(cpu_payload(CPUINFO_AMD, LSCPU_AMD))
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["cpu_vendor"], "AuthenticAMD")
        self.assertEqual(dados["cpu_vendor_family"], "amd")
        self.assertEqual(dados["cpu_vendor_state"], platform.STATE_DETECTED)
        self.assertEqual(dados["cpu_vendor_evidence"], platform.EVIDENCE_CPU_BOTH)
        self.assertEqual(dados["cpu_vendor_supported"], 1)
        self.assertEqual(dados["error"], "")

    def test_intel_continua_bloqueada_byte_a_byte(self) -> None:
        dados = platform.cpu_vendor_fact(cpu_payload(CPUINFO_INTEL, LSCPU_INTEL))
        self.assertEqual(dados["cpu_vendor"], "GenuineIntel")
        self.assertEqual(dados["cpu_vendor_state"], platform.STATE_DETECTED)
        self.assertEqual(dados["cpu_vendor_supported"], 0)
        self.assertEqual(
            dados["error"],
            "CPU GenuineIntel bloqueada: esta implementação oferece apenas AMD "
            "(amd_iommu=on/AMD-Vi). Intel e outros fabricantes não sofrerão "
            "qualquer mutação.",
        )
        # Oráculo do gate I1.
        self.assertIn("CPU GenuineIntel bloqueada", dados["error"])

    def test_uma_fonte_so_ainda_e_deteccao(self) -> None:
        somente_lscpu = platform.cpu_vendor_fact(cpu_payload(lscpu=LSCPU_AMD))
        self.assertEqual(somente_lscpu["cpu_vendor_evidence"], platform.EVIDENCE_LSCPU)
        self.assertEqual(somente_lscpu["cpu_vendor_supported"], 1)
        somente_cpuinfo = platform.cpu_vendor_fact(cpu_payload(cpuinfo=CPUINFO_AMD))
        self.assertEqual(
            somente_cpuinfo["cpu_vendor_evidence"], platform.EVIDENCE_CPUINFO
        )

    def test_vendor_ausente(self) -> None:
        dados = platform.cpu_vendor_fact(cpu_payload())
        self.assertEqual(dados["valid"], 0)
        self.assertEqual(dados["cpu_vendor_state"], platform.STATE_ABSENT)
        self.assertEqual(dados["cpu_vendor"], "")
        self.assertEqual(
            dados["error"], "Fabricante de CPU ausente ou não suportado: desconhecido."
        )

    def test_sonda_indisponivel_e_sonda_com_erro(self) -> None:
        indisponivel = platform.cpu_vendor_fact(
            cpu_payload(lscpu_state="unavailable")
        )
        self.assertEqual(
            indisponivel["error"],
            "lscpu indisponível para identificar o fabricante da CPU.",
        )
        com_erro = platform.cpu_vendor_fact(cpu_payload(lscpu_state="error"))
        self.assertEqual(
            com_erro["error"], "lscpu falhou ao identificar o fabricante da CPU."
        )

    def test_vendor_desconhecido(self) -> None:
        dados = platform.cpu_vendor_fact(
            cpu_payload(lscpu="Vendor ID: CentaurHauls\n")
        )
        self.assertEqual(dados["valid"], 0)
        self.assertEqual(dados["cpu_vendor"], "CentaurHauls")
        self.assertEqual(dados["cpu_vendor_state"], platform.STATE_UNKNOWN)
        self.assertEqual(
            dados["error"], "Fabricante de CPU ausente ou não suportado: CentaurHauls."
        )

    def test_evidencia_conflitante_entre_as_duas_fontes(self) -> None:
        dados = platform.cpu_vendor_fact(cpu_payload(CPUINFO_AMD, LSCPU_INTEL))
        self.assertEqual(dados["valid"], 0)
        self.assertEqual(dados["cpu_vendor_state"], platform.STATE_CONFLICTING)
        self.assertEqual(dados["cpu_vendor"], "")
        self.assertEqual(dados["cpu_vendor_supported"], 0)
        self.assertEqual(
            dados["error"],
            "Mais de um fabricante de CPU foi reportado: AuthenticAMD e GenuineIntel.",
        )

    def test_conflito_dentro_de_uma_unica_fonte(self) -> None:
        misturado = LSCPU_AMD + "Vendor ID: GenuineIntel\n"
        dados = platform.cpu_vendor_fact(cpu_payload(lscpu=misturado))
        self.assertEqual(dados["cpu_vendor_state"], platform.STATE_CONFLICTING)
        self.assertEqual(dados["lscpu_distinct"], 2)

    def test_repeticao_identica_nao_e_conflito(self) -> None:
        dados = platform.cpu_vendor_fact(cpu_payload(CPUINFO_AMD))
        self.assertEqual(dados["cpuinfo_distinct"], 1)
        self.assertEqual(dados["cpu_vendor_state"], platform.STATE_DETECTED)

    def test_captura_incoerente_e_defeito_de_chamada(self) -> None:
        with self.assertRaises(DataError):
            platform.cpu_vendor_fact(cpu_payload(lscpu=LSCPU_AMD, lscpu_state="absent"))
        with self.assertRaises(DataError):
            platform.cpu_vendor_fact(cpu_payload(lscpu="", lscpu_state="present"))


class GpuVendorTests(unittest.TestCase):
    def test_nvidia_continua_o_unico_suportado(self) -> None:
        dados = platform.gpu_vendor_fact(gpu_payload(PCI_NVIDIA, IOMMU_NVIDIA))
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["gpu_vendor"], "10de")
        self.assertEqual(dados["gpu_vendor_family"], "nvidia")
        self.assertEqual(dados["gpu_vendor_state"], platform.STATE_DETECTED)
        self.assertEqual(dados["gpu_vendor_supported"], 1)
        self.assertEqual(dados["error"], "")
        self.assertEqual(dados["gpu_count"], 1)

    def test_amd_reconhecida_e_recusada(self) -> None:
        dados = platform.gpu_vendor_fact(gpu_payload(PCI_AMD))
        self.assertEqual(dados["gpu_vendor"], "1002")
        self.assertEqual(dados["gpu_vendor_family"], "amd")
        self.assertEqual(dados["gpu_vendor_state"], platform.STATE_DETECTED)
        self.assertEqual(dados["gpu_vendor_supported"], 0)
        self.assertEqual(dados["error_code"], "gpu_vendor_blocked")
        self.assertIn("apenas NVIDIA", dados["error"])

    def test_intel_reconhecida_e_recusada(self) -> None:
        dados = platform.gpu_vendor_fact(gpu_payload(PCI_INTEL))
        self.assertEqual(dados["gpu_vendor"], "8086")
        self.assertEqual(dados["gpu_vendor_supported"], 0)
        self.assertEqual(dados["error_code"], "gpu_vendor_blocked")

    def test_gpu_ausente(self) -> None:
        somente_ponte = (
            "0000:00:00.0 Host bridge [0600]: Advanced Micro Devices, Inc. "
            "[AMD] Root Complex [1022:1480]\n"
        )
        dados = platform.gpu_vendor_fact(gpu_payload(somente_ponte))
        self.assertEqual(dados["valid"], 0)
        self.assertEqual(dados["gpu_vendor_state"], platform.STATE_ABSENT)
        self.assertEqual(dados["gpu_count"], 0)
        self.assertEqual(dados["error_code"], "gpu_absent")

    def test_duas_gpus_de_fabricantes_diferentes(self) -> None:
        dados = platform.gpu_vendor_fact(gpu_payload(PCI_DOIS_FABRICANTES))
        self.assertEqual(dados["valid"], 0)
        self.assertEqual(dados["gpu_vendor_state"], platform.STATE_CONFLICTING)
        self.assertEqual(dados["gpu_vendor"], "")
        self.assertEqual(dados["gpu_vendor_count"], 2)
        self.assertEqual(dados["gpu_vendor_supported"], 0)
        self.assertEqual(
            dados["error"], "Mais de um fabricante de GPU foi reportado: NVIDIA e AMD."
        )

    def test_duas_gpus_do_mesmo_fabricante_nao_conflitam(self) -> None:
        duas = PCI_NVIDIA + (
            "0000:04:00.0 VGA compatible controller [0300]: NVIDIA Corporation "
            "GA102 [GeForce RTX 3090] [10de:2204] (rev a1)\n"
        )
        dados = platform.gpu_vendor_fact(gpu_payload(duas))
        self.assertEqual(dados["gpu_count"], 2)
        self.assertEqual(dados["gpu_vendor_count"], 1)
        self.assertEqual(dados["gpu_vendor_state"], platform.STATE_DETECTED)

    def test_audio_sem_video_no_mesmo_grupo_e_inferencia(self) -> None:
        dados = platform.gpu_vendor_fact(
            gpu_payload(PCI_SEM_VIDEO, IOMMU_SO_AUDIO, bdf="0000:01:00.1")
        )
        self.assertEqual(dados["gpu_vendor"], "10de")
        self.assertEqual(dados["gpu_vendor_state"], platform.STATE_INFERRED)
        self.assertEqual(dados["gpu_vendor_evidence"], platform.EVIDENCE_IOMMU)
        self.assertEqual(dados["iommu_group"], "14")
        # Inferência nunca promove: sem função de vídeo não há promessa.
        self.assertEqual(dados["gpu_vendor_supported"], 0)
        self.assertEqual(dados["error_code"], "gpu_audio_only")

    def test_audio_sem_video_tambem_aparece_na_varredura(self) -> None:
        dados = platform.gpu_vendor_fact(gpu_payload(PCI_SEM_VIDEO, IOMMU_SO_AUDIO))
        self.assertEqual(dados["gpu_vendor_state"], platform.STATE_INFERRED)
        self.assertEqual(dados["gpu_vendor_supported"], 0)

    def test_audio_com_video_no_grupo_volta_a_ser_deteccao(self) -> None:
        dados = platform.gpu_vendor_fact(
            gpu_payload(PCI_NVIDIA, IOMMU_NVIDIA, bdf="0000:01:00.1")
        )
        self.assertEqual(dados["gpu_vendor_state"], platform.STATE_DETECTED)
        self.assertEqual(dados["gpu_vendor_evidence"], platform.EVIDENCE_IOMMU)
        self.assertEqual(dados["gpu_vendor_supported"], 1)

    def test_bdf_selecionado_resolve_um_dispositivo(self) -> None:
        dados = platform.gpu_vendor_fact(
            gpu_payload(PCI_DOIS_FABRICANTES, bdf="0000:03:00.0")
        )
        self.assertEqual(dados["gpu_vendor"], "1002")
        self.assertEqual(dados["gpu_vendor_state"], platform.STATE_DETECTED)

    def test_bdf_selecionado_fora_da_captura(self) -> None:
        dados = platform.gpu_vendor_fact(
            gpu_payload(PCI_NVIDIA, IOMMU_NVIDIA, bdf="0000:09:00.0")
        )
        self.assertEqual(dados["error_code"], "gpu_bdf_absent")
        self.assertEqual(dados["gpu_vendor_state"], platform.STATE_ABSENT)

    def test_bdf_selecionado_que_nao_e_video(self) -> None:
        dados = platform.gpu_vendor_fact(
            gpu_payload(PCI_NVIDIA, IOMMU_NVIDIA, bdf="0000:00:00.0")
        )
        self.assertEqual(dados["error_code"], "gpu_not_display")

    def test_fabricante_pci_desconhecido(self) -> None:
        matrox = (
            "0000:01:00.0 VGA compatible controller [0300]: Matrox Electronics "
            "Systems Ltd. MGA G200e [102b:0522] (rev 41)\n"
        )
        dados = platform.gpu_vendor_fact(gpu_payload(matrox))
        self.assertEqual(dados["gpu_vendor_state"], platform.STATE_UNKNOWN)
        self.assertEqual(dados["gpu_vendor_supported"], 0)
        self.assertEqual(
            dados["error"], "Fabricante de GPU ausente ou não reconhecido: 102b."
        )

    def test_captura_pci_malformada_e_estado_de_host(self) -> None:
        for texto, codigo in (
            ("0000:01:00.0 sem classe nem par vendor device\n", "pci_malformed"),
            ("linha sem colchetes\n", "pci_invalid_bdf"),
            ("zz:zz:zz.z VGA [0300]: coisa [10de:2786]\n", "pci_invalid_bdf"),
            (PCI_NVIDIA + PCI_NVIDIA, "pci_duplicate_bdf"),
        ):
            with self.subTest(codigo=codigo):
                dados = platform.gpu_vendor_fact(gpu_payload(texto))
                self.assertEqual(dados["valid"], 0)
                self.assertEqual(dados["error_code"], codigo)

    def test_captura_iommu_malformada(self) -> None:
        for texto, codigo in (
            ("14\n", "iommu_malformed"),
            ("999999 0000:01:00.0\n", "iommu_invalid_group"),
            ("14 0000:01:00.0\n15 0000:01:00.0\n", "iommu_duplicate"),
        ):
            with self.subTest(codigo=codigo):
                dados = platform.gpu_vendor_fact(gpu_payload(PCI_NVIDIA, texto))
                self.assertEqual(dados["valid"], 0)
                self.assertEqual(dados["error_code"], codigo)

    def test_ordem_da_captura_nao_muda_o_veredicto(self) -> None:
        invertida = "\n".join(reversed(PCI_DOIS_FABRICANTES.strip("\n").split("\n")))
        self.assertEqual(
            platform.gpu_vendor_fact(gpu_payload(PCI_DOIS_FABRICANTES))["error"],
            platform.gpu_vendor_fact(gpu_payload(invertida + "\n"))["error"],
        )


class ResolucaoDeUnidadeSystemdTests(unittest.TestCase):
    """I8.6: classificação e desempate do backend systemd, agora no core.

    Cada caso aqui é um comportamento que `libvirt_backend_resolver` e as
    etapas 9, 14, 20 e 21 já consomem hoje. O oráculo é o Bash de antes de
    I8.6, e nenhum valor pode mudar.
    """

    UNIDADES = (
        "libvirtd.socket",
        "libvirtd.service",
        "virtqemud.socket",
        "virtqemud.service",
    )

    def resolver(self, **kwargs):
        return platform.service_unit_choice(servico_payload(**kwargs))

    # --- Níveis de escore ---------------------------------------------------

    def test_ativa_vence_habilitavel_que_vence_iniciavel(self) -> None:
        dados = self.resolver(
            fixture="\n".join(
                (
                    "libvirtd.socket|loaded|inactive|dead|static",
                    "libvirtd.service|loaded|inactive|dead|enabled",
                    "virtqemud.service|loaded|active|running|enabled",
                    "",
                )
            )
        )
        self.assertEqual(dados["valid"], 1)
        self.assertEqual(dados["resolved_unit"], "virtqemud.service")
        self.assertEqual(dados["resolved_service"], "virtqemud")
        self.assertEqual(dados["resolved_action"], platform.UNIT_ACTION_NONE)
        self.assertEqual(dados["resolved_score"], platform.SCORE_ACTIVE)

    def test_habilitavel_vence_apenas_iniciavel(self) -> None:
        dados = self.resolver(
            fixture="\n".join(
                (
                    "libvirtd.service|loaded|inactive|dead|static",
                    "virtqemud.service|loaded|inactive|dead|enabled",
                    "",
                )
            )
        )
        self.assertEqual(dados["resolved_unit"], "virtqemud.service")
        self.assertEqual(dados["resolved_action"], platform.UNIT_ACTION_ENABLE_NOW)
        self.assertEqual(dados["resolved_score"], platform.SCORE_ENABLE_NOW)

    def test_apenas_iniciavel_ainda_resolve_com_start(self) -> None:
        for estado in platform.UNIT_FILE_START:
            with self.subTest(unit_file=estado):
                dados = self.resolver(
                    fixture="libvirtd.service|loaded|inactive|dead|%s\n" % estado
                )
                self.assertEqual(dados["resolved_unit"], "libvirtd.service")
                self.assertEqual(dados["resolved_action"], platform.UNIT_ACTION_START)
                self.assertEqual(dados["resolved_score"], platform.SCORE_START)

    def test_disabled_ainda_e_habilitavel(self) -> None:
        for estado in platform.UNIT_FILE_ENABLE_NOW:
            with self.subTest(unit_file=estado):
                dados = self.resolver(
                    fixture="libvirtd.service|loaded|inactive|dead|%s\n" % estado
                )
                self.assertEqual(dados["resolved_action"], platform.UNIT_ACTION_ENABLE_NOW)

    def test_activating_conta_como_ativa(self) -> None:
        for estado in platform.UNIT_ACTIVE_STATES:
            with self.subTest(active=estado):
                dados = self.resolver(
                    fixture="libvirtd.service|loaded|%s|running|enabled\n" % estado
                )
                self.assertEqual(dados["resolved_action"], platform.UNIT_ACTION_NONE)
                self.assertEqual(dados["resolved_score"], platform.SCORE_ACTIVE)

    # --- Desempate ----------------------------------------------------------

    def test_socket_desempata_dentro_do_mesmo_nivel(self) -> None:
        fixture = "\n".join(
            (
                "libvirtd.socket|loaded|active|listening|enabled",
                "libvirtd.service|loaded|active|running|enabled",
                "",
            )
        )
        dados = self.resolver(fixture=fixture)
        self.assertEqual(dados["resolved_unit"], "libvirtd.socket")
        self.assertEqual(
            dados["resolved_score"], platform.SCORE_ACTIVE + platform.SCORE_SOCKET_BONUS
        )

    def test_socket_desempata_mesmo_declarado_depois(self) -> None:
        # A ordem das LINHAS da fixture não decide nada: quem decide é a ordem
        # das unidades candidatas e o escore.
        fixture = "\n".join(
            (
                "libvirtd.service|loaded|active|running|enabled",
                "libvirtd.socket|loaded|active|listening|enabled",
                "",
            )
        )
        self.assertEqual(
            self.resolver(fixture=fixture)["resolved_unit"], "libvirtd.socket"
        )

    def test_bonus_de_socket_nunca_atravessa_nivel(self) -> None:
        # Socket apenas habilitável (51) perde para service ativo (100).
        fixture = "\n".join(
            (
                "libvirtd.socket|loaded|inactive|dead|enabled",
                "virtqemud.service|loaded|active|running|enabled",
                "",
            )
        )
        dados = self.resolver(fixture=fixture)
        self.assertEqual(dados["resolved_unit"], "virtqemud.service")
        self.assertEqual(dados["resolved_score"], platform.SCORE_ACTIVE)

    def test_empate_de_escore_e_vencido_por_quem_o_perfil_listou_antes(self) -> None:
        fixture = "\n".join(
            (
                "libvirtd.socket|loaded|active|listening|enabled",
                "virtqemud.socket|loaded|active|listening|enabled",
                "",
            )
        )
        self.assertEqual(
            self.resolver(fixture=fixture)["resolved_unit"], "libvirtd.socket"
        )
        invertida = self.resolver(
            unidades=("virtqemud.socket", "libvirtd.socket"), fixture=fixture
        )
        self.assertEqual(invertida["resolved_unit"], "virtqemud.socket")

    def test_servico_e_o_nome_ate_o_primeiro_ponto(self) -> None:
        dados = self.resolver(
            unidades=("virt.qemud.socket",),
            fixture="virt.qemud.socket|loaded|active|listening|enabled\n",
        )
        self.assertEqual(dados["resolved_service"], "virt")

    # --- Unidade ausente e arquivo inválido ---------------------------------

    def test_unidade_fora_da_fixture_nao_concorre(self) -> None:
        dados = self.resolver(fixture="outra.service|loaded|active|running|enabled\n")
        self.assertEqual(dados["valid"], 0)
        self.assertEqual(dados["error_code"], "no_unit")
        self.assertEqual(dados["resolved_unit"], "")
        self.assertEqual(dados["resolved_unit_state"], platform.STATE_ABSENT)
        self.assertEqual(dados["resolved_service"], "")
        self.assertEqual(dados["resolved_action"], "")
        self.assertEqual(dados["resolved_score"], 0)

    def test_fixture_vazia_nao_resolve(self) -> None:
        self.assertEqual(self.resolver(fixture="")["error_code"], "no_unit")

    def test_carga_diferente_de_loaded_nao_concorre(self) -> None:
        for carga in ("not-found", "masked", "error", "bad-setting"):
            with self.subTest(load=carga):
                dados = self.resolver(
                    fixture="libvirtd.service|%s|active|running|enabled\n" % carga
                )
                self.assertEqual(dados["error_code"], "no_unit")

    def test_unit_file_state_invalido_nao_concorre(self) -> None:
        for arquivo in ("masked", "masked-runtime", "bad", "transient"):
            with self.subTest(unit_file=arquivo):
                dados = self.resolver(
                    fixture="libvirtd.service|loaded|inactive|dead|%s\n" % arquivo
                )
                self.assertEqual(dados["error_code"], "no_unit")

    def test_unit_file_state_invalido_cede_a_vez_a_outro_backend(self) -> None:
        dados = self.resolver(
            fixture="\n".join(
                (
                    "libvirtd.service|loaded|inactive|dead|masked",
                    "virtqemud.service|loaded|inactive|dead|enabled",
                    "",
                )
            )
        )
        self.assertEqual(dados["resolved_unit"], "virtqemud.service")

    def test_lista_de_candidatas_vazia_e_pendencia_e_nao_erro(self) -> None:
        # Perfil sem backend declarado (`PLATAFORMA_LIBVIRT_SERVICOS` vazio):
        # o Bash não sonda nada e a resolução é pendência, nunca erro.
        dados = self.resolver(unidades=("",), fixture="")
        self.assertEqual(dados["valid"], 0)
        self.assertEqual(dados["error_code"], "no_unit")
        self.assertEqual(dados["unit_count"], 0)
        dados = self.resolver(unidades=(), fixture="")
        self.assertEqual(dados["valid"], 0)
        self.assertEqual(dados["error_code"], "no_unit")
        self.assertEqual(dados["unit_count"], 0)

    # --- Formato da fixture -------------------------------------------------

    def test_comentario_e_linha_em_branco_sao_ignorados(self) -> None:
        fixture = "\n".join(
            (
                "# unit|load_state|active_state|sub_state|unit_file_state",
                "",
                "libvirtd.service|loaded|active|running|enabled",
                "",
                "# fim",
                "",
            )
        )
        self.assertEqual(
            self.resolver(fixture=fixture)["resolved_unit"], "libvirtd.service"
        )

    def test_ultima_linha_sem_nova_linha_ainda_e_linha(self) -> None:
        self.assertEqual(
            self.resolver(fixture="libvirtd.service|loaded|active|running|enabled")[
                "resolved_unit"
            ],
            "libvirtd.service",
        )

    def test_unit_file_state_vazio_vira_disabled_na_fixture(self) -> None:
        dados = self.resolver(fixture="libvirtd.service|loaded|inactive|dead|\n")
        self.assertEqual(dados["resolved_action"], platform.UNIT_ACTION_ENABLE_NOW)

    def test_campos_a_menos_sao_tolerados_como_no_read_do_bash(self) -> None:
        # `IFS='|' read` deixa os campos que faltam vazios, e `unitfile` vazio
        # vira `disabled`. É o que a fixture de teste já explora hoje.
        dados = self.resolver(fixture="libvirtd.service|loaded|inactive\n")
        self.assertEqual(dados["resolved_action"], platform.UNIT_ACTION_ENABLE_NOW)

    def test_campo_extra_e_fixture_malformada(self) -> None:
        linha = "libvirtd.service|loaded|active|running|enabled|campo-extra"
        dados = self.resolver(fixture=linha + "\n")
        self.assertEqual(dados["valid"], 0)
        self.assertEqual(dados["error_code"], "fixture_malformed")
        self.assertEqual(dados["error_field"], linha)
        self.assertEqual(dados["error"], platform.MSG_UNIT_FIXTURE_MALFORMED % linha)

    def test_separador_final_solitario_nao_e_campo_extra(self) -> None:
        # `read -r ... extra <<< 'a|b|c|d|e|'` deixa `extra` vazio, mas
        # `'a|b|c|d|e||'` não. A recusa segue o Bash, não a intuição.
        for linha, malformada in (
            ("libvirtd.service|loaded|active|running|enabled", False),
            ("libvirtd.service|loaded|active|running|enabled|", False),
            ("libvirtd.service|loaded|active|running|enabled||", False),
            ("libvirtd.service|loaded|active|running|enabled|x", True),
            ("libvirtd.service|loaded|active|running|enabled|x|", True),
            ("libvirtd.service|loaded|active|running|enabled|x|y", True),
        ):
            with self.subTest(linha=linha):
                dados = self.resolver(fixture=linha + "\n")
                if malformada:
                    self.assertEqual(dados["error_code"], "fixture_malformed")
                else:
                    self.assertEqual(dados["resolved_unit"], "libvirtd.service")

    def test_unidade_repetida_e_recusada(self) -> None:
        fixture = "\n".join(
            (
                "libvirtd.service|loaded|active|running|enabled",
                "libvirtd.service|loaded|inactive|dead|enabled",
                "",
            )
        )
        dados = self.resolver(fixture=fixture)
        self.assertEqual(dados["valid"], 0)
        self.assertEqual(dados["error_code"], "fixture_duplicate")
        self.assertEqual(dados["error_field"], "libvirtd.service")

    def test_duplicata_de_outra_unidade_nao_e_recusada(self) -> None:
        # A varredura por unidade só conta repetição da unidade CONSULTADA.
        fixture = "\n".join(
            (
                "outra.service|loaded|active|running|enabled",
                "outra.service|loaded|active|running|enabled",
                "libvirtd.service|loaded|active|running|enabled",
                "",
            )
        )
        self.assertEqual(
            self.resolver(fixture=fixture)["resolved_unit"], "libvirtd.service"
        )

    def test_malformada_em_qualquer_posicao_vence_duplicata_posterior(self) -> None:
        # A primeira unidade consultada varre a fixture inteira, então a linha
        # malformada reprova antes de a duplicata ser alcançada.
        fixture = "\n".join(
            (
                "virtqemud.socket|loaded|active|listening|enabled|extra",
                "libvirtd.service|loaded|active|running|enabled",
                "libvirtd.service|loaded|active|running|enabled",
                "",
            )
        )
        self.assertEqual(self.resolver(fixture=fixture)["error_code"], "fixture_malformed")

    def test_duplicata_da_primeira_unidade_vence_malformada_posterior(self) -> None:
        fixture = "\n".join(
            (
                "libvirtd.socket|loaded|active|listening|enabled",
                "libvirtd.socket|loaded|inactive|dead|enabled",
                "virtqemud.service|loaded|active|running|enabled|extra",
                "",
            )
        )
        dados = self.resolver(fixture=fixture)
        self.assertEqual(dados["error_code"], "fixture_duplicate")
        self.assertEqual(dados["error_field"], "libvirtd.socket")

    # --- Fonte de sonda -----------------------------------------------------

    def test_sonda_real_classifica_igual_a_fixture(self) -> None:
        dados = self.resolver(
            unidades=self.UNIDADES,
            estados=(
                sonda("libvirtd.socket", "not-found"),
                sonda("libvirtd.service", "not-found"),
                sonda("virtqemud.socket", "loaded", "active", "listening", "enabled"),
                sonda("virtqemud.service", "loaded", "inactive", "dead", "enabled"),
            ),
        )
        self.assertEqual(dados["resolved_unit"], "virtqemud.socket")
        self.assertEqual(dados["resolved_action"], platform.UNIT_ACTION_NONE)
        self.assertEqual(dados["resolved_unit_evidence"], platform.EVIDENCE_SYSTEMCTL_SHOW)

    def test_unit_file_state_vazio_na_sonda_nao_vira_disabled(self) -> None:
        # Divergência deliberada com a fixture: na sonda real, `UnitFileState`
        # vazio significa unidade sem arquivo próprio e ela NÃO concorre.
        dados = self.resolver(
            unidades=("libvirtd.service",),
            estados=(sonda("libvirtd.service", "loaded", "inactive", "dead", ""),),
        )
        self.assertEqual(dados["error_code"], "no_unit")

    def test_evidencia_declara_a_fonte(self) -> None:
        fixture = self.resolver(fixture="libvirtd.service|loaded|active|running|enabled\n")
        self.assertEqual(fixture["service_source"], platform.SERVICE_SOURCE_FIXTURE)
        self.assertEqual(fixture["resolved_unit_evidence"], platform.EVIDENCE_SYSTEMD_FIXTURE)

    # --- Schema fechado -----------------------------------------------------

    def test_schema_fechado_recusa_campo_ausente_e_extra(self) -> None:
        completo = servico_payload(fixture="")
        for chave in completo:
            with self.subTest(faltando=chave):
                parcial = dict(completo)
                del parcial[chave]
                with self.assertRaises(DataError):
                    platform.service_unit_choice(parcial)
        with self.assertRaises(DataError):
            platform.service_unit_choice(dict(completo, extra="1"))

    def test_fonte_desconhecida_e_defeito_de_chamada(self) -> None:
        with self.assertRaises(DataError):
            self.resolver(fixture="", source="talvez")

    def test_fontes_nao_se_misturam(self) -> None:
        with self.assertRaises(DataError):
            self.resolver(
                unidades=("libvirtd.service",),
                fixture="libvirtd.service|loaded|active|running|enabled\n",
                estados=(sonda("libvirtd.service"),),
                source="fixture",
            )
        with self.assertRaises(DataError):
            self.resolver(
                unidades=("libvirtd.service",),
                fixture="libvirtd.service|loaded|active|running|enabled\n",
                estados=(sonda("libvirtd.service"),),
                source="probe",
            )

    def test_sonda_incoerente_com_as_candidatas_e_defeito_de_chamada(self) -> None:
        with self.assertRaises(DataError):
            self.resolver(
                unidades=("libvirtd.socket", "libvirtd.service"),
                estados=(sonda("libvirtd.socket"),),
            )
        with self.assertRaises(DataError):
            self.resolver(
                unidades=("libvirtd.socket", "libvirtd.service"),
                estados=(sonda("libvirtd.service"), sonda("libvirtd.socket")),
            )

    def test_registro_de_sonda_fora_do_formato(self) -> None:
        for registros in ("libvirtd.socket\tloaded\tactive", "", "a\tb\tc\td\te\tf"):
            with self.subTest(registro=registros):
                payload = servico_payload(unidades=("libvirtd.socket",))
                payload["service_source"] = "probe"
                payload["unit_states"] = registros
                with self.assertRaises(DataError):
                    platform.service_unit_choice(payload)

    def test_nome_de_unidade_invalido_e_defeito_de_chamada(self) -> None:
        for nome in ("libvirtd service", "/etc/passwd", "-libvirtd", "libvirtd;rm"):
            with self.subTest(unidade=nome):
                with self.assertRaises(DataError):
                    self.resolver(unidades=(nome,), fixture="")

    def test_unidade_repetida_na_lista_de_candidatas_e_defeito(self) -> None:
        with self.assertRaises(DataError):
            self.resolver(unidades=("libvirtd.socket", "libvirtd.socket"), fixture="")

    def test_tipo_errado_e_defeito_de_chamada(self) -> None:
        payload = servico_payload(fixture="")
        payload["fixture_text"] = 1
        with self.assertRaises(DataError):
            platform.service_unit_choice(payload)
        with self.assertRaises(DataError):
            platform.service_unit_choice("nem mapeamento")

    def test_caractere_de_controle_e_recusado(self) -> None:
        with self.assertRaises(DataError):
            self.resolver(fixture="libvirtd.service|loaded|active|running|en\x00abled\n")

    def test_limites_de_tamanho(self) -> None:
        with self.assertRaises(DataError):
            self.resolver(fixture="#" * (platform.MAX_SERVICE_FIXTURE_BYTES + 1))
        with self.assertRaises(DataError):
            self.resolver(
                fixture="\n".join(
                    "u%d.service|loaded|inactive|dead|enabled" % indice
                    for indice in range(platform.MAX_SERVICE_FIXTURE_LINES + 1)
                )
            )

    # --- Contrato de resposta -----------------------------------------------

    def test_resposta_e_escalar_e_projetavel_em_pares(self) -> None:
        for dados in (
            self.resolver(fixture="libvirtd.service|loaded|active|running|enabled\n"),
            self.resolver(fixture=""),
            self.resolver(fixture="libvirtd.service|a|b|c|d|e\n"),
        ):
            with self.subTest(valid=dados["valid"]):
                for chave, valor in dados.items():
                    self.assertRegex(chave, r"^[a-z][a-z0-9_]{0,63}$")
                    self.assertIsInstance(valor, (str, int))
                    self.assertNotIsInstance(valor, bool)
                    if isinstance(valor, str):
                        self.assertLessEqual(len(valor.encode("utf-8")), 64 * 1024)

    def test_recusa_nao_publica_decisao_alguma(self) -> None:
        for dados in (
            self.resolver(fixture=""),
            self.resolver(fixture="libvirtd.service|loaded|active|running|enabled|x\n"),
        ):
            with self.subTest(codigo=dados["error_code"]):
                self.assertEqual(dados["valid"], 0)
                for campo in ("resolved_unit", "resolved_service", "resolved_action"):
                    self.assertEqual(dados[campo], "")
                self.assertEqual(dados["resolved_score"], 0)

    def test_determinismo(self) -> None:
        payload = servico_payload(
            fixture="\n".join(
                (
                    "libvirtd.socket|loaded|active|listening|enabled",
                    "libvirtd.service|loaded|active|running|enabled",
                    "",
                )
            )
        )
        primeira = platform.service_unit_choice(payload)
        segunda = platform.service_unit_choice(payload)
        self.assertEqual(primeira, segunda)


class ClassificacaoDeErroTests(unittest.TestCase):
    """Estado de host recusado devolve veredicto; chamada errada levanta."""

    def test_estado_recusado_nao_levanta(self) -> None:
        for chamada in (
            lambda: platform.os_release_facts(os_release_payload("lixo")),
            lambda: platform.support_state(support_payload("lixo")),
            lambda: platform.gpu_vendor_fact(gpu_payload("lixo")),
        ):
            with self.subTest(chamada=chamada):
                self.assertEqual(chamada()["valid"], 0)

    def test_schema_fechado_recusa_campo_ausente_e_extra(self) -> None:
        completo = support_payload(UBUNTU)
        for chave in completo:
            with self.subTest(faltando=chave):
                parcial = dict(completo)
                del parcial[chave]
                with self.assertRaises(DataError):
                    platform.support_state(parcial)
        with self.assertRaises(DataError):
            platform.support_state(dict(completo, extra="1"))

    def test_tipo_errado_e_defeito_de_chamada(self) -> None:
        with self.assertRaises(DataError):
            platform.os_release_facts({"text": 1, "text_state": "present", "arch": ""})
        with self.assertRaises(DataError):
            platform.os_release_facts(os_release_payload(UBUNTU, state="talvez"))
        with self.assertRaises(DataError):
            platform.os_release_facts("nem mapeamento")
        with self.assertRaises(DataError):
            platform.os_release_facts(os_release_payload("ID=ubuntu\x00\n"))

    def test_limite_de_tamanho_por_campo(self) -> None:
        with self.assertRaises(DataError):
            platform.os_release_facts(
                os_release_payload("#" * (platform.MAX_OS_RELEASE_BYTES + 1))
            )

    def test_toda_resposta_e_escalar_e_projetavel_em_pares(self) -> None:
        respostas = (
            platform.support_state(support_payload(UBUNTU)),
            platform.cpu_vendor_fact(cpu_payload(CPUINFO_AMD, LSCPU_AMD)),
            platform.gpu_vendor_fact(gpu_payload(PCI_NVIDIA, IOMMU_NVIDIA)),
        )
        for resposta in respostas:
            with self.subTest(chaves=len(resposta)):
                self.assertLessEqual(len(resposta), 256)
                for chave, valor in resposta.items():
                    self.assertRegex(chave, r"^[a-z][a-z0-9_]{0,63}$")
                    self.assertIsInstance(valor, (str, int))
                    self.assertNotIsInstance(valor, bool)
                    if isinstance(valor, str):
                        self.assertLessEqual(len(valor.encode("utf-8")), 64 * 1024)

    def test_todo_fato_traz_estado_e_evidencia(self) -> None:
        resposta = platform.support_state(support_payload(UBUNTU))
        for chave in list(resposta):
            if chave.endswith("_state"):
                base = chave[: -len("_state")]
                self.assertIn(base, resposta)
                self.assertIn("%s_evidence" % base, resposta)
                self.assertIn(resposta[chave], platform.FACT_STATES)


if __name__ == "__main__":
    unittest.main()
