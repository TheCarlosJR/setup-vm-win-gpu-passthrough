#!/bin/bash
# ============================================================================
# lib/platform.sh - núcleo mínimo de plataforma para Ubuntu e Pop!_OS
# ============================================================================
# A fonte de os-release é injetável pelo argumento de plataforma_carregar nos
# testes. Sem argumento, produção consulta somente /etc/os-release. O arquivo
# é sempre tratado como dado: nunca é executado com source/eval.
# ============================================================================

if [ -n "${_PLATAFORMA_LIB_CARREGADA:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
_PLATAFORMA_LIB_CARREGADA=1

# I8.4: o resolver de plataforma passou a ser o core Python, então a ponte
# precisa estar carregada aqui. `lib/common.sh` sourceia esta biblioteca ANTES
# de `lib/python-core.sh`, e `tests/test-ubuntu-audit-regressions.sh` sourceia
# só esta; a ponte não depende de nada de `common.sh` e tem guarda de duplo
# source, então carregá-la aqui é seguro e não muda ordem de ninguém.
# shellcheck source=lib/python-core.sh
source "${BASH_SOURCE[0]%/*}/python-core.sh"

PLATAFORMA_CARREGADA=0
PLATAFORMA_DETECTADA=0
PLATAFORMA_ERRO=""
PLATAFORMA_ID=""
PLATAFORMA_ID_LIKE=""
PLATAFORMA_VARIANT_ID=""
PLATAFORMA_VERSION_ID=""
PLATAFORMA_VERSION_CODENAME=""
PLATAFORMA_PERFIL=""
PLATAFORMA_SUPPORT_LEVEL="blocked"
PLATAFORMA_MUTAVEL=0
PLATAFORMA_IMUTAVEL=0
PLATAFORMA_BLOQUEIO_MOTIVO=""
PLATAFORMA_GERENCIADOR_PACOTES=""
PLATAFORMA_QEMU_PACOTE=""
PLATAFORMA_QEMU_COMANDO=""
PLATAFORMA_NVIDIA_ESTRATEGIA=""
PLATAFORMA_BOOT_BACKENDS=""
PLATAFORMA_INITRAMFS_BACKEND=""
PLATAFORMA_LIBVIRT_SERVICOS=""
PLATAFORMA_VIRTLOGD_SERVICOS=""
PLATAFORMA_QEMU_USUARIOS=""
PLATAFORMA_LIBVIRT_GRUPO=""
PLATAFORMA_KVM_GRUPO=""
PLATAFORMA_SERVICO_RESOLVIDO=""
PLATAFORMA_UNIDADE_RESOLVIDA=""
PLATAFORMA_UNIDADE_ACAO=""
PLATAFORMA_QEMU_USUARIO_PADRAO=""
PLATAFORMA_USUARIO_QEMU=""
PLATAFORMA_QEMU_ORIGEM=""
PLATAFORMA_CPU_VENDOR=""
# I8.7/I8.8: os eixos de fabricante viram FATO exposto, com motivo próprio. Esta
# fase modela; nenhuma delas entra em `guard_mutation` (isso é I14B/I14C) e
# nenhum fabricante é habilitado: Intel segue bloqueada e NVIDIA segue a única
# GPU suportada, byte a byte como antes.
PLATAFORMA_CPU_VENDOR_SUPORTADO=0
PLATAFORMA_CPU_VENDOR_MOTIVO=""
PLATAFORMA_GPU_VENDOR=""
PLATAFORMA_GPU_VENDOR_FAMILIA=""
PLATAFORMA_GPU_VENDOR_SUPORTADO=0
PLATAFORMA_GPU_VENDOR_MOTIVO=""
PLATAFORMA_GPU_IOMMU_GRUPO=""
PLATAFORMA_PACOTES_VIRTUALIZACAO=()
declare -ag PLATAFORMA_CAPABILITIES_CONHECIDAS=(
    inventory.write config.manage host.update gpu.driver packages.base
    storage.prepare virtualization.manage iommu.configure domain.create
    domain.console hooks.configure guest.driver usb.configure cpu.tune
    network.configure airlock.configure trim.configure backup.create
    snapshot.manage gpu.recover diagnostic.write
)
declare -Ag PLATAFORMA_CAPABILITIES=()
declare -Ag PLATAFORMA_CAPABILITY_REASONS=()

_plataforma_trim() {
    local valor="${1:-}"
    valor="${valor#"${valor%%[![:space:]]*}"}"
    valor="${valor%"${valor##*[![:space:]]}"}"
    printf '%s\n' "$valor"
}

_plataforma_resetar_estado() {
    PLATAFORMA_CARREGADA=0
    PLATAFORMA_DETECTADA=0
    PLATAFORMA_ERRO=""
    PLATAFORMA_ID=""
    PLATAFORMA_ID_LIKE=""
    PLATAFORMA_VARIANT_ID=""
    PLATAFORMA_VERSION_ID=""
    PLATAFORMA_VERSION_CODENAME=""
    PLATAFORMA_PERFIL=""
    PLATAFORMA_SUPPORT_LEVEL="blocked"
    PLATAFORMA_MUTAVEL=0
    PLATAFORMA_IMUTAVEL=0
    PLATAFORMA_BLOQUEIO_MOTIVO=""
    PLATAFORMA_GERENCIADOR_PACOTES=""
    PLATAFORMA_QEMU_PACOTE=""
    PLATAFORMA_QEMU_COMANDO=""
    PLATAFORMA_NVIDIA_ESTRATEGIA=""
    PLATAFORMA_BOOT_BACKENDS=""
    PLATAFORMA_INITRAMFS_BACKEND=""
    PLATAFORMA_LIBVIRT_SERVICOS=""
    PLATAFORMA_VIRTLOGD_SERVICOS=""
    PLATAFORMA_QEMU_USUARIOS=""
    PLATAFORMA_LIBVIRT_GRUPO=""
    PLATAFORMA_KVM_GRUPO=""
    PLATAFORMA_SERVICO_RESOLVIDO=""
    PLATAFORMA_UNIDADE_RESOLVIDA=""
    PLATAFORMA_UNIDADE_ACAO=""
    PLATAFORMA_QEMU_USUARIO_PADRAO=""
    PLATAFORMA_USUARIO_QEMU=""
    PLATAFORMA_QEMU_ORIGEM=""
    PLATAFORMA_CPU_VENDOR=""
    PLATAFORMA_PACOTES_VIRTUALIZACAO=()
    PLATAFORMA_CAPABILITIES=()
    PLATAFORMA_CAPABILITY_REASONS=()
}

_plataforma_resolver_estado() {
    # I8.4: um resolver só, no core, para leitura do os-release, imutabilidade e
    # nível de suporte. O Bash continua dono de tudo que toca o host: abre o
    # arquivo, captura a arquitetura e a evidência de ostree, e é o único que
    # conhece o caminho local. Esse caminho é LOCAL_IDENTIFIER (seção 3.9) e por
    # isso NÃO atravessa a ponte: o core devolve código e campo, e a frase é
    # rerenderizada aqui, byte a byte igual à que a etapa publicava antes.
    local arquivo="$1" fonte_explicita="${2:-0}"
    local conteudo="" estado=present arquitetura="" ostree=not-captured marcador=""
    local -a payload=()
    local -a PLAT_PERMITIDAS=(
        CORE_VERSION PROTOCOL_VERSION SUBCOMMAND
        ARCH ARCH_EVIDENCE ARCH_EXPECTED ARCH_STATE BLOCK_REASON
        CAPABILITIES_KNOWN CAPABILITY_REASON ERROR ERROR_CODE ERROR_FIELD
        FIELDS_SEEN ID ID_EVIDENCE ID_LIKE ID_LIKE_COUNT ID_LIKE_EVIDENCE
        ID_LIKE_NORMALIZED ID_LIKE_STATE ID_STATE IMMUTABLE IMMUTABLE_SOURCE
        IMMUTABLE_SOURCE_EVIDENCE IMMUTABLE_SOURCE_STATE MUTABLE PROFILE
        SUPPORT_LEVEL SUPPORT_SOURCE SUPPORT_SOURCE_EVIDENCE
        SUPPORT_SOURCE_STATE VALID VARIANT_ID VARIANT_ID_EVIDENCE
        VARIANT_ID_STATE VERSION_CODENAME VERSION_CODENAME_EVIDENCE
        VERSION_CODENAME_STATE VERSION_ID VERSION_ID_EVIDENCE VERSION_ID_STATE
    )

    if [ -f "$arquivo" ] && [ -r "$arquivo" ]; then
        # `read -d ''` preserva os bytes do arquivo, inclusive a nova linha
        # final que a substituição de comando podaria.
        IFS= read -r -d '' conteudo < "$arquivo" || true
    elif [ -e "$arquivo" ] || [ -L "$arquivo" ]; then
        estado=unreadable
    else
        estado=absent
    fi

    # Arquitetura é snapshot do Bash, nunca suposição do arquivo. Ausente vira
    # fato tipado `ausente` no core, e não default silencioso.
    if command -v uname >/dev/null 2>&1; then
        arquitetura="$(uname -m 2>/dev/null || true)"
    fi

    # Mesma regra de antes: com os-release injetado, só VARIANT_ID é
    # autoritativo; em produção, /run/ostree-booted é a segunda evidência.
    if [ "$fonte_explicita" -eq 0 ]; then
        if declare -F caminho_sistema >/dev/null 2>&1; then
            marcador="$(caminho_sistema /run/ostree-booted)" || {
                PLATAFORMA_ERRO="Não foi possível resolver a evidência de implantação ostree."
                return 1
            }
        else
            marcador=/run/ostree-booted
        fi
        if [ -e "$marcador" ] || [ -L "$marcador" ]; then
            ostree=present
        else
            ostree=absent
        fi
    fi

    payload=(
        text "$conteudo"
        text_state "$estado"
        arch "$arquitetura"
        ostree_evidence "$ostree"
    )
    if ! python_core_pares_payload PLAT_PERMITIDAS PLAT_ platform-detect payload; then
        PLATAFORMA_ERRO="${PYTHON_CORE_ERRO:-Não foi possível resolver a plataforma pelo core.}"
        return 1
    fi

    if [ "${PLAT_VALID:-0}" != 1 ]; then
        # O ramo `*` é fail-closed de propósito: código novo do core sem
        # tradução aqui reprova, em vez de virar mensagem vazia.
        case "${PLAT_ERROR_CODE:-}" in
            os_release_missing) PLATAFORMA_ERRO="os-release ausente ou ilegível: $arquivo" ;;
            duplicate_key)      PLATAFORMA_ERRO="Chave $PLAT_ERROR_FIELD repetida em $arquivo." ;;
            invalid_value)      PLATAFORMA_ERRO="Valor inválido para $PLAT_ERROR_FIELD em $arquivo." ;;
            invalid_id)         PLATAFORMA_ERRO="ID ausente ou inválido em $arquivo." ;;
            invalid_field)      PLATAFORMA_ERRO="$PLAT_ERROR_FIELD inválido em $arquivo." ;;
            *)                  PLATAFORMA_ERRO="Falha ao interpretar $arquivo (código ${PLAT_ERROR_CODE:-desconhecido})." ;;
        esac
        return 1
    fi

    # Publicação um para um, e SÓ com leitura válida: era isso que o parser
    # antigo fazia ao atribuir as globais depois de todas as validações.
    PLATAFORMA_DETECTADA=1
    PLATAFORMA_ID="$PLAT_ID"
    PLATAFORMA_ID_LIKE="$PLAT_ID_LIKE"
    PLATAFORMA_VARIANT_ID="$PLAT_VARIANT_ID"
    PLATAFORMA_VERSION_ID="$PLAT_VERSION_ID"
    PLATAFORMA_VERSION_CODENAME="$PLAT_VERSION_CODENAME"
    PLATAFORMA_IMUTAVEL="$PLAT_IMMUTABLE"
    PLATAFORMA_SUPPORT_LEVEL="$PLAT_SUPPORT_LEVEL"
    PLATAFORMA_MUTAVEL="$PLAT_MUTABLE"
    PLATAFORMA_BLOQUEIO_MOTIVO="$PLAT_BLOCK_REASON"
    PLATAFORMA_PERFIL="$PLAT_PROFILE"
    return 0
}

_plataforma_inicializar_capabilities() {
    local capability
    for capability in "${PLATAFORMA_CAPABILITIES_CONHECIDAS[@]}"; do
        PLATAFORMA_CAPABILITIES[$capability]=0
        PLATAFORMA_CAPABILITY_REASONS[$capability]="$PLATAFORMA_BLOQUEIO_MOTIVO"
    done
}

_plataforma_habilitar_capabilities_perfil() {
    local capability
    for capability in "${PLATAFORMA_CAPABILITIES_CONHECIDAS[@]}"; do
        PLATAFORMA_CAPABILITIES[$capability]=1
        PLATAFORMA_CAPABILITY_REASONS[$capability]="Capability habilitada pelo perfil exato $PLATAFORMA_PERFIL."
    done
}

plataforma_carregar() {
    # O caminho opcional é uma dependência explícita para testes unitários. Os
    # entrypoints usam /etc, salvo no modo hermético validado por common.sh.
    local arquivo="${1:-}" fonte_explicita=0
    if [ -n "$arquivo" ]; then
        fonte_explicita=1
    elif declare -F caminho_sistema >/dev/null 2>&1; then
        arquivo="$(caminho_sistema /etc/os-release)" || return 1
    else
        arquivo=/etc/os-release
    fi
    _plataforma_resetar_estado
    _plataforma_resolver_estado "$arquivo" "$fonte_explicita" || return 1
    _plataforma_inicializar_capabilities

    if [ "$PLATAFORMA_SUPPORT_LEVEL" != supported ]; then
        PLATAFORMA_ERRO="Mutação indisponível no nível $PLATAFORMA_SUPPORT_LEVEL: $PLATAFORMA_BLOQUEIO_MOTIVO"
        return 1
    fi

    # Defaults são atributos de um perfil exato aceito, nunca evidência de
    # suporte. Nenhuma capability é inferida pela presença de comandos.
    PLATAFORMA_GERENCIADOR_PACOTES=apt
    PLATAFORMA_QEMU_COMANDO=qemu-system-x86_64
    PLATAFORMA_INITRAMFS_BACKEND=update-initramfs
    PLATAFORMA_LIBVIRT_SERVICOS="libvirtd virtqemud"
    PLATAFORMA_VIRTLOGD_SERVICOS="virtlogd"
    PLATAFORMA_QEMU_USUARIOS="libvirt-qemu qemu"
    PLATAFORMA_LIBVIRT_GRUPO=libvirt
    PLATAFORMA_KVM_GRUPO=kvm
    # I8.4: o NOME do perfil é resolução (vem do core); os atributos abaixo são
    # provider, e provider é Bash. Antes as duas coisas eram decididas no mesmo
    # `case`, o que duplicaria a classificação depois do cutover.
    case "$PLATAFORMA_PERFIL" in
        ubuntu)
            PLATAFORMA_QEMU_PACOTE=qemu-system-x86
            PLATAFORMA_QEMU_USUARIO_PADRAO=libvirt-qemu
            PLATAFORMA_NVIDIA_ESTRATEGIA=ubuntu-drivers
            PLATAFORMA_BOOT_BACKENDS=grub
            ;;
        pop-os)
            PLATAFORMA_QEMU_PACOTE=qemu-kvm
            PLATAFORMA_QEMU_USUARIO_PADRAO=libvirt-qemu
            PLATAFORMA_NVIDIA_ESTRATEGIA=system76
            PLATAFORMA_BOOT_BACKENDS="kernelstub grub"
            ;;
        *)
            PLATAFORMA_ERRO="Falha interna: support level habilitou um perfil sem provider exato (ID=$PLATAFORMA_ID)."
            PLATAFORMA_SUPPORT_LEVEL=blocked
            PLATAFORMA_MUTAVEL=0
            PLATAFORMA_BLOQUEIO_MOTIVO="$PLATAFORMA_ERRO"
            _plataforma_inicializar_capabilities
            return 1
            ;;
    esac
    PLATAFORMA_PACOTES_VIRTUALIZACAO=(
        "$PLATAFORMA_QEMU_PACOTE" qemu-utils libvirt-daemon-system
        libvirt-clients bridge-utils virt-manager ovmf swtpm swtpm-tools virtinst
    )
    _plataforma_habilitar_capabilities_perfil
    PLATAFORMA_CARREGADA=1
    return 0
}

# I8.8: `nvidia.driver` virou ALIAS de `gpu.driver`. O array de conhecidas
# continua com 21 entradas (o alias não infla a contagem que os testes de I1
# conferem) e todo consumidor antigo continua aceito durante o cutover; a
# remoção do alias é I10.
declare -Ag PLATAFORMA_CAPABILITY_ALIASES=(
    [nvidia.driver]=gpu.driver
)

platform_capability_known() {
    local procurada="${1:-}" capability
    [ -n "$procurada" ] || return 1
    procurada="${PLATAFORMA_CAPABILITY_ALIASES[$procurada]:-$procurada}"
    for capability in "${PLATAFORMA_CAPABILITIES_CONHECIDAS[@]}"; do
        [ "$capability" = "$procurada" ] && return 0
    done
    return 1
}

platform_has_capability() {
    local capability="${1:-}"
    capability="${PLATAFORMA_CAPABILITY_ALIASES[$capability]:-$capability}"
    platform_capability_known "$capability" || return 1
    if [ "$PLATAFORMA_DETECTADA" -ne 1 ]; then
        plataforma_carregar || [ "$PLATAFORMA_DETECTADA" -eq 1 ] || return 1
    fi
    [ "${PLATAFORMA_CAPABILITIES[$capability]:-0}" -eq 1 ]
}

platform_capability_reason() {
    local capability="${1:-}"
    capability="${PLATAFORMA_CAPABILITY_ALIASES[$capability]:-$capability}"
    if ! platform_capability_known "$capability"; then
        printf 'Capability desconhecida: %s.\n' "${capability:-vazia}"
        return 1
    fi
    if [ "$PLATAFORMA_DETECTADA" -ne 1 ]; then
        if ! plataforma_carregar && [ "$PLATAFORMA_DETECTADA" -ne 1 ]; then
            printf '%s\n' "$PLATAFORMA_ERRO"
            return 1
        fi
    fi
    printf '%s\n' "${PLATAFORMA_CAPABILITY_REASONS[$capability]:-$PLATAFORMA_BLOQUEIO_MOTIVO}"
}

platform_require_capability() {
    local capability="${1:-}"
    capability="${PLATAFORMA_CAPABILITY_ALIASES[$capability]:-$capability}"
    if ! platform_capability_known "$capability"; then
        PLATAFORMA_ERRO="Capability desconhecida: ${capability:-vazia}."
        return 1
    fi
    if [ "$PLATAFORMA_DETECTADA" -ne 1 ]; then
        if ! plataforma_carregar && [ "$PLATAFORMA_DETECTADA" -ne 1 ]; then
            return 1
        fi
    fi
    if [ "${PLATAFORMA_CAPABILITIES[$capability]:-0}" -ne 1 ]; then
        PLATAFORMA_ERRO="${PLATAFORMA_CAPABILITY_REASONS[$capability]:-$PLATAFORMA_BLOQUEIO_MOTIVO}"
        return 1
    fi
    return 0
}

plataforma_exigir_suportada() {
    plataforma_carregar \
        || { printf '[erro] %s\n' "$PLATAFORMA_ERRO" >&2; return 1; }
}

plataforma_pacotes_virtualizacao() {
    [ "$PLATAFORMA_CARREGADA" -eq 1 ] || plataforma_carregar || return 1
    printf '%s\n' "${PLATAFORMA_PACOTES_VIRTUALIZACAO[@]}"
}

plataforma_boot_backend_suportado() {
    local pedido="${1:-}" backend
    [ "$PLATAFORMA_CARREGADA" -eq 1 ] || plataforma_carregar || return 1
    for backend in $PLATAFORMA_BOOT_BACKENDS; do
        [ "$backend" = "$pedido" ] && return 0
    done
    return 1
}

plataforma_atualizar_initramfs() {
    [ "$PLATAFORMA_CARREGADA" -eq 1 ] || plataforma_carregar || return 1
    case "$PLATAFORMA_INITRAMFS_BACKEND" in
        update-initramfs) sudo update-initramfs -u -k all ;;
        *) PLATAFORMA_ERRO="Backend de initramfs não suportado: $PLATAFORMA_INITRAMFS_BACKEND"; return 1 ;;
    esac
}

_PLATAFORMA_UNIDADE_CARGA=""
_PLATAFORMA_UNIDADE_ATIVA=""
_PLATAFORMA_UNIDADE_SUB=""
_PLATAFORMA_UNIDADE_ARQUIVO=""

_plataforma_sondar_unidade() {
    # SONDA, e só sonda: é ela que toca o host, então continua no Bash. A
    # interpretação dos quatro valores foi para o core em I8.6.
    #
    # A consulta pede exatamente LoadState, ActiveState, SubState e
    # UnitFileState. O shim de `systemctl show` do harness I0 recusa qualquer
    # outra propriedade como comando proibido: acrescentar uma aqui reprova a
    # campanha inteira, mesmo que o systemd real respondesse.
    local unidade="$1" saida linha chave valor
    local viu_carga=0 viu_ativa=0
    _PLATAFORMA_UNIDADE_CARGA=""
    _PLATAFORMA_UNIDADE_ATIVA=""
    _PLATAFORMA_UNIDADE_SUB=""
    _PLATAFORMA_UNIDADE_ARQUIVO=""
    command -v systemctl >/dev/null 2>&1 \
        || { PLATAFORMA_ERRO="systemctl indisponível para sondar $unidade."; return 2; }
    saida="$(systemctl show "$unidade" --property=LoadState --property=ActiveState \
        --property=SubState --property=UnitFileState --no-pager 2>&1)" \
        || { PLATAFORMA_ERRO="Falha operacional ao consultar $unidade: ${saida:-sem diagnóstico}."; return 2; }
    while IFS= read -r linha || [ -n "$linha" ]; do
        [[ "$linha" == *=* ]] || continue
        chave="${linha%%=*}"
        valor="${linha#*=}"
        case "$chave" in
            LoadState) _PLATAFORMA_UNIDADE_CARGA="$valor"; viu_carga=$((viu_carga + 1)) ;;
            ActiveState) _PLATAFORMA_UNIDADE_ATIVA="$valor"; viu_ativa=$((viu_ativa + 1)) ;;
            SubState) _PLATAFORMA_UNIDADE_SUB="$valor" ;;
            UnitFileState) _PLATAFORMA_UNIDADE_ARQUIVO="$valor" ;;
        esac
    done <<< "$saida"
    [ "$viu_carga" -eq 1 ] && [ "$viu_ativa" -eq 1 ] \
        || { PLATAFORMA_ERRO="Resposta systemd incompleta para $unidade."; return 2; }
}

plataforma_resolver_servico() {
    # Contrato público: 0 resolve; 1 indica unidade ainda ausente; 2 indica
    # configuração inválida ou falha operacional da sondagem. A fixture
    # opcional é autoritativa e nunca cai no systemd do host.
    #
    # I8.6 (REQ-LIBVIRT-BACKEND): a CLASSIFICAÇÃO das unidades e o DESEMPATE
    # entre elas são do core (`platform-service-resolve`), num lugar só, para
    # que `libvirt_backend_resolver` (etapa 50) e as etapas 20 e 21 consumam a
    # MESMA decisão e nenhuma possa reimplementá-la. Aqui ficam só as coisas
    # que tocam o host ou pertencem à fachada: a lista de candidatos do perfil,
    # a leitura da fixture, a sonda `systemctl show` e a renderização das
    # frases, que carregam o caminho da fixture e o nome do tipo
    # (LOCAL_IDENTIFIER e prosa, seção 3.9).
    local tipo="${1:-libvirt}" fixture="${2:-}" candidatos base unidade
    local conteudo="" ordem="" registros="" origem=probe
    local -a payload=()
    local -a PLAT_SVC_PERMITIDAS=(
        CORE_VERSION PROTOCOL_VERSION SUBCOMMAND
        ERROR ERROR_CODE ERROR_FIELD RESOLVED_ACTION RESOLVED_SCORE
        RESOLVED_SERVICE RESOLVED_UNIT RESOLVED_UNIT_EVIDENCE
        RESOLVED_UNIT_STATE SERVICE_SOURCE UNIT_COUNT VALID
    )
    if [ "$PLATAFORMA_CARREGADA" -ne 1 ]; then
        plataforma_carregar || return 2
    fi
    PLATAFORMA_ERRO=""
    PLATAFORMA_SERVICO_RESOLVIDO=""
    PLATAFORMA_UNIDADE_RESOLVIDA=""
    PLATAFORMA_UNIDADE_ACAO=""
    case "$tipo" in
        libvirt) candidatos="$PLATAFORMA_LIBVIRT_SERVICOS" ;;
        virtlogd) candidatos="$PLATAFORMA_VIRTLOGD_SERVICOS" ;;
        *) PLATAFORMA_ERRO="Tipo de serviço desconhecido: $tipo"; return 2 ;;
    esac
    if [ -n "$fixture" ]; then
        if [ ! -r "$fixture" ] || [ ! -f "$fixture" ]; then
            PLATAFORMA_ERRO="Fixture de serviços ausente ou ilegível: $fixture."
            return 2
        fi
        origem=fixture
        # `read -d ''` preserva os bytes do arquivo, inclusive a nova linha
        # final que a substituição de comando podaria.
        IFS= read -r -d '' conteudo < "$fixture" || true
    fi
    # A expansão em .socket e .service decide O QUE perguntar ao host, então é
    # do Bash. A ordem produzida aqui é a ordem de desempate do core.
    for base in $candidatos; do
        for unidade in "${base}.socket" "${base}.service"; do
            ordem+="${ordem:+$'\n'}$unidade"
            [ "$origem" = probe ] || continue
            _plataforma_sondar_unidade "$unidade" || return $?
            registros+="${registros:+$'\n'}${unidade}"$'\t'
            registros+="${_PLATAFORMA_UNIDADE_CARGA}"$'\t'
            registros+="${_PLATAFORMA_UNIDADE_ATIVA}"$'\t'
            registros+="${_PLATAFORMA_UNIDADE_SUB}"$'\t'
            registros+="${_PLATAFORMA_UNIDADE_ARQUIVO}"
        done
    done
    payload=(
        service_source "$origem"
        unit_order "$ordem"
        fixture_text "$conteudo"
        unit_states "$registros"
    )
    if ! python_core_pares_payload PLAT_SVC_PERMITIDAS PLAT_SVC_ platform-service-resolve payload; then
        PLATAFORMA_ERRO="${PYTHON_CORE_ERRO:-Não foi possível resolver a unidade systemd pelo core.}"
        return 2
    fi
    if [ "${PLAT_SVC_VALID:-0}" != 1 ]; then
        # O ramo `*` é fail-closed de propósito: código novo do core sem
        # tradução aqui reprova, em vez de virar mensagem vazia.
        case "${PLAT_SVC_ERROR_CODE:-}" in
            fixture_malformed)
                PLATAFORMA_ERRO="Fixture systemd malformada: $PLAT_SVC_ERROR_FIELD"
                return 2 ;;
            fixture_duplicate)
                PLATAFORMA_ERRO="Unidade $PLAT_SVC_ERROR_FIELD repetida na fixture."
                return 2 ;;
            no_unit)
                PLATAFORMA_ERRO="Nenhuma unidade $tipo ativa ou iniciável entre os backends do perfil: $candidatos."
                return 1 ;;
            *)
                PLATAFORMA_ERRO="Falha ao resolver a unidade $tipo (código ${PLAT_SVC_ERROR_CODE:-desconhecido})."
                return 2 ;;
        esac
    fi
    # Publicação um para um, e SÓ com decisão válida.
    PLATAFORMA_UNIDADE_RESOLVIDA="$PLAT_SVC_RESOLVED_UNIT"
    PLATAFORMA_SERVICO_RESOLVIDO="$PLAT_SVC_RESOLVED_SERVICE"
    PLATAFORMA_UNIDADE_ACAO="$PLAT_SVC_RESOLVED_ACTION"
}

_plataforma_usuario_nss_unico() {
    local usuario="$1" saida rc registro nome senha uid gid gecos home shell extra
    local -a registros=()
    command -v getent >/dev/null 2>&1 \
        || { PLATAFORMA_ERRO="getent indisponível para consultar a identidade QEMU '$usuario'."; return 2; }
    if saida="$(getent passwd "$usuario" 2>/dev/null)"; then
        rc=0
    else
        rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 2 ] && [ -z "$saida" ]; then
            PLATAFORMA_ERRO="Identidade QEMU '$usuario' ainda não possui entrada NSS."
            return 1
        fi
        PLATAFORMA_ERRO="Falha operacional do NSS ao consultar a identidade QEMU '$usuario' (código $rc)."
        return 2
    fi
    if [ -z "$saida" ]; then
        PLATAFORMA_ERRO="Identidade QEMU '$usuario' ainda não possui entrada NSS."
        return 1
    fi
    mapfile -t registros <<< "$saida"
    [ "${#registros[@]}" -eq 1 ] \
        || { PLATAFORMA_ERRO="Identidade QEMU '$usuario' possui mais de uma entrada NSS."; return 2; }
    registro="${registros[0]}"
    IFS=: read -r nome senha uid gid gecos home shell extra <<< "$registro"
    if [ "$nome" != "$usuario" ] || [ -n "$extra" ] \
       || [[ ! "$uid" =~ ^[0-9]+$ ]] || [[ ! "$gid" =~ ^[0-9]+$ ]]; then
        PLATAFORMA_ERRO="Entrada NSS da identidade QEMU '$usuario' é inconsistente."
        return 2
    fi
}

_plataforma_usuario_qemu_permitido() {
    local pedido="$1" candidato
    for candidato in $PLATAFORMA_QEMU_USUARIOS; do
        [ "$pedido" = "$candidato" ] && return 0
    done
    return 1
}

_plataforma_ler_usuario_qemu_conf() {
    # Retornos: 0 resolve a diretiva user; 1 indica arquivo ausente ou sem
    # diretiva ativa; 2 indica qemu.conf inválido (link, diretório, leitura
    # quebrada); 3 indica arquivo regular que só o root pode ler, que é o modo
    # 0600 padrão do pacote, sem ticket sudo disponível para lê-lo.
    local arquivo="$1" linha conteudo valor usuario="" encontrados=0 texto
    PLATAFORMA_USUARIO_QEMU=""
    [ ! -L "$arquivo" ] \
        || { PLATAFORMA_ERRO="qemu.conf deve ser arquivo regular legível, não link: $arquivo"; return 2; }
    [ -e "$arquivo" ] || return 1
    [ -f "$arquivo" ] \
        || { PLATAFORMA_ERRO="qemu.conf deve ser arquivo regular legível, não link: $arquivo"; return 2; }
    if [ -r "$arquivo" ]; then
        texto="$(cat -- "$arquivo")" \
            || { PLATAFORMA_ERRO="qemu.conf deve ser arquivo regular legível, não link: $arquivo"; return 2; }
    elif texto="$(sudo -n cat -- "$arquivo" 2>/dev/null)"; then
        :
    else
        PLATAFORMA_ERRO="qemu.conf é regular, mas legível apenas pelo root (modo padrão do pacote): $arquivo."
        return 3
    fi
    while IFS= read -r linha || [ -n "$linha" ]; do
        linha="${linha%$'\r'}"
        conteudo="$(_plataforma_trim "$linha")"
        [ -n "$conteudo" ] && [[ "$conteudo" != \#* ]] || continue
        [[ "$conteudo" =~ ^user[[:space:]]*= ]] || continue
        valor="${conteudo#*=}"
        valor="$(_plataforma_trim "$valor")"
        valor="${valor%%#*}"
        valor="$(_plataforma_trim "$valor")"
        if [[ "$valor" == \"*\" ]] && [ "${#valor}" -ge 2 ]; then
            valor="${valor:1:${#valor}-2}"
        elif [[ "$valor" == \'*\' ]] && [ "${#valor}" -ge 2 ]; then
            valor="${valor:1:${#valor}-2}"
        fi
        [[ "$valor" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
            || { PLATAFORMA_ERRO="Valor user inválido em $arquivo."; return 2; }
        encontrados=$((encontrados + 1))
        [ "$encontrados" -eq 1 ] \
            || { PLATAFORMA_ERRO="Mais de uma diretiva user ativa em $arquivo; identidade QEMU ambígua."; return 2; }
        usuario="$valor"
    done <<< "$texto"
    [ "$encontrados" -eq 1 ] || return 1
    PLATAFORMA_USUARIO_QEMU="$usuario"
}

_plataforma_usuario_qemu_runtime() {
    # Identidade QEMU efetiva observável sem privilégio: o libvirt cria e
    # transfere o diretório de estado do QEMU para o usuário realmente
    # configurado, e os diretórios pais são atravessáveis por qualquer conta.
    # Ecoa a identidade só quando ela é plausível e permitida pelo perfil.
    local diretorio dono
    if declare -F caminho_sistema >/dev/null 2>&1; then
        diretorio="$(caminho_sistema /var/lib/libvirt/qemu)" || return 1
    else
        diretorio=/var/lib/libvirt/qemu
    fi
    [ -d "$diretorio" ] && [ ! -L "$diretorio" ] || return 1
    command -v stat >/dev/null 2>&1 || return 1
    dono="$(stat -c %U -- "$diretorio" 2>/dev/null)" || return 1
    [[ "$dono" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1
    _plataforma_usuario_qemu_permitido "$dono" || return 1
    printf '%s\n' "$dono"
}

plataforma_resolver_usuario_qemu() {
    # Contrato público: 0 resolve; 1 indica conta NSS ainda ausente; 2 indica
    # qemu.conf/perfil/NSS inválido ou falha operacional. A ausência da
    # diretiva usa o padrão determinístico do perfil.
    # PLATAFORMA_QEMU_ORIGEM registra de onde veio a identidade resolvida:
    # 'qemu.conf' quando a diretiva foi lida, 'padrao' quando não há diretiva
    # ativa e 'presumido' quando qemu.conf existe restrito ao root e a
    # identidade foi inferida sem privilégio. Só 'presumido' precisa de
    # reconfirmação com sudo antes de qualquer mutação.
    local arquivo="${1:-}" usuario rc
    if [ "$PLATAFORMA_CARREGADA" -ne 1 ]; then
        plataforma_carregar || return 2
    fi
    PLATAFORMA_ERRO=""
    PLATAFORMA_USUARIO_QEMU=""
    PLATAFORMA_QEMU_ORIGEM=""
    if [ -z "$arquivo" ]; then
        if declare -F caminho_sistema >/dev/null 2>&1; then
            arquivo="$(caminho_sistema /etc/libvirt/qemu.conf)" || {
                PLATAFORMA_ERRO="Não foi possível resolver o caminho de qemu.conf."
                return 2
            }
        else
            arquivo=/etc/libvirt/qemu.conf
        fi
    fi
    if _plataforma_ler_usuario_qemu_conf "$arquivo"; then
        usuario="$PLATAFORMA_USUARIO_QEMU"
        PLATAFORMA_USUARIO_QEMU=""
        PLATAFORMA_QEMU_ORIGEM=qemu.conf
    else
        rc=$?
        PLATAFORMA_USUARIO_QEMU=""
        usuario=""
        case "$rc" in
            1) PLATAFORMA_QEMU_ORIGEM=padrao ;;
            2) return 2 ;;
            3)
                # qemu.conf existe, é regular e está fechado ao root: nenhuma
                # etapa roda como root e nem toda verificação tem sudo. A
                # identidade efetiva ainda é observável pelo dono do estado do
                # QEMU; sem esse sinal cai no padrão determinístico do perfil.
                PLATAFORMA_QEMU_ORIGEM=presumido
                PLATAFORMA_ERRO=""
                usuario="$(_plataforma_usuario_qemu_runtime)" || usuario=""
                ;;
            *) PLATAFORMA_ERRO="Falha interna ao interpretar qemu.conf (código $rc)."; return 2 ;;
        esac
        if [ -z "$usuario" ]; then
            usuario="$PLATAFORMA_QEMU_USUARIO_PADRAO"
            [ -n "$usuario" ] \
                || { PLATAFORMA_ERRO="Perfil sem identidade QEMU padrão e sem user explícito em qemu.conf."; return 2; }
        fi
    fi
    _plataforma_usuario_qemu_permitido "$usuario" \
        || { PLATAFORMA_ERRO="Identidade QEMU '$usuario' não pertence ao conjunto permitido do perfil: $PLATAFORMA_QEMU_USUARIOS."; return 2; }
    if _plataforma_usuario_nss_unico "$usuario"; then
        :
    else
        rc=$?
        return "$rc"
    fi
    PLATAFORMA_USUARIO_QEMU="$usuario"
}

plataforma_detectar_cpu_vendor() {
    # I8.7: a SONDA continua aqui (é ela que toca o host); a interpretação foi
    # para o core, que modela o vendor como fato tipado com origem da evidência.
    # O argumento opcional injeta somente o resultado da sonda em testes que
    # chamam esta função diretamente; entrypoints operacionais não o repassam.
    #
    # A segunda fonte do eixo (`/proc/cpuinfo`) é aceita pelo core e coberta
    # pelas fixtures dele, mas a fachada ainda captura só `lscpu`, que é o que a
    # implementação atual sonda. Capturar as duas aqui mudaria comportamento
    # nesta fase: os harnesses de teste substituem o COMANDO por PATH e não têm
    # como redirecionar o ARQUIVO, então um host com `lscpu` encenado e
    # `/proc/cpuinfo` real viraria "evidência conflitante" onde hoje há decisão
    # limpa. Ligar a segunda fonte é I14B, junto com o host Intel real.
    local vendor="${1:-}" texto="" estado=absent
    local -a payload=()
    local -a PLAT_CPU_PERMITIDAS=(
        CORE_VERSION PROTOCOL_VERSION SUBCOMMAND
        CPUINFO_CAPTURE CPUINFO_DISTINCT CPUINFO_VENDOR CPU_VENDOR
        CPU_VENDOR_EVIDENCE CPU_VENDOR_FAMILY CPU_VENDOR_STATE
        CPU_VENDOR_SUPPORTED ERROR ERROR_CODE LSCPU_CAPTURE LSCPU_DISTINCT
        LSCPU_VENDOR VALID
    )
    PLATAFORMA_CPU_VENDOR=""
    PLATAFORMA_CPU_VENDOR_SUPORTADO=0
    PLATAFORMA_CPU_VENDOR_MOTIVO=""
    PLATAFORMA_ERRO=""
    if [ -n "$vendor" ]; then
        texto="Vendor ID: $vendor"
        estado=present
    elif ! command -v lscpu >/dev/null 2>&1; then
        estado=unavailable
    elif texto="$(LC_ALL=C lscpu 2>/dev/null)"; then
        estado=present
    else
        texto=""
        estado=error
    fi
    payload=(
        cpuinfo_text "" cpuinfo_state absent
        lscpu_text "$texto" lscpu_state "$estado"
    )
    if ! python_core_pares_payload PLAT_CPU_PERMITIDAS PLAT_ platform-cpu-vendor payload; then
        PLATAFORMA_ERRO="${PYTHON_CORE_ERRO:-Não foi possível identificar o fabricante da CPU pelo core.}"
        return 1
    fi
    if [ "${PLAT_VALID:-0}" != 1 ]; then
        PLATAFORMA_ERRO="$PLAT_ERROR"
        return 1
    fi
    PLATAFORMA_CPU_VENDOR="$PLAT_CPU_VENDOR"
    PLATAFORMA_CPU_VENDOR_SUPORTADO="$PLAT_CPU_VENDOR_SUPPORTED"
    # Motivo próprio do eixo: vendor detectado e não suportado é fato, não erro
    # de detecção. Quem transforma isso em recusa é `plataforma_validar_cpu_amd`.
    PLATAFORMA_CPU_VENDOR_MOTIVO="$PLAT_ERROR"
}


plataforma_validar_cpu_amd() {
    # O argumento opcional é encaminhado apenas por testes unitários diretos.
    plataforma_detectar_cpu_vendor "${1:-}" || return 1
    [ "$PLATAFORMA_CPU_VENDOR_SUPORTADO" = 1 ] || {
        PLATAFORMA_ERRO="$PLATAFORMA_CPU_VENDOR_MOTIVO"
        return 1
    }
}

plataforma_detectar_gpu_vendor() {
    # I8.8: o eixo de fabricante de GPU não existia; era propriedade implícita
    # espalhada por dezenas de pontos. Aqui ele nasce como FATO exposto, com
    # motivo próprio, sem entrar em `guard_mutation` e sem habilitar fabricante
    # nenhum: só NVIDIA continua suportada, exatamente como antes.
    #
    # $1 = BDF já escolhido (opcional). $2 e $3 injetam as capturas de `lspci` e
    # dos grupos IOMMU, e existem só para teste direto; produção sonda o host.
    local bdf="${1:-}" pci="${2:-}" grupos="${3:-}"
    local pci_estado=present grupos_estado=present base grupo dispositivo
    local -a payload=()
    local -a PLAT_GPU_PERMITIDAS=(
        CORE_VERSION PROTOCOL_VERSION SUBCOMMAND
        ERROR ERROR_CODE GPU_COUNT GPU_VENDOR GPU_VENDOR_COUNT
        GPU_VENDOR_EVIDENCE GPU_VENDOR_FAMILY GPU_VENDOR_LABEL GPU_VENDOR_STATE
        GPU_VENDOR_SUPPORTED IOMMU_CAPTURE IOMMU_GROUP PCI_CAPTURE VALID
    )
    PLATAFORMA_GPU_VENDOR=""
    PLATAFORMA_GPU_VENDOR_FAMILIA=""
    PLATAFORMA_GPU_VENDOR_SUPORTADO=0
    PLATAFORMA_GPU_VENDOR_MOTIVO=""
    PLATAFORMA_GPU_IOMMU_GRUPO=""
    PLATAFORMA_ERRO=""
    if [ -z "$pci" ]; then
        if ! command -v lspci >/dev/null 2>&1; then
            pci_estado=unavailable
        elif pci="$(LC_ALL=C lspci -Dnn 2>/dev/null)"; then
            pci_estado=present
        else
            pci=""
            pci_estado=error
        fi
    fi
    if [ -z "$grupos" ]; then
        if declare -F caminho_sistema >/dev/null 2>&1; then
            base="$(caminho_sistema /sys/kernel/iommu_groups)" || base=""
        else
            base=/sys/kernel/iommu_groups
        fi
        if [ -n "$base" ] && [ -d "$base" ]; then
            for grupo in "$base"/*; do
                [ -d "$grupo/devices" ] || continue
                for dispositivo in "$grupo/devices"/*; do
                    [ -e "$dispositivo" ] || continue
                    grupos+="${grupos:+$'\n'}${grupo##*/} ${dispositivo##*/}"
                done
            done
        else
            grupos_estado=absent
        fi
    fi
    payload=(
        pci_text "$pci" pci_state "$pci_estado"
        iommu_text "$grupos" iommu_state "$grupos_estado"
        bdf "$bdf"
    )
    if ! python_core_pares_payload PLAT_GPU_PERMITIDAS PLAT_ platform-gpu-vendor payload; then
        PLATAFORMA_ERRO="${PYTHON_CORE_ERRO:-Não foi possível identificar o fabricante da GPU pelo core.}"
        return 1
    fi
    PLATAFORMA_GPU_VENDOR="$PLAT_GPU_VENDOR"
    PLATAFORMA_GPU_VENDOR_FAMILIA="$PLAT_GPU_VENDOR_FAMILY"
    PLATAFORMA_GPU_VENDOR_SUPORTADO="$PLAT_GPU_VENDOR_SUPPORTED"
    PLATAFORMA_GPU_VENDOR_MOTIVO="$PLAT_ERROR"
    PLATAFORMA_GPU_IOMMU_GRUPO="$PLAT_IOMMU_GROUP"
    [ "${PLAT_VALID:-0}" = 1 ] || { PLATAFORMA_ERRO="$PLAT_ERROR"; return 1; }
}
