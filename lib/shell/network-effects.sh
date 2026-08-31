#!/bin/bash
# ============================================================================
# lib/shell/network-effects.sh - validação compartilhada da configuração de rede
# ============================================================================
# Este arquivo NÃO é executado diretamente: ele é carregado via "source" por
# lib/common.sh, que continua sendo a fachada pública das etapas.
#
# Fronteiras (seções 2.1, 2.3 e 2.4 do PLANO-FINALIZACAO.md):
#
#   * aqui fica a validação de rede que várias etapas compartilham: IPs da
#     interface, coerência entre modo/bridge/NAT e a exigência de rede
#     configurada;
#   * o planejamento transacional de bridge/NAT vive no core Python (I7) e a
#     aplicação vive na etapa 19; este módulo não aplica nada;
#   * os predicados sintáticos (ipv4_valido, mac_valido, cidr_*) moram em
#     base.sh porque decidem sobre texto e são usados fora de rede.
#
# Pré-requisitos de carga: lib/shell/base.sh, lib/shell/probes.sh, lib/shell/ui.sh.
# Carregar fora de ordem é recusado com diagnóstico, nunca com falha obscura.
#
# Sourcing deste arquivo não produz efeito: apenas define variáveis e funções.
# ============================================================================

if ! declare -F ipv4_valido > /dev/null 2>&1; then
    printf 'ERRO: lib/shell/network-effects.sh exige %s carregado antes.\n' 'lib/shell/base.sh' >&2
    return 1 2>/dev/null || exit 1
fi
if ! declare -F falhar > /dev/null 2>&1; then
    printf 'ERRO: lib/shell/network-effects.sh exige %s carregado antes.\n' 'lib/shell/ui.sh' >&2
    return 1 2>/dev/null || exit 1
fi
if ! declare -F interface_wifi > /dev/null 2>&1; then
    printf 'ERRO: lib/shell/network-effects.sh exige %s carregado antes.\n' 'lib/shell/probes.sh' >&2
    return 1 2>/dev/null || exit 1
fi

[ -n "${NETWORK_EFFECTS_SH_CARREGADO:-}" ] && return 0
NETWORK_EFFECTS_SH_CARREGADO=1

REDE_IP_ERRO=""
validar_ips_interface_rede() {
    # validar_ips_interface_rede IFACE IP_VM IP_HOST
    # O endereço do host precisa estar efetivamente na interface, e o da VM
    # precisa ser um unicast distinto dentro do mesmo prefixo IPv4.
    local iface="${1:-}" ip_vm="${2:-}" ip_host="${3:-}" cidr endereco
    local -a cidrs=()
    REDE_IP_ERRO=""
    nome_interface_valido "$iface" || { REDE_IP_ERRO="Interface de rede inválida: '$iface'."; return 1; }
    ipv4_valido "$ip_vm" || { REDE_IP_ERRO="VM_IP_FIXO inválido: '${ip_vm:-vazio}'."; return 1; }
    ipv4_valido "$ip_host" || { REDE_IP_ERRO="IP_FIXO_HOST inválido: '${ip_host:-vazio}'."; return 1; }
    [ "$ip_vm" != "$ip_host" ] || { REDE_IP_ERRO="VM_IP_FIXO e IP_FIXO_HOST não podem ser iguais."; return 1; }
    mapfile -t cidrs < <(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{print $4}')
    [ "${#cidrs[@]}" -gt 0 ] \
        || { REDE_IP_ERRO="A interface '$iface' não possui endereço IPv4 global."; return 1; }
    for cidr in "${cidrs[@]}"; do
        endereco="${cidr%/*}"
        if [ "$ip_host" = "$endereco" ]; then
            ipv4_unicast_em_cidr "$ip_vm" "$cidr" \
                || { REDE_IP_ERRO="VM_IP_FIXO=$ip_vm não é unicast no prefixo $cidr de $iface."; return 1; }
            return 0
        fi
    done
    REDE_IP_ERRO="IP_FIXO_HOST=$ip_host não está atribuído à interface '$iface'."
    return 1
}

REDE_CONFIG_ERRO=""
validar_config_rede() {
    # Valida apenas a decisão da etapa 3. VM_NIC_MAC, sub-rede e IPs podem
    # continuar vazios até as etapas 12/18, mas, quando presentes, são validados.
    local modo="${REDE_MODO:-}" iface="${INTERFACE_FISICA:-}"
    local bridge="${REDE_BRIDGE:-br0}"
    local rede_libvirt="${REDE_LIBVIRT:-passthrough-nat}"
    local bridge_libvirt="${REDE_BRIDGE_LIBVIRT:-virbr-vmnat}"
    REDE_CONFIG_ERRO=""

    case "$modo" in
        bridge|nat) : ;;
        *) REDE_CONFIG_ERRO="REDE_MODO precisa ser 'bridge' ou 'nat' (está: '${modo:-vazio}')."; return 1 ;;
    esac
    if ! nome_interface_valido "$iface"; then
        REDE_CONFIG_ERRO="INTERFACE_FISICA tem nome inválido: '${iface:-vazio}'."
        return 1
    fi
    if ! interface_fisica_elegivel "$iface"; then
        REDE_CONFIG_ERRO="INTERFACE_FISICA='$iface' não existe ou não é uma interface física elegível."
        return 1
    fi
    if [ "$modo" = "bridge" ] && interface_wifi "$iface"; then
        REDE_CONFIG_ERRO="Bridge sobre Wi-Fi station não é suportada; selecione REDE_MODO='nat'."
        return 1
    fi
    if ! nome_interface_valido "$bridge" || [ "$bridge" = "$iface" ]; then
        REDE_CONFIG_ERRO="REDE_BRIDGE='$bridge' é inválida ou coincide com o uplink."
        return 1
    fi
    if ! nome_rede_libvirt_valido "$rede_libvirt" || [ "$rede_libvirt" = "default" ]; then
        REDE_CONFIG_ERRO="REDE_LIBVIRT='$rede_libvirt' é inválida ou usa o nome reservado 'default'."
        return 1
    fi
    if ! nome_interface_valido "$bridge_libvirt" \
       || [ "$bridge_libvirt" = "$iface" ] \
       || [ "$bridge_libvirt" = "$bridge" ]; then
        REDE_CONFIG_ERRO="REDE_BRIDGE_LIBVIRT='$bridge_libvirt' é inválida ou coincide com outra interface."
        return 1
    fi
    if [ -n "${REDE_NAT_CIDR:-}" ] && ! cidr_privado_24_valido "$REDE_NAT_CIDR"; then
        REDE_CONFIG_ERRO="REDE_NAT_CIDR='$REDE_NAT_CIDR' precisa ser uma sub-rede privada /24 (terminada em .0/24)."
        return 1
    fi
    if [ -n "${VM_NIC_MAC:-}" ] && ! mac_valido "$VM_NIC_MAC"; then
        REDE_CONFIG_ERRO="VM_NIC_MAC='$VM_NIC_MAC' não é um endereço MAC válido."
        return 1
    fi
    if [ -n "${VM_IP_FIXO:-}" ] && ! ipv4_valido "$VM_IP_FIXO"; then
        REDE_CONFIG_ERRO="VM_IP_FIXO='$VM_IP_FIXO' não é um IPv4 válido."
        return 1
    fi
    if [ -n "${IP_FIXO_HOST:-}" ] && ! ipv4_valido "$IP_FIXO_HOST"; then
        REDE_CONFIG_ERRO="IP_FIXO_HOST='$IP_FIXO_HOST' não é um IPv4 válido."
        return 1
    fi
}

exigir_config_rede() {
    validar_config_rede \
        || falhar "$REDE_CONFIG_ERRO Rode: bash etapas/02-detectar-config.sh --redetectar"
}
