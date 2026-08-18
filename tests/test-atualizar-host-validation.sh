#!/usr/bin/env bash
# Matriz fail-closed de util/atualizar-host.sh --validar.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=tests/lib/i1-guard-harness.sh
source "$ROOT/tests/lib/i1-guard-harness.sh"

CHECKS=0
fail() {
    printf 'FALHA atualizar-host --validar: %s\n' "$*" >&2
    if [[ -n ${I1_OUTPUT:-} && -s ${I1_OUTPUT:-/dev/null} ]]; then
        printf '%s\n' '--- stdout ---' >&2
        /usr/bin/sed 's/^/  /' "$I1_OUTPUT" >&2
    fi
    if [[ -n ${I1_ERROR:-} && -s ${I1_ERROR:-/dev/null} ]]; then
        printf '%s\n' '--- stderr ---' >&2
        /usr/bin/sed 's/^/  /' "$I1_ERROR" >&2
    fi
    exit 1
}
pass() { CHECKS=$((CHECKS + 1)); }
assert_eq() {
    local expected=$1 actual=$2 description=$3
    [[ $actual == "$expected" ]] || fail "$description (esperado=$expected; obtido=$actual)"
}
assert_text() {
    local expression=$1 description=$2
    /usr/bin/grep -Eiq -- "$expression" "$I1_OUTPUT" "$I1_ERROR" || fail "$description"
}
assert_no_text() {
    local expression=$1 description=$2
    ! /usr/bin/grep -Eiq -- "$expression" "$I1_OUTPUT" "$I1_ERROR" || fail "$description"
}
assert_no_probes() {
    local description=$1
    [[ ! -s $I1_PROBE_LOG ]] || fail "$description executou sonda antes da guarda"
}

prepare_case() {
    i1_harness_reset
    i1_harness_prepare_profile supported
    i1_harness_prepare_validation
}

run_case() {
    local name=$1 expected=$2 input=${3-} expected_text=${4-}
    local before="$I1_HARNESS_DIR/$name.before" after="$I1_HARNESS_DIR/$name.after"
    : > "$I1_EFFECT_LOG"; : > "$I1_ACTION_LOG"; : > "$I1_PROBE_LOG"
    i1_harness_exact_manifest "$before"
    i1_harness_run_direct util/atualizar-host.sh "$input" --validar
    assert_eq "$expected" "$I1_RC" "$name"
    [[ -z $expected_text ]] || assert_text "$expected_text" "$name sem diagnóstico esperado"
    i1_harness_exact_manifest "$after"
    /usr/bin/cmp -s -- "$before" "$after" \
        || fail "$name alterou conteúdo, owner, grupo, modo ou mtime"
    [[ ! -s $I1_EFFECT_LOG ]] || fail "$name alcançou efeito não permitido"
    assert_no_text 'apt (update|full-upgrade|autoremove)|snapshot interno pré-atualização|REINICIALIZAÇÃO NECESSÁRIA' \
        "$name executou fluxo de atualização"
    pass
}

i1_harness_setup || fail 'não foi possível preparar a sandbox de validação'
trap i1_harness_cleanup EXIT HUP INT TERM

prepare_case
printf '%s\n' 'LINHA SEM ATRIBUICAO' > "$I1_PROJECT/passthrough.conf"
run_case config-malformada 3 '' 'Linha 1 inválida'

prepare_case
/usr/bin/rm -f -- "$I1_PROJECT/passthrough.conf"
/usr/bin/ln -s -- passthrough.conf.example "$I1_PROJECT/passthrough.conf"
run_case config-simbolica 3 '' 'arquivo regular, não um link'

prepare_case
/usr/bin/chmod 000 "$I1_PROJECT/passthrough.conf"
# I4: a leitura do conf passou ao core, que distingue permissão de link. O
# diagnóstico anterior vinha do shell e do próprio Bash; a alternativa nova é
# aceita junto das antigas para não reduzir a cobertura.
run_case config-ilegivel 3 '' 'configuração não pôde ser carregada|Permission denied|Permissão negada|permissão negada'

prepare_case
/usr/bin/rm -f -- "$I1_ROOT/bin/nvidia-smi"
run_case nvidia-ausente 2 '' 'nvidia-smi não está disponível'

prepare_case
I1_NVIDIA_FIRST_RC=9
export I1_NVIDIA_FIRST_RC
run_case nvidia-falha 3 '' 'nvidia-smi falhou com código 9'

prepare_case
printf '%s\n' 'saída vazia de semântica conhecida' > "$I1_NVIDIA_FIRST_FILE"
run_case nvidia-saida-inesperada 2 '' 'saída não contém identificação e versão parseáveis'

prepare_case
printf '%s\n' 'quiet splash' > "$I1_ROOT/proc/cmdline"
run_case cmdline-ausente 3 '' 'aparece 0 vez'

prepare_case
printf '%s\n' 'amd_iommu=on amd_iommu=on iommu=pt' > "$I1_ROOT/proc/cmdline"
run_case cmdline-duplicada 3 '' 'aparece 2 vez'

prepare_case
printf '%s\n' 'amd_iommu=off iommu=pt' > "$I1_ROOT/proc/cmdline"
run_case cmdline-valor-incorreto 3 '' 'esperado.*amd_iommu=on'

prepare_case
/usr/bin/rm -f -- "$I1_ROOT/proc/cmdline"
run_case cmdline-ilegivel 3 '' 'Não foi possível ler'

prepare_case
I1_SUDO_NONINTERACTIVE_RC=1
I1_SUDO_AUTH_RC=5
export I1_SUDO_NONINTERACTIVE_RC I1_SUDO_AUTH_RC
run_case sudo-falha 3 '' 'autorização sudo.*código 5'

prepare_case
I1_DMESG_RC=13
export I1_DMESG_RC
run_case dmesg-falha 3 '' 'Falha operacional ao ler dmesg.*13'

prepare_case
: > "$I1_DMESG_FILE"
run_case dmesg-sem-evidencia 2 '' 'não contém evidência AMD-Vi'

prepare_case
printf '%s\n' 'AMD-Vi: IOMMU disabled by firmware' > "$I1_DMESG_FILE"
run_case dmesg-negativo 3 '' 'evidência negativa de AMD-Vi'

prepare_case
printf '%s\n' 'AMD-Vi: IVRS table revision 1' > "$I1_DMESG_FILE"
run_case dmesg-inesperado 2 '' 'não contém uma pós-condição positiva reconhecida'

prepare_case
run_case teste-manual-recusado 2 $'n\n' 'retorno da GPU.*não comprovado'
[[ ! -s $I1_ACTION_LOG ]] || fail 'recusa manual iniciou a VM'

prepare_case
i1_harness_set_conf VM_NAME ''
run_case vm-nao-configurada 2 '' 'VM_NAME não está configurado'

for profile in intel planned unknown immutable-variant immutable-ostree capability; do
    prepare_case
    i1_harness_prepare_profile "$profile"
    run_case "guarda-$profile" 3 $'s\n' 'Mutação .* bloqueada|bloqueada antes de sudo'
    assert_no_probes "guarda $profile"
    [[ ! -s $I1_ACTION_LOG ]] || fail "guarda $profile alcançou virsh start"
done

prepare_case
I1_VIRSH_START_RC=7
export I1_VIRSH_START_RC
run_case start-falha 3 $'s\n' 'Falha ao iniciar.*código 7'
/usr/bin/grep -Eq 'virsh\|start' "$I1_ACTION_LOG" \
    || fail 'falha de start não exercitou o shim'

prepare_case
run_case retorno-nao-confirmado 2 $'s\nn\n' 'retorno da GPU não foi confirmado'

prepare_case
I1_VIRSH_DOMSTATE=running
export I1_VIRSH_DOMSTATE
run_case vm-ainda-ligada 2 $'s\ns\n' 'não comprovou a VM.*como desligada'

prepare_case
I1_VIRSH_DOMSTATE_RC=9
export I1_VIRSH_DOMSTATE_RC
run_case domstate-falha 3 $'s\ns\n' 'Falha operacional ao consultar.*código 9'

prepare_case
I1_NVIDIA_SECOND_RC=11
export I1_NVIDIA_SECOND_RC
run_case gpu-nao-retornou 3 $'s\ns\n' 'nvidia-smi falhou após.*código 11'

prepare_case
run_case ciclo-completo 0 $'s\ns\n' 'GPU novamente comprovada no host'
assert_eq 2 "$(<"$I1_NVIDIA_COUNT_FILE")" 'ciclo completo deve executar nvidia-smi exatamente duas vezes'
/usr/bin/grep -Eq 'virsh\|start' "$I1_ACTION_LOG" \
    || fail 'ciclo completo não iniciou a VM modelada'
/usr/bin/grep -Eq 'virsh\|domstate' "$I1_ACTION_LOG" \
    || fail 'ciclo completo não comprovou o desligamento modelado'

printf 'OK: atualizar-host --validar preservou códigos 0/2/3 e estado exato em %d cenários\n' "$CHECKS"
