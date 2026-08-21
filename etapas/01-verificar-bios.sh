#!/bin/bash
# ============================================================================
# etapas/01-verificar-bios.sh - Etapa 2: Configuração da BIOS/UEFI
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
        v_ok "Sistema inicializado em modo UEFI."
    else
        v_falta "Sistema em Legacy/BIOS: confirme ou converta a instalação para UEFI antes de desativar o CSM."
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

titulo "Etapa 2: BIOS/UEFI (ASUS TUF Gaming B550-Plus WiFi II)"
info "Finalidade: orientar a configuração manual da virtualização e verificar do Linux o que for observável."
info "Pré-requisitos: acesso à BIOS/UEFI, senha sudo e registro dos valores atuais antes de alterá-los."
info "Este script apenas orienta e lê o estado atual; não modifica nem reinicia a BIOS/UEFI."
aviso "Os caminhos ASUS abaixo são referências: nomes e posições variam conforme placa e versão do firmware."
aviso "RISCO: se o Linux foi instalado em Legacy, desativar o CSM pode impedir a inicialização do host."
info "Recomendação: confirme ou converta o boot do Linux para UEFI antes de desativar o CSM."

cat <<'CHECKLIST'
Esta etapa é MANUAL. Reinicie, pressione Del durante o logotipo ASUS,
entre no Advanced Mode (F7) e localize as opções equivalentes:

  | Opção                  | Menu (referência ASUS)                               | Valor final |
  |------------------------|------------------------------------------------------|-------------|
  | SVM Mode               | Advanced > CPU Configuration (ou AMD CBS > CPU ...)  | Enabled     |
  | IOMMU                  | Advanced > AMD CBS > NBIO Common Options             | Enabled     |
  | Above 4G Decoding      | Advanced > PCI Subsystem Settings                    | Enabled     |
  | Re-Size BAR Support    | Advanced > PCI Subsystem Settings                    | Enabled     |
  | CSM                    | Boot                                                 | Disabled    |
  | Secure Boot > OS Type  | Boot > Secure Boot                                   | Other OS    |

Salve com F10 (Save Changes and Reset). O firmware reiniciará o host; quando o
Linux voltar, execute esta etapa novamente para validar e depois retorne ao menu.

Observações do manual:
  - Nomes de menu variam entre versões de firmware; procure termos similares.
  - Re-Size BAR: manter Enabled; é um dos primeiros itens a testar Desabilitado
    caso apareça instabilidade ou "Code 43" (consulte troubleshooting.md).
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
    aviso "Modo Legacy/BIOS: não desative o CSM antes de converter ou reinstalar o boot do Linux em UEFI."
fi

echo "3) Mensagens AMD-Vi/IOMMU no kernel:"
DMESG_KERNEL="$(sudo dmesg)" || falhar "Não foi possível ler o dmesg."
IOMMU_LOG="$(awk 'tolower($0) ~ /(amd-vi|iommu)/ && exibidas < 10 { print; exibidas++ }' <<< "$DMESG_KERNEL")"
if [ -n "$IOMMU_LOG" ]; then
    printf '%s\n' "$IOMMU_LOG"
else
    info "(vazio: normal ANTES da etapa 11, que aplica amd_iommu=on ao kernel)"
fi

echo "4) Secure Boot:"
SECURE_BOOT_LOG="$(awk 'tolower($0) ~ /secure boot/ && exibidas < 3 { print; exibidas++ }' <<< "$DMESG_KERNEL")"
if [ -n "$SECURE_BOOT_LOG" ]; then
    printf '%s\n' "$SECURE_BOOT_LOG"
else
    info "(kernel não reportou estado de Secure Boot; verifique na própria BIOS)"
fi

echo
info "Se algo acima falhou, ajuste a BIOS, salve e aguarde o reboot; então rode este script novamente."
info "Se tudo estiver correto, volte ao menu. Este script não reinicia o host por conta própria."
