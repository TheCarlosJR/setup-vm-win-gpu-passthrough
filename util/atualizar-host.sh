#!/bin/bash
# ============================================================================
# util/atualizar-host.sh - atualização do host com snapshot opcional da VM
# ============================================================================
# Uso:
#   atualizar-host.sh            tenta snapshot libvirt e executa apt update,
#                                full-upgrade e autoremove
#   atualizar-host.sh --validar  faz checagens parciais depois do reboot
# ============================================================================
SCRIPT_VERSION="1.0.0"
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

MODO_ATUALIZAR_HOST="${1:-}"
case "$MODO_ATUALIZAR_HOST" in
    ""|--validar) ;;
    *) falhar "Uso: $0 [--validar]" ;;
esac

# No contrato público de validação, 1 significa pendente. Erros fatais de
# bootstrap/configuração precisam, portanto, sair como STATUS_ERRO (3).
if [ "$MODO_ATUALIZAR_HOST" = "--validar" ]; then
    falhar() { erro "$*"; exit "$STATUS_ERRO"; }
    if ! carregar_conf; then
        erro "A configuração não pôde ser carregada para a validação."
        exit "$STATUS_ERRO"
    fi
else
    carregar_conf
fi

confirmar_validacao() {
    local resposta=""
    read -r -p "$1 [s/N] " resposta || return 1
    case "${resposta,,}" in
        s|sim) return 0 ;;
        *) return 1 ;;
    esac
}

nvidia_smi_saida_comprovada() {
    local saida="${1:-}"
    grep -Eq 'NVIDIA-SMI[[:space:]]+[0-9]' <<< "$saida" \
        && grep -Eq 'Driver Version:[[:space:]]*[0-9]' <<< "$saida"
}

validar_pos_atualizacao() {
    local saida_nvidia="" saida_nvidia_retorno="" rc_nvidia=0 cmdline_atual=""
    local cmdline_arquivo="" saida_dmesg="" rc_dmesg=0 linhas_amd_vi=""
    local mensagens_amd_vi="" rc_sudo=0 sudo_ok=0 rc_start=0
    local estado_vm="" rc_domstate=0

    titulo "Validação parcial pós-atualização"
    info "Finalidade: checar driver NVIDIA, parâmetros AMD IOMMU e, opcionalmente, iniciar a VM para observar os hooks."
    info "Pré-requisitos: reboot concluído, sudo, configuração carregada e acesso ao monitor/TTY para acompanhar o teste da GPU."
    aviso "Efeito: as primeiras checagens são leitura; se confirmado, o teste inicia a VM e entrega a GPU ao Windows."
    info "Recomendação: só inicie a VM após nvidia-smi, cmdline e AMD-Vi estarem comprovados; desligue o Windows para testar o retorno da GPU."
    info "Não abrange: teste automático de áudio, grupo/reset IOMMU, XML/NVRAM/TPM, HD1, DKMS/Secure Boot ou rollback."
    info "Status: 0 exige sondagens automáticas e ciclo de retorno da GPU comprovados; 2 indica evidência ausente/manual; 3 indica falha ou configuração incorreta."

    if [ "$(id -u)" -eq 0 ]; then
        v_erro "O modo --validar deve ser executado como usuário normal; sudo será usado somente para ler o dmesg."
        v_fim
    fi
    if ! guard_mutation domain.console; then
        v_erro "A validação com opção de iniciar a VM foi bloqueada antes de sudo ou qualquer efeito: $MUTATION_GUARD_ERROR"
        v_fim
    fi

    echo "1) Driver NVIDIA no host:"
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        v_indeterminado "nvidia-smi não está disponível; o driver NVIDIA não pôde ser sondado."
    elif saida_nvidia="$(nvidia-smi 2>&1)"; then
        [ -z "$saida_nvidia" ] || awk 'NR <= 12 { print }' <<< "$saida_nvidia"
        if nvidia_smi_saida_comprovada "$saida_nvidia"; then
            v_ok "Driver NVIDIA respondeu com identificação e versão parseáveis."
        else
            v_indeterminado "nvidia-smi terminou com zero, mas a saída não contém identificação e versão parseáveis; o driver não foi comprovado."
        fi
    else
        rc_nvidia=$?
        v_erro "nvidia-smi falhou com código $rc_nvidia: NÃO inicie a VM; confirme módulos e logs do driver NVIDIA no boot atual."
    fi

    echo "2) Parâmetros de IOMMU:"
    cmdline_arquivo="$(caminho_sistema /proc/cmdline 2>/dev/null || true)"
    if [ -z "$cmdline_arquivo" ]; then
        v_erro "Não foi possível resolver /proc/cmdline para validar IOMMU."
    elif ! IFS= read -r cmdline_atual < "$cmdline_arquivo"; then
        v_erro "Não foi possível ler $cmdline_arquivo para validar IOMMU."
    elif cmdline_parametros_exatos "amd_iommu=on iommu=pt" "$cmdline_atual"; then
        v_ok "amd_iommu=on e iommu=pt estão presentes uma única vez com valores exatos."
    else
        v_erro "Parâmetros AMD IOMMU incorretos: $CMDLINE_PARAM_ERRO"
    fi

    if ! command -v sudo >/dev/null 2>&1; then
        v_erro "sudo não está disponível; o dmesg privilegiado não pôde ser lido."
    else
        if sudo -n true 2>/dev/null; then
            sudo_ok=1
        else
            info "Acesso administrativo é necessário somente para a leitura do dmesg."
            if sudo -v; then
                sudo_ok=1
            else
                rc_sudo=$?
                v_erro "Não foi possível obter autorização sudo para ler o dmesg (código $rc_sudo)."
            fi
        fi
        if [ "$sudo_ok" -eq 1 ]; then
            if saida_dmesg="$(sudo dmesg 2>&1)"; then
                linhas_amd_vi="$(awk 'tolower($0) ~ /amd-vi/ { print }' <<< "$saida_dmesg")"
                mensagens_amd_vi="$(awk 'NR <= 5 { print }' <<< "$linhas_amd_vi")"
                if [ -z "$linhas_amd_vi" ]; then
                    v_indeterminado "O dmesg foi lido, mas não contém evidência AMD-Vi; IOMMU não foi comprovado por esta sonda."
                elif grep -Eiq '(fail(ed|ure)?|error|unable|disable(d)?|unsupported|not[[:space:]]+(enabled|available|supported|found|present|active)|timeout|timed[[:space:]]+out|fault|cannot)' <<< "$linhas_amd_vi"; then
                    printf '%s\n' "$mensagens_amd_vi"
                    v_erro "O dmesg contém evidência negativa de AMD-Vi; revise firmware, cmdline e logs completos antes de iniciar a VM."
                elif grep -Eiq '(initiali[sz]ed|enabl(ed|ing)|found[[:space:]]+iommu|extended features|using global ivhd|performance counters supported|passthrough mode)' <<< "$linhas_amd_vi"; then
                    printf '%s\n' "$mensagens_amd_vi"
                    v_ok "AMD-Vi possui evidência positiva parseável no dmesg do boot atual."
                else
                    printf '%s\n' "$mensagens_amd_vi"
                    v_indeterminado "O dmesg menciona AMD-Vi, mas não contém uma pós-condição positiva reconhecida."
                fi
            else
                rc_dmesg=$?
                v_erro "Falha operacional ao ler dmesg (código $rc_dmesg); a ausência de saída não foi tratada como sucesso."
            fi
        fi
    fi

    echo "3) Teste manual da VM e dos hooks:"
    if [ "$V_ERROS" -gt 0 ] || [ "$V_INDETERMINADOS" -gt 0 ]; then
        v_indeterminado "A VM não foi iniciada porque as sondagens automáticas não estão todas comprovadas."
    elif [ -z "${VM_NAME:-}" ]; then
        v_indeterminado "VM_NAME não está configurado; o ciclo dos hooks e o retorno da GPU não puderam ser comprovados."
    elif ! confirmar_validacao "Iniciar a VM $VM_NAME agora para testar o passthrough?"; then
        v_indeterminado "O teste da VM não foi executado; o retorno da GPU e os hooks permanecem não comprovados."
    elif ! guard_mutation domain.console; then
        v_erro "O teste da VM foi bloqueado antes do primeiro efeito: $MUTATION_GUARD_ERROR"
    elif $VIRSH start "$VM_NAME"; then
        info "Esperado: monitor troca para o Windows. Desligue o Windows antes de responder à próxima pergunta."
        info "Logs auxiliares: sudo journalctl -u libvirtd -e | grep -i hook"
        if ! confirmar_validacao "Após desligar o Windows, o desktop Linux retornou e a GPU parece disponível?"; then
            v_indeterminado "A VM iniciou, mas o retorno da GPU não foi confirmado pelo operador."
        elif estado_vm="$(vm_estado "$VM_NAME")"; then
            if [ "$estado_vm" != "shut off" ]; then
                v_indeterminado "O libvirt não comprovou a VM '$VM_NAME' como desligada; o ciclo dos hooks ainda não foi encerrado."
            elif saida_nvidia_retorno="$(nvidia-smi 2>&1)"; then
                [ -z "$saida_nvidia_retorno" ] || awk 'NR <= 12 { print }' <<< "$saida_nvidia_retorno"
                if nvidia_smi_saida_comprovada "$saida_nvidia_retorno"; then
                    v_ok "VM desligada e GPU novamente comprovada no host após o ciclo dos hooks."
                else
                    v_indeterminado "nvidia-smi retornou zero após o desligamento, mas sua saída não comprovou identificação e versão da GPU."
                fi
            else
                rc_nvidia=$?
                v_erro "A VM desligou, mas nvidia-smi falhou após o ciclo dos hooks (código $rc_nvidia); o retorno da GPU não ocorreu."
            fi
        else
            rc_domstate=$?
            v_erro "Falha operacional ao consultar o estado da VM '$VM_NAME' no libvirt (código $rc_domstate); o desligamento não foi comprovado."
        fi
    else
        rc_start=$?
        v_erro "Falha ao iniciar a VM '$VM_NAME' para o teste dos hooks (código $rc_start)."
    fi
    v_fim
}

if [ "$MODO_ATUALIZAR_HOST" = "--validar" ]; then
    validar_pos_atualizacao
fi

guard_mutation host.update || exit 1
exigir_nao_root

exigir_sudo

titulo "Atualização do host com proteção prévia da VM"
info "Finalidade: criar um snapshot interno offline da VM antes de executar apt update, full-upgrade e autoremove no host."
info "Pré-requisitos: sudo, APT/rede funcionais e espaço; para o snapshot, VM configurada, desligada e QCOW2 ativo sem overlay externo."
aviso "Efeito: pode criar snapshot interno, atualizar/remover pacotes, trocar kernel/driver e reiniciar o host se você confirmar."
info "Recomendação: desligue a VM e tenha cópia independente verificada antes de continuar; revise pacotes críticos depois."
aviso "Risco: full-upgrade/autoremove podem remover versões úteis para rollback; sem snapshot, só prossiga com confirmação textual e backup independente."
info "Limite do snapshot: não é backup independente nem rollback do host e não cobre HD1; XML/NVRAM/TPM restauráveis não são garantidos."
info "Retorno/reboot: falhas APT interrompem. Sem snapshot interno comprovado, o script exige confirmação textual. O reboot é opcional, mas necessário antes de --validar."
SNAPSHOT_OK=0
if [ -n "${VM_NAME:-}" ] && vm_existe "$VM_NAME"; then
    NOME_SNAP="antes-atualizacao-host-$(date +%Y%m%d-%H%M%S)"
    if vm_desligada "$VM_NAME"; then
        info "Criando snapshot interno offline pré-atualização '$NOME_SNAP'..."
        if bash "$PROJETO_DIR/util/snapshot-vm.sh" criar "$NOME_SNAP" \
            "Snapshot interno da VM antes de atualizar o host; não substitui backup"; then
            SNAPSHOT_OK=1
            ok "Snapshot interno pré-atualização criado e comprovado."
        else
            aviso "Snapshot interno falhou (overlay externo, armazenamento, espaço ou configuração)."
        fi
    else
        aviso "VM está ligada; snapshot interno offline não será criado."
    fi
else
    aviso "VM não encontrada; não há snapshot a criar."
fi
if [ "$SNAPSHOT_OK" -ne 1 ]; then
    confirmar_digitando "CONTINUAR SEM SNAPSHOT" "Sem snapshot interno comprovado da VM. Confirme que há backup independente e digite CONTINUAR SEM SNAPSHOT para atualizar mesmo assim." \
        || falhar "Atualização cancelada sem snapshot."
fi

sudo apt update
sudo apt full-upgrade -y
sudo apt autoremove -y

echo
info "Pacotes NVIDIA ainda marcados como atualizáveis:"
apt list --upgradable 2>/dev/null | grep -i nvidia || echo "  (nenhum pendente)"

echo
aviso "Após reiniciar, faça a validação pós-reboot com: bash util/atualizar-host.sh --validar"
aviso "Não repita o modo de atualização apenas para validar; na mensagem genérica abaixo, 'mesma etapa' significa usar --validar."
pedir_reboot
