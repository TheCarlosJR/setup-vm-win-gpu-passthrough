#!/bin/bash
# ============================================================================
# lib/common.sh - funções compartilhadas por todas as etapas e utilitários
# ============================================================================
# Este arquivo NÃO é executado diretamente: ele é carregado via "source"
# pelos scripts de etapas/ e util/.
#
# Referência: Velho_Windows11_VM_Passthrough_PopOS_v2.md (manual completo).
# ============================================================================

# --- Localização do projeto e arquivos centrais -----------------------------
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJETO_DIR="$(cd "$COMMON_DIR/.." && pwd)"
CONF_ARQUIVO="$PROJETO_DIR/passthrough.conf"
BACKUPS_DIR="$PROJETO_DIR/backups"
FSTAB="/etc/fstab"
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
    if ! sudo -n true 2>/dev/null; then
        info "Acesso administrativo necessário: a senha do sudo será pedida UMA vez."
        sudo -v || falhar "Sem acesso sudo."
    fi
    if [ -z "$SUDO_KEEPALIVE_PID" ]; then
        ( while :; do sudo -n true 2>/dev/null || exit 0; sleep 50; done ) &
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

# --- Configuração central (passthrough.conf) ---------------------------------
carregar_conf() {
    if [ -f "$CONF_ARQUIVO" ]; then
        # shellcheck disable=SC1090
        source "$CONF_ARQUIVO"
    fi
}

_citar_shell() {
    # Envolve o valor em aspas SIMPLES, escapando aspas simples internas.
    # O conf é lido com "source": sem isso, um valor com $(...) ou ` ` seria
    # EXECUTADO na próxima carga (o usuário digita esses valores à mão).
    local v="$1"
    printf "'%s'" "${v//\'/\'\\\'\'}"
}

salvar_conf() {
    # salvar_conf CHAVE VALOR -> cria/atualiza a linha CHAVE='VALOR' no conf
    local chave="$1" valor="$2" tmp
    touch "$CONF_ARQUIVO"
    if grep -q "^${chave}=" "$CONF_ARQUIVO"; then
        # awk (e não sed) porque o valor pode conter |, & e / de caminhos
        tmp="$(mktemp)"
        CONF_CHAVE="$chave" CONF_LINHA="${chave}=$(_citar_shell "$valor")" \
        awk 'BEGIN { k = ENVIRON["CONF_CHAVE"]; l = ENVIRON["CONF_LINHA"] }
             index($0, k "=") == 1 && !feito { print l; feito = 1; next }
             { print }' "$CONF_ARQUIVO" > "$tmp"
        cat "$tmp" > "$CONF_ARQUIVO"   # preserva permissões do arquivo original
        rm -f "$tmp"
    else
        printf '%s=%s\n' "$chave" "$(_citar_shell "$valor")" >> "$CONF_ARQUIVO"
    fi
    # exporta para o processo atual também
    printf -v "$chave" '%s' "$valor"
    export "${chave?}"
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
    local iface="${1:-}"
    nome_interface_valido "$iface" || return 1
    [ "$iface" != "lo" ] || return 1
    [ -e "/sys/class/net/$iface/device" ] || return 1
    [ "$(cat "/sys/class/net/$iface/type" 2>/dev/null)" = "1" ]
}

interface_wifi() {
    local iface="${1:-}"
    [ -d "/sys/class/net/$iface/wireless" ]
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
confirmar() {
    # confirmar "Pergunta?" -> retorna 0 se sim. Padrão: NÃO.
    local resposta
    read -r -p "$1 [s/N] " resposta
    [[ "$resposta" =~ ^[sS]([iI][mM])?$ ]]
}

confirmar_digitando() {
    # confirmar_digitando PALAVRA "mensagem" -> exige digitar a PALAVRA exata
    local palavra="$1" msg="$2" resposta
    echo
    aviso "$msg"
    read -r -p "Digite ${palavra} (maiúsculas) para confirmar; qualquer outra coisa cancela: " resposta
    [ "$resposta" = "$palavra" ]
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
    # Repergunta em vez de deixar o script morrer com valor fora da faixa ou
    # com texto no lugar de número (proteção de interface).
    local texto="$1" padrao="${2:-}" min="$3" max="$4" resposta
    while :; do
        resposta="$(perguntar "$texto ($min-$max)" "$padrao")"
        if [[ "$resposta" =~ ^[0-9]+$ ]] && [ "$resposta" -ge "$min" ] && [ "$resposta" -le "$max" ]; then
            echo "$resposta"
            return 0
        fi
        erro "Valor inválido: '${resposta}'. Informe um número inteiro entre $min e $max."
    done
}

escolher_da_lista() {
    # escolher_da_lista "pergunta" sim|nao item1 item2 ...
    # Lista os itens numerados (em stderr) e imprime no stdout o ÍNDICE
    # escolhido: 1..N, ou 0 quando "nenhum" é permitido e o usuário escolhe 0.
    local pergunta="$1" permitir_nenhum="$2"
    shift 2
    local itens=("$@") i min=1 padrao=""
    for i in "${!itens[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "${itens[$i]}" >&2
    done
    if [ "$permitir_nenhum" = "sim" ]; then
        printf '  0) nenhum\n' >&2
        min=0
    fi
    [ "${#itens[@]}" -eq 1 ] && [ "$min" -eq 1 ] && padrao=1
    perguntar_inteiro "$pergunta" "$padrao" "$min" "${#itens[@]}"
}

# --- Discos: identificação segura (nunca /dev/sdX chumbado) --------------------
disco_de() {
    # disco_de /dev/sda3 -> /dev/sda ; /dev/nvme0n1p2 -> /dev/nvme0n1
    # Sobe na hierarquia até encontrar um dispositivo do tipo "disk", para
    # funcionar também com LVM/LUKS (/dev/mapper/...).
    local atual="$1" tipo pk _i
    [ -n "$atual" ] || return 1
    for _i in 1 2 3 4 5; do
        tipo="$(lsblk -no TYPE "$atual" 2>/dev/null | head -n1 | tr -d ' ')"
        [ "$tipo" = "disk" ] && { echo "$atual"; return 0; }
        pk="$(lsblk -no PKNAME "$atual" 2>/dev/null | head -n1 | tr -d ' ')"
        [ -n "$pk" ] || return 1
        atual="/dev/$pk"
    done
    return 1
}

disco_raiz() {
    # Disco físico que contém a raiz (/) do Linux: JAMAIS pode ir para a VM.
    local fonte
    fonte="$(findmnt -no SOURCE / 2>/dev/null | sed 's/\[.*\]$//')"
    [ -n "$fonte" ] || return 1
    disco_de "$fonte"
}

disco_em_uso_pelo_host() {
    # 0 se qualquer partição do disco estiver montada no host (ou for a raiz).
    local disco="$1" raiz
    raiz="$(disco_raiz 2>/dev/null || true)"
    [ -n "$raiz" ] && [ "$disco" = "$raiz" ] && return 0
    lsblk -nlo NAME,MOUNTPOINT "$disco" 2>/dev/null \
        | awk 'NF>1 && $2!="" {encontrado=1} END{exit !encontrado}'
}

# --- Memória ---------------------------------------------------------------------
ram_total_mib() { awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo; }

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
detectar_bootloader() {
    if command -v kernelstub >/dev/null 2>&1 && [ -d /boot/efi/loader/entries ]; then
        echo "kernelstub"
    elif [ -f /boot/grub/grub.cfg ]; then
        echo "grub"
    else
        echo "desconhecido"
    fi
}

cmdline_tem() {
    # cmdline_tem "param" -> 0 se o parâmetro está na linha de comando do kernel
    local p palavra
    p="$1"
    for palavra in $(cat /proc/cmdline); do
        [ "$palavra" = "$p" ] && return 0
    done
    return 1
}

_grub_cmdline_atual() {
    grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub \
        | sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="(.*)"$/\1/'
}

kernel_param_add() {
    # kernel_param_add "param1 param2 ..." -> adiciona pelo caminho certo
    local params="$1" bl="${BOOTLOADER:-$(detectar_bootloader)}"
    case "$bl" in
        kernelstub)
            sudo kernelstub -a "$params"
            ;;
        grub)
            local arq=/etc/default/grub atual novo p w presente
            sudo cp "$arq" "${arq}.bak-$(date +%Y%m%d-%H%M%S)"
            atual="$(_grub_cmdline_atual)"
            novo="$atual"
            for p in $params; do
                presente=0
                for w in $novo; do [ "$w" = "$p" ] && presente=1; done
                [ "$presente" -eq 0 ] && novo="$novo $p"
            done
            novo="${novo# }"
            sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${novo}\"|" "$arq"
            sudo update-grub
            ;;
        *)
            falhar "Bootloader não identificado. Execute etapas/02-detectar-config.sh."
            ;;
    esac
    info "Parâmetros aplicados via ${bl}: $params"
    info "Para reverter depois: kernel_param_del (ver 'Como desfazer' do capítulo correspondente)."
}

kernel_param_del() {
    # kernel_param_del "param1 param2 ..." -> remove pelo caminho certo
    local params="$1" bl="${BOOTLOADER:-$(detectar_bootloader)}"
    case "$bl" in
        kernelstub)
            sudo kernelstub -d "$params"
            ;;
        grub)
            local arq=/etc/default/grub atual novo w p manter
            sudo cp "$arq" "${arq}.bak-$(date +%Y%m%d-%H%M%S)"
            atual="$(_grub_cmdline_atual)"
            novo=""
            for w in $atual; do
                manter=1
                for p in $params; do [ "$w" = "$p" ] && manter=0; done
                [ "$manter" -eq 1 ] && novo="$novo $w"
            done
            novo="${novo# }"
            sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${novo}\"|" "$arq"
            sudo update-grub
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
xml_backup() {
    # xml_backup NOME_DA_VM -> salva dumpxml datado em backups/
    local vm="$1" destino
    mkdir -p "$BACKUPS_DIR"
    destino="$BACKUPS_DIR/${vm}-$(date +%Y%m%d-%H%M%S).xml"
    $VIRSH dumpxml --inactive "$vm" > "$destino" \
        || falhar "Falha ao salvar backup do XML da VM '$vm'."
    info "Backup do XML salvo em: $destino"
}

vm_existe()    { $VIRSH dominfo "$1" >/dev/null 2>&1; }
vm_desligada() { [ "$($VIRSH domstate "$1" 2>/dev/null)" = "shut off" ]; }

exigir_vm_desligada() {
    vm_existe "$1" || falhar "A VM '$1' não existe. Execute a etapa 40 antes."
    vm_desligada "$1" \
        || falhar "A VM '$1' precisa estar DESLIGADA (use: virsh --connect qemu:///system shutdown $1)."
}

# --- CPUs ------------------------------------------------------------------------
expandir_lista_cpus() {
    # "0-2,5,8-9" -> imprime uma CPU por linha (expande intervalos)
    local parte partes
    IFS=',' read -ra partes <<< "$1"
    for parte in "${partes[@]}"; do
        if [[ "$parte" == *-* ]]; then
            seq "${parte%-*}" "${parte#*-}"
        else
            echo "$parte"
        fi
    done
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
# Cada etapa implementa uma função verificar() usando v_ok/v_falta e termina
# com v_fim: código de saída 0 = etapa concluída, 1 = pendente.
V_FALHAS=0
v_ok()    { ok "$*"; }
v_falta() { aviso "$*"; V_FALHAS=$((V_FALHAS+1)); }
v_fim()   { if [ "$V_FALHAS" -eq 0 ]; then exit 0; else exit 1; fi; }
