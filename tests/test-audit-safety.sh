#!/bin/bash
# Testes sem efeitos no host para os contratos de segurança da auditoria.
set -euo pipefail
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

falha() { echo "FALHA: $*" >&2; exit 1; }
exigir_texto() {
    local arquivo="$1" texto="$2"
    grep -Fq -- "$texto" "$RAIZ/$arquivo" || falha "$arquivo não contém: $texto"
}

bash -n "$RAIZ/etapas/11-driver-nvidia.sh" "$RAIZ/etapas/12-pacotes-base.sh" \
    "$RAIZ/etapas/14-docs4.sh" "$RAIZ/etapas/61-airlock.sh" \
    "$RAIZ/util/snapshot-vm.sh" "$RAIZ/util/atualizar-host.sh" "$RAIZ/util/backup-vm.sh"

exigir_texto etapas/14-docs4.sh 'rsync -a --checksum --itemize-changes --dry-run'
exigir_texto util/backup-vm.sh 'qemu-img check'
exigir_texto util/snapshot-vm.sh 'vm_desligada "$VM_NAME" || falhar'
exigir_texto util/snapshot-vm.sh '--disk-only --atomic'
exigir_texto util/atualizar-host.sh 'CONTINUAR SEM SNAPSHOT'
exigir_texto etapas/12-pacotes-base.sh 'rsync)'
exigir_texto etapas/11-driver-nvidia.sh 'ubuntu-drivers devices'
exigir_texto etapas/61-airlock.sh 'ssh-keygen -l -f'
exigir_texto etapas/61-airlock.sh 'airlock_rollback()'

echo "AUDIT_SAFETY_TESTS_OK"
