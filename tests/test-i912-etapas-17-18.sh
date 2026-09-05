#!/usr/bin/env bash
# Gate dirigido I9.12 (REQ-VM-RESOURCE-LIFECYCLE): o contrato NOVO das etapas
# 17 e 18, provado por doubles, sem sudo, sem virsh real e sem tocar o boot.
#
# Por que esta suíte existe, e o que ela protege:
#
#   * a etapa 17 mudou de contrato em I9.12-D10: ela aplica SOMENTE o XML,
#     dirigida por MEMORIA_MODO, e nunca mais grava parâmetro de HugePages no
#     boot. Um defeito aqui não deixa a VM lenta: ele devolve o host ao estado
#     que o requisito trata como defeito — RAM fora da memória comum com a VM
#     desligada — e o `--verificar` passaria a EMPURRAR o operador para lá,
#     porque é o status do menu que ele lê.
#   * a etapa 18 recusa isolamento persistente por padrão desde `10f5e52`
#     (03/09/2026) e NUNCA teve teste dirigido. A auditoria de 03/09 registrou
#     isso como "código CONFORME, prova AUSENTE" — esta suíte fecha a lacuna,
#     que é a pendência 1 de I9.12.
#   * em ambas, a inversão é a parte perigosa: AUSÊNCIA de reserva e AUSÊNCIA
#     de isolamento passaram a ser pós-condição de SUCESSO. Cada caso abaixo
#     que prova `rc 0` carrega junto o oráculo anterior, para que uma reversão
#     silenciosa reprove com o nome do que quebrou.
#
# ---------------------------------------------------------------------------
# MECÂNICA (mesma de tests/test-cpu-hugepages.sh, seção dos doubles)
#
# A etapa é carregada com `source` dentro de um SUBSHELL, e as funções que
# tocam host, privilégio ou libvirt são sobrescritas ali. `main` só roda com
# BASH_SOURCE == $0, então o `source` não dispara nada. `verificar` termina em
# `v_fim`, que faz `exit` com o status público 0/1/2/3 e imprime o sentinel
# quando V_STATUS_TOKEN está definido — os dois são conferidos, porque rc sem
# sentinel não prova que o verificador chegou deliberadamente ao fim.
#
# O XML é REAL: os candidatos saem de `xml_cpu_gerar_candidato`, e
# `validar_xml_cpu_pinning` roda de verdade contra o núcleo Python. É isso que
# faz o caso 3 (página de tamanho errado) provar alguma coisa.
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$RAIZ/lib/common.sh"

CASOS=0
falha() { echo "FALHA I9.12 (etapas 17/18): $*" >&2; exit 1; }
passo() { CASOS=$((CASOS + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/i912-etapas.XXXXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

TOKEN='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
SENTINEL_PREFIXO='__PASSTHROUGH_STATUS_V1__:'

# `virt-xml-validate` pode não existir no host de desenvolvimento, e o
# verificador o exige por `v_exigir_comando`. O double abaixo entra no PATH da
# suíte inteira: ele aprova qualquer XML, porque quem julga conteúdo aqui é o
# núcleo Python, não o schema do libvirt.
BIN_FALSO="$TMP/bin"
mkdir -p "$BIN_FALSO"
cat > "$BIN_FALSO/virt-xml-validate" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$BIN_FALSO/virt-xml-validate"
PATH="$BIN_FALSO:$PATH"
export PATH

# --- Fixtures de XML --------------------------------------------------------
# Um domínio mínimo com conteúdo NÃO gerenciado (shares, iothreadpin, locked),
# igual ao de tests/test-cpu-hugepages.sh: preservá-lo é contrato, e um XML
# estéril não provaria isso.
ORIGINAL="$TMP/original.xml"
cat > "$ORIGINAL" <<'XML'
<domain type='kvm'>
  <name>fixture</name>
  <memory unit='MiB'>4096</memory>
  <currentMemory unit='MiB'>4096</currentMemory>
  <vcpu placement='static'>4</vcpu>
  <cputune>
    <shares>2048</shares>
    <iothreadpin iothread='1' cpuset='2'/>
  </cputune>
  <memoryBacking><locked/></memoryBacking>
  <os><type arch='x86_64'>hvm</type></os>
  <features><acpi/></features>
  <cpu mode='host-model'><feature policy='require' name='topoext'/></cpu>
  <clock offset='localtime'/>
  <devices/>
</domain>
XML

CPUS_VM_FIXTURE="0-1,4-5"
CPUS_HOST_FIXTURE="2-3,6-7"
RAM_FIXTURE=4096

XML_NORMAL="$TMP/xml-normal.xml"
XML_2M="$TMP/xml-2m.xml"
XML_1G="$TMP/xml-1g.xml"
for par in "normal:$XML_NORMAL" "hugetlb-2m:$XML_2M" "hugetlb-1g:$XML_1G"; do
    xml_cpu_gerar_candidato "$ORIGINAL" "${par#*:}" \
        "$CPUS_VM_FIXTURE" "$CPUS_HOST_FIXTURE" 4 2 2 "$RAM_FIXTURE" "${par%%:*}" \
        || falha "não foi possível gerar a fixture de XML em ${par%%:*}: $XML_CPU_ERRO"
done
passo

# --- Runner do --verificar --------------------------------------------------
# verificar_etapa ARQUIVO_DA_ETAPA ARQUIVO_XML PRELUDIO...
# O PRELÚDIO é código shell avaliado DENTRO do subshell, depois dos doubles
# comuns: é onde cada caso encena o seu cenário.
VERIFICAR_SAIDA=""
VERIFICAR_RC=0
verificar_etapa() {
    local etapa="$1" xml="$2" prelude="$3"
    VERIFICAR_RC=0
    VERIFICAR_SAIDA="$(
        set +e
        (
            set -euo pipefail
            source "$RAIZ/etapas/$etapa"
            V_STATUS_TOKEN="$TOKEN"

            # --- doubles comuns: host, privilégio e libvirt ------------------
            VM_NAME=fixture
            CPUS_VM="$CPUS_VM_FIXTURE"
            CPUS_HOST="$CPUS_HOST_FIXTURE"
            VM_VCPUS=4; VM_CORES=2; VM_THREADS=2; VM_RAM_MB="$RAM_FIXTURE"
            BOOTLOADER=grub

            v_exigir_comando() { return 0; }
            vm_existe_estado() { return 0; }
            validar_configuracao() { CPU_LAYOUT_ONLINE="0,1,2,3,4,5,6,7"; TOPOLOGIA_FINGERPRINT=fixture; return 0; }
            validar_layout_configurado() { CPU_LAYOUT_ONLINE="0,1,2,3,4,5,6,7"; return 0; }
            validar_suporte_isolamento() { return 0; }
            validar_isolamento_compativel() { return 0; }
            validar_pinning_vm() { return 0; }
            isolamento_efetivo_exato() { return 0; }
            memoria_politica_viavel() { MEMORIA_PAGINAS=2048; MEMORIA_PAGE_KB=2048; return 0; }
            # Boot limpo por padrão; cada caso reencena o que precisar.
            cmdline_possui_alguma_chave() { return 1; }
            cmdline_parametros_exatos() { return 0; }
            kernel_param_chaves_persistentes_ausentes() { return 0; }
            kernel_parametros_persistentes_exatos() { return 0; }
            # O "virsh" desta suíte responde só a dumpxml, com o XML do caso.
            VIRSH_XML="$xml"
            VIRSH() {
                case "${1:-}" in
                    dumpxml) cat -- "$VIRSH_XML" ;;
                    *) return 64 ;;
                esac
            }
            VIRSH=VIRSH

            eval "$prelude"
            verificar
        ) 2>&1
    )" || VERIFICAR_RC=$?
    printf '%s\n' "$VERIFICAR_SAIDA" \
        | grep -Fq "${SENTINEL_PREFIXO}${TOKEN}:${VERIFICAR_RC}" \
        || falha "o verificador de $etapa saiu antes de v_fim ou publicou status divergente: rc=$VERIFICAR_RC saída=$VERIFICAR_SAIDA"
}

exige_rc() {
    local esperado="$1" descricao="$2"
    [ "$VERIFICAR_RC" -eq "$esperado" ] \
        || falha "$descricao: esperado rc=$esperado, obtido rc=$VERIFICAR_RC. Saída:\n$VERIFICAR_SAIDA"
}

exige_texto() {
    local trecho="$1" descricao="$2"
    printf '%s\n' "$VERIFICAR_SAIDA" | grep -Fq -- "$trecho" \
        || falha "$descricao: a saída não contém '$trecho'. Saída:\n$VERIFICAR_SAIDA"
}

exige_sem_texto() {
    local trecho="$1" descricao="$2"
    printf '%s\n' "$VERIFICAR_SAIDA" | grep -Fq -- "$trecho" \
        && falha "$descricao: a saída não devia conter '$trecho'. Saída:\n$VERIFICAR_SAIDA"
    return 0
}

# ===========================================================================
# A. Etapa 17: --verificar dirigido pela política
# ===========================================================================

# A1: modo normal, XML sem hugepages, boot limpo. Este é o host que o requisito
# quer, e até `af07725` ele era relatado como DIVERGENTE, porque o verificador
# exigia HugePages_Total igual a HUGEPAGES_1G.
verificar_etapa 52-cpu-pinning-hugepages.sh "$XML_NORMAL" '
    MEMORIA_MODO=normal
'
exige_rc 0 'A1 modo normal com XML e boot limpos'
exige_texto 'MEMORIA_MODO=normal' 'A1'
exige_texto 'NÃO exige HugePages' 'A1'
exige_texto 'o perfil é retornável' 'A1'
passo

# A2: hugetlb-2m com a página de 2 MiB declarada no XML. A prova de página de
# 2 MiB não existia até I9.12-D11: o verificador emitia um v_indeterminado
# permanente dizendo que ela "ainda não existe".
verificar_etapa 52-cpu-pinning-hugepages.sh "$XML_2M" '
    MEMORIA_MODO=hugetlb-2m
'
exige_rc 0 'A2 hugetlb-2m com página de 2 MiB'
exige_texto 'página de 2 MiB exatos' 'A2'
exige_texto 'serão adquiridas no start e devolvidas no stop' 'A2'
exige_sem_texto 'ainda não existe' 'A2'
passo

# A3: hugetlb-1g, o outro modo de runtime, com a página que lhe corresponde.
verificar_etapa 52-cpu-pinning-hugepages.sh "$XML_1G" '
    MEMORIA_MODO=hugetlb-1g
'
exige_rc 0 'A3 hugetlb-1g com página de 1 GiB'
exige_texto 'página de 1 GiB exatos' 'A3'
passo

# A4: hugetlb-2m com XML de 1 GiB. Com o vocabulário antigo (`sim`/`nao`) isto
# era INEXPRIMÍVEL: os dois tamanhos caíam em "sim" e o XML errado passava.
verificar_etapa 52-cpu-pinning-hugepages.sh "$XML_1G" '
    MEMORIA_MODO=hugetlb-2m
'
exige_rc 1 'A4 hugetlb-2m com XML de 1 GiB'
exige_texto 'não tem exatamente 2 MiB' 'A4'
passo

# A4b: e o cruzamento inverso, para que o caso acima não passe por um "recusa
# sempre".
verificar_etapa 52-cpu-pinning-hugepages.sh "$XML_2M" '
    MEMORIA_MODO=hugetlb-1g
'
exige_rc 1 'A4b hugetlb-1g com XML de 2 MiB'
exige_texto 'não tem exatamente 1 GiB' 'A4b'
passo

# A4c: modo normal com XML que ainda exige HugePages. É o host meio migrado, e
# relatar sucesso aqui deixaria a VM sem subir por falta de pool.
verificar_etapa 52-cpu-pinning-hugepages.sh "$XML_1G" '
    MEMORIA_MODO=normal
'
exige_rc 1 'A4c modo normal com XML exigindo HugePages'
exige_texto 'XML de CPU/HugePages incompleto ou divergente' 'A4c'
passo

# A5: MEMORIA_MODO vazio. O requisito proíbe padrão silencioso: a etapa não
# pode assumir `normal` só porque é o baseline.
verificar_etapa 52-cpu-pinning-hugepages.sh "$XML_NORMAL" '
    MEMORIA_MODO=""
'
exige_rc 1 'A5 política não decidida'
exige_texto 'MEMORIA_MODO não decidido' 'A5'
exige_texto 'etapa 3' 'A5'
passo

# A5b: valor fora do catálogo é ERRO de configuração (rc 3), não pendência:
# reexecutar a etapa não conserta um literal inválido. `hugetlb-1g-boot` cai
# aqui desde I9.12-D8, e é a prova de que o perfil saiu.
verificar_etapa 52-cpu-pinning-hugepages.sh "$XML_1G" '
    MEMORIA_MODO=hugetlb-1g-boot
'
exige_rc 3 'A5b perfil removido em D8'
exige_texto 'MEMORIA_MODO com valor fora do formato aceito' 'A5b'
passo

# A6: chave de HugePages na cmdline encenada, em QUALQUER modo. O ramo do
# perfil legado saiu do `case` em I9.12-D8: agora presença é sempre resíduo.
for modo in normal hugetlb-2m hugetlb-1g; do
    case "$modo" in
        normal) xml_do_modo="$XML_NORMAL" ;;
        hugetlb-2m) xml_do_modo="$XML_2M" ;;
        *) xml_do_modo="$XML_1G" ;;
    esac
    verificar_etapa 52-cpu-pinning-hugepages.sh "$xml_do_modo" "
        MEMORIA_MODO=$modo
        cmdline_possui_alguma_chave() { return 0; }
    "
    exige_rc 1 "A6 chave de HugePages no boot com modo '$modo'"
    exige_texto 'ainda reserva HugePages no boot' "A6 modo '$modo'"
    exige_texto 'rode --desfazer e reinicie' "A6 modo '$modo'"
    passo
done

# A6b: o mesmo pela persistência, com a cmdline deste boot já limpa. Sem esta
# ponta, um host cuja remoção não foi persistida seria relatado como correto e
# voltaria ao defeito no próximo boot.
verificar_etapa 52-cpu-pinning-hugepages.sh "$XML_NORMAL" '
    MEMORIA_MODO=normal
    kernel_param_chaves_persistentes_ausentes() { KERNEL_PERSISTENCIA_ERRO="chave presente em /etc/default/grub"; return 1; }
'
exige_rc 1 'A6b ausência persistente não comprovada'
exige_texto 'Ausência persistente de HugePages não comprovada' 'A6b'
passo

# A7: REGRESSÃO EXPLÍCITA da chave depreciada. Até `af07725`, HUGEPAGES_1G
# vazio era relatado como pendência (`v_var_definida HUGEPAGES_1G`) e
# preenchido era relatado como "resíduo legado" — ou seja, não existia valor
# que passasse no modo normal, e o `--verificar` nunca chegava a 0. Hoje a
# etapa não lê a chave: o rc não pode depender dela.
verificar_etapa 52-cpu-pinning-hugepages.sh "$XML_NORMAL" '
    MEMORIA_MODO=normal
    HUGEPAGES_1G=22
'
exige_rc 0 'A7 HUGEPAGES_1G preenchida não muda o veredicto'
exige_sem_texto 'resíduo' 'A7'
exige_sem_texto 'HUGEPAGES_1G' 'A7'
passo

verificar_etapa 52-cpu-pinning-hugepages.sh "$XML_NORMAL" '
    MEMORIA_MODO=normal
    HUGEPAGES_1G=""
'
exige_rc 0 'A7b HUGEPAGES_1G vazia não muda o veredicto'
exige_sem_texto 'HUGEPAGES_1G' 'A7b'
passo

# A8: recusa da política de memória continua sendo pendência de verdade. Sem
# este caso, "rc 0 sempre" passaria por A1 a A3.
verificar_etapa 52-cpu-pinning-hugepages.sh "$XML_2M" '
    MEMORIA_MODO=hugetlb-2m
    memoria_politica_viavel() { MEMORIA_POLITICA_ERRO="pool de 2048 kB ausente"; return 1; }
'
exige_rc 1 'A8 política inviável'
exige_texto 'não é viável' 'A8'
passo

# ===========================================================================
# B. Etapa 17: o apply não toca no boot
# ===========================================================================
#
# A ordem já é provada em tests/test-cpu-hugepages.sh; o que falta aqui é a
# afirmação estática que sobrevive a qualquer refatoração do fluxo: a etapa
# inteira tem UM único ponto que escreve chave de boot, e ele está dentro de
# `desfazer`. Um `kernel_param_add` reintroduzido em qualquer lugar reprova.
ETAPA17="$RAIZ/etapas/52-cpu-pinning-hugepages.sh"
grep -n 'kernel_param_add' "$ETAPA17" \
    && falha 'a etapa 17 voltou a ter kernel_param_add; o apply não pode gravar parâmetro de boot (I9.12-D10)'
passo

LINHA_DESFAZER=$(grep -n '^desfazer() {' "$ETAPA17" | head -1 | cut -d: -f1)
LINHA_MAIN=$(grep -n '^main() {' "$ETAPA17" | head -1 | cut -d: -f1)
[ -n "$LINHA_DESFAZER" ] && [ -n "$LINHA_MAIN" ] \
    || falha 'não foi possível localizar desfazer() e main() na etapa 17'
[ "$LINHA_DESFAZER" -lt "$LINHA_MAIN" ] \
    || falha 'a ordem de desfazer()/main() mudou; a asserção de faixa abaixo perdeu o sentido'
awk -v ini="$LINHA_DESFAZER" -v fim="$LINHA_MAIN" \
    'NR > ini && NR < fim' "$ETAPA17" > "$TMP/corpo-desfazer.sh"
grep -q 'kernel_param_del' "$TMP/corpo-desfazer.sh" \
    || falha 'desfazer() deixou de remover as chaves de boot; ele é o ÚNICO caminho que pode tocá-las'
awk -v ini="$LINHA_MAIN" 'NR > ini' "$ETAPA17" > "$TMP/corpo-main.sh"
grep -q 'kernel_param_del' "$TMP/corpo-main.sh" \
    && falha 'main() passou a remover chave de boot; a remoção pertence só a --desfazer'
grep -q 'pedir_reboot' "$TMP/corpo-main.sh" \
    && falha 'main() da etapa 17 voltou a pedir reboot (I9.12-D10)'
passo

# ===========================================================================
# C. Etapa 18: perfil retornável (pendência 1 de I9.12)
# ===========================================================================

# C1: cmdline sem as três chaves e ausência persistente comprovada. Este é o
# caso que a árvore ANTERIOR a `10f5e52` relatava como divergência: o host
# correto era acusado de defeito e o menu empurrava o operador para um custo
# permanente. Hoje é sucesso, e o texto diz por quê.
verificar_etapa 53-cpu-isolation.sh "$XML_NORMAL" '
    cmdline_possui_alguma_chave() { return 1; }
    kernel_param_chaves_persistentes_ausentes() { return 0; }
'
exige_rc 0 'C1 ausência de isolamento é sucesso do perfil retornável'
exige_texto 'Nenhuma CPU sai do scheduler no boot' 'C1'
exige_texto 'o perfil é retornável' 'C1'
passo

# C1b: a mesma ausência, mas sem conseguir provar a persistência. Ausência não
# comprovada não é ausência: o próximo boot pode reintroduzir o isolamento.
verificar_etapa 53-cpu-isolation.sh "$XML_NORMAL" '
    cmdline_possui_alguma_chave() { return 1; }
    kernel_param_chaves_persistentes_ausentes() { KERNEL_PERSISTENCIA_ERRO="entradas divergentes"; return 1; }
'
[ "$VERIFICAR_RC" -ne 0 ] \
    || falha "C1b: ausência persistente não comprovada devia sair do sucesso. Saída:\n$VERIFICAR_SAIDA"
exige_texto 'Ausência persistente de isolamento não comprovada' 'C1b'
passo

# C2: as três chaves presentes e exatas. O contrato antigo continua valendo
# integralmente para quem escolheu esse perfil — o que muda é que ele passa a
# ser relatado como opt-in NÃO retornável, e não como o estado desejado.
verificar_etapa 53-cpu-isolation.sh "$XML_NORMAL" '
    cmdline_possui_alguma_chave() { return 0; }
    cmdline_parametros_exatos() { return 0; }
    kernel_parametros_persistentes_exatos() { return 0; }
    isolamento_efetivo_exato() { return 0; }
'
exige_rc 1 'C2 isolamento persistente aplicado'
exige_texto 'não voltam ao host quando a VM para' 'C2'
exige_texto 'use --desfazer para sair dele' 'C2'
exige_texto 'Perfil opt-in' 'C2'
passo

# C3: isolamento presente, mas divergente da configuração. Duas pendências,
# não uma: o perfil não é retornável E as chaves não batem.
verificar_etapa 53-cpu-isolation.sh "$XML_NORMAL" '
    cmdline_possui_alguma_chave() { return 0; }
    cmdline_parametros_exatos() { CMDLINE_PARAM_ERRO="isolcpus duplicado"; return 1; }
    kernel_parametros_persistentes_exatos() { return 0; }
    isolamento_efetivo_exato() { return 0; }
'
exige_rc 1 'C3 isolamento presente e divergente'
exige_texto 'Cmdline de isolamento divergente' 'C3'
passo

# ===========================================================================
# D. Etapa 18: o apply exige a saída digitada do perfil retornável
# ===========================================================================
#
# I9.12-D5: sair do perfil retornável se DIGITA. Um `s` de confirmação não
# serve, porque o custo é permanente para o host e a escolha precisa ficar
# explícita no log de ações.
ORDEM="$TMP/ordem-etapa18"

rodar_apply_18() { # rodar_apply_18 PRELUDIO -> rc no APPLY_RC
    local prelude="$1"
    : > "$ORDEM"
    APPLY_RC=0
    APPLY_SAIDA="$(
        set +e
        (
            set -euo pipefail
            source "$RAIZ/etapas/53-cpu-isolation.sh"
            carregar_conf() {
                VM_NAME=fixture
                CPUS_VM="'"$CPUS_VM_FIXTURE"'"
                CPUS_HOST="'"$CPUS_HOST_FIXTURE"'"
                VM_VCPUS=4; VM_CORES=2; VM_THREADS=2; VM_RAM_MB=4096
                BOOTLOADER=grub
            }
            guard_mutation() { return 0; }
            exigir_nao_root() { :; }
            exigir_conf() { :; }
            exigir_bootloader_coerente() { :; }
            exigir_sudo() { :; }
            exigir_comando() { :; }
            exigir_vm_desligada() { :; }
            validar_layout_configurado() { CPU_LAYOUT_ONLINE="0,1,2,3,4,5,6,7"; return 0; }
            validar_suporte_isolamento() { return 0; }
            validar_pinning_vm() { return 0; }
            exigir_topologia_inalterada() { echo topologia >> "'"$ORDEM"'"; }
            isolamento_efetivo_exato() { return 0; }
            confirmar() { return 0; }
            cmdline_parametros_exatos() { return 0; }
            kernel_parametros_persistentes_exatos() { return 0; }
            kernel_param_add() { echo boot >> "'"$ORDEM"'"; }
            kernel_param_del() { echo boot >> "'"$ORDEM"'"; }
            pedir_reboot() { echo reboot >> "'"$ORDEM"'"; }
            eval "$prelude"
            main
        ) 2>&1
    )" || APPLY_RC=$?
}

# D1: confirmação digitada CORRETA. Sem esta ponta, "nenhum efeito" passaria
# por "a etapa nunca aplica nada".
rodar_apply_18 '
    confirmar_digitando() { return 0; }
'
[ "$APPLY_RC" -eq 0 ] \
    || falha "D1: apply com confirmação correta devia concluir, rc=$APPLY_RC. Saída:\n$APPLY_SAIDA"
passo

# D2: confirmação digitada RECUSADA (texto errado ou vazio). Nenhum efeito:
# nem chave de boot, nem reboot, nem revalidação de topologia.
rodar_apply_18 '
    confirmar_digitando() { return 1; }
'
[ "$APPLY_RC" -ne 0 ] \
    || falha "D2: apply sem a confirmação digitada devia falhar. Saída:\n$APPLY_SAIDA"
[ ! -s "$ORDEM" ] \
    || falha "D2: apply recusado produziu efeito: $(paste -sd, "$ORDEM")"
printf '%s\n' "$APPLY_SAIDA" | grep -Fq 'o perfil retornável foi preservado' \
    || falha "D2: a recusa não disse que o perfil retornável foi preservado. Saída:\n$APPLY_SAIDA"
passo

# D3: a frase digitada é EXATAMENTE `ISOLAMENTO-NAO-RETORNAVEL`. Trocá-la sem
# atualizar a documentação deixaria o operador sem como aplicar a etapa.
grep -Fq 'confirmar_digitando "ISOLAMENTO-NAO-RETORNAVEL"' "$RAIZ/etapas/53-cpu-isolation.sh" \
    || falha 'a etapa 18 deixou de exigir a frase ISOLAMENTO-NAO-RETORNAVEL (I9.12-D5)'
passo

# D4: e a exigência vem ANTES de qualquer escrita de boot. Confirmação depois
# do efeito não é confirmação.
ETAPA18="$RAIZ/etapas/53-cpu-isolation.sh"
LINHA_CONFIRMA=$(grep -n 'confirmar_digitando "ISOLAMENTO-NAO-RETORNAVEL"' "$ETAPA18" | head -1 | cut -d: -f1)
LINHA_ADD=$(grep -n 'kernel_param_add' "$ETAPA18" | head -1 | cut -d: -f1)
[ -n "$LINHA_CONFIRMA" ] && [ -n "$LINHA_ADD" ] \
    || falha 'não foi possível localizar a confirmação digitada e o kernel_param_add da etapa 18'
[ "$LINHA_CONFIRMA" -lt "$LINHA_ADD" ] \
    || falha 'a confirmação digitada da etapa 18 passou a vir DEPOIS da escrita de boot'
passo

printf 'OK: contrato novo das etapas 17 e 18 (I9.12) em %d casos: política dirige o XML, o apply da 17 não toca no boot, e o isolamento persistente só entra digitado\n' "$CASOS"
