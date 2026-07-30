#!/bin/bash
# ============================================================================
# etapas/52-cpu-pinning-hugepages.sh - Capítulo 21: CPU Pinning, NUMA e
#                                      HugePages
# ============================================================================
# Fase A (XML): <vcpu cpuset>, <cputune> (vcpupin + emulatorpin), topologia
#   <cpu> (sockets/dies/cores/threads) e <memoryBacking><hugepages/>.
# Fase B (kernel): reserva de HugePages de 1 GiB no boot + reboot.
# Os mapas de CPU vêm do passthrough.conf (detectados na etapa 02 a partir
# do lscpu -e REAL, nunca presumidos).
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

param_hugepages() { echo "default_hugepagesz=1G hugepagesz=1G hugepages=${HUGEPAGES_1G}"; }

verificar() {
    [ -n "${VM_NAME:-}" ] || { v_falta "VM_NAME não definido."; v_fim; }
    if vm_existe "$VM_NAME"; then
        local xml
        xml="$($VIRSH dumpxml --inactive "$VM_NAME" 2>/dev/null)"
        grep -q "<vcpupin" <<< "$xml" && v_ok "vcpupin presente no XML." || v_falta "vcpupin ausente."
        grep -q "<topology" <<< "$xml" && v_ok "topologia de CPU definida." || v_falta "topologia ausente."
        grep -q "<hugepages/>" <<< "$xml" && v_ok "memoryBacking/hugepages no XML." || v_falta "memoryBacking ausente."
    else
        v_falta "VM não existe."
    fi
    local total
    total="$(awk '/HugePages_Total/{print $2}' /proc/meminfo)"
    if [ "${total:-0}" -ge "${HUGEPAGES_1G:-16}" ] 2>/dev/null; then
        v_ok "HugePages reservadas: $total"
    else
        v_falta "HugePages_Total=$total (esperado ${HUGEPAGES_1G:-16})."
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

exigir_nao_root
exigir_sudo
exigir_comando xmlstarlet virsh
exigir_conf VM_NAME CPUS_VM CPUS_HOST VM_CORES VM_THREADS VM_VCPUS VM_RAM_MB HUGEPAGES_1G BOOTLOADER

titulo "Capítulo 21: CPU pinning e HugePages (VM: $VM_NAME)"
info "NUMA: $(lscpu | grep -i 'NUMA node(s)' | awk -F: '{gsub(/ /,"",$2); print $2}') nó(s) (esperado 1 no Ryzen 5700X)."
info "Mapa: VM=[$CPUS_VM] ($VM_CORES núcleos x $VM_THREADS threads)  HOST=[$CPUS_HOST]"

# ----------------------------------------------------------------------------
# Fase A: XML da VM
# ----------------------------------------------------------------------------
titulo "Fase A: pinning e topologia no XML"
exigir_vm_desligada "$VM_NAME"
xml_backup "$VM_NAME"

TMPX="$(mktemp)"
$VIRSH dumpxml --inactive "$VM_NAME" > "$TMPX"

# <vcpu placement='static' cpuset='...'>N</vcpu>
xmlstarlet ed -L -u '/domain/vcpu' -v "$VM_VCPUS" "$TMPX"
xmlstarlet ed -L -d '/domain/vcpu/@placement' -d '/domain/vcpu/@cpuset' "$TMPX"
xmlstarlet ed -L -i '/domain/vcpu' -t attr -n placement -v static "$TMPX"
xmlstarlet ed -L -i '/domain/vcpu' -t attr -n cpuset -v "$CPUS_VM" "$TMPX"

# <cputune> com um vcpupin por vCPU (ordem exata do CPUS_VM) + emulatorpin
xmlstarlet ed -L -d '/domain/cputune' "$TMPX"
xmlstarlet ed -L -s '/domain' -t elem -n cputune -v '' "$TMPX"
VCPU_N=0
IFS=',' read -ra LISTA_VM <<< "$CPUS_VM"
for CPU_FISICA in "${LISTA_VM[@]}"; do
    xmlstarlet ed -L -s '/domain/cputune' -t elem -n vcpupin -v '' "$TMPX"
    xmlstarlet ed -L -i '/domain/cputune/vcpupin[last()]' -t attr -n vcpu -v "$VCPU_N" "$TMPX"
    xmlstarlet ed -L -i '/domain/cputune/vcpupin[last()]' -t attr -n cpuset -v "$CPU_FISICA" "$TMPX"
    VCPU_N=$((VCPU_N+1))
done
xmlstarlet ed -L -s '/domain/cputune' -t elem -n emulatorpin -v '' "$TMPX"
xmlstarlet ed -L -i '/domain/cputune/emulatorpin' -t attr -n cpuset -v "$CPUS_HOST" "$TMPX"

# <cpu mode='host-passthrough' ...> + <topology .../>
if ! xmlstarlet sel -t -c '/domain/cpu' "$TMPX" >/dev/null 2>&1; then
    xmlstarlet ed -L -s '/domain' -t elem -n cpu -v '' "$TMPX"
fi
xmlstarlet ed -L -d '/domain/cpu/@mode' "$TMPX"
xmlstarlet ed -L -i '/domain/cpu' -t attr -n mode -v host-passthrough "$TMPX"
xmlstarlet ed -L -d '/domain/cpu/@check' "$TMPX"
xmlstarlet ed -L -i '/domain/cpu' -t attr -n check -v none "$TMPX"
xmlstarlet ed -L -d '/domain/cpu/@migratable' "$TMPX"
xmlstarlet ed -L -i '/domain/cpu' -t attr -n migratable -v off "$TMPX"
xmlstarlet ed -L -d '/domain/cpu/topology' "$TMPX"
xmlstarlet ed -L -s '/domain/cpu' -t elem -n topology -v '' "$TMPX"
xmlstarlet ed -L -i '/domain/cpu/topology' -t attr -n sockets -v 1 "$TMPX"
xmlstarlet ed -L -i '/domain/cpu/topology' -t attr -n dies -v 1 "$TMPX"
xmlstarlet ed -L -i '/domain/cpu/topology' -t attr -n cores -v "$VM_CORES" "$TMPX"
xmlstarlet ed -L -i '/domain/cpu/topology' -t attr -n threads -v "$VM_THREADS" "$TMPX"

# <memoryBacking><hugepages/></memoryBacking>
if ! xmlstarlet sel -t -c '/domain/memoryBacking' "$TMPX" >/dev/null 2>&1; then
    xmlstarlet ed -L -s '/domain' -t elem -n memoryBacking -v '' "$TMPX"
fi
if ! xmlstarlet sel -t -c '/domain/memoryBacking/hugepages' "$TMPX" >/dev/null 2>&1; then
    xmlstarlet ed -L -s '/domain/memoryBacking' -t elem -n hugepages -v '' "$TMPX"
fi

$VIRSH define "$TMPX" >/dev/null
rm -f "$TMPX"
ok "XML atualizado: $VM_VCPUS vCPUs pinadas, emulatorpin em [$CPUS_HOST], topologia ${VM_CORES}c/${VM_THREADS}t, hugepages."

# ----------------------------------------------------------------------------
# Fase B: reserva de HugePages de 1 GiB no boot
# ----------------------------------------------------------------------------
titulo "Fase B: HugePages de 1 GiB"
if [ $((VM_RAM_MB % 1024)) -ne 0 ]; then
    falhar "VM_RAM_MB=$VM_RAM_MB não é múltiplo de 1024; ajuste no passthrough.conf."
fi
if ! grep -qi pdpe1gb /proc/cpuinfo; then
    aviso "CPU sem flag pdpe1gb (HugePages de 1 GiB indisponíveis)."
    falhar "Ajuste manual necessário (páginas de 2 MiB); o Ryzen 7 5700X do manual suporta 1 GiB."
fi

if cmdline_tem "hugepages=${HUGEPAGES_1G}" && cmdline_tem "hugepagesz=1G"; then
    ok "Parâmetros de HugePages já ativos no kernel."
    TOTAL="$(awk '/HugePages_Total/{print $2}' /proc/meminfo)"
    TAM="$(awk '/Hugepagesize/{print $2}' /proc/meminfo)"
    info "HugePages_Total=$TOTAL  Hugepagesize=${TAM} kB"
    if [ "${TOTAL:-0}" -ge "$HUGEPAGES_1G" ]; then
        ok "Reserva completa. Etapa 52 concluída: inicie a VM e confira 'virsh vcpuinfo $VM_NAME'."
    else
        aviso "Reserva incompleta (memória fragmentada?). Reinicie novamente logo após o boot."
    fi
else
    aviso "Reservar ${HUGEPAGES_1G} GiB retira essa RAM do uso geral do host MESMO com a VM desligada."
    confirmar "Aplicar '$(param_hugepages)' via $BOOTLOADER?" || falhar "Cancelado."
    kernel_param_add "$(param_hugepages)"
    info "Reversão: remover os mesmos parâmetros ($BOOTLOADER -d / restaurar grub backup)."
    pedir_reboot
fi
