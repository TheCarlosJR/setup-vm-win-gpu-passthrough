#!/usr/bin/env bash
# Gate dirigido I9.11: os três defeitos que a revisão semântica do Gate I9
# encontrou (regra 15 da seção 0.1 do PLANO-FINALIZACAO.md).
#
# Cada bloco abaixo reproduz o cenário concreto que o defeito produzia na
# árvore de 91cd349, no espírito do que I7.8 fez para o rollback de rede. A
# ordem é a mesma do registro da fase:
#
#   1. lib/shell/waivers.sh validava o nome da flag pelo glob *_DISPENSADO.
#      '1_DISPENSADO' casa o glob e NÃO é identificador do bash, então
#      ${!flag} abortava o corpo da função. Corpo abortado por erro de
#      expansão não devolve o código de recusa: waiver_estado publicava 0
#      ("há dispensa declarada E ativa") com todos os campos vazios. O
#      fail-closed do módulo ficava exatamente invertido, e o gate era mais
#      estrito que o runtime (tests/check-waivers-matrix.py já exigia
#      ^[A-Z][A-Z0-9_]*_DISPENSADO$).
#   2. menu.sh afirmava "A etapa não foi executada" no ramo de status 0 com
#      dispensa ativa. A afirmação era falsa em todos os casos que chegam ao
#      ramo: a única etapa da matriz que recusa sem efeito sai por
#      cancelar_etapa (código 20), tratado no ramo seguinte.
#   3. etapas/02-detectar-config.sh usava `[ -f x ] && v_ok`, o padrão que
#      REQ-VERIFY-FAILCLOSED existe para eliminar. Aqui ele estava LATENTE, e
#      o teste registra isso em vez de inventar um falso sucesso: qualquer
#      passthrough.conf inutilizável é recusado por carregar_conf antes de
#      verificar() rodar. O que a correção entrega é a eliminação do padrão,
#      a distinção entre ausente/ilegível/não-regular e uma invariante
#      estática que impede o padrão de voltar em qualquer verificador.
#
# Hermético: nenhuma etapa real muta o host; tudo roda sob um TMP próprio com
# HOME e XDG_STATE_HOME desviados.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

fail() { printf 'FALHA I9.11: %s\n' "$*" >&2; exit 1; }
BASH_BIN="${BASH:-/bin/bash}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/i9-semantica.XXXXXXXX")
trap 'rm -rf -- "$TMP"' EXIT HUP INT TERM
CASOS=0

# ============================================================================
# Defeito 1: leitor de dispensa fail-closed sob nome de flag hostil
# ============================================================================
# Cada consulta roda em processo próprio: o módulo memoriza a matriz em
# WAIVERS_MATRIZ_CARREGADA e reusar o shell mascararia erro de carga.
consultar() {
    local matriz="$1" etapa="$2"
    shift 2
    local rc=0 saida=""
    saida="$( { env "$@" "$BASH_BIN" -c "
        source \"$ROOT/lib/common.sh\"
        WAIVERS_MATRIZ_ARQUIVO='$matriz'
        rc=0
        waiver_estado '$etapa' || rc=\$?
        printf 'RC=%s ATIVA=%s CHAVE=%s ERRO=%s\n' \
            \"\$rc\" \"\$WAIVER_ATIVA\" \"\$WAIVER_CHAVE\" \"\$WAIVER_ERRO\"
    "; } 2>&1 )" || rc=$?
    [ "$rc" -eq 0 ] || fail "a consulta abortou (código $rc): $saida"
    printf '%s\n' "$saida" | tail -n 1
}

matriz_com_flag() {
    local nome="$1" arquivo="$TMP/matriz-$2.tsv"
    {
        printf '# schema_version=1\n'
        printf '14-working-disk.sh\t%s\tescolha-de-modo\tworkingdisk-montado\tdisp\tfatal\n' "$nome"
    } > "$arquivo"
    printf '%s\n' "$arquivo"
}

flag_recusada() {
    local nome="$1" rotulo="$2" arquivo r
    shift 2
    arquivo="$(matriz_com_flag "$nome" "$rotulo")"
    r="$(consultar "$arquivo" 14-working-disk.sh "$@")"
    case "$r" in
        RC=2*) ;;
        *) fail "flag '$nome' não foi recusada com indeterminado: $r" ;;
    esac
    printf '%s' "$r" | grep -q 'ATIVA=0' \
        || fail "flag '$nome' publicou dispensa ativa: $r"
    printf '%s' "$r" | grep -q 'ERRO=$' \
        && fail "flag '$nome' foi recusada sem diagnóstico: $r"
    CASOS=$((CASOS + 1))
}

# O caso que reproduzia o defeito. Antes da correção: 'RC=0 ATIVA=0 CHAVE= ERRO='.
flag_recusada '1_DISPENSADO' digito 1_DISPENSADO=sim
# Sem prefixo: '_DISPENSADO' é identificador válido do bash, mas está fora do
# padrão que o gate exige, e o runtime tem de recusar o mesmo conjunto.
flag_recusada '_DISPENSADO' sem-prefixo
# Minúscula e hífen: nenhum dos dois é chave de passthrough.conf.
flag_recusada 'working_disk_DISPENSADO' minuscula
flag_recusada 'WORKING-DISK_DISPENSADO' hifen
# Letra acentuada sob locale UTF-8. Faixa [A-Z] em padrão do bash depende da
# collation e aceitaria 'Í' aqui; o módulo enumera os caracteres justamente
# porque o menu roda no locale do operador, não no LC_ALL=C do gate.
flag_recusada 'WORKING_DÍSK_DISPENSADO' acento LC_ALL=C.UTF-8

# A correção não pode ter fechado o caminho legítimo.
r="$(consultar "$ROOT/lib/policy/waivers.tsv" 14-working-disk.sh WORKING_DISK_DISPENSADO=sim)"
[ "$r" = 'RC=0 ATIVA=1 CHAVE=WORKING_DISK_DISPENSADO ERRO=' ] \
    || fail "a dispensa legítima parou de resolver: $r"
CASOS=$((CASOS + 1))

# Segunda camada: WAIVERS_LINHAS é estado de processo, e a expansão indireta é
# o único ponto do módulo capaz de abortar o corpo da função. Mesmo com a
# matriz já marcada como carregada, um registro hostil tem de dar 2, não 0.
r="$( { "$BASH_BIN" -c "
    source \"$ROOT/lib/common.sh\"
    WAIVERS_MATRIZ_CARREGADA=1
    WAIVERS_LINHAS=('14-working-disk.sh|9_DISPENSADO|escolha-de-modo|x|disp|fatal')
    rc=0
    waiver_estado 14-working-disk.sh || rc=\$?
    printf 'RC=%s ATIVA=%s\n' \"\$rc\" \"\$WAIVER_ATIVA\"
"; } 2>&1 | tail -n 1 )"
[ "$r" = 'RC=2 ATIVA=0' ] \
    || fail "a leitura direta de registro hostil não foi fail-closed: $r"
CASOS=$((CASOS + 1))

# ============================================================================
# Defeito 2: o que o menu afirma depois de executar uma etapa dispensada
# ============================================================================
# Projeto encenado com as 21 etapas e os 6 utilitários como stubs. A etapa 8 é
# a única linha da matriz sem capability em menu.sh, então ela exercita o ramo
# de status 0 sem passar por guard_mutation. O stub responde 0 no lugar dos
# 50/61/70, que são as etapas que realmente chegam a esse ramo rodando até o
# fim e mutando o host.
PROJ="$TMP/projeto"
mkdir -p "$PROJ/etapas" "$PROJ/util" "$TMP/home" "$TMP/state"
cp -a -- "$ROOT/lib" "$PROJ/lib"
cp -a -- "$ROOT/libexec" "$PROJ/libexec"
cp -- "$ROOT/menu.sh" "$PROJ/menu.sh"
stub_etapa() {
    local destino="$1" codigo="$2"
    cat > "$destino" <<STUB
#!/bin/bash
SCRIPT_VERSION="1.0.0"
set -uo pipefail
source "\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
[ "\${1:-}" = "--verificar" ] && { v_ok "stub"; v_fim; }
exit $codigo
STUB
}
for origem in "$ROOT"/etapas/*.sh; do
    stub_etapa "$PROJ/etapas/$(basename -- "$origem")" 0
done
for origem in "$ROOT"/util/*.sh; do
    printf '#!/bin/bash\nSCRIPT_VERSION="1.0.0"\nexit 0\n' \
        > "$PROJ/util/$(basename -- "$origem")"
done

menu_executa() {
    # menu_executa ESCOLHA CONF -> saída sem cor, com MENU_RC na última linha
    local escolha="$1" conf="$2" saida="" rc=0
    printf '%s' "$conf" > "$PROJ/passthrough.conf"
    chmod 600 "$PROJ/passthrough.conf"
    saida="$( {
        cd "$PROJ" && printf '%s\nq\n' "$escolha" \
            | env HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" \
                  VM_PASSTHROUGH_LOG=0 \
                  timeout 180 "$BASH_BIN" menu.sh
    } 2>&1 )" || rc=$?
    printf '%s\nMENU_RC=%s\n' "$saida" "$rc" | sed 's/\x1b\[[0-9;]*m//g'
}

CONF_BASE='USUARIO_LINUX="alice"
VM_NAME="fixture"
'
COM_DISPENSA="$(menu_executa 8 "${CONF_BASE}WORKING_DISK_DISPENSADO=\"sim\"
")"

# A frase falsa não pode voltar em nenhuma redação.
printf '%s\n' "$COM_DISPENSA" | grep -Fq 'A etapa não foi executada' \
    && fail 'o menu voltou a afirmar que a etapa dispensada não foi executada'
CASOS=$((CASOS + 1))
printf '%s\n' "$COM_DISPENSA" | grep -Fq 'Nada a executar' \
    && fail 'o menu voltou a afirmar que não havia nada a executar'
CASOS=$((CASOS + 1))
# E o que sobra tem de nomear a dispensa como decisão consciente, sem chamar o
# recurso dispensado de comprovado (REQ-WAIVERS: nunca "executada/concluída").
printf '%s\n' "$COM_DISPENSA" | grep -Fq 'conscientemente dispensado' \
    || fail "o menu não informou a dispensa após a execução: $COM_DISPENSA"
CASOS=$((CASOS + 1))
printf '%s\n' "$COM_DISPENSA" | grep -Fq 'continua sem comprovação' \
    || fail 'o menu não negou a comprovação do recurso dispensado'
CASOS=$((CASOS + 1))
printf '%s\n' "$COM_DISPENSA" | grep -Fq 'Execução concluída.' \
    && fail 'o menu chamou de concluída uma execução com dispensa ativa'
CASOS=$((CASOS + 1))

# Sem dispensa o ramo normal continua intacto.
SEM_DISPENSA="$(menu_executa 8 "$CONF_BASE")"
printf '%s\n' "$SEM_DISPENSA" | grep -Fq 'Execução concluída.' \
    || fail "o ramo sem dispensa parou de reportar conclusão: $SEM_DISPENSA"
printf '%s\n' "$SEM_DISPENSA" | grep -Fq 'conscientemente dispensado' \
    && fail 'o menu informou dispensa sem dispensa registrada'
CASOS=$((CASOS + 2))

# A etapa 8 real recusa sem efeito por cancelar_etapa, que sai com 20. Esse é
# o ramo que ela toma de verdade, e ele não pode ser confundido com o de cima.
stub_etapa "$PROJ/etapas/14-working-disk.sh" 20
CANCELADA="$(menu_executa 8 "${CONF_BASE}WORKING_DISK_DISPENSADO=\"sim\"
")"
printf '%s\n' "$CANCELADA" | grep -Fq 'Execução cancelada' \
    || fail "a recusa sem efeito não caiu no ramo de cancelamento: $CANCELADA"
printf '%s\n' "$CANCELADA" | grep -Fq 'conscientemente dispensado' \
    && fail 'o ramo de cancelamento reportou a mensagem de dispensa'
CASOS=$((CASOS + 2))
stub_etapa "$PROJ/etapas/14-working-disk.sh" 0

# ============================================================================
# Defeito 3: nenhum verificador aprova por teste de arquivo isolado
# ============================================================================
# Invariante estática, e não um caso reproduzido: o padrão `[ -f x ] && v_ok`
# afirma "existe" a partir de um teste que também é verdadeiro para arquivo
# ilegível ou de outra geração, e é falso para link quebrado que existe. Os
# demais `&& v_ok` da árvore comparam VALOR ou chamam função de prova
# (validar_iso_configurada, mac_valido), e continuam permitidos.
alvos=("$ROOT/menu.sh")
while IFS= read -r -d '' arquivo; do
    alvos+=("$arquivo")
done < <(find "$ROOT/etapas" "$ROOT/util" "$ROOT/lib" -name '*.sh' -print0 | sort -z)
PADRAO='\[{1,2}[[:space:]]+-[abcdefghkprsuwxGLNOS][[:space:]]+[^]]*\]{1,2}[[:space:]]*&&[[:space:]]*v_(ok|prova)'
achados="$TMP/fail-open.txt"
: > "$achados"
for arquivo in "${alvos[@]}"; do
    # Esvazia comentário de linha inteira antes de casar: este próprio teste e
    # o cabeçalho de v_prova_arquivo CITAM o padrão proibido em prosa, e uma
    # invariante que reprova a documentação do defeito é ruído, não prova.
    # Depois junta continuação de linha: a mesma construção quebrada em duas
    # linhas é o mesmo defeito.
    LC_ALL=C sed -e 's/^[[:space:]]*#.*$//' -- "$arquivo" \
        | LC_ALL=C sed -e ':a' -e '/\\$/N; s/\\\n//; ta' \
        | LC_ALL=C grep -nE "$PADRAO" \
        | sed "s|^|${arquivo#"$ROOT/"}:|" >> "$achados" || true
done
if [ -s "$achados" ]; then
    cat -- "$achados" >&2
    fail 'verificador aprovando por teste de arquivo isolado (REQ-VERIFY-FAILCLOSED)'
fi
CASOS=$((CASOS + 1))

# O padrão precisa ser capaz de acusar: sem esta prova, um erro de escrita na
# expressão transformaria a invariante em teste que nunca reprova.
SENTINELA="$TMP/sentinela.sh"
printf '%s\n' '[ -f "$CONF_ARQUIVO" ] && v_ok "existe." || v_falta "não existe."' > "$SENTINELA"
LC_ALL=C grep -qE "$PADRAO" -- "$SENTINELA" \
    || fail 'a invariante estática não acusa o padrão que ela existe para proibir'
CASOS=$((CASOS + 1))
printf '%s\n' '[ -f "$x" ] \' > "$SENTINELA"
printf '%s\n' '    && v_ok "existe."' >> "$SENTINELA"
LC_ALL=C sed -e ':a' -e '/\\$/N; s/\\\n//; ta' -- "$SENTINELA" \
    | LC_ALL=C grep -qE "$PADRAO" \
    || fail 'a invariante estática não acusa o padrão quebrado em duas linhas'
CASOS=$((CASOS + 1))
# E não pode acusar as formas legítimas.
printf '%s\n' '[ -n "$VM_NIC_MAC" ] && v_ok "definido." || v_falta "ausente."' > "$SENTINELA"
printf '%s\n' 'mac_valido "$VM_NIC_MAC" && v_ok "MAC ok" || v_falta "MAC inválido"' >> "$SENTINELA"
printf '%s\n' '[ "${VM_IP_FIXO:-}" = "$NAT_VM_IP" ] && v_ok "IP ok" || v_falta "IP errado"' >> "$SENTINELA"
LC_ALL=C grep -qE "$PADRAO" -- "$SENTINELA" \
    && fail 'a invariante estática acusou comparação de valor ou função de prova'
CASOS=$((CASOS + 1))

# Prova positiva de que a etapa 3 passou a usar o helper: com a configuração
# ausente, a linha nomeia o caminho, que é o que v_prova_arquivo acrescenta.
# (Com a configuração inutilizável, carregar_conf recusa antes de verificar()
# rodar; é por isso que o defeito era latente e não há caso de falso sucesso a
# reproduzir aqui.)
PROJ3="$TMP/projeto-etapa3"
mkdir -p "$PROJ3/etapas"
cp -a -- "$ROOT/lib" "$PROJ3/lib"
cp -a -- "$ROOT/libexec" "$PROJ3/libexec"
cp -- "$ROOT/etapas/02-detectar-config.sh" "$PROJ3/etapas/"
# A legenda e a mensagem de status 0 não podem afirmar, em nenhuma
# capitalização, que a etapa não foi executada.
printf '%s\n' "$COM_DISPENSA" | grep -Fiq 'não executada' \
    && fail 'o menu voltou a afirmar que a etapa dispensada não foi executada'
CASOS=$((CASOS + 1))

TOKEN_STATUS='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
rc_etapa3=0
saida_etapa3="$( { cd "$PROJ3" && env HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" \
    V_STATUS_TOKEN="$TOKEN_STATUS" timeout 180 "$BASH_BIN" \
    etapas/02-detectar-config.sh --verificar; } 2>&1 )" || rc_etapa3=$?
case "$rc_etapa3" in
    1|2|3) ;;
    *) fail "a etapa 3 não terminou pelo contrato público 1/2/3: rc=$rc_etapa3 saída=$saida_etapa3" ;;
esac
printf '%s\n' "$saida_etapa3" \
    | grep -Fq "passthrough.conf ausente ($PROJ3/passthrough.conf)" \
    || fail "a etapa 3 não usou v_prova_arquivo para o passthrough.conf: $saida_etapa3"
CASOS=$((CASOS + 1))
printf '%s\n' "$saida_etapa3" \
    | grep -Fq "__PASSTHROUGH_STATUS_V1__:${TOKEN_STATUS}:${rc_etapa3}" \
    || fail "a etapa 3 saiu antes de v_fim ou publicou status divergente: rc=$rc_etapa3 saída=$saida_etapa3"
CASOS=$((CASOS + 1))
printf '%s\n' "$saida_etapa3" | grep -Fq 'passthrough.conf existe.' \
    && fail 'a etapa 3 voltou a afirmar existência sem prova'
CASOS=$((CASOS + 1))

printf 'OK: revisão semântica I9.11 aprovada em %d casos\n' "$CASOS"
