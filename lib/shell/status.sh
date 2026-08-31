#!/bin/bash
# ============================================================================
# lib/shell/status.sh - protocolo do modo --verificar e provas fail-closed
# ============================================================================
# Este arquivo NÃO é executado diretamente: ele é carregado via "source" por
# lib/common.sh, que continua sendo a fachada pública das etapas.
#
# Fronteiras (seções 2.1, 2.3 e 2.4 do PLANO-FINALIZACAO.md):
#
#   * aqui ficam o vocabulário do --verificar (v_ok, v_falta, v_erro,
#     v_indeterminado), o sentinel V1 do canal de máquina e as provas
#     compartilhadas que impedem sucesso sem evidência (REQ-VERIFY-FAILCLOSED);
#   * nenhuma prova deste módulo muta o host: elas observam e classificam;
#   * ausência de ferramenta vira INDETERMINADO, nunca CONCLUÍDO.
#
# Pré-requisitos de carga: lib/shell/base.sh, lib/shell/ui.sh.
# Carregar fora de ordem é recusado com diagnóstico, nunca com falha obscura.
#
# Sourcing deste arquivo não produz efeito: apenas define variáveis e funções.
# ============================================================================

if ! declare -F lista_contem_token > /dev/null 2>&1; then
    printf 'ERRO: lib/shell/status.sh exige %s carregado antes.\n' 'lib/shell/base.sh' >&2
    return 1 2>/dev/null || exit 1
fi
if ! declare -F ok > /dev/null 2>&1; then
    printf 'ERRO: lib/shell/status.sh exige %s carregado antes.\n' 'lib/shell/ui.sh' >&2
    return 1 2>/dev/null || exit 1
fi

[ -n "${STATUS_SH_CARREGADO:-}" ] && return 0
STATUS_SH_CARREGADO=1

# --- Protocolo do modo --verificar ---------------------------------------------------
# 0=concluído, 1=pendente, 2=indeterminado, 3=erro. A precedência é
# erro > indeterminado > pendência, mantendo compatibilidade com etapas que
# usam apenas v_ok/v_falta.
STATUS_CONCLUIDO=0
STATUS_PENDENTE=1
STATUS_INDETERMINADO=2
STATUS_ERRO=3
STATUS_SENTINEL_PREFIX='__PASSTHROUGH_STATUS_V1__:'
V_FALHAS=0
V_INDETERMINADOS=0
V_ERROS=0
v_ok()             { ok "$*"; }

v_falta()          { aviso "$*"; V_FALHAS=$((V_FALHAS + 1)); }

v_indeterminado()  { aviso "Indeterminado: $*"; V_INDETERMINADOS=$((V_INDETERMINADOS + 1)); }

v_erro()           { erro "$*"; V_ERROS=$((V_ERROS + 1)); }

# --- Provas compartilhadas dos verificadores (REQ-VERIFY-FAILCLOSED, I9.9) -----
# Regra única destes helpers: ferramenta ausente, saída inesperada e parsing
# incompleto NUNCA viram sucesso. As três classes são distintas de propósito:
#
#   * pendência (v_falta)      = a etapa ainda não foi executada; o operador
#                                resolve rodando a etapa;
#   * indeterminado (v_indet.) = não foi possível OBSERVAR o estado; o operador
#                                resolve dando acesso (ferramenta, privilégio);
#   * erro (v_erro)            = o estado foi observado e está errado ou
#                                contraditório; o operador resolve corrigindo.
#
# Contrato de retorno destes helpers: 0 provado, 1 pendente, 2 indeterminado,
# 3 erro, alinhado com STATUS_* para poder alimentar v_classificar diretamente.
#
# Hermeticidade: quem chama é responsável por rotear caminhos de sistema por
# caminho_sistema antes de passar aqui. O helper não adivinha raiz de teste.

v_exigir_comando() {
    # Uso: v_exigir_comando [--pendente] cmd...
    # Sem --pendente, ausência de ferramenta é INDETERMINADO: sem o binário
    # nada foi observado, e chamar isso de "pendente" mandaria o operador mexer
    # numa configuração que pode já estar correta. Com --pendente, a ausência é
    # a própria pendência da etapa, porque é a etapa que instala a ferramenta.
    local classe=indeterminado cmd
    local faltando=()
    if [ "${1:-}" = "--pendente" ]; then
        classe=pendente
        shift
    fi
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || faltando+=("$cmd")
    done
    if [ "${#faltando[@]}" -eq 0 ]; then
        return 0
    fi
    if [ "$classe" = pendente ]; then
        v_falta "Ferramenta ausente (${faltando[*]}); execute a etapa que a instala."
        return 1
    fi
    v_indeterminado "Ferramenta ausente (${faltando[*]}); o estado não pôde ser observado."
    return 2
}

v_classificar() {
    # Uso: v_classificar RC MSG_OK MSG_PENDENTE MSG_INDETERMINADO MSG_ERRO
    # Código fora de 0..3 é fail-closed: vira erro em vez de ser ignorado.
    local rc="${1:-}" msg_ok="${2:-}" msg_pend="${3:-}"
    local msg_indet="${4:-}" msg_erro="${5:-}"
    case "$rc" in
        0) v_ok "$msg_ok" ;;
        1) v_falta "$msg_pend" ;;
        2) v_indeterminado "$msg_indet" ;;
        3) v_erro "$msg_erro" ;;
        *) v_erro "Código de verificação inesperado ('$rc') ao avaliar: ${msg_erro:-estado não classificado}." ;;
    esac
}

v_prova_pacote() {
    # Prova de instalação REAL, não de "o gerenciador conhece o nome".
    # `dpkg -s` devolve 0 para pacote removido que deixou config-files, o que
    # fazia um pacote ausente ser relatado como instalado.
    local pacote="${1:-}" status=""
    if [ -z "$pacote" ]; then
        v_erro "v_prova_pacote exige o nome do pacote."
        return 3
    fi
    case "${PLATAFORMA_GERENCIADOR_PACOTES:-}" in
        apt)
            if ! command -v dpkg-query >/dev/null 2>&1; then
                v_indeterminado "dpkg-query ausente; a instalação de $pacote não pôde ser comprovada."
                return 2
            fi
            status="$(LC_ALL=C dpkg-query -W -f='${Status}' -- "$pacote" 2>/dev/null)" || status=""
            if [ "$status" = "install ok installed" ]; then
                v_ok "$pacote instalado."
                return 0
            fi
            if [ -z "$status" ]; then
                v_falta "$pacote ausente."
                return 1
            fi
            v_falta "$pacote ausente (estado dpkg: $status)."
            return 1
            ;;
        "")
            v_indeterminado "Gerenciador de pacotes não resolvido; $pacote não pôde ser comprovado."
            return 2
            ;;
        *)
            v_indeterminado "Gerenciador de pacotes '$PLATAFORMA_GERENCIADOR_PACOTES' sem prova de instalação implementada; $pacote não pôde ser comprovado."
            return 2
            ;;
    esac
}

v_prova_arquivo() {
    # Uso: v_prova_arquivo CAMINHO DESCRICAO [--exec] [--marcador REGEX]
    #                      [--esperado ARQUIVO] [--modo MODO]
    # Substitui o padrão `[ -f x ] && v_ok`, que aprova arquivo ilegível,
    # truncado, obsoleto ou com conteúdo de outra geração.
    local caminho="${1:-}" descricao="${2:-}"
    local exigir_exec=0 marcador="" esperado="" modo="" modo_atual=""
    shift 2 2>/dev/null || {
        v_erro "v_prova_arquivo exige caminho e descrição."
        return 3
    }
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --exec) exigir_exec=1; shift ;;
            --marcador) marcador="${2:-}"; shift 2 ;;
            --esperado) esperado="${2:-}"; shift 2 ;;
            --modo) modo="${2:-}"; shift 2 ;;
            *)
                v_erro "v_prova_arquivo recebeu opção desconhecida: $1"
                return 3
                ;;
        esac
    done
    if [ -z "$caminho" ] || [ -z "$descricao" ]; then
        v_erro "v_prova_arquivo exige caminho e descrição não vazios."
        return 3
    fi
    if [ -L "$caminho" ] && [ ! -e "$caminho" ]; then
        v_erro "$descricao é um link simbólico quebrado ($caminho)."
        return 3
    fi
    if [ ! -e "$caminho" ]; then
        v_falta "$descricao ausente ($caminho)."
        return 1
    fi
    if [ ! -f "$caminho" ]; then
        v_erro "$descricao existe mas não é arquivo regular ($caminho)."
        return 3
    fi
    if [ ! -r "$caminho" ]; then
        v_indeterminado "$descricao existe mas não é legível; o conteúdo não pôde ser comprovado ($caminho)."
        return 2
    fi
    if [ "$exigir_exec" -eq 1 ] && [ ! -x "$caminho" ]; then
        v_falta "$descricao presente mas sem permissão de execução ($caminho)."
        return 1
    fi
    if [ -n "$modo" ]; then
        if ! command -v stat >/dev/null 2>&1; then
            v_indeterminado "stat ausente; os modos de $descricao não puderam ser comprovados."
            return 2
        fi
        modo_atual="$(LC_ALL=C stat -c '%a' -- "$caminho" 2>/dev/null)" || modo_atual=""
        if [ -z "$modo_atual" ]; then
            v_indeterminado "Não foi possível ler os modos de $descricao ($caminho)."
            return 2
        fi
        if [ "$modo_atual" != "$modo" ]; then
            v_falta "$descricao com modo $modo_atual, esperado $modo ($caminho)."
            return 1
        fi
    fi
    if [ -n "$esperado" ]; then
        if [ ! -r "$esperado" ]; then
            v_indeterminado "Conteúdo de referência de $descricao indisponível; a convergência não pôde ser comprovada."
            return 2
        fi
        if ! cmp -s -- "$caminho" "$esperado"; then
            v_falta "$descricao presente mas divergente do conteúdo gerado por esta versão ($caminho)."
            return 1
        fi
    fi
    if [ -n "$marcador" ]; then
        if ! LC_ALL=C grep -Eq -- "$marcador" "$caminho" 2>/dev/null; then
            v_falta "$descricao presente mas sem o marcador desta versão ($caminho)."
            return 1
        fi
    fi
    v_ok "$descricao provado ($caminho)."
    return 0
}

v_prova_montagem() {
    # Uso: v_prova_montagem PONTO FSTYPE_ESPERADO [ORIGEM] [opcao...]
    # `mountpoint -q` prova apenas que existe ALGUMA montagem no ponto: não
    # prova o tipo, a origem nem as opções de segurança.
    local ponto="${1:-}" fstype="${2:-}" origem="${3:-}"
    local linha="" alvo_atual="" origem_atual="" fstype_atual="" opcoes_atuais=""
    local opcao
    if [ -z "$ponto" ] || [ -z "$fstype" ]; then
        v_erro "v_prova_montagem exige ponto de montagem e tipo esperado."
        return 3
    fi
    shift 3 2>/dev/null || shift "$#"
    if ! command -v findmnt >/dev/null 2>&1; then
        v_indeterminado "findmnt ausente; a montagem em $ponto não pôde ser comprovada."
        return 2
    fi
    linha="$(LC_ALL=C findmnt -rn --mountpoint "$ponto" \
        --output TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null)" || linha=""
    if [ -z "$linha" ]; then
        v_falta "Nada montado em $ponto."
        return 1
    fi
    read -r alvo_atual origem_atual fstype_atual opcoes_atuais <<< "$linha"
    if [ "$alvo_atual" != "$ponto" ]; then
        v_indeterminado "findmnt devolveu o ponto '$alvo_atual' ao consultar '$ponto'; saída inesperada."
        return 2
    fi
    if [ "$fstype_atual" != "$fstype" ]; then
        v_falta "Montagem em $ponto é do tipo $fstype_atual, esperado $fstype."
        return 1
    fi
    if [ -n "$origem" ] && [ "$origem_atual" != "$origem" ]; then
        v_falta "Montagem em $ponto vem de $origem_atual, esperado $origem."
        return 1
    fi
    for opcao in "$@"; do
        # lista_contem_token recebe (lista, alvo), nessa ordem.
        if ! lista_contem_token "${opcoes_atuais//,/ }" "$opcao"; then
            v_falta "Montagem em $ponto sem a opção obrigatória '$opcao' (atuais: $opcoes_atuais)."
            return 1
        fi
    done
    v_ok "Montagem em $ponto provada: $origem_atual, $fstype_atual, opções obrigatórias presentes."
    return 0
}

VM_EXISTE_MOTIVO=""
vm_existe_estado() {
    # Tri-estado que substitui o booleano vm_existe nos verificadores.
    # 0 = domínio existe, 1 = domínio ausente, 2 = não foi possível observar.
    # `virsh dominfo` com stderr descartado fundia "não existe" com libvirtd
    # fora do ar, virsh ausente e permissão negada, e os oito pontos de chamada
    # relatavam pendência em todos os casos.
    local nome="${1:-}" saida="" rc=0
    VM_EXISTE_MOTIVO=""
    if [ -z "$nome" ]; then
        VM_EXISTE_MOTIVO="nome de VM vazio"
        return 2
    fi
    if ! command -v virsh >/dev/null 2>&1; then
        VM_EXISTE_MOTIVO="virsh ausente"
        return 2
    fi
    saida="$(LC_ALL=C $VIRSH dominfo "$nome" 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ]; then
        return 0
    fi
    # A mensagem de domínio inexistente é estável no libvirt e é a única que
    # autoriza concluir "ausente". Qualquer outra falha é falta de observação.
    if LC_ALL=C grep -Eqi 'domain not found|no domain with matching' <<< "$saida"; then
        VM_EXISTE_MOTIVO="domínio não definido no libvirt"
        return 1
    fi
    VM_EXISTE_MOTIVO="libvirt não respondeu de forma conclusiva (código $rc)"
    return 2
}

nvidia_smi_comprovado() {
    # Promovido de util/atualizar-host.sh (corrigido em I1) para que as demais
    # etapas parem de aceitar rc 0 com saída não parseável como prova.
    local saida="${1:-}"
    LC_ALL=C grep -Eq 'NVIDIA-SMI[[:space:]]+[0-9]' <<< "$saida" \
        && LC_ALL=C grep -Eq 'Driver Version:[[:space:]]*[0-9]' <<< "$saida"
}

v_var_definida() {
    # Uso: v_var_definida NOME [VALIDADOR]
    # Ausente é pendência; presente e fora do formato é ERRO de configuração,
    # nunca pendência: um valor inválido não se resolve reexecutando a etapa.
    local nome="${1:-}" validador="${2:-}" valor=""
    if [ -z "$nome" ]; then
        v_erro "v_var_definida exige o nome da variável."
        return 3
    fi
    valor="${!nome:-}"
    if [ -z "$valor" ]; then
        v_falta "$nome ainda não definido."
        return 1
    fi
    if [ -n "$validador" ]; then
        if ! command -v "$validador" >/dev/null 2>&1 && ! declare -F "$validador" >/dev/null 2>&1; then
            v_indeterminado "Validador '$validador' indisponível; $nome não pôde ser comprovado."
            return 2
        fi
        if ! "$validador" "$valor"; then
            v_erro "$nome com valor fora do formato aceito."
            return 3
        fi
    fi
    v_ok "$nome=$valor"
    return 0
}

v_fim() {
    local rc="$STATUS_CONCLUIDO"
    if [ "$V_ERROS" -gt 0 ]; then
        rc="$STATUS_ERRO"
    elif [ "$V_INDETERMINADOS" -gt 0 ]; then
        rc="$STATUS_INDETERMINADO"
    elif [ "$V_FALHAS" -gt 0 ]; then
        rc="$STATUS_PENDENTE"
    fi
    # O token é criado pelo menu para cada subprocesso. Um RC 0/1/2/3 sem esta
    # linha final não prova que o verificador chegou deliberadamente a v_fim.
    if [[ "${V_STATUS_TOKEN:-}" =~ ^[0-9a-f]{48}$ ]]; then
        printf '%s%s:%s\n' "$STATUS_SENTINEL_PREFIX" "$V_STATUS_TOKEN" "$rc"
    fi
    exit "$rc"
}
