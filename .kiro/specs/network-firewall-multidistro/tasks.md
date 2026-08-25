# Tarefas — Rede e firewall multi-distro

> **Status:** todas abertas; implementação parcial atual será preservada e caracterizada.
> **Escopo:** I7 base, I9 efeitos/Airlock, I14 providers.
> **Dependências:** I6.0/I6 → I7 → I8/I9/I10 → I13 → I14.
> **Gate:** Gate I7, Gate I9 e qualificação individual de provider.

- [ ] 1. Caracterizar a transação atual da etapa 60 e o verifier atual da etapa 61.
- [ ] 2. Definir schema de snapshots/fingerprints de uplink, rota, bridge, libvirt, XML e consumidores.
- [ ] 3. Implementar `libexec/passthrough_core/network.py` em I7 sem comandos do host.
- [ ] 4. Implementar validação CIDR/rotas e planos bridge/NAT backend-neutral.
- [ ] 5. Implementar `recovery_id`, bundle privado e mapeamento local por operação.
- [ ] 6. Implementar commit/expiração/limpeza idempotente dos bundles.
- [ ] 7. Integrar fingerprints, confirmação, traps, rollback e verificação semântica no Bash.
- [ ] 8. Injetar falha antes/depois de cada ação e de cada ação de rollback.
- [ ] 9. Executar Gate I7 sem criar provider de nova distro.
- [ ] 10. Criar `lib/shell/network-effects.sh` em I9 e migrar um efeito por vez.
- [ ] 11. Implementar REQ-AIRLOCK-VERIFY reutilizando a avaliação efetiva do apply.
- [ ] 12. Cobrir `sshd -T -C`, identidade, chroot, chave, bindfs, firewall e IPv6 em testes.
- [ ] 13. Executar Gate I9 e remover o caminho mutante substituído.
- [ ] 14. Implementar NetworkManager/networkd/Wicked/firewalld somente no I14 do alvo aplicável.
- [ ] 15. Qualificar cada provider em ambiente descartável com console antes de promover suporte.
