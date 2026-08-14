#!/bin/bash
# ============================================================================
# util/backup-vm.sh - backup offline restaurável do conjunto da VM
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf
exigir_nao_root
exigir_conf VM_NAME QCOW2_PATH
nome_vm_valido "$VM_NAME" || falhar "VM_NAME='$VM_NAME' contém caracteres não seguros."
WORKING_DISK="${WORKING_DISK_PATH:-}"
if [ -n "${BACKUPS_VM_DIR:-}" ]; then
    DESTINO_BASE="$BACKUPS_VM_DIR"
elif [ -n "$WORKING_DISK" ] && [ "${WORKING_DISK_DISPENSADO:-}" != "sim" ]; then
    DESTINO_BASE="${WORKING_DISK%/}/backups-vm"
else
    falhar "Destino de backup não resolvido. Defina BACKUPS_VM_DIR ou configure WORKING_DISK_PATH na etapa 02 e mantenha o workingDisk montado."
fi
caminho_absoluto_seguro "$DESTINO_BASE" \
    || falhar "Destino de backup inseguro: '$DESTINO_BASE'."
BACKUP_DEPENDS_ON_WORKING_DISK=0
classificar_destino_backup() {
    local alvo="${1:-$DESTINO_BASE}" rc
    BACKUP_DEPENDS_ON_WORKING_DISK=0
    [ -n "$WORKING_DISK" ] || return 0
    if caminho_dentro_working_disk "$alvo" "$WORKING_DISK"; then
        BACKUP_DEPENDS_ON_WORKING_DISK=1
        return 0
    else
        rc=$?
    fi
    [ "$rc" -eq 1 ] && return 0
    falhar "Destino de backup recusado por contenção insegura no workingDisk: $WORKING_DISK_CONTENCAO_ERRO"
}
exigir_destino_backup_disponivel() {
    local alvo="${1:-$DESTINO_BASE}"
    classificar_destino_backup "$alvo"
    if [ "$BACKUP_DEPENDS_ON_WORKING_DISK" -eq 1 ]; then
        validar_working_disk_montado "$WORKING_DISK" \
            || falhar "Backup dentro do workingDisk recusado: $WORKING_DISK_ERRO"
    fi
}

titulo "Backup offline do conjunto da VM $VM_NAME"
info "Cria um diretório datado com o QCOW2 principal ativo e sem backing chain, XML inativo e, quando existirem, NVRAM e estado TPM."
info "BACKUPS_VM_DIR explícito tem prioridade; sem ele, o destino é derivado do workingDisk configurado."
info "Se o XML apontar para overlay externo ou o QCOW2 depender de backing file, o backup falha antes de copiar uma base obsoleta."
aviso "A VM ficará desligada. Um backup só é comprovadamente restaurável após teste de restauração em ambiente separado."

exigir_destino_backup_disponivel
exigir_comando rsync qemu-img virsh python3
exigir_sudo
exigir_destino_backup_disponivel
sudo mkdir -p "$DESTINO_BASE"

if ! vm_desligada "$VM_NAME"; then
    info "VM em execução; solicitando desligamento gracioso (ACPI)..."
    confirmar "Desligar a VM $VM_NAME agora para criar o backup?" || falhar "Cancelado."
    $VIRSH shutdown "$VM_NAME"
    LIMITE=300; PASSADO=0
    while ! vm_desligada "$VM_NAME"; do
        [ "$PASSADO" -ge "$LIMITE" ] && falhar "VM não desligou em ${LIMITE}s. NÃO uso 'destroy' automaticamente."
        sleep 5; PASSADO=$((PASSADO + 5)); echo -n "."
    done
    echo
fi

XML_LOCAL="$(mktemp)"
trap 'rm -f "$XML_LOCAL"; encerrar_sudo_keepalive' EXIT INT TERM
info "Exportando e validando a definição inativa da VM..."
$VIRSH dumpxml "$VM_NAME" --inactive > "$XML_LOCAL"
if ! VALIDACAO_XML="$(python3 - "$XML_LOCAL" "$QCOW2_PATH" 2>&1 <<'PY'
import sys
import xml.etree.ElementTree as ET

arquivo, qcow2 = sys.argv[1:]
try:
    root = ET.parse(arquivo).getroot()
except (OSError, ET.ParseError) as exc:
    raise SystemExit(f'XML inativo inválido: {exc}')
matches = []
for disk in root.findall('./devices/disk'):
    if disk.get('device') != 'disk':
        continue
    source = disk.find('source')
    if source is not None and source.get('file') == qcow2:
        matches.append(disk)
if len(matches) != 1:
    raise SystemExit(
        f'QCOW2_PATH={qcow2} precisa ser exatamente o disco ativo no XML; '
        'um overlay externo ou caminho divergente tornaria a cópia obsoleta'
    )
driver = matches[0].find('driver')
if driver is None or driver.get('type') != 'qcow2':
    raise SystemExit(f'o disco ativo {qcow2} não usa driver qcow2')
PY
)"; then
    falhar "$VALIDACAO_XML Consolide snapshots externos ou corrija o XML antes do backup."
fi

QCOW2_VALIDACAO_ERRO=""
validar_qcow2_sem_backing() {
    local arquivo="$1" info resultado
    QCOW2_VALIDACAO_ERRO=""
    info="$(sudo qemu-img info --output=json "$arquivo" 2>/dev/null)" \
        || { QCOW2_VALIDACAO_ERRO="qemu-img não conseguiu inspecionar $arquivo."; return 1; }
    if ! resultado="$(python3 - 3<<< "$info" 2>&1 <<'PY'
import json
import os

try:
    with os.fdopen(3, encoding='utf-8') as stream:
        info = json.load(stream)
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f'JSON do qemu-img inválido: {exc}')
if info.get('format') != 'qcow2':
    raise SystemExit(f"formato inesperado: {info.get('format', 'ausente')}")
backing = info.get('full-backing-filename') or info.get('backing-filename')
if backing:
    raise SystemExit(f'backing file detectado: {backing}')
PY
)"; then
        QCOW2_VALIDACAO_ERRO="$resultado"
        return 1
    fi
}
validar_qcow2_sem_backing "$QCOW2_PATH" \
    || falhar "O disco ativo não é um QCOW2 independente: $QCOW2_VALIDACAO_ERRO Consolide a cadeia antes do backup."

DATA_BACKUP="$(date +%Y%m%d-%H%M%S)"
DESTINO_DIR="$DESTINO_BASE/${VM_NAME}-backup-$DATA_BACKUP"
exigir_destino_backup_disponivel "$DESTINO_DIR"
sudo mkdir -m 700 "$DESTINO_DIR"
sudo mkdir "$DESTINO_DIR/discos-adicionais"

TAM_ORIGEM_KB="$(sudo du -k -- "$QCOW2_PATH" | cut -f1)"
LIVRE_KB="$(df -k --output=avail "$DESTINO_BASE" 2>/dev/null | tail -n1 | tr -dc '0-9')"
if [ -n "$LIVRE_KB" ] && [ "$LIVRE_KB" -lt "$TAM_ORIGEM_KB" ]; then
    falhar "Espaço insuficiente: $((LIVRE_KB / 1024)) MiB livres para ao menos $((TAM_ORIGEM_KB / 1024)) MiB físicos do QCOW2 principal."
fi

XML="$DESTINO_DIR/${VM_NAME}.inactive.xml"
exigir_destino_backup_disponivel "$XML"
sudo install -m 600 "$XML_LOCAL" "$XML"

copiar_artefato() {
    local origem="$1" subdiretorio="$2" destino
    [ -f "$origem" ] || return 1
    destino="$DESTINO_DIR/$subdiretorio/$(basename "$origem")"
    exigir_destino_backup_disponivel "$destino"
    sudo mkdir -p "$DESTINO_DIR/$subdiretorio"
    info "Copiando $origem -> $subdiretorio/ (preservando sparse e metadados)..." >&2
    sudo rsync -aHAXS --numeric-ids --protect-args "$origem" "$destino"
    sudo chmod 600 "$destino" || true
    printf '%s\n' "$destino"
}

QCOW2_BACKUP="$(copiar_artefato "$QCOW2_PATH" discos)"
info "Verificando integralmente o QCOW2 copiado com qemu-img check e ausência de backing file..."
sudo qemu-img check "$QCOW2_BACKUP" >/dev/null \
    || falhar "qemu-img check encontrou erro no QCOW2 copiado; não trate este backup como utilizável."
validar_qcow2_sem_backing "$QCOW2_BACKUP" \
    || falhar "A cópia não é independente: $QCOW2_VALIDACAO_ERRO"
ok "QCOW2 ativo copiado com preservação sparse, sem backing chain e aprovado em qemu-img check."

# Caminhos extraídos da definição inativa, produzida pelo próprio libvirt.
NVRAM_PATH="$(sed -n "s|.*<nvram[^>]*>\(.*\)</nvram>.*|\1|p" "$XML_LOCAL" | head -n1)"
if [ -n "$NVRAM_PATH" ] && [ -f "$NVRAM_PATH" ]; then
    copiar_artefato "$NVRAM_PATH" nvram >/dev/null
    ok "NVRAM incluída."
else
    info "NVRAM não configurada ou não encontrada; nada a incluir."
fi

TPM_STATE="/var/lib/libvirt/swtpm/$VM_NAME"
if sudo test -d "$TPM_STATE"; then
    info "Copiando estado TPM em $TPM_STATE..."
    exigir_destino_backup_disponivel "$DESTINO_DIR/tpm"
    sudo rsync -aHAXS --numeric-ids --protect-args "$TPM_STATE/" "$DESTINO_DIR/tpm/"
    sudo chmod -R go-rwx "$DESTINO_DIR/tpm"
    ok "Estado TPM incluído."
else
    info "Estado TPM do swtpm não encontrado; nada a incluir."
fi

MAPA_DISCOS="$DESTINO_DIR/ESCOPO-NAO-INCLUIDO.txt"
exigir_destino_backup_disponivel "$MAPA_DISCOS"
{
    printf 'Backup: %s\nVM: %s\n\n' "$DATA_BACKUP" "$VM_NAME"
    printf 'Incluído:\n- QCOW2 principal: %s\n- XML inativo: %s\n' "$QCOW2_PATH" "$XML"
    printf '\nDiscos definidos pela VM (exceto o QCOW2 principal), não copiados automaticamente:\n'
    sed -n "s|.*<source file='\([^']*\)'.*| - \1|p; s|.*<source dev='\([^']*\)'.*| - \1|p" "$XML_LOCAL" | grep -Fvx " - $QCOW2_PATH" || true
    printf '\nHD1 físico, outros discos, ISO e configuração do host estão fora deste backup.\n'
    printf 'Restaure primeiro em uma VM de teste e valide boot, NVRAM e TPM antes de considerar este conjunto recuperável.\n'
} | sudo tee "$MAPA_DISCOS" >/dev/null
sudo chmod 600 "$MAPA_DISCOS"

echo
ok "Backup do conjunto criado em: $DESTINO_DIR"
info "Conteúdo: $(basename "$QCOW2_BACKUP"), XML inativo, NVRAM/TPM quando existentes e relatório de escopo."
aviso "O relatório lista itens deliberadamente fora do escopo; mantenha também uma cópia externa/offsite e teste a restauração."
