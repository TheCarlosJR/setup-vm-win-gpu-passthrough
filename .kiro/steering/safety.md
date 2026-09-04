# Segurança

- Operações ambíguas, evidência ausente e pós-condição não comprovada falham de forma fechada.
- Testes e implementação não alteram o host: usar fixtures, shims, mocks e raízes temporárias; não executar `sudo`, rede, firewall, boot/initramfs, disco, libvirt ou serviços reais.
- Etapas mutantes exigem `sudo` interativo e são executadas pelo operador em terminal próprio; o assistente entrega o bloco de comandos, não o executa. Só `--verificar` e as suítes rodam sem privilégio.
- Hardware real, reboot, GPU, bootloader, rede/SSH, disco e VM exigem ambiente descartável, backup, console fora de banda e autorização explícita.
- Tratar arquivos, comandos e payloads como não confiáveis; proibir `eval`, `source` de dados e execução de conteúdo recebido. Vale também para catálogos de mensagem (I9B): catálogo é dado inerte.
- Dados sensíveis e identificadores locais não entram no repositório nem em artefatos publicáveis. Temporários e bundles de recuperação usam escopo privado e permissões restritas.
- Python só planeja e compara; Bash confirma, aplica, verifica e restaura. Hooks libvirt são Bash puro, autossuficientes e independentes do checkout.
- Nenhuma distro, CPU ou GPU é promovida por fixture. A expansão I14 ocorre somente após I13 e `BASE_QUALIFICADA`, um alvo por vez.
- Nunca construir trabalho em diretório temporário: todo arquivo nasce na árvore do repositório e entra no manifesto da fase em `tests/manifests/`. Foi assim que a infraestrutura de I9B se perdeu em 02/09/2026.
- Nunca marcar checkbox por inferência: `[x]` exige teste dirigido e gate aprovado; `[~]` registra evidência e pendências; `[H]` depende de hardware real.
- Antes de editar, rodar `git status --short` e preservar alterações do usuário; nunca `git reset --hard`, `git clean` ou checkout destrutivo. Commit, tag e push só com pedido explícito.
- Kiro e Claude Code executam o mesmo plano em alternância (regra 21 da seção 0.1): antes de trocar de ferramenta, commitar ou registrar o estado na seção 12 e deixar `git status --short` legível; nunca editar o checkout enquanto a outra ferramenta roda o gate; memória privada de ferramenta, fora do repositório, não é fonte de verdade. Ao mudar o cabeçalho do plano, refrescar `product.md` e as linhas `> **Status:**` das specs no mesmo commit (regra 20).
