# Listas de comandos por distribuição

Esta pasta separa os comandos porque os provedores variam por família. O índice público principal permanece em [`../comandos.md`](../comandos.md).

## Arquivos

| Arquivo | Conteúdo | Estado |
|---|---|---|
| [`common.md`](common.md) | Inventário dos scripts, wrappers e hooks | Atual |
| [`ubuntu.md`](ubuntu.md) | Ubuntu | Implementado |
| [`pop-os.md`](pop-os.md) | Pop!_OS | Implementado |
| [`debian.md`](debian.md) | Debian 12 | Planejado |
| [`arch.md`](arch.md) | Arch Linux | Planejado |
| [`cachyos.md`](cachyos.md) | CachyOS | Planejado |
| [`fedora.md`](fedora.md) | Fedora Workstation | Planejado |
| [`opensuse-tumbleweed.md`](opensuse-tumbleweed.md) | openSUSE Tumbleweed | Planejado |
| [`fedora-silverblue.md`](fedora-silverblue.md) | Fedora Silverblue/rpm-ostree | Diagnóstico somente |
| [`unsupported-fixtures.md`](unsupported-fixtures.md) | Nebula, Orion e entrada maliciosa | Rejeitados |

## Capabilities que precisam de provedor

| Capability | Ubuntu/Pop atual | Debian planejado | Arch/CachyOS planejado | Fedora planejado | openSUSE planejado |
|---|---|---|---|---|---|
| Pacotes | APT/DPKG | APT/DPKG | pacman | DNF/RPM | Zypper/RPM |
| Atualização | `apt`/`apt-get` | `apt-get` | `pacman -Syu` | `dnf upgrade --refresh` | `zypper dup` |
| NVIDIA | `ubuntu-drivers` ou System76 | `nvidia-detect`, se repositórios já existirem | kernel + módulo/DKMS | RPM Fusion já configurado | repositório NVIDIA já configurado |
| Initramfs | `update-initramfs` | `update-initramfs` | mkinitcpio ou dracut detectado | dracut | dracut |
| Boot | GRUB/kernelstub | GRUB detectado | systemd-boot/GRUB/Limine detectado | BLS/grubby ou GRUB detectado | GRUB/update-bootloader detectado |
| Rede bridge | Netplan | systemd-networkd na fixture | NetworkManager na fixture | NetworkManager | NetworkManager ou Wicked |
| Firewall | UFW | UFW quando comprovado | UFW/firewalld quando comprovado | firewalld | firewalld |
| MAC/LSM | AppArmor/path rules atuais | AppArmor se ativo | nenhum presumido | SELinux | AppArmor se ativo |

## Regras de segurança

1. O perfil exato da distro deve vencer `ID_LIKE`.
2. Derivada desconhecida começa sem mutações (`family-unverified`).
3. Nenhum adaptador pode habilitar repositório externo automaticamente.
4. `pacman -Sy` isolado é proibido; a atualização Arch deve ser uma transação completa.
5. O destino de `grub-mkconfig`/`grub2-mkconfig` precisa ser comprovado no host.
6. `bootctl update` não é equivalente a persistir parâmetros do kernel.
7. Serviço, usuário e grupos do QEMU devem ser detectados por unidades, `qemu.conf` e NSS.
8. Fedora/openSUSE não devem desativar SELinux/AppArmor para liberar `/vm`.
9. rpm-ostree permanece diagnóstico somente até existir projeto específico.

## Interpretação dos blocos

Os blocos marcados **IMPLEMENTADO** refletem chamadas atuais. Blocos **CANDIDATO** mostram a forma esperada para o adaptador, mas nomes de pacotes, unidades e destinos precisam ser confirmados antes de entrar no código.
