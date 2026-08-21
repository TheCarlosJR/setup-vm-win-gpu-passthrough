#!/bin/bash
# ============================================================================
# lib/shell/boot.sh - bootloader, parâmetros de kernel e transação IOMMU/VFIO
# ============================================================================
# Este arquivo NÃO é executado diretamente: ele é carregado via "source" por
# lib/common.sh, que continua sendo a fachada pública das etapas.
#
# Fronteiras (seções 2.1, 2.3 e 2.4 do PLANO-FINALIZACAO.md):
#
#   * aqui ficam os EFEITOS de boot: sudo, escrita em /etc/default/grub,
#     kernelstub, regeneração de initramfs, snapshots, traps e rollback;
#   * o cálculo puro de CPU/RAM continua no core Python, pela ponte única;
#   * a leitura e a escrita de texto de cmdline permanecem em Bash de
#     propósito: elas são inseparáveis do backend de boot que as aplica, e
#     mover só o parsing criaria um segundo caminho para o mesmo estado.
#
# Sourcing deste arquivo não produz efeito: apenas define variáveis e funções.
# ============================================================================

[ -n "${BOOT_SH_CARREGADO:-}" ] && return 0
BOOT_SH_CARREGADO=1

# Os recursos persistentes de boot passam pela raiz hermética opcional, para
# que a transação real possa ser exercitada por teste sem tocar o host. Em
# produção SISTEMA_RAIZ_TESTE está vazio e caminho_sistema é identidade.
GRUB_DEFAULT_ARQUIVO="$(caminho_sistema /etc/default/grub)" \
    || falhar "Não foi possível resolver /etc/default/grub."
GRUB_CFG_ARQUIVO="$(caminho_sistema /boot/grub/grub.cfg)" \
    || falhar "Não foi possível resolver /boot/grub/grub.cfg."
KERNELSTUB_ENTRIES_DIR="$(caminho_sistema /boot/efi/loader/entries)" \
    || falhar "Não foi possível resolver o diretório de loader entries."
VFIO_MODULES_ARQUIVO="$(caminho_sistema /etc/modules-load.d/vfio.conf)" \
    || falhar "Não foi possível resolver /etc/modules-load.d/vfio.conf."

BOOTLOADER_VALIDACAO_ERRO=""
BOOTLOADER_ATIVO=""
detectar_bootloader() {
    # Prefere evidência do loader que iniciou a sessão. A simples presença do
    # binário kernelstub não basta: ele pode coexistir com um GRUB ativo. O
    # argumento opcional injeta a evidência apenas em chamadas unitárias.
    local bootctl_status="" tem_kernelstub=0 tem_grub=0 injetado="${1:-}"
    if [ -n "$injetado" ]; then
        case "$injetado" in grub|kernelstub|desconhecido) printf '%s\n' "$injetado"; return ;; esac
        printf '%s\n' desconhecido
        return
    fi
    command -v kernelstub >/dev/null 2>&1 && tem_kernelstub=1
    [ -f "$GRUB_CFG_ARQUIVO" ] && tem_grub=1
    if command -v bootctl >/dev/null 2>&1; then
        bootctl_status="$(LC_ALL=C bootctl status --no-pager 2>/dev/null || true)"
        if grep -A6 -F 'Current Boot Loader:' <<< "$bootctl_status" | grep -qi 'systemd-boot'; then
            [ "$tem_kernelstub" -eq 1 ] && { echo kernelstub; return; }
            echo desconhecido
            return
        elif grep -A6 -F 'Current Boot Loader:' <<< "$bootctl_status" | grep -qi 'grub'; then
            echo grub
            return
        fi
    fi
    if [ "$tem_grub" -eq 1 ] && [ "$tem_kernelstub" -eq 0 ]; then
        echo grub
    elif [ "$tem_kernelstub" -eq 1 ] && [ "$tem_grub" -eq 0 ]; then
        echo kernelstub
    elif [ "$tem_grub" -eq 1 ] && [ "$tem_kernelstub" -eq 1 ]; then
        # Sem prova do loader atual, escolher qualquer um seria perigoso.
        echo desconhecido
    else
        echo desconhecido
    fi
}

validar_bootloader_configurado() {
    local persistido="${1:-${BOOTLOADER:-}}" efetivo_injetado="${2:-}" efetivo
    BOOTLOADER_VALIDACAO_ERRO=""
    BOOTLOADER_ATIVO=""
    [ -n "$persistido" ] \
        || { BOOTLOADER_VALIDACAO_ERRO="BOOTLOADER não está definido em $CONF_ARQUIVO."; return 1; }
    [ "$PLATAFORMA_CARREGADA" -eq 1 ] || plataforma_carregar \
        || { BOOTLOADER_VALIDACAO_ERRO="$PLATAFORMA_ERRO"; return 1; }
    efetivo="$(detectar_bootloader "$efetivo_injetado")"
    case "$efetivo" in
        grub|kernelstub) ;;
        *) BOOTLOADER_VALIDACAO_ERRO="Bootloader efetivo não pôde ser determinado sem ambiguidade."; return 1 ;;
    esac
    plataforma_boot_backend_suportado "$efetivo" \
        || { BOOTLOADER_VALIDACAO_ERRO="Bootloader efetivo '$efetivo' não é suportado pelo perfil $PLATAFORMA_PERFIL."; return 1; }
    [ "$persistido" = "$efetivo" ] \
        || { BOOTLOADER_VALIDACAO_ERRO="Divergência de boot: passthrough.conf registra '$persistido', mas o boot efetivo é '$efetivo'. Execute a etapa 3 e confirme a migração com backup."; return 1; }
    BOOTLOADER_ATIVO="$efetivo"
}

_kernelstub_entries_diretas_legiveis() {
    local entrada restaurar_nullglob=0
    local -a entradas=()
    [ -d "$KERNELSTUB_ENTRIES_DIR" ] || return 1
    shopt -q nullglob || { shopt -s nullglob; restaurar_nullglob=1; }
    entradas=("$KERNELSTUB_ENTRIES_DIR"/*.conf)
    [ "$restaurar_nullglob" -eq 0 ] || shopt -u nullglob
    [ "${#entradas[@]}" -gt 0 ] || return 1
    for entrada in "${entradas[@]}"; do
        [ -f "$entrada" ] && [ -r "$entrada" ] || return 1
    done
}

boot_backend_observavel() {
    # Retornos: 0=observável, 1=backend inválido/ausente, 2=leitura
    # privilegiada indisponível. Nunca solicita senha.
    validar_bootloader_configurado "${1:-${BOOTLOADER:-}}" || return 1
    case "$BOOTLOADER_ATIVO" in
        grub)
            [ -r "$GRUB_DEFAULT_ARQUIVO" ] || return 2
            [ -r "$GRUB_CFG_ARQUIVO" ] && return 0
            command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null && return 0
            return 2
            ;;
        kernelstub)
            command -v kernelstub >/dev/null 2>&1 || return 1
            [ -d "$KERNELSTUB_ENTRIES_DIR" ] || return 1
            _kernelstub_entries_diretas_legiveis && return 0
            command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null && return 0
            return 2
            ;;
    esac
    return 1
}

exigir_bootloader_coerente() {
    validar_bootloader_configurado || falhar "$BOOTLOADER_VALIDACAO_ERRO"
}

cmdline_tem() {
    # cmdline_tem "param" -> 0 se o parâmetro exato está ativo neste boot.
    local procurado="$1" palavra conteudo
    local -a palavras=()
    IFS= read -r conteudo < /proc/cmdline || return 1
    read -r -a palavras <<< "$conteudo"
    for palavra in "${palavras[@]}"; do
        [ "$palavra" = "$procurado" ] && return 0
    done
    return 1
}

CMDLINE_PARAM_ERRO=""
cmdline_parametros_exatos() {
    # cmdline_parametros_exatos "chave=valor ..." [CMDLINE]
    # Exige exatamente uma ocorrência de cada chave e o valor literal esperado.
    # Quando CMDLINE não é informado, lê o kernel em execução.
    local esperados="${1:-}" conteudo="" desejado palavra chave encontrada quantidade
    local -a lista_esperada=() palavras=()
    CMDLINE_PARAM_ERRO=""
    kernel_parametros_validos "$esperados" \
        || { CMDLINE_PARAM_ERRO="Lista de parâmetros esperados inválida: '$esperados'."; return 1; }
    if [ "$#" -ge 2 ]; then
        conteudo="$2"
    else
        IFS= read -r conteudo < /proc/cmdline \
            || { CMDLINE_PARAM_ERRO="Não foi possível ler /proc/cmdline."; return 1; }
    fi
    read -r -a lista_esperada <<< "$esperados"
    read -r -a palavras <<< "$conteudo"
    for desejado in "${lista_esperada[@]}"; do
        chave="${desejado%%=*}"
        quantidade=0
        encontrada=""
        for palavra in "${palavras[@]}"; do
            if [ "${palavra%%=*}" = "$chave" ]; then
                quantidade=$((quantidade + 1))
                encontrada="$palavra"
            fi
        done
        [ "$quantidade" -eq 1 ] \
            || { CMDLINE_PARAM_ERRO="A chave '$chave' aparece $quantidade vez(es) na cmdline; esperado: exatamente uma."; return 1; }
        [ "$encontrada" = "$desejado" ] \
            || { CMDLINE_PARAM_ERRO="A chave '$chave' está como '$encontrada'; esperado: '$desejado'."; return 1; }
    done
}

cmdline_possui_alguma_chave() {
    local chaves="${1:-}" conteudo="" palavra procurada
    local -a palavras=() lista_chaves=()
    kernel_parametros_validos "$chaves" || return 2
    if [ "$#" -ge 2 ]; then
        conteudo="$2"
    else
        IFS= read -r conteudo < /proc/cmdline || return 2
    fi
    read -r -a palavras <<< "$conteudo"
    read -r -a lista_chaves <<< "$chaves"
    for palavra in "${palavras[@]}"; do
        for procurada in "${lista_chaves[@]}"; do
            [ "${palavra%%=*}" != "${procurada%%=*}" ] || return 0
        done
    done
    return 1
}

_parametros_por_chaves_cmdline() {
    # Imprime, na ordem de CHAVES, os valores presentes em CMDLINE. Falha se
    # uma chave estiver duplicada, pois esse estado não pode ser restaurado ou
    # comparado de forma inequívoca.
    local cmdline="$1" chaves="$2" chave_token chave palavra quantidade encontrado saida=""
    local -a lista_chaves=() palavras=()
    kernel_parametros_validos "$chaves" || return 1
    read -r -a lista_chaves <<< "$chaves"
    read -r -a palavras <<< "$cmdline"
    for chave_token in "${lista_chaves[@]}"; do
        chave="${chave_token%%=*}"
        quantidade=0
        encontrado=""
        for palavra in "${palavras[@]}"; do
            if [ "${palavra%%=*}" = "$chave" ]; then
                quantidade=$((quantidade + 1))
                encontrado="$palavra"
            fi
        done
        [ "$quantidade" -le 1 ] || return 1
        [ "$quantidade" -eq 0 ] || saida="${saida:+$saida }$encontrado"
    done
    printf '%s\n' "$saida"
}

_parametros_por_chaves_cmdline_tolerante() {
    # Inventário para reparo: preserva todas as ocorrências (inclusive legadas
    # duplicadas), agrupadas pela ordem das chaves solicitadas.
    local cmdline="$1" chaves="$2" chave_token chave palavra saida=""
    local -a lista_chaves=() palavras=()
    kernel_parametros_validos "$chaves" || return 1
    read -r -a lista_chaves <<< "$chaves"
    read -r -a palavras <<< "$cmdline"
    for chave_token in "${lista_chaves[@]}"; do
        chave="${chave_token%%=*}"
        for palavra in "${palavras[@]}"; do
            [ "${palavra%%=*}" = "$chave" ] || continue
            saida="${saida:+$saida }$palavra"
        done
    done
    printf '%s\n' "$saida"
}

kernel_parametros_validos() {
    local params="${1:-}" parametro chave
    local -a itens=()
    local -A chaves=()
    read -r -a itens <<< "$params"
    [ "${#itens[@]}" -gt 0 ] || return 1
    for parametro in "${itens[@]}"; do
        [[ "$parametro" =~ ^[[:alnum:]][[:alnum:]_.-]*(=[[:alnum:]_.,:/+-]+)?$ ]] || return 1
        chave="${parametro%%=*}"
        [ -z "${chaves[$chave]+definida}" ] || return 1
        chaves[$chave]=1
    done
}

_cmdline_sem_chaves() {
    # Imprime CMDLINE sem qualquer valor das chaves presentes em PARAMS.
    local cmdline="$1" params="$2" atual desejado chave_atual chave_desejada saida=""
    local -a atuais=() desejados=()
    read -r -a atuais <<< "$cmdline"
    read -r -a desejados <<< "$params"
    for atual in "${atuais[@]}"; do
        chave_atual="${atual%%=*}"
        for desejado in "${desejados[@]}"; do
            chave_desejada="${desejado%%=*}"
            [ "$chave_atual" != "$chave_desejada" ] || continue 2
        done
        saida="${saida:+$saida }$atual"
    done
    printf '%s\n' "$saida"
}

_kernelstub_linhas_opcoes() {
    # Prefere leitura direta; somente usa sudo não interativo quando os entries
    # existem mas não são legíveis pelo operador. O diretório é argumento de
    # bash -c, nunca interpolado como código.
    local entrada
    local -a entradas=() opcoes=()
    if _kernelstub_entries_diretas_legiveis; then
        entradas=("$KERNELSTUB_ENTRIES_DIR"/*.conf)
        for entrada in "${entradas[@]}"; do
            mapfile -t opcoes < <(grep -E '^[[:space:]]*options[[:space:]]+' -- "$entrada")
            [ "${#opcoes[@]}" -eq 1 ] || return 3
            printf '%s\n' "${opcoes[0]}"
        done
        return 0
    fi
    command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null || return 2
    sudo -n bash -c '
        shopt -s nullglob
        entradas=("$1"/*.conf)
        ((${#entradas[@]} > 0)) || exit 2
        for entrada in "${entradas[@]}"; do
            mapfile -t opcoes < <(grep -E "^[[:space:]]*options[[:space:]]+" -- "$entrada")
            ((${#opcoes[@]} == 1)) || exit 3
            printf "%s\n" "${opcoes[0]}"
        done
    ' _ "$KERNELSTUB_ENTRIES_DIR"
}

_kernelstub_parametros_por_chaves() {
    # Lê todas as entradas pendentes e só retorna um estado quando cada entrada
    # possui, para as chaves gerenciadas, exatamente o mesmo conjunto sem
    # duplicações. sudo -n impede prompts durante --verificar; etapas mutáveis
    # já obtiveram o ticket antes de chamar esta função.
    local params="$1" linhas linha opcoes estado referencia="" primeira=1
    linhas="$(_kernelstub_linhas_opcoes)" || return 1
    [ -n "$linhas" ] || return 1

    while IFS= read -r linha || [ -n "$linha" ]; do
        [[ "$linha" =~ ^[[:space:]]*options[[:space:]]+(.+)$ ]] || return 1
        opcoes="${BASH_REMATCH[1]}"
        estado="$(_parametros_por_chaves_cmdline "$opcoes" "$params")" || return 1
        if [ "$primeira" -eq 1 ]; then
            referencia="$estado"
            primeira=0
        elif [ "$estado" != "$referencia" ]; then
            return 1
        fi
    done <<< "$linhas"
    [ "$primeira" -eq 0 ] || return 1
    printf '%s\n' "$referencia"
}

_kernelstub_parametros_para_mutacao() {
    # Igual ao leitor estrito, mas aceita duplicações idênticas entre entries
    # para que o SET/DEL consiga saneá-las. Entries divergentes continuam
    # bloqueadas antes de qualquer mutação.
    local params="$1" linhas linha opcoes estado referencia="" primeira=1
    linhas="$(_kernelstub_linhas_opcoes)" || return 1
    [ -n "$linhas" ] || return 1
    while IFS= read -r linha || [ -n "$linha" ]; do
        [[ "$linha" =~ ^[[:space:]]*options[[:space:]]+(.+)$ ]] || return 1
        opcoes="${BASH_REMATCH[1]}"
        estado="$(_parametros_por_chaves_cmdline_tolerante "$opcoes" "$params")" || return 1
        if [ "$primeira" -eq 1 ]; then
            referencia="$estado"
            primeira=0
        elif [ "$estado" != "$referencia" ]; then
            return 1
        fi
    done <<< "$linhas"
    [ "$primeira" -eq 0 ] || return 1
    printf '%s\n' "$referencia"
}

_kernelstub_aplicar_estado() {
    # _kernelstub_aplicar_estado CHAVES "NOVO_ESTADO". Executa em subshell com
    # rollback no EXIT/sinal; o caller só recebe sucesso após reler todos os
    # loader entries e comprovar a pós-condição.
    local chaves="$1" novo="$2" antigo rc_tx=0
    antigo="$(_kernelstub_parametros_para_mutacao "$chaves")" \
        || { KERNEL_PERSISTENCIA_ERRO="Loader entries divergentes ou ilegíveis; nada foi alterado."; return 1; }
    if [ "$antigo" = "$novo" ]; then
        return 0
    fi
    (
        alterado=0
        concluido=0
        rollback_kernelstub() {
            local status="$1" atual restaurado
            trap - EXIT INT TERM
            if [ "$alterado" -eq 1 ] && [ "$concluido" -eq 0 ]; then
                erro "Transação kernelstub falhou; restaurando o estado anterior."
                if atual="$(_kernelstub_parametros_para_mutacao "$chaves")"; then
                    [ -z "$atual" ] || sudo kernelstub -d "$atual" >/dev/null 2>&1 || true
                else
                    # Estado intermediário ilegível: tente retirar tanto o
                    # destino quanto o snapshot antes de restaurar.
                    [ -z "$novo" ] || sudo kernelstub -d "$novo" >/dev/null 2>&1 || true
                    [ -z "$antigo" ] || sudo kernelstub -d "$antigo" >/dev/null 2>&1 || true
                fi
                if [ -n "$antigo" ]; then
                    sudo kernelstub -a "$antigo" >/dev/null 2>&1 || true
                fi
                restaurado="$(_kernelstub_parametros_para_mutacao "$chaves")" || restaurado="__ERRO__"
                if [ "$restaurado" != "$antigo" ]; then
                    erro "ROLLBACK KERNELSTUB NÃO COMPROVADO. Não reinicie antes de revisar os loader entries."
                else
                    aviso "Rollback kernelstub comprovado em todos os loader entries."
                fi
            fi
            exit "$status"
        }
        trap 'rollback_kernelstub $?' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        alterado=1
        if [ -n "$antigo" ]; then
            sudo kernelstub -d "$antigo" >/dev/null || exit 1
        fi
        if [ -n "$novo" ]; then
            sudo kernelstub -a "$novo" >/dev/null || exit 1
            kernel_parametros_persistentes_exatos "$novo" || exit 1
        else
            kernel_param_chaves_persistentes_ausentes "$chaves" || exit 1
        fi
        concluido=1
    ) || rc_tx=$?
    if [ "$rc_tx" -ne 0 ]; then
        # O código do sinal é parte do contrato: um INT/TERM na janela mutante
        # precisa chegar ao chamador como 130/143, não virar "falhou".
        case "$rc_tx" in
            130|143)
                erro "Transação kernelstub interrompida por sinal; consulte as mensagens de rollback."
                exit "$rc_tx"
                ;;
        esac
        KERNEL_PERSISTENCIA_ERRO="A transação kernelstub falhou; consulte as mensagens de rollback."
        return 1
    fi
}

_grub_cmdline_atual() {
    local linha
    local -a linhas=()
    mapfile -t linhas < <(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_DEFAULT_ARQUIVO" 2>/dev/null)
    [ "${#linhas[@]}" -eq 1 ] || return 1
    linha="${linhas[0]}"
    if [[ "$linha" =~ ^GRUB_CMDLINE_LINUX_DEFAULT=\"([^\"]*)\"[[:space:]]*$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

KERNEL_PERSISTENCIA_ERRO=""
KERNEL_PERSISTENCIA_TIPO="pendente"
KERNEL_PARAMETROS_PERSISTENTES=""
kernel_parametros_persistentes() {
    # kernel_parametros_persistentes "chave ..."
    # Preenche KERNEL_PARAMETROS_PERSISTENTES e rejeita duplicações ou loader
    # entries divergentes. Não solicita senha durante verificadores.
    local chaves="${1:-}" bl cmdline estado observavel_rc
    KERNEL_PERSISTENCIA_ERRO=""
    KERNEL_PERSISTENCIA_TIPO="pendente"
    KERNEL_PARAMETROS_PERSISTENTES=""
    kernel_parametros_validos "$chaves" \
        || { KERNEL_PERSISTENCIA_TIPO="erro"; KERNEL_PERSISTENCIA_ERRO="Lista de chaves de kernel inválida: '$chaves'."; return 1; }
    if ! validar_bootloader_configurado; then
        KERNEL_PERSISTENCIA_TIPO="erro"
        KERNEL_PERSISTENCIA_ERRO="$BOOTLOADER_VALIDACAO_ERRO"
        return 1
    fi
    bl="$BOOTLOADER_ATIVO"
    if boot_backend_observavel "$bl"; then
        :
    else
        observavel_rc=$?
        if [ "$observavel_rc" -eq 2 ]; then
            KERNEL_PERSISTENCIA_TIPO="indeterminado"
            KERNEL_PERSISTENCIA_ERRO="Backend $bl não pode ser lido sem privilégio já autorizado."
        else
            KERNEL_PERSISTENCIA_TIPO="erro"
            KERNEL_PERSISTENCIA_ERRO="Backend $bl não está disponível para inspeção segura."
        fi
        return 1
    fi
    case "$bl" in
        kernelstub)
            estado="$(_kernelstub_parametros_por_chaves "$chaves")" \
                || { KERNEL_PERSISTENCIA_TIPO="erro"; KERNEL_PERSISTENCIA_ERRO="Loader entries indisponíveis, duplicados ou divergentes para as chaves gerenciadas."; return 1; }
            ;;
        grub)
            cmdline="$(_grub_cmdline_atual)" \
                || { KERNEL_PERSISTENCIA_TIPO="erro"; KERNEL_PERSISTENCIA_ERRO="GRUB_CMDLINE_LINUX_DEFAULT ausente, duplicado ou ilegível."; return 1; }
            estado="$(_parametros_por_chaves_cmdline "$cmdline" "$chaves")" \
                || { KERNEL_PERSISTENCIA_TIPO="erro"; KERNEL_PERSISTENCIA_ERRO="Uma chave gerenciada está duplicada no GRUB."; return 1; }
            ;;
        *)
            KERNEL_PERSISTENCIA_TIPO="erro"
            KERNEL_PERSISTENCIA_ERRO="Bootloader não identificado."
            return 1
            ;;
    esac
    KERNEL_PARAMETROS_PERSISTENTES="$estado"
}

kernel_parametros_persistentes_exatos() {
    local esperados="${1:-}" bl
    kernel_parametros_persistentes "$esperados" || return 1
    bl="$BOOTLOADER_ATIVO"
    [ "$KERNEL_PARAMETROS_PERSISTENTES" = "$esperados" ] \
        || { KERNEL_PERSISTENCIA_TIPO="pendente"; KERNEL_PERSISTENCIA_ERRO="Persistência atual: '${KERNEL_PARAMETROS_PERSISTENTES:-ausente}'; esperado: '$esperados'."; return 1; }
    if [ "$bl" = grub ] && ! _grub_cfg_parametros_exatos "$esperados"; then
        KERNEL_PERSISTENCIA_TIPO="pendente"
        KERNEL_PERSISTENCIA_ERRO="O grub.cfg efetivo não contém exatamente os parâmetros esperados em todas as entradas Linux."
        return 1
    fi
}

kernel_param_chaves_persistentes_ausentes() {
    local chaves="${1:-}" bl
    kernel_parametros_persistentes "$chaves" || return 1
    bl="$BOOTLOADER_ATIVO"
    [ -z "$KERNEL_PARAMETROS_PERSISTENTES" ] \
        || { KERNEL_PERSISTENCIA_TIPO="pendente"; KERNEL_PERSISTENCIA_ERRO="Ainda persistem parâmetros: $KERNEL_PARAMETROS_PERSISTENTES"; return 1; }
    if [ "$bl" = grub ] && ! _grub_cfg_chaves_ausentes "$chaves"; then
        KERNEL_PERSISTENCIA_TIPO="pendente"
        KERNEL_PERSISTENCIA_ERRO="O grub.cfg efetivo ainda contém uma das chaves gerenciadas."
        return 1
    fi
}

_grub_cfg_linhas_linux() {
    if [ -r "$GRUB_CFG_ARQUIVO" ]; then
        awk '/^[[:space:]]*(linux|linuxefi)[[:space:]]/ {print}' "$GRUB_CFG_ARQUIVO"
        return
    fi
    command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null || return 2
    sudo -n awk '/^[[:space:]]*(linux|linuxefi)[[:space:]]/ {print}' "$GRUB_CFG_ARQUIVO" 2>/dev/null
}

_grub_cfg_parametros_exatos() {
    local esperados="$1" linhas linha estado encontrou=0
    linhas="$(_grub_cfg_linhas_linux)" \
        || return 1
    [ -n "$linhas" ] || return 1
    while IFS= read -r linha || [ -n "$linha" ]; do
        estado="$(_parametros_por_chaves_cmdline "$linha" "$esperados")" || return 1
        # Recovery/custom entries podem deliberadamente não herdar
        # GRUB_CMDLINE_LINUX_DEFAULT. Se uma entrada contiver qualquer chave
        # gerenciada, porém, o conjunto precisa ser integral e exato.
        [ -n "$estado" ] || continue
        [ "$estado" = "$esperados" ] || return 1
        encontrou=1
    done <<< "$linhas"
    [ "$encontrou" -eq 1 ]
}

_grub_cfg_chaves_ausentes() {
    local chaves="$1" linhas linha estado encontrou=0
    linhas="$(_grub_cfg_linhas_linux)" \
        || return 1
    [ -n "$linhas" ] || return 1
    while IFS= read -r linha || [ -n "$linha" ]; do
        estado="$(_parametros_por_chaves_cmdline "$linha" "$chaves")" || return 1
        [ -z "$estado" ] || return 1
        encontrou=1
    done <<< "$linhas"
    [ "$encontrou" -eq 1 ]
}

_grub_aplicar_cmdline() {
    # Instala /etc/default/grub e regenera o grub.cfg numa única transação.
    # EXIT/INT/TERM após o primeiro mv restauram a fonte e regeneram o cfg.
    local novo="$1" verificacao="$2" modo="$3" arq="$GRUB_DEFAULT_ARQUIVO"
    local tmp backup staged linha rc_tx=0
    [[ "$novo" != *$'\n'* && "$novo" != *$'\r'* && "$novo" != *'"'* && "$novo" != *'\'* ]] \
        || falhar "Linha de parâmetros GRUB contém caractere não suportado."
    tmp="$(mktemp)" || falhar "Não foi possível criar temporário para o GRUB."
    linha="GRUB_CMDLINE_LINUX_DEFAULT=\"${novo}\""
    if ! NOVA_LINHA_GRUB="$linha" awk '
        /^GRUB_CMDLINE_LINUX_DEFAULT=/ {
            encontradas++
            if (encontradas == 1) print ENVIRON["NOVA_LINHA_GRUB"]
            next
        }
        { print }
        END { if (encontradas != 1) exit 42 }
    ' "$arq" > "$tmp"; then
        rm -f -- "$tmp"
        falhar "GRUB_CMDLINE_LINUX_DEFAULT ausente ou duplicado em $arq."
    fi

    backup="${arq}.bak-$(date +%Y%m%d-%H%M%S)-$$"
    staged="${arq}.vm-passthrough-$$"
    sudo cp -a -- "$arq" "$backup" \
        || { rm -f -- "$tmp"; falhar "Falha ao criar backup do GRUB em $backup."; }

    # A cópia e a escrita do arquivo intermediário acontecem DENTRO da janela
    # protegida: um sinal entre criar e publicar o intermediário deixaria um
    # arquivo órfão ao lado de /etc/default/grub, e limpar isso é parte do
    # contrato de rollback, não detalhe.
    (
        alterado=0
        concluido=0
        rollback_grub() {
            local status="$1"
            trap - EXIT INT TERM
            sudo rm -f -- "$staged" >/dev/null 2>&1 || true
            if [ "$alterado" -eq 1 ] && [ "$concluido" -eq 0 ]; then
                erro "Transação GRUB interrompida ou inválida; restaurando $backup."
                if sudo cp -a -- "$backup" "$arq" \
                   && sudo update-grub \
                   && sudo cmp -s -- "$backup" "$arq"; then
                    aviso "Rollback da fonte GRUB e regeneração do grub.cfg concluídos."
                else
                    erro "ROLLBACK GRUB NÃO COMPROVADO. Não reinicie antes de revisar $arq e /boot/grub/grub.cfg."
                fi
            fi
            exit "$status"
        }
        trap 'rollback_grub $?' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        sudo cp -a -- "$arq" "$staged" \
            || { erro "Falha ao preparar atualização atômica do GRUB."; exit 1; }
        sudo tee "$staged" < "$tmp" >/dev/null \
            || { erro "Falha ao escrever configuração temporária do GRUB."; exit 1; }
        alterado=1
        sudo mv -f -- "$staged" "$arq" || exit 1
        sudo update-grub || exit 1
        if [ "$modo" = exato ]; then
            _grub_cfg_parametros_exatos "$verificacao" || exit 1
        elif [ "$modo" = ausente ]; then
            _grub_cfg_chaves_ausentes "$verificacao" || exit 1
        else
            exit 1
        fi
        concluido=1
    ) || rc_tx=$?
    rm -f -- "$tmp"
    if [ "$rc_tx" -ne 0 ]; then
        erro "Alteração do GRUB não concluída; consulte as mensagens de rollback."
        # 130/143 precisam sobreviver: o chamador (e a transação de IOMMU acima
        # dele) distingue interrupção por sinal de falha comum pelo código.
        case "$rc_tx" in
            130|143) exit "$rc_tx" ;;
        esac
        exit 1
    fi
    info "Backup do GRUB preservado em: $backup"
}

kernel_param_add() {
    # Apesar do nome histórico, esta operação é SET por chave: qualquer valor
    # anterior de hugepages, isolcpus, iommu etc. é removido antes do novo.
    local params="$1" bl atual novo
    kernel_parametros_validos "$params" \
        || falhar "Lista de parâmetros de kernel inválida ou com chaves duplicadas: '$params'."
    exigir_bootloader_coerente
    bl="$BOOTLOADER_ATIVO"
    case "$bl" in
        kernelstub)
            _kernelstub_aplicar_estado "$params" "$params" \
                || falhar "${KERNEL_PERSISTENCIA_ERRO:-Transação kernelstub não concluída.}"
            ;;
        grub)
            atual="$(_grub_cmdline_atual)" \
                || falhar "Não foi possível ler com segurança GRUB_CMDLINE_LINUX_DEFAULT."
            novo="$(_cmdline_sem_chaves "$atual" "$params")"
            novo="${novo:+$novo }$params"
            _grub_aplicar_cmdline "$novo" "$params" exato
            ;;
        *)
            falhar "Bootloader não identificado. Execute etapas/02-detectar-config.sh."
            ;;
    esac
    info "Parâmetros definidos por chave via ${bl}: $params"
}

kernel_param_del() {
    # Remove todos os valores das chaves informadas, mesmo que sejam diferentes
    # daqueles registrados na chamada (ex.: hugepages=16 remove hugepages=8).
    local params="$1" bl atual novo
    kernel_parametros_validos "$params" \
        || falhar "Lista de parâmetros de kernel inválida ou com chaves duplicadas: '$params'."
    exigir_bootloader_coerente
    bl="$BOOTLOADER_ATIVO"
    case "$bl" in
        kernelstub)
            _kernelstub_aplicar_estado "$params" "" \
                || falhar "${KERNEL_PERSISTENCIA_ERRO:-Transação kernelstub de remoção não concluída.}"
            ;;
        grub)
            atual="$(_grub_cmdline_atual)" \
                || falhar "Não foi possível ler com segurança GRUB_CMDLINE_LINUX_DEFAULT."
            novo="$(_cmdline_sem_chaves "$atual" "$params")"
            if [ "$novo" != "$atual" ] || ! _grub_cfg_chaves_ausentes "$params"; then
                _grub_aplicar_cmdline "$novo" "$params" ausente
            else
                info "Nenhum parâmetro dessas chaves está configurado na fonte nem no grub.cfg efetivo."
            fi
            ;;
        *)
            falhar "Bootloader não identificado."
            ;;
    esac
}

# --- REQ-IOMMU-TX: convergência persistente de IOMMU e VFIO -------------------
# Parâmetros de boot, /etc/modules-load.d/vfio.conf e initramfs são UMA
# transação lógica. O que essa seção garante, e que a sequência anterior não
# garantia:
#
#   * "ativo neste boot" e "persistido para o próximo boot" são fatos
#     independentes, medidos separadamente (D-IOMMU-ACTIVE-PERSISTENT);
#   * todos os candidatos são gerados e validados ANTES da primeira mutação;
#   * o initramfs só é regenerado depois que boot e vfio.conf estão aplicados e
#     comprovados;
#   * falha ou sinal em qualquer janela restaura todos os recursos e prova cada
#     restauração por releitura (D-IOMMU-PARTIALITY);
#   * conteúdo não gerenciado de vfio.conf é preservado, e os metadados do
#     arquivo também;
#   * segunda execução sobre estado convergido é no-op exato.

IOMMU_PARAMS_PADRAO="amd_iommu=on iommu=pt"
VFIO_MODULOS_GERENCIADOS="vfio vfio_pci vfio_iommu_type1"
VFIO_MARCADOR_INICIO="# vm-passthrough:vfio inicio"
VFIO_MARCADOR_FIM="# vm-passthrough:vfio fim"

boot_params_chaves() {
    # "amd_iommu=on iommu=pt" -> "amd_iommu iommu"
    local params="${1:-}" token saida=""
    local -a itens=()
    read -r -a itens <<< "$params"
    for token in "${itens[@]}"; do
        saida="${saida:+$saida }${token%%=*}"
    done
    printf '%s\n' "$saida"
}

BOOT_IOMMU_ATIVO=""
BOOT_IOMMU_PERSISTENTE=""
BOOT_IOMMU_ERRO=""
boot_estado_iommu() {
    # Publica os dois fatos separadamente. Valores possíveis para cada um:
    # exato, divergente, ausente, indeterminado. Retorno 0 quando ambos foram
    # medidos; 1 quando algum ficou indeterminado (ferramenta ou privilégio
    # ausente), que nunca pode ser lido como convergência.
    local params="${1:-$IOMMU_PARAMS_PADRAO}" chaves rc=0
    BOOT_IOMMU_ATIVO=indeterminado
    BOOT_IOMMU_PERSISTENTE=indeterminado
    BOOT_IOMMU_ERRO=""
    chaves="$(boot_params_chaves "$params")"

    if cmdline_parametros_exatos "$params"; then
        BOOT_IOMMU_ATIVO=exato
    elif cmdline_possui_alguma_chave "$chaves"; then
        BOOT_IOMMU_ATIVO=divergente
    else
        rc=$?
        if [ "$rc" -eq 1 ]; then
            BOOT_IOMMU_ATIVO=ausente
        else
            BOOT_IOMMU_ERRO="Não foi possível inspecionar a cmdline em execução."
        fi
    fi

    if kernel_parametros_persistentes_exatos "$params"; then
        BOOT_IOMMU_PERSISTENTE=exato
    elif kernel_param_chaves_persistentes_ausentes "$chaves"; then
        BOOT_IOMMU_PERSISTENTE=ausente
    elif [ "$KERNEL_PERSISTENCIA_TIPO" = indeterminado ]; then
        BOOT_IOMMU_ERRO="${BOOT_IOMMU_ERRO:+$BOOT_IOMMU_ERRO }$KERNEL_PERSISTENCIA_ERRO"
    else
        BOOT_IOMMU_PERSISTENTE=divergente
        BOOT_IOMMU_ERRO="${BOOT_IOMMU_ERRO:+$BOOT_IOMMU_ERRO }$KERNEL_PERSISTENCIA_ERRO"
    fi

    [ "$BOOT_IOMMU_ATIVO" != indeterminado ] \
        && [ "$BOOT_IOMMU_PERSISTENTE" != indeterminado ]
}

# --- vfio.conf: bloco gerenciado, conteúdo externo preservado -----------------

VFIO_MODULES_ERRO=""
VFIO_MODULES_CANDIDATO=""
VFIO_MODULES_ATUAL=""
VFIO_MODULES_EXISTE=0

_vfio_bloco_gerenciado() {
    local modulo
    printf '%s\n' "$VFIO_MARCADOR_INICIO"
    for modulo in $VFIO_MODULOS_GERENCIADOS; do
        printf '%s\n' "$modulo"
    done
    printf '%s\n' "$VFIO_MARCADOR_FIM"
}

_vfio_marcadores_validos() {
    # Valida o par de marcadores no shell atual, e não dentro de uma
    # substituição de comando: uma verificação feita em subshell perderia
    # VFIO_MODULES_ERRO e o operador receberia recusa sem diagnóstico.
    local conteudo="${1:-}" linha inicio=0 fim=0
    VFIO_MODULES_ERRO=""
    [ -n "$conteudo" ] || return 0
    while IFS= read -r linha || [ -n "$linha" ]; do
        [ "$linha" != "$VFIO_MARCADOR_INICIO" ] || inicio=$((inicio + 1))
        [ "$linha" != "$VFIO_MARCADOR_FIM" ] || fim=$((fim + 1))
    done <<< "$conteudo"
    if [ "$inicio" -ne "$fim" ] || [ "$inicio" -gt 1 ]; then
        VFIO_MODULES_ERRO="Marcadores de $VFIO_MODULES_ARQUIVO desemparelhados ou repetidos; corrija o arquivo à mão antes de continuar."
        return 1
    fi
    return 0
}

_vfio_candidato_de() {
    # Recebe o conteúdo atual (possivelmente vazio) e imprime o candidato.
    #
    # Três casos, nesta ordem:
    #   1. arquivo com o par de marcadores: a região entre eles é substituída
    #      pelo bloco canônico e tudo fora dela é preservado byte a byte;
    #   2. arquivo sem marcadores: as linhas que declaram exatamente um módulo
    #      gerenciado são retiradas (senão o módulo seria declarado duas vezes)
    #      e o bloco canônico é acrescentado ao fim; qualquer outra linha,
    #      inclusive comentário de terceiros, é preservada na ordem original;
    #   3. arquivo ausente: o candidato é só o bloco canônico.
    local atual="${1:-}" linha modulo gerenciado
    local -a prefixo=() sufixo=()
    local dentro=0 vistos_inicio=0 vistos_fim=0
    if [ -z "$atual" ]; then
        _vfio_bloco_gerenciado
        return 0
    fi
    while IFS= read -r linha || [ -n "$linha" ]; do
        if [ "$linha" = "$VFIO_MARCADOR_INICIO" ]; then
            vistos_inicio=$((vistos_inicio + 1))
            dentro=1
            continue
        fi
        if [ "$linha" = "$VFIO_MARCADOR_FIM" ]; then
            vistos_fim=$((vistos_fim + 1))
            dentro=0
            continue
        fi
        if [ "$dentro" -eq 1 ]; then
            continue
        fi
        if [ "$vistos_inicio" -eq 0 ]; then
            prefixo+=("$linha")
        else
            sufixo+=("$linha")
        fi
    done <<< "$atual"
    if [ "$vistos_inicio" -ne "$vistos_fim" ] || [ "$vistos_inicio" -gt 1 ]; then
        # Defesa em profundidade: o chamador já validou os marcadores fora de
        # substituição de comando, onde a mensagem consegue chegar ao operador.
        return 1
    fi
    if [ "$vistos_inicio" -eq 0 ]; then
        # Migração do formato antigo: linhas soltas dos módulos gerenciados são
        # absorvidas pelo bloco; o resto continua exatamente onde estava.
        local -a preservadas=()
        for linha in ${prefixo[@]+"${prefixo[@]}"}; do
            gerenciado=0
            for modulo in $VFIO_MODULOS_GERENCIADOS; do
                [ "$linha" = "$modulo" ] && gerenciado=1
            done
            [ "$gerenciado" -eq 1 ] || preservadas+=("$linha")
        done
        prefixo=(${preservadas[@]+"${preservadas[@]}"})
    fi
    for linha in ${prefixo[@]+"${prefixo[@]}"}; do
        printf '%s\n' "$linha"
    done
    _vfio_bloco_gerenciado
    for linha in ${sufixo[@]+"${sufixo[@]}"}; do
        printf '%s\n' "$linha"
    done
}

vfio_modules_estado() {
    # Retornos: 0=convergido; 1=divergente ou ausente; 2=erro de leitura ou de
    # formato. Publica o conteúdo atual e o candidato, sem tocar o arquivo.
    VFIO_MODULES_ERRO=""
    VFIO_MODULES_ATUAL=""
    VFIO_MODULES_CANDIDATO=""
    VFIO_MODULES_EXISTE=0
    if [ -L "$VFIO_MODULES_ARQUIVO" ]; then
        VFIO_MODULES_ERRO="$VFIO_MODULES_ARQUIVO é um link simbólico; recusado."
        return 2
    fi
    if [ -e "$VFIO_MODULES_ARQUIVO" ]; then
        [ -f "$VFIO_MODULES_ARQUIVO" ] \
            || { VFIO_MODULES_ERRO="$VFIO_MODULES_ARQUIVO não é um arquivo regular."; return 2; }
        [ -r "$VFIO_MODULES_ARQUIVO" ] \
            || { VFIO_MODULES_ERRO="$VFIO_MODULES_ARQUIVO não é legível pelo operador."; return 2; }
        VFIO_MODULES_ATUAL="$(<"$VFIO_MODULES_ARQUIVO")" \
            || { VFIO_MODULES_ERRO="Falha ao ler $VFIO_MODULES_ARQUIVO."; return 2; }
        VFIO_MODULES_EXISTE=1
    fi
    _vfio_marcadores_validos "$VFIO_MODULES_ATUAL" || return 2
    VFIO_MODULES_CANDIDATO="$(_vfio_candidato_de "$VFIO_MODULES_ATUAL")" \
        || { VFIO_MODULES_ERRO="Não foi possível montar o candidato de $VFIO_MODULES_ARQUIVO."; return 2; }
    [ "$VFIO_MODULES_EXISTE" -eq 1 ] || return 1
    # A comparação é textual e inclui a política de newline final: o candidato
    # sempre termina em uma única quebra, e é assim que ele é publicado.
    [ "$VFIO_MODULES_ATUAL" = "$VFIO_MODULES_CANDIDATO" ] || return 1
    return 0
}

_vfio_staged_path() {
    printf '%s\n' "${VFIO_MODULES_ARQUIVO}.vm-passthrough-novo-$$"
}

_vfio_descartar_staged() {
    # Idempotente: chamada no rollback e no commit. Um sinal no meio da escrita
    # do intermediário não pode deixá-lo em /etc/modules-load.d, onde ele nem
    # sequer seria lido pelo systemd e só confundiria o operador.
    sudo rm -f -- "$(_vfio_staged_path)" >/dev/null 2>&1 || true
}

_vfio_publicar() {
    # Publicação atômica no mesmo diretório, preservando metadados quando o
    # arquivo já existe. O temporário nunca fica com nome *.conf, para que o
    # systemd-modules-load não o leia num estado intermediário.
    local conteudo="$1" staged
    local diretorio="${VFIO_MODULES_ARQUIVO%/*}" existia=0
    staged="$(_vfio_staged_path)"
    VFIO_MODULES_ERRO=""
    [ -f "$VFIO_MODULES_ARQUIVO" ] && existia=1
    sudo mkdir -p -- "$diretorio" \
        || { VFIO_MODULES_ERRO="Não foi possível criar $diretorio."; return 1; }
    if [ "$existia" -eq 1 ]; then
        # cp -a leva modo, dono e grupo; o tee seguinte troca só o conteúdo.
        sudo cp -a -- "$VFIO_MODULES_ARQUIVO" "$staged" \
            || { VFIO_MODULES_ERRO="Não foi possível preparar a atualização de $VFIO_MODULES_ARQUIVO."; return 1; }
    fi
    if ! printf '%s\n' "$conteudo" | sudo tee "$staged" >/dev/null; then
        sudo rm -f -- "$staged"
        VFIO_MODULES_ERRO="Não foi possível escrever o conteúdo de $VFIO_MODULES_ARQUIVO."
        return 1
    fi
    if [ "$existia" -ne 1 ]; then
        sudo chmod 0644 -- "$staged" \
            || { sudo rm -f -- "$staged"; VFIO_MODULES_ERRO="Não foi possível ajustar o modo do novo $VFIO_MODULES_ARQUIVO."; return 1; }
    fi
    sudo mv -f -- "$staged" "$VFIO_MODULES_ARQUIVO" \
        || { sudo rm -f -- "$staged"; VFIO_MODULES_ERRO="Não foi possível publicar $VFIO_MODULES_ARQUIVO."; return 1; }
    return 0
}

# --- Transação -----------------------------------------------------------------

IOMMU_TX_ESTADO=IDLE   # IDLE|PREPARED|BOOT|VFIO|INITRAMFS|VERIFIED|COMMITTED|ROLLING_BACK
IOMMU_TX_ERRO=""
IOMMU_TX_PARAMS=""
IOMMU_TX_CHAVES=""
IOMMU_TX_PERSISTENCIA_ANTERIOR=""
IOMMU_TX_VFIO_EXISTIA=0
IOMMU_TX_VFIO_BACKUP=""
IOMMU_TX_VFIO_CONTEUDO_ANTERIOR=""
IOMMU_TX_INITRAMFS_TENTADO=0
IOMMU_TX_INITRAMFS_APLICADO=0
IOMMU_TX_ALTEROU_BOOT=0
IOMMU_TX_ALTEROU_VFIO=0

_iommu_tx_backup_vfio() {
    IOMMU_TX_VFIO_BACKUP="${VFIO_MODULES_ARQUIVO}.vm-passthrough-anterior-$$"
    if [ "$IOMMU_TX_VFIO_EXISTIA" -eq 1 ]; then
        sudo cp -a -- "$VFIO_MODULES_ARQUIVO" "$IOMMU_TX_VFIO_BACKUP" \
            || { IOMMU_TX_ERRO="Não foi possível preservar o vfio.conf anterior."; return 1; }
    fi
    return 0
}

_iommu_tx_descartar_backup_vfio() {
    [ -n "$IOMMU_TX_VFIO_BACKUP" ] || return 0
    sudo rm -f -- "$IOMMU_TX_VFIO_BACKUP" >/dev/null 2>&1 || true
    IOMMU_TX_VFIO_BACKUP=""
}

_iommu_tx_restaurar_boot() {
    # Restaura e PROVA a persistência anterior. Roda em subshell porque
    # kernel_param_add/del terminam o processo em falha: aqui a falha precisa
    # virar retorno, não saída.
    local anterior="$IOMMU_TX_PERSISTENCIA_ANTERIOR"
    if [ -n "$anterior" ]; then
        ( kernel_param_add "$anterior" >/dev/null ) || return 1
        kernel_parametros_persistentes_exatos "$anterior" || return 1
    else
        ( kernel_param_del "$IOMMU_TX_CHAVES" >/dev/null ) || return 1
        kernel_param_chaves_persistentes_ausentes "$IOMMU_TX_CHAVES" || return 1
    fi
    return 0
}

_iommu_tx_restaurar_vfio() {
    if [ "$IOMMU_TX_VFIO_EXISTIA" -eq 1 ]; then
        [ -n "$IOMMU_TX_VFIO_BACKUP" ] && [ -f "$IOMMU_TX_VFIO_BACKUP" ] || return 1
        sudo mv -f -- "$IOMMU_TX_VFIO_BACKUP" "$VFIO_MODULES_ARQUIVO" || return 1
        IOMMU_TX_VFIO_BACKUP=""
        [ -f "$VFIO_MODULES_ARQUIVO" ] || return 1
        [ "$(<"$VFIO_MODULES_ARQUIVO")" = "$IOMMU_TX_VFIO_CONTEUDO_ANTERIOR" ] || return 1
    else
        sudo rm -f -- "$VFIO_MODULES_ARQUIVO" || return 1
        [ ! -e "$VFIO_MODULES_ARQUIVO" ] || return 1
    fi
    return 0
}

iommu_vfio_rollback() {
    # Desfaz na ordem inversa e comprova cada recurso por releitura. O
    # initramfs é regenerado ao final sempre que algum recurso que ele embute
    # chegou a mudar: sem isso o host ficaria com initramfs e configuração em
    # versões incompatíveis, que é exatamente o risco que REQ-IOMMU-TX fecha.
    local falhas=0
    IOMMU_TX_ESTADO=ROLLING_BACK
    if [ "$IOMMU_TX_ALTEROU_VFIO" -eq 1 ]; then
        _vfio_descartar_staged
        if _iommu_tx_restaurar_vfio; then
            aviso "vfio.conf restaurado e comprovado por releitura."
        else
            erro "ROLLBACK DE vfio.conf NÃO COMPROVADO: revise $VFIO_MODULES_ARQUIVO antes de reiniciar."
            falhas=$((falhas + 1))
        fi
    fi
    if [ "$IOMMU_TX_ALTEROU_BOOT" -eq 1 ]; then
        if _iommu_tx_restaurar_boot; then
            aviso "Parâmetros de boot restaurados e comprovados por releitura."
        else
            erro "ROLLBACK DE BOOT NÃO COMPROVADO: ${KERNEL_PERSISTENCIA_ERRO:-persistência não relida}."
            erro "NÃO REINICIE antes de revisar a configuração do $BOOTLOADER_ATIVO."
            falhas=$((falhas + 1))
        fi
    fi
    # A regeneração conta a partir da TENTATIVA, não do sucesso: um
    # update-initramfs que falhou no meio pode ter deixado a imagem
    # inconsistente, e é justamente aí que ressincronizar importa.
    if [ "$IOMMU_TX_ALTEROU_VFIO" -eq 1 ] || [ "$IOMMU_TX_INITRAMFS_TENTADO" -eq 1 ]; then
        if ( plataforma_atualizar_initramfs >/dev/null ); then
            aviso "Initramfs regenerado para voltar a coincidir com a configuração restaurada."
        else
            erro "INITRAMFS NÃO RESSINCRONIZADO. Rode manualmente a regeneração do initramfs antes de reiniciar."
            falhas=$((falhas + 1))
        fi
    fi
    _iommu_tx_descartar_backup_vfio
    [ "$falhas" -eq 0 ]
}

iommu_vfio_transacao() {
    # Aplica a convergência persistente de IOMMU/VFIO como uma transação só.
    # Pré-condição: o chamador já armou os traps que chamam iommu_vfio_rollback
    # e já obteve o ticket de sudo. Retornos: 0=convergido (com ou sem
    # mutação); 1=recusado antes de qualquer efeito.
    local params="${1:-$IOMMU_PARAMS_PADRAO}" rc_vfio=0
    IOMMU_TX_ERRO=""
    IOMMU_TX_PARAMS="$params"
    IOMMU_TX_CHAVES="$(boot_params_chaves "$params")"
    IOMMU_TX_ALTEROU_BOOT=0
    IOMMU_TX_ALTEROU_VFIO=0
    IOMMU_TX_INITRAMFS_TENTADO=0
    IOMMU_TX_INITRAMFS_APLICADO=0

    kernel_parametros_validos "$params" \
        || { IOMMU_TX_ERRO="Lista de parâmetros de kernel inválida: '$params'."; return 1; }

    # 1. Snapshots. Nada foi tocado ainda.
    if ! kernel_parametros_persistentes "$IOMMU_TX_CHAVES"; then
        IOMMU_TX_ERRO="Estado persistente de boot não pôde ser lido: $KERNEL_PERSISTENCIA_ERRO"
        return 1
    fi
    IOMMU_TX_PERSISTENCIA_ANTERIOR="$KERNEL_PARAMETROS_PERSISTENTES"
    vfio_modules_estado || rc_vfio=$?
    if [ "$rc_vfio" -eq 2 ]; then
        IOMMU_TX_ERRO="$VFIO_MODULES_ERRO"
        return 1
    fi
    IOMMU_TX_VFIO_EXISTIA="$VFIO_MODULES_EXISTE"
    IOMMU_TX_VFIO_CONTEUDO_ANTERIOR="$VFIO_MODULES_ATUAL"

    # 2. Candidatos completos e validados antes da primeira mutação.
    local candidato_boot="$params" candidato_vfio="$VFIO_MODULES_CANDIDATO"
    [ -n "$candidato_vfio" ] \
        || { IOMMU_TX_ERRO="Candidato de vfio.conf vazio; nada foi alterado."; return 1; }

    local boot_convergido=0
    if [ "$IOMMU_TX_PERSISTENCIA_ANTERIOR" = "$candidato_boot" ]; then
        boot_convergido=1
    fi
    if [ "$boot_convergido" -eq 1 ] && [ "$rc_vfio" -eq 0 ]; then
        # No-op exato: nem boot, nem vfio.conf, nem initramfs são tocados.
        IOMMU_TX_ESTADO=COMMITTED
        info "Boot persistente e vfio.conf já convergidos; nenhuma alteração aplicada."
        return 0
    fi

    if [ "$IOMMU_TX_VFIO_EXISTIA" -eq 1 ] || [ "$rc_vfio" -ne 0 ]; then
        _iommu_tx_backup_vfio || return 1
    fi

    IOMMU_TX_ESTADO=PREPARED

    # 3. Boot primeiro: kernel_param_add já é transacional por backend e prova
    #    a própria pós-condição; aqui a prova é repetida pela transação.
    if [ "$boot_convergido" -eq 0 ]; then
        IOMMU_TX_ALTEROU_BOOT=1
        info "Aplicando $params via $BOOTLOADER_ATIVO..."
        kernel_param_add "$params" \
            || falhar "A alteração de boot falhou; a transação restaurará o estado anterior."
        kernel_parametros_persistentes_exatos "$params" \
            || falhar "Persistência de IOMMU não comprovada após a alteração: $KERNEL_PERSISTENCIA_ERRO"
        IOMMU_TX_ESTADO=BOOT
    fi

    # 4. vfio.conf, preservando conteúdo não gerenciado e metadados.
    if [ "$rc_vfio" -ne 0 ]; then
        IOMMU_TX_ALTEROU_VFIO=1
        info "Convergindo $VFIO_MODULES_ARQUIVO (bloco gerenciado)..."
        _vfio_publicar "$candidato_vfio" \
            || falhar "${VFIO_MODULES_ERRO:-Falha ao publicar vfio.conf}"
        vfio_modules_estado \
            || falhar "vfio.conf não convergiu após a publicação: ${VFIO_MODULES_ERRO:-conteúdo divergente}."
        IOMMU_TX_ESTADO=VFIO
    fi

    # 5. Initramfs só depois de boot e vfio.conf aplicados e comprovados.
    # Cada comando mutante desta função é verificado explicitamente: como o
    # chamador testa o status da transação, o errexit fica suspenso dentro dela
    # e "não checar" viraria falha silenciosa em vez de rollback.
    info "Regenerando initramfs via $PLATAFORMA_INITRAMFS_BACKEND..."
    IOMMU_TX_INITRAMFS_TENTADO=1
    plataforma_atualizar_initramfs \
        || falhar "A regeneração do initramfs falhou; a transação restaurará boot e vfio.conf."
    IOMMU_TX_INITRAMFS_APLICADO=1
    IOMMU_TX_ESTADO=INITRAMFS

    # 6. Prova final: os dois recursos relidos, não os retornos dos comandos.
    kernel_parametros_persistentes_exatos "$params" \
        || falhar "Persistência de IOMMU divergiu após o initramfs: $KERNEL_PERSISTENCIA_ERRO"
    vfio_modules_estado \
        || falhar "vfio.conf divergiu após o initramfs: ${VFIO_MODULES_ERRO:-conteúdo divergente}."
    IOMMU_TX_ESTADO=VERIFIED

    _iommu_tx_descartar_backup_vfio
    IOMMU_TX_ESTADO=COMMITTED
    return 0
}
