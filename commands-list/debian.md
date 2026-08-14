# Debian

**Estado:** PLANEJADO — NÃO EXECUTADO PELO PROJETO  
**Fixture:** Debian 12 Bookworm, UEFI, GRUB, systemd-networkd e systemd-resolved inativo  
**Família:** APT/DPKG

`lib/platform.sh` rejeita atualmente `ID=debian`. Os comandos abaixo são o mapeamento candidato para o adaptador Debian; não constituem suporte operacional.

## Atualização e pacotes

Para automação, o adaptador planejado deve preferir `apt-get`:

```bash
sudo apt-get update
apt-get --simulate full-upgrade
sudo apt-get full-upgrade -y
apt-get --simulate autoremove
sudo apt-get autoremove -y
```

Consulta e instalação:

```bash
dpkg-query -W -f='${Status}\n' "$PACOTE"
apt-cache show "$PACOTE"
sudo apt-get install -y "$PACOTE"
```

Pacotes base candidatos:

```bash
sudo apt-get install -y \
  pciutils usbutils dmidecode curl wget git htop \
  xmlstarlet rsync acl
```

Pilha de virtualização candidata, a confirmar nos repositórios habilitados:

```bash
sudo apt-get install -y \
  qemu-system-x86 qemu-utils \
  libvirt-daemon-system libvirt-clients \
  virtinst virt-manager ovmf swtpm swtpm-tools
```

Pós-condições:

```bash
qemu-system-x86_64 --version
qemu-img --version
virsh --connect qemu:///system version
virt-install --version
```

## Validação KVM

`kvm-ok` pode existir via `cpu-checker`, mas o provider não deve depender exclusivamente dele. Candidatos:

```bash
lscpu
ls -l /dev/kvm
virt-host-validate qemu
```

`virt-host-validate` ainda não é usado pelo código atual e precisa de resolução de pacote/capability.

## NVIDIA

Não existe equivalente automático completo de `ubuntu-drivers`. Somente se `contrib`, `non-free` e `non-free-firmware` já estiverem habilitados pelo operador:

```bash
apt-cache show nvidia-detect
sudo apt-get install -y nvidia-detect
nvidia-detect
apt-cache show nvidia-driver
sudo apt-get install -y nvidia-driver
nvidia-smi
```

O adaptador não deve editar `sources.list` nem habilitar repositórios automaticamente. Sem pré-condição comprovada, a capability NVIDIA deve ser bloqueada.

## Initramfs e boot

Candidatos quando comprovados no host:

```bash
sudo update-initramfs -u -k all
sudo update-grub
```

A fixture indica GRUB, mas a implementação futura ainda deve detectar o backend real antes de mutar `/etc/default/grub`.

## Libvirt

Sondagem planejada:

```bash
systemctl status libvirtd.socket
systemctl status libvirtd.service
systemctl status virtqemud.socket
systemctl status virtqemud.service
systemctl status virtlogd.socket
systemctl status virtlogd.service
```

A identidade provável é `libvirt-qemu`, mas deve ser comprovada:

```bash
grep -E '^[[:space:]]*user[[:space:]]*=' /etc/libvirt/qemu.conf
getent passwd libvirt-qemu
getent passwd qemu
getent group libvirt
getent group kvm
```

## Rede

A fixture usa systemd-networkd, não Netplan. O provider planejado deve materializar unidades `.netdev`/`.network`, validar ownership e então usar:

```bash
networkctl list
networkctl status "$INTERFACE"
sudo networkctl reload
sudo networkctl reconfigure "$INTERFACE"
systemctl status systemd-networkd.service
ip -brief link
ip -brief address
ip route
```

Não se deve chamar `netplan` nesse perfil sem comprovar que o host realmente o adotou.

## Firewall e segurança

UFW é o provider mais próximo do fluxo atual, mas só pode ser usado se estiver instalado/configurado:

```bash
ufw status verbose
sudo ufw allow ...
sudo ufw deny ...
sudo ufw reload
```

Sem UFW/firewalld comprovado, o Airlock deve permanecer bloqueado. AppArmor também deve ser detectado em vez de presumido:

```bash
aa-status
```

## Novos executáveis candidatos

```text
aa-status, dpkg-query, networkctl, nvidia-detect, virt-host-validate
```

Os demais comandos compartilhados estão em [`common.md`](common.md).
