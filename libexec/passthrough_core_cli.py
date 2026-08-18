#!/usr/bin/env python3
"""Entrypoint único do core Python do projeto.

Contrato desta camada (seções 2.2, 2.3 e 3.8 do PLANO-FINALIZACAO.md):

* invocação exclusiva pela ponte `lib/python-core.sh`, sempre por caminho
  absoluto e com `python3 -I -S -B`;
* nenhum comando do host, nenhum privilégio, nenhuma escrita fora da entrada
  controlada que a própria ponte cria;
* bytecode desabilitado antes do primeiro import local e `sys.path` recebendo
  somente o `libexec` físico deste arquivo;
* em sucesso, stdout contém apenas dados de máquina; em erro, stdout fica
  vazio e o diagnóstico humano sai em stderr.

O bootstrap abaixo roda antes de qualquer import local e por isso mantém
sintaxe conservadora: um interpretador antigo precisa conseguir compilar o
arquivo para exibir o diagnóstico de versão.
"""
import sys

sys.dont_write_bytecode = True

# Espelham libexec/passthrough_core/errors.py. O bootstrap não pode importar o
# package antes de validar o ambiente, então os literais são duplicados de
# propósito; tests/python/test_errors.py reprova qualquer divergência.
_EXIT_USAGE = 64
_EXIT_CAPABILITY = 69
_EXIT_INTERNAL = 70

_MINIMUM_PYTHON = (3, 10)
_FORBIDDEN_PATH_MARKERS = ("site-packages", "dist-packages")
_REQUIRED_PARENT = "libexec"
_PACKAGE_NAME = "passthrough_core"


def _fail(message, code):
    """Emite diagnóstico humano em stderr e devolve o código interno."""
    text = "passthrough-core: " + message + "\n"
    try:
        sys.stderr.buffer.write(text.encode("utf-8", "backslashreplace"))
        sys.stderr.buffer.flush()
    except Exception:  # noqa: BLE001 - diagnóstico não pode mascarar o código
        pass
    return code


def _bootstrap():
    """Valida ambiente e raiz física. Devolve (raiz, código_de_falha)."""
    if sys.version_info < _MINIMUM_PYTHON:
        return None, _fail(
            "Python %d.%d ou superior é obrigatório; este interpretador é %d.%d."
            % (
                _MINIMUM_PYTHON[0],
                _MINIMUM_PYTHON[1],
                sys.version_info[0],
                sys.version_info[1],
            ),
            _EXIT_CAPABILITY,
        )

    if not (
        sys.flags.isolated
        and sys.flags.no_site
        and sys.flags.dont_write_bytecode
    ):
        return None, _fail(
            "Invoque o core somente pela ponte lib/python-core.sh, que usa "
            "python3 -I -S -B com caminho absoluto.",
            _EXIT_USAGE,
        )

    for entry in sys.path:
        for marker in _FORBIDDEN_PATH_MARKERS:
            if marker in entry:
                return None, _fail(
                    "sys.path contaminado por pacotes globais; o core não "
                    "aceita site-packages nem dist-packages.",
                    _EXIT_USAGE,
                )

    from pathlib import Path

    entrypoint = Path(__file__).resolve()
    root = entrypoint.parent
    package = root / _PACKAGE_NAME
    initializer = package / "__init__.py"

    if root.name != _REQUIRED_PARENT:
        return None, _fail(
            "O entrypoint precisa residir em %s/ dentro do checkout físico."
            % _REQUIRED_PARENT,
            _EXIT_INTERNAL,
        )
    if package.is_symlink() or not package.is_dir():
        return None, _fail(
            "Package do core ausente ou simbólico no libexec físico.",
            _EXIT_INTERNAL,
        )
    if initializer.is_symlink() or not initializer.is_file():
        return None, _fail(
            "Inicializador do package ausente ou simbólico no libexec físico.",
            _EXIT_INTERNAL,
        )
    if package.resolve() != package:
        return None, _fail(
            "Package do core não pertence ao mesmo libexec físico do entrypoint.",
            _EXIT_INTERNAL,
        )

    sys.path.insert(0, str(root))
    return root, None


def main():
    """Bootstrap, despacho e mapeamento de falhas para códigos internos."""
    _root, failure = _bootstrap()
    if failure is not None:
        return failure

    try:
        from passthrough_core.cli import main as cli_main
    except Exception as error:  # noqa: BLE001 - sem traceback por padrão
        return _fail(
            "Não foi possível carregar o core Python (%s)." % type(error).__name__,
            _EXIT_INTERNAL,
        )

    try:
        return cli_main(sys.argv[1:])
    except SystemExit:
        raise
    except Exception as error:  # noqa: BLE001 - sem traceback por padrão
        return _fail(
            "Falha interna não tratada no core (%s)." % type(error).__name__,
            _EXIT_INTERNAL,
        )


if __name__ == "__main__":
    sys.exit(main())
else:
    raise ImportError(
        "passthrough_core_cli.py é o entrypoint único do core e não pode ser "
        "importado como módulo."
    )
