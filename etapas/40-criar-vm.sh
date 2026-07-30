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
#   - CPU host-passthrough, rede NAT 'default' com modelo virtio (bridge: etapa 60)
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
    if [ -f "${QCOW2_PATH:-/vm/Windows11.qcow2}" ]; then
        v_ok "Disco ${QCOW2_PATH} existe."
    else
        v_falta "Disco ${QCOW2_PATH:-?} não existe."
    fi
    if vm_existe "$VM_NAME"; then
        v_ok "VM '$VM_NAME' definida no libvirt."
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

exigir_nao_root
exigir_sudo
exigir_comando virt-install qemu-img virsh
exigir_conf VM_NAME QCOW2_PATH QCOW2_TAMANHO VM_RAM_MB VM_VCPUS

titulo "Capítulo 17: Criação da VM '$VM_NAME'"

if vm_existe "$VM_NAME"; then
    falhar "A VM '$VM_NAME' já existe. Para recriar: virsh --connect qemu:///system undefine $VM_NAME --nvram (CUIDADO: leia o Capítulo 17, 'Como desfazer')."
fi

# ----------------------------------------------------------------------------
# 1. ISOs (sempre de canais oficiais; o manual não fornece links de propósito)
# ----------------------------------------------------------------------------
titulo "1/5 ISOs de instalação"
if [ -z "${ISO_WINDOWS:-}" ] || [ ! -f "${ISO_WINDOWS:-}" ]; then
    info "Baixe a ISO do Windows 11 em microsoft.com (nunca de espelhos de terceiros)."
    salvar_conf ISO_WINDOWS "$(perguntar 'Caminho da ISO do Windows 11')"
fi
if [ -z "${ISO_VIRTIO:-}" ] || [ ! -f "${ISO_VIRTIO:-}" ]; then
    info "Baixe a virtio-win.iso do projeto oficial virtio-win (QEMU/Red Hat)."
    salvar_conf ISO_VIRTIO "$(perguntar 'Caminho da virtio-win.iso')"
fi
[ -f "$ISO_WINDOWS" ] || falhar "ISO do Windows não encontrada: $ISO_WINDOWS"
[ -f "$ISO_VIRTIO" ]  || falhar "virtio-win.iso não encontrada: $ISO_VIRTIO"

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
    sudo -u libvirt-qemu qemu-img create -f qcow2 "$QCOW2_PATH" "$QCOW2_TAMANHO"
fi
qemu-img info "$QCOW2_PATH" | sed 's/^/  /'

# ----------------------------------------------------------------------------
# 4. Rede default do libvirt ativa (NAT, suficiente até a etapa 60)
# ----------------------------------------------------------------------------
titulo "4/5 Rede NAT default"
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
