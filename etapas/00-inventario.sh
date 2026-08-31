#!/bin/bash
# ============================================================================
# etapas/00-inventario.sh - Etapa 1: Inventário de Hardware
# ============================================================================
# Levanta a identificação completa do hardware e grava um arquivo datado na raiz
# única de estado do projeto (o diretório vem do acessor diretorio_inventario;
# por padrão ${XDG_STATE_HOME:-~/.local/state}/vm-passthrough/inventario/). A
# coleta não reconfigura o hardware; se necessário, o script instala dmidecode e
# sempre cria/atualiza o relatório local.
#
# Por que pede senha de administrador logo no início:
#   - dmidecode lê a tabela SMBIOS/DMI (memória, placa-mãe, firmware) e exige root;
#   - dmesg é restrito a root no Pop!_OS (kernel.dmesg_restrict=1), então o bloco
#     de IOMMU/DMAR sairia VAZIO sem sudo (o manual traz esse comando sem sudo,
#     que é justamente onde ele falha).
# Pedindo a senha uma vez no começo, o relatório sai completo de primeira.
# ============================================================================
SCRIPT_VERSION="1.0.0"
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

verificar() {
    # resolver_ultimo_inventario e validar_inventario_principal devolvem 1 para
    # "nunca gerado", "ponteiro adulterado", "ilegível" e "core indisponível".
    # O verificador não pode achatar os quatro em pendência: cada motivo manda o
    # operador a um lugar diferente. Tudo aqui é leitura.
    local inventario="" diretorio="" ponteiro="" alvo=""
    diretorio="$(diretorio_inventario)" || diretorio=""
    if [ -z "$diretorio" ]; then
        v_indeterminado "Não foi possível resolver o diretório de inventários; o estado não pôde ser observado."
        v_fim
    fi
    # Sem o core Python nada do schema é observável: o arquivo pode estar
    # perfeito e ainda assim nenhuma prova é possível.
    if ! python_core_disponivel; then
        v_indeterminado "Core Python indisponível; o inventário não pôde ser validado: ${PYTHON_CORE_ERRO:-sem diagnóstico}."
        v_fim
    fi
    if [ -d "$diretorio" ] && { [ ! -r "$diretorio" ] || [ ! -x "$diretorio" ]; }; then
        v_indeterminado "Diretório de inventários sem permissão de leitura; o estado não pôde ser observado ($diretorio)."
        v_fim
    fi
    ponteiro="$diretorio/ultimo-inventario.txt"
    if [ -e "$ponteiro" ] && [ ! -L "$ponteiro" ]; then
        v_erro "Ponteiro de inventário não é um link simbólico: $ponteiro"
        v_fim
    fi
    if resolver_ultimo_inventario >/dev/null; then
        inventario="$INVENTARIO_RESOLVIDO"
        if validar_inventario_principal "$inventario"; then
            v_ok "Último inventário completo: $inventario"
        else
            v_erro "Inventário publicado e ilegível ou fora do schema: ${INVENTARIO_ERRO:-sem diagnóstico}"
        fi
    elif [ -L "$ponteiro" ]; then
        # Existe ponteiro publicado e ele NÃO resolve: o estado é contraditório,
        # não é "a etapa ainda não rodou".
        alvo="$(readlink -- "$ponteiro" 2>/dev/null)" || alvo=""
        if [ -n "$alvo" ] && [ -e "$diretorio/$alvo" ] && [ ! -r "$diretorio/$alvo" ]; then
            v_indeterminado "Inventário apontado por $ponteiro não é legível; o conteúdo não pôde ser comprovado."
        else
            v_erro "${INVENTARIO_ERRO:-Ponteiro de inventário inválido: $ponteiro}"
        fi
    else
        v_falta "${INVENTARIO_ERRO:-Nenhum inventário válido gerado ainda.}"
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

guard_mutation inventory.write || exit 1
exigir_nao_root
exigir_sudo

# O caminho literal dos relatórios existe em UM lugar só (`lib/shell/base.sh`); aqui
# ele vem do acessor, para que o inventário caia na mesma raiz de estado do log
# de ações e das listagens de grupos IOMMU.
DIRETORIO_INVENTARIO="$(diretorio_inventario)"

titulo "Etapa 1: Inventário de Hardware"
info "Finalidade: registrar CPU, RAM, firmware, PCI, discos e IOMMU para conferir as próximas etapas."
info "Pré-requisito: execute como usuário normal com acesso sudo e mantenha o hardware conectado."
aviso "Alterações: pode atualizar o índice APT e instalar dmidecode; grava um relatório datado em $DIRETORIO_INVENTARIO/."
info "A coleta não altera hardware, BIOS/UEFI, firmware, partições nem configuração dos dispositivos."
aviso "Risco: o relatório contém modelos, seriais e IDs do equipamento; guarde-o em local confiável."
info "Não exige reboot; ao terminar, volte ao menu para continuar."

# Pergunta UMA vez, depois dos avisos e antes de qualquer escrita desta etapa:
# recusar é seguro, porque o relatório novo vai para a raiz de estado de todo
# modo, e aceitar só remove a pasta antiga depois de conferir a cópia inteira.
inventario_migracao_interativa

# dmidecode pode não existir antes da etapa 6 (pacotes base); resolve aqui.
if ! command -v dmidecode >/dev/null 2>&1; then
    info "Instalando dmidecode (necessário para ler SMBIOS/DMI)..."
    sudo apt-get update -qq
    sudo apt-get install -y dmidecode
fi

mkdir -p "$DIRETORIO_INVENTARIO"
TMP_INVENTARIO="$(umask 077; mktemp "$DIRETORIO_INVENTARIO/.inventario.tmp.XXXXXXXXX")" \
    || falhar "Não foi possível criar o relatório temporário."
TMP_LINK=""
PUBLICADO=0
limpar_temporarios_inventario() {
    [ "$PUBLICADO" -eq 1 ] || rm -f -- "$TMP_INVENTARIO"
    [ -z "$TMP_LINK" ] || rm -f -- "$TMP_LINK"
    encerrar_sudo_keepalive
}
trap limpar_temporarios_inventario EXIT INT TERM

MEMORIA_DMI="$(sudo dmidecode --type memory 2>/dev/null)" \
    || falhar "Não foi possível capturar a memória por SMBIOS/DMI."
BASEBOARD_DMI="$(sudo dmidecode -t baseboard 2>/dev/null)" \
    || falhar "Não foi possível capturar a placa-base por SMBIOS/DMI."
BIOS_DMI="$(sudo dmidecode -t bios 2>/dev/null)" \
    || falhar "Não foi possível capturar o firmware por SMBIOS/DMI."
MENSAGENS_IOMMU="$(sudo dmesg 2>/dev/null | grep -i -e DMAR -e IOMMU || true)"
MENSAGENS_IOMMU="${MENSAGENS_IOMMU:-(vazio: normal antes da etapa 11)}"
declare -a CAPTURA_INVENTARIO=()
coletar_snapshot_inventario CAPTURA_INVENTARIO \
    "$MEMORIA_DMI" "$BASEBOARD_DMI" "$BIOS_DMI" "$MENSAGENS_IOMMU" \
    || falhar "Não foi possível capturar os fatos do inventário."
inventario_normalizar_snapshot CAPTURA_INVENTARIO "$TMP_INVENTARIO" \
    || falhar "A coleta não produziu um inventário normalizado: $INVENTARIO_ERRO"
cat -- "$TMP_INVENTARIO"

validar_inventario_principal "$TMP_INVENTARIO" \
    || falhar "A coleta não produziu um inventário completo: $INVENTARIO_ERRO"
publicar_inventario_completo "$TMP_INVENTARIO" "$DIRETORIO_INVENTARIO" >/dev/null \
    || falhar "$INVENTARIO_ERRO"
ARQUIVO="$INVENTARIO_PUBLICADO"
PUBLICADO=1

limpar_temporarios_inventario
trap - EXIT INT TERM

echo
ok "Inventário salvo em: $ARQUIVO"
info "Ponteiro atualizado: $DIRETORIO_INVENTARIO/ultimo-inventario.txt -> ${ARQUIVO##*/}"
info "Confira na seção PCI as duas linhas NVIDIA (VGA e Audio) no mesmo barramento (ex.: 0c:00.x)."
info "Recomendação do manual: guarde uma cópia deste arquivo FORA do disco do sistema."
