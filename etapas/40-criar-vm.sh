#!/bin/bash
# ============================================================================
# etapas/40-criar-vm.sh - Capítulo 17: Criação da Máquina Virtual
# ============================================================================
# Versão automatizada (virt-install) da criação feita no Virt-Manager pelo
# manual, com exatamente as mesmas escolhas:
#   - Firmware OVMF (UEFI) + chipset Q35
#   - TPM 2.0 emulado (swtpm)
#   - Disco /vm/Windows11.qcow2 (qcow2 dinâmico, VirtIO, cache=none)
#   - 2 CD-ROMs: ISO do Windows 11 + virtio-win.iso
#   - CPU host-passthrough, NIC virtio em NAT 'default' TEMPORÁRIA
#     (a etapa 60 aplica o modo final bridge ou NAT dedicado)
#   - Vídeo QXL temporário (a GPU real entra na etapa 50)
# Também aplica a regra AppArmor para o caminho customizado /vm.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

APPARMOR_LOCAL="/etc/apparmor.d/local/abstractions/libvirt-qemu"
REGRA_APPARMOR='/vm/** rwk,'

verificar() {
    [ -n "${VM_NAME:-}" ] || { v_falta "VM_NAME não definido (etapa 02)."; v_fim; }
    if validar_config_rede; then
        v_ok "Rede final selecionada: $REDE_MODO via $INTERFACE_FISICA (NAT default permanece temporária até a etapa 60)."
    else
        v_falta "$REDE_CONFIG_ERRO"
    fi
    if [ -f "${QCOW2_PATH:-/vm/Windows11.qcow2}" ]; then
        v_ok "Disco ${QCOW2_PATH} existe."
    else
        v_falta "Disco ${QCOW2_PATH:-?} não existe."
    fi
    if vm_existe "$VM_NAME"; then
        v_ok "VM '$VM_NAME' definida no libvirt."
        if [ -n "${VM_NIC_MAC:-}" ]; then
            mac_valido "$VM_NIC_MAC" \
                && v_ok "MAC persistido da NIC: $VM_NIC_MAC" \
                || v_falta "VM_NIC_MAC inválido: $VM_NIC_MAC"
        else
            v_ok "Configuração antiga: a etapa 60 registrará VM_NIC_MAC antes de alterar a NIC."
        fi
    else
        v_falta "VM '$VM_NAME' não definida."
    fi
    if grep -qF "$REGRA_APPARMOR" "$APPARMOR_LOCAL" 2>/dev/null; then
        v_ok "Regra AppArmor para /vm presente."
    else
        v_falta "Regra AppArmor para /vm ausente."
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

titulo "Antes de continuar"
info "Objetivo: preparar o armazenamento e definir/iniciar a VM do Windows 11 com UEFI, TPM, VirtIO e NAT temporária."
info "Pré-requisitos: etapas 20, 21 (já em sessão nova) e 30 fase B concluídas, ISOs oficiais disponíveis e espaço suficiente no volume do QCOW2."
info "Alterações: salva caminhos das ISOs; a cópia opcional para /vm/iso preserva os originais; adiciona '/vm/** rwk,' à abstração local do AppArmor e a recarrega; cria o QCOW2 dinâmico se ausente; ativa a rede default; virt-install define e inicia a VM."
info "Recomendação: mantenha backup de qualquer QCOW2 existente, confirme o espaço livre e use somente ISOs obtidas dos canais oficiais."
aviso "Riscos: a regra AppArmor concede ao QEMU leitura/escrita/bloqueio sob /vm; falta de espaço pode corromper o convidado; uma interrupção pode deixar disco, configuração ou definição parciais."
info "VM existente: a etapa aborta antes dessas alterações. 'undefine --nvram' remove a definição e a NVRAM, mas não apaga o QCOW2 sem --remove-all-storage; o arquivo existente permanece e será reutilizado."
aviso "virsh reset é um reset forçado, equivalente ao botão físico: só é aceitável no primeiro boot, enquanto não houver dados importantes; depois use desligamento/reinício normal do Windows."
info "Retorno/reboot: não exige reboot do host e não há rollback automático; com a VM desligada, undefine remove apenas a definição/NVRAM, enquanto QCOW2, ISOs e a regra AppArmor exigem revisão manual separada."

exigir_nao_root
exigir_sudo
exigir_comando virt-install qemu-img virsh xmlstarlet
exigir_conf VM_NAME QCOW2_PATH QCOW2_TAMANHO VM_RAM_MB VM_VCPUS
exigir_config_rede
nome_vm_valido "$VM_NAME" || falhar "VM_NAME='$VM_NAME' contém caracteres não seguros para libvirt/caminhos."

titulo "Capítulo 17: Criação da VM '$VM_NAME'"
info "Modo final selecionado: $REDE_MODO via $INTERFACE_FISICA; a criação usa NAT default somente até a etapa 60."

# Rede de segurança: o conf pode ter sido editado à mão depois da etapa 02.
RAM_MAX="$(ram_max_vm_mib)"
if [ "$VM_RAM_MB" -gt "$RAM_MAX" ]; then
    erro "VM_RAM_MB=$VM_RAM_MB MiB passa do teto seguro deste host ($RAM_MAX MiB)."
    erro "O host precisa da diferença para si (cache, desktop, o próprio processo QEMU)."
    falhar "Corrija com: bash etapas/02-detectar-config.sh --redetectar"
fi
CPUS_TOTAL="$(nproc --all)"
if [ "$VM_VCPUS" -ge "$CPUS_TOTAL" ]; then
    erro "VM_VCPUS=$VM_VCPUS é igual/maior que o total de CPUs lógicas do host ($CPUS_TOTAL)."
    falhar "Deixe pelo menos um núcleo físico para o host: etapas/02-detectar-config.sh --redetectar"
fi
info "Recursos: ${VM_RAM_MB} MiB de RAM (teto ${RAM_MAX}), ${VM_VCPUS} vCPUs de ${CPUS_TOTAL}."

if vm_existe "$VM_NAME"; then
    falhar "A VM '$VM_NAME' já existe. Para recriar: virsh --connect qemu:///system undefine $VM_NAME --nvram (CUIDADO: leia o Capítulo 17, 'Como desfazer')."
fi
HOOKS_RESIDUAIS="/etc/libvirt/hooks/qemu.d/$VM_NAME"
if sudo test -e "$HOOKS_RESIDUAIS" || sudo test -L "$HOOKS_RESIDUAIS"; then
    falhar "Existem hooks residuais para '$VM_NAME' em $HOOKS_RESIDUAIS. Revise/arquive-os manualmente antes de recriar a VM; eles não serão removidos automaticamente."
fi

# ----------------------------------------------------------------------------
# 1. ISOs (sempre de canais oficiais; o manual não fornece links de propósito)
# ----------------------------------------------------------------------------
titulo "1/5 ISOs de instalação"

pedir_iso() {
    # pedir_iso VARIAVEL "descrição" "dica"  -> pergunta até existir o arquivo
    local var="$1" desc="$2" dica="$3" caminho tentativas=0
    caminho="${!var:-}"
    while [ ! -f "$caminho" ]; do
        if [ -n "$caminho" ]; then
            erro "Arquivo não encontrado: $caminho"
        fi
        info "$dica"
        caminho="$(perguntar "Caminho da $desc (ENTER cancela)" '')"
        [ -n "$caminho" ] || falhar "Sem a $desc não há como instalar o Windows. Cancelado."
        # ~ digitado à mão não é expandido dentro de variáveis
        caminho="${caminho/#\~/$HOME}"
        tentativas=$((tentativas + 1))
        [ "$tentativas" -ge 5 ] && falhar "Cinco tentativas sem encontrar a $desc. Cancelado."
    done
    salvar_conf "$var" "$caminho"
    ok "$desc: $caminho ($(du -h "$caminho" 2>/dev/null | cut -f1))"
}

pedir_iso ISO_WINDOWS "ISO do Windows 11" \
    "Baixe a ISO do Windows 11 em microsoft.com (nunca de espelhos de terceiros)."
pedir_iso ISO_VIRTIO "ISO virtio-win" \
    "Baixe a virtio-win.iso do projeto oficial virtio-win (QEMU/Red Hat)."

# ISOs dentro de /home podem ficar ilegíveis para o usuário libvirt-qemu
# (home 750 no Ubuntu/Pop recentes). Oferece mover para /vm/iso.
for VAR in ISO_WINDOWS ISO_VIRTIO; do
    CAMINHO="${!VAR}"
    if [[ "$CAMINHO" == /home/* ]]; then
        aviso "$CAMINHO está dentro de /home (o QEMU pode não conseguir ler)."
        if confirmar "Copiar para /vm/iso/ (recomendado)?"; then
            sudo mkdir -p /vm/iso
            sudo cp -v "$CAMINHO" /vm/iso/
            NOVO="/vm/iso/$(basename "$CAMINHO")"
            sudo chown root:libvirt-qemu "$NOVO"
            sudo chmod 640 "$NOVO"
            salvar_conf "$VAR" "$NOVO"
        fi
    fi
done

# ----------------------------------------------------------------------------
# 2. Regra AppArmor para o caminho customizado /vm
# ----------------------------------------------------------------------------
titulo "2/5 AppArmor"
sudo mkdir -p "$(dirname "$APPARMOR_LOCAL")"
sudo touch "$APPARMOR_LOCAL"
if sudo grep -qF "$REGRA_APPARMOR" "$APPARMOR_LOCAL"; then
    info "Regra AppArmor já presente."
else
    echo "$REGRA_APPARMOR" | sudo tee -a "$APPARMOR_LOCAL" >/dev/null
    sudo systemctl reload apparmor
    ok "Regra '$REGRA_APPARMOR' adicionada e AppArmor recarregado."
fi

# ----------------------------------------------------------------------------
# 3. Disco QCOW2 (dinâmico, criado já com o dono correto)
# ----------------------------------------------------------------------------
titulo "3/5 Disco do sistema"
if [ -f "$QCOW2_PATH" ]; then
    info "Disco já existe: $QCOW2_PATH (mantido)."
else
    # QCOW2 cresce sob demanda, mas alocar mais do que o disco tem só adia o
    # problema para o meio de uma sessão do Windows (ENOSPC = corrupção).
    DIR_QCOW2="$(dirname "$QCOW2_PATH")"
    LIVRE_GB="$(df -BG --output=avail "$DIR_QCOW2" 2>/dev/null | tail -n1 | tr -dc '0-9')"
    # QCOW2_TAMANHO aceita sufixo G, T ou M (formato do qemu-img): normaliza em GiB
    NUM_ALVO="$(tr -dc '0-9' <<< "$QCOW2_TAMANHO")"
    case "${QCOW2_TAMANHO: -1}" in
        T|t) ALVO_GB=$((NUM_ALVO * 1024)) ;;
        M|m) ALVO_GB=$((NUM_ALVO / 1024)) ;;
        *)   ALVO_GB="$NUM_ALVO" ;;
    esac
    if [ -n "$LIVRE_GB" ] && [ -n "$ALVO_GB" ] && [ "$LIVRE_GB" -lt "$ALVO_GB" ]; then
        aviso "Espaço livre em $DIR_QCOW2: ${LIVRE_GB} GiB, menor que o disco pedido (${ALVO_GB} GiB)."
        aviso "O QCOW2 cresce sob demanda; se o disco encher com a VM ligada, o Windows corrompe."
        confirmar "Criar assim mesmo?" \
            || falhar "Cancelado. Ajuste QCOW2_TAMANHO no passthrough.conf ou libere espaço."
    fi
    sudo -u libvirt-qemu qemu-img create -f qcow2 "$QCOW2_PATH" "$QCOW2_TAMANHO"
fi
qemu-img info "$QCOW2_PATH" | sed 's/^/  /'

# ----------------------------------------------------------------------------
# 4. Rede default do libvirt ativa (NAT de bootstrap até a etapa 60)
# ----------------------------------------------------------------------------
titulo "4/5 Rede NAT default temporária"
if ! $VIRSH net-info default 2>/dev/null | grep -q 'Active:.*yes'; then
    $VIRSH net-start default || true
    $VIRSH net-autostart default || true
fi
$VIRSH net-info default | sed 's/^/  /' || aviso "Rede 'default' indisponível; verifique o libvirt."

# ----------------------------------------------------------------------------
# 5. Definição da VM via virt-install
# ----------------------------------------------------------------------------
titulo "5/5 virt-install"
OSV="win10"
if command -v osinfo-query >/dev/null 2>&1 && osinfo-query os 2>/dev/null | grep -qw win11; then
    OSV="win11"
fi
info "os-variant: $OSV"

virt-install \
    --connect qemu:///system \
    --name "$VM_NAME" \
    --metadata title="Windows 11 (GPU passthrough)" \
    --memory "$VM_RAM_MB" \
    --vcpus "$VM_VCPUS" \
    --cpu host-passthrough \
    --machine q35 \
    --os-variant "$OSV" \
    --boot uefi \
    --tpm model=tpm-crb,backend.type=emulator,backend.version=2.0 \
    --disk path="$QCOW2_PATH",format=qcow2,bus=virtio,cache=none \
    --disk path="$ISO_WINDOWS",device=cdrom,bus=sata \
    --disk path="$ISO_VIRTIO",device=cdrom,bus=sata \
    --network network=default,model=virtio \
    --graphics spice \
    --video qxl \
    --sound ich9 \
    --noautoconsole

VM_NIC_MAC_DETECTADO="$($VIRSH dumpxml --inactive "$VM_NAME" \
    | xmlstarlet sel -t -v "string(/domain/devices/interface[source/@network='default'][1]/mac/@address)")"
mac_valido "$VM_NIC_MAC_DETECTADO" \
    || falhar "A VM foi criada, mas não foi possível obter com segurança o MAC da NIC NAT temporária."
salvar_conf VM_NIC_MAC "${VM_NIC_MAC_DETECTADO,,}"
ok "NIC virtio temporária em network=default; MAC persistido: $VM_NIC_MAC."

echo
ok "VM criada e instalação iniciada em segundo plano."
$VIRSH list --all

info "Conferência do XML (loader OVMF, nvram, qcow2, q35):"
$VIRSH dumpxml "$VM_NAME" | grep -E "loader|nvram|qcow2|machine=" | sed 's/^/  /'

echo
aviso "A ISO do Windows pede 'Press any key to boot from CD' logo no início:"
aviso "abra o console AGORA e pressione uma tecla, senão o boot cai no shell UEFI."
if confirmar "Abrir o console gráfico da VM agora (virt-manager)?"; then
    nohup virt-manager --connect qemu:///system --show-domain-console "$VM_NAME" >/dev/null 2>&1 &
    info "Console aberto. Siga a etapa 41 para o passo a passo da instalação."
else
    info "Abra depois com: virt-manager --connect qemu:///system --show-domain-console $VM_NAME"
fi
info "Se perder o momento do boot: virsh --connect qemu:///system reset $VM_NAME"
