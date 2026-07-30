#!/bin/bash
# ============================================================================
# etapas/53-cpu-isolation.sh - Capítulo 22: CPU Isolation (isolcpus)
# ============================================================================
# Remove os núcleos da VM do escalonador geral do host (isolcpus, nohz_full,
# rcu_nocbs). A parte de MSI é feita DENTRO do Windows: use o script
# windows/Ativar-MSI-GPU.ps1 (gerado por este projeto).
#
# ATENÇÃO: erro na lista de CPUs pode inutilizar o boot (Capítulo 29,
# cenário 2). O script valida a lista antes de aplicar.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

verificar() {
    local isolados
    isolados="$(cat /sys/devices/system/cpu/isolated 2>/dev/null || true)"
    if [ -n "$isolados" ]; then
        v_ok "CPUs isoladas: $isolados"
        if [ -n "${CPUS_VM:-}" ]; then
            local esperado atual
            esperado="$(expandir_lista_cpus "$CPUS_VM" | sort -n | tr '\n' ',')"
            atual="$(expandir_lista_cpus "$isolados" | sort -n | tr '\n' ',')"
            if [ "$esperado" = "$atual" ]; then
                v_ok "Lista isolada corresponde exatamente a CPUS_VM."
            else
                v_falta "Lista isolada difere de CPUS_VM ($CPUS_VM)."
            fi
        fi
    else
        v_falta "Nenhuma CPU isolada (isolcpus não aplicado)."
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

exigir_nao_root
exigir_sudo
exigir_conf CPUS_VM CPUS_HOST BOOTLOADER

titulo "Capítulo 22: CPU isolation"

# Validações de segurança antes de tocar no kernel
TOTAL_CPUS="$(nproc --all)"
QTD_VM="$(expandir_lista_cpus "$CPUS_VM" | wc -l)"
QTD_HOST="$(expandir_lista_cpus "$CPUS_HOST" | wc -l)"
info "CPUs lógicas: total=$TOTAL_CPUS  VM=$QTD_VM  host=$QTD_HOST"

[ "$QTD_HOST" -ge 2 ] || falhar "CPUS_HOST tem menos de 2 threads; isso deixaria o host inutilizável."
if [ $((QTD_VM + QTD_HOST)) -ne "$TOTAL_CPUS" ]; then
    aviso "VM+host ($((QTD_VM+QTD_HOST))) difere do total ($TOTAL_CPUS); confira o passthrough.conf."
fi
for CPU in $(expandir_lista_cpus "$CPUS_VM"); do
    for CPU_H in $(expandir_lista_cpus "$CPUS_HOST"); do
        [ "$CPU" = "$CPU_H" ] && falhar "CPU $CPU aparece nas duas listas (VM e host). Abortado."
    done
done
ok "Listas validadas (sem sobreposição, host preservado)."

PARAMS="isolcpus=$CPUS_VM nohz_full=$CPUS_VM rcu_nocbs=$CPUS_VM"
if cmdline_tem "isolcpus=$CPUS_VM"; then
    ok "isolcpus já ativo no kernel em execução."
    info "CPUs isoladas agora: $(cat /sys/devices/system/cpu/isolated)"
    info "Com a VM ligada, confira: ps -eo pid,psr,comm | grep qemu"
else
    echo
    aviso "Efeito colateral (manual): os núcleos isolados deixam de receber processos"
    aviso "comuns do host MESMO com a VM desligada. Dimensione com cuidado."
    confirmar "Aplicar '$PARAMS' via $BOOTLOADER?" || falhar "Cancelado."
    kernel_param_add "$PARAMS"
    echo
    info "Reversão em caso de problema no boot (Capítulo 29, cenário 2):"
    if [ "$BOOTLOADER" = "kernelstub" ]; then
        info "  sudo kernelstub -d \"$PARAMS\""
    else
        info "  restaurar /etc/default/grub.bak-<data> + sudo update-grub"
    fi
    pedir_reboot
fi

echo
titulo "Parte no Windows (MSI)"
info "Dentro da VM, execute como administrador: windows/Ativar-MSI-GPU.ps1"
info "(força MSISupported=1 para a GPU NVIDIA no registro e reduz stuttering)."
