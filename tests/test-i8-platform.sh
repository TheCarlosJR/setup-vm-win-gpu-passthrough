#!/usr/bin/env bash
# ============================================================================
# tests/test-i8-platform.sh - tarefa I8.5
# ============================================================================
# Executa as 11 fixtures canônicas de plataforma contra a implementação REAL
# (`plataforma_carregar` com fonte de os-release explícita, resolvida pelo core
# Python atrás da fachada Bash) e prova, para cada caso:
#
#   * o código de retorno e as sete globais de decisão, string inteira;
#   * os campos do os-release conferidos com o `expected.env` da própria
#     fixture, lido como DADO (linha a linha, nunca `source`);
#   * determinismo: duas execuções seguidas produzem o mesmo dump ordenado de
#     TODAS as `PLATAFORMA_*`, e a ordem dos casos não muda resultado nenhum;
#   * invariância: a árvore de fixtures fica idêntica em caminho, modo, tamanho
#     e mtime, e nada é criado no HOME nem na raiz de estado (ambos temporários);
#   * nenhuma das 21 capabilities habilitada fora de `supported`, sempre com o
#     motivo de bloqueio;
#   * os textos que são oráculo do gate I1, byte a byte, inclusive sob as
#     expressões que o próprio gate usa;
#   * inércia da fixture hostil: nada é executado e, com leitura inválida,
#     nenhum campo é publicado.
#
# Sem sudo, sem tocar /etc e sem escrever fora da raiz temporária própria.
# ============================================================================
set -euo pipefail

RAIZ=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

TMP=$(mktemp -d "${TMPDIR:-/tmp}/i8-platform.XXXXXXXX") \
    || { printf 'FALHA I8: não foi possível criar a raiz temporária.\n' >&2; exit 1; }
limpar_i8() {
    command -v python_core_temporarios_limpar >/dev/null 2>&1 \
        && python_core_temporarios_limpar 2>/dev/null
    rm -rf -- "$TMP"
    return 0
}
trap limpar_i8 EXIT HUP INT TERM

# HOME e raiz de estado saem do host antes de qualquer carga: a prova de que
# nada foi criado só vale se o alvo observado for exclusivo deste teste.
mkdir -p -- "$TMP/home" "$TMP/state" "$TMP/dump"
HOME="$TMP/home"; export HOME
XDG_STATE_HOME="$TMP/state"; export XDG_STATE_HOME

# Implementação real. `lib/platform.sh` carrega a ponte do core sozinho, então
# não é preciso arrastar `lib/common.sh` (e seus efeitos) para dentro do teste.
# shellcheck source=../lib/platform.sh
source "$RAIZ/lib/platform.sh"
# Lista canônica de casos, diretório de fixtures e leitor de `expected.env`.
# shellcheck source=lib/platform-harness.sh
source "$RAIZ/tests/lib/platform-harness.sh"

CHECKS=0
falha() { printf 'FALHA I8: %s\n' "$*" >&2; exit 1; }
grupo() { CHECKS=$((CHECKS + 1)); }
igual() {
    local obtido=$1 esperado=$2 descricao=$3
    [[ $obtido == "$esperado" ]] \
        || falha "$descricao: esperado [$esperado], obtido [$obtido]"
}
vazio() {
    local obtido=$1 descricao=$2
    [[ -z $obtido ]] || falha "$descricao deveria estar vazio, obtido [$obtido]"
}
arquivo_vazio() {
    local arquivo=$1 descricao=$2
    [[ -f $arquivo && ! -s $arquivo ]] \
        || falha "$descricao deveria estar vazio: $(head -c 400 -- "$arquivo")"
}

# --- Dump ordenado de TODAS as globais de plataforma ------------------------
# Escalares, array indexado de pacotes e os dois mapas de capabilities entram
# no mesmo arquivo, com chaves ordenadas em C. Comparar subconjunto esconderia
# exatamente o tipo de vazamento que esta tarefa precisa pegar.

_i8_dump_assoc() {
    local -n _i8_ref=$1
    local _i8_nome=$1 _i8_chave
    printf '%s#\t%s\n' "$_i8_nome" "${#_i8_ref[@]}"
    ((${#_i8_ref[@]} > 0)) || return 0
    while IFS= read -r _i8_chave; do
        printf '%s[%s]\t%s\n' "$_i8_nome" "$_i8_chave" "${_i8_ref[$_i8_chave]}"
    done < <(printf '%s\n' "${!_i8_ref[@]}" | LC_ALL=C sort)
}

_i8_dump_indexado() {
    local -n _i8_ref=$1
    local _i8_nome=$1 _i8_indice
    printf '%s#\t%s\n' "$_i8_nome" "${#_i8_ref[@]}"
    for _i8_indice in "${!_i8_ref[@]}"; do
        printf '%s[%s]\t%s\n' "$_i8_nome" "$_i8_indice" "${_i8_ref[$_i8_indice]}"
    done
}

plataforma_dump() {
    local destino=$1 nome declaracao tipo
    : > "$destino"
    while IFS= read -r nome; do
        if ! declaracao=$(declare -p "$nome" 2>/dev/null); then
            printf '%s\tINDEFINIDA\n' "$nome" >> "$destino"
            continue
        fi
        tipo=${declaracao#declare }
        tipo=${tipo%% *}
        case $tipo in
            *A*) _i8_dump_assoc "$nome" >> "$destino" ;;
            *a*) _i8_dump_indexado "$nome" >> "$destino" ;;
            *) printf '%s\t%s\n' "$nome" "${!nome}" >> "$destino" ;;
        esac
    done < <(compgen -v PLATAFORMA_ | LC_ALL=C sort)
    [[ -s $destino ]] || falha 'dump de plataforma vazio; prova vazia recusada'
}

arvore_assinatura() {
    local raiz=$1 destino=$2
    /usr/bin/find "$raiz" -printf '%p|%m|%s|%T@\n' | LC_ALL=C sort > "$destino"
    [[ -s $destino ]] || falha "assinatura vazia para $raiz"
}

# Reproduz, byte a byte, o texto que `guard_mutation` (lib/common.sh) monta a
# partir destas globais. É esse texto que o gate I1 procura no stderr dos
# mutadores; renderizá-lo aqui prova que o oráculo continua saindo daqui.
motivo_guarda() {
    if [[ $PLATAFORMA_DETECTADA -ne 1 ]]; then
        printf 'plataforma não pôde ser detectada com confiança: %s\n' "$PLATAFORMA_ERRO"
    elif [[ $PLATAFORMA_IMUTAVEL -eq 1 ]]; then
        printf 'plataforma imutável: %s\n' "$PLATAFORMA_BLOQUEIO_MOTIVO"
    else
        printf 'nível de suporte %s: %s\n' "$PLATAFORMA_SUPPORT_LEVEL" "$PLATAFORMA_BLOQUEIO_MOTIVO"
    fi
}

# Uma execução real: fecha os dois canais em arquivo (nenhuma etapa lê a saída
# de `plataforma_carregar`, então qualquer byte aqui já é regressão) e devolve
# o código sem deixar `set -e` abortar o caso bloqueado, que é o esperado.
carregar_fixture() {
    local caso=$1 rc=0
    plataforma_carregar "$PLATFORM_HARNESS_FIXTURES_DIR/$caso/os-release" \
        > "$TMP/stdout.$caso" 2> "$TMP/stderr.$caso" || rc=$?
    arquivo_vazio "$TMP/stdout.$caso" "stdout de $caso"
    arquivo_vazio "$TMP/stderr.$caso" "stderr de $caso"
    return "$rc"
}

# --- Oráculo por caso, medido contra a implementação real --------------------
# caso|rc|support_level|mutavel|imutavel|perfil|carregada|detectada|capabilities|motivo
# `perfil` não é permissão: o host imutável publica `immutable-diagnostic` (I8.3)
# e continua com mutação fechada; só `ubuntu` e `pop-os` chegam a `supported`.
# `capabilities` é o número de entradas publicadas em PLATAFORMA_CAPABILITIES:
# 21 quando houve leitura válida, 0 quando o resolver abortou antes de publicar
# o mapa (é o caso da fixture hostil, e o acesso efetivo continua fechado).
declare -A ESPERADO_RC=() ESPERADO_NIVEL=() ESPERADO_MUTAVEL=() ESPERADO_IMUTAVEL=()
declare -A ESPERADO_PERFIL=() ESPERADO_CARREGADA=() ESPERADO_DETECTADA=()
declare -A ESPERADO_CAPS=() ESPERADO_MOTIVO=()
linha_numero=0
while IFS= read -r linha || [[ -n $linha ]]; do
    [[ -n $linha && $linha != \#* ]] || continue
    linha_numero=$((linha_numero + 1))
    resto=$linha
    barras=0
    while [[ $resto == *'|'* ]]; do
        resto=${resto#*|}
        barras=$((barras + 1))
    done
    ((barras == 9)) || falha "oráculo I8 exige dez campos por linha: $linha"
    IFS='|' read -r caso rc nivel mutavel imutavel perfil carregada detectada caps motivo \
        <<< "$linha"
    [[ -z ${ESPERADO_RC[$caso]+presente} ]] || falha "caso repetido no oráculo: $caso"
    ESPERADO_RC[$caso]=$rc
    ESPERADO_NIVEL[$caso]=$nivel
    ESPERADO_MUTAVEL[$caso]=$mutavel
    ESPERADO_IMUTAVEL[$caso]=$imutavel
    ESPERADO_PERFIL[$caso]=$perfil
    ESPERADO_CARREGADA[$caso]=$carregada
    ESPERADO_DETECTADA[$caso]=$detectada
    ESPERADO_CAPS[$caso]=$caps
    ESPERADO_MOTIVO[$caso]=$motivo
done <<'TABELA'
ubuntu|0|supported|1|0|ubuntu|1|1|21|
pop-os|0|supported|1|0|pop-os|1|1|21|
debian|1|diagnostic-only|0|0||0|1|21|ID=debian possui provider planejado, ainda restrito a diagnóstico.
arch|1|diagnostic-only|0|0||0|1|21|ID=arch possui provider planejado, ainda restrito a diagnóstico.
cachyos|1|diagnostic-only|0|0||0|1|21|ID=cachyos possui provider planejado, ainda restrito a diagnóstico.
fedora|1|diagnostic-only|0|0||0|1|21|ID=fedora possui provider planejado, ainda restrito a diagnóstico.
opensuse|1|diagnostic-only|0|0||0|1|21|ID=opensuse-tumbleweed possui provider planejado, ainda restrito a diagnóstico.
unknown-derivative|1|family-unverified|0|0||0|1|21|ID=nebula declara ID_LIKE=ubuntu debian, mas a derivação não foi verificada.
unknown-distro|1|blocked|0|0||0|1|21|ID=orion não possui provider reconhecido.
malicious-os-release|1|blocked|0|0||0|0|0|
immutable|1|diagnostic-only|0|1|immutable-diagnostic|0|1|21|VARIANT_ID=silverblue identifica uma implantação imutável.
TABELA

# O oráculo e a lista canônica do harness precisam cobrir exatamente os mesmos
# casos: fixture nova sem expectativa, ou expectativa órfã, reprovam aqui.
((linha_numero == ${#PLATFORM_HARNESS_CASES[@]})) \
    || falha "oráculo I8 tem $linha_numero casos e o harness tem ${#PLATFORM_HARNESS_CASES[@]}"
igual "$linha_numero" 11 'quantidade de fixtures canônicas de plataforma'
for caso in "${PLATFORM_HARNESS_CASES[@]}"; do
    [[ -n ${ESPERADO_RC[$caso]+presente} ]] || falha "caso canônico sem oráculo I8: $caso"
done
igual "${#PLATAFORMA_CAPABILITIES_CONHECIDAS[@]}" 21 'capabilities conhecidas'
grupo

# --- Invariância: assinaturas iniciais --------------------------------------
arvore_assinatura "$PLATFORM_HARNESS_FIXTURES_DIR" "$TMP/fixtures.antes"
/usr/bin/find "$HOME" -mindepth 1 -printf '%p\n' | LC_ALL=C sort > "$TMP/home.antes"
/usr/bin/find "$XDG_STATE_HOME" -mindepth 1 -printf '%p\n' | LC_ALL=C sort > "$TMP/state.antes"
arquivo_vazio "$TMP/home.antes" 'HOME temporário antes do teste'
arquivo_vazio "$TMP/state.antes" 'raiz de estado temporária antes do teste'
grupo

# --- Verificação por capability ---------------------------------------------
verificar_capabilities() {
    local caso=$1 capability valor motivo esperado_valor esperado_motivo habilitadas=0
    if [[ $PLATAFORMA_SUPPORT_LEVEL == supported ]]; then
        esperado_valor=1
        esperado_motivo="Capability habilitada pelo perfil exato $PLATAFORMA_PERFIL."
    else
        esperado_valor=0
        esperado_motivo=$PLATAFORMA_BLOQUEIO_MOTIVO
    fi
    for capability in "${PLATAFORMA_CAPABILITIES_CONHECIDAS[@]}"; do
        # Mesma leitura efetiva de platform_has_capability/platform_capability_reason:
        # ausência no mapa é acesso fechado, não permissão silenciosa.
        valor=${PLATAFORMA_CAPABILITIES[$capability]:-0}
        motivo=${PLATAFORMA_CAPABILITY_REASONS[$capability]:-$PLATAFORMA_BLOQUEIO_MOTIVO}
        igual "$valor" "$esperado_valor" "$caso: capability $capability"
        igual "$motivo" "$esperado_motivo" "$caso: motivo da capability $capability"
        if [[ $valor == 1 ]]; then
            habilitadas=$((habilitadas + 1))
        fi
        platform_capability_known "$capability" \
            || falha "$caso: capability $capability deixou de ser conhecida"
    done
    if [[ $PLATAFORMA_SUPPORT_LEVEL == supported ]]; then
        igual "$habilitadas" 21 "$caso: capabilities habilitadas no perfil exato"
    else
        igual "$habilitadas" 0 \
            "$caso: capabilities habilitadas fora de supported ($PLATAFORMA_SUPPORT_LEVEL)"
    fi
    igual "${#PLATAFORMA_CAPABILITIES[@]}" "${ESPERADO_CAPS[$caso]}" \
        "$caso: entradas publicadas em PLATAFORMA_CAPABILITIES"
    igual "${#PLATAFORMA_CAPABILITY_REASONS[@]}" "${ESPERADO_CAPS[$caso]}" \
        "$caso: entradas publicadas em PLATAFORMA_CAPABILITY_REASONS"
}

# --- Verificação de um caso --------------------------------------------------
verificar_caso() {
    local caso=$1 dump=$2 rc=0 fixture="$PLATFORM_HARNESS_FIXTURES_DIR/$caso"
    local esperado_id esperado_id_like esperado_version esperado_codename esperado_immutable

    platform_harness_validate_fixture "$caso" || falha "fixture inválida: $caso"
    carregar_fixture "$caso" || rc=$?

    igual "$rc" "${ESPERADO_RC[$caso]}" "$caso: código de retorno de plataforma_carregar"
    igual "$PLATAFORMA_SUPPORT_LEVEL" "${ESPERADO_NIVEL[$caso]}" "$caso: PLATAFORMA_SUPPORT_LEVEL"
    igual "$PLATAFORMA_MUTAVEL" "${ESPERADO_MUTAVEL[$caso]}" "$caso: PLATAFORMA_MUTAVEL"
    igual "$PLATAFORMA_IMUTAVEL" "${ESPERADO_IMUTAVEL[$caso]}" "$caso: PLATAFORMA_IMUTAVEL"
    igual "$PLATAFORMA_PERFIL" "${ESPERADO_PERFIL[$caso]}" "$caso: PLATAFORMA_PERFIL"
    igual "$PLATAFORMA_CARREGADA" "${ESPERADO_CARREGADA[$caso]}" "$caso: PLATAFORMA_CARREGADA"
    igual "$PLATAFORMA_DETECTADA" "${ESPERADO_DETECTADA[$caso]}" "$caso: PLATAFORMA_DETECTADA"
    igual "$PLATAFORMA_BLOQUEIO_MOTIVO" "${ESPERADO_MOTIVO[$caso]}" \
        "$caso: PLATAFORMA_BLOQUEIO_MOTIVO"

    # `expected.env` da própria fixture, lido linha a linha como dado.
    esperado_id=$(platform_harness_expected_value "$fixture/expected.env" EXPECTED_ID) \
        || falha "$caso: EXPECTED_ID ilegível"
    esperado_id_like=$(platform_harness_expected_value "$fixture/expected.env" EXPECTED_ID_LIKE) \
        || falha "$caso: EXPECTED_ID_LIKE ilegível"
    esperado_version=$(platform_harness_expected_value "$fixture/expected.env" EXPECTED_VERSION_ID) \
        || falha "$caso: EXPECTED_VERSION_ID ilegível"
    esperado_codename=$(platform_harness_expected_value "$fixture/expected.env" EXPECTED_VERSION_CODENAME) \
        || falha "$caso: EXPECTED_VERSION_CODENAME ilegível"
    esperado_immutable=$(platform_harness_expected_value "$fixture/expected.env" EXPECTED_IMMUTABLE) \
        || falha "$caso: EXPECTED_IMMUTABLE ilegível"
    igual "$(platform_harness_expected_value "$fixture/expected.env" CASE_ID)" "$caso" \
        "$caso: CASE_ID da fixture"

    igual "$PLATAFORMA_ID" "$esperado_id" "$caso: PLATAFORMA_ID contra expected.env"
    igual "$PLATAFORMA_ID_LIKE" "$esperado_id_like" "$caso: PLATAFORMA_ID_LIKE contra expected.env"
    igual "$PLATAFORMA_VERSION_ID" "$esperado_version" "$caso: PLATAFORMA_VERSION_ID contra expected.env"
    igual "$PLATAFORMA_VERSION_CODENAME" "$esperado_codename" \
        "$caso: PLATAFORMA_VERSION_CODENAME contra expected.env"
    case $esperado_immutable in
        true) igual "$PLATAFORMA_IMUTAVEL" 1 "$caso: PLATAFORMA_IMUTAVEL contra expected.env" ;;
        false) igual "$PLATAFORMA_IMUTAVEL" 0 "$caso: PLATAFORMA_IMUTAVEL contra expected.env" ;;
        *) falha "$caso: EXPECTED_IMMUTABLE fora do vocabulário: $esperado_immutable" ;;
    esac

    # Nome de perfil não é permissão. Um perfil novo (o `immutable-diagnostic`
    # de I8.3 é o primeiro) só pode abrir mutação se o nível for `supported`.
    if [[ $PLATAFORMA_SUPPORT_LEVEL == supported ]]; then
        igual "$PLATAFORMA_MUTAVEL" 1 "$caso: supported precisa ser mutável"
        igual "$PLATAFORMA_CARREGADA" 1 "$caso: supported precisa ficar carregada"
        igual "$PLATAFORMA_IMUTAVEL" 0 "$caso: supported não pode ser imutável"
        case $PLATAFORMA_PERFIL in
            ubuntu | pop-os) ;;
            *) falha "$caso: perfil sem provider exato chegou a supported: $PLATAFORMA_PERFIL" ;;
        esac
    else
        igual "$PLATAFORMA_MUTAVEL" 0 "$caso: mutabilidade fora de supported"
        igual "$PLATAFORMA_CARREGADA" 0 "$caso: carga concluída fora de supported"
    fi

    verificar_capabilities "$caso"

    # Malícia da fixture hostil não pode virar variável, nem em caso nenhum.
    [[ -z ${PLATFORM_FIXTURE_BUILTIN_EXECUTED+definida} ]] \
        || falha "$caso: canário de builtin da fixture foi definido"
    [[ -z ${PLATFORM_FIXTURE_PAYLOAD_EXECUTED+definida} ]] \
        || falha "$caso: canário de payload da fixture foi definido"

    plataforma_dump "$dump"
    if /usr/bin/grep -Fq -e 'payload-in-' -e 'PLATFORM_FIXTURE' -- "$dump"; then
        falha "$caso: payload da fixture apareceu em uma global de plataforma"
    fi
}

# --- Passada canônica, com determinismo por caso -----------------------------
for caso in "${PLATFORM_HARNESS_CASES[@]}"; do
    verificar_caso "$caso" "$TMP/dump/$caso.1"
    verificar_caso "$caso" "$TMP/dump/$caso.2"
    /usr/bin/cmp -s -- "$TMP/dump/$caso.1" "$TMP/dump/$caso.2" \
        || falha "$caso: duas execuções seguidas divergiram (dump completo de PLATAFORMA_*)"
    grupo
done

# A ordem em que os casos são carregados não pode mudar resultado nenhum: um
# resolver que vazasse estado do caso anterior passaria na passada canônica e
# quebraria aqui.
for ((indice = ${#PLATFORM_HARNESS_CASES[@]} - 1; indice >= 0; indice--)); do
    caso=${PLATFORM_HARNESS_CASES[$indice]}
    verificar_caso "$caso" "$TMP/dump/$caso.reverso"
    /usr/bin/cmp -s -- "$TMP/dump/$caso.1" "$TMP/dump/$caso.reverso" \
        || falha "$caso: resultado dependeu da ordem de carga das fixtures"
done
grupo

# --- Textos que são oráculo do gate I1, byte a byte --------------------------
# Cinco textos alcançáveis pelas fixtures. Os três primeiros são procurados
# literalmente por tests/test-i1-safety-envelope.sh; os dois últimos são os
# motivos completos de que aqueles trechos fazem parte.
carregar_fixture debian || true
igual "$PLATAFORMA_SUPPORT_LEVEL" 'diagnostic-only' 'oráculo I1: nível diagnostic-only'
igual "$PLATAFORMA_BLOQUEIO_MOTIVO" \
    'ID=debian possui provider planejado, ainda restrito a diagnóstico.' \
    'oráculo I1: motivo do provider planejado'
igual "$PLATAFORMA_ERRO" \
    'Mutação indisponível no nível diagnostic-only: ID=debian possui provider planejado, ainda restrito a diagnóstico.' \
    'oráculo I1: erro publicado no nível diagnóstico'
motivo_guarda > "$TMP/guarda.planned"
igual "$(cat -- "$TMP/guarda.planned")" \
    'nível de suporte diagnostic-only: ID=debian possui provider planejado, ainda restrito a diagnóstico.' \
    'oráculo I1: texto que guard_mutation publica para provider planejado'
/usr/bin/grep -Eiq -- 'diagnostic-only' "$TMP/guarda.planned" \
    || falha 'expressão do gate I1 para o perfil planned não casou mais'

carregar_fixture unknown-distro || true
igual "$PLATAFORMA_BLOQUEIO_MOTIVO" 'ID=orion não possui provider reconhecido.' \
    'oráculo I1: motivo de provider desconhecido'
motivo_guarda > "$TMP/guarda.unknown"
igual "$(cat -- "$TMP/guarda.unknown")" \
    'nível de suporte blocked: ID=orion não possui provider reconhecido.' \
    'oráculo I1: texto que guard_mutation publica para provider desconhecido'
/usr/bin/grep -Eiq -- 'não possui provider reconhecido' "$TMP/guarda.unknown" \
    || falha 'expressão do gate I1 para o perfil unknown não casou mais'

carregar_fixture immutable || true
igual "$PLATAFORMA_BLOQUEIO_MOTIVO" 'VARIANT_ID=silverblue identifica uma implantação imutável.' \
    'oráculo I1: motivo da implantação imutável'
motivo_guarda > "$TMP/guarda.immutable"
igual "$(cat -- "$TMP/guarda.immutable")" \
    'plataforma imutável: VARIANT_ID=silverblue identifica uma implantação imutável.' \
    'oráculo I1: texto que guard_mutation publica para implantação imutável'
/usr/bin/grep -Eiq -- 'plataforma imutável|VARIANT_ID=silverblue' "$TMP/guarda.immutable" \
    || falha 'expressão do gate I1 para o perfil immutable-variant não casou mais'

carregar_fixture unknown-derivative || true
igual "$PLATAFORMA_BLOQUEIO_MOTIVO" \
    'ID=nebula declara ID_LIKE=ubuntu debian, mas a derivação não foi verificada.' \
    'oráculo I1: motivo de família declarada e não verificada'

# Fonte de os-release explícita nunca olha /run/ostree-booted, então a frase de
# ostree não pode aparecer por fixture nenhuma; se aparecer, o resolver passou
# a consultar o host quando o chamador injetou o arquivo.
for caso in "${PLATFORM_HARNESS_CASES[@]}"; do
    if /usr/bin/grep -Fq 'implantação ostree' -- "$TMP/dump/$caso.1"; then
        falha "$caso: evidência ostree do host vazou para uma fonte explícita"
    fi
done
grupo

# --- Fixture hostil: inerte e sem publicação parcial ------------------------
# Carrega primeiro um perfil suportado, que publica TODOS os campos, e só então
# a fixture hostil: o que sobreviver ao reset é vazamento, não leitura.
carregar_fixture ubuntu || falha "perfil suportado falhou antes do teste hostil: $PLATAFORMA_ERRO"
igual "$PLATAFORMA_ID" ubuntu 'pré-condição do teste hostil: perfil suportado carregado'
hostil="$PLATFORM_HARNESS_FIXTURES_DIR/malicious-os-release/os-release"
/usr/bin/grep -Fxq 'ID=hostile' -- "$hostil" \
    || falha 'fixture hostil deixou de declarar ID=hostile; o teste perderia o sentido'
/usr/bin/grep -Fq 'PLATFORM_FIXTURE_BUILTIN_EXECUTED' -- "$hostil" \
    || falha 'fixture hostil deixou de carregar o canário de builtin'

rc_hostil=0
carregar_fixture malicious-os-release || rc_hostil=$?
igual "$rc_hostil" 1 'fixture hostil precisa reprovar'
igual "$PLATAFORMA_DETECTADA" 0 'fixture hostil não pode ser dada como detectada'
igual "$PLATAFORMA_CARREGADA" 0 'fixture hostil não pode ficar carregada'
vazio "$PLATAFORMA_ID" 'PLATAFORMA_ID com ID=hostile no arquivo'
vazio "$PLATAFORMA_ID_LIKE" 'PLATAFORMA_ID_LIKE com ID_LIKE hostil no arquivo'
vazio "$PLATAFORMA_VARIANT_ID" 'PLATAFORMA_VARIANT_ID após leitura inválida'
vazio "$PLATAFORMA_VERSION_ID" 'PLATAFORMA_VERSION_ID com VERSION_ID="1" no arquivo'
vazio "$PLATAFORMA_VERSION_CODENAME" 'PLATAFORMA_VERSION_CODENAME após leitura inválida'
vazio "$PLATAFORMA_PERFIL" 'PLATAFORMA_PERFIL após leitura inválida'
vazio "$PLATAFORMA_BLOQUEIO_MOTIVO" 'PLATAFORMA_BLOQUEIO_MOTIVO após leitura inválida'
vazio "$PLATAFORMA_QEMU_PACOTE" 'PLATAFORMA_QEMU_PACOTE do perfil anterior'
vazio "$PLATAFORMA_NVIDIA_ESTRATEGIA" 'PLATAFORMA_NVIDIA_ESTRATEGIA do perfil anterior'
igual "${#PLATAFORMA_PACOTES_VIRTUALIZACAO[@]}" 0 'pacotes do perfil anterior sobreviveram'
igual "$PLATAFORMA_ERRO" \
    "VERSION_CODENAME inválido em $hostil." \
    'diagnóstico da fixture hostil, com o caminho renderizado no Bash'
[[ -z ${PLATFORM_FIXTURE_BUILTIN_EXECUTED+definida} ]] \
    || falha 'a fixture hostil executou um builtin shell'
[[ -z ${PLATFORM_FIXTURE_PAYLOAD_EXECUTED+definida} ]] \
    || falha 'a fixture hostil executou o payload'
if /usr/bin/grep -Fq -e 'payload-in-' -e 'hostile' -- "$TMP/dump/malicious-os-release.1"; then
    falha 'campo da fixture hostil foi publicado apesar de leitura inválida'
fi
grupo

# --- Invariância final -------------------------------------------------------
arvore_assinatura "$PLATFORM_HARNESS_FIXTURES_DIR" "$TMP/fixtures.depois"
/usr/bin/cmp -s -- "$TMP/fixtures.antes" "$TMP/fixtures.depois" \
    || { /usr/bin/diff -- "$TMP/fixtures.antes" "$TMP/fixtures.depois" >&2 || true
         falha 'a árvore de fixtures mudou (caminho, modo, tamanho ou mtime)'; }
/usr/bin/find "$HOME" -mindepth 1 -printf '%p\n' | LC_ALL=C sort > "$TMP/home.depois"
/usr/bin/find "$XDG_STATE_HOME" -mindepth 1 -printf '%p\n' | LC_ALL=C sort > "$TMP/state.depois"
arquivo_vazio "$TMP/home.depois" 'HOME temporário depois do teste'
arquivo_vazio "$TMP/state.depois" 'raiz de estado temporária depois do teste'
[[ ! -e /run/ostree-booted ]] || falha 'ambiente inesperado: /run/ostree-booted existe no host'
grupo

printf 'OK: I8.5 (11 fixtures de plataforma na implementação real; %d grupos), determinismo, invariância de árvore/HOME/estado, 21 capabilities fechadas fora de supported e fixture hostil inerte\n' \
    "$CHECKS"
