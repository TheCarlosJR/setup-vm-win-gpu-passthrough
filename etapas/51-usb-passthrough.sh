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
#   51-usb-passthrough.sh                        pergunta o modo (padrão do menu)
#   51-usb-passthrough.sh --remover              remove dispositivos anexados
#   51-usb-passthrough.sh --controladora         passa uma controladora inteira
#   51-usb-passthrough.sh --remover-controladora devolve a controladora ao host
#   51-usb-passthrough.sh --verificar            verifica sem alterar
# Adição e remoção são persistentes e valem no próximo boot da VM.
# ============================================================================
SCRIPT_VERSION="1.1.0"
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

usb_controladora_pci() {
    # BDF da controladora PCI dona do dispositivo USB bus:device observado
    # agora. Falha (sem eco) quando o sysfs não permite concluir.
    local bus="${1:-}" device="${2:-}" dir busnum devnum caminho tronco
    [[ "$bus" =~ ^[0-9]+$ ]] && [[ "$device" =~ ^[0-9]+$ ]] || return 1
    for dir in /sys/bus/usb/devices/*; do
        [ -r "$dir/busnum" ] && [ -r "$dir/devnum" ] || continue
        IFS= read -r busnum < "$dir/busnum" || continue
        IFS= read -r devnum < "$dir/devnum" || continue
        [ "$((10#$busnum))" -eq "$((10#$bus))" ] || continue
        [ "$((10#$devnum))" -eq "$((10#$device))" ] || continue
        caminho="$(readlink -f -- "$dir")" || return 1
        # .../pci0000:00/0000:00:01.2/0000:01:00.0/usb1/1-5 -> 0000:01:00.0
        tronco="${caminho%%/usb[0-9]*}"
        [ "$tronco" != "$caminho" ] || return 1
        printf '%s\n' "${tronco##*/}"
        return 0
    done
    return 1
}

usb_coberto_por_controladora() {
    # Ecoa o BDF da controladora JÁ em passthrough que cobre bus:device.
    # Serve só para avisar: um hostdev individual numa porta dessas é redundante.
    local bus="${1:-}" device="${2:-}" dono="" bdf
    local -a configuradas=()
    [ -n "${USB_CTRL_PCI_IDS:-}" ] || return 1
    dono="$(usb_controladora_pci "$bus" "$device")" || return 1
    IFS=',' read -r -a configuradas <<< "$USB_CTRL_PCI_IDS"
    for bdf in "${configuradas[@]}"; do
        [ "$bdf" = "$dono" ] || continue
        printf '%s\n' "$dono"
        return 0
    done
    return 1
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

pci_driver_atual() {
    local link="/sys/bus/pci/devices/$1/driver"
    [ -L "$link" ] || { printf 'sem_driver\n'; return 0; }
    basename -- "$(readlink -f -- "$link")"
}

# Enumeração dos hostdevs USB do XML pelo core Python (também usada pelo
# --verificar, por isso definida antes dele).
USB_XML_PERMITIDAS=(
    "${CORE_PARES_ENVELOPE[@]}"
    USB_COUNT AMBIGUOUS_PAIRS
    'USB_#_VENDOR' 'USB_#_PRODUCT' 'USB_#_BUS' 'USB_#_DEVICE' 'USB_#_MANAGED'
    'USB_#_ALIAS' 'USB_#_IDENTITY_KIND' 'USB_#_IDENTITY_SHA256'
)
USB_AMBIGUOS=0
USB_XML_ERRO=""
USB_XML_LISTA=""
listar_usb_xml() {
    # Preenche USB_XML_LISTA no shell atual. Cada linha usa TAB e sentinela '-'
    # para preservar campos opcionais; erro nunca vira lista vazia silenciosa.
    local xml total indice vendor produto kind digest bus device alias linha
    local nome_vendor nome_produto nome_kind nome_digest nome_bus nome_device nome_alias
    local -a payload=()
    USB_AMBIGUOS=0
    USB_XML_ERRO=""
    USB_XML_LISTA=""
    xml="$($VIRSH dumpxml --inactive "$VM_NAME" 2>/dev/null)" \
        || { USB_XML_ERRO="Não foi possível ler o XML inativo da VM."; return 1; }
    payload=(xml "$xml")
    python_core_pares_payload USB_XML_PERMITIDAS USBX_ domain-usb-hostdev payload \
        2>/dev/null || { USB_XML_ERRO="${PYTHON_CORE_ERRO:-O core recusou o XML USB.}"; return 1; }
    USB_AMBIGUOS="$USBX_AMBIGUOUS_PAIRS"
    total="$USBX_USB_COUNT"
    for (( indice = 0; indice < total; indice++ )); do
        nome_vendor="USBX_USB_${indice}_VENDOR"; nome_produto="USBX_USB_${indice}_PRODUCT"
        nome_kind="USBX_USB_${indice}_IDENTITY_KIND"; nome_digest="USBX_USB_${indice}_IDENTITY_SHA256"
        nome_bus="USBX_USB_${indice}_BUS"; nome_device="USBX_USB_${indice}_DEVICE"; nome_alias="USBX_USB_${indice}_ALIAS"
        vendor="${!nome_vendor}"; produto="${!nome_produto}"; kind="${!nome_kind}"; digest="${!nome_digest}"
        bus="${!nome_bus}"; device="${!nome_device}"; alias="${!nome_alias}"
        printf -v linha '%s\t%s\t%s\t%s\t%s\t%s\t%s' \
            "${vendor:--}" "${produto:--}" "${kind:--}" "${digest:--}" \
            "${bus:--}" "${device:--}" "${alias:--}"
        USB_XML_LISTA+="$linha"$'\n'
    done
}

usb_linha_ler() {
    local linha="${1:-}" nome
    IFS=$'\t' read -r USB_LINHA_VENDOR USB_LINHA_PRODUCT USB_LINHA_KIND \
        USB_LINHA_DIGEST USB_LINHA_BUS USB_LINHA_DEVICE USB_LINHA_ALIAS <<< "$linha"
    for nome in USB_LINHA_VENDOR USB_LINHA_PRODUCT USB_LINHA_KIND USB_LINHA_DIGEST \
        USB_LINHA_BUS USB_LINHA_DEVICE USB_LINHA_ALIAS; do
        [ "${!nome}" != - ] || printf -v "$nome" '%s' ""
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
    local qtd=0 tem_algo=0 estado_vm="" usb_xml_lista=""
    # Com a VM comprovadamente desligada, o verify também prova o RETORNO ao
    # host: dispositivos individuais reobservados por identidade estável e
    # controladora fora do vfio-pci. Com a VM ligada, o lado do host fica mudo.
    estado_vm="$(LC_ALL=C $VIRSH domstate "$VM_NAME" 2>/dev/null || true)"
    if listar_usb_xml; then
        usb_xml_lista="$USB_XML_LISTA"
        qtd="$(printf '%s' "$usb_xml_lista" | sed '/^$/d' | wc -l)"
    else
        tem_algo=1
        v_indeterminado "Não foi possível inspecionar identidades USB no XML: ${USB_XML_ERRO:-erro desconhecido}."
    fi
    if [ "${qtd:-0}" -ge 1 ]; then
        v_ok "Dispositivos USB em passthrough no XML: $qtd."
        tem_algo=1
        if [ "$estado_vm" = "shut off" ]; then
            local par par_vendor par_produto par_kind par_digest par_bus par_device par_alias linha
            local usb_xml_lista usb_captura=""
            usb_xml_lista="$USB_XML_LISTA"
            if ! command -v udevadm >/dev/null 2>&1; then
                    v_indeterminado "udevadm indisponível; não é possível provar as identidades USB devolvidas ao host."
                elif ! usb_captura="$(LC_ALL=C udevadm info --export-db 2>/dev/null)"; then
                    v_indeterminado "udevadm falhou; nenhuma identidade USB foi considerada comprovada."
                else
                    while IFS= read -r linha; do
                        [ -n "$linha" ] || continue
                        usb_linha_ler "$linha"
                        par_vendor="$USB_LINHA_VENDOR"; par_produto="$USB_LINHA_PRODUCT"
                        par_kind="$USB_LINHA_KIND"; par_digest="$USB_LINHA_DIGEST"
                        par_bus="$USB_LINHA_BUS"; par_device="$USB_LINHA_DEVICE"; par_alias="$USB_LINHA_ALIAS"
                        [ -n "$par_vendor" ] && [ -n "$par_produto" ] || continue
                        par="${par_vendor#0x}:${par_produto#0x}"
                        if [ -z "$par_digest" ]; then
                            v_indeterminado "USB $par é legado e não possui identidade serial/porta persistida; migre pela etapa 15."
                        elif inventario_resolver_usb "$usb_captura" resolve \
                                "${par_vendor#0x}" "${par_produto#0x}" "$par_kind" "$par_digest" \
                                "$par_bus" "$par_device"; then
                            v_ok "USB $par com identidade $par_kind persistida foi reobservado unicamente no host."
                        else
                            v_indeterminado "USB $par não teve a identidade persistida comprovada no host: ${USB_IDENTIDADE_ERRO:-ausente ou ambígua}."
                        fi
                    done <<< "$usb_xml_lista"
                fi
            fi
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
            if [ "$estado_vm" = "shut off" ]; then
                local driver
                driver="$(pci_driver_atual "$bdf")"
                case "$driver" in
                    vfio-pci) v_falta "Controladora $bdf continua no vfio-pci com a VM desligada: as portas USB dela NÃO retornaram ao host." ;;
                    sem_driver) v_falta "Controladora $bdf está sem driver com a VM desligada: as portas USB dela NÃO retornaram ao host." ;;
                    *) v_ok "Controladora $bdf devolvida ao host (driver $driver) com a VM desligada." ;;
                esac
            fi
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
exigir_comando lsusb lspci udevadm virt-xml-validate
python_core_disponivel \
    || falhar "O core Python do projeto não respondeu: ${PYTHON_CORE_ERRO:-diagnóstico ausente}."
exigir_conf VM_NAME
vm_existe "$VM_NAME" || falhar "A VM '$VM_NAME' não existe. Execute a etapa 12 antes."

echo
info "Finalidade: dar entrada real ao Windows: dispositivos USB individuais ou uma controladora USB PCI inteira (hotplug nativo nas portas dela)."
info "Adaptadores Bluetooth são dispositivos USB e aparecem nas listas; passar um deles dá a pilha Bluetooth inteira à VM (o host a perde enquanto ela roda)."
info "Isso vale também para o Bluetooth integrado à placa-mãe: em módulos combo, só o rádio Bluetooth é USB e viaja; o WiFi é função PCIe separada e continua no host."
info "O modo individual NÃO usa VFIO nem toca no grupo IOMMU: a controladora PCI da porta segue no host, com SATA, NVMe e rede intactos."
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

modo_controladora() {
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
}

modo_remover_controladora() {
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
}

# --- Modo dispositivos individuais ---------------------------------------------
USB_TRANSACAO_ERRO=""
capturar_usb_udev() {
    LC_ALL=C udevadm info --export-db 2>/dev/null
}

usb_aplicar_candidato() {
    # usb_aplicar_candidato ESTADO KIND SHA VID PID [BUS DEVICE]
    local estado="${1:-}" kind="${2:-}" digest="${3:-}" vendor="${4:-}" product="${5:-}"
    local bus="${6:-}" device="${7:-}" captura="" captura_revalidada=""
    local original candidato observado atual xml_check fp_original fp_check
    local aplicacao_iniciada=0
    USB_TRANSACAO_ERRO=""
    original="$(mktemp)"; candidato="$(mktemp)"; observado="$(mktemp)"; xml_check="$(mktemp)" \
        || { USB_TRANSACAO_ERRO="Não foi possível reservar temporários da transação USB."; return 1; }
    chmod 600 -- "$original" "$candidato" "$observado" "$xml_check" || {
        rm -f -- "$original" "$candidato" "$observado" "$xml_check"
        USB_TRANSACAO_ERRO="Não foi possível restringir temporários USB."
        return 1
    }
    $VIRSH dumpxml --inactive "$VM_NAME" > "$original" 2>/dev/null || {
        rm -f -- "$original" "$candidato" "$observado" "$xml_check"
        USB_TRANSACAO_ERRO="Não foi possível capturar o XML inativo original."
        return 1
    }
    xml_dominio_fingerprint "$original" || {
        rm -f -- "$original" "$candidato" "$observado" "$xml_check"
        USB_TRANSACAO_ERRO="XML original inválido: $XML_DOMINIO_ERRO"
        return 1
    }
    fp_original="$XML_DOMINIO_FINGERPRINT"

    if [ "$estado" = present ]; then
        captura="$(capturar_usb_udev)" || {
            rm -f -- "$original" "$candidato" "$observado" "$xml_check"
            USB_TRANSACAO_ERRO="Falha ao reobservar USB antes do candidato."
            return 1
        }
        inventario_resolver_usb "$captura" resolve "$vendor" "$product" "$kind" "$digest" "$bus" "$device" || {
            rm -f -- "$original" "$candidato" "$observado" "$xml_check"
            USB_TRANSACAO_ERRO="Identidade USB não pôde ser revalidada: $USB_IDENTIDADE_ERRO"
            return 1
        }
        bus="$USB_IDENTIDADE_BUS"; device="$USB_IDENTIDADE_DEVICE"
    else
        bus=""; device=""
    fi

    xml_candidato_usb "$original" "$candidato" "$estado" "$kind" "$digest" \
        "$vendor" "$product" "$bus" "$device" || {
        rm -f -- "$original" "$candidato" "$observado" "$xml_check"
        USB_TRANSACAO_ERRO="Candidato USB recusado: $XML_CANDIDATO_ERRO"
        return 1
    }
    [ "$XML_CANDIDATO_FINGERPRINT_ANTES" = "$fp_original" ] || {
        rm -f -- "$original" "$candidato" "$observado" "$xml_check"
        USB_TRANSACAO_ERRO="O XML mudou durante a geração do candidato."
        return 1
    }
    if [ "$XML_CANDIDATO_MUDOU" = 0 ]; then
        rm -f -- "$original" "$candidato" "$observado" "$xml_check"
        return 0
    fi
    virt-xml-validate "$candidato" domain >/dev/null 2>&1 || {
        rm -f -- "$original" "$candidato" "$observado" "$xml_check"
        USB_TRANSACAO_ERRO="O schema libvirt recusou o candidato USB."
        return 1
    }

    if [ "$estado" = present ]; then
        captura_revalidada="$(capturar_usb_udev)" || {
            rm -f -- "$original" "$candidato" "$observado" "$xml_check"
            USB_TRANSACAO_ERRO="Falha ao reobservar USB imediatamente antes do define."
            return 1
        }
        inventario_resolver_usb "$captura_revalidada" resolve "$vendor" "$product" "$kind" "$digest" "$bus" "$device" || {
            rm -f -- "$original" "$candidato" "$observado" "$xml_check"
            USB_TRANSACAO_ERRO="Identidade USB mudou antes do define: $USB_IDENTIDADE_ERRO"
            return 1
        }
        [ "$USB_IDENTIDADE_RENUMBERED" = 0 ] || {
            rm -f -- "$original" "$candidato" "$observado" "$xml_check"
            USB_TRANSACAO_ERRO="USB renumerou durante a confirmação; execute novamente para regenerar o candidato."
            return 1
        }
    fi
    # O backup acontece antes da última comparação. Ele pode reler o domínio,
    # portanto nenhuma leitura ou efeito externo fica entre a revalidação final
    # abaixo e o define protegido pelos traps.
    xml_backup "$VM_NAME"
    $VIRSH dumpxml --inactive "$VM_NAME" > "$xml_check" 2>/dev/null \
        || { rm -f -- "$original" "$candidato" "$observado" "$xml_check"; USB_TRANSACAO_ERRO="Não foi possível reler o XML antes do define."; return 1; }
    xml_dominio_fingerprint "$xml_check" || {
        rm -f -- "$original" "$candidato" "$observado" "$xml_check"
        USB_TRANSACAO_ERRO="XML concorrente inválido antes do define."
        return 1
    }
    fp_check="$XML_DOMINIO_FINGERPRINT"
    [ "$fp_check" = "$fp_original" ] || {
        rm -f -- "$original" "$candidato" "$observado" "$xml_check"
        USB_TRANSACAO_ERRO="O XML foi alterado por outro processo; nada foi sobrescrito."
        return 1
    }

    : > "$xml_check"
    local fp_candidato="$XML_CANDIDATO_FINGERPRINT_DEPOIS" janela_rc=0 resultado=""
    if (
        USB_TX_ESTADO=PREPARED

        usb_tx_rollback() {
            local fp_atual="" rc_compare=0
            if ! $VIRSH dumpxml --inactive "$VM_NAME" > "$observado" 2>/dev/null \
                || ! xml_dominio_fingerprint "$observado"; then
                printf '%s\n' unproven > "$xml_check"
                return 1
            fi
            fp_atual="$XML_DOMINIO_FINGERPRINT"
            if [ "$fp_atual" = "$fp_original" ]; then
                printf '%s\n' unchanged > "$xml_check"
                return 0
            fi
            if [ -z "$fp_candidato" ] || [ "$fp_atual" != "$fp_candidato" ]; then
                # Outro processo publicou um terceiro estado depois do nosso
                # define. Restaurar o snapshot antigo apagaria trabalho alheio.
                printf '%s\n' conflict > "$xml_check"
                return 2
            fi
            if ! $VIRSH define --validate "$original" >/dev/null 2>&1 \
                || ! $VIRSH dumpxml --inactive "$VM_NAME" > "$observado" 2>/dev/null; then
                printf '%s\n' unproven > "$xml_check"
                return 1
            fi
            xml_dominio_equivalente "$original" "$observado" full || rc_compare=$?
            if [ "$rc_compare" -eq 0 ]; then
                printf '%s\n' restored > "$xml_check"
                return 0
            fi
            printf '%s\n' unproven > "$xml_check"
            return 1
        }

        usb_tx_finalizar() {
            local rc=$? rollback_rc=0
            trap - EXIT INT TERM
            if [ "$USB_TX_ESTADO" != COMMITTED ]; then
                usb_tx_rollback || rollback_rc=$?
                [ "$rollback_rc" -eq 0 ] || [ "$rc" -ne 0 ] || rc=1
            fi
            exit "$rc"
        }

        # Traps armados antes do primeiro efeito. PREPARED também passa pelo
        # rollback, que primeiro prova se o domínio ainda está no original.
        trap usb_tx_finalizar EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM

        if ! $VIRSH define --validate "$candidato" >/dev/null 2>&1; then
            exit 1
        fi
        USB_TX_ESTADO=APPLIED
        if ! $VIRSH dumpxml --inactive "$VM_NAME" > "$observado" 2>/dev/null \
            || ! xml_dominio_equivalente "$candidato" "$observado" full; then
            exit 1
        fi
        USB_TX_ESTADO=VERIFIED
        USB_TX_ESTADO=COMMITTED
        printf '%s\n' committed > "$xml_check"
        trap - EXIT INT TERM
        exit 0
    ); then
        rm -f -- "$original" "$candidato" "$observado" "$xml_check"
        return 0
    else
        janela_rc=$?
    fi

    IFS= read -r resultado < "$xml_check" 2>/dev/null || resultado="unproven"
    case "$resultado" in
        restored)
            USB_TRANSACAO_ERRO="A mutação USB falhou e o XML original foi restaurado e comprovado."
            ;;
        unchanged)
            USB_TRANSACAO_ERRO="A mutação USB falhou antes de produzir efeito; o XML original foi comprovado."
            ;;
        conflict)
            USB_TRANSACAO_ERRO="CONFLITO: o XML mudou depois do efeito; rollback automático recusado para não apagar trabalho concorrente. Os XMLs temporários foram preservados para recuperação manual."
            # Preservar evidência é mais seguro que apagar snapshots em conflito.
            return "$janela_rc"
            ;;
        *)
            USB_TRANSACAO_ERRO="A mutação USB falhou e a restauração do XML não pôde ser comprovada. Os XMLs temporários foram preservados para recuperação manual."
            return "$janela_rc"
            ;;
    esac
    rm -f -- "$original" "$candidato" "$observado" "$xml_check"
    return "$janela_rc"
}

modo_remover_dispositivos() {
    titulo "Etapa 15: remover USB passthrough da VM $VM_NAME"
    local lista_usb=""
    listar_usb_xml \
        || falhar "Não foi possível enumerar o XML USB: ${USB_XML_ERRO:-erro desconhecido}."
    lista_usb="$USB_XML_LISTA"
    mapfile -t ATUAIS < <(printf '%s\n' "$lista_usb" | sed '/^$/d')
    [ "${#ATUAIS[@]}" -gt 0 ] || { info "Nenhum hostdev USB no XML."; exit 0; }
    DESCRICOES=()
    for a in "${ATUAIS[@]}"; do
        usb_linha_ler "$a"
        VEND="$USB_LINHA_VENDOR"; PROD="$USB_LINHA_PRODUCT"; KIND="$USB_LINHA_KIND"
        DIGEST="$USB_LINHA_DIGEST"; BUS="$USB_LINHA_BUS"; DEVICE="$USB_LINHA_DEVICE"; ALIAS="$USB_LINHA_ALIAS"
        if [ -z "$DIGEST" ]; then
            DESCRICOES+=("LEGADO sem identidade estável: ${VEND}:${PROD} (migração necessária)")
        else
            DESCRICOES+=("${VEND}:${PROD} identidade=$KIND endereço atual=${BUS:-?}:${DEVICE:-?}")
        fi
    done
    ESCOLHA="$(escolher_da_lista 'Qual remover? (número)' nao "${DESCRICOES[@]}")"
    SEL="${ATUAIS[$((ESCOLHA-1))]}"
    usb_linha_ler "$SEL"
    VEND="$USB_LINHA_VENDOR"; PROD="$USB_LINHA_PRODUCT"; KIND="$USB_LINHA_KIND"
    DIGEST="$USB_LINHA_DIGEST"; BUS="$USB_LINHA_BUS"; DEVICE="$USB_LINHA_DEVICE"; ALIAS="$USB_LINHA_ALIAS"
    [ -n "$DIGEST" ] \
        || falhar "Hostdev legado sem serial/porta persistidos. Selecione o dispositivo conectado no modo individual para migrá-lo antes de remover."
    confirmar "Remover exatamente esta identidade USB persistida do próximo boot da VM?" || cancelar_etapa
    usb_aplicar_candidato absent "$KIND" "$DIGEST" "${VEND#0x}" "${PROD#0x}" \
        || falhar "$USB_TRANSACAO_ERRO"
    ok "Identidade USB removida da configuração persistente."
    exit 0
}

modo_dispositivos() {
    titulo "Etapa 15: USB passthrough por dispositivo (VM: $VM_NAME)"
    info "Para portas inteiras com hotplug nativo, use o modo controladora."
    exigir_vm_desligada "$VM_NAME"
    aviso "Cada dispositivo é autorizado por serial; sem serial, somente por porta física comprovada."
    aviso "Bus/device servem apenas para localizar a observação atual e nunca são a identidade persistida."

    while :; do
        mapfile -t LINHAS < <(LC_ALL=C lsusb)
        [ "${#LINHAS[@]}" -gt 0 ] || falhar "lsusb não listou nenhum dispositivo."
        # Os rótulos só decoram a lista; a identidade continua saindo de $LINHAS.
        # A cor sai das constantes de lib/common.sh, que ficam VAZIAS quando não
        # há terminal. Por isso cada marca também é texto: em captura, log e
        # pipe a informação continua legível sem depender de escape ANSI.
        # Uma única leitura do XML por rodada serve às marcas da lista e à
        # pré-checagem de duplicidade mais abaixo. A transação relê o domínio e
        # refaz o fingerprint por conta própria, então ela continua sendo a
        # autoridade sobre mudança concorrente, não esta observação.
        listar_usb_xml \
            || falhar "O XML USB atual é inválido; nenhuma mutação foi iniciada: ${USB_XML_ERRO:-erro desconhecido}."
        XML_USB_ATUAL="$USB_XML_LISTA"
        USB_PARES_NO_XML=""
        while IFS= read -r USB_XML_LINHA; do
            [ -n "$USB_XML_LINHA" ] || continue
            usb_linha_ler "$USB_XML_LINHA"
            [ -n "$USB_LINHA_VENDOR" ] && [ -n "$USB_LINHA_PRODUCT" ] || continue
            USB_PARES_NO_XML+="${USB_LINHA_VENDOR#0x}:${USB_LINHA_PRODUCT#0x}"$'\n'
        done <<< "$XML_USB_ATUAL"
        ROTULOS=()
        for LINHA in "${LINHAS[@]}"; do
            ROTULO="$LINHA"
            if [[ "$LINHA" =~ Bus[[:space:]]+([0-9]+)[[:space:]]+Device[[:space:]]+([0-9]+):[[:space:]]+ID[[:space:]]+([0-9a-fA-F]{4}):([0-9a-fA-F]{4}) ]]; then
                PAR_LINHA="${BASH_REMATCH[3],,}:${BASH_REMATCH[4],,}"
                DONO="$(usb_coberto_por_controladora \
                    "$((10#${BASH_REMATCH[1]}))" "$((10#${BASH_REMATCH[2]}))" || true)"
                case $'\n'"$USB_PARES_NO_XML" in
                    *$'\n'"$PAR_LINHA"$'\n'*)
                        ROTULO="${C_VERDE}${LINHA}${C_RESET}  ${C_VERDE}[já anexado à VM]${C_RESET}" ;;
                esac
                [ -z "$DONO" ] \
                    || ROTULO+="  ${C_AMARELO}[já vai à VM pela controladora $DONO]${C_RESET}"
            fi
            ROTULOS+=("$ROTULO")
        done
        echo
        echo "Dispositivos USB conectados agora (0 = terminar):"
        ESCOLHA="$(escolher_da_lista 'Dispositivo para configurar' sim "${ROTULOS[@]}")"
        [ "$ESCOLHA" -eq 0 ] && break
        LINHA="${LINHAS[$((ESCOLHA-1))]}"
        if [[ ! "$LINHA" =~ Bus[[:space:]]+([0-9]+)[[:space:]]+Device[[:space:]]+([0-9]+):[[:space:]]+ID[[:space:]]+([0-9a-fA-F]{4}):([0-9a-fA-F]{4}) ]]; then
            erro "Não consegui extrair endereço e VID:PID da linha escolhida."
            continue
        fi
        BUS_ATUAL="$((10#${BASH_REMATCH[1]}))"
        DEVICE_ATUAL="$((10#${BASH_REMATCH[2]}))"
        VEND="${BASH_REMATCH[3],,}"; PROD="${BASH_REMATCH[4],,}"
        DONO_CTRL="$(usb_coberto_por_controladora "$BUS_ATUAL" "$DEVICE_ATUAL" || true)"
        if [ -n "$DONO_CTRL" ]; then
            aviso "Este dispositivo está numa porta da controladora $DONO_CTRL, que já vai INTEIRA à VM; um hostdev individual aqui seria redundante."
            confirmar "Mesmo assim, adicionar também como dispositivo individual?" || continue
        fi
        USB_CAPTURA="$(capturar_usb_udev)" \
            || falhar "udevadm não forneceu a captura USB necessária."
        if ! inventario_resolver_usb "$USB_CAPTURA" select "$VEND" "$PROD" "" "" "$BUS_ATUAL" "$DEVICE_ATUAL"; then
            erro "Seleção USB bloqueada: ${USB_IDENTIDADE_ERRO:-evidência serial/porta ausente ou ambígua}."
            continue
        fi
        info "Identidade comprovada: tipo=$USB_IDENTIDADE_KIND, VID:PID=$VEND:$PROD."
        [ "$USB_IDENTIDADE_KIND" != port ] \
            || info "Fallback por porta física comprovada: $USB_IDENTIDADE_PORT"

        JA_PRESENTE=0
        BUS_XML=""
        DEVICE_XML=""
        while IFS= read -r USB_XML_LINHA; do
            [ -n "$USB_XML_LINHA" ] || continue
            usb_linha_ler "$USB_XML_LINHA"
            SHA_XML="$USB_LINHA_DIGEST"
            BUS_EXISTENTE="$USB_LINHA_BUS"
            DEVICE_EXISTENTE="$USB_LINHA_DEVICE"
            [ -n "$SHA_XML" ] || continue
            if [ "$SHA_XML" = "$USB_IDENTIDADE_SHA256" ]; then
                JA_PRESENTE=$((JA_PRESENTE + 1))
                BUS_XML="$BUS_EXISTENTE"
                DEVICE_XML="$DEVICE_EXISTENTE"
            fi
        done <<< "$XML_USB_ATUAL"
        [ "$JA_PRESENTE" -le 1 ] \
            || falhar "A mesma identidade USB aparece mais de uma vez no XML; nenhuma mutação foi iniciada."

        if [ "$JA_PRESENTE" -eq 1 ]; then
            if [ "$BUS_XML" = "$USB_IDENTIDADE_BUS" ] && [ "$DEVICE_XML" = "$USB_IDENTIDADE_DEVICE" ]; then
                info "Esta identidade USB já está configurada no endereço observado; nenhuma alteração é necessária."
                continue
            fi
            aviso "A identidade USB reapareceu em ${USB_IDENTIDADE_BUS}:${USB_IDENTIDADE_DEVICE} (antes ${BUS_XML:-?}:${DEVICE_XML:-?})."
            confirmar "Atualizar somente o endereço efêmero desta identidade no próximo boot?" || continue
            usb_aplicar_candidato present "$USB_IDENTIDADE_KIND" "$USB_IDENTIDADE_SHA256" \
                "$VEND" "$PROD" "$USB_IDENTIDADE_BUS" "$USB_IDENTIDADE_DEVICE" \
                || falhar "$USB_TRANSACAO_ERRO"
            ok "Mesma identidade USB reconhecida após renumeração; endereço efêmero atualizado."
        else
            confirmar "Adicionar exatamente esta identidade USB ao próximo boot da VM?" || continue
            usb_aplicar_candidato present "$USB_IDENTIDADE_KIND" "$USB_IDENTIDADE_SHA256" \
                "$VEND" "$PROD" "$USB_IDENTIDADE_BUS" "$USB_IDENTIDADE_DEVICE" \
                || falhar "$USB_TRANSACAO_ERRO"
            ok "Identidade USB persistida por $USB_IDENTIDADE_KIND; candidato validado e pós-condição comprovada."
        fi
    done

    echo
    info "Verificação dentro do Windows: Get-PnpDevice -Class Keyboard, Mouse, AudioEndpoint, Bluetooth"
    info "Rádio Bluetooth de placa-mãe (MediaTek, Intel, Realtek) costuma exigir o driver do fabricante no Windows; sem ele fica como dispositivo desconhecido."
    ok "Etapa 15 concluída."
}

# --- Despacho: argumento explícito ou pergunta interativa (padrão do menu) ------
case "${1:-}" in
    --controladora) modo_controladora ;;
    --remover-controladora) modo_remover_controladora ;;
    --remover) modo_remover_dispositivos ;;
    "")
        titulo "Etapa 15: USB passthrough (VM: $VM_NAME)"
        if [ -n "${USB_CTRL_PCI_IDS:-}" ]; then
            info "Controladora já em passthrough: $USB_CTRL_PCI_IDS (grupo IOMMU ${USB_CTRL_IOMMU_GROUP:-?})."
        else
            info "Nenhuma controladora inteira em passthrough ainda."
        fi
        ESCOLHA_MODO="$(escolher_da_lista 'O que você quer fazer?' nao \
            'Passar dispositivos individuais (identidade estável por serial/porta)' \
            'Passar uma controladora USB inteira (hotplug nativo nas portas dela)' \
            'Remover dispositivos individuais do XML' \
            'Devolver a controladora inteira ao host')"
        case "$ESCOLHA_MODO" in
            1) modo_dispositivos ;;
            2) modo_controladora ;;
            3) modo_remover_dispositivos ;;
            4) modo_remover_controladora ;;
            *) cancelar_etapa ;;
        esac
        ;;
    *)
        falhar "Opção desconhecida da etapa 15: '$1' (use --remover, --controladora, --remover-controladora ou --verificar)."
        ;;
esac
