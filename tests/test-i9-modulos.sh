#!/usr/bin/env bash
# Gate dirigido I9.1 a I9.6: grafo de carga dos módulos de lib/shell/.
#
# O que este teste protege:
#
#   * carregar um módulo fora de ordem é RECUSADO com diagnóstico nominal, em
#     vez de estourar mais tarde como "command not found" no meio de uma
#     mutação;
#   * cada pré-requisito declarado por um módulo aparece ANTES dele na fachada;
#     um ciclo ou uma inversão de ordem reprova aqui, não em produção;
#   * carregar não produz efeito: com PATH vazio nenhum comando externo é
#     invocado e nada é escrito na home do operador;
#   * source duplo é no-op: o estado já publicado pelos módulos sobrevive;
#   * a fachada é agregador, não monólito: sem algoritmo de domínio e sem
#     módulo carregando outro módulo por conta própria.
#
# Hermético: nenhuma etapa é executada, nenhum host é tocado, nada é gravado
# fora do TMP do próprio teste.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
BASH_BIN="${BASH:-/bin/bash}"
export LC_ALL=C

fail() { printf 'FALHA I9.6: %s\n' "$*" >&2; exit 1; }
CASOS=0
passo() { CASOS=$((CASOS + 1)); }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/i9-modulos.XXXXXXXX")
trap 'rm -rf -- "$TMP"' EXIT HUP INT TERM

# Ordem publicada pela fachada. Qualquer divergência entre esta lista e o que
# lib/common.sh realmente carrega reprova no caso 1.
ORDEM=(
    lib/shell/base.sh
    lib/platform.sh
    lib/python-core.sh
    lib/shell/ui.sh
    lib/shell/libvirt.sh
    lib/shell/privilege.sh
    lib/shell/status.sh
    lib/shell/boot.sh
    lib/shell/probes.sh
    lib/shell/network-effects.sh
    lib/shell/storage.sh
    lib/shell/config.sh
    lib/shell/waivers.sh
)

posicao_na_ordem() {
    local alvo="$1" i
    for i in "${!ORDEM[@]}"; do
        [ "${ORDEM[$i]}" = "$alvo" ] && { printf '%s\n' "$i"; return 0; }
    done
    return 1
}

# --- 1. A fachada carrega exatamente esta ordem ------------------------------

mapfile -t CARREGADOS < <(
    grep -oE 'source "\$COMMON_DIR/(shell/)?[a-z-]+\.sh"' "$ROOT/lib/common.sh" \
        | sed -e 's|source "\$COMMON_DIR/|lib/|' -e 's|"$||'
)
[ "${#CARREGADOS[@]}" -eq "${#ORDEM[@]}" ] \
    || fail "a fachada carrega ${#CARREGADOS[@]} módulos; esperado ${#ORDEM[@]}"
for i in "${!ORDEM[@]}"; do
    [ "${CARREGADOS[$i]}" = "${ORDEM[$i]}" ] \
        || fail "ordem divergente na posição $i: ${CARREGADOS[$i]} != ${ORDEM[$i]}"
done
passo

# --- 2. Todo pré-requisito declarado precede o módulo ------------------------
# A lista de dependências é lida do próprio módulo, então acrescentar um
# pré-requisito novo sem colocá-lo antes na fachada reprova automaticamente.

declare -A DEPS_DE=()
for modulo in "${ORDEM[@]}"; do
    deps=$(awk -F"' '" '/exige %s carregado antes/ {sub(/'"'"'.*/, "", $2); print $2}' \
        "$ROOT/$modulo" || true)
    DEPS_DE["$modulo"]="$deps"
    pos_modulo=$(posicao_na_ordem "$modulo") \
        || fail "$modulo não está na ordem documentada"
    for dep in $deps; do
        pos_dep=$(posicao_na_ordem "$dep") \
            || fail "$modulo declara dependência desconhecida: $dep"
        [ "$pos_dep" -lt "$pos_modulo" ] \
            || fail "ciclo ou inversão: $modulo exige $dep, que carrega depois"
    done
done
[ -n "${DEPS_DE[lib/shell/config.sh]}" ] \
    || fail 'config.sh deixou de declarar pré-requisitos'
passo

# --- 3. Cada pré-requisito é exigido individualmente -------------------------
# Carrega a ordem inteira até o módulo, remove APENAS a função que ele usa para
# provar aquela dependência e confirma que a recusa nomeia a dependência certa.
# Remover a função (em vez de omitir o arquivo) evita cascata: omitir a ponte
# derrubaria também probes.sh, e o diagnóstico observado seria o do vizinho.

carregar_sem_funcao() {
    local alvo="$1" funcao="$2" prefixo="" arquivo
    for arquivo in "${ORDEM[@]}"; do
        [ "$arquivo" = "$alvo" ] && break
        prefixo+="source '$ROOT/$arquivo'"$'\n'
    done
    "$BASH_BIN" -c "
        PROJETO_DIR='$ROOT'
        $prefixo
        unset -f '$funcao'
        source '$ROOT/$alvo'
    " 2>&1
}

PARES_TOTAL=0
for modulo in "${ORDEM[@]}"; do
    while IFS=$'\t' read -r funcao dep; do
        [ -n "$funcao" ] || continue
        PARES_TOTAL=$((PARES_TOTAL + 1))
        rc=0
        saida=$(carregar_sem_funcao "$modulo" "$funcao") || rc=$?
        [ "$rc" -eq 1 ] \
            || fail "$modulo sem $funcao devia recusar com código 1; veio $rc"
        [[ $saida == *"$modulo exige $dep carregado antes."* ]] \
            || fail "$modulo sem $funcao não nomeou $dep: $saida"
        passo
    done < <(awk '
        /^if ! declare -F [A-Za-z_]/ { funcao = $5; next }
        funcao != "" && /exige %s carregado antes/ {
            linha = $0
            sub(/.*'"'"' '"'"'/, "", linha)
            sub(/'"'"'.*/, "", linha)
            printf "%s\t%s\n", funcao, linha
            funcao = ""
        }
    ' "$ROOT/$modulo")
done
[ "$PARES_TOTAL" -ge 20 ] \
    || fail "só $PARES_TOTAL pré-requisitos nominais foram exercitados; esperado 20 ou mais"
passo

# --- 4. Na ordem certa, todo módulo publica sua API --------------------------

declare -A REPRESENTANTE=(
    [lib/shell/base.sh]=caminho_sistema
    [lib/platform.sh]=plataforma_carregar
    [lib/python-core.sh]=python_core_pares_payload
    [lib/shell/ui.sh]=falhar
    [lib/shell/libvirt.sh]=libvirt_backend_resolver
    [lib/shell/privilege.sh]=guard_mutation
    [lib/shell/status.sh]=v_fim
    [lib/shell/boot.sh]=detectar_bootloader
    [lib/shell/probes.sh]=coletar_snapshot_inventario
    [lib/shell/network-effects.sh]=validar_config_rede
    [lib/shell/storage.sh]=publicar_inventario_completo
    [lib/shell/config.sh]=carregar_conf
    [lib/shell/waivers.sh]=waiver_estado
)
prefixo=""
for arquivo in "${ORDEM[@]}"; do
    prefixo+="source '$ROOT/$arquivo'"$'\n'
done
faltando=$("$BASH_BIN" -c "
    PROJETO_DIR='$ROOT'
    $prefixo
    for f in ${REPRESENTANTE[*]}; do
        declare -F \"\$f\" > /dev/null 2>&1 || printf '%s\n' \"\$f\"
    done
") || fail 'a ordem documentada não carregou'
[ -z "$faltando" ] || fail "funções ausentes após carga ordenada: $faltando"
passo

# --- 5. base.sh carrega sozinho ----------------------------------------------
# É o único módulo sem pré-requisito; se ele passar a depender de alguém, o
# grafo perde a raiz e este caso reprova.

"$BASH_BIN" -c "source '$ROOT/lib/shell/base.sh'; declare -F caminho_sistema > /dev/null" \
    || fail 'lib/shell/base.sh deixou de ser carregável sozinho'
passo

# --- 6. Carregar não produz efeito -------------------------------------------
# PATH vazio + command_not_found_handle: qualquer comando externo invocado no
# source é registrado. A home falsa prova que nada foi escrito.

mkdir -p "$TMP/home" "$TMP/state"
: > "$TMP/comandos.txt"
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" "$BASH_BIN" -c '
    registro=$1
    raiz=$2
    command_not_found_handle() { printf "%s\n" "$1" >> "$registro"; return 127; }
    PATH=
    source "$raiz/lib/common.sh"
' _ "$TMP/comandos.txt" "$ROOT" > "$TMP/saida-source.txt" 2>&1 \
    || fail "carregar a fachada com PATH vazio falhou: $(cat "$TMP/saida-source.txt")"
[ ! -s "$TMP/comandos.txt" ] \
    || fail "o source chamou comando externo: $(tr '\n' ' ' < "$TMP/comandos.txt")"
[ ! -s "$TMP/saida-source.txt" ] \
    || fail "o source imprimiu algo: $(cat "$TMP/saida-source.txt")"
CRIADOS=$(find "$TMP/home" "$TMP/state" -mindepth 1 -print -quit)
[ -z "$CRIADOS" ] || fail "o source escreveu na home do operador: $CRIADOS"
passo

# --- 7. Source duplo é no-op -------------------------------------------------
# O estado publicado pelos módulos entre as duas cargas precisa sobreviver: se
# um módulo reexecutasse suas definições, o valor voltaria ao padrão.

ESTADO=$("$BASH_BIN" -c "
    source '$ROOT/lib/common.sh'
    antes=\$(declare -F | wc -l)
    V_FALHAS=7
    LOG_ACOES_ATIVO=1
    WAIVERS_MATRIZ_CARREGADA=1
    BOOTLOADER_ATIVO=grub
    source '$ROOT/lib/common.sh'
    depois=\$(declare -F | wc -l)
    printf '%s %s %s %s %s %s\n' \"\$V_FALHAS\" \"\$LOG_ACOES_ATIVO\" \
        \"\$WAIVERS_MATRIZ_CARREGADA\" \"\$BOOTLOADER_ATIVO\" \"\$antes\" \"\$depois\"
") || fail 'o segundo source da fachada falhou'
read -r v_falhas log_ativo waivers bootloader antes depois <<< "$ESTADO"
[ "$v_falhas" = 7 ] || fail "source duplo zerou V_FALHAS ($v_falhas)"
[ "$log_ativo" = 1 ] || fail "source duplo zerou LOG_ACOES_ATIVO ($log_ativo)"
[ "$waivers" = 1 ] || fail "source duplo recarregou a matriz de dispensas"
[ "$bootloader" = grub ] || fail "source duplo zerou BOOTLOADER_ATIVO ($bootloader)"
[ "$antes" = "$depois" ] || fail "o conjunto de funções mudou no segundo source"
passo

# --- 8. Módulo não carrega módulo, e a fachada não tem domínio ---------------

if grep -nE '^[[:space:]]*(source|\.)[[:space:]]' "$ROOT/lib/shell/"*.sh; then
    fail 'um módulo de lib/shell/ carrega outro por conta própria'
fi
FUNCOES_FACHADA=$(grep -cE '^[A-Za-z_][A-Za-z0-9_]*\(\) \{' "$ROOT/lib/common.sh")
[ "$FUNCOES_FACHADA" -le 1 ] \
    || fail "a fachada voltou a definir $FUNCOES_FACHADA funções; esperado no máximo 1"
LINHAS_FACHADA=$(wc -l < "$ROOT/lib/common.sh")
[ "$LINHAS_FACHADA" -le 150 ] \
    || fail "a fachada cresceu para $LINHAS_FACHADA linhas; ela agrega, não implementa"
for proibido in sudo virsh systemctl 'ip link' getfacl setfacl; do
    if grep -qF -- "$proibido" "$ROOT/lib/common.sh"; then
        fail "a fachada voltou a executar '$proibido'"
    fi
done
passo

printf 'OK: grafo de módulos de I9 (%d casos): ordem, pré-requisitos nominais, carga sem efeito, source duplo no-op e fachada sem domínio\n' \
    "$CASOS"
