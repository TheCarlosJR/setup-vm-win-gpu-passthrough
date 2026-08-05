#!/bin/bash
# ============================================================================
# util/atualizar-host.sh - atualização do host com snapshot opcional da VM
# ============================================================================
# Uso:
#   atualizar-host.sh            tenta snapshot libvirt e executa apt update,
#                                full-upgrade e autoremove
#   atualizar-host.sh --validar  faz checagens parciais depois do reboot
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf
exigir_nao_root
exigir_sudo

if [ "${1:-}" = "--validar" ]; then
    titulo "Validação parcial pós-atualização"
    info "Finalidade: checar driver NVIDIA, parâmetros AMD IOMMU e, opcionalmente, iniciar a VM para observar os hooks."
    info "Pré-requisitos: reboot concluído, sudo, configuração carregada e acesso ao monitor/TTY para acompanhar o teste da GPU."
    aviso "Efeito: as primeiras checagens são leitura; se confirmado, o teste inicia a VM e entrega a GPU ao Windows."
    info "Recomendação: só inicie a VM após nvidia-smi e IOMMU estarem corretos; desligue o Windows para testar o retorno da GPU."
    info "Não abrange: teste automático de áudio, grupo/reset IOMMU, XML/NVRAM/TPM, HD1, DKMS/Secure Boot ou rollback."
    aviso "Retorno/reboot: este modo pode terminar em 0 mesmo após imprimir erro; avalie cada linha. Ele não reinicia o host."
    echo "1) Driver NVIDIA no host:"
    if nvidia-smi >/dev/null 2>&1; then
        nvidia-smi | head -n 12
        ok "Driver NVIDIA respondeu ao nvidia-smi."
    else
        erro "nvidia-smi falhou: NÃO inicie a VM; confirme módulos e logs do driver NVIDIA no boot atual."
    fi
    echo "2) Parâmetros de IOMMU:"
    if cmdline_tem "amd_iommu=on" && cmdline_tem "iommu=pt"; then
        ok "amd_iommu=on iommu=pt presentes."
    else
        erro "Parâmetros AMD IOMMU ausentes do cmdline; confira /proc/cmdline e a configuração efetiva do bootloader."
    fi
    sudo dmesg | grep -i "AMD-Vi" | head -n 5 || aviso "Sem mensagens AMD-Vi."
    echo "3) Teste manual da VM e dos hooks:"
    if [ -n "${VM_NAME:-}" ] && confirmar "Iniciar a VM $VM_NAME agora para testar o passthrough?"; then
        $VIRSH start "$VM_NAME"
        info "Esperado: monitor troca para o Windows. Depois desligue o Windows e"
        info "confirme que o desktop Linux VOLTA sozinho (hook release/end)."
        info "Logs: sudo journalctl -u libvirtd -e | grep -i hook"
    fi
    exit 0
fi

titulo "Atualização do host com proteção prévia da VM"
info "Finalidade: criar um snapshot interno offline da VM antes de executar apt update, full-upgrade e autoremove no host."
info "Pré-requisitos: sudo, APT/rede funcionais e espaço; para o snapshot, VM configurada, desligada e QCOW2 ativo sem overlay externo."
aviso "Efeito: pode criar snapshot interno, atualizar/remover pacotes, trocar kernel/driver e reiniciar o host se você confirmar."
info "Recomendação: desligue a VM e tenha cópia independente verificada antes de continuar; revise pacotes críticos depois."
aviso "Risco: full-upgrade/autoremove podem remover versões úteis para rollback; sem snapshot, só prossiga com confirmação textual e backup independente."
info "Limite do snapshot: não é backup independente nem rollback do host e não cobre HD1; XML/NVRAM/TPM restauráveis não são garantidos."
info "Retorno/reboot: falhas APT interrompem. Sem snapshot interno comprovado, o script exige confirmação textual. O reboot é opcional, mas necessário antes de --validar."
SNAPSHOT_OK=0
if [ -n "${VM_NAME:-}" ] && vm_existe "$VM_NAME"; then
    NOME_SNAP="antes-atualizacao-host-$(date +%Y%m%d-%H%M%S)"
    if vm_desligada "$VM_NAME"; then
        info "Criando snapshot interno offline pré-atualização '$NOME_SNAP'..."
        if bash "$PROJETO_DIR/util/snapshot-vm.sh" criar "$NOME_SNAP" \
            "Snapshot interno da VM antes de atualizar o host; não substitui backup"; then
            SNAPSHOT_OK=1
            ok "Snapshot interno pré-atualização criado e comprovado."
        else
            aviso "Snapshot interno falhou (overlay externo, armazenamento, espaço ou configuração)."
        fi
    else
        aviso "VM está ligada; snapshot interno offline não será criado."
    fi
else
    aviso "VM não encontrada; não há snapshot a criar."
fi
if [ "$SNAPSHOT_OK" -ne 1 ]; then
    confirmar_digitando "CONTINUAR SEM SNAPSHOT" "Sem snapshot interno comprovado da VM. Confirme que há backup independente e digite CONTINUAR SEM SNAPSHOT para atualizar mesmo assim." \
        || falhar "Atualização cancelada sem snapshot."
fi

sudo apt update
sudo apt full-upgrade -y
sudo apt autoremove -y

echo
info "Pacotes NVIDIA ainda marcados como atualizáveis:"
apt list --upgradable 2>/dev/null | grep -i nvidia || echo "  (nenhum pendente)"

echo
aviso "Após reiniciar, faça a validação pós-reboot com: bash util/atualizar-host.sh --validar"
aviso "Não repita o modo de atualização apenas para validar; na mensagem genérica abaixo, 'mesma etapa' significa usar --validar."
pedir_reboot
