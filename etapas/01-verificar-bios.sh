#!/bin/bash
# ============================================================================
# etapas/01-verificar-bios.sh - Capítulo 12: Configuração da BIOS/UEFI
# ============================================================================
# A configuração da BIOS é MANUAL (feita na interface do firmware ASUS).
# Este script:
#   1. Mostra o checklist exato do manual (o que mudar e onde).
#   2. Verifica, pelo lado do Linux, tudo o que é verificável por comando.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

verificar() {
    if lscpu | grep -qiw svm; then
        v_ok "Flag 'svm' presente na CPU."
    else
        v_falta "Flag 'svm' ausente: habilite SVM Mode na BIOS."
    fi
    if [ -d /sys/firmware/efi ]; then
        v_ok "Sistema inicializado em modo UEFI (CSM desabilitado)."
    else
        v_falta "Sistema em modo Legacy/BIOS: desabilite o CSM na BIOS."
    fi
    if [ -e /dev/kvm ]; then
        v_ok "/dev/kvm existe (SVM ativo e módulo KVM carregado)."
    else
        v_falta "/dev/kvm ausente (SVM desabilitado na BIOS ou pilha KVM ainda não instalada)."
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

exigir_nao_root
exigir_sudo

titulo "Capítulo 12: BIOS/UEFI (ASUS TUF Gaming B550-Plus WiFi II)"

cat <<'CHECKLIST'
Esta etapa é MANUAL. Reinicie, pressione Del durante o logotipo ASUS,
entre no Advanced Mode (F7) e aplique a tabela-resumo do manual:

  | Opção                  | Menu (típico)                                        | Valor final |
  |------------------------|------------------------------------------------------|-------------|
  | SVM Mode               | Advanced > CPU Configuration (ou AMD CBS > CPU ...)  | Enabled     |
  | IOMMU                  | Advanced > AMD CBS > NBIO Common Options             | Enabled     |
  | Above 4G Decoding      | Advanced > PCI Subsystem Settings                    | Enabled     |
  | Re-Size BAR Support    | Advanced > PCI Subsystem Settings                    | Enabled     |
  | CSM                    | Boot                                                 | Disabled    |
  | Secure Boot > OS Type  | Boot > Secure Boot                                   | Other OS    |

Salve com F10 (Save Changes and Reset).

Observações do manual:
  - Nomes de menu variam entre versões de firmware; procure termos similares.
  - Re-Size BAR: manter Enabled; é um dos primeiros itens a testar Desabilitado
    caso apareça instabilidade ou "Code 43" (Capítulo 28).
  - Secure Boot do HOST desabilitado é decisão documentada (a VM tem o próprio
    Secure Boot via OVMF).
CHECKLIST

echo
titulo "Verificação (lado Linux)"

echo "1) Flag SVM na CPU:"
if lscpu | grep -iw svm >/dev/null; then
    ok "svm presente."
else
    aviso "svm ausente: habilite SVM Mode na BIOS."
fi

echo "2) Modo de firmware:"
if [ -d /sys/firmware/efi ]; then
    ok "Modo UEFI."
else
    aviso "Modo Legacy/BIOS: desabilite o CSM (e revise o Capítulo 6 se o SO foi instalado em Legacy)."
fi

echo "3) Mensagens AMD-Vi/IOMMU no kernel:"
if sudo dmesg | grep -i -e "AMD-Vi" -e "IOMMU" | head -n 10 | grep -q .; then
    sudo dmesg | grep -i -e "AMD-Vi" -e "IOMMU" | head -n 10
else
    info "(vazio: normal ANTES da etapa 30, que aplica amd_iommu=on ao kernel)"
fi

echo "4) Secure Boot:"
if sudo dmesg | grep -i "secure boot" | head -n 3 | grep -q .; then
    sudo dmesg | grep -i "secure boot" | head -n 3
else
    info "(kernel não reportou estado de Secure Boot; verifique na própria BIOS)"
fi

echo
info "Se algo acima falhou, ajuste a BIOS e rode este script novamente."
