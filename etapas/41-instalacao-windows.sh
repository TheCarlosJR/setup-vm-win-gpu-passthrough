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
# pós-instalação. O driver NVIDIA dentro da VM só entra depois de a etapa 14
# (hooks da GPU) estar aplicada, e o caminho recomendado para ele é a etapa 16
# do menu (instalação automática via qemu-guest-agent, sem monitor dedicado).
# ============================================================================
SCRIPT_VERSION="1.0.0"
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

# ---------------------------------------------------------------------------
# REQ-WINDOWS-STATE: três eixos independentes
# ---------------------------------------------------------------------------
# Até I9 esta etapa decidia tudo por um único `guest-agent guest-ping`, o que
# fundia três fatos distintos e fazia a conclusão evaporar sempre que a VM era
# desligada. Agora são eixos separados:
#
#   1. instalação: evidência DURÁVEL na metadata namespaced do XML INATIVO,
#      vinculada à identidade do arquivo QCOW2 (ausente|registrada|divergente|
#      invalida|erro). Não olha energia nem agent;
#   2. energia: desligada|ligada|indeterminada, lida de `virsh domstate`;
#   3. guest agent: sem-canal|nao-aplicavel|indisponivel|respondendo.
#
# Invariante do requisito: com instalação `registrada`, desligar a VM ou perder
# o agent NÃO derruba o status; os eixos 2 e 3 passam a apenas informar.

WIN_AGENT_TIMEOUT=5
WIN_AGENT_CANAL='org.qemu.guest_agent.0'

WIN_INSTALL_EIXO=erro
WIN_INSTALL_RC=3
WIN_INSTALL_MSG=""
WIN_POWER_EIXO=indeterminada
WIN_POWER_TEXTO=""
WIN_AGENT_EIXO=sem-canal
WIN_AGENT_DIAG=""

win_instalacao_eixo() {
    # win_instalacao_eixo XML_INATIVO
    # Publica WIN_INSTALL_EIXO (rótulo) e WIN_INSTALL_RC (0..3 para v_classificar).
    local xml="${1:-}" rc_id=0 rc_meta=0
    WIN_INSTALL_EIXO=erro
    WIN_INSTALL_RC=3
    WIN_INSTALL_MSG=""
    qcow2_identidade_digest "${QCOW2_PATH:-}" || rc_id=$?
    if [ "$rc_id" -ne 0 ]; then
        # Sem identidade não há vínculo a provar. Ainda assim dá para saber se
        # existe evidência gravada: ausência continua sendo pendência da etapa,
        # e evidência presente sem identidade é falta de OBSERVAÇÃO, nunca
        # sucesso e nunca "ausente".
        xml_metadata_instalacao "$xml" || rc_meta=$?
        case "$WINDOWS_INSTALL_ESTADO" in
            ausente)
                WIN_INSTALL_EIXO=ausente
                WIN_INSTALL_RC=1
                WIN_INSTALL_MSG="Nenhuma evidência durável gravada (a identidade do QCOW2 também não pôde ser medida: ${QCOW2_IDENTIDADE_ERRO:-diagnóstico ausente})"
                ;;
            invalida)
                WIN_INSTALL_EIXO=invalida
                WIN_INSTALL_RC=3
                WIN_INSTALL_MSG="$WINDOWS_INSTALL_ERRO"
                ;;
            *)
                WIN_INSTALL_EIXO=erro
                # Ferramenta/arquivo ausente é indeterminado (o operador dá
                # acesso); dado recusado pelo core é erro (o operador corrige).
                if [ "$rc_id" -eq 1 ]; then
                    WIN_INSTALL_RC=2
                else
                    WIN_INSTALL_RC=3
                fi
                WIN_INSTALL_MSG="${QCOW2_IDENTIDADE_ERRO:-identidade do QCOW2 não medida}"
                ;;
        esac
        return 0
    fi
    xml_metadata_instalacao "$xml" "$QCOW2_IDENTIDADE_DIGEST" || rc_meta=$?
    # Evidência gravada num filesystem SEM birth continua conferindo se o mesmo
    # caminho passar a expor birth: o digest base ignora o birth por construção.
    # Ausência de birth nunca invalida evidência já gravada.
    if [ "$rc_meta" -eq 2 ] && [ -n "$QCOW2_IDENTIDADE_BASE" ] \
       && [ "$QCOW2_IDENTIDADE_BASE" != "$QCOW2_IDENTIDADE_DIGEST" ]; then
        rc_meta=0
        xml_metadata_instalacao "$xml" "$QCOW2_IDENTIDADE_BASE" || rc_meta=$?
    fi
    case "$WINDOWS_INSTALL_ESTADO" in
        registrada)
            WIN_INSTALL_EIXO=registrada
            WIN_INSTALL_RC=0
            WIN_INSTALL_MSG="Gravada em $WINDOWS_INSTALL_QUANDO, origem $WINDOWS_INSTALL_ORIGEM, vinculada à identidade $QCOW2_IDENTIDADE_KIND de ${QCOW2_PATH:-}"
            ;;
        ausente)
            WIN_INSTALL_EIXO=ausente
            WIN_INSTALL_RC=1
            WIN_INSTALL_MSG="Nenhuma evidência durável gravada para ${QCOW2_PATH:-}"
            ;;
        divergente)
            WIN_INSTALL_EIXO=divergente
            WIN_INSTALL_RC=2
            WIN_INSTALL_MSG="$WINDOWS_INSTALL_ERRO"
            ;;
        invalida)
            WIN_INSTALL_EIXO=invalida
            WIN_INSTALL_RC=3
            WIN_INSTALL_MSG="$WINDOWS_INSTALL_ERRO"
            ;;
        *)
            WIN_INSTALL_EIXO=erro
            WIN_INSTALL_RC=3
            WIN_INSTALL_MSG="${WINDOWS_INSTALL_ERRO:-metadata de instalação não observada}"
            ;;
    esac
}

win_power_eixo() {
    # win_power_eixo VM. `vm_desligada` só reconhece "shut off"; aqui todo
    # estado ativo do libvirt vira `ligada` e só o desconhecido/não observado
    # vira `indeterminada`.
    local vm="${1:-}" estado=""
    WIN_POWER_EIXO=indeterminada
    WIN_POWER_TEXTO=""
    estado="$(vm_estado "$vm" 2>/dev/null)" || estado=""
    WIN_POWER_TEXTO="$estado"
    case "$estado" in
        "shut off"|shutoff) WIN_POWER_EIXO=desligada ;;
        running|idle|blocked|paused|"in shutdown"|pmsuspended|crashed)
            WIN_POWER_EIXO=ligada ;;
        *) WIN_POWER_EIXO=indeterminada ;;
    esac
}

win_agent_eixo() {
    # win_agent_eixo VM XML_INATIVO. Exige WIN_POWER_EIXO já resolvido.
    local vm="${1:-}" xml="${2:-}" saida="" rc=0
    WIN_AGENT_EIXO=sem-canal
    WIN_AGENT_DIAG=""
    # `sem-canal` é ESTRUTURAL: sem o canal virtio no XML inativo, o serviço
    # QEMU-GA roda no Windows e nenhum ping responderá jamais. Isso é diferente
    # de um agent que existe e está temporariamente calado.
    if ! LC_ALL=C grep -Fq -- "$WIN_AGENT_CANAL" "$xml" 2>/dev/null; then
        return 0
    fi
    if [ "$WIN_POWER_EIXO" != ligada ]; then
        WIN_AGENT_EIXO=nao-aplicavel
        return 0
    fi
    # Sondagem só com a VM ligada, com timeout próprio (sem timeout o virsh
    # bloqueia até o libvirt desistir) e com stderr capturado para diagnóstico.
    saida="$(LC_ALL=C $VIRSH qemu-agent-command --timeout "$WIN_AGENT_TIMEOUT" \
        "$vm" '{"execute":"guest-ping"}' 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ] && LC_ALL=C grep -Fq '"return"' <<< "$saida"; then
        WIN_AGENT_EIXO=respondendo
        return 0
    fi
    # Retorno zero com saída inesperada não vira sucesso.
    WIN_AGENT_EIXO=indisponivel
    WIN_AGENT_DIAG="$(printf '%s' "$saida" | LC_ALL=C tail -n 1)"
}

win_power_texto() {
    case "$WIN_POWER_EIXO" in
        desligada) printf 'desligada' ;;
        ligada) printf 'ligada (%s)' "${WIN_POWER_TEXTO:-estado ativo}" ;;
        *) printf 'indeterminada (%s)' "${WIN_POWER_TEXTO:-virsh domstate sem resposta}" ;;
    esac
}

win_agent_texto() {
    case "$WIN_AGENT_EIXO" in
        sem-canal) printf "sem o canal '%s' no XML inativo" "$WIN_AGENT_CANAL" ;;
        nao-aplicavel) printf 'não aplicável (a VM não está ligada)' ;;
        indisponivel) printf 'indisponível (%s)' "${WIN_AGENT_DIAG:-sem diagnóstico}" ;;
        respondendo) printf 'respondendo' ;;
        *) printf 'estado de agent não classificado' ;;
    esac
}

verificar() {
    local tmp="" rc_vm=0
    [ -n "${VM_NAME:-}" ] || { v_falta "VM_NAME não definido."; v_fim; }
    [ -n "${QCOW2_PATH:-}" ] || { v_falta "QCOW2_PATH não definido (etapa 12)."; v_fim; }
    vm_existe_estado "$VM_NAME" || rc_vm=$?
    if [ "$rc_vm" -eq 1 ]; then
        v_falta "VM '$VM_NAME' não existe (etapa 12)."
        v_fim
    fi
    if [ "$rc_vm" -ne 0 ]; then
        v_indeterminado "VM '$VM_NAME' não pôde ser observada: ${VM_EXISTE_MOTIVO:-motivo não informado}."
        v_fim
    fi
    tmp="$(mktemp)" || { v_erro "Não foi possível criar temporário para o XML."; v_fim; }
    if ! $VIRSH dumpxml --inactive "$VM_NAME" > "$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then
        rm -f -- "$tmp"
        v_erro "Não foi possível ler o XML inativo da VM '$VM_NAME'."
        v_fim
    fi
    win_instalacao_eixo "$tmp"
    win_power_eixo "$VM_NAME"
    win_agent_eixo "$VM_NAME" "$tmp"
    rm -f -- "$tmp"

    case "$WIN_INSTALL_EIXO" in
        registrada)
            # O eixo 1 decide sozinho. Energia e agent viram informação: é
            # exatamente isso que impede a conclusão durável de evaporar quando
            # a VM é desligada ou o agent some.
            v_ok "Windows instalado: evidência durável no XML inativo vinculada a este QCOW2. $WIN_INSTALL_MSG."
            info "Energia (não altera o status): $(win_power_texto)."
            info "Guest agent (não altera o status): $(win_agent_texto)."
            ;;
        ausente)
            case "$WIN_AGENT_EIXO" in
                sem-canal)
                    v_falta "Instalação do Windows não comprovada, e esta VM não tem o canal '$WIN_AGENT_CANAL' no XML inativo: nenhum guest agent responderá enquanto isso não for corrigido."
                    ;;
                indisponivel)
                    v_falta "Instalação do Windows não comprovada: o canal existe e a VM está ligada, mas o guest agent não respondeu (${WIN_AGENT_DIAG:-sem diagnóstico})."
                    ;;
                respondendo)
                    v_falta "Instalação do Windows não comprovada no XML: o guest agent responde, mas a evidência durável nunca foi gravada. Execute a etapa 13 com a VM desligada para registrá-la."
                    ;;
                *)
                    v_falta "Instalação do Windows não comprovada: nenhuma evidência durável gravada e o guest agent não é aplicável com a VM $WIN_POWER_EIXO."
                    ;;
            esac
            if [ "$WIN_POWER_EIXO" = indeterminada ]; then
                v_indeterminado "Estado de energia da VM '$VM_NAME' não pôde ser observado: $(win_power_texto)."
            else
                info "Energia: $(win_power_texto)."
            fi
            ;;
        divergente)
            v_indeterminado "A evidência gravada não pertence ao QCOW2 atual: $WIN_INSTALL_MSG Nenhuma conclusão é atribuída a este disco."
            ;;
        invalida)
            v_erro "Metadata de instalação inválida no XML inativo: $WIN_INSTALL_MSG"
            ;;
        *)
            v_classificar "$WIN_INSTALL_RC" \
                "Instalação comprovada." \
                "Instalação não comprovada." \
                "Instalação não pôde ser observada: $WIN_INSTALL_MSG" \
                "Instalação não pôde ser avaliada: $WIN_INSTALL_MSG"
            ;;
    esac
    if [ "${WINDOWS_INSTALL_TERCEIROS:-0}" -gt 0 ]; then
        info "Metadata de terceiros preservada no XML: ${WINDOWS_INSTALL_TERCEIROS} elemento(s) fora do namespace do projeto."
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

guard_mutation domain.console || exit 1
exigir_conf VM_NAME
titulo "Etapa 13: instalação e pós-instalação do Windows 11 (interativa)"
info "Estado atual da VM: $($VIRSH domstate "$VM_NAME" 2>/dev/null || echo 'não observado')"

titulo "Antes de continuar"
info "Objetivo: concluir interativamente a instalação do Windows 11, dos drivers VirtIO e da pós-instalação no disco virtual da etapa 12."
info "Pré-requisitos: VM e duas ISOs criadas/anexadas pela etapa 12; use o console gráfico e mantenha a rede NAT default até copiar os scripts iniciais."
info "Alterações: este script consulta a VM, imprime o roteiro, pode abrir o console e, com a VM desligada e mediante confirmação, grava no XML inativo a evidência durável da instalação; o instalador e os guest tools gravam sempre no QCOW2, nunca no HD1 físico."
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

       ATENÇÃO ao que muda a partir daqui: o hook da etapa 14 para o
       gerenciador de login do host (DM_SERVICE) e entrega a GPU ao vfio-pci
       a CADA start da VM. O console SPICE do virt-manager morre junto com a
       sessão gráfica do host, e o monitor físico fica PRETO até o Windows ter
       o driver NVIDIA: a saída emulada QXL continua sendo a primária. Iniciar
       a VM neste estado, sem preparação, deixa você sem imagem e sem teclado.

       Rota de recuperação (guarde antes do primeiro start com GPU): de outro
       dispositivo, por SSH, rode
         virsh --connect qemu:///system shutdown <vm>
       e o hook release devolve GPU e desktop sozinho. Se o desktop não
       voltar, use o utilitário u6 do menu (recuperar GPU). NUNCA force o
       desligamento do host: ele interrompe a restauração no meio.

13.15. Instale o driver NVIDIA DENTRO da VM. Caminho recomendado: a etapa 16
       do menu (Instalar driver NVIDIA na VM), que faz tudo sem monitor nem
       teclado dedicados: baixa o instalador oficial, injeta/usa o
       qemu-guest-agent, instala em modo silencioso via guest-exec, confirma
       com nvidia-smi e desliga a VM devolvendo o desktop.

       Caminho manual (fallback, exige monitor na GPU e teclado/mouse da
       etapa 15):

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
          faz sentido: ele é o passo da etapa 18 (CPU isolation).

       Se o "Código 43" persistir depois do driver, o problema é do lado do
       host (vinculação ao vfio-pci, ROM/UEFI da GPU ou o Fast Startup do
       13.13 ainda ativo), não do driver: consulte troubleshooting.md antes de
       reinstalar.

13.16. Desligue a VM completamente uma vez, pelo Windows, e confirme no host
       que o desktop volta sozinho (é o hook release/end da etapa 14 devolvendo
       a GPU e religando o gerenciador de login).

13.17. Só então prossiga para as etapas 15 a 21 pelo menu. O
       Gerar-Chave-Airlock.ps1 é o passo da etapa 20 (airlock) e não deve ser
       executado antes dela.

QUANDO CADA .ps1 É USADO (não execute fora de hora):

  Desativar-Fast-Startup.ps1  agora, no 13.13, como Administrador.
  Ativar-MSI-GPU.ps1          etapa 18 (CPU isolation), como Administrador e
                              somente após o driver NVIDIA do 13.15 estar
                              instalado e funcionando.
  Gerar-Chave-Airlock.ps1     etapa 20 (airlock), com o usuário comum do
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

# Console só faz sentido com a VM ativa. `vm_existe_estado` distingue domínio
# ausente de libvirt não observável, e assim um libvirtd fora do ar não vira
# "a VM não existe".
WIN_CONSOLE_RC=0
vm_existe_estado "$VM_NAME" || WIN_CONSOLE_RC=$?
win_power_eixo "$VM_NAME"
if [ "$WIN_CONSOLE_RC" -eq 0 ] && [ "$WIN_POWER_EIXO" = ligada ]; then
    if confirmar "Abrir o console gráfico agora?"; then
        nohup virt-manager --connect qemu:///system --show-domain-console "$VM_NAME" >/dev/null 2>&1 &
    fi
fi

# ---------------------------------------------------------------------------
# Transação de metadata (REQ-WINDOWS-STATE + REQ-TRIM-TX como molde)
# ---------------------------------------------------------------------------
# Estados explícitos, traps armados ANTES do primeiro define e commit somente
# depois da prova relida do libvirt. Retorno zero de `define` nunca é tratado
# como evidência: a restauração também é relida e comparada semanticamente.

WIN_ESTADO_TX=IDLE          # IDLE|PREPARED|APPLIED|VERIFIED|COMMITTED|ROLLING_BACK
WIN_FINGERPRINT_ORIGINAL=""
WIN_PRESERVAR_EVIDENCIA=0
WIN_XML_ATUAL="$(mktemp)"
WIN_XML_CANDIDATO="$(mktemp)"
WIN_XML_POS="$(mktemp)"
WIN_XML_ROLLBACK="$(mktemp)"

win_limpar_temporarios() {
    rm -f -- "$WIN_XML_CANDIDATO" "$WIN_XML_POS" "$WIN_XML_ROLLBACK"
    if [ "$WIN_PRESERVAR_EVIDENCIA" -eq 0 ]; then
        rm -f -- "$WIN_XML_ATUAL"
    else
        erro "XML original preservado para recuperação em: $WIN_XML_ATUAL"
    fi
    python_core_temporarios_limpar
    # A limpeza nunca pode virar o código de saída do script: quem decide o
    # status é o fluxo, não o `rm` do temporário.
    return 0
}
trap 'win_limpar_temporarios' EXIT

win_rollback() {
    # Restaura o XML original e PROVA a restauração relendo o domínio.
    local rc_compare=0
    WIN_ESTADO_TX=ROLLING_BACK
    if $VIRSH dumpxml --inactive "$VM_NAME" > "$WIN_XML_ROLLBACK" 2>/dev/null \
       && xml_dominio_fingerprint "$WIN_XML_ROLLBACK" \
       && [ -n "$WIN_FINGERPRINT_ORIGINAL" ] \
       && [ "$XML_DOMINIO_FINGERPRINT" = "$WIN_FINGERPRINT_ORIGINAL" ]; then
        aviso "Nenhuma mutação efetiva do XML a desfazer; o domínio segue idêntico ao original."
        return 0
    fi
    if ! $VIRSH define --validate "$WIN_XML_ATUAL" >/dev/null 2>&1; then
        erro "ROLLBACK XML NÃO COMPROVADO. O virsh recusou restaurar o XML original."
        WIN_PRESERVAR_EVIDENCIA=1
        return 1
    fi
    if ! $VIRSH dumpxml --inactive "$VM_NAME" > "$WIN_XML_ROLLBACK" 2>/dev/null; then
        erro "ROLLBACK XML NÃO COMPROVADO. Não foi possível reler o domínio após a restauração."
        WIN_PRESERVAR_EVIDENCIA=1
        return 1
    fi
    xml_dominio_equivalente "$WIN_XML_ATUAL" "$WIN_XML_ROLLBACK" full || rc_compare=$?
    if [ "$rc_compare" -eq 0 ]; then
        aviso "XML anterior restaurado e comprovado por releitura semântica."
        return 0
    fi
    if [ "$rc_compare" -eq 2 ]; then
        erro "ROLLBACK XML NÃO COMPROVADO. Falha ao comparar o domínio restaurado: $XML_COMPARACAO_ERRO"
    else
        erro "ROLLBACK XML NÃO COMPROVADO. O domínio restaurado divergiu do original: ${XML_COMPARACAO_DIFERENCA:-divergência semântica}."
    fi
    WIN_PRESERVAR_EVIDENCIA=1
    return 1
}

win_finalizar() {
    local rc=$?
    trap - EXIT INT TERM
    case "$WIN_ESTADO_TX" in
        # PREPARED entra na restauração de propósito: entre armar os traps e
        # confirmar o define não dá para saber se a mutação já valeu, e
        # win_rollback começa comparando o fingerprint, então estado inalterado
        # não gera efeito adicional.
        PREPARED|APPLIED|VERIFIED|ROLLING_BACK)
            erro "Transação de metadata interrompida antes do commit; restaurando o XML original."
            if ! win_rollback; then
                erro "Recuperação manual necessária: restaure o backup XML informado acima antes de iniciar a VM."
                [ "$rc" -ne 0 ] || rc=1
            fi
            ;;
    esac
    win_limpar_temporarios
    exit "$rc"
}

win_registrar_evidencia() {
    local quando=""
    if [ -z "$QCOW2_IDENTIDADE_DIGEST" ]; then
        aviso "A identidade do QCOW2 não pôde ser medida: ${QCOW2_IDENTIDADE_ERRO:-diagnóstico ausente}"
        info "Sem identidade não existe vínculo a gravar; nada foi alterado."
        return 0
    fi
    if [ "$WIN_POWER_EIXO" != desligada ]; then
        aviso "A evidência durável só é gravada com a VM DESLIGADA: o registro reescreve o XML inativo com virsh define."
        info "Energia agora: $(win_power_texto). Desligue a VM pelo Windows e execute a etapa 13 novamente."
        return 0
    fi
    if [ "$WIN_INSTALL_EIXO" = divergente ]; then
        aviso "JÁ EXISTE evidência gravada nesta VM, e ela aponta para OUTRO QCOW2."
        info "Gravada: $WINDOWS_INSTALL_DIGEST (em $WINDOWS_INSTALL_QUANDO, origem $WINDOWS_INSTALL_ORIGEM)."
        info "Atual:   $QCOW2_IDENTIDADE_DIGEST (identidade $QCOW2_IDENTIDADE_KIND de $QCOW2_PATH)."
        aviso "Confirme apenas se o QCOW2 foi legitimamente recriado. Confirmar sem isso atribui a evidência ao disco errado."
        if ! confirmar "Substituir a evidência antiga pela identidade do QCOW2 atual?"; then
            info "Nada foi alterado."
            return 0
        fi
    else
        info "Registrar declara que o Windows JÁ está instalado no QCOW2 $QCOW2_PATH."
        info "A evidência sobrevive a VM desligada e a guest agent ausente, e fica vinculada à identidade $QCOW2_IDENTIDADE_KIND do arquivo."
        if ! confirmar "Registrar agora a evidência durável da instalação no XML inativo?"; then
            info "Nada foi alterado. Registre quando o Windows estiver realmente instalado."
            return 0
        fi
    fi

    exigir_comando virt-xml-validate
    python_core_disponivel \
        || falhar "O core Python do projeto não respondeu: ${PYTHON_CORE_ERRO:-diagnóstico ausente}."
    exigir_vm_desligada "$VM_NAME"
    $VIRSH help define 2>/dev/null | grep -q -- '--validate' \
        || falhar "Este virsh não oferece define --validate; nada foi alterado."

    xml_dominio_fingerprint "$WIN_XML_ATUAL" \
        || falhar "Não foi possível medir o XML original: $XML_DOMINIO_ERRO"
    WIN_FINGERPRINT_ORIGINAL="$XML_DOMINIO_FINGERPRINT"

    quando="$(date +%Y%m%d-%H%M%S)"
    xml_candidato_instalacao "$WIN_XML_ATUAL" "$WIN_XML_CANDIDATO" \
        "$QCOW2_IDENTIDADE_DIGEST" "$quando" operador \
        || falhar "Candidato de metadata recusado: $XML_CANDIDATO_ERRO"
    [ "$XML_CANDIDATO_FINGERPRINT_ANTES" = "$WIN_FINGERPRINT_ORIGINAL" ] \
        || falhar "O XML mudou entre a captura e a geração do candidato; nada foi alterado."
    [ "$XML_CANDIDATO_MUDOU" = 1 ] \
        || falhar "O candidato não alterou o XML apesar do estado divergir; nada foi alterado."
    virt-xml-validate "$WIN_XML_CANDIDATO" domain >/dev/null \
        || falhar "O XML candidato com a metadata não passa no schema libvirt."
    xml_metadata_instalacao "$WIN_XML_CANDIDATO" "$QCOW2_IDENTIDADE_DIGEST" \
        || falhar "Pós-condição do candidato recusada: ${WINDOWS_INSTALL_ERRO:-evidência não comprovada no candidato}."
    xml_backup "$VM_NAME"

    # Traps armados ANTES do primeiro define: falha ou sinal em qualquer ponto
    # da janela mutante cai na restauração comprovada, preservando o código.
    trap 'win_finalizar' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    WIN_ESTADO_TX=PREPARED

    $VIRSH define --validate "$WIN_XML_CANDIDATO" >/dev/null \
        || falhar "virsh define recusou o XML candidato; a transação restaurará o XML original."
    WIN_ESTADO_TX=APPLIED
    $VIRSH dumpxml --inactive "$VM_NAME" > "$WIN_XML_POS" \
        || falhar "Não foi possível reler o XML após o define; a transação restaurará o original."
    [ -s "$WIN_XML_POS" ] \
        || falhar "O XML relido após o define veio vazio; a transação restaurará o original."
    virt-xml-validate "$WIN_XML_POS" domain >/dev/null \
        || falhar "O XML persistido não passa no schema libvirt; a transação restaurará o original."
    xml_metadata_instalacao "$WIN_XML_POS" "$QCOW2_IDENTIDADE_DIGEST" \
        || falhar "A evidência de instalação não foi comprovada após o define: ${WINDOWS_INSTALL_ERRO:-estado divergente}."
    [ "$WINDOWS_INSTALL_ESTADO" = registrada ] \
        || falhar "A evidência relida ficou em '$WINDOWS_INSTALL_ESTADO'; a transação restaurará o original."
    WIN_ESTADO_TX=VERIFIED

    # Commit lógico: a partir daqui o trap deixa de restaurar.
    WIN_ESTADO_TX=COMMITTED
    trap 'win_limpar_temporarios' EXIT
    trap - INT TERM
    ok "Evidência durável da instalação registrada no XML inativo (em $quando, origem operador)."
    info "A partir daqui, desligar a VM ou perder o guest agent não derruba mais o status da etapa 13."
}

echo
titulo "Estado da instalação, energia e guest agent (eixos independentes)"

$VIRSH dumpxml --inactive "$VM_NAME" > "$WIN_XML_ATUAL" 2>/dev/null \
    || falhar "Não foi possível ler o XML inativo da VM '$VM_NAME'."
[ -s "$WIN_XML_ATUAL" ] || falhar "O XML inativo capturado está vazio."

win_instalacao_eixo "$WIN_XML_ATUAL"
win_power_eixo "$VM_NAME"
win_agent_eixo "$VM_NAME" "$WIN_XML_ATUAL"

info "Eixo 1, instalação: $WIN_INSTALL_EIXO"
if [ -n "$WIN_INSTALL_MSG" ]; then
    info "        $WIN_INSTALL_MSG"
fi
info "Eixo 2, energia: $(win_power_texto)."
info "Eixo 3, guest agent: $(win_agent_texto)."
if [ "${WINDOWS_INSTALL_TERCEIROS:-0}" -gt 0 ]; then
    info "Metadata de terceiros no XML preservada: ${WINDOWS_INSTALL_TERCEIROS} elemento(s) fora do namespace do projeto."
fi

if [ "$WIN_AGENT_EIXO" = sem-canal ]; then
    # O canal virtio é pré-requisito do lado do host: sem ele, o serviço QEMU-GA
    # roda no Windows e o guest-ping nunca responde. VMs criadas antes de a
    # etapa 12 passar a declarar o canal precisam recebê-lo uma única vez.
    aviso "Esta VM não tem o canal 'org.qemu.guest_agent.0' no XML: nenhum guest-agent responderá enquanto isso não for corrigido."
    info "Com a VM DESLIGADA, adicione o canal uma única vez (as três linhas, na ordem):"
    printf "\n  printf '%%s\\\\n' \"<channel type='unix'><target type='virtio' name='org.qemu.guest_agent.0'/></channel>\" > /tmp/guest-agent.xml\n"
    printf '  virsh --connect qemu:///system attach-device %s /tmp/guest-agent.xml --config\n' \
        "$VM_NAME"
    printf '  rm -f /tmp/guest-agent.xml\n\n'
    info "Depois inicie a VM uma vez: o canal só passa a existir no boot seguinte."
    info "VMs criadas pela etapa 12 a partir desta versão já nascem com o canal."
elif [ "$WIN_AGENT_EIXO" = respondendo ]; then
    ok "guest-agent OK: {\"return\":{}}"
    info "Dentro do Windows, confirme também: Get-Disk  e  Get-Service QEMU-GA"
    aviso "Pós-instalação pendente mais importante: o driver NVIDIA dentro da VM."
    info "Use a etapa 16 do menu (Instalar driver NVIDIA na VM): ela instala tudo automaticamente, sem monitor nem teclado dedicados."
else
    info "guest-agent sem resposta agora. Normal antes de instalar o virtio-win-guest-tools."
    info "Atalho: a etapa 16 do menu (driver NVIDIA automático) sabe injetar o qemu-guest-agent no QCOW2 com a VM desligada, sem precisar de tela."
fi

echo
titulo "Evidência durável da instalação (independente de energia e do agent)"
case "$WIN_INSTALL_EIXO" in
    registrada)
        # Segunda execução sobre estado convergido é no-op exato: nenhum
        # candidato é gerado e nenhum define acontece.
        ok "Evidência já registrada e vinculada a este QCOW2; nada a fazer."
        info "Gravada em $WINDOWS_INSTALL_QUANDO, origem $WINDOWS_INSTALL_ORIGEM."
        ;;
    invalida)
        erro "A metadata vmpass:windows-install do XML inativo está fora do schema: $WIN_INSTALL_MSG"
        info "Corrija ou remova a metadata inválida antes de registrar evidência nova; nada foi alterado."
        ;;
    erro)
        erro "Não foi possível avaliar a evidência de instalação: $WIN_INSTALL_MSG"
        info "Nada foi alterado."
        ;;
    *)
        win_registrar_evidencia
        ;;
esac

info "Rode 'bash etapas/41-instalacao-windows.sh --verificar' (etapa 13) para reavaliar os três eixos."
