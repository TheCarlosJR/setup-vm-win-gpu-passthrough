#!/bin/bash
# Testes puros dos ciclos de vida de sudo e restauração da GPU.
set -euo pipefail
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

falha() { echo "FALHA: $*" >&2; exit 1; }
TMPDIR_TESTE="$(mktemp -d)"
PIDS_LIMPEZA=()
limpar() {
    local pid
    for pid in "${PIDS_LIMPEZA[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    rm -rf -- "$TMPDIR_TESTE"
}
trap limpar EXIT

# Mesmo que um consumidor substitua o trap instalado por exigir_sudo, o loop
# precisa observar a morte do shell dono e parar antes da próxima renovação.
cat > "$TMPDIR_TESTE/dono-keepalive.sh" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
source "$1"
sudo() { return 0; }
sleep() { command sleep 0.03; }
exigir_sudo
printf '%s\n' "$SUDO_KEEPALIVE_PID" > "$2"
trap ':' EXIT INT TERM
SCRIPT
chmod +x "$TMPDIR_TESTE/dono-keepalive.sh"
bash "$TMPDIR_TESTE/dono-keepalive.sh" "$RAIZ/lib/common.sh" "$TMPDIR_TESTE/keepalive.pid"
KEEPALIVE_PID="$(cat "$TMPDIR_TESTE/keepalive.pid")"
PIDS_LIMPEZA+=("$KEEPALIVE_PID")
for _ in $(seq 1 40); do
    if ! kill -0 "$KEEPALIVE_PID" 2>/dev/null; then
        KEEPALIVE_PID=""
        break
    fi
    sleep 0.03
done
[ -z "$KEEPALIVE_PID" ] || falha "keepalive sobreviveu ao shell dono após o trap ser substituído"
PIDS_LIMPEZA=()

# Renderiza o hook em uma cópia temporária do projeto. Os mocks fazem
# nvidia_uvm falhar e deixam os drivers ausentes; ainda assim o release precisa
# tentar nvidia-smi e reiniciar o display manager, preservar o state e sair 1.
PROJETO_TESTE="$TMPDIR_TESTE/projeto"
RENDER="$TMPDIR_TESTE/render"
BIN="$TMPDIR_TESTE/bin"
mkdir -p "$PROJETO_TESTE/lib" "$PROJETO_TESTE/etapas" "$RENDER" "$BIN" "$TMPDIR_TESTE/state"
cp "$RAIZ/lib/common.sh" "$PROJETO_TESTE/lib/common.sh"
cp "$RAIZ/etapas/50-hooks-gpu-hd1.sh" "$PROJETO_TESTE/etapas/50-hooks-gpu-hd1.sh"
cat > "$PROJETO_TESTE/passthrough.conf" <<'CONF'
VM_NAME="fixture"
GPU_PCI_ID="0000:01:00.0"
GPU_AUDIO_PCI_ID=""
GPU_VENDOR_DEVICE_ID="10de:2503"
GPU_AUDIO_VENDOR_DEVICE_ID=""
DM_SERVICE="display-manager"
IOMMU_GROUP_GPU="7"
HD1_BY_ID_PATH=""
HD1_DISPENSADO="sim"
CONF
bash "$PROJETO_TESTE/etapas/50-hooks-gpu-hd1.sh" --renderizar-hooks "$RENDER" >/dev/null
RELEASE="$RENDER/release.sh"
sed -i \
    -e "s|^PATH=.*|PATH=$BIN:/usr/bin:/bin|" \
    -e "s|^STATE_FILE=.*|STATE_FILE=$TMPDIR_TESTE/state/fixture.state|" \
    -e "s|^LOCK_DIR=.*|LOCK_DIR=$TMPDIR_TESTE/locks|" \
    "$RELEASE"
cat > "$TMPDIR_TESTE/state/fixture.state" <<'STATE'
DM_WAS_ACTIVE=1
GPU_DRIVER=nvidia
AUDIO_DRIVER=
HD1_ALVO=
HD1_DEVNO=
HD1_IDENTIDADE=
STATE
cat > "$BIN/install" <<'SCRIPT'
#!/bin/bash
mkdir -p -- "${!#}"
SCRIPT
cat > "$BIN/modprobe" <<'SCRIPT'
#!/bin/bash
echo "modprobe $*" >> "$HOOK_LOG"
[ "$1" != nvidia_uvm ]
SCRIPT
cat > "$BIN/systemctl" <<'SCRIPT'
#!/bin/bash
echo "systemctl $*" >> "$HOOK_LOG"
[ "${1:-}" != show ] || echo inactive
exit 0
SCRIPT
cat > "$BIN/nvidia-smi" <<'SCRIPT'
#!/bin/bash
echo nvidia-smi >> "$HOOK_LOG"
exit 0
SCRIPT
for cmd in chown flock sleep; do
    printf '%s\n' '#!/bin/bash' 'exit 0' > "$BIN/$cmd"
done
cat > "$BIN/stat" <<'SCRIPT'
#!/bin/bash
echo 0
SCRIPT
chmod +x "$BIN"/*
export HOOK_LOG="$TMPDIR_TESTE/hook.log"
: > "$HOOK_LOG"
set +e
bash "$RELEASE" >/dev/null 2>&1
RELEASE_RC=$?
set -e
[ "$RELEASE_RC" -ne 0 ] || falha "release declarou sucesso apesar das falhas simuladas"
grep -q '^modprobe nvidia_uvm$' "$HOOK_LOG" || falha "falha de nvidia_uvm não foi exercitada"
grep -q '^nvidia-smi$' "$HOOK_LOG" || falha "release não continuou até nvidia-smi"
grep -q '^systemctl start display-manager$' "$HOOK_LOG" || falha "release não tentou restaurar o display manager"
[ -f "$TMPDIR_TESTE/state/fixture.state" ] || falha "release incompleto removeu o state necessário à recuperação"

printf '%s\n' RUNTIME_LIFECYCLE_TESTS_OK
