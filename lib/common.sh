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
CONF_ARQUIVO="$PROJETO_DIR/passthrough.conf"
BACKUPS_DIR="$PROJETO_DIR/backups"
FSTAB="/etc/fstab"
GRUB_DEFAULT_ARQUIVO="/etc/default/grub"
GRUB_CFG_ARQUIVO="/boot/grub/grub.cfg"
KERNELSTUB_ENTRIES_DIR="/boot/efi/loader/entries"
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

# --- Pré-checagens ------------------------------------------------------------
exigir_nao_root() {
    if [ "$(id -u)" -eq 0 ]; then
        falhar "Execute como usuário normal (os scripts chamam sudo quando necessário)."
    fi
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
    TRANSFER_USER AIRLOCK_DIR AIRLOCK_BIND AIRLOCK_DISPENSADO
    BACKUPS_VM_DIR BACKUP_DISPENSADO
)

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

validar_valor_conf() {
    local chave="$1" valor="$2"
    [ -z "$valor" ] && return 0
    case "$chave" in
        USUARIO_LINUX|TRANSFER_USER) nome_usuario_valido "$valor" ;;
        VM_STORAGE_GROUP) nome_grupo_vm_dedicado_valido "$valor" ;;
        VM_NAME) nome_vm_valido "$valor" ;;
        BOOTLOADER) [[ "$valor" = kernelstub || "$valor" = grub ]] ;;
        GPU_PCI_ID|GPU_AUDIO_PCI_ID) pci_bdf_valido "$valor" ;;
        GPU_VENDOR_DEVICE_ID|GPU_AUDIO_VENDOR_DEVICE_ID) pci_vendor_device_valido "$valor" ;;
        IOMMU_GROUP_GPU) inteiro_na_faixa "$valor" 0 65535 ;;
        DM_SERVICE) nome_unidade_systemd_valido "$valor" ;;
        NVME_DEVICE|WORKING_DISK_PATH|HD1_BY_ID_PATH|AIRLOCK_DIR|AIRLOCK_BIND|BACKUPS_VM_DIR)
            caminho_absoluto_seguro "$valor" ;;
        QCOW2_PATH) caminho_qcow2_logico_valido "$valor" ;;
        ISO_WINDOWS|ISO_VIRTIO) caminho_artefato_vm_logico_valido "$valor" ;;
        WORKING_DISK_DISPENSADO|HD1_DISPENSADO|AIRLOCK_DISPENSADO|BACKUP_DISPENSADO)
            [[ "$valor" = sim || "$valor" = nao ]] ;;
        QCOW2_TAMANHO) [[ "$valor" =~ ^[1-9][0-9]*[KMGTPE]$ ]] ;;
        VM_RAM_MB) inteiro_na_faixa "$valor" 1024 1048576 ;;
        VM_VCPUS|VM_CORES|VM_THREADS) inteiro_na_faixa "$valor" 1 65535 ;;
        HUGEPAGES_1G) inteiro_na_faixa "$valor" 0 1048576 ;;
        CPUS_VM|CPUS_HOST) lista_cpus_valida "$valor" ;;
        REDE_MODO) [[ "$valor" = bridge || "$valor" = nat ]] ;;
        INTERFACE_FISICA|REDE_BRIDGE|REDE_BRIDGE_LIBVIRT) nome_interface_valido "$valor" ;;
        REDE_LIBVIRT) nome_rede_libvirt_valido "$valor" ;;
        REDE_NAT_CIDR) cidr_privado_24_valido "$valor" ;;
        VM_NIC_MAC) mac_valido "$valor" ;;
        VM_IP_FIXO|IP_FIXO_HOST) ipv4_valido "$valor" ;;
        *) return 1 ;;
    esac
}

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

carregar_conf() {
    local linha conteudo chave valor numero=0
    local -A vistas=()
    [ -e "$CONF_ARQUIVO" ] || return 0
    [ -f "$CONF_ARQUIVO" ] && [ ! -L "$CONF_ARQUIVO" ] \
        || falhar "Configuração precisa ser um arquivo regular, não um link: $CONF_ARQUIVO"

    for chave in "${CHAVES_CONF_PERMITIDAS[@]}"; do
        unset "$chave"
    done

    while IFS= read -r linha || [ -n "$linha" ]; do
        numero=$((numero + 1))
        _trim_espacos_conf "$linha"
        conteudo="$REPLY"
        [ -z "$conteudo" ] && continue
        [[ "$conteudo" == \#* ]] && continue
        if ! [[ "$conteudo" =~ ^([A-Z][A-Z0-9_]*)[[:space:]]*=(.*)$ ]]; then
            falhar "Linha $numero inválida em $CONF_ARQUIVO: somente CHAVE=literal é permitido."
        fi
        chave="${BASH_REMATCH[1]}"
        chave_conf_permitida "$chave" \
            || falhar "Chave desconhecida '$chave' na linha $numero de $CONF_ARQUIVO."
        [ -z "${vistas[$chave]+definida}" ] \
            || falhar "Chave '$chave' repetida na linha $numero de $CONF_ARQUIVO."
        _decodificar_literal_conf "${BASH_REMATCH[2]}" \
            || falhar "Literal inseguro ou malformado para '$chave' na linha $numero de $CONF_ARQUIVO."
        valor="$REPLY"
        validar_valor_conf "$chave" "$valor" \
            || falhar "Valor inválido para '$chave' na linha $numero de $CONF_ARQUIVO."
        printf -v "$chave" '%s' "$valor"
        export "$chave"
        vistas[$chave]=1
    done < "$CONF_ARQUIVO"
}

_citar_conf() {
    # Serializa para o subconjunto literal compreendido pelo parser acima.
    local valor="$1" caractere i
    printf '"'
    for ((i = 0; i < ${#valor}; i++)); do
        caractere="${valor:i:1}"
        if [ "$caractere" = '\' ] || [ "$caractere" = '"' ] \
           || [ "$caractere" = '$' ] || [ "$caractere" = '`' ]; then
            printf '\\'
        fi
        printf '%s' "$caractere"
    done
    printf '"'
}

salvar_conf() {
    # Atualização atômica: valida chave/valor, preserva os comentários e nunca
    # transforma o conteúdo em sintaxe shell executável.
    local chave="$1" valor="$2" tmp linha
    chave_conf_permitida "$chave" || falhar "Chave de configuração não permitida: '$chave'."
    validar_valor_conf "$chave" "$valor" || falhar "Valor inválido para a chave '$chave'."
    [ ! -L "$CONF_ARQUIVO" ] || falhar "Recusando atualizar link simbólico: $CONF_ARQUIVO"
    linha="${chave}=$(_citar_conf "$valor")"
    tmp="$(umask 077; mktemp "${CONF_ARQUIVO}.tmp.XXXXXX")" \
        || falhar "Não foi possível criar arquivo temporário ao lado de $CONF_ARQUIVO."

    if [ -f "$CONF_ARQUIVO" ]; then
        chmod --reference="$CONF_ARQUIVO" "$tmp" 2>/dev/null \
            || { rm -f -- "$tmp"; falhar "Não foi possível preservar as permissões do conf."; }
        if grep -q "^${chave}=" "$CONF_ARQUIVO"; then
            if ! CONF_CHAVE="$chave" CONF_LINHA="$linha" awk '
                BEGIN { k = ENVIRON["CONF_CHAVE"]; l = ENVIRON["CONF_LINHA"] }
                index($0, k "=") == 1 && !feito { print l; feito = 1; next }
                { print }
            ' "$CONF_ARQUIVO" > "$tmp"; then
                rm -f -- "$tmp"
                falhar "Falha ao atualizar '$chave' no arquivo de configuração."
            fi
        else
            if ! cat -- "$CONF_ARQUIVO" > "$tmp" || ! printf '%s\n' "$linha" >> "$tmp"; then
                rm -f -- "$tmp"
                falhar "Falha ao acrescentar '$chave' no arquivo de configuração."
            fi
        fi
    elif ! printf '%s\n' "$linha" > "$tmp"; then
        rm -f -- "$tmp"
        falhar "Falha ao criar o arquivo de configuração."
    fi

    mv -f -- "$tmp" "$CONF_ARQUIVO" || { rm -f -- "$tmp"; falhar "Falha ao instalar $CONF_ARQUIVO."; }
    printf -v "$chave" '%s' "$valor"
    export "$chave"
}

salvar_conf_lote() {
    # salvar_conf_lote CHAVE VALOR [CHAVE VALOR...]. Valida tudo primeiro e
    # publica o conjunto em um único rename, evitando relações CPU parcialmente
    # atualizadas se a etapa for interrompida.
    local tmp linha conteudo chave valor serializado i
    local -a chaves=() valores=()
    local -A novos=() linhas_novas=() encontradas=()
    [ "$#" -ge 2 ] && [ $(( $# % 2 )) -eq 0 ] \
        || falhar "salvar_conf_lote exige pares CHAVE/VALOR."
    while [ "$#" -gt 0 ]; do
        chave="$1"; valor="$2"; shift 2
        chave_conf_permitida "$chave" \
            || falhar "Chave de configuração não permitida no lote: '$chave'."
        [ -z "${novos[$chave]+definida}" ] \
            || falhar "Chave repetida no lote: '$chave'."
        validar_valor_conf "$chave" "$valor" \
            || falhar "Valor inválido para a chave '$chave'."
        serializado="$(_citar_conf "$valor")"
        chaves+=("$chave")
        valores+=("$valor")
        novos[$chave]="$valor"
        linhas_novas[$chave]="${chave}=${serializado}"
    done
    [ ! -L "$CONF_ARQUIVO" ] || falhar "Recusando atualizar link simbólico: $CONF_ARQUIVO"
    tmp="$(umask 077; mktemp "${CONF_ARQUIVO}.tmp.XXXXXX")" \
        || falhar "Não foi possível criar temporário ao lado de $CONF_ARQUIVO."
    if [ -f "$CONF_ARQUIVO" ]; then
        chmod --reference="$CONF_ARQUIVO" "$tmp" 2>/dev/null \
            || { rm -f -- "$tmp"; falhar "Não foi possível preservar as permissões do conf."; }
    fi
    if ! {
        if [ -f "$CONF_ARQUIVO" ]; then
            while IFS= read -r linha || [ -n "$linha" ]; do
                _trim_espacos_conf "$linha"
                conteudo="$REPLY"
                if [[ "$conteudo" =~ ^([A-Z][A-Z0-9_]*)[[:space:]]*= ]]; then
                    chave="${BASH_REMATCH[1]}"
                    if [ -n "${novos[$chave]+definida}" ]; then
                        printf '%s\n' "${linhas_novas[$chave]}"
                        encontradas[$chave]=1
                        continue
                    fi
                fi
                printf '%s\n' "$linha"
            done < "$CONF_ARQUIVO"
        fi
        for chave in "${chaves[@]}"; do
            [ -n "${encontradas[$chave]+definida}" ] \
                || printf '%s\n' "${linhas_novas[$chave]}"
        done
    } > "$tmp"; then
        rm -f -- "$tmp"
        falhar "Falha ao preparar atualização em lote do arquivo de configuração."
    fi
    mv -f -- "$tmp" "$CONF_ARQUIVO" \
        || { rm -f -- "$tmp"; falhar "Falha ao instalar o lote em $CONF_ARQUIVO."; }
    for i in "${!chaves[@]}"; do
        printf -v "${chaves[$i]}" '%s' "${valores[$i]}"
        export "${chaves[$i]}"
    done
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
    # Reserva mínima do host: 25% do total, nunca abaixo de 4 GiB nem acima de 8.
    local total reserva
    total="$(ram_total_mib)"
    reserva=$((total / 4))
    [ "$reserva" -lt 4096 ] && reserva=4096
    [ "$reserva" -gt 8192 ] && reserva=8192
    echo "$reserva"
}

ram_max_vm_mib() {
    # Teto para a VM: total menos a reserva do host, arredondado para baixo em
    # múltiplos de 1024 MiB (exigência das HugePages de 1 GiB da etapa 52).
    local total reserva max
    total="$(ram_total_mib)"
    reserva="$(ram_reserva_host_mib)"
    max=$((total - reserva))
    max=$(((max / 1024) * 1024))
    [ "$max" -lt 1024 ] && max=0
    echo "$max"
}

# --- Bootloader e parâmetros de kernel (Capítulos 15 e 16) --------------------
BOOTLOADER_VALIDACAO_ERRO=""
BOOTLOADER_ATIVO=""
detectar_bootloader() {
    # Prefere evidência do loader que iniciou a sessão. A simples presença do
    # binário kernelstub não basta: ele pode coexistir com um GRUB ativo. O
    # argumento opcional injeta a evidência apenas em chamadas unitárias.
    local bootctl_status="" tem_kernelstub=0 tem_grub=0 injetado="${1:-}"
    if [ -n "$injetado" ]; then
        case "$injetado" in grub|kernelstub|desconhecido) printf '%s\n' "$injetado"; return ;; esac
        printf '%s\n' desconhecido
        return
    fi
    command -v kernelstub >/dev/null 2>&1 && tem_kernelstub=1
    [ -f "$GRUB_CFG_ARQUIVO" ] && tem_grub=1
    if command -v bootctl >/dev/null 2>&1; then
        bootctl_status="$(LC_ALL=C bootctl status --no-pager 2>/dev/null || true)"
        if grep -A6 -F 'Current Boot Loader:' <<< "$bootctl_status" | grep -qi 'systemd-boot'; then
            [ "$tem_kernelstub" -eq 1 ] && { echo kernelstub; return; }
            echo desconhecido
            return
        elif grep -A6 -F 'Current Boot Loader:' <<< "$bootctl_status" | grep -qi 'grub'; then
            echo grub
            return
        fi
    fi
    if [ "$tem_grub" -eq 1 ] && [ "$tem_kernelstub" -eq 0 ]; then
        echo grub
    elif [ "$tem_kernelstub" -eq 1 ] && [ "$tem_grub" -eq 0 ]; then
        echo kernelstub
    elif [ "$tem_grub" -eq 1 ] && [ "$tem_kernelstub" -eq 1 ]; then
        # Sem prova do loader atual, escolher qualquer um seria perigoso.
        echo desconhecido
    else
        echo desconhecido
    fi
}

validar_bootloader_configurado() {
    local persistido="${1:-${BOOTLOADER:-}}" efetivo_injetado="${2:-}" efetivo
    BOOTLOADER_VALIDACAO_ERRO=""
    BOOTLOADER_ATIVO=""
    [ -n "$persistido" ] \
        || { BOOTLOADER_VALIDACAO_ERRO="BOOTLOADER não está definido em $CONF_ARQUIVO."; return 1; }
    [ "$PLATAFORMA_CARREGADA" -eq 1 ] || plataforma_carregar \
        || { BOOTLOADER_VALIDACAO_ERRO="$PLATAFORMA_ERRO"; return 1; }
    efetivo="$(detectar_bootloader "$efetivo_injetado")"
    case "$efetivo" in
        grub|kernelstub) ;;
        *) BOOTLOADER_VALIDACAO_ERRO="Bootloader efetivo não pôde ser determinado sem ambiguidade."; return 1 ;;
    esac
    plataforma_boot_backend_suportado "$efetivo" \
        || { BOOTLOADER_VALIDACAO_ERRO="Bootloader efetivo '$efetivo' não é suportado pelo perfil $PLATAFORMA_PERFIL."; return 1; }
    [ "$persistido" = "$efetivo" ] \
        || { BOOTLOADER_VALIDACAO_ERRO="Divergência de boot: passthrough.conf registra '$persistido', mas o boot efetivo é '$efetivo'. Execute a etapa 02 e confirme a migração com backup."; return 1; }
    BOOTLOADER_ATIVO="$efetivo"
}

_kernelstub_entries_diretas_legiveis() {
    local entrada restaurar_nullglob=0
    local -a entradas=()
    [ -d "$KERNELSTUB_ENTRIES_DIR" ] || return 1
    shopt -q nullglob || { shopt -s nullglob; restaurar_nullglob=1; }
    entradas=("$KERNELSTUB_ENTRIES_DIR"/*.conf)
    [ "$restaurar_nullglob" -eq 0 ] || shopt -u nullglob
    [ "${#entradas[@]}" -gt 0 ] || return 1
    for entrada in "${entradas[@]}"; do
        [ -f "$entrada" ] && [ -r "$entrada" ] || return 1
    done
}

boot_backend_observavel() {
    # Retornos: 0=observável, 1=backend inválido/ausente, 2=leitura
    # privilegiada indisponível. Nunca solicita senha.
    validar_bootloader_configurado "${1:-${BOOTLOADER:-}}" || return 1
    case "$BOOTLOADER_ATIVO" in
        grub)
            [ -r "$GRUB_DEFAULT_ARQUIVO" ] || return 2
            [ -r "$GRUB_CFG_ARQUIVO" ] && return 0
            command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null && return 0
            return 2
            ;;
        kernelstub)
            command -v kernelstub >/dev/null 2>&1 || return 1
            [ -d "$KERNELSTUB_ENTRIES_DIR" ] || return 1
            _kernelstub_entries_diretas_legiveis && return 0
            command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null && return 0
            return 2
            ;;
    esac
    return 1
}

exigir_bootloader_coerente() {
    validar_bootloader_configurado || falhar "$BOOTLOADER_VALIDACAO_ERRO"
}

cmdline_tem() {
    # cmdline_tem "param" -> 0 se o parâmetro exato está ativo neste boot.
    local procurado="$1" palavra conteudo
    local -a palavras=()
    IFS= read -r conteudo < /proc/cmdline || return 1
    read -r -a palavras <<< "$conteudo"
    for palavra in "${palavras[@]}"; do
        [ "$palavra" = "$procurado" ] && return 0
    done
    return 1
}

CMDLINE_PARAM_ERRO=""
cmdline_parametros_exatos() {
    # cmdline_parametros_exatos "chave=valor ..." [CMDLINE]
    # Exige exatamente uma ocorrência de cada chave e o valor literal esperado.
    # Quando CMDLINE não é informado, lê o kernel em execução.
    local esperados="${1:-}" conteudo="" desejado palavra chave encontrada quantidade
    local -a lista_esperada=() palavras=()
    CMDLINE_PARAM_ERRO=""
    kernel_parametros_validos "$esperados" \
        || { CMDLINE_PARAM_ERRO="Lista de parâmetros esperados inválida: '$esperados'."; return 1; }
    if [ "$#" -ge 2 ]; then
        conteudo="$2"
    else
        IFS= read -r conteudo < /proc/cmdline \
            || { CMDLINE_PARAM_ERRO="Não foi possível ler /proc/cmdline."; return 1; }
    fi
    read -r -a lista_esperada <<< "$esperados"
    read -r -a palavras <<< "$conteudo"
    for desejado in "${lista_esperada[@]}"; do
        chave="${desejado%%=*}"
        quantidade=0
        encontrada=""
        for palavra in "${palavras[@]}"; do
            if [ "${palavra%%=*}" = "$chave" ]; then
                quantidade=$((quantidade + 1))
                encontrada="$palavra"
            fi
        done
        [ "$quantidade" -eq 1 ] \
            || { CMDLINE_PARAM_ERRO="A chave '$chave' aparece $quantidade vez(es) na cmdline; esperado: exatamente uma."; return 1; }
        [ "$encontrada" = "$desejado" ] \
            || { CMDLINE_PARAM_ERRO="A chave '$chave' está como '$encontrada'; esperado: '$desejado'."; return 1; }
    done
}

cmdline_possui_alguma_chave() {
    local chaves="${1:-}" conteudo="" palavra procurada
    local -a palavras=() lista_chaves=()
    kernel_parametros_validos "$chaves" || return 2
    if [ "$#" -ge 2 ]; then
        conteudo="$2"
    else
        IFS= read -r conteudo < /proc/cmdline || return 2
    fi
    read -r -a palavras <<< "$conteudo"
    read -r -a lista_chaves <<< "$chaves"
    for palavra in "${palavras[@]}"; do
        for procurada in "${lista_chaves[@]}"; do
            [ "${palavra%%=*}" != "${procurada%%=*}" ] || return 0
        done
    done
    return 1
}

_parametros_por_chaves_cmdline() {
    # Imprime, na ordem de CHAVES, os valores presentes em CMDLINE. Falha se
    # uma chave estiver duplicada, pois esse estado não pode ser restaurado ou
    # comparado de forma inequívoca.
    local cmdline="$1" chaves="$2" chave_token chave palavra quantidade encontrado saida=""
    local -a lista_chaves=() palavras=()
    kernel_parametros_validos "$chaves" || return 1
    read -r -a lista_chaves <<< "$chaves"
    read -r -a palavras <<< "$cmdline"
    for chave_token in "${lista_chaves[@]}"; do
        chave="${chave_token%%=*}"
        quantidade=0
        encontrado=""
        for palavra in "${palavras[@]}"; do
            if [ "${palavra%%=*}" = "$chave" ]; then
                quantidade=$((quantidade + 1))
                encontrado="$palavra"
            fi
        done
        [ "$quantidade" -le 1 ] || return 1
        [ "$quantidade" -eq 0 ] || saida="${saida:+$saida }$encontrado"
    done
    printf '%s\n' "$saida"
}

_parametros_por_chaves_cmdline_tolerante() {
    # Inventário para reparo: preserva todas as ocorrências (inclusive legadas
    # duplicadas), agrupadas pela ordem das chaves solicitadas.
    local cmdline="$1" chaves="$2" chave_token chave palavra saida=""
    local -a lista_chaves=() palavras=()
    kernel_parametros_validos "$chaves" || return 1
    read -r -a lista_chaves <<< "$chaves"
    read -r -a palavras <<< "$cmdline"
    for chave_token in "${lista_chaves[@]}"; do
        chave="${chave_token%%=*}"
        for palavra in "${palavras[@]}"; do
            [ "${palavra%%=*}" = "$chave" ] || continue
            saida="${saida:+$saida }$palavra"
        done
    done
    printf '%s\n' "$saida"
}

kernel_parametros_validos() {
    local params="${1:-}" parametro chave
    local -a itens=()
    local -A chaves=()
    read -r -a itens <<< "$params"
    [ "${#itens[@]}" -gt 0 ] || return 1
    for parametro in "${itens[@]}"; do
        [[ "$parametro" =~ ^[[:alnum:]][[:alnum:]_.-]*(=[[:alnum:]_.,:/+-]+)?$ ]] || return 1
        chave="${parametro%%=*}"
        [ -z "${chaves[$chave]+definida}" ] || return 1
        chaves[$chave]=1
    done
}

_cmdline_sem_chaves() {
    # Imprime CMDLINE sem qualquer valor das chaves presentes em PARAMS.
    local cmdline="$1" params="$2" atual desejado chave_atual chave_desejada saida=""
    local -a atuais=() desejados=()
    read -r -a atuais <<< "$cmdline"
    read -r -a desejados <<< "$params"
    for atual in "${atuais[@]}"; do
        chave_atual="${atual%%=*}"
        for desejado in "${desejados[@]}"; do
            chave_desejada="${desejado%%=*}"
            [ "$chave_atual" != "$chave_desejada" ] || continue 2
        done
        saida="${saida:+$saida }$atual"
    done
    printf '%s\n' "$saida"
}

_kernelstub_linhas_opcoes() {
    # Prefere leitura direta; somente usa sudo não interativo quando os entries
    # existem mas não são legíveis pelo operador. O diretório é argumento de
    # bash -c, nunca interpolado como código.
    local entrada
    local -a entradas=() opcoes=()
    if _kernelstub_entries_diretas_legiveis; then
        entradas=("$KERNELSTUB_ENTRIES_DIR"/*.conf)
        for entrada in "${entradas[@]}"; do
            mapfile -t opcoes < <(grep -E '^[[:space:]]*options[[:space:]]+' -- "$entrada")
            [ "${#opcoes[@]}" -eq 1 ] || return 3
            printf '%s\n' "${opcoes[0]}"
        done
        return 0
    fi
    command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null || return 2
    sudo -n bash -c '
        shopt -s nullglob
        entradas=("$1"/*.conf)
        ((${#entradas[@]} > 0)) || exit 2
        for entrada in "${entradas[@]}"; do
            mapfile -t opcoes < <(grep -E "^[[:space:]]*options[[:space:]]+" -- "$entrada")
            ((${#opcoes[@]} == 1)) || exit 3
            printf "%s\n" "${opcoes[0]}"
        done
    ' _ "$KERNELSTUB_ENTRIES_DIR"
}

_kernelstub_parametros_por_chaves() {
    # Lê todas as entradas pendentes e só retorna um estado quando cada entrada
    # possui, para as chaves gerenciadas, exatamente o mesmo conjunto sem
    # duplicações. sudo -n impede prompts durante --verificar; etapas mutáveis
    # já obtiveram o ticket antes de chamar esta função.
    local params="$1" linhas linha opcoes estado referencia="" primeira=1
    linhas="$(_kernelstub_linhas_opcoes)" || return 1
    [ -n "$linhas" ] || return 1

    while IFS= read -r linha || [ -n "$linha" ]; do
        [[ "$linha" =~ ^[[:space:]]*options[[:space:]]+(.+)$ ]] || return 1
        opcoes="${BASH_REMATCH[1]}"
        estado="$(_parametros_por_chaves_cmdline "$opcoes" "$params")" || return 1
        if [ "$primeira" -eq 1 ]; then
            referencia="$estado"
            primeira=0
        elif [ "$estado" != "$referencia" ]; then
            return 1
        fi
    done <<< "$linhas"
    [ "$primeira" -eq 0 ] || return 1
    printf '%s\n' "$referencia"
}

_kernelstub_parametros_para_mutacao() {
    # Igual ao leitor estrito, mas aceita duplicações idênticas entre entries
    # para que o SET/DEL consiga saneá-las. Entries divergentes continuam
    # bloqueadas antes de qualquer mutação.
    local params="$1" linhas linha opcoes estado referencia="" primeira=1
    linhas="$(_kernelstub_linhas_opcoes)" || return 1
    [ -n "$linhas" ] || return 1
    while IFS= read -r linha || [ -n "$linha" ]; do
        [[ "$linha" =~ ^[[:space:]]*options[[:space:]]+(.+)$ ]] || return 1
        opcoes="${BASH_REMATCH[1]}"
        estado="$(_parametros_por_chaves_cmdline_tolerante "$opcoes" "$params")" || return 1
        if [ "$primeira" -eq 1 ]; then
            referencia="$estado"
            primeira=0
        elif [ "$estado" != "$referencia" ]; then
            return 1
        fi
    done <<< "$linhas"
    [ "$primeira" -eq 0 ] || return 1
    printf '%s\n' "$referencia"
}

_kernelstub_aplicar_estado() {
    # _kernelstub_aplicar_estado CHAVES "NOVO_ESTADO". Executa em subshell com
    # rollback no EXIT/sinal; o caller só recebe sucesso após reler todos os
    # loader entries e comprovar a pós-condição.
    local chaves="$1" novo="$2" antigo
    antigo="$(_kernelstub_parametros_para_mutacao "$chaves")" \
        || { KERNEL_PERSISTENCIA_ERRO="Loader entries divergentes ou ilegíveis; nada foi alterado."; return 1; }
    if [ "$antigo" = "$novo" ]; then
        return 0
    fi
    if ! (
        alterado=0
        concluido=0
        rollback_kernelstub() {
            local status="$1" atual restaurado
            trap - EXIT INT TERM
            if [ "$alterado" -eq 1 ] && [ "$concluido" -eq 0 ]; then
                erro "Transação kernelstub falhou; restaurando o estado anterior."
                if atual="$(_kernelstub_parametros_para_mutacao "$chaves")"; then
                    [ -z "$atual" ] || sudo kernelstub -d "$atual" >/dev/null 2>&1 || true
                else
                    # Estado intermediário ilegível: tente retirar tanto o
                    # destino quanto o snapshot antes de restaurar.
                    [ -z "$novo" ] || sudo kernelstub -d "$novo" >/dev/null 2>&1 || true
                    [ -z "$antigo" ] || sudo kernelstub -d "$antigo" >/dev/null 2>&1 || true
                fi
                if [ -n "$antigo" ]; then
                    sudo kernelstub -a "$antigo" >/dev/null 2>&1 || true
                fi
                restaurado="$(_kernelstub_parametros_para_mutacao "$chaves")" || restaurado="__ERRO__"
                if [ "$restaurado" != "$antigo" ]; then
                    erro "ROLLBACK KERNELSTUB NÃO COMPROVADO. Não reinicie antes de revisar os loader entries."
                else
                    aviso "Rollback kernelstub comprovado em todos os loader entries."
                fi
            fi
            exit "$status"
        }
        trap 'rollback_kernelstub $?' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        alterado=1
        if [ -n "$antigo" ]; then
            sudo kernelstub -d "$antigo" >/dev/null || exit 1
        fi
        if [ -n "$novo" ]; then
            sudo kernelstub -a "$novo" >/dev/null || exit 1
            kernel_parametros_persistentes_exatos "$novo" || exit 1
        else
            kernel_param_chaves_persistentes_ausentes "$chaves" || exit 1
        fi
        concluido=1
    ); then
        KERNEL_PERSISTENCIA_ERRO="A transação kernelstub falhou; consulte as mensagens de rollback."
        return 1
    fi
}

_grub_cmdline_atual() {
    local linha
    local -a linhas=()
    mapfile -t linhas < <(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_DEFAULT_ARQUIVO" 2>/dev/null)
    [ "${#linhas[@]}" -eq 1 ] || return 1
    linha="${linhas[0]}"
    if [[ "$linha" =~ ^GRUB_CMDLINE_LINUX_DEFAULT=\"([^\"]*)\"[[:space:]]*$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

KERNEL_PERSISTENCIA_ERRO=""
KERNEL_PERSISTENCIA_TIPO="pendente"
KERNEL_PARAMETROS_PERSISTENTES=""
kernel_parametros_persistentes() {
    # kernel_parametros_persistentes "chave ..."
    # Preenche KERNEL_PARAMETROS_PERSISTENTES e rejeita duplicações ou loader
    # entries divergentes. Não solicita senha durante verificadores.
    local chaves="${1:-}" bl cmdline estado observavel_rc
    KERNEL_PERSISTENCIA_ERRO=""
    KERNEL_PERSISTENCIA_TIPO="pendente"
    KERNEL_PARAMETROS_PERSISTENTES=""
    kernel_parametros_validos "$chaves" \
        || { KERNEL_PERSISTENCIA_TIPO="erro"; KERNEL_PERSISTENCIA_ERRO="Lista de chaves de kernel inválida: '$chaves'."; return 1; }
    if ! validar_bootloader_configurado; then
        KERNEL_PERSISTENCIA_TIPO="erro"
        KERNEL_PERSISTENCIA_ERRO="$BOOTLOADER_VALIDACAO_ERRO"
        return 1
    fi
    bl="$BOOTLOADER_ATIVO"
    if boot_backend_observavel "$bl"; then
        :
    else
        observavel_rc=$?
        if [ "$observavel_rc" -eq 2 ]; then
            KERNEL_PERSISTENCIA_TIPO="indeterminado"
            KERNEL_PERSISTENCIA_ERRO="Backend $bl não pode ser lido sem privilégio já autorizado."
        else
            KERNEL_PERSISTENCIA_TIPO="erro"
            KERNEL_PERSISTENCIA_ERRO="Backend $bl não está disponível para inspeção segura."
        fi
        return 1
    fi
    case "$bl" in
        kernelstub)
            estado="$(_kernelstub_parametros_por_chaves "$chaves")" \
                || { KERNEL_PERSISTENCIA_TIPO="erro"; KERNEL_PERSISTENCIA_ERRO="Loader entries indisponíveis, duplicados ou divergentes para as chaves gerenciadas."; return 1; }
            ;;
        grub)
            cmdline="$(_grub_cmdline_atual)" \
                || { KERNEL_PERSISTENCIA_TIPO="erro"; KERNEL_PERSISTENCIA_ERRO="GRUB_CMDLINE_LINUX_DEFAULT ausente, duplicado ou ilegível."; return 1; }
            estado="$(_parametros_por_chaves_cmdline "$cmdline" "$chaves")" \
                || { KERNEL_PERSISTENCIA_TIPO="erro"; KERNEL_PERSISTENCIA_ERRO="Uma chave gerenciada está duplicada no GRUB."; return 1; }
            ;;
        *)
            KERNEL_PERSISTENCIA_TIPO="erro"
            KERNEL_PERSISTENCIA_ERRO="Bootloader não identificado."
            return 1
            ;;
    esac
    KERNEL_PARAMETROS_PERSISTENTES="$estado"
}

kernel_parametros_persistentes_exatos() {
    local esperados="${1:-}" bl
    kernel_parametros_persistentes "$esperados" || return 1
    bl="$BOOTLOADER_ATIVO"
    [ "$KERNEL_PARAMETROS_PERSISTENTES" = "$esperados" ] \
        || { KERNEL_PERSISTENCIA_TIPO="pendente"; KERNEL_PERSISTENCIA_ERRO="Persistência atual: '${KERNEL_PARAMETROS_PERSISTENTES:-ausente}'; esperado: '$esperados'."; return 1; }
    if [ "$bl" = grub ] && ! _grub_cfg_parametros_exatos "$esperados"; then
        KERNEL_PERSISTENCIA_TIPO="pendente"
        KERNEL_PERSISTENCIA_ERRO="O grub.cfg efetivo não contém exatamente os parâmetros esperados em todas as entradas Linux."
        return 1
    fi
}

kernel_param_chaves_persistentes_ausentes() {
    local chaves="${1:-}" bl
    kernel_parametros_persistentes "$chaves" || return 1
    bl="$BOOTLOADER_ATIVO"
    [ -z "$KERNEL_PARAMETROS_PERSISTENTES" ] \
        || { KERNEL_PERSISTENCIA_TIPO="pendente"; KERNEL_PERSISTENCIA_ERRO="Ainda persistem parâmetros: $KERNEL_PARAMETROS_PERSISTENTES"; return 1; }
    if [ "$bl" = grub ] && ! _grub_cfg_chaves_ausentes "$chaves"; then
        KERNEL_PERSISTENCIA_TIPO="pendente"
        KERNEL_PERSISTENCIA_ERRO="O grub.cfg efetivo ainda contém uma das chaves gerenciadas."
        return 1
    fi
}

_grub_cfg_linhas_linux() {
    if [ -r "$GRUB_CFG_ARQUIVO" ]; then
        awk '/^[[:space:]]*(linux|linuxefi)[[:space:]]/ {print}' "$GRUB_CFG_ARQUIVO"
        return
    fi
    command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null || return 2
    sudo -n awk '/^[[:space:]]*(linux|linuxefi)[[:space:]]/ {print}' "$GRUB_CFG_ARQUIVO" 2>/dev/null
}

_grub_cfg_parametros_exatos() {
    local esperados="$1" linhas linha estado encontrou=0
    linhas="$(_grub_cfg_linhas_linux)" \
        || return 1
    [ -n "$linhas" ] || return 1
    while IFS= read -r linha || [ -n "$linha" ]; do
        estado="$(_parametros_por_chaves_cmdline "$linha" "$esperados")" || return 1
        # Recovery/custom entries podem deliberadamente não herdar
        # GRUB_CMDLINE_LINUX_DEFAULT. Se uma entrada contiver qualquer chave
        # gerenciada, porém, o conjunto precisa ser integral e exato.
        [ -n "$estado" ] || continue
        [ "$estado" = "$esperados" ] || return 1
        encontrou=1
    done <<< "$linhas"
    [ "$encontrou" -eq 1 ]
}

_grub_cfg_chaves_ausentes() {
    local chaves="$1" linhas linha estado encontrou=0
    linhas="$(_grub_cfg_linhas_linux)" \
        || return 1
    [ -n "$linhas" ] || return 1
    while IFS= read -r linha || [ -n "$linha" ]; do
        estado="$(_parametros_por_chaves_cmdline "$linha" "$chaves")" || return 1
        [ -z "$estado" ] || return 1
        encontrou=1
    done <<< "$linhas"
    [ "$encontrou" -eq 1 ]
}

_grub_aplicar_cmdline() {
    # Instala /etc/default/grub e regenera o grub.cfg numa única transação.
    # EXIT/INT/TERM após o primeiro mv restauram a fonte e regeneram o cfg.
    local novo="$1" verificacao="$2" modo="$3" arq="$GRUB_DEFAULT_ARQUIVO"
    local tmp backup staged linha
    [[ "$novo" != *$'\n'* && "$novo" != *$'\r'* && "$novo" != *'"'* && "$novo" != *'\'* ]] \
        || falhar "Linha de parâmetros GRUB contém caractere não suportado."
    tmp="$(mktemp)" || falhar "Não foi possível criar temporário para o GRUB."
    linha="GRUB_CMDLINE_LINUX_DEFAULT=\"${novo}\""
    if ! NOVA_LINHA_GRUB="$linha" awk '
        /^GRUB_CMDLINE_LINUX_DEFAULT=/ {
            encontradas++
            if (encontradas == 1) print ENVIRON["NOVA_LINHA_GRUB"]
            next
        }
        { print }
        END { if (encontradas != 1) exit 42 }
    ' "$arq" > "$tmp"; then
        rm -f -- "$tmp"
        falhar "GRUB_CMDLINE_LINUX_DEFAULT ausente ou duplicado em $arq."
    fi

    backup="${arq}.bak-$(date +%Y%m%d-%H%M%S)-$$"
    staged="${arq}.vm-passthrough-$$"
    sudo cp -a -- "$arq" "$backup" \
        || { rm -f -- "$tmp"; falhar "Falha ao criar backup do GRUB em $backup."; }
    sudo cp -a -- "$arq" "$staged" \
        || { rm -f -- "$tmp"; falhar "Falha ao preparar atualização atômica do GRUB."; }
    if ! sudo tee "$staged" < "$tmp" >/dev/null; then
        sudo rm -f -- "$staged"
        rm -f -- "$tmp"
        falhar "Falha ao escrever configuração temporária do GRUB."
    fi
    rm -f -- "$tmp"

    if ! (
        alterado=0
        concluido=0
        rollback_grub() {
            local status="$1"
            trap - EXIT INT TERM
            sudo rm -f -- "$staged" >/dev/null 2>&1 || true
            if [ "$alterado" -eq 1 ] && [ "$concluido" -eq 0 ]; then
                erro "Transação GRUB interrompida ou inválida; restaurando $backup."
                if sudo cp -a -- "$backup" "$arq" \
                   && sudo update-grub \
                   && sudo cmp -s -- "$backup" "$arq"; then
                    aviso "Rollback da fonte GRUB e regeneração do grub.cfg concluídos."
                else
                    erro "ROLLBACK GRUB NÃO COMPROVADO. Não reinicie antes de revisar $arq e /boot/grub/grub.cfg."
                fi
            fi
            exit "$status"
        }
        trap 'rollback_grub $?' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        alterado=1
        sudo mv -f -- "$staged" "$arq" || exit 1
        sudo update-grub || exit 1
        if [ "$modo" = exato ]; then
            _grub_cfg_parametros_exatos "$verificacao" || exit 1
        elif [ "$modo" = ausente ]; then
            _grub_cfg_chaves_ausentes "$verificacao" || exit 1
        else
            exit 1
        fi
        concluido=1
    ); then
        falhar "Alteração do GRUB não concluída; consulte as mensagens de rollback."
    fi
    info "Backup do GRUB preservado em: $backup"
}

kernel_param_add() {
    # Apesar do nome histórico, esta operação é SET por chave: qualquer valor
    # anterior de hugepages, isolcpus, iommu etc. é removido antes do novo.
    local params="$1" bl atual novo
    kernel_parametros_validos "$params" \
        || falhar "Lista de parâmetros de kernel inválida ou com chaves duplicadas: '$params'."
    exigir_bootloader_coerente
    bl="$BOOTLOADER_ATIVO"
    case "$bl" in
        kernelstub)
            _kernelstub_aplicar_estado "$params" "$params" \
                || falhar "${KERNEL_PERSISTENCIA_ERRO:-Transação kernelstub não concluída.}"
            ;;
        grub)
            atual="$(_grub_cmdline_atual)" \
                || falhar "Não foi possível ler com segurança GRUB_CMDLINE_LINUX_DEFAULT."
            novo="$(_cmdline_sem_chaves "$atual" "$params")"
            novo="${novo:+$novo }$params"
            _grub_aplicar_cmdline "$novo" "$params" exato
            ;;
        *)
            falhar "Bootloader não identificado. Execute etapas/02-detectar-config.sh."
            ;;
    esac
    info "Parâmetros definidos por chave via ${bl}: $params"
}

kernel_param_del() {
    # Remove todos os valores das chaves informadas, mesmo que sejam diferentes
    # daqueles registrados na chamada (ex.: hugepages=16 remove hugepages=8).
    local params="$1" bl atual novo
    kernel_parametros_validos "$params" \
        || falhar "Lista de parâmetros de kernel inválida ou com chaves duplicadas: '$params'."
    exigir_bootloader_coerente
    bl="$BOOTLOADER_ATIVO"
    case "$bl" in
        kernelstub)
            _kernelstub_aplicar_estado "$params" "" \
                || falhar "${KERNEL_PERSISTENCIA_ERRO:-Transação kernelstub de remoção não concluída.}"
            ;;
        grub)
            atual="$(_grub_cmdline_atual)" \
                || falhar "Não foi possível ler com segurança GRUB_CMDLINE_LINUX_DEFAULT."
            novo="$(_cmdline_sem_chaves "$atual" "$params")"
            if [ "$novo" != "$atual" ] || ! _grub_cfg_chaves_ausentes "$params"; then
                _grub_aplicar_cmdline "$novo" "$params" ausente
            else
                info "Nenhum parâmetro dessas chaves está configurado na fonte nem no grub.cfg efetivo."
            fi
            ;;
        *)
            falhar "Bootloader não identificado."
            ;;
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
DISCARD_XML_ERRO=""
DISCARD_XML_ESTADO=""
xml_disco_qcow2_estado() {
    # Retornos: 0=discard ativo no único disco alvo; 1=alvo único sem unmap;
    # 2=XML inválido, alvo ausente/duplicado ou estrutura ambígua.
    local arquivo="${1:-}" qcow2="${2:-}" saida rc
    DISCARD_XML_ERRO=""
    DISCARD_XML_ESTADO=""
    [ -f "$arquivo" ] && caminho_absoluto_seguro "$qcow2" \
        || { DISCARD_XML_ERRO="XML ou QCOW2_PATH inválido."; DISCARD_XML_ESTADO=erro; return 2; }
    if saida="$(python3 - "$arquivo" "$qcow2" 2>&1 <<'PY'
import sys
import xml.etree.ElementTree as ET

path, target = sys.argv[1:]
try:
    root = ET.parse(path).getroot()
except Exception as exc:
    print(f'XML ilegível: {exc}')
    raise SystemExit(2)
if root.tag != 'domain':
    print('raiz XML não é <domain>')
    raise SystemExit(2)
devices = [child for child in list(root) if child.tag == 'devices']
if len(devices) != 1:
    print(f'quantidade de <devices>={len(devices)}; esperado 1')
    raise SystemExit(2)
matches = []
for disk in [child for child in list(devices[0]) if child.tag == 'disk' and child.get('device') == 'disk']:
    all_sources = [child for child in list(disk) if child.tag == 'source']
    exact_sources = [child for child in all_sources if child.get('file') == target]
    if exact_sources:
        if len(all_sources) != 1 or len(exact_sources) != 1:
            print(f'fontes no disco alvo: total={len(all_sources)}, exatas={len(exact_sources)}; esperado 1/1')
            raise SystemExit(2)
        matches.append(disk)
if len(matches) != 1:
    print(f'discos device=disk com source/@file exato {target!r}: {len(matches)}; esperado 1')
    raise SystemExit(2)
drivers = [child for child in list(matches[0]) if child.tag == 'driver']
if len(drivers) != 1:
    print(f'drivers no disco alvo: {len(drivers)}; esperado 1')
    raise SystemExit(2)
if drivers[0].get('discard') == 'unmap':
    print('ativo')
    raise SystemExit(0)
print('ausente')
raise SystemExit(1)
PY
)"; then
        DISCARD_XML_ESTADO=ativo
        return 0
    else
        rc=$?
    fi
    if [ "$rc" -eq 1 ] && [ "$saida" = ausente ]; then
        DISCARD_XML_ESTADO=ausente
        return 1
    fi
    DISCARD_XML_ESTADO=erro
    DISCARD_XML_ERRO="${saida:-Falha ao analisar o disco QCOW2 alvo.}"
    return 2
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
vm_estado() { LC_ALL=C $VIRSH domstate "$1" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }
vm_desligada() { [ "$(vm_estado "$1")" = "shut off" ]; }

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

CPU_LISTAS_ERRO=""
validar_particao_cpus() {
    # validar_particao_cpus CPUS_VM CPUS_HOST TOTAL [VCPUS_ESPERADAS]
    # Compatibilidade para consumidores com IDs contíguos. Novas validações
    # de topologia devem preferir validar_layout_cpu.
    local cpus_vm="$1" cpus_host="$2" total="$3" esperadas="${4:-}"
    local cpu quantidade_vm=0 quantidade_total=0
    local -A vistas=()
    CPU_LISTAS_ERRO=""
    lista_cpus_valida "$cpus_vm" "$total" \
        || { CPU_LISTAS_ERRO="CPUS_VM contém duplicação, intervalo inválido ou CPU fora do host."; return 1; }
    lista_cpus_valida "$cpus_host" "$total" \
        || { CPU_LISTAS_ERRO="CPUS_HOST contém duplicação, intervalo inválido ou CPU fora do host."; return 1; }

    while IFS= read -r cpu; do
        vistas[$cpu]=vm
        quantidade_vm=$((quantidade_vm + 1))
    done < <(expandir_lista_cpus "$cpus_vm")
    while IFS= read -r cpu; do
        [ -z "${vistas[$cpu]+definida}" ] \
            || { CPU_LISTAS_ERRO="A CPU $cpu aparece simultaneamente em CPUS_VM e CPUS_HOST."; return 1; }
        vistas[$cpu]=host
    done < <(expandir_lista_cpus "$cpus_host")
    quantidade_total="${#vistas[@]}"
    [ "$quantidade_total" -eq "$total" ] \
        || { CPU_LISTAS_ERRO="As listas cobrem $quantidade_total de $total CPUs lógicas; todas precisam pertencer exatamente a uma lista."; return 1; }
    if [ -n "$esperadas" ]; then
        inteiro_na_faixa "$esperadas" 1 65536 \
            || { CPU_LISTAS_ERRO="Quantidade esperada de vCPUs inválida: $esperadas."; return 1; }
        [ "$quantidade_vm" -eq "$esperadas" ] \
            || { CPU_LISTAS_ERRO="CPUS_VM contém $quantidade_vm CPUs, mas VM_VCPUS=$esperadas."; return 1; }
    fi
}

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
validar_layout_cpu() {
    # validar_layout_cpu CPUS_VM CPUS_HOST VM_VCPUS VM_CORES VM_THREADS [CSV]
    # CSV segue lscpu -p=CPU,CORE,SOCKET,NODE,ONLINE. Valida o conjunto exato
    # de CPUs online (inclusive IDs esparsos), siblings completos por core,
    # cardinalidade e produto da topologia. Pelo menos um core inteiro fica no host.
    local cpus_vm="${1:-}" cpus_host="${2:-}" vcpus="${3:-}"
    local cores="${4:-}" threads="${5:-}" topologia="${6:-}"
    local cpu core socket node online extra chave dono primeiro irmao quantidade
    local qtd_vm=0 qtd_total=0 cores_vm=0 cores_host=0 ordem_vm="" declarada_vm
    local -a irmaos=() chaves_ordenadas=() irmaos_ordenados=()
    local -A online_set=() alocacao=() core_cpus=() core_dono=()
    CPU_LAYOUT_ERRO=""
    CPU_LAYOUT_ONLINE=""

    inteiro_na_faixa "$vcpus" 1 65536 \
        || { CPU_LAYOUT_ERRO="VM_VCPUS inválido: '${vcpus:-vazio}'."; return 1; }
    inteiro_na_faixa "$cores" 1 65536 \
        || { CPU_LAYOUT_ERRO="VM_CORES inválido: '${cores:-vazio}'."; return 1; }
    inteiro_na_faixa "$threads" 1 65536 \
        || { CPU_LAYOUT_ERRO="VM_THREADS inválido: '${threads:-vazio}'."; return 1; }
    [ $((10#$cores * 10#$threads)) -eq $((10#$vcpus)) ] \
        || { CPU_LAYOUT_ERRO="VM_CORES x VM_THREADS precisa ser igual a VM_VCPUS ($cores x $threads != $vcpus)."; return 1; }
    lista_cpus_valida "$cpus_vm" \
        || { CPU_LAYOUT_ERRO="CPUS_VM possui sintaxe, intervalo ou duplicação inválida."; return 1; }
    lista_cpus_valida "$cpus_host" \
        || { CPU_LAYOUT_ERRO="CPUS_HOST possui sintaxe, intervalo ou duplicação inválida."; return 1; }
    if [ -z "$topologia" ]; then
        topologia="$(cpu_topologia_csv)" \
            || { CPU_LAYOUT_ERRO="lscpu não conseguiu fornecer a topologia parseável."; return 1; }
    fi
    [ -n "$topologia" ] \
        || { CPU_LAYOUT_ERRO="A topologia de CPU está vazia."; return 1; }

    while IFS=, read -r cpu core socket node online extra; do
        cpu="${cpu%$'\r'}"; core="${core%$'\r'}"; socket="${socket%$'\r'}"
        online="${online%$'\r'}"
        [ -z "$extra" ] || { CPU_LAYOUT_ERRO="Linha de topologia possui colunas inesperadas."; return 1; }
        case "$online" in
            Y|yes|YES|1) ;;
            N|no|NO|0) continue ;;
            *) CPU_LAYOUT_ERRO="Estado ONLINE desconhecido para CPU ${cpu:-?}: '${online:-vazio}'."; return 1 ;;
        esac
        inteiro_na_faixa "$cpu" 0 65535 \
            || { CPU_LAYOUT_ERRO="ID de CPU online inválido: '$cpu'."; return 1; }
        inteiro_na_faixa "$core" 0 65535 \
            || { CPU_LAYOUT_ERRO="CORE inválido para a CPU $cpu: '$core'."; return 1; }
        inteiro_na_faixa "$socket" 0 65535 \
            || { CPU_LAYOUT_ERRO="SOCKET inválido para a CPU $cpu: '$socket'."; return 1; }
        [ -z "${online_set[$cpu]+definida}" ] \
            || { CPU_LAYOUT_ERRO="A CPU $cpu aparece mais de uma vez na topologia."; return 1; }
        online_set[$cpu]=1
        chave="$socket:$core"
        core_cpus[$chave]="${core_cpus[$chave]:+${core_cpus[$chave]} }$cpu"
    done <<< "$topologia"
    [ "${#online_set[@]}" -gt 0 ] \
        || { CPU_LAYOUT_ERRO="Nenhuma CPU online foi encontrada."; return 1; }

    while IFS= read -r cpu; do
        [ -n "${online_set[$cpu]+definida}" ] \
            || { CPU_LAYOUT_ERRO="CPUS_VM inclui a CPU $cpu, que não está online."; return 1; }
        alocacao[$cpu]=vm
        qtd_vm=$((qtd_vm + 1))
    done < <(expandir_lista_cpus "$cpus_vm")
    while IFS= read -r cpu; do
        [ -n "${online_set[$cpu]+definida}" ] \
            || { CPU_LAYOUT_ERRO="CPUS_HOST inclui a CPU $cpu, que não está online."; return 1; }
        [ -z "${alocacao[$cpu]+definida}" ] \
            || { CPU_LAYOUT_ERRO="A CPU $cpu aparece simultaneamente em CPUS_VM e CPUS_HOST."; return 1; }
        alocacao[$cpu]=host
    done < <(expandir_lista_cpus "$cpus_host")
    qtd_total="${#alocacao[@]}"
    [ "$qtd_total" -eq "${#online_set[@]}" ] \
        || { CPU_LAYOUT_ERRO="As listas cobrem $qtd_total de ${#online_set[@]} CPUs online; não pode haver omissões."; return 1; }
    for cpu in "${!online_set[@]}"; do
        [ -n "${alocacao[$cpu]+definida}" ] \
            || { CPU_LAYOUT_ERRO="A CPU online $cpu não pertence a CPUS_VM nem a CPUS_HOST."; return 1; }
    done
    [ "$qtd_vm" -eq "$vcpus" ] \
        || { CPU_LAYOUT_ERRO="CPUS_VM contém $qtd_vm CPUs, mas VM_VCPUS=$vcpus."; return 1; }

    for chave in "${!core_cpus[@]}"; do
        read -r -a irmaos <<< "${core_cpus[$chave]}"
        quantidade="${#irmaos[@]}"
        primeiro="${irmaos[0]}"
        dono="${alocacao[$primeiro]}"
        for irmao in "${irmaos[@]}"; do
            [ "${alocacao[$irmao]}" = "$dono" ] \
                || { CPU_LAYOUT_ERRO="O core físico $chave foi dividido entre VM e host (siblings: ${core_cpus[$chave]})."; return 1; }
        done
        core_dono[$chave]="$dono"
        if [ "$dono" = vm ]; then
            [ "$quantidade" -eq "$threads" ] \
                || { CPU_LAYOUT_ERRO="O core da VM $chave tem $quantidade thread(s) online, mas VM_THREADS=$threads."; return 1; }
            cores_vm=$((cores_vm + 1))
        else
            cores_host=$((cores_host + 1))
        fi
    done
    [ "$cores_vm" -eq "$cores" ] \
        || { CPU_LAYOUT_ERRO="CPUS_VM ocupa $cores_vm cores físicos, mas VM_CORES=$cores."; return 1; }
    [ "$cores_host" -ge 1 ] \
        || { CPU_LAYOUT_ERRO="Nenhum core físico completo foi preservado para o host."; return 1; }

    # A ordem também é parte do contrato: no XML virtual, threads adjacentes
    # pertencem ao mesmo core. Portanto cada grupo socket:core deve aparecer
    # contíguo, ordenado por socket/core e por ID lógico do sibling.
    mapfile -t chaves_ordenadas < <(printf '%s\n' "${!core_cpus[@]}" \
        | LC_ALL=C sort -t: -k1,1n -k2,2n)
    for chave in "${chaves_ordenadas[@]}"; do
        [ "${core_dono[$chave]}" = vm ] || continue
        read -r -a irmaos <<< "${core_cpus[$chave]}"
        mapfile -t irmaos_ordenados < <(printf '%s\n' "${irmaos[@]}" | LC_ALL=C sort -n)
        for cpu in "${irmaos_ordenados[@]}"; do
            ordem_vm="${ordem_vm:+$ordem_vm,}$cpu"
        done
    done
    declarada_vm="$(expandir_lista_cpus "$cpus_vm" | paste -sd, -)"
    [ "$declarada_vm" = "$ordem_vm" ] \
        || { CPU_LAYOUT_ERRO="CPUS_VM precisa agrupar siblings na ordem canônica socket:core: esperado [$ordem_vm], recebido [$declarada_vm]."; return 1; }
    CPU_LAYOUT_ONLINE="$(printf '%s\n' "${!online_set[@]}" | LC_ALL=C sort -n | paste -sd, -)"
}

XML_CPU_ERRO=""
xml_cpu_gerar_candidato() {
    # Gera XML com pinning, topologia e página explicitamente de 1 GiB sem
    # remover ajustes não gerenciados de cputune/memoryBacking.
    local origem="$1" destino="$2" cpus_vm="$3" cpus_host="$4"
    local vcpus="$5" cores="$6" threads="$7" ram_mb="$8" saida
    XML_CPU_ERRO=""
    if ! saida="$(python3 - "$origem" "$destino" "$cpus_vm" "$cpus_host" "$vcpus" "$cores" "$threads" "$ram_mb" 2>&1 <<'PY'
import sys
import xml.etree.ElementTree as ET

src, dst, vm_spec, host_spec, vcpus_s, cores_s, threads_s, ram_s = sys.argv[1:]

def fail(message):
    raise ValueError(message)

def expand(spec):
    result = []
    seen = set()
    for part in spec.split(','):
        if '-' in part:
            a_s, b_s = part.split('-', 1)
            a, b = int(a_s), int(b_s)
            if a > b:
                fail(f'intervalo invertido: {part}')
            values = range(a, b + 1)
        else:
            values = (int(part),)
        for value in values:
            if value in seen:
                fail(f'CPU duplicada: {value}')
            seen.add(value)
            result.append(value)
    return result

def direct(parent, name):
    return [child for child in list(parent) if child.tag == name]

def one(parent, name):
    items = direct(parent, name)
    if len(items) != 1:
        fail(f'esperado exatamente um <{name}>; encontrado: {len(items)}')
    return items[0]

def ensure_one(parent, name, anchors=()):
    items = direct(parent, name)
    if len(items) > 1:
        fail(f'<{name}> duplicado')
    if items:
        return items[0]
    element = ET.Element(name)
    children = list(parent)
    for index, child in enumerate(children):
        if child.tag in anchors:
            parent.insert(index, element)
            return element
    parent.append(element)
    return element

vcpus, cores, threads, ram_mb = int(vcpus_s), int(cores_s), int(threads_s), int(ram_s)
vm_cpus = expand(vm_spec)
expand(host_spec)
if len(vm_cpus) != vcpus:
    fail(f'CPUS_VM possui {len(vm_cpus)} CPUs, mas VM_VCPUS={vcpus}')
parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
tree = ET.parse(src, parser=parser)
root = tree.getroot()
if root.tag != 'domain':
    fail('raiz XML não é <domain>')
if direct(root, 'maxMemory'):
    fail('reconfiguração automática com <maxMemory> não é suportada; revise hotplug de RAM manualmente')
if direct(root, 'numatune'):
    fail('reconfiguração automática com <numatune> não é suportada')

memory = one(root, 'memory')
memory.text = str(ram_mb)
memory.set('unit', 'MiB')
current_memory = direct(root, 'currentMemory')
if len(current_memory) > 1:
    fail('<currentMemory> duplicado')
if current_memory:
    current_memory[0].text = str(ram_mb)
    current_memory[0].set('unit', 'MiB')

# Metadados individuais de hotplug possuem semântica própria (enabled,
# hotpluggable, order). Não os apague nem tente inferir uma política nova.
if direct(root, 'vcpus'):
    fail('o domínio possui <vcpus> de hotplug; remova/reconcilie essa política manualmente antes desta etapa')

vcpu = one(root, 'vcpu')
vcpu.text = str(vcpus)
vcpu.attrib.pop('current', None)
vcpu.set('placement', 'static')
vcpu.set('cpuset', vm_spec)

cputune = ensure_one(root, 'cputune', ('numatune', 'resource', 'sysinfo', 'os', 'features', 'cpu', 'clock', 'devices'))
for child in list(cputune):
    if child.tag in ('vcpupin', 'emulatorpin'):
        cputune.remove(child)
for index, physical in enumerate(vm_cpus):
    ET.SubElement(cputune, 'vcpupin', {'vcpu': str(index), 'cpuset': str(physical)})
ET.SubElement(cputune, 'emulatorpin', {'cpuset': host_spec})

cpu = ensure_one(root, 'cpu', ('clock', 'on_poweroff', 'on_reboot', 'on_crash', 'pm', 'devices'))
if direct(cpu, 'numa'):
    fail('reconfiguração automática com <cpu><numa> não é suportada')
cpu.set('mode', 'host-passthrough')
cpu.set('check', 'none')
cpu.set('migratable', 'off')
for child in list(cpu):
    if child.tag == 'topology':
        cpu.remove(child)
ET.SubElement(cpu, 'topology', {
    'sockets': '1', 'dies': '1', 'cores': str(cores), 'threads': str(threads)
})

memory_backing = ensure_one(root, 'memoryBacking', ('vcpu', 'resource', 'sysinfo', 'os', 'features', 'cpu', 'clock', 'devices'))
for child in list(memory_backing):
    if child.tag == 'hugepages':
        memory_backing.remove(child)
hugepages = ET.Element('hugepages')
hugepages.append(ET.Element('page', {'size': '1', 'unit': 'GiB'}))
memory_backing.insert(0, hugepages)

tree.write(dst, encoding='utf-8', xml_declaration=True, short_empty_elements=True)
PY
)"; then
        XML_CPU_ERRO="${saida:-Falha ao gerar o XML candidato.}"
        return 1
    fi
}

xml_cpu_remover_hugepages() {
    local origem="$1" destino="$2" saida
    XML_CPU_ERRO=""
    if ! saida="$(python3 - "$origem" "$destino" 2>&1 <<'PY'
import sys
import xml.etree.ElementTree as ET

src, dst = sys.argv[1:]
parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
tree = ET.parse(src, parser=parser)
root = tree.getroot()
if root.tag != 'domain':
    raise ValueError('raiz XML não é <domain>')
backings = [child for child in list(root) if child.tag == 'memoryBacking']
if len(backings) > 1:
    raise ValueError('<memoryBacking> duplicado')
if backings:
    backing = backings[0]
    for child in list(backing):
        if child.tag == 'hugepages':
            backing.remove(child)
    real_children = [child for child in list(backing) if isinstance(child.tag, str)]
    if not real_children and not backing.attrib and not (backing.text or '').strip():
        root.remove(backing)
tree.write(dst, encoding='utf-8', xml_declaration=True, short_empty_elements=True)
PY
)"; then
        XML_CPU_ERRO="${saida:-Falha ao remover HugePages do XML candidato.}"
        return 1
    fi
}

validar_xml_cpu_pinning() {
    # validar_xml_cpu_pinning XML CPUS_VM CPUS_HOST VCPUS CORES THREADS RAM_MB MODO
    # MODO: sim exige página de 1 GiB; nao exige ausência; ignorar não avalia.
    local arquivo="$1" cpus_vm="$2" cpus_host="$3" vcpus="$4"
    local cores="$5" threads="$6" ram_mb="$7" modo="${8:-ignorar}" saida
    XML_CPU_ERRO=""
    if ! saida="$(python3 - "$arquivo" "$cpus_vm" "$cpus_host" "$vcpus" "$cores" "$threads" "$ram_mb" "$modo" 2>&1 <<'PY'
import sys
import xml.etree.ElementTree as ET
from fractions import Fraction

path, vm_spec, host_spec, vcpus_s, cores_s, threads_s, ram_s, huge_mode = sys.argv[1:]

def fail(message):
    raise ValueError(message)

def direct(parent, name):
    return [child for child in list(parent) if child.tag == name]

def one(parent, name):
    values = direct(parent, name)
    if len(values) != 1:
        fail(f'esperado exatamente um <{name}>; encontrado: {len(values)}')
    return values[0]

def expand(spec):
    if not spec:
        fail('lista de CPUs vazia')
    result, seen = [], set()
    for part in spec.split(','):
        if '-' in part:
            bits = part.split('-', 1)
            if len(bits) != 2 or not all(bit.isdigit() for bit in bits):
                fail(f'intervalo inválido: {part}')
            start, end = map(int, bits)
            if start > end:
                fail(f'intervalo invertido: {part}')
            values = range(start, end + 1)
        else:
            if not part.isdigit():
                fail(f'CPU inválida: {part}')
            values = (int(part),)
        for value in values:
            if value in seen:
                fail(f'CPU duplicada: {value}')
            seen.add(value)
            result.append(value)
    return result

def same_set(actual, expected):
    return set(expand(actual)) == set(expand(expected))

def size_bytes(value, unit, default='KiB'):
    units = {
        'b': 1, 'bytes': 1,
        'kb': 1000, 'kib': 1024,
        'mb': 1000 ** 2, 'mib': 1024 ** 2,
        'gb': 1000 ** 3, 'gib': 1024 ** 3,
    }
    key = (unit or default).lower()
    if key not in units:
        fail(f'unidade de memória não suportada: {unit or default}')
    try:
        number = Fraction(value.strip())
    except Exception as exc:
        fail(f'valor de memória inválido: {value!r} ({exc})')
    return number * units[key]

vcpus, cores, threads, ram_mb = map(int, (vcpus_s, cores_s, threads_s, ram_s))
expected_vm = expand(vm_spec)
expand(host_spec)
if len(expected_vm) != vcpus:
    fail(f'CPUS_VM possui {len(expected_vm)} CPUs, esperado {vcpus}')
if cores * threads != vcpus:
    fail('produto cores x threads diverge de vCPUs')
root = ET.parse(path).getroot()
if root.tag != 'domain':
    fail('raiz XML não é <domain>')
if direct(root, 'maxMemory') or direct(root, 'numatune'):
    fail('maxMemory/numatune não são suportados pela validação automática desta etapa')

vcpu = one(root, 'vcpu')
if (vcpu.text or '').strip() != str(vcpus):
    fail(f'<vcpu> diverge de {vcpus}')
if vcpu.get('placement') != 'static' or not same_set(vcpu.get('cpuset', ''), vm_spec):
    fail('<vcpu> não possui placement estático e conjunto exato de CPUS_VM')
if vcpu.get('current') not in (None, str(vcpus)):
    fail('vcpu/@current limita a VM a uma cardinalidade diferente')
individual_sets = direct(root, 'vcpus')
if individual_sets:
    fail('<vcpus> de hotplug não é suportado automaticamente; a política precisa ser reconciliada manualmente')

cputune = one(root, 'cputune')
pins = direct(cputune, 'vcpupin')
if len(pins) != vcpus:
    fail(f'quantidade de vcpupin={len(pins)}, esperado {vcpus}')
seen_vcpus = set()
for pin in pins:
    index_s = pin.get('vcpu', '')
    if not index_s.isdigit():
        fail('vcpupin sem índice numérico')
    index = int(index_s)
    if index in seen_vcpus or index < 0 or index >= vcpus:
        fail(f'índice vcpupin duplicado/fora da faixa: {index}')
    seen_vcpus.add(index)
    actual = expand(pin.get('cpuset', ''))
    if actual != [expected_vm[index]]:
        fail(f'vCPU {index} está em {actual}, esperado [{expected_vm[index]}]')
if seen_vcpus != set(range(vcpus)):
    fail('vcpupin não cobre exatamente 0..VM_VCPUS-1')
emulators = direct(cputune, 'emulatorpin')
if len(emulators) != 1 or not same_set(emulators[0].get('cpuset', ''), host_spec):
    fail('emulatorpin não corresponde exatamente a CPUS_HOST')

cpu = one(root, 'cpu')
if direct(cpu, 'numa'):
    fail('<cpu><numa> não é suportado pela validação automática desta etapa')
if cpu.get('mode') != 'host-passthrough' or cpu.get('check') != 'none' or cpu.get('migratable') != 'off':
    fail('modo/check/migratable da CPU não são os valores gerenciados')
topology = one(cpu, 'topology')
expected_topology = {'sockets': '1', 'dies': '1', 'cores': str(cores), 'threads': str(threads)}
for key, value in expected_topology.items():
    if topology.get(key) != value:
        fail(f'topology/@{key}={topology.get(key)!r}, esperado {value!r}')

memory = one(root, 'memory')
expected_bytes = ram_mb * 1024 * 1024
if size_bytes(memory.text or '', memory.get('unit')) != expected_bytes:
    fail('<memory> não corresponde exatamente a VM_RAM_MB')
current = direct(root, 'currentMemory')
if len(current) > 1:
    fail('<currentMemory> duplicado')
if current and size_bytes(current[0].text or '', current[0].get('unit')) != expected_bytes:
    fail('<currentMemory> não corresponde exatamente a VM_RAM_MB')

backings = direct(root, 'memoryBacking')
huge_nodes = []
for backing in backings:
    huge_nodes.extend(direct(backing, 'hugepages'))
if huge_mode == 'sim':
    if len(backings) != 1 or len(huge_nodes) != 1:
        fail('memoryBacking/hugepages precisa existir exatamente uma vez')
    pages = direct(huge_nodes[0], 'page')
    if len(pages) != 1:
        fail('hugepages precisa declarar exatamente uma página')
    if size_bytes(pages[0].get('size', ''), pages[0].get('unit'), default='KiB') != 1024 ** 3:
        fail('a página declarada no XML não tem exatamente 1 GiB')
elif huge_mode == 'nao':
    if huge_nodes:
        fail('o XML ainda exige HugePages')
elif huge_mode != 'ignorar':
    fail(f'modo de HugePages inválido: {huge_mode}')
PY
)"; then
        XML_CPU_ERRO="${saida:-XML de CPU/HugePages inválido.}"
        return 1
    fi
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
