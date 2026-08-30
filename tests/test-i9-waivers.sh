#!/usr/bin/env bash
# Gate dirigido I9.10 / REQ-WAIVERS: matriz de política e leitor de dispensas.
#
# O que este teste protege:
#
#   * a matriz é POLÍTICA, não sugestão: linha malformada, vocabulário não
#     declarado, etapa inexistente, flag fora do schema, duplicidade e ordem C
#     quebrada recusam o arquivo INTEIRO, em vez de serem puladas;
#   * valor negativo mantém o bloqueio: só 'sim' ativa a dispensa, e tratar
#     "diferente de sim" como ativa inverteria o requisito;
#   * dispensa é estado de ORQUESTRAÇÃO: nada aqui muda código de saída de
#     verificador nem entra no sentinel V1.
#
# Hermético: nenhuma etapa é executada, nenhum host é tocado. As fixtures de
# matriz hostil vivem sob um TMP próprio.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# I9.10: enquanto a fachada não carrega o módulo, o teste o carrega direto.
# shellcheck source=lib/shell/waivers.sh
source "$ROOT/lib/shell/waivers.sh"

fail() { printf 'FALHA I9.10: %s\n' "$*" >&2; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/i9-waivers.XXXXXXXX")
trap 'rm -rf -- "$TMP"' EXIT HUP INT TERM
CASOS=0

BASH_BIN="${BASH:-/bin/bash}"

# Roda uma consulta ao leitor em processo próprio: o módulo memoriza a matriz
# em WAIVERS_MATRIZ_CARREGADA, então reusar o shell mascararia erro de carga.
consultar() {
    local matriz="$1" etapa="$2"
    shift 2
    local rc=0 saida=""
    saida="$( { env "$@" "$BASH_BIN" -c "
        source \"$ROOT/lib/common.sh\"
        WAIVERS_MATRIZ_ARQUIVO='$matriz'
        source \"$ROOT/lib/shell/waivers.sh\"
        rc=0
        waiver_estado '$etapa' || rc=\$?
        printf 'RC=%s ATIVA=%s CHAVE=%s PREREQ=%s SIMBOLO=%s ERRO=%s\n' \
            \"\$rc\" \"\$WAIVER_ATIVA\" \"\$WAIVER_CHAVE\" \"\$WAIVER_PREREQ\" \
            \"\$WAIVER_SIMBOLO\" \"\$WAIVER_ERRO\"
    "; } 2>&1 )" || rc=$?
    [ "$rc" -eq 0 ] || fail "consulta abortou (código $rc): $saida"
    printf '%s\n' "$saida" | tail -n 1
}

MATRIZ="$ROOT/lib/policy/waivers.tsv"

# --- leitor: resolução sobre a matriz real ------------------------------------
r="$(consultar "$MATRIZ" 14-working-disk.sh WORKING_DISK_DISPENSADO=sim)"
[ "$r" = 'RC=0 ATIVA=1 CHAVE=WORKING_DISK_DISPENSADO PREREQ=workingdisk-montado SIMBOLO=disp ERRO=' ] \
    || fail "dispensa ativa não resolveu: $r"
CASOS=$((CASOS + 1))

# Valor negativo NÃO dispensa. Sem esta asserção, um `nao` explícito poderia
# virar dispensa por alguém trocar a comparação por "diferente de vazio".
r="$(consultar "$MATRIZ" 14-working-disk.sh WORKING_DISK_DISPENSADO=nao)"
[ "$r" = 'RC=1 ATIVA=0 CHAVE= PREREQ= SIMBOLO= ERRO=' ] \
    || fail "valor 'nao' não manteve o bloqueio: $r"
CASOS=$((CASOS + 1))

r="$(consultar "$MATRIZ" 14-working-disk.sh WORKING_DISK_DISPENSADO=)"
[ "$r" = 'RC=1 ATIVA=0 CHAVE= PREREQ= SIMBOLO= ERRO=' ] \
    || fail "valor vazio não manteve o bloqueio: $r"
CASOS=$((CASOS + 1))

# Valor arbitrário também não dispensa.
r="$(consultar "$MATRIZ" 14-working-disk.sh WORKING_DISK_DISPENSADO=SIM)"
[ "$r" = 'RC=1 ATIVA=0 CHAVE= PREREQ= SIMBOLO= ERRO=' ] \
    || fail "valor 'SIM' maiúsculo dispensou indevidamente: $r"
CASOS=$((CASOS + 1))

r="$(consultar "$MATRIZ" 50-hooks-gpu-hd1.sh HD1_DISPENSADO=sim)"
[ "$r" = 'RC=0 ATIVA=1 CHAVE=HD1_DISPENSADO PREREQ=hd1-anexado SIMBOLO=disp ERRO=' ] \
    || fail "dispensa de HD1 não resolveu: $r"
CASOS=$((CASOS + 1))

# A mesma flag governa três etapas; duas delas não trocam o símbolo da UI.
r="$(consultar "$MATRIZ" 70-trim-discard.sh WORKING_DISK_DISPENSADO=sim)"
[ "$r" = 'RC=0 ATIVA=1 CHAVE=WORKING_DISK_DISPENSADO PREREQ=backups-em-workingdisk SIMBOLO=nenhum ERRO=' ] \
    || fail "política da etapa 21 não resolveu: $r"
CASOS=$((CASOS + 1))

# Etapa sem linha na matriz nunca é dispensada, mesmo com a flag ativa.
r="$(consultar "$MATRIZ" 40-criar-vm.sh WORKING_DISK_DISPENSADO=sim)"
[ "$r" = 'RC=1 ATIVA=0 CHAVE= PREREQ= SIMBOLO= ERRO=' ] \
    || fail "etapa fora da matriz foi dispensada: $r"
CASOS=$((CASOS + 1))

r="$(consultar "$MATRIZ" '' WORKING_DISK_DISPENSADO=sim)"
printf '%s' "$r" | grep -q '^RC=2 ' || fail "etapa vazia não deu indeterminado: $r"
CASOS=$((CASOS + 1))

# --- leitor: matrizes hostis recusam o arquivo inteiro ------------------------
hostil() {
    local nome="$1" conteudo="$2"
    local arquivo="$TMP/$nome.tsv"
    printf '%s' "$conteudo" > "$arquivo"
    local r
    r="$(consultar "$arquivo" 14-working-disk.sh WORKING_DISK_DISPENSADO=sim)"
    printf '%s' "$r" | grep -q '^RC=2 ' \
        || fail "matriz hostil '$nome' NÃO foi recusada: $r"
    printf '%s' "$r" | grep -q 'ATIVA=0' \
        || fail "matriz hostil '$nome' publicou dispensa ativa: $r"
    CASOS=$((CASOS + 1))
}

LINHA_BOA='14-working-disk.sh\tWORKING_DISK_DISPENSADO\tescolha-de-modo\tworkingdisk-montado\tdisp\tfatal\n'
hostil sem-versao "$(printf "$LINHA_BOA")"
hostil versao-errada "$(printf '# schema_version=9\n')$(printf "$LINHA_BOA")"
hostil campos-a-menos "$(printf '# schema_version=1\n14-working-disk.sh\tWORKING_DISK_DISPENSADO\tescolha-de-modo\n')"
hostil campos-a-mais "$(printf '# schema_version=1\n14-working-disk.sh\tWORKING_DISK_DISPENSADO\tescolha-de-modo\tx\tdisp\tfatal\tsobra\n')"
hostil tipo-desconhecido "$(printf '# schema_version=1\n14-working-disk.sh\tWORKING_DISK_DISPENSADO\tdispensa-total\tx\tdisp\tfatal\n')"
hostil simbolo-desconhecido "$(printf '# schema_version=1\n14-working-disk.sh\tWORKING_DISK_DISPENSADO\tescolha-de-modo\tx\tok\tfatal\n')"
hostil conflito-desconhecido "$(printf '# schema_version=1\n14-working-disk.sh\tWORKING_DISK_DISPENSADO\tescolha-de-modo\tx\tdisp\tignorar\n')"
hostil flag-fora-do-padrao "$(printf '# schema_version=1\n14-working-disk.sh\tWORKING_DISK\tescolha-de-modo\tx\tdisp\tfatal\n')"
hostil etapa-com-caminho "$(printf '# schema_version=1\n../etapas/14-working-disk.sh\tWORKING_DISK_DISPENSADO\tescolha-de-modo\tx\tdisp\tfatal\n')"
hostil prereq-vazio "$(printf '# schema_version=1\n14-working-disk.sh\tWORKING_DISK_DISPENSADO\tescolha-de-modo\t\tdisp\tfatal\n')"

# Matriz ausente é indeterminado, nunca "não há dispensa".
r="$(consultar "$TMP/nao-existe.tsv" 14-working-disk.sh WORKING_DISK_DISPENSADO=sim)"
printf '%s' "$r" | grep -q '^RC=2 ' || fail "matriz ausente não deu indeterminado: $r"
CASOS=$((CASOS + 1))

# A matriz é DADO: um campo que parece comando não pode ser executado.
INJECAO="$TMP/injecao.tsv"
{
    printf '# schema_version=1\n'
    printf '14-working-disk.sh\tWORKING_DISK_DISPENSADO\tescolha-de-modo\tx\tdisp\tfatal\n'
} > "$INJECAO"
CANARIO="$TMP/canario"
printf '14-working-disk.sh\tWORKING_DISK_DISPENSADO\tescolha-de-modo\t$(touch %s)\tdisp\tfatal\n' \
    "$CANARIO" >> "$INJECAO"
r="$(consultar "$INJECAO" 14-working-disk.sh WORKING_DISK_DISPENSADO=sim)"
[ ! -e "$CANARIO" ] || fail 'campo da matriz foi executado como comando'
CASOS=$((CASOS + 1))

# --- gate de schema: aceita a matriz real ------------------------------------
python3 -I -S -B "$ROOT/tests/check-waivers-matrix.py" --root "$ROOT" >/dev/null \
    || fail 'o checker recusou a matriz versionada do projeto'
CASOS=$((CASOS + 1))

# --- gate de schema: recusa mutações injetadas -------------------------------
# Cada mutação abaixo é uma regressão plausível. O checker precisa pegar todas;
# se alguma passar, o gate está aprovando política incoerente.
FAKE="$TMP/raiz"
mkdir -p "$FAKE/lib/policy" "$FAKE/libexec/passthrough_core" "$FAKE/etapas"
cp -- "$ROOT/libexec/passthrough_core/config.py" "$FAKE/libexec/passthrough_core/config.py"
for e in "$ROOT"/etapas/*.sh; do : > "$FAKE/etapas/$(basename -- "$e")"; done

checker_recusa() {
    local nome="$1" conteudo="$2" rc=0
    printf '%s' "$conteudo" > "$FAKE/lib/policy/waivers.tsv"
    python3 -I -S -B "$ROOT/tests/check-waivers-matrix.py" --root "$FAKE" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "o checker ACEITOU a mutação '$nome'"
    CASOS=$((CASOS + 1))
}
checker_aceita() {
    local nome="$1" conteudo="$2"
    printf '%s' "$conteudo" > "$FAKE/lib/policy/waivers.tsv"
    python3 -I -S -B "$ROOT/tests/check-waivers-matrix.py" --root "$FAKE" >/dev/null 2>&1 \
        || fail "o checker RECUSOU a matriz válida '$nome'"
    CASOS=$((CASOS + 1))
}

VALIDA="$(cat <<'EOF'
# schema_version=1
14-working-disk.sh	WORKING_DISK_DISPENSADO	escolha-de-modo	workingdisk-montado	disp	fatal
50-hooks-gpu-hd1.sh	HD1_DISPENSADO	escolha-de-modo	hd1-anexado	disp	fatal
EOF
)"
checker_aceita minima "$VALIDA"$'\n'

# Cobertura incompleta: a flag existe no schema e sumiu da matriz.
checker_recusa cobertura-incompleta "$(printf '# schema_version=1\n14-working-disk.sh\tWORKING_DISK_DISPENSADO\tescolha-de-modo\tworkingdisk-montado\tdisp\tfatal\n')"
# Etapa que não existe na árvore.
checker_recusa etapa-inexistente "$(printf '# schema_version=1\n14-working-disk.sh\tWORKING_DISK_DISPENSADO\tescolha-de-modo\tx\tdisp\tfatal\n99-nao-existe.sh\tHD1_DISPENSADO\tescolha-de-modo\ty\tdisp\tfatal\n')"
# Flag que não está no schema do core.
checker_recusa flag-fora-do-schema "$(printf '# schema_version=1\n14-working-disk.sh\tWORKING_DISK_DISPENSADO\tescolha-de-modo\tx\tdisp\tfatal\n50-hooks-gpu-hd1.sh\tHD1_DISPENSADO\tescolha-de-modo\ty\tdisp\tfatal\n61-airlock.sh\tINVENTADO_DISPENSADO\tescolha-de-modo\tz\tdisp\tfatal\n')"
# Ordem C quebrada.
checker_recusa fora-de-ordem "$(printf '# schema_version=1\n50-hooks-gpu-hd1.sh\tHD1_DISPENSADO\tescolha-de-modo\ty\tdisp\tfatal\n14-working-disk.sh\tWORKING_DISK_DISPENSADO\tescolha-de-modo\tx\tdisp\tfatal\n')"
# Par duplicado.
checker_recusa par-duplicado "$(printf '# schema_version=1\n14-working-disk.sh\tWORKING_DISK_DISPENSADO\tescolha-de-modo\tx\tdisp\tfatal\n14-working-disk.sh\tWORKING_DISK_DISPENSADO\tescolha-de-modo\tx\tdisp\tfatal\n50-hooks-gpu-hd1.sh\tHD1_DISPENSADO\tescolha-de-modo\ty\tdisp\tfatal\n')"
# CRLF, BOM e ausência de newline final.
checker_recusa com-crlf "$(printf '# schema_version=1\r\n14-working-disk.sh\tWORKING_DISK_DISPENSADO\tescolha-de-modo\tx\tdisp\tfatal\r\n50-hooks-gpu-hd1.sh\tHD1_DISPENSADO\tescolha-de-modo\ty\tdisp\tfatal\r\n')"
checker_recusa com-bom "$(printf '\xef\xbb\xbf# schema_version=1\n14-working-disk.sh\tWORKING_DISK_DISPENSADO\tescolha-de-modo\tx\tdisp\tfatal\n50-hooks-gpu-hd1.sh\tHD1_DISPENSADO\tescolha-de-modo\ty\tdisp\tfatal\n')"
checker_recusa sem-newline-final "$(printf '# schema_version=1\n14-working-disk.sh\tWORKING_DISK_DISPENSADO\tescolha-de-modo\tx\tdisp\tfatal\n50-hooks-gpu-hd1.sh\tHD1_DISPENSADO\tescolha-de-modo\ty\tdisp\tfatal')"
# Sem schema_version e sem linha de dados.
checker_recusa sem-versao "$(printf '14-working-disk.sh\tWORKING_DISK_DISPENSADO\tescolha-de-modo\tx\tdisp\tfatal\n50-hooks-gpu-hd1.sh\tHD1_DISPENSADO\tescolha-de-modo\ty\tdisp\tfatal\n')"
checker_recusa so-comentario "$(printf '# schema_version=1\n# nada aqui\n')"
# Espaço nas bordas de um campo: TAB é o separador, espaço não é aparado.
checker_recusa campo-com-espaco "$(printf '# schema_version=1\n14-working-disk.sh\t WORKING_DISK_DISPENSADO\tescolha-de-modo\tx\tdisp\tfatal\n50-hooks-gpu-hd1.sh\tHD1_DISPENSADO\tescolha-de-modo\ty\tdisp\tfatal\n')"

printf 'OK: matriz e leitor de dispensas I9.10 aprovados em %d casos\n' "$CASOS"
