#!/usr/bin/env bash
# Caracterização I0 de configuração, XML/JSON, CPU e inventário.
# Tudo opera em cópias temporárias e dados sintéticos; nenhum mutador do host é chamado.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
FIXTURES="$ROOT/tests/fixtures/i0"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

fail() { printf 'FALHA I0 characterization: %s\n' "$*" >&2; exit 1; }
expect_failure() {
    local description=$1
    shift
    if "$@"; then
        fail "$description deveria falhar"
    fi
}
file_state() {
    stat -c '%d:%i:%s:%a:%u:%g:%y' -- "$1"
}
function_rc() {
    set +e
    "$@"
    FUNCTION_RC=$?
    set -e
}

TMP=$(mktemp -d)
ALT_TMP=''
cleanup() {
    rm -rf -- "$TMP"
    [[ -z $ALT_TMP ]] || rm -rf -- "$ALT_TMP"
}
trap cleanup EXIT

python3 -I -S -B "$ROOT/tests/lib/i0-fixture-oracle.py" "$FIXTURES"

# Configuração: parser literal, round-trip, lote, metadados e casos de caminho.
CONF_ARQUIVO="$TMP/roundtrip.conf"
BACKUPS_DIR="$TMP/backups"
cp -- "$FIXTURES/config/roundtrip.conf" "$CONF_ARQUIVO"
chmod 0640 "$CONF_ARQUIVO"
ROUNDTRIP_OWNER_BEFORE=$(stat -c '%u:%g' "$CONF_ARQUIVO")
ROUNDTRIP_BEFORE=$(sha256sum "$CONF_ARQUIVO")
ROUNDTRIP_BEFORE=${ROUNDTRIP_BEFORE%% *}
carregar_conf
[[ ${VM_NAME:-} == win11-fixture ]] || fail 'roundtrip não carregou VM_NAME'
[[ ${QCOW2_PATH:-} == '/vm/Windows 11.qcow2' ]] || fail 'quoting com espaço não foi preservado'
# I4: AIRLOCK_DISPENSADO e BACKUP_DISPENSADO foram depreciadas (REQ-WAIVERS).
# A carga não define mais essas variáveis e as duas dispensas que restaram
# continuam sendo carregadas normalmente.
[[ ${WORKING_DISK_DISPENSADO+x} && ${HD1_DISPENSADO+x} ]] || fail 'allowlist completa não foi carregada'
[[ -z ${AIRLOCK_DISPENSADO+x} && -z ${BACKUP_DISPENSADO+x} ]] \
    || fail 'dispensa depreciada continuou sendo exposta como variável'
[[ $(stat -c '%a' "$CONF_ARQUIVO") == 640 ]] || fail 'load alterou modo do conf'

salvar_conf VM_NAME fixture-updated
[[ $(stat -c '%a' "$CONF_ARQUIVO") == 640 ]] || fail 'salvar_conf não preservou modo'
[[ $(stat -c '%u:%g' "$CONF_ARQUIVO") == "$ROUNDTRIP_OWNER_BEFORE" ]] || fail 'salvar_conf não preservou owner/grupo'
grep -q '^# fixture pública I0:' "$CONF_ARQUIVO" || fail 'salvar_conf removeu comentário'
[[ $(grep -n '^USUARIO_LINUX=' "$CONF_ARQUIVO" | cut -d: -f1) -lt $(grep -n '^VM_NAME=' "$CONF_ARQUIVO" | cut -d: -f1) ]] || fail 'salvar_conf alterou ordem'
carregar_conf
[[ $VM_NAME == fixture-updated ]] || fail 'valor salvo não fez round-trip'

# O decodificador de literais continua no shell porque a etapa 50 o usa para
# ler LEGACY_HOOK do dispatcher, que não é configuração.
_decodificar_literal_conf '"barra\\ aspas\" dólar\$ crase\`"' || fail 'literal com escapes inertes foi recusado'
[[ $REPLY == 'barra\ aspas" dólar$ crase`' ]] || fail 'escapes literais foram decodificados incorretamente'
# I4: a serialização saiu do Bash (_citar_conf) e passou a ser do core. O
# round-trip de escapes é provado em tests/python/test_config.py; aqui fica o
# round-trip observável pelo shell, com valor citado e espaço interno.
salvar_conf QCOW2_PATH '/vm/Windows 11 round trip.qcow2'
carregar_conf
[[ $QCOW2_PATH == '/vm/Windows 11 round trip.qcow2' ]] \
    || fail 'round-trip de valor citado com espaço perdeu bytes'
salvar_conf QCOW2_PATH '/vm/Windows 11.qcow2'

cp -- "$CONF_ARQUIVO" "$TMP/batch-before"
expect_failure 'lote com chave desconhecida' bash -c '
    set -euo pipefail
    source "$1"
    CONF_ARQUIVO=$2
    salvar_conf_lote VM_RAM_MB 16384 CHAVE_INVALIDA valor
' _ "$ROOT/lib/common.sh" "$CONF_ARQUIVO"
cmp -s "$TMP/batch-before" "$CONF_ARQUIVO" || fail 'lote inválido publicou alteração parcial'
salvar_conf_lote VM_RAM_MB 16384 HUGEPAGES_1G 16
carregar_conf
[[ $VM_RAM_MB == 16384 && $HUGEPAGES_1G == 16 ]] || fail 'lote válido não publicou todos os valores'

NO_NEWLINE="$TMP/no-final-newline.conf"
cp -- "$FIXTURES/config/no-final-newline.conf" "$NO_NEWLINE"
CONF_ARQUIVO=$NO_NEWLINE
carregar_conf
[[ $VM_NAME == fixture-no-newline ]] || fail 'arquivo sem newline final não carregou'

for invalid in duplicate unknown malicious; do
    I0_MARKER="$TMP/malicious-marker"
    I0_BACKTICK_MARKER="$TMP/backtick-marker"
    export I0_MARKER I0_BACKTICK_MARKER
    expect_failure "config $invalid" bash -c '
        set -euo pipefail
        source "$1"
        CONF_ARQUIVO=$2
        carregar_conf
    ' _ "$ROOT/lib/common.sh" "$FIXTURES/config/$invalid.conf"
done
[[ ! -e $TMP/malicious-marker && ! -e $TMP/backtick-marker ]] || fail 'conteúdo malicioso foi executado'

SYMLINK_TARGET="$TMP/symlink-target.conf"
cp -- "$FIXTURES/config/roundtrip.conf" "$SYMLINK_TARGET"
ln -s "$SYMLINK_TARGET" "$TMP/symlink.conf"
expect_failure 'load por symlink' bash -c 'source "$1"; CONF_ARQUIVO=$2; carregar_conf' _ "$ROOT/lib/common.sh" "$TMP/symlink.conf"
expect_failure 'save por symlink' bash -c 'source "$1"; CONF_ARQUIVO=$2; salvar_conf VM_NAME recusado' _ "$ROOT/lib/common.sh" "$TMP/symlink.conf"

# I4: hardlink passou a ser recusado (D-CONF-HARDLINK, P0). O oráculo de I0
# exigia aceitação e registrava a lacuna; agora a política da seção 3.2 vale, e
# nenhum dos dois nomes é alterado.
HARDLINK_ORIGINAL="$TMP/hardlink-original.conf"
HARDLINK_CONF="$TMP/hardlink.conf"
cp -- "$FIXTURES/config/roundtrip.conf" "$HARDLINK_ORIGINAL"
ln "$HARDLINK_ORIGINAL" "$HARDLINK_CONF"
[[ $(stat -c '%h' "$HARDLINK_CONF") -eq 2 ]] || fail 'fixture hardlink sem st_nlink=2'
HARDLINK_STATE_BEFORE=$(file_state "$HARDLINK_CONF")
expect_failure 'load de arquivo com dois links' bash -c \
    'set -euo pipefail; source "$1"; CONF_ARQUIVO=$2; carregar_conf' \
    _ "$ROOT/lib/common.sh" "$HARDLINK_CONF"
expect_failure 'save de arquivo com dois links' bash -c \
    'set -euo pipefail; source "$1"; CONF_ARQUIVO=$2; salvar_conf VM_NAME recusado' \
    _ "$ROOT/lib/common.sh" "$HARDLINK_CONF"
grep -q '^VM_NAME="win11-fixture"' "$HARDLINK_CONF" || fail 'recusa por hardlink alterou o alvo'
grep -q '^VM_NAME="win11-fixture"' "$HARDLINK_ORIGINAL" || fail 'recusa por hardlink alterou o outro nome'
[[ $(file_state "$HARDLINK_CONF") == "$HARDLINK_STATE_BEFORE" ]] \
    || fail 'recusa por hardlink alterou metadados do alvo'

# I4: as três corridas de publicação (troca de inode, mudança de link count e
# troca de device) deixaram de ser observáveis por shim de `mv` no PATH, porque
# a publicação passou a ser `renameat` dentro do core, com revalidação de device,
# inode, tipo, modo, dono e link count imediatamente antes do rename.
#
# A cobertura não foi reduzida: ela migrou para tests/python/test_config.py, na
# classe SensitiveFileTests, onde a corrida é montada de verdade entre a leitura
# e a publicação (test_conflito_por_troca_de_inode, test_conflito_por_link_count,
# test_conflito_por_modo, test_conflito_por_remocao e
# test_conflito_por_symlink_no_lugar). Cada um exige ConflictError, alvo
# preservado e nenhum temporário deixado para trás.
#
# O que continua sendo provado aqui, no nível do shell, é o efeito observável:
# um alvo que muda de identidade entre a leitura e a escrita não é sobrescrito.
CONCORRENTE_CONF="$TMP/concorrente.conf"
cp -- "$FIXTURES/config/roundtrip.conf" "$CONCORRENTE_CONF"
chmod 0600 "$CONCORRENTE_CONF"
bash -c 'set -euo pipefail; source "$1"; CONF_ARQUIVO=$2; carregar_conf' \
    _ "$ROOT/lib/common.sh" "$CONCORRENTE_CONF"
ln "$CONCORRENTE_CONF" "$TMP/concorrente-sombra.conf"
expect_failure 'publicação com identidade divergente' bash -c \
    'set -euo pipefail; source "$1"; CONF_ARQUIVO=$2; salvar_conf VM_NAME recusado' \
    _ "$ROOT/lib/common.sh" "$CONCORRENTE_CONF"
grep -q '^VM_NAME="win11-fixture"' "$CONCORRENTE_CONF" \
    || fail 'alvo com identidade divergente foi sobrescrito'

# O modelo versionado deve ser apenas lido: bytes, inode, metadados e mtime não mudam.
EXAMPLE_STATE_BEFORE=$(file_state "$ROOT/passthrough.conf.example")
EXAMPLE_HASH_BEFORE=$(sha256sum "$ROOT/passthrough.conf.example")
EXAMPLE_HASH_BEFORE=${EXAMPLE_HASH_BEFORE%% *}
bash -c 'set -euo pipefail; source "$1"; CONF_ARQUIVO=$2; carregar_conf' _ "$ROOT/lib/common.sh" "$ROOT/passthrough.conf.example"
[[ $(file_state "$ROOT/passthrough.conf.example") == "$EXAMPLE_STATE_BEFORE" ]] || fail 'load alterou metadados/mtime do exemplo'
EXAMPLE_HASH_AFTER=$(sha256sum "$ROOT/passthrough.conf.example")
[[ ${EXAMPLE_HASH_AFTER%% *} == "$EXAMPLE_HASH_BEFORE" ]] || fail 'load alterou bytes do exemplo'
# Baseline atualizado em I4 por mudança deliberada: AIRLOCK_DISPENSADO e
# BACKUP_DISPENSADO saíram do modelo (REQ-WAIVERS), substituídas por
# comentários que explicam a depreciação, e os exemplos de formato de GPU/NVMe
# deixaram de citar identificadores concretos (regra 8.1: clone limpo nunca
# recebe IDs de outro host). O hash anterior de I0 era
# 770ccd4d0dec50d256a8f9bf1dd75ed0e3a4aff98d93f39f91d091598a559d69.
[[ $EXAMPLE_HASH_BEFORE == 73e9253fa5aeccd951e8257903eeda972950e4edac042d19e9492757efa55175 ]] || fail 'passthrough.conf.example mudou; atualize explicitamente o baseline I0'
[[ $ROUNDTRIP_BEFORE != "$(sha256sum "$TMP/batch-before" | cut -d' ' -f1)" ]] || : # mudança anterior foi intencional

# A matriz de I0 deve cobrir cada chave pública individualmente, inclusive as
# duas dispensas hoje sem consumidor operacional. Isso impede que uma migração
# futura derive o schema apenas de um subconjunto conveniente de entrypoints.
declare -A TRACE_CONFIG_KEYS=()
TRACE_CONFIG_COUNT=0
while IFS=$'\t' read -r origem _ consumidor _; do
    [[ $origem == config:* ]] || continue
    chave=${origem#config:}
    [[ -z ${TRACE_CONFIG_KEYS[$chave]+definida} ]] || fail "chave duplicada na rastreabilidade: $chave"
    [[ -n $consumidor && $consumidor != 'all entrypoints' ]] || fail "consumidor não específico na rastreabilidade: $chave"
    TRACE_CONFIG_KEYS[$chave]=1
    TRACE_CONFIG_COUNT=$((TRACE_CONFIG_COUNT + 1))
done < "$ROOT/tests/i0/traceability.tsv"
# I4: a matriz de I0 é evidência histórica e continua com as 41 chaves daquele
# momento. Duas delas foram depreciadas, então a cobertura esperada é a allowlist
# atual mais as depreciadas, e cada linha extra tem de ser exatamente uma delas.
TRACE_ESPERADO=$(( ${#CHAVES_CONF_PERMITIDAS[@]} + ${#CHAVES_CONF_DEPRECIADAS[@]} ))
[[ $TRACE_CONFIG_COUNT -eq $TRACE_ESPERADO ]] \
    || fail "matriz de consumidores cobre $TRACE_CONFIG_COUNT de $TRACE_ESPERADO chaves"
for chave in "${CHAVES_CONF_DEPRECIADAS[@]}"; do
    [[ -n ${TRACE_CONFIG_KEYS[$chave]+definida} ]] \
        || fail "dispensa depreciada saiu da matriz histórica de I0: $chave"
done
for chave in "${CHAVES_CONF_PERMITIDAS[@]}"; do
    [[ -n ${TRACE_CONFIG_KEYS[$chave]+definida} ]] || fail "chave sem consumidor mapeado: $chave"
done
for chave in "${!TRACE_CONFIG_KEYS[@]}"; do
    if chave_conf_permitida "$chave"; then
        continue
    fi
    # I4: a única exceção autorizada é uma dispensa depreciada, que continua na
    # matriz histórica de I0 mas saiu da allowlist ativa.
    encontrada=0
    for depreciada in "${CHAVES_CONF_DEPRECIADAS[@]}"; do
        [[ $chave == "$depreciada" ]] && encontrada=1 && break
    done
    [[ $encontrada -eq 1 ]] \
        || fail "rastreabilidade contém chave fora da allowlist: $chave"
done

# CPU: execução das funções reais com multissocket, SMT, offline, IDs esparsos e ordem.
MULTI=$(grep -v '^#' "$FIXTURES/cpu/multisocket-smt.csv")
SPARSE=$(grep -v '^#' "$FIXTURES/cpu/sparse-offline-numa.csv")
validar_layout_cpu '0,8,2,10' '16,24,18,26' 4 2 2 "$MULTI" || fail "multisocket válido: $CPU_LAYOUT_ERRO"
expect_failure 'core SMT dividido' validar_layout_cpu '0,2,10,16' '8,24,18,26' 4 2 2 "$MULTI"
expect_failure 'ordem CPU não canônica' validar_layout_cpu '2,10,0,8' '16,24,18,26' 4 2 2 "$MULTI"
validar_layout_cpu '11,15,21,29' '0,4' 4 2 2 "$SPARSE" || fail "IDs esparsos/NUMA válidos: $CPU_LAYOUT_ERRO"
expect_failure 'CPU offline selecionada' validar_layout_cpu '2,6,11,15' '0,4,21,29' 4 2 2 "$SPARSE"
expect_failure 'CPU online omitida' validar_layout_cpu '11,15' '0,4' 2 1 2 "$SPARSE"

# XML: cardinalidade real do helper atual e preservação de conteúdo não gerenciado.
function_rc xml_disco_qcow2_estado "$FIXTURES/xml/domain-one.xml" /vm/fixture.qcow2
[[ $FUNCTION_RC -eq 0 && $DISCARD_XML_ESTADO == ativo ]] || fail 'disco QCOW2 singleton/unmap não foi reconhecido'
function_rc xml_disco_qcow2_estado "$FIXTURES/xml/domain-zero.xml" /vm/fixture.qcow2
[[ $FUNCTION_RC -eq 2 ]] || fail 'cardinalidade zero de QCOW2 não falhou fechado'
function_rc xml_disco_qcow2_estado "$FIXTURES/xml/domain-multiple.xml" /vm/fixture.qcow2
[[ $FUNCTION_RC -eq 2 ]] || fail 'cardinalidade múltipla de QCOW2 não falhou fechado'
function_rc xml_disco_qcow2_estado "$FIXTURES/xml/domain-malformed.xml" /vm/fixture.qcow2
[[ $FUNCTION_RC -eq 2 ]] || fail 'XML malformado não falhou fechado'
CPU_CANDIDATE="$TMP/cpu-candidate.xml"
xml_cpu_gerar_candidato "$FIXTURES/xml/domain-one.xml" "$CPU_CANDIDATE" '2-5' '0-1,6-7' 4 2 2 8192 || fail "candidato CPU: $XML_CPU_ERRO"
validar_xml_cpu_pinning "$CPU_CANDIDATE" '2-5' '0-1,6-7' 4 2 2 8192 sim || fail "validação CPU: $XML_CPU_ERRO"
grep -q 'fixture-unmanaged="keep"' "$CPU_CANDIDATE" || fail 'candidato CPU removeu atributo não gerenciado'
grep -q 'alias name="fixture-unmanaged"' "$CPU_CANDIDATE" || fail 'candidato CPU removeu elemento não gerenciado'
grep -q 'iothreadpin' "$CPU_CANDIDATE" || fail 'candidato CPU removeu iothreadpin não gerenciado'
expect_failure 'hotplug/NUMA ambíguo' xml_cpu_gerar_candidato "$FIXTURES/xml/domain-hotplug-numa.xml" "$TMP/hotplug-out.xml" '2-5' '0-1,6-7' 4 2 2 8192

# Inventário atual/legado, ordem, ausência, truncamento e mudança de identidade.
validar_inventario_principal "$FIXTURES/inventory/current.txt" || fail "$INVENTARIO_ERRO"
validar_inventario_principal "$FIXTURES/inventory/legacy.txt" || fail "$INVENTARIO_ERRO"
expect_failure 'inventário truncado' validar_inventario_principal "$FIXTURES/inventory/truncated.txt"
SNAPSHOT=$(sed -n '/^== HARDWARE IDENTITY ==$/,/^== CPU ==$/p' "$FIXTURES/inventory/current.txt" | sed '1d;$d')
comparar_inventario_com_hardware "$FIXTURES/inventory/current.txt" "$SNAPSHOT" || fail "identidade atual: $INVENTARIO_ERRO"
# Oráculo atual: a comparação ainda é sensível à ordem textual dos registros
# CPU/DISK. I6 deve normalizar por identidade; I0 apenas fixa a lacuna.
expect_failure 'inventário equivalente reordenado (lacuna conhecida)' comparar_inventario_com_hardware "$FIXTURES/inventory/current-reordered.txt" "$SNAPSHOT"
[[ ${INVENTARIO_DIFERENCAS:-} == *CPU* && ${INVENTARIO_DIFERENCAS:-} == *Discos* ]] || fail 'oráculo de ordem do inventário mudou sem atualização explícita'
expect_failure 'identidade de hardware alterada' comparar_inventario_com_hardware "$FIXTURES/inventory/identity-changed.txt" "$SNAPSHOT"
[[ ${INVENTARIO_DIFERENCAS:-} == *CPU* && ${INVENTARIO_DIFERENCAS:-} == *Discos* ]] || fail 'mudança de identidade não discriminou CPU/discos'
INV_EMPTY="$TMP/inventory-empty"
mkdir "$INV_EMPTY"
expect_failure 'inventário ausente' resolver_ultimo_inventario "$INV_EMPTY"
INV_LINK="$TMP/inventory-links"
mkdir "$INV_LINK"
cp "$FIXTURES/inventory/current.txt" "$INV_LINK/inventario-20260813-010203-000000001.txt"
ln -s inventario-20260813-010203-000000001.txt "$INV_LINK/ultimo-inventario.txt"
resolver_ultimo_inventario "$INV_LINK" >/dev/null || fail "$INVENTARIO_ERRO"
[[ $INVENTARIO_RESOLVIDO == "$INV_LINK/inventario-20260813-010203-000000001.txt" ]] || fail 'link relativo não resolveu'
rm "$INV_LINK/ultimo-inventario.txt"
ln -s /etc/passwd "$INV_LINK/ultimo-inventario.txt"
expect_failure 'link externo de inventário' resolver_ultimo_inventario "$INV_LINK"

printf 'OK: caracterização I0 de configuração, XML/JSON, CPU e inventário\n'
