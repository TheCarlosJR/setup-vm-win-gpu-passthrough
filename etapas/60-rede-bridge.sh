#!/bin/bash
# ============================================================================
# etapas/60-rede-bridge.sh - Capítulo 23: Rede em Bridge
# ============================================================================
# 1. Reescreve o Netplan criando a bridge br0 sobre a interface física
#    (backup datado antes; teste reversível com 'netplan try').
# 2. Troca a NIC da VM da rede NAT 'default' para a bridge br0.
# 3. Mostra os MACs para a reserva de IP fixo no roteador e grava
#    VM_IP_FIXO / IP_FIXO_HOST no passthrough.conf.
#
# RISCO REAL: mexer em rede pode derrubar a conectividade. O 'netplan try'
# reverte sozinho se você não confirmar em ~120 segundos.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

verificar() {
    if ip link show br0 >/dev/null 2>&1 && ip link show br0 | grep -q 'state UP'; then
        v_ok "Bridge br0 ativa."
    else
        v_falta "Bridge br0 inexistente ou down."
    fi
    if [ -n "${VM_NAME:-}" ] && vm_existe "$VM_NAME"; then
        if $VIRSH dumpxml --inactive "$VM_NAME" | grep -q "bridge='br0'"; then
            v_ok "VM usando a bridge br0."
        else
            v_falta "VM ainda na rede NAT default."
        fi
    fi
    [ -n "${VM_IP_FIXO:-}" ]   && v_ok "VM_IP_FIXO=$VM_IP_FIXO"     || v_falta "VM_IP_FIXO não definido (reserva DHCP)."
    [ -n "${IP_FIXO_HOST:-}" ] && v_ok "IP_FIXO_HOST=$IP_FIXO_HOST" || v_falta "IP_FIXO_HOST não definido (reserva DHCP)."
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

exigir_nao_root
exigir_sudo
exigir_comando netplan xmlstarlet
exigir_conf INTERFACE_FISICA VM_NAME

titulo "Capítulo 23: Rede em bridge (interface: $INTERFACE_FISICA)"

# ----------------------------------------------------------------------------
# 1. Netplan
# ----------------------------------------------------------------------------
if ip link show br0 >/dev/null 2>&1; then
    info "br0 já existe; pulando reconfiguração do Netplan."
else
    titulo "1/3 Netplan"
    mapfile -t YAMLS < <(find /etc/netplan -maxdepth 1 -name '*.yaml' | sort)
    if [ "${#YAMLS[@]}" -gt 0 ]; then
        ARQ_NETPLAN="${YAMLS[0]}"
        info "Arquivo Netplan existente: $ARQ_NETPLAN"
        BACKUP="${ARQ_NETPLAN}.bak-$(date +%Y%m%d-%H%M%S)"
        sudo cp "$ARQ_NETPLAN" "$BACKUP"
        ok "Backup criado: $BACKUP"
        aviso "O conteúdo de $ARQ_NETPLAN será SUBSTITUÍDO pela configuração da bridge"
        aviso "(qualquer configuração de Wi-Fi nesse arquivo sai de cena; o backup preserva tudo)."
    else
        ARQ_NETPLAN="/etc/netplan/01-vm-bridge.yaml"
        info "Nenhum yaml existente; será criado: $ARQ_NETPLAN"
    fi
    confirmar "Aplicar a configuração de bridge sobre $INTERFACE_FISICA?" || falhar "Cancelado."

    sudo tee "$ARQ_NETPLAN" >/dev/null <<NETPLAN
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE_FISICA:
      dhcp4: no
      dhcp6: no
  bridges:
    br0:
      interfaces: [$INTERFACE_FISICA]
      dhcp4: yes
      parameters:
        stp: true
        forward-delay: 4
NETPLAN
    sudo chmod 600 "$ARQ_NETPLAN"

    echo
    aviso "Vai rodar 'netplan try': se a rede cair e você NÃO confirmar (ENTER),"
    aviso "a configuração anterior volta sozinha em ~120 segundos."
    sudo netplan try || falhar "netplan try falhou/revertido. Backup preservado em: ${BACKUP:-'(arquivo novo)'}"
    sudo netplan apply
    ok "Bridge aplicada."
fi

info "Estado da br0:"
ip addr show br0 | sed 's/^/  /'
ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1 && ok "Conectividade externa OK via bridge." \
    || aviso "Sem resposta de 8.8.8.8; verifique cabo/roteador."

# ----------------------------------------------------------------------------
# 2. VM na bridge
# ----------------------------------------------------------------------------
titulo "2/3 NIC da VM para a bridge"
if $VIRSH dumpxml --inactive "$VM_NAME" | grep -q "bridge='br0'"; then
    info "VM já está na br0."
else
    exigir_vm_desligada "$VM_NAME"
    xml_backup "$VM_NAME"
    TMPX="$(mktemp)"
    $VIRSH dumpxml --inactive "$VM_NAME" > "$TMPX"
    xmlstarlet ed -L \
        -u "/domain/devices/interface[1]/@type" -v bridge \
        -d "/domain/devices/interface[1]/source" \
        "$TMPX"
    xmlstarlet ed -L -s "/domain/devices/interface[1]" -t elem -n source -v '' "$TMPX"
    xmlstarlet ed -L -i "/domain/devices/interface[1]/source[not(@bridge)]" -t attr -n bridge -v br0 "$TMPX"
    xmlstarlet ed -L -d "/domain/devices/interface[1]/model" "$TMPX"
    xmlstarlet ed -L -s "/domain/devices/interface[1]" -t elem -n model -v '' "$TMPX"
    xmlstarlet ed -L -i "/domain/devices/interface[1]/model[not(@type)]" -t attr -n type -v virtio "$TMPX"
    $VIRSH define "$TMPX" >/dev/null
    rm -f "$TMPX"
    ok "Interface da VM apontada para br0 (modelo virtio)."
fi

# ----------------------------------------------------------------------------
# 3. Reserva de IP fixo (roteador) e registro no conf
# ----------------------------------------------------------------------------
titulo "3/3 IPs fixos (reserva DHCP no roteador)"
echo "MAC da VM (use na reserva do roteador):"
$VIRSH domiflist "$VM_NAME" | sed 's/^/  /'
echo "MAC da br0 do host:"
ip link show br0 | awk '/link\/ether/{print "  "$2}'
cat <<'INSTRUCOES'
No roteador (interface administrativa):
  1. Localize "Reserva de DHCP" (ou "DHCP estático" / "IP/MAC binding").
  2. Associe o MAC da VM a um IP livre -> este é o VM_IP_FIXO.
  3. Associe o MAC da br0 a outro IP -> este é o IP_FIXO_HOST.
Esses IPs são exigidos pelo firewall do airlock (etapa 61).
INSTRUCOES

RESP="$(perguntar 'IP fixo reservado para a VM (ENTER para informar depois)' "${VM_IP_FIXO:-}")"
[ -n "$RESP" ] && salvar_conf VM_IP_FIXO "$RESP"
RESP="$(perguntar 'IP fixo reservado para o host/br0 (ENTER para informar depois)' "${IP_FIXO_HOST:-}")"
[ -n "$RESP" ] && salvar_conf IP_FIXO_HOST "$RESP"

echo
info "Dentro do Windows, confirme com 'ipconfig': o IP deve estar na sub-rede da casa"
info "(não mais 192.168.122.x) e igual ao reservado."
ok "Etapa 60 concluída."
