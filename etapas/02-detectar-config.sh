#!/bin/bash
# ============================================================================
# etapas/02-detectar-config.sh - Detecção e confirmação da configuração
# ============================================================================
# Implementa a regra central do manual: NUNCA usar valores inventados.
# Detecta no PRÓPRIO hardware os valores dos placeholders (Capítulos 3, 11,
# 15, 16, 19, 21 e 23), confirma cada um com o usuário e grava tudo em
# passthrough.conf, reutilizado por todas as demais etapas.
#
# Travas de segurança desta etapa:
#   - GPU: avisa quando existe só UMA (o desktop Linux sai do ar enquanto a VM
#     roda) e obriga a escolher quando existe mais de uma.
#   - CPU: pelo menos 1 núcleo físico fica sempre com o host.
#   - RAM: teto = total menos a reserva do host (25%, entre 4 e 8 GiB).
#   - Disco da VM: o disco da RAIZ do Linux e o disco do HD2 nunca entram na
#     lista de candidatos; discos montados no host são recusados; "nenhum" é
#     uma escolha válida (a VM fica só com o QCOW2).
#   - Toda entrada numérica é validada e reperguntada em vez de derrubar o
#     script.
#
# Uso:
#   02-detectar-config.sh               detecta apenas o que falta no conf
#   02-detectar-config.sh --redetectar  refaz todas as detecções
#   02-detectar-config.sh --verificar   confere se o conf está completo
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

verificar() {
    [ -f "$CONF_ARQUIVO" ] && v_ok "passthrough.conf existe." || v_falta "passthrough.conf não existe."
    local var tipo rota caminho iface tipo_lista ipv4 marca encontrou=0 topologia ram_max
    local cpu_completa=1 memoria_completa=1
    for var in USUARIO_LINUX VM_NAME BOOTLOADER GPU_PCI_ID GPU_VENDOR_DEVICE_ID \
               UUID_HD2 CPUS_VM CPUS_HOST VM_VCPUS VM_CORES VM_THREADS \
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
            v_ok "Partição CPU cobre exatamente as CPUs online por socket/core."
        else
            v_falta "Configuração relacional de CPU inválida: ${CPU_LAYOUT_ERRO:-topologia indisponível}."
        fi
    fi
    if [ "$memoria_completa" -eq 1 ]; then
        ram_max="$(ram_max_vm_mib)"
        if inteiro_na_faixa "$VM_RAM_MB" 1024 1048576 \
           && inteiro_na_faixa "$HUGEPAGES_1G" 1 1048576 \
           && [ $((10#$VM_RAM_MB % 1024)) -eq 0 ] \
           && [ $((10#$HUGEPAGES_1G * 1024)) -eq $((10#$VM_RAM_MB)) ] \
           && [ "$VM_RAM_MB" -le "$ram_max" ]; then
            v_ok "RAM e HUGEPAGES_1G são coerentes e respeitam o teto atual de ${ram_max} MiB."
        else
            v_falta "VM_RAM_MB/HUGEPAGES_1G divergentes, fora do teto ou sem alinhamento de 1 GiB."
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
            aviso "NAT está selecionado em ${INTERFACE_FISICA:-vazio}, mas a rota IPv4 efetiva usa $rota; ajuste a rota/métrica antes da etapa 60."
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
    # Disco físico da VM: opcional por decisão do usuário
    if [ -n "${HD1_BY_ID_PATH:-}" ]; then
        v_ok "HD1_BY_ID_PATH=$HD1_BY_ID_PATH"
    elif [ "${HD1_DISPENSADO:-}" = "sim" ]; then
        v_ok "Sem disco físico dedicado à VM (escolha registrada)."
    else
        v_falta "Disco da VM ainda não decidido (caminho ou 'nenhum')."
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

REDETECTAR=0
[ "${1:-}" = "--redetectar" ] && REDETECTAR=1

exigir_nao_root
exigir_sudo
exigir_comando lspci lsblk ip awk sed findmnt

# ja_definido VAR: retorna 0 se a variável já tem valor e não estamos redetectando
ja_definido() {
    [ "$REDETECTAR" -eq 0 ] && [ -n "${!1:-}" ]
}

titulo "Detecção de configuração (grava em $CONF_ARQUIVO)"
[ -f "$CONF_ARQUIVO" ] || { cp "$PROJETO_DIR/passthrough.conf.example" "$CONF_ARQUIVO"; info "Conf criado a partir do modelo."; }

# ----------------------------------------------------------------------------
# 1. Identidade
# ----------------------------------------------------------------------------
titulo "1/8 Identidade"
if ja_definido USUARIO_LINUX; then
    info "USUARIO_LINUX já definido: $USUARIO_LINUX"
else
    # $USER pode não estar exportada (sessões não interativas): id -un é a fonte
    # confiável, e com set -u a forma direta abortaria o script.
    RESPOSTA="$(perguntar 'Usuário Linux principal' "${USER:-$(id -un)}")"
    [ -n "$RESPOSTA" ] || falhar "Nome de usuário vazio."
    salvar_conf USUARIO_LINUX "$RESPOSTA"
fi
getent passwd "$USUARIO_LINUX" >/dev/null \
    || falhar "Usuário '$USUARIO_LINUX' não existe neste sistema. Rode com --redetectar e corrija."
if ja_definido VM_NAME; then
    info "VM_NAME já definido: $VM_NAME"
else
    salvar_conf VM_NAME "$(perguntar 'Nome da VM no libvirt' 'win11')"
fi

# ----------------------------------------------------------------------------
# 2. Bootloader (Capítulo 15)
# ----------------------------------------------------------------------------
titulo "2/8 Bootloader (Capítulo 15)"
if ja_definido BOOTLOADER; then
    info "BOOTLOADER já definido: $BOOTLOADER"
else
    BL="$(detectar_bootloader)"
    if [ "$BL" = "desconhecido" ]; then
        erro "Não identifiquei kernelstub nem GRUB. Diagnóstico:"
        echo "  - modo de firmware: $([ -d /sys/firmware/efi ] && echo UEFI || echo Legacy/BIOS)"
        echo "  - kernelstub: $(command -v kernelstub || echo 'não encontrado')"
        echo "  - /boot/efi/loader/entries: $(ls /boot/efi/loader/entries/ 2>/dev/null || echo 'não encontrado')"
        echo "  - /boot/grub/grub.cfg: $([ -f /boot/grub/grub.cfg ] && echo existe || echo 'não encontrado')"
        falhar "Sem bootloader identificado não há como aplicar parâmetros de kernel (etapa 30)."
    fi
    ok "Bootloader detectado: $BL"
    salvar_conf BOOTLOADER "$BL"
fi

# ----------------------------------------------------------------------------
# 3. GPU (Capítulo 16)
# ----------------------------------------------------------------------------
titulo "3/8 GPU do passthrough (Capítulo 16)"
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
        echo "   - Ao desligar o Windows, o desktop volta sozinho (hook release da etapa 50)."
        echo "   - Se o vídeo não voltar: Ctrl+Alt+F3 (TTY) e 'bash util/recuperar-gpu.sh';"
        echo "     reiniciar o host é sempre uma saída válida."
        echo "   - Enquanto a VM roda, o Linux fica sem interface gráfica: programe backups,"
        echo "     downloads e serviços do host para não depender do desktop nesse período."
        confirmar "Entendi e quero seguir com passthrough de GPU única?" \
            || falhar "Cancelado. Com uma segunda GPU (mesmo uma iGPU) o desktop continuaria ativo."
    else
        info "Há mais de uma saída de vídeo: o host pode continuar com o desktop ativo em outra GPU."
        aviso "Os hooks da etapa 50 param o gerenciador de exibição de todo jeito (desenho do"
        aviso "manual, feito para GPU única). Se quiser manter o desktop vivo, edite depois"
        aviso "/etc/libvirt/hooks/qemu.d/<vm>/prepare/begin/01-gpu-para-vfio.sh e remova o systemctl stop."
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
        aviso "(use um dispositivo USB em passthrough na etapa 51, se precisar)."
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
# 4. Serviço gráfico (para os hooks do Capítulo 19)
# ----------------------------------------------------------------------------
titulo "4/8 Gerenciador de exibição"
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
# 5. Discos (Capítulos 5, 11 e 19)
# ----------------------------------------------------------------------------
titulo "5/8 Discos"
DISCO_RAIZ="$(disco_raiz || true)"
if [ -n "$DISCO_RAIZ" ]; then
    ok "Disco da RAIZ do Linux: $DISCO_RAIZ (protegido: nunca será oferecido à VM)"
else
    aviso "Não consegui identificar o disco da raiz automaticamente."
    aviso "As travas automáticas ficam mais fracas: confira modelo/serial com muito cuidado."
fi
echo "Visão geral (compare com o inventário da etapa 00):"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL,TRAN
echo

# 5a. Disco do sistema
if ja_definido NVME_DEVICE; then
    info "NVME_DEVICE (disco do sistema) já definido: $NVME_DEVICE"
else
    if [ -n "$DISCO_RAIZ" ]; then
        salvar_conf NVME_DEVICE "$DISCO_RAIZ"
        ok "Disco do sistema: $NVME_DEVICE (detectado pela montagem de /)"
    else
        mapfile -t DISCOS < <(lsblk -dn -o NAME,SIZE,MODEL | awk '{print "/dev/"$0}')
        [ "${#DISCOS[@]}" -gt 0 ] || falhar "Nenhum disco listado por lsblk."
        echo "Qual disco contém o sistema (raiz do Linux)?"
        IDX="$(escolher_da_lista 'Disco do sistema (número)' nao "${DISCOS[@]}")"
        salvar_conf NVME_DEVICE "$(awk '{print $1}' <<< "${DISCOS[$((IDX - 1))]}")"
    fi
fi

# 5b. HD2 (partição NTFS montada em /mnt/docs4) - identificado por UUID
if ja_definido UUID_HD2; then
    info "UUID_HD2 já definido: $UUID_HD2"
else
    echo "Partições NTFS encontradas (candidatas a HD2, o disco de DOCUMENTOS do Linux):"
    mapfile -t NTFS_DEVS < <({ sudo blkid -t TYPE=ntfs -o device 2>/dev/null || true; \
                               sudo blkid -t TYPE=ntfs3 -o device 2>/dev/null || true; } | sort -u)
    if [ "${#NTFS_DEVS[@]}" -eq 0 ]; then
        erro "Nenhuma partição NTFS encontrada. O HD2 é o disco onde ficam seus documentos"
        erro "e a pasta de transferência (airlock) do Capítulo 24."
        falhar "Conecte/formate o HD2 (NTFS) e rode esta etapa de novo."
    fi
    DESCRICOES=()
    for d in "${NTFS_DEVS[@]}"; do
        TAM="$(lsblk -no SIZE "$d" 2>/dev/null | head -n1 | tr -d ' ')"
        DISCO_PAI="$(disco_de "$d" 2>/dev/null || echo '?')"
        MODELO="$(lsblk -dno MODEL "$DISCO_PAI" 2>/dev/null | head -n1 | sed 's/ *$//')"
        MARCA=""
        [ -n "$DISCO_RAIZ" ] && [ "$DISCO_PAI" = "$DISCO_RAIZ" ] && MARCA="  <-- MESMO DISCO DO SISTEMA"
        DESCRICOES+=("$d  (${TAM:-?}; disco $DISCO_PAI ${MODELO:-?})  UUID=$(sudo blkid -s UUID -o value "$d")${MARCA}")
    done
    aviso "HD2 é o disco de documentos do LINUX, NUNCA o disco que você vai entregar à VM."
    IDX="$(escolher_da_lista 'Partição do HD2 (número)' nao "${DESCRICOES[@]}")"
    DEV_HD2="${NTFS_DEVS[$((IDX - 1))]}"
    UUID_ESCOLHIDO="$(sudo blkid -s UUID -o value "$DEV_HD2")"
    [ -n "$UUID_ESCOLHIDO" ] || falhar "Não consegui ler o UUID de $DEV_HD2."
    HD2_DISCO_PAI="$(disco_de "$DEV_HD2" || echo '')"
    if [ -n "$DISCO_RAIZ" ] && [ "$HD2_DISCO_PAI" = "$DISCO_RAIZ" ]; then
        aviso "Essa partição está no MESMO disco do sistema: você perde a separação física"
        aviso "entre sistema e documentos (uma falha do disco leva os dois)."
        confirmar "Seguir mesmo assim?" || falhar "Cancelado."
    fi
    confirmar "Confirmar HD2 = $DEV_HD2 (UUID=$UUID_ESCOLHIDO)?" || falhar "Cancelado."
    salvar_conf UUID_HD2 "$UUID_ESCOLHIDO"
    salvar_conf HD2_DISCO_PAI "$HD2_DISCO_PAI"
fi

# 5c. Disco físico exclusivo da VM (HD1) - opcional
if ja_definido HD1_BY_ID_PATH; then
    info "HD1_BY_ID_PATH já definido: $HD1_BY_ID_PATH"
elif [ "$REDETECTAR" -eq 0 ] && [ "${HD1_DISPENSADO:-}" = "sim" ]; then
    info "Sem disco físico dedicado à VM (escolha registrada anteriormente)."
else
    titulo "Disco físico exclusivo da VM (opcional)"
    cat <<'EXPLICA'
Um disco inteiro pode ser entregue à VM (útil para biblioteca de jogos: o
Windows enxerga o disco real, sem camada de arquivo). É OPCIONAL: sem ele a
VM funciona apenas com o disco virtual QCOW2, que também pode ser ampliado.

O disco escolhido passa a ser propriedade da VM: NÃO o monte no host enquanto
a VM estiver ligada, sob risco de corromper o sistema de arquivos.
EXPLICA
    # Candidatos: discos inteiros por caminho estável, já excluindo raiz e HD2
    mapfile -t BYIDS < <(find /dev/disk/by-id -maxdepth 1 \( -name 'ata-*' -o -name 'nvme-*' -o -name 'usb-*' \) \
                              ! -name '*-part*' ! -name 'nvme-eui.*' -type l 2>/dev/null | sort)
    if [ "${#BYIDS[@]}" -eq 0 ]; then
        mapfile -t BYIDS < <(find /dev/disk/by-id -maxdepth 1 ! -name '*-part*' ! -name 'wwn-*' -type l 2>/dev/null | sort)
    fi

    CANDIDATOS=(); DESCRICOES=()
    for b in "${BYIDS[@]}"; do
        ALVO="$(readlink -f "$b")"
        [ -b "$ALVO" ] || continue
        [ "$(lsblk -dno TYPE "$ALVO" 2>/dev/null | tr -d ' ')" = "disk" ] || continue
        [ -n "$DISCO_RAIZ" ] && [ "$ALVO" = "$DISCO_RAIZ" ] && continue
        [ -n "${HD2_DISCO_PAI:-}" ] && [ "$ALVO" = "$HD2_DISCO_PAI" ] && continue
        # evita listar o mesmo disco duas vezes (by-id costuma ter apelidos)
        JA=0
        for c in ${CANDIDATOS[@]+"${CANDIDATOS[@]}"}; do
            [ "$(readlink -f "$c")" = "$ALVO" ] && JA=1
        done
        [ "$JA" -eq 1 ] && continue
        TAM="$(lsblk -dno SIZE "$ALVO" 2>/dev/null | tr -d ' ')"
        MODELO="$(lsblk -dno MODEL "$ALVO" 2>/dev/null | sed 's/ *$//')"
        MONTADO=""
        if disco_em_uso_pelo_host "$ALVO"; then
            MONTADO="  [MONTADO NO HOST]"
        else
            USO_STATUS=$?
            if [ "$USO_STATUS" -ne 1 ]; then
                aviso "Ignorando $b: ${DISCO_USO_ERRO:-falha ao inspecionar uso/montagens}."
                continue
            fi
        fi
        CANDIDATOS+=("$b")
        DESCRICOES+=("$(basename "$b")  ->  $ALVO  (${TAM:-?}; ${MODELO:-?})${MONTADO}")
    done

    if [ "${#CANDIDATOS[@]}" -eq 0 ]; then
        info "Nenhum disco elegível além do sistema e do HD2. A VM usará somente o QCOW2."
        salvar_conf HD1_BY_ID_PATH ""
        salvar_conf HD1_DISPENSADO "sim"
    else
        echo "Discos elegíveis (raiz do Linux e HD2 já foram excluídos da lista):"
        aviso "Confira modelo, serial e TAMANHO contra o inventário da etapa 00 antes de escolher."
        IDX="$(escolher_da_lista 'Disco para a VM (número, ou 0 para nenhum)' sim "${DESCRICOES[@]}")"
        if [ "$IDX" -eq 0 ]; then
            info "Nenhum disco físico dedicado. A VM usará somente o QCOW2."
            salvar_conf HD1_BY_ID_PATH ""
            salvar_conf HD1_DISPENSADO "sim"
        else
            HD1="${CANDIDATOS[$((IDX - 1))]}"
            HD1_ALVO="$(readlink -f "$HD1")"
            # Travas finais, mesmo com a lista já filtrada
            [ -n "$DISCO_RAIZ" ] && [ "$HD1_ALVO" = "$DISCO_RAIZ" ] \
                && falhar "O caminho escolhido aponta para o disco da RAIZ do Linux. Abortado."
            [ "$HD1_ALVO" = "${NVME_DEVICE:-}" ] \
                && falhar "O caminho escolhido aponta para o disco do sistema. Abortado."
            if [ -n "${HD2_DISCO_PAI:-}" ] && [ "$HD1_ALVO" = "$HD2_DISCO_PAI" ]; then
                falhar "O caminho escolhido aponta para o disco do HD2 (documentos). Abortado."
            fi
            if disco_em_uso_pelo_host "$HD1_ALVO"; then
                erro "Esse disco tem partição MONTADA no host agora:"
                lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS "$HD1_ALVO"
                falhar "Desmonte tudo dele (e remova do fstab) antes de entregá-lo à VM."
            else
                USO_STATUS=$?
                [ "$USO_STATUS" -eq 1 ] \
                    || falhar "Não foi possível provar que o disco está livre: ${DISCO_USO_ERRO:-erro de inspeção}."
            fi
            echo "Disco escolhido:"
            lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL "$HD1_ALVO"
            aviso "Todo o conteúdo deste disco passa a ser gerenciado pelo Windows."
            aviso "Se ele JÁ TEM dados, não formate nada dentro do Windows."
            confirmar "Confirmar $HD1 ($HD1_ALVO) como disco da VM?" || falhar "Cancelado."
            salvar_conf HD1_BY_ID_PATH "$HD1"
            salvar_conf HD1_DISPENSADO ""
        fi
    fi
fi

# ----------------------------------------------------------------------------
# 6. CPU: topologia e pinning (Capítulo 21)
# ----------------------------------------------------------------------------
titulo "6/8 CPU (topologia parseável por socket/core)"
TOPOLOGIA_CPU="$(cpu_topologia_csv)" \
    || falhar "lscpu não conseguiu fornecer CPU,CORE,SOCKET,NODE,ONLINE em formato parseável."
[ -n "$TOPOLOGIA_CPU" ] || falhar "A topologia parseável de CPU está vazia."

CPU_EXISTENTE_VALIDA=0
if ja_definido CPUS_VM && ja_definido CPUS_HOST \
   && ja_definido VM_VCPUS && ja_definido VM_CORES && ja_definido VM_THREADS; then
    if validar_layout_cpu "$CPUS_VM" "$CPUS_HOST" "$VM_VCPUS" "$VM_CORES" "$VM_THREADS" "$TOPOLOGIA_CPU"; then
        CPU_EXISTENTE_VALIDA=1
        info "Pinning já definido e validado: VM=[$CPUS_VM] HOST=[$CPUS_HOST]"
    else
        aviso "O mapa CPU persistido não corresponde mais ao host: $CPU_LAYOUT_ERRO"
        aviso "Ele será redetectado antes de qualquer etapa de pinning/isolamento."
    fi
fi

if [ "$CPU_EXISTENTE_VALIDA" -eq 0 ]; then
    echo "Mapa lógico da CPU:"
    LC_ALL=C lscpu -e=CPU,CORE,SOCKET,NODE,ONLINE
    echo

    # SOCKET faz parte da chave: IDs de CORE podem se repetir em hosts
    # multissocket. Todos os siblings online de um core permanecem juntos.
    declare -A NUCLEO_THREADS=()
    while IFS=, read -r CPU CORE SOCKET NODE ONLINE; do
        case "$ONLINE" in Y|yes|YES|1) ;; *) continue ;; esac
        CHAVE_NUCLEO="$SOCKET:$CORE"
        NUCLEO_THREADS[$CHAVE_NUCLEO]="${NUCLEO_THREADS[$CHAVE_NUCLEO]:+${NUCLEO_THREADS[$CHAVE_NUCLEO]},}$CPU"
    done <<< "$TOPOLOGIA_CPU"

    mapfile -t NUCLEOS < <(printf '%s\n' "${!NUCLEO_THREADS[@]}" \
        | LC_ALL=C sort -t: -k1,1n -k2,2n)
    TOTAL_NUCLEOS="${#NUCLEOS[@]}"
    [ "$TOTAL_NUCLEOS" -ge 2 ] \
        || falhar "Só encontrei $TOTAL_NUCLEOS core(s) físico(s) online; um precisa ficar integralmente com o host."
    THREADS_POR_NUCLEO=""
    CHAVE_CPU_BOOT=""
    for CHAVE_NUCLEO in "${NUCLEOS[@]}"; do
        QTD_THREADS="$(awk -F',' '{print NF}' <<< "${NUCLEO_THREADS[$CHAVE_NUCLEO]}")"
        IFS=',' read -r -a THREADS_CORE <<< "${NUCLEO_THREADS[$CHAVE_NUCLEO]}"
        for CPU_LOGICA in "${THREADS_CORE[@]}"; do
            [ "$CPU_LOGICA" -ne 0 ] || CHAVE_CPU_BOOT="$CHAVE_NUCLEO"
        done
        if [ -z "$THREADS_POR_NUCLEO" ]; then
            THREADS_POR_NUCLEO="$QTD_THREADS"
        elif [ "$QTD_THREADS" -ne "$THREADS_POR_NUCLEO" ]; then
            falhar "Topologia SMT heterogênea/offline: core $CHAVE_NUCLEO tem $QTD_THREADS thread(s), esperado $THREADS_POR_NUCLEO. Reative CPUs ou configure manualmente."
        fi
    done
    [ -n "$CHAVE_CPU_BOOT" ] \
        || falhar "A CPU lógica 0 não aparece online na topologia; não é seguro gerar um mapa pronto para nohz_full."
    info "Detectados $TOTAL_NUCLEOS cores físicos online, $THREADS_POR_NUCLEO thread(s) por core."
    info "Core de housekeeping da CPU 0: $CHAVE_CPU_BOOT [${NUCLEO_THREADS[$CHAVE_CPU_BOOT]}]."

    # Teto: o host mantém ao menos um core completo (dois quando há folga).
    MAX_VM=$((TOTAL_NUCLEOS - 1))
    [ "$TOTAL_NUCLEOS" -ge 6 ] && MAX_VM=$((TOTAL_NUCLEOS - 2))
    PADRAO_VM="$MAX_VM"
    aviso "Máximo permitido para a VM: $MAX_VM de $TOTAL_NUCLEOS cores físicos."
    NUC_VM="$(perguntar_inteiro 'Cores físicos dedicados à VM' "$PADRAO_VM" 1 "$MAX_VM")"

    LISTA_VM=""
    LISTA_HOST="${NUCLEO_THREADS[$CHAVE_CPU_BOOT]}"
    CORES_HOST=$((TOTAL_NUCLEOS - NUC_VM))
    CORES_HOST_RESTANTES=$((CORES_HOST - 1))
    IDX_HOST=0
    for CHAVE_NUCLEO in "${NUCLEOS[@]}"; do
        [ "$CHAVE_NUCLEO" != "$CHAVE_CPU_BOOT" ] || continue
        if [ "$IDX_HOST" -lt "$CORES_HOST_RESTANTES" ]; then
            LISTA_HOST="${LISTA_HOST:+${LISTA_HOST},}${NUCLEO_THREADS[$CHAVE_NUCLEO]}"
            IDX_HOST=$((IDX_HOST + 1))
        else
            LISTA_VM="${LISTA_VM:+${LISTA_VM},}${NUCLEO_THREADS[$CHAVE_NUCLEO]}"
        fi
    done
    VCPUS_TOTAL="$(expandir_lista_cpus "$LISTA_VM" | wc -l)"
    validar_layout_cpu "$LISTA_VM" "$LISTA_HOST" "$VCPUS_TOTAL" "$NUC_VM" "$THREADS_POR_NUCLEO" "$TOPOLOGIA_CPU" \
        || falhar "A proposta gerada falhou na validação interna: $CPU_LAYOUT_ERRO"

    echo "Proposta de alocação por core físico completo:"
    echo "  VM   ($NUC_VM cores, $VCPUS_TOTAL vCPUs): $LISTA_VM"
    echo "  HOST ($((TOTAL_NUCLEOS - NUC_VM)) cores): $LISTA_HOST"
    confirmar "Confirmar este mapa?" || falhar "Cancelado sem alterar o mapa CPU."

    salvar_conf_lote \
        CPUS_VM "$LISTA_VM" \
        CPUS_HOST "$LISTA_HOST" \
        VM_CORES "$NUC_VM" \
        VM_THREADS "$THREADS_POR_NUCLEO" \
        VM_VCPUS "$VCPUS_TOTAL"
    validar_layout_cpu "$CPUS_VM" "$CPUS_HOST" "$VM_VCPUS" "$VM_CORES" "$VM_THREADS" "$TOPOLOGIA_CPU" \
        || falhar "O mapa salvo não passou na validação final: $CPU_LAYOUT_ERRO"
fi

# ----------------------------------------------------------------------------
# 7. Memória da VM e HugePages (Capítulo 21)
# ----------------------------------------------------------------------------
titulo "7/8 Memória da VM"
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
    info "A etapa 52 (HugePages) reserva essa RAM no boot, tirando-a do host mesmo com a VM desligada."
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
titulo "8/8 Rede e complementos"

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
    aviso "Modo de rede mudou de '$MODO_ANTERIOR' para '$REDE_MODO'; os IPs serão recalculados na etapa 60."
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
        aviso "NAT escolhido, mas a rota IPv4 efetiva não pôde ser determinada; a etapa 60 recusará mutações enquanto isso persistir."
    elif [ "$INTERFACE_FISICA" != "$UPLINK_IPV4_EFETIVO" ]; then
        aviso "NAT foi escolhido em INTERFACE_FISICA=$INTERFACE_FISICA, mas a rota IPv4 efetiva usa $UPLINK_IPV4_EFETIVO."
        aviso "Torne $INTERFACE_FISICA a rota padrão ou desconecte/ajuste a métrica do outro adaptador."
        aviso "Depois execute novamente esta etapa e a etapa 60."
    else
        ok "NAT selecionado no uplink IPv4 efetivo: $INTERFACE_FISICA."
    fi
fi
exigir_config_rede
ok "Rede selecionada: modo=$REDE_MODO, uplink=$INTERFACE_FISICA ($TIPO_UPLINK)."

# Transferência de arquivos (airlock): local configurável
DOCS4="${DOCS4_MONTAGEM:-/mnt/docs4}"
if ! ja_definido TRANSFER_USER; then
    salvar_conf TRANSFER_USER "$(perguntar 'Usuário de transferência do airlock' 'vmtransfer')"
fi
if ja_definido AIRLOCK_DIR; then
    info "AIRLOCK_DIR já definido: $AIRLOCK_DIR"
else
    info "Airlock é o ÚNICO canal de troca de arquivos entre host e VM (Capítulo 24)."
    info "É uma zona de trânsito: nada permanente, fora do backup, montada sem execução."
    CAMINHO="$(perguntar 'Pasta de trânsito do airlock' "$DOCS4/airlock")"
    case "$CAMINHO" in
        /*) : ;;
        *)  falhar "Informe um caminho absoluto (começando com /)." ;;
    esac
    salvar_conf AIRLOCK_DIR "$CAMINHO"
fi

# ISOs: opcionais aqui; obrigatórias somente na etapa 40
for PAR in "ISO_WINDOWS:ISO do Windows 11" "ISO_VIRTIO:ISO virtio-win"; do
    VAR="${PAR%%:*}"; DESC="${PAR#*:}"
    if ! ja_definido "$VAR"; then
        CAMINHO="$(perguntar "Caminho local da $DESC (ENTER para informar depois, na etapa 40)" '')"
        if [ -n "$CAMINHO" ] && [ ! -f "$CAMINHO" ]; then
            aviso "Arquivo não encontrado: $CAMINHO (ficará vazio; informe na etapa 40)."
            CAMINHO=""
        fi
        salvar_conf "$VAR" "$CAMINHO"
    fi
done

# ----------------------------------------------------------------------------
titulo "Resumo gravado em $CONF_ARQUIVO"
grep -vE '^\s*(#|$)' "$CONF_ARQUIVO" | sed 's/^/  /'
echo
ok "Detecção concluída. Revise o resumo acima antes de seguir para as próximas etapas."
info "Na etapa 60: bridge solicitará reservas no roteador; NAT criará a reserva e o gateway automaticamente."
