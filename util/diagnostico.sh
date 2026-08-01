#!/bin/bash
# ============================================================================
# util/diagnostico.sh - Capítulo 28: bloco de diagnóstico geral
# ============================================================================
# Primeiro passo diante de QUALQUER problema: coleta o estado de todas as
# camadas (VM, IOMMU, módulos, driver da GPU, libvirtd, AppArmor) e salva
# um relatório datado em ~/inventario-hardware/.
# Metodologia do manual: diagnosticar de baixo (firmware) para cima (guest).
#
# SEM "set -e" de propósito: um diagnóstico precisa terminar o relatório mesmo
# quando comandos falham ou não encontram nada. É justamente o caso em que a
# informação "está vazio" é a pista mais importante.
# ============================================================================
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf
exigir_nao_root
exigir_sudo

mkdir -p "$HOME/inventario-hardware"
ARQUIVO="$HOME/inventario-hardware/diagnostico-$(date +%Y%m%d-%H%M).txt"

secao() { echo; echo "== $* =="; }

# roda "comando..." e, se falhar ou não imprimir nada, registra o motivo
coletar() {
    local saida status
    saida="$("$@" 2>&1)"
    status=$?
    if [ -n "$saida" ]; then
        echo "$saida"
    elif [ "$status" -ne 0 ]; then
        echo "(comando falhou: $* )"
    else
        echo "(sem resultados)"
    fi
}

exige() {
    # exige comando -> 0 se existe; senão registra a ausência
    if command -v "$1" >/dev/null 2>&1; then
        return 0
    fi
    echo "(comando '$1' não instalado neste host)"
    return 1
}

{
    echo "Diagnóstico gerado em $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Host: $(uname -srm)  |  VM configurada: ${VM_NAME:-(nenhuma no conf)}"

    secao "Estado da VM"
    if exige virsh; then
        coletar virsh --connect qemu:///system list --all
    fi

    secao "IOMMU (dmesg)"
    coletar sudo bash -c 'dmesg | grep -i -e "AMD-Vi" -e "DMAR" -e "IOMMU" | tail -n 20'

    secao "/proc/cmdline"
    coletar cat /proc/cmdline

    secao "Módulos vfio/nvidia"
    coletar bash -c 'lsmod | grep -e vfio -e nvidia'

    secao "Driver atual da GPU"
    if exige lspci; then
        coletar bash -c 'lspci -nnk | grep -A3 -iE "vga|3d controller"'
    fi

    secao "Driver NVIDIA (nvidia-smi)"
    if exige nvidia-smi; then
        coletar nvidia-smi
    fi

    secao "HugePages"
    coletar grep Huge /proc/meminfo

    secao "Memória"
    coletar free -h

    secao "CPUs isoladas"
    coletar cat /sys/devices/system/cpu/isolated

    secao "Grupos IOMMU"
    coletar bash "$PROJETO_DIR/util/listar-grupos-iommu.sh"

    secao "Montagens relevantes"
    coletar bash -c 'mount | grep -E "docs4|airlock|/vm"'

    secao "Logs recentes do libvirtd"
    coletar sudo journalctl -u libvirtd -e -n 50 --no-pager

    secao "Hooks (journal)"
    coletar sudo journalctl -t hook-qemu -b --no-pager

    secao "AppArmor (negações)"
    coletar sudo bash -c 'journalctl -b --no-pager 2>/dev/null | grep -i apparmor | grep -i denied | tail -n 20'
} | tee "$ARQUIVO"

echo
ok "Relatório salvo em: $ARQUIVO"
info "Interprete com o Capítulo 28 (Code 43, reset bug, grupo IOMMU, AppArmor...)."
