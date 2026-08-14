# Arch Linux

**Estado:** PLANEJADO — NÃO EXECUTADO PELO PROJETO  
**Fixture:** Arch, UEFI, systemd-boot, NetworkManager e systemd-resolved  
**Família:** pacman

`lib/platform.sh` rejeita atualmente `ID=arch`. Os comandos são candidatos para o adaptador previsto nos Specs.

## Atualização e pacotes

Atualização completa obrigatória:

```bash
sudo pacman -Syu
```

É proibido implementar `pacman -Sy` seguido de instalação isolada, pois isso cria partial upgrade.

Consulta e instalação:

```bash
pacman -Q "$PACOTE"
pacman -Si "$PACOTE"
sudo pacman -S --needed "$PACOTE"
```

Pacotes base candidatos:

```bash
sudo pacman -S --needed \
  pciutils usbutils dmidecode curl wget git htop \
  xmlstarlet rsync acl
```

A divisão de pacotes QEMU muda ao longo do tempo. O adaptador deve resolver e validar uma opção disponível, sem fixar cegamente uma única alternativa:

```bash
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

## NVIDIA

Não há equivalente único de `ubuntu-drivers`. A escolha depende do kernel, headers, GPU, Secure Boot e preferência por módulo aberto/proprietário.

Consultas candidatas:

```bash
uname -r
pacman -Q | grep -E '^(linux|nvidia)'
pacman -Ss '^nvidia'
modinfo nvidia
```

Possibilidades a serem escolhidas pelo provider, nunca instaladas todas juntas:

```bash
sudo pacman -S --needed nvidia nvidia-utils
sudo pacman -S --needed nvidia-open nvidia-utils
sudo pacman -S --needed nvidia-dkms nvidia-utils linux-headers
```

Depois da instalação:

```bash
modprobe nvidia
nvidia-smi
```

## Initramfs

Detectar o gerador efetivo:

```bash
command -v mkinitcpio
command -v dracut
```

Somente o backend comprovado pode ser chamado:

```bash
sudo mkinitcpio -P
sudo dracut --regenerate-all --force
```

## Boot

A fixture usa systemd-boot:

```bash
bootctl status
```

Parâmetros devem ser persistidos na fonte real: entrada estática, `/etc/kernel/cmdline`, kernel-install ou UKI. `bootctl update` atualiza o boot manager e não substitui essa edição.

Se GRUB for comprovado em outro host Arch:

```bash
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

O destino precisa ser validado antes da escrita.

## Libvirt

Pacote e unidades precisam ser sondados:

```bash
systemctl status libvirtd.socket
systemctl status libvirtd.service
systemctl status virtqemud.socket
systemctl status virtqemud.service
systemctl status virtlogd.socket
systemctl status virtlogd.service
```

A identidade não deve ser copiada do Ubuntu:

```bash
grep -E '^[[:space:]]*user[[:space:]]*=' /etc/libvirt/qemu.conf
getent passwd qemu
getent passwd libvirt-qemu
getent group libvirt
getent group kvm
```

## Rede

A fixture usa NetworkManager. O adaptador deve trabalhar por UUID e checkpoint:

```bash
nmcli general status
nmcli device status
nmcli connection show
nmcli checkpoint --timeout 60 -- "$INTERFACE"
```

Mutações candidatas:

```bash
nmcli connection add type bridge ifname br0 con-name br0
nmcli connection add type ethernet slave-type bridge \
  ifname "$INTERFACE" master br0 con-name "br0-$INTERFACE"
nmcli connection up br0
```

O rollback deve restaurar a conexão original, não apenas apagar `br0`.

## Firewall

A fixture não prova um provider. Detectar antes de alterar:

```bash
systemctl is-active ufw.service
systemctl is-active firewalld.service
ufw status
firewall-cmd --state
```

Se nenhum provider estiver comprovado, o Airlock deve ser bloqueado.

## Novos executáveis candidatos

```text
dracut, firewall-cmd, grub-mkconfig, mkinitcpio, modinfo, nmcli,
pacman, virt-host-validate
```

Veja também [`common.md`](common.md).
