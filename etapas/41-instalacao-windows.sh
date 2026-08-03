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

titulo "Antes de continuar"
info "Objetivo: concluir interativamente a instalação do Windows 11 e dos drivers VirtIO no disco virtual da etapa 40."
info "Pré-requisitos: VM e duas ISOs criadas/anexadas pela etapa 40; use o console gráfico e mantenha a rede NAT default até copiar os scripts iniciais."
info "Alterações: este script apenas consulta a VM, imprime o roteiro e pode abrir o console; o instalador e os guest tools gravam sempre no QCOW2, nunca no HD1 físico."
info "Destino obrigatório: ${QCOW2_PATH:-QCOW2 configurado na etapa 40}, com tamanho virtual ${QCOW2_TAMANHO:-configurado na etapa 40}."
info "Recomendação: selecione instalação Personalizada, carregue viostor e confira que o único destino é o QCOW2 antes de avançar."
aviso "Riscos: fechar o console não desfaz gravações; não force reset após haver dados importantes e nunca escolha, inicialize ou formate o HD1."
info "Retorno/reboot: o host não reinicia; o instalador e os guest tools reiniciam apenas a VM. Para voltar ao estado anterior, restaure um backup do QCOW2."
info "Se a VM estiver desligada, inicie-a com: virsh --connect qemu:///system start $VM_NAME"
info "Depois de iniciar, execute esta etapa novamente para abrir o console."

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
GUIA
printf ' 9. O QCOW2 de %s aparece: selecione-o e prossiga a instalação.\n' \
    "${QCOW2_TAMANHO:-tamanho configurado na etapa 40}"
cat <<'GUIA'
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

TRANSFERÊNCIA INICIAL DOS .ps1 (antes do airlock):
  1. Depois de instalar os guest tools, mantenha a NAT default da etapa 40.
  2. No host, em outro terminal aberto na raiz deste projeto, execute:
       HOST_NAT_IP="$(virsh --connect qemu:///system net-dumpxml default |
         xmlstarlet sel -t -v 'string(/network/ip[1]/@address)')"
       python3 -m http.server 8000 --bind "$HOST_NAT_IP" --directory windows
  3. No Windows, abra o PowerShell e copie os três scripts:
       $HostNAT = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' |
         Sort-Object RouteMetric | Select-Object -First 1).NextHop
       $Destino = "$HOME\Scripts-VM"
       New-Item -ItemType Directory -Force $Destino | Out-Null
       @('Desativar-Fast-Startup.ps1', 'Ativar-MSI-GPU.ps1',
         'Gerar-Chave-Airlock.ps1') | ForEach-Object {
           Invoke-WebRequest "http://${HostNAT}:8000/$_" -OutFile "$Destino\$_"
       }
  4. Confira os arquivos, encerre o servidor no host com Ctrl+C e deixe o
     Defender verificá-los. Execute cada .ps1 somente na etapa indicada.

O disco HD1 físico só é anexado na etapa 50, DEPOIS da instalação do Windows
no QCOW2. Nunca selecione o HD1 físico como destino do instalador.

PERDA DE DADOS: quando anexado, o Windows terá escrita no disco físico inteiro.
O script não o formata. Se estiver em branco, GPT + NTFS pode ser criado no
Gerenciamento de Disco; se JÁ TEM dados, NÃO inicialize, reparticione ou formate.
Antes de qualquer alteração, confira tamanho/modelo e mantenha backup verificado.
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
