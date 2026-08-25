#!/usr/bin/env bash
# Gate dirigido I6: somente fixtures sintéticas, core puro e temporários privados.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
FIXTURES="$ROOT/tests/fixtures/i6"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

fail() { printf 'FALHA I6: %s\n' "$*" >&2; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/i6-inventory.XXXXXXXX")
trap 'python_core_temporarios_limpar 2>/dev/null || true; rm -rf -- "$TMP"' EXIT HUP INT TERM

CPU=$(<"$FIXTURES/lscpu.txt")
MEMORY=$(<"$FIXTURES/meminfo.txt")
PCI=$(<"$FIXTURES/pci.txt")
BLOCK=$(<"$FIXTURES/block-normalize.json")
USB=$(<"$FIXTURES/usb-serial.json")
INTERFACES=$(<"$FIXTURES/interfaces.json")
declare -a CAPTURE=(
    schema_version 1
    cpu_state present cpu_reason '' cpu_data "$CPU"
    memory_state present memory_reason '' memory_data "$MEMORY"
    memory_report 'Memory Device
        Size: 32768 MB'
    pci_state present pci_reason '' pci_data "$PCI"
    disks_state present disks_reason '' block_json "$BLOCK"
    block_by_id_map $'ata-fixture\t8:0\n' udev_database ''
    usb_state present usb_reason '' usb_data "$USB"
    interfaces_state present interfaces_reason '' interfaces_data "$INTERFACES"
    boot_state present boot_reason '' boot_data $'FIRMWARE=uefi\nSECURE_BOOT=disabled\nBOOTLOADER=kernelstub\n'
    baseboard_report 'Fixture board' bios_report 'Fixture BIOS' iommu_report 'Fixture IOMMU'
)
REPORT="$TMP/inventory-v2.txt"
inventario_normalizar_snapshot CAPTURE "$REPORT" || fail "$INVENTARIO_ERRO"
[[ -s $REPORT && $(stat -c '%a' -- "$REPORT") == 600 ]] || fail 'relatório candidato não ficou regular 0600'
grep -q '^INVENTORY_V2|' "$REPORT" || fail 'relatório v2 sem marcador canônico'
validar_inventario_principal "$REPORT" || fail "$INVENTARIO_ERRO"
[[ $INVENTARIO_DECISION_FINGERPRINT =~ ^[0-9a-f]{64}$ ]] || fail 'fingerprint decisório inválido'

validar_inventario_principal "$FIXTURES/current-v1.txt" || fail 'current-v1 válido foi recusado'
validar_inventario_principal "$FIXTURES/legacy-v0.txt" || fail 'legacy-v0 válido foi recusado'
if validar_inventario_principal "$FIXTURES/hostile.txt"; then
    fail 'payload executável foi aceito como inventário'
fi
CURRENT=$(<"$FIXTURES/current-v1.txt")
REORDERED=$(<"$FIXTURES/current-v1-reordered.txt")
comparar_inventario_com_hardware "$FIXTURES/current-v1.txt" "$REORDERED" \
    || fail "reordenação semântica gerou falso positivo: $INVENTARIO_ERRO"
CHANGED=${REORDERED/SER001/SER999}
if comparar_inventario_com_hardware "$FIXTURES/current-v1.txt" "$CHANGED"; then
    fail 'mudança física de serial não exigiu redetecção'
fi
[[ $INVENTARIO_DIFERENCAS == *Discos* ]] || fail 'mudança física não foi discriminada'

# Resolução USB pelo canal da ponte: serial e fallback de porta sobrevivem à
# renumeração; identidade ausente/duplicada nunca é escolhida por ordem.
inventario_resolver_usb "$USB" select 046d c52b '' '' 1 7 \
    || fail "USB por serial não resolveu: $USB_IDENTIDADE_ERRO"
USB_SHA=$USB_IDENTIDADE_SHA256
[[ $USB_IDENTIDADE_KIND == serial && $USB_SHA =~ ^[0-9a-f]{64}$ ]] || fail 'identidade USB serial inválida'
USB_RENUMBERED=${USB/\"bus\":1/\"bus\":4}
USB_RENUMBERED=${USB_RENUMBERED/\"device\":7/\"device\":22}
inventario_resolver_usb "$USB_RENUMBERED" resolve 046d c52b serial "$USB_SHA" 1 7 \
    || fail 'USB serial renumerado não foi reconhecido'
[[ $USB_IDENTIDADE_RENUMBERED == 1 ]] || fail 'renumeração USB não foi sinalizada'
USB_PORT=$(<"$FIXTURES/usb-port.json")
inventario_resolver_usb "$USB_PORT" select 1234 5678 '' '' 2 9 \
    || fail 'fallback USB por porta não resolveu'
[[ $USB_IDENTIDADE_KIND == port ]] || fail 'USB sem serial não usou porta comprovada'

# Plano físico cru pela mesma ponte, sem lsblk/udev reais.
STORAGE=$(<"$FIXTURES/storage-distinct.json")
declare -a DISK_PAYLOAD=(
    block_json "$STORAGE" block_by_id_map $'ata-system\t8:0\nata-working\t8:16\nata-hd1\t8:32\n'
    udev_database '' system_members /dev/sda1 working_members /dev/sdb1 hd1_members /dev/sdc
    expected_system_fingerprint '' expected_working_fingerprint '' expected_hd1_fingerprint ''
)
declare -a DISK_ALLOWED=(
    "${CORE_PARES_ENVELOPE[@]}" VALID ERROR SYSTEM_STATE WORKING_STATE HD1_STATE
    SYSTEM_FINGERPRINT WORKING_FINGERPRINT HD1_FINGERPRINT CONFLICT_COUNT
    'CONFLICT_#_LEFT' 'CONFLICT_#_RIGHT' 'CONFLICT_#_IDENTITY'
)
python_core_pares_payload DISK_ALLOWED DPLAN_ inventory-disk-plan DISK_PAYLOAD \
    || fail "planner de disco recusou fixture distinta: $PYTHON_CORE_ERRO"
[[ $DPLAN_VALID == 1 && $DPLAN_CONFLICT_COUNT == 0 ]] || fail 'papéis distintos colidiram'
# Reconstrói explicitamente o cenário de colisão workingDisk=HD1.
DISK_PAYLOAD=(
    block_json "$STORAGE" block_by_id_map $'ata-system\t8:0\nata-working\t8:16\nata-hd1\t8:32\n'
    udev_database '' system_members /dev/sda1 working_members /dev/sdc hd1_members /dev/sdc
    expected_system_fingerprint '' expected_working_fingerprint '' expected_hd1_fingerprint ''
)
python_core_pares_payload DISK_ALLOWED DCOL_ inventory-disk-plan DISK_PAYLOAD \
    || fail 'colisão observada virou erro de protocolo'
[[ $DCOL_VALID == 0 && $DCOL_CONFLICT_COUNT -ge 1 ]] || fail 'workingDisk=HD1 não foi bloqueado'

# Candidato XML USB completo: metadata e hostdev têm cardinalidade única,
# segunda geração é no-op e remoção usa o hash, não VID:PID/ordem.
ORIGINAL="$TMP/domain.xml"
CANDIDATE="$TMP/domain-usb.xml"
REMOVED="$TMP/domain-removed.xml"
cat > "$ORIGINAL" <<'XML'
<domain type='kvm'><name>fixture-win11</name><memory unit='MiB'>8192</memory><vcpu>4</vcpu><devices><disk type='file' device='disk'><driver name='qemu' type='qcow2'/><source file='/vm/fixture.qcow2'/><target dev='vda' bus='virtio'/></disk></devices></domain>
XML
xml_candidato_usb "$ORIGINAL" "$CANDIDATE" present serial "$USB_SHA" 046d c52b 4 22 \
    || fail "candidato USB recusado: $XML_CANDIDATO_ERRO"
[[ $XML_CANDIDATO_MUDOU == 1 && $(stat -c '%a' -- "$CANDIDATE") == 600 ]] || fail 'candidato USB não foi publicado em 0600'
declare -a XML_PAYLOAD=(xml "$(<"$CANDIDATE")")
declare -a XML_ALLOWED=(
    "${CORE_PARES_ENVELOPE[@]}" USB_COUNT AMBIGUOUS_PAIRS
    'USB_#_VENDOR' 'USB_#_PRODUCT' 'USB_#_BUS' 'USB_#_DEVICE' 'USB_#_MANAGED'
    'USB_#_ALIAS' 'USB_#_IDENTITY_KIND' 'USB_#_IDENTITY_SHA256'
)
python_core_pares_payload XML_ALLOWED XUSB_ domain-usb-hostdev XML_PAYLOAD \
    || fail "candidato USB não passou na inspeção semântica: $PYTHON_CORE_ERRO"
[[ $XUSB_USB_COUNT == 1 && $XUSB_USB_0_IDENTITY_SHA256 == "$USB_SHA" ]] || fail 'binding USB não ficou cardinalizado'
xml_candidato_usb "$CANDIDATE" "$REMOVED" absent serial "$USB_SHA" 046d c52b '' '' \
    || fail "remoção USB recusada: $XML_CANDIDATO_ERRO"
XML_PAYLOAD=(xml "$(<"$REMOVED")")
python_core_pares_payload XML_ALLOWED XREM_ domain-usb-hostdev XML_PAYLOAD \
    || fail 'XML removido ficou semanticamente inválido'
[[ $XREM_USB_COUNT == 0 ]] || fail 'remoção por identidade deixou hostdev órfão'

# A fachada operacional reobserva os três papéis e compara exatamente os
# fingerprints persistidos antes de qualquer consumidor aplicar efeitos.
(
    STORAGE_FIXTURE=$STORAGE
    _inventario_capturar_topologia_disco() {
        local -n destino="$1"
        destino+=(
            block_json "$STORAGE_FIXTURE"
            block_by_id_map $'ata-system\t8:0\nata-working\t8:16\nata-hd1\t8:32\n'
            udev_database ''
        )
    }
    discos_fisicos_de() {
        case "$1" in
            /dev/system-fixture) printf '%s\n' /dev/sda1 ;;
            /dev/working-fixture) printf '%s\n' /dev/sdb1 ;;
            *) return 1 ;;
        esac
    }
    discos_raiz() {
        printf '%s\n' /dev/sda1
    }
    validar_working_disk_montado() {
        WORKING_DISK_SOURCE=/dev/working-fixture
        WORKING_DISK_FSTYPE=ext4
        WORKING_DISK_ERRO=''
    }
    readlink() {
        if [[ $* == '-f -- /dev/disk/by-id/ata-hd1' ]]; then
            printf '%s\n' /dev/sdc
        else
            command readlink "$@"
        fi
    }
    NVME_DEVICE=/dev/system-fixture
    SYSTEM_DISK_FINGERPRINT=$DPLAN_SYSTEM_FINGERPRINT
    WORKING_DISK_PATH=/mnt/working-fixture
    WORKING_DISK_FINGERPRINT=$DPLAN_WORKING_FINGERPRINT
    WORKING_DISK_DISPENSADO=''
    HD1_BY_ID_PATH=/dev/disk/by-id/ata-hd1
    HD1_DISK_FINGERPRINT=$DPLAN_HD1_FINGERPRINT
    HD1_DISPENSADO=''
    inventario_revalidar_papeis_disco_configurados \
        || exit 1
    if [[ ${SYSTEM_DISK_FINGERPRINT: -1} == 0 ]]; then
        SYSTEM_DISK_FINGERPRINT="${SYSTEM_DISK_FINGERPRINT::-1}1"
    else
        SYSTEM_DISK_FINGERPRINT="${SYSTEM_DISK_FINGERPRINT::-1}0"
    fi
    ! inventario_revalidar_papeis_disco_configurados
) || fail 'fachada de revalidação dos três papéis não bloqueou fingerprint divergente'

# A fachada usa toda a raiz composta, não apenas o localizador compatível
# NVME_DEVICE. O fingerprint multi-membro precisa convergir na revalidação.
(
    STORAGE_FIXTURE=$STORAGE
    _inventario_capturar_topologia_disco() {
        local -n destino="$1"
        destino+=(
            block_json "$STORAGE_FIXTURE"
            block_by_id_map $'ata-system\t8:0\nata-working\t8:16\nata-hd1\t8:32\n'
            udev_database ''
        )
    }
    discos_raiz() { printf '%s\n' /dev/sda1 /dev/sdb1; }
    inventario_planejar_papeis_disco $'/dev/sda1\n/dev/sdb1' '' /dev/sdc \
        || exit 1
    NVME_DEVICE=/dev/sda1
    SYSTEM_DISK_FINGERPRINT=$INVENTARIO_SYSTEM_FINGERPRINT
    WORKING_DISK_PATH=''
    WORKING_DISK_FINGERPRINT=''
    WORKING_DISK_DISPENSADO=sim
    HD1_BY_ID_PATH=/dev/disk/by-id/ata-hd1
    HD1_DISK_FINGERPRINT=$INVENTARIO_HD1_FINGERPRINT
    HD1_DISPENSADO=''
    readlink() {
        if [[ $* == '-f -- /dev/disk/by-id/ata-hd1' ]]; then
            printf '%s\n' /dev/sdc
        else
            command readlink "$@"
        fi
    }
    inventario_revalidar_papeis_disco_configurados
) || fail 'fachada não preservou todos os membros físicos da raiz composta'

# Falha real do probe udev é estado error, nunca coleção USB vazia.
(
    lsblk() {
        if [[ $* == *--json* ]]; then
            printf '%s\n' '{"blockdevices":[{"name":"sda","kname":"sda","path":"/dev/sda","type":"disk","maj:min":"8:0","size":1000,"model":"Fixture","serial":"SER","wwn":"5000aa"}]}'
        else
            return 1
        fi
    }
    udevadm() { return 1; }
    declare -a topology=()
    _inventario_capturar_topologia_disco topology || exit 1
    [[ $INVENTARIO_UDEV_STATE == error && $INVENTARIO_UDEV_REASON == probe_failed ]]
) || fail 'falha de udevadm foi mascarada como USB vazio'

# Harness shell end-to-end da transação USB individual. A cópia temporária usa
# virsh/udev/validador sintéticos e nunca alcança libvirt ou hardware reais.
USB_HARNESS="$TMP/usb-transaction"
USB_PROJECT="$USB_HARNESS/project"
USB_BIN="$USB_HARNESS/bin"
USB_STATE="$USB_HARNESS/domain.xml"
USB_INITIAL="$USB_HARNESS/domain-initial.xml"
USB_CONCURRENT="$USB_HARNESS/domain-concurrent.xml"
USB_LEGACY="$USB_HARNESS/domain-legacy.xml"
USB_CAPTURE="$USB_HARNESS/usb.json"
USB_DUMP_COUNT="$USB_HARNESS/dump-count"
USB_DEFINE_COUNT="$USB_HARNESS/define-count"
mkdir -p "$USB_PROJECT/etapas" "$USB_BIN"
cp -a "$ROOT/lib" "$ROOT/libexec" "$USB_PROJECT/"
cp "$ROOT/etapas/51-usb-passthrough.sh" "$USB_PROJECT/etapas/"
cat > "$USB_PROJECT/passthrough.conf" <<'CONF'
VM_NAME="fixture-win11"
CONF
chmod 0600 "$USB_PROJECT/passthrough.conf"
cat >> "$USB_PROJECT/lib/common.sh" <<'OVERRIDES'

# Overrides exclusivos do harness I6: eliminam guards/sudo e mantêm todos os
# efeitos da transação dentro dos arquivos apontados por USB_*.
VIRSH=virsh
guard_mutation() { return 0; }
exigir_nao_root() { :; }
exigir_sudo() { :; }
vm_existe() { return 0; }
exigir_vm_desligada() { :; }
xml_backup() {
    if [[ ${USB_CONCURRENT_BACKUP:-0} -eq 1 ]]; then
        cp -- "$USB_CONCURRENT" "$USB_STATE"
    fi
    cp -- "$USB_STATE" "$USB_HARNESS/xml-backup"
}
OVERRIDES
cat > "$USB_BIN/lsusb" <<'SHIM'
#!/usr/bin/env bash
printf 'Bus %03d Device %03d: ID 046d:c52b Fixture USB\n' "${USB_BUS:?}" "${USB_DEVICE:?}"
SHIM
cat > "$USB_BIN/udevadm" <<'SHIM'
#!/usr/bin/env bash
cat -- "${USB_CAPTURE:?}"
SHIM
cat > "$USB_BIN/lspci" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
cat > "$USB_BIN/virt-xml-validate" <<'SHIM'
#!/usr/bin/env bash
exit "${USB_VALIDATE_RC:-0}"
SHIM
cat > "$USB_BIN/virsh" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
command_name=${1:-}
shift || true
case "$command_name" in
    dumpxml)
        count=0
        [[ ! -f ${USB_DUMP_COUNT:?} ]] || read -r count < "$USB_DUMP_COUNT"
        count=$((count + 1))
        printf '%s\n' "$count" > "$USB_DUMP_COUNT"
        if [[ ${USB_FAIL_DUMP:-0} -eq $count ]]; then
            exit 1
        fi
        if [[ ${USB_CONCURRENT_DUMP:-0} -eq $count ]]; then
            cp -- "${USB_CONCURRENT:?}" "${USB_STATE:?}"
        fi
        cat -- "${USB_STATE:?}"
        ;;
    domstate)
        printf '%s\n' 'shut off'
        ;;
    define)
        candidate=''
        for argument in "$@"; do
            [[ $argument == --validate ]] || candidate=$argument
        done
        [[ -n $candidate ]]
        count=0
        [[ ! -f ${USB_DEFINE_COUNT:?} ]] || read -r count < "$USB_DEFINE_COUNT"
        count=$((count + 1))
        printf '%s\n' "$count" > "$USB_DEFINE_COUNT"
        cp -- "$candidate" "${USB_STATE:?}"
        if [[ ${USB_NORMALIZE_DEFINE:-0} -eq 1 ]]; then
            # Emula o que o libvirt real faz ao publicar: aloca o endereço USB
            # do hostdev que ainda não tem um e reposiciona o elemento em
            # <devices>. Sem isto o define do harness é um cp, e a pós-condição
            # nunca enfrenta o que o hipervisor de verdade devolve.
            python3 - "${USB_STATE:?}" <<'NORMALIZE'
import sys
import xml.etree.ElementTree as ET

arvore = ET.parse(sys.argv[1])
devices = arvore.getroot().find("devices")
for hostdev in list(devices.findall("hostdev")):
    if hostdev.get("type") != "usb":
        continue
    if hostdev.find("address") is None:
        ET.SubElement(hostdev, "address", {"type": "usb", "bus": "0", "port": "2"})
    devices.remove(hostdev)
    devices.insert(0, hostdev)
arvore.write(sys.argv[1], encoding="unicode", xml_declaration=True)
NORMALIZE
        fi
        if [[ ${USB_CONCURRENT_AFTER_DEFINE:-0} -eq $count ]]; then
            cp -- "${USB_CONCURRENT:?}" "${USB_STATE:?}"
        fi
        if [[ ${USB_SIGNAL_AFTER_DEFINE:-0} -eq $count ]]; then
            kill -TERM "$PPID"
        fi
        if [[ ${USB_FAIL_DEFINE:-0} -eq $count ]]; then
            exit 1
        fi
        ;;
    *)
        printf 'virsh shim: comando inesperado: %s\n' "$command_name" >&2
        exit 64
        ;;
esac
SHIM
chmod 0755 "$USB_BIN/lsusb" "$USB_BIN/udevadm" "$USB_BIN/lspci" \
    "$USB_BIN/virt-xml-validate" "$USB_BIN/virsh"
cat > "$USB_INITIAL" <<'XML'
<domain type='kvm'><name>fixture-win11</name><memory unit='MiB'>8192</memory><vcpu>4</vcpu><devices><disk type='file' device='disk'><driver name='qemu' type='qcow2'/><source file='/vm/fixture.qcow2'/><target dev='vda' bus='virtio'/></disk></devices></domain>
XML
cat > "$USB_CONCURRENT" <<'XML'
<domain type='kvm'><name>fixture-win11</name><memory unit='MiB'>4096</memory><vcpu>4</vcpu><devices><disk type='file' device='disk'><driver name='qemu' type='qcow2'/><source file='/vm/fixture.qcow2'/><target dev='vda' bus='virtio'/></disk></devices></domain>
XML
cat > "$USB_LEGACY" <<'XML'
<domain type='kvm'><name>fixture-win11</name><memory unit='MiB'>8192</memory><vcpu>4</vcpu><devices><disk type='file' device='disk'><driver name='qemu' type='qcow2'/><source file='/vm/fixture.qcow2'/><target dev='vda' bus='virtio'/></disk><hostdev mode='subsystem' type='usb' managed='yes'><source><vendor id='0x046d'/><product id='0xc52b'/><address bus='1' device='7'/></source><alias name='hostdev0'/></hostdev></devices></domain>
XML
cp "$FIXTURES/usb-serial.json" "$USB_CAPTURE"
export USB_HARNESS USB_STATE USB_CONCURRENT USB_CAPTURE USB_DUMP_COUNT USB_DEFINE_COUNT
export USB_BUS=1 USB_DEVICE=7 VIRSH=virsh

run_usb_stage() {
    local input=$1
    shift
    printf '0\n' > "$USB_DUMP_COUNT"
    printf '0\n' > "$USB_DEFINE_COUNT"
    set +e
    printf '%b' "$input" | env PATH="$USB_BIN:$PATH" \
        bash "$USB_PROJECT/etapas/51-usb-passthrough.sh" "$@" \
        > "$USB_HARNESS/stdout" 2> "$USB_HARNESS/stderr"
    USB_STAGE_RC=$?
    set -e
}

# XML legado com alias e endereço é adotado exatamente uma vez; a projeção TAB
# preserva kind/digest vazios até a migração, sem deslocar bus/device.
cp "$USB_LEGACY" "$USB_STATE"
export USB_CONCURRENT_DUMP=0 USB_CONCURRENT_AFTER_DEFINE=0 USB_SIGNAL_AFTER_DEFINE=0 USB_FAIL_DEFINE=0 USB_FAIL_DUMP=0
run_usb_stage '1\n1\ns\n0\n'
[[ $USB_STAGE_RC -eq 0 ]] || fail "migração USB legada shell falhou: $(<"$USB_HARNESS/stderr")"
[[ $(grep -o 'type="usb"' "$USB_STATE" | wc -l) == 1 ]] || fail 'migração USB legada duplicou hostdev'
grep -q 'identity-sha256=' "$USB_STATE" || fail 'migração USB legada não persistiu binding estável'

# Erro de dump trafega no shell atual e mantém diagnóstico específico.
export USB_FAIL_DUMP=1
run_usb_stage '' --verificar
[[ $USB_STAGE_RC -eq 2 ]] || fail 'dump XML ilegível não produziu status público indeterminado'
grep -q 'Não foi possível ler o XML inativo' "$USB_HARNESS/stdout" \
    || fail 'diagnóstico da listagem USB se perdeu em subshell'
export USB_FAIL_DUMP=0

# Mudança que ocorre durante o backup intermediário é vista pela comparação
# final posterior ao backup e impede qualquer define.
cp "$USB_INITIAL" "$USB_STATE"
export USB_CONCURRENT_BACKUP=1 USB_CONCURRENT_DUMP=0 USB_CONCURRENT_AFTER_DEFINE=0 USB_SIGNAL_AFTER_DEFINE=0 USB_FAIL_DEFINE=0 USB_FAIL_DUMP=0
run_usb_stage '1\n1\ns\n0\n'
[[ $USB_STAGE_RC -ne 0 ]] || fail 'concorrência durante xml_backup virou sucesso'
cmp -s "$USB_STATE" "$USB_CONCURRENT" || fail 'concorrência durante xml_backup foi sobrescrita'
[[ $(<"$USB_DEFINE_COUNT") == 0 ]] || fail 'define ocorreu após concorrência durante xml_backup'

# Mudança concorrente do XML é preservada e impede define sobre baseline velho.
cp "$USB_INITIAL" "$USB_STATE"
export USB_CONCURRENT_BACKUP=0 USB_CONCURRENT_DUMP=3 USB_CONCURRENT_AFTER_DEFINE=0 USB_SIGNAL_AFTER_DEFINE=0 USB_FAIL_DEFINE=0
run_usb_stage '1\n1\ns\n0\n'
[[ $USB_STAGE_RC -ne 0 ]] || fail "mudança concorrente do XML USB não bloqueou a transação (dumps=$(<"$USB_DUMP_COUNT"); defines=$(<"$USB_DEFINE_COUNT"); stderr=$(<"$USB_HARNESS/stderr"))"
cmp -s "$USB_STATE" "$USB_CONCURRENT" || fail "transação USB não preservou XML concorrente (dumps=$(<"$USB_DUMP_COUNT"); defines=$(<"$USB_DEFINE_COUNT"); stderr=$(<"$USB_HARNESS/stderr"))"
[[ $(<"$USB_DEFINE_COUNT") == 0 ]] || fail 'define ocorreu apesar da divergência concorrente'

# Falha depois do primeiro efeito restaura e comprova o XML original.
cp "$USB_INITIAL" "$USB_STATE"
export USB_CONCURRENT_DUMP=0 USB_CONCURRENT_AFTER_DEFINE=0 USB_SIGNAL_AFTER_DEFINE=0 USB_FAIL_DEFINE=1
run_usb_stage '1\n1\ns\n0\n'
[[ $USB_STAGE_RC -ne 0 ]] || fail 'falha sintética do define USB virou sucesso'
cmp -s "$USB_STATE" "$USB_INITIAL" || fail 'rollback USB não restaurou o XML original'
[[ $(<"$USB_DEFINE_COUNT") == 2 ]] || fail 'rollback USB não executou define compensatório'

# Concorrência depois do nosso define é um terceiro estado: o rollback automático
# precisa recusar sobrescrevê-lo e preservar exatamente a edição concorrente.
cp "$USB_INITIAL" "$USB_STATE"
export USB_CONCURRENT_DUMP=0 USB_CONCURRENT_AFTER_DEFINE=1 USB_SIGNAL_AFTER_DEFINE=0 USB_FAIL_DEFINE=0
run_usb_stage '1\n1\ns\n0\n'
[[ $USB_STAGE_RC -ne 0 ]] || fail 'concorrência pós-efeito USB virou sucesso'
cmp -s "$USB_STATE" "$USB_CONCURRENT" || fail 'rollback USB sobrescreveu XML concorrente pós-efeito'
[[ $(<"$USB_DEFINE_COUNT") == 1 ]] || fail 'conflito pós-efeito executou define compensatório destrutivo'
grep -q 'CONFLITO' "$USB_HARNESS/stderr" || fail 'conflito pós-efeito não produziu diagnóstico explícito'

# TERM na janela mutante cai no trap e restaura somente quando o estado ainda é
# o candidato desta execução.
cp "$USB_INITIAL" "$USB_STATE"
export USB_CONCURRENT_DUMP=0 USB_CONCURRENT_AFTER_DEFINE=0 USB_SIGNAL_AFTER_DEFINE=1 USB_FAIL_DEFINE=0
run_usb_stage '1\n1\ns\n0\n'
[[ $USB_STAGE_RC -ne 0 ]] || fail 'TERM pós-define USB virou sucesso'
cmp -s "$USB_STATE" "$USB_INITIAL" || fail 'TERM pós-define deixou candidato USB aplicado'
[[ $(<"$USB_DEFINE_COUNT") == 2 ]] || fail 'TERM pós-define não executou rollback comprovado'

# Sucesso, segunda execução no-op e renumeração da mesma identidade.
cp "$USB_INITIAL" "$USB_STATE"
export USB_CONCURRENT_DUMP=0 USB_CONCURRENT_AFTER_DEFINE=0 USB_SIGNAL_AFTER_DEFINE=0 USB_FAIL_DEFINE=0
run_usb_stage '1\n1\ns\n0\n'
[[ $USB_STAGE_RC -eq 0 ]] || fail "adição USB shell falhou: $(<"$USB_HARNESS/stderr")"
[[ $(<"$USB_DEFINE_COUNT") == 1 ]] || fail 'adição USB não executou exatamente um define'
grep -q 'identity-sha256=' "$USB_STATE" || fail 'adição USB não persistiu metadata de identidade'
USB_HASH_BEFORE=$(sha256sum "$USB_STATE")

# Mesmo VID:PID com outro serial não comprova o retorno da unidade persistida.
sed 's/FIXTURE-USB-1/FIXTURE-USB-OTHER/' "$FIXTURES/usb-serial.json" > "$USB_CAPTURE"
run_usb_stage '' --verificar
[[ $USB_STAGE_RC -eq 2 ]] || fail 'verificação USB aceitou outra unidade do mesmo VID:PID'
grep -q 'não teve a identidade persistida comprovada' "$USB_HARNESS/stdout" \
    || fail 'verificação USB não diagnosticou identidade física ausente'
cp "$FIXTURES/usb-serial.json" "$USB_CAPTURE"

run_usb_stage '1\n0\n'
[[ $USB_STAGE_RC -eq 0 ]] || fail 'segunda execução USB convergente falhou'
[[ $(<"$USB_DEFINE_COUNT") == 0 ]] || fail 'segunda execução USB convergente executou define'
[[ $(sha256sum "$USB_STATE") == "$USB_HASH_BEFORE" ]] || fail 'segunda execução USB alterou o XML'

sed 's/"bus":1/"bus":4/; s/"device":7/"device":22/' \
    "$FIXTURES/usb-serial.json" > "$USB_CAPTURE"
export USB_BUS=4 USB_DEVICE=22
run_usb_stage '1\n1\ns\n0\n'
[[ $USB_STAGE_RC -eq 0 ]] || fail 'renumeração da mesma identidade USB foi recusada'
[[ $(<"$USB_DEFINE_COUNT") == 1 ]] || fail 'renumeração USB não convergiu com um define'
grep -q 'bus="4" device="22"' "$USB_STATE" \
    || fail 'endereço efêmero USB não foi atualizado após renumeração'

# Remoção explícita usa a identidade persistida e deixa cardinalidade zero.
run_usb_stage '1\ns\n' --remover
[[ $USB_STAGE_RC -eq 0 ]] || fail 'remoção USB explícita falhou'
! grep -q "type=\"usb\"" "$USB_STATE" || fail 'remoção USB deixou hostdev gerenciado'

# O define real do libvirt NÃO devolve o candidato: ele aloca <address
# type='usb'> no hostdev novo e o reposiciona em <devices>. Exigir igualdade
# canônica total com o candidato transformava toda adição em falso conflito,
# com o efeito já publicado e o rollback recusado. A pós-condição precisa
# aceitar a normalização do hipervisor e continuar provando que nada mais mudou.
cp "$USB_INITIAL" "$USB_STATE"
export USB_BUS=1 USB_DEVICE=7
cp "$FIXTURES/usb-serial.json" "$USB_CAPTURE"
export USB_CONCURRENT_BACKUP=0 USB_CONCURRENT_DUMP=0 USB_CONCURRENT_AFTER_DEFINE=0
export USB_SIGNAL_AFTER_DEFINE=0 USB_FAIL_DEFINE=0 USB_FAIL_DUMP=0 USB_NORMALIZE_DEFINE=1
run_usb_stage '1\n1\ns\n0\n'
[[ $USB_STAGE_RC -eq 0 ]] \
    || fail "normalização do libvirt virou falso conflito: $(<"$USB_HARNESS/stderr")"
[[ $(<"$USB_DEFINE_COUNT") == 1 ]] || fail 'adição normalizada não convergiu com um define'
grep -q 'type="usb" bus="0" port="2"' "$USB_STATE" \
    || fail 'harness não aplicou a normalização que este caso exige'
grep -q 'identity-sha256=' "$USB_STATE" \
    || fail 'adição normalizada não persistiu binding estável'

# Sob normalização, escrita concorrente de terceiro continua sendo conflito:
# a redução pela identidade só perdoa o que o libvirt mexe DENTRO do hostdev.
cp "$USB_INITIAL" "$USB_STATE"
export USB_CONCURRENT_AFTER_DEFINE=1
run_usb_stage '1\n1\ns\n0\n'
[[ $USB_STAGE_RC -ne 0 ]] || fail 'escrita concorrente pós-define virou sucesso sob normalização'
cmp -s "$USB_STATE" "$USB_CONCURRENT" \
    || fail 'rollback apagou o estado publicado por terceiro sob normalização'
export USB_CONCURRENT_AFTER_DEFINE=0 USB_NORMALIZE_DEFINE=0

printf '%s\n' 'OK: I6 inventário/legado/diff/discos/USB herméticos e sem efeitos no host'
