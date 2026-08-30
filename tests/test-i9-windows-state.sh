#!/usr/bin/env bash
# Gate dirigido I9.7: REQ-WINDOWS-STATE, instalação/power/agent independentes.
#
# O que este teste protege: a conclusão sobre "o Windows está instalado" passa a
# vir de evidência DURÁVEL gravada na metadata namespaced do XML inativo e
# vinculada à identidade do arquivo QCOW2. Desligar a VM ou perder o guest agent
# não pode mais derrubar essa conclusão, e nenhuma evidência pode ser atribuída
# ao disco errado.
#
# Hermético por construção: nenhum virsh, qemu-img, libvirt, sudo ou VM real. A
# etapa 13 roda dentro de uma raiz de projeto própria (lib e libexec chegam por
# symlink, a configuração é sintética) com PATH controlado, e todos os eixos são
# encenados por shims. Nada toca o host.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
BASH_BIN="${BASH:-/bin/bash}"

fail() { printf 'FALHA I9.7: %s\n' "$*" >&2; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/i9-windows-state.XXXXXXXX")
trap 'python_core_temporarios_limpar 2>/dev/null || true; rm -rf -- "$TMP"' EXIT HUP INT TERM

CASOS=0

# --- Raiz de projeto sintética -----------------------------------------------
PROJ="$TMP/proj"
mkdir -p "$PROJ/etapas" "$PROJ/lib"
cp -- "$ROOT/etapas/41-instalacao-windows.sh" "$PROJ/etapas/41-instalacao-windows.sh"
ETAPA="$PROJ/etapas/41-instalacao-windows.sh"
# Fachada do projeto sintético: a real, mais um double de `carregar_conf`. O
# schema de configuração exige QCOW2_PATH como filho direto de `/vm`, caminho
# que um teste hermético não pode criar; a leitura e validação da configuração
# já são cobertas pelo gate de I4. Tudo o mais vem do arquivo real.
cat > "$PROJ/lib/common.sh" <<FACHADA
source "$ROOT/lib/common.sh"
carregar_conf() {
    VM_NAME="\${WSTATE_VM_NAME-}"
    QCOW2_PATH="\${WSTATE_QCOW2-}"
}
# Doubles do caminho mutante. A guarda de plataforma e a confirmação já têm
# gates próprios (I8 e I1); aqui elas só não podem exigir hardware real nem
# escrever log no checkout. O backup de XML é desviado para o TMP do teste.
guard_mutation() { return 0; }
confirmar() { [ "\${WSTATE_CONFIRMA:-nao}" = sim ]; }
BACKUPS_DIR="$TMP/backups"
FACHADA

# --- Shims de host ------------------------------------------------------------
BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/virsh" <<'SHIM'
#!/bin/bash
# Shim hermético: nenhum libvirt é contatado. Todo comportamento vem do
# ambiente, para que cada caso encene um ponto exato da matriz.
[ "${1:-}" = "--connect" ] && shift 2
sub="${1:-}"
shift || true
case "$sub" in
    dominfo)
        case "${WSTATE_VM:-existe}" in
            existe) printf 'Id: 1\nName: win11-teste\n'; exit 0 ;;
            ausente) printf 'error: failed to get domain: Domain not found: no domain with matching name\n' >&2; exit 1 ;;
            *) printf 'error: failed to connect to the hypervisor\n' >&2; exit 1 ;;
        esac
        ;;
    domstate)
        if [ "${WSTATE_POWER:-shut off}" = FAIL ]; then
            printf 'error: failed to get domain state\n' >&2
            exit 1
        fi
        printf '%s\n' "${WSTATE_POWER:-shut off}"
        exit 0
        ;;
    dumpxml)
        if [ "${WSTATE_XML:-}" = FAIL ] || [ ! -f "${WSTATE_XML:-}" ]; then
            printf 'error: failed to get domain xml\n' >&2
            exit 1
        fi
        cat -- "$WSTATE_XML"
        exit 0
        ;;
    qemu-agent-command)
        case "${WSTATE_AGENT:-fail}" in
            ok) printf '{"return":{}}\n'; exit 0 ;;
            lixo) printf 'resposta fora do contrato\n'; exit 0 ;;
            *) printf 'error: Guest agent is not responding: QEMU guest agent is not connected\n' >&2; exit 1 ;;
        esac
        ;;
    help) printf '  --validate\n'; exit 0 ;;
    define)
        arq=""
        for argumento in "$@"; do
            case "$argumento" in --*) ;; *) arq="$argumento" ;; esac
        done
        [ -n "$arq" ] || exit 1
        if [ "${WSTATE_DEFINE:-ok}" = FAIL ]; then
            printf 'error: virsh define recusou o XML\n' >&2
            exit 1
        fi
        # Encena UMA vez um define que retorna zero sem aplicar a metadata: é
        # a falha que um "rc 0 é prova" não detectaria.
        if [ -n "${WSTATE_DEFINE_MUDO:-}" ] && [ -e "$WSTATE_DEFINE_MUDO" ]; then
            rm -f -- "$WSTATE_DEFINE_MUDO"
            sed 's|windows-install|windows-instalX|g' -- "$arq" > "$WSTATE_XML"
            exit 0
        fi
        cp -- "$arq" "$WSTATE_XML"
        exit 0
        ;;
esac
exit 1
SHIM
cat > "$BIN/qemu-img" <<'SHIM'
#!/bin/bash
# Só `info --output=json` é encenado; nenhuma imagem é lida.
if [ "${WSTATE_QEMUIMG:-ok}" = FAIL ]; then
    printf 'qemu-img: unable to open image\n' >&2
    exit 1
fi
printf '{"virtual-size":68719476736,"filename":"imagem","cluster-size":65536,'
printf '"format":"%s","actual-size":1234567}\n' "${WSTATE_FORMAT:-qcow2}"
SHIM
cat > "$BIN/virt-xml-validate" <<'SHIM'
#!/bin/bash
# O schema real do libvirt não está disponível em ambiente hermético; a
# validação de schema tem gate próprio na qualificação com libvirt instalado.
[ "${WSTATE_VALIDATE:-ok}" = FAIL ] && exit 1
exit 0
SHIM
cat > "$BIN/systemctl" <<'SHIM'
#!/bin/bash
exit 1
SHIM
cat > "$BIN/virt-manager" <<'SHIM'
#!/bin/bash
exit 0
SHIM
chmod +x "$BIN/virsh" "$BIN/qemu-img" "$BIN/virt-xml-validate" \
    "$BIN/systemctl" "$BIN/virt-manager"
mkdir -p "$TMP/backups"
PATH="$BIN:$PATH"
export PATH

# --- Fachada carregada no processo do teste ----------------------------------
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

DISCO_A="$TMP/disco-a.qcow2"
DISCO_B="$TMP/disco-b.qcow2"
printf 'qcow2 sintetico A\n' > "$DISCO_A"
printf 'qcow2 sintetico B\n' > "$DISCO_B"

export WSTATE_FORMAT=qcow2

# --- Identidade do QCOW2 ------------------------------------------------------
qcow2_identidade_digest "$DISCO_A" \
    || fail "identidade do disco A recusada: $QCOW2_IDENTIDADE_ERRO"
DIGEST_A="$QCOW2_IDENTIDADE_DIGEST"
BASE_A="$QCOW2_IDENTIDADE_BASE"
KIND_A="$QCOW2_IDENTIDADE_KIND"
[[ $DIGEST_A =~ ^[0-9a-f]{64}$ ]] || fail 'digest de identidade fora do formato sha256'
[[ $KIND_A == inode || $KIND_A == inode+birth ]] || fail "identity_kind inesperado: $KIND_A"
CASOS=$((CASOS + 1))

qcow2_identidade_digest "$DISCO_B" \
    || fail "identidade do disco B recusada: $QCOW2_IDENTIDADE_ERRO"
DIGEST_B="$QCOW2_IDENTIDADE_DIGEST"
[ "$DIGEST_A" != "$DIGEST_B" ] || fail 'dois arquivos distintos produziram a mesma identidade'
CASOS=$((CASOS + 1))

# Reexecução sobre o mesmo arquivo é estável: identidade não pode oscilar entre
# duas leituras, senão a evidência gravada nunca conferiria.
qcow2_identidade_digest "$DISCO_A" || fail 'segunda medição do disco A falhou'
[ "$QCOW2_IDENTIDADE_DIGEST" = "$DIGEST_A" ] || fail 'identidade do mesmo arquivo oscilou entre leituras'
CASOS=$((CASOS + 1))

# Formato diferente de qcow2 é recusado pelo core, não aceito em silêncio.
WSTATE_FORMAT=raw
if qcow2_identidade_digest "$DISCO_A"; then
    fail 'imagem raw foi aceita como identidade de QCOW2'
fi
[ -n "$QCOW2_IDENTIDADE_ERRO" ] || fail 'recusa de formato não produziu diagnóstico'
WSTATE_FORMAT=qcow2
CASOS=$((CASOS + 1))

# qemu-img sem resposta é NÃO OBSERVÁVEL (retorno 1), nunca erro de dado.
WSTATE_QEMUIMG=FAIL
export WSTATE_QEMUIMG
RC_ID=0
qcow2_identidade_digest "$DISCO_A" || RC_ID=$?
[ "$RC_ID" -eq 1 ] || fail "qemu-img mudo devolveu $RC_ID, esperado 1 (não observável)"
unset WSTATE_QEMUIMG
CASOS=$((CASOS + 1))

# Arquivo ausente também é não observável, não pendência silenciosa.
RC_ID=0
qcow2_identidade_digest "$TMP/nao-existe.qcow2" || RC_ID=$?
[ "$RC_ID" -eq 1 ] || fail "QCOW2 ausente devolveu $RC_ID, esperado 1"
CASOS=$((CASOS + 1))

# --- Identidade com e sem birth, direto no core ------------------------------
declare -a ID_PERMITIDAS=(
    "${CORE_PARES_ENVELOPE[@]}"
    IDENTITY_DIGEST IDENTITY_DIGEST_BASE IDENTITY_KIND IDENTITY_BIRTH
)
declare -a ID_PAYLOAD=(
    path /vm/win11.qcow2 device 47 inode 65649 birth '' format qcow2
)
python_core_pares_payload ID_PERMITIDAS SEMB_ qemu-image-identity ID_PAYLOAD \
    || fail "identidade sem birth recusada: $PYTHON_CORE_ERRO"
[ "$SEMB_IDENTITY_KIND" = inode ] || fail 'birth ausente não produziu kind inode'
[ "$SEMB_IDENTITY_BIRTH" = '-' ] || fail 'birth ausente não foi canonicalizado como -'
[ "$SEMB_IDENTITY_DIGEST" = "$SEMB_IDENTITY_DIGEST_BASE" ] \
    || fail 'sem birth o digest deveria coincidir com o digest base'
CASOS=$((CASOS + 1))

# Birth explicitamente '-' (o que `stat -c %w` devolve no NTFS/fuseblk deste
# checkout) precisa produzir exatamente a mesma identidade do birth vazio: a
# ausência de birth nunca pode invalidar evidência já gravada.
ID_PAYLOAD=(path /vm/win11.qcow2 device 47 inode 65649 birth '-' format qcow2)
python_core_pares_payload ID_PERMITIDAS TRACO_ qemu-image-identity ID_PAYLOAD \
    || fail "identidade com birth '-' recusada: $PYTHON_CORE_ERRO"
[ "$TRACO_IDENTITY_DIGEST" = "$SEMB_IDENTITY_DIGEST" ] \
    || fail "birth '-' e birth vazio produziram identidades diferentes"
CASOS=$((CASOS + 1))

ID_PAYLOAD=(
    path /vm/win11.qcow2 device 47 inode 65649 birth 20260817-120000 format qcow2
)
python_core_pares_payload ID_PERMITIDAS COMB_ qemu-image-identity ID_PAYLOAD \
    || fail "identidade com birth recusada: $PYTHON_CORE_ERRO"
[ "$COMB_IDENTITY_KIND" = 'inode+birth' ] || fail 'birth presente não produziu kind inode+birth'
[ "$COMB_IDENTITY_DIGEST" != "$SEMB_IDENTITY_DIGEST" ] \
    || fail 'birth não participou do digest forte'
[ "$COMB_IDENTITY_DIGEST_BASE" = "$SEMB_IDENTITY_DIGEST" ] \
    || fail 'digest base deixou de ser independente do birth'
CASOS=$((CASOS + 1))

# --- Fixtures de XML ----------------------------------------------------------
CANAL="<channel type='unix'><target type='virtio' name='org.qemu.guest_agent.0'/></channel>"
NS='https://github.com/vm-passthrough/metadata/1'

xml_domain() {
    # xml_domain DESTINO METADATA CANAL_SIM_NAO
    local destino="$1" metadata="$2" canal="$3"
    {
        printf "<domain type='kvm'><name>win11-teste</name>"
        printf "<memory unit='MiB'>8192</memory><vcpu>4</vcpu>"
        printf '%s' "$metadata"
        printf '<devices>'
        printf "<disk type='file' device='disk'><driver name='qemu' type='qcow2'/>"
        printf "<source file='%s'/><target dev='vda' bus='virtio'/></disk>" "$DISCO_A"
        if [ "$canal" = sim ]; then printf '%s' "$CANAL"; fi
        printf '</devices></domain>\n'
    } > "$destino"
}

metadata_install() {
    # metadata_install DIGEST QUANDO ORIGEM [EXTRA]
    printf "<metadata>%s<vmpass:passthrough xmlns:vmpass='%s'>" "${4:-}" "$NS"
    printf "<vmpass:windows-install qcow2-digest='%s' recorded-at='%s' source='%s'/>" \
        "$1" "$2" "$3"
    printf '</vmpass:passthrough></metadata>'
}

XML_SEM_EVIDENCIA="$TMP/sem-evidencia.xml"
XML_SEM_CANAL="$TMP/sem-canal.xml"
XML_REGISTRADA="$TMP/registrada.xml"
XML_DIVERGENTE="$TMP/divergente.xml"
XML_INVALIDA="$TMP/invalida.xml"
XML_TERCEIROS="$TMP/terceiros.xml"

xml_domain "$XML_SEM_EVIDENCIA" '' sim
xml_domain "$XML_SEM_CANAL" '' nao
xml_domain "$XML_REGISTRADA" "$(metadata_install "$DIGEST_A" 20260830-101500 operador)" sim
xml_domain "$XML_DIVERGENTE" "$(metadata_install "$DIGEST_B" 20260830-101500 operador)" sim
xml_domain "$XML_INVALIDA" "$(metadata_install "$DIGEST_A" ontem operador)" sim
xml_domain "$XML_TERCEIROS" \
    "$(metadata_install "$DIGEST_A" 20260830-101500 operador "<outra:coisa xmlns:outra='https://exemplo/1'/>")" sim

# --- Leitura da metadata pela fachada -----------------------------------------
RC=0
xml_metadata_instalacao "$XML_REGISTRADA" "$DIGEST_A" || RC=$?
[ "$RC" -eq 0 ] && [ "$WINDOWS_INSTALL_ESTADO" = registrada ] \
    || fail "metadata válida não foi lida como registrada (rc $RC, estado $WINDOWS_INSTALL_ESTADO)"
[ "$WINDOWS_INSTALL_QUANDO" = 20260830-101500 ] || fail 'data da evidência não foi publicada'
[ "$WINDOWS_INSTALL_ORIGEM" = operador ] || fail 'origem da evidência não foi publicada'
CASOS=$((CASOS + 1))

RC=0
xml_metadata_instalacao "$XML_SEM_EVIDENCIA" "$DIGEST_A" || RC=$?
[ "$RC" -eq 1 ] && [ "$WINDOWS_INSTALL_ESTADO" = ausente ] \
    || fail "XML sem evidência não foi lido como ausente (rc $RC, estado $WINDOWS_INSTALL_ESTADO)"
CASOS=$((CASOS + 1))

RC=0
xml_metadata_instalacao "$XML_DIVERGENTE" "$DIGEST_A" || RC=$?
[ "$RC" -eq 2 ] && [ "$WINDOWS_INSTALL_ESTADO" = divergente ] \
    || fail "evidência de outro disco não foi lida como divergente (rc $RC, estado $WINDOWS_INSTALL_ESTADO)"
CASOS=$((CASOS + 1))

RC=0
xml_metadata_instalacao "$XML_INVALIDA" "$DIGEST_A" || RC=$?
[ "$RC" -eq 3 ] && [ "$WINDOWS_INSTALL_ESTADO" = invalida ] \
    || fail "metadata fora do schema não foi lida como inválida (rc $RC, estado $WINDOWS_INSTALL_ESTADO)"
CASOS=$((CASOS + 1))

RC=0
xml_metadata_instalacao "$TMP/nao-existe.xml" "$DIGEST_A" || RC=$?
[ "$RC" -eq 3 ] && [ "$WINDOWS_INSTALL_ESTADO" = erro ] \
    || fail "XML ilegível não virou erro (rc $RC, estado $WINDOWS_INSTALL_ESTADO)"
CASOS=$((CASOS + 1))

# Evidência presente sem digest para confrontar não pode virar veredicto.
RC=0
xml_metadata_instalacao "$XML_REGISTRADA" || RC=$?
[ "$RC" -eq 3 ] && [ "$WINDOWS_INSTALL_ESTADO" = erro ] \
    || fail "evidência sem identidade informada virou veredicto (rc $RC, estado $WINDOWS_INSTALL_ESTADO)"
CASOS=$((CASOS + 1))

# Metadata de terceiros é contada e preservada na leitura.
RC=0
xml_metadata_instalacao "$XML_TERCEIROS" "$DIGEST_A" || RC=$?
[ "$RC" -eq 0 ] || fail 'metadata de terceiros atrapalhou a leitura da evidência'
[ "${WINDOWS_INSTALL_TERCEIROS:-0}" -eq 1 ] \
    || fail "metadata de terceiros não foi contada (foreign_child_count=$WINDOWS_INSTALL_TERCEIROS)"
CASOS=$((CASOS + 1))

# --- Candidato: grava, preserva terceiros e é idempotente ---------------------
CAND1="$TMP/candidato-1.xml"
CAND2="$TMP/candidato-2.xml"
xml_candidato_instalacao "$XML_SEM_EVIDENCIA" "$CAND1" "$DIGEST_A" 20260830-120000 operador \
    || fail "candidato de metadata recusado: $XML_CANDIDATO_ERRO"
[ "$XML_CANDIDATO_MUDOU" = 1 ] || fail 'o primeiro candidato não mudou o XML'
[ "$(stat -c '%a' -- "$CAND1")" = 600 ] || fail 'candidato não foi publicado em 0600'
RC=0
xml_metadata_instalacao "$CAND1" "$DIGEST_A" || RC=$?
[ "$RC" -eq 0 ] || fail 'o candidato gerado não comprova a evidência que declarou gravar'
CASOS=$((CASOS + 1))

# Segunda execução sobre estado convergido é no-op exato (regra 17).
xml_candidato_instalacao "$CAND1" "$CAND2" "$DIGEST_A" 20260830-120000 operador \
    || fail "segundo candidato recusado: $XML_CANDIDATO_ERRO"
[ "$XML_CANDIDATO_MUDOU" = 0 ] || fail 'a segunda geração do candidato não foi no-op'
cmp -s -- "$CAND1" "$CAND2" || fail 'a segunda geração do candidato mudou bytes'
CASOS=$((CASOS + 1))

# Metadata de terceiros sobrevive à gravação da evidência.
CAND3="$TMP/candidato-3.xml"
XML_SO_TERCEIROS="$TMP/so-terceiros.xml"
xml_domain "$XML_SO_TERCEIROS" \
    "<metadata><outra:coisa xmlns:outra='https://exemplo/1'/></metadata>" sim
xml_candidato_instalacao "$XML_SO_TERCEIROS" "$CAND3" "$DIGEST_A" 20260830-120000 operador \
    || fail "candidato sobre metadata de terceiros recusado: $XML_CANDIDATO_ERRO"
# O prefixo do namespace é reescrito pelo serializador; o que precisa
# sobreviver é o namespace e o elemento, não o apelido escolhido pelo autor.
grep -Fq 'https://exemplo/1' -- "$CAND3" || fail 'namespace de terceiros foi destruído pelo candidato'
grep -Eq '[:<]coisa' -- "$CAND3" || fail 'elemento de terceiros foi destruído pelo candidato'
RC=0
xml_metadata_instalacao "$CAND3" "$DIGEST_A" || RC=$?
[ "$RC" -eq 0 ] && [ "${WINDOWS_INSTALL_TERCEIROS:-0}" -eq 1 ] \
    || fail 'candidato não preservou nem contou a metadata de terceiros'
CASOS=$((CASOS + 1))

# --- Matriz de saída de --verificar ------------------------------------------
conf_definir() {
    # conf_definir VM_NAME QCOW2_PATH
    export WSTATE_VM_NAME="$1" WSTATE_QCOW2="$2"
}
conf_definir win11-teste "$DISCO_A"

SAIDA=""
verificar_caso() {
    # verificar_caso DESCRICAO RC_ESPERADO [TRECHO...]
    local descricao="$1" esperado="$2"
    shift 2
    local rc=0 trecho
    SAIDA="$("$BASH_BIN" "$ETAPA" --verificar 2>&1)" || rc=$?
    [ "$rc" -eq "$esperado" ] \
        || fail "$descricao: rc $rc, esperado $esperado. Saída: $SAIDA"
    for trecho in "$@"; do
        grep -Fq -- "$trecho" <<< "$SAIDA" \
            || fail "$descricao: saída sem o trecho '$trecho'. Saída: $SAIDA"
    done
    CASOS=$((CASOS + 1))
}

export WSTATE_VM=existe WSTATE_XML="$XML_SEM_EVIDENCIA" WSTATE_POWER='shut off'
export WSTATE_AGENT=fail

# 1. Ausente, VM desligada: pendência da etapa, nunca erro.
verificar_caso 'ausente com VM desligada' 1 'não comprovada'

# 2. Instalado e desligado: o eixo 1 decide sozinho.
WSTATE_XML="$XML_REGISTRADA"
verificar_caso 'instalado e desligado' 0 'evidência durável' 'não altera o status'

# 3. Instalado e ligado sem agent: a conclusão durável não se mexe.
WSTATE_POWER=running
WSTATE_AGENT=fail
verificar_caso 'instalado, ligado e sem agent' 0 'evidência durável'

# 4. Instalado com o agent respondendo: continua 0, sem depender dele.
WSTATE_AGENT=ok
verificar_caso 'instalado com agent respondendo' 0 'evidência durável'

# 5. Instalado com energia indeterminada: energia não derruba o eixo 1.
WSTATE_POWER=FAIL
verificar_caso 'instalado com energia indeterminada' 0 'evidência durável'

# 6. Ausente e ligado SEM canal: mensagem estrutural própria.
WSTATE_XML="$XML_SEM_CANAL"
WSTATE_POWER=running
WSTATE_AGENT=fail
verificar_caso 'ausente e ligado sem canal' 1 'não tem o canal'

# 7. Ausente, ligado, canal presente, agent mudo: mensagem de indisponível.
WSTATE_XML="$XML_SEM_EVIDENCIA"
verificar_caso 'ausente com agent indisponível' 1 'não respondeu'

# 8. Retorno zero com saída fora do contrato não vira agent respondendo.
WSTATE_AGENT=lixo
verificar_caso 'agent com resposta fora do contrato' 1 'não respondeu'

# 9. Ausente com o agent respondendo: pendência é gravar a evidência.
WSTATE_AGENT=ok
verificar_caso 'ausente com agent respondendo' 1 'guest agent responde' 'nunca foi gravada'

# 10. Ausente com energia indeterminada: pendência mais falta de observação.
WSTATE_POWER=FAIL
WSTATE_AGENT=fail
verificar_caso 'ausente com energia indeterminada' 2 'não comprovada' 'não pôde ser observado'

# 11. Troca do QCOW2: evidência de outro disco nunca é atribuída a este.
WSTATE_POWER='shut off'
WSTATE_XML="$XML_DIVERGENTE"
verificar_caso 'evidência de outro QCOW2' 2 'não pertence ao QCOW2 atual'

# 12. Metadata fora do schema é erro de configuração do XML.
WSTATE_XML="$XML_INVALIDA"
verificar_caso 'metadata inválida' 3 'inválida'

# 13. Falha de dumpxml é erro, nunca ausência de instalação.
WSTATE_XML=FAIL
verificar_caso 'dumpxml sem resposta' 3 'XML inativo'

# 14. Domínio inexistente continua sendo pendência da etapa 12.
WSTATE_XML="$XML_SEM_EVIDENCIA"
WSTATE_VM=ausente
verificar_caso 'domínio inexistente' 1 'não existe'

# 15. libvirt fora do ar não é "a VM não existe": é falta de observação.
WSTATE_VM=semdaemon
verificar_caso 'libvirt não observável' 2 'não pôde ser observada'

# 16. VM_NAME e QCOW2_PATH ausentes continuam sendo pendência.
WSTATE_VM=existe
conf_definir '' "$DISCO_A"
verificar_caso 'VM_NAME vazio' 1 'VM_NAME'
conf_definir win11-teste ''
verificar_caso 'QCOW2_PATH vazio' 1 'QCOW2_PATH'
conf_definir win11-teste "$DISCO_A"

# 17. Evidência gravada sem birth continua conferindo quando o mesmo caminho
# passa a expor birth: só se pode provar aqui quando o filesystem do teste
# informa birth, e nesse caso os dois digests diferem.
qcow2_identidade_digest "$DISCO_A" || fail 'identidade do disco A perdida'
if [ "$QCOW2_IDENTIDADE_KIND" = 'inode+birth' ]; then
    XML_BASE="$TMP/base.xml"
    xml_domain "$XML_BASE" "$(metadata_install "$BASE_A" 20260830-101500 operador)" sim
    WSTATE_XML="$XML_BASE"
    WSTATE_POWER='shut off'
    verificar_caso 'evidência gravada sem birth aceita com birth presente' 0 'evidência durável'
else
    printf 'AVISO I9.7: filesystem de teste sem birth; queda para o digest base não exercitada.\n' >&2
fi

# 18. Estados ativos do libvirt não podem cair em indeterminada.
WSTATE_XML="$XML_SEM_EVIDENCIA"
for estado in running paused pmsuspended 'in shutdown'; do
    WSTATE_POWER="$estado"
    WSTATE_AGENT=fail
    verificar_caso "energia '$estado' é ligada" 1 'não comprovada'
    if grep -Fq 'não pôde ser observado' <<< "$SAIDA"; then
        fail "estado ativo '$estado' foi classificado como indeterminado"
    fi
done

# --- Transação de metadata no caminho mutante --------------------------------
# O molde é o da etapa 21 (REQ-TRIM-TX): candidato validado, traps antes do
# primeiro define, releitura, prova pós-define e rollback comprovado.
ESTADO_XML="$TMP/estado-dominio.xml"
SAIDA_MUT=""
mutar_caso() {
    # mutar_caso DESCRICAO RC_ESPERADO [TRECHO...]
    local descricao="$1" esperado="$2"
    shift 2
    local rc=0 trecho
    SAIDA_MUT="$("$BASH_BIN" "$ETAPA" 2>&1)" || rc=$?
    [ "$rc" -eq "$esperado" ] \
        || fail "$descricao: rc $rc, esperado $esperado. Saída: $SAIDA_MUT"
    for trecho in "$@"; do
        grep -Fq -- "$trecho" <<< "$SAIDA_MUT" \
            || fail "$descricao: saída sem o trecho '$trecho'. Saída: $SAIDA_MUT"
    done
    CASOS=$((CASOS + 1))
}

conf_definir win11-teste "$DISCO_A"
export WSTATE_VM=existe WSTATE_POWER='shut off' WSTATE_AGENT=fail
export WSTATE_XML="$ESTADO_XML" WSTATE_DEFINE=ok WSTATE_CONFIRMA=nao
export WSTATE_DEFINE_MUDO="" WSTATE_VALIDATE=ok

# Recusar a confirmação não pode alterar coisa alguma.
cp -- "$XML_SEM_EVIDENCIA" "$ESTADO_XML"
ANTES="$(sha256sum < "$ESTADO_XML")"
mutar_caso 'sem confirmação nada é gravado' 0 'Nada foi alterado'
[ "$ANTES" = "$(sha256sum < "$ESTADO_XML")" ] \
    || fail 'a recusa da confirmação ainda assim alterou o XML'

# Confirmação explícita grava a evidência e a prova por releitura.
WSTATE_CONFIRMA=sim
mutar_caso 'evidência gravada com confirmação' 0 'Evidência durável da instalação registrada'
RC=0
xml_metadata_instalacao "$ESTADO_XML" "$DIGEST_A" || RC=$?
[ "$RC" -eq 0 ] || fail 'o XML persistido não carrega a evidência que a etapa declarou gravar'

# Segunda execução sobre estado convergido é no-op exato (regra 17).
DEPOIS="$(sha256sum < "$ESTADO_XML")"
mutar_caso 'segunda execução é no-op' 0 'nada a fazer'
[ "$DEPOIS" = "$(sha256sum < "$ESTADO_XML")" ] \
    || fail 'a segunda execução sobre estado convergido alterou o XML'
if grep -Fq 'registrada no XML inativo' <<< "$SAIDA_MUT"; then
    fail 'a segunda execução gravou de novo em vez de reconhecer a convergência'
fi

# `virsh define` recusando o candidato: nada aplicado, nada a desfazer.
cp -- "$XML_SEM_EVIDENCIA" "$ESTADO_XML"
ANTES="$(sha256sum < "$ESTADO_XML")"
WSTATE_DEFINE=FAIL
mutar_caso 'define recusado restaura sem efeito' 1 'restaurando o XML original' 'Nenhuma mutação efetiva'
[ "$ANTES" = "$(sha256sum < "$ESTADO_XML")" ] || fail 'define recusado deixou efeito no XML'
WSTATE_DEFINE=ok

# `virsh define` que devolve zero SEM aplicar: a pós-condição relida precisa
# pegar isso e o rollback precisa ser comprovado por comparação semântica.
cp -- "$XML_SEM_EVIDENCIA" "$ESTADO_XML"
ANTES="$(sha256sum < "$ESTADO_XML")"
WSTATE_DEFINE_MUDO="$TMP/define-mudo"
: > "$WSTATE_DEFINE_MUDO"
mutar_caso 'define mudo é detectado e revertido' 1 \
    'não foi comprovada após o define' 'restaurado e comprovado por releitura semântica'
[ "$ANTES" = "$(sha256sum < "$ESTADO_XML")" ] \
    || fail 'o rollback não devolveu o XML ao estado original'
WSTATE_DEFINE_MUDO=""

# Metadata inválida no XML bloqueia a gravação em vez de sobrescrever.
cp -- "$XML_INVALIDA" "$ESTADO_XML"
ANTES="$(sha256sum < "$ESTADO_XML")"
mutar_caso 'metadata inválida bloqueia a gravação' 0 'fora do schema' 'nada foi alterado'
[ "$ANTES" = "$(sha256sum < "$ESTADO_XML")" ] || fail 'metadata inválida foi sobrescrita'

# Evidência de outro QCOW2 só é substituída com confirmação própria.
cp -- "$XML_DIVERGENTE" "$ESTADO_XML"
ANTES="$(sha256sum < "$ESTADO_XML")"
WSTATE_CONFIRMA=nao
mutar_caso 'evidência divergente preservada sem confirmação' 0 'aponta para OUTRO QCOW2' 'Nada foi alterado'
[ "$ANTES" = "$(sha256sum < "$ESTADO_XML")" ] \
    || fail 'evidência de outro disco foi substituída sem confirmação'
WSTATE_CONFIRMA=sim
mutar_caso 'evidência divergente substituída sob confirmação' 0 'registrada no XML inativo'
RC=0
xml_metadata_instalacao "$ESTADO_XML" "$DIGEST_A" || RC=$?
[ "$RC" -eq 0 ] || fail 'a substituição confirmada não vinculou a evidência ao QCOW2 atual'

# Com a VM ligada a etapa não grava: o XML inativo só é reescrito com ela parada.
cp -- "$XML_SEM_EVIDENCIA" "$ESTADO_XML"
ANTES="$(sha256sum < "$ESTADO_XML")"
WSTATE_POWER=running
mutar_caso 'VM ligada não grava evidência' 0 'só é gravada com a VM DESLIGADA'
[ "$ANTES" = "$(sha256sum < "$ESTADO_XML")" ] || fail 'evidência foi gravada com a VM ligada'
WSTATE_POWER='shut off'

printf 'OK: REQ-WINDOWS-STATE aprovado em %d casos\n' "$CASOS"
