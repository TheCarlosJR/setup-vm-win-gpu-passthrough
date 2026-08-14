# Inventário de comandos por distribuição

> Revisão: 2026-08-13, baseada na árvore de trabalho atual.

Este é o índice mestre dos comandos usados ou planejados pelo projeto. Como os provedores de pacotes, boot, initramfs, rede, firewall e segurança diferem substancialmente entre distribuições, os detalhes ficam em `commands-list/`.

## Legenda de estado

- **IMPLEMENTADO**: o código de produção executa esses comandos atualmente.
- **PLANEJADO**: existe direção nos Specs do projeto, mas o adaptador ainda não foi implementado.
- **CANDIDATO**: equivalente técnico a validar na versão, repositórios e configuração reais do host antes da implementação.
- **DIAGNÓSTICO SOMENTE**: apenas consultas sem mutação são permitidas pelo plano atual.
- **REJEITADO**: fixture de segurança ou plataforma desconhecida, sem lista operacional.

Documentar um comando como **PLANEJADO** ou **CANDIDATO** não significa que o script já suporte aquela distribuição.

## Matriz

| Distribuição/variante | Fixture | Estado do código | Lista |
|---|---|---|---|
| Ubuntu | `ubuntu` | **IMPLEMENTADO** | [`commands-list/ubuntu.md`](commands-list/ubuntu.md) |
| Pop!_OS | `pop-os` | **IMPLEMENTADO** | [`commands-list/pop-os.md`](commands-list/pop-os.md) |
| Debian 12 | `debian` | **PLANEJADO** | [`commands-list/debian.md`](commands-list/debian.md) |
| Arch Linux | `arch` | **PLANEJADO** | [`commands-list/arch.md`](commands-list/arch.md) |
| CachyOS | `cachyos` | **PLANEJADO** | [`commands-list/cachyos.md`](commands-list/cachyos.md) |
| Fedora Workstation | `fedora` | **PLANEJADO** | [`commands-list/fedora.md`](commands-list/fedora.md) |
| openSUSE Tumbleweed | `opensuse` | **PLANEJADO** | [`commands-list/opensuse-tumbleweed.md`](commands-list/opensuse-tumbleweed.md) |
| Fedora Silverblue | `immutable` | **DIAGNÓSTICO SOMENTE** | [`commands-list/fedora-silverblue.md`](commands-list/fedora-silverblue.md) |
| Nebula, Orion e `os-release` malicioso | fixtures auxiliares | **REJEITADO** | [`commands-list/unsupported-fixtures.md`](commands-list/unsupported-fixtures.md) |

## Inventário compartilhado

O inventário dos executáveis externos presentes hoje em `menu.sh`, `lib/*.sh`, `etapas/*.sh`, `util/*.sh` e nos hooks gerados está em:

- [`commands-list/common.md`](commands-list/common.md)

A união operacional atual possui **99 executáveis externos**. Ela corresponde ao código Ubuntu/Pop!_OS. Os arquivos das demais distribuições acrescentam comandos equivalentes planejados, sempre identificados como não implementados.

## Fonte de verdade atual

`lib/platform.sh` aceita somente:

```text
ID=ubuntu
ID=pop
```

O código atual não herda suporte por `ID_LIKE`. Portanto:

- Debian não é aceito apenas por compartilhar APT;
- CachyOS não é aceito apenas por declarar `ID_LIKE=arch`;
- uma derivada Ubuntu desconhecida não recebe automaticamente o perfil Ubuntu;
- Fedora Silverblue não recebe automaticamente o perfil Fedora mutável.

Além da seleção da plataforma, ainda existem chamadas diretas a APT/DPKG, Netplan, UFW, AppArmor e caminhos Ubuntu em etapas específicas. Criar os arquivos nesta pasta documenta a migração necessária, mas não remove esses bloqueios.

## Organização

- [`commands-list/README.md`](commands-list/README.md): convenções, cobertura e capabilities por família.
- [`commands-list/common.md`](commands-list/common.md): comandos compartilhados, wrappers e mapa dos scripts atuais.
- Arquivos de distro: comandos de pacote, atualização, NVIDIA, initramfs, boot, libvirt, rede, firewall e segurança.
- [`commands-list/unsupported-fixtures.md`](commands-list/unsupported-fixtures.md): casos que não devem receber comandos mutáveis.

## Regras de manutenção

Ao alterar comandos no código:

1. atualizar `commands-list/common.md` se o executável for compartilhado ou fizer parte dos 99 atuais;
2. atualizar o arquivo da distro afetada;
3. registrar claramente se o comando está implementado, planejado ou é apenas candidato;
4. não apresentar uma fixture como prova de suporte operacional;
5. não habilitar automaticamente repositórios NVIDIA de terceiros;
6. não traduzir comandos de boot mecanicamente: o backend efetivo precisa ser detectado;
7. não executar mutações em hosts imutáveis sem um Spec e adaptador próprios.
