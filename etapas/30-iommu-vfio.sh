#!/bin/bash
# ============================================================================
# etapas/30-iommu-vfio.sh - Capítulo 16: IOMMU e VFIO
# ============================================================================
# Duas fases automáticas (o script percebe sozinho em qual está):
#   Fase A (antes do reboot): aplica amd_iommu=on iommu=pt pelo bootloader
#     correto, cria /etc/modules-load.d/vfio.conf e regenera o initramfs.
#   Fase B (após o reboot): valida cmdline, mensagens AMD-Vi, módulos vfio,
#     lista o grupo IOMMU da GPU, alerta sobre dispositivos estranhos no
#     grupo e grava IOMMU_GROUP_GPU no passthrough.conf.
#
# Fiel ao manual: a GPU NÃO é presa ao vfio-pci no boot (GPU única!);
# a vinculação é dinâmica, feita pelos hooks da etapa 50.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

verificar() {
    if cmdline_tem "amd_iommu=on" && cmdline_tem "iommu=pt"; then
        v_ok "Parâmetros amd_iommu=on iommu=pt ativos no kernel em execução."
    else
        v_falta "Parâmetros de IOMMU ausentes no /proc/cmdline."
    fi
    if [ -f /etc/modules-load.d/vfio.conf ]; then
        v_ok "/etc/modules-load.d/vfio.conf presente."
    else
        v_falta "/etc/modules-load.d/vfio.conf ausente."
    fi
    if lsmod | grep -q '^vfio_pci'; then
        v_ok "Módulo vfio_pci carregado."
    else
        v_falta "Módulo vfio_pci não carregado."
    fi
    if ls /sys/kernel/iommu_groups/ 2>/dev/null | grep -q .; then
        v_ok "Grupos IOMMU populados."
    else
        v_falta "Grupos IOMMU vazios (IOMMU inativo)."
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

exigir_nao_root
exigir_sudo
exigir_conf BOOTLOADER GPU_PCI_ID GPU_AUDIO_PCI_ID

titulo "Capítulo 16: IOMMU e VFIO"

# ----------------------------------------------------------------------------
# Fase A: configuração (só roda se os parâmetros ainda não estão ativos)
# ----------------------------------------------------------------------------
if ! cmdline_tem "amd_iommu=on" || ! cmdline_tem "iommu=pt"; then
    titulo "Fase A: aplicar parâmetros de kernel e módulos VFIO"

    info "Aplicando amd_iommu=on iommu=pt via $BOOTLOADER..."
    kernel_param_add "amd_iommu=on iommu=pt"

    info "Configurando carga automática dos módulos VFIO..."
    sudo tee /etc/modules-load.d/vfio.conf >/dev/null <<'MODULOS'
vfio
vfio_pci
vfio_iommu_type1
MODULOS

    info "Regenerando initramfs para todos os kernels instalados..."
    sudo update-initramfs -u -k all

    echo
    ok "Fase A concluída."
    info "Reversão (Capítulo 16, 'Como desfazer'):"
    if [ "$BOOTLOADER" = "kernelstub" ]; then
        info "  sudo kernelstub -d \"amd_iommu=on iommu=pt\""
    else
        info "  restaurar /etc/default/grub.bak-<data> e rodar sudo update-grub"
    fi
    info "  sudo rm /etc/modules-load.d/vfio.conf && sudo update-initramfs -u -k all"
    pedir_reboot
    exit 0
fi

# ----------------------------------------------------------------------------
# Fase B: validação pós-reboot
# ----------------------------------------------------------------------------
titulo "Fase B: validação pós-reboot"

info "1) /proc/cmdline:"
cat /proc/cmdline
cmdline_tem "amd_iommu=on" && ok "amd_iommu=on ativo." || falhar "amd_iommu=on ausente."

info "2) Mensagens do kernel (AMD-Vi):"
if sudo dmesg | grep -i "AMD-Vi" | head -n 10 | grep -q .; then
    sudo dmesg | grep -i "AMD-Vi" | head -n 10
    ok "AMD-Vi reportado pelo kernel."
else
    aviso "Nenhuma mensagem AMD-Vi: confirme IOMMU=Enabled na BIOS (etapa 01)."
fi

info "3) Módulos VFIO:"
if lsmod | grep -E '^vfio(_pci|_iommu_type1)?' ; then
    ok "Módulos vfio carregados."
else
    falhar "Módulos vfio ausentes. Verifique /etc/modules-load.d/vfio.conf e rode: sudo modprobe vfio_pci"
fi

info "4) Grupo IOMMU da GPU:"
LINK_GRUPO="/sys/bus/pci/devices/${GPU_PCI_ID}/iommu_group"
[ -e "$LINK_GRUPO" ] || falhar "Dispositivo $GPU_PCI_ID sem grupo IOMMU (IOMMU realmente ativo?)."
GRUPO="$(basename "$(readlink -f "$LINK_GRUPO")")"
ok "GPU ($GPU_PCI_ID) no grupo IOMMU $GRUPO. Conteúdo do grupo:"

PROBLEMA=0
for DEV in "/sys/kernel/iommu_groups/$GRUPO/devices/"*; do
    END="$(basename "$DEV")"
    DESCRICAO="$(lspci -nns "${END#0000:}")"
    echo "   $DESCRICAO"
    if [ "$END" != "$GPU_PCI_ID" ] && [ "$END" != "$GPU_AUDIO_PCI_ID" ]; then
        # Bridges PCI (pcieport) no grupo são normais e não impedem passthrough
        if ! grep -qi "bridge" <<< "$DESCRICAO"; then
            PROBLEMA=1
        fi
    fi
done
if [ "$PROBLEMA" -eq 1 ]; then
    aviso "Há dispositivo(s) NÃO relacionados à GPU no grupo $GRUPO."
    aviso "Consulte o Capítulo 28 (outro slot físico, atualização de BIOS, ACS override como último recurso)."
else
    ok "Grupo limpo: apenas GPU + áudio (bridges são inofensivas)."
fi

salvar_conf IOMMU_GROUP_GPU "$GRUPO"
info "IOMMU_GROUP_GPU=$GRUPO gravado no passthrough.conf."

info "5) Listagem completa dos grupos (registro em ~/inventario-hardware/):"
mkdir -p "$HOME/inventario-hardware"
bash "$PROJETO_DIR/util/listar-grupos-iommu.sh" | tee "$HOME/inventario-hardware/grupos-iommu-$(date +%Y%m%d).txt" | tail -n 5
info "(arquivo completo salvo; acima só as últimas linhas)"

echo
ok "Capítulo 16 concluído. GPU pronta para vinculação DINÂMICA na etapa 50."
