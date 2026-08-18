"""Envelope fechado, serialização determinística, canal de pares e redação.

Os separadores do canal de pares são escritos com `chr(0)` em vez de escapes
literais, para que o próprio arquivo de teste continue sendo texto legítimo.
"""
import json
import unittest

from passthrough_core import protocol
from passthrough_core.errors import (
    DataError,
    InternalError,
    MissingInputError,
    UsageError,
)

NUL = chr(0)


def envelope(payload: dict, version: object = 1) -> bytes:
    return json.dumps(
        {"protocol_version": version, "payload": payload},
        ensure_ascii=False,
    ).encode("utf-8")


def pares(*campos: str) -> bytes:
    """Codificação esperada do canal de pares a partir de campos alternados."""
    return "".join(campo + NUL for campo in campos).encode("utf-8")


class SerializationTests(unittest.TestCase):
    def test_versoes_declaradas(self) -> None:
        self.assertEqual(protocol.PROTOCOL_VERSION, 1)
        self.assertTrue(protocol.CORE_VERSION)
        self.assertNotEqual(protocol.CORE_VERSION, str(protocol.PROTOCOL_VERSION))

    def test_serializacao_determinista_independe_da_ordem(self) -> None:
        primeiro = protocol.serialize({"b": 1, "a": {"d": 2, "c": 3}})
        segundo = protocol.serialize({"a": {"c": 3, "d": 2}, "b": 1})
        self.assertEqual(primeiro, segundo)
        self.assertEqual(primeiro, b'{"a":{"c":3,"d":2},"b":1}\n')

    def test_serializacao_preserva_unicode_sem_escape(self) -> None:
        saida = protocol.serialize({"texto": "acentuação ção ✓"})
        self.assertEqual(saida, '{"texto":"acentuação ção ✓"}\n'.encode("utf-8"))

    def test_serializacao_recusa_nao_finito(self) -> None:
        for valor in (float("nan"), float("inf"), float("-inf")):
            with self.subTest(valor=valor):
                with self.assertRaises(InternalError):
                    protocol.serialize({"valor": valor})

    def test_serializacao_recusa_tipo_desconhecido(self) -> None:
        with self.assertRaises(InternalError):
            protocol.serialize({"valor": object()})


class ResponseTests(unittest.TestCase):
    def test_envelope_de_resposta_fechado(self) -> None:
        resposta = protocol.build_response("version", {})
        self.assertEqual(tuple(sorted(resposta)), protocol.RESPONSE_KEYS)
        self.assertEqual(resposta["protocol_version"], protocol.PROTOCOL_VERSION)
        self.assertEqual(resposta["core_version"], protocol.CORE_VERSION)

    def test_encode_response_determinista(self) -> None:
        esperado = (
            '{"core_version":"%s","data":{},"protocol_version":1,'
            '"subcommand":"version"}\n' % protocol.CORE_VERSION
        ).encode("utf-8")
        self.assertEqual(protocol.encode_response("version", {}), esperado)

    def test_subcomando_invalido(self) -> None:
        for nome in ("", "com espaco", "../fuga", "a" * 65):
            with self.subTest(nome=nome):
                with self.assertRaises(UsageError):
                    protocol.build_response(nome, {})

    def test_validate_response_recusa_chave_extra(self) -> None:
        resposta = protocol.build_response("version", {})
        resposta["extra"] = 1
        with self.assertRaises(InternalError):
            protocol.validate_response(resposta)

    def test_validate_response_recusa_chave_ausente(self) -> None:
        resposta = protocol.build_response("version", {})
        del resposta["data"]
        with self.assertRaises(InternalError):
            protocol.validate_response(resposta)

    def test_validate_response_recusa_versao_divergente(self) -> None:
        resposta = protocol.build_response("version", {})
        resposta["protocol_version"] = 2
        with self.assertRaises(InternalError):
            protocol.validate_response(resposta)

    def test_dados_precisam_ser_mapeamento(self) -> None:
        with self.assertRaises(InternalError):
            protocol.build_response("version", [("a", 1)])  # type: ignore[arg-type]


class DecodeRequestTests(unittest.TestCase):
    def test_payload_valido(self) -> None:
        payload = protocol.decode_request(envelope({"a": 1, "b": {"c": "x"}}))
        self.assertEqual(payload, {"a": 1, "b": {"c": "x"}})

    def test_payload_vazio(self) -> None:
        with self.assertRaises(MissingInputError):
            protocol.decode_request(b"")

    def test_payload_apenas_espacos(self) -> None:
        with self.assertRaises(MissingInputError):
            protocol.decode_request(b"   \n\t ")

    def test_payload_grande_aceito(self) -> None:
        texto = "x" * (protocol.MAX_PAYLOAD_BYTES // 2)
        payload = protocol.decode_request(envelope({"grande": texto}))
        self.assertEqual(len(payload["grande"]), len(texto))

    def test_payload_acima_do_limite(self) -> None:
        bruto = b"x" * (protocol.MAX_PAYLOAD_BYTES + 1)
        with self.assertRaises(DataError):
            protocol.decode_request(bruto)

    def test_payload_nao_utf8(self) -> None:
        with self.assertRaises(DataError):
            protocol.decode_request(b'{"protocol_version":1,"payload":{"a":"\xff"}}')

    def test_payload_malformado(self) -> None:
        with self.assertRaises(DataError):
            protocol.decode_request(b'{"protocol_version":1,')

    def test_topo_nao_objeto(self) -> None:
        for bruto in (b"[]", b'"texto"', b"7", b"null"):
            with self.subTest(bruto=bruto):
                with self.assertRaises(DataError):
                    protocol.decode_request(bruto)

    def test_chave_extra_no_envelope(self) -> None:
        with self.assertRaises(DataError):
            protocol.decode_request(
                b'{"protocol_version":1,"payload":{},"extra":true}'
            )

    def test_chave_ausente_no_envelope(self) -> None:
        with self.assertRaises(DataError):
            protocol.decode_request(b'{"payload":{}}')

    def test_versao_booleana_recusada(self) -> None:
        with self.assertRaises(DataError):
            protocol.decode_request(b'{"protocol_version":true,"payload":{}}')

    def test_versao_nao_suportada(self) -> None:
        with self.assertRaises(DataError):
            protocol.decode_request(envelope({}, version=2))

    def test_versao_textual_recusada(self) -> None:
        with self.assertRaises(DataError):
            protocol.decode_request(envelope({}, version="1"))

    def test_payload_nao_objeto(self) -> None:
        with self.assertRaises(DataError):
            protocol.decode_request(b'{"protocol_version":1,"payload":[]}')

    def test_chave_duplicada(self) -> None:
        with self.assertRaises(DataError):
            protocol.decode_request(
                b'{"protocol_version":1,"payload":{"a":1,"a":2}}'
            )

    def test_chave_duplicada_aninhada(self) -> None:
        with self.assertRaises(DataError):
            protocol.decode_request(
                b'{"protocol_version":1,"payload":{"n":{"a":1,"a":2}}}'
            )

    def test_constante_nao_numerica(self) -> None:
        for constante in (b"NaN", b"Infinity", b"-Infinity"):
            with self.subTest(constante=constante):
                with self.assertRaises(DataError):
                    protocol.decode_request(
                        b'{"protocol_version":1,"payload":{"v":' + constante + b"}}"
                    )

    def test_transporte_precisa_entregar_bytes(self) -> None:
        with self.assertRaises(InternalError):
            protocol.decode_request('{"protocol_version":1,"payload":{}}')

    def test_conteudo_hostil_permanece_inerte(self) -> None:
        original = {
            "comando": "$(touch /tmp/passthrough-canario-i2)",
            "crase": "`id`",
            "quebra": "linha1\nlinha2",
            "hifen": "-rf",
            "nulo": "a" + NUL + "b",
            "aspas": 'fim" ; rm -rf /',
        }
        payload = protocol.decode_request(envelope(original))
        self.assertEqual(payload, original)


class PairsTests(unittest.TestCase):
    def test_ordem_e_delimitadores(self) -> None:
        self.assertEqual(
            protocol.encode_pairs({"SEGUNDA": "b", "PRIMEIRA": "a"}),
            pares("PRIMEIRA", "a", "SEGUNDA", "b"),
        )

    def test_escalares_convertidos(self) -> None:
        self.assertEqual(
            protocol.encode_pairs({"N": 7, "V": True, "F": False, "T": "texto"}),
            pares("F", "0", "N", "7", "T", "texto", "V", "1"),
        )

    def test_valor_com_espaco_e_quebra(self) -> None:
        self.assertEqual(
            protocol.encode_pairs({"V": "com espaço\ne quebra"}),
            pares("V", "com espaço\ne quebra"),
        )

    def test_chave_invalida(self) -> None:
        for chave in ("minuscula", "COM-HIFEN", "1INICIAL", "", "A" * 65):
            with self.subTest(chave=chave):
                with self.assertRaises(InternalError):
                    protocol.encode_pairs({chave: "v"})

    def test_valor_nao_escalar(self) -> None:
        for valor in ({"a": 1}, ["a"], None, 1.5):
            with self.subTest(valor=valor):
                with self.assertRaises(InternalError):
                    protocol.encode_pairs({"CHAVE": valor})

    def test_valor_com_nul(self) -> None:
        with self.assertRaises(InternalError):
            protocol.encode_pairs({"CHAVE": "a" + NUL + "b"})

    def test_valor_acima_do_limite(self) -> None:
        with self.assertRaises(InternalError):
            protocol.encode_pairs(
                {"CHAVE": "x" * (protocol.MAX_PAIR_VALUE_BYTES + 1)}
            )

    def test_mapeamento_obrigatorio(self) -> None:
        with self.assertRaises(InternalError):
            protocol.encode_pairs([("CHAVE", "v")])  # type: ignore[arg-type]

    def test_projecao_da_resposta(self) -> None:
        resposta = protocol.build_response("version", {})
        self.assertEqual(
            protocol.pairs_from_response(resposta),
            pares(
                "CORE_VERSION",
                protocol.CORE_VERSION,
                "PROTOCOL_VERSION",
                "1",
                "SUBCOMMAND",
                "version",
            ),
        )

    def test_projecao_inclui_dados_em_maiusculas(self) -> None:
        resposta = protocol.build_response("payload-probe", {"byte_length": 3})
        self.assertIn(
            pares("BYTE_LENGTH", "3"), protocol.pairs_from_response(resposta)
        )

    def test_projecao_recusa_colisao(self) -> None:
        resposta = protocol.build_response("version", {"core_version": "x"})
        with self.assertRaises(InternalError):
            protocol.pairs_from_response(resposta)

    def test_projecao_recusa_chave_nao_projetavel(self) -> None:
        resposta = protocol.build_response("version", {"com-hifen": "x"})
        with self.assertRaises(InternalError):
            protocol.pairs_from_response(resposta)


class ScalarIdentifierTests(unittest.TestCase):
    def test_aceitos(self) -> None:
        for valor in ("abc", "A1", "op-123", "op_123", "9", "a" * 64):
            with self.subTest(valor=valor):
                self.assertEqual(
                    protocol.validate_scalar_identifier(valor, "campo"), valor
                )

    def test_recusados(self) -> None:
        recusados = (
            "",
            "-inicial",
            "_inicial",
            "com espaco",
            "../fuga",
            "a/b",
            "a;b",
            "a" * 65,
            "acentuação",
            None,
            7,
        )
        for valor in recusados:
            with self.subTest(valor=valor):
                with self.assertRaises(UsageError):
                    protocol.validate_scalar_identifier(valor, "campo")


class SafeLabelTests(unittest.TestCase):
    def test_rotulos_publicaveis(self) -> None:
        for valor in ("version", "--format", "chave_1", "1.2.3", "a:b"):
            with self.subTest(valor=valor):
                self.assertEqual(protocol.safe_label(valor), valor)

    def test_rotulos_redigidos(self) -> None:
        redigidos = (
            "/vm/Windows11.qcow2",
            "/home/usuario/segredo",
            "senha com espaço",
            "x" * 65,
            None,
            {"a": 1},
        )
        for valor in redigidos:
            with self.subTest(valor=valor):
                self.assertEqual(protocol.safe_label(valor), protocol.REDACTED_LABEL)

    def test_diagnostico_nao_contem_valor_bruto(self) -> None:
        canario = "CANARIO_SECRETO_/etc/shadow"
        with self.assertRaises(UsageError) as capturado:
            protocol.validate_scalar_identifier(canario, "--operation-id")
        self.assertNotIn(canario, capturado.exception.message)
        self.assertIn(protocol.REDACTED_LABEL, capturado.exception.message)


if __name__ == "__main__":
    unittest.main()
