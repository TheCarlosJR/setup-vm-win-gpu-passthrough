"""Despacho, canais de saída, códigos internos e política da entrada controlada."""
import hashlib
import io
import json
import os
import tempfile
import unittest
from unittest import mock

from passthrough_core import cli, errors, protocol

NUL = chr(0)


def executar(argv: list, entrada: bytes = b"") -> tuple:
    """Executa a CLI em processo, com fluxos binários isolados."""
    stdin = io.BytesIO(entrada)
    stdout = io.BytesIO()
    stderr = io.BytesIO()
    codigo = cli.main(argv, stdin=stdin, stdout=stdout, stderr=stderr)
    return codigo, stdout.getvalue(), stderr.getvalue()


def envelope(payload: dict, version: object = 1) -> bytes:
    return json.dumps(
        {"protocol_version": version, "payload": payload}, ensure_ascii=False
    ).encode("utf-8")


class VersionTests(unittest.TestCase):
    def test_saida_json_deterministica(self) -> None:
        codigo, saida, diagnostico = executar(["version"])
        self.assertEqual(codigo, errors.EXIT_OK)
        self.assertEqual(diagnostico, b"")
        self.assertEqual(saida, protocol.encode_response("version", {}))
        documento = json.loads(saida.decode("utf-8"))
        self.assertEqual(documento["protocol_version"], protocol.PROTOCOL_VERSION)
        self.assertEqual(documento["core_version"], protocol.CORE_VERSION)

    def test_saida_repetida_e_identica(self) -> None:
        primeira = executar(["version"])
        segunda = executar(["version"])
        self.assertEqual(primeira, segunda)

    def test_saida_em_pares(self) -> None:
        codigo, saida, _ = executar(["version", "--format=pairs"])
        self.assertEqual(codigo, errors.EXIT_OK)
        campos = saida.decode("utf-8").split(NUL)
        self.assertEqual(campos[-1], "")
        self.assertEqual(
            campos[:-1],
            [
                "CORE_VERSION",
                protocol.CORE_VERSION,
                "PROTOCOL_VERSION",
                "1",
                "SUBCOMMAND",
                "version",
            ],
        )

    def test_nao_abre_nenhum_arquivo(self) -> None:
        def recusar(*argumentos, **nomeados):
            raise AssertionError("o subcomando version não pode abrir arquivos")

        with mock.patch("builtins.open", recusar), mock.patch("os.open", recusar):
            codigo, saida, _ = executar(["version"])
        self.assertEqual(codigo, errors.EXIT_OK)
        self.assertTrue(saida)

    def test_opcao_de_transporte_recusada(self) -> None:
        for argv in (["version", "--stdin"], ["version", "--input-file=/tmp/x"]):
            with self.subTest(argv=argv):
                codigo, saida, diagnostico = executar(argv)
                self.assertEqual(codigo, errors.EXIT_USAGE)
                self.assertEqual(saida, b"")
                self.assertIn(b"Op", diagnostico)


class DispatchTests(unittest.TestCase):
    def test_subcomando_ausente(self) -> None:
        codigo, saida, diagnostico = executar([])
        self.assertEqual(codigo, errors.EXIT_USAGE)
        self.assertEqual(saida, b"")
        self.assertIn("Subcomando ausente", diagnostico.decode("utf-8"))

    def test_subcomando_desconhecido(self) -> None:
        codigo, saida, diagnostico = executar(["inexistente"])
        self.assertEqual(codigo, errors.EXIT_USAGE)
        self.assertEqual(saida, b"")
        self.assertIn("Uso interno do core", diagnostico.decode("utf-8"))

    def test_argumento_posicional(self) -> None:
        codigo, saida, _ = executar(["version", "extra"])
        self.assertEqual(codigo, errors.EXIT_USAGE)
        self.assertEqual(saida, b"")

    def test_separador_solto(self) -> None:
        codigo, saida, _ = executar(["version", "--"])
        self.assertEqual(codigo, errors.EXIT_USAGE)
        self.assertEqual(saida, b"")

    def test_opcao_repetida(self) -> None:
        codigo, saida, _ = executar(["version", "--format=json", "--format=pairs"])
        self.assertEqual(codigo, errors.EXIT_USAGE)
        self.assertEqual(saida, b"")

    def test_formato_invalido(self) -> None:
        codigo, saida, diagnostico = executar(["version", "--format=xml"])
        self.assertEqual(codigo, errors.EXIT_USAGE)
        self.assertEqual(saida, b"")
        self.assertIn("json ou pairs", diagnostico.decode("utf-8"))

    def test_traceback_apenas_como_primeiro_argumento(self) -> None:
        codigo, saida, _ = executar(["version", "--traceback"])
        self.assertEqual(codigo, errors.EXIT_USAGE)
        self.assertEqual(saida, b"")

    def test_sem_traceback_por_padrao(self) -> None:
        _codigo, _saida, diagnostico = executar(["inexistente"])
        self.assertNotIn(b"Traceback", diagnostico)

    def test_traceback_em_modo_explicito(self) -> None:
        codigo, saida, diagnostico = executar(["--traceback", "inexistente"])
        self.assertEqual(codigo, errors.EXIT_USAGE)
        self.assertEqual(saida, b"")
        self.assertIn(b"Traceback", diagnostico)

    def test_falha_inesperada_vira_erro_interno(self) -> None:
        with mock.patch.dict(
            cli.SUBCOMMANDS,
            {"explodir": lambda argumentos, streams: 1 / 0},
            clear=False,
        ):
            codigo, saida, diagnostico = executar(["explodir"])
        self.assertEqual(codigo, errors.EXIT_INTERNAL)
        self.assertEqual(saida, b"")
        self.assertIn(b"ZeroDivisionError", diagnostico)
        self.assertNotIn(b"Traceback", diagnostico)


class PayloadProbeStdinTests(unittest.TestCase):
    def test_payload_valido(self) -> None:
        bruto = envelope({"a": "com espaço", "b": "-hifen", "c": "acentuação"})
        codigo, saida, diagnostico = executar(["payload-probe", "--stdin"], bruto)
        self.assertEqual(codigo, errors.EXIT_OK)
        self.assertEqual(diagnostico, b"")
        dados = json.loads(saida.decode("utf-8"))["data"]
        self.assertEqual(dados["byte_length"], len(bruto))
        self.assertEqual(dados["key_count"], 3)
        self.assertEqual(dados["sha256"], hashlib.sha256(bruto).hexdigest())
        self.assertEqual(dados["operation_id"], "")

    def test_conteudo_nao_aparece_na_saida(self) -> None:
        canario = "CANARIO-SECRETO-I2-NAO-DEVE-VAZAR"
        bruto = envelope({"segredo": canario})
        codigo, saida, diagnostico = executar(["payload-probe", "--stdin"], bruto)
        self.assertEqual(codigo, errors.EXIT_OK)
        self.assertNotIn(canario.encode("utf-8"), saida)
        self.assertNotIn(canario.encode("utf-8"), diagnostico)

    def test_payload_vazio(self) -> None:
        codigo, saida, _ = executar(["payload-probe", "--stdin"], b"")
        self.assertEqual(codigo, errors.EXIT_MISSING_INPUT)
        self.assertEqual(saida, b"")

    def test_payload_malformado(self) -> None:
        codigo, saida, _ = executar(["payload-probe", "--stdin"], b"{")
        self.assertEqual(codigo, errors.EXIT_DATA)
        self.assertEqual(saida, b"")

    def test_payload_acima_do_limite(self) -> None:
        bruto = b"x" * (protocol.MAX_PAYLOAD_BYTES + 1)
        codigo, saida, _ = executar(["payload-probe", "--stdin"], bruto)
        self.assertEqual(codigo, errors.EXIT_DATA)
        self.assertEqual(saida, b"")

    def test_transporte_ausente(self) -> None:
        codigo, saida, diagnostico = executar(["payload-probe"])
        self.assertEqual(codigo, errors.EXIT_USAGE)
        self.assertEqual(saida, b"")
        self.assertIn("exatamente um transporte", diagnostico.decode("utf-8"))

    def test_transporte_ambiguo(self) -> None:
        codigo, saida, _ = executar(
            ["payload-probe", "--stdin", "--input-file=/tmp/x"], envelope({})
        )
        self.assertEqual(codigo, errors.EXIT_USAGE)
        self.assertEqual(saida, b"")

    def test_operation_id_valido_e_ecoado(self) -> None:
        codigo, saida, _ = executar(
            ["payload-probe", "--stdin", "--operation-id=op-123"], envelope({})
        )
        self.assertEqual(codigo, errors.EXIT_OK)
        dados = json.loads(saida.decode("utf-8"))["data"]
        self.assertEqual(dados["operation_id"], "op-123")

    def test_operation_id_invalido(self) -> None:
        for valor in ("../fuga", "com espaco", "", "/tmp/x"):
            with self.subTest(valor=valor):
                codigo, saida, diagnostico = executar(
                    ["payload-probe", "--stdin", "--operation-id=%s" % valor],
                    envelope({}),
                )
                self.assertEqual(codigo, errors.EXIT_USAGE)
                self.assertEqual(saida, b"")
                if valor:
                    self.assertNotIn(valor.encode("utf-8"), diagnostico)

    def test_saida_em_pares(self) -> None:
        bruto = envelope({"a": 1})
        codigo, saida, _ = executar(
            ["payload-probe", "--stdin", "--format=pairs"], bruto
        )
        self.assertEqual(codigo, errors.EXIT_OK)
        campos = saida.decode("utf-8").split(NUL)[:-1]
        self.assertEqual(len(campos) % 2, 0)
        mapa = dict(zip(campos[0::2], campos[1::2]))
        self.assertEqual(mapa["BYTE_LENGTH"], str(len(bruto)))
        self.assertEqual(mapa["SHA256"], hashlib.sha256(bruto).hexdigest())
        self.assertEqual(mapa["SUBCOMMAND"], "payload-probe")


class ControlledInputTests(unittest.TestCase):
    def setUp(self) -> None:
        self.diretorio = tempfile.TemporaryDirectory()
        self.addCleanup(self.diretorio.cleanup)
        self.base = self.diretorio.name

    def _arquivo(self, conteudo: bytes, modo: int = 0o600) -> str:
        descritor, caminho = tempfile.mkstemp(dir=self.base)
        with os.fdopen(descritor, "wb") as destino:
            destino.write(conteudo)
        os.chmod(caminho, modo)
        return caminho

    def test_arquivo_valido(self) -> None:
        bruto = envelope({"a": "x"})
        caminho = self._arquivo(bruto)
        codigo, saida, diagnostico = executar(
            ["payload-probe", "--input-file=%s" % caminho]
        )
        self.assertEqual(codigo, errors.EXIT_OK)
        self.assertEqual(diagnostico, b"")
        dados = json.loads(saida.decode("utf-8"))["data"]
        self.assertEqual(dados["sha256"], hashlib.sha256(bruto).hexdigest())

    def test_caminho_relativo(self) -> None:
        codigo, saida, _ = executar(["payload-probe", "--input-file=relativo.json"])
        self.assertEqual(codigo, errors.EXIT_USAGE)
        self.assertEqual(saida, b"")

    def test_caminho_nao_canonico(self) -> None:
        caminho = self._arquivo(envelope({}))
        pai = os.path.dirname(caminho)
        nome = os.path.basename(caminho)
        for variante in (
            "%s/./%s" % (pai, nome),
            "%s/../%s/%s" % (pai, os.path.basename(pai), nome),
            "%s//%s" % (pai, nome),
        ):
            with self.subTest(variante=variante):
                codigo, saida, _ = executar(
                    ["payload-probe", "--input-file=%s" % variante]
                )
                self.assertEqual(codigo, errors.EXIT_USAGE)
                self.assertEqual(saida, b"")

    def test_arquivo_inexistente(self) -> None:
        codigo, saida, _ = executar(
            ["payload-probe", "--input-file=%s/ausente" % self.base]
        )
        self.assertEqual(codigo, errors.EXIT_MISSING_INPUT)
        self.assertEqual(saida, b"")

    def test_symlink_recusado(self) -> None:
        alvo = self._arquivo(envelope({}))
        atalho = os.path.join(self.base, "atalho.json")
        os.symlink(alvo, atalho)
        codigo, saida, _ = executar(["payload-probe", "--input-file=%s" % atalho])
        self.assertEqual(codigo, errors.EXIT_USAGE)
        self.assertEqual(saida, b"")

    def test_modo_permissivo_recusado(self) -> None:
        caminho = self._arquivo(envelope({}), modo=0o644)
        codigo, saida, diagnostico = executar(
            ["payload-probe", "--input-file=%s" % caminho]
        )
        self.assertEqual(codigo, errors.EXIT_USAGE)
        self.assertEqual(saida, b"")
        self.assertIn("0600", diagnostico.decode("utf-8"))

    def test_hardlink_recusado(self) -> None:
        caminho = self._arquivo(envelope({}))
        gemeo = os.path.join(self.base, "gemeo.json")
        os.link(caminho, gemeo)
        self.assertEqual(os.stat(caminho).st_nlink, 2)
        codigo, saida, diagnostico = executar(
            ["payload-probe", "--input-file=%s" % caminho]
        )
        self.assertEqual(codigo, errors.EXIT_USAGE)
        self.assertEqual(saida, b"")
        self.assertIn("link", diagnostico.decode("utf-8"))

    def test_diretorio_recusado(self) -> None:
        interno = os.path.join(self.base, "subdiretorio")
        os.mkdir(interno, 0o700)
        codigo, saida, diagnostico = executar(
            ["payload-probe", "--input-file=%s" % interno]
        )
        self.assertEqual(codigo, errors.EXIT_USAGE)
        self.assertEqual(saida, b"")
        self.assertIn("regular", diagnostico.decode("utf-8"))

    def test_raiz_privada_permissiva_recusada(self) -> None:
        aberta = os.path.join(self.base, "aberta")
        os.mkdir(aberta, 0o755)
        descritor, caminho = tempfile.mkstemp(dir=aberta)
        os.close(descritor)
        os.chmod(caminho, 0o600)
        codigo, saida, diagnostico = executar(
            ["payload-probe", "--input-file=%s" % caminho]
        )
        self.assertEqual(codigo, errors.EXIT_USAGE)
        self.assertEqual(saida, b"")
        self.assertIn("grupo e outros", diagnostico.decode("utf-8"))

    def test_raiz_privada_inexistente(self) -> None:
        codigo, saida, diagnostico = executar(
            ["payload-probe", "--input-file=%s/ausente/payload" % self.base]
        )
        self.assertEqual(codigo, errors.EXIT_MISSING_INPUT)
        self.assertEqual(saida, b"")
        self.assertIn("Raiz privada", diagnostico.decode("utf-8"))

    def test_arquivo_direto_na_raiz_do_sistema(self) -> None:
        codigo, saida, diagnostico = executar(["payload-probe", "--input-file=/payload"])
        self.assertEqual(codigo, errors.EXIT_USAGE)
        self.assertEqual(saida, b"")
        self.assertIn("raiz privada", diagnostico.decode("utf-8"))

    def test_arquivo_acima_do_limite(self) -> None:
        caminho = self._arquivo(b"x" * (protocol.MAX_PAYLOAD_BYTES + 1))
        codigo, saida, _ = executar(["payload-probe", "--input-file=%s" % caminho])
        self.assertEqual(codigo, errors.EXIT_DATA)
        self.assertEqual(saida, b"")

    def test_caminho_nao_aparece_no_diagnostico(self) -> None:
        caminho = self._arquivo(envelope({}), modo=0o644)
        _codigo, _saida, diagnostico = executar(
            ["payload-probe", "--input-file=%s" % caminho]
        )
        self.assertNotIn(caminho.encode("utf-8"), diagnostico)


if __name__ == "__main__":
    unittest.main()
