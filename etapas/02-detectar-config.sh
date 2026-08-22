#!/bin/bash
# ============================================================================
# etapas/02-detectar-config.sh - Detecção e confirmação da configuração
# ============================================================================
# Implementa a regra central do manual: NUNCA usar valores inventados.
# Detecta no PRÓPRIO hardware os valores dos placeholders usados pelas
# etapas 1, 8, 11, 14, 16, 17 e 18, confirma cada um com o usuário e grava em
# passthrough.conf, reutilizado por todas as demais etapas.
#
# Travas de segurança desta etapa:
#   - GPU: avisa quando existe só UMA (o desktop Linux sai do ar enquanto a VM
#     roda) e obriga a escolher quando existe mais de uma.
#   - CPU: pelo menos 1 núcleo físico fica sempre com o host.
#   - RAM: teto = total menos a reserva do host (25%, entre 4 e 8 GiB).
#   - Disco da VM: o disco da RAIZ do Linux e qualquer disco montado/em uso no
#     host nunca entram como candidatos; o workingDisk é apenas um caminho
#     externo e não é persistido como dispositivo físico; "nenhum" é uma
#     escolha válida (a VM fica só com o QCOW2).
#   - Toda entrada numérica é validada e reperguntada em vez de derrubar o
#     script.
#
# Uso:
#   02-detectar-config.sh               descarta escolhas da etapa e reconfigura
#   02-detectar-config.sh --redetectar  alias compatível do mesmo reinício
#   02-detectar-config.sh --verificar   confere sem modificar arquivo algum
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# REQ-CONF-ISO: a migração pré-parser roda ANTES de carregar_conf, e somente
# nesta etapa, que é a única com prompt para decidir um caminho novo. Se a
# configuração já for válida, é no-op exato. Em `--verificar` nada é migrado:
# verificação é estritamente somente leitura, e uma ISO legada inválida aparece
# como erro do parser, apontando esta etapa como o caminho de correção.
if [ "${1:-}" != "--verificar" ]; then
    conf_migrar_iso_legada \
        || falhar "A configuração não pôde ser migrada; corrija ou restaure o backup informado."
    conf_migrar_dispensas_depreciadas \
        || falhar "As dispensas sem efeito não puderam ser removidas da configuração."
fi
carregar_conf

verificar() {
    local inventario
    if plataforma_carregar; then
        v_ok "Plataforma suportada: $PLATAFORMA_PERFIL ${PLATAFORMA_VERSION_ID:-}."
    else
        v_erro "$PLATAFORMA_ERRO"
    fi
    if resolver_ultimo_inventario >/dev/null && inventario="$INVENTARIO_RESOLVIDO" \
       && validar_inventario_principal "$inventario"; then
        v_ok "Inventário de referência válido: $inventario"
    else
        v_falta "${INVENTARIO_ERRO:-Inventário de referência indisponível.}"
    fi
    [ -f "$CONF_ARQUIVO" ] && v_ok "passthrough.conf existe." || v_falta "passthrough.conf não existe."
    local var tipo rota caminho iface tipo_lista ipv4 marca encontrou=0 topologia ram_max
    local cpu_completa=1 memoria_completa=1
    if [ -z "${USUARIO_LINUX:-}" ]; then
        v_falta "USUARIO_LINUX ainda não definido."
    elif validar_usuario_linux "$USUARIO_LINUX"; then
        if [ "$USUARIO_DIFERE_OPERADOR" -eq 1 ]; then
            v_erro "USUARIO_LINUX='$USUARIO_LINUX' é válido, mas difere do operador efetivo '$USUARIO_OPERADOR'; a execução exigirá confirmação reforçada."
        else
            v_ok "USUARIO_LINUX=$USUARIO_LINUX (uid=$USUARIO_VALIDADO_UID gid=$USUARIO_VALIDADO_GID home=$USUARIO_VALIDADO_HOME)."
        fi
    else
        v_erro "$USUARIO_VALIDACAO_ERRO"
    fi
    if [ -z "${BOOTLOADER:-}" ]; then
        v_falta "BOOTLOADER ainda não definido."
    elif validar_bootloader_configurado; then
        v_ok "BOOTLOADER=$BOOTLOADER coincide com o boot efetivo."
    else
        v_erro "$BOOTLOADER_VALIDACAO_ERRO"
    fi
    for var in VM_NAME GPU_PCI_ID GPU_VENDOR_DEVICE_ID \
               CPUS_VM CPUS_HOST VM_VCPUS VM_CORES VM_THREADS \
               VM_RAM_MB HUGEPAGES_1G DM_SERVICE; do
        if [ -n "${!var:-}" ]; then
            v_ok "$var=${!var}"
        else
            v_falta "$var ainda não definido."
            case "$var" in
                CPUS_VM|CPUS_HOST|VM_VCPUS|VM_CORES|VM_THREADS) cpu_completa=0 ;;
                VM_RAM_MB|HUGEPAGES_1G) memoria_completa=0 ;;
            esac
        fi
    done
    if [ "$cpu_completa" -eq 1 ]; then
        topologia="$(cpu_topologia_csv)" || topologia=""
        if [ -n "$topologia" ] \
           && validar_layout_cpu "$CPUS_VM" "$CPUS_HOST" "$VM_VCPUS" "$VM_CORES" "$VM_THREADS" "$topologia"; then
            v_ok "Plano de pinning de CPU cobre exatamente as CPUs online por socket/core."
        else
            v_falta "Plano relacional de CPU inválido: ${CPU_LAYOUT_ERRO:-topologia indisponível}."
        fi
    fi
    if [ "$memoria_completa" -eq 1 ]; then
        if plano_memoria_vm "$(ram_total_mib)" "$VM_RAM_MB" "$HUGEPAGES_1G"; then
            ram_max="$CPUMEM_MAX_VM_MIB"
            v_ok "RAM e HUGEPAGES_1G são coerentes e respeitam o teto atual de ${ram_max} MiB."
        else
            v_falta "VM_RAM_MB/HUGEPAGES_1G recusados: $CPU_MEMORIA_ERRO"
        fi
    fi
    if validar_config_rede; then
        tipo="Ethernet"
        interface_wifi "$INTERFACE_FISICA" && tipo="Wi-Fi"
        v_ok "Rede: modo=$REDE_MODO, uplink=$INTERFACE_FISICA ($tipo)."
    else
        v_falta "$REDE_CONFIG_ERRO"
    fi

    rota="$(dispositivo_uplink_ipv4_efetivo || true)"
    echo "Interfaces físicas elegíveis:"
    for caminho in /sys/class/net/*; do
        [ -e "$caminho" ] || continue
        iface="$(basename "$caminho")"
        interface_fisica_elegivel "$iface" || continue
        encontrou=1
        tipo_lista="Ethernet"
        interface_wifi "$iface" && tipo_lista="Wi-Fi"
        ipv4="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk 'NR==1 {print $4}')"
        [ -n "$ipv4" ] || ipv4="sem IPv4"
        marca=""
        [ "$iface" = "$rota" ] && marca=" <-- ROTA IPv4 EFETIVA"
        echo "  - $iface [$tipo_lista; IPv4=$ipv4]$marca"
    done
    [ "$encontrou" -eq 1 ] || v_falta "Nenhuma interface física elegível encontrada."
    if [ -n "$rota" ]; then
        v_ok "Rota IPv4 efetiva para 1.1.1.1: dispositivo $rota (nenhum pacote enviado)."
        if [ "${REDE_MODO:-}" = "nat" ] && [ "${INTERFACE_FISICA:-}" != "$rota" ]; then
            aviso "NAT está selecionado em ${INTERFACE_FISICA:-vazio}, mas a rota IPv4 efetiva usa $rota; ajuste a rota/métrica antes da etapa 19."
        fi
    else
        aviso "Rota IPv4 efetiva indisponível para destacar."
    fi
    # Áudio HDMI da GPU: opcional (algumas placas não expõem a função)
    if [ -n "${GPU_AUDIO_PCI_ID:-}" ]; then
        v_ok "GPU_AUDIO_PCI_ID=$GPU_AUDIO_PCI_ID"
    else
        v_ok "GPU sem função de áudio HDMI em passthrough (escolha registrada)."
    fi
    # workingDisk: caminho opcional, já montado externamente pelo operador.
    if [ -n "${WORKING_DISK_PATH:-}" ] && [ "${WORKING_DISK_DISPENSADO:-}" = "sim" ]; then
        v_falta "Configuração contraditória: WORKING_DISK_PATH definido e WORKING_DISK_DISPENSADO=sim."
    elif [ -n "${WORKING_DISK_PATH:-}" ]; then
        if validar_working_disk_montado "$WORKING_DISK_PATH"; then
            v_ok "workingDisk ativo em $WORKING_DISK_PATH (source=$WORKING_DISK_SOURCE; fstype=$WORKING_DISK_FSTYPE)."
        else
            v_falta "$WORKING_DISK_ERRO"
        fi
    elif [ "${WORKING_DISK_DISPENSADO:-}" = "sim" ]; then
        v_ok "workingDisk dispensado explicitamente."
    else
        v_falta "workingDisk ainda não decidido (caminho absoluto ou opção 0)."
    fi
    # Disco físico da VM: opcional por decisão do usuário.
    if [ -n "${HD1_BY_ID_PATH:-}" ] && [ "${HD1_DISPENSADO:-}" = "sim" ]; then
        v_falta "Configuração contraditória: HD1_BY_ID_PATH definido e HD1_DISPENSADO=sim."
    elif [ -n "${HD1_BY_ID_PATH:-}" ]; then
        if validar_disco_fisico_vm "$HD1_BY_ID_PATH" "${NVME_DEVICE:-}"; then
            v_ok "HD1 válido, livre e exclusivo da VM: $HD1_BY_ID_PATH -> $DISCO_VM_ALVO."
        else
            v_falta "HD1 inválido ou inseguro no estado atual: $DISCO_VM_ERRO"
        fi
    elif [ "${HD1_DISPENSADO:-}" = "sim" ]; then
        v_ok "Sem disco físico dedicado à VM (escolha registrada)."
    else
        v_falta "Disco da VM ainda não decidido (caminho ou opção 0)."
    fi
    v_fim
}
MODO_EXECUCAO="$(modo_execucao_etapa02 "${1:-}")" \
    || falhar "Uso: $0 [--redetectar|--verificar]"
[ "$MODO_EXECUCAO" = "verificar" ] && verificar

guard_mutation config.manage || exit 1

# Execução normal e --redetectar são deliberadamente equivalentes: não existe
# retomada implícita de escolhas administradas por esta etapa.
REDETECTAR=1

exigir_plataforma_suportada
exigir_nao_root
exigir_sudo
exigir_comando lscpu lspci lsblk ip awk sed findmnt mountpoint

if ! resolver_ultimo_inventario >/dev/null; then
    falhar "$INVENTARIO_ERRO Execute primeiro a opção 1 (etapa 1)."
fi
INVENTARIO_USADO="$INVENTARIO_RESOLVIDO"
validar_inventario_principal "$INVENTARIO_USADO" \
    || falhar "$INVENTARIO_ERRO Execute novamente a opção 1 (etapa 1)."
if ! comparar_inventario_com_hardware "$INVENTARIO_USADO"; then
    erro "$INVENTARIO_ERRO"
    [ -z "$INVENTARIO_DIFERENCAS" ] || while IFS= read -r diferenca; do erro "  - $diferenca"; done <<< "$INVENTARIO_DIFERENCAS"
    falhar "O passthrough.conf foi preservado. Execute novamente a opção 1 antes de reconfigurar."
fi
info "Inventário de hardware utilizado: $INVENTARIO_USADO"

# Reconciliar o valor antigo antes do reset evita que uma migração de backend
# seja silenciosa. A confirmação vem antes de qualquer escrita; o backup
# restrito é criado imediatamente depois por backup_e_resetar_config_etapa02.
BOOTLOADER_ANTIGO="${BOOTLOADER:-}"
BL_EFETIVO_INICIAL="$(detectar_bootloader)"
case "$BL_EFETIVO_INICIAL" in
    grub|kernelstub) ;;
    *) falhar "Bootloader efetivo não pôde ser identificado sem ambiguidade; passthrough.conf foi preservado." ;;
esac
plataforma_boot_backend_suportado "$BL_EFETIVO_INICIAL" \
    || falhar "Bootloader '$BL_EFETIVO_INICIAL' não é suportado pelo perfil $PLATAFORMA_PERFIL."
if [ -n "$BOOTLOADER_ANTIGO" ] && [ "$BOOTLOADER_ANTIGO" != "$BL_EFETIVO_INICIAL" ]; then
    erro "Divergência detectada: passthrough.conf registra BOOTLOADER='$BOOTLOADER_ANTIGO', mas o boot efetivo é '$BL_EFETIVO_INICIAL'."
    aviso "A configuração atual será preservada em backup 0600 antes de gravar o backend efetivo."
    confirmar_digitando MIGRAR-BOOTLOADER \
        "Confirmar conscientemente a migração de '$BOOTLOADER_ANTIGO' para '$BL_EFETIVO_INICIAL'?" \
        || falhar "Migração de bootloader cancelada; passthrough.conf não foi alterado."
fi

# ja_definido permanece como estrutura dos blocos, mas após o reset sempre
# retorna falso para as escolhas desta etapa.
ja_definido() {
    [ "$REDETECTAR" -eq 0 ] && [ -n "${!1:-}" ]
}

aviso "As escolhas atuais da configuração central serão descartadas e refeitas desde 1/8 Identidade."
backup_e_resetar_config_etapa02
if [ -n "$BACKUP_CONFIG_ETAPA02" ]; then
    info "Backup da configuração anterior: $BACKUP_CONFIG_ETAPA02"
else
    info "Conf criado a partir do modelo; não havia configuração anterior para backup."
fi

titulo "Detecção de configuração (grava em $CONF_ARQUIVO)"
info "Finalidade: configurar interativamente GPU, discos, plano de CPU/RAM, rede e complementos."
info "Pré-requisitos: execute como usuário normal com sudo; mantenha GPU, discos e rede que serão usados conectados."
info "Alteração desta etapa: faz backup restrito, limpa atomicamente suas escolhas e grava novas respostas no passthrough.conf."
aviso "As respostas são salvas por bloco à medida que o fluxo avança; cancelar não restaura escolhas antigas."
info "A execução sem argumento e --redetectar sempre recomeçam. Nada é formatado, montado, anexado à VM ou aplicado ao kernel aqui."
aviso "Risco: uma identificação errada pode orientar etapas posteriores; confira modelos, seriais, IDs e o resumo final."
info "O inventário recente acima é a referência automática; as validações ao vivo continuam sendo a autoridade. Não exige reboot."

# ----------------------------------------------------------------------------
# 1. Identidade
# ----------------------------------------------------------------------------
titulo "Etapa 3.1/8 Identidade"
if ja_definido USUARIO_LINUX; then
    RESPOSTA="$USUARIO_LINUX"
    info "USUARIO_LINUX já definido: $RESPOSTA"
else
    # $USER pode não estar exportada (sessões não interativas): id -un é a fonte
    # confiável, e com set -u a forma direta abortaria o script.
    RESPOSTA="$(perguntar 'Usuário Linux principal' "${USER:-$(id -un)}")"
fi
[ -n "$RESPOSTA" ] || falhar "Nome de usuário vazio."
validar_usuario_linux "$RESPOSTA" || falhar "$USUARIO_VALIDACAO_ERRO"
confirmar_usuario_linux_diferente "$RESPOSTA" \
    || falhar "Conta diferente do operador não foi autorizada."
salvar_conf USUARIO_LINUX "$RESPOSTA"
ok "Conta validada: $USUARIO_LINUX (uid=$USUARIO_VALIDADO_UID gid=$USUARIO_VALIDADO_GID home=$USUARIO_VALIDADO_HOME; operador=$USUARIO_OPERADOR)."
if ja_definido VM_NAME; then
    info "VM_NAME já definido: $VM_NAME"
else
    perguntar_validado 'Nome da VM no libvirt' 'win11' nome_vm_valido \
        'Nome de VM inválido: use letras, números, ponto, hífen ou sublinhado, sem espaços, até 63 caracteres' \
        || falhar "Cinco tentativas sem um nome de VM válido."
    salvar_conf VM_NAME "$PERGUNTA_VALIDADA"
fi

# ----------------------------------------------------------------------------
# 2. Bootloader
# ----------------------------------------------------------------------------
titulo "Etapa 3.2/8 Bootloader"
if ja_definido BOOTLOADER; then
    BL="$BOOTLOADER"
else
    BL="$BL_EFETIVO_INICIAL"
fi
case "$BL" in
    grub|kernelstub) ;;
    *)
        erro "Não identifiquei com segurança kernelstub nem GRUB. Diagnóstico:"
        echo "  - modo de firmware: $([ -d /sys/firmware/efi ] && echo UEFI || echo Legacy/BIOS)"
        echo "  - kernelstub: $(command -v kernelstub || echo 'não encontrado')"
        echo "  - /boot/efi/loader/entries: $(ls /boot/efi/loader/entries/ 2>/dev/null || echo 'não encontrado')"
        echo "  - /boot/grub/grub.cfg: $([ -f /boot/grub/grub.cfg ] && echo existe || echo 'não encontrado')"
        falhar "Sem bootloader efetivo não há como aplicar parâmetros de kernel (etapa 11)."
        ;;
esac
[ "$BL" = "$(detectar_bootloader)" ] \
    || falhar "O bootloader mudou durante a detecção; configuração não será gravada."
plataforma_boot_backend_suportado "$BL" \
    || falhar "Bootloader '$BL' não é suportado pelo perfil $PLATAFORMA_PERFIL."
salvar_conf BOOTLOADER "$BL"
validar_bootloader_configurado \
    || falhar "A pós-condição de bootloader falhou: $BOOTLOADER_VALIDACAO_ERRO"
ok "Bootloader efetivo reconciliado e salvo: $BOOTLOADER"

# ----------------------------------------------------------------------------
# 3. GPU (usada pela etapa 11)
# ----------------------------------------------------------------------------
titulo "Etapa 3.3/8 GPU do passthrough"
if ja_definido GPU_PCI_ID && ja_definido GPU_VENDOR_DEVICE_ID; then
    info "GPU já definida: $GPU_PCI_ID [$GPU_VENDOR_DEVICE_ID] (use --redetectar para refazer)"
else
    # Todas as saídas de vídeo do sistema (qualquer fabricante), para saber se
    # o host tem uma segunda GPU para continuar desenhando o desktop.
    mapfile -t TODAS_GPUS < <(lspci -nn | grep -iE 'VGA compatible controller|3D controller|Display controller' || true)
    if [ "${#TODAS_GPUS[@]}" -eq 0 ]; then
        falhar "Nenhum controlador de vídeo encontrado no lspci. Confira o encaixe/alimentação da placa."
    fi

    echo "Controladores de vídeo presentes neste host:"
    printf '  - %s\n' "${TODAS_GPUS[@]}"
    echo

    mapfile -t CANDIDATAS < <(printf '%s\n' "${TODAS_GPUS[@]}" | grep -i nvidia || true)
    if [ "${#CANDIDATAS[@]}" -eq 0 ]; then
        erro "Nenhuma GPU NVIDIA encontrada. Estes scripts (como o manual) cobrem apenas"
        erro "passthrough de GPU NVIDIA com driver proprietário no host."
        falhar "Ajuste manual necessário para outro fabricante (AMD/Intel)."
    fi

    if [ "${#TODAS_GPUS[@]}" -eq 1 ]; then
        aviso "Este host tem UMA ÚNICA GPU. Consequências, para você decidir agora:"
        echo "   - Ao ligar a VM, o gerenciador de exibição é encerrado: o desktop Linux"
        echo "     SAI DO AR e o monitor passa a mostrar o Windows. Isso é o desenho, não um defeito."
        echo "   - Ao desligar o Windows, o desktop volta sozinho (hook release da etapa 14)."
        echo "   - Se o vídeo não voltar: Ctrl+Alt+F3 (TTY) e 'bash util/recuperar-gpu.sh';"
        echo "     reiniciar o host é sempre uma saída válida."
        echo "   - Enquanto a VM roda, o Linux fica sem interface gráfica: programe backups,"
        echo "     downloads e serviços do host para não depender do desktop nesse período."
        confirmar "Entendi e quero seguir com passthrough de GPU única?" \
            || falhar "Cancelado. Com uma segunda GPU (mesmo uma iGPU) o desktop continuaria ativo."
    else
        info "Há mais de uma saída de vídeo: o host pode continuar com o desktop ativo em outra GPU."
        aviso "Os hooks da etapa 14 param o gerenciador de exibição de todo jeito (desenho do"
        aviso "manual, feito para GPU única). Se quiser manter o desktop vivo, edite depois"
        aviso "/etc/libvirt/hooks/qemu.d/<vm>/prepare/begin/01-gpu-preflight.sh e remova o systemctl stop."
    fi

    if [ "${#CANDIDATAS[@]}" -gt 1 ]; then
        echo
        echo "Mais de uma GPU NVIDIA encontrada. Escolha a que será ENTREGUE À VM:"
        IDX="$(escolher_da_lista 'GPU do passthrough (número)' nao "${CANDIDATAS[@]}")"
        LINHA_VGA="${CANDIDATAS[$((IDX - 1))]}"
    else
        LINHA_VGA="${CANDIDATAS[0]}"
    fi

    END_VGA="${LINHA_VGA%% *}"                                    # ex.: 0c:00.0
    ID_VGA="$(grep -oE '\[[0-9a-f]{4}:[0-9a-f]{4}\]' <<< "$LINHA_VGA" | tail -n1 | tr -d '[]')"
    [ -n "$ID_VGA" ] || falhar "Não consegui extrair o vendor:device da linha: $LINHA_VGA"

    # Função de áudio HDMI: normalmente no mesmo barramento, função .1
    BASE="${END_VGA%.*}"                                          # ex.: 0c:00
    LINHA_AUDIO="$(lspci -nn | grep "^${BASE}\." | grep -i 'audio' | head -n1 || true)"
    END_AUDIO=""; ID_AUDIO=""
    if [ -n "$LINHA_AUDIO" ]; then
        END_AUDIO="${LINHA_AUDIO%% *}"
        ID_AUDIO="$(grep -oE '\[[0-9a-f]{4}:[0-9a-f]{4}\]' <<< "$LINHA_AUDIO" | tail -n1 | tr -d '[]')"
    else
        aviso "Não encontrei função de áudio HDMI em ${BASE}.x."
        aviso "Sem ela, o som do Windows não sai pelo cabo HDMI/DP do monitor"
        aviso "(use um dispositivo USB em passthrough na etapa 15, se precisar)."
        confirmar "Seguir com passthrough somente de vídeo?" \
            || falhar "Cancelado. Confira 'lspci -nn | grep -i audio' e rode de novo."
    fi

    echo
    echo "Detectado no SEU hardware:"
    echo "  Vídeo: $LINHA_VGA"
    echo "  Áudio: ${LINHA_AUDIO:-(nenhum: passthrough somente de vídeo)}"
    confirmar "Confirmar este dispositivo como a GPU do passthrough?" \
        || falhar "Cancelado. Rode novamente e escolha o dispositivo correto."

    salvar_conf GPU_PCI_ID "0000:${END_VGA}"
    salvar_conf GPU_VENDOR_DEVICE_ID "$ID_VGA"
    salvar_conf GPU_AUDIO_PCI_ID "${END_AUDIO:+0000:${END_AUDIO}}"
    salvar_conf GPU_AUDIO_VENDOR_DEVICE_ID "$ID_AUDIO"
    ok "GPU: $GPU_PCI_ID [$GPU_VENDOR_DEVICE_ID]${GPU_AUDIO_PCI_ID:+ / áudio $GPU_AUDIO_PCI_ID [$GPU_AUDIO_VENDOR_DEVICE_ID]}"
fi

# ----------------------------------------------------------------------------
# 4. Serviço gráfico (para os hooks da etapa 14)
# ----------------------------------------------------------------------------
titulo "Etapa 3.4/8 Gerenciador de exibição"
if ja_definido DM_SERVICE; then
    info "DM_SERVICE já definido: $DM_SERVICE"
else
    DM="display-manager"
    for s in gdm3 gdm cosmic-greeter sddm lightdm; do
        if systemctl list-unit-files "${s}.service" 2>/dev/null | grep -q "^${s}.service"; then
            DM="$s"; break
        fi
    done
    ok "Serviço gráfico detectado: $DM"
    salvar_conf DM_SERVICE "$DM"
fi

# ----------------------------------------------------------------------------
# 5. Discos (usados pelas etapas 8 e 14)
# ----------------------------------------------------------------------------
titulo "Etapa 3.5/8 Discos"
info "O disco físico que contém a montagem '/' será apenas registrado e protegido das escolhas da VM."
DISCO_RAIZ="$(disco_raiz || true)"
if [ -n "$DISCO_RAIZ" ]; then
    ok "Disco físico que contém '/': $DISCO_RAIZ (somente registrado e protegido; não será alterado nem oferecido à VM)"
else
    aviso "Não consegui identificar o disco físico que contém '/'."
    aviso "As travas automáticas ficam mais fracas: confira modelo/serial com muito cuidado; nada será alterado nesta escolha."
fi
echo "Visão geral (compare com o inventário da etapa 1):"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL,TRAN
echo

# 5a. Disco do sistema
if ja_definido NVME_DEVICE; then
    info "Disco físico que contém '/' já registrado e protegido: $NVME_DEVICE"
else
    if [ -n "$DISCO_RAIZ" ]; then
        salvar_conf NVME_DEVICE "$DISCO_RAIZ"
        ok "Disco físico que contém '/' registrado e protegido: $NVME_DEVICE"
    else
        mapfile -t DISCOS < <(lsblk -dn -o NAME,SIZE,MODEL | awk '{print "/dev/"$0}')
        [ "${#DISCOS[@]}" -gt 0 ] || falhar "Nenhum disco listado por lsblk."
        echo "Qual disco físico contém a montagem '/' do Linux?"
        IDX="$(escolher_da_lista 'Disco do sistema (número)' nao "${DISCOS[@]}")"
        salvar_conf NVME_DEVICE "$(awk '{print $1}' <<< "${DISCOS[$((IDX - 1))]}")"
    fi
fi

# 5b. workingDisk opcional, já montado externamente pelo operador
# O projeto registra somente o caminho do mountpoint; não identifica nem
# persiste o dispositivo físico subjacente.
titulo "workingDisk do host (mountpoint externo opcional)"
cat <<'EXPLICA_WORKING_DISK'
O workingDisk é um caminho absoluto que o operador já montou por meios externos.
Este projeto apenas valida que o diretório existe e é exatamente um mountpoint
ativo; nunca cria o caminho-base, monta, formata, descobre UUID ou grava sua
montagem no fstab.

Digite 0 para dispensar o workingDisk. A dispensa explícita será salva e os
consumidores que precisarem de armazenamento exigirão um caminho alternativo.
EXPLICA_WORKING_DISK
while :; do
    CAMINHO="$(perguntar 'Caminho absoluto do workingDisk já montado (ou 0 para dispensar)' '/mnt/workingDisk')"
    if [ "$CAMINHO" = 0 ]; then
        salvar_conf_lote WORKING_DISK_PATH "" WORKING_DISK_DISPENSADO "sim"
        info "workingDisk dispensado explicitamente; nenhum mountpoint foi criado ou alterado."
        break
    fi
    if ! caminho_absoluto_seguro "$CAMINHO"; then
        aviso "Caminho inseguro. Informe um caminho absoluto sem componentes relativos ou metacaracteres."
        continue
    fi
    if [ ! -d "$CAMINHO" ]; then
        aviso "Diretório inexistente: $CAMINHO. Monte-o externamente antes de continuar."
        continue
    fi
    if ! validar_working_disk_montado "$CAMINHO"; then
        aviso "$WORKING_DISK_ERRO"
        continue
    fi
    WORKING_DISK="$CAMINHO"
    info "workingDisk confirmado: $WORKING_DISK"
    info "Diagnóstico: source=$WORKING_DISK_SOURCE; fstype=$WORKING_DISK_FSTYPE"
    confirmar "Registrar esse mountpoint externo como workingDisk?" \
        || cancelar_etapa "Escolha do workingDisk cancelada; nenhuma decisão de armazenamento foi salva."
    salvar_conf_lote WORKING_DISK_PATH "$WORKING_DISK" WORKING_DISK_DISPENSADO ""
    break
done

# 5c. Disco físico inteiro e exclusivo da VM (HD1) - opcional
if ja_definido HD1_BY_ID_PATH; then
    [ "${HD1_DISPENSADO:-}" != "sim" ] \
        || falhar "Configuração contraditória: HD1_BY_ID_PATH definido e HD1_DISPENSADO=sim. Rode --redetectar."
    info "HD1_BY_ID_PATH já definido: $HD1_BY_ID_PATH"
elif [ "$REDETECTAR" -eq 0 ] && [ "${HD1_DISPENSADO:-}" = "sim" ]; then
    info "Sem disco físico adicional da VM (dispensa salva; use --redetectar para rever)."
else
    titulo "Segundo disco físico pai inteiro da VM (HD1 opcional)"
    cat <<'EXPLICA_HD1'
A VM já possui seu disco de sistema no arquivo QCOW2 do host. Opcionalmente,
um SEGUNDO DISCO FÍSICO PAI INTEIRO pode ser destinado ao Windows, por exemplo
para uma biblioteca de jogos.

Esta escolha apenas registra um identificador persistente /dev/disk/by-id/ do
disco pai: nada é anexado à VM ou formatado agora. A etapa 14 fará a anexação.
Partições como /dev/sdb1 aparecem só para reconhecimento; selecionar /dev/sdb
registra o pai inteiro, com TODAS as partições. Disco montado ou em uso no host
permanece bloqueado até ser totalmente liberado.

Digite 0 para manter somente o QCOW2. A dispensa fica salva e será reutilizada
até você executar esta etapa com --redetectar.
EXPLICA_HD1
    # Todos os aliases persistentes de discos inteiros são considerados. A
    # deduplicação abaixo escolhe um único alias por alvo físico.
    mapfile -t BYIDS < <(find /dev/disk/by-id -maxdepth 1 ! -name '*-part*' -type l 2>/dev/null | sort)

    CANDIDATOS=(); DESCRICOES=()
    for b in "${BYIDS[@]}"; do
        ALVO="$(readlink -f "$b")"
        [ -b "$ALVO" ] || continue
        [ "$(lsblk -dno TYPE "$ALVO" 2>/dev/null | tr -d ' ')" = "disk" ] || continue
        [ -n "$DISCO_RAIZ" ] && [ "$ALVO" = "$DISCO_RAIZ" ] && continue
        # Evita listar o mesmo disco várias vezes (ata-, nvme-, scsi-, wwn-...).
        JA=0
        for c in "${CANDIDATOS[@]}"; do
            [ "$(readlink -f "$c")" = "$ALVO" ] && JA=1
        done
        [ "$JA" -eq 1 ] && continue
        TAM="$(lsblk -dno SIZE "$ALVO" 2>/dev/null | tr -d ' ')"
        MODELO="$(lsblk -dno MODEL "$ALVO" 2>/dev/null | sed 's/ *$//')"
        SERIAL="$(lsblk -dno SERIAL "$ALVO" 2>/dev/null | sed 's/ *$//')"
        PARTICOES="$({ lsblk -lnpo PATH,TYPE -- "$ALVO" 2>/dev/null || true; } \
            | awk '$2 == "part" {lista=lista separador $1; separador=", "} END {print lista}')"
        [ -n "$PARTICOES" ] || PARTICOES="nenhuma"
        MONTADO=""
        if disco_em_uso_pelo_host "$ALVO"; then
            MONTADO="  [INDISPONÍVEL: MONTADO/EM USO NO HOST]"
        else
            USO_STATUS=$?
            if [ "$USO_STATUS" -ne 1 ]; then
                aviso "Ignorando $b: ${DISCO_USO_ERRO:-falha ao inspecionar uso/montagens}."
                continue
            fi
        fi
        CANDIDATOS+=("$b")
        DESCRICOES+=("$(basename "$b") -> $ALVO (${TAM:-?}; ${MODELO:-?}; serial ${SERIAL:-?}; partições: $PARTICOES)${MONTADO}")
    done

    if [ "${#CANDIDATOS[@]}" -eq 0 ]; then
        aviso "Nenhum disco físico elegível foi detectado além dos discos protegidos."
    else
        echo "Discos detectados (a opção representa o disco pai inteiro):"
        aviso "Localize /dev/sdb1, por exemplo, no campo 'partições' e escolha o /dev/sdb pai correspondente."
        aviso "Confira modelo, serial e TAMANHO contra o inventário da etapa 1 antes de escolher."
    fi
    info "A opção 0 sempre mantém a VM somente com o disco virtual QCOW2."
    IDX="$(escolher_da_lista 'Disco físico adicional da VM (número, ou 0 para nenhum)' sim "${DESCRICOES[@]}")"
    if [ "$IDX" -eq 0 ]; then
        info "Nenhum disco físico adicional; a VM manterá somente o QCOW2."
        info "A dispensa fica salva até você executar esta etapa com --redetectar."
        salvar_conf_lote HD1_BY_ID_PATH "" HD1_DISPENSADO "sim"
    else
        HD1="${CANDIDATOS[$((IDX - 1))]}"
        HD1_ALVO="$(readlink -f "$HD1")"
        # Travas finais, mesmo com a lista já filtrada.
        [ -n "$DISCO_RAIZ" ] && [ "$HD1_ALVO" = "$DISCO_RAIZ" ] \
            && falhar "O caminho escolhido aponta para o disco da RAIZ do Linux. Abortado."
        SISTEMA_REAL="$(readlink -f -- "${NVME_DEVICE:-}" 2>/dev/null || true)"
        [ -n "$SISTEMA_REAL" ] && [ "$HD1_ALVO" = "$SISTEMA_REAL" ] \
            && falhar "O caminho escolhido aponta para o disco do sistema. Abortado."
        if disco_em_uso_pelo_host "$HD1_ALVO"; then
            erro "Esse disco tem partição montada ou em uso no host agora:"
            lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS "$HD1_ALVO"
            falhar "Desmonte tudo dele (e remova montagens automáticas) antes de entregá-lo à VM."
        else
            USO_STATUS=$?
            [ "$USO_STATUS" -eq 1 ] \
                || falhar "Não foi possível provar que o disco está livre: ${DISCO_USO_ERRO:-erro de inspeção}."
        fi
        echo "Disco inteiro escolhido (incluindo todas as partições abaixo):"
        lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL "$HD1_ALVO"
        aviso "PERDA DE DADOS: o Windows receberá acesso de escrita ao DISCO INTEIRO $HD1_ALVO."
        aviso "O script não formata o disco, mas inicializar, reparticionar, formatar ou instalar"
        aviso "o Windows nele pode destruir TODAS as partições e arquivos, inclusive os de /dev/sdb1."
        aviso "Só prossiga após conferir modelo/serial e possuir backup verificado dos dados importantes."
        confirmar_digitando AUTORIZAR \
            "Autorizar $HD1 ($HD1_ALVO) como disco físico adicional da VM?" \
            || cancelar_etapa "Disco não autorizado; a decisão de HD1 não foi salva."
        salvar_conf_lote HD1_BY_ID_PATH "$HD1" HD1_DISPENSADO ""
    fi
fi

# ----------------------------------------------------------------------------
# 6. CPU: topologia e plano de pinning (aplicado pela etapa 17)
# ----------------------------------------------------------------------------
titulo "Etapa 3.6/8 CPU: plano de pinning por socket/core"
info "Esta seção apenas calcula e grava o plano; o pinning será aplicado pela etapa 17."
# I5.3: o planner é o core Python. O shell continua sondando o host (lscpu),
# mostrando o mapa, perguntando e confirmando; o cálculo determinístico do
# recorte por core físico e a validação relacional têm uma implementação só.
TOPOLOGIA_CPU="$(cpu_topologia_csv)" \
    || falhar "lscpu não conseguiu fornecer CPU,CORE,SOCKET,NODE,ONLINE em formato parseável."
[ -n "$TOPOLOGIA_CPU" ] || falhar "A topologia parseável de CPU está vazia."

CPU_EXISTENTE_VALIDA=0
if ja_definido CPUS_VM && ja_definido CPUS_HOST \
   && ja_definido VM_VCPUS && ja_definido VM_CORES && ja_definido VM_THREADS; then
    if validar_layout_cpu "$CPUS_VM" "$CPUS_HOST" "$VM_VCPUS" "$VM_CORES" "$VM_THREADS" "$TOPOLOGIA_CPU"; then
        CPU_EXISTENTE_VALIDA=1
        info "Plano de pinning já definido e validado: VM=[$CPUS_VM] HOST=[$CPUS_HOST]"
    else
        aviso "O plano de CPU persistido não corresponde mais ao host: $CPU_LAYOUT_ERRO"
        aviso "Ele será redetectado antes de o pinning/isolamento ser aplicado pelas etapas próprias."
    fi
fi

if [ "$CPU_EXISTENTE_VALIDA" -eq 0 ]; then
    echo "Mapa lógico da CPU:"
    LC_ALL=C lscpu -e=CPU,CORE,SOCKET,NODE,ONLINE
    echo

    cpu_plano_pinning "$TOPOLOGIA_CPU" || falhar "$CPU_PLANO_ERRO"
    TOPOLOGIA_FINGERPRINT="$CPUPLANO_FINGERPRINT"
    info "Detectados $CPUPLANO_TOTAL_CORES cores físicos online, $CPUPLANO_THREADS_PER_CORE thread(s) por core."
    info "Core de housekeeping da CPU 0: $CPUPLANO_BOOT_CORE [$CPUPLANO_BOOT_CORE_CPUS]."
    aviso "Máximo permitido para a VM: $CPUPLANO_MAX_VM_CORES de $CPUPLANO_TOTAL_CORES cores físicos."
    NUC_VM="$(perguntar_inteiro 'Cores físicos dedicados à VM' \
        "$CPUPLANO_DEFAULT_VM_CORES" 1 "$CPUPLANO_MAX_VM_CORES")"

    cpu_plano_pinning "$TOPOLOGIA_CPU" "$NUC_VM" || falhar "$CPU_PLANO_ERRO"
    LISTA_VM="$CPUPLANO_CPUS_VM"
    LISTA_HOST="$CPUPLANO_CPUS_HOST"
    VCPUS_TOTAL="$CPUPLANO_VCPUS"
    THREADS_POR_NUCLEO="$CPUPLANO_THREADS_PER_CORE"
    TOTAL_NUCLEOS="$CPUPLANO_TOTAL_CORES"

    echo "Plano de pinning proposto por core físico completo:"
    echo "  VM   ($NUC_VM cores, $VCPUS_TOTAL vCPUs): $LISTA_VM"
    echo "  HOST ($((TOTAL_NUCLEOS - NUC_VM)) cores): $LISTA_HOST"
    confirmar "Confirmar este plano de pinning?" || falhar "Cancelado sem alterar o plano de CPU."

    # Revalidação antes de persistir: entre mostrar o mapa e confirmar, o
    # operador pode ter colocado uma CPU offline em outro terminal. Persistir um
    # plano calculado sobre topologia obsoleta é conflito, não detalhe.
    TOPOLOGIA_CPU="$(cpu_topologia_csv)" \
        || falhar "lscpu deixou de fornecer a topologia antes de gravar o plano."
    cpu_topologia_fingerprint "$TOPOLOGIA_CPU" || falhar "$CPU_TOPOLOGIA_ERRO"
    [ "$CPU_TOPOLOGIA_FINGERPRINT" = "$TOPOLOGIA_FINGERPRINT" ] \
        || falhar "A topologia de CPU mudou durante a confirmação; nada foi gravado. Execute a etapa 3 novamente."

    salvar_conf_lote \
        CPUS_VM "$LISTA_VM" \
        CPUS_HOST "$LISTA_HOST" \
        VM_CORES "$NUC_VM" \
        VM_THREADS "$THREADS_POR_NUCLEO" \
        VM_VCPUS "$VCPUS_TOTAL"
    validar_layout_cpu "$CPUS_VM" "$CPUS_HOST" "$VM_VCPUS" "$VM_CORES" "$VM_THREADS" "$TOPOLOGIA_CPU" \
        || falhar "O plano salvo não passou na validação final: $CPU_LAYOUT_ERRO"
    ok "Plano de pinning salvo; nenhum pinning foi aplicado nesta etapa."
fi

# ----------------------------------------------------------------------------
# 7. Memória da VM e HugePages (aplicadas pela etapa 17)
# ----------------------------------------------------------------------------
titulo "Etapa 3.7/8 Memória da VM"
RAM_TOTAL_MB="$(ram_total_mib)"
RESERVA_HOST_MB="$(ram_reserva_host_mib)"
RAM_MAX_VM_MB="$(ram_max_vm_mib)"
info "RAM total do host: ${RAM_TOTAL_MB} MiB (~$((RAM_TOTAL_MB / 1024)) GiB)"
info "Reserva do host:   ${RESERVA_HOST_MB} MiB (~$((RESERVA_HOST_MB / 1024)) GiB)"
[ "$RAM_MAX_VM_MB" -ge 4096 ] \
    || falhar "Sobram apenas ${RAM_MAX_VM_MB} MiB para a VM: pouco para Windows 11 (mínimo prático 4 GiB)."

if ja_definido VM_RAM_MB && [ "$VM_RAM_MB" -le "$RAM_MAX_VM_MB" ] 2>/dev/null && [ $((VM_RAM_MB % 1024)) -eq 0 ]; then
    info "VM_RAM_MB já definido: $VM_RAM_MB MiB (~$((VM_RAM_MB / 1024)) GiB)"
    salvar_conf HUGEPAGES_1G "$((VM_RAM_MB / 1024))"
else
    if [ -n "${VM_RAM_MB:-}" ] && [ "$REDETECTAR" -eq 0 ]; then
        aviso "VM_RAM_MB atual (${VM_RAM_MB}) é inválido: acima do teto ou não múltiplo de 1024 MiB."
    fi
    MAX_GIB=$((RAM_MAX_VM_MB / 1024))
    PADRAO_GIB=16
    [ "$PADRAO_GIB" -gt "$MAX_GIB" ] && PADRAO_GIB="$MAX_GIB"
    aviso "Teto para a VM: ${MAX_GIB} GiB. O restante NÃO é negociável: fica com o host."
    info "A etapa 17 (HugePages) reserva essa RAM no boot, tirando-a do host mesmo com a VM desligada."
    RAM_GIB="$(perguntar_inteiro 'RAM da VM em GiB' "$PADRAO_GIB" 4 "$MAX_GIB")"
    NOVA_RAM_MB=$((RAM_GIB * 1024))
    salvar_conf_lote \
        VM_RAM_MB "$NOVA_RAM_MB" \
        HUGEPAGES_1G "$RAM_GIB"
    ok "RAM da VM: $VM_RAM_MB MiB (${RAM_GIB} GiB); host mantém $((RAM_TOTAL_MB - VM_RAM_MB)) MiB."
fi

# ----------------------------------------------------------------------------
# 8. Rede, transferência de arquivos e ISOs
# ----------------------------------------------------------------------------
titulo "Etapa 3.8/8 Rede e complementos"

# Interfaces elegíveis vêm do sysfs: uma interface física possui o vínculo
# /sys/class/net/<nome>/device. Isso exclui lo, bridges, veth, tun/tap e demais
# interfaces virtuais sem depender de prefixos como en*/eth*. Wi-Fi é
# classificado exclusivamente pela presença de /wireless. A lista é sempre
# exibida, mesmo quando uma escolha válida já existe no arquivo central.
INTERFACE_ANTERIOR="${INTERFACE_FISICA:-}"
UPLINK_IPV4_EFETIVO="$(dispositivo_uplink_ipv4_efetivo || true)"
INTERFACES=()
DESCRICOES_REDE=()
for CAMINHO_IFACE in /sys/class/net/*; do
    [ -e "$CAMINHO_IFACE" ] || continue
    IFACE="$(basename "$CAMINHO_IFACE")"
    interface_fisica_elegivel "$IFACE" || continue
    TIPO="Ethernet"
    interface_wifi "$IFACE" && TIPO="Wi-Fi"
    ESTADO="$(cat "$CAMINHO_IFACE/operstate" 2>/dev/null || echo '?')"
    CARRIER="$(cat "$CAMINHO_IFACE/carrier" 2>/dev/null || echo '?')"
    MAC="$(cat "$CAMINHO_IFACE/address" 2>/dev/null || echo '?')"
    DRIVER_ALVO="$(readlink -f "$CAMINHO_IFACE/device/driver" 2>/dev/null || true)"
    DRIVER="${DRIVER_ALVO##*/}"
    [ -n "$DRIVER" ] || DRIVER="?"
    IPV4="$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk 'NR==1 {print $4}')"
    [ -n "$IPV4" ] || IPV4="sem IPv4"
    MARCA_ROTA=""
    [ "$IFACE" = "$UPLINK_IPV4_EFETIVO" ] \
        && MARCA_ROTA="; ROTA IPv4 EFETIVA para a internet"
    INTERFACES+=("$IFACE")
    DESCRICOES_REDE+=("$IFACE [$TIPO; estado=$ESTADO; carrier=$CARRIER; IPv4=$IPV4; MAC=$MAC; driver=$DRIVER$MARCA_ROTA]")
done
if [ "${#INTERFACES[@]}" -eq 0 ]; then
    erro "Nenhuma interface física Ethernet/Wi-Fi elegível foi encontrada."
    echo "Interfaces do kernel (lo e virtuais são deliberadamente excluídas):"
    ip -o link show | awk -F': ' '{print "  - "$2}'
    falhar "Conecte/habilite um adaptador físico e rode esta etapa novamente."
fi

echo "Interfaces físicas elegíveis:"
for IDX_REDE in "${!DESCRICOES_REDE[@]}"; do
    printf '  %d) %s\n' "$((IDX_REDE + 1))" "${DESCRICOES_REDE[$IDX_REDE]}"
done
if [ -n "$UPLINK_IPV4_EFETIVO" ]; then
    if interface_fisica_elegivel "$UPLINK_IPV4_EFETIVO"; then
        ok "Rota IPv4 efetiva para 1.1.1.1: dispositivo $UPLINK_IPV4_EFETIVO (consulta local; nenhum pacote enviado)."
    else
        aviso "A rota IPv4 efetiva usa '$UPLINK_IPV4_EFETIVO', que não é uma interface física elegível da lista (pode ser VPN/bridge)."
    fi
else
    aviso "Não foi possível determinar a rota IPv4 efetiva com 'ip -4 route get 1.1.1.1'."
fi

if ja_definido INTERFACE_FISICA && interface_fisica_elegivel "$INTERFACE_FISICA"; then
    TIPO_UPLINK="Ethernet"
    interface_wifi "$INTERFACE_FISICA" && TIPO_UPLINK="Wi-Fi"
    info "INTERFACE_FISICA já definida: $INTERFACE_FISICA ($TIPO_UPLINK)"
else
    if [ -n "${INTERFACE_FISICA:-}" ] && [ "$REDETECTAR" -eq 0 ]; then
        aviso "INTERFACE_FISICA='$INTERFACE_FISICA' não existe mais ou não é física; escolha novamente."
    fi
    PADRAO_REDE=""
    [ "${#INTERFACES[@]}" -eq 1 ] && PADRAO_REDE=1
    IDX="$(perguntar_inteiro 'Uplink físico da VM (número)' "$PADRAO_REDE" 1 "${#INTERFACES[@]}")"
    salvar_conf INTERFACE_FISICA "${INTERFACES[$((IDX - 1))]}"
fi

TIPO_UPLINK="Ethernet"
interface_wifi "$INTERFACE_FISICA" && TIPO_UPLINK="Wi-Fi"
ok "Uplink escolhido explicitamente: $INTERFACE_FISICA ($TIPO_UPLINK)."

MODO_ANTERIOR="${REDE_MODO:-}"
if [ "$TIPO_UPLINK" = "Wi-Fi" ]; then
    aviso "Wi-Fi station não transporta normalmente MACs de convidados sem 4addr/WDS."
    aviso "Bridge sobre Wi-Fi não é suportada por este projeto; será usada NAT libvirt vinculada ao adaptador."
    salvar_conf REDE_MODO "nat"
elif [ "$REDETECTAR" -eq 0 ] && { [ "${REDE_MODO:-}" = "bridge" ] || [ "${REDE_MODO:-}" = "nat" ]; }; then
    info "REDE_MODO já definido: $REDE_MODO"
else
    MODOS_REDE=(
        "bridge - VM recebe IP da LAN (Ethernet; exige mudança Netplan e reservas no roteador)"
        "nat - VM fica em sub-rede libvirt privada vinculada a $INTERFACE_FISICA (sem tocar Netplan)"
    )
    IDX="$(escolher_da_lista 'Modo final da rede (número)' nao "${MODOS_REDE[@]}")"
    if [ "$IDX" -eq 1 ]; then
        salvar_conf REDE_MODO "bridge"
    else
        salvar_conf REDE_MODO "nat"
    fi
fi

# Defaults explícitos mantêm configurações antigas válidas e deixam todos os
# nomes usados em YAML/XML visíveis e editáveis no arquivo central.
salvar_conf REDE_BRIDGE "${REDE_BRIDGE:-br0}"
salvar_conf REDE_LIBVIRT "${REDE_LIBVIRT:-passthrough-nat}"
salvar_conf REDE_BRIDGE_LIBVIRT "${REDE_BRIDGE_LIBVIRT:-virbr-vmnat}"
if [ -n "$MODO_ANTERIOR" ] && [ "$MODO_ANTERIOR" != "$REDE_MODO" ]; then
    aviso "Modo de rede mudou de '$MODO_ANTERIOR' para '$REDE_MODO'; os IPs serão recalculados na etapa 19."
    salvar_conf VM_IP_FIXO ""
    salvar_conf IP_FIXO_HOST ""
elif [ -n "$INTERFACE_ANTERIOR" ] \
     && [ "$INTERFACE_ANTERIOR" != "$INTERFACE_FISICA" ] \
     && [ "$REDE_MODO" = "bridge" ]; then
    aviso "Uplink da bridge mudou de '$INTERFACE_ANTERIOR' para '$INTERFACE_FISICA'; reservas da LAN anterior foram limpas."
    salvar_conf VM_IP_FIXO ""
    salvar_conf IP_FIXO_HOST ""
fi
if [ "$REDE_MODO" = "nat" ]; then
    if [ -z "$UPLINK_IPV4_EFETIVO" ]; then
        aviso "NAT escolhido, mas a rota IPv4 efetiva não pôde ser determinada; a etapa 19 recusará mutações enquanto isso persistir."
    elif [ "$INTERFACE_FISICA" != "$UPLINK_IPV4_EFETIVO" ]; then
        aviso "NAT foi escolhido em INTERFACE_FISICA=$INTERFACE_FISICA, mas a rota IPv4 efetiva usa $UPLINK_IPV4_EFETIVO."
        aviso "Torne $INTERFACE_FISICA a rota padrão ou desconecte/ajuste a métrica do outro adaptador."
        aviso "Depois execute novamente esta etapa e a etapa 19."
    else
        ok "NAT selecionado no uplink IPv4 efetivo: $INTERFACE_FISICA."
    fi
fi
exigir_config_rede
ok "Rede selecionada: modo=$REDE_MODO, uplink=$INTERFACE_FISICA ($TIPO_UPLINK)."

# Transferência de arquivos (airlock): local configurável
WORKING_DISK="${WORKING_DISK_PATH:-}"
if ! ja_definido TRANSFER_USER; then
    perguntar_validado 'Usuário de transferência do airlock' 'vmtransfer' nome_usuario_valido \
        'Nome de usuário inválido: use minúsculas, números, hífen ou sublinhado, iniciando por letra ou sublinhado, até 32 caracteres' \
        || falhar "Cinco tentativas sem um usuário de transferência válido."
    salvar_conf TRANSFER_USER "$PERGUNTA_VALIDADA"
fi
info "Airlock é o canal previsto e recomendado para troca de arquivos entre host e VM (etapa 20)."
info "É uma zona de trânsito: nada permanente, fora do backup e montada sem execução."
aviso "Essa é uma política recomendada, não uma garantia técnica de que outros canais sejam impossíveis."
if ja_definido AIRLOCK_DIR; then
    info "AIRLOCK_DIR já definido: $AIRLOCK_DIR"
else
    if [ -n "$WORKING_DISK" ]; then
        AIRLOCK_PADRAO="$WORKING_DISK/airlock"
        info "O padrão do airlock fica dentro do workingDisk já validado: $AIRLOCK_PADRAO"
    else
        AIRLOCK_PADRAO="/var/lib/vm-passthrough/airlock"
        info "Sem workingDisk, o padrão do airlock usa armazenamento local: $AIRLOCK_PADRAO"
    fi
    perguntar_validado 'Pasta de trânsito do airlock' "$AIRLOCK_PADRAO" caminho_absoluto_seguro \
        'Caminho inválido: informe um caminho absoluto sem componentes relativos, metacaracteres de shell ou quebras de linha' \
        || falhar "Cinco tentativas sem uma pasta de trânsito válida."
    salvar_conf AIRLOCK_DIR "$PERGUNTA_VALIDADA"
fi

# ISOs: opcionais aqui; obrigatórias somente na etapa 12. A política de
# armazenamento é a mesma da etapa 12: filho direto de /vm, sem vírgula e sem
# links. Um caminho fora dela é explicado e reperguntado, nunca derruba o fluxo.
for PAR in "ISO_WINDOWS:ISO do Windows 11" "ISO_VIRTIO:ISO virtio-win"; do
    VAR="${PAR%%:*}"; DESC="${PAR#*:}"
    if ! ja_definido "$VAR"; then
        perguntar_iso_opcional_conf "$VAR" "$DESC"
    fi
done

# ----------------------------------------------------------------------------
titulo "Resumo gravado em $CONF_ARQUIVO"
info "Inventário de hardware utilizado: $INVENTARIO_USADO"
ok "Comparação prévia: CPU, RAM, PCI e discos correspondem ao inventário selecionado."
grep -vE '^\s*(#|$)' "$CONF_ARQUIVO" | sed 's/^/  /'
echo
ok "Detecção concluída. Revise o resumo acima antes de seguir para as próximas etapas."
info "Na etapa 19: bridge solicitará reservas no roteador; NAT criará a reserva e o gateway automaticamente."
