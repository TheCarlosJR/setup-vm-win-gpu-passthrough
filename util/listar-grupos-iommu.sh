#!/bin/bash
SCRIPT_VERSION="1.0.0"
# ============================================================================
# util/listar-grupos-iommu.sh - inventário dos grupos IOMMU expostos no sysfs
# ============================================================================
# Somente leitura: enumera os dispositivos PCI de cada grupo e não decide se
# um grupo é adequado para passthrough.
# ============================================================================
echo "Finalidade: listar os membros dos grupos IOMMU atualmente expostos pelo kernel."
echo "Pré-requisitos: IOMMU habilitado no firmware e no kernel, reboot já concluído e pciutils/lspci instalado."
echo "Efeito: somente leitura; não vincula drivers, não altera a VM e não reinicia o host."
echo "Como ler: a função gráfica/3D da GPU e o áudio HDMI/DP costumam aparecer no mesmo grupo."
echo "Atenção: endpoints extras no grupo (USB, serial, bridge ou outro PCI) também devem ser identificados e avaliados."
echo "Risco: a listagem não aprova isolamento; não passe a GPU sem entender todos os membros do grupo."
echo "Não abrange: driver em uso, segurança ACS, capacidade de reset ou compatibilidade do hardware."
echo

for grupo in /sys/kernel/iommu_groups/*; do
    [ -e "$grupo" ] || { echo "Nenhum grupo IOMMU exposto; verifique firmware, parâmetros do kernel e se o reboot foi concluído."; exit 1; }
    numero_grupo="${grupo##*/}"                    # extrai apenas o numero do grupo
    for dispositivo in "$grupo"/devices/*; do
        endereco="${dispositivo##*/}"              # endereco PCI (ex.: 0000:0c:00.0)
        echo "Grupo IOMMU $numero_grupo: $(lspci -nns "${endereco#*:}")"
    done
done

echo
echo "Retorno/reboot: 0 apenas indica que a enumeração terminou; 1 indica ausência de grupos. Nenhum reboot é executado."
