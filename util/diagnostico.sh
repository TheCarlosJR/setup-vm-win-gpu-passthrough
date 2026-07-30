#!/bin/bash
# ============================================================================
# util/diagnostico.sh - Capítulo 28: bloco de diagnóstico geral
# ============================================================================
# Primeiro passo diante de QUALQUER problema: coleta o estado de todas as
# camadas (VM, IOMMU, módulos, driver da GPU, libvirtd, AppArmor) e salva
# um relatório datado em ~/inventario-hardware/.
# Metodologia do manual: diagnosticar de baixo (firmware) para cima (guest).
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf
exigir_nao_root
exigir_sudo

mkdir -p "$HOME/inventario-hardware"
ARQUIVO="$HOME/inventario-hardware/diagnostico-$(date +%Y%m%d-%H%M).txt"

{
    echo "== Estado da VM ==";        virsh --connect qemu:///system list --all 2>&1
    echo "== IOMMU ==";               sudo dmesg | grep -i -e "AMD-Vi" -e "IOMMU" | tail -n 20
    echo "== /proc/cmdline ==";       cat /proc/cmdline
    echo "== Módulos vfio/nvidia =="; lsmod | grep -e vfio -e nvidia || echo "(nenhum)"
    echo "== Driver atual da GPU =="; lspci -nnk | grep -A3 -i vga
    echo "== HugePages ==";           grep Huge /proc/meminfo
    echo "== CPUs isoladas ==";       cat /sys/devices/system/cpu/isolated 2>/dev/null || echo "(nenhuma)"
    echo "== Logs recentes do libvirtd =="; sudo journalctl -u libvirtd -e -n 50 --no-pager 2>&1
    echo "== AppArmor (DENIED) ==";   sudo journalctl -xe --no-pager 2>/dev/null | grep -i apparmor | grep -i denied | tail -n 20 || echo "(nenhuma negação)"
    echo "== Hooks ==";               sudo journalctl -t hook-qemu -b --no-pager 2>&1 | tail -n 20 || true
} | tee "$ARQUIVO"

echo
ok "Relatório salvo em: $ARQUIVO"
info "Interprete com o Capítulo 28 (Code 43, reset bug, grupo IOMMU, AppArmor...)."
