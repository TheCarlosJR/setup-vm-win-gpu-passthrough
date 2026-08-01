#!/bin/bash
# ============================================================================
# util/recuperar-gpu.sh - Capítulo 29, cenário 1
# ============================================================================
# Para quando a VM desligou e o Linux NÃO recuperou o vídeo (hook release
# falhou). Rode a partir do TTY de texto: Ctrl+Alt+F3, login, e:
#     bash util/recuperar-gpu.sh
# Faz manualmente o caminho do hook release: desvincula do vfio-pci,
# recarrega o driver nvidia e religa o gerenciador de exibição.
# ============================================================================
set -uo pipefail   # SEM -e de propósito: cada passo tolera falha e reporta
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf
exigir_nao_root
exigir_sudo

DM="${DM_SERVICE:-display-manager}"
titulo "Recuperação de emergência da GPU (Capítulo 29, cenário 1)"

if [ -n "${VM_NAME:-}" ]; then
    ESTADO="$($VIRSH domstate "$VM_NAME" 2>/dev/null || echo desconhecido)"
    info "Estado da VM $VM_NAME: $ESTADO"
    [ "$ESTADO" = "running" ] && aviso "A VM ainda está LIGADA; a GPU pertence a ela. Desligue-a antes."
fi

if [ -n "${GPU_PCI_ID:-}" ]; then
    info "1) Desvinculando GPU/áudio do driver atual (se houver)..."
    # Lista sem aspas de propósito: se não há áudio HDMI, o valor vazio desaparece
    for DISPOSITIVO in $GPU_PCI_ID ${GPU_AUDIO_PCI_ID:-}; do
        if [ -e "/sys/bus/pci/devices/$DISPOSITIVO/driver" ]; then
            DRIVER_ATUAL="$(basename "$(readlink -f "/sys/bus/pci/devices/$DISPOSITIVO/driver")")"
            info "   $DISPOSITIVO está com o driver: $DRIVER_ATUAL"
            echo "$DISPOSITIVO" | sudo tee "/sys/bus/pci/devices/$DISPOSITIVO/driver/unbind" >/dev/null \
                && ok "   unbind de $DISPOSITIVO" \
                || aviso "   unbind falhou em $DISPOSITIVO"
        else
            info "   $DISPOSITIVO sem driver vinculado."
        fi
    done
else
    aviso "GPU_PCI_ID ausente no conf; pulando unbind direcionado."
fi

info "2) Recarregando os módulos NVIDIA (ordem de dependência)..."
for MODULO in nvidia nvidia_modeset nvidia_drm nvidia_uvm; do
    if sudo modprobe "$MODULO"; then
        ok "   modprobe $MODULO"
    else
        aviso "   modprobe $MODULO FALHOU"
    fi
done

info "3) Testando o driver..."
if nvidia-smi >/dev/null 2>&1; then
    ok "   nvidia-smi respondeu; GPU de volta ao Linux."
else
    aviso "   nvidia-smi ainda falha (possível 'reset bug', Capítulo 28)."
fi

info "4) Religando o gerenciador de exibição ($DM)..."
if sudo systemctl start "$DM"; then
    ok "   $DM iniciado; a sessão gráfica deve voltar no monitor."
else
    aviso "   Falha ao iniciar $DM."
fi

echo
if nvidia-smi >/dev/null 2>&1; then
    ok "Recuperação concluída."
else
    aviso "Não recuperou. Próximo passo SEMPRE válido e seguro (manual): sudo reboot"
    aviso "(o power cycle reseta a GPU por completo e resolve estados inconsistentes)."
fi
