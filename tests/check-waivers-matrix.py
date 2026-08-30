#!/usr/bin/env python3
"""Gate de schema da matriz de política de dispensas (REQ-WAIVERS, I9.10).

A matriz `lib/policy/waivers.tsv` é o único lugar do projeto que declara qual
pré-requisito cada dispensa exclui. O leitor de runtime (`lib/shell/waivers.sh`)
é fail-closed mas propositalmente burro: ele recusa linha malformada e não sabe
nada sobre o schema de configuração nem sobre quais etapas existem. A prova de
COERÊNCIA mora aqui, no gate, onde é barato cruzar a matriz com o schema do
core e com a árvore de etapas.

O que este checker recusa, e por quê cada item importa:

  * cobertura incompleta: uma chave `*_DISPENSADO` que existe no schema e não
    aparece na matriz é uma dispensa sem política declarada, ou seja,
    exatamente o estado que o requisito manda eliminar;
  * etapa inexistente: a matriz autorizaria excluir um pré-requisito de um
    arquivo que ninguém executa, e o erro só apareceria quando alguém
    renomeasse a etapa;
  * flag fora do schema: a matriz poderia dispensar por uma chave que
    `carregar_conf` nunca publica, e a dispensa seria silenciosamente inerte;
  * ordem C e duplicidade: a matriz é dado versionado e diffável; duas linhas
    para o mesmo par (etapa, flag) tornariam a resolução dependente da ordem
    de leitura.
"""
from __future__ import annotations

import argparse
import ast
import re
import sys
from pathlib import Path

SCHEMA_VERSION = 1
CAMPOS = ("etapa", "flag", "tipo", "prereq_excluido", "simbolo_ui", "conflito")
TIPOS = {"escolha-de-modo"}
SIMBOLOS = {"disp", "nenhum"}
CONFLITOS = {"fatal", "aviso"}
ETAPA_RE = re.compile(r"^[0-9]{2}-[a-z0-9-]+\.sh$")
FLAG_RE = re.compile(r"^[A-Z][A-Z0-9_]*_DISPENSADO$")
PREREQ_RE = re.compile(r"^[a-z][a-z0-9-]*$")


class Reprovado(Exception):
    pass


def chaves_de_dispensa(raiz: Path) -> set[str]:
    """Extrai as chaves *_DISPENSADO do SCHEMA do core sem importar o package.

    Importar `config.py` puxaria o pacote inteiro para dentro do gate; ler a
    AST mantém o checker independente e continua falhando se a chave sumir do
    schema. A leitura precisa ser do nó `SCHEMA` especificamente: um regex
    sobre o arquivo inteiro também casaria `DEPRECATED_KEYS`, e as duas chaves
    removidas em I4 (`AIRLOCK_DISPENSADO`, `BACKUP_DISPENSADO`) voltariam a ser
    exigidas na matriz, ressuscitando por engano a política que a fase anterior
    removeu de propósito.
    """
    fonte = (raiz / "libexec" / "passthrough_core" / "config.py").read_text(encoding="utf-8")
    arvore = ast.parse(fonte)
    for no in arvore.body:
        alvos = []
        if isinstance(no, ast.Assign):
            alvos = no.targets
            valor = no.value
        elif isinstance(no, ast.AnnAssign):
            alvos = [no.target]
            valor = no.value
        else:
            continue
        if not any(isinstance(a, ast.Name) and a.id == "SCHEMA" for a in alvos):
            continue
        if not isinstance(valor, ast.Dict):
            raise Reprovado("SCHEMA do core deixou de ser um dicionário literal")
        chaves = set()
        for chave in valor.keys:
            if isinstance(chave, ast.Constant) and isinstance(chave.value, str):
                if chave.value.endswith("_DISPENSADO"):
                    chaves.add(chave.value)
        return chaves
    raise Reprovado("SCHEMA não encontrado em libexec/passthrough_core/config.py")


def linhas_de_dados(texto: str) -> list[tuple[int, str]]:
    saida = []
    for numero, linha in enumerate(texto.split("\n"), start=1):
        if linha.startswith("#") or not linha.strip():
            continue
        saida.append((numero, linha))
    return saida


def validar(raiz: Path) -> int:
    alvo = raiz / "lib" / "policy" / "waivers.tsv"
    if not alvo.is_file():
        raise Reprovado(f"matriz ausente: {alvo}")

    bruto = alvo.read_bytes()
    if bruto.startswith(b"\xef\xbb\xbf"):
        raise Reprovado("matriz com BOM")
    if b"\r" in bruto:
        raise Reprovado("matriz com CR; o terminador precisa ser LF")
    if not bruto.endswith(b"\n"):
        raise Reprovado("matriz sem newline final")
    try:
        texto = bruto.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise Reprovado(f"matriz não é UTF-8 válido: {exc}") from exc

    if f"# schema_version={SCHEMA_VERSION}\n" not in texto:
        raise Reprovado(f"matriz sem '# schema_version={SCHEMA_VERSION}' declarado")

    dados = linhas_de_dados(texto)
    if not dados:
        raise Reprovado("matriz sem nenhuma linha de dados")

    etapas_existentes = {p.name for p in (raiz / "etapas").glob("*.sh")}
    schema = chaves_de_dispensa(raiz)
    if not schema:
        raise Reprovado("nenhuma chave *_DISPENSADO encontrada no schema do core")

    vistos: set[tuple[str, str]] = set()
    cobertas: set[str] = set()
    anterior = ""
    for numero, linha in dados:
        campos = linha.split("\t")
        if len(campos) != len(CAMPOS):
            raise Reprovado(
                f"linha {numero}: {len(campos)} campos, esperado {len(CAMPOS)} "
                f"({', '.join(CAMPOS)})"
            )
        etapa, flag, tipo, prereq, simbolo, conflito = campos
        if any(campo != campo.strip() for campo in campos):
            raise Reprovado(f"linha {numero}: campo com espaço nas bordas")
        if not ETAPA_RE.match(etapa):
            raise Reprovado(f"linha {numero}: etapa '{etapa}' fora do padrão NN-nome.sh")
        if etapa not in etapas_existentes:
            raise Reprovado(f"linha {numero}: etapa '{etapa}' não existe em etapas/")
        if not FLAG_RE.match(flag):
            raise Reprovado(f"linha {numero}: flag '{flag}' fora do padrão *_DISPENSADO")
        if flag not in schema:
            raise Reprovado(f"linha {numero}: flag '{flag}' não está no schema do core")
        if tipo not in TIPOS:
            raise Reprovado(f"linha {numero}: tipo '{tipo}' fora do vocabulário {sorted(TIPOS)}")
        if simbolo not in SIMBOLOS:
            raise Reprovado(f"linha {numero}: simbolo_ui '{simbolo}' fora de {sorted(SIMBOLOS)}")
        if conflito not in CONFLITOS:
            raise Reprovado(f"linha {numero}: conflito '{conflito}' fora de {sorted(CONFLITOS)}")
        if not PREREQ_RE.match(prereq):
            raise Reprovado(f"linha {numero}: prereq_excluido '{prereq}' fora do padrão")
        if (etapa, flag) in vistos:
            raise Reprovado(f"linha {numero}: par ({etapa}, {flag}) duplicado")
        vistos.add((etapa, flag))
        cobertas.add(flag)
        if linha < anterior:
            raise Reprovado(f"linha {numero}: matriz fora de ordem C")
        anterior = linha

    faltando = sorted(schema - cobertas)
    if faltando:
        raise Reprovado(
            "chaves de dispensa do schema sem política declarada na matriz: "
            + ", ".join(faltando)
        )

    print(
        f"OK: matriz de dispensas com {len(dados)} políticas, "
        f"{len(cobertas)} chaves cobertas de {len(schema)} no schema"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="raiz física do checkout")
    args = parser.parse_args()
    try:
        return validar(Path(args.root).resolve())
    except Reprovado as exc:
        print(f"ERRO: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
