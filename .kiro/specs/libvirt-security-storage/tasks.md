# Tarefas — Libvirt, segurança e armazenamento

> **Status:** todas abertas como reconciliação/deltas; entregas I3 são registradas, não remarcadas em bloco.
> **Escopo:** preservar core I3, fechar identidades I6, modularizar efeitos I9 e adicionar providers somente em I14.
> **Dependências:** I3 histórico → I6/I8/I9 → I13/I14.
> **Gate:** regressões dirigidas e gate da fase correspondente; hardware real separado.

- [ ] 1. Mapear consumidores atuais de `domain_xml.py`, `network_xml.py` e `qemu_image.py`.
- [ ] 2. Preservar cardinalidade, determinismo e conteúdo XML não gerenciado nas regressões I3.
- [ ] 3. Integrar REQ-DISK-IDENTITY e REQ-USB-IDENTITY quando I6 estiver aprovado.
- [ ] 4. Caracterizar runtime libvirt monolítico, modular e socket-activated sem efeitos reais.
- [ ] 5. Caracterizar identidade QEMU e preflight de travessia/permissão de storage.
- [ ] 6. Extrair efeitos libvirt/storage para módulos `lib/shell/` durante I9, um caminho por vez.
- [ ] 7. Extrair efeitos AppArmor preservando a política atual e as fachadas.
- [ ] 8. Manter SELinux bloqueado até o provider I14 aplicável ser implementado.
- [ ] 9. Convergir consumidores XML para candidato, validação, apply, releitura e pós-condição.
- [ ] 10. Validar hooks Bash puros, instalação atômica e lifecycle fail-closed.
- [ ] 11. Corrigir garantias de backup conforme fidelidade real do destino.
- [ ] 12. Validar NVRAM/SWTPM por XML/API e manifesto/checksums.
- [ ] 13. Unificar unidades e cálculo de espaço QCOW2 com limites seguros.
- [ ] 14. Executar regressões herméticas sem GPU/libvirt/storage reais.
- [ ] 15. Qualificar providers e hardware somente nas campanhas reais das fases correspondentes.
