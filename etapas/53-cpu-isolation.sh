#!/bin/bash
# ============================================================================
# etapas/53-cpu-isolation.sh - isolamento opcional de CPUs da VM
# ============================================================================
# Aplica isolcpus, nohz_full e rcu_nocbs somente depois de provar que a VM está
# pinada exatamente em CPUS_VM e que VM/host formam uma partição de cores
# físicos completos. As três chaves são sempre tratadas juntas e por nome.
# Reversão: --desfazer.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

CHAVES_ISOLAMENTO="isolcpus nohz_full rcu_nocbs"
ISOLAMENTO_ERRO=""
TOPOLOGIA_CPU=""

param_isolamento() {
    printf 'isolcpus=%s nohz_full=%s rcu_nocbs=%s\n' "$CPUS_VM" "$CPUS_VM" "$CPUS_VM"
}

SUPORTE_ISOLAMENTO_ERRO=""
validar_suporte_isolamento() {
    local cpu config=""
    SUPORTE_ISOLAMENTO_ERRO=""
    while IFS= read -r cpu; do
        [ "$cpu" -ne 0 ] \
            || { SUPORTE_ISOLAMENTO_ERRO="A CPU 0 e seu core de housekeeping precisam ficar em CPUS_HOST; redetecte o mapa na etapa 02."; return 1; }
    done < <(expandir_lista_cpus "$CPUS_VM")
    [ -r /sys/devices/system/cpu/nohz_full ] \
        || { SUPORTE_ISOLAMENTO_ERRO="O kernel não expõe /sys/devices/system/cpu/nohz_full."; return 1; }
    if [ -r /proc/config.gz ] && command -v gzip >/dev/null 2>&1; then
        config="$(gzip -cd /proc/config.gz 2>/dev/null)" \
            || { SUPORTE_ISOLAMENTO_ERRO="Não foi possível ler /proc/config.gz."; return 1; }
    elif [ -r "/boot/config-$(uname -r)" ]; then
        config="$(< "/boot/config-$(uname -r)")" \
            || { SUPORTE_ISOLAMENTO_ERRO="Não foi possível ler a configuração do kernel atual."; return 1; }
    else
        SUPORTE_ISOLAMENTO_ERRO="A configuração do kernel atual não está legível; não é possível provar NO_HZ_FULL/RCU_NOCB_CPU."
        return 1
    fi
    grep -qx 'CONFIG_NO_HZ_FULL=y' <<< "$config" \
        || { SUPORTE_ISOLAMENTO_ERRO="O kernel atual não possui CONFIG_NO_HZ_FULL=y."; return 1; }
    grep -qx 'CONFIG_RCU_NOCB_CPU=y' <<< "$config" \
        || { SUPORTE_ISOLAMENTO_ERRO="O kernel atual não possui CONFIG_RCU_NOCB_CPU=y."; return 1; }
}

isolamento_efetivo_exato() {
    local isolados nohz esperado atual
    ISOLAMENTO_ERRO=""
    [ -r /sys/devices/system/cpu/isolated ] \
        || { ISOLAMENTO_ERRO="/sys/devices/system/cpu/isolated não é legível."; return 1; }
    IFS= read -r isolados < /sys/devices/system/cpu/isolated || true
    [ -n "$isolados" ] \
        || { ISOLAMENTO_ERRO="O kernel não reporta CPUs isoladas."; return 1; }
    esperado="$(normalizar_conjunto_cpus "$CPUS_VM")" \
        || { ISOLAMENTO_ERRO="CPUS_VM não pode ser normalizado."; return 1; }
    atual="$(normalizar_conjunto_cpus "$isolados")" \
        || { ISOLAMENTO_ERRO="A lista efetiva de CPUs isoladas é inválida: '$isolados'."; return 1; }
    [ "$atual" = "$esperado" ] \
        || { ISOLAMENTO_ERRO="CPUs isoladas efetivas=[$isolados], esperado CPUS_VM=[$CPUS_VM]."; return 1; }

    [ -r /sys/devices/system/cpu/nohz_full ] \
        || { ISOLAMENTO_ERRO="/sys/devices/system/cpu/nohz_full não é legível."; return 1; }
    IFS= read -r nohz < /sys/devices/system/cpu/nohz_full || true
    nohz="${nohz#"${nohz%%[![:space:]]*}"}"
    nohz="${nohz%"${nohz##*[![:space:]]}"}"
    [ -n "$nohz" ] \
        || { ISOLAMENTO_ERRO="nohz_full é exposto pelo kernel, mas está vazio."; return 1; }
    atual="$(normalizar_conjunto_cpus "$nohz")" \
        || { ISOLAMENTO_ERRO="A lista efetiva nohz_full é inválida: '$nohz'."; return 1; }
    [ "$atual" = "$esperado" ] \
        || { ISOLAMENTO_ERRO="nohz_full efetivo=[$nohz], esperado CPUS_VM=[$CPUS_VM]."; return 1; }
}

validar_layout_configurado() {
    TOPOLOGIA_CPU="$(cpu_topologia_csv)" \
        || { CPU_LAYOUT_ERRO="lscpu não forneceu a topologia parseável."; return 1; }
    validar_layout_cpu "$CPUS_VM" "$CPUS_HOST" "$VM_VCPUS" "$VM_CORES" "$VM_THREADS" "$TOPOLOGIA_CPU"
}

validar_pinning_vm() {
    local tmp
    vm_existe "$VM_NAME" || { XML_CPU_ERRO="A VM '$VM_NAME' não existe."; return 1; }
    tmp="$(mktemp)" || { XML_CPU_ERRO="Não foi possível criar temporário para o XML."; return 1; }
    if ! $VIRSH dumpxml --inactive "$VM_NAME" > "$tmp"; then
        rm -f -- "$tmp"
        XML_CPU_ERRO="Não foi possível ler o XML inativo da VM."
        return 1
    fi
    if ! virt-xml-validate "$tmp" domain >/dev/null 2>&1; then
        rm -f -- "$tmp"
        XML_CPU_ERRO="O XML inativo não passa no schema libvirt."
        return 1
    fi
    if ! validar_xml_cpu_pinning "$tmp" "$CPUS_VM" "$CPUS_HOST" \
        "$VM_VCPUS" "$VM_CORES" "$VM_THREADS" "$VM_RAM_MB" ignorar; then
        rm -f -- "$tmp"
        return 1
    fi
    rm -f -- "$tmp"
}

verificar() {
    local var faltando=0 params=""
    for var in VM_NAME CPUS_VM CPUS_HOST VM_VCPUS VM_CORES VM_THREADS VM_RAM_MB BOOTLOADER; do
        if [ -n "${!var:-}" ]; then
            v_ok "$var=${!var}"
        else
            v_falta "$var ausente."
            faltando=1
        fi
    done
    if [ "$faltando" -eq 0 ]; then
        params="$(param_isolamento)"
        if validar_layout_configurado; then
            v_ok "VM e host cobrem exatamente as CPUs online por cores físicos completos."
        else
            v_falta "$CPU_LAYOUT_ERRO"
        fi
        if validar_suporte_isolamento; then
            v_ok "CPU 0 está no host e o kernel oferece NO_HZ_FULL/RCU_NOCB_CPU observáveis."
        else
            v_falta "$SUPORTE_ISOLAMENTO_ERRO"
        fi
        if command -v python3 >/dev/null 2>&1 \
           && command -v virsh >/dev/null 2>&1 \
           && command -v virt-xml-validate >/dev/null 2>&1 \
           && validar_pinning_vm; then
            v_ok "O XML inativo está pinado exatamente em CPUS_VM/CPUS_HOST."
        else
            v_falta "Pinning exato da VM não comprovado: ${XML_CPU_ERRO:-dependência indisponível}."
        fi
        if cmdline_parametros_exatos "$params"; then
            v_ok "isolcpus, nohz_full e rcu_nocbs estão ativos uma única vez e com valores exatos."
        else
            v_falta "Cmdline de isolamento divergente: $CMDLINE_PARAM_ERRO"
        fi
        if kernel_parametros_persistentes_exatos "$params"; then
            v_ok "Persistência das três chaves é exata e coerente."
        else
            v_falta "Persistência do isolamento não comprovada: $KERNEL_PERSISTENCIA_ERRO"
        fi
        if isolamento_efetivo_exato; then
            v_ok "isolcpus/nohz_full efetivos correspondem a CPUS_VM; rcu_nocbs foi validado na cmdline."
        else
            v_falta "$ISOLAMENTO_ERRO"
        fi
    fi
    v_fim
}

desfazer() {
    exigir_nao_root
    exigir_sudo
    exigir_conf BOOTLOADER
    titulo "Reverter isolamento opcional de CPU"
    if kernel_param_chaves_persistentes_ausentes "$CHAVES_ISOLAMENTO"; then
        ok "isolcpus, nohz_full e rcu_nocbs já estão ausentes da configuração de boot."
        if cmdline_possui_alguma_chave "$CHAVES_ISOLAMENTO"; then
            pedir_reboot
        else
            info "A reversão da etapa 53 já está completa."
        fi
        return 0
    fi
    aviso "A remoção de todas as ocorrências só terá efeito no kernel após reinicializar."
    confirmar "Remover isolcpus, nohz_full e rcu_nocbs por chave via $BOOTLOADER?" \
        || falhar "Cancelado sem alterações."
    kernel_param_del "$CHAVES_ISOLAMENTO"
    kernel_param_chaves_persistentes_ausentes "$CHAVES_ISOLAMENTO" \
        || falhar "A remoção persistente não pôde ser comprovada: $KERNEL_PERSISTENCIA_ERRO"
    pedir_reboot
}

main() {
    carregar_conf
    case "${1:-}" in
        --verificar) verificar ;;
        --desfazer) desfazer; return ;;
        "") ;;
        *) falhar "Uso: $0 [--verificar|--desfazer]" ;;
    esac

    exigir_nao_root
    exigir_sudo
    exigir_comando python3 virsh lscpu virt-xml-validate
    exigir_conf VM_NAME CPUS_VM CPUS_HOST VM_VCPUS VM_CORES VM_THREADS VM_RAM_MB BOOTLOADER
    exigir_vm_desligada "$VM_NAME"
    validar_layout_configurado || falhar "$CPU_LAYOUT_ERRO"
    validar_suporte_isolamento || falhar "$SUPORTE_ISOLAMENTO_ERRO"
    validar_pinning_vm || falhar "A etapa 53 só pode isolar CPUs já pinadas exatamente no XML: $XML_CPU_ERRO"

    local params
    params="$(param_isolamento)"
    titulo "Isolamento opcional de CPU"
    aviso "Otimização opcional: aplique somente após medir um baseline e comprovar gargalo de latência/CPU."
    info "A opção 3 da etapa 02 apenas registra o plano; a etapa 52 aplica o pinning, e esta etapa só isola CPUs já pinadas."
    info "Fase 1: gravar isolcpus/nohz_full/rcu_nocbs, reiniciar o host e executar esta etapa novamente."
    info "Fase 2: comprovar o isolamento; não exige novo reboot do host."
    info "CPUs online=[$CPU_LAYOUT_ONLINE] VM=[$CPUS_VM] HOST=[$CPUS_HOST]"
    aviso "Com isolamento ativo, CPUS_VM deixa de atender processos comuns do host mesmo com a VM desligada."
    aviso "Na etapa 52, HugePages também podem manter RAM indisponível ao host com a VM desligada."

    if ! kernel_parametros_persistentes_exatos "$params"; then
        aviso "Persistência atual divergente/duplicada: ${KERNEL_PERSISTENCIA_ERRO:-estado não exato}."
        confirmar "Remover todas as ocorrências atuais de isolcpus, nohz_full e rcu_nocbs e gravar exatamente '$CPUS_VM' via $BOOTLOADER?" \
            || falhar "Cancelado sem alterações."
        kernel_param_add "$params"
        kernel_parametros_persistentes_exatos "$params" \
            || falhar "A persistência pós-alteração não é exata: $KERNEL_PERSISTENCIA_ERRO"
        pedir_reboot
        return 0
    fi

    if ! cmdline_parametros_exatos "$params"; then
        aviso "As três chaves persistentes já estão corretas, mas o kernel atual ainda não: $CMDLINE_PARAM_ERRO"
        pedir_reboot
        return 0
    fi
    isolamento_efetivo_exato \
        || falhar "A cmdline está presente, mas o efeito do kernel diverge: $ISOLAMENTO_ERRO"
    ok "Fase 2 concluída: isolcpus/nohz_full estão efetivos e exatos; rcu_nocbs está ativo e único na cmdline."
    info "Não há novo reboot do host nesta fase; --desfazer remove as três opções e exige reboot."
    info "Não há máscara RCU estável em todos os kernels; o suporte foi provado por CONFIG_RCU_NOCB_CPU=y."
    info "Reversão: bash etapas/53-cpu-isolation.sh --desfazer"

    echo
    titulo "Parte no Windows (MSI)"
    aviso "windows/Ativar-MSI-GPU.ps1 altera o Registro do Windows; salve o trabalho antes de executá-lo."
    info "Dentro da VM, execute o script como administrador e reinicie a VM para a alteração produzir efeito."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
