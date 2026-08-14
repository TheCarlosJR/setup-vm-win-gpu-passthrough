#!/bin/bash
# ============================================================================
# menu.sh - orquestrador das etapas
# ============================================================================
# Mostra o status AO VIVO de cada etapa (cada uma é consultada com --verificar,
# que pergunta ao próprio sistema, não a arquivos de estado: o status continua
# correto mesmo depois de reboots) e executa a etapa escolhida.
#
# Uso:
#   bash menu.sh            menu interativo
#   bash menu.sh --status   só imprime o checklist e sai
# ============================================================================
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
carregar_conf

# Cada verificador informa seu próprio estado pelo contrato 0/1/2/3. O menu
# agrega os resultados com a mesma precedência: erro > indeterminado > pendente.
ETAPAS=(
    "00-inventario.sh|Inventário de hardware (Cap. 3)|auto|"
    "01-verificar-bios.sh|BIOS/UEFI: checklist e verificação (Cap. 12)|manual|"
    "02-detectar-config.sh|Reiniciar configuração central: GPU, workingDisk, CPU/RAM e rede|auto|"
    "10-atualizar-sistema.sh|Atualizar sistema e firmware (Cap. 7)|auto|reboot"
    "11-driver-nvidia.sh|Driver NVIDIA no host (Cap. 8)|auto|reboot"
    "12-pacotes-base.sh|Pacotes base (Cap. 9)|auto|"
    "13-diretorios.sh|Diretório /vm (Cap. 10)|auto|"
    "14-working-disk.sh|workingDisk externo: preflight (Cap. 11)|auto|"
    "20-virtualizacao.sh|Pilha KVM/QEMU/libvirt (Cap. 13)|auto|"
    "21-usuario-grupos.sh|Usuário, grupos e /vm (Cap. 14)|auto|logout"
    "30-iommu-vfio.sh|IOMMU e VFIO (Caps. 15 e 16)|auto|reboot"
    "40-criar-vm.sh|Criar a VM com virt-install (Cap. 17)|auto|"
    "41-instalacao-windows.sh|Instalar o Windows na VM (Cap. 18)|manual|"
    "50-hooks-gpu-hd1.sh|Hooks da GPU e HD1 físico (Cap. 19)|auto|"
    "51-usb-passthrough.sh|USB passthrough (Cap. 20)|opcional|"
    "52-cpu-pinning-hugepages.sh|CPU pinning e HugePages (Cap. 21)|opcional|reboot"
    "53-cpu-isolation.sh|CPU isolation (Cap. 22)|opcional|reboot"
    "60-rede-bridge.sh|Rede final: bridge Ethernet ou NAT (Cap. 23)|auto|"
    "61-airlock.sh|Airlock: SFTP seguro (Cap. 24)|auto|"
    "70-trim-discard.sh|TRIM/discard e backups (Cap. 25)|auto|"
)

UTILS=(
    "diagnostico.sh|Diagnóstico geral (Cap. 28)"
    "listar-grupos-iommu.sh|Listar grupos IOMMU (Cap. 16)"
    "snapshot-vm.sh|Gerenciar snapshots QCOW2 (retorno rápido; não são backup) (Cap. 25)"
    "backup-vm.sh|Backup real da VM (Cap. 25)"
    "atualizar-host.sh|Atualizar host (snapshot se possível, full-upgrade, reboot e validação) (Cap. 26)"
    "recuperar-gpu.sh|EMERGÊNCIA: devolver a GPU ao Linux (Cap. 29)"
)

STATUS_ETAPA="erro"
STATUS_ETAPA_DIAGNOSTICO=""
MENU_STATUS_RC=0
status_etapa() {
    # Só aceita 0/1/2/3 quando a última linha comprova que o subprocesso chegou
    # a v_fim com o token efêmero criado para esta chamada.
    local arquivo="$1" rc saida token sentinel sentinel_ok=0
    printf -v token '%08x%08x%08x%08x%08x%08x' \
        "$BASHPID" "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM"
    if saida="$(V_STATUS_TOKEN="$token" bash "$PROJETO_DIR/etapas/$arquivo" --verificar 2>&1)"; then
        rc=0
    else
        rc=$?
    fi
    sentinel="${STATUS_SENTINEL_PREFIX}${token}:${rc}"
    if [ "$saida" = "$sentinel" ]; then
        saida=""
        sentinel_ok=1
    elif [[ "$saida" == *$'\n'"$sentinel" ]]; then
        saida="${saida%$'\n'"$sentinel"}"
        sentinel_ok=1
    fi
    STATUS_ETAPA_DIAGNOSTICO="$saida"
    if [ "$sentinel_ok" -ne 1 ]; then
        STATUS_ETAPA=erro
        STATUS_ETAPA_DIAGNOSTICO="${saida:+$saida$'\n'}Verificador abortou sem sentinel válido de v_fim (código $rc)."
        return 0
    fi
    case "$rc" in
        "$STATUS_CONCLUIDO") STATUS_ETAPA=ok ;;
        "$STATUS_PENDENTE") STATUS_ETAPA=pendente ;;
        "$STATUS_INDETERMINADO") STATUS_ETAPA=indeterminado ;;
        "$STATUS_ERRO") STATUS_ETAPA=erro ;;
        *)
            STATUS_ETAPA=erro
            STATUS_ETAPA_DIAGNOSTICO="${saida:+$saida$'\n'}Verificador terminou com código inesperado $rc."
            ;;
    esac
}

imprimir_diagnostico_status() {
    local linha
    [ -n "$STATUS_ETAPA_DIAGNOSTICO" ] || return 0
    while IFS= read -r linha || [ -n "$linha" ]; do
        printf '      ! %s\n' "$linha"
    done <<< "$STATUS_ETAPA_DIAGNOSTICO"
}

imprimir_lista() {
    MENU_STATUS_RC=0
    echo
    echo "${C_NEGRITO}Windows 11 VM + GPU Passthrough (Ubuntu/Pop!_OS): etapas${C_RESET}"
    echo "Conf: ${CONF_ARQUIVO} $( [ -f "$CONF_ARQUIVO" ] && echo '(presente)' || echo '(AUSENTE: execute a opção 3)')"
    echo "Execute como usuário normal; no modo interativo, sudo será solicitado quando necessário."
    echo "A opção 3 reinicia a configuração central, faz backup das escolhas atuais e pergunta tudo novamente."
    echo "Ela usa automaticamente o último inventário completo da opção 1 e preserva validações ao vivo."
    echo "O menu apenas consulta status e inicia o item escolhido; cada fluxo informa alterações e riscos."
    echo "Recomendação: siga a ordem e, após <reboot>/<logout>, retorne ao menu antes de continuar."
    echo
    local i=1 entrada arquivo titulo tipo pos st simbolo
    for entrada in "${ETAPAS[@]}"; do
        IFS='|' read -r arquivo titulo tipo pos <<< "$entrada"
        status_etapa "$arquivo"
        st="$STATUS_ETAPA"
        case "$st" in
            erro) MENU_STATUS_RC="$STATUS_ERRO" ;;
            indeterminado)
                [ "$MENU_STATUS_RC" -eq "$STATUS_ERRO" ] \
                    || MENU_STATUS_RC="$STATUS_INDETERMINADO"
                ;;
            pendente)
                [ "$MENU_STATUS_RC" -ne "$STATUS_CONCLUIDO" ] \
                    || MENU_STATUS_RC="$STATUS_PENDENTE"
                ;;
        esac
        if [ "$st" = "ok" ]; then
            simbolo="${C_VERDE}[ok]${C_RESET}"
        elif [ "$st" = "erro" ]; then
            simbolo="${C_VERMELHO}[!!]${C_RESET}"
        elif [ "$st" = "indeterminado" ]; then
            simbolo="${C_AMARELO}[??]${C_RESET}"
        elif [ "$tipo" = "opcional" ]; then
            simbolo="${C_AZUL}[--]${C_RESET}"
        else
            simbolo="${C_AMARELO}[  ]${C_RESET}"
        fi
        printf ' %s %2d) %s' "$simbolo" "$i" "$titulo"
        [ "$tipo" = "manual" ] && printf ' %s(manual)%s' "$C_AMARELO" "$C_RESET"
        [ -n "$pos" ] && printf ' %s<%s>%s' "$C_VERMELHO" "$pos" "$C_RESET"
        echo
        if [ "$st" = erro ] || [ "$st" = indeterminado ]; then
            imprimir_diagnostico_status
        fi
        i=$((i+1))
    done
    echo
    echo " Utilitários:"
    local u=1
    for entrada in "${UTILS[@]}"; do
        IFS='|' read -r arquivo titulo <<< "$entrada"
        printf '      u%d) %s\n' "$u" "$titulo"
        u=$((u+1))
    done
    echo
    echo " Legenda: [ok] concluída  [  ] pendente  [--] opcional pendente  [??] indeterminada  [!!] erro (diagnóstico abaixo)  <reboot>/<logout> exigidos ao final"
}

if [ "${1:-}" = "--status" ]; then
    imprimir_lista
    exit "$MENU_STATUS_RC"
fi

exigir_nao_root
# Senha do sudo pedida UMA vez, aqui: o ticket é renovado em segundo plano
# enquanto o menu estiver aberto, e as etapas filhas herdam essa sessão.
# A senha em si nunca é guardada em arquivo.
exigir_sudo

limpar_terminal_menu() {
    # A saída da etapa permanece visível até o ENTER. A limpeza ocorre somente
    # quando o menu vai ser redesenhado e nunca no modo não interativo --status.
    if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && command -v clear >/dev/null 2>&1; then
        clear 2>/dev/null || true
    fi
}

executar_no_menu() {
    local caminho="$1" rc resposta
    echo
    bash "$caminho"
    rc=$?
    case "$rc" in
        0) ok "Execução concluída." ;;
        "$CODIGO_VOLTAR_MENU"|130)
            info "Execução cancelada; voltando ao menu principal."
            return 0
            ;;
        "$CODIGO_SAIR_MENU")
            return "$CODIGO_SAIR_MENU"
            ;;
        *) erro "O comando terminou com status $rc. A saída acima foi preservada para diagnóstico." ;;
    esac
    echo
    read -r -p "ENTER ou v para voltar ao menu; q para sair: " resposta || return 0
    case "${resposta,,}" in
        q|sair) return "$CODIGO_SAIR_MENU" ;;
        *) return 0 ;;
    esac
}

while :; do
    limpar_terminal_menu
    imprimir_lista
    echo
    read -r -p "Etapa (1-${#ETAPAS[@]}), utilitário (u1-u${#UTILS[@]}), r/v=recarregar, 0/q=sair: " ESCOLHA || exit 0
    case "${ESCOLHA,,}" in
        0|q|sair) exit 0 ;;
        r|v|voltar|"") continue ;;
        u[0-9]*)
            IDX="${ESCOLHA#?}"
            if [[ "$IDX" =~ ^[0-9]+$ ]] && [ "$((10#$IDX))" -ge 1 ] && [ "$((10#$IDX))" -le "${#UTILS[@]}" ]; then
                IFS='|' read -r ARQUIVO _ <<< "${UTILS[$((10#$IDX - 1))]}"
                executar_no_menu "$PROJETO_DIR/util/$ARQUIVO" || {
                    [ "$?" -eq "$CODIGO_SAIR_MENU" ] && exit 0
                }
            else
                aviso "Utilitário inválido: '$ESCOLHA'."
            fi
            ;;
        [0-9]*)
            if [[ "$ESCOLHA" =~ ^[0-9]+$ ]] && [ "$((10#$ESCOLHA))" -ge 1 ] && [ "$((10#$ESCOLHA))" -le "${#ETAPAS[@]}" ]; then
                IFS='|' read -r ARQUIVO _ _ _ <<< "${ETAPAS[$((10#$ESCOLHA - 1))]}"
                executar_no_menu "$PROJETO_DIR/etapas/$ARQUIVO" || {
                    [ "$?" -eq "$CODIGO_SAIR_MENU" ] && exit 0
                }
            else
                aviso "Etapa inválida: '$ESCOLHA'."
            fi
            ;;
        *) aviso "Opção inválida: '$ESCOLHA'." ;;
    esac
done
