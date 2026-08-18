"""Leitura, cardinalidade e canonicalização de XML (seção 3.5).

Módulo puro: recebe texto, devolve árvore ou erro tipado. Não abre arquivo,
não executa comando, não conhece libvirt e não mantém estado global mutável.

Três invariantes do plano vivem aqui:

* nenhuma seleção implícita do "primeiro" nó: quem espera exatamente um nó
  chama `exactly_one` e recebe erro tipado quando a cardinalidade é zero ou
  maior que um;
* conteúdo não gerenciado é preservado: a árvore mantém comentários e
  instruções de processamento, e a serialização é determinística;
* entrada é sempre não confiável: DOCTYPE, entidade e namespace externo são
  recusados antes de qualquer análise, então nem XXE nem expansão exponencial
  de entidade têm superfície.
"""
from __future__ import annotations

import hashlib
import re
import xml.etree.ElementTree as ET
from typing import Any, Iterable

from .errors import DataError

# Declaração de tipo de documento e entidades são recusadas por completo: o
# projeto só consome XML gerado pelo libvirt/qemu, que nunca as usa.
_DOCTYPE = re.compile(r"<!DOCTYPE", re.IGNORECASE)
_ENTITY_DECL = re.compile(r"<!ENTITY", re.IGNORECASE)
_ENTITY_REF = re.compile(r"&(?!(?:amp|lt|gt|quot|apos|#[0-9]+|#x[0-9A-Fa-f]+);)")

MAX_XML_BYTES = 4 * 1024 * 1024
MAX_XML_DEPTH = 64


def parse_document(text: Any, expected_root: str, label: str = "XML") -> ET.Element:
    """Analisa o documento e devolve a raiz, exigindo o nome de raiz esperado.

    `label` só aparece no diagnóstico e é sempre um rótulo do próprio código
    (por exemplo `XML inativo`), nunca um valor vindo da entrada.
    """
    if not isinstance(text, str):
        raise DataError("O documento %s precisa chegar como texto." % label)
    if not text.strip():
        raise DataError("O documento %s está vazio." % label)
    encoded = text.encode("utf-8", "surrogatepass")
    if len(encoded) > MAX_XML_BYTES:
        raise DataError(
            "O documento %s excede o limite de %d bytes." % (label, MAX_XML_BYTES)
        )
    if _DOCTYPE.search(text) or _ENTITY_DECL.search(text):
        raise DataError(
            "O documento %s declara DOCTYPE/ENTITY; recusado por política." % label
        )
    if _ENTITY_REF.search(text):
        raise DataError(
            "O documento %s usa referência de entidade não predefinida." % label
        )
    parser = ET.XMLParser(
        target=ET.TreeBuilder(insert_comments=True, insert_pis=True)
    )
    try:
        parser.feed(text)
        root = parser.close()
    except ET.ParseError as error:
        raise DataError(
            "O documento %s não é XML bem formado (linha %d, coluna %d)."
            % (label, error.position[0], error.position[1])
        ) from error
    except (ValueError, TypeError) as error:
        raise DataError("O documento %s não pôde ser analisado." % label) from error
    if root is None:
        raise DataError("O documento %s não produziu elemento raiz." % label)
    if root.tag != expected_root:
        raise DataError(
            "A raiz do documento %s não é <%s>." % (label, expected_root)
        )
    _reject_deep_tree(root, label)
    return root


def _reject_deep_tree(root: ET.Element, label: str) -> None:
    """Recusa profundidade absurda antes de qualquer travessia recursiva."""
    pending = [(root, 1)]
    while pending:
        element, depth = pending.pop()
        if depth > MAX_XML_DEPTH:
            raise DataError(
                "O documento %s excede a profundidade máxima de %d níveis."
                % (label, MAX_XML_DEPTH)
            )
        for child in element:
            if isinstance(child.tag, str):
                pending.append((child, depth + 1))


def elements(parent: ET.Element) -> list[ET.Element]:
    """Filhos que são elementos reais (comentário e PI ficam de fora)."""
    return [child for child in list(parent) if isinstance(child.tag, str)]


def direct(parent: ET.Element, name: str) -> list[ET.Element]:
    """Filhos diretos com o nome dado, sem descer na árvore."""
    return [child for child in list(parent) if child.tag == name]


def exactly_one(parent: ET.Element, name: str, context: str) -> ET.Element:
    """Devolve o único filho com esse nome ou falha por cardinalidade."""
    found = direct(parent, name)
    if len(found) != 1:
        raise DataError(
            "%s: esperado exatamente um <%s>; encontrado %d."
            % (context, name, len(found))
        )
    return found[0]


def at_most_one(parent: ET.Element, name: str, context: str) -> ET.Element | None:
    """Devolve zero ou um filho com esse nome; dois ou mais é erro tipado."""
    found = direct(parent, name)
    if len(found) > 1:
        raise DataError(
            "%s: <%s> aparece %d vezes; esperado no máximo uma."
            % (context, name, len(found))
        )
    return found[0] if found else None


def ensure_one(
    parent: ET.Element, name: str, anchors: Iterable[str] = ()
) -> ET.Element:
    """Devolve o filho único ou cria um novo antes da primeira âncora.

    Preserva a ordem exigida pelo schema do libvirt sem reordenar nada que já
    exista: o elemento novo entra imediatamente antes do primeiro filho cujo
    nome esteja em `anchors`; sem âncora encontrada, vai para o fim.
    """
    found = direct(parent, name)
    if len(found) > 1:
        raise DataError("<%s> duplicado no domínio; revisão manual necessária." % name)
    if found:
        return found[0]
    element = ET.Element(name)
    anchor_names = tuple(anchors)
    for index, child in enumerate(list(parent)):
        if child.tag in anchor_names:
            parent.insert(index, element)
            return element
    parent.append(element)
    return element


def text_of(element: ET.Element | None) -> str:
    """Texto normalizado de um elemento, ou vazio quando ausente."""
    if element is None:
        return ""
    return (element.text or "").strip()


def attribute(element: ET.Element | None, name: str) -> str:
    """Atributo de um elemento, ou vazio quando o elemento/atributo falta."""
    if element is None:
        return ""
    return element.get(name, "") or ""


def canonical(
    element: ET.Element,
    ignored_children: Iterable[str] = (),
    ignored_attributes: Iterable[str] = (),
) -> tuple:
    """Projeção canônica comparável de um elemento e seus descendentes.

    A projeção ignora comentários, PIs e espaço em branco irrelevante, ordena
    atributos e preserva a ordem dos elementos: no XML do libvirt a ordem de
    `vcpupin`, `disk` e `hostdev` é observável, então reordenar não pode ser
    tratado como equivalência.
    """
    ignored_child_names = tuple(ignored_children)
    ignored_attribute_names = tuple(ignored_attributes)
    children = tuple(
        canonical(child)
        for child in list(element)
        if isinstance(child.tag, str) and child.tag not in ignored_child_names
    )
    attributes = tuple(
        sorted(
            (key, value)
            for key, value in element.attrib.items()
            if key not in ignored_attribute_names
        )
    )
    tail_free_text = (element.text or "").strip()
    return element.tag, attributes, tail_free_text, children


def canonical_text(projection: Any) -> str:
    """Serializa uma projeção canônica de forma determinística e estável."""
    if isinstance(projection, tuple):
        return "(" + ",".join(canonical_text(item) for item in projection) + ")"
    if projection is None:
        return "~"
    return repr(str(projection))


def fingerprint(element: ET.Element) -> str:
    """Digest determinístico da semântica canônica do elemento.

    Serve de fingerprint para detectar mudança concorrente (TOCTOU) sem
    depender de formatação, espaço em branco ou ordem de atributos. Não é
    material sensível: é derivado de conteúdo já conhecido pelo chamador.
    """
    digest = hashlib.sha256()
    digest.update(canonical_text(canonical(element)).encode("utf-8"))
    return digest.hexdigest()


def serialize(root: ET.Element) -> str:
    """Serializa a árvore no formato aceito pelo `virsh define`.

    Mantém o mesmo contrato dos helpers substituídos: declaração XML presente,
    UTF-8 e elementos vazios em forma curta.
    """
    try:
        body = ET.tostring(
            root, encoding="unicode", short_empty_elements=True
        )
    except (TypeError, ValueError) as error:
        raise DataError("Não foi possível serializar o XML candidato.") from error
    return "<?xml version='1.0' encoding='UTF-8'?>\n" + body + "\n"


def describe_difference(left: ET.Element, right: ET.Element) -> str:
    """Primeira divergência semântica entre duas árvores, em caminho legível.

    Só devolve nomes de elemento, nomes de atributo e cardinalidade: nunca o
    valor divergente, que pode ser um `LOCAL_IDENTIFIER` (seção 3.9).
    """
    pending = [(left, right, "/" + left.tag)]
    while pending:
        node_left, node_right, path = pending.pop(0)
        if node_left.tag != node_right.tag:
            return "%s: nome do elemento divergiu" % path
        keys_left = sorted(node_left.attrib)
        keys_right = sorted(node_right.attrib)
        if keys_left != keys_right:
            missing = sorted(set(keys_left) ^ set(keys_right))
            return "%s: conjunto de atributos divergiu (%s)" % (
                path,
                ", ".join(missing),
            )
        for key in keys_left:
            if node_left.attrib[key] != node_right.attrib[key]:
                return "%s/@%s: valor divergiu" % (path, key)
        if (node_left.text or "").strip() != (node_right.text or "").strip():
            return "%s: texto divergiu" % path
        children_left = elements(node_left)
        children_right = elements(node_right)
        if len(children_left) != len(children_right):
            return "%s: quantidade de filhos divergiu (%d contra %d)" % (
                path,
                len(children_left),
                len(children_right),
            )
        for index, (child_left, child_right) in enumerate(
            zip(children_left, children_right)
        ):
            pending.append(
                (child_left, child_right, "%s/%s[%d]" % (path, child_left.tag, index))
            )
    return ""
