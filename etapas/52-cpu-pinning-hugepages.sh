#!/bin/bash
# ============================================================================
# etapas/52-cpu-pinning-hugepages.sh - Etapa 17: CPU pinning e política de
# memória da VM (XML, sem reboot)
# ============================================================================
# Otimização opcional, aplicada em UMA transação sobre o XML inativo:
#   1. valida configuração, topologia, suporte ao modo e XML candidato;
#   2. recusa se o boot ainda reservar HugePages (contrato antigo);
#   3. define o XML com pinning, topologia, RAM e a página de MEMORIA_MODO.
#
# I9.12-D10: esta etapa NÃO grava mais parâmetro de boot e NÃO pede reboot. Nos
# modos hugetlb as páginas são adquiridas pelo hook no start e devolvidas no
# stop; nada fica reservado com a VM desligada. O único caminho que ainda toca
# chave de boot é `--desfazer`, e só para REMOVER as três juntas, que é a
# migração de hosts vindos do contrato antigo.
# ============================================================================
SCRIPT_VERSION="1.0.0"
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# As três chaves de boot do contrato antigo. Só `--desfazer` as escreve, e só
# para removê-las juntas (I9.12-D10); o restante da etapa apenas prova ausência.
CHAVES_HUGEPAGES="default_hugepagesz hugepagesz hugepages"
TOPOLOGIA_CPU=""
TOPOLOGIA_FINGERPRINT=""
XML_ORIGINAL=""
XML_CANDIDATO=""
XML_POS=""
XML_MUTACAO_POSSIVEL=0
TRANSACAO_OK=0

# Inspeção e comparação de XML vivem no core Python (seção 3.5). As três
# funções abaixo são só adaptadores finos sobre a API pública da fachada, para
# preservar os nomes já usados no restante desta etapa.

xml_sem_hugepages() {
    # 0=não exige HugePages; 1=exige; 2=erro de análise.
    xml_sem_hugepages_arquivo "$1"
}

xml_equivalente() {
    # Equivalência semântica total: usada para provar rollback do domínio.
    xml_dominio_equivalente "$1" "$2" full
}

xml_ajustes_nao_gerenciados_iguais() {
    # Prova que o libvirt não mexeu em cputune/memoryBacking/cpu fora do que
    # esta etapa gerencia (vcpupin, emulatorpin, hugepages, topology e
    # mode/check/migratable).
    xml_dominio_equivalente "$1" "$2" cpu-unmanaged
}

validar_configuracao() {
    # O teto de RAM e a partição de CPU são decididos pelo core; o shell só
    # sonda o host e publica o diagnóstico. O fingerprint da topologia fica
    # guardado para a revalidação TOCTOU antes de cada mutação.
    plano_memoria_vm "$(ram_total_mib)" "${VM_RAM_MB:-}" \
        || { CPU_LAYOUT_ERRO="$CPU_MEMORIA_ERRO"; return 1; }
    TOPOLOGIA_CPU="$(cpu_topologia_csv)" \
        || { CPU_LAYOUT_ERRO="lscpu não forneceu a topologia parseável."; return 1; }
    validar_layout_cpu "$CPUS_VM" "$CPUS_HOST" "$VM_VCPUS" "$VM_CORES" "$VM_THREADS" "$TOPOLOGIA_CPU" \
        || return 1
    TOPOLOGIA_FINGERPRINT="$CPU_LAYOUT_FINGERPRINT"
}

exigir_topologia_inalterada() {
    # Recusa aplicar um plano calculado sobre topologia obsoleta. Uma CPU
    # colocada offline entre a validação e a mutação muda o significado de
    # CPUS_VM/CPUS_HOST, e aplicar assim seria convergência parcial.
    local topologia
    [ -n "$TOPOLOGIA_FINGERPRINT" ] \
        || falhar "Fingerprint da topologia ausente; a validação inicial não foi executada."
    topologia="$(cpu_topologia_csv)" \
        || falhar "lscpu deixou de fornecer a topologia antes da mutação; nada foi alterado."
    cpu_topologia_fingerprint "$topologia" || falhar "$CPU_TOPOLOGIA_ERRO"
    [ "$CPU_TOPOLOGIA_FINGERPRINT" = "$TOPOLOGIA_FINGERPRINT" ] \
        || falhar "A topologia de CPU mudou desde a validação; nada foi alterado. Rode a etapa 3 e repita esta etapa."
}

validar_suporte_modo() {
    # I9.12: era `validar_suporte_1g`, que exigia pdpe1gb e o pool de 1 GiB de
    # todo mundo. Cada modo tem a sua exigência, e `normal` não tem nenhuma:
    # exigir suporte a página gigante para usar memória comum recusaria por um
    # motivo que não existe.
    case "$MEMORIA_MODO_EFETIVO" in
        hugetlb-1g)
            grep -qw pdpe1gb /proc/cpuinfo \
                || falhar "A CPU não anuncia pdpe1gb; o modo hugetlb-1g não é aplicável neste host."
            [ -d /sys/kernel/mm/hugepages/hugepages-1048576kB ] \
                || falhar "O kernel não expõe hugepages-1048576kB; páginas de 1 GiB não estão disponíveis."
            ;;
        hugetlb-2m)
            [ -d /sys/kernel/mm/hugepages/hugepages-2048kB ] \
                || falhar "O kernel não expõe hugepages-2048kB; páginas de 2 MiB não estão disponíveis."
            ;;
        normal)
            :
            ;;
        *)
            falhar "MEMORIA_MODO desconhecido: '$MEMORIA_MODO_EFETIVO'. Aceitos: normal, hugetlb-2m, hugetlb-1g."
            ;;
    esac
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
        "$MEMORIA_MODO_EFETIVO" \
        || falhar "XML candidato recusado: $XML_CPU_ERRO"
    virt-xml-validate "$XML_CANDIDATO" domain >/dev/null \
        || falhar "O schema libvirt recusou o XML candidato; o domínio permanece inalterado."
    validar_xml_cpu_pinning "$XML_CANDIDATO" "$CPUS_VM" "$CPUS_HOST" \
        "$VM_VCPUS" "$VM_CORES" "$VM_THREADS" "$VM_RAM_MB" "$XML_MODO_HUGEPAGES" \
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
        # I9.12-D10: a frase antiga ("as chaves de boot não foram alteradas
        # nesta fase") era verdadeira quando o apply gravava boot em outra
        # fase. O apply não toca em boot nenhum, então o que ainda precisa ser
        # dito é só o que fazer com o XML.
        [ "$restaurado" = sim ] || erro "Nenhum parâmetro de boot foi alterado por esta etapa; preserve o estado atual até revisar o XML."
        rm -f -- "${rollback_dump:-}"
    fi
    rm -f -- "${XML_ORIGINAL:-}" "${XML_CANDIDATO:-}" "${XML_POS:-}"
    python_core_temporarios_limpar
    encerrar_sudo_keepalive
    exit "$status"
}

# I9.9 (REQ-VERIFY-FAILCLOSED): validadores de uma variável para v_var_definida.
# As faixas são as mesmas do schema canônico de configuração do core, para
# que o verificador não aceite valor que a própria configuração recusa.
_v_inteiro_vm_vcpus()   { inteiro_na_faixa "${1:-}" 1 65535; }
_v_inteiro_vm_cores()   { inteiro_na_faixa "${1:-}" 1 65535; }
_v_inteiro_vm_threads() { inteiro_na_faixa "${1:-}" 1 65535; }
_v_inteiro_vm_ram_mb()  { inteiro_na_faixa "${1:-}" 1024 1048576; }
_v_bootloader_valido()  { case "${1:-}" in grub|kernelstub) return 0 ;; *) return 1 ;; esac; }
# I9.12-D8: três valores. `hugetlb-1g-boot` saiu do catálogo e é recusado aqui
# tanto quanto qualquer texto inventado.
_v_memoria_modo_valido() {
    case "${1:-}" in normal|hugetlb-2m|hugetlb-1g) return 0 ;; *) return 1 ;; esac
}

MEMORIA_MODO_EFETIVO=""
XML_MODO_HUGEPAGES=ignorar
MEMORIA_PAGE_KB=0
MEMORIA_PAGINAS=0
MEMORIA_POLITICA_ERRO=""
MEMORIA_POLITICA_TRANSITORIA=0

memoria_modo_resolver() {
    # Vazio significa "ainda não decidido" e NÃO é sinônimo de nenhum modo: o
    # requisito proíbe padrão silencioso. Para as checagens estruturais o
    # verificador usa `normal`, que é o baseline, mas relata a decisão como
    # pendente em vez de fingir que ela foi tomada — e o XML fica em `ignorar`,
    # porque avaliar a página contra um modo que ninguém escolheu seria
    # inventar a resposta.
    #
    # I9.12-D11: o mapa traduz a política em vocabulário do validador de XML.
    # `sim` deixou de existir: com 2 MiB e 1 GiB em jogo ele não identificava
    # mais um estado.
    MEMORIA_MODO_EFETIVO="${MEMORIA_MODO:-}"
    if [ -z "$MEMORIA_MODO_EFETIVO" ]; then
        MEMORIA_MODO_EFETIVO=normal
        XML_MODO_HUGEPAGES=ignorar
        return 1
    fi
    case "$MEMORIA_MODO_EFETIVO" in
        normal)     XML_MODO_HUGEPAGES=nao ;;
        hugetlb-2m) XML_MODO_HUGEPAGES=2m ;;
        hugetlb-1g) XML_MODO_HUGEPAGES=1g ;;
        *)          XML_MODO_HUGEPAGES=ignorar; return 1 ;;
    esac
    return 0
}

memoria_politica_viavel() {
    # Quem decide é o core: aqui só entram a captura da fotografia e o
    # transporte. Repetir a tabela de modos nesta etapa criaria uma segunda
    # autoridade sobre a mesma política.
    local -a permitidas=("${CORE_PARES_ENVELOPE[@]}" VALID ERROR MODE RUNTIME
        RETURNABLE PAGE_KB PAGES_NEEDED BASELINE_NR BASELINE_FREE BASELINE_RESV
        BASELINE_SURPLUS ACQUIRE_DELTA TARGET_NR NODE_COUNT FINGERPRINT
        TRANSIENT)
    local -a payload=()
    local foto=""
    MEMORIA_PAGE_KB=0
    MEMORIA_PAGINAS=0
    MEMORIA_POLITICA_ERRO=""
    # I9.12-D4: recusa estrutural (0) não muda por esperar; transitória (1)
    # depende do pool naquele instante e o hook a reavalia no start. O apply
    # trata as duas de forma diferente, então o default é o mais restritivo.
    MEMORIA_POLITICA_TRANSITORIA=0
    foto="$(recursos_fotografar)" || {
        MEMORIA_POLITICA_ERRO="a fotografia de recursos do host não pôde ser capturada"
        return 1
    }
    payload=(mode "$MEMORIA_MODO_EFETIVO" snapshot "$foto" vm_ram_mib "${VM_RAM_MB:-0}")
    if ! python_core_pares_payload permitidas MEMPOL_ resources-plan payload 2>/dev/null; then
        MEMORIA_POLITICA_ERRO="$(_core_diagnostico 'o core não respondeu ao plano de memória')"
        return 1
    fi
    MEMORIA_PAGE_KB="${MEMPOL_PAGE_KB:-0}"
    MEMORIA_PAGINAS="${MEMPOL_PAGES_NEEDED:-0}"
    MEMORIA_POLITICA_TRANSITORIA="${MEMPOL_TRANSIENT:-0}"
    if [ "${MEMPOL_VALID:-0}" != 1 ]; then
        MEMORIA_POLITICA_ERRO="${MEMPOL_ERROR:-plano de memória recusado sem diagnóstico}"
        return 1
    fi
    return 0
}

verificar() {
    local faltando=0 tmp="" vm_estado=0
    # `[ -n ]` aprovava qualquer literal: lista de CPUs com faixa invertida,
    # VM_RAM_MB com letras ou BOOTLOADER inexistente passavam como "definido" e
    # o verificador seguia usando o valor. Ausente continua sendo pendência;
    # presente e fora do formato é ERRO de configuração, porque reexecutar a
    # etapa não conserta um literal inválido.
    # A exigência de HugePages no XML é DIRIGIDA PELA POLÍTICA: em perfil
    # retornável de memória comum o XML tem de NÃO exigir página grande, e
    # exigir vira defeito — o inverso exato do contrato anterior. O mapa de
    # modo para vocabulário do validador vive em memoria_modo_resolver.
    memoria_modo_resolver || true
    v_var_definida VM_NAME nome_vm_valido || faltando=1
    v_var_definida CPUS_VM lista_cpus_valida || faltando=1
    v_var_definida CPUS_HOST lista_cpus_valida || faltando=1
    v_var_definida VM_CORES _v_inteiro_vm_cores || faltando=1
    v_var_definida VM_THREADS _v_inteiro_vm_threads || faltando=1
    v_var_definida VM_VCPUS _v_inteiro_vm_vcpus || faltando=1
    v_var_definida VM_RAM_MB _v_inteiro_vm_ram_mb || faltando=1
    v_var_definida BOOTLOADER _v_bootloader_valido || faltando=1
    # I9.12-D12: `v_var_definida MEMORIA_MODO` diria só "ainda não definido", e
    # uma decisão de política precisa dizer ONDE se decide. As três respostas
    # são as mesmas de `v_var_definida`: ausente é pendência, valor fora do
    # formato é ERRO (reexecutar a etapa não conserta literal inválido).
    if [ -z "${MEMORIA_MODO:-}" ]; then
        v_falta "MEMORIA_MODO não decidido em passthrough.conf; esta etapa não assume nenhum modo. Rode a etapa 3 e escolha entre normal, hugetlb-2m e hugetlb-1g."
        faltando=1
    elif ! _v_memoria_modo_valido "$MEMORIA_MODO"; then
        v_erro "MEMORIA_MODO com valor fora do formato aceito: normal, hugetlb-2m ou hugetlb-1g."
        faltando=1
    else
        v_ok "MEMORIA_MODO=$MEMORIA_MODO"
    fi
    if [ "$faltando" -eq 0 ]; then
        if validar_configuracao; then
            v_ok "Layout CPU, topologia, RAM e contagem derivada são coerentes."
        else
            v_falta "$CPU_LAYOUT_ERRO"
        fi
    fi
    # A guarda de ferramenta virou uma chamada própria: antes, python3/virsh/
    # virt-xml-validate ausentes viravam UMA v_falta agregada, encadeada por &&
    # com a validação real, e ausência de ferramenta ficava indistinguível de
    # divergência de XML. Ferramenta ausente é indeterminado.
    if ! v_exigir_comando python3 virsh virt-xml-validate; then
        :
    elif [ "$faltando" -ne 0 ]; then
        v_falta "XML de CPU/HugePages não avaliado: a configuração acima precisa estar completa e válida."
    else
        vm_existe_estado "$VM_NAME" || vm_estado=$?
        if [ "$vm_estado" -eq 1 ]; then
            v_falta "VM '$VM_NAME' não existe."
        elif [ "$vm_estado" -ne 0 ]; then
            # `vm_existe` relatava "não existe" também com virsh mudo, libvirtd
            # fora do ar ou permissão negada.
            v_indeterminado "Estado da VM '$VM_NAME' não pôde ser observado: ${VM_EXISTE_MOTIVO:-sem diagnóstico}."
        elif ! tmp="$(mktemp)"; then
            # Sem guarda, `mktemp` falhando abortava o verificador sob set -e,
            # sem sentinel, e o menu exibia "erro" sem diagnóstico nenhum.
            v_indeterminado "Não foi possível criar o temporário para ler o XML da VM."
        else
            # Estágios separados: uma cadeia && de quatro termos colapsava numa
            # única mensagem "XML incompleto ou divergente" que era FALSA quando
            # a causa era o dump que falhou.
            if ! $VIRSH dumpxml --inactive "$VM_NAME" > "$tmp" 2>/dev/null; then
                v_indeterminado "Não foi possível ler o XML inativo da VM '$VM_NAME'."
            elif ! virt-xml-validate "$tmp" domain >/dev/null 2>&1; then
                v_falta "O XML inativo da VM '$VM_NAME' não passa no schema libvirt."
            elif validar_xml_cpu_pinning "$tmp" "$CPUS_VM" "$CPUS_HOST" \
                    "$VM_VCPUS" "$VM_CORES" "$VM_THREADS" "$VM_RAM_MB" \
                    "$XML_MODO_HUGEPAGES"; then
                case "$XML_MODO_HUGEPAGES" in
                    1g)  v_ok "XML possui pinning, topologia, memória e página de 1 GiB exatos." ;;
                    2m)  v_ok "XML possui pinning, topologia, memória e página de 2 MiB exatos." ;;
                    nao) v_ok "XML possui pinning, topologia e memória exatos, e NÃO exige HugePages: é o que torna a VM iniciável com memória comum." ;;
                    *)   v_ok "XML possui pinning, topologia e memória exatos." ;;
                esac
            else
                v_falta "XML de CPU/HugePages incompleto ou divergente: ${XML_CPU_ERRO:-sem diagnóstico}."
            fi
            # I9.12-D11: aqui havia um v_indeterminado permanente dizendo que
            # "a prova de página de 2 MiB no XML ainda não existe". Ela existe
            # desde D11, e o `ignorar` agora só acontece com MEMORIA_MODO
            # indecidido, que já é relatado como pendência acima.
            rm -f -- "$tmp"
        fi
    fi
    # I9.12 (REQ-VM-RESOURCE-LIFECYCLE): o critério passou a ser a POLÍTICA,
    # não a reserva estática. Antes, a ausência das três chaves de boot era
    # relatada como divergência — ou seja, o host com a RAM devolvida ao
    # operador era acusado de defeito, e o status do menu empurrava de volta
    # para a reserva permanente.
    #
    # I9.12-D8/D10: o `case` por modo virou um ramo só. Todos os três modos são
    # retornáveis, e em todos eles chave de HugePages no boot é RESÍDUO do
    # contrato antigo, não configuração desta etapa. Provar ausência é tão
    # obrigatório quanto provar presença era.
    if ! cmdline_possui_alguma_chave "$CHAVES_HUGEPAGES"; then
        v_ok "Nenhuma reserva de HugePages na cmdline deste boot: o perfil é retornável."
    else
        v_falta "O perfil '$MEMORIA_MODO_EFETIVO' é retornável, mas a cmdline ainda reserva HugePages no boot. Isso é resíduo do contrato antigo: rode --desfazer e reinicie."
    fi
    if kernel_param_chaves_persistentes_ausentes "$CHAVES_HUGEPAGES" 2>/dev/null; then
        v_ok "O boot persistente não reserva HugePages."
    else
        v_kernel_persistencia_falhou "Ausência persistente de HugePages não comprovada: ${KERNEL_PERSISTENCIA_ERRO:-não verificável}."
    fi
    if [ "$faltando" -eq 0 ] && validar_isolamento_compativel; then
        v_ok "Isolamento está ausente ou exatamente alinhado ao pinning configurado."
    elif [ "$faltando" -eq 0 ]; then
        v_falta "$ISOLAMENTO_COMPAT_ERRO"
    fi
    # O pool é adquirido pelo hook no start e devolvido no stop, então com a VM
    # desligada o estado correto é o baseline do host: exigir páginas aqui
    # seria exigir de volta o defeito que I9.12 removeu. O ramo do perfil
    # legado, que exigia o pool reservado, saiu com o modo em I9.12-D8.
    case "$MEMORIA_MODO_EFETIVO" in
        hugetlb-2m|hugetlb-1g)
            memoria_politica_viavel \
                && v_ok "Política '$MEMORIA_MODO_EFETIVO' viável: $MEMORIA_PAGINAS página(s) de $MEMORIA_PAGE_KB kB serão adquiridas no start e devolvidas no stop." \
                || v_falta "Política '$MEMORIA_MODO_EFETIVO' não é viável: ${MEMORIA_POLITICA_ERRO:-sem diagnóstico}."
            ;;
        *)
            memoria_politica_viavel \
                && v_ok "Política '$MEMORIA_MODO_EFETIVO': a VM usa memória comum, que volta ao host quando o QEMU termina." \
                || v_falta "Política de memória inválida: ${MEMORIA_POLITICA_ERRO:-sem diagnóstico}."
            ;;
    esac
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
        "$VM_VCPUS" "$VM_CORES" "$VM_THREADS" "$VM_RAM_MB" "$XML_MODO_HUGEPAGES" \
        || falhar "XML persistido não passou nas pós-condições: $XML_CPU_ERRO"
    xml_ajustes_nao_gerenciados_iguais "$XML_CANDIDATO" "$XML_POS" \
        || falhar "O libvirt alterou ajustes não gerenciados de cputune/memoryBacking/cpu; rollback obrigatório."
    TRANSACAO_OK=1
    # I9.12-D11: a mensagem dizia "páginas de 1 GiB" em qualquer caso, porque
    # era o único desfecho possível. Agora ela precisa dizer qual política ficou
    # definida, senão o operador não distingue os três resultados.
    case "$MEMORIA_MODO_EFETIVO" in
        normal)
            ok "XML validado e definido: $VM_VCPUS vCPUs, topologia ${VM_CORES}c/${VM_THREADS}t e memória comum (sem exigência de HugePages)."
            ;;
        hugetlb-2m)
            ok "XML validado e definido: $VM_VCPUS vCPUs, topologia ${VM_CORES}c/${VM_THREADS}t e página de 2 MiB."
            ;;
        hugetlb-1g)
            ok "XML validado e definido: $VM_VCPUS vCPUs, topologia ${VM_CORES}c/${VM_THREADS}t e página de 1 GiB."
            ;;
    esac
}

desfazer() {
    local params tmp candidato pos
    exigir_nao_root
    exigir_conf VM_NAME BOOTLOADER
    exigir_bootloader_coerente
    exigir_sudo
    exigir_comando python3 virsh virt-xml-validate
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
        aviso "Fase 1/2: será removida apenas a exigência de HugePages do XML, qualquer que seja o tamanho de página declarado."
        confirmar "Continuar com a reversão segura da etapa 17?" || falhar "Cancelado sem alterações."
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
        info "Rode novamente com --desfazer para remover do boot as três chaves residuais do contrato antigo, se ainda existirem."
        return 0
    fi

    # Fase 2/2: remove do boot o resíduo do contrato antigo. É o ÚNICO ponto do
    # projeto que escreve chave de HugePages no bootloader, e escreve só para
    # apagar as três juntas — a etapa nunca mais as adiciona (I9.12-D10).
    params="$CHAVES_HUGEPAGES"
    if kernel_param_chaves_persistentes_ausentes "$params"; then
        ok "As chaves de HugePages já estão ausentes da configuração de boot."
        if cmdline_possui_alguma_chave "$params"; then
            pedir_reboot
        else
            info "Reversão da etapa 17 já está completa."
        fi
        TRANSACAO_OK=1
        return 0
    fi
    aviso "Fase 2/2: o XML já não depende de HugePages; agora todas as ocorrências residuais de default_hugepagesz, hugepagesz e hugepages serão removidas do boot."
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
        --desfazer)
            guard_mutation cpu.tune || return 1
            desfazer
            return
            ;;
        "") guard_mutation cpu.tune || return 1 ;;
        *) falhar "Uso: $0 [--verificar|--desfazer]" ;;
    esac

    exigir_nao_root
    # I9.12-D9/D10: HUGEPAGES_1G saiu (chave depreciada) e MEMORIA_MODO entrou:
    # sem a política decidida esta etapa não tem o que aplicar.
    exigir_conf VM_NAME CPUS_VM CPUS_HOST VM_CORES VM_THREADS VM_VCPUS VM_RAM_MB MEMORIA_MODO BOOTLOADER
    memoria_modo_resolver \
        || falhar "MEMORIA_MODO não decidido; rode a etapa 3 (opção de política de memória) antes desta etapa."
    exigir_bootloader_coerente
    exigir_sudo
    exigir_comando python3 virsh lscpu virt-xml-validate
    exigir_vm_desligada "$VM_NAME"
    $VIRSH help define 2>/dev/null | grep -q -- '--validate' \
        || falhar "Este virsh não oferece 'define --validate'; nenhuma alteração foi feita."
    validar_configuracao || falhar "$CPU_LAYOUT_ERRO"
    validar_suporte_modo

    # I9.12-D10: reserva de HugePages no boot pertence ao contrato antigo, e
    # esta etapa recusa aplicar por cima dela em QUALQUER modo. Aplicar assim
    # deixaria o host com página reservada permanentemente e o XML declarando
    # outra política — os dois caminhos mutantes que a regra 8 proíbe. Sair
    # desse estado é `--desfazer`, que é o único lugar que ainda toca boot.
    if cmdline_possui_alguma_chave "$CHAVES_HUGEPAGES"; then
        falhar "A cmdline deste boot ainda reserva HugePages (default_hugepagesz/hugepagesz/hugepages): isso pertence ao contrato antigo. Rode 'bash $0 --desfazer' e reinicie antes de aplicar."
    fi
    kernel_param_chaves_persistentes_ausentes "$CHAVES_HUGEPAGES" \
        || falhar "A configuração de boot ainda reserva HugePages ou não pôde ser lida (${KERNEL_PERSISTENCIA_ERRO:-não verificável}). Rode 'bash $0 --desfazer' e reinicie antes de aplicar."

    trap 'finalizar_transacao $?' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    titulo "Etapa 17: CPU pinning e política de memória (VM: $VM_NAME)"
    aviso "Otimização opcional: aplique somente após medir um baseline e identificar benefício esperado."
    info "A opção 3 da etapa 3 registra o plano de CPUs/RAM e a política de memória; esta etapa aplica o XML de fato."
    info "Uma transação, sobre o XML inativo: nenhum parâmetro de boot é gravado e nenhum reboot é pedido."
    info "O pinning organiza a VM quando ligada; somente a etapa 18 opcional retira CPUs do host mesmo com a VM desligada."
    info "CPUs online=[$CPU_LAYOUT_ONLINE] VM=[$CPUS_VM] HOST=[$CPUS_HOST]"

    case "$MEMORIA_MODO_EFETIVO" in
        normal)
            info "Política 'normal': a VM usa memória comum com THP oportunístico, e o kernel devolve tudo quando o QEMU termina."
            ;;
        hugetlb-2m|hugetlb-1g)
            # I9.12-D4: recusa estrutural bloqueia; transitória não. O XML não
            # depende do estado do pool NESTE instante — quem adquire é o hook,
            # no start, e é lá que a recusa transitória será reavaliada. É a
            # mesma lógica de memoria_plano_resolver na etapa 14.
            if memoria_politica_viavel; then
                info "Política '$MEMORIA_MODO_EFETIVO': $MEMORIA_PAGINAS página(s) de $MEMORIA_PAGE_KB kB serão adquiridas no start e devolvidas no stop."
            elif [ "$MEMORIA_POLITICA_TRANSITORIA" = 1 ]; then
                aviso "Política '$MEMORIA_MODO_EFETIVO' não é viável AGORA: ${MEMORIA_POLITICA_ERRO:-sem diagnóstico}."
                aviso "A recusa é transitória e depende do pool neste instante; o hook a reavalia no start. O XML será definido mesmo assim."
            else
                falhar "Política '$MEMORIA_MODO_EFETIVO' recusada estruturalmente: ${MEMORIA_POLITICA_ERRO:-sem diagnóstico}. Corrija a configuração ou escolha outro modo na etapa 3."
            fi
            ;;
    esac

    preparar_xml_candidato
    validar_isolamento_compativel || falhar "$ISOLAMENTO_COMPAT_ERRO"
    exigir_topologia_inalterada
    aplicar_xml
    ok "O XML será usado no próximo start da VM, sem reboot do host."
    info "A etapa 17 é opcional e reversível com: bash etapas/52-cpu-pinning-hugepages.sh --desfazer"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
