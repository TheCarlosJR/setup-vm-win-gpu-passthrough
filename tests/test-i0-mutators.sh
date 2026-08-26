#!/usr/bin/env bash
# Caracterização I0 direta dos mutadores críticos 30, 50, 60, 61 e 70.
# Executa os scripts reais em uma cópia temporária com PATH fechado. Os shims
# recusam acesso externo e modelam estado/efeitos para falha e sinal.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=tests/lib/mutator-harness.sh
source "$ROOT/tests/lib/mutator-harness.sh"

CHECKS=0
I0_MUTATOR_MATRIX=${I0_MUTATOR_MATRIX:-gate}
case $I0_MUTATOR_MATRIX in
    gate|smoke|full) ;;
    *) printf 'Uso: I0_MUTATOR_MATRIX=gate|smoke|full %s\n' "$0" >&2; exit 64 ;;
esac
NAT_INPUT=''
BRIDGE_INPUT=$'s\n\n\n'
HOOKS_INPUT=$'APLICAR\n'
AIRLOCK_INPUT=$'s\n\nn\nn\n'

fail() {
    printf 'FALHA I0 mutators: %s\n' "$*" >&2
    if [[ -n ${MUTATOR_ERROR:-} && -s ${MUTATOR_ERROR:-/dev/null} ]]; then
        printf '%s\n' '--- stderr do último mutador ---' >&2
        /usr/bin/sed 's/^/  /' "$MUTATOR_ERROR" >&2
    fi
    if [[ -n ${MUTATOR_FORBIDDEN_LOG:-} && -s ${MUTATOR_FORBIDDEN_LOG:-/dev/null} ]]; then
        printf '%s\n' '--- operações recusadas ---' >&2
        /usr/bin/sed 's/^/  /' "$MUTATOR_FORBIDDEN_LOG" >&2
    fi
    exit 1
}
pass() { CHECKS=$((CHECKS + 1)); }
assert_eq() {
    local expected=$1 actual=$2 description=$3
    [[ $actual == "$expected" ]] || fail "$description (esperado=$expected; obtido=$actual)"
}
assert_nonzero() {
    local actual=$1 description=$2
    [[ $actual -ne 0 ]] || fail "$description deveria retornar não zero"
}
assert_text() {
    local file=$1 expression=$2 description=$3
    /usr/bin/grep -Eq -- "$expression" "$file" || fail "$description"
}
assert_text_any() {
    local expression=$1 description=$2
    /usr/bin/grep -Eq -- "$expression" "$MUTATOR_OUTPUT" \
        || /usr/bin/grep -Eq -- "$expression" "$MUTATOR_ERROR" \
        || fail "$description"
}
assert_no_text() {
    local file=$1 expression=$2 description=$3
    ! /usr/bin/grep -Eq -- "$expression" "$file" || fail "$description"
}
assert_confined() {
    mutator_harness_assert_confined || fail "escape da sandbox em $1"
}
assert_forbidden_operation() {
    local description=$1
    shift
    mutator_harness_command "$@"
    assert_eq 126 "$MUTATOR_RC" "$description"
    [[ -s $MUTATOR_FORBIDDEN_LOG ]] || fail "$description não foi registrada em forbidden.log"
    mutator_harness_reset
}
snapshot_observable() {
    mutator_harness_observable_manifest "$1" "${2:-content}"
}
assert_manifest_equal() {
    /usr/bin/cmp -s "$1" "$2" || fail "$3"
}
assert_manifest_different() {
    ! /usr/bin/cmp -s "$1" "$2" || fail "$3"
}
prepare_network() {
    local mode=$1
    mutator_harness_reset
    [[ $mode == nat ]] || mutator_harness_set_conf REDE_MODO bridge
}
assert_vm_source() {
    local attribute=$1 value=$2
    /usr/bin/python3 - "$MUTATOR_STATE_DIR/vm.xml" "$attribute" "$value" <<'PY'
import sys
import xml.etree.ElementTree as ET
path, attribute, expected = sys.argv[1:]
root = ET.parse(path).getroot()
nodes = [node for node in root.findall('./devices/interface')
         if node.find('mac') is not None
         and node.find('mac').get('address', '').lower() == '52:54:00:12:34:56']
if len(nodes) != 1:
    raise SystemExit(1)
source = nodes[0].find('source')
if source is None or source.get(attribute) != expected:
    raise SystemExit(1)
PY
}
assert_discard() {
    local expected=$1
    /usr/bin/python3 - "$MUTATOR_STATE_DIR/vm.xml" "$expected" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
disks = [disk for disk in root.findall('./devices/disk')
         if disk.find('source') is not None
         and disk.find('source').get('file') == '/vm/fixture.qcow2']
if len(disks) != 1 or disks[0].find('driver').get('discard', '') != sys.argv[2]:
    raise SystemExit(1)
PY
}
assert_video_code43() {
    local video=$1 code43=$2
    /usr/bin/python3 - "$MUTATOR_STATE_DIR/vm.xml" "$video" "$code43" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
video_expected, code43_expected = sys.argv[2:]
has_video = bool(root.findall('./devices/video') or root.findall('./devices/graphics'))
vendor = root.findall('./features/hyperv/vendor_id')
hidden = root.findall('./features/kvm/hidden')
has_code43 = (len(vendor) == 1 and vendor[0].get('state') == 'on'
              and vendor[0].get('value') == 'randomid123'
              and len(hidden) == 1 and hidden[0].get('state') == 'on')
if has_video != (video_expected == 'yes') or has_code43 != (code43_expected == 'yes'):
    raise SystemExit(1)
PY
}
assert_hooks_transaction_restored() {
    local expected_vm_hash=$1 path
    [[ $(mutator_harness_vm_hash) == "$expected_vm_hash" ]] || fail 'etapa 50 não restaurou o XML original'
    for path in \
        etc/libvirt/hooks/qemu \
        etc/libvirt/hooks/qemu.d/fixture-win11/.vm-passthrough-required \
        etc/libvirt/hooks/qemu.d/fixture-win11/.vm-passthrough-installing \
        etc/libvirt/hooks/qemu.d/fixture-win11/prepare/begin/00-vm-passthrough-installing.sh \
        etc/libvirt/hooks/qemu.d/fixture-win11/prepare/begin/01-gpu-preflight.sh \
        etc/libvirt/hooks/qemu.d/fixture-win11/start/begin/01-gpu-vfio-check.sh \
        etc/libvirt/hooks/qemu.d/fixture-win11/release/end/01-gpu-restore.sh \
        usr/local/sbin/vm-passthrough-nvidia-udev; do
        [[ ! -e $MUTATOR_ROOT/$path ]] || fail "etapa 50 deixou recurso gerenciado após rollback: $path"
    done
}
assert_airlock_restored() {
    local test_file_state=${1:-absent}
    [[ ! -e $MUTATOR_STATE_DIR/user-vmtransfer ]] || fail 'rollback Airlock deixou usuário'
    [[ ! -e $MUTATOR_STATE_DIR/group-airlock-transfer ]] || fail 'rollback Airlock deixou grupo'
    [[ ! -e $MUTATOR_STATE_DIR/airlock-mounted ]] || fail 'rollback Airlock deixou montagem'
    [[ ! -e $MUTATOR_STATE_DIR/ufw-active ]] || fail 'rollback Airlock deixou UFW ativo'
    [[ $(<"$MUTATOR_ROOT/etc/fstab") == '# synthetic fstab' ]] || fail 'rollback Airlock não restaurou fstab'
    [[ ! -e $MUTATOR_ROOT/etc/ssh/sshd_config.d/10-airlock.conf ]] || fail 'rollback Airlock deixou drop-in SSH'
    [[ ! -e $MUTATOR_ROOT/etc/ssh/authorized_keys/vmtransfer ]] || fail 'rollback Airlock deixou chave'
    [[ ! -e $MUTATOR_ROOT/etc/libvirt/hooks/qemu.d/fixture-win11/prepare/begin/00-airlock.sh ]] || fail 'rollback Airlock deixou hook'
    [[ -d $MUTATOR_ROOT/etc/ufw && ! -s $MUTATOR_ROOT/etc/ufw/added.rules ]] || fail 'rollback Airlock não restaurou regras UFW'
    if [[ $test_file_state == present ]]; then
        [[ -e $MUTATOR_AIRLOCK_BIND/.teste-escrita && -e $MUTATOR_AIRLOCK_TRANSIT/.teste-escrita ]] \
            || fail 'janela após touch não preservou o arquivo parcial esperado pelo oráculo atual'
    else
        [[ ! -e $MUTATOR_AIRLOCK_BIND/.teste-escrita && ! -e $MUTATOR_AIRLOCK_TRANSIT/.teste-escrita ]] \
            || fail 'rollback Airlock deixou arquivo de teste inesperado'
    fi
}
effect_tail() {
    local count=$1
    /usr/bin/python3 - "$MUTATOR_CALL_LOG" "$MUTATOR_HARNESS_DIR" "$count" <<'PY'
import sys
path, harness, raw_count = sys.argv[1:]
keys=[]
for line in open(path, encoding='utf-8'):
    fields=line.rstrip('\n').split('|')
    if len(fields) > 2 and fields[1] == 'EFFECT':
        keys.append(fields[2].replace(harness, '$H'))
print(';'.join(keys[-int(raw_count):]))
PY
}

declare -a UNIX_CANARY_DIRS=()
declare -a UNIX_CANARY_PIDS=()
UNIX_CANARY_RESULT=''
cleanup() {
    local pid directory
    for pid in "${UNIX_CANARY_PIDS[@]}"; do
        /usr/bin/kill "$pid" 2>/dev/null || :
    done
    for pid in "${UNIX_CANARY_PIDS[@]}"; do
        wait "$pid" 2>/dev/null || :
    done
    for directory in "${UNIX_CANARY_DIRS[@]}"; do
        if [[ ${directory##*/} == i0-mutator-socket.* ]]; then
            /usr/bin/rm -rf -- "$directory"
        fi
    done
    mutator_harness_cleanup
}

start_unix_canary() {
    local parent=$1 directory socket_path ready_path pid
    [[ -d $parent && -w $parent ]] || fail "diretório indisponível para canário AF_UNIX: $parent"
    directory=$(/usr/bin/mktemp -d "$parent/i0-mutator-socket.XXXXXXXX") \
        || fail "não foi possível criar canário AF_UNIX em $parent"
    socket_path="$directory/listener.sock"
    ready_path="$directory/ready"
    /usr/bin/python3 - "$socket_path" "$ready_path" <<'PY' &
import socket
import sys
from pathlib import Path

listener = socket.socket(socket.AF_UNIX)
listener.bind(sys.argv[1])
listener.listen(4)
Path(sys.argv[2]).touch()
while True:
    connection, _ = listener.accept()
    connection.close()
PY
    pid=$!
    UNIX_CANARY_DIRS+=("$directory")
    UNIX_CANARY_PIDS+=("$pid")
    for _ in {1..200}; do
        [[ -S $socket_path && -f $ready_path ]] && break
        /usr/bin/kill -0 "$pid" 2>/dev/null \
            || fail "servidor AF_UNIX encerrou antes de ficar pronto: $parent"
        /usr/bin/sleep 0.01
    done
    [[ -S $socket_path && -f $ready_path ]] \
        || fail "socket AF_UNIX não ficou pronto: $parent"
    UNIX_CANARY_RESULT=$socket_path
}

assert_unix_canary_hidden() {
    local socket_path=$1 description=$2
    /usr/bin/python3 -c 'import socket, sys; client = socket.socket(socket.AF_UNIX); client.connect(sys.argv[1]); client.close()' \
        "$socket_path" || fail "socket AF_UNIX não é conectável fora da sandbox: $description"
    mutator_harness_raw '/usr/bin/python3 -c "import socket,sys; client=socket.socket(socket.AF_UNIX); raise SystemExit(99 if client.connect_ex(sys.argv[1]) == 0 else 0)" "$1"' \
        "$socket_path"
    assert_eq 0 "$MUTATOR_RC" "isolamento do socket AF_UNIX falhou: $description"
}

mutator_harness_setup || fail 'não foi possível criar a sandbox'
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Confinamento: caminhos físicos externos e travessia devem falhar com 126.
# ---------------------------------------------------------------------------
mutator_harness_command cp /tmp/i0-escape /etc/i0-escape
assert_eq 126 "$MUTATOR_RC" 'canário /tmp externo'
[[ -s $MUTATOR_FORBIDDEN_LOG ]] || fail 'escape recusado não foi registrado'
mutator_harness_reset
mutator_harness_command cp /etc/../../tmp/i0-escape /etc/i0-escape
assert_eq 126 "$MUTATOR_RC" 'canário de travessia'
[[ -s $MUTATOR_FORBIDDEN_LOG ]] || fail 'travessia recusada não foi registrada'
mutator_harness_reset

# O namespace bubblewrap torna a raiz do host somente leitura, sobrepõe /tmp e
# /run com tmpfs e substitui /sys e /proc/cmdline por fixtures. Estes canários
# não passam pelo dispatcher: provam que redirecionamentos do shell e código
# embutido em Bash/Python/AWK não conseguem alterar a raiz real do projeto.
OUTSIDE_CANARY="$ROOT/.i0-mutator-host-escape-${BASHPID}-${RANDOM}"
[[ ! -e $OUTSIDE_CANARY ]] || fail 'nome do canário externo já existe'
mutator_harness_raw "printf x > '$OUTSIDE_CANARY'"
assert_nonzero "$MUTATOR_RC" 'redirecionamento absoluto cru fora da sandbox'
[[ ! -e $OUTSIDE_CANARY ]] || fail 'redirecionamento cru escreveu no host'
mutator_harness_command bash -c "printf x > '$OUTSIDE_CANARY'"
assert_nonzero "$MUTATOR_RC" 'bash -c com escrita externa'
[[ ! -e $OUTSIDE_CANARY ]] || fail 'bash -c escreveu no host'
mutator_harness_command python3 -c "open('$OUTSIDE_CANARY', 'w', encoding='utf-8').write('x')"
assert_nonzero "$MUTATOR_RC" 'Python embutido com escrita externa'
[[ ! -e $OUTSIDE_CANARY ]] || fail 'Python embutido escreveu no host'
mutator_harness_command awk "BEGIN { print \"x\" > \"$OUTSIDE_CANARY\" }"
assert_nonzero "$MUTATOR_RC" 'AWK embutido com escrita externa'
[[ ! -e $OUTSIDE_CANARY ]] || fail 'AWK embutido escreveu no host'

TMPFS_CANARY="/tmp/i0-mutator-tmpfs-${BASHPID}-${RANDOM}"
[[ ! -e $TMPFS_CANARY ]] || fail 'nome do canário /tmp já existe no host'
mutator_harness_raw "printf x > '$TMPFS_CANARY' && test -f '$TMPFS_CANARY'"
assert_eq 0 "$MUTATOR_RC" 'tmpfs /tmp não permitiu escrita efêmera interna'
[[ ! -e $TMPFS_CANARY ]] || fail 'overlay /tmp vazou uma escrita para o host'

# Uma raiz host somente leitura ainda permitiria connect(2) em sockets Unix.
# A raiz mínima deve ocultar tanto runtimes conhecidos quanto qualquer socket
# criado em diretório host que não tenha overlay específico.
UNIX_CANARY_PARENT=${XDG_RUNTIME_DIR:-/run/user/$(/usr/bin/id -u)}
if [[ $UNIX_CANARY_PARENT != /run/* || ! -d $UNIX_CANARY_PARENT || ! -w $UNIX_CANARY_PARENT ]]; then
    UNIX_CANARY_PARENT=/run/lock
fi
start_unix_canary "$UNIX_CANARY_PARENT"
RUN_CANARY_SOCKET=$UNIX_CANARY_RESULT
assert_unix_canary_hidden "$RUN_CANARY_SOCKET" '/run'

start_unix_canary /var/tmp
VAR_TMP_CANARY_SOCKET=$UNIX_CANARY_RESULT
assert_unix_canary_hidden "$VAR_TMP_CANARY_SOCKET" '/var/tmp fora dos overlays'

mutator_harness_raw 'printf x > relative-canary'
assert_eq 0 "$MUTATOR_RC" 'redirecionamento relativo dentro do cwd confinado'
[[ -f $MUTATOR_PROJECT/relative-canary ]] || fail 'cwd do mutador não está dentro da sandbox'
/usr/bin/rm -f -- "$MUTATOR_PROJECT/relative-canary"
mutator_harness_raw 'test -e /sys/kernel/iommu_groups/17/devices/0000:0a:00.0 && test ! -e /sys/class/dmi/id/product_uuid && /usr/bin/grep -q "quiet splash" /proc/cmdline'
assert_eq 0 "$MUTATOR_RC" 'fixtures sintéticas de /sys e /proc não ocultaram o host'
mutator_harness_command dmesg --nao-modelado
assert_eq 126 "$MUTATOR_RC" 'comando/subcomando stateful não modelado'
[[ -s $MUTATOR_FORBIDDEN_LOG ]] || fail 'comando stateful não modelado não foi registrado'
mutator_harness_reset
assert_forbidden_operation 'systemctl aceitou operação desconhecida' systemctl mask fixture.service
assert_forbidden_operation 'systemctl aceitou opção interna desconhecida' systemctl is-active --bogus fixture.service
assert_forbidden_operation 'netplan aceitou operação desconhecida' netplan set network.version=2
assert_forbidden_operation 'netplan aceitou argumento interno desconhecido' netplan apply --bogus
assert_forbidden_operation 'ip aceitou operação mutante/desconhecida' ip link set enp3s0 down
assert_forbidden_operation 'ip aceitou sufixo desconhecido em consulta' ip -4 route get 1.1.1.1 extra
assert_forbidden_operation 'ufw aceitou operação desconhecida' ufw reset
assert_forbidden_operation 'ufw aceitou regra allow sem gramática modelada' ufw allow nonsense garbage
assert_forbidden_operation 'ufw aceitou interface iniciada por opção' ufw allow in on --bogus from 192.168.177.10 to any port 22 proto tcp comment teste
assert_forbidden_operation 'virsh aceitou operação desconhecida' virsh destroy fixture-win11
assert_forbidden_operation 'virsh aceitou opção interna desconhecida' virsh dominfo fixture-win11 --bogus
assert_forbidden_operation 'xmlstarlet aceitou operação desconhecida' xmlstarlet fo
assert_forbidden_operation 'xmlstarlet sel aceitou token interno desconhecido' xmlstarlet sel --bogus "$MUTATOR_STATE_DIR/vm.xml"
assert_forbidden_operation 'xmlstarlet sel aceitou XPath não modelado' xmlstarlet sel -t -v 'string(/domain/nonsense)' "$MUTATOR_STATE_DIR/vm.xml"
assert_forbidden_operation 'xmlstarlet count aceitou descendente não modelado' xmlstarlet sel -t -v 'count(/domain/devices/disk/nonsense)' "$MUTATOR_STATE_DIR/vm.xml"
assert_forbidden_operation 'xmlstarlet ed aceitou token interno desconhecido' xmlstarlet ed -u /domain/name -v x "$MUTATOR_STATE_DIR/vm.xml"
assert_forbidden_operation 'xmlstarlet ed aceitou XPath não modelado' xmlstarlet ed -L -d /domain/nonsense "$MUTATOR_STATE_DIR/vm.xml"
assert_forbidden_operation 'xmlstarlet ed aceitou seletor de interface não modelado' xmlstarlet ed -L -s '/domain/devices/interface[nonsense]' -t elem -n source -v '' "$MUTATOR_STATE_DIR/vm.xml"
pass

# O runner normal executa uma prova direta de rollback para permanecer rápido.
# As campanhas `smoke` e `full` são gates dirigidos e ficam registradas no
# baseline I0 com seus comandos explícitos.
if [[ $I0_MUTATOR_MATRIX == gate ]]; then
    prepare_network nat
    snapshot_observable "$MUTATOR_HARNESS_DIR/gate-before.content"
    MUTATOR_TEST_FAIL_EFFECT=8 MUTATOR_TEST_FAIL_MODE=after
    mutator_harness_run 60-rede-bridge.sh "$NAT_INPUT"
    unset MUTATOR_TEST_FAIL_EFFECT MUTATOR_TEST_FAIL_MODE
    assert_nonzero "$MUTATOR_RC" 'gate rápido da etapa 60'
    snapshot_observable "$MUTATOR_HARNESS_DIR/gate-after.content"
    assert_manifest_equal "$MUTATOR_HARNESS_DIR/gate-before.content" "$MUTATOR_HARNESS_DIR/gate-after.content" \
        'gate rápido não restaurou o estado da etapa 60'
    assert_confined 'gate rápido da etapa 60'
    pass
    printf 'OK: caracterização I0 direta dos mutadores (%s; %d grupos de cenários)\n' "$I0_MUTATOR_MATRIX" "$CHECKS"
    exit 0
fi

# ---------------------------------------------------------------------------
# Etapa 60: sucessos NAT/bridge e matrizes de falha/sinal em cada efeito.
# ---------------------------------------------------------------------------
prepare_network nat
mutator_harness_run 60-rede-bridge.sh "$NAT_INPUT"
assert_eq 0 "$MUTATOR_RC" 'sucesso NAT'
assert_eq 11 "$(mutator_harness_effect_count)" 'fronteiras NAT'
[[ -e $MUTATOR_STATE_DIR/network-persistent.xml && -e $MUTATOR_STATE_DIR/network-active.xml \
   && -e $MUTATOR_STATE_DIR/network-autostart ]] || fail 'NAT não ficou persistente/ativa/autostart'
assert_vm_source network passthrough-nat || fail 'NIC não terminou na rede NAT'
assert_text "$MUTATOR_OUTPUT" 'Commit lógico da transação de rede concluído' 'NAT sem commit explícito'
assert_confined 'sucesso NAT'
pass

prepare_network bridge
mutator_harness_run 60-rede-bridge.sh "$BRIDGE_INPUT"
assert_eq 0 "$MUTATOR_RC" 'sucesso bridge'
assert_eq 10 "$(mutator_harness_effect_count)" 'fronteiras bridge'
[[ -e $MUTATOR_ROOT/etc/netplan/90-vm-passthrough-bridge.yaml \
   && -e $MUTATOR_STATE_DIR/bridge-active ]] || fail 'bridge não publicou/aplicou Netplan sintético'
assert_eq 600 "$(/usr/bin/stat -c '%a' "$MUTATOR_ROOT/etc/netplan/90-vm-passthrough-bridge.yaml")" 'modo do Netplan'
assert_vm_source bridge br0 || fail 'NIC não terminou na bridge'
assert_confined 'sucesso bridge'
pass

if [[ $I0_MUTATOR_MATRIX == full && ${I0_MUTATOR_SKIP_60:-0} != 1 ]]; then
for network_mode in nat bridge; do
    if [[ $network_mode == nat ]]; then
        max_effect=11; network_input=$NAT_INPUT
    else
        max_effect=10; network_input=$BRIDGE_INPUT
    fi
    for ((effect_number=1; effect_number<=max_effect; effect_number++)); do
        prepare_network "$network_mode"
        snapshot_observable "$MUTATOR_HARNESS_DIR/before.content"
        MUTATOR_TEST_FAIL_EFFECT=$effect_number
        MUTATOR_TEST_FAIL_MODE=after
        mutator_harness_run 60-rede-bridge.sh "$network_input"
        unset MUTATOR_TEST_FAIL_EFFECT MUTATOR_TEST_FAIL_MODE
        assert_nonzero "$MUTATOR_RC" "falha $network_mode após efeito $effect_number"
        snapshot_observable "$MUTATOR_HARNESS_DIR/after.content"
        assert_manifest_equal "$MUTATOR_HARNESS_DIR/before.content" "$MUTATOR_HARNESS_DIR/after.content" \
            "rollback $network_mode não restaurou conteúdo no efeito $effect_number"
        assert_no_text "$MUTATOR_OUTPUT" 'Commit lógico da transação de rede concluído' \
            "falha $network_mode/$effect_number produziu falso commit"
        assert_confined "falha $network_mode/$effect_number"
    done
    pass

done

for network_mode in nat bridge; do
    if [[ $network_mode == nat ]]; then
        max_effect=11; network_input=$NAT_INPUT
    else
        max_effect=10; network_input=$BRIDGE_INPUT
    fi
    for signal_name in INT TERM EXIT; do
        for ((effect_number=1; effect_number<=max_effect; effect_number++)); do
            prepare_network "$network_mode"
            snapshot_observable "$MUTATOR_HARNESS_DIR/before.content"
            MUTATOR_TEST_SIGNAL_EFFECT=$effect_number
            MUTATOR_TEST_SIGNAL_NAME=$signal_name
            mutator_harness_run 60-rede-bridge.sh "$network_input"
            unset MUTATOR_TEST_SIGNAL_EFFECT MUTATOR_TEST_SIGNAL_NAME
            case $signal_name in
                INT) assert_eq 130 "$MUTATOR_RC" "INT $network_mode/$effect_number" ;;
                TERM) assert_eq 143 "$MUTATOR_RC" "TERM $network_mode/$effect_number" ;;
                EXIT) assert_nonzero "$MUTATOR_RC" "EXIT $network_mode/$effect_number" ;;
            esac
            snapshot_observable "$MUTATOR_HARNESS_DIR/after.content"
            assert_manifest_equal "$MUTATOR_HARNESS_DIR/before.content" "$MUTATOR_HARNESS_DIR/after.content" \
                "sinal $signal_name não restaurou $network_mode/$effect_number"
            assert_no_text "$MUTATOR_OUTPUT" 'Commit lógico da transação de rede concluído' \
                "sinal $signal_name produziu falso commit em $network_mode/$effect_number"
            assert_confined "sinal $signal_name $network_mode/$effect_number"
        done
    done
    pass

done

# Ordem atual do rollback com todos os recursos já mutados.
prepare_network nat
MUTATOR_TEST_SIGNAL_EFFECT=8 MUTATOR_TEST_SIGNAL_NAME=EXIT
mutator_harness_run 60-rede-bridge.sh "$NAT_INPUT"
unset MUTATOR_TEST_SIGNAL_EFFECT MUTATOR_TEST_SIGNAL_NAME
assert_eq 'virsh:net-destroy;virsh:net-undefine;virsh:define;fs:cp:$H/project/passthrough.conf' \
    "$(effect_tail 4)" 'ordem do rollback NAT'
prepare_network bridge
MUTATOR_TEST_SIGNAL_EFFECT=8 MUTATOR_TEST_SIGNAL_NAME=EXIT
mutator_harness_run 60-rede-bridge.sh "$BRIDGE_INPUT"
unset MUTATOR_TEST_SIGNAL_EFFECT MUTATOR_TEST_SIGNAL_NAME
assert_eq 'fs:rm:/etc/netplan/90-vm-passthrough-bridge.yaml;netplan:apply;virsh:define;fs:cp:$H/project/passthrough.conf' \
    "$(effect_tail 4)" 'ordem do rollback bridge'
pass

# Falha antes/depois de cada ação do próprio rollback.
for network_mode in nat bridge; do
    network_input=$NAT_INPUT
    [[ $network_mode == nat ]] || network_input=$BRIDGE_INPUT
    for fail_mode in before after; do
        for rollback_effect in 9 10 11 12; do
            prepare_network "$network_mode"
            MUTATOR_TEST_SIGNAL_EFFECT=8
            MUTATOR_TEST_SIGNAL_NAME=EXIT
            MUTATOR_TEST_FAIL_EFFECT=$rollback_effect
            MUTATOR_TEST_FAIL_MODE=$fail_mode
            mutator_harness_run 60-rede-bridge.sh "$network_input"
            unset MUTATOR_TEST_SIGNAL_EFFECT MUTATOR_TEST_SIGNAL_NAME
            unset MUTATOR_TEST_FAIL_EFFECT MUTATOR_TEST_FAIL_MODE
            assert_nonzero "$MUTATOR_RC" "falha $fail_mode no rollback $network_mode/$rollback_effect"
            assert_text "$MUTATOR_ERROR" 'ROLLBACK INCOMPLETO' \
                "rollback $network_mode/$rollback_effect não sinalizou falha"
            assert_confined "rollback $network_mode/$rollback_effect"
        done
    done
    pass

done

# Oráculo da lacuna atual: define de rollback rc=0, mas sem aplicar, é aceito.
for network_mode in nat bridge; do
    prepare_network "$network_mode"
    original_vm_hash=$(mutator_harness_vm_hash)
    MUTATOR_TEST_SIGNAL_EFFECT=8
    MUTATOR_TEST_SIGNAL_NAME=EXIT
    MUTATOR_TEST_DIVERGE_EFFECT=11
    network_input=$NAT_INPUT
    [[ $network_mode == nat ]] || network_input=$BRIDGE_INPUT
    mutator_harness_run 60-rede-bridge.sh "$network_input"
    unset MUTATOR_TEST_SIGNAL_EFFECT MUTATOR_TEST_SIGNAL_NAME MUTATOR_TEST_DIVERGE_EFFECT
    assert_nonzero "$MUTATOR_RC" "rollback divergente $network_mode"
    [[ $(mutator_harness_vm_hash) != "$original_vm_hash" ]] \
        || fail "rollback divergente $network_mode foi indevidamente considerado aplicado pelo shim"
    assert_text "$MUTATOR_OUTPUT" 'Rollback concluído: estados anteriores restaurados' \
        "oráculo de falso sucesso do rollback $network_mode mudou"
    assert_no_text "$MUTATOR_ERROR" 'ROLLBACK INCOMPLETO' \
        "rollback divergente $network_mode passou a ser detectado; atualize o oráculo"
    assert_text "$MUTATOR_CALL_LOG" '\|DIVERGE\|' 'injeção divergente não foi observada'
done
# O código atual também remove o TMP_DIR e não emite recovery_id nessa falha.
[[ -z $(/usr/bin/find "$MUTATOR_TMP" -mindepth 1 -print -quit) ]] || fail 'TMP_DIR da etapa 60 não foi limpo'
assert_no_text "$MUTATOR_ERROR" 'recovery_id=' 'oráculo atual passou a preservar recovery_id; atualize a classificação'
pass

# Mudança concorrente é registrada pelo harness, mas não detectada pela etapa.
prepare_network nat
MUTATOR_TEST_CONCURRENT_EFFECT=8
mutator_harness_run 60-rede-bridge.sh "$NAT_INPUT"
unset MUTATOR_TEST_CONCURRENT_EFFECT
assert_eq 0 "$MUTATOR_RC" 'concorrência atual da etapa 60'
assert_text "$MUTATOR_CALL_LOG" '\|CONCURRENT\|' 'injeção concorrente ausente'
assert_no_text "$MUTATOR_ERROR" '[Cc]onflito|[Cc]oncorr' 'etapa 60 detectou concorrência sem atualização do oráculo'
/usr/bin/python3 - "$MUTATOR_STATE_DIR/vm.xml" "$MUTATOR_STATE_DIR/network-persistent.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
vm = ET.parse(sys.argv[1]).getroot()
network = ET.parse(sys.argv[2]).getroot()
# O define da VM sobrescreve a mudança; a rede retém metadata ignorada.
if vm.find('./metadata/i0-external-change') is not None:
    raise SystemExit(1)
if network.find('./metadata/i0-external-change') is None:
    raise SystemExit(1)
PY
pass

# Conversões e recusas seguras/atuais.
mutator_harness_reset
mutator_harness_seed_network managed yes yes yes
mutator_harness_set_conf REDE_MODO bridge
mutator_harness_run 60-rede-bridge.sh "$BRIDGE_INPUT"
assert_eq 0 "$MUTATOR_RC" 'conversão NAT -> bridge'
[[ -e $MUTATOR_STATE_DIR/network-persistent.xml && ! -e $MUTATOR_STATE_DIR/network-active.xml \
   && ! -e $MUTATOR_STATE_DIR/network-autostart && -e $MUTATOR_STATE_DIR/bridge-active ]] \
    || fail 'NAT -> bridge terminou em estado inesperado'
assert_vm_source bridge br0 || fail 'NAT -> bridge não migrou a NIC'

mutator_harness_reset
mutator_harness_seed_bridge_runtime
snapshot_observable "$MUTATOR_HARNESS_DIR/before.content"
mutator_harness_run 60-rede-bridge.sh "$NAT_INPUT"
assert_nonzero "$MUTATOR_RC" 'bridge -> NAT sem restauração manual'
snapshot_observable "$MUTATOR_HARNESS_DIR/after.content"
assert_manifest_equal "$MUTATOR_HARNESS_DIR/before.content" "$MUTATOR_HARNESS_DIR/after.content" \
    'recusa bridge -> NAT alterou o estado'
assert_text "$MUTATOR_ERROR" 'restaure o backup Netplan' 'recusa bridge -> NAT sem instrução atual'
pass

# Rede homônima não gerenciada: NAT recusa; bridge hoje preserva e prossegue.
mutator_harness_reset
mutator_harness_seed_network unmanaged yes yes yes
unmanaged_persistent=$(/usr/bin/sha256sum "$MUTATOR_STATE_DIR/network-persistent.xml")
unmanaged_active=$(/usr/bin/sha256sum "$MUTATOR_STATE_DIR/network-active.xml")
snapshot_observable "$MUTATOR_HARNESS_DIR/before.content"
mutator_harness_run 60-rede-bridge.sh "$NAT_INPUT"
assert_nonzero "$MUTATOR_RC" 'NAT com rede não gerenciada'
snapshot_observable "$MUTATOR_HARNESS_DIR/after.content"
assert_manifest_equal "$MUTATOR_HARNESS_DIR/before.content" "$MUTATOR_HARNESS_DIR/after.content" \
    'NAT alterou rede homônima não gerenciada'
assert_text "$MUTATOR_ERROR" 'sem o marcador deste projeto' 'NAT sem diagnóstico de propriedade'

mutator_harness_reset
mutator_harness_seed_network unmanaged yes yes yes
mutator_harness_set_conf REDE_MODO bridge
unmanaged_persistent=$(/usr/bin/sha256sum "$MUTATOR_STATE_DIR/network-persistent.xml")
unmanaged_active=$(/usr/bin/sha256sum "$MUTATOR_STATE_DIR/network-active.xml")
mutator_harness_run 60-rede-bridge.sh "$BRIDGE_INPUT"
assert_eq 0 "$MUTATOR_RC" 'bridge com rede homônima não gerenciada (oráculo atual)'
assert_eq "$unmanaged_persistent" "$(/usr/bin/sha256sum "$MUTATOR_STATE_DIR/network-persistent.xml")" \
    'bridge alterou XML persistente não gerenciado'
assert_eq "$unmanaged_active" "$(/usr/bin/sha256sum "$MUTATOR_STATE_DIR/network-active.xml")" \
    'bridge alterou XML ativo não gerenciado'
[[ -e $MUTATOR_STATE_DIR/bridge-active ]] || fail 'bridge não prosseguiu no oráculo atual de rede não gerenciada'
pass

# Consumidores definidos/ativos bloqueiam as respectivas migrações/restarts.
mutator_harness_reset
mutator_harness_seed_network managed yes yes yes
mutator_harness_seed_other_vm_consumer no
mutator_harness_set_conf REDE_MODO bridge
snapshot_observable "$MUTATOR_HARNESS_DIR/before.content"
mutator_harness_run 60-rede-bridge.sh "$BRIDGE_INPUT"
assert_nonzero "$MUTATOR_RC" 'consumidor definido NAT -> bridge'
snapshot_observable "$MUTATOR_HARNESS_DIR/after.content"
assert_manifest_equal "$MUTATOR_HARNESS_DIR/before.content" "$MUTATOR_HARNESS_DIR/after.content" 'consumidor bridge alterou estado'
assert_text "$MUTATOR_ERROR" 'other-vm' 'consumidor bridge não foi identificado'

mutator_harness_reset
mutator_harness_seed_network managed yes yes yes
mutator_harness_seed_other_vm_consumer yes
mutator_harness_set_conf REDE_NAT_CIDR 192.168.178.0/24
snapshot_observable "$MUTATOR_HARNESS_DIR/before.content"
mutator_harness_run 60-rede-bridge.sh "$NAT_INPUT"
assert_nonzero "$MUTATOR_RC" 'consumidor ativo durante atualização NAT'
snapshot_observable "$MUTATOR_HARNESS_DIR/after.content"
assert_manifest_equal "$MUTATOR_HARNESS_DIR/before.content" "$MUTATOR_HARNESS_DIR/after.content" 'consumidor NAT alterou estado'
assert_text "$MUTATOR_ERROR" 'Outra VM ativa' 'consumidor NAT ativo não foi recusado'
pass

# Colisão e cardinalidade da NIC falham sem alteração observável.
mutator_harness_reset
mutator_harness_seed_route_collision
snapshot_observable "$MUTATOR_HARNESS_DIR/before.content"
mutator_harness_run 60-rede-bridge.sh "$NAT_INPUT"
assert_nonzero "$MUTATOR_RC" 'colisão de sub-rede'
snapshot_observable "$MUTATOR_HARNESS_DIR/after.content"
assert_manifest_equal "$MUTATOR_HARNESS_DIR/before.content" "$MUTATOR_HARNESS_DIR/after.content" 'colisão alterou estado'
assert_text "$MUTATOR_ERROR" 'Colisão detectada' 'colisão sem diagnóstico'

for nic_mode in zero duplicate-mac; do
    mutator_harness_reset
    mutator_harness_seed_vm_nics "$nic_mode"
    snapshot_observable "$MUTATOR_HARNESS_DIR/before.content"
    mutator_harness_run 60-rede-bridge.sh "$NAT_INPUT"
    assert_nonzero "$MUTATOR_RC" "NIC $nic_mode"
    snapshot_observable "$MUTATOR_HARNESS_DIR/after.content"
    assert_manifest_equal "$MUTATOR_HARNESS_DIR/before.content" "$MUTATOR_HARNESS_DIR/after.content" \
        "NIC $nic_mode alterou estado"
    assert_text "$MUTATOR_ERROR" 'não identifica exatamente uma NIC' "NIC $nic_mode sem cardinalidade fechada"
done
mutator_harness_reset
mutator_harness_set_conf VM_NIC_MAC ''
mutator_harness_seed_vm_nics two-distinct
mutator_harness_run 60-rede-bridge.sh $'2\n'
assert_eq 0 "$MUTATOR_RC" 'seleção explícita entre múltiplas NICs legadas'
assert_text "$MUTATOR_PROJECT/passthrough.conf" '^VM_NIC_MAC="52:54:00:65:43:21"$' 'NIC selecionada não foi persistida'
pass

# I4: a segunda execução passou a ser no-op exato. O oráculo anterior exigia
# manifesto exato DIFERENTE, porque cada `salvar_conf` reescrevia o arquivo e
# mudava mtime mesmo com o valor idêntico ("conteúdo converge, mas NAT/bridge
# ainda republicam config"). Agora a publicação acontece dentro do core, que
# converge: valor igual não gera rename, não toca metadados e não toca mtime.
#
# A contagem de efeitos não mudou (7 em NAT, 6 em bridge) porque o que o harness
# conta é a *tentativa* de publicação, registrada antes de o interpretador rodar:
# o wrapper não pode saber de antemão se o core vai convergir, e é justamente
# nessa janela que a injeção de falha e de sinal precisa continuar valendo.
for network_mode in nat bridge; do
    prepare_network "$network_mode"
    network_input=$NAT_INPUT
    expected_second_effects=7
    [[ $network_mode == nat ]] || { network_input=$BRIDGE_INPUT; expected_second_effects=6; }
    mutator_harness_run 60-rede-bridge.sh "$network_input"
    assert_eq 0 "$MUTATOR_RC" "primeira execução $network_mode"
    snapshot_observable "$MUTATOR_HARNESS_DIR/first.content" content
    snapshot_observable "$MUTATOR_HARNESS_DIR/first.exact" exact
    mutator_harness_clear_instrumentation
    mutator_harness_run 60-rede-bridge.sh "$network_input"
    assert_eq 0 "$MUTATOR_RC" "segunda execução $network_mode"
    assert_eq "$expected_second_effects" "$(mutator_harness_effect_count)" "efeitos da segunda execução $network_mode"
    assert_eq "$expected_second_effects" \
        "$(/usr/bin/grep -c 'custom:config-publish' "$MUTATOR_CALL_LOG" || true)" \
        "segunda execução $network_mode deixou de ser só publicação convergente"
    snapshot_observable "$MUTATOR_HARNESS_DIR/second.content" content
    snapshot_observable "$MUTATOR_HARNESS_DIR/second.exact" exact
    assert_manifest_equal "$MUTATOR_HARNESS_DIR/first.content" "$MUTATOR_HARNESS_DIR/second.content" \
        "segunda execução $network_mode mudou conteúdo"
    assert_manifest_equal "$MUTATOR_HARNESS_DIR/first.exact" "$MUTATOR_HARNESS_DIR/second.exact" \
        "segunda execução $network_mode deixou de ser no-op exato"
done
pass
fi # matriz full da etapa 60

# ---------------------------------------------------------------------------
# Etapa 30: REQ-IOMMU-TX. Onde o oráculo de I0 registrava parcialidade, a
# asserção correspondente está marcada com "I5:" e cita o comportamento
# anterior, em vez de apagá-lo do histórico.
#
# A etapa passou a executar a transação REAL de boot: o harness materializa
# /etc/default/grub, /boot/grub/grub.cfg e /etc/modules-load.d/vfio.conf na
# raiz simulada e shima update-grub/update-initramfs. Não há mais efeito
# sintético de kernel-param, então a matriz abaixo prova restauração de
# verdade, e não a restauração de um mock.
# ---------------------------------------------------------------------------
mutator_harness_reset
mutator_harness_boot_manifest "$MUTATOR_HARNESS_DIR/30-boot.antes"
mutator_harness_run 30-iommu-vfio.sh ''
assert_eq 0 "$MUTATOR_RC" 'sucesso etapa 30 fase A'
# I5: eram 3 efeitos, porque kernel_param_add e o initramfs eram efeitos
# sintéticos de uma linha. Agora são 8: backup do GRUB, cópia da fonte,
# escrita, publicação por rename, update-grub, escrita do vfio.conf,
# publicação por rename e update-initramfs.
assert_eq 8 "$(mutator_harness_effect_count)" 'efeitos etapa 30 fase A'
ETAPA_30_EFEITOS=$(mutator_harness_effect_count)
# Persistido para o próximo boot, com o grub.cfg efetivo regenerado...
assert_text "$MUTATOR_ROOT/etc/default/grub" 'amd_iommu=on iommu=pt' 'fase A não persistiu os parâmetros de IOMMU'
assert_text "$MUTATOR_ROOT/boot/grub/grub.cfg" 'amd_iommu=on iommu=pt' 'fase A não regenerou o grub.cfg efetivo'
# ...e NÃO ativo neste boot: os dois eixos são independentes
# (D-IOMMU-ACTIVE-PERSISTENT). Antes, o efeito sintético mutava a cmdline e
# escondia essa distinção.
assert_no_text "$MUTATOR_STATE_DIR/cmdline" 'amd_iommu=on' 'fase A não pode alterar a cmdline em execução'
assert_text_any 'REINICIALIZAÇÃO NECESSÁRIA|reboot' 'fase A não pediu reboot'
assert_text "$MUTATOR_ROOT/etc/modules-load.d/vfio.conf" '^vm-passthrough:vfio inicio|vm-passthrough:vfio inicio' 'bloco gerenciado ausente de vfio.conf'
[[ -e $MUTATOR_STATE_DIR/initramfs-updated ]] || fail 'fase A não regenerou o initramfs'
assert_confined 'etapa 30 sucesso'
pass

# Conteúdo não gerenciado de vfio.conf é preservado, e a migração do formato
# antigo (linhas soltas) não duplica módulo.
mutator_harness_reset
/usr/bin/mkdir -p "$MUTATOR_ROOT/etc/modules-load.d"
printf '%s\n' '# comentario de terceiros' 'vfio' 'outro_modulo' \
    > "$MUTATOR_ROOT/etc/modules-load.d/vfio.conf"
mutator_harness_run 30-iommu-vfio.sh ''
assert_eq 0 "$MUTATOR_RC" 'etapa 30 com vfio.conf de terceiros'
assert_text "$MUTATOR_ROOT/etc/modules-load.d/vfio.conf" '^# comentario de terceiros$' 'comentário de terceiros foi descartado'
assert_text "$MUTATOR_ROOT/etc/modules-load.d/vfio.conf" '^outro_modulo$' 'módulo de terceiros foi descartado'
assert_eq 1 "$(/usr/bin/grep -c '^vfio$' "$MUTATOR_ROOT/etc/modules-load.d/vfio.conf")" 'módulo vfio ficou duplicado após a migração'
assert_confined 'etapa 30 vfio.conf de terceiros'
pass

if [[ $I0_MUTATOR_MATRIX == full && ${I0_MUTATOR_SKIP_30:-0} != 1 ]]; then
# Falha em cada janela: o estado persistente precisa voltar ao original, byte a
# byte, sem resíduo de temporário. I5: o oráculo anterior media exatamente a
# parcialidade que sobrava (cmdline/vfio/initramfs já aplicados).
for fail_mode in before after; do
    for effect_number in $(seq 1 "$ETAPA_30_EFEITOS"); do
        mutator_harness_reset
        mutator_harness_boot_manifest "$MUTATOR_HARNESS_DIR/30-boot.antes"
        MUTATOR_TEST_FAIL_EFFECT=$effect_number MUTATOR_TEST_FAIL_MODE=$fail_mode
        mutator_harness_run 30-iommu-vfio.sh ''
        unset MUTATOR_TEST_FAIL_EFFECT MUTATOR_TEST_FAIL_MODE
        assert_nonzero "$MUTATOR_RC" "falha etapa 30 $fail_mode/$effect_number"
        mutator_harness_boot_manifest "$MUTATOR_HARNESS_DIR/30-boot.depois"
        assert_manifest_equal "$MUTATOR_HARNESS_DIR/30-boot.antes" \
            "$MUTATOR_HARNESS_DIR/30-boot.depois" \
            "etapa 30 $fail_mode/$effect_number deixou estado persistente parcial"
        assert_no_text "$MUTATOR_STATE_DIR/cmdline" 'amd_iommu=on' \
            "etapa 30 $fail_mode/$effect_number alterou a cmdline em execução"
        assert_confined "etapa 30 $fail_mode/$effect_number"
    done
done
pass

for signal_name in INT TERM EXIT; do
    for effect_number in $(seq 1 "$ETAPA_30_EFEITOS"); do
        mutator_harness_reset
        mutator_harness_boot_manifest "$MUTATOR_HARNESS_DIR/30-boot.antes"
        MUTATOR_TEST_SIGNAL_EFFECT=$effect_number MUTATOR_TEST_SIGNAL_NAME=$signal_name
        mutator_harness_run 30-iommu-vfio.sh ''
        unset MUTATOR_TEST_SIGNAL_EFFECT MUTATOR_TEST_SIGNAL_NAME
        case $signal_name in
            INT) assert_eq 130 "$MUTATOR_RC" "INT etapa 30/$effect_number" ;;
            TERM) assert_eq 143 "$MUTATOR_RC" "TERM etapa 30/$effect_number" ;;
            EXIT) assert_nonzero "$MUTATOR_RC" "EXIT etapa 30/$effect_number" ;;
        esac
        mutator_harness_boot_manifest "$MUTATOR_HARNESS_DIR/30-boot.depois"
        # I5: antes, o oráculo exigia justamente o contrário ("sinal 30 não
        # deixou publicação já aplicada"): a publicação sobrevivia ao sinal.
        assert_manifest_equal "$MUTATOR_HARNESS_DIR/30-boot.antes" \
            "$MUTATOR_HARNESS_DIR/30-boot.depois" \
            "sinal $signal_name na etapa 30/$effect_number deixou estado persistente parcial"
    done
done
pass
fi # matriz full de falhas/sinais da etapa 30

# Reexecução antes do reboot: o estado persistente já convergiu, então a
# transação é no-op EXATO (zero efeitos), inclusive metadados e mtimes.
mutator_harness_reset
mutator_harness_run 30-iommu-vfio.sh ''
assert_eq 0 "$MUTATOR_RC" 'primeira execução da etapa 30'
snapshot_observable "$MUTATOR_HARNESS_DIR/30-first.content" content
snapshot_observable "$MUTATOR_HARNESS_DIR/30-first.exact" exact
mutator_harness_clear_instrumentation
mutator_harness_run 30-iommu-vfio.sh ''
assert_eq 0 "$MUTATOR_RC" 'segunda execução da etapa 30 antes do reboot'
assert_eq 0 "$(mutator_harness_effect_count)" 'convergido, a etapa 30 ainda executou efeitos'
snapshot_observable "$MUTATOR_HARNESS_DIR/30-second.content" content
snapshot_observable "$MUTATOR_HARNESS_DIR/30-second.exact" exact
assert_manifest_equal "$MUTATOR_HARNESS_DIR/30-first.content" "$MUTATOR_HARNESS_DIR/30-second.content" 'segunda execução da etapa 30 mudou conteúdo'
assert_manifest_equal "$MUTATOR_HARNESS_DIR/30-first.exact" "$MUTATOR_HARNESS_DIR/30-second.exact" 'segunda execução da etapa 30 deixou de ser no-op exato'
assert_confined 'etapa 30 convergida'
pass

# Só depois do reboot simulado o estado ativo alcança o persistido e a fase B
# começa. É o único caminho pelo qual a cmdline em execução muda.
mutator_harness_simular_reboot
mutator_harness_clear_instrumentation
mutator_harness_run 30-iommu-vfio.sh ''
assert_eq 0 "$MUTATOR_RC" 'etapa 30 fase B'
assert_text_any 'Fase B' 'a etapa 30 não entrou na fase B após o reboot simulado'
assert_eq 1 "$(mutator_harness_effect_count)" 'fase B republica IOMMU_GROUP_GPU'
assert_text "$MUTATOR_PROJECT/passthrough.conf" '^IOMMU_GROUP_GPU="17"$' 'fase B não persistiu IOMMU_GROUP_GPU'
snapshot_observable "$MUTATOR_HARNESS_DIR/30-fb-first.exact" exact
mutator_harness_clear_instrumentation
mutator_harness_run 30-iommu-vfio.sh ''
assert_eq 0 "$MUTATOR_RC" 'segunda fase B'
snapshot_observable "$MUTATOR_HARNESS_DIR/30-fb-second.exact" exact
# I4 já havia invertido este oráculo: a publicação convergente do core tornou a
# fase B um no-op exato. O único efeito continua sendo a tentativa de
# publicação, contada antes de o interpretador rodar.
assert_manifest_equal "$MUTATOR_HARNESS_DIR/30-fb-first.exact" "$MUTATOR_HARNESS_DIR/30-fb-second.exact" 'fase B deixou de ser no-op exato'
assert_confined 'etapa 30 fase B'
pass

# ---------------------------------------------------------------------------
# Etapa 50: transação principal, opções dentro da transação, rollback
# comprovado, backend libvirt resolvido e idempotência exata (REQ-HOOKS-TX e
# REQ-LIBVIRT-BACKEND, fechados em I3). Onde o oráculo de I0 registrava a
# lacuna, a asserção correspondente está marcada com "I3:" e cita o
# comportamento anterior, em vez de apagá-lo do histórico.
# ---------------------------------------------------------------------------
mutator_harness_reset
mutator_harness_run 50-hooks-gpu-hd1.sh "$HOOKS_INPUT"
assert_eq 0 "$MUTATOR_RC" 'sucesso etapa 50'
# D-GPU-UDEV-LOOP: 23 antes do filtro udev. O arquivo novo custa o mesmo par
# de efeitos de qualquer outro gerenciado (install do diretório + mv atômico),
# então todo efeito a partir do 15 desloca +2 nos oráculos abaixo.
assert_eq 25 "$(mutator_harness_effect_count)" 'efeitos etapa 50'
for installed in \
    etc/libvirt/hooks/qemu \
    etc/libvirt/hooks/qemu.d/fixture-win11/.vm-passthrough-required \
    etc/libvirt/hooks/qemu.d/fixture-win11/prepare/begin/01-gpu-preflight.sh \
    etc/libvirt/hooks/qemu.d/fixture-win11/start/begin/01-gpu-vfio-check.sh \
    etc/libvirt/hooks/qemu.d/fixture-win11/release/end/01-gpu-restore.sh \
    usr/local/sbin/vm-passthrough-nvidia-udev; do
    [[ -e $MUTATOR_ROOT/$installed ]] || fail "etapa 50 não instalou $installed"
done
# D-GPU-UDEV-LOOP: a raiz simulada não tem as regras udev da distro, então este
# é o ramo "host sem regras a filtrar": o filtro é publicado, o override não.
# O ramo com regras é provado em tests/test-gpu-udev-loop.sh, que deriva o
# arquivo real e o submete a udevadm verify.
[[ ! -e $MUTATOR_ROOT/etc/udev/rules.d/71-nvidia.rules ]] \
    || fail 'etapa 50 publicou override udev sem regras de distro para filtrar'
[[ ! -e $MUTATOR_ROOT/etc/libvirt/hooks/qemu.d/fixture-win11/.vm-passthrough-installing \
   && ! -e $MUTATOR_ROOT/etc/libvirt/hooks/qemu.d/fixture-win11/prepare/begin/00-vm-passthrough-installing.sh ]] \
    || fail 'etapa 50 deixou marcadores temporários no sucesso'
/usr/bin/python3 - "$MUTATOR_STATE_DIR/vm.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
root=ET.parse(sys.argv[1]).getroot()
if len(root.findall('./devices/hostdev')) != 2:
    raise SystemExit(1)
PY
assert_confined 'etapa 50 sucesso'
pass

if [[ $I0_MUTATOR_MATRIX == full && ${I0_MUTATOR_SKIP_50:-0} != 1 ]]; then
for effect_number in $(/usr/bin/seq 1 25); do
    mutator_harness_reset
    baseline_vm_hash=$(mutator_harness_vm_hash)
    MUTATOR_TEST_FAIL_EFFECT=$effect_number MUTATOR_TEST_FAIL_MODE=after
    mutator_harness_run 50-hooks-gpu-hd1.sh "$HOOKS_INPUT"
    unset MUTATOR_TEST_FAIL_EFFECT MUTATOR_TEST_FAIL_MODE
    assert_nonzero "$MUTATOR_RC" "falha etapa 50/$effect_number"
    assert_hooks_transaction_restored "$baseline_vm_hash"
    assert_confined "falha etapa 50/$effect_number"
done
pass

for signal_name in INT TERM EXIT; do
    for effect_number in 1 15 17 19 25; do
        mutator_harness_reset
        baseline_vm_hash=$(mutator_harness_vm_hash)
        MUTATOR_TEST_SIGNAL_EFFECT=$effect_number MUTATOR_TEST_SIGNAL_NAME=$signal_name
        mutator_harness_run 50-hooks-gpu-hd1.sh "$HOOKS_INPUT"
        unset MUTATOR_TEST_SIGNAL_EFFECT MUTATOR_TEST_SIGNAL_NAME
        case $signal_name in
            INT) assert_eq 130 "$MUTATOR_RC" "INT etapa 50/$effect_number" ;;
            TERM) assert_eq 143 "$MUTATOR_RC" "TERM etapa 50/$effect_number" ;;
            EXIT) assert_nonzero "$MUTATOR_RC" "EXIT etapa 50/$effect_number" ;;
        esac
        assert_hooks_transaction_restored "$baseline_vm_hash"
    done
done
pass

# Todas as combinações das opções atuais.
mutator_harness_reset
mutator_harness_run 50-hooks-gpu-hd1.sh "$HOOKS_INPUT"
assert_video_code43 yes no || fail 'opções vazias da etapa 50'
mutator_harness_reset
mutator_harness_run 50-hooks-gpu-hd1.sh $'APLICAR\nREMOVER\n' --remover-video
assert_eq 0 "$MUTATOR_RC" '--remover-video'
assert_video_code43 no no || fail '--remover-video não convergiu'
mutator_harness_reset
mutator_harness_run 50-hooks-gpu-hd1.sh "$HOOKS_INPUT" --anti-code43
assert_eq 0 "$MUTATOR_RC" '--anti-code43'
assert_video_code43 yes yes || fail '--anti-code43 não convergiu'
mutator_harness_reset
mutator_harness_run 50-hooks-gpu-hd1.sh $'APLICAR\nREMOVER\n' --remover-video --anti-code43
assert_eq 0 "$MUTATOR_RC" 'combinação das opções da etapa 50'
assert_video_code43 no yes || fail 'combinação das opções não convergiu'
pass

# I3: as opções deixaram de ocorrer depois do commit (REQ-HOOKS-TX). O oráculo
# de I0 exigia parcialidade pós-commit; agora falha e sinal na janela da opção
# restauram hooks, serviço e XML como qualquer outra janela mutante.
mutator_harness_reset
baseline_vm_hash=$(mutator_harness_vm_hash)
MUTATOR_TEST_FAIL_EFFECT=26 MUTATOR_TEST_FAIL_MODE=after
mutator_harness_run 50-hooks-gpu-hd1.sh $'APLICAR\nREMOVER\n' --remover-video
unset MUTATOR_TEST_FAIL_EFFECT MUTATOR_TEST_FAIL_MODE
assert_nonzero "$MUTATOR_RC" 'falha na opção --remover-video dentro da transação'
assert_hooks_transaction_restored "$baseline_vm_hash"
assert_video_code43 yes no || fail 'falha na opção não restaurou o vídeo virtual'
assert_confined 'falha na opção --remover-video'

for signal_name in INT TERM EXIT; do
    mutator_harness_reset
    baseline_vm_hash=$(mutator_harness_vm_hash)
    MUTATOR_TEST_SIGNAL_EFFECT=26 MUTATOR_TEST_SIGNAL_NAME=$signal_name
    mutator_harness_run 50-hooks-gpu-hd1.sh "$HOOKS_INPUT" --anti-code43
    unset MUTATOR_TEST_SIGNAL_EFFECT MUTATOR_TEST_SIGNAL_NAME
    case $signal_name in
        INT) assert_eq 130 "$MUTATOR_RC" 'INT na opção anti-code43' ;;
        TERM) assert_eq 143 "$MUTATOR_RC" 'TERM na opção anti-code43' ;;
        EXIT) assert_nonzero "$MUTATOR_RC" 'EXIT na opção anti-code43' ;;
    esac
    assert_hooks_transaction_restored "$baseline_vm_hash"
    assert_video_code43 yes no || fail "$signal_name na opção deixou o anti-Code 43 aplicado"
done
pass

# I3: define de restauração com rc=0 divergente agora é relido e recusado. O
# oráculo de I0 exigia a ausência de "Rollback incompleto".
mutator_harness_reset
baseline_vm_hash=$(mutator_harness_vm_hash)
MUTATOR_TEST_SIGNAL_EFFECT=19 MUTATOR_TEST_SIGNAL_NAME=EXIT MUTATOR_TEST_DIVERGE_EFFECT=20
mutator_harness_run 50-hooks-gpu-hd1.sh "$HOOKS_INPUT"
unset MUTATOR_TEST_SIGNAL_EFFECT MUTATOR_TEST_SIGNAL_NAME MUTATOR_TEST_DIVERGE_EFFECT
assert_nonzero "$MUTATOR_RC" 'rollback divergente etapa 50'
[[ $(mutator_harness_vm_hash) != "$baseline_vm_hash" ]] || fail 'divergência XML da etapa 50 não foi injetada'
assert_text "$MUTATOR_CALL_LOG" '\|DIVERGE\|virsh:define\|' 'define divergente da etapa 50 ausente'
assert_text "$MUTATOR_ERROR" 'ROLLBACK XML NÃO COMPROVADO' 'divergência da etapa 50 não virou erro grave'
assert_text "$MUTATOR_ERROR" 'divergiu do original' 'erro grave da etapa 50 sem evidência da divergência'
assert_text "$MUTATOR_ERROR" 'Rollback incompleto' 'divergência da etapa 50 sem agregação de falha'
pass

# I3 REQ-LIBVIRT-BACKEND: a resolução autoritativa é a mesma da etapa 20 e
# nenhum ponto da etapa 50 assume `libvirtd`.
mutator_harness_reset
mutator_harness_set_systemd_profile modular
mutator_harness_run 50-hooks-gpu-hd1.sh "$HOOKS_INPUT"
assert_eq 0 "$MUTATOR_RC" 'etapa 50 no backend modular'
assert_text "$MUTATOR_OUTPUT" 'Backend libvirt resolvido: virtqemud.socket' 'backend modular não foi resolvido'
assert_text "$MUTATOR_CALL_LOG" 'systemctl:restart:virtqemud.service' 'backend modular não reiniciou virtqemud'
assert_no_text "$MUTATOR_CALL_LOG" 'systemctl:restart:libvirtd' 'backend modular ainda reiniciou libvirtd'
assert_confined 'etapa 50 backend modular'

mutator_harness_reset
mutator_harness_set_systemd_profile ausente
baseline_vm_hash=$(mutator_harness_vm_hash)
mutator_harness_run 50-hooks-gpu-hd1.sh "$HOOKS_INPUT"
assert_nonzero "$MUTATOR_RC" 'etapa 50 sem unidade libvirt'
assert_eq 0 "$(mutator_harness_effect_count)" 'etapa 50 mutou sem backend resolvido'
assert_text "$MUTATOR_ERROR" 'Nenhuma unidade libvirt do perfil' 'recusa de backend ausente sem diagnóstico'
[[ $(mutator_harness_vm_hash) == "$baseline_vm_hash" ]] || fail 'recusa de backend alterou XML'

mutator_harness_reset
mutator_harness_set_systemd_profile monolitico-servico-morto
baseline_vm_hash=$(mutator_harness_vm_hash)
mutator_harness_run 50-hooks-gpu-hd1.sh "$HOOKS_INPUT"
assert_nonzero "$MUTATOR_RC" 'etapa 50 com daemon inativo após restart'
assert_text "$MUTATOR_ERROR" 'não ficou ativo depois do restart' 'pós-condição do restart não foi provada'
assert_hooks_transaction_restored "$baseline_vm_hash"
pass

# I3: segunda execução sobre estado convergido é no-op exato
# (D-HOOKS-IDEMPOTENCE). O oráculo de I0 exigia 31 efeitos e manifesto
# diferente, por causa dos backups e republicações desnecessários.
mutator_harness_reset
mutator_harness_run 50-hooks-gpu-hd1.sh "$HOOKS_INPUT"
snapshot_observable "$MUTATOR_HARNESS_DIR/50-first.content" content
snapshot_observable "$MUTATOR_HARNESS_DIR/50-first.exact" exact
mutator_harness_clear_instrumentation
mutator_harness_run 50-hooks-gpu-hd1.sh "$HOOKS_INPUT"
assert_eq 0 "$MUTATOR_RC" 'segunda execução etapa 50'
assert_eq 0 "$(mutator_harness_effect_count)" 'segunda execução da etapa 50 não foi no-op'
assert_text "$MUTATOR_OUTPUT" 'Estado já convergido' 'segunda execução sem diagnóstico de convergência'
snapshot_observable "$MUTATOR_HARNESS_DIR/50-second.content" content
snapshot_observable "$MUTATOR_HARNESS_DIR/50-second.exact" exact
assert_manifest_equal "$MUTATOR_HARNESS_DIR/50-first.content" "$MUTATOR_HARNESS_DIR/50-second.content" \
    'segunda execução da etapa 50 mudou conteúdo'
assert_manifest_equal "$MUTATOR_HARNESS_DIR/50-first.exact" "$MUTATOR_HARNESS_DIR/50-second.exact" \
    'segunda execução da etapa 50 mudou metadados/mtime'
/usr/bin/python3 - "$MUTATOR_STATE_DIR/vm.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
root=ET.parse(sys.argv[1]).getroot()
if len(root.findall('./devices/hostdev')) != 2:
    raise SystemExit(1)
PY
pass
fi # matriz full da etapa 50

# ---------------------------------------------------------------------------
# Etapa 61: sucesso, rollback, sinais e idempotência sem duplicatas semânticas.
# ---------------------------------------------------------------------------
mutator_harness_reset
mutator_harness_run 61-airlock.sh "$AIRLOCK_INPUT"
assert_eq 0 "$MUTATOR_RC" 'sucesso etapa 61'
assert_eq 14 "$(mutator_harness_effect_count)" 'efeitos etapa 61'
[[ -e $MUTATOR_STATE_DIR/user-vmtransfer && -e $MUTATOR_STATE_DIR/group-airlock-transfer \
   && -e $MUTATOR_STATE_DIR/airlock-mounted ]] || fail 'Airlock não criou conta/montagem'
assert_text "$MUTATOR_ROOT/etc/fstab" 'fuse\.bindfs' 'Airlock não publicou fstab'
[[ -e $MUTATOR_ROOT/etc/ssh/sshd_config.d/10-airlock.conf \
   && -e $MUTATOR_ROOT/etc/libvirt/hooks/qemu.d/fixture-win11/prepare/begin/00-airlock.sh ]] \
    || fail 'Airlock não publicou SSH/hook'
assert_text "$MUTATOR_ROOT/etc/ufw/added.rules" 'SFTP airlock - somente VM Windows' 'Airlock não publicou regra UFW'
[[ ! -e $MUTATOR_AIRLOCK_BIND/.teste-escrita && ! -e $MUTATOR_AIRLOCK_TRANSIT/.teste-escrita ]] \
    || fail 'Airlock deixou arquivo de teste no sucesso'
assert_confined 'etapa 61 sucesso'
pass

if [[ $I0_MUTATOR_MATRIX == full && ${I0_MUTATOR_SKIP_61:-0} != 1 ]]; then
for effect_number in $(/usr/bin/seq 1 14); do
    mutator_harness_reset
    MUTATOR_TEST_FAIL_EFFECT=$effect_number MUTATOR_TEST_FAIL_MODE=after
    mutator_harness_run 61-airlock.sh "$AIRLOCK_INPUT"
    unset MUTATOR_TEST_FAIL_EFFECT MUTATOR_TEST_FAIL_MODE
    assert_nonzero "$MUTATOR_RC" "falha etapa 61/$effect_number"
    if [[ $effect_number -eq 6 ]]; then
        assert_airlock_restored present
    else
        assert_airlock_restored absent
    fi
    assert_confined "falha etapa 61/$effect_number"
done
pass

for signal_name in INT TERM EXIT; do
    for effect_number in 2 7 10 14; do
        mutator_harness_reset
        MUTATOR_TEST_SIGNAL_EFFECT=$effect_number MUTATOR_TEST_SIGNAL_NAME=$signal_name
        mutator_harness_run 61-airlock.sh "$AIRLOCK_INPUT"
        unset MUTATOR_TEST_SIGNAL_EFFECT MUTATOR_TEST_SIGNAL_NAME
        case $signal_name in
            INT) assert_eq 130 "$MUTATOR_RC" "INT etapa 61/$effect_number" ;;
            TERM) assert_eq 143 "$MUTATOR_RC" "TERM etapa 61/$effect_number" ;;
            EXIT) assert_eq 98 "$MUTATOR_RC" "EXIT etapa 61/$effect_number" ;;
        esac
        assert_airlock_restored absent
    done
done
pass

# Falha do próprio rollback vira aviso e o rollback continua; não há estado
# grave agregado nem prova semântica final.
for fail_mode in before after; do
    mutator_harness_reset
    MUTATOR_TEST_SIGNAL_EFFECT=14 MUTATOR_TEST_SIGNAL_NAME=EXIT
    MUTATOR_TEST_FAIL_EFFECT=16 MUTATOR_TEST_FAIL_MODE=$fail_mode
    mutator_harness_run 61-airlock.sh "$AIRLOCK_INPUT"
    unset MUTATOR_TEST_SIGNAL_EFFECT MUTATOR_TEST_SIGNAL_NAME
    unset MUTATOR_TEST_FAIL_EFFECT MUTATOR_TEST_FAIL_MODE
    assert_eq 98 "$MUTATOR_RC" "falha $fail_mode no rollback Airlock"
    assert_text_any 'Não foi possível restaurar.*/etc/fstab' 'rollback Airlock não avisou falha do fstab'
    assert_no_text "$MUTATOR_ERROR" 'ROLLBACK INCOMPLETO|recovery_id=' 'Airlock passou a agregar erro grave; atualize o oráculo'
    if [[ $fail_mode == before ]]; then
        assert_text "$MUTATOR_ROOT/etc/fstab" 'fuse\.bindfs' 'falha antes da restauração deveria deixar fstab divergente'
    else
        [[ $(<"$MUTATOR_ROOT/etc/fstab") == '# synthetic fstab' ]] || fail 'falha após restauração não preservou fstab restaurado'
    fi
done
pass

mutator_harness_reset
mutator_harness_run 61-airlock.sh "$AIRLOCK_INPUT"
snapshot_observable "$MUTATOR_HARNESS_DIR/61-first.content" content
mutator_harness_clear_instrumentation
mutator_harness_run 61-airlock.sh "$AIRLOCK_INPUT"
assert_eq 0 "$MUTATOR_RC" 'segunda execução etapa 61'
assert_eq 11 "$(mutator_harness_effect_count)" 'efeitos segunda execução etapa 61'
snapshot_observable "$MUTATOR_HARNESS_DIR/61-second.content" content
assert_manifest_different "$MUTATOR_HARNESS_DIR/61-first.content" "$MUTATOR_HARNESS_DIR/61-second.content" \
    'segunda execução Airlock virou no-op; atualize o oráculo'
assert_eq 1 "$(/usr/bin/grep -c 'airlock-bindfs' "$MUTATOR_ROOT/etc/fstab")" 'duplicata fstab na segunda execução Airlock'
assert_eq 1 "$(/usr/bin/grep -c 'SFTP airlock - somente VM Windows' "$MUTATOR_ROOT/etc/ufw/added.rules")" \
    'duplicata UFW na segunda execução Airlock'
pass
fi # matriz full da etapa 61

# ---------------------------------------------------------------------------
# Etapa 70: transação de discard (REQ-TRIM-TX, fechada em I3).
#
# O oráculo original de I0 caracterizava a ausência de transação: define sem
# trap, parcialidade preservada em falha/sinal e rollback divergente anunciado
# como sucesso. I3 implementou a transação, então as asserções abaixo passaram a
# exigir o comportamento correto. Cada expectativa invertida está marcada com
# "I3:" e cita o que o oráculo de I0 registrava, para que a mudança fique
# rastreável em vez de apagada.
# ---------------------------------------------------------------------------
mutator_harness_reset
mutator_harness_run 70-trim-discard.sh ''
assert_eq 0 "$MUTATOR_RC" 'sucesso etapa 70'
assert_eq 1 "$(mutator_harness_effect_count)" 'efeitos etapa 70'
assert_discard unmap || fail 'discard não foi aplicado'
assert_confined 'etapa 70 sucesso'
pass

if [[ $I0_MUTATOR_MATRIX == full && ${I0_MUTATOR_SKIP_70:-0} != 1 ]]; then
mutator_harness_reset
baseline_vm_hash=$(mutator_harness_vm_hash)
MUTATOR_TEST_FAIL_EFFECT=1 MUTATOR_TEST_FAIL_MODE=before
mutator_harness_run 70-trim-discard.sh ''
unset MUTATOR_TEST_FAIL_EFFECT MUTATOR_TEST_FAIL_MODE
assert_nonzero "$MUTATOR_RC" 'falha antes do define TRIM'
[[ $(mutator_harness_vm_hash) == "$baseline_vm_hash" ]] || fail 'falha antes do define alterou XML'

mutator_harness_reset
MUTATOR_TEST_FAIL_EFFECT=1 MUTATOR_TEST_FAIL_MODE=after
mutator_harness_run 70-trim-discard.sh ''
unset MUTATOR_TEST_FAIL_EFFECT MUTATOR_TEST_FAIL_MODE
assert_nonzero "$MUTATOR_RC" 'falha imediatamente após define TRIM'
# I3: o oráculo de I0 exigia parcialidade (assert_discard unmap) e a mensagem
# "domínio original foi preservado", que era falsa depois do define. Agora a
# transação restaura e prova a restauração.
assert_discard '' || fail 'falha após define não restaurou o XML original'
assert_text "$MUTATOR_ERROR" 'restaurará o XML original' 'diagnóstico pós-define da transação mudou'
assert_text "$MUTATOR_OUTPUT" 'XML anterior restaurado e comprovado' 'restauração pós-define sem prova semântica'
pass

for signal_name in INT TERM EXIT; do
    mutator_harness_reset
    MUTATOR_TEST_SIGNAL_EFFECT=1 MUTATOR_TEST_SIGNAL_NAME=$signal_name
    mutator_harness_run 70-trim-discard.sh ''
    unset MUTATOR_TEST_SIGNAL_EFFECT MUTATOR_TEST_SIGNAL_NAME
    case $signal_name in
        INT) assert_eq 130 "$MUTATOR_RC" 'INT etapa 70' ;;
        TERM) assert_eq 143 "$MUTATOR_RC" 'TERM etapa 70' ;;
        EXIT) assert_nonzero "$MUTATOR_RC" 'EXIT etapa 70' ;;
    esac
    # I3: o oráculo de I0 exigia parcialidade após o sinal; a transação agora
    # restaura o original em INT, TERM e EXIT, preservando 130/143.
    assert_discard '' || fail "$signal_name após define não restaurou o XML original"
    assert_text "$MUTATOR_OUTPUT" 'XML anterior restaurado e comprovado' \
        "$signal_name não comprovou a restauração"
done
pass

# Falha de releitura aciona restauração comprovada por releitura semântica.
mutator_harness_reset
MUTATOR_TEST_FAIL_CALL='virsh:dumpxml@3'
mutator_harness_run 70-trim-discard.sh ''
unset MUTATOR_TEST_FAIL_CALL
assert_nonzero "$MUTATOR_RC" 'falha de releitura TRIM'
assert_discard '' || fail 'rollback normal TRIM não restaurou XML'
assert_text "$MUTATOR_OUTPUT" 'XML anterior restaurado e comprovado' 'rollback TRIM normal sem prova'

# Rollback divergente: o define de restauração retorna zero sem aplicar.
mutator_harness_reset
MUTATOR_TEST_FAIL_CALL='virsh:dumpxml@3'
MUTATOR_TEST_DIVERGE_EFFECT=2
mutator_harness_run 70-trim-discard.sh ''
unset MUTATOR_TEST_FAIL_CALL MUTATOR_TEST_DIVERGE_EFFECT
assert_nonzero "$MUTATOR_RC" 'rollback divergente TRIM'
assert_discard unmap || fail 'divergência TRIM não foi mantida pelo shim'
# I3: o oráculo de I0 exigia o falso sucesso ("XML anterior restaurado" sem
# releitura) e a ausência de erro grave. Agora a divergência é detectada.
assert_no_text "$MUTATOR_OUTPUT" 'XML anterior restaurado' 'rollback divergente TRIM ainda anuncia sucesso'
assert_text "$MUTATOR_ERROR" 'ROLLBACK XML NÃO COMPROVADO' 'rollback divergente TRIM sem erro grave'
assert_text "$MUTATOR_ERROR" 'divergiu do original' 'erro grave sem a evidência da divergência'
assert_text "$MUTATOR_ERROR" 'XML original preservado para recuperação' 'divergência não preservou evidência'
pass

# Falha explícita do define de restauração.
mutator_harness_reset
MUTATOR_TEST_FAIL_CALL='virsh:dumpxml@3'
MUTATOR_TEST_FAIL_EFFECT=2 MUTATOR_TEST_FAIL_MODE=before
mutator_harness_run 70-trim-discard.sh ''
unset MUTATOR_TEST_FAIL_CALL MUTATOR_TEST_FAIL_EFFECT MUTATOR_TEST_FAIL_MODE
assert_nonzero "$MUTATOR_RC" 'falha explícita do define de rollback TRIM'
assert_discard unmap || fail 'falha do rollback TRIM não deixou XML divergente'
assert_text "$MUTATOR_ERROR" 'ROLLBACK XML NÃO COMPROVADO' 'falha do rollback TRIM sem erro grave'
assert_text "$MUTATOR_ERROR" 'Recuperação manual necessária' 'falha do rollback sem instrução de recuperação'
pass

mutator_harness_reset
mutator_harness_run 70-trim-discard.sh ''
snapshot_observable "$MUTATOR_HARNESS_DIR/70-first.content" content
snapshot_observable "$MUTATOR_HARNESS_DIR/70-first.exact" exact
mutator_harness_clear_instrumentation
mutator_harness_run 70-trim-discard.sh ''
assert_eq 0 "$MUTATOR_RC" 'segunda execução etapa 70'
assert_eq 0 "$(mutator_harness_effect_count)" 'segunda execução TRIM não foi no-op'
snapshot_observable "$MUTATOR_HARNESS_DIR/70-second.content" content
snapshot_observable "$MUTATOR_HARNESS_DIR/70-second.exact" exact
assert_manifest_equal "$MUTATOR_HARNESS_DIR/70-first.content" "$MUTATOR_HARNESS_DIR/70-second.content" 'segunda execução TRIM mudou conteúdo'
assert_manifest_equal "$MUTATOR_HARNESS_DIR/70-first.exact" "$MUTATOR_HARNESS_DIR/70-second.exact" 'segunda execução TRIM mudou metadados/mtime'
pass
fi # matriz full da etapa 70

printf 'OK: caracterização I0 direta dos mutadores (%s; %d grupos de cenários)\n' "$I0_MUTATOR_MATRIX" "$CHECKS"
