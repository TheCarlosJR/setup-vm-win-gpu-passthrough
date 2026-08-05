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
nome_vm_valido "$VM_NAME" || falhar "VM_NAME inválido: '$VM_NAME'."
exigir_comando virsh python3

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
    local xml mapa alvo modo extra
    SNAPSHOT_ERRO=""
    SNAPSHOT_DISKSPECS=()
    xml="$($VIRSH dumpxml --inactive "$VM_NAME" 2>/dev/null)" \
        || { SNAPSHOT_ERRO="Não foi possível ler o XML inativo de $VM_NAME."; return 1; }
    if ! mapa="$(python3 - "$QCOW2_PATH" 3<<< "$xml" 2>&1 <<'PY'
import os
import re
import sys
import xml.etree.ElementTree as ET

qcow2 = sys.argv[1]
try:
    with os.fdopen(3, encoding='utf-8') as stream:
        root = ET.parse(stream).getroot()
except (OSError, ET.ParseError) as exc:
    raise SystemExit(f'XML inativo inválido: {exc}')

dispositivos = []
principais = 0
alvos = set()
for disk in root.findall('./devices/disk'):
    if disk.get('device') != 'disk':
        continue
    target = disk.find('target')
    source = disk.find('source')
    driver = disk.find('driver')
    alvo = '' if target is None else target.get('dev', '')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+', alvo):
        raise SystemExit(f'alvo de disco inválido ou ausente no XML: {alvo!r}')
    if alvo in alvos:
        raise SystemExit(f'alvo de disco duplicado no XML: {alvo}')
    alvos.add(alvo)
    arquivo = '' if source is None else source.get('file', '')
    formato = '' if driver is None else driver.get('type', '')
    if arquivo == qcow2:
        principais += 1
        if formato != 'qcow2':
            raise SystemExit(f'o disco configurado {qcow2} não usa driver qcow2')
        dispositivos.append((alvo, 'internal'))
    else:
        dispositivos.append((alvo, 'no'))

if principais != 1:
    raise SystemExit(
        f'o XML precisa usar QCOW2_PATH={qcow2} exatamente uma vez como disco ativo; '
        'um overlay externo ou configuração divergente exige consolidação/revisão manual'
    )
if not dispositivos:
    raise SystemExit('nenhum disco de dados foi encontrado no XML inativo')
for alvo, modo in dispositivos:
    print(f'{alvo}|{modo}')
PY
)"; then
        SNAPSHOT_ERRO="$mapa"
        return 1
    fi
    while IFS='|' read -r alvo modo extra; do
        [ -n "$alvo" ] && [ -z "$extra" ] && [[ "$modo" = internal || "$modo" = no ]] \
            || { SNAPSHOT_ERRO="Mapa de discos inválido ao preparar o snapshot."; return 1; }
        SNAPSHOT_DISKSPECS+=(--diskspec "$alvo,snapshot=$modo")
    done <<< "$mapa"
    [ "${#SNAPSHOT_DISKSPECS[@]}" -gt 0 ] \
        || { SNAPSHOT_ERRO="Nenhuma especificação de disco foi preparada."; return 1; }
}

SNAPSHOT_ALVO_INTERNO=""
validar_snapshot_interno() {
    local nome="$1" xml resultado
    SNAPSHOT_ERRO=""
    SNAPSHOT_ALVO_INTERNO=""
    xml="$($VIRSH snapshot-dumpxml "$VM_NAME" "$nome" 2>/dev/null)" \
        || { SNAPSHOT_ERRO="Snapshot '$nome' não existe ou seus metadados não puderam ser lidos."; return 1; }
    if ! resultado="$(python3 - 3<<< "$xml" 2>&1 <<'PY'
import os
import sys
import xml.etree.ElementTree as ET

try:
    with os.fdopen(3, encoding='utf-8') as stream:
        root = ET.parse(stream).getroot()
except (OSError, ET.ParseError) as exc:
    raise SystemExit(f'XML do snapshot inválido: {exc}')

disks = root.findall('./disks/disk')
externos = [d.get('name', '?') for d in disks if d.get('snapshot') == 'external']
internos = [d.get('name', '') for d in disks if d.get('snapshot') == 'internal']
desconhecidos = [d.get('snapshot', '') for d in disks if d.get('snapshot') not in {'internal', 'no'}]
if externos:
    raise SystemExit(
        'snapshot externo não é compatível com reverter/apagar automaticamente; '
        f'discos externos: {", ".join(externos)}'
    )
if desconhecidos:
    raise SystemExit(f'tipos de snapshot não reconhecidos: {", ".join(desconhecidos)}')
if len(internos) != 1 or not internos[0]:
    raise SystemExit(f'esperado exatamente um disco interno; encontrados: {len(internos)}')
print(internos[0])
PY
)"; then
        SNAPSHOT_ERRO="$resultado"
        return 1
    fi
    SNAPSHOT_ALVO_INTERNO="$resultado"
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
