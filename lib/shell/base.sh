#!/bin/bash
# ============================================================================
# lib/shell/base.sh - primitivas de caminho, log local e predicados puros
# ============================================================================
# Este arquivo NÃO é executado diretamente: ele é carregado via "source" por
# lib/common.sh, que continua sendo a fachada pública das etapas.
#
# Fronteiras (seções 2.1, 2.3 e 2.4 do PLANO-FINALIZACAO.md):
#
#   * aqui ficam as primitivas que todo o resto usa: raiz de estado na home,
#     log local de ações, diagnóstico do core e predicados sintáticos puros;
#   * nenhuma função deste módulo toca privilégio, rede, libvirt ou disco: os
#     predicados decidem sobre TEXTO, nunca sobre o host;
#   * este é o único módulo sem pré-requisito de carga, e por isso ele não
#     pode chamar função de nenhum outro.
#
# Pré-requisitos de carga: nenhum. Este módulo é a base de todos os outros.
#
# Sourcing deste arquivo não produz efeito: apenas define variáveis e funções.
# ============================================================================

[ -n "${BASE_SH_CARREGADO:-}" ] && return 0
BASE_SH_CARREGADO=1

# --- Log local de ações (diagnóstico com privacidade) -------------------------
# Cada ação relevante do HOST fica registrada em um arquivo local, para que
# falhas intermitentes (ex.: retomada da GPU que deixa a tela preta) possam ser
# diagnosticadas depois, mesmo quando o terminal já se perdeu. Privacidade por
# contrato: o log registra somente eventos do lado do host (drivers, hooks,
# systemd, virsh, XML); NUNCA conteúdo, tela, teclado, rede ou qualquer dado de
# dentro da VM, e nada sai da máquina.
#
# O registro em arquivo só é ativado por log_ativar (chamado por guard_mutation
# e pelo menu) e somente em execução interativa (TTY) ou com
# VM_PASSTHROUGH_LOG=1: os --verificar que o menu roda a cada redesenho e os
# harnesses de teste (que exigem validação sem nenhum efeito de escrita)
# permanecem fora do log. Falha de log é sempre best-effort e nunca altera o
# resultado nem a saída de uma etapa.
LOG_ACOES_ATIVO=0
LOG_ACOES_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/vm-passthrough"
LOG_ACOES_ARQUIVO="$LOG_ACOES_DIR/acoes.log"
LOG_ACOES_ROTACAO_BYTES=1048576
# Somente expansão do bash: no momento do source, o PATH pode estar restrito.
LOG_SCRIPT_ID="${BASH_SOURCE[-1]:-desconhecido}"
LOG_SCRIPT_ID="${LOG_SCRIPT_ID##*/}"

# --- Raiz única de estado na home --------------------------------------------
# Tudo o que os scripts gravam na home do operador vive sob a MESMA raiz que o
# log de ações já usa: LOG_ACOES_DIR. O caminho literal existe em UM lugar só
# (a linha de LOG_ACOES_DIR acima); nenhum consumidor pode montá-lo por conta
# própria. Antes da unificação os relatórios moravam em ~/inventario-hardware;
# esse caminho legado continua nomeado aqui apenas para que a etapa 1 possa
# oferecer a migração e removê-lo depois de provar a cópia.
INVENTARIO_LEGADO_DIR="$HOME/inventario-hardware"

diretorio_inventario() {
    # Acessor ÚNICO do diretório de relatórios (inventários, diagnósticos e
    # listagens de grupos IOMMU). Não cria nada: quem grava chama mkdir. O
    # override INVENTARIO_DIR existe para os testes; produção nunca o define.
    printf '%s\n' "${INVENTARIO_DIR:-$LOG_ACOES_DIR/inventario}"
}

_log_acoes_rotacionar() {
    local tamanho
    [ -f "$LOG_ACOES_ARQUIVO" ] || return 0
    tamanho="$(stat -c %s -- "$LOG_ACOES_ARQUIVO" 2>/dev/null)" || return 0
    [ "$tamanho" -ge "$LOG_ACOES_ROTACAO_BYTES" ] 2>/dev/null || return 0
    mv -f -- "$LOG_ACOES_ARQUIVO" "$LOG_ACOES_ARQUIVO.1" 2>/dev/null || true
}

log_ativar() {
    [ "$LOG_ACOES_ATIVO" -eq 0 ] || return 0
    # Sem TTY (testes, automação), nada é escrito, a menos que o operador
    # peça explicitamente com VM_PASSTHROUGH_LOG=1; =0 desliga sempre.
    [ "${VM_PASSTHROUGH_LOG:-}" != 0 ] || return 0
    [ "${VM_PASSTHROUGH_LOG:-}" = 1 ] || [ -t 0 ] || return 0
    mkdir -p -- "$LOG_ACOES_DIR" 2>/dev/null || return 0
    _log_acoes_rotacionar
    LOG_ACOES_ATIVO=1
    log_acao inicio "execução iniciada (pid $$)"
}

log_acao() {
    # log_acao NIVEL MENSAGEM: uma linha com timestamp, script e versão.
    local nivel="$1"
    shift
    [ "$LOG_ACOES_ATIVO" -eq 1 ] || return 0
    printf '%s [%s v%s] [%s] %s\n' \
        "$(date '+%F %T' 2>/dev/null || echo '?')" \
        "$LOG_SCRIPT_ID" "${SCRIPT_VERSION:-?}" "$nivel" "$*" \
        >> "$LOG_ACOES_ARQUIVO" 2>/dev/null || true
}

versao_de_script() {
    # Lê a constante SCRIPT_VERSION declarada no topo de um script, sem
    # executá-lo; imprime "?" quando ausente ou ilegível.
    local arquivo="$1" linha
    linha="$(grep -m1 -E '^SCRIPT_VERSION="[0-9]+\.[0-9]+\.[0-9]+"' -- "$arquivo" 2>/dev/null)" \
        || { echo "?"; return 0; }
    linha="${linha#SCRIPT_VERSION=\"}"
    printf '%s\n' "${linha%%\"*}"
}

# --- Prefixo hermético opcional de caminho de sistema ------------------------
# A variável é declarada aqui porque caminho_sistema é quem a lê, e um módulo
# precisa poder ser carregado sozinho sem esbarrar em variável indefinida sob
# "set -u". Quem a DEFINE é inicializar_raiz_teste, em lib/shell/privilege.sh:
# aceitar uma raiz alternativa é decisão de privilégio, não de caminho.
SISTEMA_RAIZ_TESTE=""

caminho_sistema() {
    local caminho="${1:-}"
    [[ "$caminho" == /* ]] \
        && [[ "$caminho" != *'/../'* && "$caminho" != */.. \
           && "$caminho" != *'/./'* && "$caminho" != */. ]] \
        || return 1
    if [ -n "$SISTEMA_RAIZ_TESTE" ]; then
        [ "$caminho" = / ] && printf '%s\n' "$SISTEMA_RAIZ_TESTE" \
            || printf '%s%s\n' "$SISTEMA_RAIZ_TESTE" "$caminho"
    else
        printf '%s\n' "$caminho"
    fi
}

pci_bdf_valido() {
    local valor="${1:-}"
    [[ "$valor" =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]]
}

pci_vendor_device_valido() {
    local valor="${1:-}"
    [[ "$valor" =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{4}$ ]]
}

caminho_absoluto_seguro() {
    # Espaços e caracteres UTF-8 são permitidos, mas não metacaracteres que
    # mudariam shell/XML/fstab nem componentes relativos ambíguos.
    local caminho="${1:-}"
    [ -n "$caminho" ] && [ "${#caminho}" -le 4096 ] && [[ "$caminho" == /* ]] || return 1
    [[ "$caminho" != *$'\n'* && "$caminho" != *$'\r'* && "$caminho" != *$'\t'* ]] || return 1
    [[ "$caminho" != *'$'* && "$caminho" != *'`'* && "$caminho" != *'"'* \
       && "$caminho" != *"'"* && "$caminho" != *'\'* && "$caminho" != *';'* \
       && "$caminho" != *'|'* && "$caminho" != *'&'* && "$caminho" != *'<'* \
       && "$caminho" != *'>'* && "$caminho" != *'#'* ]] || return 1
    [[ "$caminho" != *'/../'* && "$caminho" != */.. \
       && "$caminho" != *'/./'* && "$caminho" != */. ]]
}

_caminho_lexico_normalizado() {
    local caminho="${1:-}"
    while [[ "$caminho" == *//* ]]; do
        caminho="${caminho//\/\//\/}"
    done
    while [ "$caminho" != / ] && [[ "$caminho" == */ ]]; do
        caminho="${caminho%/}"
    done
    printf '%s\n' "$caminho"
}

_caminho_igual_ou_filho() {
    local caminho="${1:-}" base="${2:-}"
    [ "$caminho" = "$base" ] && return 0
    [ "$base" = / ] && return 0
    [[ "$caminho" == "$base"/* ]]
}

nome_unidade_systemd_valido() {
    local valor="${1:-}"
    [[ "$valor" =~ ^[[:alnum:]][[:alnum:]_.@:-]{0,254}$ ]]
}

inteiro_na_faixa() {
    local valor="${1:-}" minimo="${2:-0}" maximo="${3:-2147483647}" numero
    [[ "$valor" =~ ^[0-9]+$ ]] && [ "${#valor}" -le 10 ] || return 1
    numero=$((10#$valor))
    [ "$numero" -ge "$minimo" ] && [ "$numero" -le "$maximo" ]
}

lista_cpus_valida() {
    # lista_cpus_valida LISTA [TOTAL_CPUS]. Rejeita sobreposição, intervalos
    # invertidos, índices absurdos e CPUs fora do host quando TOTAL é informado.
    local lista="${1:-}" total="${2:-}" parte inicio fim cpu quantidade=0 inicio_texto fim_texto
    local -a partes=()
    local -A vistas=()
    [[ "$lista" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] || return 1
    if [ -n "$total" ]; then
        inteiro_na_faixa "$total" 1 65536 || return 1
    fi
    IFS=',' read -r -a partes <<< "$lista"
    for parte in "${partes[@]}"; do
        if [[ "$parte" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            inicio_texto="${BASH_REMATCH[1]}"
            fim_texto="${BASH_REMATCH[2]}"
            inteiro_na_faixa "$inicio_texto" 0 65535 || return 1
            inteiro_na_faixa "$fim_texto" 0 65535 || return 1
            inicio=$((10#$inicio_texto))
            fim=$((10#$fim_texto))
        else
            inteiro_na_faixa "$parte" 0 65535 || return 1
            inicio=$((10#$parte))
            fim="$inicio"
        fi
        [ "$inicio" -le "$fim" ] || return 1
        for ((cpu = inicio; cpu <= fim; cpu++)); do
            [ -z "${vistas[$cpu]+definida}" ] || return 1
            [ -z "$total" ] || [ "$cpu" -lt "$total" ] || return 1
            vistas[$cpu]=1
            quantidade=$((quantidade + 1))
            [ "$quantidade" -le 4096 ] || return 1
        done
    done
}

# --- Predicados de nome e de endereço (sintaxe, nunca host) ------------------
# Nomes e valores abaixo são interpolados em XML, YAML, caminhos e comandos.
# Aceitar somente formatos estritos evita ambiguidades e injeção por um conf
# editado à mão, sem recorrer a eval.
nome_interface_valido() {
    local nome="${1:-}"
    [[ "$nome" =~ ^[[:alnum:]_][[:alnum:]_.-]{0,14}$ ]]
}

nome_rede_libvirt_valido() {
    local nome="${1:-}"
    [[ "$nome" =~ ^[[:alnum:]_][[:alnum:]_.-]{0,62}$ ]]
}

nome_vm_valido() {
    nome_rede_libvirt_valido "${1:-}"
}

nome_usuario_valido() {
    local nome="${1:-}"
    [[ "$nome" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

nome_grupo_valido() {
    local nome="${1:-}"
    [[ "$nome" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

nome_grupo_vm_dedicado_valido() {
    # Reserva um namespace próprio para impedir que uma configuração manual
    # reutilize grupos privilegiados como disk, sudo, adm ou libvirt.
    local nome="${1:-}"
    nome_grupo_valido "$nome" || return 1
    [[ "$nome" = vm-passthrough || "$nome" =~ ^vm-passthrough-[a-z0-9][a-z0-9_-]*$ ]]
}

mac_valido() {
    local mac="${1:-}"
    [[ "$mac" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]]
}

ipv4_valido() {
    local ip="${1:-}" octeto
    local -a partes=()
    IFS='.' read -r -a partes <<< "$ip"
    [ "${#partes[@]}" -eq 4 ] || return 1
    for octeto in "${partes[@]}"; do
        [[ "$octeto" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$octeto <= 255 )) || return 1
    done
}

ipv4_para_inteiro() {
    local ip="${1:-}" a b c d
    ipv4_valido "$ip" || return 1
    IFS='.' read -r a b c d <<< "$ip"
    echo $(( (10#$a << 24) + (10#$b << 16) + (10#$c << 8) + 10#$d ))
}

cidr_intervalo() {
    local cidr="${1:-}" ip prefixo inteiro mascara inicio fim
    ip="${cidr%/*}"
    prefixo="${cidr##*/}"
    [ "$ip" != "$cidr" ] && ipv4_valido "$ip" || return 1
    [[ "$prefixo" =~ ^[0-9]+$ ]] && [ "$prefixo" -ge 0 ] && [ "$prefixo" -le 32 ] || return 1
    inteiro="$(ipv4_para_inteiro "$ip")"
    if [ "$prefixo" -eq 0 ]; then
        mascara=0
    else
        mascara=$(( (0xFFFFFFFF << (32 - prefixo)) & 0xFFFFFFFF ))
    fi
    inicio=$((inteiro & mascara))
    fim=$((inicio | (0xFFFFFFFF ^ mascara)))
    echo "$inicio $fim"
}

cidrs_sobrepoem() {
    local a_inicio a_fim b_inicio b_fim
    read -r a_inicio a_fim <<< "$(cidr_intervalo "$1")" || return 1
    read -r b_inicio b_fim <<< "$(cidr_intervalo "$2")" || return 1
    [ "$a_inicio" -le "$b_fim" ] && [ "$b_inicio" -le "$a_fim" ]
}

ipv4_unicast_em_cidr() {
    local ip="${1:-}" cidr="${2:-}" inteiro inicio fim
    inteiro="$(ipv4_para_inteiro "$ip")" || return 1
    read -r inicio fim <<< "$(cidr_intervalo "$cidr")" || return 1
    [ "$inteiro" -gt "$inicio" ] && [ "$inteiro" -lt "$fim" ]
}

cidr_privado_24_valido() {
    local cidr="${1:-}" ip a b c d
    [ "${cidr##*/}" = "24" ] || return 1
    ip="${cidr%/*}"
    [ "$ip" != "$cidr" ] && ipv4_valido "$ip" || return 1
    IFS='.' read -r a b c d <<< "$ip"
    (( 10#$d == 0 )) || return 1
    if (( 10#$a == 10 )); then
        return 0
    fi
    if (( 10#$a == 172 && 10#$b >= 16 && 10#$b <= 31 )); then
        return 0
    fi
    (( 10#$a == 192 && 10#$b == 168 ))
}

# --- Pertinência em lista separada por espaço --------------------------------
# Usada por quem compara conjuntos publicados pelo provider de plataforma
# (serviços, grupos, backends). É comparação de token, não de substring: um
# `grep` cru casaria `libvirtd` dentro de `libvirtd-ro`.
lista_contem_token() {
    local lista="$1" alvo="$2" item
    [ -n "$alvo" ] || return 1
    for item in $lista; do
        [ "$item" = "$alvo" ] && return 0
    done
    return 1
}

XML_CONTEUDO=""

_core_diagnostico() {
    # Normaliza o diagnóstico do core para as variáveis públicas de erro (vale
    # para qualquer domínio, não só XML):
    # remove o prefixo do programa e mantém somente a última linha útil, que é
    # a mensagem de domínio. Nada é interpretado: é texto para o operador.
    local padrao="${1:-Falha ao analisar o XML.}" bruto="${PYTHON_CORE_ERRO:-}"
    bruto="${bruto#passthrough-core: }"
    bruto="${bruto%%$'\n'*}"
    printf '%s' "${bruto:-$padrao}"
}
