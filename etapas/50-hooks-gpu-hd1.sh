#!/bin/bash
# ============================================================================
# etapas/50-hooks-gpu-hd1.sh - Capítulo 19: GPU Passthrough Dinâmico + HD1
# ============================================================================
# 1. Gera o dispatcher /etc/libvirt/hooks/qemu e os hooks:
#      prepare/begin/01-gpu-para-vfio.sh  (para o display manager, descarrega
#                                          nvidia e vincula a GPU ao vfio-pci)
#      release/end/01-gpu-para-linux.sh   (caminho inverso, devolve a GPU)
#    com os IDs REAIS do passthrough.conf preenchidos (nenhum placeholder).
# 2. Anexa ao XML da VM os dois <hostdev> da GPU (vídeo + áudio HDMI).
# 3. Anexa o HD1 físico como <disk> por caminho estável /dev/disk/by-id.
#
# Flags opcionais:
#   --remover-video   remove o vídeo virtual QXL/SPICE (fazer só APÓS validar
#                     o passthrough; o manual recomenda manter no início)
#   --anti-code43     aplica <kvm><hidden/> e <hyperv><vendor_id/> (Cap. 28)
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

HOOK_QEMU="/etc/libvirt/hooks/qemu"

verificar() {
    [ -n "${VM_NAME:-}" ] || { v_falta "VM_NAME não definido."; v_fim; }
    local prep="/etc/libvirt/hooks/qemu.d/$VM_NAME/prepare/begin/01-gpu-para-vfio.sh"
    local rel="/etc/libvirt/hooks/qemu.d/$VM_NAME/release/end/01-gpu-para-linux.sh"
    [ -x "$HOOK_QEMU" ] && v_ok "Dispatcher instalado." || v_falta "Dispatcher ausente."
    [ -x "$prep" ] && v_ok "Hook prepare/begin instalado." || v_falta "Hook prepare/begin ausente."
    [ -x "$rel" ]  && v_ok "Hook release/end instalado."   || v_falta "Hook release/end ausente."
    if vm_existe "$VM_NAME"; then
        local xml
        xml="$($VIRSH dumpxml --inactive "$VM_NAME" 2>/dev/null)"
        if grep -q "<hostdev" <<< "$xml" && [ -n "${GPU_PCI_ID:-}" ]; then
            v_ok "XML contém hostdev (GPU)."
        else
            v_falta "GPU ainda não anexada ao XML."
        fi
        if [ -z "${HD1_BY_ID_PATH:-}" ]; then
            v_ok "Sem disco físico dedicado à VM (escolha da etapa 02)."
        elif grep -qF "$HD1_BY_ID_PATH" <<< "$xml"; then
            v_ok "Disco físico anexado ao XML."
        else
            v_falta "Disco físico ainda não anexado ao XML."
        fi
    else
        v_falta "VM '$VM_NAME' não existe."
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

exigir_nao_root
exigir_sudo
exigir_comando xmlstarlet virsh
# GPU_AUDIO_* e HD1_BY_ID_PATH são opcionais (etapa 02 permite ficar sem eles)
exigir_conf VM_NAME GPU_PCI_ID GPU_VENDOR_DEVICE_ID DM_SERVICE
exigir_vm_desligada "$VM_NAME"

titulo "Capítulo 19: hooks dinâmicos e HD1 físico (VM: $VM_NAME)"

# ----------------------------------------------------------------------------
# 1. Estrutura de diretórios + dispatcher
# ----------------------------------------------------------------------------
titulo "1/4 Dispatcher de hooks"
sudo mkdir -p "/etc/libvirt/hooks/qemu.d/$VM_NAME/prepare/begin"
sudo mkdir -p "/etc/libvirt/hooks/qemu.d/$VM_NAME/release/end"

sudo tee "$HOOK_QEMU" >/dev/null <<'DISPATCHER'
#!/bin/bash
# /etc/libvirt/hooks/qemu
# Dispatcher principal de hooks do libvirt para objetos QEMU.
# Argumentos recebidos automaticamente pelo libvirtd:
#   $1 = nome da VM
#   $2 = nome do evento    (prepare, start, started, stopped, release)
#   $3 = sub-evento        (begin, end)
#   $4 = argumento extra (nao utilizado aqui)

VM_NAME="$1"
EVENTO="$2"
SUBEVENTO="$3"

DIRETORIO_HOOK="/etc/libvirt/hooks/qemu.d/${VM_NAME}/${EVENTO}/${SUBEVENTO}"

# Se existir um diretorio de scripts para esta combinacao exata de
# VM + evento + sub-evento, executa todos os scripts executaveis
# encontrados nele, em ordem alfabetica.
if [ -d "$DIRETORIO_HOOK" ]; then
    for script in "$DIRETORIO_HOOK"/*; do
        [ -x "$script" ] && "$script" "$VM_NAME" "$EVENTO" "$SUBEVENTO"
    done
fi

exit 0
DISPATCHER
sudo chmod +x "$HOOK_QEMU"
sudo chown root:root "$HOOK_QEMU"
ok "Dispatcher instalado em $HOOK_QEMU"

# ----------------------------------------------------------------------------
# 2. Hooks da GPU (com os valores reais do conf)
# ----------------------------------------------------------------------------
titulo "2/4 Hooks da GPU"
PREPARE="/etc/libvirt/hooks/qemu.d/$VM_NAME/prepare/begin/01-gpu-para-vfio.sh"
RELEASE="/etc/libvirt/hooks/qemu.d/$VM_NAME/release/end/01-gpu-para-linux.sh"

sudo tee "$PREPARE" >/dev/null <<'HOOKA'
#!/bin/bash
# 01-gpu-para-vfio.sh (gerado por etapas/50-hooks-gpu-hd1.sh)
# Executado pelo libvirtd ANTES de o QEMU iniciar a VM.
# Objetivo: liberar a GPU do driver "nvidia" e vincula-la ao "vfio-pci".

set -e   # interrompe imediatamente se um comando critico falhar

# Enderecos PCI dos dispositivos da VM. GPU_AUDIO_PCI pode estar VAZIO quando a
# placa nao expoe funcao de audio HDMI: as listas abaixo sao deliberadamente
# NAO citadas para que o valor vazio simplesmente desapareca do laco.
GPU_PCI="@GPU_PCI@"
GPU_AUDIO_PCI="@GPU_AUDIO_PCI@"
GPU_IDS="@GPU_IDS@"

echo "[hook] Parando o gerenciador de exibicao (@DM@)..."
systemctl stop @DM@

echo "[hook] Aguardando liberacao de sessoes graficas..."
sleep 2

echo "[hook] Descarregando modulos do driver NVIDIA..."
modprobe -r nvidia_uvm     || true
modprobe -r nvidia_drm     || true
modprobe -r nvidia_modeset || true
modprobe -r nvidia         || true

echo "[hook] Vinculando GPU (${GPU_PCI}) ${GPU_AUDIO_PCI:+e audio (${GPU_AUDIO_PCI}) }ao vfio-pci..."
for dispositivo in $GPU_PCI $GPU_AUDIO_PCI; do
    if [ -e "/sys/bus/pci/devices/${dispositivo}/driver" ]; then
        echo "$dispositivo" > "/sys/bus/pci/devices/${dispositivo}/driver/unbind" || true
    fi
done

# new_id aceita UM par por escrita, no formato "vendor device" (espaco, sem
# dois-pontos): escrever "10de:2504,10de:228e" de uma vez e recusado pelo kernel.
for par in $GPU_IDS; do
    printf '%s %s\n' "${par%%:*}" "${par##*:}" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || true
done

for dispositivo in $GPU_PCI $GPU_AUDIO_PCI; do
    echo "$dispositivo" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true
done

echo "[hook] GPU vinculada ao vfio-pci com sucesso."
HOOKA

sudo tee "$RELEASE" >/dev/null <<'HOOKB'
#!/bin/bash
# 01-gpu-para-linux.sh (gerado por etapas/50-hooks-gpu-hd1.sh)
# Executado pelo libvirtd DEPOIS que a VM foi completamente finalizada.
# Objetivo: devolver a GPU ao driver "nvidia" e restaurar o desktop Linux.

set -e

GPU_PCI="@GPU_PCI@"
GPU_AUDIO_PCI="@GPU_AUDIO_PCI@"   # pode ser vazio (placa sem audio HDMI)

echo "[hook] Desvinculando GPU do vfio-pci..."
for dispositivo in $GPU_PCI $GPU_AUDIO_PCI; do
    if [ -e "/sys/bus/pci/devices/${dispositivo}/driver" ]; then
        echo "$dispositivo" > "/sys/bus/pci/devices/${dispositivo}/driver/unbind" || true
    fi
done

echo "[hook] Recarregando o driver NVIDIA..."
modprobe nvidia
modprobe nvidia_modeset
modprobe nvidia_drm
modprobe nvidia_uvm

echo "[hook] Reiniciando o gerenciador de exibicao (@DM@)..."
systemctl start @DM@

echo "[hook] GPU devolvida ao Linux com sucesso."
HOOKB

# Substitui os tokens pelos valores REAIS do passthrough.conf.
# GPU_IDS é uma lista separada por ESPAÇO de pares vendor:device.
GPU_IDS="$GPU_VENDOR_DEVICE_ID${GPU_AUDIO_VENDOR_DEVICE_ID:+ $GPU_AUDIO_VENDOR_DEVICE_ID}"
for ARQ in "$PREPARE" "$RELEASE"; do
    sudo sed -i \
        -e "s|@GPU_PCI@|$GPU_PCI_ID|g" \
        -e "s|@GPU_AUDIO_PCI@|${GPU_AUDIO_PCI_ID:-}|g" \
        -e "s|@GPU_IDS@|$GPU_IDS|g" \
        -e "s|@DM@|$DM_SERVICE|g" \
        "$ARQ"
    sudo chmod +x "$ARQ"
    sudo chown root:root "$ARQ"
done
ok "Hooks gerados com: GPU=$GPU_PCI_ID audio=${GPU_AUDIO_PCI_ID:-(nenhum)} ids='$GPU_IDS' dm=$DM_SERVICE"

# Garantia extra: nenhum token pode ter sobrado
if sudo grep -q "@GPU_PCI@\|@DM@\|@GPU_IDS@" "$PREPARE" "$RELEASE"; then
    falhar "Sobrou token não substituído nos hooks. Revise o passthrough.conf."
fi

info "Reiniciando o libvirtd para reconhecer o novo hook..."
sudo systemctl restart libvirtd

# ----------------------------------------------------------------------------
# 3. Anexar a GPU (vídeo + áudio) ao XML da VM
# ----------------------------------------------------------------------------
titulo "3/4 GPU no XML da VM"
xml_backup "$VM_NAME"

anexar_hostdev_pci() {
    local endereco="$1" dom bus slot func tmp existe
    IFS=':.' read -r dom bus slot func <<< "$endereco"
    existe="$($VIRSH dumpxml --inactive "$VM_NAME" \
        | xmlstarlet sel -t -v "count(/domain/devices/hostdev/source/address[@bus='0x$bus' and @slot='0x$slot' and @function='0x$func'])" 2>/dev/null || echo 0)"
    if [ "${existe:-0}" != "0" ]; then
        info "hostdev $endereco já presente no XML; pulando."
        return 0
    fi
    tmp="$(mktemp)"
    cat > "$tmp" <<XML
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x$dom' bus='0x$bus' slot='0x$slot' function='0x$func'/>
  </source>
</hostdev>
XML
    $VIRSH attach-device "$VM_NAME" "$tmp" --config
    rm -f "$tmp"
    ok "hostdev $endereco anexado."
}

anexar_hostdev_pci "$GPU_PCI_ID"
if [ -n "${GPU_AUDIO_PCI_ID:-}" ]; then
    anexar_hostdev_pci "$GPU_AUDIO_PCI_ID"
else
    info "Sem função de áudio HDMI da GPU (escolha da etapa 02): nada a anexar."
fi

# ----------------------------------------------------------------------------
# 4. Anexar o disco físico dedicado à VM (opcional)
# ----------------------------------------------------------------------------
titulo "4/4 Disco físico no XML da VM"
if [ -z "${HD1_BY_ID_PATH:-}" ]; then
    info "Nenhum disco físico dedicado (escolha da etapa 02): a VM segue apenas com o QCOW2."
    info "Para adicionar um depois: bash etapas/02-detectar-config.sh --redetectar e reexecute esta etapa."
elif $VIRSH dumpxml --inactive "$VM_NAME" | grep -qF "$HD1_BY_ID_PATH"; then
    info "Disco físico já anexado; pulando."
else
    [ -e "$HD1_BY_ID_PATH" ] || falhar "Disco não encontrado: $HD1_BY_ID_PATH (ainda conectado?)"
    ALVO="$(readlink -f "$HD1_BY_ID_PATH")"
    echo "Confira TRÊS vezes (alerta do manual): este disco será entregue por inteiro à VM."
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,MODEL,SERIAL "$ALVO"
    RAIZ_ATUAL="$(disco_raiz 2>/dev/null || true)"
    if [ -n "$RAIZ_ATUAL" ] && [ "$ALVO" = "$RAIZ_ATUAL" ]; then
        falhar "ABORTADO: $ALVO é o disco da RAIZ do Linux. Corrija o passthrough.conf (etapa 02)."
    fi
    if disco_em_uso_pelo_host "$ALVO"; then
        erro "Partições montadas neste disco agora:"
        lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT "$ALVO"
        falhar "O disco ($ALVO) está MONTADO no host. Desmonte (e remova do fstab) antes."
    fi
    confirmar "Anexar $HD1_BY_ID_PATH ($ALVO) como disco físico da VM?" || falhar "Cancelado."

    TMP="$(mktemp)"
    cat > "$TMP" <<XML
<disk type='block' device='disk'>
  <driver name='qemu' type='raw' cache='none'/>
  <source dev='$HD1_BY_ID_PATH'/>
  <target dev='vdb' bus='virtio'/>
</disk>
XML
    $VIRSH attach-device "$VM_NAME" "$TMP" --config
    rm -f "$TMP"
    ok "Disco físico anexado como vdb (VirtIO, raw, cache=none)."
fi

# ----------------------------------------------------------------------------
# Flags opcionais
# ----------------------------------------------------------------------------
if [ "${1:-}" = "--remover-video" ] || [ "${2:-}" = "--remover-video" ]; then
    titulo "Removendo vídeo virtual (QXL/SPICE)"
    aviso "Faça isso apenas com o passthrough JÁ validado (recomendação do manual)."
    if confirmar "Remover vídeo virtual, gráficos SPICE e áudio emulado?"; then
        TMPX="$(mktemp)"
        $VIRSH dumpxml --inactive "$VM_NAME" > "$TMPX"
        xmlstarlet ed -L \
            -d '/domain/devices/graphics' \
            -d '/domain/devices/video' \
            -d "/domain/devices/channel[@type='spicevmc']" \
            -d '/domain/devices/redirdev' \
            -d '/domain/devices/sound' \
            -d '/domain/devices/audio' \
            "$TMPX"
        $VIRSH define "$TMPX"
        rm -f "$TMPX"
        ok "Vídeo virtual removido (a saída passa a ser exclusivamente a RTX 3060)."
    fi
fi

if [ "${1:-}" = "--anti-code43" ] || [ "${2:-}" = "--anti-code43" ]; then
    titulo "Aplicando ocultação de hypervisor (Capítulo 28, Code 43)"
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
    rm -f "$TMPX"
    ok "kvm.hidden=on e hyperv.vendor_id aplicados."
fi

# ----------------------------------------------------------------------------
echo
titulo "Como testar (Capítulo 19, 'Como verificar')"
cat <<TESTE
1. Validar o XML:      virsh --connect qemu:///system dumpxml $VM_NAME | xmllint --noout -
2. Iniciar a VM:       virsh --connect qemu:///system start $VM_NAME
   Esperado: o monitor sai do desktop Linux, fica preto por alguns segundos e
   mostra o boot do Windows pela RTX 3060. Isso é o desenho, não é falha.
3. Desligar o Windows normalmente e observar o desktop Linux VOLTAR sozinho.
4. Logs dos hooks:     sudo journalctl -u libvirtd -e | grep -i hook
5. Se o Linux não recuperar o vídeo: Ctrl+Alt+F3 (TTY) e rode
   util/recuperar-gpu.sh (Capítulo 29, cenário 1).
TESTE
ok "Etapa 50 concluída."
