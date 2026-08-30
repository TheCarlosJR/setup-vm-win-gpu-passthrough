#!/bin/bash
# ============================================================================
# etapas/61-airlock.sh - Etapa 20: Compartilhamento Seguro (Airlock)
# ============================================================================
# Canal recomendado de troca host<->VM, exposto por SFTP com chroot, chave
# obrigatória, usuário sem shell e firewall restrito ao IP fixo da VM.
# O workingDisk é opcional: quando AIRLOCK_DIR estiver dentro de
# WORKING_DISK_PATH, o mountpoint-base externo precisa permanecer ativo. Sem
# workingDisk, AIRLOCK_DIR pode apontar para outro filesystem local.
#
#   1. Grupo/usuário dedicados (airlock-transfer / vmtransfer)
#   2. Pasta de trânsito + /srv/airlock/files (chroot)
#   3. Visão de serviço bindfs (fstab, noexec/nosuid/nodev)
#   4. sshd endurecido global + Match User com chroot e internal-sftp
#   5. Instalação da chave pública gerada DENTRO do Windows
#   6. Firewall ufw: porta 22 apenas para VM_IP_FIXO na interface do modo
#      (REDE_BRIDGE em bridge; REDE_BRIDGE_LIBVIRT em NAT)
#   7. Hook 00-airlock.sh (criação automática e idempotente a cada boot da VM)
#
# Uso:
#   61-airlock.sh                  execução completa (idempotente)
#   61-airlock.sh --instalar-chave somente instala/troca a chave pública
#   61-airlock.sh --verificar      status
#
# A alternativa Samba não é instalada; o airlock/SFTP é o método recomendado.
# ============================================================================
SCRIPT_VERSION="1.0.0"
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf
REDE_BRIDGE="${REDE_BRIDGE:-br0}"
REDE_BRIDGE_LIBVIRT="${REDE_BRIDGE_LIBVIRT:-virbr-vmnat}"
AIRLOCK_REDE_IFACE=""

interface_rede_airlock() {
    case "${REDE_MODO:-}" in
        bridge) echo "$REDE_BRIDGE" ;;
        nat) echo "$REDE_BRIDGE_LIBVIRT" ;;
        *) return 1 ;;
    esac
}

UFW_MARCADOR="SFTP airlock - somente VM Windows"
UFW_COLETA_ERRO=""
UFW_COLETA_TIPO=""
UFW_REGRAS_MARCADAS=()
UFW_REGRAS_IFACES=()
UFW_REGRAS_IPS=()
UFW_REGRAS_INVALIDAS=()
REGRA_UFW_IFACE=""
REGRA_UFW_IP=""
AIRLOCK_TX_ATIVA=0
AIRLOCK_TX_DIR=""
AIRLOCK_USUARIO_NOVO=0
AIRLOCK_GRUPO_NOVO=0
AIRLOCK_MONTAGEM_INICIAL=0
AIRLOCK_UFW_ATIVO_INICIAL=0

airlock_salvar_arquivo() {
    local nome="$1" caminho="$2"
    if sudo test -e "$caminho"; then
        printf 'presente\n' > "$AIRLOCK_TX_DIR/$nome.estado"
        sudo cp -a -- "$caminho" "$AIRLOCK_TX_DIR/$nome"
    else
        printf 'ausente\n' > "$AIRLOCK_TX_DIR/$nome.estado"
    fi
}

airlock_restaurar_arquivo() {
    local nome="$1" caminho="$2"
    if [ "$(<"$AIRLOCK_TX_DIR/$nome.estado")" = "presente" ]; then
        sudo mkdir -p "$(dirname "$caminho")" || return 1
        sudo cp -a -- "$AIRLOCK_TX_DIR/$nome" "$caminho"
    else
        sudo rm -f -- "$caminho"
    fi
}

airlock_iniciar_transacao() {
    AIRLOCK_TX_DIR="$(mktemp -d)"
    chmod 700 "$AIRLOCK_TX_DIR"
    airlock_resolver_caminhos_conta
    HOOK_DIR="$AIRLOCK_HOOK_DIR"
    HOOK_FILE="$AIRLOCK_HOOK_FILE"
    airlock_salvar_arquivo fstab "$FSTAB"
    airlock_salvar_arquivo sshd-dropin "$SSHD_DROPIN"
    airlock_salvar_arquivo chave "$AIRLOCK_CHAVE_ARQUIVO"
    airlock_salvar_arquivo hook "$HOOK_FILE"
    if sudo test -d /etc/ufw; then
        printf 'presente\n' > "$AIRLOCK_TX_DIR/ufw.estado"
        sudo cp -a /etc/ufw "$AIRLOCK_TX_DIR/ufw"
    else
        printf 'ausente\n' > "$AIRLOCK_TX_DIR/ufw.estado"
    fi
    sudo ufw status 2>/dev/null | grep -q 'Status: active' && AIRLOCK_UFW_ATIVO_INICIAL=1 || true
    getent group airlock-transfer >/dev/null && AIRLOCK_GRUPO_NOVO=0 || AIRLOCK_GRUPO_NOVO=1
    getent passwd "$TRANSFER_USER" >/dev/null && AIRLOCK_USUARIO_NOVO=0 || AIRLOCK_USUARIO_NOVO=1
    mountpoint -q "$AIRLOCK_BIND" && AIRLOCK_MONTAGEM_INICIAL=1 || true
    AIRLOCK_TX_ATIVA=1
}

airlock_rollback() {
    aviso "Falha detectada: restaurando o estado anterior do Airlock..."
    if [ "$AIRLOCK_MONTAGEM_INICIAL" -eq 0 ] && mountpoint -q "$AIRLOCK_BIND"; then
        sudo umount "$AIRLOCK_BIND" || aviso "Não foi possível desmontar $AIRLOCK_BIND automaticamente."
    fi
    airlock_restaurar_arquivo fstab "$FSTAB" || aviso "Não foi possível restaurar $FSTAB."
    airlock_restaurar_arquivo sshd-dropin "$SSHD_DROPIN" || aviso "Não foi possível restaurar o drop-in do sshd."
    airlock_restaurar_arquivo chave "$AIRLOCK_CHAVE_ARQUIVO" || aviso "Não foi possível restaurar a chave anterior."
    airlock_restaurar_arquivo hook "$HOOK_FILE" || aviso "Não foi possível restaurar o hook anterior."
    if [ "$(<"$AIRLOCK_TX_DIR/ufw.estado")" = "presente" ]; then
        sudo rm -rf /etc/ufw && sudo cp -a "$AIRLOCK_TX_DIR/ufw" /etc/ufw || aviso "Não foi possível restaurar os arquivos do UFW."
    else
        sudo rm -rf /etc/ufw || aviso "Não foi possível remover a configuração UFW criada."
    fi
    if [ "$AIRLOCK_UFW_ATIVO_INICIAL" -eq 1 ]; then sudo ufw --force enable || true; else sudo ufw --force disable || true; fi
    if sudo sshd -t; then sudo systemctl reload ssh || aviso "sshd restaurado, mas o reload falhou."; else aviso "Configuração SSH restaurada ainda não passa em sshd -t; revise pelo console."; fi
    [ "$AIRLOCK_USUARIO_NOVO" -eq 0 ] || sudo userdel "$TRANSFER_USER" 2>/dev/null || true
    [ "$AIRLOCK_GRUPO_NOVO" -eq 0 ] || sudo groupdel airlock-transfer 2>/dev/null || true
    aviso "Rollback do Airlock concluído; diretórios vazios criados podem permanecer."
}

airlock_finalizar() {
    local status=$?
    trap - EXIT INT TERM
    if [ "$AIRLOCK_TX_ATIVA" -eq 1 ] && [ "$status" -ne 0 ]; then airlock_rollback; fi
    [ -z "$AIRLOCK_TX_DIR" ] || sudo rm -rf "$AIRLOCK_TX_DIR"
    encerrar_sudo_keepalive
    exit "$status"
}

parsear_regra_ufw_airlock() {
    local linha="$1"
    local -a campos=()
    read -r -a campos <<< "$linha"
    [ "${#campos[@]}" -eq 20 ] || return 1
    [ "${campos[0]}" = "ufw" ] \
        && [ "${campos[1]}" = "allow" ] \
        && [ "${campos[2]}" = "in" ] \
        && [ "${campos[3]}" = "on" ] \
        && [ "${campos[5]}" = "from" ] \
        && [ "${campos[7]}" = "to" ] \
        && [ "${campos[8]}" = "any" ] \
        && [ "${campos[9]}" = "port" ] \
        && [ "${campos[10]}" = "22" ] \
        && [ "${campos[11]}" = "proto" ] \
        && [ "${campos[12]}" = "tcp" ] \
        && [ "${campos[13]}" = "comment" ] \
        && [ "${campos[14]} ${campos[15]} ${campos[16]} ${campos[17]} ${campos[18]} ${campos[19]}" = "'$UFW_MARCADOR'" ] \
        || return 1
    nome_interface_valido "${campos[4]}" || return 1
    ipv4_valido "${campos[6]}" || return 1
    REGRA_UFW_IFACE="${campos[4]}"
    REGRA_UFW_IP="${campos[6]}"
}

coletar_regras_ufw_airlock() {
    local modo_sudo="${1:-normal}" saida linha
    UFW_COLETA_ERRO=""
    # Duas falhas MUITO diferentes moravam no mesmo retorno 1: não conseguir
    # consultar o ufw (nada foi observado) e observar uma regra com o
    # comentário gerenciado fora do formato seguro (estado errado e perigoso).
    # O tipo separa as duas para o verificador não chamar as duas de pendência.
    UFW_COLETA_TIPO="indeterminado"
    UFW_REGRAS_MARCADAS=()
    UFW_REGRAS_IFACES=()
    UFW_REGRAS_IPS=()
    UFW_REGRAS_INVALIDAS=()
    if [ "$modo_sudo" = "sem-senha" ]; then
        if ! saida="$(sudo -n ufw show added 2>/dev/null)"; then
            UFW_COLETA_ERRO="Não foi possível consultar 'ufw show added' sem interação."
            return 1
        fi
    else
        if ! saida="$(sudo ufw show added)"; then
            UFW_COLETA_ERRO="Falha ao consultar todas as regras adicionadas do UFW."
            return 1
        fi
    fi
    while IFS= read -r linha; do
        [[ "$linha" == *"$UFW_MARCADOR"* ]] || continue
        UFW_REGRAS_MARCADAS+=("$linha")
        if parsear_regra_ufw_airlock "$linha"; then
            UFW_REGRAS_IFACES+=("$REGRA_UFW_IFACE")
            UFW_REGRAS_IPS+=("$REGRA_UFW_IP")
        else
            UFW_REGRAS_INVALIDAS+=("$linha")
        fi
    done <<< "$saida"
    if [ "${#UFW_REGRAS_INVALIDAS[@]}" -gt 0 ]; then
        UFW_COLETA_TIPO="erro"
        UFW_COLETA_ERRO="Há ${#UFW_REGRAS_INVALIDAS[@]} regra(s) com o comentário exato, mas fora do formato seguro esperado: ${UFW_REGRAS_INVALIDAS[0]}"
        return 1
    fi
    UFW_COLETA_TIPO="ok"
}

contar_regras_ufw_airlock_exatas() {
    local iface="$1" ip="$2" i total=0
    for i in "${!UFW_REGRAS_IFACES[@]}"; do
        if [ "${UFW_REGRAS_IFACES[$i]}" = "$iface" ] \
           && [ "${UFW_REGRAS_IPS[$i]}" = "$ip" ]; then
            total=$((total + 1))
        fi
    done
    printf '%s\n' "$total"
}

WORKING_DISK="${WORKING_DISK_PATH:-}"
if [ -n "${AIRLOCK_DIR:-}" ]; then
    AIRLOCK_TRANSITO="$AIRLOCK_DIR"
elif [ -n "$WORKING_DISK" ]; then
    AIRLOCK_TRANSITO="$WORKING_DISK/airlock"
else
    AIRLOCK_TRANSITO="/var/lib/vm-passthrough/airlock"
fi
AIRLOCK_BIND="${AIRLOCK_BIND:-/srv/airlock/files}"
AIRLOCK_BASE="$(dirname "$AIRLOCK_BIND")"

# Hermeticidade (regra 12 da seção 0.1): TODO caminho de sistema desta etapa
# passa por caminho_sistema, para que o verificador leia exatamente a árvore
# que o caminho de aplicação escreve. Em produção caminho_sistema devolve o
# caminho literal, então nada muda para o operador. Sem isso, o verificador
# testaria o /etc real do host de desenvolvimento e nenhuma pós-condição do
# airlock seria testável sem mutar a máquina.
FSTAB="$(caminho_sistema /etc/fstab)" \
    || falhar "Não foi possível resolver o caminho do fstab."
SSHD_DROPIN="$(caminho_sistema /etc/ssh/sshd_config.d/10-airlock.conf)" \
    || falhar "Não foi possível resolver o drop-in do sshd."
AIRLOCK_CHAVES_DIR="$(caminho_sistema /etc/ssh/authorized_keys)" \
    || falhar "Não foi possível resolver o diretório de chaves do airlock."
UFW_DEFAULT_ARQUIVO="$(caminho_sistema /etc/default/ufw)" \
    || falhar "Não foi possível resolver /etc/default/ufw."
HOOKS_QEMU_DIR="$(caminho_sistema /etc/libvirt/hooks/qemu.d)" \
    || falhar "Não foi possível resolver o diretório de hooks do libvirt."
AIRLOCK_CHAVE_ARQUIVO=""
AIRLOCK_HOOK_DIR=""
AIRLOCK_HOOK_FILE=""
airlock_resolver_caminhos_conta() {
    # TRANSFER_USER e VM_NAME só existem depois de carregar_conf/exigir_conf,
    # então os caminhos que dependem deles são resolvidos por esta função, e
    # não no corpo do script: o apply e o --verificar chamam a MESMA resolução.
    AIRLOCK_CHAVE_ARQUIVO=""
    AIRLOCK_HOOK_DIR=""
    AIRLOCK_HOOK_FILE=""
    [ -z "${TRANSFER_USER:-}" ] || AIRLOCK_CHAVE_ARQUIVO="$AIRLOCK_CHAVES_DIR/$TRANSFER_USER"
    if [ -n "${VM_NAME:-}" ]; then
        AIRLOCK_HOOK_DIR="$HOOKS_QEMU_DIR/$VM_NAME/prepare/begin"
        AIRLOCK_HOOK_FILE="$AIRLOCK_HOOK_DIR/00-airlock.sh"
    fi
}
airlock_resolver_caminhos_conta

airlock_opcoes_bindfs() {
    # Fonte única das opções da visão de serviço: a linha publicada no fstab e
    # a linha exigida pelo verificador saem daqui, para que "configurado" e
    # "provado" não possam divergir por edição de um lado só.
    local opcoes="force-user=$TRANSFER_USER,force-group=airlock-transfer,perms=0770,chmod-ignore,chown-ignore,allow_other,noexec,nosuid,nodev,nofail"
    [ "$AIRLOCK_DEPENDS_ON_WORKING_DISK" -eq 1 ] \
        && opcoes="${opcoes},x-systemd.requires=$(sed 's/ /\\040/g' <<< "$WORKING_DISK")"
    printf '%s\n' "$opcoes"
}

AIRLOCK_DEPENDS_ON_WORKING_DISK=0
AIRLOCK_CONTENCAO_ERRO=""
classificar_airlock_working_disk() {
    local rc
    AIRLOCK_DEPENDS_ON_WORKING_DISK=0
    AIRLOCK_CONTENCAO_ERRO=""
    [ -n "$WORKING_DISK" ] || return 0
    if caminho_dentro_working_disk "$AIRLOCK_TRANSITO" "$WORKING_DISK"; then
        AIRLOCK_DEPENDS_ON_WORKING_DISK=1
        return 0
    else
        rc=$?
    fi
    [ "$rc" -eq 1 ] && return 0
    AIRLOCK_CONTENCAO_ERRO="Airlock recusado por contenção insegura no workingDisk: $WORKING_DISK_CONTENCAO_ERRO"
    return 1
}

# ============================================================================
# Avaliação efetiva do Airlock (REQ-AIRLOCK-VERIFY / REQ-VERIFY-FAILCLOSED)
# ============================================================================
# O apply e o --verificar usam ESTES avaliadores, e só eles. A regra é uma só:
# presença textual não prova nada. Um drop-in no disco não prova que o sshd o
# lê; uma linha no fstab não prova que a visão está montada; um arquivo de
# chave não prova que a chave é válida, é única e está fora do alcance da
# conta de transferência.
#
# Contrato de retorno, igual ao dos helpers de lib/common.sh:
#   0 provado | 1 pendente | 2 indeterminado | 3 erro
# Cada avaliador publica AIRLOCK_AVAL_TIPO (ok|pendente|indeterminado|erro),
# AIRLOCK_AVAL_ERRO (mensagem acionável quando não provado) e
# AIRLOCK_AVAL_DETALHE (o que foi observado quando provado).
#
# Os avaliadores NÃO imprimem: quem imprime é o --verificar (via v_classificar)
# ou o apply (via falhar). A exceção é o avaliador que delega a um helper de
# lib/common.sh que já emite a própria mensagem; nesse caso ele marca
# AIRLOCK_AVAL_RELATADO=1 para o chamador não duplicar a linha.
declare -A SSHD_EFETIVO=()
AIRLOCK_AVAL_TIPO=""
AIRLOCK_AVAL_ERRO=""
AIRLOCK_AVAL_DETALHE=""
AIRLOCK_AVAL_RELATADO=0
# 1 durante o --verificar: privilégio só é aceito sem interação. Um verificador
# que abre prompt de senha travaria o menu a cada redesenho.
AIRLOCK_AVAL_SEM_SENHA=0
SSHD_EFETIVO_CONTEXTO=""
AIRLOCK_SSHD_FAMILIAS=""
UFW_STATUS_SAIDA=""
UFW_STATUS_ATIVO=0
# Diretivas que o sshd sempre imprime, com ou sem drop-in. A ausência de
# qualquer uma delas significa saída truncada/inesperada (indeterminado), e
# nunca "a política não está aplicada" (pendência).
AIRLOCK_SSHD_SENTINELAS=(port permitrootlogin passwordauthentication pubkeyauthentication authorizedkeysfile)
# Diretivas que o sshd só imprime quando estão configuradas: a ausência delas é
# exatamente o falso sucesso que este requisito proíbe, logo é pendência.
AIRLOCK_SSHD_MULTIVALORADAS=(listenaddress hostkey subsystem acceptenv include allowusers denyusers)

airlock_aval_reset() {
    AIRLOCK_AVAL_TIPO=""
    AIRLOCK_AVAL_ERRO=""
    AIRLOCK_AVAL_DETALHE=""
    AIRLOCK_AVAL_RELATADO=0
}
airlock_aval_ok()            { AIRLOCK_AVAL_TIPO=ok;            AIRLOCK_AVAL_DETALHE="$1"; return 0; }
airlock_aval_pendente()      { AIRLOCK_AVAL_TIPO=pendente;      AIRLOCK_AVAL_ERRO="$1";    return 1; }
airlock_aval_indeterminado() { AIRLOCK_AVAL_TIPO=indeterminado; AIRLOCK_AVAL_ERRO="$1";    return 2; }
airlock_aval_erro()          { AIRLOCK_AVAL_TIPO=erro;          AIRLOCK_AVAL_ERRO="$1";    return 3; }
airlock_aval_delegado() {
    # O helper de lib/common.sh já emitiu a mensagem e já contabilizou a
    # classe; aqui só traduzimos o código para o vocabulário do avaliador.
    local rc="${1:-3}"
    AIRLOCK_AVAL_RELATADO=1
    case "$rc" in
        0) AIRLOCK_AVAL_TIPO=ok ;;
        1) AIRLOCK_AVAL_TIPO=pendente ;;
        2) AIRLOCK_AVAL_TIPO=indeterminado ;;
        *) AIRLOCK_AVAL_TIPO=erro ;;
    esac
    return "$rc"
}

airlock_sudo() {
    # Privilégio no modo da fase atual. No --verificar nada pode pedir senha.
    if [ "$AIRLOCK_AVAL_SEM_SENHA" -eq 1 ]; then
        sudo -n "$@"
    else
        sudo "$@"
    fi
}

airlock_exigir_ferramenta() {
    # Equivalente silencioso de v_exigir_comando, para os avaliadores que
    # também rodam no apply (onde uma linha "[aviso]" de verificador seria
    # ruído). O --verificar continua chamando v_exigir_comando diretamente nos
    # portões de ferramenta, para manter a mensagem canônica do projeto.
    local cmd
    local -a faltando=()
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || faltando+=("$cmd")
    done
    [ "${#faltando[@]}" -eq 0 ] && return 0
    airlock_aval_indeterminado "Ferramenta ausente (${faltando[*]}); o estado do airlock não pôde ser observado."
}

airlock_aval_privilegio() {
    # Portão único das provas privilegiadas. Sem ele, "não consegui olhar"
    # viraria "está tudo certo" (o falso sucesso) ou "falta executar a etapa"
    # (uma pendência mentirosa que manda o operador rodar a etapa à toa).
    airlock_aval_reset
    airlock_exigir_ferramenta sudo || return 2
    if [ "$AIRLOCK_AVAL_SEM_SENHA" -eq 1 ] && ! sudo -n true >/dev/null 2>&1; then
        airlock_aval_indeterminado "Sem sudo sem senha: política efetiva do sshd, chave, metadados e firewall NÃO foram observados. Rode 'sudo -v' e verifique de novo."
        return 2
    fi
    airlock_aval_ok "Observação privilegiada disponível."
}

airlock_aval_conta() {
    # Conta de transferência: existência única, identidade numérica, GID
    # primário do grupo do airlock, nenhum grupo extra, shell sem login e home
    # do chroot. `getent passwd` devolvendo 0 provava apenas que o nome
    # resolve, inclusive quando resolve para a conta errada.
    local saida total nome uid gid gecos home shell grupo_linha grupo_gid grupos operador
    airlock_aval_reset
    airlock_exigir_ferramenta getent id || return 2
    saida="$(LC_ALL=C getent passwd "$TRANSFER_USER" 2>/dev/null)" || saida=""
    if [ -z "$saida" ]; then
        airlock_aval_pendente "Usuário $TRANSFER_USER ausente; execute a etapa 20."
        return 1
    fi
    total="$(printf '%s\n' "$saida" | grep -c '^')"
    if [ "$total" -ne 1 ]; then
        airlock_aval_erro "NSS devolveu $total entradas para $TRANSFER_USER: a identidade da conta do airlock é ambígua e nenhuma política pode ser atribuída com segurança."
        return 3
    fi
    IFS=: read -r nome _ uid gid gecos home shell <<< "$saida"
    : "$gecos"
    if [ "$nome" != "$TRANSFER_USER" ] || ! [[ "$uid" =~ ^[0-9]+$ ]] || ! [[ "$gid" =~ ^[0-9]+$ ]]; then
        airlock_aval_indeterminado "Entrada de $TRANSFER_USER no NSS fora do formato passwd esperado: $saida"
        return 2
    fi
    if [ "$uid" -eq 0 ]; then
        airlock_aval_erro "$TRANSFER_USER tem UID 0: a conta do airlock seria root dentro do SFTP."
        return 3
    fi
    # Conta compartilhada com a administração do host: a etapa aceita esse
    # valor (o useradd só roda quando a conta não existe) e o próprio texto da
    # etapa 20.4 avisa contra ele. O verificador precisa dizer isso com todas
    # as letras, em vez de reportar "GID errado" e deixar o operador procurando
    # um defeito mecânico que não existe.
    operador="$(LC_ALL=C id -un 2>/dev/null)" || operador=""
    if { [ -n "$operador" ] && [ "$TRANSFER_USER" = "$operador" ]; } \
       || { [ -n "${USUARIO_LINUX:-}" ] && [ "$TRANSFER_USER" = "$USUARIO_LINUX" ]; }; then
        airlock_aval_erro "TRANSFER_USER='$TRANSFER_USER' é a mesma conta usada para administrar o host: o Match do sshd transforma o SSH dessa conta em SFTP dentro do chroot e o airlock deixa de ter conta dedicada. Escolha uma conta separada (ex.: vmtransfer) pela etapa 3 e reexecute a etapa 20."
        return 3
    fi
    grupo_linha="$(LC_ALL=C getent group airlock-transfer 2>/dev/null)" || grupo_linha=""
    if [ -z "$grupo_linha" ]; then
        airlock_aval_pendente "Grupo airlock-transfer ausente; execute a etapa 20."
        return 1
    fi
    grupo_gid="$(cut -d: -f3 <<< "$grupo_linha")"
    if ! [[ "$grupo_gid" =~ ^[0-9]+$ ]]; then
        airlock_aval_indeterminado "Entrada de airlock-transfer no NSS fora do formato group esperado: $grupo_linha"
        return 2
    fi
    if [ "$gid" != "$grupo_gid" ]; then
        airlock_aval_erro "GID primário de $TRANSFER_USER é $gid, esperado $grupo_gid (airlock-transfer): os arquivos da visão não pertenceriam ao grupo do airlock."
        return 3
    fi
    grupos="$(LC_ALL=C id -nG "$TRANSFER_USER" 2>/dev/null)" || grupos=""
    if [ -z "$grupos" ]; then
        airlock_aval_indeterminado "Não foi possível listar os grupos de $TRANSFER_USER."
        return 2
    fi
    if [ "$grupos" != "airlock-transfer" ]; then
        airlock_aval_erro "$TRANSFER_USER pertence a grupos além do airlock ($grupos): a conta de transferência teria alcance fora da zona de trânsito."
        return 3
    fi
    case "$shell" in
        */nologin|*/false) : ;;
        *)
            airlock_aval_erro "Shell de $TRANSFER_USER é '$shell': a conta do airlock precisa de nologin/false, senão o confinamento depende só do Match do sshd."
            return 3
            ;;
    esac
    if [ "$home" != "/files" ]; then
        airlock_aval_erro "Home de $TRANSFER_USER é '$home', esperado /files (o diretório dentro do chroot)."
        return 3
    fi
    airlock_aval_ok "Conta $TRANSFER_USER provada: uid=$uid, gid=$gid (airlock-transfer), grupos=$grupos, shell=$shell, home=$home."
}

airlock_aval_autenticacao() {
    # Lock/senha da conta: `passwd -S` é a única leitura que distingue senha
    # utilizável (P) de conta travada (L) e de conta sem senha (NP).
    local saida estado
    airlock_aval_reset
    airlock_exigir_ferramenta passwd || return 2
    saida="$(airlock_sudo passwd -S "$TRANSFER_USER" 2>/dev/null)" || saida=""
    if [ -z "$saida" ]; then
        airlock_aval_indeterminado "Estado de autenticação de $TRANSFER_USER não pôde ser lido ('passwd -S' sem resposta utilizável)."
        return 2
    fi
    read -r _ estado _ <<< "$saida"
    case "$estado" in
        L|LK)
            airlock_aval_ok "Autenticação por senha travada para $TRANSFER_USER (passwd -S: $estado)."
            ;;
        NP)
            airlock_aval_ok "Conta $TRANSFER_USER sem senha definida (passwd -S: NP); o acesso depende exclusivamente da chave."
            ;;
        P|PS)
            airlock_aval_erro "$TRANSFER_USER tem senha utilizável (passwd -S: $estado): a conta de serviço do airlock não pode autenticar por senha."
            return 3
            ;;
        *)
            airlock_aval_indeterminado "Estado de autenticação inesperado para $TRANSFER_USER: '$saida'."
            return 2
            ;;
    esac
}

airlock_aval_fstab() {
    # A linha gerenciada precisa existir E descrever a montagem certa: origem,
    # destino, tipo e TODAS as opções de segurança. Só o marcador provava que
    # alguém escreveu algo com aquele nome.
    local linha origem destino tipo opcoes esperadas opcao
    local origem_esperada destino_esperada
    local -a faltando=()
    airlock_aval_reset
    if [ ! -r "$FSTAB" ]; then
        airlock_aval_indeterminado "$FSTAB ilegível; a linha bindfs do airlock não pôde ser observada."
        return 2
    fi
    if ! fstab_tem_linha airlock-bindfs; then
        airlock_aval_pendente "fstab sem a linha gerenciada 'airlock-bindfs'; a visão não sobrevive ao próximo boot."
        return 1
    fi
    linha="$(sed -n '/^# vm-passthrough:airlock-bindfs$/{n;p;q;}' "$FSTAB")" || linha=""
    if [ -z "$linha" ]; then
        airlock_aval_erro "Marcador 'airlock-bindfs' presente no fstab sem a linha de montagem logo abaixo."
        return 3
    fi
    read -r origem destino tipo opcoes _ <<< "$linha"
    origem_esperada="$(sed 's/ /\\040/g' <<< "$AIRLOCK_TRANSITO")"
    destino_esperada="$(sed 's/ /\\040/g' <<< "$AIRLOCK_BIND")"
    if [ "$origem" != "$origem_esperada" ] || [ "$destino" != "$destino_esperada" ]; then
        airlock_aval_pendente "Linha bindfs do fstab aponta $origem -> $destino; a configuração atual exige $origem_esperada -> $destino_esperada."
        return 1
    fi
    if [ "$tipo" != "fuse.bindfs" ]; then
        airlock_aval_pendente "Linha bindfs do fstab declara o tipo '$tipo', esperado fuse.bindfs."
        return 1
    fi
    esperadas="$(airlock_opcoes_bindfs)"
    for opcao in ${esperadas//,/ }; do
        lista_contem_token "${opcoes//,/ }" "$opcao" || faltando+=("$opcao")
    done
    if [ "${#faltando[@]}" -gt 0 ]; then
        airlock_aval_pendente "Linha bindfs do fstab sem as opções obrigatórias (${faltando[*]}); atuais: $opcoes."
        return 1
    fi
    airlock_aval_ok "Linha bindfs do fstab provada: $origem -> $destino, fuse.bindfs, opções completas."
}

airlock_aval_bindfs_ativo() {
    # `mountpoint -q` só prova que EXISTE alguma montagem no ponto: não prova o
    # tipo, a origem nem noexec/nosuid/nodev. A prova vem do findmnt.
    local rc=0
    airlock_aval_reset
    v_prova_montagem "$AIRLOCK_BIND" fuse.bindfs "$AIRLOCK_TRANSITO" noexec nosuid nodev || rc=$?
    airlock_aval_delegado "$rc"
}

airlock_aval_chave() {
    # Fingerprint, cardinalidade e conteúdo. Um arquivo não vazio provava
    # apenas que alguém escreveu bytes ali.
    local linhas fingerprint rc=0
    airlock_aval_reset
    airlock_exigir_ferramenta ssh-keygen grep || return 2
    if ! airlock_sudo test -e "$AIRLOCK_CHAVE_ARQUIVO" >/dev/null 2>&1; then
        airlock_aval_pendente "Chave pública de $TRANSFER_USER pendente; instale com: 61-airlock.sh --instalar-chave"
        return 1
    fi
    if ! airlock_sudo test -s "$AIRLOCK_CHAVE_ARQUIVO" >/dev/null 2>&1; then
        airlock_aval_pendente "Arquivo de chave de $TRANSFER_USER existe mas está vazio ($AIRLOCK_CHAVE_ARQUIVO)."
        return 1
    fi
    linhas="$(airlock_sudo grep -c -E -v '^[[:space:]]*(#|$)' -- "$AIRLOCK_CHAVE_ARQUIVO" 2>/dev/null || true)"
    if ! [[ "$linhas" =~ ^[0-9]+$ ]]; then
        airlock_aval_indeterminado "Não foi possível contar as chaves autorizadas em $AIRLOCK_CHAVE_ARQUIVO."
        return 2
    fi
    if [ "$linhas" -ne 1 ]; then
        airlock_aval_erro "$AIRLOCK_CHAVE_ARQUIVO autoriza $linhas chaves; o airlock exige exatamente uma credencial conhecida."
        return 3
    fi
    fingerprint="$(airlock_sudo ssh-keygen -l -f "$AIRLOCK_CHAVE_ARQUIVO" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        airlock_aval_erro "A chave instalada para $TRANSFER_USER não passa no ssh-keygen (código $rc): ${fingerprint%%$'\n'*}"
        return 3
    fi
    airlock_aval_ok "Chave pública provada para $TRANSFER_USER: ${fingerprint%%$'\n'*}"
}

airlock_metadados_de() {
    # Publica "DONO GRUPO MODO" de um caminho, sempre com privilégio: os três
    # recursos abaixo são root-only por desenho.
    airlock_sudo stat -c '%U %G %a' -- "$1" 2>/dev/null
}

airlock_aval_metadados() {
    # O sshd RECUSA o chroot se a base não for root e não estiver protegida
    # contra escrita de grupo/outros, e a chave dentro do alcance da própria
    # conta de transferência anularia a autenticação.
    local caminho dono grupo modo saida
    local -a provados=()
    airlock_aval_reset
    airlock_exigir_ferramenta stat || return 2
    for caminho in "$AIRLOCK_CHAVE_ARQUIVO" "$SSHD_DROPIN" "$AIRLOCK_BASE"; do
        [ -n "$caminho" ] || continue
        airlock_sudo test -e "$caminho" >/dev/null 2>&1 || continue
        saida="$(airlock_metadados_de "$caminho")" || saida=""
        if [ -z "$saida" ]; then
            airlock_aval_indeterminado "Metadados de $caminho não puderam ser lidos."
            return 2
        fi
        read -r dono grupo modo <<< "$saida"
        if ! [[ "$modo" =~ ^[0-7]{3,4}$ ]]; then
            airlock_aval_indeterminado "Modo inesperado em $caminho: '$saida'."
            return 2
        fi
        if [ "$dono" != root ] || [ "$grupo" != root ]; then
            airlock_aval_erro "$caminho pertence a $dono:$grupo, esperado root:root."
            return 3
        fi
        if [ "$caminho" = "$AIRLOCK_CHAVE_ARQUIVO" ] && [ "${modo: -3}" != "600" ]; then
            airlock_aval_erro "$caminho está em modo $modo, esperado 600: a chave autorizada ficaria legível fora do root."
            return 3
        fi
        # A base do chroot segue a regra do próprio sshd (safe_path): nenhuma
        # escrita de grupo ou de outros, ou o daemon recusa a sessão. O drop-in
        # é root:root e só precisa não ser escrevível por outros; exigir 022
        # ali dependeria do umask do root e viraria pendência fantasma.
        if [ "$caminho" = "$AIRLOCK_BASE" ] && [ $(( 8#${modo: -3} & 8#022 )) -ne 0 ]; then
            airlock_aval_erro "$caminho está em modo $modo, com escrita para grupo/outros: o sshd recusa esse ChrootDirectory e a sessão do airlock não abriria."
            return 3
        fi
        if [ "$caminho" = "$SSHD_DROPIN" ] && [ $(( 8#${modo: -3} & 8#002 )) -ne 0 ]; then
            airlock_aval_erro "$caminho está em modo $modo, escrevível por outros: qualquer conta local reescreveria a política do sshd."
            return 3
        fi
        provados+=("$caminho=$dono:$grupo:$modo")
    done
    if [ "${#provados[@]}" -eq 0 ]; then
        airlock_aval_pendente "Nenhum recurso root-only do airlock existe ainda; execute a etapa 20."
        return 1
    fi
    airlock_aval_ok "Metadados provados: ${provados[*]}"
}

airlock_sshd_valor() {
    # "none" é como o sshd descreve uma diretiva não configurada; tratá-la como
    # valor faria "ForceCommand none" passar por confinamento.
    local valor="${SSHD_EFETIVO[$1]:-}"
    [ "$valor" != none ] || valor=""
    printf '%s' "$valor"
}

airlock_aval_sshd_efetivo() {
    # A política EFETIVA, lida do próprio daemon, com o contexto de conexão do
    # airlock. É o único jeito de provar que o drop-in está sendo incluído e
    # que o bloco Match casa com o usuário real.
    local contexto="${1:-}" saida rc=0 linha chave valor
    local -a faltando=()
    airlock_aval_reset
    SSHD_EFETIVO=()
    SSHD_EFETIVO_CONTEXTO="$contexto"
    airlock_exigir_ferramenta sshd || return 2
    if [ -n "$contexto" ]; then
        saida="$(airlock_sudo sshd -T -C "$contexto" 2>&1)" || rc=$?
    else
        saida="$(airlock_sudo sshd -T 2>&1)" || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        airlock_aval_indeterminado "sshd -T${contexto:+ -C $contexto} não pôde ser consultado (código $rc): ${saida%%$'\n'*}"
        return 2
    fi
    while IFS= read -r linha; do
        [ -n "$linha" ] || continue
        chave="${linha%% *}"
        valor="${linha#* }"
        [ "$chave" != "$linha" ] || valor=""
        chave="${chave,,}"
        [[ "$chave" =~ ^[a-z0-9]+$ ]] || continue
        if lista_contem_token "${AIRLOCK_SSHD_MULTIVALORADAS[*]}" "$chave" \
           && [ -n "${SSHD_EFETIVO[$chave]:-}" ]; then
            SSHD_EFETIVO[$chave]="${SSHD_EFETIVO[$chave]} $valor"
        else
            SSHD_EFETIVO[$chave]="$valor"
        fi
    done <<< "$saida"
    for chave in "${AIRLOCK_SSHD_SENTINELAS[@]}"; do
        [ -n "${SSHD_EFETIVO[$chave]+definida}" ] || faltando+=("$chave")
    done
    if [ "${#faltando[@]}" -gt 0 ]; then
        airlock_aval_indeterminado "Saída de sshd -T${contexto:+ -C $contexto} vazia ou truncada (sem ${faltando[*]}); a política efetiva NÃO foi lida."
        return 2
    fi
    airlock_aval_ok "Política efetiva lida${contexto:+ para $contexto}: ${#SSHD_EFETIVO[@]} diretivas."
}

airlock_aval_sshd_global() {
    # Exige SSHD_EFETIVO carregado SEM contexto (política global).
    local chave valor
    local -a divergencias=()
    airlock_aval_reset
    for chave in passwordauthentication kbdinteractiveauthentication permitrootlogin; do
        valor="$(airlock_sshd_valor "$chave")"
        [ "$valor" = no ] || divergencias+=("$chave=${valor:-<ausente>}")
    done
    if [ "${#divergencias[@]}" -gt 0 ]; then
        airlock_aval_pendente "Endurecimento global do sshd não é efetivo (${divergencias[*]}); esperado 'no' em todas. Texto no drop-in não basta: o daemon precisa aplicá-lo."
        return 1
    fi
    airlock_aval_ok "Endurecimento global efetivo: senha, teclado-interativo e login de root desligados."
}

airlock_aval_sshd_familias() {
    # Exige SSHD_EFETIVO carregado SEM contexto. Publica AIRLOCK_SSHD_FAMILIAS
    # para o cruzamento com a família atendida pelo firewall.
    local familia endereco
    local -a familias=()
    airlock_aval_reset
    AIRLOCK_SSHD_FAMILIAS=""
    familia="$(airlock_sshd_valor addressfamily)"
    case "$familia" in
        inet) familias=(inet) ;;
        inet6) familias=(inet6) ;;
        any|"")
            for endereco in $(airlock_sshd_valor listenaddress); do
                case "$endereco" in
                    \[*|*:*:*) lista_contem_token "${familias[*]:-}" inet6 || familias+=(inet6) ;;
                    *) lista_contem_token "${familias[*]:-}" inet || familias+=(inet) ;;
                esac
            done
            [ "${#familias[@]}" -gt 0 ] || familias=(inet inet6)
            ;;
        *)
            airlock_aval_indeterminado "AddressFamily efetiva desconhecida ('$familia'); as famílias atendidas pelo sshd não foram determinadas."
            return 2
            ;;
    esac
    AIRLOCK_SSHD_FAMILIAS="${familias[*]}"
    airlock_aval_ok "Famílias atendidas pelo sshd: $AIRLOCK_SSHD_FAMILIAS."
}

airlock_aval_politica_positiva() {
    # Exige SSHD_EFETIVO carregado COM o contexto do usuário do airlock.
    local valor esperado_chaves
    local -a divergencias=()
    airlock_aval_reset
    esperado_chaves="$AIRLOCK_CHAVES_DIR/%u"
    valor="$(airlock_sshd_valor chrootdirectory)"
    [ "$valor" = "$AIRLOCK_BASE" ] || divergencias+=("chrootdirectory=${valor:-<ausente>} (esperado $AIRLOCK_BASE)")
    valor="$(airlock_sshd_valor forcecommand)"
    [ "$valor" = "internal-sftp -u 0007" ] || divergencias+=("forcecommand=${valor:-<ausente>} (esperado 'internal-sftp -u 0007')")
    valor="$(airlock_sshd_valor authorizedkeysfile)"
    [ "$valor" = "$esperado_chaves" ] || divergencias+=("authorizedkeysfile=${valor:-<ausente>} (esperado $esperado_chaves)")
    valor="$(airlock_sshd_valor pubkeyauthentication)"
    [ "$valor" = yes ] || divergencias+=("pubkeyauthentication=${valor:-<ausente>} (esperado yes)")
    if [ "${#divergencias[@]}" -gt 0 ]; then
        airlock_aval_pendente "Confinamento efetivo de $TRANSFER_USER incompleto: ${divergencias[*]}. Sem isso a sessão SFTP não fica presa em $AIRLOCK_BASE."
        return 1
    fi
    airlock_aval_ok "Confinamento efetivo de $TRANSFER_USER provado: chroot $AIRLOCK_BASE, internal-sftp -u 0007 e chave dedicada."
}

airlock_aval_politica_negativa() {
    # Exige SSHD_EFETIVO carregado COM o contexto do usuário do airlock. Um
    # Match posterior pode reabrir o que o global fechou, então a negativa é
    # reavaliada DENTRO do contexto.
    local chave valor
    local -a divergencias=()
    airlock_aval_reset
    for chave in allowtcpforwarding allowagentforwarding x11forwarding permittunnel \
                 passwordauthentication kbdinteractiveauthentication permitrootlogin; do
        valor="$(airlock_sshd_valor "$chave")"
        [ "$valor" = no ] || divergencias+=("$chave=${valor:-<ausente>}")
    done
    if [ "${#divergencias[@]}" -gt 0 ]; then
        airlock_aval_pendente "Restrições efetivas de $TRANSFER_USER não aplicadas (${divergencias[*]}); esperado 'no' em todas. A sessão de arquivos viraria ponte de rede ou aceitaria senha."
        return 1
    fi
    airlock_aval_ok "Restrições efetivas provadas para $TRANSFER_USER: sem forwarding, sem túnel, sem senha."
}

airlock_aval_ufw_defaults() {
    # Publica UFW_STATUS_SAIDA/UFW_STATUS_ATIVO para os avaliadores seguintes.
    # "ufw inativo" e "não consegui consultar o ufw" deixaram de ser a mesma
    # frase: são pendência e indeterminado, respectivamente.
    local rc=0 linha politica_in politica_out
    airlock_aval_reset
    UFW_STATUS_SAIDA=""
    UFW_STATUS_ATIVO=0
    airlock_exigir_ferramenta ufw || return 2
    UFW_STATUS_SAIDA="$(airlock_sudo ufw status verbose 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        airlock_aval_indeterminado "'ufw status verbose' não pôde ser consultado (código $rc); o firewall NÃO foi observado."
        return 2
    fi
    if ! grep -q '^Status:' <<< "$UFW_STATUS_SAIDA"; then
        airlock_aval_indeterminado "Saída inesperada de 'ufw status verbose' (sem linha 'Status:'); o firewall NÃO foi observado."
        return 2
    fi
    grep -q '^Status: active' <<< "$UFW_STATUS_SAIDA" && UFW_STATUS_ATIVO=1
    if [ "$UFW_STATUS_ATIVO" -eq 0 ]; then
        airlock_aval_pendente "ufw inativo: as regras existem mas nada é filtrado. Ative com 'sudo ufw enable'."
        return 1
    fi
    linha="$(grep -m1 '^Default:' <<< "$UFW_STATUS_SAIDA")" || linha=""
    if [ -z "$linha" ]; then
        airlock_aval_indeterminado "'ufw status verbose' ativo sem a linha 'Default:'; as políticas padrão NÃO foram observadas."
        return 2
    fi
    politica_in="$(sed -n 's/.*[[:space:]]\([a-z]*\)[[:space:]](incoming).*/\1/p' <<< "$linha")"
    politica_out="$(sed -n 's/.*[[:space:]]\([a-z]*\)[[:space:]](outgoing).*/\1/p' <<< "$linha")"
    if [ -z "$politica_in" ] || [ -z "$politica_out" ]; then
        airlock_aval_indeterminado "Linha 'Default:' do ufw fora do formato esperado: $linha"
        return 2
    fi
    if [ "$politica_in" != deny ] && [ "$politica_in" != reject ]; then
        airlock_aval_pendente "Política padrão de entrada do ufw é '$politica_in': tudo o que não for negado explicitamente entra, e a regra do airlock deixa de ser um limite."
        return 1
    fi
    airlock_aval_ok "ufw ativo com entrada '$politica_in' e saída '$politica_out' por padrão."
}

airlock_aval_ufw_regras() {
    local total_marcadas total_exatas
    airlock_aval_reset
    if ! coletar_regras_ufw_airlock sem-senha; then
        if [ "$UFW_COLETA_TIPO" = erro ]; then
            airlock_aval_erro "$UFW_COLETA_ERRO"
            return 3
        fi
        airlock_aval_indeterminado "$UFW_COLETA_ERRO"
        return 2
    fi
    total_marcadas="${#UFW_REGRAS_MARCADAS[@]}"
    total_exatas="$(contar_regras_ufw_airlock_exatas "$AIRLOCK_REDE_IFACE" "${VM_IP_FIXO:-}")"
    if [ "$total_marcadas" -ne 1 ] || [ "$total_exatas" -ne 1 ]; then
        airlock_aval_pendente "UFW exige total marcado=1 e exato=1; encontrado marcado=$total_marcadas, exato=$total_exatas. Remova regras residuais."
        return 1
    fi
    airlock_aval_ok "UFW contém exatamente uma regra marcada, exata para interface=$AIRLOCK_REDE_IFACE, origem=$VM_IP_FIXO, porta=22/tcp."
}

airlock_aval_ufw_ipv6() {
    # Cruzamento IPv4/IPv6: a regra do airlock é IPv4. Se o sshd atende IPv6, a
    # porta 22 precisa continuar fechada nessa família, seja porque o ufw a
    # gerencia e não a abre, seja porque o operador foi avisado do contrário.
    local valor linha
    local -a v6_abertas=()
    airlock_aval_reset
    if [ ! -r "$UFW_DEFAULT_ARQUIVO" ]; then
        airlock_aval_indeterminado "$UFW_DEFAULT_ARQUIVO ilegível; a família IPv6 do firewall NÃO foi observada."
        return 2
    fi
    valor="$(sed -n 's/^[[:space:]]*IPV6=["'"'"']*\([A-Za-z]*\).*/\1/p' "$UFW_DEFAULT_ARQUIVO" | tail -n1)"
    valor="${valor,,}"
    if [ -z "$valor" ]; then
        airlock_aval_indeterminado "$UFW_DEFAULT_ARQUIVO sem a chave IPV6=; a família IPv6 do firewall NÃO foi observada."
        return 2
    fi
    if [ "$valor" != yes ]; then
        if lista_contem_token "$AIRLOCK_SSHD_FAMILIAS" inet6; then
            airlock_aval_pendente "O sshd atende IPv6 ($AIRLOCK_SSHD_FAMILIAS) mas o ufw está com IPV6=$valor: a porta 22 fica sem filtro nessa família."
            return 1
        fi
        airlock_aval_ok "ufw com IPV6=$valor e sshd restrito a $AIRLOCK_SSHD_FAMILIAS."
        return 0
    fi
    while IFS= read -r linha; do
        [[ "$linha" == *"(v6)"* ]] || continue
        [[ "$linha" == *"ALLOW IN"* ]] || continue
        [[ "$linha" == 22/* || "$linha" == *" 22/"* ]] || continue
        v6_abertas+=("$linha")
    done <<< "$UFW_STATUS_SAIDA"
    if [ "${#v6_abertas[@]}" -gt 0 ]; then
        airlock_aval_pendente "ufw com IPV6=yes libera a porta 22 em IPv6 (${v6_abertas[0]}): o airlock só autoriza $VM_IP_FIXO em IPv4."
        return 1
    fi
    airlock_aval_ok "ufw gerencia IPv6 e nenhuma regra v6 libera a porta 22."
}

airlock_aval_hook() {
    # Presença + bit de execução + conteúdo desta geração E desta configuração:
    # um hook de outra VM ou de outro par de caminhos "existe e é executável",
    # e mesmo assim não monta nada.
    local rc=0 esperado_transito esperado_bind esperado_disco
    airlock_aval_reset
    if [ -z "$AIRLOCK_HOOK_FILE" ]; then
        airlock_aval_pendente "VM_NAME não definido; o hook do airlock não tem caminho."
        return 1
    fi
    v_prova_arquivo "$AIRLOCK_HOOK_FILE" "Hook 00-airlock.sh" --exec \
        --marcador '^# 00-airlock\.sh \(gerado por etapas/61-airlock\.sh\)$' || rc=$?
    if [ "$rc" -ne 0 ]; then
        airlock_aval_delegado "$rc"
        return "$rc"
    fi
    esperado_transito="AIRLOCK_TRANSITO=\"$AIRLOCK_TRANSITO\""
    esperado_bind="AIRLOCK_BIND=\"$AIRLOCK_BIND\""
    esperado_disco="WORKING_DISK=\"$WORKING_DISK\""
    if ! grep -Fqx -- "$esperado_transito" "$AIRLOCK_HOOK_FILE" \
       || ! grep -Fqx -- "$esperado_bind" "$AIRLOCK_HOOK_FILE" \
       || ! grep -Fqx -- "$esperado_disco" "$AIRLOCK_HOOK_FILE"; then
        airlock_aval_pendente "Hook 00-airlock.sh instalado para outra configuração; reexecute a etapa 20 para regravá-lo com $AIRLOCK_TRANSITO -> $AIRLOCK_BIND."
        return 1
    fi
    AIRLOCK_AVAL_RELATADO=1
    airlock_aval_ok "Hook 00-airlock.sh provado para $AIRLOCK_TRANSITO -> $AIRLOCK_BIND."
}

airlock_exigir_politica_sshd() {
    # Uso do CAMINHO DE APLICAÇÃO: mesma avaliação do --verificar, com falha
    # fatal (e portanto rollback) em vez de relatório. Chamada duas vezes: uma
    # antes do reload (pré-condição) e outra depois (pós-condição pós-commit).
    local fase="$1"
    AIRLOCK_AVAL_SEM_SENHA=0
    airlock_aval_sshd_efetivo \
        || falhar "Política global do sshd não pôde ser lida $fase: $AIRLOCK_AVAL_ERRO"
    airlock_aval_sshd_global \
        || falhar "Endurecimento global do sshd não é efetivo $fase: $AIRLOCK_AVAL_ERRO"
    airlock_aval_sshd_efetivo "user=$TRANSFER_USER,addr=$VM_IP_FIXO,host=airlock" \
        || falhar "Política efetiva do usuário Airlock não pôde ser lida $fase: $AIRLOCK_AVAL_ERRO"
    airlock_aval_politica_positiva \
        || falhar "Confinamento do usuário Airlock não é efetivo $fase: $AIRLOCK_AVAL_ERRO"
    airlock_aval_politica_negativa \
        || falhar "Restrições do usuário Airlock não são efetivas $fase: $AIRLOCK_AVAL_ERRO"
    info "Política efetiva do sshd provada $fase."
}

airlock_v_relatar() {
    # Traduz o resultado do avaliador para o protocolo 0/1/2/3 do verificador.
    # Quando o avaliador delegou a um helper que já imprimiu, nada é reimpresso
    # (a classe já foi contabilizada lá dentro).
    local rc="${1:-3}"
    if [ "$AIRLOCK_AVAL_RELATADO" -eq 1 ]; then
        return "$rc"
    fi
    v_classificar "$rc" "$AIRLOCK_AVAL_DETALHE" "$AIRLOCK_AVAL_ERRO" \
        "$AIRLOCK_AVAL_ERRO" "$AIRLOCK_AVAL_ERRO"
    return "$rc"
}

airlock_v_avaliar() {
    # Açúcar: roda o avaliador, relata e nunca derruba o verificador por rc.
    local rc=0
    "$@" || rc=$?
    airlock_v_relatar "$rc" || true
    return 0
}

verificar() {
    local rc=0 conta_rc=0
    AIRLOCK_AVAL_SEM_SENHA=1
    if [ -n "$WORKING_DISK" ] && [ "${WORKING_DISK_DISPENSADO:-}" = "sim" ]; then
        v_erro "Configuração contraditória: WORKING_DISK_PATH definido e WORKING_DISK_DISPENSADO=sim."
    elif ! classificar_airlock_working_disk; then
        v_erro "$AIRLOCK_CONTENCAO_ERRO"
    elif [ "$AIRLOCK_DEPENDS_ON_WORKING_DISK" -eq 1 ]; then
        if validar_working_disk_montado "$WORKING_DISK"; then
            v_ok "Base do airlock protegida pelo workingDisk ativo em $WORKING_DISK."
        else
            v_falta "$WORKING_DISK_ERRO"
        fi
    fi
    if [ -z "${USUARIO_LINUX:-}" ]; then
        v_falta "USUARIO_LINUX não definido."
    elif validar_usuario_linux "$USUARIO_LINUX"; then
        if [ "$USUARIO_DIFERE_OPERADOR" -eq 1 ]; then
            v_erro "USUARIO_LINUX='$USUARIO_LINUX' difere do operador '$USUARIO_OPERADOR'."
        else
            v_ok "Conta principal validada no NSS: $USUARIO_LINUX."
        fi
    else
        v_erro "$USUARIO_VALIDACAO_ERRO"
    fi
    if ! validar_config_rede; then
        v_falta "$REDE_CONFIG_ERRO"
        v_fim
    fi
    AIRLOCK_REDE_IFACE="$(interface_rede_airlock)"
    if ip link show "$AIRLOCK_REDE_IFACE" >/dev/null 2>&1; then
        v_ok "Interface do airlock: $AIRLOCK_REDE_IFACE (modo $REDE_MODO)."
    else
        v_falta "Interface do airlock $AIRLOCK_REDE_IFACE ausente; conclua a etapa 19."
    fi
    if validar_ips_interface_rede "$AIRLOCK_REDE_IFACE" "${VM_IP_FIXO:-}" "${IP_FIXO_HOST:-}"; then
        v_ok "IPs do airlock coerentes: VM=$VM_IP_FIXO, host=$IP_FIXO_HOST."
    else
        v_falta "$REDE_IP_ERRO"
    fi
    [ -n "${TRANSFER_USER:-}" ] || { v_falta "TRANSFER_USER não definido."; v_fim; }
    if ! nome_usuario_valido "$TRANSFER_USER"; then
        # Valor presente e inválido é ERRO de configuração: não se resolve
        # reexecutando a etapa, e seguir daqui interpolaria lixo em caminhos e
        # em expressões regulares.
        v_erro "TRANSFER_USER='$TRANSFER_USER' não é um nome de usuário seguro; corrija pela etapa 3."
        v_fim
    fi
    airlock_resolver_caminhos_conta

    # --- Provas não privilegiadas ------------------------------------------
    conta_rc=0
    airlock_aval_conta || conta_rc=$?
    airlock_v_relatar "$conta_rc" || true
    airlock_v_avaliar airlock_aval_fstab
    if v_exigir_comando findmnt; then
        airlock_v_avaliar airlock_aval_bindfs_ativo
    fi
    v_prova_arquivo "$SSHD_DROPIN" "Drop-in do sshd do airlock" \
        --marcador "^Match User[[:space:]]+$TRANSFER_USER\$" || true

    # --- Provas privilegiadas ----------------------------------------------
    # Tudo abaixo depende de ler estado root-only (política efetiva do sshd,
    # chave, metadados, firewall). Sem sudo sem senha o estado NÃO é observado:
    # indeterminado, nunca pendência e muito menos sucesso.
    rc=0
    airlock_aval_privilegio || rc=$?
    if [ "$rc" -ne 0 ]; then
        airlock_v_relatar "$rc" || true
    else
        if v_exigir_comando sshd; then
            rc=0
            airlock_aval_sshd_efetivo || rc=$?
            airlock_v_relatar "$rc" || true
            if [ "$rc" -eq 0 ]; then
                airlock_v_avaliar airlock_aval_sshd_global
                airlock_v_avaliar airlock_aval_sshd_familias
            fi
            if [ "$conta_rc" -eq 1 ]; then
                # Sem conta não existe contexto de conexão para consultar: dizer
                # "política ausente" aqui esconderia a causa real.
                v_falta "Política efetiva de $TRANSFER_USER não avaliada: a conta ainda não existe."
            else
                rc=0
                airlock_aval_sshd_efetivo "user=$TRANSFER_USER,addr=${VM_IP_FIXO:-},host=airlock" || rc=$?
                airlock_v_relatar "$rc" || true
                if [ "$rc" -eq 0 ]; then
                    airlock_v_avaliar airlock_aval_politica_positiva
                    airlock_v_avaliar airlock_aval_politica_negativa
                fi
            fi
        fi
        if [ "$conta_rc" -eq 1 ]; then
            v_falta "Autenticação de $TRANSFER_USER não avaliada: a conta ainda não existe."
        else
            airlock_v_avaliar airlock_aval_autenticacao
        fi
        airlock_v_avaliar airlock_aval_chave
        airlock_v_avaliar airlock_aval_metadados
        rc=0
        airlock_aval_ufw_defaults || rc=$?
        airlock_v_relatar "$rc" || true
        airlock_v_avaliar airlock_aval_ufw_regras
        if [ "$rc" -eq 0 ]; then
            airlock_v_avaliar airlock_aval_ufw_ipv6
        fi
    fi

    airlock_v_avaliar airlock_aval_hook
    v_fim
}

[ "${1:-}" = "--verificar" ] && verificar

guard_mutation airlock.configure || exit 1

instalar_chave() {
    local arquivo_chave="$AIRLOCK_CHAVE_ARQUIVO" temporario fingerprint backup
    titulo "Chave pública do Windows -> $AIRLOCK_CHAVE_ARQUIVO"
    cat <<'COMO'
Dentro da VM (PowerShell), gere o par com windows/Gerar-Chave-Airlock.ps1
(ou: ssh-keygen -t ed25519 -f $env:USERPROFILE\.ssh\airlock -C "airlock-vm").
A chave PRIVADA fica na VM; cole aqui a linha PÚBLICA (começa com ssh-ed25519).
COMO
    read -r -p "Cole a linha pública (ENTER para pular): " LINHA
    if [ -z "$LINHA" ]; then
        aviso "Sem chave por enquanto. Instale depois com: 61-airlock.sh --instalar-chave"
        return 0
    fi
    temporario="$(mktemp)"
    chmod 600 "$temporario"
    printf '%s\n' "$LINHA" > "$temporario"
    if ! fingerprint="$(ssh-keygen -l -f "$temporario" 2>&1)"; then
        rm -f "$temporario"
        falhar "A chave pública não passou na validação do ssh-keygen."
    fi
    info "Fingerprint da chave recebida: $fingerprint"
    if sudo test -s "$arquivo_chave"; then
        backup="${arquivo_chave}.bak-$(date +%Y%m%d-%H%M%S)"
        sudo cp -a "$arquivo_chave" "$backup"
        sudo chmod 600 "$backup"
        info "Chave anterior preservada em $backup (root-only)."
    fi
    sudo install -o root -g root -m 600 "$temporario" "${arquivo_chave}.novo"
    sudo mv -f "${arquivo_chave}.novo" "$arquivo_chave"
    rm -f "$temporario"
    ok "Chave instalada atomicamente (arquivo sob controle do root, fora do alcance do $TRANSFER_USER)."
}

if [ "${1:-}" = "--instalar-chave" ]; then
    exigir_nao_root
    exigir_sudo
    exigir_conf TRANSFER_USER
    nome_usuario_valido "$TRANSFER_USER" \
        || falhar "TRANSFER_USER='$TRANSFER_USER' não é um nome de usuário seguro."
    airlock_resolver_caminhos_conta
    titulo "Troca da chave pública do airlock"
    info "Este submodo altera somente $AIRLOCK_CHAVE_ARQUIVO; não exige reboot."
    aviso "Ao colar uma chave, a chave anterior deixará de autenticar, mas será preservada em backup root-only."
    info "ENTER preserva a chave atual; confira o fingerprint antes de confirmar a troca."
    sudo mkdir -p "$AIRLOCK_CHAVES_DIR"
    sudo chmod 755 "$AIRLOCK_CHAVES_DIR"
    instalar_chave
    exit 0
fi

exigir_nao_root
exigir_conf TRANSFER_USER VM_NAME USUARIO_LINUX REDE_MODO INTERFACE_FISICA VM_IP_FIXO IP_FIXO_HOST
exigir_usuario_linux_valido "$USUARIO_LINUX"
exigir_sudo
exigir_config_rede
nome_usuario_valido "$TRANSFER_USER" \
    || falhar "TRANSFER_USER='$TRANSFER_USER' não é um nome de usuário seguro."
nome_vm_valido "$VM_NAME" || falhar "VM_NAME='$VM_NAME' contém caracteres não seguros para caminhos."
AIRLOCK_REDE_IFACE="$(interface_rede_airlock)"
ip link show "$AIRLOCK_REDE_IFACE" >/dev/null 2>&1 \
    || falhar "Interface $AIRLOCK_REDE_IFACE ausente; conclua e verifique a etapa 19 primeiro."
validar_ips_interface_rede "$AIRLOCK_REDE_IFACE" "$VM_IP_FIXO" "$IP_FIXO_HOST" \
    || falhar "$REDE_IP_ERRO"
caminho_absoluto_seguro "$AIRLOCK_TRANSITO" \
    || falhar "AIRLOCK_DIR precisa ser um caminho absoluto seguro (está: '$AIRLOCK_TRANSITO')."
caminho_absoluto_seguro "$AIRLOCK_BIND" \
    || falhar "AIRLOCK_BIND precisa ser um caminho absoluto seguro (está: '$AIRLOCK_BIND')."
if [ -n "$WORKING_DISK" ] && [ "${WORKING_DISK_DISPENSADO:-}" = "sim" ]; then
    falhar "Configuração contraditória: WORKING_DISK_PATH definido e WORKING_DISK_DISPENSADO=sim."
fi
classificar_airlock_working_disk || falhar "$AIRLOCK_CONTENCAO_ERRO"
if [ "$AIRLOCK_DEPENDS_ON_WORKING_DISK" -eq 1 ]; then
    validar_working_disk_montado "$WORKING_DISK" \
        || falhar "Airlock dentro do workingDisk recusado: $WORKING_DISK_ERRO"
    info "workingDisk ativo antes de qualquer escrita do airlock: $WORKING_DISK (source=$WORKING_DISK_SOURCE; fstype=$WORKING_DISK_FSTYPE)."
fi

# Dependências são instaladas antes da transação; as mutações do Airlock abaixo
# passam a ter rollback do estado que o script gerencia.
dpkg -s bindfs >/dev/null 2>&1 || { sudo apt update; sudo apt install -y bindfs; }
dpkg -s openssh-server >/dev/null 2>&1 || { sudo apt update; sudo apt install -y openssh-server; }
dpkg -s ufw >/dev/null 2>&1 || { sudo apt update; sudo apt install -y ufw; }
airlock_iniciar_transacao
trap airlock_finalizar EXIT INT TERM

titulo "Etapa 20: Airlock (modo: $REDE_MODO; interface: $AIRLOCK_REDE_IFACE; VM: $VM_NAME)"
if [ "$AIRLOCK_TRANSITO" = "$AIRLOCK_BIND" ] \
   || [[ "$AIRLOCK_BIND" == "$AIRLOCK_TRANSITO"/* ]] \
   || [[ "$AIRLOCK_TRANSITO" == "$AIRLOCK_BIND"/* ]]; then
    erro "Pasta de trânsito: $AIRLOCK_TRANSITO"
    erro "Visão do SFTP:     $AIRLOCK_BIND"
    falhar "Os dois caminhos não podem coincidir nem conter um ao outro (montagem sobre si mesma)."
fi
info "Trânsito: $AIRLOCK_TRANSITO  ->  visão exposta: $AIRLOCK_BIND"

echo
cat <<ORIENTACAO
O que é o Airlock: o canal recomendado de troca de arquivos entre o host e a
VM Windows. Não é pasta compartilhada de rede: o host passa a oferecer SFTP na
porta 22 e a VM conecta nele como cliente, autenticando por chave.

São dois caminhos para a MESMA pasta:
  - trânsito, onde os arquivos realmente ficam: $AIRLOCK_TRANSITO
  - visão exposta ao SFTP (chroot), a mesma pasta com dono e permissões
    forçados para o serviço: $AIRLOCK_BIND

Como isso funciona no dia a dia:
  - no host: grave e leia em $AIRLOCK_TRANSITO como em qualquer pasta sua;
  - na VM: WinSCP (ou o comando sftp) apontando para o host $IP_FIXO_HOST com
    o usuário $TRANSFER_USER e a chave privada gerada DENTRO do Windows; a
    sessão abre direto em /$(basename "$AIRLOCK_BIND") e não alcança o resto
    do host;
  - o que um lado grava, o outro vê na hora. É zona de passagem: sem dado
    permanente, fora do backup e montada noexec (nada roda de dentro dela).

Esta execução fará, nesta ordem:
  1. conta: grupo airlock-transfer e usuário sem shell $TRANSFER_USER;
  2. pastas: trânsito $AIRLOCK_TRANSITO e chroot/visão $AIRLOCK_BIND;
  3. fstab/bindfs: backup do fstab, linha persistente e montagem da visão;
  4. SSH: drop-in global $SSHD_DROPIN, chave dedicada e reload imediato;
  5. UFW: regra SFTP para VM Windows $VM_IP_FIXO em $AIRLOCK_REDE_IFACE,
     políticas globais e ativação opcional;
  6. hook: /etc/libvirt/hooks/qemu.d/$VM_NAME/prepare/begin/00-airlock.sh.
workingDisk é opcional. Quando AIRLOCK_DIR está dentro de WORKING_DISK_PATH,
o mountpoint-base externo precisa estar ativo; fora dele, AIRLOCK_DIR usa o
filesystem escolhido pelo operador. Se qualquer fase falhar ou for interrompida,
restaura fstab, SSH/chave, UFW, hook e a conta/grupo que tenha criado. SSH/UFW
podem ter efeito imediato; não há reboot do host, e o hook atua no próximo
start da VM. Revise o acesso por console antes de continuar.
ORIENTACAO

# ----------------------------------------------------------------------------
# 1. Grupo e usuário dedicados
# ----------------------------------------------------------------------------
titulo "Etapa 20.1/7 Grupo e usuário dedicados"
getent group airlock-transfer >/dev/null || sudo groupadd --system airlock-transfer
if ! getent passwd "$TRANSFER_USER" >/dev/null; then
    sudo useradd --system --no-create-home --home-dir /files \
        --shell /usr/sbin/nologin --gid airlock-transfer "$TRANSFER_USER"
fi
id "$TRANSFER_USER"
ok "Conta de sistema sem shell, sem home real e sem senha (raio de alcance mínimo)."

# ----------------------------------------------------------------------------
# 2. Pastas
# ----------------------------------------------------------------------------
titulo "Etapa 20.2/7 Pastas"
classificar_airlock_working_disk || falhar "$AIRLOCK_CONTENCAO_ERRO"
if [ "$AIRLOCK_DEPENDS_ON_WORKING_DISK" -eq 1 ]; then
    validar_working_disk_montado "$WORKING_DISK" \
        || falhar "O workingDisk deixou de estar ativo antes da criação do airlock: $WORKING_DISK_ERRO"
else
    aviso "Pasta de trânsito fora do workingDisk: $AIRLOCK_TRANSITO"
    aviso "Ela vai consumir espaço do filesystem escolhido; mantenha-a como zona de passagem."
fi
sudo mkdir -p "$AIRLOCK_TRANSITO"
sudo mkdir -p "$AIRLOCK_BIND"
sudo chown root:root "$AIRLOCK_BASE"
sudo chmod 755 "$AIRLOCK_BASE"
ok "Trânsito: $AIRLOCK_TRANSITO | Base do chroot (root:root 755): $AIRLOCK_BASE"

# ----------------------------------------------------------------------------
# 3. Visão de serviço (bindfs)
# ----------------------------------------------------------------------------
titulo "Etapa 20.3/7 Visão de serviço (bindfs)"
classificar_airlock_working_disk || falhar "$AIRLOCK_CONTENCAO_ERRO"
if [ "$AIRLOCK_DEPENDS_ON_WORKING_DISK" -eq 1 ]; then
    validar_working_disk_montado "$WORKING_DISK" \
        || falhar "O workingDisk deixou de estar ativo antes do bindfs do airlock: $WORKING_DISK_ERRO"
fi
OPCOES_BINDFS="$(airlock_opcoes_bindfs)"
fstab_backup
fstab_definir_linha airlock-bindfs \
    "$(sed 's/ /\\040/g' <<< "$AIRLOCK_TRANSITO")  $(sed 's/ /\\040/g' <<< "$AIRLOCK_BIND")  fuse.bindfs  $OPCOES_BINDFS  0  0"
sudo mount -a
mountpoint -q "$AIRLOCK_BIND" || falhar "Visão bindfs não montou; confira a linha no fstab."
sudo -u "$TRANSFER_USER" touch "$AIRLOCK_BIND/.teste-escrita"
[ -e "$AIRLOCK_TRANSITO/.teste-escrita" ] \
    || falhar "Arquivo criado na visão não apareceu em $AIRLOCK_TRANSITO."
sudo -u "$TRANSFER_USER" rm "$AIRLOCK_BIND/.teste-escrita"
ok "Ponta a ponta confirmado: escrita do $TRANSFER_USER na visão chega a $AIRLOCK_TRANSITO."

# ----------------------------------------------------------------------------
# 4. Servidor SSH endurecido
# ----------------------------------------------------------------------------
titulo "Etapa 20.4/7 Servidor SSH"
sudo mkdir -p "$AIRLOCK_CHAVES_DIR"
sudo chmod 755 "$AIRLOCK_CHAVES_DIR"

echo
cat <<SSHEXPLICA
Este drop-in ($SSHD_DROPIN) é lido pelo sshd
porque /etc/ssh/sshd_config tem um Include para /etc/ssh/sshd_config.d/*.conf,
como se o conteúdo estivesse colado no início da configuração. Ele tem DUAS
partes bem diferentes:

  1) GLOBAL, vale para todos os usuários do SSH:
     PasswordAuthentication no       login por senha deixa de existir
     KbdInteractiveAuthentication no fecha o caminho alternativo via PAM
     PermitRootLogin no              root não entra mais por SSH

  2) SÓ PARA $TRANSFER_USER, no bloco Match User:
     chroot em $AIRLOCK_BASE (a sessão vê essa pasta como se fosse a raiz),
     internal-sftp com umask 0007 (sem shell, sem comando arbitrário),
     chave lida de $AIRLOCK_CHAVE_ARQUIVO, que pertence ao
     root e fica fora do alcance da própria conta, e nenhum forwarding ou
     túnel, para a sessão de arquivos não virar ponte de rede.

O RISCO está na parte GLOBAL. Cenário concreto: se hoje você administra este
host de outro dispositivo com "ssh $USUARIO_LINUX@<IP-do-host-na-LAN>"
digitando a SENHA, no instante do reload do sshd esse caminho deixa de
existir. Aquele dispositivo passa a receber "Permission denied (publickey)" e
não há como consertar remotamente, porque para consertar você precisaria
justamente do SSH. Por isso: instale a chave pública nesse dispositivo ANTES
de responder s.

O que NÃO é afetado: o console local. Sentado na frente da máquina, com
teclado e monitor, o login não passa pelo sshd, então PasswordAuthentication
não tem efeito nenhum ali. O sudo também continua pedindo sua senha como
sempre. Recusar aqui também é seguro: a etapa cai no rollback e devolve
fstab, SSH, chave, UFW, hook e a conta que tenha criado.

Se o TRANSFER_USER for a MESMA conta que você usa para administrar o host,
lembre que o bloco Match acima passa a valer para ela: SSH com essa conta vira
SFTP dentro do chroot, sem shell. Uma conta dedicada (ex.: vmtransfer) mantém
as duas funções separadas.

Antes de recarregar, a configuração passa por sshd -t e por sshd -T do usuário
Airlock; se qualquer uma reprovar, nada é aplicado e o rollback assume.

Mais adiante, a etapa 20.6 faz o cuidado equivalente no firewall: ela pergunta
se você acessa este host por SSH de outro dispositivo e, se sim, cria a regra
"allow from <IP> to any port 22" ANTES de aplicar default deny incoming.
Tenha o IPv4 desse dispositivo em mãos.
SSHEXPLICA
echo
aviso "Endurecimento GLOBAL do sshd: PasswordAuthentication no / PermitRootLogin no."
aviso "Se você acessa ESTE host por SSH com SENHA de outro dispositivo, configure"
aviso "chave SSH nesse dispositivo ANTES, ou ele perderá o acesso (console local nunca é afetado)."
confirmar "Aplicar o drop-in $SSHD_DROPIN?" || falhar "Cancelado."

sudo tee "$SSHD_DROPIN" >/dev/null <<'SSHDCONF'
# Endurecimento global - a porta 22 fica alcancavel pela VM (etapa 20).
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no

# Confinamento do usuario de transferencia do airlock
Match User @TRANSFER_USER@
    ChrootDirectory @AIRLOCK_BASE@
    ForceCommand internal-sftp -u 0007
    AuthorizedKeysFile @AIRLOCK_CHAVES_DIR@/%u
    PubkeyAuthentication yes
    AllowTcpForwarding no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTunnel no
SSHDCONF
sudo sed -i \
    -e "s|@TRANSFER_USER@|$TRANSFER_USER|g" \
    -e "s|@AIRLOCK_BASE@|$AIRLOCK_BASE|g" \
    -e "s|@AIRLOCK_CHAVES_DIR@|$AIRLOCK_CHAVES_DIR|g" \
    "$SSHD_DROPIN"

sudo sshd -t || falhar "sshd -t reprovou a configuração; o rollback será executado."
# Pré-condição: a política EFETIVA (não o texto do arquivo) precisa estar
# provada antes do reload. A saída do sshd -T -C deixou de ser descartada: ela
# alimenta os mesmos avaliadores que o --verificar usa.
airlock_exigir_politica_sshd "antes do reload"
sudo systemctl enable --now ssh
sudo systemctl reload ssh
# Pós-condição pós-commit: o reload é o commit desta fase, e um drop-in válido
# no disco não prova que o daemon recarregado passou a aplicá-lo. A mesma prova
# é repetida DEPOIS do reload; qualquer divergência cai no rollback.
airlock_exigir_politica_sshd "depois do reload"
ok "sshd validado (sshd -t, política efetiva antes e depois do reload) e recarregado."

# ----------------------------------------------------------------------------
# 5. Chave pública gerada dentro do Windows
# ----------------------------------------------------------------------------
titulo "Etapa 20.5/7 Chave"
if [ -s "$AIRLOCK_CHAVE_ARQUIVO" ]; then
    info "Já existe chave instalada para $TRANSFER_USER (troque com --instalar-chave)."
else
    instalar_chave
fi

# ----------------------------------------------------------------------------
# 6. Firewall (ufw)
# ----------------------------------------------------------------------------
titulo "Etapa 20.6/7 Firewall (ufw: $AIRLOCK_REDE_IFACE <- $VM_IP_FIXO)"
aviso "As regras e políticas UFW abaixo são globais. Se o UFW já estiver ativo, cada alteração terá efeito imediato."
aviso "Se você administra por SSH, deixar o IP do administrador vazio pode bloquear o acesso quando deny incoming for aplicado."
info "Informe um IPv4 administrativo estável/correto ou garanta acesso por console antes de prosseguir."

# O comentário é a identidade da regra gerenciada. Captura e valida TODAS as
# ocorrências antes de qualquer adição; uma ocorrência não parseável fecha o
# fluxo em vez de deixar uma abertura residual sem controle.
coletar_regras_ufw_airlock normal || falhar "$UFW_COLETA_ERRO"
if confirmar "Você acessa este host por SSH de OUTRO dispositivo (ex.: notebook)?"; then
    IP_ADMIN="$(perguntar 'IPv4 do dispositivo administrador' '')"
    if [ -n "$IP_ADMIN" ]; then
        ipv4_valido "$IP_ADMIN" || falhar "IPv4 do administrador inválido: '$IP_ADMIN'."
        sudo ufw allow from "$IP_ADMIN" to any port 22 proto tcp comment 'SSH admin'
        ok "Regra anti-lockout criada para $IP_ADMIN."
    fi
fi
TOTAL_EXATAS="$(contar_regras_ufw_airlock_exatas "$AIRLOCK_REDE_IFACE" "$VM_IP_FIXO")"
if [ "$TOTAL_EXATAS" -eq 0 ]; then
    sudo ufw allow in on "$AIRLOCK_REDE_IFACE" from "$VM_IP_FIXO" \
        to any port 22 proto tcp comment "$UFW_MARCADOR"
fi
coletar_regras_ufw_airlock normal || falhar "$UFW_COLETA_ERRO"
TOTAL_MARCADAS="${#UFW_REGRAS_MARCADAS[@]}"
TOTAL_EXATAS="$(contar_regras_ufw_airlock_exatas "$AIRLOCK_REDE_IFACE" "$VM_IP_FIXO")"
[ "$TOTAL_EXATAS" -eq 1 ] || falhar "A regra substituta UFW não pôde ser comprovada antes de remover regras antigas."
sudo ufw default deny incoming
sudo ufw default allow outgoing
MANTEVE_EXATA=0
for IDX_REGRA in "${!UFW_REGRAS_IFACES[@]}"; do
    if [ "${UFW_REGRAS_IFACES[$IDX_REGRA]}" = "$AIRLOCK_REDE_IFACE" ] && [ "${UFW_REGRAS_IPS[$IDX_REGRA]}" = "$VM_IP_FIXO" ] && [ "$MANTEVE_EXATA" -eq 0 ]; then
        MANTEVE_EXATA=1
        continue
    fi
    sudo ufw --force delete allow in on "${UFW_REGRAS_IFACES[$IDX_REGRA]}" from "${UFW_REGRAS_IPS[$IDX_REGRA]}" \
        to any port 22 proto tcp comment "$UFW_MARCADOR" >/dev/null || falhar "Falha ao remover regra UFW antiga; o rollback será executado."
done
coletar_regras_ufw_airlock normal || falhar "$UFW_COLETA_ERRO"
TOTAL_MARCADAS="${#UFW_REGRAS_MARCADAS[@]}"
TOTAL_EXATAS="$(contar_regras_ufw_airlock_exatas "$AIRLOCK_REDE_IFACE" "$VM_IP_FIXO")"
[ "$TOTAL_MARCADAS" -eq 1 ] && [ "$TOTAL_EXATAS" -eq 1 ] || falhar "Pós-condição UFW falhou; o rollback será executado."
ok "UFW confirmado com exatamente uma regra marcada e exata para interface/IP/porta/protocolo atuais."
echo
aviso "Política: tudo que não for liberado explicitamente será bloqueado na entrada."
if confirmar "Ativar o ufw agora?"; then
    sudo ufw --force enable
    sudo ufw status verbose
    ok "Firewall ativo e persistente entre boots."
else
    aviso "ufw configurado mas NÃO ativado (ative depois com: sudo ufw enable)."
fi

# ----------------------------------------------------------------------------
# 7. Hook 00-airlock.sh (antes do 01-gpu-preflight.sh, ordem alfabética)
# ----------------------------------------------------------------------------
titulo "Etapa 20.7/7 Hook de criação automática"
sudo mkdir -p "$HOOK_DIR"
sudo tee "$HOOK_FILE" >/dev/null <<'HOOKAIR'
#!/bin/bash
# 00-airlock.sh (gerado por etapas/61-airlock.sh)
# Garante a pasta de transito e sua visao de servico antes da preparacao da GPU.
# Projetado para NUNCA impedir o inicio da VM: qualquer falha aqui apenas
# registra um aviso no journal (via logger) e o script termina com sucesso.

AIRLOCK_TRANSITO="@AIRLOCK_TRANSITO@"
AIRLOCK_BIND="@AIRLOCK_BIND@"
WORKING_DISK="@WORKING_DISK@"
AIRLOCK_DEPENDS_ON_WORKING_DISK=0

caminho_lexico_normalizado() {
    local caminho="${1:-}"
    while [[ "$caminho" == *//* ]]; do caminho="${caminho//\/\//\/}"; done
    while [ "$caminho" != / ] && [[ "$caminho" == */ ]]; do caminho="${caminho%/}"; done
    printf '%s\n' "$caminho"
}
caminho_igual_ou_filho() {
    local caminho="${1:-}" base="${2:-}"
    [ "$caminho" = "$base" ] && return 0
    [ "$base" = / ] && return 0
    [[ "$caminho" == "$base"/* ]]
}
classificar_airlock_working_disk() {
    local caminho_lexico base_lexica caminho_fisico base_fisica
    local lexical_dentro=0 fisico_dentro=0
    AIRLOCK_DEPENDS_ON_WORKING_DISK=0
    [ -n "$WORKING_DISK" ] || return 0
    command -v readlink >/dev/null 2>&1 || return 2
    caminho_lexico="$(caminho_lexico_normalizado "$AIRLOCK_TRANSITO")" \
        && base_lexica="$(caminho_lexico_normalizado "$WORKING_DISK")" \
        && caminho_fisico="$(readlink -m -- "$AIRLOCK_TRANSITO" 2>/dev/null)" \
        && base_fisica="$(readlink -m -- "$WORKING_DISK" 2>/dev/null)" \
        || return 2
    [ "$WORKING_DISK" = "$base_lexica" ] && [ "$base_fisica" = "$base_lexica" ] || return 2
    caminho_igual_ou_filho "$caminho_lexico" "$base_lexica" && lexical_dentro=1
    caminho_igual_ou_filho "$caminho_fisico" "$base_fisica" && fisico_dentro=1
    [ "$lexical_dentro" -eq 1 ] && [ "$fisico_dentro" -ne 1 ] && return 2
    [ "$fisico_dentro" -eq 1 ] && AIRLOCK_DEPENDS_ON_WORKING_DISK=1
    return 0
}
working_disk_ativo() {
    local alvo
    [ -d "$WORKING_DISK" ] || return 1
    mountpoint -q -- "$WORKING_DISK" || return 1
    alvo="$(findmnt -rn --raw --mountpoint "$WORKING_DISK" --output TARGET 2>/dev/null)" || return 1
    [ "$alvo" = "$WORKING_DISK" ]
}
destino_airlock_disponivel() {
    classificar_airlock_working_disk || return $?
    [ "$AIRLOCK_DEPENDS_ON_WORKING_DISK" = "0" ] || working_disk_ativo
}

# Recalcula a relação física imediatamente antes de cada mutação. Em caso de
# escape simbólico ou mount ausente, o hook preserva o contrato de não impedir
# o início da VM e não cria/monta nada.
if ! destino_airlock_disponivel; then
    logger -t hook-qemu "AVISO: destino do airlock não pôde ser comprovado com o workingDisk ativo; airlock indisponível nesta sessão da VM."
    exit 0
fi
if [ ! -d "$AIRLOCK_TRANSITO" ]; then
    mkdir -p "$AIRLOCK_TRANSITO" && logger -t hook-qemu "pasta airlock criada em $AIRLOCK_TRANSITO"
fi

if ! destino_airlock_disponivel; then
    logger -t hook-qemu "AVISO: destino do airlock mudou ou o workingDisk ficou indisponível; bindfs não será montado nesta sessão da VM."
    exit 0
fi
if ! mountpoint -q "$AIRLOCK_BIND"; then
    if mount "$AIRLOCK_BIND" 2>/dev/null; then
        logger -t hook-qemu "visao bindfs do airlock montada em $AIRLOCK_BIND"
    else
        logger -t hook-qemu "AVISO: falha ao montar $AIRLOCK_BIND (verifique a linha bindfs no fstab)."
    fi
fi

exit 0
HOOKAIR
sudo sed -i \
    -e "s|@AIRLOCK_TRANSITO@|$AIRLOCK_TRANSITO|g" \
    -e "s|@AIRLOCK_BIND@|$AIRLOCK_BIND|g" \
    -e "s|@WORKING_DISK@|$WORKING_DISK|g" \
    "$HOOK_FILE"
sudo chmod +x "$HOOK_FILE"
sudo chown root:root "$HOOK_FILE"
ok "Hook instalado: $HOOK_FILE (roda ANTES do 01-gpu-preflight.sh)."

# ----------------------------------------------------------------------------
echo
titulo "Como testar (as 7 verificações da etapa 20)"
IP_FIXO_HOST_DISPLAY="${IP_FIXO_HOST:-<IP_FIXO_HOST>}"
SUBDIR="$(basename "$AIRLOCK_BIND")"
if [ "$REDE_MODO" = "bridge" ]; then
    TESTE_FIREWALL="de OUTRO dispositivo da LAN a porta 22 deve dar TIMEOUT; da VM, conecta"
else
    TESTE_FIREWALL="a LAN não possui rota para a sub-rede NAT; confirme que a regra existe SOMENTE em $AIRLOCK_REDE_IFACE para $VM_IP_FIXO"
fi
cat <<TESTES
1. Visão:        mount | grep airlock  (tipo fuse.bindfs) - teste de escrita já feito acima.
2. sshd:         sudo sshd -t (sem saída) e systemctl status ssh.
3. Transferência:na VM, WinSCP (SFTP, host $IP_FIXO_HOST_DISPLAY, usuário $TRANSFER_USER,
                 chave %USERPROFILE%\\.ssh\\airlock) -> a sessão abre em /$SUBDIR.
                 O que você envia aparece em $AIRLOCK_TRANSITO (e vice-versa).
4. Confinamento: no WinSCP, subir para / mostra APENAS $SUBDIR/.
5. Autenticação: ssh sem chave -> "Permission denied (publickey)" imediato.
6. Firewall:     $TESTE_FIREWALL.
                 Verifique: sudo ufw show added (interface $AIRLOCK_REDE_IFACE).
7. Hook:         com a VM desligada: sudo umount $AIRLOCK_BIND; iniciar a VM;
                 journalctl -t hook-qemu -b deve registrar a remontagem.

Regras operacionais: airlock é zona de TRÂNSITO (sem dados permanentes, fora
do backup); nunca execute binários vindos dela (a visão é noexec).
TESTES
ok "Etapa 20 concluída."
