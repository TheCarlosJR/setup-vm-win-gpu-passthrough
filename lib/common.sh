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

# --- Validadores simples ------------------------------------------------------
inteiro_positivo() {
    [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

indice_array_valido() {
    # indice_array_valido ESCOLHA TAMANHO -> índice humano entre 1 e TAMANHO
    local indice="${1:-}" tamanho="${2:-}"
    inteiro_positivo "$indice" || return 1
    [[ "$tamanho" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
    [ "${#indice}" -le 18 ] && [ "${#tamanho}" -le 18 ] || return 1
    (( 10#$indice <= 10#$tamanho ))
}

ipv4_valido() {
    local ip="${1:-}" octeto
    local -a octetos
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a octetos <<< "$ip"
    for octeto in "${octetos[@]}"; do
        [ "${#octeto}" -eq 1 ] || [ "${octeto:0:1}" != "0" ] || return 1
        (( 10#$octeto <= 255 )) || return 1
    done
}

# --- Configuração central (passthrough.conf) ---------------------------------
conf_chave_permitida() {
    case "${1:-}" in
        USUARIO_LINUX|VM_NAME|BOOTLOADER|GPU_PCI_ID|GPU_AUDIO_PCI_ID|\
        GPU_VENDOR_DEVICE_ID|GPU_AUDIO_VENDOR_DEVICE_ID|IOMMU_GROUP_GPU|\
        DM_SERVICE|NVME_DEVICE|UUID_HD2|HD2_DISCO_PAI|HD1_BY_ID_PATH|\
        DOCS4_MONTAGEM|QCOW2_PATH|QCOW2_TAMANHO|VM_RAM_MB|VM_VCPUS|\
        VM_CORES|VM_THREADS|CPUS_VM|CPUS_HOST|HUGEPAGES_1G|ISO_WINDOWS|\
        ISO_VIRTIO|INTERFACE_FISICA|VM_IP_FIXO|IP_FIXO_HOST|TRANSFER_USER)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

_conf_decodificar_linha() {
    # Define _CONF_LINHA_CHAVE, _CONF_LINHA_VALOR e _CONF_LINHA_SUFIXO.
    local linha="$1" numero="$2" resto caractere proximo valor="" i=1
    local regex_chave='^([A-Z][A-Z0-9_]*)='
    local regex_sufixo='^[[:blank:]]*(#.*)?$'

    if [[ "$linha" =~ $regex_chave ]]; then
        _CONF_LINHA_CHAVE="${BASH_REMATCH[1]}"
    else
        falhar "Linha $numero malformada em $CONF_ARQUIVO."
    fi
    conf_chave_permitida "$_CONF_LINHA_CHAVE" \
        || falhar "Chave desconhecida '$_CONF_LINHA_CHAVE' na linha $numero de $CONF_ARQUIVO."

    resto="${linha#*=}"
    [ "${resto:0:1}" = '"' ] \
        || falhar "Linha $numero malformada em $CONF_ARQUIVO: o valor deve estar entre aspas."

    while [ "$i" -lt "${#resto}" ]; do
        caractere="${resto:i:1}"
        if [ "$caractere" = '"' ]; then
            _CONF_LINHA_SUFIXO="${resto:i+1}"
            [[ "$_CONF_LINHA_SUFIXO" =~ $regex_sufixo ]] \
                || falhar "Conteúdo inválido após o valor na linha $numero de $CONF_ARQUIVO."
            _CONF_LINHA_VALOR="$valor"
            return 0
        fi
        if [ "$caractere" = '\' ]; then
            [ $((i + 1)) -lt "${#resto}" ] \
                || falhar "Escape incompleto na linha $numero de $CONF_ARQUIVO."
            proximo="${resto:i+1:1}"
            if [ "$proximo" = '\' ] || [ "$proximo" = '"' ] \
                || [ "$proximo" = '$' ] || [ "$proximo" = '`' ]; then
                valor+="$proximo"
                i=$((i + 2))
                continue
            fi
            # Compatibilidade com arquivos antigos: escapes que o serializer
            # não emite são mantidos literalmente, nunca interpretados.
            valor+='\'
            i=$((i + 1))
            continue
        fi
        valor+="$caractere"
        i=$((i + 1))
    done

    falhar "Aspas de fechamento ausentes na linha $numero de $CONF_ARQUIVO."
}

_conf_validar_arquivo() {
    local carregar="${1:-0}" linha chave numero=0 status antes_nul
    local regex_comentario='^[[:blank:]]*(#.*)?$'
    local -A valores=()

    [ -r "$CONF_ARQUIVO" ] || falhar "Sem permissão para ler $CONF_ARQUIVO."
    if IFS= read -r -d '' antes_nul < "$CONF_ARQUIVO"; then
        falhar "Byte NUL encontrado em $CONF_ARQUIVO."
    fi
    if LC_ALL=C grep -q '[[:cntrl:]]' "$CONF_ARQUIVO"; then
        falhar "Caractere de controle encontrado em $CONF_ARQUIVO."
    else
        status=$?
        [ "$status" -eq 1 ] || falhar "Não foi possível validar $CONF_ARQUIVO."
    fi

    while IFS= read -r linha || [ -n "$linha" ]; do
        numero=$((numero + 1))
        [[ "$linha" =~ $regex_comentario ]] && continue
        _conf_decodificar_linha "$linha" "$numero"
        chave="$_CONF_LINHA_CHAVE"
        [ -z "${valores[$chave]+definida}" ] \
            || falhar "Chave duplicada '$chave' na linha $numero de $CONF_ARQUIVO."
        valores[$chave]="$_CONF_LINHA_VALOR"
    done < "$CONF_ARQUIVO"

    if [ "$carregar" -eq 1 ]; then
        for chave in "${!valores[@]}"; do
            printf -v "$chave" '%s' "${valores[$chave]}"
        done
    fi
}

carregar_conf() {
    [ -L "$CONF_ARQUIVO" ] && falhar "$CONF_ARQUIVO não pode ser um link simbólico."
    [ -e "$CONF_ARQUIVO" ] || return 0
    [ -f "$CONF_ARQUIVO" ] || falhar "$CONF_ARQUIVO não é um arquivo regular."
    _conf_validar_arquivo 1
}

_conf_codificar_valor() {
    local valor="$1" caractere saida="" i
    for ((i = 0; i < ${#valor}; i++)); do
        caractere="${valor:i:1}"
        if [ "$caractere" = '\' ] || [ "$caractere" = '"' ] \
            || [ "$caractere" = '$' ] || [ "$caractere" = '`' ]; then
            saida+='\'
        fi
        saida+="$caractere"
    done
    printf '%s' "$saida"
}

_conf_gravar_atomico() (
    local chave="$1" codificado="$2" linha numero=0 encontrada=0
    local diretorio="${CONF_ARQUIVO%/*}" nome="${CONF_ARQUIVO##*/}" temporario=""
    local regex_comentario='^[[:blank:]]*(#.*)?$'

    trap 'status=$?; [ -z "$temporario" ] || rm -f -- "$temporario"; exit "$status"' EXIT
    trap 'exit 1' HUP INT TERM

    temporario="$(mktemp -- "$diretorio/.${nome}.tmp.XXXXXX")" || return 1
    chmod 0600 "$temporario" || return 1

    {
        if [ -e "$CONF_ARQUIVO" ]; then
            while IFS= read -r linha || [ -n "$linha" ]; do
                numero=$((numero + 1))
                if [[ "$linha" =~ $regex_comentario ]]; then
                    printf '%s\n' "$linha"
                    continue
                fi
                _conf_decodificar_linha "$linha" "$numero"
                if [ "$_CONF_LINHA_CHAVE" = "$chave" ]; then
                    printf '%s="%s"%s\n' "$chave" "$codificado" "$_CONF_LINHA_SUFIXO"
                    encontrada=1
                else
                    printf '%s\n' "$linha"
                fi
            done < "$CONF_ARQUIVO"
        fi
        [ "$encontrada" -eq 1 ] || printf '%s="%s"\n' "$chave" "$codificado"
    } > "$temporario" || return 1

    mv -f -- "$temporario" "$CONF_ARQUIVO" || return 1
    temporario=""
)

salvar_conf() {
    # salvar_conf CHAVE VALOR -> cria/atualiza uma entrada de dados no conf
    [ "$#" -eq 2 ] || falhar "Uso: salvar_conf CHAVE VALOR"
    local chave="$1" valor="$2" codificado

    conf_chave_permitida "$chave" || falhar "Chave de configuração não permitida: '$chave'."
    if [[ "$valor" =~ [[:cntrl:]] ]]; then
        falhar "O valor de '$chave' contém newline, CR, NUL ou outro caractere de controle."
    fi
    [ -L "$CONF_ARQUIVO" ] && falhar "$CONF_ARQUIVO não pode ser um link simbólico."
    if [ -e "$CONF_ARQUIVO" ]; then
        [ -f "$CONF_ARQUIVO" ] || falhar "$CONF_ARQUIVO não é um arquivo regular."
        _conf_validar_arquivo 0
    fi

    codificado="$(_conf_codificar_valor "$valor")"
    _conf_gravar_atomico "$chave" "$codificado" \
        || falhar "Falha ao atualizar $CONF_ARQUIVO de forma atômica."

    # Atualiza e exporta a chave no processo atual somente após o rename.
    printf -v "$chave" '%s' "$valor"
    export "$chave"
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
