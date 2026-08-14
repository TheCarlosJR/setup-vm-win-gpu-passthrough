#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/platform-harness.sh
source "$TESTS_DIR/lib/platform-harness.sh"

falha() {
    printf 'FALHA: %s\n' "$*" >&2
    exit 1
}

arquivo_tem_linha() {
    local arquivo=$1 esperada=$2 linha
    while IFS= read -r linha || [[ -n $linha ]]; do
        [[ $linha == "$esperada" ]] && return 0
    done < "$arquivo"
    return 1
}

arquivo_tem_prefixo() {
    local arquivo=$1 prefixo=$2 linha
    while IFS= read -r linha || [[ -n $linha ]]; do
        [[ $linha == "$prefixo"* ]] && return 0
    done < "$arquivo"
    return 1
}

os_release_valor_literal() {
    local arquivo=$1 chave_pedida=$2
    local linha chave valor encontrado=0 resultado=

    case $chave_pedida in
        ID | ID_LIKE | VERSION_ID | VERSION_CODENAME) ;;
        *) return 1 ;;
    esac

    while IFS= read -r linha || [[ -n $linha ]]; do
        linha=${linha%$'\r'}
        [[ -z $linha || $linha == \#* || $linha != *=* ]] && continue
        chave=${linha%%=*}
        [[ $chave == "$chave_pedida" ]] || continue
        ((encontrado == 0)) || return 1
        valor=${linha#*=}
        if [[ $valor == \"*\" && ${#valor} -ge 2 ]]; then
            valor=${valor:1:${#valor}-2}
        elif [[ $valor == \'*\' && ${#valor} -ge 2 ]]; then
            valor=${valor:1:${#valor}-2}
        fi
        case $valor in
            *'$('* | *'`'* | *'${'* | *';'* | *'&'* | *'|'* | *'<'* | *'>'*) return 1 ;;
        esac
        resultado=$valor
        encontrado=1
    done < "$arquivo"

    if ((encontrado == 0)); then
        resultado=
    fi
    printf '%s\n' "$resultado"
}

validar_boot_evidence() {
    local arquivo=$1 expected_immutable=$2
    local linha chave valor
    declare -A vistas=()

    while IFS= read -r linha || [[ -n $linha ]]; do
        linha=${linha%$'\r'}
        [[ -z $linha || $linha == \#* ]] && continue
        [[ $linha == *=* ]] || return 1
        chave=${linha%%=*}
        valor=${linha#*=}
        [[ ! ${vistas[$chave]+presente} ]] || return 1
        vistas[$chave]=1
        case $chave in
            firmware) [[ $valor == uefi || $valor == bios || $valor == unknown ]] || return 1 ;;
            bootloader) [[ $valor == grub || $valor == systemd-boot || $valor == unknown ]] || return 1 ;;
            immutable) [[ $valor == "$expected_immutable" ]] || return 1 ;;
            deployment) [[ $valor == ostree ]] || return 1 ;;
            *) return 1 ;;
        esac
    done < "$arquivo"

    [[ ${vistas[firmware]+presente} && ${vistas[bootloader]+presente} &&
        ${vistas[immutable]+presente} ]]
}

validar_systemctl_units() {
    local arquivo=$1 linha unidade load_state active_state sub_state extra rest pipes

    while IFS= read -r linha || [[ -n $linha ]]; do
        linha=${linha%$'\r'}
        [[ -z $linha || $linha == \#* ]] && continue
        rest=$linha
        pipes=0
        while [[ $rest == *'|'* ]]; do
            rest=${rest#*|}
            pipes=$((pipes + 1))
        done
        ((pipes == 3)) || return 1
        IFS='|' read -r unidade load_state active_state sub_state extra <<< "$linha"
        [[ $unidade =~ ^[a-zA-Z0-9@_.:-]+$ ]] || return 1
        [[ $load_state == loaded || $load_state == not-found || $load_state == masked ]] || return 1
        [[ $active_state == active || $active_state == inactive || $active_state == failed ||
            $active_state == activating || $active_state == deactivating ]] || return 1
        [[ $sub_state =~ ^[a-zA-Z0-9@_.:-]+$ ]] || return 1
    done < "$arquivo"
}

validar_oraculo_fixture() {
    local caso=$1 fixture=$2
    local case_id estado expected_id expected_id_like expected_version expected_codename
    local expected_immutable present_command actual_id actual_id_like actual_version actual_codename

    case_id=$(platform_harness_expected_value "$fixture/expected.env" CASE_ID) || return 1
    estado=$(platform_harness_expected_value "$fixture/expected.env" OS_RELEASE_STATE) || return 1
    expected_id=$(platform_harness_expected_value "$fixture/expected.env" EXPECTED_ID) || return 1
    expected_id_like=$(platform_harness_expected_value "$fixture/expected.env" EXPECTED_ID_LIKE) || return 1
    expected_version=$(platform_harness_expected_value "$fixture/expected.env" EXPECTED_VERSION_ID) || return 1
    expected_codename=$(platform_harness_expected_value "$fixture/expected.env" EXPECTED_VERSION_CODENAME) || return 1
    expected_immutable=$(platform_harness_expected_value "$fixture/expected.env" EXPECTED_IMMUTABLE) || return 1
    present_command=$(platform_harness_expected_value "$fixture/expected.env" PRESENT_COMMAND) || return 1

    [[ $case_id == "$caso" ]] || return 1
    [[ $estado == present || $estado == malformed ]] || return 1
    [[ $expected_immutable == true || $expected_immutable == false ]] || return 1
    [[ $present_command == none || $present_command =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ ]] || return 1
    arquivo_tem_linha "$fixture/commands.txt" '# command|arguments|exit_status|stdout|stderr' || return 1
    arquivo_tem_linha "$fixture/systemctl-units.txt" '# unit|load_state|active_state|sub_state' || return 1
    validar_boot_evidence "$fixture/boot-evidence.txt" "$expected_immutable" || return 1
    validar_systemctl_units "$fixture/systemctl-units.txt" || return 1
    arquivo_tem_prefixo "$fixture/os-release" 'NAME=' || return 1
    arquivo_tem_prefixo "$fixture/os-release" 'ID=' || return 1

    if [[ $estado == present ]]; then
        actual_id=$(os_release_valor_literal "$fixture/os-release" ID) || return 1
        actual_id_like=$(os_release_valor_literal "$fixture/os-release" ID_LIKE) || return 1
        actual_version=$(os_release_valor_literal "$fixture/os-release" VERSION_ID) || return 1
        actual_codename=$(os_release_valor_literal "$fixture/os-release" VERSION_CODENAME) || return 1
        [[ -n $expected_id && $actual_id == "$expected_id" ]] || return 1
        [[ $actual_id_like == "$expected_id_like" ]] || return 1
        [[ $actual_version == "$expected_version" ]] || return 1
        [[ $actual_codename == "$expected_codename" ]] || return 1
    else
        [[ $caso == malicious-os-release && -z $expected_id && -z $expected_id_like &&
            -z $expected_version && -z $expected_codename ]] || return 1
        if os_release_valor_literal "$fixture/os-release" VERSION_CODENAME >/dev/null 2>&1; then
            return 1
        fi
        arquivo_tem_linha "$fixture/os-release" \
            "printf 'PLATFORM_FIXTURE_PAYLOAD_EXECUTED\\n'" || return 1
    fi

    if [[ $caso == ubuntu ]]; then
        [[ $expected_version == 26.04 && $expected_codename == resolute ]] || return 1
    fi
}

caso_esperado() {
    local procurado=$1 caso
    for caso in "${PLATFORM_HARNESS_CASES[@]}"; do
        [[ $caso == "$procurado" ]] && return 0
    done
    return 1
}

escrever_alvo_sondagens() {
    local destino=$1
    cat > "$destino" <<'TARGET'
#!/usr/bin/env bash
set -euo pipefail

shopt -q restricted_shell
[[ $PLATFORM_HARNESS_ACTIVE == 1 ]]
[[ $PLATFORM_HARNESS_RESTRICTED == 1 ]]
[[ $PLATFORM_ROOT == "$PLATFORM_HARNESS_DIR/root" ]]
[[ $PLATFORM_OS_RELEASE == "$PLATFORM_ROOT/etc/os-release" ]]
[[ $PATH == "$PLATFORM_HARNESS_PATH" ]]
case :$PATH: in
    *:/usr/bin:* | *:/bin:*) exit 80 ;;
esac
[[ -n $(command -v uname) ]]
[[ -n $(command -v probe-ok) ]]
[[ -f $PLATFORM_OS_RELEASE ]]
[[ $PLATFORM_BOOT_EVIDENCE_FILE == "$PLATFORM_PROBE_DIR/boot-evidence.txt" ]]
[[ $PLATFORM_SYSTEMCTL_UNITS_FILE == "$PLATFORM_PROBE_DIR/systemctl-units.txt" ]]
[[ -f $PLATFORM_BOOT_EVIDENCE_FILE && -f $PLATFORM_SYSTEMCTL_UNITS_FILE ]]

IFS= read -r primeira_linha < "$PLATFORM_OS_RELEASE"
IFS= read -r boot_header < "$PLATFORM_BOOT_EVIDENCE_FILE"
IFS= read -r units_header < "$PLATFORM_SYSTEMCTL_UNITS_FILE"
printf 'ROOT_FIRST=%s\n' "$primeira_linha"
printf 'BOOT_HEADER=%s\n' "$boot_header"
printf 'UNITS_HEADER=%s\n' "$units_header"
probe-ok --case "$PLATFORM_CASE"
uname -m
if probe-fail --case "$PLATFORM_CASE"; then
    exit 81
else
    status=$?
fi
[[ $status -eq 42 ]]
TARGET
    /usr/bin/chmod 0444 -- "$destino"
}

escrever_alvo_sem_os_release() {
    local destino=$1
    cat > "$destino" <<'TARGET'
#!/usr/bin/env bash
set -euo pipefail
shopt -q restricted_shell
[[ ! -e $PLATFORM_OS_RELEASE ]]
probe-ok --case "$PLATFORM_CASE"
TARGET
    /usr/bin/chmod 0444 -- "$destino"
}

escrever_alvo_malicioso() {
    local destino=$1
    cat > "$destino" <<'TARGET'
#!/usr/bin/env bash
set -euo pipefail
shopt -q restricted_shell
PLATFORM_FIXTURE_BUILTIN_EXECUTED=0
literal_malicioso=0
while IFS= read -r linha || [[ -n $linha ]]; do
    if [[ $linha == *'$('* || $linha == *'`'* ]]; then
        literal_malicioso=1
    fi
done < "$PLATFORM_OS_RELEASE"
[[ $literal_malicioso -eq 1 ]]
[[ $PLATFORM_FIXTURE_BUILTIN_EXECUTED -eq 0 ]]
printf 'MALICIOUS_LITERAL=preserved\n'
probe-ok --case "$PLATFORM_CASE"
TARGET
    /usr/bin/chmod 0444 -- "$destino"
}

escrever_alvo_canario() {
    local destino=$1
    cat > "$destino" <<'TARGET'
#!/usr/bin/env bash
set -u
shopt -q restricted_shell || exit 90
[[ $(type -t kill || :) != builtin ]] || exit 91

status_sudo=0
sudo --non-interactive true || status_sudo=$?
status_apt=0
apt-get install pacote-proibido || status_apt=$?
status_touch=0
touch "$PLATFORM_HARNESS_DIR/nao-deve-exist" || status_touch=$?
status_kill=0
kill -0 "$$" || status_kill=$?
status_absoluto=0
/usr/bin/printf 'ABSOLUTE_ESCAPE\n' || status_absoluto=$?

[[ $status_sudo -eq 126 ]] || exit 92
[[ $status_apt -eq 126 ]] || exit 93
[[ $status_touch -eq 126 ]] || exit 94
[[ $status_kill -eq 126 ]] || exit 95
[[ $status_absoluto -ne 0 ]] || exit 96
[[ ! -e $PLATFORM_HARNESS_DIR/nao-deve-exist ]] || exit 97
printf 'CANARY=sudo:%s,apt:%s,touch:%s,kill:%s\n' \
    "$status_sudo" "$status_apt" "$status_touch" "$status_kill"
printf 'ABSOLUTE_STATUS=%s\n' "$status_absoluto"
TARGET
    /usr/bin/chmod 0444 -- "$destino"
}

escrever_alvo_sondagem_ausente() {
    local destino=$1
    cat > "$destino" <<'TARGET'
#!/usr/bin/env bash
set -euo pipefail
shopt -q restricted_shell
status=0
probe-nao-declarada --fixture || status=$?
[[ $status -eq 127 ]]
probe-ok --case "$PLATFORM_CASE"
TARGET
    /usr/bin/chmod 0444 -- "$destino"
}

escrever_alvo_desativar_trace() {
    local destino=$1
    cat > "$destino" <<'TARGET'
#!/usr/bin/env bash
set -euo pipefail
shopt -q restricted_shell
set +x
probe-ok --case "$PLATFORM_CASE"
TARGET
    /usr/bin/chmod 0444 -- "$destino"
}

trap platform_harness_cleanup EXIT HUP INT TERM

[[ -d $PLATFORM_HARNESS_FIXTURES_DIR ]] || falha 'diretório de fixtures ausente'
mapfile -t diretorios_reais < <(
    for entrada in "$PLATFORM_HARNESS_FIXTURES_DIR"/*; do
        [[ -d $entrada && ! -L $entrada ]] && printf '%s\n' "${entrada##*/}"
    done
)
[[ ${#diretorios_reais[@]} -eq ${#PLATFORM_HARNESS_CASES[@]} ]] ||
    falha 'o conjunto de fixtures não contém exatamente os 11 casos exigidos'
for caso in "${diretorios_reais[@]}"; do
    caso_esperado "$caso" || falha "fixture inesperada: $caso"
done

for caso in "${PLATFORM_HARNESS_CASES[@]}"; do
    platform_harness_validate_fixture "$caso" || falha "fixture inválida: $caso"
    fixture="$PLATFORM_HARNESS_FIXTURES_DIR/$caso"
    validar_oraculo_fixture "$caso" "$fixture" ||
        falha "oráculos/evidências inválidos: $caso"
    IFS= read -r primeira_linha_fixture < "$fixture/os-release"

    platform_harness_setup "$caso" || falha "não foi possível preparar $caso"
    [[ $PLATFORM_ROOT != / && $PLATFORM_ROOT == "$PLATFORM_HARNESS_DIR/root" ]] ||
        falha "raiz não isolada em $caso"
    [[ $PLATFORM_HARNESS_PATH == "$PLATFORM_HARNESS_DIR/bin" ]] ||
        falha "PATH não isolado em $caso"
    [[ $PLATFORM_COMMANDS_FILE == "$PLATFORM_HARNESS_DIR/probes/commands.txt" ]] ||
        falha "respostas não materializadas em $caso"

    comando_presente=$(platform_harness_expected_value "$fixture/expected.env" PRESENT_COMMAND) ||
        falha "PRESENT_COMMAND ausente em $caso"
    if [[ $comando_presente == none ]]; then
        for gerenciador in apt-get pacman dnf zypper rpm-ostree; do
            [[ ! -e $PLATFORM_HARNESS_PATH/$gerenciador ]] ||
                falha "PATH de $caso contém comando não declarado: $gerenciador"
        done
    else
        [[ -x $PLATFORM_HARNESS_PATH/$comando_presente ]] ||
            falha "PATH de $caso não contém $comando_presente"
    fi

    alvo="$PLATFORM_HARNESS_WORK_DIR/probe-target.sh"
    saida="$PLATFORM_HARNESS_WORK_DIR/probe.stdout"
    erros="$PLATFORM_HARNESS_WORK_DIR/probe.stderr"
    escrever_alvo_sondagens "$alvo"
    platform_harness_run "$alvo" > "$saida" 2> "$erros" ||
        falha "runner falhou em $caso"
    arquivo_tem_linha "$saida" "ROOT_FIRST=$primeira_linha_fixture" ||
        falha "raiz injetada não foi usada em $caso"
    arquivo_tem_linha "$saida" 'BOOT_HEADER=# Evidência literal; não carregar como shell.' ||
        falha "boot-evidence injetado não foi aberto em $caso"
    arquivo_tem_linha "$saida" 'UNITS_HEADER=# unit|load_state|active_state|sub_state' ||
        falha "systemctl-units injetado não foi aberto em $caso"
    arquivo_tem_linha "$saida" "probe:$caso" ||
        falha "stdout injetado não observado em $caso"
    arquivo_tem_linha "$saida" 'x86_64' ||
        falha "resposta read-only de uname não foi injetada em $caso"
    arquivo_tem_linha "$erros" "probe-failure:$caso" ||
        falha "stderr injetado não observado em $caso"
    platform_harness_assert_clean || falha "execução limpa não comprovada em $caso"
    platform_harness_cleanup
 done

# A mesma fixture pode simular ausência ou ilegibilidade sem consultar /etc do host.
platform_harness_setup unknown-distro absent || falha 'falha ao simular os-release ausente'
[[ ! -e $PLATFORM_OS_RELEASE ]] || falha 'os-release deveria estar ausente na raiz simulada'
alvo="$PLATFORM_HARNESS_WORK_DIR/absent-target.sh"
escrever_alvo_sem_os_release "$alvo"
platform_harness_run "$alvo" > "$PLATFORM_HARNESS_WORK_DIR/absent.stdout" ||
    falha 'runner falhou com os-release ausente'
platform_harness_assert_clean || falha 'simulação ausente não permaneceu limpa'
platform_harness_cleanup

platform_harness_setup unknown-distro unreadable || falha 'falha ao simular os-release ilegível'
[[ -d $PLATFORM_OS_RELEASE ]] ||
    falha 'os-release ilegível deve ser um objeto não legível para qualquer UID'
modo=$(/usr/bin/stat -c '%a' -- "$PLATFORM_OS_RELEASE")
[[ $modo == 555 ]] || falha "os-release ilegível ficou com modo $modo"
alvo="$PLATFORM_HARNESS_WORK_DIR/unreadable-target.sh"
cat > "$alvo" <<'TARGET'
#!/usr/bin/env bash
set -euo pipefail
shopt -q restricted_shell
status_leitura=0
IFS= read -r linha < "$PLATFORM_OS_RELEASE" || status_leitura=$?
[[ $status_leitura -ne 0 ]]
probe-ok --case "$PLATFORM_CASE"
TARGET
/usr/bin/chmod 0444 -- "$alvo"
platform_harness_run "$alvo" > "$PLATFORM_HARNESS_WORK_DIR/unreadable.stdout" \
    2> "$PLATFORM_HARNESS_WORK_DIR/unreadable.stderr" ||
    falha 'runner falhou com os-release ilegível'
platform_harness_assert_clean || falha 'simulação ilegível não permaneceu limpa'
platform_harness_cleanup

# A entrada hostil permanece texto literal e não cria o marcador-canário.
platform_harness_setup malicious-os-release || falha 'falha ao preparar fixture maliciosa'
alvo="$PLATFORM_HARNESS_WORK_DIR/malicious-target.sh"
saida="$PLATFORM_HARNESS_WORK_DIR/malicious.stdout"
escrever_alvo_malicioso "$alvo"
platform_harness_run "$alvo" > "$saida" || falha 'runner falhou na fixture maliciosa'
arquivo_tem_linha "$saida" 'MALICIOUS_LITERAL=preserved' ||
    falha 'conteúdo hostil não foi preservado literalmente'
if arquivo_tem_linha "$saida" 'PLATFORM_FIXTURE_PAYLOAD_EXECUTED'; then
    falha 'a fixture maliciosa executou um builtin shell'
fi
platform_harness_assert_clean || falha 'fixture maliciosa não permaneceu limpa'
platform_harness_cleanup

# Canários devem falhar fechados e aparecer no log; log vazio não é aceito como prova.
platform_harness_setup ubuntu || falha 'falha ao preparar canários'
alvo="$PLATFORM_HARNESS_WORK_DIR/canary-target.sh"
saida="$PLATFORM_HARNESS_WORK_DIR/canary.stdout"
escrever_alvo_canario "$alvo"
platform_harness_run "$alvo" > "$saida" 2> "$PLATFORM_HARNESS_WORK_DIR/canary.stderr" ||
    falha 'runner não conteve os canários'
arquivo_tem_linha "$saida" 'CANARY=sudo:126,apt:126,touch:126,kill:126' ||
    falha 'status dos canários divergente'
arquivo_tem_prefixo "$saida" 'ABSOLUTE_STATUS=' ||
    falha 'status da tentativa absoluta ausente'
if arquivo_tem_linha "$saida" 'ABSOLUTE_ESCAPE'; then
    falha 'comando absoluto escapou do shell restrito'
fi
platform_harness_assert_forbidden_logged sudo || falha 'sudo não foi registrado'
platform_harness_assert_forbidden_logged apt-get || falha 'apt-get não foi registrado'
platform_harness_assert_forbidden_logged touch || falha 'touch não foi registrado'
platform_harness_assert_forbidden_logged kill || falha 'builtin kill não foi neutralizado/registrado'
platform_harness_assert_absolute_attempt_logged /usr/bin/printf ||
    falha 'tentativa por caminho absoluto não foi registrada no trace'
[[ -s $PLATFORM_CALL_LOG && -s $PLATFORM_FORBIDDEN_LOG && -s $PLATFORM_TRACE_LOG ]] ||
    falha 'logs de auditoria dos canários ficaram vazios'
[[ ! -e $PLATFORM_HARNESS_DIR/nao-deve-exist ]] ||
    falha 'um comando mutável escapou do harness'
platform_harness_assert_root_unchanged || falha 'canários alteraram a raiz simulada'
platform_harness_cleanup

# Uma sondagem fora da allowlist deve ser registrada e invalidar uma execução "limpa".
platform_harness_setup unknown-distro || falha 'falha ao preparar canário de sondagem ausente'
alvo="$PLATFORM_HARNESS_WORK_DIR/missing-target.sh"
escrever_alvo_sondagem_ausente "$alvo"
platform_harness_run "$alvo" > "$PLATFORM_HARNESS_WORK_DIR/missing.stdout" ||
    falha 'runner falhou no canário de sondagem ausente'
if platform_harness_assert_clean 2> "$PLATFORM_HARNESS_WORK_DIR/missing.assert.stderr"; then
    falha 'sondagem não declarada foi aceita como execução limpa'
fi
platform_harness_assert_root_unchanged || falha 'sondagem ausente alterou a raiz simulada'
platform_harness_cleanup

# Desativar xtrace é uma tentativa de burlar auditoria e deve invalidar a execução.
platform_harness_setup unknown-distro || falha 'falha ao preparar canário de xtrace'
alvo="$PLATFORM_HARNESS_WORK_DIR/xtrace-bypass-target.sh"
escrever_alvo_desativar_trace "$alvo"
platform_harness_run "$alvo" > "$PLATFORM_HARNESS_WORK_DIR/xtrace.stdout" ||
    falha 'runner falhou no canário de xtrace'
if platform_harness_assert_clean 2> "$PLATFORM_HARNESS_WORK_DIR/xtrace.assert.stderr"; then
    falha 'desativação de xtrace foi aceita como execução limpa'
fi
arquivo_tem_prefixo "$PLATFORM_HARNESS_WORK_DIR/xtrace.assert.stderr" \
    'platform-harness: tentativa de desativar auditoria xtrace:' ||
    falha 'motivo do bloqueio de xtrace não foi registrado'
platform_harness_assert_root_unchanged || falha 'canário de xtrace alterou a raiz simulada'
platform_harness_cleanup

printf 'OK: harness hermético e 11 fixtures de plataforma validados\n'
