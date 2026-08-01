#!/bin/bash
# ============================================================================
# etapas/70-trim-discard.sh - Capítulo 25: TRIM/discard
# ============================================================================
# Habilita discard='unmap' no disco QCOW2 (o TRIM do Windows passa a liberar
# espaço físico no NVMe) e cria a pasta de backups no HD2.
# Snapshots e backup viram utilitários: util/snapshot-vm.sh e util/backup-vm.sh.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf
DOCS4="${DOCS4_MONTAGEM:-/mnt/docs4}"
DESTINO_BACKUPS="${BACKUPS_VM_DIR:-$DOCS4/backups-vm}"

verificar() {
    [ -n "${VM_NAME:-}" ] || { v_falta "VM_NAME não definido."; v_fim; }
    if vm_existe "$VM_NAME" && $VIRSH dumpxml --inactive "$VM_NAME" | grep -q "discard='unmap'"; then
        v_ok "discard='unmap' ativo no XML."
    else
        v_falta "discard='unmap' ausente."
    fi
    [ -d "$DESTINO_BACKUPS" ] && v_ok "Pasta de backups existe." || v_falta "Pasta $DESTINO_BACKUPS ausente."
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

exigir_nao_root
exigir_sudo
exigir_comando xmlstarlet
exigir_conf VM_NAME QCOW2_PATH

titulo "Capítulo 25: TRIM/discard"

info "Suporte a discard no host (DISC-GRAN/DISC-MAX diferentes de zero = OK):"
lsblk --discard | sed 's/^/  /'

if $VIRSH dumpxml --inactive "$VM_NAME" | grep -q "discard='unmap'"; then
    info "discard='unmap' já configurado."
else
    exigir_vm_desligada "$VM_NAME"
    xml_backup "$VM_NAME"
    TMPX="$(mktemp)"
    $VIRSH dumpxml --inactive "$VM_NAME" > "$TMPX"
    xmlstarlet ed -L \
        -d "/domain/devices/disk[source/@file='$QCOW2_PATH']/driver/@discard" \
        "$TMPX"
    xmlstarlet ed -L \
        -i "/domain/devices/disk[source/@file='$QCOW2_PATH']/driver" -t attr -n discard -v unmap \
        "$TMPX"
    $VIRSH define "$TMPX" >/dev/null
    rm -f "$TMPX"
    ok "discard='unmap' aplicado ao disco $QCOW2_PATH."
fi

titulo "Pasta de backups"
if [[ "$DESTINO_BACKUPS" == "$DOCS4"/* ]] && ! mountpoint -q "$DOCS4"; then
    aviso "$DOCS4 não está montado; pasta de backups não criada (rode a etapa 14)."
else
    sudo mkdir -p "$DESTINO_BACKUPS"
    ok "$DESTINO_BACKUPS pronto."
    if [ "$(disco_de "$DESTINO_BACKUPS" 2>/dev/null || true)" = "$(disco_raiz 2>/dev/null || true)" ]; then
        aviso "Os backups estão no MESMO disco físico da VM: não protegem contra falha desse disco."
    fi
fi

echo
cat <<'DICAS'
Operação contínua (Capítulo 25):
  - Dentro do Windows: "Otimizar Unidades" deve listar o C: como SSD com
    otimização agendada (é o TRIM automático).
  - Validação: apague arquivos grandes na VM, rode a otimização e compare
    'qemu-img info /vm/Windows11.qcow2' (disk size deve diminuir).
  - Snapshots rápidos:   util/snapshot-vm.sh criar|listar|reverter|apagar
  - Backup real (HD2):   util/backup-vm.sh
  - Snapshot NÃO substitui backup: ambos vivem no mesmo NVMe.
DICAS
ok "Etapa 70 concluída."
