#!/bin/bash
# ============================================================================
# util/atualizar-host.sh - Capítulo 26: atualização segura do host
# ============================================================================
# Uso:
#   atualizar-host.sh            snapshot de segurança + apt full-upgrade
#   atualizar-host.sh --validar  validação em camadas pós-reboot
#
# Ordem de validação do manual: driver NVIDIA -> parâmetros IOMMU -> início
# da VM (hook prepare) -> retorno da GPU ao desligar (hook release).
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf
exigir_nao_root
exigir_sudo

if [ "${1:-}" = "--validar" ]; then
    titulo "Validação pós-atualização (Capítulo 26)"
    echo "1) Driver NVIDIA no host:"
    if nvidia-smi >/dev/null 2>&1; then
        nvidia-smi | head -n 12
        ok "Driver NVIDIA funcional."
    else
        erro "nvidia-smi falhou: NÃO prossiga; revise a etapa 11 / Capítulo 26."
    fi
    echo "2) Parâmetros de IOMMU:"
    if cmdline_tem "amd_iommu=on" && cmdline_tem "iommu=pt"; then
        ok "amd_iommu=on iommu=pt presentes."
    else
        erro "Parâmetros de IOMMU sumiram do cmdline; revise a etapa 30."
    fi
    sudo dmesg | grep -i "AMD-Vi" | head -n 5 || aviso "Sem mensagens AMD-Vi."
    echo "3) Teste da VM (hooks):"
    if [ -n "${VM_NAME:-}" ] && confirmar "Iniciar a VM $VM_NAME agora para testar o passthrough?"; then
        $VIRSH start "$VM_NAME"
        info "Esperado: monitor troca para o Windows. Depois desligue o Windows e"
        info "confirme que o desktop Linux VOLTA sozinho (hook release/end)."
        info "Logs: sudo journalctl -u libvirtd -e | grep -i hook"
    fi
    exit 0
fi

titulo "Atualização segura do host (Capítulo 26)"
if [ -n "${VM_NAME:-}" ] && vm_existe "$VM_NAME"; then
    NOME_SNAP="antes-atualizacao-host-$(date +%Y%m%d)"
    info "Criando snapshot de segurança '$NOME_SNAP'..."
    $VIRSH snapshot-create-as "$VM_NAME" "$NOME_SNAP" "Snapshot de segurança antes de atualizar o host" \
        || aviso "Snapshot falhou (VM inexistente/sem espaço); prosseguindo por sua conta."
else
    aviso "VM não encontrada; atualizando sem snapshot."
fi

sudo apt update
sudo apt full-upgrade -y
sudo apt autoremove -y

echo
info "Pacotes NVIDIA que mudaram/estão pendentes:"
apt list --upgradable 2>/dev/null | grep -i nvidia || echo "  (nenhum pendente)"

echo
aviso "Reinicie e depois rode: util/atualizar-host.sh --validar"
pedir_reboot
