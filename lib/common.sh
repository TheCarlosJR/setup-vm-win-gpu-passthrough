#!/bin/bash
# ============================================================================
# lib/common.sh - funções compartilhadas por todas as etapas e utilitários
# ============================================================================
# Este arquivo NÃO é executado diretamente: ele é carregado via "source"
# pelos scripts de etapas/ e util/.
#
# Referência: Windows11_VM_Passthrough_PopOS_v2.md (manual completo).
# ============================================================================

# --- Localização do projeto e arquivos centrais -----------------------------
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJETO_DIR="$(cd "$COMMON_DIR/.." && pwd)"
CONF_ARQUIVO="$PROJETO_DIR/passthrough.conf"
BACKUPS_DIR="$PROJETO_DIR/backups"
FSTAB="/etc/fstab"
VIRSH="virsh --connect qemu:///system"

# --- Saída colorida ----------------------------------------------------------
if [ -t 1 ]; then
    C_VERDE=$'\033[0;32m'; C_AMARELO=$'\033[0;33m'; C_VERMELHO=$'\033[0;31m'
    C_AZUL=$'\033[0;36m';  C_NEGRITO=$'\033[1m';    C_RESET=$'\033[0m'
else
    C_VERDE=""; C_AMARELO=""; C_VERMELHO=""; C_AZUL=""; C_NEGRITO=""; C_RESET=""
fi

info()   { echo "${C_AZUL}[info]${C_RESET} $*"; }
ok()     { echo "${C_VERDE}[ ok ]${C_RESET} $*"; }
aviso()  { echo "${C_AMARELO}[aviso]${C_RESET} $*"; }
erro()   { echo "${C_VERMELHO}[erro]${C_RESET} $*" >&2; }
titulo() { echo; echo "${C_NEGRITO}==== $* ====${C_RESET}"; }
falhar() { erro "$*"; exit 1; }

# --- Pré-checagens ------------------------------------------------------------
exigir_nao_root() {
    if [ "$(id -u)" -eq 0 ]; then
        falhar "Execute como usuário normal (os scripts chamam sudo quando necessário)."
    fi
}

exigir_sudo() {
    info "Validando acesso sudo (a senha pode ser pedida)..."
    sudo -v || falhar "Sem acesso sudo."
}

exigir_comando() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 \
            || falhar "Comando '$cmd' não encontrado. Verifique as etapas anteriores (README)."
    done
}

# --- Configuração central (passthrough.conf) ---------------------------------
carregar_conf() {
    if [ -f "$CONF_ARQUIVO" ]; then
        # shellcheck disable=SC1090
        source "$CONF_ARQUIVO"
    fi
}

salvar_conf() {
    # salvar_conf CHAVE VALOR -> cria/atualiza a linha CHAVE="VALOR" no conf
    local chave="$1" valor="$2"
    touch "$CONF_ARQUIVO"
    if grep -q "^${chave}=" "$CONF_ARQUIVO"; then
        sed -i "s|^${chave}=.*|${chave}=\"${valor}\"|" "$CONF_ARQUIVO"
    else
        echo "${chave}=\"${valor}\"" >> "$CONF_ARQUIVO"
    fi
    # exporta para o processo atual também
    printf -v "$chave" '%s' "$valor"
    export "${chave?}"
}

exigir_conf() {
    # exigir_conf VAR1 VAR2 ... -> aborta se alguma estiver vazia/não definida
    local var faltando=0
    for var in "$@"; do
        if [ -z "${!var:-}" ]; then
            erro "Variável '$var' ausente ou vazia em: $CONF_ARQUIVO"
            faltando=1
        fi
    done
    if [ "$faltando" -eq 1 ]; then
        falhar "Execute antes: etapas/02-detectar-config.sh (ou edite o passthrough.conf)."
    fi
}

# --- Interação ----------------------------------------------------------------
confirmar() {
    # confirmar "Pergunta?" -> retorna 0 se sim. Padrão: NÃO.
    local resposta
    read -r -p "$1 [s/N] " resposta
    [[ "$resposta" =~ ^[sS]([iI][mM])?$ ]]
}

confirmar_digitando() {
    # confirmar_digitando PALAVRA "mensagem" -> exige digitar a PALAVRA exata
    local palavra="$1" msg="$2" resposta
    echo
    aviso "$msg"
    read -r -p "Digite ${palavra} (maiúsculas) para confirmar; qualquer outra coisa cancela: " resposta
    [ "$resposta" = "$palavra" ]
}

perguntar() {
    # perguntar "texto" "padrao" -> imprime a resposta (ou o padrão) no stdout.
    # O prompt do read vai para stderr, então funciona dentro de $(...).
    local texto="$1" padrao="${2:-}" resposta
    if [ -n "$padrao" ]; then
        read -r -p "$texto [$padrao]: " resposta
        echo "${resposta:-$padrao}"
    else
        read -r -p "$texto: " resposta
        echo "$resposta"
    fi
}

# --- Bootloader e parâmetros de kernel (Capítulos 15 e 16) --------------------
detectar_bootloader() {
    if command -v kernelstub >/dev/null 2>&1 && [ -d /boot/efi/loader/entries ]; then
        echo "kernelstub"
    elif [ -f /boot/grub/grub.cfg ]; then
        echo "grub"
    else
        echo "desconhecido"
    fi
}

cmdline_tem() {
    # cmdline_tem "param" -> 0 se o parâmetro está na linha de comando do kernel
    local p palavra
    p="$1"
    for palavra in $(cat /proc/cmdline); do
        [ "$palavra" = "$p" ] && return 0
    done
    return 1
}

_grub_cmdline_atual() {
    grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub \
        | sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="(.*)"$/\1/'
}

kernel_param_add() {
    # kernel_param_add "param1 param2 ..." -> adiciona pelo caminho certo
    local params="$1" bl="${BOOTLOADER:-$(detectar_bootloader)}"
    case "$bl" in
        kernelstub)
            sudo kernelstub -a "$params"
            ;;
        grub)
            local arq=/etc/default/grub atual novo p w presente
            sudo cp "$arq" "${arq}.bak-$(date +%Y%m%d-%H%M%S)"
            atual="$(_grub_cmdline_atual)"
            novo="$atual"
            for p in $params; do
                presente=0
                for w in $novo; do [ "$w" = "$p" ] && presente=1; done
                [ "$presente" -eq 0 ] && novo="$novo $p"
            done
            novo="${novo# }"
            sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${novo}\"|" "$arq"
            sudo update-grub
            ;;
        *)
            falhar "Bootloader não identificado. Execute etapas/02-detectar-config.sh."
            ;;
    esac
    info "Parâmetros aplicados via ${bl}: $params"
    info "Para reverter depois: kernel_param_del (ver 'Como desfazer' do capítulo correspondente)."
}

kernel_param_del() {
    # kernel_param_del "param1 param2 ..." -> remove pelo caminho certo
    local params="$1" bl="${BOOTLOADER:-$(detectar_bootloader)}"
    case "$bl" in
        kernelstub)
            sudo kernelstub -d "$params"
            ;;
        grub)
            local arq=/etc/default/grub atual novo w p manter
            sudo cp "$arq" "${arq}.bak-$(date +%Y%m%d-%H%M%S)"
            atual="$(_grub_cmdline_atual)"
            novo=""
            for w in $atual; do
                manter=1
                for p in $params; do [ "$w" = "$p" ] && manter=0; done
                [ "$manter" -eq 1 ] && novo="$novo $w"
            done
            novo="${novo# }"
            sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${novo}\"|" "$arq"
            sudo update-grub
            ;;
        *)
            falhar "Bootloader não identificado."
            ;;
    esac
}

# --- fstab gerenciado (linhas com marcador, idempotentes) ----------------------
fstab_backup() {
    local destino="${FSTAB}.bak-$(date +%Y%m%d-%H%M%S)"
    sudo cp "$FSTAB" "$destino"
    info "Backup do fstab criado: $destino"
}

fstab_definir_linha() {
    # fstab_definir_linha ID "linha completa"
    # Adiciona (ou substitui) uma linha marcada com "# vm-passthrough:ID".
    local id="$1" linha="$2"
    sudo sed -i "/^# vm-passthrough:${id}\$/,+1d" "$FSTAB"
    printf '%s\n%s\n' "# vm-passthrough:${id}" "$linha" | sudo tee -a "$FSTAB" >/dev/null
    info "fstab: linha '${id}' definida."
}

fstab_remover_linha() {
    local id="$1"
    sudo sed -i "/^# vm-passthrough:${id}\$/,+1d" "$FSTAB"
}

fstab_tem_linha() {
    grep -q "^# vm-passthrough:${1}\$" "$FSTAB" 2>/dev/null
}

# --- XML da VM ------------------------------------------------------------------
xml_backup() {
    # xml_backup NOME_DA_VM -> salva dumpxml datado em backups/
    local vm="$1" destino
    mkdir -p "$BACKUPS_DIR"
    destino="$BACKUPS_DIR/${vm}-$(date +%Y%m%d-%H%M%S).xml"
    $VIRSH dumpxml --inactive "$vm" > "$destino" \
        || falhar "Falha ao salvar backup do XML da VM '$vm'."
    info "Backup do XML salvo em: $destino"
}

vm_existe()    { $VIRSH dominfo "$1" >/dev/null 2>&1; }
vm_desligada() { [ "$($VIRSH domstate "$1" 2>/dev/null)" = "shut off" ]; }

exigir_vm_desligada() {
    vm_existe "$1" || falhar "A VM '$1' não existe. Execute a etapa 40 antes."
    vm_desligada "$1" \
        || falhar "A VM '$1' precisa estar DESLIGADA (use: virsh --connect qemu:///system shutdown $1)."
}

# --- CPUs ------------------------------------------------------------------------
expandir_lista_cpus() {
    # "0-2,5,8-9" -> imprime uma CPU por linha (expande intervalos)
    local parte partes
    IFS=',' read -ra partes <<< "$1"
    for parte in "${partes[@]}"; do
        if [[ "$parte" == *-* ]]; then
            seq "${parte%-*}" "${parte#*-}"
        else
            echo "$parte"
        fi
    done
}

# --- Diversos ----------------------------------------------------------------------
pedir_reboot() {
    echo
    aviso "REINICIALIZAÇÃO NECESSÁRIA para concluir esta etapa."
    aviso "Após o reboot, rode esta mesma etapa novamente (ela continua/valida sozinha)"
    aviso "ou abra o menu.sh para ver o status."
    if confirmar "Reiniciar agora?"; then
        sudo reboot
    else
        info "Ok, reinicie manualmente quando puder (sudo reboot)."
    fi
}

# --- Protocolo do modo --verificar ---------------------------------------------------
# Cada etapa implementa uma função verificar() usando v_ok/v_falta e termina
# com v_fim: código de saída 0 = etapa concluída, 1 = pendente.
V_FALHAS=0
v_ok()    { ok "$*"; }
v_falta() { aviso "$*"; V_FALHAS=$((V_FALHAS+1)); }
v_fim()   { if [ "$V_FALHAS" -eq 0 ]; then exit 0; else exit 1; fi; }
