# Design — Perfis de pacotes APT e pacman

> **Status:** baseline APT existente; convergência I10 e providers I14 ainda futuros.
> **Escopo:** resolução por capability e efeitos de pacote; NTFS, boot e rede ficam fora.
> **Dependências:** `platform.py` de I8, modularização I9, convergência I10 e qualificação I13.
> **Gate:** gate canônico + boundary/static checks de I10 + campanha individual I14.

## Arquitetura híbrida

```text
etapas comuns
   |
   +--> lib/python-core.sh --> core puro (catálogo, resolução e plano)
   |
   +--> lib/shell/ e etapas (confirmação, APT/pacman, verificação e diagnóstico)
```

Não será criada uma árvore Bash paralela. Diferenças de nomes ficam em dados/contratos do provider; ferramentas de pacote nunca são executadas pelo Python.

## Estado por alvo

| Alvo | Estado atual | Fase |
|---|---|---|
| Ubuntu | mutável, APT existente; convergência parcial | base/I10 |
| Pop!_OS | mutável, APT existente; convergência parcial | base/I10 |
| Debian | diagnóstico, provider não implementado | I14.1 |
| Arch Linux | diagnóstico, pacman não implementado | I14.3 |
| CachyOS | diagnóstico, provider não implementado | I14.4 |

Cada I14 é executado e qualificado separadamente depois de `BASE_QUALIFICADA`.

## Catálogo

Capabilities representam resultados concretos: hardware PCI/USB, rede, sincronização de arquivos, QEMU, libvirt, firmware, TPM, SSH, firewall, bindfs e firmware update. Pacotes virtuais/transitórios são apenas candidatos. `xmlstarlet` não integra o catálogo futuro: é dependência residual de compatibilidade até a remoção controlada em I10. `virt-xml-validate` continua válido.

Migração ou montagem de NTFS não pertence ao catálogo nem a este spec.

## Providers e efeitos

O provider APT preserva Ubuntu/Pop!_OS e migra chamadas diretas sem mudar políticas. O provider pacman só nasce em I14.3 e é reutilizado por CachyOS em I14.4 após diferenças explícitas. Cada operação separa consulta, plano, confirmação, aplicação e pós-condição. Não há rollback automático de transação de pacote; nova execução deve ser idempotente e diagnosticar estado parcial.

## NVIDIA

O plano valida vendor/BDF, perfil, kernel e Secure Boot. Ubuntu nunca seleciona System76 por disponibilidade; Pop!_OS só usa System76 quando o perfil exato permitir. Arch/CachyOS não são antecipados por fixture.

## Testes

Wrappers sintéticos registram argv sem rede. Cobrir pacote real, virtual, transitório, ausente, falha parcial, dry-run e segunda execução. Gates de I10 comprovam fronteiras e ausência de consumidor operacional de `xmlstarlet` antes de removê-lo. Smoke tests I14 usam ambiente descartável e não promovem hardware por inferência.
