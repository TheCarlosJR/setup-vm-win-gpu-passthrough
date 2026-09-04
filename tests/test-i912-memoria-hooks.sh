#!/usr/bin/env bash
# Gate dirigido I9.12 (REQ-VM-RESOURCE-LIFECYCLE): o ciclo de vida da memória
# DENTRO dos hooks gerados, provado contra um sysfs simulado.
#
# O que esta suíte protege, e por quê:
#
#   * o requisito nasceu de 22 GiB de HugePages de 1 GiB retirados da RAM comum
#     com a VM DESLIGADA. A metade executora do conserto é `mem_adquirir` no
#     prepare e `mem_devolver` no release, e as duas escrevem em
#     `nr_hugepages`. Um defeito aqui não devolve memória de menos: ele ZERA
#     pool de terceiro, ou arranca página de uma VM viva. É por isso que cada
#     caso afirma os QUATRO contadores do pool, e não só o código de retorno.
#   * a devolução só pode tirar do pool o delta que a operação adquiriu.
#     `DELTA=0` (pool preexistente já cobria a necessidade) tem de deixar o
#     pool intacto: escrever "para garantir" é exatamente o desastre.
#   * estado de OUTRO boot é reconciliado SEM tocar no pool. O reboot já
#     limpou; reduzir `nr_hugepages` agora seria roubar do boot atual.
#   * `mem_devolver` NUNCA aborta. O release restaura GPU, display e CPU
#     depois dela, e o requisito proíbe abandonar o desktop porque a memória
#     não voltou. Cada cenário de falha prova que o processo chega vivo à
#     linha seguinte.
#   * o hook faz a aritmética em Bash puro porque roda com o projeto apagado
#     (decisão I9-D8, provada por tests/test-i9-hooks-isolados.sh).
#     `libexec/passthrough_core/resources.py` decide o mesmo em Python. Que as
#     duas concordem é obrigação de teste, não de fé: a seção F é o oráculo
#     diferencial, e toda divergência é DECLARADA nos dois sentidos —
#     divergência não declarada reprova, e divergência declarada que sumiu
#     também.
#
# ---------------------------------------------------------------------------
# MECÂNICA DA SIMULAÇÃO (sem root, sem tocar o host)
#
# 1. Os hooks são renderizados a partir de uma cópia temporária do projeto,
#    como em tests/test-i9-hooks-isolados.sh. Do artefato renderizado é
#    recortado o FRAGMENTO que vai do cabeçalho até o fim de `mem_devolver`;
#    tudo o que vem depois (lock em /run, systemctl, modprobe, PCI) fica de
#    fora. O fragmento é o código de produção, não uma cópia mantida à mão.
#
# 2. `sed` reescreve as âncoras para dentro do sandbox: `MEM_STATE_DIR`,
#    `HOOK_LOG_DIR`, o prefixo `/sys/kernel/mm/hugepages/hugepages-` (que
#    aparece DUAS vezes: em `MEM_POOL_DIR` e na reconstrução do pool dentro de
#    `mem_devolver`) e `/proc/sys/kernel/random/boot_id`. As três linhas de
#    configuração assadas na renderização (`MEMORIA_MODO`, `MEM_PAGE_KB`,
#    `MEM_PAGES_NEEDED`) são REMOVIDAS para que cada caso as forneça pelo
#    ambiente; as derivações (`MEM_POOL_DIR`, `MEM_STATE_FILE`) continuam
#    sendo as do hook. Uma guarda ABORTA a suíte se sobrar `/sys`, `/var/lib`,
#    `/var/log` ou `/proc/sys` no fragmento: um teste de memória que escreva
#    no sysfs real do host seria desastre.
#
# 3. O "kernel" é uma função `printf` definida no runner DEPOIS do `source` do
#    fragmento. Ela intercepta exclusivamente a escrita cujo stdout É o
#    `nr_hugepages` do pool simulado — a comparação é por inode
#    (`[ /proc/self/fd/1 -ef "$KERNEL_NR" ]`), então pipe, terminal e o
#    arquivo de estado passam direto para `builtin printf`. Interceptada a
#    escrita, o modelo do kernel:
#       - concede `min(pedido, KERNEL_TETO)` e nunca menos que `KERNEL_PISO`
#         (é assim que "alocação parcial" e "não consigo devolver" viram
#         cenário determinístico, sem corrida e sem FUSE);
#       - move `free_hugepages` junto com `nr_hugepages`, como um kernel faz
#         com páginas livres, salvo em `KERNEL_LIVRE=congelado`, que simula
#         página adquirida que NÃO fica livre;
#       - com `KERNEL_ESCRITA=erro` devolve 1 e repõe o valor anterior, porque
#         o shell já truncou o arquivo antes de o comando rodar;
#       - registra cada escrita em `KERNEL_ESCRITAS`, o que permite afirmar
#         "o pool não foi escrito NENHUMA vez", que é mais forte do que "o
#         valor final é igual".
#    É o "wrapper que grava menos do que foi pedido": o kernel é o teste.
#
# 4. `install -d -o root -g root` é a única coisa que exige privilégio no
#    caminho de memória. O runner define uma função `install` que descarta
#    `-o`/`-g` e delega no binário real. É um shim de PRIVILÉGIO, não de
#    comportamento: modo, atomicidade por rename e o resto continuam sendo os
#    do hook.
#
# Hermético: nada é escrito fora do TMP, nenhum `sudo`, e os contadores reais
# de /sys/kernel/mm/hugepages são fotografados no início e conferidos no fim.
set -euo pipefail
RAIZ=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
export LC_ALL=C

fail() { printf 'FALHA I9.12: %s\n' "$*" >&2; exit 1; }
CASOS=0
passo() { CASOS=$((CASOS + 1)); }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/i912-mem.XXXXXXXX")
trap 'rm -rf -- "$TMP"' EXIT HUP INT TERM

# O caminho do sandbox entra no fragmento por `sed` e em `[ -r CAMINHO ]` sem
# aspas (é assim que o hook lê o boot_id). Espaço, `|` ou `&` quebrariam a
# reescrita ou o teste; recusar cedo é melhor do que falhar por motivo errado.
case "$TMP" in
    *[[:space:]]*|*'|'*|*'&'*|*'\'*)
        fail "TMPDIR impróprio para esta suíte (espaço ou metacaractere): $TMP" ;;
esac

VM_TESTE=fixture
BOOT_ATUAL='11111111-2222-3333-4444-555555555555'
BOOT_OUTRO='99999999-8888-7777-6666-000000000000'

PROJETO="$TMP/projeto"
RENDER="$TMP/render"
SIM="$TMP/sys"
ESTADO_DIR="$TMP/estado"
LOG_DIR="$TMP/log"
BOOT_FILE="$TMP/boot_id"
SOMBRA="$TMP/kernel-sombra"
ESCRITAS="$TMP/kernel-escritas"
RUNNER="$TMP/runner.sh"
ORACULO_DIR="$TMP/oraculo"
ORACULO="$ORACULO_DIR/oraculo.py"
mkdir -p "$PROJETO/lib/shell" "$PROJETO/lib/policy" "$PROJETO/etapas" \
    "$RENDER" "$SIM" "$ESTADO_DIR" "$LOG_DIR" "$ORACULO_DIR"

# --- 0. Fotografia do host: o pool REAL não pode mudar por causa do teste ----

hugepages_host() {
    local dir campo
    [ -d /sys/kernel/mm/hugepages ] || { printf 'sem-hugetlb\n'; return 0; }
    for dir in /sys/kernel/mm/hugepages/*/; do
        [ -d "$dir" ] || continue
        for campo in nr_hugepages free_hugepages resv_hugepages surplus_hugepages; do
            if [ -r "$dir$campo" ]; then
                printf '%s=%s\n' "$dir$campo" "$(cat -- "$dir$campo")"
            fi
        done
    done
}
HOST_ANTES=$(hugepages_host)
HOST_ESTADO_ANTES=$([ -e /var/lib/vm-passthrough ] && echo existe || echo ausente)

# --- 1. Renderização a partir de uma cópia do projeto -----------------------

cp "$RAIZ/lib/common.sh" "$RAIZ/lib/platform.sh" "$RAIZ/lib/python-core.sh" "$PROJETO/lib/"
cp "$RAIZ/lib/shell/"*.sh "$PROJETO/lib/shell/"
cp "$RAIZ/lib/policy/waivers.tsv" "$PROJETO/lib/policy/waivers.tsv"
cp -a "$RAIZ/libexec" "$PROJETO/libexec"
cp "$RAIZ/etapas/50-hooks-gpu-hd1.sh" "$PROJETO/etapas/50-hooks-gpu-hd1.sh"
cat > "$PROJETO/passthrough.conf" <<CONF
VM_NAME="$VM_TESTE"
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

bash "$PROJETO/etapas/50-hooks-gpu-hd1.sh" --renderizar-hooks "$RENDER" > "$TMP/render.log" 2>&1 \
    || fail "a renderização dos hooks falhou: $(tail -3 "$TMP/render.log")"
[ -f "$RENDER/prepare.sh" ] && [ -f "$RENDER/release.sh" ] \
    || fail 'a renderização não produziu prepare.sh e release.sh'
passo

# --- 2. As duas metades saem da mesma fonte ---------------------------------
# prepare adquire e release devolve. Se os dois blocos divergirem, uma metade
# passa a escrever no pool com aritmética que a outra não conhece — e é a
# devolução que erra, sempre em cima de memória já entregue ao host.

recortar_fragmento() {
    # Do começo do hook até o fim de mem_devolver. O que vem depois abre lock
    # em /run e fala com systemd; nada disso entra no sandbox.
    awk '/^STATE_DIR=|^STATE_FILE=/{exit} {print}' "$1"
}
bloco_de_memoria() { awk '/^MEM_STATE_DIR=/{dentro=1} dentro{print}' "$1"; }

recortar_fragmento "$RENDER/prepare.sh" > "$TMP/frag-prepare.sh"
recortar_fragmento "$RENDER/release.sh" > "$TMP/frag-release.sh"
for frag in "$TMP/frag-prepare.sh" "$TMP/frag-release.sh"; do
    grep -q '^mem_devolver() {' "$frag" \
        || fail "o recorte de $frag não alcançou mem_devolver"
    grep -q '^mem_adquirir() {' "$frag" \
        || fail "o recorte de $frag não alcançou mem_adquirir"
    [ "$(tail -1 "$frag")" = '}' ] \
        || fail "o recorte de $frag não terminou no fim de uma função"
done
bloco_de_memoria "$TMP/frag-prepare.sh" > "$TMP/bloco-prepare"
bloco_de_memoria "$TMP/frag-release.sh" > "$TMP/bloco-release"
cmp -s "$TMP/bloco-prepare" "$TMP/bloco-release" \
    || fail 'o bloco de memória do prepare e o do release divergem; as duas metades deixaram de sair da mesma fonte'
CFG_PREPARE=$(grep -E '^(MEMORIA_MODO|MEM_PAGE_KB|MEM_PAGES_NEEDED)=' "$RENDER/prepare.sh")
CFG_RELEASE=$(grep -E '^(MEMORIA_MODO|MEM_PAGE_KB|MEM_PAGES_NEEDED)=' "$RENDER/release.sh")
[ "$CFG_PREPARE" = "$CFG_RELEASE" ] \
    || fail "prepare e release foram renderizados com política de memória diferente:\n$CFG_PREPARE\n---\n$CFG_RELEASE"
[ "$(printf '%s\n' "$CFG_PREPARE" | wc -l)" -eq 3 ] \
    || fail 'a renderização deixou de assar as três chaves de política de memória nos hooks'
passo

# Os pontos de chamada, que dão sentido ao resto: o prepare ABORTA o start se a
# aquisição falhar, e o release CONTA a falha da devolução em vez de morrer.
grep -qE '^mem_adquirir \|\| falha ' "$RENDER/prepare.sh" \
    || fail 'o prepare deixou de abortar o start quando a aquisição de memória falha'
grep -qE '^mem_devolver \|\| FALHAS=' "$RENDER/release.sh" \
    || fail 'o release deixou de chamar mem_devolver em contexto que tolera a falha'
LINHA_DEV=$(grep -n '^mem_devolver || FALHAS=' "$RENDER/release.sh" | head -1 | cut -d: -f1)
LINHA_MODPROBE=$(awk -v ini="$LINHA_DEV" 'NR > ini && /modprobe "\$modulo"/ { print NR; exit }' "$RENDER/release.sh")
[ -n "$LINHA_MODPROBE" ] \
    || fail 'a devolução de memória passou a acontecer DEPOIS da restauração da GPU; a ordem do release mudou sem prova'
passo

# --- 3. Reescrita para o sandbox, com guarda que aborta ---------------------

for frag in "$TMP/frag-prepare.sh" "$TMP/frag-release.sh"; do
    sed -i \
        -e "s|^MEM_STATE_DIR=.*|MEM_STATE_DIR=$ESTADO_DIR|" \
        -e "s|^HOOK_LOG_DIR=.*|HOOK_LOG_DIR=$LOG_DIR|" \
        -e "s|/sys/kernel/mm/hugepages/hugepages-|$SIM/hugepages-|g" \
        -e "s|/proc/sys/kernel/random/boot_id|$BOOT_FILE|g" \
        -e '/^MEMORIA_MODO=/d' -e '/^MEM_PAGE_KB=/d' -e '/^MEM_PAGES_NEEDED=/d' \
        "$frag"
    bash -n "$frag" || fail "$frag ficou inválido depois da reescrita"

    # A GUARDA. Se qualquer âncora de produção sobreviveu ao sed, o caso
    # seguinte escreveria no sysfs REAL do host. Abortar aqui é obrigatório.
    if grep -nE '(^|[^-[:alnum:]_])/(sys|proc)/|/var/lib/|/var/log/' "$frag" >&2; then
        fail "o fragmento ainda aponta para caminho do host; a suíte NÃO pode rodar"
    fi
    grep -q "^MEM_STATE_DIR=$ESTADO_DIR\$" "$frag" \
        || fail "MEM_STATE_DIR não foi redirecionado em $frag"
    grep -q "MEM_POOL_DIR=\"$SIM/hugepages-\${MEM_PAGE_KB}kB\"" "$frag" \
        || fail "MEM_POOL_DIR não foi redirecionado em $frag"
    grep -q "pool=\"$SIM/hugepages-\${page_kb}kB\"" "$frag" \
        || fail "o pool reconstruído dentro de mem_devolver não foi redirecionado em $frag"
    if grep -qE '^MEMORIA_MODO=|^MEM_PAGE_KB=|^MEM_PAGES_NEEDED=' "$frag"; then
        fail "a configuração assada continua em $frag; o caso não controlaria a política"
    fi
done
FRAG_PREPARE="$TMP/frag-prepare.sh"
FRAG_RELEASE="$TMP/frag-release.sh"
passo

# --- 4. O runner: shims de privilégio e o kernel simulado -------------------

cat > "$RUNNER" <<'RUNNER_EOF'
#!/bin/bash
# Executa funções de memória do hook num sandbox. Argumento 1: o fragmento.
# Demais argumentos: funções a chamar, na ordem.
set -Eeuo pipefail
FRAGMENTO="$1"; shift
# shellcheck source=/dev/null
source "$FRAGMENTO"

# Shim de PRIVILÉGIO: `install -d -o root -g root -m 0700` é a única coisa do
# caminho de memória que exige root. O modo e a criação continuam reais.
install() {
    local args=() pular=0 a
    for a in "$@"; do
        if [ "$pular" = 1 ]; then pular=0; continue; fi
        case "$a" in
            -o|-g) pular=1 ;;
            *) args+=("$a") ;;
        esac
    done
    command install "${args[@]}"
}

# O KERNEL SIMULADO. Só intercepta a escrita cujo stdout é, por inode, o
# nr_hugepages do pool falso; qualquer outro destino passa direto.
printf() {
    local pedido antigo concedido livre
    if [ ! /proc/self/fd/1 -ef "$KERNEL_NR" ]; then
        builtin printf "$@"
        return
    fi
    pedido="${*: -1}"
    IFS= read -r antigo < "$KERNEL_SOMBRA"
    builtin printf '%s->%s\n' "$antigo" "$pedido" >> "$KERNEL_ESCRITAS"
    if [ "$KERNEL_ESCRITA" = erro ]; then
        # O shell já truncou o arquivo antes de chamar o comando; repor o valor
        # anterior é o que torna "a escrita falhou" observável como no sysfs.
        builtin printf '%s\n' "$antigo"
        return 1
    fi
    concedido="$pedido"
    [ "$concedido" -le "$KERNEL_TETO" ] || concedido="$KERNEL_TETO"
    [ "$concedido" -ge "$KERNEL_PISO" ] || concedido="$KERNEL_PISO"
    builtin printf '%s\n' "$concedido"
    if [ "$KERNEL_LIVRE" = segue ]; then
        IFS= read -r livre < "$KERNEL_FREE"
        livre=$(( livre + concedido - antigo ))
        [ "$livre" -ge 0 ] || livre=0
        builtin printf '%s\n' "$livre" > "$KERNEL_FREE"
    fi
    builtin printf '%s\n' "$concedido" > "$KERNEL_SOMBRA"
    return 0
}

# Emula o que vem DEPOIS da devolução no release de verdade. Se ela abortar o
# processo, esta linha não sai, e o operador fica sem desktop.
marca_restauracao() { builtin printf 'RESTAUROU_GPU_E_DISPLAY\n'; }

for fn in "$@"; do
    rc=0
    "$fn" || rc=$?
    builtin printf 'RC:%s=%s\n' "$fn" "$rc"
done
builtin printf 'VIVO\n'
RUNNER_EOF
bash -n "$RUNNER" || fail 'o runner do sandbox não passou em bash -n'
passo

# --- 5. Helpers de cenário --------------------------------------------------

CASO_MODO=hugetlb-2m
CASO_PAGE_KB=2048
CASO_PAGES=0
K_TETO=999999999
K_PISO=0
K_ESCRITA=ok
K_LIVRE=segue
POOL_ATUAL=""
SAIDA=""

caso_padrao() {
    CASO_MODO=hugetlb-2m
    CASO_PAGE_KB=2048
    CASO_PAGES=0
    K_TETO=999999999
    K_PISO=0
    K_ESCRITA=ok
    K_LIVRE=segue
    rm -rf -- "$SIM" "$ESTADO_DIR"
    mkdir -p "$SIM"
    printf '%s\n' "$BOOT_ATUAL" > "$BOOT_FILE"
    : > "$ESCRITAS"
    printf '0\n' > "$SOMBRA"
    POOL_ATUAL=""
}

pool_montar() { # pool_montar KB NR FREE RESV SURPLUS
    local dir="$SIM/hugepages-${1}kB"
    mkdir -p -- "$dir"
    printf '%s\n' "$2" > "$dir/nr_hugepages"
    printf '%s\n' "$3" > "$dir/free_hugepages"
    printf '%s\n' "$4" > "$dir/resv_hugepages"
    printf '%s\n' "$5" > "$dir/surplus_hugepages"
    printf '%s\n' "$2" > "$SOMBRA"
    : > "$ESCRITAS"
    POOL_ATUAL="$dir"
}

pool_conta() { # imprime "nr free resv surplus"
    local campo saida=""
    for campo in nr free resv surplus; do
        saida="$saida $(cat -- "$POOL_ATUAL/${campo}_hugepages")"
    done
    printf '%s\n' "${saida# }"
}

estado_arquivo() { printf '%s\n' "$ESTADO_DIR/${VM_TESTE}.memoria"; }

estado_escrever() { # conteúdo vem do stdin
    mkdir -p -- "$ESTADO_DIR"
    cat > "$(estado_arquivo)"
    chmod 0600 "$(estado_arquivo)"
    # Cópia para provar preservação byte a byte quando a devolução recusa.
    cp -- "$(estado_arquivo)" "$TMP/estado-como-escrito"
}

estado_completo() { # estado_completo DELTA BASE_NR BASE_FREE [BOOT] [PAGE_KB]
    estado_escrever <<EOF
ESTADO=VERIFIED
BOOT_ID=${4:-$BOOT_ATUAL}
MODO=hugetlb-2m
PAGE_KB=${5:-2048}
DELTA=$1
BASE_NR=$2
BASE_FREE=$3
BASE_RESV=0
BASE_SURPLUS=0
EOF
}

rodar() { # rodar FRAGMENTO FUNÇÃO...
    local fragmento="$1"; shift
    SAIDA=$(env -i \
        PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/nonexistent LC_ALL=C \
        MEMORIA_MODO="$CASO_MODO" \
        MEM_PAGE_KB="$CASO_PAGE_KB" \
        MEM_PAGES_NEEDED="$CASO_PAGES" \
        KERNEL_NR="$SIM/hugepages-${CASO_PAGE_KB}kB/nr_hugepages" \
        KERNEL_FREE="$SIM/hugepages-${CASO_PAGE_KB}kB/free_hugepages" \
        KERNEL_SOMBRA="$SOMBRA" \
        KERNEL_ESCRITAS="$ESCRITAS" \
        KERNEL_TETO="$K_TETO" \
        KERNEL_PISO="$K_PISO" \
        KERNEL_ESCRITA="$K_ESCRITA" \
        KERNEL_LIVRE="$K_LIVRE" \
        timeout 60 "$BASH" "$RUNNER" "$fragmento" "$@" 2>&1) || true
    # A promessa da seção E, cobrada em TODO caso: o processo chega vivo ao
    # fim. Um `exit` dentro das funções de memória mataria o release inteiro.
    [[ $SAIDA == *VIVO* ]] \
        || fail "o processo não sobreviveu à execução de $*: $SAIDA"
}

exige_rc() { # exige_rc FUNÇÃO CÓDIGO CONTEXTO
    local obtido
    obtido=$(printf '%s\n' "$SAIDA" | sed -n "s/^RC:$1=//p" | head -1)
    [ "$obtido" = "$2" ] \
        || fail "$3: $1 devia sair $2 e saiu '${obtido:-nenhum}'. Saída: $SAIDA"
}
exige_texto() {
    [[ $SAIDA == *"$1"* ]] || fail "$2: diagnóstico esperado ausente ('$1'). Saída: $SAIDA"
}
exige_pool() { # exige_pool "nr free resv surplus" CONTEXTO
    local obtido
    obtido=$(pool_conta)
    [ "$obtido" = "$1" ] \
        || fail "$2: pool devia ser '$1' e é '$obtido'"
}
exige_sem_escrita() {
    [ ! -s "$ESCRITAS" ] \
        || fail "$1: o pool foi escrito quando não devia ter sido ($(tr '\n' ' ' < "$ESCRITAS"))"
}
exige_escritas() {
    local obtido
    obtido=$(tr '\n' ' ' < "$ESCRITAS")
    [ "${obtido% }" = "$1" ] \
        || fail "$2: escritas no pool deviam ser '$1' e foram '${obtido% }'"
}
exige_estado_ausente() {
    [ ! -e "$(estado_arquivo)" ] \
        || fail "$1: o estado devia ter sido removido e ainda existe: $(cat -- "$(estado_arquivo)" | tr '\n' ' ')"
}
exige_estado_campo() { # exige_estado_campo CHAVE VALOR CONTEXTO
    local obtido
    [ -e "$(estado_arquivo)" ] || fail "$3: o estado devia existir e não existe"
    obtido=$(sed -n "s/^$1=//p" "$(estado_arquivo)" | head -1)
    [ "$obtido" = "$2" ] \
        || fail "$3: $1 no estado devia ser '$2' e é '${obtido:-vazio}'"
}
exige_estado_intacto() {
    [ -e "$(estado_arquivo)" ] || fail "$1: o estado devia ter sido PRESERVADO e sumiu"
    cmp -s "$(estado_arquivo)" "$TMP/estado-como-escrito" \
        || fail "$1: o estado foi reescrito quando devia ter sido preservado byte a byte"
}
recusa_texto() { # recusa_texto TRECHO CONTEXTO
    [[ $SAIDA != *"$1"* ]] \
        || fail "$2: a saída trouxe '$1', que não devia mais aparecer. Saída: $SAIDA"
}
exige_modo_estado() {
    local modo
    modo=$(stat -c %a -- "$(estado_arquivo)")
    [ "$modo" = 600 ] || fail "$1: o estado devia estar em 0600 e está em $modo"
}

# ===========================================================================
# A. Aquisição (mem_adquirir)
# ===========================================================================

# A1 e A2: modo que não é de runtime não toca no pool. `normal` é o BASELINE do
# requisito (a VM usa memória comum e o kernel devolve tudo quando o QEMU sai);
# modo vazio é o que um hook antigo, ou uma configuração incompleta, produz.
for modo in normal ''; do
    caso_padrao
    CASO_MODO="$modo"
    CASO_PAGES=4096
    pool_montar 2048 100 100 0 0
    rodar "$FRAG_PREPARE" mem_adquirir
    exige_rc mem_adquirir 0 "A1 modo '${modo:-vazio}'"
    exige_texto 'o ciclo de vida não toca no pool' "A1 modo '${modo:-vazio}'"
    exige_pool '100 100 0 0' "A1 modo '${modo:-vazio}'"
    exige_sem_escrita "A1 modo '${modo:-vazio}'"
    exige_estado_ausente "A1 modo '${modo:-vazio}'"
    passo
done

# A3: o host não expõe pool do tamanho pedido. Aceitar aqui deixaria a VM subir
# sem as páginas que o perfil promete.
caso_padrao
CASO_MODO=hugetlb-1g
CASO_PAGE_KB=1048576
CASO_PAGES=22
pool_montar 2048 0 0 0 0
rodar "$FRAG_PREPARE" mem_adquirir
exige_rc mem_adquirir 1 'A3 pool ausente'
exige_texto 'o host não expõe pool de 1048576 kB' 'A3 pool ausente'
exige_estado_ausente 'A3 pool ausente'
passo

# A4: consumidor externo (nr != free). Na devolução não haveria como distinguir
# a nossa página da dele.
caso_padrao
CASO_PAGES=4096
pool_montar 2048 100 98 0 0
rodar "$FRAG_PREPARE" mem_adquirir
exige_rc mem_adquirir 1 'A4 consumidor externo'
exige_texto '2 página(s) em uso por outro consumidor' 'A4 consumidor externo'
exige_pool '100 98 0 0' 'A4 consumidor externo'
exige_sem_escrita 'A4 consumidor externo'
exige_estado_ausente 'A4 consumidor externo'
passo

# A5: resv > 0.
caso_padrao
CASO_PAGES=4096
pool_montar 2048 100 100 3 0
rodar "$FRAG_PREPARE" mem_adquirir
exige_rc mem_adquirir 1 'A5 resv de terceiro'
exige_texto '3 página(s) reservada(s) por outro consumidor' 'A5 resv de terceiro'
exige_pool '100 100 3 0' 'A5 resv de terceiro'
exige_sem_escrita 'A5 resv de terceiro'
passo

# A6: surplus > 0. Com overcommit em jogo, `nr` deixa de descrever o que a
# operação adquiriu e a exatidão da devolução fica indemonstrável.
caso_padrao
CASO_PAGES=4096
pool_montar 2048 100 100 0 5
rodar "$FRAG_PREPARE" mem_adquirir
exige_rc mem_adquirir 1 'A6 surplus'
exige_texto '5 página(s) de surplus' 'A6 surplus'
exige_pool '100 100 0 5' 'A6 surplus'
exige_sem_escrita 'A6 surplus'
passo

# A7: pool preexistente JÁ cobre a necessidade. É o caso do host medido em
# 03/09/2026 (22 páginas de 1 GiB vindas do boot). O estado tem de nascer com
# DELTA=0 e o pool não pode ser escrito: delta zero é a promessa de que a
# devolução não vai mexer no pool de ninguém.
caso_padrao
CASO_MODO=hugetlb-1g
CASO_PAGE_KB=1048576
CASO_PAGES=22
pool_montar 1048576 22 22 0 0
rodar "$FRAG_PREPARE" mem_adquirir
exige_rc mem_adquirir 0 'A7 pool já cobre'
exige_texto 'pool já cobre as 22 página(s); nada a adquirir' 'A7 pool já cobre'
exige_pool '22 22 0 0' 'A7 pool já cobre'
exige_sem_escrita 'A7 pool já cobre'
exige_estado_campo ESTADO VERIFIED 'A7 pool já cobre'
exige_estado_campo DELTA 0 'A7 pool já cobre'
exige_estado_campo BASE_NR 22 'A7 pool já cobre'
exige_estado_campo BOOT_ID "$BOOT_ATUAL" 'A7 pool já cobre'
exige_modo_estado 'A7 pool já cobre'
passo

# A8: aquisição normal, com pool preexistente NÃO vazio. Só o delta é adquirido.
caso_padrao
CASO_PAGES=4096
pool_montar 2048 1096 1096 0 0
rodar "$FRAG_PREPARE" mem_adquirir
exige_rc mem_adquirir 0 'A8 aquisição normal'
exige_texto 'adquirindo 3000 página(s) de 2048 kB (de 1096 para 4096)' 'A8 aquisição normal'
exige_texto 'aquisição comprovada: 4096 página(s) no pool, 4096 livre(s)' 'A8 aquisição normal'
exige_pool '4096 4096 0 0' 'A8 aquisição normal'
exige_escritas '1096->4096' 'A8 aquisição normal'
exige_estado_campo ESTADO VERIFIED 'A8 aquisição normal'
exige_estado_campo DELTA 3000 'A8 aquisição normal'
exige_estado_campo BASE_NR 1096 'A8 aquisição normal'
exige_estado_campo BASE_FREE 1096 'A8 aquisição normal'
passo

# A9: ALOCAÇÃO PARCIAL. O kernel aceita a escrita e entrega o que consegue; sem
# reler, "aloquei 22" e "aloquei 9" seriam indistinguíveis. Página de 1 GiB
# exige 1 GiB fisicamente contíguo, então este é o cenário esperado depois de
# uptime e fragmentação — e o requisito manda RECUSAR o start, não degradar.
caso_padrao
CASO_MODO=hugetlb-1g
CASO_PAGE_KB=1048576
CASO_PAGES=22
K_TETO=9
pool_montar 1048576 0 0 0 0
rodar "$FRAG_PREPARE" mem_adquirir
exige_rc mem_adquirir 1 'A9 alocação parcial'
exige_texto 'aquisição parcial ou recusada pelo kernel; restaurando o baseline' 'A9 alocação parcial'
exige_texto 'baseline restaurado em 0 página(s)' 'A9 alocação parcial'
exige_pool '0 0 0 0' 'A9 alocação parcial'
exige_escritas '0->22 9->0' 'A9 alocação parcial'
exige_estado_ausente 'A9 alocação parcial'
passo

# A10: as páginas foram criadas mas NÃO ficaram livres. O QEMU não teria como
# tomá-las; a pós-condição é sobre disponibilidade, não sobre o contador total.
caso_padrao
CASO_PAGES=4096
K_LIVRE=congelado
pool_montar 2048 0 0 0 0
rodar "$FRAG_PREPARE" mem_adquirir
exige_rc mem_adquirir 1 'A10 páginas não livres'
exige_texto 'as 4096 página(s) adquiridas não estão livres (free=0); restaurando' 'A10 páginas não livres'
exige_pool '0 0 0 0' 'A10 páginas não livres'
exige_escritas '0->4096 4096->0' 'A10 páginas não livres'
exige_estado_campo ESTADO RECOVERY_REQUIRED 'A10 páginas não livres'
exige_estado_campo DELTA 4096 'A10 páginas não livres'
passo

# A11: a restauração do baseline TAMBÉM falha. É o pior caso da janela de
# aquisição: sobrou página no pool que não é de ninguém. O estado precisa
# sobreviver marcado, senão o operador não sabe o que recuperar.
caso_padrao
CASO_MODO=hugetlb-1g
CASO_PAGE_KB=1048576
CASO_PAGES=22
K_TETO=5
K_PISO=3
pool_montar 1048576 0 0 0 0
rodar "$FRAG_PREPARE" mem_adquirir
exige_rc mem_adquirir 1 'A11 baseline não restaurado'
exige_texto 'BASELINE NÃO RESTAURADO: nr_hugepages diverge de 0' 'A11 baseline não restaurado'
exige_texto 'estado preservado em' 'A11 baseline não restaurado'
exige_escritas '0->22 5->0' 'A11 baseline não restaurado'
exige_estado_campo ESTADO RECOVERY_REQUIRED 'A11 baseline não restaurado'
exige_estado_campo BASE_NR 0 'A11 baseline não restaurado'
passo

# A12: modo de runtime com plano ZERADO recusa o start.
#
# ISTO FOI DEFEITO, encontrado em 03/09/2026 e corrigido no mesmo dia: quando o
# núcleo RECUSAVA a política na renderização, a etapa 14 assava
# `MEM_PAGES_NEEDED=0` nos hooks assim mesmo, e o hook lia isso como "nada a
# adquirir" e devolvia 0. A VM subia sem as páginas que o perfil promete, e a
# mensagem da etapa afirmava que o hook recusaria no start — não recusava. A
# razão da recusa é LOCAL, e é por isso que o hook consegue aplicá-la sozinho,
# com o projeto apagado: num modo de runtime, zero página exigida é incoerente
# por construção.
for pedido in 0 '' quatro; do
    caso_padrao
    CASO_PAGES="$pedido"
    pool_montar 2048 4096 4096 0 0
    rodar "$FRAG_PREPARE" mem_adquirir
    exige_rc mem_adquirir 1 "A12 plano zerado ('${pedido:-vazio}')"
    exige_texto 'exige páginas, mas o plano assado nos hooks pede' "A12 plano zerado ('${pedido:-vazio}')"
    exige_pool '4096 4096 0 0' "A12 plano zerado ('${pedido:-vazio}')"
    exige_sem_escrita "A12 plano zerado ('${pedido:-vazio}')"
    exige_estado_ausente "A12 plano zerado ('${pedido:-vazio}')"
    passo
done

# ===========================================================================
# B. Devolução (mem_devolver)
# ===========================================================================

# B1: sem estado não há nada nosso no pool. Devolver "por precaução" seria
# reduzir pool de terceiro.
caso_padrao
CASO_PAGES=0
pool_montar 2048 22 22 0 0
rodar "$FRAG_RELEASE" mem_devolver marca_restauracao
exige_rc mem_devolver 0 'B1 sem estado'
exige_texto 'sem estado de memória; nada a devolver' 'B1 sem estado'
exige_pool '22 22 0 0' 'B1 sem estado'
exige_sem_escrita 'B1 sem estado'
passo

# B2: DELTA=0. CRÍTICO. O pool preexistente é baseline a preservar, não sobra a
# limpar: uma escrita aqui zeraria as 22 páginas que vieram do boot.
caso_padrao
pool_montar 2048 22 22 0 0
estado_completo 0 22 22
rodar "$FRAG_RELEASE" mem_devolver marca_restauracao
exige_rc mem_devolver 0 'B2 delta zero'
exige_texto 'nada havia sido adquirido; o pool preexistente é preservado' 'B2 delta zero'
exige_pool '22 22 0 0' 'B2 delta zero'
exige_sem_escrita 'B2 delta zero'
exige_estado_ausente 'B2 delta zero'
passo

# B3: devolução normal, voltando ao baseline não vazio.
caso_padrao
pool_montar 2048 4096 4096 0 0
estado_completo 3000 1096 1096
rodar "$FRAG_RELEASE" mem_devolver marca_restauracao
exige_rc mem_devolver 0 'B3 devolução normal'
exige_texto 'devolvendo 3000 página(s) de 2048 kB (de 4096 para 1096)' 'B3 devolução normal'
exige_texto 'devolução comprovada: pool de volta a 1096 página(s)' 'B3 devolução normal'
exige_pool '1096 1096 0 0' 'B3 devolução normal'
exige_escritas '4096->1096' 'B3 devolução normal'
exige_estado_ausente 'B3 devolução normal'
passo

# B4: free < delta. Página em uso na hora de devolver é QEMU vivo ou vazamento;
# escrever agora arrancaria memória de quem a está usando.
caso_padrao
pool_montar 2048 4096 10 0 0
estado_completo 3000 1096 1096
rodar "$FRAG_RELEASE" mem_devolver marca_restauracao
exige_rc mem_devolver 1 'B4 consumidor ativo'
exige_texto 'só 10 de 3000 página(s) estão livres; ainda há consumidor ativo' 'B4 consumidor ativo'
exige_pool '4096 10 0 0' 'B4 consumidor ativo'
exige_sem_escrita 'B4 consumidor ativo'
exige_estado_campo ESTADO RECOVERY_REQUIRED 'B4 consumidor ativo'
exige_texto 'RESTAUROU_GPU_E_DISPLAY' 'B4 consumidor ativo'
passo

# B5: nr < base_nr + delta. Alguém mexeu no pool entre a aquisição e a
# devolução; tirar o delta cheio desceria abaixo do baseline alheio.
caso_padrao
pool_montar 2048 3500 3500 0 0
estado_completo 3000 1096 1096
rodar "$FRAG_RELEASE" mem_devolver marca_restauracao
exige_rc mem_devolver 1 'B5 pool mexido'
exige_texto 'menos que baseline 1096 mais delta 3000; alguém mexeu no pool' 'B5 pool mexido'
exige_pool '3500 3500 0 0' 'B5 pool mexido'
exige_sem_escrita 'B5 pool mexido'
exige_estado_campo ESTADO RECOVERY_REQUIRED 'B5 pool mexido'
passo

# B6: a escrita da devolução não pode ser comprovada (o kernel não desce).
caso_padrao
K_PISO=2000
pool_montar 2048 4096 4096 0 0
estado_completo 3000 1096 1096
rodar "$FRAG_RELEASE" mem_devolver marca_restauracao
exige_rc mem_devolver 1 'B6 devolução não comprovada'
exige_texto 'a devolução não pôde ser comprovada; estado preservado' 'B6 devolução não comprovada'
exige_estado_campo ESTADO RECOVERY_REQUIRED 'B6 devolução não comprovada'
exige_estado_campo BASE_NR 1096 'B6 devolução não comprovada'
exige_texto 'RESTAUROU_GPU_E_DISPLAY' 'B6 devolução não comprovada'
passo

# B7: a escrita passa, mas o pool não reproduz o baseline (surplus apareceu). O
# aceite do requisito é sobre os QUATRO contadores, não só sobre `nr`.
caso_padrao
pool_montar 2048 4096 4096 0 7
estado_completo 3000 1096 1096
rodar "$FRAG_RELEASE" mem_devolver marca_restauracao
exige_rc mem_devolver 1 'B7 baseline não reproduzido'
exige_texto 'o pool não reproduziu o baseline' 'B7 baseline não reproduzido'
exige_texto 'surplus=7 esperado 0' 'B7 baseline não reproduzido'
exige_estado_campo ESTADO RECOVERY_REQUIRED 'B7 baseline não reproduzido'
passo

# B8: CHAVE DESCONHECIDA NÃO IMPEDE A DEVOLUÇÃO. Um hook antigo lendo estado
# novo cai exatamente aqui, e o release não pode abandonar GPU e display por
# causa de um campo que ele não entendeu. Ele relata e segue.
caso_padrao
pool_montar 2048 4096 4096 0 0
estado_escrever <<EOF
ESTADO=VERIFIED
BOOT_ID=$BOOT_ATUAL
MODO=hugetlb-2m
PAGE_KB=2048
DELTA=3000
BASE_NR=1096
BASE_FREE=1096
BASE_RESV=0
BASE_SURPLUS=0
CAMPO_DE_AMANHA=42
EOF
rodar "$FRAG_RELEASE" mem_devolver marca_restauracao
exige_rc mem_devolver 0 'B8 chave desconhecida'
exige_texto 'chave desconhecida no estado de memória: CAMPO_DE_AMANHA; a devolução segue' 'B8 chave desconhecida'
exige_texto 'devolução comprovada: pool de volta a 1096 página(s)' 'B8 chave desconhecida'
exige_pool '1096 1096 0 0' 'B8 chave desconhecida'
exige_estado_ausente 'B8 chave desconhecida'
passo

# B9: estado ilegível, vazio ou com campo não numérico devolve 1 SEM escrever
# no pool, e o diagnóstico NOMEIA o campo que faltou. Quem for recuperar o host
# à mão precisa saber qual campo se perdeu; "ilegível ou incompleto" mandava o
# operador abrir o arquivo e adivinhar.
for caso_b9 in vazio:delta ilegivel:delta delta_nao_numerico:delta base_resv_ausente:base_resv; do
    variante="${caso_b9%%:*}"
    campo="${caso_b9#*:}"
    caso_padrao
    pool_montar 2048 4096 4096 0 0
    case "$variante" in
        vazio) estado_escrever < /dev/null ;;
        ilegivel) estado_completo 3000 1096 1096; chmod 000 "$(estado_arquivo)" ;;
        delta_nao_numerico) estado_completo 'tres mil' 1096 1096 ;;
        base_resv_ausente)
            # O campo que falta aqui é de BASELINE, não de aritmética: ele só
            # entra na comparação final. Ainda assim decide o veredicto da
            # devolução, então a guarda tem de cobri-lo como cobre o delta.
            estado_escrever <<EOF
ESTADO=VERIFIED
BOOT_ID=$BOOT_ATUAL
MODO=hugetlb-2m
PAGE_KB=2048
DELTA=3000
BASE_NR=1096
BASE_FREE=1096
BASE_SURPLUS=0
EOF
            ;;
    esac
    rodar "$FRAG_RELEASE" mem_devolver marca_restauracao
    exige_rc mem_devolver 1 "B9 estado $variante"
    exige_texto "estado de memória sem o campo '$campo' ou com valor não numérico" "B9 estado $variante"
    exige_texto 'o pool não será tocado' "B9 estado $variante"
    exige_pool '4096 4096 0 0' "B9 estado $variante"
    exige_sem_escrita "B9 estado $variante"
    exige_texto 'RESTAUROU_GPU_E_DISPLAY' "B9 estado $variante"
    [ "$variante" != ilegivel ] || chmod 600 "$(estado_arquivo)"
    passo
done

# B10 e B11: REGRESSÃO de um defeito real, encontrado em 03/09/2026 pela
# primeira execução desta suíte e corrigido no mesmo dia. Os dois casos existem
# para que ele não volte, e é por isso que o mecanismo está escrito aqui.
#
# A guarda de completude validava os campos EMENDADOS num teste só:
#
#     case "$delta$base_nr$page_kb" in ''|*[!0-9]*) ... return 1 ;; esac
#
# A emenda numérica esconde campo vazio atrás do vizinho: com DELTA ausente,
# BASE_NR=2 e PAGE_KB=2048, a emenda vira "22048", que é numérica, e o estado
# incompleto passava pela guarda. O que vinha depois é o que torna estes dois
# casos obrigatórios:
#
#   B10 (sem DELTA): `[ "$livre" -lt "$delta" ]` com delta vazio vira ERRO DE
#        SINTAXE do `[`, que devolve 2 — e 2 é lido como FALSO, então a
#        verificação de consumidor ativo era PULADA. O hook ainda escrevia no
#        pool, porque `$(( nr - delta ))` com delta vazio é o próprio nr; e
#        quando base_nr casava com o nr atual, a devolução era declarada
#        COMPROVADA e o estado removido. Sucesso silencioso sobre estado que
#        ninguém conseguiu ler.
#   B11 (sem BASE_NR): pior. delta=3000 era válido, base_nr vazio virava 0 na
#        aritmética, e o hook REDUZIA o pool de 4096 para 1096 páginas antes de
#        descobrir que não sabia qual era o baseline — gravando `BASE_NR=`
#        (vazio) no RECOVERY_REQUIRED, um estado de recuperação que não
#        descreve nada. Se aquelas páginas fossem de terceiro, 3000 delas
#        tinham acabado de ser tiradas dele a partir de um estado ilegível: é a
#        invariante "pool preexistente ou de terceiro nunca é zerado" quebrada
#        em cheio, que é a razão de ser do requisito inteiro.
#
# Hoje cada campo é validado sozinho, e estes dois casos falham de novo se a
# validação voltar a ser feita em bloco.
caso_padrao
pool_montar 2048 4096 4096 0 0
estado_escrever <<EOF
ESTADO=VERIFIED
BOOT_ID=$BOOT_ATUAL
MODO=hugetlb-2m
PAGE_KB=2048
BASE_NR=4096
BASE_FREE=4096
BASE_RESV=0
BASE_SURPLUS=0
EOF
rodar "$FRAG_RELEASE" mem_devolver marca_restauracao
exige_rc mem_devolver 1 'B10 estado sem DELTA'
exige_texto "estado de memória sem o campo 'delta' ou com valor não numérico" 'B10 estado sem DELTA'
# Prova de que o `[` não é mais alimentado com campo vazio: era esse erro de
# sintaxe, lido como falso, que pulava a checagem de consumidor ativo.
recusa_texto 'integer expected' 'B10 estado sem DELTA'
recusa_texto 'devolução comprovada' 'B10 estado sem DELTA'
exige_sem_escrita 'B10 estado sem DELTA'
exige_pool '4096 4096 0 0' 'B10 estado sem DELTA'
exige_estado_intacto 'B10 estado sem DELTA: o estado tem de ser PRESERVADO como estava, não removido nem reescrito'
exige_texto 'RESTAUROU_GPU_E_DISPLAY' 'B10 estado sem DELTA'
passo

caso_padrao
pool_montar 2048 4096 4096 0 0
estado_escrever <<EOF
ESTADO=VERIFIED
BOOT_ID=$BOOT_ATUAL
MODO=hugetlb-2m
PAGE_KB=2048
DELTA=3000
BASE_FREE=4096
BASE_RESV=0
BASE_SURPLUS=0
EOF
rodar "$FRAG_RELEASE" mem_devolver marca_restauracao
exige_rc mem_devolver 1 'B11 estado sem BASE_NR'
exige_texto "estado de memória sem o campo 'base_nr' ou com valor não numérico" 'B11 estado sem BASE_NR'
exige_sem_escrita 'B11 estado sem BASE_NR'
# A asserção que o defeito tornava impossível: os QUATRO contadores saem da
# chamada exatamente como entraram. Antes, nr caía de 4096 para 1096.
exige_pool '4096 4096 0 0' 'B11 estado sem BASE_NR: o pool tem de sair intacto de um estado que o hook não sabe ler'
exige_estado_intacto 'B11 estado sem BASE_NR: o estado tem de ser PRESERVADO como estava'
exige_texto 'RESTAUROU_GPU_E_DISPLAY' 'B11 estado sem BASE_NR'
passo

# ===========================================================================
# C. Boot ID: o que impede o boot seguinte de reduzir pool que não é dele
# ===========================================================================

# O reboot limpa o pool inteiro. Um estado sobrevivente de outro boot não
# descreve página alguma para devolver; tratá-lo como pendente faria o hook
# tirar de `nr_hugepages` páginas que pertencem a ESTE boot. A reconciliação é
# descartar o estado sem tocar no pool. Sem isto, power loss vira perda de
# memória do host no boot seguinte.
caso_padrao
pool_montar 2048 4096 4096 0 0
estado_completo 3000 1096 1096 "$BOOT_OUTRO"
rodar "$FRAG_RELEASE" mem_devolver marca_restauracao
exige_rc mem_devolver 0 'C1 estado de outro boot'
exige_texto "estado de memória é do boot $BOOT_OUTRO e o atual é $BOOT_ATUAL" 'C1 estado de outro boot'
exige_texto 'reconciliando sem tocar no pool' 'C1 estado de outro boot'
exige_pool '4096 4096 0 0' 'C1 estado de outro boot'
exige_sem_escrita 'C1 estado de outro boot'
exige_estado_ausente 'C1 estado de outro boot'
passo

# C2: o mesmo estado, agora com o boot ID batendo, PRECISA devolver. Sem este
# par, "não tocar no pool" passaria trivialmente por nunca devolver nada.
caso_padrao
pool_montar 2048 4096 4096 0 0
estado_completo 3000 1096 1096 "$BOOT_ATUAL"
rodar "$FRAG_RELEASE" mem_devolver marca_restauracao
exige_rc mem_devolver 0 'C2 mesmo boot devolve'
exige_pool '1096 1096 0 0' 'C2 mesmo boot devolve'
exige_escritas '4096->1096' 'C2 mesmo boot devolve'
passo

# C3: boot_id do host ilegível. Sem saber de que boot é o estado, devolver
# seria adivinhar; o hook recusa e não escreve.
caso_padrao
pool_montar 2048 4096 4096 0 0
estado_completo 3000 1096 1096
rm -f -- "$BOOT_FILE"
rodar "$FRAG_RELEASE" mem_devolver marca_restauracao
exige_rc mem_devolver 1 'C3 boot_id ilegível'
exige_texto 'boot_id ilegível; devolução impossível' 'C3 boot_id ilegível'
exige_sem_escrita 'C3 boot_id ilegível'
exige_pool '4096 4096 0 0' 'C3 boot_id ilegível'
printf '%s\n' "$BOOT_ATUAL" > "$BOOT_FILE"
passo

# ===========================================================================
# D. Ciclo completo e idempotência
# ===========================================================================

# O aceite do requisito é literalmente este: com a VM parada, os quatro
# contadores voltam ao baseline legítimo anterior. O pool preexistente NÃO
# vazio é o que torna o caso interessante: ele tem de sobreviver aos dois
# ciclos, e a segunda devolução tem de ser no-op em vez de "limpar o resto".
caso_padrao
CASO_MODO=hugetlb-1g
CASO_PAGE_KB=1048576
CASO_PAGES=22
pool_montar 1048576 8 8 0 0
BASELINE=$(pool_conta)
rodar "$FRAG_PREPARE" mem_adquirir
exige_rc mem_adquirir 0 'D1 ciclo: aquisição'
exige_pool '22 22 0 0' 'D1 ciclo: aquisição'
exige_estado_campo DELTA 14 'D1 ciclo: aquisição'
rodar "$FRAG_RELEASE" mem_devolver marca_restauracao
exige_rc mem_devolver 0 'D1 ciclo: devolução'
exige_pool "$BASELINE" 'D1 ciclo: pool voltou ao baseline preexistente'
exige_estado_ausente 'D1 ciclo: devolução'
passo

: > "$ESCRITAS"
rodar "$FRAG_RELEASE" mem_devolver marca_restauracao
exige_rc mem_devolver 0 'D2 segunda devolução é no-op'
exige_texto 'sem estado de memória; nada a devolver' 'D2 segunda devolução é no-op'
exige_sem_escrita 'D2 segunda devolução é no-op'
exige_pool "$BASELINE" 'D2 segunda devolução é no-op'
passo

# D3: dois ciclos seguidos, um depois do outro, no mesmo pool.
rodar "$FRAG_PREPARE" mem_adquirir
exige_rc mem_adquirir 0 'D3 segundo ciclo: aquisição'
rodar "$FRAG_RELEASE" mem_devolver
exige_rc mem_devolver 0 'D3 segundo ciclo: devolução'
exige_pool "$BASELINE" 'D3 dois ciclos deixam o pool exatamente como estava'
exige_estado_ausente 'D3 segundo ciclo'
passo

# D4: o mesmo ciclo com pool VAZIO, para provar que o baseline preservado do
# caso anterior não foi acidente de ter sobrado página.
caso_padrao
CASO_PAGES=4096
pool_montar 2048 0 0 0 0
rodar "$FRAG_PREPARE" mem_adquirir
exige_pool '4096 4096 0 0' 'D4 ciclo do zero: aquisição'
rodar "$FRAG_RELEASE" mem_devolver
exige_rc mem_devolver 0 'D4 ciclo do zero: devolução'
exige_pool '0 0 0 0' 'D4 ciclo do zero: pool volta a zero'
exige_estado_ausente 'D4 ciclo do zero'
passo

# ===========================================================================
# E. O que o release promete ao resto do host
# ===========================================================================

# Todo `rodar` já cobra a linha VIVO, então a promessa é verificada em cada
# caso acima. Este bloco a torna explícita nos cenários de falha, e prova que
# a restauração de GPU e display roda DEPOIS de cada um deles. Um `exit` no
# lugar de um `return 1` aqui é tela preta para o operador.
falhas_de_devolucao() {
    caso_padrao
    case "$1" in
        consumidor)  pool_montar 2048 4096 10 0 0;   estado_completo 3000 1096 1096 ;;
        pool_mexido) pool_montar 2048 3500 3500 0 0; estado_completo 3000 1096 1096 ;;
        sem_prova)   K_PISO=2000; pool_montar 2048 4096 4096 0 0; estado_completo 3000 1096 1096 ;;
        surplus)     pool_montar 2048 4096 4096 0 7; estado_completo 3000 1096 1096 ;;
        estado_ruim) pool_montar 2048 4096 4096 0 0; estado_escrever < /dev/null ;;
        pool_sumiu)  pool_montar 2048 4096 4096 0 0; estado_completo 3000 1096 1096 '' 4096 ;;
        escrita_erro) K_ESCRITA=erro; pool_montar 2048 4096 4096 0 0; estado_completo 3000 1096 1096 ;;
    esac
}
for cenario in consumidor pool_mexido sem_prova surplus estado_ruim pool_sumiu escrita_erro; do
    falhas_de_devolucao "$cenario"
    rodar "$FRAG_RELEASE" mem_devolver marca_restauracao
    exige_rc mem_devolver 1 "E falha '$cenario'"
    exige_texto 'RESTAUROU_GPU_E_DISPLAY' "E falha '$cenario': o release abandonaria GPU e display"
    passo
done

# E2: a mesma promessa na aquisição, só que ao contrário. Falhar ali ABORTA o
# start, e é esse o contrato: uma VM que sobe com metade das páginas
# prometidas mente sobre o próprio perfil. O hook devolve 1 e quem aborta é o
# `mem_adquirir || falha` do prepare, já verificado na seção 2.
caso_padrao
CASO_PAGES=4096
K_TETO=100
pool_montar 2048 0 0 0 0
rodar "$FRAG_PREPARE" mem_adquirir marca_restauracao
exige_rc mem_adquirir 1 'E2 aquisição parcial devolve 1 sem abortar o processo'
exige_texto 'RESTAUROU_GPU_E_DISPLAY' 'E2 aquisição parcial'
passo

# ===========================================================================
# F. Oráculo diferencial: Bash do hook x Python do core
# ===========================================================================
#
# O hook decide sozinho, com o projeto apagado; o core decide o mesmo em
# Python, e é ele quem alimenta o hook com `MEM_PAGE_KB` e `MEM_PAGES_NEEDED`
# na renderização. Cada cenário roda nos dois e o veredicto (aceita/recusa) e
# o delta são comparados. Onde eles divergem POR DESENHO, a divergência é
# declarada no corpus com o motivo, e a checagem é nos dois sentidos:
# divergência não declarada reprova, e divergência declarada que deixou de
# existir também.
command -v python3 > /dev/null 2>&1 || fail 'python3 é obrigatório para o oráculo diferencial'

cat > "$ORACULO" <<'PY_EOF'
"""Lado Python do oráculo de I9.12: o mesmo plano que o hook faz em Bash."""
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])

from passthrough_core import resources  # noqa: E402
from passthrough_core.errors import DataError  # noqa: E402

with open(sys.argv[2], encoding="utf-8") as entrada:
    linhas = [linha.rstrip("\n") for linha in entrada if linha.strip()]

saida = []
for linha in linhas:
    ident, modo, ram, caminho = linha.split("\t")
    with open(caminho, encoding="utf-8") as arquivo:
        foto = arquivo.read()
    try:
        plano = resources.plan({"mode": modo, "snapshot": foto, "vm_ram_mib": ram})
    except DataError as exc:
        saida.append("\t".join([ident, "dado", "0", "0", "0", str(exc)]))
        continue
    saida.append(
        "\t".join(
            [
                ident,
                "aceita" if plano["valid"] == 1 else "recusa",
                str(plano["page_kb"]),
                str(plano["pages_needed"]),
                str(plano["acquire_delta"]),
                plano["error"],
            ]
        )
    )
with open(sys.argv[3], "w", encoding="utf-8") as destino:
    destino.write("\n".join(saida) + "\n")
PY_EOF

# id|modo|ram_mib|pool_kb|nr|free|resv|surplus|memavail_kb|nodes|teto|py|sh|delta|motivo
# pool_kb=0: o host não expõe pool nenhum.  nodes: 1, 2 (com contadores por nó)
# ou 2sem (declara dois nós sem os contadores).  teto=-: kernel sem limite.
# py/sh: veredicto esperado de cada lado.  delta: o delta comum quando os dois
# aceitam.  motivo: '-' quando concordam; texto quando a divergência é de
# desenho e está declarada.
CORPUS=(
  'normal-baseline|normal|8192|2048|0|0|0|0|20971520|1|-|aceita|aceita|0|-'
  'normal-pool-de-terceiro-em-uso|normal|8192|2048|100|80|0|0|20971520|1|-|aceita|aceita|0|-'
  '2m-pool-ausente|hugetlb-2m|8192|0|0|0|0|0|20971520|1|-|recusa|recusa|-|-'
  '2m-consumidor-externo|hugetlb-2m|8192|2048|4096|4090|0|0|20971520|1|-|recusa|recusa|-|-'
  '2m-resv-de-terceiro|hugetlb-2m|8192|2048|4096|4096|5|0|20971520|1|-|recusa|recusa|-|-'
  '2m-surplus|hugetlb-2m|8192|2048|4096|4096|0|7|20971520|1|-|recusa|recusa|-|-'
  '2m-pool-cobre-de-sobra|hugetlb-2m|8192|2048|5000|5000|0|0|20971520|1|-|aceita|aceita|0|-'
  '2m-pool-exato|hugetlb-2m|8192|2048|4096|4096|0|0|20971520|1|-|aceita|aceita|0|-'
  '2m-do-zero|hugetlb-2m|8192|2048|0|0|0|0|20971520|1|-|aceita|aceita|4096|-'
  '2m-preexistente-parcial|hugetlb-2m|8192|2048|1096|1096|0|0|20971520|1|-|aceita|aceita|3000|-'
  '1g-runtime-do-zero|hugetlb-1g|22528|1048576|0|0|0|0|29093508|1|-|aceita|aceita|22|-'
  '1g-runtime-pool-do-boot|hugetlb-1g|22528|1048576|22|22|0|0|29093508|1|-|aceita|aceita|0|-'
  '1g-runtime-consumidor|hugetlb-1g|22528|1048576|22|20|0|0|29093508|1|-|recusa|recusa|-|-'
  '1g-boot-cobre|hugetlb-1g-boot|22528|1048576|22|22|0|0|4143904|1|-|aceita|aceita|0|-'
  '2m-kernel-honesto-sem-memoria|hugetlb-2m|8192|2048|0|0|0|0|1048576|1|100|recusa|recusa|-|-'
  '2m-memavail-insuficiente|hugetlb-2m|8192|2048|0|0|0|0|1048576|1|-|recusa|aceita|-|o núcleo recusa CEDO por MemAvailable; o hook não lê meminfo (I9-D8) e só reprova pela pós-condição, quando o kernel de fato não entrega. Com kernel generoso o hook aceita, e é o cenário 2m-kernel-honesto-sem-memoria que prova que os dois recusam quando a memória realmente falta'
  '1g-boot-nao-cobre|hugetlb-1g-boot|22528|1048576|10|10|0|0|4143904|1|-|recusa|aceita|-|hugetlb-1g-boot não é modo de runtime: o hook por contrato NÃO toca no pool e devolve 0. Quem recusa a reserva estática insuficiente é o núcleo, na renderização'
  'modo-desconhecido|hugetlb-4m|8192|2048|0|0|0|0|20971520|1|-|recusa|aceita|-|modo fora do catálogo: o núcleo recusa nominalmente e o hook aplica o padrão mais seguro que ele pode aplicar sozinho, que é não tocar no pool'
  'modo-vazio||8192|2048|0|0|0|0|20971520|1|-|recusa|aceita|-|idem modo-desconhecido: modo vazio não é de runtime, o hook não toca no pool e o núcleo recusa por nome'
  'numa-dois-nos-delta-par|hugetlb-2m|8192|2048|0|0|0|0|20971520|2|-|aceita|aceita|4096|-'
  'numa-dois-nos-delta-impar|hugetlb-2m|8194|2048|0|0|0|0|20971520|2|-|recusa|aceita|-|NUMA é decisão do planejador e o hook é deliberadamente cego a nós (I9-D8, Bash puro sem o core). A recusa por plano zerado NÃO alcança este caso: resources.py fixa pages_needed ANTES da checagem de NUMA (linha 418 contra 472), então o hook recebe 4097 páginas válidas e adquire. Fechar isto exige a etapa 14 não renderizar hook a partir de plano recusado, não uma checagem local'
  'numa-dois-nos-sem-contadores|hugetlb-2m|8192|2048|0|0|0|0|20971520|2sem|-|recusa|aceita|-|idem numa-dois-nos-delta-impar: a recusa do núcleo acontece depois da aritmética de páginas, o hook recebe 4096 páginas válidas e não tem como olhar para NUMA sozinho'
  'ram-nao-multipla-da-pagina|hugetlb-2m|8193|2048|0|0|0|0|20971520|1|-|recusa|recusa|-|-'  # CONVERGIU em 03/09/2026: a recusa nasce DENTRO de _pages_needed, então pages_needed chega 0 ao hook e a nova checagem de plano zerado recusa o start
)

: > "$ORACULO_DIR/corpus.tsv"
for linha in "${CORPUS[@]}"; do
    IFS='|' read -r c_id c_modo c_ram c_pool_kb c_nr c_free c_resv c_surplus \
        c_memavail c_nodes c_teto c_py c_sh c_delta c_motivo <<< "$linha"
    foto="$ORACULO_DIR/foto-$c_id.txt"
    {
        case "$c_nodes" in
            1) printf 'nodes\t1\n' ;;
            2|2sem) printf 'nodes\t2\n' ;;
            *) fail "corpus: campo nodes inválido em $c_id" ;;
        esac
        if [ "$c_pool_kb" != 0 ]; then
            printf 'pool\t%s\tnr\t%s\n' "$c_pool_kb" "$c_nr"
            printf 'pool\t%s\tfree\t%s\n' "$c_pool_kb" "$c_free"
            printf 'pool\t%s\tresv\t%s\n' "$c_pool_kb" "$c_resv"
            printf 'pool\t%s\tsurplus\t%s\n' "$c_pool_kb" "$c_surplus"
            if [ "$c_nodes" = 2 ]; then
                printf 'node\t0\t%s\tnr\t%s\n' "$c_pool_kb" "$(( c_nr / 2 ))"
                printf 'node\t0\t%s\tfree\t%s\n' "$c_pool_kb" "$(( c_free / 2 ))"
                printf 'node\t1\t%s\tnr\t%s\n' "$c_pool_kb" "$(( c_nr - c_nr / 2 ))"
                printf 'node\t1\t%s\tfree\t%s\n' "$c_pool_kb" "$(( c_free - c_free / 2 ))"
            fi
        fi
        printf 'meminfo\tMemTotal\t31722704\n'
        printf 'meminfo\tMemAvailable\t%s\n' "$c_memavail"
        printf 'boot_id\t%s\n' "$BOOT_ATUAL"
    } > "$foto"
    printf '%s\t%s\t%s\t%s\n' "$c_id" "$c_modo" "$c_ram" "$foto" >> "$ORACULO_DIR/corpus.tsv"
done

python3 -I -S -B "$ORACULO" "$RAIZ/libexec" "$ORACULO_DIR/corpus.tsv" "$ORACULO_DIR/veredictos.tsv" \
    || fail 'o lado Python do oráculo não executou'
[ -s "$ORACULO_DIR/veredictos.tsv" ] || fail 'o oráculo Python não produziu resultado'
passo

DIVERGENCIAS=0
for linha in "${CORPUS[@]}"; do
    IFS='|' read -r c_id c_modo c_ram c_pool_kb c_nr c_free c_resv c_surplus \
        c_memavail c_nodes c_teto c_py c_sh c_delta c_motivo <<< "$linha"

    py_linha=$(awk -F'\t' -v id="$c_id" '$1 == id { print; exit }' "$ORACULO_DIR/veredictos.tsv")
    [ -n "$py_linha" ] || fail "oráculo: o núcleo não respondeu sobre $c_id"
    IFS=$'\t' read -r _ py_veredicto py_page_kb py_pages py_delta py_erro <<< "$py_linha"
    [ "$py_veredicto" != dado ] \
        || fail "oráculo: o corpus produziu fotografia inválida em $c_id: $py_erro"
    [ "$py_veredicto" = "$c_py" ] \
        || fail "oráculo: o núcleo devia '$c_py' em $c_id e respondeu '$py_veredicto' ($py_erro)"

    # O hook consome exatamente os números que o núcleo assou na renderização.
    caso_padrao
    CASO_MODO="$c_modo"
    CASO_PAGE_KB="$py_page_kb"
    CASO_PAGES="$py_pages"
    [ "$c_teto" = '-' ] || K_TETO="$c_teto"
    [ "$c_pool_kb" = 0 ] || pool_montar "$c_pool_kb" "$c_nr" "$c_free" "$c_resv" "$c_surplus"
    rodar "$FRAG_PREPARE" mem_adquirir
    sh_rc=$(printf '%s\n' "$SAIDA" | sed -n 's/^RC:mem_adquirir=//p' | head -1)
    if [ "$sh_rc" = 0 ]; then sh_veredicto=aceita; else sh_veredicto=recusa; fi
    [ "$sh_veredicto" = "$c_sh" ] \
        || fail "oráculo: o hook devia '$c_sh' em $c_id e respondeu '$sh_veredicto'. Saída: $SAIDA"

    # Sem estado gravado, nada foi adquirido: delta observado é zero.
    if [ -e "$(estado_arquivo)" ]; then
        sh_delta=$(sed -n 's/^DELTA=//p' "$(estado_arquivo)" | head -1)
    else
        sh_delta=0
    fi

    if [ "$py_veredicto" = "$sh_veredicto" ]; then
        [ "$c_motivo" = '-' ] \
            || fail "oráculo: $c_id declara divergência que NÃO existe (os dois responderam '$py_veredicto'); divergência declarada e não observada reprova"
        if [ "$py_veredicto" = aceita ]; then
            [ "$py_delta" = "$c_delta" ] \
                || fail "oráculo: delta do núcleo em $c_id é $py_delta e o corpus declara $c_delta"
            [ "$sh_delta" = "$c_delta" ] \
                || fail "oráculo: delta do hook em $c_id é $sh_delta e o corpus declara $c_delta"
        fi
    else
        [ "$c_motivo" != '-' ] \
            || fail "oráculo: DIVERGÊNCIA NÃO DECLARADA em $c_id: núcleo '$py_veredicto', hook '$sh_veredicto'. Declare o motivo no corpus ou corrija um dos lados"
        DIVERGENCIAS=$((DIVERGENCIAS + 1))
    fi
    passo
done
[ "$DIVERGENCIAS" -eq 6 ] \
    || fail "oráculo: o corpus previa 6 divergências declaradas e observou $DIVERGENCIAS; mudança de comportamento sem revisão do contrato"
passo

# ===========================================================================
# 6. Nada saiu do sandbox
# ===========================================================================

HOST_DEPOIS=$(hugepages_host)
[ "$HOST_ANTES" = "$HOST_DEPOIS" ] \
    || fail "os contadores REAIS de hugepages do host mudaram durante a suíte:\n$HOST_ANTES\n---\n$HOST_DEPOIS"
HOST_ESTADO_DEPOIS=$([ -e /var/lib/vm-passthrough ] && echo existe || echo ausente)
[ "$HOST_ESTADO_ANTES" = "$HOST_ESTADO_DEPOIS" ] \
    || fail '/var/lib/vm-passthrough foi criado ou removido pela suíte'
[ -n "$(find "$LOG_DIR" -name hooks.log -print -quit)" ] \
    || fail 'o log dos hooks não caiu dentro do sandbox; verifique o redirecionamento de HOOK_LOG_DIR'
PERMITIDOS=' bloco-prepare bloco-release boot_id estado estado-como-escrito frag-prepare.sh frag-release.sh kernel-escritas kernel-sombra log oraculo projeto render render.log runner.sh sys '
while IFS= read -r item; do
    case "$PERMITIDOS" in
        *" $item "*) ;;
        *) fail "artefato inesperado na raiz do sandbox: $item" ;;
    esac
done < <(find "$TMP" -maxdepth 1 -mindepth 1 -printf '%f\n' | LC_ALL=C sort)
for obrigatorio in render sys log runner.sh oraculo; do
    [ -e "$TMP/$obrigatorio" ] \
        || fail "o sandbox perdeu um artefato que a suíte precisa ter produzido: $obrigatorio"
done
passo

printf 'OK: ciclo de vida da memória dos hooks (I9.12) em %d casos: aquisição fail-closed, devolução exata, reconciliação por boot ID, dois ciclos idempotentes e oráculo Bash x Python com %d divergências declaradas\n' \
    "$CASOS" "$DIVERGENCIAS"
