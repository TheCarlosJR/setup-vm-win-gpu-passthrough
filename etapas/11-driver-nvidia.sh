#!/bin/bash
# ============================================================================
# etapas/11-driver-nvidia.sh - Etapa 5: Drivers NVIDIA no Host
# ============================================================================
# Garante o driver proprietário NVIDIA funcionando no Ubuntu/Pop!_OS. Este é
# o estado de repouso da GPU enquanto a VM está desligada.
# ============================================================================
SCRIPT_VERSION="1.0.0"
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

verificar() {
    local saida_nvidia="" identificacao="" rc_nvidia=0
    local raiz_pci="" link_driver="" alvo_driver="" driver=""
    if plataforma_carregar; then
        v_ok "Estratégia NVIDIA do perfil $PLATAFORMA_PERFIL: $PLATAFORMA_NVIDIA_ESTRATEGIA."
    else
        v_erro "$PLATAFORMA_ERRO"
    fi
    # Mesma política já corrigida em util/atualizar-host.sh: sem a ferramenta
    # nada foi observado (indeterminado); rc 0 com saída não parseável não é
    # prova de driver; e rc != 0 é estado observado e errado.
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        v_indeterminado "nvidia-smi não está disponível; o driver NVIDIA não pôde ser sondado."
    elif saida_nvidia="$(nvidia-smi 2>&1)"; then
        if nvidia_smi_comprovado "$saida_nvidia"; then
            # A identificação sai da MESMA saída já comprovada; a consulta
            # extra de antes podia vir vazia e ainda assim virar "funcional".
            identificacao="$(LC_ALL=C grep -Eo 'Driver Version:[[:space:]]*[0-9][0-9.]*' \
                <<< "$saida_nvidia" | head -n1)" || identificacao=""
            v_ok "nvidia-smi funcional: ${identificacao:-driver comprovado na saída}"
        else
            v_indeterminado "nvidia-smi terminou com zero, mas a saída não contém identificação e versão parseáveis; o driver não foi comprovado."
        fi
    else
        rc_nvidia=$?
        v_erro "nvidia-smi falhou com código $rc_nvidia; o driver NVIDIA não está operacional neste boot."
    fi
    # O vínculo é lido no sysfs do dispositivo configurado. A janela `-A3` do
    # lspci casava QUALQUER VGA e podia aprovar uma GPU que não é a da VM.
    if v_var_definida GPU_PCI_ID pci_bdf_valido; then
        raiz_pci="$(caminho_sistema /sys/bus/pci/devices)" || raiz_pci=""
        link_driver="$raiz_pci/$GPU_PCI_ID/driver"
        if [ -z "$raiz_pci" ] || [ ! -d "$raiz_pci" ]; then
            v_indeterminado "Barramento PCI não legível em ${raiz_pci:-/sys/bus/pci/devices}; o driver em uso não pôde ser observado."
        elif [ ! -d "$raiz_pci/$GPU_PCI_ID" ]; then
            v_erro "GPU $GPU_PCI_ID não está presente no barramento PCI; a configuração aponta para um endereço inexistente."
        elif [ ! -L "$link_driver" ]; then
            v_falta "GPU não está com o driver 'nvidia' em uso."
        else
            alvo_driver="$(readlink -f -- "$link_driver" 2>/dev/null)" || alvo_driver=""
            driver="${alvo_driver##*/}"
            if [ -z "$driver" ]; then
                v_indeterminado "Não foi possível resolver o driver vinculado a $GPU_PCI_ID; o estado não pôde ser observado."
            elif [ "$driver" = nvidia ]; then
                v_ok "GPU vinculada ao driver 'nvidia'."
            else
                v_falta "GPU não está com o driver 'nvidia' em uso; driver atual: $driver."
            fi
        fi
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

guard_mutation gpu.driver || exit 1
exigir_plataforma_suportada
[ "$PLATAFORMA_GERENCIADOR_PACOTES" = apt ] \
    || falhar "A etapa 5 requer o perfil APT de Ubuntu/Pop!_OS."
exigir_nao_root

titulo "Antes de continuar"
info "Finalidade: manter a GPU no driver proprietário NVIDIA enquanto a VM estiver desligada."
info "Plataforma: $PLATAFORMA_PERFIL; estratégia selecionada por ID: $PLATAFORMA_NVIDIA_ESTRATEGIA."
info "Pré-requisitos: etapa 4 concluída, GPU NVIDIA presente, rede/repositórios funcionais e sudo."
info "Alterações: se nvidia-smi já funciona, nenhuma; caso contrário, o APT é atualizado e pacotes NVIDIA são instalados."
info "Recomendação: mantenha acesso a TTY ou mídia de recuperação e não interrompa a instalação."
aviso "Risco principal: um driver incompatível pode impedir a sessão gráfica no próximo boot."
info "Reboot/retorno: com nvidia-smi funcional, sai sem alteração nem reboot; após instalar, reinicie, valide nvidia-smi e retorne ao menu."

exigir_sudo

titulo "Etapa 5: Driver NVIDIA no host"

# A mesma prova do verificador: rc 0 com saída não parseável não autoriza
# anunciar "já funciona" nem pular a instalação do driver.
SAIDA_NVIDIA=""
if command -v nvidia-smi >/dev/null 2>&1 && SAIDA_NVIDIA="$(nvidia-smi 2>&1)" \
   && nvidia_smi_comprovado "$SAIDA_NVIDIA"; then
    ok "nvidia-smi já funciona: nenhum pacote será alterado e não é necessário reiniciar."
    printf '%s\n' "$SAIDA_NVIDIA"
    exit 0
fi

info "nvidia-smi ausente ou não funcional. Consultando os repositórios..."
sudo apt update

PACOTE=""
case "$PLATAFORMA_NVIDIA_ESTRATEGIA" in
    system76)
        # A estratégia System76 é permitida somente quando ID=pop. A mera
        # visibilidade do pacote num Ubuntu nunca muda esta decisão.
        [ "$PLATAFORMA_ID" = pop ] \
            || falhar "Estratégia System76 recusada fora do Pop!_OS."
        apt-cache show system76-driver-nvidia >/dev/null 2>&1 \
            || falhar "O perfil Pop!_OS requer system76-driver-nvidia, mas o pacote não está disponível."
        PACOTE=system76-driver-nvidia
        info "Pop!_OS detectado: usando o meta-pacote oficial System76."
        ;;
    ubuntu-drivers)
        [ "$PLATAFORMA_ID" = ubuntu ] \
            || falhar "Estratégia ubuntu-drivers recusada fora do Ubuntu."
        if ! command -v ubuntu-drivers >/dev/null 2>&1; then
            info "Instalando ubuntu-drivers-common para consultar a recomendação oficial do Ubuntu."
            sudo apt install -y ubuntu-drivers-common
        fi
        PACOTE="$(LC_ALL=C ubuntu-drivers devices 2>/dev/null | awk '
            /^[[:space:]]*driver[[:space:]]*:/ && /recommended/ {
                for (i = 1; i <= NF; i++) if ($i == ":" && (i + 1) <= NF) { print $(i + 1); exit }
            }
        ')"
        [ -n "$PACOTE" ] && apt-cache show "$PACOTE" >/dev/null 2>&1 \
            || falhar "Nenhum driver NVIDIA recomendado foi informado por ubuntu-drivers. Revise repositórios e hardware."
        info "Ubuntu detectado; driver recomendado por ubuntu-drivers: $PACOTE"
        ;;
    *) falhar "Estratégia NVIDIA desconhecida no perfil: $PLATAFORMA_NVIDIA_ESTRATEGIA" ;;
esac

echo
info "Instalando: $PACOTE"
if ! sudo apt install -y "$PACOTE"; then
    erro "A instalação falhou."
    [ "$PLATAFORMA_NVIDIA_ESTRATEGIA" != ubuntu-drivers ] \
        || info "Após corrigir repositórios, a alternativa oficial é: sudo ubuntu-drivers install"
    falhar "Driver não instalado; sem ele o passthrough dinâmico (etapa 14) não funciona."
fi

echo
ok "Instalação concluída."
aviso "O driver só carrega a partir de um boot limpo (substituindo o nouveau)."
info "Após o reboot, valide com: nvidia-smi  e  lspci -nnk | grep -A3 -i vga"
pedir_reboot
