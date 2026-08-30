"""Parser fail-closed do JSON de `qemu-img info` (I3.5)."""
import unittest

from passthrough_core import qemu_image
from passthrough_core.errors import DataError, MissingInputError

import fixtures_i3 as fx


class InspectTests(unittest.TestCase):
    def test_imagem_simples(self) -> None:
        dados = qemu_image.inspect_image(
            {
                "json": fx.QEMU_IMG_SIMPLES,
                "expect_format": "qcow2",
                "require_no_backing": True,
            }
        )
        self.assertEqual(dados["format"], "qcow2")
        self.assertEqual(dados["has_backing"], 0)
        self.assertEqual(dados["backing_filename"], "")
        self.assertEqual(dados["chain_length"], 1)
        self.assertEqual(dados["virtual_size"], 68719476736)
        self.assertEqual(dados["actual_size"], 1234567)
        self.assertEqual(dados["cluster_size"], 65536)

    def test_backing_reportado_sem_exigencia(self) -> None:
        dados = qemu_image.inspect_image({"json": fx.QEMU_IMG_COM_BACKING})
        self.assertEqual(dados["has_backing"], 1)
        self.assertEqual(dados["backing_filename"], "/vm/fixture.qcow2")

    def test_backing_recusado_quando_exigido(self) -> None:
        with self.assertRaises(DataError) as contexto:
            qemu_image.inspect_image(
                {"json": fx.QEMU_IMG_COM_BACKING, "require_no_backing": True}
            )
        self.assertIn("backing file detectado", str(contexto.exception))

    def test_backing_apenas_relativo(self) -> None:
        dados = qemu_image.inspect_image(
            {"json": '{"format":"qcow2","backing-filename":"base.qcow2"}'}
        )
        self.assertEqual(dados["has_backing"], 1)
        self.assertEqual(dados["backing_filename"], "base.qcow2")

    def test_formato_inesperado(self) -> None:
        with self.assertRaises(DataError) as contexto:
            qemu_image.inspect_image(
                {"json": '{"format":"raw"}', "expect_format": "qcow2"}
            )
        self.assertIn("formato inesperado", str(contexto.exception))

    def test_formato_desconhecido(self) -> None:
        with self.assertRaises(DataError) as contexto:
            qemu_image.inspect_image({"json": '{"format":"inventado"}'})
        self.assertIn("não reconhecido", str(contexto.exception))

    def test_formato_ausente(self) -> None:
        with self.assertRaises(DataError) as contexto:
            qemu_image.inspect_image({"json": '{"virtual-size":1}'})
        self.assertIn("obrigatório", str(contexto.exception))

    def test_formato_com_tipo_errado(self) -> None:
        with self.assertRaises(DataError):
            qemu_image.inspect_image({"json": '{"format":7}'})

    def test_tamanho_com_tipo_errado(self) -> None:
        with self.assertRaises(DataError):
            qemu_image.inspect_image({"json": '{"format":"qcow2","virtual-size":"8G"}'})

    def test_tamanho_negativo(self) -> None:
        with self.assertRaises(DataError):
            qemu_image.inspect_image({"json": '{"format":"qcow2","actual-size":-1}'})

    def test_booleano_nao_e_inteiro(self) -> None:
        with self.assertRaises(DataError):
            qemu_image.inspect_image(
                {"json": '{"format":"qcow2","virtual-size":true}'}
            )

    def test_campos_opcionais_ausentes(self) -> None:
        dados = qemu_image.inspect_image({"json": '{"format":"qcow2"}'})
        self.assertEqual(dados["virtual_size"], -1)
        self.assertEqual(dados["actual_size"], -1)
        self.assertEqual(dados["cluster_size"], -1)

    def test_json_vazio(self) -> None:
        for entrada in ("", "   "):
            with self.assertRaises(MissingInputError):
                qemu_image.inspect_image({"json": entrada})

    def test_json_malformado(self) -> None:
        with self.assertRaises(DataError) as contexto:
            qemu_image.inspect_image({"json": '{"format":"qcow2"'})
        self.assertIn("inválido", str(contexto.exception))

    def test_chave_duplicada(self) -> None:
        with self.assertRaises(DataError) as contexto:
            qemu_image.inspect_image(
                {"json": '{"format":"qcow2","format":"raw"}'}
            )
        self.assertIn("duplicada", str(contexto.exception))

    def test_constante_nao_numerica(self) -> None:
        with self.assertRaises(DataError):
            qemu_image.inspect_image({"json": '{"format":"qcow2","actual-size":NaN}'})

    def test_tipo_de_raiz_invalido(self) -> None:
        for entrada in ('"qcow2"', "42", "true", "null"):
            with self.assertRaises(DataError):
                qemu_image.inspect_image({"json": entrada})

    def test_json_com_tipo_errado_no_payload(self) -> None:
        with self.assertRaises(DataError):
            qemu_image.inspect_image({"json": 7})

    def test_require_no_backing_em_texto(self) -> None:
        dados = qemu_image.inspect_image(
            {"json": fx.QEMU_IMG_SIMPLES, "require_no_backing": "1"}
        )
        self.assertEqual(dados["has_backing"], 0)
        with self.assertRaises(DataError):
            qemu_image.inspect_image(
                {"json": fx.QEMU_IMG_COM_BACKING, "require_no_backing": "1"}
            )

    def test_require_no_backing_texto_invalido(self) -> None:
        with self.assertRaises(DataError):
            qemu_image.inspect_image(
                {"json": fx.QEMU_IMG_SIMPLES, "require_no_backing": "sim"}
            )

    def test_expect_format_invalido(self) -> None:
        with self.assertRaises(DataError):
            qemu_image.inspect_image(
                {"json": fx.QEMU_IMG_SIMPLES, "expect_format": 7}
            )


class ChainTests(unittest.TestCase):
    def test_cadeia_coerente(self) -> None:
        dados = qemu_image.inspect_image({"json": fx.QEMU_IMG_CADEIA})
        self.assertEqual(dados["chain_length"], 2)
        self.assertEqual(dados["has_backing"], 1)

    def test_cadeia_recusada_quando_exige_independencia(self) -> None:
        with self.assertRaises(DataError):
            qemu_image.inspect_image(
                {"json": fx.QEMU_IMG_CADEIA, "require_no_backing": True}
            )

    def test_cadeia_incoerente(self) -> None:
        incoerente = (
            '[{"filename":"/vm/a.qcow2","format":"qcow2"},'
            '{"filename":"/vm/b.qcow2","format":"qcow2"}]'
        )
        with self.assertRaises(DataError) as contexto:
            qemu_image.inspect_image({"json": incoerente})
        self.assertIn("incoerente", str(contexto.exception))

    def test_cadeia_vazia(self) -> None:
        with self.assertRaises(DataError):
            qemu_image.inspect_image({"json": "[]"})

    def test_elemento_da_cadeia_sem_filename(self) -> None:
        ruim = (
            '[{"filename":"/vm/a.qcow2","format":"qcow2",'
            '"backing-filename":"/vm/b.qcow2"},{"format":"qcow2"}]'
        )
        with self.assertRaises(DataError):
            qemu_image.inspect_image({"json": ruim})

    def test_elemento_da_cadeia_nao_objeto(self) -> None:
        with self.assertRaises(DataError):
            qemu_image.inspect_image({"json": '[{"format":"qcow2"},7]'})

    def test_limite_de_profundidade(self) -> None:
        elementos = ",".join(
            '{"filename":"/vm/%d.qcow2","format":"qcow2"}' % indice
            for indice in range(qemu_image.MAX_CHAIN_DEPTH + 1)
        )
        with self.assertRaises(DataError) as contexto:
            qemu_image.inspect_image({"json": "[" + elementos + "]"})
        self.assertIn("limite", str(contexto.exception))


class IdentityTests(unittest.TestCase):
    """REQ-WINDOWS-STATE: identidade estável do arquivo QCOW2, sem lê-lo."""

    BASE = {
        "path": "/vm/win11.qcow2",
        "device": "64768",
        "inode": "1234567",
        "birth": "",
        "format": "qcow2",
    }

    def identidade(self, **mudancas: str) -> dict:
        entrada = dict(self.BASE)
        entrada.update(mudancas)
        return qemu_image.image_identity(entrada)

    def test_sem_birth(self) -> None:
        dados = self.identidade()
        self.assertEqual(dados["identity_kind"], "inode")
        self.assertEqual(dados["identity_birth"], "-")
        self.assertRegex(dados["identity_digest"], r"^[0-9a-f]{64}$")
        # Sem birth o digest gravado e o digest base coincidem por construção.
        self.assertEqual(dados["identity_digest"], dados["identity_digest_base"])

    def test_birth_ausente_canonicaliza_como_traco(self) -> None:
        # `stat -c '%w'` devolve '-' em vários filesystems: vazio e '-' precisam
        # produzir exatamente a mesma identidade, senão a evidência já gravada
        # deixaria de conferir só por causa do formato da captura.
        self.assertEqual(
            self.identidade(birth="-")["identity_digest"],
            self.identidade(birth="")["identity_digest"],
        )
        self.assertEqual(self.identidade(birth="-")["identity_kind"], "inode")

    def test_birth_presente_fortalece_a_identidade(self) -> None:
        com_birth = self.identidade(birth="20260817-120000")
        sem_birth = self.identidade()
        self.assertEqual(com_birth["identity_kind"], "inode+birth")
        self.assertEqual(com_birth["identity_birth"], "20260817-120000")
        self.assertNotEqual(com_birth["identity_digest"], sem_birth["identity_digest"])
        # O digest base ignora o birth: é ele que sustenta evidência gravada
        # antes de o filesystem passar a expor birth.
        self.assertEqual(
            com_birth["identity_digest_base"], sem_birth["identity_digest"]
        )

    def test_identidade_e_determinista(self) -> None:
        self.assertEqual(
            self.identidade()["identity_digest"],
            self.identidade()["identity_digest"],
        )

    def test_arquivos_distintos_produzem_identidades_distintas(self) -> None:
        digests = {
            self.identidade()["identity_digest"],
            self.identidade(inode="7654321")["identity_digest"],
            self.identidade(device="64769")["identity_digest"],
            self.identidade(path="/vm/outro.qcow2")["identity_digest"],
            self.identidade(birth="20260817-120000")["identity_digest"],
        }
        self.assertEqual(len(digests), 5)

    def test_formato_diferente_de_qcow2_recusado(self) -> None:
        for formato in ("raw", "vmdk", "QCOW2", ""):
            with self.assertRaises(DataError) as contexto:
                self.identidade(format=formato)
            self.assertIn("qcow2", str(contexto.exception))

    def test_inode_nao_numerico_recusado(self) -> None:
        for inode in ("abc", "12a", "1.5", " 12", "12 ", "+12", "-12", "١٢"):
            with self.assertRaises(DataError):
                self.identidade(inode=inode)

    def test_inode_e_device_precisam_ser_positivos(self) -> None:
        for campo in ("inode", "device"):
            for valor in ("0", "00", "0123"):
                with self.assertRaises(DataError):
                    self.identidade(**{campo: valor})

    def test_numero_absurdamente_longo_recusado(self) -> None:
        with self.assertRaises(DataError):
            self.identidade(inode="1" * 21)

    def test_path_relativo_recusado(self) -> None:
        for caminho in ("vm/win11.qcow2", "./win11.qcow2", "", "win11.qcow2", "/"):
            with self.assertRaises(DataError):
                self.identidade(path=caminho)

    def test_path_nao_canonico_recusado(self) -> None:
        for caminho in (
            "/vm/../etc/win11.qcow2",
            "/vm/./win11.qcow2",
            "/vm//win11.qcow2",
            "/vm/win11.qcow2/",
            "/vm/..",
        ):
            with self.assertRaises(DataError):
                self.identidade(path=caminho)

    def test_path_com_controle_recusado(self) -> None:
        for caminho in ("/vm/win\n11.qcow2", "/vm/win\t11.qcow2", "/vm/win\x7f.qcow2"):
            with self.assertRaises(DataError):
                self.identidade(path=caminho)

    def test_path_acima_do_limite_recusado(self) -> None:
        with self.assertRaises(DataError):
            self.identidade(path="/vm/" + "a" * qemu_image.MAX_IDENTITY_PATH_BYTES)

    def test_birth_malformado_recusado(self) -> None:
        for birth in (
            "2026-08-17",
            "20260817",
            "20260817-1200",
            "20260817 120000",
            "ontem",
            "20260817-120000 ",
        ):
            with self.assertRaises(DataError):
                self.identidade(birth=birth)

    def test_campo_obrigatorio_ausente(self) -> None:
        for campo in ("path", "device", "inode", "format"):
            entrada = dict(self.BASE)
            del entrada[campo]
            with self.assertRaises(DataError) as contexto:
                qemu_image.image_identity(entrada)
            self.assertIn("obrigatório", str(contexto.exception))

    def test_birth_ausente_no_payload_e_aceito(self) -> None:
        entrada = dict(self.BASE)
        del entrada["birth"]
        self.assertEqual(
            qemu_image.image_identity(entrada)["identity_digest"],
            self.identidade()["identity_digest"],
        )

    def test_campo_desconhecido_recusado(self) -> None:
        with self.assertRaises(DataError) as contexto:
            qemu_image.image_identity(dict(self.BASE, sha256="x"))
        self.assertIn("desconhecido", str(contexto.exception))

    def test_campo_com_tipo_errado_recusado(self) -> None:
        for campo in ("path", "device", "inode", "format", "birth"):
            with self.assertRaises(DataError):
                qemu_image.image_identity(dict(self.BASE, **{campo: 7}))

    def test_texto_canonico_e_versionado(self) -> None:
        texto = qemu_image._identity_text(
            "inode", "/vm/win11.qcow2", "64768", "1234567", "-"
        )
        self.assertTrue(texto.startswith(qemu_image.IDENTITY_VERSION + "\n"))
        self.assertTrue(texto.endswith("\n"))
        self.assertIn("kind=inode\n", texto)
        self.assertIn("format=qcow2\n", texto)


if __name__ == "__main__":
    unittest.main()
