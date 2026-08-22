#!/bin/bash
# ============================================================================
# etapas/60-rede-bridge.sh - Etapa 19: configuração final da rede da VM
# ============================================================================
# O nome do arquivo é preservado por compatibilidade. O comportamento depende
# de REDE_MODO, gravado pela etapa 3:
#   bridge - somente Ethernet; mantém o fluxo histórico Netplan + bridge.
#   nat    - Ethernet ou Wi-Fi; NÃO toca Netplan e cria uma rede libvirt
#            dedicada, vinculada explicitamente ao uplink físico escolhido.
#
# Em ambos os modos, a NIC é localizada pelo VM_NIC_MAC persistido, nunca por
# posição no XML, e o MAC não é alterado.
# ============================================================================
SCRIPT_VERSION="1.0.0"
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

REDE_BRIDGE="${REDE_BRIDGE:-br0}"
REDE_LIBVIRT="${REDE_LIBVIRT:-passthrough-nat}"
REDE_BRIDGE_LIBVIRT="${REDE_BRIDGE_LIBVIRT:-virbr-vmnat}"
REDE_MARCADOR="vm-passthrough:60-rede-nat:v1"
NETPLAN_BRIDGE_ARQUIVO="/etc/netplan/90-vm-passthrough-bridge.yaml"
TMP_DIR=""
NAT_GATEWAY=""
NAT_VM_IP=""
NAT_DHCP_INICIO=""
NAT_DHCP_FIM=""
COLISAO_DESC=""

TX_ARMADA=0
TX_COMMIT=0
TX_MUTOU=0
TX_CONF_MUTOU=0
TX_VM_MUTOU=0
TX_REDE_MUTOU=0
TX_NETPLAN_MUTOU=0
TX_CONF_EXISTIA=0
TX_NETPLAN_EXISTIA=0
TX_REDE_EXISTIA=0
TX_REDE_PERSISTENTE=0
TX_REDE_ATIVA=0
TX_REDE_AUTOSTART=0
TX_REDE_XML_PERSISTENTE=""
TX_REDE_XML_ATIVO=""
ROLLBACK_FALHOU=0

ESTADO_REDE_NOME=""
ESTADO_REDE_EXISTE="ERRO"
ESTADO_REDE_PERSISTENTE="ERRO"
ESTADO_REDE_ATIVA="ERRO"
ESTADO_REDE_AUTOSTART="ERRO"
ESTADO_REDE_XML=""
ESTADO_REDE_ERRO=""
REDE_XML_ATUAL=""
REDE_XML_ERRO=""
DETECCAO_SUBREDE="ERRO"
REDES_LIBVIRT=()

limpar_temporarios() {
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf -- "$TMP_DIR"
    fi
    encerrar_sudo_keepalive
}

registrar_mutacao() {
    TX_MUTOU=1
    case "$1" in
        conf) TX_CONF_MUTOU=1 ;;
        vm) TX_VM_MUTOU=1 ;;
        rede) TX_REDE_MUTOU=1 ;;
        netplan) TX_NETPLAN_MUTOU=1 ;;
    esac
}

registrar_falha_rollback() {
    erro "ROLLBACK: $*"
    ROLLBACK_FALHOU=1
}

capturar_lista_redes_libvirt() {
    local saida rede existente
    REDES_LIBVIRT=()
    ESTADO_REDE_ERRO=""
    if ! saida="$(LC_ALL=C $VIRSH net-list --all --name)"; then
        ESTADO_REDE_ERRO="Falha ao enumerar as redes libvirt com '$VIRSH net-list --all --name'."
        return 2
    fi
    while IFS= read -r rede; do
        [ -n "$rede" ] || continue
        if [[ "$rede" =~ [[:cntrl:]] ]]; then
            ESTADO_REDE_ERRO="A enumeração libvirt retornou um nome de rede com caractere de controle."
            return 2
        fi
        for existente in "${REDES_LIBVIRT[@]}"; do
            if [ "$existente" = "$rede" ]; then
                ESTADO_REDE_ERRO="A enumeração libvirt retornou a rede '$rede' mais de uma vez."
                return 2
            fi
        done
        REDES_LIBVIRT+=("$rede")
    done <<< "$saida"
}

consultar_info_rede_existente() {
    local nome="$1" info linha ativa="" persistente="" autostart=""
    ESTADO_REDE_NOME="$nome"
    ESTADO_REDE_EXISTE="ERRO"
    ESTADO_REDE_PERSISTENTE="ERRO"
    ESTADO_REDE_ATIVA="ERRO"
    ESTADO_REDE_AUTOSTART="ERRO"
    ESTADO_REDE_XML=""
    if ! info="$(LC_ALL=C $VIRSH net-info "$nome")"; then
        ESTADO_REDE_ERRO="Falha ao consultar o estado da rede libvirt '$nome'."
        return 2
    fi
    while IFS= read -r linha; do
        case "$linha" in
            Active:*)
                if [ -n "$ativa" ] || ! [[ "$linha" =~ ^Active:[[:space:]]+(yes|no)[[:space:]]*$ ]]; then
                    ESTADO_REDE_ERRO="Saída inválida de net-info para Active na rede '$nome'."
                    return 2
                fi
                ativa="${BASH_REMATCH[1]}"
                ;;
            Persistent:*)
                if [ -n "$persistente" ] || ! [[ "$linha" =~ ^Persistent:[[:space:]]+(yes|no)[[:space:]]*$ ]]; then
                    ESTADO_REDE_ERRO="Saída inválida de net-info para Persistent na rede '$nome'."
                    return 2
                fi
                persistente="${BASH_REMATCH[1]}"
                ;;
            Autostart:*)
                if [ -n "$autostart" ] || ! [[ "$linha" =~ ^Autostart:[[:space:]]+(yes|no)[[:space:]]*$ ]]; then
                    ESTADO_REDE_ERRO="Saída inválida de net-info para Autostart na rede '$nome'."
                    return 2
                fi
                autostart="${BASH_REMATCH[1]}"
                ;;
        esac
    done <<< "$info"
    if [ -z "$ativa" ] || [ -z "$persistente" ] || [ -z "$autostart" ]; then
        ESTADO_REDE_ERRO="Saída incompleta de net-info para a rede '$nome'."
        return 2
    fi

    ESTADO_REDE_EXISTE="SIM"
    [ "$persistente" = "yes" ] && ESTADO_REDE_PERSISTENTE="SIM" || ESTADO_REDE_PERSISTENTE="NAO"
    [ "$ativa" = "yes" ] && ESTADO_REDE_ATIVA="SIM" || ESTADO_REDE_ATIVA="NAO"
    [ "$autostart" = "yes" ] && ESTADO_REDE_AUTOSTART="SIM" || ESTADO_REDE_AUTOSTART="NAO"
    if [ "$ESTADO_REDE_PERSISTENTE" = "NAO" ] && [ "$ESTADO_REDE_ATIVA" = "NAO" ]; then
        ESTADO_REDE_ERRO="Estado impossível para '$nome': rede existente, transitória e inativa."
        return 2
    fi
    if [ "$ESTADO_REDE_AUTOSTART" = "SIM" ] && [ "$ESTADO_REDE_PERSISTENTE" = "NAO" ]; then
        ESTADO_REDE_ERRO="Estado inválido para '$nome': rede transitória marcada para autostart."
        return 2
    fi
}

consultar_estado_rede_libvirt() {
    local nome="$1" rede ocorrencias=0
    ESTADO_REDE_NOME="$nome"
    ESTADO_REDE_EXISTE="ERRO"
    ESTADO_REDE_PERSISTENTE="ERRO"
    ESTADO_REDE_ATIVA="ERRO"
    ESTADO_REDE_AUTOSTART="ERRO"
    ESTADO_REDE_XML=""
    capturar_lista_redes_libvirt || return 2
    for rede in "${REDES_LIBVIRT[@]}"; do
        [ "$rede" = "$nome" ] && ocorrencias=$((ocorrencias + 1))
    done
    if [ "$ocorrencias" -eq 0 ]; then
        ESTADO_REDE_EXISTE="NAO"
        ESTADO_REDE_PERSISTENTE="NAO"
        ESTADO_REDE_ATIVA="NAO"
        ESTADO_REDE_AUTOSTART="NAO"
        return 0
    fi
    if [ "$ocorrencias" -ne 1 ]; then
        ESTADO_REDE_ERRO="A enumeração não determinou univocamente a existência da rede '$nome'."
        return 2
    fi
    consultar_info_rede_existente "$nome"
}

# Sondagens usadas durante mutações não podem confundir erro operacional com
# estado falso: diante de uma consulta inconclusiva, abortam e deixam o trap
# transacional restaurar qualquer alteração já realizada.
rede_ativa() {
    consultar_estado_rede_libvirt "$REDE_LIBVIRT" \
        || falhar "$ESTADO_REDE_ERRO Não foi possível determinar se a rede está ativa."
    [ "$ESTADO_REDE_EXISTE" = "SIM" ] && [ "$ESTADO_REDE_ATIVA" = "SIM" ]
}

rede_autostart() {
    consultar_estado_rede_libvirt "$REDE_LIBVIRT" \
        || falhar "$ESTADO_REDE_ERRO Não foi possível determinar o autostart da rede."
    [ "$ESTADO_REDE_EXISTE" = "SIM" ] && [ "$ESTADO_REDE_AUTOSTART" = "SIM" ]
}

capturar_xml_estado_rede() {
    local nome="$1" estado="$2" xml
    ESTADO_REDE_XML=""
    if [ "$ESTADO_REDE_NOME" != "$nome" ] || [ "$ESTADO_REDE_EXISTE" != "SIM" ]; then
        ESTADO_REDE_ERRO="O XML de '$nome' foi solicitado sem um estado existente previamente validado."
        return 2
    fi
    case "$estado" in
        persistente)
            [ "$ESTADO_REDE_PERSISTENTE" = "SIM" ] || return 1
            if ! xml="$($VIRSH net-dumpxml --inactive "$nome")"; then
                ESTADO_REDE_ERRO="Falha ao capturar o XML persistente da rede '$nome'."
                return 2
            fi
            ;;
        ativo)
            [ "$ESTADO_REDE_ATIVA" = "SIM" ] || return 1
            if ! xml="$($VIRSH net-dumpxml "$nome")"; then
                ESTADO_REDE_ERRO="Falha ao capturar o XML ativo da rede '$nome'."
                return 2
            fi
            ;;
        *)
            ESTADO_REDE_ERRO="Estado XML desconhecido solicitado para '$nome': '$estado'."
            return 2
            ;;
    esac
    [ -n "$xml" ] || { ESTADO_REDE_ERRO="O XML $estado da rede '$nome' veio vazio."; return 2; }
    ESTADO_REDE_XML="$xml"
}

capturar_estado_transacao() {
    if [ -e "$CONF_ARQUIVO" ]; then
        TX_CONF_EXISTIA=1
        cp -p "$CONF_ARQUIVO" "$TMP_DIR/passthrough.conf.anterior"
    fi
    $VIRSH dumpxml --inactive "$VM_NAME" > "$TMP_DIR/vm-anterior.xml" \
        || falhar "Falha ao capturar o XML anterior da VM antes da transação."

    if sudo test -e "$NETPLAN_BRIDGE_ARQUIVO"; then
        TX_NETPLAN_EXISTIA=1
        sudo cp -p "$NETPLAN_BRIDGE_ARQUIVO" "$TMP_DIR/netplan-bridge.anterior.yaml" \
            || falhar "Falha ao capturar $NETPLAN_BRIDGE_ARQUIVO antes da transação."
    fi

    consultar_estado_rede_libvirt "$REDE_LIBVIRT" \
        || falhar "$ESTADO_REDE_ERRO A captura transacional foi recusada."
    if [ "$ESTADO_REDE_EXISTE" = "SIM" ]; then
        TX_REDE_EXISTIA=1
        if [ "$ESTADO_REDE_PERSISTENTE" = "SIM" ]; then
            TX_REDE_PERSISTENTE=1
            $VIRSH net-dumpxml --inactive "$REDE_LIBVIRT" \
                > "$TMP_DIR/rede-anterior-persistente.xml" \
                || falhar "Falha ao capturar o XML persistente anterior da rede $REDE_LIBVIRT."
            TX_REDE_XML_PERSISTENTE="$TMP_DIR/rede-anterior-persistente.xml"
        fi
        if [ "$ESTADO_REDE_ATIVA" = "SIM" ]; then
            TX_REDE_ATIVA=1
            $VIRSH net-dumpxml "$REDE_LIBVIRT" > "$TMP_DIR/rede-anterior-ativa.xml" \
                || falhar "Falha ao capturar o XML ativo anterior da rede $REDE_LIBVIRT."
            TX_REDE_XML_ATIVO="$TMP_DIR/rede-anterior-ativa.xml"
        fi
        [ "$ESTADO_REDE_AUTOSTART" = "SIM" ] && TX_REDE_AUTOSTART=1
    fi

    TX_ARMADA=1
    info "Transação armada: estado anterior da rede, VM, Netplan dedicado e passthrough.conf capturado."
}

restaurar_netplan_anterior() {
    [ "$TX_NETPLAN_MUTOU" -eq 1 ] || return 0
    if [ "$TX_NETPLAN_EXISTIA" -eq 1 ]; then
        if ! sudo cp -p "$TMP_DIR/netplan-bridge.anterior.yaml" "$NETPLAN_BRIDGE_ARQUIVO"; then
            registrar_falha_rollback "não foi possível restaurar $NETPLAN_BRIDGE_ARQUIVO."
        fi
    else
        if ! sudo rm -f "$NETPLAN_BRIDGE_ARQUIVO"; then
            registrar_falha_rollback "não foi possível remover a criação parcial de $NETPLAN_BRIDGE_ARQUIVO."
        fi
    fi
    if ! sudo netplan generate; then
        registrar_falha_rollback "'netplan generate' falhou ao reaplicar a configuração anterior."
    fi
    if ! sudo netplan apply; then
        registrar_falha_rollback "'netplan apply' falhou ao reaplicar a configuração anterior."
    fi
}

restaurar_rede_anterior() {
    local atual_existe=0 atual_persistente=0 atual_ativa=0 atual_autostart=0
    local REDE_ATIVA_RECRIADA=0
    [ "$TX_REDE_MUTOU" -eq 1 ] || return 0

    if ! consultar_estado_rede_libvirt "$REDE_LIBVIRT"; then
        registrar_falha_rollback "$ESTADO_REDE_ERRO Não foi possível sondar a rede atual antes da restauração."
        return 0
    fi
    if [ "$ESTADO_REDE_ATIVA" = "SIM" ]; then
        if ! $VIRSH net-destroy "$REDE_LIBVIRT" >/dev/null; then
            registrar_falha_rollback "não foi possível parar a rede atual $REDE_LIBVIRT."
        fi
    fi
    if [ "$ESTADO_REDE_PERSISTENTE" = "SIM" ]; then
        if ! $VIRSH net-undefine "$REDE_LIBVIRT" >/dev/null; then
            registrar_falha_rollback "não foi possível remover a definição atual de $REDE_LIBVIRT."
        fi
    fi

    if [ "$TX_REDE_EXISTIA" -eq 1 ]; then
        if [ "$TX_REDE_PERSISTENTE" -eq 1 ]; then
            REDE_ATIVA_RECRIADA=0
            if [ "$TX_REDE_ATIVA" -eq 1 ]; then
                if $VIRSH net-create "$TX_REDE_XML_ATIVO" >/dev/null; then
                    REDE_ATIVA_RECRIADA=1
                else
                    registrar_falha_rollback "não foi possível recriar o XML ativo anterior de $REDE_LIBVIRT."
                fi
            fi
            # Definir enquanto a instância anterior está ativa preserva também
            # uma eventual divergência legítima entre XML ativo e persistente.
            if ! $VIRSH net-define "$TX_REDE_XML_PERSISTENTE" >/dev/null; then
                registrar_falha_rollback "não foi possível restaurar o XML persistente de $REDE_LIBVIRT."
            fi
            if [ "$TX_REDE_AUTOSTART" -eq 1 ]; then
                if ! $VIRSH net-autostart "$REDE_LIBVIRT" >/dev/null; then
                    registrar_falha_rollback "não foi possível restaurar autostart=sim em $REDE_LIBVIRT."
                fi
            else
                if ! $VIRSH net-autostart "$REDE_LIBVIRT" --disable >/dev/null; then
                    registrar_falha_rollback "não foi possível restaurar autostart=não em $REDE_LIBVIRT."
                fi
            fi
            if [ "$TX_REDE_ATIVA" -eq 1 ] && [ "$REDE_ATIVA_RECRIADA" -eq 0 ]; then
                if ! $VIRSH net-start "$REDE_LIBVIRT" >/dev/null; then
                    registrar_falha_rollback "não foi possível ao menos restaurar o estado ativo de $REDE_LIBVIRT."
                fi
            fi
        elif [ "$TX_REDE_ATIVA" -eq 1 ]; then
            if ! $VIRSH net-create "$TX_REDE_XML_ATIVO" >/dev/null; then
                registrar_falha_rollback "não foi possível recriar a rede transitória anterior $REDE_LIBVIRT."
            fi
        fi
    fi

    if ! consultar_estado_rede_libvirt "$REDE_LIBVIRT"; then
        registrar_falha_rollback "$ESTADO_REDE_ERRO Não foi possível validar o estado da rede após a restauração."
        return 0
    fi
    [ "$ESTADO_REDE_EXISTE" = "SIM" ] && atual_existe=1
    [ "$ESTADO_REDE_PERSISTENTE" = "SIM" ] && atual_persistente=1
    [ "$ESTADO_REDE_ATIVA" = "SIM" ] && atual_ativa=1
    [ "$ESTADO_REDE_AUTOSTART" = "SIM" ] && atual_autostart=1
    [ "$atual_existe" -eq "$TX_REDE_EXISTIA" ] \
        || registrar_falha_rollback "existência de $REDE_LIBVIRT não voltou ao estado anterior."
    [ "$atual_persistente" -eq "$TX_REDE_PERSISTENTE" ] \
        || registrar_falha_rollback "persistência de $REDE_LIBVIRT não voltou ao estado anterior."
    [ "$atual_ativa" -eq "$TX_REDE_ATIVA" ] \
        || registrar_falha_rollback "estado ativo de $REDE_LIBVIRT não voltou ao valor anterior."
    [ "$atual_autostart" -eq "$TX_REDE_AUTOSTART" ] \
        || registrar_falha_rollback "autostart de $REDE_LIBVIRT não voltou ao valor anterior."
}

restaurar_vm_anterior() {
    [ "$TX_VM_MUTOU" -eq 1 ] || return 0
    if ! $VIRSH define "$TMP_DIR/vm-anterior.xml" >/dev/null; then
        registrar_falha_rollback "não foi possível restaurar o XML anterior da VM $VM_NAME."
    fi
}

restaurar_conf_anterior() {
    [ "$TX_CONF_MUTOU" -eq 1 ] || return 0
    if [ "$TX_CONF_EXISTIA" -eq 1 ]; then
        if ! cp -p "$TMP_DIR/passthrough.conf.anterior" "$CONF_ARQUIVO"; then
            registrar_falha_rollback "não foi possível restaurar $CONF_ARQUIVO."
        fi
    else
        if ! rm -f "$CONF_ARQUIVO"; then
            registrar_falha_rollback "não foi possível remover o passthrough.conf criado parcialmente."
        fi
    fi
}

executar_rollback() {
    ROLLBACK_FALHOU=0
    aviso "Falha/sinal após mutação: iniciando rollback transacional da etapa 19."
    restaurar_netplan_anterior
    restaurar_rede_anterior
    restaurar_vm_anterior
    restaurar_conf_anterior
    if [ "$ROLLBACK_FALHOU" -eq 0 ]; then
        ok "Rollback concluído: estados anteriores restaurados."
        return 0
    fi
    erro "ROLLBACK INCOMPLETO: revise as falhas acima antes de executar a etapa novamente."
    return 1
}

tratar_saida() {
    local status="$1"
    trap - EXIT INT TERM
    set +e
    if [ "$TX_ARMADA" -eq 1 ] && [ "$TX_COMMIT" -eq 0 ] && [ "$TX_MUTOU" -eq 1 ]; then
        executar_rollback
        if [ "$?" -ne 0 ] && [ "$status" -eq 0 ]; then
            status=1
        fi
    fi
    limpar_temporarios
    # Idioma documentado da ponte (seção 3.8): a janela de sinal precisa limpar
    # a raiz privada do core, além dos temporários da própria etapa.
    python_core_temporarios_limpar
    exit "$status"
}

salvar_conf_transacao() {
    registrar_mutacao conf
    salvar_conf "$1" "$2"
}

commit_transacao() {
    TX_COMMIT=1
    TX_ARMADA=0
    ok "Commit lógico da transação de rede concluído."
}

# --- Inspeção de XML pelo core Python ----------------------------------------
# Todo XML de domínio e de rede desta etapa é analisado pelo core, com
# cardinalidade explícita e nenhum dado local em argv. Os nomes das funções e as
# conclusões que o restante da etapa consome permanecem os mesmos.

NIC_XML_PERMITIDAS=(
    CORE_VERSION PROTOCOL_VERSION SUBCOMMAND
    NIC_COUNT MAC_COUNT CONSUMER_COUNT NETWORK_MATCH_COUNT NETWORK_MATCH_MAC
    MAC_TYPE MAC_NETWORK MAC_BRIDGE MAC_DEV MAC_HAS_ADDRESS
    'NIC_#_MAC' 'NIC_#_TYPE' 'NIC_#_NETWORK' 'NIC_#_SOURCE'
)
REDE_XML_PERMITIDAS=(
    CORE_VERSION PROTOCOL_VERSION SUBCOMMAND
    NAME UUID DESCRIPTION MARKER_MATCH
    FORWARD_COUNT FORWARD_MODE FORWARD_DEV BRIDGE_NAME BRIDGE_STP
    IP_COUNT DHCP_RANGE_COUNT DHCP_RANGE_START DHCP_RANGE_END
    DHCP_MAC_COUNT DHCP_MAC_IP DHCP_IP_COUNT FINGERPRINT
    'IP_#_FAMILY' 'IP_#_ADDRESS' 'IP_#_NETMASK' 'IP_#_PREFIX'
    'IP_#_NETWORK' 'IP_#_BROADCAST'
)

inspecionar_nic_dominio() {
    # $1 = XML do domínio; $2 = prefixo das variáveis; demais = pares extras.
    local conteudo="$1" prefixo="$2"
    local -a payload=()
    shift 2
    payload=(xml "$conteudo" "$@")
    python_core_pares_payload NIC_XML_PERMITIDAS "$prefixo" domain-interfaces payload \
        2>/dev/null
}

inspecionar_rede_xml() {
    # $1 = XML da rede; $2 = prefixo das variáveis; demais = pares extras.
    local conteudo="$1" prefixo="$2"
    local -a payload=()
    shift 2
    payload=(xml "$conteudo" "$@")
    python_core_pares_payload REDE_XML_PERMITIDAS "$prefixo" network-inspect payload \
        2>/dev/null
}

COLISAO_XML_PERMITIDAS=(
    CORE_VERSION PROTOCOL_VERSION SUBCOMMAND
    NAME MARKER_MATCH OVERLAP_COUNT OVERLAP_CIDR CANDIDATE_CIDR
)

inspecionar_colisao_rede() {
    # $1 = XML da rede; $2 = CIDR candidato. Publica COLX_OVERLAP_COUNT e
    # COLX_OVERLAP_CIDR. Um XML de rede inválido devolve falha, nunca "livre".
    local conteudo="$1" candidata="$2"
    local -a payload=()
    payload=(xml "$conteudo" candidate_cidr "$candidata")
    python_core_pares_payload COLISAO_XML_PERMITIDAS COLX_ network-overlap payload \
        2>/dev/null
}

nic_vm_contagem() {
    local xml
    xml="$($VIRSH dumpxml --inactive "$VM_NAME" 2>/dev/null)" || { printf '0\n'; return 0; }
    inspecionar_nic_dominio "$xml" NICVM_ nic_mac "${VM_NIC_MAC,,}" \
        || { printf '0\n'; return 0; }
    printf '%s\n' "$NICVM_MAC_COUNT"
}

nic_vm_confere_fonte() {
    local tipo="$1" atributo="$2" valor="$3" xml atual_fonte
    xml="$($VIRSH dumpxml --inactive "$VM_NAME" 2>/dev/null)" || return 1
    inspecionar_nic_dominio "$xml" NICVM_ nic_mac "${VM_NIC_MAC,,}" || return 1
    [ "$NICVM_MAC_COUNT" = 1 ] || return 1
    case "$atributo" in
        bridge) atual_fonte="$NICVM_MAC_BRIDGE" ;;
        network) atual_fonte="$NICVM_MAC_NETWORK" ;;
        dev) atual_fonte="$NICVM_MAC_DEV" ;;
        *) return 1 ;;
    esac
    [ "$NICVM_MAC_TYPE" = "$tipo" ] && [ "$atual_fonte" = "$valor" ]
}

master_da_interface() {
    ip -o link show "$1" 2>/dev/null \
        | awk '{for (i=1; i<=NF; i++) if ($i=="master") {print $(i+1); exit}}'
}

bridge_runtime_confere() {
    local bridge_link uplink_link flags
    bridge_link="$(ip -o link show "$REDE_BRIDGE" 2>/dev/null)" || return 1
    flags="${bridge_link#*<}"
    [ "$flags" != "$bridge_link" ] || return 1
    flags="${flags%%>*}"
    case ",$flags," in
        *,UP,*) : ;;
        *) return 1 ;;
    esac
    uplink_link="$(ip -o link show "$INTERFACE_FISICA" 2>/dev/null)" || return 1
    [[ " $uplink_link " == *" master $REDE_BRIDGE "* ]]
}

derivar_parametros_nat() {
    local base prefixo
    cidr_privado_24_valido "${REDE_NAT_CIDR:-}" || return 1
    base="${REDE_NAT_CIDR%/24}"
    prefixo="${base%.*}"
    NAT_GATEWAY="${prefixo}.1"
    NAT_VM_IP="${prefixo}.10"
    NAT_DHCP_INICIO="${prefixo}.100"
    NAT_DHCP_FIM="${prefixo}.254"
}

rede_gerenciada() {
    REDE_XML_ATUAL=""
    consultar_estado_rede_libvirt "$REDE_LIBVIRT" || return 2
    [ "$ESTADO_REDE_EXISTE" = "SIM" ] || return 1
    if [ "$ESTADO_REDE_PERSISTENTE" = "SIM" ]; then
        capturar_xml_estado_rede "$REDE_LIBVIRT" persistente || return 2
    else
        capturar_xml_estado_rede "$REDE_LIBVIRT" ativo || return 2
    fi
    REDE_XML_ATUAL="$ESTADO_REDE_XML"
    if ! inspecionar_rede_xml "$REDE_XML_ATUAL" MARCA_ marker "$REDE_MARCADOR"; then
        ESTADO_REDE_ERRO="Falha ao analisar o marcador da rede libvirt '$REDE_LIBVIRT'."
        return 2
    fi
    # O marcador é comparado explicitamente pelo core: rede homônima sem o
    # marcador deste projeto não é nossa e precisa ser preservada.
    [ "$MARCA_MARKER_MATCH" = 1 ]
}

rede_nat_xml_confere() {
    # Retornos: 0=confere, 1=diverge/estado ausente, 2=erro operacional.
    local estado="${1:-}" xml status
    REDE_XML_ERRO=""
    derivar_parametros_nat || return 1
    consultar_estado_rede_libvirt "$REDE_LIBVIRT" \
        || { REDE_XML_ERRO="$ESTADO_REDE_ERRO"; return 2; }
    [ "$ESTADO_REDE_EXISTE" = "SIM" ] || return 1
    case "$estado" in
        persistente)
            [ "$ESTADO_REDE_PERSISTENTE" = "SIM" ] || return 1
            if capturar_xml_estado_rede "$REDE_LIBVIRT" persistente; then
                xml="$ESTADO_REDE_XML"
            else
                status=$?
                [ "$status" -eq 1 ] && return 1
                REDE_XML_ERRO="$ESTADO_REDE_ERRO"
                return 2
            fi
            ;;
        ativo)
            [ "$ESTADO_REDE_ATIVA" = "SIM" ] || return 1
            if capturar_xml_estado_rede "$REDE_LIBVIRT" ativo; then
                xml="$ESTADO_REDE_XML"
            else
                status=$?
                [ "$status" -eq 1 ] && return 1
                REDE_XML_ERRO="$ESTADO_REDE_ERRO"
                return 2
            fi
            ;;
        *) return 1 ;;
    esac
    if ! inspecionar_rede_xml "$xml" NATX_ \
            marker "$REDE_MARCADOR" nic_mac "${VM_NIC_MAC,,}" vm_ip "$NAT_VM_IP"; then
        REDE_XML_ERRO="Falha ao analisar o XML $estado da rede '$REDE_LIBVIRT'."
        return 2
    fi
    # Um único bloco <ip> é o contrato desta etapa: zero ou vários significam
    # configuração fora do modelo gerenciado e devem divergir, não ser aceitos
    # pela primeira entrada.
    [ "$NATX_MARKER_MATCH" = 1 ] \
        && [ "$NATX_FORWARD_COUNT" = 1 ] \
        && [ "$NATX_FORWARD_MODE" = "nat" ] \
        && [ "$NATX_FORWARD_DEV" = "$INTERFACE_FISICA" ] \
        && [ "$NATX_BRIDGE_NAME" = "$REDE_BRIDGE_LIBVIRT" ] \
        && [ "$NATX_IP_COUNT" = 1 ] \
        && [ "$NATX_IP_0_ADDRESS" = "$NAT_GATEWAY" ] \
        && [ "$NATX_IP_0_NETMASK" = "255.255.255.0" ] \
        && [ "$NATX_DHCP_RANGE_COUNT" = 1 ] \
        && [ "$NATX_DHCP_RANGE_START" = "$NAT_DHCP_INICIO" ] \
        && [ "$NATX_DHCP_RANGE_END" = "$NAT_DHCP_FIM" ] \
        && [ "$NATX_DHCP_MAC_COUNT" = 1 ] \
        && [ "$NATX_DHCP_MAC_IP" = "$NAT_VM_IP" ] \
        && [ "$NATX_DHCP_IP_COUNT" = 1 ]
}

verificar() {
    local status
    if ! validar_config_rede; then
        v_falta "$REDE_CONFIG_ERRO"
        v_fim
    fi
    python_core_disponivel \
        || { v_indeterminado "Core Python indisponível para analisar XML: ${PYTHON_CORE_ERRO:-sem diagnóstico}."; v_fim; }
    if [ -z "${VM_NAME:-}" ] || ! nome_vm_valido "$VM_NAME"; then
        v_falta "VM_NAME ausente ou inválido."
        v_fim
    fi
    if [ -z "${VM_NIC_MAC:-}" ]; then
        v_falta "VM_NIC_MAC ainda não persistido; execute esta etapa para migrar configurações antigas."
        v_fim
    fi
    if ! mac_valido "$VM_NIC_MAC"; then
        v_falta "VM_NIC_MAC inválido: $VM_NIC_MAC"
        v_fim
    fi
    if ! vm_existe "$VM_NAME"; then
        v_falta "VM '$VM_NAME' não existe."
        v_fim
    fi
    if [ "$(nic_vm_contagem)" = "1" ]; then
        v_ok "NIC identificada pelo MAC persistido $VM_NIC_MAC."
    else
        v_falta "O XML da VM não contém exatamente uma NIC com MAC $VM_NIC_MAC."
    fi

    if [ "$REDE_MODO" = "bridge" ]; then
        if bridge_runtime_confere; then
            v_ok "Bridge $REDE_BRIDGE administrativamente UP com uplink $INTERFACE_FISICA vinculado."
        else
            v_falta "Bridge $REDE_BRIDGE deve existir, estar administrativamente UP e ter $INTERFACE_FISICA como porta."
        fi
        if nic_vm_confere_fonte bridge bridge "$REDE_BRIDGE"; then
            v_ok "VM usando bridge=$REDE_BRIDGE."
        else
            v_falta "Fonte da NIC da VM não é bridge=$REDE_BRIDGE."
        fi
        if validar_ips_interface_rede "$REDE_BRIDGE" "${VM_IP_FIXO:-}" "${IP_FIXO_HOST:-}"; then
            v_ok "Endereços da bridge coerentes: VM Windows=$VM_IP_FIXO, host Linux=$IP_FIXO_HOST, na mesma sub-rede de $REDE_BRIDGE."
        else
            v_falta "$REDE_IP_ERRO"
        fi
        if consultar_estado_rede_libvirt "$REDE_LIBVIRT"; then
            if [ "$ESTADO_REDE_EXISTE" = "SIM" ]; then
                if rede_gerenciada; then
                    if [ "$ESTADO_REDE_ATIVA" = "NAO" ] && [ "$ESTADO_REDE_AUTOSTART" = "NAO" ]; then
                        v_ok "Rede NAT gerenciada $REDE_LIBVIRT permanece definida, inativa e sem autostart."
                    else
                        v_falta "Rede NAT gerenciada $REDE_LIBVIRT deveria estar inativa e sem autostart no modo bridge."
                    fi
                else
                    status=$?
                    if [ "$status" -eq 1 ]; then
                        v_ok "Rede homônima $REDE_LIBVIRT sem marcador foi preservada sem validação/alteração."
                    else
                        v_falta "$ESTADO_REDE_ERRO"
                    fi
                fi
            fi
        else
            v_falta "$ESTADO_REDE_ERRO"
        fi
    else
        UPLINK_IPV4_EFETIVO="$(dispositivo_uplink_ipv4_efetivo || true)"
        if [ -z "$UPLINK_IPV4_EFETIVO" ]; then
            v_falta "Não foi possível determinar o uplink IPv4 efetivo com 'ip -4 route get 1.1.1.1'."
        elif [ "$INTERFACE_FISICA" = "$UPLINK_IPV4_EFETIVO" ]; then
            v_ok "NAT vinculado ao uplink IPv4 efetivo: $INTERFACE_FISICA."
        else
            v_falta "INTERFACE_FISICA=$INTERFACE_FISICA, mas a rota IPv4 efetiva usa $UPLINK_IPV4_EFETIVO. Torne o adaptador selecionado a rota padrão ou desconecte/ajuste a métrica do outro e execute novamente."
        fi
        if [ -z "${REDE_NAT_CIDR:-}" ] || ! derivar_parametros_nat; then
            v_falta "REDE_NAT_CIDR ausente ou inválida."
            v_fim
        fi
        MASTER_UPLINK="$(master_da_interface "$INTERFACE_FISICA")"
        if [ -n "$MASTER_UPLINK" ]; then
            v_falta "Uplink $INTERFACE_FISICA ainda é porta de '$MASTER_UPLINK'; restaure o Netplan antes de usar NAT."
        else
            v_ok "Uplink $INTERFACE_FISICA não está escravizado a bridge anterior."
        fi
        if consultar_estado_rede_libvirt "$REDE_LIBVIRT"; then
            if [ "$ESTADO_REDE_ATIVA" = "SIM" ]; then
                v_ok "Rede libvirt $REDE_LIBVIRT ativa."
            else
                v_falta "Rede libvirt $REDE_LIBVIRT inativa/ausente."
            fi
            if [ "$ESTADO_REDE_AUTOSTART" = "SIM" ]; then
                v_ok "Rede libvirt $REDE_LIBVIRT em autostart."
            else
                v_falta "Rede libvirt $REDE_LIBVIRT sem autostart."
            fi
        else
            v_falta "$ESTADO_REDE_ERRO"
        fi
        if rede_nat_xml_confere persistente; then
            v_ok "Definição persistente NAT corresponde a uplink/bridge/sub-rede/reserva."
        else
            status=$?
            if [ "$status" -eq 2 ]; then
                v_falta "$REDE_XML_ERRO"
            else
                v_falta "Definição persistente da rede NAT não corresponde à configuração."
            fi
        fi
        if rede_nat_xml_confere ativo; then
            v_ok "Backend NAT ativo corresponde à definição persistente selecionada."
        else
            status=$?
            if [ "$status" -eq 2 ]; then
                v_falta "$REDE_XML_ERRO"
            else
                v_falta "Backend NAT ativo diverge da configuração persistente (reinício da rede pendente)."
            fi
        fi
        if ip link show "$REDE_BRIDGE_LIBVIRT" 2>/dev/null | grep -q '<[^>]*UP'; then
            v_ok "Bridge virtual $REDE_BRIDGE_LIBVIRT ativa."
        else
            v_falta "Bridge virtual $REDE_BRIDGE_LIBVIRT inexistente ou down."
        fi
        if nic_vm_confere_fonte network network "$REDE_LIBVIRT"; then
            v_ok "VM usando network=$REDE_LIBVIRT."
        else
            v_falta "Fonte da NIC da VM não é network=$REDE_LIBVIRT."
        fi
        [ "${VM_IP_FIXO:-}" = "$NAT_VM_IP" ] \
            && v_ok "IP da VM Windows=$VM_IP_FIXO (reserva DHCP libvirt)." \
            || v_falta "O IP da VM Windows deveria ser $NAT_VM_IP."
        [ "${IP_FIXO_HOST:-}" = "$NAT_GATEWAY" ] \
            && v_ok "Gateway virtual do host=$IP_FIXO_HOST." \
            || v_falta "O gateway virtual do host deveria ser $NAT_GATEWAY."
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

guard_mutation network.configure || exit 1
exigir_nao_root
exigir_sudo
exigir_comando virsh ip awk virt-xml-validate
python_core_disponivel \
    || falhar "O core Python do projeto não respondeu: ${PYTHON_CORE_ERRO:-diagnóstico ausente}."

exigir_conf VM_NAME REDE_MODO INTERFACE_FISICA
exigir_config_rede
nome_vm_valido "$VM_NAME" || falhar "VM_NAME='$VM_NAME' contém caracteres não seguros."
exigir_vm_desligada "$VM_NAME"

if [ "$REDE_MODO" = "nat" ]; then
    UPLINK_IPV4_EFETIVO="$(dispositivo_uplink_ipv4_efetivo || true)"
    [ -n "$UPLINK_IPV4_EFETIVO" ] \
        || falhar "Não foi possível determinar o uplink IPv4 efetivo com 'ip -4 route get 1.1.1.1'; nenhuma alteração foi feita."
    [ "$INTERFACE_FISICA" = "$UPLINK_IPV4_EFETIVO" ] \
        || falhar "INTERFACE_FISICA=$INTERFACE_FISICA, mas a rota IPv4 efetiva usa $UPLINK_IPV4_EFETIVO. Torne o adaptador selecionado a rota padrão ou desconecte/ajuste a métrica do outro e execute novamente; nenhuma alteração foi feita."
    ok "Trava NAT: $INTERFACE_FISICA é o uplink IPv4 efetivo (consulta local; nenhum pacote enviado)."
fi

titulo "Orientação antes das alterações de rede"
cat <<ORIENTACAO
Finalidade: conectar a NIC persistente da VM pelo modo selecionado: $REDE_MODO.
  bridge: põe a VM diretamente na LAN; exige Ethernet e altera o Netplan do host.
  NAT: mantém a VM em rede privada atrás do libvirt; aceita Ethernet/Wi-Fi e não altera Netplan.
Endereços: VM_IP_FIXO é o IP da VM Windows; IP_FIXO_HOST é o IP do host na
bridge (modo bridge) ou o gateway virtual do host acessível pela VM (modo NAT).
Risco: no modo bridge, mover $INTERFACE_FISICA para $REDE_BRIDGE pode derrubar
rede e SSH imediatamente; prefira console local e uma janela de manutenção.
Recuperação: antes do commit, falha/sinal aciona o rollback do estado capturado.
Na bridge, netplan try volta em cerca de 120 s sem confirmação; se necessário,
use o console local para restaurar o backup datado anunciado e rode netplan apply.
No modo bridge, IP vazio deixa reservas, --verificar e a etapa 20 pendentes.
Não há reboot do host; a NIC persistente será usada no próximo start da VM.
ORIENTACAO

TMP_DIR="$(mktemp -d)"
trap 'tratar_saida $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
capturar_estado_transacao
salvar_conf_transacao REDE_BRIDGE "$REDE_BRIDGE"
salvar_conf_transacao REDE_LIBVIRT "$REDE_LIBVIRT"
salvar_conf_transacao REDE_BRIDGE_LIBVIRT "$REDE_BRIDGE_LIBVIRT"

garantir_vm_nic_mac() {
    local conteudo total indice escolhido mac tipo rede fonte idx recomendada
    local nome_mac nome_tipo nome_rede nome_fonte
    conteudo="$($VIRSH dumpxml --inactive "$VM_NAME")" \
        || falhar "Não foi possível capturar o XML inativo da VM."
    if [ -n "${VM_NIC_MAC:-}" ]; then
        mac_valido "$VM_NIC_MAC" || falhar "VM_NIC_MAC inválido: $VM_NIC_MAC"
        VM_NIC_MAC="${VM_NIC_MAC,,}"
        inspecionar_nic_dominio "$conteudo" GARNIC_ nic_mac "$VM_NIC_MAC" \
            || falhar "Não foi possível analisar as NICs do XML da VM."
        [ "$GARNIC_MAC_COUNT" = "1" ] \
            || falhar "VM_NIC_MAC=$VM_NIC_MAC não identifica exatamente uma NIC no XML da VM."
        salvar_conf_transacao VM_NIC_MAC "$VM_NIC_MAC"
        return 0
    fi

    # Migração segura de configurações antigas: consulta e conta TODAS as NICs.
    # Só há escolha automática quando o domínio possui uma única interface.
    inspecionar_nic_dominio "$conteudo" GARNIC_ \
        || falhar "Não foi possível analisar as NICs do XML da VM."
    total="$GARNIC_NIC_COUNT"
    [ "$total" -gt 0 ] || falhar "A VM não possui NIC para configurar."
    if [ "$total" -eq 1 ]; then
        escolhido=0
    else
        DESCRICOES_NIC=()
        for (( indice = 0; indice < total; indice++ )); do
            nome_mac="GARNIC_NIC_${indice}_MAC"
            nome_tipo="GARNIC_NIC_${indice}_TYPE"
            nome_rede="GARNIC_NIC_${indice}_NETWORK"
            nome_fonte="GARNIC_NIC_${indice}_SOURCE"
            mac="${!nome_mac}"
            tipo="${!nome_tipo}"
            rede="${!nome_rede}"
            fonte="${!nome_fonte}"
            recomendada=""
            [ "$rede" = "default" ] && recomendada="; RECOMENDADA (network=default)"
            DESCRICOES_NIC+=("MAC=$mac; tipo=$tipo; fonte=${fonte:-sem fonte}$recomendada")
        done
        aviso "Configuração antiga sem VM_NIC_MAC e com várias NICs: escolha entre todas as interfaces abaixo."
        idx="$(escolher_da_lista 'NIC a gerenciar (número)' nao "${DESCRICOES_NIC[@]}")"
        escolhido=$((idx - 1))
    fi
    nome_mac="GARNIC_NIC_${escolhido}_MAC"
    mac="${!nome_mac}"
    mac_valido "$mac" || falhar "A NIC escolhida não possui MAC válido: '$mac'."
    salvar_conf_transacao VM_NIC_MAC "${mac,,}"
    ok "Configuração antiga migrada: VM_NIC_MAC=$VM_NIC_MAC."
}

trocar_fonte_nic() {
    local tipo="$1" atributo="$2" valor="$3" origem candidato conteudo
    origem="$TMP_DIR/vm-rede-${tipo}-origem.xml"
    candidato="$TMP_DIR/vm-rede-${tipo}.xml"
    $VIRSH dumpxml --inactive "$VM_NAME" > "$origem" \
        || falhar "Não foi possível capturar o XML da VM antes de trocar a fonte da NIC."
    conteudo="$(<"$origem")"
    inspecionar_nic_dominio "$conteudo" TROCA_ nic_mac "${VM_NIC_MAC,,}" \
        || falhar "Não foi possível analisar as NICs antes da edição."
    [ "$TROCA_MAC_COUNT" = "1" ] \
        || falhar "O MAC $VM_NIC_MAC não identifica exatamente uma NIC antes da edição."

    # O candidato é gerado pelo core (que recusa cardinalidade diferente de um e
    # exige o MAC preservado) e validado pelo schema antes do define.
    xml_candidato_fonte_nic "$origem" "$candidato" \
        "${VM_NIC_MAC,,}" "$tipo" "$atributo" "$valor" \
        || falhar "Candidato da NIC recusado: $XML_CANDIDATO_ERRO"
    virt-xml-validate "$candidato" domain >/dev/null \
        || falhar "O schema libvirt recusou o candidato da NIC; nada foi definido."
    xml_backup "$VM_NAME"
    registrar_mutacao vm
    $VIRSH define "$candidato" >/dev/null
    nic_vm_confere_fonte "$tipo" "$atributo" "$valor" \
        || falhar "A fonte da NIC não foi comprovada após o define; revise $XML_BACKUP_PATH."
    ok "Fonte da NIC $VM_NIC_MAC alterada para $tipo/$atributo=$valor; MAC preservado."
}

perguntar_ipv4_opcional() {
    local texto="$1" padrao="${2:-}" resposta
    while :; do
        resposta="$(perguntar "$texto (ENTER para informar depois)" "$padrao")"
        if [ -z "$resposta" ]; then
            return 1
        fi
        if ipv4_valido "$resposta"; then
            echo "$resposta"
            return 0
        fi
        erro "IPv4 inválido: '$resposta'."
    done
}

bridge_atual_rede_gerenciada() {
    local xml bridge status
    if rede_gerenciada; then
        :
    else
        return $?
    fi
    if [ "$ESTADO_REDE_ATIVA" = "SIM" ]; then
        if capturar_xml_estado_rede "$REDE_LIBVIRT" ativo; then
            xml="$ESTADO_REDE_XML"
        else
            status=$?
            [ "$status" -eq 1 ] && ESTADO_REDE_ERRO="A rede '$REDE_LIBVIRT' perdeu o estado ativo durante a inspeção."
            return 2
        fi
    else
        xml="$REDE_XML_ATUAL"
    fi
    if inspecionar_rede_xml "$xml" BRATU_ marker "$REDE_MARCADOR"; then
        bridge="$BRATU_BRIDGE_NAME"
    else
        ESTADO_REDE_ERRO="Falha ao analisar a bridge atual da rede gerenciada '$REDE_LIBVIRT'."
        return 2
    fi
    if ! nome_interface_valido "$bridge"; then
        ESTADO_REDE_ERRO="A rede gerenciada '$REDE_LIBVIRT' não possui uma bridge atual válida."
        return 2
    fi
    printf '%s\n' "$bridge"
}

listar_consumidores_rede_gerenciada() {
    local lista dominio xml quantidade bridge_atual
    CONSUMIDORES_REDE=()
    bridge_atual="$(bridge_atual_rede_gerenciada)" \
        || falhar "${ESTADO_REDE_ERRO:-Não foi possível identificar a bridge da rede gerenciada $REDE_LIBVIRT.}"
    lista="$($VIRSH list --all --name)" \
        || falhar "Não foi possível listar todas as VMs definidas antes da migração NAT -> bridge."
    while IFS= read -r dominio; do
        [ -n "$dominio" ] || continue
        [ "$dominio" = "$VM_NAME" ] && continue
        xml="$($VIRSH dumpxml --inactive "$dominio")" \
            || falhar "Não foi possível inspecionar o XML inativo da VM '$dominio'; migração recusada."
        inspecionar_nic_dominio "$xml" CONSU_ \
            network_name "$REDE_LIBVIRT" \
            bridge_names "$(printf '%s\n%s' "$bridge_atual" "$REDE_BRIDGE_LIBVIRT")" \
            || falhar "Não foi possível analisar as interfaces da VM '$dominio'; migração recusada."
        quantidade="$CONSU_CONSUMER_COUNT"
        [[ "$quantidade" =~ ^[0-9]+$ ]] \
            || falhar "Contagem de interfaces inválida ao inspecionar a VM '$dominio'; migração recusada."
        [ "$quantidade" = "0" ] || CONSUMIDORES_REDE+=("$dominio")
    done <<< "$lista"
}

preparar_nat_para_bridge() {
    local consumidor status
    consultar_estado_rede_libvirt "$REDE_LIBVIRT" \
        || falhar "$ESTADO_REDE_ERRO Migração NAT -> bridge recusada."
    [ "$ESTADO_REDE_EXISTE" = "SIM" ] || return 0
    if rede_gerenciada; then
        :
    else
        status=$?
        if [ "$status" -eq 1 ]; then
            aviso "A rede homônima '$REDE_LIBVIRT' não tem o marcador deste projeto; ela não será alterada."
            return 0
        fi
        falhar "$ESTADO_REDE_ERRO Migração NAT -> bridge recusada."
    fi

    listar_consumidores_rede_gerenciada
    if [ "${#CONSUMIDORES_REDE[@]}" -gt 0 ]; then
        erro "A migração NAT -> bridge foi recusada: outras VMs definidas consomem $REDE_LIBVIRT ou sua bridge:"
        for consumidor in "${CONSUMIDORES_REDE[@]}"; do
            erro "  - $consumidor"
        done
        falhar "Remova/troque a fonte dessas NICs e execute novamente; nenhuma configuração de Netplan foi tocada."
    fi

    consultar_estado_rede_libvirt "$REDE_LIBVIRT" \
        || falhar "$ESTADO_REDE_ERRO Não foi possível revalidar a rede antes da migração."
    [ "$ESTADO_REDE_EXISTE" = "SIM" ] \
        || falhar "A rede $REDE_LIBVIRT desapareceu durante a inspeção; migração recusada."
    if [ "$ESTADO_REDE_AUTOSTART" = "SIM" ]; then
        registrar_mutacao rede
        $VIRSH net-autostart "$REDE_LIBVIRT" --disable >/dev/null \
            || falhar "Falha ao desabilitar o autostart de $REDE_LIBVIRT antes da bridge."
    fi
    if [ "$ESTADO_REDE_ATIVA" = "SIM" ]; then
        registrar_mutacao rede
        $VIRSH net-destroy "$REDE_LIBVIRT" >/dev/null \
            || falhar "Falha ao parar $REDE_LIBVIRT antes de aplicar o Netplan."
    fi
    ok "Rede NAT gerenciada $REDE_LIBVIRT deixada inativa/ausente e sem autostart para a migração."
}

configurar_bridge() {
    local tmp_netplan backup="" arquivo_igual=0 runtime_ok=0 precisa_aplicar=1
    local resposta host_atual
    exigir_comando netplan
    interface_wifi "$INTERFACE_FISICA" \
        && falhar "Bridge sobre Wi-Fi station não é suportada. Selecione REDE_MODO=nat na etapa 3."
    titulo "Etapa 19: bridge Ethernet ($INTERFACE_FISICA -> $REDE_BRIDGE)"

    confirmar "Aplicar/verificar bridge $REDE_BRIDGE sobre $INTERFACE_FISICA?" || falhar "Cancelado."
    # Antes até mesmo de consultar o arquivo dedicado, trata a eventual rede
    # NAT gerenciada e recusa consumidores definidos, ativos ou não.
    preparar_nat_para_bridge

    tmp_netplan="$TMP_DIR/netplan-bridge.yaml"
    cat > "$tmp_netplan" <<NETPLAN
network:
  version: 2
  ethernets:
    $INTERFACE_FISICA:
      dhcp4: no
      dhcp6: no
  bridges:
    $REDE_BRIDGE:
      interfaces: [$INTERFACE_FISICA]
      dhcp4: yes
      parameters:
        stp: true
        forward-delay: 4
NETPLAN

    if sudo test -e "$NETPLAN_BRIDGE_ARQUIVO" \
       && sudo cmp -s "$tmp_netplan" "$NETPLAN_BRIDGE_ARQUIVO"; then
        arquivo_igual=1
    fi
    if bridge_runtime_confere; then
        runtime_ok=1
    fi
    [ "$arquivo_igual" -eq 1 ] && [ "$runtime_ok" -eq 1 ] && precisa_aplicar=0

    if [ "$precisa_aplicar" -eq 1 ]; then
        titulo "Etapa 19.1/3 Netplan dedicado (somente modo bridge)"
        registrar_mutacao netplan
        if sudo test -e "$NETPLAN_BRIDGE_ARQUIVO"; then
            backup="${NETPLAN_BRIDGE_ARQUIVO}.bak-$(date +%Y%m%d-%H%M%S)"
            sudo cp -p "$NETPLAN_BRIDGE_ARQUIVO" "$backup" \
                || falhar "Falha ao criar backup datado de $NETPLAN_BRIDGE_ARQUIVO."
            ok "Backup criado: $backup"
        else
            info "Será criado somente o arquivo dedicado: $NETPLAN_BRIDGE_ARQUIVO"
        fi
        if [ "$arquivo_igual" -eq 0 ]; then
            sudo install -m 600 "$tmp_netplan" "$NETPLAN_BRIDGE_ARQUIVO" \
                || falhar "Falha ao gravar $NETPLAN_BRIDGE_ARQUIVO."
        fi
        sudo netplan generate \
            || falhar "netplan generate reprovou a configuração; o rollback restaurará o estado anterior."
        echo
        aviso "Vai rodar 'netplan try': sem confirmação, a configuração anterior volta em ~120 segundos."
        sudo netplan try \
            || falhar "netplan try falhou/reverteu; o rollback reaplicará a configuração anterior."
        sudo netplan apply \
            || falhar "netplan apply falhou; o rollback reaplicará a configuração anterior."
        bridge_runtime_confere \
            || falhar "Pós-condição da bridge falhou após netplan apply: $REDE_BRIDGE deve existir, estar administrativamente UP e ter $INTERFACE_FISICA como porta."
        ok "Bridge aplicada por $NETPLAN_BRIDGE_ARQUIVO; outros YAMLs/interfaces foram preservados."
    else
        info "$NETPLAN_BRIDGE_ARQUIVO já corresponde à bridge ativa; Netplan mantido."
    fi

    ip addr show "$REDE_BRIDGE" | sed 's/^/  /'
    ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1 \
        && ok "Conectividade externa do host OK via bridge." \
        || aviso "Sem resposta de 8.8.8.8; confira cabo, DHCP e roteador."

    titulo "Etapa 19.2/3 NIC da VM na bridge"
    if nic_vm_confere_fonte bridge bridge "$REDE_BRIDGE"; then
        info "NIC $VM_NIC_MAC já usa bridge=$REDE_BRIDGE."
    else
        trocar_fonte_nic bridge bridge "$REDE_BRIDGE"
    fi

    titulo "Etapa 19.3/3 Reservas DHCP no roteador"
    echo "MAC da VM:   $VM_NIC_MAC"
    echo -n "MAC do host em $REDE_BRIDGE: "
    ip link show "$REDE_BRIDGE" | awk '/link\/ether/{print $2; achou=1} END{if (!achou) print "não encontrado"}'
    cat <<INSTRUCOES
No roteador:
  1. reserve um endereço da LAN para o MAC da VM -> IP da VM Windows (VM_IP_FIXO);
  2. reserve outro para o MAC de $REDE_BRIDGE -> IP do host Linux na bridge (IP_FIXO_HOST).
A etapa 20 restringe o airlock à interface $REDE_BRIDGE e ao IP da VM Windows.
INSTRUCOES
    if resposta="$(perguntar_ipv4_opcional 'IP reservado para a VM Windows' "${VM_IP_FIXO:-}")"; then
        salvar_conf_transacao VM_IP_FIXO "$resposta"
    fi
    host_atual="$(ip -4 -o addr show dev "$REDE_BRIDGE" 2>/dev/null | awk 'NR==1 {sub(/\/.*/, "", $4); print $4}')"
    if resposta="$(perguntar_ipv4_opcional "IP reservado para o host Linux em $REDE_BRIDGE" "${IP_FIXO_HOST:-$host_atual}")"; then
        salvar_conf_transacao IP_FIXO_HOST "$resposta"
    fi
    if [ -n "${VM_IP_FIXO:-}" ] && [ -n "${IP_FIXO_HOST:-}" ]; then
        validar_ips_interface_rede "$REDE_BRIDGE" "$VM_IP_FIXO" "$IP_FIXO_HOST" \
            || falhar "$REDE_IP_ERRO Corrija as reservas/renove o DHCP e execute a etapa novamente."
        ok "Reservas coerentes com o IPv4 efetivo de $REDE_BRIDGE."
    else
        aviso "Endereços da bridge incompletos: a rede pode estar aplicada, mas a etapa 19 permanece pendente."
        aviso "Preencha o IP da VM Windows e o IP do host Linux, renove o DHCP e rode --verificar antes da etapa 20."
    fi
    info "No Windows, 'ipconfig' deve mostrar o IP da VM Windows na mesma sub-rede da LAN."
}

netmask_para_prefixo() {
    local mascara="$1" inteiro bit prefixo=0 viu_zero=0
    inteiro="$(ipv4_para_inteiro "$mascara")" || return 1
    for ((bit=31; bit>=0; bit--)); do
        if (( (inteiro >> bit) & 1 )); then
            [ "$viu_zero" -eq 0 ] || return 1
            prefixo=$((prefixo + 1))
        else
            viu_zero=1
        fi
    done
    echo "$prefixo"
}

bridge_libvirt_pertence_rede() {
    local bridge status
    if bridge="$(bridge_atual_rede_gerenciada)"; then
        [ "$bridge" = "$REDE_BRIDGE_LIBVIRT" ]
    else
        status=$?
        [ "$status" -eq 1 ] && return 1
        return 2
    fi
}

inteiro_para_ipv4_rede() {
    local valor="$1"
    printf '%d.%d.%d.%d\n' \
        $(( (valor >> 24) & 255 )) $(( (valor >> 16) & 255 )) \
        $(( (valor >> 8) & 255 )) $(( valor & 255 ))
}

preparar_excecoes_rotas_rede_atual() {
    local xml endereco prefixo inicio fim intervalo status
    TEM_EXCECOES_ROTA_REDE_ATUAL=0
    ROTA_REDE_ATUAL_BRIDGE=""
    ROTA_REDE_ATUAL_CIDR=""
    ROTA_REDE_ATUAL_GATEWAY=""
    ROTA_REDE_ATUAL_ENDERECO_REDE=""
    ROTA_REDE_ATUAL_BROADCAST=""
    consultar_estado_rede_libvirt "$REDE_LIBVIRT" || return 2
    [ "$ESTADO_REDE_EXISTE" = "SIM" ] && [ "$ESTADO_REDE_ATIVA" = "SIM" ] || return 1
    if capturar_xml_estado_rede "$REDE_LIBVIRT" ativo; then
        xml="$ESTADO_REDE_XML"
    else
        status=$?
        [ "$status" -eq 1 ] && return 1
        return 2
    fi
    if ! inspecionar_rede_xml "$xml" ROTAX_ marker "$REDE_MARCADOR"; then
        ESTADO_REDE_ERRO="Falha ao analisar o XML ativo da rede atual '$REDE_LIBVIRT'."
        return 2
    fi
    [ "$ROTAX_MARKER_MATCH" = 1 ] || return 1
    # Exatamente um bloco <ip> é o contrato: várias entradas exigem revisão.
    if [ "$ROTAX_IP_COUNT" != 1 ]; then
        ESTADO_REDE_ERRO="A rede '$REDE_LIBVIRT' declara $ROTAX_IP_COUNT blocos <ip>; esperado 1."
        return 2
    fi
    ROTA_REDE_ATUAL_BRIDGE="$ROTAX_BRIDGE_NAME"
    endereco="$ROTAX_IP_0_ADDRESS"
    prefixo="$ROTAX_IP_0_PREFIX"
    if ! nome_interface_valido "$ROTA_REDE_ATUAL_BRIDGE" || ! ipv4_valido "$endereco"; then
        ESTADO_REDE_ERRO="XML ativo inválido ao preparar as exceções de rota de '$REDE_LIBVIRT'."
        return 2
    fi
    if ! intervalo="$(cidr_intervalo "$endereco/$prefixo")"; then
        ESTADO_REDE_ERRO="Prefixo IPv4 inválido no XML ativo da rede '$REDE_LIBVIRT'."
        return 2
    fi
    read -r inicio fim <<< "$intervalo"
    ROTA_REDE_ATUAL_ENDERECO_REDE="$(inteiro_para_ipv4_rede "$inicio")"
    ROTA_REDE_ATUAL_BROADCAST="$(inteiro_para_ipv4_rede "$fim")"
    ROTA_REDE_ATUAL_CIDR="$ROTA_REDE_ATUAL_ENDERECO_REDE/$prefixo"
    ROTA_REDE_ATUAL_GATEWAY="$endereco"
    TEM_EXCECOES_ROTA_REDE_ATUAL=1
}

rota_kernel_exata_da_rede_atual() {
    local classe="$1" destino="$2" dev="$3" linha="$4"
    [ "$TEM_EXCECOES_ROTA_REDE_ATUAL" -eq 1 ] || return 1
    [ "$dev" = "$ROTA_REDE_ATUAL_BRIDGE" ] || return 1
    [[ " $linha " == *" proto kernel "* ]] || return 1
    case "$classe" in
        conectada)
            [ "$destino" = "$ROTA_REDE_ATUAL_CIDR" ]
            ;;
        local)
            [ "$destino" = "$ROTA_REDE_ATUAL_GATEWAY/32" ]
            ;;
        broadcast)
            [ "$destino" = "$ROTA_REDE_ATUAL_ENDERECO_REDE/32" ] \
                || [ "$destino" = "$ROTA_REDE_ATUAL_BROADCAST/32" ]
            ;;
        *) return 1 ;;
    esac
}

detectar_colisao_subrede() {
    local candidata="$1" rotas linha destino dev i token tipo classe rede estado xml
    local status
    local -a campos_rota=() redes=() estados_xml=()
    COLISAO_DESC=""
    DETECCAO_SUBREDE="ERRO"

    if ! rotas="$(ip -4 route show table all)"; then
        COLISAO_DESC="falha ao consultar 'ip -4 route show table all'"
        return 0
    fi
    if ! capturar_lista_redes_libvirt; then
        COLISAO_DESC="$ESTADO_REDE_ERRO"
        return 0
    fi
    redes=("${REDES_LIBVIRT[@]}")

    if preparar_excecoes_rotas_rede_atual; then
        :
    else
        status=$?
        if [ "$status" -ne 1 ]; then
            COLISAO_DESC="$ESTADO_REDE_ERRO"
            return 0
        fi
    fi

    while IFS= read -r linha; do
        [ -n "$linha" ] || continue
        read -r -a campos_rota <<< "$linha"
        i=0
        tipo="${campos_rota[0]:-}"
        classe="conectada"
        case "$tipo" in
            default) continue ;;
            unicast) classe="conectada"; i=1 ;;
            local|broadcast) classe="$tipo"; i=1 ;;
            unreachable|prohibit|blackhole|throw) classe="outra"; i=1 ;;
        esac
        destino="${campos_rota[$i]:-}"
        [ "$destino" = "default" ] && continue
        if ipv4_valido "$destino"; then
            destino="$destino/32"
        fi
        if ! cidr_intervalo "$destino" >/dev/null 2>&1; then
            COLISAO_DESC="saída de rota IPv4 não reconhecida: '$linha'"
            return 0
        fi
        dev=""
        for ((i=0; i<${#campos_rota[@]}; i++)); do
            token="${campos_rota[$i]}"
            if [ "$token" = "dev" ] && [ $((i + 1)) -lt "${#campos_rota[@]}" ]; then
                dev="${campos_rota[$((i + 1))]}"
                break
            fi
        done
        # A única exceção são as três classes de rotas proto kernel exatas
        # produzidas pela sub-rede ativa da rede gerenciada. Qualquer outra
        # sobreposição, inclusive na mesma bridge, bloqueia a operação.
        if rota_kernel_exata_da_rede_atual "$classe" "$destino" "$dev" "$linha"; then
            continue
        fi
        if cidrs_sobrepoem "$candidata" "$destino"; then
            COLISAO_DESC="rota '$linha'"
            DETECCAO_SUBREDE="COLISAO"
            return 0
        fi
    done <<< "$rotas"

    for rede in "${redes[@]}"; do
        if ! consultar_info_rede_existente "$rede"; then
            COLISAO_DESC="$ESTADO_REDE_ERRO"
            return 0
        fi
        estados_xml=()
        [ "$ESTADO_REDE_ATIVA" = "SIM" ] && estados_xml+=(ativo)
        [ "$ESTADO_REDE_PERSISTENTE" = "SIM" ] && estados_xml+=(persistente)
        for estado in "${estados_xml[@]}"; do
            if capturar_xml_estado_rede "$rede" "$estado"; then
                xml="$ESTADO_REDE_XML"
            else
                status=$?
                COLISAO_DESC="${ESTADO_REDE_ERRO:-Falha ao capturar o XML $estado da rede '$rede' (status $status).}"
                return 0
            fi
            # A sobreposição das redes libvirt é decidida pelo core, que usa
            # `ipaddress` e já recusa endereço/prefixo/netmask inválidos. O XML
            # da rede-alvo continua sendo validado nos dois estados; apenas a
            # decisão de colisão a ignora, porque a sub-rede dela é justamente a
            # candidata usada para atualizá-la.
            if ! inspecionar_colisao_rede "$xml" "$candidata"; then
                COLISAO_DESC="falha ao analisar o XML $estado da rede libvirt '$rede'"
                return 0
            fi
            [ "$rede" = "$REDE_LIBVIRT" ] && continue
            if [ "$COLX_OVERLAP_COUNT" != 0 ]; then
                COLISAO_DESC="rede libvirt '$rede'/$estado ($COLX_OVERLAP_CIDR)"
                DETECCAO_SUBREDE="COLISAO"
                return 0
            fi
        done
    done
    DETECCAO_SUBREDE="LIVRE"
}

escolher_subrede_nat() {
    local terceiro candidata
    if [ -n "${REDE_NAT_CIDR:-}" ]; then
        cidr_privado_24_valido "$REDE_NAT_CIDR" \
            || falhar "REDE_NAT_CIDR='$REDE_NAT_CIDR' não é uma sub-rede privada /24 válida."
        detectar_colisao_subrede "$REDE_NAT_CIDR"
        case "$DETECCAO_SUBREDE" in
            LIVRE) return 0 ;;
            COLISAO) falhar "Colisão detectada antes de aplicar $REDE_NAT_CIDR: $COLISAO_DESC. Escolha outra REDE_NAT_CIDR." ;;
            ERRO) falhar "Erro ao verificar colisões para $REDE_NAT_CIDR: $COLISAO_DESC. Nenhuma sub-rede foi aceita." ;;
            *) falhar "Resultado interno inválido ao verificar $REDE_NAT_CIDR: '$DETECCAO_SUBREDE'." ;;
        esac
    fi
    for ((terceiro=124; terceiro<=250; terceiro++)); do
        candidata="192.168.${terceiro}.0/24"
        detectar_colisao_subrede "$candidata"
        case "$DETECCAO_SUBREDE" in
            LIVRE)
                REDE_NAT_CIDR="$candidata"
                info "Sub-rede privada livre selecionada: $REDE_NAT_CIDR"
                return 0
                ;;
            COLISAO) : ;;
            ERRO) falhar "Erro ao verificar colisões para $candidata: $COLISAO_DESC. Nenhuma sub-rede foi aceita." ;;
            *) falhar "Resultado interno inválido ao verificar $candidata: '$DETECCAO_SUBREDE'." ;;
        esac
    done
    falhar "Não encontrei sub-rede 192.168.x.0/24 sem colisão; defina REDE_NAT_CIDR manualmente."
}

validar_bridge_libvirt_disponivel() {
    local rede bridge estado xml status
    local -a redes=() estados_xml=()

    consultar_estado_rede_libvirt "$REDE_LIBVIRT" \
        || falhar "$ESTADO_REDE_ERRO Não foi possível validar a disponibilidade da rede libvirt."
    if [ "$ESTADO_REDE_EXISTE" = "SIM" ]; then
        if rede_gerenciada; then
            :
        else
            status=$?
            if [ "$status" -eq 1 ]; then
                falhar "A rede libvirt '$REDE_LIBVIRT' já existe sem o marcador deste projeto. Escolha outro REDE_LIBVIRT; nada foi alterado."
            fi
            falhar "$ESTADO_REDE_ERRO Não foi possível validar a propriedade de '$REDE_LIBVIRT'."
        fi
    fi
    if [ -e "/sys/class/net/$REDE_BRIDGE_LIBVIRT" ]; then
        if bridge_libvirt_pertence_rede; then
            :
        else
            status=$?
            if [ "$status" -eq 2 ]; then
                falhar "Não foi possível validar a interface existente $REDE_BRIDGE_LIBVIRT contra a rede $REDE_LIBVIRT."
            fi
            falhar "A interface $REDE_BRIDGE_LIBVIRT já existe e não pertence à rede gerenciada $REDE_LIBVIRT."
        fi
    fi

    capturar_lista_redes_libvirt \
        || falhar "$ESTADO_REDE_ERRO Não foi possível validar bridges libvirt existentes."
    redes=("${REDES_LIBVIRT[@]}")
    for rede in "${redes[@]}"; do
        [ "$rede" = "$REDE_LIBVIRT" ] && continue
        consultar_info_rede_existente "$rede" \
            || falhar "$ESTADO_REDE_ERRO Não foi possível inspecionar a rede libvirt '$rede'."
        estados_xml=()
        [ "$ESTADO_REDE_ATIVA" = "SIM" ] && estados_xml+=(ativo)
        [ "$ESTADO_REDE_PERSISTENTE" = "SIM" ] && estados_xml+=(persistente)
        for estado in "${estados_xml[@]}"; do
            capturar_xml_estado_rede "$rede" "$estado" \
                || falhar "$ESTADO_REDE_ERRO Não foi possível capturar o XML $estado de '$rede'."
            xml="$ESTADO_REDE_XML"
            inspecionar_rede_xml "$xml" VBRID_ \
                || falhar "Não foi possível analisar a bridge no XML $estado da rede '$rede'."
            bridge="$VBRID_BRIDGE_NAME"
            [ -n "$bridge" ] || continue
            nome_interface_valido "$bridge" \
                || falhar "A rede libvirt '$rede' possui bridge inválida no XML $estado."
            [ "$bridge" != "$REDE_BRIDGE_LIBVIRT" ] \
                || falhar "REDE_BRIDGE_LIBVIRT=$REDE_BRIDGE_LIBVIRT já é usada pela rede libvirt '$rede' ($estado)."
        done
    done
}

rede_nat_usada_por_outra_vm_ativa() {
    local bridge_atual="$1" lista dominio xml quantidade
    nome_interface_valido "$bridge_atual" \
        || falhar "Não foi possível validar a bridge atual da rede $REDE_LIBVIRT antes do restart."
    lista="$($VIRSH list --name)" \
        || falhar "Não foi possível listar as VMs ativas antes de atualizar a rede NAT."
    while IFS= read -r dominio; do
        [ -n "$dominio" ] || continue
        [ "$dominio" = "$VM_NAME" ] && continue
        xml="$($VIRSH dumpxml "$dominio")" \
            || falhar "Não foi possível inspecionar o XML ativo da VM '$dominio'; atualização NAT recusada."
        inspecionar_nic_dominio "$xml" ATIVA_ \
            network_name "$REDE_LIBVIRT" \
            bridge_names "$(printf '%s\n%s' "$bridge_atual" "$REDE_BRIDGE_LIBVIRT")" \
            || falhar "Não foi possível analisar as interfaces ativas da VM '$dominio'; atualização NAT recusada."
        quantidade="$ATIVA_CONSUMER_COUNT"
        [[ "$quantidade" =~ ^[0-9]+$ ]] \
            || falhar "Contagem de interfaces inválida para a VM ativa '$dominio'; atualização NAT recusada."
        [ "$quantidade" = "0" ] || return 0
    done <<< "$lista"
    return 1
}

configurar_nat() {
    titulo "Etapa 19: NAT libvirt dedicado ($REDE_LIBVIRT via $INTERFACE_FISICA)"
    info "Caminho NAT: nenhuma configuração ou comando do Netplan será usado."

    local master xml_rede rede_existia="$TX_REDE_EXISTIA" precisa_definir=1
    local estava_ativa="$TX_REDE_ATIVA" ativo_confere=0 precisa_proteger_restart=0
    local xml_anterior="" xml_bridge_atual="" bridge_atual="$REDE_BRIDGE_LIBVIRT"
    local uuid="" uuid_linha="" backup_rede status
    master="$(master_da_interface "$INTERFACE_FISICA")"
    if [ -n "$master" ]; then
        if [ "$master" = "$REDE_BRIDGE" ]; then
            falhar "O uplink $INTERFACE_FISICA ainda é porta de $REDE_BRIDGE. Para migrar bridge -> NAT, restaure o backup Netplan da bridge, rode 'sudo netplan apply' e execute esta etapa novamente; o caminho NAT não altera Netplan."
        fi
        falhar "O uplink $INTERFACE_FISICA está escravizado a '$master'; remova-o dessa bridge antes de usar NAT."
    fi

    validar_bridge_libvirt_disponivel
    escolher_subrede_nat
    derivar_parametros_nat || falhar "Falha ao derivar endereços de $REDE_NAT_CIDR."

    if [ "$rede_existia" -eq 1 ]; then
        if [ "$TX_REDE_PERSISTENTE" -eq 1 ]; then
            xml_anterior="$(<"$TX_REDE_XML_PERSISTENTE")"
        else
            xml_anterior="$(<"$TX_REDE_XML_ATIVO")"
        fi
        if [ "$TX_REDE_ATIVA" -eq 1 ]; then
            xml_bridge_atual="$(<"$TX_REDE_XML_ATIVO")"
        else
            xml_bridge_atual="$xml_anterior"
        fi
        inspecionar_rede_xml "$xml_bridge_atual" NATBR_ \
            || falhar "Não foi possível analisar a bridge atual capturada de '$REDE_LIBVIRT'."
        bridge_atual="$NATBR_BRIDGE_NAME"
        nome_interface_valido "$bridge_atual" \
            || falhar "A rede existente '$REDE_LIBVIRT' não possui uma bridge atual válida."
        inspecionar_rede_xml "$xml_anterior" NATANT_ \
            || falhar "Não foi possível analisar o UUID da rede existente '$REDE_LIBVIRT'."
        uuid="$NATANT_UUID"
        if [ -n "$uuid" ]; then
            [[ "$uuid" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] \
                || falhar "UUID inválido na rede libvirt existente '$REDE_LIBVIRT'."
            uuid_linha="  <uuid>$uuid</uuid>"
        fi
    fi

    xml_rede="$TMP_DIR/rede-nat.xml"
    cat > "$xml_rede" <<XML
<network>
  <name>$REDE_LIBVIRT</name>
$uuid_linha
  <description>$REDE_MARCADOR</description>
  <forward mode='nat' dev='$INTERFACE_FISICA'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='$REDE_BRIDGE_LIBVIRT' stp='on' delay='0'/>
  <ip address='$NAT_GATEWAY' netmask='255.255.255.0'>
    <dhcp>
      <range start='$NAT_DHCP_INICIO' end='$NAT_DHCP_FIM'/>
      <host mac='${VM_NIC_MAC,,}' ip='$NAT_VM_IP'/>
    </dhcp>
  </ip>
</network>
XML

    if [ "$rede_existia" -eq 1 ] && [ "$TX_REDE_PERSISTENTE" -eq 1 ]; then
        if rede_nat_xml_confere persistente; then
            precisa_definir=0
            info "Definição persistente de $REDE_LIBVIRT já corresponde ao modo NAT selecionado."
        else
            status=$?
            [ "$status" -eq 2 ] && falhar "$REDE_XML_ERRO"
        fi
    fi
    if [ "$estava_ativa" -eq 1 ]; then
        if rede_nat_xml_confere ativo; then
            ativo_confere=1
        else
            status=$?
            [ "$status" -eq 2 ] && falhar "$REDE_XML_ERRO"
        fi
    fi
    if [ "$precisa_definir" -eq 1 ] \
       || { [ "$estava_ativa" -eq 1 ] && [ "$ativo_confere" -eq 0 ]; }; then
        precisa_proteger_restart=1
    fi
    if [ "$precisa_proteger_restart" -eq 1 ] \
       && rede_nat_usada_por_outra_vm_ativa "$bridge_atual"; then
        falhar "Outra VM ativa usa network=$REDE_LIBVIRT, bridge atual=$bridge_atual ou bridge pretendida=$REDE_BRIDGE_LIBVIRT; desligue-a antes da atualização."
    fi

    if [ "$precisa_definir" -eq 1 ]; then
        if [ "$rede_existia" -eq 1 ]; then
            mkdir -p "$BACKUPS_DIR"
            backup_rede="$BACKUPS_DIR/rede-${REDE_LIBVIRT}-$(date +%Y%m%d-%H%M%S).xml"
            printf '%s\n' "$xml_anterior" > "$backup_rede"
            info "Backup da rede libvirt salvo em: $backup_rede"
        fi
        # Uma rede transitória ativa precisa desaparecer antes de ganhar uma
        # definição persistente. O rollback sabe recriá-la como transitória.
        if [ "$rede_existia" -eq 1 ] && [ "$TX_REDE_PERSISTENTE" -eq 0 ] && rede_ativa; then
            registrar_mutacao rede
            $VIRSH net-destroy "$REDE_LIBVIRT" >/dev/null \
                || falhar "Falha ao parar a rede transitória $REDE_LIBVIRT antes de defini-la."
        fi
        registrar_mutacao rede
        $VIRSH net-define "$xml_rede" >/dev/null \
            || falhar "Falha ao definir o XML NAT de $REDE_LIBVIRT."
    fi
    if [ "$estava_ativa" -eq 1 ] \
       && { [ "$precisa_definir" -eq 1 ] || [ "$ativo_confere" -eq 0 ]; } \
       && rede_ativa; then
        registrar_mutacao rede
        $VIRSH net-destroy "$REDE_LIBVIRT" >/dev/null \
            || falhar "Falha ao reiniciar o backend ativo de $REDE_LIBVIRT."
    fi
    if ! rede_ativa; then
        registrar_mutacao rede
        $VIRSH net-start "$REDE_LIBVIRT" >/dev/null \
            || falhar "Falha ao iniciar a rede $REDE_LIBVIRT."
    fi
    if ! rede_autostart; then
        registrar_mutacao rede
        $VIRSH net-autostart "$REDE_LIBVIRT" >/dev/null \
            || falhar "Falha ao habilitar o autostart de $REDE_LIBVIRT."
    fi
    rede_ativa && rede_autostart \
        || falhar "A rede $REDE_LIBVIRT não ficou ativa e em autostart."
    rede_nat_xml_confere persistente \
        || falhar "A definição persistente de $REDE_LIBVIRT diverge do XML NAT esperado."
    rede_nat_xml_confere ativo \
        || falhar "O backend ativo de $REDE_LIBVIRT diverge da definição persistente esperada."
    validar_ips_interface_rede "$REDE_BRIDGE_LIBVIRT" "$NAT_VM_IP" "$NAT_GATEWAY" \
        || falhar "$REDE_IP_ERRO"
    ok "Rede gerenciada $REDE_LIBVIRT ativa/autostart: bridge=$REDE_BRIDGE_LIBVIRT, sub-rede=$REDE_NAT_CIDR."

    titulo "Etapa 19: NIC da VM na rede NAT dedicada"
    if nic_vm_confere_fonte network network "$REDE_LIBVIRT"; then
        info "NIC $VM_NIC_MAC já usa network=$REDE_LIBVIRT."
    else
        trocar_fonte_nic network network "$REDE_LIBVIRT"
    fi

    salvar_conf_transacao REDE_NAT_CIDR "$REDE_NAT_CIDR"
    salvar_conf_transacao VM_IP_FIXO "$NAT_VM_IP"
    salvar_conf_transacao IP_FIXO_HOST "$NAT_GATEWAY"
    ok "Reserva DHCP automática: $VM_NIC_MAC -> IP da VM Windows $VM_IP_FIXO."
    ok "Gateway virtual do host acessível pela VM: $IP_FIXO_HOST."
    info "Ao iniciar/renovar DHCP no Windows, a VM usará $VM_IP_FIXO e acessará o airlock no host em $IP_FIXO_HOST."
}

garantir_vm_nic_mac
case "$REDE_MODO" in
    bridge) configurar_bridge ;;
    nat) configurar_nat ;;
    *) falhar "REDE_MODO inválido: $REDE_MODO" ;;
esac
commit_transacao

echo
ok "Alterações da etapa 19 aplicadas: modo=$REDE_MODO, uplink=$INTERFACE_FISICA, NIC=$VM_NIC_MAC."
info "A etapa só fica pronta para o airlock quando os endereços da VM Windows e do host estão preenchidos e --verificar aprova."
