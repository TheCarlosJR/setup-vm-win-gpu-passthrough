#!/bin/bash
# ============================================================================
# etapas/52-cpu-pinning-hugepages.sh - CPU pinning e HugePages de 1 GiB
# ============================================================================
# Otimização opcional e faseada:
#   1. valida configuração, topologia, suporte e XML candidato sem mutar nada;
#   2. configura o boot por chave e exige um reboot, sem definir o XML;
#   3. somente num boot posterior, com páginas exatas e livres, define o XML.
# A reversão segue a ordem segura inversa: XML primeiro, boot depois.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

CHAVES_HUGEPAGES="default_hugepagesz hugepagesz hugepages"
TOPOLOGIA_CPU=""
HUGEPAGES_ERRO=""
XML_ORIGINAL=""
XML_CANDIDATO=""
XML_POS=""
XML_MUTACAO_POSSIVEL=0
TRANSACAO_OK=0

param_hugepages() {
    printf 'default_hugepagesz=1G hugepagesz=1G hugepages=%s\n' "$HUGEPAGES_1G"
}

xml_sem_hugepages() {
    python3 - "$1" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
if root.tag != 'domain':
    raise SystemExit(2)
for backing in [c for c in list(root) if c.tag == 'memoryBacking']:
    if any(c.tag == 'hugepages' for c in list(backing)):
        raise SystemExit(1)
PY
}

xml_equivalente() {
    python3 - "$1" "$2" <<'PY'
import sys
import xml.etree.ElementTree as ET

def canon(element):
    children = tuple(canon(child) for child in list(element) if isinstance(child.tag, str))
    return (
        element.tag,
        tuple(sorted(element.attrib.items())),
        (element.text or '').strip(),
        children,
    )
try:
    left = canon(ET.parse(sys.argv[1]).getroot())
    right = canon(ET.parse(sys.argv[2]).getroot())
except Exception:
    raise SystemExit(2)
raise SystemExit(0 if left == right else 1)
PY
}

xml_ajustes_nao_gerenciados_iguais() {
    python3 - "$1" "$2" <<'PY'
import sys
import xml.etree.ElementTree as ET

def direct(parent, name):
    return [child for child in list(parent) if child.tag == name]

def canon(element, ignored_children=(), ignored_attrs=()):
    children = tuple(
        canon(child) for child in list(element)
        if isinstance(child.tag, str) and child.tag not in ignored_children
    )
    attrs = tuple(sorted((k, v) for k, v in element.attrib.items() if k not in ignored_attrs))
    return element.tag, attrs, (element.text or '').strip(), children

def projection(path):
    root = ET.parse(path).getroot()
    result = []
    for name, ignored_children, ignored_attrs in (
        ('cputune', ('vcpupin', 'emulatorpin'), ()),
        ('memoryBacking', ('hugepages',), ()),
        ('cpu', ('topology',), ('mode', 'check', 'migratable')),
    ):
        nodes = direct(root, name)
        if len(nodes) > 1:
            raise ValueError(f'<{name}> duplicado')
        result.append(None if not nodes else canon(nodes[0], ignored_children, ignored_attrs))
    return tuple(result)

try:
    equal = projection(sys.argv[1]) == projection(sys.argv[2])
except Exception:
    raise SystemExit(2)
raise SystemExit(0 if equal else 1)
PY
}

hugepages_estado_exato() {
    # hugepages_estado_exato [livres]: além do tamanho/total/sysfs, exige que
    # todas as páginas estejam livres antes de tornar o XML dependente delas.
    local exigir_livres="${1:-nao}" total tamanho livres reservadas excedentes sys_total sys_livres
    local -a valores=()
    HUGEPAGES_ERRO=""

    mapfile -t valores < <(awk '$1 == "HugePages_Total:" {print $2}' /proc/meminfo)
    [ "${#valores[@]}" -eq 1 ] \
        || { HUGEPAGES_ERRO="HugePages_Total ausente ou duplicado em /proc/meminfo."; return 1; }
    total="${valores[0]}"
    mapfile -t valores < <(awk '$1 == "Hugepagesize:" {print $2}' /proc/meminfo)
    [ "${#valores[@]}" -eq 1 ] \
        || { HUGEPAGES_ERRO="Hugepagesize ausente ou duplicado em /proc/meminfo."; return 1; }
    tamanho="${valores[0]}"
    inteiro_na_faixa "$total" 0 1048576 && inteiro_na_faixa "$tamanho" 1 1073741824 \
        || { HUGEPAGES_ERRO="Valores de HugePages inválidos em /proc/meminfo."; return 1; }
    [ "$tamanho" -eq 1048576 ] \
        || { HUGEPAGES_ERRO="Hugepagesize=${tamanho} kB; esperado exatamente 1048576 kB (1 GiB)."; return 1; }
    [ "$total" -eq "$HUGEPAGES_1G" ] \
        || { HUGEPAGES_ERRO="HugePages_Total=$total; esperado exatamente $HUGEPAGES_1G."; return 1; }

    [ -r /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages ] \
        || { HUGEPAGES_ERRO="Interface sysfs de páginas de 1 GiB indisponível."; return 1; }
    IFS= read -r sys_total < /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages \
        || { HUGEPAGES_ERRO="Não foi possível ler nr_hugepages de 1 GiB."; return 1; }
    [ "$sys_total" -eq "$HUGEPAGES_1G" ] 2>/dev/null \
        || { HUGEPAGES_ERRO="nr_hugepages de 1 GiB=$sys_total; esperado $HUGEPAGES_1G."; return 1; }

    if [ "$exigir_livres" = livres ]; then
        livres="$(awk '$1 == "HugePages_Free:" {print $2}' /proc/meminfo)"
        reservadas="$(awk '$1 == "HugePages_Rsvd:" {print $2}' /proc/meminfo)"
        excedentes="$(awk '$1 == "HugePages_Surp:" {print $2}' /proc/meminfo)"
        [ "$livres" -eq "$HUGEPAGES_1G" ] 2>/dev/null \
            || { HUGEPAGES_ERRO="Somente ${livres:-?} de $HUGEPAGES_1G páginas estão livres; a VM permanece bloqueada."; return 1; }
        [ "${reservadas:-1}" -eq 0 ] 2>/dev/null \
            || { HUGEPAGES_ERRO="Há ${reservadas:-?} HugePages reservadas por outro processo."; return 1; }
        [ "${excedentes:-1}" -eq 0 ] 2>/dev/null \
            || { HUGEPAGES_ERRO="HugePages_Surp=${excedentes:-?}; a reserva não é exata."; return 1; }
        [ -r /sys/kernel/mm/hugepages/hugepages-1048576kB/free_hugepages ] \
            || { HUGEPAGES_ERRO="free_hugepages de 1 GiB não é legível."; return 1; }
        IFS= read -r sys_livres < /sys/kernel/mm/hugepages/hugepages-1048576kB/free_hugepages \
            || { HUGEPAGES_ERRO="Não foi possível ler free_hugepages de 1 GiB."; return 1; }
        [ "$sys_livres" -eq "$HUGEPAGES_1G" ] 2>/dev/null \
            || { HUGEPAGES_ERRO="free_hugepages de 1 GiB=$sys_livres; esperado $HUGEPAGES_1G."; return 1; }
    fi
}

validar_configuracao() {
    local ram_max
    inteiro_na_faixa "${VM_RAM_MB:-}" 1024 1048576 \
        || { CPU_LAYOUT_ERRO="VM_RAM_MB inválido: '${VM_RAM_MB:-vazio}'."; return 1; }
    inteiro_na_faixa "${HUGEPAGES_1G:-}" 1 1048576 \
        || { CPU_LAYOUT_ERRO="HUGEPAGES_1G precisa ser um inteiro positivo."; return 1; }
    [ $((10#$VM_RAM_MB % 1024)) -eq 0 ] \
        || { CPU_LAYOUT_ERRO="VM_RAM_MB=$VM_RAM_MB não é múltiplo de 1024 MiB."; return 1; }
    [ $((10#$HUGEPAGES_1G * 1024)) -eq $((10#$VM_RAM_MB)) ] \
        || { CPU_LAYOUT_ERRO="HUGEPAGES_1G=$HUGEPAGES_1G diverge de VM_RAM_MB/1024; corrija conscientemente na etapa 02."; return 1; }
    ram_max="$(ram_max_vm_mib)"
    [ "$VM_RAM_MB" -le "$ram_max" ] \
        || { CPU_LAYOUT_ERRO="VM_RAM_MB=$VM_RAM_MB excede o teto seguro atual de ${ram_max} MiB."; return 1; }
    TOPOLOGIA_CPU="$(cpu_topologia_csv)" \
        || { CPU_LAYOUT_ERRO="lscpu não forneceu a topologia parseável."; return 1; }
    validar_layout_cpu "$CPUS_VM" "$CPUS_HOST" "$VM_VCPUS" "$VM_CORES" "$VM_THREADS" "$TOPOLOGIA_CPU"
}

validar_suporte_1g() {
    grep -qw pdpe1gb /proc/cpuinfo \
        || falhar "A CPU não anuncia pdpe1gb; esta etapa não aplicará páginas de 1 GiB."
    [ -d /sys/kernel/mm/hugepages/hugepages-1048576kB ] \
        || falhar "O kernel não expõe hugepages-1048576kB; páginas de 1 GiB não estão disponíveis."
}

ISOLAMENTO_COMPAT_ERRO=""
validar_isolamento_compativel() {
    # Um novo pinning só pode coexistir com ausência completa de isolamento ou
    # com as três chaves já exatamente alinhadas ao novo CPUS_VM. Estados de
    # reboot pendente/divergentes são bloqueados.
    local chaves="isolcpus nohz_full rcu_nocbs" esperados ativo persistente status
    ISOLAMENTO_COMPAT_ERRO=""
    esperados="isolcpus=$CPUS_VM nohz_full=$CPUS_VM rcu_nocbs=$CPUS_VM"
    if cmdline_parametros_exatos "$esperados"; then
        ativo=exato
    elif cmdline_possui_alguma_chave "$chaves"; then
        ativo=divergente
    else
        status=$?
        [ "$status" -eq 1 ] \
            || { ISOLAMENTO_COMPAT_ERRO="Não foi possível inspecionar as chaves de isolamento na cmdline."; return 1; }
        ativo=ausente
    fi

    if kernel_parametros_persistentes_exatos "$esperados"; then
        persistente=exato
    elif kernel_param_chaves_persistentes_ausentes "$chaves"; then
        persistente=ausente
    else
        ISOLAMENTO_COMPAT_ERRO="Persistência de isolamento divergente ou não verificável: $KERNEL_PERSISTENCIA_ERRO"
        return 1
    fi
    if [ "$ativo" = ausente ] && [ "$persistente" = ausente ]; then
        return 0
    fi
    if [ "$ativo" = exato ] && [ "$persistente" = exato ]; then
        return 0
    fi
    ISOLAMENTO_COMPAT_ERRO="Isolamento ativo=$ativo e persistente=$persistente. Execute 53 --desfazer, reinicie e só então altere o pinning."
    return 1
}

preparar_xml_candidato() {
    XML_ORIGINAL="$(mktemp)" || falhar "Não foi possível criar temporário para o XML original."
    XML_CANDIDATO="$(mktemp)" || falhar "Não foi possível criar temporário para o XML candidato."
    XML_POS="$(mktemp)" || falhar "Não foi possível criar temporário para a pós-condição XML."
    $VIRSH dumpxml --inactive "$VM_NAME" > "$XML_ORIGINAL" \
        || falhar "Não foi possível capturar o XML inativo da VM."
    [ -s "$XML_ORIGINAL" ] || falhar "O XML inativo capturado está vazio."
    xml_cpu_gerar_candidato "$XML_ORIGINAL" "$XML_CANDIDATO" \
        "$CPUS_VM" "$CPUS_HOST" "$VM_VCPUS" "$VM_CORES" "$VM_THREADS" "$VM_RAM_MB" \
        || falhar "XML candidato recusado: $XML_CPU_ERRO"
    virt-xml-validate "$XML_CANDIDATO" domain >/dev/null \
        || falhar "O schema libvirt recusou o XML candidato; boot e domínio permanecem inalterados."
    validar_xml_cpu_pinning "$XML_CANDIDATO" "$CPUS_VM" "$CPUS_HOST" \
        "$VM_VCPUS" "$VM_CORES" "$VM_THREADS" "$VM_RAM_MB" sim \
        || falhar "Pós-condições do XML candidato falharam: $XML_CPU_ERRO"
}

finalizar_transacao() {
    local status="$1" restaurado="" rollback_dump=""
    trap - EXIT INT TERM
    if [ "$status" -ne 0 ] && [ "$XML_MUTACAO_POSSIVEL" -eq 1 ] \
       && [ "$TRANSACAO_OK" -eq 0 ] && [ -s "${XML_ORIGINAL:-}" ]; then
        erro "Falha após iniciar a definição do domínio; restaurando o XML original."
        rollback_dump="$(mktemp)" || true
        if $VIRSH define --validate "$XML_ORIGINAL" >/dev/null 2>&1 \
           && [ -n "$rollback_dump" ] \
           && $VIRSH dumpxml --inactive "$VM_NAME" > "$rollback_dump" \
           && xml_equivalente "$XML_ORIGINAL" "$rollback_dump"; then
            restaurado=sim
            aviso "Rollback XML concluído e comparado semanticamente."
        else
            erro "ROLLBACK XML NÃO COMPROVADO. Não inicie a VM até restaurar: ${XML_BACKUP_PATH:-$XML_ORIGINAL}"
            status=1
        fi
        [ "$restaurado" = sim ] || erro "As chaves de boot não foram alteradas nesta fase; preserve o estado atual até revisar o XML."
        rm -f -- "${rollback_dump:-}"
    fi
    rm -f -- "${XML_ORIGINAL:-}" "${XML_CANDIDATO:-}" "${XML_POS:-}"
    encerrar_sudo_keepalive
    exit "$status"
}

verificar() {
    local var faltando=0 tmp="" params=""
    [ -z "${HUGEPAGES_1G:-}" ] || params="$(param_hugepages)"
    for var in VM_NAME CPUS_VM CPUS_HOST VM_CORES VM_THREADS VM_VCPUS VM_RAM_MB HUGEPAGES_1G BOOTLOADER; do
        if [ -n "${!var:-}" ]; then
            v_ok "$var=${!var}"
        else
            v_falta "$var ausente."
            faltando=1
        fi
    done
    if [ "$faltando" -eq 0 ]; then
        if validar_configuracao; then
            v_ok "Layout CPU, topologia, RAM e contagem derivada são coerentes."
        else
            v_falta "$CPU_LAYOUT_ERRO"
        fi
    fi
    if ! command -v python3 >/dev/null 2>&1 \
       || ! command -v virsh >/dev/null 2>&1 \
       || ! command -v virt-xml-validate >/dev/null 2>&1; then
        v_falta "python3, virsh e/ou virt-xml-validate indisponíveis para validar o XML."
    elif [ -n "${VM_NAME:-}" ] && vm_existe "$VM_NAME"; then
        tmp="$(mktemp)"
        if $VIRSH dumpxml --inactive "$VM_NAME" > "$tmp" \
           && virt-xml-validate "$tmp" domain >/dev/null 2>&1 \
           && [ "$faltando" -eq 0 ] \
           && validar_xml_cpu_pinning "$tmp" "$CPUS_VM" "$CPUS_HOST" \
                "$VM_VCPUS" "$VM_CORES" "$VM_THREADS" "$VM_RAM_MB" sim; then
            v_ok "XML possui pinning, topologia, memória e página de 1 GiB exatos."
        else
            v_falta "XML de CPU/HugePages incompleto ou divergente: ${XML_CPU_ERRO:-dump indisponível}."
        fi
        rm -f -- "$tmp"
    else
        v_falta "VM '${VM_NAME:-não definida}' não existe."
    fi
    if [ -n "$params" ] && cmdline_parametros_exatos "$params"; then
        v_ok "As três chaves de HugePages estão ativas uma única vez e com valores exatos."
    else
        v_falta "Cmdline de HugePages divergente: ${CMDLINE_PARAM_ERRO:-configuração ausente}."
    fi
    if [ -n "$params" ] && kernel_parametros_persistentes_exatos "$params"; then
        v_ok "Persistência do boot é exata e coerente entre entradas."
    else
        v_falta "Persistência de HugePages não comprovada: ${KERNEL_PERSISTENCIA_ERRO:-configuração ausente}."
    fi
    if [ "$faltando" -eq 0 ] && validar_isolamento_compativel; then
        v_ok "Isolamento está ausente ou exatamente alinhado ao pinning configurado."
    elif [ "$faltando" -eq 0 ]; then
        v_falta "$ISOLAMENTO_COMPAT_ERRO"
    fi
    if [ -n "${HUGEPAGES_1G:-}" ] && hugepages_estado_exato; then
        v_ok "Pool ativo: $HUGEPAGES_1G páginas de 1 GiB."
    else
        v_falta "Pool de HugePages divergente: ${HUGEPAGES_ERRO:-configuração ausente}."
    fi
    v_fim
}

aplicar_xml() {
    xml_backup "$VM_NAME"
    exigir_vm_desligada "$VM_NAME"
    XML_MUTACAO_POSSIVEL=1
    $VIRSH define --validate "$XML_CANDIDATO" >/dev/null \
        || falhar "virsh define falhou; o trap tentará restaurar o XML original."
    $VIRSH dumpxml --inactive "$VM_NAME" > "$XML_POS" \
        || falhar "Não foi possível ler o XML após define."
    virt-xml-validate "$XML_POS" domain >/dev/null \
        || falhar "O XML persistido não passa no schema libvirt."
    validar_xml_cpu_pinning "$XML_POS" "$CPUS_VM" "$CPUS_HOST" \
        "$VM_VCPUS" "$VM_CORES" "$VM_THREADS" "$VM_RAM_MB" sim \
        || falhar "XML persistido não passou nas pós-condições: $XML_CPU_ERRO"
    xml_ajustes_nao_gerenciados_iguais "$XML_CANDIDATO" "$XML_POS" \
        || falhar "O libvirt alterou ajustes não gerenciados de cputune/memoryBacking/cpu; rollback obrigatório."
    TRANSACAO_OK=1
    ok "XML validado e definido: $VM_VCPUS vCPUs, topologia ${VM_CORES}c/${VM_THREADS}t e páginas de 1 GiB."
}

desfazer() {
    local params tmp candidato pos
    exigir_nao_root
    exigir_sudo
    exigir_comando python3 virsh virt-xml-validate
    exigir_conf VM_NAME BOOTLOADER
    exigir_vm_desligada "$VM_NAME"
    $VIRSH help define 2>/dev/null | grep -q -- '--validate' \
        || falhar "Este virsh não oferece 'define --validate'; nenhuma alteração foi feita."
    trap 'finalizar_transacao $?' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    tmp="$(mktemp)"; candidato="$(mktemp)"; pos="$(mktemp)"
    XML_ORIGINAL="$tmp"; XML_CANDIDATO="$candidato"; XML_POS="$pos"
    $VIRSH dumpxml --inactive "$VM_NAME" > "$tmp" \
        || falhar "Não foi possível capturar o XML original."

    if ! xml_sem_hugepages "$tmp"; then
        xml_cpu_remover_hugepages "$tmp" "$candidato" \
            || falhar "Não foi possível preparar a reversão: $XML_CPU_ERRO"
        xml_sem_hugepages "$candidato" \
            || falhar "O candidato de reversão ainda exige HugePages."
        virt-xml-validate "$candidato" domain >/dev/null \
            || falhar "O schema libvirt recusou o candidato de reversão."
        aviso "Fase 1/2: será removida apenas a exigência de HugePages do XML."
        confirmar "Continuar com a reversão segura da etapa 52?" || falhar "Cancelado sem alterações."
        xml_backup "$VM_NAME"
        exigir_vm_desligada "$VM_NAME"
        XML_MUTACAO_POSSIVEL=1
        $VIRSH define --validate "$candidato" >/dev/null \
            || falhar "Falha ao retirar HugePages do XML; o rollback será tentado."
        $VIRSH dumpxml --inactive "$VM_NAME" > "$pos" \
            || falhar "Não foi possível verificar o XML após a reversão."
        virt-xml-validate "$pos" domain >/dev/null \
            || falhar "O XML persistido após reversão não passa no schema libvirt."
        xml_sem_hugepages "$pos" \
            || falhar "O XML persistido ainda exige HugePages."
        xml_ajustes_nao_gerenciados_iguais "$candidato" "$pos" \
            || falhar "A reversão alterou ajustes XML não gerenciados; rollback obrigatório."
        TRANSACAO_OK=1
        ok "HugePages removidas do XML; pinning e demais ajustes foram preservados."
        info "Rode novamente com --desfazer para remover as três chaves do boot."
        return 0
    fi

    params="$CHAVES_HUGEPAGES"
    if kernel_param_chaves_persistentes_ausentes "$params"; then
        ok "As chaves de HugePages já estão ausentes da configuração de boot."
        if cmdline_possui_alguma_chave "$params"; then
            pedir_reboot
        else
            info "Reversão da etapa 52 já está completa."
        fi
        TRANSACAO_OK=1
        return 0
    fi
    aviso "Fase 2/2: o XML já não depende de HugePages; agora todas as ocorrências de default_hugepagesz, hugepagesz e hugepages serão removidas do boot."
    confirmar "Remover default_hugepagesz, hugepagesz e hugepages via $BOOTLOADER?" \
        || falhar "Cancelado sem alterações."
    kernel_param_del "$params"
    kernel_param_chaves_persistentes_ausentes "$params" \
        || falhar "A remoção não pôde ser comprovada: $KERNEL_PERSISTENCIA_ERRO"
    TRANSACAO_OK=1
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
    exigir_conf VM_NAME CPUS_VM CPUS_HOST VM_CORES VM_THREADS VM_VCPUS VM_RAM_MB HUGEPAGES_1G BOOTLOADER
    exigir_vm_desligada "$VM_NAME"
    $VIRSH help define 2>/dev/null | grep -q -- '--validate' \
        || falhar "Este virsh não oferece 'define --validate'; nenhuma alteração foi feita."
    validar_configuracao || falhar "$CPU_LAYOUT_ERRO"
    validar_suporte_1g

    trap 'finalizar_transacao $?' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    titulo "CPU pinning e HugePages opcionais (VM: $VM_NAME)"
    aviso "Otimização opcional: aplique somente após medir um baseline e identificar benefício esperado."
    info "A opção 3 da etapa 02 apenas registra o plano de CPUs/RAM; esta etapa aplica boot e XML de fato."
    info "Fase 1: gravar HugePages no boot, reiniciar o host e executar novamente."
    info "Fase 2: comprovar as páginas e então definir pinning/topologia/memória no XML; não exige novo reboot do host."
    aviso "HugePages reservam $HUGEPAGES_1G GiB fora da RAM comum do host mesmo com a VM desligada."
    info "O pinning organiza a VM quando ligada; somente a etapa 53 opcional retira CPUs do host mesmo com a VM desligada."
    info "CPUs online=[$CPU_LAYOUT_ONLINE] VM=[$CPUS_VM] HOST=[$CPUS_HOST]"
    info "Reserva solicitada: $HUGEPAGES_1G x 1 GiB = $VM_RAM_MB MiB."

    # O candidato é validado antes até mesmo da alteração de boot.
    preparar_xml_candidato
    validar_isolamento_compativel || falhar "$ISOLAMENTO_COMPAT_ERRO"

    local params
    params="$(param_hugepages)"
    if ! kernel_parametros_persistentes_exatos "$params"; then
        aviso "Fase 1/2: o XML NÃO será alterado nesta execução."
        aviso "Persistência atual divergente/duplicada: ${KERNEL_PERSISTENCIA_ERRO:-estado não exato}."
        aviso "Reservar $HUGEPAGES_1G GiB retira essa RAM do host mesmo com a VM desligada."
        confirmar "Remover todas as ocorrências atuais de default_hugepagesz, hugepagesz e hugepages e gravar exatamente '$params' via $BOOTLOADER?" \
            || falhar "Cancelado sem alterações."
        kernel_param_add "$params"
        kernel_parametros_persistentes_exatos "$params" \
            || falhar "A persistência pós-alteração não é exata: $KERNEL_PERSISTENCIA_ERRO"
        TRANSACAO_OK=1
        pedir_reboot
        return 0
    fi

    if ! cmdline_parametros_exatos "$params"; then
        aviso "O boot persistente já está correto, mas o kernel atual ainda não: $CMDLINE_PARAM_ERRO"
        TRANSACAO_OK=1
        pedir_reboot
        return 0
    fi
    hugepages_estado_exato livres \
        || falhar "Não é seguro definir o XML: $HUGEPAGES_ERRO"

    titulo "Fase 2/2: definir XML somente após comprovar as páginas"
    aplicar_xml
    ok "Fase 2 concluída; o XML será usado no próximo start da VM, sem novo reboot do host."
    info "A etapa 52 é opcional e reversível com: bash etapas/52-cpu-pinning-hugepages.sh --desfazer"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
