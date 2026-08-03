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
    if ls "$HOME"/inventario-hardware/inventario-*.txt >/dev/null 2>&1; then
        v_ok "Inventário encontrado em ~/inventario-hardware/"
    else
        v_falta "Nenhum inventário gerado ainda."
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

mkdir -p "$HOME/inventario-hardware"
ARQUIVO="$HOME/inventario-hardware/inventario-$(date +%Y%m%d).txt"

{
    echo "== CPU ==";        lscpu
    echo "== RAM ==";        sudo dmidecode --type memory
    echo "== BASEBOARD =="; sudo dmidecode -t baseboard
    echo "== BIOS ==";       sudo dmidecode -t bios
    echo "== PCI ==";        lspci -nnk
    echo "== BLOCK DEVICES =="; lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL
    echo "== IOMMU/DMAR (pré-configuração) =="; sudo dmesg | grep -i -e DMAR -e IOMMU || echo "(vazio: normal antes da etapa 30)"
} | tee "$ARQUIVO"

echo
ok "Inventário salvo em: $ARQUIVO"
info "Confira na seção PCI as duas linhas NVIDIA (VGA e Audio) no mesmo barramento (ex.: 0c:00.x)."
info "Recomendação do manual: guarde uma cópia deste arquivo FORA do disco do sistema."
