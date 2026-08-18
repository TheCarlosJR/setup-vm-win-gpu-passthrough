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
declare -ag PLATAFORMA_CAPABILITIES_CONHECIDAS=(
    inventory.write config.manage host.update nvidia.driver packages.base
    storage.prepare virtualization.manage iommu.configure domain.create
    domain.console hooks.configure usb.configure cpu.tune network.configure
    airlock.configure trim.configure backup.create snapshot.manage gpu.recover
    diagnostic.write
)
declare -Ag PLATAFORMA_CAPABILITIES=()
declare -Ag PLATAFORMA_CAPABILITY_REASONS=()

_plataforma_trim() {
    local valor="${1:-}"
    valor="${valor#"${valor%%[![:space:]]*}"}"
    valor="${valor%"${valor##*[![:space:]]}"}"
    printf '%s\n' "$valor"
}

_plataforma_decodificar_valor() {
    local valor
    valor="$(_plataforma_trim "${1:-}")"
    if [[ "$valor" == \"*\" ]] && [ "${#valor}" -ge 2 ]; then
        valor="${valor:1:${#valor}-2}"
        valor="${valor//\\\"/\"}"
        valor="${valor//\\\\/\\}"
    elif [[ "$valor" == \'*\' ]] && [ "${#valor}" -ge 2 ]; then
        valor="${valor:1:${#valor}-2}"
    fi
    [[ "$valor" != *$'\n'* && "$valor" != *$'\r'* ]] || return 1
    printf '%s\n' "$valor"
}

_plataforma_ler_os_release() {
    local arquivo="$1" linha chave bruto valor
    local id="" id_like="" variant_id="" version_id="" codename=""
    local -A vistas=()
    PLATAFORMA_ERRO=""
    [ -r "$arquivo" ] && [ -f "$arquivo" ] \
        || { PLATAFORMA_ERRO="os-release ausente ou ilegível: $arquivo"; return 1; }
    while IFS= read -r linha || [ -n "$linha" ]; do
        linha="${linha%$'\r'}"
        [ -n "$linha" ] && [[ "$linha" != \#* ]] || continue
        [[ "$linha" == *=* ]] || continue
        chave="$(_plataforma_trim "${linha%%=*}")"
        case "$chave" in
            ID|ID_LIKE|VARIANT_ID|VERSION_ID|VERSION_CODENAME) ;;
            *) continue ;;
        esac
        [ -z "${vistas[$chave]+definida}" ] \
            || { PLATAFORMA_ERRO="Chave $chave repetida em $arquivo."; return 1; }
        vistas[$chave]=1
        bruto="${linha#*=}"
        valor="$(_plataforma_decodificar_valor "$bruto")" \
            || { PLATAFORMA_ERRO="Valor inválido para $chave em $arquivo."; return 1; }
        case "$chave" in
            ID) id="$valor" ;;
            ID_LIKE) id_like="$valor" ;;
            VARIANT_ID) variant_id="$valor" ;;
            VERSION_ID) version_id="$valor" ;;
            VERSION_CODENAME) codename="$valor" ;;
        esac
    done < "$arquivo"

    [[ "$id" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
        || { PLATAFORMA_ERRO="ID ausente ou inválido em $arquivo."; return 1; }
    [ -z "$id_like" ] || [[ "$id_like" =~ ^[a-z0-9._-]+([[:space:]]+[a-z0-9._-]+)*$ ]] \
        || { PLATAFORMA_ERRO="ID_LIKE inválido em $arquivo."; return 1; }
    [ -z "$variant_id" ] || [[ "$variant_id" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
        || { PLATAFORMA_ERRO="VARIANT_ID inválido em $arquivo."; return 1; }
    [ -z "$version_id" ] || [[ "$version_id" =~ ^[[:alnum:]._-]+$ ]] \
        || { PLATAFORMA_ERRO="VERSION_ID inválido em $arquivo."; return 1; }
    [ -z "$codename" ] || [[ "$codename" =~ ^[[:alnum:]._-]+$ ]] \
        || { PLATAFORMA_ERRO="VERSION_CODENAME inválido em $arquivo."; return 1; }

    PLATAFORMA_ID="$id"
    PLATAFORMA_ID_LIKE="$id_like"
    PLATAFORMA_VARIANT_ID="$variant_id"
    PLATAFORMA_VERSION_ID="$version_id"
    PLATAFORMA_VERSION_CODENAME="$codename"
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

_plataforma_id_like_contem() {
    local procurado="$1" item
    for item in $PLATAFORMA_ID_LIKE; do
        [ "$item" = "$procurado" ] && return 0
    done
    return 1
}

_plataforma_detectar_imutabilidade() {
    # Em testes com os-release explicitamente injetado, apenas VARIANT_ID é
    # autoritativo. Em produção, /run/ostree-booted é uma segunda evidência.
    local fonte_explicita="${1:-0}" marcador=""
    case "$PLATAFORMA_VARIANT_ID" in
        silverblue|kinoite|sericea|onyx|coreos)
            PLATAFORMA_IMUTAVEL=1
            PLATAFORMA_BLOQUEIO_MOTIVO="VARIANT_ID=$PLATAFORMA_VARIANT_ID identifica uma implantação imutável."
            return 0
            ;;
    esac
    [ "$fonte_explicita" -eq 0 ] || return 0
    if declare -F caminho_sistema >/dev/null 2>&1; then
        marcador="$(caminho_sistema /run/ostree-booted)" || {
            PLATAFORMA_ERRO="Não foi possível resolver a evidência de implantação ostree."
            return 1
        }
    else
        marcador=/run/ostree-booted
    fi
    if [ -e "$marcador" ] || [ -L "$marcador" ]; then
        PLATAFORMA_IMUTAVEL=1
        PLATAFORMA_BLOQUEIO_MOTIVO="Uma implantação ostree foi detectada; o host é tratado como imutável."
    fi
}

_plataforma_classificar_suporte() {
    local familia
    if [ "$PLATAFORMA_IMUTAVEL" -eq 1 ]; then
        PLATAFORMA_SUPPORT_LEVEL=diagnostic-only
        PLATAFORMA_MUTAVEL=0
        return 0
    fi
    case "$PLATAFORMA_ID" in
        ubuntu|pop)
            PLATAFORMA_SUPPORT_LEVEL=supported
            PLATAFORMA_MUTAVEL=1
            PLATAFORMA_BLOQUEIO_MOTIVO=""
            return 0
            ;;
        debian|arch|cachyos|fedora|opensuse-tumbleweed)
            PLATAFORMA_SUPPORT_LEVEL=diagnostic-only
            PLATAFORMA_MUTAVEL=0
            PLATAFORMA_BLOQUEIO_MOTIVO="ID=$PLATAFORMA_ID possui provider planejado, ainda restrito a diagnóstico."
            return 0
            ;;
    esac
    for familia in ubuntu debian arch fedora rhel opensuse suse; do
        if _plataforma_id_like_contem "$familia"; then
            PLATAFORMA_SUPPORT_LEVEL=family-unverified
            PLATAFORMA_MUTAVEL=0
            PLATAFORMA_BLOQUEIO_MOTIVO="ID=$PLATAFORMA_ID declara ID_LIKE=$PLATAFORMA_ID_LIKE, mas a derivação não foi verificada."
            return 0
        fi
    done
    PLATAFORMA_SUPPORT_LEVEL=blocked
    PLATAFORMA_MUTAVEL=0
    PLATAFORMA_BLOQUEIO_MOTIVO="ID=$PLATAFORMA_ID não possui provider reconhecido."
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
    _plataforma_ler_os_release "$arquivo" || return 1
    PLATAFORMA_DETECTADA=1
    _plataforma_detectar_imutabilidade "$fonte_explicita" || return 1
    _plataforma_classificar_suporte
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
    case "$PLATAFORMA_ID" in
        ubuntu)
            PLATAFORMA_PERFIL=ubuntu
            PLATAFORMA_QEMU_PACOTE=qemu-system-x86
            PLATAFORMA_QEMU_USUARIO_PADRAO=libvirt-qemu
            PLATAFORMA_NVIDIA_ESTRATEGIA=ubuntu-drivers
            PLATAFORMA_BOOT_BACKENDS=grub
            ;;
        pop)
            PLATAFORMA_PERFIL=pop-os
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

platform_capability_known() {
    local procurada="${1:-}" capability
    [ -n "$procurada" ] || return 1
    for capability in "${PLATAFORMA_CAPABILITIES_CONHECIDAS[@]}"; do
        [ "$capability" = "$procurada" ] && return 0
    done
    return 1
}

platform_has_capability() {
    local capability="${1:-}"
    platform_capability_known "$capability" || return 1
    if [ "$PLATAFORMA_DETECTADA" -ne 1 ]; then
        plataforma_carregar || [ "$PLATAFORMA_DETECTADA" -eq 1 ] || return 1
    fi
    [ "${PLATAFORMA_CAPABILITIES[$capability]:-0}" -eq 1 ]
}

platform_capability_reason() {
    local capability="${1:-}"
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

_plataforma_sondar_unidade_fixture() {
    local unidade="$1" arquivo="$2" linha nome carga ativo sub unitfile extra encontrados=0
    _PLATAFORMA_UNIDADE_CARGA=not-found
    _PLATAFORMA_UNIDADE_ATIVA=inactive
    _PLATAFORMA_UNIDADE_SUB=dead
    _PLATAFORMA_UNIDADE_ARQUIVO=""
    while IFS= read -r linha || [ -n "$linha" ]; do
        [[ "$linha" != \#* && -n "$linha" ]] || continue
        IFS='|' read -r nome carga ativo sub unitfile extra <<< "$linha"
        [ -z "$extra" ] \
            || { PLATAFORMA_ERRO="Fixture systemd malformada: $linha"; return 2; }
        [ "$nome" = "$unidade" ] || continue
        encontrados=$((encontrados + 1))
        [ "$encontrados" -eq 1 ] \
            || { PLATAFORMA_ERRO="Unidade $unidade repetida na fixture."; return 2; }
        _PLATAFORMA_UNIDADE_CARGA="$carga"
        _PLATAFORMA_UNIDADE_ATIVA="$ativo"
        _PLATAFORMA_UNIDADE_SUB="$sub"
        _PLATAFORMA_UNIDADE_ARQUIVO="${unitfile:-disabled}"
    done < "$arquivo"
}

_plataforma_sondar_unidade() {
    local unidade="$1" fixture="${2:-}" saida linha chave valor
    local viu_carga=0 viu_ativa=0
    _PLATAFORMA_UNIDADE_CARGA=""
    _PLATAFORMA_UNIDADE_ATIVA=""
    _PLATAFORMA_UNIDADE_SUB=""
    _PLATAFORMA_UNIDADE_ARQUIVO=""
    if [ -n "$fixture" ]; then
        _plataforma_sondar_unidade_fixture "$unidade" "$fixture"
        return $?
    fi
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

_plataforma_classificar_unidade() {
    # Imprime SCORE|AÇÃO. Unidades ativas sempre vencem unidades apenas
    # carregadas; sockets vencem services quando o nível operacional empata.
    local unidade="$1" bonus=0
    [ "$_PLATAFORMA_UNIDADE_CARGA" = loaded ] || return 1
    [[ "$unidade" == *.socket ]] && bonus=1
    case "$_PLATAFORMA_UNIDADE_ATIVA" in
        active|activating) printf '%s|nenhuma\n' "$((100 + bonus))"; return 0 ;;
    esac
    case "$_PLATAFORMA_UNIDADE_ARQUIVO" in
        enabled|enabled-runtime|disabled)
            printf '%s|enable-now\n' "$((50 + bonus))" ;;
        static|indirect|generated|linked|linked-runtime|alias)
            printf '%s|start\n' "$((25 + bonus))" ;;
        *) return 1 ;;
    esac
}

plataforma_resolver_servico() {
    # Contrato público: 0 resolve; 1 indica unidade ainda ausente; 2 indica
    # configuração inválida ou falha operacional da sondagem. A fixture
    # opcional é autoritativa e nunca cai no systemd do host.
    local tipo="${1:-libvirt}" fixture="${2:-}" candidatos base unidade classificado rc
    local score acao melhor_score=-1 melhor_unidade="" melhor_acao=""
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
    if [ -n "$fixture" ] && { [ ! -r "$fixture" ] || [ ! -f "$fixture" ]; }; then
        PLATAFORMA_ERRO="Fixture de serviços ausente ou ilegível: $fixture."
        return 2
    fi
    for base in $candidatos; do
        for unidade in "${base}.socket" "${base}.service"; do
            if _plataforma_sondar_unidade "$unidade" "$fixture"; then
                :
            else
                rc=$?
                return "$rc"
            fi
            classificado="$(_plataforma_classificar_unidade "$unidade" || true)"
            [ -n "$classificado" ] || continue
            score="${classificado%%|*}"
            acao="${classificado#*|}"
            if [ "$score" -gt "$melhor_score" ]; then
                melhor_score="$score"
                melhor_unidade="$unidade"
                melhor_acao="$acao"
            fi
        done
    done
    [ -n "$melhor_unidade" ] \
        || { PLATAFORMA_ERRO="Nenhuma unidade $tipo ativa ou iniciável entre os backends do perfil: $candidatos."; return 1; }
    PLATAFORMA_UNIDADE_RESOLVIDA="$melhor_unidade"
    PLATAFORMA_SERVICO_RESOLVIDO="${melhor_unidade%%.*}"
    PLATAFORMA_UNIDADE_ACAO="$melhor_acao"
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
    # O argumento opcional injeta somente o resultado da sonda em testes que
    # chamam esta função diretamente; entrypoints operacionais não o repassam.
    local vendor="${1:-}" saida linha chave valor
    PLATAFORMA_CPU_VENDOR=""
    PLATAFORMA_ERRO=""
    if [ -z "$vendor" ]; then
        command -v lscpu >/dev/null 2>&1 \
            || { PLATAFORMA_ERRO="lscpu indisponível para identificar o fabricante da CPU."; return 1; }
        saida="$(LC_ALL=C lscpu 2>/dev/null)" \
            || { PLATAFORMA_ERRO="lscpu falhou ao identificar o fabricante da CPU."; return 1; }
        while IFS=: read -r chave valor; do
            chave="$(_plataforma_trim "$chave")"
            [ "$chave" = "Vendor ID" ] || continue
            valor="$(_plataforma_trim "$valor")"
            [ -n "$valor" ] || continue
            if [ -z "$vendor" ]; then
                vendor="$valor"
            elif [ "$vendor" != "$valor" ]; then
                PLATAFORMA_ERRO="Mais de um fabricante de CPU foi reportado: $vendor e $valor."
                return 1
            fi
        done <<< "$saida"
    fi
    case "$vendor" in
        AuthenticAMD|GenuineIntel) ;;
        *) PLATAFORMA_ERRO="Fabricante de CPU ausente ou não suportado: ${vendor:-desconhecido}."; return 1 ;;
    esac
    PLATAFORMA_CPU_VENDOR="$vendor"
}


plataforma_validar_cpu_amd() {
    # O argumento opcional é encaminhado apenas por testes unitários diretos.
    plataforma_detectar_cpu_vendor "${1:-}" || return 1
    [ "$PLATAFORMA_CPU_VENDOR" = AuthenticAMD ] || {
        PLATAFORMA_ERRO="CPU $PLATAFORMA_CPU_VENDOR bloqueada: esta implementação oferece apenas AMD (amd_iommu=on/AMD-Vi). Intel e outros fabricantes não sofrerão qualquer mutação."
        return 1
    }
}
