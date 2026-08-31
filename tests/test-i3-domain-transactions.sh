#!/usr/bin/env bash
# Fase I3: prova a fronteira de XML/JSON no lado do shell.
#
# O que este teste cobre, sempre em raízes temporárias e sem tocar o host:
#
#   * as APIs públicas da fachada (mesmos nomes e retornos de antes da migração)
#     agora respondem a partir do core Python;
#   * XML, JSON e snapshots nunca aparecem em `argv`: um shim de `python3`
#     registra a linha de comando e um canário de segredo é procurado nela;
#   * o arquivo controlado de payload é 0600, com um único link e do dono
#     correto, e todo temporário é removido em sucesso, erro e sinal;
#   * a resolução autoritativa do backend libvirt (REQ-LIBVIRT-BACKEND) decide
#     por fixture, distinguindo backend monolítico, modular e ausência total;
#   * o teste tem dentes: mutações injetadas no core e na ponte precisam ser
#     reprovadas.
set -euo pipefail

RAIZ=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
PYTHON_REAL=$(type -P python3 || true)
STAT_REAL=$(type -P stat || true)
CANARIO='CANARIO-SECRETO-I3-9d41c7'
CHECKS=0

falha() { printf 'FALHA I3 domain: %s\n' "$*" >&2; exit 1; }
passo() { CHECKS=$((CHECKS + 1)); }

[[ -n $PYTHON_REAL ]] || falha 'python3 é obrigatório'
[[ -n $STAT_REAL ]] || falha 'stat é obrigatório'

TMP=$(mktemp -d "${TMPDIR:-/tmp}/i3-domain.XXXXXXXX")
limpar() {
    python_core_temporarios_limpar 2>/dev/null || true
    rm -rf -- "$TMP"
}
trap limpar EXIT
trap 'python_core_temporarios_limpar 2>/dev/null || true; exit 130' INT
trap 'python_core_temporarios_limpar 2>/dev/null || true; exit 143' TERM

# --- Fotografia do checkout ---------------------------------------------------
snapshot_checkout() {
    (
        cd -- "$RAIZ"
        find . -path ./.git -prune -o -type f -printf '%p\t%s\t%m\t%T@\n' \
            | LC_ALL=C sort
    ) > "$1"
}
snapshot_checkout "$TMP/checkout.antes"

# shellcheck source=lib/common.sh
source "$RAIZ/lib/common.sh"

python_core_disponivel || falha "core indisponível: $PYTHON_CORE_ERRO"

# --- Fixtures sintéticas ------------------------------------------------------
QCOW2='/vm/fixture.qcow2'
HD1='/dev/disk/by-id/ata-FIXTURE_SERIAL0001'
MAC='52:54:00:12:34:56'

escrever_dominio() {
    # escrever_dominio ARQUIVO [discard] [extras dentro de <devices>]
    local arquivo=$1 discard=${2:-} extras=${3:-}
    local atributo=''
    [[ -z $discard ]] || atributo=" discard='$discard'"
    cat > "$arquivo" <<XML
<domain type='kvm'>
  <name>fixture-win11</name>
  <!-- comentário do operador: $CANARIO -->
  <memory unit='MiB'>8192</memory>
  <currentMemory unit='MiB'>8192</currentMemory>
  <vcpu placement='static'>4</vcpu>
  <features><acpi/><apic/></features>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'$atributo/>
      <source file='$QCOW2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='network'>
      <mac address='$MAC'/>
      <source network='default'/>
      <model type='virtio'/>
    </interface>
    <graphics type='spice'/>
    <video><model type='qxl'/></video>
$extras
  </devices>
</domain>
XML
}

ORIGINAL="$TMP/original.xml"
escrever_dominio "$ORIGINAL"

# --- 1. Estado do disco alvo --------------------------------------------------

RC=0
xml_disco_qcow2_estado "$ORIGINAL" "$QCOW2" || RC=$?
[[ $RC -eq 1 ]] || falha "discard ausente devia dar rc=1, deu $RC"
[[ $DISCARD_XML_ESTADO == ausente ]] || falha "estado divergente: $DISCARD_XML_ESTADO"
[[ -n $DISCARD_XML_FINGERPRINT ]] || falha 'fingerprint não foi publicado'

COM_DISCARD="$TMP/com-discard.xml"
escrever_dominio "$COM_DISCARD" unmap
xml_disco_qcow2_estado "$COM_DISCARD" "$QCOW2" \
    || falha "discard ativo devia dar rc=0: $DISCARD_XML_ERRO"
[[ $DISCARD_XML_ESTADO == ativo ]] || falha 'estado ativo não foi reconhecido'

RC=0
xml_disco_qcow2_estado "$ORIGINAL" '/vm/inexistente.qcow2' || RC=$?
[[ $RC -eq 2 ]] || falha "alvo ausente devia dar rc=2, deu $RC"
[[ $DISCARD_XML_ESTADO == erro ]] || falha 'cardinalidade zero não virou erro'
[[ -n $DISCARD_XML_ERRO ]] || falha 'erro de cardinalidade sem diagnóstico'
[[ $DISCARD_XML_ERRO != *"$CANARIO"* ]] || falha 'canário vazou no diagnóstico'

MALFORMADO="$TMP/malformado.xml"
printf '<domain><devices>\n' > "$MALFORMADO"
RC=0
xml_disco_qcow2_estado "$MALFORMADO" "$QCOW2" || RC=$?
[[ $RC -eq 2 ]] || falha "XML malformado devia dar rc=2, deu $RC"

RC=0
xml_disco_qcow2_estado "$TMP/nao-existe.xml" "$QCOW2" || RC=$?
[[ $RC -eq 2 ]] || falha 'arquivo ausente devia dar rc=2'

ln -s "$ORIGINAL" "$TMP/link.xml"
RC=0
xml_disco_qcow2_estado "$TMP/link.xml" "$QCOW2" || RC=$?
[[ $RC -eq 2 ]] || falha 'snapshot simbólico devia ser recusado'

RC=0
xml_disco_qcow2_estado "$ORIGINAL" 'relativo.qcow2' || RC=$?
[[ $RC -eq 2 ]] || falha 'QCOW2_PATH relativo devia ser recusado'

# Disco físico (HD1): cardinalidade e identidade projetadas para o fluxo de I6.
COM_HD1="$TMP/com-hd1.xml"
escrever_dominio "$COM_HD1" '' "    <disk type='block' device='disk'>
      <driver name='qemu' type='raw' cache='none'/>
      <source dev='$HD1'/>
      <target dev='vdb' bus='virtio'/>
      <serial>FIXTURE1</serial>
    </disk>"
declare -a HD1_PERMITIDAS=(
    "${CORE_PARES_ENVELOPE[@]}" SOURCE_COUNT EXACT_COUNT TARGET_COUNT IDENTITY_COUNT
)
declare -a HD1_PAYLOAD=(xml "$(<"$COM_HD1")" block_path "$HD1" target_dev vdb)
python_core_pares_payload HD1_PERMITIDAS HD1X_ domain-disk-block HD1_PAYLOAD \
    || falha "inspeção do HD1 falhou: $PYTHON_CORE_ERRO"
[[ $HD1X_SOURCE_COUNT == 1 && $HD1X_EXACT_COUNT == 1 && $HD1X_TARGET_COUNT == 1 ]] \
    || falha 'HD1 exato não foi reconhecido'
[[ $HD1X_IDENTITY_COUNT == 1 ]] || falha 'identidade física do HD1 não foi projetada'
passo

# --- 2. Fingerprint e comparação semântica ------------------------------------

xml_dominio_fingerprint "$ORIGINAL" || falha "fingerprint: $XML_DOMINIO_ERRO"
FP_ORIGINAL=$XML_DOMINIO_FINGERPRINT
[[ $FP_ORIGINAL =~ ^[0-9a-f]{64}$ ]] || falha 'fingerprint fora do formato'
xml_dominio_fingerprint "$ORIGINAL" || falha 'fingerprint não repetiu'
[[ $XML_DOMINIO_FINGERPRINT == "$FP_ORIGINAL" ]] || falha 'fingerprint não é determinístico'

COPIA="$TMP/copia.xml"
cp -- "$ORIGINAL" "$COPIA"
xml_dominio_equivalente "$ORIGINAL" "$COPIA" full \
    || falha "cópia idêntica devia ser equivalente: $XML_COMPARACAO_ERRO"

RC=0
xml_dominio_equivalente "$ORIGINAL" "$COM_DISCARD" full || RC=$?
[[ $RC -eq 1 ]] || falha "divergência devia dar rc=1, deu $RC"
[[ -n $XML_COMPARACAO_DIFERENCA ]] || falha 'divergência sem descrição'
[[ $XML_COMPARACAO_DIFERENCA != *"$CANARIO"* ]] || falha 'canário vazou na descrição da divergência'

# Espaço em branco e ordem de atributos não são divergência semântica.
REFORMATADO="$TMP/reformatado.xml"
sed -e "s|<driver name='qemu' type='qcow2'/>|<driver    type='qcow2'   name='qemu'/>|" \
    "$ORIGINAL" > "$REFORMATADO"
xml_dominio_equivalente "$ORIGINAL" "$REFORMATADO" full \
    || falha 'reordenar atributos não devia divergir'

RC=0
xml_dominio_equivalente "$ORIGINAL" "$MALFORMADO" full || RC=$?
[[ $RC -eq 2 ]] || falha "comparação com XML inválido devia dar rc=2, deu $RC"

RC=0
xml_dominio_equivalente "$ORIGINAL" "$COPIA" projecao-inexistente || RC=$?
[[ $RC -eq 2 ]] || falha 'projeção desconhecida devia dar rc=2'
passo

# --- 3. Candidatos ------------------------------------------------------------

CANDIDATO="$TMP/candidato.xml"
xml_candidato_discard "$ORIGINAL" "$CANDIDATO" "$QCOW2" \
    || falha "candidato de discard: $XML_CANDIDATO_ERRO"
[[ $XML_CANDIDATO_MUDOU == 1 ]] || falha 'candidato de discard não marcou mudança'
[[ $XML_CANDIDATO_FINGERPRINT_ANTES == "$FP_ORIGINAL" ]] \
    || falha 'fingerprint anterior do candidato divergiu'
xml_disco_qcow2_estado "$CANDIDATO" "$QCOW2" \
    || falha 'candidato de discard não ficou ativo'
grep -q "$CANARIO" "$CANDIDATO" || falha 'comentário não gerenciado foi perdido no candidato'

# Segunda geração sobre o candidato é no-op declarado.
CANDIDATO2="$TMP/candidato2.xml"
xml_candidato_discard "$CANDIDATO" "$CANDIDATO2" "$QCOW2" \
    || falha "segunda geração: $XML_CANDIDATO_ERRO"
[[ $XML_CANDIDATO_MUDOU == 0 ]] || falha 'segunda geração devia ser no-op'
cmp -s "$CANDIDATO" "$CANDIDATO2" || falha 'segunda geração alterou bytes'

# Falha de geração não toca o destino.
INTOCADO="$TMP/intocado.xml"
printf 'CONTEUDO-ANTERIOR\n' > "$INTOCADO"
RC=0
xml_candidato_discard "$ORIGINAL" "$INTOCADO" '/vm/inexistente.qcow2' || RC=$?
[[ $RC -ne 0 ]] || falha 'candidato com alvo ausente devia falhar'
[[ $(<"$INTOCADO") == 'CONTEUDO-ANTERIOR' ]] || falha 'candidato recusado sobrescreveu o destino'
[[ -n $XML_CANDIDATO_ERRO ]] || falha 'candidato recusado sem diagnóstico'

SEM_VIDEO="$TMP/sem-video.xml"
xml_candidato_sem_video "$ORIGINAL" "$SEM_VIDEO" \
    || falha "candidato sem vídeo: $XML_CANDIDATO_ERRO"
grep -q '<graphics' "$SEM_VIDEO" && falha 'graphics não foi removido'
grep -q '<video' "$SEM_VIDEO" && falha 'video não foi removido'

CODE43="$TMP/code43.xml"
xml_candidato_anti_code43 "$ORIGINAL" "$CODE43" \
    || falha "candidato anti-Code 43: $XML_CANDIDATO_ERRO"
grep -q 'vendor_id' "$CODE43" || falha 'vendor_id não foi inserido'
grep -q 'hidden' "$CODE43" || falha 'kvm/hidden não foi inserido'
grep -q '<acpi' "$CODE43" || falha 'features original foi perdida'

NIC_BRIDGE="$TMP/nic-bridge.xml"
xml_candidato_fonte_nic "$ORIGINAL" "$NIC_BRIDGE" "$MAC" bridge bridge br-vm \
    || falha "candidato de NIC: $XML_CANDIDATO_ERRO"
grep -q "bridge=\"br-vm\"" "$NIC_BRIDGE" || falha 'fonte da NIC não foi trocada'
grep -q "$MAC" "$NIC_BRIDGE" || falha 'MAC não foi preservado'

RC=0
xml_candidato_fonte_nic "$ORIGINAL" "$TMP/nic-ruim.xml" '52:54:00:99:99:99' bridge bridge br-vm || RC=$?
[[ $RC -ne 0 ]] || falha 'MAC inexistente devia recusar o candidato'
passo

# --- 4. CPU: candidato, validação e HugePages ---------------------------------

CPU_CANDIDATO="$TMP/cpu.xml"
xml_cpu_gerar_candidato "$ORIGINAL" "$CPU_CANDIDATO" '2-5' '0-1,6-7' 4 2 2 8192 \
    || falha "candidato de CPU: $XML_CPU_ERRO"
validar_xml_cpu_pinning "$CPU_CANDIDATO" '2-5' '0-1,6-7' 4 2 2 8192 sim \
    || falha "validação de CPU: $XML_CPU_ERRO"
RC=0
validar_xml_cpu_pinning "$CPU_CANDIDATO" '2-5' '0-1,6-7' 4 2 2 4096 sim || RC=$?
[[ $RC -ne 0 ]] || falha 'RAM divergente devia reprovar'
[[ -n $XML_CPU_ERRO ]] || falha 'validação reprovada sem diagnóstico'

RC=0
xml_sem_hugepages_arquivo "$CPU_CANDIDATO" || RC=$?
[[ $RC -eq 1 ]] || falha "candidato com HugePages devia dar rc=1, deu $RC"

SEM_HUGE="$TMP/sem-huge.xml"
xml_cpu_remover_hugepages "$CPU_CANDIDATO" "$SEM_HUGE" \
    || falha "remoção de HugePages: $XML_CPU_ERRO"
xml_sem_hugepages_arquivo "$SEM_HUGE" \
    || falha 'candidato de reversão ainda exige HugePages'
validar_xml_cpu_pinning "$SEM_HUGE" '2-5' '0-1,6-7' 4 2 2 8192 nao \
    || falha "XML sem HugePages inválido: $XML_CPU_ERRO"

# Conteúdo não gerenciado de cputune sobrevive ao candidato.
COM_SHARES="$TMP/com-shares.xml"
sed -e "s|<vcpu placement='static'>4</vcpu>|<vcpu placement='static'>4</vcpu><cputune><shares>2048</shares></cputune>|" \
    "$ORIGINAL" > "$COM_SHARES"
CPU_SHARES="$TMP/cpu-shares.xml"
xml_cpu_gerar_candidato "$COM_SHARES" "$CPU_SHARES" '2-5' '0-1,6-7' 4 2 2 8192 \
    || falha "candidato com shares: $XML_CPU_ERRO"
grep -q '<shares>2048</shares>' "$CPU_SHARES" || falha 'shares não gerenciado foi perdido'
xml_dominio_equivalente "$CPU_SHARES" "$CPU_SHARES" cpu-unmanaged \
    || falha 'projeção cpu-unmanaged não é reflexiva'

RC=0
xml_sem_hugepages_arquivo "$TMP/nao-existe.xml" || RC=$?
[[ $RC -eq 2 ]] || falha 'arquivo ausente devia dar rc=2 em xml_sem_hugepages_arquivo'
passo

# --- 5. Transporte: nada de dado local em argv --------------------------------

ARGV_LOG="$TMP/argv.log"
MODE_LOG="$TMP/mode.log"
SHIM="$TMP/bin"
: > "$ARGV_LOG"
: > "$MODE_LOG"
mkdir -p -- "$SHIM"
cat > "$SHIM/python3" <<SHIMEOF
#!/usr/bin/env bash
printf '%s\0' "\$@" >> "$ARGV_LOG"
for argumento in "\$@"; do
    case \$argumento in
        --input-file=*|--output-file=*)
            "$STAT_REAL" -c '%a %h %U %F' -- "\${argumento#*=}" >> "$MODE_LOG"
            ;;
    esac
done
exec "$PYTHON_REAL" "\$@"
SHIMEOF
chmod 0755 -- "$SHIM/python3"

PATH_ORIGINAL=$PATH
PATH="$SHIM:$PATH"
xml_disco_qcow2_estado "$COM_DISCARD" "$QCOW2" || { PATH=$PATH_ORIGINAL; falha 'chamada sob shim falhou'; }
CANDIDATO_SHIM="$TMP/candidato-shim.xml"
xml_candidato_discard "$ORIGINAL" "$CANDIDATO_SHIM" "$QCOW2" \
    || { PATH=$PATH_ORIGINAL; falha "candidato sob shim falhou: $XML_CANDIDATO_ERRO"; }
PATH=$PATH_ORIGINAL

mapfile -d '' -t ARGV_CAPTURADO < "$ARGV_LOG"
(( ${#ARGV_CAPTURADO[@]} > 0 )) || falha 'shim não registrou argv'
argv_tem_flags=0
argv_tem_entrada=0
argv_tem_saida=0
for argumento in "${ARGV_CAPTURADO[@]}"; do
    [[ $argumento != *"$CANARIO"* ]] || falha 'canário do XML apareceu em argv'
    [[ $argumento != *'<domain'* ]] || falha 'XML apareceu em argv'
    [[ $argumento != "$QCOW2" ]] || falha 'QCOW2_PATH apareceu em argv'
    [[ $argumento != *'"payload"'* ]] || falha 'JSON apareceu em argv'
    case $argumento in
        --input-file=*) argv_tem_entrada=1 ;;
        --output-file=*) argv_tem_saida=1 ;;
        -I) argv_tem_flags=1 ;;
    esac
done
(( argv_tem_entrada == 1 )) || falha 'argv não recebeu o localizador do payload'
(( argv_tem_saida == 1 )) || falha 'argv não recebeu o localizador do candidato'
(( argv_tem_flags == 1 )) || falha 'argv não recebeu as flags de isolamento'
[[ -s $MODE_LOG ]] || falha 'shim não inspecionou os arquivos controlados'
while read -r modo links dono tipo; do
    [[ $modo == 600 ]] || falha "arquivo controlado com modo $modo"
    [[ $links == 1 ]] || falha "arquivo controlado com $links links"
    [[ $dono == "$(id -un)" ]] || falha "arquivo controlado pertence a $dono"
    [[ $tipo == 'regular file' || $tipo == 'regular empty file' ]] \
        || falha "arquivo controlado não é regular: $tipo"
done < "$MODE_LOG"
passo

# --- 6. Ciclo de vida dos temporários ----------------------------------------

python_core_temporarios_limpar
xml_disco_qcow2_estado "$COM_DISCARD" "$QCOW2" || falha 'chamada de controle falhou'
[[ -z $PYTHON_CORE_TMPDIR || ! -d $PYTHON_CORE_TMPDIR ]] \
    || falha 'raiz privada sobreviveu a uma consulta bem-sucedida'
RC=0
xml_disco_qcow2_estado "$MALFORMADO" "$QCOW2" || RC=$?
[[ $RC -eq 2 ]] || falha 'consulta inválida devia falhar'
[[ -z $PYTHON_CORE_TMPDIR || ! -d $PYTHON_CORE_TMPDIR ]] \
    || falha 'raiz privada sobreviveu a uma consulta com erro'
RESIDUO=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'passthrough-core.*' -newer "$TMP/checkout.antes" -print -quit 2>/dev/null || true)
[[ -z $RESIDUO ]] || falha "raiz privada residual em TMPDIR: $RESIDUO"

cat > "$TMP/sinal.sh" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
source "$1/lib/common.sh"
trap 'python_core_temporarios_limpar' EXIT
trap 'python_core_temporarios_limpar; exit 130' INT
trap 'python_core_temporarios_limpar; exit 143' TERM
python_core_temporario_novo ALVO
printf '%s\n%s\n' "$ALVO" "$PYTHON_CORE_TMPDIR" > "$2"
[[ -f $ALVO ]] || exit 98
kill -"$3" $$
sleep 5
exit 99
HARNESS
for sinal in TERM INT; do
    marcador="$TMP/sinal.$sinal"
    rc=0
    bash "$TMP/sinal.sh" "$RAIZ" "$marcador" "$sinal" || rc=$?
    case $sinal in
        TERM) [[ $rc -eq 143 ]] || falha "SIGTERM devia sair 143, saiu $rc" ;;
        INT) [[ $rc -eq 130 ]] || falha "SIGINT devia sair 130, saiu $rc" ;;
    esac
    arquivo_filho=$(sed -n 1p "$marcador")
    raiz_filho=$(sed -n 2p "$marcador")
    [[ ! -e $arquivo_filho ]] || falha "temporário sobreviveu a SIG$sinal"
    [[ ! -d $raiz_filho ]] || falha "raiz privada sobreviveu a SIG$sinal"
done
passo

# --- 7. Backend libvirt autoritativo (REQ-LIBVIRT-BACKEND) -------------------

fixture_systemd() {
    local arquivo=$1 perfil=$2
    case $perfil in
        monolitico)
            cat > "$arquivo" <<'UNITS'
libvirtd.socket|loaded|active|running|enabled
libvirtd.service|loaded|active|running|enabled
virtqemud.socket|not-found|inactive|dead|disabled
virtqemud.service|not-found|inactive|dead|disabled
UNITS
            ;;
        modular)
            cat > "$arquivo" <<'UNITS'
libvirtd.socket|not-found|inactive|dead|disabled
libvirtd.service|not-found|inactive|dead|disabled
virtqemud.socket|loaded|active|running|enabled
virtqemud.service|loaded|active|running|enabled
UNITS
            ;;
        ausente)
            cat > "$arquivo" <<'UNITS'
libvirtd.socket|not-found|inactive|dead|disabled
libvirtd.service|not-found|inactive|dead|disabled
virtqemud.socket|not-found|inactive|dead|disabled
virtqemud.service|not-found|inactive|dead|disabled
UNITS
            ;;
        so-instalavel)
            cat > "$arquivo" <<'UNITS'
libvirtd.socket|loaded|inactive|dead|enabled
libvirtd.service|loaded|inactive|dead|enabled
virtqemud.socket|not-found|inactive|dead|disabled
virtqemud.service|not-found|inactive|dead|disabled
UNITS
            ;;
    esac
}

fixture_systemd "$TMP/units-mono" monolitico
libvirt_backend_resolver "$TMP/units-mono" \
    || falha "backend monolítico não resolveu: $LIBVIRT_BACKEND_ERRO"
[[ $LIBVIRT_BACKEND_SERVICO == libvirtd ]] || falha "serviço resolvido: $LIBVIRT_BACKEND_SERVICO"
[[ $LIBVIRT_BACKEND_UNIDADE == libvirtd.socket ]] || falha "unidade resolvida: $LIBVIRT_BACKEND_UNIDADE"
[[ $LIBVIRT_BACKEND_UNIDADE_DAEMON == libvirtd.service ]] \
    || falha "daemon resolvido: $LIBVIRT_BACKEND_UNIDADE_DAEMON"
[[ $LIBVIRT_BACKEND_ACAO == nenhuma ]] || falha "ação resolvida: $LIBVIRT_BACKEND_ACAO"

fixture_systemd "$TMP/units-modular" modular
libvirt_backend_resolver "$TMP/units-modular" \
    || falha "backend modular não resolveu: $LIBVIRT_BACKEND_ERRO"
[[ $LIBVIRT_BACKEND_SERVICO == virtqemud ]] || falha 'backend modular não escolheu virtqemud'
[[ $LIBVIRT_BACKEND_UNIDADE_DAEMON == virtqemud.service ]] \
    || falha 'backend modular apontou o daemon errado'

fixture_systemd "$TMP/units-ausente" ausente
RC=0
libvirt_backend_resolver "$TMP/units-ausente" || RC=$?
[[ $RC -eq 1 ]] || falha "backend ausente devia dar rc=1, deu $RC"
[[ -n $LIBVIRT_BACKEND_ERRO ]] || falha 'backend ausente sem diagnóstico'
[[ -z $LIBVIRT_BACKEND_UNIDADE_DAEMON ]] || falha 'backend ausente publicou daemon'

fixture_systemd "$TMP/units-instalavel" so-instalavel
libvirt_backend_resolver "$TMP/units-instalavel" \
    || falha "backend instalável não resolveu: $LIBVIRT_BACKEND_ERRO"
[[ $LIBVIRT_BACKEND_ACAO == enable-now ]] \
    || falha "ação para unidade inativa: $LIBVIRT_BACKEND_ACAO"

RC=0
libvirt_backend_resolver "$TMP/fixture-inexistente" || RC=$?
[[ $RC -eq 2 ]] || falha "fixture ausente devia dar rc=2, deu $RC"

# O restart exige backend resolvido: sem resolução, recusa antes de qualquer sudo.
LIBVIRT_BACKEND_UNIDADE_DAEMON=''
RC=0
libvirt_backend_reiniciar || RC=$?
[[ $RC -eq 1 ]] || falha 'restart sem backend resolvido devia falhar'
[[ $LIBVIRT_BACKEND_ERRO == *'não resolvido'* ]] || falha 'restart sem backend sem diagnóstico'
passo

# --- 8. Uma única definição de ativar_unidade_systemd ------------------------

DUPLICADAS=$(grep -rlc '^ativar_unidade_systemd()' \
    "$RAIZ/lib" "$RAIZ/etapas" "$RAIZ/util" "$RAIZ/menu.sh" 2>/dev/null | wc -l)
[[ $DUPLICADAS -eq 1 ]] \
    || falha "ativar_unidade_systemd está definida em $DUPLICADAS arquivos; esperado 1"
declare -F ativar_unidade_systemd > /dev/null 2>&1 \
    || falha 'ativar_unidade_systemd não está acessível pela fachada'
# I9: a fachada agrega; a definição mora no módulo de privilégio, que é quem
# executa systemctl com sudo.
grep -q '^ativar_unidade_systemd()' "$RAIZ/lib/shell/privilege.sh" \
    || falha 'ativar_unidade_systemd saiu de lib/shell/privilege.sh'
for arquivo in "$RAIZ/etapas/20-virtualizacao.sh" "$RAIZ/etapas/50-hooks-gpu-hd1.sh"; do
    grep -q 'libvirt_backend_resolver' "$arquivo" \
        || falha "$arquivo não usa a resolução autoritativa do backend"
done
grep -qE '(systemctl (restart|reload)|is-active).*\blibvirtd\b' \
    "$RAIZ/etapas/50-hooks-gpu-hd1.sh" \
    && falha 'etapa 50 ainda opera libvirtd de forma chumbada'
passo

# --- 9. Zero consumidor operacional de xmlstarlet e de heredoc Python --------

CONSUMIDORES=$(grep -rlE '(^|[^[:alnum:]_])xmlstarlet[[:space:]]' \
    "$RAIZ/menu.sh" "$RAIZ/lib" "$RAIZ/etapas" "$RAIZ/util" 2>/dev/null \
    | grep -v '12-pacotes-base.sh' || true)
[[ -z $CONSUMIDORES ]] || falha "consumidor operacional de xmlstarlet: $CONSUMIDORES"

# `python3 -` (o hífen sozinho) é o idioma dos heredocs migrados. `python3 -m`
# e `python3 -I` não casam, então a documentação da etapa 41 e a ponte seguem
# válidas.
HEREDOCS=$(grep -rnE 'python3[[:space:]]+-([[:space:]]|$)' \
    "$RAIZ/menu.sh" "$RAIZ/lib/common.sh" "$RAIZ/lib/platform.sh" \
    "$RAIZ/lib/shell" "$RAIZ/etapas" "$RAIZ/util" 2>/dev/null || true)
[[ -z $HEREDOCS ]] || falha "heredoc Python de produção restante: $HEREDOCS"
MARCADORES=$(grep -rn "<<'PY'" \
    "$RAIZ/menu.sh" "$RAIZ/lib" "$RAIZ/etapas" "$RAIZ/util" 2>/dev/null || true)
[[ -z $MARCADORES ]] || falha "marcador de heredoc Python restante: $MARCADORES"

# A ponte continua sendo a única rota até o core.
ROTAS=$(grep -rn 'passthrough_core\|libexec' \
    "$RAIZ/menu.sh" "$RAIZ/lib/common.sh" "$RAIZ/lib/platform.sh" \
    "$RAIZ/lib/shell" "$RAIZ/etapas" "$RAIZ/util" 2>/dev/null || true)
[[ -z $ROTAS ]] || falha "referência ao core fora da ponte: $ROTAS"
passo

# --- 10. Dentes: mutações injetadas precisam reprovar ------------------------
# Cada mutação é aplicada numa cópia isolada de lib/ e libexec/. O padrão
# precisa existir (a troca é verificada), e a bateria de asserções abaixo tem de
# reprovar a cópia mutada. Isso prova que as asserções deste arquivo têm dentes.

cat > "$TMP/mutar.py" <<'MUTADOR'
import io
import sys

caminho, antigo, novo = sys.argv[1:4]
with io.open(caminho, encoding="utf-8") as fluxo:
    texto = fluxo.read()
if antigo not in texto:
    raise SystemExit("padrão não encontrado em %s" % caminho)
with io.open(caminho, "w", encoding="utf-8") as fluxo:
    fluxo.write(texto.replace(antigo, novo, 1))
MUTADOR

cat > "$TMP/bateria.sh" <<'BATERIA'
# Oráculo mínimo executado contra a cópia (intacta ou mutada). Cada código de
# saída aponta exatamente qual invariante caiu.
set -uo pipefail
source "$1/lib/common.sh" 2>/dev/null || exit 20
trap 'python_core_temporarios_limpar 2>/dev/null || true' EXIT
original="$2"
qcow2="$3"
candidato="$4"
com_discard="$5"
duplicado="$6"
# 1. Alvo único sem discard: pendência, não sucesso.
rc=0
xml_disco_qcow2_estado "$original" "$qcow2" || rc=$?
[ "$rc" -eq 1 ] || exit 10
[ "$DISCARD_XML_ESTADO" = ausente ] || exit 11
# 2. Alvo único com discard: sucesso.
xml_disco_qcow2_estado "$com_discard" "$qcow2" || exit 12
[ "$DISCARD_XML_ESTADO" = ativo ] || exit 13
# 3. Cardinalidade zero e cardinalidade dois: erro, nunca escolha implícita.
rc=0
xml_disco_qcow2_estado "$original" /vm/inexistente.qcow2 || rc=$?
[ "$rc" -eq 2 ] || exit 14
rc=0
xml_disco_qcow2_estado "$duplicado" "$qcow2" || rc=$?
[ "$rc" -eq 2 ] || exit 15
# 4. Candidato: muda, é relido como ativo e diverge do original. O destino
#    começa ausente, para que "não publicou" não seja mascarado por sobra.
rm -f -- "$candidato"
xml_candidato_discard "$original" "$candidato" "$qcow2" || exit 16
[ "$XML_CANDIDATO_MUDOU" = 1 ] || exit 17
xml_disco_qcow2_estado "$candidato" "$qcow2" || exit 18
rc=0
xml_dominio_equivalente "$original" "$candidato" full || rc=$?
[ "$rc" -eq 1 ] || exit 19
# 5. Allowlist incompleta do canal de pares precisa recusar a carga inteira.
declare -a PARCIAL=(CORE_VERSION)
declare -a payload_parcial=(xml "$(cat -- "$original")")
rc=0
python_core_pares_payload PARCIAL PARC_ domain-fingerprint payload_parcial \
    > /dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || exit 21
[ -z "${PARC_FINGERPRINT:-}" ] || exit 22
# 6. Snapshot simbólico é recusado antes de qualquer análise.
rc=0
xml_disco_qcow2_estado "$7" "$qcow2" || rc=$?
[ "$rc" -eq 2 ] || exit 23
exit 0
BATERIA

DUPLICADO="$TMP/duplicado.xml"
escrever_dominio "$DUPLICADO" '' "    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='$QCOW2'/>
      <target dev='vdc' bus='virtio'/>
    </disk>"

COPIA_RAIZ="$TMP/mutado"
executar_mutacao() {
    # $1 = descrição; $2 = arquivo relativo; $3 = texto antigo; $4 = texto novo.
    local descricao=$1 alvo=$2 antigo=$3 novo=$4 rc=0
    rm -rf -- "$COPIA_RAIZ"
    mkdir -p -- "$COPIA_RAIZ"
    cp -a -- "$RAIZ/lib" "$COPIA_RAIZ/lib"
    cp -a -- "$RAIZ/libexec" "$COPIA_RAIZ/libexec"
    python3 "$TMP/mutar.py" "$COPIA_RAIZ/$alvo" "$antigo" "$novo" \
        || falha "mutação '$descricao' não pôde ser aplicada"
    bash "$TMP/bateria.sh" "$COPIA_RAIZ" "$ORIGINAL" "$QCOW2" \
        "$TMP/mut-candidato.xml" "$COM_DISCARD" "$DUPLICADO" "$TMP/link.xml" \
        > /dev/null 2>&1 || rc=$?
    [[ $rc -ne 0 ]] || falha "mutação '$descricao' passou sem ser detectada"
    rm -rf -- "$COPIA_RAIZ"
}

# A bateria precisa aprovar a árvore intacta antes de servir como oráculo.
rm -rf -- "$COPIA_RAIZ"
mkdir -p -- "$COPIA_RAIZ"
cp -a -- "$RAIZ/lib" "$COPIA_RAIZ/lib"
cp -a -- "$RAIZ/libexec" "$COPIA_RAIZ/libexec"
bash "$TMP/bateria.sh" "$COPIA_RAIZ" "$ORIGINAL" "$QCOW2" "$TMP/mut-candidato.xml" \
    "$COM_DISCARD" "$DUPLICADO" "$TMP/link.xml" \
    || falha 'a bateria de mutação reprovou a árvore intacta'
rm -rf -- "$COPIA_RAIZ"

executar_mutacao 'cardinalidade dois aceita como se fosse um' \
    libexec/passthrough_core/domain_xml.py \
    'if len(matches) != 1:' \
    'if len(matches) < 1:'

executar_mutacao 'estado de discard sempre ativo' \
    libexec/passthrough_core/domain_xml.py \
    '"state": "ativo" if target["driver_discard"] == "unmap" else "ausente",' \
    '"state": "ativo",'

executar_mutacao 'candidato não altera o disco' \
    libexec/passthrough_core/domain_xml.py \
    "    driver.set(\"discard\", value)" \
    "    pass"

executar_mutacao 'comparação sempre igual' \
    libexec/passthrough_core/domain_xml.py \
    'equal = xmlutil.canonical(left) == xmlutil.canonical(right)' \
    'equal = True'

executar_mutacao 'ponte manda o payload por argv' \
    lib/python-core.sh \
    '"--input-file=$_pc_pp_arquivo" "$@" || _pc_pp_rc=$?' \
    '"$@" || _pc_pp_rc=$?'

executar_mutacao 'allowlist de pares vira permissiva' \
    lib/python-core.sh \
    'PYTHON_CORE_ERRO="Chave fora da allowlist no canal de pares: $_pc_cp_chave"
            return 1' \
    'PYTHON_CORE_ERRO=""'

executar_mutacao 'leitura aceita snapshot simbólico' \
    lib/shell/libvirt.sh \
    '[ -n "$arquivo" ] && [ -f "$arquivo" ] && [ ! -L "$arquivo" ] || return 1' \
    '[ -n "$arquivo" ] && [ -f "$arquivo" ] || return 1'

executar_mutacao 'destino do candidato não é publicado' \
    lib/python-core.sh \
    'if ! cat -- "$_pc_as_temporario" > "$_pc_as_destino"; then' \
    'if false; then'

passo

# --- 11. Checkout intacto ----------------------------------------------------

python_core_temporarios_limpar
RESIDUO=$(cd -- "$RAIZ" && find . -path ./.git -prune -o \
    \( -name '__pycache__' -o -name '*.pyc' \) -print -quit)
[[ -z $RESIDUO ]] || falha "bytecode residual no checkout: $RESIDUO"
snapshot_checkout "$TMP/checkout.depois"
diff -u "$TMP/checkout.antes" "$TMP/checkout.depois" \
    || falha 'o checkout mudou durante o teste'

printf 'OK: fronteira de XML/JSON de I3 no shell (%d grupos), transporte fora de argv, backend autoritativo e 8 mutações reprovadas\n' \
    "$CHECKS"
