#!/bin/bash
# ============================================================================
# util/backup-vm.sh - Capítulo 25: backup real do disco da VM
# ============================================================================
# Desliga a VM graciosamente (ACPI, aguardando de verdade), copia o QCOW2
# para /mnt/docs4/backups-vm com data no nome e valida a cópia.
# Snapshot NÃO substitui isto: o backup vive em outro disco físico (HD2).
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf
exigir_nao_root
exigir_sudo
exigir_conf VM_NAME QCOW2_PATH
DOCS4="${DOCS4_MONTAGEM:-/mnt/docs4}"
DESTINO_DIR="${BACKUPS_VM_DIR:-$DOCS4/backups-vm}"

titulo "Backup da VM $VM_NAME"
if [[ "$DESTINO_DIR" == "$DOCS4"/* ]]; then
    mountpoint -q "$DOCS4" || falhar "HD2 não montado em $DOCS4 (destino dos backups)."
fi
sudo mkdir -p "$DESTINO_DIR"

if ! vm_desligada "$VM_NAME"; then
    info "VM em execução; solicitando desligamento gracioso (ACPI)..."
    confirmar "Desligar a VM $VM_NAME agora para o backup?" || falhar "Cancelado."
    $VIRSH shutdown "$VM_NAME"
    LIMITE=300; PASSADO=0
    while ! vm_desligada "$VM_NAME"; do
        [ "$PASSADO" -ge "$LIMITE" ] && falhar "VM não desligou em ${LIMITE}s. NÃO uso 'destroy' automaticamente; desligue pelo Windows e rode de novo."
        sleep 5; PASSADO=$((PASSADO+5))
        echo -n "."
    done
    echo
    ok "VM desligada."
fi

# Espaço disponível vs tamanho físico atual do qcow2
TAM_ORIGEM_KB="$(du -k "$QCOW2_PATH" | cut -f1)"
info "Origem: $QCOW2_PATH ($(du -h "$QCOW2_PATH" | cut -f1) físicos)"
df -h "$DESTINO_DIR" | sed 's/^/  /'
LIVRE_KB="$(df -k --output=avail "$DESTINO_DIR" 2>/dev/null | tail -n1 | tr -dc '0-9')"
if [ -n "$LIVRE_KB" ] && [ "$LIVRE_KB" -lt "$TAM_ORIGEM_KB" ]; then
    falhar "Espaço insuficiente em $DESTINO_DIR: $((LIVRE_KB / 1024)) MiB livres para $((TAM_ORIGEM_KB / 1024)) MiB necessários."
fi

DESTINO="$DESTINO_DIR/Windows11-backup-$(date +%Y%m%d).qcow2"
[ -e "$DESTINO" ] && { confirmar "Já existe $DESTINO. Sobrescrever?" || falhar "Cancelado."; }

info "Copiando (rsync com progresso; pode demorar)..."
sudo rsync -avh --progress "$QCOW2_PATH" "$DESTINO"

info "Validando a cópia (qemu-img info)..."
if qemu-img info "$DESTINO" >/dev/null 2>&1; then
    ok "Backup íntegro: $DESTINO"
else
    falhar "qemu-img não leu o backup; NÃO confie nesta cópia."
fi

echo
info "Backups existentes:"
ls -lh "$DESTINO_DIR" | sed 's/^/  /'
aviso "Lembrete do manual: isso protege contra falha do NVMe, não contra eventos"
aviso "que atinjam o computador inteiro; mantenha também uma cópia externa/offsite."
