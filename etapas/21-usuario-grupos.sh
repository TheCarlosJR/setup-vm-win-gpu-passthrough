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

VM_ESTADO=""
VM_DIAGNOSTICO=""

validar_vm_existente() {
    local dono grupo modo status
    VM_ESTADO=""
    VM_DIAGNOSTICO=""

    if [ -L /vm ]; then
        VM_DIAGNOSTICO="/vm não pode ser um link simbólico."
        return 1
    fi
    if [ ! -e /vm ]; then
        VM_DIAGNOSTICO="/vm não existe. Execute a etapa 13 antes."
        return 1
    fi
    if [ ! -d /vm ]; then
        VM_DIAGNOSTICO="/vm deve ser um diretório real, não arquivo ou outro tipo."
        return 1
    fi
    if ! command -v mountpoint >/dev/null 2>&1; then
        VM_DIAGNOSTICO="Não foi possível validar /vm: comando mountpoint ausente."
        return 1
    fi
    if mountpoint -q -- /vm; then
        VM_DIAGNOSTICO="/vm é um ponto de montagem inesperado; aborte e revise a montagem."
        return 1
    else
        status=$?
        if [ "$status" -ne 32 ]; then
            VM_DIAGNOSTICO="Não foi possível determinar se /vm é um ponto de montagem (status $status)."
            return 1
        fi
    fi
    if ! read -r dono grupo modo < <(stat -c '%U %G %a' -- /vm); then
        VM_DIAGNOSTICO="Não foi possível consultar dono, grupo e modo de /vm."
        return 1
    fi

    case "$dono:$grupo:$modo" in
        root:root:755)
            VM_ESTADO="inicial"
            ;;
        root:libvirt-qemu:770)
            VM_ESTADO="final"
            ;;
        *)
            VM_DIAGNOSTICO="Estado inválido de /vm: encontrado $dono:$grupo modo $modo; esperado root:root 755 ou root:libvirt-qemu 770."
            return 1
            ;;
    esac
}

verificar() {
    [ -n "${USUARIO_LINUX:-}" ] || { v_falta "USUARIO_LINUX não definido (etapa 02)."; v_fim; }
    local grupos servico qemu_usuario_ok=0 qemu_grupo_ok=0 vm_final=0

    if getent passwd "$USUARIO_LINUX" >/dev/null; then
        grupos="$(id -nG "$USUARIO_LINUX")"
        grep -qw libvirt <<< "$grupos" \
            && v_ok "usuário no grupo libvirt." \
            || v_falta "usuário fora do grupo libvirt."
        grep -qw kvm <<< "$grupos" \
            && v_ok "usuário no grupo kvm." \
            || v_falta "usuário fora do grupo kvm."
        if grep -qw libvirt-qemu <<< "$grupos"; then
            v_falta "usuário normal não deve pertencer ao grupo libvirt-qemu."
        else
            v_ok "usuário normal fora do grupo libvirt-qemu."
        fi
    else
        v_falta "Usuário $USUARIO_LINUX não existe."
    fi

    if getent passwd libvirt-qemu >/dev/null; then
        v_ok "usuário de sistema libvirt-qemu existe."
        qemu_usuario_ok=1
    else
        v_falta "usuário de sistema libvirt-qemu não existe."
    fi
    if getent group libvirt-qemu >/dev/null; then
        v_ok "grupo de sistema libvirt-qemu existe."
        qemu_grupo_ok=1
    else
        v_falta "grupo de sistema libvirt-qemu não existe."
    fi

    if validar_vm_existente; then
        if [ "$VM_ESTADO" = "final" ]; then
            v_ok "/vm é diretório real root:libvirt-qemu 770 e não é mountpoint."
            vm_final=1
        else
            v_falta "/vm ainda está no estado inicial root:root 755."
        fi
    else
        v_falta "$VM_DIAGNOSTICO"
    fi

    for servico in libvirtd virtlogd; do
        systemctl is-active --quiet "$servico" \
            && v_ok "$servico ativo." \
            || v_falta "$servico inativo."
    done

    if [ "$qemu_usuario_ok" -eq 1 ] && [ "$qemu_grupo_ok" -eq 1 ] \
        && [ "$vm_final" -eq 1 ] \
        && sudo -n -u libvirt-qemu test -w /vm 2>/dev/null; then
        v_ok "escrita efetiva em /vm confirmada como libvirt-qemu."
    else
        v_falta "escrita efetiva em /vm como libvirt-qemu não confirmada."
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

exigir_nao_root
exigir_sudo
exigir_conf USUARIO_LINUX

titulo "Capítulo 14: Usuário, grupos e serviços"

info "Confirmando os nomes de usuário/grupo de sistema criados pelo libvirt:"
getent passwd | grep -i libvirt || true
getent group  | grep -i libvirt || true
getent passwd "$USUARIO_LINUX" >/dev/null \
    || falhar "Usuário normal '$USUARIO_LINUX' não existe."
getent passwd libvirt-qemu >/dev/null \
    || falhar "Usuário de sistema 'libvirt-qemu' não existe. A etapa 20 foi concluída?"
getent group libvirt-qemu >/dev/null \
    || falhar "Grupo de sistema 'libvirt-qemu' não existe. A etapa 20 foi concluída?"
getent group libvirt >/dev/null \
    || falhar "Grupo 'libvirt' não existe. A etapa 20 foi concluída?"
getent group kvm >/dev/null \
    || falhar "Grupo 'kvm' não existe. A etapa 20 foi concluída?"
if id -nG "$USUARIO_LINUX" | grep -qw libvirt-qemu; then
    falhar "O usuário normal '$USUARIO_LINUX' não deve pertencer ao grupo libvirt-qemu."
fi
validar_vm_existente || falhar "$VM_DIAGNOSTICO"

info "Adicionando $USUARIO_LINUX aos grupos libvirt e kvm..."
sudo usermod -aG libvirt "$USUARIO_LINUX"
sudo usermod -aG kvm "$USUARIO_LINUX"

info "Ajustando permissões de /vm para o processo QEMU..."
if [ "$VM_ESTADO" = "inicial" ]; then
    sudo chown root:libvirt-qemu -- /vm
    sudo chmod 0770 -- /vm
else
    info "/vm já está no estado final root:libvirt-qemu 770; preservado."
fi
validar_vm_existente || falhar "$VM_DIAGNOSTICO"
[ "$VM_ESTADO" = "final" ] \
    || falhar "/vm não atingiu o estado final root:libvirt-qemu 770."

info "Garantindo serviços ativos..."
sudo systemctl enable --now libvirtd
sudo systemctl enable --now virtlogd

titulo "Teste de escrita do usuário libvirt-qemu em /vm"
if sudo -u libvirt-qemu test -w /vm; then
    ok "libvirt-qemu tem escrita efetiva em /vm."
else
    falhar "libvirt-qemu não consegue escrever em /vm; etapa não concluída."
fi

echo
ok "Etapa concluída."
aviso "IMPORTANTE: os novos grupos só valem em sessões NOVAS."
aviso "Faça LOGOUT e LOGIN (ou reinicie) antes da etapa 30."
info "Depois do login, confirme com: id   (deve listar libvirt e kvm)"
info "E teste sem sudo: virsh --connect qemu:///system list --all"
