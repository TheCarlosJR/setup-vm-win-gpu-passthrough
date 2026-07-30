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
exigir_sudo

titulo "Capítulo 8: Driver NVIDIA no host"

if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    ok "Driver NVIDIA já instalado e funcional (caso da ISO Pop!_OS com NVIDIA integrado):"
    nvidia-smi
    exit 0
fi

info "Driver não encontrado. Versões disponíveis nos repositórios:"
sudo apt update
apt list --all-versions 2>/dev/null | grep -i '^nvidia-driver' || true

echo
info "Instalando o meta-pacote do Pop!_OS (system76-driver-nvidia + nvidia-driver)..."
sudo apt install -y system76-driver-nvidia nvidia-driver

echo
ok "Instalação concluída."
aviso "O driver só carrega a partir de um boot limpo (substituindo o nouveau)."
info "Após o reboot, valide com: nvidia-smi  e  lspci -nnk | grep -A3 -i vga"
pedir_reboot
