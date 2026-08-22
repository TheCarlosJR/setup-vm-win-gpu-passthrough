# Plano de Finalização: Windows 11 VM com GPU Passthrough (prioridade Ubuntu)

> **Data de consolidação:** 16 de agosto de 2026
> **Executor-alvo:** Claude Code (Opus 5)
> **Status:** fases I0 e I1 concluídas e reverificadas em 16 de agosto de 2026; fases I2, I3, I4 e I5 concluídas em 17 de agosto de 2026; fases I6 a I14 pendentes
> **Escopo:** correções funcionais e de segurança, migração arquitetural híbrida Bash/Python, testes/CI, documentação, qualificação real de Ubuntu/Pop!_OS e, por último, expansão multidistribuição
> **Substitui integralmente:** `PLANO-CORRECOES-AUDITORIA.md` (blocos A, B e C registrados como executados; itens restantes absorvidos no código atual e nos deltas de I0) e `PLANO-INTEGRADO-MELHORIAS-MIGRACAO-PYTHON.md` (todo o conteúdo normativo foi transportado para cá). Nenhum dos dois é necessário para executar este documento.

---

## Numeração das etapas

Toda referência a "etapa N" neste documento usa o **número do menu** (1 a 20),
igual ao que `menu.sh` mostra e ao que os scripts imprimem. O nome do arquivo em
`etapas/` mantém a numeração histórica, que é diferente:

| Etapa | Script | Etapa | Script | Etapa | Script |
|---|---|---|---|---|---|
| 1 | `00-inventario.sh` | 8 | `14-working-disk.sh` | 15 | `51-usb-passthrough.sh` |
| 2 | `01-verificar-bios.sh` | 9 | `20-virtualizacao.sh` | 16 | `55-driver-nvidia-vm.sh` |
| 3 | `02-detectar-config.sh` | 10 | `21-usuario-grupos.sh` | 17 | `52-cpu-pinning-hugepages.sh` |
| 4 | `10-atualizar-sistema.sh` | 11 | `30-iommu-vfio.sh` | 18 | `53-cpu-isolation.sh` |
| 5 | `11-driver-nvidia.sh` | 12 | `40-criar-vm.sh` | 19 | `60-rede-bridge.sh` |
| 6 | `12-pacotes-base.sh` | 13 | `41-instalacao-windows.sh` | 20 | `61-airlock.sh` |
| 7 | `13-diretorios.sh` | 14 | `50-hooks-gpu-hd1.sh` | 21 | `70-trim-discard.sh` |

Caminhos de arquivo (`etapas/40-criar-vm.sh`, `tests/i0/...`) continuam literais.

---

## 0. Instrução principal ao executor

Este arquivo é a fonte de verdade para a implementação. Trabalhe de **I6 até I13 na ordem** (I0 a I5 já estão concluídas) e só então inicie I14 conforme a ordem interna registrada naquela fase. Não presuma que um item está ausente só porque aparece como tarefa: primeiro detecte e caracterize o estado atual, classifique-o como `AUSENTE`, `PARCIAL` ou `CONFORME`, preserve o que já estiver correto e aplique somente o delta necessário. O marco `BASE_QUALIFICADA` encerra I0 a I13; o marco `EXPANSAO_TOTAL_QUALIFICADA` só existe após todos os providers mutáveis de I14 e o gate diagnóstico Silverblue estarem concluídos.

O objetivo não é apenas criar um núcleo Python. O resultado final deve simultaneamente:

1. eliminar os bloqueadores funcionais e de segurança descritos neste plano;
2. preservar os contratos públicos e operacionais atuais;
3. separar cálculo/validação pura em Python de efeitos, privilégio e rollback em Bash;
4. deixar todos os caminhos mutantes fail-closed e transacionais;
5. comprovar o comportamento por testes herméticos e CI;
6. manter qualificação em hardware real separada de implementação e mocks;
7. qualificar Ubuntu e Pop!_OS por campanhas distintas;
8. implementar providers de novas distribuições, uma por vez, sem promover suporte por inferência.

### 0.1 Regras obrigatórias de execução

1. Leia este plano, `README.md`, `Guia-QEMU-Passthrough.md`, os artefatos de estado (`tests/i0/*.tsv`, `tests/i0/baseline.md`, `tests/i1/mutators.tsv`), as steering/specs aplicáveis em `.kiro/specs/` e os arquivos da fase ativa antes de editar.
2. Execute **uma fase por vez**. Crie uma lista de tarefas apenas para a fase ativa e só avance quando o gate dela estiver aprovado.
3. Antes de cada fase, execute `git status --short`; preserve alterações do usuário e nunca use `git reset --hard`, `git clean`, checkout destrutivo ou sobrescrita ampla.
4. Não crie commit, tag, release ou push sem pedido explícito do usuário.
5. Registre baseline antes da primeira mudança. Falhas preexistentes devem ser reproduzidas e registradas, nunca apagadas do histórico de execução.
6. Leia todo arquivo antes de editá-lo. Faça mudanças lógicas pequenas e preserve mensagens, opções, códigos de saída, formatos e ordem operacional, salvo quando este plano exigir mudança explícita.
7. Escreva testes de caracterização antes de substituir comportamento existente. Uma correção P0/P1 deve aparecer como correção funcional explícita, não ser escondida como "refatoração equivalente".
8. Nunca mantenha dois caminhos mutantes em produção. Comparação diferencial temporária só é permitida para funções puras e fixtures; remova-a no cutover da fase.
9. Python não pode executar comandos do host, elevar privilégio ou controlar serviços/libvirt/rede/boot. Bash captura snapshots, confirma, aplica, verifica e restaura.
10. Nunca transporte código do Python para o Bash: sem `eval`, sem `source` de dados, sem interpolação de comandos e sem parsing de JSON complexo por regex.
11. Não instale dependências automaticamente. O core usa Python 3.10+ e biblioteca padrão. Dependências de sistema entram no bootstrap/provider e na CI de forma explícita.
12. Durante implementação e testes automatizados, não altere o host de desenvolvimento: use fixtures, shims, mocks e raízes temporárias. Não execute `sudo`, `virsh define`, `systemctl`, `netplan apply`, comandos de boot/initramfs, firewall ou disco reais.
13. Se uma validação exigir GPU real, reboot, bootloader, initramfs, rede física, firewall/SSH, disco, VM ou teste destrutivo, pare e peça ao usuário um ambiente descartável, backups, console fora de banda e autorização explícita.
14. Para cada tarefa, rode primeiro o teste direcionado; para cada fase, rode o gate global. Corrija qualquer falha antes de avançar.
15. Faça revisão semântica nos checkpoints I3, I4, I5, I7, I9, I10 e I12, verificando comportamento, segurança, transação e compatibilidade, não apenas sintaxe.
16. Atualize os checkboxes e o registro deste documento com data, comandos, resultados, limitações e arquivos alterados. Não marque hardware real como aprovado com base em mocks.
17. Execute cada operação convergente duas vezes nos testes e prove que a segunda execução é no-op quando o estado já é o desejado, inclusive conteúdo, metadados e mtimes quando aplicável.
18. Antes de declarar conclusão, revise todos os critérios da seção 16 e peça revisão do usuário antes de qualquer release.
19. Manifesto de fase: todo arquivo novo (untracked ou adicionado ao index) precisa constar de um manifesto em `tests/manifests/` (ordenado em ordem C, um caminho por linha). O gate `tests/check-phase-manifest.sh` também exige que cada caminho nominal exista. Crie um manifesto novo por fase (por exemplo `tests/manifests/i2-files.txt`) e acrescente-o à chamada do checker em `tests/run-gate-i1.sh` ou no runner da fase.

### 0.2 Semântica dos checkboxes

- `[ ]`: não iniciado ou não comprovado.
- `[~]`: parcial, com evidência e pendências registradas.
- `[x]`: implementado e aprovado pelo gate correspondente.
- `[H]`: depende de qualificação manual/hardware e não pode ser fechado por teste hermético.
- Nunca troque `[H]` por `[x]` sem registrar ambiente, procedimento e evidências reais.

---

## 1. Auditoria de 16 de agosto de 2026 (estado verificado, não presumido)

Esta auditoria reexecutou a verificação completa no host de desenvolvimento e substitui qualquer suposição sobre "trabalho possivelmente terminado". Resultado objetivo: **as fases I0 e I1 estão de fato concluídas e o gate se mantém verde; a migração Python (I2 em diante) NÃO começou** (`libexec/` não existe; os únicos `.py` do projeto são harnesses de teste).

**Atualização de 2026-08-17:** as fases I2 e I3 foram implementadas e aprovadas pelo gate canônico. `libexec/` passou a existir com o entrypoint único `passthrough_core_cli.py` e o package `passthrough_core` (`errors`, `protocol`, `cli` em I2; `xmlutil`, `domain_xml`, `network_xml`, `qemu_image` em I3), e `lib/python-core.sh` é a ponte única, carregada por `lib/common.sh`. Depois de I3 não existe mais nenhum heredoc Python nem consumidor operacional de `xmlstarlet` em produção. O parágrafo acima permanece como registro fiel do que foi verificado em 16 de agosto e não deve ser reescrito.

### 1.1 Ambiente auditado

| Item | Valor verificado |
|---|---|
| Host | Ubuntu 26.04 LTS (`ID=ubuntu`), usuário `charloso`, kernel 7.0.0-29-generic |
| Bash / Python / Git | 5.3.9 / 3.14.4 (atende 3.10+) / 2.53.0 |
| Bubblewrap | presente (sandbox dos testes mutantes funciona) |
| nvidia-smi | presente (driver NVIDIA do host funcional) |
| shellcheck, pwsh, xmlstarlet, virt-xml-validate, virsh, qemu-img | ausentes no host; a CI provisiona ShellCheck; virsh/qemu-img chegam com a etapa 9 |

### 1.2 Verificações executadas e resultados

| Verificação | Resultado |
|---|---|
| `bash -n` em todos os `.sh` (menu, lib, etapas, util, tests) | aprovado, sem falhas |
| CRLF em `*.sh` | nenhum |
| Placeholders `<MAIUSCULAS>` residuais | nenhum (exceto o fallback intencional `<IP_FIXO_HOST>` na etapa 20) |
| Suíte hermética completa (12 testes `tests/test-*.sh`) | **12/12 aprovados** (total aproximado de 62 s; maior: `test-i1-safety-envelope.sh` com 43 s) |
| Gate canônico `bash tests/run-gate-i1.sh` (manifesto, envelope I1, validador, campanha I0 integral `full` sem skips, suíte, sintaxe, whitespace) | resultado registrado na seção 12 (registro de execução) |
| Manifesto de fase | 52 arquivos untracked correspondem exatamente à união de `i0-files.txt` + `i1-files.txt` |
| `passthrough.conf` | ignorado pelo Git e fora do índice (correto); cópia local preservada |
| `guard_mutation` | definida em `lib/common.sh`, aplicada em todos os entrypoints mutantes antes de `sudo` (conferido por amostragem nas etapas 19 e 20; somente os read-only 2, 8 e `listar-grupos-iommu.sh` não a usam, por desenho) |
| Bloqueadores do antigo `PLANO-CORRECOES-AUDITORIA.md` | amostrados no código: recuperação recusa VM ligada; snapshot exige VM desligada; estratégia única de driver NVIDIA por perfil; `rsync` nas dependências; migração NTFS removida do escopo (workingDisk é montado externamente pelo operador). As lacunas restantes estão TODAS catalogadas em `tests/i0/deltas.tsv` (32 deltas) e no catálogo da seção 4 |

### 1.3 Estado real DESTE host Ubuntu (`bash menu.sh --status`, rc=3)

O código está saudável, mas a configuração local veio de outra máquina (host Pop!_OS anterior). Bloqueios operacionais reais encontrados:

1. `passthrough.conf` registra `USUARIO_LINUX="charles"`, mas o usuário deste host é `charloso` (a conta `charles` não existe no NSS). Isso contamina as etapas 3, 7, 10, 12 e 20.
2. `BOOTLOADER="kernelstub"` no conf, mas o boot efetivo deste host é `grub`. A etapa 11 bloqueia corretamente até a migração pela etapa 3.
3. Diretório de inventários `~/inventario-hardware` inexistente (etapa 1 pendente).
4. `CPUS_VM`, `CPUS_HOST`, `VM_VCPUS`, `VM_CORES`, `VM_THREADS`, `VM_RAM_MB`, `HUGEPAGES_1G`, `REDE_MODO`, `ISO_WINDOWS` e `ISO_VIRTIO` indefinidos.
5. `WORKING_DISK_PATH=/mnt/workingDisk` não é um mountpoint ativo neste host (montar externamente ou dispensar com `WORKING_DISK_DISPENSADO=sim`).
6. Uplink: somente `wlp5s0` (Wi-Fi) tem IPv4; `enp6s0` (Ethernet) está sem IPv4. Enquanto isso valer, o modo de rede obrigatório é `nat` (bridge exige Ethernet).
7. Hardware detectado corretamente: GPU `0000:07:00.0` (`10de:2504`, RTX 3060) + áudio `0000:07:00.1`, CPU AMD (`AuthenticAMD`), `DM_SERVICE=gdm3`.

**Roteiro operacional para destravar este host (executar pelo usuário, na ordem do menu):** etapa 1 (inventário), etapa 3 (reinicia a configuração, corrige usuário e migra `kernelstub` para `grub` com backup), etapa 4 (reboot), etapa 5 (valida driver), etapas 6 a 10, etapa 11 (fase A, reboot, fase B), etapas 12 a 21. Este roteiro usa o código já existente; não depende das fases I2+.

**Atualização de 2026-08-16 23:19:** o usuário executou as etapas 1 e 3 com sucesso. `menu.sh --status` agora mostra as etapas 1, 2, 3, 5 e 8 concluídas; o conf está correto para este host (`USUARIO_LINUX=charloso`, `VM_NAME=vwin11`, `BOOTLOADER=grub`, `REDE_MODO=nat` em `wlp5s0`, `WORKING_DISK_PATH=/mnt/docs4` montado, 12 vCPUs, 22 GiB de RAM, `HUGEPAGES_1G=22`). Restam as etapas 4 em diante, na ordem do menu. Itens 1 a 5 acima estão resolvidos; o item 6 (NAT obrigatório) permanece válido.

### 1.3.1 Incidente da ISO do Windows 11 (16/08/2026) e correção aplicada

Durante a etapa 3, o usuário informou um caminho de ISO que existia fora de `/vm`. O bloco antigo só testava `[ -f ]` e repassava o valor ao `salvar_conf`, cuja política tipada (`caminho_artefato_vm_logico_valido`: filho direto canônico de `/vm`, sem vírgula, sem links) abortava a etapa inteira com `Valor inválido para a chave 'ISO_WINDOWS'`, sem explicar a política; o menu então mostrava "A saída acima foi preservada para diagnóstico" (o "registro para análise" percebido pelo usuário). Não existe ISO do Windows 11 nem virtio-win nesta máquina; elas precisam ser baixadas (microsoft.com e projeto oficial virtio-win) e, depois da etapa 7 criar `/vm`, copiadas para lá (ex.: `/vm/Win11.iso`), quando a etapa 12 pedirá os caminhos.

Correção aplicada em 2026-08-16 (herméticamente testada, sem mutação do host):

- `lib/common.sh`: novos helpers `classificar_iso_opcional_conf` (classificador puro: `vazia`/`ausente`/`valida` ou recusa com diagnóstico da política) e `perguntar_iso_opcional_conf` (prompt opcional que explica a política, repergunta até cinco vezes e persiste vazio em ENTER/ausência/limite; nunca deixa `salvar_conf` derrubar a detecção).
- `etapas/02-detectar-config.sh`: o bloco de ISOs passou a usar o novo prompt.
- `tests/test-ubuntu-audit-regressions.sh`: regressões cobrindo vazio, fora de `/vm` existente, vírgula, `/vm` ausente, recusa+ENTER, cinco recusas e caminho `/vm` válido persistido (com raiz hermética).

A mesma classe de defeito (resposta digitada indo a um `falhar` fatal, obrigando a refazer a detecção desde 1/8) existia em outros três prompts da etapa 3 e foi corrigida junto:

- `lib/common.sh`: novo helper genérico `perguntar_validado texto padrao VALIDADOR mensagem` (repergunta com o motivo; define `PERGUNTA_VALIDADA`; cinco recusas retornam 1; validador precisa ser função existente).
- `etapas/02-detectar-config.sh`: `VM_NAME` (bloco 1/8), `TRANSFER_USER` e `AIRLOCK_DIR` (bloco 8/8, onde o aborto fatal era mais caro) agora reperguntam com `nome_vm_valido`, `nome_usuario_valido` e `caminho_absoluto_seguro` respectivamente.
- `tests/test-ubuntu-audit-regressions.sh`: regressões de aceitação após recusa, limite de cinco tentativas e validador desconhecido.

O prompt de `USUARIO_LINUX` (1/8) mantém o aborto fatal deliberadamente: a validação envolve NSS e a autorização explícita de conta diferente do operador, e o custo de reexecução no primeiro bloco é mínimo. A migração segura de valor legado de ISO já gravado no conf (REQ-CONF-ISO) continua pendente para I4; esta correção cobre somente os prompts interativos da etapa 3.

### 1.4 Divergências de documentação já conhecidas (corrigir em I11, não antes)

- `README.md` e `Guia-QEMU-Passthrough.md` ainda dizem "Pop!_OS" no título/ambiente de referência, enquanto `lib/platform.sh` e o menu suportam Ubuntu e Pop!_OS com perfis distintos (Ubuntu: `grub` + `ubuntu-drivers` + `qemu-system-x86`; Pop: `kernelstub`/`grub` + `system76` + `qemu-kvm`).
- `tests/i0/baseline.md` referencia o nome do plano antigo; é evidência histórica e não deve ser reescrita.

---

## 2. Arquitetura e fronteiras invariantes

### 2.1 Decisão arquitetural

A solução final é **híbrida**, não uma reescrita total:

- **Python:** modelos, schemas, parsing, normalização, validação, comparação semântica, cardinalidade, diff, cálculo de CPU/RAM, inventário, CIDR/rotas, leitura e geração de candidatos XML/JSON, fatos de plataforma e planos declarativos.
- **Bash:** menu/UI, prompts e confirmações, `sudo`, chamadas às ferramentas Linux, captura de snapshots, locks, traps/sinais, aplicação, pós-condições no host, commit, rollback e recuperação.
- **Hooks libvirt:** Bash puro e autossuficiente, com `PATH` controlado, sem Python, sem checkout e sem dependência do diretório do repositório.

Regra para caso misto: **planejar e comparar em Python; aplicar, verificar no host e restaurar em Bash**.

### 2.2 Restrições do core Python

O core deve:

- funcionar com Python 3.10+ e somente biblioteca padrão;
- ser invocado por caminho absoluto com `python3 -I -S -B`;
- definir `sys.dont_write_bytecode = True` antes do primeiro import local e nunca criar `.pyc`/`__pycache__` no checkout;
- não depender de instalação, venv, `PYTHONPATH`, diretório atual, módulo `site`, arquivos `.pth`, `site-packages`/`dist-packages` ou download;
- não importar nem executar `subprocess`, `os.system`, `pty`, libvirt ou ferramentas do host;
- não elevar privilégio nem escrever fora de candidatos/temporários/configuração controlada do usuário;
- tratar toda entrada como não confiável;
- não manter estado global mutável;
- emitir traceback apenas em modo explícito de desenvolvimento;
- produzir serialização determinística.

### 2.3 Árvore-alvo

A árvore pode ser ajustada somente com justificativa registrada, mantendo as mesmas responsabilidades:

```text
lib/
├── common.sh                    # agregador/fachada compatível, sem algoritmos de domínio
├── platform.sh                  # fachada compatível durante o cutover
├── python-core.sh               # única ponte Bash para Python
└── shell/
    ├── base.sh
    ├── ui.sh
    ├── privilege.sh
    ├── status.sh
    ├── probes.sh
    ├── storage.sh
    ├── libvirt.sh
    ├── boot.sh
    ├── network-effects.sh
    └── hooks.sh
libexec/
├── passthrough_core_cli.py      # único entrypoint interno
└── passthrough_core/
    ├── __init__.py
    ├── cli.py
    ├── errors.py
    ├── protocol.py
    ├── config.py
    ├── domain_xml.py
    ├── network_xml.py
    ├── qemu_image.py
    ├── cpu.py
    ├── inventory.py
    ├── network.py
    └── platform.py
tests/
├── test-python-core.sh          # integra os testes Python ao loop shell histórico
├── python/
│   └── run_tests.py             # bootstrap isolado e discovery unittest
└── fixtures/core/
```

### 2.4 Direção de dependências

```text
menu/etapas/util
    v
fachadas common.sh/platform.sh
    v
módulos lib/shell + lib/python-core.sh
    v
libexec/passthrough_core_cli.py
    v
módulos puros passthrough_core
```

- módulos de domínio não importam CLI;
- CLI apenas valida/despacha e mapeia erros;
- Python não conhece shell nem efeitos;
- etapas não importam o package diretamente;
- módulos shell não formam ciclos e não causam efeitos ao serem `source`ados;
- APIs públicas existentes permanecem wrappers até o cutover completo.

### 2.5 Fora de escopo durante I0 a I12

- reescrever menu ou etapas inteiras em Python;
- executar ferramentas do host a partir de Python;
- converter hooks para Python;
- adicionar dependências PyPI;
- trocar o formato público de `passthrough.conf`;
- alterar política de CPU/rede/segurança sem requisito explícito deste plano;
- promover uma distro só porque o detector/parser passou a reconhecê-la;
- executar mutação real no host de desenvolvimento;
- implementar novos providers antes de I14.

---

## 3. Contratos que não podem regredir

### 3.1 CLI, entrypoints e status

- Preservar caminhos e nomes de `menu.sh`, `etapas/*.sh` e `util/*.sh`, execução por `bash`, opções públicas e `--verificar`/`--validar` existentes.
- Preservar a ordem operacional das etapas, avisos de reboot/logout e os itens atuais do menu, salvo adição de bloqueio/ocultação por capability.
- Status público: `0=concluído`, `1=pendente`, `2=indeterminado`, `3=erro`.
- Códigos internos do menu `20=voltar` e `21=sair` permanecem internos.
- Preservar o sentinel versionado `__PASSTHROUGH_STATUS_V1__:` e seu token efêmero; saída sem sentinel válido nunca vira sucesso.
- Status é observado do host, não um arquivo arbitrário de progresso. Processo abortado, saída incompleta, parser incerto ou ferramenta ausente nunca retorna concluído.
- Dispensa é estado de orquestração separado, não um quinto status público: `--verificar` e o sentinel V1 continuam descrevendo somente o estado real em `0/1/2/3`; uma etapa dispensada mas não executada retorna `1`. O menu lê a flag validada por canal separado, pode renderizar `[disp]` apenas na UI e só ignora o pré-requisito na matriz de política declarada. `[disp]` nunca integra nem altera o sentinel V1.
- Mensagens usadas por testes ou recuperação são API operacional. Alteração exige teste e documentação conjunta e não pode reduzir o diagnóstico.

### 3.2 Privilégio e segurança

- Processo inicia como usuário comum; `sudo` continua granular e controlado pelo shell.
- Guardas e validações devem ocorrer antes do primeiro `sudo` e do primeiro efeito.
- Preservar confirmações destrutivas, ticket/keepalive shell quando existente, traps, ordem de rollback e recusa de condições inseguras.
- Não ampliar a superfície root. Python nunca recebe `sudo`.
- Arquivos sensíveis exigem caminhos canônicos, temporário no mesmo filesystem, owner/grupo/modo corretos, flush/fsync quando exigido e publicação atômica. Symlink é recusado. Arquivo regular sensível existente com `st_nlink != 1` também é recusado: usar `lstat`/descritor seguro e revalidar device, inode, tipo e link count imediatamente antes da publicação para impedir troca concorrente. Essa política única vale para configuração, migração de ISO, backups e demais arquivos sensíveis, salvo exceção específica mais restritiva documentada e testada.

### 3.3 Configuração

- O formato público continua `CHAVE=valor_literal` em UTF-8.
- O schema definitivo deve ser derivado da allowlist atual de `lib/common.sh`, de `passthrough.conf.example` e dos consumidores; nenhuma chave pode desaparecer por omissão.
- Preservar comentários, linhas vazias, ordem, newline final e opções fora do reset quando o contrato atual assim exigir.
- Rejeitar chave desconhecida, repetida, literal inválido, tipo/relação inválida, symlink proibido e conflito TOCTOU.
- Nunca usar `source`, `eval`, command substitution ou expansão shell para carregar configuração.
- Preservar as APIs públicas `carregar_conf`, `salvar_conf`, escrita em lote, reset e backup como wrappers compatíveis.
- Escrita em lote é todo-ou-nada; publicar por rename no mesmo diretório/filesystem; preservar ou reaplicar metadados; backup sensível deve ser `0600`.
- As categorias atuais (identidade/VM/grupo/boot, GPU/áudio/vendor/IOMMU/display manager, NVMe/workingDisk/HD1/dispensas, QCOW2/tamanho/RAM/vCPU/topologia/CPU sets/HugePages, ISOs, rede/uplink/bridges/CIDR/MAC/IPs, usuário/Airlock/bind, backup e dispensas) devem constar do schema e da matriz de consumidores criada em I0 (`tests/i0/traceability.tsv`, 41 chaves).

### 3.4 Inventário e identidade

- Preservar leitura dos formatos de inventário atual e legado.
- Preservar nomes `inventario-YYYYMMDD...txt` e o symlink relativo `ultimo-inventario.txt`.
- Publicação do relatório deve ser completa e atômica; rejeitar vazio, parcial, truncado, inconsistente, duplicado ou link externo.
- Ordem textual não define identidade nem pode gerar falso positivo.

### 3.5 XML, JSON e libvirt

- Distinguir XML inativo de XML ativo e declarar qual está sendo analisado.
- Nunca selecionar silenciosamente "o primeiro" nó: cardinalidade zero ou múltipla é erro quando se espera exatamente um.
- Python recebe snapshots e gera candidato/diff; não chama `virsh`, `qemu-img` ou `virt-xml-validate`.
- Bash valida candidato com `virt-xml-validate` antes de `virsh define`, relê o estado, verifica a pós-condição e compara semanticamente.
- Preservar elementos e atributos não gerenciados.
- Backups XML devem ser exclusivos e vinculados à operação.
- `managed='yes'` permanece a autoridade sobre PCI; não reintroduzir bind/unbind/new_id manual paralelo.

### 3.6 Hooks

- Hooks permanecem Bash puro, independentes do checkout e do Python, com `PATH` fixo e `bash -n` aprovado.
- Falha em `prepare` bloqueia a inicialização da VM.
- Preservar controle de estado runtime e restauração de display/GPU.
- O ciclo `prepare > start > release` deve ser testado; nenhum caminho pode deixar serviço/GPU/arquivos parcialmente alterados.

### 3.7 Rede

- MAC persistido identifica a NIC da VM.
- Rede NAT só é gerenciada se possuir marcador explícito; rede homônima não gerenciada deve ser preservada e causar recusa segura.
- Bridge/NAT mantêm snapshots de configuração, XML, estado ativo, autostart, VMs consumidoras e configuração de rede do host.
- Fingerprints devem detectar mudança concorrente antes de aplicar e antes de restaurar.
- O planner é backend-neutral; provider Bash executa Netplan/NetworkManager/networkd/Wicked conforme capability futura.

### 3.8 Protocolo Bash/Python

- Invocação absoluta: `python3 -I -S -B /caminho/físico/libexec/passthrough_core_cli.py ...`.
- Como `-I -S -B` ignora ambiente/cwd, desabilita o módulo `site` e impede bytecode, o entrypoint define ainda `sys.dont_write_bytecode = True`, resolve `Path(__file__).resolve().parent`, verifica que o package pertence ao mesmo `libexec` físico confiável e insere **somente esse diretório** no `sys.path` antes do import. Nenhum caminho de ambiente, cwd, `.pth`, `site-packages` ou `dist-packages` pode participar; nenhum `.pyc`/`__pycache__` pode surgir.
- A ponte descobre a raiz física, exige Python 3.10+, controla locale/encoding, usa temporários com trap, preserva stdout/stderr/status e agrupa chamadas.
- JSON UTF-8 com `protocol_version: 1`, `core_version` próprio, schema fechado e serialização determinística. O subcomando read-only `version` retorna ambos os campos de qualquer cwd, sem tocar arquivos.
- XML, JSON bruto, conteúdo de configuração e snapshots entram **sempre** por stdin ou por arquivo temporário regular controlado `0600`, independentemente do tamanho; nunca entram em `argv`. `argv` contém apenas subcomandos, opções fixas, identificadores escalares previamente validados e, quando indispensável, localizadores aleatórios de arquivos controlados conforme a seção 3.9; nunca caminhos derivados de dados locais. A ponte remove temporários em sucesso, erro e sinal.
- Em sucesso, stdout contém somente dados de máquina; stderr contém diagnóstico humano.
- Para carregar valores no Bash, usar arquivo de pares `chave\0valor\0`, validar tamanho/paridade/allowlist e atribuir com `printf -v`; nunca regex sobre JSON.
- Códigos internos do helper: `0` sucesso, `64` uso, `65` dado/schema, `66` entrada ausente, `69` capability, `70` erro interno, `73` persistência segura, `75` conflito/TOCTOU.
- A ponte mapeia esses códigos conforme o contexto; qualquer `64-75` jamais pode virar status público `0`.

### 3.9 Classificação e redação de dados

Todo campo do schema de configuração, XML, inventário, rede, storage, protocolo e log deve declarar uma classe; campo novo ou desconhecido assume `SECRET` até revisão:

| Classe | Exemplos mínimos | Canais permitidos |
|---|---|---|
| `SECRET` | senha, token, chave privada, credencial, material de autenticação/criptografia | somente entrada controlada quando estritamente necessária; nunca stdout, stderr, log, bundle de CI ou artefato publicável |
| `LOCAL_IDENTIFIER` | UUID, MAC real, BDF selecionado, IP/CIDR local, username, hostname, caminho local, nome de VM, WWN/serial/by-id e identidade de hardware/disco | valor bruto permitido somente em: (a) IPC efêmero necessário (`stdin`, stdout de máquina por pipe/NUL ou arquivo temporário `0600`); (b) stores operacionais nominados abaixo; e (c) bundle local de recuperação `0600`. Em stderr, logs, CI e artefatos publicáveis, usar apenas rótulo e HMAC por operação |
| `RECOVERY_LOCATOR` | ID aleatório de operação com pelo menos 128 bits, não derivado de username, hostname, caminho, VM ou hardware | pode aparecer no stderr local e no comando local de recuperação; nunca em CI ou artefato publicável. O mapeamento ID/caminho fica somente em arquivo local `0600` |
| `PUBLIC` | versão de software, nome genérico de capability/provider, booleano/status e dados sintéticos de fixture | pode aparecer nos canais documentados |

- O schema deve enumerar a classe de cada chave/campo; não basta inferir pelo nome.
- Stores operacionais autorizados para `LOCAL_IDENTIFIER` bruto: `passthrough.conf` e backups; relatórios de inventário; XML inativo administrado pelo libvirt e backups XML; snapshots de rede, storage e rollback. Arquivos mantidos pelo projeto usam diretório `0700`, arquivo `0600`, owner esperado e nunca entram no repositório/CI; XML mantido pelo libvirt usa sua ACL própria e não é exportado sem redação.
- Um caminho em `argv` só pode localizar arquivo controlado criado pelo programa sob raiz privada fixa, com basename aleatório não derivado de `LOCAL_IDENTIFIER` ou `SECRET`. Qualquer outro caminho/conteúdo é transmitido por stdin ou descritor/arquivo controlado.
- O identificador redigido deve ser correlacionável apenas dentro da operação, usando chave/salt aleatório efêmero não registrado; digest simples de domínio pequeno não é aceito.
- No commit bem-sucedido, remover imediatamente bundle e mapeamento. Em falha grave, reter até o primeiro entre recuperação reconhecida e sete dias, registrar criação/expiração e fornecer limpeza idempotente. O diagnóstico imprime somente `recovery_id=<ID>` e o comando de recuperação, nunca o caminho completo. Documentar que unlink não garante apagamento físico em CoW/SSD.
- Fixtures de CI devem ser sintéticas e classificadas `PUBLIC`. Artefatos publicáveis contêm somente dados sintéticos ou redigidos.
- Testes com canários verificam stdout de máquina, stderr, logs, stores operacionais, temporários, bundles/mapeamentos de rollback e artefatos de CI: `SECRET` nunca vaza; `LOCAL_IDENTIFIER` bruto aparece somente em IPC, stores nominados ou bundle local `0600`; `RECOVERY_LOCATOR` não revela caminho e não é publicado.

---

## 4. Catálogo completo de requisitos funcionais e de segurança

Cada requisito abaixo é bloqueante. A fase indicada organiza a implementação, mas o aceite só ocorre quando todos os testes e gates associados passarem. O estado caracterizado em I0 consta de `tests/i0/deltas.tsv` e `tests/i0/oracle.tsv` e é evidência histórica: naquele momento REQ-CONF-ISO, REQ-WINDOWS-STATE e REQ-USB-IDENTITY estavam `AUSENTE` e os demais `PARCIAL`.

Estado depois de I3: REQ-TRIM-TX, REQ-LIBVIRT-BACKEND e REQ-HOOKS-TX estão `CONFORME` no código e nos testes herméticos, com a prova em hardware real ainda pendente em I13 (blocos/alocação de TRIM, ciclo real de GPU/display e libvirt real). A parte de REQ-GUARD e de REQ-VERIFY-FAILCLOSED fechada em I1 permanece. Os demais seguem `PARCIAL` ou `AUSENTE` nas fases indicadas.

Estado depois de I5: REQ-IOMMU-TX passou a `CONFORME` no código e nos testes herméticos; a campanha de dois reboots reais continua em I13. Os demais requisitos não mudaram de estado nesta fase.

### REQ-GUARD: guarda global de plataforma e capabilities (P0)

**Fases:** I1 (feita), migração interna em I8, gates I10/I12.

Uma única API pública fail-closed de guarda (`guard_mutation <capability>`, já implementada sobre o provider Bash), chamada por **todo entrypoint mutante**, inclusive execução direta. Ela valida plataforma, perfil, imutabilidade e capability específica antes de `sudo`, escrita, serviço, disco, rede, libvirt ou estado. O menu oculta ou bloqueia opções incompatíveis sem ser a única barreira.

- distro desconhecida, provider incompleto e capability ausente: recusar com erro específico e não zero;
- Silverblue/ostree: diagnóstico somente e zero mutações;
- escopo inicial de passthrough: AMD-only; Intel só pode ser habilitado após detecção e persistência de Intel IOMMU completas e qualificadas;
- nenhuma etapa pode contornar a guarda ao ser chamada diretamente.

**Testes:** cada mutador via menu e direto, em perfil suportado, desconhecido, planejado e imutável; interceptar `sudo`/primeiro efeito; provar que nenhum mutador foi chamado; comparar conteúdo, owner/grupo/modo e mtimes da raiz simulada. (Já existentes: `tests/test-i1-safety-envelope.sh`, `tests/i1/mutators.tsv`.)

**Aceite:** nenhuma mutação ocorre sem plataforma e capability explicitamente suportadas. Em I8, trocar apenas o resolver por trás da mesma API.

### REQ-CONF-ISO: migração segura de ISO legada (P0)

**Fases:** caracterização I0 (feita); implementação definitiva I4 (feita). Estado: código `CONFORME`. A migração pré-parser, o backup `0600`, a publicação única e a idempotência estão implementadas e testadas; a prova em host descartável continua opcional.

A migração deve ocorrer **antes** do parser estrito normal:

- ler somente atribuições literais de uma allowlist mínima;
- proibir execução, `source`, `eval`, command substitution e expansões;
- não abrir, resolver, montar, copiar, testar existência ou usar com privilégio o caminho legado;
- não reutilizar automaticamente o caminho antigo;
- solicitar e registrar um novo caminho válido;
- preservar demais chaves válidas e comentários necessários;
- criar backup; recusar symlink e arquivo regular sensível com `st_nlink != 1`; revalidar device/inode/tipo/link count imediatamente antes da publicação; publicar no mesmo filesystem por substituição atômica; preservar/reaplicar owner, grupo e modo;
- em qualquer falha, manter o original utilizável e informar o backup;
- configuração atual já válida deve permanecer byte a byte e mtime inalterados.

**Testes:** legado em `/home`, `/tmp` e `/vm/subdiretorio`; atual/no-op; literais malformados ou executáveis inertes; symlink, hardlink (`st_nlink > 1`) e troca concorrente de inode; falha antes e durante publicação; backup, conteúdo e metadados.

**Aceite:** configuração antiga chega ao prompt de nova ISO sem abrir nem privilegiar o caminho legado. **Aprovado em I4:** `conf_iso_legada_classificar` e `conf_migrar_iso_legada` em `lib/common.sh` sobre `config-legacy-scan`/`config-publish`, com matriz em `tests/test-i4-config.sh` e `tests/python/test_config.py`.

### REQ-TRIM-TX: transação completa de TRIM/discard (P0)

**Fases:** I3 (feita); prova de storage real I13. Estado: código `CONFORME`; D-TRIM-TRAPS e D-TRIM-ROLLBACK-DIVERGE fechados em I3; D-TRIM-OPERATIONAL permanece aberto para I13.

- capturar XML original e fingerprint;
- gerar e validar candidato antes da primeira mutação;
- armar traps `EXIT`, `INT` e `TERM` antes do primeiro `define`;
- manter estado explícito `PREPARED/APPLIED/VERIFIED/COMMITTED/ROLLING_BACK`;
- reler com `dumpxml` e provar exatamente `discard='unmap'` no disco correto;
- commit somente após a prova;
- qualquer erro/sinal pré-commit restaura o original;
- após rollback, reler e comparar semanticamente; retorno zero de `define` não basta;
- rollback divergente é erro grave com evidências e instruções de recuperação;
- preservar semântica/código do sinal.

**Testes:** sucesso; falha pré-publicação e imediatamente após define; falha de releitura/validação; `INT`, `TERM` e `EXIT` em cada janela mutante, sem falso commit; rollback que retorna zero mas diverge; estado final e idempotência.

**Aceite de código:** confirmação só após prova semântica, com restauração comprovada antes do commit. **Aprovado em I3:** `etapas/70-trim-discard.sh` mantém os cinco estados, arma traps antes do primeiro `define`, valida o candidato pelo schema antes da primeira mutação e relê o domínio depois de cada restauração; a matriz de falhas/sinais/rollback está em `tests/test-i0-mutators.sh` (bloco da etapa 21).
**Aceite operacional:** medir blocos/alocação no storage real em I13; XML sozinho não qualifica TRIM. Continua `[H]`.

### REQ-IOMMU-TX: convergência persistente IOMMU/VFIO (P0)

**Fases:** I5 (feita); dois reboots reais I13. Estado: código `CONFORME`; D-IOMMU-PARTIALITY e a parte hermética de D-IOMMU-ACTIVE-PERSISTENT fechados em I5. A prova em hardware, com dois reboots reais, continua `[H]` em I13.

- modelar separadamente "ativo no boot atual" e "persistido para o próximo boot";
- inspecionar a fonte persistente, não apenas `/proc/cmdline`;
- tratar parâmetros de boot, `vfio.conf` e initramfs como uma transação lógica;
- preservar conteúdo não gerenciado e metadados de `vfio.conf`;
- gerar initramfs somente depois de todos os candidatos válidos;
- capturar backups/snapshots de todos os recursos;
- em falha/sinal, restaurar e verificar semanticamente cada recurso;
- após reboot, provar argumentos, módulos e binding;
- segunda execução deve ser no-op.

**Testes:** cmdline temporária sem persistência; persistência correta com boot atual antigo; conteúdo extra em `vfio.conf`; falha depois de cada publicação; `INT`/`TERM`; rollback equivalente e divergente; idempotência; campanha de dois reboots em I13.

**Aceite:** estado ativo e persistente são provados separadamente e GRUB/bootloader, VFIO e initramfs nunca ficam em versões incompatíveis. **Aprovado em I5:** `iommu_vfio_transacao`/`iommu_vfio_rollback` em `lib/shell/boot.sh` mantêm os estados `PREPARED/BOOT/VFIO/INITRAMFS/VERIFIED/COMMITTED/ROLLING_BACK`, geram e validam todos os candidatos antes da primeira mutação, regeneram o initramfs somente depois de boot e `vfio.conf` comprovados e, em falha ou sinal, restauram cada recurso com releitura. A etapa 11 consome a transação; a matriz de falha/sinal em todas as janelas roda em `tests/test-i0-mutators.sh` (bloco da etapa 11, agora com a transação real de boot) e em `tests/test-i5-cpu-boot.sh`.
**Aceite operacional:** dois reboots reais em I13 continuam obrigatórios; nenhum teste hermético prova boot. Continua `[H]`.

### REQ-LIBVIRT-BACKEND: backend modular consistente (P1)

**Fases:** I3 (feita), integração de plataforma I8, modularização I9. Estado: código `CONFORME`; D-LIBVIRT-BACKEND fechado em I3 por `libvirt_backend_resolver`/`libvirt_backend_reiniciar` em `lib/common.sh`, consumidos pelas etapas 9, 10 e 14. Prova em libvirt real continua em I13.

O provider retorna backend, unidade e ações autorizadas. Etapas 9 e 14 consomem a mesma resolução autoritativa; nenhuma pode escolher ou hardcodear `libvirtd` de forma divergente. Validar existência, estado, restart/reload e pós-condição para backend monolítico e modular.

**Testes:** `libvirtd`, `virtqemud`, unidade ausente, restart falho, estado final inesperado e consistência 20 para 50.

**Aceite:** nenhuma etapa resolve backend diferente do aprovado pelo provider. **Aprovado em I3:** a etapa 14 não menciona mais `libvirtd`; a matriz monolítico/modular/ausente/daemon-inativo roda por fixture systemd em `tests/test-i0-mutators.sh` e em `tests/test-i3-domain-transactions.sh`, e uma asserção versionada garante uma única definição de `ativar_unidade_systemd`.

### REQ-HOOKS-TX: hooks e XML opcional na mesma transação (P1)

**Fases:** I3 (feita) e I9; ciclo real I13. Estado: código `CONFORME`; D-HOOKS-POSTCOMMIT, D-HOOKS-ROLLBACK-DIVERGE e D-HOOKS-IDEMPOTENCE fechados em I3. O ciclo `prepare > start > release` em GPU real continua em I13.

Incluir `--remover-video` e `--anti-code43` na transação principal ou em segunda transação completa, nunca após commit sem proteção. Validar candidatos com `virt-xml-validate`; armar traps antes da primeira mutação; reler e provar hooks, hostdev, vídeo e Code 43; commit apenas no fim. Rollback cobre arquivos de hooks, modos, serviço e XML e compara semanticamente o original.

**Testes:** ciclo `prepare > start > release`; todas as combinações das opções; falha após cada arquivo/permissão/serviço/XML; sinais; rollback zero-divergente; estado final de todos os recursos.

**Aceite:** toda alteração da etapa 14 é validada e reversível, sem parcialidade pós-commit. **Aprovado em I3:** as opções entram na transação como um único candidato validado e comprovado por releitura; falha e sinal na janela da opção restauram hooks, serviço e XML; o `define` de restauração é relido e comparado semanticamente; e a segunda execução sobre estado convergido é no-op exato (zero efeitos, conteúdo e mtimes invariantes).

### REQ-WINDOWS-STATE: instalação, power state e agent independentes (P1)

**Fases:** suporte XML I3 (feito); decisão/persistência I4/I9; cenário real I13. Estado: `PARCIAL`. Em I3 o core passou a ler e gravar a metadata namespaced `vmpass:windows-install` vinculada ao digest do QCOW2, de forma idempotente e preservando metadata de terceiros, com recusa de digest/data/origem inválidos. Nada disso foi ligado ao fluxo da etapa 13: instalação, power e agent continuam como três eixos separados a decidir em I4/I9.

Persistir evidência durável da instalação independente do guest agent, sem criar simples arquivo `.done`. Preferir metadata namespaced no XML inativo do domínio, vinculada à identidade do QCOW2 e criada apenas após evidência/aceite explícito. Modelar separadamente:

1. Windows instalado ou não comprovado;
2. VM ligada/desligada/indeterminada;
3. agent ausente, temporariamente indisponível ou respondendo.

VM desligada ou perda do agent não apaga a evidência de instalação. Mensagens e status devem distinguir os estados.

**Testes:** ausente; instalado/desligado; ligado sem agent; agent indisponível; agent respondendo; troca do QCOW2; metadata inválida.

**Aceite:** desligamento ou perda do agent não muda a conclusão durável e nenhuma evidência é atribuída ao disco errado.

### REQ-AIRLOCK-VERIFY: prova semântica do Airlock (P1)

**Fases:** I9; IPv4/IPv6 real I13. Estado: `PARCIAL` (deltas D-AIRLOCK-*).

`--verificar` deve reutilizar a avaliação efetiva do apply e consultar `sshd -T -C` para o contexto. Verificar conta, UID/GID, grupos, lock/autenticação, GID/shell/chroot, bindfs configurado e ativo, fingerprint, owner/grupo/modos, política positiva e negativa, IPv4 e IPv6. Texto presente mas inefetivo deve falhar.

**Testes:** sucesso e falha de cada pós-condição; falha pós-publicação; sinais; rollback; IPv4/IPv6; saída inesperada/ausente; estado final.

**Aceite:** o verifier prova a política efetiva, não apenas presença textual.

### REQ-VERIFY-FAILCLOSED: verificadores sem falso sucesso (P1)

**Fases:** correção urgente I1 (feita para `util/atualizar-host.sh --validar`); auditoria completa I9; gate I12.

Auditar todos os `--verificar`/`--validar`. Separar aviso, desconhecido e erro; ferramenta ausente, saída inesperada e parsing incompleto não podem virar sucesso. Fornecer mensagens acionáveis e códigos estáveis; validar pós-condições semânticas, não apenas retorno de comando/texto.

**Aceite:** erro ou estado não comprovado impede status concluído.

### REQ-WAIVERS: dispensas operacionais coerentes (P1)

**Fases:** decisão/schema I4 (feita); menu/status/entrypoints I9. Estado: `CONFORME` quanto à decisão e ao schema. Decisão registrada em I4.8: manter `WORKING_DISK_DISPENSADO` e `HD1_DISPENSADO`, que têm efeito real e testado, e **remover** `AIRLOCK_DISPENSADO` e `BACKUP_DISPENSADO` por migração segura, porque não alteravam pré-requisito, status, execução nem resumo. I9 continua responsável por qualquer integração de menu/status que dependa das duas que ficaram.

Formalizar `AIRLOCK_DISPENSADO` e `BACKUP_DISPENSADO` em pré-requisitos, status, menu, execução e resumo, ou removê-las com migração/depreciação segura se não houver uso legítimo.

Se mantidas:

- decisão deve ser explícita, persistida e auditável;
- mostrar "conscientemente dispensada", nunca "executada/concluída";
- valor negativo mantém bloqueio;
- dispensa é estado de orquestração, não status público nem estado do host;
- `--verificar` continua relatando exclusivamente o estado real em `0/1/2/3`; etapa dispensada e não executada retorna `1` e emite o sentinel V1 normal para esse estado;
- o menu carrega a flag validada separadamente, exibe `[disp]` somente na UI e exclui o pré-requisito apenas nas relações autorizadas por uma matriz de política versionada; `[disp]` nunca entra no sentinel nem é inferido por parsing de texto;
- execução direta nunca infere conclusão pela dispensa: deve informar a política e, para executar a etapa, exigir confirmação e limpar a flag atomicamente antes do commit, ou recusar sem efeito;
- impedir `dispensado+concluído`: se a etapa se tornar realmente concluída, a dispensa deve ser limpa na mesma transação; estado legado contraditório é erro de configuração a migrar, não sucesso;
- resumo e auditoria mostram separadamente estado real, decisão de dispensa, data/origem da decisão e efeito sobre cada pré-requisito.

**Testes:** cada flag e combinação; sentinel e códigos 0/1/2/3; menu/status/resumo; matriz de bloqueios; execução direta; estado legado contraditório; transições dispensada/executada nas duas direções; falha durante limpeza atômica da flag.

**Aceite:** toda flag aceita altera comportamento documentado/testado ou deixa de ser aceita por migração explícita. **Aprovado em I4:** as duas que permanecem alteram comportamento testado; as duas removidas saem do schema, continuam sendo aceitas na leitura sem expor valor, geram aviso e têm as linhas removidas pela etapa 3 em publicação idempotente.

### REQ-DISK-IDENTITY: identidade física workingDisk/HD1 (P1)

**Fases:** integração XML I3 (feita); modelo e fluxo I6. Estado: `PARCIAL` (delta D-DISK-IDENTITY). Em I3 a projeção de disco block passou a expor `wwn`/`serial` declarados no XML; a resolução de identidade física, o cruzamento com HD1 e a recusa de ambiguidade continuam em I6.

Capturar e persistir identidade estável do workingDisk, preferindo WWN, serial e `/dev/disk/by-id`. Resolver `/dev/sdX`, symlinks, partições e device-mapper ao mesmo dispositivo físico e comparar com todos os HD1, inclusive desmontados. Igualdade ou ambiguidade deve ser recusada. Substituição ou ausência de ID exige confirmação explícita e auditável.

**Testes:** montado/desmontado; renomeação sdX; partição/pai; by-id; device-mapper; IDs ausentes; colisão.

**Aceite:** um dispositivo físico nunca ocupa os dois papéis por alias ou estado de montagem.

### REQ-USB-IDENTITY: seleção USB não ambígua (P1)

**Fases:** I6, integração de domínio I3 quando necessária (feita). Estado: `PARCIAL`. Em I3 a enumeração de hostdev USB passou a exigir discriminador (vendor/product ou endereço físico) e a informar quantos pares VID:PID estão duplicados; a etapa 15 recusa a remoção quando há ambiguidade em vez de escolher pela ordem. Serial/porta persistidos e a revalidação antes do attach continuam em I6.

Usar VID:PID apenas quando único. Persistir serial quando disponível; sem serial, usar porta/caminho físico estável. Exibir candidatos e atributos; revalidar discriminador antes de anexar; duplicidade ou ambiguidade deve recusar, nunca escolher arbitrariamente.

**Testes:** único; idênticos com seriais; sem serial em portas distintas; reconexão; seleção obsoleta/ambígua.

**Aceite:** nenhum dispositivo é anexado apenas por ordem de enumeração.

### REQ-NET-TX: bridge/NAT transacional (P1)

**Fases:** harness I0 (feito); inspeção de XML migrada em I3; implementação I7. Estado: `PARCIAL` (deltas D-NET-* seguem abertos). Em I3 a etapa 19 passou a analisar XML de rede e de domínio pelo core, com marcador comparado explicitamente e cardinalidade exigida em `<forward>`, `<bridge>`, blocos `<ip>` e reservas DHCP; a transação, os fingerprints de aplicação/restauração e o `recovery_id` são de I7.

Validar candidato e snapshots; armar traps antes da primeira alteração; publicar/ativar/provar bridge, libvirt e conectividade; commit só após todas as pós-condições. Rollback restaura arquivos e estado ativo, relê e compara semanticamente. Mudança concorrente de qualquer fingerprint causa conflito, não sobrescrita.

**Testes:** sucesso; falha pós-publicação e durante cada ativação; `INT`, `TERM` e `EXIT` em toda janela mutante, sem falso commit; rollback correto e zero-divergente; falha explícita antes e depois de cada ação do próprio rollback, incluindo restauração de arquivo, estado ativo, autostart, XML e consumidores; consumidores; rede homônima não gerenciada; colisões; idempotência; conteúdo/metadados/mtimes e estado final. Rollback não comprovado deve gerar erro grave, preservar evidências e emitir instrução de recuperação manual.

**Aceite:** nenhuma rede parcial e nenhuma recuperação é considerada bem-sucedida sem prova.

---

## 5. Fases de execução

## I0: Baseline, oráculo e caracterização [CONCLUÍDA em 2026-08-14]

Evidências: `tests/i0/{baseline.md,oracle.tsv,traceability.tsv,deltas.tsv}`, `tests/fixtures/i0/`, `tests/lib/i0-fixture-oracle.py`, `tests/lib/mutator-{harness.sh,dispatch.py,safe-command.sh}`, `tests/test-i0-characterization.sh`, `tests/test-i0-mutators.sh`. Resumo do registro original:

- Campanha integral de mutadores: 39 grupos sob bubblewrap, sem skips, raiz mínima em tmpfs, zero mutação real do host.
- Medições autoritativas (LC_ALL=C, cache aquecido, serial): runner completo de dez testes com mediana de 14167 ms (orçamento pós-migração: 28334 ms); `menu.sh --status` com mediana de 3085 ms (orçamento: 6170 ms). O orçamento normativo por alvo é o maior entre 2x a baseline e baseline + 2 s (regra que I10.4/I10.5 reavaliam com nova medição comparável).
- Specs `.kiro/`: seis `tasks.md`, 59 checkboxes; somente a tarefa 1 de `platform-multidistro-core` está marcada. `.kiro/` é ignorado e não deve ser editado fora dos pontos de alinhamento (I11.3/I11.4).
- Auditoria do histórico Git local: não encontrou o conteúdo da configuração local, mas não substitui scanner especializado nem auditoria de remotos; revisão/rotação continua registrada para I4.
- Nenhum dos 13 requisitos da seção 4 estava `CONFORME`; três `AUSENTE` e dez `PARCIAL` (ver `deltas.tsv`).

## I1: Envelope de segurança imediato [CONCLUÍDA em 2026-08-16, reverificada nesta auditoria]

Evidências: `lib/common.sh` (`guard_mutation`), `lib/platform.sh` (perfis/capabilities), `menu.sh`, entrypoints guardados em `etapas/` e `util/`, `.github/workflows/ci.yml`, `tests/{run-gate-i1.sh,check-phase-manifest.sh,test-i1-safety-envelope.sh,test-atualizar-host-validation.sh}`, `tests/i1/mutators.tsv`, `tests/manifests/{i0,i1}-files.txt`. Resumo do registro original:

- `guard_mutation <capability>` é fail-closed para capability ausente, CPU não AMD, provider desconhecido/planejado, derivação não verificada e Silverblue/ostree; menu e entrypoint aplicam defesa em profundidade antes de `sudo`, filho ou efeito.
- `util/atualizar-host.sh --validar`: 29 cenários; falhas produzem `3`, evidência ausente produz `2`, somente ciclo integral comprovado produz `0`.
- Recusa hermética: 29 mutadores diretos e 22 seleções de menu em seis perfis, duas vezes, com fotografias de root/projeto/HOME/TMP provando invariância de conteúdo, tipo, owner, grupo, modo e `mtime_ns`.
- CI: checkout por SHA com histórico completo, Bubblewrap pinado, ShellCheck 0.11.0 validado por SHA-256 (`8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198`); `I1_REQUIRE_SHELLCHECK=1` no gate da CI.
- Limite registrado: em `workflow_dispatch` sem base e no primeiro push de uma referência, o manifesto audita apenas o último commit (`HEAD^`); PRs e pushes normais auditam o intervalo completo.
- Revisão semântica final: APPROVE, bloqueadores 0.

## I2: Fundação do core Python [CONCLUÍDA em 2026-08-17]

**Objetivo:** criar o runtime interno e o protocolo, ainda sem migrar domínios.

**Evidências:** `libexec/passthrough_core_cli.py` (entrypoint único), `libexec/passthrough_core/{__init__,errors,protocol,cli}.py`, `lib/python-core.sh` (ponte única, carregada por `lib/common.sh`), `tests/python/{run_tests.py,test_isolation.py,test_errors.py,test_protocol.py,test_cli.py}` (108 casos), `tests/test-python-core.sh`, `tests/manifests/i2-files.txt` e os passos novos de `tests/run-gate-i1.sh` (manifesto I2, `compileall` com `pycache_prefix` externo, verificação de bytecode residual, guarda de `tests/python` sem wrapper e hook condicional do checker de fronteira de I10).

### Tarefas

- [x] **I2.1:** criar árvore Python e entrypoint; funcionar de qualquer cwd, inclusive caminho com espaços, sem packaging/instalação. Implementar subcomando read-only `version`, que retorna deterministicamente `core_version` e `protocol_version` sem tocar arquivos.
- [x] **I2.2:** implementar exceções e códigos 64/65/66/69/70/73/75; stdout vazio no erro; stderr humano sem traceback por padrão.
- [x] **I2.3:** implementar JSON v1, schema fechado, UTF-8, Unicode, payload vazio/grande/malformado e serialização determinística. Testar transporte por stdin/arquivo `0600` com espaços, quebras de linha, prefixo `-`, metacaracteres e canários; provar que XML/JSON/config/snapshots nunca aparecem em `argv`, que identificadores escalares são validados e que temporários são removidos em sucesso, erro e sinal.
- [x] **I2.4:** implementar `lib/python-core.sh`: raiz física, `python3 -I -S -B`, Python 3.10+, locale/encoding, temporários com trap e mapeamento seguro de status. Antes do primeiro import local, o entrypoint define `sys.dont_write_bytecode = True` e insere somente seu `libexec` físico resolvido no `sys.path`, sem usar cwd, `PYTHONPATH`, `.pth`, `site-packages` ou `dist-packages`.
- [x] **I2.5:** criar `tests/python/run_tests.py` e `tests/test-python-core.sh`. O shell runner resolve a raiz física e inicia `python3 -I -S -B <raiz>/tests/python/run_tests.py`; o runner também define `sys.dont_write_bytecode = True` e adiciona exclusivamente `<raiz>/libexec` resolvido ao `sys.path` antes do discovery. Integrá-lo ao loop histórico `tests/test-*.sh` e cobrir cwd, caminho com espaços, `PYTHONPATH` hostil, permissão, versão/protocolo e ausência de escrita externa. Provar `sys.flags.isolated == 1`, `sys.flags.no_site == 1`, `sys.dont_write_bytecode is True`, ausência de `site-packages`/`dist-packages` em `sys.path`, não execução de `.pth` e ausência de `.pyc`/`__pycache__`. O teste `version` e o runner comparam conteúdo e mtimes do checkout antes/depois; qualquer alteração fora da raiz temporária reprova o gate.

### Gate I2

`compileall` com cache redirecionado, `tests/test-python-core.sh`, `bash -n`, suíte shell e diff-check completo aprovados; `version` responde versão do core e protocolo de qualquer cwd; CLI e testes ignoram `PYTHONPATH`, `.pth` e pacotes globais hostis; flags de isolamento/no-site/no-bytecode estão ativas; checkout permanece sem `.pyc`/`__pycache__` e com conteúdo/mtimes invariantes; busca/revisão confirma ausência de comandos externos no core.

### Resultado do Gate I2 (2026-08-17)

Aprovado. O que ficou comprovado hermeticamente, sem tocar o host:

- **Isolamento:** o entrypoint recusa com código `64` qualquer invocação sem `-I -S -B` (testado com as quatro combinações de flags) e o `sys.path` recebe apenas o `libexec` físico resolvido; `PYTHONPATH` hostil, `sitecustomize.py` e `.pth` canários ficam inertes; nenhum `.pyc`/`__pycache__` aparece no checkout.
- **Protocolo v1:** envelope fechado nas duas direções, serialização determinística independente da ordem de inserção, UTF-8 sem escape, recusa tipada de payload vazio (`66`), malformado, acima do limite, com chave duplicada, com constante não numérica, com versão divergente e fora do schema (`65`).
- **Transporte:** payload com espaços, quebras de linha, prefixo `-`, metacaracteres de shell e canário de segredo trafega íntegro por stdin e por arquivo controlado; um shim de `python3` provou que `argv` recebeu somente flags, subcomando, opções fixas e o localizador aleatório do arquivo, que o arquivo estava em `0600`, `nlink=1` e com o dono correto, e que o canário não apareceu em `argv`, stdout ou stderr. O digest devolvido é idêntico ao `sha256sum` independente dos mesmos bytes.
- **Entrada controlada verificada, não presumida:** a CLI abre o arquivo pelo descritor do diretório pai (`dir_fd`), exige que essa raiz pertença ao processo e negue grupo e outros, e revalida tipo, modo, dono e link count pelo descritor; caminho relativo, componente `.`/`..`, barra dupla, symlink, hardlink, modo permissivo, raiz permissiva, raiz inexistente, diretório e arquivo acima do limite são recusados com código tipado e sem citar o caminho no diagnóstico.
- **Temporários:** raiz privada `0700` por processo, removida em sucesso, em erro e sob `SIGTERM`/`SIGINT` com preservação dos códigos `143` e `130`.
- **Fail-closed do bootstrap:** core ausente, core sem permissão de leitura e `python3` fora do `PATH` produzem `69` com diagnóstico acionável e stdout vazio; nenhum código interno `64-75` mapeia para status público `0` (`69` em verificação mapeia para `2`).
- **Ponte única:** `lib/common.sh` expõe a ponte, o `source` duplo é idempotente e a busca provou que nenhum arquivo de `menu.sh`, `etapas/`, `util/`, `lib/common.sh` ou `lib/platform.sh` referencia `libexec` ou `passthrough_core`.
- **Teste com dentes:** seis mutações injetadas em cópia isolada do repositório (flags aceitas sem isolamento, limpeza de temporários virando no-op, payload em `argv` aceito pela CLI e pela ponte, rótulo de diagnóstico imprimindo valor bruto e remoção da checagem de raiz privada) foram todas reprovadas pela suíte.

Limitações registradas:

- os heredocs Python de produção das etapas continuam existindo e são migrados em I3; I2 apenas proíbe uma segunda rota até este core;
- a simulação de interpretador Python incompatível (versão abaixo de 3.10 em execução) permanece para I12.3; I2 cobre o literal declarado, `python3` ausente, core ausente e core sem permissão;
- os harnesses herméticos de I0/I1 copiam `lib/`, `etapas/` e `util/`, mas não `libexec/`; quando I3 migrar o primeiro consumidor de produção, o staging desses harnesses precisará incluir `libexec/`. Os quatro testes que montam projeto mínimo (`test-bios-output`, `test-runtime-lifecycles`, `test-snapshot-safety` e `test-ubuntu-audit-regressions`) já passaram a copiar `lib/python-core.sh`, porque a fachada `lib/common.sh` carrega a ponte de forma incondicional e fail-closed;
- a busca por comandos externos no core é textual e provisória até `tests/check-python-boundary.py` (I10), que o gate já invoca condicionalmente.

Desempenho medido nesta fase (não substitui I10.4): carregar `lib/python-core.sh` custa cerca de 2 ms e a fachada `lib/common.sh` completa passou de 15 ms para 12 ms depois de a ponte resolver a raiz física com um único subshell, sem `dirname`. `bash menu.sh --status` roda em cerca de 3610 ms com `rc=2` neste host, dentro do orçamento de 6170 ms, mas essa medição não é comparável à baseline de I0 (3085 ms) porque a configuração local mudou de estado entre as duas: I10.4 precisa refazer a medição nas mesmas condições.

## I3: XML/JSON, libvirt e transações de domínio [CONCLUÍDA em 2026-08-17]

**Objetivo:** centralizar dados estruturados e fechar as transações de TRIM/hooks/backend.

**Evidências:** `libexec/passthrough_core/{xmlutil,domain_xml,network_xml,qemu_image}.py`, os 17 subcomandos de domínio em `libexec/passthrough_core/cli.py`, o canal de entrada por pares em `libexec/passthrough_core/protocol.py`, a ponte estendida em `lib/python-core.sh` (`python_core_pares_payload`, `python_core_candidato`, allowlist com `#`, recolhimento da raiz privada), as fachadas de XML em `lib/common.sh`, `etapas/{40,50,51,52,60,70}`, `util/{backup-vm,snapshot-vm}.sh`, `tests/python/{fixtures_i3,test_xmlutil,test_domain_xml,test_network_xml,test_qemu_image,test_cli_domain}.py` (360 casos), `tests/test-i3-domain-transactions.sh`, o oráculo atualizado em `tests/test-i0-mutators.sh` e o suporte de fixture systemd em `tests/lib/{mutator-harness.sh,mutator-dispatch.py}`.

### Tarefas

- [x] **I3.1:** implementar inspeção cardinalizada de discos QCOW2 e block, hostdev de GPU e áudio PCI, NIC por MAC, TPM, NVRAM, vídeo, metadata, hooks e atributos `managed`; cardinalidade ou tipo inesperado deve gerar erro tipado, nunca seleção do primeiro nó.
- [x] **I3.2:** gerar candidatos de CPU/emulator/iothread/NUMA/HugePages/discard/Code 43/vídeo preservando conteúdo não gerenciado; shell continua validando com `virt-xml-validate`.
- [x] **I3.3:** implementar comparação semântica, diff gerenciado e fingerprints para conflito externo.
- [x] **I3.4:** implementar `network_xml.py`: marcador, forward, bridge, CIDR, DHCP, MAC, consumidores e estados inválidos.
- [x] **I3.5:** implementar parser de JSON `qemu-img` e backing chain sem executar `qemu-img`; validar tipos, formato, campos obrigatórios/ausentes e valores inválidos com erros tipados e fail-closed.
- [x] **I3.6:** migrar consumidores em `common.sh`, etapas 14, 17, 19 (apenas XML), 21, snapshot e backup, além dos achados de `tests/i0/traceability.tsv` (11 heredocs Python de produção inventariados); todos os XML/JSON/snapshots usam stdin ou arquivo `0600`, nunca `argv`, com testes de quoting, canários e limpeza.
- [x] **I3.7:** implementar integralmente REQ-TRIM-TX.
- [x] **I3.8:** implementar REQ-LIBVIRT-BACKEND, eliminando backend hardcoded na etapa 14.
- [x] **I3.9:** implementar REQ-HOOKS-TX, incluindo opções XML antes do commit.
- [x] **I3.10:** preparar suporte à metadata de REQ-WINDOWS-STATE sem ainda confundir instalação/power/agent.
- [x] **I3.11:** integrar identidades de disco/USB ao XML apenas onde necessário, sem antecipar o fluxo completo de I6.
- [x] **I3.12:** remover snippets/heredocs Python e consumidores de `xmlstarlet` de produção após o cutover do último consumidor; manter pacote/documentação até I10.

### Gate I3

Equivalência lógica nas fixtures; cardinalidade fail-closed; candidatos válidos; origem intacta; zero comando externo no Python; TRIM/hooks/backend passam matriz de falhas/sinais/rollback; revisão semântica transacional sem bloqueador.

### Resultado do Gate I3 (2026-08-17)

Aprovado. O que ficou comprovado hermeticamente, sem tocar o host:

- **Fronteira de dados estruturados:** todo XML de domínio, XML de rede, XML de snapshot e JSON do `qemu-img` passa pelo core Python. Restaram zero heredocs Python de produção (eram 11) e zero consumidores operacionais de `xmlstarlet` (eram 6 arquivos), verificado por asserção versionada em `tests/test-i3-domain-transactions.sh`; o pacote `xmlstarlet` continua em `etapas/12-pacotes-base.sh` por decisão explícita do plano até I10.
- **Cardinalidade fail-closed:** disco alvo, `<devices>`, `<source>`, `<driver>`, alvo de disco duplicado, hostdev PCI, hostdev USB, NIC por MAC, `memoryBacking/hugepages`, `<forward>`, `<bridge>`, blocos `<ip>` e reservas DHCP recusam zero/múltiplo com erro tipado. A etapa 12 deixou de usar `interface[...][1]`: hoje exige exatamente uma NIC na rede `default` (correção direta da seção 3.5).
- **Entrada não confiável:** `DOCTYPE`, `<!ENTITY`, referência de entidade não predefinida, profundidade acima de 64 níveis e documento acima de 4 MiB são recusados antes de qualquer travessia, o que fecha XXE e expansão exponencial de entidade.
- **Bash não constrói JSON:** o protocolo ganhou o canal de entrada `chave\0valor\0` (`--payload-format=pairs`), simétrico ao de resposta. XML com aspas, barra invertida, `&`, acentos e metacaracteres trafega byte a byte sem escape manual. O envelope JSON continua válido e testado.
- **Transporte fora de `argv`:** um shim de `python3` provou que `argv` recebe somente flags de isolamento, subcomando, opções fixas e os localizadores aleatórios dos arquivos controlados; `QCOW2_PATH`, XML e JSON nunca aparecem. Os arquivos de payload e de candidato estão em `0600`, `nlink=1` e com o dono correto.
- **Candidatos escritos pelo core, publicados pelo Bash:** `domain-candidate` grava somente no temporário controlado (a exceção autorizada pela seção 2.2) e devolve medidas (`changed`, fingerprints antes/depois, `bytes_written`, `sha256`); o XML não passa por stdout. Destino relativo, não canônico, inexistente, simbólico, com dois links, com modo permissivo, sob raiz permissiva e diretório são todos recusados. Candidato recusado nunca toca o destino.
- **REQ-TRIM-TX:** a etapa 21 passou a ter estados explícitos (`PREPARED/APPLIED/VERIFIED/COMMITTED/ROLLING_BACK`), fingerprint do original, candidato validado pelo schema antes da primeira mutação e traps `EXIT/INT/TERM` armados antes do primeiro `define`. Falha antes do define, falha depois do define, falha de releitura, `INT`, `TERM` e `EXIT` agora restauram o original e provam a restauração por releitura semântica. Rollback com `define` retornando zero sem aplicar virou erro grave com evidência preservada; falha explícita do define de rollback também. `130` e `143` continuam preservados.
- **REQ-HOOKS-TX:** `--remover-video` e `--anti-code43` saíram do pós-commit e entraram na transação como um único candidato validado, definido uma vez e comprovado por releitura. Falha e sinal nessa janela restauram hooks, serviço e XML. O `define` de restauração passou a ser relido e comparado semanticamente, então rollback divergente é erro grave.
- **Idempotência exata da etapa 14 (D-HOOKS-IDEMPOTENCE):** sobre estado convergido a etapa termina com **zero efeitos** e manifesto de conteúdo e de metadados/mtime idênticos (o oráculo de I0 media 31 efeitos e manifesto diferente). A convergência compara byte a byte o conjunto renderizado com o instalado, mais dono e modo, e recusa marcador de transação interrompida ou hook antigo pendente.
- **REQ-LIBVIRT-BACKEND:** `libvirt_backend_resolver`/`libvirt_backend_reiniciar` são a única resolução autoritativa, e `ativar_unidade_systemd` passou a ter uma única definição (estava duplicada nas etapas 9 e 10). A etapa 14 não conhece mais `libvirtd`: no perfil modular ela reinicia `virtqemud.service`, sem unidade disponível recusa antes de qualquer efeito, e um daemon que não fica ativo depois do restart derruba a transação com restauração comprovada.
- **REQ-WINDOWS-STATE (preparação):** metadata namespaced `vmpass:windows-install` vinculada ao digest do QCOW2, com leitura e gravação idempotentes, preservação de metadata de terceiros e recusa de digest/data/origem inválidos. Nada foi ligado ao fluxo da etapa 13: instalação, power e agent continuam separados para I4/I9.
- **REQ-USB-IDENTITY e REQ-DISK-IDENTITY (integração mínima):** a enumeração USB exige discriminador (vendor/product ou endereço físico) e informa quantos pares VID:PID estão duplicados; a etapa 15 recusa remoção quando há ambiguidade, em vez de escolher por ordem. A projeção de disco block passou a expor identidade física (`wwn`/`serial`) para o fluxo completo de I6.
- **Higiene de temporários:** a raiz privada da ponte é recolhida assim que fica vazia, então um consumidor com trap próprio não deixa resíduo em `TMPDIR`; as quatro etapas transacionais também chamam `python_core_temporarios_limpar` no trap, cobrindo a janela de sinal.
- **Teste com dentes:** oito mutações injetadas em cópia isolada de `lib/` e `libexec/` (cardinalidade dois aceita como um, estado de discard sempre ativo, candidato que não altera o disco, comparação sempre igual, payload em `argv`, allowlist permissiva, leitura aceitando symlink e candidato não publicado) foram todas reprovadas.

**Revisão semântica do checkpoint I3 (regra 0.1.15): APPROVE, bloqueadores 0.** Quatro achados foram corrigidos dentro da própria fase, não deixados como pendência:

1. `util/snapshot-vm.sh` sondava o core antes de `guard_mutation` (a guarda desse utilitário fica dentro de cada ação), criando um temporário antes do primeiro ponto de recusa. A sondagem foi removida: a ponte já é fail-closed. Regra derivada: nenhum entrypoint mutante consulta o core antes da guarda.
2. A pós-condição das opções da etapa 14 comparava o XML persistido com o candidato por igualdade semântica total, o que produziria falso negativo em host real, onde o libvirt normaliza o domínio ao definir. Passou a ser prova por idempotência: gerar o mesmo candidato sobre o estado persistido tem de resultar em "nada a mudar".
3. `network-overlap` existia testado e sem consumidor. Foi ligado à detecção de colisão de sub-rede da etapa 19, para não deixar subcomando morto no core nem duas aritméticas de CIDR conviverem.
4. `_require_bool` em `domain_xml.py` ficou sem uso depois da coerção local em `qemu_image.py` e foi removido.

Limitações registradas:

- a busca por comandos externos no core deixou de ser textual e passou a ser por AST dentro de `tests/test-python-core.sh`, mas continua provisória até `tests/check-python-boundary.py` (I10.2), que é o gate normativo;
- `virsh attach-device --config` continua sendo o caminho de anexo de GPU/áudio/HD1, porque `managed='yes'` é a autoridade sobre PCI e a pós-condição já é relida; a geração de candidato cobre apenas as alterações que o projeto gerencia por `define`;
- REQ-WINDOWS-STATE, REQ-USB-IDENTITY e REQ-DISK-IDENTITY têm aqui somente a base de dados estruturados; a decisão, a persistência e o fluxo completo são de I4, I6 e I9;
- a rede tem inspeção migrada, mas a transação e o planner backend-neutral continuam em I7: os deltas `D-NET-*` seguem abertos, inclusive o `recovery_id` de rollback não comprovado;
- a medição de TRIM por blocos reais (`D-TRIM-OPERATIONAL`) e o ciclo real de hooks continuam em I13;
- o `virsh define` de restauração é relido pelo próprio `virsh`; um libvirt que mentisse nas duas chamadas não seria detectável por software, o que reforça a necessidade da campanha de I13;
- paridade deliberada de canal para `LOCAL_IDENTIFIER`: o core devolve `backing_filename`, `nvram_path` e as demais fontes de disco pelo canal de máquina (permitido pela seção 3.9 como IPC), e o shell continua imprimindo esses caminhos exatamente como antes da migração, para não reduzir o diagnóstico. A aplicação da tabela de redação a stderr, logs e artefatos de todo o projeto é escopo de I4.2, não de I3;
- `etapas/60-rede-bridge.sh` passou a exigir `virt-xml-validate` (o candidato da NIC é validado pelo schema antes do `define`), o que acrescenta um pré-requisito a essa etapa; ele já vinha com a etapa 9 e o menu não mudou.

Desempenho medido nesta fase (não substitui I10.4): `bash menu.sh --status` roda em cerca de 3,6 s neste host, sem mudança perceptível em relação a I2, porque o menu não consulta XML. As etapas que inspecionam XML trocaram de 2 a 11 processos `xmlstarlet` por chamada por 1 processo Python, o que reduz a contagem de processos nos caminhos de rede e hooks; a medição comparável e o orçamento formal são de I10.4.

## I4: Configuração, ISO legada, dispensas e dados locais [CONCLUÍDA em 2026-08-17]

**Objetivo:** tornar o core Python a única implementação de schema/parsing/persistência de configuração.

**Evidências:** `libexec/passthrough_core/config.py` (schema fechado com classe da seção 3.9 por chave, parser, serializador, migração pré-parser e depreciação), os subcomandos `config-load`, `config-publish`, `config-legacy-scan`, `config-schema` e `config-validate` em `libexec/passthrough_core/cli.py` (com a política de arquivo sensível por descritor de diretório), `python_core_config` em `lib/python-core.sh`, as fachadas `carregar_conf`/`salvar_conf`/`salvar_conf_lote`/`validar_valor_conf`/`conf_migrar_iso_legada`/`conf_migrar_dispensas_depreciadas` em `lib/common.sh`, `etapas/02-detectar-config.sh`, `passthrough.conf.example`, `tests/python/test_config.py` (462 casos no total da suíte), `tests/test-i4-config.sh` e o oráculo atualizado em `tests/test-i0-characterization.sh`.

### Tarefas

- [x] **I4.1:** implementar schema/tipos/relações para BDF, vendor, UUID, caminhos, unidades systemd, inteiros, booleanos, MAC/IP/CIDR e conjuntos de CPU; atribuir explicitamente `SECRET`, `LOCAL_IDENTIFIER`, `RECOVERY_LOCATOR` ou `PUBLIC` a cada chave/campo conforme a seção 3.9, com default fail-closed `SECRET` para campo desconhecido.
- [x] **I4.2:** implementar parser compatível que preserva comentários, vazios, ordem e newline e diagnostica arquivo/linha/chave/classe do erro sem executar conteúdo e **sem imprimir o valor bruto**. Aplicar deterministicamente a tabela 3.9 a IPC, stores, stdout, stderr, logs e artefatos; testar canários `SECRET`/`LOCAL_IDENTIFIER`, `RECOVERY_LOCATOR`, redação por operação e bundles/mapeamentos locais `0600`.
- [x] **I4.3:** implementar persistência no diretório do alvo, recusa de symlink e de arquivo regular sensível com `st_nlink != 1`, owner/mode, flush/fsync e lote todo-ou-nada. Usar `lstat`/descritor seguro e revalidar device, inode, tipo e link count imediatamente antes do rename para bloquear TOCTOU.
- [x] **I4.4:** implementar protocolo NUL validado e allowlist com `printf -v`; limpar variáveis ausentes/obsoletas; sem `source`, `eval` ou command substitution.
- [x] **I4.5:** manter wrappers públicos e semântica de reset/opções externas; migrar todos os consumidores.
- [x] **I4.6:** executar diferencial somente em fixtures, provar round-trip e removê-lo no cutover.
- [x] **I4.7:** implementar integralmente REQ-CONF-ISO como subcomando pré-parser do mesmo core, sem parser Bash paralelo.
- [x] **I4.8:** decidir e implementar REQ-WAIVERS; documentar migração/depreciação se as flags forem removidas.
- [x] **I4.9:** verificar que apenas `passthrough.conf.example` neutro é versionado; preservar conf local; auditar histórico e orientar rotação se houver dados expostos.

### Gate I4

Round-trip completo; malícia inerte; classificação total do schema e canários sem vazamento em canais/artefatos; mesma matriz de variáveis; lote atômico; symlink/hardlink/concorrência/persistência fail-closed; ISO legada segura e idempotente; dispensas semanticamente definidas; revisão de configuração sem bloqueador.

### Resultado do Gate I4 (2026-08-17)

Aprovado. O que ficou comprovado hermeticamente, sem tocar o host:

- **Schema fechado e classificado:** as 39 chaves ativas têm validador, tipo declarado e classe da seção 3.9 (25 `LOCAL_IDENTIFIER`, 14 `PUBLIC`, nenhuma `SECRET` porque o `passthrough.conf` não guarda credencial); chave desconhecida assume `SECRET` por default fail-closed. Um teste versionado prova que o schema do core e a allowlist do shell descrevem exatamente o mesmo conjunto, mais as depreciadas, sem terceira autoridade.
- **Diagnóstico sem valor bruto:** valor inválido produz chave, tipo esperado e classe, nunca o conteúdo. Um canário de segredo plantado no valor de `VM_NAME` não aparece em stdout, stderr nem em `argv`.
- **Caminho do conf fora de `argv`:** o `passthrough.conf` é um `LOCAL_IDENTIFIER`, então a ponte abre o **diretório** do alvo e passa o descritor herdado (`--dir-fd=N`, escalar) enquanto o basename fixo viaja no payload. O core usa `openat`/`renameat` com esse descritor e nunca resolve caminho vindo de dado. Um shim de `python3` provou que `argv` recebeu apenas flags, subcomando, o descritor e o localizador aleatório do payload `0600`.
- **Persistência transacional:** temporário no mesmo diretório, escrita completa, `fsync` do arquivo, metadados reaplicados, revalidação de device, inode, tipo, modo, dono e link count imediatamente antes do `renameat`, e `fsync` do diretório. Comentários, linhas vazias, ordem e a política de newline final são preservados; a chave alterada é substituída na própria linha.
- **D-CONF-HARDLINK fechado (P0):** arquivo sensível com `st_nlink != 1` é recusado na leitura e na publicação, e nenhum dos dois nomes é alterado.
- **D-CONF-TOCTOU fechado (P0):** troca concorrente de inode, mudança de link count, mudança de modo, remoção e substituição por symlink entre a leitura e a publicação produzem conflito (código 75), preservam o alvo e não deixam temporário. Essa cobertura migrou do shim de `mv` para `tests/python/test_config.py`, porque a publicação passou a ser `renameat` dentro do core e deixou de ser interceptável por `PATH`.
- **D-CONF-DURABILITY fechado:** `fsync` do arquivo e do diretório passaram a existir, e o lote é todo-ou-nada com validação completa antes de qualquer escrita (chave desconhecida, repetida, valor fora do tipo e paridade ímpar não publicam nada).
- **Convergência exata:** gravar o mesmo valor duas vezes não altera conteúdo, metadados nem mtime.
- **REQ-CONF-ISO fechado (P0):** o classificador pré-parser lê apenas atribuições literais de uma allowlist mínima e classifica cada ISO como ausente, vazia, válida, inválida ou duplicada **sem abrir, resolver, montar, copiar, testar existência ou privilegiar** o caminho legado, que nunca é reaproveitado nem publicado em diagnóstico. A migração cria backup `0600`, pergunta o novo caminho com a política explicada, e publica todas as chaves pendentes em um único `renameat`, com tolerância válida **somente** para as chaves declaradas e exigindo novo valor para cada uma. Configuração já válida é no-op exato, sem backup novo. A etapa 3 roda a migração antes de `carregar_conf`; `--verificar` continua estritamente somente leitura.
- **REQ-WAIVERS decidido e implementado (D-WAIVERS):** `WORKING_DISK_DISPENSADO` e `HD1_DISPENSADO` **permanecem**, porque não são dispensa de etapa e sim escolha entre montagens mutuamente exclusivas, com efeito real e testado nas etapas 3, 7, 8, 14, 20 e 21; nenhuma delas faz um verificador relatar conclusão sem execução. `AIRLOCK_DISPENSADO` e `BACKUP_DISPENSADO` foram **removidas por migração**, na segunda alternativa que o próprio requisito autoriza: elas eram aceitas e não alteravam pré-requisito, status, execução nem resumo, e o menu não tem matriz de pré-requisitos para elas dispensarem. A depreciação é segura: o parser continua aceitando as linhas sem expor o valor, a carga avisa que a flag não tem efeito, a etapa 3 remove as linhas em publicação idempotente, e o exemplo versionado documenta o motivo. Com isso, toda flag aceita altera comportamento documentado e testado.
- **Relação entre chaves reportada:** caminho definido junto com a dispensa correspondente em `sim` é conflito, reportado em toda carga. As etapas que possuem a relação continuam com o diagnóstico específico delas, que explica como corrigir.
- **I4.9:** apenas `passthrough.conf.example` está rastreado; a configuração local está ignorada, fora do índice e ausente de todo o histórico (`git log --all`). Duas correções saíram desta auditoria: o exemplo versionado deixou de citar identificadores concretos (`0000:0c:00.0`, `10de:2504`, `/dev/nvme0n1`), que violavam a regra 8.1 de clone limpo, e a carga passou a avisar quando o `passthrough.conf` está legível por outros usuários, com a publicação convergindo o modo (grupo perde escrita, terceiros perdem tudo) sem nunca afrouxá-lo.
- **Teste com dentes:** cinco mutações injetadas em cópia isolada (gravação que não persiste, hardlink aceito no arquivo sensível, comentários descartados na reescrita, classificação legada que nunca acha pendência e descritor apontando para o diretório errado) foram todas reprovadas.
- **Cobertura preservada nos harnesses, não reduzida:** a publicação deixou de ser um `mv` interceptável por `PATH`, então o harness I0 passou a modelar `config-publish` como efeito sintético registrado por `mutator-effect-exec`, que substitui o próprio processo pelo interpretador. Isso importa porque a injeção de sinal envia INT/TERM ao processo pai: com uma camada extra de shell no meio, o sinal atingiria o wrapper e o shell da etapa veria apenas um filho morto, sem disparar trap. Com a correção, os 63 cenários de sinal da etapa 19 (11 efeitos em NAT e 10 em bridge, para INT, TERM e EXIT) voltaram a exigir 130/143, rollback completo e ausência de falso commit, e a injeção de falha por efeito continua valendo dentro da janela de publicação.
- **Dois oráculos de I0 invertidos pela convergência:** a segunda execução das etapas 11 (fase B) e 19 (NAT e bridge) virou **no-op exato**, porque valor igual não gera mais rename, não toca metadados e não toca mtime. O oráculo anterior exigia manifesto exato diferente e está citado no comentário `I4:` de cada asserção. A contagem de efeitos foi mantida (1 na etapa 11, 7 em NAT e 6 em bridge) com uma asserção nova de que os efeitos restantes são apenas tentativas de publicação convergentes: o harness conta a tentativa, não a mutação, porque não pode saber de antemão se o core vai convergir e é nessa janela que a injeção precisa continuar existindo.

**Revisão semântica do checkpoint I4: APPROVE, bloqueadores 0.** Três achados corrigidos dentro da fase:

1. A política inicial recusava arquivo ou diretório gravável por grupo, o que quebra `umask 002` legitimamente (0664/0775) e bloquearia operadores sem alternativa. A recusa passou a ser sobre escrita por **outros**, que é a linha real entre o operador e terceiros; contra troca concorrente por alguém do grupo, a proteção é a revalidação de identidade antes do rename. A publicação aperta o modo em vez de recusar.
2. O aviso de modo exposto disparava também para `passthrough.conf.example`, que é neutro por desenho e legível por todos de propósito. O aviso passou a valer só para a configuração real do operador.
3. Duas mutações inicialmente escolhidas eram indetectáveis porque o schema tem guardas independentes no parser e no validador, e a limpeza de chave ausente também tem duas. Em vez de enfraquecer o código para o teste enxergar, as mutações foram trocadas por outras que a bateria realmente prova.

Limitações registradas:

- os validadores primitivos (caminho, MAC, IPv4, CIDR, lista de CPUs, nome de interface) continuam existindo em Bash **e** em Python. Isso é deliberado e não é fallback mutante: o schema tem uma implementação só (o core), mas as etapas validam entrada interativa e dado de runtime em Bash, fora de qualquer configuração. A equivalência é provada por fixtures nos dois lados; a unificação, se um dia valer a pena, dependeria de mover os prompts para o core, o que a fronteira de efeitos do plano proíbe;
- os validadores de nome passaram a usar classes ASCII explícitas em vez de `[[:alnum:]]`. Sob `LC_ALL=C`, que é o locale do gate, o comportamento é idêntico; sob locale UTF-8 o Bash aceitaria letra acentuada em nome de VM ou de usuário, e agora não aceita. É estreitamento deliberado, para o schema não depender do locale do operador;
- I4.2 pede canários de `SECRET` e de `RECOVERY_LOCATOR` com redação por operação e bundles locais `0600`. A parte que a configuração toca está feita (nenhum valor bruto em canal algum, classe declarada por chave, default fail-closed `SECRET`). O mecanismo de bundle de recuperação e o `recovery_id` por operação não têm consumidor em configuração e pertencem a I7 (D-NET-RECOVERY-EVIDENCE), onde há rollback que precisa preservar evidência;
- o diferencial de I4.6 não é uma execução lado a lado das duas implementações, porque a implementação Bash foi substituída no mesmo cutover. O papel de oráculo é cumprido por `tests/test-i0-characterization.sh`, escrito em I0 contra a implementação antiga: ele continua exigindo round-trip, comentários, ordem, metadados, malícia inerte e recusa de symlink, e só mudou onde o próprio plano exigia mudança (hardlink e corridas de publicação), sempre com comentário `I4:` citando o oráculo anterior;
- `backup_e_resetar_config_etapa02` continua copiando `passthrough.conf.example` com `cp` quando a configuração não existe. Isso é efeito de shell por desenho: o core não copia arquivo versionado, e o template precisa chegar com seus comentários.

## I5: CPU, RAM, HugePages, isolamento e IOMMU/VFIO [CONCLUÍDA em 2026-08-17]

**Objetivo:** migrar cálculo puro e transformar boot/VFIO em convergência transacional.

**Evidências:** `libexec/passthrough_core/cpu.py` (snapshot canônico, validação relacional, planner e plano de memória), os quatro subcomandos `cpu-topology`, `cpu-layout`, `cpu-plan` e `cpu-memory` em `libexec/passthrough_core/cli.py`, as fachadas `validar_layout_cpu`/`cpu_topologia_fingerprint`/`cpu_plano_pinning`/`plano_memoria_vm` e os wrappers `ram_reserva_host_mib`/`ram_max_vm_mib` em `lib/common.sh`, o módulo novo `lib/shell/boot.sh` (bootloader, parâmetros de kernel, bloco gerenciado de `vfio.conf` e a transação `iommu_vfio_transacao`/`iommu_vfio_rollback`), `etapas/{02,30,52,53}`, `tests/python/test_cpu.py` (503 casos no total da suíte), `tests/test-i5-cpu-boot.sh`, o oráculo da etapa 11 reescrito em `tests/test-i0-mutators.sh`, o suporte de boot real em `tests/lib/{mutator-harness.sh,mutator-dispatch.py}`, `tests/manifests/i5-files.txt` e o passo novo em `tests/run-gate-i1.sh`.

### Tarefas

- [x] **I5.1:** modelar snapshot de topologia CPU/NUMA/online e canonicalização determinística.
- [x] **I5.2:** validar conjuntos, disjunção, cobertura, CPU offline, core/SMT dividido e reserva mínima do host com mensagens compatíveis.
- [x] **I5.3:** migrar planner da etapa 3; UI/confirmação ficam em Bash; revalidar snapshot antes de persistir.
- [x] **I5.4:** nas etapas 17/18, Python produz intenção/candidato; Bash confirma, altera kernel/XML/reboot, verifica e desfaz; conflito TOCTOU bloqueia.
- [x] **I5.5:** cobrir reconfiguração de RAM/CPU/HugePages/parâmetros, XML com hotplug e elementos/atributos externos não gerenciados, idempotência e reversão; nenhum cutover pode remover ou reordenar semanticamente conteúdo externo.
- [x] **I5.6:** criar e fazer o cutover de `lib/shell/boot.sh` nesta fase, preservando wrappers públicos, e implementar nele integralmente REQ-IOMMU-TX; manter AMD-only. Não manter implementação mutante paralela em `common.sh`/etapas após o cutover.

### Gate I5

Testes atuais e novos passam; reserva do host preservada; ativo diferente de persistente é modelado; candidato validado antes de apply; nenhuma convergência parcial; REQ-IOMMU-TX aprovado hermeticamente; revisão semântica sem bloqueador.

### Resultado do Gate I5 (2026-08-17)

Aprovado. O que ficou comprovado hermeticamente, sem tocar o host:

- **Cálculo de CPU com uma implementação só:** `validar_layout_cpu` deixou de ter algoritmo em Bash e passou a ser fachada sobre `cpu-layout`. As mensagens continuam idênticas às anteriores, porque são API operacional (seção 3.1), e os oráculos de I0 (`tests/test-i0-characterization.sh`) e da tarefa 5 (`tests/test-cpu-hugepages.sh`) continuam valendo sem alteração de expectativa.
- **Snapshot canônico e fingerprint:** reordenar as linhas do `lscpu` não muda o fingerprint; colocar uma CPU offline, mudar o agrupamento de siblings ou a contagem muda. É esse fingerprint que sustenta a recusa por conflito.
- **Conflito TOCTOU bloqueia (I5.4):** a etapa 3 recalcula a topologia entre a confirmação e o `salvar_conf_lote`, e as etapas 17 e 18 revalidam antes de gravar chaves de boot e antes de definir o XML. Topologia alterada no meio do caminho aborta sem gravar nem aplicar. Sem fingerprint capturado, a mutação também é recusada, em vez de seguir com o plano antigo.
- **Planner determinístico:** o recorte por core físico saiu da etapa 3 para `cpu-plan`, que devolve teto, padrão, core de housekeeping e a proposta já aprovada pelo próprio validador. A proposta é idêntica para qualquer ordem de linhas do `lscpu`, o core da CPU 0 nunca vai para a VM e o host mantém um core inteiro (dois quando há seis ou mais).
- **Aritmética de memória unificada:** reserva do host, teto da VM e a relação `VM_RAM_MB`/`HUGEPAGES_1G` passaram a existir só em `cpu-memory`. As etapas 3, 12 e 17 consomem o mesmo resultado, e `ram_reserva_host_mib`/`ram_max_vm_mib` viraram projeções do plano.
- **REQ-IOMMU-TX fechado no código:** a etapa 11 tem uma transação com estados explícitos, traps armados antes da primeira mutação, candidatos gerados e validados antes de qualquer efeito e commit somente após reler boot e `vfio.conf`. O initramfs é regenerado por último e, no rollback, é regenerado de novo para não deixar configuração e initramfs em versões incompatíveis.
- **D-IOMMU-ACTIVE-PERSISTENT fechado hermeticamente:** "ativo neste boot" e "persistido para o próximo" são medidos separadamente e reportados separadamente por `--verificar`. A fase A converge o persistente mesmo quando a cmdline atual já tem os parâmetros, e a fase B só começa quando o kernel em execução prova os dois. No harness, o único caminho pelo qual a cmdline ativa muda é o reboot simulado.
- **D-IOMMU-PARTIALITY fechado:** o oráculo de I0 media a parcialidade que sobrava depois de falha ou sinal (cmdline, `vfio.conf` e/ou initramfs já aplicados). Agora a matriz percorre as oito janelas mutantes em `before`/`after` e os três sinais, e exige em cada uma que os três recursos persistentes voltem ao conteúdo original byte a byte, sem resíduo de temporário, preservando `130`/`143`.
- **Teste com dentes de verdade:** o harness deixou de usar efeitos sintéticos para boot. `kernel_param_add` e `plataforma_atualizar_initramfs` foram removidos dos overrides, `/etc/default/grub`, `/boot/grub/grub.cfg` e `/etc/modules-load.d/vfio.conf` passaram a ser materializados na raiz simulada e `update-grub`/`update-initramfs` são shims que regeneram estado observável. A campanha agora reprova o mock, não o valida.
- **Conteúdo não gerenciado preservado:** `vfio.conf` passou a ter bloco delimitado por marcador. Comentário e módulo de terceiros sobrevivem à transação, o formato antigo (linhas soltas) é absorvido sem duplicar módulo, marcadores desemparelhados são recusados antes de qualquer efeito e os metadados do arquivo existente são preservados por `cp -a` + `tee` + rename.
- **Idempotência exata:** com boot e `vfio.conf` já convergidos, a etapa 11 termina com zero efeitos e manifesto de conteúdo, metadados, inode e mtime idênticos; nem `update-grub` nem `update-initramfs` são chamados.
- **Cutover sem caminho duplo (I5.6):** as oito funções públicas de boot têm exatamente uma definição, em `lib/shell/boot.sh`, e nenhuma em `lib/common.sh`. A fachada apenas carrega o módulo, então os nomes públicos e as variáveis de erro não mudaram para nenhum consumidor.

**Revisão semântica do checkpoint I5 (regra 0.1.15): APPROVE, bloqueadores 0.** Seis achados foram corrigidos dentro da própria fase, dois deles P0 encontrados justamente porque a campanha deixou de exercitar mocks de boot:

1. `iommu_vfio_transacao` é chamada em uma lista `||`, o que suspende o `errexit` dentro dela em todo o corpo da função. A regeneração do initramfs era o único comando mutante sem verificação explícita e teria virado falha silenciosa em vez de rollback. Passou a ser `|| falhar`, com o motivo registrado em comentário. Regra derivada: dentro de função cujo status o chamador testa, nenhum comando mutante pode depender de `set -e`.
2. A publicação de um `vfio.conf` novo escrevia duas vezes (um `tee` vazio para criar e outro com o conteúdo), o que criava uma janela extra de efeito sem necessidade. Virou uma escrita só, com `chmod 0644` apenas no caminho de criação.
3. `vfio_modules_estado` validava os marcadores dentro de uma substituição de comando, então `VFIO_MODULES_ERRO` era publicado em um subshell e o operador receberia recusa sem diagnóstico. A validação foi extraída para `_vfio_marcadores_validos`, chamada no shell atual, e o teste passou a exercitar o caminho real, não só o helper.
4. `validar_particao_cpus` ficou sem consumidor quando `validar_layout_cpu` passou a exigir topologia real. Foi removida, pelo mesmo critério aplicado a `_require_bool` em I3: mantê-la seria conservar uma segunda implementação da mesma política, cega para socket, core e CPU offline.
5. **Defeito P0 encontrado pelo teste novo:** `_grub_aplicar_cmdline` e `_kernelstub_aplicar_estado` colapsavam `130`/`143` em `1`. O subshell protegido preservava o código do sinal, mas o `falhar` seguinte o descartava, então a etapa acima não conseguia distinguir interrupção de falha comum. Enquanto `kernel_param_add` era um efeito sintético do harness, essa janela nunca era exercitada. As duas transações passaram a propagar o código com `exit "$rc_tx"`.
6. **Segundo defeito P0 do mesmo teste:** os arquivos intermediários (`grub.vm-passthrough-<pid>` e `vfio.conf.vm-passthrough-novo-<pid>`) eram criados fora da janela protegida, então um sinal entre criar e publicar deixava lixo ao lado do arquivo real. A cópia e a escrita do intermediário do GRUB entraram no subshell com trap, e o rollback da transação de IOMMU passou a descartar o intermediário do `vfio.conf`. As duas correções foram confirmadas por mutação injetada: sem elas, a campanha reprova em `INT 30/6` e em `before 30/3`.

Limitações registradas:

- a campanha de dois reboots reais (`D-IOMMU-ACTIVE-PERSISTENT`, parte operacional) continua `[H]` em I13: nenhum teste hermético prova boot, initramfs ou binding real;
- `expandir_lista_cpus`, `lista_cpus_valida` e `normalizar_conjunto_cpus` continuam em Bash, pela mesma razão registrada em I4: validam entrada interativa e dado de runtime (`/sys/devices/system/cpu/isolated`), não schema. A equivalência com o core é provada por fixtures dos dois lados;
- o parsing e a escrita de texto de cmdline/GRUB continuam em Bash, dentro de `lib/shell/boot.sh`. A árvore-alvo da seção 2.3 não prevê um `boot.py`, e separar o parsing do backend que o aplica criaria um segundo caminho para o mesmo estado persistente. Esta é a justificativa registrada exigida pela seção 2.3;
- `FSTAB` continua sem passar por `caminho_sistema`: apenas os recursos de boot e `vfio.conf` foram roteados nesta fase, porque são os que a transação de I5 precisa exercitar de verdade. O restante é escopo de I9;
- a etapa 11 `--verificar` passou a devolver `2` (indeterminado) quando a persistência de boot não pode ser lida sem privilégio já autorizado, onde antes devolvia `1`. É a mesma política que as etapas 17 e 18 já usavam e é exigida por REQ-VERIFY-FAILCLOSED: estado não comprovado nunca é pendência silenciosa;
- o bloco gerenciado muda o formato de `vfio.conf` de hosts que já rodaram a etapa 11 antes desta fase. A migração é automática, idempotente e preserva o que não é nosso, mas o texto de reversão da etapa mudou junto e está documentado nela.

## I6: Inventário e identidades físicas

**Objetivo:** normalizar hardware sem mover probes para Python e eliminar ambiguidades de disco/USB.

### Tarefas

- [ ] **I6.1:** definir snapshot de CPU, memória, PCI, discos/IDs, interfaces e boot; distinguir ausente, indisponível, erro e vazio; ordenar deterministicamente.
- [ ] **I6.2:** implementar parsers de inventário atual/legado; rejeitar truncado, duplicado, inconsistente e texto executável.
- [ ] **I6.3:** implementar diff semântico de hardware separado de diferenças de formato e renderização.
- [ ] **I6.4:** migrar etapas 1/3: Bash faz probes/publicação; Python normaliza/compara; relatório permanece atômico.
- [ ] **I6.5:** implementar integralmente REQ-DISK-IDENTITY.
- [ ] **I6.6:** implementar integralmente REQ-USB-IDENTITY.

### Gate I6

Legado continua legível; reordenação não gera falso positivo; mudança real bloqueia/redetecta; probes continuam Bash; alias físico e USB ambíguo são recusados; suíte aprovada.

## I7: Rede transacional e planner backend-neutral

**Pré-condição:** harness da etapa 19 de I0 aprovado (já existe: `tests/test-i0-mutators.sh`).

**Objetivo:** convergir a transação existente da etapa 19 sem perder seus snapshots/traps já corretos.

### Tarefas

- [ ] **I7.1:** modelar snapshots/intenção de uplink, rotas, links, bridge, XML, ativo/persistente/autostart, VMs e configuração, com fingerprints.
- [ ] **I7.2:** usar `ipaddress` para gateway/DHCP/host/VM/broadcast/sobreposição; tratar exceção `proto kernel` exatamente; recusar IPv6/formato ainda não suportado de forma explícita.
- [ ] **I7.3:** gerar planos bridge/NAT determinísticos com precondições, operações abstratas, pós-condições e rollback; nenhum comando/escrita no Python.
- [ ] **I7.4:** detectar consumidores/NIC de todas as VMs por MAC/cardinalidade/marcador.
- [ ] **I7.5:** Bash captura, confirma, revalida fingerprints, aplica, arma traps, verifica, commita e restaura; Python só verifica snapshots.
- [ ] **I7.6:** implementar integralmente REQ-NET-TX e a matriz bridge/NAT/conversões/consumidores/marcador/rota/uplink/concorrência; cobrir `INT`/`TERM`/`EXIT` sem falso commit e injetar falha antes/depois de cada ação do próprio rollback, comprovando erro grave e recuperação orientada quando a restauração divergir ou falhar.
- [ ] **I7.7:** manter a intenção independente de Netplan; não criar parser YAML manual. Providers futuros escolhem backend.

### Gate I7

Transação fail-closed; snapshot+restore por operação; conflito em mudança concorrente; rollback semanticamente comprovado; testes sem rede real; revisão específica de rollback sem bloqueador.

## I8: Plataforma e capabilities em Python

**Objetivo:** migrar detecção read-only sem promover suporte e sem alterar a API de guarda criada em I1.

### Tarefas

- [ ] **I8.1:** implementar parser `os-release` com allowlist, quoting, malícia inerte e normalização explícita de `ID`, lista `ID_LIKE`, `VERSION_ID`/versão e arquitetura. Campo ausente, duplicado ou conflitante deve produzir estado tipado, nunca default silencioso. A arquitetura vem de snapshot capturado pelo Bash (por exemplo, saída validada de `uname -m`), não do arquivo por suposição.
- [ ] **I8.2:** `platform.py` recebe conteúdo de `os-release` e demais evidências já capturados pelo Bash via stdin ou arquivo controlado `0600`; não abre `/etc/os-release`, não consulta o host e não aceita caminho arbitrário vindo do payload. Modelar fatos, origem da evidência e confiança: detectado, inferido, conflitante, ausente e desconhecido; sem `sudo`. Fixtures cobrem ausência de cada campo, duplicata, conflito, arquiteturas, payload com path traversal e prova de que nenhum caminho é aberto.
- [ ] **I8.3:** preservar exatamente o comportamento permitido de Ubuntu/Pop e o bloqueio das demais; Silverblue/ostree ganha perfil imutável diagnóstico explícito.
- [ ] **I8.4:** trocar somente o resolver por trás da fachada/guarda; providers mutáveis permanecem Bash.
- [ ] **I8.5:** executar as 11 fixtures de plataforma com a implementação real, determinismo e invariância; comparação diferencial temporária deve ser removida.
- [ ] **I8.6:** integrar a resolução autoritativa do backend libvirt ao contrato de I3.

### Gate I8

Mesmas operações para Ubuntu/Pop; fixtures não promovem suporte; malícia inerte; detecção sem mutação; desconhecido/imutável fail-closed.

## I9: Modularização Bash e requisitos P1 restantes

**Objetivo:** reduzir `common.sh` a fachada/agregador e fechar estado Windows, Airlock, verificadores e dispensas.

### Tarefas

- [ ] **I9.1:** mapear grafo de `source`; criar guards; impedir ciclos e efeitos em carregamento.
- [ ] **I9.2:** extrair base/UI/privilégio/status preservando wrappers e mensagens.
- [ ] **I9.3:** separar probes de storage/libvirt/rede/hooks sem esconder pós-condições; consolidar e revisar `lib/shell/boot.sh` já criado em I5, sem recriá-lo nem introduzir segundo caminho mutante.
- [ ] **I9.4:** transformar `common.sh` em agregador determinístico, sem algoritmos de domínio.
- [ ] **I9.5:** garantir hooks Bash puros e independentes, com `bash -n` e testes isolados.
- [ ] **I9.6:** testar source isolado, ordem errada com diagnóstico e duplo source idempotente.
- [ ] **I9.7:** implementar integralmente REQ-WINDOWS-STATE.
- [ ] **I9.8:** implementar integralmente REQ-AIRLOCK-VERIFY, reutilizando a mesma avaliação efetiva usada no apply.
- [ ] **I9.9:** concluir REQ-VERIFY-FAILCLOSED em todos os verificadores.
- [ ] **I9.10:** concluir integração de REQ-WAIVERS em menu, pré-requisitos, execução direta, status e resumo.

### Gate I9

`common.sh` não é monolítico; sem ciclos/efeitos no source; mesmos entrypoints e superfície de privilégio; hooks independentes; estados Windows corretos; Airlock semântico; nenhum verifier com falso sucesso; revisão semântica sem bloqueador.

## I10: Convergência, remoção de legado e CI completa

**Objetivo:** tornar a arquitetura nova obrigatória e impedir regressão automática.

### Tarefas

- [ ] **I10.1:** remover parsers/helpers/cálculos/snippets/wrappers/diferenciais mortos; não manter fallback automático.
- [ ] **I10.2:** criar gates estáticos versionados contra heredoc Python de produção, `xmlstarlet` operacional, `subprocess`/`os.system` no core, `source`/`eval` de config/saída e violações de fronteira. Implementar `tests/check-python-boundary.py`: percorrer todo Python de produção por AST e cobrir `Import`, `ImportFrom`, aliases de `importlib.import_module` e chamadas a `__import__`; import dinâmico com alvo não literal é proibido fora do package/testes. Módulo-raiz `passthrough_core` só pode ser importado em `libexec/passthrough_core/**`, no único entrypoint `libexec/passthrough_core_cli.py` e em `tests/**`. Inspecionar também shell, utilitários e templates/renderizações e reprovar `python -m passthrough_core`, `libexec/passthrough_core/__main__.py`, qualquer segundo entrypoint Python de produção e qualquer chamada do entrypoint fora de `lib/python-core.sh`; testes usam allowlist separada e explícita, nunca exceção por diretório de produção inteiro.
- [ ] **I10.3:** tornar Python 3.10+ pré-requisito inicial com diagnóstico acionável; remover `xmlstarlet` de pacotes/docs somente após busca de consumidores vazia; manter `virt-xml-validate`.
- [ ] **I10.4:** agrupar chamadas para reduzir overhead e repetir, nas mesmas fixtures/ambiente/locale/condição de cache da baseline I0, três execuções do runner hermético completo e três de `menu.sh --status`; comparar amostras e medianas por alvo.
- [ ] **I10.5:** cumprir orçamento `max(2x, +2 s)` por alvo ou registrar exceção explícita aceita; não introduzir daemon/cache persistente.
- [ ] **I10.6:** completar CI: suíte não interativa, Python, ShellCheck, validação XML/libvirt por fixtures, guardas/perfis recusados, logs transacionais e versões controladas; nunca mascarar status.
- [ ] **I10.7:** garantir cobertura completa das etapas 11/14/19/20/21: sucesso, falha pré-mudança e após cada publicação, `INT`/`TERM`/`EXIT`, rollback correto, explicitamente falho e zero-divergente, falha antes/depois de cada passo de restauração quando aplicável, estado final, metadados, idempotência e plataforma recusada.

### Gate I10

Sem fallback/legado; gates estáticos aprovados; bootstrap correto; desempenho aceito; CI reproduz o gate global; revisão arquitetural/segurança sem bloqueador.

## I11: Documentação, specs e recuperação

**Objetivo:** alinhar todos os artefatos ao comportamento real, sem promover suporte.

### Tarefas

- [ ] **I11.1:** atualizar README, guia, troubleshooting, o índice `commands-list.md`, os documentos `commands-list/*.md`, exemplo e mensagens. Incluir a correção das divergências listadas na seção 1.4 (títulos ainda dizem somente Pop!_OS).
- [ ] **I11.2:** documentar core, protocolo, fronteira Python/Bash, testes, bootstrap e diagnóstico do Python. Incluir um guia normativo de extensão mostrando: como adicionar subcomando/schema/fixture; como preservar stdout de máquina, stderr humano e códigos; como decidir Python versus Bash pela fronteira de efeitos; e como testar a extensão sem tocar o host.
- [ ] **I11.3:** alinhar spec de plataforma sem perder tarefa realmente concluída e sem promover distro.
- [ ] **I11.4:** alinhar specs de pacotes, boot, rede e libvirt à divisão planner Python/provider Bash.
- [ ] **I11.5:** preservar auditoria/histórico e marcar somente evidência real.
- [ ] **I11.6:** documentar `managed='yes'`, ausência de bind/unbind/new_id manual, AMD-only, GPU única, Secure Boot/assinaturas, persistência, diferenças Ubuntu/Pop e matriz exata de versões.
- [ ] **I11.7:** documentar recuperação/rollback por mutador, distinguindo automático, manual e emergência.
- [ ] **I11.8:** documentar dispensas, três eixos de suporte, Silverblue diagnóstico e por que mocks/comandos candidatos não qualificam hardware/provider.
- [ ] **I11.9:** documentar migração/backup da configuração e resposta a possível exposição de dados locais.
- [ ] **I11.10:** implementar `tests/check-plan-traceability.py`, validar a proveniência R1/R2/R3 da seção 10.2 e comprovar que `commands-list.md` e `commands-list/*.md` existem, são regulares/rastreados e estão sincronizados.

### Coordenação normativa com as specs existentes

É proibido executar em paralelo tarefas de specs que alterem os mesmos contratos/arquivos enquanto a fase de cutover indicada estiver aberta. Checkboxes não são marcados por inferência. A tarefa 1 já concluída de `platform-multidistro-core` deve ser preservada.

| Spec | Área compartilhada que fica congelada | Gate para alinhar/retomar | Execução posterior |
|---|---|---|---|
| `platform-multidistro-core` | detector, capabilities, fachada `platform.sh` e fixtures | I8 aprovado; alinhar em I11.3 sem perder tarefa 1 | providers em I14 |
| `package-profiles-apt-pacman` | APIs de pacotes/provider e módulos shell | I8 e I9 aprovados; alinhar em I11.4 | somente no target ativo da ordem I14 |
| `package-profiles-dnf-zypper` | APIs DNF/zypper e repos | I8/I9/I11 aprovados e contratos APT/Pacman estabilizados | apenas quando a ordem aprovada de I14 chegar a Fedora/openSUSE |
| `boot-initramfs-multidistro` | `boot.sh`, cmdline, bootloader, initramfs e rollback | I5 e I9 aprovados; alinhar em I11.4 | provider ativo em I14 |
| `network-firewall-multidistro` | planner, `network-effects.sh`, firewall e rollback | I7 e I9 aprovados; alinhar em I11.4 | provider ativo em I14 |
| `libvirt-security-storage` | XML/libvirt, MAC, security driver, storage e backend | I3 e I9 aprovados; alinhar em I11.4 | provider ativo em I14 |

Se uma spec contiver mudança conflitante, pausar essa tarefa, registrar o conflito e atualizar a spec após o gate; nunca manter duas implementações mutantes nem contornar a ordem de I14.

### Gate I11

```bash
[[ -f commands-list.md && -d commands-list ]] || {
    printf '%s\n' 'ERRO: índice ou diretório commands-list ausente' >&2
    exit 1
}
shopt -s nullglob
command_docs=(commands-list/*.md)
((${#command_docs[@]} > 0)) || {
    printf '%s\n' 'ERRO: commands-list sem documentos Markdown' >&2
    exit 1
}
git ls-files --error-unmatch -- commands-list.md "${command_docs[@]}" >/dev/null
python3 -I -S -B tests/check-plan-traceability.py \
    --plan PLANO-FINALIZACAO.md \
    --require-range R1-01:R1-15 \
    --require-range R2-01:R2-08 \
    --require-range R3-01:R3-06 \
    --require-canonical-text \
    --require-unified-reference
```

Docs descrevem o código atual; índice e documentos commands-list estão rastreados/sincronizados; proveniência R1/R2/R3 está completa; specs não recriam parser Bash nem competem por contratos compartilhados; tabela de retomada respeitada e tarefa 1 de `platform-multidistro-core` preservada; checkboxes refletem evidência; todos os artefatos declaram o mesmo suporte e recuperação.

## I12: Validação hermética final

**Objetivo:** produzir um release candidate de código sem alegar qualificação de hardware.

### Tarefas

- [ ] **I12.1:** executar o gate global completo duas vezes consecutivas.
- [ ] **I12.2:** testar, sob cwd arbitrário, caminho com espaços, locale diferente, `PYTHONPATH` hostil e ambiente com pacote/arquivo `.pth` canário em site global, cada classe de entrada: `menu.sh --status`, ao menos uma etapa em `--verificar`, um utilitário read-only seguro e a CLI do core. Cada combinação deve preservar diagnóstico, canais e status, com `-I -S -B`, sem carregar o canário nem criar bytecode.
- [ ] **I12.3:** simular Python ausente/incompatível, arquivo/entrypoint do core ausente, core sem permissão e protocolo inválido em menu, etapa, utilitário e CLI; exigir mensagem acionável, stdout sem payload de sucesso, status não zero e zero mutações.
- [ ] **I12.4:** revisar config, XML, privilégio, TOCTOU, traps/sinais, rede, hooks e mensagens.
- [ ] **I12.5:** executar revisão semântica final e corrigir todos os bloqueadores.
- [ ] **I12.6:** revisar definição de pronto, registro, arquivos, comandos e pendências `[H]`; pedir revisão do usuário antes de release.

### Gate I12

Tudo automatizável comprovado; host intacto; nenhuma distro promovida; nenhum temporário/dado real incluído; hardware permanece explicitamente pendente; working tree rastreada, index e arquivos untracked aprovados sem whitespace/erro e contra o manifesto; usuário informado das limitações.

## I13: Qualificação operacional Ubuntu e Pop!_OS

**Objetivo:** qualificar separadamente combinações reais de plataforma/hardware. Requer autorização explícita, ambiente descartável ou recuperável, backups e console fora de banda. **Para o objetivo mínimo do usuário (Ubuntu funcional), a campanha Ubuntu desta fase é o marco decisivo; este host Ubuntu 26.04 com RTX 3060 é um candidato natural, desde que o usuário autorize e tenha backup e console alternativo.**

### Campanha independente para cada distro

- [ ] **I13.1:** registrar distro, kernel, firmware, bootloader, QEMU, libvirt, OVMF, NVIDIA, hardware, topologia e hashes/versões relevantes.
- [ ] **I13.2:** executar instalação limpa das etapas 1 a 21.
- [ ] **I13.3:** executar dois reboots e provar persistência IOMMU/VFIO, módulos e binding de todas as funções da GPU.
- [ ] **I13.4:** após cada reboot, provar estado persistido e ativo de CPU sets/isolamento, topologia e HugePages de 1 GiB por nó NUMA; validar pinning/NUMA no XML e no processo QEMU; iniciar a VM, comprovar alocação/consumo e, após desligá-la, liberação esperada; testar rollback e registrar evidências.
- [ ] **I13.5:** instalar Windows real com OVMF, TPM, VirtIO e agent; validar metadata durável e estados independentes.
- [ ] **I13.6:** testar ciclos completos VM/GPU/display/HD1/hooks, incluindo detach/reattach e recuperação.
- [ ] **I13.7:** testar USB real: dispositivo único; dois dispositivos com mesmo VID:PID discriminados por serial; fallback por porta sem serial; desconexão/reconexão; recusa de seleção obsoleta/ambígua antes do attach; e confirmação da identidade efetivamente anexada. Se o hardware necessário não existir, marcar a capability USB como não qualificada e impedir qualificação completa da combinação.
- [ ] **I13.8:** testar Airlock positivo/negativo por IPv4 e IPv6 e política SSH efetiva.
- [ ] **I13.9:** medir TRIM por blocos/alocação real.
- [ ] **I13.10:** testar bridge/NAT, conectividade, falha induzida e recuperação por console fora de banda. Neste host, enquanto só o Wi-Fi tiver IPv4, a campanha cobre NAT; bridge exige Ethernet ativa.
- [ ] **I13.11:** restaurar backup em mídia/ambiente separado e validar o resultado; "backup criado" não basta.
- [ ] **I13.12:** depois de registrar baseline e capturar snapshots/fingerprints vinculados à operação, executar, em instalação ou clone descartável separado e quando operacionalmente possível, um cenário de falha controlada e comprovar o rollback antes do caminho feliz de boot, libvirt, hooks, rede, Airlock e storage. Nunca invocar rollback sem estado `PREPARED` e snapshot pertencente à mesma operação. Quando essa ordem não for possível, registrar a razão e o controle alternativo antes de prosseguir.
- [ ] **I13.13:** registrar logs redigidos conforme a seção 3.9, evidências, toda intervenção manual e limitações; dados brutos de recuperação seguem a política local `0600`, diagnóstico usa apenas `recovery_id` e nada bruto é publicado.

**Aceite:** apenas a combinação exata testada pode ser marcada como qualificada. Ubuntu qualificado não implica Pop!_OS qualificado, nem vice-versa.

## I14: Providers de novas distribuições (fora do escopo mínimo Ubuntu)

Só começa após o marco `BASE_QUALIFICADA` (I0 a I13 completos, com as campanhas Ubuntu e Pop!_OS de I13 concluídas separadamente). Antes da primeira mudança, o usuário deve aprovar uma lista ordenada contendo **Debian, Fedora Workstation, Arch Linux, CachyOS e openSUSE Tumbleweed**; apenas um target ativo por vez; o próximo só começa após código, testes, documentação e campanha real do anterior. Preferir estabilizar APT/Pacman antes de DNF/zypper. Os comandos candidatos por distro estão em `commands-list/*.md` e não contam como provider nem como suporte.

Contrato mínimo de qualquer provider (capabilities explícitas e recusa de função ausente): 1) pacotes/repositórios; 2) cmdline/bootloader/initramfs; 3) backend libvirt e usuário QEMU; 4) driver NVIDIA compatível; 5) OVMF/UEFI; 6) AppArmor/SELinux; 7) bridge/rede e rollback; 8) UFW/firewalld; 9) reboot, pós-condições e rollback; 10) fixtures usando a biblioteca/provider real, instalação descartável e campanha operacional. Cada distro mutável repete **integralmente I13.1 a I13.13**.

Requisitos específicos por target:

- [ ] **I14.1 Debian:** APT/repositórios Debian, GRUB/update-initramfs, networkd ou backend explícito, NVIDIA sem `ubuntu-drivers`, libvirt/QEMU/AppArmor/OVMF/firewall comprovados.
- [ ] **I14.2 Fedora Workstation:** DNF, dracut+BLS, NetworkManager, firewalld e repositório NVIDIA explicitamente escolhido; SELinux deve permanecer enforcing, com contextos, relabel persistente e políticas/booleans estritamente necessários, testes positivo/negativo e rollback. `setenforce 0` não conta como suporte.
- [ ] **I14.3 Arch Linux:** Pacman, mkinitcpio ou dracut detectado, GRUB ou systemd-boot detectado, rede/firewall/libvirt/QEMU/OVMF/NVIDIA.
- [ ] **I14.4 CachyOS:** tudo de Arch mais kernels/headers próprios, Limine, compatibilidade NVIDIA/kernel/initramfs.
- [ ] **I14.5 openSUSE Tumbleweed:** `zypper dup`, natureza rolling release, dracut, update-bootloader, NetworkManager ou Wicked com rollback, firewalld, AppArmor, libvirt/OVMF/NVIDIA por snapshot qualificado.
- [ ] **I14.6 Fedora Silverblue:** manter diagnóstico ostree/imutabilidade; recusar todo mutador antes de `sudo`; testar menu, execução direta e bibliotecas com conteúdo/metadados/mtimes invariantes. Não implementar mutação tradicional.

**Aceite individual:** dez domínios completos, capabilities, fixtures reais, instalação descartável, matriz exata e repetição aprovada de I13.1 a I13.13 para a combinação. Só então remover `PLANEJADO` daquele target.
**Aceite de I14/plano integral:** os cinco providers mutáveis possuem evidência própria e I14.6 está aprovado; somente então registrar `EXPANSAO_TOTAL_QUALIFICADA`.

---

## 6. Gates globais e CI

### 6.1 Gate local obrigatório por fase

O gate canônico atual é `bash tests/run-gate-i1.sh` (manifesto nominal acumulado de I0, I1, I2 e I3, envelope I1, validador do host, campanha I0 integral sem skips, suíte histórica incluindo `tests/test-python-core.sh` e `tests/test-i3-domain-transactions.sh`, `bash -n`, `compileall` e `py_compile` sob `-I -S` com `pycache_prefix` externo, verificação de bytecode residual no checkout, hook condicional de `tests/check-python-boundary.py`, ShellCheck quando presente, whitespace de working tree/index/untracked). O rótulo da fase vem de `GATE_FASE`, cujo padrão acompanha a fase ativa; o caminho do arquivo é preservado por compatibilidade com a CI versionada. A partir de I2, estenda o mesmo runner ou crie o runner da fase preservando todos os passos; adapte apenas caminhos que ainda não existirem e não silencie falhas reais. Complementos exigidos pelas fases novas:

```bash
set -o errexit -o nounset -o pipefail

project_root="$(git rev-parse --show-toplevel)"
[[ "$(pwd -P)" == "$(realpath -- "$project_root")" ]] || {
    printf '%s\n' 'ERRO: execute o gate na raiz física do repositório' >&2
    exit 1
}

gate_tmp="$(mktemp -d)"
cleanup_gate() { rm -rf -- "$gate_tmp"; }
trap cleanup_gate EXIT INT TERM

git status --short

shopt -s nullglob
shell_files=(menu.sh lib/*.sh lib/shell/*.sh etapas/*.sh util/*.sh)
for file in "${shell_files[@]}"; do
    bash -n "$file"
done

compile_targets=()
[[ -d libexec ]] && compile_targets+=(libexec)
[[ -d tests/python ]] && compile_targets+=(tests/python)
if ((${#compile_targets[@]})); then
    cache_root="$gate_tmp/pycache"
    mkdir -p -- "$cache_root"
    # compileall precisa gerar bytecode, mas somente fora do checkout.
    python3 -I -S -X "pycache_prefix=$cache_root" \
        -m compileall -q "${compile_targets[@]}"

    residual="$(find "${compile_targets[@]}" \
        \( -type d -name __pycache__ -o -type f \( -name '*.pyc' -o -name '*.pyo' \) \) \
        -print -quit)"
    [[ -z "$residual" ]] || {
        printf 'ERRO: bytecode residual no checkout: %s\n' "$residual" >&2
        exit 1
    }
fi

if [[ -d tests/python && ! -f tests/test-python-core.sh ]]; then
    printf '%s\n' 'ERRO: tests/python existe sem tests/test-python-core.sh' >&2
    exit 1
fi

# O loop histórico executa também tests/test-python-core.sh. Esse wrapper usa
# python3 -I -S -B com tests/python/run_tests.py e bootstrap físico controlado.
for test_file in tests/test-*.sh; do
    bash "$test_file"
done

if [[ -f tests/check-python-boundary.py ]]; then
    python3 -I -S -B tests/check-python-boundary.py --root "$project_root"
fi

# Validar separadamente working tree rastreada, index e todos os arquivos novos.
git diff --check --
if git rev-parse --verify HEAD >/dev/null 2>&1; then
    git diff --cached --check HEAD --
else
    git diff --cached --check --
fi

untracked_log_dir="$gate_tmp/untracked"
mkdir -p -- "$untracked_log_dir"
check_n=0
while IFS= read -r -d '' file; do
    check_n=$((check_n + 1))
    check_log="$untracked_log_dir/$check_n"
    check_rc=0
    git diff --no-index --check -- /dev/null "$file" \
        >"$check_log" 2>&1 || check_rc=$?

    # Em --no-index, rc=1 sem diagnóstico significa apenas "arquivo diferente".
    if ((check_rc > 1)) || [[ -s "$check_log" ]]; then
        cat "$check_log" >&2
        printf 'ERRO: arquivo novo não aprovado: %s\n' "$file" >&2
        exit 1
    fi
done < <(git ls-files --others --exclude-standard -z)
```

O registro da fase lista nominalmente todo arquivo untracked inspecionado e confirma que pertence ao manifesto da fase. Arquivo novo fora do manifesto e resíduo como `.pyc`/`__pycache__` reprovam o gate mesmo quando o whitespace é válido. Em `git diff --no-index`, código `1` com stdout/stderr capturados e vazios é a diferença esperada contra `/dev/null`; código `1` com diagnóstico ou código maior que `1` é falha.

Se ShellCheck estiver disponível localmente, executá-lo em todos os arquivos shell; a ausência local deve ser registrada, não escondida nem corrigida por instalação automática. Na CI, ShellCheck é obrigatório e a versão deve ser controlada.

### 6.2 Gates arquiteturais após I10

Criar um teste estático versionado, com exceções explícitas e revisadas, que falhe se encontrar:

- heredoc/snippet Python em produção fora do entrypoint/package;
- consumidor operacional de `xmlstarlet`;
- `subprocess`, `os.system`, `pty` ou biblioteca libvirt no core;
- `source`/`eval` de configuração, saída do Python ou dados não confiáveis;
- parsing de JSON complexo por grep/sed/regex no Bash;
- violação detectada pelo checker AST/fronteira: qualquer forma de import (`import`, `from`, `importlib`, `__import__`), import dinâmico não literal, `-m passthrough_core`, `__main__.py`, segundo entrypoint ou chamada da CLI fora da ponte única;
- hooks que chamem Python ou dependam do checkout;
- fallback mutante para implementação legada.

O gate de fronteira é obrigatório e usa raiz física:

```bash
python3 -I -S -B tests/check-python-boundary.py \
    --root "$(git rev-parse --show-toplevel)"
```

O checker cobre `lib/**`, `libexec/**`, menu, etapas, utilitários, hooks/templates e testes; somente package interno, entrypoint único, ponte única e allowlist explícita de testes são aceitos.

Falso positivo deve ser resolvido melhorando a regra ou criando exceção mínima documentada; nunca removendo silenciosamente o gate.

### 6.3 Requisitos da CI

- ambiente reproduzível e versões registradas;
- suíte shell não interativa;
- `compileall` sob `-I -S` com `pycache_prefix` em diretório temporário e verificação de zero resíduo no checkout; `tests/test-python-core.sh` executa `unittest` sob `python3 -I -S -B` e prova isolamento/no-site/no-bytecode, ausência de pacotes globais e inércia de `.pth`;
- ShellCheck obrigatório;
- validação de XML/candidatos por fixtures e ferramenta apropriada;
- testes de transporte que provam XML/JSON/config/snapshots ausentes de `argv`, temporários `0600` e limpeza em sucesso/erro/sinal;
- canários de classificação/redação da seção 3.9 em stdout, stderr, logs, stores operacionais, bundles locais e artefatos publicáveis;
- `tests/check-python-boundary.py` e, após I11, `tests/check-plan-traceability.py` executados sob `-I -S -B`;
- testes de perfis suportados, planejados, desconhecidos e imutáveis;
- testes de falha/sinais/rollback e preservação de logs transacionais;
- nenhum `|| true`, pipe ou wrapper que masque status;
- artefatos publicáveis de falha suficientes para diagnosticar estado anterior, candidato, observado e rollback, mas somente com fixtures sintéticas ou redação da seção 3.9; estado bruto real fica exclusivamente em bundle local de recuperação `0600`, fora do repositório/CI, com retenção e limpeza registradas;
- nenhuma GPU/VM/rede/disco real necessária no runner.

**Gate de integração:** nenhuma mudança entra como concluída sem suíte, ShellCheck, validação XML e guardas aprovados.

**Observação de manutenção da CI atual:** `.github/workflows/ci.yml` fixa `bubblewrap=0.9.0-1ubuntu0.1` no runner `ubuntu-24.04`; se o repositório de pacotes remover essa versão, atualize o pin explicitamente e registre a mudança.

---

## 7. Estratégia de cutover por domínio

Para configuração, XML/JSON, CPU, inventário, rede e plataforma, repetir exatamente:

1. caracterizar o comportamento atual e casos raros;
2. implementar função pura e testes Python;
3. comparar antigo/novo somente em fixtures;
4. criar wrapper Bash compatível;
5. migrar todos os consumidores do domínio;
6. executar testes direcionados e gate global;
7. remover implementação/diferencial legado;
8. buscar consumidores restantes e provar busca vazia;
9. executar novamente e confirmar idempotência;
10. registrar arquivos, comandos, resultados e limitações.

Não avançar deixando fallback automático. A reversão de uma fase é por mudança Git explícita e não destrutiva, nunca por dois caminhos mutantes em produção.

---

## 8. Documentação e proteção de dados

### 8.1 Configuração distribuída

- versionar apenas `passthrough.conf.example` neutro;
- criar conf local no bootstrap quando necessário;
- manter `passthrough.conf`, lock e backups ignorados;
- se o arquivo voltar ao índice, removê-lo do índice **sem apagar a cópia local**;
- revisar histórico Git por IDs de hardware, caminhos, nomes, rede ou decisões; se houver exposição, orientar rotação e saneamento somente com autorização;
- eliminar defaults Pop!_OS/bootloader/hardware do exemplo;
- documentar migração e backup.

**Aceite:** clone limpo nunca recebe IDs, caminhos ou decisões de outro host.

### 8.2 Conteúdo obrigatório sincronizado

README, guia, o índice `commands-list.md`, os documentos `commands-list/*.md`, exemplo, mensagens e specs devem explicar de modo consistente:

- três eixos de suporte (código implementado; teste hermético aprovado; qualificação em host real para combinação exata);
- AMD-only e critérios futuros para Intel;
- GPU única e riscos de perder display;
- Secure Boot e assinatura de módulos;
- diferenças Ubuntu/Pop e persistência;
- `managed='yes'` e ausência de manipulação PCI paralela;
- Python 3.10+, protocolo e fronteira de privilégio;
- recuperação por mutador: automática, manual e emergência;
- dispensas e seu efeito real;
- matriz exata distro/kernel/QEMU/libvirt/NVIDIA/hardware;
- `PLANEJADO` para providers incompletos;
- Silverblue diagnóstico somente;
- mocks/comandos candidatos não equivalem a qualificação.

---

## 9. Riscos e decisões resolvidas

| Risco/ambiguidade | Decisão obrigatória |
|---|---|
| Migração "sem mudança" versus correções P0/P1 | caracterização, cutover puro e correção funcional são tarefas/testes separados na mesma fase |
| Guarda depende do detector Python de I8 | API e proteção criadas sobre provider Bash em I1 (feito); trocar apenas o resolver em I8 |
| ISO P0 antes da fase de config | caracterizada em I0; solução definitiva em I4; não criar migrador mutante temporário |
| Python escreve config, mas efeitos ficam em Bash | única exceção controlada: persistência da conf do usuário, sem sudo, com rename/fsync/política de arquivo |
| Status 0-3 versus helper 64-75 | códigos internos nunca vazam como concluído; ponte mapeia por contexto |
| Evidência Windows versus "sem progresso em arquivo" | metadata namespaced vinculada ao QCOW2, não `.done`; power/agent continuam sondagens separadas |
| Dispensa versus status concluído | usar metadado visual/político próprio; não declarar etapa não executada como status 0 |
| Silverblue hoje pode ser só "Fedora recusado" | detectar ostree/VARIANT explicitamente e fornecer diagnóstico read-only |
| `IMPLEMENTADO` ambíguo | sempre publicar código/teste hermético/host real em colunas separadas |
| Backend libvirt divergente | uma resolução autoritativa compartilhada pelas etapas 9 e 14 |
| `sshd -T` duplicado | uma função de snapshot efetivo compartilhada por apply e verifier |
| Conf local já aparenta estar corrigida | verificar/convergir idempotentemente; nunca executar remoção cega nem apagar arquivo local |
| Remoção de xmlstarlet | consumidores removidos em I3; pacote/docs somente em I10 após gate vazio; `virt-xml-validate` mantido |
| Qualificação dentro de I12 | I12 é hermético; hardware, dois reboots, TRIM e restore pertencem a I13 |
| Semântica rara perdida | fixtures e diferencial puro antes do cutover |
| TOCTOU | fingerprints e revalidação imediatamente antes de apply/rollback |
| Overhead Python | operações em lote e orçamento medido; sem daemon/cache persistente |
| Specs divergentes | alinhar somente após estabilizar código e nunca marcar por inferência |

---

## 10. Matriz de rastreabilidade funcional

| ID unificado | Conteúdo | Fase principal | Prova automática | Prova real |
|---|---|---|---|---|
| REQ-GUARD | plataforma/capability fail-closed | I1/I8 | menu+direto, zero efeito/mtime | perfis reais em I13/I14 |
| REQ-CONF-ISO | migração pré-parser segura | I4 (feita) | fixtures de legado/falha/metadados aprovadas | opcional em host descartável |
| REQ-TRIM-TX | discard transacional | I3 (feita) | falhas/sinais/rollback XML aprovados | blocos/alocação I13 |
| REQ-IOMMU-TX | boot/VFIO/initramfs atômicos | I5 | fixtures e idempotência | dois reboots I13 |
| REQ-LIBVIRT-BACKEND | monolítico/modular consistente | I3 (feita)/I8 | fixture systemd e estado final aprovados | libvirt real I13 |
| REQ-HOOKS-TX | hooks+XML reversíveis | I3 (feita)/I9 | matriz de falhas/sinais e no-op exato aprovados | GPU/display I13 |
| REQ-WINDOWS-STATE | instalação/power/agent separados | I9 | XML/estados simulados | Windows real I13 |
| REQ-AIRLOCK-VERIFY | política SSH efetiva | I9 | shims IPv4/IPv6 | rede real I13 |
| REQ-VERIFY-FAILCLOSED | nenhum falso sucesso | I1/I9 | matriz ferramenta/saída/status | amostra I13 |
| REQ-WAIVERS | dispensas coerentes ou removidas | I4 (decisão feita)/I9 | config/menu/direto | revisão operacional |
| REQ-DISK-IDENTITY | workingDisk diferente de HD1 físico | I6 | aliases/IDs/DM | discos reais I13 |
| REQ-USB-IDENTITY | USB não ambíguo | I6 | serial/porta/duplicidade | dispositivos reais I13 |
| REQ-NET-TX | rede transacional | I0/I3 (inspeção)/I7 | harness completo | conectividade/console I13 |
| CORE-PROTOCOL | Python stdlib, `-I -S -B`, no-bytecode, JSON/NUL e payload fora de argv | I2/I3 | unittest/cwd/locale/PYTHONPATH/.pth/transporte/mtime | não aplicável |
| DOMAIN-XML-CORE | XML de domínio/rede/snapshot e JSON do qemu-img com cardinalidade fail-closed | I3 | fixtures sintéticas, canários, shim de argv e mutações injetadas | libvirt/storage reais I13 |
| CONFIG-CORE | schema/parser/atomicidade/classificação | I4 (feita) | round-trip/malícia/TOCTOU/canários aprovados | não aplicável |
| CPU-CORE | topologia/planner | I5 | fixtures NUMA/SMT/offline | pós-reboot I13 |
| INVENTORY-CORE | normalização/diff | I6 | atual/legado/ordem | hardware I13 |
| PLATFORM-CORE | fatos/capabilities | I8 | 11 fixtures | providers I13/I14 |
| SHELL-MODULES | common agregador | I9 | source/ciclos/hooks | não aplicável |
| CI-GATES | arquitetura e regressão | I10/I12 | pipeline completo 2x | não aplicável |
| DOCS-SPECS | comportamento real | I11 | revisão/gates de links quando houver | revisão humana |
| QUAL-UBUNTU-POP | campanha 00-70 | I13 | não substitui | obrigatória por combinação |
| PROVIDERS | dez domínios por distro | I14 | fixtures reais | campanha por combinação |

### 10.1 Rastreabilidade de componentes atuais para módulos-alvo

| Origem atual | Destino principal | Fase |
|---|---|---|
| parser/persistência de config | `config.py` + wrapper (feito) | I4 |
| XML de disco/GPU/hooks/TRIM | `domain_xml.py` (feito) | I3 |
| XML/topologia de CPU | `cpu.py` + `domain_xml.py` | I3/I5 |
| inventário | `inventory.py` | I6 |
| plataforma/os-release | `platform.py` | I8 |
| etapa 3 | config/cpu/inventory | I4/I5/I6 |
| etapa 14 | domain XML + libvirt shell (XML e backend feitos) | I3/I9 |
| etapa 17 | CPU/domain XML + boot shell | I3/I5 |
| etapa 19 | network XML/planner + network-effects shell (XML feito) | I3/I7 |
| etapa 21 | domain XML + transação shell (feito) | I3 |
| snapshot/backup | domain XML/qemu image (feito) | I3 |
| UI/sudo/status | módulos shell | I9 |
| probes/efeitos | probes e módulos de efeito shell | I9 |

### 10.2 Proveniência nominal das auditorias de consolidação

As revisões R1, R2 e R3 foram realizadas durante a consolidação de 13 de agosto de 2026, antes da remoção dos planos antigos. Como seus relatórios eram saídas de sessão e não arquivos normativos, **esta seção é o arquivo primário canônico de seus textos nominais** (transportada integralmente do plano integrado, que este documento substitui). Eles não substituem P0/P1: rastreiam correções necessárias para que a união permaneça executável. Relações muitos-para-um são permitidas, mas cada ID aparece exatamente uma vez.

| Revisão | ID | Texto nominal arquivado | Base nos planos de origem | Requisito/cláusula integrada | Tarefa/teste/gate |
|---|---|---|---|---|---|
| R1 | R1-01 | runner Python isolado sem caminho controlado para o core | Migração F1.5/gate F1 | seções 2.3 e 3.8 | I2.5; Gate I2/6.1 |
| R1 | R1-02 | dispensa sem contrato compatível com status 0-3/sentinel | Melhorias P1-06; Migração 7.1 | seção 3.1; REQ-WAIVERS | I4.8/I9.10; testes de sentinel/transição |
| R1 | R1-03 | I14 sem escopo concluível nem ordem autoritativa | Melhorias 10-12 | governança I14; seções 15-16 | marcos BASE/EXPANSAO |
| R1 | R1-04 | provider novo sem herdar campanha operacional completa | Melhorias 9 e 11.3 | contrato I14 | repetição I13.1-I13.13 |
| R1 | R1-05 | rede sem EXIT e falha dentro do rollback | Migração F6.6 | REQ-NET-TX | I0.7/I7.6/I10.7 |
| R1 | R1-06 | rollback real ordenado sem estado preparado | Migração F11.5/F11.6 | I13.12; seção 14 | cenário controlado PREPARED |
| R1 | R1-07 | benchmark sem alvos reproduzíveis | Migração F0.7/F9.4 | I0.9/I10.4 | runner completo + menu status |
| R1 | R1-08 | versão do core ausente | Migração F1.1 | seção 3.8 | I2.1/Gate I2 |
| R1 | R1-09 | validação final sem matriz de entrypoints/bootstrap | Migração F11.2/F11.3 | I12.2/I12.3 | menu/etapa/util/CLI |
| R1 | R1-10 | casos raros XML/QEMU/hotplug implícitos | Migração F2.1/F2.5/F4.5 | seção 3.5; I0.5 | I3.1/I3.5/I5.5 |
| R1 | R1-11 | diagnóstico de config podia vazar valor sensível | Migração F3.2 | seção 3.9 | I4.1/I4.2; canários |
| R1 | R1-12 | política nova de hardlink sem decisão/teste | contratos de arquivo/config | seção 3.2; REQ-CONF-ISO | I0.4/I4.3 |
| R1 | R1-13 | boot.sh exigido antes de sua extração | Migração F4/F8 | árvore 2.3 | I5.6 cria; I9.3 consolida |
| R1 | R1-14 | provider Fedora sem contextos/políticas SELinux | Melhorias 10.2 | I14.2 | testes enforcing/rollback |
| R1 | R1-15 | documentação de extensão do core genérica | Migração F10.2 | I11.2 | Gate I11 |
| R2 | R2-01 | `-I` ainda admitia site-packages/.pth | Migração F1 | seções 2.2 e 3.8 | `-I -S -B`; I2/Gate/CI |
| R2 | R2-02 | XML/JSON/config/snapshot podiam entrar em argv | Migração protocolo 10 | seção 3.8 | I2.3/I3.6/6.3 |
| R2 | R2-03 | redação sem classificação normativa/canais | segurança/config/logs | seção 3.9 | I4.1/I4.2; canários CI |
| R2 | R2-04 | gate de import não abrangia todo repositório | Migração F9.2 | I10.2; seção 6.2 | checker AST/fronteira |
| R2 | R2-05 | campanha real omitia CPU isolation/HugePages | Migração F4/F11 | I13.4; seção 11.2 | evidência reboot/XML/QEMU |
| R2 | R2-06 | campanha real omitia identidade USB | Melhorias P1-08 | REQ-USB-IDENTITY | I13.7/I14 |
| R2 | R2-07 | contrato os-release perdeu campos/fronteira | Migração F7.1 | I8.1/I8.2 | fixtures ausência/conflito/path |
| R2 | R2-08 | coordenação de seis specs ficou genérica | Migração 27 | tabela I11 | gates I3/I5/I7/I8/I9/I11 |
| R3 | R3-01 | LOCAL_IDENTIFIER contradizia stores e localização do bundle | contratos config/inventário/XML/rede | seção 3.9 | canários de stores/recovery_id |
| R3 | R3-02 | `compileall`/imports deixavam bytecode no checkout | Migração gates F1/F11 | seções 2.2 e 3.8 | I2/6.1 cache externo+mtime |
| R3 | R3-03 | ponte única contornável por imports/entrypoints alternativos | Migração árvore/dependências/F9.2 | I10.2; seção 6.2 | `check-python-boundary.py` |
| R3 | R3-04 | diff-check não cobria index nem untracked | gates globais | seção 6.1 | três comparações + manifesto |
| R3 | R3-05 | achados R1/R2 sem proveniência nominal | rastreabilidade/aceite | esta seção | `check-plan-traceability.py` |
| R3 | R3-06 | referência ambígua entre índice e diretório commands-list | Migração F10.1; docs | seções 1.4 e 8.2 | I11.1/Gate I11 |

Gate obrigatório em I11:

```bash
python3 -I -S -B tests/check-plan-traceability.py \
    --plan PLANO-FINALIZACAO.md \
    --require-range R1-01:R1-15 \
    --require-range R2-01:R2-08 \
    --require-range R3-01:R3-06 \
    --require-canonical-text \
    --require-unified-reference
```

O checker reprova ID ausente/duplicado, texto nominal vazio, base/cláusula/tarefa/gate vazios ou vínculo inexistente. Não inferir proveniência pela quantidade/ordem da matriz funcional nem fabricar relação a partir de linhas mutáveis.

---

## 11. Definições objetivas de "completo"

### 11.1 Código Ubuntu/Pop completo

Somente quando:

- zero requisito P0/P1 aberto;
- todo mutador possui guarda, precondição, candidato, trap, pós-condição, commit e rollback por estado quando aplicável;
- rollback é relido e comparado semanticamente;
- verificadores não têm falso sucesso;
- config/exemplo são neutros e seguros;
- arquitetura híbrida e gates de I10 estão ativos;
- CI, ShellCheck e XML passam;
- docs/specs estão sincronizadas;
- matriz exata de versões existe;
- I12 foi aprovado duas vezes.

Isso significa **código completo**, não hardware qualificado.

### 11.2 Ubuntu/Pop operacionalmente qualificado

Além de 11.1, exige campanha I13 separada: 00-70 limpo, dois reboots, IOMMU/VFIO, CPU sets/isolamento e HugePages de 1 GiB por NUMA comprovados no host/XML/QEMU, Windows real, GPU/HD1/hooks, identidade USB real sem ambiguidade, Airlock IPv4/IPv6, TRIM físico, rede/recuperação, backup restaurado e evidências.

### 11.3 Nova distro completa

Além da base estável: provider nos dez domínios, capabilities, fixtures usando implementação real, instalação descartável, matriz exata e repetição integral de I13.1 a I13.13 com evidência própria. O plano integral exige as cinco distros mutáveis de I14 e o gate Silverblue; `PLANEJADO` só é removido individualmente após prova da combinação.

---

## 12. Registro obrigatório de execução

Não apagar falhas antigas; adicionar uma linha por tentativa relevante.

| Fase | Data | Commit/base | Arquivos | Comandos/testes | Resultado | Falhas/limitações | Evidências | Próxima ação |
|---|---|---|---|---|---|---|---|---|
| I0 | 2026-08-14 | `8b34a4c` | `tests/i0`, `tests/fixtures/i0`, harnesses e testes I0 | campanha full com 39 grupos; suíte 10/10; Bash 42/42; AST 2/2; whitespace/TSV | APROVADO; revisão semântica issues 0 | mocks não qualificam hardware/boot/rede/libvirt/Windows reais | `tests/i0/baseline.md`, `oracle.tsv`, `traceability.tsv`, `deltas.tsv` | executar I1 |
| I1 | 2026-08-16 | `8b34a4c` + working tree | guarda/CI/testes I1 (ver evidências na seção 5, fase I1) | `I1_REQUIRE_SHELLCHECK=1 bash tests/run-gate-i1.sh` retornou 0; envelope 29+22 em 6 perfis 2x; validador 29 cenários; manifesto 52 arquivos | APROVADO; revisão semântica APPROVE, bloqueadores 0 | fallback de manifesto em `workflow_dispatch`/primeiro push audita só o último commit | `tests/i1/mutators.tsv`, `.github/workflows/ci.yml`, suíte I1 | executar I2 |
| Auditoria | 2026-08-16 | `8b34a4c` + working tree | nenhum arquivo de produção alterado | `bash -n` total; CRLF/placeholders zero; suíte 12/12 (62 s); `bash tests/run-gate-i1.sh` local sem ShellCheck reexecutado com sucesso; `menu.sh --status` rc=3 por configuração local divergente | I0/I1 CONFIRMADAS; I2+ não iniciadas; `libexec/` inexistente | host com conf de outra máquina (seção 1.3); ShellCheck/xmlstarlet/virt-xml-validate/virsh ausentes no host | este documento, logs da sessão | consolidar planos, executar I2 |
| Correção prompts etapa 3 | 2026-08-16 | `8b34a4c` + working tree | `lib/common.sh`, `etapas/02-detectar-config.sh`, `tests/test-ubuntu-audit-regressions.sh`, este plano (seção 1.3.1) | regressões novas aprovadas; suíte completa 12/12 aprovada; `bash -n` nos três arquivos; gate canônico completo reexecutado sobre o estado final | APROVADO herméticamente; prompts de ISO, VM_NAME, TRANSFER_USER e AIRLOCK_DIR reperguntam com diagnóstico em vez de abortar a detecção | não cobre valor legado de ISO já gravado no conf (REQ-CONF-ISO, I4); sem commit por decisão do usuário | seção 1.3.1; logs da sessão | usuário: baixar ISOs e seguir etapas 4+; executor: I2 |
| I2 (tentativa 1) | 2026-08-17 | `8b34a4c` + working tree | mesmos arquivos da tentativa final | `bash tests/run-gate-i1.sh` | **REPROVADO (rc=1)** | `lib/common.sh` passou a carregar `lib/python-core.sh` de forma incondicional, mas quatro testes montam projeto mínimo copiando apenas `common.sh` e `platform.sh`; `tests/test-bios-output.sh` falhou com `No such file or directory`. Corrigido acrescentando a ponte aos cinco pontos de staging, sem tornar o `source` condicional | `scratchpad/gate-i2-final.log` | corrigir staging e reexecutar |
| I2 | 2026-08-17 | `8b34a4c` + working tree | `libexec/passthrough_core_cli.py`, `libexec/passthrough_core/{__init__,errors,protocol,cli}.py`, `lib/python-core.sh`, `lib/common.sh` (uma linha de `source`), `tests/python/*.py`, `tests/test-python-core.sh`, `tests/manifests/i2-files.txt`, `tests/run-gate-i1.sh`, staging de `tests/test-{bios-output,runtime-lifecycles,snapshot-safety,ubuntu-audit-regressions}.sh`, este plano | baseline `bash tests/run-gate-i1.sh` = 0 antes da primeira mudança; `python3 -I -S -B tests/python/run_tests.py` = 108 casos; `bash tests/test-python-core.sh`; gate canônico completo aprovado (rc=0): manifesto I2 com 65 arquivos nominais, 13 testes da suíte, `bash -n` em 49 arquivos, `compileall` em 2 árvores mais `py_compile` em 12 arquivos sem bytecode residual, whitespace de 65 arquivos untracked; seis mutações injetadas reprovadas em cópia isolada | APROVADO | heredocs Python de produção seguem em I3; Python incompatível em execução fica para I12.3; harnesses de I0/I1 ainda não copiam `libexec/`; busca de comandos externos é textual até I10 | seção 5 (fase I2, resultado do gate), logs da sessão | executar I3 |
| I3 (tentativa 1) | 2026-08-17 | `8b34a4c` + working tree | mesmos arquivos da tentativa final | `bash tests/run-gate-i1.sh` | **REPROVADO (rc=1)** | `util/snapshot-vm.sh` sondava `python_core_disponivel` antes de `guard_mutation` (a guarda desse utilitário fica dentro de cada ação), então o envelope I1 viu a criação do temporário do core antes do primeiro ponto de recusa. Corrigido removendo a sondagem: a ponte já é fail-closed com código 69 e diagnóstico acionável | `scratchpad/gate-i3-run1.log` | corrigir ordem e reexecutar |
| I3 | 2026-08-17 | `8b34a4c` + working tree | `libexec/passthrough_core/{xmlutil,domain_xml,network_xml,qemu_image}.py`, `libexec/passthrough_core/{cli,protocol}.py`, `lib/python-core.sh`, `lib/common.sh`, `etapas/{12,20,21,40,41,50,51,52,60,70}`, `util/{backup-vm,snapshot-vm}.sh`, `tests/python/{fixtures_i3,test_xmlutil,test_domain_xml,test_network_xml,test_qemu_image,test_cli_domain}.py`, `tests/test-i3-domain-transactions.sh`, `tests/{test-i0-mutators,test-audit-safety,test-ubuntu-audit-regressions,test-python-core}.sh`, `tests/lib/{mutator-harness.sh,mutator-dispatch.py,i1-guard-harness.sh}`, `tests/manifests/i3-files.txt`, `tests/run-gate-i1.sh`, este plano | baseline `bash tests/run-gate-i1.sh` = 0 antes da primeira mudança; `python3 -I -S -B tests/python/run_tests.py` = 360 casos; `bash tests/test-i3-domain-transactions.sh` (10 grupos, 8 mutações reprovadas); campanha I0 `full` sem skips com os oráculos das etapas 14 e 20 atualizados para o comportamento transacional; gate canônico completo aprovado (rc=0): manifesto I3 com 77 arquivos nominais, campanha I0 `full` com 40 grupos de cenários, 13 testes da suíte, `bash -n` em 50 arquivos, `compileall` em 2 árvores mais `py_compile` em 22 arquivos sem bytecode residual, whitespace de 77 arquivos untracked | APROVADO | TRIM físico, ciclo real de hooks/GPU e libvirt real seguem `[H]` em I13; `D-NET-*` seguem abertos para I7; a busca por comandos externos no core virou AST mas continua provisória até `tests/check-python-boundary.py` (I10.2); `virsh attach-device --config` continua sendo o caminho de anexo sob `managed='yes'`; ShellCheck continua ausente neste host (a CI versionada o provisiona e o exige); a segunda execução consecutiva do gate global é requisito de I12.1, não de I3 | seção 5 (fase I3, resultado do gate), `scratchpad/gate-i3-A.log` | executar I4 |
| I4 (tentativa A) | 2026-08-17 | `8b34a4c` + working tree | mesmos arquivos da tentativa final | `bash tests/run-gate-i1.sh` | **REPROVADO (rc=1)** | o envelope I1 barrava `python3`, `mktemp` e `rm` de forma absoluta, incompatível com a carga de configuração pela ponte antes da guarda. Corrigido com wrappers restritos à raiz do harness, log próprio (`I1_SCOPED_LOG`) e parada dura mantida para `config-publish`, que é o efeito real | `scratchpad/gate-i4-A.log` | ensinar o envelope e reexecutar |
| I4 (tentativa B) | 2026-08-17 | `8b34a4c` + working tree | mesmos arquivos da tentativa final | `bash tests/run-gate-i1.sh` | **REPROVADO (rc=1)** | `tests/test-atualizar-host-validation.sh` (caso `config-ilegivel`) esperava diagnóstico de permissão que o core não emitia. Corrigido com ramo dedicado de `PermissionError` com mensagem acionável, e o teste passou a aceitá-la com comentário `I4:` | `scratchpad/gate-i4-B.log` | separar erro de permissão e reexecutar |
| I4 (tentativa C) | 2026-08-17 | `8b34a4c` + working tree | mesmos arquivos da tentativa final | `bash tests/run-gate-i1.sh` | **REPROVADO (rc=1)** | a etapa 19 em NAT caiu de 11 para 4 efeitos porque a publicação deixou de ser um `mv` interceptável por `PATH`. Corrigido modelando `config-publish` como efeito sintético do harness, o que restaurou a contagem, a ordem e a injeção de falha/sinal naquela janela | `scratchpad/gate-i4-C.log` | modelar o efeito e reexecutar |
| I4 (tentativa D) | 2026-08-17 | `8b34a4c` + working tree | mesmos arquivos da tentativa final | `bash tests/run-gate-i1.sh` | **REPROVADO (rc=1)** | `INT nat/1` devolveu 1 em vez de 130: o efeito sintético era registrado por um processo neto, então `os.kill(getppid())` atingia o wrapper intermediário e o shell da etapa nunca recebia o sinal nem disparava o trap. Corrigido com `mutator-effect-exec`, que registra o efeito e substitui o próprio processo pelo interpretador, mantendo-o filho direto do shell da etapa | `scratchpad/gate-i4-D.log` | corrigir a árvore de processos e reexecutar |
| I4 (tentativa E) | 2026-08-17 | `8b34a4c` + working tree | mesmos arquivos da tentativa final | `bash tests/run-gate-i1.sh` | **REPROVADO (rc=1)** | o oráculo de I0 exigia manifesto exato diferente na segunda execução da etapa 19, porque cada `salvar_conf` reescrevia o arquivo e mexia no mtime. Com a publicação convergente do core, os dois modos passaram a ser no-op exato; o oráculo foi invertido com comentário `I4:` citando o anterior, e a contagem de efeitos foi mantida com asserção nova de que os efeitos restantes são apenas publicações convergentes | `scratchpad/gate-i4-E.log` | inverter o oráculo e reexecutar |
| I4 | 2026-08-17 | `8b34a4c` + working tree | `libexec/passthrough_core/config.py`, `libexec/passthrough_core/cli.py`, `lib/python-core.sh`, `lib/common.sh`, `etapas/02-detectar-config.sh`, `passthrough.conf.example`, `tests/python/test_config.py`, `tests/test-i4-config.sh`, `tests/test-i0-characterization.sh`, `tests/test-i0-mutators.sh`, `tests/test-atualizar-host-validation.sh`, `tests/lib/{mutator-harness.sh,mutator-dispatch.py,mutator-safe-command.sh,i1-guard-harness.sh}`, `tests/manifests/i4-files.txt`, `tests/run-gate-i1.sh`, este plano | `python3 -I -S -B tests/python/run_tests.py` = 462 casos; `bash tests/test-i4-config.sh` (10 grupos, 5 mutações reprovadas); campanha I0 `full` sem skips; gate canônico completo aprovado (rc=0) com manifesto I4 de 81 arquivos nominais | APROVADO; revisão semântica APPROVE, bloqueadores 0 | validadores primitivos seguem duplicados em Bash por serem de entrada interativa, com equivalência provada por fixtures; nomes passaram a usar classes ASCII explícitas; `recovery_id` e bundles de recuperação pertencem a I7; `backup_e_resetar_config_etapa02` continua copiando o exemplo versionado com `cp` por desenho | seção 5 (fase I4, resultado do gate), `scratchpad/gate-i4-F.log` | executar I5 |
| I5 (tentativa 1) | 2026-08-17 | `8b34a4c` + working tree | mesmos arquivos da tentativa final | `bash tests/run-gate-i1.sh` | **REPROVADO (rc=1)** | quatro testes que montam projeto mínimo copiavam só `common.sh`, `platform.sh` e `python-core.sh`, e a fachada passou a carregar `lib/shell/boot.sh` de forma incondicional. Corrigido acrescentando o módulo aos cinco pontos de staging, sem tornar o `source` condicional (mesma decisão de I2) | logs da sessão | corrigir staging e reexecutar |
| I5 (tentativa 2) | 2026-08-17 | `8b34a4c` + working tree | mesmos arquivos da tentativa final | campanha I0 `full` | **REPROVADO (rc=1)** | `falha etapa 11 before/8 deveria retornar não zero`: `iommu_vfio_transacao` é chamada em lista `||`, o que suspende o `errexit` em todo o corpo da função, e a regeneração do initramfs era o único comando mutante sem verificação explícita. Corrigido com `|| falhar` em cada comando mutante da transação e o motivo registrado em comentário | logs da sessão | verificar explicitamente e reexecutar |
| I5 (tentativa 3) | 2026-08-17 | `8b34a4c` + working tree | mesmos arquivos da tentativa final | campanha I0 `full` | **REPROVADO (rc=1)** | `INT etapa 11/4 (esperado=130; obtido=1)`: a transação do GRUB preservava o código do sinal dentro do subshell, mas o `falhar` seguinte o convertia em `1`. Só apareceu agora porque `kernel_param_add` deixou de ser efeito sintético do harness. Corrigido propagando `130`/`143` em `_grub_aplicar_cmdline` e `_kernelstub_aplicar_estado` | logs da sessão | preservar o código do sinal e reexecutar |
| I5 (tentativa 4) | 2026-08-17 | `8b34a4c` + working tree | mesmos arquivos da tentativa final | campanha I0 `full` | **REPROVADO (rc=1)** | `sinal INT na etapa 11/6 deixou estado persistente parcial`: o intermediário do `vfio.conf` era criado fora da janela protegida e sobrevivia ao sinal. Corrigido movendo a criação/escrita do intermediário do GRUB para dentro do subshell com trap e descartando o intermediário do `vfio.conf` no rollback; ambas as correções foram confirmadas por mutação injetada | logs da sessão | fechar a janela do intermediário e reexecutar |
| I5 | 2026-08-17 | `8b34a4c` + working tree | `libexec/passthrough_core/cpu.py`, `libexec/passthrough_core/cli.py`, `lib/shell/boot.sh` (novo, com o bloco de boot movido de `lib/common.sh`), `lib/common.sh`, `etapas/{02,30,52,53}`, `tests/python/test_cpu.py`, `tests/test-i5-cpu-boot.sh`, `tests/{test-i0-mutators,test-cpu-hugepages,test-bios-output,test-runtime-lifecycles,test-snapshot-safety,test-ubuntu-audit-regressions}.sh`, `tests/lib/{mutator-harness.sh,mutator-dispatch.py}`, `tests/manifests/i5-files.txt`, `tests/run-gate-i1.sh`, este plano | `python3 -I -S -B tests/python/run_tests.py` = 503 casos; `bash tests/test-i5-cpu-boot.sh` (12 grupos); suíte shell 16/16; campanha I0 `full` sem skips com o oráculo da etapa 11 reescrito sobre a transação real de boot (42 grupos de cenários, eram 40); gate canônico completo aprovado (rc=0): manifesto I5 com 86 arquivos nominais, 16 testes da suíte, `bash -n` em 53 arquivos, `compileall` em 2 árvores mais `py_compile` em 26 arquivos sem bytecode residual, whitespace de 86 arquivos untracked; duas mutações injetadas em `lib/shell/boot.sh` reprovadas | APROVADO; revisão semântica APPROVE, bloqueadores 0 | dois reboots reais seguem `[H]` em I13; validadores de lista de CPU continuam em Bash por serem de runtime; parsing de cmdline/GRUB permanece em Bash com justificativa registrada (seção 2.3); `FSTAB` não foi roteado por `caminho_sistema` nesta fase; a etapa 11 `--verificar` passou a devolver `2` quando a persistência não é legível sem privilégio | seção 5 (fase I5, resultado do gate), `scratchpad/gate-i5-final.log` | executar I6 |
| I6 | | | | | não iniciado | | | próxima fase |
| I7 | | | | | não iniciado | | | aguarda I6 (harness I0 pronto) |
| I8 | | | | | não iniciado | | | aguarda I7 |
| I9 | | | | | não iniciado | | | aguarda I8 |
| I10 | | | | | não iniciado | | | aguarda I9 |
| I11 | | | | | não iniciado | | | aguarda I10 |
| I12 | | | | | não iniciado | | | aguarda I11 |
| I13 Ubuntu | | | | | `[H]` | autorização/ambiente real | | aguarda I12 |
| I13 Pop!_OS | | | | | `[H]` | autorização/ambiente real | | aguarda I12 |
| BASE_QUALIFICADA | | | | | pendente | exige I0-I13 | | autorizar ordem de I14 |
| I14.1 Debian | | | | | PLANEJADO | ordem a registrar | | aguarda target anterior |
| I14.2 Fedora Workstation | | | | | PLANEJADO | ordem a registrar | | aguarda target anterior |
| I14.3 Arch Linux | | | | | PLANEJADO | ordem a registrar | | aguarda target anterior |
| I14.4 CachyOS | | | | | PLANEJADO | ordem a registrar | | aguarda target anterior |
| I14.5 openSUSE Tumbleweed | | | | | PLANEJADO | ordem a registrar | | aguarda target anterior |
| I14.6 Silverblue | | | | | diagnóstico pendente | sem mutação | | aguarda base/guarda |
| EXPANSAO_TOTAL_QUALIFICADA | | | | | pendente | exige todos os targets I14 | | encerramento integral |

---

## 13. Limitações que sempre exigem validação manual

Mesmo com toda a suíte aprovada, permanecem manuais até I13/I14:

- GPU/display manager e reset real;
- IOMMU/VFIO, bootloader e initramfs após reboot;
- HugePages e isolamento após reboot;
- rede física, Netplan/NetworkManager/networkd/Wicked e recuperação de conectividade;
- NAT/bridge/libvirt reais;
- firewall, SSH, bindfs e Airlock real;
- USB real com duplicidade VID:PID, serial/porta e reconexão;
- discos, NVRAM, TPM, storage/TRIM e restauração de backup;
- instalação/agent do Windows;
- diferenças reais de cada distro e combinação de versões.

Nenhuma delas pode ser marcada por inferência ou mock.

---

## 14. Checklist de segurança antes de qualquer mutação real

- [ ] autorização explícita do usuário para o cenário específico;
- [ ] ambiente descartável ou plano de recuperação testado;
- [ ] backup íntegro e restauração já ensaiada quando aplicável;
- [ ] console fora de banda para boot/rede/SSH;
- [ ] snapshots/fingerprints capturados;
- [ ] candidato validado antes do primeiro efeito;
- [ ] traps armados antes da janela mutante;
- [ ] cenário de falha controlada e rollback ensaiado, quando possível, somente após criar estado `PREPARED`, snapshots e fingerprints da mesma operação;
- [ ] critérios de commit e pós-condição definidos;
- [ ] logs/artefatos obedecem a seção 3.9: sem `SECRET`, identificadores locais redigidos, stores nominados protegidos e estado bruto somente em bundle local `0600`; diagnóstico usa `recovery_id`, com retenção/limpeza do bundle e mapeamento;
- [ ] versão exata do ambiente registrada.

---

## 15. Critério de encerramento de cada fase

Uma fase só termina quando:

1. todas as tarefas aplicáveis estão `[x]` e as manuais estão `[H]` justificadas; em I14, as cinco distros mutáveis e o gate Silverblue são obrigatórios para o encerramento integral, independentemente da ordem escolhida;
2. teste direcionado e gate global passaram;
3. segunda execução comprovou idempotência quando aplicável;
4. nenhuma mudança do usuário foi perdida;
5. documentação/testes afetados foram atualizados na mesma fase;
6. revisão semântica exigida não possui bloqueador;
7. registro contém comandos, resultados, arquivos e limitações;
8. busca por consumidor legado da fase está vazia ou exceção mínima está documentada;
9. o host de desenvolvimento permaneceu intacto.

---

## 16. Checklist mestre de conclusão

### Código e segurança

- [~] REQ-GUARD aprovado em todo mutador, menu e execução direta (parte I1 feita; falta o resolver Python de I8 e a prova real I13/I14).
- [x] REQ-CONF-ISO aprovado sem abrir/privilegiar caminho legado (I4; prova em host descartável é opcional).
- [~] REQ-TRIM-TX aprovado com sinais e rollback semântico (código e matriz hermética aprovados em I3; blocos/alocação reais são `[H]` de I13).
- [ ] REQ-IOMMU-TX aprovado, separando ativo/persistente.
- [~] REQ-LIBVIRT-BACKEND aprovado em backend monolítico/modular (resolução autoritativa e matriz por fixture aprovadas em I3; libvirt real é `[H]` de I13).
- [~] REQ-HOOKS-TX aprovado incluindo opções XML (opções dentro da transação, rollback comprovado e idempotência exata aprovados em I3; ciclo real de GPU/display é `[H]` de I13).
- [~] REQ-WINDOWS-STATE separa instalação/power/agent (metadata durável vinculada ao QCOW2 pronta e testada em I3; a decisão e os três eixos entram em I4/I9).
- [ ] REQ-AIRLOCK-VERIFY prova política efetiva.
- [~] REQ-VERIFY-FAILCLOSED não possui falso sucesso conhecido (o caso `atualizar-host --validar` foi corrigido em I1; auditoria completa pendente em I9).
- [x] REQ-WAIVERS tem efeito real ou foi removido com migração (I4: duas mantidas com efeito testado, duas removidas por migração segura).
- [ ] REQ-DISK-IDENTITY impede workingDisk igual a HD1 físico.
- [~] REQ-USB-IDENTITY recusa dispositivos ambíguos (a etapa 15 já recusa VID:PID duplicado em vez de escolher por ordem; serial/porta e revalidação antes do attach são de I6).
- [ ] REQ-NET-TX não deixa estado parcial e prova recuperação.

### Arquitetura híbrida

- [~] Core Python 3.10+ stdlib, `-I -S -B`, `sys.dont_write_bytecode`, sem `site`/`.pth`/pacotes globais, bytecode residual ou comandos/privilégio (propriedade estabelecida em I2, mantida em I3 com verificação por AST, e vigiada pelo gate; o core ainda cresce nas fases I4 a I8).
- [~] Ponte única e protocolo JSON v1/NUL seguros (implementados em I2; em I3 ganharam o canal de entrada por pares e os primeiros consumidores de produção; a configuração entra em I4).
- [~] XML/JSON/config/snapshots nunca entram em `argv`; usam stdin/arquivo `0600` e temporários são limpos (provado em I2 e aplicado em I3 a todo XML de domínio/rede/snapshot e ao JSON do `qemu-img`, com canário e shim de `argv`; a configuração entra em I4).
- [x] Zero heredoc Python em produção (11 removidos em I3; asserção versionada em `tests/test-i3-domain-transactions.sh`; o gate estático normativo é de I10.2).
- [x] Zero parsing/mutação XML disperso (todo XML de domínio, de rede e de snapshot passa pelo core desde I3).
- [~] Zero dependência operacional de `xmlstarlet` (nenhum consumidor operacional restou em I3; o pacote e a documentação saem em I10, conforme a decisão registrada na seção 9).
- [x] Config/schema/relações/atomicidade migrados (I4).
- [ ] CPU/RAM, inventário, rede e plataforma migrados conforme fronteira.
- [ ] `common.sh` é agregador, sem algoritmos de domínio.
- [ ] Hooks permanecem Bash puro e autossuficiente.
- [ ] Sem fallback legado ou dois caminhos mutantes.

### Testes, dados e documentação

- [ ] Cobertura transacional completa de 30/50/60/61/70.
- [~] CI executa suíte, Python, ShellCheck, XML e guardas (gate canônico versionado e ativo, com as suítes Python de I2/I3, `compileall` com cache externo, verificação de bytecode residual e as fixtures de XML/JSON de I3; faltam os canários de redação e a validação por `virt-xml-validate` na CI, que dependem das fases futuras).
- [ ] Gate global passou duas vezes.
- [ ] Gates arquiteturais negativos passaram.
- [ ] Desempenho está no orçamento ou exceção foi aceita.
- [x] `passthrough.conf` local não é distribuído nem apagado (verificado em I0 e reverificado em I4.9, inclusive contra todo o histórico).
- [~] Schema inteiro possui classe da seção 3.9 e canários provam canais/stores permitidos, ausência de dados brutos indevidos em stderr/logs/CI e `recovery_id` sem path; bundles/mapeamentos locais `0600` têm retenção/limpeza (schema classificado e canários de configuração aprovados em I4; `recovery_id` e bundles pertencem a I7).
- [~] Histórico foi auditado e eventual exposição tratada (auditoria local de I0 feita; remotos/scanner especializado pendentes, ver I4.9).
- [ ] README, guia, `commands-list.md`, `commands-list/*.md`, exemplo, mensagens e specs estão sincronizados.
- [ ] As seis specs multidistribuição respeitam a tabela de congelamento/retomada e não mantêm trabalho paralelo conflitante.
- [ ] Proveniência nominal R1-01..R1-15, R2-01..R2-08 e R3-01..R3-06 passa em `check-plan-traceability.py`.
- [ ] Nenhuma distro foi promovida por fixture ou migração arquitetural.
- [ ] Revisão semântica final não possui bloqueador.

### Qualificação e release

- [ ] `[H]` Campanha Ubuntu I13 aprovada para combinação registrada.
- [ ] `[H]` Campanha Pop!_OS I13 aprovada para combinação registrada.
- [ ] Cada campanha real comprovou CPU sets/isolamento, HugePages 1 GiB por NUMA, pinning XML/QEMU e alocação/liberação após reboot.
- [ ] Cada campanha real comprovou identidade USB única/serial/porta/reconexão/recusa ambígua; capability ausente permaneceu não qualificada.
- [ ] Marco `BASE_QUALIFICADA` registrado após I0-I13.
- [ ] Todos os cinco providers mutáveis de I14 implementados e qualificados, um por vez, com repetição integral de I13.1-I13.13.
- [ ] Silverblue permanece diagnóstico somente e invariável sob mutadores; I14.6 aprovado.
- [ ] Marco `EXPANSAO_TOTAL_QUALIFICADA` registrado.
- [ ] Limitações de hardware estão explícitas.
- [ ] Não há temporários, dados reais ou segredos na working tree rastreada, no index nem em arquivos untracked; todos os novos pertencem ao manifesto.
- [ ] Usuário revisou o resultado antes de commit/tag/release.

**O plano só está integralmente concluído no marco `EXPANSAO_TOTAL_QUALIFICADA`. O objetivo mínimo do usuário (Ubuntu funcional) é atingido antes disso, em dois degraus verificáveis: (a) "código Ubuntu completo" conforme 11.1 ao final de I12; e (b) "Ubuntu operacionalmente qualificado" conforme 11.2 ao final da campanha Ubuntu de I13. Enquanto qualquer campanha/provider não for executado, mantenha o item `[H]`/`PLANEJADO` aberto; não reduza o critério para encerrar artificialmente.**
