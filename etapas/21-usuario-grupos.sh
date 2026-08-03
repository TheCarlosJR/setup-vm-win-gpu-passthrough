#!/bin/bash
# ============================================================================
# etapas/21-usuario-grupos.sh - Capítulo 14: Usuário, Grupos e Serviços
# ============================================================================
# Adiciona o usuário aos grupos libvirt/kvm, ajusta /vm para o usuário de
# sistema do QEMU (libvirt-qemu) e garante libvirtd/virtlogd ativos.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

verificar() {
    [ -n "${USUARIO_LINUX:-}" ] || { v_falta "USUARIO_LINUX não definido (etapa 02)."; v_fim; }
    local grupos
    grupos="$(id -nG "$USUARIO_LINUX" 2>/dev/null || true)"
    grep -qw libvirt <<< "$grupos" && v_ok "usuário no grupo libvirt." || v_falta "usuário fora do grupo libvirt."
    grep -qw kvm     <<< "$grupos" && v_ok "usuário no grupo kvm."     || v_falta "usuário fora do grupo kvm."
    if [ "$(stat -c %G /vm 2>/dev/null)" = "libvirt-qemu" ]; then
        v_ok "/vm com grupo libvirt-qemu."
    else
        v_falta "/vm sem o grupo libvirt-qemu."
    fi
    systemctl is-active --quiet libvirtd && v_ok "libvirtd ativo." || v_falta "libvirtd inativo."
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

titulo "Antes de continuar"
info "Objetivo: permitir que o usuário opere libvirt/KVM e que o processo libvirt-qemu grave os arquivos da VM em /vm."
info "Pré-requisitos: conclua a opção 7 do menu (cria /vm) e a opção 9 (instala libvirt/KVM e cria o usuário libvirt-qemu); confira também USUARIO_LINUX."
info "Alterações: acrescenta o usuário aos grupos libvirt e kvm, define /vm como root:libvirt-qemu com modo 770, habilita libvirtd/virtlogd e cria/remove um arquivo temporário de teste."
info "Recomendação: execute esta etapa antes de criar a VM e confirme depois, em sessão nova, os comandos id e virsh sem sudo."
aviso "Riscos: os grupos concedem controle sobre VMs/KVM; o modo 770 retira acesso a /vm de usuários fora do dono/grupo, e o estado anterior não é salvo."
info "Retorno/reboot: não exige reboot, mas é obrigatório encerrar o menu e toda a sessão, fazer logout/login (ou reiniciar) e só então reabrir o menu; qualquer reversão de grupos/permissões é manual."

exigir_nao_root
exigir_sudo
exigir_conf USUARIO_LINUX

titulo "Capítulo 14: Usuário, grupos e serviços"

info "Confirmando os nomes de usuário/grupo de sistema criados pelo libvirt:"
getent passwd | grep -i libvirt || true
getent group  | grep -i libvirt || true
getent passwd libvirt-qemu >/dev/null \
    || falhar "Usuário de sistema 'libvirt-qemu' não existe. As opções 7 e 9 foram concluídas?"

info "Adicionando $USUARIO_LINUX aos grupos libvirt e kvm..."
sudo usermod -aG libvirt "$USUARIO_LINUX"
sudo usermod -aG kvm "$USUARIO_LINUX"

info "Ajustando permissões de /vm para o processo QEMU..."
sudo chown root:libvirt-qemu /vm
sudo chmod 770 /vm

info "Garantindo serviços ativos..."
sudo systemctl enable --now libvirtd
sudo systemctl enable --now virtlogd

titulo "Teste de escrita do usuário libvirt-qemu em /vm"
if sudo -u libvirt-qemu touch /vm/.teste-permissao && [ -e /vm/.teste-permissao ]; then
    sudo rm -f /vm/.teste-permissao
    ok "libvirt-qemu consegue criar arquivos em /vm."
else
    aviso "Teste de escrita falhou; revise chown/chmod acima."
fi

echo
ok "Etapa concluída."
aviso "IMPORTANTE: os novos grupos só valem em sessões NOVAS."
aviso "Encerre este menu e faça LOGOUT e LOGIN de toda a sessão (ou reinicie) antes da etapa 30."
info "Depois do login, reabra o menu e confirme com: id   (deve listar libvirt e kvm)"
info "E teste sem sudo: virsh --connect qemu:///system list --all"
