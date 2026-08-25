"""Códigos internos, mapeamento de exceções, paleta e divergência do bootstrap."""
import ast
import unittest
from pathlib import Path

from passthrough_core import colors, errors

LIBEXEC = Path(__file__).resolve().parent.parent.parent / "libexec"
ENTRYPOINT = LIBEXEC / "passthrough_core_cli.py"


class ExitCodeTests(unittest.TestCase):
    def test_valores_normativos(self) -> None:
        self.assertEqual(errors.EXIT_OK, 0)
        self.assertEqual(errors.EXIT_USAGE, 64)
        self.assertEqual(errors.EXIT_DATA, 65)
        self.assertEqual(errors.EXIT_MISSING_INPUT, 66)
        self.assertEqual(errors.EXIT_CAPABILITY, 69)
        self.assertEqual(errors.EXIT_INTERNAL, 70)
        self.assertEqual(errors.EXIT_PERSISTENCE, 73)
        self.assertEqual(errors.EXIT_CONFLICT, 75)

    def test_codigos_internos_unicos(self) -> None:
        codigos = errors.INTERNAL_EXIT_CODES
        self.assertEqual(len(set(codigos)), len(codigos))
        self.assertEqual(len(codigos), 7)

    def test_codigos_internos_nao_colidem_com_status_publico(self) -> None:
        # 0/1/2/3 são os status públicos; nenhum código interno pode ocupá-los.
        for codigo in errors.INTERNAL_EXIT_CODES:
            self.assertGreater(codigo, 3)


class ExceptionMappingTests(unittest.TestCase):
    def test_cada_classe_carrega_seu_codigo(self) -> None:
        pares = (
            (errors.UsageError, errors.EXIT_USAGE),
            (errors.DataError, errors.EXIT_DATA),
            (errors.MissingInputError, errors.EXIT_MISSING_INPUT),
            (errors.CapabilityError, errors.EXIT_CAPABILITY),
            (errors.InternalError, errors.EXIT_INTERNAL),
            (errors.PersistenceError, errors.EXIT_PERSISTENCE),
            (errors.ConflictError, errors.EXIT_CONFLICT),
        )
        for classe, codigo in pares:
            with self.subTest(classe=classe.__name__):
                self.assertTrue(issubclass(classe, errors.CoreError))
                self.assertEqual(classe("mensagem").exit_code, codigo)

    def test_base_falha_fechada_em_interno(self) -> None:
        self.assertEqual(errors.CoreError("x").exit_code, errors.EXIT_INTERNAL)

    def test_mensagem_preservada(self) -> None:
        erro = errors.DataError("payload recusado")
        self.assertEqual(erro.message, "payload recusado")
        self.assertEqual(str(erro), "payload recusado")

    def test_mensagem_ausente_recebe_fallback(self) -> None:
        for entrada in ("", None, 7):
            with self.subTest(entrada=entrada):
                erro = errors.UsageError(entrada)  # type: ignore[arg-type]
                self.assertEqual(erro.message, "Falha do core sem diagnóstico.")

    def test_todas_as_classes_cobertas_pela_tupla(self) -> None:
        classes = [
            valor
            for valor in vars(errors).values()
            if isinstance(valor, type)
            and issubclass(valor, errors.CoreError)
            and valor is not errors.CoreError
        ]
        codigos = {classe.exit_code for classe in classes}
        self.assertEqual(codigos, set(errors.INTERNAL_EXIT_CODES))


class BootstrapDriftTests(unittest.TestCase):
    """O bootstrap duplica literais por necessidade; aqui provamos que não divergem."""

    def _literais(self) -> dict:
        arvore = ast.parse(ENTRYPOINT.read_text(encoding="utf-8"))
        encontrados: dict = {}
        for node in arvore.body:
            if not isinstance(node, ast.Assign) or len(node.targets) != 1:
                continue
            alvo = node.targets[0]
            if not isinstance(alvo, ast.Name):
                continue
            try:
                encontrados[alvo.id] = ast.literal_eval(node.value)
            except ValueError:
                continue
        return encontrados

    def test_codigos_do_bootstrap_espelham_errors(self) -> None:
        literais = self._literais()
        self.assertEqual(literais.get("_EXIT_USAGE"), errors.EXIT_USAGE)
        self.assertEqual(literais.get("_EXIT_CAPABILITY"), errors.EXIT_CAPABILITY)
        self.assertEqual(literais.get("_EXIT_INTERNAL"), errors.EXIT_INTERNAL)

    def test_cores_do_bootstrap_espelham_colors(self) -> None:
        literais = self._literais()
        self.assertEqual(literais.get("_CORE_PREFIX"), colors.PREFIX)
        self.assertEqual(literais.get("_COLOR_RESET"), colors.RESET)
        self.assertEqual(literais.get("_COLOR_BOLD"), colors.BOLD)
        self.assertEqual(literais.get("_COLOR_RED"), colors.RED)
        self.assertEqual(literais.get("_COLOR_BRAND"), colors.BRAND)

    def test_minimo_de_python_declarado(self) -> None:
        self.assertEqual(self._literais().get("_MINIMUM_PYTHON"), (3, 10))

    def test_bootstrap_desabilita_bytecode_antes_de_import_local(self) -> None:
        arvore = ast.parse(ENTRYPOINT.read_text(encoding="utf-8"))
        posicao_flag = None
        posicao_import_local = None
        for indice, node in enumerate(arvore.body):
            if (
                posicao_flag is None
                and isinstance(node, ast.Assign)
                and any(
                    isinstance(alvo, ast.Attribute)
                    and alvo.attr == "dont_write_bytecode"
                    for alvo in node.targets
                )
            ):
                posicao_flag = indice
            if (
                posicao_import_local is None
                and isinstance(node, (ast.Import, ast.ImportFrom))
                and indice > 0
            ):
                nomes = []
                if isinstance(node, ast.ImportFrom) and node.module:
                    nomes.append(node.module)
                nomes.extend(alias.name for alias in node.names)
                if any(nome.startswith("passthrough_core") for nome in nomes):
                    posicao_import_local = indice
        self.assertIsNotNone(posicao_flag)
        # O import do package acontece dentro de main(), não no corpo do módulo.
        self.assertIsNone(posicao_import_local)


if __name__ == "__main__":
    unittest.main()


class DiagnosticLineTests(unittest.TestCase):
    """Cor é decoração de terminal; sem terminal o byte precisa ser o histórico."""

    def test_sem_cor_e_exatamente_o_texto_historico(self) -> None:
        self.assertEqual(
            colors.diagnostic_line("falhou", False), "passthrough-core: falhou\n"
        )

    def test_com_cor_preserva_mensagem_e_fecha_toda_sequencia(self) -> None:
        linha = colors.diagnostic_line("falhou", True)
        self.assertIn("passthrough-core:", linha)
        self.assertIn("falhou", linha)
        self.assertTrue(linha.endswith(colors.RESET + "\n"))
        self.assertEqual(linha.count(colors.RESET), 2)

    def test_so_a_primeira_linha_recebe_cor(self) -> None:
        linha = colors.diagnostic_line("falhou\nUso interno:\n  exemplo", True)
        self.assertEqual(linha.count(colors.RED), 1)
        self.assertTrue(linha.endswith("\nUso interno:\n  exemplo\n"))

    def test_identidade_visual_usa_cor_verdadeira(self) -> None:
        for tom in (colors.BRAND, colors.BRAND_ALT):
            self.assertTrue(tom.startswith("\033[38;2;"))

    def test_paleta_semantica_espelha_o_shell(self) -> None:
        # Mesmos códigos de lib/common.sh, para que a severidade tenha a mesma
        # cor venha ela do shell ou do core.
        self.assertEqual(colors.GREEN, "\033[0;32m")
        self.assertEqual(colors.YELLOW, "\033[0;33m")
        self.assertEqual(colors.RED, "\033[0;31m")
        self.assertEqual(colors.CYAN, "\033[0;36m")
        self.assertEqual(colors.BOLD, "\033[1m")
        self.assertEqual(colors.RESET, "\033[0m")
