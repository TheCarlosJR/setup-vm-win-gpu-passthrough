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
achados de prioridade alta foram corrigidos após esta revisão; permanecem os
itens de prioridade média e baixa abaixo.

| Prioridade | Área | Achado |
|---|---|---|
| Média | Snapshot | Reversão aceita VM ligada; criação não especifica modo de snapshot consistente. |
| Média | Atualização | Upgrade do host continua mesmo sem o snapshot de segurança. |
| Média | Dependências | `rsync` é usado, mas não é instalado pela etapa de dependências. |
| Média | Driver NVIDIA | Pode instalar dois meta-pacotes e escolhe fallback pela maior versão, não pela recomendada. |
| Média | Airlock | Chave pública é aceita por prefixo, sem parser criptográfico; a substituição não preserva a anterior. |
| Baixa | Documentação/testes | Promessas globais excedem a implementação e a cobertura automatizada é concentrada em CPU. |

## Achados detalhados

### A-04 — Snapshot pode reverter domínio ligado (média)

O utilitário apenas avisa quando a VM está ligada e ainda executa
`snapshot-revert` ([linhas 50–56](util/snapshot-vm.sh#L50)). A criação tampouco
declara uma política explícita de snapshot offline/live/disk-only
([linhas 37–41](util/snapshot-vm.sh#L37)).

Impacto: consistência depende do storage e do tipo de snapshot que o libvirt
deduzir; a reversão pode falhar ou produzir estado inesperado.

Correção: bloquear criar/reverter se a VM não estiver `shut off`, salvo um modo
explicitamente desenhado e documentado para snapshots live consistentes.

### A-05 — Atualização do host prossegue sem ponto de retorno da VM (média)

O utilitário tenta o snapshot, mas continua com `full-upgrade` e `autoremove`
se ele falhar ([linhas 48–67](util/atualizar-host.sh#L48)). Isso é informado ao
usuário, porém contraria a finalidade de atualização assistida com proteção
prévia.

Correção: exigir sucesso do snapshot (com VM desligada) ou confirmação textual
específica para continuar sem ele. Preferir também verificar a existência de um
backup independente recente, sem alegar que o snapshot protege o host.

### A-06 — Dependência obrigatória ausente na etapa 12 (média)

`etapas/14-docs4.sh` exige `rsync`, e `util/backup-vm.sh` também o usa, mas a
lista da etapa 12 não o instala ([linhas 13–45](etapas/12-pacotes-base.sh#L13)).
O próprio texto reconhece a lacuna ([linha 36](etapas/12-pacotes-base.sh#L36)).

Impacto: a ordem recomendada no menu pode falhar numa instalação mínima.

Correção: adicionar `rsync` à lista e ao verificador da etapa 12.

### A-07 — Seleção do driver NVIDIA é ambígua (média)

Quando os dois meta-pacotes existem, o script os adiciona à mesma instalação;
quando o meta genérico não existe, escolhe a maior versão encontrada, mesmo
declarando que isso não representa recomendação de compatibilidade
([linhas 55–83](etapas/11-driver-nvidia.sh#L55)).

Impacto: dependências conflitantes/inesperadas ou escolha de driver inadequada
para o release e hardware do host.

Correção: usar uma única estratégia: preferir `system76-driver-nvidia`; se não
estiver disponível, consultar `ubuntu-drivers` e instalar somente o pacote
marcado como recomendado. Falhar com instrução clara se não houver recomendação.

### A-08 — Instalação de chave do Airlock não valida a chave de fato (média)

`instalar_chave` aceita qualquer linha com prefixo permitido e a grava por
inteiro, sobrescrevendo a chave anterior ([linhas 180–203](etapas/61-airlock.sh#L180)).

Impacto: erro de colagem/formato só aparece no uso, e rotação acidental remove o
único meio de acesso da VM ao SFTP.

Correção: validar o conteúdo temporário via `ssh-keygen -l -f`, instalar
atomicamente e preservar backup root-only da chave anterior (ou exigir uma
confirmação de troca após mostrar fingerprints).

### A-09 — Documentação e cobertura não correspondem a todas as garantias (baixa)

O README declara que **cada** etapa é idempotente, sempre faz backup antes de
editar arquivo crítico e sempre possui critério objetivo de sucesso
([linhas 3–6](README.md#L3)). Os achados ainda listados abaixo mostram exceções concretas.
Além disso, só existe a suíte automatizada de CPU/HugePages; não há testes
isolados para parser de configuração, Docs4, backup/snapshot, Airlock, UFW ou
scripts PowerShell.

Correção: reduzir afirmações absolutas no README/guia, apontar limitações por
etapa e adicionar testes sem efeitos no host para validações puras, geração de
artefatos e rollback simulado. Quando disponível, incluir ShellCheck e parser
PowerShell no CI/local.

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
