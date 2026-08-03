#!/bin/bash
# ============================================================================
# etapas/11-driver-nvidia.sh - Capítulo 8: Drivers NVIDIA no Host
# ============================================================================
# Garante o driver proprietário NVIDIA funcionando no Pop!_OS. Este é o
# estado "de repouso" da GPU: ela volta para este driver sempre que a VM
# desliga (hooks da etapa 50).
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

verificar() {
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

exigir_nao_root

titulo "Antes de continuar"
info "Finalidade: manter a GPU no driver proprietário NVIDIA enquanto a VM estiver desligada."
info "Pré-requisitos: etapa 10 concluída, GPU NVIDIA presente, rede/repositórios funcionais e sudo."
info "Alterações: se nvidia-smi já funciona, nenhuma; caso contrário, o APT é atualizado e pacotes NVIDIA são instalados."
info "Recomendação: mantenha acesso a TTY ou mídia de recuperação e não interrompa a instalação."
aviso "Risco principal: um driver incompatível pode impedir a sessão gráfica no próximo boot."
info "Reboot/retorno: com nvidia-smi funcional, sai sem alteração nem reboot; após instalar, reinicie, valide nvidia-smi e retorne ao menu."

exigir_sudo

titulo "Capítulo 8: Driver NVIDIA no host"

if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    ok "nvidia-smi já funciona: nenhum pacote será alterado e não é necessário reiniciar."
    nvidia-smi
    exit 0
fi

info "nvidia-smi ausente ou não funcional. Consultando os repositórios..."
sudo apt update

# Usa uma única estratégia: o meta-pacote do Pop!_OS tem precedência. Em
# Ubuntu, instala somente o driver que ubuntu-drivers marcar como recomendado.
PACOTE=""
if apt-cache show system76-driver-nvidia >/dev/null 2>&1; then
    PACOTE="system76-driver-nvidia"
    info "Pacote do Pop!_OS disponível: system76-driver-nvidia"
else
    command -v ubuntu-drivers >/dev/null 2>&1 \
        || falhar "'ubuntu-drivers' não está disponível e system76-driver-nvidia não existe nos repositórios. Instale ubuntu-drivers-common ou use a ferramenta recomendada pela sua distribuição."
    PACOTE="$(ubuntu-drivers devices 2>/dev/null | awk '/driver[[:space:]]*:/ && /recommended/ {print $3; exit}')"
    [ -n "$PACOTE" ] && apt-cache show "$PACOTE" >/dev/null 2>&1 \
        || falhar "Nenhum driver NVIDIA recomendado foi informado por ubuntu-drivers. Revise os repositórios e o hardware antes de continuar."
    info "Driver recomendado por ubuntu-drivers: $PACOTE"
fi

echo
info "Instalando: $PACOTE"
if ! sudo apt install -y "$PACOTE"; then
    erro "A instalação falhou."
    info "Tente: sudo ubuntu-drivers install"
    falhar "Driver não instalado; sem ele o passthrough dinâmico (etapa 50) não funciona."
fi

echo
ok "Instalação concluída."
aviso "O driver só carrega a partir de um boot limpo (substituindo o nouveau)."
info "Após o reboot, valide com: nvidia-smi  e  lspci -nnk | grep -A3 -i vga"
pedir_reboot
