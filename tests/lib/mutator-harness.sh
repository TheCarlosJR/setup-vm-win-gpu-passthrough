#!/usr/bin/env bash
# Harness stateful para execução DIRETA das etapas mutantes críticas.
# Não deve ser carregado pelo código operacional.

if [[ -n ${_MUTATOR_HARNESS_LOADED:-} ]]; then
    return 0 2>/dev/null || exit 0
fi
_MUTATOR_HARNESS_LOADED=1

_MUTATOR_HARNESS_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
_MUTATOR_HARNESS_TESTS_DIR=$(cd "$_MUTATOR_HARNESS_LIB_DIR/.." && pwd -P)
MUTATOR_HARNESS_SOURCE=$(cd "$_MUTATOR_HARNESS_TESTS_DIR/.." && pwd -P)
MUTATOR_HARNESS_DISPATCH="$_MUTATOR_HARNESS_LIB_DIR/mutator-dispatch.py"
MUTATOR_HARNESS_SAFE="$_MUTATOR_HARNESS_LIB_DIR/mutator-safe-command.sh"
readonly _MUTATOR_HARNESS_LIB_DIR _MUTATOR_HARNESS_TESTS_DIR
readonly MUTATOR_HARNESS_SOURCE MUTATOR_HARNESS_DISPATCH MUTATOR_HARNESS_SAFE

mutator_harness_error() {
    printf 'mutator-harness: %s\n' "$*" >&2
    return 1
}

_mutator_harness_write_state_wrapper() {
    local destination=$1 command=$2
    {
        printf '%s\n' '#!/usr/bin/bash'
        printf '%s\n' 'set -u'
        printf 'exec /usr/bin/python3 -I -S -B %q %q "$@"\n' "${MUTATOR_HARNESS_RUNTIME_DISPATCH:?}" "$command"
    } > "$destination"
    /usr/bin/chmod 0755 "$destination"
}

_mutator_harness_write_safe_wrapper() {
    local destination=$1 command=$2 executable
    executable=$(/usr/bin/readlink -f "/usr/bin/$command") || return 1
    [[ $executable == /usr/* && -x $executable ]] || return 1
    {
        printf '%s\n' '#!/usr/bin/bash'
        printf 'MUTATOR_SAFE_COMMAND=%q MUTATOR_SAFE_EXECUTABLE=%q MUTATOR_SAFE_DISPATCH=%q exec /usr/bin/bash %q "$@"\n' \
            "$command" "$executable" "${MUTATOR_HARNESS_RUNTIME_DISPATCH:?}" \
            "${MUTATOR_HARNESS_RUNTIME_SAFE:?}"
    } > "$destination"
    /usr/bin/chmod 0755 "$destination"
}

_mutator_harness_materialize_path() {
    local command
    local -a stateful=(
        sudo virsh xmlstarlet virt-xml-validate ip netplan systemctl ufw sshd
        mount umount mountpoint findmnt dpkg apt apt-get getent id passwd groupadd
        useradd userdel groupdel ssh-keygen lsblk udevadm lscpu lsmod lspci
        update-initramfs update-grub kernelstub flock logger ping dmesg
        cp mv rm mkdir chmod chown chgrp touch install tee sed grep find stat
        mktemp test mutator-effect
    )
    local -a safe=(
        awk basename bash cat cmp cut date dirname env head paste python3
        readlink sha256sum sleep sort tail tr wc
    )
    for command in "${stateful[@]}"; do
        _mutator_harness_write_state_wrapper "$MUTATOR_ROOT/bin/$command" "$command" || return 1
    done
    for command in "${safe[@]}"; do
        _mutator_harness_write_safe_wrapper "$MUTATOR_ROOT/bin/$command" "$command" || return 1
    done
}

_mutator_harness_write_config() {
    cat > "$MUTATOR_PROJECT/passthrough.conf" <<CONF
USUARIO_LINUX="fixture"
VM_NAME="fixture-win11"
VM_STORAGE_GROUP="vm-passthrough"
BOOTLOADER="grub"
GPU_PCI_ID="0000:0a:00.0"
GPU_AUDIO_PCI_ID="0000:0a:00.1"
GPU_VENDOR_DEVICE_ID="1234:5678"
GPU_AUDIO_VENDOR_DEVICE_ID="1234:5679"
IOMMU_GROUP_GPU="17"
DM_SERVICE="display-manager"
NVME_DEVICE=""
WORKING_DISK_PATH=""
WORKING_DISK_DISPENSADO="sim"
HD1_BY_ID_PATH=""
HD1_DISPENSADO="sim"
QCOW2_PATH="/vm/fixture.qcow2"
QCOW2_TAMANHO="250G"
VM_RAM_MB="8192"
VM_VCPUS="4"
VM_CORES="2"
VM_THREADS="2"
CPUS_VM="2-5"
CPUS_HOST="0-1,6-7"
MEMORIA_MODO="normal"
ISO_WINDOWS="/vm/windows.iso"
ISO_VIRTIO="/vm/virtio.iso"
REDE_MODO="nat"
INTERFACE_FISICA="enp3s0"
REDE_BRIDGE="br0"
REDE_LIBVIRT="passthrough-nat"
REDE_BRIDGE_LIBVIRT="virbr-vmnat"
REDE_NAT_CIDR="192.168.177.0/24"
VM_NIC_MAC="52:54:00:12:34:56"
VM_IP_FIXO="192.168.177.10"
IP_FIXO_HOST="192.168.177.1"
TRANSFER_USER="vmtransfer"
AIRLOCK_DIR="$MUTATOR_ROOT/var/lib/vm-passthrough/airlock"
AIRLOCK_BIND="$MUTATOR_ROOT/srv/airlock/files"
BACKUPS_VM_DIR="$MUTATOR_ROOT/backup/vm"
CONF
    /usr/bin/chmod 0600 "$MUTATOR_PROJECT/passthrough.conf"
}

_mutator_harness_append_common_overrides() {
    cat >> "$MUTATOR_PROJECT/lib/common.sh" <<'OVERRIDES'

# ---- overrides exclusivos da cópia temporária do mutator-harness I0 ----
exigir_nao_root() { :; }
exigir_sudo() { sudo -n true; SUDO_KEEPALIVE_PID=""; }
encerrar_sudo_keepalive() { SUDO_KEEPALIVE_PID=""; }
plataforma_carregar() {
    local capability
    PLATAFORMA_DETECTADA=1
    PLATAFORMA_CARREGADA=1
    PLATAFORMA_ID=ubuntu
    PLATAFORMA_ID_LIKE=debian
    PLATAFORMA_VARIANT_ID=""
    PLATAFORMA_PERFIL=ubuntu
    PLATAFORMA_SUPPORT_LEVEL=supported
    PLATAFORMA_MUTAVEL=1
    PLATAFORMA_IMUTAVEL=0
    PLATAFORMA_BLOQUEIO_MOTIVO=""
    PLATAFORMA_FAMILIA=debian
    PLATAFORMA_CPU_VENDOR=AuthenticAMD
    PLATAFORMA_GERENCIADOR_PACOTES=apt
    PLATAFORMA_INITRAMFS_BACKEND=update-initramfs
    # Backends libvirt do perfil real: a resolução autoritativa de
    # REQ-LIBVIRT-BACKEND é exercitada de verdade, contra o systemctl shimado.
    PLATAFORMA_LIBVIRT_SERVICOS="libvirtd virtqemud"
    PLATAFORMA_VIRTLOGD_SERVICOS="virtlogd"
    PLATAFORMA_ERRO=""
    for capability in "${PLATAFORMA_CAPABILITIES_CONHECIDAS[@]}"; do
        PLATAFORMA_CAPABILITIES[$capability]=1
        PLATAFORMA_CAPABILITY_REASONS[$capability]="Capability habilitada pelo harness I0."
    done
    return 0
}
exigir_plataforma_suportada() { plataforma_carregar; }
plataforma_validar_cpu_amd() { PLATAFORMA_CPU_VENDOR=AuthenticAMD; PLATAFORMA_ERRO=""; return 0; }
validar_bootloader_configurado() { BOOTLOADER_ATIVO=${BOOTLOADER:-grub}; BOOTLOADER_VALIDACAO_ERRO=""; return 0; }
exigir_bootloader_coerente() { validar_bootloader_configurado; }
cmdline_tem() { /usr/bin/grep -qw -- "$1" "$MUTATOR_STATE_DIR/cmdline"; }
# I5: kernel_param_add e plataforma_atualizar_initramfs deixaram de ser efeitos
# sintéticos. A etapa 30 passou a executar a transação REQ-IOMMU-TX real contra
# /etc/default/grub, /boot/grub/grub.cfg e /etc/modules-load.d/vfio.conf
# materializados na raiz simulada, com update-grub e update-initramfs shimados
# pelo dispatcher. Só assim a matriz de falha/sinal prova restauração de
# verdade, em vez de provar o mock.
pedir_reboot() { :; }
validar_grupo_iommu_gpu() {
    IOMMU_ERRO=""
    IOMMU_GRUPO_ATUAL=17
    IOMMU_MEMBROS="0000:0a:00.0 0000:0a:00.1"
    return 0
}
exigir_vm_desligada() { :; }
vm_existe() { return 0; }
validar_config_rede() { REDE_CONFIG_ERRO=""; return 0; }
exigir_config_rede() { validar_config_rede || falhar "$REDE_CONFIG_ERRO"; }
interface_fisica_elegivel() { return 0; }
interface_wifi() { return 1; }
dispositivo_uplink_ipv4_efetivo() { printf '%s\n' enp3s0; }
validar_ips_interface_rede() { REDE_IP_ERRO=""; return 0; }
validar_usuario_linux() {
    USUARIO_VALIDACAO_ERRO=""
    USUARIO_VALIDADO_UID=1000
    USUARIO_VALIDADO_GID=1000
    USUARIO_VALIDADO_HOME="$HOME"
    USUARIO_OPERADOR=fixture
    USUARIO_DIFERE_OPERADOR=0
    return 0
}
exigir_usuario_linux_valido() { validar_usuario_linux "${1:-fixture}"; }
validar_working_disk_montado() {
    WORKING_DISK_ERRO=""
    WORKING_DISK_SOURCE=/dev/fixture
    WORKING_DISK_FSTYPE=ext4
    return 0
}
disco_de() { printf '%s\n' /dev/fixture; }
disco_raiz() { printf '%s\n' /dev/root-fixture; }
OVERRIDES
}

mutator_harness_set_systemd_profile() {
    # Descreve o estado das unidades systemd que o shim de `systemctl show`
    # responde. Formato: NOME|LoadState|ActiveState|SubState|UnitFileState.
    # Serve à matriz de REQ-LIBVIRT-BACKEND: backend monolítico, modular e
    # ausência total de unidade.
    local profile=${1:-monolitico} destino="$MUTATOR_STATE_DIR/systemd-units"
    case $profile in
        monolitico)
            cat > "$destino" <<'UNITS'
libvirtd.socket|loaded|active|running|enabled
libvirtd.service|loaded|active|running|enabled
virtqemud.socket|not-found|inactive|dead|
virtqemud.service|not-found|inactive|dead|
virtlogd.socket|loaded|active|running|enabled
virtlogd.service|loaded|active|running|enabled
UNITS
            ;;
        modular)
            cat > "$destino" <<'UNITS'
libvirtd.socket|not-found|inactive|dead|
libvirtd.service|not-found|inactive|dead|
virtqemud.socket|loaded|active|running|enabled
virtqemud.service|loaded|active|running|enabled
virtlogd.socket|loaded|active|running|enabled
virtlogd.service|loaded|active|running|enabled
UNITS
            ;;
        monolitico-servico-morto)
            # O socket resolve o endpoint, mas o serviço não fica ativo depois
            # do restart: exercita a pós-condição do restart, não só o rc.
            cat > "$destino" <<'UNITS'
libvirtd.socket|loaded|active|running|enabled
libvirtd.service|loaded|inactive|dead|enabled
virtqemud.socket|not-found|inactive|dead|
virtqemud.service|not-found|inactive|dead|
virtlogd.socket|loaded|active|running|enabled
virtlogd.service|loaded|active|running|enabled
UNITS
            ;;
        ausente)
            cat > "$destino" <<'UNITS'
libvirtd.socket|not-found|inactive|dead|
libvirtd.service|not-found|inactive|dead|
virtqemud.socket|not-found|inactive|dead|
virtqemud.service|not-found|inactive|dead|
virtlogd.socket|not-found|inactive|dead|
virtlogd.service|not-found|inactive|dead|
UNITS
            ;;
        *)
            mutator_harness_error "perfil systemd desconhecido: $profile"
            return 1
            ;;
    esac
}

_mutator_harness_write_initial_boot() {
    # Fonte persistente do GRUB e grub.cfg efetivo, materializados na raiz
    # simulada. A cmdline ativa é um arquivo separado de propósito: "ativo
    # neste boot" e "persistido para o próximo" são fatos independentes
    # (D-IOMMU-ACTIVE-PERSISTENT), e só um reboot simulado liga um ao outro.
    /usr/bin/mkdir -p "$MUTATOR_ROOT/etc/default" "$MUTATOR_ROOT/boot/grub" \
        "$MUTATOR_ROOT/etc/modules-load.d"
    cat > "$MUTATOR_ROOT/etc/default/grub" <<'GRUB'
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX=""
GRUB
    cat > "$MUTATOR_ROOT/boot/grub/grub.cfg" <<'CFG'
menuentry normal {
 linux /vmlinuz root=/dev/fixture quiet splash
}
menuentry recovery {
 linux /vmlinuz root=/dev/fixture recovery nomodeset
}
CFG
}

mutator_harness_simular_reboot() {
    # Copia os parâmetros persistidos para a cmdline ativa. É o único caminho
    # pelo qual o estado ativo muda: nenhuma etapa pode alterá-lo sozinha.
    /usr/bin/python3 - "$MUTATOR_ROOT/etc/default/grub" "$MUTATOR_STATE_DIR/cmdline" <<'PY'
import sys
from pathlib import Path
origem, destino = map(Path, sys.argv[1:3])
parametros = ""
for linha in origem.read_text(encoding="utf-8").splitlines():
    if linha.startswith("GRUB_CMDLINE_LINUX_DEFAULT="):
        valor = linha.partition("=")[2].strip()
        if len(valor) >= 2 and valor[0] == '"' and valor[-1] == '"':
            parametros = valor[1:-1]
destino.write_text(parametros + "\n", encoding="utf-8")
PY
}

mutator_harness_boot_manifest() {
    # Conteúdo dos três recursos persistentes da transação de boot, para provar
    # restauração byte a byte depois de falha ou sinal.
    local output=$1
    /usr/bin/python3 - "$MUTATOR_ROOT" "$output" <<'PY'
import hashlib, sys
from pathlib import Path
root, output = map(Path, sys.argv[1:3])
alvos = ("etc/default/grub", "boot/grub/grub.cfg", "etc/modules-load.d/vfio.conf")
linhas = []
for alvo in alvos:
    caminho = root / alvo
    if caminho.is_file():
        linhas.append("%s|F|%s" % (alvo, hashlib.sha256(caminho.read_bytes()).hexdigest()))
    elif caminho.exists():
        linhas.append("%s|O|" % alvo)
    else:
        linhas.append("%s|-|" % alvo)
# Um resíduo de temporário da transação é falha: a limpeza faz parte do
# contrato de rollback e de commit. O backup datado do GRUB (.bak-*) é
# deliberado e fica de fora; o intermediário .vm-passthrough-* não.
residuos = sorted(
    str(item.relative_to(root))
    for padrao, base in (
        ("vfio.conf.vm-passthrough-*", root / "etc/modules-load.d"),
        ("grub.vm-passthrough-*", root / "etc/default"),
    )
    for item in base.glob(padrao)
)
linhas.append("residuos|%d|%s" % (len(residuos), ",".join(residuos)))
output.write_text("\n".join(linhas) + "\n", encoding="utf-8")
PY
}

_mutator_harness_write_initial_vm() {
    cat > "$MUTATOR_STATE_DIR/vm.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<domain type="kvm">
  <name>fixture-win11</name>
  <memory unit="MiB">8192</memory><vcpu>4</vcpu>
  <features><acpi/><apic/></features>
  <devices>
    <disk type="file" device="disk"><driver name="qemu" type="qcow2"/><source file="/vm/fixture.qcow2"/><target dev="vda" bus="virtio"/></disk>
    <interface type="network"><mac address="52:54:00:12:34:56"/><source network="default"/><model type="virtio"/></interface>
    <graphics type="spice"/><video><model type="qxl"/></video>
  </devices>
</domain>
XML
    mutator_harness_set_systemd_profile monolitico
    printf '%s\n' 'quiet splash' > "$MUTATOR_STATE_DIR/cmdline"
    _mutator_harness_write_initial_boot
    printf '%s\n' '{"sequence":0,"effects":0,"calls":{}}' > "$MUTATOR_STATE_DIR/counters.json"
    : > "$MUTATOR_ROOT/etc/ufw/added.rules"
    # O pacote ufw sempre entrega /etc/default/ufw, e é dele que sai a família
    # atendida pelo firewall (IPV6=). Sem o arquivo, a prova de IPv4/IPv6 do
    # airlock seria indeterminada por fixture ausente, não por estado do host.
    /usr/bin/mkdir -p "$MUTATOR_ROOT/etc/default"
    cat > "$MUTATOR_ROOT/etc/default/ufw" <<'UFWDEFAULT'
IPV6=yes
DEFAULT_INPUT_POLICY="DROP"
DEFAULT_OUTPUT_POLICY="ACCEPT"
DEFAULT_FORWARD_POLICY="DROP"
UFWDEFAULT
}

_mutator_harness_copy_project() {
    /usr/bin/mkdir -p "$MUTATOR_PROJECT"
    /usr/bin/cp -a "$MUTATOR_HARNESS_SOURCE/lib" "$MUTATOR_PROJECT/lib"
    /usr/bin/cp -a "$MUTATOR_HARNESS_SOURCE/etapas" "$MUTATOR_PROJECT/etapas"
    /usr/bin/cp -a "$MUTATOR_HARNESS_SOURCE/util" "$MUTATOR_PROJECT/util"
    /usr/bin/cp -a "$MUTATOR_HARNESS_SOURCE/passthrough.conf.example" "$MUTATOR_PROJECT/passthrough.conf.example"
    # Desde I3 os consumidores de produção usam o core Python pela ponte única,
    # então o projeto encenado precisa do libexec real (nenhum mock).
    /usr/bin/cp -a "$MUTATOR_HARNESS_SOURCE/libexec" "$MUTATOR_PROJECT/libexec"
}

mutator_harness_setup() {
    [[ -z ${MUTATOR_HARNESS_DIR:-} ]] || mutator_harness_error 'sandbox já ativa' || return 1
    [[ -f $MUTATOR_HARNESS_DISPATCH && -f $MUTATOR_HARNESS_SAFE ]] \
        || mutator_harness_error 'helpers do harness ausentes' || return 1
    [[ -x /usr/bin/bwrap ]] \
        || mutator_harness_error 'bubblewrap (/usr/bin/bwrap) é obrigatório para provar confinamento do filesystem' || return 1
    local parent=${MUTATOR_HARNESS_TMP_PARENT:-${TMPDIR:-/tmp}}
    parent=$(cd "$parent" && pwd -P) || return 1
    MUTATOR_HARNESS_DIR=$(/usr/bin/mktemp -d "$parent/mutator-harness.XXXXXXXX") || return 1
    _MUTATOR_HARNESS_OWNED_DIR=$MUTATOR_HARNESS_DIR
    MUTATOR_ROOT="$MUTATOR_HARNESS_DIR/root"
    MUTATOR_PROJECT="$MUTATOR_HARNESS_DIR/project"
    MUTATOR_STATE_DIR="$MUTATOR_HARNESS_DIR/state"
    MUTATOR_CALL_LOG="$MUTATOR_HARNESS_DIR/calls.log"
    MUTATOR_FORBIDDEN_LOG="$MUTATOR_HARNESS_DIR/forbidden.log"
    MUTATOR_OUTPUT="$MUTATOR_HARNESS_DIR/stdout.log"
    MUTATOR_ERROR="$MUTATOR_HARNESS_DIR/stderr.log"
    MUTATOR_HOME="$MUTATOR_HARNESS_DIR/home"
    MUTATOR_TMP="$MUTATOR_HARNESS_DIR/tmp"
    MUTATOR_HARNESS_RUNTIME_DIR="$MUTATOR_HARNESS_DIR/runtime-lib"
    MUTATOR_HARNESS_RUNTIME_DISPATCH="$MUTATOR_HARNESS_RUNTIME_DIR/mutator-dispatch.py"
    MUTATOR_HARNESS_RUNTIME_SAFE="$MUTATOR_HARNESS_RUNTIME_DIR/mutator-safe-command.sh"
    MUTATOR_AIRLOCK_TRANSIT="$MUTATOR_ROOT/var/lib/vm-passthrough/airlock"
    MUTATOR_AIRLOCK_BIND="$MUTATOR_ROOT/srv/airlock/files"
    export MUTATOR_HARNESS_DIR MUTATOR_ROOT MUTATOR_PROJECT MUTATOR_STATE_DIR
    export MUTATOR_CALL_LOG MUTATOR_FORBIDDEN_LOG MUTATOR_AIRLOCK_TRANSIT MUTATOR_AIRLOCK_BIND

    /usr/bin/mkdir -p \
        "$MUTATOR_ROOT/bin" "$MUTATOR_ROOT/etc/modules-load.d" "$MUTATOR_ROOT/etc/default" \
        "$MUTATOR_ROOT/etc/netplan" "$MUTATOR_ROOT/etc/libvirt/hooks" "$MUTATOR_ROOT/etc/ssh/sshd_config.d" \
        "$MUTATOR_ROOT/etc/ssh/authorized_keys" "$MUTATOR_ROOT/etc/ufw" \
        "$MUTATOR_ROOT/var/lib/vm-passthrough" "$MUTATOR_ROOT/srv" \
        "$MUTATOR_ROOT/vm" "$MUTATOR_ROOT/backup" "$MUTATOR_STATE_DIR" \
        "$MUTATOR_HOME" "$MUTATOR_TMP" "$MUTATOR_HARNESS_RUNTIME_DIR" \
        "$MUTATOR_ROOT/sys/kernel/iommu_groups/17/devices" \
        "$MUTATOR_ROOT/sys/bus/pci/devices/0000:0a:00.0" \
        "$MUTATOR_ROOT/sys/bus/pci/devices/0000:0a:00.1"
    printf '%s\n' 'ID=ubuntu' 'ID_LIKE=debian' 'VERSION_ID="24.04"' > "$MUTATOR_ROOT/etc/os-release"
    printf '%s\n' '# synthetic fstab' > "$MUTATOR_ROOT/etc/fstab"
    printf '%s\n' '# synthetic grub' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' > "$MUTATOR_ROOT/etc/default/grub"
    : > "$MUTATOR_ROOT/sys/kernel/iommu_groups/17/devices/0000:0a:00.0"
    : > "$MUTATOR_ROOT/sys/kernel/iommu_groups/17/devices/0000:0a:00.1"
    : > "$MUTATOR_ROOT/vm/fixture.qcow2"
    : > "$MUTATOR_ROOT/vm/windows.iso"
    : > "$MUTATOR_ROOT/vm/virtio.iso"
    : > "$MUTATOR_CALL_LOG"
    : > "$MUTATOR_FORBIDDEN_LOG"
    : > "$MUTATOR_OUTPUT"
    : > "$MUTATOR_ERROR"
    /usr/bin/cp -p "$MUTATOR_HARNESS_DISPATCH" "$MUTATOR_HARNESS_RUNTIME_DISPATCH" \
        || { mutator_harness_cleanup; return 1; }
    /usr/bin/cp -p "$MUTATOR_HARNESS_SAFE" "$MUTATOR_HARNESS_RUNTIME_SAFE" \
        || { mutator_harness_cleanup; return 1; }
    _mutator_harness_copy_project || { mutator_harness_cleanup; return 1; }
    _mutator_harness_write_config || { mutator_harness_cleanup; return 1; }
    _mutator_harness_append_common_overrides || { mutator_harness_cleanup; return 1; }
    _mutator_harness_write_initial_vm || { mutator_harness_cleanup; return 1; }
    _mutator_harness_materialize_path || { mutator_harness_cleanup; return 1; }

    /usr/bin/cp -a "$MUTATOR_ROOT" "$MUTATOR_HARNESS_DIR/root.initial"
    /usr/bin/cp -a "$MUTATOR_STATE_DIR" "$MUTATOR_HARNESS_DIR/state.initial"
    /usr/bin/cp -p "$MUTATOR_PROJECT/passthrough.conf" "$MUTATOR_HARNESS_DIR/passthrough.conf.initial"
    MUTATOR_RC=0
}

mutator_harness_reset() {
    [[ -n ${MUTATOR_HARNESS_DIR:-} && -d $MUTATOR_HARNESS_DIR ]] || return 1
    /usr/bin/rm -rf "$MUTATOR_ROOT"
    /usr/bin/cp -a "$MUTATOR_HARNESS_DIR/root.initial" "$MUTATOR_ROOT"
    /usr/bin/rm -rf "$MUTATOR_STATE_DIR"
    /usr/bin/cp -a "$MUTATOR_HARNESS_DIR/state.initial" "$MUTATOR_STATE_DIR"
    /usr/bin/cp -p "$MUTATOR_HARNESS_DIR/passthrough.conf.initial" "$MUTATOR_PROJECT/passthrough.conf"
    /usr/bin/rm -rf "$MUTATOR_PROJECT/backups"
    : > "$MUTATOR_CALL_LOG"
    : > "$MUTATOR_FORBIDDEN_LOG"
    : > "$MUTATOR_OUTPUT"
    : > "$MUTATOR_ERROR"
    unset MUTATOR_TEST_FAIL_EFFECT MUTATOR_TEST_FAIL_MODE MUTATOR_TEST_FAIL_CALL
    unset MUTATOR_TEST_SIGNAL_EFFECT MUTATOR_TEST_SIGNAL_NAME MUTATOR_TEST_DIVERGE_EFFECT
    unset MUTATOR_TEST_CONCURRENT_EFFECT
}

mutator_harness_clear_instrumentation() {
    [[ -n ${MUTATOR_HARNESS_DIR:-} && -d $MUTATOR_HARNESS_DIR ]] || return 1
    printf '%s\n' '{"sequence":0,"effects":0,"calls":{}}' > "$MUTATOR_STATE_DIR/counters.json"
    /usr/bin/rm -f "$MUTATOR_STATE_DIR/counters.lock"
    : > "$MUTATOR_CALL_LOG"
    : > "$MUTATOR_FORBIDDEN_LOG"
    : > "$MUTATOR_OUTPUT"
    : > "$MUTATOR_ERROR"
    unset MUTATOR_TEST_FAIL_EFFECT MUTATOR_TEST_FAIL_MODE MUTATOR_TEST_FAIL_CALL
    unset MUTATOR_TEST_SIGNAL_EFFECT MUTATOR_TEST_SIGNAL_NAME MUTATOR_TEST_DIVERGE_EFFECT
    unset MUTATOR_TEST_CONCURRENT_EFFECT
}

mutator_harness_cleanup() {
    local sandbox=${MUTATOR_HARNESS_DIR:-}
    local owned=${_MUTATOR_HARNESS_OWNED_DIR:-}
    # Só remove o caminho exato criado por este processo via mktemp. Alterar a
    # variável pública depois do setup não amplia o alvo de rm -rf.
    if [[ -n $sandbox && -n $owned && $sandbox == "$owned" \
          && ${sandbox##*/} == mutator-harness.* && -d $sandbox ]]; then
        /usr/bin/chmod -R u+rwX "$sandbox" 2>/dev/null || :
        /usr/bin/rm -rf "$sandbox"
    fi
    unset _MUTATOR_HARNESS_OWNED_DIR
    unset MUTATOR_HARNESS_DIR MUTATOR_ROOT MUTATOR_PROJECT MUTATOR_STATE_DIR
    unset MUTATOR_CALL_LOG MUTATOR_FORBIDDEN_LOG MUTATOR_OUTPUT MUTATOR_ERROR
    unset MUTATOR_HOME MUTATOR_TMP MUTATOR_AIRLOCK_TRANSIT MUTATOR_AIRLOCK_BIND MUTATOR_RC
    unset MUTATOR_HARNESS_RUNTIME_DIR MUTATOR_HARNESS_RUNTIME_DISPATCH MUTATOR_HARNESS_RUNTIME_SAFE
}

mutator_harness_set_conf() {
    local key=$1 value=$2
    [[ $key =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
    /usr/bin/python3 - "$MUTATOR_PROJECT/passthrough.conf" "$key" "$value" <<'PY'
import sys
from pathlib import Path
path, key, value = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
quoted = '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('$', '\\$').replace('`', '\\`') + '"'
lines = path.read_text(encoding='utf-8').splitlines()
replacement = f'{key}={quoted}'
for index, line in enumerate(lines):
    if line.startswith(key + '='):
        lines[index] = replacement
        break
else:
    lines.append(replacement)
path.write_text('\n'.join(lines) + '\n', encoding='utf-8')
PY
}

mutator_harness_seed_network() {
    local fixture=${1:-managed} active=${2:-yes} persistent=${3:-yes} autostart=${4:-yes}
    local source="$MUTATOR_HARNESS_SOURCE/tests/fixtures/i0/xml/network-$fixture.xml"
    [[ -f $source ]] || return 1
    [[ $persistent == yes ]] && /usr/bin/cp "$source" "$MUTATOR_STATE_DIR/network-persistent.xml"
    [[ $active == yes ]] && /usr/bin/cp "$source" "$MUTATOR_STATE_DIR/network-active.xml"
    [[ $autostart == yes ]] && : > "$MUTATOR_STATE_DIR/network-autostart"
    # I7.6: `return 0` explícito. O último `[[ ... ]] &&` devolvia 1 quando a
    # semeadura pedia `no`, e sob `set -e` isso derrubava o chamador em vez de
    # semear o cenário — motivo pelo qual todas as chamadas anteriores usavam
    # `yes yes yes`. A matriz de rollback precisa da rede sem autostart para
    # alcançar o verbo `network-autostart-disable`.
    return 0
}

mutator_harness_seed_other_vm_consumer() {
    local active=${1:-no}
    /usr/bin/cp "$MUTATOR_STATE_DIR/vm.xml" "$MUTATOR_STATE_DIR/other-vm.xml"
    /usr/bin/python3 - "$MUTATOR_STATE_DIR/other-vm.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
path = sys.argv[1]
tree = ET.parse(path); root = tree.getroot(); root.find('name').text = 'other-vm'
source = root.find('./devices/interface/source'); source.attrib.clear(); source.set('network', 'passthrough-nat')
tree.write(path, encoding='utf-8', xml_declaration=True)
PY
    [[ $active != yes ]] || : > "$MUTATOR_STATE_DIR/other-vm-active"
}

mutator_harness_seed_route_collision() {
    : > "$MUTATOR_STATE_DIR/route-collision"
}

mutator_harness_seed_bridge_runtime() {
    /usr/bin/cat > "$MUTATOR_ROOT/etc/netplan/90-vm-passthrough-bridge.yaml" <<'YAML'
network:
  version: 2
  ethernets:
    enp3s0:
      dhcp4: no
      dhcp6: no
  bridges:
    br0:
      interfaces: [enp3s0]
      dhcp4: yes
      parameters:
        stp: true
        forward-delay: 4
YAML
    /usr/bin/chmod 0600 "$MUTATOR_ROOT/etc/netplan/90-vm-passthrough-bridge.yaml"
    : > "$MUTATOR_STATE_DIR/bridge-active"
}

mutator_harness_seed_vm_nics() {
    local mode=$1
    /usr/bin/python3 - "$MUTATOR_STATE_DIR/vm.xml" "$mode" <<'PY'
import copy
import sys
import xml.etree.ElementTree as ET

path, mode = sys.argv[1:]
tree = ET.parse(path)
devices = tree.getroot().find('devices')
assert devices is not None
interfaces = list(devices.findall('interface'))
if mode == 'zero':
    for node in interfaces:
        devices.remove(node)
elif mode == 'duplicate-mac':
    assert interfaces
    devices.append(copy.deepcopy(interfaces[0]))
elif mode == 'two-distinct':
    assert interfaces
    clone = copy.deepcopy(interfaces[0])
    mac = clone.find('mac')
    assert mac is not None
    mac.set('address', '52:54:00:65:43:21')
    devices.append(clone)
else:
    raise SystemExit(f'modo de NIC desconhecido: {mode}')
tree.write(path, encoding='utf-8', xml_declaration=True)
PY
}

mutator_harness_env_array() {
    MUTATOR_ENV=(
        /usr/bin/env -i
        "PATH=$MUTATOR_ROOT/bin"
        "HOME=$MUTATOR_HOME"
        "TMPDIR=$MUTATOR_TMP"
        "LANG=C.UTF-8" "LC_ALL=C.UTF-8" "TZ=UTC"
        "PASSTHROUGH_TEST_MODE=1" "PASSTHROUGH_TEST_ROOT=$MUTATOR_ROOT"
        "MUTATOR_SANDBOX_ACTIVE=1"
        "MUTATOR_HARNESS_DIR=$MUTATOR_HARNESS_DIR" "MUTATOR_ROOT=$MUTATOR_ROOT"
        "MUTATOR_PROJECT=$MUTATOR_PROJECT" "MUTATOR_STATE_DIR=$MUTATOR_STATE_DIR"
        "MUTATOR_CALL_LOG=$MUTATOR_CALL_LOG" "MUTATOR_FORBIDDEN_LOG=$MUTATOR_FORBIDDEN_LOG"
        "MUTATOR_AIRLOCK_TRANSIT=$MUTATOR_AIRLOCK_TRANSIT" "MUTATOR_AIRLOCK_BIND=$MUTATOR_AIRLOCK_BIND"
    )
    [[ -z ${MUTATOR_TEST_FAIL_EFFECT:-} ]] || MUTATOR_ENV+=("MUTATOR_FAIL_EFFECT=$MUTATOR_TEST_FAIL_EFFECT")
    [[ -z ${MUTATOR_TEST_FAIL_MODE:-} ]] || MUTATOR_ENV+=("MUTATOR_FAIL_MODE=$MUTATOR_TEST_FAIL_MODE")
    [[ -z ${MUTATOR_TEST_FAIL_CALL:-} ]] || MUTATOR_ENV+=("MUTATOR_FAIL_CALL=$MUTATOR_TEST_FAIL_CALL")
    [[ -z ${MUTATOR_TEST_SIGNAL_EFFECT:-} ]] || MUTATOR_ENV+=("MUTATOR_SIGNAL_EFFECT=$MUTATOR_TEST_SIGNAL_EFFECT")
    [[ -z ${MUTATOR_TEST_SIGNAL_NAME:-} ]] || MUTATOR_ENV+=("MUTATOR_SIGNAL_NAME=$MUTATOR_TEST_SIGNAL_NAME")
    [[ -z ${MUTATOR_TEST_DIVERGE_EFFECT:-} ]] || MUTATOR_ENV+=("MUTATOR_DIVERGE_EFFECT=$MUTATOR_TEST_DIVERGE_EFFECT")
    [[ -z ${MUTATOR_TEST_CONCURRENT_EFFECT:-} ]] || MUTATOR_ENV+=("MUTATOR_CONCURRENT_EFFECT=$MUTATOR_TEST_CONCURRENT_EFFECT")
}

mutator_harness_bwrap_array() {
    # Raiz mínima: não espelhar o host evita connect(2) em sockets AF_UNIX
    # existentes em diretórios somente leitura (ro-bind não bloqueia conexão).
    MUTATOR_BWRAP=(
        /usr/bin/bwrap
        --unshare-all
        --die-with-parent
        --new-session
        --tmpfs /
        --ro-bind /usr /usr
    )
    [[ ! -e /lib ]] || MUTATOR_BWRAP+=(--ro-bind /lib /lib)
    [[ ! -e /lib64 ]] || MUTATOR_BWRAP+=(--ro-bind /lib64 /lib64)
    MUTATOR_BWRAP+=(
        --dir /etc
    )
    [[ ! -f /etc/ld.so.cache ]] || MUTATOR_BWRAP+=(--ro-bind /etc/ld.so.cache /etc/ld.so.cache)
    MUTATOR_BWRAP+=(
        --dir /tmp
        --dir "$MUTATOR_HARNESS_DIR"
        --bind "$MUTATOR_HARNESS_DIR" "$MUTATOR_HARNESS_DIR"
        --tmpfs /run
        --dev /dev
        --proc /proc
        --dir /sys
        --ro-bind "$MUTATOR_ROOT/sys" /sys
        --ro-bind "$MUTATOR_STATE_DIR/cmdline" /proc/cmdline
        --chdir "$MUTATOR_PROJECT"
    )
}

mutator_harness_run() {
    local stage=$1 input=${2-}
    shift 2 || :
    local script="$MUTATOR_PROJECT/etapas/$stage"
    local input_file="$MUTATOR_HARNESS_DIR/stdin.input"
    [[ -f $script ]] || mutator_harness_error "etapa ausente: $stage" || return 1
    printf '%s' "$input" > "$input_file"
    mutator_harness_env_array
    mutator_harness_bwrap_array
    set +e
    (
        set +e
        "${MUTATOR_ENV[@]}" "${MUTATOR_BWRAP[@]}" /usr/bin/bash "$script" "$@" \
            < "$input_file" > "$MUTATOR_OUTPUT" 2> "$MUTATOR_ERROR"
        exit "$?"
    ) 2>> "$MUTATOR_ERROR"
    MUTATOR_RC=$?
    set -e
    /usr/bin/rm -f "$input_file"
    return 0
}

mutator_harness_command() {
    local command=$1
    shift
    [[ $command =~ ^[a-zA-Z0-9_.-]+$ && -x $MUTATOR_ROOT/bin/$command ]] \
        || mutator_harness_error "comando do harness ausente/inválido: $command" || return 1
    mutator_harness_env_array
    mutator_harness_bwrap_array
    set +e
    "${MUTATOR_ENV[@]}" "${MUTATOR_BWRAP[@]}" "$MUTATOR_ROOT/bin/$command" "$@" \
        > "$MUTATOR_OUTPUT" 2> "$MUTATOR_ERROR"
    MUTATOR_RC=$?
    set -e
    return 0
}

mutator_harness_raw() {
    local code=$1
    shift
    mutator_harness_env_array
    mutator_harness_bwrap_array
    set +e
    "${MUTATOR_ENV[@]}" "${MUTATOR_BWRAP[@]}" /usr/bin/bash -c "$code" _ "$@" \
        > "$MUTATOR_OUTPUT" 2> "$MUTATOR_ERROR"
    MUTATOR_RC=$?
    set -e
    return 0
}

mutator_harness_effect_count() {
    /usr/bin/python3 - "$MUTATOR_STATE_DIR/counters.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding='utf-8')).get('effects', 0))
PY
}

mutator_harness_content_manifest() {
    local output=$1
    /usr/bin/python3 - "$MUTATOR_ROOT" "$MUTATOR_PROJECT/passthrough.conf" "$output" <<'PY'
import hashlib, os, stat, sys
from pathlib import Path
root, conf, output = map(Path, sys.argv[1:])
rows=[]
for base, label in ((root, 'root'),):
    for path in sorted(base.rglob('*')):
        rel=f"{label}/{path.relative_to(base)}"
        st=path.lstat()
        mode=stat.S_IMODE(st.st_mode)
        if path.is_symlink(): rows.append((rel,'L',oct(mode),os.readlink(path)))
        elif path.is_dir(): rows.append((rel,'D',oct(mode),''))
        elif path.is_file(): rows.append((rel,'F',oct(mode),hashlib.sha256(path.read_bytes()).hexdigest()))
st=conf.stat(); rows.append(('project/passthrough.conf','F',oct(stat.S_IMODE(st.st_mode)),hashlib.sha256(conf.read_bytes()).hexdigest()))
output.write_text('\n'.join('|'.join(row) for row in rows)+'\n', encoding='utf-8')
PY
}

mutator_harness_exact_manifest() {
    local output=$1
    /usr/bin/python3 - "$MUTATOR_ROOT" "$MUTATOR_PROJECT/passthrough.conf" "$output" <<'PY'
import hashlib, os, stat, sys
from pathlib import Path
root, conf, output = map(Path, sys.argv[1:])
rows=[]
for path in sorted(root.rglob('*')):
    st=path.lstat(); rel=f"root/{path.relative_to(root)}"; mode=stat.S_IMODE(st.st_mode)
    digest=hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() and not path.is_symlink() else (os.readlink(path) if path.is_symlink() else '')
    rows.append((rel,oct(mode),str(st.st_uid),str(st.st_gid),str(st.st_mtime_ns),digest))
st=conf.stat(); rows.append(('project/passthrough.conf',oct(stat.S_IMODE(st.st_mode)),str(st.st_uid),str(st.st_gid),str(st.st_mtime_ns),hashlib.sha256(conf.read_bytes()).hexdigest()))
output.write_text('\n'.join('|'.join(row) for row in rows)+'\n', encoding='utf-8')
PY
}

mutator_harness_observable_manifest() {
    local output=$1 mode=${2:-content}
    [[ $mode == content || $mode == exact ]] || return 1
    /usr/bin/python3 - "$MUTATOR_ROOT" "$MUTATOR_STATE_DIR" "$MUTATOR_PROJECT/passthrough.conf" "$output" "$mode" <<'PY'
import hashlib, os, stat, sys
from pathlib import Path
root, state, conf, output = map(Path, sys.argv[1:5])
mode = sys.argv[5]
rows=[]
for base, label in ((root, 'root'), (state, 'state')):
    for path in sorted(base.rglob('*')):
        relative = path.relative_to(base)
        if label == 'root' and relative.parts[:1] == ('bin',):
            continue
        if label == 'state' and relative.as_posix() in {'counters.json', 'counters.lock'}:
            continue
        rel=f"{label}/{relative}"
        st=path.lstat(); permissions=oct(stat.S_IMODE(st.st_mode))
        if path.is_symlink(): kind='L'; digest=os.readlink(path)
        elif path.is_dir(): kind='D'; digest=''
        elif path.is_file(): kind='F'; digest=hashlib.sha256(path.read_bytes()).hexdigest()
        else: kind='O'; digest=''
        if mode == 'exact':
            rows.append((rel,kind,permissions,str(st.st_uid),str(st.st_gid),str(st.st_mtime_ns),str(st.st_dev),str(st.st_ino),str(st.st_nlink),digest))
        else:
            rows.append((rel,kind,permissions,digest))
st=conf.stat(); digest=hashlib.sha256(conf.read_bytes()).hexdigest()
if mode == 'exact':
    rows.append(('project/passthrough.conf','F',oct(stat.S_IMODE(st.st_mode)),str(st.st_uid),str(st.st_gid),str(st.st_mtime_ns),str(st.st_dev),str(st.st_ino),str(st.st_nlink),digest))
else:
    rows.append(('project/passthrough.conf','F',oct(stat.S_IMODE(st.st_mode)),digest))
output.write_text('\n'.join('|'.join(row) for row in rows)+'\n', encoding='utf-8')
PY
}

mutator_harness_vm_hash() {
    /usr/bin/sha256sum "$MUTATOR_STATE_DIR/vm.xml" | /usr/bin/cut -d' ' -f1
}

mutator_harness_assert_confined() {
    [[ ! -s $MUTATOR_FORBIDDEN_LOG ]] || {
        /usr/bin/cat "$MUTATOR_FORBIDDEN_LOG" >&2
        return 1
    }
}
