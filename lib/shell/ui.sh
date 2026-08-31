#!/bin/bash
# ============================================================================
# lib/shell/ui.sh - canal humano: cores, mensagens e perguntas
# ============================================================================
# Este arquivo NÃO é executado diretamente: ele é carregado via "source" por
# lib/common.sh, que continua sendo a fachada pública das etapas.
#
# Fronteiras (seções 2.1, 2.3 e 2.4 do PLANO-FINALIZACAO.md):
#
#   * aqui fica a superfície humana (info/ok/aviso/erro/titulo/falhar) e a
#     interação com o operador (confirmar, perguntar, escolher da lista);
#   * nada aqui decide política: uma pergunta devolve a resposta, quem julga
#     é o módulo de domínio que perguntou;
#   * o canal de máquina (sentinel V1 do --verificar) NÃO mora aqui: ele é
#     responsabilidade de status.sh.
#
# Pré-requisitos de carga: lib/shell/base.sh.
# Carregar fora de ordem é recusado com diagnóstico, nunca com falha obscura.
#
# Sourcing deste arquivo não produz efeito: apenas define variáveis e funções.
# ============================================================================

if ! declare -F log_acao > /dev/null 2>&1; then
    printf 'ERRO: lib/shell/ui.sh exige %s carregado antes.\n' 'lib/shell/base.sh' >&2
    return 1 2>/dev/null || exit 1
fi

[ -n "${UI_SH_CARREGADO:-}" ] && return 0
UI_SH_CARREGADO=1

# --- Saída colorida ----------------------------------------------------------
if [ -t 1 ]; then
    C_VERDE=$'\033[0;32m'; C_AMARELO=$'\033[0;33m'; C_VERMELHO=$'\033[0;31m'
    C_AZUL=$'\033[0;36m';  C_NEGRITO=$'\033[1m';    C_RESET=$'\033[0m'
else
    C_VERDE=""; C_AMARELO=""; C_VERMELHO=""; C_AZUL=""; C_NEGRITO=""; C_RESET=""
fi

info()   { echo "${C_AZUL}[info]${C_RESET} $*"; log_acao info "$*"; }

ok()     { echo "${C_VERDE}[ ok ]${C_RESET} $*"; log_acao ok "$*"; }

aviso()  { echo "${C_AMARELO}[aviso]${C_RESET} $*"; log_acao aviso "$*"; }

erro()   { echo "${C_VERMELHO}[erro]${C_RESET} $*" >&2; log_acao erro "$*"; }

titulo() { echo; echo; echo "${C_NEGRITO}==== $* ====${C_RESET}"; echo; log_acao titulo "$*"; }

falhar() { erro "$*"; log_acao fatal "execução encerrada com status 1"; exit 1; }

# --- Interação ----------------------------------------------------------------
# Códigos reservados para que uma etapa filha possa controlar o menu sem que
# cancelamento seja confundido com falha técnica.
CODIGO_VOLTAR_MENU=20
CODIGO_SAIR_MENU=21

cancelar_etapa() {
    aviso "${*:-Operação cancelada; voltando ao menu principal.}" >&2
    exit "$CODIGO_VOLTAR_MENU"
}

confirmar() {
    # confirmar "Pergunta?" -> 0 se sim; padrão NÃO. v volta ao menu e q
    # encerra o menu (ou apenas a etapa quando executada diretamente).
    local resposta normalizada
    read -r -p "$1 [s/N; v=voltar; q=sair] " resposta || return 1
    normalizada="${resposta,,}"
    case "$normalizada" in
        s|sim) return 0 ;;
        v|voltar)
            aviso "Operação cancelada; voltando ao menu principal." >&2
            exit "$CODIGO_VOLTAR_MENU"
            ;;
        q|sair)
            aviso "Saída solicitada pelo usuário." >&2
            exit "$CODIGO_SAIR_MENU"
            ;;
        *) return 1 ;;
    esac
}

confirmar_digitando() {
    # confirmar_digitando PALAVRA "mensagem" -> exige a PALAVRA exata; também
    # aceita v/voltar e q/sair como comandos de navegação.
    local palavra="$1" msg="$2" resposta normalizada
    echo
    aviso "$msg"
    read -r -p "Digite ${palavra} para confirmar; v=voltar; q=sair; outra resposta cancela: " resposta \
        || return 1
    [ "$resposta" = "$palavra" ] && return 0
    normalizada="${resposta,,}"
    case "$normalizada" in
        v|voltar)
            aviso "Operação cancelada; voltando ao menu principal." >&2
            exit "$CODIGO_VOLTAR_MENU"
            ;;
        q|sair)
            aviso "Saída solicitada pelo usuário." >&2
            exit "$CODIGO_SAIR_MENU"
            ;;
        *) return 1 ;;
    esac
}

perguntar() {
    # perguntar "texto" "padrao" -> imprime a resposta (ou o padrão) no stdout.
    # O prompt do read vai para stderr, então funciona dentro de $(...).
    local texto="$1" padrao="${2:-}" resposta
    if [ -n "$padrao" ]; then
        read -r -p "$texto [$padrao]: " resposta
        echo "${resposta:-$padrao}"
    else
        read -r -p "$texto: " resposta
        echo "$resposta"
    fi
}

perguntar_inteiro() {
    # perguntar_inteiro "texto" PADRAO MIN MAX -> imprime um inteiro VÁLIDO.
    # v/voltar retorna ao menu e q/sair encerra o menu. Entradas inválidas são
    # reperguntadas em vez de derrubar o script.
    local texto="$1" padrao="${2:-}" min="$3" max="$4" resposta normalizada
    while :; do
        resposta="$(perguntar "$texto ($min-$max; v=voltar; q=sair)" "$padrao")"
        normalizada="${resposta,,}"
        case "$normalizada" in
            v|voltar)
                aviso "Seleção cancelada; voltando ao menu principal." >&2
                return "$CODIGO_VOLTAR_MENU"
                ;;
            q|sair)
                aviso "Saída solicitada pelo usuário." >&2
                return "$CODIGO_SAIR_MENU"
                ;;
        esac
        if [[ "$resposta" =~ ^[0-9]+$ ]] && [ "$resposta" -ge "$min" ] && [ "$resposta" -le "$max" ]; then
            echo "$resposta"
            return 0
        fi
        erro "Valor inválido: '${resposta}'. Informe um número entre $min e $max, v para voltar ou q para sair."
    done
}

PERGUNTA_VALIDADA=""
perguntar_validado() {
    # perguntar_validado "texto" "padrao" VALIDADOR "mensagem de recusa".
    # Repergunta até o VALIDADOR (função de um argumento) aceitar, definindo
    # PERGUNTA_VALIDADA; cinco recusas retornam 1 sem valor. Roda no shell
    # corrente para que uma resposta inválida seja reperguntada com o motivo
    # em vez de estourar mais tarde dentro de salvar_conf.
    local texto="$1" padrao="${2:-}" validador="$3" recusa="$4"
    local resposta tentativas=0
    PERGUNTA_VALIDADA=""
    declare -F "$validador" >/dev/null 2>&1 \
        || { erro "Validador desconhecido em perguntar_validado: '$validador'."; return 1; }
    while :; do
        resposta="$(perguntar "$texto" "$padrao")"
        if "$validador" "$resposta"; then
            PERGUNTA_VALIDADA="$resposta"
            return 0
        fi
        aviso "$recusa (recebi: '${resposta:-vazio}')"
        tentativas=$((tentativas + 1))
        [ "$tentativas" -lt 5 ] || return 1
    done
}

escolher_da_lista() {
    # escolher_da_lista "pergunta" sim|nao item1 item2 ...
    # Lista os itens numerados (em stderr) e imprime no stdout o ÍNDICE
    # escolhido: 1..N, ou 0 quando o chamador permite não selecionar item.
    local pergunta="$1" permitir_nenhum="$2"
    shift 2
    local itens=("$@") i min=1 padrao=""
    # Índice em largura fixa, alinhado à direita com espaço em vez de zero: em
    # lista longa (USB, discos, controladoras) os rótulos caem todos na mesma
    # coluna, e as opções fixas abaixo respeitam o mesmo recuo.
    for i in "${!itens[@]}"; do
        printf '  %5d) %s\n' "$((i + 1))" "${itens[$i]}" >&2
    done
    if [ "$permitir_nenhum" = "sim" ]; then
        printf '  %5d) não selecionar item\n' 0 >&2
        min=0
    fi
    printf '  %5s) voltar ao menu principal\n  %5s) sair\n' v q >&2
    [ "${#itens[@]}" -eq 1 ] && [ "$min" -eq 1 ] && padrao=1
    perguntar_inteiro "$pergunta" "$padrao" "$min" "${#itens[@]}"
}

# --- Diversos ----------------------------------------------------------------------
pedir_reboot() {
    echo
    aviso "REINICIALIZAÇÃO NECESSÁRIA para concluir esta etapa."
    aviso "Após o reboot, rode esta mesma etapa novamente (ela continua/valida sozinha)"
    aviso "ou abra o menu.sh para ver o status."
    if confirmar "Reiniciar agora?"; then
        sudo reboot
    else
        info "Ok, reinicie manualmente quando puder (sudo reboot)."
    fi
}
