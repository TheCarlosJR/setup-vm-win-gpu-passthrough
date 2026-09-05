# Tarefas — Boot e initramfs multi-distro

> **Status (05/09/2026):** baseline I5 mantido; I9.3 consolidou `lib/shell/boot.sh`; I9.13 fechou REQ-BOOT-POSCONDICAO para GRUB (commit `39440f2`, prova do `grub.cfg` regenerado no apply e no rollback); I9.12 tirou a reserva de HugePages e o isolamento persistente do perfil retornável (etapas 17 e 18); em 05/09/2026 a etapa 17 deixou de gravar QUALQUER parâmetro de HugePages no boot, e `--desfazer` passou a ser o único caminho que toca essas chaves, apenas para removê-las. Checkboxes abaixo congelados até o alinhamento formal em I11.4 (tabela de coordenação do `PLANO-FINALIZACAO.md`); não reimplementar o que já existe. Intel continua bloqueado até I14B.
> **Escopo:** consolidação do baseline e expansões futuras vinculadas às fases corretas.
> **Dependências:** preservar I5; executar I8/I9 antes da expansão; I14B para Intel.
> **Gate:** regressões I5 + REQ-BOOT-POSCONDICAO + gate canônico.

- [ ] 1. Recaracterizar `lib/shell/boot.sh`, `cpu.py` e os testes I5 sem alterar comportamento.
- [ ] 2. Documentar o estado normalizado de boot manager, fonte de cmdline e initramfs.
- [ ] 3. Preservar `BOOTLOADER` como enum/configuração e override legado validado.
- [ ] 4. Consolidar chamadas residuais atrás de `lib/shell/boot.sh` durante I9.
- [ ] 5. Implementar testes explícitos de REQ-BOOT-POSCONDICAO para persistência e artefatos.
- [ ] 6. Implementar testes de rollback cuja restauração não pode ser comprovada.
- [ ] 7. Preservar AMD como único eixo CPU mutável da base.
- [ ] 8. Modelar Intel como bloqueado sem habilitá-lo em I8.
- [ ] 9. Implementar Intel somente em I14B.
- [ ] 10. Qualificar Intel somente em hardware real com console de recuperação.
- [ ] 11. Acrescentar systemd-boot/Limine/mkinitcpio/dracut/`update-bootloader` somente no provider I14 que comprovar necessidade.
- [ ] 12. Qualificar cada provider de boot/initramfs em campanha própria antes de promover suporte.
