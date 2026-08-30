#!/bin/bash
# Testes puros do contrato de snapshots internos. Não usa libvirt real.
set -euo pipefail
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

falha() { echo "FALHA: $*" >&2; exit 1; }
TMPDIR_TESTE="$(mktemp -d)"
trap 'rm -rf -- "$TMPDIR_TESTE"' EXIT
PROJETO_TESTE="$TMPDIR_TESTE/projeto"
BIN="$TMPDIR_TESTE/bin"
mkdir -p "$PROJETO_TESTE/lib" "$PROJETO_TESTE/util" "$BIN"
cp "$RAIZ/lib/common.sh" "$PROJETO_TESTE/lib/common.sh"
cp "$RAIZ/lib/platform.sh" "$PROJETO_TESTE/lib/platform.sh"
cp "$RAIZ/lib/python-core.sh" "$PROJETO_TESTE/lib/python-core.sh"
# I5: a fachada carrega lib/shell/boot.sh de forma incondicional.
mkdir -p "$PROJETO_TESTE/lib/shell"
cp "$RAIZ/lib/shell/boot.sh" "$PROJETO_TESTE/lib/shell/boot.sh"
# I9.10: a fachada também carrega lib/shell/waivers.sh de forma
# incondicional, e o módulo lê a matriz de política em lib/policy/.
cp "$RAIZ/lib/shell/waivers.sh" "$PROJETO_TESTE/lib/shell/waivers.sh"
mkdir -p "$PROJETO_TESTE/lib/policy"
cp "$RAIZ/lib/policy/waivers.tsv" "$PROJETO_TESTE/lib/policy/waivers.tsv"
cp -a "$RAIZ/libexec" "$PROJETO_TESTE/libexec"
cp "$RAIZ/util/snapshot-vm.sh" "$PROJETO_TESTE/util/snapshot-vm.sh"
cat > "$PROJETO_TESTE/passthrough.conf" <<'CONF'
VM_NAME="fixture"
QCOW2_PATH="/vm/Windows11.qcow2"
CONF

cat > "$BIN/virsh" <<'SCRIPT'
#!/bin/bash
{
    printf 'CALL'
    printf '\t%s' "$@"
    printf '\n'
} >> "$VIRSH_LOG"
case " $* " in
    *' domstate '*)
        echo 'shut off'
        ;;
    *' snapshot-dumpxml '*)
        if [ "${SNAPSHOT_KIND:-internal}" = external ]; then
            cat <<'XML'
<domainsnapshot>
  <name>fixture-snap</name>
  <disks>
    <disk name='vda' snapshot='external'><source file='/vm/fixture-snap.qcow2'/></disk>
    <disk name='vdb' snapshot='no'/>
  </disks>
</domainsnapshot>
XML
        else
            cat <<'XML'
<domainsnapshot>
  <name>fixture-snap</name>
  <disks>
    <disk name='vda' snapshot='internal'/>
    <disk name='vdb' snapshot='no'/>
  </disks>
</domainsnapshot>
XML
        fi
        ;;
    *' dumpxml '*)
        if [ "${DOMAIN_MODE:-normal}" = overlay ]; then
            DISCO_ATIVO='/vm/fixture-overlay.qcow2'
        else
            DISCO_ATIVO='/vm/Windows11.qcow2'
        fi
        cat <<XML
<domain type='kvm'>
  <name>fixture</name>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='$DISCO_ATIVO'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='block' device='disk'>
      <driver name='qemu' type='raw'/>
      <source dev='/dev/disk/by-id/fixture-hd1'/>
      <target dev='vdb' bus='virtio'/>
    </disk>
    <disk type='file' device='cdrom'>
      <source file='/isos/windows.iso'/>
      <target dev='sda' bus='sata'/>
    </disk>
  </devices>
</domain>
XML
        ;;
    *' snapshot-create-as '*|*' snapshot-revert '*|*' snapshot-delete '*|*' snapshot-list '*)
        :
        ;;
    *)
        echo "virsh fake: chamada não prevista: $*" >&2
        exit 2
        ;;
esac
SCRIPT
chmod +x "$BIN/virsh"
export PATH="$BIN:$PATH"
export VIRSH_LOG="$TMPDIR_TESTE/virsh.log"

: > "$VIRSH_LOG"
SNAPSHOT_KIND=internal DOMAIN_MODE=normal \
    bash "$PROJETO_TESTE/util/snapshot-vm.sh" criar fixture-snap 'descrição fixture' >/dev/null
CRIAR="$(grep $'\tsnapshot-create-as\t' "$VIRSH_LOG")"
[[ "$CRIAR" == *$'\t--atomic\t'* ]] || falha "snapshot não exigiu atomicidade"
[[ "$CRIAR" == *$'\t--diskspec\tvda,snapshot=internal\t'* ]] || falha "QCOW2 principal não foi marcado internal"
[[ "$CRIAR" == *$'\t--diskspec\tvdb,snapshot=no'* ]] || falha "HD1 não foi excluído"
[[ "$CRIAR" != *'sda,snapshot='* ]] || falha "CD-ROM entrou no snapshot"
[[ "$CRIAR" != *$'\t--disk-only\t'* ]] || falha "--disk-only voltou a criar snapshot externo"

: > "$VIRSH_LOG"
printf 's\n' | SNAPSHOT_KIND=internal \
    bash "$PROJETO_TESTE/util/snapshot-vm.sh" reverter fixture-snap >/dev/null
grep -q $'\tsnapshot-revert\tfixture\tfixture-snap' "$VIRSH_LOG" \
    || falha "snapshot interno não foi revertido"

: > "$VIRSH_LOG"
set +e
SAIDA_EXTERNO="$(printf 's\n' | SNAPSHOT_KIND=external \
    bash "$PROJETO_TESTE/util/snapshot-vm.sh" reverter fixture-snap 2>&1)"
RC_EXTERNO=$?
set -e
[ "$RC_EXTERNO" -ne 0 ] || falha "snapshot externo foi aceito para reversão"
[[ "$SAIDA_EXTERNO" == *'snapshot externo'* ]] || falha "recusa do snapshot externo não foi explicada"
! grep -q $'\tsnapshot-revert\t' "$VIRSH_LOG" || falha "virsh snapshot-revert foi chamado para snapshot externo"

: > "$VIRSH_LOG"
set +e
SAIDA_OVERLAY="$(SNAPSHOT_KIND=internal DOMAIN_MODE=overlay \
    bash "$PROJETO_TESTE/util/snapshot-vm.sh" criar outro-snap 2>&1)"
RC_OVERLAY=$?
set -e
[ "$RC_OVERLAY" -ne 0 ] || falha "overlay externo ativo foi tratado como QCOW2 principal"
[[ "$SAIDA_OVERLAY" == *'overlay externo'* ]] || falha "bloqueio do overlay externo não foi explicado"
! grep -q $'\tsnapshot-create-as\t' "$VIRSH_LOG" || falha "snapshot foi tentado sobre XML divergente"

# O backup também deve comparar QCOW2_PATH com o source ativo do XML antes de
# inspecionar ou copiar dados. Um overlay externo precisa falhar fechado.
cp "$RAIZ/util/backup-vm.sh" "$PROJETO_TESTE/util/backup-vm.sh"
cat > "$PROJETO_TESTE/passthrough.conf" <<CONF
VM_NAME="fixture"
QCOW2_PATH="/vm/Windows11.qcow2"
BACKUPS_VM_DIR="$TMPDIR_TESTE/backup-dest"
CONF
cat > "$BIN/sudo" <<'SCRIPT'
#!/bin/bash
case "${1:-}" in
    -n) shift ;;
    -v) exit 0 ;;
esac
exec "$@"
SCRIPT
cat > "$BIN/qemu-img" <<'SCRIPT'
#!/bin/bash
echo qemu-img >> "$BACKUP_COMMAND_LOG"
exit 0
SCRIPT
cat > "$BIN/rsync" <<'SCRIPT'
#!/bin/bash
echo rsync >> "$BACKUP_COMMAND_LOG"
exit 0
SCRIPT
chmod +x "$BIN/sudo" "$BIN/qemu-img" "$BIN/rsync"
export BACKUP_COMMAND_LOG="$TMPDIR_TESTE/backup-commands.log"
: > "$BACKUP_COMMAND_LOG"

# O utilitário deve reclassificar fisicamente o destino antes de qualquer
# mutação: escape lexical é erro e alias externo para dentro exige mount ativo.
WORKING_DISK_FIXTURE="$TMPDIR_TESTE/workingDisk"
FORA_WORKING_DISK="$TMPDIR_TESTE/fora-working-disk"
ALIAS_WORKING_DISK="$TMPDIR_TESTE/alias-working-disk"
mkdir -p "$WORKING_DISK_FIXTURE" "$FORA_WORKING_DISK"
ln -s "$FORA_WORKING_DISK" "$WORKING_DISK_FIXTURE/escape"
cat > "$PROJETO_TESTE/passthrough.conf" <<CONF
VM_NAME="fixture"
QCOW2_PATH="/vm/Windows11.qcow2"
WORKING_DISK_PATH="$WORKING_DISK_FIXTURE"
WORKING_DISK_DISPENSADO=""
BACKUPS_VM_DIR="$WORKING_DISK_FIXTURE/escape/backups"
CONF
set +e
SAIDA_ESCAPE="$(DOMAIN_MODE=normal bash "$PROJETO_TESTE/util/backup-vm.sh" 2>&1)"
RC_ESCAPE=$?
set -e
[ "$RC_ESCAPE" -ne 0 ] || falha "backup aceitou destino lexical interno que resolve para fora"
[[ "$SAIDA_ESCAPE" == *'contenção insegura'* && "$SAIDA_ESCAPE" == *'resolve para fora'* ]] \
    || falha "backup não explicou o escape simbólico do workingDisk"
[ ! -s "$BACKUP_COMMAND_LOG" ] || falha "backup executou qemu-img/rsync antes de rejeitar escape simbólico"

ln -s "$WORKING_DISK_FIXTURE" "$ALIAS_WORKING_DISK"
cat > "$PROJETO_TESTE/passthrough.conf" <<CONF
VM_NAME="fixture"
QCOW2_PATH="/vm/Windows11.qcow2"
WORKING_DISK_PATH="$WORKING_DISK_FIXTURE"
WORKING_DISK_DISPENSADO=""
BACKUPS_VM_DIR="$ALIAS_WORKING_DISK/backups"
CONF
: > "$BACKUP_COMMAND_LOG"
set +e
SAIDA_ALIAS="$(DOMAIN_MODE=normal bash "$PROJETO_TESTE/util/backup-vm.sh" 2>&1)"
RC_ALIAS=$?
set -e
[ "$RC_ALIAS" -ne 0 ] || falha "backup por alias interno ignorou workingDisk desmontado"
[[ "$SAIDA_ALIAS" == *'workingDisk não está montado exatamente'* ]] \
    || falha "alias externo para dentro não armou a validação do mountpoint"
[ ! -s "$BACKUP_COMMAND_LOG" ] || falha "backup executou qemu-img/rsync com workingDisk desmontado"

# BACKUPS_VM_DIR explícito e fisicamente externo continua tendo prioridade,
# mesmo com WORKING_DISK_PATH configurado e desmontado; o fluxo deve alcançar
# a rejeição posterior do overlay ativo.
cat > "$PROJETO_TESTE/passthrough.conf" <<CONF
VM_NAME="fixture"
QCOW2_PATH="/vm/Windows11.qcow2"
WORKING_DISK_PATH="$WORKING_DISK_FIXTURE"
WORKING_DISK_DISPENSADO=""
BACKUPS_VM_DIR="$TMPDIR_TESTE/backup-dest"
CONF
: > "$BACKUP_COMMAND_LOG"
set +e
SAIDA_BACKUP="$(DOMAIN_MODE=overlay bash "$PROJETO_TESTE/util/backup-vm.sh" 2>&1)"
RC_BACKUP=$?
set -e
[ "$RC_BACKUP" -ne 0 ] || falha "backup aceitou QCOW2_PATH obsoleto diante de overlay ativo"
[[ "$SAIDA_BACKUP" == *'overlay externo'* ]] || falha "backup não explicou a divergência do disco ativo"
[ ! -s "$BACKUP_COMMAND_LOG" ] || falha "backup inspecionou/copiou dados antes de rejeitar o overlay"

printf '%s\n' SNAPSHOT_SAFETY_TESTS_OK
