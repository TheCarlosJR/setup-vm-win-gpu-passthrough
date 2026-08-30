#!/usr/bin/env bash
# Gate canônico cumulativo: a CI e a execução local chamam exatamente este
# runner. O caminho do arquivo é mantido por compatibilidade com a CI
# versionada e com o plano; cada fase nova acrescenta seu manifesto e seus
# passos sem remover nenhum dos anteriores.
set -euo pipefail

GATE_FASE=${GATE_FASE:-I9}
secao() {
    printf '%s\n' "== Gate $GATE_FASE: $1 =="
}

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) \
    || { printf 'ERRO: checkout Git não encontrado.\n' >&2; exit 2; }
ROOT=$(realpath -- "$ROOT")
[[ $(pwd -P) == "$ROOT" ]] \
    || { printf 'ERRO: execute na raiz física do checkout: %s\n' "$ROOT" >&2; exit 2; }

GATE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/gate-i1.XXXXXXXX") \
    || { printf 'ERRO: não foi possível criar diretório temporário do gate.\n' >&2; exit 1; }
cleanup_gate() {
    rm -rf -- "$GATE_TMP"
}
trap cleanup_gate EXIT HUP INT TERM

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

export LC_ALL=C
secao 'estado inicial'
git status --short

secao 'manifesto nominal'
bash tests/check-phase-manifest.sh \
    "$GATE_FASE" \
    tests/manifests/i0-files.txt \
    tests/manifests/i1-files.txt \
    tests/manifests/i2-files.txt \
    tests/manifests/i3-files.txt \
    tests/manifests/i4-files.txt \
    tests/manifests/i5-files.txt \
    tests/manifests/i6-docs-files.txt \
    tests/manifests/i6-files.txt \
    tests/manifests/i7-files.txt \
    tests/manifests/i8-files.txt \
    tests/manifests/i9-files.txt

secao 'testes dirigidos'
bash tests/test-i1-safety-envelope.sh
bash tests/test-atualizar-host-validation.sh

secao 'campanha I0 integral sem skips'
env \
    -u I0_MUTATOR_SKIP_30 \
    -u I0_MUTATOR_SKIP_50 \
    -u I0_MUTATOR_SKIP_60 \
    -u I0_MUTATOR_SKIP_61 \
    -u I0_MUTATOR_SKIP_70 \
    LC_ALL=C I0_MUTATOR_MATRIX=full \
    bash tests/test-i0-mutators.sh

secao 'suíte histórica e regressões'
if [[ -d tests/python && ! -f tests/test-python-core.sh ]]; then
    printf '%s\n' 'ERRO: tests/python existe sem tests/test-python-core.sh' >&2
    exit 1
fi
for test_file in tests/test-*.sh; do
    case $test_file in
        tests/test-i0-mutators.sh|tests/test-i1-safety-envelope.sh|tests/test-atualizar-host-validation.sh)
            continue
            ;;
    esac
    printf 'RUN %s\n' "$test_file"
    bash "$test_file"
done

secao 'sintaxe Bash'
shell_list="$GATE_TMP/shell-files.z"
capture_git_nul "$shell_list" 'enumerar arquivos shell rastreados e novos' \
    ls-files -co --exclude-standard -z -- '*.sh'
mapfile -d '' -t shell_files < "$shell_list"
(( ${#shell_files[@]} > 0 )) \
    || { printf 'ERRO: nenhum arquivo shell encontrado.\n' >&2; exit 1; }
for file in "${shell_files[@]}"; do
    bash -n "$file"
done
printf 'OK: bash -n em %d arquivos\n' "${#shell_files[@]}"

secao 'sintaxe Python sem contaminar o checkout'
python_list="$GATE_TMP/python-files.z"
capture_git_nul "$python_list" 'enumerar arquivos Python rastreados e novos' \
    ls-files -co --exclude-standard -z -- '*.py'
mapfile -d '' -t python_files < "$python_list"
pycache="$GATE_TMP/pycache"
mkdir -- "$pycache"
# compileall cobre as árvores do core e dos testes Python; py_compile cobre
# qualquer .py restante (harnesses em tests/lib, por exemplo). Ambos usam
# -I -S e pycache_prefix externo: bytecode nunca entra no checkout. Com -I o
# interpretador ignora PYTHONPYCACHEPREFIX, então a opção -X é obrigatória.
compile_targets=()
[[ -d libexec ]] && compile_targets+=(libexec)
[[ -d tests/python ]] && compile_targets+=(tests/python)
if (( ${#compile_targets[@]} > 0 )); then
    python3 -I -S -X "pycache_prefix=$pycache" \
        -m compileall -q "${compile_targets[@]}"
fi
if (( ${#python_files[@]} > 0 )); then
    python3 -I -S -X "pycache_prefix=$pycache" \
        -m py_compile "${python_files[@]}"
fi
bytecode_residual=$(
    find . -path ./.git -prune -o \
        \( -name '__pycache__' -o -name '*.pyc' -o -name '*.pyo' \) \
        -print -quit
)
[[ -z $bytecode_residual ]] || {
    printf 'ERRO: bytecode residual no checkout: %s\n' "$bytecode_residual" >&2
    exit 1
}
printf 'OK: compileall em %d árvores e py_compile em %d arquivos, sem bytecode residual\n' \
    "${#compile_targets[@]}" "${#python_files[@]}"

if [[ -f tests/check-python-boundary.py ]]; then
    secao 'fronteira Python/Bash'
    python3 -I -S -B tests/check-python-boundary.py --root "$ROOT"
fi

if [[ -f tests/check-waivers-matrix.py ]]; then
    secao 'matriz de política de dispensas'
    python3 -I -S -B tests/check-waivers-matrix.py --root "$ROOT"
fi

secao 'ShellCheck'
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck --version
    # I1 bloqueia erros do analisador em toda a suíte. Warnings/infos
    # históricos permanecem visíveis em auditorias dedicadas de fases futuras.
    LC_ALL=C.UTF-8 shellcheck --severity=error -x -P SCRIPTDIR "${shell_files[@]}"
elif [[ ${CI:-} == true || ${I1_REQUIRE_SHELLCHECK:-0} == 1 ]]; then
    printf 'ERRO: ShellCheck é obrigatório na CI, mas não está no PATH.\n' >&2
    exit 1
else
    printf 'AVISO: ShellCheck ausente localmente; a CI versionada o provisiona e o exige.\n' >&2
fi

secao 'whitespace working tree e index'
git diff --check --
if git rev-parse --verify HEAD >/dev/null 2>&1; then
    git diff --cached --check HEAD --
else
    git diff --cached --check --
fi

secao 'whitespace de arquivos untracked'
untracked_list="$GATE_TMP/untracked-files.z"
capture_git_nul "$untracked_list" 'enumerar arquivos untracked para whitespace' \
    ls-files --others --exclude-standard -z
whitespace_tmp="$GATE_TMP/whitespace"
mkdir -- "$whitespace_tmp"
check_n=0
while IFS= read -r -d '' file; do
    check_n=$((check_n + 1))
    check_log="$whitespace_tmp/$check_n.log"
    check_rc=0
    git diff --no-index --check -- /dev/null "$file" > "$check_log" 2>&1 \
        || check_rc=$?
    if (( check_rc > 1 )) || [[ -s $check_log ]]; then
        cat -- "$check_log" >&2
        printf 'ERRO: whitespace inválido em arquivo novo: %s\n' "$file" >&2
        exit 1
    fi
done < "$untracked_list"
printf 'OK: whitespace em %d arquivos untracked\n' "$check_n"

secao 'estado final'
git status --short
printf 'OK: Gate %s concluído sem mascarar status\n' "$GATE_FASE"
