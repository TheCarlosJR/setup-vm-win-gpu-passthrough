#!/bin/bash
# Testes puros do inventário/reset. Não usa sudo, serviços, /sys gravável ou discos reais.
set -euo pipefail
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$RAIZ/lib/common.sh"

falha() { echo "FALHA: $*" >&2; exit 1; }
esperar_falha() {
    local descricao="$1"; shift
    if "$@"; then falha "$descricao deveria falhar"; fi
}

TMPDIR_TESTE="$(mktemp -d)"
trap 'rm -rf -- "$TMPDIR_TESTE"' EXIT
DIR_INV="$TMPDIR_TESTE/inventarios"
mkdir -p "$DIR_INV"

# Contenção física do workingDisk: destino final pode ainda não existir, alias
# externo para dentro continua dependente, e filho simbólico que escapa falha
# com estado distinto de um destino externo legítimo.
WORKING_DISK_FIXTURE="$TMPDIR_TESTE/workingDisk"
FORA_WORKING_DISK="$TMPDIR_TESTE/fora-working-disk"
ALIAS_WORKING_DISK="$TMPDIR_TESTE/alias-working-disk"
mkdir -p "$WORKING_DISK_FIXTURE" "$FORA_WORKING_DISK"
caminho_dentro_working_disk "$WORKING_DISK_FIXTURE/backups-vm/futuro" "$WORKING_DISK_FIXTURE" \
    || falha "filho ainda inexistente não foi reconhecido dentro do workingDisk"
ln -s "$WORKING_DISK_FIXTURE" "$ALIAS_WORKING_DISK"
caminho_dentro_working_disk "$ALIAS_WORKING_DISK/backups-vm" "$WORKING_DISK_FIXTURE" \
    || falha "alias externo que resolve para dentro não armou a dependência do workingDisk"
ln -s "$FORA_WORKING_DISK" "$WORKING_DISK_FIXTURE/escape"
if caminho_dentro_working_disk "$WORKING_DISK_FIXTURE/escape/backups-vm" "$WORKING_DISK_FIXTURE"; then
    falha "filho lexical que resolve para fora foi aceito"
else
    RC_CONTENCAO=$?
fi
[ "$RC_CONTENCAO" -eq 2 ] || falha "escape simbólico retornou $RC_CONTENCAO em vez de erro de contenção"
[[ "$WORKING_DISK_CONTENCAO_ERRO" == *'resolve para fora'* ]] \
    || falha "escape simbólico não produziu diagnóstico acionável"
if caminho_dentro_working_disk "$FORA_WORKING_DISK/backups-vm" "$WORKING_DISK_FIXTURE"; then
    falha "destino externo foi classificado como interno"
else
    RC_CONTENCAO=$?
fi
[ "$RC_CONTENCAO" -eq 1 ] || falha "destino externo legítimo retornou $RC_CONTENCAO"
esperar_falha "WORKING_DISK_PATH simbólico" validar_working_disk_montado "$ALIAS_WORKING_DISK"
[[ "$WORKING_DISK_ERRO" == *'componentes simbólicos'* ]] \
    || falha "base simbólica não foi rejeitada antes da validação de mountpoint"

SNAPSHOT=$'CPU|Architecture|x86_64\nCPU|CPU(s)|8\nCPU|On-line CPU(s) list|0-7\nCPU|Thread(s) per core|2\nCPU|Core(s) per socket|4\nCPU|Socket(s)|1\nCPU|Model name|Fixture CPU\nRAM_MIB|32768\nPCI|0000:01:00.0|0300|1234:5678\nDISK|BYTES="1073741824" MODEL="Fixture Disk" SERIAL="SER001" TYPE="disk"'
criar_inventario() {
    local caminho="$1" snapshot="${2:-$SNAPSHOT}"
    cat > "$caminho" <<EOF
== HARDWARE IDENTITY ==
$snapshot
== CPU ==
fixture cpu
== RAM ==
fixture ram
== BASEBOARD ==
fixture board
== BIOS ==
fixture bios
== PCI ==
fixture pci
== BLOCK DEVICES ==
fixture disk
== IOMMU/DMAR (pré-configuração) ==
fixture iommu
EOF
}

# Resolvedor: symlink relativo tem prioridade; fallback aceita formatos legado
# e novo e usa ordem lexical C, ignorando artefatos e vazios.
criar_inventario "$DIR_INV/inventario-20260803.txt"
criar_inventario "$DIR_INV/inventario-20260803-120000-000000001.txt"
criar_inventario "$DIR_INV/inventario-20260804-010000-000000001.txt"
criar_inventario "$DIR_INV/diagnostico-99999999.txt"
criar_inventario "$DIR_INV/grupos-iommu-99999999.txt"
: > "$DIR_INV/inventario-20990101.txt"
ln -s inventario-20260803-120000-000000001.txt "$DIR_INV/ultimo-inventario.txt"
resolver_ultimo_inventario "$DIR_INV" >/dev/null || falha "$INVENTARIO_ERRO"
[ "$INVENTARIO_RESOLVIDO" = "$DIR_INV/inventario-20260803-120000-000000001.txt" ] \
    || falha "ponteiro relativo válido não teve prioridade"
rm -f "$DIR_INV/ultimo-inventario.txt"
resolver_ultimo_inventario "$DIR_INV" >/dev/null || falha "$INVENTARIO_ERRO"
[ "$INVENTARIO_RESOLVIDO" = "$DIR_INV/inventario-20260804-010000-000000001.txt" ] \
    || falha "fallback lexical não escolheu o inventário novo mais recente"
ln -s /etc/passwd "$DIR_INV/ultimo-inventario.txt"
esperar_falha "ponteiro externo" resolver_ultimo_inventario "$DIR_INV"
[ -z "$INVENTARIO_RESOLVIDO" ] || falha "ponteiro externo selecionou um inventário"
rm -f "$DIR_INV/ultimo-inventario.txt"
ln -s inventario-20991231.txt "$DIR_INV/ultimo-inventario.txt"
esperar_falha "ponteiro quebrado" resolver_ultimo_inventario "$DIR_INV"
[ -z "$INVENTARIO_RESOLVIDO" ] || falha "link quebrado foi aceito"
rm -f "$DIR_INV/ultimo-inventario.txt"
printf '%s\n' 'não é um inventário' > "$DIR_INV/ultimo-inventario.txt"
esperar_falha "ponteiro regular" resolver_ultimo_inventario "$DIR_INV"
rm -f "$DIR_INV/ultimo-inventario.txt"
printf '%s\n' 'parcial' > "$DIR_INV/inventario-20990102.txt"
resolver_ultimo_inventario "$DIR_INV" >/dev/null || falha "$INVENTARIO_ERRO"
[ "$INVENTARIO_RESOLVIDO" = "$DIR_INV/inventario-20260804-010000-000000001.txt" ] \
    || falha "fallback selecionou inventário parcial mais novo"

DIR_VAZIO="$TMPDIR_TESTE/vazio"
mkdir "$DIR_VAZIO"
esperar_falha "diretório sem inventário" resolver_ultimo_inventario "$DIR_VAZIO"

# No mesmo dia, o formato novo tem horário real e deve superar o legado (00:00).
DIR_MESMO_DIA="$TMPDIR_TESTE/mesmo-dia"
mkdir "$DIR_MESMO_DIA"
criar_inventario "$DIR_MESMO_DIA/inventario-20260803.txt"
criar_inventario "$DIR_MESMO_DIA/inventario-20260803-120000-000000001.txt"
resolver_ultimo_inventario "$DIR_MESMO_DIA" >/dev/null || falha "$INVENTARIO_ERRO"
[ "$INVENTARIO_RESOLVIDO" = "$DIR_MESMO_DIA/inventario-20260803-120000-000000001.txt" ] \
    || falha "inventário legado venceu coleta nova do mesmo dia"

# Publicação: nomes distintos, ponteiro relativo e preservação do ponteiro
# anterior quando a preparação do novo link falha depois de publicar o relatório.
DIR_PUBLICACAO="$TMPDIR_TESTE/publicacao"
mkdir "$DIR_PUBLICACAO"
TMP1="$(mktemp "$DIR_PUBLICACAO/.inventario.tmp.XXXXXX")"
criar_inventario "$TMP1"
publicar_inventario_completo "$TMP1" "$DIR_PUBLICACAO" 20260803-120000-000000001 >/dev/null \
    || falha "$INVENTARIO_ERRO"
PRIMEIRO="$INVENTARIO_PUBLICADO"
[ "$(readlink "$DIR_PUBLICACAO/ultimo-inventario.txt")" = "${PRIMEIRO##*/}" ] \
    || falha "ponteiro publicado não é relativo ao primeiro inventário"
TMP2="$(mktemp "$DIR_PUBLICACAO/.inventario.tmp.XXXXXX")"
criar_inventario "$TMP2"
publicar_inventario_completo "$TMP2" "$DIR_PUBLICACAO" 20260803-120000-000000002 >/dev/null \
    || falha "$INVENTARIO_ERRO"
SEGUNDO="$INVENTARIO_PUBLICADO"
[ "$PRIMEIRO" != "$SEGUNDO" ] && [ -f "$PRIMEIRO" ] && [ -f "$SEGUNDO" ] \
    || falha "duas publicações não preservaram históricos distintos"
[ "$(readlink "$DIR_PUBLICACAO/ultimo-inventario.txt")" = "${SEGUNDO##*/}" ] \
    || falha "ponteiro não selecionou a segunda publicação"
TMP3="$(mktemp "$DIR_PUBLICACAO/.inventario.tmp.XXXXXX")"
criar_inventario "$TMP3"
mkdir "$TMPDIR_TESTE/bin-falha"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$TMPDIR_TESTE/bin-falha/ln"
chmod +x "$TMPDIR_TESTE/bin-falha/ln"
PONTEIRO_ANTES="$(readlink "$DIR_PUBLICACAO/ultimo-inventario.txt")"
esperar_falha "falha ao preparar ponteiro" env PATH="$TMPDIR_TESTE/bin-falha:$PATH" \
    bash -c 'source "$1"; publicar_inventario_completo "$2" "$3" "$4" >/dev/null' _ \
    "$RAIZ/lib/common.sh" "$TMP3" "$DIR_PUBLICACAO" 20260803-120000-000000003
[ "$(readlink "$DIR_PUBLICACAO/ultimo-inventario.txt")" = "$PONTEIRO_ANTES" ] \
    || falha "falha de publicação substituiu o ponteiro anterior"

# Validação estrutural e comparação relevante, incluindo tolerância de RAM.
VALIDO="$DIR_INV/inventario-20260805-010000-000000001.txt"
criar_inventario "$VALIDO"
validar_inventario_principal "$VALIDO" || falha "$INVENTARIO_ERRO"
comparar_inventario_com_hardware "$VALIDO" "$SNAPSHOT" || falha "$INVENTARIO_ERRO"
LEGADO="$DIR_INV/inventario-20260806.txt"
cat > "$LEGADO" <<'EOF'
== CPU ==
Architecture:                         x86_64
CPU(s):                               8
On-line CPU(s) list:                  0-7
Thread(s) per core:                   2
Core(s) per socket:                   4
Socket(s):                            1
Model name:                           Fixture CPU
== RAM ==
Memory Device
        Size: 32768 MB
== BASEBOARD ==
fixture board
== BIOS ==
fixture bios
== PCI ==
01:00.0 VGA compatible controller [0300]: Fixture GPU [1234:5678]
== BLOCK DEVICES ==
NAME  SIZE TYPE FSTYPE MOUNTPOINT MODEL        SERIAL
sda   1G   disk                    Fixture Disk SER001
== IOMMU/DMAR (pré-configuração) ==
fixture iommu
EOF
comparar_inventario_com_hardware "$LEGADO" "$SNAPSHOT" \
    || falha "inventário legado válido não foi comparável: $INVENTARIO_ERRO ${INVENTARIO_DIFERENCAS:-}"
SNAPSHOT_RAM_TOLERADA="${SNAPSHOT/RAM_MIB|32768/RAM_MIB|33792}"
comparar_inventario_com_hardware "$VALIDO" "$SNAPSHOT_RAM_TOLERADA" \
    || falha "variação razoável de RAM deveria ser tolerada"
SNAPSHOT_CPU_DIFERENTE="${SNAPSHOT/CPU|CPU(s)|8/CPU|CPU(s)|16}"
esperar_falha "topologia de CPU divergente" comparar_inventario_com_hardware "$VALIDO" "$SNAPSHOT_CPU_DIFERENTE"
[[ "$INVENTARIO_DIFERENCAS" == *CPU* ]] || falha "diferença de CPU não foi reportada"
SNAPSHOT_DISCO_DIFERENTE="${SNAPSHOT/SER001/SER999}"
esperar_falha "serial de disco divergente" comparar_inventario_com_hardware "$VALIDO" "$SNAPSHOT_DISCO_DIFERENTE"
[[ "$INVENTARIO_DIFERENCAS" == *Discos* ]] || falha "diferença de disco não foi reportada"
INCOMPLETO="$TMPDIR_TESTE/incompleto.txt"
printf '%s\n' '== CPU ==' 'x' > "$INCOMPLETO"
esperar_falha "inventário sem seções obrigatórias" validar_inventario_principal "$INCOMPLETO"

# Backup restrito e reset único preservam somente as opções fora do escopo.
CONF_ARQUIVO="$TMPDIR_TESTE/passthrough.conf"
BACKUPS_DIR="$TMPDIR_TESTE/backups"
cat > "$CONF_ARQUIVO" <<'CONF'
USUARIO_LINUX="antigo"
VM_NAME="antiga"
GPU_PCI_ID="0000:01:00.0"
HD1_DISPENSADO="sim"
WORKING_DISK_PATH="/mnt/workingDisk"
WORKING_DISK_DISPENSADO=""
CPUS_VM="2-7"
VM_RAM_MB="8192"
INTERFACE_FISICA="eth0"
REDE_MODO="nat"
VM_IP_FIXO="192.168.100.2"
TRANSFER_USER="antigo"
AIRLOCK_DIR="/tmp/antigo"
ISO_WINDOWS="/vm/windows.iso"
IOMMU_GROUP_GPU="7"
QCOW2_PATH="/vm/preservado.qcow2"
QCOW2_TAMANHO="300G"
REDE_BRIDGE="br9"
REDE_LIBVIRT="rede-preservada"
REDE_BRIDGE_LIBVIRT="virbr9"
VM_NIC_MAC="52:54:00:12:34:56"
AIRLOCK_BIND="/srv/preservado"
BACKUPS_VM_DIR="/backup/preservado"
CONF
cp "$CONF_ARQUIVO" "$TMPDIR_TESTE/conf-original"
backup_e_resetar_config_etapa02
[ -n "$BACKUP_CONFIG_ETAPA02" ] && [ -f "$BACKUP_CONFIG_ETAPA02" ] || falha "backup não criado"
cmp -s "$TMPDIR_TESTE/conf-original" "$BACKUP_CONFIG_ETAPA02" || falha "backup diverge do original"
[ "$(stat -c '%a' "$BACKUP_CONFIG_ETAPA02")" = 600 ] || falha "backup sem permissão 600"
[[ "${BACKUP_CONFIG_ETAPA02##*/}" =~ ^passthrough\.conf\.pre-redetectar-[0-9]{8}-[0-9]{6}-[0-9]{9}\.[[:alnum:]]{6}\.bak$ ]] \
    || falha "nome do backup fora do contrato"
carregar_conf
CHAVES_RESET_ESPERADAS=(
    USUARIO_LINUX VM_NAME BOOTLOADER GPU_PCI_ID GPU_AUDIO_PCI_ID
    GPU_VENDOR_DEVICE_ID GPU_AUDIO_VENDOR_DEVICE_ID IOMMU_GROUP_GPU DM_SERVICE
    NVME_DEVICE WORKING_DISK_PATH WORKING_DISK_DISPENSADO
    HD1_BY_ID_PATH HD1_DISPENSADO CPUS_VM CPUS_HOST VM_VCPUS VM_CORES VM_THREADS
    VM_RAM_MB HUGEPAGES_1G INTERFACE_FISICA REDE_MODO VM_IP_FIXO IP_FIXO_HOST
    REDE_NAT_CIDR TRANSFER_USER AIRLOCK_DIR ISO_WINDOWS ISO_VIRTIO
)
for chave in "${CHAVES_RESET_ESPERADAS[@]}"; do
    grep -q "^${chave}=\"\"$" "$CONF_ARQUIVO" || falha "$chave não participou do reset atômico"
    [ -z "${!chave:-}" ] || falha "$chave não foi limpa"
done
for chave in USUARIO_LINUX VM_NAME GPU_PCI_ID HD1_DISPENSADO WORKING_DISK_PATH \
             WORKING_DISK_DISPENSADO CPUS_VM VM_RAM_MB INTERFACE_FISICA REDE_MODO \
             VM_IP_FIXO TRANSFER_USER AIRLOCK_DIR ISO_WINDOWS IOMMU_GROUP_GPU; do
    [ -z "${!chave:-}" ] || falha "$chave não foi limpa"
done
[ "$QCOW2_PATH" = /vm/preservado.qcow2 ] \
    && [ "$QCOW2_TAMANHO" = 300G ] \
    && [ "$REDE_BRIDGE" = br9 ] \
    && [ "$REDE_LIBVIRT" = rede-preservada ] \
    && [ "$REDE_BRIDGE_LIBVIRT" = virbr9 ] \
    && [ "$VM_NIC_MAC" = 52:54:00:12:34:56 ] \
    && [ "$AIRLOCK_BIND" = /srv/preservado ] \
    && [ "$BACKUPS_VM_DIR" = /backup/preservado ] \
    || falha "opções fora do reset não foram preservadas"

# Sem argumento e --redetectar resolvem para o mesmo modo; verificar é separado.
[ "$(modo_execucao_etapa02)" = reiniciar ] || falha "modo sem argumento"
[ "$(modo_execucao_etapa02 --redetectar)" = reiniciar ] || falha "alias --redetectar"
[ "$(modo_execucao_etapa02 --verificar)" = verificar ] || falha "modo --verificar"
esperar_falha "argumento desconhecido" modo_execucao_etapa02 --desconhecido

# Os verificadores reais são executados em subprocessos e não podem alterar
# configuração, backups ou inventário. O fixture evita qualquer coleta real.
ESTADO_CONF_ANTES="$(sha256sum "$CONF_ARQUIVO" | awk '{print $1}')|$(stat -c '%y' "$CONF_ARQUIVO")"
QTD_BACKUPS_ANTES="$(find "$BACKUPS_DIR" -maxdepth 1 -type f | wc -l)"
HOME="$TMPDIR_TESTE/home"; export HOME
mkdir -p "$HOME/inventario-hardware"
cp "$VALIDO" "$HOME/inventario-hardware/inventario-20260805-010000-000000001.txt"
ln -s inventario-20260805-010000-000000001.txt "$HOME/inventario-hardware/ultimo-inventario.txt"
bash "$RAIZ/etapas/00-inventario.sh" --verificar >/dev/null
# A etapa 02 aponta para o conf do projeto, que pode estar ausente; qualquer
# status é aceitável, mas o modo precisa terminar sem criar/alterar o arquivo.
CONF_PROJETO="$RAIZ/passthrough.conf"
if [ -e "$CONF_PROJETO" ]; then
    ESTADO_PROJETO_ANTES="$(sha256sum "$CONF_PROJETO" | awk '{print $1}')|$(stat -c '%y' "$CONF_PROJETO")"
else
    ESTADO_PROJETO_ANTES=ausente
fi
bash "$RAIZ/etapas/02-detectar-config.sh" --verificar >/dev/null 2>&1 || true
if [ -e "$CONF_PROJETO" ]; then
    ESTADO_PROJETO_DEPOIS="$(sha256sum "$CONF_PROJETO" | awk '{print $1}')|$(stat -c '%y' "$CONF_PROJETO")"
else
    ESTADO_PROJETO_DEPOIS=ausente
fi
[ "$ESTADO_PROJETO_ANTES" = "$ESTADO_PROJETO_DEPOIS" ] || falha "--verificar alterou passthrough.conf"
[ "$ESTADO_CONF_ANTES" = "$(sha256sum "$CONF_ARQUIVO" | awk '{print $1}')|$(stat -c '%y' "$CONF_ARQUIVO")" ] \
    || falha "verificadores alteraram o conf de teste"
[ "$QTD_BACKUPS_ANTES" = "$(find "$BACKUPS_DIR" -maxdepth 1 -type f | wc -l)" ] \
    || falha "--verificar criou backup"

printf '%s\n' INVENTARIO_REDETECTAR_TESTS_OK
