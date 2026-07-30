#!/bin/bash
# ============================================================================
# etapas/13-diretorios.sh - Capítulo 10: Estrutura de Diretórios
# ============================================================================
# Cria /vm (disco virtual da VM) e /mnt/docs4 (ponto de montagem do HD2).
# A permissão fina de /vm para o usuário libvirt-qemu é feita na etapa 21,
# depois que a pilha de virtualização criar esse usuário de sistema.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf
DOCS4="${DOCS4_MONTAGEM:-/mnt/docs4}"

VM_ESTADO=""
VM_DIAGNOSTICO=""
DOCS4_DIAGNOSTICO=""

validar_vm_existente() {
    local dono grupo modo status
    VM_ESTADO=""
    VM_DIAGNOSTICO=""

    if [ -L /vm ]; then
        VM_DIAGNOSTICO="/vm não pode ser um link simbólico."
        return 1
    fi
    if [ ! -e /vm ]; then
        VM_DIAGNOSTICO="/vm não existe."
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

validar_docs4_existente() {
    DOCS4_DIAGNOSTICO=""
    if [ -L "$DOCS4" ]; then
        DOCS4_DIAGNOSTICO="$DOCS4 não pode ser um link simbólico."
        return 1
    fi
    if [ ! -e "$DOCS4" ]; then
        DOCS4_DIAGNOSTICO="$DOCS4 não existe."
        return 1
    fi
    if [ ! -d "$DOCS4" ]; then
        DOCS4_DIAGNOSTICO="$DOCS4 deve ser um diretório real, não arquivo ou outro tipo."
        return 1
    fi
}

verificar() {
    if validar_vm_existente; then
        v_ok "/vm é diretório real, não é mountpoint e está no estado $VM_ESTADO normativo."
    else
        v_falta "$VM_DIAGNOSTICO"
    fi
    if validar_docs4_existente; then
        v_ok "$DOCS4 é um diretório real."
    else
        v_falta "$DOCS4_DIAGNOSTICO"
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

exigir_nao_root
exigir_sudo

titulo "Capítulo 10: Estrutura de diretórios"

VM_NOVO=0
DOCS4_NOVO=0
if [ -e /vm ] || [ -L /vm ]; then
    validar_vm_existente || falhar "$VM_DIAGNOSTICO"
else
    VM_NOVO=1
fi
if [ -e "$DOCS4" ] || [ -L "$DOCS4" ]; then
    validar_docs4_existente || falhar "$DOCS4_DIAGNOSTICO"
else
    DOCS4_NOVO=1
fi

if [ "$VM_NOVO" -eq 1 ]; then
    sudo mkdir -- /vm
    sudo chown root:root -- /vm
    sudo chmod 0755 -- /vm
else
    info "/vm já está no estado $VM_ESTADO normativo; permissões preservadas."
fi

if [ "$DOCS4_NOVO" -eq 1 ]; then
    sudo mkdir -p -- "$DOCS4"
else
    info "$DOCS4 já é um diretório real; preservado."
fi

validar_vm_existente || falhar "$VM_DIAGNOSTICO"
validar_docs4_existente || falhar "$DOCS4_DIAGNOSTICO"

ok "Diretórios validados:"
ls -ld -- /vm "$DOCS4"
if [ "$VM_ESTADO" = "inicial" ]; then
    info "Estado inicial seguro (root:root 755); a etapa 21 ajusta /vm para o grupo libvirt-qemu."
else
    info "Estado final da etapa 21 (root:libvirt-qemu 770) preservado."
fi
