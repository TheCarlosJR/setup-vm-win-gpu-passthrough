#!/bin/bash
# ============================================================================
# lib/common.sh - funções compartilhadas por todas as etapas e utilitários
# ============================================================================
# Este arquivo NÃO é executado diretamente: ele é carregado via "source"
# pelos scripts de etapas/ e util/.
#
# Referências: Guia-QEMU-Passthrough.md e troubleshooting.md.
# ============================================================================

# --- Localização do projeto e arquivos centrais -----------------------------
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJETO_DIR="$(cd "$COMMON_DIR/.." && pwd)"
# shellcheck source=lib/platform.sh
source "$COMMON_DIR/platform.sh"
# Ponte única para o core Python. O carregamento não produz efeito: nada é
# executado até que uma função python_core_* seja chamada explicitamente.
# shellcheck source=lib/python-core.sh
source "$COMMON_DIR/python-core.sh"
CONF_ARQUIVO="$PROJETO_DIR/passthrough.conf"
BACKUPS_DIR="$PROJETO_DIR/backups"
FSTAB="/etc/fstab"
GRUB_DEFAULT_ARQUIVO="/etc/default/grub"
GRUB_CFG_ARQUIVO="/boot/grub/grub.cfg"
KERNELSTUB_ENTRIES_DIR="/boot/efi/loader/entries"
VFIO_MODULES_ARQUIVO="/etc/modules-load.d/vfio.conf"
VIRSH="virsh --connect qemu:///system"

# --- Saída colorida ----------------------------------------------------------
if [ -t 1 ]; then
    C_VERDE=$'\033[0;32m'; C_AMARELO=$'\033[0;33m'; C_VERMELHO=$'\033[0;31m'
    C_AZUL=$'\033[0;36m';  C_NEGRITO=$'\033[1m';    C_RESET=$'\033[0m'
else
    C_VERDE=""; C_AMARELO=""; C_VERMELHO=""; C_AZUL=""; C_NEGRITO=""; C_RESET=""
fi

info()   { echo "${C_AZUL}[info]${C_RESET} $*"; }
ok()     { echo "${C_VERDE}[ ok ]${C_RESET} $*"; }
aviso()  { echo "${C_AMARELO}[aviso]${C_RESET} $*"; }
erro()   { echo "${C_VERMELHO}[erro]${C_RESET} $*" >&2; }
titulo() { echo; echo "${C_NEGRITO}==== $* ====${C_RESET}"; }
falhar() { erro "$*"; exit 1; }

# --- Raiz hermética opcional, exclusiva dos testes ---------------------------
# A produção nunca aceita redirecionamento de /etc, /vm ou /usr. O modo de
# teste só é ativado quando o próprio PATH fornece um sudo falso, regular,
# pertencente ao operador e localizado dentro da raiz temporária. Assim um
# sudo real jamais pode receber caminhos injetados pelo ambiente.
SISTEMA_RAIZ_TESTE=""
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

inicializar_raiz_teste

# Módulos de efeito do shell (seção 2.3). O carregamento é ordenado: boot.sh
# depende de caminho_sistema, das funções de saída e do provider de plataforma,
# todos já definidos acima. Nenhum módulo produz efeito ao ser sourceado.
# shellcheck source=lib/shell/boot.sh
source "$COMMON_DIR/shell/boot.sh"

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

APT_ATUALIZACOES_ERRO=""
APT_ATUALIZACOES_TOTAL=""
APT_DIST_INSTALACOES=""
APT_DIST_REMOCOES=""
APT_AUTOREMOVE_EXCLUSIVAS=""
apt_contar_atualizacoes() {
    # Simula, sem locale e sem locks, as duas classes de transação realmente
    # aplicadas pela etapa 10. O total deduplica nomes de pacote entre os dois
    # planos; as categorias são diagnóstico e não devem ser somadas.
    local saida_dist saida_autoremove resumo total instalacoes remocoes auto_exclusivas
    APT_ATUALIZACOES_ERRO=""
    APT_ATUALIZACOES_TOTAL=""
    APT_DIST_INSTALACOES=""
    APT_DIST_REMOCOES=""
    APT_AUTOREMOVE_EXCLUSIVAS=""
    command -v apt-get >/dev/null 2>&1 \
        || { APT_ATUALIZACOES_ERRO="apt-get não está disponível."; return 1; }
    if ! saida_dist="$(LC_ALL=C apt-get --simulate -o Debug::NoLocking=1 dist-upgrade 2>&1)"; then
        APT_ATUALIZACOES_ERRO="Falha ao simular dist-upgrade APT: ${saida_dist:-sem diagnóstico}."
        return 1
    fi
    if ! saida_autoremove="$(LC_ALL=C apt-get --simulate -o Debug::NoLocking=1 autoremove 2>&1)"; then
        APT_ATUALIZACOES_ERRO="Falha ao simular autoremove APT: ${saida_autoremove:-sem diagnóstico}."
        return 1
    fi
    resumo="$(awk '
        BEGIN { fase = "dist" }
        $0 == "__PASSTHROUGH_AUTOREMOVE__" { fase = "autoremove"; next }
        ($1 == "Inst" || $1 == "Remv") && NF >= 2 {
            pacote = $2
            todos[pacote] = 1
            if (fase == "dist") {
                dist[pacote] = 1
                if ($1 == "Inst") inst[pacote] = 1
                else remv[pacote] = 1
            } else {
                auto[pacote] = 1
            }
        }
        END {
            for (p in todos) total++
            for (p in inst) ni++
            for (p in remv) nr++
            for (p in auto) if (!(p in dist)) na++
            print total + 0, ni + 0, nr + 0, na + 0
        }
    ' <<< "$saida_dist"$'\n__PASSTHROUGH_AUTOREMOVE__\n'"$saida_autoremove")" \
        || { APT_ATUALIZACOES_ERRO="Falha ao analisar as simulações APT."; return 1; }
    read -r total instalacoes remocoes auto_exclusivas <<< "$resumo"
    [[ "$total" =~ ^[0-9]+$ && "$instalacoes" =~ ^[0-9]+$ \
       && "$remocoes" =~ ^[0-9]+$ && "$auto_exclusivas" =~ ^[0-9]+$ ]] \
        || { APT_ATUALIZACOES_ERRO="Resumo APT inválido: '$resumo'."; return 1; }
    APT_ATUALIZACOES_TOTAL="$total"
    APT_DIST_INSTALACOES="$instalacoes"
    APT_DIST_REMOCOES="$remocoes"
    APT_AUTOREMOVE_EXCLUSIVAS="$auto_exclusivas"
    printf '%s\n' "$total"
}

fwupd_classificar_resultado() {
    # Contrato do cliente fwupdmgr: 0=operação concluída e 2=nada a fazer.
    # O código 2 só é normal para consultas/aplicação de updates; refresh deve
    # concluir com zero. Qualquer outro status é falha operacional.
    local operacao="${1:-}" rc="${2:-}"
    [[ "$rc" =~ ^[0-9]+$ ]] || return 1
    case "$operacao:$rc" in
        refresh:0|get-updates:0|update:0) printf '%s\n' sucesso ;;
        get-updates:2|update:2) printf '%s\n' sem-atualizacoes ;;
        *) printf '%s\n' erro; return 1 ;;
    esac
}

# --- Inventário de hardware --------------------------------------------------
INVENTARIO_ERRO=""
INVENTARIO_DIFERENCAS=""
INVENTARIO_RESOLVIDO=""

modo_execucao_etapa02() {
    case "${1:-}" in
        ""|--redetectar) printf '%s\n' reiniciar ;;
        --verificar) printf '%s\n' verificar ;;
        *) return 1 ;;
    esac
}

resolver_ultimo_inventario() {
    # Imprime o inventário principal mais recente. O diretório opcional existe
    # para testes; em produção a única fonte é ~/inventario-hardware.
    local diretorio="${1:-${INVENTARIO_DIR:-$HOME/inventario-hardware}}"
    local ponteiro="$diretorio/ultimo-inventario.txt" alvo nome candidato
    local -a candidatos=()
    INVENTARIO_ERRO=""
    INVENTARIO_RESOLVIDO=""
    [ -d "$diretorio" ] \
        || { INVENTARIO_ERRO="Diretório de inventários não existe: $diretorio"; return 1; }

    if [ -L "$ponteiro" ]; then
        alvo="$(readlink -- "$ponteiro" 2>/dev/null || true)"
        # O gerador publica links relativos para um arquivo direto no diretório.
        # Isso impede escape por caminho absoluto, '..' ou subdiretórios.
        if [[ "$alvo" != */* ]] \
           && [[ "$alvo" =~ ^inventario-[0-9]{8}(-[0-9]{6}-[0-9]{9})?\.txt$ ]] \
           && [ -f "$diretorio/$alvo" ] && [ ! -L "$diretorio/$alvo" ] \
           && [ -r "$diretorio/$alvo" ] && [ -s "$diretorio/$alvo" ] \
           && validar_inventario_principal "$diretorio/$alvo"; then
            INVENTARIO_RESOLVIDO="$diretorio/$alvo"
            printf '%s\n' "$INVENTARIO_RESOLVIDO"
            return 0
        fi
        INVENTARIO_ERRO="Ponteiro de inventário inválido, quebrado, incompleto ou fora do diretório: $ponteiro"
        return 1
    elif [ -e "$ponteiro" ]; then
        INVENTARIO_ERRO="Ponteiro de inventário não é um link simbólico: $ponteiro"
        return 1
    fi

    # Sem ponteiro, recupera deterministicamente históricos completos nos
    # formatos novo e legado. Artefatos, links, vazios e parciais não entram.
    for candidato in "$diretorio"/inventario-*.txt; do
        [ -f "$candidato" ] && [ ! -L "$candidato" ] && [ -r "$candidato" ] && [ -s "$candidato" ] || continue
        nome="${candidato##*/}"
        [[ "$nome" =~ ^inventario-[0-9]{8}(-[0-9]{6}-[0-9]{9})?\.txt$ ]] || continue
        validar_inventario_principal "$candidato" || continue
        candidatos+=("$candidato")
    done
    if [ "${#candidatos[@]}" -gt 0 ]; then
        local chave data hora nanos
        local -a candidatos_ordenados=()
        for candidato in "${candidatos[@]}"; do
            nome="${candidato##*/}"
            if [[ "$nome" =~ ^inventario-([0-9]{8})\.txt$ ]]; then
                data="${BASH_REMATCH[1]}"; hora="000000"; nanos="000000000"
            else
                [[ "$nome" =~ ^inventario-([0-9]{8})-([0-9]{6})-([0-9]{9})\.txt$ ]] || continue
                data="${BASH_REMATCH[1]}"; hora="${BASH_REMATCH[2]}"; nanos="${BASH_REMATCH[3]}"
            fi
            chave="$data-$hora-$nanos"
            candidatos_ordenados+=("$chave|$candidato")
        done
        INVENTARIO_RESOLVIDO="$(printf '%s\n' "${candidatos_ordenados[@]}" | LC_ALL=C sort | tail -n1 | cut -d'|' -f2-)"
        INVENTARIO_ERRO=""
        printf '%s\n' "$INVENTARIO_RESOLVIDO"
        return 0
    fi
    [ -n "$INVENTARIO_ERRO" ] \
        || INVENTARIO_ERRO="Nenhum inventário principal válido e legível em $diretorio."
    return 1
}

validar_inventario_principal() {
    local arquivo="${1:-}" secao
    INVENTARIO_ERRO=""
    [ -f "$arquivo" ] && [ ! -L "$arquivo" ] && [ -r "$arquivo" ] && [ -s "$arquivo" ] \
        || { INVENTARIO_ERRO="Inventário inválido, vazio ou ilegível: ${arquivo:-vazio}"; return 1; }
    for secao in '== CPU ==' '== RAM ==' '== PCI ==' '== BLOCK DEVICES =='; do
        grep -Fqx -- "$secao" "$arquivo" \
            || { INVENTARIO_ERRO="Inventário incompleto: seção '$secao' ausente em $arquivo."; return 1; }
    done
}

INVENTARIO_PUBLICADO=""
publicar_inventario_completo() {
    # Publica um temporário já concluído e só então troca atomicamente o
    # ponteiro. O timestamp opcional torna o contrato testável sem relógio real.
    local temporario="${1:-}" diretorio="${2:-}" timestamp="${3:-$(date +%Y%m%d-%H%M%S-%N)}"
    local diretorio_real temporario_dir_real arquivo tmp_link
    INVENTARIO_ERRO=""
    INVENTARIO_PUBLICADO=""
    [ -d "$diretorio" ] \
        || { INVENTARIO_ERRO="Diretório de inventários não existe: ${diretorio:-vazio}"; return 1; }
    validar_inventario_principal "$temporario" || return 1
    [[ "$timestamp" =~ ^[0-9]{8}-[0-9]{6}-[0-9]{9}$ ]] \
        || { INVENTARIO_ERRO="Timestamp inválido para publicação: $timestamp"; return 1; }
    diretorio_real="$(readlink -f -- "$diretorio")" || return 1
    temporario_dir_real="$(readlink -f -- "$(dirname -- "$temporario")")" || return 1
    [ "$temporario_dir_real" = "$diretorio_real" ] \
        || { INVENTARIO_ERRO="O temporário precisa estar dentro de $diretorio."; return 1; }

    arquivo="$diretorio/inventario-${timestamp}.txt"
    tmp_link="$diretorio/.ultimo-inventario.tmp.$timestamp"
    [ ! -e "$arquivo" ] && [ ! -L "$arquivo" ] \
        || { INVENTARIO_ERRO="Nome de inventário já existe: $arquivo"; return 1; }
    [ ! -e "$tmp_link" ] && [ ! -L "$tmp_link" ] \
        || { INVENTARIO_ERRO="Temporário do ponteiro já existe: $tmp_link"; return 1; }

    mv -- "$temporario" "$arquivo" \
        || { INVENTARIO_ERRO="Não foi possível publicar o inventário completo."; return 1; }
    if ! ln -s -- "${arquivo##*/}" "$tmp_link"; then
        INVENTARIO_ERRO="Inventário publicado, mas não foi possível preparar o novo ponteiro; o anterior foi preservado."
        return 1
    fi
    if ! mv -Tf -- "$tmp_link" "$diretorio/ultimo-inventario.txt"; then
        rm -f -- "$tmp_link"
        INVENTARIO_ERRO="Inventário publicado, mas não foi possível atualizar o ponteiro; o anterior foi preservado."
        return 1
    fi
    INVENTARIO_PUBLICADO="$arquivo"
    printf '%s\n' "$arquivo"
}

normalizar_identidade_hardware_atual() {
    # Formato estável, deliberadamente sem drivers, montagens, nomes /dev/sdX
    # ou outros dados voláteis. LC_ALL=C torna rótulos e ordenação previsíveis.
    local lscpu_saida chave valor ram_kib
    lscpu_saida="$(LC_ALL=C lscpu)" || return 1
    for chave in Architecture 'CPU(s)' 'On-line CPU(s) list' 'Thread(s) per core' \
                 'Core(s) per socket' 'Socket(s)' 'Model name'; do
        valor="$(awk -F: -v chave="$chave" '$1 == chave {sub(/^[[:space:]]+/, "", $2); print $2; exit}' <<< "$lscpu_saida")"
        printf 'CPU|%s|%s\n' "$chave" "$valor"
    done
    ram_kib="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)"
    [[ "$ram_kib" =~ ^[0-9]+$ ]] || return 1
    printf 'RAM_MIB|%s\n' "$((ram_kib / 1024))"
    LC_ALL=C lspci -Dnn | awk '
        {
            bdf=$1; classe=""; id=""
            for (i=2; i<=NF; i++) {
                if ($i ~ /^\[[[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]]\]:$/ && classe == "") {
                    classe=$i; gsub(/[\[\]:]/, "", classe)
                } else if ($i ~ /^\[[[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]]:[[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]]\]/) {
                    id=$i; gsub(/[\[\]]/, "", id)
                }
            }
            if (bdf != "" && classe != "" && id != "") print "PCI|" bdf "|" classe "|" id
        }
    ' | LC_ALL=C sort
    LC_ALL=C lsblk -bdnP -o SIZE,MODEL,SERIAL,TYPE | awk '
        /TYPE="disk"/ {
            linha=$0; sub(/^SIZE=/, "BYTES=", linha)
            gsub(/[[:space:]]+/, " ", linha); print "DISK|" linha
        }
    ' | LC_ALL=C sort
}

extrair_identidade_inventario() {
    local arquivo="$1" identidade
    identidade="$(awk '/^== HARDWARE IDENTITY ==$/ {captura=1; next} /^== / {if (captura) exit} captura && /^(CPU\||RAM_MIB\||PCI\||DISK\|)/ {print}' "$arquivo")"
    if [ -n "$identidade" ]; then
        printf '%s\n' "$identidade"
        return 0
    fi

    # Compatibilidade com relatórios anteriores à seção normalizada. Só os
    # campos estáveis são extraídos; se algum conjunto não puder ser provado,
    # a comparação posterior falha fechada e pede uma nova coleta.
    awk '
        function tamanho_em_bytes(texto, numero, unidade, mult) {
            numero=texto + 0
            unidade=substr(texto, length(texto), 1)
            mult=1
            if (unidade == "K") mult=1024
            else if (unidade == "M") mult=1048576
            else if (unidade == "G") mult=1073741824
            else if (unidade == "T") mult=1099511627776
            else if (unidade == "P") mult=1125899906842624
            else unidade=""
            if (unidade == "") return sprintf("%.0f", numero)
            return sprintf("%.0f", numero * mult)
        }
        /^== CPU ==$/ {secao="cpu"; next}
        /^== RAM ==$/ {secao="ram"; next}
        /^== PCI ==$/ {secao="pci"; next}
        /^== BLOCK DEVICES ==$/ {secao="disk"; cabecalho=""; next}
        /^== / {secao=""}
        secao == "cpu" && index($0, ":") {
            chave=$0; sub(/:.*/, "", chave); gsub(/^[[:space:]]+|[[:space:]]+$/, "", chave)
            if (chave == "Architecture" || chave == "CPU(s)" || chave == "On-line CPU(s) list" ||
                chave == "Thread(s) per core" || chave == "Core(s) per socket" ||
                chave == "Socket(s)" || chave == "Model name") {
                valor=$0; sub(/^[^:]*:[[:space:]]*/, "", valor)
                cpu[chave]=valor
            }
        }
        secao == "ram" && /^[[:space:]]*Size:[[:space:]]*[0-9]+[[:space:]]+(MB|GB|TB)/ {
            valor=$2 + 0; unidade=$3
            if (unidade == "GB") valor *= 1024
            else if (unidade == "TB") valor *= 1048576
            ram += valor
        }
        secao == "pci" && /^([[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]]:)?[[:xdigit:]][[:xdigit:]]:[[:xdigit:]][[:xdigit:]]\.[0-7][[:space:]]/ {
            bdf=$1
            if (bdf !~ /^[[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]]:/) bdf="0000:" bdf
            classe=""; id=""
            for (i=2; i<=NF; i++) {
                if ($i ~ /^\[[[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]]\]:$/ && classe == "") {
                    classe=$i; gsub(/[\[\]:]/, "", classe)
                } else if ($i ~ /^\[[[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]]:[[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]]\]/) {
                    id=$i; gsub(/[\[\]]/, "", id)
                }
            }
            if (classe != "" && id != "") pci[++npci]="PCI|" bdf "|" classe "|" id
        }
        secao == "disk" && cabecalho == "" && /NAME/ && /SIZE/ && /TYPE/ && /MODEL/ && /SERIAL/ {
            cabecalho=$0
            psize=index(cabecalho, "SIZE"); ptype=index(cabecalho, "TYPE")
            pmodel=index(cabecalho, "MODEL"); pserial=index(cabecalho, "SERIAL")
            next
        }
        secao == "disk" && cabecalho != "" {
            tipo=substr($0, ptype, pmodel-ptype); gsub(/^[[:space:]]+|[[:space:]]+$/, "", tipo)
            if (tipo == "disk") {
                tamanho=substr($0, psize, ptype-psize); modelo=substr($0, pmodel, pserial-pmodel); serial=substr($0, pserial)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", tamanho)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", modelo)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", serial)
                disco[++ndisco]="DISK|BYTES=\"" tamanho_em_bytes(tamanho) "\" MODEL=\"" modelo "\" SERIAL=\"" serial "\" TYPE=\"disk\""
            }
        }
        END {
            ordem[1]="Architecture"; ordem[2]="CPU(s)"; ordem[3]="On-line CPU(s) list"
            ordem[4]="Thread(s) per core"; ordem[5]="Core(s) per socket"
            ordem[6]="Socket(s)"; ordem[7]="Model name"
            for (i=1; i<=7; i++) print "CPU|" ordem[i] "|" cpu[ordem[i]]
            if (ram > 0) print "RAM_MIB|" ram
            for (i=1; i<=npci; i++) print pci[i]
            for (i=1; i<=ndisco; i++) print disco[i]
        }
    ' "$arquivo" | {
        # CPU mantém ordem semântica; os dois inventários de conjuntos precisam
        # da mesma ordem C usada pela coleta nova.
        awk '/^CPU\||^RAM_MIB\|/ {print; next} /^PCI\|/ {pci[++np]=$0; next} /^DISK\|/ {disk[++nd]=$0} END {
            for (i=1; i<=np; i++) print pci[i] | "LC_ALL=C sort"
            close("LC_ALL=C sort")
            for (i=1; i<=nd; i++) print disk[i] | "LC_ALL=C sort"
            close("LC_ALL=C sort")
        }'
    }
}

comparar_inventario_com_hardware() {
    # O segundo argumento é uma fotografia normalizada opcional, usada apenas
    # por testes. Em produção ela é sempre coletada novamente do kernel.
    local arquivo="${1:-}" atual="${2:-}" esperado ram_antiga ram_atual tolerancia diferencas=""
    INVENTARIO_DIFERENCAS=""
    validar_inventario_principal "$arquivo" || return 1
    esperado="$(extrair_identidade_inventario "$arquivo")"
    if [ -z "$(grep '^CPU|' <<< "$esperado")" ] \
       || [ -z "$(grep '^RAM_MIB|' <<< "$esperado")" ] \
       || [ -z "$(grep '^PCI|' <<< "$esperado")" ] \
       || [ -z "$(grep '^DISK|' <<< "$esperado")" ]; then
        INVENTARIO_ERRO="Inventário sem identidade suficiente para comparação; execute novamente a etapa 00."
        return 1
    fi
    [ -n "$atual" ] || atual="$(normalizar_identidade_hardware_atual)" \
        || { INVENTARIO_ERRO="Não foi possível obter a identidade atual do hardware."; return 1; }

    if [ "$(grep '^CPU|' <<< "$esperado")" != "$(grep '^CPU|' <<< "$atual")" ]; then
        diferencas+="CPU: identidade ou topologia mudou."$'\n'
    fi
    ram_antiga="$(awk -F'|' '$1 == "RAM_MIB" {print $2; exit}' <<< "$esperado")"
    ram_atual="$(awk -F'|' '$1 == "RAM_MIB" {print $2; exit}' <<< "$atual")"
    if [[ "$ram_antiga" =~ ^[0-9]+$ ]] && [[ "$ram_atual" =~ ^[0-9]+$ ]]; then
        tolerancia=$((ram_antiga / 20))
        [ "$tolerancia" -ge 1024 ] || tolerancia=1024
        if [ "$ram_atual" -lt $((ram_antiga - tolerancia)) ] \
           || [ "$ram_atual" -gt $((ram_antiga + tolerancia)) ]; then
            diferencas+="RAM: inventário=${ram_antiga} MiB, atual=${ram_atual} MiB (tolerância=${tolerancia} MiB)."$'\n'
        fi
    else
        diferencas+="RAM: total não pôde ser comparado."$'\n'
    fi
    if [ "$(grep '^PCI|' <<< "$esperado")" != "$(grep '^PCI|' <<< "$atual")" ]; then
        diferencas+="PCI: conjunto normalizado de dispositivos mudou."$'\n'
    fi
    if [ "$(grep '^DISK|' <<< "$esperado")" != "$(grep '^DISK|' <<< "$atual")" ]; then
        diferencas+="Discos: modelo, serial ou tamanho mudou."$'\n'
    fi
    if [ -n "$diferencas" ]; then
        INVENTARIO_DIFERENCAS="${diferencas%$'\n'}"
        INVENTARIO_ERRO="O hardware atual diverge do último inventário completo."
        return 1
    fi
}

# --- Configuração central (passthrough.conf) ---------------------------------
# O arquivo é tratado como DADOS, nunca como código shell. Somente as chaves
# conhecidas abaixo e literais simples são aceitos; command substitution, eval,
# expansões de variáveis e diretivas shell são rejeitados antes de qualquer uso.
CHAVES_CONF_PERMITIDAS=(
    USUARIO_LINUX VM_NAME BOOTLOADER VM_STORAGE_GROUP
    GPU_PCI_ID GPU_AUDIO_PCI_ID GPU_VENDOR_DEVICE_ID GPU_AUDIO_VENDOR_DEVICE_ID
    IOMMU_GROUP_GPU DM_SERVICE
    NVME_DEVICE WORKING_DISK_PATH WORKING_DISK_DISPENSADO
    HD1_BY_ID_PATH HD1_DISPENSADO
    QCOW2_PATH QCOW2_TAMANHO VM_RAM_MB VM_VCPUS VM_CORES VM_THREADS
    CPUS_VM CPUS_HOST HUGEPAGES_1G ISO_WINDOWS ISO_VIRTIO
    REDE_MODO INTERFACE_FISICA REDE_BRIDGE REDE_LIBVIRT
    REDE_BRIDGE_LIBVIRT REDE_NAT_CIDR VM_NIC_MAC VM_IP_FIXO IP_FIXO_HOST
    TRANSFER_USER AIRLOCK_DIR AIRLOCK_BIND
    BACKUPS_VM_DIR
)

# REQ-WAIVERS (decidido em I4.8): AIRLOCK_DISPENSADO e BACKUP_DISPENSADO saíram
# da allowlist porque nunca alteraram pré-requisito, status ou execução. O core
# continua aceitando as linhas para não derrubar configuração existente, sem
# expor o valor, e a etapa 02 remove as linhas na migração. As duas dispensas
# que permanecem (workingDisk e HD1) têm efeito real e testado.
CHAVES_CONF_DEPRECIADAS=(AIRLOCK_DISPENSADO BACKUP_DISPENSADO)

chave_conf_permitida() {
    local procurada="${1:-}" chave
    for chave in "${CHAVES_CONF_PERMITIDAS[@]}"; do
        [ "$chave" = "$procurada" ] && return 0
    done
    return 1
}

pci_bdf_valido() {
    local valor="${1:-}"
    [[ "$valor" =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]]
}

pci_vendor_device_valido() {
    local valor="${1:-}"
    [[ "$valor" =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{4}$ ]]
}

pci_vendor_device_atual() {
    local bdf="${1,,}" base="/sys/bus/pci/devices/${1,,}" vendor device
    pci_bdf_valido "$bdf" || return 1
    [ -r "$base/vendor" ] && [ -r "$base/device" ] || return 1
    IFS= read -r vendor < "$base/vendor" || return 1
    IFS= read -r device < "$base/device" || return 1
    vendor="${vendor#0x}"
    device="${device#0x}"
    pci_vendor_device_valido "$vendor:$device" || return 1
    printf '%s:%s\n' "${vendor,,}" "${device,,}"
}

IOMMU_ERRO=""
IOMMU_GRUPO_ATUAL=""
IOMMU_MEMBROS=""
validar_grupo_iommu_gpu() {
    # validar_grupo_iommu_gpu GPU_BDF AUDIO_BDF GRUPO_ESPERADO GPU_VID_DID AUDIO_VID_DID
    # Aceita somente as funções autorizadas e bridges PCI (classe base 0x06).
    local gpu="${1,,}" audio="${2,,}" esperado="${3:-}"
    local gpu_id="${4,,}" audio_id="${5,,}" link grupo membro bdf classe id_atual
    local restaurar_nullglob=0
    local -a membros=()
    IOMMU_ERRO=""
    IOMMU_GRUPO_ATUAL=""
    IOMMU_MEMBROS=""

    pci_bdf_valido "$gpu" \
        || { IOMMU_ERRO="GPU_PCI_ID inválido: '${gpu:-vazio}'."; return 1; }
    [ -z "$audio" ] || pci_bdf_valido "$audio" \
        || { IOMMU_ERRO="GPU_AUDIO_PCI_ID inválido: '$audio'."; return 1; }
    [ -z "$esperado" ] || inteiro_na_faixa "$esperado" 0 65535 \
        || { IOMMU_ERRO="IOMMU_GROUP_GPU persistido é inválido: '$esperado'."; return 1; }

    link="/sys/bus/pci/devices/$gpu/iommu_group"
    [ -L "$link" ] \
        || { IOMMU_ERRO="GPU $gpu ausente ou sem grupo IOMMU."; return 1; }
    grupo="$(basename -- "$(readlink -f -- "$link" 2>/dev/null)")" \
        || { IOMMU_ERRO="Não foi possível resolver o grupo IOMMU da GPU $gpu."; return 1; }
    inteiro_na_faixa "$grupo" 0 65535 \
        || { IOMMU_ERRO="Grupo IOMMU resolvido é inválido: '$grupo'."; return 1; }
    IOMMU_GRUPO_ATUAL="$grupo"
    if [ -n "$esperado" ] && [ "$((10#$grupo))" -ne "$((10#$esperado))" ]; then
        IOMMU_ERRO="A GPU mudou do grupo IOMMU persistido $esperado para $grupo; execute uma redetecção consciente."
        return 1
    fi

    if [ -n "$audio" ]; then
        link="/sys/bus/pci/devices/$audio/iommu_group"
        [ -L "$link" ] \
            || { IOMMU_ERRO="Função de áudio $audio ausente ou sem grupo IOMMU."; return 1; }
        [ "$(basename -- "$(readlink -f -- "$link" 2>/dev/null)")" = "$grupo" ] \
            || { IOMMU_ERRO="GPU $gpu e áudio $audio não pertencem ao mesmo grupo IOMMU."; return 1; }
    fi

    if [ -n "$gpu_id" ]; then
        id_atual="$(pci_vendor_device_atual "$gpu")" \
            || { IOMMU_ERRO="Não foi possível ler vendor/device da GPU $gpu."; return 1; }
        [ "$id_atual" = "$gpu_id" ] \
            || { IOMMU_ERRO="O BDF $gpu agora identifica $id_atual, não a GPU autorizada $gpu_id."; return 1; }
    fi
    if [ -n "$audio" ] && [ -n "$audio_id" ]; then
        id_atual="$(pci_vendor_device_atual "$audio")" \
            || { IOMMU_ERRO="Não foi possível ler vendor/device do áudio $audio."; return 1; }
        [ "$id_atual" = "$audio_id" ] \
            || { IOMMU_ERRO="O BDF $audio agora identifica $id_atual, não o áudio autorizado $audio_id."; return 1; }
    fi

    shopt -q nullglob || { shopt -s nullglob; restaurar_nullglob=1; }
    membros=("/sys/kernel/iommu_groups/$grupo/devices/"*)
    [ "$restaurar_nullglob" -eq 0 ] || shopt -u nullglob
    [ "${#membros[@]}" -gt 0 ] \
        || { IOMMU_ERRO="O grupo IOMMU $grupo não possui membros legíveis."; return 1; }
    for membro in "${membros[@]}"; do
        bdf="${membro##*/}"
        IOMMU_MEMBROS="${IOMMU_MEMBROS:+$IOMMU_MEMBROS }$bdf"
        [ "$bdf" = "$gpu" ] && continue
        [ -n "$audio" ] && [ "$bdf" = "$audio" ] && continue
        [ -r "/sys/bus/pci/devices/$bdf/class" ] \
            || { IOMMU_ERRO="Não foi possível classificar o membro $bdf do grupo $grupo."; return 1; }
        IFS= read -r classe < "/sys/bus/pci/devices/$bdf/class" || return 1
        [[ "${classe,,}" == 0x06* ]] && continue
        IOMMU_ERRO="Endpoint não autorizado $bdf (classe $classe) compartilha o grupo IOMMU $grupo."
        return 1
    done
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

WORKING_DISK_ERRO=""
WORKING_DISK_SOURCE=""
WORKING_DISK_FSTYPE=""
validar_working_disk_montado() {
    # O operador monta o workingDisk externamente. Esta função apenas comprova
    # que o caminho configurado é canônico, um mountpoint ativo e coleta um
    # diagnóstico; nunca cria diretório, monta, formata ou altera o fstab.
    local caminho="${1:-}" alvo caminho_lexico caminho_fisico
    WORKING_DISK_ERRO=""
    WORKING_DISK_SOURCE=""
    WORKING_DISK_FSTYPE=""
    caminho_absoluto_seguro "$caminho" \
        || { WORKING_DISK_ERRO="WORKING_DISK_PATH inseguro: '${caminho:-vazio}'."; return 1; }
    [ -d "$caminho" ] \
        || { WORKING_DISK_ERRO="WORKING_DISK_PATH não é um diretório existente: $caminho"; return 1; }
    command -v readlink >/dev/null 2>&1 \
        && command -v mountpoint >/dev/null 2>&1 \
        && command -v findmnt >/dev/null 2>&1 \
        || { WORKING_DISK_ERRO="readlink/mountpoint/findmnt são necessários para validar o workingDisk."; return 1; }
    caminho_lexico="$(_caminho_lexico_normalizado "$caminho")" \
        || { WORKING_DISK_ERRO="Não foi possível normalizar WORKING_DISK_PATH: $caminho"; return 1; }
    caminho_fisico="$(readlink -f -- "$caminho" 2>/dev/null)" \
        || { WORKING_DISK_ERRO="Não foi possível canonicalizar WORKING_DISK_PATH: $caminho"; return 1; }
    [ "$caminho" = "$caminho_lexico" ] && [ "$caminho_fisico" = "$caminho" ] \
        || { WORKING_DISK_ERRO="WORKING_DISK_PATH precisa ser canônico e não pode conter componentes simbólicos: $caminho"; return 1; }
    mountpoint -q -- "$caminho" \
        || { WORKING_DISK_ERRO="workingDisk não está montado exatamente em $caminho."; return 1; }
    alvo="$(findmnt -rn --raw --mountpoint "$caminho" --output TARGET 2>/dev/null)" \
        || { WORKING_DISK_ERRO="findmnt não confirmou o mountpoint exato $caminho."; return 1; }
    [ "$alvo" = "$caminho" ] \
        || { WORKING_DISK_ERRO="mountpoint divergente: configurado '$caminho', ativo '${alvo:-desconhecido}'."; return 1; }
    WORKING_DISK_SOURCE="$(findmnt -rn --raw --mountpoint "$caminho" --output SOURCE 2>/dev/null)" \
        || { WORKING_DISK_ERRO="findmnt não informou a origem de $caminho."; return 1; }
    WORKING_DISK_FSTYPE="$(findmnt -rn --raw --mountpoint "$caminho" --output FSTYPE 2>/dev/null)" \
        || { WORKING_DISK_ERRO="findmnt não informou o filesystem de $caminho."; return 1; }
    [ -n "$WORKING_DISK_SOURCE" ] && [ -n "$WORKING_DISK_FSTYPE" ] \
        || { WORKING_DISK_ERRO="Diagnóstico incompleto do workingDisk em $caminho."; return 1; }
}

WORKING_DISK_CONTENCAO_ERRO=""
WORKING_DISK_CAMINHO_FISICO=""
WORKING_DISK_BASE_FISICA=""
WORKING_DISK_CONTENCAO_ESTADO=""
caminho_dentro_working_disk() {
    # Retornos: 0=dentro (inclusive alias externo que resolve para dentro),
    # 1=fora comprovado, 2=inválido/escape simbólico. Destinos podem não existir.
    local caminho="${1:-}" base="${2:-${WORKING_DISK_PATH:-}}"
    local caminho_lexico base_lexica caminho_fisico base_fisica
    local lexical_dentro=0 fisico_dentro=0
    WORKING_DISK_CONTENCAO_ERRO=""
    WORKING_DISK_CAMINHO_FISICO=""
    WORKING_DISK_BASE_FISICA=""
    WORKING_DISK_CONTENCAO_ESTADO=""
    if ! caminho_absoluto_seguro "$caminho" || ! caminho_absoluto_seguro "$base"; then
        WORKING_DISK_CONTENCAO_ERRO="Destino ou WORKING_DISK_PATH possui sintaxe insegura: destino='${caminho:-vazio}', base='${base:-vazia}'."
        WORKING_DISK_CONTENCAO_ESTADO=erro
        return 2
    fi
    command -v readlink >/dev/null 2>&1 \
        || { WORKING_DISK_CONTENCAO_ERRO="readlink é necessário para comprovar a contenção no workingDisk."; WORKING_DISK_CONTENCAO_ESTADO=erro; return 2; }
    caminho_lexico="$(_caminho_lexico_normalizado "$caminho")" \
        && base_lexica="$(_caminho_lexico_normalizado "$base")" \
        || { WORKING_DISK_CONTENCAO_ERRO="Não foi possível normalizar destino/base do workingDisk."; WORKING_DISK_CONTENCAO_ESTADO=erro; return 2; }
    caminho_fisico="$(readlink -m -- "$caminho" 2>/dev/null)" \
        && base_fisica="$(readlink -m -- "$base" 2>/dev/null)" \
        || { WORKING_DISK_CONTENCAO_ERRO="Não foi possível resolver fisicamente destino/base do workingDisk."; WORKING_DISK_CONTENCAO_ESTADO=erro; return 2; }
    WORKING_DISK_CAMINHO_FISICO="$caminho_fisico"
    WORKING_DISK_BASE_FISICA="$base_fisica"
    if [ "$base" != "$base_lexica" ] || [ "$base_fisica" != "$base_lexica" ]; then
        WORKING_DISK_CONTENCAO_ERRO="WORKING_DISK_PATH precisa ser canônico e não pode conter componentes simbólicos: $base"
        WORKING_DISK_CONTENCAO_ESTADO=erro
        return 2
    fi
    _caminho_igual_ou_filho "$caminho_lexico" "$base_lexica" && lexical_dentro=1
    _caminho_igual_ou_filho "$caminho_fisico" "$base_fisica" && fisico_dentro=1
    if [ "$lexical_dentro" -eq 1 ] && [ "$fisico_dentro" -ne 1 ]; then
        WORKING_DISK_CONTENCAO_ERRO="Destino lexicalmente interno ao workingDisk resolve para fora dele: '$caminho' -> '$caminho_fisico'."
        WORKING_DISK_CONTENCAO_ESTADO=erro
        return 2
    fi
    if [ "$fisico_dentro" -eq 1 ]; then
        WORKING_DISK_CONTENCAO_ESTADO=dentro
        return 0
    fi
    WORKING_DISK_CONTENCAO_ESTADO=fora
    return 1
}

# Artefatos entregues à gramática `--disk` do virt-install ficam diretamente
# em /vm e nunca contêm vírgula (delimitador interno dessa opção). Além de
# evitar reinterpretação, a raiz única pode ser selada contra rename no open.
caminho_artefato_vm_logico_valido() {
    local caminho="${1:-}" nome
    caminho_absoluto_seguro "$caminho" || return 1
    [[ "$caminho" != *,* && "$caminho" == /vm/* ]] || return 1
    nome="${caminho#/vm/}"
    [ -n "$nome" ] && [[ "$nome" != */* ]] && [ "$caminho" = "/vm/$nome" ]
}

caminho_qcow2_logico_valido() {
    caminho_artefato_vm_logico_valido "${1:-}"
}

ARMAZENAMENTO_ERRO=""
ARMAZENAMENTO_CAMINHO_FISICO=""
ARMAZENAMENTO_FINGERPRINT=""
ARMAZENAMENTO_QCOW2_ESTADO=""

_caminho_configurado_fisico() {
    local caminho="${1:-}"
    caminho_absoluto_seguro "$caminho" || return 1
    caminho_sistema "$caminho"
}

_armazenamento_caminho_existente_canonico() {
    local caminho="${1:-}" pai real_pai real_alvo
    [ -f "$caminho" ] && [ ! -L "$caminho" ] || return 1
    pai="$(dirname -- "$caminho")" || return 1
    real_pai="$(readlink -f -- "$pai" 2>/dev/null)" || return 1
    real_alvo="$(readlink -f -- "$caminho" 2>/dev/null)" || return 1
    [ "$real_pai" = "$pai" ] && [ "$real_alvo" = "$caminho" ]
}

armazenamento_fingerprint_atual() {
    local caminho="${1:-}"
    _armazenamento_caminho_existente_canonico "$caminho" || return 1
    stat -c '%d:%i:%s:%Y:%f:%h' -- "$caminho" 2>/dev/null
}

validar_qcow2_configurado() {
    # Aceita estado existente ou ausente, mas nunca link, hardlink, componente
    # simbólico, formato diferente de qcow2 ou metadados que exigiriam reparo
    # privilegiado. Define caminho físico/fingerprint/estado para o chamador.
    local logico="${1:-}" grupo="${2:-}" fisico raiz real_raiz pai estado info links
    ARMAZENAMENTO_ERRO=""
    ARMAZENAMENTO_CAMINHO_FISICO=""
    ARMAZENAMENTO_FINGERPRINT=""
    ARMAZENAMENTO_QCOW2_ESTADO=""
    caminho_qcow2_logico_valido "$logico" \
        || { ARMAZENAMENTO_ERRO="QCOW2_PATH deve ser canônico e um filho direto de /vm: '$logico'."; return 1; }
    nome_grupo_vm_dedicado_valido "$grupo" \
        || { ARMAZENAMENTO_ERRO="Grupo de armazenamento inválido: '$grupo'."; return 1; }
    fisico="$(_caminho_configurado_fisico "$logico")" \
        || { ARMAZENAMENTO_ERRO="Não foi possível mapear QCOW2_PATH."; return 1; }
    raiz="$(caminho_sistema /vm)" \
        || { ARMAZENAMENTO_ERRO="Não foi possível resolver /vm."; return 1; }
    [ -d "$raiz" ] && [ ! -L "$raiz" ] \
        || { ARMAZENAMENTO_ERRO="/vm precisa ser diretório real, não link."; return 1; }
    real_raiz="$(readlink -f -- "$raiz" 2>/dev/null)" \
        || { ARMAZENAMENTO_ERRO="Não foi possível canonicalizar /vm."; return 1; }
    [ "$real_raiz" = "$raiz" ] \
        || { ARMAZENAMENTO_ERRO="/vm contém componente simbólico ou não canônico."; return 1; }
    pai="$(dirname -- "$fisico")"
    [ "$pai" = "$raiz" ] \
        || { ARMAZENAMENTO_ERRO="QCOW2_PATH físico escapou da raiz /vm."; return 1; }
    [ ! -L "$fisico" ] \
        || { ARMAZENAMENTO_ERRO="QCOW2_PATH não pode ser link simbólico."; return 1; }
    ARMAZENAMENTO_CAMINHO_FISICO="$fisico"
    if [ ! -e "$fisico" ]; then
        ARMAZENAMENTO_QCOW2_ESTADO=ausente
        return 0
    fi
    _armazenamento_caminho_existente_canonico "$fisico" \
        || { ARMAZENAMENTO_ERRO="QCOW2 existente deve ser arquivo regular canônico, sem links em nenhum componente."; return 1; }
    links="$(stat -c '%h' -- "$fisico" 2>/dev/null)" \
        || { ARMAZENAMENTO_ERRO="Não foi possível inspecionar os links do QCOW2."; return 1; }
    [ "$links" = 1 ] \
        || { ARMAZENAMENTO_ERRO="QCOW2 com hardlinks foi recusado (nlink=$links)."; return 1; }
    estado="$(stat -c '%G:%a' -- "$fisico" 2>/dev/null)" \
        || { ARMAZENAMENTO_ERRO="Não foi possível inspecionar grupo/modo do QCOW2."; return 1; }
    [ "$estado" = "$grupo:660" ] \
        || { ARMAZENAMENTO_ERRO="QCOW2 está como $estado; esperado $grupo:660. Corrija-o manualmente após conferir o inode, sem executar esta etapa como root."; return 1; }
    command -v qemu-img >/dev/null 2>&1 \
        || { ARMAZENAMENTO_ERRO="qemu-img indisponível para validar o formato antes de sudo."; return 1; }
    info="$(qemu-img info --output=json "$fisico" 2>&1)" \
        || { ARMAZENAMENTO_ERRO="qemu-img recusou o arquivo: ${info:-sem diagnóstico}."; return 1; }
    grep -Eq '"format"[[:space:]]*:[[:space:]]*"qcow2"' <<< "$info" \
        || { ARMAZENAMENTO_ERRO="O arquivo existente não declara formato qcow2."; return 1; }
    ARMAZENAMENTO_FINGERPRINT="$(armazenamento_fingerprint_atual "$fisico")" \
        || { ARMAZENAMENTO_ERRO="Não foi possível fixar a identidade do QCOW2."; return 1; }
    ARMAZENAMENTO_QCOW2_ESTADO=existente
}

validar_iso_configurada() {
    # ISOs são somente leitura: não há cópia, chmod, chgrp nem ACL automática.
    # O acesso do QEMU é comprovado separadamente depois que sudo está disponível.
    local logico="${1:-}" fisico links
    ARMAZENAMENTO_ERRO=""
    ARMAZENAMENTO_CAMINHO_FISICO=""
    ARMAZENAMENTO_FINGERPRINT=""
    caminho_artefato_vm_logico_valido "$logico" \
        || { ARMAZENAMENTO_ERRO="ISO deve ser um filho direto canônico de /vm e não pode conter vírgula: '$logico'."; return 1; }
    fisico="$(_caminho_configurado_fisico "$logico")" \
        || { ARMAZENAMENTO_ERRO="Não foi possível mapear a ISO."; return 1; }
    [ ! -L "$fisico" ] \
        || { ARMAZENAMENTO_ERRO="ISO não pode ser link simbólico: $logico"; return 1; }
    _armazenamento_caminho_existente_canonico "$fisico" \
        || { ARMAZENAMENTO_ERRO="ISO deve ser arquivo regular canônico, sem componentes simbólicos: $logico"; return 1; }
    [ -r "$fisico" ] \
        || { ARMAZENAMENTO_ERRO="O operador não consegue ler a ISO: $logico"; return 1; }
    links="$(stat -c '%h' -- "$fisico" 2>/dev/null)" \
        || { ARMAZENAMENTO_ERRO="Não foi possível inspecionar a ISO: $logico"; return 1; }
    [ "$links" = 1 ] \
        || { ARMAZENAMENTO_ERRO="ISO com hardlinks foi recusada: $logico"; return 1; }
    ARMAZENAMENTO_CAMINHO_FISICO="$fisico"
    ARMAZENAMENTO_FINGERPRINT="$(armazenamento_fingerprint_atual "$fisico")" \
        || { ARMAZENAMENTO_ERRO="Não foi possível fixar a identidade da ISO: $logico"; return 1; }
}

ISO_OPCIONAL_ESTADO=""
ISO_OPCIONAL_ERRO=""
classificar_iso_opcional_conf() {
    # Classifica um caminho de ISO digitado ANTES de persisti-lo, com a mesma
    # política de salvar_conf/etapa 40 (filho direto canônico de /vm, sem
    # vírgula e sem links). Um prompt opcional consulta esta função para nunca
    # abortar dentro de salvar_conf por um caminho fora da política.
    # Estados em sucesso: vazia (sem valor), ausente (política ok, arquivo
    # ainda não existe; /vm nasce na etapa 13) e valida (arquivo regular ok).
    local logico="${1:-}" fisico
    ISO_OPCIONAL_ESTADO=""
    ISO_OPCIONAL_ERRO=""
    if [ -z "$logico" ]; then
        ISO_OPCIONAL_ESTADO=vazia
        return 0
    fi
    if ! caminho_artefato_vm_logico_valido "$logico"; then
        ISO_OPCIONAL_ERRO="Caminho recusado pela política de armazenamento: a ISO precisa ser um filho direto canônico de /vm, sem vírgula (ex.: /vm/Win11.iso); recebi '$logico'."
        return 1
    fi
    fisico="$(_caminho_configurado_fisico "$logico")" \
        || { ISO_OPCIONAL_ERRO="Não foi possível mapear a ISO: $logico"; return 1; }
    if [ ! -e "$fisico" ] && [ ! -L "$fisico" ]; then
        ISO_OPCIONAL_ESTADO=ausente
        return 0
    fi
    validar_iso_configurada "$logico" \
        || { ISO_OPCIONAL_ERRO="$ARMAZENAMENTO_ERRO"; return 1; }
    ISO_OPCIONAL_ESTADO=valida
}

CONF_ISO_NOVO_VALOR=""
perguntar_iso_valor_conf() {
    # Só decide o valor; não persiste. Separar a decisão da persistência é o que
    # permite reaproveitar exatamente este prompt na migração pré-parser de
    # REQ-CONF-ISO, onde a publicação precisa ser um único rename com todas as
    # chaves pendentes.
    # Publica CONF_ISO_NOVO_VALOR (vazio significa "decidir na etapa 40").
    local descricao="$1" caminho tentativas=0
    CONF_ISO_NOVO_VALOR=""
    while :; do
        caminho="$(perguntar "Caminho da $descricao em /vm (ENTER para informar depois, na etapa 40)" '')"
        caminho="${caminho/#\~/$HOME}"
        if [ -z "$caminho" ]; then
            return 0
        fi
        if classificar_iso_opcional_conf "$caminho"; then
            if [ "$ISO_OPCIONAL_ESTADO" = ausente ]; then
                aviso "Arquivo não encontrado: $caminho (ficará vazio; informe na etapa 40)."
                return 0
            fi
            CONF_ISO_NOVO_VALOR="$caminho"
            ok "$descricao validada sem links: $caminho"
            return 0
        fi
        aviso "$ISO_OPCIONAL_ERRO"
        info "Copie a ISO como operador para um nome direto e exclusivo em /vm (criado na etapa 13) e informe esse caminho, ou ENTER para decidir na etapa 40."
        tentativas=$((tentativas + 1))
        if [ "$tentativas" -ge 5 ]; then
            aviso "Cinco tentativas sem um caminho aceito; a $descricao ficará vazia (informe na etapa 40)."
            return 0
        fi
    done
}

perguntar_iso_opcional_conf() {
    # Prompt opcional de ISO da etapa 02. ENTER, arquivo ainda ausente ou cinco
    # recusas deixam a chave vazia para a etapa 40 exigir depois; somente um
    # caminho aceito pela política é persistido, então salvar_conf nunca
    # derruba a detecção por causa de uma ISO.
    local chave="$1" descricao="$2"
    perguntar_iso_valor_conf "$descricao"
    salvar_conf "$chave" "$CONF_ISO_NOVO_VALOR"
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

# validar_valor_conf mudou de lugar: o mapeamento chave -> tipo agora vive no
# módulo de configuração do core Python, e o wrapper público está junto das
# demais funções de configuração, mais abaixo. Os validadores primitivos
# (caminho, MAC, IPv4, lista de CPUs, interface) permanecem aqui porque são
# usados por prompts e por validação de dados de runtime, não só pelo schema.

_trim_espacos_conf() {
    local valor="$1"
    valor="${valor#"${valor%%[![:space:]]*}"}"
    valor="${valor%"${valor##*[![:space:]]}"}"
    REPLY="$valor"
}

_resto_conf_valido() {
    _trim_espacos_conf "$1"
    [ -z "$REPLY" ] || [[ "$REPLY" == \#* ]]
}

_decodificar_literal_conf() {
    # Define REPLY. Aceita "literal" com escapes inertes, 'literal' simples ou
    # literal não cotado restrito. Nada aqui é passado a eval/source.
    local bruto="$1" valor="" resto caractere escape=0 fechado=0 i
    _trim_espacos_conf "$bruto"
    bruto="$REPLY"
    [ -n "$bruto" ] || { REPLY=""; return 0; }

    if [ "${bruto:0:1}" = '"' ]; then
        for ((i = 1; i < ${#bruto}; i++)); do
            caractere="${bruto:i:1}"
            if [ "$escape" -eq 1 ]; then
                if [ "$caractere" = '\' ] || [ "$caractere" = '"' ] \
                   || [ "$caractere" = '$' ] || [ "$caractere" = '`' ]; then
                    valor+="$caractere"
                    escape=0
                    continue
                fi
                return 1
            fi
            if [ "$caractere" = '\' ]; then
                escape=1
            elif [ "$caractere" = '"' ]; then
                fechado=1
                resto="${bruto:$((i + 1))}"
                break
            else
                valor+="$caractere"
            fi
        done
        [ "$fechado" -eq 1 ] && [ "$escape" -eq 0 ] && _resto_conf_valido "$resto" || return 1
        REPLY="$valor"
        return 0
    fi

    if [ "${bruto:0:1}" = "'" ]; then
        for ((i = 1; i < ${#bruto}; i++)); do
            caractere="${bruto:i:1}"
            if [ "$caractere" = "'" ]; then
                fechado=1
                resto="${bruto:$((i + 1))}"
                break
            fi
            valor+="$caractere"
        done
        [ "$fechado" -eq 1 ] && _resto_conf_valido "$resto" || return 1
        REPLY="$valor"
        return 0
    fi

    valor="${bruto%%#*}"
    _trim_espacos_conf "$valor"
    valor="$REPLY"
    case "$valor" in
        *[![:alnum:]_./:@,+%=-]*) return 1 ;;
    esac
    REPLY="$valor"
}

# --- Fronteira de configuração: o core é a única implementação ----------------
# As funções públicas abaixo mantêm nome, argumentos, efeitos e mensagens de
# antes da migração. O que mudou é onde o schema mora: parsing, validação,
# serialização e publicação atômica passaram a ser do core Python. O caminho do
# conf é um LOCAL_IDENTIFIER e, pela seção 3.9, não entra em argv: a ponte passa
# o descritor do diretório e o basename viaja no payload.
#
# CHAVES_CONF_PERMITIDAS continua sendo a allowlist do canal de pares. Ela não é
# uma segunda autoridade sobre o schema: se divergir do core, a carga falha
# fechada, porque o core emitiria uma chave que a allowlist não autoriza.

CONF_DIRETORIO_ALVO=""
CONF_NOME_ALVO=""
CONF_PARES_PERMITIDAS=()

_conf_localizar_alvo() {
    # Separa o alvo em diretório e basename, sem resolver o link do arquivo.
    local caminho="${1:-$CONF_ARQUIVO}"
    CONF_DIRETORIO_ALVO=""
    CONF_NOME_ALVO=""
    case "$caminho" in
        */*)
            CONF_DIRETORIO_ALVO="${caminho%/*}"
            CONF_NOME_ALVO="${caminho##*/}"
            [ -n "$CONF_DIRETORIO_ALVO" ] || CONF_DIRETORIO_ALVO=/
            ;;
        *)
            CONF_DIRETORIO_ALVO="$(pwd -P)" || return 1
            CONF_NOME_ALVO="$caminho"
            ;;
    esac
    [ -n "$CONF_NOME_ALVO" ] || return 1
    return 0
}

_conf_allowlist_pares() {
    # Allowlist completa da resposta, derivada da própria allowlist do shell.
    local chave
    CONF_PARES_PERMITIDAS=(
        CORE_VERSION PROTOCOL_VERSION SUBCOMMAND
        EXISTS KEY_COUNT PRESENT_COUNT FINAL_NEWLINE LINE_COUNT
        CHANGED UPDATE_COUNT MIGRATED_COUNT REMOVED_COUNT INVALID_BEFORE
        PUBLISHED CREATED BYTES_WRITTEN SHA256
        MODE_OCTAL MODE_EXPOSES_OTHERS
        DEPRECATED_PRESENT DEPRECATED_WITH_VALUE DEPRECATED_KEYS
        RELATION_CONFLICTS RELATION_CONFLICT_KEYS
    )
    for chave in "${CHAVES_CONF_PERMITIDAS[@]}"; do
        CONF_PARES_PERMITIDAS+=("VALUE_$chave" "PRESENT_$chave")
    done
}

carregar_conf() {
    # Lê e valida a configuração pelo core. Chave ausente é desdefinida, para
    # que uma execução nunca herde valor de outra (protocolo NUL validado).
    local chave nome_valor nome_presente
    local -a payload=()
    _conf_localizar_alvo \
        || falhar "Caminho de configuração inválido: $CONF_ARQUIVO"
    if [ -L "$CONF_ARQUIVO" ]; then
        falhar "Configuração precisa ser um arquivo regular, não um link: $CONF_ARQUIVO"
    fi
    for chave in "${CHAVES_CONF_PERMITIDAS[@]}"; do
        unset "$chave"
    done
    [ -e "$CONF_ARQUIVO" ] || return 0
    _conf_allowlist_pares
    payload=(name "$CONF_NOME_ALVO")
    if ! python_core_config CONF_PARES_PERMITIDAS CFG_ config-load payload \
            "$CONF_DIRETORIO_ALVO"; then
        falhar "Configuração recusada em $CONF_ARQUIVO: $(_core_diagnostico 'schema fechado violado')"
    fi
    [ "${CFG_EXISTS:-0}" = 1 ] || return 0
    # Uma flag depreciada com valor mente sobre ter efeito; avisar é obrigatório
    # e a etapa 02 remove a linha. Um conflito de relação (caminho definido e
    # dispensa "sim") é reportado aqui e explicado pela etapa que o possui.
    if [ "${CFG_DEPRECATED_WITH_VALUE:-0}" != 0 ]; then
        aviso "Configuração usa dispensa sem efeito: ${CFG_DEPRECATED_KEYS//$'\n'/, }. Rode a etapa 02 para remover a linha."
    fi
    if [ "${CFG_RELATION_CONFLICTS:-0}" != 0 ]; then
        aviso "Configuração contraditória entre caminho e dispensa: ${CFG_RELATION_CONFLICT_KEYS//$'\n'/, }."
    fi
    # A configuração guarda identidade local (BDF, MAC, IP, caminhos): a seção
    # 3.9 exige arquivo do projeto em 0600. Um modo herdado de cópia manual
    # expõe isso a qualquer conta da máquina, então o aviso é obrigatório. A
    # próxima gravação aperta o modo automaticamente.
    # O aviso vale só para a configuração real do operador: o modelo versionado
    # é neutro por desenho e pode ser legível por todos.
    if [ "${CFG_MODE_EXPOSES_OTHERS:-0}" != 0 ] \
        && [ "$CONF_NOME_ALVO" = passthrough.conf ]; then
        aviso "Configuração legível por outros usuários (modo ${CFG_MODE_OCTAL:-?}): ela guarda identificadores do seu hardware."
        info "Corrija agora com: chmod 600 $CONF_ARQUIVO (a próxima gravação também aperta o modo)."
    fi
    for chave in "${CHAVES_CONF_PERMITIDAS[@]}"; do
        nome_presente="CFG_PRESENT_$chave"
        nome_valor="CFG_VALUE_$chave"
        if [ "${!nome_presente}" = 1 ]; then
            printf -v "$chave" '%s' "${!nome_valor}"
            # shellcheck disable=SC2163
            export "$chave"
        else
            unset "$chave"
        fi
    done
}

_conf_publicar() {
    # $@ = pares CHAVE VALOR. Schema, serialização e publicação atômica são do
    # core; aqui só entram a allowlist, a cardinalidade e o transporte.
    local chave valor
    local -a payload=()
    local -A vistas=()
    _conf_localizar_alvo \
        || falhar "Caminho de configuração inválido: $CONF_ARQUIVO"
    [ ! -L "$CONF_ARQUIVO" ] \
        || falhar "Recusando atualizar link simbólico: $CONF_ARQUIVO"
    payload=(name "$CONF_NOME_ALVO")
    while [ "$#" -gt 0 ]; do
        chave="$1"
        valor="$2"
        shift 2
        chave_conf_permitida "$chave" \
            || falhar "Chave de configuração não permitida: '$chave'."
        [ -z "${vistas[$chave]+definida}" ] \
            || falhar "Chave repetida no lote: '$chave'."
        vistas[$chave]=1
        payload+=("set_${chave,,}" "$valor")
    done
    _conf_allowlist_pares
    if ! python_core_config CONF_PARES_PERMITIDAS CFG_ config-publish payload \
            "$CONF_DIRETORIO_ALVO"; then
        falhar "Falha ao publicar a configuração: $(_core_diagnostico 'persistência recusada')"
    fi
}

_conf_publicar_migracao() {
    # $1 = nome do array com as chaves toleradas; demais = pares CHAVE VALOR.
    # A tolerância vale apenas para as chaves declaradas, e o core exige que
    # cada uma delas receba um novo valor: nenhum valor legado inválido pode
    # sobreviver à publicação.
    local _cpm_toleradas="${1:-}" chave valor lista=""
    local -a payload=()
    shift
    local -n _cpm_ref="$_cpm_toleradas"
    for chave in "${_cpm_ref[@]}"; do
        lista+="${lista:+$'\n'}$chave"
    done
    _conf_localizar_alvo \
        || { erro "Caminho de configuração inválido: $CONF_ARQUIVO"; return 1; }
    [ ! -L "$CONF_ARQUIVO" ] \
        || { erro "Recusando atualizar link simbólico: $CONF_ARQUIVO"; return 1; }
    payload=(name "$CONF_NOME_ALVO" migrate_keys "$lista")
    while [ "$#" -gt 0 ]; do
        chave="$1"
        valor="$2"
        shift 2
        chave_conf_permitida "$chave" \
            || { erro "Chave não permitida na migração: '$chave'."; return 1; }
        payload+=("set_${chave,,}" "$valor")
    done
    _conf_allowlist_pares
    python_core_config CONF_PARES_PERMITIDAS CFG_ config-publish payload \
        "$CONF_DIRETORIO_ALVO"
}

salvar_conf() {
    # Atualização atômica de uma chave, preservando comentários, ordem e modo.
    local chave="$1" valor="${2-}"
    [ "$#" -eq 2 ] || falhar "salvar_conf exige CHAVE e VALOR."
    _conf_publicar "$chave" "$valor"
    printf -v "$chave" '%s' "$valor"
    # shellcheck disable=SC2163
    export "$chave"
}

salvar_conf_lote() {
    # salvar_conf_lote CHAVE VALOR [CHAVE VALOR...]. Valida tudo primeiro e
    # publica o conjunto em um único rename, evitando relações CPU parcialmente
    # atualizadas se a etapa for interrompida.
    local i
    local -a entradas=("$@") chaves=() valores=()
    [ "$#" -ge 2 ] && [ $(( $# % 2 )) -eq 0 ] \
        || falhar "salvar_conf_lote exige pares CHAVE/VALOR."
    for ((i = 0; i < ${#entradas[@]}; i += 2)); do
        chaves+=("${entradas[$i]}")
        valores+=("${entradas[$((i + 1))]}")
    done
    _conf_publicar "${entradas[@]}"
    for i in "${!chaves[@]}"; do
        printf -v "${chaves[$i]}" '%s' "${valores[$i]}"
        # shellcheck disable=SC2163
        export "${chaves[$i]}"
    done
}

validar_valor_conf() {
    # API pública preservada. O schema vive no core: esta função consulta a
    # mesma implementação usada na carga e na publicação, sem tocar arquivo.
    local chave="${1:-}" valor="${2-}"
    local -a permitidas=(CORE_VERSION PROTOCOL_VERSION SUBCOMMAND KEY DATA_CLASS VALID)
    local -a payload=()
    chave_conf_permitida "$chave" || return 1
    payload=(key "$chave" value "$valor")
    python_core_pares_payload permitidas CFGVAL_ config-validate payload 2>/dev/null
}

CONF_MIGRACAO_DISPENSAS_REMOVIDAS=0
conf_migrar_dispensas_depreciadas() {
    # REQ-WAIVERS: remove as linhas das dispensas sem efeito. Configuração já
    # limpa é no-op exato. A remoção é publicada pelo mesmo rename atômico da
    # configuração, então nunca há estado intermediário.
    # Retornos: 0 = nada a fazer ou removido; 1 = erro.
    local chave lista=""
    local -a payload=()
    CONF_MIGRACAO_DISPENSAS_REMOVIDAS=0
    [ -e "$CONF_ARQUIVO" ] || return 0
    _conf_localizar_alvo || return 1
    [ ! -L "$CONF_ARQUIVO" ] || return 1
    # Só remove o que realmente está no arquivo, para não republicar sem motivo.
    if ! grep -Eq "^[[:space:]]*(AIRLOCK_DISPENSADO|BACKUP_DISPENSADO)[[:space:]]*=" \
        "$CONF_ARQUIVO"; then
        return 0
    fi
    for chave in "${CHAVES_CONF_DEPRECIADAS[@]}"; do
        if grep -Eq "^[[:space:]]*${chave}[[:space:]]*=" "$CONF_ARQUIVO"; then
            lista+="${lista:+$'\n'}$chave"
        fi
    done
    [ -n "$lista" ] || return 0
    _conf_allowlist_pares
    payload=(name "$CONF_NOME_ALVO" remove_keys "$lista")
    if ! python_core_config CONF_PARES_PERMITIDAS CFG_ config-publish payload \
            "$CONF_DIRETORIO_ALVO"; then
        erro "Não foi possível remover as dispensas depreciadas da configuração."
        return 1
    fi
    CONF_MIGRACAO_DISPENSAS_REMOVIDAS="${CFG_REMOVED_COUNT:-0}"
    if [ "$CONF_MIGRACAO_DISPENSAS_REMOVIDAS" != 0 ]; then
        info "Dispensas sem efeito removidas da configuração: ${lista//$'\n'/, }."
        info "Para não usar o Airlock ou o backup, simplesmente não execute a etapa; o status continua dizendo a verdade."
    fi
    return 0
}

CONF_MIGRACAO_ISO_BACKUP=""
conf_migrar_iso_legada() {
    # REQ-CONF-ISO, fluxo completo. Roda ANTES de carregar_conf, porque um valor
    # legado inválido derrubaria o parser estrito e impediria justamente a
    # correção. Regras que este fluxo cumpre:
    #
    #   * o caminho legado nunca é aberto, resolvido, montado, copiado, testado
    #     por existência nem usado com privilégio: só o classificador
    #     pré-parser o lê, e como texto;
    #   * o valor antigo nunca é reaproveitado como sugestão;
    #   * um backup 0600 é criado antes de qualquer publicação;
    #   * todas as chaves pendentes entram em um único rename (todo-ou-nada);
    #   * em qualquer falha o original permanece utilizável e o backup é
    #     informado;
    #   * configuração já válida é no-op exato: nenhum backup, nenhuma escrita.
    #
    # Retornos: 0 = nada a fazer ou migração concluída; 1 = erro.
    local estado chave descricao timestamp indice rc=0
    local -a pendentes=() descricoes=() pares=() migradas=()
    CONF_MIGRACAO_ISO_BACKUP=""
    conf_iso_legada_classificar || rc=$?
    if [ "$rc" -eq 2 ]; then
        erro "Não foi possível classificar as ISOs da configuração antes do parser estrito."
        return 1
    fi
    [ "$rc" -eq 1 ] || return 0

    for chave in ISO_WINDOWS ISO_VIRTIO; do
        case "$chave" in
            ISO_WINDOWS)
                estado="$CONF_ISO_LEGADA_ESTADO_WINDOWS"
                descricao="ISO do Windows 11"
                ;;
            *)
                estado="$CONF_ISO_LEGADA_ESTADO_VIRTIO"
                descricao="ISO virtio-win"
                ;;
        esac
        case "$estado" in
            invalida|duplicada)
                pendentes+=("$chave")
                descricoes+=("$descricao")
                ;;
        esac
    done
    [ "${#pendentes[@]}" -gt 0 ] || return 0

    titulo "Migração segura de ISO legada na configuração"
    aviso "A configuração guarda ${CONF_ISO_LEGADA_PENDENTES} caminho(s) de ISO que a política atual recusa."
    info "O caminho antigo NÃO foi aberto, resolvido nem reaproveitado: ele é tratado apenas como texto."
    info "Política em vigor: a ISO precisa ser um filho direto canônico de /vm, sem vírgula (ex.: /vm/Win11.iso)."
    info "ENTER deixa a chave vazia e a etapa 40 pedirá o caminho depois."

    if [ -f "$CONF_ARQUIVO" ]; then
        mkdir -p -- "$BACKUPS_DIR" \
            || { erro "Não foi possível criar $BACKUPS_DIR para o backup da migração."; return 1; }
        timestamp="$(date +%Y%m%d-%H%M%S-%N)"
        CONF_MIGRACAO_ISO_BACKUP="$(umask 077; mktemp "$BACKUPS_DIR/passthrough.conf.pre-iso-migracao-${timestamp}.XXXXXX.bak")" \
            || { erro "Não foi possível reservar nome único para o backup da migração."; return 1; }
        if ! cp -- "$CONF_ARQUIVO" "$CONF_MIGRACAO_ISO_BACKUP" \
           || ! chmod 600 -- "$CONF_MIGRACAO_ISO_BACKUP"; then
            rm -f -- "$CONF_MIGRACAO_ISO_BACKUP"
            CONF_MIGRACAO_ISO_BACKUP=""
            erro "Não foi possível criar o backup 0600 antes da migração de ISO."
            return 1
        fi
        info "Backup da configuração antes da migração: $CONF_MIGRACAO_ISO_BACKUP"
    fi

    for indice in "${!pendentes[@]}"; do
        chave="${pendentes[$indice]}"
        perguntar_iso_valor_conf "${descricoes[$indice]}"
        pares+=("$chave" "$CONF_ISO_NOVO_VALOR")
        migradas+=("$chave")
    done

    if ! _conf_publicar_migracao migradas "${pares[@]}"; then
        erro "A migração de ISO não foi publicada; a configuração original continua utilizável."
        [ -z "$CONF_MIGRACAO_ISO_BACKUP" ] \
            || erro "Backup disponível em: $CONF_MIGRACAO_ISO_BACKUP"
        return 1
    fi
    ok "Migração de ISO concluída em um único rename: ${migradas[*]}."
    return 0
}

CONF_ISO_LEGADA_ESTADO_WINDOWS=""
CONF_ISO_LEGADA_ESTADO_VIRTIO=""
CONF_ISO_LEGADA_PENDENTES=0
conf_iso_legada_classificar() {
    # REQ-CONF-ISO: leitura pré-parser das chaves de ISO. Não abre, não resolve,
    # não monta, não copia, não testa existência e não privilegia o caminho
    # legado; ele é tratado como texto e nunca é reaproveitado. Serve para que um
    # valor antigo inválido chegue ao prompt de novo caminho em vez de derrubar a
    # etapa no parser estrito.
    # Retornos: 0=nada a migrar; 1=há chave a substituir; 2=erro de leitura.
    local -a permitidas=(
        CORE_VERSION PROTOCOL_VERSION SUBCOMMAND
        EXISTS NEEDS_MIGRATION SCANNED_KEYS ISO_WINDOWS_STATE ISO_VIRTIO_STATE
    )
    local -a payload=()
    CONF_ISO_LEGADA_ESTADO_WINDOWS=""
    CONF_ISO_LEGADA_ESTADO_VIRTIO=""
    CONF_ISO_LEGADA_PENDENTES=0
    _conf_localizar_alvo || return 2
    [ ! -L "$CONF_ARQUIVO" ] || return 2
    [ -e "$CONF_ARQUIVO" ] || return 0
    payload=(name "$CONF_NOME_ALVO")
    python_core_config permitidas ISOLEG_ config-legacy-scan payload \
        "$CONF_DIRETORIO_ALVO" 2>/dev/null || return 2
    CONF_ISO_LEGADA_ESTADO_WINDOWS="$ISOLEG_ISO_WINDOWS_STATE"
    CONF_ISO_LEGADA_ESTADO_VIRTIO="$ISOLEG_ISO_VIRTIO_STATE"
    CONF_ISO_LEGADA_PENDENTES="$ISOLEG_NEEDS_MIGRATION"
    [ "$CONF_ISO_LEGADA_PENDENTES" = 0 ] || return 1
    return 0
}
backup_e_resetar_config_etapa02() {
    # O conjunto precisa acompanhar toda chave escolhida/calculada pela etapa
    # 02. A limpeza inteira é publicada pelo único rename de salvar_conf_lote.
    local timestamp backup="" conf_existia=0
    local -a chaves=(
        USUARIO_LINUX VM_NAME BOOTLOADER
        GPU_PCI_ID GPU_AUDIO_PCI_ID GPU_VENDOR_DEVICE_ID GPU_AUDIO_VENDOR_DEVICE_ID
        IOMMU_GROUP_GPU DM_SERVICE
        NVME_DEVICE WORKING_DISK_PATH WORKING_DISK_DISPENSADO
        HD1_BY_ID_PATH HD1_DISPENSADO
        CPUS_VM CPUS_HOST VM_VCPUS VM_CORES VM_THREADS VM_RAM_MB HUGEPAGES_1G
        INTERFACE_FISICA REDE_MODO VM_IP_FIXO IP_FIXO_HOST REDE_NAT_CIDR
        TRANSFER_USER AIRLOCK_DIR ISO_WINDOWS ISO_VIRTIO
    )
    local -a pares=()
    local chave
    BACKUP_CONFIG_ETAPA02=""
    if [ -f "$CONF_ARQUIVO" ]; then
        conf_existia=1
        mkdir -p -- "$BACKUPS_DIR" || falhar "Não foi possível criar $BACKUPS_DIR."
        timestamp="$(date +%Y%m%d-%H%M%S-%N)"
        backup="$(umask 077; mktemp "$BACKUPS_DIR/passthrough.conf.pre-redetectar-${timestamp}.XXXXXX.bak")" \
            || falhar "Não foi possível reservar um nome único para o backup pré-redetecção."
        cp -- "$CONF_ARQUIVO" "$backup" \
            || { rm -f -- "$backup"; falhar "Não foi possível criar o backup pré-redetecção."; }
        chmod 600 -- "$backup" \
            || { rm -f -- "$backup"; falhar "Não foi possível restringir o backup pré-redetecção."; }
        BACKUP_CONFIG_ETAPA02="$backup"
    fi
    if [ "$conf_existia" -eq 0 ]; then
        cp -- "$PROJETO_DIR/passthrough.conf.example" "$CONF_ARQUIVO" \
            || falhar "Não foi possível criar o arquivo central a partir do modelo."
        chmod 600 -- "$CONF_ARQUIVO" \
            || falhar "Não foi possível restringir o novo arquivo de configuração."
    fi
    for chave in "${chaves[@]}"; do
        pares+=("$chave" "")
    done
    salvar_conf_lote "${pares[@]}"
}

exigir_conf() {
    # exigir_conf VAR1 VAR2 ... -> aborta se alguma estiver vazia/não definida
    local var faltando=0
    for var in "$@"; do
        if [ -z "${!var:-}" ]; then
            erro "Variável '$var' ausente ou vazia em: $CONF_ARQUIVO"
            faltando=1
        fi
    done
    if [ "$faltando" -eq 1 ]; then
        falhar "Execute antes: etapas/02-detectar-config.sh (ou edite o passthrough.conf)."
    fi
}

# --- Rede: validação compartilhada -------------------------------------------
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

USUARIO_VALIDACAO_ERRO=""
USUARIO_VALIDADO_UID=""
USUARIO_VALIDADO_GID=""
USUARIO_VALIDADO_HOME=""
USUARIO_OPERADOR=""
USUARIO_DIFERE_OPERADOR=0

usuario_operador_efetivo() {
    # O argumento opcional existe apenas para testes unitários que chamam esta
    # API diretamente. Fluxos operacionais não o recebem do ambiente.
    local operador="${1:-}"
    if [ -z "$operador" ]; then
        if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
            operador="$SUDO_USER"
        else
            operador="$(id -un 2>/dev/null)" || return 1
        fi
    fi
    nome_usuario_valido "$operador" || return 1
    printf '%s\n' "$operador"
}

validar_usuario_linux() {
    # Valida uma única entrada NSS e cruza UID/GID com id(1). O home precisa
    # ser absoluto, existir e ser atravessável como diretório. O segundo
    # argumento injeta o operador somente em chamadas unitárias explícitas.
    local usuario="${1:-}" operador_injetado="${2:-}"
    local registro nome senha uid gid gecos home shell extra uid_id gid_id operador
    local -a registros=()
    USUARIO_VALIDACAO_ERRO=""
    USUARIO_VALIDADO_UID=""
    USUARIO_VALIDADO_GID=""
    USUARIO_VALIDADO_HOME=""
    USUARIO_OPERADOR=""
    USUARIO_DIFERE_OPERADOR=0
    nome_usuario_valido "$usuario" \
        || { USUARIO_VALIDACAO_ERRO="USUARIO_LINUX inválido: '${usuario:-vazio}'."; return 1; }
    mapfile -t registros < <(getent passwd "$usuario" 2>/dev/null)
    [ "${#registros[@]}" -eq 1 ] \
        || { USUARIO_VALIDACAO_ERRO="A conta '$usuario' não possui uma entrada NSS única."; return 1; }
    registro="${registros[0]}"
    IFS=: read -r nome senha uid gid gecos home shell extra <<< "$registro"
    [ "$nome" = "$usuario" ] && [ -z "$extra" ] \
        || { USUARIO_VALIDACAO_ERRO="A entrada NSS de '$usuario' é inconsistente."; return 1; }
    inteiro_na_faixa "$uid" 1 2147483647 \
        || { USUARIO_VALIDACAO_ERRO="UID inválido para '$usuario': '${uid:-vazio}'."; return 1; }
    inteiro_na_faixa "$gid" 1 2147483647 \
        || { USUARIO_VALIDACAO_ERRO="GID inválido para '$usuario': '${gid:-vazio}'."; return 1; }
    caminho_absoluto_seguro "$home" && [ -d "$home" ] \
        || { USUARIO_VALIDACAO_ERRO="Home inválido ou inexistente para '$usuario': '${home:-vazio}'."; return 1; }
    uid_id="$(id -u "$usuario" 2>/dev/null)" \
        || { USUARIO_VALIDACAO_ERRO="id não conseguiu resolver o UID de '$usuario'."; return 1; }
    gid_id="$(id -g "$usuario" 2>/dev/null)" \
        || { USUARIO_VALIDACAO_ERRO="id não conseguiu resolver o GID de '$usuario'."; return 1; }
    [ "$uid_id" = "$uid" ] && [ "$gid_id" = "$gid" ] \
        || { USUARIO_VALIDACAO_ERRO="UID/GID de id e NSS divergem para '$usuario'."; return 1; }
    operador="$(usuario_operador_efetivo "$operador_injetado")" \
        || { USUARIO_VALIDACAO_ERRO="Não foi possível determinar o operador efetivo."; return 1; }
    USUARIO_VALIDADO_UID="$uid"
    USUARIO_VALIDADO_GID="$gid"
    USUARIO_VALIDADO_HOME="$home"
    USUARIO_OPERADOR="$operador"
    [ "$usuario" = "$operador" ] || USUARIO_DIFERE_OPERADOR=1
}

confirmar_usuario_linux_diferente() {
    local usuario="${1:-}" token
    [ "$USUARIO_DIFERE_OPERADOR" -eq 1 ] || return 0
    token="USAR-$usuario"
    confirmar_digitando "$token" \
        "USUARIO_LINUX='$usuario' é uma conta válida, mas o operador efetivo é '$USUARIO_OPERADOR'. As mutações agirão sobre a outra conta."
}

exigir_usuario_linux_valido() {
    local usuario="${1:-${USUARIO_LINUX:-}}"
    validar_usuario_linux "$usuario" || falhar "$USUARIO_VALIDACAO_ERRO"
    confirmar_usuario_linux_diferente "$usuario" \
        || falhar "Conta diferente do operador não foi autorizada; nenhuma mutação foi iniciada."
}

GRUPO_VM_ERRO=""
validar_acl_diretorio_vm() {
    local diretorio="${1:-/vm}" saida linha
    local u=0 g=0 m=0 o=0 du=0 dg=0 dm=0 do_=0
    GRUPO_VM_ERRO=""
    command -v getfacl >/dev/null 2>&1 \
        || { GRUPO_VM_ERRO="getfacl indisponível para comprovar a herança de /vm."; return 1; }
    saida="$(getfacl -cp -- "$diretorio" 2>/dev/null)" \
        || { GRUPO_VM_ERRO="Não foi possível ler as ACLs de $diretorio."; return 1; }
    while IFS= read -r linha || [ -n "$linha" ]; do
        [ -n "$linha" ] || continue
        case "$linha" in
            user::rwx) u=$((u + 1)) ;;
            group::rwx) g=$((g + 1)) ;;
            mask::rwx) m=$((m + 1)) ;;
            other::---) o=$((o + 1)) ;;
            default:user::rwx) du=$((du + 1)) ;;
            default:group::rwx) dg=$((dg + 1)) ;;
            default:mask::rwx) dm=$((dm + 1)) ;;
            default:other::---) do_=$((do_ + 1)) ;;
            \#*) ;;
            *) GRUPO_VM_ERRO="ACL inesperada em $diretorio: $linha"; return 1 ;;
        esac
    done <<< "$saida"
    [ "$u" -eq 1 ] && [ "$g" -eq 1 ] && [ "$m" -eq 1 ] && [ "$o" -eq 1 ] \
        && [ "$du" -eq 1 ] && [ "$dg" -eq 1 ] && [ "$dm" -eq 1 ] && [ "$do_" -eq 1 ] \
        || { GRUPO_VM_ERRO="ACL de acesso/default de $diretorio não é exatamente rwx/rwx/--- com máscara rwx."; return 1; }
}

usuario_pertence_grupo() {
    local usuario="$1" grupo="$2" grupos
    grupos="$(id -nG "$usuario" 2>/dev/null)" || return 1
    grep -qw -- "$grupo" <<< "$grupos"
}

validar_modelo_diretorio_vm() {
    # validar_modelo_diretorio_vm DIRETORIO OPERADOR [USUARIO_QEMU] [GRUPO]
    local diretorio="${1:-/vm}" operador="${2:-}" qemu="${3:-}"
    local grupo="${4:-${VM_STORAGE_GROUP:-vm-passthrough}}" estado
    local nome senha gid membros extra
    local -a registros=()
    GRUPO_VM_ERRO=""
    nome_grupo_vm_dedicado_valido "$grupo" \
        || { GRUPO_VM_ERRO="Grupo de armazenamento precisa usar o namespace dedicado 'vm-passthrough[-sufixo]': '$grupo'."; return 1; }
    mapfile -t registros < <(getent group "$grupo" 2>/dev/null)
    [ "${#registros[@]}" -eq 1 ] \
        || { GRUPO_VM_ERRO="Grupo compartilhado '$grupo' não possui entrada NSS única."; return 1; }
    IFS=: read -r nome senha gid membros extra <<< "${registros[0]}"
    [ "$nome" = "$grupo" ] && [ -z "$extra" ] && inteiro_na_faixa "$gid" 1 2147483647 \
        || { GRUPO_VM_ERRO="Entrada NSS inconsistente para o grupo dedicado '$grupo'."; return 1; }
    [ -d "$diretorio" ] \
        || { GRUPO_VM_ERRO="Diretório $diretorio não existe."; return 1; }
    estado="$(stat -c '%U:%G:%a' -- "$diretorio" 2>/dev/null)" \
        || { GRUPO_VM_ERRO="Não foi possível inspecionar $diretorio."; return 1; }
    [ "$estado" = "root:$grupo:2770" ] \
        || { GRUPO_VM_ERRO="$diretorio está como $estado; esperado root:$grupo:2770."; return 1; }
    usuario_pertence_grupo "$operador" "$grupo" \
        || { GRUPO_VM_ERRO="Operador '$operador' não pertence ao grupo '$grupo'."; return 1; }
    if [ -n "$qemu" ]; then
        usuario_pertence_grupo "$qemu" "$grupo" \
            || { GRUPO_VM_ERRO="Identidade QEMU '$qemu' não pertence ao grupo '$grupo'."; return 1; }
    fi
    validar_acl_diretorio_vm "$diretorio"
}

configurar_modelo_diretorio_vm() {
    local diretorio="${1:-/vm}" grupo="${2:-${VM_STORAGE_GROUP:-vm-passthrough}}"
    nome_grupo_vm_dedicado_valido "$grupo" \
        || falhar "Grupo de armazenamento precisa usar o namespace dedicado 'vm-passthrough[-sufixo]': '$grupo'."
    sudo chown "root:$grupo" "$diretorio"
    sudo setfacl -b -k -- "$diretorio"
    sudo setfacl -m 'u::rwx,g::rwx,m::rwx,o::---' -- "$diretorio"
    sudo setfacl -m 'd:u::rwx,d:g::rwx,d:m::rwx,d:o::---' -- "$diretorio"
    sudo chmod 2770 "$diretorio"
}

SELO_VM_ERRO=""
selar_diretorio_vm() {
    # Remove somente o write do grupo na raiz fixa /vm. Arquivos já abertos
    # continuam graváveis, mas nenhum membro do grupo pode criar/renomear uma
    # entrada entre a validação e o consumidor abrir o pathname.
    local diretorio="${1:-}" grupo="${2:-}" raiz estado real
    SELO_VM_ERRO=""
    raiz="$(caminho_sistema /vm)" \
        || { SELO_VM_ERRO="Não foi possível resolver /vm para selagem."; return 1; }
    [ "$diretorio" = "$raiz" ] && [ -d "$diretorio" ] && [ ! -L "$diretorio" ] \
        || { SELO_VM_ERRO="A selagem só aceita a raiz fixa /vm, regular e sem link."; return 1; }
    nome_grupo_vm_dedicado_valido "$grupo" \
        || { SELO_VM_ERRO="Grupo inválido para selagem de /vm: '$grupo'."; return 1; }
    real="$(readlink -f -- "$diretorio" 2>/dev/null)" \
        || { SELO_VM_ERRO="Não foi possível canonicalizar /vm para selagem."; return 1; }
    [ "$real" = "$diretorio" ] \
        || { SELO_VM_ERRO="A raiz /vm não é canônica para selagem."; return 1; }
    estado="$(stat -c '%U:%G:%a' -- "$diretorio" 2>/dev/null)" \
        || { SELO_VM_ERRO="Não foi possível inspecionar /vm antes da selagem."; return 1; }
    [ "$estado" = "root:$grupo:2770" ] \
        || { SELO_VM_ERRO="Estado inesperado antes da selagem: $estado."; return 1; }
    sudo chmod 2750 "$diretorio" \
        || { SELO_VM_ERRO="Falha ao remover write do grupo em /vm."; return 1; }
    estado="$(stat -c '%U:%G:%a' -- "$diretorio" 2>/dev/null)" \
        || { SELO_VM_ERRO="Não foi possível comprovar a selagem de /vm."; return 1; }
    [ "$estado" = "root:$grupo:2750" ] \
        || { SELO_VM_ERRO="Selagem de /vm não convergiu: $estado."; return 1; }
}

restaurar_diretorio_vm() {
    local diretorio="${1:-}" grupo="${2:-}" raiz estado
    SELO_VM_ERRO=""
    raiz="$(caminho_sistema /vm)" \
        || { SELO_VM_ERRO="Não foi possível resolver /vm para restauração."; return 1; }
    [ "$diretorio" = "$raiz" ] && [ -d "$diretorio" ] && [ ! -L "$diretorio" ] \
        || { SELO_VM_ERRO="A restauração só aceita a raiz fixa /vm."; return 1; }
    nome_grupo_vm_dedicado_valido "$grupo" \
        || { SELO_VM_ERRO="Grupo inválido para restauração de /vm: '$grupo'."; return 1; }
    sudo chmod 2770 "$diretorio" \
        || { SELO_VM_ERRO="Falha ao restaurar write do grupo em /vm."; return 1; }
    estado="$(stat -c '%U:%G:%a' -- "$diretorio" 2>/dev/null)" \
        || { SELO_VM_ERRO="Não foi possível comprovar a restauração de /vm."; return 1; }
    [ "$estado" = "root:$grupo:2770" ] \
        || { SELO_VM_ERRO="Restauração de /vm não convergiu: $estado."; return 1; }
    validar_acl_diretorio_vm "$diretorio" \
        || { SELO_VM_ERRO="ACL de /vm não foi restaurada: $GRUPO_VM_ERRO"; return 1; }
}

validar_arquivo_compartilhado_vm() {
    local arquivo="$1" grupo="$2" estado
    [ -f "$arquivo" ] && [ ! -L "$arquivo" ] || return 1
    estado="$(stat -c '%h:%G:%a' -- "$arquivo" 2>/dev/null)" || return 1
    [ "$estado" = "1:$grupo:660" ]
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

REDE_IP_ERRO=""
validar_ips_interface_rede() {
    # validar_ips_interface_rede IFACE IP_VM IP_HOST
    # O endereço do host precisa estar efetivamente na interface, e o da VM
    # precisa ser um unicast distinto dentro do mesmo prefixo IPv4.
    local iface="${1:-}" ip_vm="${2:-}" ip_host="${3:-}" cidr endereco
    local -a cidrs=()
    REDE_IP_ERRO=""
    nome_interface_valido "$iface" || { REDE_IP_ERRO="Interface de rede inválida: '$iface'."; return 1; }
    ipv4_valido "$ip_vm" || { REDE_IP_ERRO="VM_IP_FIXO inválido: '${ip_vm:-vazio}'."; return 1; }
    ipv4_valido "$ip_host" || { REDE_IP_ERRO="IP_FIXO_HOST inválido: '${ip_host:-vazio}'."; return 1; }
    [ "$ip_vm" != "$ip_host" ] || { REDE_IP_ERRO="VM_IP_FIXO e IP_FIXO_HOST não podem ser iguais."; return 1; }
    mapfile -t cidrs < <(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{print $4}')
    [ "${#cidrs[@]}" -gt 0 ] \
        || { REDE_IP_ERRO="A interface '$iface' não possui endereço IPv4 global."; return 1; }
    for cidr in "${cidrs[@]}"; do
        endereco="${cidr%/*}"
        if [ "$ip_host" = "$endereco" ]; then
            ipv4_unicast_em_cidr "$ip_vm" "$cidr" \
                || { REDE_IP_ERRO="VM_IP_FIXO=$ip_vm não é unicast no prefixo $cidr de $iface."; return 1; }
            return 0
        fi
    done
    REDE_IP_ERRO="IP_FIXO_HOST=$ip_host não está atribuído à interface '$iface'."
    return 1
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

interface_fisica_elegivel() {
    local iface="${1:-}" base
    nome_interface_valido "$iface" || return 1
    [ "$iface" != "lo" ] || return 1
    base="$(caminho_sistema "/sys/class/net/$iface")" || return 1
    [ -e "$base/device" ] || return 1
    [ "$(cat "$base/type" 2>/dev/null)" = "1" ]
}

interface_wifi() {
    local iface="${1:-}" base
    base="$(caminho_sistema "/sys/class/net/$iface")" || return 1
    [ -d "$base/wireless" ]
}

dispositivo_uplink_ipv4_efetivo() {
    # Consulta somente a decisão local de roteamento do kernel: nenhum pacote é
    # enviado a 1.1.1.1. Imprime o dispositivo usado pela rota IPv4 efetiva.
    local rota dispositivo
    rota="$(ip -4 route get 1.1.1.1 2>/dev/null)" || return 1
    dispositivo="$(awk 'NR == 1 {
        for (i = 1; i <= NF; i++) {
            if ($i == "dev" && (i + 1) <= NF) { print $(i + 1); exit }
        }
    }' <<< "$rota")"
    [ -n "$dispositivo" ] || return 1
    printf '%s\n' "$dispositivo"
}

REDE_CONFIG_ERRO=""
validar_config_rede() {
    # Valida apenas a decisão da etapa 02. VM_NIC_MAC, sub-rede e IPs podem
    # continuar vazios até as etapas 40/60, mas, quando presentes, são validados.
    local modo="${REDE_MODO:-}" iface="${INTERFACE_FISICA:-}"
    local bridge="${REDE_BRIDGE:-br0}"
    local rede_libvirt="${REDE_LIBVIRT:-passthrough-nat}"
    local bridge_libvirt="${REDE_BRIDGE_LIBVIRT:-virbr-vmnat}"
    REDE_CONFIG_ERRO=""

    case "$modo" in
        bridge|nat) : ;;
        *) REDE_CONFIG_ERRO="REDE_MODO precisa ser 'bridge' ou 'nat' (está: '${modo:-vazio}')."; return 1 ;;
    esac
    if ! nome_interface_valido "$iface"; then
        REDE_CONFIG_ERRO="INTERFACE_FISICA tem nome inválido: '${iface:-vazio}'."
        return 1
    fi
    if ! interface_fisica_elegivel "$iface"; then
        REDE_CONFIG_ERRO="INTERFACE_FISICA='$iface' não existe ou não é uma interface física elegível."
        return 1
    fi
    if [ "$modo" = "bridge" ] && interface_wifi "$iface"; then
        REDE_CONFIG_ERRO="Bridge sobre Wi-Fi station não é suportada; selecione REDE_MODO='nat'."
        return 1
    fi
    if ! nome_interface_valido "$bridge" || [ "$bridge" = "$iface" ]; then
        REDE_CONFIG_ERRO="REDE_BRIDGE='$bridge' é inválida ou coincide com o uplink."
        return 1
    fi
    if ! nome_rede_libvirt_valido "$rede_libvirt" || [ "$rede_libvirt" = "default" ]; then
        REDE_CONFIG_ERRO="REDE_LIBVIRT='$rede_libvirt' é inválida ou usa o nome reservado 'default'."
        return 1
    fi
    if ! nome_interface_valido "$bridge_libvirt" \
       || [ "$bridge_libvirt" = "$iface" ] \
       || [ "$bridge_libvirt" = "$bridge" ]; then
        REDE_CONFIG_ERRO="REDE_BRIDGE_LIBVIRT='$bridge_libvirt' é inválida ou coincide com outra interface."
        return 1
    fi
    if [ -n "${REDE_NAT_CIDR:-}" ] && ! cidr_privado_24_valido "$REDE_NAT_CIDR"; then
        REDE_CONFIG_ERRO="REDE_NAT_CIDR='$REDE_NAT_CIDR' precisa ser uma sub-rede privada /24 (terminada em .0/24)."
        return 1
    fi
    if [ -n "${VM_NIC_MAC:-}" ] && ! mac_valido "$VM_NIC_MAC"; then
        REDE_CONFIG_ERRO="VM_NIC_MAC='$VM_NIC_MAC' não é um endereço MAC válido."
        return 1
    fi
    if [ -n "${VM_IP_FIXO:-}" ] && ! ipv4_valido "$VM_IP_FIXO"; then
        REDE_CONFIG_ERRO="VM_IP_FIXO='$VM_IP_FIXO' não é um IPv4 válido."
        return 1
    fi
    if [ -n "${IP_FIXO_HOST:-}" ] && ! ipv4_valido "$IP_FIXO_HOST"; then
        REDE_CONFIG_ERRO="IP_FIXO_HOST='$IP_FIXO_HOST' não é um IPv4 válido."
        return 1
    fi
}

exigir_config_rede() {
    validar_config_rede \
        || falhar "$REDE_CONFIG_ERRO Rode: bash etapas/02-detectar-config.sh --redetectar"
}

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
    for i in "${!itens[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "${itens[$i]}" >&2
    done
    if [ "$permitir_nenhum" = "sim" ]; then
        printf '  0) não selecionar item\n' >&2
        min=0
    fi
    printf '  v) voltar ao menu principal\n  q) sair\n' >&2
    [ "${#itens[@]}" -eq 1 ] && [ "$min" -eq 1 ] && padrao=1
    perguntar_inteiro "$pergunta" "$padrao" "$min" "${#itens[@]}"
}

# --- Discos: identificação segura (nunca /dev/sdX chumbado) --------------------
discos_fisicos_de() {
    # Imprime TODOS os ancestrais físicos TYPE=disk (LVM/MD/multipath podem ter
    # mais de um). Falha se a topologia não puder ser enumerada integralmente.
    local origem="$1" saida caminho tipo
    local -A vistos=()
    [ -n "$origem" ] || return 1
    saida="$(lsblk -s -nro PATH,TYPE -- "$origem" 2>/dev/null)" || return 1
    while read -r caminho tipo; do
        [ "$tipo" = disk ] || continue
        [ -n "$caminho" ] || return 1
        if [ -z "${vistos[$caminho]+definido}" ]; then
            printf '%s\n' "$caminho"
            vistos[$caminho]=1
        fi
    done <<< "$saida"
    [ "${#vistos[@]}" -gt 0 ]
}

disco_de() {
    # Compatibilidade para consumidores que esperam um único disco. Valida a
    # topologia plural, mas retorna o primeiro; gates destrutivos usam a função
    # plural diretamente.
    local discos primeiro
    discos="$(discos_fisicos_de "$1")" || return 1
    IFS= read -r primeiro <<< "$discos"
    [ -n "$primeiro" ] || return 1
    printf '%s\n' "$primeiro"
}

discos_raiz() {
    local fonte
    fonte="$(findmnt -no SOURCE / 2>/dev/null | sed 's/\[.*\]$//')" || return 1
    [ -n "$fonte" ] || return 1
    discos_fisicos_de "$fonte"
}

disco_raiz() {
    local discos primeiro
    discos="$(discos_raiz)" || return 1
    IFS= read -r primeiro <<< "$discos"
    [ -n "$primeiro" ] || return 1
    printf '%s\n' "$primeiro"
}

DISCO_USO_ERRO=""
disco_em_uso_pelo_host() {
    # Retornos: 0=em uso/montado, 1=inspeção concluída e livre, 2=erro de
    # inspeção. Além de mountpoints, bloqueia swap, device-mapper/LVM/MD e
    # qualquer holder ativo no disco ou em suas partições.
    local disco="$1" raizes raiz real saida caminho tipo nome holder swap swap_real no_real
    local -a nos=()
    DISCO_USO_ERRO=""
    real="$(readlink -f -- "$disco" 2>/dev/null)" \
        || { DISCO_USO_ERRO="Não foi possível resolver $disco."; return 2; }
    raizes="$(discos_raiz 2>/dev/null)" \
        || { DISCO_USO_ERRO="Não foi possível enumerar todos os discos físicos da raiz."; return 2; }
    while IFS= read -r raiz; do
        [ -n "$raiz" ] || continue
        raiz="$(readlink -f -- "$raiz" 2>/dev/null)" \
            || { DISCO_USO_ERRO="Não foi possível resolver um ancestral físico da raiz."; return 2; }
        [ "$real" != "$raiz" ] || return 0
    done <<< "$raizes"

    saida="$(lsblk -nrpo PATH,MOUNTPOINTS -- "$real" 2>/dev/null)" \
        || { DISCO_USO_ERRO="lsblk falhou ao inspecionar montagens de $real."; return 2; }
    if awk 'NF > 1 && $2 != "" {encontrado=1} END {exit !encontrado}' <<< "$saida"; then
        return 0
    fi

    saida="$(lsblk -nrpo PATH,TYPE -- "$real" 2>/dev/null)" \
        || { DISCO_USO_ERRO="lsblk falhou ao inspecionar consumidores de $real."; return 2; }
    while read -r caminho tipo; do
        [ -n "$caminho" ] && [ -n "$tipo" ] \
            || { DISCO_USO_ERRO="Topologia de bloco incompleta ao inspecionar $real."; return 2; }
        nos+=("$caminho")
        case "$tipo" in
            disk|part) ;;
            *) return 0 ;; # crypt, lvm, raid, multipath e similares
        esac
    done <<< "$saida"
    [ "${#nos[@]}" -gt 0 ] \
        || { DISCO_USO_ERRO="Nenhum nó de bloco foi enumerado para $real."; return 2; }

    for caminho in "${nos[@]}"; do
        nome="${caminho##*/}"
        [ -d "/sys/class/block/$nome/holders" ] \
            || { DISCO_USO_ERRO="Não foi possível inspecionar holders de $caminho."; return 2; }
        for holder in "/sys/class/block/$nome/holders/"*; do
            [ -e "$holder" ] || continue
            return 0
        done
    done

    if [ -r /proc/swaps ]; then
        while read -r swap _; do
            [ "$swap" != "Filename" ] || continue
            [ -n "$swap" ] || continue
            swap_real="$(readlink -f -- "$swap" 2>/dev/null || true)"
            [ -n "$swap_real" ] || continue
            for caminho in "${nos[@]}"; do
                no_real="$(readlink -f -- "$caminho" 2>/dev/null || true)"
                [ -n "$no_real" ] || continue
                [ "$swap_real" != "$no_real" ] || return 0
            done
        done < /proc/swaps
    else
        DISCO_USO_ERRO="Não foi possível ler /proc/swaps."
        return 2
    fi
    return 1
}

DISCO_VM_ERRO=""
DISCO_VM_ALVO=""
validar_disco_fisico_vm() {
    # validar_disco_fisico_vm BY_ID [DISCO_SISTEMA] [ALVO_ESPERADO]
    # Executa duas fotografias completas: link, tipo, todos os ancestrais da
    # raiz, disco do sistema e montagens/consumidores. Qualquer erro de
    # inspeção bloqueia.
    local origem="${1:-}" disco_sistema="${2:-${NVME_DEVICE:-}}" esperado="${3:-}"
    local alvo="" atual raizes raiz real tipo uso_status rodada
    DISCO_VM_ERRO=""
    DISCO_VM_ALVO=""

    caminho_absoluto_seguro "$origem" \
        || { DISCO_VM_ERRO="Caminho do disco físico inválido: '${origem:-vazio}'."; return 1; }
    [[ "$origem" == /dev/disk/by-id/* ]] \
        || { DISCO_VM_ERRO="O disco físico precisa usar /dev/disk/by-id/*, nunca /dev/sdX ou /dev/nvmeX."; return 1; }

    for rodada in 1 2; do
        [ -L "$origem" ] \
            || { DISCO_VM_ERRO="O identificador persistente não existe ou não é link simbólico: $origem"; return 1; }
        atual="$(readlink -f -- "$origem" 2>/dev/null)" \
            || { DISCO_VM_ERRO="Não foi possível resolver o destino de $origem."; return 1; }
        if [ -z "$alvo" ]; then
            alvo="$atual"
        elif [ "$atual" != "$alvo" ]; then
            DISCO_VM_ERRO="BLOQUEADO: o alvo de $origem mudou durante a validação ($alvo -> $atual)."
            return 1
        fi
        [ -b "$atual" ] \
            || { DISCO_VM_ERRO="O destino atual de $origem não é dispositivo de bloco: $atual"; return 1; }
        tipo="$(lsblk -dnro TYPE -- "$atual" 2>/dev/null)" \
            || { DISCO_VM_ERRO="lsblk falhou ao classificar $atual."; return 1; }
        [ "$tipo" = disk ] \
            || { DISCO_VM_ERRO="$origem aponta para partição ou dispositivo não físico, não para disco inteiro."; return 1; }

        raizes="$(discos_raiz 2>/dev/null)" \
            || { DISCO_VM_ERRO="Não foi possível enumerar todos os discos físicos da raiz do host."; return 1; }
        while IFS= read -r raiz; do
            [ -n "$raiz" ] || continue
            raiz="$(readlink -f -- "$raiz" 2>/dev/null)" \
                || { DISCO_VM_ERRO="Não foi possível resolver um disco físico da raiz."; return 1; }
            [ "$atual" != "$raiz" ] \
                || { DISCO_VM_ERRO="BLOQUEADO: o disco selecionado contém a raiz do host ($raiz)."; return 1; }
        done <<< "$raizes"

        if [ -n "$disco_sistema" ]; then
            real="$(readlink -f -- "$disco_sistema" 2>/dev/null)" \
                || { DISCO_VM_ERRO="Não foi possível resolver o disco do sistema: $disco_sistema"; return 1; }
            [ -b "$real" ] \
                || { DISCO_VM_ERRO="O disco do sistema deixou de ser dispositivo de bloco: $disco_sistema"; return 1; }
            [ "$atual" != "$real" ] \
                || { DISCO_VM_ERRO="BLOQUEADO: o HD1 coincide com o disco do sistema ($real)."; return 1; }
        fi

        if [ -n "$esperado" ]; then
            real="$(readlink -f -- "$esperado" 2>/dev/null)" \
                || { DISCO_VM_ERRO="O alvo esperado do HD1 não pode mais ser resolvido: $esperado"; return 1; }
            [ "$atual" = "$real" ] \
                || { DISCO_VM_ERRO="BLOQUEADO: $origem não aponta para o alvo esperado ($real -> $atual)."; return 1; }
        fi
        if disco_em_uso_pelo_host "$atual"; then
            DISCO_VM_ERRO="BLOQUEADO: $atual ou uma de suas partições está montado/em uso no host."
            return 1
        else
            uso_status=$?
            if [ "$uso_status" -ne 1 ]; then
                DISCO_VM_ERRO="Falha fechada ao inspecionar uso de $atual: ${DISCO_USO_ERRO:-erro desconhecido}."
                return 1
            fi
        fi
    done
    DISCO_VM_ALVO="$alvo"
}

# --- Memória ---------------------------------------------------------------------
ram_total_mib() {
    local meminfo
    meminfo="$(caminho_sistema /proc/meminfo)" || return 1
    awk '/MemTotal/{printf "%d", $2/1024}' "$meminfo"
}

ram_reserva_host_mib() {
    # Reserva mínima do host: 25% do total, nunca abaixo de 4 GiB nem acima de
    # 8. I5: a aritmética vive no core (plano_memoria_vm); aqui só resta o
    # probe do host e a projeção do valor.
    local total="${1:-}"
    [ -n "$total" ] || total="$(ram_total_mib)" || return 1
    plano_memoria_vm "$total" || return 1
    printf '%s\n' "$CPUMEM_RESERVE_MIB"
}

ram_max_vm_mib() {
    # Teto para a VM: total menos a reserva do host, arredondado para baixo em
    # múltiplos de 1024 MiB (exigência das HugePages de 1 GiB da etapa 52).
    local total="${1:-}"
    [ -n "$total" ] || total="$(ram_total_mib)" || return 1
    plano_memoria_vm "$total" || return 1
    printf '%s\n' "$CPUMEM_MAX_VM_MIB"
}

# --- Bootloader e parâmetros de kernel (Capítulos 15 e 16) --------------------
# I5.6: toda a implementação vive em lib/shell/boot.sh, carregado logo no topo
# desta fachada. Nenhuma cópia mutante permanece aqui: os nomes públicos
# (detectar_bootloader, validar_bootloader_configurado, cmdline_*,
# kernel_param_add/del, kernel_parametros_*) continuam disponíveis porque o
# módulo é sourceado, não duplicado.

# --- Backend libvirt: uma única resolução autoritativa ------------------------
# REQ-LIBVIRT-BACKEND: nenhuma etapa pode escolher `libvirtd` por conta própria.
# O provider de plataforma decide o backend (monolítico `libvirtd` ou modular
# `virtqemud`), a unidade resolvida e a ação autorizada; as etapas 20, 21 e 50
# consomem exatamente este resultado e provam a pós-condição.

LIBVIRT_BACKEND_ERRO=""
LIBVIRT_BACKEND_SERVICO=""
LIBVIRT_BACKEND_UNIDADE=""
LIBVIRT_BACKEND_UNIDADE_DAEMON=""
LIBVIRT_BACKEND_ACAO=""

libvirt_backend_resolver() {
    # Retornos: 0=resolvido; 1=nenhuma unidade do perfil está disponível;
    # 2=erro operacional da sondagem (systemctl ausente, resposta incompleta).
    # A fixture opcional em $1 é autoritativa e nunca cai no systemd do host.
    local fixture="${1:-}" rc=0
    LIBVIRT_BACKEND_ERRO=""
    LIBVIRT_BACKEND_SERVICO=""
    LIBVIRT_BACKEND_UNIDADE=""
    LIBVIRT_BACKEND_UNIDADE_DAEMON=""
    LIBVIRT_BACKEND_ACAO=""
    if plataforma_resolver_servico libvirt "$fixture"; then
        :
    else
        rc=$?
        LIBVIRT_BACKEND_ERRO="$PLATAFORMA_ERRO"
        return "$rc"
    fi
    LIBVIRT_BACKEND_SERVICO="$PLATAFORMA_SERVICO_RESOLVIDO"
    LIBVIRT_BACKEND_UNIDADE="$PLATAFORMA_UNIDADE_RESOLVIDA"
    LIBVIRT_BACKEND_ACAO="$PLATAFORMA_UNIDADE_ACAO"
    # Hooks e configuração são lidos pelo daemon, não pelo socket: a unidade a
    # reiniciar é sempre o serviço do backend resolvido.
    LIBVIRT_BACKEND_UNIDADE_DAEMON="${LIBVIRT_BACKEND_SERVICO}.service"
    if [ -z "$LIBVIRT_BACKEND_SERVICO" ] || [ -z "$LIBVIRT_BACKEND_UNIDADE" ]; then
        LIBVIRT_BACKEND_ERRO="Resolução de backend libvirt incompleta."
        return 2
    fi
    return 0
}

libvirt_backend_reiniciar() {
    # Reinicia o daemon do backend resolvido e prova a pós-condição.
    # Retornos: 0=reiniciado e ativo; 1=falha, com diagnóstico acionável.
    local alvo="$LIBVIRT_BACKEND_UNIDADE_DAEMON"
    LIBVIRT_BACKEND_ERRO=""
    if [ -z "$alvo" ]; then
        LIBVIRT_BACKEND_ERRO="Backend libvirt não resolvido antes do restart."
        return 1
    fi
    if ! sudo systemctl restart "$alvo"; then
        LIBVIRT_BACKEND_ERRO="$alvo não aceitou o restart."
        return 1
    fi
    if ! sudo systemctl is-active --quiet "$alvo"; then
        LIBVIRT_BACKEND_ERRO="$alvo não ficou ativo depois do restart."
        return 1
    fi
    return 0
}

# --- Acesso do operador a qemu:///system --------------------------------------
# REQ-VERIFY-FAILCLOSED aplicado à conexão libvirt: falha de conexão não é
# sinônimo de runtime quebrado. A concessão de grupo só entra na sessão depois
# de logout/login, e quem concede é a etapa 21. Sem classificar a causa, uma
# pendência conhecida e resolvível vira erro, e o operador perde a ação certa.

LIBVIRT_ACESSO_ERRO=""
LIBVIRT_ACESSO_MOTIVO=""

lista_contem_token() {
    local lista="$1" alvo="$2" item
    [ -n "$alvo" ] || return 1
    for item in $lista; do
        [ "$item" = "$alvo" ] && return 0
    done
    return 1
}

libvirt_acesso_operador() {
    # Prova o acesso desta sessão a qemu:///system e classifica a falha.
    # Retornos: 0=acessível; 1=pendência conhecida (grupo ainda não concedido,
    # ou concedido no NSS e ausente desta sessão); 2=falha real.
    # LIBVIRT_ACESSO_MOTIVO: ok|virsh-ausente|grupo|sessao|runtime.
    local grupo="${PLATAFORMA_LIBVIRT_GRUPO:-libvirt}" operador nss sessao
    LIBVIRT_ACESSO_ERRO=""
    LIBVIRT_ACESSO_MOTIVO=""
    if ! command -v virsh >/dev/null 2>&1; then
        LIBVIRT_ACESSO_MOTIVO=virsh-ausente
        LIBVIRT_ACESSO_ERRO="virsh ausente: a pilha da etapa 20 ainda não está instalada."
        return 2
    fi
    if virsh --connect qemu:///system list --all >/dev/null 2>&1; then
        LIBVIRT_ACESSO_MOTIVO=ok
        return 0
    fi
    operador="$(id -un 2>/dev/null || true)"
    sessao="$(id -nG 2>/dev/null || true)"
    nss="$(id -nG "$operador" 2>/dev/null || true)"
    if lista_contem_token "$sessao" "$grupo"; then
        LIBVIRT_ACESSO_MOTIVO=runtime
        LIBVIRT_ACESSO_ERRO="A sessão já carrega o grupo '$grupo' e ainda assim qemu:///system não respondeu; o runtime libvirt está inválido."
        return 2
    fi
    if lista_contem_token "$nss" "$grupo"; then
        LIBVIRT_ACESSO_MOTIVO=sessao
        LIBVIRT_ACESSO_ERRO="Acesso a qemu:///system pendente de sessão nova: o grupo '$grupo' já consta no NSS de '$operador', mas ainda não nesta sessão. Faça logout/login e verifique de novo."
        return 1
    fi
    LIBVIRT_ACESSO_MOTIVO=grupo
    LIBVIRT_ACESSO_ERRO="Acesso a qemu:///system pendente: '$operador' ainda não pertence ao grupo '$grupo'. Execute a etapa 21 e faça logout/login."
    return 1
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

# --- fstab gerenciado (linhas com marcador, idempotentes) ----------------------
fstab_backup() {
    local destino="${FSTAB}.bak-$(date +%Y%m%d-%H%M%S)"
    sudo cp "$FSTAB" "$destino"
    info "Backup do fstab criado: $destino"
}

fstab_definir_linha() {
    # fstab_definir_linha ID "linha completa"
    # Adiciona (ou substitui) uma linha marcada com "# vm-passthrough:ID".
    local id="$1" linha="$2"
    sudo sed -i "/^# vm-passthrough:${id}\$/,+1d" "$FSTAB"
    printf '%s\n%s\n' "# vm-passthrough:${id}" "$linha" | sudo tee -a "$FSTAB" >/dev/null
    info "fstab: linha '${id}' definida."
}

fstab_remover_linha() {
    local id="$1"
    sudo sed -i "/^# vm-passthrough:${id}\$/,+1d" "$FSTAB"
}

fstab_tem_linha() {
    grep -q "^# vm-passthrough:${1}\$" "$FSTAB" 2>/dev/null
}

# --- XML da VM ------------------------------------------------------------------
# Todo XML de domínio, de rede e todo JSON do qemu-img passam pelo core Python
# através da ponte única. As funções desta seção permanecem a API pública do
# shell (mesmos nomes, mesmos argumentos, mesmas variáveis de erro): elas
# capturam o snapshot, transportam por stdin e traduzem a resposta. Nenhuma
# delas interpola dado local em argv nem interpreta JSON com regex.

_xml_ler_arquivo() {
    # Publica o conteúdo do arquivo em XML_CONTEUDO sem executá-lo e sem
    # aceitar link simbólico no lugar do snapshot.
    local arquivo="${1:-}"
    XML_CONTEUDO=""
    [ -n "$arquivo" ] && [ -f "$arquivo" ] && [ ! -L "$arquivo" ] || return 1
    XML_CONTEUDO="$(<"$arquivo")" || return 1
    [ -n "$XML_CONTEUDO" ] || return 1
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

# Allowlist mínima comum a toda resposta do core.
CORE_PARES_ENVELOPE=(CORE_VERSION PROTOCOL_VERSION SUBCOMMAND)

DISCARD_XML_ERRO=""
DISCARD_XML_ESTADO=""
DISCARD_XML_FINGERPRINT=""
xml_disco_qcow2_estado() {
    # Retornos: 0=discard ativo no único disco alvo; 1=alvo único sem unmap;
    # 2=XML inválido, alvo ausente/duplicado ou estrutura ambígua.
    local arquivo="${1:-}" qcow2="${2:-}"
    local -a permitidas=(
        "${CORE_PARES_ENVELOPE[@]}"
        STATE DISCARD DRIVER_TYPE TARGET_DEV DISK_COUNT FINGERPRINT
    )
    local -a payload=()
    DISCARD_XML_ERRO=""
    DISCARD_XML_ESTADO=""
    DISCARD_XML_FINGERPRINT=""
    _xml_ler_arquivo "$arquivo" && caminho_absoluto_seguro "$qcow2" \
        || { DISCARD_XML_ERRO="XML ou QCOW2_PATH inválido."; DISCARD_XML_ESTADO=erro; return 2; }
    payload=(xml "$XML_CONTEUDO" qcow2_path "$qcow2")
    if ! python_core_pares_payload permitidas DISCO_ domain-disk-target payload \
            2>/dev/null; then
        DISCARD_XML_ESTADO=erro
        DISCARD_XML_ERRO="$(_core_diagnostico 'Falha ao analisar o disco QCOW2 alvo.')"
        return 2
    fi
    DISCARD_XML_FINGERPRINT="${DISCO_FINGERPRINT:-}"
    case "${DISCO_STATE:-}" in
        ativo) DISCARD_XML_ESTADO=ativo; return 0 ;;
        ausente) DISCARD_XML_ESTADO=ausente; return 1 ;;
    esac
    DISCARD_XML_ESTADO=erro
    DISCARD_XML_ERRO="Estado de discard não reconhecido na resposta do core."
    return 2
}

XML_DOMINIO_ERRO=""
XML_DOMINIO_FINGERPRINT=""
xml_dominio_fingerprint() {
    # Fingerprint canônico do XML de domínio, para detectar mudança concorrente
    # antes de aplicar e antes de restaurar.
    local arquivo="${1:-}"
    local -a permitidas=("${CORE_PARES_ENVELOPE[@]}" FINGERPRINT)
    local -a payload=()
    XML_DOMINIO_ERRO=""
    XML_DOMINIO_FINGERPRINT=""
    _xml_ler_arquivo "$arquivo" \
        || { XML_DOMINIO_ERRO="XML de domínio ausente ou ilegível."; return 1; }
    payload=(xml "$XML_CONTEUDO")
    if ! python_core_pares_payload permitidas XMLFP_ domain-fingerprint payload \
            2>/dev/null; then
        XML_DOMINIO_ERRO="$(_core_diagnostico 'Não foi possível calcular o fingerprint do XML.')"
        return 1
    fi
    XML_DOMINIO_FINGERPRINT="$XMLFP_FINGERPRINT"
}

XML_CANDIDATO_ERRO=""
XML_CANDIDATO_MUDOU=0
XML_CANDIDATO_FINGERPRINT_ANTES=""
XML_CANDIDATO_FINGERPRINT_DEPOIS=""
_xml_candidato_permitidas=(
    CORE_VERSION PROTOCOL_VERSION SUBCOMMAND
    CHANGED OPERATION_COUNT FINGERPRINT_BEFORE FINGERPRINT_AFTER
    BYTES_WRITTEN SHA256
)
_xml_candidato_gerar() {
    # $1 = XML de origem; $2 = destino; demais = pares do payload da operação.
    # O core gera o candidato num temporário controlado e a ponte publica no
    # destino somente quando a geração é aceita, então uma recusa nunca deixa
    # candidato parcial. O destino continua sendo validado pelo shell com
    # virt-xml-validate antes do primeiro define.
    local origem="${1:-}" destino="${2:-}"
    local -a payload=()
    shift 2 || true
    XML_CANDIDATO_ERRO=""
    XML_CANDIDATO_MUDOU=0
    XML_CANDIDATO_FINGERPRINT_ANTES=""
    XML_CANDIDATO_FINGERPRINT_DEPOIS=""
    _xml_ler_arquivo "$origem" \
        || { XML_CANDIDATO_ERRO="XML de origem ausente ou ilegível."; return 1; }
    payload=(xml "$XML_CONTEUDO" "$@")
    if ! python_core_candidato _xml_candidato_permitidas XMLCAND_ payload "$destino" \
            2>/dev/null; then
        XML_CANDIDATO_ERRO="$(_core_diagnostico 'Falha ao gerar o XML candidato.')"
        return 1
    fi
    XML_CANDIDATO_MUDOU="$XMLCAND_CHANGED"
    XML_CANDIDATO_FINGERPRINT_ANTES="$XMLCAND_FINGERPRINT_BEFORE"
    XML_CANDIDATO_FINGERPRINT_DEPOIS="$XMLCAND_FINGERPRINT_AFTER"
}

xml_candidato_discard() {
    # xml_candidato_discard ORIGEM DESTINO QCOW2_PATH
    _xml_candidato_gerar "$1" "$2" \
        op_count 1 op_0 disk-discard op_0_qcow2_path "$3" op_0_value unmap
}

xml_candidato_sem_video() {
    # xml_candidato_sem_video ORIGEM DESTINO
    _xml_candidato_gerar "$1" "$2" op_count 1 op_0 remove-video
}

xml_candidato_anti_code43() {
    # xml_candidato_anti_code43 ORIGEM DESTINO [VENDOR_ID]
    local vendor="${3:-randomid123}"
    _xml_candidato_gerar "$1" "$2" \
        op_count 1 op_0 anti-code43 op_0_vendor_id "$vendor"
}

xml_candidato_fonte_nic() {
    # xml_candidato_fonte_nic ORIGEM DESTINO MAC TIPO ATRIBUTO VALOR
    _xml_candidato_gerar "$1" "$2" \
        op_count 1 op_0 nic-source \
        op_0_mac "$3" op_0_type "$4" op_0_attribute "$5" op_0_value "$6"
}

XML_COMPARACAO_ERRO=""
XML_COMPARACAO_DIFERENCA=""
xml_dominio_equivalente() {
    # xml_dominio_equivalente ESQUERDA DIREITA [PROJECAO]
    # Retornos: 0=equivalente na projeção; 1=divergente; 2=erro de análise.
    # PROJECAO: full (padrão), cpu-unmanaged, devices-unmanaged.
    local esquerda="${1:-}" direita="${2:-}" projecao="${3:-full}" conteudo_esquerda
    local -a permitidas=(
        "${CORE_PARES_ENVELOPE[@]}" EQUAL DIFFERENCE FINGERPRINT_LEFT FINGERPRINT_RIGHT
    )
    local -a payload=()
    XML_COMPARACAO_ERRO=""
    XML_COMPARACAO_DIFERENCA=""
    _xml_ler_arquivo "$esquerda" \
        || { XML_COMPARACAO_ERRO="XML de referência ausente ou ilegível."; return 2; }
    conteudo_esquerda="$XML_CONTEUDO"
    _xml_ler_arquivo "$direita" \
        || { XML_COMPARACAO_ERRO="XML observado ausente ou ilegível."; return 2; }
    payload=(left "$conteudo_esquerda" right "$XML_CONTEUDO" projection "$projecao")
    if ! python_core_pares_payload permitidas XMLCMP_ domain-compare payload \
            2>/dev/null; then
        XML_COMPARACAO_ERRO="$(_core_diagnostico 'Não foi possível comparar os XML.')"
        return 2
    fi
    XML_COMPARACAO_DIFERENCA="$XMLCMP_DIFFERENCE"
    [ "$XMLCMP_EQUAL" = 1 ] || return 1
    return 0
}

xml_backup() {
    # Backup único e validado do XML inativo. O caminho também fica em
    # XML_BACKUP_PATH para consumidores que precisem mostrá-lo em rollback.
    local vm="$1" destino
    XML_BACKUP_PATH=""
    mkdir -p "$BACKUPS_DIR"
    destino="$(mktemp "$BACKUPS_DIR/${vm}-$(date +%Y%m%d-%H%M%S)-XXXXXX.xml")" \
        || falhar "Não foi possível criar destino exclusivo para o backup XML."
    if ! $VIRSH dumpxml --inactive "$vm" > "$destino"; then
        rm -f -- "$destino"
        falhar "Falha ao salvar backup do XML da VM '$vm'."
    fi
    [ -s "$destino" ] || { rm -f -- "$destino"; falhar "O backup XML da VM ficou vazio."; }
    XML_BACKUP_PATH="$destino"
    info "Backup do XML salvo em: $destino"
}

vm_existe() { LC_ALL=C $VIRSH dominfo "$1" >/dev/null 2>&1; }
vm_estado() {
    local estado rc
    if estado="$(LC_ALL=C $VIRSH domstate "$1" 2>/dev/null)"; then
        sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<< "$estado"
    else
        rc=$?
        return "$rc"
    fi
}
vm_desligada() {
    local estado
    estado="$(vm_estado "$1")" || return $?
    [ "$estado" = "shut off" ]
}

exigir_vm_desligada() {
    vm_existe "$1" || falhar "A VM '$1' não existe. Execute a etapa 40 antes."
    vm_desligada "$1" \
        || falhar "A VM '$1' precisa estar DESLIGADA (use: virsh --connect qemu:///system shutdown $1)."
}

# --- CPUs ------------------------------------------------------------------------
expandir_lista_cpus() {
    # "0-2,5,8-9" -> imprime uma CPU por linha, preservando a ordem declarada.
    local lista="${1:-}" parte inicio fim cpu
    local -a partes=()
    lista_cpus_valida "$lista" || return 1
    IFS=',' read -r -a partes <<< "$lista"
    for parte in "${partes[@]}"; do
        if [[ "$parte" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            inicio=$((10#${BASH_REMATCH[1]}))
            fim=$((10#${BASH_REMATCH[2]}))
            for ((cpu = inicio; cpu <= fim; cpu++)); do
                printf '%s\n' "$cpu"
            done
        else
            printf '%s\n' "$((10#$parte))"
        fi
    done
}

# I5: validar_particao_cpus foi removida. Ela era a validação relacional
# antiga, por contagem de CPUs contíguas, e ficou sem consumidor quando
# validar_layout_cpu passou a exigir topologia real. Mantê-la significaria
# duas implementações da mesma política, uma delas cega para socket, core e
# CPU offline.

cpu_topologia_csv() {
    # Saída estável e não localizada: CPU,CORE,SOCKET,NODE,ONLINE.
    LC_ALL=C lscpu -p=CPU,CORE,SOCKET,NODE,ONLINE 2>/dev/null \
        | awk -F, '!/^#/ && NF { print }'
}

normalizar_conjunto_cpus() {
    local lista="${1:-}"
    lista_cpus_valida "$lista" || return 1
    expandir_lista_cpus "$lista" | LC_ALL=C sort -n | paste -sd, -
}

CPU_LAYOUT_ERRO=""
CPU_LAYOUT_ONLINE=""
CPU_LAYOUT_FINGERPRINT=""
validar_layout_cpu() {
    # validar_layout_cpu CPUS_VM CPUS_HOST VM_VCPUS VM_CORES VM_THREADS [CSV]
    # CSV segue lscpu -p=CPU,CORE,SOCKET,NODE,ONLINE. Valida o conjunto exato
    # de CPUs online (inclusive IDs esparsos), siblings completos por core,
    # cardinalidade e produto da topologia. Pelo menos um core inteiro fica no
    # host.
    #
    # I5: a política relacional passou a ter uma implementação só, no core
    # Python. O shell continua sendo quem captura o snapshot (`lscpu` é um
    # probe do host) e quem publica o diagnóstico; as mensagens são as mesmas
    # de antes, porque são API operacional (seção 3.1). Além do veredicto, a
    # chamada devolve o fingerprint canônico da topologia, usado pelas etapas
    # para provar que o host não mudou entre planejar e aplicar.
    local cpus_vm="${1:-}" cpus_host="${2:-}" vcpus="${3:-}"
    local cores="${4:-}" threads="${5:-}" topologia="${6:-}"
    local -a permitidas=(
        "${CORE_PARES_ENVELOPE[@]}"
        VALID ERROR ONLINE_SET ONLINE_COUNT VM_CPU_COUNT VM_CORE_COUNT
        HOST_CORE_COUNT FINGERPRINT
    )
    local -a payload=()
    CPU_LAYOUT_ERRO=""
    CPU_LAYOUT_ONLINE=""
    CPU_LAYOUT_FINGERPRINT=""
    if [ -z "$topologia" ]; then
        topologia="$(cpu_topologia_csv)" \
            || { CPU_LAYOUT_ERRO="lscpu não conseguiu fornecer a topologia parseável."; return 1; }
    fi
    [ -n "$topologia" ] \
        || { CPU_LAYOUT_ERRO="A topologia de CPU está vazia."; return 1; }
    payload=(
        csv "$topologia"
        cpus_vm "$cpus_vm"
        cpus_host "$cpus_host"
        vcpus "$vcpus"
        cores "$cores"
        threads "$threads"
    )
    if ! python_core_pares_payload permitidas CPULAYOUT_ cpu-layout payload \
            2>/dev/null; then
        CPU_LAYOUT_ERRO="$(_core_diagnostico 'Não foi possível validar o layout de CPU.')"
        return 1
    fi
    if [ "${CPULAYOUT_VALID:-0}" != 1 ]; then
        CPU_LAYOUT_ERRO="${CPULAYOUT_ERROR:-Layout de CPU recusado pelo core.}"
        return 1
    fi
    CPU_LAYOUT_ONLINE="${CPULAYOUT_ONLINE_SET:-}"
    CPU_LAYOUT_FINGERPRINT="${CPULAYOUT_FINGERPRINT:-}"
}

CPU_TOPOLOGIA_ERRO=""
CPU_TOPOLOGIA_FINGERPRINT=""
CPU_TOPOLOGIA_ONLINE=""
cpu_topologia_fingerprint() {
    # Publica o fingerprint canônico da topologia recebida (ou lida agora).
    # Reordenar linhas do lscpu não muda o valor; mudar o conjunto online ou o
    # agrupamento de siblings muda. É a base da recusa por conflito TOCTOU.
    local topologia="${1:-}"
    local -a permitidas=(
        "${CORE_PARES_ENVELOPE[@]}"
        VALID ERROR ONLINE_COUNT ONLINE_SET CORE_COUNT SOCKET_COUNT
        THREADS_PER_CORE HOMOGENEOUS BOOT_CORE BOOT_CORE_CPUS FINGERPRINT
    )
    local -a payload=()
    CPU_TOPOLOGIA_ERRO=""
    CPU_TOPOLOGIA_FINGERPRINT=""
    CPU_TOPOLOGIA_ONLINE=""
    if [ -z "$topologia" ]; then
        topologia="$(cpu_topologia_csv)" \
            || { CPU_TOPOLOGIA_ERRO="lscpu não conseguiu fornecer a topologia parseável."; return 1; }
    fi
    [ -n "$topologia" ] \
        || { CPU_TOPOLOGIA_ERRO="A topologia de CPU está vazia."; return 1; }
    payload=(csv "$topologia")
    if ! python_core_pares_payload permitidas CPUTOPO_ cpu-topology payload \
            2>/dev/null; then
        CPU_TOPOLOGIA_ERRO="$(_core_diagnostico 'Não foi possível canonicalizar a topologia de CPU.')"
        return 1
    fi
    if [ "${CPUTOPO_VALID:-0}" != 1 ]; then
        CPU_TOPOLOGIA_ERRO="${CPUTOPO_ERROR:-Topologia de CPU recusada pelo core.}"
        return 1
    fi
    CPU_TOPOLOGIA_FINGERPRINT="${CPUTOPO_FINGERPRINT:-}"
    CPU_TOPOLOGIA_ONLINE="${CPUTOPO_ONLINE_SET:-}"
}

CPU_PLANO_ERRO=""
cpu_plano_pinning() {
    # cpu_plano_pinning CSV [CORES_VM]
    # Sem CORES_VM devolve apenas os limites (para a pergunta ao operador);
    # com CORES_VM devolve a proposta determinística já validada. As variáveis
    # publicadas usam o prefixo CPUPLANO_.
    local topologia="${1:-}" cores_vm="${2:-}"
    local -a permitidas=(
        "${CORE_PARES_ENVELOPE[@]}"
        VALID ERROR TOTAL_CORES THREADS_PER_CORE MAX_VM_CORES DEFAULT_VM_CORES
        BOOT_CORE BOOT_CORE_CPUS ONLINE_SET FINGERPRINT PLANNED CPUS_VM
        CPUS_HOST VCPUS VM_CORES HOST_CORE_COUNT
    )
    local -a payload=()
    CPU_PLANO_ERRO=""
    if [ -z "$topologia" ]; then
        topologia="$(cpu_topologia_csv)" \
            || { CPU_PLANO_ERRO="lscpu não conseguiu fornecer a topologia parseável."; return 1; }
    fi
    [ -n "$topologia" ] \
        || { CPU_PLANO_ERRO="A topologia de CPU está vazia."; return 1; }
    payload=(csv "$topologia" vm_cores "$cores_vm")
    if ! python_core_pares_payload permitidas CPUPLANO_ cpu-plan payload \
            2>/dev/null; then
        CPU_PLANO_ERRO="$(_core_diagnostico 'Não foi possível calcular o plano de pinning.')"
        return 1
    fi
    if [ "${CPUPLANO_VALID:-0}" != 1 ]; then
        CPU_PLANO_ERRO="${CPUPLANO_ERROR:-Plano de pinning recusado pelo core.}"
        return 1
    fi
}

CPU_MEMORIA_ERRO=""
plano_memoria_vm() {
    # plano_memoria_vm TOTAL_MIB [VM_RAM_MIB] [HUGEPAGES_1G]
    # Reserva do host, teto da VM e relação RAM/HugePages em um único lugar.
    # Publica CPUMEM_TOTAL_MIB, CPUMEM_RESERVE_MIB, CPUMEM_MAX_VM_MIB,
    # CPUMEM_MAX_VM_GIB e CPUMEM_HUGEPAGES_1G.
    local total="${1:-}" vm_ram="${2:-}" hugepages="${3:-}"
    local -a permitidas=(
        "${CORE_PARES_ENVELOPE[@]}"
        VALID ERROR TOTAL_MIB RESERVE_MIB MAX_VM_MIB MAX_VM_GIB CHECKED
        VM_RAM_MIB HUGEPAGES_1G
    )
    local -a payload=()
    CPU_MEMORIA_ERRO=""
    payload=(
        total_mib "$total"
        vm_ram_mib "$vm_ram"
        hugepages_1g "$hugepages"
    )
    if ! python_core_pares_payload permitidas CPUMEM_ cpu-memory payload \
            2>/dev/null; then
        CPU_MEMORIA_ERRO="$(_core_diagnostico 'Não foi possível calcular o plano de memória.')"
        return 1
    fi
    if [ "${CPUMEM_VALID:-0}" != 1 ]; then
        CPU_MEMORIA_ERRO="${CPUMEM_ERROR:-Plano de memória recusado pelo core.}"
        return 1
    fi
}

XML_CPU_ERRO=""
xml_cpu_gerar_candidato() {
    # Gera XML com pinning, topologia e página explicitamente de 1 GiB sem
    # remover ajustes não gerenciados de cputune/memoryBacking.
    # Assinatura preservada: ORIGEM DESTINO CPUS_VM CPUS_HOST VCPUS CORES
    # THREADS RAM_MB. O destino só é escrito quando o candidato é aceito.
    local origem="$1" destino="$2" cpus_vm="$3" cpus_host="$4"
    local vcpus="$5" cores="$6" threads="$7" ram_mb="$8"
    local -a permitidas=(
        "${CORE_PARES_ENVELOPE[@]}"
        CHANGED OPERATION_COUNT FINGERPRINT_BEFORE FINGERPRINT_AFTER
        BYTES_WRITTEN SHA256
    )
    local -a payload=()
    XML_CPU_ERRO=""
    _xml_ler_arquivo "$origem" \
        || { XML_CPU_ERRO="XML de origem ausente ou ilegível."; return 1; }
    payload=(
        xml "$XML_CONTEUDO"
        op_count 1
        op_0 cpu-pinning
        op_0_cpus_vm "$cpus_vm"
        op_0_cpus_host "$cpus_host"
        op_0_vcpus "$vcpus"
        op_0_cores "$cores"
        op_0_threads "$threads"
        op_0_ram_mb "$ram_mb"
    )
    if ! python_core_candidato permitidas XMLCPU_ payload "$destino" 2>/dev/null; then
        XML_CPU_ERRO="$(_core_diagnostico 'Falha ao gerar o XML candidato.')"
        return 1
    fi
}

xml_cpu_remover_hugepages() {
    # Remove a exigência de HugePages preservando o restante do memoryBacking.
    local origem="$1" destino="$2"
    local -a permitidas=(
        "${CORE_PARES_ENVELOPE[@]}"
        CHANGED OPERATION_COUNT FINGERPRINT_BEFORE FINGERPRINT_AFTER
        BYTES_WRITTEN SHA256
    )
    local -a payload=()
    XML_CPU_ERRO=""
    _xml_ler_arquivo "$origem" \
        || { XML_CPU_ERRO="XML de origem ausente ou ilegível."; return 1; }
    payload=(xml "$XML_CONTEUDO" op_count 1 op_0 remove-hugepages)
    if ! python_core_candidato permitidas XMLCPU_ payload "$destino" 2>/dev/null; then
        XML_CPU_ERRO="$(_core_diagnostico 'Falha ao remover HugePages do XML candidato.')"
        return 1
    fi
}

validar_xml_cpu_pinning() {
    # validar_xml_cpu_pinning XML CPUS_VM CPUS_HOST VCPUS CORES THREADS RAM_MB MODO
    # MODO: sim exige página de 1 GiB; nao exige ausência; ignorar não avalia.
    local arquivo="$1" cpus_vm="$2" cpus_host="$3" vcpus="$4"
    local cores="$5" threads="$6" ram_mb="$7" modo="${8:-ignorar}"
    local -a permitidas=(
        "${CORE_PARES_ENVELOPE[@]}" VALID VCPUS HUGEPAGES_COUNT FINGERPRINT
    )
    local -a payload=()
    XML_CPU_ERRO=""
    _xml_ler_arquivo "$arquivo" \
        || { XML_CPU_ERRO="XML de CPU/HugePages ausente ou ilegível."; return 1; }
    payload=(
        xml "$XML_CONTEUDO"
        cpus_vm "$cpus_vm"
        cpus_host "$cpus_host"
        vcpus "$vcpus"
        cores "$cores"
        threads "$threads"
        ram_mb "$ram_mb"
        hugepages_mode "$modo"
    )
    if ! python_core_pares_payload permitidas XMLCPU_ domain-validate-cpu payload \
            2>/dev/null; then
        XML_CPU_ERRO="$(_core_diagnostico 'XML de CPU/HugePages inválido.')"
        return 1
    fi
}

xml_sem_hugepages_arquivo() {
    # Retornos: 0=nenhuma HugePage exigida; 1=exige HugePages; 2=erro.
    local arquivo="${1:-}"
    local -a permitidas=(
        "${CORE_PARES_ENVELOPE[@]}"
        BACKING_COUNT HUGEPAGES_COUNT PAGE_COUNT PAGE_BYTES
    )
    local -a payload=()
    XML_CPU_ERRO=""
    _xml_ler_arquivo "$arquivo" \
        || { XML_CPU_ERRO="XML de domínio ausente ou ilegível."; return 2; }
    payload=(xml "$XML_CONTEUDO")
    if ! python_core_pares_payload permitidas XMLHP_ domain-memory-backing payload \
            2>/dev/null; then
        XML_CPU_ERRO="$(_core_diagnostico 'Não foi possível inspecionar memoryBacking.')"
        return 2
    fi
    [ "$XMLHP_HUGEPAGES_COUNT" = 0 ] || return 1
    return 0
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
v_kernel_persistencia_falhou() {
    case "${KERNEL_PERSISTENCIA_TIPO:-erro}" in
        pendente) v_falta "$*" ;;
        indeterminado) v_indeterminado "$*" ;;
        *) v_erro "$*" ;;
    esac
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
