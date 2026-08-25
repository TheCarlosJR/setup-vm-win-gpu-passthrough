# Tarefas — Perfis de pacotes APT e pacman

> **Status:** todas abertas; baseline existente não implica conclusão destas tarefas.
> **Escopo:** convergência I10 e alvos I14 individuais; sem NTFS.
> **Dependências:** I8/I9 antes de I10; I13 antes de I14.
> **Gate:** teste direcionado, gate canônico e qualificação separada por alvo.

- [ ] 1. Caracterizar o comportamento APT atual de Ubuntu e Pop!_OS por capability e pós-condição.
- [ ] 2. Definir o contrato puro de catálogo/plano e a interface Bash de efeitos de pacote.
- [ ] 3. Migrar uma chamada APT de cada vez, preservando mensagens, confirmação e status.
- [ ] 4. Tratar `xmlstarlet` como dependência transitória até a busca de consumidores de I10 ficar vazia.
- [ ] 5. Remover `xmlstarlet` em I10 sem remover `virt-xml-validate`.
- [ ] 6. Validar bootstrap de ferramentas antes do uso e diagnóstico sem instalação automática.
- [ ] 7. Validar estratégia NVIDIA do baseline Ubuntu/Pop!_OS sem promover outro hardware.
- [ ] 8. Acrescentar gates estáticos de fronteira e chamadas de gerenciador em I10.
- [ ] 9. Implementar provider Debian somente em I14.1.
- [ ] 10. Qualificar Debian em campanha própria antes de promover suporte.
- [ ] 11. Implementar provider pacman de Arch somente em I14.3.
- [ ] 12. Qualificar Arch em campanha própria antes de promover suporte.
- [ ] 13. Implementar as diferenças de CachyOS somente em I14.4.
- [ ] 14. Qualificar CachyOS em campanha própria antes de promover suporte.
- [ ] 15. Confirmar que nenhum item desta spec migra ou monta conteúdo NTFS.
