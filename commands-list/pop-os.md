# Pop!_OS

**Estado:** IMPLEMENTADO  
**Seleção atual:** correspondência exata `ID=pop`  
**Fixture:** Pop!_OS 22.04, UEFI, systemd-boot, NetworkManager e system76-power

O perfil compartilha APT, libvirt, Netplan, UFW e a maior parte dos comandos com Ubuntu. Seus deltas implementados são pacote QEMU, NVIDIA e backend de boot.

## Atualização do sistema

```bash
sudo apt update
apt-get --simulate dist-upgrade
sudo apt full-upgrade -y
apt-get --simulate autoremove
sudo apt autoremove -y

fwupdmgr refresh --force
fwupdmgr get-updates
sudo fwupdmgr update
```

## Pacotes base

```bash
sudo apt install -y \
  pciutils usbutils dmidecode curl wget git htop \
  xmlstarlet rsync acl
```

Pilha de virtualização:

```bash
sudo apt install -y \
  qemu-kvm qemu-utils \
  libvirt-daemon-system libvirt-clients bridge-utils \
  virt-manager ovmf swtpm swtpm-tools virtinst
```

O binário validado continua sendo:

```bash
qemu-system-x86_64 --version
```

Consultas/instalações usam:

```bash
dpkg -s "$PACOTE"
apt-cache show "$PACOTE"
sudo apt install -y "$PACOTE"
```

## NVIDIA

```bash
apt-cache show system76-driver-nvidia
sudo apt install -y system76-driver-nvidia
nvidia-smi
```

`ubuntu-drivers` não é o provider NVIDIA do perfil Pop!_OS.

## Initramfs

```bash
sudo update-initramfs -u -k all
```

## Boot

O código aceita kernelstub ou GRUB conforme o loader comprovado no host.

Kernelstub:

```bash
kernelstub -p
sudo kernelstub -d "$PARAMETRO"
sudo kernelstub -a "$PARAMETRO"
```

GRUB, apenas quando detectado como backend efetivo:

```bash
sudo update-grub
```

`bootctl status` e as entradas do loader são evidência; `bootctl update` não é usado como substituto de persistência dos parâmetros.

## Libvirt

Os mesmos candidatos do perfil Ubuntu são sondados:

```bash
systemctl status libvirtd.socket
systemctl status libvirtd.service
systemctl status virtqemud.socket
systemctl status virtqemud.service
systemctl status virtlogd.socket
systemctl status virtlogd.service
```

A identidade QEMU é resolvida por `qemu.conf`/NSS, normalmente entre:

```bash
getent passwd libvirt-qemu
getent passwd qemu
getent group libvirt
getent group kvm
```

## Rede e firewall

Bridge via Netplan:

```bash
sudo netplan generate
sudo netplan apply
ip -brief link
ip -brief address
ip route
```

Firewall/airlock via UFW:

```bash
sudo ufw status verbose
sudo ufw allow ...
sudo ufw deny ...
sudo ufw reload
```

O modo NAT continua sendo gerenciado por `virsh net-*`.

## Executáveis específicos deste perfil

```text
apt, apt-cache, apt-get, dpkg, kernelstub, kvm-ok, netplan, ufw,
update-grub, update-initramfs
```

Pacotes que diferem do Ubuntu:

```text
qemu-kvm
system76-driver-nvidia
```

Veja também [`common.md`](common.md).
