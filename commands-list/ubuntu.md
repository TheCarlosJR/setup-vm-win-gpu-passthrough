# Ubuntu

**Estado:** IMPLEMENTADO  
**Seleção atual:** correspondência exata `ID=ubuntu`  
**Fixture:** Ubuntu 26.04, UEFI, GRUB, NetworkManager e systemd-resolved

A versão da fixture é dado de teste; o código atual não usa `VERSION_ID` para liberar ou bloquear o perfil.

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

O script interpreta separadamente ausência de atualização, atualização disponível e falha do `fwupdmgr`.

## Consulta e instalação de pacotes

```bash
dpkg -s "$PACOTE"
apt-cache show "$PACOTE"
sudo apt install -y "$PACOTE"
```

Pacotes base atuais:

```bash
sudo apt install -y \
  pciutils usbutils dmidecode curl wget git htop \
  xmlstarlet rsync acl xorriso guestfs-tools
```

Pilha de virtualização atual:

```bash
sudo apt install -y \
  qemu-system-x86 qemu-utils \
  libvirt-daemon-system libvirt-clients bridge-utils \
  virt-manager ovmf swtpm swtpm-tools virtinst
```

Validações pós-instalação:

```bash
qemu-system-x86_64 --version
qemu-img --version
virsh --connect qemu:///system version
virt-install --version
virt-manager --version
```

`kvm-ok` é instalado por meio de `cpu-checker` quando necessário:

```bash
sudo apt install -y cpu-checker
kvm-ok
```

## NVIDIA

```bash
sudo apt install -y ubuntu-drivers-common
LC_ALL=C ubuntu-drivers devices
apt-cache show "$PACOTE_RECOMENDADO"
sudo apt install -y "$PACOTE_RECOMENDADO"
nvidia-smi
```

O pacote instalado é o marcado como `recommended`. O script não escolhe simplesmente o maior número encontrado em `nvidia-driver-*`.

## Initramfs e boot

Initramfs:

```bash
sudo update-initramfs -u -k all
```

GRUB:

```bash
sudo update-grub
```

Antes da alteração, o código reúne evidências com `bootctl status`, entradas do loader e configuração do GRUB. No perfil Ubuntu, o backend mutável permitido é GRUB.

## Libvirt

O código sonda runtime monolítico e modular:

```bash
systemctl status libvirtd.socket
systemctl status libvirtd.service
systemctl status virtqemud.socket
systemctl status virtqemud.service
systemctl status virtlogd.socket
systemctl status virtlogd.service
```

Conforme o estado da unidade:

```bash
sudo systemctl enable --now "$UNIDADE"
sudo systemctl start "$UNIDADE"
```

A identidade QEMU é resolvida por `/etc/libvirt/qemu.conf` e NSS:

```bash
getent passwd libvirt-qemu
getent passwd qemu
getent group libvirt
getent group kvm
```

Os nomes aceitos atualmente são `libvirt-qemu` e `qemu`; o padrão Ubuntu é `libvirt-qemu`.

## Rede

Bridge do host via Netplan:

```bash
sudo netplan generate
sudo netplan apply
ip -brief link
ip -brief address
ip route
ping -c 1 "$DESTINO"
```

O arquivo YAML é instalado de forma transacional. O modo NAT usa redes libvirt e não chama Netplan:

```bash
virsh --connect qemu:///system net-list --all
virsh --connect qemu:///system net-define "$XML"
virsh --connect qemu:///system net-start "$REDE"
virsh --connect qemu:///system net-autostart "$REDE"
```

## Firewall e airlock

```bash
sudo ufw status verbose
sudo ufw allow ...
sudo ufw deny ...
sudo ufw reload
sshd -T -C user="$USUARIO",host="$HOST",addr="$IP"
ssh-keygen -l -f "$CHAVE_PUBLICA"
```

O fluxo salva e restaura a configuração UFW durante rollback.

## Armazenamento e AppArmor

Os comandos compartilhados usam `getfacl`, `setfacl`, `chown`, `chmod`, `qemu-img` e canários sob a identidade QEMU. Caminhos AppArmor/OVMF atuais são específicos da família Ubuntu e precisam de outro provider nas demais distros.

## Executáveis específicos deste perfil

```text
apt, apt-cache, apt-get, dpkg, kvm-ok, netplan, ubuntu-drivers, ufw,
update-grub, update-initramfs
```

Veja também [`common.md`](common.md).
