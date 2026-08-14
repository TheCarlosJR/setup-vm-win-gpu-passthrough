# openSUSE Tumbleweed

**Estado:** PLANEJADO — NÃO EXECUTADO PELO PROJETO  
**Fixture:** `ID=opensuse-tumbleweed`, UEFI, GRUB, NetworkManager e firewalld  
**Família:** Zypper/RPM, rolling release

`lib/platform.sh` rejeita atualmente esse ID. Os comandos são candidatos para a segunda onda multi-distro.

## Atualização e pacotes

Tumbleweed deve usar a política de distribuição rolling:

```bash
sudo zypper --non-interactive refresh
sudo zypper --non-interactive dup
```

Não substituir `dup` por uma política pensada para openSUSE Leap sem um perfil separado. Mudanças inesperadas de vendor/repositório devem bloquear a transação.

Consulta e instalação:

```bash
rpm -q "$PACOTE"
zypper search --installed-only "$PACOTE"
zypper info "$PACOTE"
sudo zypper --non-interactive install "$PACOTE"
```

Pacotes base candidatos:

```bash
sudo zypper --non-interactive install \
  pciutils usbutils dmidecode curl wget git htop \
  xmlstarlet rsync acl
```

A pilha de virtualização pode ser fornecida por patterns ou pacotes concretos. O provider deve consultar e registrar a escolha:

```bash
zypper patterns
zypper info -t pattern kvm_server
zypper info -t pattern kvm_tools
sudo zypper --non-interactive install -t pattern kvm_server kvm_tools
```

Alternativamente, resolver pacotes QEMU/libvirt, `virt-install`, `virt-manager`, OVMF x86 e SWTPM no snapshot suportado. Pós-condições obrigatórias:

```bash
qemu-system-x86_64 --version
qemu-img --version
virsh --connect qemu:///system version
virt-install --version
virt-host-validate qemu
```

Os nomes concretos dos pacotes ainda não são contrato do projeto.

## NVIDIA

Não existe equivalente único de `ubuntu-drivers`. O projeto não deve adicionar repositório NVIDIA automaticamente.

Somente se um repositório compatível já estiver configurado:

```bash
zypper repos
zypper search --details 'nvidia*'
zypper info '<pacote NVIDIA compatível>'
sudo zypper --non-interactive install '<pacote NVIDIA compatível>'
modinfo nvidia
nvidia-smi
```

G06, KMP, módulo aberto/proprietário e pacote userspace variam por GPU, kernel e repositório; o provider deve resolver o conjunto, não fixar um nome universal.

## Initramfs

```bash
sudo dracut --regenerate-all --force
```

Usar somente depois de confirmar dracut como gerador efetivo.

## Boot

A fixture indica GRUB. Candidatos após detectar fonte e destino:

```bash
grub2-mkconfig --version
update-bootloader --help
sudo grub2-mkconfig -o "$GRUB_CFG_COMPROVADO"
sudo update-bootloader --refresh
```

O adaptador não deve presumir um destino baseado apenas no nome da distro.

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

Unidades, identidade QEMU e grupos precisam ser comprovados no host.

## Rede

A fixture usa NetworkManager:

```bash
nmcli general status
nmcli device status
nmcli connection show
nmcli checkpoint --timeout 60 -- "$INTERFACE"
```

Outras instalações openSUSE podem usar Wicked. Detectar ownership da interface:

```bash
systemctl is-active NetworkManager.service
systemctl is-active wicked.service
wicked ifstatus all
```

Aplicação via provider comprovado:

```bash
nmcli connection add type bridge ifname br0 con-name br0
sudo wicked ifreload all
```

Nunca usar os dois providers sobre a mesma interface.

## Firewalld

```bash
firewall-cmd --state
firewall-cmd --get-active-zones
firewall-cmd --get-zone-of-interface="$INTERFACE"
sudo firewall-cmd --permanent --zone="$ZONA" --add-interface=br0
sudo firewall-cmd --reload
```

## AppArmor e armazenamento

Detectar antes de instalar regras:

```bash
aa-status
systemctl status apparmor.service
sudo apparmor_parser -r "$PERFIL"
```

Não copiar caminhos de AppArmor Ubuntu sem validar o layout openSUSE. Permissões Unix/ACL e contexto de segurança precisam de pós-condição sob a identidade QEMU.

## Novos executáveis candidatos

```text
aa-status, apparmor_parser, dracut, firewall-cmd, grub2-mkconfig, modinfo,
nmcli, rpm, update-bootloader, virt-host-validate, wicked, zypper
```

Veja também [`common.md`](common.md).
