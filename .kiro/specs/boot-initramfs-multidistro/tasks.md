# Tarefas — Boot e initramfs multi-distro

> **Status:** todas abertas como deltas; entregas I5 não são remarcadas por inferência.
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
