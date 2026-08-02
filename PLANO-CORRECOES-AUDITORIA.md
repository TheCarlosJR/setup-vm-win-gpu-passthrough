# Plano de correções da auditoria

## Objetivo

Tornar o conjunto de scripts seguro para execução gradual no host principal, corrigindo os riscos identificados na auditoria estática de 1 de agosto de 2026. Este documento preserva o contexto, a ordem de implementação, os critérios de sucesso e as limitações de validação.

## Regra de execução

1. Este arquivo deve existir antes de qualquer alteração de implementação.
2. Rodar primeiro os testes estáticos de linha de base que não alteram o host.
3. Alterar os scripts em blocos coerentes e validar cada bloco.
4. Não executar etapas que alterem GPU, discos, bootloader, rede, firewall, SSH, libvirt ou serviços deste host durante o desenvolvimento.
5. Testes funcionais destrutivos ou dependentes de hardware real devem ficar documentados para execução manual em uma instalação descartável ou depois de backup integral.

## Diagnóstico preservado

### Pontos positivos

- Configuração central e detecção de GPU, CPU, RAM, discos, bootloader e rede.
- Uso de UUID e `/dev/disk/by-id` para armazenamento persistente.
- Proteções iniciais contra seleção do disco raiz e do HD2.
- Confirmações explícitas para operações destrutivas.
- Backups de `fstab` e XML em diversas etapas.
- Boa separação entre instalação, otimização, manutenção e recuperação.
- Documentação extensa.
- A etapa `60-rede-bridge.sh` possui uma transação de rede bem estruturada.

### Bloqueadores encontrados

1. `util/recuperar-gpu.sh` apenas avisa quando a VM está ligada e continua para o unbind da GPU.
2. `etapas/50-hooks-gpu-hd1.sh` sobrescreve o hook global `/etc/libvirt/hooks/qemu`, não preserva configuração existente e ignora falhas críticas de bind/unbind.
3. O ciclo PCI mistura `managed='yes'` do libvirt com gestão manual por sysfs, sem pós-condições claras.
4. O disco físico é verificado apenas quando anexado; não existe trava em cada boot da VM contra raiz, HD2 ou montagem concorrente.
5. Grupo IOMMU contaminado apenas gera aviso e ainda permite concluir a etapa.
6. A etapa 52 redefine o XML para exigir HugePages antes de validar memória, suporte de CPU e parâmetros de kernel.
7. Parâmetros de kernel são adicionados por valor completo e podem ficar duplicados quando RAM ou listas de CPU mudam.
8. O backup usa `rsync` sem preservação explícita de sparse, considera `qemu-img info` uma validação de integridade e não inclui XML, NVRAM nem TPM.
9. Snapshot pode ser revertido com a VM ligada e a atualização do host prossegue mesmo quando o snapshot falha.
10. Airlock altera SSH e UFW globalmente sem backup/rollback integral; `sshd -t` não confirma a configuração efetiva.
11. A seleção do driver NVIDIA pode instalar mais de um meta-pacote e escolher a maior versão numérica em vez da recomendada.
12. A etapa de pacotes base não instala todas as dependências exigidas, especialmente `rsync`.
13. A migração para NTFS usa uma segunda passagem de `rsync` sem checksum antes de permitir apagar a origem.
14. Alguns verificadores aceitam estados incompletos ou dispositivos errados e podem gerar falso positivo no menu.
15. O arquivo `passthrough.conf` é código shell carregado com `source`; valores manuais e caminhos interpolados em scripts root precisam de validação estrita.
16. A etapa 00 se declara somente leitura, mas pode instalar pacote e grava relatório.
17. HD2 e otimizações opcionais são descritos de forma inconsistente entre scripts, menu e documentação.
18. Não há suíte automatizada do projeto; o README apenas sugere comandos manuais de sintaxe e ShellCheck.

## Plano de implementação

### Etapa A — Linha de base

- Rodar `bash -n` em `lib/common.sh`, `menu.sh`, `etapas/*.sh` e `util/*.sh`.
- Verificar CRLF e placeholders residuais.
- Rodar ShellCheck se já estiver instalado; não instalar dependências sem necessidade.
- Registrar falhas preexistentes antes das alterações.

### Etapa B — Biblioteca compartilhada e configuração

- Adicionar validações estritas para PCI BDF, vendor/device ID, UUID, caminho absoluto seguro e listas de CPU.
- Validar variáveis críticas imediatamente após carregar o arquivo central nas etapas que as consomem.
- Implementar substituição de parâmetros de kernel por chave, removendo versões antigas de `hugepages`, `isolcpus`, `nohz_full`, `rcu_nocbs` e equivalentes antes de adicionar o valor novo.
- Preservar backups no caminho GRUB e manter comportamento idempotente no kernelstub.
- Criar helpers reutilizáveis para identificar e validar o disco físico dedicado.

### Etapa C — IOMMU, GPU e disco físico

- Fazer a etapa 30 falhar diante de endpoint estranho no grupo IOMMU.
- Reforçar `--verificar` para conferir GPU, áudio, grupo persistido e limpeza do grupo.
- Instalar dispatcher sem destruir hook incompatível; criar backup e recusar adoção insegura.
- Tornar geração dos hooks atômica, com arquivos temporários root e validação antes da instalação.
- Usar um ciclo PCI coerente: hooks param o display manager e validam o estado; o libvirt com `managed='yes'` gerencia detach/reattach PCI. Remover bind/unbind manual duplicado dos hooks gerados.
- Adicionar preflight do HD1 no hook `prepare/begin`, abortando a VM se o disco for raiz, HD2, estiver montado ou tiver mudado de alvo.
- Verificar pós-condições do driver no início/fim, sem imprimir sucesso falso.
- Fazer a recuperação abortar se a VM estiver ligada e evitar desvincular desnecessariamente um dispositivo já entregue ao driver NVIDIA.

### Etapa D — CPU, HugePages e parâmetros de boot

- Validar todas as entradas e capacidade antes de alterar o XML.
- Preparar e validar o XML temporário antes de defini-lo.
- Aplicar parâmetros de kernel antes de tornar HugePages obrigatórias no XML, ou restaurar o XML em qualquer falha.
- Fazer reconfiguração substituir parâmetros antigos por chave.
- Reforçar verificadores com tamanho real da HugePage, contagem, lista exata de CPUs e ausência de duplicações/sobreposição.
- Marcar HugePages e isolamento como opcionais no menu e na documentação.

### Etapa E — Dados, snapshots e backup

- Adicionar `rsync` às dependências instaladas.
- Usar verificação com checksum na migração antes de permitir remoção dos originais.
- Manter confirmação textual destrutiva e listar limitações de metadados NTFS.
- Fazer snapshot/reversão exigir VM desligada quando o modo não garantir consistência.
- Não prosseguir silenciosamente com atualização do host se o snapshot de segurança falhar; exigir confirmação explícita.
- Criar backup em diretório datado contendo disco QCOW2, XML inativo, NVRAM e estado do TPM quando disponíveis.
- Copiar QCOW2 de maneira sparse/segura, validar com `qemu-img check` e evitar afirmar integridade absoluta sem verificação.
- Documentar que HD1 físico requer rotina separada e que BitLocker exige chave de recuperação.

### Etapa F — Airlock, SSH e UFW

- Validar nomes e caminhos antes de interpolá-los em fstab, sshd ou hooks root.
- Criar backups do drop-in SSH e das regras UFW gerenciadas.
- Usar transação com trap para restaurar drop-in e regras em falhas após mutação.
- Validar chave pública com `ssh-keygen -l -f` antes da instalação e preservar chave anterior.
- Validar sintaxe com `sshd -t` e valores efetivos com `sshd -T`/`sshd -T -C user=...`.
- Alertar e confirmar explicitamente o impacto global de ativar política `deny incoming` quando o UFW estava inativo.
- Não remover a regra antiga antes de comprovar que a substituição pode ser aplicada ou garantir rollback.
- Ampliar `--verificar` para conta, grupo, shell, chroot, opções bindfs, SSH efetivo e chave parseável.

### Etapa G — Dependências, driver, verificadores e documentação

- Instalar uma única estratégia de driver NVIDIA: preferir `system76-driver-nvidia`; caso ausente, usar `ubuntu-drivers` para descobrir o recomendado, sem selecionar a maior versão numericamente.
- Declarar e verificar todas as dependências usadas.
- Corrigir a descrição da etapa 00: coleta de inventário, não somente leitura.
- Alinhar a obrigatoriedade do HD2; permitir explicitamente fluxo sem HD2 ou documentar que ele é requisito. A implementação preferida é tornar Docs4/Airlock/backup em HD2 opcionais.
- Marcar etapas 51–53 como opcionais.
- Reforçar verificadores para endereços/discos exatos e pós-condições reais.
- Atualizar README e guia com garantias que de fato existem, removendo afirmações absolutas incorretas.

### Etapa H — Testes finais

- Repetir `bash -n`, CRLF, placeholders e ShellCheck.
- Adicionar testes shell isolados para validações puras e geração de arquivos, sem sudo nem alteração do host.
- Validar que hooks gerados passam `bash -n` usando fixtures temporárias.
- Revisar `git diff --check` e o diff completo.
- Não executar passthrough, bootloader, Netplan, UFW, SSH ou libvirt reais neste host como parte da suíte automatizada.

## Critérios de sucesso

- Todos os scripts Bash passam em `bash -n`.
- Nenhum erro ShellCheck de severidade alta permanece sem justificativa documentada.
- Recuperação recusa VM ligada.
- Grupo IOMMU contaminado bloqueia a continuação.
- Hook global existente nunca é sobrescrito silenciosamente.
- Falha de preparação da GPU impede o início da VM e não informa sucesso falso.
- HD1 é revalidado em todo início da VM.
- Etapas 52/53 não deixam XML ou cmdline parcialmente alterados quando falham.
- Não há parâmetros de kernel duplicados por chave após reconfiguração.
- Backup preserva sparse quando suportado, inclui metadados restauráveis e passa em `qemu-img check`.
- Migração destrutiva só é oferecida após comparação por checksum.
- SSH/UFW têm backup, rollback e validação efetiva.
- Menu e documentação distinguem claramente etapas obrigatórias e opcionais.
- O estado final e os testes executados ficam registrados neste arquivo.

## Limitações esperadas

- Bind/unbind real da GPU, recuperação de vídeo, grupos IOMMU, HugePages de 1 GiB, reinicialização, Netplan, UFW e SFTP precisam de teste funcional posterior em hardware compatível.
- Não é possível provar recuperação de uma GPU específica apenas com testes estáticos.
- Versões de pacote disponíveis dependem da versão real do Pop!_OS e dos repositórios configurados.

## Registro de execução

A preencher ao final de cada bloco de implementação.


### Linha de base antes das correções

- `bash -n` em todos os scripts Bash: **aprovado**.
- CRLF em arquivos `.sh`: **nenhum encontrado**.
- Placeholders `<MAIUSCULAS>` em scripts executáveis: apenas o fallback textual intencional `<IP_FIXO_HOST>` em `etapas/61-airlock.sh`.
- ShellCheck: **não instalado no ambiente**; não foi instalado automaticamente.
- PowerShell (`pwsh`): **não instalado no ambiente**; os três arquivos `.ps1` não puderam ser analisados pelo parser oficial local.
- Estado Git inicial após criar este plano: somente `PLANO-CORRECOES-AUDITORIA.md` aparecia como arquivo novo.
- Nenhuma etapa do projeto, serviço, VM, rede, firewall, bootloader ou configuração do host foi executada durante esta linha de base.


### Bloco B — biblioteca compartilhada e configuração

- `passthrough.conf` deixou de ser carregado com `source`: agora existe parser de dados com whitelist de chaves, literais sem `eval`, rejeição de chaves duplicadas/desconhecidas e validação por tipo.
- `salvar_conf` passou a serializar no subconjunto literal aceito pelo parser e instalar a atualização atomicamente no mesmo diretório, recusando link simbólico.
- Adicionados validadores compartilhados para PCI BDF, vendor/device, UUID, caminhos absolutos, unidades systemd, inteiros, listas de CPU e partição completa/disjunta das CPUs.
- Adicionado preflight fail-closed reutilizável para disco físico `/dev/disk/by-id`, incluindo disco raiz, discos protegidos, montagem, tipo do alvo e mudança de alvo durante a validação.
- `kernel_param_add`/`kernel_param_del` agora operam por chave. O caminho kernelstub lê os loader entries pendentes com privilégio e restaura valores antigos se a inclusão falhar; o caminho GRUB usa arquivo temporário, backup e rollback se `update-grub` falhar.
- Validações executadas sem alterar o host: `bash -n` em todos os scripts, `git diff --check`, carga completa de `passthrough.conf.example`, round-trip atômico de valor com espaços, rejeição de command substitution sem execução, listas de CPU e filtragem de cmdline por chave. Resultado: **aprovado**.
- Nenhum comando real de kernelstub, GRUB, disco ou `sudo` foi executado; esses caminhos permanecem para teste funcional posterior em ambiente descartável.


### Bloco C — IOMMU, GPU e disco físico

- O grupo IOMMU passou a ser validado pela identidade vendor/device da GPU/áudio, grupo persistido e classe de cada membro. Somente GPU, áudio autorizado e bridges PCI de classe base `0x06` são aceitos; qualquer endpoint estranho bloqueia a fase B e não é persistido.
- O verificador da etapa 30 agora valida a GPU específica e o grupo exato. A coleta de mensagens AMD-Vi deixou de usar pipelines sujeitos a SIGPIPE sob `pipefail`.
- A validação de discos passou a distinguir `livre` de `erro de inspeção`, enumerar todos os ancestrais físicos da raiz e repetir duas fotografias completas. A etapa 02 também ignora/bloqueia candidatos quando não consegue provar o estado de montagem.
- A etapa 50 foi reestruturada: `managed='yes'` do libvirt é a única autoridade de detach/reattach PCI; os hooks gerados não escrevem em `bind`, `unbind` ou `new_id`.
- O dispatcher v2 preserva stdin e todos os argumentos, propaga status de falha, valida segmentos de caminho e executa o gate de segurança antes de hooks `00-*` e do legado. Dispatcher antigo conhecido é migrado; dispatcher desconhecido ou hook legado/sibling que gerencie PCI diretamente é recusado. Symlinks, arquivos não-root ou graváveis por terceiros também são recusados.
- A publicação do conjunto usa marcador/hook temporário de bloqueio de starts, instalações atômicas por arquivo, backups fora da árvore despachada e trap transacional para `EXIT`, `INT` e `TERM`. XML é marcado como potencialmente mutado antes de cada chamada remota e é restaurado junto com os hooks em falhas; artefatos são preservados se o rollback não puder ser provado.
- `prepare/begin` revalida em todo start: vendor/device, grupo e membros IOMMU, HD1 contra todos os discos da raiz, `NVME_DEVICE`, HD2, montagens, WWN/serial, major:minor e mudança de alvo; só depois para o display manager e descarrega NVIDIA com rollback e pós-condições. `start/begin` repete identidade/montagem do HD1 e exige `vfio-pci`; `release/end` exige state root-owned, valida drivers, `nvidia-smi` e restaura exatamente o estado anterior do display manager.
- O lock compartilhado usa diretório root-owned em `/run`, impedindo symlink arbitrário em hook root e coordenando prepare/release/recuperação.
- A criação da VM bloqueia nomes com árvore de hooks residual. A recuperação exige domínio existente e `domstate` exatamente `shut off` duas vezes sob lock, revalida PCI/IOMMU, preserva drivers saudáveis, usa `nodedev-reattach`/probe somente quando necessário e nunca faz unbind indiscriminado. Sem state, exige o override explícito e confirmado `--assumir-dm-ativo`.
- Validações executadas sem mutar GPU/libvirt/discos/serviços: `bash -n` global, `git diff --check`, regressão do parser, teste read-only de topologia/erro fail-closed de disco, renderização dos cinco artefatos de hook com e sem áudio, `bash -n` dos artefatos, busca negativa por bind/unbind/new_id e duas revisões semânticas independentes com correção dos bloqueadores encontrados. Resultado estático: **aprovado**.
- Não foram executados start de VM, detach/reattach, modprobe, display manager, instalação em `/etc/libvirt`, restart do libvirtd ou acesso destrutivo a disco. A ordem real dos eventos e o reset da GPU ainda exigem ensaio manual controlado em hardware compatível.
