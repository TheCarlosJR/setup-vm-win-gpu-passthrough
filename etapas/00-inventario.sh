#!/bin/bash
# ============================================================================
# etapas/00-inventario.sh - Capítulo 3: Inventário de Hardware
# ============================================================================
# Levanta a identificação completa do hardware e grava em um arquivo datado.
# Não instala pacotes nem altera configurações do host; cria somente o relatório
# prometido em ~/inventario-hardware/.
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

mkdir -p "$HOME/inventario-hardware"
ARQUIVO="$HOME/inventario-hardware/inventario-$(date +%Y%m%d).txt"
DMIDECODE_AUSENTE="(indisponível: dmidecode ausente; execute etapas/12-pacotes-base.sh e gere novamente o inventário)"

{
    echo "== CPU =="
    if command -v lscpu >/dev/null 2>&1; then
        lscpu 2>&1 || echo "(indisponível: falha ao executar lscpu)"
    else
        echo "(indisponível: comando lscpu ausente)"
    fi

    echo "== RAM =="
    if command -v dmidecode >/dev/null 2>&1; then
        sudo dmidecode --type memory 2>&1 || echo "(indisponível: falha ao executar dmidecode)"
    else
        echo "$DMIDECODE_AUSENTE"
    fi

    echo "== BASEBOARD =="
    if command -v dmidecode >/dev/null 2>&1; then
        sudo dmidecode -t baseboard 2>&1 || echo "(indisponível: falha ao executar dmidecode)"
    else
        echo "$DMIDECODE_AUSENTE"
    fi

    echo "== BIOS =="
    if command -v dmidecode >/dev/null 2>&1; then
        sudo dmidecode -t bios 2>&1 || echo "(indisponível: falha ao executar dmidecode)"
    else
        echo "$DMIDECODE_AUSENTE"
    fi

    echo "== PCI =="
    if command -v lspci >/dev/null 2>&1; then
        lspci -nnk 2>&1 || echo "(indisponível: falha ao executar lspci)"
    else
        echo "(indisponível: lspci ausente; execute etapas/12-pacotes-base.sh e gere novamente o inventário)"
    fi

    echo "== BLOCK DEVICES =="
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL 2>&1 \
            || echo "(indisponível: falha ao executar lsblk)"
    else
        echo "(indisponível: comando lsblk ausente)"
    fi

    echo "== IOMMU/DMAR (pré-configuração) =="
    if command -v dmesg >/dev/null 2>&1; then
        if SAIDA_DMESG="$(sudo dmesg 2>&1)"; then
            grep -i -e DMAR -e IOMMU <<< "$SAIDA_DMESG" \
                || echo "(vazio: normal antes da etapa 30)"
        else
            echo "$SAIDA_DMESG"
            echo "(indisponível: não foi possível ler dmesg)"
        fi
    else
        echo "(indisponível: comando dmesg ausente)"
    fi
} | tee "$ARQUIVO"

echo
ok "Inventário salvo em: $ARQUIVO"
info "Confira na seção PCI as duas linhas NVIDIA (VGA e Audio) no mesmo barramento (ex.: 0c:00.x)."
info "Recomendação do manual: guarde uma cópia deste arquivo FORA do disco do sistema."
