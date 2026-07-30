#!/bin/bash
# ============================================================================
# util/listar-grupos-iommu.sh - Capítulo 16
# Lista todos os dispositivos PCI agrupados por grupo IOMMU.
# Só produz saída útil DEPOIS da etapa 30 (amd_iommu=on) + reboot.
# ============================================================================
for grupo in /sys/kernel/iommu_groups/*; do
    [ -e "$grupo" ] || { echo "Nenhum grupo IOMMU (IOMMU inativo: rode a etapa 30 e reinicie)."; exit 1; }
    numero_grupo="${grupo##*/}"                    # extrai apenas o numero do grupo
    for dispositivo in "$grupo"/devices/*; do
        endereco="${dispositivo##*/}"              # endereco PCI (ex.: 0000:0c:00.0)
        echo "Grupo IOMMU $numero_grupo: $(lspci -nns "${endereco#*:}")"
    done
done
