"""Exceções tipadas e códigos internos do core (seção 3.8).

Os códigos abaixo são internos do helper Python. A ponte Bash os traduz por
contexto e nenhum valor entre 64 e 75 pode virar status público 0.

Mapa normativo:

* 0  sucesso;
* 64 uso (argv, opção, transporte ou identificador inválido);
* 65 dado/schema (payload malformado, fora do schema fechado ou inválido);
* 66 entrada ausente (payload vazio ou arquivo controlado inexistente);
* 69 capability (recurso do ambiente ausente, por exemplo versão de Python);
* 70 erro interno (defeito do próprio core);
* 73 persistência segura (falha ao publicar arquivo sensível);
* 75 conflito/TOCTOU (estado mudou entre a leitura e a publicação).
"""
from __future__ import annotations

EXIT_OK = 0
EXIT_USAGE = 64
EXIT_DATA = 65
EXIT_MISSING_INPUT = 66
EXIT_CAPABILITY = 69
EXIT_INTERNAL = 70
EXIT_PERSISTENCE = 73
EXIT_CONFLICT = 75

# Ordem estável usada por testes e pela ponte para provar que nenhum código
# interno colide com os status públicos 0/1/2/3.
INTERNAL_EXIT_CODES = (
    EXIT_USAGE,
    EXIT_DATA,
    EXIT_MISSING_INPUT,
    EXIT_CAPABILITY,
    EXIT_INTERNAL,
    EXIT_PERSISTENCE,
    EXIT_CONFLICT,
)


class CoreError(Exception):
    """Falha prevista do core, com código interno e mensagem humana.

    A mensagem é destinada a stderr e precisa ser acionável sem revelar valor
    bruto de dado local (seção 3.9). Use `protocol.safe_label` para citar
    qualquer trecho vindo da entrada.
    """

    exit_code = EXIT_INTERNAL

    def __init__(self, message: str) -> None:
        if not isinstance(message, str) or not message:
            message = "Falha do core sem diagnóstico."
        super().__init__(message)
        self.message = message


class UsageError(CoreError):
    """Subcomando, opção, transporte ou identificador escalar inválido."""

    exit_code = EXIT_USAGE


class DataError(CoreError):
    """Payload malformado, fora do schema fechado ou com valor inválido."""

    exit_code = EXIT_DATA


class MissingInputError(CoreError):
    """Entrada obrigatória ausente ou vazia."""

    exit_code = EXIT_MISSING_INPUT


class CapabilityError(CoreError):
    """Recurso do ambiente indisponível para atender à chamada."""

    exit_code = EXIT_CAPABILITY


class InternalError(CoreError):
    """Defeito do próprio core: invariante interna violada."""

    exit_code = EXIT_INTERNAL


class PersistenceError(CoreError):
    """Falha na publicação segura de arquivo sensível."""

    exit_code = EXIT_PERSISTENCE


class ConflictError(CoreError):
    """Estado observado mudou entre a leitura e a publicação (TOCTOU)."""

    exit_code = EXIT_CONFLICT
