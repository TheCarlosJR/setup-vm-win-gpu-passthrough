#!/bin/bash
# ============================================================================
# etapas/30-iommu-vfio.sh - Capítulo 16: IOMMU e VFIO
# ============================================================================
# Reconcilia, em etapas independentes, os parâmetros do kernel, a carga dos
# módulos VFIO e o estado efetivo do grupo IOMMU. A GPU única NÃO é capturada
# no boot: sua troca de driver continua sendo responsabilidade dos hooks da
# etapa 50.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

VFIO_CONF="/etc/modules-load.d/vfio.conf"
MODULOS_VFIO=(vfio vfio_pci vfio_iommu_type1)
GRUPO_RUNTIME=""

conteudo_vfio_conf() {
    printf '%s\n' "${MODULOS_VFIO[@]}"
}

vfio_conf_correto() {
    [ -f "$VFIO_CONF" ] && cmp -s <(conteudo_vfio_conf) "$VFIO_CONF"
}

parametro_iommu_persistente() {
    local parametro="$1" palavra
    case "${BOOTLOADER:-}" in
        kernelstub)
            [ -r /etc/kernelstub/configuration ] \
                && grep -Eq "(^|[\"[:space:]])${parametro//./\\.}([\"[:space:],]|$)" /etc/kernelstub/configuration
            ;;
        grub)
            while IFS= read -r palavra; do
                [ "$palavra" = "$parametro" ] && return 0
            done < <(_grub_cmdline_atual 2>/dev/null | tr ' ' '\n')
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

capturas_gpu_no_boot() {
    local padrao captura arquivo
    [ -n "${GPU_VENDOR_DEVICE_ID:-}" ] || return 1
    [ -n "${GPU_AUDIO_VENDOR_DEVICE_ID:-}" ] || return 1
    padrao="${GPU_VENDOR_DEVICE_ID}|${GPU_AUDIO_VENDOR_DEVICE_ID}"

    captura=""
    if grep -Eqi '(^|[[:space:]])vfio-pci\.ids=' /proc/cmdline 2>/dev/null \
        && grep -Eqi "$padrao" /proc/cmdline; then
        captura="/proc/cmdline: $(cat /proc/cmdline)"
    fi

    shopt -s nullglob
    for arquivo in /etc/modprobe.d/*.conf /etc/default/grub /etc/kernelstub/configuration; do
        [ -f "$arquivo" ] || continue
        while IFS= read -r linha; do
            captura+="${captura:+$'\n'}${arquivo}:${linha}"
        done < <(grep -Ein "(vfio-pci\.ids=|options[[:space:]]+vfio-pci.*ids=).*(${padrao})" "$arquivo" 2>/dev/null || true)
    done
    shopt -u nullglob

    [ -n "$captura" ] || return 1
    printf '%s\n' "$captura"
}

modulos_vfio_carregados() {
    local modulo
    for modulo in "${MODULOS_VFIO[@]}"; do
        grep -q "^${modulo}[[:space:]]" /proc/modules 2>/dev/null || return 1
    done
}

validar_grupo_gpu() {
    local gpu="${GPU_PCI_ID:-}" audio="${GPU_AUDIO_PCI_ID:-}"
    local link_gpu link_audio grupo_gpu grupo_audio dev endereco descricao
    local -a estranhos=()

    [ -n "$gpu" ] && [ -n "$audio" ] || return 1
    [ -d "/sys/bus/pci/devices/$gpu" ] || return 1
    [ -d "/sys/bus/pci/devices/$audio" ] || return 1

    link_gpu="/sys/bus/pci/devices/$gpu/iommu_group"
    link_audio="/sys/bus/pci/devices/$audio/iommu_group"
    [ -e "$link_gpu" ] && [ -e "$link_audio" ] || return 1

    grupo_gpu="$(basename "$(readlink -f "$link_gpu")")"
    grupo_audio="$(basename "$(readlink -f "$link_audio")")"
    [ -n "$grupo_gpu" ] && [ "$grupo_gpu" = "$grupo_audio" ] || return 1
    [ -d "/sys/kernel/iommu_groups/$grupo_gpu/devices" ] || return 1

    shopt -s nullglob
    local -a dispositivos=("/sys/kernel/iommu_groups/$grupo_gpu/devices/"*)
    shopt -u nullglob
    [ "${#dispositivos[@]}" -gt 0 ] || return 1

    for dev in "${dispositivos[@]}"; do
        endereco="$(basename "$dev")"
        [ "$endereco" = "$gpu" ] && continue
        [ "$endereco" = "$audio" ] && continue
        descricao="$(LC_ALL=C lspci -nns "${endereco#0000:}" 2>/dev/null || true)"
        if [ -z "$descricao" ] || ! grep -q '\[0604\]' <<< "$descricao"; then
            estranhos+=("$endereco${descricao:+ ($descricao)}")
        fi
    done

    if [ "${#estranhos[@]}" -gt 0 ]; then
        erro "O grupo IOMMU $grupo_gpu contém endpoint(s) além da GPU e do áudio:"
        printf '  - %s\n' "${estranhos[@]}" >&2
        return 1
    fi

    GRUPO_RUNTIME="$grupo_gpu"
    return 0
}

verificar() {
    local modulo capturas=""

    if cmdline_tem "amd_iommu=on" && cmdline_tem "iommu=pt"; then
        v_ok "Parâmetros amd_iommu=on e iommu=pt ativos."
    else
        v_falta "Parâmetros de IOMMU ausentes no kernel em execução."
    fi

    if parametro_iommu_persistente "amd_iommu=on" \
        && parametro_iommu_persistente "iommu=pt"; then
        v_ok "Parâmetros de IOMMU persistidos no $BOOTLOADER."
    else
        v_falta "Parâmetros de IOMMU não estão persistidos no bootloader configurado."
    fi

    if vfio_conf_correto; then
        v_ok "$VFIO_CONF contém exatamente os módulos esperados."
    else
        v_falta "$VFIO_CONF ausente ou divergente."
    fi

    if capturas="$(capturas_gpu_no_boot 2>/dev/null)"; then
        v_falta "Configuração externa tenta capturar a GPU no boot: $capturas"
    else
        v_ok "GPU não está configurada para captura VFIO no boot."
    fi

    for modulo in "${MODULOS_VFIO[@]}"; do
        if grep -q "^${modulo}[[:space:]]" /proc/modules 2>/dev/null; then
            v_ok "Módulo $modulo carregado."
        else
            v_falta "Módulo $modulo não carregado."
        fi
    done

    if validar_grupo_gpu; then
        v_ok "GPU e áudio isolados juntos no grupo IOMMU $GRUPO_RUNTIME."
        if [ "${IOMMU_GROUP_GPU:-}" = "$GRUPO_RUNTIME" ]; then
            v_ok "IOMMU_GROUP_GPU corresponde ao estado atual."
        else
            v_falta "IOMMU_GROUP_GPU não corresponde ao grupo atual ($GRUPO_RUNTIME)."
        fi
    else
        v_falta "Grupo IOMMU da GPU ausente, divergente ou contém outro endpoint."
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

exigir_nao_root
exigir_sudo
exigir_comando lspci cmp
exigir_conf BOOTLOADER GPU_PCI_ID GPU_AUDIO_PCI_ID \
            GPU_VENDOR_DEVICE_ID GPU_AUDIO_VENDOR_DEVICE_ID

titulo "Capítulo 16: IOMMU e VFIO"

CAPTURAS=""
if CAPTURAS="$(capturas_gpu_no_boot)"; then
    erro "Foi encontrada configuração que captura esta GPU no boot:"
    printf '%s\n' "$CAPTURAS" >&2
    falhar "Remova essa configuração manualmente antes de usar o fluxo dinâmico de GPU única."
fi

PRECISA_REBOOT=0
if ! parametro_iommu_persistente "amd_iommu=on" \
    || ! parametro_iommu_persistente "iommu=pt"; then
    titulo "Aplicando parâmetros persistentes de IOMMU"
    kernel_param_add "amd_iommu=on iommu=pt"
fi
if ! cmdline_tem "amd_iommu=on" || ! cmdline_tem "iommu=pt"; then
    PRECISA_REBOOT=1
else
    ok "Parâmetros de IOMMU já estão ativos no kernel em execução."
fi

if ! vfio_conf_correto; then
    titulo "Reconciliando módulos VFIO"
    TMP_VFIO="$(mktemp)"
    trap 'rm -f "${TMP_VFIO:-}"' EXIT
    conteudo_vfio_conf > "$TMP_VFIO"
    if [ -e "$VFIO_CONF" ]; then
        BACKUP_VFIO="${VFIO_CONF}.bak-$(date +%Y%m%d-%H%M%S)"
        sudo cp -- "$VFIO_CONF" "$BACKUP_VFIO"
        info "Backup criado: $BACKUP_VFIO"
    fi
    sudo install -o root -g root -m 0644 "$TMP_VFIO" "$VFIO_CONF"
    rm -f "$TMP_VFIO"
    trap - EXIT
    info "Regenerando initramfs porque a lista de módulos mudou..."
    sudo update-initramfs -u -k all
    PRECISA_REBOOT=1
else
    ok "$VFIO_CONF já está correto."
fi

if [ "$PRECISA_REBOOT" -eq 1 ]; then
    ok "Configuração persistente reconciliada."
    aviso "A validação do grupo só é confiável após reiniciar com este estado."
    pedir_reboot
    exit 0
fi

titulo "Validação pós-reboot"

info "1) /proc/cmdline:"
cat /proc/cmdline
cmdline_tem "amd_iommu=on" || falhar "amd_iommu=on ausente."
cmdline_tem "iommu=pt" || falhar "iommu=pt ausente."

info "2) Inicialização AMD-Vi/IOMMU:"
MENSAGENS_IOMMU="$(sudo dmesg | grep -iE 'AMD-Vi|IOMMU' || true)"
[ -n "$MENSAGENS_IOMMU" ] \
    || falhar "O kernel não registrou AMD-Vi/IOMMU. Revise a BIOS antes de continuar."
head -n 20 <<< "$MENSAGENS_IOMMU"
ok "IOMMU reportado pelo kernel."

info "3) Módulos VFIO:"
for MODULO in "${MODULOS_VFIO[@]}"; do
    if ! grep -q "^${MODULO}[[:space:]]" /proc/modules 2>/dev/null; then
        info "Carregando $MODULO..."
        sudo modprobe "$MODULO" || falhar "Não foi possível carregar $MODULO."
    fi
done
modulos_vfio_carregados || falhar "Nem todos os módulos VFIO esperados estão carregados."
lsmod | grep -E '^vfio(_pci|_iommu_type1)?[[:space:]]'
ok "Todos os módulos VFIO esperados estão carregados."

info "4) Grupo IOMMU da GPU:"
validar_grupo_gpu \
    || falhar "GPU/áudio não formam um grupo IOMMU seguro. Não prossiga para os hooks."
ok "GPU e áudio estão no grupo IOMMU $GRUPO_RUNTIME sem endpoints estranhos."
for DEV in "/sys/kernel/iommu_groups/$GRUPO_RUNTIME/devices/"*; do
    ENDERECO="$(basename "$DEV")"
    LC_ALL=C lspci -nns "${ENDERECO#0000:}" || true
done

if [ -n "${IOMMU_GROUP_GPU:-}" ] && [ "$IOMMU_GROUP_GPU" != "$GRUPO_RUNTIME" ]; then
    aviso "Grupo persistido ($IOMMU_GROUP_GPU) mudou para $GRUPO_RUNTIME; atualizando após validação completa."
fi
salvar_conf IOMMU_GROUP_GPU "$GRUPO_RUNTIME"

info "5) Listagem completa dos grupos:"
mkdir -p "$HOME/inventario-hardware"
RELATORIO="$HOME/inventario-hardware/grupos-iommu-$(date +%Y%m%d-%H%M%S).txt"
bash "$PROJETO_DIR/util/listar-grupos-iommu.sh" | tee "$RELATORIO"
info "Relatório salvo em: $RELATORIO"

echo
ok "Capítulo 16 concluído. GPU pronta para vinculação dinâmica na etapa 50."
