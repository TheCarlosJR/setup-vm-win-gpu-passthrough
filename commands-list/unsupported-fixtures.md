# Fixtures sem lista operacional

Os casos abaixo exercitam detecção, isolamento e segurança. Eles não representam distribuições suportadas e não devem receber comandos mutáveis.

## Nebula (`unknown-derivative`)

```text
ID=nebula
ID_LIKE="ubuntu debian"
PRESENT_COMMAND=apt-get
```

**Estado:** REJEITADO atualmente; futuramente `family-unverified`.

A presença de `apt-get` e `ID_LIKE` não autoriza usar a lista Ubuntu/Debian. No máximo, o detector pode coletar evidências read-only:

```bash
cat /etc/os-release
command -v apt-get
systemctl list-unit-files
bootctl status
```

Antes de qualquer mutação seriam necessárias comprovações de pacote, boot, initramfs, rede, firewall, libvirt e segurança.

## Orion (`unknown-distro`)

```text
ID=orion
ID_LIKE=
PRESENT_COMMAND=none
```

**Estado:** REJEITADO/diagnóstico.

Não há família conhecida nem gerenciador declarado. Apenas inventário read-only genérico é aceitável:

```bash
cat /etc/os-release
uname -a
lscpu
lspci -nnk
lsblk
findmnt
systemctl list-units
```

## `malicious-os-release`

**Estado:** REJEITADO por segurança.

É um fixture malformado para provar que `/etc/os-release` deve ser interpretado literalmente e nunca executado com `source`, `.` ou `eval`.

Regras:

```text
- não executar o conteúdo;
- não expandir substituição de comando;
- não confiar em ID/ID_LIKE inválidos;
- falhar antes de qualquer mutação;
- registrar diagnóstico sem expor dados sensíveis.
```

## Por que não existem `nebula.md` ou `orion.md`

Criar um arquivo de comandos por esses nomes sugeriria suporte inexistente. Eles permanecem reunidos aqui até que uma distribuição real receba perfil exato, adaptadores implementados e validação operacional.
