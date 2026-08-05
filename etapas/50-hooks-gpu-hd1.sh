#!/bin/bash
# ============================================================================
# etapas/50-hooks-gpu-hd1.sh - Capítulo 19: GPU dinâmica + HD1 opcional
# ============================================================================
# O libvirt (hostdev managed='yes') é a única autoridade para detach/reattach
# PCI. Os hooks apenas fazem preflight, liberam/restauram a sessão gráfica e
# conferem as pós-condições. Nenhum hook escreve em bind/unbind/new_id.
# O HD1 físico é opcional: HD1_DISPENSADO=sim mantém a VM somente no QCOW2.
#
# Uso:
#   50-hooks-gpu-hd1.sh                         instala/atualiza hooks e XML
#   50-hooks-gpu-hd1.sh --verificar             verifica sem alterar
#   50-hooks-gpu-hd1.sh --renderizar-hooks DIR_EXISTENTE  renderiza/valida
#   50-hooks-gpu-hd1.sh [--remover-video] [--anti-code43]
#       aplica o fluxo normal e, ao final, os submodos solicitados.
#
# Falha ou cancelamento durante a transação restaura hooks/XML automaticamente.
# Recuperar a GPU no host não desfaz a configuração persistente; após sucesso,
# a reversão exige restaurar os backups de XML/hooks em janela de manutenção.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

HOOK_QEMU="/etc/libvirt/hooks/qemu"
HOOK_BASE="/etc/libvirt/hooks/qemu.d/${VM_NAME:-nao-configurada}"
PREPARE="$HOOK_BASE/prepare/begin/01-gpu-preflight.sh"
START="$HOOK_BASE/start/begin/01-gpu-vfio-check.sh"
RELEASE="$HOOK_BASE/release/end/01-gpu-restore.sh"
GATE_REQUIRED="$HOOK_BASE/.vm-passthrough-required"
INSTALLING_MARKER="$HOOK_BASE/.vm-passthrough-installing"
INSTALLING_HOOK="$HOOK_BASE/prepare/begin/00-vm-passthrough-installing.sh"
PREPARE_ANTIGO="$HOOK_BASE/prepare/begin/01-gpu-para-vfio.sh"
RELEASE_ANTIGO="$HOOK_BASE/release/end/01-gpu-para-linux.sh"
MARCADOR_DISPATCHER="# vm-passthrough-qemu-dispatcher-v2"
STAMP="$(date +%Y%m%d-%H%M%S)-$$"

hostdev_estado_xml() {
    local endereco="${1,,}" dom bus slot func xml
    IFS=':.' read -r dom bus slot func <<< "$endereco"
    xml="$($VIRSH dumpxml --inactive "$VM_NAME" 2>/dev/null)" || return 1
    HOSTDEV_TOTAL="$(xmlstarlet sel -t -v \
        "count(/domain/devices/hostdev/source/address[@domain='0x$dom' and @bus='0x$bus' and @slot='0x$slot' and @function='0x$func'])" \
        <<< "$xml")" || return 1
    HOSTDEV_EXATO="$(xmlstarlet sel -t -v \
        "count(/domain/devices/hostdev[@mode='subsystem' and @type='pci' and @managed='yes']/source/address[@domain='0x$dom' and @bus='0x$bus' and @slot='0x$slot' and @function='0x$func'])" \
        <<< "$xml")" || return 1
}

disco_estado_xml() {
    local caminho="$1" xml
    xml="$($VIRSH dumpxml --inactive "$VM_NAME" 2>/dev/null)" || return 1
    DISCO_XML_SOURCE="$(xmlstarlet sel -t -v \
        "count(/domain/devices/disk/source[@dev='$caminho'])" <<< "$xml")" || return 1
    DISCO_XML_EXATO="$(xmlstarlet sel -t -v \
        "count(/domain/devices/disk[@type='block' and @device='disk' and driver/@name='qemu' and driver/@type='raw' and driver/@cache='none' and source/@dev='$caminho' and target/@dev='vdb' and target/@bus='virtio'])" \
        <<< "$xml")" || return 1
    DISCO_XML_VDB="$(xmlstarlet sel -t -v \
        "count(/domain/devices/disk/target[@dev='vdb'])" <<< "$xml")" || return 1
}

verificar_hook() {
    local arquivo="$1" descricao="$2"
    if [ -x "$arquivo" ] && bash -n "$arquivo" 2>/dev/null; then
        v_ok "$descricao presente e sintaticamente válido."
    else
        v_falta "$descricao ausente, não executável ou inválido: $arquivo"
    fi
}

verificar() {
    [ -n "${VM_NAME:-}" ] || { v_falta "VM_NAME não definido."; v_fim; }
    local prep="/etc/libvirt/hooks/qemu.d/$VM_NAME/prepare/begin/01-gpu-preflight.sh"
    local inicio="/etc/libvirt/hooks/qemu.d/$VM_NAME/start/begin/01-gpu-vfio-check.sh"
    local release="/etc/libvirt/hooks/qemu.d/$VM_NAME/release/end/01-gpu-restore.sh"
    local obrigatorio="/etc/libvirt/hooks/qemu.d/$VM_NAME/.vm-passthrough-required"
    if [ -x "$HOOK_QEMU" ] && grep -qF "$MARCADOR_DISPATCHER" "$HOOK_QEMU" 2>/dev/null \
       && bash -n "$HOOK_QEMU" 2>/dev/null; then
        v_ok "Dispatcher gerenciado v2 instalado e válido."
    else
        v_falta "Dispatcher v2 ausente ou incompatível."
    fi
    verificar_hook "$prep" "Hook prepare/begin"
    verificar_hook "$inicio" "Hook start/begin"
    verificar_hook "$release" "Hook release/end"
    [ -f "$obrigatorio" ] \
        && v_ok "Marcador fail-closed do gate presente." \
        || v_falta "Marcador fail-closed do gate ausente: $obrigatorio"
    if [ -e "/etc/libvirt/hooks/qemu.d/$VM_NAME/.vm-passthrough-installing" ]; then
        v_falta "Marcador de transação interrompida ainda existe; starts permanecem bloqueados."
    else
        v_ok "Nenhuma transação de instalação pendente bloqueia a VM."
    fi

    if vm_existe "$VM_NAME"; then
        if [ -n "${GPU_PCI_ID:-}" ] && hostdev_estado_xml "$GPU_PCI_ID" \
           && [ "$HOSTDEV_TOTAL" = 1 ] && [ "$HOSTDEV_EXATO" = 1 ]; then
            v_ok "GPU $GPU_PCI_ID anexada exatamente uma vez com managed='yes'."
        else
            v_falta "GPU ausente, duplicada ou sem managed='yes' no XML."
        fi
        if [ -z "${GPU_AUDIO_PCI_ID:-}" ]; then
            v_ok "GPU sem função de áudio configurada."
        elif hostdev_estado_xml "$GPU_AUDIO_PCI_ID" \
             && [ "$HOSTDEV_TOTAL" = 1 ] && [ "$HOSTDEV_EXATO" = 1 ]; then
            v_ok "Áudio $GPU_AUDIO_PCI_ID anexado exatamente uma vez com managed='yes'."
        else
            v_falta "Áudio da GPU ausente, duplicado ou sem managed='yes' no XML."
        fi
        if [ -n "${HD1_BY_ID_PATH:-}" ] && [ "${HD1_DISPENSADO:-}" = "sim" ]; then
            v_falta "Configuração contraditória: HD1 definido e dispensado ao mesmo tempo."
        elif [ -z "${HD1_BY_ID_PATH:-}" ] && [ "${HD1_DISPENSADO:-}" = "sim" ]; then
            v_ok "Fluxo sem disco físico dedicado (opção 0 registrada)."
        elif [ -z "${HD1_BY_ID_PATH:-}" ]; then
            v_falta "Uso do HD1 ainda não decidido na etapa 02."
        elif disco_estado_xml "$HD1_BY_ID_PATH" \
             && [ "$DISCO_XML_SOURCE" = 1 ] && [ "$DISCO_XML_EXATO" = 1 ]; then
            if validar_disco_fisico_vm "$HD1_BY_ID_PATH" "${NVME_DEVICE:-}" "${HD2_DISCO_PAI:-}"; then
                v_ok "HD1 exato no XML e seguro no estado atual: $HD1_BY_ID_PATH."
            else
                v_falta "$DISCO_VM_ERRO"
            fi
        else
            v_falta "HD1 ausente, duplicado ou com atributos diferentes dos autorizados."
        fi
    else
        v_falta "VM '$VM_NAME' não existe."
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

validar_config_hooks() {
    exigir_conf VM_NAME GPU_PCI_ID GPU_VENDOR_DEVICE_ID DM_SERVICE IOMMU_GROUP_GPU
    nome_vm_valido "$VM_NAME" || falhar "VM_NAME inseguro: '$VM_NAME'."
    pci_bdf_valido "$GPU_PCI_ID" || falhar "GPU_PCI_ID inválido: '$GPU_PCI_ID'."
    pci_vendor_device_valido "$GPU_VENDOR_DEVICE_ID" || falhar "GPU_VENDOR_DEVICE_ID inválido."
    inteiro_na_faixa "$IOMMU_GROUP_GPU" 0 65535 || falhar "IOMMU_GROUP_GPU inválido."
    nome_unidade_systemd_valido "$DM_SERVICE" || falhar "DM_SERVICE inválido: '$DM_SERVICE'."
    if [ -n "${GPU_AUDIO_PCI_ID:-}" ]; then
        pci_bdf_valido "$GPU_AUDIO_PCI_ID" || falhar "GPU_AUDIO_PCI_ID inválido."
        exigir_conf GPU_AUDIO_VENDOR_DEVICE_ID
        pci_vendor_device_valido "$GPU_AUDIO_VENDOR_DEVICE_ID" || falhar "GPU_AUDIO_VENDOR_DEVICE_ID inválido."
    fi
    if [ -n "${HD1_BY_ID_PATH:-}" ] && [ "${HD1_DISPENSADO:-}" = "sim" ]; then
        falhar "Configuração contraditória: HD1_BY_ID_PATH definido e HD1_DISPENSADO=sim."
    elif [ -n "${HD1_BY_ID_PATH:-}" ]; then
        caminho_absoluto_seguro "$HD1_BY_ID_PATH" || falhar "HD1_BY_ID_PATH inseguro."
        exigir_conf NVME_DEVICE
        if [ -n "${UUID_HD2:-}" ]; then
            exigir_conf HD2_DISCO_PAI
        fi
    elif [ "${HD1_DISPENSADO:-}" != "sim" ]; then
        falhar "Uso do disco físico adicional ainda não foi decidido. Rode a etapa 02 e escolha um disco ou a opção 0."
    fi
}

gerar_dispatcher() {
    local destino="$1" legado="$2"
    {
        cat <<'CAB'
#!/bin/bash
# vm-passthrough-qemu-dispatcher-v2
# Propaga todos os argumentos, replica o XML de stdin e preserva hook legado.
set -u -o pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
CAB
        printf 'LEGACY_HOOK=%q\n' "$legado"
        cat <<'CORPO'
[ "$#" -ge 3 ] || { echo "[hook dispatcher] argumentos insuficientes" >&2; exit 64; }
VM_NAME="$1"
EVENTO="$2"
SUBEVENTO="$3"
segmento_seguro() {
    [ -n "$1" ] && [ "$1" != . ] && [ "$1" != .. ] \
        && [[ "$1" != */* && "$1" != *$'\n'* && "$1" != *$'\r'* ]]
}
segmento_seguro "$VM_NAME" && segmento_seguro "$EVENTO" && segmento_seguro "$SUBEVENTO" \
    || { echo "[hook dispatcher] segmento de caminho inseguro" >&2; exit 64; }
INSTALANDO="/etc/libvirt/hooks/qemu.d/${VM_NAME}/.vm-passthrough-installing"
if [ -e "$INSTALANDO" ]; then
    echo "[hook dispatcher] configuração de passthrough em transação; start bloqueado" >&2
    exit 75
fi
DIRETORIO_HOOK="/etc/libvirt/hooks/qemu.d/${VM_NAME}/${EVENTO}/${SUBEVENTO}"
ENTRADA="$(mktemp /run/libvirt-qemu-hook.XXXXXX)" \
    || { echo "[hook dispatcher] falha ao criar temporário" >&2; exit 70; }
chmod 600 "$ENTRADA" || { rm -f "$ENTRADA"; exit 70; }
trap 'rm -f "$ENTRADA"' EXIT
cat > "$ENTRADA" || { echo "[hook dispatcher] falha ao capturar stdin" >&2; exit 74; }

executar_hook() {
    local alvo="$1" rc
    shift
    "$alvo" "$@" < "$ENTRADA" || {
        rc=$?
        echo "[hook dispatcher] $alvo falhou com status $rc" >&2
        return "$rc"
    }
}

# O gate de prepare é executado explicitamente antes de qualquer 00-* ou hook
# legado. Depois ele é pulado no glob para nunca rodar duas vezes.
GATE=""
if [ "$EVENTO" = prepare ] && [ "$SUBEVENTO" = begin ]; then
    GATE="$DIRETORIO_HOOK/01-gpu-preflight.sh"
    OBRIGATORIO="/etc/libvirt/hooks/qemu.d/${VM_NAME}/.vm-passthrough-required"
    if [ -e "$OBRIGATORIO" ] && [ ! -e "$GATE" ]; then
        echo "[hook dispatcher] gate obrigatório ausente: $GATE" >&2
        exit 127
    fi
    if [ -e "$GATE" ]; then
        [ -x "$GATE" ] || { echo "[hook dispatcher] gate não executável: $GATE" >&2; exit 126; }
        executar_hook "$GATE" "$@" || exit $?
    fi
fi
if [ -d "$DIRETORIO_HOOK" ]; then
    for script in "$DIRETORIO_HOOK"/*; do
        [ -x "$script" ] || continue
        [ -n "$GATE" ] && [ "$script" = "$GATE" ] && continue
        executar_hook "$script" "$@" || exit $?
    done
fi
if [ -n "$LEGACY_HOOK" ] && [ -x "$LEGACY_HOOK" ]; then
    executar_hook "$LEGACY_HOOK" "$@" || exit $?
fi
exit 0
CORPO
    } > "$destino"
}

gerar_prepare() {
    local destino="$1" audio_pci="${GPU_AUDIO_PCI_ID:-}" audio_id="${GPU_AUDIO_VENDOR_DEVICE_ID:-}"
    audio_pci="${audio_pci,,}"
    audio_id="${audio_id,,}"
    {
        cat <<'CAB'
#!/bin/bash
# Hook prepare/begin: preflight fail-closed e liberação transacional do desktop.
set -Eeuo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
CAB
        printf 'VM_NAME=%q\n' "$VM_NAME"
        printf 'GPU_PCI=%q\n' "${GPU_PCI_ID,,}"
        printf 'GPU_AUDIO_PCI=%q\n' "$audio_pci"
        printf 'GPU_ID=%q\n' "${GPU_VENDOR_DEVICE_ID,,}"
        printf 'GPU_AUDIO_ID=%q\n' "$audio_id"
        printf 'IOMMU_GROUP=%q\n' "$((10#$IOMMU_GROUP_GPU))"
        printf 'DM=%q\n' "$DM_SERVICE"
        printf 'HD1_BY_ID=%q\n' "${HD1_BY_ID_PATH:-}"
        printf 'DISCO_SISTEMA=%q\n' "${NVME_DEVICE:-}"
        printf 'DISCO_HD2=%q\n' "${HD2_DISCO_PAI:-}"
        printf 'HD1_IDENTIDADE=%q\n' "${HD1_IDENTIDADE:-}"
        cat <<'CORPO'
STATE_DIR=/run/libvirt-gpu-passthrough
STATE_FILE="$STATE_DIR/${VM_NAME}.state"
DM_WAS_ACTIVE=0

falha() { echo "[hook prepare] ERRO: $*" >&2; return 1; }
LOCK_DIR=/run/libvirt-gpu-locks
LOCK_FILE="$LOCK_DIR/${VM_NAME}.lock"
install -d -o root -g root -m 0755 "$LOCK_DIR"
[ ! -L "$LOCK_FILE" ] || falha "lock é link simbólico: $LOCK_FILE"
touch "$LOCK_FILE"
chown root:root "$LOCK_FILE"
chmod 0666 "$LOCK_FILE"
[ -f "$LOCK_FILE" ] && [ "$(stat -c %u "$LOCK_FILE")" -eq 0 ] || falha "lock inseguro"
exec 9>"$LOCK_FILE"
flock -n 9 || falha "outra operação de GPU está em andamento ($LOCK_FILE)"

pci_id_atual() {
    local bdf="$1" vendor device
    IFS= read -r vendor < "/sys/bus/pci/devices/$bdf/vendor" || return 1
    IFS= read -r device < "/sys/bus/pci/devices/$bdf/device" || return 1
    printf '%s:%s\n' "${vendor#0x}" "${device#0x}"
}
validar_pci_iommu() {
    local link grupo audio_grupo membro bdf classe
    local restaurar_nullglob=0
    [ "$(pci_id_atual "$GPU_PCI")" = "$GPU_ID" ] \
        || falha "identidade vendor/device da GPU mudou"
    link="/sys/bus/pci/devices/$GPU_PCI/iommu_group"
    [ -L "$link" ] || falha "GPU sem grupo IOMMU"
    grupo="$(basename -- "$(readlink -f -- "$link")")" || falha "grupo IOMMU ilegível"
    [ "$grupo" = "$IOMMU_GROUP" ] || falha "grupo IOMMU mudou: $IOMMU_GROUP -> $grupo"
    if [ -n "$GPU_AUDIO_PCI" ]; then
        [ "$(pci_id_atual "$GPU_AUDIO_PCI")" = "$GPU_AUDIO_ID" ] \
            || falha "identidade vendor/device do áudio mudou"
        link="/sys/bus/pci/devices/$GPU_AUDIO_PCI/iommu_group"
        [ -L "$link" ] || falha "áudio sem grupo IOMMU"
        audio_grupo="$(basename -- "$(readlink -f -- "$link")")" || falha "grupo do áudio ilegível"
        [ "$audio_grupo" = "$grupo" ] || falha "GPU e áudio deixaram de compartilhar grupo IOMMU"
    fi
    shopt -q nullglob || { shopt -s nullglob; restaurar_nullglob=1; }
    membros=("/sys/kernel/iommu_groups/$grupo/devices/"*)
    [ "$restaurar_nullglob" -eq 0 ] || shopt -u nullglob
    [ "${#membros[@]}" -gt 0 ] || falha "grupo IOMMU vazio/ilegível"
    for membro in "${membros[@]}"; do
        bdf="${membro##*/}"
        [ "$bdf" = "$GPU_PCI" ] && continue
        [ -n "$GPU_AUDIO_PCI" ] && [ "$bdf" = "$GPU_AUDIO_PCI" ] && continue
        IFS= read -r classe < "/sys/bus/pci/devices/$bdf/class" \
            || falha "não foi possível classificar membro IOMMU $bdf"
        [[ "${classe,,}" == 0x06* ]] || falha "endpoint não autorizado no grupo IOMMU: $bdf ($classe)"
    done
}
driver_atual() {
    local bdf="$1"
    if [ -L "/sys/bus/pci/devices/$bdf/driver" ]; then
        basename -- "$(readlink -f -- "/sys/bus/pci/devices/$bdf/driver")"
    else
        printf '%s\n' sem_driver
    fi
}
discos_fisicos_de() {
    local origem="$1" saida caminho tipo
    local -A vistos=()
    saida="$(lsblk -s -nro PATH,TYPE -- "$origem" 2>/dev/null)" || return 1
    while read -r caminho tipo; do
        [ "$tipo" = disk ] || continue
        [ -n "$caminho" ] || return 1
        if [ -z "${vistos[$caminho]+definido}" ]; then
            printf '%s\n' "$caminho"
            vistos[$caminho]=1
        fi
    done <<< "$saida"
    [ "${#vistos[@]}" -gt 0 ]
}
discos_raiz() {
    local fonte
    fonte="$(findmnt -no SOURCE / 2>/dev/null | sed 's/\[.*\]$//')" || return 1
    discos_fisicos_de "$fonte"
}
identidade_disco() {
    local alvo="$1" propriedades chave valor
    propriedades="$(udevadm info --query=property --name "$alvo" 2>/dev/null)" || return 1
    for chave in ID_WWN_WITH_EXTENSION ID_WWN ID_SERIAL; do
        valor="$(awk -F= -v k="$chave" '$1 == k && length($2) {print k "=" substr($0, index($0,"=")+1); exit}' \
            <<< "$propriedades")"
        [ -z "$valor" ] || { printf '%s\n' "$valor"; return 0; }
    done
    return 1
}
inspecionar_montagens() {
    local alvo="$1" saida
    saida="$(lsblk -nlo NAME,MOUNTPOINTS -- "$alvo" 2>/dev/null)" || return 1
    if awk 'NF>1 && $2!="" {achou=1} END {exit !achou}' <<< "$saida"; then
        SNAP_MONTADO=1
    else
        SNAP_MONTADO=0
    fi
}
capturar_snapshot_hd1() {
    local alvo tipo devno raizes raiz protegido real identidade
    [ -L "$HD1_BY_ID" ] || falha "HD1 persistente ausente: $HD1_BY_ID"
    alvo="$(readlink -f -- "$HD1_BY_ID")" || falha "não foi possível resolver HD1"
    [ -b "$alvo" ] || falha "alvo do HD1 não é bloco: $alvo"
    tipo="$(lsblk -dnro TYPE -- "$alvo" 2>/dev/null)" || falha "lsblk não classificou $alvo"
    [ "$tipo" = disk ] || falha "HD1 não aponta para disco inteiro"
    devno="$(lsblk -dnro MAJ:MIN -- "$alvo" 2>/dev/null)" || falha "major:minor do HD1 ilegível"
    [ -n "$devno" ] || falha "major:minor do HD1 vazio"
    raizes="$(discos_raiz)" || falha "não foi possível enumerar todos os discos físicos da raiz"
    while IFS= read -r raiz; do
        [ -n "$raiz" ] || continue
        raiz="$(readlink -f -- "$raiz")" || falha "ancestral da raiz ilegível"
        [ "$alvo" != "$raiz" ] || falha "HD1 coincide com a raiz do host ($raiz)"
    done <<< "$raizes"
    for protegido in "$DISCO_SISTEMA" "$DISCO_HD2"; do
        [ -n "$protegido" ] || continue
        real="$(readlink -f -- "$protegido")" || falha "disco protegido desapareceu: $protegido"
        [ -b "$real" ] || falha "disco protegido não é bloco: $protegido"
        [ "$alvo" != "$real" ] || falha "HD1 coincide com disco protegido: $real"
    done
    inspecionar_montagens "$alvo" || falha "lsblk falhou ao inspecionar montagens de $alvo"
    [ "$SNAP_MONTADO" -eq 0 ] || falha "HD1 ou partição está montado no host: $alvo"
    identidade="$(identidade_disco "$alvo")" || falha "HD1 não possui WWN/serial verificável"
    [ "$identidade" = "$HD1_IDENTIDADE" ] \
        || falha "identidade do HD1 mudou: esperado '$HD1_IDENTIDADE', atual '$identidade'"
    SNAP_ALVO="$alvo"
    SNAP_DEVNO="$devno"
    SNAP_IDENTIDADE="$identidade"
}
preflight_hd1() {
    local alvo_1 devno_1 identidade_1
    [ -n "$HD1_BY_ID" ] || return 0
    [[ "$HD1_BY_ID" == /dev/disk/by-id/* ]] || falha "HD1 não usa /dev/disk/by-id."
    capturar_snapshot_hd1
    alvo_1="$SNAP_ALVO"
    devno_1="$SNAP_DEVNO"
    identidade_1="$SNAP_IDENTIDADE"
    capturar_snapshot_hd1
    [ "$SNAP_ALVO" = "$alvo_1" ] && [ "$SNAP_DEVNO" = "$devno_1" ] \
        && [ "$SNAP_IDENTIDADE" = "$identidade_1" ] \
        || falha "alvo, major:minor ou identidade do HD1 mudou durante o preflight"
}
aguardar_dm_inativo() {
    local estado i
    for ((i=0; i<30; i++)); do
        estado="$(systemctl show -p ActiveState --value "$DM")" || return 1
        [ "$estado" = inactive ] && return 0
        sleep 1
    done
    return 1
}
rollback_prepare() {
    local rc=$? modulo falhas=0 i estado
    trap - ERR
    set +e
    echo "[hook prepare] revertendo liberação do desktop após falha..." >&2
    for modulo in nvidia nvidia_modeset nvidia_drm nvidia_uvm; do
        modprobe "$modulo" || { echo "[hook prepare] rollback: modprobe $modulo falhou" >&2; falhas=1; }
    done
    for ((i=0; i<20; i++)); do
        [ "$(driver_atual "$GPU_PCI")" = nvidia ] && break
        sleep 1
    done
    [ "$(driver_atual "$GPU_PCI")" = nvidia ] \
        || { echo "[hook prepare] rollback: GPU não retornou ao driver nvidia" >&2; falhas=1; }
    if [ -n "$GPU_AUDIO_PCI" ]; then
        modprobe snd_hda_intel || falhas=1
        for ((i=0; i<20; i++)); do
            [ "$(driver_atual "$GPU_AUDIO_PCI")" = snd_hda_intel ] && break
            sleep 1
        done
        [ "$(driver_atual "$GPU_AUDIO_PCI")" = snd_hda_intel ] || falhas=1
    fi
    nvidia-smi >/dev/null 2>&1 || { echo "[hook prepare] rollback: nvidia-smi falhou" >&2; falhas=1; }
    if [ "$DM_WAS_ACTIVE" -eq 1 ]; then
        systemctl start "$DM" || falhas=1
        systemctl is-active --quiet "$DM" || falhas=1
    else
        estado="$(systemctl show -p ActiveState --value "$DM")"
        [ "$estado" = inactive ] || falhas=1
    fi
    if [ "$falhas" -eq 0 ]; then
        rm -f -- "$STATE_FILE"
    else
        echo "[hook prepare] rollback incompleto; estado preservado em $STATE_FILE" >&2
    fi
    exit "$rc"
}

validar_pci_iommu
preflight_hd1
[ "$(driver_atual "$GPU_PCI")" = nvidia ] \
    || falha "GPU $GPU_PCI não está no driver nvidia antes do start"
if [ -n "$GPU_AUDIO_PCI" ]; then
    [ "$(driver_atual "$GPU_AUDIO_PCI")" = snd_hda_intel ] \
        || falha "áudio $GPU_AUDIO_PCI não está em snd_hda_intel antes do start"
fi
DM_ESTADO="$(systemctl show -p ActiveState --value "$DM")" || falha "não foi possível consultar $DM"
case "$DM_ESTADO" in
    active) DM_WAS_ACTIVE=1 ;;
    inactive) DM_WAS_ACTIVE=0 ;;
    *) falha "$DM está em estado transitório/inseguro: $DM_ESTADO" ;;
esac
install -d -m 0700 "$STATE_DIR"
[ ! -e "$STATE_FILE" ] || falha "estado anterior ainda existe: $STATE_FILE; execute a recuperação"
STATE_TMP="$(mktemp "$STATE_DIR/.${VM_NAME}.XXXXXX")" || falha "não foi possível criar estado"
chmod 0600 "$STATE_TMP"
printf 'DM_WAS_ACTIVE=%s\nGPU_DRIVER=nvidia\nAUDIO_DRIVER=%s\nHD1_ALVO=%s\nHD1_DEVNO=%s\nHD1_IDENTIDADE=%s\n' \
    "$DM_WAS_ACTIVE" "${GPU_AUDIO_PCI:+snd_hda_intel}" \
    "${SNAP_ALVO:-}" "${SNAP_DEVNO:-}" "${SNAP_IDENTIDADE:-}" > "$STATE_TMP"
mv -f -- "$STATE_TMP" "$STATE_FILE"
trap rollback_prepare ERR

if [ "$DM_WAS_ACTIVE" -eq 1 ]; then
    echo "[hook prepare] parando $DM..."
    systemctl stop "$DM"
    aguardar_dm_inativo || falha "$DM não ficou inativo em 30 segundos"
fi
for modulo in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
    if grep -q "^${modulo} " /proc/modules; then
        echo "[hook prepare] descarregando $modulo..."
        modprobe -r "$modulo"
    fi
done
[ "$(driver_atual "$GPU_PCI")" = sem_driver ] \
    || falha "GPU continuou vinculada após descarregar nvidia"
trap - ERR
echo "[hook prepare] preflight aprovado e desktop liberado; detach PCI será feito pelo libvirt."
CORPO
    } > "$destino"
}

gerar_start() {
    local destino="$1" audio_pci="${GPU_AUDIO_PCI_ID:-}"
    audio_pci="${audio_pci,,}"
    {
        cat <<'CAB'
#!/bin/bash
# Hook start/begin: confere o detach gerenciado antes de liberar o QEMU.
set -Eeuo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
CAB
        printf 'VM_NAME=%q\n' "$VM_NAME"
        printf 'GPU_PCI=%q\n' "${GPU_PCI_ID,,}"
        printf 'GPU_AUDIO_PCI=%q\n' "$audio_pci"
        printf 'HD1_BY_ID=%q\n' "${HD1_BY_ID_PATH:-}"
        printf 'HD1_IDENTIDADE=%q\n' "${HD1_IDENTIDADE:-}"
        cat <<'CORPO'
STATE_FILE="/run/libvirt-gpu-passthrough/${VM_NAME}.state"
[ -f "$STATE_FILE" ] || { echo "[hook start] estado prepare ausente" >&2; exit 1; }
HD1_ALVO_ESTADO=""
HD1_DEVNO_ESTADO=""
HD1_IDENTIDADE_ESTADO=""
while IFS='=' read -r chave valor; do
    case "$chave" in
        HD1_ALVO) HD1_ALVO_ESTADO="$valor" ;;
        HD1_DEVNO) HD1_DEVNO_ESTADO="$valor" ;;
        HD1_IDENTIDADE) HD1_IDENTIDADE_ESTADO="$valor" ;;
        DM_WAS_ACTIVE|GPU_DRIVER|AUDIO_DRIVER) : ;;
        *) echo "[hook start] chave de estado desconhecida: $chave" >&2; exit 1 ;;
    esac
done < "$STATE_FILE"
identidade_disco() {
    local alvo="$1" propriedades chave valor
    propriedades="$(udevadm info --query=property --name "$alvo" 2>/dev/null)" || return 1
    for chave in ID_WWN_WITH_EXTENSION ID_WWN ID_SERIAL; do
        valor="$(awk -F= -v k="$chave" '$1 == k && length($2) {print k "=" substr($0, index($0,"=")+1); exit}' \
            <<< "$propriedades")"
        [ -z "$valor" ] || { printf '%s\n' "$valor"; return 0; }
    done
    return 1
}
validar_hd1_antes_qemu() {
    local alvo devno identidade saida
    [ -n "$HD1_BY_ID" ] || return 0
    alvo="$(readlink -f -- "$HD1_BY_ID")" || return 1
    [ -b "$alvo" ] || return 1
    devno="$(lsblk -dnro MAJ:MIN -- "$alvo" 2>/dev/null)" || return 1
    identidade="$(identidade_disco "$alvo")" || return 1
    [ "$alvo" = "$HD1_ALVO_ESTADO" ] && [ "$devno" = "$HD1_DEVNO_ESTADO" ] \
        && [ "$identidade" = "$HD1_IDENTIDADE_ESTADO" ] \
        && [ "$identidade" = "$HD1_IDENTIDADE" ] || return 1
    saida="$(lsblk -nlo NAME,MOUNTPOINTS -- "$alvo" 2>/dev/null)" || return 1
    ! awk 'NF>1 && $2!="" {achou=1} END {exit !achou}' <<< "$saida"
}
validar_hd1_antes_qemu \
    || { echo "[hook start] HD1 mudou ou foi montado depois do prepare; abortando QEMU" >&2; exit 1; }
driver_atual() {
    [ -L "/sys/bus/pci/devices/$1/driver" ] \
        && basename -- "$(readlink -f -- "/sys/bus/pci/devices/$1/driver")" \
        || printf '%s\n' sem_driver
}
aguardar_vfio() {
    local bdf="$1" i
    for ((i=0; i<15; i++)); do
        [ "$(driver_atual "$bdf")" = vfio-pci ] && return 0
        sleep 1
    done
    echo "[hook start] $bdf não foi entregue ao vfio-pci pelo libvirt" >&2
    return 1
}
aguardar_vfio "$GPU_PCI"
[ -z "$GPU_AUDIO_PCI" ] || aguardar_vfio "$GPU_AUDIO_PCI"
echo "[hook start] hostdev managed='yes' confirmado em vfio-pci."
CORPO
    } > "$destino"
}

gerar_release() {
    local destino="$1" audio_pci="${GPU_AUDIO_PCI_ID:-}"
    audio_pci="${audio_pci,,}"
    {
        cat <<'CAB'
#!/bin/bash
# Hook release/end: valida reattach gerenciado e restaura o desktop.
set -Eeuo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
CAB
        printf 'VM_NAME=%q\n' "$VM_NAME"
        printf 'GPU_PCI=%q\n' "${GPU_PCI_ID,,}"
        printf 'GPU_AUDIO_PCI=%q\n' "$audio_pci"
        printf 'DM=%q\n' "$DM_SERVICE"
        cat <<'CORPO'
STATE_FILE="/run/libvirt-gpu-passthrough/${VM_NAME}.state"
LOCK_DIR=/run/libvirt-gpu-locks
LOCK_FILE="$LOCK_DIR/${VM_NAME}.lock"
install -d -o root -g root -m 0755 "$LOCK_DIR"
[ ! -L "$LOCK_FILE" ] || { echo "[hook release] lock inseguro" >&2; exit 1; }
touch "$LOCK_FILE"
chown root:root "$LOCK_FILE"
chmod 0666 "$LOCK_FILE"
[ -f "$LOCK_FILE" ] && [ "$(stat -c %u "$LOCK_FILE")" -eq 0 ] \
    || { echo "[hook release] lock inseguro" >&2; exit 1; }
exec 9>"$LOCK_FILE"
flock -w 60 9 || { echo "[hook release] lock de GPU ocupado por mais de 60 s" >&2; exit 1; }
driver_atual() {
    [ -L "/sys/bus/pci/devices/$1/driver" ] \
        && basename -- "$(readlink -f -- "/sys/bus/pci/devices/$1/driver")" \
        || printf '%s\n' sem_driver
}
aguardar_driver() {
    local bdf="$1" esperado="$2" i
    for ((i=0; i<20; i++)); do
        [ "$(driver_atual "$bdf")" = "$esperado" ] && return 0
        sleep 1
    done
    echo "[hook release] $bdf não retornou ao driver $esperado (atual: $(driver_atual "$bdf"))" >&2
    return 1
}
if [ ! -f "$STATE_FILE" ]; then
    echo "[hook release] estado ausente; não é possível provar o baseline do driver/DM. Use util/recuperar-gpu.sh." >&2
    exit 1
fi
DM_WAS_ACTIVE=""
GPU_DRIVER=""
AUDIO_DRIVER=""
while IFS='=' read -r chave valor; do
    case "$chave" in
        DM_WAS_ACTIVE) DM_WAS_ACTIVE="$valor" ;;
        GPU_DRIVER) GPU_DRIVER="$valor" ;;
        AUDIO_DRIVER) AUDIO_DRIVER="$valor" ;;
        HD1_ALVO|HD1_DEVNO|HD1_IDENTIDADE) : ;;
        *) echo "[hook release] chave de estado desconhecida: $chave" >&2; exit 1 ;;
    esac
done < "$STATE_FILE"
[[ "$DM_WAS_ACTIVE" =~ ^[01]$ ]] || { echo "[hook release] estado DM inválido" >&2; exit 1; }
[ "$GPU_DRIVER" = nvidia ] || { echo "[hook release] driver GPU de estado inválido" >&2; exit 1; }
[[ "$AUDIO_DRIVER" =~ ^(snd_hda_intel)?$ ]] || { echo "[hook release] driver de áudio inválido" >&2; exit 1; }

FALHAS=0
for modulo in nvidia nvidia_modeset nvidia_drm nvidia_uvm; do
    echo "[hook release] carregando $modulo..."
    if ! modprobe "$modulo"; then
        echo "[hook release] modprobe $modulo falhou" >&2
        FALHAS=$((FALHAS + 1))
    fi
done
if [ -n "$AUDIO_DRIVER" ] && ! modprobe "$AUDIO_DRIVER"; then
    echo "[hook release] modprobe $AUDIO_DRIVER falhou" >&2
    FALHAS=$((FALHAS + 1))
fi
if ! aguardar_driver "$GPU_PCI" "$GPU_DRIVER"; then
    FALHAS=$((FALHAS + 1))
fi
if [ -n "$GPU_AUDIO_PCI" ] && ! aguardar_driver "$GPU_AUDIO_PCI" "$AUDIO_DRIVER"; then
    FALHAS=$((FALHAS + 1))
fi
if ! nvidia-smi >/dev/null; then
    echo "[hook release] nvidia-smi não respondeu" >&2
    FALHAS=$((FALHAS + 1))
fi
if [ "$DM_WAS_ACTIVE" -eq 1 ]; then
    if ! systemctl start "$DM"; then
        echo "[hook release] não foi possível iniciar $DM" >&2
        FALHAS=$((FALHAS + 1))
    elif ! systemctl is-active --quiet "$DM"; then
        echo "[hook release] $DM não ficou ativo" >&2
        FALHAS=$((FALHAS + 1))
    fi
else
    if ! DM_ESTADO_FINAL="$(systemctl show -p ActiveState --value "$DM")"; then
        echo "[hook release] não foi possível consultar o estado final de $DM" >&2
        FALHAS=$((FALHAS + 1))
    elif [ "$DM_ESTADO_FINAL" != inactive ]; then
        echo "[hook release] $DM estava inativo antes, mas mudou para $DM_ESTADO_FINAL" >&2
        FALHAS=$((FALHAS + 1))
    fi
fi
if [ "$FALHAS" -ne 0 ]; then
    echo "[hook release] restauração incompleta ($FALHAS falha(s)); estado preservado em $STATE_FILE" >&2
    exit 1
fi
rm -f -- "$STATE_FILE" \
    || { echo "[hook release] pós-condições aprovadas, mas o estado não pôde ser removido: $STATE_FILE" >&2; exit 1; }
echo "[hook release] GPU e desktop restaurados com pós-condições verificadas."
CORPO
    } > "$destino"
}

gerar_conjunto_hooks() {
    local diretorio="$1" legado="${2:-}"
    mkdir -p "$diretorio"
    gerar_dispatcher "$diretorio/qemu" "$legado"
    gerar_prepare "$diretorio/prepare.sh"
    gerar_start "$diretorio/start.sh"
    gerar_release "$diretorio/release.sh"
    printf 'vm-passthrough gate obrigatório para %s\n' "$VM_NAME" > "$diretorio/required"
    printf 'transação de instalação em andamento para %s\n' "$VM_NAME" > "$diretorio/installing"
    cat > "$diretorio/installing.sh" <<'BLOQUEIO'
#!/bin/bash
echo "[hook install] configuração de passthrough em transação; evento bloqueado" >&2
exit 75
BLOQUEIO
    chmod 0755 "$diretorio/qemu" "$diretorio/prepare.sh" "$diretorio/start.sh" "$diretorio/release.sh" "$diretorio/installing.sh"
    chmod 0644 "$diretorio/required" "$diretorio/installing"
    local arquivo
    for arquivo in "$diretorio/qemu" "$diretorio/prepare.sh" "$diretorio/start.sh" "$diretorio/release.sh" "$diretorio/installing.sh"; do
        bash -n "$arquivo" || return 1
    done
}

validar_config_hooks
if [ "${1:-}" = "--renderizar-hooks" ]; then
    [ -n "${2:-}" ] && [ -d "$2" ] || falhar "Uso: $0 --renderizar-hooks DIRETORIO_EXISTENTE"
    caminho_absoluto_seguro "$2" || falhar "Diretório de renderização inseguro: $2"
    HD1_IDENTIDADE="TESTE-ID_SERIAL=renderizacao"
    gerar_conjunto_hooks "$2" ""
    ok "Hooks renderizados e aprovados em bash -n: $2"
    exit 0
fi

exigir_nao_root
exigir_sudo
exigir_comando xmlstarlet virsh udevadm lsblk findmnt flock
exigir_vm_desligada "$VM_NAME"
exigir_conf IOMMU_GROUP_GPU
validar_grupo_iommu_gpu \
    "$GPU_PCI_ID" "${GPU_AUDIO_PCI_ID:-}" "$IOMMU_GROUP_GPU" \
    "$GPU_VENDOR_DEVICE_ID" "${GPU_AUDIO_VENDOR_DEVICE_ID:-}" \
    || falhar "$IOMMU_ERRO"

titulo "Capítulo 19: hooks dinâmicos e HD1 físico (VM: $VM_NAME)"

# Todos os preflights ocorrem antes da primeira mutação.
HD1_IDENTIDADE=""
if [ -n "${HD1_BY_ID_PATH:-}" ]; then
    validar_disco_fisico_vm "$HD1_BY_ID_PATH" "${NVME_DEVICE:-}" "${HD2_DISCO_PAI:-}" \
        || falhar "$DISCO_VM_ERRO"
    ALVO_HD1="$DISCO_VM_ALVO"
    PROPRIEDADES_HD1="$(udevadm info --query=property --name "$ALVO_HD1" 2>/dev/null)" \
        || falhar "Não foi possível consultar a identidade udev de $ALVO_HD1."
    for CHAVE_ID in ID_WWN_WITH_EXTENSION ID_WWN ID_SERIAL; do
        HD1_IDENTIDADE="$(awk -F= -v k="$CHAVE_ID" '$1 == k && length($2) {print k "=" substr($0, index($0,"=")+1); exit}' \
            <<< "$PROPRIEDADES_HD1")"
        [ -z "$HD1_IDENTIDADE" ] || break
    done
    [ -n "$HD1_IDENTIDADE" ] || falhar "HD1 não possui WWN/serial estável para validar em todo start."
    echo "Disco físico autorizado após preflight: $HD1_BY_ID_PATH -> $ALVO_HD1"
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL "$ALVO_HD1"
fi

for ENDERECO in "$GPU_PCI_ID" ${GPU_AUDIO_PCI_ID:+"$GPU_AUDIO_PCI_ID"}; do
    hostdev_estado_xml "$ENDERECO" || falhar "Não foi possível inspecionar hostdev $ENDERECO."
    if [ "$HOSTDEV_TOTAL" != 0 ] && { [ "$HOSTDEV_TOTAL" != 1 ] || [ "$HOSTDEV_EXATO" != 1 ]; }; then
        falhar "O XML já contém $ENDERECO duplicado ou sem managed='yes'; corrija antes de continuar."
    fi
done
if [ -n "${HD1_BY_ID_PATH:-}" ]; then
    disco_estado_xml "$HD1_BY_ID_PATH" || falhar "Não foi possível inspecionar o HD1 no XML."
    if [ "$DISCO_XML_SOURCE" != 0 ] && { [ "$DISCO_XML_SOURCE" != 1 ] || [ "$DISCO_XML_EXATO" != 1 ]; }; then
        falhar "O XML contém o HD1 com atributos divergentes/duplicados; revisão manual necessária."
    fi
    if [ "$DISCO_XML_SOURCE" = 0 ] && [ "$DISCO_XML_VDB" != 0 ]; then
        falhar "O alvo vdb já pertence a outro disco no XML; não será substituído."
    fi
fi

echo
cat <<'ORIENTACAO'
Resumo antes de aplicar:
  - finalidade: entregar GPU/áudio à VM com hooks transacionais do libvirt;
  - pré-requisitos: VM desligada, IOMMU/preflights aprovados e acesso por TTY;
  - HD1: totalmente opcional; a opção 0 mantém somente o QCOW2;
  - alterações: hooks do host e XML persistente; não exige reboot do host;
  - recomendação/risco: valide primeiro o Windows no QCOW2 e tenha backup do HD1;
  - retorno: falha ou cancelamento restaura a transação; se houver HD1, cancelar
    a segunda confirmação ANEXAR também restaura automaticamente hooks e XML.
ORIENTACAO

titulo "Confirmação antes de alterar hooks e XML"
info "Todos os preflights terminaram. Até este ponto, hooks e XML da VM não foram alterados."
info "A etapa instalará/atualizará hooks do libvirt e anexará GPU/áudio ao XML persistente da VM."
if [ -n "${HD1_BY_ID_PATH:-}" ]; then
    echo "Disco físico que também será autorizado:"
    lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL "$ALVO_HD1"
    aviso "PERDA DE DADOS: o Windows terá escrita no DISCO INTEIRO acima e em todas as suas partições."
    aviso "O script não o formata, mas inicializar, reparticionar, formatar ou instalar o Windows"
    aviso "nesse disco pode destruir todos os dados. Confirme que existe backup verificado."
    aviso "Conclua antes a instalação do Windows no QCOW2 e nunca selecione este HD físico como destino do instalador."
else
    info "Opção 0 registrada: nenhum disco físico será anexado; a VM permanecerá somente com o QCOW2."
fi
confirmar_digitando APLICAR \
    "Aplicar agora as alterações de hooks e XML descritas acima?" \
    || cancelar_etapa "Aplicação cancelada antes da primeira alteração persistente."

XML_ANTES="$(mktemp)" || falhar "Não foi possível criar backup temporário do XML."
$VIRSH dumpxml --inactive "$VM_NAME" > "$XML_ANTES" || falhar "Não foi possível capturar XML original."
xml_backup "$VM_NAME"

# Nenhum sibling/legado desconhecido pode continuar gerindo PCI em paralelo ao
# hostdev managed='yes'. Hooks antigos deste próprio projeto são migrados abaixo.
HOOKS_EXISTENTES=()
for HOOK_ANTIGO in "$PREPARE_ANTIGO" "$RELEASE_ANTIGO"; do
    if sudo test -e "$HOOK_ANTIGO"; then
        sudo test ! -L "$HOOK_ANTIGO" || falhar "Hook antigo é link simbólico: $HOOK_ANTIGO"
        sudo grep -qF 'gerado por etapas/50-hooks-gpu-hd1.sh' "$HOOK_ANTIGO" \
            || falhar "Arquivo desconhecido ocupa o nome de um hook antigo: $HOOK_ANTIGO"
    fi
done
if sudo test -d "$HOOK_BASE"; then
    HOOK_LISTA="$(mktemp)" || falhar "Não foi possível criar inventário temporário de hooks."
    if ! sudo find "$HOOK_BASE" -mindepth 1 \( -type f -o -type l \) -print0 > "$HOOK_LISTA"; then
        rm -f -- "$HOOK_LISTA"
        falhar "Não foi possível enumerar integralmente os hooks existentes."
    fi
    mapfile -d '' -t HOOKS_EXISTENTES < "$HOOK_LISTA"
    rm -f -- "$HOOK_LISTA"
fi
for HOOK_EXISTENTE in "${HOOKS_EXISTENTES[@]}"; do
    sudo test ! -L "$HOOK_EXISTENTE" \
        || falhar "Link simbólico dentro de qemu.d é recusado: $HOOK_EXISTENTE"
    sudo test -f "$HOOK_EXISTENTE" \
        || falhar "Entrada não regular dentro de qemu.d: $HOOK_EXISTENTE"
    [ "$(sudo stat -c %u -- "$HOOK_EXISTENTE")" -eq 0 ] \
        || falhar "Hook existente não pertence ao root: $HOOK_EXISTENTE"
    if sudo find "$HOOK_EXISTENTE" -maxdepth 0 -perm /022 -print -quit | grep -q .; then
        falhar "Hook existente é gravável por grupo/outros: $HOOK_EXISTENTE"
    fi
    case "$HOOK_EXISTENTE" in
        "$PREPARE"|"$START"|"$RELEASE") continue ;;
        "$PREPARE_ANTIGO")
            sudo grep -qF '01-gpu-para-vfio.sh (gerado por etapas/50-hooks-gpu-hd1.sh)' "$HOOK_EXISTENTE" \
                || falhar "Arquivo desconhecido ocupa o nome do hook antigo: $HOOK_EXISTENTE"
            continue
            ;;
        "$RELEASE_ANTIGO")
            sudo grep -qF '01-gpu-para-linux.sh (gerado por etapas/50-hooks-gpu-hd1.sh)' "$HOOK_EXISTENTE" \
                || falhar "Arquivo desconhecido ocupa o nome do hook antigo: $HOOK_EXISTENTE"
            continue
            ;;
    esac
    if sudo grep -Eq '/sys/bus/pci|nodedev-(detach|reattach)|vfio-pci/(bind|unbind|new_id)|driver/unbind' "$HOOK_EXISTENTE"; then
        falhar "Hook adicional tenta gerir PCI e conflita com managed='yes': $HOOK_EXISTENTE"
    fi
done

titulo "1/4 Dispatcher e hooks transacionais"
LEGADO=""
INSTALAR_DISPATCHER=1
if sudo test -e "$HOOK_QEMU" || sudo test -L "$HOOK_QEMU"; then
    sudo test ! -L "$HOOK_QEMU" || falhar "Hook global é link simbólico; adoção recusada: $HOOK_QEMU"
    sudo test -f "$HOOK_QEMU" || falhar "Hook global existente não é arquivo regular: $HOOK_QEMU"
    [ "$(sudo stat -c %u -- "$HOOK_QEMU")" -eq 0 ] \
        || falhar "Hook global existente não pertence ao root: $HOOK_QEMU"
    if sudo find "$HOOK_QEMU" -maxdepth 0 -perm /022 -print -quit | grep -q .; then
        falhar "Hook global existente é gravável por grupo/outros; adoção recusada."
    fi
    sudo bash -n "$HOOK_QEMU" || falhar "Hook global existente tem sintaxe inválida; não será substituído."
    if sudo grep -qF "$MARCADOR_DISPATCHER" "$HOOK_QEMU"; then
        LEGACY_DECLARACAO="$(sudo grep -E '^LEGACY_HOOK=' "$HOOK_QEMU")" \
            || falhar "Dispatcher gerenciado não contém LEGACY_HOOK."
        [ "$(sudo grep -Ec '^LEGACY_HOOK=' "$HOOK_QEMU")" -eq 1 ] \
            || falhar "Dispatcher gerenciado contém LEGACY_HOOK ambíguo."
        _decodificar_literal_conf "${LEGACY_DECLARACAO#LEGACY_HOOK=}" \
            || falhar "LEGACY_HOOK do dispatcher gerenciado é inválido."
        LEGADO="$REPLY"
        if [ -n "$LEGADO" ]; then
            caminho_absoluto_seguro "$LEGADO" \
                || falhar "LEGACY_HOOK inseguro no dispatcher existente."
            sudo test -f "$LEGADO" && sudo test ! -L "$LEGADO" \
                || falhar "LEGACY_HOOK preservado não é arquivo regular seguro: $LEGADO"
            [ "$(sudo stat -c %u -- "$LEGADO")" -eq 0 ] \
                || falhar "LEGACY_HOOK preservado não pertence ao root."
            if sudo find "$LEGADO" -maxdepth 0 -perm /022 -print -quit | grep -q .; then
                falhar "LEGACY_HOOK preservado é gravável por grupo/outros."
            fi
        fi
        info "Dispatcher v2 já gerenciado; será atualizado atomicamente para a versão atual."
    elif sudo grep -qF '/etc/libvirt/hooks/qemu.d' "$HOOK_QEMU"; then
        if sudo grep -qF 'Dispatcher principal de hooks do libvirt para objetos QEMU.' "$HOOK_QEMU"; then
            BACKUP_DISPATCHER_ANTIGO="${HOOK_QEMU}.pre-vm-passthrough-${STAMP}"
            sudo cp -a -- "$HOOK_QEMU" "$BACKUP_DISPATCHER_ANTIGO" \
                || falhar "Não foi possível preservar o dispatcher antigo."
            info "Dispatcher antigo reconhecido e arquivado em: $BACKUP_DISPATCHER_ANTIGO"
        else
            falhar "Dispatcher qemu.d não gerenciado já existe. Integração automática recusada para evitar execução dupla."
        fi
    else
        if sudo grep -Eq '/sys/bus/pci|nodedev-(detach|reattach)|vfio-pci/(bind|unbind|new_id)|driver/unbind' "$HOOK_QEMU"; then
            falhar "Hook global legado gere PCI diretamente; migração automática recusada para manter managed='yes' como única autoridade."
        fi
        LEGADO="${HOOK_QEMU}.pre-vm-passthrough-${STAMP}"
        sudo cp -a -- "$HOOK_QEMU" "$LEGADO" || falhar "Não foi possível preservar o hook global existente."
        info "Hook legado preservado em: $LEGADO"
    fi
fi
RENDER_DIR="$(mktemp -d)" || falhar "Não foi possível criar diretório de renderização."
limpar_temporarios() {
    rm -rf -- "$RENDER_DIR"
    rm -f -- "$XML_ANTES"
    encerrar_sudo_keepalive
}
trap limpar_temporarios EXIT
gerar_conjunto_hooks "$RENDER_DIR" "$LEGADO" || falhar "Hooks gerados não passaram em bash -n."

DESTINOS=()
BACKUPS=()
EXISTIAM=()
BACKUP_ROOT="/etc/libvirt/hooks/.vm-passthrough-backups/$STAMP"
TRANSACAO_ATIVA=0
XML_MUTADO=0
PRESERVAR_XML=0
instalar_root_atomico() {
    local origem="$1" destino="$2" diretorio temporario
    diretorio="$(dirname "$destino")"
    sudo install -d -o root -g root -m 0755 "$diretorio" || return 1
    sudo test ! -L "$destino" || return 1
    temporario="$(sudo mktemp "${destino}.tmp.XXXXXX")" || return 1
    if ! sudo install -o root -g root -m 0755 "$origem" "$temporario" \
       || ! sudo bash -n "$temporario"; then
        sudo rm -f -- "$temporario"
        return 1
    fi
    sudo mv -fT -- "$temporario" "$destino" || { sudo rm -f -- "$temporario"; return 1; }
}
instalar_dado_root_atomico() {
    local origem="$1" destino="$2" diretorio temporario
    diretorio="$(dirname "$destino")"
    sudo install -d -o root -g root -m 0755 "$diretorio" || return 1
    sudo test ! -L "$destino" || return 1
    temporario="$(sudo mktemp "${destino}.tmp.XXXXXX")" || return 1
    if ! sudo install -o root -g root -m 0644 "$origem" "$temporario"; then
        sudo rm -f -- "$temporario"
        return 1
    fi
    sudo mv -fT -- "$temporario" "$destino" || { sudo rm -f -- "$temporario"; return 1; }
}
registrar_backup_destino() {
    local destino="$1" backup="" existia=0
    sudo test ! -L "$destino" || return 1
    if sudo test -e "$destino"; then
        sudo install -d -o root -g root -m 0700 "$BACKUP_ROOT" || return 1
        backup="$BACKUP_ROOT/${#DESTINOS[@]}-$(basename "$destino")"
        sudo cp -a -- "$destino" "$backup" || return 1
        existia=1
    fi
    DESTINOS+=("$destino")
    BACKUPS+=("$backup")
    EXISTIAM+=("$existia")
}
instalar_com_backup() {
    local origem="$1" destino="$2"
    registrar_backup_destino "$destino" || return 1
    instalar_root_atomico "$origem" "$destino"
}
instalar_dado_com_backup() {
    local origem="$1" destino="$2"
    registrar_backup_destino "$destino" || return 1
    instalar_dado_root_atomico "$origem" "$destino"
}
remover_com_backup() {
    local destino="$1"
    sudo test -e "$destino" || return 0
    registrar_backup_destino "$destino" || return 1
    sudo rm -f -- "$destino"
}
rollback_hooks() {
    local i falhou=0
    erro "Revertendo arquivos de hook instalados nesta execução..."
    for ((i=${#DESTINOS[@]}-1; i>=0; i--)); do
        if [ "${EXISTIAM[$i]}" -eq 1 ]; then
            if ! sudo cp -a -- "${BACKUPS[$i]}" "${DESTINOS[$i]}"; then
                erro "Falha ao restaurar ${DESTINOS[$i]}"
                falhou=1
            fi
        elif ! sudo rm -f -- "${DESTINOS[$i]}"; then
            erro "Falha ao remover ${DESTINOS[$i]}"
            falhou=1
        fi
    done
    [ "$falhou" -eq 0 ]
}
rollback_total() {
    local falhou=0
    set +e
    if [ "$XML_MUTADO" -eq 1 ]; then
        $VIRSH define "$XML_ANTES" >/dev/null \
            || { erro "Falha ao restaurar XML original: $XML_ANTES"; falhou=1; }
    fi
    rollback_hooks || falhou=1
    sudo systemctl restart libvirtd \
        || { erro "Hooks foram revertidos, mas libvirtd não reiniciou. Não inicie VMs."; falhou=1; }
    if [ "$falhou" -ne 0 ]; then
        PRESERVAR_XML=1
        return 1
    fi
    return 0
}
finalizar_transacao() {
    local rc=$?
    trap - EXIT INT TERM
    if [ "$TRANSACAO_ATIVA" -eq 1 ]; then
        rollback_total || erro "Rollback incompleto; backups foram preservados para recuperação manual."
    fi
    rm -rf -- "$RENDER_DIR"
    if [ "$PRESERVAR_XML" -eq 0 ]; then
        rm -f -- "$XML_ANTES"
    else
        erro "XML original preservado em: $XML_ANTES"
    fi
    encerrar_sudo_keepalive
    exit "$rc"
}
trap finalizar_transacao EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
TRANSACAO_ATIVA=1

instalar_dado_com_backup "$RENDER_DIR/installing" "$INSTALLING_MARKER" \
    || falhar "Falha ao publicar marcador de transação."
instalar_com_backup "$RENDER_DIR/installing.sh" "$INSTALLING_HOOK" \
    || falhar "Falha ao publicar hook de bloqueio durante a transação."
if [ "$INSTALAR_DISPATCHER" -eq 1 ]; then
    instalar_com_backup "$RENDER_DIR/qemu" "$HOOK_QEMU" \
        || falhar "Falha ao instalar dispatcher atomicamente."
fi
instalar_dado_com_backup "$RENDER_DIR/required" "$GATE_REQUIRED" \
    || falhar "Falha ao instalar marcador fail-closed do gate."
instalar_com_backup "$RENDER_DIR/prepare.sh" "$PREPARE" \
    || falhar "Falha ao instalar prepare/begin."
instalar_com_backup "$RENDER_DIR/start.sh" "$START" \
    || falhar "Falha ao instalar start/begin."
instalar_com_backup "$RENDER_DIR/release.sh" "$RELEASE" \
    || falhar "Falha ao instalar release/end."
remover_com_backup "$PREPARE_ANTIGO" \
    || falhar "Falha ao migrar o hook prepare antigo."
remover_com_backup "$RELEASE_ANTIGO" \
    || falhar "Falha ao migrar o hook release antigo."

if ! sudo systemctl restart libvirtd || ! sudo systemctl is-active --quiet libvirtd; then
    falhar "libvirtd não aceitou a instalação; a transação restaurará os hooks anteriores."
fi
ok "Dispatcher e três hooks instalados atomicamente; falhas agora abortam o evento libvirt."

titulo "2/4 GPU e áudio no XML com managed='yes'"

anexar_hostdev_pci() {
    local endereco="${1,,}" dom bus slot func arquivo
    hostdev_estado_xml "$endereco" || return 1
    if [ "$HOSTDEV_TOTAL" = 1 ] && [ "$HOSTDEV_EXATO" = 1 ]; then
        info "hostdev $endereco já está correto; preservado."
        return 0
    fi
    [ "$HOSTDEV_TOTAL" = 0 ] || return 1
    IFS=':.' read -r dom bus slot func <<< "$endereco"
    arquivo="$(mktemp)" || return 1
    cat > "$arquivo" <<XML
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x$dom' bus='0x$bus' slot='0x$slot' function='0x$func'/>
  </source>
</hostdev>
XML
    XML_MUTADO=1
    if ! $VIRSH attach-device "$VM_NAME" "$arquivo" --config; then
        rm -f -- "$arquivo"
        return 1
    fi
    rm -f -- "$arquivo"
    hostdev_estado_xml "$endereco" \
        && [ "$HOSTDEV_TOTAL" = 1 ] && [ "$HOSTDEV_EXATO" = 1 ]
}

XML_FALHOU=0
anexar_hostdev_pci "$GPU_PCI_ID" || XML_FALHOU=1
if [ "$XML_FALHOU" -eq 0 ] && [ -n "${GPU_AUDIO_PCI_ID:-}" ]; then
    anexar_hostdev_pci "$GPU_AUDIO_PCI_ID" || XML_FALHOU=1
fi
if [ "$XML_FALHOU" -ne 0 ]; then
    falhar "Não foi possível anexar GPU/áudio com pós-condição exata; a transação restaurará XML e hooks."
fi
ok "GPU e áudio configurados sob gestão exclusiva do libvirt."

titulo "3/4 Disco físico no XML (opcional)"
anexar_hd1() {
    local arquivo
    [ -n "${HD1_BY_ID_PATH:-}" ] || { info "Fluxo sem HD1 físico; somente QCOW2."; return 0; }
    disco_estado_xml "$HD1_BY_ID_PATH" || return 1
    if [ "$DISCO_XML_SOURCE" = 1 ] && [ "$DISCO_XML_EXATO" = 1 ]; then
        info "HD1 já está correto no XML; preflight foi repetido e aprovado."
        return 0
    fi
    [ "$DISCO_XML_SOURCE" = 0 ] && [ "$DISCO_XML_VDB" = 0 ] || return 1
    echo "Revisão final do disco antes do attach:"
    lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL "$ALVO_HD1" || return 1
    aviso "PERDA DE DADOS: este attach concede ao Windows escrita no disco inteiro e em todas as partições."
    aviso "Não inicialize, reparticione nem formate o disco no Windows se deseja preservar os dados existentes."
    confirmar_digitando ANEXAR \
        "Entregar $HD1_BY_ID_PATH ($ALVO_HD1, $HD1_IDENTIDADE) à VM?" \
        || return "$CODIGO_VOLTAR_MENU"
    arquivo="$(mktemp)" || return 1
    cat > "$arquivo" <<XML
<disk type='block' device='disk'>
  <driver name='qemu' type='raw' cache='none'/>
  <source dev='$HD1_BY_ID_PATH'/>
  <target dev='vdb' bus='virtio'/>
</disk>
XML
    XML_MUTADO=1
    if ! $VIRSH attach-device "$VM_NAME" "$arquivo" --config; then
        rm -f -- "$arquivo"
        return 1
    fi
    rm -f -- "$arquivo"
    disco_estado_xml "$HD1_BY_ID_PATH" \
        && [ "$DISCO_XML_SOURCE" = 1 ] && [ "$DISCO_XML_EXATO" = 1 ]
}
if anexar_hd1; then
    :
else
    ANEXAR_RC=$?
    if [ "$ANEXAR_RC" -eq "$CODIGO_VOLTAR_MENU" ]; then
        aviso "Attach cancelado; a transação restaurará automaticamente hooks e XML anteriores."
        exit "$CODIGO_VOLTAR_MENU"
    fi
    falhar "HD1 não foi anexado com segurança; a transação restaurará XML e hooks."
fi
exigir_vm_desligada "$VM_NAME"
remover_com_backup "$INSTALLING_HOOK" \
    || falhar "Falha ao retirar o bloqueio temporário de start."
remover_com_backup "$INSTALLING_MARKER" \
    || falhar "Falha ao retirar o marcador temporário de transação."
TRANSACAO_ATIVA=0
rm -f -- "$XML_ANTES"
ok "Configuração persistente de dispositivos validada."

titulo "4/4 Opções de vídeo/hypervisor"
if [ "${1:-}" = "--remover-video" ] || [ "${2:-}" = "--remover-video" ]; then
    aviso "Remova o vídeo virtual somente após validar um boot completo com passthrough."
    if confirmar_digitando REMOVER "A saída gráfica virtual QXL/SPICE será removida."; then
        TMPX="$(mktemp)"
        $VIRSH dumpxml --inactive "$VM_NAME" > "$TMPX"
        xmlstarlet ed -L \
            -d '/domain/devices/graphics' -d '/domain/devices/video' \
            -d "/domain/devices/channel[@type='spicevmc']" -d '/domain/devices/redirdev' \
            -d '/domain/devices/sound' -d '/domain/devices/audio' "$TMPX"
        $VIRSH define "$TMPX"
        rm -f -- "$TMPX"
        ok "Vídeo virtual removido."
    fi
fi
if [ "${1:-}" = "--anti-code43" ] || [ "${2:-}" = "--anti-code43" ]; then
    TMPX="$(mktemp)"
    $VIRSH dumpxml --inactive "$VM_NAME" > "$TMPX"
    xmlstarlet sel -t -c '/domain/features/hyperv' "$TMPX" >/dev/null 2>&1 \
        || xmlstarlet ed -L -s '/domain/features' -t elem -n hyperv -v '' "$TMPX"
    xmlstarlet ed -L -d '/domain/features/hyperv/vendor_id' "$TMPX"
    xmlstarlet ed -L -s '/domain/features/hyperv' -t elem -n vendor_id -v '' "$TMPX"
    xmlstarlet ed -L -i '/domain/features/hyperv/vendor_id' -t attr -n state -v on "$TMPX"
    xmlstarlet ed -L -i '/domain/features/hyperv/vendor_id' -t attr -n value -v randomid123 "$TMPX"
    xmlstarlet sel -t -c '/domain/features/kvm' "$TMPX" >/dev/null 2>&1 \
        || xmlstarlet ed -L -s '/domain/features' -t elem -n kvm -v '' "$TMPX"
    xmlstarlet ed -L -d '/domain/features/kvm/hidden' "$TMPX"
    xmlstarlet ed -L -s '/domain/features/kvm' -t elem -n hidden -v '' "$TMPX"
    xmlstarlet ed -L -i '/domain/features/kvm/hidden' -t attr -n state -v on "$TMPX"
    $VIRSH define "$TMPX"
    rm -f -- "$TMPX"
    ok "Ocultação de hypervisor aplicada."
fi

cat <<'RECUPERACAO'

Recuperação e reversão:
  - falha/sinal ou cancelamento de ANEXAR durante a transação: rollback automático;
  - GPU não restaurada ao host: use um TTY e execute bash util/recuperar-gpu.sh;
  - após sucesso não há --desfazer: restaure o backup XML informado e, se
    necessário, os hooks em /etc/libvirt/hooks/.vm-passthrough-backups/.
  O utilitário de recuperação da GPU não desfaz o XML nem os hooks persistentes.
RECUPERACAO

cat <<TESTE

Como testar manualmente somente após backup e janela de manutenção:
  1. bash etapas/50-hooks-gpu-hd1.sh --verificar
  2. virsh --connect qemu:///system start $VM_NAME
  3. sudo journalctl -u libvirtd -e | grep -i hook
  4. Desligar o Windows e confirmar GPU em nvidia e $DM_SERVICE ativo.
Se a restauração falhar, use um TTY e rode: bash util/recuperar-gpu.sh
TESTE
ok "Etapa 50 concluída sem executar o primeiro start da VM."
