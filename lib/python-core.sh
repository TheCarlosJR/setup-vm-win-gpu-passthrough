#!/bin/bash
# ============================================================================
# lib/python-core.sh - única ponte Bash para o core Python
# ============================================================================
# Este arquivo NÃO é executado diretamente: ele é carregado via "source" por
# lib/common.sh e, em testes, isoladamente.
#
# Contrato (seções 2.1, 2.2, 3.8 e 3.9 do PLANO-FINALIZACAO.md):
#
#   * nenhuma outra parte do projeto invoca libexec/passthrough_core_cli.py;
#   * a invocação é sempre absoluta, com "python3 -I -S -B";
#   * XML, JSON, configuração e snapshots trafegam por stdin ou por arquivo
#     temporário controlado 0600, jamais por argv;
#   * o Python nunca recebe sudo, nunca decide efeito e nunca é "sourceado":
#     nada aqui transporta código do Python para o Bash (sem eval, sem source
#     de dados, sem regex sobre JSON);
#   * códigos internos 64/65/66/69/70/73/75 nunca viram status público 0;
#   * carregar valores no Bash usa o canal de pares chave\0valor\0 com
#     allowlist explícita e printf -v.
#
# Desempenho: cada chamada é um processo. Agrupe informações em uma única
# chamada (canal de pares ou um JSON com vários campos) em vez de consultar o
# core por valor.
#
# Sourcing deste arquivo não produz efeito: apenas define variáveis e funções.
# ============================================================================

[ -n "${PYTHON_CORE_SH_CARREGADO:-}" ] && return 0
PYTHON_CORE_SH_CARREGADO=1

# Resolução física com um único subshell: `pwd -P` canonicaliza e a raiz sai
# por expansão de parâmetro, sem chamar dirname nem abrir um segundo subshell.
# Toda etapa carrega esta ponte pela fachada, então o custo importa.
_PYTHON_CORE_DIR_RELATIVO="${BASH_SOURCE[0]%/*}"
[ "$_PYTHON_CORE_DIR_RELATIVO" != "${BASH_SOURCE[0]}" ] || _PYTHON_CORE_DIR_RELATIVO=.
PYTHON_CORE_LIB_DIR="$(cd -- "$_PYTHON_CORE_DIR_RELATIVO" && pwd -P)"
unset _PYTHON_CORE_DIR_RELATIVO
PYTHON_CORE_RAIZ="${PYTHON_CORE_LIB_DIR%/*}"
[ -n "$PYTHON_CORE_RAIZ" ] || PYTHON_CORE_RAIZ=/
PYTHON_CORE_LIBEXEC="$PYTHON_CORE_RAIZ/libexec"
PYTHON_CORE_ENTRYPOINT="$PYTHON_CORE_LIBEXEC/passthrough_core_cli.py"
PYTHON_CORE_PACKAGE_INIT="$PYTHON_CORE_LIBEXEC/passthrough_core/__init__.py"
PYTHON_CORE_PROTOCOLO_ESPERADO=1
PYTHON_CORE_LIMITE_VALOR_PARES=65536

# Códigos internos do helper (espelham libexec/passthrough_core/errors.py).
PYTHON_CORE_EXIT_USO=64
PYTHON_CORE_EXIT_DADO=65
PYTHON_CORE_EXIT_ENTRADA_AUSENTE=66
PYTHON_CORE_EXIT_CAPABILITY=69
PYTHON_CORE_EXIT_INTERNO=70
PYTHON_CORE_EXIT_PERSISTENCIA=73
PYTHON_CORE_EXIT_CONFLITO=75

PYTHON_CORE_SAIDA=""
PYTHON_CORE_ERRO=""
PYTHON_CORE_STATUS=0
PYTHON_CORE_DISPONIVEL=""
PYTHON_CORE_TMPDIR=""
PYTHON_CORE_ARQUIVO_PARES=""
PYTHON_CORE_TEMPORARIOS=()

_python_core_emitir_erro() {
    [ -n "$PYTHON_CORE_ERRO" ] || return 0
    printf '%s\n' "$PYTHON_CORE_ERRO" >&2
}

# --- Temporários controlados --------------------------------------------------
# Raiz privada 0700 por processo, com basename aleatório não derivado de nome
# de usuário, host, VM ou hardware. O idioma de trap esperado no chamador é:
#
#   trap 'python_core_temporarios_limpar' EXIT
#   trap 'python_core_temporarios_limpar; exit 130' INT
#   trap 'python_core_temporarios_limpar; exit 143' TERM
#
# As funções de chamada já removem o que criam em sucesso e em erro; o trap
# cobre a janela de sinal.

_python_core_garantir_tmpdir() {
    # Publica a raiz privada em PYTHON_CORE_TMPDIR. Não pode ser chamada por
    # substituição de comando: a atribuição precisa valer no processo atual,
    # senão cada chamada criaria uma raiz nova e nada seria removido.
    if [ -n "$PYTHON_CORE_TMPDIR" ] && [ -d "$PYTHON_CORE_TMPDIR" ]; then
        return 0
    fi
    local _pc_td_base
    _pc_td_base="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/passthrough-core.XXXXXXXXXX")" \
        || {
            PYTHON_CORE_ERRO="Não foi possível criar a raiz temporária do core."
            return 1
        }
    PYTHON_CORE_TMPDIR="$_pc_td_base"
    return 0
}

_python_core_nome_de_chamador_valido() {
    # O escopo do Bash é dinâmico: um "local" homônimo sombrearia a variável do
    # chamador em printf -v e em expansão indireta. Cada função que atribui ou
    # lê indiretamente declara aqui o prefixo que reserva para os seus locais.
    # $1 = nome recebido; $2 = prefixo reservado; $3 = papel para diagnóstico.
    local _pc_nv_nome="${1:-}" _pc_nv_reservado="${2:-}" _pc_nv_papel="${3:-variável}"
    if [[ ! "$_pc_nv_nome" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        PYTHON_CORE_ERRO="Nome de $_pc_nv_papel inválido: '${_pc_nv_nome:-vazio}'."
        return 1
    fi
    if [ -n "$_pc_nv_reservado" ] && [[ "$_pc_nv_nome" == "$_pc_nv_reservado"* ]]; then
        PYTHON_CORE_ERRO="Nome de $_pc_nv_papel reservado pela ponte: '$_pc_nv_nome'."
        return 1
    fi
    return 0
}

python_core_temporario_novo() {
    # Cria arquivo 0600 na raiz privada e publica o caminho na variável dada.
    local _pc_tn_alvo="${1:-}" _pc_tn_arquivo
    _python_core_nome_de_chamador_valido \
        "$_pc_tn_alvo" '_pc_tn_' 'variável de temporário' || return 1
    _python_core_garantir_tmpdir || return 1
    _pc_tn_arquivo="$(umask 077; mktemp "$PYTHON_CORE_TMPDIR/payload.XXXXXXXXXX")" \
        || {
            PYTHON_CORE_ERRO="Não foi possível criar temporário controlado."
            return 1
        }
    PYTHON_CORE_TEMPORARIOS+=("$_pc_tn_arquivo")
    printf -v "$_pc_tn_alvo" '%s' "$_pc_tn_arquivo"
}

_python_core_recolher_tmpdir() {
    # Recolhe a raiz privada assim que ela fica vazia. Sem isso, um consumidor
    # com trap próprio (as etapas transacionais têm) deixaria o diretório para
    # trás, e os testes herméticos exigem TMPDIR limpo ao fim da execução. A
    # remoção só acontece quando nenhum temporário do chamador está registrado,
    # e usa o mesmo `rm -rf` de python_core_temporarios_limpar.
    (( ${#PYTHON_CORE_TEMPORARIOS[@]} == 0 )) || return 0
    [ -n "$PYTHON_CORE_TMPDIR" ] && [ -d "$PYTHON_CORE_TMPDIR" ] || return 0
    rm -rf -- "$PYTHON_CORE_TMPDIR" 2>/dev/null || return 0
    PYTHON_CORE_TMPDIR=""
    return 0
}

python_core_temporario_remover() {
    local alvo="${1:-}" item
    local -a restantes=()
    [ -n "$alvo" ] || return 0
    if (( ${#PYTHON_CORE_TEMPORARIOS[@]} > 0 )); then
        for item in "${PYTHON_CORE_TEMPORARIOS[@]}"; do
            [ "$item" = "$alvo" ] || restantes+=("$item")
        done
    fi
    if (( ${#restantes[@]} > 0 )); then
        PYTHON_CORE_TEMPORARIOS=("${restantes[@]}")
    else
        PYTHON_CORE_TEMPORARIOS=()
    fi
    rm -f -- "$alvo" 2>/dev/null || true
    _python_core_recolher_tmpdir
}

python_core_temporarios_limpar() {
    # Idempotente: pode ser chamada em sucesso, erro e sinal.
    local item
    if (( ${#PYTHON_CORE_TEMPORARIOS[@]} > 0 )); then
        for item in "${PYTHON_CORE_TEMPORARIOS[@]}"; do
            rm -f -- "$item" 2>/dev/null || true
        done
    fi
    PYTHON_CORE_TEMPORARIOS=()
    PYTHON_CORE_ARQUIVO_PARES=""
    if [ -n "$PYTHON_CORE_TMPDIR" ] && [ -d "$PYTHON_CORE_TMPDIR" ]; then
        rm -rf -- "$PYTHON_CORE_TMPDIR" 2>/dev/null || true
    fi
    PYTHON_CORE_TMPDIR=""
}

# --- Instalação e capability --------------------------------------------------

python_core_verificar_instalacao() {
    # Somente builtins: nenhuma escrita, nenhum processo, nenhum privilégio.
    PYTHON_CORE_ERRO=""
    if ! command -v python3 >/dev/null 2>&1; then
        PYTHON_CORE_ERRO="python3 não está no PATH. Instale Python 3.10 ou superior (pacote python3) antes de continuar."
        return "$PYTHON_CORE_EXIT_CAPABILITY"
    fi
    if [ ! -f "$PYTHON_CORE_ENTRYPOINT" ] || [ -L "$PYTHON_CORE_ENTRYPOINT" ]; then
        PYTHON_CORE_ERRO="Entrypoint do core ausente ou simbólico: $PYTHON_CORE_ENTRYPOINT"
        return "$PYTHON_CORE_EXIT_CAPABILITY"
    fi
    if [ ! -f "$PYTHON_CORE_PACKAGE_INIT" ] || [ -L "$PYTHON_CORE_PACKAGE_INIT" ]; then
        PYTHON_CORE_ERRO="Package do core ausente ou simbólico: $PYTHON_CORE_PACKAGE_INIT"
        return "$PYTHON_CORE_EXIT_CAPABILITY"
    fi
    # Legibilidade é checada aqui para que falta de permissão produza um
    # diagnóstico acionável em vez de um erro cru do interpretador.
    if [ ! -r "$PYTHON_CORE_ENTRYPOINT" ] || [ ! -r "$PYTHON_CORE_PACKAGE_INIT" ]; then
        PYTHON_CORE_ERRO="Core Python sem permissão de leitura para o operador: $PYTHON_CORE_LIBEXEC"
        return "$PYTHON_CORE_EXIT_CAPABILITY"
    fi
    return 0
}

# --- Execução -----------------------------------------------------------------

_python_core_registrar_stderr() {
    # Preserva o diagnóstico humano: guarda em PYTHON_CORE_ERRO e reemite.
    local arquivo="$1"
    PYTHON_CORE_ERRO=""
    [ -s "$arquivo" ] || return 0
    PYTHON_CORE_ERRO="$(<"$arquivo")"
    _python_core_emitir_erro
}

_python_core_invocar() {
    # $1 = "heredado" para herdar stdin, ou caminho para redirecionar;
    # $2 = arquivo de stdout; $3 = arquivo de stderr; demais = subcomando/opções.
    local entrada="$1" saida="$2" diagnostico="$3" rc=0
    shift 3
    if [ "$entrada" = heredado ]; then
        LC_ALL=C python3 -I -S -B "$PYTHON_CORE_ENTRYPOINT" "$@" \
            >"$saida" 2>"$diagnostico" || rc=$?
    else
        LC_ALL=C python3 -I -S -B "$PYTHON_CORE_ENTRYPOINT" "$@" \
            <"$entrada" >"$saida" 2>"$diagnostico" || rc=$?
    fi
    return "$rc"
}

_python_core_executar_bruto() {
    # $1 = stdin ("heredado" ou caminho); $2 = modo ("texto" ou "pares");
    # demais = subcomando e opções. Publica SAIDA/ERRO/STATUS.
    local entrada="$1" modo="$2" rc=0 saida diagnostico
    shift 2
    PYTHON_CORE_SAIDA=""
    PYTHON_CORE_ERRO=""
    PYTHON_CORE_STATUS=0
    python_core_verificar_instalacao || {
        PYTHON_CORE_STATUS=$PYTHON_CORE_EXIT_CAPABILITY
        _python_core_emitir_erro
        return "$PYTHON_CORE_STATUS"
    }
    _python_core_garantir_tmpdir || {
        PYTHON_CORE_STATUS=$PYTHON_CORE_EXIT_INTERNO
        _python_core_emitir_erro
        return "$PYTHON_CORE_STATUS"
    }
    saida="$(umask 077; mktemp "$PYTHON_CORE_TMPDIR/stdout.XXXXXXXXXX")" \
        && diagnostico="$(umask 077; mktemp "$PYTHON_CORE_TMPDIR/stderr.XXXXXXXXXX")" \
        || {
            PYTHON_CORE_ERRO="Não foi possível criar temporários de captura do core."
            PYTHON_CORE_STATUS=$PYTHON_CORE_EXIT_INTERNO
            _python_core_emitir_erro
            return "$PYTHON_CORE_STATUS"
        }
    PYTHON_CORE_TEMPORARIOS+=("$saida" "$diagnostico")
    _python_core_invocar "$entrada" "$saida" "$diagnostico" "$@" || rc=$?
    _python_core_registrar_stderr "$diagnostico"
    PYTHON_CORE_STATUS=$rc
    if [ "$rc" -eq 0 ] && [ "$modo" = texto ]; then
        PYTHON_CORE_SAIDA="$(<"$saida")"
    fi
    if [ "$modo" = pares ]; then
        PYTHON_CORE_ARQUIVO_PARES="$saida"
    else
        python_core_temporario_remover "$saida"
    fi
    python_core_temporario_remover "$diagnostico"
    _python_core_recolher_tmpdir
    return "$rc"
}

python_core_executar() {
    # Chamada sem payload. Publica o JSON de máquina em PYTHON_CORE_SAIDA.
    local subcomando="${1:-}"
    [ -n "$subcomando" ] || {
        PYTHON_CORE_ERRO="Subcomando do core não informado."
        PYTHON_CORE_STATUS=$PYTHON_CORE_EXIT_USO
        _python_core_emitir_erro
        return "$PYTHON_CORE_STATUS"
    }
    local rc=0
    _python_core_executar_bruto /dev/null texto "$@" || rc=$?
    return "$rc"
}

_python_core_validar_payload() {
    # Valida subcomando e nome da variável de payload antes de qualquer efeito.
    # O prefixo _pc_ inteiro é reservado porque a expansão indireta do payload
    # ocorre dentro das funções de execução, que também usam locais _pc_*.
    local _pc_vp_subcomando="${1:-}" _pc_vp_nome="${2:-}"
    if [ -z "$_pc_vp_subcomando" ]; then
        PYTHON_CORE_ERRO="Subcomando do core não informado."
        return 1
    fi
    _python_core_nome_de_chamador_valido \
        "$_pc_vp_nome" '_pc_' 'variável de payload' || return 1
    if [ -z "${!_pc_vp_nome+definida}" ]; then
        PYTHON_CORE_ERRO="Variável de payload '$_pc_vp_nome' não está definida."
        return 1
    fi
    return 0
}

python_core_executar_stdin() {
    # Payload por stdin, sem tocar o disco. $1 = subcomando; $2 = nome da
    # variável que contém o payload; demais = opções. A ponte acrescenta
    # --stdin, então o chamador não repete a opção de transporte.
    local _pc_es_subcomando="${1:-}" _pc_es_nome="${2:-}" _pc_es_rc=0
    if ! _python_core_validar_payload "$_pc_es_subcomando" "$_pc_es_nome"; then
        PYTHON_CORE_STATUS=$PYTHON_CORE_EXIT_USO
        _python_core_emitir_erro
        return "$PYTHON_CORE_STATUS"
    fi
    shift 2
    set -- "$_pc_es_subcomando" --stdin "$@"
    _python_core_executar_bruto heredado texto "$@" \
        < <(printf '%s' "${!_pc_es_nome}") || _pc_es_rc=$?
    return "$_pc_es_rc"
}

python_core_executar_arquivo() {
    # Payload por arquivo controlado 0600, cujo caminho aleatório é o único
    # dado local aceito em argv. O temporário é removido em sucesso e em erro.
    local _pc_ea_subcomando="${1:-}" _pc_ea_nome="${2:-}" _pc_ea_arquivo="" _pc_ea_rc=0
    if ! _python_core_validar_payload "$_pc_ea_subcomando" "$_pc_ea_nome"; then
        PYTHON_CORE_STATUS=$PYTHON_CORE_EXIT_USO
        _python_core_emitir_erro
        return "$PYTHON_CORE_STATUS"
    fi
    shift 2
    python_core_verificar_instalacao || {
        PYTHON_CORE_STATUS=$PYTHON_CORE_EXIT_CAPABILITY
        _python_core_emitir_erro
        return "$PYTHON_CORE_STATUS"
    }
    python_core_temporario_novo _pc_ea_arquivo || {
        PYTHON_CORE_STATUS=$PYTHON_CORE_EXIT_INTERNO
        _python_core_emitir_erro
        return "$PYTHON_CORE_STATUS"
    }
    if ! printf '%s' "${!_pc_ea_nome}" > "$_pc_ea_arquivo"; then
        PYTHON_CORE_ERRO="Não foi possível escrever o payload no temporário controlado."
        PYTHON_CORE_STATUS=$PYTHON_CORE_EXIT_INTERNO
        python_core_temporario_remover "$_pc_ea_arquivo"
        _python_core_emitir_erro
        return "$PYTHON_CORE_STATUS"
    fi
    _python_core_executar_bruto /dev/null texto \
        "$_pc_ea_subcomando" "--input-file=$_pc_ea_arquivo" "$@" || _pc_ea_rc=$?
    python_core_temporario_remover "$_pc_ea_arquivo"
    return "$_pc_ea_rc"
}

# --- Canal de pares -----------------------------------------------------------

_python_core_chave_permitida() {
    # $1 = chave observada; $2 = nome do array de allowlist já validado.
    # Uma entrada da allowlist pode conter o token '#', que casa com um ou mais
    # dígitos decimais. É assim que uma lista indexada (NIC_0_MAC, NIC_1_MAC)
    # entra por allowlist explícita, sem aceitar chave arbitrária e sem exigir
    # que o chamador conheça a cardinalidade antes da chamada.
    local _pc_ka_chave="${1:-}" _pc_ka_allowlist="${2:-}"
    local _pc_ka_permitida _pc_ka_padrao
    local -n _pc_ka_ref="$_pc_ka_allowlist"
    for _pc_ka_permitida in "${_pc_ka_ref[@]}"; do
        # A entrada da allowlist é versionada no código, mas a validação é
        # explícita: só maiúsculas, dígitos, sublinhado e '#'. Assim nenhuma
        # entrada pode injetar metacaractere no padrão construído abaixo.
        if [[ ! "$_pc_ka_permitida" =~ ^[A-Z][A-Z0-9_#]*$ ]]; then
            PYTHON_CORE_ERRO="Entrada inválida na allowlist de pares."
            return 2
        fi
        if [[ "$_pc_ka_permitida" != *'#'* ]]; then
            [ "$_pc_ka_permitida" = "$_pc_ka_chave" ] && return 0
            continue
        fi
        _pc_ka_padrao="^${_pc_ka_permitida//'#'/[0-9][0-9]*}\$"
        if [[ "$_pc_ka_chave" =~ $_pc_ka_padrao ]]; then
            return 0
        fi
    done
    return 1
}

_python_core_carregar_pares() {
    # $1 = arquivo com chave\0valor\0; $2 = nome do array de allowlist;
    # $3 = prefixo das variáveis de destino (pode ser vazio).
    local _pc_cp_arquivo="${1:-}" _pc_cp_allowlist="${2:-}" _pc_cp_prefixo="${3:-}"
    local -a _pc_cp_campos=() _pc_cp_chaves=() _pc_cp_valores=()
    local _pc_cp_indice _pc_cp_total _pc_cp_chave _pc_cp_valor
    local _pc_cp_permitida _pc_cp_encontrada
    if [ ! -f "$_pc_cp_arquivo" ] || [ -L "$_pc_cp_arquivo" ]; then
        PYTHON_CORE_ERRO="Saída de pares ausente ou simbólica."
        return 1
    fi
    _python_core_nome_de_chamador_valido \
        "$_pc_cp_allowlist" '_pc_' 'array de allowlist' || return 1
    if [ -n "$_pc_cp_prefixo" ] && [[ ! "$_pc_cp_prefixo" =~ ^[A-Z][A-Z0-9_]*_$ ]]; then
        PYTHON_CORE_ERRO="Prefixo de destino inválido: '$_pc_cp_prefixo'."
        return 1
    fi
    local -n _pc_cp_ref="$_pc_cp_allowlist"
    if (( ${#_pc_cp_ref[@]} == 0 )); then
        PYTHON_CORE_ERRO="Allowlist de pares vazia."
        return 1
    fi
    mapfile -d '' -t _pc_cp_campos < "$_pc_cp_arquivo" \
        || { PYTHON_CORE_ERRO="Não foi possível ler a saída de pares."; return 1; }
    _pc_cp_total=${#_pc_cp_campos[@]}
    if (( _pc_cp_total == 0 )); then
        PYTHON_CORE_ERRO="Saída de pares vazia."
        return 1
    fi
    if (( _pc_cp_total % 2 != 0 )); then
        PYTHON_CORE_ERRO="Saída de pares com paridade inválida ($_pc_cp_total campos)."
        return 1
    fi
    for (( _pc_cp_indice = 0; _pc_cp_indice < _pc_cp_total; _pc_cp_indice += 2 )); do
        _pc_cp_chave="${_pc_cp_campos[_pc_cp_indice]}"
        _pc_cp_valor="${_pc_cp_campos[_pc_cp_indice + 1]}"
        if [[ ! "$_pc_cp_chave" =~ ^[A-Z][A-Z0-9_]{0,63}$ ]]; then
            PYTHON_CORE_ERRO="Chave de pares fora do formato aceito."
            return 1
        fi
        if (( ${#_pc_cp_valor} > PYTHON_CORE_LIMITE_VALOR_PARES )); then
            PYTHON_CORE_ERRO="Valor de '$_pc_cp_chave' excede o limite do canal de pares."
            return 1
        fi
        _pc_cp_encontrada=0
        _python_core_chave_permitida "$_pc_cp_chave" "$_pc_cp_allowlist" \
            || _pc_cp_encontrada=$?
        # 0 = permitida; 1 = fora da allowlist; 2 = allowlist malformada (o
        # diagnóstico já foi publicado pelo matcher).
        if (( _pc_cp_encontrada == 2 )); then
            return 1
        fi
        if (( _pc_cp_encontrada != 0 )); then
            PYTHON_CORE_ERRO="Chave fora da allowlist no canal de pares: $_pc_cp_chave"
            return 1
        fi
        _pc_cp_chaves+=("$_pc_cp_chave")
        _pc_cp_valores+=("$_pc_cp_valor")
    done
    # Publicação todo-ou-nada: só atribui depois de validar o conjunto inteiro.
    for (( _pc_cp_indice = 0; _pc_cp_indice < ${#_pc_cp_chaves[@]}; _pc_cp_indice++ )); do
        printf -v "${_pc_cp_prefixo}${_pc_cp_chaves[_pc_cp_indice]}" '%s' \
            "${_pc_cp_valores[_pc_cp_indice]}" \
            || {
                PYTHON_CORE_ERRO="Não foi possível atribuir a variável de destino do canal de pares."
                return 1
            }
    done
    return 0
}

_python_core_pares_comum() {
    # $1 = stdin ("heredado" ou caminho); $2 = allowlist; $3 = prefixo;
    # $4 = subcomando; demais = opções extras.
    local _pc_pc_entrada="${1:-}" _pc_pc_allowlist="${2:-}"
    local _pc_pc_prefixo="${3:-}" _pc_pc_subcomando="${4:-}" _pc_pc_rc=0
    shift 4
    PYTHON_CORE_ARQUIVO_PARES=""
    if [ -z "$_pc_pc_allowlist" ] || [ -z "$_pc_pc_subcomando" ]; then
        PYTHON_CORE_ERRO="Uso: python_core_pares ALLOWLIST PREFIXO SUBCOMANDO [opções]"
        PYTHON_CORE_STATUS=$PYTHON_CORE_EXIT_USO
        _python_core_emitir_erro
        return "$PYTHON_CORE_STATUS"
    fi
    _python_core_executar_bruto "$_pc_pc_entrada" pares \
        "$_pc_pc_subcomando" --format=pairs "$@" || _pc_pc_rc=$?
    if [ "$_pc_pc_rc" -ne 0 ]; then
        python_core_temporario_remover "$PYTHON_CORE_ARQUIVO_PARES"
        PYTHON_CORE_ARQUIVO_PARES=""
        return "$_pc_pc_rc"
    fi
    if ! _python_core_carregar_pares \
        "$PYTHON_CORE_ARQUIVO_PARES" "$_pc_pc_allowlist" "$_pc_pc_prefixo"; then
        python_core_temporario_remover "$PYTHON_CORE_ARQUIVO_PARES"
        PYTHON_CORE_ARQUIVO_PARES=""
        _python_core_emitir_erro
        PYTHON_CORE_STATUS=$PYTHON_CORE_EXIT_DADO
        return "$PYTHON_CORE_STATUS"
    fi
    python_core_temporario_remover "$PYTHON_CORE_ARQUIVO_PARES"
    PYTHON_CORE_ARQUIVO_PARES=""
    return 0
}

python_core_pares() {
    # $1 = nome do array de allowlist; $2 = prefixo (pode ser ""); $3 =
    # subcomando; demais = opções. Carrega os valores com printf -v.
    local _pc_pr_rc=0
    _python_core_pares_comum /dev/null "$@" || _pc_pr_rc=$?
    return "$_pc_pr_rc"
}

python_core_pares_stdin() {
    # Mesma coisa, com payload por stdin. $1 = allowlist; $2 = prefixo;
    # $3 = subcomando; $4 = nome da variável de payload; demais = opções.
    # A ponte acrescenta --stdin.
    local _pc_ps_allowlist="${1:-}" _pc_ps_prefixo="${2:-}"
    local _pc_ps_subcomando="${3:-}" _pc_ps_nome="${4:-}" _pc_ps_rc=0
    if ! _python_core_validar_payload "$_pc_ps_subcomando" "$_pc_ps_nome"; then
        PYTHON_CORE_STATUS=$PYTHON_CORE_EXIT_USO
        _python_core_emitir_erro
        return "$PYTHON_CORE_STATUS"
    fi
    shift 4
    _python_core_pares_comum heredado "$_pc_ps_allowlist" "$_pc_ps_prefixo" \
        "$_pc_ps_subcomando" --stdin "$@" \
        < <(printf '%s' "${!_pc_ps_nome}") || _pc_ps_rc=$?
    return "$_pc_ps_rc"
}

# --- Payload por pares chave/valor --------------------------------------------
# O Bash nunca constrói JSON. Um payload é um array de pares alternados
# (chave valor chave valor ...) escrito com printf '%s\0' num arquivo
# controlado 0600. Assim não existe escape manual de aspas, barra invertida ou
# controle: qualquer XML, JSON capturado ou snapshot trafega byte a byte.
#
# As chaves são minúsculas (o canal de resposta usa maiúsculas), o que também
# impede confusão entre pedido e resposta.

_python_core_escrever_payload_pares() {
    # $1 = nome do array de pares; $2 = nome da variável que recebe o caminho.
    local _pc_ep_array="${1:-}" _pc_ep_alvo="${2:-}" _pc_ep_arquivo="" _pc_ep_total
    local _pc_ep_indice
    # O prefixo reservado aqui é apenas o dos locais desta função: as próprias
    # funções da ponte passam nomes _pc_<sufixo>_ como destino, e o escopo
    # dinâmico do Bash só cria conflito com os locais visíveis neste quadro.
    _python_core_nome_de_chamador_valido \
        "$_pc_ep_array" '_pc_ep_' 'array de payload' || return 1
    _python_core_nome_de_chamador_valido \
        "$_pc_ep_alvo" '_pc_ep_' 'variável de caminho do payload' || return 1
    local -n _pc_ep_ref="$_pc_ep_array"
    _pc_ep_total=${#_pc_ep_ref[@]}
    if (( _pc_ep_total == 0 )); then
        PYTHON_CORE_ERRO="Payload de pares vazio."
        return 1
    fi
    if (( _pc_ep_total % 2 != 0 )); then
        PYTHON_CORE_ERRO="Payload de pares com paridade inválida ($_pc_ep_total campos)."
        return 1
    fi
    for (( _pc_ep_indice = 0; _pc_ep_indice < _pc_ep_total; _pc_ep_indice += 2 )); do
        if [[ ! "${_pc_ep_ref[_pc_ep_indice]}" =~ ^[a-z][a-z0-9_]{0,63}$ ]]; then
            PYTHON_CORE_ERRO="Chave de payload fora do formato aceito."
            return 1
        fi
    done
    python_core_temporario_novo _pc_ep_arquivo || return 1
    if ! printf '%s\0' "${_pc_ep_ref[@]}" > "$_pc_ep_arquivo"; then
        PYTHON_CORE_ERRO="Não foi possível escrever o payload de pares."
        python_core_temporario_remover "$_pc_ep_arquivo"
        return 1
    fi
    printf -v "$_pc_ep_alvo" '%s' "$_pc_ep_arquivo"
}

python_core_pares_payload() {
    # Chamada completa por pares nas duas direções.
    #   $1 = array de allowlist da resposta; $2 = prefixo das variáveis;
    #   $3 = subcomando; $4 = array de pares do payload; demais = opções.
    local _pc_pp_allowlist="${1:-}" _pc_pp_prefixo="${2:-}"
    local _pc_pp_subcomando="${3:-}" _pc_pp_array="${4:-}"
    local _pc_pp_arquivo="" _pc_pp_rc=0
    if [ -z "$_pc_pp_allowlist" ] || [ -z "$_pc_pp_subcomando" ] || [ -z "$_pc_pp_array" ]; then
        PYTHON_CORE_ERRO="Uso: python_core_pares_payload ALLOWLIST PREFIXO SUBCOMANDO PAYLOAD [opções]"
        PYTHON_CORE_STATUS=$PYTHON_CORE_EXIT_USO
        _python_core_emitir_erro
        return "$PYTHON_CORE_STATUS"
    fi
    shift 4
    python_core_verificar_instalacao || {
        PYTHON_CORE_STATUS=$PYTHON_CORE_EXIT_CAPABILITY
        _python_core_emitir_erro
        return "$PYTHON_CORE_STATUS"
    }
    if ! _python_core_escrever_payload_pares "$_pc_pp_array" _pc_pp_arquivo; then
        PYTHON_CORE_STATUS=$PYTHON_CORE_EXIT_USO
        _python_core_emitir_erro
        return "$PYTHON_CORE_STATUS"
    fi
    _python_core_pares_comum /dev/null "$_pc_pp_allowlist" "$_pc_pp_prefixo" \
        "$_pc_pp_subcomando" --payload-format=pairs \
        "--input-file=$_pc_pp_arquivo" "$@" || _pc_pp_rc=$?
    python_core_temporario_remover "$_pc_pp_arquivo"
    return "$_pc_pp_rc"
}

# --- Arquivo sensível por descritor de diretório -------------------------------
# A configuração do operador é a única escrita autorizada ao core (seção 2.2), e
# o caminho dela é um LOCAL_IDENTIFIER que a seção 3.9 proíbe em argv. A ponte
# resolve isso abrindo o diretório do alvo e passando o **descritor** herdado
# (`--dir-fd=N`, escalar), enquanto o basename fixo viaja no payload. O core
# nunca resolve caminho vindo de dado.

python_core_config() {
    # $1 = array de allowlist da resposta; $2 = prefixo; $3 = subcomando;
    # $4 = array de pares do payload; $5 = diretório do alvo (absoluto);
    # demais = opções extras.
    local _pc_cf_allowlist="${1:-}" _pc_cf_prefixo="${2:-}"
    local _pc_cf_subcomando="${3:-}" _pc_cf_array="${4:-}" _pc_cf_dir="${5:-}"
    local _pc_cf_payload="" _pc_cf_rc=0
    if [ -z "$_pc_cf_allowlist" ] || [ -z "$_pc_cf_subcomando" ] \
        || [ -z "$_pc_cf_array" ] || [ -z "$_pc_cf_dir" ]; then
        PYTHON_CORE_ERRO="Uso: python_core_config ALLOWLIST PREFIXO SUBCOMANDO PAYLOAD DIRETORIO [opções]"
        PYTHON_CORE_STATUS=$PYTHON_CORE_EXIT_USO
        _python_core_emitir_erro
        return "$PYTHON_CORE_STATUS"
    fi
    shift 5
    case "$_pc_cf_dir" in
        /*) ;;
        *)
            PYTHON_CORE_ERRO="O diretório do alvo precisa ser um caminho absoluto."
            PYTHON_CORE_STATUS=$PYTHON_CORE_EXIT_USO
            _python_core_emitir_erro
            return "$PYTHON_CORE_STATUS"
            ;;
    esac
    if [ ! -d "$_pc_cf_dir" ] || [ -L "$_pc_cf_dir" ]; then
        PYTHON_CORE_ERRO="O diretório do alvo não existe ou é um link simbólico."
        PYTHON_CORE_STATUS=$PYTHON_CORE_EXIT_USO
        _python_core_emitir_erro
        return "$PYTHON_CORE_STATUS"
    fi
    python_core_verificar_instalacao || {
        PYTHON_CORE_STATUS=$PYTHON_CORE_EXIT_CAPABILITY
        _python_core_emitir_erro
        return "$PYTHON_CORE_STATUS"
    }
    if ! _python_core_escrever_payload_pares "$_pc_cf_array" _pc_cf_payload; then
        PYTHON_CORE_STATUS=$PYTHON_CORE_EXIT_USO
        _python_core_emitir_erro
        return "$PYTHON_CORE_STATUS"
    fi
    # O descritor é aberto no shell atual para ser herdado pelo interpretador e
    # fechado logo depois, em sucesso e em erro.
    if ! exec {_PC_CFG_FD}< "$_pc_cf_dir"; then
        python_core_temporario_remover "$_pc_cf_payload"
        PYTHON_CORE_ERRO="Não foi possível abrir o diretório do alvo para leitura."
        PYTHON_CORE_STATUS=$PYTHON_CORE_EXIT_INTERNO
        _python_core_emitir_erro
        return "$PYTHON_CORE_STATUS"
    fi
    _python_core_pares_comum /dev/null "$_pc_cf_allowlist" "$_pc_cf_prefixo" \
        "$_pc_cf_subcomando" --payload-format=pairs \
        "--dir-fd=$_PC_CFG_FD" "--input-file=$_pc_cf_payload" "$@" \
        || _pc_cf_rc=$?
    exec {_PC_CFG_FD}<&-
    python_core_temporario_remover "$_pc_cf_payload"
    return "$_pc_cf_rc"
}

# --- Candidatos XML -----------------------------------------------------------

python_core_candidato() {
    # Gera um candidato XML e o entrega em um arquivo pertencente ao Bash.
    #
    #   $1 = nome do array de allowlist de pares da resposta
    #   $2 = prefixo das variáveis de destino
    #   $3 = nome do array de pares do payload
    #   $4 = caminho absoluto do arquivo de destino
    #   demais = opções extras do subcomando
    #
    # O core escreve somente no temporário controlado 0600 criado aqui; o
    # conteúdo é então copiado para o destino do chamador, que continua sendo
    # quem valida com virt-xml-validate e quem define no libvirt. Em qualquer
    # falha o temporário é removido e o destino não é tocado, então uma geração
    # recusada nunca deixa candidato parcial no lugar do anterior.
    local _pc_cs_allowlist="${1:-}" _pc_cs_prefixo="${2:-}"
    local _pc_cs_array="${3:-}" _pc_cs_destino="${4:-}"
    local _pc_cs_temporario="" _pc_cs_payload="" _pc_cs_rc=0
    if [ -z "$_pc_cs_allowlist" ] || [ -z "$_pc_cs_array" ] || [ -z "$_pc_cs_destino" ]; then
        PYTHON_CORE_ERRO="Uso: python_core_candidato ALLOWLIST PREFIXO PAYLOAD DESTINO [opções]"
        PYTHON_CORE_STATUS=$PYTHON_CORE_EXIT_USO
        _python_core_emitir_erro
        return "$PYTHON_CORE_STATUS"
    fi
    case "$_pc_cs_destino" in
        /*) ;;
        *)
            PYTHON_CORE_ERRO="O destino do candidato precisa ser um caminho absoluto."
            PYTHON_CORE_STATUS=$PYTHON_CORE_EXIT_USO
            _python_core_emitir_erro
            return "$PYTHON_CORE_STATUS"
            ;;
    esac
    if [ -L "$_pc_cs_destino" ] \
        || { [ -e "$_pc_cs_destino" ] && [ ! -f "$_pc_cs_destino" ]; }; then
        PYTHON_CORE_ERRO="O destino do candidato precisa ser um arquivo regular, não link nem diretório."
        PYTHON_CORE_STATUS=$PYTHON_CORE_EXIT_USO
        _python_core_emitir_erro
        return "$PYTHON_CORE_STATUS"
    fi
    if [ ! -d "${_pc_cs_destino%/*}" ]; then
        PYTHON_CORE_ERRO="O diretório do destino do candidato não existe."
        PYTHON_CORE_STATUS=$PYTHON_CORE_EXIT_USO
        _python_core_emitir_erro
        return "$PYTHON_CORE_STATUS"
    fi
    shift 4
    python_core_verificar_instalacao || {
        PYTHON_CORE_STATUS=$PYTHON_CORE_EXIT_CAPABILITY
        _python_core_emitir_erro
        return "$PYTHON_CORE_STATUS"
    }
    if ! _python_core_escrever_payload_pares "$_pc_cs_array" _pc_cs_payload; then
        PYTHON_CORE_STATUS=$PYTHON_CORE_EXIT_USO
        _python_core_emitir_erro
        return "$PYTHON_CORE_STATUS"
    fi
    if ! python_core_temporario_novo _pc_cs_temporario; then
        python_core_temporario_remover "$_pc_cs_payload"
        PYTHON_CORE_STATUS=$PYTHON_CORE_EXIT_INTERNO
        _python_core_emitir_erro
        return "$PYTHON_CORE_STATUS"
    fi
    _python_core_pares_comum /dev/null "$_pc_cs_allowlist" "$_pc_cs_prefixo" \
        domain-candidate --payload-format=pairs \
        "--input-file=$_pc_cs_payload" "--output-file=$_pc_cs_temporario" "$@" \
        || _pc_cs_rc=$?
    python_core_temporario_remover "$_pc_cs_payload"
    if [ "$_pc_cs_rc" -ne 0 ]; then
        python_core_temporario_remover "$_pc_cs_temporario"
        return "$_pc_cs_rc"
    fi
    if ! cat -- "$_pc_cs_temporario" > "$_pc_cs_destino"; then
        PYTHON_CORE_ERRO="Não foi possível publicar o candidato no destino informado."
        PYTHON_CORE_STATUS=$PYTHON_CORE_EXIT_PERSISTENCIA
        python_core_temporario_remover "$_pc_cs_temporario"
        _python_core_emitir_erro
        return "$PYTHON_CORE_STATUS"
    fi
    python_core_temporario_remover "$_pc_cs_temporario"
    PYTHON_CORE_STATUS=0
    return 0
}

# --- Disponibilidade ----------------------------------------------------------

python_core_disponivel() {
    # Confirma, uma única vez por processo, que o core responde e fala o
    # protocolo esperado. Read-only: o subcomando version não toca arquivos.
    local -a permitidas=(CORE_VERSION PROTOCOL_VERSION SUBCOMMAND)
    case "$PYTHON_CORE_DISPONIVEL" in
        sim) return 0 ;;
        nao) return "$PYTHON_CORE_EXIT_CAPABILITY" ;;
    esac
    if ! python_core_pares permitidas PYTHON_CORE_VERSAO_ version; then
        PYTHON_CORE_DISPONIVEL=nao
        return "$PYTHON_CORE_EXIT_CAPABILITY"
    fi
    if [ "${PYTHON_CORE_VERSAO_PROTOCOL_VERSION:-}" != "$PYTHON_CORE_PROTOCOLO_ESPERADO" ] \
        || [ -z "${PYTHON_CORE_VERSAO_CORE_VERSION:-}" ] \
        || [ "${PYTHON_CORE_VERSAO_SUBCOMMAND:-}" != version ]; then
        PYTHON_CORE_ERRO="Protocolo do core incompatível: esperado versão $PYTHON_CORE_PROTOCOLO_ESPERADO."
        _python_core_emitir_erro
        PYTHON_CORE_DISPONIVEL=nao
        return "$PYTHON_CORE_EXIT_CAPABILITY"
    fi
    PYTHON_CORE_DISPONIVEL=sim
    return 0
}

# --- Mapeamento para status público -------------------------------------------
# Nenhum código interno pode virar 0. Domínios futuros podem refinar 1/2/3,
# mas nunca reintroduzir sucesso a partir de falha do helper.

python_core_status_publico_mutacao() {
    local rc="${1:-}"
    if [[ ! "$rc" =~ ^[0-9]+$ ]] || [ "$rc" -ne 0 ]; then
        printf '3\n'
    else
        printf '0\n'
    fi
}

python_core_status_publico_verificacao() {
    local rc="${1:-}"
    if [[ ! "$rc" =~ ^[0-9]+$ ]]; then
        printf '3\n'
        return 0
    fi
    case "$rc" in
        0) printf '0\n' ;;
        "$PYTHON_CORE_EXIT_CAPABILITY") printf '2\n' ;;
        *) printf '3\n' ;;
    esac
}
