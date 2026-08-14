# CachyOS

**Estado:** PLANEJADO — NÃO EXECUTADO PELO PROJETO  
**Fixture:** CachyOS, `ID_LIKE=arch`, UEFI, systemd-boot, NetworkManager e systemd-resolved  
**Família:** pacman, com kernel/repositórios próprios

`lib/platform.sh` rejeita atualmente `ID=cachyos`; ele não herda o perfil Arch por `ID_LIKE`. O adaptador não pode ser uma cópia cega do arquivo Arch.

## Atualização e pacotes

```bash
sudo pacman -Syu
pacman -Q "$PACOTE"
pacman -Si "$PACOTE"
sudo pacman -S --needed "$PACOTE"
```

`pacman -Sy` isolado é proibido.

Pacotes base candidatos:

```bash
sudo pacman -S --needed \
  pciutils usbutils dmidecode curl wget git htop \
  xmlstarlet rsync acl
```

Resolver a pilha QEMU disponível nos repositórios ativos:

```bash
pacman -Ss '^qemu'
pacman -Si qemu-full
pacman -Si qemu-desktop
pacman -Si qemu-system-x86

QEMU_PKG='<pacote QEMU comprovado>'
sudo pacman -S --needed \
  "$QEMU_PKG" libvirt virt-install virt-manager edk2-ovmf swtpm
```

Pós-condições:

```bash
qemu-system-x86_64 --version
qemu-img --version
virsh --connect qemu:///system version
virt-host-validate qemu
```

## Kernel e NVIDIA

O kernel CachyOS e seus headers devem ser descobertos, não inferidos somente de `uname`:

```bash
uname -r
pacman -Q | grep -E '^(linux-cachyos|linux|nvidia)'
pacman -Ss '^linux-cachyos'
pacman -Ss '^nvidia'
```

O provider deve parear o kernel instalado com o módulo/prebuilt package ou DKMS correspondente. Comandos candidatos, dependentes do resultado da detecção:

```bash
sudo pacman -S --needed nvidia-utils
sudo pacman -S --needed '<módulo NVIDIA compatível com o kernel CachyOS>'
# ou, quando escolhido explicitamente:
sudo pacman -S --needed nvidia-dkms '<headers do kernel ativo>' nvidia-utils
```

Validação:

```bash
modinfo nvidia
modprobe nvidia
nvidia-smi
```

O arquivo não fixa um pacote NVIDIA CachyOS porque nomes e disponibilidade dependem do kernel/repositório ativo.

## Initramfs

CachyOS pode usar mkinitcpio ou dracut. Detectar primeiro:

```bash
command -v mkinitcpio
command -v dracut
```

Executar somente o gerador comprovado:

```bash
sudo mkinitcpio -P
sudo dracut --regenerate-all --force
```

## Boot

A fixture usa systemd-boot:

```bash
bootctl status
```

Hosts CachyOS também podem usar GRUB ou Limine. Detectar os artefatos reais:

```bash
command -v grub-mkconfig
command -v limine-update
```

Candidatos condicionais:

```bash
sudo grub-mkconfig -o /boot/grub/grub.cfg
sudo limine-update
```

Para systemd-boot/UKI, editar a fonte real da cmdline. `bootctl update` sozinho não persiste parâmetros de kernel.

## Libvirt

```bash
systemctl status libvirtd.socket
systemctl status libvirtd.service
systemctl status virtqemud.socket
systemctl status virtqemud.service
systemctl status virtlogd.socket
systemctl status virtlogd.service

grep -E '^[[:space:]]*user[[:space:]]*=' /etc/libvirt/qemu.conf
getent passwd qemu
getent passwd libvirt-qemu
getent group libvirt
getent group kvm
```

Serviço, identidade e grupos devem resultar da sondagem, não do nome da distro.

## Rede e firewall

NetworkManager, conforme a fixture:

```bash
nmcli general status
nmcli device status
nmcli connection show
nmcli checkpoint --timeout 60 -- "$INTERFACE"
nmcli connection add type bridge ifname br0 con-name br0
```

Firewall precisa ser detectado:

```bash
systemctl is-active ufw.service
systemctl is-active firewalld.service
ufw status
firewall-cmd --state
```

Sem provider comprovado, o Airlock fica bloqueado.

## Novos executáveis candidatos

```text
dracut, firewall-cmd, grub-mkconfig, limine-update, mkinitcpio, modinfo,
nmcli, pacman, virt-host-validate
```

Veja também [`common.md`](common.md) e [`arch.md`](arch.md), sem presumir que os pacotes de kernel sejam iguais.
