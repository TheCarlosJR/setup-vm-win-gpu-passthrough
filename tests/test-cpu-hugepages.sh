#!/bin/bash
# Testes puros da tarefa 5. Não usa sudo, virsh, bootloader, /sys gravável ou serviços.
set -euo pipefail
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$RAIZ/lib/common.sh"

falha() {
    echo "FALHA: $*" >&2
    exit 1
}

esperar_falha() {
    local descricao="$1"
    shift
    if "$@"; then
        falha "$descricao deveria ter sido recusado"
    fi
}

TOPO_SMT2_MULTISOCKET=$'0,0,0,0,Y\n4,0,0,0,Y\n1,1,0,0,Y\n5,1,0,0,Y\n2,0,1,1,Y\n6,0,1,1,Y\n3,1,1,1,Y\n7,1,1,1,Y'
validar_layout_cpu "0,4,1,5" "2,6,3,7" 4 2 2 "$TOPO_SMT2_MULTISOCKET" \
    || falha "layout multissocket SMT2 válido: $CPU_LAYOUT_ERRO"
[ "$CPU_LAYOUT_ONLINE" = "0,1,2,3,4,5,6,7" ] \
    || falha "normalização do conjunto online"
esperar_falha "siblings intercalados na topologia virtual" validar_layout_cpu \
    "0,1,4,5" "2,6,3,7" 4 2 2 "$TOPO_SMT2_MULTISOCKET"

TOPO_ESPARSA=$'0,0,0,0,Y\n2,0,0,0,Y\n4,1,0,0,Y\n6,1,0,0,Y\n8,2,0,0,N'
validar_layout_cpu "0,2" "4,6" 2 1 2 "$TOPO_ESPARSA" \
    || falha "IDs esparsos válidos: $CPU_LAYOUT_ERRO"
esperar_falha "CPU offline" validar_layout_cpu "0,8" "2,4,6" 2 1 2 "$TOPO_ESPARSA"
esperar_falha "sobreposição VM/host" validar_layout_cpu "0,2" "2,4,6" 2 1 2 "$TOPO_ESPARSA"
esperar_falha "CPU online omitida" validar_layout_cpu "0,2" "4" 2 1 2 "$TOPO_ESPARSA"
esperar_falha "core físico dividido" validar_layout_cpu "0,4" "2,6" 2 1 2 "$TOPO_ESPARSA"
esperar_falha "produto de topologia divergente" validar_layout_cpu "0,2" "4,6" 2 2 2 "$TOPO_ESPARSA"

cmdline_parametros_exatos "default_hugepagesz=1G hugepagesz=1G hugepages=4" \
    "quiet default_hugepagesz=1G hugepagesz=1G hugepages=4 splash" \
    || falha "cmdline exata: $CMDLINE_PARAM_ERRO"
esperar_falha "chave de cmdline duplicada" cmdline_parametros_exatos \
    "hugepages=4" "quiet hugepages=4 hugepages=8"
esperar_falha "valor de cmdline divergente" cmdline_parametros_exatos \
    "hugepages=4" "quiet hugepages=8"
[ "$(_parametros_por_chaves_cmdline 'quiet hugepagesz=1G hugepages=4' 'hugepagesz hugepages')" = \
  "hugepagesz=1G hugepages=4" ] || falha "extração por chave"
esperar_falha "persistência ambígua por chave" _parametros_por_chaves_cmdline \
    "quiet hugepages=4 hugepages=8" "hugepages"

TMPDIR_TESTE="$(mktemp -d)"
trap 'rm -rf -- "$TMPDIR_TESTE"' EXIT
ORIGINAL="$TMPDIR_TESTE/original.xml"
CANDIDATO="$TMPDIR_TESTE/candidato.xml"
RECONFIGURADO="$TMPDIR_TESTE/reconfigurado.xml"
SEM_HUGE="$TMPDIR_TESTE/sem-huge.xml"
INVALIDO="$TMPDIR_TESTE/invalido.xml"
HOTPLUG="$TMPDIR_TESTE/hotplug.xml"
cat > "$ORIGINAL" <<'XML'
<domain type='kvm'>
  <name>fixture</name>
  <memory unit='MiB'>4096</memory>
  <currentMemory unit='MiB'>4096</currentMemory>
  <vcpu placement='static'>4</vcpu>
  <cputune>
    <shares>2048</shares>
    <iothreadpin iothread='1' cpuset='2'/>
    <vcpupin vcpu='0' cpuset='7'/>
  </cputune>
  <memoryBacking><locked/></memoryBacking>
  <os><type arch='x86_64'>hvm</type></os>
  <features><acpi/></features>
  <cpu mode='host-model'><feature policy='require' name='topoext'/></cpu>
  <clock offset='localtime'/>
  <devices/>
</domain>
XML

cp -- "$ORIGINAL" "$HOTPLUG"
python3 - "$HOTPLUG" <<'PY'
import sys
import xml.etree.ElementTree as ET
path = sys.argv[1]
tree = ET.parse(path)
root = tree.getroot()
node = ET.Element('vcpus')
ET.SubElement(node, 'vcpu', {'id': '0', 'enabled': 'yes', 'hotpluggable': 'no', 'order': '1'})
root.insert(list(root).index(root.find('cputune')), node)
tree.write(path, encoding='utf-8', xml_declaration=True)
PY
# I9.12-D11: as chamadas ganharam o nono argumento (MEMORIA_MODO) e o validador
# trocou `sim` por `1g`. Os casos herdados usam hugetlb-1g porque era o que a
# operação fazia fixo até `af07725`, então o XML esperado é o mesmo de antes.
esperar_falha "metadados vcpus/hotplug" xml_cpu_gerar_candidato \
    "$HOTPLUG" "$TMPDIR_TESTE/hotplug-candidato.xml" "0-1,4-5" "2-3,6-7" 4 2 2 4096 hugetlb-1g
esperar_falha "modo de memória ausente" xml_cpu_gerar_candidato \
    "$ORIGINAL" "$TMPDIR_TESTE/sem-modo.xml" "0-1,4-5" "2-3,6-7" 4 2 2 4096
esperar_falha "modo de memória removido em D8" xml_cpu_gerar_candidato \
    "$ORIGINAL" "$TMPDIR_TESTE/modo-legado.xml" "0-1,4-5" "2-3,6-7" 4 2 2 4096 hugetlb-1g-boot

xml_cpu_gerar_candidato "$ORIGINAL" "$CANDIDATO" "0-1,4-5" "2-3,6-7" 4 2 2 4096 hugetlb-1g \
    || falha "geração do XML candidato: $XML_CPU_ERRO"
validar_xml_cpu_pinning "$CANDIDATO" "0-1,4-5" "2-3,6-7" 4 2 2 4096 1g \
    || falha "validação do XML candidato: $XML_CPU_ERRO"
python3 - "$CANDIDATO" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
cputune = root.find('cputune')
assert cputune is not None
assert cputune.find('shares').text == '2048'
assert cputune.find('iothreadpin').attrib == {'iothread': '1', 'cpuset': '2'}
assert len(cputune.findall('vcpupin')) == 4
assert root.find('vcpus') is None
assert root.find('memoryBacking/locked') is not None
assert root.find("memoryBacking/hugepages/page").attrib == {'size': '1', 'unit': 'GiB'}
assert root.find("cpu/feature[@name='topoext']") is not None
PY

xml_cpu_gerar_candidato "$ORIGINAL" "$RECONFIGURADO" "0-1,4-5" "2-3,6-7" 4 2 2 8192 hugetlb-1g \
    || falha "reconfiguração de RAM no candidato: $XML_CPU_ERRO"
validar_xml_cpu_pinning "$RECONFIGURADO" "0-1,4-5" "2-3,6-7" 4 2 2 8192 1g \
    || falha "XML com RAM reconfigurada inválido: $XML_CPU_ERRO"
python3 - "$RECONFIGURADO" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
assert root.find('memory').text == '8192' and root.find('memory').get('unit') == 'MiB'
assert root.find('currentMemory').text == '8192' and root.find('currentMemory').get('unit') == 'MiB'
PY

cp -- "$CANDIDATO" "$INVALIDO"
python3 - "$INVALIDO" <<'PY'
import sys
import xml.etree.ElementTree as ET
path = sys.argv[1]
tree = ET.parse(path)
ET.SubElement(tree.getroot().find('cputune'), 'vcpupin', {'vcpu': '0', 'cpuset': '0'})
tree.write(path, encoding='utf-8', xml_declaration=True)
PY
esperar_falha "vcpupin duplicado" validar_xml_cpu_pinning \
    "$INVALIDO" "0-1,4-5" "2-3,6-7" 4 2 2 4096 1g
esperar_falha "RAM divergente" validar_xml_cpu_pinning \
    "$CANDIDATO" "0-1,4-5" "2-3,6-7" 4 2 2 8192 1g
esperar_falha "modo sim saiu do validador" validar_xml_cpu_pinning \
    "$CANDIDATO" "0-1,4-5" "2-3,6-7" 4 2 2 4096 sim

xml_cpu_remover_hugepages "$CANDIDATO" "$SEM_HUGE" \
    || falha "remoção de HugePages: $XML_CPU_ERRO"
validar_xml_cpu_pinning "$SEM_HUGE" "0-1,4-5" "2-3,6-7" 4 2 2 4096 nao \
    || falha "XML sem HugePages inválido: $XML_CPU_ERRO"
python3 - "$SEM_HUGE" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
assert root.find('memoryBacking/hugepages') is None
assert root.find('memoryBacking/locked') is not None
PY

# I9.12-D11: os dois modos que a fachada não sabia gerar antes.
DOIS_MEGAS="$TMPDIR_TESTE/candidato-2m.xml"
MEMORIA_NORMAL="$TMPDIR_TESTE/candidato-normal.xml"

xml_cpu_gerar_candidato "$ORIGINAL" "$DOIS_MEGAS" "0-1,4-5" "2-3,6-7" 4 2 2 4096 hugetlb-2m \
    || falha "geração do candidato em hugetlb-2m: $XML_CPU_ERRO"
validar_xml_cpu_pinning "$DOIS_MEGAS" "0-1,4-5" "2-3,6-7" 4 2 2 4096 2m \
    || falha "XML de 2 MiB recusado pelo próprio modo: $XML_CPU_ERRO"
python3 - "$DOIS_MEGAS" <<'XMLCHK'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
assert root.find("memoryBacking/hugepages/page").attrib == {'size': '2048', 'unit': 'KiB'}
assert root.find('memoryBacking/locked') is not None
assert len(root.findall('cputune/vcpupin')) == 4
XMLCHK
esperar_falha "recusa cruzada 2m contra 1g" validar_xml_cpu_pinning \
    "$DOIS_MEGAS" "0-1,4-5" "2-3,6-7" 4 2 2 4096 1g
esperar_falha "recusa cruzada 1g contra 2m" validar_xml_cpu_pinning \
    "$CANDIDATO" "0-1,4-5" "2-3,6-7" 4 2 2 4096 2m

# `normal` sobre um XML que exigia 1 GiB: a exigência sai no mesmo apply, e o
# memoryBacking sobrevive porque carrega <locked/> não gerenciado.
xml_cpu_gerar_candidato "$CANDIDATO" "$MEMORIA_NORMAL" "0-1,4-5" "2-3,6-7" 4 2 2 4096 normal \
    || falha "geração do candidato em normal: $XML_CPU_ERRO"
validar_xml_cpu_pinning "$MEMORIA_NORMAL" "0-1,4-5" "2-3,6-7" 4 2 2 4096 nao \
    || falha "XML sem HugePages recusado no modo normal: $XML_CPU_ERRO"
python3 - "$MEMORIA_NORMAL" <<'XMLCHK'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
assert root.find('memoryBacking/hugepages') is None
assert root.find('memoryBacking/locked') is not None
assert len(root.findall('cputune/vcpupin')) == 4
XMLCHK
esperar_falha "normal recusado como 1g" validar_xml_cpu_pinning \
    "$MEMORIA_NORMAL" "0-1,4-5" "2-3,6-7" 4 2 2 4096 1g

# --desfazer precisa encerrar main, nunca cair novamente no fluxo de aplicação.
(
    source "$RAIZ/etapas/52-cpu-pinning-hugepages.sh"
    carregar_conf() { :; }
    desfazer() { :; }
    exigir_nao_root() { exit 91; }
    main --desfazer
) || falha "52 --desfazer caiu no fluxo de aplicação"
(
    source "$RAIZ/etapas/53-cpu-isolation.sh"
    carregar_conf() { :; }
    desfazer() { :; }
    exigir_nao_root() { exit 92; }
    main --desfazer
) || falha "53 --desfazer caiu no fluxo de aplicação"

# A etapa 53 recusa a CPU de boot antes de consultar/mutar qualquer estado.
(
    source "$RAIZ/etapas/53-cpu-isolation.sh"
    CPUS_VM="0,2"
    if validar_suporte_isolamento; then
        exit 1
    fi
    [[ "$SUPORTE_ISOLAMENTO_ERRO" == *"CPU 0"* ]]
) || falha "CPU 0 não foi bloqueada no isolamento"

# Atualização relacional do conf é publicada em um único lote.
(
    CONF_ARQUIVO="$TMPDIR_TESTE/passthrough.conf"
    cat > "$CONF_ARQUIVO" <<'CONF'
CPUS_VM="0"
CPUS_HOST="1"
VM_CORES="1"
VM_THREADS="1"
VM_VCPUS="1"
CONF
    salvar_conf_lote CPUS_VM "2,6" CPUS_HOST "0,4" VM_CORES "1" VM_THREADS "2" VM_VCPUS "2"
    carregar_conf
    [ "$CPUS_VM" = "2,6" ] && [ "$CPUS_HOST" = "0,4" ] \
        && [ "$VM_CORES" = 1 ] && [ "$VM_THREADS" = 2 ] && [ "$VM_VCPUS" = 2 ]
) || falha "atualização atômica do conjunto CPU no conf"

# Double de kernelstub: saneia duplicatas e restaura o snapshot quando a
# inclusão falha, sem acessar /boot ou sudo real.
(
    ESTADO="$TMPDIR_TESTE/kernelstub-state"
    FALHAR_UMA_VEZ="$TMPDIR_TESTE/kernelstub-fail-once"
    printf '%s\n' 'hugepages=8 hugepages=16' > "$ESTADO"
    _kernelstub_parametros_para_mutacao() { cat -- "$ESTADO"; }
    kernel_parametros_persistentes_exatos() { [ "$(< "$ESTADO")" = "$1" ]; }
    kernel_param_chaves_persistentes_ausentes() { [ ! -s "$ESTADO" ]; }
    sudo() {
        [ "$1" = kernelstub ] || return 99
        case "$2" in
            -d) : > "$ESTADO" ;;
            -a)
                if [ -e "$FALHAR_UMA_VEZ" ]; then
                    rm -f -- "$FALHAR_UMA_VEZ"
                    return 1
                fi
                printf '%s\n' "$3" > "$ESTADO"
                ;;
            *) return 98 ;;
        esac
    }
    _kernelstub_aplicar_estado "hugepages" "hugepages=4" \
        || exit 1
    [ "$(< "$ESTADO")" = "hugepages=4" ] || exit 1

    printf '%s\n' 'hugepages=8 hugepages=16' > "$ESTADO"
    : > "$FALHAR_UMA_VEZ"
    if _kernelstub_aplicar_estado "hugepages" "hugepages=4"; then
        exit 1
    fi
    [ "$(< "$ESTADO")" = "hugepages=8 hugepages=16" ]
) || falha "transação/rollback do kernelstub"

# Double completo do GRUB: recovery sem DEFAULT é aceita, grub.cfg stale é
# regenerado e sinal após o mv restaura a fonte antes de sair.
(
    GRUB_DEFAULT_ARQUIVO="$TMPDIR_TESTE/grub-default"
    GRUB_CFG_ARQUIVO="$TMPDIR_TESTE/grub.cfg"
    FALHAR_UPDATE="$TMPDIR_TESTE/grub-fail-update"
    SINALIZAR_MV="$TMPDIR_TESTE/grub-signal-mv"
    cat > "$GRUB_DEFAULT_ARQUIVO" <<'GRUB'
GRUB_CMDLINE_LINUX_DEFAULT="quiet hugepages=8"
GRUB_CMDLINE_LINUX=""
GRUB
    gerar_cfg_fake() {
        local params
        params="$(_grub_cmdline_atual)" || return 1
        printf 'menuentry normal {\n linux /vmlinuz root=/dev/test %s\n}\n' "$params" > "$GRUB_CFG_ARQUIVO"
        printf 'menuentry recovery {\n linux /vmlinuz root=/dev/test recovery nomodeset\n}\n' >> "$GRUB_CFG_ARQUIVO"
    }
    sudo() {
        if [ "${1:-}" = -n ]; then shift; fi
        case "${1:-}" in
            update-grub)
                if [ -e "$FALHAR_UPDATE" ]; then
                    rm -f -- "$FALHAR_UPDATE"
                    return 1
                fi
                gerar_cfg_fake
                ;;
            cp|tee|rm|cmp) command "$@" ;;
            mv)
                command "$@" || return
                if [ -e "$SINALIZAR_MV" ]; then
                    rm -f -- "$SINALIZAR_MV"
                    kill -TERM "$BASHPID"
                fi
                ;;
            awk) command "$@" ;;
            *) return 97 ;;
        esac
    }
    gerar_cfg_fake
    _grub_aplicar_cmdline "quiet hugepages=4" "hugepages=4" exato
    _grub_cfg_parametros_exatos "hugepages=4" \
        || exit 1
    grep -q 'recovery nomodeset' "$GRUB_CFG_ARQUIVO" || exit 1

    # Fonte limpa + cfg antigo: DEL precisa regenerar mesmo sem editar a linha.
    cat > "$GRUB_DEFAULT_ARQUIVO" <<'GRUB'
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX=""
GRUB
    printf ' linux /vmlinuz root=/dev/test quiet hugepages=4\n' > "$GRUB_CFG_ARQUIVO"
    BOOTLOADER=grub
    kernel_param_del "hugepages"
    _grub_cfg_chaves_ausentes "hugepages" || exit 1

    # Sinal após instalar a fonte candidata: o trap local precisa restaurar.
    cat > "$GRUB_DEFAULT_ARQUIVO" <<'GRUB'
GRUB_CMDLINE_LINUX_DEFAULT="quiet hugepages=8"
GRUB_CMDLINE_LINUX=""
GRUB
    gerar_cfg_fake
    cp -- "$GRUB_DEFAULT_ARQUIVO" "$TMPDIR_TESTE/grub-before-signal"
    : > "$SINALIZAR_MV"
    RC_SINAL=0
    ( _grub_aplicar_cmdline "quiet hugepages=4" "hugepages=4" exato ) || RC_SINAL=$?
    # I5: o código do sinal é contrato. Antes, a transação do GRUB colapsava
    # 130/143 em 1 e a etapa acima dela não conseguia distinguir interrupção de
    # falha comum; a campanha I0 da etapa 30 passou a exigir 130/143.
    [ "$RC_SINAL" -eq 143 ] || exit 1
    cmp -s -- "$TMPDIR_TESTE/grub-before-signal" "$GRUB_DEFAULT_ARQUIVO" || exit 1
    _grub_cfg_parametros_exatos "hugepages=8"
) || falha "transação, recovery ou convergência do GRUB"

# Matriz da coordenação entre isolamento ativo e persistente.
(
    source "$RAIZ/etapas/52-cpu-pinning-hugepages.sh"
    CPUS_VM="2,6"
    ATIVO=ausente
    PERSISTENTE=ausente
    cmdline_parametros_exatos() { [ "$ATIVO" = exato ]; }
    cmdline_possui_alguma_chave() { [ "$ATIVO" = divergente ]; }
    kernel_parametros_persistentes_exatos() { [ "$PERSISTENTE" = exato ]; }
    kernel_param_chaves_persistentes_ausentes() { [ "$PERSISTENTE" = ausente ]; }
    validar_isolamento_compativel || exit 1
    ATIVO=exato; PERSISTENTE=exato
    validar_isolamento_compativel || exit 1
    ATIVO=exato; PERSISTENTE=ausente
    if validar_isolamento_compativel; then exit 1; fi
    ATIVO=divergente; PERSISTENTE=exato
    if validar_isolamento_compativel; then exit 1; fi
) || falha "matriz de isolamento antigo/pendente"

# A validação integral do candidato deve ocorrer antes de qualquer SET de boot.
FAKE_HELP_VIRSH="$TMPDIR_TESTE/fake-help-virsh"
ORDEM_FASES="$TMPDIR_TESTE/ordem-fases"
cat > "$FAKE_HELP_VIRSH" <<'SH'
#!/bin/bash
[ "${1:-}" = help ] && { echo 'define --validate'; exit 0; }
exit 64
SH
chmod +x "$FAKE_HELP_VIRSH"
(
    source "$RAIZ/etapas/52-cpu-pinning-hugepages.sh"
    carregar_conf() {
        VM_NAME=fixture; CPUS_VM="2,6"; CPUS_HOST="0,4"
        VM_CORES=1; VM_THREADS=2; VM_VCPUS=2; VM_RAM_MB=4096
        HUGEPAGES_1G=4; BOOTLOADER=grub
    }
    exigir_nao_root() { :; }
    exigir_sudo() { :; }
    exigir_comando() { :; }
    exigir_conf() { :; }
    exigir_vm_desligada() { :; }
    # I5: além do layout, a validação publica o fingerprint da topologia, que a
    # revalidação TOCTOU exige antes de qualquer mutação de boot ou XML.
    validar_configuracao() { CPU_LAYOUT_ONLINE="0,2,4,6"; TOPOLOGIA_FINGERPRINT=fixture; }
    exigir_topologia_inalterada() { echo topologia >> "$ORDEM_FASES"; }
    validar_suporte_1g() { :; }
    preparar_xml_candidato() { echo candidate >> "$ORDEM_FASES"; }
    validar_isolamento_compativel() { :; }
    confirmar() { return 0; }
    CONTAGEM_PERSISTENCIA=0
    kernel_parametros_persistentes_exatos() {
        CONTAGEM_PERSISTENCIA=$((CONTAGEM_PERSISTENCIA + 1))
        [ "$CONTAGEM_PERSISTENCIA" -gt 1 ]
    }
    kernel_param_add() { echo boot >> "$ORDEM_FASES"; }
    pedir_reboot() { :; }
    VIRSH="$FAKE_HELP_VIRSH"
    main
) || falha "fluxo faseado com doubles"
[ "$(paste -sd, "$ORDEM_FASES")" = "candidate,topologia,boot" ] \
    || falha "boot foi chamado antes da validação do candidato ou sem revalidar a topologia"

# Double de virsh: uma falha após define deve reinstalar e comprovar o XML
# original. O fake só copia fixtures no diretório temporário.
FAKE_VIRSH="$TMPDIR_TESTE/fake-virsh"
FAKE_STATE="$TMPDIR_TESTE/fake-domain.xml"
ROLLBACK_ORIGINAL="$TMPDIR_TESTE/rollback-original.xml"
ROLLBACK_BACKUP="$TMPDIR_TESTE/rollback-backup.xml"
cp -- "$ORIGINAL" "$ROLLBACK_ORIGINAL"
cp -- "$ORIGINAL" "$ROLLBACK_BACKUP"
cp -- "$CANDIDATO" "$FAKE_STATE"
cat > "$FAKE_VIRSH" <<'SH'
#!/bin/bash
set -euo pipefail
case "$1" in
    define)
        [ "$2" = "--validate" ]
        cp -- "$3" "$FAKE_STATE"
        ;;
    dumpxml)
        cat -- "$FAKE_STATE"
        ;;
    *) exit 64 ;;
esac
SH
chmod +x "$FAKE_VIRSH"
export FAKE_STATE
if (
    source "$RAIZ/etapas/52-cpu-pinning-hugepages.sh"
    VIRSH="$FAKE_VIRSH"
    VM_NAME=fixture
    XML_ORIGINAL="$ROLLBACK_ORIGINAL"
    XML_CANDIDATO="$TMPDIR_TESTE/rollback-candidate.xml"
    XML_POS="$TMPDIR_TESTE/rollback-post.xml"
    XML_MUTACAO_POSSIVEL=1
    TRANSACAO_OK=0
    finalizar_transacao 1
); then
    falha "finalizador deveria preservar o status de falha"
fi
cmp -s -- "$ROLLBACK_BACKUP" "$FAKE_STATE" \
    || falha "rollback XML não restaurou o domínio original"

grep -Fq '52-cpu-pinning-hugepages.sh|CPU pinning e HugePages|opcional|' "$RAIZ/menu.sh" \
    || falha "etapa 52 não está opcional"
grep -Fq '53-cpu-isolation.sh|CPU isolation|opcional|' "$RAIZ/menu.sh" \
    || falha "etapa 53 não está opcional"
# I5: a reserva do core da CPU 0 deixou de ser uma linha do planner em Bash e
# passou a ser propriedade do core Python. A verificação virou comportamental,
# no lugar do antigo grep por 'LISTA_HOST="${NUCLEO_THREADS[$CHAVE_CPU_BOOT]}"'.
cpu_plano_pinning "$TOPO_SMT2_MULTISOCKET" 3 \
    || falha "plano de pinning com 3 cores recusado: $CPU_PLANO_ERRO"
[ "$CPUPLANO_BOOT_CORE_CPUS" = "0,4" ] \
    || falha "core de housekeeping da CPU 0 não foi identificado"
[ "$CPUPLANO_CPUS_HOST" = "0,4" ] \
    || falha "o planner não reservou o core da CPU 0 para o host"
case ",$CPUPLANO_CPUS_VM," in
    *,0,*|*,4,*) falha "o planner entregou o core de housekeeping à VM" ;;
esac

echo "CPU_HUGEPAGES_TESTS_OK"
