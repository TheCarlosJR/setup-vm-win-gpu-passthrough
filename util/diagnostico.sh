#!/bin/bash
# ============================================================================
# util/diagnostico.sh - coleta diagnóstica parcial do host e da VM
# ============================================================================
# Reúne sinais do libvirt, IOMMU, módulos, GPU, memória, montagens e journals
# em um relatório datado. Não corrige falhas nem certifica que o host está
# saudável. Falhas de comandos individuais são mantidas no relatório sempre
# que possível para não interromper a coleta.
# ============================================================================
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf
guard_mutation diagnostic.write || exit 1
exigir_nao_root
exigir_sudo

mkdir -p "$HOME/inventario-hardware"
ARQUIVO="$HOME/inventario-hardware/diagnostico-$(date +%Y%m%d-%H%M).txt"

titulo "Diagnóstico parcial do host e da VM"
info "Finalidade: reunir evidências locais para investigar VM, IOMMU, GPU, memória, montagens e serviços."
info "Pré-requisitos: usuário comum com sudo; virsh, lspci e nvidia-smi enriquecem a coleta, mas ausências são registradas."
aviso "Efeito/risco: grava $ARQUIVO e inclui cmdline, nomes/caminhos, dispositivos e logs potencialmente sensíveis."
aviso "Uma segunda execução no mesmo minuto usa o mesmo nome; permissões do arquivo dependem do umask."
info "Recomendação: mantenha o relatório local e revise-o integralmente antes de compartilhar."
info "Não abrange: firmware/BIOS, XML/NVRAM/TPM completos, estado interno do Windows nem teste de restauração."
info "Retorno/reboot: chegar ao fim não aprova a configuração; falhas pontuais podem constar no texto. Nenhum reboot é feito."

secao() { echo; echo "== $* =="; }

# Executa o comando e preserva sua saída; se ele falhar sem saída ou não
# encontrar nada, registra uma indicação no relatório.
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
    if [ -n "${WORKING_DISK_PATH:-}" ]; then
        echo "workingDisk configurado: $WORKING_DISK_PATH"
        coletar findmnt -rn --raw --mountpoint "$WORKING_DISK_PATH" \
            --output TARGET,SOURCE,FSTYPE,OPTIONS
    elif [ "${WORKING_DISK_DISPENSADO:-}" = "sim" ]; then
        echo "workingDisk dispensado explicitamente"
    else
        echo "workingDisk ainda não configurado nem dispensado"
    fi
    coletar bash -c 'mount | grep -E "airlock|/vm"'

    secao "Logs recentes do libvirtd"
    coletar sudo journalctl -u libvirtd -e -n 50 --no-pager

    secao "Hooks (journal)"
    coletar sudo journalctl -t hook-qemu -b --no-pager

    secao "AppArmor (negações)"
    coletar sudo bash -c 'journalctl -b --no-pager 2>/dev/null | grep -i apparmor | grep -i denied | tail -n 20'
} | tee "$ARQUIVO"

echo
info "Destino solicitado para o relatório: $ARQUIVO (confirme que o arquivo foi gravado e está legível)."
aviso "Antes de compartilhar, faça ao menos esta triagem local; ela não detecta todo dado sensível:"
printf '  less %q\n' "$ARQUIVO"
printf "  grep -nEi 'senha|password|token|secret|chave|private|key|IP|MAC|UUID|serial|/home/' %q\n" "$ARQUIVO"
info "Leia também o contexto das ocorrências e remova/redija somente na cópia que será compartilhada."
