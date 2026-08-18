"""Protocolo versionado entre Bash e Python (seção 3.8).

Módulo puro: não abre arquivos, não executa comandos, não conhece o shell e
não mantém estado global mutável. Ele define:

* o envelope fechado de requisição e de resposta;
* a serialização JSON determinística (UTF-8, chaves ordenadas, sem espaços,
  sem NaN/Infinity, com newline final);
* o canal alternativo de pares `chave\\0valor\\0`, usado quando o Bash precisa
  carregar valores com `printf -v` sem nunca aplicar regex sobre JSON;
* a validação de identificadores escalares que podem trafegar em `argv`;
* o rótulo seguro de diagnóstico, que impede impressão de valor bruto.

Nada aqui conhece transporte: quem lê stdin ou o arquivo controlado é a CLI.
"""
from __future__ import annotations

import json
import re
from typing import Any, Iterable, Mapping

from .errors import DataError, InternalError, MissingInputError, UsageError

# Versão do próprio core, independente da versão do protocolo.
CORE_VERSION = "0.1.0"
PROTOCOL_VERSION = 1

# Limites explícitos: payload maior que isso é recusado com erro tipado, nunca
# truncado em silêncio. Os dados reais do projeto (XML de domínio, JSON de
# qemu-img, inventário, snapshots de rede) ficam ordens de magnitude abaixo.
MAX_PAYLOAD_BYTES = 4 * 1024 * 1024
MAX_PAIR_VALUE_BYTES = 64 * 1024

REQUEST_KEYS = ("payload", "protocol_version")
RESPONSE_KEYS = ("core_version", "data", "protocol_version", "subcommand")

_SCALAR_IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
_PAIR_KEY = re.compile(r"^[A-Z][A-Z0-9_]{0,63}$")
# Chave do canal de entrada por pares: minúscula, para nunca colidir com a
# projeção de resposta, e sem ponto/barra, para não sugerir caminho.
_REQUEST_PAIR_KEY = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
MAX_REQUEST_PAIRS = 256
# Rótulo conservador: sem barra, para que caminho local não vaze em stderr.
_SAFE_LABEL = re.compile(r"^[A-Za-z0-9_.:=-]{1,64}$")

REDACTED_LABEL = "<valor redigido>"


def safe_label(value: Any) -> str:
    """Devolve rótulo publicável para diagnóstico humano.

    Valor que não caiba no formato conservador é substituído por um marcador.
    Assim uma mensagem de erro nunca imprime conteúdo de configuração, XML,
    caminho local ou material sensível vindo da entrada (seção 3.9).
    """
    if isinstance(value, str) and _SAFE_LABEL.match(value):
        return value
    return REDACTED_LABEL


def validate_scalar_identifier(value: Any, field: str) -> str:
    """Valida identificador escalar aceito em `argv`."""
    if not isinstance(value, str) or not _SCALAR_IDENTIFIER.match(value):
        raise UsageError(
            "Identificador escalar inválido em %s: %s."
            % (safe_label(field), safe_label(value))
        )
    return value


def serialize(document: Any) -> bytes:
    """Serializa de forma determinística em UTF-8 com newline final."""
    try:
        text = json.dumps(
            document,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        )
    except (TypeError, ValueError) as error:
        raise InternalError(
            "Resposta do core não é serializável de forma determinística."
        ) from error
    return text.encode("utf-8") + b"\n"


def build_response(subcommand: str, data: Mapping[str, Any]) -> dict:
    """Monta o envelope fechado de resposta."""
    validate_scalar_identifier(subcommand, "subcomando")
    if not isinstance(data, Mapping):
        raise InternalError("Dados de resposta precisam ser um mapeamento.")
    for key in data:
        if not isinstance(key, str) or not key:
            raise InternalError("Chave de dados de resposta inválida.")
    return {
        "core_version": CORE_VERSION,
        "data": dict(data),
        "protocol_version": PROTOCOL_VERSION,
        "subcommand": subcommand,
    }


def validate_response(response: Mapping[str, Any]) -> None:
    """Recusa resposta fora do schema fechado antes de qualquer emissão."""
    if not isinstance(response, Mapping):
        raise InternalError("Resposta do core precisa ser um mapeamento.")
    if tuple(sorted(response)) != RESPONSE_KEYS:
        raise InternalError("Resposta do core fora do schema fechado.")
    if response["protocol_version"] != PROTOCOL_VERSION:
        raise InternalError("Resposta do core com versão de protocolo divergente.")
    if response["core_version"] != CORE_VERSION:
        raise InternalError("Resposta do core com versão de core divergente.")
    if not isinstance(response["data"], Mapping):
        raise InternalError("Campo data da resposta precisa ser um mapeamento.")


def encode_response(subcommand: str, data: Mapping[str, Any]) -> bytes:
    """Monta, valida e serializa a resposta em JSON determinístico."""
    response = build_response(subcommand, data)
    validate_response(response)
    return serialize(response)


def _reject_json_constant(name: str) -> Any:
    raise DataError(
        "Constante JSON não numérica recusada no payload: %s." % safe_label(name)
    )


def _reject_duplicate_keys(pairs: Iterable[tuple[str, Any]]) -> dict:
    document: dict[str, Any] = {}
    for key, value in pairs:
        if key in document:
            raise DataError(
                "Chave JSON duplicada no payload: %s." % safe_label(key)
            )
        document[key] = value
    return document


def decode_request(raw: Any) -> dict:
    """Valida o envelope fechado de requisição e devolve o payload interno.

    Toda entrada é tratada como não confiável: tamanho, codificação, sintaxe,
    duplicidade de chave, constantes não numéricas, versão de protocolo e
    schema são verificados antes de qualquer uso do conteúdo.
    """
    if not isinstance(raw, (bytes, bytearray)):
        raise InternalError("O transporte precisa entregar bytes ao protocolo.")
    if len(raw) == 0:
        raise MissingInputError(
            "Payload ausente: envie o envelope JSON por stdin ou por arquivo "
            "controlado."
        )
    if len(raw) > MAX_PAYLOAD_BYTES:
        raise DataError(
            "Payload maior que o limite de %d bytes." % MAX_PAYLOAD_BYTES
        )
    try:
        text = bytes(raw).decode("utf-8")
    except UnicodeDecodeError as error:
        raise DataError("Payload não está em UTF-8 válido.") from error
    if not text.strip():
        raise MissingInputError("Payload contém apenas espaços em branco.")
    try:
        document = json.loads(
            text,
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_json_constant,
        )
    except json.JSONDecodeError as error:
        raise DataError(
            "Payload não é JSON válido (linha %d, coluna %d)."
            % (error.lineno, error.colno)
        ) from error
    if not isinstance(document, dict):
        raise DataError("O envelope de requisição precisa ser um objeto JSON.")
    if tuple(sorted(document)) != REQUEST_KEYS:
        raise DataError(
            "Envelope de requisição fora do schema fechado; esperado exatamente "
            "as chaves protocol_version e payload."
        )
    version = document["protocol_version"]
    if isinstance(version, bool) or not isinstance(version, int):
        raise DataError("protocol_version precisa ser inteiro.")
    if version != PROTOCOL_VERSION:
        raise DataError(
            "Versão de protocolo não suportada; este core fala a versão %d."
            % PROTOCOL_VERSION
        )
    payload = document["payload"]
    if not isinstance(payload, dict):
        raise DataError("O campo payload precisa ser um objeto JSON.")
    return payload


def decode_request_pairs(raw: Any) -> dict:
    """Decodifica o canal de entrada `chave\\0valor\\0` em um payload de texto.

    Existe para que o Bash nunca precise construir JSON: montar um envelope à
    mão exigiria escape manual de barra invertida, aspas e controles, e um erro
    nesse escape viraria payload malformado ou, pior, campo interpretado de
    forma diferente da pretendida. Com pares NUL o Bash só usa
    `printf '%s\\0'` e o schema fechado continua sendo validado aqui.

    Todos os valores chegam como texto; a coerção para inteiro, booleano ou
    lista é responsabilidade do módulo de domínio, que conhece o schema.
    """
    if not isinstance(raw, (bytes, bytearray)):
        raise InternalError("O transporte precisa entregar bytes ao protocolo.")
    if len(raw) == 0:
        raise MissingInputError(
            "Payload ausente: envie os pares chave/valor por stdin ou por "
            "arquivo controlado."
        )
    if len(raw) > MAX_PAYLOAD_BYTES:
        raise DataError(
            "Payload maior que o limite de %d bytes." % MAX_PAYLOAD_BYTES
        )
    blocks = bytes(raw).split(b"\x00")
    # Um fluxo bem formado termina em NUL, então o último bloco é vazio.
    if blocks and blocks[-1] == b"":
        blocks.pop()
    else:
        raise DataError("O canal de pares de entrada precisa terminar em NUL.")
    if len(blocks) % 2 != 0:
        raise DataError(
            "O canal de pares de entrada tem paridade inválida (%d campos)."
            % len(blocks)
        )
    if len(blocks) // 2 > MAX_REQUEST_PAIRS:
        raise DataError(
            "O canal de pares de entrada excede %d pares." % MAX_REQUEST_PAIRS
        )
    payload: dict[str, str] = {}
    for index in range(0, len(blocks), 2):
        try:
            key = blocks[index].decode("utf-8")
            value = blocks[index + 1].decode("utf-8")
        except UnicodeDecodeError as error:
            raise DataError(
                "O canal de pares de entrada não está em UTF-8 válido."
            ) from error
        if _REQUEST_PAIR_KEY.match(key) is None:
            raise DataError(
                "Chave inválida no canal de pares de entrada: %s" % safe_label(key)
            )
        if key in payload:
            raise DataError(
                "Chave duplicada no canal de pares de entrada: %s" % safe_label(key)
            )
        payload[key] = value
    if not payload:
        raise MissingInputError("O canal de pares de entrada não trouxe campo algum.")
    return payload


def _pair_text(value: Any) -> str:
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return value
    raise InternalError(
        "O canal de pares aceita somente escalares (texto, inteiro, booleano)."
    )


def encode_pairs(mapping: Mapping[str, Any]) -> bytes:
    """Codifica pares `chave\\0valor\\0` em ordem determinística."""
    if not isinstance(mapping, Mapping):
        raise InternalError("O canal de pares exige um mapeamento.")
    blocks = []
    for key in sorted(mapping):
        if not isinstance(key, str) or not _PAIR_KEY.match(key):
            raise InternalError(
                "Chave inválida no canal de pares: %s." % safe_label(key)
            )
        text = _pair_text(mapping[key])
        encoded = text.encode("utf-8")
        if b"\x00" in encoded:
            raise InternalError("Valor com NUL não pode trafegar no canal de pares.")
        if len(encoded) > MAX_PAIR_VALUE_BYTES:
            raise InternalError(
                "Valor maior que o limite de %d bytes no canal de pares."
                % MAX_PAIR_VALUE_BYTES
            )
        blocks.append(key.encode("ascii") + b"\x00" + encoded + b"\x00")
    return b"".join(blocks)


def pairs_from_response(response: Mapping[str, Any]) -> bytes:
    """Projeta o envelope de resposta no canal de pares.

    As chaves do envelope viram `CORE_VERSION`, `PROTOCOL_VERSION` e
    `SUBCOMMAND`; cada chave de `data` vira seu nome em maiúsculas. Colisão ou
    valor não escalar é erro interno, nunca projeção parcial.
    """
    validate_response(response)
    flat: dict[str, Any] = {
        "CORE_VERSION": response["core_version"],
        "PROTOCOL_VERSION": response["protocol_version"],
        "SUBCOMMAND": response["subcommand"],
    }
    for key, value in response["data"].items():
        pair_key = key.upper()
        if not _PAIR_KEY.match(pair_key):
            raise InternalError(
                "Chave de dados não projetável no canal de pares: %s."
                % safe_label(key)
            )
        if pair_key in flat:
            raise InternalError(
                "Colisão de chave no canal de pares: %s." % safe_label(pair_key)
            )
        flat[pair_key] = value
    return encode_pairs(flat)
