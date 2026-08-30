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
    NVME_DEVICE SYSTEM_DISK_FINGERPRINT
    WORKING_DISK_PATH WORKING_DISK_FINGERPRINT WORKING_DISK_DISPENSADO
    HD1_BY_ID_PATH HD1_DISK_FINGERPRINT HD1_DISPENSADO CPUS_VM CPUS_HOST VM_VCPUS VM_CORES VM_THREADS
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
# A raiz de estado precisa cair dentro do temporário mesmo quando o ambiente
# real define XDG_STATE_HOME, e o fixture mora onde o acessor aponta: se a etapa
# voltar a montar o caminho legado por conta própria, --verificar não acha nada.
XDG_STATE_HOME="$HOME/.local/state"; export XDG_STATE_HOME
LOG_ACOES_DIR="$XDG_STATE_HOME/vm-passthrough"
LOG_ACOES_ARQUIVO="$LOG_ACOES_DIR/acoes.log"
INVENTARIO_LEGADO_DIR="$HOME/inventario-hardware"
DIR_ESTADO_INV="$(diretorio_inventario)"
mkdir -p "$DIR_ESTADO_INV"
cp "$VALIDO" "$DIR_ESTADO_INV/inventario-20260805-010000-000000001.txt"
ln -s inventario-20260805-010000-000000001.txt "$DIR_ESTADO_INV/ultimo-inventario.txt"
bash "$RAIZ/etapas/00-inventario.sh" --verificar >/dev/null \
    || falha "a etapa 1 não achou o inventário do fixture na raiz única de estado"
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

# --- Migração da pasta legada de relatórios para a raiz única de estado -------
# Cada cenário roda em uma HOME temporária própria: a origem é sempre
# "$HOME/inventario-hardware" por contrato da transação e o destino sai do
# acessor, então nada aqui toca a home real nem a raiz de estado do usuário.
MIG_RAIZ="$TMPDIR_TESTE/migracao"
CP_REAL="$(command -v cp)"
DESTINO_MIGRACAO=""

usar_home_migracao() {
    # usar_home_migracao NOME: isola HOME, raiz de estado e pasta legada em um
    # cenário próprio e publica o destino do acessor em DESTINO_MIGRACAO. Nada de
    # substituição de comando aqui: as variáveis precisam valer no shell do teste.
    HOME="$MIG_RAIZ/$1"; export HOME
    XDG_STATE_HOME="$HOME/.local/state"; export XDG_STATE_HOME
    LOG_ACOES_DIR="$XDG_STATE_HOME/vm-passthrough"
    LOG_ACOES_ARQUIVO="$LOG_ACOES_DIR/acoes.log"
    INVENTARIO_LEGADO_DIR="$HOME/inventario-hardware"
    mkdir -p "$HOME"
    DESTINO_MIGRACAO="$(diretorio_inventario)"
}

assinatura_migracao() {
    # Metadados e bytes de uma árvore: tipo, modo, mtime com nanossegundos, alvo
    # de link e digest do conteúdo, em ordem estável. O tamanho de diretório fica
    # de fora de propósito, porque depende do histórico do sistema de arquivos.
    local base="$1"
    ( cd -- "$base" && LC_ALL=C find . -mindepth 1 -printf '%p|%y|%m|%T@|%l\n' | LC_ALL=C sort )
    ( cd -- "$base" && LC_ALL=C find . -type f -exec sha256sum -- {} + 2>/dev/null | LC_ALL=C sort )
}

assinatura_no_op() {
    # Regra 17: a segunda execução precisa ser no-op exato em caminho, modo,
    # tamanho e mtime, inclusive na raiz observada.
    local base="$1"
    ( cd -- "$base" && LC_ALL=C find . -printf '%p|%m|%s|%T@\n' | LC_ALL=C sort )
}

arvore_vazia() {
    # 0 quando o diretório não existe ou não tem nenhuma entrada.
    local base="$1"
    [ -d "$base" ] || return 0
    [ -z "$(cd -- "$base" && LC_ALL=C find . -mindepth 1 -printf 'x\n')" ]
}

contar_entradas() {
    ( cd -- "$1" && LC_ALL=C find . -mindepth 1 -printf 'x\n' | wc -l )
}

povoar_legado() {
    # Pasta legada realista: inventário válido publicável, ponteiro relativo,
    # subdiretório com modo restrito e arquivo com modo/mtime fora do padrão.
    local origem="$1"
    mkdir -p "$origem/historico"
    criar_inventario "$origem/inventario-20260807-010000-000000001.txt"
    criar_inventario "$origem/historico/inventario-20260701-010000-000000001.txt"
    printf '%s\n' 'diagnóstico antigo' > "$origem/diagnostico-20260701-0900.txt"
    ln -s inventario-20260807-010000-000000001.txt "$origem/ultimo-inventario.txt"
    chmod 640 "$origem/diagnostico-20260701-0900.txt"
    chmod 700 "$origem/historico"
    touch -d '2026-07-01 09:00:00.123456789' "$origem/diagnostico-20260701-0900.txt"
}

# (a) Migração aceita: move tudo, preserva metadados e remove a origem só depois
# de conferir a cópia inteira.
usar_home_migracao sucesso
DEST_SUCESSO="$DESTINO_MIGRACAO"
povoar_legado "$INVENTARIO_LEGADO_DIR"
ASSINATURA_ORIGEM="$(assinatura_migracao "$INVENTARIO_LEGADO_DIR")"
ITENS_ORIGEM="$(contar_entradas "$INVENTARIO_LEGADO_DIR")"
inventario_legado_pendente || falha "pasta legada com conteúdo não foi reconhecida como pendente"
[ "$INVENTARIO_LEGADO_ITENS" -eq "$ITENS_ORIGEM" ] \
    || falha "contagem de itens legados divergiu: $INVENTARIO_LEGADO_ITENS != $ITENS_ORIGEM"
SAIDA_MIG="$TMPDIR_TESTE/saida-migracao-sucesso.txt"
inventario_migracao_interativa <<< 's' > "$SAIDA_MIG" \
    || falha "migração aceita retornou erro: $(cat "$SAIDA_MIG")"
[ ! -e "$INVENTARIO_LEGADO_DIR" ] && [ ! -L "$INVENTARIO_LEGADO_DIR" ] \
    || falha "migração concluída não removeu a pasta legada"
[ "$INVENTARIO_MIGRACAO_ITENS" -eq "$ITENS_ORIGEM" ] \
    || falha "migração relatou $INVENTARIO_MIGRACAO_ITENS itens para $ITENS_ORIGEM na origem"
[ "$(assinatura_migracao "$DEST_SUCESSO")" = "$ASSINATURA_ORIGEM" ] \
    || falha "migração não preservou conteúdo, modo, mtime ou alvo de symlink no destino"
[ "$(grep -c 'Relatórios antigos encontrados' "$SAIDA_MIG")" = 1 ] \
    || falha "a pergunta da migração não apareceu exatamente uma vez"
grep -q "Migração concluída: $ITENS_ORIGEM itens conferidos em $DEST_SUCESSO" "$SAIDA_MIG" \
    || falha "migração não confirmou a conferência no destino unificado"
ALVO_PONTEIRO_MIGRADO="$(readlink "$DEST_SUCESSO/ultimo-inventario.txt")"
[[ "$ALVO_PONTEIRO_MIGRADO" != /* ]] && [ -e "$DEST_SUCESSO/$ALVO_PONTEIRO_MIGRADO" ] \
    || falha "ponteiro migrado não resolve dentro do destino unificado"

# (g) O resolvedor sem argumento passa a achar o inventário na raiz unificada.
resolver_ultimo_inventario >/dev/null || falha "$INVENTARIO_ERRO"
[ "$INVENTARIO_RESOLVIDO" = "$DEST_SUCESSO/inventario-20260807-010000-000000001.txt" ] \
    || falha "resolvedor não achou o inventário migrado: ${INVENTARIO_RESOLVIDO:-vazio}"

# (e) Segunda execução: no-op exato, sem pergunta e sem qualquer escrita.
ANTES_NO_OP="$(assinatura_no_op "$HOME")"
SAIDA_NO_OP="$TMPDIR_TESTE/saida-migracao-noop.txt"
inventario_migracao_interativa </dev/null > "$SAIDA_NO_OP" \
    || falha "segunda execução da migração retornou erro"
[ ! -s "$SAIDA_NO_OP" ] \
    || falha "segunda execução não foi silenciosa: $(cat "$SAIDA_NO_OP")"
[ "$(assinatura_no_op "$HOME")" = "$ANTES_NO_OP" ] \
    || falha "segunda execução da migração não foi no-op exato"

# (b) Colisão de nome no destino: recusa sem copiar nem remover nada.
usar_home_migracao colisao
DEST_COLISAO="$DESTINO_MIGRACAO"
povoar_legado "$INVENTARIO_LEGADO_DIR"
mkdir -p "$DEST_COLISAO/historico"
printf '%s\n' 'relatório que já morava no destino' > "$DEST_COLISAO/historico/nao-mexer.txt"
ASSINATURA_ORIGEM_COLISAO="$(assinatura_migracao "$INVENTARIO_LEGADO_DIR")"
ASSINATURA_DESTINO_COLISAO="$(assinatura_migracao "$DEST_COLISAO")"
esperar_falha "colisão de nome no destino" migrar_inventario_legado
[[ "$INVENTARIO_MIGRACAO_ERRO" == *"'historico' já existe"* ]] \
    || falha "colisão não produziu diagnóstico acionável: $INVENTARIO_MIGRACAO_ERRO"
[ "$(assinatura_migracao "$INVENTARIO_LEGADO_DIR")" = "$ASSINATURA_ORIGEM_COLISAO" ] \
    || falha "colisão de nome alterou a pasta legada"
[ "$(assinatura_migracao "$DEST_COLISAO")" = "$ASSINATURA_DESTINO_COLISAO" ] \
    || falha "colisão de nome copiou algo para o destino"

# (c) Divergência de conteúdo durante a prova: desfaz a cópia e mantém a origem.
# O cp de teste copia de verdade e corrompe um arquivo já copiado; nenhuma
# divergência pode virar remoção da origem.
usar_home_migracao divergencia
DEST_DIVERGENCIA="$DESTINO_MIGRACAO"
povoar_legado "$INVENTARIO_LEGADO_DIR"
ASSINATURA_ORIGEM_DIVERGENCIA="$(assinatura_migracao "$INVENTARIO_LEGADO_DIR")"
BIN_CP_DIVERGENTE="$TMPDIR_TESTE/bin-cp-divergente"
mkdir -p "$BIN_CP_DIVERGENTE"
cat > "$BIN_CP_DIVERGENTE/cp" <<EOF
#!/bin/sh
"$CP_REAL" "\$@" || exit \$?
if [ -f "$DEST_DIVERGENCIA/diagnostico-20260701-0900.txt" ]; then
    printf 'divergencia\n' >> "$DEST_DIVERGENCIA/diagnostico-20260701-0900.txt"
fi
exit 0
EOF
chmod +x "$BIN_CP_DIVERGENTE/cp"
if SAIDA_DIVERGENCIA="$(env PATH="$BIN_CP_DIVERGENTE:$PATH" bash -c \
        'source "$1"; migrar_inventario_legado && exit 0; printf "%s\n" "$INVENTARIO_MIGRACAO_ERRO"; exit 1' \
        _ "$RAIZ/lib/common.sh" 2>&1)"; then
    falha "cópia divergente foi aceita como migração válida"
fi
[[ "$SAIDA_DIVERGENCIA" == *divergiram* ]] \
    || falha "divergência de conteúdo não foi diagnosticada: $SAIDA_DIVERGENCIA"
[ "$(assinatura_migracao "$INVENTARIO_LEGADO_DIR")" = "$ASSINATURA_ORIGEM_DIVERGENCIA" ] \
    || falha "divergência durante a prova alterou a pasta legada"
arvore_vazia "$DEST_DIVERGENCIA" \
    || falha "divergência durante a prova não desfez a cópia no destino"

# (d) Pasta legada ausente, vazia ou simbólica: no-op silencioso nos três casos.
usar_home_migracao noop
DEST_NOOP="$DESTINO_MIGRACAO"
SAIDA_NOOP_AUSENTE="$TMPDIR_TESTE/saida-migracao-ausente.txt"
ANTES_NOOP_AUSENTE="$(assinatura_no_op "$HOME")"
esperar_falha "pasta legada ausente" inventario_legado_pendente
inventario_migracao_interativa </dev/null > "$SAIDA_NOOP_AUSENTE" \
    || falha "pasta legada ausente retornou erro"
[ ! -s "$SAIDA_NOOP_AUSENTE" ] \
    || falha "pasta legada ausente não foi silenciosa: $(cat "$SAIDA_NOOP_AUSENTE")"
[ "$(assinatura_no_op "$HOME")" = "$ANTES_NOOP_AUSENTE" ] \
    || falha "pasta legada ausente produziu escrita"
esperar_falha "migração sem pasta legada" migrar_inventario_legado
[[ "$INVENTARIO_MIGRACAO_ERRO" == *'Nada a migrar'* ]] \
    || falha "migração sem origem não diagnosticou: $INVENTARIO_MIGRACAO_ERRO"

mkdir -p "$INVENTARIO_LEGADO_DIR"
SAIDA_NOOP_VAZIA="$TMPDIR_TESTE/saida-migracao-vazia.txt"
ANTES_NOOP_VAZIA="$(assinatura_no_op "$HOME")"
esperar_falha "pasta legada vazia" inventario_legado_pendente
inventario_migracao_interativa </dev/null > "$SAIDA_NOOP_VAZIA" \
    || falha "pasta legada vazia retornou erro"
[ ! -s "$SAIDA_NOOP_VAZIA" ] \
    || falha "pasta legada vazia não foi silenciosa: $(cat "$SAIDA_NOOP_VAZIA")"
[ -d "$INVENTARIO_LEGADO_DIR" ] || falha "no-op removeu a pasta legada vazia"
[ "$(assinatura_no_op "$HOME")" = "$ANTES_NOOP_VAZIA" ] \
    || falha "pasta legada vazia produziu escrita"

rmdir "$INVENTARIO_LEGADO_DIR"
LEGADO_ALVO="$HOME/relatorios-fora-da-home-legada"
mkdir -p "$LEGADO_ALVO"
printf '%s\n' 'conteúdo apontado pelo link legado' > "$LEGADO_ALVO/inventario-20260601-010000-000000001.txt"
ln -s "$LEGADO_ALVO" "$INVENTARIO_LEGADO_DIR"
SAIDA_NOOP_LINK="$TMPDIR_TESTE/saida-migracao-link.txt"
ANTES_NOOP_LINK="$(assinatura_no_op "$HOME")"
esperar_falha "pasta legada simbólica" inventario_legado_pendente
inventario_migracao_interativa </dev/null > "$SAIDA_NOOP_LINK" \
    || falha "pasta legada simbólica retornou erro"
[ ! -s "$SAIDA_NOOP_LINK" ] \
    || falha "pasta legada simbólica não foi silenciosa: $(cat "$SAIDA_NOOP_LINK")"
[ -L "$INVENTARIO_LEGADO_DIR" ] || falha "no-op alterou o link legado"
esperar_falha "migração de pasta legada simbólica" migrar_inventario_legado
[ "$(assinatura_no_op "$HOME")" = "$ANTES_NOOP_LINK" ] \
    || falha "pasta legada simbólica produziu escrita"
arvore_vazia "$DEST_NOOP" || falha "no-op copiou algo para o destino unificado"

# (f) Recusar a migração não copia, não remove e não impede a etapa 1 de publicar
# no destino unificado.
usar_home_migracao recusa
DEST_RECUSA="$DESTINO_MIGRACAO"
povoar_legado "$INVENTARIO_LEGADO_DIR"
ASSINATURA_ORIGEM_RECUSA="$(assinatura_migracao "$INVENTARIO_LEGADO_DIR")"
SAIDA_RECUSA="$TMPDIR_TESTE/saida-migracao-recusa.txt"
inventario_migracao_interativa <<< 'n' > "$SAIDA_RECUSA" \
    || falha "recusar a migração terminou com erro"
grep -q 'Migração recusada' "$SAIDA_RECUSA" || falha "a recusa não foi registrada na saída"
[ "$(assinatura_migracao "$INVENTARIO_LEGADO_DIR")" = "$ASSINATURA_ORIGEM_RECUSA" ] \
    || falha "recusar a migração alterou a pasta legada"
arvore_vazia "$DEST_RECUSA" || falha "recusar a migração copiou algo para o destino"
mkdir -p "$DEST_RECUSA"
TMP_RECUSA="$(umask 077; mktemp "$DEST_RECUSA/.inventario.tmp.XXXXXXXXX")"
criar_inventario "$TMP_RECUSA"
publicar_inventario_completo "$TMP_RECUSA" "$DEST_RECUSA" 20260808-010000-000000001 >/dev/null \
    || falha "$INVENTARIO_ERRO"
resolver_ultimo_inventario >/dev/null || falha "$INVENTARIO_ERRO"
[ "$INVENTARIO_RESOLVIDO" = "$DEST_RECUSA/inventario-20260808-010000-000000001.txt" ] \
    || falha "publicação após a recusa não ficou visível no destino unificado"
bash "$RAIZ/etapas/00-inventario.sh" --verificar >/dev/null \
    || falha "a etapa 1 não reconheceu o inventário publicado no destino unificado após a recusa"
[ -d "$INVENTARIO_LEGADO_DIR" ] && [ ! -L "$INVENTARIO_LEGADO_DIR" ] \
    || falha "recusar a migração removeu a pasta legada"

# Nenhum consumidor pode voltar a montar o caminho legado por conta própria: o
# literal vive só em lib/common.sh, para a migração poder nomeá-lo.
for CONSUMIDOR in etapas/00-inventario.sh util/diagnostico.sh; do
    if grep -q 'inventario-hardware' "$RAIZ/$CONSUMIDOR"; then
        falha "$CONSUMIDOR voltou a citar o caminho legado em vez do acessor"
    fi
    grep -q 'diretorio_inventario' "$RAIZ/$CONSUMIDOR" \
        || falha "$CONSUMIDOR não resolve o diretório pelo acessor"
done
grep -q 'inventario_migracao_interativa' "$RAIZ/etapas/00-inventario.sh" \
    || falha "a etapa 1 não oferece a migração da pasta legada"

printf '%s\n' INVENTARIO_REDETECTAR_TESTS_OK
