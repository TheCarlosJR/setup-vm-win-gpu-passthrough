"""Paleta ANSI do diagnóstico humano do core (seção 3.10).

Módulo puro: não importa nada, não sonda o host e não decide nada. Ele só
declara constantes e monta a linha de diagnóstico. Quem sabe se existe terminal
é a CLI, a única camada que enxerga os fluxos do processo.

Fronteira que este módulo NÃO cruza: apenas o texto destinado ao operador em
stderr recebe cor. O stdout jamais é colorido, porque ele carrega o canal de
pares lido pelo Bash e qualquer sequência de escape ali seria corrupção de
dado, não decoração.

A paleta semântica espelha a de `lib/common.sh`, para que a mesma severidade
tenha a mesma cor venha ela do shell ou do core. A ela se somam os dois tons da
identidade visual do projeto, em cor verdadeira de 24 bits.
"""

RESET = "\033[0m"
BOLD = "\033[1m"
GREEN = "\033[0;32m"
YELLOW = "\033[0;33m"
RED = "\033[0;31m"
CYAN = "\033[0;36m"

# Identidade visual do projeto: #0D5A5C (primária) e #115C5B (secundária).
BRAND = "\033[38;2;13;90;92m"
BRAND_ALT = "\033[38;2;17;92;91m"

# Rótulo do programa em toda linha de diagnóstico, colorida ou não.
PREFIX = "passthrough-core: "


def diagnostic_line(message: str, colored: bool) -> str:
    """Linha de diagnóstico do core, já terminada em quebra.

    Com `colored` falso o resultado é exatamente `PREFIX + message + "\\n"`,
    byte a byte igual ao que o core sempre emitiu. Captura, redirecionamento e
    oráculo de teste continuam lendo texto puro, então nenhuma asserção de
    saída precisa conhecer cor.

    Colorida, a linha marca o rótulo do programa com o tom primário da
    identidade e a mensagem com o vermelho semântico: quem escreve aqui está
    sempre reportando falha.

    Só a primeira linha da mensagem é colorida. Diagnóstico de uso traz o texto
    de ajuda inteiro na continuação, e pintar dezenas de linhas de vermelho
    atrapalha exatamente quem precisa lê-las.
    """
    if not colored:
        return PREFIX + message + "\n"
    head, separator, tail = message.partition("\n")
    return (
        BRAND + BOLD + PREFIX.rstrip() + RESET + " "
        + RED + head + RESET + separator + tail + "\n"
    )
