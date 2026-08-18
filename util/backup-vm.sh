#!/bin/bash
# ============================================================================
# util/backup-vm.sh - backup offline restaurável do conjunto da VM
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf
guard_mutation backup.create || exit 1
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
python_core_disponivel \
    || falhar "O core Python do projeto não respondeu: ${PYTHON_CORE_ERRO:-diagnóstico ausente}."
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
# Cardinalidade do disco ativo, driver e demais fontes vêm do core Python. O
# XML inativo trafega por arquivo controlado 0600, nunca por argv.
BACKUP_XML_PERMITIDAS=(
    "${CORE_PARES_ENVELOPE[@]}"
    TARGET_DEV DRIVER_TYPE NVRAM_PATH OTHER_SOURCE_COUNT 'OTHER_SOURCE_#'
)
validar_disco_ativo_xml() {
    local -a payload=()
    _xml_ler_arquivo "$XML_LOCAL" \
        || { VALIDACAO_XML="XML inativo ausente ou ilegível."; return 1; }
    payload=(xml "$XML_CONTEUDO" qcow2_path "$QCOW2_PATH")
    if ! python_core_pares_payload BACKUP_XML_PERMITIDAS BKP_ \
            domain-disk-backup-target payload 2>/dev/null; then
        VALIDACAO_XML="$(_core_diagnostico 'XML inativo inválido.')"
        return 1
    fi
}
VALIDACAO_XML=""
if ! validar_disco_ativo_xml; then
    falhar "$VALIDACAO_XML Consolide snapshots externos ou corrija o XML antes do backup."
fi

QCOW2_VALIDACAO_ERRO=""
QCOW2_PERMITIDAS=(
    "${CORE_PARES_ENVELOPE[@]}"
    FORMAT HAS_BACKING BACKING_FILENAME CHAIN_LENGTH
    VIRTUAL_SIZE ACTUAL_SIZE CLUSTER_SIZE
)
validar_qcow2_sem_backing() {
    # O JSON do qemu-img é capturado aqui e analisado pelo core Python, com
    # schema fechado: formato inesperado, campo com tipo errado ou presença de
    # backing file recusam a operação antes de qualquer cópia.
    local arquivo="$1" info
    local -a payload=()
    QCOW2_VALIDACAO_ERRO=""
    info="$(sudo qemu-img info --output=json "$arquivo" 2>/dev/null)" \
        || { QCOW2_VALIDACAO_ERRO="qemu-img não conseguiu inspecionar $arquivo."; return 1; }
    # O formato é exigido pelo core; a presença de backing file é decidida
    # aqui para que o diagnóstico continue nomeando o arquivo encontrado, como
    # antes da migração.
    IMG_HAS_BACKING=0
    IMG_BACKING_FILENAME=""
    payload=(json "$info" expect_format qcow2)
    if ! python_core_pares_payload QCOW2_PERMITIDAS IMG_ qemu-image-inspect payload \
            2>/dev/null; then
        QCOW2_VALIDACAO_ERRO="$(_core_diagnostico 'JSON do qemu-img inválido.')"
        return 1
    fi
    if [ "$IMG_HAS_BACKING" = 1 ]; then
        QCOW2_VALIDACAO_ERRO="backing file detectado: $IMG_BACKING_FILENAME"
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

# Caminhos extraídos da definição inativa pelo core Python (cardinalidade
# exigida), não por expressão regular sobre XML.
NVRAM_PATH="${BKP_NVRAM_PATH:-}"
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
    for INDICE_FONTE in $(seq 0 $(( ${BKP_OTHER_SOURCE_COUNT:-0} - 1 )) ); do
        NOME_FONTE="BKP_OTHER_SOURCE_$INDICE_FONTE"
        printf ' - %s\n' "${!NOME_FONTE}"
    done
    printf '\nHD1 físico, outros discos, ISO e configuração do host estão fora deste backup.\n'
    printf 'Restaure primeiro em uma VM de teste e valide boot, NVRAM e TPM antes de considerar este conjunto recuperável.\n'
} | sudo tee "$MAPA_DISCOS" >/dev/null
sudo chmod 600 "$MAPA_DISCOS"

echo
ok "Backup do conjunto criado em: $DESTINO_DIR"
info "Conteúdo: $(basename "$QCOW2_BACKUP"), XML inativo, NVRAM/TPM quando existentes e relatório de escopo."
aviso "O relatório lista itens deliberadamente fora do escopo; mantenha também uma cópia externa/offsite e teste a restauração."
