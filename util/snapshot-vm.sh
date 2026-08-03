#!/bin/bash
# ============================================================================
# util/snapshot-vm.sh - operações de snapshot da VM pelo libvirt
# ============================================================================
# Uso:
#   snapshot-vm.sh criar [nome] [descricao]
#   snapshot-vm.sh listar
#   snapshot-vm.sh reverter <nome>
#   snapshot-vm.sh apagar <nome>
# Sem argumento, lista os snapshots e imprime este uso.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf
exigir_conf VM_NAME

mostrar_uso() {
    cat <<'EOF'
Uso:
  bash util/snapshot-vm.sh criar [nome] [descricao]
  bash util/snapshot-vm.sh listar
  bash util/snapshot-vm.sh reverter <nome>
  bash util/snapshot-vm.sh apagar <nome>
EOF
}

info "Finalidade: criar, listar, reverter ou apagar snapshots que o libvirt associar à VM '$VM_NAME'."
info "Pré-requisitos: domínio existente, acesso ao libvirt e armazenamento compatível com o tipo de snapshot resultante."
info "Efeito: criar/reverter/apagar altera estado ou metadados da VM; listar é somente leitura."
info "Política de consistência: criar e reverter exigem a VM desligada; a criação usa snapshot de disco atômico."
aviso "Riscos: reverter descarta estado posterior; apagar remove um ponto de retorno; acúmulo pode degradar I/O e ocupar espaço."
info "Não abrange: HD1 físico, backup externo, consistência de aplicações nem garantia restaurável de XML, NVRAM ou TPM."
info "Retorno/reboot: falhas do virsh/cancelamento retornam erro; o script não desliga a VM nem reinicia VM ou host automaticamente."

ACAO="${1:-listar}"
case "$ACAO" in
    criar)
        NOME="${2:-snap-$(date +%Y%m%d-%H%M%S)}"
        DESC="${3:-Snapshot criado por util/snapshot-vm.sh}"
        vm_desligada "$VM_NAME" || falhar "A VM precisa estar desligada para criar um snapshot offline consistente."
        $VIRSH snapshot-create-as "$VM_NAME" "$NOME" "$DESC" --disk-only --atomic
        ok "Snapshot offline de disco '$NOME' criado pelo libvirt; isso não substitui backup."
        ;;
    listar)
        $VIRSH snapshot-list "$VM_NAME"
        if [ "$#" -eq 0 ]; then
            echo
            mostrar_uso
        fi
        ;;
    reverter)
        NOME="${2:?Informe o nome do snapshot (veja: snapshot-vm.sh listar)}"
        aviso "Reverter descarta TODAS as alterações feitas depois de '$NOME'."
        vm_desligada "$VM_NAME" || falhar "A VM precisa estar desligada antes de reverter um snapshot."
        confirmar "Reverter $VM_NAME para '$NOME'?" || falhar "Cancelado."
        $VIRSH snapshot-revert "$VM_NAME" "$NOME"
        ok "Revertido para '$NOME'."
        ;;
    apagar)
        NOME="${2:?Informe o nome do snapshot}"
        confirmar "Apagar o snapshot '$NOME'? A remoção não tem desfazer e o efeito no storage depende do tipo de snapshot." || falhar "Cancelado."
        $VIRSH snapshot-delete "$VM_NAME" "$NOME"
        ok "Snapshot '$NOME' removido pelo libvirt."
        ;;
    *)
        falhar "Ação desconhecida: $ACAO (use: criar | listar | reverter | apagar)"
        ;;
esac
