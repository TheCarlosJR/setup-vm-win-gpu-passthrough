#!/bin/bash
# ============================================================================
# lib/shell/waivers.sh - leitura da matriz de política de dispensas
# ============================================================================
# Este arquivo NÃO é executado diretamente: ele é carregado via "source" por
# lib/common.sh, que continua sendo a fachada pública das etapas.
#
# Fronteiras (seções 2.1, 2.3, 2.4 e 3.1 do PLANO-FINALIZACAO.md):
#
#   * aqui fica APENAS a leitura de dado tabular estático e a publicação do
#     estado resolvido; nenhuma decisão de status público;
#   * a validação de schema da matriz é de gate, não de runtime, e vive em
#     tests/check-waivers-matrix.py; em runtime a leitura é fail-closed e
#     recusa qualquer linha que não case exatamente o formato;
#   * a matriz é DADO: nunca é sourceada, nunca passa por eval, e nenhum campo
#     dela vira comando.
#
# Invariante que este módulo protege (REQ-WAIVERS): dispensa é estado de
# ORQUESTRAÇÃO. Ela não entra no sentinel V1, não altera o código de saída de
# nenhum --verificar e não é inferida por parsing de texto da saída da etapa.
# O menu lê a flag por este canal separado e, no máximo, troca o símbolo.
#
# Sourcing deste arquivo não produz efeito: apenas define variáveis e funções.
# ============================================================================

[ -n "${WAIVERS_SH_CARREGADO:-}" ] && return 0
WAIVERS_SH_CARREGADO=1

WAIVERS_MATRIZ_ARQUIVO="${WAIVERS_MATRIZ_ARQUIVO:-$PROJETO_DIR/lib/policy/waivers.tsv}"
WAIVERS_SCHEMA_VERSION_ESPERADA=1

# Vocabulário fechado. Valor fora daqui invalida a linha inteira, em vez de ser
# aceito como texto livre: uma matriz de política que aceita valor desconhecido
# não é política, é sugestão.
WAIVERS_TIPOS_ACEITOS='escolha-de-modo'
WAIVERS_SIMBOLOS_ACEITOS='disp nenhum'
WAIVERS_CONFLITOS_ACEITOS='fatal aviso'

WAIVERS_MATRIZ_CARREGADA=0
WAIVERS_MATRIZ_ERRO=""
declare -ag WAIVERS_LINHAS=()

# Estado publicado por waiver_estado. Sempre reinicializado na entrada, para
# que nenhuma consulta herde o resultado da anterior.
WAIVER_ATIVA=0
WAIVER_CHAVE=""
WAIVER_TIPO=""
WAIVER_PREREQ=""
WAIVER_SIMBOLO=""
WAIVER_CONFLITO=""
WAIVER_ERRO=""

_waiver_campo_aceito() {
    local aceitos="$1" valor="$2" item
    for item in $aceitos; do
        [ "$item" = "$valor" ] && return 0
    done
    return 1
}

waiver_matriz_carregar() {
    # Carrega uma vez por processo. Recusa a matriz inteira ao primeiro defeito:
    # aceitar as linhas boas e ignorar as ruins deixaria o menu decidir sobre um
    # pré-requisito com base em política parcialmente lida.
    [ "$WAIVERS_MATRIZ_CARREGADA" -eq 1 ] && return 0
    WAIVERS_MATRIZ_ERRO=""
    WAIVERS_LINHAS=()

    local arquivo="$WAIVERS_MATRIZ_ARQUIVO"
    if [ ! -f "$arquivo" ] || [ ! -r "$arquivo" ]; then
        WAIVERS_MATRIZ_ERRO="matriz de dispensas ausente ou ilegível ($arquivo)"
        return 2
    fi

    local linha versao_vista=0 numero=0
    local etapa flag tipo prereq simbolo conflito extra
    while IFS= read -r linha || [ -n "$linha" ]; do
        numero=$((numero + 1))
        case "$linha" in
            '# schema_version='*)
                if [ "${linha#\# schema_version=}" != "$WAIVERS_SCHEMA_VERSION_ESPERADA" ]; then
                    WAIVERS_MATRIZ_ERRO="schema_version inesperado na matriz de dispensas (linha $numero)"
                    return 2
                fi
                versao_vista=1
                continue
                ;;
            '#'*|'') continue ;;
        esac
        IFS=$'\t' read -r etapa flag tipo prereq simbolo conflito extra <<< "$linha"
        if [ -n "$extra" ] || [ -z "$conflito" ]; then
            WAIVERS_MATRIZ_ERRO="linha $numero da matriz de dispensas não tem exatamente 6 campos"
            return 2
        fi
        case "$etapa" in
            */*|''|.|..)
                WAIVERS_MATRIZ_ERRO="linha $numero da matriz nomeia etapa inválida"
                return 2
                ;;
        esac
        case "$flag" in
            *_DISPENSADO) ;;
            *)
                WAIVERS_MATRIZ_ERRO="linha $numero da matriz nomeia flag fora do padrão *_DISPENSADO"
                return 2
                ;;
        esac
        if ! _waiver_campo_aceito "$WAIVERS_TIPOS_ACEITOS" "$tipo" \
            || ! _waiver_campo_aceito "$WAIVERS_SIMBOLOS_ACEITOS" "$simbolo" \
            || ! _waiver_campo_aceito "$WAIVERS_CONFLITOS_ACEITOS" "$conflito" \
            || [ -z "$prereq" ]; then
            WAIVERS_MATRIZ_ERRO="linha $numero da matriz usa vocabulário não declarado"
            return 2
        fi
        WAIVERS_LINHAS+=("$etapa|$flag|$tipo|$prereq|$simbolo|$conflito")
    done < "$arquivo"

    if [ "$versao_vista" -ne 1 ]; then
        WAIVERS_MATRIZ_ERRO="matriz de dispensas sem schema_version declarado"
        return 2
    fi
    WAIVERS_MATRIZ_CARREGADA=1
    return 0
}

waiver_estado() {
    # waiver_estado ETAPA
    # 0 = há dispensa declarada E ativa para a etapa
    # 1 = há linha na matriz, mas nenhuma flag ativa (ou não há linha)
    # 2 = a matriz não pôde ser lida; nada pode ser decidido por ela
    #
    # "Ativa" é estritamente o valor 'sim'. Qualquer outro valor, inclusive
    # 'nao', mantém o bloqueio: o requisito exige que valor negativo NÃO
    # dispense, e tratar "não é sim" como ativo inverteria isso.
    local etapa="${1:-}" registro
    local r_etapa r_flag r_tipo r_prereq r_simbolo r_conflito
    WAIVER_ATIVA=0
    WAIVER_CHAVE=""
    WAIVER_TIPO=""
    WAIVER_PREREQ=""
    WAIVER_SIMBOLO=""
    WAIVER_CONFLITO=""
    WAIVER_ERRO=""

    if [ -z "$etapa" ]; then
        WAIVER_ERRO="waiver_estado exige o nome da etapa"
        return 2
    fi
    if ! waiver_matriz_carregar; then
        WAIVER_ERRO="$WAIVERS_MATRIZ_ERRO"
        return 2
    fi
    for registro in ${WAIVERS_LINHAS[@]+"${WAIVERS_LINHAS[@]}"}; do
        IFS='|' read -r r_etapa r_flag r_tipo r_prereq r_simbolo r_conflito <<< "$registro"
        [ "$r_etapa" = "$etapa" ] || continue
        if [ "${!r_flag:-}" = "sim" ]; then
            WAIVER_ATIVA=1
            WAIVER_CHAVE="$r_flag"
            WAIVER_TIPO="$r_tipo"
            WAIVER_PREREQ="$r_prereq"
            WAIVER_SIMBOLO="$r_simbolo"
            WAIVER_CONFLITO="$r_conflito"
            return 0
        fi
    done
    return 1
}

waiver_politica_texto() {
    # Texto único para a execução direta informar a política antes de agir.
    # Existe para que a mensagem não seja reescrita em cada etapa e divirja.
    local etapa="${1:-}"
    if ! waiver_estado "$etapa"; then
        return 1
    fi
    printf 'Escolha de modo registrada em %s=sim: o pré-requisito "%s" não se aplica a este fluxo. Isso é decisão de configuração, não conclusão de etapa.' \
        "$WAIVER_CHAVE" "$WAIVER_PREREQ"
}
