#!/bin/bash
# ============================================================================
# etapas/20-virtualizacao.sh - Capítulo 13: KVM, QEMU, Libvirt, Virt-Manager,
#                              OVMF, SWTPM e VirtIO
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

PACOTES=(qemu-kvm qemu-utils libvirt-daemon-system libvirt-clients bridge-utils
         virt-manager ovmf swtpm swtpm-tools virtinst)

verificar() {
    local p
    for p in qemu-kvm libvirt-daemon-system virt-manager ovmf swtpm virtinst; do
        dpkg -s "$p" >/dev/null 2>&1 && v_ok "$p instalado." || v_falta "$p ausente."
    done
    if systemctl is-active --quiet libvirtd; then
        v_ok "libvirtd ativo."
    else
        v_falta "libvirtd inativo."
    fi
    if ls /usr/share/OVMF/OVMF_CODE*.fd >/dev/null 2>&1; then
        v_ok "Firmware OVMF presente."
    else
        v_falta "Arquivos OVMF não encontrados."
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

titulo "Antes de continuar"
info "Objetivo: instalar a pilha KVM/QEMU/libvirt usada para criar e executar a VM do Windows 11."
info "Pré-requisitos: SVM/virtualização habilitada na BIOS, rede para o APT e a etapa 12 (pacotes base) concluída."
info "Pacotes: qemu-kvm/qemu-utils virtualizam e gerenciam discos; libvirt-daemon-system/libvirt-clients fornecem libvirtd e virsh; virtinst/virt-manager criam e exibem a VM; OVMF e swtpm fornecem UEFI e TPM 2.0; bridge-utils apoia a rede posterior."
info "Alterações: atualiza o índice do APT, instala esses pacotes, habilita/inicia libvirtd e instala cpu-checker somente se o comando kvm-ok estiver ausente."
info "Recomendação: não interrompa o APT e só avance depois de confirmar KVM, OVMF e a conexão qemu:///system."
aviso "Riscos: uma interrupção pode deixar pacotes ou o serviço incompletos; esta etapa não cria nem altera discos ou VMs."
info "Retorno/reboot: não há rollback automático nem reboot obrigatório; antes de remover pacotes ou desabilitar libvirtd, confirme que nenhuma VM depende deles."

exigir_nao_root
exigir_sudo

titulo "Capítulo 13: Pilha de virtualização"
sudo apt update
sudo apt install -y "${PACOTES[@]}"

info "Habilitando e iniciando o libvirtd, serviço que gerencia as VMs do modo sistema..."
sudo systemctl enable --now libvirtd
sudo systemctl status libvirtd --no-pager | head -n 5

titulo "Verificações do capítulo"
info "Aceleração KVM:"
info "Resultado esperado do kvm-ok: /dev/kvm existe e 'KVM acceleration can be used'."
if ! command -v kvm-ok >/dev/null 2>&1; then
    info "kvm-ok não está disponível; instalando o pacote cpu-checker para executar a verificação."
    sudo apt install -y cpu-checker
fi
kvm-ok || aviso "kvm-ok reprovou: revise SVM na BIOS (etapa 01/Capítulo 12)."

info "Firmware OVMF:"
ls /usr/share/OVMF/

info "Conexão com o libvirt (modo sistema):"
if sudo virsh --connect qemu:///system list --all; then
    ok "libvirtd respondendo (a conexão SEM sudo passa a funcionar após a etapa 21 + logout)."
else
    aviso "Falha na conexão; consulte: sudo journalctl -u libvirtd -e"
fi

echo
ok "Pilha instalada. Próxima etapa: 21 (grupos e permissões do usuário)."
