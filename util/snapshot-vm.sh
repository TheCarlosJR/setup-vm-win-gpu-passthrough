#!/bin/bash
# ============================================================================
# util/snapshot-vm.sh - Capítulo 25: snapshots internos offline do disco C:
# ============================================================================
# Uso:
#   snapshot-vm.sh criar [nome] [descricao]
#   snapshot-vm.sh listar
#   snapshot-vm.sh reverter <nome>
#   snapshot-vm.sh apagar <nome>
#
# O snapshot é interno e contém somente o QCOW2 do C:. O HD1 físico e todos os
# demais discos ficam explicitamente com snapshot=no. Snapshot NÃO é backup:
# ele permanece no mesmo arquivo/NVMe e snapshots acumulados degradam I/O.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf
exigir_conf VM_NAME QCOW2_PATH
exigir_comando xmlstarlet qemu-img python3

TMP_DIR=""
XML_VM=""
QCOW2_TARGET=""
TOTAL_DISCOS=0
declare -a ALVOS_DISCOS=()

limpar() {
    local status="$?"
    trap - EXIT
    if [ -n "$TMP_DIR" ] && [[ "$TMP_DIR" == /tmp/snapshot-vm.* ]]; then
        rm -rf -- "$TMP_DIR"
    fi
    exit "$status"
}
trap limpar EXIT
trap 'exit 1' HUP INT TERM

uso() {
    falhar "Uso: $0 criar [nome] [descricao] | listar | reverter <nome> | apagar <nome>"
}

validar_nome_simples() {
    local tipo="$1" valor="${2:-}"
    [ "${#valor}" -le 128 ] && [[ "$valor" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
        || falhar "$tipo inválido: use de 1 a 128 caracteres ASCII (letras, números, ponto, '_' ou '-')."
}

validar_descricao() {
    local descricao="$1"
    [ -n "$descricao" ] && [ "${#descricao}" -le 240 ] \
        && [[ "$descricao" != *[[:cntrl:]]* ]] \
        || falhar "Descrição inválida: use de 1 a 240 caracteres sem controles ou quebras de linha."
}

estado_vm() {
    LC_ALL=C $VIRSH domstate "$VM_NAME" 2>/dev/null
}

exigir_vm_existente() {
    LC_ALL=C $VIRSH dominfo "$VM_NAME" >/dev/null 2>&1 \
        || falhar "A VM '$VM_NAME' não existe ou não pôde ser consultada."
}

exigir_estado_shut_off() {
    local estado
    estado="$(estado_vm)" \
        || falhar "Não foi possível consultar o estado da VM '$VM_NAME'."
    [ "$estado" = "shut off" ] \
        || falhar "A VM '$VM_NAME' deve estar exatamente 'shut off'; estado encontrado: ${estado:-<vazio>}."
}

xml_valor() {
    local arquivo="$1" xpath="$2"
    xmlstarlet sel -t -v "$xpath" "$arquivo"
}

xml_contagem() {
    local arquivo="$1" xpath="$2"
    xml_valor "$arquivo" "count($xpath)"
}

validar_imagem_sem_backing() {
    local json
    [ -f "$QCOW2_PATH" ] && [ ! -L "$QCOW2_PATH" ] \
        || falhar "O disco C: deve ser um arquivo regular, não-symlink: $QCOW2_PATH"
    json="$(LC_ALL=C qemu-img info --output=json "$QCOW2_PATH")" \
        || falhar "qemu-img não conseguiu inspecionar $QCOW2_PATH."
    python3 -c '
import json, sys
try:
    image = json.load(sys.stdin)
except Exception:
    raise SystemExit(2)
if image.get("format") != "qcow2":
    raise SystemExit(3)
for key, value in image.items():
    if key.startswith("backing-") or key == "full-backing-filename":
        if value not in (None, ""):
            raise SystemExit(4)
' <<< "$json" \
        || falhar "O disco C: não é qcow2 standalone ou possui backing file/chain externa: $QCOW2_PATH"
}

contar_snapshot_na_imagem() {
    local nome="$1" json
    json="$(LC_ALL=C qemu-img info --output=json "$QCOW2_PATH")" || return 1
    python3 -c '
import json, sys
name = sys.argv[1]
try:
    image = json.load(sys.stdin)
except Exception:
    raise SystemExit(2)
print(sum(1 for item in image.get("snapshots", []) if item.get("name") == name))
' "$nome" <<< "$json"
}

carregar_e_validar_xml_vm() {
    local total_qcow2 blocos_invalidos i alvo origem tipo

    LC_ALL=C $VIRSH dumpxml --inactive "$VM_NAME" > "$XML_VM" \
        || falhar "Falha ao obter o XML inativo de '$VM_NAME'."
    xmlstarlet val -q "$XML_VM" \
        || falhar "O XML inativo de '$VM_NAME' é inválido."

    total_qcow2="$(xml_contagem "$XML_VM" "/domain/devices/disk[@device='disk' and @type='file' and driver/@type='qcow2']")" \
        || falhar "Falha ao contar discos QCOW2 no XML."
    [ "$total_qcow2" = "1" ] \
        || falhar "O XML deve conter exatamente um disco QCOW2 file/device=disk; encontrados: $total_qcow2."

    origem="$(xml_valor "$XML_VM" "/domain/devices/disk[@device='disk' and @type='file' and driver/@type='qcow2'][1]/source/@file")" \
        || falhar "Falha ao localizar a origem do único QCOW2."
    [ "$origem" = "$QCOW2_PATH" ] \
        || falhar "O único QCOW2 da VM é '$origem', mas QCOW2_PATH é '$QCOW2_PATH'."
    [ "$(xml_contagem "$XML_VM" "/domain/devices/disk[@device='disk' and @type='file' and driver/@type='qcow2'][1]/source[@file]")" = "1" ] \
        || falhar "O único QCOW2 deve ter exatamente uma origem file."

    QCOW2_TARGET="$(xml_valor "$XML_VM" "/domain/devices/disk[@device='disk' and @type='file' and driver/@type='qcow2'][1]/target/@dev")" \
        || falhar "Falha ao localizar o target do QCOW2."
    [[ "$QCOW2_TARGET" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
        || falhar "Target inválido para o disco C: '$QCOW2_TARGET'."
    [ "$(xml_contagem "$XML_VM" "/domain/devices/disk[@device='disk' and @type='file' and driver/@type='qcow2'][1]/target[@dev]")" = "1" ] \
        || falhar "O único QCOW2 deve ter exatamente um target."

    blocos_invalidos="$(xml_contagem "$XML_VM" "/domain/devices/disk[@device='disk' and @type='block' and not(@snapshot='no')]")" \
        || falhar "Falha ao validar discos físicos no XML."
    [ "$blocos_invalidos" = "0" ] \
        || falhar "Todo disco físico block/device=disk deve declarar snapshot='no'; inválidos: $blocos_invalidos."

    TOTAL_DISCOS="$(xml_contagem "$XML_VM" "/domain/devices/disk[@device='disk']")" \
        || falhar "Falha ao contar discos da VM."
    [[ "$TOTAL_DISCOS" =~ ^[1-9][0-9]*$ ]] \
        || falhar "A VM não possui uma lista válida de discos device=disk."
    ALVOS_DISCOS=()
    for ((i = 1; i <= TOTAL_DISCOS; i++)); do
        alvo="$(xml_valor "$XML_VM" "/domain/devices/disk[@device='disk'][$i]/target/@dev")" \
            || falhar "Falha ao ler target do disco $i."
        tipo="$(xml_valor "$XML_VM" "/domain/devices/disk[@device='disk'][$i]/@type")" \
            || falhar "Falha ao ler tipo do disco $i."
        [[ "$alvo" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
            || falhar "Target inseguro no disco $i: '$alvo'."
        [ -n "$tipo" ] && [[ "$tipo" != *[[:cntrl:]]* ]] \
            || falhar "Tipo inválido no disco $i."
        if [[ " ${ALVOS_DISCOS[*]} " == *" $alvo "* ]]; then
            falhar "Target de disco duplicado no XML: $alvo"
        fi
        ALVOS_DISCOS+=("$alvo")
    done
    [[ " ${ALVOS_DISCOS[*]} " == *" $QCOW2_TARGET "* ]] \
        || falhar "O target do QCOW2 não pertence à lista validada de discos."

    validar_imagem_sem_backing
}

listar_nomes_snapshots() {
    LC_ALL=C $VIRSH snapshot-list "$VM_NAME" --name
}

snapshot_metadado_existe() {
    local procurado="$1" nomes linha
    nomes="$(listar_nomes_snapshots)" \
        || falhar "Não foi possível listar os snapshots de '$VM_NAME'."
    while IFS= read -r linha; do
        [ "$linha" = "$procurado" ] && return 0
    done <<< "$nomes"
    return 1
}

validar_snapshot_metadado() {
    local nome="$1" xml_snapshot="$TMP_DIR/snapshot.xml"
    local memoria internos invalidos quantidade i alvo modo esperado encontrado
    local -A modos=()

    LC_ALL=C $VIRSH snapshot-dumpxml "$VM_NAME" "$nome" > "$xml_snapshot" \
        || falhar "Não foi possível ler os metadados do snapshot '$nome'."
    xmlstarlet val -q "$xml_snapshot" \
        || falhar "Metadados XML inválidos no snapshot '$nome'."
    [ "$(xml_valor "$xml_snapshot" "/domainsnapshot/name")" = "$nome" ] \
        || falhar "O nome retornado nos metadados do snapshot diverge de '$nome'."

    memoria="$(xml_valor "$xml_snapshot" "/domainsnapshot/memory/@snapshot")" \
        || falhar "O snapshot '$nome' não declara o estado de memória."
    [ "$memoria" = "no" ] \
        || falhar "O snapshot '$nome' captura memória; somente snapshots offline sem memória são aceitos."
    internos="$(xml_contagem "$xml_snapshot" "/domainsnapshot/disks/disk[@snapshot='internal']")" \
        || falhar "Falha ao validar discos internos de '$nome'."
    [ "$internos" = "1" ] \
        || falhar "O snapshot '$nome' deve conter exatamente um disco interno; encontrados: $internos."
    invalidos="$(xml_contagem "$xml_snapshot" "/domainsnapshot/disks/disk[not(@snapshot='internal') and not(@snapshot='no')]")" \
        || falhar "Falha ao validar exclusões de discos em '$nome'."
    [ "$invalidos" = "0" ] \
        || falhar "O snapshot '$nome' contém modo de disco diferente de internal/no."
    quantidade="$(xml_contagem "$xml_snapshot" "/domainsnapshot/disks/disk")" \
        || falhar "Falha ao contar discos de '$nome'."
    [ "$quantidade" = "$TOTAL_DISCOS" ] \
        || falhar "O snapshot '$nome' não declara todos os discos; esperados $TOTAL_DISCOS, encontrados $quantidade."

    for ((i = 1; i <= quantidade; i++)); do
        alvo="$(xml_valor "$xml_snapshot" "/domainsnapshot/disks/disk[$i]/@name")" \
            || falhar "Falha ao ler o disco $i do snapshot '$nome'."
        modo="$(xml_valor "$xml_snapshot" "/domainsnapshot/disks/disk[$i]/@snapshot")" \
            || falhar "Falha ao ler o modo do disco $i do snapshot '$nome'."
        [[ "$alvo" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
            || falhar "Target inseguro nos metadados do snapshot '$nome': '$alvo'."
        [ -z "${modos[$alvo]+definido}" ] \
            || falhar "Target duplicado nos metadados do snapshot '$nome': $alvo"
        modos[$alvo]="$modo"
    done
    for esperado in "${ALVOS_DISCOS[@]}"; do
        [ -n "${modos[$esperado]+definido}" ] \
            || falhar "O snapshot '$nome' não declara o disco '$esperado'."
        if [ "$esperado" = "$QCOW2_TARGET" ]; then
            encontrado="internal"
        else
            encontrado="no"
        fi
        [ "${modos[$esperado]}" = "$encontrado" ] \
            || falhar "Modo inesperado para '$esperado' no snapshot '$nome': ${modos[$esperado]} (esperado $encontrado)."
    done
}

validar_snapshot_presente() {
    local nome="$1" quantidade
    snapshot_metadado_existe "$nome" \
        || falhar "Snapshot '$nome' não existe nos metadados do libvirt."
    validar_snapshot_metadado "$nome"
    quantidade="$(contar_snapshot_na_imagem "$nome")" \
        || falhar "Não foi possível confirmar '$nome' dentro do QCOW2."
    [ "$quantidade" = "1" ] \
        || falhar "O QCOW2 deve conter exatamente um snapshot interno chamado '$nome'; encontrados: $quantidade."
}

validar_snapshot_ausente() {
    local nome="$1" quantidade
    if snapshot_metadado_existe "$nome"; then
        falhar "Já existe metadado libvirt para o snapshot '$nome'."
    fi
    quantidade="$(contar_snapshot_na_imagem "$nome")" \
        || falhar "Não foi possível verificar duplicidade dentro do QCOW2."
    [ "$quantidade" = "0" ] \
        || falhar "Já existem $quantidade snapshots internos chamados '$nome' no QCOW2."
}

suporta_atomic() {
    local ajuda
    ajuda="$(LC_ALL=C $VIRSH help snapshot-create-as)" \
        || falhar "Não foi possível consultar as opções de snapshot-create-as."
    [[ "$ajuda" == *"--atomic"* ]]
}

criar_snapshot_interno() {
    local nome="$1" descricao="$2" alvo atual
    local -a comando

    validar_snapshot_ausente "$nome"
    exigir_estado_shut_off
    carregar_e_validar_xml_vm
    comando=(snapshot-create-as --domain "$VM_NAME" --name "$nome"
             --description "$descricao" --disk-only)
    for alvo in "${ALVOS_DISCOS[@]}"; do
        if [ "$alvo" = "$QCOW2_TARGET" ]; then
            comando+=(--diskspec "$alvo,snapshot=internal")
        else
            comando+=(--diskspec "$alvo,snapshot=no")
        fi
    done
    if suporta_atomic; then
        comando+=(--atomic)
    else
        aviso "Este virsh não oferece --atomic; a operação offline continuará sem essa garantia adicional."
    fi

    exigir_estado_shut_off
    LC_ALL=C $VIRSH "${comando[@]}" >/dev/null \
        || falhar "Falha ao criar o snapshot interno '$nome'."
    exigir_estado_shut_off
    carregar_e_validar_xml_vm
    validar_snapshot_presente "$nome"
    atual="$(LC_ALL=C $VIRSH snapshot-current "$VM_NAME" --name)" \
        || falhar "Snapshot '$nome' criado, mas o snapshot atual não pôde ser consultado."
    [ "$atual" = "$nome" ] \
        || falhar "Pós-condição falhou: snapshot atual é '$atual', esperado '$nome'."
}

novo_nome_seguranca() {
    local base tentativa i
    base="seguranca-$(date +%Y%m%d-%H%M%S)-$$"
    for ((i = 0; i < 100; i++)); do
        tentativa="$base-$i"
        if ! snapshot_metadado_existe "$tentativa" \
            && [ "$(contar_snapshot_na_imagem "$tentativa")" = "0" ]; then
            printf '%s\n' "$tentativa"
            return 0
        fi
    done
    return 1
}

validar_nome_simples "Nome da VM" "$VM_NAME"
[[ "$QCOW2_PATH" == /* ]] && [[ "$QCOW2_PATH" != *[[:cntrl:]]* ]] \
    || falhar "QCOW2_PATH deve ser absoluto e não conter controles."
exigir_vm_existente

ACAO="${1:-listar}"
case "$ACAO" in
    criar)
        [ "$#" -ge 1 ] && [ "$#" -le 3 ] || uso
        NOME="${2:-snap-$(date +%Y%m%d-%H%M%S)}"
        DESC="${3:-Snapshot interno offline criado por util/snapshot-vm.sh}"
        validar_nome_simples "Nome do snapshot" "$NOME"
        validar_descricao "$DESC"
        exigir_estado_shut_off
        TMP_DIR="$(mktemp -d -- /tmp/snapshot-vm.XXXXXX)" \
            || falhar "Não foi possível criar diretório temporário."
        chmod 0700 -- "$TMP_DIR"
        XML_VM="$TMP_DIR/domain.xml"
        carregar_e_validar_xml_vm
        info "Escopo: snapshot interno offline somente de C: ($QCOW2_PATH); HD1 físico e demais discos excluídos."
        criar_snapshot_interno "$NOME" "$DESC"
        ok "Snapshot interno '$NOME' criado e validado."
        ;;
    listar)
        [ "$#" -eq 0 ] || [ "$#" -eq 1 ] || uso
        info "Escopo dos snapshots deste utilitário: somente C: ($QCOW2_PATH), sem memória; HD1 excluído."
        listar_nomes_snapshots \
            || falhar "Não foi possível listar os snapshots de '$VM_NAME'."
        ;;
    reverter)
        [ "$#" -eq 2 ] || uso
        NOME="$2"
        validar_nome_simples "Nome do snapshot" "$NOME"
        exigir_estado_shut_off
        TMP_DIR="$(mktemp -d -- /tmp/snapshot-vm.XXXXXX)" \
            || falhar "Não foi possível criar diretório temporário."
        chmod 0700 -- "$TMP_DIR"
        XML_VM="$TMP_DIR/domain.xml"
        carregar_e_validar_xml_vm
        validar_snapshot_presente "$NOME"
        aviso "Reverter trocará todo o estado atual de C: pelo snapshot '$NOME'."
        aviso "HD1 físico está excluído; nenhuma memória da VM será restaurada."
        confirmar_digitando "REVERTER" \
            "Confirma a reversão offline de '$VM_NAME' para '$NOME'? Um snapshot de segurança único do C: atual será criado antes." \
            || falhar "Cancelado sem alterações."
        SEGURANCA="$(novo_nome_seguranca)" \
            || falhar "Não foi possível reservar um nome único para o snapshot de segurança."
        criar_snapshot_interno "$SEGURANCA" "Segurança automática antes de reverter para $NOME"
        ok "Snapshot de segurança do C: atual criado: '$SEGURANCA'."
        exigir_estado_shut_off
        carregar_e_validar_xml_vm
        validar_snapshot_presente "$NOME"
        LC_ALL=C $VIRSH snapshot-revert "$VM_NAME" "$NOME" >/dev/null \
            || falhar "Reversão falhou; o snapshot de segurança '$SEGURANCA' foi preservado."
        exigir_estado_shut_off
        carregar_e_validar_xml_vm
        validar_snapshot_presente "$NOME"
        validar_snapshot_presente "$SEGURANCA"
        ATUAL="$(LC_ALL=C $VIRSH snapshot-current "$VM_NAME" --name)" \
            || falhar "A reversão retornou sucesso, mas o snapshot atual não pôde ser consultado. Segurança: '$SEGURANCA'."
        [ "$ATUAL" = "$NOME" ] \
            || falhar "Pós-condição falhou: snapshot atual é '$ATUAL', esperado '$NOME'. Segurança: '$SEGURANCA'."
        ok "VM revertida e validada em '$NOME'. Segurança preservada em '$SEGURANCA'."
        ;;
    apagar)
        [ "$#" -eq 2 ] || uso
        NOME="$2"
        validar_nome_simples "Nome do snapshot" "$NOME"
        exigir_estado_shut_off
        TMP_DIR="$(mktemp -d -- /tmp/snapshot-vm.XXXXXX)" \
            || falhar "Não foi possível criar diretório temporário."
        chmod 0700 -- "$TMP_DIR"
        XML_VM="$TMP_DIR/domain.xml"
        carregar_e_validar_xml_vm
        validar_snapshot_presente "$NOME"
        confirmar "Apagar permanentemente o snapshot interno '$NOME' somente do C:?" \
            || falhar "Cancelado sem alterações."
        exigir_estado_shut_off
        LC_ALL=C $VIRSH snapshot-delete "$VM_NAME" "$NOME" >/dev/null \
            || falhar "Falha ao apagar o snapshot '$NOME'."
        exigir_estado_shut_off
        carregar_e_validar_xml_vm
        if snapshot_metadado_existe "$NOME"; then
            falhar "Pós-condição falhou: metadado de '$NOME' ainda existe."
        fi
        QUANTIDADE="$(contar_snapshot_na_imagem "$NOME")" \
            || falhar "Não foi possível validar o QCOW2 após apagar '$NOME'."
        [ "$QUANTIDADE" = "0" ] \
            || falhar "Pós-condição falhou: '$NOME' ainda aparece $QUANTIDADE vez(es) no QCOW2."
        ok "Snapshot interno '$NOME' removido e ausência validada."
        ;;
    *)
        uso
        ;;
esac
