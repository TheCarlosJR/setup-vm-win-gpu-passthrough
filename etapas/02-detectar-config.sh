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

verificar() {
    [ -f "$CONF_ARQUIVO" ] && v_ok "passthrough.conf existe." || v_falta "passthrough.conf não existe."
    local var
    for var in USUARIO_LINUX VM_NAME BOOTLOADER GPU_PCI_ID GPU_AUDIO_PCI_ID \
               GPU_VENDOR_DEVICE_ID GPU_AUDIO_VENDOR_DEVICE_ID UUID_HD2 \
               HD1_BY_ID_PATH CPUS_VM CPUS_HOST INTERFACE_FISICA DM_SERVICE; do
        if [ -n "${!var:-}" ]; then
            v_ok "$var=${!var}"
        else
            v_falta "$var ainda não definido."
        fi
    done
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

REDETECTAR=0
[ "${1:-}" = "--redetectar" ] && REDETECTAR=1

exigir_nao_root
exigir_sudo
exigir_comando lspci lsblk ip awk sed

# ja_definido VAR: retorna 0 se a variável já tem valor e não estamos redetectando
ja_definido() {
    [ "$REDETECTAR" -eq 0 ] && [ -n "${!1:-}" ]
}

titulo "Detecção de configuração (grava em $CONF_ARQUIVO)"
[ -f "$CONF_ARQUIVO" ] || { cp "$PROJETO_DIR/passthrough.conf.example" "$CONF_ARQUIVO"; info "Conf criado a partir do modelo."; }

# ----------------------------------------------------------------------------
# 1. Identidade
# ----------------------------------------------------------------------------
titulo "1/8 Identidade"
if ja_definido USUARIO_LINUX; then
    info "USUARIO_LINUX já definido: $USUARIO_LINUX"
else
    salvar_conf USUARIO_LINUX "$(perguntar 'Usuário Linux principal' "${USER}")"
fi
if ja_definido VM_NAME; then
    info "VM_NAME já definido: $VM_NAME"
else
    salvar_conf VM_NAME "$(perguntar 'Nome da VM no libvirt' 'win11')"
fi

# ----------------------------------------------------------------------------
# 2. Bootloader (Capítulo 15)
# ----------------------------------------------------------------------------
titulo "2/8 Bootloader (Capítulo 15)"
if ja_definido BOOTLOADER; then
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
if ja_definido GPU_PCI_ID && ja_definido GPU_VENDOR_DEVICE_ID; then
    info "GPU já definida: $GPU_PCI_ID [$GPU_VENDOR_DEVICE_ID] (use --redetectar para refazer)"
else
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
        LINHA_VGA="${LINHAS_VGA[$((ESCOLHA-1))]}"
    fi

    END_VGA="${LINHA_VGA%% *}"                                    # ex.: 0c:00.0
    ID_VGA="$(grep -oE '\[[0-9a-f]{4}:[0-9a-f]{4}\]' <<< "$LINHA_VGA" | tail -n1 | tr -d '[]')"

    BASE="${END_VGA%.*}"                                          # ex.: 0c:00
    LINHA_AUDIO="$(lspci -nn | grep -i nvidia | grep -i audio | grep "^${BASE}\." | head -n1 || true)"
    if [ -z "$LINHA_AUDIO" ]; then
        falhar "Função de áudio HDMI da GPU não encontrada em ${BASE}.x (esperada para a RTX 3060)."
    fi
    END_AUDIO="${LINHA_AUDIO%% *}"
    ID_AUDIO="$(grep -oE '\[[0-9a-f]{4}:[0-9a-f]{4}\]' <<< "$LINHA_AUDIO" | tail -n1 | tr -d '[]')"

    echo "Detectado no SEU hardware:"
    echo "  Vídeo: $LINHA_VGA"
    echo "  Áudio: $LINHA_AUDIO"
    confirmar "Confirmar estes dois dispositivos como a GPU do passthrough?" \
        || falhar "Cancelado. Rode novamente e escolha o dispositivo correto."

    salvar_conf GPU_PCI_ID "0000:${END_VGA}"
    salvar_conf GPU_AUDIO_PCI_ID "0000:${END_AUDIO}"
    salvar_conf GPU_VENDOR_DEVICE_ID "$ID_VGA"
    salvar_conf GPU_AUDIO_VENDOR_DEVICE_ID "$ID_AUDIO"
    ok "GPU: $GPU_PCI_ID [$GPU_VENDOR_DEVICE_ID] / áudio $GPU_AUDIO_PCI_ID [$GPU_AUDIO_VENDOR_DEVICE_ID]"
fi

# ----------------------------------------------------------------------------
# 4. Serviço gráfico (para os hooks do Capítulo 19)
# ----------------------------------------------------------------------------
titulo "4/8 Gerenciador de exibição"
if ja_definido DM_SERVICE; then
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
    info "NVME_DEVICE já definido: $NVME_DEVICE"
else
    mapfile -t NVMES < <(lsblk -dn -o NAME,TRAN | awk '$2=="nvme"{print "/dev/"$1}')
    case "${#NVMES[@]}" in
        0) aviso "Nenhum NVMe detectado; informe manualmente."
           salvar_conf NVME_DEVICE "$(perguntar 'Dispositivo do disco do sistema' '/dev/nvme0n1')" ;;
        1) ok "NVMe detectado: ${NVMES[0]}"
           salvar_conf NVME_DEVICE "${NVMES[0]}" ;;
        *) echo "Mais de um NVMe:"; printf '  %s\n' "${NVMES[@]}"
           salvar_conf NVME_DEVICE "$(perguntar 'Qual é o disco do SISTEMA?' "${NVMES[0]}")" ;;
    esac
fi

# 5b. HD2 (NTFS montado em /mnt/docs4) - identificado por UUID
if ja_definido UUID_HD2; then
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
    DEV_HD2="${NTFS_DEVS[$((ESCOLHA-1))]}"
    UUID_ESCOLHIDO="$(sudo blkid -s UUID -o value "$DEV_HD2")"
    confirmar "Confirmar HD2 = $DEV_HD2 (UUID=$UUID_ESCOLHIDO)?" || falhar "Cancelado."
    salvar_conf UUID_HD2 "$UUID_ESCOLHIDO"
    # guarda o disco-pai para a checagem de segurança do HD1
    HD2_DISCO_PAI="/dev/$(lsblk -no PKNAME "$DEV_HD2" | head -n1)"
    salvar_conf HD2_DISCO_PAI "$HD2_DISCO_PAI"
fi

# 5c. HD1 (disco inteiro da VM) - caminho estável by-id
if ja_definido HD1_BY_ID_PATH; then
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
    HD1="${BYIDS[$((ESCOLHA-1))]}"
    HD1_ALVO="$(readlink -f "$HD1")"

    # Segurança: HD1 não pode ser o NVMe do sistema nem o disco do HD2
    [ "$HD1_ALVO" = "${NVME_DEVICE:-}" ] && falhar "O caminho escolhido aponta para o NVMe do sistema. Abortado."
    if [ -n "${HD2_DISCO_PAI:-}" ] && [ "$HD1_ALVO" = "$HD2_DISCO_PAI" ]; then
        falhar "O caminho escolhido aponta para o disco do HD2. Abortado."
    fi
    confirmar "Confirmar HD1 = $HD1 ($HD1_ALVO)? Confira modelo/serial no inventário." || falhar "Cancelado."
    salvar_conf HD1_BY_ID_PATH "$HD1"
fi

# ----------------------------------------------------------------------------
# 6. CPU: topologia e pinning (Capítulo 21)
# ----------------------------------------------------------------------------
titulo "6/8 CPU (topologia real via lscpu -e)"
if ja_definido CPUS_VM && ja_definido CPUS_HOST; then
    info "Pinning já definido: VM=[$CPUS_VM] HOST=[$CPUS_HOST]"
else
    echo "Mapa lógico da CPU:"
    lscpu -e
    echo

    # Agrupa CPUs lógicas por núcleo físico
    declare -A NUCLEO_THREADS=()
    while read -r CPU CORE ONLINE; do
        [ "$ONLINE" = "yes" ] || continue
        NUCLEO_THREADS[$CORE]="${NUCLEO_THREADS[$CORE]:+${NUCLEO_THREADS[$CORE]},}$CPU"
    done < <(lscpu -e=CPU,CORE,ONLINE | tail -n +2)

    mapfile -t NUCLEOS < <(printf '%s\n' "${!NUCLEO_THREADS[@]}" | sort -n)
    TOTAL_NUCLEOS="${#NUCLEOS[@]}"
    THREADS_POR_NUCLEO="$(awk -F',' '{print NF}' <<< "${NUCLEO_THREADS[${NUCLEOS[0]}]}")"
    info "Detectados $TOTAL_NUCLEOS núcleos físicos, $THREADS_POR_NUCLEO thread(s) por núcleo."

    PADRAO_VM=6
    [ "$TOTAL_NUCLEOS" -le 4 ] && PADRAO_VM=$((TOTAL_NUCLEOS-1))
    NUC_VM="$(perguntar "Núcleos físicos dedicados à VM (o restante fica com o host)" "$PADRAO_VM")"
    if [ "$NUC_VM" -ge "$TOTAL_NUCLEOS" ]; then
        falhar "Reserve pelo menos 1 núcleo físico para o host (Capítulo 21)."
    fi

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

    echo "Proposta de alocação (mesma estratégia do Capítulo 21):"
    echo "  VM   ($NUC_VM núcleos, $VCPUS_TOTAL vCPUs): $LISTA_VM"
    echo "  HOST ($((TOTAL_NUCLEOS-NUC_VM)) núcleos):            $LISTA_HOST"
    confirmar "Confirmar este mapa?" || falhar "Cancelado. Rode novamente e ajuste."

    salvar_conf CPUS_VM "$LISTA_VM"
    salvar_conf CPUS_HOST "$LISTA_HOST"
    salvar_conf VM_CORES "$NUC_VM"
    salvar_conf VM_THREADS "$THREADS_POR_NUCLEO"
    salvar_conf VM_VCPUS "$VCPUS_TOTAL"
fi

# ----------------------------------------------------------------------------
# 7. Memória da VM e HugePages (Capítulo 21)
# ----------------------------------------------------------------------------
titulo "7/8 Memória da VM"
if ja_definido VM_RAM_MB && [ "$REDETECTAR" -eq 0 ]; then
    info "VM_RAM_MB já definido: $VM_RAM_MB"
else
    RAM_TOTAL_MB="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)"
    info "RAM total do host: ${RAM_TOTAL_MB} MiB"
    RAM_VM="$(perguntar 'RAM da VM em MiB (múltiplo de 1024)' '16384')"
    salvar_conf VM_RAM_MB "$RAM_VM"
fi
salvar_conf HUGEPAGES_1G "$((VM_RAM_MB / 1024))"
[ $((VM_RAM_MB % 1024)) -ne 0 ] && aviso "VM_RAM_MB não é múltiplo de 1024: ajuste antes da etapa 52 (HugePages de 1 GiB)."

# ----------------------------------------------------------------------------
# 8. Rede e demais valores
# ----------------------------------------------------------------------------
titulo "8/8 Rede e complementos"
if ja_definido INTERFACE_FISICA; then
    info "INTERFACE_FISICA já definida: $INTERFACE_FISICA"
else
    echo "Interfaces de rede:"
    ip -o link show | awk -F': ' '{print "  - "$2}'
    mapfile -t ETHS < <(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(en|eth)' || true)
    PADRAO_IF="${ETHS[0]:-}"
    aviso "Use a interface Ethernet CABEADA (bridge sobre Wi-Fi não é coberta pelo manual)."
    salvar_conf INTERFACE_FISICA "$(perguntar 'Interface física para a bridge' "$PADRAO_IF")"
fi

if ! ja_definido TRANSFER_USER; then
    salvar_conf TRANSFER_USER "$(perguntar 'Usuário de transferência do airlock' 'vmtransfer')"
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
