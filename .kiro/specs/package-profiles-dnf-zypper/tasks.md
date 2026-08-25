# Tarefas — Perfis DNF e Zypper

> **Status:** todas futuras e abertas.
> **Escopo:** I14.2, I14.5 e I14.6, executados individualmente.
> **Dependências:** I8–I10 e I13/`BASE_QUALIFICADA`.
> **Gate:** gate por alvo, sem promoção por fixture.

- [ ] 1. Definir fixtures sintéticas de Fedora Workstation, Tumbleweed e Silverblue.
- [ ] 2. Registrar contratos de DNF5/DNF, Zypper/RPM e `update-bootloader` sem executar o host.
- [ ] 3. Implementar a detecção pura de fatos necessários atrás da fachada de plataforma.
- [ ] 4. Implementar o provider DNF de Fedora Workstation somente em I14.2.
- [ ] 5. Resolver SELinux e demais providers Fedora por evidência runtime.
- [ ] 6. Validar repositórios ausentes e pós-condições sem habilitar terceiros.
- [ ] 7. Qualificar Fedora Workstation em ambiente descartável e registrar limitações.
- [ ] 8. Implementar o provider Zypper de Tumbleweed somente em I14.5.
- [ ] 9. Resolver AppArmor, Wicked/NetworkManager, dracut e `update-bootloader` por runtime.
- [ ] 10. Validar recusa de vendor change e mudança de repositório.
- [ ] 11. Qualificar openSUSE Tumbleweed em ambiente descartável e registrar limitações.
- [ ] 12. Implementar I14.6 como diagnóstico fail-closed de Silverblue.
- [ ] 13. Provar que Silverblue não chama DNF mutável nem tenta remontar o sistema.
- [ ] 14. Confirmar que Nobara, Leap e outros alvos não foram promovidos por inferência.
