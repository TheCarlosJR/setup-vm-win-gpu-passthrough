"""Testes do parser puro de busca de driver NVIDIA (etapa 15).

O módulo nunca acessa a rede: os documentos aqui são fixtures no formato
público do catálogo (`lookupValueSearch.aspx?TypeID=3`) e do
`DriverManualLookup`.
"""
import json
import unittest

from passthrough_core import nvidia_lookup
from passthrough_core.errors import DataError

CATALOGO = """<?xml version="1.0" encoding="utf-8"?>
<LookupValueSearch>
  <LookupValues>
    <LookupValue ParentID="127">
      <Name>GeForce RTX 3060</Name>
      <Value>995</Value>
    </LookupValue>
    <LookupValue ParentID="127">
      <Name>GeForce RTX 3060 Ti</Name>
      <Value>996</Value>
    </LookupValue>
    <LookupValue ParentID="100">
      <Name>GeForce GTX 1660</Name>
      <Value>888</Value>
    </LookupValue>
  </LookupValues>
</LookupValueSearch>
"""


def resposta_lookup(url: str, version: str = "572.83") -> str:
    return json.dumps(
        {
            "Success": 1,
            "IDS": [
                {
                    "downloadInfo": {
                        "DownloadURL": url,
                        "Version": version,
                        "Name": "GeForce Game Ready Driver",
                    }
                }
            ],
        }
    )


class NormalizeProductTests(unittest.TestCase):
    def test_remove_sufixos_de_variacao(self) -> None:
        self.assertEqual(
            nvidia_lookup.normalize_product("GeForce RTX 3060 Lite Hash Rate"),
            "geforce rtx 3060",
        )
        self.assertEqual(
            nvidia_lookup.normalize_product("GeForce RTX 3060 LHR"),
            "geforce rtx 3060",
        )

    def test_nao_remove_variante_de_modelo(self) -> None:
        self.assertEqual(
            nvidia_lookup.normalize_product("GeForce RTX 3060 Ti"),
            "geforce rtx 3060 ti",
        )


class ProductMatchTests(unittest.TestCase):
    def test_casa_por_igualdade_normalizada(self) -> None:
        dados = nvidia_lookup.product_match(
            {"xml": CATALOGO, "product": "GeForce RTX 3060 Lite Hash Rate"}
        )
        self.assertEqual(dados["psid"], "127")
        self.assertEqual(dados["pfid"], "995")
        self.assertEqual(dados["matched_name"], "GeForce RTX 3060")

    def test_nunca_casa_por_substring(self) -> None:
        dados = nvidia_lookup.product_match(
            {"xml": CATALOGO, "product": "GeForce RTX 3060 Ti"}
        )
        self.assertEqual(dados["pfid"], "996")

    def test_sem_correspondencia_e_erro(self) -> None:
        with self.assertRaises(DataError):
            nvidia_lookup.product_match(
                {"xml": CATALOGO, "product": "GeForce RTX 5090"}
            )

    def test_payload_sem_campos_e_erro(self) -> None:
        with self.assertRaises(DataError):
            nvidia_lookup.product_match({"xml": CATALOGO})
        with self.assertRaises(DataError):
            nvidia_lookup.product_match({"product": "GeForce RTX 3060"})


class DownloadInfoTests(unittest.TestCase):
    def test_extrai_url_versao_e_nome(self) -> None:
        dados = nvidia_lookup.download_info(
            {
                "json": resposta_lookup(
                    "https://us.download.nvidia.com/Windows/572.83/572.83-desktop-win10-win11-64bit-international-dch-whql.exe"
                )
            }
        )
        self.assertTrue(dados["url"].startswith("https://us.download.nvidia.com/"))
        self.assertEqual(dados["version"], "572.83")
        self.assertEqual(dados["name"], "GeForce Game Ready Driver")

    def test_normaliza_url_protocolo_relativo(self) -> None:
        dados = nvidia_lookup.download_info(
            {"json": resposta_lookup("//us.download.nvidia.com/Windows/x.exe")}
        )
        self.assertTrue(dados["url"].startswith("https://us.download.nvidia.com/"))

    def test_recusa_host_fora_da_nvidia(self) -> None:
        with self.assertRaises(DataError):
            nvidia_lookup.download_info(
                {"json": resposta_lookup("https://example.com/driver.exe")}
            )
        with self.assertRaises(DataError):
            nvidia_lookup.download_info(
                {
                    "json": resposta_lookup(
                        "https://download.nvidia.com.example.com/driver.exe"
                    )
                }
            )

    def test_recusa_http_simples(self) -> None:
        with self.assertRaises(DataError):
            nvidia_lookup.download_info(
                {"json": resposta_lookup("http://us.download.nvidia.com/x.exe")}
            )

    def test_recusa_versao_fora_do_formato(self) -> None:
        with self.assertRaises(DataError):
            nvidia_lookup.download_info(
                {
                    "json": resposta_lookup(
                        "https://us.download.nvidia.com/x.exe", version="beta!"
                    )
                }
            )

    def test_recusa_json_invalido_e_sem_sucesso(self) -> None:
        with self.assertRaises(DataError):
            nvidia_lookup.download_info({"json": "não é json"})
        with self.assertRaises(DataError):
            nvidia_lookup.download_info(
                {"json": json.dumps({"Success": 0, "IDS": []})}
            )


if __name__ == "__main__":
    unittest.main()
