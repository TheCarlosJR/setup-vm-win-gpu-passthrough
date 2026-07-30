#!/bin/bash
# ============================================================================
# util/listar-grupos-iommu.sh - Capítulo 16
# Lista todos os dispositivos PCI agrupados por grupo IOMMU.
# Só produz saída útil DEPOIS da etapa 30 (amd_iommu=on) + reboot.
# ============================================================================
set -uo pipefail

command -v lspci >/dev/null 2>&1 \
    || { echo "Erro: lspci não encontrado (execute a etapa 12)." >&2; exit 1; }

shopt -s nullglob
grupos=(/sys/kernel/iommu_groups/*)
if [ "${#grupos[@]}" -eq 0 ]; then
    echo "Nenhum grupo IOMMU encontrado. Rode a etapa 30 e reinicie." >&2
    exit 1
fi

falhas=0
for grupo in "${grupos[@]}"; do
    [ -d "$grupo" ] || continue
    numero_grupo="${grupo##*/}"
    dispositivos=("$grupo"/devices/*)
    if [ "${#dispositivos[@]}" -eq 0 ]; then
        echo "Grupo IOMMU $numero_grupo: (sem dispositivos)" >&2
        falhas=1
        continue
    fi

    for dispositivo in "${dispositivos[@]}"; do
        endereco="${dispositivo##*/}"
        if descricao="$(LC_ALL=C lspci -nns "${endereco#0000:}" 2>&1)"; then
            echo "Grupo IOMMU $numero_grupo: $descricao"
        else
            echo "Grupo IOMMU $numero_grupo: $endereco (lspci falhou: $descricao)" >&2
            falhas=1
        fi
    done
done

exit "$falhas"
