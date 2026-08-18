"""Parser do JSON de `qemu-img info` e da backing chain (I3.5).

Módulo puro e fail-closed: recebe o texto JSON já capturado pelo Bash e nunca
executa `qemu-img`. Campo ausente, tipo errado, formato inesperado ou cadeia
com backing file produzem erro tipado; nada é presumido por omissão.

O único consumidor operacional hoje é o backup, que precisa provar que o disco
copiado é um QCOW2 independente. A validação de cadeia completa fica pronta
aqui para o restore/qualificação de I13.
"""
from __future__ import annotations

import json
from typing import Any, Mapping

from .errors import DataError, MissingInputError
from .protocol import safe_label

MAX_CHAIN_DEPTH = 16

_KNOWN_FORMATS = (
    "qcow2",
    "raw",
    "qed",
    "vmdk",
    "vdi",
    "vpc",
    "vhdx",
    "luks",
    "parallels",
)


def _reject_duplicate_keys(pairs: Any) -> dict:
    document: dict[str, Any] = {}
    for key, value in pairs:
        if key in document:
            raise DataError(
                "chave JSON duplicada na saída do qemu-img: %s" % safe_label(key)
            )
        document[key] = value
    return document


def _reject_constant(name: str) -> Any:
    raise DataError(
        "constante JSON não numérica na saída do qemu-img: %s" % safe_label(name)
    )


def _load(text: str) -> Any:
    if not isinstance(text, str):
        raise DataError("O campo json precisa ser texto.")
    if not text.strip():
        raise MissingInputError("A saída do qemu-img está vazia.")
    try:
        return json.loads(
            text,
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_constant,
        )
    except json.JSONDecodeError as error:
        raise DataError(
            "JSON do qemu-img inválido (linha %d, coluna %d)."
            % (error.lineno, error.colno)
        ) from error


def _require_string(entry: Mapping[str, Any], key: str, context: str) -> str:
    value = entry.get(key)
    if value is None:
        raise DataError("%s: campo obrigatório %s ausente." % (context, safe_label(key)))
    if not isinstance(value, str) or not value:
        raise DataError("%s: campo %s precisa ser texto." % (context, safe_label(key)))
    return value


def _optional_string(entry: Mapping[str, Any], key: str, context: str) -> str:
    value = entry.get(key)
    if value is None:
        return ""
    if not isinstance(value, str):
        raise DataError("%s: campo %s precisa ser texto." % (context, safe_label(key)))
    return value


def _optional_int(entry: Mapping[str, Any], key: str, context: str) -> int:
    value = entry.get(key)
    if value is None:
        return -1
    if isinstance(value, bool) or not isinstance(value, int):
        raise DataError("%s: campo %s precisa ser inteiro." % (context, safe_label(key)))
    if value < 0:
        raise DataError("%s: campo %s não pode ser negativo." % (context, safe_label(key)))
    return value


def _validate_format(value: str, context: str) -> str:
    if value not in _KNOWN_FORMATS:
        raise DataError(
            "%s: formato de imagem não reconhecido: %s" % (context, safe_label(value))
        )
    return value


def inspect_image(payload: Mapping[str, Any]) -> dict:
    """Valida a saída de `qemu-img info --output=json` de uma única imagem.

    Aceita tanto o objeto único quanto o array devolvido por `--backing-chain`,
    e nesse caso exige que a cadeia seja coerente com o elemento raiz.
    """
    document = _load(payload.get("json", ""))
    expected_format = payload.get("expect_format")
    if expected_format is not None and (
        not isinstance(expected_format, str) or not expected_format
    ):
        raise DataError("expect_format precisa ser texto quando informado.")
    # O canal de pares entrega tudo como texto, então `1`/`0` são aceitos ao
    # lado do booleano JSON. Nenhum outro literal passa.
    require_no_backing = payload.get("require_no_backing", False)
    if isinstance(require_no_backing, str):
        if require_no_backing not in ("0", "1"):
            raise DataError("require_no_backing precisa ser 1 ou 0.")
        require_no_backing = require_no_backing == "1"
    if not isinstance(require_no_backing, bool):
        raise DataError("require_no_backing precisa ser booleano.")

    if isinstance(document, list):
        entries = document
        if not entries:
            raise DataError("a cadeia devolvida pelo qemu-img está vazia.")
        if len(entries) > MAX_CHAIN_DEPTH:
            raise DataError(
                "a cadeia possui %d elementos, acima do limite de %d."
                % (len(entries), MAX_CHAIN_DEPTH)
            )
    elif isinstance(document, dict):
        entries = [document]
    else:
        raise DataError("a saída do qemu-img precisa ser objeto ou array JSON.")

    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            raise DataError("elemento %d da cadeia não é objeto JSON." % index)

    head = entries[0]
    context = "imagem principal"
    image_format = _validate_format(_require_string(head, "format", context), context)
    backing = _optional_string(head, "full-backing-filename", context) or _optional_string(
        head, "backing-filename", context
    )
    virtual_size = _optional_int(head, "virtual-size", context)
    actual_size = _optional_int(head, "actual-size", context)
    cluster_size = _optional_int(head, "cluster-size", context)

    if expected_format is not None and image_format != expected_format:
        raise DataError(
            "formato inesperado: %s" % safe_label(image_format)
        )
    if require_no_backing and backing:
        raise DataError("backing file detectado na imagem inspecionada")

    chain_length = len(entries)
    if chain_length > 1 and not backing:
        raise DataError(
            "a cadeia possui mais de um elemento, mas a imagem principal não "
            "declara backing file; saída incoerente"
        )
    for index, entry in enumerate(entries[1:], start=1):
        entry_context = "elemento %d da cadeia" % index
        _validate_format(_require_string(entry, "format", entry_context), entry_context)
        _require_string(entry, "filename", entry_context)

    return {
        "format": image_format,
        "has_backing": 1 if backing else 0,
        "backing_filename": backing,
        "chain_length": chain_length,
        "virtual_size": virtual_size,
        "actual_size": actual_size,
        "cluster_size": cluster_size,
    }
