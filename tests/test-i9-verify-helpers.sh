#!/usr/bin/env bash
# Gate dirigido I9.9: helpers compartilhados de prova dos verificadores.
#
# O que este teste protege (REQ-VERIFY-FAILCLOSED): ferramenta ausente, saída
# inesperada e parsing incompleto não podem virar sucesso, e as três classes
# (pendente, indeterminado, erro) precisam continuar distinguíveis. Cada caso
# confere ao mesmo tempo o CÓDIGO devolvido, o CONTADOR incrementado e o TEXTO
# emitido, porque um helper que devolve 2 mas incrementa V_FALHAS levaria a
# etapa a rc 1 e o operador a mexer na coisa errada.
#
# Todo caso roda em um processo bash próprio: os contadores V_* são globais e
# vazariam entre casos. Herméticos por construção: tudo acontece sob um TMP
# próprio, com PATH controlado quando o caso precisa esconder ou encenar um
# binário. Nada toca o host.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

fail() { printf 'FALHA I9.9: %s\n' "$*" >&2; exit 1; }
# Caminho absoluto do interpretador: alguns casos zeram o PATH de propósito
# para provar o ramo "ferramenta ausente", e aí "bash" deixaria de resolver.
BASH_BIN="${BASH:-/bin/bash}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/i9-verify.XXXXXXXX")
trap 'rm -rf -- "$TMP"' EXIT HUP INT TERM

CASOS=0
CASO_SAIDA=""
CASO_RESUMO=""

# executar DESCRICAO CORPO [VAR=valor...]
# Roda CORPO em um bash filho que carrega a fachada, zera os contadores e
# imprime o resumo canônico. Assim o resumo mede o processo que realmente
# executou o helper, e não o shell do teste.
executar() {
    local descricao="$1" corpo="$2"
    shift 2
    local script saida="" rc=0
    script="source \"$ROOT/lib/common.sh\"
V_FALHAS=0
V_INDETERMINADOS=0
V_ERROS=0
rc_interno=0
{ $corpo ; } || rc_interno=\$?
printf 'RC=%s FALHAS=%s INDET=%s ERROS=%s\\n' \"\$rc_interno\" \"\$V_FALHAS\" \"\$V_INDETERMINADOS\" \"\$V_ERROS\""
    saida="$( { env "$@" "$BASH_BIN" -c "$script"; } 2>&1 )" || rc=$?
    [ "$rc" -eq 0 ] || fail "$descricao: o caso abortou (código $rc). Saída: $saida"
    CASO_SAIDA="$saida"
    CASO_RESUMO="$(printf '%s\n' "$saida" | tail -n 1)"
    CASOS=$((CASOS + 1))
}

# esperar DESCRICAO RC CLASSE [TRECHO]
esperar() {
    local descricao="$1" rc="$2" classe="$3" trecho="${4:-}"
    local f=0 i=0 e=0 alvo
    case "$classe" in
        ok) ;;
        pendente) f=1 ;;
        indeterminado) i=1 ;;
        erro) e=1 ;;
        *) fail "$descricao: classe de teste desconhecida '$classe'" ;;
    esac
    alvo="RC=$rc FALHAS=$f INDET=$i ERROS=$e"
    [ "$CASO_RESUMO" = "$alvo" ] \
        || fail "$descricao: esperado [$alvo], obtido [$CASO_RESUMO]. Saída: $CASO_SAIDA"
    if [ -n "$trecho" ]; then
        printf '%s\n' "$CASO_SAIDA" | grep -Fq -- "$trecho" \
            || fail "$descricao: texto sem o trecho '$trecho'. Saída: $CASO_SAIDA"
    fi
}

VAZIO="$TMP/bin-vazio"
mkdir -p "$VAZIO"

# --- v_exigir_comando ---------------------------------------------------------
executar 'comando presente' 'v_exigir_comando sh'
esperar 'comando presente' 0 ok

executar 'comando ausente é indeterminado' 'v_exigir_comando nao-existe-i9'
esperar 'comando ausente é indeterminado' 2 indeterminado 'não pôde ser observado'

executar 'comando ausente com --pendente' 'v_exigir_comando --pendente nao-existe-i9'
esperar 'comando ausente com --pendente' 1 pendente 'execute a etapa que a instala'

executar 'lista com um ausente' 'v_exigir_comando sh nao-existe-i9'
esperar 'lista com um ausente' 2 indeterminado 'nao-existe-i9'

executar 'lista toda presente' 'v_exigir_comando sh cat'
esperar 'lista toda presente' 0 ok

# --- v_classificar ------------------------------------------------------------
executar 'classificar 0' "v_classificar 0 provado pendente indet erroX"
esperar 'classificar 0' 0 ok 'provado'
executar 'classificar 1' "v_classificar 1 provado pendente indet erroX"
esperar 'classificar 1' 0 pendente 'pendente'
executar 'classificar 2' "v_classificar 2 provado pendente indet erroX"
esperar 'classificar 2' 0 indeterminado 'indet'
executar 'classificar 3' "v_classificar 3 provado pendente indet erroX"
esperar 'classificar 3' 0 erro 'erroX'
# Código fora da faixa não pode ser ignorado nem virar sucesso.
executar 'classificar 7' "v_classificar 7 provado pendente indet erroX"
esperar 'classificar 7' 0 erro 'inesperado'
executar 'classificar vazio' "v_classificar '' provado pendente indet erroX"
esperar 'classificar vazio' 0 erro 'inesperado'

# --- v_prova_pacote -----------------------------------------------------------
# A regressão central: `dpkg -s` devolve 0 para pacote REMOVIDO que deixou
# config-files, então um pacote ausente era relatado como instalado.
BIN_DPKG="$TMP/bin-dpkg"
mkdir -p "$BIN_DPKG"
cat > "$BIN_DPKG/dpkg-query" <<'SHIM'
#!/bin/bash
for arg in "$@"; do
    case "$arg" in
        removido-com-config) printf 'deinstall ok config-files'; exit 0 ;;
        instalado-de-verdade) printf 'install ok installed'; exit 0 ;;
        semi-instalado) printf 'install ok half-configured'; exit 0 ;;
    esac
done
exit 1
SHIM
chmod +x "$BIN_DPKG/dpkg-query"

executar 'pacote instalado' \
    'PLATAFORMA_GERENCIADOR_PACOTES=apt; v_prova_pacote instalado-de-verdade' \
    PATH="$BIN_DPKG:$PATH"
esperar 'pacote instalado' 0 ok 'instalado-de-verdade instalado.'

executar 'pacote removido com config-files' \
    'PLATAFORMA_GERENCIADOR_PACOTES=apt; v_prova_pacote removido-com-config' \
    PATH="$BIN_DPKG:$PATH"
esperar 'pacote removido com config-files' 1 pendente 'deinstall ok config-files'

executar 'pacote meio configurado' \
    'PLATAFORMA_GERENCIADOR_PACOTES=apt; v_prova_pacote semi-instalado' \
    PATH="$BIN_DPKG:$PATH"
esperar 'pacote meio configurado' 1 pendente 'half-configured'

executar 'pacote desconhecido' \
    'PLATAFORMA_GERENCIADOR_PACOTES=apt; v_prova_pacote nunca-existiu' \
    PATH="$BIN_DPKG:$PATH"
esperar 'pacote desconhecido' 1 pendente 'nunca-existiu ausente.'

executar 'dpkg-query ausente' \
    'PLATAFORMA_GERENCIADOR_PACOTES=apt; v_prova_pacote qualquer' \
    PATH="$VAZIO"
esperar 'dpkg-query ausente' 2 indeterminado 'dpkg-query ausente'

executar 'gerenciador não resolvido' \
    'PLATAFORMA_GERENCIADOR_PACOTES=""; v_prova_pacote qualquer'
esperar 'gerenciador não resolvido' 2 indeterminado 'não resolvido'

executar 'gerenciador sem prova implementada' \
    'PLATAFORMA_GERENCIADOR_PACOTES=zypper; v_prova_pacote qualquer'
esperar 'gerenciador sem prova implementada' 2 indeterminado 'zypper'

executar 'pacote sem nome' "v_prova_pacote ''"
esperar 'pacote sem nome' 3 erro 'exige o nome'

# --- v_prova_arquivo ----------------------------------------------------------
ARQ="$TMP/hook.sh"
printf '#!/bin/bash\n# MARCADOR-I9\necho ok\n' > "$ARQ"
chmod 755 "$ARQ"

executar 'arquivo ausente' "v_prova_arquivo '$TMP/nao-existe' Hook"
esperar 'arquivo ausente' 1 pendente 'Hook ausente'

executar 'arquivo provado' "v_prova_arquivo '$ARQ' Hook"
esperar 'arquivo provado' 0 ok 'Hook provado'

executar 'marcador presente' "v_prova_arquivo '$ARQ' Hook --marcador MARCADOR-I9"
esperar 'marcador presente' 0 ok 'Hook provado'

# O falso sucesso clássico: o arquivo existe, é executável e passa em bash -n,
# mas é de outra geração. Sem marcador isso era aprovado como concluído.
executar 'marcador de outra geração' "v_prova_arquivo '$ARQ' Hook --marcador MARCADOR-ANTIGO"
esperar 'marcador de outra geração' 1 pendente 'sem o marcador desta versão'

executar 'modo divergente' "v_prova_arquivo '$ARQ' Hook --modo 600"
esperar 'modo divergente' 1 pendente 'com modo 755, esperado 600'

executar 'modo convergente' "v_prova_arquivo '$ARQ' Hook --modo 755"
esperar 'modo convergente' 0 ok 'Hook provado'

SEM_EXEC="$TMP/sem-exec.sh"
printf '#!/bin/bash\n' > "$SEM_EXEC"
chmod 644 "$SEM_EXEC"
executar 'sem bit de execução' "v_prova_arquivo '$SEM_EXEC' Hook --exec"
esperar 'sem bit de execução' 1 pendente 'sem permissão de execução'

mkdir -p "$TMP/um-diretorio"
executar 'caminho é diretório' "v_prova_arquivo '$TMP/um-diretorio' Hook"
esperar 'caminho é diretório' 3 erro 'não é arquivo regular'

ln -s "$TMP/alvo-inexistente" "$TMP/link-quebrado"
executar 'link quebrado' "v_prova_arquivo '$TMP/link-quebrado' Hook"
esperar 'link quebrado' 3 erro 'link simbólico quebrado'

REFERENCIA="$TMP/referencia.sh"
cp -- "$ARQ" "$REFERENCIA"
executar 'conteúdo convergente' "v_prova_arquivo '$ARQ' Hook --esperado '$REFERENCIA'"
esperar 'conteúdo convergente' 0 ok 'Hook provado'
printf 'divergiu\n' >> "$REFERENCIA"
executar 'conteúdo divergente' "v_prova_arquivo '$ARQ' Hook --esperado '$REFERENCIA'"
esperar 'conteúdo divergente' 1 pendente 'divergente do conteúdo gerado'
executar 'referência indisponível' "v_prova_arquivo '$ARQ' Hook --esperado '$TMP/nao-existe'"
esperar 'referência indisponível' 2 indeterminado 'referência de Hook indisponível'

executar 'opção desconhecida' "v_prova_arquivo '$ARQ' Hook --invalida"
esperar 'opção desconhecida' 3 erro 'opção desconhecida'

executar 'sem descrição' "v_prova_arquivo '$ARQ' ''"
esperar 'sem descrição' 3 erro 'não vazios'

# Arquivo ilegível é indeterminado, nunca pendência: o conteúdo não foi visto.
# Pulado sob root, que lê tudo e tornaria a asserção falsa por ambiente.
if [ "$(id -u)" -ne 0 ]; then
    ILEGIVEL="$TMP/ilegivel"
    printf 'x\n' > "$ILEGIVEL"
    chmod 000 "$ILEGIVEL"
    if [ ! -r "$ILEGIVEL" ]; then
        executar 'arquivo ilegível' "v_prova_arquivo '$ILEGIVEL' Drop-in"
        esperar 'arquivo ilegível' 2 indeterminado 'não é legível'
    fi
    chmod 644 "$ILEGIVEL"
fi

# --- v_prova_montagem ---------------------------------------------------------
BIN_MNT="$TMP/bin-mnt"
mkdir -p "$BIN_MNT"
cat > "$BIN_MNT/findmnt" <<'SHIM'
#!/bin/bash
alvo=""
for ((i = 1; i <= $#; i++)); do
    if [ "${!i}" = "--mountpoint" ]; then
        j=$((i + 1))
        alvo="${!j}"
    fi
done
case "${FINDMNT_PERFIL:-vazio}" in
    bindfs) printf '%s /srv/transito fuse.bindfs rw,nosuid,nodev,noexec,allow_other\n' "$alvo" ;;
    ext4)   printf '%s /dev/sda1 ext4 rw,relatime\n' "$alvo" ;;
    origem) printf '%s /outro/lugar fuse.bindfs rw,nosuid,nodev,noexec\n' "$alvo" ;;
    frouxa) printf '%s /srv/transito fuse.bindfs rw,allow_other\n' "$alvo" ;;
    outro)  printf '/ponto/errado /srv/transito fuse.bindfs rw\n' ;;
    vazio)  : ;;
esac
exit 0
SHIM
chmod +x "$BIN_MNT/findmnt"

executar 'montagem provada' \
    'v_prova_montagem /srv/bind fuse.bindfs /srv/transito noexec nosuid nodev' \
    PATH="$BIN_MNT:$PATH" FINDMNT_PERFIL=bindfs
esperar 'montagem provada' 0 ok 'Montagem em /srv/bind provada'

executar 'nada montado' 'v_prova_montagem /srv/bind fuse.bindfs' \
    PATH="$BIN_MNT:$PATH" FINDMNT_PERFIL=vazio
esperar 'nada montado' 1 pendente 'Nada montado em /srv/bind'

# `mountpoint -q` aprovava este caso: existe montagem, mas não é a esperada.
executar 'tipo divergente' 'v_prova_montagem /srv/bind fuse.bindfs' \
    PATH="$BIN_MNT:$PATH" FINDMNT_PERFIL=ext4
esperar 'tipo divergente' 1 pendente 'é do tipo ext4, esperado fuse.bindfs'

executar 'origem divergente' 'v_prova_montagem /srv/bind fuse.bindfs /srv/transito' \
    PATH="$BIN_MNT:$PATH" FINDMNT_PERFIL=origem
esperar 'origem divergente' 1 pendente 'vem de /outro/lugar'

executar 'opção obrigatória ausente' \
    'v_prova_montagem /srv/bind fuse.bindfs /srv/transito noexec' \
    PATH="$BIN_MNT:$PATH" FINDMNT_PERFIL=frouxa
esperar 'opção obrigatória ausente' 1 pendente "sem a opção obrigatória 'noexec'"

executar 'findmnt respondeu outro ponto' 'v_prova_montagem /srv/bind fuse.bindfs' \
    PATH="$BIN_MNT:$PATH" FINDMNT_PERFIL=outro
esperar 'findmnt respondeu outro ponto' 2 indeterminado 'saída inesperada'

executar 'findmnt ausente' 'v_prova_montagem /srv/bind fuse.bindfs' PATH="$VAZIO"
esperar 'findmnt ausente' 2 indeterminado 'findmnt ausente'

executar 'montagem sem tipo esperado' "v_prova_montagem /srv/bind ''"
esperar 'montagem sem tipo esperado' 3 erro 'exige ponto de montagem e tipo'

# --- vm_existe_estado ---------------------------------------------------------
BIN_VIRSH="$TMP/bin-virsh"
mkdir -p "$BIN_VIRSH"
cat > "$BIN_VIRSH/virsh" <<'SHIM'
#!/bin/bash
case "${VIRSH_PERFIL:-}" in
    existe) printf 'Id: 1\nName: win11\n'; exit 0 ;;
    ausente) printf 'error: Domain not found: no domain with matching name\n' >&2; exit 1 ;;
    semdaemon) printf 'error: failed to connect to the hypervisor\n' >&2; exit 1 ;;
    negado) printf 'error: authentication unavailable: no polkit agent available\n' >&2; exit 1 ;;
esac
exit 1
SHIM
chmod +x "$BIN_VIRSH/virsh"

vm_caso() {
    local descricao="$1" perfil="$2" nome="$3" rc_esperado="$4" trecho="${5:-}"
    local saida="" rc=0
    saida="$( { env PATH="$BIN_VIRSH:$PATH" VIRSH_PERFIL="$perfil" "$BASH_BIN" -c "
        source \"$ROOT/lib/common.sh\"
        rc=0
        vm_existe_estado \"\$1\" || rc=\$?
        printf 'MOTIVO=%s\n' \"\$VM_EXISTE_MOTIVO\"
        exit \"\$rc\"
    " _ "$nome"; } 2>&1 )" || rc=$?
    [ "$rc" -eq "$rc_esperado" ] \
        || fail "$descricao: devolveu $rc, esperado $rc_esperado. Saída: $saida"
    if [ -n "$trecho" ]; then
        printf '%s\n' "$saida" | grep -Fq -- "$trecho" \
            || fail "$descricao: motivo sem '$trecho'. Saída: $saida"
    fi
    CASOS=$((CASOS + 1))
}

vm_caso 'domínio existente' existe win11 0
vm_caso 'domínio ausente' ausente win11 1 'não definido no libvirt'
# A regressão que este helper existe para impedir: libvirtd fora do ar era
# relatado como "a VM não existe", ou seja, pendência em vez de indeterminado.
vm_caso 'libvirt inacessível' semdaemon win11 2 'não respondeu de forma conclusiva'
vm_caso 'permissão negada' negado win11 2 'não respondeu de forma conclusiva'
vm_caso 'nome vazio' existe '' 2 'nome de VM vazio'

rc=0
saida="$( { env PATH="$VAZIO" "$BASH_BIN" -c "
    source \"$ROOT/lib/common.sh\"
    rc=0
    vm_existe_estado win11 || rc=\$?
    printf 'MOTIVO=%s\n' \"\$VM_EXISTE_MOTIVO\"
    exit \"\$rc\"
"; } 2>&1 )" || rc=$?
[ "$rc" -eq 2 ] || fail "vm_existe_estado com virsh ausente devolveu $rc, esperado 2"
printf '%s\n' "$saida" | grep -Fq 'virsh ausente' \
    || fail "vm_existe_estado não informou virsh ausente. Saída: $saida"
CASOS=$((CASOS + 1))

# --- nvidia_smi_comprovado ----------------------------------------------------
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
nvidia_smi_comprovado 'NVIDIA-SMI 550.54.14   Driver Version: 550.54.14   CUDA Version: 12.4' \
    || fail 'nvidia_smi_comprovado recusou saída válida'
CASOS=$((CASOS + 1))
# rc 0 com saída não parseável não é prova de driver.
! nvidia_smi_comprovado '' || fail 'nvidia_smi_comprovado aceitou saída vazia'
CASOS=$((CASOS + 1))
! nvidia_smi_comprovado 'NVIDIA-SMI has failed because it could not communicate' \
    || fail 'nvidia_smi_comprovado aceitou mensagem de falha'
CASOS=$((CASOS + 1))
! nvidia_smi_comprovado 'Driver Version: desconhecida' \
    || fail 'nvidia_smi_comprovado aceitou versão não numérica'
CASOS=$((CASOS + 1))

# --- v_var_definida -----------------------------------------------------------
executar 'variável ausente' 'unset VAR_I9 || true; v_var_definida VAR_I9'
esperar 'variável ausente' 1 pendente 'VAR_I9 ainda não definido.'

executar 'variável definida sem validador' 'VAR_I9=abc; v_var_definida VAR_I9'
esperar 'variável definida sem validador' 0 ok 'VAR_I9=abc'

executar 'formato válido' 'VAR_I9=0000:0c:00.0; v_var_definida VAR_I9 pci_bdf_valido'
esperar 'formato válido' 0 ok 'VAR_I9=0000:0c:00.0'

# Valor presente e inválido é ERRO: reexecutar a etapa não conserta um literal
# fora do formato, então chamar de pendência mandaria o operador ao lugar errado.
executar 'formato inválido' 'VAR_I9=nao-e-bdf; v_var_definida VAR_I9 pci_bdf_valido'
esperar 'formato inválido' 3 erro 'fora do formato aceito'

executar 'validador inexistente' 'VAR_I9=abc; v_var_definida VAR_I9 validador_inexistente_i9'
esperar 'validador inexistente' 2 indeterminado 'indisponível'

executar 'variável sem nome' "v_var_definida ''"
esperar 'variável sem nome' 3 erro 'exige o nome'

# --- invariante estrutural ----------------------------------------------------
for helper in v_exigir_comando v_classificar v_prova_pacote v_prova_arquivo \
              v_prova_montagem vm_existe_estado nvidia_smi_comprovado v_var_definida; do
    declare -F "$helper" >/dev/null || fail "helper $helper desapareceu da fachada"
done
CASOS=$((CASOS + 1))

printf 'OK: helpers de verificação I9.9 aprovados em %d casos\n' "$CASOS"
