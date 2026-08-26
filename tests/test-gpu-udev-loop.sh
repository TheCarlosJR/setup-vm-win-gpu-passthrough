#!/bin/bash
# Regressão D-GPU-UDEV-LOOP: as regras udev da NVIDIA rodam modprobe direto a
# cada evento em /bus/pci/drivers/nvidia. Com a GPU no vfio-pci esse modprobe
# se realimenta em laço, atravessa o release e derruba nvidia_drm com o desktop
# já aberto. Aqui provamos o filtro, o override de regras e a recusa do hook em
# subir o display manager sobre uma GPU instável.
set -euo pipefail
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

falha() { echo "FALHA: $*" >&2; exit 1; }
TMPDIR_TESTE="$(mktemp -d)"
trap 'rm -rf -- "$TMPDIR_TESTE"' EXIT

PROJETO="$TMPDIR_TESTE/projeto"
RENDER="$TMPDIR_TESTE/render"
BIN="$TMPDIR_TESTE/bin"
mkdir -p "$PROJETO/lib/shell" "$PROJETO/etapas" "$RENDER" "$BIN" "$TMPDIR_TESTE/state"
cp "$RAIZ/lib/common.sh" "$RAIZ/lib/platform.sh" "$RAIZ/lib/python-core.sh" "$PROJETO/lib/"
cp "$RAIZ/lib/shell/boot.sh" "$PROJETO/lib/shell/boot.sh"
cp -a "$RAIZ/libexec" "$PROJETO/libexec"
cp "$RAIZ/etapas/50-hooks-gpu-hd1.sh" "$PROJETO/etapas/50-hooks-gpu-hd1.sh"
cat > "$PROJETO/passthrough.conf" <<'CONF'
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
bash "$PROJETO/etapas/50-hooks-gpu-hd1.sh" --renderizar-hooks "$RENDER" >/dev/null

FILTRO="$RENDER/nvidia-udev-filtro.sh"
[ -x "$FILTRO" ] || falha "filtro de modprobe não foi renderizado"
bash -n "$FILTRO" || falha "filtro renderizado tem sintaxe inválida"

# --- 1. Override de regras: só o modprobe muda -------------------------------
ORIGEM=""
for candidato in /usr/lib/udev/rules.d/71-nvidia.rules /lib/udev/rules.d/71-nvidia.rules; do
    if [ -f "$candidato" ] && grep -q 'RUN+="/sbin/modprobe' "$candidato"; then
        ORIGEM="$candidato"
        break
    fi
done
if [ -n "$ORIGEM" ]; then
    REGRAS="$RENDER/nvidia.rules"
    [ -f "$REGRAS" ] || falha "override das regras udev não foi renderizado"
    grep -q 'RUN+="/sbin/modprobe' "$REGRAS" \
        && falha "override ainda dispara modprobe direto: o laço continua aberto"
    [ "$(grep -cF '/usr/local/sbin/vm-passthrough-nvidia-udev ' "$REGRAS")" \
        -eq "$(grep -cF 'RUN+="/sbin/modprobe' "$ORIGEM")" ] \
        || falha "número de regras filtradas diverge do original"
    # Sombrear o arquivo da distro só é seguro se nada além do modprobe mudar.
    diff <(grep -v 'RUN+="/sbin/modprobe' "$ORIGEM") \
         <(grep -vF '/usr/local/sbin/vm-passthrough-nvidia-udev ' "$REGRAS" | tail -n +5) \
        >/dev/null || falha "override alterou linhas que não são de modprobe"
    if command -v udevadm >/dev/null 2>&1; then
        udevadm verify "$REGRAS" >/dev/null 2>&1 \
            || falha "udev recusou a sintaxe do override gerado"
    fi
else
    echo "aviso: host sem 71-nvidia.rules da distro; parte 1 pulada" >&2
fi

# --- 2. Filtro decide pelo estado real do barramento -------------------------
cat > "$BIN/modprobe" <<'SCRIPT'
#!/bin/bash
echo "modprobe $*" >> "$MODPROBE_LOG"
SCRIPT
chmod +x "$BIN/modprobe"

montar_sysfs_falso() {
    # $1 = driver da GPU NVIDIA ("nvidia", "vfio-pci" ou "" para sem driver)
    local driver="$1" raiz="$TMPDIR_TESTE/sysfs"
    rm -rf -- "$raiz"
    mkdir -p "$raiz/0000:01:00.0" "$raiz/0000:00:1f.3" "$raiz/drivers/$driver"
    printf '0x10de\n' > "$raiz/0000:01:00.0/vendor"
    printf '0x030000\n' > "$raiz/0000:01:00.0/class"
    # Placa de som Intel no mesmo barramento: nunca pode influenciar a decisão.
    printf '0x8086\n' > "$raiz/0000:00:1f.3/vendor"
    printf '0x040300\n' > "$raiz/0000:00:1f.3/class"
    [ -z "$driver" ] || ln -s "$raiz/drivers/$driver" "$raiz/0000:01:00.0/driver"
    printf '%s\n' "$raiz"
}

executar_filtro() {
    # $1 = driver simulado; $2... = argumentos do filtro
    local driver="$1" raiz copia
    shift
    raiz="$(montar_sysfs_falso "$driver")"
    copia="$TMPDIR_TESTE/filtro-sob-teste.sh"
    sed -e "s|^PATH=.*|PATH=$BIN:/usr/bin:/bin|" \
        -e "s|/sys/bus/pci/devices/\*|$raiz/*|" \
        "$FILTRO" > "$copia"
    chmod +x "$copia"
    export MODPROBE_LOG="$TMPDIR_TESTE/modprobe.log"
    : > "$MODPROBE_LOG"
    "$copia" "$@" || true
    cat "$MODPROBE_LOG"
}

# Janela vfio: a VM é dona da GPU e nenhum modprobe pode acontecer. É este caso
# que gerava 1738 recargas de nvidia em um único boot.
[ -z "$(executar_filtro vfio-pci load nvidia-modeset)" ] \
    || falha "filtro carregou módulo com a GPU no vfio-pci: o laço continua"
[ -z "$(executar_filtro vfio-pci unload nvidia-drm)" ] \
    || falha "filtro descarregou módulo com a GPU no vfio-pci"

# GPU viva no host: carregar segue permitido (é assim que o boot ganha KMS),
# descarregar não, porque mataria a sessão gráfica em uso.
[ "$(executar_filtro nvidia load nvidia-modeset)" = "modprobe -- nvidia-modeset" ] \
    || falha "filtro bloqueou o carregamento legítimo com a GPU no nvidia"
[ -z "$(executar_filtro nvidia unload nvidia-drm)" ] \
    || falha "filtro descarregou nvidia_drm com a GPU viva no nvidia"

# Sem driver: é a limpeza legítima (pacote removido, GPU ausente).
[ "$(executar_filtro '' unload nvidia-uvm)" = "modprobe -r -- nvidia-uvm" ] \
    || falha "filtro impediu a limpeza legítima sem GPU vinculada"
[ "$(executar_filtro '' load nvidia-drm)" = "modprobe -- nvidia-drm" ] \
    || falha "filtro bloqueou carregamento sem GPU vinculada"

# Entrada fora do contrato nunca vira modprobe.
[ -z "$(executar_filtro nvidia load modulo-arbitrario)" ] \
    || falha "filtro aceitou módulo fora da lista"
[ -z "$(executar_filtro nvidia acao-invalida nvidia-drm)" ] \
    || falha "filtro aceitou ação fora do contrato"

# --- 3. Release não sobe o desktop sobre GPU instável ------------------------
cat > "$BIN/install" <<'SCRIPT'
#!/bin/bash
mkdir -p -- "${!#}"
SCRIPT
cat > "$BIN/systemctl" <<'SCRIPT'
#!/bin/bash
echo "systemctl $*" >> "$HOOK_LOG"
[ "${1:-}" != show ] || echo inactive
exit 0
SCRIPT
cat > "$BIN/nvidia-smi" <<'SCRIPT'
#!/bin/bash
exit 0
SCRIPT
cat > "$BIN/stat" <<'SCRIPT'
#!/bin/bash
echo 0
SCRIPT
for cmd in chown flock sleep udevadm timeout; do
    printf '%s\n' '#!/bin/bash' 'exit 0' > "$BIN/$cmd"
done
printf '%s\n' '#!/bin/bash' 'exit 0' > "$BIN/modprobe-ok"
chmod +x "$BIN"/*

preparar_release() {
    # $1 = 1 quando os módulos nvidia devem permanecer presentes (GPU estável)
    local estavel="$1" sysfs="$TMPDIR_TESTE/rel-sysfs" modulos="$TMPDIR_TESTE/rel-modulos"
    rm -rf -- "$sysfs" "$modulos"
    mkdir -p "$sysfs/0000:01:00.0/drm/card0" "$sysfs/drivers/nvidia" "$modulos"
    ln -s "$sysfs/drivers/nvidia" "$sysfs/0000:01:00.0/driver"
    if [ "$estavel" -eq 1 ]; then
        mkdir -p "$modulos/nvidia_drm" "$modulos/nvidia_modeset"
    fi
    cat > "$TMPDIR_TESTE/state/fixture.state" <<'STATE'
DM_WAS_ACTIVE=1
GPU_DRIVER=nvidia
AUDIO_DRIVER=
HD1_ALVO=
HD1_DEVNO=
HD1_IDENTIDADE=
HD1_FINGERPRINT=
STATE
    sed -e "s|^PATH=.*|PATH=$BIN:/usr/bin:/bin|" \
        -e "s|^STATE_FILE=.*|STATE_FILE=$TMPDIR_TESTE/state/fixture.state|" \
        -e "s|^LOCK_DIR=.*|LOCK_DIR=$TMPDIR_TESTE/locks|" \
        -e "s|/sys/bus/pci/devices|$sysfs|g" \
        -e "s|/sys/module|$modulos|g" \
        "$RENDER/release.sh" > "$TMPDIR_TESTE/release-sob-teste.sh"
    printf '%s\n' '#!/bin/bash' 'exit 0' > "$BIN/modprobe"
    chmod +x "$BIN/modprobe"
    export HOOK_LOG="$TMPDIR_TESTE/hook.log"
    : > "$HOOK_LOG"
}

preparar_release 0
set +e
bash "$TMPDIR_TESTE/release-sob-teste.sh" >/dev/null 2>"$TMPDIR_TESTE/release-instavel.err"
RC_INSTAVEL=$?
set -e
[ "$RC_INSTAVEL" -ne 0 ] || falha "release declarou sucesso com a GPU recarregando em laço"
grep -q '^systemctl start display-manager$' "$HOOK_LOG" \
    && falha "release subiu o display manager sobre uma GPU instável: é o congelamento que a etapa deve evitar"
grep -q 'recarregados em laço' "$TMPDIR_TESTE/release-instavel.err" \
    || falha "release não diagnosticou o laço de recarga"
[ -f "$TMPDIR_TESTE/state/fixture.state" ] \
    || falha "release instável removeu o state necessário à recuperação"

preparar_release 1
set +e
bash "$TMPDIR_TESTE/release-sob-teste.sh" >/dev/null 2>&1
RC_ESTAVEL=$?
set -e
[ "$RC_ESTAVEL" -eq 0 ] || falha "release falhou mesmo com a GPU estável (rc=$RC_ESTAVEL)"
grep -q '^systemctl start display-manager$' "$HOOK_LOG" \
    || falha "release não restaurou o desktop com a GPU estável"
[ ! -f "$TMPDIR_TESTE/state/fixture.state" ] \
    || falha "release bem-sucedido não removeu o state"

printf '%s\n' GPU_UDEV_LOOP_TESTS_OK
