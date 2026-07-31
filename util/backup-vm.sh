#!/bin/bash
# ============================================================================
# util/backup-vm.sh - Capítulo 25: backup standalone e verificável da VM
# ============================================================================
# Cria no HD2 um conjunto autocontido com o QCOW2 atual do C:, XML inativo,
# NVRAM e estado swtpm quando presentes. O HD1 físico é sempre excluído.
# A publicação ocorre somente após qemu-img check/compare e checksums.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf
exigir_nao_root
exigir_sudo
exigir_comando xmlstarlet qemu-img python3 blkid lsblk findmnt readlink \
    stat df sha256sum cmp tar sync tr
exigir_conf VM_NAME QCOW2_PATH UUID_HD2 HD2_DISCO_PAI NVME_DEVICE \
    HD1_BY_ID_PATH DOCS4_MONTAGEM

DOCS4="/mnt/docs4"
DESTINO_DIR="$DOCS4/backups-vm"
TMP_DIR=""
XML_ORIGINAL=""
XML_ATUAL=""
QCOW2_ORIGEM=""
QCOW2_VIRTUAL_SIZE=0
HD2_PARTICAO=""
HD2_DISCO=""
NVME_DISCO=""
HD1_DISCO=""
NVRAM_ORIGEM=""
SWTPM_ORIGEM=""
BACKUP_NOME=""
BACKUP_FINAL=""
BACKUP_PARTIAL=""
BACKUP_ATUAL=""
PUBLICADO=0
CONCLUIDO=0
MARGEM_BYTES=0
NECESSARIO_BYTES=0
DISPONIVEL_BYTES=0
declare -a ARQUIVOS_BACKUP=()

encerrar() {
    local status="$?"
    trap - EXIT
    if [ "$status" -ne 0 ] && [ "$PUBLICADO" -eq 1 ] \
        && [ -n "$BACKUP_FINAL" ] && [ -n "$BACKUP_PARTIAL" ] \
        && [ -d "$BACKUP_FINAL" ] && [ ! -e "$BACKUP_PARTIAL" ] \
        && [ ! -L "$BACKUP_PARTIAL" ]; then
        if sudo mv -Tn -- "$BACKUP_FINAL" "$BACKUP_PARTIAL" 2>/dev/null \
            && [ -d "$BACKUP_PARTIAL" ]; then
            BACKUP_ATUAL="$BACKUP_PARTIAL"
            PUBLICADO=0
            marcar_quarentena "Falha detectada após o rename de publicação."
        else
            aviso "Não foi possível retirar o conjunto do nome final; trate-o como quarentena: $BACKUP_FINAL"
        fi
    fi
    if [ "$status" -ne 0 ] && [ -n "$BACKUP_ATUAL" ]; then
        aviso "Backup incompleto/quarentenado preservado para diagnóstico: $BACKUP_ATUAL"
        aviso "Não use esse conjunto como backup válido; remova-o manualmente após revisar a falha."
    fi
    if [ -n "$TMP_DIR" ] && [[ "$TMP_DIR" == /tmp/backup-vm.* ]]; then
        rm -rf -- "$TMP_DIR"
    fi
    exit "$status"
}
trap encerrar EXIT
trap 'exit 1' HUP INT TERM

validar_nome_vm() {
    [ "${#VM_NAME}" -le 128 ] \
        && [[ "$VM_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
        || falhar "VM_NAME inválido para compor um backup seguro: '$VM_NAME'."
}

estado_vm() {
    LC_ALL=C $VIRSH domstate "$VM_NAME" 2>/dev/null
}

exigir_vm_existente() {
    LC_ALL=C $VIRSH dominfo "$VM_NAME" >/dev/null 2>&1 \
        || falhar "A VM '$VM_NAME' não existe ou não pôde ser consultada."
}

vm_sem_managed_save() {
    local dominfo linha valor="" quantidade=0
    dominfo="$(LC_ALL=C $VIRSH dominfo "$VM_NAME" 2>/dev/null)" || return 1
    while IFS= read -r linha; do
        case "$linha" in
            "Managed save:"*)
                quantidade=$((quantidade + 1))
                valor="${linha#*:}"
                valor="${valor#"${valor%%[![:space:]]*}"}"
                valor="${valor%"${valor##*[![:space:]]}"}"
                ;;
        esac
    done <<< "$dominfo"
    [ "$quantidade" -eq 1 ] && [ "$valor" = "no" ]
}

exigir_sem_managed_save() {
    vm_sem_managed_save \
        || falhar "A VM deve estar sem managed-save; execute um desligamento completo pelo Windows."
}

exigir_vm_shut_off_limpa() {
    local estado
    exigir_vm_existente
    estado="$(estado_vm)" \
        || falhar "Não foi possível consultar o estado da VM '$VM_NAME'."
    [ "$estado" = "shut off" ] \
        || falhar "A VM '$VM_NAME' deve estar exatamente 'shut off'; encontrado: ${estado:-<vazio>}. Desligue-a pelo Windows e tente novamente."
    exigir_sem_managed_save
}

xml_valor() {
    local arquivo="$1" xpath="$2"
    xmlstarlet sel -t -v "$xpath" "$arquivo"
}

xml_contagem() {
    local arquivo="$1" xpath="$2"
    xml_valor "$arquivo" "count($xpath)"
}

validar_caminho_absoluto() {
    local descricao="$1" caminho="${2:-}"
    [[ "$caminho" == /* ]] && [[ "$caminho" != *[[:cntrl:]]* ]] \
        || falhar "$descricao deve ser caminho absoluto sem caracteres de controle: '$caminho'."
}

validar_xml_e_descobrir_origem() {
    local arquivo="$1" total origem fontes

    xmlstarlet val -q "$arquivo" || falhar "XML inativo inválido para '$VM_NAME'."
    total="$(xml_contagem "$arquivo" "/domain/devices/disk[@device='disk' and @type='file' and driver/@type='qcow2']")" \
        || falhar "Falha ao contar discos QCOW2 no XML."
    [ "$total" = "1" ] \
        || falhar "O XML deve conter exatamente um disco file/device=disk com driver qcow2; encontrados: $total."
    fontes="$(xml_contagem "$arquivo" "/domain/devices/disk[@device='disk' and @type='file' and driver/@type='qcow2'][1]/source[@file]")" \
        || falhar "Falha ao validar a origem do disco do sistema."
    [ "$fontes" = "1" ] \
        || falhar "O único QCOW2 deve declarar exatamente uma source file."
    origem="$(xml_valor "$arquivo" "/domain/devices/disk[@device='disk' and @type='file' and driver/@type='qcow2'][1]/source/@file")" \
        || falhar "Não foi possível descobrir a fonte efetiva do disco do sistema."
    validar_caminho_absoluto "Fonte do QCOW2" "$origem"
    [ "$origem" = "$QCOW2_PATH" ] \
        || falhar "O XML usa '$origem' como disco do sistema, mas QCOW2_PATH é '$QCOW2_PATH'."
    QCOW2_ORIGEM="$origem"
}

inspecionar_qcow2_standalone() {
    local caminho="$1" json resultado formato virtual
    [ -f "$caminho" ] && [ ! -L "$caminho" ] \
        || falhar "O disco do sistema deve ser arquivo regular e não-symlink: $caminho"
    json="$(LC_ALL=C qemu-img info --output=json "$caminho")" \
        || falhar "qemu-img não conseguiu inspecionar $caminho."
    resultado="$(python3 -c '
import json, sys
try:
    image = json.load(sys.stdin)
except Exception:
    raise SystemExit(2)
fmt = image.get("format")
size = image.get("virtual-size")
if fmt != "qcow2" or not isinstance(size, int) or size <= 0:
    raise SystemExit(3)
for key, value in image.items():
    if key.startswith("backing-") or key == "full-backing-filename":
        if value not in (None, ""):
            raise SystemExit(4)
print(fmt, size)
' <<< "$json")" \
        || falhar "A imagem '$caminho' não é qcow2 standalone ou possui backing file/chain externa."
    read -r formato virtual <<< "$resultado"
    [ "$formato" = "qcow2" ] && [[ "$virtual" =~ ^[1-9][0-9]*$ ]] \
        || falhar "Metadados inválidos retornados para '$caminho'."
    QCOW2_VIRTUAL_SIZE="$virtual"
}

dispositivo_bloco_valido() {
    [[ "${1:-}" == /dev/* ]] && [ -b "$1" ]
}

resolver_disco_fisico() {
    local dispositivo="$1" canonico saida nome tipo extra disco
    local -A discos=()

    DISCO_FISICO_RESOLVIDO=""
    canonico="$(readlink -f -- "$dispositivo" 2>/dev/null || true)"
    dispositivo_bloco_valido "$canonico" \
        || falhar "Dispositivo de bloco inválido ou indisponível: $dispositivo"
    saida="$(LC_ALL=C lsblk -srpn -o KNAME,TYPE -- "$canonico" 2>/dev/null)" \
        || falhar "Não foi possível percorrer a cadeia física de $canonico."
    [ -n "$saida" ] || falhar "A cadeia física de $canonico está vazia."
    while read -r nome tipo extra; do
        [ -n "$nome" ] || continue
        [ -z "${extra:-}" ] && [ -n "${tipo:-}" ] \
            || falhar "Saída lsblk ambígua ao resolver $canonico."
        [[ "$nome" == /dev/* ]] || nome="/dev/$nome"
        nome="$(readlink -f -- "$nome" 2>/dev/null || true)"
        if [ "$tipo" = "disk" ]; then
            dispositivo_bloco_valido "$nome" \
                || falhar "Disco físico inválido na cadeia de $canonico: $nome"
            discos[$nome]=1
        fi
    done <<< "$saida"
    [ "${#discos[@]}" -eq 1 ] \
        || falhar "A cadeia de $canonico não leva inequivocamente a um disco físico."
    for disco in "${!discos[@]}"; do
        DISCO_FISICO_RESOLVIDO="$disco"
    done
}

resolver_uuid_hd2() {
    local saida status linha canonico tipo fstype uuid
    local -a dispositivos=()

    [[ "$UUID_HD2" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
        || falhar "UUID_HD2 ausente ou com formato inválido."
    if saida="$(sudo blkid -c /dev/null -t "UUID=$UUID_HD2" -o device 2>/dev/null)"; then
        status=0
    else
        status=$?
        [ "$status" -eq 2 ] \
            || falhar "Falha ao enumerar UUID_HD2=$UUID_HD2 sem cache (status $status)."
        saida=""
    fi
    while IFS= read -r linha; do
        [ -n "$linha" ] || continue
        [[ "$linha" == /dev/* ]] && [[ "$linha" != *[[:cntrl:]]* ]] \
            || falhar "blkid retornou caminho inválido para UUID_HD2: '$linha'."
        canonico="$(readlink -f -- "$linha" 2>/dev/null || true)"
        dispositivo_bloco_valido "$canonico" \
            || falhar "UUID_HD2 retornou dispositivo indisponível: '$linha'."
        dispositivos+=("$canonico")
    done <<< "$saida"
    [ "${#dispositivos[@]}" -eq 1 ] \
        || falhar "UUID_HD2=$UUID_HD2 deve resolver para exatamente uma partição; encontradas: ${#dispositivos[@]}."
    HD2_PARTICAO="${dispositivos[0]}"
    tipo="$(LC_ALL=C lsblk -dnro TYPE -- "$HD2_PARTICAO" 2>/dev/null)" \
        || falhar "Não foi possível consultar o tipo de $HD2_PARTICAO."
    [ "$tipo" = "part" ] || falhar "UUID_HD2 deve identificar uma partição; tipo: ${tipo:-desconhecido}."
    fstype="$(LC_ALL=C lsblk -dnro FSTYPE -- "$HD2_PARTICAO" 2>/dev/null)" \
        || falhar "Não foi possível consultar o filesystem de $HD2_PARTICAO."
    [ "$fstype" = "ntfs" ] || [ "$fstype" = "ntfs3" ] \
        || falhar "UUID_HD2 deve identificar NTFS; tipo: ${fstype:-desconhecido}."
    uuid="$(LC_ALL=C lsblk -dnro UUID -- "$HD2_PARTICAO" 2>/dev/null)" \
        || falhar "Não foi possível confirmar o UUID de $HD2_PARTICAO."
    [ "$uuid" = "$UUID_HD2" ] \
        || falhar "$HD2_PARTICAO não confirma UUID_HD2=$UUID_HD2."
}

validar_identidades_fisicas() {
    local pai hd1 hd1_rel

    resolver_uuid_hd2
    resolver_disco_fisico "$HD2_PARTICAO"
    HD2_DISCO="$DISCO_FISICO_RESOLVIDO"

    pai="$(readlink -f -- "$HD2_DISCO_PAI" 2>/dev/null || true)"
    dispositivo_bloco_valido "$pai" \
        && [ "$pai" = "$HD2_DISCO_PAI" ] \
        && [ "$(LC_ALL=C lsblk -dnro TYPE -- "$pai" 2>/dev/null)" = "disk" ] \
        || falhar "HD2_DISCO_PAI deve ser o caminho canônico de um disco físico inteiro."
    resolver_disco_fisico "$pai"
    [ "$pai" = "$DISCO_FISICO_RESOLVIDO" ] && [ "$pai" = "$HD2_DISCO" ] \
        || falhar "HD2_DISCO_PAI diverge do disco derivado de UUID_HD2."

    NVME_DISCO="$(readlink -f -- "$NVME_DEVICE" 2>/dev/null || true)"
    dispositivo_bloco_valido "$NVME_DISCO" \
        && [ "$NVME_DISCO" = "$NVME_DEVICE" ] \
        && [ "$(LC_ALL=C lsblk -dnro TYPE -- "$NVME_DISCO" 2>/dev/null)" = "disk" ] \
        || falhar "NVME_DEVICE deve ser o caminho canônico de um disco físico inteiro."
    resolver_disco_fisico "$NVME_DISCO"
    [ "$DISCO_FISICO_RESOLVIDO" = "$NVME_DISCO" ] \
        || falhar "NVME_DEVICE não resolve inequivocamente para si próprio."

    [[ "$HD1_BY_ID_PATH" == /dev/disk/by-id/* ]] && [ -L "$HD1_BY_ID_PATH" ] \
        || falhar "HD1_BY_ID_PATH deve ser um symlink real sob /dev/disk/by-id/."
    hd1_rel="${HD1_BY_ID_PATH#/dev/disk/by-id/}"
    [ -n "$hd1_rel" ] && [[ "$hd1_rel" != */* ]] \
        && [ "$hd1_rel" != "." ] && [ "$hd1_rel" != ".." ] \
        && [[ "$hd1_rel" != *[[:cntrl:]]* ]] \
        || falhar "HD1_BY_ID_PATH contém um nome by-id inseguro."
    hd1="$(readlink -f -- "$HD1_BY_ID_PATH" 2>/dev/null || true)"
    dispositivo_bloco_valido "$hd1" \
        && [ "$(LC_ALL=C lsblk -dnro TYPE -- "$hd1" 2>/dev/null)" = "disk" ] \
        || falhar "HD1_BY_ID_PATH deve resolver para um disco físico inteiro."
    resolver_disco_fisico "$hd1"
    HD1_DISCO="$DISCO_FISICO_RESOLVIDO"
    [ "$HD1_DISCO" = "$hd1" ] \
        || falhar "HD1_BY_ID_PATH não resolve inequivocamente para um disco inteiro."

    [ "$HD2_DISCO" != "$NVME_DISCO" ] && [ "$HD2_DISCO" != "$HD1_DISCO" ] \
        && [ "$NVME_DISCO" != "$HD1_DISCO" ] \
        || falhar "HD2, NVMe e HD1 devem ser três discos físicos distintos."
}

obter_mount_exato() {
    MOUNT_SOURCE="$(findmnt -rn --no-encode -M "$DOCS4" -o SOURCE 2>/dev/null)" || return 1
    MOUNT_TARGET="$(findmnt -rn --no-encode -M "$DOCS4" -o TARGET 2>/dev/null)" || return 1
    MOUNT_UUID="$(findmnt -rn --no-encode -M "$DOCS4" -o UUID 2>/dev/null)" || return 1
    MOUNT_FSTYPE="$(findmnt -rn --no-encode -M "$DOCS4" -o FSTYPE 2>/dev/null)" || return 1
    MOUNT_FSROOT="$(findmnt -rn --no-encode -M "$DOCS4" -o FSROOT 2>/dev/null)" || return 1
    MOUNT_OPTIONS="$(findmnt -rn --no-encode -M "$DOCS4" -o OPTIONS 2>/dev/null)" || return 1
    [ -n "$MOUNT_SOURCE" ] && [ "$MOUNT_TARGET" = "$DOCS4" ] \
        && [[ "$MOUNT_SOURCE$MOUNT_TARGET$MOUNT_UUID$MOUNT_FSTYPE$MOUNT_FSROOT$MOUNT_OPTIONS" != *$'\n'* ]]
}

validar_mount_docs4() {
    local origem opcoes
    [ "$DOCS4_MONTAGEM" = "$DOCS4" ] \
        || falhar "DOCS4_MONTAGEM deve ser exatamente $DOCS4; encontrado: '$DOCS4_MONTAGEM'."
    obter_mount_exato || falhar "$DOCS4 não é um mountpoint exato consultável."
    [[ "$MOUNT_SOURCE" != *"["* ]] && [[ "$MOUNT_SOURCE" != *"]"* ]] \
        && [ "$MOUNT_FSROOT" = "/" ] \
        || falhar "$DOCS4 deve montar a raiz da partição, sem subpath."
    origem="$(readlink -f -- "$MOUNT_SOURCE" 2>/dev/null || true)"
    [ "$origem" = "$HD2_PARTICAO" ] && [ "$MOUNT_UUID" = "$UUID_HD2" ] \
        || falhar "$DOCS4 não aponta para $HD2_PARTICAO com UUID=$UUID_HD2."
    [ "$MOUNT_FSTYPE" = "fuseblk" ] || [ "$MOUNT_FSTYPE" = "ntfs3" ] \
        || falhar "$DOCS4 não está montado como NTFS; tipo: '$MOUNT_FSTYPE'."
    opcoes=",$MOUNT_OPTIONS,"
    [[ "$opcoes" == *",rw,"* ]] && [[ "$opcoes" != *",ro,"* ]] \
        || falhar "$DOCS4 deve estar montado em leitura e escrita."
    [ -d "$DOCS4" ] && [ ! -L "$DOCS4" ] \
        || falhar "$DOCS4 deve ser um diretório real, não-symlink."
}

descobrir_estado_auxiliar() {
    local quantidade uuid candidato

    quantidade="$(xml_contagem "$XML_ORIGINAL" "/domain/os/nvram[normalize-space(.) != '']")" \
        || falhar "Falha ao localizar NVRAM no XML."
    [ "$quantidade" = "0" ] || [ "$quantidade" = "1" ] \
        || falhar "O XML contém mais de um caminho NVRAM."
    if [ "$quantidade" = "1" ]; then
        NVRAM_ORIGEM="$(xml_valor "$XML_ORIGINAL" "normalize-space(/domain/os/nvram[1])")" \
            || falhar "Falha ao ler o caminho NVRAM."
        validar_caminho_absoluto "NVRAM" "$NVRAM_ORIGEM"
        sudo test -f "$NVRAM_ORIGEM" && ! sudo test -L "$NVRAM_ORIGEM" \
            || falhar "NVRAM declarada não é arquivo regular ou é symlink: $NVRAM_ORIGEM"
    fi

    quantidade="$(xml_contagem "$XML_ORIGINAL" "/domain/devices/tpm/backend[@type='emulator']")" \
        || falhar "Falha ao localizar swtpm no XML."
    [ "$quantidade" = "0" ] || [ "$quantidade" = "1" ] \
        || falhar "O XML contém mais de um backend swtpm."
    if [ "$quantidade" = "1" ]; then
        quantidade="$(xml_contagem "$XML_ORIGINAL" "/domain/devices/tpm/backend[@type='emulator']/source[@path]")" \
            || falhar "Falha ao localizar o estado swtpm explícito."
        [ "$quantidade" = "0" ] || [ "$quantidade" = "1" ] \
            || falhar "O backend swtpm contém múltiplas fontes."
        if [ "$quantidade" = "1" ]; then
            SWTPM_ORIGEM="$(xml_valor "$XML_ORIGINAL" "/domain/devices/tpm/backend[@type='emulator']/source/@path")" \
                || falhar "Falha ao ler a origem swtpm."
            validar_caminho_absoluto "Estado swtpm" "$SWTPM_ORIGEM"
        else
            uuid="$(xml_valor "$XML_ORIGINAL" "normalize-space(/domain/uuid)")" \
                || falhar "VM com swtpm não possui UUID consultável."
            [[ "$uuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
                || falhar "UUID inválido no XML ao localizar o estado swtpm."
            candidato="/var/lib/libvirt/swtpm/$uuid"
            if sudo test -d "$candidato"; then
                SWTPM_ORIGEM="$candidato"
            fi
        fi
        if [ -n "$SWTPM_ORIGEM" ]; then
            sudo test -d "$SWTPM_ORIGEM" && ! sudo test -L "$SWTPM_ORIGEM" \
                || falhar "Estado swtpm não é diretório real ou é symlink: $SWTPM_ORIGEM"
        fi
    fi
}

calcular_espaco() {
    local saida cabecalho disponivel extra=0
    MARGEM_BYTES=$((QCOW2_VIRTUAL_SIZE / 10 + 1073741824))
    if [ -n "$NVRAM_ORIGEM" ]; then
        extra=$((extra + 16777216))
    fi
    if [ -n "$SWTPM_ORIGEM" ]; then
        extra=$((extra + 67108864))
    fi
    NECESSARIO_BYTES=$((QCOW2_VIRTUAL_SIZE + MARGEM_BYTES + extra))
    saida="$(LC_ALL=C df -B1 --output=avail "$DOCS4")" \
        || falhar "Não foi possível consultar o espaço disponível em $DOCS4."
    read -r cabecalho disponivel extra <<< "$(printf '%s\n' "$saida" | tr '\n' ' ')"
    [ "$cabecalho" = "Avail" ] && [[ "$disponivel" =~ ^[0-9]+$ ]] && [ -z "${extra:-}" ] \
        || falhar "Saída ambígua de df ao calcular espaço em $DOCS4."
    DISPONIVEL_BYTES="$disponivel"
    [ "$DISPONIVEL_BYTES" -ge "$NECESSARIO_BYTES" ] \
        || falhar "Espaço insuficiente no HD2: necessários $NECESSARIO_BYTES bytes (inclui margem de $MARGEM_BYTES), disponíveis $DISPONIVEL_BYTES."
}

validar_xml_inalterado() {
    exigir_vm_shut_off_limpa
    LC_ALL=C $VIRSH dumpxml --inactive "$VM_NAME" > "$XML_ATUAL" \
        || falhar "Falha ao revalidar o XML inativo de '$VM_NAME'."
    validar_xml_e_descobrir_origem "$XML_ATUAL"
    cmp -s -- "$XML_ORIGINAL" "$XML_ATUAL" \
        || falhar "O XML inativo da VM mudou durante o backup; conjunto mantido em quarentena."
    inspecionar_qcow2_standalone "$QCOW2_ORIGEM"
}

marcar_quarentena() {
    local motivo="$1" marcador="$TMP_DIR/QUARENTENA.txt"
    printf 'Backup inválido/quarentenado.\nMotivo: %s\n' "$motivo" > "$marcador"
    if [ -n "$BACKUP_ATUAL" ] && [ -d "$BACKUP_ATUAL" ]; then
        sudo cp -- "$marcador" "$BACKUP_ATUAL/QUARENTENA.txt" 2>/dev/null \
            || aviso "Não foi possível gravar o marcador de quarentena."
    fi
}

confirmar_estado_ou_quarentenar() {
    local contexto="$1" estado motivo=""
    estado="$(estado_vm 2>/dev/null || true)"
    if [ "$estado" != "shut off" ]; then
        motivo="estado da VM: ${estado:-indisponível}"
    elif ! vm_sem_managed_save; then
        motivo="managed-save presente ou estado limpo não verificável"
    elif ! obter_mount_exato \
        || [ "$MOUNT_TARGET" != "$DOCS4" ] \
        || [ "$MOUNT_UUID" != "$UUID_HD2" ] \
        || [ "$(readlink -f -- "$MOUNT_SOURCE" 2>/dev/null || true)" != "$HD2_PARTICAO" ]; then
        motivo="mount exato do HD2 mudou ou não pôde ser revalidado"
    fi
    if [ -n "$motivo" ]; then
        marcar_quarentena "Mudança durante $contexto: $motivo."
        falhar "Condição segura mudou durante $contexto ($motivo); backup abortado."
    fi
}

copiar_estado_auxiliar() {
    if [ -n "$NVRAM_ORIGEM" ]; then
        sudo cp -- "$NVRAM_ORIGEM" "$BACKUP_PARTIAL/nvram.fd" \
            || falhar "Falha ao copiar a NVRAM."
        sudo cmp -s -- "$NVRAM_ORIGEM" "$BACKUP_PARTIAL/nvram.fd" \
            || falhar "A cópia da NVRAM diverge da origem."
        ARQUIVOS_BACKUP+=("nvram.fd")
    fi
    if [ -n "$SWTPM_ORIGEM" ]; then
        sudo tar --numeric-owner -C "$SWTPM_ORIGEM" -cf "$BACKUP_PARTIAL/swtpm-state.tar" . \
            || falhar "Falha ao arquivar o estado swtpm."
        sudo tar -tf "$BACKUP_PARTIAL/swtpm-state.tar" >/dev/null \
            || falhar "O arquivo do estado swtpm não pôde ser relido."
        ARQUIVOS_BACKUP+=("swtpm-state.tar")
    fi
}

criar_manifesto() {
    local manifesto="$TMP_DIR/manifesto.txt"
    {
        printf 'backup_format=vm-standalone-v1\n'
        printf 'vm_name=%s\n' "$VM_NAME"
        printf 'created_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'system_disk_source=%s\n' "$QCOW2_ORIGEM"
        printf 'system_disk_backup=system.qcow2\n'
        printf 'system_disk_format=qcow2\n'
        printf 'system_disk_standalone=yes\n'
        printf 'inactive_xml=domain.xml\n'
        printf 'nvram=%s\n' "$([ -n "$NVRAM_ORIGEM" ] && printf 'nvram.fd' || printf 'absent')"
        printf 'swtpm_state=%s\n' "$([ -n "$SWTPM_ORIGEM" ] && printf 'swtpm-state.tar' || printf 'absent')"
        printf 'hd1=excluded\n'
        printf 'hd1_source=%s\n' "$HD1_BY_ID_PATH"
        printf 'destination_uuid=%s\n' "$UUID_HD2"
        printf 'destination_disk=%s\n' "$HD2_DISCO"
        printf 'validation=qemu-img-check,qemu-img-compare,sha256\n'
    } > "$manifesto"
    sudo cp -- "$manifesto" "$BACKUP_PARTIAL/manifesto.txt" \
        || falhar "Falha ao gravar o manifesto."
    ARQUIVOS_BACKUP+=("manifesto.txt")
}

gerar_e_validar_checksums() {
    local arquivo soma linha checksums="$TMP_DIR/checksums.sha256"
    : > "$checksums"
    for arquivo in "${ARQUIVOS_BACKUP[@]}"; do
        linha="$(sudo sha256sum -- "$BACKUP_PARTIAL/$arquivo")" \
            || falhar "Falha ao calcular checksum de '$arquivo'."
        soma="${linha%% *}"
        [[ "$soma" =~ ^[0-9a-f]{64}$ ]] \
            || falhar "Checksum inválido retornado para '$arquivo'."
        printf '%s  %s\n' "$soma" "$arquivo" >> "$checksums"
    done
    sudo cp -- "$checksums" "$BACKUP_PARTIAL/checksums.sha256" \
        || falhar "Falha ao gravar checksums.sha256."
    (
        cd -- "$BACKUP_PARTIAL" || exit 1
        sudo sha256sum -c -- checksums.sha256 >/dev/null
    ) || falhar "A verificação dos checksums do conjunto falhou."
}

sincronizar_caminho() {
    local caminho="$1"
    if sudo sync -f "$caminho" 2>/dev/null; then
        return 0
    fi
    aviso "sync -f não está disponível para '$caminho'; executando sync global antes de continuar."
    sudo sync || falhar "Não foi possível sincronizar os dados do backup."
}

validar_backup_qcow2() {
    local json
    sudo qemu-img check -f qcow2 "$BACKUP_PARTIAL/system.qcow2" >/dev/null \
        || falhar "qemu-img check encontrou erro na imagem convertida."
    sudo qemu-img compare -f qcow2 -F qcow2 "$QCOW2_ORIGEM" "$BACKUP_PARTIAL/system.qcow2" >/dev/null \
        || falhar "qemu-img compare encontrou divergência entre origem e backup."
    json="$(sudo env LC_ALL=C qemu-img info --output=json "$BACKUP_PARTIAL/system.qcow2")" \
        || falhar "Não foi possível inspecionar a imagem convertida."
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
        || falhar "A imagem convertida não é um QCOW2 standalone."
}

validar_nome_vm
validar_caminho_absoluto "QCOW2_PATH" "$QCOW2_PATH"
exigir_vm_shut_off_limpa
validar_identidades_fisicas
validar_mount_docs4

TMP_DIR="$(mktemp -d -- /tmp/backup-vm.XXXXXX)" \
    || falhar "Não foi possível criar diretório temporário seguro."
chmod 0700 -- "$TMP_DIR"
XML_ORIGINAL="$TMP_DIR/domain.xml"
XML_ATUAL="$TMP_DIR/domain-atual.xml"
LC_ALL=C $VIRSH dumpxml --inactive "$VM_NAME" > "$XML_ORIGINAL" \
    || falhar "Falha ao capturar o XML inativo de '$VM_NAME'."
validar_xml_e_descobrir_origem "$XML_ORIGINAL"
inspecionar_qcow2_standalone "$QCOW2_ORIGEM"
descobrir_estado_auxiliar
calcular_espaco
validar_mount_docs4
exigir_vm_shut_off_limpa

BACKUP_NOME="$VM_NAME-backup-$(date -u +%Y%m%dT%H%M%SZ)-$$"
BACKUP_FINAL="$DESTINO_DIR/$BACKUP_NOME"
BACKUP_PARTIAL="$DESTINO_DIR/.$BACKUP_NOME.partial"
[ ! -e "$BACKUP_FINAL" ] && [ ! -L "$BACKUP_FINAL" ] \
    && [ ! -e "$BACKUP_PARTIAL" ] && [ ! -L "$BACKUP_PARTIAL" ] \
    || falhar "Nome de backup já existe; nada será sobrescrito: $BACKUP_NOME"
if [ -e "$DESTINO_DIR" ] || [ -L "$DESTINO_DIR" ]; then
    [ -d "$DESTINO_DIR" ] && [ ! -L "$DESTINO_DIR" ] \
        || falhar "$DESTINO_DIR deve ser um diretório real, não-symlink."
else
    sudo mkdir -- "$DESTINO_DIR" \
        || falhar "Não foi possível criar o diretório de backups no HD2."
fi
sudo mkdir -- "$BACKUP_PARTIAL" \
    || falhar "Não foi possível criar o diretório parcial único: $BACKUP_PARTIAL"
[ -d "$BACKUP_PARTIAL" ] && [ ! -L "$BACKUP_PARTIAL" ] \
    || falhar "O diretório parcial criado não é um diretório real seguro."
BACKUP_ATUAL="$BACKUP_PARTIAL"

marcar_quarentena "Backup em construção; válido somente após publicação final."
titulo "Backup verificável da VM $VM_NAME"
info "Origem efetiva: $QCOW2_ORIGEM (QCOW2 standalone; VM exatamente shut off)."
info "Destino: UUID=$UUID_HD2 em $HD2_DISCO; HD1 $HD1_BY_ID_PATH está EXCLUÍDO."
info "Reserva conservadora: $NECESSARIO_BYTES bytes, incluindo margem de $MARGEM_BYTES bytes."

validar_xml_inalterado
confirmar_estado_ou_quarentenar "a preparação da conversão"
info "Convertendo o estado atual do C: para um QCOW2 standalone..."
sudo qemu-img convert -p -f qcow2 -O qcow2 "$QCOW2_ORIGEM" "$BACKUP_PARTIAL/system.qcow2" \
    || falhar "Falha no qemu-img convert; diretório parcial preservado."
ARQUIVOS_BACKUP+=("system.qcow2")
confirmar_estado_ou_quarentenar "a conversão do disco"

sudo cp -- "$XML_ORIGINAL" "$BACKUP_PARTIAL/domain.xml" \
    || falhar "Falha ao copiar o XML inativo."
sudo cmp -s -- "$XML_ORIGINAL" "$BACKUP_PARTIAL/domain.xml" \
    || falhar "A cópia do XML inativo diverge da origem."
ARQUIVOS_BACKUP+=("domain.xml")
copiar_estado_auxiliar
criar_manifesto

validar_backup_qcow2
validar_xml_inalterado
confirmar_estado_ou_quarentenar "a validação do conjunto"
gerar_e_validar_checksums
sincronizar_caminho "$BACKUP_PARTIAL"
confirmar_estado_ou_quarentenar "a publicação"

[ ! -e "$BACKUP_FINAL" ] && [ ! -L "$BACKUP_FINAL" ] \
    || falhar "O nome final apareceu durante o backup; publicação recusada."
sudo mv -Tn -- "$BACKUP_PARTIAL" "$BACKUP_FINAL" \
    || falhar "Falha ao publicar o backup por rename sem sobrescrita."
[ ! -e "$BACKUP_PARTIAL" ] && [ ! -L "$BACKUP_PARTIAL" ] \
    && [ -d "$BACKUP_FINAL" ] && [ ! -L "$BACKUP_FINAL" ] \
    || falhar "A publicação no-clobber não produziu exatamente o diretório final esperado."
BACKUP_ATUAL="$BACKUP_FINAL"
PUBLICADO=1
sincronizar_caminho "$DESTINO_DIR"

MOTIVO_FINAL=""
ESTADO_FINAL="$(estado_vm 2>/dev/null || true)"
if [ "$ESTADO_FINAL" != "shut off" ]; then
    MOTIVO_FINAL="estado da VM: ${ESTADO_FINAL:-indisponível}"
elif ! vm_sem_managed_save; then
    MOTIVO_FINAL="managed-save presente ou estado limpo não verificável"
elif ! obter_mount_exato \
    || [ "$MOUNT_TARGET" != "$DOCS4" ] \
    || [ "$MOUNT_UUID" != "$UUID_HD2" ] \
    || [ "$(readlink -f -- "$MOUNT_SOURCE" 2>/dev/null || true)" != "$HD2_PARTICAO" ]; then
    MOTIVO_FINAL="mount exato do HD2 mudou ou não pôde ser revalidado"
fi
if [ -n "$MOTIVO_FINAL" ]; then
    if sudo mv -Tn -- "$BACKUP_FINAL" "$BACKUP_PARTIAL" \
        && [ -d "$BACKUP_PARTIAL" ] && [ ! -L "$BACKUP_PARTIAL" ]; then
        BACKUP_ATUAL="$BACKUP_PARTIAL"
        PUBLICADO=0
    fi
    marcar_quarentena "Condição mudou imediatamente após a publicação: $MOTIVO_FINAL."
    falhar "Condição segura mudou após a publicação ($MOTIVO_FINAL); conjunto retirado/quarentenado."
fi
validar_mount_docs4
sudo rm -f -- "$BACKUP_FINAL/QUARENTENA.txt" \
    || falhar "Não foi possível remover o marcador provisório de quarentena."
sincronizar_caminho "$BACKUP_FINAL"
sincronizar_caminho "$DESTINO_DIR"

CONCLUIDO=1
BACKUP_ATUAL=""
ok "Backup standalone verificado e publicado: $BACKUP_FINAL"
info "Validações concluídas: qemu-img check, comparação de conteúdo e checksums SHA-256."
aviso "HD1 não faz parte deste conjunto. Mantenha também uma cópia externa/offsite."
