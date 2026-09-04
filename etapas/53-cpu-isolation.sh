#!/bin/bash
# ============================================================================
# etapas/53-cpu-isolation.sh - Etapa 18: isolamento opcional de CPUs da VM
# ============================================================================
# Aplica isolcpus, nohz_full e rcu_nocbs somente depois de provar que a VM está
# pinada exatamente em CPUS_VM e que VM/host formam uma partição de cores
# físicos completos. As três chaves são sempre tratadas juntas e por nome.
# Reversão: --desfazer.
# ============================================================================
SCRIPT_VERSION="1.0.0"
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

CHAVES_ISOLAMENTO="isolcpus nohz_full rcu_nocbs"
ISOLAMENTO_ERRO=""
TOPOLOGIA_CPU=""
TOPOLOGIA_FINGERPRINT=""

param_isolamento() {
    printf 'isolcpus=%s nohz_full=%s rcu_nocbs=%s\n' "$CPUS_VM" "$CPUS_VM" "$CPUS_VM"
}

SUPORTE_ISOLAMENTO_ERRO=""
validar_suporte_isolamento() {
    local cpu config=""
    SUPORTE_ISOLAMENTO_ERRO=""
    while IFS= read -r cpu; do
        [ "$cpu" -ne 0 ] \
            || { SUPORTE_ISOLAMENTO_ERRO="A CPU 0 e seu core de housekeeping precisam ficar em CPUS_HOST; redetecte o mapa na etapa 3."; return 1; }
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
    validar_layout_cpu "$CPUS_VM" "$CPUS_HOST" "$VM_VCPUS" "$VM_CORES" "$VM_THREADS" "$TOPOLOGIA_CPU" \
        || return 1
    TOPOLOGIA_FINGERPRINT="$CPU_LAYOUT_FINGERPRINT"
}

exigir_topologia_inalterada() {
    # Isolar CPUs a partir de um plano calculado sobre topologia obsoleta
    # retiraria do host CPUs que ele passou a precisar. Conflito bloqueia.
    local topologia
    [ -n "$TOPOLOGIA_FINGERPRINT" ] \
        || falhar "Fingerprint da topologia ausente; a validação inicial não foi executada."
    topologia="$(cpu_topologia_csv)" \
        || falhar "lscpu deixou de fornecer a topologia antes da mutação; nada foi alterado."
    cpu_topologia_fingerprint "$topologia" || falhar "$CPU_TOPOLOGIA_ERRO"
    [ "$CPU_TOPOLOGIA_FINGERPRINT" = "$TOPOLOGIA_FINGERPRINT" ] \
        || falhar "A topologia de CPU mudou desde a validação; nada foi alterado. Rode a etapa 3 e repita esta etapa."
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

# I9.9 (REQ-VERIFY-FAILCLOSED): validadores de uma variável para v_var_definida,
# com as mesmas faixas do schema canônico de configuração do core.
_v_inteiro_vm_vcpus()   { inteiro_na_faixa "${1:-}" 1 65535; }
_v_inteiro_vm_cores()   { inteiro_na_faixa "${1:-}" 1 65535; }
_v_inteiro_vm_threads() { inteiro_na_faixa "${1:-}" 1 65535; }
_v_inteiro_vm_ram_mb()  { inteiro_na_faixa "${1:-}" 1024 1048576; }
_v_bootloader_valido()  { case "${1:-}" in grub|kernelstub) return 0 ;; *) return 1 ;; esac; }

verificar() {
    local faltando=0 params="" vm_estado=0
    # `[ -n ]` aprovava qualquer literal, e o isolamento é escrito na cmdline a
    # partir de CPUS_VM: uma lista malformada aprovada aqui vira parâmetro de
    # boot inválido. Ausente é pendência; presente e fora do formato é erro.
    v_var_definida VM_NAME nome_vm_valido || faltando=1
    v_var_definida CPUS_VM lista_cpus_valida || faltando=1
    v_var_definida CPUS_HOST lista_cpus_valida || faltando=1
    v_var_definida VM_VCPUS _v_inteiro_vm_vcpus || faltando=1
    v_var_definida VM_CORES _v_inteiro_vm_cores || faltando=1
    v_var_definida VM_THREADS _v_inteiro_vm_threads || faltando=1
    v_var_definida VM_RAM_MB _v_inteiro_vm_ram_mb || faltando=1
    v_var_definida BOOTLOADER _v_bootloader_valido || faltando=1
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
        # A guarda de ferramenta virou uma chamada própria: antes, as três
        # ausências e a divergência real colapsavam na MESMA v_falta, com a
        # mensagem "dependência indisponível" servindo para os dois casos.
        if ! v_exigir_comando python3 virsh virt-xml-validate; then
            :
        else
            vm_existe_estado "$VM_NAME" || vm_estado=$?
            if [ "$vm_estado" -eq 1 ]; then
                v_falta "A VM '$VM_NAME' não existe."
            elif [ "$vm_estado" -ne 0 ]; then
                # `vm_existe` dizia "não existe" também com virsh mudo,
                # libvirtd fora do ar ou permissão negada.
                v_indeterminado "Estado da VM '$VM_NAME' não pôde ser observado: ${VM_EXISTE_MOTIVO:-sem diagnóstico}."
            elif validar_pinning_vm; then
                v_ok "O XML inativo está pinado exatamente em CPUS_VM/CPUS_HOST."
            else
                v_falta "Pinning exato da VM não comprovado: ${XML_CPU_ERRO:-sem diagnóstico}."
            fi
        fi
        # I9.12 (REQ-VM-RESOURCE-LIFECYCLE): a AUSÊNCIA de isolamento é o estado
        # correto do perfil retornável, e relatá-la como divergência empurrava o
        # operador para um custo permanente — a mesma inversão que a etapa 17
        # tinha com a reserva estática de HugePages. Quando o isolamento não
        # está aplicado, isto aqui é sucesso; quando está, o contrato antigo
        # vale integralmente e ganha o aviso de não ser retornável.
        if ! cmdline_possui_alguma_chave "$CHAVES_ISOLAMENTO"; then
            v_ok "Nenhuma CPU sai do scheduler no boot: o perfil é retornável e o pinning da etapa 17 devolve a CPU quando o QEMU termina."
            if ! kernel_param_chaves_persistentes_ausentes "$CHAVES_ISOLAMENTO" 2>/dev/null; then
                v_kernel_persistencia_falhou "Ausência persistente de isolamento não comprovada: ${KERNEL_PERSISTENCIA_ERRO:-não verificável}."
            fi
        else
            v_falta "Isolamento persistente aplicado: as CPUs de CPUS_VM não voltam ao host quando a VM para. É perfil opt-in de desempenho, fora da base retornável; use --desfazer para sair dele."
            if cmdline_parametros_exatos "$params"; then
                v_ok "Perfil opt-in: isolcpus, nohz_full e rcu_nocbs estão ativos uma única vez e com valores exatos."
            else
                v_falta "Cmdline de isolamento divergente: $CMDLINE_PARAM_ERRO"
            fi
            if kernel_parametros_persistentes_exatos "$params"; then
                v_ok "Perfil opt-in: persistência das três chaves é exata e coerente."
            else
                v_kernel_persistencia_falhou "Persistência do isolamento não comprovada: $KERNEL_PERSISTENCIA_ERRO"
            fi
            if isolamento_efetivo_exato; then
                v_ok "Perfil opt-in: isolcpus/nohz_full efetivos correspondem a CPUS_VM; rcu_nocbs foi validado na cmdline."
            else
                v_falta "$ISOLAMENTO_ERRO"
            fi
        fi
    fi
    v_fim
}

desfazer() {
    exigir_nao_root
    exigir_conf BOOTLOADER
    exigir_bootloader_coerente
    exigir_sudo
    titulo "Etapa 18: reverter isolamento opcional de CPU"
    if kernel_param_chaves_persistentes_ausentes "$CHAVES_ISOLAMENTO"; then
        ok "isolcpus, nohz_full e rcu_nocbs já estão ausentes da configuração de boot."
        if cmdline_possui_alguma_chave "$CHAVES_ISOLAMENTO"; then
            pedir_reboot
        else
            info "A reversão da etapa 18 já está completa."
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
        --desfazer)
            guard_mutation cpu.tune || return 1
            desfazer
            return
            ;;
        "") guard_mutation cpu.tune || return 1 ;;
        *) falhar "Uso: $0 [--verificar|--desfazer]" ;;
    esac

    exigir_nao_root
    exigir_conf VM_NAME CPUS_VM CPUS_HOST VM_VCPUS VM_CORES VM_THREADS VM_RAM_MB BOOTLOADER
    exigir_bootloader_coerente
    exigir_sudo
    exigir_comando python3 virsh lscpu virt-xml-validate
    exigir_vm_desligada "$VM_NAME"
    validar_layout_configurado || falhar "$CPU_LAYOUT_ERRO"
    validar_suporte_isolamento || falhar "$SUPORTE_ISOLAMENTO_ERRO"
    validar_pinning_vm || falhar "A etapa 18 só pode isolar CPUs já pinadas exatamente no XML: $XML_CPU_ERRO"

    local params
    params="$(param_isolamento)"
    titulo "Etapa 18: isolamento opcional de CPU"
    aviso "Otimização opcional: aplique somente após medir um baseline e comprovar gargalo de latência/CPU."
    info "A opção 3 da etapa 3 apenas registra o plano; a etapa 17 aplica o pinning, e esta etapa só isola CPUs já pinadas."
    info "Fase 1: gravar isolcpus/nohz_full/rcu_nocbs, reiniciar o host e executar esta etapa novamente."
    info "Fase 2: comprovar o isolamento; não exige novo reboot do host."
    info "CPUs online=[$CPU_LAYOUT_ONLINE] VM=[$CPUS_VM] HOST=[$CPUS_HOST]"
    aviso "Com isolamento ativo, CPUS_VM deixa de atender processos comuns do host mesmo com a VM desligada."

    # I9.12 (REQ-VM-RESOURCE-LIFECYCLE): isolamento PERSISTENTE é incompatível
    # com o perfil retornável, e o motivo é o mesmo da reserva estática de
    # HugePages: `isolcpus`, `nohz_full` e `rcu_nocbs` no boot não devolvem CPU
    # ao scheduler quando a VM para — elas ficam fora do host o tempo todo,
    # ligada ou não. O que é retornável é o `vcpupin`/`emulatorpin` da etapa
    # 17, que deixa de consumir CPU quando o QEMU termina.
    #
    # A etapa não proíbe: ela recusa por padrão e exige que a saída do perfil
    # retornável seja DIGITADA, para que a decisão fique explícita no log de
    # ações em vez de escondida atrás de um "s".
    aviso "Este isolamento é PERSISTENTE e NÃO retornável: as $(printf '%s' "$CPUS_VM" | tr ',' ' ' | wc -w) CPU(s) de CPUS_VM saem do scheduler do host no boot e não voltam quando a VM para."
    info "A alternativa retornável já está aplicada pela etapa 17: vcpupin e emulatorpin organizam a VM quando ela está ligada e liberam a CPU quando o QEMU termina."
    info "Para desfazer depois: bash etapas/53-cpu-isolation.sh --desfazer, seguido de reboot."
    confirmar_digitando "ISOLAMENTO-NAO-RETORNAVEL" \
        "Sair do perfil retornável e isolar CPUs de forma persistente é uma escolha de desempenho com custo permanente para o host." \
        || falhar "Cancelado sem alterações: o perfil retornável foi preservado."

    if ! kernel_parametros_persistentes_exatos "$params"; then
        aviso "Persistência atual divergente/duplicada: ${KERNEL_PERSISTENCIA_ERRO:-estado não exato}."
        confirmar "Remover todas as ocorrências atuais de isolcpus, nohz_full e rcu_nocbs e gravar exatamente '$CPUS_VM' via $BOOTLOADER?" \
            || falhar "Cancelado sem alterações."
        exigir_topologia_inalterada
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
    titulo "Etapa 18: parte no Windows (MSI)"
    aviso "windows/Ativar-MSI-GPU.ps1 altera o Registro do Windows; salve o trabalho antes de executá-lo."
    info "Dentro da VM, execute o script como administrador e reinicie a VM para a alteração produzir efeito."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
