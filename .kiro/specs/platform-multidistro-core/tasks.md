# Tarefas — Núcleo de plataforma multi-distro

> **Status:** parcial; somente a tarefa histórica 1 permanece marcada.
> **Escopo:** tarefas I8; providers e qualificação de novas distros pertencem a I14.
> **Dependências:** I6.0, I6 e I7 aprovados.
> **Gate:** Gate I8 e gate canônico; nenhuma fixture promove suporte.

- [x] 1. Preservar fixtures e harness isolado de plataforma já entregues historicamente.
- [ ] 2. Recaracterizar `lib/platform.sh` e os campos `PLATAFORMA_*` antes do cutover.
- [ ] 3. Definir schema fechado de fatos, origem, confiança e motivos de bloqueio.
- [ ] 4. Implementar parser puro de `os-release` em `libexec/passthrough_core/platform.py`.
- [ ] 5. Implementar resolução pura dos estados `supported`, `diagnostic-only`, `family-unverified` e `blocked`.
- [ ] 6. Modelar eixo CPU preservando AMD suportado e Intel bloqueado até I14B.
- [ ] 7. Modelar eixo GPU preservando NVIDIA suportada e demais vendors bloqueados.
- [ ] 8. Expor o cálculo por `lib/python-core.sh` sem segundo entrypoint.
- [ ] 9. Trocar o resolvedor atrás de `lib/platform.sh`, preservando guards e API pública.
- [ ] 10. Integrar a resolução autoritativa do backend libvirt ao contrato entregue em I3.
- [ ] 11. Executar fixtures, determinismo e payloads hostis; remover comparação diferencial temporária.
- [ ] 12. Executar Gate I8 e registrar que Debian/Fedora/Arch/CachyOS/openSUSE continuam sem providers mutáveis.
- [ ] 13. Planejar I14 somente após I13 e `BASE_QUALIFICADA`, um alvo por vez.
