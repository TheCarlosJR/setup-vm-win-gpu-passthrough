#!/bin/bash
# ============================================================================
# lib/shell/config.sh - schema, leitura e escrita de passthrough.conf
# ============================================================================
# Este arquivo NÃO é executado diretamente: ele é carregado via "source" por
# lib/common.sh, que continua sendo a fachada pública das etapas.
#
# Fronteiras (seções 2.1, 2.3 e 2.4 do PLANO-FINALIZACAO.md):
#
#   * aqui fica o ciclo de vida da configuração: allowlist de chaves, leitura,
#     publicação atômica, migrações (ISO legada, dispensas depreciadas) e a
#     exigência de configuração presente;
#   * o módulo existe por decisão registrada (I9-D1 do plano): as funções de
#     configuração não têm casa entre os dez módulos da seção 2.3, e juntá-las
#     a storage.sh misturaria schema com ciclo de vida de arquivo;
#   * a validação de valor é do core Python; este módulo transporta, nunca
#     reimplementa o schema.
#
# BACKUPS_DIR e PROJETO_DIR vêm da fachada, que resolve a raiz do checkout
# antes de carregar qualquer módulo; nenhum módulo recalcula esse caminho.
#
# Pré-requisitos de carga: lib/python-core.sh, lib/shell/base.sh, lib/shell/storage.sh, lib/shell/ui.sh.
# Carregar fora de ordem é recusado com diagnóstico, nunca com falha obscura.
#
# Sourcing deste arquivo não produz efeito: apenas define variáveis e funções.
# ============================================================================

if ! declare -F _core_diagnostico > /dev/null 2>&1; then
    printf 'ERRO: lib/shell/config.sh exige %s carregado antes.\n' 'lib/shell/base.sh' >&2
    return 1 2>/dev/null || exit 1
fi
if ! declare -F falhar > /dev/null 2>&1; then
    printf 'ERRO: lib/shell/config.sh exige %s carregado antes.\n' 'lib/shell/ui.sh' >&2
    return 1 2>/dev/null || exit 1
fi
if ! declare -F validar_iso_configurada > /dev/null 2>&1; then
    printf 'ERRO: lib/shell/config.sh exige %s carregado antes.\n' 'lib/shell/storage.sh' >&2
    return 1 2>/dev/null || exit 1
fi
if ! declare -F python_core_config > /dev/null 2>&1; then
    printf 'ERRO: lib/shell/config.sh exige %s carregado antes.\n' 'lib/python-core.sh' >&2
    return 1 2>/dev/null || exit 1
fi

[ -n "${CONFIG_SH_CARREGADO:-}" ] && return 0
CONFIG_SH_CARREGADO=1

# --- Configuração central (passthrough.conf) ---------------------------------
# O arquivo é tratado como DADOS, nunca como código shell. Somente as chaves
# conhecidas abaixo e literais simples são aceitos; command substitution, eval,
# expansões de variáveis e diretivas shell são rejeitados antes de qualquer uso.
# O arquivo de configuração pertence a este módulo: quem o lê, escreve e
# migra mora aqui. PROJETO_DIR vem da fachada, que resolve a raiz do checkout
# antes de carregar qualquer módulo.
CONF_ARQUIVO="$PROJETO_DIR/passthrough.conf"

CHAVES_CONF_PERMITIDAS=(
    USUARIO_LINUX VM_NAME BOOTLOADER VM_STORAGE_GROUP
    GPU_PCI_ID GPU_AUDIO_PCI_ID GPU_VENDOR_DEVICE_ID GPU_AUDIO_VENDOR_DEVICE_ID
    IOMMU_GROUP_GPU DM_SERVICE
    USB_CTRL_PCI_IDS USB_CTRL_VENDOR_DEVICE_IDS USB_CTRL_IOMMU_GROUP
    NVME_DEVICE SYSTEM_DISK_FINGERPRINT
    WORKING_DISK_PATH WORKING_DISK_FINGERPRINT WORKING_DISK_DISPENSADO
    HD1_BY_ID_PATH HD1_DISK_FINGERPRINT HD1_DISPENSADO
    QCOW2_PATH QCOW2_TAMANHO VM_RAM_MB VM_VCPUS VM_CORES VM_THREADS
    CPUS_VM CPUS_HOST HUGEPAGES_1G ISO_WINDOWS ISO_VIRTIO NVIDIA_DRIVER_EXE
    REDE_MODO INTERFACE_FISICA REDE_BRIDGE REDE_LIBVIRT
    REDE_BRIDGE_LIBVIRT REDE_NAT_CIDR VM_NIC_MAC VM_IP_FIXO IP_FIXO_HOST
    TRANSFER_USER AIRLOCK_DIR AIRLOCK_BIND
    BACKUPS_VM_DIR
)

# REQ-WAIVERS (decidido em I4.8): AIRLOCK_DISPENSADO e BACKUP_DISPENSADO saíram
# da allowlist porque nunca alteraram pré-requisito, status ou execução. O core
# continua aceitando as linhas para não derrubar configuração existente, sem
# expor o valor, e a etapa 3 remove as linhas na migração. As duas dispensas
# que permanecem (workingDisk e HD1) têm efeito real e testado.
CHAVES_CONF_DEPRECIADAS=(AIRLOCK_DISPENSADO BACKUP_DISPENSADO)

chave_conf_permitida() {
    local procurada="${1:-}" chave
    for chave in "${CHAVES_CONF_PERMITIDAS[@]}"; do
        [ "$chave" = "$procurada" ] && return 0
    done
    return 1
}

ISO_OPCIONAL_ESTADO=""
ISO_OPCIONAL_ERRO=""
classificar_iso_opcional_conf() {
    # Classifica um caminho de ISO digitado ANTES de persisti-lo, com a mesma
    # política de salvar_conf/etapa 12 (filho direto canônico de /vm, sem
    # vírgula e sem links). Um prompt opcional consulta esta função para nunca
    # abortar dentro de salvar_conf por um caminho fora da política.
    # Estados em sucesso: vazia (sem valor), ausente (política ok, arquivo
    # ainda não existe; /vm nasce na etapa 7) e valida (arquivo regular ok).
    local logico="${1:-}" fisico
    ISO_OPCIONAL_ESTADO=""
    ISO_OPCIONAL_ERRO=""
    if [ -z "$logico" ]; then
        ISO_OPCIONAL_ESTADO=vazia
        return 0
    fi
    if ! caminho_artefato_vm_logico_valido "$logico"; then
        ISO_OPCIONAL_ERRO="Caminho recusado pela política de armazenamento: a ISO precisa ser um filho direto canônico de /vm, sem vírgula (ex.: /vm/Win11.iso); recebi '$logico'."
        return 1
    fi
    fisico="$(_caminho_configurado_fisico "$logico")" \
        || { ISO_OPCIONAL_ERRO="Não foi possível mapear a ISO: $logico"; return 1; }
    if [ ! -e "$fisico" ] && [ ! -L "$fisico" ]; then
        ISO_OPCIONAL_ESTADO=ausente
        return 0
    fi
    validar_iso_configurada "$logico" \
        || { ISO_OPCIONAL_ERRO="$ARMAZENAMENTO_ERRO"; return 1; }
    ISO_OPCIONAL_ESTADO=valida
}

CONF_ISO_NOVO_VALOR=""
perguntar_iso_valor_conf() {
    # Só decide o valor; não persiste. Separar a decisão da persistência é o que
    # permite reaproveitar exatamente este prompt na migração pré-parser de
    # REQ-CONF-ISO, onde a publicação precisa ser um único rename com todas as
    # chaves pendentes.
    # Publica CONF_ISO_NOVO_VALOR (vazio significa "decidir na etapa 12").
    local descricao="$1" caminho tentativas=0
    CONF_ISO_NOVO_VALOR=""
    while :; do
        caminho="$(perguntar "Caminho da $descricao em /vm (ENTER para informar depois, na etapa 12)" '')"
        caminho="${caminho/#\~/$HOME}"
        if [ -z "$caminho" ]; then
            return 0
        fi
        if classificar_iso_opcional_conf "$caminho"; then
            if [ "$ISO_OPCIONAL_ESTADO" = ausente ]; then
                aviso "Arquivo não encontrado: $caminho (ficará vazio; informe na etapa 12)."
                return 0
            fi
            CONF_ISO_NOVO_VALOR="$caminho"
            ok "$descricao validada sem links: $caminho"
            return 0
        fi
        aviso "$ISO_OPCIONAL_ERRO"
        info "Copie a ISO como operador para um nome direto e exclusivo em /vm (criado na etapa 7) e informe esse caminho, ou ENTER para decidir na etapa 12."
        tentativas=$((tentativas + 1))
        if [ "$tentativas" -ge 5 ]; then
            aviso "Cinco tentativas sem um caminho aceito; a $descricao ficará vazia (informe na etapa 12)."
            return 0
        fi
    done
}

perguntar_iso_opcional_conf() {
    # Prompt opcional de ISO da etapa 3. ENTER, arquivo ainda ausente ou cinco
    # recusas deixam a chave vazia para a etapa 12 exigir depois; somente um
    # caminho aceito pela política é persistido, então salvar_conf nunca
    # derruba a detecção por causa de uma ISO.
    local chave="$1" descricao="$2"
    perguntar_iso_valor_conf "$descricao"
    salvar_conf "$chave" "$CONF_ISO_NOVO_VALOR"
}

# validar_valor_conf mudou de lugar: o mapeamento chave -> tipo agora vive no
# módulo de configuração do core Python, e o wrapper público está junto das
# demais funções de configuração, mais abaixo. Os validadores primitivos
# (caminho, MAC, IPv4, lista de CPUs, interface) permanecem aqui porque são
# usados por prompts e por validação de dados de runtime, não só pelo schema.

_trim_espacos_conf() {
    local valor="$1"
    valor="${valor#"${valor%%[![:space:]]*}"}"
    valor="${valor%"${valor##*[![:space:]]}"}"
    REPLY="$valor"
}

_resto_conf_valido() {
    _trim_espacos_conf "$1"
    [ -z "$REPLY" ] || [[ "$REPLY" == \#* ]]
}

_decodificar_literal_conf() {
    # Define REPLY. Aceita "literal" com escapes inertes, 'literal' simples ou
    # literal não cotado restrito. Nada aqui é passado a eval/source.
    local bruto="$1" valor="" resto caractere escape=0 fechado=0 i
    _trim_espacos_conf "$bruto"
    bruto="$REPLY"
    [ -n "$bruto" ] || { REPLY=""; return 0; }

    if [ "${bruto:0:1}" = '"' ]; then
        for ((i = 1; i < ${#bruto}; i++)); do
            caractere="${bruto:i:1}"
            if [ "$escape" -eq 1 ]; then
                if [ "$caractere" = '\' ] || [ "$caractere" = '"' ] \
                   || [ "$caractere" = '$' ] || [ "$caractere" = '`' ]; then
                    valor+="$caractere"
                    escape=0
                    continue
                fi
                return 1
            fi
            if [ "$caractere" = '\' ]; then
                escape=1
            elif [ "$caractere" = '"' ]; then
                fechado=1
                resto="${bruto:$((i + 1))}"
                break
            else
                valor+="$caractere"
            fi
        done
        [ "$fechado" -eq 1 ] && [ "$escape" -eq 0 ] && _resto_conf_valido "$resto" || return 1
        REPLY="$valor"
        return 0
    fi

    if [ "${bruto:0:1}" = "'" ]; then
        for ((i = 1; i < ${#bruto}; i++)); do
            caractere="${bruto:i:1}"
            if [ "$caractere" = "'" ]; then
                fechado=1
                resto="${bruto:$((i + 1))}"
                break
            fi
            valor+="$caractere"
        done
        [ "$fechado" -eq 1 ] && _resto_conf_valido "$resto" || return 1
        REPLY="$valor"
        return 0
    fi

    valor="${bruto%%#*}"
    _trim_espacos_conf "$valor"
    valor="$REPLY"
    case "$valor" in
        *[![:alnum:]_./:@,+%=-]*) return 1 ;;
    esac
    REPLY="$valor"
}

# --- Fronteira de configuração: o core é a única implementação ----------------
# As funções públicas abaixo mantêm nome, argumentos, efeitos e mensagens de
# antes da migração. O que mudou é onde o schema mora: parsing, validação,
# serialização e publicação atômica passaram a ser do core Python. O caminho do
# conf é um LOCAL_IDENTIFIER e, pela seção 3.9, não entra em argv: a ponte passa
# o descritor do diretório e o basename viaja no payload.
#
# CHAVES_CONF_PERMITIDAS continua sendo a allowlist do canal de pares. Ela não é
# uma segunda autoridade sobre o schema: se divergir do core, a carga falha
# fechada, porque o core emitiria uma chave que a allowlist não autoriza.

CONF_DIRETORIO_ALVO=""
CONF_NOME_ALVO=""
CONF_PARES_PERMITIDAS=()

_conf_localizar_alvo() {
    # Separa o alvo em diretório e basename, sem resolver o link do arquivo.
    local caminho="${1:-$CONF_ARQUIVO}"
    CONF_DIRETORIO_ALVO=""
    CONF_NOME_ALVO=""
    case "$caminho" in
        */*)
            CONF_DIRETORIO_ALVO="${caminho%/*}"
            CONF_NOME_ALVO="${caminho##*/}"
            [ -n "$CONF_DIRETORIO_ALVO" ] || CONF_DIRETORIO_ALVO=/
            ;;
        *)
            CONF_DIRETORIO_ALVO="$(pwd -P)" || return 1
            CONF_NOME_ALVO="$caminho"
            ;;
    esac
    [ -n "$CONF_NOME_ALVO" ] || return 1
    return 0
}

_conf_allowlist_pares() {
    # Allowlist completa da resposta, derivada da própria allowlist do shell.
    local chave
    CONF_PARES_PERMITIDAS=(
        CORE_VERSION PROTOCOL_VERSION SUBCOMMAND
        EXISTS KEY_COUNT PRESENT_COUNT FINAL_NEWLINE LINE_COUNT
        CHANGED UPDATE_COUNT MIGRATED_COUNT REMOVED_COUNT INVALID_BEFORE
        PUBLISHED CREATED BYTES_WRITTEN SHA256
        MODE_OCTAL MODE_EXPOSES_OTHERS
        DEPRECATED_PRESENT DEPRECATED_WITH_VALUE DEPRECATED_KEYS
        RELATION_CONFLICTS RELATION_CONFLICT_KEYS
    )
    for chave in "${CHAVES_CONF_PERMITIDAS[@]}"; do
        CONF_PARES_PERMITIDAS+=("VALUE_$chave" "PRESENT_$chave")
    done
}

carregar_conf() {
    # Lê e valida a configuração pelo core. Chave ausente é desdefinida, para
    # que uma execução nunca herde valor de outra (protocolo NUL validado).
    local chave nome_valor nome_presente
    local -a payload=()
    _conf_localizar_alvo \
        || falhar "Caminho de configuração inválido: $CONF_ARQUIVO"
    if [ -L "$CONF_ARQUIVO" ]; then
        falhar "Configuração precisa ser um arquivo regular, não um link: $CONF_ARQUIVO"
    fi
    for chave in "${CHAVES_CONF_PERMITIDAS[@]}"; do
        unset "$chave"
    done
    [ -e "$CONF_ARQUIVO" ] || return 0
    _conf_allowlist_pares
    payload=(name "$CONF_NOME_ALVO")
    if ! python_core_config CONF_PARES_PERMITIDAS CFG_ config-load payload \
            "$CONF_DIRETORIO_ALVO"; then
        falhar "Configuração recusada em $CONF_ARQUIVO: $(_core_diagnostico 'schema fechado violado')"
    fi
    [ "${CFG_EXISTS:-0}" = 1 ] || return 0
    # Uma flag depreciada com valor mente sobre ter efeito; avisar é obrigatório
    # e a etapa 3 remove a linha. Um conflito de relação (caminho definido e
    # dispensa "sim") é reportado aqui e explicado pela etapa que o possui.
    if [ "${CFG_DEPRECATED_WITH_VALUE:-0}" != 0 ]; then
        aviso "Configuração usa dispensa sem efeito: ${CFG_DEPRECATED_KEYS//$'\n'/, }. Rode a etapa 3 para remover a linha."
    fi
    if [ "${CFG_RELATION_CONFLICTS:-0}" != 0 ]; then
        aviso "Configuração contraditória entre caminho e dispensa: ${CFG_RELATION_CONFLICT_KEYS//$'\n'/, }."
    fi
    # A configuração guarda identidade local (BDF, MAC, IP, caminhos): a seção
    # 3.9 exige arquivo do projeto em 0600. Um modo herdado de cópia manual
    # expõe isso a qualquer conta da máquina, então o aviso é obrigatório. A
    # próxima gravação aperta o modo automaticamente.
    # O aviso vale só para a configuração real do operador: o modelo versionado
    # é neutro por desenho e pode ser legível por todos.
    if [ "${CFG_MODE_EXPOSES_OTHERS:-0}" != 0 ] \
        && [ "$CONF_NOME_ALVO" = passthrough.conf ]; then
        aviso "Configuração legível por outros usuários (modo ${CFG_MODE_OCTAL:-?}): ela guarda identificadores do seu hardware."
        info "Corrija agora com: chmod 600 $CONF_ARQUIVO (a próxima gravação também aperta o modo)."
    fi
    for chave in "${CHAVES_CONF_PERMITIDAS[@]}"; do
        nome_presente="CFG_PRESENT_$chave"
        nome_valor="CFG_VALUE_$chave"
        if [ "${!nome_presente}" = 1 ]; then
            printf -v "$chave" '%s' "${!nome_valor}"
            # shellcheck disable=SC2163
            export "$chave"
        else
            unset "$chave"
        fi
    done
}

_conf_publicar() {
    # $@ = pares CHAVE VALOR. Schema, serialização e publicação atômica são do
    # core; aqui só entram a allowlist, a cardinalidade e o transporte.
    local chave valor
    local -a payload=()
    local -A vistas=()
    _conf_localizar_alvo \
        || falhar "Caminho de configuração inválido: $CONF_ARQUIVO"
    [ ! -L "$CONF_ARQUIVO" ] \
        || falhar "Recusando atualizar link simbólico: $CONF_ARQUIVO"
    payload=(name "$CONF_NOME_ALVO")
    while [ "$#" -gt 0 ]; do
        chave="$1"
        valor="$2"
        shift 2
        chave_conf_permitida "$chave" \
            || falhar "Chave de configuração não permitida: '$chave'."
        [ -z "${vistas[$chave]+definida}" ] \
            || falhar "Chave repetida no lote: '$chave'."
        vistas[$chave]=1
        payload+=("set_${chave,,}" "$valor")
    done
    _conf_allowlist_pares
    if ! python_core_config CONF_PARES_PERMITIDAS CFG_ config-publish payload \
            "$CONF_DIRETORIO_ALVO"; then
        falhar "Falha ao publicar a configuração: $(_core_diagnostico 'persistência recusada')"
    fi
}

_conf_publicar_migracao() {
    # $1 = nome do array com as chaves toleradas; demais = pares CHAVE VALOR.
    # A tolerância vale apenas para as chaves declaradas, e o core exige que
    # cada uma delas receba um novo valor: nenhum valor legado inválido pode
    # sobreviver à publicação.
    local _cpm_toleradas="${1:-}" chave valor lista=""
    local -a payload=()
    shift
    local -n _cpm_ref="$_cpm_toleradas"
    for chave in "${_cpm_ref[@]}"; do
        lista+="${lista:+$'\n'}$chave"
    done
    _conf_localizar_alvo \
        || { erro "Caminho de configuração inválido: $CONF_ARQUIVO"; return 1; }
    [ ! -L "$CONF_ARQUIVO" ] \
        || { erro "Recusando atualizar link simbólico: $CONF_ARQUIVO"; return 1; }
    payload=(name "$CONF_NOME_ALVO" migrate_keys "$lista")
    while [ "$#" -gt 0 ]; do
        chave="$1"
        valor="$2"
        shift 2
        chave_conf_permitida "$chave" \
            || { erro "Chave não permitida na migração: '$chave'."; return 1; }
        payload+=("set_${chave,,}" "$valor")
    done
    _conf_allowlist_pares
    python_core_config CONF_PARES_PERMITIDAS CFG_ config-publish payload \
        "$CONF_DIRETORIO_ALVO"
}

salvar_conf() {
    # Atualização atômica de uma chave, preservando comentários, ordem e modo.
    local chave="$1" valor="${2-}"
    [ "$#" -eq 2 ] || falhar "salvar_conf exige CHAVE e VALOR."
    _conf_publicar "$chave" "$valor"
    printf -v "$chave" '%s' "$valor"
    # shellcheck disable=SC2163
    export "$chave"
}

salvar_conf_lote() {
    # salvar_conf_lote CHAVE VALOR [CHAVE VALOR...]. Valida tudo primeiro e
    # publica o conjunto em um único rename, evitando relações CPU parcialmente
    # atualizadas se a etapa for interrompida.
    local i
    local -a entradas=("$@") chaves=() valores=()
    [ "$#" -ge 2 ] && [ $(( $# % 2 )) -eq 0 ] \
        || falhar "salvar_conf_lote exige pares CHAVE/VALOR."
    for ((i = 0; i < ${#entradas[@]}; i += 2)); do
        chaves+=("${entradas[$i]}")
        valores+=("${entradas[$((i + 1))]}")
    done
    _conf_publicar "${entradas[@]}"
    for i in "${!chaves[@]}"; do
        printf -v "${chaves[$i]}" '%s' "${valores[$i]}"
        # shellcheck disable=SC2163
        export "${chaves[$i]}"
    done
}

validar_valor_conf() {
    # API pública preservada. O schema vive no core: esta função consulta a
    # mesma implementação usada na carga e na publicação, sem tocar arquivo.
    local chave="${1:-}" valor="${2-}"
    local -a permitidas=(CORE_VERSION PROTOCOL_VERSION SUBCOMMAND KEY DATA_CLASS VALID)
    local -a payload=()
    chave_conf_permitida "$chave" || return 1
    payload=(key "$chave" value "$valor")
    python_core_pares_payload permitidas CFGVAL_ config-validate payload 2>/dev/null
}

CONF_MIGRACAO_DISPENSAS_REMOVIDAS=0
conf_migrar_dispensas_depreciadas() {
    # REQ-WAIVERS: remove as linhas das dispensas sem efeito. Configuração já
    # limpa é no-op exato. A remoção é publicada pelo mesmo rename atômico da
    # configuração, então nunca há estado intermediário.
    # Retornos: 0 = nada a fazer ou removido; 1 = erro.
    local chave lista=""
    local -a payload=()
    CONF_MIGRACAO_DISPENSAS_REMOVIDAS=0
    [ -e "$CONF_ARQUIVO" ] || return 0
    _conf_localizar_alvo || return 1
    [ ! -L "$CONF_ARQUIVO" ] || return 1
    # Só remove o que realmente está no arquivo, para não republicar sem motivo.
    if ! grep -Eq "^[[:space:]]*(AIRLOCK_DISPENSADO|BACKUP_DISPENSADO)[[:space:]]*=" \
        "$CONF_ARQUIVO"; then
        return 0
    fi
    for chave in "${CHAVES_CONF_DEPRECIADAS[@]}"; do
        if grep -Eq "^[[:space:]]*${chave}[[:space:]]*=" "$CONF_ARQUIVO"; then
            lista+="${lista:+$'\n'}$chave"
        fi
    done
    [ -n "$lista" ] || return 0
    _conf_allowlist_pares
    payload=(name "$CONF_NOME_ALVO" remove_keys "$lista")
    if ! python_core_config CONF_PARES_PERMITIDAS CFG_ config-publish payload \
            "$CONF_DIRETORIO_ALVO"; then
        erro "Não foi possível remover as dispensas depreciadas da configuração."
        return 1
    fi
    CONF_MIGRACAO_DISPENSAS_REMOVIDAS="${CFG_REMOVED_COUNT:-0}"
    if [ "$CONF_MIGRACAO_DISPENSAS_REMOVIDAS" != 0 ]; then
        info "Dispensas sem efeito removidas da configuração: ${lista//$'\n'/, }."
        info "Para não usar o Airlock ou o backup, simplesmente não execute a etapa; o status continua dizendo a verdade."
    fi
    return 0
}

CONF_MIGRACAO_ISO_BACKUP=""
conf_migrar_iso_legada() {
    # REQ-CONF-ISO, fluxo completo. Roda ANTES de carregar_conf, porque um valor
    # legado inválido derrubaria o parser estrito e impediria justamente a
    # correção. Regras que este fluxo cumpre:
    #
    #   * o caminho legado nunca é aberto, resolvido, montado, copiado, testado
    #     por existência nem usado com privilégio: só o classificador
    #     pré-parser o lê, e como texto;
    #   * o valor antigo nunca é reaproveitado como sugestão;
    #   * um backup 0600 é criado antes de qualquer publicação;
    #   * todas as chaves pendentes entram em um único rename (todo-ou-nada);
    #   * em qualquer falha o original permanece utilizável e o backup é
    #     informado;
    #   * configuração já válida é no-op exato: nenhum backup, nenhuma escrita.
    #
    # Retornos: 0 = nada a fazer ou migração concluída; 1 = erro.
    local estado chave descricao timestamp indice rc=0
    local -a pendentes=() descricoes=() pares=() migradas=()
    CONF_MIGRACAO_ISO_BACKUP=""
    conf_iso_legada_classificar || rc=$?
    if [ "$rc" -eq 2 ]; then
        erro "Não foi possível classificar as ISOs da configuração antes do parser estrito."
        return 1
    fi
    [ "$rc" -eq 1 ] || return 0

    for chave in ISO_WINDOWS ISO_VIRTIO; do
        case "$chave" in
            ISO_WINDOWS)
                estado="$CONF_ISO_LEGADA_ESTADO_WINDOWS"
                descricao="ISO do Windows 11"
                ;;
            *)
                estado="$CONF_ISO_LEGADA_ESTADO_VIRTIO"
                descricao="ISO virtio-win"
                ;;
        esac
        case "$estado" in
            invalida|duplicada)
                pendentes+=("$chave")
                descricoes+=("$descricao")
                ;;
        esac
    done
    [ "${#pendentes[@]}" -gt 0 ] || return 0

    titulo "Migração segura de ISO legada na configuração"
    aviso "A configuração guarda ${CONF_ISO_LEGADA_PENDENTES} caminho(s) de ISO que a política atual recusa."
    info "O caminho antigo NÃO foi aberto, resolvido nem reaproveitado: ele é tratado apenas como texto."
    info "Política em vigor: a ISO precisa ser um filho direto canônico de /vm, sem vírgula (ex.: /vm/Win11.iso)."
    info "ENTER deixa a chave vazia e a etapa 12 pedirá o caminho depois."

    if [ -f "$CONF_ARQUIVO" ]; then
        mkdir -p -- "$BACKUPS_DIR" \
            || { erro "Não foi possível criar $BACKUPS_DIR para o backup da migração."; return 1; }
        timestamp="$(date +%Y%m%d-%H%M%S-%N)"
        CONF_MIGRACAO_ISO_BACKUP="$(umask 077; mktemp "$BACKUPS_DIR/passthrough.conf.pre-iso-migracao-${timestamp}.XXXXXX.bak")" \
            || { erro "Não foi possível reservar nome único para o backup da migração."; return 1; }
        if ! cp -- "$CONF_ARQUIVO" "$CONF_MIGRACAO_ISO_BACKUP" \
           || ! chmod 600 -- "$CONF_MIGRACAO_ISO_BACKUP"; then
            rm -f -- "$CONF_MIGRACAO_ISO_BACKUP"
            CONF_MIGRACAO_ISO_BACKUP=""
            erro "Não foi possível criar o backup 0600 antes da migração de ISO."
            return 1
        fi
        info "Backup da configuração antes da migração: $CONF_MIGRACAO_ISO_BACKUP"
    fi

    for indice in "${!pendentes[@]}"; do
        chave="${pendentes[$indice]}"
        perguntar_iso_valor_conf "${descricoes[$indice]}"
        pares+=("$chave" "$CONF_ISO_NOVO_VALOR")
        migradas+=("$chave")
    done

    if ! _conf_publicar_migracao migradas "${pares[@]}"; then
        erro "A migração de ISO não foi publicada; a configuração original continua utilizável."
        [ -z "$CONF_MIGRACAO_ISO_BACKUP" ] \
            || erro "Backup disponível em: $CONF_MIGRACAO_ISO_BACKUP"
        return 1
    fi
    ok "Migração de ISO concluída em um único rename: ${migradas[*]}."
    return 0
}

CONF_ISO_LEGADA_ESTADO_WINDOWS=""
CONF_ISO_LEGADA_ESTADO_VIRTIO=""
CONF_ISO_LEGADA_PENDENTES=0
conf_iso_legada_classificar() {
    # REQ-CONF-ISO: leitura pré-parser das chaves de ISO. Não abre, não resolve,
    # não monta, não copia, não testa existência e não privilegia o caminho
    # legado; ele é tratado como texto e nunca é reaproveitado. Serve para que um
    # valor antigo inválido chegue ao prompt de novo caminho em vez de derrubar a
    # etapa no parser estrito.
    # Retornos: 0=nada a migrar; 1=há chave a substituir; 2=erro de leitura.
    local -a permitidas=(
        CORE_VERSION PROTOCOL_VERSION SUBCOMMAND
        EXISTS NEEDS_MIGRATION SCANNED_KEYS ISO_WINDOWS_STATE ISO_VIRTIO_STATE
    )
    local -a payload=()
    CONF_ISO_LEGADA_ESTADO_WINDOWS=""
    CONF_ISO_LEGADA_ESTADO_VIRTIO=""
    CONF_ISO_LEGADA_PENDENTES=0
    _conf_localizar_alvo || return 2
    [ ! -L "$CONF_ARQUIVO" ] || return 2
    [ -e "$CONF_ARQUIVO" ] || return 0
    payload=(name "$CONF_NOME_ALVO")
    python_core_config permitidas ISOLEG_ config-legacy-scan payload \
        "$CONF_DIRETORIO_ALVO" 2>/dev/null || return 2
    CONF_ISO_LEGADA_ESTADO_WINDOWS="$ISOLEG_ISO_WINDOWS_STATE"
    CONF_ISO_LEGADA_ESTADO_VIRTIO="$ISOLEG_ISO_VIRTIO_STATE"
    CONF_ISO_LEGADA_PENDENTES="$ISOLEG_NEEDS_MIGRATION"
    [ "$CONF_ISO_LEGADA_PENDENTES" = 0 ] || return 1
    return 0
}

backup_e_resetar_config_etapa02() {
    # O conjunto precisa acompanhar toda chave escolhida/calculada pela etapa
    # 02. A limpeza inteira é publicada pelo único rename de salvar_conf_lote.
    local timestamp backup="" conf_existia=0
    local -a chaves=(
        USUARIO_LINUX VM_NAME BOOTLOADER
        GPU_PCI_ID GPU_AUDIO_PCI_ID GPU_VENDOR_DEVICE_ID GPU_AUDIO_VENDOR_DEVICE_ID
        IOMMU_GROUP_GPU DM_SERVICE
        NVME_DEVICE SYSTEM_DISK_FINGERPRINT
        WORKING_DISK_PATH WORKING_DISK_FINGERPRINT WORKING_DISK_DISPENSADO
        HD1_BY_ID_PATH HD1_DISK_FINGERPRINT HD1_DISPENSADO
        CPUS_VM CPUS_HOST VM_VCPUS VM_CORES VM_THREADS VM_RAM_MB HUGEPAGES_1G
        INTERFACE_FISICA REDE_MODO VM_IP_FIXO IP_FIXO_HOST REDE_NAT_CIDR
        TRANSFER_USER AIRLOCK_DIR ISO_WINDOWS ISO_VIRTIO
    )
    local -a pares=()
    local chave
    BACKUP_CONFIG_ETAPA02=""
    if [ -f "$CONF_ARQUIVO" ]; then
        conf_existia=1
        mkdir -p -- "$BACKUPS_DIR" || falhar "Não foi possível criar $BACKUPS_DIR."
        timestamp="$(date +%Y%m%d-%H%M%S-%N)"
        backup="$(umask 077; mktemp "$BACKUPS_DIR/passthrough.conf.pre-redetectar-${timestamp}.XXXXXX.bak")" \
            || falhar "Não foi possível reservar um nome único para o backup pré-redetecção."
        cp -- "$CONF_ARQUIVO" "$backup" \
            || { rm -f -- "$backup"; falhar "Não foi possível criar o backup pré-redetecção."; }
        chmod 600 -- "$backup" \
            || { rm -f -- "$backup"; falhar "Não foi possível restringir o backup pré-redetecção."; }
        BACKUP_CONFIG_ETAPA02="$backup"
    fi
    if [ "$conf_existia" -eq 0 ]; then
        cp -- "$PROJETO_DIR/passthrough.conf.example" "$CONF_ARQUIVO" \
            || falhar "Não foi possível criar o arquivo central a partir do modelo."
        chmod 600 -- "$CONF_ARQUIVO" \
            || falhar "Não foi possível restringir o novo arquivo de configuração."
    fi
    for chave in "${chaves[@]}"; do
        pares+=("$chave" "")
    done
    salvar_conf_lote "${pares[@]}"
}

exigir_conf() {
    # exigir_conf VAR1 VAR2 ... -> aborta se alguma estiver vazia/não definida
    local var faltando=0
    for var in "$@"; do
        if [ -z "${!var:-}" ]; then
            erro "Variável '$var' ausente ou vazia em: $CONF_ARQUIVO"
            faltando=1
        fi
    done
    if [ "$faltando" -eq 1 ]; then
        falhar "Execute antes: etapas/02-detectar-config.sh (ou edite o passthrough.conf)."
    fi
}
