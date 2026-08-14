# Fedora Workstation

**Estado:** PLANEJADO — NÃO EXECUTADO PELO PROJETO  
**Fixture:** Fedora 42, UEFI, GRUB, NetworkManager e firewalld  
**Família:** DNF/RPM

`lib/platform.sh` rejeita atualmente `ID=fedora`. Os comandos abaixo são candidatos para a segunda onda do suporte multi-distro.

## Atualização e pacotes

```bash
sudo dnf upgrade --refresh
sudo dnf autoremove
```

Consulta e instalação:

```bash
rpm -q "$PACOTE"
dnf info "$PACOTE"
dnf repoquery "$PACOTE"
sudo dnf install -y "$PACOTE"
```

Pacotes base candidatos, sujeitos ao catálogo da versão:

```bash
sudo dnf install -y \
  pciutils usbutils dmidecode curl wget git htop \
  xmlstarlet rsync acl
```

Pilha de virtualização candidata:

```bash
sudo dnf install -y \
  qemu-kvm libvirt-daemon-kvm libvirt-client \
  virt-install virt-manager edk2-ovmf swtpm swtpm-tools
```

O adaptador também pode resolver um grupo de virtualização, mas deve registrar os pacotes concretos escolhidos e validar:

```bash
qemu-system-x86_64 --version
qemu-img --version
virsh --connect qemu:///system version
virt-install --version
virt-host-validate qemu
```

Os nomes de pacote acima são candidatos; os Specs ainda não os congelam como contrato.

## NVIDIA

Fedora não possui equivalente nativo de `ubuntu-drivers`. O projeto não deve habilitar RPM Fusion, COPR ou outro repositório externo.

Somente quando o operador já tiver configurado um repositório compatível:

```bash
dnf info akmod-nvidia
sudo dnf install -y akmod-nvidia
akmods --force
modinfo nvidia
nvidia-smi
```

Outros pacotes, como componentes CUDA/userspace, devem ser resolvidos conforme a GPU e o repositório existente. Sem pré-condição comprovada, a capability NVIDIA fica bloqueada.

## Initramfs

```bash
sudo dracut --regenerate-all --force
```

Antes da mutação, confirmar que dracut é o gerador efetivo e capturar os artefatos para rollback.

## Boot

Fedora pode usar BLS/grubby mesmo quando a fixture relata GRUB.

Consulta:

```bash
grubby --info=ALL
bootctl status
```

BLS/grubby, quando comprovado:

```bash
sudo grubby --update-kernel=ALL --args='amd_iommu=on iommu=pt'
sudo grubby --update-kernel=ALL --remove-args='amd_iommu=on iommu=pt'
```

GRUB tradicional, somente após descobrir o destino real:

```bash
sudo grub2-mkconfig -o "$GRUB_CFG_COMPROVADO"
```

Não fixar `/boot/grub2/grub.cfg` ou caminho EFI sem evidência do host.

## Libvirt

Fedora frequentemente usa daemons modulares, mas o provider precisa sondar todos os candidatos:

```bash
systemctl status libvirtd.socket
systemctl status libvirtd.service
systemctl status virtqemud.socket
systemctl status virtqemud.service
systemctl status virtlogd.socket
systemctl status virtlogd.service
```

Identidade e grupos:

```bash
grep -E '^[[:space:]]*user[[:space:]]*=' /etc/libvirt/qemu.conf
getent passwd qemu
getent passwd libvirt-qemu
getent group libvirt
getent group kvm
```

Não presumir usuário `qemu` apenas pelo nome Fedora.

## Rede

NetworkManager conforme a fixture:

```bash
nmcli general status
nmcli device status
nmcli connection show
nmcli checkpoint --timeout 60 -- "$INTERFACE"
```

Bridge candidata:

```bash
nmcli connection add type bridge ifname br0 con-name br0
nmcli connection add type ethernet slave-type bridge \
  ifname "$INTERFACE" master br0 con-name "br0-$INTERFACE"
nmcli connection up br0
```

O rollback precisa restaurar UUID, rota, DNS e estado da conexão original.

## Firewalld

```bash
firewall-cmd --state
firewall-cmd --get-active-zones
firewall-cmd --get-zone-of-interface="$INTERFACE"
sudo firewall-cmd --permanent --zone="$ZONA" --add-interface=br0
sudo firewall-cmd --reload
```

O provider deve tratar separadamente estado runtime e permanent e restaurar a zona original no rollback.

## SELinux e armazenamento

Nunca usar `setenforce 0` como solução. Consultas e rotulagem candidatas:

```bash
getenforce
ls -Zd /vm
semanage fcontext -a -t virt_image_t '/vm(/.*)?'
sudo restorecon -Rv /vm
```

`semanage` pode exigir pacote adicional; o adaptador deve resolvê-lo por capability. Uma regra existente deve ser preservada/restaurada transacionalmente.

## Novos executáveis candidatos

```text
akmods, dnf, dracut, firewall-cmd, getenforce, grub2-mkconfig, grubby,
ls, modinfo, nmcli, restorecon, rpm, semanage, virt-host-validate
```

Veja também [`common.md`](common.md).
