#!/usr/bin/env bash
# Fase I4: prova a fronteira de configuração no lado do shell.
#
# O que este teste cobre, sempre em raízes temporárias e sem tocar o host:
#
#   * as APIs públicas (carregar_conf, salvar_conf, salvar_conf_lote,
#     validar_valor_conf) mantêm nome, retorno e efeitos, agora sobre o core;
#   * o schema do core e a allowlist do shell descrevem exatamente o mesmo
#     conjunto de chaves, mais as depreciadas, sem terceira autoridade;
#   * o caminho do conf nunca entra em argv: a ponte passa descritor de
#     diretório e o basename viaja no payload;
#   * canários de valor bruto não aparecem em stdout, stderr nem em argv;
#   * REQ-CONF-ISO migra valor legado sem abrir o caminho antigo, com backup
#     0600 e publicação única;
#   * REQ-WAIVERS remove as dispensas sem efeito por migração idempotente;
#   * o teste tem dentes: mutações injetadas precisam ser reprovadas.
set -euo pipefail

RAIZ=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
PYTHON_REAL=$(type -P python3 || true)
STAT_REAL=$(type -P stat || true)
CANARIO='CANARIO-SECRETO-I4-3d9a71'
CHECKS=0

falha() { printf 'FALHA I4 config: %s\n' "$*" >&2; exit 1; }
passo() { CHECKS=$((CHECKS + 1)); }

[[ -n $PYTHON_REAL ]] || falha 'python3 é obrigatório'
[[ -n $STAT_REAL ]] || falha 'stat é obrigatório'

TMP=$(mktemp -d "${TMPDIR:-/tmp}/i4-config.XXXXXXXX")
chmod 0700 -- "$TMP"
limpar() {
    python_core_temporarios_limpar 2>/dev/null || true
    rm -rf -- "$TMP"
}
trap limpar EXIT
trap 'python_core_temporarios_limpar 2>/dev/null || true; exit 130' INT
trap 'python_core_temporarios_limpar 2>/dev/null || true; exit 143' TERM

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

escrever_conf() {
    # escrever_conf ARQUIVO [modo]
    local arquivo=$1 modo=${2:-0600}
    cat > "$arquivo" <<CONF
# fixture I4: comentário preservado ($CANARIO)

USUARIO_LINUX='fixture'
VM_NAME="win11-fixture" # comentário de fim de linha
BOOTLOADER=grub
VM_RAM_MB="8192"
QCOW2_PATH="/vm/Windows 11.qcow2"
CONF
    chmod "$modo" -- "$arquivo"
}

# --- 1. Schema do core e allowlist do shell descrevem o mesmo conjunto -------

declare -a SCHEMA_PERMITIDAS=(
    CORE_VERSION PROTOCOL_VERSION SUBCOMMAND
    KEY_COUNT WAIVER_COUNT DEPRECATED_COUNT DEPRECATED_KEYS
    'KEY_#_NAME' 'KEY_#_CLASS' 'WAIVER_#_NAME'
)
# config-schema é read-only e não recebe payload, como `version`.
python_core_pares SCHEMA_PERMITIDAS SCH_ config-schema \
    || falha "config-schema falhou: $PYTHON_CORE_ERRO"
[[ $SCH_KEY_COUNT -eq ${#CHAVES_CONF_PERMITIDAS[@]} ]] \
    || falha "core declara $SCH_KEY_COUNT chaves e a allowlist do shell tem ${#CHAVES_CONF_PERMITIDAS[@]}"
[[ $SCH_DEPRECATED_COUNT -eq ${#CHAVES_CONF_DEPRECIADAS[@]} ]] \
    || falha "core declara $SCH_DEPRECATED_COUNT depreciadas e o shell tem ${#CHAVES_CONF_DEPRECIADAS[@]}"
[[ $SCH_WAIVER_COUNT -eq 2 ]] || falha "esperadas 2 dispensas com efeito, core diz $SCH_WAIVER_COUNT"

declare -A SCHEMA_CHAVES=()
for ((i = 0; i < SCH_KEY_COUNT; i++)); do
    nome_var="SCH_KEY_${i}_NAME"
    classe_var="SCH_KEY_${i}_CLASS"
    nome=${!nome_var}
    classe=${!classe_var}
    SCHEMA_CHAVES[$nome]=$classe
    case $classe in
        SECRET|LOCAL_IDENTIFIER|RECOVERY_LOCATOR|PUBLIC) ;;
        *) falha "classe fora da seção 3.9 para $nome: $classe" ;;
    esac
done
for chave in "${CHAVES_CONF_PERMITIDAS[@]}"; do
    [[ -n ${SCHEMA_CHAVES[$chave]+definida} ]] \
        || falha "allowlist do shell tem chave fora do schema do core: $chave"
done
for chave in "${!SCHEMA_CHAVES[@]}"; do
    chave_conf_permitida "$chave" \
        || falha "schema do core tem chave fora da allowlist do shell: $chave"
done
# As depreciadas não podem ter voltado ao schema ativo.
for chave in "${CHAVES_CONF_DEPRECIADAS[@]}"; do
    [[ -z ${SCHEMA_CHAVES[$chave]+definida} ]] \
        || falha "dispensa depreciada voltou ao schema: $chave"
done
passo

# --- 2. Round-trip, ordem, comentários e metadados ---------------------------

CONF_ARQUIVO="$TMP/roundtrip.conf"
BACKUPS_DIR="$TMP/backups"
escrever_conf "$CONF_ARQUIVO" 0640
ESTADO_ANTES=$("$STAT_REAL" -c '%a:%u:%g' -- "$CONF_ARQUIVO")

carregar_conf
[[ $VM_NAME == win11-fixture ]] || falha 'VM_NAME não carregou'
[[ $USUARIO_LINUX == fixture ]] || falha 'literal com aspas simples não carregou'
[[ $BOOTLOADER == grub ]] || falha 'literal não cotado não carregou'
[[ $QCOW2_PATH == '/vm/Windows 11.qcow2' ]] || falha 'valor com espaço não carregou'
[[ -z ${ISO_WINDOWS+x} ]] || falha 'chave ausente do arquivo ficou definida'
[[ $("$STAT_REAL" -c '%a:%u:%g' -- "$CONF_ARQUIVO") == "$ESTADO_ANTES" ]] \
    || falha 'carga alterou metadados do conf'

salvar_conf VM_NAME novo-nome
[[ $("$STAT_REAL" -c '%a:%u:%g' -- "$CONF_ARQUIVO") == "$ESTADO_ANTES" ]] \
    || falha 'gravação não preservou modo/owner/grupo'
grep -q "^# fixture I4: comentário preservado" "$CONF_ARQUIVO" \
    || falha 'gravação removeu comentário'
[[ $(grep -n '^USUARIO_LINUX=' "$CONF_ARQUIVO" | cut -d: -f1) \
   -lt $(grep -n '^VM_NAME=' "$CONF_ARQUIVO" | cut -d: -f1) ]] \
    || falha 'gravação alterou a ordem das chaves'
carregar_conf
[[ $VM_NAME == novo-nome ]] || falha 'valor salvo não fez round-trip'

# Gravação convergida é no-op exato: conteúdo e mtime invariantes.
ESTADO_EXATO=$("$STAT_REAL" -c '%s:%a:%u:%g:%Y' -- "$CONF_ARQUIVO")
HASH_ANTES=$(sha256sum "$CONF_ARQUIVO" | cut -d' ' -f1)
salvar_conf VM_NAME novo-nome
[[ $(sha256sum "$CONF_ARQUIVO" | cut -d' ' -f1) == "$HASH_ANTES" ]] \
    || falha 'segunda gravação do mesmo valor mudou o conteúdo'
[[ $("$STAT_REAL" -c '%s:%a:%u:%g:%Y' -- "$CONF_ARQUIVO") == "$ESTADO_EXATO" ]] \
    || falha 'segunda gravação do mesmo valor mudou metadados/mtime'
passo

# --- 3. Lote todo-ou-nada ----------------------------------------------------

cp -- "$CONF_ARQUIVO" "$TMP/antes-lote"
RC=0
( salvar_conf_lote VM_RAM_MB 16384 CHAVE_INVALIDA valor ) >/dev/null 2>&1 || RC=$?
[[ $RC -ne 0 ]] || falha 'lote com chave desconhecida foi aceito'
cmp -s "$TMP/antes-lote" "$CONF_ARQUIVO" || falha 'lote inválido publicou alteração parcial'

RC=0
( salvar_conf_lote VM_RAM_MB 16384 VM_RAM_MB 8192 ) >/dev/null 2>&1 || RC=$?
[[ $RC -ne 0 ]] || falha 'lote com chave repetida foi aceito'
cmp -s "$TMP/antes-lote" "$CONF_ARQUIVO" || falha 'lote repetido publicou alteração'

RC=0
( salvar_conf_lote VM_RAM_MB 12 ) >/dev/null 2>&1 || RC=$?
[[ $RC -ne 0 ]] || falha 'lote com valor fora do tipo foi aceito'
cmp -s "$TMP/antes-lote" "$CONF_ARQUIVO" || falha 'lote inválido por tipo publicou alteração'

RC=0
( salvar_conf_lote VM_RAM_MB ) >/dev/null 2>&1 || RC=$?
[[ $RC -ne 0 ]] || falha 'lote com paridade ímpar foi aceito'

salvar_conf_lote VM_RAM_MB 16384 HUGEPAGES_1G 16 CPUS_VM 2-5
carregar_conf
[[ $VM_RAM_MB == 16384 && $HUGEPAGES_1G == 16 && $CPUS_VM == 2-5 ]] \
    || falha 'lote válido não publicou todos os valores'
passo

# --- 4. Fail-closed: schema, symlink, hardlink e modo ------------------------

for caso in duplicada desconhecida maliciosa literal; do
    ARQ="$TMP/invalido-$caso.conf"
    case $caso in
        duplicada) printf 'VM_NAME="a"\nVM_NAME="b"\n' > "$ARQ" ;;
        desconhecida) printf 'VM_NAME="a"\nCHAVE_INVENTADA="x"\n' > "$ARQ" ;;
        maliciosa) printf 'VM_NAME="$(touch %s/executou)"\n' "$TMP" > "$ARQ" ;;
        literal) printf 'VM_NAME="aberto\n' > "$ARQ" ;;
    esac
    chmod 0600 -- "$ARQ"
    RC=0
    ( CONF_ARQUIVO="$ARQ"; carregar_conf ) >/dev/null 2>&1 || RC=$?
    [[ $RC -ne 0 ]] || falha "configuração $caso foi aceita"
done
[[ ! -e $TMP/executou ]] || falha 'conteúdo malicioso foi executado'

ln -s "$CONF_ARQUIVO" "$TMP/link.conf"
RC=0
( CONF_ARQUIVO="$TMP/link.conf"; carregar_conf ) >/dev/null 2>&1 || RC=$?
[[ $RC -ne 0 ]] || falha 'carga por symlink foi aceita'
RC=0
( CONF_ARQUIVO="$TMP/link.conf"; salvar_conf VM_NAME x ) >/dev/null 2>&1 || RC=$?
[[ $RC -ne 0 ]] || falha 'gravação por symlink foi aceita'

cp -- "$CONF_ARQUIVO" "$TMP/hard.conf"
ln "$TMP/hard.conf" "$TMP/hard-sombra.conf"
HASH_HARD=$(sha256sum "$TMP/hard.conf" | cut -d' ' -f1)
RC=0
( CONF_ARQUIVO="$TMP/hard.conf"; salvar_conf VM_NAME x ) >/dev/null 2>&1 || RC=$?
[[ $RC -ne 0 ]] || falha 'gravação em arquivo com dois links foi aceita'
[[ $(sha256sum "$TMP/hard.conf" | cut -d' ' -f1) == "$HASH_HARD" ]] \
    || falha 'recusa por hardlink alterou o alvo'

cp -- "$CONF_ARQUIVO" "$TMP/mundo.conf"
chmod 0666 -- "$TMP/mundo.conf"
RC=0
( CONF_ARQUIVO="$TMP/mundo.conf"; carregar_conf ) >/dev/null 2>&1 || RC=$?
[[ $RC -ne 0 ]] || falha 'configuração gravável por outros foi aceita'

# Modo herdado de cópia manual converge na gravação, sem afrouxar.
cp -- "$CONF_ARQUIVO" "$TMP/aberto.conf"
chmod 0755 -- "$TMP/aberto.conf"
( CONF_ARQUIVO="$TMP/aberto.conf"; carregar_conf >/dev/null 2>&1; salvar_conf VM_NAME convergido )
[[ $("$STAT_REAL" -c '%a' -- "$TMP/aberto.conf") == 750 ]] \
    || falha "modo não convergiu: $("$STAT_REAL" -c '%a' -- "$TMP/aberto.conf")"
passo

# --- 5. validar_valor_conf pela mesma implementação --------------------------

validar_valor_conf VM_NAME win11 || falha 'valor válido foi recusado'
validar_valor_conf VM_NAME '' || falha 'valor vazio devia ser aceito'
! validar_valor_conf VM_NAME 'com espaço' || falha 'valor inválido foi aceito'
! validar_valor_conf VM_RAM_MB 12 || falha 'inteiro fora de faixa foi aceito'
! validar_valor_conf CHAVE_INVENTADA x || falha 'chave fora da allowlist foi aceita'
! validar_valor_conf AIRLOCK_DISPENSADO sim || falha 'dispensa depreciada foi aceita'
passo

# --- 6. Transporte: caminho do conf nunca em argv ---------------------------

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
        --input-file=*)
            "$STAT_REAL" -c '%a %h %U %F' -- "\${argumento#*=}" >> "$MODE_LOG"
            ;;
    esac
done
exec "$PYTHON_REAL" "\$@"
SHIMEOF
chmod 0755 -- "$SHIM/python3"

PATH_ORIGINAL=$PATH
PATH="$SHIM:$PATH"
carregar_conf || { PATH=$PATH_ORIGINAL; falha 'carga sob shim falhou'; }
salvar_conf VM_NAME sob-shim || { PATH=$PATH_ORIGINAL; falha 'gravação sob shim falhou'; }
PATH=$PATH_ORIGINAL

mapfile -d '' -t ARGV_CAPTURADO < "$ARGV_LOG"
(( ${#ARGV_CAPTURADO[@]} > 0 )) || falha 'shim não registrou argv'
argv_tem_dirfd=0
for argumento in "${ARGV_CAPTURADO[@]}"; do
    [[ $argumento != *"$CANARIO"* ]] || falha 'canário do conf apareceu em argv'
    [[ $argumento != *"$TMP/roundtrip.conf"* ]] || falha 'caminho do conf apareceu em argv'
    [[ $argumento != *'VM_NAME='* ]] || falha 'conteúdo do conf apareceu em argv'
    [[ $argumento != *'"payload"'* ]] || falha 'JSON apareceu em argv'
    case $argumento in
        --dir-fd=*)
            argv_tem_dirfd=1
            [[ ${argumento#--dir-fd=} =~ ^[0-9]+$ ]] \
                || falha 'descritor de diretório não é escalar numérico'
            ;;
    esac
done
(( argv_tem_dirfd == 1 )) || falha 'argv não recebeu o descritor de diretório'
[[ -s $MODE_LOG ]] || falha 'shim não inspecionou o payload controlado'
while read -r modo links dono tipo; do
    [[ $modo == 600 ]] || falha "payload controlado com modo $modo"
    [[ $links == 1 ]] || falha "payload controlado com $links links"
    [[ $dono == "$(id -un)" ]] || falha "payload controlado pertence a $dono"
    [[ $tipo == 'regular file' || $tipo == 'regular empty file' ]] \
        || falha "payload controlado não é regular: $tipo"
done < "$MODE_LOG"

# Diagnóstico de valor inválido não publica o valor bruto.
ARQ="$TMP/canario-valor.conf"
printf 'VM_NAME="%s com espaço"\n' "$CANARIO" > "$ARQ"
chmod 0600 -- "$ARQ"
SAIDA_ERRO="$TMP/canario.err"
RC=0
( CONF_ARQUIVO="$ARQ"; carregar_conf ) >"$TMP/canario.out" 2>"$SAIDA_ERRO" || RC=$?
[[ $RC -ne 0 ]] || falha 'valor inválido com canário foi aceito'
grep -q "$CANARIO" "$SAIDA_ERRO" && falha 'canário vazou no stderr do diagnóstico'
grep -q "$CANARIO" "$TMP/canario.out" && falha 'canário vazou no stdout'
grep -q 'VM_NAME' "$SAIDA_ERRO" || falha 'diagnóstico não nomeia a chave'
grep -q 'LOCAL_IDENTIFIER' "$SAIDA_ERRO" || falha 'diagnóstico não declara a classe'
passo

# --- 7. REQ-CONF-ISO: migração pré-parser ------------------------------------

ISO_CONF="$TMP/iso-legado.conf"
CONF_ARQUIVO="$ISO_CONF"
printf '%s\n' '# legado' 'VM_NAME="win11"' \
    'ISO_WINDOWS="/home/alice/Downloads/Win11.iso"' \
    'ISO_VIRTIO="/vm/virtio-win.iso"' 'VM_RAM_MB="8192"' > "$ISO_CONF"
chmod 0600 -- "$ISO_CONF"

RC=0
conf_iso_legada_classificar || RC=$?
[[ $RC -eq 1 ]] || falha "classificação legada devia devolver 1, devolveu $RC"
[[ $CONF_ISO_LEGADA_ESTADO_WINDOWS == invalida ]] || falha 'ISO legada não foi classificada como inválida'
[[ $CONF_ISO_LEGADA_ESTADO_VIRTIO == valida ]] || falha 'ISO válida foi classificada errado'
[[ $CONF_ISO_LEGADA_PENDENTES == 1 ]] || falha 'contagem de pendências divergiu'

RC=0
( carregar_conf ) >/dev/null 2>&1 || RC=$?
[[ $RC -ne 0 ]] || falha 'parser estrito aceitou a ISO legada inválida'

HASH_LEGADO=$(sha256sum "$ISO_CONF" | cut -d' ' -f1)
# Sem pipeline: um `|` colocaria a função em subshell e o backup registrado se
# perderia, exatamente como aconteceria se a etapa 02 a chamasse errado.
printf '\n' > "$TMP/entrada-migracao"
conf_migrar_iso_legada > "$TMP/migracao.out" 2>&1 < "$TMP/entrada-migracao" \
    || falha "migração de ISO falhou: $(tail -1 "$TMP/migracao.out")"
grep -q "$CANARIO" "$TMP/migracao.out" && falha 'canário vazou na migração'
grep -q '/home/alice' "$TMP/migracao.out" \
    && falha 'a migração publicou o caminho legado no diagnóstico'
[[ -n $CONF_MIGRACAO_ISO_BACKUP ]] || falha 'migração não registrou backup'
[[ $("$STAT_REAL" -c '%a' -- "$CONF_MIGRACAO_ISO_BACKUP") == 600 ]] \
    || falha 'backup da migração não está em 0600'
[[ $(sha256sum "$CONF_MIGRACAO_ISO_BACKUP" | cut -d' ' -f1) == "$HASH_LEGADO" ]] \
    || falha 'backup não preservou o conteúdo legado'
carregar_conf
[[ -z $ISO_WINDOWS ]] || falha 'ISO legada não foi esvaziada'
[[ $ISO_VIRTIO == /vm/virtio-win.iso ]] || falha 'migração alterou a chave válida'
[[ $VM_RAM_MB == 8192 ]] || falha 'migração perdeu outra chave'
grep -q '^# legado' "$ISO_CONF" || falha 'migração removeu comentário'

BACKUPS_ANTES=$(find "$BACKUPS_DIR" -name 'passthrough.conf.pre-iso-migracao-*' | wc -l)
conf_migrar_iso_legada >/dev/null 2>&1 || falha 'segunda migração falhou'
BACKUPS_DEPOIS=$(find "$BACKUPS_DIR" -name 'passthrough.conf.pre-iso-migracao-*' | wc -l)
[[ $BACKUPS_ANTES -eq $BACKUPS_DEPOIS ]] \
    || falha 'segunda migração criou backup sobre configuração já válida'
passo

# --- 8. REQ-WAIVERS: depreciação por migração -------------------------------

DISP_CONF="$TMP/dispensas.conf"
CONF_ARQUIVO="$DISP_CONF"
printf '%s\n' '# antigo' 'VM_NAME="win11"' 'AIRLOCK_DISPENSADO="sim"' \
    'BACKUP_DISPENSADO=""' 'VM_RAM_MB="8192"' > "$DISP_CONF"
chmod 0600 -- "$DISP_CONF"

carregar_conf > "$TMP/dispensa.out" 2>&1
grep -q 'dispensa sem efeito' "$TMP/dispensa.out" \
    || falha 'carga não avisou sobre dispensa sem efeito'
[[ -z ${AIRLOCK_DISPENSADO+x} ]] || falha 'dispensa depreciada foi exposta como variável'
[[ $VM_NAME == win11 ]] || falha 'carga com dispensa depreciada perdeu outras chaves'

conf_migrar_dispensas_depreciadas >/dev/null 2>&1 \
    || falha 'migração de dispensas falhou'
grep -q 'DISPENSADO' "$DISP_CONF" && falha 'linha depreciada sobreviveu à migração'
carregar_conf >/dev/null 2>&1
[[ $VM_NAME == win11 && $VM_RAM_MB == 8192 ]] || falha 'migração de dispensas perdeu chaves'

HASH_DISP=$(sha256sum "$DISP_CONF" | cut -d' ' -f1)
conf_migrar_dispensas_depreciadas >/dev/null 2>&1 \
    || falha 'segunda migração de dispensas falhou'
[[ $(sha256sum "$DISP_CONF" | cut -d' ' -f1) == "$HASH_DISP" ]] \
    || falha 'segunda migração de dispensas alterou o arquivo'

# As duas dispensas que restaram continuam com efeito e são aceitas.
salvar_conf_lote WORKING_DISK_PATH '' WORKING_DISK_DISPENSADO sim
carregar_conf >/dev/null 2>&1
[[ $WORKING_DISK_DISPENSADO == sim ]] || falha 'dispensa com efeito não persistiu'

# Relação contraditória é reportada em toda carga.
salvar_conf WORKING_DISK_PATH /mnt/w
carregar_conf > "$TMP/relacao.out" 2>&1
grep -q 'contraditória entre caminho e dispensa' "$TMP/relacao.out" \
    || falha 'relação contraditória não foi reportada'
passo

# --- 9. Apenas o exemplo neutro é versionado (I4.9) -------------------------

RASTREADOS=$(cd -- "$RAIZ" && git ls-files | grep -c '^passthrough\.conf' || true)
[[ $RASTREADOS -eq 1 ]] || falha "há $RASTREADOS arquivos passthrough.conf* rastreados; esperado só o exemplo"
(cd -- "$RAIZ" && git ls-files --error-unmatch passthrough.conf.example >/dev/null 2>&1) \
    || falha 'o exemplo neutro não está rastreado'
(cd -- "$RAIZ" && git ls-files --error-unmatch passthrough.conf >/dev/null 2>&1) \
    && falha 'a configuração local entrou no índice'
(cd -- "$RAIZ" && git check-ignore -q passthrough.conf) \
    || falha 'a configuração local não está ignorada'
[[ -z $(cd -- "$RAIZ" && git log --all --oneline -- passthrough.conf) ]] \
    || falha 'a configuração local aparece no histórico'
# O exemplo não pode conter identidade de hardware real.
if grep -Eq '(10de:|0000:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]|([0-9a-f]{2}:){5}[0-9a-f]{2})' \
    "$RAIZ/passthrough.conf.example"; then
    falha 'o exemplo versionado contém identificador de hardware concreto'
fi
CONF_ARQUIVO="$RAIZ/passthrough.conf.example"
ESTADO_EXEMPLO=$("$STAT_REAL" -c '%d:%i:%s:%a:%Y' -- "$CONF_ARQUIVO")
carregar_conf >/dev/null 2>&1 || falha 'o exemplo neutro não carrega'
[[ $("$STAT_REAL" -c '%d:%i:%s:%a:%Y' -- "$CONF_ARQUIVO") == "$ESTADO_EXEMPLO" ]] \
    || falha 'a carga alterou o exemplo versionado'
passo

# --- 10. Dentes: mutações injetadas precisam reprovar -----------------------

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
set -uo pipefail
source "$1/lib/common.sh" 2>/dev/null || exit 20
trap 'python_core_temporarios_limpar 2>/dev/null || true' EXIT
raiz_teste="$2"
CONF_ARQUIVO="$raiz_teste/bateria.conf"
BACKUPS_DIR="$raiz_teste/bateria-backups"
printf '%s\n' '# c' 'VM_NAME="win11"' 'VM_RAM_MB="8192"' > "$CONF_ARQUIVO"
chmod 0600 "$CONF_ARQUIVO"
# 1. Round-trip básico.
export ISO_WINDOWS=/vm/herdado.iso
carregar_conf || exit 10
[ "$VM_NAME" = win11 ] || exit 11
# Chave ausente do arquivo não pode sobreviver do ambiente anterior.
[ -z "${ISO_WINDOWS+definida}" ] || exit 19
salvar_conf VM_NAME outro || exit 12
carregar_conf || exit 13
[ "$VM_NAME" = outro ] || exit 14
# 2. Comentário preservado.
grep -q '^# c' "$CONF_ARQUIVO" || exit 15
# 3. Chave desconhecida recusada. O subshell é obrigatório: carregar_conf usa
#    `falhar`, que encerra o processo, e não devolve status ao chamador.
printf 'CHAVE_INVENTADA="x"\n' >> "$CONF_ARQUIVO"
rc=0
( carregar_conf ) >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || exit 16
# 4. Hardlink recusado.
printf '%s\n' 'VM_NAME="win11"' > "$raiz_teste/hard.conf"
chmod 0600 "$raiz_teste/hard.conf"
ln "$raiz_teste/hard.conf" "$raiz_teste/hard2.conf"
rc=0
( CONF_ARQUIVO="$raiz_teste/hard.conf"; salvar_conf VM_NAME x ) >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || exit 17
# 5. ISO legada classificada sem abrir o caminho.
printf '%s\n' 'ISO_WINDOWS="/home/alice/x.iso"' > "$raiz_teste/iso.conf"
chmod 0600 "$raiz_teste/iso.conf"
rc=0
( CONF_ARQUIVO="$raiz_teste/iso.conf"; conf_iso_legada_classificar ) || rc=$?
[ "$rc" -eq 1 ] || exit 18
exit 0
BATERIA

COPIA_RAIZ="$TMP/mutado"
BATERIA_DIR="$TMP/bateria"
mkdir -p -- "$BATERIA_DIR"
chmod 0700 -- "$BATERIA_DIR"

preparar_copia() {
    rm -rf -- "$COPIA_RAIZ"
    mkdir -p -- "$COPIA_RAIZ"
    cp -a -- "$RAIZ/lib" "$COPIA_RAIZ/lib"
    cp -a -- "$RAIZ/libexec" "$COPIA_RAIZ/libexec"
    cp -a -- "$RAIZ/passthrough.conf.example" "$COPIA_RAIZ/passthrough.conf.example"
}

executar_mutacao() {
    local descricao=$1 alvo=$2 antigo=$3 novo=$4 rc=0
    preparar_copia
    python3 "$TMP/mutar.py" "$COPIA_RAIZ/$alvo" "$antigo" "$novo" \
        || falha "mutação '$descricao' não pôde ser aplicada"
    rm -rf -- "$BATERIA_DIR"
    mkdir -p -- "$BATERIA_DIR"
    chmod 0700 -- "$BATERIA_DIR"
    bash "$TMP/bateria.sh" "$COPIA_RAIZ" "$BATERIA_DIR" >/dev/null 2>&1 || rc=$?
    [[ $rc -ne 0 ]] || falha "mutação '$descricao' passou sem ser detectada"
    rm -rf -- "$COPIA_RAIZ"
}

preparar_copia
rm -rf -- "$BATERIA_DIR"
mkdir -p -- "$BATERIA_DIR"
chmod 0700 -- "$BATERIA_DIR"
bash "$TMP/bateria.sh" "$COPIA_RAIZ" "$BATERIA_DIR" \
    || falha 'a bateria de mutação reprovou a árvore intacta'
rm -rf -- "$COPIA_RAIZ"

# O schema tem duas guardas independentes (parser e validador), então abrir só
# uma delas não é observável: é defesa em profundidade deliberada. A mutação
# abaixo ataca o que a bateria realmente prova, a persistência.
executar_mutacao 'gravação não persiste' \
    lib/shell/config.sh \
    'falhar "Falha ao publicar a configuração: $(_core_diagnostico '"'"'persistência recusada'"'"')"' \
    'return 0'

# Âncora específica de _check_sensitive: a checagem de nlink também existe em
# _read_from_private_root (entrada controlada de I2), e mutar a errada não seria
# observável por este teste.
executar_mutacao 'hardlink aceito no arquivo sensível' \
    libexec/passthrough_core/cli.py \
    '    if info.st_nlink != 1:
        raise ConflictError(
            "O arquivo sensível possui mais de um link; publicação recusada."
        )' \
    '    if False:
        raise ConflictError(
            "O arquivo sensível possui mais de um link; publicação recusada."
        )'

executar_mutacao 'comentários descartados na reescrita' \
    libexec/passthrough_core/config.py \
    '        rendered.append(entry["text"])' \
    '        rendered.append(entry["text"] if entry["kind"] == "key" else "")'

executar_mutacao 'classificação legada nunca acha pendência' \
    libexec/passthrough_core/config.py \
    '    data["needs_migration"] = precisa_migrar' \
    '    data["needs_migration"] = 0'

# A limpeza de chave ausente também tem duas guardas (o unset inicial de
# carregar_conf e o else do laço de carga), então nenhuma das duas isolada é
# observável. A mutação abaixo ataca o alvo do descritor de diretório, que é
# justamente o que substituiu o caminho em argv.
executar_mutacao 'descritor aponta para o diretório errado' \
    lib/shell/config.sh \
    '            CONF_DIRETORIO_ALVO="${caminho%/*}"' \
    '            CONF_DIRETORIO_ALVO="$(pwd -P)"'
passo

# --- 11. Checkout intacto ---------------------------------------------------

python_core_temporarios_limpar
RESIDUO=$(cd -- "$RAIZ" && find . -path ./.git -prune -o \
    \( -name '__pycache__' -o -name '*.pyc' \) -print -quit)
[[ -z $RESIDUO ]] || falha "bytecode residual no checkout: $RESIDUO"
snapshot_checkout "$TMP/checkout.depois"
diff -u "$TMP/checkout.antes" "$TMP/checkout.depois" \
    || falha 'o checkout mudou durante o teste'

printf 'OK: fronteira de configuração de I4 (%d grupos), schema classificado, transporte por descritor, ISO legada e dispensas migradas, 5 mutações reprovadas\n' \
    "$CHECKS"
