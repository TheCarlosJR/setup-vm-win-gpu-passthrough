#!/bin/bash
# ============================================================================
# etapas/13-diretorios.sh - Capítulo 10: Estrutura de Diretórios
# ============================================================================
# Cria /vm (disco virtual da VM) e /mnt/docs4 (ponto de montagem do HD2).
# A política escalonada de /vm aceita tanto o estado inicial root:root 0755
# quanto o estado final root:libvirt-qemu 0770 definido pela etapa 21.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf
DOCS4="/mnt/docs4"

VM_ESTADO=""
VM_DIAGNOSTICO=""
DOCS4_ESTADO=""
DOCS4_DIAGNOSTICO=""

validar_docs4_normativo() {
    if [ "${DOCS4_MONTAGEM:-$DOCS4}" != "$DOCS4" ]; then
        DOCS4_DIAGNOSTICO="DOCS4_MONTAGEM deve ser exatamente $DOCS4; encontrado: ${DOCS4_MONTAGEM:-<vazio>}."
        return 1
    fi
}

opcao_mount_presente() {
    local opcoes=",$1," opcao="$2"
    [[ "$opcoes" == *",$opcao,"* ]]
}

obter_mount_docs4() {
    DOCS4_MOUNT_SOURCE=""
    DOCS4_MOUNT_TARGET=""
    DOCS4_MOUNT_FSTYPE=""
    DOCS4_MOUNT_UUID=""
    DOCS4_MOUNT_OPTIONS=""

    DOCS4_MOUNT_SOURCE="$(findmnt -rn -M "$DOCS4" -o SOURCE 2>/dev/null)" || return 1
    DOCS4_MOUNT_TARGET="$(findmnt -rn -M "$DOCS4" -o TARGET 2>/dev/null)" || return 1
    DOCS4_MOUNT_FSTYPE="$(findmnt -rn -M "$DOCS4" -o FSTYPE 2>/dev/null)" || return 1
    DOCS4_MOUNT_UUID="$(findmnt -rn -M "$DOCS4" -o UUID 2>/dev/null)" || return 1
    DOCS4_MOUNT_OPTIONS="$(findmnt -rn -M "$DOCS4" -o OPTIONS 2>/dev/null)" || return 1
    [ -n "$DOCS4_MOUNT_SOURCE" ] && [ "$DOCS4_MOUNT_TARGET" = "$DOCS4" ] \
        && [[ "$DOCS4_MOUNT_SOURCE$DOCS4_MOUNT_TARGET$DOCS4_MOUNT_FSTYPE$DOCS4_MOUNT_UUID$DOCS4_MOUNT_OPTIONS" != *$'\n'* ]]
}

validar_mount_docs4_esperado() {
    local esperado origem

    [ -n "${UUID_HD2:-}" ] && [[ "$UUID_HD2" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
        DOCS4_DIAGNOSTICO="$DOCS4 está montado, mas UUID_HD2 está ausente ou inválido."
        return 1
    }
    if [ -e "/dev/disk/by-uuid/$UUID_HD2" ] || [ -L "/dev/disk/by-uuid/$UUID_HD2" ]; then
        esperado="$(readlink -f -- "/dev/disk/by-uuid/$UUID_HD2" 2>/dev/null || true)"
    else
        esperado="$(blkid -U "$UUID_HD2" 2>/dev/null || true)"
        esperado="$(readlink -f -- "$esperado" 2>/dev/null || true)"
    fi
    origem="${DOCS4_MOUNT_SOURCE%%\[*}"
    origem="$(readlink -f -- "$origem" 2>/dev/null || true)"

    [ -n "$esperado" ] && [ -b "$esperado" ] && [ "$origem" = "$esperado" ] \
        && [ "$DOCS4_MOUNT_UUID" = "$UUID_HD2" ] || {
        DOCS4_DIAGNOSTICO="$DOCS4 é um mountpoint inesperado: origem ${DOCS4_MOUNT_SOURCE:-desconhecida}, UUID ${DOCS4_MOUNT_UUID:-desconhecido}; esperada UUID=$UUID_HD2."
        return 1
    }
    [ "$DOCS4_MOUNT_FSTYPE" = "fuseblk" ] || {
        DOCS4_DIAGNOSTICO="$DOCS4 usa tipo inesperado '$DOCS4_MOUNT_FSTYPE'; esperado ntfs-3g (fuseblk)."
        return 1
    }
    opcao_mount_presente "$DOCS4_MOUNT_OPTIONS" rw \
        && ! opcao_mount_presente "$DOCS4_MOUNT_OPTIONS" ro || {
        DOCS4_DIAGNOSTICO="$DOCS4 não está montado para leitura e escrita com opções coerentes."
        return 1
    }
}

validar_sem_mounts_aninhados_docs4() {
    local permitir_raiz="$1" saida alvo

    saida="$(findmnt -rn --raw -o TARGET 2>/dev/null)" || {
        DOCS4_DIAGNOSTICO="Não foi possível inspecionar mounts sob $DOCS4."
        return 1
    }
    while IFS= read -r alvo; do
        [ -n "$alvo" ] || continue
        if [ "$alvo" = "$DOCS4" ]; then
            if [ "$permitir_raiz" -eq 1 ]; then
                continue
            fi
            DOCS4_DIAGNOSTICO="$DOCS4 é um mountpoint inesperado nesta etapa."
            return 1
        fi
        if [[ "$alvo" == "$DOCS4/"* ]]; then
            DOCS4_DIAGNOSTICO="Mount aninhado inesperado sob $DOCS4: $alvo"
            return 1
        fi
    done <<< "$saida"
}

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
    local metadados conteudo

    DOCS4_ESTADO=""
    DOCS4_DIAGNOSTICO=""
    validar_docs4_normativo || return 1
    command -v findmnt >/dev/null 2>&1 || {
        DOCS4_DIAGNOSTICO="Não foi possível validar $DOCS4: comando findmnt ausente."
        return 1
    }
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

    if obter_mount_docs4; then
        validar_mount_docs4_esperado || return 1
        validar_sem_mounts_aninhados_docs4 1 || return 1
        DOCS4_ESTADO="montado no HD2 esperado"
        return 0
    fi

    validar_sem_mounts_aninhados_docs4 0 || return 1
    metadados="$(stat -c '%u:%g:%a' -- "$DOCS4" 2>/dev/null || true)"
    if [ "$metadados" != "0:0:755" ]; then
        DOCS4_DIAGNOSTICO="Underlay de $DOCS4 deve ser root:root 0755; encontrado ${metadados:-estado desconhecido}."
        return 1
    fi
    conteudo="$(find "$DOCS4" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" || {
        DOCS4_DIAGNOSTICO="Não foi possível confirmar que o underlay de $DOCS4 está vazio."
        return 1
    }
    if [ -n "$conteudo" ]; then
        DOCS4_DIAGNOSTICO="Underlay de $DOCS4 deve estar vazio antes da montagem; encontrado: $conteudo"
        return 1
    fi
    DOCS4_ESTADO="underlay root:root 0755 vazio"
}

verificar() {
    if validar_vm_existente; then
        v_ok "/vm é diretório real, não é mountpoint e está no estado $VM_ESTADO normativo."
    else
        v_falta "$VM_DIAGNOSTICO"
    fi
    if validar_docs4_existente; then
        v_ok "$DOCS4 é diretório real no estado: $DOCS4_ESTADO."
    else
        v_falta "$DOCS4_DIAGNOSTICO"
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

exigir_nao_root
exigir_sudo
exigir_comando findmnt mountpoint stat find blkid readlink
validar_docs4_normativo || falhar "$DOCS4_DIAGNOSTICO"

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
    sudo mkdir -- "$DOCS4"
    sudo chown root:root -- "$DOCS4"
    sudo chmod 0755 -- "$DOCS4"
else
    info "$DOCS4 já está no estado seguro '$DOCS4_ESTADO'; preservado."
fi

validar_vm_existente || falhar "$VM_DIAGNOSTICO"
validar_docs4_existente || falhar "$DOCS4_DIAGNOSTICO"

ok "Diretórios validados:"
ls -ld -- /vm "$DOCS4"
if [ "$VM_ESTADO" = "inicial" ]; then
    info "Estado inicial seguro de /vm (root:root 755); a etapa 21 aplicará a política final."
else
    info "Estado final escalonado de /vm (root:libvirt-qemu 770) preservado."
fi
info "$DOCS4: $DOCS4_ESTADO."
