#!/bin/bash
# ============================================================================
# etapas/41-instalacao-windows.sh - Capítulo 18: Instalação do Windows 11
# ============================================================================
# A instalação é interativa (console gráfico). Este script imprime o passo a
# passo exato do manual, abre o console se desejado e verifica ao final a
# comunicação com o qemu-guest-agent.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

verificar() {
    [ -n "${VM_NAME:-}" ] || { v_falta "VM_NAME não definido."; v_fim; }
    if ! vm_existe "$VM_NAME"; then
        v_falta "VM '$VM_NAME' não existe (etapa 40)."
        v_fim
    fi
    if $VIRSH qemu-agent-command "$VM_NAME" '{"execute":"guest-ping"}' >/dev/null 2>&1; then
        v_ok "qemu-guest-agent respondendo (Windows instalado com guest tools)."
    else
        v_falta "guest-agent sem resposta (Windows/guest-tools pendentes ou VM desligada)."
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

exigir_conf VM_NAME
titulo "Capítulo 18: Instalação do Windows 11 (interativa)"
info "Estado atual da VM: $($VIRSH domstate "$VM_NAME" 2>/dev/null || echo 'inexistente')"

cat <<'GUIA'
PASSO A PASSO (dentro do console gráfico da VM):

 1. Boot pela ISO: pressione uma tecla em "Press any key to boot from CD".
 2. Idioma/teclado > Avançar > "Instalar agora".
 3. Chave de produto: insira, ou "Não tenho uma chave de produto".
 4. Escolha a edição (Home/Pro) e aceite os termos.
 5. "Personalizada: instalar somente o Windows (avançado)".
 6. A lista de discos estará VAZIA: é o esperado (driver VirtIO ausente).
 7. Clique em "Carregar driver" > "Procurar" > unidade do CD virtio-win >
        viostor\w11\amd64
    (use vioscsi\w11\amd64 apenas se o disco foi configurado como virtio-scsi)
 8. Selecione "Red Hat VirtIO SCSI controller" > Avançar.
 9. O disco de 250 GB aparece: selecione e prossiga a instalação.
10. Se o instalador exigir rede/conta Microsoft: "Carregar driver" novamente em
        NetKVM\w11\amd64
11. Ao chegar na área de trabalho, ainda com a virtio-win.iso anexada:
    executar virtio-win-guest-tools.exe (raiz da ISO) e reiniciar.

PÓS-INSTALAÇÃO (desenho de segurança do manual):
  - Windows Defender: manter proteção em tempo real ATIVA; não instalar
    antivírus de terceiros; NUNCA excluir a pasta airlock da verificação.
  - Desativar a Inicialização Rápida (Fast Startup):
    use windows/Desativar-Fast-Startup.ps1 (PowerShell como administrador)
    ou Painel de Controle > Opções de Energia.
  - O driver NVIDIA dentro da VM só é instalado APÓS a etapa 50
    (quando a GPU real estiver em passthrough): baixar de nvidia.com/drivers,
    opção "Instalação limpa".

O disco HD1 físico é anexado na etapa 50; o particionamento dele (se estiver
em branco) é feito no Gerenciamento de Disco do Windows: GPT + NTFS.
Se o HD1 JÁ TEM dados: NÃO formate; ele aparece pronto com letra de unidade.
GUIA

if vm_existe "$VM_NAME" && ! vm_desligada "$VM_NAME"; then
    if confirmar "Abrir o console gráfico agora?"; then
        nohup virt-manager --connect qemu:///system --show-domain-console "$VM_NAME" >/dev/null 2>&1 &
    fi
fi

echo
titulo "Verificação (quando o Windows + guest tools estiverem instalados)"
if $VIRSH qemu-agent-command "$VM_NAME" '{"execute":"guest-ping"}' >/dev/null 2>&1; then
    ok "guest-agent OK: {\"return\":{}}"
    info "Dentro do Windows, confirme também: Get-Disk  e  Get-Service QEMU-GA"
else
    info "guest-agent ainda sem resposta. Normal antes de instalar o virtio-win-guest-tools."
    info "Rode '41-instalacao-windows.sh --verificar' depois da instalação."
fi
