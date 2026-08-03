# Auditoria dos scripts e comandos — 2026-08-03

## Escopo e método

Foram revisados o orquestrador, a biblioteca compartilhada, as 20 etapas Bash,
os 6 utilitários, o teste existente e os 3 scripts PowerShell, além de
`README.md`, `Guia-QEMU-Passthrough.md`, o manual legado e o plano de correções
já presente no repositório. A revisão foi estática: nenhum serviço, VM,
bootloader, firewall, rede, GPU, disco ou configuração do host foi alterado.

Validações executadas:

- `bash -n` em todos os arquivos Bash: aprovado.
- `bash tests/test-cpu-hugepages.sh`: aprovado (`CPU_HUGEPAGES_TESTS_OK`),
  incluindo os doubles de rollback de kernelstub, GRUB e XML.
- `git diff --check`: aprovado.
- Busca de CRLF em `.sh`, `.ps1` e `.md`: nenhum encontrado.
- ShellCheck e PowerShell (`pwsh`) não estavam instalados; portanto não houve
  análise por esses parsers/linters.

Há mudanças locais não relacionadas a esta auditoria em praticamente todos os
scripts. Elas foram preservadas integralmente.

## Resultado

O núcleo de configuração, a validação de IOMMU/GPU, os hooks de GPU e a
transação de CPU/HugePages mostram evolução importante e proteções úteis. Os
achados foram corrigidos após esta revisão.

| Prioridade | Área | Achado |
|---|---|---|

## Achados detalhados

Nenhum achado pendente. As correções incluem testes sem efeitos no host para os
contratos de segurança auditados; ShellCheck e o parser PowerShell são
executados localmente quando estiverem instalados.

## Itens verificados sem achado novo

- Não há erro de sintaxe Bash, CRLF ou problema de whitespace no diff.
- O parser de configuração não usa mais `source` para `passthrough.conf`, e a
  biblioteca contém validações estritas para valores críticos.
- A etapa de IOMMU e os hooks de GPU adotam verificações de identidade/grupo e
  recuperação mais defensiva; não foi executado teste físico de bind/rebind.
- As etapas de CPU/HugePages e isolamento contam com a melhor cobertura do
  repositório; seu teste isolado passou.

## Limitações desta auditoria

Não foram executadas mutações reais em APT, firmware, bootloader, Netplan,
libvirt, GPU/VFIO, discos, SSH, UFW, bindfs ou Windows. Assim, a revisão não
substitui ensaio controlado em hardware compatível, especialmente do ciclo de
GPU, da rede e da restauração de backups.
