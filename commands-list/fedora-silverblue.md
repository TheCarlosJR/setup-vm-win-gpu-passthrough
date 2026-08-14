# Fedora Silverblue / rpm-ostree

**Estado:** DIAGNÓSTICO SOMENTE — SEM MUTAÇÕES  
**Fixture:** Fedora 42 Silverblue, `VARIANT_ID=silverblue`, deployment ostree, UEFI, GRUB, NetworkManager e rpm-ostreed

O código atual não lê `VARIANT_ID`, não detecta rpm-ostree e rejeita `ID=fedora`. Os Specs determinam que hosts imutáveis permaneçam sem capabilities mutáveis até existir um projeto específico.

## Consultas permitidas

Estado da imagem/deployments:

```bash
rpm-ostree status
ostree admin status
systemctl status rpm-ostreed.service
```

Inventário read-only:

```bash
cat /etc/os-release
uname -r
lscpu
lspci -nnk
lsusb
lsblk
findmnt
bootctl status
systemctl list-units --type=service --type=socket
nmcli general status
nmcli device status
firewall-cmd --state
```

Virtualização, somente se já existir no host:

```bash
virsh --connect qemu:///system list --all
qemu-system-x86_64 --version
qemu-img --version
```

Essas consultas não significam que a configuração de passthrough possa ser aplicada.

## Mutações bloqueadas

O projeto não deve executar automaticamente:

```bash
rpm-ostree install ...
rpm-ostree uninstall ...
rpm-ostree kargs ...
rpm-ostree override ...
dnf install ...
dracut --regenerate-all --force
grubby --update-kernel=ALL ...
```

Também ficam bloqueados:

- instalação/atualização NVIDIA;
- alteração de initramfs, kernel args ou bootloader;
- criação de bridge persistente;
- alteração permanente do firewalld;
- instalação de regras SELinux para `/vm`;
- criação do Airlock;
- tentativa de remontar `/` ou `/usr` como gravável;
- layering de pacotes como efeito colateral de uma etapa comum.

## Motivo

`rpm-ostree` trabalha com deployments e reinicializações, não com a mesma semântica transacional de APT/DNF tradicional. Adaptar somente os nomes dos comandos quebraria rollback, pós-condições e modelo de confiança do projeto.

## Executáveis de diagnóstico específicos

```text
firewall-cmd, nmcli, ostree, rpm-ostree
```

Qualquer promoção além de diagnóstico requer Spec, adaptador, fixtures mutáveis seguras e smoke tests próprios.
