#!/bin/bash
# ============================================================================
# etapas/00-inventario.sh - Capítulo 3: Inventário de Hardware
# ============================================================================
# Levanta a identificação completa do hardware e grava em um arquivo datado
# em ~/inventario-hardware/. Somente leitura: nada é alterado no sistema.
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
