# Comandos compartilhados e inventário operacional

**Estado:** inventário do código atual Ubuntu/Pop!_OS.

Este arquivo cobre `menu.sh`, `lib/*.sh`, `etapas/*.sh`, `util/*.sh` e os hooks escritos pelas etapas 14 e 19. Os arquivos de distro explicam quais itens são específicos de cada provedor.

## Critério de inclusão

Entram executáveis externos iniciados diretamente, por `sudo`, dentro de `bash -c`/`sh -c`, por arrays, pela variável `$VIRSH` ou por scripts gerados. Não entram palavras reservadas e built-ins como `if`, `case`, `source`, `read`, `printf`, `echo`, `trap`, `return`, `[` e `[[`.

`true` e `test` entram porque também são lançados como processos por `sudo`.

## União canônica atual: 99 executáveis

```text
apt
apt-cache
apt-get
awk
basename
bash
bootctl
cat
chmod
chown
clear
cmp
cp
cut
date
df
dirname
dmesg
dmidecode
dpkg
du
find
findmnt
flock
free
fwupdmgr
getent
getfacl
grep
groupadd
groupdel
gzip
head
id
install
ip
journalctl
kernelstub
kvm-ok
ln
logger
ls
lsblk
lscpu
lsmod
lspci
lsusb
mkdir
mktemp
modprobe
mount
mountpoint
mv
netplan
nohup
nproc
nvidia-smi
osinfo-query
paste
ping
python3
qemu-img
qemu-system-x86_64
readlink
reboot
rm
rsync
sed
setfacl
sh
sleep
sort
ssh-keygen
sshd
stat
sudo
systemctl
tail
tee
test
touch
tr
true
ubuntu-drivers
udevadm
ufw
umount
uname
update-grub
update-initramfs
useradd
userdel
usermod
virsh
virt-install
virt-manager
virt-xml-validate
wc
xmlstarlet
```

Itens claramente vinculados ao perfil atual — `apt*`, `dpkg`, `ubuntu-drivers`, `kernelstub`, `kvm-ok`, `netplan`, `ufw`, `update-grub` e `update-initramfs` — possuem substitutos ou políticas diferentes nos demais arquivos.

## Comandos portáveis por função

### Shell, privilégio e processo

```text
bash, sh, sudo, true, test, clear, nohup, sleep, reboot
```

### Hardware e kernel

```text
dmesg, dmidecode, free, gzip, lscpu, lsmod, lspci, lsusb, lsblk,
modprobe, nproc, nvidia-smi, udevadm, uname
```

### Virtualização

```text
osinfo-query, python3, qemu-img, qemu-system-x86_64, virsh,
virt-install, virt-manager, virt-xml-validate, xmlstarlet
```

O wrapper atual é:

```bash
VIRSH="virsh --connect qemu:///system"
```

Os nomes `define`, `dumpxml`, `domstate`, `start`, `shutdown`, `destroy`, `net-*`, `snapshot-*`, `attach-device` e `detach-device` são subcomandos de `virsh`, não executáveis separados.

### Sistema, contas e armazenamento

```text
flock, getent, getfacl, groupadd, groupdel, id, logger, mount,
mountpoint, setfacl, ssh-keygen, sshd, systemctl, umount, useradd,
userdel, usermod
```

### Arquivos e texto

```text
awk, basename, cat, chmod, chown, cmp, cp, cut, date, df, dirname, du,
find, findmnt, grep, head, install, ip, ln, ls, mkdir, mktemp, mv, paste,
ping, readlink, rm, rsync, sed, sort, stat, tail, tee, touch, tr, wc
```

## Wrappers e execução indireta

### Sudo

```bash
sudo -n true
sudo -v
sudo -n true
sudo test ...
sudo -u "$IDENTIDADE" sh -c '...'
sudo bash -c '...'
sudo -n bash -c '...'
```

Não existe uso operacional de `eval` nem do executável `env`.

### Python embutido

`python3` recebe programas por heredoc ou descritor para processar XML, JSON, topologia, snapshots e backups. Esses programas usam a biblioteca padrão e não iniciam subprocessos adicionais.

## Mapa dos scripts atuais

As funções chamadas de `lib/common.sh` podem acrescentar comandos compartilhados à lista de cada entrypoint.

### Entrada e bibliotecas

| Arquivo | Executáveis próprios/principais |
|---|---|
| `menu.sh` | `bash`, `clear`, `dirname` |
| `lib/platform.sh` | `getent`, `lscpu`, `qemu-system-x86_64`, `sudo`, `systemctl`, `update-initramfs` |
| `lib/common.sh` | `apt-get`, `awk`, `bash`, `bootctl`, `cat`, `chmod`, `chown`, `cmp`, `cp`, `cut`, `date`, `dirname`, `findmnt`, `getent`, `getfacl`, `grep`, `id`, `kernelstub`, `ln`, `lscpu`, `lspci`, `lsblk`, `mkdir`, `mktemp`, `mountpoint`, `mv`, `paste`, `python3`, `qemu-img`, `readlink`, `reboot`, `rm`, `sed`, `setfacl`, `sleep`, `sort`, `stat`, `sudo`, `tail`, `tee`, `true`, `update-grub`, `virsh` |

### Etapas

| Arquivo | Executáveis próprios/principais |
|---|---|
| `etapas/00-inventario.sh` | `apt-get`, `date`, `dmesg`, `dmidecode`, `grep`, `ln`, `lscpu`, `lspci`, `lsblk`, `mkdir`, `mktemp`, `mv`, `readlink`, `rm`, `tee` |
| `etapas/01-verificar-bios.sh` | `awk`, `cat`, `dmesg`, `grep`, `lscpu`, `sudo` |
| `etapas/02-detectar-config.sh` | `awk`, `basename`, `cat`, `chmod`, `cp`, `date`, `find`, `findmnt`, `grep`, `id`, `ip`, `ls`, `lscpu`, `lspci`, `lsblk`, `mkdir`, `mktemp`, `mountpoint`, `mv`, `readlink`, `rm`, `sed`, `sort`, `systemctl`, `tail`, `tr`, `wc` |
| `etapas/10-atualizar-sistema.sh` | `apt`, `apt-get`, `awk`, `dpkg`, `fwupdmgr`, `reboot`, `sort`, `tail`, `uname` |
| `etapas/11-driver-nvidia.sh` | `apt`, `apt-cache`, `grep`, `head`, `lspci`, `nvidia-smi`, `ubuntu-drivers` |
| `etapas/12-pacotes-base.sh` | `apt`, `dmidecode`, `dpkg`, `head`, `lspci`, `lsusb`, `xmlstarlet` |
| `etapas/13-diretorios.sh` | `chmod`, `chown`, `getent`, `getfacl`, `groupadd`, `ls`, `mkdir`, `sed`, `setfacl`, `usermod` |
| `etapas/14-working-disk.sh` | `findmnt`, `mountpoint`, `readlink` |
| `etapas/20-virtualizacao.sh` | `apt`, `dpkg`, `head`, `kvm-ok`, `ls`, `qemu-system-x86_64`, `systemctl`, `virsh` |
| `etapas/21-usuario-grupos.sh` | `chmod`, `chown`, `getent`, `getfacl`, `grep`, `groupadd`, `id`, `mktemp`, `rm`, `setfacl`, `sh`, `stat`, `sudo`, `systemctl`, `test`, `usermod`, `virsh` |
| `etapas/30-iommu-vfio.sh` | `awk`, `bash`, `cat`, `date`, `dmesg`, `grep`, `kernelstub`, `lscpu`, `lsmod`, `lspci`, `mkdir`, `sed`, `tail`, `tee`, `update-grub`, `update-initramfs` |
| `etapas/40-criar-vm.sh` | `chmod`, `df`, `getfacl`, `grep`, `ln`, `mkdir`, `mktemp`, `nohup`, `nproc`, `osinfo-query`, `qemu-img`, `readlink`, `rm`, `sed`, `sh`, `stat`, `sudo`, `systemctl`, `tail`, `tee`, `test`, `touch`, `tr`, `virsh`, `virt-install`, `virt-manager`, `xmlstarlet` |
| `etapas/41-instalacao-windows.sh` | `cat`, `nohup`, `virsh`, `virt-manager` |
| `etapas/50-hooks-gpu-hd1.sh` | `awk`, `basename`, `bash`, `cat`, `chmod`, `cp`, `date`, `dirname`, `find`, `findmnt`, `flock`, `grep`, `install`, `lsblk`, `mkdir`, `mktemp`, `mv`, `rm`, `stat`, `sudo`, `systemctl`, `test`, `udevadm`, `virsh`, `xmlstarlet` |
| `etapas/51-usb-passthrough.sh` | `cat`, `cut`, `grep`, `lsusb`, `mktemp`, `rm`, `sed`, `virsh`, `xmlstarlet` |
| `etapas/52-cpu-pinning-hugepages.sh` | `awk`, `grep`, `kernelstub`, `lscpu`, `mktemp`, `python3`, `reboot`, `rm`, `update-grub`, `virsh`, `virt-xml-validate` |
| `etapas/53-cpu-isolation.sh` | `grep`, `gzip`, `kernelstub`, `lscpu`, `mktemp`, `python3`, `reboot`, `rm`, `uname`, `update-grub`, `virsh`, `virt-xml-validate` |
| `etapas/60-rede-bridge.sh` | `awk`, `cmp`, `cp`, `date`, `grep`, `install`, `ip`, `mkdir`, `mktemp`, `netplan`, `ping`, `rm`, `sed`, `sudo`, `test`, `virsh`, `xmlstarlet` |
| `etapas/61-airlock.sh` | `apt`, `chmod`, `chown`, `cp`, `date`, `dpkg`, `findmnt`, `getent`, `grep`, `groupadd`, `groupdel`, `id`, `install`, `ip`, `mkdir`, `mktemp`, `mount`, `mountpoint`, `mv`, `rm`, `sed`, `ssh-keygen`, `sshd`, `sudo`, `systemctl`, `tee`, `test`, `touch`, `ufw`, `umount`, `useradd`, `userdel` |
| `etapas/70-trim-discard.sh` | `cp`, `lsblk`, `mkdir`, `mktemp`, `python3`, `rm`, `sed`, `virsh`, `virt-xml-validate`, `xmlstarlet` |

### Utilitários

| Arquivo | Executáveis próprios/principais |
|---|---|
| `util/atualizar-host.sh` | `apt`, `bash`, `date`, `dmesg`, `grep`, `head`, `nvidia-smi`, `reboot`, `virsh` |
| `util/backup-vm.sh` | `basename`, `chmod`, `cut`, `date`, `df`, `du`, `grep`, `head`, `install`, `mkdir`, `mktemp`, `python3`, `qemu-img`, `rm`, `rsync`, `sed`, `sleep`, `tail`, `tee`, `tr`, `virsh` |
| `util/diagnostico.sh` | `bash`, `cat`, `date`, `dmesg`, `findmnt`, `free`, `grep`, `journalctl`, `lspci`, `lsmod`, `mkdir`, `mount`, `nvidia-smi`, `sudo`, `tail`, `tee`, `uname`, `virsh` |
| `util/listar-grupos-iommu.sh` | `lspci` |
| `util/recuperar-gpu.sh` | `basename`, `cat`, `chmod`, `chown`, `flock`, `install`, `modprobe`, `nvidia-smi`, `readlink`, `rm`, `sleep`, `stat`, `systemctl`, `tee`, `test`, `touch`, `virsh` |
| `util/snapshot-vm.sh` | `date`, `python3`, `virsh` |

## Hooks gerados

| Hook | Executáveis |
|---|---|
| Dispatcher global `qemu` | `cat`, `chmod`, `mktemp`, `rm` e execução dos hooks encontrados |
| `prepare/begin/01-gpu-preflight.sh` | `awk`, `basename`, `chmod`, `chown`, `findmnt`, `flock`, `grep`, `install`, `lsblk`, `mktemp`, `modprobe`, `mv`, `nvidia-smi`, `readlink`, `rm`, `sed`, `sleep`, `stat`, `systemctl`, `touch`, `udevadm` |
| `start/begin/01-gpu-vfio-check.sh` | `awk`, `basename`, `lsblk`, `readlink`, `sleep`, `udevadm` |
| `release/end/01-gpu-restore.sh` | `basename`, `chmod`, `chown`, `flock`, `install`, `modprobe`, `nvidia-smi`, `readlink`, `rm`, `sleep`, `stat`, `systemctl`, `touch` |
| `00-airlock.sh` | `findmnt`, `logger`, `mkdir`, `mount`, `mountpoint`, `readlink` |

## Relacionados, mas não executados diretamente

- `swtpm` é instalado/sondado, mas iniciado pelo libvirt.
- `curl`, `git`, `htop` e `wget` são instalados, mas não chamados pelos scripts atuais.
- `bridge-utils` é instalado, mas `brctl` não é chamado.
- `python3 -m http.server` e `less` aparecem apenas em instruções manuais.
