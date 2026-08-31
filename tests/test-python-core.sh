#!/usr/bin/env bash
# Fase I2: prova o bootstrap isolado, o protocolo e a ponte única do core Python.
# Tudo roda em raízes temporárias e ambientes hostis simulados; nenhum arquivo do
# checkout é alterado e nenhum mutador do host é chamado.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
ENTRYPOINT="$ROOT/libexec/passthrough_core_cli.py"
RUNNER="$ROOT/tests/python/run_tests.py"
PYTHON_REAL=$(type -P python3 || true)
STAT_REAL=$(type -P stat || true)

fail() { printf 'FALHA I2 python-core: %s\n' "$*" >&2; exit 1; }

[[ -n $PYTHON_REAL ]] || fail 'python3 é obrigatório para executar este teste'
[[ -n $STAT_REAL ]] || fail 'stat é obrigatório para executar este teste'
[[ -f $ENTRYPOINT ]] || fail "entrypoint ausente: $ENTRYPOINT"
[[ -f $RUNNER ]] || fail "runner ausente: $RUNNER"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/i2-python-core.XXXXXXXX")
ESPACOS="$TMP/dir com espaços"
cleanup() {
    python_core_temporarios_limpar 2>/dev/null || true
    rm -rf -- "$TMP"
}
trap cleanup EXIT
trap 'python_core_temporarios_limpar 2>/dev/null || true; exit 130' INT
trap 'python_core_temporarios_limpar 2>/dev/null || true; exit 143' TERM
mkdir -p -- "$ESPACOS"

# --- Fotografia do checkout ---------------------------------------------------
# Conteúdo, tamanho, modo e mtime de alta resolução de tudo que não é .git.

snapshot_checkout() {
    local destino=$1
    (
        cd -- "$ROOT"
        find . -path ./.git -prune -o -type f -printf '%p\t%s\t%m\t%T@\n' \
            | LC_ALL=C sort
        find . -path ./.git -prune -o -type f -print0 \
            | LC_ALL=C sort -z \
            | xargs -0 -r sha256sum
    ) > "$destino"
}

exigir_sem_bytecode() {
    local residuo
    residuo=$(
        cd -- "$ROOT"
        find . -path ./.git -prune -o \
            \( -name '__pycache__' -o -name '*.pyc' -o -name '*.pyo' \) \
            -print -quit
    )
    [[ -z $residuo ]] || fail "bytecode residual no checkout: $residuo"
}

snapshot_checkout "$TMP/checkout.antes"
exigir_sem_bytecode

# --- 1. Suíte unittest sob isolamento ----------------------------------------
# O runner prova, de dentro do processo, flags de isolamento, sys.path sem
# pacotes globais e ausência de bytecode.

LC_ALL=C python3 -I -S -B "$RUNNER" > "$TMP/unittest.out" 2> "$TMP/unittest.err" \
    || { cat -- "$TMP/unittest.err" >&2; fail 'suíte unittest do core reprovou'; }
[[ ! -s $TMP/unittest.out ]] || fail 'o runner unittest não deve escrever em stdout'
grep -q '^OK$' "$TMP/unittest.err" || fail 'relatório do unittest sem OK final'
TOTAL_UNITTEST=$(sed -n 's/^Ran \([0-9]\+\) tests\? in .*/\1/p' "$TMP/unittest.err")
[[ ${TOTAL_UNITTEST:-0} -ge 100 ]] || fail "suíte unittest com apenas ${TOTAL_UNITTEST:-0} casos"

# --- 2. version é idêntico de qualquer cwd -----------------------------------

VERSION_ESPERADA=$(cd -- "$ROOT" && LC_ALL=C python3 -I -S -B "$ENTRYPOINT" version)
for diretorio in "$ROOT" / "$ESPACOS" "$TMP"; do
    obtida=$(cd -- "$diretorio" && LC_ALL=C python3 -I -S -B "$ENTRYPOINT" version) \
        || fail "version falhou com cwd $diretorio"
    [[ $obtida == "$VERSION_ESPERADA" ]] \
        || fail "version divergiu com cwd $diretorio"
done
[[ $VERSION_ESPERADA == *'"protocol_version":1'* ]] \
    || fail 'version não declarou protocol_version 1'
[[ $VERSION_ESPERADA == *'"core_version"'* ]] \
    || fail 'version não declarou core_version'

# O entrypoint também funciona quando o próprio checkout está sob caminho com
# espaços: este repositório já está em um caminho assim, o que cobre o caso.
[[ $ROOT == *' '* ]] || printf 'AVISO: checkout sem espaço no caminho; cobertura vem do cwd\n' >&2

# --- 3. Ambiente hostil: PYTHONPATH, sitecustomize e .pth --------------------

HOSTIL="$TMP/hostil"
CANARIO_ENV="$TMP/canario-env"
mkdir -p -- "$HOSTIL"
cat > "$HOSTIL/sitecustomize.py" <<'PY'
import os
import pathlib

pathlib.Path(os.environ["I2_CANARIO_MARCADOR"]).write_text("sitecustomize\n")
PY
cat > "$HOSTIL/canario.pth" <<'PTH'
import os, pathlib; pathlib.Path(os.environ["I2_CANARIO_MARCADOR"]).write_text("pth\n")
PTH
cat > "$HOSTIL/passthrough_core.py" <<'PY'
raise SystemExit("package canário do PYTHONPATH foi importado")
PY

saida_hostil=$(
    cd -- "$TMP"
    I2_CANARIO_MARCADOR="$CANARIO_ENV" \
    PYTHONPATH="$HOSTIL" \
    PYTHONHOME="$HOSTIL" \
    PYTHONSTARTUP="$HOSTIL/sitecustomize.py" \
    PYTHONDONTWRITEBYTECODE= \
    LC_ALL=C python3 -I -S -B "$ENTRYPOINT" version
) || fail 'version falhou sob ambiente hostil'
[[ $saida_hostil == "$VERSION_ESPERADA" ]] || fail 'ambiente hostil alterou a saída de version'
[[ ! -e $CANARIO_ENV ]] || fail 'canário de sitecustomize/.pth foi executado'
exigir_sem_bytecode

# O runner de testes precisa do mesmo isolamento.
(
    cd -- "$TMP"
    I2_CANARIO_MARCADOR="$CANARIO_ENV" PYTHONPATH="$HOSTIL" \
        LC_ALL=C python3 -I -S -B "$RUNNER"
) > /dev/null 2>&1 || fail 'runner unittest reprovou sob PYTHONPATH hostil'
[[ ! -e $CANARIO_ENV ]] || fail 'canário foi executado pelo runner unittest'

# --- 4. Invocação fora da ponte é recusada -----------------------------------

for flags in "" "-I" "-S" "-I -S"; do
    rc=0
    # shellcheck disable=SC2086
    LC_ALL=C python3 $flags "$ENTRYPOINT" version > "$TMP/direto.out" 2> "$TMP/direto.err" \
        || rc=$?
    [[ $rc -eq 64 ]] || fail "invocação com flags '${flags:-nenhuma}' devia falhar com 64, obteve $rc"
    [[ ! -s $TMP/direto.out ]] || fail 'invocação recusada escreveu em stdout'
    grep -q 'lib/python-core.sh' "$TMP/direto.err" \
        || fail 'diagnóstico de invocação não aponta a ponte única'
done
exigir_sem_bytecode

# --- 5. Ponte: carga isolada e por common.sh ---------------------------------

bash -c 'set -euo pipefail; source "$1/lib/common.sh"; declare -F python_core_executar >/dev/null' \
    _ "$ROOT" || fail 'common.sh não expõe a ponte do core'
bash -c 'set -euo pipefail; source "$1/lib/python-core.sh"; source "$1/lib/python-core.sh"; declare -F python_core_executar >/dev/null' \
    _ "$ROOT" || fail 'source duplo da ponte não é idempotente'

# shellcheck source=lib/python-core.sh
source "$ROOT/lib/python-core.sh"

python_core_disponivel || fail "core indisponível: $PYTHON_CORE_ERRO"
[[ $PYTHON_CORE_VERSAO_PROTOCOL_VERSION == 1 ]] || fail 'protocolo divergente na ponte'
[[ -n $PYTHON_CORE_VERSAO_CORE_VERSION ]] || fail 'core_version vazio na ponte'
python_core_disponivel || fail 'segunda consulta de disponibilidade divergiu'

python_core_executar version || fail "python_core_executar version: $PYTHON_CORE_ERRO"
[[ $PYTHON_CORE_SAIDA == "$VERSION_ESPERADA" ]] || fail 'ponte alterou a saída de version'
[[ -z $PYTHON_CORE_ERRO ]] || fail 'chamada bem-sucedida produziu diagnóstico'
[[ $PYTHON_CORE_STATUS -eq 0 ]] || fail 'status interno divergente em sucesso'

rc=0
python_core_executar '' > /dev/null 2>&1 || rc=$?
[[ $rc -eq $PYTHON_CORE_EXIT_USO ]] || fail 'subcomando vazio não retornou 64'

# --- 6. Transporte de payload: stdin e arquivo controlado 0600 ---------------

CANARIO='CANARIO-SECRETO-I2-0f3a9c'
PAYLOAD_HOSTIL=$(printf '{\n  "protocol_version": 1,\n  "payload": {\n    "espacos": "a b  c",\n    "hifen": "-rf --force",\n    "meta": "$(id) `id` ; | & > <",\n    "acentos": "instalação ção",\n    "escape": "linha1\\nlinha2\\ttab",\n    "segredo": "%s"\n  }\n}' "$CANARIO")
DIGEST_ESPERADO=$(printf '%s' "$PAYLOAD_HOSTIL" | sha256sum)
DIGEST_ESPERADO=${DIGEST_ESPERADO%% *}
BYTES_ESPERADOS=$(printf '%s' "$PAYLOAD_HOSTIL" | wc -c)

python_core_executar_stdin payload-probe PAYLOAD_HOSTIL \
    || fail "transporte por stdin falhou: $PYTHON_CORE_ERRO"
[[ $PYTHON_CORE_SAIDA == *"\"sha256\":\"$DIGEST_ESPERADO\""* ]] \
    || fail 'digest do payload por stdin divergiu'
[[ $PYTHON_CORE_SAIDA == *"\"byte_length\":$BYTES_ESPERADOS"* ]] \
    || fail 'tamanho do payload por stdin divergiu'
[[ $PYTHON_CORE_SAIDA != *"$CANARIO"* ]] || fail 'canário vazou no stdout de máquina'

# Arquivo controlado: um shim registra argv e os metadados do arquivo recebido.
ARGV_LOG="$TMP/argv.log"
MODE_LOG="$TMP/mode.log"
SHIM_DIR="$TMP/bin"
: > "$ARGV_LOG"
: > "$MODE_LOG"
mkdir -p -- "$SHIM_DIR"
cat > "$SHIM_DIR/python3" <<SHIM
#!/usr/bin/env bash
printf '%s\0' "\$@" >> "$ARGV_LOG"
for argumento in "\$@"; do
    case \$argumento in
        --input-file=*)
            "$STAT_REAL" -c '%a %h %U %F' -- "\${argumento#--input-file=}" >> "$MODE_LOG"
            ;;
    esac
done
exec "$PYTHON_REAL" "\$@"
SHIM
chmod 0755 -- "$SHIM_DIR/python3"

PATH_ORIGINAL=$PATH
PATH="$SHIM_DIR:$PATH"
python_core_executar_arquivo payload-probe PAYLOAD_HOSTIL --operation-id=i2probe \
    || { PATH=$PATH_ORIGINAL; fail "transporte por arquivo falhou: $PYTHON_CORE_ERRO"; }
PATH=$PATH_ORIGINAL

[[ $PYTHON_CORE_SAIDA == *"\"sha256\":\"$DIGEST_ESPERADO\""* ]] \
    || fail 'digest do payload por arquivo divergiu'
[[ $PYTHON_CORE_SAIDA == *'"operation_id":"i2probe"'* ]] \
    || fail 'identificador escalar não foi ecoado'
[[ $PYTHON_CORE_SAIDA != *"$CANARIO"* ]] || fail 'canário vazou na saída do transporte por arquivo'

mapfile -d '' -t ARGV_CAPTURADO < "$ARGV_LOG"
(( ${#ARGV_CAPTURADO[@]} > 0 )) || fail 'shim não registrou argv'
argv_tem_flags=0
argv_tem_entrada=0
for argumento in "${ARGV_CAPTURADO[@]}"; do
    [[ $argumento != *"$CANARIO"* ]] || fail 'payload apareceu em argv'
    [[ $argumento != *'"payload"'* ]] || fail 'JSON apareceu em argv'
    case $argumento in
        --input-file=*) argv_tem_entrada=1 ;;
        -I) argv_tem_flags=1 ;;
    esac
done
(( argv_tem_entrada == 1 )) || fail 'argv não recebeu o localizador do arquivo controlado'
(( argv_tem_flags == 1 )) || fail 'argv não recebeu as flags de isolamento'
[[ -s $MODE_LOG ]] || fail 'shim não inspecionou o arquivo controlado'
while read -r modo links dono tipo; do
    [[ $modo == 600 ]] || fail "arquivo controlado com modo $modo"
    [[ $links == 1 ]] || fail "arquivo controlado com $links links"
    [[ $dono == "$(id -un)" ]] || fail "arquivo controlado pertence a $dono"
    [[ $tipo == 'regular file' || $tipo == 'regular empty file' ]] \
        || fail "arquivo controlado não é regular: $tipo"
done < "$MODE_LOG"

# --- 7. Erros do protocolo pela ponte ----------------------------------------

VAZIO=''
rc=0
python_core_executar_stdin payload-probe VAZIO > /dev/null 2>&1 || rc=$?
[[ $rc -eq $PYTHON_CORE_EXIT_ENTRADA_AUSENTE ]] || fail "payload vazio devia dar 66, deu $rc"

MALFORMADO='{"protocol_version":1,'
rc=0
python_core_executar_arquivo payload-probe MALFORMADO > /dev/null 2>&1 || rc=$?
[[ $rc -eq $PYTHON_CORE_EXIT_DADO ]] || fail "payload malformado devia dar 65, deu $rc"
[[ -n $PYTHON_CORE_ERRO ]] || fail 'erro do core não foi preservado na ponte'
[[ -z $PYTHON_CORE_SAIDA ]] || fail 'stdout de máquina não ficou vazio no erro'

PROTOCOLO_ANTIGO='{"protocol_version":2,"payload":{}}'
rc=0
python_core_executar_stdin payload-probe PROTOCOLO_ANTIGO > /dev/null 2>&1 || rc=$?
[[ $rc -eq $PYTHON_CORE_EXIT_DADO ]] || fail "protocolo divergente devia dar 65, deu $rc"

rc=0
python_core_executar_stdin payload-probe NAO_DEFINIDA > /dev/null 2>&1 || rc=$?
[[ $rc -eq $PYTHON_CORE_EXIT_USO ]] || fail "variável de payload ausente devia dar 64, deu $rc"
for nome in '_pc_es_nome' '1invalido' 'com-hifen'; do
    rc=0
    python_core_executar_stdin payload-probe "$nome" > /dev/null 2>&1 || rc=$?
    [[ $rc -eq $PYTHON_CORE_EXIT_USO ]] || fail "nome '$nome' devia ser recusado com 64"
done

# --- 8. Canal de pares -------------------------------------------------------

declare -a PERMITIDAS_PROBE=(
    BYTE_LENGTH CORE_VERSION KEY_COUNT OPERATION_ID PROTOCOL_VERSION SHA256 SUBCOMMAND
)
python_core_pares_stdin PERMITIDAS_PROBE I2_ payload-probe PAYLOAD_HOSTIL \
    || fail "canal de pares falhou: $PYTHON_CORE_ERRO"
[[ $I2_SHA256 == "$DIGEST_ESPERADO" ]] || fail 'canal de pares trouxe digest divergente'
[[ $I2_BYTE_LENGTH == "$BYTES_ESPERADOS" ]] || fail 'canal de pares trouxe tamanho divergente'
[[ $I2_SUBCOMMAND == payload-probe ]] || fail 'canal de pares trouxe subcomando divergente'
[[ $I2_PROTOCOL_VERSION == 1 ]] || fail 'canal de pares trouxe protocolo divergente'

declare -a PERMITIDAS_PARCIAL=(CORE_VERSION)
rc=0
python_core_pares PERMITIDAS_PARCIAL '' version > /dev/null 2>&1 || rc=$?
[[ $rc -eq $PYTHON_CORE_EXIT_DADO ]] || fail 'allowlist incompleta devia recusar a carga'
[[ -z ${SEM_PREFIXO_PROTOCOL_VERSION:-} ]] || fail 'carga parcial publicou variável'

# Negativos do parser de pares, com arquivos sintéticos.
declare -a PERMITIDAS_SIMPLES=(CHAVE OUTRA)
printf '%s\0' CHAVE valor OUTRA 'com espaço' > "$TMP/pares.ok"
_python_core_carregar_pares "$TMP/pares.ok" PERMITIDAS_SIMPLES 'T_' \
    || fail "parser de pares recusou entrada válida: $PYTHON_CORE_ERRO"
[[ $T_CHAVE == valor && $T_OUTRA == 'com espaço' ]] || fail 'parser de pares atribuiu valor errado'

printf '%s\0' CHAVE valor OUTRA > "$TMP/pares.impar"
! _python_core_carregar_pares "$TMP/pares.impar" PERMITIDAS_SIMPLES 'T_' \
    || fail 'parser de pares aceitou paridade inválida'
printf '%s\0' minuscula valor > "$TMP/pares.minuscula"
! _python_core_carregar_pares "$TMP/pares.minuscula" PERMITIDAS_SIMPLES '' \
    || fail 'parser de pares aceitou chave minúscula'
printf '%s\0' FORA valor > "$TMP/pares.fora"
! _python_core_carregar_pares "$TMP/pares.fora" PERMITIDAS_SIMPLES '' \
    || fail 'parser de pares aceitou chave fora da allowlist'
: > "$TMP/pares.vazio"
! _python_core_carregar_pares "$TMP/pares.vazio" PERMITIDAS_SIMPLES '' \
    || fail 'parser de pares aceitou saída vazia'
declare -a PERMITIDAS_NENHUMA=()
! _python_core_carregar_pares "$TMP/pares.ok" PERMITIDAS_NENHUMA '' \
    || fail 'parser de pares aceitou allowlist vazia'
! _python_core_carregar_pares "$TMP/pares.ok" PERMITIDAS_SIMPLES 'minusculo_' \
    || fail 'parser de pares aceitou prefixo inválido'
ln -s -- "$TMP/pares.ok" "$TMP/pares.link"
! _python_core_carregar_pares "$TMP/pares.link" PERMITIDAS_SIMPLES '' \
    || fail 'parser de pares aceitou arquivo simbólico'
GRANDE=$(printf 'x%.0s' $(seq 1 100))
while (( ${#GRANDE} <= PYTHON_CORE_LIMITE_VALOR_PARES )); do
    GRANDE+=$GRANDE
done
printf '%s\0' CHAVE "$GRANDE" > "$TMP/pares.grande"
! _python_core_carregar_pares "$TMP/pares.grande" PERMITIDAS_SIMPLES '' \
    || fail 'parser de pares aceitou valor acima do limite'

# --- 9. Ciclo de vida dos temporários ----------------------------------------

python_core_temporarios_limpar
[[ ${#PYTHON_CORE_TEMPORARIOS[@]} -eq 0 ]] || fail 'registro de temporários não zerou'
[[ -z $PYTHON_CORE_TMPDIR ]] || fail 'raiz privada não foi liberada'

# A raiz privada é observável enquanto o chamador mantém um temporário próprio:
# é assim que se prova o modo 0700 sem depender de um resíduo pós-chamada.
python_core_temporario_novo RESERVA || fail 'temporário controlado não foi criado'
RAIZ_SUCESSO=$PYTHON_CORE_TMPDIR
[[ -d $RAIZ_SUCESSO ]] || fail 'raiz privada não foi criada'
[[ $(stat -c '%a' -- "$RAIZ_SUCESSO") == 700 ]] || fail 'raiz privada não está em 0700'
python_core_executar version > /dev/null || fail 'chamada de controle falhou'
[[ $(find "$RAIZ_SUCESSO" -mindepth 1 | wc -l) -eq 1 ]] \
    || fail 'a chamada bem-sucedida deixou temporários além da reserva do chamador'
python_core_temporario_remover "$RESERVA"
# I3: sem temporário do chamador, a raiz privada é recolhida imediatamente. Um
# consumidor com trap próprio (as etapas transacionais têm) não pode depender de
# lembrar da limpeza para deixar o TMPDIR intacto.
[[ ! -d $RAIZ_SUCESSO ]] || fail 'raiz privada sobreviveu à remoção do último temporário'
[[ -z $PYTHON_CORE_TMPDIR ]] || fail 'raiz privada recolhida continuou publicada'

python_core_executar version > /dev/null || fail 'segunda chamada de controle falhou'
[[ -z $PYTHON_CORE_TMPDIR || ! -d $PYTHON_CORE_TMPDIR ]] \
    || fail 'raiz privada sobreviveu a uma chamada sem temporário do chamador'

rc=0
python_core_executar_arquivo payload-probe MALFORMADO > /dev/null 2>&1 || rc=$?
[[ $rc -ne 0 ]] || fail 'chamada de erro não falhou'
[[ -z $PYTHON_CORE_TMPDIR || $(find "$PYTHON_CORE_TMPDIR" -mindepth 1 | wc -l) -eq 0 ]] \
    || fail 'temporários sobraram após erro'
python_core_temporarios_limpar
[[ ! -d $RAIZ_SUCESSO ]] || fail 'raiz privada sobreviveu à limpeza'

# Sinal durante a janela do temporário: o trap documentado precisa limpar. O
# harness sinaliza a si mesmo em primeiro plano, para que a disposição herdada
# de um job em background não interfira no teste de SIGINT.
cat > "$TMP/sinal.sh" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
source "$1/lib/python-core.sh"
trap 'python_core_temporarios_limpar' EXIT
trap 'python_core_temporarios_limpar; exit 130' INT
trap 'python_core_temporarios_limpar; exit 143' TERM
python_core_temporario_novo ALVO
printf '%s\n%s\n' "$ALVO" "$PYTHON_CORE_TMPDIR" > "$2"
[[ -f $ALVO ]] || exit 98
kill -"$3" $$
# Só chega aqui se o sinal tiver sido ignorado; o código 99 reprova o teste.
sleep 5
exit 99
HARNESS

for sinal in TERM INT; do
    marcador="$TMP/sinal.$sinal"
    rc=0
    bash "$TMP/sinal.sh" "$ROOT" "$marcador" "$sinal" || rc=$?
    case $sinal in
        TERM) [[ $rc -eq 143 ]] || fail "SIGTERM devia sair 143, saiu $rc" ;;
        INT) [[ $rc -eq 130 ]] || fail "SIGINT devia sair 130, saiu $rc" ;;
    esac
    arquivo_filho=$(sed -n 1p "$marcador")
    raiz_filho=$(sed -n 2p "$marcador")
    [[ -n $arquivo_filho && -n $raiz_filho ]] || fail "harness de sinal $sinal não registrou caminhos"
    [[ ! -e $arquivo_filho ]] || fail "temporário sobreviveu a SIG$sinal"
    [[ ! -d $raiz_filho ]] || fail "raiz privada sobreviveu a SIG$sinal"
done

# --- 10. Bootstrap ausente ou incompleto -------------------------------------

FALSA_RAIZ="$TMP/falsa-raiz"
mkdir -p -- "$FALSA_RAIZ/lib"
cp -- "$ROOT/lib/python-core.sh" "$FALSA_RAIZ/lib/python-core.sh"
rc=0
bash -c '
    set -euo pipefail
    source "$1/lib/python-core.sh"
    python_core_executar version
' _ "$FALSA_RAIZ" > "$TMP/falsa.out" 2> "$TMP/falsa.err" || rc=$?
[[ $rc -eq 69 ]] || fail "core ausente devia dar 69, deu $rc"
[[ ! -s $TMP/falsa.out ]] || fail 'core ausente escreveu em stdout'
grep -q 'Entrypoint do core ausente' "$TMP/falsa.err" \
    || fail 'diagnóstico de core ausente não é acionável'

SEM_PERMISSAO="$TMP/sem-permissao"
mkdir -p -- "$SEM_PERMISSAO"
cp -a -- "$ROOT/lib" "$SEM_PERMISSAO/lib"
cp -a -- "$ROOT/libexec" "$SEM_PERMISSAO/libexec"
chmod 0000 -- "$SEM_PERMISSAO/libexec/passthrough_core_cli.py"
rc=0
bash -c '
    set -euo pipefail
    source "$1/lib/python-core.sh"
    python_core_executar version
' _ "$SEM_PERMISSAO" > "$TMP/permissao.out" 2> "$TMP/permissao.err" || rc=$?
chmod 0600 -- "$SEM_PERMISSAO/libexec/passthrough_core_cli.py"
[[ $rc -eq 69 ]] || fail "core sem permissão devia dar 69, deu $rc"
[[ ! -s $TMP/permissao.out ]] || fail 'core sem permissão escreveu em stdout'
grep -q 'sem permissão de leitura' "$TMP/permissao.err" \
    || fail 'diagnóstico de permissão não é acionável'

rc=0
(
    PATH=''
    python_core_executar version
) > "$TMP/sempython.out" 2> "$TMP/sempython.err" || rc=$?
[[ $rc -eq 69 ]] || fail "python3 ausente devia dar 69, deu $rc"
grep -q 'Python 3.10' "$TMP/sempython.err" \
    || fail 'diagnóstico de python3 ausente não indica a versão mínima'

# --- 11. Mapeamento para status público --------------------------------------

for codigo in 0 64 65 66 69 70 73 75 1 42 abc ''; do
    mutacao=$(python_core_status_publico_mutacao "$codigo")
    verificacao=$(python_core_status_publico_verificacao "$codigo")
    case $mutacao in 0|1|2|3) ;; *) fail "status público inválido em mutação: $mutacao" ;; esac
    case $verificacao in 0|1|2|3) ;; *) fail "status público inválido em verificação: $verificacao" ;; esac
    if [[ $codigo == 0 ]]; then
        [[ $mutacao == 0 && $verificacao == 0 ]] || fail 'sucesso não mapeou para 0'
    else
        [[ $mutacao != 0 ]] || fail "código $codigo virou sucesso em mutação"
        [[ $verificacao != 0 ]] || fail "código $codigo virou sucesso em verificação"
    fi
done
[[ $(python_core_status_publico_verificacao 69) == 2 ]] \
    || fail 'capability ausente devia ser indeterminado em verificação'
[[ $(python_core_status_publico_mutacao 69) == 3 ]] \
    || fail 'capability ausente devia ser erro em mutação'

# --- 12. Busca por comandos externos no core ---------------------------------
# Provisória até o gate AST de I10 (tests/check-python-boundary.py).

# A busca é por AST, não por texto: comentário e docstring podem citar libvirt,
# qemu-img ou xmlstarlet ao explicar a fronteira, e citar não é usar. O que a
# checagem recusa é import, chamada ou atributo que dê acesso a processo, rede,
# código dinâmico ou à biblioteca do libvirt.
LC_ALL=C python3 -I -S -B - "$ROOT/libexec" > "$TMP/boundary.out" 2>&1 <<'PY' \
    || { cat -- "$TMP/boundary.out" >&2; fail 'o core Python referenciou comando externo, rede, libvirt ou código dinâmico'; }
import ast
import sys
from pathlib import Path

MODULOS = {
    "subprocess", "socket", "urllib", "http", "ctypes", "multiprocessing",
    "pty", "shutil", "signal", "threading", "asyncio", "libvirt", "site",
}
ATRIBUTOS_OS = {
    "system", "popen", "execv", "execve", "execvp", "execl", "execle",
    "execlp", "spawnv", "spawnve", "spawnl", "spawnlp", "fork", "forkpty",
    "posix_spawn", "posix_spawnp", "setuid", "seteuid", "setgid", "setegid",
}
NOMES_DINAMICOS = {"eval", "exec", "compile", "__import__"}

falhas = []
raiz = Path(sys.argv[1])
for arquivo in sorted(raiz.rglob("*.py")):
    arvore = ast.parse(arquivo.read_text(encoding="utf-8"), filename=str(arquivo))
    for no in ast.walk(arvore):
        if isinstance(no, ast.Import):
            for alias in no.names:
                if alias.name.split(".")[0] in MODULOS:
                    falhas.append(f"{arquivo}:{no.lineno}: import {alias.name}")
        elif isinstance(no, ast.ImportFrom):
            base = (no.module or "").split(".")[0]
            if base in MODULOS:
                falhas.append(f"{arquivo}:{no.lineno}: from {no.module}")
        elif isinstance(no, ast.Attribute):
            valor = no.value
            if isinstance(valor, ast.Name) and valor.id == "os" and no.attr in ATRIBUTOS_OS:
                falhas.append(f"{arquivo}:{no.lineno}: os.{no.attr}")
            if isinstance(valor, ast.Name) and valor.id == "importlib":
                falhas.append(f"{arquivo}:{no.lineno}: importlib.{no.attr}")
        elif isinstance(no, ast.Name) and no.id in NOMES_DINAMICOS:
            falhas.append(f"{arquivo}:{no.lineno}: {no.id}")
for linha in falhas:
    print(linha)
raise SystemExit(1 if falhas else 0)
PY
# Ponte única: somente lib/python-core.sh conhece o entrypoint e o libexec.
# Heredocs Python legados das etapas continuam existindo e são migrados em I3;
# o que I2 proíbe é qualquer segunda rota até este core.
if grep -nE 'passthrough_core|libexec' \
    "$ROOT/menu.sh" "$ROOT/etapas/"*.sh "$ROOT/util/"*.sh "$ROOT/lib/common.sh" \
    "$ROOT/lib/platform.sh" "$ROOT/lib/shell/"*.sh; then
    fail 'referência ao core fora da ponte lib/python-core.sh'
fi
if [[ ! -d $ROOT/libexec/passthrough_core ]] \
    || [[ -e $ROOT/libexec/passthrough_core/__main__.py ]]; then
    fail 'árvore do core inválida ou com segundo entrypoint'
fi

# --- 13. Checkout intacto ----------------------------------------------------

exigir_sem_bytecode
snapshot_checkout "$TMP/checkout.depois"
diff -u "$TMP/checkout.antes" "$TMP/checkout.depois" \
    || fail 'o checkout mudou durante o teste (conteúdo, modo ou mtime)'

printf 'OK: core Python isolado, protocolo v1, transporte fora de argv, ponte única e %s casos unittest\n' \
    "$TOTAL_UNITTEST"
