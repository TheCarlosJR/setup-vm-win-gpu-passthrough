#!/usr/bin/env bash
# Recusa arquivos novos/untracked ou adicionados ao index fora dos manifests.
set -euo pipefail

# Este checker AFIRMA ordem C, então ele não pode depender da collation de quem
# o chama. Sob o gate isso não aparecia, porque tests/run-gate-i1.sh já exporta
# LC_ALL=C; rodado direto pelo operador (que a regra 19 da seção 0.1 do plano
# incentiva), a collation de pt_BR.UTF-8 ignora a pontuação no nível primário e
# ordena "libexec/..." antes de "lib/shell/...", produzindo erro FALSO num
# manifesto correto — e, na direção oposta, aceitando manifesto de fato fora de
# ordem. Comparação de bytes é o contrato; o locale do operador não é.
export LC_ALL=C

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) \
    || { printf 'ERRO: execute dentro de um checkout Git.\n' >&2; exit 2; }
ROOT=$(realpath -- "$ROOT")
[[ $(pwd -P) == "$ROOT" ]] \
    || { printf 'ERRO: execute na raiz física do checkout: %s\n' "$ROOT" >&2; exit 2; }

[[ $# -ge 2 ]] || {
    printf 'Uso: %s FASE MANIFESTO [MANIFESTO...]\n' "$0" >&2
    exit 64
}
PHASE=$1
shift
[[ $PHASE =~ ^I[0-9]+$ ]] \
    || { printf 'ERRO: fase inválida: %s\n' "$PHASE" >&2; exit 64; }

declare -A ALLOWED=() ORIGIN=()
TOTAL=0
for manifest in "$@"; do
    [[ $manifest != /* && $manifest != *'..'* && -f $manifest && ! -L $manifest ]] || {
        printf 'ERRO: manifesto inseguro, ausente ou simbólico: %s\n' "$manifest" >&2
        exit 1
    }
    previous=''
    while IFS= read -r path || [[ -n $path ]]; do
        [[ -n $path && $path != \#* ]] || continue
        [[ $path =~ ^[A-Za-z0-9._/-]+$ && $path != /* && $path != */../* \
           && $path != ../* && $path != */.. && $path != ./* ]] || {
            printf 'ERRO: caminho inválido em %s: %s\n' "$manifest" "$path" >&2
            exit 1
        }
        if [[ -n $previous && $path < $previous ]]; then
            printf 'ERRO: manifesto fora de ordem C: %s (%s antes de %s)\n' \
                "$manifest" "$path" "$previous" >&2
            exit 1
        fi
        [[ -z ${ALLOWED[$path]+x} ]] || {
            printf 'ERRO: caminho repetido nos manifests: %s (%s e %s)\n' \
                "$path" "${ORIGIN[$path]}" "$manifest" >&2
            exit 1
        }
        [[ -e $path || -L $path ]] || {
            printf 'ERRO: arquivo nominal não existe: %s (manifesto %s)\n' \
                "$path" "$manifest" >&2
            exit 1
        }
        ALLOWED[$path]=1
        ORIGIN[$path]=$manifest
        previous=$path
        TOTAL=$((TOTAL + 1))
    done < "$manifest"
done

MANIFEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/phase-manifest.XXXXXXXX") \
    || { printf 'ERRO: não foi possível criar diretório temporário do manifesto.\n' >&2; exit 1; }
cleanup_manifest() {
    rm -rf -- "$MANIFEST_TMP"
}
trap cleanup_manifest EXIT HUP INT TERM

capture_git_nul() {
    local output=$1 description=$2 rc
    shift 2
    if git "$@" > "$output"; then
        return 0
    else
        rc=$?
        printf 'ERRO: Git falhou ao %s (código %d).\n' "$description" "$rc" >&2
        return "$rc"
    fi
}

untracked_list="$MANIFEST_TMP/untracked.z"
added_list="$MANIFEST_TMP/added.z"
tracked_list="$MANIFEST_TMP/tracked-range.z"
capture_git_nul "$untracked_list" 'enumerar arquivos untracked' \
    ls-files --others --exclude-standard -z
capture_git_nul "$added_list" 'enumerar arquivos adicionados ao index' \
    diff --cached --name-only --diff-filter=A -z --
: > "$tracked_list"

manifest_base=${PHASE_MANIFEST_BASE:-}
base_commit=''
[[ ! $manifest_base =~ ^0+$ ]] || manifest_base=''
if [[ -z $manifest_base && ${CI:-} == true ]]; then
    manifest_base=$(git rev-parse --verify HEAD^ 2>/dev/null) || {
        printf 'ERRO: a CI não forneceu PHASE_MANIFEST_BASE e HEAD não possui pai verificável.\n' >&2
        exit 1
    }
fi
if [[ -n $manifest_base ]]; then
    [[ $manifest_base =~ ^[0-9a-fA-F]{40,64}$ ]] || {
        printf 'ERRO: PHASE_MANIFEST_BASE deve ser um hash Git completo.\n' >&2
        exit 64
    }
    base_commit=$(git rev-parse --verify "${manifest_base}^{commit}" 2>/dev/null) || {
        printf 'ERRO: base do manifesto não existe no checkout: %s\n' "$manifest_base" >&2
        exit 1
    }
    capture_git_nul "$tracked_list" \
        "enumerar arquivos rastreados adicionados desde $base_commit" \
        diff --name-only --diff-filter=A -z "${base_commit}...HEAD" --
fi

UNKNOWN=0
while IFS= read -r -d '' path; do
    if [[ -z ${ALLOWED[$path]+x} ]]; then
        printf 'ERRO: arquivo untracked fora do manifesto da fase %s: %s\n' \
            "$PHASE" "$path" >&2
        UNKNOWN=$((UNKNOWN + 1))
    fi
done < "$untracked_list"

while IFS= read -r -d '' path; do
    if [[ -z ${ALLOWED[$path]+x} ]]; then
        printf 'ERRO: arquivo adicionado ao index fora do manifesto da fase %s: %s\n' \
            "$PHASE" "$path" >&2
        UNKNOWN=$((UNKNOWN + 1))
    fi
done < "$added_list"

while IFS= read -r -d '' path; do
    if [[ -z ${ALLOWED[$path]+x} ]]; then
        printf 'ERRO: arquivo rastreado adicionado desde %s fora do manifesto da fase %s: %s\n' \
            "$base_commit" "$PHASE" "$path" >&2
        UNKNOWN=$((UNKNOWN + 1))
    fi
done < "$tracked_list"

(( UNKNOWN == 0 )) || exit 1
printf 'OK: manifesto %s autorizou %d arquivos nominais; nenhum arquivo novo ficou fora da lista\n' \
    "$PHASE" "$TOTAL"
