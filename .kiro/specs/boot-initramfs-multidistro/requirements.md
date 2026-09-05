# Requisitos — Boot e initramfs multi-distro

> **Status (05/09/2026):** baseline I5 mantido; I9.3 consolidou `lib/shell/boot.sh`; I9.13 fechou REQ-BOOT-POSCONDICAO para GRUB (commit `39440f2`, prova do `grub.cfg` regenerado no apply e no rollback); I9.12 tirou a reserva de HugePages e o isolamento persistente do perfil retornável (etapas 17 e 18); em 05/09/2026 a etapa 17 deixou de gravar QUALQUER parâmetro de HugePages no boot, e `--desfazer` passou a ser o único caminho que toca essas chaves, apenas para removê-las. Gate I9 aprovado e observado em 05/09/2026; a fase I9 está encerrada. Checkboxes abaixo congelados até o alinhamento formal em I11.4 (tabela de coordenação do `PLANO-FINALIZACAO.md`); não reimplementar o que já existe. Intel continua bloqueado até I14B.
> **Escopo:** preservar `lib/shell/boot.sh`, pós-condições e compatibilidade; Intel pertence a I14B.
> **Dependências:** I5 histórico; I8/I9 para evolução; I13 antes de I14B e providers I14.
> **Gate:** testes I5 existentes, gate canônico e qualificação real por bootloader/hardware.

## Requisito 1 — Mapeamento atual

1. `lib/shell/boot.sh` DEVE permanecer o módulo de efeitos de boot existente; não deve ser recriado em outro caminho.
2. `cpu.py` DEVE continuar responsável pelo cálculo puro já entregue em I5.
3. GRUB/kernelstub e `update-initramfs` do baseline DEVEM preservar seus contratos e testes.
4. Systemd-boot, Limine, mkinitcpio, dracut e `update-bootloader` só podem ser acrescentados com o alvo I14 que os exigir e qualificar.

## Requisito 2 — Detecção e configuração

1. O SISTEMA DEVE distinguir boot manager, fonte canônica de parâmetros e gerador de initramfs.
2. Presença de binário isolado NÃO DEVE autorizar mutação.
3. Conflito de evidência DEVE bloquear e explicar os mecanismos encontrados.
4. `BOOTLOADER` DEVE permanecer enum/configuração pública e override legado compatível; não deve ser removido por esta spec.
5. Divergência entre `BOOTLOADER` e runtime DEVE bloquear até resolução explícita.

## Requisito 3 — Contrato transacional

1. Antes de qualquer efeito, Bash DEVE mostrar plano, capturar fontes/artefatos/metadados e revalidar fingerprints.
2. Aplicação DEVE preservar parâmetros não gerenciados e substituir chaves gerenciadas sem duplicação.
3. Falha de gravação, regeneração ou verificação DEVE acionar restauração e verificação do estado restaurado.
4. Python NÃO DEVE executar ferramentas de boot/initramfs; Bash mantém efeitos e rollback.

## REQ-BOOT-POSCONDICAO — Pós-condição obrigatória

1. QUANDO parâmetros forem persistidos, O SISTEMA DEVE reler a fonte canônica e o artefato gerado aplicável.
2. QUANDO initramfs for reconstruído, O SISTEMA DEVE comprovar todos os kernels/artefatos exigidos pelo provider.
3. SE persistência, artefato ou restauração não puder ser comprovada, ENTÃO O SISTEMA DEVE retornar erro e NÃO DEVE recomendar reboot.
4. Estado persistido e estado ativo do kernel DEVEM ser apresentados separadamente.
5. Reboot DEVE permanecer manual.

## Requisito 5 — Hardware

1. O baseline mutável DEVE permanecer AMD com `amd_iommu=on` e requisitos atuais de IOMMU/VFIO.
2. Intel DEVE permanecer bloqueado até I14B, com implementação e qualificação em hardware real.
3. Vendor ausente, desconhecido ou conflitante DEVE bloquear o plano.
4. PCI, grupos IOMMU, memória e topologia DEVEM ser revalidados antes da aplicação.
5. Fixture de Intel NÃO DEVE promover suporte.

## Requisito 6 — Testes e segurança

1. Testes DEVEM usar roots temporárias/wrappers, nunca boot ou initramfs reais.
2. Cada provider novo DEVE cobrir sucesso, ambiguidade, idempotência, falha e rollback não comprovado.
3. Smoke test real exige VM/host descartável e console de recuperação.
