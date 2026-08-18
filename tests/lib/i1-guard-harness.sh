#!/usr/bin/env bash
# Harness hermético I1 para provar recusas antes de sudo, filhos ou efeitos.
# O código operacional é copiado; somente a cópia recebe um injetor de
# capability negada para exercitar esse estado impossível de selecionar em
# produção sem alterar o provider real.

if [[ -n ${_I1_GUARD_HARNESS_LOADED:-} ]]; then
    return 0 2>/dev/null || exit 0
fi
_I1_GUARD_HARNESS_LOADED=1

_I1_HARNESS_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
_I1_HARNESS_TESTS_DIR=$(cd -- "$_I1_HARNESS_LIB_DIR/.." && pwd -P)
I1_HARNESS_SOURCE=$(cd -- "$_I1_HARNESS_TESTS_DIR/.." && pwd -P)
readonly _I1_HARNESS_LIB_DIR _I1_HARNESS_TESTS_DIR I1_HARNESS_SOURCE

_i1_harness_error() {
    printf 'i1-guard-harness: %s\n' "$*" >&2
    return 1
}

_i1_write_safe_wrapper() {
    local destination=$1 requested=$2 executable
    executable=$(/usr/bin/readlink -f -- "$requested") || return 1
    [[ $executable == /usr/* && -x $executable ]] || return 1
    cat > "$destination" <<WRAPPER
#!/usr/bin/bash
exec $executable "\$@"
WRAPPER
    /usr/bin/chmod 0755 "$destination"
}

_i1_write_scoped_wrapper() {
    # Executa o comando real somente quando todo operando absoluto está sob a
    # raiz do harness. O nome do comando e os argumentos vão para o log de
    # efeitos em qualquer caso, para que a auditoria continue completa.
    local destination=$1 command=$2 executable
    executable=$(/usr/bin/readlink -f -- "/usr/bin/$command") || return 1
    [[ $executable == /usr/* && -x $executable ]] || return 1
    cat > "$destination" <<WRAPPER
#!/usr/bin/bash
printf '%s|%s\\n' 'scoped:$command' "\$*" >> "\${I1_SCOPED_LOG:?}"
raiz="\${I1_HARNESS_DIR:?}"
# Publicar configuração antes da guarda é exatamente o efeito que o envelope
# existe para impedir, então continua sendo parada dura mesmo sob escopo.
for argumento in "\$@"; do
    if [ "\$argumento" = config-publish ]; then
        printf '%s|%s\\n' 'config-publish' "\$*" >> "\${I1_EFFECT_LOG:?}"
        exit 97
    fi
done
for argumento in "\$@"; do
    case "\$argumento" in
        /*)
            case "\$argumento" in
                "\$raiz"|"\$raiz"/*) ;;
                *)
                    printf '%s|%s\\n' 'forbidden:$command' "\$argumento" \\
                        >> "\${I1_EFFECT_LOG:?}"
                    exit 97
                    ;;
            esac
            ;;
    esac
done
exec $executable "\$@"
WRAPPER
    /usr/bin/chmod 0755 "$destination"
}

_i1_write_effect_wrapper() {
    local destination=$1 command=$2
    cat > "$destination" <<WRAPPER
#!/usr/bin/bash
printf '%s|%s\\n' '$command' "\$*" >> "\${I1_EFFECT_LOG:?}"
exit 97
WRAPPER
    /usr/bin/chmod 0755 "$destination"
}

_i1_write_shims() {
    local command
    for command in awk basename cat cmp cut date dirname grep sed sort stat tr; do
        _i1_write_safe_wrapper "$I1_ROOT/bin/$command" "/usr/bin/$command"
    done

    cat > "$I1_ROOT/bin/id" <<'SHIM'
#!/usr/bin/bash
case "${1:-}" in
    -u) printf '%s\n' 1000 ;;
    -un) printf '%s\n' fixture ;;
    -g) printf '%s\n' 1000 ;;
    -gn) printf '%s\n' fixture ;;
    *) exec /usr/bin/id "$@" ;;
esac
SHIM

    cat > "$I1_ROOT/bin/lscpu" <<'SHIM'
#!/usr/bin/bash
printf 'Architecture: x86_64\nVendor ID: %s\n' "${I1_CPU_VENDOR:-AuthenticAMD}"
SHIM

    cat > "$I1_ROOT/bin/bash" <<'SHIM'
#!/usr/bin/bash
if (( $# > 0 )) && [[ ${!#} == --verificar && ${V_STATUS_TOKEN:-} =~ ^[0-9a-f]{48}$ ]]; then
    printf '__PASSTHROUGH_STATUS_V1__:%s:1\n' "$V_STATUS_TOKEN"
    printf 'status|%s\n' "$*" >> "${I1_STATUS_LOG:?}"
    exit 1
fi
printf 'bash-child|%s\n' "$*" >> "${I1_EFFECT_LOG:?}"
exit 97
SHIM

    cat > "$I1_ROOT/bin/sudo" <<'SHIM'
#!/usr/bin/bash
if [[ ${I1_SUDO_MODE:-guard} == validation ]]; then
    case "${1:-}" in
        -n)
            if [[ ${2:-} == true && $# -eq 2 ]]; then
                printf 'sudo|-n true\n' >> "${I1_PROBE_LOG:?}"
                exit "${I1_SUDO_NONINTERACTIVE_RC:-0}"
            fi
            ;;
        -v)
            if (( $# == 1 )); then
                printf 'sudo|-v\n' >> "${I1_PROBE_LOG:?}"
                exit "${I1_SUDO_AUTH_RC:-0}"
            fi
            ;;
        dmesg)
            if (( $# == 1 )); then
                printf 'sudo|dmesg\n' >> "${I1_PROBE_LOG:?}"
                /usr/bin/cat -- "${I1_DMESG_FILE:?}"
                exit "${I1_DMESG_RC:-0}"
            fi
            ;;
    esac
fi
printf 'sudo|%s\n' "$*" >> "${I1_EFFECT_LOG:?}"
exit 97
SHIM

    cat > "$I1_ROOT/bin/nvidia-smi" <<'SHIM'
#!/usr/bin/bash
count=0
if [[ -f ${I1_NVIDIA_COUNT_FILE:?} ]]; then
    IFS= read -r count < "$I1_NVIDIA_COUNT_FILE" || count=0
fi
count=$((count + 1))
printf '%s\n' "$count" > "$I1_NVIDIA_COUNT_FILE"
printf 'nvidia-smi|%s\n' "$count" >> "${I1_PROBE_LOG:?}"
if (( count == 1 )); then
    /usr/bin/cat -- "${I1_NVIDIA_FIRST_FILE:?}"
    exit "${I1_NVIDIA_FIRST_RC:-0}"
fi
/usr/bin/cat -- "${I1_NVIDIA_SECOND_FILE:?}"
exit "${I1_NVIDIA_SECOND_RC:-0}"
SHIM

    cat > "$I1_ROOT/bin/virsh" <<'SHIM'
#!/usr/bin/bash
if [[ ${I1_VIRSH_MODE:-guard} == validation ]]; then
    case " $* " in
        *' start '*)
            printf 'virsh|start|%s\n' "$*" >> "${I1_ACTION_LOG:?}"
            exit "${I1_VIRSH_START_RC:-0}"
            ;;
        *' domstate '*)
            printf 'virsh|domstate|%s\n' "$*" >> "${I1_ACTION_LOG:?}"
            printf '%s\n' "${I1_VIRSH_DOMSTATE:-shut off}"
            exit "${I1_VIRSH_DOMSTATE_RC:-0}"
            ;;
    esac
fi
printf 'virsh|%s\n' "$*" >> "${I1_EFFECT_LOG:?}"
exit 97
SHIM

    for command in \
        apt apt-get chmod chgrp chown cp find findmnt flock groupadd \
        groupdel install ip kernelstub logger lsblk lsmod lspci mkdir \
        mount mv netplan ping reboot ssh-keygen sshd systemctl tee \
        touch udevadm ufw umount update-initramfs useradd userdel xmlstarlet; do
        _i1_write_effect_wrapper "$I1_ROOT/bin/$command" "$command"
    done

    # Desde I4 a carga de configuração passa pelo core Python, e ela acontece
    # antes da guarda porque todo entrypoint precisa do conf para se descrever.
    # Bloquear python3, mktemp e rm por atacado tornaria o envelope incompatível
    # com a própria arquitetura do plano, então os três passam a ser ESCOPADOS:
    # só operam sob a raiz do harness. Qualquer caminho absoluto fora dela é
    # registrado como efeito proibido e recusado, e todo comando que muta o host
    # (sudo, install, mv, rm de host, systemctl, virsh, ip, netplan, ufw...)
    # continua sendo parada dura. A prova real do envelope permanece sendo a
    # invariância fotografada de root, projeto, HOME e TMP.
    for command in mktemp rm python3; do
        _i1_write_scoped_wrapper "$I1_ROOT/bin/$command" "$command"
    done
    /usr/bin/chmod 0755 "$I1_ROOT/bin/id" "$I1_ROOT/bin/lscpu" \
        "$I1_ROOT/bin/bash" "$I1_ROOT/bin/sudo" "$I1_ROOT/bin/nvidia-smi" \
        "$I1_ROOT/bin/virsh"
}

_i1_copy_project() {
    /usr/bin/mkdir -p -- "$I1_PROJECT"
    /usr/bin/cp -a -- "$I1_HARNESS_SOURCE/lib" "$I1_PROJECT/lib"
    /usr/bin/cp -a -- "$I1_HARNESS_SOURCE/etapas" "$I1_PROJECT/etapas"
    /usr/bin/cp -a -- "$I1_HARNESS_SOURCE/util" "$I1_PROJECT/util"
    /usr/bin/cp -a -- "$I1_HARNESS_SOURCE/menu.sh" "$I1_PROJECT/menu.sh"
    /usr/bin/cp -a -- "$I1_HARNESS_SOURCE/passthrough.conf.example" \
        "$I1_PROJECT/passthrough.conf.example"
    /usr/bin/cp -a -- "$I1_HARNESS_SOURCE/libexec" "$I1_PROJECT/libexec"
}

_i1_write_config() {
    cat > "$I1_PROJECT/passthrough.conf" <<CONF
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
HUGEPAGES_1G="8"
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
AIRLOCK_DIR="$I1_ROOT/var/lib/vm-passthrough/airlock"
AIRLOCK_BIND="$I1_ROOT/srv/airlock/files"
BACKUPS_VM_DIR="$I1_ROOT/backup/vm"
CONF
    /usr/bin/chmod 0600 "$I1_PROJECT/passthrough.conf"
}

_i1_inject_capability_denial_in_copy() {
    /usr/bin/python3 - "$I1_PROJECT/lib/platform.sh" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding='utf-8')
old_local = '    local arquivo="${1:-}" fonte_explicita=0\n'
new_local = '    local arquivo="${1:-}" fonte_explicita=0 capability\n'
needle = '    _plataforma_habilitar_capabilities_perfil\n    PLATAFORMA_CARREGADA=1\n'
replacement = '''    _plataforma_habilitar_capabilities_perfil
    # Injeção exclusiva da cópia hermética I1; o arquivo operacional não muda.
    if [ -n "${I1_TEST_DENY_CAPABILITY:-}" ]; then
        for capability in "${PLATAFORMA_CAPABILITIES_CONHECIDAS[@]}"; do
            if [ "$I1_TEST_DENY_CAPABILITY" = all ] \
               || [ "$I1_TEST_DENY_CAPABILITY" = "$capability" ]; then
                PLATAFORMA_CAPABILITIES[$capability]=0
                PLATAFORMA_CAPABILITY_REASONS[$capability]="Capability negada pelo harness I1."
            fi
        done
    fi
    PLATAFORMA_CARREGADA=1
'''
if text.count(old_local) != 1 or text.count(needle) != 1:
    raise SystemExit('ponto de injeção I1 não é único')
text = text.replace(old_local, new_local).replace(needle, replacement)
path.write_text(text, encoding='utf-8')
PY
}

i1_harness_setup() {
    [[ -z ${I1_HARNESS_DIR:-} ]] \
        || _i1_harness_error 'sandbox já ativa' || return 1
    [[ -x /usr/bin/bwrap ]] \
        || _i1_harness_error 'bubblewrap (/usr/bin/bwrap) é obrigatório' || return 1
    local parent=${I1_HARNESS_TMP_PARENT:-${TMPDIR:-/tmp}}
    parent=$(cd -- "$parent" && pwd -P) || return 1
    I1_HARNESS_DIR=$(/usr/bin/mktemp -d "$parent/i1-guard.XXXXXXXX") || return 1
    _I1_HARNESS_OWNED_DIR=$I1_HARNESS_DIR
    I1_ROOT="$I1_HARNESS_DIR/root"
    I1_PROJECT="$I1_HARNESS_DIR/project"
    I1_HOME="$I1_HARNESS_DIR/home"
    I1_TMP="$I1_HARNESS_DIR/tmp"
    I1_OUTPUT="$I1_HARNESS_DIR/stdout.log"
    I1_ERROR="$I1_HARNESS_DIR/stderr.log"
    I1_EFFECT_LOG="$I1_HARNESS_DIR/effects.log"
    # Log separado das operações escopadas (mktemp/rm/python3 sob a raiz do
    # harness). Manter isso fora de effects.log é o que permite continuar
    # exigindo effects.log VAZIO em toda recusa de guarda.
    I1_SCOPED_LOG="$I1_HARNESS_DIR/scoped.log"
    I1_STATUS_LOG="$I1_HARNESS_DIR/status.log"
    I1_PROBE_LOG="$I1_HARNESS_DIR/probes.log"
    I1_ACTION_LOG="$I1_HARNESS_DIR/actions.log"
    I1_DMESG_FILE="$I1_HARNESS_DIR/dmesg.txt"
    I1_NVIDIA_FIRST_FILE="$I1_HARNESS_DIR/nvidia-first.txt"
    I1_NVIDIA_SECOND_FILE="$I1_HARNESS_DIR/nvidia-second.txt"
    I1_NVIDIA_COUNT_FILE="$I1_HARNESS_DIR/nvidia-count.txt"
    export I1_HARNESS_DIR I1_ROOT I1_PROJECT I1_HOME I1_TMP
    export I1_OUTPUT I1_ERROR I1_EFFECT_LOG I1_SCOPED_LOG I1_STATUS_LOG I1_PROBE_LOG
    export I1_ACTION_LOG I1_DMESG_FILE I1_NVIDIA_FIRST_FILE
    export I1_NVIDIA_SECOND_FILE I1_NVIDIA_COUNT_FILE

    /usr/bin/mkdir -p -- "$I1_ROOT/bin" "$I1_ROOT/etc" "$I1_ROOT/proc" \
        "$I1_ROOT/run" "$I1_ROOT/var/lib/vm-passthrough" "$I1_ROOT/srv/airlock" \
        "$I1_ROOT/backup/vm" "$I1_ROOT/vm" "$I1_HOME" "$I1_TMP"
    _i1_write_shims || { i1_harness_cleanup; return 1; }
    _i1_copy_project || { i1_harness_cleanup; return 1; }
    _i1_write_config || { i1_harness_cleanup; return 1; }
    _i1_inject_capability_denial_in_copy || { i1_harness_cleanup; return 1; }
    printf '%s\n' 'amd_iommu=on iommu=pt quiet' > "$I1_ROOT/proc/cmdline"
    : > "$I1_OUTPUT"; : > "$I1_ERROR"; : > "$I1_EFFECT_LOG"; : > "$I1_SCOPED_LOG"
    : > "$I1_STATUS_LOG"; : > "$I1_PROBE_LOG"; : > "$I1_ACTION_LOG"
    : > "$I1_DMESG_FILE"; : > "$I1_NVIDIA_FIRST_FILE"
    : > "$I1_NVIDIA_SECOND_FILE"; printf '0\n' > "$I1_NVIDIA_COUNT_FILE"
    /usr/bin/cp -a -- "$I1_ROOT" "$I1_HARNESS_DIR/root.initial"
    /usr/bin/cp -a -- "$I1_PROJECT" "$I1_HARNESS_DIR/project.initial"
    I1_RC=0
}

i1_harness_reset() {
    [[ -n ${I1_HARNESS_DIR:-} && -d ${I1_HARNESS_DIR:-} ]] || return 1
    /usr/bin/rm -rf -- "$I1_ROOT" "$I1_PROJECT"
    /usr/bin/cp -a -- "$I1_HARNESS_DIR/root.initial" "$I1_ROOT"
    /usr/bin/cp -a -- "$I1_HARNESS_DIR/project.initial" "$I1_PROJECT"
    : > "$I1_OUTPUT"; : > "$I1_ERROR"; : > "$I1_EFFECT_LOG"; : > "$I1_SCOPED_LOG"
    : > "$I1_STATUS_LOG"; : > "$I1_PROBE_LOG"; : > "$I1_ACTION_LOG"
    : > "$I1_DMESG_FILE"; : > "$I1_NVIDIA_FIRST_FILE"
    : > "$I1_NVIDIA_SECOND_FILE"; printf '0\n' > "$I1_NVIDIA_COUNT_FILE"
    unset I1_CPU_VENDOR I1_TEST_DENY_CAPABILITY I1_SUDO_MODE
    unset I1_SUDO_NONINTERACTIVE_RC I1_SUDO_AUTH_RC I1_DMESG_RC
    unset I1_NVIDIA_FIRST_RC I1_NVIDIA_SECOND_RC I1_VIRSH_MODE
    unset I1_VIRSH_START_RC I1_VIRSH_DOMSTATE I1_VIRSH_DOMSTATE_RC
    I1_RC=0
}

i1_harness_prepare_profile() {
    local profile=$1
    /usr/bin/rm -f -- "$I1_ROOT/run/ostree-booted"
    I1_CPU_VENDOR=AuthenticAMD
    I1_TEST_DENY_CAPABILITY=""
    case $profile in
        supported)
            printf '%s\n' 'ID=ubuntu' 'ID_LIKE=debian' 'VERSION_ID="24.04"' \
                > "$I1_ROOT/etc/os-release"
            ;;
        intel)
            printf '%s\n' 'ID=ubuntu' 'ID_LIKE=debian' 'VERSION_ID="24.04"' \
                > "$I1_ROOT/etc/os-release"
            I1_CPU_VENDOR=GenuineIntel
            ;;
        planned)
            printf '%s\n' 'ID=debian' 'ID_LIKE=debian' 'VERSION_ID="13"' \
                > "$I1_ROOT/etc/os-release"
            ;;
        unknown)
            printf '%s\n' 'ID=void' 'VERSION_ID="rolling"' \
                > "$I1_ROOT/etc/os-release"
            ;;
        immutable-variant)
            printf '%s\n' 'ID=fedora' 'VARIANT_ID=silverblue' 'VERSION_ID="42"' \
                > "$I1_ROOT/etc/os-release"
            ;;
        immutable-ostree)
            printf '%s\n' 'ID=ubuntu' 'ID_LIKE=debian' 'VERSION_ID="24.04"' \
                > "$I1_ROOT/etc/os-release"
            : > "$I1_ROOT/run/ostree-booted"
            ;;
        capability)
            printf '%s\n' 'ID=ubuntu' 'ID_LIKE=debian' 'VERSION_ID="24.04"' \
                > "$I1_ROOT/etc/os-release"
            I1_TEST_DENY_CAPABILITY=all
            ;;
        *) _i1_harness_error "perfil desconhecido: $profile"; return 1 ;;
    esac
    export I1_CPU_VENDOR I1_TEST_DENY_CAPABILITY
}

i1_harness_prepare_validation() {
    I1_SUDO_MODE=validation
    I1_SUDO_NONINTERACTIVE_RC=0
    I1_SUDO_AUTH_RC=0
    I1_DMESG_RC=0
    I1_NVIDIA_FIRST_RC=0
    I1_NVIDIA_SECOND_RC=0
    I1_VIRSH_MODE=validation
    I1_VIRSH_START_RC=0
    I1_VIRSH_DOMSTATE='shut off'
    I1_VIRSH_DOMSTATE_RC=0
    printf '%s\n' 'amd_iommu=on iommu=pt quiet' > "$I1_ROOT/proc/cmdline"
    printf '%s\n' 'AMD-Vi: Interrupt remapping enabled' > "$I1_DMESG_FILE"
    printf '%s\n' '| NVIDIA-SMI 550.90.07 Driver Version: 550.90.07 CUDA Version: 12.4 |' \
        > "$I1_NVIDIA_FIRST_FILE"
    /usr/bin/cp -- "$I1_NVIDIA_FIRST_FILE" "$I1_NVIDIA_SECOND_FILE"
    printf '0\n' > "$I1_NVIDIA_COUNT_FILE"
    export I1_SUDO_MODE I1_SUDO_NONINTERACTIVE_RC I1_SUDO_AUTH_RC I1_DMESG_RC
    export I1_NVIDIA_FIRST_RC I1_NVIDIA_SECOND_RC I1_VIRSH_MODE
    export I1_VIRSH_START_RC I1_VIRSH_DOMSTATE I1_VIRSH_DOMSTATE_RC
}

i1_harness_set_conf() {
    local key=$1 value=$2
    [[ $key =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
    /usr/bin/python3 - "$I1_PROJECT/passthrough.conf" "$key" "$value" <<'PY'
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

i1_harness_env_array() {
    I1_ENV=(
        /usr/bin/env -i
        "PATH=$I1_ROOT/bin" "HOME=$I1_HOME" "TMPDIR=$I1_TMP"
        # Os wrappers escopados de mktemp/rm/python3 comparam operandos com esta
        # raiz; sem ela no ambiente do filho, nada seria permitido.
        "I1_HARNESS_DIR=$I1_HARNESS_DIR"
        'LANG=C.UTF-8' 'LC_ALL=C.UTF-8' 'TZ=UTC'
        'PASSTHROUGH_TEST_MODE=1' "PASSTHROUGH_TEST_ROOT=$I1_ROOT"
        "I1_CPU_VENDOR=${I1_CPU_VENDOR:-AuthenticAMD}"
        "I1_TEST_DENY_CAPABILITY=${I1_TEST_DENY_CAPABILITY:-}"
        "I1_OUTPUT=$I1_OUTPUT" "I1_ERROR=$I1_ERROR"
        "I1_EFFECT_LOG=$I1_EFFECT_LOG" "I1_SCOPED_LOG=$I1_SCOPED_LOG"
        "I1_STATUS_LOG=$I1_STATUS_LOG"
        "I1_PROBE_LOG=$I1_PROBE_LOG" "I1_ACTION_LOG=$I1_ACTION_LOG"
        "I1_DMESG_FILE=$I1_DMESG_FILE"
        "I1_NVIDIA_FIRST_FILE=$I1_NVIDIA_FIRST_FILE"
        "I1_NVIDIA_SECOND_FILE=$I1_NVIDIA_SECOND_FILE"
        "I1_NVIDIA_COUNT_FILE=$I1_NVIDIA_COUNT_FILE"
        "I1_SUDO_MODE=${I1_SUDO_MODE:-guard}"
        "I1_SUDO_NONINTERACTIVE_RC=${I1_SUDO_NONINTERACTIVE_RC:-0}"
        "I1_SUDO_AUTH_RC=${I1_SUDO_AUTH_RC:-0}"
        "I1_DMESG_RC=${I1_DMESG_RC:-0}"
        "I1_NVIDIA_FIRST_RC=${I1_NVIDIA_FIRST_RC:-0}"
        "I1_NVIDIA_SECOND_RC=${I1_NVIDIA_SECOND_RC:-0}"
        "I1_VIRSH_MODE=${I1_VIRSH_MODE:-guard}"
        "I1_VIRSH_START_RC=${I1_VIRSH_START_RC:-0}"
        "I1_VIRSH_DOMSTATE=${I1_VIRSH_DOMSTATE:-shut off}"
        "I1_VIRSH_DOMSTATE_RC=${I1_VIRSH_DOMSTATE_RC:-0}"
    )
}

i1_harness_bwrap_array() {
    I1_BWRAP=(
        /usr/bin/bwrap --unshare-all --die-with-parent --new-session
        --tmpfs / --ro-bind /usr /usr
    )
    [[ ! -e /lib ]] || I1_BWRAP+=(--ro-bind /lib /lib)
    [[ ! -e /lib64 ]] || I1_BWRAP+=(--ro-bind /lib64 /lib64)
    I1_BWRAP+=(
        --dir /etc
    )
    [[ ! -f /etc/ld.so.cache ]] || I1_BWRAP+=(--ro-bind /etc/ld.so.cache /etc/ld.so.cache)
    I1_BWRAP+=(
        --dir /tmp --dir "$I1_HARNESS_DIR" --bind "$I1_HARNESS_DIR" "$I1_HARNESS_DIR"
        --tmpfs /run --dev /dev --proc /proc --dir /sys --chdir "$I1_PROJECT"
    )
}

_i1_harness_run() {
    local input=$1
    shift
    local input_file="$I1_HARNESS_DIR/stdin.input"
    printf '%s' "$input" > "$input_file"
    : > "$I1_OUTPUT"; : > "$I1_ERROR"
    i1_harness_env_array
    i1_harness_bwrap_array
    set +e
    "${I1_ENV[@]}" "${I1_BWRAP[@]}" "$@" \
        < "$input_file" > "$I1_OUTPUT" 2> "$I1_ERROR"
    I1_RC=$?
    set -e
    /usr/bin/rm -f -- "$input_file"
}

i1_harness_run_direct() {
    local relative=$1 input=$2
    shift 2
    [[ -f $I1_PROJECT/$relative ]] \
        || _i1_harness_error "entrypoint ausente: $relative" || return 1
    _i1_harness_run "$input" /usr/bin/bash "$I1_PROJECT/$relative" "$@"
}

i1_harness_run_menu() {
    local input=$1
    _i1_harness_run "$input" /usr/bin/bash "$I1_PROJECT/menu.sh"
}

i1_harness_exact_manifest() {
    local output=$1
    /usr/bin/python3 - "$I1_ROOT" "$I1_PROJECT" "$I1_HOME" "$I1_TMP" "$output" <<'PY'
import hashlib
import os
import stat
import sys
from pathlib import Path

root, project, home, tmp, output = map(Path, sys.argv[1:])
rows = []
for base, label in ((root, 'root'), (project, 'project'), (home, 'home'), (tmp, 'tmp')):
    for path in (base, *sorted(base.rglob('*'))):
        st = path.lstat()
        relative = label if path == base else f'{label}/{path.relative_to(base)}'
        mode_bits = stat.S_IMODE(st.st_mode)
        mode = oct(mode_bits)
        if path.is_symlink():
            kind, digest = 'L', os.readlink(path)
        elif path.is_dir():
            kind, digest = 'D', ''
        elif path.is_file():
            kind = 'F'
            try:
                content = path.read_bytes()
            except PermissionError:
                if st.st_uid != os.geteuid():
                    raise
                os.chmod(path, mode_bits | stat.S_IRUSR, follow_symlinks=False)
                try:
                    content = path.read_bytes()
                finally:
                    os.chmod(path, mode_bits, follow_symlinks=False)
            digest = hashlib.sha256(content).hexdigest()
        else:
            kind, digest = 'O', ''
        # A raiz do TMPDIR tem o mtime excluído de propósito: desde I4 a carga
        # de configuração passa pelo core Python, que cria e remove a própria
        # raiz privada dentro dessa pasta, e criar/remover uma entrada altera o
        # mtime do diretório pai. O que precisa continuar invariante é o
        # CONJUNTO de entradas (nada pode sobrar) e todo o resto de root,
        # projeto e HOME, inclusive mtime. Qualquer arquivo dentro de tmp
        # continua entrando na comparação com mtime.
        registro_mtime = '-' if relative == 'tmp' else str(st.st_mtime_ns)
        rows.append((relative, kind, str(st.st_uid), str(st.st_gid), mode,
                     registro_mtime, digest))
output.write_text('\n'.join('|'.join(row) for row in rows) + '\n', encoding='utf-8')
PY
}

i1_harness_cleanup() {
    local sandbox=${I1_HARNESS_DIR:-} owned=${_I1_HARNESS_OWNED_DIR:-}
    if [[ -n $sandbox && -n $owned && $sandbox == "$owned" \
          && ${sandbox##*/} == i1-guard.* && -d $sandbox ]]; then
        /usr/bin/chmod -R u+rwX "$sandbox" 2>/dev/null || :
        /usr/bin/rm -rf -- "$sandbox"
    fi
    unset I1_SCOPED_LOG
    unset _I1_HARNESS_OWNED_DIR I1_HARNESS_DIR I1_ROOT I1_PROJECT I1_HOME I1_TMP
    unset I1_OUTPUT I1_ERROR I1_EFFECT_LOG I1_STATUS_LOG I1_PROBE_LOG I1_ACTION_LOG
    unset I1_DMESG_FILE I1_NVIDIA_FIRST_FILE I1_NVIDIA_SECOND_FILE
    unset I1_NVIDIA_COUNT_FILE I1_RC I1_ENV I1_BWRAP
}
