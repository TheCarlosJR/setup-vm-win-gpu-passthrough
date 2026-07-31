#!/bin/bash
# ============================================================================
# util/recuperar-gpu.sh - Capítulo 29, cenário 1
# ============================================================================
# Recupera GPU e áudio depois que a VM já desligou, quando o hook release/end
# não concluiu. O utilitário compartilha o lock dos hooks e só altera sysfs
# após confirmar que a VM está exatamente "shut off" e que os BDFs ainda
# correspondem ao hardware configurado.
# ============================================================================
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

exigir_nao_root
exigir_sudo
exigir_comando virsh flock modprobe systemctl nvidia-smi
exigir_conf VM_NAME GPU_PCI_ID GPU_AUDIO_PCI_ID GPU_VENDOR_DEVICE_ID \
            GPU_AUDIO_VENDOR_DEVICE_ID DM_SERVICE

[[ "$VM_NAME" =~ ^[A-Za-z0-9_.-]+$ ]] \
    || falhar "VM_NAME contém caracteres inseguros."
[[ "$DM_SERVICE" =~ ^[A-Za-z0-9_.@-]+$ ]] \
    || falhar "DM_SERVICE contém caracteres inseguros."
[[ "$GPU_PCI_ID" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]] \
    || falhar "GPU_PCI_ID inválido."
[[ "$GPU_AUDIO_PCI_ID" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]] \
    || falhar "GPU_AUDIO_PCI_ID inválido."
[[ "$GPU_VENDOR_DEVICE_ID" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]] \
    || falhar "GPU_VENDOR_DEVICE_ID inválido."
[[ "$GPU_AUDIO_VENDOR_DEVICE_ID" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]] \
    || falhar "GPU_AUDIO_VENDOR_DEVICE_ID inválido."
[ "$GPU_PCI_ID" != "$GPU_AUDIO_PCI_ID" ] \
    || falhar "GPU e áudio não podem usar o mesmo BDF."

current_driver() {
    local bdf="$1"
    if [ -L "/sys/bus/pci/devices/$bdf/driver" ]; then
        basename "$(readlink -f "/sys/bus/pci/devices/$bdf/driver")"
    else
        printf 'none\n'
    fi
}

device_matches() {
    local bdf="$1" expected_id="$2" kind="$3" vendor device class
    [ -d "/sys/bus/pci/devices/$bdf" ] || return 1
    vendor="$(<"/sys/bus/pci/devices/$bdf/vendor")" || return 1
    device="$(<"/sys/bus/pci/devices/$bdf/device")" || return 1
    class="$(<"/sys/bus/pci/devices/$bdf/class")" || return 1
    [ "${vendor#0x}:${device#0x}" = "${expected_id,,}" ] || return 1
    if [ "$kind" = "video" ]; then
        [[ "${class#0x}" =~ ^03(00|02) ]]
    else
        [[ "${class#0x}" =~ ^0403 ]]
    fi
}

validar_par_gpu() {
    local grupo_video grupo_audio
    device_matches "$GPU_PCI_ID" "$GPU_VENDOR_DEVICE_ID" video || return 1
    device_matches "$GPU_AUDIO_PCI_ID" "$GPU_AUDIO_VENDOR_DEVICE_ID" audio || return 1
    grupo_video="$(readlink -f "/sys/bus/pci/devices/$GPU_PCI_ID/iommu_group")" || return 1
    grupo_audio="$(readlink -f "/sys/bus/pci/devices/$GPU_AUDIO_PCI_ID/iommu_group")" || return 1
    [ -n "$grupo_video" ] && [ "$grupo_video" = "$grupo_audio" ]
}

validar_driver_inicial() {
    local bdf="$1" esperado="$2" atual
    atual="$(current_driver "$bdf")"
    case "$atual" in
        vfio-pci|none|"$esperado")
            info "$bdf está com o driver: $atual"
            ;;
        *)
            erro "$bdf está com driver inesperado '$atual'; nenhuma alteração foi feita."
            return 1
            ;;
    esac
}

GPU_LOCK_FILE="/run/lock/vm-passthrough-gpu.lock"
id -nG | grep -qw libvirt \
    || falhar "A sessão atual não possui o grupo libvirt; faça logout/login após a etapa 21."
sudo touch "$GPU_LOCK_FILE"
sudo chown root:libvirt "$GPU_LOCK_FILE"
sudo chmod 0660 "$GPU_LOCK_FILE"
exec 9>"$GPU_LOCK_FILE"
flock -w 30 9 \
    || falhar "Outra troca ou recuperação de GPU está em andamento."

titulo "Recuperação de emergência da GPU (Capítulo 29, cenário 1)"

if ! ESTADO="$(LC_ALL=C $VIRSH domstate "$VM_NAME" 2>/dev/null)"; then
    falhar "Não foi possível consultar o estado da VM '$VM_NAME'; sysfs não será alterado."
fi
info "Estado da VM $VM_NAME: $ESTADO"
[ "$ESTADO" = "shut off" ] \
    || falhar "A VM precisa estar exatamente 'shut off'; sysfs não será alterado."

validar_par_gpu \
    || falhar "Os BDFs não correspondem aos IDs, classes ou grupo IOMMU configurados."
validar_driver_inicial "$GPU_PCI_ID" nvidia \
    || falhar "Recuperação abortada antes de qualquer escrita em sysfs."
validar_driver_inicial "$GPU_AUDIO_PCI_ID" snd_hda_intel \
    || falhar "Recuperação abortada antes de qualquer escrita em sysfs."

STATUS=0
info "1) Retirando somente dispositivos ainda vinculados ao vfio-pci..."
for DISPOSITIVO in "$GPU_PCI_ID" "$GPU_AUDIO_PCI_ID"; do
    if [ "$(current_driver "$DISPOSITIVO")" = "vfio-pci" ]; then
        if printf '%s' "$DISPOSITIVO" | sudo tee \
            "/sys/bus/pci/devices/$DISPOSITIVO/driver/unbind" >/dev/null; then
            ok "   $DISPOSITIVO desvinculado do vfio-pci."
        else
            erro "   Falha ao desvincular $DISPOSITIVO do vfio-pci."
            STATUS=1
        fi
    else
        info "   $DISPOSITIVO não está no vfio-pci; unbind ignorado."
    fi
done

info "2) Limpando driver_override..."
for DISPOSITIVO in "$GPU_PCI_ID" "$GPU_AUDIO_PCI_ID"; do
    if printf '\n' | sudo tee "/sys/bus/pci/devices/$DISPOSITIVO/driver_override" >/dev/null; then
        ok "   override limpo para $DISPOSITIVO."
    else
        erro "   Falha ao limpar override de $DISPOSITIVO."
        STATUS=1
    fi
done

info "3) Carregando os drivers Linux..."
for MODULO in nvidia nvidia_modeset nvidia_drm nvidia_uvm snd_hda_intel; do
    if sudo modprobe "$MODULO"; then
        ok "   modprobe $MODULO"
    else
        erro "   modprobe $MODULO falhou."
        STATUS=1
    fi
done

info "4) Reprovando GPU e áudio que permaneceram sem driver..."
for DISPOSITIVO in "$GPU_PCI_ID" "$GPU_AUDIO_PCI_ID"; do
    if [ "$(current_driver "$DISPOSITIVO")" = "none" ]; then
        if printf '%s' "$DISPOSITIVO" | sudo tee /sys/bus/pci/drivers_probe >/dev/null; then
            ok "   probe solicitado para $DISPOSITIVO."
        else
            erro "   Falha no probe de $DISPOSITIVO."
            STATUS=1
        fi
    else
        info "   $DISPOSITIVO já possui driver; probe desnecessário."
    fi
done

info "5) Validando drivers e NVIDIA..."
[ "$(current_driver "$GPU_PCI_ID")" = "nvidia" ] \
    || { erro "   A GPU não retornou ao driver nvidia."; STATUS=1; }
[ "$(current_driver "$GPU_AUDIO_PCI_ID")" = "snd_hda_intel" ] \
    || { erro "   O áudio não retornou ao snd_hda_intel."; STATUS=1; }
if nvidia-smi -L >/dev/null 2>&1; then
    ok "   nvidia-smi reconheceu a GPU."
else
    erro "   nvidia-smi ainda falha (possível reset bug, Capítulo 28)."
    STATUS=1
fi

if [ "$STATUS" -eq 0 ]; then
    info "6) Religando o gerenciador de exibição ($DM_SERVICE)..."
    if sudo systemctl start "$DM_SERVICE"; then
        ok "   $DM_SERVICE iniciado; a sessão gráfica deve retornar."
        sudo rm -rf -- "/run/vm-passthrough/$VM_NAME"
    else
        erro "   Falha ao iniciar $DM_SERVICE."
        STATUS=1
    fi
else
    aviso "O display manager não será iniciado enquanto a GPU não estiver validada."
fi

echo
if [ "$STATUS" -eq 0 ]; then
    ok "Recuperação concluída com GPU e áudio validados."
else
    aviso "Recuperação incompleta. Contingência segura do manual: sudo reboot"
fi
exit "$STATUS"
