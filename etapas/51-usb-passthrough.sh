#!/bin/bash
# ============================================================================
# etapas/51-usb-passthrough.sh - Capítulo 20: USB Passthrough (opcional)
# ============================================================================
# Passthrough de dispositivos USB individuais (teclado, mouse, headset) por
# vendor:product, método recomendado pelo manual. O áudio HDMI da GPU já vai
# junto do passthrough da etapa 50 (mesmo grupo IOMMU).
#
# Uso:
#   51-usb-passthrough.sh             adiciona dispositivos (interativo)
#   51-usb-passthrough.sh --remover   remove dispositivos anexados
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

verificar() {
    # Etapa opcional: considera concluída se a VM existir (com ou sem USB).
    [ -n "${VM_NAME:-}" ] || { v_falta "VM_NAME não definido."; v_fim; }
    if ! vm_existe "$VM_NAME"; then
        v_falta "VM '$VM_NAME' não existe."
        v_fim
    fi
    local qtd
    qtd="$($VIRSH dumpxml --inactive "$VM_NAME" | grep -c "hostdev mode='subsystem' type='usb'" || true)"
    v_ok "Dispositivos USB em passthrough no XML: ${qtd:-0} (etapa opcional)."
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

exigir_nao_root
exigir_sudo
exigir_comando lsusb xmlstarlet
exigir_conf VM_NAME

listar_usb_xml() {
    $VIRSH dumpxml --inactive "$VM_NAME" \
        | xmlstarlet sel -t -m "/domain/devices/hostdev[@type='usb']" \
            -v "concat(source/vendor/@id, ' ', source/product/@id)" -n 2>/dev/null || true
}

if [ "${1:-}" = "--remover" ]; then
    titulo "Remover USB passthrough da VM $VM_NAME"
    mapfile -t ATUAIS < <(listar_usb_xml | sed '/^$/d')
    [ "${#ATUAIS[@]}" -gt 0 ] || { info "Nenhum hostdev USB no XML."; exit 0; }
    i=1
    for a in "${ATUAIS[@]}"; do echo "  $i) vendor=$(cut -d' ' -f1 <<<"$a") product=$(cut -d' ' -f2 <<<"$a")"; i=$((i+1)); done
    ESCOLHA="$(perguntar 'Qual remover? (número)' '1')"
    SEL="${ATUAIS[$((ESCOLHA-1))]}"
    VEND="$(cut -d' ' -f1 <<<"$SEL")"; PROD="$(cut -d' ' -f2 <<<"$SEL")"
    xml_backup "$VM_NAME"
    TMP="$(mktemp)"
    cat > "$TMP" <<XML
<hostdev mode='subsystem' type='usb' managed='yes'>
  <source>
    <vendor id='$VEND'/>
    <product id='$PROD'/>
  </source>
</hostdev>
XML
    $VIRSH detach-device "$VM_NAME" "$TMP" --config
    rm -f "$TMP"
    ok "Removido: $VEND:$PROD"
    exit 0
fi

titulo "Capítulo 20: USB passthrough (VM: $VM_NAME)"
info "Dispositivos USB conectados agora:"
mapfile -t LINHAS < <(lsusb)
i=1
for l in "${LINHAS[@]}"; do echo "  $i) $l"; i=$((i+1)); done
echo
aviso "O dispositivo escolhido fica EXCLUSIVO da VM enquanto ela estiver ligada."
aviso "Nunca passe o ÚNICO teclado do host: ele é necessário para o TTY de emergência (Capítulo 29)."

while :; do
    ESCOLHA="$(perguntar 'Número do dispositivo para passar à VM (ENTER para terminar)' '')"
    [ -n "$ESCOLHA" ] || break
    LINHA="${LINHAS[$((ESCOLHA-1))]}"
    PAR="$(grep -oE 'ID [0-9a-fA-F]{4}:[0-9a-fA-F]{4}' <<< "$LINHA" | awk '{print $2}')"
    VEND="${PAR%%:*}"; PROD="${PAR##*:}"
    echo "Selecionado: $LINHA  (vendor=0x$VEND product=0x$PROD)"
    confirmar "Confirmar?" || continue

    if listar_usb_xml | grep -q "0x$VEND 0x$PROD"; then
        info "Este dispositivo já está no XML; pulando."
        continue
    fi
    xml_backup "$VM_NAME"
    TMP="$(mktemp)"
    cat > "$TMP" <<XML
<hostdev mode='subsystem' type='usb' managed='yes'>
  <source>
    <vendor id='0x$VEND'/>
    <product id='0x$PROD'/>
  </source>
</hostdev>
XML
    $VIRSH attach-device "$VM_NAME" "$TMP" --config
    rm -f "$TMP"
    ok "Anexado (vale a partir do próximo boot da VM): 0x$VEND:0x$PROD"
done

echo
info "Verificação dentro do Windows: Get-PnpDevice -Class Keyboard, Mouse, AudioEndpoint"
ok "Etapa 51 concluída."
