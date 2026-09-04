#!/bin/bash
# ============================================================================
# lib/shell/probes.sh - observação do host: hardware, discos, CPU, memória e identidades
# ============================================================================
# Este arquivo NÃO é executado diretamente: ele é carregado via "source" por
# lib/common.sh, que continua sendo a fachada pública das etapas.
#
# Fronteiras (seções 2.1, 2.3 e 2.4 do PLANO-FINALIZACAO.md):
#
#   * aqui fica a CAPTURA do estado do host: inventário de hardware, topologia
#     de disco, CPU/RAM, usuário/grupos e interfaces de rede;
#   * o ciclo de vida do ARQUIVO de inventário não mora aqui (decisão I9-D2 do
#     plano): ele é de storage.sh, e essa separação é o que mantém a direção
#     de dependência única (storage observa por probes, probes nunca lê o
#     arquivo publicado);
#   * cálculo puro de CPU/RAM continua no core Python, pela ponte única.
#
# Pré-requisitos de carga: lib/python-core.sh, lib/shell/base.sh, lib/shell/boot.sh, lib/shell/ui.sh.
# Carregar fora de ordem é recusado com diagnóstico, nunca com falha obscura.
#
# Sourcing deste arquivo não produz efeito: apenas define variáveis e funções.
# ============================================================================

if ! declare -F caminho_sistema > /dev/null 2>&1; then
    printf 'ERRO: lib/shell/probes.sh exige %s carregado antes.\n' 'lib/shell/base.sh' >&2
    return 1 2>/dev/null || exit 1
fi
if ! declare -F falhar > /dev/null 2>&1; then
    printf 'ERRO: lib/shell/probes.sh exige %s carregado antes.\n' 'lib/shell/ui.sh' >&2
    return 1 2>/dev/null || exit 1
fi
if ! declare -F detectar_bootloader > /dev/null 2>&1; then
    printf 'ERRO: lib/shell/probes.sh exige %s carregado antes.\n' 'lib/shell/boot.sh' >&2
    return 1 2>/dev/null || exit 1
fi
if ! declare -F python_core_pares_payload > /dev/null 2>&1; then
    printf 'ERRO: lib/shell/probes.sh exige %s carregado antes.\n' 'lib/python-core.sh' >&2
    return 1 2>/dev/null || exit 1
fi

[ -n "${PROBES_SH_CARREGADO:-}" ] && return 0
PROBES_SH_CARREGADO=1

APT_ATUALIZACOES_ERRO=""
APT_ATUALIZACOES_TOTAL=""
APT_DIST_INSTALACOES=""
APT_DIST_REMOCOES=""
APT_AUTOREMOVE_EXCLUSIVAS=""
apt_contar_atualizacoes() {
    # Simula, sem locale e sem locks, as duas classes de transação realmente
    # aplicadas pela etapa 4. O total deduplica nomes de pacote entre os dois
    # planos; as categorias são diagnóstico e não devem ser somadas.
    local saida_dist saida_autoremove resumo total instalacoes remocoes auto_exclusivas
    APT_ATUALIZACOES_ERRO=""
    APT_ATUALIZACOES_TOTAL=""
    APT_DIST_INSTALACOES=""
    APT_DIST_REMOCOES=""
    APT_AUTOREMOVE_EXCLUSIVAS=""
    command -v apt-get >/dev/null 2>&1 \
        || { APT_ATUALIZACOES_ERRO="apt-get não está disponível."; return 1; }
    if ! saida_dist="$(LC_ALL=C apt-get --simulate -o Debug::NoLocking=1 dist-upgrade 2>&1)"; then
        APT_ATUALIZACOES_ERRO="Falha ao simular dist-upgrade APT: ${saida_dist:-sem diagnóstico}."
        return 1
    fi
    if ! saida_autoremove="$(LC_ALL=C apt-get --simulate -o Debug::NoLocking=1 autoremove 2>&1)"; then
        APT_ATUALIZACOES_ERRO="Falha ao simular autoremove APT: ${saida_autoremove:-sem diagnóstico}."
        return 1
    fi
    resumo="$(awk '
        BEGIN { fase = "dist" }
        $0 == "__PASSTHROUGH_AUTOREMOVE__" { fase = "autoremove"; next }
        ($1 == "Inst" || $1 == "Remv") && NF >= 2 {
            pacote = $2
            todos[pacote] = 1
            if (fase == "dist") {
                dist[pacote] = 1
                if ($1 == "Inst") inst[pacote] = 1
                else remv[pacote] = 1
            } else {
                auto[pacote] = 1
            }
        }
        END {
            for (p in todos) total++
            for (p in inst) ni++
            for (p in remv) nr++
            for (p in auto) if (!(p in dist)) na++
            print total + 0, ni + 0, nr + 0, na + 0
        }
    ' <<< "$saida_dist"$'\n__PASSTHROUGH_AUTOREMOVE__\n'"$saida_autoremove")" \
        || { APT_ATUALIZACOES_ERRO="Falha ao analisar as simulações APT."; return 1; }
    read -r total instalacoes remocoes auto_exclusivas <<< "$resumo"
    [[ "$total" =~ ^[0-9]+$ && "$instalacoes" =~ ^[0-9]+$ \
       && "$remocoes" =~ ^[0-9]+$ && "$auto_exclusivas" =~ ^[0-9]+$ ]] \
        || { APT_ATUALIZACOES_ERRO="Resumo APT inválido: '$resumo'."; return 1; }
    APT_ATUALIZACOES_TOTAL="$total"
    APT_DIST_INSTALACOES="$instalacoes"
    APT_DIST_REMOCOES="$remocoes"
    APT_AUTOREMOVE_EXCLUSIVAS="$auto_exclusivas"
    printf '%s\n' "$total"
}

fwupd_classificar_resultado() {
    # Contrato do cliente fwupdmgr: 0=operação concluída e 2=nada a fazer.
    # O código 2 só é normal para consultas/aplicação de updates; refresh deve
    # concluir com zero. Qualquer outro status é falha operacional.
    local operacao="${1:-}" rc="${2:-}"
    [[ "$rc" =~ ^[0-9]+$ ]] || return 1
    case "$operacao:$rc" in
        refresh:0|get-updates:0|update:0) printf '%s\n' sucesso ;;
        get-updates:2|update:2) printf '%s\n' sem-atualizacoes ;;
        *) printf '%s\n' erro; return 1 ;;
    esac
}

# --- Inventário de hardware --------------------------------------------------
INVENTARIO_ERRO=""
INVENTARIO_DIFERENCAS=""
INVENTARIO_RESOLVIDO=""

modo_execucao_etapa02() {
    case "${1:-}" in
        ""|--redetectar) printf '%s\n' reiniciar ;;
        --verificar) printf '%s\n' verificar ;;
        *) return 1 ;;
    esac
}

INVENTARIO_DECISION_FINGERPRINT=""
INVENTARIO_SYSTEM_FINGERPRINT=""
INVENTARIO_WORKING_FINGERPRINT=""
INVENTARIO_HD1_FINGERPRINT=""
INVENTARIO_CONFLITOS_DISCO=0
INVENTARIO_UDEV_STATE="unavailable"
INVENTARIO_UDEV_REASON="probe_missing"

_inventario_capturar_topologia_disco() {
    # Preenche o array de pares indicado com capturas de bloco já realizadas
    # pelo Bash. O Python recebe somente texto e nunca abre /dev ou /sys.
    local nome_array="${1:-}" block_json="" udev_db="" by_id_map=""
    local by_id_dir="" alias alvo major
    local -n destino="$nome_array"
    INVENTARIO_UDEV_STATE="unavailable"
    INVENTARIO_UDEV_REASON="probe_missing"
    block_json="$(LC_ALL=C lsblk --json --bytes \
        -o NAME,KNAME,PATH,TYPE,MAJ:MIN,PKNAME,SIZE,MODEL,SERIAL,WWN,MOUNTPOINTS 2>/dev/null)" \
        || return 1
    if command -v udevadm >/dev/null 2>&1; then
        if udev_db="$(LC_ALL=C udevadm info --export-db 2>/dev/null)"; then
            INVENTARIO_UDEV_STATE="present"
            INVENTARIO_UDEV_REASON=""
        else
            INVENTARIO_UDEV_STATE="error"
            INVENTARIO_UDEV_REASON="probe_failed"
            udev_db=""
        fi
    fi
    by_id_dir="$(caminho_sistema /dev/disk/by-id 2>/dev/null || true)"
    if [ -d "$by_id_dir" ]; then
        while IFS= read -r alias; do
            [ -L "$alias" ] || continue
            alvo="$(readlink -f -- "$alias" 2>/dev/null || true)"
            [ -n "$alvo" ] || continue
            major="$(LC_ALL=C lsblk -dnro MAJ:MIN -- "$alvo" 2>/dev/null | head -n1)"
            [[ "$major" =~ ^[0-9]+:[0-9]+$ ]] || continue
            by_id_map+="${alias##*/}"$'\t'"$major"$'\n'
        done < <(find "$by_id_dir" -maxdepth 1 -type l ! -name '*-part*' -print 2>/dev/null | LC_ALL=C sort)
    fi
    destino+=(
        block_json "$block_json"
        block_by_id_map "$by_id_map"
        udev_database "$udev_db"
    )
}

coletar_snapshot_inventario() {
    # Captura fatos do host sem interpretar o domínio. Estados distinguem
    # ausência, indisponibilidade, erro e coleção vazia; o core valida todas as
    # combinações e produz o relatório canônico.
    local nome_array="${1:-}" memory_report="${2:-}" baseboard_report="${3:-}"
    local bios_report="${4:-}" iommu_report="${5:-}"
    local cpu_data="" memory_data="" pci_data="" interfaces_data="" boot_data=""
    local udev_db="" meminfo="" firmware="bios" bootloader="unknown"
    local cpu_state=present cpu_reason="" memory_state=present memory_reason=""
    local pci_state=present pci_reason="" disks_state=present disks_reason=""
    local usb_state=present usb_reason="" interfaces_state=present interfaces_reason=""
    local boot_state=present boot_reason=""
    local -a pares=(schema_version 1)
    local -n destino="$nome_array"

    INVENTARIO_UDEV_STATE="unavailable"
    INVENTARIO_UDEV_REASON="probe_missing"
    cpu_data="$(LC_ALL=C lscpu 2>/dev/null)" || { cpu_state=error; cpu_reason=probe_failed; cpu_data=""; }
    [ -n "$cpu_data" ] || { cpu_state=error; cpu_reason=malformed_capture; }
    meminfo="$(caminho_sistema /proc/meminfo 2>/dev/null || true)"
    if [ -r "$meminfo" ]; then
        memory_data="$(<"$meminfo")" || { memory_state=error; memory_reason=probe_failed; memory_data=""; }
    else
        memory_state=unavailable; memory_reason=permission_denied
    fi
    pci_data="$(LC_ALL=C lspci -Dnn 2>/dev/null)" || { pci_state=error; pci_reason=probe_failed; pci_data=""; }
    if [ "$pci_state" = present ] && [ -z "$pci_data" ]; then pci_state=empty; fi

    if ! _inventario_capturar_topologia_disco pares; then
        disks_state=error; disks_reason=probe_failed
        pares+=(block_json "" block_by_id_map "" udev_database "")
    fi
    local i
    for (( i=0; i<${#pares[@]}; i+=2 )); do
        [ "${pares[$i]}" != udev_database ] || udev_db="${pares[$((i+1))]}"
    done
    if [ -n "$udev_db" ]; then
        # Overrides de teste podem fornecer a captura diretamente.
        INVENTARIO_UDEV_STATE=present
        INVENTARIO_UDEV_REASON=""
    fi
    case "$INVENTARIO_UDEV_STATE" in
        present)
            if grep -Fq 'E: DEVTYPE=usb_device' <<< "$udev_db"; then
                :
            else
                usb_state=empty
                udev_db=""
            fi
            ;;
        error)
            usb_state=error
            usb_reason="${INVENTARIO_UDEV_REASON:-probe_failed}"
            udev_db=""
            ;;
        *)
            usb_state=unavailable
            usb_reason="${INVENTARIO_UDEV_REASON:-probe_missing}"
            udev_db=""
            ;;
    esac

    if command -v ip >/dev/null 2>&1; then
        interfaces_data="$(LC_ALL=C ip -j -details link 2>/dev/null)" \
            || { interfaces_state=error; interfaces_reason=probe_failed; interfaces_data=""; }
        if [ "$interfaces_state" = present ] && [ "$interfaces_data" = "[]" ]; then
            interfaces_state=empty
            interfaces_data=""
        fi
    else
        interfaces_state=unavailable; interfaces_reason=probe_missing
    fi
    [ -d "$(caminho_sistema /sys/firmware/efi 2>/dev/null || true)" ] && firmware=uefi
    bootloader="$(detectar_bootloader 2>/dev/null || true)"
    case "$bootloader" in grub|kernelstub) ;; *) bootloader=unknown ;; esac
    boot_data="FIRMWARE=$firmware"$'\n'"SECURE_BOOT=unknown"$'\n'"BOOTLOADER=$bootloader"

    pares+=(
        cpu_state "$cpu_state" cpu_reason "$cpu_reason" cpu_data "$cpu_data"
        memory_state "$memory_state" memory_reason "$memory_reason" memory_data "$memory_data"
        memory_report "${memory_report:-$memory_data}"
        pci_state "$pci_state" pci_reason "$pci_reason" pci_data "$pci_data"
        disks_state "$disks_state" disks_reason "$disks_reason"
        usb_state "$usb_state" usb_reason "$usb_reason" usb_data "$udev_db"
        interfaces_state "$interfaces_state" interfaces_reason "$interfaces_reason" interfaces_data "$interfaces_data"
        boot_state "$boot_state" boot_reason "$boot_reason" boot_data "$boot_data"
        baseboard_report "${baseboard_report:-(indisponível)}"
        bios_report "${bios_report:-(indisponível)}"
        iommu_report "${iommu_report:-(vazio: normal antes da etapa 11)}"
    )
    destino=("${pares[@]}")
}

inventario_normalizar_snapshot() {
    local nome_payload="${1:-}" destino="${2:-}"
    local -a permitidas=(
        "${CORE_PARES_ENVELOPE[@]}" VALID ERROR SCHEMA_VERSION SOURCE_FORMAT
        COVERAGE CPU_STATE MEMORY_STATE PCI_STATE DISKS_STATE USB_STATE
        INTERFACES_STATE BOOT_STATE FACT_COUNT SNAPSHOT_FINGERPRINT
        IDENTITY_FINGERPRINT DECISION_FINGERPRINT BYTES_WRITTEN SHA256
    )
    INVENTARIO_ERRO=""
    python_core_arquivo_saida permitidas INVN_ inventory-normalize \
        "$nome_payload" "$destino" || {
        INVENTARIO_ERRO="${PYTHON_CORE_ERRO:-O core recusou a captura de inventário.}"
        return 1
    }
    INVENTARIO_DECISION_FINGERPRINT="$INVN_DECISION_FINGERPRINT"
}

inventario_planejar_papeis_disco() {
    local system_members="${1:-}" working_members="${2:-}" hd1_members="${3:-}"
    local expected_system="${4:-}" expected_working="${5:-}" expected_hd1="${6:-}"
    local -a payload=() permitidas=(
        "${CORE_PARES_ENVELOPE[@]}" VALID ERROR SYSTEM_STATE WORKING_STATE HD1_STATE
        SYSTEM_FINGERPRINT WORKING_FINGERPRINT HD1_FINGERPRINT CONFLICT_COUNT
        'CONFLICT_#_LEFT' 'CONFLICT_#_RIGHT' 'CONFLICT_#_IDENTITY'
    )
    INVENTARIO_ERRO=""
    INVENTARIO_SYSTEM_FINGERPRINT=""; INVENTARIO_WORKING_FINGERPRINT=""; INVENTARIO_HD1_FINGERPRINT=""
    INVENTARIO_CONFLITOS_DISCO=0
    _inventario_capturar_topologia_disco payload \
        || { INVENTARIO_ERRO="Não foi possível capturar a topologia física de discos."; return 1; }
    payload+=(
        system_members "$system_members" working_members "$working_members" hd1_members "$hd1_members"
        expected_system_fingerprint "$expected_system"
        expected_working_fingerprint "$expected_working"
        expected_hd1_fingerprint "$expected_hd1"
    )
    python_core_pares_payload permitidas INVD_ inventory-disk-plan payload || {
        INVENTARIO_ERRO="${PYTHON_CORE_ERRO:-O core recusou a topologia física de discos.}"
        return 1
    }
    INVENTARIO_SYSTEM_FINGERPRINT="$INVD_SYSTEM_FINGERPRINT"
    INVENTARIO_WORKING_FINGERPRINT="$INVD_WORKING_FINGERPRINT"
    INVENTARIO_HD1_FINGERPRINT="$INVD_HD1_FINGERPRINT"
    INVENTARIO_CONFLITOS_DISCO="$INVD_CONFLICT_COUNT"
    if [ "$INVD_VALID" != 1 ]; then
        INVENTARIO_ERRO="${INVD_ERROR:-Papéis de disco fisicamente incompatíveis.}"
        return 1
    fi
}

inventario_resolver_usb() {
    # inventario_resolver_usb DADOS MODO VID PID KIND SHA BUS DEVICE
    local usb_data="${1:-}" mode="${2:-}" vendor="${3:-}" product="${4:-}"
    local kind="${5:-}" digest="${6:-}" bus="${7:-}" device="${8:-}"
    local -a payload=(
        usb_data "$usb_data" mode "$mode" vendor "$vendor" product "$product"
        identity_kind "$kind" identity_sha256 "$digest"
        expected_bus "$bus" expected_device "$device"
    ) permitidas=(
        "${CORE_PARES_ENVELOPE[@]}" VALID ERROR MATCH_COUNT IDENTITY_KIND
        IDENTITY_SHA256 VENDOR PRODUCT PORT BUS DEVICE RENUMBERED
    )
    USB_IDENTIDADE_ERRO=""; USB_IDENTIDADE_KIND=""; USB_IDENTIDADE_SHA256=""
    USB_IDENTIDADE_VENDOR=""; USB_IDENTIDADE_PRODUCT=""; USB_IDENTIDADE_PORT=""
    USB_IDENTIDADE_BUS=""; USB_IDENTIDADE_DEVICE=""; USB_IDENTIDADE_RENUMBERED=0
    python_core_pares_payload permitidas USBID_ inventory-usb-resolve payload || {
        USB_IDENTIDADE_ERRO="${PYTHON_CORE_ERRO:-O core recusou a captura USB.}"
        return 1
    }
    USB_IDENTIDADE_ERRO="$USBID_ERROR"
    USB_IDENTIDADE_KIND="$USBID_IDENTITY_KIND"
    USB_IDENTIDADE_SHA256="$USBID_IDENTITY_SHA256"
    USB_IDENTIDADE_VENDOR="$USBID_VENDOR"
    USB_IDENTIDADE_PRODUCT="$USBID_PRODUCT"
    USB_IDENTIDADE_PORT="$USBID_PORT"
    USB_IDENTIDADE_BUS="$USBID_BUS"
    USB_IDENTIDADE_DEVICE="$USBID_DEVICE"
    USB_IDENTIDADE_RENUMBERED="$USBID_RENUMBERED"
    [ "$USBID_VALID" = 1 ] || return 1
}

pci_vendor_device_atual() {
    local bdf="${1,,}" base="/sys/bus/pci/devices/${1,,}" vendor device
    pci_bdf_valido "$bdf" || return 1
    [ -r "$base/vendor" ] && [ -r "$base/device" ] || return 1
    IFS= read -r vendor < "$base/vendor" || return 1
    IFS= read -r device < "$base/device" || return 1
    vendor="${vendor#0x}"
    device="${device#0x}"
    pci_vendor_device_valido "$vendor:$device" || return 1
    printf '%s:%s\n' "${vendor,,}" "${device,,}"
}

IOMMU_ERRO=""
IOMMU_GRUPO_ATUAL=""
IOMMU_MEMBROS=""
validar_grupo_iommu_gpu() {
    # validar_grupo_iommu_gpu GPU_BDF AUDIO_BDF GRUPO_ESPERADO GPU_VID_DID AUDIO_VID_DID
    # Aceita somente as funções autorizadas e bridges PCI (classe base 0x06).
    local gpu="${1,,}" audio="${2,,}" esperado="${3:-}"
    local gpu_id="${4,,}" audio_id="${5,,}" link grupo membro bdf classe id_atual
    local restaurar_nullglob=0
    local -a membros=()
    IOMMU_ERRO=""
    IOMMU_GRUPO_ATUAL=""
    IOMMU_MEMBROS=""

    pci_bdf_valido "$gpu" \
        || { IOMMU_ERRO="GPU_PCI_ID inválido: '${gpu:-vazio}'."; return 1; }
    [ -z "$audio" ] || pci_bdf_valido "$audio" \
        || { IOMMU_ERRO="GPU_AUDIO_PCI_ID inválido: '$audio'."; return 1; }
    [ -z "$esperado" ] || inteiro_na_faixa "$esperado" 0 65535 \
        || { IOMMU_ERRO="IOMMU_GROUP_GPU persistido é inválido: '$esperado'."; return 1; }

    link="/sys/bus/pci/devices/$gpu/iommu_group"
    [ -L "$link" ] \
        || { IOMMU_ERRO="GPU $gpu ausente ou sem grupo IOMMU."; return 1; }
    grupo="$(basename -- "$(readlink -f -- "$link" 2>/dev/null)")" \
        || { IOMMU_ERRO="Não foi possível resolver o grupo IOMMU da GPU $gpu."; return 1; }
    inteiro_na_faixa "$grupo" 0 65535 \
        || { IOMMU_ERRO="Grupo IOMMU resolvido é inválido: '$grupo'."; return 1; }
    IOMMU_GRUPO_ATUAL="$grupo"
    if [ -n "$esperado" ] && [ "$((10#$grupo))" -ne "$((10#$esperado))" ]; then
        IOMMU_ERRO="A GPU mudou do grupo IOMMU persistido $esperado para $grupo; execute uma redetecção consciente."
        return 1
    fi

    if [ -n "$audio" ]; then
        link="/sys/bus/pci/devices/$audio/iommu_group"
        [ -L "$link" ] \
            || { IOMMU_ERRO="Função de áudio $audio ausente ou sem grupo IOMMU."; return 1; }
        [ "$(basename -- "$(readlink -f -- "$link" 2>/dev/null)")" = "$grupo" ] \
            || { IOMMU_ERRO="GPU $gpu e áudio $audio não pertencem ao mesmo grupo IOMMU."; return 1; }
    fi

    if [ -n "$gpu_id" ]; then
        id_atual="$(pci_vendor_device_atual "$gpu")" \
            || { IOMMU_ERRO="Não foi possível ler vendor/device da GPU $gpu."; return 1; }
        [ "$id_atual" = "$gpu_id" ] \
            || { IOMMU_ERRO="O BDF $gpu agora identifica $id_atual, não a GPU autorizada $gpu_id."; return 1; }
    fi
    if [ -n "$audio" ] && [ -n "$audio_id" ]; then
        id_atual="$(pci_vendor_device_atual "$audio")" \
            || { IOMMU_ERRO="Não foi possível ler vendor/device do áudio $audio."; return 1; }
        [ "$id_atual" = "$audio_id" ] \
            || { IOMMU_ERRO="O BDF $audio agora identifica $id_atual, não o áudio autorizado $audio_id."; return 1; }
    fi

    shopt -q nullglob || { shopt -s nullglob; restaurar_nullglob=1; }
    membros=("/sys/kernel/iommu_groups/$grupo/devices/"*)
    [ "$restaurar_nullglob" -eq 0 ] || shopt -u nullglob
    [ "${#membros[@]}" -gt 0 ] \
        || { IOMMU_ERRO="O grupo IOMMU $grupo não possui membros legíveis."; return 1; }
    for membro in "${membros[@]}"; do
        bdf="${membro##*/}"
        IOMMU_MEMBROS="${IOMMU_MEMBROS:+$IOMMU_MEMBROS }$bdf"
        [ "$bdf" = "$gpu" ] && continue
        [ -n "$audio" ] && [ "$bdf" = "$audio" ] && continue
        [ -r "/sys/bus/pci/devices/$bdf/class" ] \
            || { IOMMU_ERRO="Não foi possível classificar o membro $bdf do grupo $grupo."; return 1; }
        IFS= read -r classe < "/sys/bus/pci/devices/$bdf/class" || return 1
        [[ "${classe,,}" == 0x06* ]] && continue
        IOMMU_ERRO="Endpoint não autorizado $bdf (classe $classe) compartilha o grupo IOMMU $grupo."
        return 1
    done
}

USUARIO_VALIDACAO_ERRO=""
USUARIO_VALIDADO_UID=""
USUARIO_VALIDADO_GID=""
USUARIO_VALIDADO_HOME=""
USUARIO_OPERADOR=""
USUARIO_DIFERE_OPERADOR=0

usuario_operador_efetivo() {
    # O argumento opcional existe apenas para testes unitários que chamam esta
    # API diretamente. Fluxos operacionais não o recebem do ambiente.
    local operador="${1:-}"
    if [ -z "$operador" ]; then
        if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
            operador="$SUDO_USER"
        else
            operador="$(id -un 2>/dev/null)" || return 1
        fi
    fi
    nome_usuario_valido "$operador" || return 1
    printf '%s\n' "$operador"
}

validar_usuario_linux() {
    # Valida uma única entrada NSS e cruza UID/GID com id(1). O home precisa
    # ser absoluto, existir e ser atravessável como diretório. O segundo
    # argumento injeta o operador somente em chamadas unitárias explícitas.
    local usuario="${1:-}" operador_injetado="${2:-}"
    local registro nome senha uid gid gecos home shell extra uid_id gid_id operador
    local -a registros=()
    USUARIO_VALIDACAO_ERRO=""
    USUARIO_VALIDADO_UID=""
    USUARIO_VALIDADO_GID=""
    USUARIO_VALIDADO_HOME=""
    USUARIO_OPERADOR=""
    USUARIO_DIFERE_OPERADOR=0
    nome_usuario_valido "$usuario" \
        || { USUARIO_VALIDACAO_ERRO="USUARIO_LINUX inválido: '${usuario:-vazio}'."; return 1; }
    mapfile -t registros < <(getent passwd "$usuario" 2>/dev/null)
    [ "${#registros[@]}" -eq 1 ] \
        || { USUARIO_VALIDACAO_ERRO="A conta '$usuario' não possui uma entrada NSS única."; return 1; }
    registro="${registros[0]}"
    IFS=: read -r nome senha uid gid gecos home shell extra <<< "$registro"
    [ "$nome" = "$usuario" ] && [ -z "$extra" ] \
        || { USUARIO_VALIDACAO_ERRO="A entrada NSS de '$usuario' é inconsistente."; return 1; }
    inteiro_na_faixa "$uid" 1 2147483647 \
        || { USUARIO_VALIDACAO_ERRO="UID inválido para '$usuario': '${uid:-vazio}'."; return 1; }
    inteiro_na_faixa "$gid" 1 2147483647 \
        || { USUARIO_VALIDACAO_ERRO="GID inválido para '$usuario': '${gid:-vazio}'."; return 1; }
    caminho_absoluto_seguro "$home" && [ -d "$home" ] \
        || { USUARIO_VALIDACAO_ERRO="Home inválido ou inexistente para '$usuario': '${home:-vazio}'."; return 1; }
    uid_id="$(id -u "$usuario" 2>/dev/null)" \
        || { USUARIO_VALIDACAO_ERRO="id não conseguiu resolver o UID de '$usuario'."; return 1; }
    gid_id="$(id -g "$usuario" 2>/dev/null)" \
        || { USUARIO_VALIDACAO_ERRO="id não conseguiu resolver o GID de '$usuario'."; return 1; }
    [ "$uid_id" = "$uid" ] && [ "$gid_id" = "$gid" ] \
        || { USUARIO_VALIDACAO_ERRO="UID/GID de id e NSS divergem para '$usuario'."; return 1; }
    operador="$(usuario_operador_efetivo "$operador_injetado")" \
        || { USUARIO_VALIDACAO_ERRO="Não foi possível determinar o operador efetivo."; return 1; }
    USUARIO_VALIDADO_UID="$uid"
    USUARIO_VALIDADO_GID="$gid"
    USUARIO_VALIDADO_HOME="$home"
    USUARIO_OPERADOR="$operador"
    [ "$usuario" = "$operador" ] || USUARIO_DIFERE_OPERADOR=1
}

confirmar_usuario_linux_diferente() {
    local usuario="${1:-}" token
    [ "$USUARIO_DIFERE_OPERADOR" -eq 1 ] || return 0
    token="USAR-$usuario"
    confirmar_digitando "$token" \
        "USUARIO_LINUX='$usuario' é uma conta válida, mas o operador efetivo é '$USUARIO_OPERADOR'. As mutações agirão sobre a outra conta."
}

exigir_usuario_linux_valido() {
    local usuario="${1:-${USUARIO_LINUX:-}}"
    validar_usuario_linux "$usuario" || falhar "$USUARIO_VALIDACAO_ERRO"
    confirmar_usuario_linux_diferente "$usuario" \
        || falhar "Conta diferente do operador não foi autorizada; nenhuma mutação foi iniciada."
}

usuario_pertence_grupo() {
    local usuario="$1" grupo="$2" grupos
    grupos="$(id -nG "$usuario" 2>/dev/null)" || return 1
    grep -qw -- "$grupo" <<< "$grupos"
}

interface_fisica_elegivel() {
    local iface="${1:-}" base
    nome_interface_valido "$iface" || return 1
    [ "$iface" != "lo" ] || return 1
    base="$(caminho_sistema "/sys/class/net/$iface")" || return 1
    [ -e "$base/device" ] || return 1
    [ "$(cat "$base/type" 2>/dev/null)" = "1" ]
}

interface_wifi() {
    local iface="${1:-}" base
    base="$(caminho_sistema "/sys/class/net/$iface")" || return 1
    [ -d "$base/wireless" ]
}

dispositivo_uplink_ipv4_efetivo() {
    # Consulta somente a decisão local de roteamento do kernel: nenhum pacote é
    # enviado a 1.1.1.1. Imprime o dispositivo usado pela rota IPv4 efetiva.
    local rota dispositivo
    rota="$(ip -4 route get 1.1.1.1 2>/dev/null)" || return 1
    dispositivo="$(awk 'NR == 1 {
        for (i = 1; i <= NF; i++) {
            if ($i == "dev" && (i + 1) <= NF) { print $(i + 1); exit }
        }
    }' <<< "$rota")"
    [ -n "$dispositivo" ] || return 1
    printf '%s\n' "$dispositivo"
}

# --- Discos: identificação segura (nunca /dev/sdX chumbado) --------------------
discos_fisicos_de() {
    # Imprime TODOS os ancestrais físicos TYPE=disk (LVM/MD/multipath podem ter
    # mais de um). Falha se a topologia não puder ser enumerada integralmente.
    local origem="$1" saida caminho tipo
    local -A vistos=()
    [ -n "$origem" ] || return 1
    saida="$(lsblk -s -nro PATH,TYPE -- "$origem" 2>/dev/null)" || return 1
    while read -r caminho tipo; do
        [ "$tipo" = disk ] || continue
        [ -n "$caminho" ] || return 1
        if [ -z "${vistos[$caminho]+definido}" ]; then
            printf '%s\n' "$caminho"
            vistos[$caminho]=1
        fi
    done <<< "$saida"
    [ "${#vistos[@]}" -gt 0 ]
}

disco_de() {
    # Compatibilidade para consumidores que esperam um único disco. Valida a
    # topologia plural, mas retorna o primeiro; gates destrutivos usam a função
    # plural diretamente.
    local discos primeiro
    discos="$(discos_fisicos_de "$1")" || return 1
    IFS= read -r primeiro <<< "$discos"
    [ -n "$primeiro" ] || return 1
    printf '%s\n' "$primeiro"
}

discos_raiz() {
    local fonte
    fonte="$(findmnt -no SOURCE / 2>/dev/null | sed 's/\[.*\]$//')" || return 1
    [ -n "$fonte" ] || return 1
    discos_fisicos_de "$fonte"
}

disco_raiz() {
    local discos primeiro
    discos="$(discos_raiz)" || return 1
    IFS= read -r primeiro <<< "$discos"
    [ -n "$primeiro" ] || return 1
    printf '%s\n' "$primeiro"
}

DISCO_USO_ERRO=""
disco_em_uso_pelo_host() {
    # Retornos: 0=em uso/montado, 1=inspeção concluída e livre, 2=erro de
    # inspeção. Além de mountpoints, bloqueia swap, device-mapper/LVM/MD e
    # qualquer holder ativo no disco ou em suas partições.
    local disco="$1" raizes raiz real saida caminho tipo nome holder swap swap_real no_real
    local -a nos=()
    DISCO_USO_ERRO=""
    real="$(readlink -f -- "$disco" 2>/dev/null)" \
        || { DISCO_USO_ERRO="Não foi possível resolver $disco."; return 2; }
    raizes="$(discos_raiz 2>/dev/null)" \
        || { DISCO_USO_ERRO="Não foi possível enumerar todos os discos físicos da raiz."; return 2; }
    while IFS= read -r raiz; do
        [ -n "$raiz" ] || continue
        raiz="$(readlink -f -- "$raiz" 2>/dev/null)" \
            || { DISCO_USO_ERRO="Não foi possível resolver um ancestral físico da raiz."; return 2; }
        [ "$real" != "$raiz" ] || return 0
    done <<< "$raizes"

    saida="$(lsblk -nrpo PATH,MOUNTPOINTS -- "$real" 2>/dev/null)" \
        || { DISCO_USO_ERRO="lsblk falhou ao inspecionar montagens de $real."; return 2; }
    if awk 'NF > 1 && $2 != "" {encontrado=1} END {exit !encontrado}' <<< "$saida"; then
        return 0
    fi

    saida="$(lsblk -nrpo PATH,TYPE -- "$real" 2>/dev/null)" \
        || { DISCO_USO_ERRO="lsblk falhou ao inspecionar consumidores de $real."; return 2; }
    while read -r caminho tipo; do
        [ -n "$caminho" ] && [ -n "$tipo" ] \
            || { DISCO_USO_ERRO="Topologia de bloco incompleta ao inspecionar $real."; return 2; }
        nos+=("$caminho")
        case "$tipo" in
            disk|part) ;;
            *) return 0 ;; # crypt, lvm, raid, multipath e similares
        esac
    done <<< "$saida"
    [ "${#nos[@]}" -gt 0 ] \
        || { DISCO_USO_ERRO="Nenhum nó de bloco foi enumerado para $real."; return 2; }

    for caminho in "${nos[@]}"; do
        nome="${caminho##*/}"
        [ -d "/sys/class/block/$nome/holders" ] \
            || { DISCO_USO_ERRO="Não foi possível inspecionar holders de $caminho."; return 2; }
        for holder in "/sys/class/block/$nome/holders/"*; do
            [ -e "$holder" ] || continue
            return 0
        done
    done

    if [ -r /proc/swaps ]; then
        while read -r swap _; do
            [ "$swap" != "Filename" ] || continue
            [ -n "$swap" ] || continue
            swap_real="$(readlink -f -- "$swap" 2>/dev/null || true)"
            [ -n "$swap_real" ] || continue
            for caminho in "${nos[@]}"; do
                no_real="$(readlink -f -- "$caminho" 2>/dev/null || true)"
                [ -n "$no_real" ] || continue
                [ "$swap_real" != "$no_real" ] || return 0
            done
        done < /proc/swaps
    else
        DISCO_USO_ERRO="Não foi possível ler /proc/swaps."
        return 2
    fi
    return 1
}

DISCO_VM_ERRO=""
DISCO_VM_ALVO=""
validar_disco_fisico_vm() {
    # validar_disco_fisico_vm BY_ID [DISCO_SISTEMA] [ALVO_ESPERADO]
    # Executa duas fotografias completas: link, tipo, todos os ancestrais da
    # raiz, disco do sistema e montagens/consumidores. Qualquer erro de
    # inspeção bloqueia.
    local origem="${1:-}" disco_sistema="${2:-${NVME_DEVICE:-}}" esperado="${3:-}"
    local alvo="" atual raizes raiz real tipo uso_status rodada
    DISCO_VM_ERRO=""
    DISCO_VM_ALVO=""

    caminho_absoluto_seguro "$origem" \
        || { DISCO_VM_ERRO="Caminho do disco físico inválido: '${origem:-vazio}'."; return 1; }
    [[ "$origem" == /dev/disk/by-id/* ]] \
        || { DISCO_VM_ERRO="O disco físico precisa usar /dev/disk/by-id/*, nunca /dev/sdX ou /dev/nvmeX."; return 1; }

    for rodada in 1 2; do
        [ -L "$origem" ] \
            || { DISCO_VM_ERRO="O identificador persistente não existe ou não é link simbólico: $origem"; return 1; }
        atual="$(readlink -f -- "$origem" 2>/dev/null)" \
            || { DISCO_VM_ERRO="Não foi possível resolver o destino de $origem."; return 1; }
        if [ -z "$alvo" ]; then
            alvo="$atual"
        elif [ "$atual" != "$alvo" ]; then
            DISCO_VM_ERRO="BLOQUEADO: o alvo de $origem mudou durante a validação ($alvo -> $atual)."
            return 1
        fi
        [ -b "$atual" ] \
            || { DISCO_VM_ERRO="O destino atual de $origem não é dispositivo de bloco: $atual"; return 1; }
        tipo="$(lsblk -dnro TYPE -- "$atual" 2>/dev/null)" \
            || { DISCO_VM_ERRO="lsblk falhou ao classificar $atual."; return 1; }
        [ "$tipo" = disk ] \
            || { DISCO_VM_ERRO="$origem aponta para partição ou dispositivo não físico, não para disco inteiro."; return 1; }

        raizes="$(discos_raiz 2>/dev/null)" \
            || { DISCO_VM_ERRO="Não foi possível enumerar todos os discos físicos da raiz do host."; return 1; }
        while IFS= read -r raiz; do
            [ -n "$raiz" ] || continue
            raiz="$(readlink -f -- "$raiz" 2>/dev/null)" \
                || { DISCO_VM_ERRO="Não foi possível resolver um disco físico da raiz."; return 1; }
            [ "$atual" != "$raiz" ] \
                || { DISCO_VM_ERRO="BLOQUEADO: o disco selecionado contém a raiz do host ($raiz)."; return 1; }
        done <<< "$raizes"

        if [ -n "$disco_sistema" ]; then
            real="$(readlink -f -- "$disco_sistema" 2>/dev/null)" \
                || { DISCO_VM_ERRO="Não foi possível resolver o disco do sistema: $disco_sistema"; return 1; }
            [ -b "$real" ] \
                || { DISCO_VM_ERRO="O disco do sistema deixou de ser dispositivo de bloco: $disco_sistema"; return 1; }
            [ "$atual" != "$real" ] \
                || { DISCO_VM_ERRO="BLOQUEADO: o HD1 coincide com o disco do sistema ($real)."; return 1; }
        fi

        if [ -n "$esperado" ]; then
            real="$(readlink -f -- "$esperado" 2>/dev/null)" \
                || { DISCO_VM_ERRO="O alvo esperado do HD1 não pode mais ser resolvido: $esperado"; return 1; }
            [ "$atual" = "$real" ] \
                || { DISCO_VM_ERRO="BLOQUEADO: $origem não aponta para o alvo esperado ($real -> $atual)."; return 1; }
        fi
        if disco_em_uso_pelo_host "$atual"; then
            DISCO_VM_ERRO="BLOQUEADO: $atual ou uma de suas partições está montado/em uso no host."
            return 1
        else
            uso_status=$?
            if [ "$uso_status" -ne 1 ]; then
                DISCO_VM_ERRO="Falha fechada ao inspecionar uso de $atual: ${DISCO_USO_ERRO:-erro desconhecido}."
                return 1
            fi
        fi
    done
    DISCO_VM_ALVO="$alvo"
}

# --- Memória ---------------------------------------------------------------------
ram_total_mib() {
    local meminfo
    meminfo="$(caminho_sistema /proc/meminfo)" || return 1
    awk '/MemTotal/{printf "%d", $2/1024}' "$meminfo"
}

ram_reserva_host_mib() {
    # Reserva mínima do host: 25% do total, nunca abaixo de 4 GiB nem acima de
    # 8. I5: a aritmética vive no core (plano_memoria_vm); aqui só resta o
    # probe do host e a projeção do valor.
    local total="${1:-}"
    [ -n "$total" ] || total="$(ram_total_mib)" || return 1
    plano_memoria_vm "$total" || return 1
    printf '%s\n' "$CPUMEM_RESERVE_MIB"
}

ram_max_vm_mib() {
    # Teto para a VM: total menos a reserva do host, arredondado para baixo em
    # múltiplos de 1024 MiB (exigência das HugePages de 1 GiB da etapa 17).
    local total="${1:-}"
    [ -n "$total" ] || total="$(ram_total_mib)" || return 1
    plano_memoria_vm "$total" || return 1
    printf '%s\n' "$CPUMEM_MAX_VM_MIB"
}

# --- CPUs ------------------------------------------------------------------------
expandir_lista_cpus() {
    # "0-2,5,8-9" -> imprime uma CPU por linha, preservando a ordem declarada.
    local lista="${1:-}" parte inicio fim cpu
    local -a partes=()
    lista_cpus_valida "$lista" || return 1
    IFS=',' read -r -a partes <<< "$lista"
    for parte in "${partes[@]}"; do
        if [[ "$parte" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            inicio=$((10#${BASH_REMATCH[1]}))
            fim=$((10#${BASH_REMATCH[2]}))
            for ((cpu = inicio; cpu <= fim; cpu++)); do
                printf '%s\n' "$cpu"
            done
        else
            printf '%s\n' "$((10#$parte))"
        fi
    done
}

# I5: validar_particao_cpus foi removida. Ela era a validação relacional
# antiga, por contagem de CPUs contíguas, e ficou sem consumidor quando
# validar_layout_cpu passou a exigir topologia real. Mantê-la significaria
# duas implementações da mesma política, uma delas cega para socket, core e
# CPU offline.

cpu_topologia_csv() {
    # Saída estável e não localizada: CPU,CORE,SOCKET,NODE,ONLINE.
    LC_ALL=C lscpu -p=CPU,CORE,SOCKET,NODE,ONLINE 2>/dev/null \
        | awk -F, '!/^#/ && NF { print }'
}

normalizar_conjunto_cpus() {
    local lista="${1:-}"
    lista_cpus_valida "$lista" || return 1
    expandir_lista_cpus "$lista" | LC_ALL=C sort -n | paste -sd, -
}

CPU_LAYOUT_ERRO=""
CPU_LAYOUT_ONLINE=""
CPU_LAYOUT_FINGERPRINT=""
validar_layout_cpu() {
    # validar_layout_cpu CPUS_VM CPUS_HOST VM_VCPUS VM_CORES VM_THREADS [CSV]
    # CSV segue lscpu -p=CPU,CORE,SOCKET,NODE,ONLINE. Valida o conjunto exato
    # de CPUs online (inclusive IDs esparsos), siblings completos por core,
    # cardinalidade e produto da topologia. Pelo menos um core inteiro fica no
    # host.
    #
    # I5: a política relacional passou a ter uma implementação só, no core
    # Python. O shell continua sendo quem captura o snapshot (`lscpu` é um
    # probe do host) e quem publica o diagnóstico; as mensagens são as mesmas
    # de antes, porque são API operacional (seção 3.1). Além do veredicto, a
    # chamada devolve o fingerprint canônico da topologia, usado pelas etapas
    # para provar que o host não mudou entre planejar e aplicar.
    local cpus_vm="${1:-}" cpus_host="${2:-}" vcpus="${3:-}"
    local cores="${4:-}" threads="${5:-}" topologia="${6:-}"
    local -a permitidas=(
        "${CORE_PARES_ENVELOPE[@]}"
        VALID ERROR ONLINE_SET ONLINE_COUNT VM_CPU_COUNT VM_CORE_COUNT
        HOST_CORE_COUNT FINGERPRINT
    )
    local -a payload=()
    CPU_LAYOUT_ERRO=""
    CPU_LAYOUT_ONLINE=""
    CPU_LAYOUT_FINGERPRINT=""
    if [ -z "$topologia" ]; then
        topologia="$(cpu_topologia_csv)" \
            || { CPU_LAYOUT_ERRO="lscpu não conseguiu fornecer a topologia parseável."; return 1; }
    fi
    [ -n "$topologia" ] \
        || { CPU_LAYOUT_ERRO="A topologia de CPU está vazia."; return 1; }
    payload=(
        csv "$topologia"
        cpus_vm "$cpus_vm"
        cpus_host "$cpus_host"
        vcpus "$vcpus"
        cores "$cores"
        threads "$threads"
    )
    if ! python_core_pares_payload permitidas CPULAYOUT_ cpu-layout payload \
            2>/dev/null; then
        CPU_LAYOUT_ERRO="$(_core_diagnostico 'Não foi possível validar o layout de CPU.')"
        return 1
    fi
    if [ "${CPULAYOUT_VALID:-0}" != 1 ]; then
        CPU_LAYOUT_ERRO="${CPULAYOUT_ERROR:-Layout de CPU recusado pelo core.}"
        return 1
    fi
    CPU_LAYOUT_ONLINE="${CPULAYOUT_ONLINE_SET:-}"
    CPU_LAYOUT_FINGERPRINT="${CPULAYOUT_FINGERPRINT:-}"
}

CPU_TOPOLOGIA_ERRO=""
CPU_TOPOLOGIA_FINGERPRINT=""
CPU_TOPOLOGIA_ONLINE=""
cpu_topologia_fingerprint() {
    # Publica o fingerprint canônico da topologia recebida (ou lida agora).
    # Reordenar linhas do lscpu não muda o valor; mudar o conjunto online ou o
    # agrupamento de siblings muda. É a base da recusa por conflito TOCTOU.
    local topologia="${1:-}"
    local -a permitidas=(
        "${CORE_PARES_ENVELOPE[@]}"
        VALID ERROR ONLINE_COUNT ONLINE_SET CORE_COUNT SOCKET_COUNT
        THREADS_PER_CORE HOMOGENEOUS BOOT_CORE BOOT_CORE_CPUS FINGERPRINT
    )
    local -a payload=()
    CPU_TOPOLOGIA_ERRO=""
    CPU_TOPOLOGIA_FINGERPRINT=""
    CPU_TOPOLOGIA_ONLINE=""
    if [ -z "$topologia" ]; then
        topologia="$(cpu_topologia_csv)" \
            || { CPU_TOPOLOGIA_ERRO="lscpu não conseguiu fornecer a topologia parseável."; return 1; }
    fi
    [ -n "$topologia" ] \
        || { CPU_TOPOLOGIA_ERRO="A topologia de CPU está vazia."; return 1; }
    payload=(csv "$topologia")
    if ! python_core_pares_payload permitidas CPUTOPO_ cpu-topology payload \
            2>/dev/null; then
        CPU_TOPOLOGIA_ERRO="$(_core_diagnostico 'Não foi possível canonicalizar a topologia de CPU.')"
        return 1
    fi
    if [ "${CPUTOPO_VALID:-0}" != 1 ]; then
        CPU_TOPOLOGIA_ERRO="${CPUTOPO_ERROR:-Topologia de CPU recusada pelo core.}"
        return 1
    fi
    CPU_TOPOLOGIA_FINGERPRINT="${CPUTOPO_FINGERPRINT:-}"
    CPU_TOPOLOGIA_ONLINE="${CPUTOPO_ONLINE_SET:-}"
}

CPU_PLANO_ERRO=""
cpu_plano_pinning() {
    # cpu_plano_pinning CSV [CORES_VM]
    # Sem CORES_VM devolve apenas os limites (para a pergunta ao operador);
    # com CORES_VM devolve a proposta determinística já validada. As variáveis
    # publicadas usam o prefixo CPUPLANO_.
    local topologia="${1:-}" cores_vm="${2:-}"
    local -a permitidas=(
        "${CORE_PARES_ENVELOPE[@]}"
        VALID ERROR TOTAL_CORES THREADS_PER_CORE MAX_VM_CORES DEFAULT_VM_CORES
        BOOT_CORE BOOT_CORE_CPUS ONLINE_SET FINGERPRINT PLANNED CPUS_VM
        CPUS_HOST VCPUS VM_CORES HOST_CORE_COUNT
    )
    local -a payload=()
    CPU_PLANO_ERRO=""
    if [ -z "$topologia" ]; then
        topologia="$(cpu_topologia_csv)" \
            || { CPU_PLANO_ERRO="lscpu não conseguiu fornecer a topologia parseável."; return 1; }
    fi
    [ -n "$topologia" ] \
        || { CPU_PLANO_ERRO="A topologia de CPU está vazia."; return 1; }
    payload=(csv "$topologia" vm_cores "$cores_vm")
    if ! python_core_pares_payload permitidas CPUPLANO_ cpu-plan payload \
            2>/dev/null; then
        CPU_PLANO_ERRO="$(_core_diagnostico 'Não foi possível calcular o plano de pinning.')"
        return 1
    fi
    if [ "${CPUPLANO_VALID:-0}" != 1 ]; then
        CPU_PLANO_ERRO="${CPUPLANO_ERROR:-Plano de pinning recusado pelo core.}"
        return 1
    fi
}

CPU_MEMORIA_ERRO=""
plano_memoria_vm() {
    # plano_memoria_vm TOTAL_MIB [VM_RAM_MIB] [HUGEPAGES_1G]
    # Reserva do host, teto da VM e relação RAM/HugePages em um único lugar.
    # Publica CPUMEM_TOTAL_MIB, CPUMEM_RESERVE_MIB, CPUMEM_MAX_VM_MIB,
    # CPUMEM_MAX_VM_GIB e CPUMEM_HUGEPAGES_1G.
    local total="${1:-}" vm_ram="${2:-}" hugepages="${3:-}"
    local -a permitidas=(
        "${CORE_PARES_ENVELOPE[@]}"
        VALID ERROR TOTAL_MIB RESERVE_MIB MAX_VM_MIB MAX_VM_GIB CHECKED
        VM_RAM_MIB HUGEPAGES_1G
    )
    local -a payload=()
    CPU_MEMORIA_ERRO=""
    payload=(
        total_mib "$total"
        vm_ram_mib "$vm_ram"
        hugepages_1g "$hugepages"
    )
    if ! python_core_pares_payload permitidas CPUMEM_ cpu-memory payload \
            2>/dev/null; then
        CPU_MEMORIA_ERRO="$(_core_diagnostico 'Não foi possível calcular o plano de memória.')"
        return 1
    fi
    if [ "${CPUMEM_VALID:-0}" != 1 ]; then
        CPU_MEMORIA_ERRO="${CPUMEM_ERROR:-Plano de memória recusado pelo core.}"
        return 1
    fi
}

# --- Fotografia de recursos dedicados (REQ-VM-RESOURCE-LIFECYCLE, I9.12) ------
# Observação pura do host, no formato fechado que o módulo de recursos do core
# interpreta: um fato por linha, campos separados por TAB. A
# captura passa por caminho_sistema, então a suíte encena sysfs e /proc numa
# raiz temporária e o mesmo código roda contra host real e contra fixture.
#
# Por que a fotografia é TEXTO e não um punhado de variáveis: o número de pools
# e de nós NUMA varia por máquina, e transportar isso pelo canal de pares
# exigiria chave indexada para cada combinação. O core recebe o texto, valida o
# formato inteiro e recusa o que não reconhece.

recursos_fotografar() {
    # recursos_fotografar -> escreve a fotografia em stdout. Não muta nada.
    local base_pools node_dir tamanho campo arquivo valor node_id
    local meminfo boot_id_arq thp_dir

    base_pools="$(caminho_sistema /sys/kernel/mm/hugepages 2>/dev/null || true)"
    meminfo="$(caminho_sistema /proc/meminfo 2>/dev/null || true)"
    boot_id_arq="$(caminho_sistema /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
    thp_dir="$(caminho_sistema /sys/kernel/mm/transparent_hugepage 2>/dev/null || true)"
    node_dir="$(caminho_sistema /sys/devices/system/node 2>/dev/null || true)"

    if [ -n "$boot_id_arq" ] && [ -r "$boot_id_arq" ]; then
        IFS= read -r valor < "$boot_id_arq" || valor=""
        # O boot ID é identidade de máquina ligada, não segredo, mas também não
        # é texto livre: só o formato UUID entra na fotografia.
        case "$valor" in
            [0-9a-f]*-*-*-*-*) printf 'boot_id\t%s\n' "$valor" ;;
        esac
    fi

    # Pools de página grande, um bloco por tamanho.
    if [ -n "$base_pools" ] && [ -d "$base_pools" ]; then
        for arquivo in "$base_pools"/hugepages-*; do
            [ -d "$arquivo" ] || continue
            tamanho="${arquivo##*/hugepages-}"
            tamanho="${tamanho%kB}"
            case "$tamanho" in
                ''|*[!0-9]*) continue ;;
            esac
            for campo in nr_hugepages free_hugepages resv_hugepages surplus_hugepages; do
                [ -r "$arquivo/$campo" ] || continue
                IFS= read -r valor < "$arquivo/$campo" || continue
                case "$valor" in
                    ''|*[!0-9]*) continue ;;
                esac
                printf 'pool\t%s\t%s\t%s\n' "$tamanho" "${campo%%_*}" "$valor"
            done
        done
    fi

    # Contadores por nó NUMA. Sem eles o core recusa planejar em host de mais de
    # um nó, que é o comportamento exigido pelo requisito.
    local nodes=0
    if [ -n "$node_dir" ] && [ -d "$node_dir" ]; then
        for arquivo in "$node_dir"/node[0-9]*; do
            [ -d "$arquivo" ] || continue
            node_id="${arquivo##*/node}"
            case "$node_id" in
                ''|*[!0-9]*) continue ;;
            esac
            nodes=$((nodes + 1))
            local pool_node
            for pool_node in "$arquivo"/hugepages/hugepages-*; do
                [ -d "$pool_node" ] || continue
                tamanho="${pool_node##*/hugepages-}"
                tamanho="${tamanho%kB}"
                case "$tamanho" in
                    ''|*[!0-9]*) continue ;;
                esac
                for campo in nr_hugepages free_hugepages; do
                    [ -r "$pool_node/$campo" ] || continue
                    IFS= read -r valor < "$pool_node/$campo" || continue
                    case "$valor" in
                        ''|*[!0-9]*) continue ;;
                    esac
                    printf 'node\t%s\t%s\t%s\t%s\n' \
                        "$node_id" "$tamanho" "${campo%%_*}" "$valor"
                done
            done
        done
    fi
    [ "$nodes" -gt 0 ] && printf 'nodes\t%s\n' "$nodes"

    # Só os campos de /proc/meminfo que o plano usa. Copiar o arquivo inteiro
    # colocaria dado do host que ninguém valida dentro do payload do core.
    if [ -n "$meminfo" ] && [ -r "$meminfo" ]; then
        local linha nome unidade
        while IFS= read -r linha; do
            case "$linha" in
                'MemTotal:'*|'MemFree:'*|'MemAvailable:'*|'Hugetlb:'*|'AnonHugePages:'*)
                    # A separação é por espaço em branco, com `read`, e não por
                    # expansão de parâmetro: /proc/meminfo alinha o valor com
                    # uma quantidade variável de espaços, e `${v## }` remove
                    # apenas UM (o padrão casa um caractere), o que fazia todo
                    # o bloco ser descartado pela checagem de dígito.
                    read -r nome valor unidade <<< "$linha"
                    nome="${nome%:}"
                    case "$valor" in
                        ''|*[!0-9]*) continue ;;
                    esac
                    [ "$unidade" = kB ] || continue
                    printf 'meminfo\t%s\t%s\n' "$nome" "$valor"
                    ;;
            esac
        done < "$meminfo"
    fi

    if [ -n "$thp_dir" ] && [ -d "$thp_dir" ]; then
        for campo in enabled defrag; do
            [ -r "$thp_dir/$campo" ] || continue
            IFS= read -r valor < "$thp_dir/$campo" || continue
            # O kernel publica "always [madvise] never"; o valor efetivo é o que
            # está entre colchetes, e é ele que interessa ao plano.
            case "$valor" in
                *'['*']'*)
                    valor="${valor#*[}"
                    valor="${valor%%]*}"
                    ;;
            esac
            case "$valor" in
                ''|*[!a-z_-]*) continue ;;
            esac
            printf 'thp\t%s\t%s\n' "$campo" "$valor"
        done
    fi
    return 0
}
