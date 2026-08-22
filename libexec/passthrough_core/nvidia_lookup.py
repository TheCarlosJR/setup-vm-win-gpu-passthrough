"""Interpretação pura das respostas públicas de busca de driver da NVIDIA.

Módulo puro. O core nunca acessa a rede: o Bash baixa os dois documentos do
serviço público da NVIDIA (o XML de famílias de produto de
`lookupValueSearch.aspx?TypeID=3` e o JSON de `DriverManualLookup`) e os
entrega por payload. Aqui apenas se interpreta, valida e devolve escalares.

Duas regras estruturam as funções daqui:

* correspondência é por igualdade do nome normalizado, nunca por substring:
  "GeForce RTX 3060" não pode casar com "GeForce RTX 3060 Ti";
* a URL de download só é aceita em HTTPS e em host de download da própria
  NVIDIA; qualquer outra origem é erro tipado, nunca um aviso.
"""
from __future__ import annotations

import json
import re
from typing import Any, Mapping

from . import xmlutil
from .errors import DataError
from .protocol import safe_label

LOOKUP_ROOT = "LookupValueSearch"

# Sufixos de variação comercial que não mudam a família de driver. A remoção
# vale para os dois lados da comparação (nome consultado e nome do catálogo).
_VARIANT_SUFFIXES = ("lite hash rate", "lhr", "oem", "rev. a1", "rev. 2.0")

# Hosts de download aceitos. O catálogo da NVIDIA publica URLs absolutas em
# us./international.download.nvidia.com e variantes protocolo-relativas.
# A fronteira de I2 proíbe importar urllib no core, então a URL é validada por
# uma gramática fechada: esquema https, host imediato (sem userinfo nem porta)
# e caminho sem espaço ou controle.
_DOWNLOAD_HOST = re.compile(r"^([a-z0-9-]+\.)?download\.nvidia\.com$")
_URL_HTTPS = re.compile(r"^https://([a-z0-9-]+(?:\.[a-z0-9-]+)+)(/\S*)?$")

_VERSION = re.compile(r"^[0-9]+(\.[0-9]+){1,3}$")
_NUMERIC_ID = re.compile(r"^[0-9]{1,6}$")


def _payload_text(payload: Mapping[str, Any], key: str) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or not value.strip():
        raise DataError(
            "Campo obrigatório ausente ou vazio no payload: %s." % safe_label(key)
        )
    return value


def normalize_product(name: str) -> str:
    """Normaliza um nome de produto para comparação por igualdade.

    Colapsa espaços, remove parênteses de brinde comercial e descarta os
    sufixos de variação listados em `_VARIANT_SUFFIXES`. O resultado é sempre
    minúsculo; a exibição usa o nome original do catálogo.
    """
    text = re.sub(r"\([^)]*\)", " ", name)
    text = re.sub(r"\s+", " ", text).strip().lower()
    changed = True
    while changed:
        changed = False
        for suffix in _VARIANT_SUFFIXES:
            if text.endswith(" " + suffix):
                text = text[: -len(suffix) - 1].rstrip()
                changed = True
    return text


def product_match(payload: Mapping[str, Any]) -> dict:
    """Resolve psid/pfid da família de produto pelo nome normalizado.

    Payload: `xml` (documento de lookupValueSearch TypeID=3) e `product`
    (nome de mercado, por exemplo "GeForce RTX 3060 Lite Hash Rate").
    Zero correspondências é erro; mais de uma só é aceita quando todas apontam
    para o mesmo par psid/pfid.
    """
    document = _payload_text(payload, "xml")
    product = _payload_text(payload, "product")
    target = normalize_product(product)
    if not target:
        raise DataError("Nome de produto vazio após a normalização.")
    root = xmlutil.parse_document(
        document, LOOKUP_ROOT, "catálogo de famílias de produto NVIDIA"
    )
    matches: list[tuple[str, str, str]] = []
    for value in root.iter("LookupValue"):
        name = xmlutil.text_of(xmlutil.at_most_one(value, "Name", "LookupValue"))
        pfid = xmlutil.text_of(xmlutil.at_most_one(value, "Value", "LookupValue"))
        psid = xmlutil.attribute(value, "ParentID").strip()
        if not name or not pfid:
            continue
        if normalize_product(name) != target:
            continue
        pfid = pfid.strip()
        if not _NUMERIC_ID.match(pfid) or not _NUMERIC_ID.match(psid):
            raise DataError(
                "Identificadores não numéricos no catálogo NVIDIA para a "
                "família correspondente."
            )
        matches.append((psid, pfid, name))
    if not matches:
        raise DataError(
            "Nenhuma família de produto NVIDIA corresponde a %s."
            % safe_label(product)
        )
    pairs = {(psid, pfid) for psid, pfid, _ in matches}
    if len(pairs) > 1:
        raise DataError(
            "O catálogo NVIDIA tem famílias divergentes para %s; a escolha "
            "automática seria ambígua." % safe_label(product)
        )
    psid, pfid, matched_name = matches[0]
    return {"psid": psid, "pfid": pfid, "matched_name": matched_name}


def _mapping_field(container: Mapping[str, Any], key: str, context: str) -> Any:
    if not isinstance(container, Mapping) or key not in container:
        raise DataError(
            "Resposta de driver NVIDIA sem o campo %s em %s."
            % (safe_label(key), safe_label(context))
        )
    return container[key]


def download_info(payload: Mapping[str, Any]) -> dict:
    """Extrai URL, versão e nome do driver do JSON de DriverManualLookup.

    Payload: `json` (texto bruto da resposta). Devolve a URL já normalizada
    para HTTPS absoluto e recusa qualquer host fora de download.nvidia.com.
    """
    text = _payload_text(payload, "json")
    try:
        data = json.loads(text)
    except ValueError as error:
        raise DataError(
            "Resposta de driver NVIDIA não é JSON válido (%s)."
            % type(error).__name__
        ) from error
    if not isinstance(data, Mapping):
        raise DataError("Resposta de driver NVIDIA não é um objeto JSON.")
    success = data.get("Success")
    if str(success) != "1":
        raise DataError(
            "O serviço de driver NVIDIA não reportou sucesso na consulta."
        )
    ids = _mapping_field(data, "IDS", "resposta")
    if not isinstance(ids, list) or not ids:
        raise DataError("O serviço de driver NVIDIA devolveu lista vazia.")
    info = _mapping_field(ids[0], "downloadInfo", "IDS[0]")
    url = _mapping_field(info, "DownloadURL", "downloadInfo")
    version = _mapping_field(info, "Version", "downloadInfo")
    name = info.get("Name") if isinstance(info, Mapping) else ""
    if not isinstance(url, str) or not url.strip():
        raise DataError("URL de download NVIDIA ausente ou vazia.")
    url = url.strip()
    if url.startswith("//"):
        url = "https:" + url
    shape = _URL_HTTPS.match(url)
    if shape is None:
        raise DataError(
            "URL de download NVIDIA fora do formato https://host/caminho foi "
            "recusada."
        )
    host = shape.group(1).lower()
    if not _DOWNLOAD_HOST.match(host):
        raise DataError(
            "Host de download fora de download.nvidia.com foi recusado: %s."
            % safe_label(host)
        )
    if not isinstance(version, str) or not _VERSION.match(version.strip()):
        raise DataError("Versão de driver NVIDIA fora do formato numérico.")
    if not isinstance(name, str):
        name = ""
    return {"url": url, "version": version.strip(), "name": name.strip()}
