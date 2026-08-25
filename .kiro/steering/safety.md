# Segurança

- Operações ambíguas, evidência ausente e pós-condição não comprovada falham de forma fechada.
- Testes e implementação não alteram o host: usar fixtures, shims, mocks e raízes temporárias; não executar `sudo`, rede, firewall, boot/initramfs, disco, libvirt ou serviços reais.
- Hardware real, reboot, GPU, bootloader, rede/SSH, disco e VM exigem ambiente descartável, backup, console fora de banda e autorização explícita.
- Tratar arquivos, comandos e payloads como não confiáveis; proibir `eval`, `source` de dados e execução de conteúdo recebido.
- Dados sensíveis e identificadores locais não entram no repositório nem em artefatos publicáveis. Temporários e bundles de recuperação usam escopo privado e permissões restritas.
- Python só planeja e compara; Bash confirma, aplica, verifica e restaura.
- Nenhuma distro, CPU ou GPU é promovida por fixture. A expansão I14 ocorre somente após I13 e `BASE_QUALIFICADA`, um alvo por vez.
- Antes de I6.1, executar I6.0 exatamente como definido no plano; não inferir aprovação do gate histórico.
