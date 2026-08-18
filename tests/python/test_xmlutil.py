"""Leitura segura, cardinalidade e canonicalização de XML (I3.1 e I3.3)."""
import unittest

from passthrough_core import xmlutil
from passthrough_core.errors import DataError

import fixtures_i3 as fx


class ParseTests(unittest.TestCase):
    def test_raiz_esperada(self) -> None:
        raiz = xmlutil.parse_document(fx.domain(), "domain", "XML de domínio")
        self.assertEqual(raiz.tag, "domain")

    def test_raiz_divergente(self) -> None:
        with self.assertRaises(DataError):
            xmlutil.parse_document(fx.network(), "domain", "XML de domínio")

    def test_texto_vazio(self) -> None:
        for entrada in ("", "   ", "\n\t "):
            with self.assertRaises(DataError):
                xmlutil.parse_document(entrada, "domain")

    def test_tipo_invalido(self) -> None:
        for entrada in (None, 7, b"<domain/>"):
            with self.assertRaises(DataError):
                xmlutil.parse_document(entrada, "domain")

    def test_malformado(self) -> None:
        with self.assertRaises(DataError):
            xmlutil.parse_document("<domain><devices></domain>", "domain")

    def test_doctype_recusado(self) -> None:
        payload = (
            "<!DOCTYPE domain [<!ENTITY x 'y'>]>"
            "<domain><devices/></domain>"
        )
        with self.assertRaises(DataError) as contexto:
            xmlutil.parse_document(payload, "domain")
        self.assertIn("DOCTYPE", str(contexto.exception))

    def test_entidade_declarada_recusada(self) -> None:
        with self.assertRaises(DataError):
            xmlutil.parse_document(
                "<!ENTITY a 'b'><domain><devices/></domain>", "domain"
            )

    def test_referencia_de_entidade_nao_predefinida(self) -> None:
        with self.assertRaises(DataError):
            xmlutil.parse_document(
                "<domain><name>&externa;</name><devices/></domain>", "domain"
            )

    def test_entidades_predefinidas_aceitas(self) -> None:
        raiz = xmlutil.parse_document(
            "<domain><name>a &amp; b &#65;</name><devices/></domain>", "domain"
        )
        self.assertEqual(
            xmlutil.text_of(xmlutil.exactly_one(raiz, "name", "t")), "a & b A"
        )

    def test_limite_de_tamanho(self) -> None:
        recheio = "<x/>" * 4
        gigante = "<domain>" + "<a>" + "b" * (xmlutil.MAX_XML_BYTES + 10) + "</a>" + recheio + "</domain>"
        with self.assertRaises(DataError) as contexto:
            xmlutil.parse_document(gigante, "domain")
        self.assertIn("limite", str(contexto.exception))

    def test_limite_de_profundidade(self) -> None:
        profundo = "<domain>" + "<a>" * 200 + "</a>" * 200 + "</domain>"
        with self.assertRaises(DataError) as contexto:
            xmlutil.parse_document(profundo, "domain")
        self.assertIn("profundidade", str(contexto.exception))

    def test_comentario_preservado(self) -> None:
        raiz = xmlutil.parse_document(
            "<domain><!-- nota do operador --><devices/></domain>", "domain"
        )
        # O comentário existe como filho, mas não conta como elemento.
        self.assertEqual(len(list(raiz)), 2)
        self.assertEqual(len(xmlutil.elements(raiz)), 1)
        self.assertIn("nota do operador", xmlutil.serialize(raiz))


class CardinalityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.raiz = xmlutil.parse_document(
            "<domain><a/><b/><b/></domain>", "domain"
        )

    def test_exactly_one_sucesso(self) -> None:
        self.assertEqual(xmlutil.exactly_one(self.raiz, "a", "ctx").tag, "a")

    def test_exactly_one_zero(self) -> None:
        with self.assertRaises(DataError) as contexto:
            xmlutil.exactly_one(self.raiz, "c", "ctx")
        self.assertIn("encontrado 0", str(contexto.exception))

    def test_exactly_one_multiplo(self) -> None:
        with self.assertRaises(DataError) as contexto:
            xmlutil.exactly_one(self.raiz, "b", "ctx")
        self.assertIn("encontrado 2", str(contexto.exception))

    def test_at_most_one(self) -> None:
        self.assertIsNone(xmlutil.at_most_one(self.raiz, "c", "ctx"))
        self.assertIsNotNone(xmlutil.at_most_one(self.raiz, "a", "ctx"))
        with self.assertRaises(DataError):
            xmlutil.at_most_one(self.raiz, "b", "ctx")

    def test_ensure_one_respeita_ancora(self) -> None:
        raiz = xmlutil.parse_document(
            "<domain><memory/><devices/></domain>", "domain"
        )
        criado = xmlutil.ensure_one(raiz, "cputune", ("devices",))
        nomes = [filho.tag for filho in xmlutil.elements(raiz)]
        self.assertEqual(nomes, ["memory", "cputune", "devices"])
        self.assertIs(criado, xmlutil.exactly_one(raiz, "cputune", "ctx"))

    def test_ensure_one_sem_ancora_vai_para_o_fim(self) -> None:
        raiz = xmlutil.parse_document("<domain><memory/></domain>", "domain")
        xmlutil.ensure_one(raiz, "cputune", ("devices",))
        self.assertEqual(
            [filho.tag for filho in xmlutil.elements(raiz)], ["memory", "cputune"]
        )

    def test_ensure_one_duplicado_falha(self) -> None:
        raiz = xmlutil.parse_document(
            "<domain><cputune/><cputune/></domain>", "domain"
        )
        with self.assertRaises(DataError):
            xmlutil.ensure_one(raiz, "cputune")


class CanonicalTests(unittest.TestCase):
    def test_ordem_de_atributo_nao_altera_semantica(self) -> None:
        esquerda = xmlutil.parse_document(
            "<domain><a x='1' y='2'/><devices/></domain>", "domain"
        )
        direita = xmlutil.parse_document(
            "<domain><a y='2' x='1'/><devices/></domain>", "domain"
        )
        self.assertEqual(xmlutil.canonical(esquerda), xmlutil.canonical(direita))
        self.assertEqual(
            xmlutil.fingerprint(esquerda), xmlutil.fingerprint(direita)
        )

    def test_ordem_de_elemento_altera_semantica(self) -> None:
        # No XML do libvirt a ordem de disk/hostdev/vcpupin é observável.
        esquerda = xmlutil.parse_document(
            "<domain><a/><b/><devices/></domain>", "domain"
        )
        direita = xmlutil.parse_document(
            "<domain><b/><a/><devices/></domain>", "domain"
        )
        self.assertNotEqual(xmlutil.canonical(esquerda), xmlutil.canonical(direita))

    def test_comentario_nao_altera_fingerprint(self) -> None:
        com = xmlutil.parse_document(
            "<domain><!-- x --><devices/></domain>", "domain"
        )
        sem = xmlutil.parse_document("<domain><devices/></domain>", "domain")
        self.assertEqual(xmlutil.fingerprint(com), xmlutil.fingerprint(sem))

    def test_valor_de_atributo_altera_fingerprint(self) -> None:
        esquerda = xmlutil.parse_document(
            "<domain><a x='1'/><devices/></domain>", "domain"
        )
        direita = xmlutil.parse_document(
            "<domain><a x='2'/><devices/></domain>", "domain"
        )
        self.assertNotEqual(
            xmlutil.fingerprint(esquerda), xmlutil.fingerprint(direita)
        )

    def test_fingerprint_determinista(self) -> None:
        raiz = xmlutil.parse_document(fx.domain(), "domain")
        self.assertEqual(xmlutil.fingerprint(raiz), xmlutil.fingerprint(raiz))
        self.assertRegex(xmlutil.fingerprint(raiz), r"^[0-9a-f]{64}$")

    def test_canonical_ignora_filhos_e_atributos_declarados(self) -> None:
        raiz = xmlutil.parse_document(
            "<domain><cpu mode='host-passthrough'><topology cores='2'/>"
            "<feature name='svm'/></cpu><devices/></domain>",
            "domain",
        )
        cpu = xmlutil.exactly_one(raiz, "cpu", "ctx")
        projecao = xmlutil.canonical(cpu, ("topology",), ("mode",))
        self.assertEqual(projecao[1], ())
        self.assertEqual([item[0] for item in projecao[3]], ["feature"])


class DifferenceTests(unittest.TestCase):
    def test_iguais_sem_diferenca(self) -> None:
        raiz = xmlutil.parse_document(fx.domain(), "domain")
        outro = xmlutil.parse_document(fx.domain(), "domain")
        self.assertEqual(xmlutil.describe_difference(raiz, outro), "")

    def test_atributo_divergente_nao_publica_valor(self) -> None:
        esquerda = xmlutil.parse_document(
            "<domain><a segredo='CANARIO-XYZ'/><devices/></domain>", "domain"
        )
        direita = xmlutil.parse_document(
            "<domain><a segredo='OUTRO-VALOR'/><devices/></domain>", "domain"
        )
        diferenca = xmlutil.describe_difference(esquerda, direita)
        self.assertIn("@segredo", diferenca)
        self.assertNotIn("CANARIO-XYZ", diferenca)
        self.assertNotIn("OUTRO-VALOR", diferenca)

    def test_cardinalidade_divergente(self) -> None:
        esquerda = xmlutil.parse_document("<domain><a/><a/></domain>", "domain")
        direita = xmlutil.parse_document("<domain><a/></domain>", "domain")
        self.assertIn("quantidade de filhos", xmlutil.describe_difference(esquerda, direita))

    def test_conjunto_de_atributos_divergente(self) -> None:
        esquerda = xmlutil.parse_document("<domain><a x='1'/></domain>", "domain")
        direita = xmlutil.parse_document("<domain><a/></domain>", "domain")
        self.assertIn("atributos", xmlutil.describe_difference(esquerda, direita))


class SerializeTests(unittest.TestCase):
    def test_declaracao_e_reanalise(self) -> None:
        raiz = xmlutil.parse_document(fx.domain(), "domain")
        texto = xmlutil.serialize(raiz)
        self.assertTrue(texto.startswith("<?xml version='1.0' encoding='UTF-8'?>"))
        self.assertTrue(texto.endswith("\n"))
        reanalisado = xmlutil.parse_document(texto, "domain")
        self.assertEqual(xmlutil.fingerprint(raiz), xmlutil.fingerprint(reanalisado))

    def test_serializacao_determinista(self) -> None:
        raiz = xmlutil.parse_document(fx.domain(), "domain")
        self.assertEqual(xmlutil.serialize(raiz), xmlutil.serialize(raiz))

    def test_unicode_preservado(self) -> None:
        raiz = xmlutil.parse_document(
            "<domain><description>instalação ção</description><devices/></domain>",
            "domain",
        )
        texto = xmlutil.serialize(raiz)
        self.assertIn("instalação ção", texto)


if __name__ == "__main__":
    unittest.main()
