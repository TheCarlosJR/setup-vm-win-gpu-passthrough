#!/bin/bash
# ============================================================================
# etapas/41-instalacao-windows.sh - Etapa 13: instalação e pós-instalação do
# Windows 11 na VM
# ============================================================================
# A instalação é interativa (console gráfico). Este script imprime o passo a
# passo numerado (13.1, 13.2, ...), abre o console se desejado e verifica ao
# final a comunicação com o qemu-guest-agent.
#
# Os sub-passos 13.1 a 13.11 são a instalação; 13.12 a 13.17 são a
# pós-instalação, incluindo o driver NVIDIA dentro da VM, que só entra depois
# de a etapa 14 (hooks da GPU) estar aplicada.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

verificar() {
    [ -n "${VM_NAME:-}" ] || { v_falta "VM_NAME não definido."; v_fim; }
    if ! vm_existe "$VM_NAME"; then
        v_falta "VM '$VM_NAME' não existe (etapa 12)."
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
titulo "Etapa 13: instalação e pós-instalação do Windows 11 (interativa)"
info "Estado atual da VM: $($VIRSH domstate "$VM_NAME" 2>/dev/null || echo 'inexistente')"

titulo "Antes de continuar"
info "Objetivo: concluir interativamente a instalação do Windows 11, dos drivers VirtIO e da pós-instalação no disco virtual da etapa 12."
info "Pré-requisitos: VM e duas ISOs criadas/anexadas pela etapa 12; use o console gráfico e mantenha a rede NAT default até copiar os scripts iniciais."
info "Alterações: este script apenas consulta a VM, imprime o roteiro e pode abrir o console; o instalador e os guest tools gravam sempre no QCOW2, nunca no HD1 físico."
info "Destino obrigatório: ${QCOW2_PATH:-QCOW2 configurado na etapa 12}, com tamanho virtual ${QCOW2_TAMANHO:-configurado na etapa 12}."
info "Recomendação: selecione instalação Personalizada, carregue viostor e confira que o único destino é o QCOW2 antes de avançar."
aviso "Riscos: fechar o console não desfaz gravações; não force reset após haver dados importantes e nunca escolha, inicialize ou formate o HD1."
info "Retorno/reboot: o host não reinicia; o instalador e os guest tools reiniciam apenas a VM. Para voltar ao estado anterior, restaure um backup do QCOW2."
info "Se a VM estiver desligada, inicie-a com: virsh --connect qemu:///system start $VM_NAME"
info "Depois de iniciar, execute esta etapa novamente para abrir o console."

cat <<'GUIA'
INSTALAÇÃO (13.1 a 13.11, dentro do console gráfico da VM):

 13.1. Boot pela ISO: pressione uma tecla em "Press any key to boot from CD".
 13.2. Idioma/teclado > Avançar > "Instalar agora".
 13.3. Chave de produto: insira, ou "Não tenho uma chave de produto".
 13.4. Escolha a edição (Home/Pro) e aceite os termos.
 13.5. "Personalizada: instalar somente o Windows (avançado)".
 13.6. A lista de discos estará VAZIA: é o esperado (driver VirtIO ausente).
 13.7. Clique em "Carregar driver" > "Procurar" > unidade do CD virtio-win >
           viostor\w11\amd64
       (use vioscsi\w11\amd64 apenas se o disco foi configurado como virtio-scsi)
 13.8. Selecione "Red Hat VirtIO SCSI controller" > Avançar.
GUIA
printf ' 13.9. O QCOW2 de %s aparece: selecione-o e prossiga a instalação.\n' \
    "${QCOW2_TAMANHO:-tamanho configurado na etapa 12}"
cat <<'GUIA'
13.10. Se o instalador exigir rede/conta Microsoft: "Carregar driver" novamente
       em NetKVM\w11\amd64
13.11. Ao chegar na área de trabalho, ainda com a virtio-win.iso anexada:
       executar virtio-win-guest-tools.exe (raiz da ISO) e reiniciar a VM.

       Isso instala de uma vez o qemu-guest-agent (desligamento gracioso e
       verificação desta etapa) e o spice-vdagent (arrastar arquivos e
       copiar/colar entre host e VM, usado no 13.12).

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

PÓS-INSTALAÇÃO (13.12 a 13.17, na ordem; a VM continua na NAT default da
etapa 12):

13.12. Copie os três .ps1 do host para a VM (veja "COMO COPIAR OS TRÊS .ps1"
       logo abaixo). Copiar não é executar: cada script só roda no passo dele.

13.13. Desative a Inicialização Rápida (Fast Startup) agora, e só ela:
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
       hibernado, e a partir da etapa 14 o host não consegue tratar o HD1 como
       desligado de verdade. Depois de aplicar, faça um desligamento completo
       da VM pelo menos uma vez.

13.14. Confirme que a etapa 14 (hooks da GPU e HD1 físico) já está aplicada
       antes de seguir para o 13.15. No host:
GUIA
printf '\n         bash menu.sh --status        # a etapa 14 precisa estar [ok]\n'
printf '         virsh --connect qemu:///system dumpxml %s | grep -c hostdev\n\n' \
    "$VM_NAME"
cat <<'GUIA'
       Enquanto a etapa 14 não estiver aplicada, a VM só tem a QXL emulada e
       NÃO existe GPU real para instalar driver: pular direto ao 13.15 instala
       um driver sem hardware correspondente.

       Prepare também como você vai ver e controlar a VM a partir daqui: o
       hook da etapa 14 para o gerenciador de login do host (DM_SERVICE) e
       entrega a GPU ao vfio-pci, então o console SPICE do virt-manager deixa
       de existir junto com a sessão gráfica do host. Antes do primeiro boot
       com a GPU passada, garanta um monitor ligado na GPU da VM e teclado e
       mouse dedicados via etapa 15 (USB passthrough); sem isso você fica sem
       imagem e sem teclado dentro do Windows.

13.15. Instale o driver NVIDIA DENTRO da VM (somente com a etapa 14 aplicada):

       a) Desligue a VM completamente pelo próprio Windows (não use "reiniciar"
          nem force reset) e inicie-a novamente para que a GPU real entre.
       b) No Windows, abra o Gerenciador de Dispositivos: a GPU aparece em
          "Adaptadores de vídeo". Um "Código 43" ou "Dispositivo de vídeo
          básico" neste momento é o esperado, é exatamente a falta do driver.
       c) Baixe o driver apenas de https://www.nvidia.com/Download/index.aspx
          escolhendo o modelo da GPU passada e Windows 11 64-bit. Prefira o
          pacote "Game Ready" ou "Studio" conforme o uso; NÃO use driver
          empacotado por terceiros.
       d) Execute o instalador, escolha "Personalizada (Avançado)" e marque
          "Executar uma instalação limpa". Instalar apenas "Driver gráfico" e
          "Áudio HD" é suficiente; o GeForce Experience é dispensável.
       e) Reinicie a VM ao final e confirme:
            - Gerenciador de Dispositivos sem "Código 43" e sem alerta;
            - a saída de vídeo pelo monitor ligado na GPU passada;
            - no PowerShell: nvidia-smi   (deve listar a GPU e o driver).
       f) Só depois de o driver estar funcionando é que o Ativar-MSI-GPU.ps1
          faz sentido: ele é o passo da etapa 17 (CPU isolation).

       Se o "Código 43" persistir depois do driver, o problema é do lado do
       host (vinculação ao vfio-pci, ROM/UEFI da GPU ou o Fast Startup do
       13.13 ainda ativo), não do driver: consulte troubleshooting.md antes de
       reinstalar.

13.16. Desligue a VM completamente uma vez, pelo Windows, e confirme no host
       que o desktop volta sozinho (é o hook release/end da etapa 14 devolvendo
       a GPU e religando o gerenciador de login).

13.17. Só então prossiga para as etapas 15 a 20 pelo menu. O
       Gerar-Chave-Airlock.ps1 é o passo da etapa 19 (airlock) e não deve ser
       executado antes dela.

QUANDO CADA .ps1 É USADO (não execute fora de hora):

  Desativar-Fast-Startup.ps1  agora, no 13.13, como Administrador.
  Ativar-MSI-GPU.ps1          etapa 17 (CPU isolation), como Administrador e
                              somente após o driver NVIDIA do 13.15 estar
                              instalado e funcionando.
  Gerar-Chave-Airlock.ps1     etapa 19 (airlock), com o usuário comum do
                              Windows que vai usar o WinSCP; NÃO como
                              Administrador, senão a chave nasce no perfil
                              errado.

COMO COPIAR OS TRÊS .ps1 DO HOST PARA A VM (passo 13.12)
GUIA
printf 'Os arquivos estão no host em: %s/windows\n' "$PROJETO_DIR"
cat <<'GUIA'

Opção A
Arrastar e soltar (mais simples, sem rede e sem firewall):

  Os guest tools do 13.11 instalam o spice-vdagent, que é o que habilita
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
  5. Leia o conteúdo de cada .ps1 antes de executá-lo. Nenhum deles precisa de
     rede para funcionar.

GUIA
cat <<'GUIA'
O disco HD1 físico só é anexado na etapa 14, DEPOIS da instalação do Windows
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
    info "Rode 'bash etapas/41-instalacao-windows.sh --verificar' (etapa 13) depois da instalação."
fi
