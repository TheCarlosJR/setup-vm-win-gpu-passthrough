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

guard_mutation domain.console || exit 1
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

GUIA

# ---------------------------------------------------------------------------
# Dados reais da NAT default, usados no roteiro de transferência dos .ps1.
# LC_ALL=C é obrigatório: em um host com locale pt_BR o rótulo de net-info sai
# como "Ponte:", o filtro por "Bridge:" devolve vazio e o comando manual antigo
# terminava em 'Device "" does not exist' seguido de socket.gaierror no
# http.server. Aqui a bridge e o IP já saem resolvidos para o usuário copiar.
# ---------------------------------------------------------------------------
BRIDGE_NAT="$(LC_ALL=C $VIRSH net-info default 2>/dev/null \
    | awk '/^Bridge:/ {print $2; exit}')" || BRIDGE_NAT=""
HOST_NAT_IP=""
if [ -n "$BRIDGE_NAT" ]; then
    HOST_NAT_IP="$(ip -4 -o addr show "$BRIDGE_NAT" 2>/dev/null \
        | awk '{split($4, campo, "/"); print campo[1]; exit}')" || HOST_NAT_IP=""
fi

cat <<'GUIA'

PÓS-INSTALAÇÃO, NA ORDEM (a VM continua na NAT default da etapa 40):

12. Copie os três .ps1 do host para a VM (veja "COMO COPIAR OS TRÊS .ps1"
    logo abaixo). Copiar não é executar: cada script só roda na etapa dele.

13. Desative a Inicialização Rápida (Fast Startup) agora, e só ela:
      - PowerShell como Administrador:
        
        .\Desativar-Fast-Startup.ps1
        
        OU
        
        powershell.exe -ExecutionPolicy Bypass -File ".\Desativar-Fast-Startup.ps1"
        
        OU

        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
        .\Desativar-Fast-Startup.ps1

      - ou Painel de Controle > Opções de Energia > "Escolher a função dos
        botões de energia" > "Alterar configurações não disponíveis
        atualmente" > desmarcar "Ligar inicialização rápida".

    Por quê: com Fast Startup, "Desligar" deixa o Windows/NTFS parcialmente
    hibernado, e a partir da etapa 50 o host não consegue tratar o HD1 como
    desligado de verdade. Depois de aplicar, faça um desligamento completo da
    VM pelo menos uma vez.

14. Windows Defender: mantenha a proteção em tempo real ATIVA, não instale
    antivírus de terceiros e NUNCA exclua a pasta do airlock da verificação
    (é exatamente ela que recebe arquivos vindos do host).

15. NÃO instale o driver NVIDIA ainda. Até a etapa 50 a VM só tem a QXL
    emulada. Depois do passthrough da GPU real, baixe de nvidia.com/drivers e
    use a opção "Instalação limpa".

QUANDO CADA .ps1 É USADO (não execute fora de hora):

  Desativar-Fast-Startup.ps1  agora, no passo 13, como Administrador.
  Ativar-MSI-GPU.ps1          etapa 53 (CPU isolation), como Administrador e
                              somente após o driver NVIDIA estar instalado.
  Gerar-Chave-Airlock.ps1     etapa 61 (airlock), com o usuário comum do
                              Windows que vai usar o WinSCP; NÃO como
                              Administrador, senão a chave nasce no perfil
                              errado.

COMO COPIAR OS TRÊS .ps1 DO HOST PARA A VM
GUIA
printf 'Os arquivos estão no host em: %s/windows\n' "$PROJETO_DIR"
cat <<'GUIA'

Opção A
Arrastar e soltar (mais simples, sem rede e sem firewall):

  Os guest tools do passo 11 instalam o spice-vdagent, que é o que habilita
  arrastar arquivos e o copiar/colar de texto entre host e VM.
  1. Reinicie a VM depois dos guest tools e abra o console gráfico
     (virt-manager > a VM > Exibir > Console).
  2. Abra a pasta windows do projeto no gerenciador de arquivos do host,
     selecione os três .ps1 e arraste-os para dentro da janela do console.
  3. Uma barra de progresso de transferência aparece e os arquivos chegam na
     pasta padrão do usuário Windows (Downloads ou Área de Trabalho,
     conforme a versão do vdagent). Mova-os para %USERPROFILE%\Scripts-VM.
  Se nada acontecer ao soltar, o vdagent não está rodando: confira o serviço
  "Spice VDAgent" em services.msc dentro do Windows, ou use a opção B.

Opção B
Servidor HTTP temporário na NAT default:

GUIA
if [ -n "$HOST_NAT_IP" ]; then
    printf '  1. No host, em OUTRO terminal, suba o servidor e deixe rodando:\n'
    printf "       python3 -m http.server 8000 --bind %s --directory '%s/windows'\n" \
        "$HOST_NAT_IP" "$PROJETO_DIR"
else
    aviso "Não foi possível resolver o IP do host na rede 'default' (ela está ativa?)."
    info  "Verifique com: LC_ALL=C $VIRSH net-info default   e   ip -4 -o addr show <bridge>"
    printf '  1. No host, em OUTRO terminal, com <IP> = IP do host na bridge da NAT:\n'
    printf "       python3 -m http.server 8000 --bind <IP> --directory '%s/windows'\n" \
        "$PROJETO_DIR"
fi
if systemctl is-active --quiet ufw 2>/dev/null; then
    printf '  2. O ufw está ativo neste host: libere a porta apenas na bridge da VM:\n'
    printf '       sudo ufw allow in on %s to any port 8000 proto tcp\n' \
        "${BRIDGE_NAT:-virbr0}"
else
    printf '  2. Sem ufw ativo aqui; se o download falhar, o firewall do host é o\n'
    printf '     primeiro suspeito (a porta 8000 precisa aceitar tráfego da %s).\n' \
        "${BRIDGE_NAT:-bridge da NAT}"
fi
cat <<'GUIA'
  3. No Windows, no PowerShell (usuário comum basta):
       $HostNAT = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' |
         Sort-Object RouteMetric | Select-Object -First 1).NextHop
       $Destino = "$HOME\Scripts-VM"
       New-Item -ItemType Directory -Force $Destino | Out-Null
       @('Desativar-Fast-Startup.ps1', 'Ativar-MSI-GPU.ps1',
         'Gerar-Chave-Airlock.ps1') | ForEach-Object {
           Invoke-WebRequest "http://${HostNAT}:8000/$_" -OutFile "$Destino\$_"
       }
       Get-ChildItem $Destino
GUIA
if [ -n "$HOST_NAT_IP" ]; then
    printf '     $HostNAT tem de imprimir %s. Se imprimir outro valor, a VM já não\n' \
        "$HOST_NAT_IP"
    printf '     está na NAT default: devolva a rede para "default" antes de insistir.\n'
fi
printf '  4. Encerre o servidor no host com Ctrl+C'
if systemctl is-active --quiet ufw 2>/dev/null; then
    printf ' e remova a liberação:\n'
    printf '       sudo ufw delete allow in on %s to any port 8000 proto tcp\n' \
        "${BRIDGE_NAT:-virbr0}"
else
    printf '.\n'
fi
cat <<'GUIA'
  5. Deixe o Defender verificar os arquivos e leia o conteúdo de cada .ps1
     antes de executá-lo. Nenhum deles precisa de rede para funcionar.

GUIA
cat <<'GUIA'
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
