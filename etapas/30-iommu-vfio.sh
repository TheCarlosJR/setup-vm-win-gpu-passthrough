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

CPU_SUPORTE_ERRO=""
validar_cpu_amd_suportada() {
    CPU_SUPORTE_ERRO=""
    plataforma_validar_cpu_amd \
        || { CPU_SUPORTE_ERRO="$PLATAFORMA_ERRO"; return 1; }
}

verificar() {
    if ! plataforma_carregar; then
        v_erro "$PLATAFORMA_ERRO"
        v_fim
    fi
    if validar_cpu_amd_suportada; then
        v_ok "CPU AMD suportada por esta implementação: $PLATAFORMA_CPU_VENDOR."
    else
        v_erro "$CPU_SUPORTE_ERRO"
        v_fim
    fi
    if validar_bootloader_configurado; then
        v_ok "Boot persistido coincide com o efetivo: $BOOTLOADER_ATIVO."
    else
        v_erro "$BOOTLOADER_VALIDACAO_ERRO"
    fi
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
    if [ -z "${GPU_PCI_ID:-}" ]; then
        v_falta "GPU_PCI_ID não definido; não é possível validar o grupo da GPU específica."
    elif [ -z "${IOMMU_GROUP_GPU:-}" ]; then
        v_falta "IOMMU_GROUP_GPU ainda não foi persistido pela fase B."
    elif [ -n "${GPU_AUDIO_PCI_ID:-}" ] && [ -z "${GPU_AUDIO_VENDOR_DEVICE_ID:-}" ]; then
        v_falta "GPU_AUDIO_PCI_ID existe, mas seu vendor/device não foi persistido."
    elif validar_grupo_iommu_gpu \
            "$GPU_PCI_ID" "${GPU_AUDIO_PCI_ID:-}" "$IOMMU_GROUP_GPU" \
            "${GPU_VENDOR_DEVICE_ID:-}" "${GPU_AUDIO_VENDOR_DEVICE_ID:-}"; then
        v_ok "GPU, áudio e bridges autorizadas formam exatamente o grupo IOMMU $IOMMU_GRUPO_ATUAL."
    else
        v_falta "$IOMMU_ERRO"
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

exigir_plataforma_suportada
validar_cpu_amd_suportada || falhar "$CPU_SUPORTE_ERRO"
# LIM-001: o bloqueio ocorre antes de sudo, escrita de configuração ou qualquer
# mutação de boot/initramfs. Não se aplicam parâmetros AMD a Intel.
exigir_nao_root
exigir_conf BOOTLOADER GPU_PCI_ID GPU_VENDOR_DEVICE_ID
exigir_bootloader_coerente
if [ -n "${GPU_AUDIO_PCI_ID:-}" ]; then
    exigir_conf GPU_AUDIO_VENDOR_DEVICE_ID
fi

titulo "Antes de continuar"
info "Objetivo: habilitar IOMMU/VFIO no host AMD e validar que o grupo PCI da GPU é seguro para passthrough dinâmico."
info "Limitação segura: CPUs Intel e fabricantes desconhecidos são bloqueados antes de sudo; suporte Intel não é inferido nem aplicado parcialmente."
info "Pré-requisitos: SVM e IOMMU habilitados na BIOS, configuração da etapa 02 completa e etapa 21 concluída já em uma sessão nova."
info "Fases: a A altera boot/módulos e exige reboot; após reiniciar, execute novamente esta mesma etapa/opção para a fase B validar o kernel e registrar o grupo da GPU."
info "Alterações: a fase A define amd_iommu=on iommu=pt, substitui /etc/modules-load.d/vfio.conf e regenera o initramfs via $PLATAFORMA_INITRAMFS_BACKEND; a B grava IOMMU_GROUP_GPU e o inventário."
info "Recomendação: não interrompa a atualização do boot/initramfs e guarde a saída que identifica o backup real do GRUB."
aviso "Riscos: parâmetros ou initramfs inválidos podem impedir o próximo boot; não reinicie se houver erro ou rollback não comprovado."
info "Retorno no kernelstub: sudo kernelstub -d \"amd_iommu=on iommu=pt\"."
info "Retorno no GRUB: use o caminho exato mostrado por 'Backup do GRUB preservado em:' para restaurar /etc/default/grub e rode sudo update-grub."
info "Retorno comum: remova /etc/modules-load.d/vfio.conf, regenere o initramfs e reinicie; não há reboot automático na fase B."

exigir_sudo
exigir_comando lspci

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

    info "Regenerando initramfs para todos os kernels instalados via $PLATAFORMA_INITRAMFS_BACKEND..."
    plataforma_atualizar_initramfs

    echo
    ok "Fase A concluída."
    info "Reversão (Capítulo 16, 'Como desfazer'):"
    if [ "$BOOTLOADER" = "kernelstub" ]; then
        info "  sudo kernelstub -d \"amd_iommu=on iommu=pt\""
    else
        info "  restaure em /etc/default/grub o arquivo cujo caminho exato foi exibido acima por 'Backup do GRUB preservado em:'"
        info "  sudo update-grub"
    fi
    info "  sudo rm /etc/modules-load.d/vfio.conf && sudo update-initramfs -u -k all"
    info "Após o reboot, execute novamente esta mesma etapa/opção; ela entrará na fase B."
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
AMD_VI_LOG="$(sudo dmesg | awk 'BEGIN { exibidas=0 }
    tolower($0) ~ /amd-vi/ { if (exibidas < 10) print; exibidas++ }')" \
    || falhar "Não foi possível ler/analisar o dmesg para validar AMD-Vi."
if [ -n "$AMD_VI_LOG" ]; then
    printf '%s\n' "$AMD_VI_LOG"
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
if ! validar_grupo_iommu_gpu \
        "$GPU_PCI_ID" "${GPU_AUDIO_PCI_ID:-}" "${IOMMU_GROUP_GPU:-}" \
        "$GPU_VENDOR_DEVICE_ID" "${GPU_AUDIO_VENDOR_DEVICE_ID:-}"; then
    erro "$IOMMU_ERRO"
    if [ -n "$IOMMU_GRUPO_ATUAL" ] && [ -d "/sys/kernel/iommu_groups/$IOMMU_GRUPO_ATUAL/devices" ]; then
        erro "Conteúdo observado no grupo $IOMMU_GRUPO_ATUAL:"
        for DEV in "/sys/kernel/iommu_groups/$IOMMU_GRUPO_ATUAL/devices/"*; do
            [ -e "$DEV" ] || continue
            END="${DEV##*/}"
            lspci -nns "${END#0000:}" 2>/dev/null | sed 's/^/   /' || echo "   $END (descrição indisponível)"
        done
    fi
    falhar "Grupo IOMMU inseguro. Não foi persistido nem liberado para passthrough; corrija hardware/BIOS antes de continuar."
fi
GRUPO="$IOMMU_GRUPO_ATUAL"
ok "GPU ($GPU_PCI_ID) no grupo IOMMU $GRUPO. Conteúdo autorizado:"
for END in $IOMMU_MEMBROS; do
    lspci -nns "${END#0000:}" 2>/dev/null | sed 's/^/   /' || echo "   $END (descrição indisponível)"
done
ok "Grupo limpo: apenas GPU, áudio configurado e bridges PCI de classe 0x06."

salvar_conf IOMMU_GROUP_GPU "$GRUPO"
info "IOMMU_GROUP_GPU=$GRUPO validado e gravado no passthrough.conf."

info "5) Listagem completa dos grupos (registro em ~/inventario-hardware/):"
mkdir -p "$HOME/inventario-hardware"
bash "$PROJETO_DIR/util/listar-grupos-iommu.sh" | tee "$HOME/inventario-hardware/grupos-iommu-$(date +%Y%m%d).txt" | tail -n 5
info "(arquivo completo salvo; acima só as últimas linhas)"

echo
ok "Capítulo 16 concluído. GPU pronta para vinculação DINÂMICA na etapa 50."
