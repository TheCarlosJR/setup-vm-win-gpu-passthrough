#!/bin/bash
# ============================================================================
# etapas/30-iommu-vfio.sh - Etapa 11: IOMMU e VFIO
# ============================================================================
# Duas fases automáticas (o script percebe sozinho em qual está):
#   Fase A (antes do reboot): converge, em UMA transação, os parâmetros de
#     kernel do bootloader correto, o bloco gerenciado de
#     /etc/modules-load.d/vfio.conf e o initramfs. Falha ou sinal em qualquer
#     janela restaura todos os recursos e prova cada restauração (REQ-IOMMU-TX).
#   Fase B (após o reboot): valida cmdline, mensagens AMD-Vi, módulos vfio,
#     lista o grupo IOMMU da GPU, alerta sobre dispositivos estranhos no
#     grupo e grava IOMMU_GROUP_GPU no passthrough.conf.
#
# "Ativo neste boot" e "persistido para o próximo boot" são fatos
# independentes: a fase A converge o persistente mesmo quando a cmdline atual
# já tem os parâmetros, e a fase B só começa quando o kernel em execução prova
# os dois.
#
# Fiel ao manual: a GPU NÃO é presa ao vfio-pci no boot (GPU única!);
# a vinculação é dinâmica, feita pelos hooks da etapa 14.
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
    local rc_vfio=0
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

    # Os dois eixos são reportados separadamente: um host com parâmetros ativos
    # mas não persistidos perde IOMMU no próximo boot, e o inverso ainda exige
    # reiniciar. Nenhum dos dois pode ser lido como concluído sozinho.
    boot_estado_iommu "$IOMMU_PARAMS_PADRAO" || true
    case "$BOOT_IOMMU_ATIVO" in
        exato) v_ok "Parâmetros $IOMMU_PARAMS_PADRAO ativos no kernel em execução." ;;
        divergente) v_falta "A cmdline em execução tem as chaves de IOMMU com valores divergentes." ;;
        ausente) v_falta "Parâmetros de IOMMU ausentes no /proc/cmdline (reboot pendente)." ;;
        *) v_indeterminado "Não foi possível inspecionar a cmdline em execução." ;;
    esac
    case "$BOOT_IOMMU_PERSISTENTE" in
        exato) v_ok "Persistência de boot exata para o próximo boot." ;;
        ausente) v_falta "Nenhum parâmetro de IOMMU está persistido para o próximo boot." ;;
        divergente) v_kernel_persistencia_falhou "Persistência de IOMMU divergente: ${BOOT_IOMMU_ERRO:-estado não exato}." ;;
        *) v_indeterminado "Persistência de boot não pôde ser lida: ${BOOT_IOMMU_ERRO:-privilégio ou backend indisponível}." ;;
    esac

    vfio_modules_estado || rc_vfio=$?
    case "$rc_vfio" in
        0) v_ok "$VFIO_MODULES_ARQUIVO com o bloco gerenciado convergido." ;;
        1) v_falta "$VFIO_MODULES_ARQUIVO ausente ou divergente do bloco gerenciado." ;;
        *) v_erro "$VFIO_MODULES_ERRO" ;;
    esac
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

guard_mutation iommu.configure || exit 1
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
info "Pré-requisitos: SVM e IOMMU habilitados na BIOS, configuração da etapa 3 completa e etapa 10 concluída já em uma sessão nova."
info "Fases: a A altera boot/módulos e exige reboot; após reiniciar, execute novamente esta mesma etapa/opção para a fase B validar o kernel e registrar o grupo da GPU."
info "Alterações: a fase A é uma transação única que define $IOMMU_PARAMS_PADRAO, converge o bloco gerenciado de $VFIO_MODULES_ARQUIVO e regenera o initramfs via $PLATAFORMA_INITRAMFS_BACKEND; a B grava IOMMU_GROUP_GPU e o inventário."
info "Recomendação: não interrompa a atualização do boot/initramfs; se ela for interrompida, a própria etapa restaura e comprova o estado anterior antes de sair."
aviso "Riscos: parâmetros ou initramfs inválidos podem impedir o próximo boot; não reinicie se houver erro ou rollback não comprovado."
info "Retorno no kernelstub: sudo kernelstub -d \"$IOMMU_PARAMS_PADRAO\"."
info "Retorno no GRUB: use o caminho exato mostrado por 'Backup do GRUB preservado em:' para restaurar /etc/default/grub e rode sudo update-grub."
info "Retorno comum: apague o bloco entre '$VFIO_MARCADOR_INICIO' e '$VFIO_MARCADOR_FIM' em $VFIO_MODULES_ARQUIVO, regenere o initramfs e reinicie; não há reboot automático na fase B."

exigir_sudo
exigir_comando lspci

titulo "Etapa 11: IOMMU e VFIO"

# ----------------------------------------------------------------------------
# Fase A: convergência transacional de boot, VFIO e initramfs (REQ-IOMMU-TX)
# ----------------------------------------------------------------------------
iommu_finalizar() {
    local rc=$?
    trap - EXIT INT TERM
    case "$IOMMU_TX_ESTADO" in
        PREPARED|BOOT|VFIO|INITRAMFS|VERIFIED|ROLLING_BACK)
            erro "Transação de IOMMU/VFIO interrompida antes do commit; restaurando o estado anterior."
            if ! iommu_vfio_rollback; then
                erro "Recuperação manual necessária: revise boot, $VFIO_MODULES_ARQUIVO e o initramfs ANTES de reiniciar."
                [ "$rc" -ne 0 ] || rc=1
            fi
            ;;
    esac
    python_core_temporarios_limpar
    encerrar_sudo_keepalive
    exit "$rc"
}

titulo "Etapa 11.1/2 Fase A: convergir parâmetros de kernel, módulos VFIO e initramfs"
boot_estado_iommu "$IOMMU_PARAMS_PADRAO" \
    || aviso "Estado de boot parcialmente indeterminado: ${BOOT_IOMMU_ERRO:-sem diagnóstico}."
info "Estado atual: ativo=$BOOT_IOMMU_ATIVO, persistido=$BOOT_IOMMU_PERSISTENTE."

# Traps armados ANTES da primeira mutação: qualquer falha ou sinal na janela
# transacional cai na restauração comprovada, preservando o código de saída.
trap 'iommu_finalizar' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

iommu_vfio_transacao "$IOMMU_PARAMS_PADRAO" \
    || falhar "${IOMMU_TX_ERRO:-Transação de IOMMU/VFIO recusada antes de qualquer efeito.}"

# Commit lógico: a partir daqui o trap deixa de restaurar e volta a ser apenas
# o do ticket sudo instalado por exigir_sudo.
trap encerrar_sudo_keepalive EXIT INT TERM
ok "Boot persistente, $VFIO_MODULES_ARQUIVO e initramfs convergidos e comprovados."

if ! cmdline_parametros_exatos "$IOMMU_PARAMS_PADRAO"; then
    aviso "O kernel em execução ainda não tem $IOMMU_PARAMS_PADRAO: ${CMDLINE_PARAM_ERRO:-parâmetros ausentes}."
    info "Reversão (etapa 11, 'Como desfazer'):"
    if [ "$BOOTLOADER_ATIVO" = "kernelstub" ]; then
        info "  sudo kernelstub -d \"$IOMMU_PARAMS_PADRAO\""
    else
        info "  restaure em /etc/default/grub o arquivo cujo caminho exato foi exibido acima por 'Backup do GRUB preservado em:'"
        info "  sudo update-grub"
    fi
    info "  apague o bloco gerenciado de $VFIO_MODULES_ARQUIVO e regenere o initramfs"
    info "Após o reboot, execute novamente esta mesma etapa/opção; ela entrará na fase B."
    pedir_reboot
    exit 0
fi

# ----------------------------------------------------------------------------
# Fase B: validação pós-reboot
# ----------------------------------------------------------------------------
titulo "Etapa 11.2/2 Fase B: validação pós-reboot"

info "1) /proc/cmdline:"
cat /proc/cmdline
ok "amd_iommu=on e iommu=pt ativos uma única vez e com os valores exatos."

info "2) Mensagens do kernel (AMD-Vi):"
AMD_VI_LOG="$(sudo dmesg | awk 'BEGIN { exibidas=0 }
    tolower($0) ~ /amd-vi/ { if (exibidas < 10) print; exibidas++ }')" \
    || falhar "Não foi possível ler/analisar o dmesg para validar AMD-Vi."
if [ -n "$AMD_VI_LOG" ]; then
    printf '%s\n' "$AMD_VI_LOG"
    ok "AMD-Vi reportado pelo kernel."
else
    aviso "Nenhuma mensagem AMD-Vi: confirme IOMMU=Enabled na BIOS (etapa 2)."
fi

info "3) Módulos VFIO:"
if lsmod | grep -E '^vfio(_pci|_iommu_type1)?' ; then
    ok "Módulos vfio carregados."
else
    falhar "Módulos vfio ausentes. Verifique $VFIO_MODULES_ARQUIVO e rode: sudo modprobe vfio_pci"
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
ok "Etapa 11 concluída. GPU pronta para vinculação DINÂMICA na etapa 14."
