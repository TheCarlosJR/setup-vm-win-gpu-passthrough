#!/bin/bash
# ============================================================================
# lib/shell/libvirt.sh - backend libvirt, domínio, XML candidato e identidade do disco
# ============================================================================
# Este arquivo NÃO é executado diretamente: ele é carregado via "source" por
# lib/common.sh, que continua sendo a fachada pública das etapas.
#
# Fronteiras (seções 2.1, 2.3 e 2.4 do PLANO-FINALIZACAO.md):
#
#   * aqui ficam a resolução do backend libvirt, o acesso do operador a
#     qemu:///system, o estado do domínio e a geração/comparação de XML
#     candidato pela ponte única do core;
#   * o XML é sempre gerado como CANDIDATO por Python e aplicado por Bash;
#     nenhuma edição de XML por regex mora aqui;
#   * a identidade durável da instalação (REQ-WINDOWS-STATE) é lida deste
#     módulo, mas quem decide o fluxo é a etapa 13.
#
# BACKUPS_DIR e PROJETO_DIR vêm da fachada, que resolve a raiz do checkout
# antes de carregar qualquer módulo; nenhum módulo recalcula esse caminho.
#
# Pré-requisitos de carga: lib/platform.sh, lib/python-core.sh, lib/shell/base.sh, lib/shell/ui.sh.
# Carregar fora de ordem é recusado com diagnóstico, nunca com falha obscura.
#
# Sourcing deste arquivo não produz efeito: apenas define variáveis e funções.
# ============================================================================

if ! declare -F _core_diagnostico > /dev/null 2>&1; then
    printf 'ERRO: lib/shell/libvirt.sh exige %s carregado antes.\n' 'lib/shell/base.sh' >&2
    return 1 2>/dev/null || exit 1
fi
if ! declare -F falhar > /dev/null 2>&1; then
    printf 'ERRO: lib/shell/libvirt.sh exige %s carregado antes.\n' 'lib/shell/ui.sh' >&2
    return 1 2>/dev/null || exit 1
fi
if ! declare -F plataforma_resolver_servico > /dev/null 2>&1; then
    printf 'ERRO: lib/shell/libvirt.sh exige %s carregado antes.\n' 'lib/platform.sh' >&2
    return 1 2>/dev/null || exit 1
fi
if ! declare -F python_core_pares_payload > /dev/null 2>&1; then
    printf 'ERRO: lib/shell/libvirt.sh exige %s carregado antes.\n' 'lib/python-core.sh' >&2
    return 1 2>/dev/null || exit 1
fi

[ -n "${LIBVIRT_SH_CARREGADO:-}" ] && return 0
LIBVIRT_SH_CARREGADO=1

# --- Bootloader e parâmetros de kernel (etapas 3 e 11) -----------------------
# I5.6: toda a implementação vive em lib/shell/boot.sh, carregado logo no topo
# desta fachada. Nenhuma cópia mutante permanece aqui: os nomes públicos
# (detectar_bootloader, validar_bootloader_configurado, cmdline_*,
# kernel_param_add/del, kernel_parametros_*) continuam disponíveis porque o
# módulo é sourceado, não duplicado.

# Comando único de acesso ao libvirt do sistema. Toda etapa passa por ele; não
# existe segundo cliente nem conexão de sessão.
VIRSH="virsh --connect qemu:///system"

# --- Backend libvirt: uma única resolução autoritativa ------------------------
# REQ-LIBVIRT-BACKEND: nenhuma etapa pode escolher `libvirtd` por conta própria.
# O provider de plataforma decide o backend (monolítico `libvirtd` ou modular
# `virtqemud`), a unidade resolvida e a ação autorizada; as etapas 9, 10 e 14
# consomem exatamente este resultado e provam a pós-condição.

LIBVIRT_BACKEND_ERRO=""
LIBVIRT_BACKEND_SERVICO=""
LIBVIRT_BACKEND_UNIDADE=""
LIBVIRT_BACKEND_UNIDADE_DAEMON=""
LIBVIRT_BACKEND_ACAO=""

libvirt_backend_resolver() {
    # Retornos: 0=resolvido; 1=nenhuma unidade do perfil está disponível;
    # 2=erro operacional da sondagem (systemctl ausente, resposta incompleta).
    # A fixture opcional em $1 é autoritativa e nunca cai no systemd do host.
    local fixture="${1:-}" rc=0
    LIBVIRT_BACKEND_ERRO=""
    LIBVIRT_BACKEND_SERVICO=""
    LIBVIRT_BACKEND_UNIDADE=""
    LIBVIRT_BACKEND_UNIDADE_DAEMON=""
    LIBVIRT_BACKEND_ACAO=""
    if plataforma_resolver_servico libvirt "$fixture"; then
        :
    else
        rc=$?
        LIBVIRT_BACKEND_ERRO="$PLATAFORMA_ERRO"
        return "$rc"
    fi
    LIBVIRT_BACKEND_SERVICO="$PLATAFORMA_SERVICO_RESOLVIDO"
    LIBVIRT_BACKEND_UNIDADE="$PLATAFORMA_UNIDADE_RESOLVIDA"
    LIBVIRT_BACKEND_ACAO="$PLATAFORMA_UNIDADE_ACAO"
    # Hooks e configuração são lidos pelo daemon, não pelo socket: a unidade a
    # reiniciar é sempre o serviço do backend resolvido.
    LIBVIRT_BACKEND_UNIDADE_DAEMON="${LIBVIRT_BACKEND_SERVICO}.service"
    if [ -z "$LIBVIRT_BACKEND_SERVICO" ] || [ -z "$LIBVIRT_BACKEND_UNIDADE" ]; then
        LIBVIRT_BACKEND_ERRO="Resolução de backend libvirt incompleta."
        return 2
    fi
    return 0
}

libvirt_backend_reiniciar() {
    # Reinicia o daemon do backend resolvido e prova a pós-condição.
    # Retornos: 0=reiniciado e ativo; 1=falha, com diagnóstico acionável.
    local alvo="$LIBVIRT_BACKEND_UNIDADE_DAEMON"
    LIBVIRT_BACKEND_ERRO=""
    if [ -z "$alvo" ]; then
        LIBVIRT_BACKEND_ERRO="Backend libvirt não resolvido antes do restart."
        return 1
    fi
    if ! sudo systemctl restart "$alvo"; then
        LIBVIRT_BACKEND_ERRO="$alvo não aceitou o restart."
        return 1
    fi
    if ! sudo systemctl is-active --quiet "$alvo"; then
        LIBVIRT_BACKEND_ERRO="$alvo não ficou ativo depois do restart."
        return 1
    fi
    return 0
}

libvirt_acesso_operador() {
    # Prova o acesso desta sessão a qemu:///system e classifica a falha.
    # Retornos: 0=acessível; 1=pendência conhecida (grupo ainda não concedido,
    # ou concedido no NSS e ausente desta sessão); 2=falha real.
    # LIBVIRT_ACESSO_MOTIVO: ok|virsh-ausente|grupo|sessao|runtime.
    local grupo="${PLATAFORMA_LIBVIRT_GRUPO:-libvirt}" operador nss sessao
    LIBVIRT_ACESSO_ERRO=""
    LIBVIRT_ACESSO_MOTIVO=""
    if ! command -v virsh >/dev/null 2>&1; then
        LIBVIRT_ACESSO_MOTIVO=virsh-ausente
        LIBVIRT_ACESSO_ERRO="virsh ausente: a pilha da etapa 9 ainda não está instalada."
        return 2
    fi
    if virsh --connect qemu:///system list --all >/dev/null 2>&1; then
        LIBVIRT_ACESSO_MOTIVO=ok
        return 0
    fi
    operador="$(id -un 2>/dev/null || true)"
    sessao="$(id -nG 2>/dev/null || true)"
    nss="$(id -nG "$operador" 2>/dev/null || true)"
    if lista_contem_token "$sessao" "$grupo"; then
        LIBVIRT_ACESSO_MOTIVO=runtime
        LIBVIRT_ACESSO_ERRO="A sessão já carrega o grupo '$grupo' e ainda assim qemu:///system não respondeu; o runtime libvirt está inválido."
        return 2
    fi
    if lista_contem_token "$nss" "$grupo"; then
        LIBVIRT_ACESSO_MOTIVO=sessao
        LIBVIRT_ACESSO_ERRO="Acesso a qemu:///system pendente de sessão nova: o grupo '$grupo' já consta no NSS de '$operador', mas ainda não nesta sessão. Faça logout/login e verifique de novo."
        return 1
    fi
    LIBVIRT_ACESSO_MOTIVO=grupo
    LIBVIRT_ACESSO_ERRO="Acesso a qemu:///system pendente: '$operador' ainda não pertence ao grupo '$grupo'. Execute a etapa 10 e faça logout/login."
    return 1
}

# --- XML da VM ------------------------------------------------------------------
# Todo XML de domínio, de rede e todo JSON do qemu-img passam pelo core Python
# através da ponte única. As funções desta seção permanecem a API pública do
# shell (mesmos nomes, mesmos argumentos, mesmas variáveis de erro): elas
# capturam o snapshot, transportam por stdin e traduzem a resposta. Nenhuma
# delas interpola dado local em argv nem interpreta JSON com regex.

_xml_ler_arquivo() {
    # Publica o conteúdo do arquivo em XML_CONTEUDO sem executá-lo e sem
    # aceitar link simbólico no lugar do snapshot.
    local arquivo="${1:-}"
    XML_CONTEUDO=""
    [ -n "$arquivo" ] && [ -f "$arquivo" ] && [ ! -L "$arquivo" ] || return 1
    XML_CONTEUDO="$(<"$arquivo")" || return 1
    [ -n "$XML_CONTEUDO" ] || return 1
}

# Allowlist mínima comum a toda resposta do core.
CORE_PARES_ENVELOPE=(CORE_VERSION PROTOCOL_VERSION SUBCOMMAND)

DISCARD_XML_ERRO=""
DISCARD_XML_ESTADO=""
DISCARD_XML_FINGERPRINT=""
xml_disco_qcow2_estado() {
    # Retornos: 0=discard ativo no único disco alvo; 1=alvo único sem unmap;
    # 2=XML inválido, alvo ausente/duplicado ou estrutura ambígua.
    local arquivo="${1:-}" qcow2="${2:-}"
    local -a permitidas=(
        "${CORE_PARES_ENVELOPE[@]}"
        STATE DISCARD DRIVER_TYPE TARGET_DEV DISK_COUNT FINGERPRINT
    )
    local -a payload=()
    DISCARD_XML_ERRO=""
    DISCARD_XML_ESTADO=""
    DISCARD_XML_FINGERPRINT=""
    _xml_ler_arquivo "$arquivo" && caminho_absoluto_seguro "$qcow2" \
        || { DISCARD_XML_ERRO="XML ou QCOW2_PATH inválido."; DISCARD_XML_ESTADO=erro; return 2; }
    payload=(xml "$XML_CONTEUDO" qcow2_path "$qcow2")
    if ! python_core_pares_payload permitidas DISCO_ domain-disk-target payload \
            2>/dev/null; then
        DISCARD_XML_ESTADO=erro
        DISCARD_XML_ERRO="$(_core_diagnostico 'Falha ao analisar o disco QCOW2 alvo.')"
        return 2
    fi
    DISCARD_XML_FINGERPRINT="${DISCO_FINGERPRINT:-}"
    case "${DISCO_STATE:-}" in
        ativo) DISCARD_XML_ESTADO=ativo; return 0 ;;
        ausente) DISCARD_XML_ESTADO=ausente; return 1 ;;
    esac
    DISCARD_XML_ESTADO=erro
    DISCARD_XML_ERRO="Estado de discard não reconhecido na resposta do core."
    return 2
}

# --- Identidade e evidência durável da instalação (REQ-WINDOWS-STATE) --------
# Três eixos independentes moram aqui: a identidade do ARQUIVO QCOW2, a leitura
# da metadata namespaced e a geração do candidato que a grava. Nenhum deles
# consulta o guest agent nem o estado de energia da VM: a evidência de
# instalação precisa sobreviver a VM desligada e a agent ausente.

QCOW2_IDENTIDADE_ERRO=""
QCOW2_IDENTIDADE_DIGEST=""
QCOW2_IDENTIDADE_BASE=""
QCOW2_IDENTIDADE_KIND=""
QCOW2_IDENTIDADE_BIRTH=""
qcow2_identidade_digest() {
    # qcow2_identidade_digest CAMINHO
    # Retornos: 0 identidade medida; 1 não observável (ferramenta ausente,
    # arquivo ausente/ilegível, host sem resposta); 2 dado recusado pelo core.
    #
    # O digest identifica o ARQUIVO (device/inode/birth/caminho/formato), nunca
    # o conteúdo: hashear dezenas ou centenas de GB a cada `--verificar` seria
    # inviável, e o conteúdo do QCOW2 muda a cada boot do Windows sem que o
    # disco tenha sido trocado. Todo o dado é capturado aqui, no shell; o core
    # só canoniza e calcula.
    local caminho="${1:-}" info="" device="" inode="" birth="" nascimento=""
    local -a inspecionar=(
        "${CORE_PARES_ENVELOPE[@]}"
        FORMAT HAS_BACKING BACKING_FILENAME CHAIN_LENGTH
        VIRTUAL_SIZE ACTUAL_SIZE CLUSTER_SIZE
    )
    local -a permitidas=(
        "${CORE_PARES_ENVELOPE[@]}"
        IDENTITY_DIGEST IDENTITY_DIGEST_BASE IDENTITY_KIND IDENTITY_BIRTH
    )
    local -a payload=()
    QCOW2_IDENTIDADE_ERRO=""
    QCOW2_IDENTIDADE_DIGEST=""
    QCOW2_IDENTIDADE_BASE=""
    QCOW2_IDENTIDADE_KIND=""
    QCOW2_IDENTIDADE_BIRTH=""
    caminho_absoluto_seguro "$caminho" \
        || { QCOW2_IDENTIDADE_ERRO="Caminho do QCOW2 inválido ou não absoluto."; return 2; }
    command -v stat >/dev/null 2>&1 && command -v qemu-img >/dev/null 2>&1 \
        || { QCOW2_IDENTIDADE_ERRO="stat ou qemu-img ausente; a identidade do QCOW2 não pôde ser medida."; return 1; }
    [ -e "$caminho" ] \
        || { QCOW2_IDENTIDADE_ERRO="QCOW2 ausente: $caminho"; return 1; }
    [ -f "$caminho" ] && [ ! -L "$caminho" ] \
        || { QCOW2_IDENTIDADE_ERRO="QCOW2 não é arquivo regular: $caminho"; return 1; }
    [ -r "$caminho" ] \
        || { QCOW2_IDENTIDADE_ERRO="QCOW2 sem permissão de leitura: $caminho"; return 1; }
    device="$(LC_ALL=C stat -c '%d' -- "$caminho" 2>/dev/null)" || device=""
    inode="$(LC_ALL=C stat -c '%i' -- "$caminho" 2>/dev/null)" || inode=""
    [ -n "$device" ] && [ -n "$inode" ] \
        || { QCOW2_IDENTIDADE_ERRO="stat não devolveu device/inode do QCOW2."; return 1; }
    # Birth é opcional de propósito: `%W` devolve 0 e `%w` devolve '-' em vários
    # filesystems (o NTFS/fuseblk deste checkout entre eles). Ausência de birth
    # NÃO invalida a identidade: ela apenas reduz o identity_kind para 'inode'.
    nascimento="$(LC_ALL=C stat -c '%W' -- "$caminho" 2>/dev/null)" || nascimento=""
    if [[ "$nascimento" =~ ^[1-9][0-9]*$ ]] && command -v date >/dev/null 2>&1; then
        birth="$(LC_ALL=C date -u -d "@$nascimento" +%Y%m%d-%H%M%S 2>/dev/null)" || birth=""
        [[ "$birth" =~ ^[0-9]{8}-[0-9]{6}$ ]] || birth=""
    fi
    info="$(LC_ALL=C qemu-img info --output=json -- "$caminho" 2>/dev/null)" || info=""
    [ -n "$info" ] \
        || { QCOW2_IDENTIDADE_ERRO="qemu-img não conseguiu inspecionar o QCOW2 $caminho."; return 1; }
    # O formato vem do parser fechado do core, nunca de regex sobre o JSON.
    # A cadeia de backing NÃO é política desta função: a evidência se vincula ao
    # ARQUIVO em QCOW2_PATH, e um overlay criado depois é outro inode, logo
    # outra identidade. Quem exige imagem independente é o backup.
    payload=(json "$info" expect_format qcow2)
    if ! python_core_pares_payload inspecionar QIMG_ qemu-image-inspect payload \
            2>/dev/null; then
        QCOW2_IDENTIDADE_ERRO="$(_core_diagnostico 'A imagem em QCOW2_PATH não é um qcow2 válido.')"
        return 2
    fi
    payload=(
        path "$caminho" device "$device" inode "$inode" birth "$birth"
        format "${QIMG_FORMAT:-}"
    )
    if ! python_core_pares_payload permitidas QID_ qemu-image-identity payload \
            2>/dev/null; then
        QCOW2_IDENTIDADE_ERRO="$(_core_diagnostico 'Identidade do QCOW2 recusada pelo core.')"
        return 2
    fi
    QCOW2_IDENTIDADE_DIGEST="$QID_IDENTITY_DIGEST"
    QCOW2_IDENTIDADE_BASE="$QID_IDENTITY_DIGEST_BASE"
    QCOW2_IDENTIDADE_KIND="$QID_IDENTITY_KIND"
    QCOW2_IDENTIDADE_BIRTH="$QID_IDENTITY_BIRTH"
}

WINDOWS_INSTALL_ESTADO=""
WINDOWS_INSTALL_DIGEST=""
WINDOWS_INSTALL_QUANDO=""
WINDOWS_INSTALL_ORIGEM=""
WINDOWS_INSTALL_TERCEIROS=0
WINDOWS_INSTALL_ERRO=""
xml_metadata_instalacao() {
    # xml_metadata_instalacao ARQUIVO [DIGEST_ESPERADO]
    # Lê a metadata namespaced vmpass:windows-install do XML INATIVO e a
    # confronta com a identidade do QCOW2 atual.
    #
    # WINDOWS_INSTALL_ESTADO recebe a evidência lida:
    #   ausente    nenhuma evidência gravada;
    #   registrada evidência gravada e vinculada a ESTE QCOW2;
    #   divergente evidência gravada para OUTRO disco (ou disco trocado);
    #   invalida   metadata presente e fora do schema (digest/data/origem).
    # Quando nada pôde ser observado (XML ilegível, core sem resposta) o estado
    # vira 'erro' e WINDOWS_INSTALL_ERRO traz o diagnóstico: "não observei"
    # jamais pode passar por "ausente".
    #
    # Retornos alinhados a STATUS_*: 0 registrada, 1 ausente, 2 divergente,
    # 3 invalida/erro.
    local arquivo="${1:-}" esperado="${2:-}" rc=0
    local -a permitidas=(
        "${CORE_PARES_ENVELOPE[@]}"
        METADATA_PRESENT INSTALL_PRESENT INSTALL_DIGEST INSTALL_RECORDED_AT
        INSTALL_SOURCE DIGEST_MATCHES FOREIGN_CHILD_COUNT
    )
    local -a payload=()
    WINDOWS_INSTALL_ESTADO=erro
    WINDOWS_INSTALL_DIGEST=""
    WINDOWS_INSTALL_QUANDO=""
    WINDOWS_INSTALL_ORIGEM=""
    WINDOWS_INSTALL_TERCEIROS=0
    WINDOWS_INSTALL_ERRO=""
    _xml_ler_arquivo "$arquivo" \
        || { WINDOWS_INSTALL_ERRO="XML inativo ausente ou ilegível."; return 3; }
    payload=(xml "$XML_CONTEUDO" qcow2_digest "$esperado")
    python_core_pares_payload permitidas WINST_ domain-metadata payload \
        2>/dev/null || rc=$?
    if [ "$rc" -ne 0 ]; then
        WINDOWS_INSTALL_ERRO="$(_core_diagnostico 'Falha ao ler a metadata de instalação.')"
        # Só dado recusado pelo core (65) é metadata inválida; qualquer outro
        # código interno é ausência de observação, não veredicto sobre o XML.
        if [ "$rc" -eq "$PYTHON_CORE_EXIT_DADO" ]; then
            WINDOWS_INSTALL_ESTADO=invalida
        fi
        return 3
    fi
    WINDOWS_INSTALL_TERCEIROS="${WINST_FOREIGN_CHILD_COUNT:-0}"
    if [ "${WINST_INSTALL_PRESENT:-0}" != 1 ]; then
        WINDOWS_INSTALL_ESTADO=ausente
        return 1
    fi
    WINDOWS_INSTALL_DIGEST="${WINST_INSTALL_DIGEST:-}"
    WINDOWS_INSTALL_QUANDO="${WINST_INSTALL_RECORDED_AT:-}"
    WINDOWS_INSTALL_ORIGEM="${WINST_INSTALL_SOURCE:-}"
    if [ -z "$esperado" ]; then
        # Evidência presente sem digest para confrontar: o vínculo com o disco
        # não foi provado, e sem prova não existe veredicto.
        WINDOWS_INSTALL_ESTADO=erro
        WINDOWS_INSTALL_ERRO="Identidade do QCOW2 não informada; o vínculo da evidência com o disco não foi provado."
        return 3
    fi
    if [ "${WINST_DIGEST_MATCHES:-0}" = 1 ]; then
        WINDOWS_INSTALL_ESTADO=registrada
        return 0
    fi
    WINDOWS_INSTALL_ESTADO=divergente
    WINDOWS_INSTALL_ERRO="A evidência gravada aponta para outro QCOW2 (identidade $WINDOWS_INSTALL_DIGEST)."
    return 2
}

XML_DOMINIO_ERRO=""
XML_DOMINIO_FINGERPRINT=""
xml_dominio_fingerprint() {
    # Fingerprint canônico do XML de domínio, para detectar mudança concorrente
    # antes de aplicar e antes de restaurar.
    local arquivo="${1:-}"
    local -a permitidas=("${CORE_PARES_ENVELOPE[@]}" FINGERPRINT)
    local -a payload=()
    XML_DOMINIO_ERRO=""
    XML_DOMINIO_FINGERPRINT=""
    _xml_ler_arquivo "$arquivo" \
        || { XML_DOMINIO_ERRO="XML de domínio ausente ou ilegível."; return 1; }
    payload=(xml "$XML_CONTEUDO")
    if ! python_core_pares_payload permitidas XMLFP_ domain-fingerprint payload \
            2>/dev/null; then
        XML_DOMINIO_ERRO="$(_core_diagnostico 'Não foi possível calcular o fingerprint do XML.')"
        return 1
    fi
    XML_DOMINIO_FINGERPRINT="$XMLFP_FINGERPRINT"
}

XML_CANDIDATO_ERRO=""
XML_CANDIDATO_MUDOU=0
XML_CANDIDATO_FINGERPRINT_ANTES=""
XML_CANDIDATO_FINGERPRINT_DEPOIS=""
_xml_candidato_permitidas=(
    CORE_VERSION PROTOCOL_VERSION SUBCOMMAND
    CHANGED OPERATION_COUNT FINGERPRINT_BEFORE FINGERPRINT_AFTER
    BYTES_WRITTEN SHA256
)
_xml_candidato_gerar() {
    # $1 = XML de origem; $2 = destino; demais = pares do payload da operação.
    # O core gera o candidato num temporário controlado e a ponte publica no
    # destino somente quando a geração é aceita, então uma recusa nunca deixa
    # candidato parcial. O destino continua sendo validado pelo shell com
    # virt-xml-validate antes do primeiro define.
    local origem="${1:-}" destino="${2:-}"
    local -a payload=()
    shift 2 || true
    XML_CANDIDATO_ERRO=""
    XML_CANDIDATO_MUDOU=0
    XML_CANDIDATO_FINGERPRINT_ANTES=""
    XML_CANDIDATO_FINGERPRINT_DEPOIS=""
    _xml_ler_arquivo "$origem" \
        || { XML_CANDIDATO_ERRO="XML de origem ausente ou ilegível."; return 1; }
    payload=(xml "$XML_CONTEUDO" "$@")
    if ! python_core_candidato _xml_candidato_permitidas XMLCAND_ payload "$destino" \
            2>/dev/null; then
        XML_CANDIDATO_ERRO="$(_core_diagnostico 'Falha ao gerar o XML candidato.')"
        return 1
    fi
    XML_CANDIDATO_MUDOU="$XMLCAND_CHANGED"
    XML_CANDIDATO_FINGERPRINT_ANTES="$XMLCAND_FINGERPRINT_BEFORE"
    XML_CANDIDATO_FINGERPRINT_DEPOIS="$XMLCAND_FINGERPRINT_AFTER"
}

xml_candidato_discard() {
    # xml_candidato_discard ORIGEM DESTINO QCOW2_PATH
    _xml_candidato_gerar "$1" "$2" \
        op_count 1 op_0 disk-discard op_0_qcow2_path "$3" op_0_value unmap
}

xml_candidato_sem_video() {
    # xml_candidato_sem_video ORIGEM DESTINO
    _xml_candidato_gerar "$1" "$2" op_count 1 op_0 remove-video
}

xml_candidato_anti_code43() {
    # xml_candidato_anti_code43 ORIGEM DESTINO [VENDOR_ID]
    local vendor="${3:-randomid123}"
    _xml_candidato_gerar "$1" "$2" \
        op_count 1 op_0 anti-code43 op_0_vendor_id "$vendor"
}

xml_candidato_fonte_nic() {
    # xml_candidato_fonte_nic ORIGEM DESTINO MAC TIPO ATRIBUTO VALOR
    _xml_candidato_gerar "$1" "$2" \
        op_count 1 op_0 nic-source \
        op_0_mac "$3" op_0_type "$4" op_0_attribute "$5" op_0_value "$6"
}

xml_candidato_instalacao() {
    # xml_candidato_instalacao ORIGEM DESTINO DIGEST QUANDO [ORIGEM_EVIDENCIA]
    _xml_candidato_gerar "$1" "$2" \
        op_count 1 op_0 install-metadata \
        op_0_qcow2_digest "$3" op_0_recorded_at "$4" op_0_source "${5:-operador}"
}

xml_candidato_usb() {
    # xml_candidato_usb ORIGEM DESTINO ESTADO KIND SHA VID PID [BUS DEVICE]
    local estado="${3:-}" kind="${4:-}" digest="${5:-}"
    local vendor="${6:-}" product="${7:-}" bus="${8:-}" device="${9:-}"
    _xml_candidato_gerar "$1" "$2" \
        op_count 1 op_0 usb-hostdev \
        op_0_state "$estado" op_0_identity_kind "$kind" \
        op_0_identity_sha256 "$digest" op_0_vendor "$vendor" \
        op_0_product "$product" op_0_bus "$bus" op_0_device "$device"
}

XML_COMPARACAO_ERRO=""
XML_COMPARACAO_DIFERENCA=""
xml_dominio_equivalente() {
    # xml_dominio_equivalente ESQUERDA DIREITA [PROJECAO]
    # Retornos: 0=equivalente na projeção; 1=divergente; 2=erro de análise.
    # PROJECAO: full (padrão), cpu-unmanaged, devices-unmanaged.
    local esquerda="${1:-}" direita="${2:-}" projecao="${3:-full}" conteudo_esquerda
    local -a permitidas=(
        "${CORE_PARES_ENVELOPE[@]}" EQUAL DIFFERENCE FINGERPRINT_LEFT FINGERPRINT_RIGHT
    )
    local -a payload=()
    XML_COMPARACAO_ERRO=""
    XML_COMPARACAO_DIFERENCA=""
    _xml_ler_arquivo "$esquerda" \
        || { XML_COMPARACAO_ERRO="XML de referência ausente ou ilegível."; return 2; }
    conteudo_esquerda="$XML_CONTEUDO"
    _xml_ler_arquivo "$direita" \
        || { XML_COMPARACAO_ERRO="XML observado ausente ou ilegível."; return 2; }
    payload=(left "$conteudo_esquerda" right "$XML_CONTEUDO" projection "$projecao")
    if ! python_core_pares_payload permitidas XMLCMP_ domain-compare payload \
            2>/dev/null; then
        XML_COMPARACAO_ERRO="$(_core_diagnostico 'Não foi possível comparar os XML.')"
        return 2
    fi
    XML_COMPARACAO_DIFERENCA="$XMLCMP_DIFFERENCE"
    [ "$XMLCMP_EQUAL" = 1 ] || return 1
    return 0
}

xml_backup() {
    # Backup único e validado do XML inativo. O caminho também fica em
    # XML_BACKUP_PATH para consumidores que precisem mostrá-lo em rollback.
    local vm="$1" destino
    XML_BACKUP_PATH=""
    mkdir -p "$BACKUPS_DIR"
    destino="$(mktemp "$BACKUPS_DIR/${vm}-$(date +%Y%m%d-%H%M%S)-XXXXXX.xml")" \
        || falhar "Não foi possível criar destino exclusivo para o backup XML."
    if ! $VIRSH dumpxml --inactive "$vm" > "$destino"; then
        rm -f -- "$destino"
        falhar "Falha ao salvar backup do XML da VM '$vm'."
    fi
    [ -s "$destino" ] || { rm -f -- "$destino"; falhar "O backup XML da VM ficou vazio."; }
    XML_BACKUP_PATH="$destino"
    info "Backup do XML salvo em: $destino"
}

vm_existe() { LC_ALL=C $VIRSH dominfo "$1" >/dev/null 2>&1; }

vm_estado() {
    local estado rc
    if estado="$(LC_ALL=C $VIRSH domstate "$1" 2>/dev/null)"; then
        sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<< "$estado"
    else
        rc=$?
        return "$rc"
    fi
}

vm_desligada() {
    local estado
    estado="$(vm_estado "$1")" || return $?
    [ "$estado" = "shut off" ]
}

exigir_vm_desligada() {
    vm_existe "$1" || falhar "A VM '$1' não existe. Execute a etapa 12 antes."
    vm_desligada "$1" \
        || falhar "A VM '$1' precisa estar DESLIGADA (use: virsh --connect qemu:///system shutdown $1)."
}

XML_CPU_ERRO=""
xml_cpu_gerar_candidato() {
    # Gera XML com pinning, topologia e página explicitamente de 1 GiB sem
    # remover ajustes não gerenciados de cputune/memoryBacking.
    # Assinatura preservada: ORIGEM DESTINO CPUS_VM CPUS_HOST VCPUS CORES
    # THREADS RAM_MB. O destino só é escrito quando o candidato é aceito.
    local origem="$1" destino="$2" cpus_vm="$3" cpus_host="$4"
    local vcpus="$5" cores="$6" threads="$7" ram_mb="$8"
    local -a permitidas=(
        "${CORE_PARES_ENVELOPE[@]}"
        CHANGED OPERATION_COUNT FINGERPRINT_BEFORE FINGERPRINT_AFTER
        BYTES_WRITTEN SHA256
    )
    local -a payload=()
    XML_CPU_ERRO=""
    _xml_ler_arquivo "$origem" \
        || { XML_CPU_ERRO="XML de origem ausente ou ilegível."; return 1; }
    payload=(
        xml "$XML_CONTEUDO"
        op_count 1
        op_0 cpu-pinning
        op_0_cpus_vm "$cpus_vm"
        op_0_cpus_host "$cpus_host"
        op_0_vcpus "$vcpus"
        op_0_cores "$cores"
        op_0_threads "$threads"
        op_0_ram_mb "$ram_mb"
    )
    if ! python_core_candidato permitidas XMLCPU_ payload "$destino" 2>/dev/null; then
        XML_CPU_ERRO="$(_core_diagnostico 'Falha ao gerar o XML candidato.')"
        return 1
    fi
}

xml_cpu_remover_hugepages() {
    # Remove a exigência de HugePages preservando o restante do memoryBacking.
    local origem="$1" destino="$2"
    local -a permitidas=(
        "${CORE_PARES_ENVELOPE[@]}"
        CHANGED OPERATION_COUNT FINGERPRINT_BEFORE FINGERPRINT_AFTER
        BYTES_WRITTEN SHA256
    )
    local -a payload=()
    XML_CPU_ERRO=""
    _xml_ler_arquivo "$origem" \
        || { XML_CPU_ERRO="XML de origem ausente ou ilegível."; return 1; }
    payload=(xml "$XML_CONTEUDO" op_count 1 op_0 remove-hugepages)
    if ! python_core_candidato permitidas XMLCPU_ payload "$destino" 2>/dev/null; then
        XML_CPU_ERRO="$(_core_diagnostico 'Falha ao remover HugePages do XML candidato.')"
        return 1
    fi
}

validar_xml_cpu_pinning() {
    # validar_xml_cpu_pinning XML CPUS_VM CPUS_HOST VCPUS CORES THREADS RAM_MB MODO
    # MODO: sim exige página de 1 GiB; nao exige ausência; ignorar não avalia.
    local arquivo="$1" cpus_vm="$2" cpus_host="$3" vcpus="$4"
    local cores="$5" threads="$6" ram_mb="$7" modo="${8:-ignorar}"
    local -a permitidas=(
        "${CORE_PARES_ENVELOPE[@]}" VALID VCPUS HUGEPAGES_COUNT FINGERPRINT
    )
    local -a payload=()
    XML_CPU_ERRO=""
    _xml_ler_arquivo "$arquivo" \
        || { XML_CPU_ERRO="XML de CPU/HugePages ausente ou ilegível."; return 1; }
    payload=(
        xml "$XML_CONTEUDO"
        cpus_vm "$cpus_vm"
        cpus_host "$cpus_host"
        vcpus "$vcpus"
        cores "$cores"
        threads "$threads"
        ram_mb "$ram_mb"
        hugepages_mode "$modo"
    )
    if ! python_core_pares_payload permitidas XMLCPU_ domain-validate-cpu payload \
            2>/dev/null; then
        XML_CPU_ERRO="$(_core_diagnostico 'XML de CPU/HugePages inválido.')"
        return 1
    fi
}

xml_sem_hugepages_arquivo() {
    # Retornos: 0=nenhuma HugePage exigida; 1=exige HugePages; 2=erro.
    local arquivo="${1:-}"
    local -a permitidas=(
        "${CORE_PARES_ENVELOPE[@]}"
        BACKING_COUNT HUGEPAGES_COUNT PAGE_COUNT PAGE_BYTES
    )
    local -a payload=()
    XML_CPU_ERRO=""
    _xml_ler_arquivo "$arquivo" \
        || { XML_CPU_ERRO="XML de domínio ausente ou ilegível."; return 2; }
    payload=(xml "$XML_CONTEUDO")
    if ! python_core_pares_payload permitidas XMLHP_ domain-memory-backing payload \
            2>/dev/null; then
        XML_CPU_ERRO="$(_core_diagnostico 'Não foi possível inspecionar memoryBacking.')"
        return 2
    fi
    [ "$XMLHP_HUGEPAGES_COUNT" = 0 ] || return 1
    return 0
}
