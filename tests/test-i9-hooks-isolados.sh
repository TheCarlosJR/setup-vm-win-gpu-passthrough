#!/usr/bin/env bash
# Gate dirigido I9.5: os hooks libvirt são Bash puro e independentes.
#
# O que este teste protege:
#
#   * o hook não depende do checkout: ele é renderizado a partir de uma cópia
#     temporária do projeto, a cópia é APAGADA e só então os hooks rodam;
#   * o hook não conhece Python, core, configuração do repositório nem
#     `source` de arquivo externo: tudo o que ele precisa é literal dentro
#     dele;
#   * todo hook declara o próprio PATH absoluto antes de qualquer comando;
#   * sem ferramenta nenhuma (PATH vazio, ambiente vazio) nenhum hook declara
#     sucesso silencioso: cada um falha fechado com código e diagnóstico
#     nominais, e o filtro udev não dispara modprobe;
#   * nada é escrito fora do sandbox do teste.
#
# Hermético: nenhuma etapa muta o host; o único artefato executado é a cópia
# redirecionada dos hooks, com PATH e diretório de log dentro do TMP.
set -euo pipefail
RAIZ=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
export LC_ALL=C

fail() { printf 'FALHA I9.5: %s\n' "$*" >&2; exit 1; }
CASOS=0
passo() { CASOS=$((CASOS + 1)); }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/i9-hooks.XXXXXXXX")
trap 'rm -rf -- "$TMP"' EXIT HUP INT TERM

PROJETO="$TMP/projeto"
RENDER="$TMP/render"
EXEC="$TMP/exec"
VAZIO="$TMP/sem-comandos"
LOG_HOOKS="$TMP/log-hooks"
mkdir -p "$PROJETO/lib/shell" "$PROJETO/lib/policy" "$PROJETO/etapas" \
    "$RENDER" "$EXEC" "$VAZIO" "$LOG_HOOKS"

cp "$RAIZ/lib/common.sh" "$RAIZ/lib/platform.sh" "$RAIZ/lib/python-core.sh" "$PROJETO/lib/"
cp "$RAIZ/lib/shell/"*.sh "$PROJETO/lib/shell/"
cp "$RAIZ/lib/policy/waivers.tsv" "$PROJETO/lib/policy/waivers.tsv"
cp -a "$RAIZ/libexec" "$PROJETO/libexec"
cp "$RAIZ/etapas/50-hooks-gpu-hd1.sh" "$PROJETO/etapas/50-hooks-gpu-hd1.sh"
cat > "$PROJETO/passthrough.conf" <<'CONF'
VM_NAME="fixture"
GPU_PCI_ID="0000:01:00.0"
GPU_AUDIO_PCI_ID=""
GPU_VENDOR_DEVICE_ID="10de:2503"
GPU_AUDIO_VENDOR_DEVICE_ID=""
DM_SERVICE="display-manager"
IOMMU_GROUP_GPU="7"
HD1_BY_ID_PATH=""
HD1_DISPENSADO="sim"
CONF
chmod 0600 "$PROJETO/passthrough.conf"

# --- 1. Renderização e independência do checkout ----------------------------

bash "$PROJETO/etapas/50-hooks-gpu-hd1.sh" --renderizar-hooks "$RENDER" > "$TMP/render.log" 2>&1 \
    || fail "a renderização dos hooks falhou: $(tail -3 "$TMP/render.log")"
cp -a "$RENDER/." "$EXEC/"
# A partir daqui o projeto que gerou os hooks não existe mais: se algum hook
# precisasse do repositório, ele quebraria nos casos de execução abaixo.
rm -rf -- "$PROJETO"
[ ! -d "$PROJETO" ] || fail 'a cópia do projeto não foi removida'
passo

mapfile -t HOOKS < <(cd -- "$EXEC" && find . -maxdepth 1 -type f -perm -u+x -printf '%f\n' | LC_ALL=C sort)
[ "${#HOOKS[@]}" -ge 5 ] \
    || fail "esperava pelo menos 5 hooks executáveis; vieram ${#HOOKS[@]}"

# --- 2. bash -n em todo artefato executável ---------------------------------

for hook in "${HOOKS[@]}"; do
    bash -n "$EXEC/$hook" || fail "$hook não passou em bash -n"
done
passo

# --- 3. Pureza: nenhum vínculo com o repositório ou com o core --------------

for hook in "${HOOKS[@]}"; do
    if grep -nE 'common\.sh|lib/shell|python|passthrough_core|libexec|PROJETO_DIR|passthrough\.conf' \
        "$EXEC/$hook"; then
        fail "$hook depende do repositório ou do core"
    fi
    if grep -nE '^[[:space:]]*(source|\.)[[:space:]]+' "$EXEC/$hook"; then
        fail "$hook carrega arquivo externo em vez de ser autossuficiente"
    fi
    grep -qE '^PATH=(/[A-Za-z0-9._-]+:?)+$' "$EXEC/$hook" \
        || fail "$hook não declara PATH absoluto próprio"
    grep -qE '^PATH=[^/]' "$EXEC/$hook" \
        && fail "$hook declara PATH relativo"
done
passo

# --- 4. Sem ferramenta nenhuma, ninguém declara sucesso silencioso ----------
# PATH e diretório de log são redirecionados para o sandbox: o hook roda de
# verdade, mas não alcança binário nem /var/log do host.

for hook in "${HOOKS[@]}"; do
    sed -i \
        -e "s|^PATH=.*|PATH=$VAZIO|" \
        -e "s|^HOOK_LOG_DIR=.*|HOOK_LOG_DIR=$LOG_HOOKS|" \
        "$EXEC/$hook"
    bash -n "$EXEC/$hook" || fail "$hook ficou inválido após o redirecionamento"
done

executar_isolado() {
    local hook="$1" rc=0
    shift
    ISOLADO_SAIDA=$(cd -- "$TMP" && timeout 30 env -i "$BASH" "$EXEC/$hook" "$@" 2>&1) || rc=$?
    ISOLADO_RC=$rc
}

executar_isolado qemu
[ "$ISOLADO_RC" -eq 64 ] \
    || fail "dispatcher sem argumentos devia sair 64; veio $ISOLADO_RC"
[[ $ISOLADO_SAIDA == *'argumentos insuficientes'* ]] \
    || fail "dispatcher sem argumentos não diagnosticou: $ISOLADO_SAIDA"
passo

executar_isolado installing.sh
[ "$ISOLADO_RC" -eq 75 ] \
    || fail "hook de instalação devia bloquear o evento com 75; veio $ISOLADO_RC"
[[ $ISOLADO_SAIDA == *'evento bloqueado'* ]] \
    || fail "hook de instalação não diagnosticou o bloqueio: $ISOLADO_SAIDA"
passo

executar_isolado start.sh
[ "$ISOLADO_RC" -ne 0 ] \
    || fail 'hook start declarou sucesso sem nenhuma evidência de detach'
[[ $ISOLADO_SAIDA == *'[hook start]'* ]] \
    || fail "hook start falhou sem diagnóstico próprio: $ISOLADO_SAIDA"
passo

for hook in prepare.sh release.sh; do
    executar_isolado "$hook"
    [ "$ISOLADO_RC" -ne 0 ] \
        || fail "$hook declarou sucesso sem nenhuma ferramenta disponível"
    passo
done

# --- 4b. O release não abandona GPU e display por estado não entendido ------
# Até 03/09/2026 uma chave desconhecida no arquivo de estado fazia `exit 1`
# ANTES de qualquer restauração: a GPU não voltava ao host e o display manager
# não subia, e o operador ficava com tela preta porque a limpeza anterior não
# foi ENTENDIDA. O contrato de REQ-VM-RESOURCE-LIFECYCLE proíbe isso em letra,
# e I9.12 vai acrescentar chaves neste mesmo arquivo — um hook antigo lendo
# estado novo cairia exatamente aqui.
#
# A verificação é ESTÁTICA, e a limitação é declarada: rodar o release de
# verdade exigiria root, porque antes de chegar ao estado ele cria o diretório
# de lock com dono root e RECUSA lock que não seja seguro. Simular tudo isso
# sem privilégio produziria um teste que passa por causa dos mocks, não por
# causa do hook. O que dá para provar sem root, e é o que importa aqui, é que
# entre a leitura do estado e a restauração não sobrou nenhuma saída fatal.
RELEASE_FONTE="$EXEC/release.sh"
LINHA_ESTADO=$(grep -n 'done < "\$STATE_FILE"' "$RELEASE_FONTE" | head -1 | cut -d: -f1)
[ -n "$LINHA_ESTADO" ] \
    || fail 'não encontrei a leitura do arquivo de estado no hook release'
LINHA_RESTAURA=$(awk -v ini="$LINHA_ESTADO" 'NR > ini && /modprobe "\$modulo"/ { print NR; exit }' \
    "$RELEASE_FONTE")
[ -n "$LINHA_RESTAURA" ] \
    || fail 'não encontrei o laço de modprobe que restaura a GPU no hook release'
JANELA=$(sed -n "${LINHA_ESTADO},${LINHA_RESTAURA}p" "$RELEASE_FONTE")
if printf '%s\n' "$JANELA" | grep -qE '(^|[^_[:alnum:]])exit[[:space:]]+[1-9]'; then
    printf '%s\n' "$JANELA" | grep -nE '(^|[^_[:alnum:]])exit[[:space:]]+[1-9]' >&2
    fail 'o release voltou a abandonar GPU/display entre ler o estado e restaurar'
fi
passo

# E a chave desconhecida precisa CONTAR como falha, não passar batida: sem
# isto, tolerar viraria ignorar, e o hook sairia 0 com estado que ele não
# entendeu.
ARM_DESCONHECIDA=$(awk -v ini="$LINHA_ESTADO" '
    NR < ini && /chave de estado desconhecida/ { achou = NR }
    END { print achou }' "$RELEASE_FONTE")
[ -n "$ARM_DESCONHECIDA" ] \
    || fail 'o release deixou de relatar chave de estado desconhecida'
CONTEXTO=$(sed -n "${ARM_DESCONHECIDA},$((ARM_DESCONHECIDA + 2))p" "$RELEASE_FONTE")
printf '%s\n' "$CONTEXTO" | grep -q 'FALHAS=' \
    || fail 'chave desconhecida não incrementa o contador de falhas do release'
passo

# O filtro udev decide NÃO agir quando a ação não é dele; agir seria
# justamente o laço que ele existe para cortar.
executar_isolado nvidia-udev-filtro.sh evento-desconhecido nvidia-drm
[ "$ISOLADO_RC" -eq 0 ] \
    || fail "filtro udev devia ignorar ação desconhecida; veio $ISOLADO_RC"
[ -z "$ISOLADO_SAIDA" ] \
    || fail "filtro udev falou ao ignorar ação desconhecida: $ISOLADO_SAIDA"
passo

# --- 5. Nada foi escrito fora do sandbox ------------------------------------

FORA=$(find "$TMP" -maxdepth 1 -mindepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')
[ "$FORA" = 'exec log-hooks render render.log sem-comandos ' ] \
    || fail "o sandbox ganhou artefato inesperado: $FORA"
[ -z "$(find "$VAZIO" -mindepth 1 -print -quit)" ] \
    || fail 'algum hook escreveu no diretório que simula PATH vazio'

printf 'OK: hooks libvirt independentes de I9 (%d casos): render sem checkout, %d hooks puros, PATH próprio, fail-closed sem ferramentas\n' \
    "$CASOS" "${#HOOKS[@]}"
