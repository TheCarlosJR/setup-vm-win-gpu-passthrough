#!/bin/bash
# ============================================================================
# etapas/61-airlock.sh - Capítulo 24: Compartilhamento Seguro (Airlock)
# ============================================================================
# Canal ÚNICO de troca de arquivos host<->VM: /mnt/docs4/airlock exposto por
# SFTP com chroot, chave obrigatória, usuário dedicado sem shell e firewall
# restrito ao IP fixo da VM. As pastas reais do HD2 nunca são expostas.
#
#   1. Grupo/usuário dedicados (airlock-transfer / vmtransfer)
#   2. Pastas: /mnt/docs4/airlock (HD2) + /srv/airlock/files (chroot, NVMe)
#   3. Visão de serviço bindfs (fstab, noexec/nosuid/nodev)
#   4. sshd endurecido global + Match User com chroot e internal-sftp
#   5. Instalação da chave pública gerada DENTRO do Windows
#   6. Firewall ufw: porta 22 apenas para o VM_IP_FIXO (com anti-lockout)
#   7. Hook 00-airlock.sh (criação automática e idempotente a cada boot da VM)
#
# Uso:
#   61-airlock.sh                  execução completa (idempotente)
#   61-airlock.sh --instalar-chave somente instala/troca a chave pública
#   61-airlock.sh --verificar      status
#
# Observação: a alternativa Samba do manual NÃO é instalada por este script
# (o manual manda escolher UM método; o padrão é SFTP).
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf
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
    [ -n "${TRANSFER_USER:-}" ] || { v_falta "TRANSFER_USER não definido."; v_fim; }
    getent passwd "$TRANSFER_USER" >/dev/null && v_ok "Usuário $TRANSFER_USER existe." || v_falta "Usuário $TRANSFER_USER ausente."
    mountpoint -q "$AIRLOCK_BIND" && v_ok "Visão bindfs montada." || v_falta "Visão bindfs não montada."
    [ -f "$SSHD_DROPIN" ] && v_ok "Drop-in do sshd presente." || v_falta "Drop-in do sshd ausente."
    [ -s "/etc/ssh/authorized_keys/${TRANSFER_USER}" ] && v_ok "Chave pública instalada." || v_falta "Chave pública pendente."
    if command -v ufw >/dev/null 2>&1 && sudo -n ufw status 2>/dev/null | grep -q 'Status: active'; then
        v_ok "ufw ativo."
    else
        v_falta "ufw inativo (ou sem sudo sem senha para checar)."
    fi
    [ -x "/etc/libvirt/hooks/qemu.d/${VM_NAME:-}/prepare/begin/00-airlock.sh" ] \
        && v_ok "Hook 00-airlock.sh instalado." || v_falta "Hook 00-airlock.sh ausente."
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

exigir_nao_root
exigir_sudo
exigir_conf TRANSFER_USER VM_NAME USUARIO_LINUX

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
    sudo mkdir -p /etc/ssh/authorized_keys
    sudo chmod 755 /etc/ssh/authorized_keys
    instalar_chave
    exit 0
fi

titulo "Capítulo 24: Airlock (usuário: $TRANSFER_USER, VM: $VM_NAME)"

# Caminhos configuráveis: impedir combinação que criaria montagem sobre si mesma
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
dpkg -s bindfs >/dev/null 2>&1 || { sudo apt update; sudo apt install -y bindfs; }
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
dpkg -s openssh-server >/dev/null 2>&1 || { sudo apt update; sudo apt install -y openssh-server; }
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

if ! sudo sshd -t; then
    sudo rm -f "$SSHD_DROPIN"
    falhar "sshd -t reprovou a configuração; drop-in removido, nada aplicado."
fi
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
titulo "6/7 Firewall (ufw)"
if [ -z "${VM_IP_FIXO:-}" ]; then
    aviso "VM_IP_FIXO não definido (reserva DHCP da etapa 60 pendente)."
    aviso "Firewall NÃO configurado agora; rode esta etapa de novo depois da reserva."
else
    dpkg -s ufw >/dev/null 2>&1 || { sudo apt update; sudo apt install -y ufw; }
    if confirmar "Você acessa este host por SSH de OUTRO dispositivo (ex.: notebook)?"; then
        IP_ADMIN="$(perguntar 'IP do dispositivo administrador' '')"
        if [ -n "$IP_ADMIN" ]; then
            sudo ufw allow from "$IP_ADMIN" to any port 22 proto tcp comment 'SSH admin'
            ok "Regra anti-lockout criada para $IP_ADMIN."
        fi
    fi
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw allow in on br0 from "$VM_IP_FIXO" to any port 22 proto tcp comment 'SFTP airlock - somente VM Windows'
    echo
    aviso "Política: TUDO que não for liberado explicitamente será bloqueado na entrada."
    if confirmar "Ativar o ufw agora?"; then
        sudo ufw --force enable
        sudo ufw status verbose
        ok "Firewall ativo e persistente entre boots."
    else
        aviso "ufw configurado mas NÃO ativado (ative depois com: sudo ufw enable)."
    fi
fi

# ----------------------------------------------------------------------------
# 7. Hook 00-airlock.sh (antes do 01-gpu-para-vfio.sh, ordem alfabética)
# ----------------------------------------------------------------------------
titulo "7/7 Hook de criação automática"
HOOK_DIR="/etc/libvirt/hooks/qemu.d/$VM_NAME/prepare/begin"
sudo mkdir -p "$HOOK_DIR"
sudo tee "$HOOK_DIR/00-airlock.sh" >/dev/null <<'HOOKAIR'
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
    "$HOOK_DIR/00-airlock.sh"
sudo chmod +x "$HOOK_DIR/00-airlock.sh"
sudo chown root:root "$HOOK_DIR/00-airlock.sh"
ok "Hook instalado: $HOOK_DIR/00-airlock.sh (roda ANTES do 01-gpu-para-vfio.sh)."

# ----------------------------------------------------------------------------
echo
titulo "Como testar (as 7 verificações do Capítulo 24)"
IP_FIXO_HOST_DISPLAY="${IP_FIXO_HOST:-<IP_FIXO_HOST>}"
SUBDIR="$(basename "$AIRLOCK_BIND")"
cat <<TESTES
1. Visão:        mount | grep airlock  (tipo fuse.bindfs) - teste de escrita já feito acima.
2. sshd:         sudo sshd -t (sem saída) e systemctl status ssh.
3. Transferência:na VM, WinSCP (SFTP, host $IP_FIXO_HOST_DISPLAY, usuário $TRANSFER_USER,
                 chave %USERPROFILE%\\.ssh\\airlock) -> a sessão abre em /$SUBDIR.
                 O que você envia aparece em $AIRLOCK_TRANSITO (e vice-versa).
4. Confinamento: no WinSCP, subir para / mostra APENAS $SUBDIR/.
5. Autenticação: ssh sem chave -> "Permission denied (publickey)" imediato.
6. Firewall:     de OUTRO dispositivo da LAN a porta 22 deve dar TIMEOUT;
                 da VM, conecta. (Teste negativo importante!)
7. Hook:         com a VM desligada: sudo umount $AIRLOCK_BIND; iniciar a VM;
                 journalctl -t hook-qemu -b deve registrar a remontagem.

Regras operacionais: airlock é zona de TRÂNSITO (sem dados permanentes, fora
do backup); nunca execute binários vindos dela (a visão é noexec); nunca crie
exclusão do Defender para essa pasta dentro do Windows.
TESTES
ok "Etapa 61 concluída."
