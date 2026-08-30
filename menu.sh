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
SCRIPT_VERSION="1.0.0"
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
carregar_conf

# Cada verificador informa seu próprio estado pelo contrato 0/1/2/3. O menu
# agrega os resultados com a mesma precedência: erro > indeterminado > pendente.
ETAPAS=(
    "00-inventario.sh|Inventário de hardware|auto||inventory.write"
    "01-verificar-bios.sh|BIOS/UEFI: checklist e verificação|manual||"
    "02-detectar-config.sh|Reiniciar configuração central: GPU, workingDisk, CPU/RAM e rede|auto||config.manage"
    "10-atualizar-sistema.sh|Atualizar sistema e firmware|auto|reboot|host.update"
    "11-driver-nvidia.sh|Driver NVIDIA no host|auto|reboot|gpu.driver"
    "12-pacotes-base.sh|Pacotes base|auto||packages.base"
    "13-diretorios.sh|Diretório /vm|auto||storage.prepare"
    "14-working-disk.sh|workingDisk externo: preflight|auto||"
    "20-virtualizacao.sh|Pilha KVM/QEMU/libvirt|auto||virtualization.manage"
    "21-usuario-grupos.sh|Usuário, grupos e /vm|auto|logout|virtualization.manage"
    "30-iommu-vfio.sh|IOMMU e VFIO|auto|reboot|iommu.configure"
    "40-criar-vm.sh|Criar a VM com virt-install|auto||domain.create"
    "41-instalacao-windows.sh|Instalar o Windows na VM|manual||domain.console"
    "50-hooks-gpu-hd1.sh|Hooks da GPU e HD1 físico|auto||hooks.configure"
    "51-usb-passthrough.sh|USB passthrough: dispositivos ou controladora inteira|opcional||usb.configure"
    "55-driver-nvidia-vm.sh|Instalar driver NVIDIA na VM (automático)|auto||guest.driver"
    "52-cpu-pinning-hugepages.sh|CPU pinning e HugePages|opcional|reboot|cpu.tune"
    "53-cpu-isolation.sh|CPU isolation|opcional|reboot|cpu.tune"
    "60-rede-bridge.sh|Rede final: bridge Ethernet ou NAT|auto||network.configure"
    "61-airlock.sh|Airlock: SFTP seguro|auto||airlock.configure"
    "70-trim-discard.sh|TRIM/discard e backups|auto||trim.configure"
)

UTILS=(
    "diagnostico.sh|Diagnóstico geral (consulte troubleshooting.md)|diagnostic.write"
    "listar-grupos-iommu.sh|Listar grupos IOMMU|"
    "snapshot-vm.sh|Gerenciar snapshots QCOW2 (retorno rápido; não são backup)|"
    "backup-vm.sh|Backup real da VM|backup.create"
    "atualizar-host.sh|Atualizar host (snapshot se possível, full-upgrade, reboot e validação)|host.update"
    "recuperar-gpu.sh|EMERGÊNCIA: devolver a GPU ao Linux (consulte troubleshooting.md)|gpu.recover"
)

WAIVER_POLITICA_AVISADA=0
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
    echo "**************************************"
    echo
    echo " ${C_NEGRITO}Setup VM Windows com GPU Passthrough${C_RESET}"
    echo
    echo "**************************************"
    echo
    echo "Scripts de instalação e configuração da VM Windows (Windows 11) com GPU em passthrough (KVM/QEMU/libvirt + VFIO)"
    echo
    echo "${C_AMARELO}Recomendação:${C_RESET}"
    echo "Execute como usuário normal, siga a ordem e, após <reboot>/<logout>, retorne ao menu antes de continuar."
    echo
    echo "No modo interativo, sudo será solicitado quando necessário."
    echo "A opção 3 reinicia a configuração central, faz backup das escolhas atuais e pergunta tudo novamente."
    echo "Ela usa automaticamente o último inventário completo da opção 1 e preserva validações ao vivo."
    echo "O menu apenas consulta status e inicia o item escolhido; cada fluxo informa alterações e riscos."
    echo
    echo "${C_AMARELO}Configuração:${C_RESET}"
    echo "${CONF_ARQUIVO} $( [ -f "$CONF_ARQUIVO" ] && echo ${C_VERDE}'(presente)'${C_RESET} || echo ${C_VERMELHO}'(AUSENTE: execute a opção 3)'${C_RESET})"
    echo
    echo ---
    echo
    echo "${C_AZUL}menu v${SCRIPT_VERSION} · lib v${LIB_COMMON_VERSION}${C_RESET}"
    echo
    echo "**************************************"
    echo
    local i=1 entrada arquivo titulo tipo pos capability st simbolo waiver_rc
    WAIVER_POLITICA_AVISADA=0
    for entrada in "${ETAPAS[@]}"; do
        IFS='|' read -r arquivo titulo tipo pos capability <<< "$entrada"
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
        # REQ-WAIVERS: a dispensa entra AQUI, depois de MENU_STATUS_RC já ter
        # sido agregado acima, e só troca o símbolo. Ela é lida por canal
        # separado (a flag validada de passthrough.conf, resolvida contra a
        # matriz de política versionada), nunca por parsing do texto que a
        # etapa imprimiu, e nunca entra no sentinel V1. O motivo de não dizer
        # "concluída": com a escolha de modo registrada, a etapa não foi
        # executada; o recurso é que não se aplica a este fluxo.
        waiver_rc=0
        waiver_estado "$arquivo" || waiver_rc=$?
        # Matriz ilegível não pode degradar em silêncio: sem ela o menu voltaria
        # a pintar [ok] numa etapa dispensada, que é exatamente o "concluída"
        # que o requisito proíbe. O aviso sai uma vez por listagem.
        if [ "$waiver_rc" -eq 2 ] && [ "$WAIVER_POLITICA_AVISADA" -eq 0 ]; then
            WAIVER_POLITICA_AVISADA=1
            aviso "Política de dispensas não pôde ser lida: ${WAIVER_ERRO:-motivo ausente}. O menu não distingue etapa dispensada nesta listagem."
        fi
        if [ "$st" = "ok" ] && [ "$waiver_rc" -eq 0 ] \
            && [ "$WAIVER_SIMBOLO" = "disp" ]; then
            simbolo="${C_AZUL}[disp]${C_RESET}"
        elif [ "$st" = "ok" ]; then
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
        printf ' %s %2d) %s %s(v%s)%s' "$simbolo" "$i" "$titulo" \
            "$C_AZUL" "$(versao_de_script "$PROJETO_DIR/etapas/$arquivo")" "$C_RESET"
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
        IFS='|' read -r arquivo titulo capability <<< "$entrada"
        printf '      u%d) %s %s(v%s)%s\n' "$u" "$titulo" \
            "$C_AZUL" "$(versao_de_script "$PROJETO_DIR/util/$arquivo")" "$C_RESET"
        u=$((u+1))
    done
    echo
    echo " Legenda: [ok] concluída  [disp] dispensada por escolha de modo (não executada)  [  ] pendente  [--] opcional pendente  [??] indeterminada  [!!] erro (diagnóstico abaixo)  <reboot>/<logout> exigidos ao final"
}

if [ "${1:-}" = "--status" ]; then
    imprimir_lista
    exit "$MENU_STATUS_RC"
fi

exigir_nao_root

limpar_terminal_menu() {
    # A saída da etapa permanece visível até o ENTER. A limpeza ocorre somente
    # quando o menu vai ser redesenhado e nunca no modo não interativo --status.
    if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && command -v clear >/dev/null 2>&1; then
        clear 2>/dev/null || true
    fi
}

executar_no_menu() {
    local caminho="$1" capability="${2:-}" rc resposta
    local etapa_arquivo dispensa_ativa=0
    etapa_arquivo="$(basename -- "$caminho")"
    echo
    # REQ-WAIVERS: execução direta NUNCA infere conclusão pela dispensa. Antes
    # de rodar, o menu informa qual pré-requisito a escolha de modo exclui, e
    # depois evita chamar de "concluída" uma execução que não fez nada.
    if waiver_estado "$etapa_arquivo"; then
        dispensa_ativa=1
        aviso "$(waiver_politica_texto "$etapa_arquivo")"
    fi
    log_ativar
    log_acao menu "executando $(basename -- "$caminho") v$(versao_de_script "$caminho")"
    if [ -n "$capability" ]; then
        if guard_mutation "$capability"; then
            bash "$caminho"
            rc=$?
        else
            rc=$?
        fi
    else
        bash "$caminho"
        rc=$?
    fi
    log_acao menu "$(basename -- "$caminho") terminou com status $rc"
    case "$rc" in
        0)
            if [ "$dispensa_ativa" -eq 1 ]; then
                ok "Nada a executar: a escolha de modo registrada em $WAIVER_CHAVE dispensa o pré-requisito \"$WAIVER_PREREQ\". A etapa não foi executada."
            else
                ok "Execução concluída."
            fi
            ;;
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
                IFS='|' read -r ARQUIVO _ CAPABILITY <<< "${UTILS[$((10#$IDX - 1))]}"
                executar_no_menu "$PROJETO_DIR/util/$ARQUIVO" "$CAPABILITY" || {
                    [ "$?" -eq "$CODIGO_SAIR_MENU" ] && exit 0
                }
            else
                aviso "Utilitário inválido: '$ESCOLHA'."
            fi
            ;;
        [0-9]*)
            if [[ "$ESCOLHA" =~ ^[0-9]+$ ]] && [ "$((10#$ESCOLHA))" -ge 1 ] && [ "$((10#$ESCOLHA))" -le "${#ETAPAS[@]}" ]; then
                IFS='|' read -r ARQUIVO _ _ _ CAPABILITY <<< "${ETAPAS[$((10#$ESCOLHA - 1))]}"
                executar_no_menu "$PROJETO_DIR/etapas/$ARQUIVO" "$CAPABILITY" || {
                    [ "$?" -eq "$CODIGO_SAIR_MENU" ] && exit 0
                }
            else
                aviso "Etapa inválida: '$ESCOLHA'."
            fi
            ;;
        *) aviso "Opção inválida: '$ESCOLHA'." ;;
    esac
done
