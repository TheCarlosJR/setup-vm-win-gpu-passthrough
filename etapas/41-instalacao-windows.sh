#!/bin/bash
# ============================================================================
# etapas/41-instalacao-windows.sh - Capítulo 18: Instalação do Windows 11
# ============================================================================
# A instalação é interativa (console gráfico). Este script imprime o passo a
# passo exato do manual, abre o console se desejado e usa a comunicação com o
# qemu-guest-agent apenas como indicador de acessibilidade do guest.
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
        v_ok "qemu-guest-agent acessível."
        info "A resposta é apenas um indicador de acesso; não comprova a instalação completa do Windows."
    else
        v_falta "guest-agent sem resposta (guest tools pendentes, VM desligada ou guest inacessível)."
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

consultar_estado_vm() {
    LC_ALL=C $VIRSH domstate "$1" 2>/dev/null
}

oferecer_console() {
    if confirmar "Abrir o console gráfico agora?"; then
        exigir_comando virt-manager
        nohup virt-manager --connect qemu:///system --show-domain-console "$VM_NAME" >/dev/null 2>&1 &
    fi
}

exigir_conf VM_NAME
vm_existe "$VM_NAME" || falhar "VM '$VM_NAME' não existe. Execute a etapa 40 antes."
if ! ESTADO_VM="$(consultar_estado_vm "$VM_NAME")"; then
    falhar "Não foi possível consultar o estado da VM '$VM_NAME'."
fi
case "$ESTADO_VM" in
    "shut off"|running)
        ;;
    *)
        falhar "Estado não suportado para instalação interativa: '$ESTADO_VM'. Deixe a VM running ou shut off."
        ;;
esac

titulo "Capítulo 18: Instalação do Windows 11 (interativa)"
info "Estado atual da VM: $ESTADO_VM"

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

case "$ESTADO_VM" in
    "shut off")
        if confirmar "A VM está desligada. Iniciar agora?"; then
            $VIRSH start "$VM_NAME" || falhar "Não foi possível iniciar a VM '$VM_NAME'."
            if ! ESTADO_VM="$(consultar_estado_vm "$VM_NAME")"; then
                falhar "A VM foi iniciada, mas seu novo estado não pôde ser consultado."
            fi
            [ "$ESTADO_VM" = "running" ] \
                || falhar "Após o start, a VM entrou no estado inesperado '$ESTADO_VM'."
            oferecer_console
        else
            info "VM mantida desligada; inicie-a quando estiver pronto para instalar."
        fi
        ;;
    running)
        oferecer_console
        ;;
esac

echo
titulo "Verificação (quando o Windows + guest tools estiverem instalados)"
if $VIRSH qemu-agent-command "$VM_NAME" '{"execute":"guest-ping"}' >/dev/null 2>&1; then
    ok "qemu-guest-agent acessível: {\"return\":{}}"
    aviso "Este ping confirma acessibilidade do agente, não a instalação completa do Windows."
    info "Dentro do Windows, confirme também: Get-Disk  e  Get-Service QEMU-GA"
else
    info "guest-agent ainda sem resposta. Normal antes de instalar o virtio-win-guest-tools."
    info "Rode '41-instalacao-windows.sh --verificar' depois da instalação."
fi
