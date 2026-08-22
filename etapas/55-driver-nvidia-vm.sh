#!/bin/bash
# ============================================================================
# etapas/55-driver-nvidia-vm.sh - Etapa 15: instalar o driver NVIDIA dentro
# da VM, de ponta a ponta e sem depender de vídeo
# ============================================================================
# A etapa 14 entrega a GPU ao vfio-pci e derruba o desktop a cada start da VM,
# então o 13.15 manual exigia monitor e teclado dedicados. Esta etapa remove
# essa exigência: ela baixa o instalador oficial da NVIDIA, injeta o
# qemu-guest-agent no QCOW2 quando necessário, e dispara uma unidade systemd
# transiente que liga a VM, instala o driver em modo silencioso
# (setup -s -noreboot) via guest-exec, confirma com nvidia-smi e desliga a VM.
# O hook release da etapa 14 devolve GPU e desktop sozinho ao final.
#
# Uso:
#   55-driver-nvidia-vm.sh              fluxo completo (interativo até o disparo)
#   55-driver-nvidia-vm.sh --verificar  status pelo contrato 0/1/2/3
#
# O resultado fica registrado em /var/lib/vm-passthrough e o andamento pode
# ser acompanhado sem vídeo com: journalctl -u vm-passthrough-driver-<vm> -f
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

RESULTADOS_DIR="/var/lib/vm-passthrough"
PAYLOAD_ISO_LOGICO="/vm/driver-nvidia-payload.iso"
PAYLOAD_ROTULO="VMPTDRV"
NVIDIA_CATALOGO_URL="https://www.nvidia.com/Download/API/lookupValueSearch.aspx?TypeID=3"
NVIDIA_LOOKUP_BASE="https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php"
NVIDIA_PAGINA_OFICIAL="https://www.nvidia.com/Download/index.aspx"
TAMANHO_MINIMO_DRIVER=200000000

unidade_driver() { printf 'vm-passthrough-driver-%s.service\n' "$1"; }
resultado_driver() { printf '%s/driver-nvidia-%s.resultado\n' "$RESULTADOS_DIR" "$1"; }

ler_resultado() {
    # Parser restrito do arquivo de resultado (dados, nunca código).
    local arquivo="$1" chave valor
    RES_STATUS=""; RES_FASE=""; RES_MOTIVO=""; RES_DRIVER_VERSAO=""
    RES_SETUP_EXIT=""; RES_SMI_OK=""; RES_TOOLS=""; RES_TS_FIM=""
    [ -f "$arquivo" ] && [ -r "$arquivo" ] || return 1
    while IFS='=' read -r chave valor; do
        case "$chave" in
            STATUS) RES_STATUS="$valor" ;;
            FASE) RES_FASE="$valor" ;;
            MOTIVO) RES_MOTIVO="$valor" ;;
            DRIVER_VERSAO) RES_DRIVER_VERSAO="$valor" ;;
            SETUP_EXIT) RES_SETUP_EXIT="$valor" ;;
            SMI_OK) RES_SMI_OK="$valor" ;;
            TOOLS) RES_TOOLS="$valor" ;;
            TS_FIM) RES_TS_FIM="$valor" ;;
            SCHEMA_VERSAO|TS_INICIO) : ;;
            *) : ;;
        esac
    done < "$arquivo"
    [ -n "$RES_STATUS" ]
}

verificar() {
    [ -n "${VM_NAME:-}" ] || { v_falta "VM_NAME não definido."; v_fim; }
    if ! vm_existe "$VM_NAME"; then
        v_falta "VM '$VM_NAME' não existe (etapa 12)."
        v_fim
    fi
    local unidade resultado
    unidade="$(unidade_driver "$VM_NAME")"
    resultado="$(resultado_driver "$VM_NAME")"
    if systemctl is-active --quiet "$unidade" 2>/dev/null; then
        ler_resultado "$resultado" || true
        v_indeterminado "Instalação automática em andamento (fase: ${RES_FASE:-inicial}). Acompanhe com: journalctl -u $unidade -f"
        v_fim
    fi
    if ! ler_resultado "$resultado"; then
        v_falta "Instalação automática do driver ainda não executada."
        v_fim
    fi
    case "$RES_STATUS" in
        sucesso)
            if [ "$RES_SMI_OK" = "1" ]; then
                v_ok "Driver NVIDIA ${RES_DRIVER_VERSAO:-?} instalado e confirmado por nvidia-smi na VM (${RES_TS_FIM:-sem data})."
            else
                v_indeterminado "Instalador NVIDIA concluiu (código ${RES_SETUP_EXIT:-?}), mas nvidia-smi não confirmou; verifique dentro do Windows."
            fi
            ;;
        falha)
            v_erro "Última execução falhou na fase ${RES_FASE:-?}: ${RES_MOTIVO:-sem diagnóstico}. Journal: journalctl -u $unidade"
            ;;
        andamento)
            v_erro "Execução anterior foi interrompida na fase ${RES_FASE:-?} e a unidade não está mais ativa. Rode a etapa novamente."
            ;;
        *)
            v_erro "Resultado registrado ilegível em $resultado."
            ;;
    esac
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

guard_mutation guest.driver || exit 1
exigir_nao_root
python_core_disponivel \
    || falhar "O core Python do projeto não respondeu: ${PYTHON_CORE_ERRO:-diagnóstico ausente}."
exigir_conf VM_NAME GPU_VENDOR_DEVICE_ID QCOW2_PATH ISO_VIRTIO DM_SERVICE
nome_vm_valido "$VM_NAME" || falhar "VM_NAME inválido: '$VM_NAME'."
pci_vendor_device_valido "$GPU_VENDOR_DEVICE_ID" || falhar "GPU_VENDOR_DEVICE_ID inválido."
exigir_comando curl xorriso lspci systemctl systemd-run base64

UNIDADE="$(unidade_driver "$VM_NAME")"
RESULTADO="$(resultado_driver "$VM_NAME")"
RUNNER_DESTINO="/run/vm-passthrough-driver-${VM_NAME}.sh"

titulo "Etapa 15: instalar o driver NVIDIA dentro da VM (automático)"
titulo "Antes de continuar"
info "Finalidade: instalar o driver NVIDIA no Windows da VM sem monitor nem teclado dedicados, usando o qemu-guest-agent e a instalação silenciosa oficial (setup -s -noreboot)."
info "Pré-requisitos: Windows instalado no QCOW2 (etapa 13 essencial), hooks aplicados (etapa 14), VM desligada e internet para o download do driver."
info "Alterações: pode injetar o qemu-guest-agent no QCOW2 (offline), baixa o instalador oficial para /vm, gera e anexa uma ISO de payload, garante o canal do guest-agent no XML e dispara uma unidade systemd transiente que liga a VM, instala e desliga."
aviso "Risco principal: durante a fase automática o desktop do host cai (hooks da etapa 14): a tela apaga por vários minutos e VOLTA SOZINHA ao final. Não force o desligamento do PC."
info "Acompanhamento sem vídeo (SSH ou outro dispositivo): journalctl -u $UNIDADE -f"
info "Aborto de emergência: virsh --connect qemu:///system destroy $VM_NAME e, se o desktop não voltar, utilitário u6 (recuperar GPU)."
info "Retorno: sem reboot do host. O resultado fica em $RESULTADO e aparece no status do menu."

exigir_sudo

# --- Preflight -----------------------------------------------------------------
vm_existe "$VM_NAME" || falhar "A VM '$VM_NAME' não existe. Execute a etapa 12 antes."
exigir_vm_desligada "$VM_NAME"
if systemctl is-active --quiet "$UNIDADE" 2>/dev/null; then
    falhar "Já existe uma instalação automática em andamento ($UNIDADE). Acompanhe com: journalctl -u $UNIDADE -f"
fi
XML_INATIVO="$($VIRSH dumpxml --inactive "$VM_NAME")" \
    || falhar "Não foi possível ler o XML da VM."
QTD_PCI="$(grep -c "hostdev mode='subsystem' type='pci'" <<< "$XML_INATIVO" || true)"
[ "${QTD_PCI:-0}" -ge 1 ] \
    || falhar "A VM não tem GPU em passthrough no XML. Aplique a etapa 14 antes."
[ -e "/etc/libvirt/hooks/qemu.d/${VM_NAME}/.vm-passthrough-required" ] \
    || falhar "Os hooks da etapa 14 não estão instalados para esta VM. Aplique a etapa 14 antes."
# O prepare precisa da espera de liberação da GPU: sem ela, o descarregamento
# dos módulos nvidia perde a corrida contra a morte assíncrona da sessão
# gráfica e o start aborta com "module in use" (visto em 2026-08-22).
grep -q 'descarregar_modulos_nvidia' \
    "/etc/libvirt/hooks/qemu.d/${VM_NAME}/prepare/begin/01-gpu-preflight.sh" 2>/dev/null \
    || falhar "Os hooks instalados são de uma versão antiga, sem a espera de liberação da GPU. Rode a etapa 14 novamente (ela re-renderiza os hooks) e volte a esta etapa."

validar_iso_configurada "$ISO_VIRTIO" \
    || falhar "ISO virtio-win inválida (${ARMAZENAMENTO_ERRO:-sem diagnóstico}). Ela é a fonte dos guest tools."
ISO_VIRTIO_FISICO="$ARMAZENAMENTO_CAMINHO_FISICO"
VIRTIO_ANEXADA=0
grep -Fq "$(basename -- "$ISO_VIRTIO")" <<< "$XML_INATIVO" && VIRTIO_ANEXADA=1

caminho_artefato_vm_logico_valido "$QCOW2_PATH" || falhar "QCOW2_PATH fora da política de /vm."
QCOW2_FISICO="$(caminho_sistema "$QCOW2_PATH")" || falhar "Não foi possível mapear o QCOW2."
[ -f "$QCOW2_FISICO" ] || falhar "QCOW2 não encontrado: $QCOW2_PATH (etapa 12)."

# --- Canal do guest-agent no XML -------------------------------------------------
if ! grep -Fq "org.qemu.guest_agent.0" <<< "$XML_INATIVO"; then
    info "A VM não tem o canal 'org.qemu.guest_agent.0'; adicionando ao XML persistente."
    xml_backup "$VM_NAME"
    TMP_CANAL="$(mktemp)"
    printf '%s\n' "<channel type='unix'><target type='virtio' name='org.qemu.guest_agent.0'/></channel>" > "$TMP_CANAL"
    $VIRSH attach-device "$VM_NAME" "$TMP_CANAL" --config \
        || { rm -f "$TMP_CANAL"; falhar "Não foi possível adicionar o canal do guest-agent."; }
    rm -f "$TMP_CANAL"
    ok "Canal do guest-agent adicionado (vale a partir do próximo boot da VM)."
else
    ok "Canal do guest-agent já presente no XML."
fi

# --- Bootstrap do agente dentro do Windows ---------------------------------------
echo
info "O fluxo automático depende do serviço qemu-guest-agent DENTRO do Windows."
info "Ele faz parte dos guest tools do item 13.11 (virtio-win-guest-tools.exe)."
if confirmar "Os guest tools (13.11) JÁ foram instalados dentro do Windows desta VM?"; then
    info "Injeção offline dispensada; o agente existente será usado."
else
    if ! command -v virt-customize >/dev/null 2>&1; then
        falhar "virt-customize ausente. Rode a etapa 6 (Pacotes base) novamente para instalar o guestfs-tools e volte a esta etapa."
    fi
    aviso "A injeção offline grava no QCOW2 com a VM desligada e demora alguns minutos."
    aviso "Ela falha de propósito se o NTFS estiver hibernado (Fast Startup do 13.13 ainda ativo)."
    confirmar "Injetar o qemu-guest-agent no QCOW2 agora?" || cancelar_etapa
    info "Injetando o qemu-guest-agent a partir de: $ISO_VIRTIO"
    if ! sudo virt-customize --no-network -a "$QCOW2_FISICO" --inject-qemu-ga "$ISO_VIRTIO_FISICO"; then
        falhar "A injeção offline falhou. Causas comuns: Fast Startup/hibernação do Windows (13.13) ou QCOW2 em uso. Alternativa manual única: instale o virtio-win-guest-tools.exe dentro do Windows (13.11) e rode esta etapa de novo."
    fi
    ok "Agente injetado: ele se instala sozinho no primeiro boot da VM (a primeira resposta pode atrasar alguns minutos)."
fi

# --- Instalador NVIDIA: reutilizar, baixar ou receber do usuário ------------------
DRIVER_ERRO=""
DRIVER_FISICO=""
validar_driver_exe() {
    local logico="${1:-}" fisico assinatura tamanho
    DRIVER_ERRO=""
    DRIVER_FISICO=""
    caminho_artefato_vm_logico_valido "$logico" \
        || { DRIVER_ERRO="o instalador precisa ser um filho direto de /vm, sem vírgula (ex.: /vm/nvidia-driver-572.83.exe)"; return 1; }
    [[ "${logico,,}" == *.exe ]] \
        || { DRIVER_ERRO="o instalador precisa ter extensão .exe"; return 1; }
    fisico="$(caminho_sistema "$logico")" || { DRIVER_ERRO="não foi possível mapear o caminho"; return 1; }
    [ -f "$fisico" ] && [ ! -L "$fisico" ] && [ -r "$fisico" ] \
        || { DRIVER_ERRO="arquivo inexistente, ilegível ou link simbólico"; return 1; }
    assinatura="$(head -c2 -- "$fisico" 2>/dev/null)" || assinatura=""
    [ "$assinatura" = "MZ" ] \
        || { DRIVER_ERRO="o arquivo não é um executável Windows (assinatura MZ ausente)"; return 1; }
    tamanho="$(stat -c %s -- "$fisico" 2>/dev/null)" || tamanho=0
    [ "$tamanho" -ge "$TAMANHO_MINIMO_DRIVER" ] \
        || { DRIVER_ERRO="arquivo pequeno demais para um driver NVIDIA completo ($tamanho bytes)"; return 1; }
    DRIVER_FISICO="$fisico"
}

DRIVER_VERSAO_META=""
extrair_versao_do_nome() {
    # nvidia-driver-572.83.exe -> 572.83 (apenas informativo).
    local nome="${1##*/}"
    if [[ "$nome" =~ ([0-9]{3,4}\.[0-9]{2,3}) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    fi
}

baixar_driver_nvidia() {
    # Preenche DRIVER_EXE/DRIVER_VERSAO_META em sucesso; retorna 1 para o
    # chamador acionar o caminho manual. Nunca aborta a etapa sozinha.
    local linha_gpu produto catalogo consulta url versao nome destino parcial
    local -a payload=()
    linha_gpu="$(LC_ALL=C lspci -d "$GPU_VENDOR_DEVICE_ID" 2>/dev/null | head -n1)" || linha_gpu=""
    produto="$(sed -n 's/.*\[\([^][]*\)\].*/\1/p' <<< "$linha_gpu" | head -n1)"
    if [ -z "$produto" ]; then
        aviso "Não consegui derivar o nome de mercado da GPU a partir do lspci."
        produto="$(perguntar 'Nome do produto para a busca NVIDIA (ex.: GeForce RTX 3060)')"
        [ -n "$produto" ] || { aviso "Nome vazio; busca automática cancelada."; return 1; }
    else
        info "GPU detectada para a busca: $produto"
        produto="$(perguntar 'Nome do produto para a busca NVIDIA' "$produto")"
    fi
    info "Consultando o catálogo público de produtos da NVIDIA..."
    catalogo="$(curl -fsS --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 120 --retry 2 "$NVIDIA_CATALOGO_URL")" \
        || { aviso "Falha ao baixar o catálogo de produtos da NVIDIA."; return 1; }
    local -a NVM_PERMITIDAS=("${CORE_PARES_ENVELOPE[@]}" PSID PFID MATCHED_NAME)
    payload=(xml "$catalogo" product "$produto")
    if ! python_core_pares_payload NVM_PERMITIDAS NVM_ nvidia-product-match payload; then
        aviso "O catálogo da NVIDIA não tem correspondência exata para '$produto'."
        return 1
    fi
    info "Família encontrada: $NVM_MATCHED_NAME (psid=$NVM_PSID pfid=$NVM_PFID)"
    info "Consultando o driver mais recente para Windows 11 64-bit (WHQL/DCH)..."
    consulta="$(curl -fsS --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 60 --retry 2 \
        "${NVIDIA_LOOKUP_BASE}?func=DriverManualLookup&psid=${NVM_PSID}&pfid=${NVM_PFID}&osID=135&languageCode=1033&beta=0&isWHQL=1&dltype=-1&dch=1&upCRD=0&qnf=0&sort1=0&numberOfResults=1")" \
        || { aviso "Falha ao consultar o serviço de drivers da NVIDIA."; return 1; }
    local -a NVD_PERMITIDAS=("${CORE_PARES_ENVELOPE[@]}" URL VERSION NAME)
    payload=(json "$consulta")
    if ! python_core_pares_payload NVD_PERMITIDAS NVD_ nvidia-download-info payload; then
        aviso "A resposta do serviço de drivers da NVIDIA não pôde ser validada."
        return 1
    fi
    url="$NVD_URL"; versao="$NVD_VERSION"; nome="${NVD_NAME:-driver NVIDIA}"
    info "Driver mais recente: $nome $versao"
    destino="/vm/nvidia-driver-${versao}.exe"
    if validar_driver_exe "$destino"; then
        ok "O instalador $versao já está baixado em $destino."
        DRIVER_EXE="$destino"
        DRIVER_VERSAO_META="$versao"
        return 0
    fi
    info "Baixando de: $url"
    parcial="$(caminho_sistema "$destino")".part
    if ! curl -f --proto '=https' --tlsv1.2 --connect-timeout 20 --retry 2 -o "$parcial" "$url"; then
        rm -f -- "$parcial"
        aviso "O download do driver falhou."
        return 1
    fi
    mv -f -- "$parcial" "$(caminho_sistema "$destino")"
    if ! validar_driver_exe "$destino"; then
        aviso "O arquivo baixado não passou na validação: ${DRIVER_ERRO}."
        return 1
    fi
    ok "Driver $versao baixado e validado em $destino."
    DRIVER_EXE="$destino"
    DRIVER_VERSAO_META="$versao"
}

DRIVER_EXE=""
if [ -n "${NVIDIA_DRIVER_EXE:-}" ] && validar_driver_exe "$NVIDIA_DRIVER_EXE"; then
    info "Instalador salvo na configuração: $NVIDIA_DRIVER_EXE"
    if confirmar "Buscar online uma versão mais recente? (N reutiliza o instalador salvo)"; then
        baixar_driver_nvidia || {
            aviso "Busca online falhou; mantendo o instalador salvo."
            DRIVER_EXE="$NVIDIA_DRIVER_EXE"
        }
    else
        DRIVER_EXE="$NVIDIA_DRIVER_EXE"
    fi
else
    [ -z "${NVIDIA_DRIVER_EXE:-}" ] \
        || aviso "O instalador salvo em NVIDIA_DRIVER_EXE ficou inválido (${DRIVER_ERRO}); ele será substituído."
    baixar_driver_nvidia || {
        echo
        aviso "Não foi possível obter o driver automaticamente."
        info "Baixe manualmente em: $NVIDIA_PAGINA_OFICIAL (Windows 11 64-bit, pacote oficial da NVIDIA)"
        info "Salve o .exe como filho direto de /vm (ex.: /vm/nvidia-driver-572.83.exe) e informe o caminho abaixo."
        while :; do
            RESPOSTA_CAMINHO="$(perguntar 'Caminho do instalador .exe em /vm (v=voltar; q=sair)')"
            case "${RESPOSTA_CAMINHO,,}" in
                v|voltar) cancelar_etapa ;;
                q|sair)
                    aviso "Saída solicitada pelo usuário." >&2
                    exit "$CODIGO_SAIR_MENU"
                    ;;
            esac
            if validar_driver_exe "$RESPOSTA_CAMINHO"; then
                DRIVER_EXE="$RESPOSTA_CAMINHO"
                break
            fi
            aviso "Caminho recusado: ${DRIVER_ERRO}."
        done
    }
fi
[ -n "$DRIVER_EXE" ] || falhar "Nenhum instalador NVIDIA definido."
validar_driver_exe "$DRIVER_EXE" || falhar "Instalador inválido: ${DRIVER_ERRO}."
[ -n "$DRIVER_VERSAO_META" ] || DRIVER_VERSAO_META="$(extrair_versao_do_nome "$DRIVER_EXE")"
salvar_conf NVIDIA_DRIVER_EXE "$DRIVER_EXE"
ok "Instalador definido e persistido: $DRIVER_EXE"

# --- ISO de payload (leva o instalador para dentro do Windows) --------------------
PAYLOAD_FISICO="$(caminho_sistema "$PAYLOAD_ISO_LOGICO")" || falhar "Não foi possível mapear a ISO de payload."
info "Gerando a ISO de payload com o instalador (rótulo $PAYLOAD_ROTULO)..."
AREA_PAYLOAD="$(mktemp -d)"
cp -f -- "$DRIVER_FISICO" "$AREA_PAYLOAD/NvidiaDriver.exe" \
    || { rm -rf -- "$AREA_PAYLOAD"; falhar "Não foi possível preparar o payload."; }
if ! xorriso -as mkisofs -quiet -iso-level 3 -V "$PAYLOAD_ROTULO" -J -R \
    -o "${PAYLOAD_FISICO}.part" "$AREA_PAYLOAD"; then
    rm -rf -- "$AREA_PAYLOAD" "${PAYLOAD_FISICO}.part"
    falhar "xorriso não conseguiu gerar a ISO de payload."
fi
rm -rf -- "$AREA_PAYLOAD"
mv -f -- "${PAYLOAD_FISICO}.part" "$PAYLOAD_FISICO"
ok "ISO de payload pronta: $PAYLOAD_ISO_LOGICO"

XML_INATIVO="$($VIRSH dumpxml --inactive "$VM_NAME")" || falhar "Não foi possível reler o XML da VM."
if ! grep -Fq "$(basename -- "$PAYLOAD_ISO_LOGICO")" <<< "$XML_INATIVO"; then
    grep -q "dev='sdc'" <<< "$XML_INATIVO" \
        && falhar "O alvo sdc já está em uso no XML; remova o disco conflitante antes."
    xml_backup "$VM_NAME"
    TMP_CDROM="$(mktemp)"
    cat > "$TMP_CDROM" <<XML
<disk type='file' device='cdrom'>
  <driver name='qemu' type='raw'/>
  <source file='$PAYLOAD_FISICO'/>
  <target dev='sdc' bus='sata'/>
  <readonly/>
</disk>
XML
    $VIRSH attach-device "$VM_NAME" "$TMP_CDROM" --config \
        || { rm -f "$TMP_CDROM"; falhar "Não foi possível anexar a ISO de payload."; }
    rm -f "$TMP_CDROM"
    ok "ISO de payload anexada ao XML (cdrom sdc)."
else
    ok "ISO de payload já anexada ao XML."
fi
if [ "$VIRTIO_ANEXADA" -eq 0 ]; then
    aviso "A ISO virtio-win não está anexada à VM: a fase opcional de guest tools completos será pulada."
fi

# --- Confirmação final e disparo ---------------------------------------------------
sudo install -d -o root -g root -m 0755 "$RESULTADOS_DIR" \
    || falhar "Não foi possível preparar $RESULTADOS_DIR."

echo
titulo "O que vai acontecer agora"
info "1) A VM liga com a GPU passada; os hooks da etapa 14 derrubam o desktop do host (tela preta)."
info "2) O runner espera o qemu-guest-agent, instala os guest tools (se faltarem) e roda o instalador NVIDIA em modo silencioso."
info "3) nvidia-smi confirma o driver (com um reboot de verificação da VM se necessário)."
info "4) A VM desliga e o hook release devolve GPU e desktop sozinhos."
info "Duração típica: 10 a 30 minutos. Acompanhe sem vídeo: journalctl -u $UNIDADE -f"
aviso "Feche antes os aplicativos pesados que usam a GPU (navegador, IDE, acesso remoto): eles atrasam a liberação dos módulos nvidia na queda da sessão."
aviso "NÃO force o desligamento do PC durante o processo; para abortar use, por SSH: virsh --connect qemu:///system destroy $VM_NAME"
confirmar_digitando INSTALAR "Ao confirmar, o VÍDEO DO HOST SERÁ PERDIDO durante a instalação automática; ele volta sozinho ao final." \
    || cancelar_etapa

TMP_RUNNER="$(mktemp)"
{
    cat <<'CAB'
#!/bin/bash
# Runner transiente da etapa 15: instala o driver NVIDIA dentro da VM via
# qemu-guest-agent. Renderizado por etapas/55-driver-nvidia-vm.sh e autônomo
# de propósito: o repositório pode estar em montagem ilegível ao root.
set -uo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
CAB
    printf 'VM_NAME=%q\n' "$VM_NAME"
    printf 'RESULTADO=%q\n' "$RESULTADO"
    printf 'PAYLOAD_ISO=%q\n' "$PAYLOAD_FISICO"
    printf 'PAYLOAD_ROTULO=%q\n' "$PAYLOAD_ROTULO"
    printf 'DRIVER_VERSAO_META=%q\n' "$DRIVER_VERSAO_META"
    printf 'INSTALAR_GUEST_TOOLS=%q\n' "$VIRTIO_ANEXADA"
    cat <<'CORPO'
VIRSH="virsh --connect qemu:///system"
TS_INICIO="$(date -Is)"
R_STATUS=andamento R_FASE=preparacao R_MOTIVO="" R_SETUP_EXIT=""
R_SMI_OK="" R_TOOLS="" R_DRIVER_VERSAO="$DRIVER_VERSAO_META" R_TS_FIM=""

publicar() {
    local tmp
    tmp="$(mktemp "${RESULTADO}.XXXXXX")" || return 1
    {
        printf 'SCHEMA_VERSAO=1\n'
        printf 'STATUS=%s\n' "$R_STATUS"
        printf 'FASE=%s\n' "$R_FASE"
        printf 'MOTIVO=%s\n' "${R_MOTIVO//$'\n'/ }"
        printf 'DRIVER_VERSAO=%s\n' "$R_DRIVER_VERSAO"
        printf 'SETUP_EXIT=%s\n' "$R_SETUP_EXIT"
        printf 'SMI_OK=%s\n' "$R_SMI_OK"
        printf 'TOOLS=%s\n' "$R_TOOLS"
        printf 'TS_INICIO=%s\n' "$TS_INICIO"
        printf 'TS_FIM=%s\n' "$R_TS_FIM"
    } > "$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$RESULTADO"
}
fase() { R_FASE="$1"; publicar || true; echo "[driver-vm] fase: $1"; }

vm_estado() {
    LC_ALL=C $VIRSH domstate "$VM_NAME" 2>/dev/null \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

desligar_vm() {
    local i
    [ "$(vm_estado)" = "shut off" ] && return 0
    $VIRSH shutdown --mode agent "$VM_NAME" >/dev/null 2>&1 \
        || $VIRSH shutdown "$VM_NAME" >/dev/null 2>&1 || true
    for ((i=0; i<60; i++)); do
        [ "$(vm_estado)" = "shut off" ] && return 0
        sleep 5
    done
    echo "[driver-vm] shutdown gracioso não concluiu; tentando ACPI..." >&2
    $VIRSH shutdown --mode acpi "$VM_NAME" >/dev/null 2>&1 || true
    for ((i=0; i<60; i++)); do
        [ "$(vm_estado)" = "shut off" ] && return 0
        sleep 5
    done
    echo "[driver-vm] ÚLTIMO RECURSO: virsh destroy (a VM não respondeu ao desligamento)." >&2
    $VIRSH destroy "$VM_NAME" >/dev/null 2>&1 || true
    for ((i=0; i<12; i++)); do
        [ "$(vm_estado)" = "shut off" ] && return 0
        sleep 5
    done
    return 1
}

falhar_runner() {
    R_STATUS=falha
    R_MOTIVO="$*"
    echo "[driver-vm] ERRO: $*" >&2
    publicar || true
    desligar_vm || echo "[driver-vm] atenção: a VM pode continuar ligada." >&2
    R_TS_FIM="$(date -Is)"
    publicar || true
    exit 1
}

agent_cmd() { LC_ALL=C $VIRSH qemu-agent-command "$VM_NAME" "$1" 2>/dev/null; }
guest_ping() { agent_cmd '{"execute":"guest-ping"}' >/dev/null; }

json_get() {
    # json_get caminho.pontuado <<< json  (parser mínimo local: o runner não
    # pode depender do repositório nem do core, que vivem em montagem de
    # usuário; python3 -I -S -B evita site-packages e código externo).
    python3 -I -S -B -c '
import json, sys
data = json.load(sys.stdin)
for parte in sys.argv[1].split("."):
    if isinstance(data, list):
        data = data[int(parte)]
    else:
        data = data[parte]
if isinstance(data, bool):
    print(1 if data else 0)
else:
    print(data)
' "$1"
}

aguardar_agente() {
    local limite="$1" i
    for ((i=0; i<limite; i+=5)); do
        guest_ping && return 0
        if (( i % 60 == 0 )); then
            echo "[driver-vm] aguardando o guest-agent (${i}s)..."
        fi
        sleep 5
    done
    return 1
}

guest_exec() {
    local saida pid
    saida="$(agent_cmd "$1")" || return 1
    pid="$(json_get return.pid <<< "$saida" 2>/dev/null)" || return 1
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$pid"
}

EXEC_EXITCODE=""
EXEC_SAIDA=""
guest_exec_aguardar() {
    local pid="$1" limite="$2" i saida exited
    EXEC_EXITCODE=""
    EXEC_SAIDA=""
    for ((i=0; i<limite; i+=10)); do
        saida="$(agent_cmd "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}")" \
            || { sleep 10; continue; }
        exited="$(json_get return.exited <<< "$saida" 2>/dev/null)" || exited=0
        if [ "$exited" = "1" ]; then
            EXEC_EXITCODE="$(json_get return.exitcode <<< "$saida" 2>/dev/null)" || EXEC_EXITCODE=""
            EXEC_SAIDA="$(json_get return.out-data <<< "$saida" 2>/dev/null | base64 -d 2>/dev/null)" || EXEC_SAIDA=""
            return 0
        fi
        sleep 10
    done
    return 1
}

powershell_exec() {
    # powershell_exec 'comando-sem-aspas-duplas' timeout
    local comando="$1" limite="$2" json pid
    json='{"execute":"guest-exec","arguments":{"path":"C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe","arg":["-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-Command","'"$comando"'"],"capture-output":true}}'
    pid="$(guest_exec "$json")" || return 1
    guest_exec_aguardar "$pid" "$limite"
}

letra_volume() {
    local rotulo="$1" letra
    powershell_exec "(Get-Volume | Where-Object { \$_.FileSystemLabel -like '${rotulo}*' } | Select-Object -First 1).DriveLetter" 60 \
        || return 1
    letra="$(printf '%s' "$EXEC_SAIDA" | tr -d '[:space:]')"
    [[ "$letra" =~ ^[A-Za-z]$ ]] || return 1
    printf '%s\n' "$letra"
}

instalar_guest_tools() {
    local letra i marcador='C:/Windows/Temp/vmpt-guest-tools.marcador'
    if [ "$INSTALAR_GUEST_TOOLS" != "1" ]; then
        R_TOOLS=sem-iso
        return 0
    fi
    if powershell_exec "(Get-Service | Where-Object { \$_.Name -like '*spice*' } | Measure-Object).Count" 60 \
        && [ "$(printf '%s' "$EXEC_SAIDA" | tr -d '[:space:]')" != "0" ] \
        && [ -n "$(printf '%s' "$EXEC_SAIDA" | tr -d '[:space:]')" ]; then
        echo "[driver-vm] guest tools completos já presentes; fase pulada."
        R_TOOLS=presente
        return 0
    fi
    letra="$(letra_volume 'virtio-win')" || { R_TOOLS=sem-iso; return 0; }
    echo "[driver-vm] instalando os guest tools completos a partir de ${letra}:..."
    powershell_exec "Remove-Item -Force -ErrorAction SilentlyContinue '${marcador}'" 60 || true
    # O instalador reinicia o próprio qemu-guest-agent, então o rastreio por
    # pid se perde: um marcador com o código de saída fecha a fase.
    powershell_exec "\$p = Start-Process -FilePath '${letra}:/virtio-win-guest-tools.exe' -ArgumentList '/install','/quiet','/norestart' -PassThru -Wait; Set-Content -Path '${marcador}' -Value \$p.ExitCode" 30 \
        || true
    for ((i=0; i<900; i+=15)); do
        sleep 15
        guest_ping || continue
        if powershell_exec "Get-Content -ErrorAction SilentlyContinue '${marcador}'" 60; then
            local codigo
            codigo="$(printf '%s' "$EXEC_SAIDA" | tr -d '[:space:]')"
            case "$codigo" in
                0|3010) R_TOOLS=ok; echo "[driver-vm] guest tools instalados (código $codigo)."; return 0 ;;
                "") continue ;;
                *) R_TOOLS="falha($codigo)"; echo "[driver-vm] guest tools terminaram com código $codigo; seguindo assim mesmo." >&2; return 0 ;;
            esac
        fi
    done
    R_TOOLS=timeout
    echo "[driver-vm] guest tools não confirmaram em 15 minutos; seguindo com o agente atual." >&2
    return 0
}

verificar_smi() {
    local pid versao
    pid="$(guest_exec '{"execute":"guest-exec","arguments":{"path":"C:\\Windows\\System32\\nvidia-smi.exe","capture-output":true}}')" \
        || return 1
    guest_exec_aguardar "$pid" 120 || return 1
    [ "${EXEC_EXITCODE:-1}" = "0" ] || return 1
    grep -q "Driver Version" <<< "$EXEC_SAIDA" || return 1
    versao="$(grep -o 'Driver Version: [0-9.]*' <<< "$EXEC_SAIDA" | head -n1 | awk '{print $3}')"
    [ -z "$versao" ] || R_DRIVER_VERSAO="$versao"
    return 0
}

echo "[driver-vm] início: VM=$VM_NAME driver=${DRIVER_VERSAO_META:-desconhecido}"
publicar || { echo "[driver-vm] não foi possível registrar o resultado em $RESULTADO" >&2; exit 1; }

fase boot
LC_ALL=C $VIRSH start "$VM_NAME" \
    || falhar_runner "virsh start falhou (o preflight dos hooks pode ter recusado; veja journalctl -u libvirtd)"

fase agente
aguardar_agente 900 \
    || falhar_runner "o guest-agent não respondeu em 15 minutos (guest tools ausentes no Windows?)"
echo "[driver-vm] guest-agent respondendo."

fase guest-tools
instalar_guest_tools

fase driver
LETRA_PAYLOAD="$(letra_volume "$PAYLOAD_ROTULO")" \
    || falhar_runner "a ISO de payload ($PAYLOAD_ROTULO) não apareceu como volume no Windows"
echo "[driver-vm] executando ${LETRA_PAYLOAD}:\\NvidiaDriver.exe -s -noreboot (instalação silenciosa)..."
PID_DRIVER="$(guest_exec "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"${LETRA_PAYLOAD}:\\\\NvidiaDriver.exe\",\"arg\":[\"-s\",\"-noreboot\"],\"capture-output\":true}}")" \
    || falhar_runner "não foi possível iniciar o instalador NVIDIA dentro do Windows"
guest_exec_aguardar "$PID_DRIVER" 2400 \
    || falhar_runner "o instalador NVIDIA não terminou em 40 minutos"
R_SETUP_EXIT="${EXEC_EXITCODE:-}"
case "$R_SETUP_EXIT" in
    0|1) echo "[driver-vm] instalador NVIDIA terminou com código $R_SETUP_EXIT." ;;
    *) falhar_runner "o instalador NVIDIA terminou com código ${R_SETUP_EXIT:-desconhecido}" ;;
esac

fase verificacao
if verificar_smi; then
    R_SMI_OK=1
else
    echo "[driver-vm] nvidia-smi ainda não confirmou; reboot de verificação da VM..."
    $VIRSH reboot --mode agent "$VM_NAME" >/dev/null 2>&1 \
        || $VIRSH reboot "$VM_NAME" >/dev/null 2>&1 || true
    sleep 30
    aguardar_agente 600 \
        || falhar_runner "a VM não voltou do reboot de verificação"
    if verificar_smi; then
        R_SMI_OK=1
    else
        R_SMI_OK=0
        echo "[driver-vm] nvidia-smi não confirmou o driver; verifique dentro do Windows." >&2
    fi
fi
publicar || true

fase desligamento
desligar_vm || falhar_runner "não foi possível desligar a VM ao final"
TMP_DETACH="$(mktemp)"
cat > "$TMP_DETACH" <<XMLDET
<disk type='file' device='cdrom'>
  <driver name='qemu' type='raw'/>
  <source file='$PAYLOAD_ISO'/>
  <target dev='sdc' bus='sata'/>
  <readonly/>
</disk>
XMLDET
$VIRSH detach-device "$VM_NAME" "$TMP_DETACH" --config >/dev/null 2>&1 \
    || echo "[driver-vm] aviso: não foi possível desanexar a ISO de payload (inofensivo)." >&2
rm -f "$TMP_DETACH"

R_STATUS=sucesso
R_FASE=concluido
R_TS_FIM="$(date -Is)"
publicar || true
echo "[driver-vm] concluído: driver ${R_DRIVER_VERSAO:-?} instalado (nvidia-smi=${R_SMI_OK})."
echo "[driver-vm] o hook release da etapa 14 devolve GPU e desktop automaticamente."
exit 0
CORPO
} > "$TMP_RUNNER"

bash -n "$TMP_RUNNER" || { rm -f "$TMP_RUNNER"; falhar "O runner renderizado tem erro de sintaxe (defeito interno da etapa)."; }
sudo install -o root -g root -m 0700 "$TMP_RUNNER" "$RUNNER_DESTINO" \
    || { rm -f "$TMP_RUNNER"; falhar "Não foi possível instalar o runner em $RUNNER_DESTINO."; }
rm -f "$TMP_RUNNER"

sudo systemctl reset-failed "$UNIDADE" >/dev/null 2>&1 || true
sudo systemd-run --unit="${UNIDADE%.service}" \
    --description="Instalação automática do driver NVIDIA na VM $VM_NAME (etapa 15)" \
    "$RUNNER_DESTINO" \
    || falhar "Não foi possível disparar a unidade transiente $UNIDADE."

echo
ok "Instalação automática disparada em segundo plano ($UNIDADE)."
aviso "O desktop do host vai cair em instantes e volta sozinho ao final (10 a 30 minutos)."
info "Acompanhe sem vídeo: journalctl -u $UNIDADE -f"
info "Resultado registrado em: $RESULTADO (o status desta etapa no menu reflete o desfecho)."
