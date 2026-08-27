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
# I7.5: fato capturado do estado ATIVO do host. A prova semântica do rollback
# do perfil de rede não pode depender só do rc de "netplan apply": o master do
# uplink é o menor fato que separa "bridge desfeita" de "bridge ainda montada".
TX_UPLINK_MASTER=""
ROLLBACK_FALHOU=0

# --- I7.5: identificador lógico do perfil de rede do host ---------------------
# O plano nomeia o artefato por identificador lógico e recusa `/` (I7.7): qual
# arquivo o materializa é decisão DESTE provider, e a tabela está aqui.
PERFIL_HOST_ID="vm-passthrough-bridge"
PERFIL_HOST_ESCOPO="host"
PERFIL_HOST_MODO=384          # 0600 em decimal, como o schema fechado exige
CONF_ESCOPO="project"
CONF_IDENTIFICADOR="${CONF_ARQUIVO##*/}"

# Estado capturado que vira pares do canal. Cada campo é preenchido por uma
# sondagem explícita; nenhum default implícito entra no snapshot.
CAP_UPLINK_MAC=""
CAP_UPLINK_KIND=""
CAP_LINKS=""
CAP_LINK_NOMES=()
CAP_ROTAS=""
CAP_BRIDGE_EXISTE=0
CAP_BRIDGE_PORTAS=""
CAP_REDE_EXISTE=0
CAP_REDE_ATIVA=0
CAP_REDE_PERSISTENTE=0
CAP_REDE_AUTOSTART=0
CAP_REDE_MARCADOR=""
CAP_REDE_XML_ATIVO=""
CAP_REDE_XML_PERSISTENTE=""
CAP_REDE_ALHEIA=0
AVISO_REDE_ALHEIA=0
CAP_ESTRANHAS=""
CAP_CONSUMIDORES=""
CAP_CONSUMIDOR_XML=()
CAP_CONSUMIDOR_IFACES=()
CAP_CONFIG=""
CAP_CONFIG_CONTEUDO=()
CAP_ALVO_XML=""
CAP_ALVO_FONTE=""
CAP_ALVO_FONTE_TIPO=""
CAP_ALVO_NIC_TOTAL=0
CAP_CAPACIDADES=""

# Fingerprints guardados (D-NET-CONCURRENCY). REVAL_BASE_* é a última
# observação ACEITA de cada componente; divergir dela fora da autorização do
# grupo em execução é conflito, não mudança nossa.
declare -A REVAL_BASE=()
REVAL_SUPERFICIE=""
REVAL_CONFLITO=""
REVAL_DIVERGENTES=""

# Plano em execução.
PLANO_CARREGADO=0
PLANO_OP_TOTAL=0
PLANO_RB_TOTAL=0
PLANO_PRE_TOTAL=0
PLANO_POS_TOTAL=0
AUTORIZACAO_GRUPO=""
CHAVES_PUBLICADAS=()
VALORES_PUBLICADOS=()
NETPLAN_TMP=""
PERFIL_BACKUP=""
PERFIL_CONTEUDO=""
XML_REDE_PRETENDIDO=""
CAP_REDE_UUID=""
CAP_CONFIG_INTENCAO=()
CAP_CONFIG_INTENCAO_REGISTROS=""
CAP_LINKS_INTENCAO=""
CAP_BRIDGE_PORTAS_INTENCAO=""
CAP_FONTE_TIPO_PRETENDIDA=""
CAP_FONTE_PRETENDIDA=""
IP_INTENCAO_VM=""
IP_INTENCAO_HOST=""
UPLINK_IPV4_EFETIVO=""

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

# I7.5: `rede_ativa` e `rede_autostart` saíram junto com o caminho imperativo.
# Elas abortavam a etapa (`falhar`) diante de sondagem inconclusiva, o que era
# adequado no meio de `configurar_nat`, mas não em prova de pós-condição: o
# rollback roda dentro do trap de saída e precisa concluir a sequência inteira
# antes de reportar ROLLBACK INCOMPLETO. Quem sonda agora é
# `consultar_estado_rede_libvirt`, e quem decide o efeito é a prova.

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

# ============================================================================
# I7.5: captura do modelo fechado de rede (I7.1) e transporte por pares
# ============================================================================
# A etapa deixou de capturar apenas os quatro recursos que ela mesma restaura e
# passou a capturar o ESTADO INTEIRO que o core modela: uplink, rotas, links,
# bridge do host, rede libvirt gerenciada, redes libvirt vizinhas, VMs
# consumidoras e artefatos de configuração com os metadados de `lstat`. É esse
# estado que vira `snapshot_*` no canal de pares, e é dele que saem os
# fingerprints guardados para revalidar concorrência (D-NET-CONCURRENCY).
#
# Quem sonda é o Bash; o core só normaliza, digere e planeja. A ordem dos
# campos de cada registro é a das tuplas `PAIRS_*_FIELDS` do módulo de rede do
# core; trocar a ordem aqui é erro tipado lá, nunca campo adivinhado.
CAPTURA_ERRO=""
PAIRS_TAB=$'\t'
PAIRS_NL=$'\n'

_dividir_campos() {
    # $1 = registro; $2 = nome do array de destino. `read` com IFS=TAB não
    # serve: TAB é whitespace de IFS e o Bash colapsa campos vazios, que são
    # legítimos no canal de pares (kind, master e metadados ausentes).
    local registro="$1" resto
    local -n _dc_ref="$2"
    _dc_ref=()
    resto="$registro"
    while :; do
        if [[ "$resto" == *"$PAIRS_TAB"* ]]; then
            _dc_ref+=("${resto%%"$PAIRS_TAB"*}")
            resto="${resto#*"$PAIRS_TAB"}"
        else
            _dc_ref+=("$resto")
            break
        fi
    done
}

capturar_links() {
    # Preenche CAP_LINKS (coleção), CAP_LINK_NOMES, CAP_UPLINK_MAC/KIND e a
    # projeção `bridge` do host, que o modelo fechado deriva dos masters.
    local saida enderecos_saida linha nome resto flags mtu master mac operstate
    local kind wireless i token registros="" portas=""
    local -a campos=()
    local -A enderecos=()
    CAP_LINKS=""; CAP_LINK_NOMES=(); CAP_UPLINK_MAC=""; CAP_UPLINK_KIND=""
    CAP_BRIDGE_EXISTE=0; CAP_BRIDGE_PORTAS=""
    if ! saida="$(ip -o link show)"; then
        CAPTURA_ERRO="Falha ao enumerar os links com 'ip -o link show'."
        return 1
    fi
    if ! enderecos_saida="$(ip -4 -o addr show)"; then
        CAPTURA_ERRO="Falha ao enumerar os endereços IPv4 com 'ip -4 -o addr show'."
        return 1
    fi
    while IFS= read -r linha; do
        [ -n "$linha" ] || continue
        read -r -a campos <<< "$linha"
        nome="${campos[1]:-}"
        [ -n "$nome" ] || continue
        for ((i = 2; i < ${#campos[@]}; i++)); do
            [ "${campos[i]}" = "inet" ] || continue
            (( i + 1 < ${#campos[@]} )) || break
            if [ -n "${enderecos[$nome]:-}" ]; then
                enderecos[$nome]+=",${campos[i + 1]}"
            else
                enderecos[$nome]="${campos[i + 1]}"
            fi
            break
        done
    done <<< "$enderecos_saida"
    while IFS= read -r linha; do
        [ -n "$linha" ] || continue
        read -r -a campos <<< "$linha"
        nome="${campos[1]:-}"
        nome="${nome%:}"
        # `ip -o link show` nomeia o par de veth/VLAN como `nome@ancora`; a
        # âncora não é nome de interface e não pertence ao modelo.
        nome="${nome%%@*}"
        [ -n "$nome" ] || continue
        flags=""; mtu=""; master=""; mac=""; operstate=""
        for ((i = 2; i < ${#campos[@]}; i++)); do
            token="${campos[i]}"
            case "$token" in
                '<'*'>') flags="${token#<}"; flags="${flags%>}" ;;
                mtu) mtu="${campos[i + 1]:-}" ;;
                master) master="${campos[i + 1]:-}" ;;
                state) operstate="${campos[i + 1]:-}" ;;
                link/ether) mac="${campos[i + 1]:-}" ;;
            esac
        done
        [[ "$mtu" =~ ^[0-9]+$ ]] || {
            CAPTURA_ERRO="O link '$nome' não declarou MTU numérica em 'ip -o link show'."
            return 1
        }
        # `kind` só é decidido pelo modelo para a bridge declarada: o schema
        # fechado exige `kind=bridge` no link dela e não representa "existe um
        # link com o nome da bridge que não é bridge". A evidência primária é
        # `/sys/class/net/NOME/bridge`, a mesma classe de sonda que
        # `interface_wifi` usa.
        kind=""
        [ -d "$(caminho_sistema "/sys/class/net/$nome/bridge")" ] && kind="bridge"
        [ "$nome" = "$REDE_BRIDGE" ] && kind="bridge"
        wireless=0
        interface_wifi "$nome" && wireless=1
        [ -n "$operstate" ] || operstate="unknown"
        registros+="${registros:+$PAIRS_NL}${enderecos[$nome]:-}$PAIRS_TAB$flags$PAIRS_TAB$kind$PAIRS_TAB$mac$PAIRS_TAB$master$PAIRS_TAB$mtu$PAIRS_TAB$nome$PAIRS_TAB${operstate,,}$PAIRS_TAB$wireless"
        CAP_LINK_NOMES+=("$nome")
        [ "$nome" = "$REDE_BRIDGE" ] && CAP_BRIDGE_EXISTE=1
        [ "$master" = "$REDE_BRIDGE" ] && portas+="${portas:+$PAIRS_NL}$nome"
        if [ "$nome" = "$INTERFACE_FISICA" ]; then
            CAP_UPLINK_MAC="$mac"
            CAP_UPLINK_KIND="$kind"
        fi
    done <<< "$saida"
    CAP_LINKS="$registros"
    CAP_BRIDGE_PORTAS="$portas"
    [ "$CAP_BRIDGE_EXISTE" -eq 1 ] || CAP_BRIDGE_PORTAS=""
    return 0
}

capturar_rotas() {
    # Uma rota multipath ocupa várias linhas: as continuações começam por
    # espaço e pertencem à rota anterior. Juntá-las antes de tokenizar é o que
    # permite ao scanner achar o primeiro `dev`/`via` da rota.
    local saida linha logica="" registros=""
    CAP_ROTAS=""
    if ! saida="$(ip -4 route show table all)"; then
        CAPTURA_ERRO="Falha ao consultar 'ip -4 route show table all'."
        return 1
    fi
    while IFS= read -r linha; do
        if [[ "$linha" == [[:space:]]* ]]; then
            logica+=" $linha"
            continue
        fi
        if [ -n "$logica" ]; then
            _capturar_rota_registro "$logica" registros || return 1
        fi
        logica="$linha"
    done <<< "$saida"
    if [ -n "$logica" ]; then
        _capturar_rota_registro "$logica" registros || return 1
    fi
    CAP_ROTAS="$registros"
    return 0
}

_capturar_rota_registro() {
    local linha="$1" destino tipo gateway="" dev="" proto="" escopo="" origem=""
    local tabela="" metrica="" i token inicio=0
    local -n _rota_ref="$2"
    local -a campos=()
    read -r -a campos <<< "$linha"
    [ "${#campos[@]}" -gt 0 ] || return 0
    case "${campos[0]}" in
        unicast|local|broadcast|throw|unreachable|prohibit|blackhole)
            tipo="${campos[0]}"; inicio=1 ;;
        *)
            tipo="unicast"; inicio=0 ;;
    esac
    destino="${campos[$inicio]:-}"
    if [ -z "$destino" ] || [[ "$destino" == -* ]]; then
        CAPTURA_ERRO="Saída de rota IPv4 não reconhecida: '$linha'."
        return 1
    fi
    for ((i = inicio + 1; i < ${#campos[@]}; i++)); do
        token="${campos[i]}"
        case "$token" in
            via) [ -n "$gateway" ] || gateway="${campos[i + 1]:-}" ;;
            dev) [ -n "$dev" ] || dev="${campos[i + 1]:-}" ;;
            proto) [ -n "$proto" ] || proto="${campos[i + 1]:-}" ;;
            scope) [ -n "$escopo" ] || escopo="${campos[i + 1]:-}" ;;
            src) [ -n "$origem" ] || origem="${campos[i + 1]:-}" ;;
            table) [ -n "$tabela" ] || tabela="${campos[i + 1]:-}" ;;
            metric) [ -n "$metrica" ] || metrica="${campos[i + 1]:-}" ;;
        esac
    done
    [ -n "$tabela" ] || tabela="main"
    _rota_ref+="${_rota_ref:+$PAIRS_NL}$destino$PAIRS_TAB$dev$PAIRS_TAB$gateway$PAIRS_TAB$metrica$PAIRS_TAB$proto$PAIRS_TAB$escopo$PAIRS_TAB$origem$PAIRS_TAB$tabela$PAIRS_TAB$tipo"
    return 0
}

_capturar_bridge_de_rede() {
    # Nome da bridge declarada por um XML de rede libvirt já capturado.
    local xml="$1" alvo="$2"
    printf -v "$alvo" '%s' ""
    [ -n "$xml" ] || return 0
    inspecionar_rede_xml "$xml" CAPBR_ || return 1
    printf -v "$alvo" '%s' "$CAPBR_BRIDGE_NAME"
    return 0
}

capturar_redes_libvirt() {
    # Rede gerenciada + redes vizinhas, cada uma com bridge POR ESTADO, como o
    # laço histórico de `validar_bridge_libvirt_disponivel` as via.
    local rede xml_ativo xml_persistente marcador ativa persistente autostart
    local bridge_ativa bridge_persistente registros=""
    CAP_REDE_EXISTE=0; CAP_REDE_ATIVA=0; CAP_REDE_PERSISTENTE=0
    CAP_REDE_AUTOSTART=0; CAP_REDE_MARCADOR=""; CAP_REDE_ALHEIA=0
    CAP_REDE_XML_ATIVO=""; CAP_REDE_XML_PERSISTENTE=""; CAP_ESTRANHAS=""
    if ! capturar_lista_redes_libvirt; then
        CAPTURA_ERRO="$ESTADO_REDE_ERRO"
        return 1
    fi
    for rede in "${REDES_LIBVIRT[@]}"; do
        if ! consultar_info_rede_existente "$rede"; then
            CAPTURA_ERRO="$ESTADO_REDE_ERRO"
            return 1
        fi
        ativa=0; persistente=0; autostart=0
        xml_ativo=""; xml_persistente=""
        [ "$ESTADO_REDE_ATIVA" = "SIM" ] && ativa=1
        [ "$ESTADO_REDE_PERSISTENTE" = "SIM" ] && persistente=1
        [ "$ESTADO_REDE_AUTOSTART" = "SIM" ] && autostart=1
        if [ "$persistente" -eq 1 ]; then
            if ! capturar_xml_estado_rede "$rede" persistente; then
                CAPTURA_ERRO="$ESTADO_REDE_ERRO"
                return 1
            fi
            xml_persistente="$ESTADO_REDE_XML"
        fi
        if [ "$ativa" -eq 1 ]; then
            if ! capturar_xml_estado_rede "$rede" ativo; then
                CAPTURA_ERRO="$ESTADO_REDE_ERRO"
                return 1
            fi
            xml_ativo="$ESTADO_REDE_XML"
        fi
        if ! inspecionar_rede_xml "${xml_persistente:-$xml_ativo}" CAPRD_; then
            CAPTURA_ERRO="Falha ao analisar o XML da rede libvirt '$rede'."
            return 1
        fi
        marcador="$CAPRD_DESCRIPTION"
        if [ "$rede" = "$REDE_LIBVIRT" ]; then
            CAP_REDE_EXISTE=1
            CAP_REDE_UUID="$CAPRD_UUID"
            CAP_REDE_ATIVA="$ativa"
            CAP_REDE_PERSISTENTE="$persistente"
            CAP_REDE_AUTOSTART="$autostart"
            CAP_REDE_MARCADOR="$marcador"
            CAP_REDE_XML_ATIVO="$xml_ativo"
            CAP_REDE_XML_PERSISTENTE="$xml_persistente"
            [ "$marcador" = "$REDE_MARCADOR" ] || CAP_REDE_ALHEIA=1
            continue
        fi
        bridge_ativa=""; bridge_persistente=""
        if [ "$ativa" -eq 1 ]; then
            _capturar_bridge_de_rede "$xml_ativo" bridge_ativa || {
                CAPTURA_ERRO="Falha ao analisar a bridge ativa da rede libvirt '$rede'."
                return 1
            }
        fi
        if [ "$persistente" -eq 1 ]; then
            _capturar_bridge_de_rede "$xml_persistente" bridge_persistente || {
                CAPTURA_ERRO="Falha ao analisar a bridge persistente da rede libvirt '$rede'."
                return 1
            }
        fi
        registros+="${registros:+$PAIRS_NL}$ativa$PAIRS_TAB$bridge_ativa$PAIRS_TAB$marcador$PAIRS_TAB$rede$PAIRS_TAB$persistente$PAIRS_TAB$bridge_persistente"
    done
    CAP_ESTRANHAS="$registros"
    # D-NET-UNMANAGED-BRIDGE (recusa integral é de I7.6): no modo bridge a
    # etapa histórica AVISA e deixa a rede homônima sem marcador intocada, ou
    # seja, declara que ela não faz parte desta transação. O modelo fechado não
    # permite a mesma rede em `libvirt_network` e em `foreign_networks`, então
    # "não faz parte da transação" é declarado como slot gerenciado ausente. No
    # modo NAT nada muda: a rede alheia é declarada como é e a precondição
    # `P-LIBVIRT-NETWORK-OWNED` recusa.
    if [ "$CAP_REDE_ALHEIA" -eq 1 ] && [ "$REDE_MODO" = "bridge" ]; then
        CAP_REDE_UUID=""
        if [ "$AVISO_REDE_ALHEIA" -eq 0 ]; then
            AVISO_REDE_ALHEIA=1
            aviso "A rede homônima '$REDE_LIBVIRT' não tem o marcador deste projeto; ela não será alterada."
        fi
        CAP_REDE_EXISTE=0; CAP_REDE_ATIVA=0; CAP_REDE_PERSISTENTE=0
        CAP_REDE_AUTOSTART=0; CAP_REDE_MARCADOR=""
        CAP_REDE_XML_ATIVO=""; CAP_REDE_XML_PERSISTENTE=""
    fi
    return 0
}

_rede_conhecida_no_snapshot() {
    local nome="$1" linha
    local -a campos=()
    if [ "$CAP_REDE_EXISTE" -eq 1 ] && [ "$nome" = "$REDE_LIBVIRT" ]; then
        return 0
    fi
    [ -n "$CAP_ESTRANHAS" ] || return 1
    while IFS= read -r linha; do
        [ -n "$linha" ] || continue
        _dividir_campos "$linha" campos
        [ "${campos[3]:-}" = "$nome" ] && return 0
    done <<< "$CAP_ESTRANHAS"
    return 1
}

_link_conhecido_no_snapshot() {
    local nome="$1" item
    for item in "${CAP_LINK_NOMES[@]}"; do
        [ "$item" = "$nome" ] && return 0
    done
    return 1
}

capturar_consumidores() {
    # Todas as OUTRAS VMs definidas, com as interfaces que o modelo fechado de
    # I7.1 sabe representar. Uma interface fora do modelo (`type='user'`, sem
    # MAC, fonte que o snapshot não conhece) não consome recurso gerenciado
    # algum e por isso é omitida; uma VM que fica sem interface representável
    # some do conjunto, o que não muda `defined_consumer_names` nem
    # `active_consumer_names`, que são justamente quem decide a recusa.
    local lista ativas="" dominio xml indice total tipo mac fonte registros=""
    local ifaces nome_mac nome_tipo nome_fonte
    CAP_CONSUMIDORES=""; CAP_CONSUMIDOR_XML=(); CAP_CONSUMIDOR_IFACES=()
    if ! lista="$($VIRSH list --all --name)"; then
        CAPTURA_ERRO="Não foi possível listar as VMs definidas do host."
        return 1
    fi
    while IFS= read -r dominio; do
        [ -n "$dominio" ] || continue
        [ "$dominio" = "$VM_NAME" ] && continue
        if [ -z "$ativas" ]; then
            if ! ativas="$($VIRSH list --name)"; then
                CAPTURA_ERRO="Não foi possível listar as VMs ativas do host."
                return 1
            fi
            ativas="$PAIRS_NL$ativas$PAIRS_NL"
        fi
        if ! xml="$($VIRSH dumpxml --inactive "$dominio")"; then
            CAPTURA_ERRO="Não foi possível inspecionar o XML inativo da VM '$dominio'."
            return 1
        fi
        if ! inspecionar_nic_dominio "$xml" CAPVM_; then
            CAPTURA_ERRO="Não foi possível analisar as interfaces da VM '$dominio'."
            return 1
        fi
        total="$CAPVM_NIC_COUNT"
        ifaces=""
        for ((indice = 0; indice < total; indice++)); do
            nome_mac="CAPVM_NIC_${indice}_MAC"
            nome_tipo="CAPVM_NIC_${indice}_TYPE"
            nome_fonte="CAPVM_NIC_${indice}_SOURCE"
            mac="${!nome_mac}"
            tipo="${!nome_tipo}"
            fonte="${!nome_fonte}"
            [ -n "$mac" ] && [ -n "$fonte" ] || continue
            case "$tipo" in
                network) _rede_conhecida_no_snapshot "$fonte" || continue ;;
                direct) _link_conhecido_no_snapshot "$fonte" || continue ;;
                bridge)
                    if [ "$CAP_BRIDGE_EXISTE" -eq 1 ] && [ "$fonte" = "$REDE_BRIDGE" ]; then
                        :
                    elif [ "$fonte" = "$REDE_BRIDGE_LIBVIRT" ]; then
                        # Consumidor real de uma bridge de rede libvirt, que o
                        # modelo fechado só sabe representar para a bridge do
                        # HOST. Recusar é fail-closed: aceitar em silêncio
                        # perderia a recusa histórica por consumidor.
                        CAPTURA_ERRO="A VM '$dominio' usa diretamente a bridge $fonte; desconecte-a antes de executar a etapa 19."
                        return 1
                    else
                        continue
                    fi
                    ;;
                *) continue ;;
            esac
            ifaces+="${ifaces:+$PAIRS_NL}$mac$PAIRS_TAB$fonte$PAIRS_TAB$tipo"
        done
        [ -n "$ifaces" ] || continue
        if [[ "$ativas" == *"$PAIRS_NL$dominio$PAIRS_NL"* ]]; then
            registros+="${registros:+$PAIRS_NL}1$PAIRS_TAB$dominio"
        else
            registros+="${registros:+$PAIRS_NL}0$PAIRS_TAB$dominio"
        fi
        CAP_CONSUMIDOR_XML+=("$xml")
        CAP_CONSUMIDOR_IFACES+=("$ifaces")
    done <<< "$lista"
    CAP_CONSUMIDORES="$registros"
    return 0
}

_capturar_artefato() {
    # $1 = escopo; $2 = identificador lógico; $3 = caminho; $4 = 1 quando o
    # arquivo exige sudo para ler. Publica um registro em CAP_CONFIG e o
    # conteúdo correspondente em CAP_CONFIG_CONTEUDO.
    local escopo="$1" identificador="$2" caminho="$3" elevado="$4"
    local metadados dispositivo inode modo uid gid nlink tamanho instante
    local conteudo="" copia
    if [ "$elevado" -eq 1 ]; then
        metadados="$(sudo stat -c '%d %i %a %u %g %h %s %.9Y' -- "$caminho" 2>/dev/null)" || metadados=""
    else
        metadados="$(stat -c '%d %i %a %u %g %h %s %.9Y' -- "$caminho" 2>/dev/null)" || metadados=""
    fi
    if [ -z "$metadados" ]; then
        CAP_CONFIG+="${CAP_CONFIG:+$PAIRS_NL}${PAIRS_TAB}0$PAIRS_TAB$PAIRS_TAB$PAIRS_TAB$identificador$PAIRS_TAB$PAIRS_TAB$PAIRS_TAB$PAIRS_TAB$PAIRS_TAB$escopo$PAIRS_TAB$PAIRS_TAB"
        CAP_CONFIG_CONTEUDO+=("")
        return 0
    fi
    read -r dispositivo inode modo uid gid nlink tamanho instante <<< "$metadados"
    [[ "$modo" =~ ^[0-7]{3,4}$ ]] || {
        CAPTURA_ERRO="Modo inesperado em '$identificador': '$modo'."
        return 1
    }
    # O schema fechado transporta `mode` em DECIMAL e `mtime_ns` em inteiro.
    modo=$(( 8#$modo ))
    instante="${instante/./}"
    if [ "$elevado" -eq 1 ]; then
        copia="$TMP_DIR/artefato-$escopo-$identificador"
        # `install -m 0644` produz uma cópia legível pelo operador sem alterar
        # o original; `cp -p` preservaria o modo 0600 do root e a leitura
        # falharia fora do harness.
        sudo install -m 0644 -- "$caminho" "$copia" >/dev/null 2>&1 || {
            CAPTURA_ERRO="Não foi possível ler o artefato '$identificador'."
            return 1
        }
        IFS= read -r -d '' conteudo < "$copia" || true
    else
        IFS= read -r -d '' conteudo < "$caminho" || true
    fi
    CAP_CONFIG+="${CAP_CONFIG:+$PAIRS_NL}$dispositivo${PAIRS_TAB}1${PAIRS_TAB}regular$PAIRS_TAB$gid$PAIRS_TAB$identificador$PAIRS_TAB$inode$PAIRS_TAB$modo$PAIRS_TAB$instante$PAIRS_TAB$nlink$PAIRS_TAB$escopo$PAIRS_TAB$tamanho$PAIRS_TAB$uid"
    CAP_CONFIG_CONTEUDO+=("$conteudo")
    return 0
}

capturar_configuracao() {
    CAP_CONFIG=""; CAP_CONFIG_CONTEUDO=()
    _capturar_artefato "$PERFIL_HOST_ESCOPO" "$PERFIL_HOST_ID" "$NETPLAN_BRIDGE_ARQUIVO" 1 || return 1
    _capturar_artefato "$CONF_ESCOPO" "$CONF_IDENTIFICADOR" "$CONF_ARQUIVO" 0 || return 1
    return 0
}

capturar_capacidades() {
    # Capacidade abstrata do plano -> executável que a fornece NESTE provider.
    # O plano nomeia só a capacidade (I7.7); a tabela vive aqui.
    local lista=""
    command -v virsh >/dev/null 2>&1 && lista+="${lista:+$PAIRS_NL}hypervisor-control"
    command -v ip >/dev/null 2>&1 && lista+="${lista:+$PAIRS_NL}host-link-inspection"
    command -v netplan >/dev/null 2>&1 && lista+="${lista:+$PAIRS_NL}host-network-apply"
    command -v virt-xml-validate >/dev/null 2>&1 && lista+="${lista:+$PAIRS_NL}domain-schema-validation"
    python_core_disponivel && lista+="${lista:+$PAIRS_NL}text-extraction"
    CAP_CAPACIDADES="$lista"
}

capturar_estado() {
    CAPTURA_ERRO=""
    capturar_links || return 1
    capturar_rotas || return 1
    capturar_redes_libvirt || return 1
    capturar_consumidores || return 1
    capturar_configuracao || return 1
    return 0
}

montar_pares_estado() {
    # $1 = prefixo (`snapshot` ou `intent`); $2 = nome do array de pares.
    local prefixo="$1" indice
    local -n _pe_ref="$2"
    _pe_ref+=(
        "${prefixo}_schema_version" 1
        "${prefixo}_uplink_kind" "$CAP_UPLINK_KIND"
        "${prefixo}_uplink_mac" "$CAP_UPLINK_MAC"
        "${prefixo}_uplink_name" "$INTERFACE_FISICA"
        "${prefixo}_routes" "$CAP_ROTAS"
        "${prefixo}_links" "$CAP_LINKS"
        "${prefixo}_bridge_exists" "$CAP_BRIDGE_EXISTE"
        "${prefixo}_bridge_name" "$REDE_BRIDGE"
        "${prefixo}_bridge_ports" "$CAP_BRIDGE_PORTAS"
        "${prefixo}_libvirt_network_active" "$CAP_REDE_ATIVA"
        "${prefixo}_libvirt_network_active_xml" "$CAP_REDE_XML_ATIVO"
        "${prefixo}_libvirt_network_autostart" "$CAP_REDE_AUTOSTART"
        "${prefixo}_libvirt_network_exists" "$CAP_REDE_EXISTE"
        "${prefixo}_libvirt_network_marker" "$CAP_REDE_MARCADOR"
        "${prefixo}_libvirt_network_name" "$REDE_LIBVIRT"
        "${prefixo}_libvirt_network_persistent" "$CAP_REDE_PERSISTENTE"
        "${prefixo}_libvirt_network_persistent_xml" "$CAP_REDE_XML_PERSISTENTE"
        "${prefixo}_foreign_networks" "$CAP_ESTRANHAS"
        "${prefixo}_consumers" "$CAP_CONSUMIDORES"
        "${prefixo}_configuration" "$CAP_CONFIG"
    )
    for indice in "${!CAP_CONSUMIDOR_XML[@]}"; do
        _pe_ref+=(
            "${prefixo}_consumer_${indice}_xml" "${CAP_CONSUMIDOR_XML[$indice]}"
            "${prefixo}_consumer_${indice}_interfaces" "${CAP_CONSUMIDOR_IFACES[$indice]}"
        )
    done
    for indice in "${!CAP_CONFIG_CONTEUDO[@]}"; do
        _pe_ref+=("${prefixo}_configuration_${indice}_content" "${CAP_CONFIG_CONTEUDO[$indice]}")
    done
}

capturar_estado_transacao() {
    capturar_estado || falhar "${CAPTURA_ERRO:-Falha ao capturar o estado da rede.} A captura transacional foi recusada."

    if [ -e "$CONF_ARQUIVO" ]; then
        TX_CONF_EXISTIA=1
        cp -p "$CONF_ARQUIVO" "$TMP_DIR/passthrough.conf.anterior"
    fi
    CAP_ALVO_XML="$($VIRSH dumpxml --inactive "$VM_NAME")" \
        || falhar "Falha ao capturar o XML anterior da VM antes da transação."
    printf '%s\n' "$CAP_ALVO_XML" > "$TMP_DIR/vm-anterior.xml"

    if sudo test -e "$NETPLAN_BRIDGE_ARQUIVO"; then
        TX_NETPLAN_EXISTIA=1
        sudo cp -p "$NETPLAN_BRIDGE_ARQUIVO" "$TMP_DIR/netplan-bridge.anterior.yaml" \
            || falhar "Falha ao capturar $NETPLAN_BRIDGE_ARQUIVO antes da transação."
    fi

    if [ "$CAP_REDE_EXISTE" -eq 1 ]; then
        TX_REDE_EXISTIA=1
        TX_REDE_PERSISTENTE="$CAP_REDE_PERSISTENTE"
        TX_REDE_ATIVA="$CAP_REDE_ATIVA"
        TX_REDE_AUTOSTART="$CAP_REDE_AUTOSTART"
        if [ "$CAP_REDE_PERSISTENTE" -eq 1 ]; then
            printf '%s\n' "$CAP_REDE_XML_PERSISTENTE" > "$TMP_DIR/rede-anterior-persistente.xml" \
                || falhar "Falha ao guardar o XML persistente anterior da rede $REDE_LIBVIRT."
            TX_REDE_XML_PERSISTENTE="$TMP_DIR/rede-anterior-persistente.xml"
        fi
        if [ "$CAP_REDE_ATIVA" -eq 1 ]; then
            printf '%s\n' "$CAP_REDE_XML_ATIVO" > "$TMP_DIR/rede-anterior-ativa.xml" \
                || falhar "Falha ao guardar o XML ativo anterior da rede $REDE_LIBVIRT."
            TX_REDE_XML_ATIVO="$TMP_DIR/rede-anterior-ativa.xml"
        fi
    fi

    TX_UPLINK_MASTER="$(master_da_interface "$INTERFACE_FISICA" || true)"

    guardar_fingerprints_capturados

    TX_ARMADA=1
    info "Transação armada: estado completo da rede, VM, Netplan dedicado, master do uplink e passthrough.conf capturado."
}

# ============================================================================
# I7.5 (D-NET-CONCURRENCY): fingerprints guardados e revalidação
# ============================================================================
# `network-snapshot` devolve o digest exato, o semântico e um por componente.
# Eles são a BASE: a cada fronteira da transação a etapa recaptura, chama
# `network-revalidate` com a base guardada e exige que só tenha mudado o que o
# plano autorizou naquele trecho — a lista `revalidate` de cada operação. Um
# componente da superfície do plano que mude fora dessa autorização é mudança
# de TERCEIRO, ou seja, conflito, e conflito é recusa fail-closed: a etapa não
# sobrescreve nada e nomeia os componentes divergentes.
#
# Comparar apenas os componentes listados, sem a base ser reobservada, nunca
# acusaria nada: a única mudança esperada entre duas observações é a nossa. Por
# isso a lista é usada como conjunto AUTORIZADO e a comparação é do complemento
# dentro da superfície do plano.
#
# A expansão de autorização é conhecimento de PROVIDER, não de plano: o modelo
# fechado deriva `bridge` de `links`, e ativar/desativar uma rede libvirt
# materializa/remove a bridge dela e as rotas conectadas correspondentes.
ESTADO_CAMPOS=(
    uplink routes links bridge libvirt_network foreign_networks consumers
    configuration
)
SNAPSHOT_PERMITIDAS=(
    "${CORE_PARES_ENVELOPE[@]}"
    BRIDGE_EXISTS BRIDGE_NAME BRIDGE_PORT_COUNT BRIDGE_PORTS
    CONFIGURATION_COUNT CONSUMER_COUNT CONSUMER_NAMES
    FINGERPRINT_EXACT FINGERPRINT_SEMANTIC
    FOREIGN_NETWORK_COUNT FOREIGN_NETWORK_NAMES
    LIBVIRT_NETWORK_ACTIVE LIBVIRT_NETWORK_AUTOSTART LIBVIRT_NETWORK_EXISTS
    LIBVIRT_NETWORK_MARKER LIBVIRT_NETWORK_NAME LIBVIRT_NETWORK_PERSISTENT
    LINK_COUNT ROUTE_COUNT SCHEMA_VERSION UPLINK_MAC UPLINK_NAME
    FINGERPRINT_COMPONENT_UPLINK FINGERPRINT_COMPONENT_ROUTES
    FINGERPRINT_COMPONENT_LINKS FINGERPRINT_COMPONENT_BRIDGE
    FINGERPRINT_COMPONENT_LIBVIRT_NETWORK FINGERPRINT_COMPONENT_FOREIGN_NETWORKS
    FINGERPRINT_COMPONENT_CONSUMERS FINGERPRINT_COMPONENT_CONFIGURATION
)
REVALIDACAO_PERMITIDAS=(
    "${CORE_PARES_ENVELOPE[@]}"
    DIVERGENT_COMPONENTS DIVERGENT_COUNT EXACT_MATCH MATCHES SCHEMA_VERSION
    SEMANTIC_MATCH EXPECTED_EXACT EXPECTED_SEMANTIC
    FINGERPRINT_EXACT FINGERPRINT_SEMANTIC
    COMPONENT_UPLINK_MATCH COMPONENT_ROUTES_MATCH COMPONENT_LINKS_MATCH
    COMPONENT_BRIDGE_MATCH COMPONENT_LIBVIRT_NETWORK_MATCH
    COMPONENT_FOREIGN_NETWORKS_MATCH COMPONENT_CONSUMERS_MATCH
    COMPONENT_CONFIGURATION_MATCH
    EXPECTED_COMPONENT_UPLINK EXPECTED_COMPONENT_ROUTES
    EXPECTED_COMPONENT_LINKS EXPECTED_COMPONENT_BRIDGE
    EXPECTED_COMPONENT_LIBVIRT_NETWORK EXPECTED_COMPONENT_FOREIGN_NETWORKS
    EXPECTED_COMPONENT_CONSUMERS EXPECTED_COMPONENT_CONFIGURATION
    FINGERPRINT_COMPONENT_UPLINK FINGERPRINT_COMPONENT_ROUTES
    FINGERPRINT_COMPONENT_LINKS FINGERPRINT_COMPONENT_BRIDGE
    FINGERPRINT_COMPONENT_LIBVIRT_NETWORK FINGERPRINT_COMPONENT_FOREIGN_NETWORKS
    FINGERPRINT_COMPONENT_CONSUMERS FINGERPRINT_COMPONENT_CONFIGURATION
)

guardar_fingerprints_capturados() {
    local campo nome
    local -a payload=()
    montar_pares_estado snapshot payload
    python_core_pares_payload SNAPSHOT_PERMITIDAS SNAP_ network-snapshot payload \
        || falhar "O core recusou o estado capturado da rede: ${PYTHON_CORE_ERRO:-sem diagnóstico}."
    REVAL_BASE=()
    for campo in "${ESTADO_CAMPOS[@]}"; do
        nome="SNAP_FINGERPRINT_COMPONENT_${campo^^}"
        REVAL_BASE[$campo]="${!nome}"
    done
    REVAL_BASE[exact]="$SNAP_FINGERPRINT_EXACT"
    REVAL_BASE[semantic]="$SNAP_FINGERPRINT_SEMANTIC"
    printf '%s\n' "$CAP_ALVO_XML" > "$TMP_DIR/obs-alvo.xml"
}

expandir_autorizacao() {
    local entrada=" $1 " saida="$1"
    [[ "$entrada" == *" links "* ]] && saida+=" bridge"
    if [[ "$entrada" == *" libvirt_network "* ]]; then
        saida+=" links routes bridge"
    fi
    printf '%s' "$saida"
}

revalidar_estado() {
    # $1 = componentes autorizados a mudar neste trecho (separados por espaço);
    # $2 = rótulo do momento, usado só no diagnóstico.
    local autorizados momento="$2" campo divergentes="" nome novo
    local -a payload=()
    REVAL_CONFLITO=""
    REVAL_DIVERGENTES=""
    [ -n "$REVAL_SUPERFICIE" ] || return 0
    autorizados=" $(expandir_autorizacao "${1:-}") "
    if ! capturar_estado; then
        REVAL_CONFLITO="${CAPTURA_ERRO:-falha ao recapturar o estado da rede} ($momento)"
        return 1
    fi
    montar_pares_estado snapshot payload
    for campo in "${ESTADO_CAMPOS[@]}"; do
        payload+=("expected_component_$campo" "${REVAL_BASE[$campo]}")
    done
    payload+=(
        expected_exact "${REVAL_BASE[exact]}"
        expected_semantic "${REVAL_BASE[semantic]}"
    )
    if ! python_core_pares_payload REVALIDACAO_PERMITIDAS RVL_ network-revalidate payload; then
        REVAL_CONFLITO="o core recusou a recaptura da rede $momento: ${PYTHON_CORE_ERRO:-sem diagnóstico}"
        return 1
    fi
    if [ "$RVL_DIVERGENT_COUNT" != 0 ]; then
        while IFS= read -r campo; do
            [ -n "$campo" ] || continue
            [[ "$REVAL_SUPERFICIE" == *" $campo "* ]] || continue
            [[ "$autorizados" == *" $campo "* ]] && continue
            divergentes+="${divergentes:+, }$campo"
        done <<< "$RVL_DIVERGENT_COMPONENTS"
    fi
    novo=""
    if [[ "$REVAL_SUPERFICIE" == *" target "* ]] && [ -s "$TMP_DIR/obs-alvo.xml" ]; then
        if novo="$($VIRSH dumpxml --inactive "$VM_NAME" 2>/dev/null)"; then
            printf '%s\n' "$novo" > "$TMP_DIR/obs-alvo-novo.xml"
            if ! xml_dominio_equivalente "$TMP_DIR/obs-alvo.xml" "$TMP_DIR/obs-alvo-novo.xml"; then
                [[ "$autorizados" == *" target "* ]] || divergentes+="${divergentes:+, }target"
            fi
        else
            novo=""
        fi
    fi
    # A base só avança quando a observação foi ACEITA. Avançá-la no conflito
    # apagaria a evidência: a revalidação seguinte (a de antes de restaurar)
    # compararia contra o estado já contaminado e o rollback passaria por cima
    # da mudança de terceiro.
    if [ -n "$divergentes" ]; then
        REVAL_DIVERGENTES=" ${divergentes//, / } "
        REVAL_CONFLITO="conflito de concorrência $momento: os componentes [$divergentes] mudaram fora desta transação"
        return 1
    fi
    for campo in "${ESTADO_CAMPOS[@]}"; do
        nome="RVL_FINGERPRINT_COMPONENT_${campo^^}"
        REVAL_BASE[$campo]="${!nome}"
    done
    REVAL_BASE[exact]="$RVL_FINGERPRINT_EXACT"
    REVAL_BASE[semantic]="$RVL_FINGERPRINT_SEMANTIC"
    [ -z "$novo" ] || printf '%s\n' "$novo" > "$TMP_DIR/obs-alvo.xml"
    return 0
}

# I7.5 (D-NET-ROLLBACK-DIVERGE): cada passo do rollback relê o recurso que
# acabou de restaurar e o compara SEMANTICAMENTE com o que foi capturado. Antes
# desta subetapa a única prova era o código de retorno da ferramenta, e por isso
# uma restauração que devolvesse rc=0 sem aplicar nada era anunciada como
# "Rollback concluído: estados anteriores restaurados". Divergência agora é erro
# grave (ROLLBACK_FALHOU=1), nunca mensagem de sucesso.
#
# Fora do escopo desta subetapa: reter bundle de evidência e emitir recovery_id
# (D-NET-RECOVERY-EVIDENCE) continuam sendo de I7.6.
provar_xml_rede_restaurado() {
    # $1 = estado (persistente|ativo); $2 = arquivo com o XML capturado.
    # A comparação é por fingerprint canônico do core, não por bytes: o XML
    # volta pelo libvirt, que pode reordenar e normalizar o documento.
    local estado="$1" capturado="$2" anterior atual
    if [ -z "$capturado" ] || [ ! -s "$capturado" ]; then
        registrar_falha_rollback "o XML $estado capturado de $REDE_LIBVIRT não está disponível para a prova."
        return 0
    fi
    if ! inspecionar_rede_xml "$(<"$capturado")" RBANT_; then
        registrar_falha_rollback "não foi possível analisar o XML $estado capturado de $REDE_LIBVIRT."
        return 0
    fi
    anterior="$RBANT_FINGERPRINT"
    if ! consultar_estado_rede_libvirt "$REDE_LIBVIRT"; then
        registrar_falha_rollback "$ESTADO_REDE_ERRO Não foi possível sondar $REDE_LIBVIRT antes de provar o XML $estado."
        return 0
    fi
    if ! capturar_xml_estado_rede "$REDE_LIBVIRT" "$estado"; then
        registrar_falha_rollback "não foi possível reler o XML $estado de $REDE_LIBVIRT após a restauração."
        return 0
    fi
    if ! inspecionar_rede_xml "$ESTADO_REDE_XML" RBATU_; then
        registrar_falha_rollback "não foi possível analisar o XML $estado restaurado de $REDE_LIBVIRT."
        return 0
    fi
    atual="$RBATU_FINGERPRINT"
    if [ -z "$anterior" ] || [ "$anterior" != "$atual" ]; then
        registrar_falha_rollback "o XML $estado de $REDE_LIBVIRT diverge do capturado; a restauração não foi comprovada."
    fi
}

# ============================================================================
# I7.5: rollback executado A PARTIR DO PLANO
# ============================================================================
# A sequência inversa deixou de ser escrita à mão: ela vem de `rollback[]` do
# plano, na ordem dele (perfil de rede do host, rede libvirt, domínio,
# configuração do projeto), e cada passo prova o que restaurou. O provider
# continua sendo quem traduz verbo abstrato em comando e quem sonda o recurso
# antes de agir: `network-deactivate` de uma rede já inativa não vira erro de
# ferramenta, porque o que o plano exige é a PÓS-CONDIÇÃO, não a chamada.
#
# Só executam os passos cujo `resource_type` foi realmente mutado nesta
# execução; o plano é estático e dimensionado pelo pior caso.
recurso_foi_mutado() {
    case "$1" in
        host-network-profile) [ "$TX_NETPLAN_MUTOU" -eq 1 ] ;;
        libvirt-network) [ "$TX_REDE_MUTOU" -eq 1 ] ;;
        domain) [ "$TX_VM_MUTOU" -eq 1 ] ;;
        project-configuration) [ "$TX_CONF_MUTOU" -eq 1 ] ;;
        *) return 1 ;;
    esac
}

rb_perfil_restaurar() {
    if ! sudo cp -p "$TMP_DIR/netplan-bridge.anterior.yaml" "$NETPLAN_BRIDGE_ARQUIVO"; then
        registrar_falha_rollback "não foi possível restaurar $NETPLAN_BRIDGE_ARQUIVO."
    fi
}

rb_perfil_descartar() {
    if ! sudo rm -f "$NETPLAN_BRIDGE_ARQUIVO"; then
        registrar_falha_rollback "não foi possível remover a criação parcial de $NETPLAN_BRIDGE_ARQUIVO."
    fi
}

rb_perfil_ativar() {
    if ! sudo netplan generate; then
        registrar_falha_rollback "'netplan generate' falhou ao reaplicar a configuração anterior."
        return 0
    fi
    if ! sudo netplan apply; then
        registrar_falha_rollback "'netplan apply' falhou ao reaplicar a configuração anterior."
    fi
}

rb_rede_parar() {
    if ! consultar_estado_rede_libvirt "$REDE_LIBVIRT"; then
        registrar_falha_rollback "$ESTADO_REDE_ERRO Não foi possível sondar a rede antes de pará-la."
        return 0
    fi
    [ "$ESTADO_REDE_ATIVA" = "SIM" ] || return 0
    if ! $VIRSH net-destroy "$REDE_LIBVIRT" >/dev/null; then
        registrar_falha_rollback "não foi possível parar a rede atual $REDE_LIBVIRT."
    fi
}

rb_rede_remover() {
    if ! consultar_estado_rede_libvirt "$REDE_LIBVIRT"; then
        registrar_falha_rollback "$ESTADO_REDE_ERRO Não foi possível sondar a rede antes de removê-la."
        return 0
    fi
    [ "$ESTADO_REDE_PERSISTENTE" = "SIM" ] || return 0
    if ! $VIRSH net-undefine "$REDE_LIBVIRT" >/dev/null; then
        registrar_falha_rollback "não foi possível remover a definição atual de $REDE_LIBVIRT."
    fi
}

rb_rede_recriar() {
    [ -n "$TX_REDE_XML_ATIVO" ] || {
        registrar_falha_rollback "o XML ativo capturado de $REDE_LIBVIRT não está disponível para recriar a instância."
        return 0
    }
    if ! $VIRSH net-create "$TX_REDE_XML_ATIVO" >/dev/null; then
        registrar_falha_rollback "não foi possível recriar o XML ativo anterior de $REDE_LIBVIRT."
    fi
}

rb_rede_redefinir() {
    [ -n "$TX_REDE_XML_PERSISTENTE" ] || {
        registrar_falha_rollback "o XML persistente capturado de $REDE_LIBVIRT não está disponível para redefinir a rede."
        return 0
    }
    # Definir enquanto a instância anterior está ativa preserva também uma
    # eventual divergência legítima entre XML ativo e persistente.
    if ! $VIRSH net-define "$TX_REDE_XML_PERSISTENTE" >/dev/null; then
        registrar_falha_rollback "não foi possível restaurar o XML persistente de $REDE_LIBVIRT."
    fi
}

rb_rede_autostart() {
    local ligado="$1"
    if [ "$ligado" -eq 1 ]; then
        $VIRSH net-autostart "$REDE_LIBVIRT" >/dev/null \
            || registrar_falha_rollback "não foi possível restaurar autostart=sim em $REDE_LIBVIRT."
    else
        $VIRSH net-autostart "$REDE_LIBVIRT" --disable >/dev/null \
            || registrar_falha_rollback "não foi possível restaurar autostart=não em $REDE_LIBVIRT."
    fi
}

rb_vm_restaurar() {
    if ! $VIRSH define "$TMP_DIR/vm-anterior.xml" >/dev/null; then
        registrar_falha_rollback "não foi possível restaurar o XML anterior da VM $VM_NAME."
    fi
}

rb_conf_restaurar() {
    if ! cp -p "$TMP_DIR/passthrough.conf.anterior" "$CONF_ARQUIVO"; then
        registrar_falha_rollback "não foi possível restaurar $CONF_ARQUIVO."
    fi
}

executar_passo_rollback() {
    local indice="$1" verbo
    plano_ler verbo rollback "$indice" VERB
    case "$verbo" in
        host-profile-restore) rb_perfil_restaurar ;;
        host-profile-discard) rb_perfil_descartar ;;
        host-network-activate) rb_perfil_ativar ;;
        network-deactivate) rb_rede_parar ;;
        network-undefine) rb_rede_remover ;;
        network-recreate) rb_rede_recriar ;;
        network-redefine) rb_rede_redefinir ;;
        network-autostart-enable) rb_rede_autostart 1 ;;
        network-autostart-disable) rb_rede_autostart 0 ;;
        domain-restore) rb_vm_restaurar ;;
        configuration-restore) rb_conf_restaurar ;;
        *)
            registrar_falha_rollback "verbo de rollback fora do mapa deste provider: '$verbo'."
            return 0
            ;;
    esac
    provar_postcondicoes rollback "$indice"
}

passo_bloqueado_por_conflito() {
    local indice="$1" componente lista
    [ -n "$REVAL_DIVERGENTES" ] || return 1
    plano_ler lista rollback "$indice" REVALIDATE
    while IFS= read -r componente; do
        [ -n "$componente" ] || continue
        [[ "$REVAL_DIVERGENTES" == *" $componente "* ]] && return 0
    done <<< "$lista"
    return 1
}

executar_rollback() {
    local indice tipo identificador
    ROLLBACK_FALHOU=0
    aviso "Falha/sinal após mutação: iniciando rollback transacional da etapa 19."
    if [ "$PLANO_CARREGADO" -ne 1 ] || [ "$PLANO_RB_TOTAL" -eq 0 ]; then
        registrar_falha_rollback "a transação mutou sem plano de restauração carregado."
        erro "ROLLBACK INCOMPLETO: revise as falhas acima antes de executar a etapa novamente."
        return 1
    fi
    # D-NET-CONCURRENCY: restaurar por cima de uma mudança de terceiro apagaria
    # o trabalho dele. O que divergiu fora da autorização do trecho em execução
    # bloqueia exatamente os passos que tocariam aquele componente.
    if ! revalidar_estado "$AUTORIZACAO_GRUPO" "antes de restaurar"; then
        registrar_falha_rollback "${REVAL_CONFLITO:-divergência não detalhada}; os passos afetados não foram executados."
    fi
    for ((indice = 0; indice < PLANO_RB_TOTAL; indice++)); do
        plano_ler tipo rollback "$indice" RESOURCE_TYPE
        recurso_foi_mutado "$tipo" || continue
        plano_ler identificador rollback "$indice" ID
        if passo_bloqueado_por_conflito "$indice"; then
            registrar_falha_rollback "$identificador não foi executado: o recurso mudou fora desta transação."
            continue
        fi
        executar_passo_rollback "$indice"
    done
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

# I7.5: a confirmação passou a acontecer ANTES da primeira mutação, nos DOIS
# modos. No comportamento anterior o passthrough.conf era gravado três vezes
# logo depois da captura, sem pergunta nenhuma, e só o modo bridge confirmava,
# ainda assim depois dessas três gravações (a chamada ficava dentro de
# `configurar_bridge`). O modo NAT nunca confirmava.
#
# A pergunta foi MOVIDA, não duplicada: `configurar_bridge` não pergunta mais.
# Recusar aqui produz zero efeito, porque nenhuma mutação foi tentada, e o
# código de saída continua sendo o de `falhar "Cancelado."`. Confirmação não é
# efeito, então as contagens do oráculo I0 (11 NAT / 10 bridge) não mudam.
#
# As recusas específicas do modo bridge que não dependem de mutação alguma
# (netplan ausente, uplink Wi-Fi) saíram daqui na fiação do plano: viraram as
# precondições `P-CAPABILITIES-AVAILABLE` e `P-UPLINK-NOT-WIRELESS`, provadas
# depois da confirmação e ainda antes da primeira mutação. A garantia que
# importa é a mesma: recusar sem ter gravado configuração alguma.
confirmar_primeira_mutacao() {
    case "$REDE_MODO" in
        bridge)
            confirmar "Aplicar/verificar bridge $REDE_BRIDGE sobre $INTERFACE_FISICA?" \
                || falhar "Cancelado."
            ;;
        nat)
            confirmar "Aplicar/verificar a rede NAT libvirt $REDE_LIBVIRT sobre $INTERFACE_FISICA?" \
                || falhar "Cancelado."
            ;;
        *) falhar "REDE_MODO inválido: $REDE_MODO" ;;
    esac
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

# I7.5: a trava NAT deixou de ser um `falhar` avulso aqui e virou a precondição
# `P-UPLINK-EFFECTIVE` do plano, provada antes de qualquer mutação com a mesma
# mensagem. A sondagem continua sendo local: `ip -4 route get` não envia pacote.
UPLINK_IPV4_EFETIVO="$(dispositivo_uplink_ipv4_efetivo || true)"

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
capturar_capacidades
confirmar_primeira_mutacao
# I7.5: REDE_BRIDGE, REDE_LIBVIRT, REDE_BRIDGE_LIBVIRT e VM_NIC_MAC não são
# mais gravadas por chamadas avulsas: são as quatro publicações do estágio um
# do plano (`_configuration_targets`), executadas na ordem dele.

# I7.5: `garantir_vm_nic_mac` virou RESOLUÇÃO pura. A publicação do valor não
# acontece mais aqui: `VM_NIC_MAC` é a quarta publicação do estágio um do plano
# (`_configuration_targets`), executada pelo mesmo caminho das outras chaves.
# O XML já vem da captura transacional, então nenhum `dumpxml` extra é gasto.
resolver_vm_nic_mac() {
    local conteudo total indice escolhido mac tipo rede fonte idx recomendada
    local nome_mac nome_tipo nome_rede nome_fonte
    conteudo="$CAP_ALVO_XML"
    [ -n "$conteudo" ] || falhar "Não foi possível capturar o XML inativo da VM."
    if [ -n "${VM_NIC_MAC:-}" ]; then
        mac_valido "$VM_NIC_MAC" || falhar "VM_NIC_MAC inválido: $VM_NIC_MAC"
        VM_NIC_MAC="${VM_NIC_MAC,,}"
        inspecionar_nic_dominio "$conteudo" GARNIC_ nic_mac "$VM_NIC_MAC" \
            || falhar "Não foi possível analisar as NICs do XML da VM."
        [ "$GARNIC_MAC_COUNT" = "1" ] \
            || falhar "VM_NIC_MAC=$VM_NIC_MAC não identifica exatamente uma NIC no XML da VM."
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
    VM_NIC_MAC="${mac,,}"
    ok "Configuração antiga migrada: VM_NIC_MAC=$VM_NIC_MAC."
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

# I7.5: a sub-rede CONFIGURADA deixou de ser verificada aqui. Sobreposição com
# rota existente virou a precondição `P-ROUTE-COLLISION-FREE` do plano, e a
# sobreposição com outra rede libvirt continua sendo checada por
# `confirmar_subrede_livre`, depois das precondições e antes de qualquer
# mutação — o core não modela essa segunda pergunta. A busca automática
# permanece aqui porque escolher a candidata é decisão do provider, não plano.
escolher_subrede_nat() {
    local terceiro candidata
    if [ -n "${REDE_NAT_CIDR:-}" ]; then
        cidr_privado_24_valido "$REDE_NAT_CIDR" \
            || falhar "REDE_NAT_CIDR='$REDE_NAT_CIDR' não é uma sub-rede privada /24 válida."
        return 0
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

confirmar_subrede_livre() {
    # Sobreposição com a sub-rede de OUTRA rede libvirt, ativa ou apenas
    # definida. O plano audita rotas; esta pergunta é sobre definição, e a
    # etapa a mantém para não perder a recusa histórica.
    detectar_colisao_subrede "$REDE_NAT_CIDR"
    case "$DETECCAO_SUBREDE" in
        LIVRE) return 0 ;;
        COLISAO) falhar "Colisão detectada antes de aplicar $REDE_NAT_CIDR: $COLISAO_DESC. Escolha outra REDE_NAT_CIDR." ;;
        ERRO) falhar "Erro ao verificar colisões para $REDE_NAT_CIDR: $COLISAO_DESC. Nenhuma sub-rede foi aceita." ;;
        *) falhar "Resultado interno inválido ao verificar $REDE_NAT_CIDR: '$DETECCAO_SUBREDE'." ;;
    esac
}

coletar_enderecos_bridge() {
    # I7.5: as reservas passaram a ser perguntadas ANTES do plano, porque são
    # intenção do operador (`settings.vm_ip` e `settings.host_ip`) e a intenção
    # precisa estar completa antes da primeira mutação. O MAC exibido é o do
    # uplink: a bridge o herda, e perguntar depois de aplicar significaria
    # publicar configuração antes de saber o que publicar.
    local resposta host_atual
    echo "MAC da VM:   $VM_NIC_MAC"
    echo "MAC previsto do host em $REDE_BRIDGE: ${CAP_UPLINK_MAC:-desconhecido} (a bridge herda o MAC de $INTERFACE_FISICA)"
    cat <<INSTRUCOES
No roteador:
  1. reserve um endereço da LAN para o MAC da VM -> IP da VM Windows (VM_IP_FIXO);
  2. reserve outro para o MAC de $REDE_BRIDGE -> IP do host Linux na bridge (IP_FIXO_HOST).
A etapa 20 restringe o airlock à interface $REDE_BRIDGE e ao IP da VM Windows.
INSTRUCOES
    IP_INTENCAO_VM=""
    IP_INTENCAO_HOST=""
    if resposta="$(perguntar_ipv4_opcional 'IP reservado para a VM Windows' "${VM_IP_FIXO:-}")"; then
        IP_INTENCAO_VM="$resposta"
    fi
    host_atual="$(ip -4 -o addr show dev "$REDE_BRIDGE" 2>/dev/null | awk 'NR==1 {sub(/\/.*/, "", $4); print $4}')"
    if resposta="$(perguntar_ipv4_opcional "IP reservado para o host Linux em $REDE_BRIDGE" "${IP_FIXO_HOST:-$host_atual}")"; then
        IP_INTENCAO_HOST="$resposta"
    fi
}

# ============================================================================
# I7.5: o plano do core é o roteiro da etapa
# ============================================================================
# A etapa não decide mais a sequência: ela captura, monta a INTENÇÃO, pede o
# plano a `network-plan` e executa `operations[]` na ordem do plano, provando a
# pós-condição de cada operação. O plano nomeia verbos abstratos e nunca cita
# ferramenta (I7.7); o mapa verbo -> comando vive AQUI, no provider, e é a
# única parte do fluxo que sabe o que são `virsh`, `netplan` e `install`.
#
# O código imperativo que o plano substituiu saiu (regra 8: nunca dois caminhos
# mutantes em produção): `configurar_bridge`, `configurar_nat`,
# `preparar_nat_para_bridge`, `validar_bridge_libvirt_disponivel`,
# `listar_consumidores_rede_gerenciada`, `rede_nat_usada_por_outra_vm_ativa`,
# `bridge_atual_rede_gerenciada`, `bridge_libvirt_pertence_rede` e as quatro
# funções `restaurar_*`.

PLANO_ARGUMENTOS=(
    BRIDGE BRIDGE_DELAY BRIDGE_STP CONTENT CONTENT_SHA256 DHCP4 DHCP_END
    DHCP_START ENABLED FAMILY FORWARD_DELAY FORWARD_DEVICE FORWARD_MODE
    FORWARD_PORT_END FORWARD_PORT_START FROM GATEWAY KEY MARKER MEMBER
    MEMBER_DHCP4 MEMBER_DHCP6 MODE NAME NETMASK NIC_MAC PREFIX REASON
    RESERVATION_IP RESERVATION_MAC RESTORE REVERT_WITHOUT_CONFIRMATION SCOPE
    SOURCE SOURCE_TYPE STP UUID VALUE
)
PLANO_PERMITIDAS=(
    "${CORE_PARES_ENVELOPE[@]}"
    ACCEPTED BLOCKING_PRECONDITION CONVERGED_COUNT FAILED_PRECONDITION_COUNT
    FAMILY MODE MUTATING_COUNT OPERATION_COUNT OPERATION_IDS PLAN_SHA256
    POSTCONDITION_COUNT PRECONDITION_COUNT ROLLBACK_COUNT ROLLBACK_IDS
    SCHEMA_VERSION
    FINGERPRINT_INTENT_EXACT FINGERPRINT_INTENT_SEMANTIC
    FINGERPRINT_SNAPSHOT_EXACT FINGERPRINT_SNAPSHOT_SEMANTIC FINGERPRINT_TARGET
    FINGERPRINT_COMPONENT_UPLINK FINGERPRINT_COMPONENT_ROUTES
    FINGERPRINT_COMPONENT_LINKS FINGERPRINT_COMPONENT_BRIDGE
    FINGERPRINT_COMPONENT_LIBVIRT_NETWORK FINGERPRINT_COMPONENT_FOREIGN_NETWORKS
    FINGERPRINT_COMPONENT_CONSUMERS FINGERPRINT_COMPONENT_CONFIGURATION
    'PRECONDITION_#_DETAIL' 'PRECONDITION_#_EVIDENCE' 'PRECONDITION_#_ID'
    'PRECONDITION_#_REQUIRES' 'PRECONDITION_#_SATISFIED'
    'PRECONDITION_#_SEVERITY' 'PRECONDITION_#_SUBJECT'
    'OPERATION_#_ARGUMENTS' 'OPERATION_#_CONVERGED' 'OPERATION_#_ID'
    'OPERATION_#_MUTATING' 'OPERATION_#_POSTCONDITIONS' 'OPERATION_#_RESOURCE'
    'OPERATION_#_RESOURCE_TYPE' 'OPERATION_#_REVALIDATE' 'OPERATION_#_UNDO'
    'OPERATION_#_VERB'
    'ROLLBACK_#_ARGUMENTS' 'ROLLBACK_#_ID' 'ROLLBACK_#_ON_DIVERGENCE'
    'ROLLBACK_#_POSTCONDITIONS' 'ROLLBACK_#_RESOURCE' 'ROLLBACK_#_RESOURCE_TYPE'
    'ROLLBACK_#_REVALIDATE' 'ROLLBACK_#_VERB'
    'POSTCONDITION_#_EVIDENCE' 'POSTCONDITION_#_ID' 'POSTCONDITION_#_REQUIRES'
    'POSTCONDITION_#_SCOPE' 'POSTCONDITION_#_STEP' 'POSTCONDITION_#_SUBJECT'
)
for _plano_arg in "${PLANO_ARGUMENTOS[@]}"; do
    PLANO_PERMITIDAS+=("OPERATION_#_ARGUMENT_$_plano_arg" "ROLLBACK_#_ARGUMENT_$_plano_arg")
done
unset _plano_arg

plano_ler() {
    # Leitura de um campo do plano sem subshell: $1 = variável destino;
    # $2 = coleção (precondition|operation|rollback|postcondition);
    # $3 = índice; $4 = campo. Os laços de prova percorrem o plano inteiro por
    # operação, e um fork por campo custaria mais que a própria prova.
    local _pll_nome="PL_${2^^}_${3}_${4}"
    printf -v "$1" '%s' "${!_pll_nome-}"
}

op_argumento() {
    local _opa_nome="PL_OPERATION_${1}_ARGUMENT_${2^^}"
    printf '%s' "${!_opa_nome-}"
}

# --- Intenção declarativa -----------------------------------------------------

gerar_perfil_host() {
    # Mesmo corpo do heredoc histórico: o conteúdo é INTENÇÃO, não comando, e
    # não menciona ferramenta alguma.
    PERFIL_CONTEUDO="network:
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
"
}

render_xml_rede() {
    # Renderiza o XML libvirt a partir de escalares. Usado duas vezes com a
    # MESMA implementação: para declarar a intenção e para materializar o verbo
    # `network-define` com os argumentos que o plano devolveu.
    local nome="$1" uuid="$2" marcador="$3" modo="$4" dev="$5" porta_inicio="$6"
    local porta_fim="$7" bridge="$8" stp="$9" atraso="${10}" gateway="${11}"
    local mascara="${12}" dhcp_inicio="${13}" dhcp_fim="${14}" mac="${15}"
    local vm_ip="${16}" linha_uuid="" texto_stp="off"
    [ "$stp" = "1" ] && texto_stp="on"
    [ -z "$uuid" ] || linha_uuid="  <uuid>$uuid</uuid>"
    cat <<XML
<network>
  <name>$nome</name>
$linha_uuid
  <description>$marcador</description>
  <forward mode='$modo' dev='$dev'>
    <nat>
      <port start='$porta_inicio' end='$porta_fim'/>
    </nat>
  </forward>
  <bridge name='$bridge' stp='$texto_stp' delay='$atraso'/>
  <ip address='$gateway' netmask='$mascara'>
    <dhcp>
      <range start='$dhcp_inicio' end='$dhcp_fim'/>
      <host mac='$mac' ip='$vm_ip'/>
    </dhcp>
  </ip>
</network>
XML
}

gerar_xml_rede_nat() {
    XML_REDE_PRETENDIDO="$(render_xml_rede \
        "$REDE_LIBVIRT" "$CAP_REDE_UUID" "$REDE_MARCADOR" nat "$INTERFACE_FISICA" \
        1024 65535 "$REDE_BRIDGE_LIBVIRT" 1 0 "$NAT_GATEWAY" 255.255.255.0 \
        "$NAT_DHCP_INICIO" "$NAT_DHCP_FIM" "${VM_NIC_MAC,,}" "$NAT_VM_IP")"
}

_intencao_links() {
    # Links pretendidos no modo bridge: o uplink vira porta e a bridge existe.
    local linha registros="" tem_bridge=0 flags kind mac master mtu nome
    local operstate wireless enderecos uplink_flags="" uplink_mtu="1500"
    local uplink_enderecos="" portas=""
    local -a campos=()
    while IFS= read -r linha; do
        [ -n "$linha" ] || continue
        _dividir_campos "$linha" campos
        enderecos="${campos[0]}"; flags="${campos[1]}"; kind="${campos[2]}"
        mac="${campos[3]}"; master="${campos[4]}"; mtu="${campos[5]}"
        nome="${campos[6]}"; operstate="${campos[7]}"; wireless="${campos[8]}"
        if [ "$nome" = "$INTERFACE_FISICA" ]; then
            master="$REDE_BRIDGE"
            uplink_flags="$flags"
            uplink_mtu="$mtu"
            uplink_enderecos="$enderecos"
        fi
        if [ "$nome" = "$REDE_BRIDGE" ]; then
            tem_bridge=1
            kind="bridge"
            master=""
        fi
        [ "$master" = "$REDE_BRIDGE" ] && portas+="${portas:+$PAIRS_NL}$nome"
        registros+="${registros:+$PAIRS_NL}$enderecos$PAIRS_TAB$flags$PAIRS_TAB$kind$PAIRS_TAB$mac$PAIRS_TAB$master$PAIRS_TAB$mtu$PAIRS_TAB$nome$PAIRS_TAB$operstate$PAIRS_TAB$wireless"
    done <<< "$CAP_LINKS"
    if [ "$tem_bridge" -eq 0 ]; then
        registros+="${registros:+$PAIRS_NL}$uplink_enderecos$PAIRS_TAB${uplink_flags:-BROADCAST,MULTICAST,UP}${PAIRS_TAB}bridge$PAIRS_TAB$CAP_UPLINK_MAC$PAIRS_TAB$PAIRS_TAB$uplink_mtu$PAIRS_TAB$REDE_BRIDGE${PAIRS_TAB}up${PAIRS_TAB}0"
    fi
    # As portas pretendidas saem dos masters dos links pretendidos, nunca de um
    # valor fixo: uma porta alheia já presente na bridge precisa aparecer para
    # que `P-BRIDGE-MEMBER-DECLARED` a recuse, em vez de virar erro de schema.
    CAP_LINKS_INTENCAO="$registros"
    CAP_BRIDGE_PORTAS_INTENCAO="$portas"
}

_intencao_configuracao() {
    # Artefatos pretendidos: o perfil do host passa a existir com o conteúdo
    # gerado; o restante é o capturado. Quando o arquivo ainda não existe, a
    # identidade de inode NÃO é intenção — só `mode`, `content` e `size` são —,
    # então os metadados restantes vão neutros e o plano não os consome.
    local linha registros="" dispositivo existe tipo gid identificador inode
    local modo instante nlink escopo tamanho uid
    local -a campos=()
    CAP_CONFIG_INTENCAO=()
    while IFS= read -r linha; do
        [ -n "$linha" ] || continue
        _dividir_campos "$linha" campos
        dispositivo="${campos[0]}"; existe="${campos[1]}"; tipo="${campos[2]}"
        gid="${campos[3]}"; identificador="${campos[4]}"; inode="${campos[5]}"
        modo="${campos[6]}"; instante="${campos[7]}"; nlink="${campos[8]}"
        escopo="${campos[9]}"; tamanho="${campos[10]}"; uid="${campos[11]}"
        if [ "$escopo" = "$PERFIL_HOST_ESCOPO" ] && [ "$identificador" = "$PERFIL_HOST_ID" ]; then
            [ "$existe" = "1" ] || { dispositivo=0; inode=1; gid=0; uid=0; nlink=1; instante=0; }
            existe=1
            tipo="regular"
            modo="$PERFIL_HOST_MODO"
            tamanho="${#PERFIL_CONTEUDO}"
            CAP_CONFIG_INTENCAO+=("$PERFIL_CONTEUDO")
        else
            CAP_CONFIG_INTENCAO+=("${CAP_CONFIG_CONTEUDO[${#CAP_CONFIG_INTENCAO[@]}]}")
        fi
        registros+="${registros:+$PAIRS_NL}$dispositivo$PAIRS_TAB$existe$PAIRS_TAB$tipo$PAIRS_TAB$gid$PAIRS_TAB$identificador$PAIRS_TAB$inode$PAIRS_TAB$modo$PAIRS_TAB$instante$PAIRS_TAB$nlink$PAIRS_TAB$escopo$PAIRS_TAB$tamanho$PAIRS_TAB$uid"
    done <<< "$CAP_CONFIG"
    CAP_CONFIG_INTENCAO_REGISTROS="$registros"
}

montar_pares_intencao() {
    # $1 = nome do array de pares. A intenção é o snapshot com as diferenças
    # que a etapa PRETENDE causar; nada além disso é inventado.
    local -n _pi_ref="$1"
    local indice links="$CAP_LINKS" bridge_existe="$CAP_BRIDGE_EXISTE"
    local bridge_portas="$CAP_BRIDGE_PORTAS" config="$CAP_CONFIG"
    local rede_existe="$CAP_REDE_EXISTE" rede_ativa_i="$CAP_REDE_ATIVA"
    local rede_persistente="$CAP_REDE_PERSISTENTE" rede_autostart=0
    local rede_marcador="$CAP_REDE_MARCADOR" rede_xml_ativo="$CAP_REDE_XML_ATIVO"
    local rede_xml_persistente="$CAP_REDE_XML_PERSISTENTE"
    CAP_CONFIG_INTENCAO=("${CAP_CONFIG_CONTEUDO[@]}")
    if [ "$REDE_MODO" = "nat" ]; then
        rede_existe=1; rede_ativa_i=1; rede_persistente=1; rede_autostart=1
        rede_marcador="$REDE_MARCADOR"
        rede_xml_ativo="$XML_REDE_PRETENDIDO"
        rede_xml_persistente="$XML_REDE_PRETENDIDO"
    else
        _intencao_links
        links="$CAP_LINKS_INTENCAO"
        bridge_existe=1
        bridge_portas="$CAP_BRIDGE_PORTAS_INTENCAO"
        # Sem `$( )`: a projeção publica também o array de conteúdos, e um
        # subshell descartaria o array.
        _intencao_configuracao
        config="$CAP_CONFIG_INTENCAO_REGISTROS"
        # Rede gerenciada no modo bridge: fica definida, inativa e sem
        # autostart; uma instância só transitória desaparece.
        if [ "$rede_existe" -eq 1 ] && [ "$rede_persistente" -eq 0 ]; then
            rede_existe=0; rede_ativa_i=0; rede_marcador=""
            rede_xml_ativo=""; rede_xml_persistente=""
        elif [ "$rede_existe" -eq 1 ]; then
            rede_ativa_i=0
            rede_xml_ativo=""
        fi
    fi
    _pi_ref+=(
        intent_schema_version 1
        intent_mode "$REDE_MODO"
        intent_uplink_kind "$CAP_UPLINK_KIND"
        intent_uplink_mac "$CAP_UPLINK_MAC"
        intent_uplink_name "$INTERFACE_FISICA"
        intent_routes "$CAP_ROTAS"
        intent_links "$links"
        intent_bridge_exists "$bridge_existe"
        intent_bridge_name "$REDE_BRIDGE"
        intent_bridge_ports "$bridge_portas"
        intent_libvirt_network_active "$rede_ativa_i"
        intent_libvirt_network_active_xml "$rede_xml_ativo"
        intent_libvirt_network_autostart "$rede_autostart"
        intent_libvirt_network_exists "$rede_existe"
        intent_libvirt_network_marker "$rede_marcador"
        intent_libvirt_network_name "$REDE_LIBVIRT"
        intent_libvirt_network_persistent "$rede_persistente"
        intent_libvirt_network_persistent_xml "$rede_xml_persistente"
        intent_foreign_networks "$CAP_ESTRANHAS"
        intent_consumers "$CAP_CONSUMIDORES"
        intent_configuration "$config"
    )
    for indice in "${!CAP_CONSUMIDOR_XML[@]}"; do
        _pi_ref+=(
            "intent_consumer_${indice}_xml" "${CAP_CONSUMIDOR_XML[$indice]}"
            "intent_consumer_${indice}_interfaces" "${CAP_CONSUMIDOR_IFACES[$indice]}"
        )
    done
    for indice in "${!CAP_CONFIG_INTENCAO[@]}"; do
        _pi_ref+=("intent_configuration_${indice}_content" "${CAP_CONFIG_INTENCAO[$indice]}")
    done
}

capturar_alvo() {
    # A VM gerenciada não entra em `consumers`: ela tem bloco próprio.
    local tipo fonte
    inspecionar_nic_dominio "$CAP_ALVO_XML" ALVO_ nic_mac "${VM_NIC_MAC,,}" \
        || falhar "Não foi possível analisar as NICs do XML da VM alvo."
    CAP_ALVO_NIC_TOTAL="$ALVO_MAC_COUNT"
    tipo="$ALVO_MAC_TYPE"
    case "$tipo" in
        network) fonte="$ALVO_MAC_NETWORK" ;;
        bridge) fonte="$ALVO_MAC_BRIDGE" ;;
        direct) fonte="$ALVO_MAC_DEV" ;;
        *) tipo=""; fonte="" ;;
    esac
    [ -n "$fonte" ] || tipo=""
    [ -n "$tipo" ] || fonte=""
    CAP_ALVO_FONTE_TIPO="$tipo"
    CAP_ALVO_FONTE="$fonte"
}

montar_pares_pedido() {
    local -n _pp_ref="$1"
    _pp_ref+=(schema_version 1)
    montar_pares_estado snapshot _pp_ref
    montar_pares_intencao _pp_ref
    _pp_ref+=(
        target_active 0
        target_defined 1
        target_name "$VM_NAME"
        target_nic_mac "${VM_NIC_MAC,,}"
        target_nic_match_count "$CAP_ALVO_NIC_TOTAL"
        target_nic_source "$CAP_ALVO_FONTE"
        target_nic_source_type "$CAP_ALVO_FONTE_TIPO"
        target_xml "$CAP_ALVO_XML"
        settings_capabilities "$CAP_CAPACIDADES"
        settings_configuration_identifier "$CONF_IDENTIFICADOR"
        settings_host_ip "$IP_INTENCAO_HOST"
        settings_host_profile_dhcp4 1
        settings_host_profile_forward_delay 4
        settings_host_profile_identifier "$PERFIL_HOST_ID"
        settings_host_profile_member_dhcp4 0
        settings_host_profile_member_dhcp6 0
        settings_host_profile_scope "$PERFIL_HOST_ESCOPO"
        settings_host_profile_stp 1
        settings_marker "$REDE_MARCADOR"
        settings_nat_bridge "$REDE_BRIDGE_LIBVIRT"
        settings_nat_cidr "${REDE_NAT_CIDR:-}"
        settings_uplink_effective "$UPLINK_IPV4_EFETIVO"
        settings_vm_ip "$IP_INTENCAO_VM"
    )
}

construir_plano() {
    local indice componente lista
    local -a payload=()
    montar_pares_pedido payload
    python_core_pares_payload PLANO_PERMITIDAS PL_ network-plan payload \
        || falhar "O core recusou o pedido de plano de rede: ${PYTHON_CORE_ERRO:-sem diagnóstico}."
    PLANO_CARREGADO=1
    PLANO_PRE_TOTAL="$PL_PRECONDITION_COUNT"
    PLANO_OP_TOTAL="$PL_OPERATION_COUNT"
    PLANO_RB_TOTAL="$PL_ROLLBACK_COUNT"
    PLANO_POS_TOTAL="$PL_POSTCONDITION_COUNT"
    # Superfície de concorrência: os componentes que o próprio plano diz que
    # importam nesta transação. Fora dela a etapa não acusa conflito, porque o
    # plano não depende do componente.
    REVAL_SUPERFICIE=" "
    for ((indice = 0; indice < PLANO_OP_TOTAL; indice++)); do
        plano_ler lista operation "$indice" REVALIDATE
        while IFS= read -r componente; do
            [ -n "$componente" ] || continue
            [[ "$REVAL_SUPERFICIE" == *" $componente "* ]] || REVAL_SUPERFICIE+="$componente "
        done <<< "$lista"
    done
    for ((indice = 0; indice < PLANO_RB_TOTAL; indice++)); do
        plano_ler lista rollback "$indice" REVALIDATE
        while IFS= read -r componente; do
            [ -n "$componente" ] || continue
            [[ "$REVAL_SUPERFICIE" == *" $componente "* ]] || REVAL_SUPERFICIE+="$componente "
        done <<< "$lista"
    done
    [ "$REVAL_SUPERFICIE" = " " ] && REVAL_SUPERFICIE=""
    info "Plano de rede $PL_PLAN_SHA256: $PLANO_OP_TOTAL operações ($PL_MUTATING_COUNT mutantes), $PLANO_RB_TOTAL passos de restauração."
}

# --- Precondições -------------------------------------------------------------

mensagem_precondicao() {
    local id="$1" sujeito="$2" detalhe="$3"
    case "$id" in
        P-CAPABILITIES-AVAILABLE)
            printf 'Ferramentas ausentes para o modo %s: %s. Nenhuma alteração foi feita.' "$REDE_MODO" "$detalhe" ;;
        P-CONFIGURATION-PRESENT)
            printf 'O arquivo de configuração %s não foi capturado; nada foi alterado.' "$sujeito" ;;
        P-DOMAIN-DEFINED)
            printf "A VM '%s' não está definida no libvirt." "$sujeito" ;;
        P-DOMAIN-STOPPED)
            printf "A VM '%s' está em execução; desligue-a antes da etapa 19." "$sujeito" ;;
        P-DOMAIN-NIC-UNIQUE)
            printf 'VM_NIC_MAC=%s não identifica exatamente uma NIC no XML da VM (encontradas: %s).' "$sujeito" "${detalhe:-0}" ;;
        P-UPLINK-PRESENT)
            printf 'O uplink %s não aparece na captura de links do host.' "$sujeito" ;;
        P-UPLINK-EFFECTIVE)
            printf 'INTERFACE_FISICA=%s, mas a rota IPv4 efetiva usa %s. Torne o adaptador selecionado a rota padrão ou desconecte/ajuste a métrica do outro e execute novamente; nenhuma alteração foi feita.' "$sujeito" "${detalhe:-nenhuma interface}" ;;
        P-UPLINK-NOT-ENSLAVED)
            if [ "$detalhe" = "host-bridge" ]; then
                printf 'O uplink %s ainda é porta de %s. Para migrar bridge -> NAT, restaure o backup Netplan da bridge, rode '"'"'sudo netplan apply'"'"' e execute esta etapa novamente; o caminho NAT não altera Netplan.' "$sujeito" "$REDE_BRIDGE"
            else
                printf "O uplink %s está escravizado a outra bridge; remova-o dessa bridge antes de usar NAT." "$sujeito"
            fi ;;
        P-LIBVIRT-NETWORK-OWNED)
            printf "A rede libvirt '%s' já existe sem o marcador deste projeto. Escolha outro REDE_LIBVIRT; nada foi alterado." "$sujeito" ;;
        P-LIBVIRT-BRIDGE-OWNED)
            printf 'A interface %s já existe e não pertence à rede gerenciada %s.' "$sujeito" "$REDE_LIBVIRT" ;;
        P-NETWORK-CONSUMERS-ABSENT)
            if [ "$REDE_MODO" = "nat" ]; then
                printf 'Outra VM ativa usa network=%s, a bridge atual ou a bridge pretendida %s: %s. Desligue-a antes da atualização.' "$sujeito" "$REDE_BRIDGE_LIBVIRT" "$detalhe"
            else
                printf 'A migração NAT -> bridge foi recusada: outras VMs definidas consomem %s ou sua bridge: %s. Remova/troque a fonte dessas NICs e execute novamente; nenhuma configuração de Netplan foi tocada.' "$sujeito" "$detalhe"
            fi ;;
        P-LIBVIRT-BRIDGE-UNIQUE)
            printf "REDE_BRIDGE_LIBVIRT=%s já é usada pela rede libvirt '%s'." "$sujeito" "$detalhe" ;;
        P-ROUTE-COLLISION-FREE)
            printf "Colisão detectada antes de aplicar %s: rota '%s'. Escolha outra REDE_NAT_CIDR." "$sujeito" "$detalhe" ;;
        P-UPLINK-NOT-WIRELESS)
            printf 'Bridge sobre Wi-Fi station não é suportada. Selecione REDE_MODO=nat na etapa 3.' ;;
        P-HOST-PROFILE-DECLARED)
            printf "A intenção não declarou o perfil de rede do host '%s'; nada foi alterado." "$sujeito" ;;
        P-BRIDGE-MEMBER-DECLARED)
            printf 'A bridge %s precisa declarar %s como sua única porta; nada foi alterado.' "$sujeito" "$INTERFACE_FISICA" ;;
        *)
            printf "Precondição %s não satisfeita para '%s'%s." "$id" "$sujeito" "${detalhe:+ ($detalhe)}" ;;
    esac
}

provar_precondicoes() {
    local indice id severidade satisfeita sujeito detalhe mensagem
    for ((indice = 0; indice < PLANO_PRE_TOTAL; indice++)); do
        plano_ler satisfeita precondition "$indice" SATISFIED
        [ "$satisfeita" = "1" ] && continue
        plano_ler id precondition "$indice" ID
        plano_ler severidade precondition "$indice" SEVERITY
        plano_ler sujeito precondition "$indice" SUBJECT
        plano_ler detalhe precondition "$indice" DETAIL
        mensagem="$(mensagem_precondicao "$id" "$sujeito" "$detalhe")"
        if [ "$severidade" = "refuse" ]; then
            falhar "$mensagem"
        fi
        aviso "$mensagem"
    done
    [ "$PL_ACCEPTED" = "1" ] \
        || falhar "O plano de rede foi recusado pela precondição ${PL_BLOCKING_PRECONDITION:-desconhecida}; nada foi alterado."
}

# --- Pós-condições ------------------------------------------------------------

conf_literal() {
    local valor="$1"
    valor="${valor//\\/\\\\}"
    valor="${valor//\"/\\\"}"
    valor="${valor//\$/\\\$}"
    valor="${valor//\`/\\\`}"
    printf '"%s"' "$valor"
}

conf_chave_publicada() {
    # Prova a publicação relendo o arquivo, não a variável em memória. O
    # literal é serializado com o mesmo subconjunto que o core grava
    # (`config.encode_literal`).
    local chave="$1" esperado="$2" literal linha lida resto
    literal="$(conf_literal "$esperado")"
    while IFS= read -r linha; do
        lida="${linha%%=*}"
        lida="${lida%%[[:space:]]*}"
        [ "$lida" = "$chave" ] || continue
        resto="${linha#*=}"
        [ "$resto" = "$literal" ]
        return $?
    done < "$CONF_ARQUIVO"
    return 1
}

falha_postcondicao() {
    # $1 = escopo; demais = mensagem. Em rollback nunca chama `falhar`: o trap
    # de saída precisa concluir a sequência e reportar ROLLBACK INCOMPLETO.
    local escopo="$1"
    shift
    if [ "$escopo" = "rollback" ]; then
        registrar_falha_rollback "$*"
        return 0
    fi
    falhar "$*"
}

provar_postcondicao() {
    local escopo="$1" indice="$2" tipo="$3" sujeito="$4" atual esperado
    local iface ip_vm ip_host chave i modo_esperado
    case "$tipo" in
        CONFIGURATION-VALUE)
            conf_chave_publicada "$sujeito" "$(op_argumento "$indice" value)" \
                || falha_postcondicao "$escopo" "A chave $sujeito não ficou publicada com o valor pretendido em $CONF_ARQUIVO."
            ;;
        CONFIGURATION-CONVERGED)
            for i in "${!CHAVES_PUBLICADAS[@]}"; do
                conf_chave_publicada "${CHAVES_PUBLICADAS[$i]}" "${VALORES_PUBLICADOS[$i]}" \
                    || falha_postcondicao "$escopo" "A chave ${CHAVES_PUBLICADAS[$i]} não convergiu em $CONF_ARQUIVO."
            done
            ;;
        NETWORK-PERSISTENT)
            rede_nat_xml_confere persistente \
                || falha_postcondicao "$escopo" "A definição persistente de $sujeito diverge do XML NAT esperado.${REDE_XML_ERRO:+ $REDE_XML_ERRO}"
            ;;
        NETWORK-ACTIVE)
            rede_nat_xml_confere ativo \
                || falha_postcondicao "$escopo" "O backend ativo de $sujeito diverge da definição persistente esperada.${REDE_XML_ERRO:+ $REDE_XML_ERRO}"
            ;;
        NETWORK-INACTIVE|NETWORK-AUTOSTART|NETWORK-AUTOSTART-OFF)
            # Sondagem explícita: `rede_ativa`/`rede_autostart` abortam a etapa
            # diante de consulta inconclusiva, e dentro do trap de saída isso
            # mataria o rollback no meio da sequência.
            if ! consultar_estado_rede_libvirt "$REDE_LIBVIRT"; then
                falha_postcondicao "$escopo" "$ESTADO_REDE_ERRO Não foi possível provar o estado de $sujeito."
            elif [ "$tipo" = "NETWORK-INACTIVE" ] \
                 && [ "$ESTADO_REDE_EXISTE" = "SIM" ] && [ "$ESTADO_REDE_ATIVA" = "SIM" ]; then
                falha_postcondicao "$escopo" "A rede $sujeito continua ativa depois da operação."
            elif [ "$tipo" = "NETWORK-AUTOSTART" ] \
                 && { [ "$ESTADO_REDE_EXISTE" != "SIM" ] || [ "$ESTADO_REDE_AUTOSTART" != "SIM" ]; }; then
                falha_postcondicao "$escopo" "A rede $sujeito não ficou em autostart."
            elif [ "$tipo" = "NETWORK-AUTOSTART-OFF" ] \
                 && [ "$ESTADO_REDE_EXISTE" = "SIM" ] && [ "$ESTADO_REDE_AUTOSTART" = "SIM" ]; then
                falha_postcondicao "$escopo" "A rede $sujeito continua em autostart."
            fi
            ;;
        NETWORK-UNDEFINED)
            if ! consultar_estado_rede_libvirt "$REDE_LIBVIRT"; then
                falha_postcondicao "$escopo" "$ESTADO_REDE_ERRO Não foi possível provar a remoção de $sujeito."
            elif [ "$ESTADO_REDE_PERSISTENTE" = "SIM" ]; then
                falha_postcondicao "$escopo" "a definição criada por esta execução continua presente em $sujeito."
            fi
            ;;
        NETWORK-ACTIVE-CAPTURE)
            provar_xml_rede_restaurado ativo "$TX_REDE_XML_ATIVO"
            ;;
        NETWORK-PERSISTENT-CAPTURE)
            provar_xml_rede_restaurado persistente "$TX_REDE_XML_PERSISTENTE"
            ;;
        NETWORK-AUTOSTART-CAPTURE)
            if ! consultar_estado_rede_libvirt "$REDE_LIBVIRT"; then
                falha_postcondicao "$escopo" "$ESTADO_REDE_ERRO Não foi possível provar o autostart de $sujeito."
            else
                atual=0
                [ "$ESTADO_REDE_AUTOSTART" = "SIM" ] && atual=1
                [ "$atual" -eq "$TX_REDE_AUTOSTART" ] \
                    || falha_postcondicao "$escopo" "autostart de $sujeito não voltou ao valor anterior."
            fi
            ;;
        NETWORK-STATE)
            provar_estado_rede_capturado "$escopo" "$sujeito"
            ;;
        PROFILE-ARCHIVED)
            sudo cmp -s "$NETPLAN_BRIDGE_ARQUIVO" "$PERFIL_BACKUP" \
                || falha_postcondicao "$escopo" "o backup datado de $sujeito não corresponde ao artefato anterior."
            ;;
        PROFILE-CONTENT)
            sudo cmp -s "$NETPLAN_TMP" "$NETPLAN_BRIDGE_ARQUIVO" \
                || falha_postcondicao "$escopo" "o conteúdo publicado de $sujeito diverge da intenção."
            ;;
        PROFILE-MODE)
            modo_esperado="$(printf '%o' "$(op_argumento "$indice" mode)")"
            atual="$(sudo stat -c '%a' -- "$NETPLAN_BRIDGE_ARQUIVO" 2>/dev/null || true)"
            [ "$atual" = "$modo_esperado" ] \
                || falha_postcondicao "$escopo" "o modo publicado de $sujeito é '${atual:-desconhecido}', mas a intenção é '$modo_esperado'."
            ;;
        PROFILE-REVERSIBLE)
            sudo test -e "$NETPLAN_BRIDGE_ARQUIVO" \
                || falha_postcondicao "$escopo" "a ativação reversível de $sujeito não preservou o artefato publicado."
            ;;
        PROFILE-DIGEST)
            if ! sudo test -e "$NETPLAN_BRIDGE_ARQUIVO"; then
                falha_postcondicao "$escopo" "$NETPLAN_BRIDGE_ARQUIVO não existe após a restauração."
            elif ! sudo cmp -s "$TMP_DIR/netplan-bridge.anterior.yaml" "$NETPLAN_BRIDGE_ARQUIVO"; then
                falha_postcondicao "$escopo" "o conteúdo restaurado de $NETPLAN_BRIDGE_ARQUIVO diverge do capturado."
            fi
            ;;
        PROFILE-ABSENT)
            ! sudo test -e "$NETPLAN_BRIDGE_ARQUIVO" \
                || falha_postcondicao "$escopo" "$NETPLAN_BRIDGE_ARQUIVO continua presente após a remoção da criação parcial."
            ;;
        PROFILE-RENDERABLE)
            sudo netplan generate \
                || falha_postcondicao "$escopo" "o perfil de rede restaurado não é renderizável."
            ;;
        LINK-TOPOLOGY)
            atual="$(master_da_interface "$INTERFACE_FISICA" || true)"
            [ "$atual" = "$TX_UPLINK_MASTER" ] \
                || falha_postcondicao "$escopo" "o uplink $sujeito ficou sob master '${atual:-nenhum}', mas o capturado era '${TX_UPLINK_MASTER:-nenhum}'."
            ;;
        BRIDGE-RUNTIME)
            bridge_runtime_confere \
                || falha_postcondicao "$escopo" "Pós-condição da bridge falhou: $sujeito deve existir, estar administrativamente UP e ter $INTERFACE_FISICA como porta."
            ;;
        DOMAIN-NIC-SOURCE)
            provar_fonte_nic "$escopo" "$sujeito"
            ;;
        DOMAIN-FINGERPRINT)
            provar_dominio_restaurado "$escopo" "$sujeito"
            ;;
        CONFIGURATION-DIGEST)
            cmp -s "$TMP_DIR/passthrough.conf.anterior" "$CONF_ARQUIVO" \
                || falha_postcondicao "$escopo" "o conteúdo restaurado de $CONF_ARQUIVO diverge do capturado."
            ;;
        ADDRESS-PAIR)
            read -r iface ip_vm ip_host <<< "$sujeito"
            validar_ips_interface_rede "$iface" "$ip_vm" "$ip_host" \
                || falha_postcondicao "$escopo" "${REDE_IP_ERRO:-Os endereços do host e da VM não compartilham o prefixo efetivo.}"
            ;;
        *)
            falha_postcondicao "$escopo" "Pós-condição fora do mapa deste provider: '$tipo'."
            ;;
    esac
}

provar_estado_rede_capturado() {
    # As quatro flags provam o ESTADO restaurado; o XML prova o CONTEÚDO e já
    # foi comparado pelos passos anteriores.
    local escopo="$1" sujeito="$2" existe=0 persistente=0 ativa=0 autostart=0
    if ! consultar_estado_rede_libvirt "$REDE_LIBVIRT"; then
        falha_postcondicao "$escopo" "$ESTADO_REDE_ERRO Não foi possível validar o estado da rede após a restauração."
        return 0
    fi
    [ "$ESTADO_REDE_EXISTE" = "SIM" ] && existe=1
    [ "$ESTADO_REDE_PERSISTENTE" = "SIM" ] && persistente=1
    [ "$ESTADO_REDE_ATIVA" = "SIM" ] && ativa=1
    [ "$ESTADO_REDE_AUTOSTART" = "SIM" ] && autostart=1
    [ "$existe" -eq "$TX_REDE_EXISTIA" ] \
        || falha_postcondicao "$escopo" "existência de $sujeito não voltou ao estado anterior."
    [ "$persistente" -eq "$TX_REDE_PERSISTENTE" ] \
        || falha_postcondicao "$escopo" "persistência de $sujeito não voltou ao estado anterior."
    [ "$ativa" -eq "$TX_REDE_ATIVA" ] \
        || falha_postcondicao "$escopo" "estado ativo de $sujeito não voltou ao valor anterior."
    [ "$autostart" -eq "$TX_REDE_AUTOSTART" ] \
        || falha_postcondicao "$escopo" "autostart de $sujeito não voltou ao valor anterior."
}

provar_fonte_nic() {
    local escopo="$1" mac="$2" tipo atributo valor
    tipo="$CAP_FONTE_TIPO_PRETENDIDA"
    valor="$CAP_FONTE_PRETENDIDA"
    case "$tipo" in
        network) atributo=network ;;
        bridge) atributo=bridge ;;
        direct) atributo=dev ;;
        *)
            falha_postcondicao "$escopo" "fonte pretendida da NIC $mac fora do vocabulário: '$tipo'."
            return 0
            ;;
    esac
    nic_vm_confere_fonte "$tipo" "$atributo" "$valor" \
        || falha_postcondicao "$escopo" "A fonte da NIC $mac não foi comprovada após o define${XML_BACKUP_PATH:+; revise $XML_BACKUP_PATH}."
}

provar_dominio_restaurado() {
    # O define não é prova: o XML é relido e comparado pelo core, que já
    # devolve EQUAL/FINGERPRINT_LEFT/FINGERPRINT_RIGHT (lib/common.sh:2996).
    local escopo="$1" nome="$2" observado status
    observado="$TMP_DIR/vm-restaurada.xml"
    if ! $VIRSH dumpxml --inactive "$VM_NAME" > "$observado"; then
        falha_postcondicao "$escopo" "não foi possível reler o XML da VM $nome após a restauração."
        return 0
    fi
    if xml_dominio_equivalente "$TMP_DIR/vm-anterior.xml" "$observado"; then
        return 0
    else
        status=$?
    fi
    if [ "$status" -eq 2 ]; then
        falha_postcondicao "$escopo" "não foi possível comparar o XML restaurado da VM $nome: ${XML_COMPARACAO_ERRO:-sem diagnóstico}."
    else
        falha_postcondicao "$escopo" "o XML restaurado da VM $nome diverge do capturado (${XML_COMPARACAO_DIFERENCA:-divergência não detalhada}); a restauração não foi comprovada."
    fi
}

provar_postcondicoes() {
    # $1 = escopo (operation|rollback|plan); $2 = índice do passo (vazio no
    # escopo do plano).
    local escopo="$1" indice="${2:-}" passo="" i id tipo sujeito atual
    if [ "$escopo" != "plan" ]; then
        plano_ler passo "$escopo" "$indice" ID
    fi
    for ((i = 0; i < PLANO_POS_TOTAL; i++)); do
        plano_ler atual postcondition "$i" SCOPE
        [ "$atual" = "$escopo" ] || continue
        plano_ler atual postcondition "$i" STEP
        [ "$atual" = "$passo" ] || continue
        plano_ler id postcondition "$i" ID
        if [[ "$id" =~ ^PC-(OP|RB)-[0-9]+-(.+)$ ]]; then
            tipo="${BASH_REMATCH[2]}"
        elif [[ "$id" =~ ^PC-PLAN-(.+)$ ]]; then
            tipo="${BASH_REMATCH[1]}"
        else
            falha_postcondicao "$escopo" "Identificador de pós-condição fora do formato: '$id'."
            continue
        fi
        plano_ler sujeito postcondition "$i" SUBJECT
        provar_postcondicao "$escopo" "$indice" "$tipo" "$sujeito"
    done
}

# --- Providers: verbo abstrato -> comando concreto ----------------------------

op_configuracao_publicar() {
    local chave valor
    chave="$(op_argumento "$1" key)"
    valor="$(op_argumento "$1" value)"
    CHAVES_PUBLICADAS+=("$chave")
    VALORES_PUBLICADOS+=("$valor")
    salvar_conf_transacao "$chave" "$valor"
}

op_rede_definir() {
    local indice="$1" destino="$TMP_DIR/rede-nat.xml" backup
    if [ "$TX_REDE_EXISTIA" -eq 1 ]; then
        # O backup é do XML CAPTURADO na abertura da transação, não da última
        # recaptura: uma operação anterior do plano pode já ter destruído a
        # instância transitória, e o operador precisa do estado que existia
        # antes de a etapa começar.
        mkdir -p "$BACKUPS_DIR"
        backup="$BACKUPS_DIR/rede-${REDE_LIBVIRT}-$(date +%Y%m%d-%H%M%S).xml"
        cp -p "${TX_REDE_XML_PERSISTENTE:-$TX_REDE_XML_ATIVO}" "$backup" \
            || falhar "Falha ao salvar o backup da rede libvirt $REDE_LIBVIRT."
        info "Backup da rede libvirt salvo em: $backup"
    fi
    render_xml_rede \
        "$(op_argumento "$indice" name)" \
        "$(op_argumento "$indice" uuid)" \
        "$(op_argumento "$indice" marker)" \
        "$(op_argumento "$indice" forward_mode)" \
        "$(op_argumento "$indice" forward_device)" \
        "$(op_argumento "$indice" forward_port_start)" \
        "$(op_argumento "$indice" forward_port_end)" \
        "$(op_argumento "$indice" bridge)" \
        "$(op_argumento "$indice" bridge_stp)" \
        "$(op_argumento "$indice" bridge_delay)" \
        "$(op_argumento "$indice" gateway)" \
        "$(op_argumento "$indice" netmask)" \
        "$(op_argumento "$indice" dhcp_start)" \
        "$(op_argumento "$indice" dhcp_end)" \
        "$(op_argumento "$indice" reservation_mac)" \
        "$(op_argumento "$indice" reservation_ip)" > "$destino"
    registrar_mutacao rede
    $VIRSH net-define "$destino" >/dev/null \
        || falhar "Falha ao definir o XML NAT de $REDE_LIBVIRT."
}

op_rede_parar() {
    registrar_mutacao rede
    $VIRSH net-destroy "$REDE_LIBVIRT" >/dev/null \
        || falhar "Falha ao parar a rede $REDE_LIBVIRT."
}

op_rede_ativar() {
    registrar_mutacao rede
    $VIRSH net-start "$REDE_LIBVIRT" >/dev/null \
        || falhar "Falha ao iniciar a rede $REDE_LIBVIRT."
}

op_rede_autostart() {
    registrar_mutacao rede
    if [ "$1" -eq 1 ]; then
        $VIRSH net-autostart "$REDE_LIBVIRT" >/dev/null \
            || falhar "Falha ao habilitar o autostart de $REDE_LIBVIRT."
    else
        $VIRSH net-autostart "$REDE_LIBVIRT" --disable >/dev/null \
            || falhar "Falha ao desabilitar o autostart de $REDE_LIBVIRT."
    fi
}

op_perfil_arquivar() {
    registrar_mutacao netplan
    PERFIL_BACKUP="${NETPLAN_BRIDGE_ARQUIVO}.bak-$(date +%Y%m%d-%H%M%S)"
    sudo cp -p "$NETPLAN_BRIDGE_ARQUIVO" "$PERFIL_BACKUP" \
        || falhar "Falha ao criar backup datado de $NETPLAN_BRIDGE_ARQUIVO."
    ok "Backup criado: $PERFIL_BACKUP"
}

op_perfil_publicar() {
    local indice="$1" modo nome_conteudo
    NETPLAN_TMP="$TMP_DIR/netplan-bridge.yaml"
    # Sem `$( )`: a substituição de comando descartaria a nova linha final do
    # artefato, e o conteúdo publicado deixaria de convergir com a intenção.
    nome_conteudo="PL_OPERATION_${indice}_ARGUMENT_CONTENT"
    printf '%s' "${!nome_conteudo-}" > "$NETPLAN_TMP"
    modo="$(printf '%04o' "$(op_argumento "$indice" mode)")"
    registrar_mutacao netplan
    sudo install -m "$modo" "$NETPLAN_TMP" "$NETPLAN_BRIDGE_ARQUIVO" \
        || falhar "Falha ao gravar $NETPLAN_BRIDGE_ARQUIVO."
}

op_perfil_ativar_reversivel() {
    sudo netplan generate \
        || falhar "netplan generate reprovou a configuração; o rollback restaurará o estado anterior."
    echo
    aviso "Vai rodar 'netplan try': sem confirmação, a configuração anterior volta em ~120 segundos."
    registrar_mutacao netplan
    sudo netplan try \
        || falhar "netplan try falhou/reverteu; o rollback reaplicará a configuração anterior."
}

op_perfil_ativar() {
    registrar_mutacao netplan
    sudo netplan apply \
        || falhar "netplan apply falhou; o rollback reaplicará a configuração anterior."
}

op_dominio_redefinir() {
    local indice="$1" tipo valor atributo origem candidato conteudo
    tipo="$(op_argumento "$indice" source_type)"
    valor="$(op_argumento "$indice" source)"
    case "$tipo" in
        network) atributo=network ;;
        bridge) atributo=bridge ;;
        direct) atributo=dev ;;
        *) falhar "Fonte de NIC fora do vocabulário do plano: '$tipo'." ;;
    esac
    # O plano é a autoridade sobre a fonte pretendida; a prova do escopo do
    # plano usa o mesmo par quando a operação nem chega a existir (execução já
    # convergente).
    CAP_FONTE_TIPO_PRETENDIDA="$tipo"
    CAP_FONTE_PRETENDIDA="$valor"
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
        "$(op_argumento "$indice" nic_mac)" "$tipo" "$atributo" "$valor" \
        || falhar "Candidato da NIC recusado: $XML_CANDIDATO_ERRO"
    virt-xml-validate "$candidato" domain >/dev/null \
        || falhar "O schema libvirt recusou o candidato da NIC; nada foi definido."
    xml_backup "$VM_NAME"
    registrar_mutacao vm
    $VIRSH define "$candidato" >/dev/null
    ok "Fonte da NIC $VM_NIC_MAC alterada para $tipo/$atributo=$valor; MAC preservado."
}

executar_operacao() {
    local indice="$1" verbo
    plano_ler verbo operation "$indice" VERB
    case "$verbo" in
        configuration-publish) op_configuracao_publicar "$indice" ;;
        network-define) op_rede_definir "$indice" ;;
        network-deactivate) op_rede_parar ;;
        network-activate) op_rede_ativar ;;
        network-autostart-enable) op_rede_autostart 1 ;;
        network-autostart-disable) op_rede_autostart 0 ;;
        host-profile-archive) op_perfil_arquivar ;;
        host-profile-store) op_perfil_publicar "$indice" ;;
        host-network-activate-reversible) op_perfil_ativar_reversivel ;;
        host-network-activate) op_perfil_ativar ;;
        domain-redefine) op_dominio_redefinir "$indice" ;;
        *) falhar "Verbo do plano fora do mapa deste provider: '$verbo'." ;;
    esac
}

aplicar_plano() {
    local indice autorizacao anterior="" rotulo
    for ((indice = 0; indice < PLANO_OP_TOTAL; indice++)); do
        plano_ler autorizacao operation "$indice" REVALIDATE
        autorizacao="${autorizacao//$PAIRS_NL/ }"
        if [ "$indice" -eq 0 ] || [ "$autorizacao" != "$anterior" ]; then
            rotulo="antes de aplicar"
            if [ "$indice" -ne 0 ]; then
                plano_ler rotulo operation "$indice" ID
                rotulo="antes de $rotulo"
            fi
            revalidar_estado "$anterior" "$rotulo" \
                || falhar "${REVAL_CONFLITO:-divergência não detalhada}; nada foi sobrescrito."
            anterior="$autorizacao"
            AUTORIZACAO_GRUPO="$autorizacao"
        fi
        executar_operacao "$indice"
        provar_postcondicoes operation "$indice"
    done
    revalidar_estado "$anterior" "antes do commit" \
        || falhar "${REVAL_CONFLITO:-divergência não detalhada}; a transação não foi confirmada."
    provar_postcondicoes plan ""
}

resolver_vm_nic_mac

if [ "$REDE_MODO" = "bridge" ]; then
    titulo "Etapa 19: bridge Ethernet ($INTERFACE_FISICA -> $REDE_BRIDGE)"
    CAP_FONTE_TIPO_PRETENDIDA=bridge
    CAP_FONTE_PRETENDIDA="$REDE_BRIDGE"
    coletar_enderecos_bridge
    gerar_perfil_host
else
    titulo "Etapa 19: NAT libvirt dedicado ($REDE_LIBVIRT via $INTERFACE_FISICA)"
    info "Caminho NAT: nenhuma configuração ou comando do Netplan será usado."
    CAP_FONTE_TIPO_PRETENDIDA=network
    CAP_FONTE_PRETENDIDA="$REDE_LIBVIRT"
    escolher_subrede_nat
    derivar_parametros_nat || falhar "Falha ao derivar endereços de $REDE_NAT_CIDR."
    gerar_xml_rede_nat
fi

capturar_alvo
construir_plano
provar_precondicoes
if [ "$REDE_MODO" = "nat" ]; then
    confirmar_subrede_livre
fi
aplicar_plano
commit_transacao

if [ "$REDE_MODO" = "bridge" ]; then
    ip addr show "$REDE_BRIDGE" | sed 's/^/  /'
    ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1 \
        && ok "Conectividade externa do host OK via bridge." \
        || aviso "Sem resposta de 8.8.8.8; confira cabo, DHCP e roteador."
    if [ -n "${VM_IP_FIXO:-}" ] && [ -n "${IP_FIXO_HOST:-}" ]; then
        ok "Reservas coerentes com o IPv4 efetivo de $REDE_BRIDGE."
    else
        aviso "Endereços da bridge incompletos: a rede pode estar aplicada, mas a etapa 19 permanece pendente."
        aviso "Preencha o IP da VM Windows e o IP do host Linux, renove o DHCP e rode --verificar antes da etapa 20."
    fi
    info "No Windows, 'ipconfig' deve mostrar o IP da VM Windows na mesma sub-rede da LAN."
else
    ok "Rede gerenciada $REDE_LIBVIRT ativa/autostart: bridge=$REDE_BRIDGE_LIBVIRT, sub-rede=$REDE_NAT_CIDR."
    ok "Reserva DHCP automática: $VM_NIC_MAC -> IP da VM Windows $VM_IP_FIXO."
    ok "Gateway virtual do host acessível pela VM: $IP_FIXO_HOST."
    info "Ao iniciar/renovar DHCP no Windows, a VM usará $VM_IP_FIXO e acessará o airlock no host em $IP_FIXO_HOST."
fi

echo
ok "Alterações da etapa 19 aplicadas: modo=$REDE_MODO, uplink=$INTERFACE_FISICA, NIC=$VM_NIC_MAC."
info "A etapa só fica pronta para o airlock quando os endereços da VM Windows e do host estão preenchidos e --verificar aprova."
