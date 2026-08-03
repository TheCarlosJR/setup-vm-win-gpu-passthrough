#!/bin/bash
# ============================================================================
# etapas/61-airlock.sh - Capítulo 24: Compartilhamento Seguro (Airlock)
# ============================================================================
# Canal recomendado de troca host<->VM, exposto por SFTP com chroot, chave
# obrigatória, usuário sem shell e firewall restrito ao IP fixo da VM.
# O HD2 é dispensável: sem AIRLOCK_DIR, o padrão é /mnt/docs4/airlock e requer
# /mnt/docs4 montado; configure AIRLOCK_DIR em outro filesystem para não usá-lo.
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

DOCS4="${DOCS4_MONTAGEM:-/mnt/docs4}"
# Pasta de TRÂNSITO: configurável (etapa 02). Padrão: dentro do HD2.
AIRLOCK_TRANSITO="${AIRLOCK_DIR:-$DOCS4/airlock}"
AIRLOCK_BIND="${AIRLOCK_BIND:-/srv/airlock/files}"
AIRLOCK_BASE="$(dirname "$AIRLOCK_BIND")"
SSHD_DROPIN="/etc/ssh/sshd_config.d/10-airlock.conf"

# A visão só depende do docs4 quando a pasta de trânsito mora nele
DEPENDE_DOCS4=0
case "$AIRLOCK_TRANSITO" in
    "$DOCS4"/*) DEPENDE_DOCS4=1 ;;
esac

verificar() {
    if ! validar_config_rede; then
        v_falta "$REDE_CONFIG_ERRO"
        v_fim
    fi
    AIRLOCK_REDE_IFACE="$(interface_rede_airlock)"
    if ip link show "$AIRLOCK_REDE_IFACE" >/dev/null 2>&1; then
        v_ok "Interface do airlock: $AIRLOCK_REDE_IFACE (modo $REDE_MODO)."
    else
        v_falta "Interface do airlock $AIRLOCK_REDE_IFACE ausente; conclua a etapa 60."
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

instalar_chave() {
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
    case "$LINHA" in
        ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*)
            echo "$LINHA" | sudo tee "/etc/ssh/authorized_keys/$TRANSFER_USER" >/dev/null
            sudo chown root:root "/etc/ssh/authorized_keys/$TRANSFER_USER"
            sudo chmod 644 "/etc/ssh/authorized_keys/$TRANSFER_USER"
            ok "Chave instalada (arquivo sob controle do root, fora do alcance do $TRANSFER_USER)."
            ;;
        *)
            falhar "Isso não parece uma chave pública OpenSSH válida."
            ;;
    esac
}

if [ "${1:-}" = "--instalar-chave" ]; then
    exigir_nao_root
    exigir_sudo
    exigir_conf TRANSFER_USER
    nome_usuario_valido "$TRANSFER_USER" \
        || falhar "TRANSFER_USER='$TRANSFER_USER' não é um nome de usuário seguro."
    titulo "Troca da chave pública do airlock"
    info "Este submodo altera somente /etc/ssh/authorized_keys/$TRANSFER_USER; não exige reboot."
    aviso "Ao colar uma chave, o arquivo inteiro será sobrescrito e a chave anterior deixará de autenticar."
    info "ENTER preserva a chave atual; para recuperar uma troca incorreta, reinstale a chave por console ou acesso administrativo."
    sudo mkdir -p /etc/ssh/authorized_keys
    sudo chmod 755 /etc/ssh/authorized_keys
    instalar_chave
    exit 0
fi

exigir_nao_root
exigir_sudo
exigir_conf TRANSFER_USER VM_NAME USUARIO_LINUX REDE_MODO INTERFACE_FISICA VM_IP_FIXO IP_FIXO_HOST
exigir_config_rede
nome_usuario_valido "$TRANSFER_USER" \
    || falhar "TRANSFER_USER='$TRANSFER_USER' não é um nome de usuário seguro."
nome_vm_valido "$VM_NAME" || falhar "VM_NAME='$VM_NAME' contém caracteres não seguros para caminhos."
AIRLOCK_REDE_IFACE="$(interface_rede_airlock)"
ip link show "$AIRLOCK_REDE_IFACE" >/dev/null 2>&1 \
    || falhar "Interface $AIRLOCK_REDE_IFACE ausente; conclua e verifique a etapa 60 primeiro."
validar_ips_interface_rede "$AIRLOCK_REDE_IFACE" "$VM_IP_FIXO" "$IP_FIXO_HOST" \
    || falhar "$REDE_IP_ERRO"

# Dependências são instaladas antes da transação; as mutações do Airlock abaixo
# passam a ter rollback do estado que o script gerencia.
dpkg -s bindfs >/dev/null 2>&1 || { sudo apt update; sudo apt install -y bindfs; }
dpkg -s openssh-server >/dev/null 2>&1 || { sudo apt update; sudo apt install -y openssh-server; }
dpkg -s ufw >/dev/null 2>&1 || { sudo apt update; sudo apt install -y ufw; }
airlock_iniciar_transacao
trap airlock_finalizar EXIT INT TERM

titulo "Capítulo 24: Airlock (modo: $REDE_MODO; interface: $AIRLOCK_REDE_IFACE; VM: $VM_NAME)"
case "$AIRLOCK_TRANSITO" in
    /*) : ;;
    *)  falhar "AIRLOCK_DIR precisa ser um caminho absoluto (está: '$AIRLOCK_TRANSITO')." ;;
esac
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
HD2 é dispensável: o padrão é /mnt/docs4/airlock; AIRLOCK_DIR pode apontar
para outro filesystem. Se qualquer fase falhar ou for interrompida, o script
restaura fstab, SSH/chave, UFW, hook e a conta/grupo que tenha criado. SSH/UFW
podem ter efeito imediato; não há reboot do host, e o hook atua no próximo
start da VM. Revise o acesso por console antes de continuar.
ORIENTACAO

# ----------------------------------------------------------------------------
# 1. Grupo e usuário dedicados
# ----------------------------------------------------------------------------
titulo "1/7 Grupo e usuário dedicados"
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
titulo "2/7 Pastas"
if [ "$DEPENDE_DOCS4" -eq 1 ]; then
    mountpoint -q "$DOCS4" \
        || falhar "A pasta de trânsito está em $DOCS4, que não está montado (etapa 14 / Capítulo 11)."
else
    aviso "Pasta de trânsito fora do HD2: $AIRLOCK_TRANSITO"
    aviso "Ela vai consumir espaço do disco onde está; mantenha-a como zona de passagem."
fi
sudo mkdir -p "$AIRLOCK_TRANSITO"
sudo mkdir -p "$AIRLOCK_BIND"
sudo chown root:root "$AIRLOCK_BASE"
sudo chmod 755 "$AIRLOCK_BASE"
ok "Trânsito: $AIRLOCK_TRANSITO | Base do chroot (root:root 755): $AIRLOCK_BASE"

# ----------------------------------------------------------------------------
# 3. Visão de serviço (bindfs)
# ----------------------------------------------------------------------------
titulo "3/7 Visão de serviço (bindfs)"
OPCOES_BINDFS="force-user=$TRANSFER_USER,force-group=airlock-transfer,perms=0770,chmod-ignore,chown-ignore,allow_other,noexec,nosuid,nodev,nofail"
[ "$DEPENDE_DOCS4" -eq 1 ] && OPCOES_BINDFS="${OPCOES_BINDFS},x-systemd.requires=$(sed 's/ /\\040/g' <<< "$DOCS4")"
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
titulo "4/7 Servidor SSH"
sudo mkdir -p /etc/ssh/authorized_keys
sudo chmod 755 /etc/ssh/authorized_keys

echo
aviso "Endurecimento GLOBAL do sshd: PasswordAuthentication no / PermitRootLogin no."
aviso "Se você acessa ESTE host por SSH com SENHA de outro dispositivo, configure"
aviso "chave SSH nesse dispositivo ANTES, ou ele perderá o acesso (console local nunca é afetado)."
confirmar "Aplicar o drop-in $SSHD_DROPIN?" || falhar "Cancelado."

sudo tee "$SSHD_DROPIN" >/dev/null <<'SSHDCONF'
# Endurecimento global - a porta 22 fica alcancavel pela VM (Capitulo 24).
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
titulo "5/7 Chave"
if [ -s "/etc/ssh/authorized_keys/$TRANSFER_USER" ]; then
    info "Já existe chave instalada para $TRANSFER_USER (troque com --instalar-chave)."
else
    instalar_chave
fi

# ----------------------------------------------------------------------------
# 6. Firewall (ufw)
# ----------------------------------------------------------------------------
titulo "6/7 Firewall (ufw: $AIRLOCK_REDE_IFACE <- $VM_IP_FIXO)"
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
titulo "7/7 Hook de criação automática"
sudo mkdir -p "$HOOK_DIR"
sudo tee "$HOOK_FILE" >/dev/null <<'HOOKAIR'
#!/bin/bash
# 00-airlock.sh (gerado por etapas/61-airlock.sh)
# Garante a pasta de transito e sua visao de servico antes da preparacao da GPU.
# Projetado para NUNCA impedir o inicio da VM: qualquer falha aqui apenas
# registra um aviso no journal (via logger) e o script termina com sucesso.

AIRLOCK_TRANSITO="@AIRLOCK_TRANSITO@"
AIRLOCK_BIND="@AIRLOCK_BIND@"
DOCS4="@DOCS4@"
DEPENDE_DOCS4="@DEPENDE_DOCS4@"

# 1) Se a pasta de transito mora no HD2, ele precisa estar montado; sem isso,
#    criar a pasta poluiria o ponto de montagem vazio no disco do sistema em
#    vez do HD2 real (alerta do Capitulo 11).
if [ "$DEPENDE_DOCS4" = "1" ] && ! mountpoint -q "$DOCS4"; then
    logger -t hook-qemu "AVISO: $DOCS4 nao montado; airlock indisponivel nesta sessao da VM."
    exit 0
fi

# 2) Cria a pasta de transito, se ausente (idempotente).
#    Sem chown/chmod: em NTFS (ntfs-3g), dono e permissoes vem das opcoes
#    de montagem do fstab (Capitulo 11) e nao podem ser alterados por pasta.
if [ ! -d "$AIRLOCK_TRANSITO" ]; then
    mkdir -p "$AIRLOCK_TRANSITO" && logger -t hook-qemu "pasta airlock criada em $AIRLOCK_TRANSITO"
fi

# 3) Garante a visao de servico (bindfs) montada, usando a entrada do fstab.
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
    -e "s|@DOCS4@|$DOCS4|g" \
    -e "s|@DEPENDE_DOCS4@|$DEPENDE_DOCS4|g" \
    "$HOOK_FILE"
sudo chmod +x "$HOOK_FILE"
sudo chown root:root "$HOOK_FILE"
ok "Hook instalado: $HOOK_FILE (roda ANTES do 01-gpu-preflight.sh)."

# ----------------------------------------------------------------------------
echo
titulo "Como testar (as 7 verificações do Capítulo 24)"
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
do backup); nunca execute binários vindos dela (a visão é noexec); nunca crie
exclusão do Defender para essa pasta dentro do Windows.
TESTES
ok "Etapa 61 concluída."
