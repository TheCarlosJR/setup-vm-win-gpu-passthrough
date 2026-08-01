#!/bin/bash
# ============================================================================
# util/snapshot-vm.sh - Capítulo 25: snapshots QCOW2 (pontos de restauração)
# ============================================================================
# Uso:
#   snapshot-vm.sh criar [nome] [descricao]
#   snapshot-vm.sh listar
#   snapshot-vm.sh reverter <nome>
#   snapshot-vm.sh apagar <nome>
#
# Lembrete do manual: snapshot NÃO é backup (vive no mesmo arquivo/NVMe) e
# snapshots acumulados degradam I/O: apague os temporários após validar.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf
exigir_conf VM_NAME

ACAO="${1:-listar}"
case "$ACAO" in
    criar)
        NOME="${2:-snap-$(date +%Y%m%d-%H%M%S)}"
        DESC="${3:-Snapshot criado por util/snapshot-vm.sh}"
        $VIRSH snapshot-create-as "$VM_NAME" "$NOME" "$DESC"
        ok "Snapshot '$NOME' criado."
        ;;
    listar)
        $VIRSH snapshot-list "$VM_NAME"
        ;;
    reverter)
        NOME="${2:?Informe o nome do snapshot (veja: snapshot-vm.sh listar)}"
        aviso "Reverter descarta TODAS as alterações feitas depois de '$NOME'."
        vm_desligada "$VM_NAME" || aviso "VM em execução: reverter snapshot apenas-disco exige VM desligada."
        confirmar "Reverter $VM_NAME para '$NOME'?" || falhar "Cancelado."
        $VIRSH snapshot-revert "$VM_NAME" "$NOME"
        ok "Revertido para '$NOME'."
        ;;
    apagar)
        NOME="${2:?Informe o nome do snapshot}"
        confirmar "Apagar o snapshot '$NOME' (consolida as alterações)?" || falhar "Cancelado."
        $VIRSH snapshot-delete "$VM_NAME" "$NOME"
        ok "Snapshot '$NOME' removido."
        ;;
    *)
        falhar "Ação desconhecida: $ACAO (use: criar | listar | reverter | apagar)"
        ;;
esac
