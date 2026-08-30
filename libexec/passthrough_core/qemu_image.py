"""Parser do JSON de `qemu-img info` e da backing chain (I3.5).

Módulo puro e fail-closed: recebe o texto JSON já capturado pelo Bash e nunca
executa `qemu-img`. Campo ausente, tipo errado, formato inesperado ou cadeia
com backing file produzem erro tipado; nada é presumido por omissão.

O backup precisa provar que o disco copiado é um QCOW2 independente, e
REQ-WINDOWS-STATE precisa de uma identidade estável do QCOW2 para amarrar a
evidência durável de instalação ao disco certo. A validação de cadeia completa
fica pronta aqui para o restore/qualificação de I13.
"""
from __future__ import annotations

import hashlib
import json
import re
from typing import Any, Mapping

from .errors import DataError, MissingInputError
from .protocol import safe_label

MAX_CHAIN_DEPTH = 16

# --- Identidade estável do QCOW2 (REQ-WINDOWS-STATE) -------------------------
# O digest identifica o ARQUIVO, nunca o conteúdo: hashear um QCOW2 de dezenas
# ou centenas de GB a cada redesenho do menu seria inviável, e o conteúdo muda a
# cada boot do Windows sem que o disco tenha sido trocado.
#
# Os campos vêm todos capturados pelo Bash (`stat`, `qemu-img`): este módulo é
# puro, não executa nada e nunca abre caminho vindo de dado.
IDENTITY_VERSION = "passthrough-qcow2-identity/1"
IDENTITY_KEYS = ("path", "device", "inode", "birth", "format")
IDENTITY_KINDS = ("inode", "inode+birth")
IDENTITY_BIRTH_ABSENT = "-"
MAX_IDENTITY_PATH_BYTES = 4096
MAX_IDENTITY_DIGITS = 20

_DECIMAL_POSITIVE = re.compile(r"^[1-9][0-9]*$")
# Mesmo formato do `recorded-at` da metadata namespaced, para que operador e
# auditoria leiam uma data só em todo o projeto.
_BIRTH = re.compile(r"^[0-9]{8}-[0-9]{6}$")

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


def _identity_text(
    kind: str, path: str, device: str, inode: str, birth: str
) -> str:
    """Texto canônico versionado do qual sai o digest de identidade.

    Ordem fixa e prefixo de versão: mudar o formato muda o digest, e a versão
    no texto deixa a mudança auditável em vez de silenciosa.
    """
    return (
        "\n".join(
            (
                IDENTITY_VERSION,
                "kind=" + kind,
                "format=qcow2",
                "device=" + device,
                "inode=" + inode,
                "birth=" + birth,
                "path=" + path,
            )
        )
        + "\n"
    )


def _identity_digest(
    kind: str, path: str, device: str, inode: str, birth: str
) -> str:
    return hashlib.sha256(
        _identity_text(kind, path, device, inode, birth).encode("utf-8")
    ).hexdigest()


def _identity_required(payload: Mapping[str, Any], key: str) -> str:
    value = payload.get(key)
    if value is None:
        raise DataError(
            "identidade do QCOW2: campo obrigatório %s ausente." % safe_label(key)
        )
    if not isinstance(value, str):
        raise DataError(
            "identidade do QCOW2: campo %s precisa ser texto." % safe_label(key)
        )
    return value


def _identity_number(payload: Mapping[str, Any], key: str) -> str:
    value = _identity_required(payload, key)
    if len(value) > MAX_IDENTITY_DIGITS or _DECIMAL_POSITIVE.match(value) is None:
        raise DataError(
            "identidade do QCOW2: %s precisa ser decimal positivo sem zero à "
            "esquerda." % safe_label(key)
        )
    return value


def _identity_path(payload: Mapping[str, Any]) -> str:
    value = _identity_required(payload, "path")
    if any(ord(char) < 0x20 or ord(char) == 0x7F for char in value):
        raise DataError("identidade do QCOW2: path com caractere de controle.")
    if len(value.encode("utf-8")) > MAX_IDENTITY_PATH_BYTES:
        raise DataError("identidade do QCOW2: path acima do limite de tamanho.")
    if not value.startswith("/") or len(value) < 2:
        raise DataError("identidade do QCOW2: path precisa ser absoluto.")
    components = value.split("/")[1:]
    if any(component in ("", ".", "..") for component in components):
        raise DataError(
            "identidade do QCOW2: path precisa ser canônico, sem componente "
            "vazio, '.' ou '..'."
        )
    return value


def _identity_birth(payload: Mapping[str, Any]) -> str:
    """Canoniza o birth ausente como `-`.

    `stat -c '%w'` devolve `-` (e `%W` devolve `0`) em vários filesystems, o
    NTFS/fuseblk deste checkout incluído. Birth ausente é um fato normal do
    host, não erro de entrada: ele vira `-`, entra no texto canônico como `-` e
    o `identity_kind` passa a `inode`, de modo que a identidade continua
    reprodutível e a evidência já gravada continua conferindo.
    """
    value = payload.get("birth", "")
    if value is None:
        value = ""
    if not isinstance(value, str):
        raise DataError("identidade do QCOW2: birth precisa ser texto.")
    if value in ("", IDENTITY_BIRTH_ABSENT):
        return IDENTITY_BIRTH_ABSENT
    if _BIRTH.match(value) is None:
        raise DataError(
            "identidade do QCOW2: birth precisa usar AAAAMMDD-HHMMSS ou '-'."
        )
    return value


def image_identity(payload: Mapping[str, Any]) -> dict:
    """Identidade estável do arquivo QCOW2, sem ler um único byte da imagem.

    Devolve dois digests do mesmo arquivo:

    * `identity_digest` é o vínculo gravado na metadata. Quando o host informa
      o birth, ele entra no digest, e é justamente o birth que separa "o mesmo
      arquivo" de "outro arquivo que reaproveitou o inode" depois de um
      apagar/recriar;
    * `identity_digest_base` ignora o birth. Ele existe para que evidência
      gravada num filesystem SEM birth continue conferindo se o mesmo caminho
      passar a expor birth: nesse caso o digest gravado é o base, e a leitura
      compara contra os dois.

    Quando não há birth os dois digests são iguais por construção.
    """
    extra = set(payload) - set(IDENTITY_KEYS)
    if extra:
        raise DataError(
            "identidade do QCOW2: campo desconhecido: %s" % safe_label(sorted(extra)[0])
        )
    image_format = _identity_required(payload, "format")
    if image_format != "qcow2":
        raise DataError(
            "identidade de imagem só é modelada para qcow2; recebido: %s"
            % safe_label(image_format)
        )
    path = _identity_path(payload)
    device = _identity_number(payload, "device")
    inode = _identity_number(payload, "inode")
    birth = _identity_birth(payload)
    kind = "inode" if birth == IDENTITY_BIRTH_ABSENT else "inode+birth"
    return {
        "identity_digest": _identity_digest(kind, path, device, inode, birth),
        "identity_digest_base": _identity_digest(
            "inode", path, device, inode, IDENTITY_BIRTH_ABSENT
        ),
        "identity_kind": kind,
        "identity_birth": birth,
    }
