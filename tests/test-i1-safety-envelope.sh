#!/usr/bin/env bash
# Prova I1: todas as rotas mutantes nominais recusam perfis não autorizados
# antes de sudo/filho/efeito, por execução direta e pelo menu.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
MANIFEST="$ROOT/tests/i1/mutators.tsv"
# shellcheck source=tests/lib/i1-guard-harness.sh
source "$ROOT/tests/lib/i1-guard-harness.sh"

CHECKS=0
fail() {
    printf 'FALHA I1 safety envelope: %s\n' "$*" >&2
    if [[ -n ${I1_ERROR:-} && -s ${I1_ERROR:-/dev/null} ]]; then
        printf '%s\n' '--- stderr ---' >&2
        /usr/bin/sed 's/^/  /' "$I1_ERROR" >&2
    fi
    if [[ -n ${I1_EFFECT_LOG:-} && -s ${I1_EFFECT_LOG:-/dev/null} ]]; then
        printf '%s\n' '--- efeitos ---' >&2
        /usr/bin/sed 's/^/  /' "$I1_EFFECT_LOG" >&2
    fi
    exit 1
}
pass() { CHECKS=$((CHECKS + 1)); }
assert_eq() {
    local expected=$1 actual=$2 description=$3
    [[ $actual == "$expected" ]] || fail "$description (esperado=$expected; obtido=$actual)"
}
assert_nonzero() {
    local actual=$1 description=$2
    [[ $actual -ne 0 ]] || fail "$description deveria retornar não zero"
}
assert_manifest_equal() {
    /usr/bin/cmp -s -- "$1" "$2" || fail "$3"
}
assert_no_effects() {
    [[ ! -s $I1_EFFECT_LOG ]] || fail "$1 alcançou sudo, filho ou efeito"
}
assert_diagnostic() {
    local profile=$1 description=$2 expression
    case $profile in
        intel) expression='CPU GenuineIntel bloqueada' ;;
        planned) expression='diagnostic-only' ;;
        unknown) expression='não possui provider reconhecido' ;;
        immutable-variant) expression='plataforma imutável|VARIANT_ID=silverblue' ;;
        immutable-ostree) expression='plataforma imutável|ostree' ;;
        capability) expression='Capability negada pelo harness I1' ;;
        *) fail "perfil sem oráculo: $profile" ;;
    esac
    /usr/bin/grep -Eiq -- "$expression" "$I1_OUTPUT" "$I1_ERROR" \
        || fail "$description não terminou pela guarda esperada ($profile)"
}

[[ -f $MANIFEST ]] || fail 'manifesto de mutadores ausente'
declare -a IDS=() KINDS=() PATHS=() CAPABILITIES=() MENUS=()
declare -a ARG1=() ARG2=() ARG3=()
declare -A SEEN_IDS=() SEEN_ROWS=() MENU_SEEN=()
while IFS=$'\t' read -r id kind path capability menu arg1 arg2 arg3 extra \
      || [[ -n ${id:-} ]]; do
    [[ -z ${id:-} || $id == \#* ]] && continue
    [[ -z ${extra:-} ]] || fail "colunas extras no manifesto: $id"
    [[ $id =~ ^[a-z0-9-]+$ ]] || fail "id inválido: $id"
    [[ $kind == mutator || $kind == validation ]] || fail "kind inválido: $id"
    [[ $path == etapas/*.sh || $path == util/*.sh ]] || fail "path inválido: $path"
    [[ $capability =~ ^[a-z]+(\.[a-z]+)+$ ]] || fail "capability inválida: $capability"
    [[ $menu == - || $menu =~ ^u?[0-9]+$ ]] || fail "seleção de menu inválida: $menu"
    [[ -z ${SEEN_IDS[$id]+x} ]] || fail "id duplicado: $id"
    row_key="$path|$capability|${arg1:-}|${arg2:-}|${arg3:-}"
    [[ -z ${SEEN_ROWS[$row_key]+x} ]] || fail "rota duplicada: $row_key"
    [[ -f $ROOT/$path ]] || fail "entrypoint ausente: $path"
    /usr/bin/grep -Fq -- "guard_mutation $capability" "$ROOT/$path" \
        || fail "$path não contém a guarda nominal $capability"
    /usr/bin/bash -c 'source "$1/lib/platform.sh"; platform_capability_known "$2"' \
        _ "$ROOT" "$capability" || fail "capability desconhecida: $capability"
    SEEN_IDS[$id]=1
    SEEN_ROWS[$row_key]=1
    IDS+=("$id"); KINDS+=("$kind"); PATHS+=("$path")
    CAPABILITIES+=("$capability"); MENUS+=("$menu")
    ARG1+=("${arg1:-}"); ARG2+=("${arg2:-}"); ARG3+=("${arg3:-}")
done < "$MANIFEST"
[[ ${#IDS[@]} -gt 0 ]] || fail 'manifesto de mutadores vazio'

# Toda chamada operacional de guard_mutation precisa estar representada ao
# menos pelo par arquivo/capability; modos adicionais são listados nominalmente.
while IFS=: read -r absolute line; do
    relative=${absolute#"$ROOT/"}
    capability=${line#*guard_mutation }
    capability=${capability%%[[:space:]]*}
    capability=${capability%%;*}
    represented=0
    for index in "${!IDS[@]}"; do
        if [[ ${PATHS[$index]} == "$relative" && ${CAPABILITIES[$index]} == "$capability" ]]; then
            represented=1
            break
        fi
    done
    (( represented == 1 )) || fail "guarda fora do manifesto: $relative ($capability)"
done < <(/usr/bin/grep -H 'guard_mutation [a-z]' "$ROOT"/etapas/*.sh "$ROOT"/util/*.sh)
pass

i1_harness_setup || fail 'não foi possível preparar a sandbox I1'
trap i1_harness_cleanup EXIT HUP INT TERM

direct_count=0
for kind in "${KINDS[@]}"; do
    [[ $kind != mutator ]] || direct_count=$((direct_count + 1))
done
validation_count=$((${#IDS[@]} - direct_count))
(( direct_count > 0 && validation_count > 0 )) \
    || fail 'manifesto precisa distinguir mutadores e validações'

profiles=(intel planned unknown immutable-variant immutable-ostree capability)
for profile in "${profiles[@]}"; do
    i1_harness_reset
    i1_harness_prepare_profile "$profile"
    baseline="$I1_HARNESS_DIR/direct-$profile.before"
    i1_harness_exact_manifest "$baseline"
    : > "$I1_EFFECT_LOG"
    for repetition in 1 2; do
        for index in "${!IDS[@]}"; do
            [[ ${KINDS[$index]} == mutator ]] || continue
            args=()
            [[ -z ${ARG1[$index]} ]] || args+=("${ARG1[$index]}")
            [[ -z ${ARG2[$index]} ]] || args+=("${ARG2[$index]}")
            [[ -z ${ARG3[$index]} ]] || args+=("${ARG3[$index]}")
            i1_harness_run_direct "${PATHS[$index]}" '' "${args[@]}"
            assert_nonzero "$I1_RC" "${IDS[$index]} direto ($profile, repetição $repetition)"
            assert_diagnostic "$profile" "${IDS[$index]} direto"
            after="$I1_HARNESS_DIR/direct-$profile-${IDS[$index]}-$repetition.after"
            i1_harness_exact_manifest "$after"
            assert_manifest_equal "$baseline" "$after" \
                "${IDS[$index]} alterou conteúdo/metadados/mtime na recusa $profile"
        done
    done
    assert_no_effects "matriz direta $profile"
    pass
done

# Uma execução de menu por perfil seleciona, duas vezes, toda rota realmente
# endereçável pelo menu. O bash de status é simulado com sentinel válido; uma
# chamada de filho sem --verificar seria registrada como efeito.
menu_input=''
for index in "${!IDS[@]}"; do
    selection=${MENUS[$index]}
    [[ $selection != - ]] || continue
    [[ -z ${MENU_SEEN[$selection]+x} ]] || continue
    MENU_SEEN[$selection]=1
    menu_input+="$selection"$'\n\n'
done
menu_input+='q'$'\n'
menu_count=${#MENU_SEEN[@]}
(( menu_count > 0 )) || fail 'manifesto não contém rotas de menu'

for profile in "${profiles[@]}"; do
    i1_harness_reset
    i1_harness_prepare_profile "$profile"
    baseline="$I1_HARNESS_DIR/menu-$profile.before"
    i1_harness_exact_manifest "$baseline"
    : > "$I1_EFFECT_LOG"; : > "$I1_STATUS_LOG"
    for repetition in 1 2; do
        i1_harness_run_menu "$menu_input"
        assert_eq 0 "$I1_RC" "menu $profile (repetição $repetition)"
        blocks=$(/usr/bin/cat "$I1_OUTPUT" "$I1_ERROR" \
            | /usr/bin/grep -Eic 'Mutação .* bloqueada' || true)
        (( blocks >= menu_count )) \
            || fail "menu $profile não recusou todas as $menu_count seleções (recusas=$blocks)"
        after="$I1_HARNESS_DIR/menu-$profile-$repetition.after"
        i1_harness_exact_manifest "$after"
        assert_manifest_equal "$baseline" "$after" \
            "menu alterou conteúdo/metadados/mtime na recusa $profile"
    done
    [[ -s $I1_STATUS_LOG ]] || fail "menu $profile não exercitou os verificadores simulados"
    assert_no_effects "matriz de menu $profile"
    pass
done

printf 'OK: envelope I1 recusou %d mutadores diretos e %d seleções de menu em %d perfis, duas vezes (%d grupos); %d rota de validação está na suíte dedicada\n' \
    "$direct_count" "$menu_count" "${#profiles[@]}" "$CHECKS" "$validation_count"
