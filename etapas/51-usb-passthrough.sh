#!/bin/bash
# ============================================================================
# etapas/51-usb-passthrough.sh - Etapa 16: USB Passthrough (opcional)
# ============================================================================
# Passthrough de dispositivos USB individuais (teclado, mouse, headset) por
# vendor:product, método recomendado pelo manual. O áudio HDMI da GPU já vai
# junto do passthrough da etapa 14 (mesmo grupo IOMMU).
#
# Uso:
#   51-usb-passthrough.sh             adiciona dispositivos (interativo)
#   51-usb-passthrough.sh --remover   remove dispositivos anexados
#   51-usb-passthrough.sh --verificar verifica o XML sem alterar
# Adição e remoção são persistentes e valem no próximo boot da VM.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

verificar() {
    # Etapa opcional: [ok] só com pelo menos um USB anexado. Sem nenhum, o
    # status fica pendente-opcional para não passar a impressão de que teclado
    # e mouse já estão garantidos dentro do Windows (o incidente clássico é
    # iniciar a VM com a GPU passada e ficar sem imagem E sem entrada).
    [ -n "${VM_NAME:-}" ] || { v_falta "VM_NAME não definido."; v_fim; }
    if ! vm_existe "$VM_NAME"; then
        v_falta "VM '$VM_NAME' não existe."
        v_fim
    fi
    local qtd
    qtd="$($VIRSH dumpxml --inactive "$VM_NAME" | grep -c "hostdev mode='subsystem' type='usb'" || true)"
    if [ "${qtd:-0}" -ge 1 ]; then
        v_ok "Dispositivos USB em passthrough no XML: $qtd (etapa opcional)."
    else
        v_falta "Nenhum dispositivo USB anexado ao XML (opcional; necessário apenas para usar teclado/mouse reais dentro do Windows)."
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

guard_mutation usb.configure || exit 1
exigir_nao_root
exigir_sudo
exigir_comando lsusb
python_core_disponivel \
    || falhar "O core Python do projeto não respondeu: ${PYTHON_CORE_ERRO:-diagnóstico ausente}."
exigir_conf VM_NAME

echo
info "Finalidade: adicionar ou remover USBs no XML persistente da VM, sem reiniciar o host."
info "Pré-requisitos: identifique o dispositivo e mantenha teclado/receptor de emergência no host."
aviso "A seleção usa apenas vendor:product: unidades idênticas têm o mesmo par e qualquer uma pode ser capturada pela VM."
aviso "Desconecte unidades idênticas que não devam ir para a VM antes do próximo boot."
info "Tanto a adição quanto a remoção passam a valer no próximo boot da VM, não na sessão já em execução."

USB_XML_PERMITIDAS=(
    "${CORE_PARES_ENVELOPE[@]}"
    USB_COUNT AMBIGUOUS_PAIRS
    'USB_#_VENDOR' 'USB_#_PRODUCT' 'USB_#_BUS' 'USB_#_DEVICE' 'USB_#_MANAGED'
)
USB_AMBIGUOS=0
listar_usb_xml() {
    # A enumeração vem do core Python: cada hostdev USB precisa ter pelo menos
    # um discriminador (vendor/product ou endereço físico) e a resposta informa
    # quantos pares VID:PID estão duplicados. Nada é escolhido por ordem.
    local xml total indice vendor produto nome_vendor nome_produto
    local -a payload=()
    USB_AMBIGUOS=0
    xml="$($VIRSH dumpxml --inactive "$VM_NAME" 2>/dev/null)" || return 0
    payload=(xml "$xml")
    python_core_pares_payload USB_XML_PERMITIDAS USBX_ domain-usb-hostdev payload \
        2>/dev/null || return 0
    USB_AMBIGUOS="$USBX_AMBIGUOUS_PAIRS"
    total="$USBX_USB_COUNT"
    for (( indice = 0; indice < total; indice++ )); do
        nome_vendor="USBX_USB_${indice}_VENDOR"
        nome_produto="USBX_USB_${indice}_PRODUCT"
        vendor="${!nome_vendor}"
        produto="${!nome_produto}"
        printf '%s %s\n' "$vendor" "$produto"
    done
}

if [ "${1:-}" = "--remover" ]; then
    titulo "Etapa 16: remover USB passthrough da VM $VM_NAME"
    mapfile -t ATUAIS < <(listar_usb_xml | sed '/^$/d')
    [ "${#ATUAIS[@]}" -gt 0 ] || { info "Nenhum hostdev USB no XML."; exit 0; }
    # REQ-USB-IDENTITY começa aqui: um par VID:PID duplicado no XML não pode ser
    # removido por ordem de enumeração. O fluxo completo (serial/porta) é de I6.
    [ "$USB_AMBIGUOS" = 0 ] \
        || falhar "O XML possui $USB_AMBIGUOS par(es) VID:PID duplicados; a remoção automática seria ambígua. Edite o XML manualmente."
    DESCRICOES=()
    for a in "${ATUAIS[@]}"; do
        DESCRICOES+=("vendor=$(cut -d' ' -f1 <<<"$a") product=$(cut -d' ' -f2 <<<"$a")")
    done
    ESCOLHA="$(escolher_da_lista 'Qual remover? (número)' nao "${DESCRICOES[@]}")"
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
    ok "Removido da configuração persistente: $VEND:$PROD (vale no próximo boot da VM)."
    exit 0
fi

titulo "Etapa 16: USB passthrough (VM: $VM_NAME)"
mapfile -t LINHAS < <(lsusb)
[ "${#LINHAS[@]}" -gt 0 ] || falhar "lsusb não listou nenhum dispositivo."
echo
aviso "O dispositivo escolhido fica EXCLUSIVO da VM enquanto ela estiver ligada."
aviso "Mantenha um segundo teclado/receptor fisicamente no host e teste o TTY de emergência."
aviso "Nunca passe o único teclado do host; ele é necessário para a recuperação local descrita em troubleshooting.md."

while :; do
    echo
    echo "Dispositivos USB conectados agora (0 = terminar):"
    ESCOLHA="$(escolher_da_lista 'Dispositivo para passar à VM' sim "${LINHAS[@]}")"
    [ "$ESCOLHA" -eq 0 ] && break
    LINHA="${LINHAS[$((ESCOLHA-1))]}"
    PAR="$(grep -oE 'ID [0-9a-fA-F]{4}:[0-9a-fA-F]{4}' <<< "$LINHA" | awk '{print $2}')"
    if [ -z "$PAR" ]; then
        erro "Não consegui extrair vendor:product de: $LINHA"
        continue
    fi
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
ok "Etapa 16 concluída."
