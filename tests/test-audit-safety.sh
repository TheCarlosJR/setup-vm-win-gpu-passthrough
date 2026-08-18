#!/bin/bash
# Testes sem efeitos no host para os contratos de segurança da auditoria.
set -euo pipefail
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

falha() { echo "FALHA: $*" >&2; exit 1; }
exigir_texto() {
    local arquivo="$1" texto="$2"
    grep -Fq -- "$texto" "$RAIZ/$arquivo" || falha "$arquivo não contém: $texto"
}
rejeitar_texto() {
    local arquivo="$1" texto="$2"
    ! grep -Fq -- "$texto" "$RAIZ/$arquivo" || falha "$arquivo ainda contém texto proibido: $texto"
}

bash -n "$RAIZ/etapas/11-driver-nvidia.sh" "$RAIZ/etapas/12-pacotes-base.sh" \
    "$RAIZ/etapas/14-working-disk.sh" "$RAIZ/etapas/61-airlock.sh" \
    "$RAIZ/etapas/70-trim-discard.sh" "$RAIZ/util/snapshot-vm.sh" \
    "$RAIZ/util/atualizar-host.sh" "$RAIZ/util/backup-vm.sh"

exigir_texto etapas/14-working-disk.sh 'validar_working_disk_montado'
for texto_proibido in sudo mkdir fstab rsync xdg-user-dir; do
    rejeitar_texto etapas/14-working-disk.sh "$texto_proibido"
done
if grep -Eq -- '(^|[;&|[:space:]])mount([[:space:]]|$)' "$RAIZ/etapas/14-working-disk.sh"; then
    falha 'etapas/14-working-disk.sh ainda executa mount'
fi
if grep -Eq -- 'find[[:space:]].*-delete' "$RAIZ/etapas/14-working-disk.sh"; then
    falha 'etapas/14-working-disk.sh ainda contém remoção via find -delete'
fi
exigir_texto util/backup-vm.sh 'qemu-img check'
# I3: o campo backing-filename do JSON do qemu-img é lido pelo core Python. O
# utilitário continua obrigado a exigir ausência de backing chain e a nomear o
# arquivo encontrado no diagnóstico.
exigir_texto util/backup-vm.sh 'qemu-image-inspect'
exigir_texto util/backup-vm.sh 'backing file detectado'
exigir_texto libexec/passthrough_core/qemu_image.py 'full-backing-filename'
exigir_texto libexec/passthrough_core/qemu_image.py 'backing-filename'
exigir_texto util/snapshot-vm.sh 'vm_desligada "$VM_NAME" || falhar'
exigir_texto util/snapshot-vm.sh 'SNAPSHOT_DISKSPECS+=(--diskspec "$alvo,snapshot=$modo")'
rejeitar_texto util/snapshot-vm.sh '--disk-only'
exigir_texto util/atualizar-host.sh 'CONTINUAR SEM SNAPSHOT'
exigir_texto util/atualizar-host.sh 'util/snapshot-vm.sh'
rejeitar_texto util/atualizar-host.sh 'snapshot-create-as'
exigir_texto etapas/12-pacotes-base.sh 'acl)'
exigir_texto etapas/11-driver-nvidia.sh 'ubuntu-drivers devices'
exigir_texto etapas/61-airlock.sh 'ssh-keygen -l -f'
exigir_texto etapas/61-airlock.sh 'airlock_rollback()'
exigir_texto etapas/61-airlock.sh 'classificar_airlock_working_disk'
exigir_texto etapas/61-airlock.sh 'readlink -m -- "$AIRLOCK_TRANSITO"'
exigir_texto etapas/70-trim-discard.sh 'classificar_destino_backups'
exigir_texto util/backup-vm.sh 'classificar_destino_backup "$alvo"'

echo "AUDIT_SAFETY_TESTS_OK"
