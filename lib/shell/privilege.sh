#!/bin/bash
# ============================================================================
# lib/shell/privilege.sh - envelope de mutação, sessão sudo e identidade efetiva
# ============================================================================
# Este arquivo NÃO é executado diretamente: ele é carregado via "source" por
# lib/common.sh, que continua sendo a fachada pública das etapas.
#
# Fronteiras (seções 2.1, 2.3 e 2.4 do PLANO-FINALIZACAO.md):
#
#   * aqui fica TODA a superfície de privilégio: guarda global de mutação,
#     sessão sudo única, exigência de comando/plataforma e prova de acesso
#     na identidade alvo;
#   * a raiz hermética de teste é validada aqui (decisão I9-D4 do plano):
#     quem aceita PASSTHROUGH_TEST_ROOT precisa provar que o sudo visível é
#     o mock confinado, e essa é uma decisão de privilégio;
#   * nenhuma etapa chama sudo sem passar por este módulo.
#
# Pré-requisitos de carga: lib/platform.sh, lib/shell/base.sh, lib/shell/ui.sh.
# Carregar fora de ordem é recusado com diagnóstico, nunca com falha obscura.
#
# Sourcing deste arquivo não produz efeito: apenas define variáveis e funções.
# ============================================================================

if ! declare -F log_acao > /dev/null 2>&1; then
    printf 'ERRO: lib/shell/privilege.sh exige %s carregado antes.\n' 'lib/shell/base.sh' >&2
    return 1 2>/dev/null || exit 1
fi
if ! declare -F falhar > /dev/null 2>&1; then
    printf 'ERRO: lib/shell/privilege.sh exige %s carregado antes.\n' 'lib/shell/ui.sh' >&2
    return 1 2>/dev/null || exit 1
fi
if ! declare -F plataforma_carregar > /dev/null 2>&1; then
    printf 'ERRO: lib/shell/privilege.sh exige %s carregado antes.\n' 'lib/platform.sh' >&2
    return 1 2>/dev/null || exit 1
fi

[ -n "${PRIVILEGE_SH_CARREGADO:-}" ] && return 0
PRIVILEGE_SH_CARREGADO=1

# --- Raiz hermética opcional, exclusiva dos testes ---------------------------
# A produção nunca aceita redirecionamento de /etc, /vm ou /usr. O modo de
# teste só é ativado quando o próprio PATH fornece um sudo falso, regular,
# pertencente ao operador e localizado dentro da raiz temporária. Assim um
# sudo real jamais pode receber caminhos injetados pelo ambiente.
inicializar_raiz_teste() {
    local solicitada="${PASSTHROUGH_TEST_ROOT:-}" canonica sudo_falso
    [ -n "$solicitada" ] || return 0
    [ "${PASSTHROUGH_TEST_MODE:-}" = 1 ] \
        || falhar "PASSTHROUGH_TEST_ROOT exige PASSTHROUGH_TEST_MODE=1."
    [[ "$solicitada" == /* ]] && [ "$solicitada" != / ] \
        && [ -d "$solicitada" ] && [ ! -L "$solicitada" ] && [ -O "$solicitada" ] \
        || falhar "Raiz hermética de teste inválida ou não pertencente ao operador."
    canonica="$(cd -- "$solicitada" && pwd -P)" \
        || falhar "Não foi possível canonicalizar a raiz hermética."
    [ "$canonica" = "$solicitada" ] \
        || falhar "A raiz hermética precisa ser canônica e não pode conter links."
    [ -d "$canonica/bin" ] && [ ! -L "$canonica/bin" ] \
        || falhar "A raiz hermética não contém bin/ seguro."
    sudo_falso="$(type -P sudo 2>/dev/null || true)"
    [ "$sudo_falso" = "$canonica/bin/sudo" ] && [ -f "$sudo_falso" ] \
        && [ ! -L "$sudo_falso" ] && [ -O "$sudo_falso" ] && [ -x "$sudo_falso" ] \
        || falhar "Modo hermético recusado: sudo não é o mock confinado da raiz de teste."
    SISTEMA_RAIZ_TESTE="$canonica"
}

# --- Pré-checagens ------------------------------------------------------------
exigir_nao_root() {
    if [ "$(id -u)" -eq 0 ]; then
        falhar "Execute como usuário normal (os scripts chamam sudo quando necessário)."
    fi
}

# --- Envelope central de mutação --------------------------------------------
# Toda recusa ocorre antes de privilégio, temporários ou escrita. A guarda
# consulta somente os-release, a evidência ostree e o fabricante da CPU.
MUTATION_GUARD_ERROR=""
_guard_mutation_diagnosticar() {
    MUTATION_GUARD_ERROR="$1"
    erro "$MUTATION_GUARD_ERROR"
}

guard_mutation() {
    local capability="${1:-}" motivo
    MUTATION_GUARD_ERROR=""
    if [ "$#" -ne 1 ] || [ -z "$capability" ]; then
        _guard_mutation_diagnosticar "Mutação bloqueada: informe exatamente uma capability."
        return 1
    fi
    # Um fluxo que pede capability é um fluxo de mutação: a partir daqui as
    # ações do host passam a ser registradas no log local de diagnóstico.
    log_ativar
    log_acao guard "capability '$capability' solicitada"

    if ! plataforma_carregar; then
        if [ "$PLATAFORMA_DETECTADA" -ne 1 ]; then
            motivo="plataforma não pôde ser detectada com confiança: $PLATAFORMA_ERRO"
        elif [ "$PLATAFORMA_IMUTAVEL" -eq 1 ]; then
            motivo="plataforma imutável: $PLATAFORMA_BLOQUEIO_MOTIVO"
        else
            motivo="nível de suporte $PLATAFORMA_SUPPORT_LEVEL: $PLATAFORMA_BLOQUEIO_MOTIVO"
        fi
        _guard_mutation_diagnosticar "Mutação '$capability' bloqueada: $motivo"
        return 1
    fi

    if [ "$PLATAFORMA_IMUTAVEL" -eq 1 ] || [ "$PLATAFORMA_MUTAVEL" -ne 1 ] \
       || [ "$PLATAFORMA_SUPPORT_LEVEL" != supported ]; then
        _guard_mutation_diagnosticar \
            "Mutação '$capability' bloqueada: plataforma não mutável ($PLATAFORMA_SUPPORT_LEVEL): $PLATAFORMA_BLOQUEIO_MOTIVO"
        return 1
    fi
    if ! platform_require_capability "$capability"; then
        _guard_mutation_diagnosticar \
            "Mutação '$capability' bloqueada: $PLATAFORMA_ERRO"
        return 1
    fi
    if ! plataforma_validar_cpu_amd; then
        _guard_mutation_diagnosticar \
            "Mutação '$capability' bloqueada: $PLATAFORMA_ERRO"
        return 1
    fi
    log_acao guard "capability '$capability' autorizada"
    return 0
}

# --- Sessão sudo: senha UMA vez por execução ---------------------------------
# A senha NUNCA é armazenada (nem em arquivo temporário): o que é renovado é o
# ticket do próprio sudo, a cada 50 s, enquanto o script roda. Assim etapas
# longas (apt, rsync, virt-install) não voltam a pedir senha no meio.
SUDO_KEEPALIVE_PID=""

encerrar_sudo_keepalive() {
    if [ -n "$SUDO_KEEPALIVE_PID" ] && kill -0 "$SUDO_KEEPALIVE_PID" 2>/dev/null; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
    SUDO_KEEPALIVE_PID=""
}

exigir_sudo() {
    local processo_dono="$BASHPID"
    if ! sudo -n true 2>/dev/null; then
        info "Acesso administrativo necessário: a senha do sudo será pedida UMA vez."
        sudo -v || falhar "Sem acesso sudo."
    fi
    if [ -z "$SUDO_KEEPALIVE_PID" ]; then
        # O trap encerra imediatamente no caminho normal. A verificação do PID
        # dono é uma segunda defesa: se outro trap substituir o nosso ou o shell
        # morrer abruptamente, o loop para antes de renovar novamente o ticket.
        (
            while kill -0 "$processo_dono" 2>/dev/null; do
                sleep 50
                kill -0 "$processo_dono" 2>/dev/null || exit 0
                sudo -n true 2>/dev/null || exit 0
            done
        ) >/dev/null 2>&1 &
        SUDO_KEEPALIVE_PID=$!
        trap encerrar_sudo_keepalive EXIT INT TERM
    fi
}

exigir_comando() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 \
            || falhar "Comando '$cmd' não encontrado. Verifique as etapas anteriores (README)."
    done
}

exigir_plataforma_suportada() {
    plataforma_carregar || falhar "$PLATAFORMA_ERRO"
}

# --- Prova de acesso na identidade alvo --------------------------------------
# O modelo compartilhado de /vm concede leitura e escrita exclusivamente pela
# classe de grupo, com other::---. Perguntar isso a um test(1) externo deixava
# o projeto refém do coreutils que a distribuição instala: o uutils adotado
# pelo Ubuntu 25.10 e derivados (Pop!_OS) ignora grupos suplementares em
# -r/-w/-x e nega acesso que o kernel concede, enquanto o coreutils GNU
# responde por access(2). A prova abaixo não consulta nenhum binário de
# coreutils: executa um shell POSIX na identidade alvo e usa o test embutido,
# que em bash, dash e ash resolve por access(2) e enxerga modo, ACL, grupo
# primário e grupos suplementares em qualquer distribuição.
ACESSO_IDENTIDADE_ERRO=""
# O veredito viaja pela saída padrão, não pelo status: assim um sudo que sequer
# chegou a executar a prova (ticket expirado, identidade recusada) nunca é lido
# como "sem acesso", que é a confusão mais cara de diagnosticar nesta etapa.
ACESSO_IDENTIDADE_PROVA='
        set -eu
        # Sem o embutido, a resposta viria de um coreutils desconhecido: a
        # prova se declara impossível em vez de aceitar um veredito alheio.
        [ "$(command -v "[")" = "[" ] || exit 3
        caminho=$1
        shift
        for modo in "$@"; do
            case $modo in
                r) [ -r "$caminho" ] || { echo negado; exit 0; } ;;
                w) [ -w "$caminho" ] || { echo negado; exit 0; } ;;
                x) [ -x "$caminho" ] || { echo negado; exit 0; } ;;
                *) exit 3 ;;
            esac
        done
        echo concedido
    '
acesso_identidade() {
    # acesso_identidade IDENTIDADE MODOS CAMINHO
    # MODOS é qualquer combinação não vazia de r, w e x. Devolve 0 quando a
    # identidade tem todos os acessos pedidos, 1 quando o kernel nega algum e
    # 2 quando a prova não pôde ser produzida. Nenhum modo escreve no alvo.
    local identidade="${1:-}" modos="${2:-}" caminho="${3:-}" indice saida rc=0
    local -a argumentos=()
    ACESSO_IDENTIDADE_ERRO=""
    nome_usuario_valido "$identidade" \
        || { ACESSO_IDENTIDADE_ERRO="Identidade inválida para prova de acesso: '${identidade:-vazio}'."; return 2; }
    [[ "$modos" =~ ^[rwx]+$ ]] \
        || { ACESSO_IDENTIDADE_ERRO="Modos de acesso inválidos: '${modos:-vazio}'; use apenas r, w e x."; return 2; }
    [[ "$caminho" == /* ]] \
        || { ACESSO_IDENTIDADE_ERRO="A prova de acesso exige caminho absoluto: '${caminho:-vazio}'."; return 2; }
    argumentos=("$caminho")
    for (( indice = 0; indice < ${#modos}; indice++ )); do
        argumentos+=("${modos:indice:1}")
    done
    saida="$(sudo -u "$identidade" sh -c "$ACESSO_IDENTIDADE_PROVA" _ "${argumentos[@]}")" || rc=$?
    if [ "$rc" -eq 3 ]; then
        ACESSO_IDENTIDADE_ERRO="O shell POSIX de '$identidade' não expôs test embutido; a prova dependeria do coreutils da distribuição e não seria confiável."
        return 2
    fi
    if [ "$rc" -ne 0 ]; then
        ACESSO_IDENTIDADE_ERRO="A prova de acesso como '$identidade' em $caminho não chegou a ser executada (status $rc); isso não significa acesso negado."
        return 2
    fi
    case "$saida" in
        concedido) return 0 ;;
        negado)
            ACESSO_IDENTIDADE_ERRO="A identidade '$identidade' não possui acesso '$modos' a $caminho."
            return 1
            ;;
        *)
            ACESSO_IDENTIDADE_ERRO="A prova de acesso como '$identidade' em $caminho devolveu um veredito inesperado."
            return 2
            ;;
    esac
}

ativar_unidade_systemd() {
    # Aplica exatamente a ação autorizada pelo provider para a unidade dada.
    local unidade="$1" acao="$2"
    case "$acao" in
        nenhuma) info "Unidade já ativa: $unidade" ;;
        enable-now) sudo systemctl enable --now "$unidade" ;;
        start) sudo systemctl start "$unidade" ;;
        *) falhar "Ação systemd inválida para $unidade: $acao" ;;
    esac
}
