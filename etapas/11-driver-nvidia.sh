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
    if plataforma_carregar; then
        v_ok "Estratégia NVIDIA do perfil $PLATAFORMA_PERFIL: $PLATAFORMA_NVIDIA_ESTRATEGIA."
    else
        v_erro "$PLATAFORMA_ERRO"
    fi
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
        v_ok "nvidia-smi funcional: $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -n1)"
    else
        v_falta "nvidia-smi ausente ou sem GPU (driver não instalado/carregado)."
    fi
    if lspci -nnk 2>/dev/null | grep -A3 -i 'vga' | grep -q 'Kernel driver in use: nvidia'; then
        v_ok "GPU vinculada ao driver 'nvidia'."
    else
        v_falta "GPU não está com o driver 'nvidia' em uso."
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

if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    ok "nvidia-smi já funciona: nenhum pacote será alterado e não é necessário reiniciar."
    nvidia-smi
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
