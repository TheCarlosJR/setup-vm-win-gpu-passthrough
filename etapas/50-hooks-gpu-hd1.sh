#!/bin/bash
# ============================================================================
# etapas/50-hooks-gpu-hd1.sh - Etapa 14: GPU dinâmica + HD1 opcional
# ============================================================================
# O libvirt (hostdev managed='yes') é a única autoridade para detach/reattach
# PCI. Os hooks apenas fazem preflight, liberam/restauram a sessão gráfica e
# conferem as pós-condições. Nenhum hook escreve em bind/unbind/new_id.
# O HD1 físico é opcional: HD1_DISPENSADO=sim mantém a VM somente no QCOW2.
#
# Uso:
#   50-hooks-gpu-hd1.sh                         instala/atualiza hooks e XML;
#       com TTY, GPU já no XML e vídeo virtual QXL/SPICE ainda presente,
#       oferece a remoção interativamente (padrão do menu)
#   50-hooks-gpu-hd1.sh --verificar             verifica sem alterar
#   50-hooks-gpu-hd1.sh --renderizar-hooks DIR_EXISTENTE  renderiza/valida
#   50-hooks-gpu-hd1.sh [--remover-video] [--anti-code43]
#       aplica o fluxo normal e, ao final, os submodos solicitados.
#
# Falha ou cancelamento durante a transação restaura hooks/XML automaticamente.
# Recuperar a GPU no host não desfaz a configuração persistente; após sucesso,
# a reversão exige restaurar os backups de XML/hooks em janela de manutenção.
# ============================================================================
SCRIPT_VERSION="1.2.0"
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

HOOK_QEMU="/etc/libvirt/hooks/qemu"
HOOK_BASE="/etc/libvirt/hooks/qemu.d/${VM_NAME:-nao-configurada}"
PREPARE="$HOOK_BASE/prepare/begin/01-gpu-preflight.sh"
START="$HOOK_BASE/start/begin/01-gpu-vfio-check.sh"
RELEASE="$HOOK_BASE/release/end/01-gpu-restore.sh"
GATE_REQUIRED="$HOOK_BASE/.vm-passthrough-required"
INSTALLING_MARKER="$HOOK_BASE/.vm-passthrough-installing"
INSTALLING_HOOK="$HOOK_BASE/prepare/begin/00-vm-passthrough-installing.sh"
PREPARE_ANTIGO="$HOOK_BASE/prepare/begin/01-gpu-para-vfio.sh"
RELEASE_ANTIGO="$HOOK_BASE/release/end/01-gpu-para-linux.sh"
NVIDIA_UDEV_FILTRO="/usr/local/sbin/vm-passthrough-nvidia-udev"
NVIDIA_UDEV_REGRAS="/etc/udev/rules.d/71-nvidia.rules"
MARCADOR_UDEV="# vm-passthrough-nvidia-udev-v1"
MARCADOR_DISPATCHER="# vm-passthrough-qemu-dispatcher-v2"
# I9.9 (REQ-VERIFY-FAILCLOSED): marcadores de conteúdo dos hooks gerados. Um
# arquivo com apenas `#!/bin/bash` é executável e passa em `bash -n`, então
# `[ -x ] && bash -n` aprovava hook vazio, truncado ou de outra geração. Cada
# hook só é dado por provado quando o cabeçalho desta versão está legível nele.
MARCADOR_HOOK_PREPARE='^# Hook prepare/begin: preflight fail-closed'
MARCADOR_HOOK_START='^# Hook start/begin: confere o detach gerenciado'
MARCADOR_HOOK_RELEASE='^# Hook release/end: valida reattach gerenciado'
MARCADOR_GATE_REQUIRED='^vm-passthrough gate obrigatório para '
# As regras da distro escrevem o modprobe em três grafias conhecidas
# (`/sbin/modprobe`, `/usr/sbin/modprobe` e `modprobe` nu). Reconhecer só a
# primeira fazia um host das outras duas ser relatado como "sem regras udev",
# isto é, falso sucesso justamente no host em que o laço existe.
NVIDIA_UDEV_PADRAO_MODPROBE='RUN[+]="[^"]*modprobe'
STAMP="$(date +%Y%m%d-%H%M%S)-$$"

# Inspeção do XML de domínio vem do core Python pela ponte única: cardinalidade
# explícita, comparação hexadecimal de BDF independente de formatação e nenhum
# dado local em argv. As funções mantêm os nomes e as variáveis já consumidas
# pelo resto desta etapa.

HOSTDEV_TOTAL=""
HOSTDEV_EXATO=""
hostdev_estado_xml() {
    local endereco="${1,,}"
    local -a permitidas=("${CORE_PARES_ENVELOPE[@]}" TOTAL EXACT MANAGED)
    local -a payload=()
    XML_CONTEUDO="$($VIRSH dumpxml --inactive "$VM_NAME" 2>/dev/null)" || return 1
    payload=(xml "$XML_CONTEUDO" pci_address "$endereco")
    python_core_pares_payload permitidas HD_PCI_ domain-hostdev-pci payload \
        2>/dev/null || return 1
    HOSTDEV_TOTAL="$HD_PCI_TOTAL"
    HOSTDEV_EXATO="$HD_PCI_EXACT"
}

DISCO_XML_SOURCE=""
DISCO_XML_EXATO=""
DISCO_XML_VDB=""
disco_estado_xml() {
    local caminho="$1"
    local -a permitidas=(
        "${CORE_PARES_ENVELOPE[@]}" SOURCE_COUNT EXACT_COUNT TARGET_COUNT IDENTITY_COUNT
    )
    local -a payload=()
    XML_CONTEUDO="$($VIRSH dumpxml --inactive "$VM_NAME" 2>/dev/null)" || return 1
    payload=(xml "$XML_CONTEUDO" block_path "$caminho" target_dev vdb)
    python_core_pares_payload permitidas DISCOXML_ domain-disk-block payload \
        2>/dev/null || return 1
    DISCO_XML_SOURCE="$DISCOXML_SOURCE_COUNT"
    DISCO_XML_EXATO="$DISCOXML_EXACT_COUNT"
    DISCO_XML_VDB="$DISCOXML_TARGET_COUNT"
}

estado_video_virtual() {
    # 0 = vídeo virtual QXL/SPICE ainda presente; 1 = já removido;
    # 2 = indeterminado. Escreve apenas em temporários; não toca o domínio.
    local origem candidato rc=2
    origem="$(mktemp)" || return 2
    candidato="$(mktemp)" || { rm -f -- "$origem"; return 2; }
    if $VIRSH dumpxml --inactive "$VM_NAME" > "$origem" 2>/dev/null \
            && xml_candidato_sem_video "$origem" "$candidato"; then
        if [ "$XML_CANDIDATO_MUDOU" = 1 ]; then rc=0; else rc=1; fi
    fi
    rm -f -- "$origem" "$candidato"
    return "$rc"
}

nvidia_udev_origem() {
    # Caminho do arquivo de regras da distro que dispara modprobe direto.
    # I9.9 (REQ-VERIFY-FAILCLOSED): tri-estado, porque o retorno 1 único fundia
    # "li os candidatos e nenhum dispara modprobe" com "não consegui ler", e o
    # chamador transformava as duas coisas em `v_ok`.
    #   0 = há regra que dispara modprobe (caminho no stdout);
    #   1 = candidatos observados e nenhum dispara;
    #   2 = não foi possível observar (grep ausente ou arquivo ilegível).
    local candidato
    if ! command -v grep >/dev/null 2>&1; then
        return 2
    fi
    # O grep continua sendo quem decide o CONTEÚDO: um teste de arquivo embutido
    # no shell leria o sistema real mesmo sob sandbox, e as duas leituras podiam
    # discordar. Os testes de arquivo abaixo só entram no ramo em que o grep já
    # não casou, para separar "não tem regra" de "não deu para ler".
    for candidato in /usr/lib/udev/rules.d/71-nvidia.rules /lib/udev/rules.d/71-nvidia.rules; do
        if LC_ALL=C grep -Eq "$NVIDIA_UDEV_PADRAO_MODPROBE" "$candidato" 2>/dev/null; then
            printf '%s\n' "$candidato"
            return 0
        fi
        if [ -e "$candidato" ] && [ ! -r "$candidato" ]; then
            return 2
        fi
    done
    return 1
}

gerar_nvidia_udev_filtro() {
    # D-GPU-UDEV-LOOP: as regras da distro rodam modprobe nvidia-modeset/-drm/
    # -uvm a cada evento add/remove em /bus/pci/drivers/nvidia. Com a GPU no
    # vfio-pci esse modprobe puxa o módulo nvidia, que não consegue sondar a
    # GPU e é descarregado, o que gera outro evento no mesmo caminho: um laço
    # que se realimenta. Ele atravessa o release, derruba nvidia_drm com o
    # desktop já aberto e congela o host. Este filtro decide pelo estado real
    # do barramento se o modprobe faz sentido; os hooks continuam sendo a
    # única autoridade sobre os módulos.
    local destino="$1"
    cat > "$destino" <<'FILTRO'
#!/bin/bash
# vm-passthrough-nvidia-udev-v1 (gerado por etapas/50-hooks-gpu-hd1.sh)
# Filtra os modprobe disparados pelas regras udev da NVIDIA.
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin

ACAO="${1:-}"
MODULO="${2:-}"
case "$ACAO" in
    load|unload) ;;
    *) exit 0 ;;
esac
case "$MODULO" in
    nvidia-modeset|nvidia-drm|nvidia-uvm) ;;
    *) exit 0 ;;
esac

EM_VFIO=0
EM_NVIDIA=0
for DISPOSITIVO in /sys/bus/pci/devices/*; do
    [ -r "$DISPOSITIVO/vendor" ] && [ -r "$DISPOSITIVO/class" ] || continue
    [ "$(cat "$DISPOSITIVO/vendor" 2>/dev/null)" = 0x10de ] || continue
    case "$(cat "$DISPOSITIVO/class" 2>/dev/null)" in
        0x03*) ;;
        *) continue ;;
    esac
    [ -L "$DISPOSITIVO/driver" ] || continue
    case "$(basename -- "$(readlink -f -- "$DISPOSITIVO/driver")")" in
        vfio-pci) EM_VFIO=1 ;;
        nvidia) EM_NVIDIA=1 ;;
    esac
done

# Janela vfio: a GPU é da VM e qualquer modprobe aqui só alimenta o laço.
if [ "$EM_VFIO" -eq 1 ]; then
    exit 0
fi

if [ "$ACAO" = load ]; then
    # Carregar segue permitido fora da janela vfio: é por estas regras que o
    # host ganha nvidia_drm modeset=1 no boot, e não há softdep que faça isso.
    exec modprobe -- "$MODULO"
fi

# Descarregar com a GPU viva no nvidia mata a sessão gráfica em uso: é
# exatamente o que a tempestade fazia depois do release.
if [ "$EM_NVIDIA" -eq 1 ]; then
    exit 0
fi
exec modprobe -r -- "$MODULO"
FILTRO
}

gerar_nvidia_udev_regras() {
    # Reescreve as regras da distro trocando o modprobe direto pelo filtro.
    # Mesmo nome em /etc sombreia o arquivo de /usr/lib inteiro, então tudo o
    # que não é modprobe é copiado byte a byte: seat/master-of-seat,
    # ub-device-create, persistenced e runtime PM continuam valendo. Derivar do
    # arquivo da distro (em vez de fixar um conteúdo) faz uma atualização do
    # pacote NVIDIA aparecer como divergência em --verificar.
    # As três grafias conhecidas do modprobe são tratadas juntas: reconhecer só
    # `/sbin/modprobe` deixava a origem detectada e a conversão impossível nos
    # hosts que usam `/usr/sbin/modprobe` ou `modprobe` nu.
    local origem="$1" destino="$2" corpo linhas_origem linhas_corpo trocas restantes
    corpo="$(sed -E \
        -e "s|RUN[+]=\"(/usr)?(/s?bin/)?modprobe -r ([A-Za-z0-9_-]+)\"|RUN+=\"$NVIDIA_UDEV_FILTRO unload \3\"|g" \
        -e "s|RUN[+]=\"(/usr)?(/s?bin/)?modprobe ([A-Za-z0-9_-]+)\"|RUN+=\"$NVIDIA_UDEV_FILTRO load \3\"|g" \
        -- "$origem")" || return 1
    linhas_origem="$(sed -n '$=' -- "$origem")" || return 1
    linhas_corpo="$(printf '%s\n' "$corpo" | sed -n '$=')" || return 1
    [ -n "$linhas_origem" ] && [ "$linhas_corpo" = "$linhas_origem" ] || return 1
    trocas="$(printf '%s\n' "$corpo" | grep -cF "$NVIDIA_UDEV_FILTRO " || true)"
    [ "${trocas:-0}" -ge 1 ] || return 1
    restantes="$(printf '%s\n' "$corpo" | grep -cE "$NVIDIA_UDEV_PADRAO_MODPROBE" || true)"
    [ "${restantes:-0}" -eq 0 ] || return 1
    {
        printf '%s\n' "$MARCADOR_UDEV"
        printf '# Gerado por etapas/50-hooks-gpu-hd1.sh a partir de %s.\n' "$origem"
        printf '# Não edite à mão: a etapa 14 regenera o arquivo e acusa divergência.\n'
        printf '# O único desvio em relação ao original é o filtro do modprobe, em %s.\n' "$NVIDIA_UDEV_FILTRO"
        printf '%s\n' "$corpo"
    } > "$destino"
}

verificar_hook() {
    # I9.9 (REQ-VERIFY-FAILCLOSED): `[ -x ] && bash -n` aprovava um arquivo que
    # contém só `#!/bin/bash`. A prova agora é de conteúdo desta geração
    # (v_prova_arquivo --exec --marcador); sintaxe quebrada em arquivo que TEM o
    # cabeçalho é estado observado e errado, portanto erro, nunca pendência.
    local arquivo="$1" descricao="$2" marcador="$3"
    if [ -f "$arquivo" ] && [ -r "$arquivo" ] && ! bash -n "$arquivo" 2>/dev/null; then
        v_erro "$descricao presente mas com sintaxe inválida ($arquivo); reexecute a etapa 14."
        return 3
    fi
    v_prova_arquivo "$arquivo" "$descricao" --exec --marcador "$marcador"
}

verificar_filtro_udev() {
    # D-GPU-UDEV-LOOP: sem este filtro o release "conclui com sucesso" e o
    # desktop congela segundos depois, porque os módulos nvidia continuam
    # recarregando em laço. A ausência é falta, não observação.
    local origem="" esperado="" origem_rc=0
    origem="$(nvidia_udev_origem)" || origem_rc=$?
    if [ "$origem_rc" -eq 2 ]; then
        # I9.9 (REQ-VERIFY-FAILCLOSED): antes, QUALQUER falha do grep (arquivo
        # ilegível, grep ausente, outra grafia de modprobe) caía no mesmo ramo
        # de "host sem regras" e virava v_ok. Não observar nunca é sucesso.
        v_indeterminado "Regras udev da NVIDIA da distro não puderam ser lidas (arquivo presente e ilegível, ou grep indisponível); o laço de modprobe não pôde ser descartado."
        return 0
    fi
    if [ "$origem_rc" -ne 0 ]; then
        v_ok "Host sem regras udev da NVIDIA que disparem modprobe; nenhum filtro é necessário."
        return 0
    fi
    if ! verificar_hook "$NVIDIA_UDEV_FILTRO" "Filtro de modprobe das regras udev" \
            "$MARCADOR_UDEV"; then
        info "Sem o filtro, os módulos nvidia recarregam em laço na janela vfio e o desktop congela após desligar a VM."
    fi
    esperado="$(mktemp)" || { v_indeterminado "Sem temporário para derivar as regras udev esperadas."; return 0; }
    if ! gerar_nvidia_udev_regras "$origem" "$esperado" 2>/dev/null; then
        rm -f -- "$esperado"
        v_indeterminado "Não foi possível derivar as regras udev esperadas a partir de $origem."
        return 0
    fi
    if [ ! -e "$NVIDIA_UDEV_REGRAS" ]; then
        v_falta "Override das regras udev da NVIDIA ausente: $NVIDIA_UDEV_REGRAS"
    elif [ ! -f "$NVIDIA_UDEV_REGRAS" ]; then
        v_erro "Override das regras udev da NVIDIA não é arquivo regular: $NVIDIA_UDEV_REGRAS"
    elif [ ! -r "$NVIDIA_UDEV_REGRAS" ]; then
        # `cmp -s` devolve 2 para arquivo ilegível, e o ramo `else` chamava isso
        # de divergência: estado não observado sendo relatado como observado.
        v_indeterminado "Override das regras udev existe mas não é legível; a convergência com $origem não pôde ser comprovada ($NVIDIA_UDEV_REGRAS)."
    elif cmp -s -- "$esperado" "$NVIDIA_UDEV_REGRAS"; then
        v_ok "Override das regras udev da NVIDIA em dia com $origem."
    else
        v_falta "Override em $NVIDIA_UDEV_REGRAS divergente de $origem (a distro atualizou as regras); reexecute a etapa 14."
    fi
    rm -f -- "$esperado"
}

verificar() {
    [ -n "${VM_NAME:-}" ] || { v_falta "VM_NAME não definido."; v_fim; }
    local prep="/etc/libvirt/hooks/qemu.d/$VM_NAME/prepare/begin/01-gpu-preflight.sh"
    local inicio="/etc/libvirt/hooks/qemu.d/$VM_NAME/start/begin/01-gpu-vfio-check.sh"
    local release="/etc/libvirt/hooks/qemu.d/$VM_NAME/release/end/01-gpu-restore.sh"
    local obrigatorio="/etc/libvirt/hooks/qemu.d/$VM_NAME/.vm-passthrough-required"
    if [ -x "$HOOK_QEMU" ] && grep -qF "$MARCADOR_DISPATCHER" "$HOOK_QEMU" 2>/dev/null \
       && bash -n "$HOOK_QEMU" 2>/dev/null; then
        v_ok "Dispatcher gerenciado v2 instalado e válido."
    else
        v_falta "Dispatcher v2 ausente ou incompatível."
    fi
    verificar_hook "$prep" "Hook prepare/begin" "$MARCADOR_HOOK_PREPARE" || true
    verificar_hook "$inicio" "Hook start/begin" "$MARCADOR_HOOK_START" || true
    verificar_hook "$release" "Hook release/end" "$MARCADOR_HOOK_RELEASE" || true
    # I9.9 (REQ-VERIFY-FAILCLOSED): o teste de geração ficava dentro de um
    # `if [ -f ] && [ -r ]` SEM else, então release ilegível não emitia nada e
    # sumia do relatório; e `grep -q '^HOOK_LOG_DIR='` aprovava qualquer valor,
    # inclusive um diretório editado à mão. Agora a ausência continua sendo
    # reportada só por verificar_hook, ilegível é indeterminado e o conteúdo é
    # comparado com as linhas exatas que emitir_hook_log_fn gera.
    if [ ! -e "$release" ]; then
        :
    elif [ ! -r "$release" ]; then
        v_indeterminado "Hook release/end existe mas não é legível; a geração instalada não pôde ser comprovada ($release)."
    elif LC_ALL=C grep -qxF 'HOOK_LOG_DIR=/var/log/vm-passthrough' "$release" 2>/dev/null \
         && LC_ALL=C grep -qxF 'HOOK_LOG_ARQUIVO="$HOOK_LOG_DIR/hooks.log"' "$release" 2>/dev/null \
         && LC_ALL=C grep -qxF "$(printf 'HOOK_VERSAO=%q' "$SCRIPT_VERSION")" \
              "$release" 2>/dev/null; then
        v_ok "Hooks com log persistente de retomada em /var/log/vm-passthrough/hooks.log."
    else
        v_falta "Hooks instalados são de geração antiga (versão diferente de $SCRIPT_VERSION, ou sem log persistente e retomada reforçada do desktop); reexecute a etapa 14 para atualizá-los."
    fi
    # Um marcador que o hook não consegue ler não é fail-closed: legibilidade e
    # conteúdo passaram a ser provados, no lugar do `[ -f ]` isolado.
    v_prova_arquivo "$obrigatorio" "Marcador fail-closed do gate" \
        --marcador "$MARCADOR_GATE_REQUIRED" || true
    # A ausência do marcador de transação só prova alguma coisa se o diretório
    # de hooks existir e for legível: sem isso, "não há marcador" era apenas o
    # efeito de a etapa nunca ter rodado.
    local dir_hooks="/etc/libvirt/hooks/qemu.d/$VM_NAME"
    if [ -e "$dir_hooks/.vm-passthrough-installing" ]; then
        v_falta "Marcador de transação interrompida ainda existe; starts permanecem bloqueados."
    elif [ ! -d "$dir_hooks" ]; then
        v_falta "Diretório de hooks da VM ainda não existe ($dir_hooks); não há transação de instalação a avaliar."
    elif [ ! -r "$dir_hooks" ] || [ ! -x "$dir_hooks" ]; then
        v_indeterminado "Diretório de hooks $dir_hooks não é percorrível; a ausência do marcador de transação não pôde ser comprovada."
    else
        v_ok "Nenhuma transação de instalação pendente bloqueia a VM."
    fi

    verificar_filtro_udev
    local vm_estado=0
    vm_existe_estado "$VM_NAME" || vm_estado=$?
    if [ "$vm_estado" -eq 0 ]; then
        local gpu_no_xml=0 video_estado=2
        if [ -n "${GPU_PCI_ID:-}" ] && hostdev_estado_xml "$GPU_PCI_ID" \
           && [ "$HOSTDEV_TOTAL" = 1 ] && [ "$HOSTDEV_EXATO" = 1 ]; then
            v_ok "GPU $GPU_PCI_ID anexada exatamente uma vez com managed='yes'."
            gpu_no_xml=1
        else
            v_falta "GPU ausente, duplicada ou sem managed='yes' no XML."
        fi
        if [ "$gpu_no_xml" -eq 1 ]; then
            if estado_video_virtual; then video_estado=0; else video_estado=$?; fi
            case "$video_estado" in
                0) v_falta "Vídeo virtual QXL/SPICE ainda presente: ele é o monitor primário invisível do Windows (janelas abrem fora da tela física). Após validar um boot com a GPU, rode a etapa 14 e confirme a remoção." ;;
                1) v_ok "Vídeo virtual QXL/SPICE removido; a GPU real é a única saída gráfica." ;;
                *) v_indeterminado "Não foi possível avaliar o vídeo virtual no XML." ;;
            esac
        fi
        if [ -z "${GPU_AUDIO_PCI_ID:-}" ]; then
            v_ok "GPU sem função de áudio configurada."
        elif hostdev_estado_xml "$GPU_AUDIO_PCI_ID" \
             && [ "$HOSTDEV_TOTAL" = 1 ] && [ "$HOSTDEV_EXATO" = 1 ]; then
            v_ok "Áudio $GPU_AUDIO_PCI_ID anexado exatamente uma vez com managed='yes'."
        else
            v_falta "Áudio da GPU ausente, duplicado ou sem managed='yes' no XML."
        fi
        if [ -n "${HD1_BY_ID_PATH:-}" ] && [ "${HD1_DISPENSADO:-}" = "sim" ]; then
            # Alinhado a etapas/14-working-disk.sh e etapas/61-airlock.sh: a
            # mesma classe de contradição de dispensa é erro (rc 3), não
            # pendência. Reexecutar a etapa não resolve config contraditória.
            v_erro "Configuração contraditória: HD1 definido e dispensado ao mesmo tempo."
        elif [ -z "${HD1_BY_ID_PATH:-}" ] && [ "${HD1_DISPENSADO:-}" = "sim" ]; then
            v_ok "Fluxo sem disco físico dedicado (opção 0 registrada)."
        elif [ -z "${HD1_BY_ID_PATH:-}" ]; then
            v_falta "Uso do HD1 ainda não decidido na etapa 3."
        elif disco_estado_xml "$HD1_BY_ID_PATH" \
             && [ "$DISCO_XML_SOURCE" = 1 ] && [ "$DISCO_XML_EXATO" = 1 ]; then
            if ! validar_disco_fisico_vm "$HD1_BY_ID_PATH" "${NVME_DEVICE:-}"; then
                v_falta "$DISCO_VM_ERRO"
            elif [ -z "${SYSTEM_DISK_FINGERPRINT:-}" ] || [ -z "${HD1_DISK_FINGERPRINT:-}" ]; then
                v_indeterminado "Identidades físicas I6 de sistema/HD1 ausentes; execute a etapa 3 com --redetectar."
            elif inventario_revalidar_papeis_disco_configurados; then
                v_ok "HD1 exato no XML, livre e com identidade física I6 convergida: $HD1_BY_ID_PATH."
            else
                v_falta "Identidade física do HD1 recusada: $INVENTARIO_ERRO"
            fi
        else
            v_falta "HD1 ausente, duplicado ou com atributos diferentes dos autorizados."
        fi
    elif [ "$vm_estado" -eq 1 ]; then
        v_falta "VM '$VM_NAME' não existe."
    else
        v_indeterminado "Estado da VM '$VM_NAME' não pôde ser observado: ${VM_EXISTE_MOTIVO:-sem diagnóstico}."
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

guard_mutation hooks.configure || exit 1

validar_config_hooks() {
    exigir_conf VM_NAME GPU_PCI_ID GPU_VENDOR_DEVICE_ID DM_SERVICE IOMMU_GROUP_GPU
    nome_vm_valido "$VM_NAME" || falhar "VM_NAME inseguro: '$VM_NAME'."
    pci_bdf_valido "$GPU_PCI_ID" || falhar "GPU_PCI_ID inválido: '$GPU_PCI_ID'."
    pci_vendor_device_valido "$GPU_VENDOR_DEVICE_ID" || falhar "GPU_VENDOR_DEVICE_ID inválido."
    inteiro_na_faixa "$IOMMU_GROUP_GPU" 0 65535 || falhar "IOMMU_GROUP_GPU inválido."
    nome_unidade_systemd_valido "$DM_SERVICE" || falhar "DM_SERVICE inválido: '$DM_SERVICE'."
    if [ -n "${GPU_AUDIO_PCI_ID:-}" ]; then
        pci_bdf_valido "$GPU_AUDIO_PCI_ID" || falhar "GPU_AUDIO_PCI_ID inválido."
        exigir_conf GPU_AUDIO_VENDOR_DEVICE_ID
        pci_vendor_device_valido "$GPU_AUDIO_VENDOR_DEVICE_ID" || falhar "GPU_AUDIO_VENDOR_DEVICE_ID inválido."
    fi
    if [ -n "${HD1_BY_ID_PATH:-}" ] && [ "${HD1_DISPENSADO:-}" = "sim" ]; then
        falhar "Configuração contraditória: HD1_BY_ID_PATH definido e HD1_DISPENSADO=sim."
    elif [ -n "${HD1_BY_ID_PATH:-}" ]; then
        caminho_absoluto_seguro "$HD1_BY_ID_PATH" || falhar "HD1_BY_ID_PATH inseguro."
        exigir_conf NVME_DEVICE
    elif [ "${HD1_DISPENSADO:-}" != "sim" ]; then
        falhar "Uso do disco físico adicional ainda não foi decidido. Rode a etapa 3 e escolha um disco ou a opção 0."
    fi
}

emitir_hook_memoria_fn() {
    # Insere nos hooks o ciclo de vida da memória dedicada
    # (REQ-VM-RESOURCE-LIFECYCLE, I9.12). Sai nos DOIS hooks a partir desta
    # fonte única: prepare adquire, release devolve, e as duas metades têm de
    # concordar sobre formato de estado e aritmética.
    #
    # Por que a aritmética é Bash puro aqui, e não uma chamada ao core: o hook
    # precisa continuar autossuficiente e independente do checkout (decisão
    # I9-D8, provada por tests/test-i9-hooks-isolados.sh, que APAGA o projeto
    # antes de executar os hooks). O core é o planejador e o validador usados
    # pela etapa e pelo gate; o hook é a autoridade de runtime. Que as duas
    # implementações concordem é obrigação de teste diferencial, não de fé.
    local rotulo="$1"
    printf 'MEMORIA_MODO=%q\n' "${MEMORIA_MODO:-normal}"
    printf 'MEM_PAGE_KB=%q\n' "${MEM_PAGE_KB:-0}"
    printf 'MEM_PAGES_NEEDED=%q\n' "${MEM_PAGES_NEEDED:-0}"
    printf 'MEM_ROTULO=%q\n' "$rotulo"
    cat <<'HOOKMEM'
MEM_STATE_DIR=/var/lib/vm-passthrough
MEM_STATE_FILE="$MEM_STATE_DIR/${VM_NAME}.memoria"
MEM_POOL_DIR="/sys/kernel/mm/hugepages/hugepages-${MEM_PAGE_KB}kB"

mem_dizer() { echo "[hook $MEM_ROTULO/mem] $*"; hook_log "mem: $*"; }
mem_erro()  { echo "[hook $MEM_ROTULO/mem] ERRO: $*" >&2; hook_log "mem ERRO: $*"; }

mem_campo() {
    # mem_campo CAMPO -> inteiro do sysfs. Vazio ou não numérico é falha, não
    # zero: tratar leitura falha como "pool vazio" faria a devolução achar que
    # não há nada a devolver.
    local campo="$1" valor=""
    [ -r "$MEM_POOL_DIR/$campo" ] || return 1
    IFS= read -r valor < "$MEM_POOL_DIR/$campo" || return 1
    case "$valor" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$valor"
}

mem_boot_id() {
    local valor=""
    [ -r /proc/sys/kernel/random/boot_id ] || return 1
    IFS= read -r valor < /proc/sys/kernel/random/boot_id || return 1
    case "$valor" in [0-9a-f]*-*-*-*-*) printf '%s\n' "$valor" ;; *) return 1 ;; esac
}

mem_modo_de_runtime() {
    case "$MEMORIA_MODO" in
        hugetlb-2m|hugetlb-1g) return 0 ;;
    esac
    return 1
}

mem_escrever_pool() {
    # Escrita única e verificada. O kernel aceita a escrita e entrega o que
    # conseguiu: sem reler, "aloquei 22" e "aloquei 9" são indistinguíveis.
    local alvo="$1" obtido=""
    printf '%s\n' "$alvo" > "$MEM_POOL_DIR/nr_hugepages" 2>/dev/null || return 1
    obtido="$(mem_campo nr_hugepages)" || return 1
    [ "$obtido" = "$alvo" ] || return 1
    return 0
}

mem_estado_gravar() {
    # mem_estado_gravar ESTADO DELTA NR FREE RESV SURPLUS
    # Publicação atômica por rename, modo 0600: o estado diz quantas páginas
    # são NOSSAS, e quem puder editá-lo escolhe quantas o release vai tirar do
    # pool de outra pessoa.
    local estado="$1" delta="$2" nr="$3" livre="$4" resv="$5" surplus="$6"
    local tmp boot
    boot="$(mem_boot_id)" || return 1
    install -d -o root -g root -m 0700 "$MEM_STATE_DIR" || return 1
    tmp="$MEM_STATE_FILE.$$"
    {
        printf 'ESTADO=%s\n' "$estado"
        printf 'BOOT_ID=%s\n' "$boot"
        printf 'MODO=%s\n' "$MEMORIA_MODO"
        printf 'PAGE_KB=%s\n' "$MEM_PAGE_KB"
        printf 'DELTA=%s\n' "$delta"
        printf 'BASE_NR=%s\n' "$nr"
        printf 'BASE_FREE=%s\n' "$livre"
        printf 'BASE_RESV=%s\n' "$resv"
        printf 'BASE_SURPLUS=%s\n' "$surplus"
    } > "$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$MEM_STATE_FILE" || { rm -f -- "$tmp"; return 1; }
    return 0
}

mem_adquirir() {
    # Usada pelo prepare. Falhar aqui ABORTA o start, e é esse o contrato: uma
    # VM que sobe com metade das páginas prometidas mente sobre o próprio
    # perfil. Nenhum fallback silencioso para outro modo.
    mem_modo_de_runtime || {
        mem_dizer "política de memória '$MEMORIA_MODO': o ciclo de vida não toca no pool"
        return 0
    }
    # Num modo de runtime, zero página exigida é incoerente: ou a política foi
    # recusada pelo planejador na renderização (e o hook recebeu 0), ou a
    # configuração está inconsistente. Nos dois casos o start é recusado, em
    # vez de a VM subir sem as páginas que o perfil promete.
    case "$MEM_PAGES_NEEDED" in
        ''|*[!0-9]*|0)
            mem_erro "modo '$MEMORIA_MODO' exige páginas, mas o plano assado nos hooks pede $MEM_PAGES_NEEDED; reexecute a etapa 14 depois de corrigir a política"
            return 1
            ;;
    esac
    [ -d "$MEM_POOL_DIR" ] \
        || { mem_erro "o host não expõe pool de ${MEM_PAGE_KB} kB"; return 1; }
    local nr livre resv surplus delta alvo livre_depois
    nr="$(mem_campo nr_hugepages)" || { mem_erro "nr_hugepages ilegível"; return 1; }
    livre="$(mem_campo free_hugepages)" || { mem_erro "free_hugepages ilegível"; return 1; }
    resv="$(mem_campo resv_hugepages)" || { mem_erro "resv_hugepages ilegível"; return 1; }
    surplus="$(mem_campo surplus_hugepages)" || { mem_erro "surplus_hugepages ilegível"; return 1; }

    # Consumidor externo recusa o start: na devolução não haveria como
    # distinguir a nossa página da dele, e tirar página de outra VM é
    # inaceitável.
    [ "$nr" -eq "$livre" ] \
        || { mem_erro "pool com $((nr - livre)) página(s) em uso por outro consumidor"; return 1; }
    [ "$resv" -eq 0 ] \
        || { mem_erro "pool com $resv página(s) reservada(s) por outro consumidor"; return 1; }
    [ "$surplus" -eq 0 ] \
        || { mem_erro "pool com $surplus página(s) de surplus; a exatidão da devolução não pode ser provada"; return 1; }

    delta=$(( MEM_PAGES_NEEDED - nr ))
    [ "$delta" -gt 0 ] || delta=0
    if [ "$delta" -eq 0 ]; then
        # Pool preexistente já cobre a necessidade. Ele é BASELINE a preservar,
        # não sobra a limpar: delta zero significa que a devolução não vai
        # mexer no pool.
        mem_dizer "pool já cobre as $MEM_PAGES_NEEDED página(s); nada a adquirir"
        mem_estado_gravar VERIFIED 0 "$nr" "$livre" "$resv" "$surplus" \
            || { mem_erro "estado de memória não pôde ser gravado"; return 1; }
        return 0
    fi

    alvo=$(( nr + delta ))
    mem_dizer "adquirindo $delta página(s) de ${MEM_PAGE_KB} kB (de $nr para $alvo)..."
    # O estado é gravado ANTES da escrita: se o hook morrer entre adquirir e
    # registrar, o release não saberia o que é dele para devolver.
    mem_estado_gravar ACQUIRED "$delta" "$nr" "$livre" "$resv" "$surplus" \
        || { mem_erro "estado de memória não pôde ser gravado; nada foi adquirido"; return 1; }
    if ! mem_escrever_pool "$alvo"; then
        mem_erro "aquisição parcial ou recusada pelo kernel; restaurando o baseline"
        if mem_escrever_pool "$nr"; then
            mem_dizer "baseline restaurado em $nr página(s)"
            rm -f -- "$MEM_STATE_FILE" || true
        else
            mem_erro "BASELINE NÃO RESTAURADO: nr_hugepages diverge de $nr; estado preservado em $MEM_STATE_FILE"
            mem_estado_gravar RECOVERY_REQUIRED "$delta" "$nr" "$livre" "$resv" "$surplus" || true
        fi
        return 1
    fi
    livre_depois="$(mem_campo free_hugepages)" || { mem_erro "free_hugepages ilegível após a aquisição"; return 1; }
    if [ "$livre_depois" -lt $(( livre + delta )) ]; then
        mem_erro "as $delta página(s) adquiridas não estão livres (free=$livre_depois); restaurando"
        mem_escrever_pool "$nr" || mem_erro "BASELINE NÃO RESTAURADO: nr_hugepages diverge de $nr"
        mem_estado_gravar RECOVERY_REQUIRED "$delta" "$nr" "$livre" "$resv" "$surplus" || true
        return 1
    fi
    mem_estado_gravar VERIFIED "$delta" "$nr" "$livre" "$resv" "$surplus" \
        || { mem_erro "estado de memória não pôde ser gravado após a prova"; return 1; }
    mem_dizer "aquisição comprovada: $alvo página(s) no pool, $livre_depois livre(s)"
    return 0
}

mem_devolver() {
    # Usada pelo release. NUNCA aborta: devolve 1 para o chamador contar a
    # falha e seguir restaurando GPU e display. Abandonar o desktop porque a
    # memória não voltou é exatamente o que o requisito proíbe.
    local estado="" boot_state="" modo="" page_kb="" delta="" base_nr=""
    local base_free="" base_resv="" base_surplus=""
    local chave valor nr livre resv surplus boot_atual alvo pool
    [ -e "$MEM_STATE_FILE" ] || { mem_dizer "sem estado de memória; nada a devolver"; return 0; }
    while IFS='=' read -r chave valor; do
        case "$chave" in
            ESTADO) estado="$valor" ;;
            BOOT_ID) boot_state="$valor" ;;
            MODO) modo="$valor" ;;
            PAGE_KB) page_kb="$valor" ;;
            DELTA) delta="$valor" ;;
            BASE_NR) base_nr="$valor" ;;
            BASE_FREE) base_free="$valor" ;;
            BASE_RESV) base_resv="$valor" ;;
            BASE_SURPLUS) base_surplus="$valor" ;;
            '') : ;;
            *) mem_erro "chave desconhecida no estado de memória: $chave; a devolução segue" ;;
        esac
    done < "$MEM_STATE_FILE"

    # Cada campo é validado SOZINHO. Concatenar para validar em um só teste
    # esconde campo vazio atrás do vizinho, e o campo que falta é justamente o
    # que decide quantas páginas tirar do pool.
    local campo_nome campo_valor
    for campo_nome in delta base_nr page_kb base_free base_resv base_surplus; do
        eval "campo_valor=\${$campo_nome}"
        case "$campo_valor" in
            ''|*[!0-9]*)
                mem_erro "estado de memória sem o campo '$campo_nome' ou com valor não numérico; devolução impossível e o pool não será tocado"
                return 1
                ;;
        esac
    done

    boot_atual="$(mem_boot_id)" || { mem_erro "boot_id ilegível; devolução impossível"; return 1; }
    if [ -n "$boot_state" ] && [ "$boot_state" != "$boot_atual" ]; then
        # Estado de outro boot. O reboot já limpou o pool, então NÃO há página
        # nossa para devolver, e mexer em nr_hugepages agora reduziria pool que
        # pertence a este boot. A reconciliação é descartar o estado.
        mem_dizer "estado de memória é do boot $boot_state e o atual é $boot_atual; reconciliando sem tocar no pool"
        rm -f -- "$MEM_STATE_FILE" || { mem_erro "estado obsoleto não pôde ser removido"; return 1; }
        return 0
    fi

    if [ "$delta" -eq 0 ]; then
        mem_dizer "nada havia sido adquirido; o pool preexistente é preservado"
        rm -f -- "$MEM_STATE_FILE" || { mem_erro "estado não pôde ser removido"; return 1; }
        return 0
    fi

    pool="/sys/kernel/mm/hugepages/hugepages-${page_kb}kB"
    [ -d "$pool" ] || { mem_erro "pool de ${page_kb} kB desapareceu; devolução impossível"; return 1; }
    MEM_POOL_DIR="$pool"
    nr="$(mem_campo nr_hugepages)" || { mem_erro "nr_hugepages ilegível"; return 1; }
    livre="$(mem_campo free_hugepages)" || { mem_erro "free_hugepages ilegível"; return 1; }

    if [ "$livre" -lt "$delta" ]; then
        # Página em uso na hora de devolver significa QEMU vivo ou vazamento. O
        # release já provou domínio desligado antes de chegar aqui; se ainda há
        # consumidor, devolver arrancaria memória de quem a está usando.
        mem_erro "só $livre de $delta página(s) estão livres; ainda há consumidor ativo"
        mem_estado_gravar RECOVERY_REQUIRED "$delta" "$base_nr" "$base_free" "$base_resv" "$base_surplus" || true
        return 1
    fi
    if [ "$nr" -lt $(( base_nr + delta )) ]; then
        mem_erro "pool tem $nr página(s), menos que baseline $base_nr mais delta $delta; alguém mexeu no pool"
        mem_estado_gravar RECOVERY_REQUIRED "$delta" "$base_nr" "$base_free" "$base_resv" "$base_surplus" || true
        return 1
    fi

    alvo=$(( nr - delta ))
    mem_dizer "devolvendo $delta página(s) de ${page_kb} kB (de $nr para $alvo)..."
    if ! mem_escrever_pool "$alvo"; then
        mem_erro "a devolução não pôde ser comprovada; estado preservado em $MEM_STATE_FILE"
        mem_estado_gravar RECOVERY_REQUIRED "$delta" "$base_nr" "$base_free" "$base_resv" "$base_surplus" || true
        return 1
    fi
    resv="$(mem_campo resv_hugepages)" || resv=""
    surplus="$(mem_campo surplus_hugepages)" || surplus=""
    if [ "$alvo" != "$base_nr" ] || [ "$resv" != "$base_resv" ] || [ "$surplus" != "$base_surplus" ]; then
        mem_erro "o pool não reproduziu o baseline (nr=$alvo esperado $base_nr, resv=$resv esperado $base_resv, surplus=$surplus esperado $base_surplus)"
        mem_estado_gravar RECOVERY_REQUIRED "$delta" "$base_nr" "$base_free" "$base_resv" "$base_surplus" || true
        return 1
    fi
    rm -f -- "$MEM_STATE_FILE" || { mem_erro "estado não pôde ser removido após a devolução"; return 1; }
    mem_dizer "devolução comprovada: pool de volta a $base_nr página(s)"
    return 0
}
HOOKMEM
}

emitir_hook_log_fn() {
    # Insere nos hooks gerados o log persistente de ações do HOST em
    # /var/log/vm-passthrough/hooks.log. O libvirt engole o stdout dos hooks
    # que terminam bem e o journal pode perder os últimos segundos num
    # travamento; este arquivo é a linha do tempo que sobrevive para o
    # diagnóstico. Privacidade por contrato: registra apenas eventos do lado
    # do host (drivers, DM, systemd); nunca conteúdo, tela, teclado ou
    # tráfego da VM.
    local rotulo="$1"
    printf 'HOOK_ROTULO=%q\n' "$rotulo"
    printf 'HOOK_VERSAO=%q\n' "$SCRIPT_VERSION"
    cat <<'HOOKLOG'
HOOK_LOG_DIR=/var/log/vm-passthrough
HOOK_LOG_ARQUIVO="$HOOK_LOG_DIR/hooks.log"
hook_log() {
    # Best-effort: falha de log nunca altera o resultado do hook. O sync
    # persiste a linha mesmo que o host trave logo em seguida.
    {
        [ -d "$HOOK_LOG_DIR" ] || mkdir -p -- "$HOOK_LOG_DIR"
        if [ ! -f "$HOOK_LOG_ARQUIVO" ]; then
            : > "$HOOK_LOG_ARQUIVO"
            chgrp adm "$HOOK_LOG_ARQUIVO" 2>/dev/null || true
            chmod 0640 "$HOOK_LOG_ARQUIVO" 2>/dev/null || true
        elif [ "$(stat -c %s -- "$HOOK_LOG_ARQUIVO")" -ge 1048576 ] 2>/dev/null; then
            mv -f -- "$HOOK_LOG_ARQUIVO" "$HOOK_LOG_ARQUIVO.1"
        fi
        printf '%s [%s] [hook %s v%s] %s\n' \
            "$(date '+%F %T')" "${VM_NAME:-?}" "$HOOK_ROTULO" "$HOOK_VERSAO" "$*" >> "$HOOK_LOG_ARQUIVO"
        sync -d -- "$HOOK_LOG_ARQUIVO" 2>/dev/null || sync 2>/dev/null
    } 2>/dev/null || true
}
HOOKLOG
}

gerar_dispatcher() {
    local destino="$1" legado="$2"
    {
        cat <<'CAB'
#!/bin/bash
# vm-passthrough-qemu-dispatcher-v2
# Propaga todos os argumentos, replica o XML de stdin e preserva hook legado.
set -u -o pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
CAB
        printf 'LEGACY_HOOK=%q\n' "$legado"
        emitir_hook_log_fn dispatcher
        cat <<'CORPO'
[ "$#" -ge 3 ] || { echo "[hook dispatcher] argumentos insuficientes" >&2; exit 64; }
VM_NAME="$1"
EVENTO="$2"
SUBEVENTO="$3"
hook_log "evento $EVENTO/$SUBEVENTO recebido (args: ${4:-} ${5:-})"
segmento_seguro() {
    [ -n "$1" ] && [ "$1" != . ] && [ "$1" != .. ] \
        && [[ "$1" != */* && "$1" != *$'\n'* && "$1" != *$'\r'* ]]
}
segmento_seguro "$VM_NAME" && segmento_seguro "$EVENTO" && segmento_seguro "$SUBEVENTO" \
    || { echo "[hook dispatcher] segmento de caminho inseguro" >&2; exit 64; }
INSTALANDO="/etc/libvirt/hooks/qemu.d/${VM_NAME}/.vm-passthrough-installing"
if [ -e "$INSTALANDO" ]; then
    echo "[hook dispatcher] configuração de passthrough em transação; start bloqueado" >&2
    exit 75
fi
DIRETORIO_HOOK="/etc/libvirt/hooks/qemu.d/${VM_NAME}/${EVENTO}/${SUBEVENTO}"
ENTRADA="$(mktemp /run/libvirt-qemu-hook.XXXXXX)" \
    || { echo "[hook dispatcher] falha ao criar temporário" >&2; exit 70; }
chmod 600 "$ENTRADA" || { rm -f "$ENTRADA"; exit 70; }
trap 'rm -f "$ENTRADA"' EXIT
cat > "$ENTRADA" || { echo "[hook dispatcher] falha ao capturar stdin" >&2; exit 74; }

executar_hook() {
    local alvo="$1" rc
    shift
    "$alvo" "$@" < "$ENTRADA" || {
        rc=$?
        echo "[hook dispatcher] $alvo falhou com status $rc" >&2
        hook_log "ERRO: $alvo falhou com status $rc"
        return "$rc"
    }
}

# O gate de prepare é executado explicitamente antes de qualquer 00-* ou hook
# legado. Depois ele é pulado no glob para nunca rodar duas vezes.
GATE=""
if [ "$EVENTO" = prepare ] && [ "$SUBEVENTO" = begin ]; then
    GATE="$DIRETORIO_HOOK/01-gpu-preflight.sh"
    OBRIGATORIO="/etc/libvirt/hooks/qemu.d/${VM_NAME}/.vm-passthrough-required"
    if [ -e "$OBRIGATORIO" ] && [ ! -e "$GATE" ]; then
        echo "[hook dispatcher] gate obrigatório ausente: $GATE" >&2
        exit 127
    fi
    if [ -e "$GATE" ]; then
        [ -x "$GATE" ] || { echo "[hook dispatcher] gate não executável: $GATE" >&2; exit 126; }
        executar_hook "$GATE" "$@" || exit $?
    fi
fi
if [ -d "$DIRETORIO_HOOK" ]; then
    for script in "$DIRETORIO_HOOK"/*; do
        [ -x "$script" ] || continue
        [ -n "$GATE" ] && [ "$script" = "$GATE" ] && continue
        executar_hook "$script" "$@" || exit $?
    done
fi
if [ -n "$LEGACY_HOOK" ] && [ -x "$LEGACY_HOOK" ]; then
    executar_hook "$LEGACY_HOOK" "$@" || exit $?
fi
hook_log "evento $EVENTO/$SUBEVENTO concluído"
exit 0
CORPO
    } > "$destino"
}

MEM_PAGE_KB=0
MEM_PAGES_NEEDED=0
MEM_PLANO_AVISO=""
memoria_plano_resolver() {
    # Deriva tamanho de página e contagem PELO CORE, em vez de repetir a tabela
    # de modos aqui: o hook executa a aritmética, mas quem a define é
    # libexec/passthrough_core/resources.py, e duplicar a tabela criaria duas
    # fontes para a mesma decisão.
    #
    # A recusa do plano NÃO impede renderizar: ela costuma ser transitória
    # (consumidor externo no pool agora, memória apertada agora) e o hook
    # reavalia no start, que é quando a decisão importa. O que a recusa faz é
    # avisar o operador no momento da instalação.
    local -a permitidas=("${CORE_PARES_ENVELOPE[@]}" VALID ERROR MODE RUNTIME
        RETURNABLE PAGE_KB PAGES_NEEDED BASELINE_NR BASELINE_FREE BASELINE_RESV
        BASELINE_SURPLUS ACQUIRE_DELTA TARGET_NR NODE_COUNT FINGERPRINT)
    local -a payload=()
    local foto=""
    MEMORIA_MODO="${MEMORIA_MODO:-normal}"
    MEM_PAGE_KB=0
    MEM_PAGES_NEEDED=0
    MEM_PLANO_AVISO=""
    foto="$(recursos_fotografar)" || foto=""
    payload=(mode "$MEMORIA_MODO" snapshot "$foto" vm_ram_mib "${VM_RAM_MB:-0}")
    if ! python_core_pares_payload permitidas MEMPLANO_ resources-plan payload 2>/dev/null; then
        MEM_PLANO_AVISO="o core não pôde planejar a política de memória: $(_core_diagnostico 'motivo não informado')"
        return 1
    fi
    MEM_PAGE_KB="${MEMPLANO_PAGE_KB:-0}"
    MEM_PAGES_NEEDED="${MEMPLANO_PAGES_NEEDED:-0}"
    [ "${MEMPLANO_VALID:-0}" = 1 ] || MEM_PLANO_AVISO="${MEMPLANO_ERROR:-plano de memória recusado}"
    return 0
}

gerar_prepare() {
    local destino="$1" audio_pci="${GPU_AUDIO_PCI_ID:-}" audio_id="${GPU_AUDIO_VENDOR_DEVICE_ID:-}"
    audio_pci="${audio_pci,,}"
    audio_id="${audio_id,,}"
    {
        cat <<'CAB'
#!/bin/bash
# Hook prepare/begin: preflight fail-closed e liberação transacional do desktop.
set -Eeuo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
CAB
        printf 'VM_NAME=%q\n' "$VM_NAME"
        printf 'GPU_PCI=%q\n' "${GPU_PCI_ID,,}"
        printf 'GPU_AUDIO_PCI=%q\n' "$audio_pci"
        printf 'GPU_ID=%q\n' "${GPU_VENDOR_DEVICE_ID,,}"
        printf 'GPU_AUDIO_ID=%q\n' "$audio_id"
        printf 'IOMMU_GROUP=%q\n' "$((10#$IOMMU_GROUP_GPU))"
        printf 'DM=%q\n' "$DM_SERVICE"
        printf 'HD1_BY_ID=%q\n' "${HD1_BY_ID_PATH:-}"
        printf 'DISCO_SISTEMA=%q\n' "${NVME_DEVICE:-}"
        printf 'HD1_IDENTIDADE=%q\n' "${HD1_IDENTIDADE:-}"
        printf 'HD1_FINGERPRINT=%q\n' "${HD1_DISK_FINGERPRINT:-}"
        emitir_hook_log_fn prepare
        emitir_hook_memoria_fn prepare
        cat <<'CORPO'
STATE_DIR=/run/libvirt-gpu-passthrough
STATE_FILE="$STATE_DIR/${VM_NAME}.state"
DM_WAS_ACTIVE=0

falha() { echo "[hook prepare] ERRO: $*" >&2; hook_log "ERRO: $*"; return 1; }
dizer() { echo "[hook prepare] $*"; hook_log "$*"; }
LOCK_DIR=/run/libvirt-gpu-locks
LOCK_FILE="$LOCK_DIR/${VM_NAME}.lock"
install -d -o root -g root -m 0755 "$LOCK_DIR"
[ ! -L "$LOCK_FILE" ] || falha "lock é link simbólico: $LOCK_FILE"
touch "$LOCK_FILE"
chown root:root "$LOCK_FILE"
chmod 0666 "$LOCK_FILE"
[ -f "$LOCK_FILE" ] && [ "$(stat -c %u "$LOCK_FILE")" -eq 0 ] || falha "lock inseguro"
exec 9>"$LOCK_FILE"
flock -n 9 || falha "outra operação de GPU está em andamento ($LOCK_FILE)"

pci_id_atual() {
    local bdf="$1" vendor device
    IFS= read -r vendor < "/sys/bus/pci/devices/$bdf/vendor" || return 1
    IFS= read -r device < "/sys/bus/pci/devices/$bdf/device" || return 1
    printf '%s:%s\n' "${vendor#0x}" "${device#0x}"
}
validar_pci_iommu() {
    local link grupo audio_grupo membro bdf classe
    local restaurar_nullglob=0
    [ "$(pci_id_atual "$GPU_PCI")" = "$GPU_ID" ] \
        || falha "identidade vendor/device da GPU mudou"
    link="/sys/bus/pci/devices/$GPU_PCI/iommu_group"
    [ -L "$link" ] || falha "GPU sem grupo IOMMU"
    grupo="$(basename -- "$(readlink -f -- "$link")")" || falha "grupo IOMMU ilegível"
    [ "$grupo" = "$IOMMU_GROUP" ] || falha "grupo IOMMU mudou: $IOMMU_GROUP -> $grupo"
    if [ -n "$GPU_AUDIO_PCI" ]; then
        [ "$(pci_id_atual "$GPU_AUDIO_PCI")" = "$GPU_AUDIO_ID" ] \
            || falha "identidade vendor/device do áudio mudou"
        link="/sys/bus/pci/devices/$GPU_AUDIO_PCI/iommu_group"
        [ -L "$link" ] || falha "áudio sem grupo IOMMU"
        audio_grupo="$(basename -- "$(readlink -f -- "$link")")" || falha "grupo do áudio ilegível"
        [ "$audio_grupo" = "$grupo" ] || falha "GPU e áudio deixaram de compartilhar grupo IOMMU"
    fi
    shopt -q nullglob || { shopt -s nullglob; restaurar_nullglob=1; }
    membros=("/sys/kernel/iommu_groups/$grupo/devices/"*)
    [ "$restaurar_nullglob" -eq 0 ] || shopt -u nullglob
    [ "${#membros[@]}" -gt 0 ] || falha "grupo IOMMU vazio/ilegível"
    for membro in "${membros[@]}"; do
        bdf="${membro##*/}"
        [ "$bdf" = "$GPU_PCI" ] && continue
        [ -n "$GPU_AUDIO_PCI" ] && [ "$bdf" = "$GPU_AUDIO_PCI" ] && continue
        IFS= read -r classe < "/sys/bus/pci/devices/$bdf/class" \
            || falha "não foi possível classificar membro IOMMU $bdf"
        [[ "${classe,,}" == 0x06* ]] || falha "endpoint não autorizado no grupo IOMMU: $bdf ($classe)"
    done
}
driver_atual() {
    local bdf="$1"
    if [ -L "/sys/bus/pci/devices/$bdf/driver" ]; then
        basename -- "$(readlink -f -- "/sys/bus/pci/devices/$bdf/driver")"
    else
        printf '%s\n' sem_driver
    fi
}
discos_fisicos_de() {
    local origem="$1" saida caminho tipo
    local -A vistos=()
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
discos_raiz() {
    local fonte
    fonte="$(findmnt -no SOURCE / 2>/dev/null | sed 's/\[.*\]$//')" || return 1
    discos_fisicos_de "$fonte"
}
identidade_disco() {
    local alvo="$1" propriedades chave valor
    propriedades="$(udevadm info --query=property --name "$alvo" 2>/dev/null)" || return 1
    for chave in ID_WWN_WITH_EXTENSION ID_WWN ID_SERIAL; do
        valor="$(awk -F= -v k="$chave" '$1 == k && length($2) {print k "=" substr($0, index($0,"=")+1); exit}' \
            <<< "$propriedades")"
        [ -z "$valor" ] || { printf '%s\n' "$valor"; return 0; }
    done
    return 1
}
inspecionar_montagens() {
    local alvo="$1" saida
    saida="$(lsblk -nlo NAME,MOUNTPOINTS -- "$alvo" 2>/dev/null)" || return 1
    if awk 'NF>1 && $2!="" {achou=1} END {exit !achou}' <<< "$saida"; then
        SNAP_MONTADO=1
    else
        SNAP_MONTADO=0
    fi
}
capturar_snapshot_hd1() {
    local alvo tipo devno raizes raiz real identidade
    [ -L "$HD1_BY_ID" ] || falha "HD1 persistente ausente: $HD1_BY_ID"
    alvo="$(readlink -f -- "$HD1_BY_ID")" || falha "não foi possível resolver HD1"
    [ -b "$alvo" ] || falha "alvo do HD1 não é bloco: $alvo"
    tipo="$(lsblk -dnro TYPE -- "$alvo" 2>/dev/null)" || falha "lsblk não classificou $alvo"
    [ "$tipo" = disk ] || falha "HD1 não aponta para disco inteiro"
    devno="$(lsblk -dnro MAJ:MIN -- "$alvo" 2>/dev/null)" || falha "major:minor do HD1 ilegível"
    [ -n "$devno" ] || falha "major:minor do HD1 vazio"
    raizes="$(discos_raiz)" || falha "não foi possível enumerar todos os discos físicos da raiz"
    while IFS= read -r raiz; do
        [ -n "$raiz" ] || continue
        raiz="$(readlink -f -- "$raiz")" || falha "ancestral da raiz ilegível"
        [ "$alvo" != "$raiz" ] || falha "HD1 coincide com a raiz do host ($raiz)"
    done <<< "$raizes"
    if [ -n "$DISCO_SISTEMA" ]; then
        real="$(readlink -f -- "$DISCO_SISTEMA")" || falha "disco do sistema desapareceu: $DISCO_SISTEMA"
        [ -b "$real" ] || falha "disco do sistema não é bloco: $DISCO_SISTEMA"
        [ "$alvo" != "$real" ] || falha "HD1 coincide com o disco do sistema: $real"
    fi
    inspecionar_montagens "$alvo" || falha "lsblk falhou ao inspecionar montagens de $alvo"
    [ "$SNAP_MONTADO" -eq 0 ] || falha "HD1 ou partição está montado no host: $alvo"
    identidade="$(identidade_disco "$alvo")" || falha "HD1 não possui WWN/serial verificável"
    [ "$identidade" = "$HD1_IDENTIDADE" ] \
        || falha "identidade do HD1 mudou: esperado '$HD1_IDENTIDADE', atual '$identidade'"
    SNAP_ALVO="$alvo"
    SNAP_DEVNO="$devno"
    SNAP_IDENTIDADE="$identidade"
}
preflight_hd1() {
    local alvo_1 devno_1 identidade_1
    [ -n "$HD1_BY_ID" ] || return 0
    [[ "$HD1_BY_ID" == /dev/disk/by-id/* ]] || falha "HD1 não usa /dev/disk/by-id."
    capturar_snapshot_hd1
    alvo_1="$SNAP_ALVO"
    devno_1="$SNAP_DEVNO"
    identidade_1="$SNAP_IDENTIDADE"
    capturar_snapshot_hd1
    [ "$SNAP_ALVO" = "$alvo_1" ] && [ "$SNAP_DEVNO" = "$devno_1" ] \
        && [ "$SNAP_IDENTIDADE" = "$identidade_1" ] \
        || falha "alvo, major:minor ou identidade do HD1 mudou durante o preflight"
}
aguardar_dm_inativo() {
    local estado i
    for ((i=0; i<30; i++)); do
        estado="$(systemctl show -p ActiveState --value "$DM")" || return 1
        [ "$estado" = inactive ] && return 0
        sleep 1
    done
    return 1
}
listar_ocupantes_gpu() {
    # Diagnóstico acionável no lugar de só "module in use": lista quem ainda
    # segura os nós da GPU no momento da desistência.
    local dispositivo
    local -a existentes=()
    command -v fuser >/dev/null 2>&1 || return 0
    for dispositivo in /dev/nvidia* /dev/dri/card* /dev/dri/renderD*; do
        [ -e "$dispositivo" ] && existentes+=("$dispositivo")
    done
    [ "${#existentes[@]}" -gt 0 ] || return 0
    echo "[hook prepare] processos ainda usando a GPU:" >&2
    fuser -v "${existentes[@]}" 2>&1 | sed 's/^/[hook prepare]   /' >&2 || true
}
descarregar_modulos_nvidia() {
    # Parar o DM encerra a sessão gráfica, mas os processos que seguram a GPU
    # (navegador, IDE, Xwayland, captura de tela) morrem de forma assíncrona:
    # um único modprobe -r perde essa corrida em sessões carregadas. O
    # descarregamento é repetido por até 60 s e o erro final lista os
    # ocupantes.
    local i modulo restante
    for ((i=0; i<60; i++)); do
        restante=0
        for modulo in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
            grep -q "^${modulo} " /proc/modules || continue
            if modprobe -r "$modulo" 2>/dev/null; then
                echo "[hook prepare] módulo $modulo descarregado."
            else
                restante=1
            fi
        done
        [ "$restante" -eq 0 ] && return 0
        if (( i % 10 == 0 )); then
            echo "[hook prepare] GPU ainda em uso; aguardando a sessão liberar os módulos nvidia (${i}s)..."
        fi
        sleep 1
    done
    listar_ocupantes_gpu
    return 1
}
rollback_prepare() {
    local rc=$? modulo falhas=0 i estado
    trap - ERR
    set +e
    echo "[hook prepare] revertendo liberação do desktop após falha..." >&2
    hook_log "rollback iniciado (status $rc): recarregando drivers e desktop"
    for modulo in nvidia nvidia_modeset nvidia_drm nvidia_uvm; do
        modprobe "$modulo" || { echo "[hook prepare] rollback: modprobe $modulo falhou" >&2; falhas=1; }
    done
    for ((i=0; i<20; i++)); do
        [ "$(driver_atual "$GPU_PCI")" = nvidia ] && break
        sleep 1
    done
    [ "$(driver_atual "$GPU_PCI")" = nvidia ] \
        || { echo "[hook prepare] rollback: GPU não retornou ao driver nvidia" >&2; falhas=1; }
    if [ -n "$GPU_AUDIO_PCI" ]; then
        modprobe snd_hda_intel || falhas=1
        for ((i=0; i<20; i++)); do
            [ "$(driver_atual "$GPU_AUDIO_PCI")" = snd_hda_intel ] && break
            sleep 1
        done
        [ "$(driver_atual "$GPU_AUDIO_PCI")" = snd_hda_intel ] || falhas=1
    fi
    nvidia-smi >/dev/null 2>&1 || { echo "[hook prepare] rollback: nvidia-smi falhou" >&2; falhas=1; }
    if [ "$DM_WAS_ACTIVE" -eq 1 ]; then
        systemctl start "$DM" || falhas=1
        systemctl is-active --quiet "$DM" || falhas=1
    else
        estado="$(systemctl show -p ActiveState --value "$DM")"
        [ "$estado" = inactive ] || falhas=1
    fi
    if [ "$falhas" -eq 0 ]; then
        rm -f -- "$STATE_FILE"
        hook_log "rollback concluído: GPU e desktop de volta ao baseline"
    else
        echo "[hook prepare] rollback incompleto; estado preservado em $STATE_FILE" >&2
        hook_log "ERRO: rollback incompleto; estado preservado em $STATE_FILE"
    fi
    exit "$rc"
}

hook_log "preflight iniciado; driver atual da GPU $GPU_PCI: $(driver_atual "$GPU_PCI")"
validar_pci_iommu
preflight_hd1
[ "$(driver_atual "$GPU_PCI")" = nvidia ] \
    || falha "GPU $GPU_PCI não está no driver nvidia antes do start"
if [ -n "$GPU_AUDIO_PCI" ]; then
    [ "$(driver_atual "$GPU_AUDIO_PCI")" = snd_hda_intel ] \
        || falha "áudio $GPU_AUDIO_PCI não está em snd_hda_intel antes do start"
fi
# REQ-VM-RESOURCE-LIFECYCLE: a memória é adquirida AQUI, antes de o display ser
# desligado e antes de o libvirt destacar a GPU. Falhar aqui aborta o start com
# o desktop ainda de pé, que é o ponto: recusar cedo custa uma mensagem, e
# recusar tarde custa a sessão gráfica do operador.
mem_adquirir || falha "aquisição de memória recusada; a VM não será iniciada"

DM_ESTADO="$(systemctl show -p ActiveState --value "$DM")" || falha "não foi possível consultar $DM"
case "$DM_ESTADO" in
    active) DM_WAS_ACTIVE=1 ;;
    inactive) DM_WAS_ACTIVE=0 ;;
    *) falha "$DM está em estado transitório/inseguro: $DM_ESTADO" ;;
esac
install -d -m 0700 "$STATE_DIR"
[ ! -e "$STATE_FILE" ] || falha "estado anterior ainda existe: $STATE_FILE; execute a recuperação"
STATE_TMP="$(mktemp "$STATE_DIR/.${VM_NAME}.XXXXXX")" || falha "não foi possível criar estado"
chmod 0600 "$STATE_TMP"
printf 'DM_WAS_ACTIVE=%s\nGPU_DRIVER=nvidia\nAUDIO_DRIVER=%s\nHD1_ALVO=%s\nHD1_DEVNO=%s\nHD1_IDENTIDADE=%s\nHD1_FINGERPRINT=%s\n' \
    "$DM_WAS_ACTIVE" "${GPU_AUDIO_PCI:+snd_hda_intel}" \
    "${SNAP_ALVO:-}" "${SNAP_DEVNO:-}" "${SNAP_IDENTIDADE:-}" "${HD1_FINGERPRINT:-}" > "$STATE_TMP"
mv -f -- "$STATE_TMP" "$STATE_FILE"
hook_log "estado registrado em $STATE_FILE (DM_WAS_ACTIVE=$DM_WAS_ACTIVE)"
trap rollback_prepare ERR

if [ "$DM_WAS_ACTIVE" -eq 1 ]; then
    dizer "parando $DM..."
    systemctl stop "$DM"
    aguardar_dm_inativo || falha "$DM não ficou inativo em 30 segundos"
    hook_log "$DM parado e confirmado inativo"
fi
dizer "descarregando os módulos nvidia (aguarda a sessão soltar a GPU; até 60 s)..."
descarregar_modulos_nvidia \
    || falha "módulos nvidia continuam em uso após 60 s; feche aplicativos que usam a GPU (navegador, IDE, acesso remoto) e tente novamente"
[ "$(driver_atual "$GPU_PCI")" = sem_driver ] \
    || falha "GPU continuou vinculada após descarregar nvidia"
trap - ERR
dizer "preflight aprovado e desktop liberado; detach PCI será feito pelo libvirt."
CORPO
    } > "$destino"
}

gerar_start() {
    local destino="$1" audio_pci="${GPU_AUDIO_PCI_ID:-}"
    audio_pci="${audio_pci,,}"
    {
        cat <<'CAB'
#!/bin/bash
# Hook start/begin: confere o detach gerenciado antes de liberar o QEMU.
set -Eeuo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
CAB
        printf 'VM_NAME=%q\n' "$VM_NAME"
        printf 'GPU_PCI=%q\n' "${GPU_PCI_ID,,}"
        printf 'GPU_AUDIO_PCI=%q\n' "$audio_pci"
        printf 'HD1_BY_ID=%q\n' "${HD1_BY_ID_PATH:-}"
        printf 'HD1_IDENTIDADE=%q\n' "${HD1_IDENTIDADE:-}"
        printf 'HD1_FINGERPRINT=%q\n' "${HD1_DISK_FINGERPRINT:-}"
        emitir_hook_log_fn start
        cat <<'CORPO'
STATE_FILE="/run/libvirt-gpu-passthrough/${VM_NAME}.state"
[ -f "$STATE_FILE" ] \
    || { echo "[hook start] estado prepare ausente" >&2; hook_log "ERRO: estado prepare ausente"; exit 1; }
HD1_ALVO_ESTADO=""
HD1_DEVNO_ESTADO=""
HD1_IDENTIDADE_ESTADO=""
HD1_FINGERPRINT_ESTADO=""
while IFS='=' read -r chave valor; do
    case "$chave" in
        HD1_ALVO) HD1_ALVO_ESTADO="$valor" ;;
        HD1_DEVNO) HD1_DEVNO_ESTADO="$valor" ;;
        HD1_IDENTIDADE) HD1_IDENTIDADE_ESTADO="$valor" ;;
        HD1_FINGERPRINT) HD1_FINGERPRINT_ESTADO="$valor" ;;
        DM_WAS_ACTIVE|GPU_DRIVER|AUDIO_DRIVER) : ;;
        *) echo "[hook start] chave de estado desconhecida: $chave" >&2; exit 1 ;;
    esac
done < "$STATE_FILE"
identidade_disco() {
    local alvo="$1" propriedades chave valor
    propriedades="$(udevadm info --query=property --name "$alvo" 2>/dev/null)" || return 1
    for chave in ID_WWN_WITH_EXTENSION ID_WWN ID_SERIAL; do
        valor="$(awk -F= -v k="$chave" '$1 == k && length($2) {print k "=" substr($0, index($0,"=")+1); exit}' \
            <<< "$propriedades")"
        [ -z "$valor" ] || { printf '%s\n' "$valor"; return 0; }
    done
    return 1
}
validar_hd1_antes_qemu() {
    local alvo devno identidade saida
    [ -n "$HD1_BY_ID" ] || return 0
    alvo="$(readlink -f -- "$HD1_BY_ID")" || return 1
    [ -b "$alvo" ] || return 1
    devno="$(lsblk -dnro MAJ:MIN -- "$alvo" 2>/dev/null)" || return 1
    identidade="$(identidade_disco "$alvo")" || return 1
    [ "$alvo" = "$HD1_ALVO_ESTADO" ] && [ "$devno" = "$HD1_DEVNO_ESTADO" ] \
        && [ "$identidade" = "$HD1_IDENTIDADE_ESTADO" ] \
        && [ "$identidade" = "$HD1_IDENTIDADE" ] \
        && [ "$HD1_FINGERPRINT_ESTADO" = "$HD1_FINGERPRINT" ] || return 1
    saida="$(lsblk -nlo NAME,MOUNTPOINTS -- "$alvo" 2>/dev/null)" || return 1
    ! awk 'NF>1 && $2!="" {achou=1} END {exit !achou}' <<< "$saida"
}
validar_hd1_antes_qemu \
    || { echo "[hook start] HD1 mudou ou foi montado depois do prepare; abortando QEMU" >&2; hook_log "ERRO: HD1 mudou ou foi montado depois do prepare; QEMU abortado"; exit 1; }
driver_atual() {
    [ -L "/sys/bus/pci/devices/$1/driver" ] \
        && basename -- "$(readlink -f -- "/sys/bus/pci/devices/$1/driver")" \
        || printf '%s\n' sem_driver
}
aguardar_vfio() {
    local bdf="$1" i
    for ((i=0; i<15; i++)); do
        [ "$(driver_atual "$bdf")" = vfio-pci ] && return 0
        sleep 1
    done
    echo "[hook start] $bdf não foi entregue ao vfio-pci pelo libvirt" >&2
    hook_log "ERRO: $bdf não foi entregue ao vfio-pci pelo libvirt (driver atual: $(driver_atual "$bdf"))"
    return 1
}
aguardar_vfio "$GPU_PCI"
[ -z "$GPU_AUDIO_PCI" ] || aguardar_vfio "$GPU_AUDIO_PCI"
echo "[hook start] hostdev managed='yes' confirmado em vfio-pci."
hook_log "hostdev managed='yes' confirmado em vfio-pci; QEMU liberado"
CORPO
    } > "$destino"
}

gerar_release() {
    local destino="$1" audio_pci="${GPU_AUDIO_PCI_ID:-}"
    audio_pci="${audio_pci,,}"
    {
        cat <<'CAB'
#!/bin/bash
# Hook release/end: valida reattach gerenciado e restaura o desktop.
set -Eeuo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
CAB
        printf 'VM_NAME=%q\n' "$VM_NAME"
        printf 'GPU_PCI=%q\n' "${GPU_PCI_ID,,}"
        printf 'GPU_AUDIO_PCI=%q\n' "$audio_pci"
        printf 'DM=%q\n' "$DM_SERVICE"
        emitir_hook_log_fn release
        emitir_hook_memoria_fn release
        cat <<'CORPO'
STATE_FILE="/run/libvirt-gpu-passthrough/${VM_NAME}.state"
LOCK_DIR=/run/libvirt-gpu-locks
LOCK_FILE="$LOCK_DIR/${VM_NAME}.lock"
dizer() { echo "[hook release] $*"; hook_log "$*"; }
dizer_erro() { echo "[hook release] $*" >&2; hook_log "ERRO: $*"; }
install -d -o root -g root -m 0755 "$LOCK_DIR"
[ ! -L "$LOCK_FILE" ] || { dizer_erro "lock inseguro"; exit 1; }
touch "$LOCK_FILE"
chown root:root "$LOCK_FILE"
chmod 0666 "$LOCK_FILE"
[ -f "$LOCK_FILE" ] && [ "$(stat -c %u "$LOCK_FILE")" -eq 0 ] \
    || { dizer_erro "lock inseguro"; exit 1; }
exec 9>"$LOCK_FILE"
flock -w 60 9 || { dizer_erro "lock de GPU ocupado por mais de 60 s"; exit 1; }
driver_atual() {
    [ -L "/sys/bus/pci/devices/$1/driver" ] \
        && basename -- "$(readlink -f -- "/sys/bus/pci/devices/$1/driver")" \
        || printf '%s\n' sem_driver
}
aguardar_driver() {
    local bdf="$1" esperado="$2" i
    for ((i=0; i<20; i++)); do
        [ "$(driver_atual "$bdf")" = "$esperado" ] && return 0
        sleep 1
    done
    dizer_erro "$bdf não retornou ao driver $esperado (atual: $(driver_atual "$bdf"))"
    return 1
}
aguardar_drm_gpu() {
    # Um DM que sobe antes de a GPU expor o nó DRM abre a sessão sem saída de
    # vídeo real: monitor sem sinal com o host vivo. Espera até 15 s.
    local i
    for ((i=0; i<15; i++)); do
        if compgen -G "/sys/bus/pci/devices/$GPU_PCI/drm/card*" >/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}
aguardar_udev_quieto() {
    # D-GPU-UDEV-LOOP: uma tempestade de eventos udev sobre
    # /bus/pci/drivers/nvidia recarrega os módulos em laço. O driver aparece
    # correto no instante da checagem e some um segundo depois, então as
    # pós-condições passam e o desktop congela logo em seguida. Aqui a fila é
    # drenada e a estabilidade é exigida por uma janela, não por uma amostra.
    local i
    udevadm settle --timeout=15 >/dev/null 2>&1 || true
    for ((i=0; i<5; i++)); do
        sleep 1
        [ "$(driver_atual "$GPU_PCI")" = "$GPU_DRIVER" ] || return 1
        [ -d /sys/module/nvidia_drm ] || return 1
        [ -d /sys/module/nvidia_modeset ] || return 1
        compgen -G "/sys/bus/pci/devices/$GPU_PCI/drm/card*" >/dev/null || return 1
    done
    return 0
}
desligamento_em_andamento() {
    # Com poweroff/reboot na fila, o systemd recusa iniciar o DM ("transaction
    # is destructive"); religar o desktop é impossível e desnecessário.
    systemctl list-jobs --no-legend 2>/dev/null \
        | grep -Eq '(shutdown|poweroff|reboot|halt)\.target'
}
iniciar_dm() {
    local tentativa
    for ((tentativa=1; tentativa<=3; tentativa++)); do
        dizer "iniciando $DM (tentativa $tentativa/3)..."
        if systemctl start "$DM" && systemctl is-active --quiet "$DM"; then
            return 0
        fi
        dizer_erro "$DM não ficou ativo na tentativa $tentativa"
        sleep 3
    done
    return 1
}
hook_log "release iniciado; driver atual da GPU $GPU_PCI: $(driver_atual "$GPU_PCI")"
if [ ! -f "$STATE_FILE" ]; then
    dizer_erro "estado ausente; não é possível provar o baseline do driver/DM. Use util/recuperar-gpu.sh."
    exit 1
fi
DM_WAS_ACTIVE=""
GPU_DRIVER=""
AUDIO_DRIVER=""
# O acumulador nasce ANTES da leitura do estado, e isso é o ponto.
#
# Até 03/09/2026 uma chave desconhecida ou um valor inválido faziam `exit 1`
# AQUI, antes de qualquer restauração: a GPU não voltava ao host e o display
# manager não subia, deixando o operador com tela preta porque a limpeza
# anterior não foi ENTENDIDA. O contrato de REQ-VM-RESOURCE-LIFECYCLE proíbe
# isso em letra ("o dispatcher de release não pode abandonar GPU/display/CPU
# porque uma limpeza anterior falhou"), e I9.12 vai acrescentar chaves neste
# mesmo arquivo — um hook antigo lendo estado novo cairia exatamente aqui.
#
# Agora tudo nesta seção ACUMULA falha, aplica o padrão mais seguro e segue
# para a restauração. O código de saída no fim continua denunciando que algo
# não foi entendido, e o estado continua preservado para diagnóstico.
FALHAS=0
while IFS='=' read -r chave valor; do
    case "$chave" in
        DM_WAS_ACTIVE) DM_WAS_ACTIVE="$valor" ;;
        GPU_DRIVER) GPU_DRIVER="$valor" ;;
        AUDIO_DRIVER) AUDIO_DRIVER="$valor" ;;
        HD1_ALVO|HD1_DEVNO|HD1_IDENTIDADE|HD1_FINGERPRINT) : ;;
        '') : ;;
        *)
            dizer_erro "chave de estado desconhecida: $chave; a restauração segue mesmo assim"
            FALHAS=$((FALHAS + 1))
            ;;
    esac
done < "$STATE_FILE"
# Padrão seguro para o desktop: na dúvida, devolver a tela ao operador. Não
# iniciar o DM quando ele estava ativo é tela preta; iniciá-lo quando não
# estava é recuperável com um comando.
if [[ ! "$DM_WAS_ACTIVE" =~ ^[01]$ ]]; then
    dizer_erro "estado DM inválido; assumindo que estava ativo para não deixar tela preta"
    DM_WAS_ACTIVE=1
    FALHAS=$((FALHAS + 1))
fi
if [ "$GPU_DRIVER" != nvidia ]; then
    dizer_erro "driver GPU de estado inválido; assumindo nvidia, que é o único suportado"
    GPU_DRIVER=nvidia
    FALHAS=$((FALHAS + 1))
fi
if [[ ! "$AUDIO_DRIVER" =~ ^(snd_hda_intel)?$ ]]; then
    dizer_erro "driver de áudio inválido; nenhum será carregado"
    AUDIO_DRIVER=""
    FALHAS=$((FALHAS + 1))
fi

# REQ-VM-RESOURCE-LIFECYCLE: a devolução acontece antes da restauração da GPU,
# e a falha dela NÃO pode interromper o que vem depois. mem_devolver nunca
# aborta: devolve 1, a falha é contada, e GPU e display são restaurados do
# mesmo jeito.
mem_devolver || FALHAS=$((FALHAS + 1))

GPU_PRONTA=1
GPU_ESTAVEL=1
for modulo in nvidia nvidia_modeset nvidia_drm nvidia_uvm; do
    dizer "carregando $modulo..."
    if ! modprobe "$modulo"; then
        dizer_erro "modprobe $modulo falhou"
        FALHAS=$((FALHAS + 1))
    fi
done
if [ -n "$AUDIO_DRIVER" ] && ! modprobe "$AUDIO_DRIVER"; then
    dizer_erro "modprobe $AUDIO_DRIVER falhou"
    FALHAS=$((FALHAS + 1))
fi
if aguardar_driver "$GPU_PCI" "$GPU_DRIVER"; then
    hook_log "GPU $GPU_PCI confirmada no driver $GPU_DRIVER"
else
    GPU_PRONTA=0
    FALHAS=$((FALHAS + 1))
fi
if [ -n "$GPU_AUDIO_PCI" ] && ! aguardar_driver "$GPU_AUDIO_PCI" "$AUDIO_DRIVER"; then
    FALHAS=$((FALHAS + 1))
fi
if aguardar_drm_gpu; then
    hook_log "nó DRM da GPU presente; saída de vídeo disponível para o DM"
else
    dizer_erro "nó DRM da GPU não apareceu em 15 s; o desktop pode subir sem sinal de vídeo"
    GPU_PRONTA=0
    FALHAS=$((FALHAS + 1))
fi
# A prova de estabilidade só faz sentido quando a GPU já voltou inteira. Se ela
# nem chegou ao nvidia, o diagnóstico é outro e o comportamento antigo (tentar
# o desktop mesmo assim) continua valendo.
if [ "$GPU_PRONTA" -eq 1 ]; then
    if aguardar_udev_quieto; then
        hook_log "GPU estável por 5 s após drenar a fila do udev"
    else
        GPU_ESTAVEL=0
        FALHAS=$((FALHAS + 1))
        dizer_erro "a GPU não ficou estável: os módulos nvidia estão sendo recarregados em laço pelas regras udev da distro."
        dizer_erro "$DM NÃO será iniciado; subir o desktop nesse estado congela o host e obriga reset físico."
        dizer_erro "confirme com: journalctl -k | grep -c 'Nvlink Core is being initialized'"
        dizer_erro "correção: reexecute a etapa 14, que reinstala o filtro em /etc/udev/rules.d/71-nvidia.rules"
    fi
fi
if ! timeout 30 nvidia-smi >/dev/null; then
    dizer_erro "nvidia-smi não respondeu"
    FALHAS=$((FALHAS + 1))
fi
if [ "$DM_WAS_ACTIVE" -eq 1 ]; then
    if desligamento_em_andamento; then
        dizer "host em desligamento/reinício; $DM não será iniciado agora."
    elif [ "$GPU_ESTAVEL" -eq 0 ]; then
        dizer_erro "$DM mantido parado por causa do laço de recarga; use um TTY (Ctrl+Alt+F3) e rode bash util/recuperar-gpu.sh"
    elif iniciar_dm; then
        hook_log "$DM ativo; desktop restaurado"
    else
        dizer_erro "não foi possível iniciar $DM"
        FALHAS=$((FALHAS + 1))
    fi
else
    if ! DM_ESTADO_FINAL="$(systemctl show -p ActiveState --value "$DM")"; then
        dizer_erro "não foi possível consultar o estado final de $DM"
        FALHAS=$((FALHAS + 1))
    elif [ "$DM_ESTADO_FINAL" != inactive ]; then
        dizer_erro "$DM estava inativo antes, mas mudou para $DM_ESTADO_FINAL"
        FALHAS=$((FALHAS + 1))
    fi
fi
if [ "$FALHAS" -ne 0 ]; then
    dizer_erro "restauração incompleta ($FALHAS falha(s)); estado preservado em $STATE_FILE"
    dizer_erro "recupere por TTY/SSH com util/recuperar-gpu.sh; linha do tempo em $HOOK_LOG_ARQUIVO"
    exit 1
fi
rm -f -- "$STATE_FILE" \
    || { dizer_erro "pós-condições aprovadas, mas o estado não pôde ser removido: $STATE_FILE"; exit 1; }
dizer "GPU e desktop restaurados com pós-condições verificadas."
CORPO
    } > "$destino"
}

gerar_conjunto_hooks() {
    local diretorio="$1" legado="${2:-}"
    mkdir -p "$diretorio"
    # A política de memória é resolvida UMA vez, antes de qualquer heredoc: os
    # valores viajam assados dentro dos hooks, que não podem consultar o core.
    memoria_plano_resolver || true
    if [ -n "$MEM_PLANO_AVISO" ]; then
        aviso "Política de memória: $MEM_PLANO_AVISO"
        info "Os hooks são renderizados assim mesmo. Recusa transitória (consumidor no pool agora, memória apertada agora) é reavaliada no start. Recusa estrutural faz o plano assar zero páginas, e nesse caso o hook RECUSA o start em vez de subir a VM sem as páginas que o perfil promete."
    fi
    gerar_dispatcher "$diretorio/qemu" "$legado"
    gerar_prepare "$diretorio/prepare.sh"
    gerar_start "$diretorio/start.sh"
    gerar_release "$diretorio/release.sh"
    gerar_nvidia_udev_filtro "$diretorio/nvidia-udev-filtro.sh"
    local udev_origem="" udev_rc=0
    udev_origem="$(nvidia_udev_origem)" || udev_rc=$?
    if [ "$udev_rc" -eq 0 ]; then
        gerar_nvidia_udev_regras "$udev_origem" "$diretorio/nvidia.rules" || return 1
        chmod 0644 "$diretorio/nvidia.rules"
    elif [ "$udev_rc" -ne 1 ]; then
        # I9.9: rc 2 é "não consegui observar as regras da distro". Renderizar o
        # conjunto assim mesmo instalaria hooks que podem deixar o laço de
        # modprobe aberto, e a etapa reportaria sucesso por isso.
        erro "Não foi possível ler as regras udev da NVIDIA da distro; a renderização dos hooks foi recusada."
        return 1
    fi
    printf 'vm-passthrough gate obrigatório para %s\n' "$VM_NAME" > "$diretorio/required"
    printf 'transação de instalação em andamento para %s\n' "$VM_NAME" > "$diretorio/installing"
    # I9.5: mesmo o hook mais curto declara o próprio PATH. Ele só usa
    # builtins hoje, mas um hook libvirt herda o ambiente do daemon, e um PATH
    # herdado é a porta pela qual um comando inesperado entraria amanhã.
    cat > "$diretorio/installing.sh" <<'BLOQUEIO'
#!/bin/bash
# Hook prepare/begin: bloqueia eventos enquanto a instalação está em transação.
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin
echo "[hook install] configuração de passthrough em transação; evento bloqueado" >&2
exit 75
BLOQUEIO
    chmod 0755 "$diretorio/qemu" "$diretorio/prepare.sh" "$diretorio/start.sh" "$diretorio/release.sh" "$diretorio/installing.sh" "$diretorio/nvidia-udev-filtro.sh"
    chmod 0644 "$diretorio/required" "$diretorio/installing"
    local arquivo
    for arquivo in "$diretorio/qemu" "$diretorio/prepare.sh" "$diretorio/start.sh" "$diretorio/release.sh" "$diretorio/installing.sh" "$diretorio/nvidia-udev-filtro.sh"; do
        bash -n "$arquivo" || return 1
    done
}

validar_config_hooks
if [ "${1:-}" = "--renderizar-hooks" ]; then
    [ -n "${2:-}" ] && [ -d "$2" ] || falhar "Uso: $0 --renderizar-hooks DIRETORIO_EXISTENTE"
    caminho_absoluto_seguro "$2" || falhar "Diretório de renderização inseguro: $2"
    HD1_IDENTIDADE="TESTE-ID_SERIAL=renderizacao"
    gerar_conjunto_hooks "$2" ""
    ok "Hooks renderizados e aprovados em bash -n: $2"
    exit 0
fi

# As opções são resolvidas antes de qualquer preflight para que a transação
# saiba, desde o início, tudo o que precisará aplicar e provar.
PEDIU_REMOVER_VIDEO=0
PEDIU_ANTI_CODE43=0
for ARGUMENTO in "$@"; do
    case "$ARGUMENTO" in
        --remover-video) PEDIU_REMOVER_VIDEO=1 ;;
        --anti-code43) PEDIU_ANTI_CODE43=1 ;;
        *) falhar "Opção desconhecida da etapa 14: '$ARGUMENTO' (use --remover-video e/ou --anti-code43)." ;;
    esac
done

exigir_nao_root
exigir_sudo
exigir_comando virsh udevadm lsblk findmnt flock virt-xml-validate
python_core_disponivel \
    || falhar "O core Python do projeto não respondeu: ${PYTHON_CORE_ERRO:-diagnóstico ausente}."
# REQ-LIBVIRT-BACKEND: uma resolução autoritativa, a mesma consumida pela etapa
# 20. Nenhum ponto desta etapa pode assumir `libvirtd`.
if libvirt_backend_resolver; then
    info "Backend libvirt resolvido: $LIBVIRT_BACKEND_UNIDADE (daemon $LIBVIRT_BACKEND_UNIDADE_DAEMON)."
else
    BACKEND_RC=$?
    if [ "$BACKEND_RC" -eq 1 ]; then
        falhar "Nenhuma unidade libvirt do perfil está disponível: $LIBVIRT_BACKEND_ERRO Execute a etapa 9."
    fi
    falhar "Não foi possível resolver o backend libvirt: $LIBVIRT_BACKEND_ERRO"
fi
exigir_vm_desligada "$VM_NAME"
exigir_conf IOMMU_GROUP_GPU
validar_grupo_iommu_gpu \
    "$GPU_PCI_ID" "${GPU_AUDIO_PCI_ID:-}" "$IOMMU_GROUP_GPU" \
    "$GPU_VENDOR_DEVICE_ID" "${GPU_AUDIO_VENDOR_DEVICE_ID:-}" \
    || falhar "$IOMMU_ERRO"

titulo "Etapa 14: hooks dinâmicos e HD1 físico (VM: $VM_NAME)"

# Todos os preflights ocorrem antes da primeira mutação.
HD1_IDENTIDADE=""
if [ -n "${HD1_BY_ID_PATH:-}" ]; then
    inventario_revalidar_papeis_disco_configurados \
        || falhar "Identidade física de sistema/workingDisk/HD1 recusada: $INVENTARIO_ERRO"
    validar_disco_fisico_vm "$HD1_BY_ID_PATH" "${NVME_DEVICE:-}" \
        || falhar "$DISCO_VM_ERRO"
    ALVO_HD1="$DISCO_VM_ALVO"
    PROPRIEDADES_HD1="$(udevadm info --query=property --name "$ALVO_HD1" 2>/dev/null)" \
        || falhar "Não foi possível consultar a identidade udev de $ALVO_HD1."
    for CHAVE_ID in ID_WWN_WITH_EXTENSION ID_WWN ID_SERIAL; do
        HD1_IDENTIDADE="$(awk -F= -v k="$CHAVE_ID" '$1 == k && length($2) {print k "=" substr($0, index($0,"=")+1); exit}' \
            <<< "$PROPRIEDADES_HD1")"
        [ -z "$HD1_IDENTIDADE" ] || break
    done
    [ -n "$HD1_IDENTIDADE" ] || falhar "HD1 não possui WWN/serial estável para validar em todo start."
    echo "Disco físico autorizado após preflight: $HD1_BY_ID_PATH -> $ALVO_HD1"
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL "$ALVO_HD1"
fi

for ENDERECO in "$GPU_PCI_ID" ${GPU_AUDIO_PCI_ID:+"$GPU_AUDIO_PCI_ID"}; do
    hostdev_estado_xml "$ENDERECO" || falhar "Não foi possível inspecionar hostdev $ENDERECO."
    if [ "$HOSTDEV_TOTAL" != 0 ] && { [ "$HOSTDEV_TOTAL" != 1 ] || [ "$HOSTDEV_EXATO" != 1 ]; }; then
        falhar "O XML já contém $ENDERECO duplicado ou sem managed='yes'; corrija antes de continuar."
    fi
done
if [ -n "${HD1_BY_ID_PATH:-}" ]; then
    disco_estado_xml "$HD1_BY_ID_PATH" || falhar "Não foi possível inspecionar o HD1 no XML."
    if [ "$DISCO_XML_SOURCE" != 0 ] && { [ "$DISCO_XML_SOURCE" != 1 ] || [ "$DISCO_XML_EXATO" != 1 ]; }; then
        falhar "O XML contém o HD1 com atributos divergentes/duplicados; revisão manual necessária."
    fi
    if [ "$DISCO_XML_SOURCE" = 0 ] && [ "$DISCO_XML_VDB" != 0 ]; then
        falhar "O alvo vdb já pertence a outro disco no XML; não será substituído."
    fi
fi

# Sombrear 71-nvidia.rules em /etc anula o arquivo da distro inteiro. Adotar um
# override que não é desta etapa apagaria em silêncio uma decisão do usuário.
if sudo test -e "$NVIDIA_UDEV_REGRAS"; then
    sudo test ! -L "$NVIDIA_UDEV_REGRAS" \
        || falhar "Override das regras udev é link simbólico; adoção recusada: $NVIDIA_UDEV_REGRAS"
    sudo grep -qF "$MARCADOR_UDEV" "$NVIDIA_UDEV_REGRAS" \
        || falhar "Já existe $NVIDIA_UDEV_REGRAS fora da gestão desta etapa. Mova-o para fora de /etc/udev/rules.d e rode a etapa 14 de novo."
fi

# --- Vídeo virtual: decisão ativa no fluxo interativo --------------------------
# A remoção do QXL/SPICE não fica mais escondida atrás de --remover-video: no
# fluxo padrão do menu (sem flags, com TTY), quando a GPU real já está no XML e
# o vídeo virtual persiste, a pendência é exposta e o usuário decide. Sem TTY
# (testes, automação) nada muda. A confirmação final digitando REMOVER continua
# dentro da transação, como sempre.
oferecer_remocao_video_interativa() {
    local escolha video_estado=2
    [ "$PEDIU_REMOVER_VIDEO" -eq 0 ] || return 0
    [ -t 0 ] || return 0
    vm_existe "$VM_NAME" || return 0
    hostdev_estado_xml "$GPU_PCI_ID" || return 0
    [ "$HOSTDEV_TOTAL" = 1 ] && [ "$HOSTDEV_EXATO" = 1 ] || return 0
    if estado_video_virtual; then video_estado=0; else video_estado=$?; fi
    [ "$video_estado" -eq 0 ] || return 0
    echo
    aviso "O vídeo virtual QXL/SPICE ainda está no XML. Com a GPU real anexada, ele é o monitor PRIMÁRIO invisível do Windows: menu Iniciar e janelas novas abrem fora da tela física."
    info "Remova somente depois de validar um boot completo com passthrough: até lá, o console SPICE é o único display de socorro da VM."
    escolha="$(escolher_da_lista 'O que fazer com o vídeo virtual?' nao \
        'Manter o vídeo virtual por enquanto' \
        'Remover o vídeo virtual QXL/SPICE nesta execução')"
    if [ "$escolha" = 2 ]; then
        PEDIU_REMOVER_VIDEO=1
        info "Remoção do vídeo virtual incluída nesta transação (confirmação final digitando REMOVER adiante)."
    else
        aviso "Vídeo virtual mantido. Para remover depois: rode a etapa 14 de novo (menu) ou bash etapas/50-hooks-gpu-hd1.sh --remover-video."
    fi
}
oferecer_remocao_video_interativa

# --- Convergência: segunda execução precisa ser no-op exato -------------------
# D-HOOKS-IDEMPOTENCE: antes, uma execução sobre estado já convergido ainda
# criava backups, republicava arquivos e reiniciava o daemon. Aqui o estado
# gerenciado é comparado byte a byte (mais dono e modo) e, quando tudo já está
# no lugar, a etapa termina sem nenhum efeito: sem backup, sem mv, sem restart.
# A comparação é somente leitura e usa exclusivamente o conjunto renderizado.

_legacy_hook_do_dispatcher() {
    # Somente leitura: extrai LEGACY_HOOK do dispatcher gerenciado instalado.
    # Qualquer ambiguidade devolve 1, e a etapa segue pelo caminho normal.
    local declaracao
    sudo test -f "$HOOK_QEMU" || return 1
    sudo test ! -L "$HOOK_QEMU" || return 1
    sudo grep -qF "$MARCADOR_DISPATCHER" "$HOOK_QEMU" || return 1
    [ "$(sudo grep -Ec '^LEGACY_HOOK=' "$HOOK_QEMU")" -eq 1 ] || return 1
    declaracao="$(sudo grep -E '^LEGACY_HOOK=' "$HOOK_QEMU")" || return 1
    _decodificar_literal_conf "${declaracao#LEGACY_HOOK=}" || return 1
    printf '%s' "$REPLY"
}

_arquivo_gerenciado_identico() {
    # $1 = origem renderizada; $2 = destino instalado; $3 = modo esperado.
    local origem="$1" destino="$2" modo="$3"
    sudo test -f "$destino" || return 1
    sudo test ! -L "$destino" || return 1
    [ "$(sudo stat -c %u -- "$destino")" -eq 0 ] || return 1
    [ "$(sudo stat -c %a -- "$destino")" = "$modo" ] || return 1
    sudo cmp -s -- "$origem" "$destino" || return 1
}

hooks_convergidos() {
    local render legado par origem destino modo rc=0
    legado="$(_legacy_hook_do_dispatcher)" || return 1
    # Marcadores temporários e hooks antigos indicam transação interrompida ou
    # migração pendente: nunca é estado convergido.
    ! sudo test -e "$INSTALLING_MARKER" || return 1
    ! sudo test -e "$INSTALLING_HOOK" || return 1
    ! sudo test -e "$PREPARE_ANTIGO" || return 1
    ! sudo test -e "$RELEASE_ANTIGO" || return 1
    render="$(mktemp -d)" || return 1
    if ! gerar_conjunto_hooks "$render" "$legado"; then
        rm -rf -- "$render"
        return 1
    fi
    for par in \
        "qemu|$HOOK_QEMU|755" \
        "required|$GATE_REQUIRED|644" \
        "prepare.sh|$PREPARE|755" \
        "start.sh|$START|755" \
        "release.sh|$RELEASE|755" \
        "nvidia-udev-filtro.sh|$NVIDIA_UDEV_FILTRO|755"; do
        origem="$render/${par%%|*}"
        destino="${par#*|}"
        modo="${destino#*|}"
        destino="${destino%%|*}"
        if ! _arquivo_gerenciado_identico "$origem" "$destino" "$modo"; then
            rc=1
            break
        fi
    done
    if [ "$rc" -eq 0 ] && [ -f "$render/nvidia.rules" ] \
       && ! _arquivo_gerenciado_identico "$render/nvidia.rules" "$NVIDIA_UDEV_REGRAS" 644; then
        rc=1
    fi
    rm -rf -- "$render"
    return "$rc"
}

dispositivos_convergidos() {
    local endereco
    for endereco in "$GPU_PCI_ID" ${GPU_AUDIO_PCI_ID:+"$GPU_AUDIO_PCI_ID"}; do
        hostdev_estado_xml "$endereco" || return 1
        [ "$HOSTDEV_TOTAL" = 1 ] && [ "$HOSTDEV_EXATO" = 1 ] || return 1
    done
    if [ -n "${HD1_BY_ID_PATH:-}" ]; then
        disco_estado_xml "$HD1_BY_ID_PATH" || return 1
        [ "$DISCO_XML_SOURCE" = 1 ] && [ "$DISCO_XML_EXATO" = 1 ] || return 1
    fi
    return 0
}

opcoes_convergidas() {
    # Uma opção já aplicada não muda o candidato. A checagem escreve apenas em
    # temporários e não toca o domínio.
    local origem candidato indice=0 rc=0
    local -a operacoes=() payload=()
    [ "$PEDIU_REMOVER_VIDEO" -eq 1 ] && operacoes+=(remove-video)
    [ "$PEDIU_ANTI_CODE43" -eq 1 ] && operacoes+=(anti-code43)
    (( ${#operacoes[@]} > 0 )) || return 0
    origem="$(mktemp)" || return 1
    candidato="$(mktemp)" || { rm -f -- "$origem"; return 1; }
    if ! $VIRSH dumpxml --inactive "$VM_NAME" > "$origem"; then
        rm -f -- "$origem" "$candidato"
        return 1
    fi
    payload=(op_count "${#operacoes[@]}")
    for indice in "${!operacoes[@]}"; do
        payload+=("op_$indice" "${operacoes[$indice]}")
        [ "${operacoes[$indice]}" != anti-code43 ] \
            || payload+=("op_${indice}_vendor_id" randomid123)
    done
    if ! _xml_candidato_gerar "$origem" "$candidato" "${payload[@]}"; then
        rc=1
    elif [ "$XML_CANDIDATO_MUDOU" != 0 ]; then
        rc=1
    fi
    rm -f -- "$origem" "$candidato"
    return "$rc"
}

if hooks_convergidos && dispositivos_convergidos && opcoes_convergidas; then
    echo
    ok "Estado já convergido: dispatcher, três hooks, marcador do gate, GPU/áudio, HD1 e opções conferem byte a byte."
    info "Nenhuma alteração foi feita: nenhum backup novo, nenhuma republicação e nenhum restart do daemon."
    info "Para revalidar sem alterar nada: bash etapas/50-hooks-gpu-hd1.sh --verificar"
    exit 0
fi

echo
cat <<'ORIENTACAO'
Resumo antes de aplicar:
  - finalidade: entregar GPU/áudio à VM com hooks transacionais do libvirt;
  - pré-requisitos: VM desligada, IOMMU/preflights aprovados e acesso por TTY;
  - HD1: totalmente opcional; a opção 0 mantém somente o QCOW2;
  - alterações: hooks do host e XML persistente; não exige reboot do host;
  - recomendação/risco: valide primeiro o Windows no QCOW2 e tenha backup do HD1;
  - retorno: falha ou cancelamento restaura a transação; se houver HD1, cancelar
    a segunda confirmação ANEXAR também restaura automaticamente hooks e XML.
ORIENTACAO

titulo "Confirmação antes de alterar hooks e XML"
info "Todos os preflights terminaram. Até este ponto, hooks e XML da VM não foram alterados."
info "A etapa instalará/atualizará hooks do libvirt e anexará GPU/áudio ao XML persistente da VM."
if [ -n "${HD1_BY_ID_PATH:-}" ]; then
    echo "Disco físico que também será autorizado:"
    lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL "$ALVO_HD1"
    aviso "PERDA DE DADOS: o Windows terá escrita no DISCO INTEIRO acima e em todas as suas partições."
    aviso "O script não o formata, mas inicializar, reparticionar, formatar ou instalar o Windows"
    aviso "nesse disco pode destruir todos os dados. Confirme que existe backup verificado."
    aviso "Conclua antes a instalação do Windows no QCOW2 e nunca selecione este HD físico como destino do instalador."
else
    info "Opção 0 registrada: nenhum disco físico será anexado; a VM permanecerá somente com o QCOW2."
fi
confirmar_digitando APLICAR \
    "Aplicar agora as alterações de hooks e XML descritas acima?" \
    || cancelar_etapa "Aplicação cancelada antes da primeira alteração persistente."

XML_ANTES="$(mktemp)" || falhar "Não foi possível criar backup temporário do XML."
$VIRSH dumpxml --inactive "$VM_NAME" > "$XML_ANTES" || falhar "Não foi possível capturar XML original."
xml_backup "$VM_NAME"

# Nenhum sibling/legado desconhecido pode continuar gerindo PCI em paralelo ao
# hostdev managed='yes'. Hooks antigos deste próprio projeto são migrados abaixo.
HOOKS_EXISTENTES=()
for HOOK_ANTIGO in "$PREPARE_ANTIGO" "$RELEASE_ANTIGO"; do
    if sudo test -e "$HOOK_ANTIGO"; then
        sudo test ! -L "$HOOK_ANTIGO" || falhar "Hook antigo é link simbólico: $HOOK_ANTIGO"
        sudo grep -qF 'gerado por etapas/50-hooks-gpu-hd1.sh' "$HOOK_ANTIGO" \
            || falhar "Arquivo desconhecido ocupa o nome de um hook antigo: $HOOK_ANTIGO"
    fi
done
if sudo test -d "$HOOK_BASE"; then
    HOOK_LISTA="$(mktemp)" || falhar "Não foi possível criar inventário temporário de hooks."
    if ! sudo find "$HOOK_BASE" -mindepth 1 \( -type f -o -type l \) -print0 > "$HOOK_LISTA"; then
        rm -f -- "$HOOK_LISTA"
        falhar "Não foi possível enumerar integralmente os hooks existentes."
    fi
    mapfile -d '' -t HOOKS_EXISTENTES < "$HOOK_LISTA"
    rm -f -- "$HOOK_LISTA"
fi
for HOOK_EXISTENTE in "${HOOKS_EXISTENTES[@]}"; do
    sudo test ! -L "$HOOK_EXISTENTE" \
        || falhar "Link simbólico dentro de qemu.d é recusado: $HOOK_EXISTENTE"
    sudo test -f "$HOOK_EXISTENTE" \
        || falhar "Entrada não regular dentro de qemu.d: $HOOK_EXISTENTE"
    [ "$(sudo stat -c %u -- "$HOOK_EXISTENTE")" -eq 0 ] \
        || falhar "Hook existente não pertence ao root: $HOOK_EXISTENTE"
    if sudo find "$HOOK_EXISTENTE" -maxdepth 0 -perm /022 -print -quit | grep -q .; then
        falhar "Hook existente é gravável por grupo/outros: $HOOK_EXISTENTE"
    fi
    case "$HOOK_EXISTENTE" in
        "$PREPARE"|"$START"|"$RELEASE") continue ;;
        "$PREPARE_ANTIGO")
            sudo grep -qF '01-gpu-para-vfio.sh (gerado por etapas/50-hooks-gpu-hd1.sh)' "$HOOK_EXISTENTE" \
                || falhar "Arquivo desconhecido ocupa o nome do hook antigo: $HOOK_EXISTENTE"
            continue
            ;;
        "$RELEASE_ANTIGO")
            sudo grep -qF '01-gpu-para-linux.sh (gerado por etapas/50-hooks-gpu-hd1.sh)' "$HOOK_EXISTENTE" \
                || falhar "Arquivo desconhecido ocupa o nome do hook antigo: $HOOK_EXISTENTE"
            continue
            ;;
    esac
    if sudo grep -Eq '/sys/bus/pci|nodedev-(detach|reattach)|vfio-pci/(bind|unbind|new_id)|driver/unbind' "$HOOK_EXISTENTE"; then
        falhar "Hook adicional tenta gerir PCI e conflita com managed='yes': $HOOK_EXISTENTE"
    fi
done

titulo "Etapa 14.1/5 Dispatcher e hooks transacionais"
LEGADO=""
INSTALAR_DISPATCHER=1
if sudo test -e "$HOOK_QEMU" || sudo test -L "$HOOK_QEMU"; then
    sudo test ! -L "$HOOK_QEMU" || falhar "Hook global é link simbólico; adoção recusada: $HOOK_QEMU"
    sudo test -f "$HOOK_QEMU" || falhar "Hook global existente não é arquivo regular: $HOOK_QEMU"
    [ "$(sudo stat -c %u -- "$HOOK_QEMU")" -eq 0 ] \
        || falhar "Hook global existente não pertence ao root: $HOOK_QEMU"
    if sudo find "$HOOK_QEMU" -maxdepth 0 -perm /022 -print -quit | grep -q .; then
        falhar "Hook global existente é gravável por grupo/outros; adoção recusada."
    fi
    sudo bash -n "$HOOK_QEMU" || falhar "Hook global existente tem sintaxe inválida; não será substituído."
    if sudo grep -qF "$MARCADOR_DISPATCHER" "$HOOK_QEMU"; then
        LEGACY_DECLARACAO="$(sudo grep -E '^LEGACY_HOOK=' "$HOOK_QEMU")" \
            || falhar "Dispatcher gerenciado não contém LEGACY_HOOK."
        [ "$(sudo grep -Ec '^LEGACY_HOOK=' "$HOOK_QEMU")" -eq 1 ] \
            || falhar "Dispatcher gerenciado contém LEGACY_HOOK ambíguo."
        _decodificar_literal_conf "${LEGACY_DECLARACAO#LEGACY_HOOK=}" \
            || falhar "LEGACY_HOOK do dispatcher gerenciado é inválido."
        LEGADO="$REPLY"
        if [ -n "$LEGADO" ]; then
            caminho_absoluto_seguro "$LEGADO" \
                || falhar "LEGACY_HOOK inseguro no dispatcher existente."
            sudo test -f "$LEGADO" && sudo test ! -L "$LEGADO" \
                || falhar "LEGACY_HOOK preservado não é arquivo regular seguro: $LEGADO"
            [ "$(sudo stat -c %u -- "$LEGADO")" -eq 0 ] \
                || falhar "LEGACY_HOOK preservado não pertence ao root."
            if sudo find "$LEGADO" -maxdepth 0 -perm /022 -print -quit | grep -q .; then
                falhar "LEGACY_HOOK preservado é gravável por grupo/outros."
            fi
        fi
        info "Dispatcher v2 já gerenciado; será atualizado atomicamente para a versão atual."
    elif sudo grep -qF '/etc/libvirt/hooks/qemu.d' "$HOOK_QEMU"; then
        if sudo grep -qF 'Dispatcher principal de hooks do libvirt para objetos QEMU.' "$HOOK_QEMU"; then
            BACKUP_DISPATCHER_ANTIGO="${HOOK_QEMU}.pre-vm-passthrough-${STAMP}"
            sudo cp -a -- "$HOOK_QEMU" "$BACKUP_DISPATCHER_ANTIGO" \
                || falhar "Não foi possível preservar o dispatcher antigo."
            info "Dispatcher antigo reconhecido e arquivado em: $BACKUP_DISPATCHER_ANTIGO"
        else
            falhar "Dispatcher qemu.d não gerenciado já existe. Integração automática recusada para evitar execução dupla."
        fi
    else
        if sudo grep -Eq '/sys/bus/pci|nodedev-(detach|reattach)|vfio-pci/(bind|unbind|new_id)|driver/unbind' "$HOOK_QEMU"; then
            falhar "Hook global legado gere PCI diretamente; migração automática recusada para manter managed='yes' como única autoridade."
        fi
        LEGADO="${HOOK_QEMU}.pre-vm-passthrough-${STAMP}"
        sudo cp -a -- "$HOOK_QEMU" "$LEGADO" || falhar "Não foi possível preservar o hook global existente."
        info "Hook legado preservado em: $LEGADO"
    fi
fi
RENDER_DIR="$(mktemp -d)" || falhar "Não foi possível criar diretório de renderização."
limpar_temporarios() {
    rm -rf -- "$RENDER_DIR"
    rm -f -- "$XML_ANTES"
    encerrar_sudo_keepalive
}
trap limpar_temporarios EXIT
gerar_conjunto_hooks "$RENDER_DIR" "$LEGADO" || falhar "Hooks gerados não passaram em bash -n."

DESTINOS=()
BACKUPS=()
EXISTIAM=()
BACKUP_ROOT="/etc/libvirt/hooks/.vm-passthrough-backups/$STAMP"
TRANSACAO_ATIVA=0
XML_MUTADO=0
UDEV_REGRAS_MUTADAS=0
PRESERVAR_XML=0
instalar_root_atomico() {
    # $3=1 preserva dono/modo de um diretório que já existe. Só o filtro udev
    # usa isso: ele mora fora da árvore de hooks e /usr/local/sbin é root:staff
    # 2775 por política da distro, que um install -d cego reescreveria.
    local origem="$1" destino="$2" preservar_dir="${3:-0}" diretorio temporario
    diretorio="$(dirname "$destino")"
    if [ "$preservar_dir" != 1 ] || ! sudo test -d "$diretorio"; then
        sudo install -d -o root -g root -m 0755 "$diretorio" || return 1
    fi
    sudo test ! -L "$destino" || return 1
    temporario="$(sudo mktemp "${destino}.tmp.XXXXXX")" || return 1
    if ! sudo install -o root -g root -m 0755 "$origem" "$temporario" \
       || ! sudo bash -n "$temporario"; then
        sudo rm -f -- "$temporario"
        return 1
    fi
    sudo mv -fT -- "$temporario" "$destino" || { sudo rm -f -- "$temporario"; return 1; }
}
instalar_dado_root_atomico() {
    local origem="$1" destino="$2" diretorio temporario
    diretorio="$(dirname "$destino")"
    sudo install -d -o root -g root -m 0755 "$diretorio" || return 1
    sudo test ! -L "$destino" || return 1
    temporario="$(sudo mktemp "${destino}.tmp.XXXXXX")" || return 1
    if ! sudo install -o root -g root -m 0644 "$origem" "$temporario"; then
        sudo rm -f -- "$temporario"
        return 1
    fi
    sudo mv -fT -- "$temporario" "$destino" || { sudo rm -f -- "$temporario"; return 1; }
}
registrar_backup_destino() {
    local destino="$1" backup="" existia=0
    sudo test ! -L "$destino" || return 1
    if sudo test -e "$destino"; then
        sudo install -d -o root -g root -m 0700 "$BACKUP_ROOT" || return 1
        backup="$BACKUP_ROOT/${#DESTINOS[@]}-$(basename "$destino")"
        sudo cp -a -- "$destino" "$backup" || return 1
        existia=1
    fi
    DESTINOS+=("$destino")
    BACKUPS+=("$backup")
    EXISTIAM+=("$existia")
}
instalar_com_backup() {
    local origem="$1" destino="$2" preservar_dir="${3:-0}"
    registrar_backup_destino "$destino" || return 1
    instalar_root_atomico "$origem" "$destino" "$preservar_dir"
}
instalar_dado_com_backup() {
    local origem="$1" destino="$2"
    registrar_backup_destino "$destino" || return 1
    instalar_dado_root_atomico "$origem" "$destino"
}
remover_com_backup() {
    local destino="$1"
    sudo test -e "$destino" || return 0
    registrar_backup_destino "$destino" || return 1
    sudo rm -f -- "$destino"
}
rollback_hooks() {
    local i falhou=0
    erro "Revertendo arquivos de hook instalados nesta execução..."
    for ((i=${#DESTINOS[@]}-1; i>=0; i--)); do
        if [ "${EXISTIAM[$i]}" -eq 1 ]; then
            if ! sudo cp -a -- "${BACKUPS[$i]}" "${DESTINOS[$i]}"; then
                erro "Falha ao restaurar ${DESTINOS[$i]}"
                falhou=1
            fi
        elif ! sudo rm -f -- "${DESTINOS[$i]}"; then
            erro "Falha ao remover ${DESTINOS[$i]}"
            falhou=1
        fi
    done
    [ "$falhou" -eq 0 ]
}
rollback_xml() {
    # Restaura o XML original e PROVA a restauração relendo o domínio e
    # comparando semanticamente. Um define que retorna zero sem aplicar
    # (rollback divergente) precisa virar erro grave, não sucesso silencioso.
    local dump rc_compare=0
    if ! $VIRSH define "$XML_ANTES" >/dev/null; then
        erro "ROLLBACK XML NÃO COMPROVADO: o virsh recusou restaurar o XML original."
        return 1
    fi
    dump="$(mktemp)" || { erro "ROLLBACK XML NÃO COMPROVADO: sem temporário para releitura."; return 1; }
    if ! $VIRSH dumpxml --inactive "$VM_NAME" > "$dump"; then
        rm -f -- "$dump"
        erro "ROLLBACK XML NÃO COMPROVADO: não foi possível reler o domínio restaurado."
        return 1
    fi
    xml_dominio_equivalente "$XML_ANTES" "$dump" full || rc_compare=$?
    rm -f -- "$dump"
    if [ "$rc_compare" -eq 0 ]; then
        aviso "XML original restaurado e comprovado por releitura semântica."
        return 0
    fi
    if [ "$rc_compare" -eq 2 ]; then
        erro "ROLLBACK XML NÃO COMPROVADO: falha ao comparar o domínio restaurado: $XML_COMPARACAO_ERRO"
    else
        erro "ROLLBACK XML NÃO COMPROVADO: o domínio restaurado divergiu do original (${XML_COMPARACAO_DIFERENCA:-divergência semântica})."
    fi
    return 1
}

rollback_total() {
    local falhou=0
    set +e
    if [ "$XML_MUTADO" -eq 1 ]; then
        rollback_xml || falhou=1
    fi
    rollback_hooks || falhou=1
    # As regras restauradas só voltam a valer depois do reload; sem isto o host
    # ficaria com o arquivo antigo em disco e o filtro revertido ainda ativo.
    if [ "$UDEV_REGRAS_MUTADAS" -eq 1 ]; then
        sudo udevadm control --reload-rules \
            || { erro "Regras udev revertidas em disco, mas o udev não recarregou. Rode: sudo udevadm control --reload-rules"; falhou=1; }
    fi
    libvirt_backend_reiniciar \
        || { erro "Hooks foram revertidos, mas o daemon libvirt não reiniciou: $LIBVIRT_BACKEND_ERRO Não inicie VMs."; falhou=1; }
    if [ "$falhou" -ne 0 ]; then
        PRESERVAR_XML=1
        return 1
    fi
    return 0
}
finalizar_transacao() {
    local rc=$?
    trap - EXIT INT TERM
    if [ "$TRANSACAO_ATIVA" -eq 1 ]; then
        rollback_total || erro "Rollback incompleto; backups foram preservados para recuperação manual."
    fi
    rm -rf -- "$RENDER_DIR"
    if [ "$PRESERVAR_XML" -eq 0 ]; then
        rm -f -- "$XML_ANTES"
    else
        erro "XML original preservado em: $XML_ANTES"
    fi
    python_core_temporarios_limpar
    encerrar_sudo_keepalive
    exit "$rc"
}
trap finalizar_transacao EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
TRANSACAO_ATIVA=1

instalar_dado_com_backup "$RENDER_DIR/installing" "$INSTALLING_MARKER" \
    || falhar "Falha ao publicar marcador de transação."
instalar_com_backup "$RENDER_DIR/installing.sh" "$INSTALLING_HOOK" \
    || falhar "Falha ao publicar hook de bloqueio durante a transação."
if [ "$INSTALAR_DISPATCHER" -eq 1 ]; then
    instalar_com_backup "$RENDER_DIR/qemu" "$HOOK_QEMU" \
        || falhar "Falha ao instalar dispatcher atomicamente."
fi
instalar_dado_com_backup "$RENDER_DIR/required" "$GATE_REQUIRED" \
    || falhar "Falha ao instalar marcador fail-closed do gate."
instalar_com_backup "$RENDER_DIR/prepare.sh" "$PREPARE" \
    || falhar "Falha ao instalar prepare/begin."
instalar_com_backup "$RENDER_DIR/start.sh" "$START" \
    || falhar "Falha ao instalar start/begin."
instalar_com_backup "$RENDER_DIR/release.sh" "$RELEASE" \
    || falhar "Falha ao instalar release/end."
instalar_com_backup "$RENDER_DIR/nvidia-udev-filtro.sh" "$NVIDIA_UDEV_FILTRO" 1 \
    || falhar "Falha ao instalar o filtro de modprobe das regras udev da NVIDIA."
if [ -f "$RENDER_DIR/nvidia.rules" ]; then
    UDEV_REGRAS_MUTADAS=1
    instalar_dado_com_backup "$RENDER_DIR/nvidia.rules" "$NVIDIA_UDEV_REGRAS" \
        || falhar "Falha ao instalar o override das regras udev da NVIDIA."
    sudo udevadm control --reload-rules \
        || falhar "O udev recusou recarregar as regras; a transação restaurará os arquivos anteriores."
    ok "Regras udev da NVIDIA filtradas: o laço de recarga dos módulos na janela vfio está fechado."
else
    aviso "Nenhuma regra udev da NVIDIA com modprobe direto foi encontrada; filtro instalado mas sem override a aplicar."
fi
remover_com_backup "$PREPARE_ANTIGO" \
    || falhar "Falha ao migrar o hook prepare antigo."
remover_com_backup "$RELEASE_ANTIGO" \
    || falhar "Falha ao migrar o hook release antigo."

libvirt_backend_reiniciar \
    || falhar "$LIBVIRT_BACKEND_UNIDADE_DAEMON não aceitou a instalação ($LIBVIRT_BACKEND_ERRO); a transação restaurará os hooks anteriores."
ok "Dispatcher e três hooks instalados atomicamente; falhas agora abortam o evento libvirt."

titulo "Etapa 14.2/5 GPU e áudio no XML com managed='yes'"

anexar_hostdev_pci() {
    local endereco="${1,,}" dom bus slot func arquivo
    hostdev_estado_xml "$endereco" || return 1
    if [ "$HOSTDEV_TOTAL" = 1 ] && [ "$HOSTDEV_EXATO" = 1 ]; then
        info "hostdev $endereco já está correto; preservado."
        return 0
    fi
    [ "$HOSTDEV_TOTAL" = 0 ] || return 1
    IFS=':.' read -r dom bus slot func <<< "$endereco"
    arquivo="$(mktemp)" || return 1
    cat > "$arquivo" <<XML
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x$dom' bus='0x$bus' slot='0x$slot' function='0x$func'/>
  </source>
</hostdev>
XML
    XML_MUTADO=1
    if ! $VIRSH attach-device "$VM_NAME" "$arquivo" --config; then
        rm -f -- "$arquivo"
        return 1
    fi
    rm -f -- "$arquivo"
    hostdev_estado_xml "$endereco" \
        && [ "$HOSTDEV_TOTAL" = 1 ] && [ "$HOSTDEV_EXATO" = 1 ]
}

XML_FALHOU=0
anexar_hostdev_pci "$GPU_PCI_ID" || XML_FALHOU=1
if [ "$XML_FALHOU" -eq 0 ] && [ -n "${GPU_AUDIO_PCI_ID:-}" ]; then
    anexar_hostdev_pci "$GPU_AUDIO_PCI_ID" || XML_FALHOU=1
fi
if [ "$XML_FALHOU" -ne 0 ]; then
    falhar "Não foi possível anexar GPU/áudio com pós-condição exata; a transação restaurará XML e hooks."
fi
ok "GPU e áudio configurados sob gestão exclusiva do libvirt."

titulo "Etapa 14.3/5 Disco físico no XML (opcional)"
anexar_hd1() {
    local arquivo
    [ -n "${HD1_BY_ID_PATH:-}" ] || { info "Fluxo sem HD1 físico; somente QCOW2."; return 0; }
    disco_estado_xml "$HD1_BY_ID_PATH" || return 1
    if [ "$DISCO_XML_SOURCE" = 1 ] && [ "$DISCO_XML_EXATO" = 1 ]; then
        info "HD1 já está correto no XML; preflight foi repetido e aprovado."
        return 0
    fi
    [ "$DISCO_XML_SOURCE" = 0 ] && [ "$DISCO_XML_VDB" = 0 ] || return 1
    echo "Revisão final do disco antes do attach:"
    lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL "$ALVO_HD1" || return 1
    aviso "PERDA DE DADOS: este attach concede ao Windows escrita no disco inteiro e em todas as partições."
    aviso "Não inicialize, reparticione nem formate o disco no Windows se deseja preservar os dados existentes."
    confirmar_digitando ANEXAR \
        "Entregar $HD1_BY_ID_PATH ($ALVO_HD1, $HD1_IDENTIDADE) à VM?" \
        || return "$CODIGO_VOLTAR_MENU"
    arquivo="$(mktemp)" || return 1
    cat > "$arquivo" <<XML
<disk type='block' device='disk'>
  <driver name='qemu' type='raw' cache='none'/>
  <source dev='$HD1_BY_ID_PATH'/>
  <target dev='vdb' bus='virtio'/>
</disk>
XML
    XML_MUTADO=1
    if ! $VIRSH attach-device "$VM_NAME" "$arquivo" --config; then
        rm -f -- "$arquivo"
        return 1
    fi
    rm -f -- "$arquivo"
    disco_estado_xml "$HD1_BY_ID_PATH" \
        && [ "$DISCO_XML_SOURCE" = 1 ] && [ "$DISCO_XML_EXATO" = 1 ]
}
if anexar_hd1; then
    :
else
    ANEXAR_RC=$?
    if [ "$ANEXAR_RC" -eq "$CODIGO_VOLTAR_MENU" ]; then
        aviso "Attach cancelado; a transação restaurará automaticamente hooks e XML anteriores."
        exit "$CODIGO_VOLTAR_MENU"
    fi
    falhar "HD1 não foi anexado com segurança; a transação restaurará XML e hooks."
fi
titulo "Etapa 14.4/5 Opções de vídeo/hypervisor (dentro da transação)"
# REQ-HOOKS-TX: as opções deixaram de ocorrer depois do commit. Elas entram na
# mesma transação, como um único candidato validado pelo schema do libvirt,
# definido uma vez e comprovado por releitura. Falha ou sinal aqui restaura
# hooks, serviço e XML como em qualquer outra janela mutante.
OPCOES_XML=()
OPCOES_DESCRICAO=()
if [ "$PEDIU_REMOVER_VIDEO" -eq 1 ]; then
    aviso "Remova o vídeo virtual somente após validar um boot completo com passthrough."
    if confirmar_digitando REMOVER "A saída gráfica virtual QXL/SPICE será removida."; then
        OPCOES_XML+=(remove-video)
        OPCOES_DESCRICAO+=("remoção do vídeo virtual")
    else
        aviso "Resposta diferente de REMOVER: a remoção do vídeo virtual NÃO será aplicada nesta execução."
        aviso "A transação continua sem essa alteração; para remover depois, rode a etapa 14 de novo (menu) ou bash etapas/50-hooks-gpu-hd1.sh --remover-video."
    fi
fi
if [ "$PEDIU_ANTI_CODE43" -eq 1 ]; then
    OPCOES_XML+=(anti-code43)
    OPCOES_DESCRICAO+=("ocultação do hypervisor (anti-Code 43)")
fi

aplicar_opcoes_xml() {
    local origem candidato pos prova indice=0
    local -a payload=()
    (( ${#OPCOES_XML[@]} > 0 )) || { info "Nenhuma opção de vídeo/hypervisor solicitada."; return 0; }
    origem="$(mktemp)" || return 1
    candidato="$(mktemp)" || { rm -f -- "$origem"; return 1; }
    pos="$(mktemp)" || { rm -f -- "$origem" "$candidato"; return 1; }
    prova="$(mktemp)" || { rm -f -- "$origem" "$candidato" "$pos"; return 1; }
    limpar_opcoes() { rm -f -- "$origem" "$candidato" "$pos" "$prova"; }
    if ! $VIRSH dumpxml --inactive "$VM_NAME" > "$origem"; then
        limpar_opcoes
        erro "Não foi possível capturar o XML antes das opções."
        return 1
    fi
    payload=(op_count "${#OPCOES_XML[@]}")
    for indice in "${!OPCOES_XML[@]}"; do
        payload+=("op_$indice" "${OPCOES_XML[$indice]}")
        [ "${OPCOES_XML[$indice]}" != anti-code43 ] \
            || payload+=("op_${indice}_vendor_id" randomid123)
    done
    if ! _xml_candidato_gerar "$origem" "$candidato" "${payload[@]}"; then
        limpar_opcoes
        erro "Candidato das opções recusado: $XML_CANDIDATO_ERRO"
        return 1
    fi
    if [ "$XML_CANDIDATO_MUDOU" != 1 ]; then
        limpar_opcoes
        info "Opções já aplicadas no XML persistente: ${OPCOES_DESCRICAO[*]}."
        return 0
    fi
    if ! virt-xml-validate "$candidato" domain >/dev/null; then
        limpar_opcoes
        erro "O schema libvirt recusou o candidato das opções; nada foi definido."
        return 1
    fi
    XML_MUTADO=1
    if ! $VIRSH define "$candidato" >/dev/null; then
        limpar_opcoes
        erro "virsh define recusou o candidato das opções."
        return 1
    fi
    if ! $VIRSH dumpxml --inactive "$VM_NAME" > "$pos"; then
        limpar_opcoes
        erro "Não foi possível reler o XML após aplicar as opções."
        return 1
    fi
    # Pós-condição por idempotência, não por igualdade textual/semântica total:
    # o libvirt normaliza o domínio ao definir (endereços, valores implícitos),
    # então exigir XML idêntico ao candidato produziria falso negativo. Gerar o
    # mesmo candidato sobre o estado persistido e obter "nada a mudar" prova
    # exatamente que cada opção pedida está aplicada.
    if ! _xml_candidato_gerar "$pos" "$prova" "${payload[@]}"; then
        limpar_opcoes
        erro "Não foi possível comprovar as opções no XML persistido: $XML_CANDIDATO_ERRO"
        return 1
    fi
    if [ "$XML_CANDIDATO_MUDOU" != 0 ]; then
        limpar_opcoes
        erro "O XML persistido não reflete as opções pedidas: ${OPCOES_DESCRICAO[*]}."
        return 1
    fi
    limpar_opcoes
    ok "Opções aplicadas e comprovadas por releitura: ${OPCOES_DESCRICAO[*]}."
}
aplicar_opcoes_xml \
    || falhar "Opções de vídeo/hypervisor não foram aplicadas com prova; a transação restaurará XML e hooks."

titulo "Etapa 14.5/5 Commit da transação"
exigir_vm_desligada "$VM_NAME"
remover_com_backup "$INSTALLING_HOOK" \
    || falhar "Falha ao retirar o bloqueio temporário de start."
remover_com_backup "$INSTALLING_MARKER" \
    || falhar "Falha ao retirar o marcador temporário de transação."
TRANSACAO_ATIVA=0
rm -f -- "$XML_ANTES"
ok "Configuração persistente de dispositivos validada."

cat <<'RECUPERACAO'

Recuperação e reversão:
  - falha/sinal ou cancelamento de ANEXAR durante a transação: rollback automático;
  - GPU não restaurada ao host: use um TTY e execute bash util/recuperar-gpu.sh;
  - após sucesso não há --desfazer: restaure o backup XML informado e, se
    necessário, os hooks em /etc/libvirt/hooks/.vm-passthrough-backups/.
  O utilitário de recuperação da GPU não desfaz o XML nem os hooks persistentes.
RECUPERACAO

cat <<TESTE

Como testar manualmente somente após backup e janela de manutenção:
  1. bash etapas/50-hooks-gpu-hd1.sh --verificar
  2. virsh --connect qemu:///system start $VM_NAME
  3. sudo journalctl -u libvirtd -e | grep -i hook
  4. Desligar o Windows e confirmar GPU em nvidia e $DM_SERVICE ativo.
Se a restauração falhar, use um TTY e rode: bash util/recuperar-gpu.sh
TESTE
ok "Etapa 14 concluída sem executar o primeiro start da VM."
