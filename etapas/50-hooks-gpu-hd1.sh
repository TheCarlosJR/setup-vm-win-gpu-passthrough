#!/bin/bash
# ============================================================================
# etapas/50-hooks-gpu-hd1.sh - Capítulo 19: GPU Passthrough Dinâmico + HD1
# ============================================================================
# Instala hooks transacionais para transferir a GPU única entre Linux e VFIO,
# anexa vídeo/áudio ao XML e entrega o HD1 físico à VM. O hook é o único dono
# da troca de driver; por isso os hostdevs usam managed='no'.
#
# Flags opcionais:
#   --remover-video   remove QXL/SPICE somente após o passthrough ser validado
#   --anti-code43     aplica ocultação opcional descrita no Capítulo 28
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

HOOK_QEMU="/etc/libvirt/hooks/qemu"
MARCADOR_DISPATCHER="# Managed by popos-win11-passthrough: qemu dispatcher"
MARCADOR_HOOK="# Managed by popos-win11-passthrough: GPU handoff"

hook_prepare_path() {
    printf '/etc/libvirt/hooks/qemu.d/%s/prepare/begin/01-gpu-para-vfio.sh\n' "$1"
}

hook_release_path() {
    printf '/etc/libvirt/hooks/qemu.d/%s/release/end/01-gpu-para-linux.sh\n' "$1"
}

arquivo_gerenciado() {
    local arquivo="$1" marcador="$2"
    [ -f "$arquivo" ] && grep -qF "$marcador" "$arquivo" 2>/dev/null
}

arquivo_root_seguro() {
    local arquivo="$1" modo
    [ -f "$arquivo" ] && [ ! -L "$arquivo" ] || return 1
    [ "$(stat -c %u "$arquivo" 2>/dev/null)" = "0" ] || return 1
    [ "$(stat -c %g "$arquivo" 2>/dev/null)" = "0" ] || return 1
    modo="$(stat -c %a "$arquivo" 2>/dev/null)" || return 1
    (( (8#$modo & 022) == 0 ))
}

validar_dispositivos_gpu() {
    local video="${GPU_PCI_ID:-}" audio="${GPU_AUDIO_PCI_ID:-}"
    local video_id="${GPU_VENDOR_DEVICE_ID:-}" audio_id="${GPU_AUDIO_VENDOR_DEVICE_ID:-}"
    local esperado_vendor esperado_device atual_vendor atual_device classe_video classe_audio
    local grupo_video grupo_audio

    [[ "$video" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]] || return 1
    [[ "$audio" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]] || return 1
    [ "$video" != "$audio" ] || return 1
    [[ "$video_id" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]] || return 1
    [[ "$audio_id" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]] || return 1

    [ -d "/sys/bus/pci/devices/$video" ] && [ -d "/sys/bus/pci/devices/$audio" ] || return 1
    IFS=: read -r esperado_vendor esperado_device <<< "$video_id"
    atual_vendor="$(<"/sys/bus/pci/devices/$video/vendor")"
    atual_device="$(<"/sys/bus/pci/devices/$video/device")"
    [ "${atual_vendor#0x}" = "${esperado_vendor,,}" ] \
        && [ "${atual_device#0x}" = "${esperado_device,,}" ] || return 1
    IFS=: read -r esperado_vendor esperado_device <<< "$audio_id"
    atual_vendor="$(<"/sys/bus/pci/devices/$audio/vendor")"
    atual_device="$(<"/sys/bus/pci/devices/$audio/device")"
    [ "${atual_vendor#0x}" = "${esperado_vendor,,}" ] \
        && [ "${atual_device#0x}" = "${esperado_device,,}" ] || return 1

    classe_video="$(<"/sys/bus/pci/devices/$video/class")"
    classe_audio="$(<"/sys/bus/pci/devices/$audio/class")"
    [[ "${classe_video#0x}" =~ ^03(00|02) ]] || return 1
    [[ "${classe_audio#0x}" =~ ^0403 ]] || return 1
    [ -e "/sys/bus/pci/devices/$video/iommu_group" ] \
        && [ -e "/sys/bus/pci/devices/$audio/iommu_group" ] || return 1
    grupo_video="$(readlink -f "/sys/bus/pci/devices/$video/iommu_group")" || return 1
    grupo_audio="$(readlink -f "/sys/bus/pci/devices/$audio/iommu_group")" || return 1
    [ -n "$grupo_video" ] && [ -n "$grupo_audio" ] \
        && [ "$grupo_video" = "$grupo_audio" ]
}

bdf_partes() {
    local endereco="$1"
    IFS=':.' read -r BDF_DOM BDF_BUS BDF_SLOT BDF_FUNC <<< "$endereco"
    [ -n "$BDF_DOM" ] && [ -n "$BDF_BUS" ] && [ -n "$BDF_SLOT" ] && [ -n "$BDF_FUNC" ]
}

hostdev_count() {
    local xml="$1" endereco="$2"
    bdf_partes "$endereco" || return 1
    xmlstarlet sel -t -v \
        "count(/domain/devices/hostdev[@type='pci' and @mode='subsystem' and @managed='no' and source/address[@domain='0x$BDF_DOM' and @bus='0x$BDF_BUS' and @slot='0x$BDF_SLOT' and @function='0x$BDF_FUNC']])" \
        "$xml" 2>/dev/null
}

disk_source_count() {
    local xml="$1" caminho="$2"
    xmlstarlet sel -t -v "count(/domain/devices/disk/source[@dev=\"$caminho\"])" \
        "$xml" 2>/dev/null
}

disk_metadata_count() {
    local xml="$1" caminho="$2"
    xmlstarlet sel -t -v \
        "count(/domain/devices/disk[@type='block' and @device='disk' and @snapshot='no' and driver[@name='qemu' and @type='raw' and @cache='none' and @io='native'] and source[@dev=\"$caminho\"] and target[@dev='vdb' and @bus='virtio']])" \
        "$xml" 2>/dev/null
}

disk_target_count() {
    local xml="$1" target="$2"
    xmlstarlet sel -t -v "count(/domain/devices/disk/target[@dev=\"$target\"])" \
        "$xml" 2>/dev/null
}

disk_overlap_count() {
    local xml="$1" caminho="$2" alvo_id fontes fonte ancestrais no no_id total=0 conflito
    [ -b "$caminho" ] || { printf '0\n'; return 1; }
    alvo_id="$(stat -Lc '%t:%T' -- "$caminho" 2>/dev/null)" \
        || { printf '0\n'; return 1; }
    fontes="$(xmlstarlet sel -t -m '/domain/devices/disk/source[@dev]' -v '@dev' -n "$xml" 2>/dev/null)" \
        || { printf '0\n'; return 1; }
    while IFS= read -r fonte; do
        [ -n "$fonte" ] && [ -b "$fonte" ] || continue
        ancestrais="$(lsblk -snrpo NAME "$fonte" 2>/dev/null)" \
            || { printf '0\n'; return 1; }
        conflito=0
        while IFS= read -r no; do
            [ -n "$no" ] || continue
            no_id="$(stat -Lc '%t:%T' -- "$no" 2>/dev/null)" \
                || { printf '0\n'; return 1; }
            if [ "$no_id" = "$alvo_id" ]; then
                conflito=1
                break
            fi
        done <<< "$ancestrais"
        [ "$conflito" -eq 0 ] || total=$((total + 1))
    done <<< "$fontes"
    printf '%s\n' "$total"
}

validar_hd1_host() {
    local lista bloco nome
    [ -L "${HD1_BY_ID_PATH:-}" ] || return 1
    [[ "$HD1_BY_ID_PATH" == /dev/disk/by-id/* ]] || return 1
    HD1_ALVO="$(readlink -f "$HD1_BY_ID_PATH")" || return 1
    [ -b "$HD1_ALVO" ] || return 1
    [ "$(lsblk -dnro TYPE "$HD1_ALVO" 2>/dev/null)" = "disk" ] || return 1
    lista="$(lsblk -nrpo NAME "$HD1_ALVO")" || return 1
    [ -n "$lista" ] || return 1
    while IFS= read -r bloco; do
        [ -n "$bloco" ] || continue
        nome="$(basename -- "$bloco")"
        if findmnt -rn -S "$bloco" >/dev/null 2>&1 \
            || awk -v dev="$bloco" 'NR > 1 && $1 == dev { encontrado=1 } END { exit !encontrado }' /proc/swaps \
            || compgen -G "/sys/class/block/$nome/holders/*" >/dev/null; then
            erro "HD1 ou partição filha está montada, em swap ou possui holder ativo: $bloco"
            return 1
        fi
    done <<< "$lista"
}

verificar() {
    [ -n "${VM_NAME:-}" ] || { v_falta "VM_NAME não definido."; v_fim; }
    local prep rel xml_tmp gpu_id audio_id
    prep="$(hook_prepare_path "$VM_NAME")"
    rel="$(hook_release_path "$VM_NAME")"
    gpu_id="${GPU_VENDOR_DEVICE_ID:-__ausente__}"; gpu_id="${gpu_id,,}"
    audio_id="${GPU_AUDIO_VENDOR_DEVICE_ID:-__ausente__}"; audio_id="${audio_id,,}"

    if [ -x "$HOOK_QEMU" ] \
        && arquivo_root_seguro "$HOOK_QEMU" \
        && arquivo_gerenciado "$HOOK_QEMU" "$MARCADOR_DISPATCHER" \
        && bash -n "$HOOK_QEMU" >/dev/null 2>&1 \
        && grep -qF '"$script" "$@" || {' "$HOOK_QEMU" \
        && grep -qF 'exit "$status"' "$HOOK_QEMU"; then
        v_ok "Dispatcher seguro, válido e com propagação de falha."
    else
        v_falta "Dispatcher ausente, inseguro ou sem propagação de falha."
    fi

    if [ -x "$prep" ] \
        && arquivo_root_seguro "$prep" \
        && arquivo_gerenciado "$prep" "$MARCADOR_HOOK" \
        && bash -n "$prep" >/dev/null 2>&1 \
        && grep -qF "GPU_PCI=\"${GPU_PCI_ID:-__ausente__}\"" "$prep" \
        && grep -qF "GPU_AUDIO_PCI=\"${GPU_AUDIO_PCI_ID:-__ausente__}\"" "$prep" \
        && grep -qF "GPU_ID=\"$gpu_id\"" "$prep" \
        && grep -qF "GPU_AUDIO_ID=\"$audio_id\"" "$prep" \
        && grep -qF "HD1_PATH=\"${HD1_BY_ID_PATH:-__ausente__}\"" "$prep" \
        && grep -qF "DM_SERVICE=\"${DM_SERVICE:-__ausente__}\"" "$prep" \
        && grep -qF 'gpu_pair_matches' "$prep" \
        && grep -qF 'flock -w 30 9 ||' "$prep" \
        && grep -qF '[ "$LOCK_ACQUIRED" -eq 1 ]' "$prep" \
        && grep -qF '[ "$HANDOFF_STARTED" -eq 1 ]' "$prep" \
        && grep -qF 'driver_override' "$prep" \
        && grep -qF 'drivers_probe' "$prep"; then
        v_ok "Hook prepare seguro e correspondente à configuração."
    else
        v_falta "Hook prepare ausente, inseguro, inválido ou divergente."
    fi

    if [ -x "$rel" ] \
        && arquivo_root_seguro "$rel" \
        && arquivo_gerenciado "$rel" "$MARCADOR_HOOK" \
        && bash -n "$rel" >/dev/null 2>&1 \
        && grep -qF "GPU_PCI=\"${GPU_PCI_ID:-__ausente__}\"" "$rel" \
        && grep -qF "GPU_AUDIO_PCI=\"${GPU_AUDIO_PCI_ID:-__ausente__}\"" "$rel" \
        && grep -qF "GPU_ID=\"$gpu_id\"" "$rel" \
        && grep -qF "GPU_AUDIO_ID=\"$audio_id\"" "$rel" \
        && grep -qF "DM_SERVICE=\"${DM_SERVICE:-__ausente__}\"" "$rel" \
        && grep -qF 'gpu_pair_matches' "$rel" \
        && grep -qF 'flock -w 30 9 ||' "$rel" \
        && grep -qF '[ "$LOCK_ACQUIRED" -eq 1 ]' "$rel" \
        && grep -qF '[ "$RESTORE_STARTED" -eq 1 ]' "$rel" \
        && grep -qF 'driver_override' "$rel" \
        && grep -qF 'drivers_probe' "$rel"; then
        v_ok "Hook release seguro e correspondente à configuração."
    else
        v_falta "Hook release ausente, inseguro, inválido ou divergente."
    fi

    if validar_dispositivos_gpu; then
        v_ok "BDFs, IDs, classes e grupo IOMMU correspondem ao hardware."
    else
        v_falta "GPU/áudio configurados não correspondem ao hardware atual."
    fi
    if validar_hd1_host; then
        v_ok "HD1 é disco inteiro e está sem mount, swap ou holders no host."
    else
        v_falta "HD1 ausente, sobreposto ou atualmente em uso pelo host."
    fi

    if vm_existe "$VM_NAME"; then
        xml_tmp="$(mktemp)"
        if $VIRSH dumpxml --inactive "$VM_NAME" > "$xml_tmp" 2>/dev/null \
            && xmlstarlet val -q "$xml_tmp"; then
            if [ -n "${HD1_BY_ID_PATH:-}" ] \
                && [ "$(disk_metadata_count "$xml_tmp" "$HD1_BY_ID_PATH" 2>/dev/null || true)" = "1" ] \
                && [ "$(disk_overlap_count "$xml_tmp" "$HD1_BY_ID_PATH" 2>/dev/null || true)" = "1" ]; then
                v_ok "HD1 possui identidade física única e todos os metadados seguros no XML."
            else
                v_falta "HD1 ausente, sobreposto, duplicado ou com metadados divergentes no XML."
            fi

            local endereco count
            for endereco in "${GPU_PCI_ID:-}" "${GPU_AUDIO_PCI_ID:-}"; do
                count="$(hostdev_count "$xml_tmp" "$endereco" 2>/dev/null || true)"
                if [ "$count" = "1" ]; then
                    v_ok "hostdev $endereco managed='no' presente exatamente uma vez no XML."
                else
                    v_falta "hostdev $endereco ausente, duplicado ou com metadados divergentes."
                fi
            done
        else
            v_falta "Não foi possível ler e validar o XML inativo da VM."
        fi
        rm -f "$xml_tmp"
    else
        v_falta "VM '$VM_NAME' não existe."
    fi
    v_fim
}
if [ "${1:-}" = "--verificar" ]; then
    [ "$#" -eq 1 ] || falhar "--verificar não aceita outras opções."
    verificar
fi

REMOVER_VIDEO=0
ANTI_CODE43=0
for ARG in "$@"; do
    case "$ARG" in
        --remover-video) REMOVER_VIDEO=1 ;;
        --anti-code43) ANTI_CODE43=1 ;;
        *) falhar "Opção desconhecida: $ARG" ;;
    esac
done

exigir_nao_root
exigir_sudo
exigir_comando xmlstarlet virsh flock findmnt lsblk
exigir_conf VM_NAME GPU_PCI_ID GPU_AUDIO_PCI_ID GPU_VENDOR_DEVICE_ID \
            GPU_AUDIO_VENDOR_DEVICE_ID HD1_BY_ID_PATH DM_SERVICE
[[ "$VM_NAME" =~ ^[A-Za-z0-9_.-]+$ ]] \
    || falhar "VM_NAME contém caracteres inseguros."
[[ "$DM_SERVICE" =~ ^[A-Za-z0-9_.@-]+$ ]] \
    || falhar "DM_SERVICE contém caracteres inseguros."
[[ "$HD1_BY_ID_PATH" =~ ^/dev/disk/by-id/[A-Za-z0-9._:+@=-]+$ ]] \
    || falhar "HD1_BY_ID_PATH contém caracteres não aceitos no hook privilegiado."
exigir_vm_desligada "$VM_NAME"
validar_dispositivos_gpu \
    || falhar "GPU/áudio configurados não correspondem aos IDs, classes ou grupo IOMMU do hardware atual."

titulo "Capítulo 19: hooks dinâmicos e HD1 físico (VM: $VM_NAME)"

PREPARE="$(hook_prepare_path "$VM_NAME")"
RELEASE="$(hook_release_path "$VM_NAME")"

validar_hd1_host \
    || falhar "HD1 deve ser disco inteiro by-id e não pode estar montado nem em swap no host."

# Não sobrescreve integrações de terceiros nem hooks manuais.
for ITEM in "$HOOK_QEMU:$MARCADOR_DISPATCHER" "$PREPARE:$MARCADOR_HOOK" "$RELEASE:$MARCADOR_HOOK"; do
    ARQUIVO="${ITEM%%:*}"
    MARCADOR="${ITEM#*:}"
    if sudo test -L "$ARQUIVO"; then
        falhar "Link simbólico não é aceito para hook privilegiado: $ARQUIVO"
    fi
    if sudo test -e "$ARQUIVO" && ! sudo grep -qF "$MARCADOR" "$ARQUIVO"; then
        falhar "Arquivo externo já existe em $ARQUIVO. Integre-o manualmente; nada foi sobrescrito."
    fi
done

id -nG | grep -qw libvirt \
    || falhar "A sessão atual ainda não possui o grupo libvirt; faça logout/login após a etapa 21."
GPU_LOCK_FILE="/run/lock/vm-passthrough-gpu.lock"
sudo touch "$GPU_LOCK_FILE"
sudo chown root:libvirt "$GPU_LOCK_FILE"
sudo chmod 0660 "$GPU_LOCK_FILE"
exec 8>"$GPU_LOCK_FILE"
flock -w 30 8 \
    || falhar "Outra instalação ou troca de GPU está em andamento."

VMS_ATIVAS_SAIDA="$($VIRSH list --name)" \
    || falhar "Não foi possível consultar as VMs ativas antes de publicar os hooks."
VMS_ATIVAS=()
while IFS= read -r VM_ATIVA; do
    [ -z "$VM_ATIVA" ] || VMS_ATIVAS+=("$VM_ATIVA")
done <<< "$VMS_ATIVAS_SAIDA"
[ "${#VMS_ATIVAS[@]}" -eq 0 ] \
    || falhar "Há outra(s) VM(s) ativa(s): ${VMS_ATIVAS[*]}. Desligue-as antes de reiniciar o libvirt."

TMP_HOOKS="$(mktemp -d)"
trap 'rm -rf "${TMP_HOOKS:-}"' EXIT
DISPATCHER_TMP="$TMP_HOOKS/qemu"
PREPARE_TMP="$TMP_HOOKS/prepare.sh"
RELEASE_TMP="$TMP_HOOKS/release.sh"

cat > "$DISPATCHER_TMP" <<'DISPATCHER'
#!/bin/bash
# Managed by popos-win11-passthrough: qemu dispatcher
# Propaga ao libvirt qualquer falha de um hook filho.
set -uo pipefail

VM_NAME="${1:?nome da VM ausente}"
EVENTO="${2:?evento ausente}"
SUBEVENTO="${3:?subevento ausente}"
DIRETORIO_HOOK="/etc/libvirt/hooks/qemu.d/${VM_NAME}/${EVENTO}/${SUBEVENTO}"

[ -d "$DIRETORIO_HOOK" ] || exit 0
shopt -s nullglob
for script in "$DIRETORIO_HOOK"/*; do
    [ -x "$script" ] || continue
    "$script" "$@" || {
        status=$?
        echo "[dispatcher] Hook falhou ($status): $script" >&2
        exit "$status"
    }
done
exit 0
DISPATCHER

cat > "$PREPARE_TMP" <<'HOOK_PREPARE'
#!/bin/bash
# Managed by popos-win11-passthrough: GPU handoff
# Transfere GPU, áudio e o HD1 ao vfio-pci/QEMU antes de iniciar a VM.
set -euo pipefail

GPU_PCI="@GPU_PCI@"
GPU_AUDIO_PCI="@GPU_AUDIO_PCI@"
GPU_ID="@GPU_ID@"
GPU_AUDIO_ID="@GPU_AUDIO_ID@"
HD1_PATH="@HD1_PATH@"
DM_SERVICE="@DM_SERVICE@"
VM_NAME="${1:-@VM_NAME@}"
LOCK_FILE="/run/lock/vm-passthrough-gpu.lock"
STATE_DIR="/run/vm-passthrough/${VM_NAME}"
LOCK_ACQUIRED=0
HANDOFF_STARTED=0
PREPARE_COMPLETE=0

current_driver() {
    local bdf="$1"
    if [ -L "/sys/bus/pci/devices/$bdf/driver" ]; then
        basename "$(readlink -f "/sys/bus/pci/devices/$bdf/driver")"
    else
        printf 'none\n'
    fi
}

device_matches() {
    local bdf="$1" expected_id="$2" kind="$3" vendor device class
    [ -d "/sys/bus/pci/devices/$bdf" ] || return 1
    vendor="$(<"/sys/bus/pci/devices/$bdf/vendor")" || return 1
    device="$(<"/sys/bus/pci/devices/$bdf/device")" || return 1
    class="$(<"/sys/bus/pci/devices/$bdf/class")" || return 1
    [ "${vendor#0x}:${device#0x}" = "${expected_id,,}" ] || return 1
    if [ "$kind" = "video" ]; then
        [[ "${class#0x}" =~ ^03(00|02) ]]
    else
        [[ "${class#0x}" =~ ^0403 ]]
    fi
}

gpu_pair_matches() {
    local video_group audio_group
    device_matches "$GPU_PCI" "$GPU_ID" video || return 1
    device_matches "$GPU_AUDIO_PCI" "$GPU_AUDIO_ID" audio || return 1
    video_group="$(readlink -f "/sys/bus/pci/devices/$GPU_PCI/iommu_group")" || return 1
    audio_group="$(readlink -f "/sys/bus/pci/devices/$GPU_AUDIO_PCI/iommu_group")" || return 1
    [ -n "$video_group" ] && [ "$video_group" = "$audio_group" ]
}

unbind_current() {
    local bdf="$1" driver
    driver="$(current_driver "$bdf")"
    [ "$driver" = "none" ] || printf '%s' "$bdf" > "/sys/bus/pci/devices/$bdf/driver/unbind"
}

probe_device() {
    printf '%s' "$1" > /sys/bus/pci/drivers_probe
}

hd1_is_exclusive() {
    local target list block name
    [ -L "$HD1_PATH" ] && [[ "$HD1_PATH" == /dev/disk/by-id/* ]] || return 1
    target="$(readlink -f "$HD1_PATH")" || return 1
    [ -b "$target" ] && [ "$(lsblk -dnro TYPE "$target")" = "disk" ] || return 1
    list="$(lsblk -nrpo NAME "$target")" || return 1
    [ -n "$list" ] || return 1
    while IFS= read -r block; do
        [ -n "$block" ] || continue
        name="$(basename -- "$block")"
        findmnt -rn -S "$block" >/dev/null 2>&1 && return 1
        awk -v dev="$block" 'NR > 1 && $1 == dev { found=1 } END { exit !found }' /proc/swaps && return 1
        compgen -G "/sys/class/block/$name/holders/*" >/dev/null && return 1
    done <<< "$list"
}

rollback_linux() {
    local failed=0 bdf module dm_state
    set +e
    echo "[hook] Prepare incompleto; restaurando a GPU ao Linux." >&2
    for bdf in "$GPU_PCI" "$GPU_AUDIO_PCI"; do
        [ -d "/sys/bus/pci/devices/$bdf" ] || { failed=1; continue; }
        if [ "$(current_driver "$bdf")" = "vfio-pci" ]; then
            printf '%s' "$bdf" > "/sys/bus/pci/devices/$bdf/driver/unbind" || failed=1
        fi
        printf '\n' > "/sys/bus/pci/devices/$bdf/driver_override" || failed=1
    done
    for module in nvidia nvidia_modeset nvidia_drm nvidia_uvm snd_hda_intel; do
        modprobe "$module" || failed=1
    done
    for bdf in "$GPU_PCI" "$GPU_AUDIO_PCI"; do
        [ -d "/sys/bus/pci/devices/$bdf" ] || continue
        [ "$(current_driver "$bdf")" != "none" ] || probe_device "$bdf" || failed=1
    done
    [ "$(current_driver "$GPU_PCI")" = "nvidia" ] || failed=1
    [ "$(current_driver "$GPU_AUDIO_PCI")" = "snd_hda_intel" ] || failed=1
    dm_state="$(cat "$STATE_DIR/dm-was-active" 2>/dev/null)" \
        || { dm_state=unknown; failed=1; }
    case "$dm_state" in
        1) systemctl start "$DM_SERVICE" || failed=1 ;;
        0) ;;
        *) failed=1 ;;
    esac
    if [ "$failed" -eq 0 ]; then
        rm -rf "$STATE_DIR"
    else
        rm -f "$STATE_DIR/handoff-complete"
    fi
    return "$failed"
}

finish_prepare() {
    local status=$?
    trap - EXIT INT TERM
    if [ "$LOCK_ACQUIRED" -eq 1 ] \
        && [ "$HANDOFF_STARTED" -eq 1 ] \
        && [ "$PREPARE_COMPLETE" -ne 1 ]; then
        rollback_linux || status=1
    fi
    exit "$status"
}
trap finish_prepare EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

exec 9>"$LOCK_FILE"
flock -w 30 9 || { echo "[hook] Outra troca de GPU está em andamento." >&2; exit 1; }
LOCK_ACQUIRED=1

gpu_pair_matches \
    || { echo "[hook] Os BDFs não correspondem à GPU/áudio esperados." >&2; false; }
hd1_is_exclusive \
    || { echo "[hook] HD1 ausente, não exclusivo ou em uso no host: $HD1_PATH" >&2; false; }

if [ -f "$STATE_DIR/handoff-complete" ] \
    && [ "$(current_driver "$GPU_PCI")" = "vfio-pci" ] \
    && [ "$(current_driver "$GPU_AUDIO_PCI")" = "vfio-pci" ]; then
    PREPARE_COMPLETE=1
    echo "[hook] Handoff já estava concluído; mantendo o estado original."
    exit 0
fi

rm -rf "$STATE_DIR"
install -d -m 0700 "$STATE_DIR"
DM_STATE=""
if DM_STATE="$(systemctl is-active "$DM_SERVICE" 2>/dev/null)"; then
    [ "$DM_STATE" = "active" ] \
        || { echo "[hook] Estado inesperado do display manager: $DM_STATE" >&2; false; }
    DM_WAS_ACTIVE=1
else
    case "$DM_STATE" in
        inactive|failed) DM_WAS_ACTIVE=0 ;;
        *) echo "[hook] Não foi possível determinar o estado de $DM_SERVICE." >&2; false ;;
    esac
fi
printf '%s\n' "$DM_WAS_ACTIVE" > "$STATE_DIR/dm-was-active"
HANDOFF_STARTED=1

if [ "$DM_WAS_ACTIVE" -eq 1 ]; then
    systemctl stop "$DM_SERVICE"
fi
sleep 2

modprobe vfio-pci
for bdf in "$GPU_PCI" "$GPU_AUDIO_PCI"; do
    printf '%s' 'vfio-pci' > "/sys/bus/pci/devices/$bdf/driver_override"
    unbind_current "$bdf"
done

for module in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
    [ ! -d "/sys/module/$module" ] || modprobe -r "$module"
done

for bdf in "$GPU_PCI" "$GPU_AUDIO_PCI"; do
    probe_device "$bdf"
    [ "$(current_driver "$bdf")" = "vfio-pci" ] \
        || { echo "[hook] $bdf não vinculou ao vfio-pci." >&2; false; }
done

printf '1\n' > "$STATE_DIR/handoff-complete"
PREPARE_COMPLETE=1
echo "[hook] GPU e áudio vinculados ao vfio-pci."
HOOK_PREPARE

cat > "$RELEASE_TMP" <<'HOOK_RELEASE'
#!/bin/bash
# Managed by popos-win11-passthrough: GPU handoff
# Devolve GPU e áudio ao Linux depois que a VM encerra.
set -uo pipefail

GPU_PCI="@GPU_PCI@"
GPU_AUDIO_PCI="@GPU_AUDIO_PCI@"
GPU_ID="@GPU_ID@"
GPU_AUDIO_ID="@GPU_AUDIO_ID@"
DM_SERVICE="@DM_SERVICE@"
VM_NAME="${1:-@VM_NAME@}"
LOCK_FILE="/run/lock/vm-passthrough-gpu.lock"
STATE_DIR="/run/vm-passthrough/${VM_NAME}"
LOCK_ACQUIRED=0
RESTORE_STARTED=0
DM_WAS_ACTIVE=unknown
STATUS=0

current_driver() {
    local bdf="$1"
    if [ -L "/sys/bus/pci/devices/$bdf/driver" ]; then
        basename "$(readlink -f "/sys/bus/pci/devices/$bdf/driver")"
    else
        printf 'none\n'
    fi
}

device_matches() {
    local bdf="$1" expected_id="$2" kind="$3" vendor device class
    [ -d "/sys/bus/pci/devices/$bdf" ] || return 1
    vendor="$(<"/sys/bus/pci/devices/$bdf/vendor")" || return 1
    device="$(<"/sys/bus/pci/devices/$bdf/device")" || return 1
    class="$(<"/sys/bus/pci/devices/$bdf/class")" || return 1
    [ "${vendor#0x}:${device#0x}" = "${expected_id,,}" ] || return 1
    if [ "$kind" = "video" ]; then
        [[ "${class#0x}" =~ ^03(00|02) ]]
    else
        [[ "${class#0x}" =~ ^0403 ]]
    fi
}

gpu_pair_matches() {
    local video_group audio_group
    device_matches "$GPU_PCI" "$GPU_ID" video || return 1
    device_matches "$GPU_AUDIO_PCI" "$GPU_AUDIO_ID" audio || return 1
    video_group="$(readlink -f "/sys/bus/pci/devices/$GPU_PCI/iommu_group")" || return 1
    audio_group="$(readlink -f "/sys/bus/pci/devices/$GPU_AUDIO_PCI/iommu_group")" || return 1
    [ -n "$video_group" ] && [ "$video_group" = "$audio_group" ]
}

finish_release() {
    local status=$?
    trap - EXIT INT TERM
    [ "$STATUS" -eq 0 ] || status="$STATUS"
    if [ "$LOCK_ACQUIRED" -eq 1 ] && [ "$RESTORE_STARTED" -eq 1 ]; then
        case "$DM_WAS_ACTIVE" in
            1) systemctl start "$DM_SERVICE" || status=1 ;;
            0) ;;
            *) status=1 ;;
        esac
        [ "$status" -ne 0 ] || rm -rf "$STATE_DIR"
    fi
    exit "$status"
}
trap finish_release EXIT
trap 'STATUS=1; exit 130' INT
trap 'STATUS=1; exit 143' TERM

exec 9>"$LOCK_FILE"
flock -w 30 9 || { echo "[hook] Outra troca de GPU está em andamento." >&2; STATUS=1; exit 1; }
LOCK_ACQUIRED=1
if ! gpu_pair_matches; then
    echo "[hook] Os BDFs não correspondem à GPU/áudio esperados; nada será alterado." >&2
    STATUS=1
    exit 1
fi
if ! DM_WAS_ACTIVE="$(cat "$STATE_DIR/dm-was-active" 2>/dev/null)"; then
    echo "[hook] Estado anterior do display manager indisponível; a GPU será restaurada sem iniciar o serviço." >&2
    DM_WAS_ACTIVE=unknown
    STATUS=1
elif [ "$DM_WAS_ACTIVE" != "0" ] && [ "$DM_WAS_ACTIVE" != "1" ]; then
    echo "[hook] Estado anterior inválido do display manager: $DM_WAS_ACTIVE" >&2
    DM_WAS_ACTIVE=unknown
    STATUS=1
fi
RESTORE_STARTED=1

for bdf in "$GPU_PCI" "$GPU_AUDIO_PCI"; do
    if [ "$(current_driver "$bdf")" = "vfio-pci" ]; then
        printf '%s' "$bdf" > "/sys/bus/pci/devices/$bdf/driver/unbind" \
            || { echo "[hook] Falha ao desvincular $bdf do VFIO." >&2; STATUS=1; }
    fi
    printf '\n' > "/sys/bus/pci/devices/$bdf/driver_override" \
        || { echo "[hook] Falha ao limpar override de $bdf." >&2; STATUS=1; }
done

for module in nvidia nvidia_modeset nvidia_drm nvidia_uvm snd_hda_intel; do
    modprobe "$module" || { echo "[hook] Falha ao carregar $module." >&2; STATUS=1; }
done

for bdf in "$GPU_PCI" "$GPU_AUDIO_PCI"; do
    if [ "$(current_driver "$bdf")" = "none" ]; then
        printf '%s' "$bdf" > /sys/bus/pci/drivers_probe \
            || { echo "[hook] Falha no probe de $bdf." >&2; STATUS=1; }
    fi
done

[ "$(current_driver "$GPU_PCI")" = "nvidia" ] \
    || { echo "[hook] A GPU não retornou ao driver nvidia." >&2; STATUS=1; }
[ "$(current_driver "$GPU_AUDIO_PCI")" = "snd_hda_intel" ] \
    || { echo "[hook] O áudio não retornou ao snd_hda_intel." >&2; STATUS=1; }
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi -L >/dev/null \
        || { echo "[hook] nvidia-smi não reconheceu a GPU restaurada." >&2; STATUS=1; }
fi

[ "$STATUS" -eq 0 ] && echo "[hook] GPU e áudio devolvidos ao Linux."
exit "$STATUS"
HOOK_RELEASE

renderizar_hook() {
    local arquivo="$1" conteudo
    conteudo="$(<"$arquivo")"
    conteudo="${conteudo//@GPU_PCI@/$GPU_PCI_ID}"
    conteudo="${conteudo//@GPU_AUDIO_PCI@/$GPU_AUDIO_PCI_ID}"
    conteudo="${conteudo//@GPU_ID@/${GPU_VENDOR_DEVICE_ID,,}}"
    conteudo="${conteudo//@GPU_AUDIO_ID@/${GPU_AUDIO_VENDOR_DEVICE_ID,,}}"
    conteudo="${conteudo//@HD1_PATH@/$HD1_BY_ID_PATH}"
    conteudo="${conteudo//@DM_SERVICE@/$DM_SERVICE}"
    conteudo="${conteudo//@VM_NAME@/$VM_NAME}"
    printf '%s\n' "$conteudo" > "$arquivo"
}
renderizar_hook "$PREPARE_TMP"
renderizar_hook "$RELEASE_TMP"

bash -n "$DISPATCHER_TMP"
bash -n "$PREPARE_TMP"
bash -n "$RELEASE_TMP"
if grep -qE '@[A-Z0-9_]+@' "$PREPARE_TMP" "$RELEASE_TMP"; then
    falhar "Sobrou token não substituído nos hooks gerados."
fi

mkdir -p "$BACKUPS_DIR"
BACKUP_HOOKS="$(mktemp -d "$BACKUPS_DIR/hooks-$(date +%Y%m%d-%H%M%S)-XXXXXX")"
QEMU_EXISTIA=0; PREPARE_EXISTIA=0; RELEASE_EXISTIA=0
if sudo test -e "$HOOK_QEMU"; then
    QEMU_EXISTIA=1; sudo cp -a -- "$HOOK_QEMU" "$BACKUP_HOOKS/qemu.bak"
fi
if sudo test -e "$PREPARE"; then
    PREPARE_EXISTIA=1; sudo cp -a -- "$PREPARE" "$BACKUP_HOOKS/prepare.bak"
fi
if sudo test -e "$RELEASE"; then
    RELEASE_EXISTIA=1; sudo cp -a -- "$RELEASE" "$BACKUP_HOOKS/release.bak"
fi

restaurar_hooks() {
    erro "Restaurando os hooks anteriores após falha da transação."
    sudo bash -c '
        set -uo pipefail
        failed=0
        restore_one() {
            local existed="$1" source="$2" destination="$3" staged="${destination}.restore.$$"
            rm -f -- "$staged" || return 1
            if [ "$existed" = "1" ]; then
                cp -a -- "$source" "$staged" || { rm -f -- "$staged"; return 1; }
                mv -fT -- "$staged" "$destination" || { rm -f -- "$staged"; return 1; }
            else
                rm -f -- "$destination" || return 1
            fi
        }
        restore_one "$1" "$2" "$3" || failed=1
        restore_one "$4" "$5" "$6" || failed=1
        restore_one "$7" "$8" "$9" || failed=1
        systemctl restart libvirtd >/dev/null 2>&1 || failed=1
        exit "$failed"
    ' bash \
        "$QEMU_EXISTIA" "$BACKUP_HOOKS/qemu.bak" "$HOOK_QEMU" \
        "$PREPARE_EXISTIA" "$BACKUP_HOOKS/prepare.bak" "$PREPARE" \
        "$RELEASE_EXISTIA" "$BACKUP_HOOKS/release.bak" "$RELEASE"
}

publicar_hooks() {
    sudo bash -c '
        set -euo pipefail
        publish_one() {
            local source="$1" destination="$2" staged="${destination}.new.$$"
            rm -f -- "$staged"
            if ! install -o root -g root -m 0755 -- "$source" "$staged"; then
                rm -f -- "$staged"
                return 1
            fi
            if ! mv -fT -- "$staged" "$destination"; then
                rm -f -- "$staged"
                return 1
            fi
        }
        install -d -o root -g root -m 0755 "$(dirname -- "$2")"
        install -d -o root -g root -m 0755 "$(dirname -- "$4")"
        install -d -o root -g root -m 0755 "$(dirname -- "$6")"
        publish_one "$1" "$2"
        publish_one "$3" "$4"
        publish_one "$5" "$6"
        systemctl restart libvirtd
    ' bash "$DISPATCHER_TMP" "$HOOK_QEMU" "$PREPARE_TMP" "$PREPARE" "$RELEASE_TMP" "$RELEASE"
}

HOOKS_PUBLICADOS=0
XML_ALTERADO=0
TRANSACTION_COMMIT=0
ORIGINAL_XML=""
XML_OPCIONAL=""
FRAGMENTO=""
XML_TESTE=""

cleanup_etapa() {
    local status=$? rollback_falhou=0
    trap - EXIT
    if [ "$XML_ALTERADO" -eq 1 ] && [ "$TRANSACTION_COMMIT" -ne 1 ]; then
        erro "Falha durante a transação XML; restaurando a definição original."
        if [ -z "$ORIGINAL_XML" ] || ! $VIRSH define "$ORIGINAL_XML" >/dev/null; then
            erro "RESTAURAÇÃO AUTOMÁTICA DO XML FALHOU: use o backup informado."
            rollback_falhou=1
        fi
    fi
    if [ "$HOOKS_PUBLICADOS" -eq 1 ] && [ "$TRANSACTION_COMMIT" -ne 1 ]; then
        if ! restaurar_hooks; then
            erro "RESTAURAÇÃO AUTOMÁTICA DOS HOOKS FALHOU: use $BACKUP_HOOKS."
            rollback_falhou=1
        fi
    fi
    rm -rf "${TMP_HOOKS:-}"
    rm -f "${ORIGINAL_XML:-}" "${FRAGMENTO:-}" "${XML_TESTE:-}"
    if [ -n "${XML_OPCIONAL:-}" ]; then
        rm -f "$XML_OPCIONAL" "${XML_OPCIONAL}.orig"
    fi
    [ "$rollback_falhou" -eq 0 ] || status=1
    exit "$status"
}
trap cleanup_etapa EXIT

if publicar_hooks; then
    HOOKS_PUBLICADOS=1
    ok "Dispatcher e hooks publicados sob lock; backup exclusivo em $BACKUP_HOOKS."
else
    if restaurar_hooks; then
        falhar "Instalação/reload dos hooks falhou; arquivos anteriores restaurados."
    else
        falhar "FALHA CRÍTICA: publicação e restauração dos hooks falharam; use $BACKUP_HOOKS."
    fi
fi

# ---------------------------------------------------------------------------
# XML: alterações com restauração integral em caso de falha.
# ---------------------------------------------------------------------------
titulo "GPU e HD1 no XML da VM"
ORIGINAL_XML="$(mktemp)"

$VIRSH dumpxml --inactive "$VM_NAME" > "$ORIGINAL_XML"
xmlstarlet val -q "$ORIGINAL_XML" || falhar "XML original da VM é inválido."
xml_backup "$VM_NAME"

restaurar_xml() {
    if [ "$XML_ALTERADO" -eq 1 ]; then
        erro "Restaurando o XML original da VM após falha."
        if $VIRSH define "$ORIGINAL_XML" >/dev/null; then
            XML_ALTERADO=0
        else
            erro "RESTAURAÇÃO AUTOMÁTICA FALHOU: use o backup XML informado acima."
        fi
    fi
}

anexar_hostdev_pci() {
    local endereco="$1" dom bus slot func count node tmp attr_count mode_count
    IFS=':.' read -r dom bus slot func <<< "$endereco"
    node="/domain/devices/hostdev[@type='pci' and source/address[@domain='0x$dom' and @bus='0x$bus' and @slot='0x$slot' and @function='0x$func']]"
    count="$($VIRSH dumpxml --inactive "$VM_NAME" | xmlstarlet sel -t -v "count($node)")"
    [[ "$count" =~ ^[0-9]+$ ]] || falhar "Não foi possível contar hostdev $endereco."
    [ "$count" -le 1 ] || falhar "Há hostdev duplicado para $endereco."

    if [ "$count" -eq 1 ]; then
        tmp="$(mktemp)"
        $VIRSH dumpxml --inactive "$VM_NAME" > "$tmp"
        attr_count="$(xmlstarlet sel -t -v "count($node/@managed)" "$tmp")"
        mode_count="$(xmlstarlet sel -t -v "count($node/@mode)" "$tmp")"
        if [ "$attr_count" = "0" ]; then
            xmlstarlet ed -L -i "$node" -t attr -n managed -v no "$tmp"
        else
            xmlstarlet ed -L -u "$node/@managed" -v no "$tmp"
        fi
        if [ "$mode_count" = "0" ]; then
            xmlstarlet ed -L -i "$node" -t attr -n mode -v subsystem "$tmp"
        else
            xmlstarlet ed -L -u "$node/@mode" -v subsystem "$tmp"
        fi
        xmlstarlet val -q "$tmp" || { rm -f "$tmp"; falhar "XML inválido ao reconciliar $endereco."; }
        XML_ALTERADO=1
        $VIRSH define "$tmp" >/dev/null
        rm -f "$tmp"
        ok "hostdev $endereco reconciliado para managed='no'."
        return 0
    fi

    FRAGMENTO="$(mktemp)"
    cat > "$FRAGMENTO" <<XML
<hostdev mode='subsystem' type='pci' managed='no'>
  <source>
    <address domain='0x$dom' bus='0x$bus' slot='0x$slot' function='0x$func'/>
  </source>
</hostdev>
XML
    XML_ALTERADO=1
    if ! $VIRSH attach-device "$VM_NAME" "$FRAGMENTO" --config; then
        rm -f "$FRAGMENTO"; FRAGMENTO=""
        restaurar_xml
        falhar "Falha ao anexar hostdev $endereco."
    fi
    rm -f "$FRAGMENTO"; FRAGMENTO=""
    ok "hostdev $endereco anexado com gerenciamento exclusivo dos hooks."
}

anexar_hostdev_pci "$GPU_PCI_ID"
anexar_hostdev_pci "$GPU_AUDIO_PCI_ID"

XML_TESTE="$(mktemp)"
$VIRSH dumpxml --inactive "$VM_NAME" > "$XML_TESTE"
xmlstarlet val -q "$XML_TESTE" \
    || { restaurar_xml; falhar "XML inválido antes de anexar o HD1."; }

HD1_SOURCE_COUNT="$(disk_source_count "$XML_TESTE" "$HD1_BY_ID_PATH")" \
    || { restaurar_xml; falhar "Não foi possível consultar as fontes de disco no XML."; }
HD1_OVERLAP_COUNT="$(disk_overlap_count "$XML_TESTE" "$HD1_BY_ID_PATH")" \
    || { restaurar_xml; falhar "Não foi possível comparar a topologia do HD1 no XML."; }
[[ "$HD1_SOURCE_COUNT" =~ ^[0-9]+$ ]] && [[ "$HD1_OVERLAP_COUNT" =~ ^[0-9]+$ ]] \
    || { restaurar_xml; falhar "Contagem inválida do HD1 no XML."; }
[ "$HD1_SOURCE_COUNT" -le 1 ] \
    || { restaurar_xml; falhar "O caminho configurado para o HD1 aparece mais de uma vez no XML."; }
[ "$HD1_OVERLAP_COUNT" -le 1 ] \
    || { restaurar_xml; falhar "O mesmo HD1 aparece no XML por caminhos ou aliases duplicados."; }

if [ "$HD1_SOURCE_COUNT" -eq 1 ]; then
    HD1_METADATA_COUNT="$(disk_metadata_count "$XML_TESTE" "$HD1_BY_ID_PATH")" \
        || { restaurar_xml; falhar "Não foi possível validar os metadados do HD1 no XML."; }
    if [ "$HD1_METADATA_COUNT" != "1" ] \
        || [ "$HD1_OVERLAP_COUNT" -ne 1 ]; then
        restaurar_xml
        falhar "HD1 existente diverge de block/raw/cache=none/io=native/snapshot=no/vdb/virtio."
    fi
    info "HD1 já anexado com caminho estável e metadados corretos."
else
    [ "$HD1_OVERLAP_COUNT" -eq 0 ] \
        || { restaurar_xml; falhar "O HD1 já está anexado por outro caminho; remova o alias conflitante."; }
    validar_hd1_host \
        || { restaurar_xml; falhar "HD1 deixou de ser exclusivo, inteiro ou acessível pelo caminho by-id."; }

    VDB_COUNT="$(disk_target_count "$XML_TESTE" vdb)" \
        || { restaurar_xml; falhar "Não foi possível consultar os targets de disco no XML."; }
    [ "$VDB_COUNT" = "0" ] \
        || { restaurar_xml; falhar "O target vdb já está ocupado por outro disco."; }

    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL "$HD1_ALVO"
    confirmar "Anexar $HD1_BY_ID_PATH ($HD1_ALVO) como disco físico inteiro da VM?" \
        || { restaurar_xml; falhar "Cancelado."; }

    FRAGMENTO="$(mktemp)"
    cat > "$FRAGMENTO" <<XML
<disk type='block' device='disk' snapshot='no'>
  <driver name='qemu' type='raw' cache='none' io='native'/>
  <source dev='$HD1_BY_ID_PATH'/>
  <target dev='vdb' bus='virtio'/>
</disk>
XML
    XML_ALTERADO=1
    if ! $VIRSH attach-device "$VM_NAME" "$FRAGMENTO" --config; then
        rm -f "$FRAGMENTO"; FRAGMENTO=""
        restaurar_xml
        falhar "Falha ao anexar o HD1."
    fi
    rm -f "$FRAGMENTO"; FRAGMENTO=""
    ok "HD1 anexado como vdb, raw, snapshot=no."
fi

VIDEO_REMOVIDO=0
ANTI_APLICADO=0

validar_xml_resultante() {
    local endereco count source_count metadata_count overlap_count
    local elementos_video vendor_count vendor_total hidden_count hidden_total
    $VIRSH dumpxml --inactive "$VM_NAME" > "$XML_TESTE" \
        || { restaurar_xml; falhar "Não foi possível reler o XML inativo da VM."; }
    xmlstarlet val -q "$XML_TESTE" \
        || { restaurar_xml; falhar "XML resultante inválido."; }

    for endereco in "$GPU_PCI_ID" "$GPU_AUDIO_PCI_ID"; do
        count="$(hostdev_count "$XML_TESTE" "$endereco")" \
            || { restaurar_xml; falhar "Falha ao consultar hostdev $endereco no XML."; }
        if [ "$count" != "1" ]; then
            restaurar_xml
            falhar "Esperado exatamente um hostdev managed='no' para $endereco."
        fi
    done

    source_count="$(disk_source_count "$XML_TESTE" "$HD1_BY_ID_PATH")" \
        || { restaurar_xml; falhar "Falha ao consultar a fonte do HD1 no XML."; }
    metadata_count="$(disk_metadata_count "$XML_TESTE" "$HD1_BY_ID_PATH")" \
        || { restaurar_xml; falhar "Falha ao consultar os metadados do HD1 no XML."; }
    if [ "$source_count" != "1" ] || [ "$metadata_count" != "1" ]; then
        restaurar_xml
        falhar "Esperado exatamente um HD1 com caminho e metadados configurados."
    fi
    overlap_count="$(disk_overlap_count "$XML_TESTE" "$HD1_BY_ID_PATH")" \
        || { restaurar_xml; falhar "Não foi possível validar a topologia física do HD1."; }
    if [ "$overlap_count" != "1" ]; then
        restaurar_xml
        falhar "O HD1 não pode aparecer por alias, partição ou camada de bloco sobreposta."
    fi

    if [ "$VIDEO_REMOVIDO" -eq 1 ]; then
        elementos_video="$(xmlstarlet sel -t -v \
            "count(/domain/devices/graphics | /domain/devices/video | /domain/devices/channel[@type='spicevmc'] | /domain/devices/redirdev | /domain/devices/sound | /domain/devices/audio)" \
            "$XML_TESTE")" \
            || { restaurar_xml; falhar "Falha ao validar a remoção de vídeo virtual."; }
        if [ "$elementos_video" != "0" ]; then
            restaurar_xml
            falhar "A remoção opcional deixou dispositivos virtuais de vídeo/áudio no XML."
        fi
    fi

    if [ "$ANTI_APLICADO" -eq 1 ]; then
        vendor_count="$(xmlstarlet sel -t -v \
            "count(/domain/features/hyperv/vendor_id[@state='on' and @value='randomid123'])" \
            "$XML_TESTE")" \
            || { restaurar_xml; falhar "Falha ao validar hyperv/vendor_id."; }
        vendor_total="$(xmlstarlet sel -t -v \
            'count(/domain/features/hyperv/vendor_id)' "$XML_TESTE")" \
            || { restaurar_xml; falhar "Falha ao contar hyperv/vendor_id."; }
        hidden_count="$(xmlstarlet sel -t -v \
            "count(/domain/features/kvm/hidden[@state='on'])" "$XML_TESTE")" \
            || { restaurar_xml; falhar "Falha ao validar kvm/hidden."; }
        hidden_total="$(xmlstarlet sel -t -v \
            'count(/domain/features/kvm/hidden)' "$XML_TESTE")" \
            || { restaurar_xml; falhar "Falha ao contar kvm/hidden."; }
        if [ "$vendor_count" != "1" ] || [ "$vendor_total" != "1" ] \
            || [ "$hidden_count" != "1" ] || [ "$hidden_total" != "1" ]; then
            restaurar_xml
            falhar "Ocultação opcional ausente, duplicada ou divergente no XML."
        fi
    fi
}

validar_xml_resultante
ok "XML-base validado: hostdevs exclusivos e um único HD1 físico."

# ---------------------------------------------------------------------------
# Flags opcionais
# ---------------------------------------------------------------------------
if [ "$REMOVER_VIDEO" -eq 1 ]; then
    titulo "Removendo vídeo virtual (QXL/SPICE)"
    aviso "Faça isso apenas depois de validar o passthrough físico."
    if confirmar "Remover vídeo virtual, gráficos SPICE e áudio emulado?"; then
        XML_OPCIONAL="$(mktemp)"
        $VIRSH dumpxml --inactive "$VM_NAME" > "$XML_OPCIONAL"
        cp "$XML_OPCIONAL" "${XML_OPCIONAL}.orig"
        xmlstarlet ed -L \
            -d '/domain/devices/graphics' \
            -d '/domain/devices/video' \
            -d "/domain/devices/channel[@type='spicevmc']" \
            -d '/domain/devices/redirdev' \
            -d '/domain/devices/sound' \
            -d '/domain/devices/audio' "$XML_OPCIONAL"
        if ! xmlstarlet val -q "$XML_OPCIONAL"; then
            restaurar_xml
            falhar "XML inválido ao remover vídeo virtual."
        fi
        XML_ALTERADO=1
        if ! $VIRSH define "$XML_OPCIONAL" >/dev/null; then
            restaurar_xml
            falhar "Falha ao remover vídeo virtual; XML original restaurado."
        fi
        rm -f "$XML_OPCIONAL" "${XML_OPCIONAL}.orig"
        XML_OPCIONAL=""
        VIDEO_REMOVIDO=1
        ok "Vídeo virtual removido."
    fi
fi

if [ "$ANTI_CODE43" -eq 1 ]; then
    titulo "Aplicando ocultação opcional de hypervisor"
    XML_OPCIONAL="$(mktemp)"
    $VIRSH dumpxml --inactive "$VM_NAME" > "$XML_OPCIONAL"
    cp "$XML_OPCIONAL" "${XML_OPCIONAL}.orig"

    FEATURES_COUNT="$(xmlstarlet sel -t -v 'count(/domain/features)' "$XML_OPCIONAL")"
    [ "$FEATURES_COUNT" = "1" ] \
        || { restaurar_xml; falhar "O XML deve conter exatamente um elemento features."; }
    HYPERV_COUNT="$(xmlstarlet sel -t -v 'count(/domain/features/hyperv)' "$XML_OPCIONAL")"
    KVM_COUNT="$(xmlstarlet sel -t -v 'count(/domain/features/kvm)' "$XML_OPCIONAL")"
    [[ "$HYPERV_COUNT" =~ ^[0-9]+$ ]] && [ "$HYPERV_COUNT" -le 1 ] \
        || { restaurar_xml; falhar "Estrutura hyperv duplicada ou inválida no XML."; }
    [[ "$KVM_COUNT" =~ ^[0-9]+$ ]] && [ "$KVM_COUNT" -le 1 ] \
        || { restaurar_xml; falhar "Estrutura kvm duplicada ou inválida no XML."; }

    if [ "$HYPERV_COUNT" -eq 0 ]; then
        xmlstarlet ed -L -s '/domain/features' -t elem -n hyperv -v '' "$XML_OPCIONAL"
    fi
    if [ "$KVM_COUNT" -eq 0 ]; then
        xmlstarlet ed -L -s '/domain/features' -t elem -n kvm -v '' "$XML_OPCIONAL"
    fi
    xmlstarlet ed -L -d '/domain/features/hyperv/vendor_id' "$XML_OPCIONAL"
    xmlstarlet ed -L -s '/domain/features/hyperv' -t elem -n vendor_id -v '' "$XML_OPCIONAL"
    xmlstarlet ed -L -i '/domain/features/hyperv/vendor_id' -t attr -n state -v on "$XML_OPCIONAL"
    xmlstarlet ed -L -i '/domain/features/hyperv/vendor_id' -t attr -n value -v randomid123 "$XML_OPCIONAL"
    xmlstarlet ed -L -d '/domain/features/kvm/hidden' "$XML_OPCIONAL"
    xmlstarlet ed -L -s '/domain/features/kvm' -t elem -n hidden -v '' "$XML_OPCIONAL"
    xmlstarlet ed -L -i '/domain/features/kvm/hidden' -t attr -n state -v on "$XML_OPCIONAL"

    if ! xmlstarlet val -q "$XML_OPCIONAL" \
        || [ "$(xmlstarlet sel -t -v 'count(/domain/features/hyperv/vendor_id)' "$XML_OPCIONAL")" != "1" ] \
        || [ "$(xmlstarlet sel -t -v 'count(/domain/features/kvm/hidden)' "$XML_OPCIONAL")" != "1" ]; then
        restaurar_xml
        falhar "Estrutura inválida ao aplicar ocultação de hypervisor."
    fi
    XML_ALTERADO=1
    if ! $VIRSH define "$XML_OPCIONAL" >/dev/null; then
        restaurar_xml
        falhar "Falha ao aplicar ocultação; XML original restaurado."
    fi
    rm -f "$XML_OPCIONAL" "${XML_OPCIONAL}.orig"
    XML_OPCIONAL=""
    ANTI_APLICADO=1
    ok "Ocultação opcional aplicada."
fi

validar_hd1_host \
    || { restaurar_xml; falhar "HD1 deixou de ser exclusivo antes do commit da etapa."; }
validar_xml_resultante
TRANSACTION_COMMIT=1
ok "Transação de hooks e XML confirmada após todas as validações."

echo
titulo "Como testar"
cat <<TESTE
1. Validar XML: virsh --connect qemu:///system dumpxml $VM_NAME | xmlstarlet val -
2. Iniciar VM:  virsh --connect qemu:///system start $VM_NAME
3. Desligar o Windows normalmente e confirmar que o desktop Linux retorna.
4. Logs: sudo journalctl -u libvirtd -e | grep -i hook
5. Se o release falhar, use um TTY e rode util/recuperar-gpu.sh.
TESTE
ok "Etapa 50 concluída."
