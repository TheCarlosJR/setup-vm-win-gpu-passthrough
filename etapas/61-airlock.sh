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
    HOOK_DIR="/etc/libvirt/hooks/qemu.d/$VM_NAME/prepare/begin"
    HOOK_FILE="$HOOK_DIR/00-airlock.sh"
    airlock_salvar_arquivo fstab "$FSTAB"
    airlock_salvar_arquivo sshd-dropin "$SSHD_DROPIN"
    airlock_salvar_arquivo chave "/etc/ssh/authorized_keys/$TRANSFER_USER"
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
    airlock_restaurar_arquivo chave "/etc/ssh/authorized_keys/$TRANSFER_USER" || aviso "Não foi possível restaurar a chave anterior."
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
        UFW_COLETA_ERRO="Há ${#UFW_REGRAS_INVALIDAS[@]} regra(s) com o comentário exato, mas fora do formato seguro esperado: ${UFW_REGRAS_INVALIDAS[0]}"
        return 1
    fi
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
SSHD_DROPIN="/etc/ssh/sshd_config.d/10-airlock.conf"

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

verificar() {
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
    getent passwd "$TRANSFER_USER" >/dev/null && v_ok "Usuário $TRANSFER_USER existe." || v_falta "Usuário $TRANSFER_USER ausente."
    mountpoint -q "$AIRLOCK_BIND" && v_ok "Visão bindfs montada." || v_falta "Visão bindfs não montada."
    [ -f "$SSHD_DROPIN" ] && v_ok "Drop-in do sshd presente." || v_falta "Drop-in do sshd ausente."
    [ -s "/etc/ssh/authorized_keys/${TRANSFER_USER}" ] && v_ok "Chave pública instalada." || v_falta "Chave pública pendente."
    if command -v ufw >/dev/null 2>&1; then
        if sudo -n ufw status 2>/dev/null | grep -q 'Status: active'; then
            v_ok "ufw ativo."
        else
            v_falta "ufw inativo (ou sem sudo sem senha para checar)."
        fi
        if coletar_regras_ufw_airlock sem-senha; then
            TOTAL_MARCADAS="${#UFW_REGRAS_MARCADAS[@]}"
            TOTAL_EXATAS="$(contar_regras_ufw_airlock_exatas "$AIRLOCK_REDE_IFACE" "${VM_IP_FIXO:-}")"
            if [ "$TOTAL_MARCADAS" -eq 1 ] && [ "$TOTAL_EXATAS" -eq 1 ]; then
                v_ok "UFW contém exatamente uma regra marcada, exata para interface=$AIRLOCK_REDE_IFACE, origem=$VM_IP_FIXO, porta=22/tcp."
            else
                v_falta "UFW exige total marcado=1 e exato=1; encontrado marcado=$TOTAL_MARCADAS, exato=$TOTAL_EXATAS. Remova regras residuais."
            fi
        else
            v_falta "$UFW_COLETA_ERRO"
        fi
    else
        v_falta "ufw não instalado."
    fi
    [ -x "/etc/libvirt/hooks/qemu.d/${VM_NAME:-}/prepare/begin/00-airlock.sh" ] \
        && v_ok "Hook 00-airlock.sh instalado." || v_falta "Hook 00-airlock.sh ausente."
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

guard_mutation airlock.configure || exit 1

instalar_chave() {
    local arquivo_chave="/etc/ssh/authorized_keys/$TRANSFER_USER" temporario fingerprint backup
    titulo "Chave pública do Windows -> /etc/ssh/authorized_keys/$TRANSFER_USER"
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
    titulo "Troca da chave pública do airlock"
    info "Este submodo altera somente /etc/ssh/authorized_keys/$TRANSFER_USER; não exige reboot."
    aviso "Ao colar uma chave, a chave anterior deixará de autenticar, mas será preservada em backup root-only."
    info "ENTER preserva a chave atual; confira o fingerprint antes de confirmar a troca."
    sudo mkdir -p /etc/ssh/authorized_keys
    sudo chmod 755 /etc/ssh/authorized_keys
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
Airlock/SFTP é o canal recomendado; esta execução fará, nesta ordem:
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
OPCOES_BINDFS="force-user=$TRANSFER_USER,force-group=airlock-transfer,perms=0770,chmod-ignore,chown-ignore,allow_other,noexec,nosuid,nodev,nofail"
[ "$AIRLOCK_DEPENDS_ON_WORKING_DISK" -eq 1 ] && OPCOES_BINDFS="${OPCOES_BINDFS},x-systemd.requires=$(sed 's/ /\\040/g' <<< "$WORKING_DISK")"
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
sudo mkdir -p /etc/ssh/authorized_keys
sudo chmod 755 /etc/ssh/authorized_keys

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
    AuthorizedKeysFile /etc/ssh/authorized_keys/%u
    PubkeyAuthentication yes
    AllowTcpForwarding no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTunnel no
SSHDCONF
sudo sed -i \
    -e "s|@TRANSFER_USER@|$TRANSFER_USER|g" \
    -e "s|@AIRLOCK_BASE@|$AIRLOCK_BASE|g" \
    "$SSHD_DROPIN"

sudo sshd -t || falhar "sshd -t reprovou a configuração; o rollback será executado."
sudo sshd -T -C "user=$TRANSFER_USER,addr=$VM_IP_FIXO,host=airlock" >/dev/null \
    || falhar "sshd -T -C reprovou a configuração efetiva do usuário Airlock; o rollback será executado."
sudo systemctl enable --now ssh
sudo systemctl reload ssh
ok "sshd validado (sshd -t) e recarregado."

# ----------------------------------------------------------------------------
# 5. Chave pública gerada dentro do Windows
# ----------------------------------------------------------------------------
titulo "Etapa 20.5/7 Chave"
if [ -s "/etc/ssh/authorized_keys/$TRANSFER_USER" ]; then
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
