"""Prova, de dentro do próprio processo, o isolamento exigido em I2.

Estes testes só passam quando o runner foi iniciado com `python3 -I -S -B` e
montou o `sys.path` manualmente. Qualquer regressão de bootstrap aparece aqui
antes de virar comportamento aceito.
"""
import os
import sys
import unittest
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
ROOT = TESTS_DIR.parent.parent
LIBEXEC = ROOT / "libexec"


class RuntimeFlagsTests(unittest.TestCase):
    def test_flags_de_isolamento(self) -> None:
        self.assertEqual(sys.flags.isolated, 1)
        self.assertEqual(sys.flags.no_site, 1)
        self.assertEqual(sys.flags.dont_write_bytecode, 1)
        self.assertIs(sys.dont_write_bytecode, True)

    def test_versao_minima(self) -> None:
        self.assertGreaterEqual(sys.version_info[:2], (3, 10))

    def test_modulo_site_nao_foi_carregado(self) -> None:
        self.assertNotIn("site", sys.modules)


class SysPathTests(unittest.TestCase):
    def test_sem_pacotes_globais(self) -> None:
        for entry in sys.path:
            self.assertNotIn("site-packages", entry)
            self.assertNotIn("dist-packages", entry)

    def test_sem_cwd_nem_caminho_relativo(self) -> None:
        for proibido in ("", ".", os.getcwd()):
            self.assertNotIn(proibido, sys.path)

    def test_libexec_presente_uma_unica_vez(self) -> None:
        self.assertEqual(sys.path.count(str(LIBEXEC)), 1)

    def test_diretorio_de_testes_presente_uma_unica_vez(self) -> None:
        self.assertEqual(sys.path.count(str(TESTS_DIR)), 1)

    def test_apenas_libexec_e_testes_fora_da_stdlib(self) -> None:
        prefixos_stdlib = tuple(
            caminho
            for caminho in (sys.prefix, sys.base_prefix, getattr(sys, "_stdlib_dir", ""))
            if caminho
        )
        for entry in sys.path:
            if entry in (str(LIBEXEC), str(TESTS_DIR)):
                continue
            self.assertTrue(
                entry.startswith(prefixos_stdlib),
                "entrada inesperada no sys.path: %s" % entry,
            )


class ByteCodeTests(unittest.TestCase):
    def test_checkout_sem_bytecode(self) -> None:
        for base in (LIBEXEC, ROOT / "tests", ROOT / "lib"):
            if not base.is_dir():
                continue
            for path in base.rglob("*"):
                self.assertNotEqual(
                    path.name, "__pycache__", "bytecode residual: %s" % path
                )
                self.assertNotIn(
                    path.suffix, (".pyc", ".pyo"), "bytecode residual: %s" % path
                )


class EntrypointImportTests(unittest.TestCase):
    def test_package_importa_sem_efeito(self) -> None:
        import ast

        import passthrough_core

        self.assertTrue(passthrough_core.__doc__)
        corpo = ast.parse(
            (LIBEXEC / "passthrough_core" / "__init__.py").read_text(encoding="utf-8")
        ).body
        self.assertEqual(
            len(corpo), 1, "o __init__ do package precisa continuar sem lógica"
        )
        self.assertIsInstance(corpo[0], ast.Expr)
        self.assertIsInstance(corpo[0].value, ast.Constant)

    def test_nao_existe_segundo_entrypoint(self) -> None:
        self.assertFalse((LIBEXEC / "passthrough_core" / "__main__.py").exists())
        entrypoints = sorted(path.name for path in LIBEXEC.glob("*.py"))
        self.assertEqual(entrypoints, ["passthrough_core_cli.py"])


if __name__ == "__main__":
    unittest.main()
