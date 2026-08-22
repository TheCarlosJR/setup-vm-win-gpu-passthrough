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
SCRIPT_VERSION="1.0.0"
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf
exigir_conf VM_NAME
nome_vm_valido "$VM_NAME" || falhar "VM_NAME inválido: '$VM_NAME'."
exigir_comando virsh python3
# A disponibilidade do core NÃO é sondada aqui: neste utilitário a guarda de
# plataforma (guard_mutation) fica dentro de cada ação, e sondar o core antes
# dela criaria um temporário antes do primeiro ponto de recusa, contra a regra
# de REQ-GUARD. A ponte é fail-closed: a primeira chamada real devolve o código
# 69 com diagnóstico acionável.

mostrar_uso() {
    cat <<'EOF'
Uso:
  bash util/snapshot-vm.sh criar [nome] [descricao]
  bash util/snapshot-vm.sh listar
  bash util/snapshot-vm.sh reverter <nome>
  bash util/snapshot-vm.sh apagar <nome>
EOF
}

nome_snapshot_valido() {
    [[ "${1:-}" =~ ^[[:alnum:]_][[:alnum:]_.-]{0,127}$ ]]
}

SNAPSHOT_ERRO=""
SNAPSHOT_DISKSPECS=()
preparar_diskspecs_internos() {
    # O plano de diskspec vem do core Python: cardinalidade do disco
    # configurado, driver exigido e exclusão explícita dos demais discos. O XML
    # trafega por arquivo controlado 0600, nunca por argv.
    local indice total alvo modo nome_alvo nome_modo
    local -a permitidas=(
        "${CORE_PARES_ENVELOPE[@]}" DISK_COUNT 'DISK_#_TARGET' 'DISK_#_MODE'
    )
    local -a payload=()
    SNAPSHOT_ERRO=""
    SNAPSHOT_DISKSPECS=()
    XML_CONTEUDO="$($VIRSH dumpxml --inactive "$VM_NAME" 2>/dev/null)" \
        || { SNAPSHOT_ERRO="Não foi possível ler o XML inativo de $VM_NAME."; return 1; }
    payload=(xml "$XML_CONTEUDO" qcow2_path "$QCOW2_PATH")
    if ! python_core_pares_payload permitidas SNAP_ domain-disk-snapshot-plan payload \
            2>/dev/null; then
        SNAPSHOT_ERRO="$(_core_diagnostico 'XML inativo inválido para snapshot.')"
        return 1
    fi
    total="$SNAP_DISK_COUNT"
    [[ "$total" =~ ^[0-9]+$ ]] && [ "$total" -gt 0 ] \
        || { SNAPSHOT_ERRO="Mapa de discos inválido ao preparar o snapshot."; return 1; }
    for (( indice = 0; indice < total; indice++ )); do
        # Expansão indireta por nome; nunca eval, nunca código do Python.
        nome_alvo="SNAP_DISK_${indice}_TARGET"
        nome_modo="SNAP_DISK_${indice}_MODE"
        alvo="${!nome_alvo:-}"
        modo="${!nome_modo:-}"
        [ -n "$alvo" ] && [[ "$modo" = internal || "$modo" = no ]] \
            || { SNAPSHOT_ERRO="Mapa de discos inválido ao preparar o snapshot."; return 1; }
        SNAPSHOT_DISKSPECS+=(--diskspec "$alvo,snapshot=$modo")
    done
    [ "${#SNAPSHOT_DISKSPECS[@]}" -gt 0 ] \
        || { SNAPSHOT_ERRO="Nenhuma especificação de disco foi preparada."; return 1; }
}

SNAPSHOT_ALVO_INTERNO=""
validar_snapshot_interno() {
    local nome="$1"
    local -a permitidas=("${CORE_PARES_ENVELOPE[@]}" INTERNAL_TARGET DISK_COUNT)
    local -a payload=()
    SNAPSHOT_ERRO=""
    SNAPSHOT_ALVO_INTERNO=""
    XML_CONTEUDO="$($VIRSH snapshot-dumpxml "$VM_NAME" "$nome" 2>/dev/null)" \
        || { SNAPSHOT_ERRO="Snapshot '$nome' não existe ou seus metadados não puderam ser lidos."; return 1; }
    payload=(xml "$XML_CONTEUDO")
    if ! python_core_pares_payload permitidas SNAPINT_ domain-snapshot-internal payload \
            2>/dev/null; then
        SNAPSHOT_ERRO="$(_core_diagnostico 'XML do snapshot inválido.')"
        return 1
    fi
    SNAPSHOT_ALVO_INTERNO="$SNAPINT_INTERNAL_TARGET"
    [ -n "$SNAPSHOT_ALVO_INTERNO" ] \
        || { SNAPSHOT_ERRO="O core não devolveu o alvo interno do snapshot."; return 1; }
}

info "Finalidade: criar, listar, reverter ou apagar snapshots internos do QCOW2 principal da VM '$VM_NAME'."
info "Pré-requisitos: domínio existente, VM desligada para criar/reverter e QCOW2_PATH apontando para o disco ativo no XML."
info "Efeito: o snapshot fica dentro do QCOW2 principal; HD1 físico e todos os demais discos são explicitamente excluídos."
info "Política de consistência: criar e reverter exigem a VM desligada; somente metadados comprovadamente internos são aceitos."
aviso "Riscos: reverter descarta estado posterior; apagar remove um ponto de retorno; snapshots acumulados ocupam espaço no mesmo disco."
info "Não abrange: HD1 físico, backup externo, consistência de aplicações nem garantia restaurável de XML, NVRAM ou TPM."
info "Snapshots externos legados são recusados: consolide a cadeia manualmente ou restaure um backup antes de gerenciá-los."
info "Retorno/reboot: falhas do virsh/cancelamento retornam erro; o script não desliga a VM nem reinicia VM ou host automaticamente."

ACAO="${1:-listar}"
case "$ACAO" in
    criar)
        guard_mutation snapshot.manage || exit 1
        NOME="${2:-snap-$(date +%Y%m%d-%H%M%S)}"
        DESC="${3:-Snapshot interno criado por util/snapshot-vm.sh}"
        nome_snapshot_valido "$NOME" || falhar "Nome de snapshot inválido: '$NOME'. Use letras, números, ponto, hífen ou sublinhado."
        exigir_conf QCOW2_PATH
        caminho_absoluto_seguro "$QCOW2_PATH" || falhar "QCOW2_PATH inseguro: '$QCOW2_PATH'."
        vm_desligada "$VM_NAME" || falhar "A VM precisa estar desligada para criar um snapshot interno offline consistente."
        preparar_diskspecs_internos || falhar "$SNAPSHOT_ERRO"
        $VIRSH snapshot-create-as "$VM_NAME" --name "$NOME" --description "$DESC" \
            --atomic "${SNAPSHOT_DISKSPECS[@]}"
        validar_snapshot_interno "$NOME" \
            || falhar "Snapshot criado, mas a pós-condição interna não foi comprovada: $SNAPSHOT_ERRO"
        ok "Snapshot interno offline '$NOME' criado em $SNAPSHOT_ALVO_INTERNO; os demais discos foram excluídos."
        ;;
    listar)
        $VIRSH snapshot-list "$VM_NAME"
        if [ "$#" -eq 0 ]; then
            echo
            mostrar_uso
        fi
        ;;
    reverter)
        guard_mutation snapshot.manage || exit 1
        NOME="${2:-}"
        [ -n "$NOME" ] || falhar "Informe o nome do snapshot (veja: snapshot-vm.sh listar)."
        nome_snapshot_valido "$NOME" || falhar "Nome de snapshot inválido: '$NOME'."
        validar_snapshot_interno "$NOME" || falhar "$SNAPSHOT_ERRO"
        aviso "Reverter descarta TODAS as alterações do QCOW2 principal feitas depois de '$NOME'."
        vm_desligada "$VM_NAME" || falhar "A VM precisa estar desligada antes de reverter um snapshot."
        confirmar "Reverter $VM_NAME para o snapshot interno '$NOME'?" || falhar "Cancelado."
        $VIRSH snapshot-revert "$VM_NAME" "$NOME"
        ok "QCOW2 principal revertido para '$NOME'."
        ;;
    apagar)
        guard_mutation snapshot.manage || exit 1
        NOME="${2:-}"
        [ -n "$NOME" ] || falhar "Informe o nome do snapshot."
        nome_snapshot_valido "$NOME" || falhar "Nome de snapshot inválido: '$NOME'."
        validar_snapshot_interno "$NOME" || falhar "$SNAPSHOT_ERRO"
        confirmar "Apagar o snapshot interno '$NOME'? A remoção não tem desfazer." || falhar "Cancelado."
        $VIRSH snapshot-delete "$VM_NAME" "$NOME"
        ok "Snapshot interno '$NOME' removido pelo libvirt."
        ;;
    *)
        falhar "Ação desconhecida: $ACAO (use: criar | listar | reverter | apagar)"
        ;;
esac
