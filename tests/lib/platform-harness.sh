#!/usr/bin/env bash
# Harness de testes para fontes de plataforma. Este arquivo não integra o fluxo operacional.

if [[ -n ${_PLATFORM_HARNESS_LOADED:-} && ${BASH_SOURCE[0]} != "$0" ]]; then
    return 0
fi
_PLATFORM_HARNESS_LOADED=1

_platform_harness_source=${BASH_SOURCE[0]}
_platform_harness_source_dir=.
if [[ $_platform_harness_source == */* ]]; then
    _platform_harness_source_dir=${_platform_harness_source%/*}
fi
if ! _PLATFORM_HARNESS_LIB_DIR=$(builtin cd -- "$_platform_harness_source_dir" && builtin pwd -P); then
    printf 'platform-harness: não foi possível resolver o diretório da biblioteca\n' >&2
    return 1 2>/dev/null || exit 1
fi
if ! _PLATFORM_HARNESS_TESTS_DIR=$(builtin cd -- "$_PLATFORM_HARNESS_LIB_DIR/.." && builtin pwd -P); then
    printf 'platform-harness: não foi possível resolver o diretório de testes\n' >&2
    return 1 2>/dev/null || exit 1
fi

readonly _PLATFORM_HARNESS_LIB_DIR _PLATFORM_HARNESS_TESTS_DIR
readonly PLATFORM_HARNESS_LIBRARY="$_PLATFORM_HARNESS_LIB_DIR/platform-harness.sh"
readonly PLATFORM_HARNESS_FIXTURES_DIR="$_PLATFORM_HARNESS_TESTS_DIR/fixtures/platform"

declare -ar PLATFORM_HARNESS_CASES=(
    ubuntu
    pop-os
    debian
    arch
    cachyos
    fedora
    opensuse
    unknown-derivative
    unknown-distro
    malicious-os-release
    immutable
)

declare -ar _PLATFORM_HARNESS_FIXTURE_FILES=(
    os-release
    commands.txt
    systemctl-units.txt
    boot-evidence.txt
    expected.env
)

_platform_harness_error() {
    printf 'platform-harness: %s\n' "$*" >&2
    return 1
}

_platform_harness_expected_key_allowed() {
    case ${1:-} in
        CASE_ID | OS_RELEASE_STATE | EXPECTED_ID | EXPECTED_ID_LIKE | \
            EXPECTED_VERSION_ID | EXPECTED_VERSION_CODENAME | \
            EXPECTED_IMMUTABLE | PRESENT_COMMAND)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

platform_harness_expected_value() {
    local expected_file=${1:-}
    local requested_key=${2:-}
    local line key value found=0 result=

    [[ -f $expected_file && ! -L $expected_file ]] ||
        _platform_harness_error "expected.env inválido: $expected_file" || return 1
    _platform_harness_expected_key_allowed "$requested_key" ||
        _platform_harness_error "chave esperada não permitida: $requested_key" || return 1

    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ -z $line || $line == \#* ]] && continue
        [[ $line == *=* ]] ||
            _platform_harness_error "linha inválida em $expected_file" || return 1
        key=${line%%=*}
        value=${line#*=}
        _platform_harness_expected_key_allowed "$key" ||
            _platform_harness_error "chave não permitida em $expected_file: $key" || return 1
        if [[ $key == "$requested_key" ]]; then
            ((found == 0)) ||
                _platform_harness_error "chave duplicada em $expected_file: $key" || return 1
            result=$value
            found=1
        fi
    done < "$expected_file"

    ((found == 1)) ||
        _platform_harness_error "chave ausente em $expected_file: $requested_key" || return 1
    printf '%s\n' "$result"
}

platform_harness_validate_fixture() {
    local case_name=${1:-}
    local fixture_dir entry basename count=0 required found

    [[ $case_name =~ ^[a-z0-9][a-z0-9.-]*$ ]] ||
        _platform_harness_error "nome de fixture inválido: $case_name" || return 1
    fixture_dir="$PLATFORM_HARNESS_FIXTURES_DIR/$case_name"
    [[ -d $fixture_dir && ! -L $fixture_dir ]] ||
        _platform_harness_error "fixture ausente ou insegura: $case_name" || return 1

    for required in "${_PLATFORM_HARNESS_FIXTURE_FILES[@]}"; do
        [[ -f $fixture_dir/$required && ! -L $fixture_dir/$required ]] ||
            _platform_harness_error "fixture $case_name sem arquivo regular $required" || return 1
    done

    for entry in "$fixture_dir"/*; do
        basename=${entry##*/}
        found=0
        for required in "${_PLATFORM_HARNESS_FIXTURE_FILES[@]}"; do
            if [[ $basename == "$required" ]]; then
                found=1
                break
            fi
        done
        ((found == 1)) ||
            _platform_harness_error "arquivo inesperado na fixture $case_name: $basename" || return 1
        [[ -f $entry && ! -L $entry ]] ||
            _platform_harness_error "entrada insegura na fixture $case_name: $basename" || return 1
        count=$((count + 1))
    done
    ((count == ${#_PLATFORM_HARNESS_FIXTURE_FILES[@]})) ||
        _platform_harness_error "fixture $case_name não contém exatamente cinco arquivos" || return 1
}

_platform_harness_validate_source_file() {
    local path=${1:-}
    local description=${2:-arquivo}
    [[ -f $path && ! -L $path ]] ||
        _platform_harness_error "$description deve ser arquivo regular sem link: $path"
}

_platform_harness_write_dispatch_shim() {
    local destination=$1
    {
        printf '%s\n' '#!/usr/bin/bash'
        printf '%s\n' 'set -u'
        printf '%s\n' 'export PLATFORM_HARNESS_INTERNAL=1'
        printf '%s\n' 'exec /usr/bin/bash "${PLATFORM_HARNESS_LIBRARY:?}" __dispatch "$@"'
    } > "$destination"
    /usr/bin/chmod 0555 -- "$destination"
}

_platform_harness_write_command_shim() {
    local destination=$1
    {
        printf '%s\n' '#!/usr/bin/bash'
        printf '%s\n' 'set -u'
        printf '%s\n' 'export PLATFORM_HARNESS_INTERNAL=1'
        printf '%s\n' 'exec "${PLATFORM_HARNESS_DISPATCH_BIN:?}" execute "${0##*/}" "$@"'
    } > "$destination"
    /usr/bin/chmod 0555 -- "$destination"
}

_platform_harness_write_bash_env() {
    local destination=$1
    {
        printf '%s\n' 'if [[ ${PLATFORM_HARNESS_INTERNAL:-0} == 1 || $0 == "${PLATFORM_HARNESS_PATH:-/caminho-inexistente}/"* ]]; then'
        printf '%s\n' '    return 0'
        printf '%s\n' 'fi'
        printf '%s\n' 'command_not_found_handle() {'
        printf '%s\n' '    platform-harness-dispatch missing "$@"'
        printf '%s\n' '}'
        printf '%s\n' 'readonly -f command_not_found_handle'
        printf '%s\n' 'readonly PATH HOME TMPDIR LC_ALL LANG TZ BASH_ENV'
        printf '%s\n' 'readonly PLATFORM_HARNESS_ACTIVE PLATFORM_HARNESS_RESTRICTED'
        printf '%s\n' 'readonly PLATFORM_CASE PLATFORM_ROOT PLATFORM_OS_RELEASE'
        printf '%s\n' 'readonly PLATFORM_PROBE_DIR PLATFORM_COMMANDS_FILE'
        printf '%s\n' 'readonly PLATFORM_SYSTEMCTL_UNITS_FILE PLATFORM_BOOT_EVIDENCE_FILE'
        printf '%s\n' 'readonly PLATFORM_CALL_LOG PLATFORM_FORBIDDEN_LOG PLATFORM_TRACE_LOG'
        printf '%s\n' 'readonly PLATFORM_HARNESS_DIR PLATFORM_HARNESS_PATH PLATFORM_HARNESS_WORK_DIR'
        printf '%s\n' 'readonly PLATFORM_HARNESS_LIBRARY PLATFORM_HARNESS_DISPATCH_BIN'
        printf '%s\n' 'readonly PLATFORM_MALICIOUS_MARKER'
        printf '%s\n' 'enable -n kill'
        printf '%s\n' 'enable -n builtin'
        printf '%s\n' 'enable -n enable'
        printf '%s\n' "PS4='+TRACE|'"
        printf '%s\n' 'readonly PS4 BASH_XTRACEFD'
        printf '%s\n' 'set -x'
    } > "$destination"
    /usr/bin/chmod 0444 -- "$destination"
}

_platform_harness_materialize_commands() {
    local commands_file=$1
    local bin_dir=$2
    local line command arguments status stdout stderr extra rest pipe_count key
    declare -A seen_records=()
    declare -A seen_commands=()

    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ -z $line || $line == \#* ]] && continue

        rest=$line
        pipe_count=0
        while [[ $rest == *'|'* ]]; do
            rest=${rest#*|}
            pipe_count=$((pipe_count + 1))
        done
        ((pipe_count == 4)) ||
            _platform_harness_error "commands.txt exige cinco campos separados por |: $line" || return 1

        IFS='|' read -r command arguments status stdout stderr extra <<< "$line"
        [[ $command =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ ]] ||
            _platform_harness_error "nome de comando inválido em commands.txt: $command" || return 1
        [[ $status =~ ^[0-9]+$ ]] && ((status >= 0 && status <= 255)) ||
            _platform_harness_error "status inválido para $command: $status" || return 1

        key=$command$'\x1f'$arguments
        [[ ! ${seen_records[$key]+presente} ]] ||
            _platform_harness_error "resposta duplicada para $command $arguments" || return 1
        seen_records[$key]=1

        if [[ ! ${seen_commands[$command]+presente} ]]; then
            _platform_harness_write_command_shim "$bin_dir/$command" || return 1
            seen_commands[$command]=1
        fi
    done < "$commands_file"
}

platform_harness_digest_tree() {
    local tree=${1:-}
    local manifest entry mode file_hash final_hash

    [[ -d $tree && ! -L $tree ]] ||
        _platform_harness_error "árvore inválida para digest: $tree" || return 1

    if ! manifest=$(
        builtin cd -- "$tree" || exit 1
        while IFS= read -r -d '' entry; do
            mode=$(/usr/bin/stat -c '%a' -- "$entry") || exit 1
            if [[ -d $entry && ! -L $entry ]]; then
                printf 'D|%q|%s\n' "$entry" "$mode"
            elif [[ -f $entry && ! -L $entry ]]; then
                if (( (8#$mode & 0444) == 0 )); then
                    file_hash=UNREADABLE
                else
                    file_hash=$(/usr/bin/sha256sum -- "$entry") || exit 1
                    file_hash=${file_hash%% *}
                fi
                printf 'F|%q|%s|%s\n' "$entry" "$mode" "$file_hash"
            elif [[ -L $entry ]]; then
                printf 'L|%q|%s\n' "$entry" "$mode"
            else
                printf 'O|%q|%s\n' "$entry" "$mode"
            fi
        done < <(/usr/bin/find . -mindepth 1 -print0 | /usr/bin/sort -z)
    ); then
        _platform_harness_error "falha ao calcular manifesto de $tree" || return 1
    fi

    final_hash=$(printf '%s' "$manifest" | /usr/bin/sha256sum) || return 1
    printf '%s\n' "${final_hash%% *}"
}

platform_harness_cleanup() {
    local sandbox=${PLATFORM_HARNESS_DIR:-}
    local parent=${PLATFORM_HARNESS_TMP_PARENT_USED:-}

    if [[ -n $sandbox && -n $parent && $sandbox != / && ! -L $sandbox && \
        $sandbox == "$parent"/platform-harness.* && -f $sandbox/.platform-harness-owned ]]; then
        /usr/bin/chmod -R u+w -- "$sandbox" 2>/dev/null || :
        /usr/bin/rm -rf -- "$sandbox"
    fi

    unset PLATFORM_HARNESS_ACTIVE PLATFORM_HARNESS_RESTRICTED
    unset PLATFORM_CASE PLATFORM_ROOT PLATFORM_OS_RELEASE PLATFORM_PROBE_DIR
    unset PLATFORM_COMMANDS_FILE PLATFORM_SYSTEMCTL_UNITS_FILE PLATFORM_BOOT_EVIDENCE_FILE
    unset PLATFORM_CALL_LOG PLATFORM_FORBIDDEN_LOG PLATFORM_TRACE_LOG PLATFORM_HARNESS_DIR
    unset PLATFORM_HARNESS_PATH PLATFORM_HARNESS_WORK_DIR PLATFORM_HARNESS_HOME
    unset PLATFORM_HARNESS_TMPDIR PLATFORM_HARNESS_DISPATCH_BIN PLATFORM_HARNESS_BASH_ENV
    unset PLATFORM_HARNESS_TMP_PARENT_USED PLATFORM_ROOT_DIGEST_BEFORE
    unset PLATFORM_HARNESS_RUN_COUNT PLATFORM_MALICIOUS_MARKER
}

platform_harness_setup() {
    local case_name=${1:-}
    local os_release_mode=${2:-present}
    local fixture_dir tmp_parent sandbox
    local os_release_source commands_source systemctl_source boot_source

    [[ -z ${PLATFORM_HARNESS_DIR:-} ]] ||
        _platform_harness_error 'já existe um sandbox ativo; chame platform_harness_cleanup' || return 1
    platform_harness_validate_fixture "$case_name" || return 1

    case $os_release_mode in
        present | absent | unreadable) ;;
        *)
            _platform_harness_error "modo de os-release inválido: $os_release_mode" || return 1
            ;;
    esac

    fixture_dir="$PLATFORM_HARNESS_FIXTURES_DIR/$case_name"
    os_release_source=${PLATFORM_HARNESS_OS_RELEASE_OVERRIDE:-$fixture_dir/os-release}
    commands_source=${PLATFORM_HARNESS_COMMANDS_OVERRIDE:-$fixture_dir/commands.txt}
    systemctl_source=${PLATFORM_HARNESS_SYSTEMCTL_OVERRIDE:-$fixture_dir/systemctl-units.txt}
    boot_source=${PLATFORM_HARNESS_BOOT_EVIDENCE_OVERRIDE:-$fixture_dir/boot-evidence.txt}

    _platform_harness_validate_source_file "$os_release_source" os-release || return 1
    _platform_harness_validate_source_file "$commands_source" commands.txt || return 1
    _platform_harness_validate_source_file "$systemctl_source" systemctl-units.txt || return 1
    _platform_harness_validate_source_file "$boot_source" boot-evidence.txt || return 1

    tmp_parent=${PLATFORM_HARNESS_TMP_PARENT:-${TMPDIR:-/tmp}}
    [[ -d $tmp_parent && -w $tmp_parent && ! -L $tmp_parent ]] ||
        _platform_harness_error "diretório temporário inseguro: $tmp_parent" || return 1
    tmp_parent=$(builtin cd -- "$tmp_parent" && builtin pwd -P) || return 1

    sandbox=$(/usr/bin/mktemp -d "$tmp_parent/platform-harness.XXXXXXXX") ||
        _platform_harness_error 'mktemp falhou' || return 1
    PLATFORM_HARNESS_DIR=$sandbox
    PLATFORM_HARNESS_TMP_PARENT_USED=$tmp_parent
    : > "$sandbox/.platform-harness-owned"

    if ! /usr/bin/mkdir -p -- \
        "$sandbox/root/etc" "$sandbox/probes" "$sandbox/bin" \
        "$sandbox/home" "$sandbox/tmp" "$sandbox/work"; then
        platform_harness_cleanup
        return 1
    fi

    if [[ $os_release_mode == present ]]; then
        /usr/bin/cp -- "$os_release_source" "$sandbox/root/etc/os-release" || {
            platform_harness_cleanup
            return 1
        }
    elif [[ $os_release_mode == unreadable ]]; then
        /usr/bin/mkdir -- "$sandbox/root/etc/os-release" || {
            platform_harness_cleanup
            return 1
        }
    fi
    /usr/bin/cp -- "$commands_source" "$sandbox/probes/commands.txt" || {
        platform_harness_cleanup
        return 1
    }
    /usr/bin/cp -- "$systemctl_source" "$sandbox/probes/systemctl-units.txt" || {
        platform_harness_cleanup
        return 1
    }
    /usr/bin/cp -- "$boot_source" "$sandbox/probes/boot-evidence.txt" || {
        platform_harness_cleanup
        return 1
    }

    : > "$sandbox/calls.log"
    : > "$sandbox/forbidden.log"
    : > "$sandbox/trace.log"

    _platform_harness_write_dispatch_shim "$sandbox/bin/platform-harness-dispatch" || {
        platform_harness_cleanup
        return 1
    }
    if ! _platform_harness_materialize_commands "$sandbox/probes/commands.txt" "$sandbox/bin"; then
        platform_harness_cleanup
        return 1
    fi
    _platform_harness_write_bash_env "$sandbox/bash-env.sh" || {
        platform_harness_cleanup
        return 1
    }

    /usr/bin/chmod 0555 -- "$sandbox/root" "$sandbox/root/etc" "$sandbox/probes" "$sandbox/bin"
    /usr/bin/chmod 0444 -- "$sandbox/probes/commands.txt" \
        "$sandbox/probes/systemctl-units.txt" "$sandbox/probes/boot-evidence.txt"
    if [[ $os_release_mode == present ]]; then
        /usr/bin/chmod 0444 -- "$sandbox/root/etc/os-release"
    elif [[ $os_release_mode == unreadable ]]; then
        /usr/bin/chmod 0555 -- "$sandbox/root/etc/os-release"
    fi
    /usr/bin/chmod 0600 -- "$sandbox/calls.log" "$sandbox/forbidden.log" "$sandbox/trace.log"
    /usr/bin/chmod 0700 -- "$sandbox/home" "$sandbox/tmp" "$sandbox/work"

    PLATFORM_HARNESS_ACTIVE=1
    PLATFORM_HARNESS_RESTRICTED=1
    PLATFORM_CASE=$case_name
    PLATFORM_ROOT="$sandbox/root"
    PLATFORM_OS_RELEASE="$sandbox/root/etc/os-release"
    PLATFORM_PROBE_DIR="$sandbox/probes"
    PLATFORM_COMMANDS_FILE="$sandbox/probes/commands.txt"
    PLATFORM_SYSTEMCTL_UNITS_FILE="$sandbox/probes/systemctl-units.txt"
    PLATFORM_BOOT_EVIDENCE_FILE="$sandbox/probes/boot-evidence.txt"
    PLATFORM_CALL_LOG="$sandbox/calls.log"
    PLATFORM_FORBIDDEN_LOG="$sandbox/forbidden.log"
    PLATFORM_TRACE_LOG="$sandbox/trace.log"
    PLATFORM_HARNESS_PATH="$sandbox/bin"
    PLATFORM_HARNESS_WORK_DIR="$sandbox/work"
    PLATFORM_HARNESS_HOME="$sandbox/home"
    PLATFORM_HARNESS_TMPDIR="$sandbox/tmp"
    PLATFORM_HARNESS_DISPATCH_BIN="$sandbox/bin/platform-harness-dispatch"
    PLATFORM_HARNESS_BASH_ENV="$sandbox/bash-env.sh"
    PLATFORM_MALICIOUS_MARKER=${PLATFORM_HARNESS_MARKER_OVERRIDE:-$sandbox/malicious-marker}
    PLATFORM_HARNESS_RUN_COUNT=0

    if ! PLATFORM_ROOT_DIGEST_BEFORE=$(platform_harness_digest_tree "$PLATFORM_ROOT"); then
        platform_harness_cleanup
        return 1
    fi

    export PLATFORM_HARNESS_ACTIVE PLATFORM_HARNESS_RESTRICTED PLATFORM_CASE
    export PLATFORM_ROOT PLATFORM_OS_RELEASE PLATFORM_PROBE_DIR PLATFORM_COMMANDS_FILE
    export PLATFORM_SYSTEMCTL_UNITS_FILE PLATFORM_BOOT_EVIDENCE_FILE
    export PLATFORM_CALL_LOG PLATFORM_FORBIDDEN_LOG PLATFORM_TRACE_LOG PLATFORM_HARNESS_DIR
    export PLATFORM_HARNESS_PATH PLATFORM_HARNESS_WORK_DIR
    export PLATFORM_HARNESS_LIBRARY PLATFORM_HARNESS_DISPATCH_BIN PLATFORM_MALICIOUS_MARKER
}

_platform_harness_join_arguments() {
    local joined= argument separator=
    for argument in "$@"; do
        joined+=$separator$argument
        separator=' '
    done
    _PLATFORM_HARNESS_JOINED=$joined
}

_platform_harness_command_forbidden() {
    local command=${1:-}
    local arguments=${2:-}

    case $command in
        sudo | doas | pkexec | su | \
            apt | apt-get | aptitude | dpkg | dnf | dnf5 | yum | \
            pacman | zypper | emerge | apk | xbps-install | \
            rpm-ostree | transactional-update | nix-env | flatpak | snap | \
            mount | umount | swapon | swapoff | losetup | modprobe | insmod | rmmod | \
            update-grub | grub-mkconfig | grub-install | kernelstub | \
            dracut | update-initramfs | mkinitcpio | \
            netplan | ufw | firewall-cmd | iptables | ip6tables | ebtables | \
            reboot | shutdown | poweroff | halt | kill | \
            tee | install | cp | mv | rm | mkdir | rmdir | chmod | chown | chgrp | \
            ln | truncate | dd | touch)
            return 0
            ;;
        systemctl)
            case $arguments in
                'is-active '* | 'is-enabled '* | 'show '* | 'status '* | \
                    list-units | 'list-units '* | list-unit-files | 'list-unit-files '* | \
                    is-system-running | 'is-system-running '*)
                    return 1
                    ;;
                *) return 0 ;;
            esac
            ;;
        bootctl)
            case $arguments in
                status | 'status '* | is-installed | 'is-installed '*) return 1 ;;
                *) return 0 ;;
            esac
            ;;
        ip)
            case $arguments in
                *' show' | *' show '* | 'route get '*) return 1 ;;
                *) return 0 ;;
            esac
            ;;
        nmcli)
            case $arguments in
                general\ status | device\ status | 'device show'* | 'connection show'*) return 1 ;;
                *) return 0 ;;
            esac
            ;;
        nft)
            case $arguments in
                list | 'list '*) return 1 ;;
                *) return 0 ;;
            esac
            ;;
        virsh)
            case $arguments in
                list | 'list '* | 'dominfo '* | 'domstate '* | net-list | 'net-list '* | \
                    pool-list | 'pool-list '* | version | uri | capabilities)
                    return 1
                    ;;
                *) return 0 ;;
            esac
            ;;
        sysctl)
            case $arguments in
                -w* | *=*) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        sed)
            case " $arguments " in
                *' -i '* | *' --in-place '*) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        *)
            return 1
            ;;
    esac
}

_platform_harness_sanitize_log_field() {
    local value=${1-}
    value=${value//\\/\\\\}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    value=${value//|/\\x7c}
    _PLATFORM_HARNESS_SANITIZED=$value
}

_platform_harness_log_call() {
    local kind=$1 command=$2 arguments=$3 status=$4
    local safe_command safe_arguments

    _platform_harness_sanitize_log_field "$command"
    safe_command=$_PLATFORM_HARNESS_SANITIZED
    _platform_harness_sanitize_log_field "$arguments"
    safe_arguments=$_PLATFORM_HARNESS_SANITIZED
    printf '%s|%s|%s|%s\n' "$kind" "$safe_command" "$safe_arguments" "$status" >> "$PLATFORM_CALL_LOG"
    if [[ $kind == forbidden ]]; then
        printf '%s|%s|%s|%s\n' "$kind" "$safe_command" "$safe_arguments" "$status" >> "$PLATFORM_FORBIDDEN_LOG"
    fi
}

_platform_harness_dispatch() {
    local mode=${1:-}
    local command=${2:-}
    shift 2 2>/dev/null || return 64
    local arguments line configured_command configured_arguments configured_status
    local configured_stdout configured_stderr extra

    [[ $mode == execute || $mode == missing ]] || return 64
    [[ -n $command ]] || return 64
    _platform_harness_join_arguments "$@"
    arguments=$_PLATFORM_HARNESS_JOINED

    if _platform_harness_command_forbidden "$command" "$arguments"; then
        _platform_harness_log_call forbidden "$command" "$arguments" 126
        return 126
    fi

    if [[ $mode == missing ]]; then
        _platform_harness_log_call missing "$command" "$arguments" 127
        return 127
    fi

    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ -z $line || $line == \#* ]] && continue
        IFS='|' read -r configured_command configured_arguments configured_status \
            configured_stdout configured_stderr extra <<< "$line"
        if [[ $configured_command == "$command" && $configured_arguments == "$arguments" ]]; then
            _platform_harness_log_call allowed "$command" "$arguments" "$configured_status"
            [[ -z $configured_stdout ]] || printf '%b' "$configured_stdout"
            [[ -z $configured_stderr ]] || printf '%b' "$configured_stderr" >&2
            return "$configured_status"
        fi
    done < "$PLATFORM_COMMANDS_FILE"

    _platform_harness_log_call missing "$command" "$arguments" 127
    return 127
}

platform_harness_run() {
    local target=${1:-}
    shift 2>/dev/null || return 64

    [[ ${PLATFORM_HARNESS_ACTIVE:-0} == 1 && -n ${PLATFORM_HARNESS_DIR:-} ]] ||
        _platform_harness_error 'nenhum sandbox ativo' || return 1
    [[ -n $target ]] || _platform_harness_error 'alvo ausente' || return 1
    if [[ $target != /* ]]; then
        target="$(builtin pwd -P)/$target"
    fi
    [[ -f $target && ! -L $target ]] ||
        _platform_harness_error "alvo deve ser arquivo regular sem link: $target" || return 1

    PLATFORM_HARNESS_RUN_COUNT=$((PLATFORM_HARNESS_RUN_COUNT + 1))
    (
        builtin cd -- "$PLATFORM_HARNESS_WORK_DIR" || exit 1
        /usr/bin/env -i \
            PATH="$PLATFORM_HARNESS_PATH" \
            HOME="$PLATFORM_HARNESS_HOME" \
            TMPDIR="$PLATFORM_HARNESS_TMPDIR" \
            LC_ALL=C LANG=C TZ=UTC \
            BASH_ENV="$PLATFORM_HARNESS_BASH_ENV" \
            BASH_XTRACEFD=9 \
            PLATFORM_HARNESS_ACTIVE=1 \
            PLATFORM_HARNESS_RESTRICTED=1 \
            PLATFORM_CASE="$PLATFORM_CASE" \
            PLATFORM_ROOT="$PLATFORM_ROOT" \
            PLATFORM_OS_RELEASE="$PLATFORM_OS_RELEASE" \
            PLATFORM_PROBE_DIR="$PLATFORM_PROBE_DIR" \
            PLATFORM_COMMANDS_FILE="$PLATFORM_COMMANDS_FILE" \
            PLATFORM_SYSTEMCTL_UNITS_FILE="$PLATFORM_SYSTEMCTL_UNITS_FILE" \
            PLATFORM_BOOT_EVIDENCE_FILE="$PLATFORM_BOOT_EVIDENCE_FILE" \
            PLATFORM_CALL_LOG="$PLATFORM_CALL_LOG" \
            PLATFORM_FORBIDDEN_LOG="$PLATFORM_FORBIDDEN_LOG" \
            PLATFORM_TRACE_LOG="$PLATFORM_TRACE_LOG" \
            PLATFORM_HARNESS_DIR="$PLATFORM_HARNESS_DIR" \
            PLATFORM_HARNESS_PATH="$PLATFORM_HARNESS_PATH" \
            PLATFORM_HARNESS_WORK_DIR="$PLATFORM_HARNESS_WORK_DIR" \
            PLATFORM_HARNESS_LIBRARY="$PLATFORM_HARNESS_LIBRARY" \
            PLATFORM_HARNESS_DISPATCH_BIN="$PLATFORM_HARNESS_DISPATCH_BIN" \
            PLATFORM_MALICIOUS_MARKER="$PLATFORM_MALICIOUS_MARKER" \
            /usr/bin/bash --noprofile --norc --restricted "$target" "$@" \
            9>> "$PLATFORM_TRACE_LOG"
    )
}

platform_harness_assert_root_unchanged() {
    local after
    [[ -n ${PLATFORM_ROOT_DIGEST_BEFORE:-} ]] ||
        _platform_harness_error 'digest inicial ausente' || return 1
    after=$(platform_harness_digest_tree "$PLATFORM_ROOT") || return 1
    [[ $after == "$PLATFORM_ROOT_DIGEST_BEFORE" ]] ||
        _platform_harness_error 'a raiz simulada foi alterada' || return 1
}

platform_harness_assert_no_forbidden() {
    [[ -f ${PLATFORM_FORBIDDEN_LOG:-} ]] ||
        _platform_harness_error 'log de chamadas proibidas ausente' || return 1
    if [[ -s $PLATFORM_FORBIDDEN_LOG ]]; then
        _platform_harness_error 'foram registradas chamadas proibidas'
        while IFS= read -r line || [[ -n $line ]]; do
            printf '  %s\n' "$line" >&2
        done < "$PLATFORM_FORBIDDEN_LOG"
        return 1
    fi
}

platform_harness_assert_forbidden_logged() {
    local expected_command=${1:-}
    local kind command arguments status

    [[ -n $expected_command ]] || return 1
    while IFS='|' read -r kind command arguments status; do
        if [[ $kind == forbidden && $command == "$expected_command" && $status == 126 ]]; then
            return 0
        fi
    done < "$PLATFORM_FORBIDDEN_LOG"
    _platform_harness_error "chamada proibida não registrada: $expected_command" || return 1
}

platform_harness_assert_no_missing() {
    local kind command arguments status

    [[ -f ${PLATFORM_CALL_LOG:-} ]] ||
        _platform_harness_error 'log de chamadas ausente' || return 1
    while IFS='|' read -r kind command arguments status; do
        if [[ $kind == missing ]]; then
            _platform_harness_error "sondagem não declarada: $command $arguments" || return 1
        fi
    done < "$PLATFORM_CALL_LOG"
}

platform_harness_assert_trace_safe() {
    local line traced

    [[ -s ${PLATFORM_TRACE_LOG:-} ]] ||
        _platform_harness_error 'trace do alvo ausente; prova vazia recusada' || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == *'TRACE|'* ]] || continue
        traced=${line#*TRACE|}
        case $traced in
            *'set +x'* | *'set +o xtrace'*)
                _platform_harness_error "tentativa de desativar auditoria xtrace: $traced" || return 1
                ;;
            /* | 'command '/* | 'command -- '/* | 'exec '/* | 'exec -- '/* | 'source '/* | '. '/*)
                _platform_harness_error "tentativa de comando/carga por caminho absoluto: $traced" || return 1
                ;;
        esac
    done < "$PLATFORM_TRACE_LOG"
}

platform_harness_assert_absolute_attempt_logged() {
    local expected=${1:-}
    local line traced

    [[ -n $expected ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == *'TRACE|'* ]] || continue
        traced=${line#*TRACE|}
        if [[ $traced == "$expected"* || $traced == "command $expected"* ||
            $traced == "exec $expected"* ]]; then
            return 0
        fi
    done < "$PLATFORM_TRACE_LOG"
    _platform_harness_error "tentativa absoluta não registrada no trace: $expected" || return 1
}

platform_harness_assert_clean() {
    (( ${PLATFORM_HARNESS_RUN_COUNT:-0} > 0 )) ||
        _platform_harness_error 'nenhum alvo foi executado' || return 1
    [[ -s ${PLATFORM_CALL_LOG:-} ]] ||
        _platform_harness_error 'nenhuma sondagem foi registrada; prova vazia recusada' || return 1
    platform_harness_assert_no_missing || return 1
    platform_harness_assert_no_forbidden || return 1
    platform_harness_assert_trace_safe || return 1
    platform_harness_assert_root_unchanged
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    if [[ ${1:-} != __dispatch ]]; then
        printf 'platform-harness: uso direto permitido apenas pelo dispatcher interno\n' >&2
        exit 64
    fi
    shift
    _platform_harness_dispatch "$@"
    exit $?
fi
