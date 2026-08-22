#!/bin/bash
# ============================================================================
# etapas/51-usb-passthrough.sh - Etapa 15: USB Passthrough (opcional)
# ============================================================================
# Dois modos complementares:
#
#   * dispositivos individuais por vendor:product (teclado, mouse, headset,
#     adaptador Bluetooth): o dispositivo escolhido vai para a VM no próximo
#     boot dela e volta ao host quando a VM desliga;
#   * controladora USB PCI inteira (--controladora): as portas físicas
#     ligadas àquela controladora passam a pertencer ao Windows enquanto a VM
#     roda, com hotplug nativo (qualquer USB plugado nelas aparece na hora).
#
# A descoberta é dinâmica: os candidatos vêm do sysfs deste host e uma
# controladora só é elegível quando TODOS os membros do grupo IOMMU dela são
# controladoras USB (sem ACS override, por política do projeto). O áudio HDMI
# da GPU já vai junto do passthrough da etapa 14 (mesmo grupo IOMMU).
#
# Uso:
#   51-usb-passthrough.sh                        adiciona dispositivos (interativo)
#   51-usb-passthrough.sh --remover              remove dispositivos anexados
#   51-usb-passthrough.sh --controladora         passa uma controladora inteira
#   51-usb-passthrough.sh --remover-controladora devolve a controladora ao host
#   51-usb-passthrough.sh --verificar            verifica sem alterar
# Adição e remoção são persistentes e valem no próximo boot da VM.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

HOSTDEV_PCI_PERMITIDAS=("${CORE_PARES_ENVELOPE[@]}" TOTAL EXACT MANAGED)

hostdev_pci_presente() {
    # 0 = hostdev PCI managed exato no XML inativo; 1 = ausente; 2 = ilegível.
    local bdf="$1" xml
    local -a payload=()
    xml="$($VIRSH dumpxml --inactive "$VM_NAME" 2>/dev/null)" || return 2
    payload=(xml "$xml" pci_address "$bdf")
    python_core_pares_payload HOSTDEV_PCI_PERMITIDAS HPCI_ domain-hostdev-pci payload \
        2>/dev/null || return 2
    [ "${HPCI_EXACT:-0}" -ge 1 ]
}

pci_classe() {
    # Classe PCI do BDF (ex.: 0x0c0330); vazio quando ilegível.
    local bdf="$1" classe=""
    IFS= read -r classe < "/sys/bus/pci/devices/$bdf/class" 2>/dev/null || classe=""
    printf '%s\n' "$classe"
}

pci_grupo_iommu() {
    local bdf="$1" link="/sys/bus/pci/devices/$1/iommu_group"
    [ -L "$link" ] || return 1
    basename -- "$(readlink -f -- "$link")"
}

pci_vendor_device_sysfs() {
    local bdf="$1" vendor device
    IFS= read -r vendor < "/sys/bus/pci/devices/$bdf/vendor" || return 1
    IFS= read -r device < "/sys/bus/pci/devices/$bdf/device" || return 1
    printf '%s:%s\n' "${vendor#0x}" "${device#0x}"
}

grupo_iommu_todo_usb() {
    # 0 quando todos os membros do grupo são controladoras USB (classe 0c03).
    local grupo="$1" membro classe
    for membro in "/sys/kernel/iommu_groups/$grupo/devices/"*; do
        [ -e "$membro" ] || return 1
        classe="$(pci_classe "$(basename -- "$membro")")"
        [[ "${classe,,}" == 0x0c03* ]] || return 1
    done
    return 0
}

membros_grupo_iommu() {
    local grupo="$1" membro
    for membro in "/sys/kernel/iommu_groups/$grupo/devices/"*; do
        [ -e "$membro" ] || continue
        basename -- "$membro"
    done
}

descricao_pci() {
    LC_ALL=C lspci -s "$1" 2>/dev/null | sed 's/^[^ ]* //' | head -n1
}

dispositivos_usb_da_controladora() {
    # Lista "vid:pid nome" de tudo conectado agora aos barramentos USB do BDF.
    local bdf="$1" raiz caminho arquivo dir vid pid nome
    for raiz in /sys/bus/usb/devices/usb*; do
        [ -e "$raiz" ] || continue
        caminho="$(readlink -f -- "$raiz")" || continue
        [[ "$caminho" == */"$bdf"/* ]] || continue
        while IFS= read -r arquivo; do
            dir="$(dirname -- "$arquivo")"
            vid=""; pid=""; nome=""
            IFS= read -r vid < "$dir/idVendor" 2>/dev/null || vid="????"
            IFS= read -r pid < "$dir/idProduct" 2>/dev/null || pid="????"
            IFS= read -r nome < "$arquivo" 2>/dev/null || nome="(sem nome)"
            # Root hubs (Linux Foundation 1d6b) são a própria controladora.
            [ "$vid" = "1d6b" ] && continue
            printf '%s:%s %s\n' "$vid" "$pid" "$nome"
        done < <(find "$caminho" -maxdepth 3 -name product 2>/dev/null | sort)
    done
}

enumerar_controladoras() {
    # Uma linha por controladora USB do host: BDF|GRUPO|ELEGIVEL|DESCRICAO.
    local dev bdf classe grupo elegivel
    for dev in /sys/bus/pci/devices/*/; do
        bdf="$(basename -- "$dev")"
        classe="$(pci_classe "$bdf")"
        [[ "${classe,,}" == 0x0c03* ]] || continue
        grupo="$(pci_grupo_iommu "$bdf")" || continue
        elegivel=0
        grupo_iommu_todo_usb "$grupo" && elegivel=1
        printf '%s|%s|%s|%s\n' "$bdf" "$grupo" "$elegivel" "$(descricao_pci "$bdf")"
    done
}

verificar() {
    # Etapa opcional: [ok] com pelo menos um dispositivo OU uma controladora
    # configurada e convergida. Sem nada, pendente-opcional, para não passar a
    # impressão de que teclado e mouse já estão garantidos dentro do Windows.
    [ -n "${VM_NAME:-}" ] || { v_falta "VM_NAME não definido."; v_fim; }
    if ! vm_existe "$VM_NAME"; then
        v_falta "VM '$VM_NAME' não existe."
        v_fim
    fi
    local qtd tem_algo=0
    qtd="$($VIRSH dumpxml --inactive "$VM_NAME" | grep -c "hostdev mode='subsystem' type='usb'" || true)"
    if [ "${qtd:-0}" -ge 1 ]; then
        v_ok "Dispositivos USB em passthrough no XML: $qtd."
        tem_algo=1
    fi
    if [ -n "${USB_CTRL_PCI_IDS:-}" ]; then
        tem_algo=1
        local -a bdfs=() ids=()
        IFS=',' read -r -a bdfs <<< "$USB_CTRL_PCI_IDS"
        IFS=',' read -r -a ids <<< "${USB_CTRL_VENDOR_DEVICE_IDS:-}"
        local i bdf atual grupo
        for i in "${!bdfs[@]}"; do
            bdf="${bdfs[$i]}"
            if ! pci_bdf_valido "$bdf"; then
                v_erro "USB_CTRL_PCI_IDS contém BDF inválido."
                continue
            fi
            if [ ! -e "/sys/bus/pci/devices/$bdf" ]; then
                v_erro "Controladora configurada não existe mais no PCI: $bdf."
                continue
            fi
            atual="$(pci_vendor_device_sysfs "$bdf" || true)"
            if [ -n "${ids[$i]:-}" ] && [ "$atual" != "${ids[$i]}" ]; then
                v_erro "Identidade da controladora $bdf mudou: esperado ${ids[$i]}, atual ${atual:-ilegível}."
                continue
            fi
            grupo="$(pci_grupo_iommu "$bdf" || true)"
            if [ -n "${USB_CTRL_IOMMU_GROUP:-}" ] && [ "$grupo" != "$USB_CTRL_IOMMU_GROUP" ]; then
                v_erro "Grupo IOMMU da controladora $bdf mudou: esperado $USB_CTRL_IOMMU_GROUP, atual ${grupo:-ilegível}."
                continue
            fi
            if ! grupo_iommu_todo_usb "$grupo"; then
                v_erro "O grupo IOMMU $grupo da controladora deixou de conter somente USB."
                continue
            fi
            case "$(hostdev_pci_presente "$bdf"; echo $?)" in
                0) v_ok "Controladora USB $bdf em passthrough no XML (grupo IOMMU $grupo)." ;;
                1) v_falta "Controladora $bdf configurada, mas ausente do XML; rode --controladora de novo." ;;
                *) v_indeterminado "Não foi possível ler o XML para conferir a controladora $bdf." ;;
            esac
        done
    fi
    [ "$tem_algo" -eq 1 ] \
        || v_falta "Nenhum dispositivo USB nem controladora em passthrough (opcional; necessário apenas para usar teclado/mouse reais dentro do Windows)."
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

guard_mutation usb.configure || exit 1
exigir_nao_root
exigir_sudo
exigir_comando lsusb lspci
python_core_disponivel \
    || falhar "O core Python do projeto não respondeu: ${PYTHON_CORE_ERRO:-diagnóstico ausente}."
exigir_conf VM_NAME
vm_existe "$VM_NAME" || falhar "A VM '$VM_NAME' não existe. Execute a etapa 12 antes."

echo
info "Finalidade: dar entrada real ao Windows: dispositivos USB individuais ou uma controladora USB PCI inteira (hotplug nativo nas portas dela)."
info "Adaptadores Bluetooth são dispositivos USB e aparecem nas listas; passar um deles dá a pilha Bluetooth inteira à VM (o host a perde enquanto ela roda)."
aviso "Tudo que for passado fica EXCLUSIVO da VM enquanto ela estiver ligada; volta ao host quando ela desliga."
aviso "Se você passar o ÚNICO teclado/mouse do host, a recuperação sem a VM cooperando é por SSH de outro dispositivo (virsh shutdown) ou, em último caso, o botão POWER."
info "Tanto a adição quanto a remoção passam a valer no próximo boot da VM, não na sessão já em execução."

# --- Modo controladora inteira -----------------------------------------------
mapear_portas_interativo() {
    # Ajuda o usuário a descobrir quais portas físicas pertencem a cada
    # controladora: plugue/remova um dispositivo e o diff aponta a dona.
    local antes depois linha
    antes="$(mktemp)"; depois="$(mktemp)"
    while :; do
        enumerar_controladoras | while IFS='|' read -r bdf _ _ _; do
            dispositivos_usb_da_controladora "$bdf" | sed "s/^/$bdf /"
        done | sort > "$antes"
        echo
        read -r -p "Plugue OU remova um dispositivo USB e pressione ENTER (n = terminar o mapeamento): " linha || break
        [ "${linha,,}" = "n" ] && break
        enumerar_controladoras | while IFS='|' read -r bdf _ _ _; do
            dispositivos_usb_da_controladora "$bdf" | sed "s/^/$bdf /"
        done | sort > "$depois"
        if cmp -s "$antes" "$depois"; then
            info "Nada mudou; o dispositivo pode não ter sido detectado ainda (tente de novo)."
            continue
        fi
        echo "Mudanças detectadas (a coluna 1 é a controladora dona da porta):"
        diff --unchanged-line-format='' \
            --old-line-format='  removido: %L' \
            --new-line-format='  plugado:  %L' "$antes" "$depois" || true
    done
    rm -f -- "$antes" "$depois"
}

xml_hostdev_pci() {
    # Gera o hostdev PCI do BDF $1 no arquivo $2.
    local bdf="$1" destino="$2"
    [[ "$bdf" =~ ^([0-9a-fA-F]{4}):([0-9a-fA-F]{2}):([0-9a-fA-F]{2})\.([0-7])$ ]] \
        || falhar "BDF inválido ao gerar XML: '$bdf'."
    cat > "$destino" <<XML
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x${BASH_REMATCH[1]}' bus='0x${BASH_REMATCH[2]}' slot='0x${BASH_REMATCH[3]}' function='0x${BASH_REMATCH[4]}'/>
  </source>
</hostdev>
XML
}

if [ "${1:-}" = "--controladora" ]; then
    titulo "Etapa 15: passar uma controladora USB inteira (VM: $VM_NAME)"
    [ -z "${USB_CTRL_PCI_IDS:-}" ] \
        || falhar "Já existe controladora configurada ($USB_CTRL_PCI_IDS). Use --remover-controladora antes de trocar."
    info "Elegibilidade dinâmica: o grupo IOMMU precisa conter SOMENTE controladoras USB (sem ACS override)."
    mapfile -t LINHAS_CTRL < <(enumerar_controladoras)
    [ "${#LINHAS_CTRL[@]}" -gt 0 ] || falhar "Nenhuma controladora USB PCI encontrada no sysfs."
    ELEGIVEIS=()
    DESCRICOES=()
    echo
    echo "Controladoras USB deste host:"
    for linha in "${LINHAS_CTRL[@]}"; do
        IFS='|' read -r BDF GRUPO ELEGIVEL DESCR <<< "$linha"
        CONECTADOS="$(dispositivos_usb_da_controladora "$BDF" | sed 's/^/        /')"
        if [ "$ELEGIVEL" = 1 ]; then
            echo "  [elegível]   $BDF (grupo IOMMU $GRUPO): $DESCR"
            ELEGIVEIS+=("$linha")
            DESCRICOES+=("$BDF (grupo $GRUPO): $DESCR")
        else
            echo "  [inelegível] $BDF (grupo IOMMU $GRUPO tem outros dispositivos): $DESCR"
        fi
        [ -n "$CONECTADOS" ] && { echo "      conectados agora:"; printf '%s\n' "$CONECTADOS"; }
    done
    [ "${#ELEGIVEIS[@]}" -gt 0 ] \
        || falhar "Nenhuma controladora elegível: em todos os grupos IOMMU há dispositivos não USB, e o projeto não usa ACS override."
    echo
    if confirmar "Quer mapear quais portas físicas pertencem a cada controladora antes de escolher?"; then
        mapear_portas_interativo
    fi
    echo
    ESCOLHA="$(escolher_da_lista 'Qual controladora passar à VM?' nao "${DESCRICOES[@]}")"
    IFS='|' read -r BDF_ESCOLHIDO GRUPO_ESCOLHIDO _ DESCR_ESCOLHIDA <<< "${ELEGIVEIS[$((ESCOLHA-1))]}"

    # O grupo inteiro vai junto (todos os membros são USB, já validado).
    mapfile -t MEMBROS < <(membros_grupo_iommu "$GRUPO_ESCOLHIDO")
    [ "${#MEMBROS[@]}" -ge 1 ] || falhar "Grupo IOMMU $GRUPO_ESCOLHIDO ficou ilegível."
    LISTA_BDF=""
    LISTA_VD=""
    for MEMBRO in "${MEMBROS[@]}"; do
        VD="$(pci_vendor_device_sysfs "$MEMBRO")" \
            || falhar "Não foi possível ler a identidade de $MEMBRO."
        LISTA_BDF="${LISTA_BDF:+$LISTA_BDF,}$MEMBRO"
        LISTA_VD="${LISTA_VD:+$LISTA_VD,}$VD"
    done

    echo
    info "Vai para a VM: grupo IOMMU $GRUPO_ESCOLHIDO inteiro (${LISTA_BDF})."
    info "As portas físicas dessas controladoras somem do host ENQUANTO a VM estiver ligada."
    CONECTADOS_AGORA="$(dispositivos_usb_da_controladora "$BDF_ESCOLHIDO")"
    if [ -n "$CONECTADOS_AGORA" ]; then
        aviso "O host vai perder, junto com as portas, o que está nelas agora:"
        printf '%s\n' "$CONECTADOS_AGORA" | sed 's/^/    /'
    fi
    confirmar_digitando CONTROLADORA "As portas da controladora escolhida passam a ser da VM a cada boot dela; sem outro teclado no host, a recuperação é por SSH ou botão POWER." \
        || cancelar_etapa

    xml_backup "$VM_NAME"
    for MEMBRO in "${MEMBROS[@]}"; do
        if hostdev_pci_presente "$MEMBRO"; then
            info "Hostdev $MEMBRO já está no XML; pulando."
            continue
        fi
        TMP="$(mktemp)"
        xml_hostdev_pci "$MEMBRO" "$TMP"
        $VIRSH attach-device "$VM_NAME" "$TMP" --config \
            || { rm -f "$TMP"; falhar "Não foi possível anexar $MEMBRO ao XML."; }
        rm -f "$TMP"
        ok "Controladora anexada ao XML: $MEMBRO."
    done
    salvar_conf_lote \
        USB_CTRL_PCI_IDS "$LISTA_BDF" \
        USB_CTRL_VENDOR_DEVICE_IDS "$LISTA_VD" \
        USB_CTRL_IOMMU_GROUP "$GRUPO_ESCOLHIDO"
    ok "Controladora configurada e persistida (vale a partir do próximo boot da VM)."
    info "Hotplug nativo: qualquer USB plugado nas portas dela aparece no Windows na hora."
    info "Para devolver ao host: bash etapas/51-usb-passthrough.sh --remover-controladora"
    exit 0
fi

if [ "${1:-}" = "--remover-controladora" ]; then
    titulo "Etapa 15: devolver a controladora USB ao host (VM: $VM_NAME)"
    [ -n "${USB_CTRL_PCI_IDS:-}" ] || { info "Nenhuma controladora configurada."; exit 0; }
    IFS=',' read -r -a MEMBROS <<< "$USB_CTRL_PCI_IDS"
    xml_backup "$VM_NAME"
    for MEMBRO in "${MEMBROS[@]}"; do
        pci_bdf_valido "$MEMBRO" || { aviso "BDF inválido na configuração: '$MEMBRO'; pulando."; continue; }
        if ! hostdev_pci_presente "$MEMBRO"; then
            info "Hostdev $MEMBRO já não está no XML."
            continue
        fi
        TMP="$(mktemp)"
        xml_hostdev_pci "$MEMBRO" "$TMP"
        $VIRSH detach-device "$VM_NAME" "$TMP" --config \
            || { rm -f "$TMP"; falhar "Não foi possível desanexar $MEMBRO do XML."; }
        rm -f "$TMP"
        ok "Removida do XML: $MEMBRO."
    done
    salvar_conf_lote \
        USB_CTRL_PCI_IDS "" \
        USB_CTRL_VENDOR_DEVICE_IDS "" \
        USB_CTRL_IOMMU_GROUP ""
    ok "Configuração da controladora limpa (vale a partir do próximo boot da VM)."
    exit 0
fi

# --- Modo dispositivos individuais ---------------------------------------------
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
    titulo "Etapa 15: remover USB passthrough da VM $VM_NAME"
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

[ -z "${1:-}" ] || falhar "Opção desconhecida da etapa 15: '$1' (use --remover, --controladora, --remover-controladora ou --verificar)."

titulo "Etapa 15: USB passthrough por dispositivo (VM: $VM_NAME)"
info "Para portas inteiras com hotplug nativo, use: bash etapas/51-usb-passthrough.sh --controladora"
mapfile -t LINHAS < <(lsusb)
[ "${#LINHAS[@]}" -gt 0 ] || falhar "lsusb não listou nenhum dispositivo."
echo
aviso "O dispositivo escolhido fica EXCLUSIVO da VM enquanto ela estiver ligada."
aviso "A seleção usa apenas vendor:product: unidades idênticas têm o mesmo par e qualquer uma pode ser capturada pela VM."
aviso "Recomendado: um segundo teclado/receptor no host. Sem ele, a recuperação é por SSH ou botão POWER (troubleshooting.md)."

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
ok "Etapa 15 concluída."
