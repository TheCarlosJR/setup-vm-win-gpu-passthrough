# Design — Boot e initramfs multi-distro

> **Status (05/09/2026):** baseline I5 mantido; I9.3 consolidou `lib/shell/boot.sh`; I9.13 fechou REQ-BOOT-POSCONDICAO para GRUB (commit `39440f2`, prova do `grub.cfg` regenerado no apply e no rollback); I9.12 tirou a reserva de HugePages e o isolamento persistente do perfil retornável (etapas 17 e 18); em 05/09/2026 a etapa 17 deixou de gravar QUALQUER parâmetro de HugePages no boot, e `--desfazer` passou a ser o único caminho que toca essas chaves, apenas para removê-las. Gate I9 aprovado e observado em 05/09/2026; a fase I9 está encerrada. Checkboxes abaixo congelados até o alinhamento formal em I11.4 (tabela de coordenação do `PLANO-FINALIZACAO.md`); não reimplementar o que já existe. Intel continua bloqueado até I14B.
> **Escopo:** manter o baseline e preparar expansão sem segundo caminho mutante.
> **Dependências:** I8/I9 para modularização; I14B para Intel; providers de distro em seus I14.
> **Gate:** regressões I5, REQ-BOOT-POSCONDICAO e gate canônico.

## Arquitetura atual

```text
etapas 11/17/18
   |
   +--> lib/python-core.sh --> passthrough_core/cpu.py (cálculo puro)
   |
   +--> lib/shell/boot.sh (snapshot, aplicação, verificação e rollback)
```

`lib/shell/boot.sh` é a implementação canônica de efeitos; expansões são feitas nele ou em módulos shell coerentes de I9, nunca numa árvore paralela. O Python produz intenções e valida cálculos, sem executar GRUB, kernelstub, initramfs ou reboot.

## Estado por componente

- **Implementado em I5:** cálculo de CPU/topologia, efeitos transacionais de boot, baseline GRUB/kernelstub/update-initramfs e testes associados.
- **Parcial:** consolidação de `common.sh`, resolução futura por `platform.py` e documentação completa de pós-condições.
- **Futuro I14B:** eixo Intel e `intel_iommu=on`, somente com hardware real.
- **Futuro por provider I14:** systemd-boot, Limine, mkinitcpio, dracut ou `update-bootloader` apenas quando o alvo aprovado realmente os exigir.

## Estado e transação

O modelo separa boot manager, fonte de cmdline e gerador. `BOOTLOADER` permanece enum/configuração e override legado, comparado com evidência runtime. O plano lista chaves removidas/adicionadas, fonte canônica, artefatos, initramfs e rollback.

Bash captura snapshot privado, aplica após confirmação, relê a fonte, regenera pelo provider comprovado e verifica artefatos. Qualquer falha restaura fontes e artefatos e verifica a restauração. O resultado nunca recomenda reboot se REQ-BOOT-POSCONDICAO estiver incompleto.

## Hardware

O baseline é AMD. `cpu.py` calcula intenção e valida partições/topologia; Bash revalida CPU, PCI, IOMMU e memória imediatamente antes do efeito. Intel permanece modelado/bloqueado até I14B; fixture não equivale a qualificação.

## Testes

Preservar regressões I5 e acrescentar matriz por provider somente quando implementado. Wrappers simulam fonte, regenerador, artefato, falha e rollback em root temporária. Smoke tests reais exigem console de recuperação e autorização explícita.
