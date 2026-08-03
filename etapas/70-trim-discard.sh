#!/bin/bash
# ============================================================================
# etapas/70-trim-discard.sh - Capítulo 25: TRIM/discard
# ============================================================================
# Habilita discard='unmap' no QCOW2 para encaminhar TRIM do Windows ao host;
# a redução do espaço alocado depende de toda a pilha e não é imediata nem
# garantida. A pasta de backups é preparada separadamente, sem executar backup.
# Snapshots usam util/snapshot-vm.sh; backups usam util/backup-vm.sh e devem ser
# armazenados em outro disco físico, não junto da VM.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf
DOCS4="${DOCS4_MONTAGEM:-/mnt/docs4}"
DESTINO_BACKUPS="${BACKUPS_VM_DIR:-$DOCS4/backups-vm}"

verificar() {
    [ -n "${VM_NAME:-}" ] || { v_falta "VM_NAME não definido."; v_fim; }
    if vm_existe "$VM_NAME" && $VIRSH dumpxml --inactive "$VM_NAME" | grep -q "discard='unmap'"; then
        v_ok "TRIM: discard='unmap' ativo no XML."
    else
        v_falta "TRIM: discard='unmap' ausente."
    fi
    [ -d "$DESTINO_BACKUPS" ] \
        && v_ok "Backup: pasta de destino existe (isso não comprova que haja backup)." \
        || v_falta "Backup pendente: pasta $DESTINO_BACKUPS ausente."
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

exigir_nao_root
exigir_sudo
exigir_comando xmlstarlet
exigir_conf VM_NAME QCOW2_PATH

titulo "Capítulo 25: TRIM/discard"

cat <<ORIENTACAO
Finalidade: habilitar discard no QCOW2 e preparar, separadamente, o diretório
de backups. Se o XML mudar, a VM deve estar desligada e um backup do XML será
criado; o efeito começa no próximo boot da VM e não exige reboot do host.
Risco/recomendação: TRIM não substitui backup e não garante redução imediata
do espaço alocado. Snapshot permanece junto da cadeia/armazenamento da VM;
backup real deve ser executado e guardado em outro disco físico.
ORIENTACAO

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
    aviso "TRIM configurado; preparação e execução do backup continuam pendentes."
else
    sudo mkdir -p "$DESTINO_BACKUPS"
    ok "$DESTINO_BACKUPS pronto; nenhum backup foi executado por esta etapa."
    if [ "$(disco_de "$DESTINO_BACKUPS" 2>/dev/null || true)" = "$(disco_raiz 2>/dev/null || true)" ]; then
        aviso "O destino está no mesmo disco físico da raiz do host; use outro disco físico para o backup real."
    fi
fi

echo
cat <<'DICAS'
Operação contínua (Capítulo 25):
  - Dentro do Windows: "Otimizar Unidades" deve listar o C: como SSD com
    otimização agendada (é o TRIM automático).
  - Validação: apague arquivos grandes na VM, rode a otimização e compare
    'qemu-img info /vm/Windows11.qcow2'; o tamanho alocado pode diminuir,
    mas não há redução imediata garantida.
  - Snapshots rápidos: util/snapshot-vm.sh criar|listar|reverter|apagar
  - Backup real: execute util/backup-vm.sh com destino em outro disco físico.
  - Snapshot permanece no armazenamento/cadeia da VM e NÃO substitui backup.
DICAS
info "Fim da etapa 70: TRIM e disponibilidade do destino de backup são estados independentes; confira os avisos acima."
