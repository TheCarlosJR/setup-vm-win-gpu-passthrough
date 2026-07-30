#!/bin/bash
# ============================================================================
# etapas/02-detectar-config.sh - Detecção e confirmação da configuração
# ============================================================================
# Implementa a regra central do manual: NUNCA usar valores inventados.
# Detecta no PRÓPRIO hardware os valores dos placeholders (Capítulos 3, 11,
# 15, 16, 19, 21 e 23), confirma cada um com o usuário e grava tudo em
# passthrough.conf, reutilizado por todas as demais etapas.
#
# Uso:
#   02-detectar-config.sh               detecta apenas o que falta no conf
#   02-detectar-config.sh --redetectar  refaz todas as detecções
#   02-detectar-config.sh --verificar   confere se o conf está completo
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

nome_usuario_valido() {
    [[ "${1:-}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

nome_vm_valido() {
    [[ "${1:-}" =~ ^[A-Za-z0-9_.-]+$ ]]
}

nome_servico_valido() {
    [[ "${1:-}" =~ ^[A-Za-z0-9_.@-]+$ ]]
}

nome_interface_valido() {
    local nome="${1:-}"
    [ "${#nome}" -le 15 ] && [[ "$nome" =~ ^[A-Za-z0-9_.-]+$ ]]
}

uuid_basico_valido() {
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

dispositivo_bloco_valido() {
    [[ "${1:-}" == /dev/* ]] && [ -b "$1" ]
}

gpu_valores_validos() {
    [[ "${1:-}" =~ ^0000:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]] \
        && [[ "${2:-}" =~ ^0000:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]] \
        && [[ "${3:-}" =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{4}$ ]] \
        && [[ "${4:-}" =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{4}$ ]]
}

_blkid_hd2() {
    local usar_sudo="$1"
    shift
    if [ "$usar_sudo" -eq 1 ]; then
        sudo blkid "$@"
    else
        blkid "$@"
    fi
}

resolver_hd2() {
    local uuid="${1:-}" nvme="${2:-}" usar_sudo="${3:-0}"
    local dev tipo fstype uuid_confirmado pkname pai tipo_pai
    local nvme_canonico tipo_nvme nvme_pkname nvme_pai

    _HD2_ERRO=""
    _HD2_DEV_CANONICO=""
    _HD2_DISCO_PAI_CANONICO=""

    if ! uuid_basico_valido "$uuid"; then
        _HD2_ERRO="UUID_HD2 tem formato inválido."
        return 1
    fi
    if ! command -v blkid >/dev/null 2>&1 || ! command -v lsblk >/dev/null 2>&1; then
        _HD2_ERRO="blkid e lsblk são necessários para validar UUID_HD2."
        return 1
    fi

    dev="$(_blkid_hd2 "$usar_sudo" -U "$uuid" 2>/dev/null || true)"
    if [ -z "$dev" ] || [[ "$dev" == *$'\n'* ]]; then
        _HD2_ERRO="UUID_HD2=$uuid não está disponível em uma única partição."
        return 1
    fi
    dev="$(readlink -f -- "$dev" 2>/dev/null || true)"
    if ! dispositivo_bloco_valido "$dev"; then
        _HD2_ERRO="UUID_HD2=$uuid não identifica uma partição de bloco acessível."
        return 1
    fi

    tipo="$(lsblk -dn -o TYPE -- "$dev" 2>/dev/null || true)"
    if [ "$tipo" != "part" ]; then
        _HD2_ERRO="UUID_HD2=$uuid deve identificar uma partição, não '$tipo'."
        return 1
    fi
    fstype="$(lsblk -dn -o FSTYPE -- "$dev" 2>/dev/null || true)"
    if [ "$fstype" != "ntfs" ] && [ "$fstype" != "ntfs3" ]; then
        _HD2_ERRO="UUID_HD2=$uuid deve identificar uma partição ntfs/ntfs3."
        return 1
    fi
    uuid_confirmado="$(lsblk -dn -o UUID -- "$dev" 2>/dev/null || true)"
    if [ "$uuid_confirmado" != "$uuid" ]; then
        _HD2_ERRO="A partição $dev não confirma UUID_HD2=$uuid."
        return 1
    fi

    pkname="$(lsblk -dn -o PKNAME -- "$dev" 2>/dev/null || true)"
    if [ -z "$pkname" ] || [[ "$pkname" == *$'\n'* ]]; then
        _HD2_ERRO="Não foi possível derivar o disco-pai de $dev."
        return 1
    fi
    [[ "$pkname" == /* ]] && pai="$pkname" || pai="/dev/$pkname"
    pai="$(readlink -f -- "$pai" 2>/dev/null || true)"
    if ! dispositivo_bloco_valido "$pai"; then
        _HD2_ERRO="Disco-pai derivado do HD2 é inválido: $pai"
        return 1
    fi
    tipo_pai="$(lsblk -dn -o TYPE -- "$pai" 2>/dev/null || true)"
    if [ "$tipo_pai" != "disk" ]; then
        _HD2_ERRO="O pai canônico de $dev não é um disco físico."
        return 1
    fi

    nvme_canonico="$(readlink -f -- "$nvme" 2>/dev/null || true)"
    if ! dispositivo_bloco_valido "$nvme_canonico"; then
        _HD2_ERRO="NVME_DEVICE é inválido ou indisponível: $nvme"
        return 1
    fi
    tipo_nvme="$(lsblk -dn -o TYPE -- "$nvme_canonico" 2>/dev/null || true)"
    case "$tipo_nvme" in
        disk)
            nvme_pai="$nvme_canonico"
            ;;
        part)
            nvme_pkname="$(lsblk -dn -o PKNAME -- "$nvme_canonico" 2>/dev/null || true)"
            [ -n "$nvme_pkname" ] && [[ "$nvme_pkname" != *$'\n'* ]] \
                || { _HD2_ERRO="Não foi possível derivar o disco físico de NVME_DEVICE."; return 1; }
            [[ "$nvme_pkname" == /* ]] && nvme_pai="$nvme_pkname" || nvme_pai="/dev/$nvme_pkname"
            nvme_pai="$(readlink -f -- "$nvme_pai" 2>/dev/null || true)"
            ;;
        *)
            _HD2_ERRO="NVME_DEVICE não resolve para disco ou partição física."
            return 1
            ;;
    esac
    if ! dispositivo_bloco_valido "$nvme_pai" \
        || [ "$(lsblk -dn -o TYPE -- "$nvme_pai" 2>/dev/null || true)" != "disk" ]; then
        _HD2_ERRO="Não foi possível validar o disco físico de NVME_DEVICE."
        return 1
    fi
    if [ "$pai" = "$nvme_pai" ]; then
        _HD2_ERRO="UUID_HD2=$uuid pertence ao mesmo disco físico de NVME_DEVICE."
        return 1
    fi

    _HD2_DEV_CANONICO="$dev"
    _HD2_DISCO_PAI_CANONICO="$pai"
}

valores_cpu_validos() {
    local cpus_vm="${1:-}" cpus_host="${2:-}" cores="${3:-}"
    local threads="${4:-}" vcpus="${5:-}" esperado cpu dono chave
    local saida primeira=1 cpu_topo core_topo socket_topo online_topo
    local nucleos_vm_total=0 nucleos_host_total=0
    local -a lista_vm lista_host
    local -A online=() cpu_nucleo=() nucleo_threads=() vistos=()
    local -A dono_nucleo=() nucleos_vm=() nucleos_host=()

    [[ "$cpus_vm" =~ ^[0-9]+(,[0-9]+)*$ ]] || return 1
    [[ "$cpus_host" =~ ^[0-9]+(,[0-9]+)*$ ]] || return 1
    inteiro_positivo "$cores" && inteiro_positivo "$threads" \
        && inteiro_positivo "$vcpus" || return 1
    [ "${#cores}" -le 9 ] && [ "${#threads}" -le 9 ] \
        && [ "${#vcpus}" -le 9 ] || return 1

    esperado=$((10#$cores * 10#$threads))
    [ "$esperado" -eq "$((10#$vcpus))" ] || return 1
    IFS=',' read -r -a lista_vm <<< "$cpus_vm"
    IFS=',' read -r -a lista_host <<< "$cpus_host"
    [ "${#lista_vm[@]}" -eq "$((10#$vcpus))" ] || return 1
    [ "${#lista_host[@]}" -gt 0 ] || return 1

    command -v lscpu >/dev/null 2>&1 || return 1
    saida="$(LC_ALL=C lscpu -e=CPU,CORE,SOCKET,ONLINE 2>/dev/null)" || return 1
    while read -r cpu_topo core_topo socket_topo online_topo; do
        if [ "$primeira" -eq 1 ]; then
            primeira=0
            continue
        fi
        [ "$online_topo" = "yes" ] || continue
        [[ "$cpu_topo" =~ ^(0|[1-9][0-9]*)$ ]] \
            && [[ "$core_topo" =~ ^(0|[1-9][0-9]*)$ ]] \
            && [[ "$socket_topo" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
        [ -z "${online[$cpu_topo]+presente}" ] || return 1
        chave="${socket_topo}:${core_topo}"
        online[$cpu_topo]=1
        cpu_nucleo[$cpu_topo]="$chave"
        nucleo_threads[$chave]=$(( ${nucleo_threads[$chave]:-0} + 1 ))
    done <<< "$saida"
    [ "$primeira" -eq 0 ] && [ "${#online[@]}" -gt 0 ] || return 1

    for cpu in "${lista_vm[@]}" "${lista_host[@]}"; do
        [[ "$cpu" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
        [ -n "${online[$cpu]+presente}" ] || return 1
        [ -z "${vistos[$cpu]+presente}" ] || return 1
        vistos[$cpu]=1
        chave="${cpu_nucleo[$cpu]}"
        if [ -z "${dono_nucleo[$chave]+definido}" ]; then
            if [ -z "${nucleos_vm[$chave]+definido}" ] \
                && [ "${#vistos[@]}" -le "${#lista_vm[@]}" ]; then
                dono="vm"
                nucleos_vm[$chave]=1
                nucleos_vm_total=$((nucleos_vm_total + 1))
            else
                dono="host"
                nucleos_host[$chave]=1
                nucleos_host_total=$((nucleos_host_total + 1))
            fi
            dono_nucleo[$chave]="$dono"
        elif [ "${#vistos[@]}" -le "${#lista_vm[@]}" ]; then
            [ "${dono_nucleo[$chave]}" = "vm" ] || return 1
        else
            [ "${dono_nucleo[$chave]}" = "host" ] || return 1
        fi
    done

    [ "${#vistos[@]}" -eq "${#online[@]}" ] || return 1
    [ "$nucleos_vm_total" -eq "$((10#$cores))" ] \
        && [ "$nucleos_host_total" -ge 1 ] || return 1
    for chave in "${!nucleos_vm[@]}"; do
        [ "${nucleo_threads[$chave]}" -eq "$((10#$threads))" ] || return 1
    done
}

valores_memoria_validos() {
    local ram="${1:-}" hugepages="${2:-}" total="${3:-}"
    inteiro_positivo "$ram" && inteiro_positivo "$hugepages" \
        && inteiro_positivo "$total" || return 1
    [ "${#ram}" -le 9 ] && [ "${#hugepages}" -le 9 ] \
        && [ "${#total}" -le 12 ] || return 1
    [ $((10#$ram % 1024)) -eq 0 ] \
        && [ "$((10#$hugepages))" -eq "$((10#$ram / 1024))" ] \
        && [ "$((10#$ram))" -lt "$((10#$total))" ]
}

verificar() {
    [ -f "$CONF_ARQUIVO" ] && v_ok "passthrough.conf existe." || v_falta "passthrough.conf não existe."
    local var caminho ram_total_mb
    local -a obrigatorias=(
        USUARIO_LINUX VM_NAME BOOTLOADER GPU_PCI_ID GPU_AUDIO_PCI_ID
        GPU_VENDOR_DEVICE_ID GPU_AUDIO_VENDOR_DEVICE_ID DM_SERVICE NVME_DEVICE
        UUID_HD2 HD2_DISCO_PAI HD1_BY_ID_PATH DOCS4_MONTAGEM QCOW2_PATH
        QCOW2_TAMANHO VM_RAM_MB VM_VCPUS VM_CORES VM_THREADS CPUS_VM CPUS_HOST
        HUGEPAGES_1G INTERFACE_FISICA TRANSFER_USER
    )
    for var in "${obrigatorias[@]}"; do
        if [ -n "${!var:-}" ]; then
            v_ok "$var=${!var}"
        else
            v_falta "$var ainda não definido."
        fi
    done

    [ -z "${USUARIO_LINUX:-}" ] || nome_usuario_valido "$USUARIO_LINUX" \
        || v_falta "USUARIO_LINUX tem formato inválido."
    [ -z "${VM_NAME:-}" ] || nome_vm_valido "$VM_NAME" \
        || v_falta "VM_NAME tem formato inválido."
    if [ -n "${BOOTLOADER:-}" ] && [ "$BOOTLOADER" != "kernelstub" ] && [ "$BOOTLOADER" != "grub" ]; then
        v_falta "BOOTLOADER deve ser kernelstub ou grub."
    fi
    if [ -n "${GPU_PCI_ID:-}${GPU_AUDIO_PCI_ID:-}${GPU_VENDOR_DEVICE_ID:-}${GPU_AUDIO_VENDOR_DEVICE_ID:-}" ] \
        && ! gpu_valores_validos "${GPU_PCI_ID:-}" "${GPU_AUDIO_PCI_ID:-}" \
            "${GPU_VENDOR_DEVICE_ID:-}" "${GPU_AUDIO_VENDOR_DEVICE_ID:-}"; then
        v_falta "O conjunto de quatro valores da GPU está incompleto ou inválido."
    fi
    [ -z "${DM_SERVICE:-}" ] || nome_servico_valido "$DM_SERVICE" \
        || v_falta "DM_SERVICE tem formato inválido."
    [ -z "${UUID_HD2:-}" ] || uuid_basico_valido "$UUID_HD2" \
        || v_falta "UUID_HD2 tem formato inválido."
    [ -z "${INTERFACE_FISICA:-}" ] || nome_interface_valido "$INTERFACE_FISICA" \
        || v_falta "INTERFACE_FISICA tem formato inválido."
    [ -z "${TRANSFER_USER:-}" ] || nome_usuario_valido "$TRANSFER_USER" \
        || v_falta "TRANSFER_USER tem formato inválido."

    for caminho in NVME_DEVICE HD2_DISCO_PAI HD1_BY_ID_PATH DOCS4_MONTAGEM QCOW2_PATH; do
        [ -z "${!caminho:-}" ] || [[ "${!caminho}" == /* ]] \
            || v_falta "$caminho deve ser um caminho absoluto."
    done
    [ -z "${HD1_BY_ID_PATH:-}" ] || [[ "$HD1_BY_ID_PATH" == /dev/disk/by-id/* ]] \
        || v_falta "HD1_BY_ID_PATH deve usar /dev/disk/by-id/."
    [ -z "${QCOW2_TAMANHO:-}" ] || [[ "$QCOW2_TAMANHO" =~ ^[1-9][0-9]*[KMGT]$ ]] \
        || v_falta "QCOW2_TAMANHO tem formato inválido."

    if [ -n "${UUID_HD2:-}" ] && [ -n "${NVME_DEVICE:-}" ] \
        && uuid_basico_valido "$UUID_HD2"; then
        if resolver_hd2 "$UUID_HD2" "$NVME_DEVICE" 0; then
            [ "${HD2_DISCO_PAI:-}" = "$_HD2_DISCO_PAI_CANONICO" ] \
                || v_falta "HD2_DISCO_PAI não corresponde ao disco-pai canônico de UUID_HD2."
        else
            v_falta "$_HD2_ERRO"
        fi
    fi

    if [ -n "${CPUS_VM:-}${CPUS_HOST:-}${VM_CORES:-}${VM_THREADS:-}${VM_VCPUS:-}" ] \
        && ! valores_cpu_validos "${CPUS_VM:-}" "${CPUS_HOST:-}" \
            "${VM_CORES:-}" "${VM_THREADS:-}" "${VM_VCPUS:-}"; then
        v_falta "Topologia ou listas de CPU inválidas/inconsistentes com as CPUs online."
    fi

    ram_total_mb="$(awk '/MemTotal/{printf "%d", $2/1024; exit}' /proc/meminfo 2>/dev/null || true)"
    if ! inteiro_positivo "$ram_total_mb"; then
        v_falta "Não foi possível detectar a RAM total do host."
    elif [ -n "${VM_RAM_MB:-}${HUGEPAGES_1G:-}" ] \
        && ! valores_memoria_validos "${VM_RAM_MB:-}" "${HUGEPAGES_1G:-}" "$ram_total_mb"; then
        v_falta "Reserva de RAM/HugePages inválida, inconsistente ou impossível para a RAM total."
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

REDETECTAR=0
[ "${1:-}" = "--redetectar" ] && REDETECTAR=1

exigir_nao_root
exigir_sudo
exigir_comando lspci lsblk blkid lscpu ip awk sed readlink flock stat

# ja_definido VAR: retorna 0 se a variável já tem valor e não estamos redetectando
ja_definido() {
    [ "$REDETECTAR" -eq 0 ] && [ -n "${!1:-}" ]
}

titulo "Detecção de configuração (grava em $CONF_ARQUIVO)"
if [ ! -e "$CONF_ARQUIVO" ]; then
    inicializar_conf "$PROJETO_DIR/passthrough.conf.example"
    info "Conf criado a partir do modelo."
fi

# ----------------------------------------------------------------------------
# 1. Identidade
# ----------------------------------------------------------------------------
titulo "1/8 Identidade"
if ja_definido USUARIO_LINUX; then
    nome_usuario_valido "$USUARIO_LINUX" && id -u -- "$USUARIO_LINUX" >/dev/null 2>&1 \
        || falhar "USUARIO_LINUX inválido ou inexistente: $USUARIO_LINUX"
    info "USUARIO_LINUX já definido: $USUARIO_LINUX"
else
    USUARIO_ESCOLHIDO="$(perguntar 'Usuário Linux principal' "${USER}")"
    nome_usuario_valido "$USUARIO_ESCOLHIDO" && id -u -- "$USUARIO_ESCOLHIDO" >/dev/null 2>&1 \
        || falhar "Usuário Linux inválido ou inexistente: $USUARIO_ESCOLHIDO"
    salvar_conf USUARIO_LINUX "$USUARIO_ESCOLHIDO"
fi
if ja_definido VM_NAME; then
    nome_vm_valido "$VM_NAME" || falhar "VM_NAME tem formato inválido: $VM_NAME"
    info "VM_NAME já definido: $VM_NAME"
else
    VM_ESCOLHIDA="$(perguntar 'Nome da VM no libvirt' 'win11')"
    nome_vm_valido "$VM_ESCOLHIDA" || falhar "Nome de VM inválido: $VM_ESCOLHIDA"
    salvar_conf VM_NAME "$VM_ESCOLHIDA"
fi

# ----------------------------------------------------------------------------
# 2. Bootloader (Capítulo 15)
# ----------------------------------------------------------------------------
titulo "2/8 Bootloader (Capítulo 15)"
if ja_definido BOOTLOADER; then
    [ "$BOOTLOADER" = "kernelstub" ] || [ "$BOOTLOADER" = "grub" ] \
        || falhar "BOOTLOADER inválido: $BOOTLOADER"
    info "BOOTLOADER já definido: $BOOTLOADER"
else
    BL="$(detectar_bootloader)"
    if [ "$BL" = "desconhecido" ]; then
        erro "Não identifiquei kernelstub nem GRUB. Diagnóstico:"
        echo "  - modo de firmware: $([ -d /sys/firmware/efi ] && echo UEFI || echo Legacy/BIOS)"
        echo "  - kernelstub: $(command -v kernelstub || echo 'não encontrado')"
        echo "  - /boot/efi/loader/entries: $(ls /boot/efi/loader/entries/ 2>/dev/null || echo 'não encontrado')"
        echo "  - /boot/grub/grub.cfg: $([ -f /boot/grub/grub.cfg ] && echo existe || echo 'não encontrado')"
        falhar "Revise o Capítulo 15 do manual antes de continuar."
    fi
    ok "Bootloader detectado: $BL"
    salvar_conf BOOTLOADER "$BL"
fi

# ----------------------------------------------------------------------------
# 3. GPU (Capítulo 16)
# ----------------------------------------------------------------------------
titulo "3/8 GPU NVIDIA (Capítulo 16)"
GPU_PREENCHIDOS=0
for VAR in GPU_PCI_ID GPU_AUDIO_PCI_ID GPU_VENDOR_DEVICE_ID GPU_AUDIO_VENDOR_DEVICE_ID; do
    [ -z "${!VAR:-}" ] || GPU_PREENCHIDOS=$((GPU_PREENCHIDOS + 1))
done
if [ "$REDETECTAR" -eq 0 ] && [ "$GPU_PREENCHIDOS" -eq 4 ]; then
    gpu_valores_validos "$GPU_PCI_ID" "$GPU_AUDIO_PCI_ID" \
        "$GPU_VENDOR_DEVICE_ID" "$GPU_AUDIO_VENDOR_DEVICE_ID" \
        || falhar "O conjunto de valores da GPU é inválido; use --redetectar."
    info "GPU já definida: $GPU_PCI_ID [$GPU_VENDOR_DEVICE_ID] / áudio $GPU_AUDIO_PCI_ID [$GPU_AUDIO_VENDOR_DEVICE_ID]"
else
    if [ "$REDETECTAR" -eq 0 ] && [ "$GPU_PREENCHIDOS" -gt 0 ]; then
        aviso "Configuração parcial da GPU encontrada; os quatro valores serão detectados novamente."
    fi
    mapfile -t LINHAS_VGA < <(lspci -nn | grep -i nvidia | grep -iE 'vga compatible|3d controller' || true)
    if [ "${#LINHAS_VGA[@]}" -eq 0 ]; then
        falhar "Nenhuma GPU NVIDIA encontrada no lspci. Confira o encaixe/alimentação (Capítulo 3)."
    fi
    LINHA_VGA="${LINHAS_VGA[0]}"
    if [ "${#LINHAS_VGA[@]}" -gt 1 ]; then
        echo "Mais de uma GPU NVIDIA encontrada:"
        local_i=1
        for l in "${LINHAS_VGA[@]}"; do echo "  $local_i) $l"; local_i=$((local_i+1)); done
        ESCOLHA="$(perguntar 'Qual é a GPU do passthrough? (número)' '1')"
        indice_array_valido "$ESCOLHA" "${#LINHAS_VGA[@]}" \
            || falhar "Seleção de GPU inválida: $ESCOLHA"
        ESCOLHA_IDX=$((10#$ESCOLHA - 1))
        LINHA_VGA="${LINHAS_VGA[$ESCOLHA_IDX]}"
    fi

    END_VGA="${LINHA_VGA%% *}"                                    # ex.: 0c:00.0
    ID_VGA="$(grep -oE '\[[0-9a-fA-F]{4}:[0-9a-fA-F]{4}\]' <<< "$LINHA_VGA" | tail -n1 | tr -d '[]')"

    BASE="${END_VGA%.*}"                                          # ex.: 0c:00
    LINHA_AUDIO="$(lspci -nn | grep -i nvidia | grep -i audio | grep "^${BASE}\." | head -n1 || true)"
    if [ -z "$LINHA_AUDIO" ]; then
        falhar "Função de áudio HDMI da GPU não encontrada em ${BASE}.x (esperada para a RTX 3060)."
    fi
    END_AUDIO="${LINHA_AUDIO%% *}"
    ID_AUDIO="$(grep -oE '\[[0-9a-fA-F]{4}:[0-9a-fA-F]{4}\]' <<< "$LINHA_AUDIO" | tail -n1 | tr -d '[]')"

    GPU_PCI_NOVO="0000:${END_VGA}"
    GPU_AUDIO_PCI_NOVO="0000:${END_AUDIO}"
    gpu_valores_validos "$GPU_PCI_NOVO" "$GPU_AUDIO_PCI_NOVO" "$ID_VGA" "$ID_AUDIO" \
        || falhar "A detecção da GPU retornou endereços ou IDs inválidos."

    echo "Detectado no SEU hardware:"
    echo "  Vídeo: $LINHA_VGA"
    echo "  Áudio: $LINHA_AUDIO"
    confirmar "Confirmar estes dois dispositivos como a GPU do passthrough?" \
        || falhar "Cancelado. Rode novamente e escolha o dispositivo correto."

    # Os quatro valores são validados antes da única atualização persistente.
    salvar_conf_multiplos \
        GPU_PCI_ID "$GPU_PCI_NOVO" \
        GPU_AUDIO_PCI_ID "$GPU_AUDIO_PCI_NOVO" \
        GPU_VENDOR_DEVICE_ID "$ID_VGA" \
        GPU_AUDIO_VENDOR_DEVICE_ID "$ID_AUDIO"
    ok "GPU: $GPU_PCI_ID [$GPU_VENDOR_DEVICE_ID] / áudio $GPU_AUDIO_PCI_ID [$GPU_AUDIO_VENDOR_DEVICE_ID]"
fi

# ----------------------------------------------------------------------------
# 4. Serviço gráfico (para os hooks do Capítulo 19)
# ----------------------------------------------------------------------------
titulo "4/8 Gerenciador de exibição"
if ja_definido DM_SERVICE; then
    nome_servico_valido "$DM_SERVICE" || falhar "DM_SERVICE inválido: $DM_SERVICE"
    info "DM_SERVICE já definido: $DM_SERVICE"
else
    DM="display-manager"
    for s in gdm3 gdm cosmic-greeter; do
        if systemctl list-unit-files "${s}.service" 2>/dev/null | grep -q "^${s}.service"; then
            DM="$s"; break
        fi
    done
    ok "Serviço gráfico detectado: $DM"
    salvar_conf DM_SERVICE "$DM"
fi

# ----------------------------------------------------------------------------
# 5. Discos (Capítulos 5, 11 e 19)
# ----------------------------------------------------------------------------
titulo "5/8 Discos"
echo "Visão geral (compare com o inventário do Capítulo 3):"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL,TRAN
echo

# 5a. NVMe
if ja_definido NVME_DEVICE; then
    dispositivo_bloco_valido "$NVME_DEVICE" || falhar "NVME_DEVICE inválido ou inexistente: $NVME_DEVICE"
    info "NVME_DEVICE já definido: $NVME_DEVICE"
else
    mapfile -t NVMES < <(lsblk -dn -o NAME,TRAN | awk '$2=="nvme"{print "/dev/"$1}')
    case "${#NVMES[@]}" in
        0) aviso "Nenhum NVMe detectado; informe manualmente."
           NVME_ESCOLHIDO="$(perguntar 'Dispositivo do disco do sistema' '/dev/nvme0n1')" ;;
        1) ok "NVMe detectado: ${NVMES[0]}"
           NVME_ESCOLHIDO="${NVMES[0]}" ;;
        *) echo "Mais de um NVMe:"; printf '  %s\n' "${NVMES[@]}"
           NVME_ESCOLHIDO="$(perguntar 'Qual é o disco do SISTEMA?' "${NVMES[0]}")" ;;
    esac
    dispositivo_bloco_valido "$NVME_ESCOLHIDO" \
        || falhar "Dispositivo do sistema inválido ou inexistente: $NVME_ESCOLHIDO"
    salvar_conf NVME_DEVICE "$NVME_ESCOLHIDO"
fi

# 5b. HD2 (NTFS montado em /mnt/docs4) - identificado por UUID
UUID_HD2_NOVO=0
if ja_definido UUID_HD2; then
    uuid_basico_valido "$UUID_HD2" || falhar "UUID_HD2 inválido: $UUID_HD2"
    info "UUID_HD2 já definido: $UUID_HD2"
else
    echo "Partições NTFS encontradas (candidatas a HD2):"
    mapfile -t NTFS_DEVS < <(sudo blkid -t TYPE=ntfs -o device 2>/dev/null; sudo blkid -t TYPE=ntfs3 -o device 2>/dev/null || true)
    if [ "${#NTFS_DEVS[@]}" -eq 0 ]; then
        falhar "Nenhuma partição NTFS encontrada. O HD2 está conectado? (Capítulo 11)"
    fi
    i=1
    for d in "${NTFS_DEVS[@]}"; do
        TAM="$(lsblk -no SIZE "$d" 2>/dev/null | head -n1)"
        MODELO="$(lsblk -no MODEL "/dev/$(lsblk -no PKNAME "$d" 2>/dev/null | head -n1)" 2>/dev/null | head -n1 || true)"
        echo "  $i) $d  (${TAM:-?}; disco: ${MODELO:-?})  UUID=$(sudo blkid -s UUID -o value "$d")"
        i=$((i+1))
    done
    aviso "HD2 é o disco NTFS EXCLUSIVO DO LINUX (documentos), NUNCA o HD1 da VM."
    ESCOLHA="$(perguntar 'Qual é a partição do HD2? (número)' '1')"
    indice_array_valido "$ESCOLHA" "${#NTFS_DEVS[@]}" \
        || falhar "Seleção de HD2 inválida: $ESCOLHA"
    ESCOLHA_IDX=$((10#$ESCOLHA - 1))
    DEV_HD2="${NTFS_DEVS[$ESCOLHA_IDX]}"
    UUID_ESCOLHIDO="$(sudo blkid -s UUID -o value -- "$DEV_HD2" 2>/dev/null || true)"
    uuid_basico_valido "$UUID_ESCOLHIDO" \
        || falhar "A partição selecionada não retornou um UUID válido e disponível."
    UUID_HD2="$UUID_ESCOLHIDO"
    UUID_HD2_NOVO=1
fi

# Resolve e valida antes de persistir, inclusive quando o UUID já existia no conf.
if ! resolver_hd2 "$UUID_HD2" "$NVME_DEVICE" 1; then
    falhar "$_HD2_ERRO"
fi
DEV_HD2="$_HD2_DEV_CANONICO"
HD2_DISCO_PAI_NOVO="$_HD2_DISCO_PAI_CANONICO"
if [ "$UUID_HD2_NOVO" -eq 1 ]; then
    confirmar "Confirmar HD2 = $DEV_HD2 (UUID=$UUID_HD2; disco=$HD2_DISCO_PAI_NOVO)?" \
        || falhar "Cancelado."
fi
salvar_conf_multiplos \
    UUID_HD2 "$UUID_HD2" \
    HD2_DISCO_PAI "$HD2_DISCO_PAI_NOVO"

# 5c. HD1 (disco inteiro da VM) - caminho estável by-id
HD1_NOVO=0
if ja_definido HD1_BY_ID_PATH; then
    [[ "$HD1_BY_ID_PATH" == /dev/disk/by-id/* ]] \
        || falhar "HD1_BY_ID_PATH deve usar /dev/disk/by-id/: $HD1_BY_ID_PATH"
    HD1="$HD1_BY_ID_PATH"
    info "HD1_BY_ID_PATH já definido: $HD1_BY_ID_PATH"
else
    echo "Discos inteiros em /dev/disk/by-id/ (sem NVMe, sem partições, sem wwn):"
    mapfile -t BYIDS < <(find /dev/disk/by-id -maxdepth 1 -name 'ata-*' ! -name '*-part*' 2>/dev/null | sort)
    if [ "${#BYIDS[@]}" -eq 0 ]; then
        mapfile -t BYIDS < <(find /dev/disk/by-id -maxdepth 1 ! -name '*nvme*' ! -name '*-part*' ! -name 'wwn-*' -type l 2>/dev/null | sort)
    fi
    [ "${#BYIDS[@]}" -gt 0 ] || falhar "Nenhum disco encontrado em /dev/disk/by-id/. O HD1 está conectado?"
    i=1
    for b in "${BYIDS[@]}"; do
        ALVO="$(readlink -f "$b")"
        TAM="$(lsblk -dno SIZE "$ALVO" 2>/dev/null || true)"
        echo "  $i) $b -> $ALVO (${TAM:-?})"
        i=$((i+1))
    done
    aviso "HD1 é o disco NTFS EXCLUSIVO DA VM (Steam/jogos). Errar aqui pode corromper outro disco."
    ESCOLHA="$(perguntar 'Qual é o HD1? (número)' '1')"
    indice_array_valido "$ESCOLHA" "${#BYIDS[@]}" \
        || falhar "Seleção de HD1 inválida: $ESCOLHA"
    ESCOLHA_IDX=$((10#$ESCOLHA - 1))
    HD1="${BYIDS[$ESCOLHA_IDX]}"
    HD1_NOVO=1
fi

HD1_ALVO="$(readlink -f "$HD1")"
dispositivo_bloco_valido "$HD1_ALVO" || falhar "HD1 inválido ou inexistente: $HD1"
NVME_ALVO="$(readlink -f "$NVME_DEVICE")"
HD2_PAI_ALVO="$(readlink -f "$HD2_DISCO_PAI")"
[ "$HD1_ALVO" = "$NVME_ALVO" ] \
    && falhar "O caminho escolhido aponta para o NVMe do sistema. Abortado."
[ "$HD1_ALVO" = "$HD2_PAI_ALVO" ] \
    && falhar "O caminho escolhido aponta para o disco do HD2. Abortado."
if [ "$HD1_NOVO" -eq 1 ]; then
    confirmar "Confirmar HD1 = $HD1 ($HD1_ALVO)? Confira modelo/serial no inventário." || falhar "Cancelado."
    salvar_conf HD1_BY_ID_PATH "$HD1"
fi

# ----------------------------------------------------------------------------
# 6. CPU: topologia e pinning (Capítulo 21)
# ----------------------------------------------------------------------------
titulo "6/8 CPU (topologia real via lscpu -e)"
if ja_definido CPUS_VM && ja_definido CPUS_HOST && ja_definido VM_CORES \
    && ja_definido VM_THREADS && ja_definido VM_VCPUS; then
    valores_cpu_validos "$CPUS_VM" "$CPUS_HOST" "$VM_CORES" "$VM_THREADS" "$VM_VCPUS" \
        || falhar "Configuração de CPU existente é inválida; use --redetectar."
    info "Pinning já definido: VM=[$CPUS_VM] HOST=[$CPUS_HOST]"
else
    echo "Mapa lógico da CPU:"
    lscpu -e
    echo

    # Agrupa CPUs lógicas por núcleo físico, distinguindo sockets.
    declare -A NUCLEO_THREADS=()
    while read -r CPU CORE SOCKET ONLINE; do
        [ "$ONLINE" = "yes" ] || continue
        [[ "$CPU" =~ ^[0-9]+$ && "$CORE" =~ ^[0-9]+$ && "$SOCKET" =~ ^[0-9]+$ ]] \
            || falhar "Topologia inválida retornada por lscpu."
        CHAVE_NUCLEO="${SOCKET}:${CORE}"
        NUCLEO_THREADS[$CHAVE_NUCLEO]="${NUCLEO_THREADS[$CHAVE_NUCLEO]:+${NUCLEO_THREADS[$CHAVE_NUCLEO]},}$CPU"
    done < <(LC_ALL=C lscpu -e=CPU,CORE,SOCKET,ONLINE | tail -n +2)

    mapfile -t NUCLEOS < <(printf '%s\n' "${!NUCLEO_THREADS[@]}" | sort -t: -k1,1n -k2,2n)
    TOTAL_NUCLEOS="${#NUCLEOS[@]}"
    [ "$TOTAL_NUCLEOS" -ge 2 ] \
        || falhar "São necessários ao menos 2 núcleos físicos online para reservar um ao host."
    THREADS_POR_NUCLEO="$(awk -F',' '{print NF}' <<< "${NUCLEO_THREADS[${NUCLEOS[0]}]}")"
    inteiro_positivo "$THREADS_POR_NUCLEO" || falhar "Número de threads por núcleo inválido."
    info "Detectados $TOTAL_NUCLEOS núcleos físicos, $THREADS_POR_NUCLEO thread(s) por núcleo."

    PADRAO_VM=6
    [ "$TOTAL_NUCLEOS" -le 4 ] && PADRAO_VM=$((TOTAL_NUCLEOS-1))
    [ "$PADRAO_VM" -lt "$TOTAL_NUCLEOS" ] || PADRAO_VM=$((TOTAL_NUCLEOS-1))
    NUC_VM="$(perguntar "Núcleos físicos dedicados à VM (o restante fica com o host)" "$PADRAO_VM")"
    indice_array_valido "$NUC_VM" "$((TOTAL_NUCLEOS - 1))" \
        || falhar "Número de núcleos inválido; reserve ao menos 1 núcleo físico para o host."
    NUC_VM=$((10#$NUC_VM))

    LISTA_VM=""; LISTA_HOST=""
    idx=0
    for CORE in "${NUCLEOS[@]}"; do
        if [ "$idx" -lt "$NUC_VM" ]; then
            LISTA_VM="${LISTA_VM:+${LISTA_VM},}${NUCLEO_THREADS[$CORE]}"
        else
            LISTA_HOST="${LISTA_HOST:+${LISTA_HOST},}${NUCLEO_THREADS[$CORE]}"
        fi
        idx=$((idx+1))
    done
    VCPUS_TOTAL="$(awk -F',' '{print NF}' <<< "$LISTA_VM")"
    valores_cpu_validos "$LISTA_VM" "$LISTA_HOST" "$NUC_VM" \
        "$THREADS_POR_NUCLEO" "$VCPUS_TOTAL" \
        || falhar "A topologia detectada produziu uma configuração de CPU inconsistente."

    echo "Proposta de alocação (mesma estratégia do Capítulo 21):"
    echo "  VM   ($NUC_VM núcleos, $VCPUS_TOTAL vCPUs): $LISTA_VM"
    echo "  HOST ($((TOTAL_NUCLEOS-NUC_VM)) núcleos):            $LISTA_HOST"
    confirmar "Confirmar este mapa?" || falhar "Cancelado. Rode novamente e ajuste."

    salvar_conf_multiplos \
        CPUS_VM "$LISTA_VM" \
        CPUS_HOST "$LISTA_HOST" \
        VM_CORES "$NUC_VM" \
        VM_THREADS "$THREADS_POR_NUCLEO" \
        VM_VCPUS "$VCPUS_TOTAL"
fi

# ----------------------------------------------------------------------------
# 7. Memória da VM e HugePages (Capítulo 21)
# ----------------------------------------------------------------------------
titulo "7/8 Memória da VM"
RAM_TOTAL_MB="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)"
inteiro_positivo "$RAM_TOTAL_MB" || falhar "Não foi possível detectar a RAM total do host."
info "RAM total do host: ${RAM_TOTAL_MB} MiB"
if ja_definido VM_RAM_MB; then
    RAM_VM="$VM_RAM_MB"
    info "VM_RAM_MB já definido: $VM_RAM_MB"
else
    RAM_VM="$(perguntar 'RAM da VM em MiB (múltiplo de 1024)' '16384')"
fi
inteiro_positivo "$RAM_VM" && [ "${#RAM_VM}" -le 9 ] \
    || falhar "RAM da VM deve ser um inteiro positivo em MiB."
RAM_VM=$((10#$RAM_VM))
[ "$RAM_VM" -lt "$RAM_TOTAL_MB" ] \
    || falhar "RAM da VM deve ser menor que a RAM total para deixar memória ao host."
[ $((RAM_VM % 1024)) -eq 0 ] \
    || falhar "RAM da VM deve ser múltipla de 1024 MiB para HugePages de 1 GiB."
HUGEPAGES_CALCULADAS=$((RAM_VM / 1024))
valores_memoria_validos "$RAM_VM" "$HUGEPAGES_CALCULADAS" "$RAM_TOTAL_MB" \
    || falhar "Reserva de RAM/HugePages inválida ou impossível para a RAM total."
salvar_conf_multiplos \
    VM_RAM_MB "$RAM_VM" \
    HUGEPAGES_1G "$HUGEPAGES_CALCULADAS"

# ----------------------------------------------------------------------------
# 8. Rede e demais valores
# ----------------------------------------------------------------------------
titulo "8/8 Rede e complementos"
if ja_definido INTERFACE_FISICA; then
    nome_interface_valido "$INTERFACE_FISICA" \
        && ip link show dev "$INTERFACE_FISICA" >/dev/null 2>&1 \
        || falhar "INTERFACE_FISICA inválida ou inexistente: $INTERFACE_FISICA"
    info "INTERFACE_FISICA já definida: $INTERFACE_FISICA"
else
    echo "Interfaces de rede:"
    ip -o link show | awk -F': ' '{print "  - "$2}'
    mapfile -t ETHS < <(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(en|eth)' || true)
    PADRAO_IF="${ETHS[0]:-}"
    aviso "Use a interface Ethernet CABEADA (bridge sobre Wi-Fi não é coberta pelo manual)."
    INTERFACE_ESCOLHIDA="$(perguntar 'Interface física para a bridge' "$PADRAO_IF")"
    nome_interface_valido "$INTERFACE_ESCOLHIDA" \
        && ip link show dev "$INTERFACE_ESCOLHIDA" >/dev/null 2>&1 \
        || falhar "Interface física inválida ou inexistente: $INTERFACE_ESCOLHIDA"
    salvar_conf INTERFACE_FISICA "$INTERFACE_ESCOLHIDA"
fi

if ja_definido TRANSFER_USER; then
    nome_usuario_valido "$TRANSFER_USER" || falhar "TRANSFER_USER inválido: $TRANSFER_USER"
else
    TRANSFER_ESCOLHIDO="$(perguntar 'Usuário de transferência do airlock' 'vmtransfer')"
    nome_usuario_valido "$TRANSFER_ESCOLHIDO" \
        || falhar "Nome de usuário de transferência inválido: $TRANSFER_ESCOLHIDO"
    salvar_conf TRANSFER_USER "$TRANSFER_ESCOLHIDO"
fi

# ISOs: opcionais aqui; obrigatórias somente na etapa 40
for PAR in "ISO_WINDOWS:ISO do Windows 11" "ISO_VIRTIO:ISO virtio-win"; do
    VAR="${PAR%%:*}"; DESC="${PAR#*:}"
    if ! ja_definido "$VAR"; then
        CAMINHO="$(perguntar "Caminho local da $DESC (ENTER para informar depois, na etapa 40)" '')"
        if [ -n "$CAMINHO" ] && [ ! -f "$CAMINHO" ]; then
            aviso "Arquivo não encontrado: $CAMINHO (ficará vazio; informe na etapa 40)."
            CAMINHO=""
        fi
        salvar_conf "$VAR" "$CAMINHO"
    fi
done

# ----------------------------------------------------------------------------
titulo "Resumo gravado em $CONF_ARQUIVO"
grep -vE '^\s*(#|$)' "$CONF_ARQUIVO" | sed 's/^/  /'
echo
ok "Detecção concluída. Revise o resumo acima antes de seguir para as próximas etapas."
info "VM_IP_FIXO e IP_FIXO_HOST são preenchidos na etapa 60 (rede em bridge)."
