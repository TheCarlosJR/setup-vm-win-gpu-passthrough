#!/bin/bash
# ============================================================================
# etapas/00-inventario.sh - Capítulo 3: Inventário de Hardware
# ============================================================================
# Levanta a identificação completa do hardware e grava um arquivo datado em
# ~/inventario-hardware/. A coleta não reconfigura o hardware; se necessário,
# o script instala dmidecode e sempre cria/atualiza o relatório local.
#
# Por que pede senha de administrador logo no início:
#   - dmidecode lê a tabela SMBIOS/DMI (memória, placa-mãe, firmware) e exige root;
#   - dmesg é restrito a root no Pop!_OS (kernel.dmesg_restrict=1), então o bloco
#     de IOMMU/DMAR sairia VAZIO sem sudo (o manual traz esse comando sem sudo,
#     que é justamente onde ele falha).
# Pedindo a senha uma vez no começo, o relatório sai completo de primeira.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

verificar() {
    local inventario
    if resolver_ultimo_inventario >/dev/null && inventario="$INVENTARIO_RESOLVIDO" \
       && validar_inventario_principal "$inventario"; then
        v_ok "Último inventário completo: $inventario"
    else
        v_falta "${INVENTARIO_ERRO:-Nenhum inventário válido gerado ainda.}"
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

exigir_nao_root
exigir_sudo

titulo "Capítulo 3: Inventário de Hardware"
info "Finalidade: registrar CPU, RAM, firmware, PCI, discos e IOMMU para conferir as próximas etapas."
info "Pré-requisito: execute como usuário normal com acesso sudo e mantenha o hardware conectado."
aviso "Alterações: pode atualizar o índice APT e instalar dmidecode; grava um relatório datado em ~/inventario-hardware/."
info "A coleta não altera hardware, BIOS/UEFI, firmware, partições nem configuração dos dispositivos."
aviso "Risco: o relatório contém modelos, seriais e IDs do equipamento; guarde-o em local confiável."
info "Não exige reboot; ao terminar, volte ao menu para continuar."

# dmidecode pode não existir antes da etapa 12 (pacotes base); resolve aqui.
if ! command -v dmidecode >/dev/null 2>&1; then
    info "Instalando dmidecode (necessário para ler SMBIOS/DMI)..."
    sudo apt-get update -qq
    sudo apt-get install -y dmidecode
fi

DIRETORIO_INVENTARIO="$HOME/inventario-hardware"
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

{
    echo "== HARDWARE IDENTITY =="; normalizar_identidade_hardware_atual
    echo "== CPU ==";        LC_ALL=C lscpu
    echo "== RAM ==";        sudo dmidecode --type memory
    echo "== BASEBOARD =="; sudo dmidecode -t baseboard
    echo "== BIOS ==";       sudo dmidecode -t bios
    echo "== PCI ==";        LC_ALL=C lspci -Dnnk
    echo "== BLOCK DEVICES =="; LC_ALL=C lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL
    echo "== IOMMU/DMAR (pré-configuração) =="
    MENSAGENS_IOMMU="$(sudo dmesg | grep -i -e DMAR -e IOMMU || true)"
    printf '%s\n' "${MENSAGENS_IOMMU:-(vazio: normal antes da etapa 30)}"
} | tee "$TMP_INVENTARIO"

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
