#!/bin/bash
# ============================================================================
# util/recuperar-gpu.sh - recuperação emergencial da GPU após release falho
# ============================================================================
# Uso:
#   recuperar-gpu.sh
#   recuperar-gpu.sh --assumir-dm-ativo  # somente sem state file e após revisão
# Exige a VM comprovadamente desligada, valida o grupo/identidade PCI e recusa
# drivers inesperados antes de tentar reattach/probe e restaurar o display.
# ============================================================================
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf
exigir_nao_root
exigir_sudo
exigir_comando virsh modprobe systemctl flock
exigir_conf VM_NAME GPU_PCI_ID GPU_VENDOR_DEVICE_ID DM_SERVICE IOMMU_GROUP_GPU
nome_vm_valido "$VM_NAME" || falhar "VM_NAME inválido: '$VM_NAME'."
pci_bdf_valido "$GPU_PCI_ID" || falhar "GPU_PCI_ID inválido: '$GPU_PCI_ID'."
pci_vendor_device_valido "$GPU_VENDOR_DEVICE_ID" || falhar "GPU_VENDOR_DEVICE_ID inválido."
inteiro_na_faixa "$IOMMU_GROUP_GPU" 0 65535 || falhar "IOMMU_GROUP_GPU inválido."
nome_unidade_systemd_valido "$DM_SERVICE" || falhar "DM_SERVICE inválido: '$DM_SERVICE'."
if [ -n "${GPU_AUDIO_PCI_ID:-}" ]; then
    pci_bdf_valido "$GPU_AUDIO_PCI_ID" || falhar "GPU_AUDIO_PCI_ID inválido."
    exigir_conf GPU_AUDIO_VENDOR_DEVICE_ID
    pci_vendor_device_valido "$GPU_AUDIO_VENDOR_DEVICE_ID" || falhar "GPU_AUDIO_VENDOR_DEVICE_ID inválido."
fi

DM="$DM_SERVICE"
STATE_FILE="/run/libvirt-gpu-passthrough/${VM_NAME}.state"
LOCK_DIR="/run/libvirt-gpu-locks"
LOCK_FILE="$LOCK_DIR/${VM_NAME}.lock"
titulo "Recuperação de emergência da GPU"
info "Finalidade: devolver GPU e áudio do vfio-pci ao host e restaurar o estado anterior do display manager após falha de release."
info "Pré-requisitos: VM exatamente 'shut off', sudo, configuração PCI/IOMMU correta e acesso por TTY ou SSH."
aviso "Efeito/risco: carrega módulos, reanexa ou solicita reprobe dos dispositivos, pode iniciar '$DM' e remover o state file no sucesso."
aviso "A tela pode piscar, apagar ou permanecer sem sessão enquanto a GPU e o display manager são recuperados; salve seu trabalho antes."
info "Recomendação: use --assumir-dm-ativo só sem state file, após confirmar que '$DM' deveria estar ativo."
info "Não abrange: recuperar a sessão gráfica anterior, reset físico/power cycle da GPU, corrigir configuração da VM ou restaurar HD1."
info "Retorno/reboot: 0 só após drivers, nvidia-smi e estado do display serem confirmados; falhas retornam 1. Não reinicia automaticamente."
info "Journals para triagem em outro TTY/SSH:"
printf '  sudo journalctl -t hook-qemu -b --no-pager\n'
printf '  sudo journalctl -u libvirtd -b -e --no-pager\n'
printf '  sudo journalctl -u %q -b -e --no-pager\n' "$DM"
sudo install -d -o root -g root -m 0755 "$LOCK_DIR" \
    || falhar "Não foi possível preparar $LOCK_DIR."
sudo test ! -L "$LOCK_FILE" || falhar "Lock inseguro (link simbólico): $LOCK_FILE"
sudo touch "$LOCK_FILE" || falhar "Não foi possível criar o lock de recuperação."
sudo chown root:root "$LOCK_FILE" && sudo chmod 0666 "$LOCK_FILE" \
    || falhar "Não foi possível proteger o lock de recuperação."
sudo test -f "$LOCK_FILE" && [ "$(sudo stat -c %u "$LOCK_FILE")" -eq 0 ] \
    || falhar "Lock de recuperação não é arquivo regular pertencente ao root."
exec 9>"$LOCK_FILE" || falhar "Não foi possível abrir o lock de recuperação: $LOCK_FILE"
flock -n 9 || falhar "Outra operação de GPU/start está em andamento; recuperação cancelada."

exigir_vm_realmente_desligada() {
    local estado
    $VIRSH dominfo "$VM_NAME" >/dev/null 2>&1 \
        || falhar "A VM '$VM_NAME' não existe ou o libvirt não respondeu; não é possível provar que a GPU está livre."
    estado="$(LC_ALL=C $VIRSH domstate "$VM_NAME" 2>/dev/null)" \
        || falhar "Não foi possível consultar o estado da VM '$VM_NAME'."
    [ "$estado" = "shut off" ] \
        || falhar "BLOQUEADO: a VM precisa estar exatamente 'shut off'; estado atual: '$estado'. Nenhum driver foi tocado."
    info "Estado da VM $VM_NAME comprovado: $estado."
}

exigir_vm_realmente_desligada
validar_grupo_iommu_gpu \
    "$GPU_PCI_ID" "${GPU_AUDIO_PCI_ID:-}" "$IOMMU_GROUP_GPU" \
    "$GPU_VENDOR_DEVICE_ID" "${GPU_AUDIO_VENDOR_DEVICE_ID:-}" \
    || falhar "$IOMMU_ERRO"

DM_WAS_ACTIVE_RECUPERACAO=1
BASELINE_DM="estado persistido"
if sudo test -f "$STATE_FILE"; then
    ESTADO_HOOK="$(sudo cat -- "$STATE_FILE")" || falhar "Não foi possível ler $STATE_FILE."
    DM_WAS_ACTIVE_RECUPERACAO=""
    while IFS='=' read -r CHAVE_ESTADO VALOR_ESTADO; do
        case "$CHAVE_ESTADO" in
            DM_WAS_ACTIVE) DM_WAS_ACTIVE_RECUPERACAO="$VALOR_ESTADO" ;;
            GPU_DRIVER|AUDIO_DRIVER|HD1_ALVO|HD1_DEVNO|HD1_IDENTIDADE) : ;;
            *) falhar "Chave desconhecida no estado de recuperação: $CHAVE_ESTADO" ;;
        esac
    done <<< "$ESTADO_HOOK"
    [[ "$DM_WAS_ACTIVE_RECUPERACAO" =~ ^[01]$ ]] \
        || falhar "DM_WAS_ACTIVE inválido no estado de recuperação."
else
    [ "${1:-}" = "--assumir-dm-ativo" ] \
        || falhar "Estado do hook ausente; não há baseline do display manager. Se você verificou que ele deve voltar ativo, reexecute com --assumir-dm-ativo."
    confirmar_digitando ASSUMIR "Sem state file, o script não pode provar o estado anterior do display manager; você está escolhendo restaurá-lo como ATIVO." \
        || falhar "Override de baseline cancelado."
    BASELINE_DM="override explícito --assumir-dm-ativo"
fi

DISPOSITIVOS=("${GPU_PCI_ID,,}")
ESPERADOS=(nvidia)
if [ -n "${GPU_AUDIO_PCI_ID:-}" ]; then
    DISPOSITIVOS+=("${GPU_AUDIO_PCI_ID,,}")
    ESPERADOS+=(snd_hda_intel)
fi

driver_atual() {
    local bdf="$1"
    if [ -L "/sys/bus/pci/devices/$bdf/driver" ]; then
        basename -- "$(readlink -f -- "/sys/bus/pci/devices/$bdf/driver")"
    else
        printf '%s\n' sem_driver
    fi
}

# Pré-checagem sem efeitos: driver inesperado bloqueia antes de qualquer ação.
for i in "${!DISPOSITIVOS[@]}"; do
    BDF="${DISPOSITIVOS[$i]}"
    ESPERADO="${ESPERADOS[$i]}"
    [ -d "/sys/bus/pci/devices/$BDF" ] || falhar "Dispositivo PCI ausente: $BDF."
    ATUAL="$(driver_atual "$BDF")"
    info "$BDF: driver atual '$ATUAL', esperado '$ESPERADO'."
    case "$ATUAL" in
        "$ESPERADO"|vfio-pci|sem_driver) : ;;
        *) falhar "Driver inesperado '$ATUAL' em $BDF; recusando unbind automático." ;;
    esac
done

# Fecha a janela entre a inspeção e a primeira mutação. O lock também impede
# que o prepare/begin deste projeto concorra com a recuperação.
exigir_vm_realmente_desligada
validar_grupo_iommu_gpu \
    "$GPU_PCI_ID" "${GPU_AUDIO_PCI_ID:-}" "$IOMMU_GROUP_GPU" \
    "$GPU_VENDOR_DEVICE_ID" "${GPU_AUDIO_VENDOR_DEVICE_ID:-}" \
    || falhar "$IOMMU_ERRO"

FALHAS=0
info "1) Carregando módulos do host sem desvincular dispositivos saudáveis..."
for MODULO in nvidia nvidia_modeset nvidia_drm nvidia_uvm; do
    if sudo modprobe "$MODULO"; then
        ok "   modprobe $MODULO"
    else
        erro "   modprobe $MODULO falhou"
        FALHAS=$((FALHAS + 1))
    fi
done
if [ -n "${GPU_AUDIO_PCI_ID:-}" ]; then
    if ! sudo modprobe snd_hda_intel; then
        erro "   modprobe snd_hda_intel falhou"
        FALHAS=$((FALHAS + 1))
    fi
fi

info "2) Solicitando reattach/probe somente quando necessário..."
for i in "${!DISPOSITIVOS[@]}"; do
    BDF="${DISPOSITIVOS[$i]}"
    ATUAL="$(driver_atual "$BDF")"
    if [ "$ATUAL" = vfio-pci ]; then
        NODEDEV="pci_${BDF//:/_}"
        NODEDEV="${NODEDEV//./_}"
        if $VIRSH nodedev-reattach "$NODEDEV"; then
            ok "   libvirt reanexou $BDF ao host."
        else
            erro "   nodedev-reattach falhou para $BDF; nenhum unbind sysfs alternativo foi tentado."
            FALHAS=$((FALHAS + 1))
        fi
    elif [ "$ATUAL" = sem_driver ]; then
        if printf '%s\n' "$BDF" | sudo tee /sys/bus/pci/drivers_probe >/dev/null; then
            ok "   reprobe solicitado para $BDF."
        else
            erro "   reprobe falhou para $BDF."
            FALHAS=$((FALHAS + 1))
        fi
    else
        info "   $BDF já está em $ATUAL; preservado sem unbind."
    fi
done

aguardar_driver() {
    local bdf="$1" esperado="$2" tentativa
    for ((tentativa=0; tentativa<20; tentativa++)); do
        [ "$(driver_atual "$bdf")" = "$esperado" ] && return 0
        sleep 1
    done
    return 1
}

info "3) Validando os drivers finais..."
for i in "${!DISPOSITIVOS[@]}"; do
    BDF="${DISPOSITIVOS[$i]}"
    ESPERADO="${ESPERADOS[$i]}"
    if aguardar_driver "$BDF" "$ESPERADO"; then
        ok "   $BDF confirmado em $ESPERADO."
    else
        erro "   $BDF não retornou a $ESPERADO (atual: $(driver_atual "$BDF"))."
        FALHAS=$((FALHAS + 1))
    fi
done
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    ok "   nvidia-smi respondeu."
else
    erro "   nvidia-smi não respondeu."
    FALHAS=$((FALHAS + 1))
fi

info "4) Restaurando o estado original do gerenciador de exibição ($DM)..."
if [ "$DM_WAS_ACTIVE_RECUPERACAO" -eq 1 ]; then
    if sudo systemctl start "$DM" && sudo systemctl is-active --quiet "$DM"; then
        ok "   $DM está ativo como antes do passthrough."
    else
        erro "   $DM não pôde ser confirmado como ativo."
        FALHAS=$((FALHAS + 1))
    fi
else
    DM_ESTADO_FINAL="$(sudo systemctl show -p ActiveState --value "$DM" 2>/dev/null)"
    if [ "$DM_ESTADO_FINAL" = inactive ]; then
        ok "   $DM permaneceu inativo, preservando o estado anterior."
    else
        erro "   $DM deveria permanecer inativo, mas está '$DM_ESTADO_FINAL'."
        FALHAS=$((FALHAS + 1))
    fi
fi

echo
if [ "$FALHAS" -eq 0 ]; then
    if sudo test -e "$STATE_FILE"; then
        sudo rm -f -- "$STATE_FILE" \
            || { erro "A GPU voltou, mas o estado obsoleto não pôde ser removido: $STATE_FILE"; exit 1; }
    fi
    ok "Recuperação concluída com driver, nvidia-smi e display manager verificados (baseline: $BASELINE_DM)."
    exit 0
fi
erro "Recuperação terminou com $FALHAS falha(s); não foi declarado sucesso."
aviso "Próximo caminho seguro: revisar o journal pelo TTY e, se necessário, reiniciar o host."
exit 1
