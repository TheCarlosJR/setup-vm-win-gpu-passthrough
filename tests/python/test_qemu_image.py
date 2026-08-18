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


if __name__ == "__main__":
    unittest.main()
