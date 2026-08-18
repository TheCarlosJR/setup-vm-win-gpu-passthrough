#!/usr/bin/env python3
"""Bootstrap isolado e discovery unittest do core Python.

Chamado por `tests/test-python-core.sh` como
`python3 -I -S -B <raiz física>/tests/python/run_tests.py`.

O runner desabilita bytecode antes de qualquer import local e coloca no
`sys.path` apenas dois diretórios físicos resolvidos: o `libexec` do core e o
próprio diretório de testes. Nenhum caminho vem de ambiente, cwd, `.pth`,
`site-packages` ou `dist-packages`.

Saída de máquina não se aplica: o relatório do unittest sai em stderr e o
status de saída é 0 apenas quando todos os testes passam e o discovery não
registrou erro.
"""
import sys

sys.dont_write_bytecode = True

import unittest  # noqa: E402 - depois de desabilitar bytecode
from pathlib import Path  # noqa: E402

RUNNER = Path(__file__).resolve()
TESTS_DIR = RUNNER.parent
ROOT = TESTS_DIR.parent.parent
LIBEXEC = ROOT / "libexec"
FORBIDDEN_PATH_MARKERS = ("site-packages", "dist-packages")


def prepare_path() -> None:
    """Deixa o sys.path com exatamente o que o core e os testes precisam."""
    initializer = LIBEXEC / "passthrough_core" / "__init__.py"
    if not initializer.is_file() or initializer.is_symlink():
        raise SystemExit(
            "passthrough-core: package ausente ou simbólico em %s" % LIBEXEC
        )
    for entry in sys.path:
        for marker in FORBIDDEN_PATH_MARKERS:
            if marker in entry:
                raise SystemExit(
                    "passthrough-core: sys.path contaminado por pacotes globais"
                )
    for directory in (str(LIBEXEC), str(TESTS_DIR)):
        while directory in sys.path:
            sys.path.remove(directory)
        sys.path.insert(0, directory)


def main() -> int:
    prepare_path()
    loader = unittest.TestLoader()
    suite = loader.discover(
        start_dir=str(TESTS_DIR),
        pattern="test_*.py",
        top_level_dir=str(TESTS_DIR),
    )
    result = unittest.TextTestRunner(verbosity=1, stream=sys.stderr).run(suite)
    if loader.errors:
        for error in loader.errors:
            sys.stderr.write("passthrough-core: erro de discovery: %s\n" % error)
        return 1
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
