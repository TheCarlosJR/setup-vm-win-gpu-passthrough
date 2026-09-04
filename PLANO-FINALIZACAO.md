# Plano de Finalização: Windows 11 VM com GPU Passthrough (prioridade Ubuntu)

> **Data de consolidação:** 16 de agosto de 2026
> **Executor-alvo:** Claude Code (Opus 5)
> **Status:** I0 e I1 concluídas e reverificadas em 16/08/2026; I2 a I5 em 17/08/2026; I6 em 23/08/2026; I7 e I8 em 28/08/2026 (Gates I7 e I8 aprovados). **I9 está REABERTA:** as tarefas I9.1 a I9.11 e I9.13 estão feitas e provadas, e o Gate I9 chegou a rodar em 02/09/2026 sem que o veredito final fosse observado; a fase foi reaberta por **I9.12 (REQ-VM-RESOURCE-LIFECYCLE)**, cuja migração deste host foi concluída em 03/09/2026 e cuja metade executora está implementada e coberta por bateria com sysfs simulado. Restam de I9.12 a etapa 18 e a qualificação em hardware (I13). Fases I9B a I14 pendentes
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

Este arquivo é a fonte de verdade para a implementação.

### 0.0 Comece por aqui

Se você é o executor e acabou de abrir este documento, faça exatamente isto, nesta ordem:

1. Rode `git status --short` e preserve qualquer alteração do usuário.
2. Leia a seção **1.5** (auditoria de 23/08/2026). Ela diz o que foi verificado **no código**, não nos checkboxes.
3. Execute a tarefa **I6.0** da seção 1.5.4. Ela é um bloqueador: o Gate I5 não vale mais como baseline porque 27 commits alteraram a árvore depois dele.
4. Só então abra a fase ativa no **mapa de execução** abaixo e trabalhe **uma fase por vez**.

Nunca presuma que um item está ausente só porque aparece como tarefa. Primeiro detecte e caracterize o estado atual, classifique-o como `AUSENTE`, `PARCIAL` ou `CONFORME`, preserve o que já estiver correto e aplique somente o delta necessário. A seção 1.5 é o exemplo normativo de como fazer essa caracterização.

### 0.0.1 Mapa de execução

A ordem de execução **não é a ordem numérica**. Siga a coluna "ordem".

**Trilha base** (termina no marco `BASE_QUALIFICADA`):

| Ordem | Fase | Título | Estado | Entrega principal |
|---|---|---|---|---|
| 1 | I0 | Baseline, oráculo e caracterização | `CONCLUÍDA` 2026-08-14 | `tests/i0/*` |
| 2 | I1 | Envelope de segurança imediato | `CONCLUÍDA` 2026-08-16 | guarda + CI |
| 3 | I2 | Fundação do core Python | `CONCLUÍDA` 2026-08-17 | `libexec/passthrough_core/{__init__,errors,protocol,cli}.py`, `lib/python-core.sh` |
| 4 | I3 | XML/JSON, libvirt e transações de domínio | `CONCLUÍDA` 2026-08-17 | `domain_xml.py`, `network_xml.py`, `qemu_image.py`, `xmlutil.py` |
| 5 | I4 | Configuração, ISO legada, dispensas e dados locais | `CONCLUÍDA` 2026-08-17 | `config.py` |
| 6 | I5 | CPU, RAM, HugePages, isolamento e IOMMU/VFIO | `CONCLUÍDA` 2026-08-17 | `cpu.py`, `lib/shell/boot.sh` |
| 7 | **I6.0** | **Revalidação do baseline pós-commits** | **CONCLUÍDA** 2026-08-23 | gate atual + campanha I0 `full` registrados na seção 12 |
| 8 | I6 | Inventário e identidades físicas | `CONCLUÍDA` 2026-08-23 | `inventory.py`, REQ-DISK-IDENTITY, REQ-USB-IDENTITY |
| 9 | I7 | Rede transacional e planner backend-neutral | `CONCLUÍDA` 2026-08-28 (`I7.1` a `I7.8`) | `network.py`, REQ-NET-TX |
| 10 | I8 | Plataforma, capabilities e **eixos de hardware** | `CONCLUÍDA` 2026-08-28 | `platform.py`, eixos distro/CPU/GPU |
| 11 | I9 | Modularização Bash e requisitos P1 restantes | `REABERTA` por I9.12 | `lib/shell/*`, REQ-WINDOWS-STATE, REQ-AIRLOCK-VERIFY, REQ-VM-RESOURCE-LIFECYCLE |
| 12 | **I9B** | **Internacionalização (en, pt-BR, es)** | **ABERTA (nova)** | `lang/*.msg`, `lib/shell/i18n.sh`, `messages.py` |
| — | nota | A infraestrutura de I9B chegou a ser construída e provada em 02/09/2026 e foi **perdida** com o diretório temporário da sessão, sem nunca ter sido commitada. O que sobreviveu são as decisões e as medições, registradas na própria fase I9B. Lição aplicada desde então: trabalho de valor nasce na árvore do repositório, não em diretório temporário. | | |
| 13 | I10 | Convergência, remoção de legado e CI completa | `ABERTA` | gates estáticos, `check-python-boundary.py` |
| 14 | I11 | Documentação, specs e recuperação | `ABERTA` | docs + `check-plan-traceability.py` |
| 15 | I12 | Validação hermética final | `ABERTA` | release candidate de código |
| 16 | I13 | Qualificação operacional Ubuntu e Pop!_OS | `[H]` | campanha em hardware real |
| 17 | marco | **`BASE_QUALIFICADA`** | pendente | encerra a trilha base |

**Trilha de expansão** (só começa após `BASE_QUALIFICADA`; **um alvo por vez**; o usuário aprova a ordem entre os oito):

| Alvo | Título | Custo relativo | Exige hardware que o usuário não tem |
|---|---|---|---|
| I14B | Eixo CPU Intel | **baixo** | sim, host Intel |
| I14C | Eixo GPU AMD | alto | sim, GPU Radeon |
| I14.1 | Provider Debian | médio | sim, instalação Debian |
| I14.2 | Provider Fedora Workstation | **alto** (SELinux + BLS) | sim |
| I14.3 | Provider Arch Linux | médio | sim |
| I14.4 | Provider CachyOS | médio (herda Arch) | sim |
| I14.5 | Provider openSUSE Tumbleweed | alto | sim |
| I14.6 | Fedora Silverblue (diagnóstico) | **baixo** | não, é só recusa |
| marco | **`EXPANSAO_TOTAL_QUALIFICADA`** | pendente | encerra o plano |

**Por que I9B fica entre I9 e I10, e não no fim:** I9 quebra `lib/common.sh` em módulos. Extrair strings antes disso duplicaria o churn no mesmo arquivo; extrair depois de I10/I11 obrigaria a reescrever documentação e gates recém-criados. Entre I9 e I10 os módulos já estão estáveis, o gate de paridade de catálogo nasce junto com os demais gates estáticos de I10, e I11 documenta um sistema que já existe. Além disso, todo provider de I14 nasce traduzível em vez de nascer em português e ser retrofitado.

**Por que os eixos de hardware ficam na trilha de expansão:** o mesmo critério já aplicado às distros. O **modelo** dos eixos entra em I8 (tarefas I8.7 e I8.8), de forma que a camada de plataforma seja vendor-genérica desde o início e nenhum provider precise reabrir essa fronteira. A **implementação e a qualificação** de cada eixo exigem hardware real e ficam em I14B/I14C, capability-gated e recusadas por padrão até prova. Isso não é adiamento: é a mesma regra que impede promover uma distro por fixture.

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
3. Diretório de inventários `${XDG_STATE_HOME:-~/.local/state}/vm-passthrough/inventario` inexistente (etapa 1 pendente). O caminho legado `~/inventario-hardware` foi unificado nessa raiz de estado, com migração conferida e confirmada oferecida pela própria etapa 1.
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

- **Corrigido pela metade em 20/08/2026, ver seção 1.5:** `README.md:1` já **não** diz "Pop!_OS" no título; `Guia-QEMU-Passthrough.md:1` **ainda diz**. Resta somente o guia. Contexto original: enquanto `lib/platform.sh` e o menu suportam Ubuntu e Pop!_OS com perfis distintos (Ubuntu: `grub` + `ubuntu-drivers` + `qemu-system-x86`; Pop: `kernelstub`/`grub` + `system76` + `qemu-kvm`).
- `tests/i0/baseline.md` referencia o nome do plano antigo; é evidência histórica e não deve ser reescrita.

### 1.5 Auditoria de 23 de agosto de 2026 (verificada contra o código, não contra os checkboxes)

Esta auditoria **não releu os checkboxes**: ela testou cada afirmação do plano contra o código realmente presente na working tree. O motivo é concreto: entre 18/08/2026 e 23/08/2026 entraram **27 commits** que tocaram praticamente toda a árvore (as 21 etapas, `lib/common.sh`, `lib/platform.sh`, `lib/shell/boot.sh`, seis módulos do core Python, `menu.sh`, quatro suítes de teste e os quatro documentos) **sem nenhuma linha correspondente no registro da seção 12**. Era necessário decidir, por evidência, se o plano havia se tornado ficção.

**Conclusão: o plano não estava defasado no essencial.** I0 a I5 seguem concluídas, I6 a I14 seguem abertas, e o próprio código carrega marcadores de adiamento escritos pelo executor das fases anteriores. Foram encontrados apenas **dois pontos defasados**, ambos no sentido "já feito, mas ainda marcado como aberto", corrigidos nesta revisão.

**Estado das caixas em 23/08/2026:** 110 em `[ ]`, 14 em `[~]`, 38 em `[x]`, 0 em `[H]`.

#### 1.5.1 Pendências confirmadas no código

Cada linha abaixo foi verificada lendo o arquivo, não o checkbox.

| Item do plano | Evidência no código em 23/08/2026 | Veredito |
|---|---|---|
| I6.6 / REQ-USB-IDENTITY | `etapas/51-usb-passthrough.sh:411` contém o comentário literal "O fluxo completo (serial/porta) é de I6". A busca por `serial`, `busnum`, `devpath` e `ID_SERIAL` no arquivo inteiro devolve **apenas esse comentário**. `libexec/passthrough_core/domain_xml.py:582` repete o marcador. | Pendente de fato, inclusive após os commits de USB de 22/08 |
| I9.8 / REQ-AIRLOCK-VERIFY | `etapas/61-airlock.sh` é o arquivo mais recente do projeto (23/08). Sua função `verificar()` (linhas 230 a 296) testa **presença textual**: `[ -f "$SSHD_DROPIN" ] && v_ok "Drop-in do sshd presente."`. O `sshd -T -C` existe apenas no caminho de aplicação, em `etapas/61-airlock.sh:565`, nunca dentro de `verificar()`. Não há checagem de UID/GID, grupos, lock, shell/chroot, fingerprint, modos nem IPv6. | Pendente de fato, e é exatamente o falso sucesso que o requisito proíbe |
| I9.7 / REQ-WINDOWS-STATE | A metadata `vmpass:windows-install` existe em `libexec/passthrough_core/domain_xml.py`, mas a busca por consumidores em `etapas/`, `lib/` e `util/` devolve **zero**. A etapa 13 continua decidindo só por agente: `etapas/41-instalacao-windows.sh:26` e `:294` usam `guest-ping`. | Core pronto, fluxo não ligado, exatamente como o requisito descreve |
| I6.5 / REQ-DISK-IDENTITY | Existe base real: `etapas/50-hooks-gpu-hd1.sh:422`, `:647` e `:924` resolvem `ID_WWN_WITH_EXTENSION`/`ID_WWN`/`ID_SERIAL`, e `lib/common.sh:2393` exige `/dev/disk/by-id/*`. Falta o cruzamento exigido pelo aceite: `lib/common.sh:2430` compara HD1 apenas com o disco do sistema, não com o workingDisk. | Parcial; o alias físico entre os dois papéis ainda não é recusado |
| I7 / REQ-NET-TX | Existem fingerprints de XML de domínio (`lib/common.sh:2705`), de topologia de CPU (`lib/common.sh:2947`) e de armazenamento (`lib/common.sh:923`). A busca por `recovery_id` em `etapas/`, `lib/` e `libexec/` devolve **zero**. | Pendente de fato |
| I8 | `libexec/passthrough_core/platform.py` **não existe**. O resolver continua sendo `lib/platform.sh`, em Bash. | Pendente de fato |
| I9.4 | `lib/common.sh` tem **3199 linhas** e continua contendo algoritmos de domínio. | Pendente de fato |
| I10.2 | `tests/check-python-boundary.py` **não existe**. | Pendente de fato |
| I11.10 | `tests/check-plan-traceability.py` **não existe**, e o Gate I11 depende dele. | Pendente de fato |
| Manifestos de fase | `tests/manifests/` contém apenas `i0-files.txt` a `i5-files.txt`. | Coerente com I6 não iniciada |

#### 1.5.2 Prova de que o plano foi mantido, não abandonado

A tabela de numeração da seção "Numeração das etapas" mapeia as 21 etapas e **bate 100%** com o array `ETAPAS` de `menu.sh`, incluindo a etapa 16 (`55-driver-nvidia-vm.sh`), criada em 22/08. Um documento abandonado não teria acompanhado essa renumeração. As afirmações do plano são confiáveis; o que faltou foi o registro da seção 12.

#### 1.5.3 Correções aplicadas nesta revisão

1. **REQ-IOMMU-TX:** o checklist mestre da seção 16 mantinha `[ ]`, enquanto o catálogo da seção 4 já registrava "Estado: código `CONFORME` ... **Aprovado em I5**". A caixa não foi atualizada no fechamento de I5. Corrigida para `[~]`, com a parte de hardware (dois reboots reais) explicitamente atribuída a I13.
2. **Seção 1.4:** `README.md:1` já não diz "Pop!_OS" no título, corrigido pelos commits de documentação de 20/08. `Guia-QEMU-Passthrough.md:1` ainda diz. A divergência foi reduzida ao guia.

#### 1.5.4 Bloqueador de entrada em I6 (obrigatório, não opcional)

Os 27 commits de 18/08 a 23/08 alteraram etapas cobertas pelos oráculos de I0 e pelas suítes de regressão **sem reexecutar nem registrar o gate canônico**. Portanto o resultado do Gate I5 **não vale mais como baseline**. Antes da primeira linha de I6:

- [x] **I6.0:** reexecutado `bash tests/run-gate-i1.sh` sobre o estado atual e registrada a sequência completa na seção 12. A primeira tentativa parou no manifesto por causa da documentação Kiro recém-tornada rastreável; a segunda revelou a regressão preexistente da etapa 55 ausente no envelope I1; após integrar os documentos ao manifesto e corrigir `tests/i1/mutators.tsv`, o gate foi aprovado. A campanha I0 `full` também foi repetida explicitamente e aprovou 42 grupos de cenários.

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
    ├── base.sh                  # primitivas e predicados puros; sem pré-requisito
    ├── ui.sh
    ├── privilege.sh
    ├── status.sh
    ├── probes.sh
    ├── storage.sh
    ├── libvirt.sh
    ├── boot.sh
    ├── network-effects.sh
    ├── config.sh                # acrescentado por I9-D1 (schema de passthrough.conf)
    └── waivers.sh               # política de dispensas (REQ-WAIVERS)
    # hooks.sh não existe: ver I9-D8. Hook libvirt é gerado autossuficiente
    # pela etapa 14 e não pode depender do checkout.
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

lang/                            # catálogos de mensagem (I9B), dado inerte, nunca código
├── en.msg                       # fallback obrigatório e completo
├── pt-BR.msg
└── es.msg
lib/shell/i18n.sh                # carregamento e função msg(); sem source/eval de dados
libexec/passthrough_core/messages.py   # validação/comparação de catálogos (cálculo puro)
tests/check-i18n-catalogs.py     # gate de paridade, placeholders e literais remanescentes
tests/i18n-pendentes.txt         # allowlist decrescente da migração; termina vazia
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

### 3.10 Mensagens, idioma e fronteira humano/máquina

Este contrato nasce em I9B e vale para todas as fases seguintes, inclusive I14.

**Separação obrigatória.** Existem dois canais de texto e eles nunca se misturam:

| Canal | Exemplos | Traduzível |
|---|---|---|
| **Humano** | `info`, `ok`, `aviso`, `erro`, `titulo`, `falhar`, `v_ok`, `v_falta`, `v_erro`, prompts `read -r -p`, textos de menu | **sim** |
| **Máquina** | payload JSON do protocolo v1/NUL, códigos de saída 0-3, categorias de `log_acao` (`info`/`ok`/`aviso`/`erro`/`titulo`/`fatal`), chaves de `passthrough.conf`, conteúdo XML/libvirt, nomes de capability, `recovery_id`, marcadores comparados por teste | **não, nunca** |

Traduzir qualquer item do canal de máquina é regressão de contrato e reprova o gate. A tradução muda **apenas** a superfície apresentada ao operador; ela **não pode** alterar código de saída, ordem de operações, decisão de fluxo, nome de arquivo, conteúdo publicado no host nem qualquer byte lido por outro programa.

**Catálogo é dado, nunca código.** É proibido `source`, `eval`, `declare -a` a partir do arquivo, substituição de comando e expansão aritmética sobre qualquer valor do catálogo. O carregamento usa leitura linha a linha com `while IFS= read -r` e separação pelo primeiro `=` por expansão de parâmetro. Um catálogo hostil deve ser **inerte**: `$(...)`, crase, `${...}`, `;`, newline escapado, `%n` e sequência `%` desconhecida não podem executar nada nem quebrar o processo.

**Format string controlada.** O valor do catálogo é usado como formato de `printf`, portanto o conjunto de especificadores é fechado por allowlist validada **no carregamento e no gate**: somente `%%` e `%N$s` (posicional, `N` de 1 a 9). Qualquer outro `%` reprova o catálogo inteiro e força o fallback para `en`. Posicional é obrigatório porque a ordem dos termos muda entre idiomas; `%s` simples não sobrevive a reordenação.

**Precedência de seleção**, determinística e nesta ordem:

1. `PASSTHROUGH_LANG` (variável de ambiente explícita);
2. chave `IDIOMA` de `passthrough.conf`;
3. `LC_ALL`, depois `LC_MESSAGES`, depois `LANG` do ambiente, normalizados (`pt_BR.UTF-8` vira `pt-BR`, `es_ES@euro` vira `es`);
4. `en`.

**Fallback por chave, não por catálogo.** Chave ausente no idioma ativo cai para `en`. Ausente também em `en`, a saída é o próprio nome da chave entre marcadores (`!!CHAVE!!`), o evento é registrado como aviso e, sob `PASSTHROUGH_I18N_STRICT=1` (usado pela CI), vira erro. Nunca abortar a execução por mensagem faltando: um problema de tradução não pode derrubar um mutador no meio de uma transação.

**Idiomas normativos:** `en` (fallback obrigatório, catálogo completo por definição), `pt-BR` (idioma atual do projeto) e `es`. Acrescentar idioma é acrescentar um arquivo e passar o gate; nenhum código muda.

### 3.11 Eixos de suporte independentes

Suporte **não** é um booleano por distribuição. São três eixos ortogonais, cada um com seu próprio estado, e a combinação só é utilizável quando os três permitem:

| Eixo | Valores | Resolvido por | Estado em 23/08/2026 |
|---|---|---|---|
| **Distribuição** | `supported`, `diagnostic-only`, `family-unverified`, `blocked` | `lib/platform.sh`, depois `platform.py` (I8) | `ubuntu` e `pop` suportados; `debian`, `arch`, `cachyos`, `fedora`, `opensuse-tumbleweed` em diagnóstico; Silverblue imutável |
| **Fabricante de CPU** | `supported`, `blocked` | `plataforma_validar_cpu_amd` em `lib/platform.sh` | somente `AuthenticAMD`; `GenuineIntel` explicitamente bloqueado |
| **Fabricante de GPU** | `supported`, `blocked` | hoje **implícito**, espalhado por 12 arquivos | somente NVIDIA, sem eixo formal |

**Regras invariantes:**

1. A combinação efetiva é a **interseção** dos três eixos. Um eixo em `blocked` recusa a operação inteira, com diagnóstico nomeando **qual** eixo recusou e por quê. Nunca uma recusa genérica.
2. Nenhum eixo é promovido por inferência. Presença de comando, fixture aprovada, parser que reconhece o valor ou migração arquitetural **não** promovem nada. Só campanha real na combinação exata promove, conforme a seção 11.
3. Toda capability é resolvida **depois** dos três eixos. Capability habilitada por perfil de distro mas incompatível com o fabricante de CPU ou de GPU presente deve ser rebaixada, com motivo próprio.
4. O eixo de GPU precisa ser **formalizado** em I8 (tarefa I8.8), porque hoje ele existe apenas como suposição espalhada. Enquanto não existir, `gpu.driver` e `guest.driver` são NVIDIA-only por acidente, não por decisão auditável.
5. Um eixo novo (Intel, Radeon) entra no código **recusado por padrão** e permanece recusado até a campanha de I14B/I14C. Código presente e não qualificado é o estado correto e esperado; não é dívida escondida, é a mesma regra já aplicada a `debian` e `arch`.

---

## 4. Catálogo completo de requisitos funcionais e de segurança

Cada requisito abaixo é bloqueante. A fase indicada organiza a implementação, mas o aceite só ocorre quando todos os testes e gates associados passarem. O estado caracterizado em I0 consta de `tests/i0/deltas.tsv` e `tests/i0/oracle.tsv` e é evidência histórica: naquele momento REQ-CONF-ISO, REQ-WINDOWS-STATE e REQ-USB-IDENTITY estavam `AUSENTE` e os demais `PARCIAL`.

Estado depois de I3: REQ-TRIM-TX, REQ-LIBVIRT-BACKEND e REQ-HOOKS-TX estão `CONFORME` no código e nos testes herméticos, com a prova em hardware real ainda pendente em I13 (blocos/alocação de TRIM, ciclo real de GPU/display e libvirt real). A parte de REQ-GUARD e de REQ-VERIFY-FAILCLOSED fechada em I1 permanece. Os demais seguem `PARCIAL` ou `AUSENTE` nas fases indicadas.

Estado depois de I5: REQ-IOMMU-TX passou a `CONFORME` no código e nos testes herméticos; a campanha de dois reboots reais continua em I13. Os demais requisitos não mudaram de estado nesta fase.

### 4.0 Travas estruturais que todo alvo novo esbarra (leia antes de I14, I14B ou I14C)

Sete revisões adversariais independentes, feitas em 23/08/2026 sobre propostas para Debian, Fedora, Arch, CachyOS, openSUSE, CPU Intel e GPU AMD, convergiram nos **mesmos** pontos de falha. Não são detalhes de distribuição: são invariantes do código atual que qualquer alvo novo encontra no primeiro dia. Toda tarefa de I14, I14B e I14C que ignorar esta seção será reprovada no gate.

**T1. Existem dois portões antes das capabilities, e eles recusam primeiro.**
`plataforma_carregar` (`lib/platform.sh`, bloco final) faz `return 1` quando `PLATAFORMA_SUPPORT_LEVEL != supported`, e `guard_mutation` (`lib/common.sh:196`) recusa pelo mesmo critério **antes** de consultar `platform_require_capability` (`lib/common.sh:203`). Portanto **habilitar capabilities não habilita nada** enquanto o nível de suporte não for `supported`. Qualquer desenho de "suporte parcial", "provider não qualificado com três capabilities ligadas" ou "diagnóstico mutável" precisa alterar esses dois portões explicitamente, com teste próprio, ou é ficção.

**T2. `guard_mutation` é o ponto único de autorização, e a ordem dele é contrato.**
A ordem atual é: plataforma mutável, depois `platform_require_capability`, depois `plataforma_validar_cpu_amd` (`lib/common.sh:208`). O eixo de GPU **não existe** nessa cadeia. Acrescentar eixo é acrescentar guarda nesse ponto, nunca espalhar validação pelas etapas.

**T3. A GPU não é presa ao `vfio-pci` no boot, e isso é deliberado.**
`etapas/30-iommu-vfio.sh:19` registra: "Fiel ao manual: a GPU NÃO é presa ao vfio-pci no boot (GPU única!); a vinculação é dinâmica, feita pelos hooks da etapa 14". Propostas de `force_drivers+=" vfio_pci "`, `rd.driver.pre=vfio-pci`, `MODULES=(vfio_pci)` no mkinitcpio ou blacklist do driver de vídeo **violam o desenho** e deixariam um host de GPU única sem console. `add_drivers` para disponibilizar o módulo é aceitável; `force_drivers` e binding precoce não são. Esta trava vale igualmente para Debian, Fedora, Arch, CachyOS e openSUSE.

**T4. `BOOTLOADER` é enum público fechado, no Bash e no core Python.**
`etapas/02-detectar-config.sh` reconcilia, escolhe, salva e revalida o valor com `case` fechado em `grub` e `kernelstub` (blocos em torno das linhas 207 a 300), e o schema do core valida o mesmo conjunto. Acrescentar `systemd-boot`, `limine` ou `grub2-suse` **muda contrato público de configuração** e exige migração conforme a seção 3.3, não uma linha nova no `case`.

**T5. `etapas/02-detectar-config.sh` é onde a configuração nasce.**
Toda proposta que descreve apenas o momento de aplicar, sem tocar a detecção, a pergunta ao operador, a reconciliação e a persistência, está incompleta. Vale para bootloader, backend de rede, identidade QEMU, eixo de CPU e eixo de GPU.

**T6. Caminho e nomes do OVMF variam por distribuição e não são atributo de perfil hoje.**
Valores confirmados: Debian `/usr/share/OVMF/OVMF_CODE_4M.fd` (não existe `OVMF_CODE.fd` sem sufixo; par de Secure Boot é `OVMF_CODE_4M.ms.fd` com `OVMF_VARS_4M.ms.fd`); Fedora `/usr/share/edk2/ovmf/`; openSUSE `/usr/share/qemu/ovmf-x86_64-*.bin` (não existe `/usr/share/OVMF`); Arch usa o pacote `edk2-ovmf`, e o pacote `ovmf` **não existe**. Preferir a autosseleção do libvirt pelos descritores JSON em `/usr/share/qemu/firmware` a qualquer caminho fixo, e tornar diretório e padrão de nome atributos de perfil com pós-condição por existência real do arquivo escolhido.

**T7. Nome de unidade systemd não é universal.**
`etapas/61-airlock.sh` usa `ssh` em `systemctl reload ssh` e `systemctl enable --now ssh` (linhas 115, 567 e 568). No openSUSE a unidade é `sshd.service` e **não existe** alias `ssh.service`, então a etapa 20 falharia logo depois de publicar o endurecimento global do sshd, e o próprio rollback falharia pelo mesmo motivo, no pior instante possível. Nome de unidade vira atributo de perfil, usado no apply **e** no rollback.

**T8. Códigos de saída informativos abortam sob `set -euo pipefail`.**
O `zypper` devolve 100 (update disponível), 101 (segurança), 102 (reboot necessário), 103 (restart do gerenciador), 104 (capability não encontrada), 105 (sinal), 106 (repos pulados) e 107 (script `%post` falhou). Sob `set -euo pipefail` esses valores derrubam o script sem tratamento. Todo provider precisa declarar quais códigos do seu gerenciador são informativos e tratá-los explicitamente.

**T9. `/usr/etc` existe no openSUSE.**
O Tumbleweed entrega defaults de pacote em `/usr/etc` e reserva `/etc` para override. Verificador que conclui "arquivo ausente" olhando só `/etc` produz falso negativo. Regra para o perfil openSUSE: ler override em `/etc`, cair para `/usr/etc` **apenas como leitura**, escrever **sempre** em `/etc`.

**T10. `apt` está espalhado por sete arquivos.**
Ocorrências medidas: `etapas/10-atualizar-sistema.sh` (7), `etapas/11-driver-nvidia.sh` (6), `lib/common.sh` (5), `etapas/20-virtualizacao.sh` (5), `etapas/61-airlock.sh` (3), `etapas/12-pacotes-base.sh` (3), `etapas/00-inventario.sh` (2). Qualquer asserção do tipo "nenhuma etapa cita apt" só pode ser ligada depois do cutover completo dessa superfície, incluindo `lib/common.sh` e os ramos `ubuntu-drivers`/`system76` da etapa 5.

**T11. A lista de pacotes da etapa 6 é literal.**
`etapas/12-pacotes-base.sh` mantém `PACOTES` como literal no topo do arquivo. Tornar `PLATAFORMA_PACOTES_VIRTUALIZACAO` atributo de perfil não resolve a etapa 6; ela precisa de tarefa própria.

**T12. Todo arquivo novo precisa entrar em manifesto de fase.**
`tests/check-phase-manifest.sh` reprova arquivo untracked fora do manifesto e exige que cada caminho nominal exista. Catálogos de idioma, fixtures de distro, configurações de dracut e módulos novos entram no manifesto da fase que os cria, sem exceção por diretório.

**T13. Rótulo `VERIFICADO` exige fonte nominal e data.**
Em rolling release (Arch, CachyOS, openSUSE Tumbleweed) um índice de repositório consultado hoje pode não valer amanhã. `VERIFICADO` só se aplica ao que foi lido em artefato oficial citado nominalmente (filelist de pacote, página de manual, arquivo do repositório, fonte do kernel) com a data do acesso. Todo o resto é `ESTIMADO`, e o plano prefere `ESTIMADO` honesto a `VERIFICADO` otimista.

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

**Fases:** I3 (feita) e I9; ciclo real I13. Estado: código `CONFORME`; D-HOOKS-POSTCOMMIT, D-HOOKS-ROLLBACK-DIVERGE e D-HOOKS-IDEMPOTENCE fechados em I3; D-GPU-UDEV-LOOP fechado em 2026-08-25 sobre hardware real. O ciclo `prepare > start > release` em GPU real continua em I13.

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

### REQ-I18N: idioma por catálogo de texto sem alterar comportamento (P1)

**Fases:** contrato na seção 3.10; implementação I9B; gate estático em I10; documentação em I11. Estado: `AUSENTE`.

Toda superfície humana passa por um catálogo de texto (`lang/en.msg`, `lang/pt-BR.msg`, `lang/es.msg`) carregado como **dado inerte**, jamais como código. `en` é o fallback obrigatório e completo. A seleção segue a precedência `PASSTHROUGH_LANG`, chave `IDIOMA` de `passthrough.conf`, `LC_ALL`/`LC_MESSAGES`/`LANG` normalizados, `en`. O fallback é por chave, não por catálogo, e mensagem ausente nunca aborta execução nem altera código de saída.

O canal de máquina definido na seção 3.10 permanece **intraduzível**: payload JSON do protocolo, códigos de saída, categorias de `log_acao`, chaves de configuração, XML/libvirt, nomes de capability, `recovery_id` e marcadores comparados por teste. Format string é fechada por allowlist (`%%` e `%N$s`, posicional obrigatório). Hooks libvirt permanecem Bash puro sem catálogo, fixos em `en`.

**Testes:** paridade de chaves e de placeholders entre os três catálogos; chave órfã; literal humano remanescente fora de `msg`; catálogo hostil com `$(...)`, crase, `${...}`, `%n`, `%` inválido, BOM, CRLF, chave duplicada, linha truncada e encoding inválido, todos inertes; chave ausente no idioma ativo e nos dois; `PASSTHROUGH_I18N_STRICT=1`; suíte completa reexecutada em `pt-BR`, `en` e `es` comparando código de saída, canal de máquina e efeitos; prompts respondidos em cada idioma produzindo a mesma decisão; hook executado sem o repositório presente.

**Aceite:** trocar o idioma não muda nenhum código de saída, nenhuma decisão de fluxo, nenhum byte publicado no host e nenhum byte do canal de máquina; e nenhum catálogo, por mais hostil que seja, executa código.

### REQ-CPU-VENDOR: eixo de fabricante de CPU e topologia híbrida (P1)

**Fases:** modelo em I8 (tarefas I8.7 e I8.9); implementação e qualificação em I14B. Estado: `AUSENTE`.

O bloqueio de Intel vive hoje em **um único ponto**, `lib/platform.sh:723`, chamado por `guard_mutation` em `lib/common.sh:208`. A troca de fabricante em si é pequena e mecânica, porque `boot_params_chaves` (`lib/shell/boot.sh:700`) deriva as chaves de kernel do próprio texto de parâmetros: trocar `amd_iommu=on iommu=pt` por `intel_iommu=on iommu=pt` faz `kernel_param_del`, o rollback e a prova de ausência acompanharem o fabricante **sem nenhuma edição adicional**. Toda a maquinaria transacional de IOMMU/VFIO é neutra quanto ao fabricante.

O custo real é **topologia híbrida**, e ali existe um **defeito latente comprovado**, não uma preocupação teórica:

- `_threads_per_core` (`libexec/passthrough_core/cpu.py:251`) devolve 0 quando os cores têm contagens de siblings diferentes, e `_plan_pinning` recusa em `cpu.py:467`. Em Alder Lake **com SMT ligado** (P-core com 2 siblings, E-core com 1) essa recusa acontece, e é **proteção acidental**.
- **Com SMT desligado na BIOS**, ajuste comum em passthrough, todos os cores passam a ter 1 sibling, `_threads_per_core` devolve 1, a topologia parece homogênea e o laço puramente ordinal de `cpu.py:519` entrega ao host os primeiros `socket:core` e à VM os últimos, que na enumeração usual do Linux em híbrida são exatamente os **E-cores**.
- O plano resultante passa em `validate_layout`, passa na prova de siblings inteiros e passa na validação do XML, produzindo uma VM Windows 11 inteiramente pinada em E-cores, em silêncio.
- Com `host-passthrough` o CPUID exposto ao convidado é o do core onde a vCPU iniciou, então misturar tipos é problema de **correção**, não só de desempenho.

Exigências: modelar o fabricante como fato tipado, com evidência capturada pelo Bash (nunca lida pelo Python); publicar os parâmetros de IOMMU **pelo perfil**, deixando `IOMMU_PARAMS_PADRAO` vazio no `source` e recusando todo consumidor quando vazio, de forma que seja estruturalmente impossível aplicar parâmetro AMD em host Intel por omissão; detectar tipo de core pela fonte autoritativa `/sys/devices/cpu_core/cpus` e `/sys/devices/cpu_atom/cpus` (`/sys/devices/system/cpu/types` **não existe** e `X86_FEATURE_HYBRID_CPU` **não tem string** em `/proc/cpuinfo`, portanto não é detectável por `grep` em flags); acrescentar um `types_fingerprint` separado, **vazio em host uniforme** para não mover o valor já validado em AMD, porque `canonical_text` (`cpu.py:174`) resume apenas `socket:core` e duas topologias híbridas com tipos trocados produziriam o mesmo hash; recusar plano que misture tipos e recusar host híbrido cuja evidência de tipo seja indeterminada.

Nunca introduzir `intel_iommu=igfx_off` por padrão: ele contorna o DMAR e **reduz isolamento**. Só entra com decisão explícita, registrada e justificada.

**Testes:** AMD uniforme continua idêntico, provado por reexecução integral da suíte e da campanha I0 `full`; híbrida com SMT ligado; **híbrida com SMT desligado**, que é a janela silenciosa e o teste mais importante; evidência de tipo ausente, parcial e conflitante; `IOMMU_PARAMS_PADRAO` vazio recusado em todo consumidor; chave `intel_iommu` derivada, removida e restaurada pelo rollback; RMRR presente produzindo diagnóstico próprio e não erro genérico; `igfx_off` recusado por padrão.

**Aceite:** nenhum plano de pinning mistura tipos de core; host híbrido sem evidência de tipo é recusado, nunca planejado; o host AMD já qualificado não muda de comportamento em nenhum byte; e é estruturalmente impossível aplicar o conjunto de parâmetros de um fabricante em host do outro.

### REQ-GPU-VENDOR: eixo de fabricante de GPU e prova de retorno (P1)

**Fases:** modelo em I8 (tarefa I8.8); implementação e qualificação em I14C. Estado: `AUSENTE`.

Hoje NVIDIA é propriedade **implícita**, espalhada por 12 arquivos (`etapas/55-driver-nvidia-vm.sh` 60 ocorrências, `etapas/11-driver-nvidia.sh` 28, `util/atualizar-host.sh` 23, `etapas/50-hooks-gpu-hd1.sh` 21), sem eixo formal. `PLATAFORMA_CAPABILITIES_CONHECIDAS` tem **21** capabilities, três delas ligadas a GPU (`nvidia.driver`, `guest.driver`, `gpu.recover`).

Diferenças estruturais que o eixo precisa absorver:

- **Driver de host:** NVIDIA é proprietário fora da árvore, com quatro módulos (`nvidia`, `nvidia_modeset`, `nvidia_drm`, `nvidia_uvm`) que precisam sair na ordem inversa da dependência, razão de existir do laço de `etapas/50-hooks-gpu-hd1.sh:511`. `amdgpu` é **in-tree e módulo único**, e **não deve** ser descarregado: em APU o mesmo `amdgpu` dirige iGPU e dGPU, e o `modprobe -r` derrubaria a saída de vídeo do host. O caminho AMD é parar o display manager, esperar os nós DRM e deixar o unbind por dispositivo com `managed='yes'`.
- **Instalação no host:** NVIDIA usa `ubuntu-drivers` ou `system76-driver-nvidia` (`etapas/11-driver-nvidia.sh:62-90`); AMD **não tem nada a instalar**. `amdgpu-pro` fica fora de escopo por não ser qualificável.
- **Prova de saúde após retomada:** NVIDIA usa `nvidia-smi` (`etapas/50-hooks-gpu-hd1.sh:813`, `util/recuperar-gpu.sh:196`). AMD **não tem equivalente instalado por padrão** (`rocm-smi` e `amdgpu_top` reintroduziriam dependência), então a prova passa a ser por sysfs: driver `amdgpu` ligado ao BDF, nó DRM em `/sys/bus/pci/devices/BDF/drm/card*` e `power_state` igual a `D0`.
- **O reset bug é bloqueio real, não ressalva.** Reset falho deixa o dispositivo preso em D3hot (`Unable to change power state from D3hot to D0, device inaccessible`), o rebind de `amdgpu` falha, o host pode perder a saída de vídeo e reiniciar sozinho, e em alguns casos só o power cycle físico recupera. Como este projeto tem requisito explícito de **retorno da GPU ao host**, a classificação de reset precisa vir **antes** da promessa, e é obtida por leitura de `/sys/bus/pci/devices/BDF/reset_method` (kernel 5.15 ou superior), que lista em ordem os métodos suportados entre `flr`, `pm`, `bus` e `device_specific`. O projeto apenas **lê** esse arquivo; escrever nele é mutação de host e exigiria regra udev persistente, fora desta frente.

| Família AMD | Estado do reset | Confiança |
|---|---|---|
| Polaris 10/11/12 (RX 460 a RX 590) | quebrado; `vendor-reset` cobre via `device_specific`, com relatos de RX 580 falhando mesmo assim | VERIFICADO |
| Vega 10 (Vega 56/64, Frontier) | quebrado; coberto por `vendor-reset` | VERIFICADO |
| Vega 20 (Radeon VII, MI100) | quebrado; coberto por `vendor-reset` | VERIFICADO |
| Navi 10/12/14 (RX 5300 a RX 5700 XT) | quebrado; `vendor-reset` sinaliza o SMU para entrar e sair de BACO no lugar do FLR | VERIFICADO |
| Navi 21/22 (RX 6000) | em geral funcional no próprio `amdgpu`; `vendor-reset` não cobre nem é necessário; há relatos isolados de RX 6700 XT que não resetam | VERIFICADO |
| Navi 3x (RX 7000) e RDNA4 (RX 9000) | presumido funcional; classificar como `desconhecido` até a prova de duplo ciclo | ESTIMADO |
| iGPU de APU (Raven, Renoir, Cezanne, Rembrandt) | **bloqueado por este projeto**: compartilha grupo IOMMU com o complexo raiz, não tem ROM própria e o mesmo `amdgpu` dirige o console do host | ESTIMADO |

**Testes:** NVIDIA continua idêntico em todos os caminhos, provado por reexecução integral; vendor AMD detectado; vendor desconhecido; duas GPUs de fabricantes diferentes; função de áudio sem função de vídeo no mesmo grupo; `reset_method` ausente, contendo `device_specific`, contendo apenas `bus` e ilegível; classificação `desconhecido` recusando a promessa de retorno; ciclo duplo de entrega e retomada; APU recusada antes de qualquer efeito.

**Aceite:** o projeto **nunca** promete retorno da GPU ao host sem ter classificado o reset daquele dispositivo, e o fabricante NVIDIA já qualificado não muda de comportamento em nenhum byte.

### REQ-BOOT-POSCONDICAO: aplicador de bootloader precisa provar que regenerou (P1)

**Fases:** correção em **I9.13** (2026-09-03); reforço por perfil em I14. Estado: `CONFORME` para GRUB, e já era para kernelstub, que valida entry por entry. O reforço por perfil de distro continua em I14.

Encontrado na auditoria de 23/08/2026: o rollback do GRUB em `lib/shell/boot.sh:581-585` restaura a fonte, executa `sudo update-grub` e então valida com `sudo cmp -s -- "$backup" "$arq"`, que compara **a fonte com o backup da fonte**. O `grub.cfg` regenerado **nunca é verificado**. Se o aplicador devolver zero sem produzir efeito, a mensagem `"Rollback da fonte GRUB e regeneração do grub.cfg concluídos"` é emitida com o `grub.cfg` ainda contendo os parâmetros novos. Isso é falso sucesso, exatamente o que REQ-VERIFY-FAILCLOSED proíbe.

O risco cresce nos alvos de I14: no openSUSE, `update-bootloader --config` sai com zero sem regenerar nada quando `LOADER_TYPE` está vazio, `none` ou desconhecido, porque `run_script` do `pbl` registra `skipped` e devolve `err=0` sem aviso. Enquanto `update-grub` ausente falha ruidosamente, o `pbl` **silencia**.

Exigência: em **ambos** os caminhos, apply e rollback, capturar a identidade do artefato gerado (conteúdo e mtime) antes e depois; exigir mudança quando a fonte mudou e igualdade semântica quando a fonte foi restaurada; e tratar "aplicador devolveu zero sem efeito" como **erro grave** com instrução de recuperação, nunca como sucesso.

**Testes:** aplicador que devolve zero sem efeito; aplicador ausente; fonte restaurada com artefato divergente; artefato idêntico após restauração; falha antes e depois da regeneração; sinal durante a janela.

**Aceite:** nenhuma mensagem de conclusão de boot é emitida sem prova de que o artefato efetivamente consumido pelo firmware foi regenerado a partir da fonte corrente.

### REQ-VM-RESOURCE-LIFECYCLE: recursos dedicados voltam ao host quando a VM para (P0)

**Fases:** contrato e implementação em **I9.12** (fase I9 reaberta por este requisito em 02/09/2026); baterias simuladas em I10 e I12; aceite operacional em I13. Estado: `PARCIAL` — migração deste host concluída e baseline retornável provado em 03/09/2026; ciclo de aquisição e devolução implementado nos hooks e coberto por bateria com sysfs simulado; **falta** a etapa 18 (isolamento de CPU) e a qualificação em hardware, que é de I13.

O contrato completo, com as nove cláusulas normativas, está na tarefa **I9.12** da fase I9, e é lá que ele é mantido; esta entrada existe para que o requisito apareça no catálogo, na rastreabilidade e nos critérios de conclusão, sem criar uma segunda fonte de verdade.

**Estado medido no host de desenvolvimento em 03/09/2026, que é a razão do requisito:** `/proc/cmdline` traz `default_hugepagesz=1G hugepagesz=1G hugepages=22`, e o resultado com a **VM desligada** é `HugePages_Total=22`, `HugePages_Free=22`, `Hugetlb=23068672 kB`. Ou seja, 22 GiB de 30,3 GiB (`MemTotal=31722704 kB`) estão fora da RAM comum sem nenhuma VM rodando, e o host fica com `MemAvailable=4143904 kB`. As páginas estão livres para o hugetlb e **inacessíveis** para todo o resto. (Correção de fato registrada em 03/09/2026: a PÁGINA reservada no boot é devolvível em runtime neste kernel, `CONFIG_CONTIG_ALLOC=y`; o que a reserva no boot tem de irreversível é a POLÍTICA, que volta a valer no próximo boot enquanto os parâmetros estiverem lá.) THP está em `[madvise]` e nenhum `isolcpus`/`nohz_full`/`rcu_nocbs` foi aplicado ainda, o que reduz o escopo de migração da etapa 18 a "recusar entrar nesse estado" em vez de "sair dele".

**A inversão que o requisito impõe:** hoje a etapa 17 trata reserva estática de 1 GiB como o contrato, e o `--verificar` dela exige `HugePages_Total` exatamente igual a `HUGEPAGES_1G` — ou seja, **o estado que este requisito considera defeito é hoje a pós-condição de sucesso**. A migração, portanto, não é acrescentar um modo: é substituir o contrato da etapa, transacionalmente e sem manter dois caminhos mutantes, preservando os 21 itens do menu, os entrypoints e os status públicos `0/1/2/3`.

**Ordem de preferência dos modos, decidida em I9.12 e não negociável por conveniência:** memória normal com THP oportunístico é o baseline; hugetlb de 2 MiB em runtime é o modo hugetlb preferencial; 1 GiB em runtime é `best-effort` fail-closed, porque cada página exige 1 GiB fisicamente contíguo e 22 delas não podem ser garantidas após uptime, pressão ou fragmentação; 1 GiB no boot sobrevive apenas como perfil legado opt-in, declaradamente **não retornável** e fora da base qualificada. Nenhum fallback silencioso entre modos.

**Testes:** sysfs, cgroup, libvirt e QEMU simulados, sem tocar o host; memória normal/THP; 2 MiB em runtime; 1 GiB em runtime parcial e indisponível; pool preexistente de terceiro; NUMA divergente; falha e sinal em cada janela; start recusado; release com múltiplas falhas; crash do QEMU; daemon indisponível; state órfão; dois ciclos completos; segunda execução no-op.

**Aceite:** com a VM parada, toda a RAM e toda a CPU geridas pelo perfil retornável estão novamente elegíveis ao host, comprovado por `total/free/reserved/surplus` iguais ao baseline legítimo anterior; falha de aquisição **não inicia** a VM; falha de devolução permanece erro recuperável com evidência e não abandona a restauração de GPU, display e CPU; e pool ou isolamento pertencente a terceiro nunca é zerado.

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

- [x] **I6.1:** definir snapshot de CPU, memória, PCI, discos/IDs, interfaces e boot; distinguir ausente, indisponível, erro e vazio; ordenar deterministicamente.
- [x] **I6.2:** implementar parsers de inventário atual/legado; rejeitar truncado, duplicado, inconsistente e texto executável.
- [x] **I6.3:** implementar diff semântico de hardware separado de diferenças de formato e renderização.
- [x] **I6.4:** migrar etapas 1/3: Bash faz probes/publicação; Python normaliza/compara; relatório permanece atômico.
- [x] **I6.5:** implementar integralmente REQ-DISK-IDENTITY.
- [x] **I6.6:** implementar integralmente REQ-USB-IDENTITY.

### Gate I6

Legado continua legível; reordenação não gera falso positivo; mudança real bloqueia/redetecta; probes continuam Bash; alias físico e USB ambíguo são recusados; suíte aprovada.

**Resultado:** `APROVADO` em 2026-08-23. A implementação e a evidência registradas na spec ativa foram reconciliadas com este plano; `tests/test-i6-inventory.sh`, os 546 casos do core Python e o gate cumulativo confirmam os contratos de inventário, legado, diff, discos e USB sem sondar o host pelo Python.

## I7: Rede transacional e planner backend-neutral

**Pré-condição:** harness da etapa 19 de I0 aprovado (já existe: `tests/test-i0-mutators.sh`).

**Objetivo:** convergir a transação existente da etapa 19 sem perder seus snapshots/traps já corretos.

### Tarefas

- [x] **I7.1:** modelar snapshots/intenção de uplink, rotas, links, bridge, XML, ativo/persistente/autostart, VMs e configuração, com fingerprints. **Concluída em 2026-08-24:** `network.py` valida schemas fechados, coerência bidirecional da topologia, identidade/metadados `lstat` dos artefatos de configuração, normaliza relações e coleções e produz fingerprints exato, semântico e por componente; XML de rede/VM usa projeção canônica. Nenhum probe, arquivo, comando, provider, cálculo de CIDR, planner ou efeito foi antecipado.
- [x] **I7.2:** usar `ipaddress` para gateway/DHCP/host/VM/broadcast/sobreposição; tratar exceção `proto kernel` exatamente; recusar IPv6/formato ainda não suportado de forma explícita. **Concluída em 2026-08-26:** `network.py` ganhou `nat_addresses`, `address_check` e `route_audit`, toda a aritmética por `ipaddress` e nenhuma concatenação de texto; os três subcomandos puros `network-nat-addresses`, `network-address-check` e `network-route-audit` foram registrados no CLI. A paridade com o Bash foi provada por oráculo extraído literalmente de `lib/common.sh` e `etapas/60-rede-bridge.sh` (38 linhas idênticas, 8 CIDRs aceitos e 9 recusados dos dois lados, 21 rotas com classe, exceção e sobreposição iguais). Nenhuma etapa foi tocada: a fiação é de I7.5, e a contagem de efeitos do oráculo I0 ficou intacta.
- [x] **I7.3:** gerar planos bridge/NAT determinísticos com precondições, operações abstratas, pós-condições e rollback; nenhum comando/escrita no Python. **Concluída em 2026-08-26:** `build_plan`/`network_plan` produzem plano de schema fechado com `preconditions`, `operations`, `postconditions`, `rollback` e `fingerprints`; cada operação declara se é mutante, se já está convergida, quais componentes de fingerprint revalidar antes de aplicar e qual passo desfaz. Precondição de recusa que falha zera operações e rollback (fail-closed). A prova de não regressão é a projeção provider→efeito no teste: o plano reproduz os 11 efeitos do NAT e os 10 do bridge na ordem exata do oráculo I0, e as duas strings exatas de ordem do rollback.
- [x] **I7.4:** detectar consumidores/NIC de todas as VMs por MAC/cardinalidade/marcador. **Concluída em 2026-08-26:** `consumer_report`/`network_consumers` classificam cada interface em `network`, `marker`, `bridge`, `direct`, `unmanaged-network` ou `unknown-network`, agregam por MAC com cardinalidade (domínios, interfaces, compartilhamento) e tipam as anomalias `mac-shared`, `mac-repeated`, `mac-missing`, `domain-without-interface` e `network-unknown` em vez de aceitar default silencioso. A assimetria congelada pelo oráculo foi preservada: o NAT decide por `active_consumer_names` (restart) e o bridge por `defined_consumer_names` (conversão). A VM alvo é excluída por **nome** e nunca por MAC, porque o harness I0 semeia `other-vm` como cópia de `vm.xml` e os dois compartilham o mesmo MAC. O snapshot ganhou `links[].wireless` e `foreign_networks[]`, fechando as duas precondições que I7.3 deixou abertas: `P-UPLINK-NOT-WIRELESS` e `P-LIBVIRT-BRIDGE-UNIQUE`.
- [x] **I7.5:** Bash captura, confirma, revalida fingerprints, aplica, arma traps, verifica, commita e restaura; Python só verifica snapshots. **Concluída em 2026-08-27.** A etapa 19 passou de 1569 para 2839 linhas e deixou de ser imperativa: captura o estado completo do host (uplink, rotas com tipo, links com `wireless`, bridge, rede libvirt, redes de terceiros, consumidores com interfaces e artefatos de configuração com os oito metadados de `lstat`), fixa a base de fingerprints por `network-snapshot`, monta a intenção, pede o plano ao core, prova precondições, confirma, revalida, aplica **na ordem do plano** com pós-condição por operação, e em falha executa o `rollback[]` do plano, na ordem dele, só para recursos realmente mutados e com prova por passo. O mapa verbo abstrato → comando vive no Bash. O código imperativo substituído foi removido (regra 8): saíram `configurar_bridge`, `configurar_nat`, `preparar_nat_para_bridge`, `validar_bridge_libvirt_disponivel`, `listar_consumidores_rede_gerenciada`, `rede_nat_usada_por_outra_vm_ativa`, `trocar_fonte_nic`, as quatro `restaurar_*` avulsas e as publicações soltas. `D-NET-CONCURRENCY` fechado: mudança concorrente vira recusa fail-closed nomeando os componentes divergentes.

- [x] **I7.6:** implementar integralmente REQ-NET-TX e a matriz bridge/NAT/conversões/consumidores/marcador/rota/uplink/concorrência; cobrir `INT`/`TERM`/`EXIT` sem falso commit e injetar falha antes/depois de cada ação do próprio rollback, comprovando erro grave e recuperação orientada quando a restauração divergir ou falhar. **Concluída em 2026-08-27.** Os três deltas restantes fecharam: `D-NET-UNMANAGED-BRIDGE` recusa nos dois modos, com as duas tolerâncias caindo juntas (a exclusão da captura e o `v_ok` de `verificar()`, que virou `v_falta`), porque separadas deixariam a verificação aprovando o que a aplicação recusa; `D-NET-RECOVERY-EVIDENCE` retém bundle `0700` com arquivos `0600` em `${XDG_STATE_HOME:-$HOME/.local/state}/vm-passthrough/recovery/<recovery_id>/`, derivado da mesma raiz de `LOG_ACOES_DIR`, com metadados de expiração de 7 dias e limpeza idempotente, emitindo apenas o localizador de 128 bits e dois comandos seguros, **só** quando a restauração diverge ou falha; `D-NET-IDEMPOTENCE` foi verificado como já cumprido e passou a ser provado por eixo separado (conteúdo, metadados, mtime e runtime modelado projetados das colunas do manifesto `exact`), com as tentativas convergentes preservadas de propósito, por serem as janelas onde a injeção de falha e de sinal continua valendo. A matriz de rollback tem **40 injeções** em 20 posições de passo, cobrindo os 11 verbos de rollback em 5 formas de transação.

- [x] **I7.7:** manter a intenção independente de Netplan; não criar parser YAML manual. Providers futuros escolhem backend. **Concluída em 2026-08-27:** a intenção modela o artefato como `{scope, identifier, content, mode}` com identificador lógico mais parâmetros declarativos; o core nunca gera nem interpreta o conteúdo e nenhum parser YAML foi criado. Um teste estático reprova qualquer token de ferramenta em qualquer valor do plano, e o mapa verbo abstrato → comando vive só no provider Bash da etapa, fechado em I7.5.

- [x] **I7.8 (revisão semântica de rollback exigida pelo Gate I7):** **Concluída em 2026-08-28.** a revisão de 27/08/2026 encontrou **um bloqueador e três defeitos relevantes** no caminho de rollback, todos com cenário concreto, e nenhum deles era detectável pela suíte anterior. Correções aplicadas:
  1. **BLOQUEADOR — o bundle de recuperação entregava o perfil NOVO com o nome do anterior.** `reter_evidencia_recuperacao` copiava `$TMP_DIR/artefato-<escopo>-<id>`, que `_capturar_artefato` **reescreve em toda recaptura**, e `capturar_estado` roda em cada fronteira de `aplicar_plano` e outra vez antes de restaurar. No modo bridge existe fronteira exatamente depois de o perfil novo ter sido publicado, então o arquivo retido como `netplan-bridge.anterior.yaml` era o perfil que acabara de derrubar o host; sem perfil anterior algum, o bundle inventava um `.anterior.yaml` que nunca existiu. O operador no console local, sem rede, reaplicaria a configuração defeituosa. Agora a captura da transação congela uma cópia legível e imutável (`perfil-host-anterior-legivel.yaml`, `sudo install -m 0644`), o bundle retém **essa**, e quando não havia perfil anterior nada é retido.
  2. **`INT`/`TERM` voltavam à ação padrão dentro da janela de rollback.** `tratar_saida` começava com `trap - EXIT INT TERM`: um segundo Ctrl-C (gesto documentado do próprio `netplan try`, que a etapa usa) matava o processo entre restaurar o arquivo e reativar a rede, sem `ROLLBACK INCOMPLETO`, sem bundle e sem localizador. Agora só o `EXIT` é desarmado; `INT`/`TERM` passam a `_diferir_sinal_saida`, que conta o sinal e deixa a sequência terminar, com aviso explícito de quantas interrupções foram diferidas.
  3. **A prova de restauração da topologia media só o master do uplink, e media com fonte ambígua.** `LINK-TOPOLOGY` comparava `master_da_interface "$INTERFACE_FISICA"` com o capturado, e aquela função devolvia string vazia com rc 0 tanto para "sem master" quanto para "interface inexistente" (o rc era o do `awk` no fim do pipe). Bridge que sobrevivesse ao `netplan apply` da restauração, com o endereço do host preso nela, dava master vazio igual ao capturado e o rollback era anunciado como comprovado com o host sem rede. Agora `master_da_interface` devolve rc 1 quando o link não existe, a transação guarda `TX_BRIDGE_EXISTIA`/`TX_BRIDGE_PORTAS`, e a prova relê a topologia depois dos passos (`observar_topologia_bridge`) exigindo uplink presente, master igual e presença/portas da bridge iguais às do instante em que a transação foi armada.
  4. **Divergência do componente `target` falhava aberta.** Em `revalidar_estado`, `dumpxml` com `2>/dev/null` que não respondesse zerava a observação e **pulava** a comparação, sem divergência: VM removida por terceiro passava sem conflito, o passo de domínio não era bloqueado, `rb_vm_restaurar` a ressuscitava com `virsh define` e `DOMAIN-FINGERPRINT` conferia. Não poder observar não é autorização para sobrescrever: agora vira conflito nomeando `target`, que bloqueia os passos daquele componente.
  Lacunas de teste fechadas junto (a suíte anterior não pegava nenhum dos quatro): asserção positiva nas seis execuções de sinal das janelas novas; divergência silenciosa (`rc=0` sem efeito) estendida das posições de passo restantes; projeção de manifesto deixando de descartar a coluna de modo de todos os arquivos; e conteúdo do bundle asserido de fato (contagem de artefatos e o perfil retido igual ao **original**, não ao publicado).

### Gate I7

Transação fail-closed; snapshot+restore por operação; conflito em mudança concorrente; rollback semanticamente comprovado; testes sem rede real; revisão específica de rollback sem bloqueador.

**Resultado:** `APROVADO` em 2026-08-28, rc 0, **depois** de a revisão específica de rollback ter reprovado o estado anterior. A revisão não foi um carimbo: encontrou um bloqueador (bundle de recuperação com o perfil publicado sob o nome de "anterior") e três defeitos relevantes (`INT`/`TERM` em ação padrão dentro do rollback; `LINK-TOPOLOGY` provando só o master do uplink, com `master_da_interface` ambíguo entre "sem master" e "interface inexistente"; divergência de `target` falhando aberta), todos corrigidos em `I7.8` e todos com teste que os pega. A auditoria paralela dos testes confirmou que as contagens declaradas em `I7.6` eram exatas (40 injeções, 20 posições, 11 verbos, 5 formas) e que **nenhum** dos quatro defeitos era detectável pela suíte anterior, o que é a razão de o Gate exigir revisão humana além da matriz. Números do gate final: campanha I0 `full` com **49 grupos** (eram 46), manifesto I7 com 136 arquivos, envelope I1 com 30 mutadores e 23 seleções em 6 perfis duas vezes, 871 casos no core, `bash -n` em 56 arquivos, `py_compile` em 35, whitespace em 0 untracked. ShellCheck ausente localmente.

## I8: Plataforma e capabilities em Python

**Objetivo:** migrar detecção read-only sem promover suporte e sem alterar a API de guarda criada em I1.

### Tarefas

- [x] **I8.1:** implementar parser `os-release` com allowlist, quoting, malícia inerte e normalização explícita de `ID`, lista `ID_LIKE`, `VERSION_ID`/versão e arquitetura. Campo ausente, duplicado ou conflitante deve produzir estado tipado, nunca default silencioso. A arquitetura vem de snapshot capturado pelo Bash (por exemplo, saída validada de `uname -m`), não do arquivo por suposição.
- [x] **I8.2:** `platform.py` recebe conteúdo de `os-release` e demais evidências já capturados pelo Bash via stdin ou arquivo controlado `0600`; não abre `/etc/os-release`, não consulta o host e não aceita caminho arbitrário vindo do payload. Modelar fatos, origem da evidência e confiança: detectado, inferido, conflitante, ausente e desconhecido; sem `sudo`. Fixtures cobrem ausência de cada campo, duplicata, conflito, arquiteturas, payload com path traversal e prova de que nenhum caminho é aberto.
- [x] **I8.3:** preservar exatamente o comportamento permitido de Ubuntu/Pop e o bloqueio das demais; Silverblue/ostree ganha perfil imutável diagnóstico explícito. **Concluída em 2026-08-28:** host imutável deixou de ter perfil vazio, que era indistinguível de "não classificado", e passou a ter `immutable-diagnostic` (constante `PROFILE_IMMUTABLE`). O nome vive no canal de máquina, junto de `supported`/`diagnostic-only`/`blocked`, e há teste provando que ele **nunca** coincide com um perfil de provider: o `case` de atributos da fachada é indexado pelo nome do perfil, então colisão faria um host imutável herdar pacote, serviço e estratégia de driver de um alvo mutável. `mutable=0`, nenhuma capability habilitada e os dois textos de bloqueio seguem byte a byte.
- [x] **I8.4:** trocar somente o resolver por trás da fachada/guarda; providers mutáveis permanecem Bash. **Concluída em 2026-08-28:** `_plataforma_resolver_estado` captura (arquivo, `uname -m`, evidência ostree), chama `platform-detect` e publica as globais uma a uma. Saíram do Bash, sem sobrar cópia, `_plataforma_ler_os_release`, `_plataforma_decodificar_valor`, `_plataforma_detectar_imutabilidade`, `_plataforma_classificar_suporte` e `_plataforma_id_like_contem`. `guard_mutation` não mudou em nenhum byte, e o `case` de atributos do provider continua no Bash, agora indexado pelo NOME do perfil que o core resolve, para que a classificação não exista em dois lugares. O caminho do `os-release` é `LOCAL_IDENTIFIER` e **não** atravessa a ponte: o core devolve `error_code`/`error_field` e a fachada rerenderiza as oito frases anteriores.
- [x] **I8.5:** executar as 11 fixtures de plataforma com a implementação real, determinismo e invariância; comparação diferencial temporária deve ser removida. **Concluída em 2026-08-28:** `tests/test-i8-platform.sh` roda `plataforma_carregar` sobre as 11 fixtures com tabela-oráculo de 10 campos por caso comparados em string inteira, duas execuções por caso comparadas com `cmp` sobre o dump ordenado de TODAS as `PLATAFORMA_*` (escalares, array e os dois mapas), uma terceira passada em ordem inversa para pegar vazamento de estado entre casos, assinatura `%p|%m|%s|%T@` da árvore de fixtures antes e depois, `HOME`/`XDG_STATE_HOME` temporários provados vazios nos dois momentos, as 21 capabilities com valor e motivo por caso, e os canários da fixture hostil. Nenhuma comparação diferencial ficou em produção: o oráculo diferencial contra o Bash antigo foi usado só no rascunho, fora do checkout, e o Bash antigo não existe mais. **Três medições que corrigiram suposições:** a fixture hostil não publica mapa de capabilities nenhum (o resolver aborta antes de inicializá-lo, então são 0 entradas, não 21 zeros); `platform_has_capability` não pode ser usada nesse caso porque, com `DETECTADA=0`, ela recarrega do `/etc/os-release` do HOST; e a frase de ostree é inalcançável por fixture, porque fonte explícita nunca consulta o marcador. **8 regressões injetadas em cópia, 8 pegas**, entre elas publicar campo antes de conferir `valid`, promover `debian` a `supported`, ligar o perfil imutável como mutável e tirar **um byte** (o ponto final) de `MSG_BLOCKED`. Essa última tem valor próprio: foi medido que o `grep -Eiq` do gate I1 continua casando com o texto mutilado, ou seja, este teste é estritamente mais forte que o oráculo do gate naquele ponto.
- [x] **I8.6:** integrar a resolução autoritativa do backend libvirt ao contrato de I3. **Concluída em 2026-08-28:** a função pura `service_unit_choice` (`platform-service-resolve`) recebeu o parsing de fixture, a classificação por escore (100/50/25, bônus de `.socket`, ação `nenhuma`/`enable-now`/`start`) e o desempate que viviam em `_plataforma_sondar_unidade_fixture`, `_plataforma_classificar_unidade` e no laço de `plataforma_resolver_servico`. A SONDA continua no Bash e **byte a byte igual**: a lista de propriedades de `systemctl show` não mudou, o que era obrigatório, porque o shim do harness I0 recusa qualquer `--property=` fora das quatro modeladas. Também ficaram no Bash a expansão `.socket`/`.service`, a lista de candidatas do perfil e toda a prosa, já que tipo de serviço e caminho de fixture são `LOCAL_IDENTIFIER`. **Prova de não regressão:** harness de 43 cenários comparando rc, as quatro variáveis publicadas, `PLATAFORMA_ERRO` e os cinco `LIBVIRT_BACKEND_*` ANTES e DEPOIS, com diff limpo, incluindo ativa vs habilitada vs só carregada, os quatro casos de empate por `.socket` (e a prova de que o bônus nunca atravessa nível), unidade ausente, `UnitFileState=masked`, fixture malformada, unidade duplicada e as quatro falhas do caminho de sonda. Suíte do core foi de 950 para **992** casos. **Cinco divergências declaradas, todas fail-closed e em entrada degenerada:** caractere de controle ou NUL na fixture, fixture acima de 60 KiB ou 4096 linhas, valor de `systemctl show` com TAB/controle, nome de unidade fora do padrão, e um processo `python3` a mais por chamada (um por chamada, não por unidade). O teto de 60 KiB é deliberado: a linha malformada volta INTEIRA em `error_field` para a frase do Bash continuar idêntica, e um teto maior estouraria o limite de 64 KiB por valor do canal de pares com erro interno em vez de recusa tipada.

- [x] **I8.7:** formalizar o **eixo de fabricante de CPU** conforme a seção 3.11. `platform.py` modela o vendor como fato tipado com origem da evidência (snapshot de `/proc/cpuinfo` e `lscpu` capturado pelo Bash, nunca lido pelo Python), e a fachada expõe `PLATAFORMA_CPU_VENDOR_SUPORTADO` com motivo próprio. Preservar exatamente o bloqueio atual de Intel: esta fase **modela** o eixo, não habilita fabricante nenhum. Fixtures cobrem `AuthenticAMD`, `GenuineIntel`, vendor ausente, vendor desconhecido e evidência conflitante entre `/proc/cpuinfo` e `lscpu`. **Concluída em 2026-08-28, com um limite declarado:** o core aceita e modela as DUAS fontes, e a evidência conflitante tem fixture própria, mas a fachada ainda captura só `lscpu`, que é o que a implementação atual sonda. Capturar `/proc/cpuinfo` aqui mudaria comportamento nesta fase: os harnesses de teste substituem o COMANDO por `PATH` e não têm como redirecionar o ARQUIVO, então host com `lscpu` encenado e `/proc/cpuinfo` real viraria "evidência conflitante" onde hoje há decisão limpa, quebrando o perfil `intel` do envelope I1. Ligar a segunda fonte é I14B, junto com o host Intel real. `PLATAFORMA_CPU_VENDOR_SUPORTADO` e `PLATAFORMA_CPU_VENDOR_MOTIVO` já existem, e a frase `CPU GenuineIntel bloqueada: ...` passou a sair do core byte a byte.
- [x] **I8.8:** formalizar o **eixo de fabricante de GPU**, que hoje não existe como eixo e está espalhado por 12 arquivos. Modelar vendor PCI (`0x10de` NVIDIA, `0x1002` AMD, `0x8086` Intel) como fato tipado a partir de snapshot capturado pelo Bash, expor `PLATAFORMA_GPU_VENDOR_SUPORTADO` com motivo próprio, e renomear a capability `nvidia.driver` para `gpu.driver` mantendo `nvidia.driver` como alias aceito durante o cutover, removido em I10. Preservar exatamente o comportamento NVIDIA atual: esta fase **modela** o eixo, não habilita fabricante nenhum. Fixtures cobrem NVIDIA, AMD, Intel, GPU ausente, duas GPUs de fabricantes diferentes e função de áudio sem função de vídeo no mesmo grupo IOMMU. **Concluída em 2026-08-28:** `plataforma_detectar_gpu_vendor` captura `lspci -Dnn` e os grupos IOMMU no Bash e publica `PLATAFORMA_GPU_VENDOR`, `_FAMILIA`, `_SUPORTADO`, `_MOTIVO` e `_IOMMU_GRUPO`. A capability virou `gpu.driver` com `nvidia.driver` aceito como alias, atualizada na mesma mudança em `lib/platform.sh`, `etapas/11-driver-nvidia.sh`, `menu.sh` e `tests/i1/mutators.tsv`, porque o envelope I1 cruza os três; o array de conhecidas continua com **21** entradas, já que o alias mora em mapa separado. O eixo **não** entra em `guard_mutation`: ele nasce exposto e diagnóstico, e a interseção dos eixos é I14C.

### Gate I8

Mesmas operações para Ubuntu/Pop; fixtures não promovem suporte; malícia inerte; detecção sem mutação; desconhecido/imutável fail-closed.

**Resultado:** `APROVADO` em 2026-08-28, rc 0. `bash tests/run-gate-i1.sh` com `GATE_FASE=I8`: manifesto de **140** arquivos nominais (4 novos, todos listados), campanha I0 `full` com 49 grupos, envelope I1 com 30 mutadores e 23 seleções em 6 perfis duas vezes, **992** casos no core (eram 871 no fecho de I7), `bash -n` em 57 arquivos, `py_compile` em 37 sem bytecode residual, fronteira Python pura agora exigida também para `platform.py`, e whitespace limpo em 4 arquivos untracked. As quatro exigências do gate ficaram provadas por teste dedicado, não por inspeção: Ubuntu/Pop com as mesmas operações e o mesmo dump de variáveis, fixtures que não promovem suporte (`debian` promovido a `supported` é regressão detectada), malícia inerte com canário por caso, ausência de mutação por assinatura `%p|%m|%s|%T@` da árvore e do `HOME` temporário, e imutável/desconhecido fail-closed com `MUTAVEL=0`, `CARREGADA=0` e zero capabilities. ShellCheck ausente localmente.

## I9: Modularização Bash e requisitos P1 restantes

**Objetivo:** reduzir `common.sh` a fachada/agregador e fechar estado Windows, Airlock, verificadores e dispensas.

### Decisões de entrada da fase (registradas em 2026-08-30, antes da primeira linha de código)

Cinco auditorias somente-leitura precederam a implementação e dimensionaram a
fase: mapa de extração de `lib/common.sh` (169 funções, 3677 linhas), estado do
Windows, Airlock, verificadores e dispensas. Elas produziram sete decisões que
não podem ser re-derivadas depois, porque mudam o desenho e não só o código.

- **I9-D1 (árvore 2.3, módulo novo):** criar `lib/shell/config.sh`, que não
  consta da árvore da seção 2.3. As 17 funções de configuração (~470 linhas,
  `lib/common.sh:1104-2085`) não têm casa entre os dez módulos previstos; jogá-las
  em `storage.sh` misturaria schema de configuração com ciclo de vida de arquivo,
  que são responsabilidades diferentes. A seção 2.3 autoriza o ajuste com
  justificativa registrada, e esta é a justificativa.
- **I9-D2 (inventário sem módulo próprio):** as 16 funções de inventário
  (`lib/common.sh:353-1098`) NÃO ganham `lib/shell/inventory.sh`. A captura vai
  para `probes.sh` e o ciclo de vida do arquivo vai para `storage.sh`. Motivo
  técnico, não estético: manter as duas juntas cria o ciclo `probes <-> storage`,
  porque a enumeração de disco e a captura de topologia se chamam nos dois
  sentidos. Separar por natureza (observar o host x administrar o arquivo) deixa
  a direção única.
- **I9-D3 (`_core_diagnostico` e `CORE_PARES_ENVELOPE`):** ficam em `base.sh`,
  não em `lib/python-core.sh`. As duas opções são consistentes com a seção 2.4,
  mas `python-core.sh` teve manifesto aprovado em I2 e mover coisa para lá
  reabriria uma fronteira já fechada sem ganho.
- **I9-D4 (`inicializar_raiz_teste`):** vai para `privilege.sh`, não para
  `base.sh`. Ela chama `falhar`, e `falhar` mora em `ui.sh`; deixá-la em
  `base.sh` criaria o ciclo `base <-> ui`. O lugar é coerente com o que ela faz:
  validar que o `sudo` visível é o mock confinado.
- **I9-D5 (`v_kernel_persistencia_falhou`):** vai para `boot.sh`, não para
  `status.sh`. É a única função de status que lê estado de boot
  (`KERNEL_PERSISTENCIA_TIPO`, `lib/shell/boot.sh:426`); mantê-la em `status.sh`
  faria o módulo de status depender do de boot sem necessidade.
- **I9-D6 (carregamento sem efeito):** `lib/shell/boot.sh:26-33` passa a resolver
  caminhos preguiçosamente. Hoje ele executa quatro subshells `caminho_sistema`
  em tempo de `source` e por isso exige que `inicializar_raiz_teste` tenha rodado
  antes. Com a resolução preguiçosa, a única exigência de ordem que sobra é
  `platform.sh`/`python-core.sh` antes do resto, e I9.1 fica cumprido
  literalmente em vez de por aproximação.
- **I9-D7 (código de saída da dispensa):** as duas dispensas que sobraram
  continuam devolvendo `0` no `--verificar`. O bullet do REQ-WAIVERS que manda
  devolver `1` vale para **dispensa de etapa**, categoria que deixou de existir
  quando I4.8 removeu `AIRLOCK_DISPENSADO` e `BACKUP_DISPENSADO`. As duas
  remanescentes são `escolha-de-modo` (D-WAIVERS): com a escolha registrada, o
  estado real do host é "este fluxo não usa esse recurso", e é isso que o
  verificador relata. O bullet que continua valendo é o de **não chamar isso de
  concluída**, e ele é atendido na UI: o menu passa a renderizar `[disp]` no
  lugar de `[ok]`, lendo a flag por canal separado, sem tocar `MENU_STATUS_RC`
  nem o sentinel V1. Trocar para `1` foi considerado e recusado: mudaria status
  público hoje verde para amarelo e quebraria os oráculos de `tests/i0` sem
  descrever melhor o host.

### Decisões tomadas durante a extração (registradas em 2026-08-30, com o código na mão)

As cinco decisões abaixo não estavam nas sete de entrada porque só aparecem
quando o grafo real de chamadas é medido. Todas foram tomadas para manter o
grafo acíclico, e cada uma cita o ciclo concreto que evita.

- **I9-D8 (`lib/shell/hooks.sh` não é criado):** a seção 2.3 prevê o módulo,
  mas não existe uma linha de lógica de hook em `lib/common.sh` para extrair.
  Os hooks são gerados por `etapas/50-hooks-gpu-hd1.sh` com todo o estado
  literal dentro deles, e a seção 2.1 exige que sejam autossuficientes. Um
  módulo compartilhado de hooks criaria exatamente a dependência do checkout
  que o contrato proíbe. I9.5 passa a ser cumprido por prova, não por
  arquivo: `tests/test-i9-hooks-isolados.sh` renderiza os hooks, apaga o
  projeto que os gerou e só então os executa.
- **I9-D9 (predicados puros em `base.sh`):** `nome_*_valido`, `pci_*_valido`,
  `inteiro_na_faixa`, `lista_cpus_valida`, `caminho_absoluto_seguro`,
  `mac_valido`, `ipv4_*` e `cidr_*` decidem sobre TEXTO e são consumidos por
  configuração, armazenamento, sondas e rede ao mesmo tempo. Distribuí-los
  pelos módulos de domínio criava dois ciclos medidos: `config <-> storage`
  (o validador de grupo dedicado) e `probes <-> storage`
  (`caminho_absoluto_seguro`). Em `base.sh` a direção fica única.
- **I9-D10 (leitura do inventário publicado é de `storage.sh`):** completa a
  decisão I9-D2. `comparar_inventario_com_hardware` e
  `inventario_revalidar_papeis_disco_configurados` leem o arquivo publicado,
  então moram em `storage.sh` e chamam `probes.sh` para observar o host. A
  regra que sobra é simples e verificável: `probes.sh` nunca lê o arquivo de
  inventário.
- **I9-D11 (constantes de domínio saem da fachada):** `CONF_ARQUIVO` vai para
  `config.sh`, `FSTAB` para `storage.sh` e `VIRSH` para `libvirt.sh`. A
  fachada mantém apenas o que é do projeto (`COMMON_DIR`, `PROJETO_DIR`,
  `BACKUPS_DIR`, `LIB_COMMON_VERSION`). Um agregador que ainda declara o
  caminho de um domínio continua sendo dono desse domínio pela porta dos
  fundos.
- **I9-D12 (a fachada resolve os caminhos de boot uma vez):** além da
  resolução preguiçosa exigida por I9-D6, `lib/common.sh` chama
  `boot_caminhos_resolver` depois de `inicializar_raiz_teste`. Consumidores
  fora do módulo (a etapa 11, por exemplo) leem `VFIO_MODULES_ARQUIVO`
  diretamente em mensagens, e sob `set -u` uma variável não resolvida
  abortaria a etapa. O módulo continua sem efeito no source: a função é
  idempotente e respeita valor já definido pelo chamador, que é o que permite
  às fixtures de teste apontarem os quatro caminhos para a raiz hermética.

### Tarefas

- [x] **I9.1:** mapear grafo de `source`; criar guards; impedir ciclos e efeitos em carregamento.
- [x] **I9.2:** extrair base/UI/privilégio/status preservando wrappers e mensagens.
- [x] **I9.3:** separar probes de storage/libvirt/rede/hooks sem esconder pós-condições; consolidar e revisar `lib/shell/boot.sh` já criado em I5, sem recriá-lo nem introduzir segundo caminho mutante.
- [x] **I9.4:** transformar `common.sh` em agregador determinístico, sem algoritmos de domínio.
- [x] **I9.5:** garantir hooks Bash puros e independentes, com `bash -n` e testes isolados.
- [x] **I9.6:** testar source isolado, ordem errada com diagnóstico e duplo source idempotente.
- [x] **I9.7:** implementar integralmente REQ-WINDOWS-STATE.
- [x] **I9.8:** implementar integralmente REQ-AIRLOCK-VERIFY, reutilizando a mesma avaliação efetiva usada no apply.
- [x] **I9.9:** concluir REQ-VERIFY-FAILCLOSED em todos os verificadores.
- [x] **I9.10:** concluir integração de REQ-WAIVERS em menu, pré-requisitos, execução direta, status e resumo.
- [x] **I9.11:** revisão semântica do checkpoint (regra 15), com os defeitos encontrados corrigidos e cada um coberto por regressão que falha na árvore anterior.
- [x] **I9.13:** fechar **REQ-BOOT-POSCONDICAO** provando o ARTEFATO regenerado, e não a fonte contra o backup da fonte, nos caminhos de apply e de rollback do GRUB. É pré-requisito de I9.12: a migração de I9.12 remove parâmetros de boot, e fazer isso sobre um rollback que anuncia sucesso sem provar o `grub.cfg` seria construir sobre falso sucesso.
- [ ] **I9.12:** implementar **REQ-VM-RESOURCE-LIFECYCLE**, garantindo que recursos computacionais dedicados à VM sejam adquiridos somente para o ciclo da VM e devolvidos ao host depois que ela parar. **I9 fica reaberta por este requisito, registrado em 02/09/2026 após observar 22 GiB de HugePages de 1 GiB livres, porém permanentemente retirados da RAM comum com a VM desligada.** O contrato é:
  - **Decisão de viabilidade:** HugePages explícitas são otimização, não requisito funcional para a VM. Memória normal, com THP apenas oportunístico, é o baseline mais confiável e volta naturalmente ao host quando o QEMU termina. HugePages de 2 MiB alocadas em runtime são o modo hugetlb preferencial a avaliar. HugePages de 1 GiB em runtime são viáveis somente como modo `best-effort` fail-closed: cada página exige 1 GiB fisicamente contíguo e a alocação exata de 22 páginas não pode ser garantida após uptime, pressão ou fragmentação. Reserva de 1 GiB no boot pode continuar apenas como perfil legado/opt-in de desempenho, explicitamente incompatível com este requisito e fora da base qualificada retornável; nunca como padrão silencioso.
  - **RAM no start:** em `prepare/begin`, antes de desligar display ou destacar GPU, capturar baseline, boot ID, fingerprint de topologia/NUMA, política, tamanho do pool, páginas livres/reservadas/surplus e ownership; tomar lock global por pool; e, somente quando a política exigir hugetlb, adquirir exatamente o delta necessário. Alocação parcial, NUMA divergente, memória insuficiente, consumidor externo ou pós-condição não comprovada abortam o start, restauram o baseline e impedem o QEMU. Não fazer fallback silencioso entre 1 GiB, 2 MiB, THP e memória normal.
  - **RAM no stop:** em `release/end`, falha de start e recuperação órfã, provar domínio desligado, ausência de QEMU residual e páginas atribuídas à operação já livres; devolver somente o delta adquirido pela operação e comprovar `total/free/reserved/surplus` iguais ao baseline legítimo anterior. Nunca zerar pool preexistente ou pertencente a terceiro. Se a devolução não puder ser provada, preservar state privado, marcar `RECOVERY_REQUIRED`, tentar as demais restaurações independentes e retornar erro; o dispatcher de release não pode abandonar GPU/display/CPU porque uma limpeza anterior falhou.
  - **CPU:** manter `vcpupin`/`emulatorpin`, que deixam de consumir CPU quando o QEMU termina. `isolcpus`, `nohz_full` e `rcu_nocbs` persistentes não devolvem CPUs ao scheduler e são incompatíveis com o perfil retornável; a etapa 18 deve migrá-los/removê-los com transação e reboot comprovado. Cpuset/cgroup dinâmico só pode ser habilitado depois de implementar snapshot, ownership, restauração e prova de elegibilidade; não prometer equivalência a isolamento de boot nem ausência total de IRQs/jitter.
  - **Migração do estado atual:** substituir de forma transacional o contrato estático da etapa 17 e o isolamento da etapa 18, sem manter dois caminhos mutantes. Remover dependência XML/persistência de boot na ordem segura para a política escolhida, retirar conjuntamente `default_hugepagesz`, `hugepagesz` e `hugepages`, retirar conjuntamente o isolamento estático, reiniciar uma vez e provar baseline sem VM antes de habilitar o lifecycle dinâmico. Preservar os 21 itens, entrypoints e status públicos `0/1/2/3`.
  - **Estado e recuperação:** hooks instalados permanecem Bash puro, autossuficientes e independentes do checkout; Python apenas calcula/valida plano, contagem, diff e fingerprints. Registrar estados `PREPARED/ACQUIRED/VERIFIED/RELEASING/RELEASED/RECOVERY_REQUIRED`, operação/VM/boot ID/baseline/delta, com lock, permissões privadas, idempotência, proteção contra double-acquire/double-release, duas VMs, daemon indisponível, crash do QEMU e state órfão. Power loss/reboot não depende de `release/end`: o boot seguinte deve reconciliar o baseline declarativo antes de permitir novo start.
  - **Testes e gates:** I10/I12 devem usar sysfs, cgroup, libvirt e QEMU simulados, sem alterar o host, cobrindo memória normal/THP, 2 MiB runtime, 1 GiB runtime parcial/indisponível, pool externo, NUMA, falha/sinal em cada janela, start recusado, release com múltiplas falhas, crash, daemon indisponível, recuperação órfã, dois ciclos completos e no-op. O Gate I9 exige baseline restaurado e recursos externos preservados; nenhum modo entra como qualificado por fixture.
  - **Aceite operacional I13:** em hardware autorizado, registrar métricas antes/durante/depois e repetir start/stop/crash: com VM parada, toda RAM e toda CPU gerenciadas pelo perfil retornável estão novamente elegíveis ao host; com VM ativa, QEMU consumiu exatamente a política escolhida; falha de aquisição não inicia a VM; falha de release permanece erro recuperável com evidência. Medir sucesso após uptime/fragmentação e benefício de cada modo. Se 1 GiB runtime não for confiável, qualificar memória normal/THP ou 2 MiB runtime e manter 1 GiB estática somente como exceção opt-in não retornável.

### Decisões tomadas ao implementar I9.12 (03/09/2026)

Seis decisões que mudam o desenho e não se re-derivam lendo o código depois.

- **I9.12-D1 (o hook faz a aritmética; o core faz o plano):** a decisão I9-D8
  obriga o hook a ser autossuficiente — `tests/test-i9-hooks-isolados.sh` APAGA
  o projeto antes de executá-lo —, então ele não pode chamar Python. A
  aritmética de aquisição e devolução é Bash puro dentro do hook, e o core é o
  planejador usado pela etapa e pelo gate. São duas implementações da mesma
  regra por necessidade, e o que impede as duas de divergirem em silêncio é o
  oráculo diferencial de `tests/test-i912-memoria-hooks.sh`, não confiança.
- **I9.12-D2 (o estado de memória é persistente, não `/run`):** o estado do
  ciclo de GPU vive em `/run` e some no reboot. O de memória vive em
  `/var/lib/vm-passthrough/`, porque o requisito manda reconciliar por boot ID,
  e boot ID só significa alguma coisa em estado que SOBREVIVE ao reboot. Estado
  de outro boot descreve páginas que o reboot já devolveu: a reconciliação é
  descartá-lo **sem tocar no pool**, porque o pool atual pertence a este boot.
- **I9.12-D3 (o estado é gravado ANTES da escrita no pool):** se o hook morrer
  entre adquirir e registrar, o release não saberia o que é dele para devolver,
  e devolver "o que parecer nosso" é como se tira página de terceiro. A ordem
  inversa perde páginas; esta, no pior caso, deixa um estado a mais para a
  reconciliação resolver.
- **I9.12-D4 (recusa transitória e recusa estrutural são coisas diferentes):**
  `plan` publica `transient`. Recusa que depende do pool NAQUELE instante
  (consumidor externo, `resv`, `surplus`, `MemAvailable`) é reavaliada pelo
  hook no start. Recusa estrutural (modo, aritmética de página, pool ausente,
  NUMA) não muda por esperar e o hook **não tem como reavaliá-la sozinho** — em
  NUMA ele é cego por desenho. Por isso ela viaja assada em `MEM_PLANO_VALIDO`
  e o hook nasce bloqueado. Sem essa distinção havia um buraco real, encontrado
  pelo oráculo: plano recusado por NUMA chegava ao hook com contagem válida e
  ele adquiria.
- **I9.12-D5 (sair do perfil retornável se digita):** a etapa 18 recusa
  isolamento persistente por padrão e exige `ISOLAMENTO-NAO-RETORNAVEL`
  digitado. `isolcpus`, `nohz_full` e `rcu_nocbs` não devolvem CPU quando a VM
  para, e o custo é permanente para o host; uma escolha assim precisa ficar
  explícita no log de ações, não escondida atrás de um `s`.
- **I9.12-D6 (o contrato das etapas 17 e 18 foi SUBSTITUÍDO, não estendido):**
  a ausência de reserva e a ausência de isolamento passaram a ser pós-condição
  de SUCESSO. Enquanto o `--verificar` exigisse `HugePages_Total` igual a
  `HUGEPAGES_1G`, o host correto seria relatado como divergente e o status do
  menu empurraria o operador de volta ao defeito. Acrescentar um modo ao lado
  do contrato velho manteria dois caminhos mutantes, que a regra 8 proíbe.

### Sequência de migração deste host, medida em 03/09/2026 (entrada de I9.12)

A auditoria de I9.12 encontrou algo que muda o tamanho da tarefa: **a etapa 17
já implementa a ordem segura de remoção**, e a impõe estruturalmente, não por
instrução ao operador. `--desfazer` detecta se o XML ainda exige HugePages e,
se exigir, executa **somente** a fase 1/2 (retira a exigência do XML, prova a
remoção no XML persistido, prova que nada não gerenciado mudou) e retorna
pedindo uma segunda invocação. Só na segunda, com o XML já independente, ele
retira `default_hugepagesz`, `hugepagesz` e `hugepages` **juntas** do boot,
prova a ausência persistente e pede reboot. Pelo caminho suportado é impossível
retirar o parâmetro de boot antes do XML.

A assimetria que justifica essa ordem é mecânica, e vale registrar porque é o
que torna a inversão perigosa: **XML exigindo 1 GiB com o pool ausente** faz o
QEMU não conseguir mapear o backing store e o domínio não inicia — e a falha
acontece **depois** do `prepare/begin`, isto é depois de o hook já ter parado o
display manager e descarregado os módulos da NVIDIA, deixando o operador sem
desktop e sem VM. **XML sem 1 GiB com o pool presente** apenas desperdiça as
páginas. A migração tem de atravessar o desperdício, nunca a indisponibilidade.

Estado medido antes da migração: `HUGEPAGES_1G=22`, `VM_RAM_MB=22528`, XML com
`memoryBacking/hugepages` de 1 GiB, as três chaves ativas no GRUB, pool com 22
páginas, e o `--verificar` da etapa 17 devolvendo `[ok] Pool ativo: 22 páginas
de 1 GiB` — ou seja, o estado que este requisito trata como defeito é hoje
relatado como sucesso.

Sequência, na ordem, com a VM desligada e provada desligada. Ela **corrige** a
que a auditoria propôs, por causa de uma medição feita em 03/09/2026 no momento
de executar: com o pool reservado, `MemAvailable` é de **3,26 GiB** e a VM pede
**22 GiB de memória comum**. O passo "inicie a VM entre as duas reversões para
provar que ela sobe com memória comum" era, portanto, **impossível** neste
estado — não havia RAM comum para ela subir. O que destrava isso é uma segunda
medição: este kernel (7.0.0-30-generic) traz `CONFIG_CONTIG_ALLOC=y`, o arquivo
`demote` no pool de 1 GiB e `nr_hugepages` gravável por root, ou seja **página
gigante reservada no boot pode ser devolvida em runtime**, sem reiniciar. A
devolução em runtime toma o lugar do reboot como pré-condição da prova, e a
prova fica mais forte do que a original, porque passa a acontecer com o pool
já ausente em vez de ainda presente.

1. `bash etapas/52-cpu-pinning-hugepages.sh --desfazer` (1ª vez) retira o
   `memoryBacking/hugepages` do XML, com backup em `BACKUPS_DIR` e rollback
   provado por releitura semântica. O XML deixa de exigir o pool ANTES de o
   pool sumir, que é a assimetria que a auditoria estabeleceu e continua
   valendo.
2. Devolver o pool em runtime, escrevendo `0` em
   `/sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages`. Reversível
   escrevendo `22` de volta, e seguro somente porque o pool está inteiramente
   livre (`HugePages_Free` igual a `HugePages_Total`); com página em uso, esta
   escrita não devolveria nada e o requisito manda recusar.
3. Iniciar a VM uma vez e confirmar que ela sobe com memória comum, agora com
   o pool já ausente. Em host de GPU única isto derruba a sessão gráfica pelos
   hooks, então é uma janela escolhida pelo operador, não um passo automático.
4. `bash etapas/52-cpu-pinning-hugepages.sh --desfazer` (2ª vez) retira as três
   chaves do boot, juntas, pela transação de `lib/shell/boot.sh` — que só é
   confiável depois de I9.13, porque até `43ec863` o rollback dela anunciava
   regeneração do `grub.cfg` sem nunca conferir o artefato.
5. Reiniciar uma vez e provar que o baseline PERSISTE: `HugePages_Total=0`,
   `Hugetlb=0` e `MemAvailable` na ordem de 26 GiB. O passo 2 já devolveu a RAM
   neste boot; o reboot prova que ela não volta a ser reservada.
6. Só então declarar `MEMORIA_MODO` e habilitar o ciclo de vida dinâmico.

**Resultado medido dos passos 1 e 2, executados em 03/09/2026.** A reversão do
XML e a devolução em runtime foram feitas pelo operador (este host exige
autenticação interativa para `sudo`, então toda etapa mutante é dele):

| | antes | depois |
|---|---|---|
| `MemAvailable` | 3.262.344 kB | **26.163.004 kB** |
| `MemFree` | 453.396 kB | 23.302.840 kB |
| `HugePages_Total` | 22 | **0** |
| `Hugetlb` | 23.068.672 kB | **0** |
| XML da VM | `memoryBacking` de 1 GiB | sem `memoryBacking` |

**21,8 GiB devolvidos ao host sem reiniciar.** Isso confirma na prática o que a
configuração do kernel indicava: página gigante reservada no boot É devolvível
em runtime neste kernel, e portanto o modo `hugetlb-1g` em runtime é
fisicamente possível aqui. A prova vale para o desenho de I9.12 inteiro: sem
ela, o modo de 1 GiB em runtime seria especulação.

**Passos 4 e 5 executados em 03/09/2026: migração concluída e persistente.** O
passo 3 (iniciar a VM para provar que ela sobe com memória comum) **não** foi
executado: em GPU única ele derruba a sessão gráfica, e o operador preferiu ir
direto ao reboot. A prova continua devendo e pertence a I13, junto com o resto
da qualificação em hardware. A
fase 2/2 removeu `default_hugepagesz`, `hugepagesz` e `hugepages` do GRUB e o
host reiniciou. Estado depois do reboot:

- `/proc/cmdline` sem nenhuma chave de hugepages;
- `HugePages_Total=0`, `Hugetlb=0`;
- `MemAvailable` em **29.093.508 kB (27,7 GiB)** de `MemTotal` 31.722.704 kB;
- `GRUB_CMDLINE_LINUX_DEFAULT="quiet splash amd_iommu=on iommu=pt"`.

Duas coisas provadas aqui, além da devolução em si. Primeira: **`amd_iommu=on` e
`iommu=pt` sobreviveram**. Eram o risco R2 da auditoria — a remoção arrastar
chave de outro dono e quebrar o passthrough inteiro —, e o `kernel_param_del`
por chave o evitou. Segunda: esta foi a **primeira execução real** da transação
de boot corrigida em I9.13, e ela concluiu sem acusar rollback, o que só passou
a significar alguma coisa depois que a prova deixou de comparar a fonte com o
backup da fonte.

O baseline retornável do host está estabelecido. O que falta de I9.12 não é
mais a migração, é a **metade executora**: adquirir no start, devolver no stop.

**A inversão de contrato, demonstrada em vez de argumentada.** Com o host já no
estado que este requisito considera CORRETO, `bash etapas/52-cpu-pinning-hugepages.sh --verificar`
devolve `rc=2` e diz:

```
[aviso] Pool de HugePages divergente: HugePages_Total=0; esperado exatamente 22.
[aviso] XML de CPU/HugePages incompleto ou divergente: memoryBacking/hugepages
        precisa existir exatamente uma vez.
```

Ou seja, a etapa 17 hoje reporta como defeito exatamente o estado que
REQ-VM-RESOURCE-LIFECYCLE persegue. É por isso que I9.12 **substitui** o
contrato da etapa e não acrescenta um modo ao lado dele: enquanto o
`--verificar` exigir `HugePages_Total` igual a `HUGEPAGES_1G`, o host correto
será relatado como divergente, e o operador será empurrado de volta à reserva
estática pelo próprio status do menu.

A etapa 18 **não entra** nesta sequência neste host: não há `isolcpus`,
`nohz_full` nem `rcu_nocbs` no `/proc/cmdline`, então o trabalho dela em I9.12 é
recusar entrar nesse estado, não sair dele.

**Como cada tarefa foi comprovada:**

| Tarefa | Entrega | Prova |
|---|---|---|
| I9.1 | grafo medido (180 funções), guarda e pré-requisito nominal em cada módulo, resolução preguiçosa em `lib/shell/boot.sh` | `tests/test-i9-modulos.sh` casos 1 a 3 |
| I9.2 | `lib/shell/{base,ui,privilege,status}.sh` | corpo de função idêntico byte a byte ao de `58e8482`; superfície pública sem perda |
| I9.3 | `lib/shell/{probes,storage,network-effects,libvirt,config}.sh`; `boot.sh` consolidado, não recriado | grafo sem ciclo; `tests/test-i5-cpu-boot.sh` continua provando definição única de boot |
| I9.4 | `lib/common.sh` de 4145 para 80 linhas, só agregação | `tests/test-i9-modulos.sh` caso 8 |
| I9.5 | hook de instalação passa a declarar PATH próprio; prova de independência | `tests/test-i9-hooks-isolados.sh` (6 hooks, projeto apagado antes da execução) |
| I9.6 | source isolado, ordem errada, duplo source e carga sem efeito | `tests/test-i9-modulos.sh` (37 casos) |
| I9.7 | eixos independentes de instalação, power state e agent | `tests/test-i9-windows-state.sh`, commit `c7e4e8f` |
| I9.8 | prova da política Airlock em efeito, não do texto | `tests/test-i9-airlock-verify.sh`, commit `54327bf` |
| I9.9 | provas compartilhadas dos verificadores | `tests/test-i9-verify-helpers.sh`, commits `8bf5fd6` e `57af49f` |
| I9.10 | matriz de dispensas versionada e símbolo `[disp]` no menu | `tests/test-i9-waivers.sh`, `tests/check-waivers-matrix.py`, commits `7febdd2` e `da7df55` |
| I9.11 | três defeitos da revisão semântica corrigidos: leitor de dispensa fail-closed, menu sem afirmação que ele não pode sustentar e o último `[ -f ] && v_ok` eliminado | `tests/test-i9-revisao-semantica.sh` (24 casos), commit `43ec863`; cada defeito reprova isoladamente na árvore de `91cd349` |
| I9.12 | **migração**: XML sem `memoryBacking`, três chaves fora do GRUB, pool devolvido em runtime e baseline provado persistente após reboot. **Núcleo puro** `resources.py`: plano, prova de pós-condição, plano de devolução e máquina de estados com reconciliação por boot ID. **Fotografia** `recursos_fotografar` e chave `MEMORIA_MODO`. **Metade executora**: `mem_adquirir` no `prepare/begin` antes de o display cair, `mem_devolver` no `release/end` sem poder abortar, estado 0600 em `/var/lib/vm-passthrough/` publicado por rename e carimbado com `BOOT_ID`. **Contrato da etapa 17 substituído**: a política virou o critério, e a ausência de reserva virou pós-condição de sucesso. | 21,8 GiB devolvidos sem reiniciar e `MemAvailable` em 29,1 GB após o reboot, com `amd_iommu=on iommu=pt` preservados; `tests/python/test_resources.py` (135 métodos, 20 mutações aplicadas e 20 pegas, 6 defeitos do núcleo achados e corrigidos); `tests/test-i912-memoria-hooks.sh` (sysfs simulado, 10 mutações e 10 pegas, oráculo diferencial Bash × Python, 2 defeitos do hook achados e corrigidos — um deles reduzia o pool de 4096 para 1096 páginas a partir de estado ilegível). **Falta**: etapa 18 e qualificação em hardware (I13). |
| I9.13 | `_grub_cfg_copia` captura o artefato ANTES da janela; o rollback só anuncia sucesso quando o `grub.cfg` volta byte a byte ao estado anterior, e o apply recusa aplicador que devolveu zero sem regenerar | `tests/test-i5-cpu-boot.sh` caso 3e-bis: com a chamada 1 do `update-grub` regenerando divergente (o que um snippet de `/etc/default/grub.d` faz de verdade) e a chamada 2, a da restauração, devolvendo zero sem escrever, a árvore de `43ec863` imprime **"Rollback da fonte GRUB e regeneração do grub.cfg concluídos"** com o artefato ainda divergente; a árvore corrigida recusa a prova e nomeia a causa |

### Gate I9

`common.sh` não é monolítico; sem ciclos/efeitos no source; mesmos entrypoints e superfície de privilégio; hooks independentes; estados Windows corretos; Airlock semântico; nenhum verifier com falso sucesso; revisão semântica sem bloqueador; e, por I9.12, **baseline de recursos restaurado com a VM parada e recursos externos preservados**, com nenhum modo qualificado por fixture.

## I9B: Internacionalização (en, pt-BR, es)

**Pré-condição:** I9 aprovado. Os módulos de `lib/shell/` precisam estar estáveis; extrair strings de um `common.sh` monolítico que será quebrado logo depois duplica o churn no mesmo arquivo.

**Objetivo:** tornar toda a superfície humana traduzível por arquivos de texto, sem alterar uma única decisão de fluxo, código de saída ou byte do canal de máquina. Ver o contrato normativo na seção 3.10.

**Dimensão real medida em 23/08/2026** (use estes números como baseline e reconfirme antes de começar):

| Alvo | Pontos de saída humana | Observação |
|---|---|---|
| `etapas/*.sh` (21 arquivos) | 1451 | maiores: `02-detectar-config.sh` (193), `60-rede-bridge.sh` (177), `50-hooks-gpu-hd1.sh` (157), `40-criar-vm.sh` (113), `61-airlock.sh` (105) |
| `util/*.sh` (6 arquivos) | 179 | maior: `recuperar-gpu.sh` (61) |
| `lib/*.sh` + `lib/shell/*.sh` | 147 | `common.sh` (99), `boot.sh` (48) |
| `menu.sh` | 6 | |
| **Total** | **1783** | contagem de chamadas de `info`/`ok`/`aviso`/`erro`/`titulo`/`falhar`/`v_ok`/`v_falta`/`v_erro` com literal |

**Acoplamento dos testes, medido:** existem **46** chamadas de `assert_text`/`assert_text_any` (44 em `tests/test-i0-mutators.sh`, 2 em `tests/test-atualizar-host-validation.sh`), das quais **12** casam texto humano em português. O restante do português nos testes são mensagens de falha do próprio teste, que são superfície de desenvolvedor e **não** entram no catálogo. Esse acoplamento é pequeno e não justifica adiar a fase.

### Tarefas

- [ ] **I9B.1:** criar `lang/en.msg`, `lang/pt-BR.msg` e `lang/es.msg`. Formato: uma entrada por linha, `CHAVE=valor`, comentários iniciados por `#`, linha vazia ignorada, sem continuação de linha, sem aspas envolventes, UTF-8 sem BOM, terminador LF. Chave casa `^[A-Z][A-Z0-9_]*(\.[A-Z][A-Z0-9_]*)*$` e usa namespace por origem (`MENU.`, `CONF.`, `REDE.`, `AIRLOCK.`, `GPU.`, `USB.`, `CPU.`, `BOOT.`, `VM.`, `TRIM.`, `COMMON.`). Justificativa de não usar gettext: `.po`/`.mo` exigem runtime e ferramenta externas, e o plano proíbe dependência nova; `$"..."` do Bash depende de `.mo` compilado e de locale do sistema, o que quebraria o determinismo exigido pela seção 3.8.
- [ ] **I9B.2:** implementar `lib/shell/i18n.sh` com `i18n_carregar` e `msg CHAVE [args...]`. O carregamento lê o catálogo linha a linha com `while IFS= read -r`, separa a chave com `${linha%%=*}` e o valor com `${linha#*=}`, valida a chave pela expressão acima e popula um array associativo. **Proibido** `source`, `eval`, `declare` a partir do arquivo, substituição de comando e expansão aritmética sobre o valor. Carregar uma vez por processo; sem I/O por mensagem.
- [ ] **I9B.3:** validar a format string no carregamento: percorrer o valor e aceitar apenas `%%` e `%N$s` com `N` de 1 a 9. Qualquer outro `%` invalida o catálogo inteiro, registra aviso e força fallback para `en`. Provar com fixture hostil contendo `%n`, `%s` simples, `%(`, `%` terminal, `$(id)`, crase, `${IFS}`, `;rm`, CRLF, BOM, chave duplicada, linha truncada e encoding inválido; nenhum caso pode executar nada nem abortar o processo.
- [ ] **I9B.4:** implementar a precedência de seleção da seção 3.10 e a normalização de locale (`pt_BR.UTF-8` para `pt-BR`, `es_ES@euro` para `es`, desconhecido para `en`). Acrescentar a chave `IDIOMA` ao schema de `passthrough.conf` e a `passthrough.conf.example`, com classe de dado conforme a seção 3.9 e valor padrão vazio (que significa "decidir pelo ambiente").
- [ ] **I9B.5:** implementar fallback por chave com marcador `!!CHAVE!!`, aviso registrado e erro sob `PASSTHROUGH_I18N_STRICT=1`. Provar que mensagem ausente **nunca** aborta mutador nem altera código de saída.
- [ ] **I9B.6:** implementar `libexec/passthrough_core/messages.py` e o subcomando correspondente na CLI para **validar e comparar catálogos** (cálculo puro, cabe na fronteira). O Bash não chama Python por mensagem, apenas nos testes e no gate; o custo por mensagem em runtime precisa continuar zero.
- [ ] **I9B.7:** migrar a superfície humana na ordem `menu.sh` (6), `lib/` (147), `util/` (179) e `etapas/` na ordem do menu (1451). Manter um allowlist explícito em `tests/i18n-pendentes.txt` com os arquivos ainda não migrados; o gate exige que essa lista **encolha monotonicamente** e termine vazia. Nunca manter dois caminhos de mensagem no mesmo arquivo.
- [ ] **I9B.8:** traduzir prompts interativos (`read -r -p`) de `menu.sh` e `etapas/02-detectar-config.sh` **sem** traduzir as respostas aceitas. As respostas continuam sendo comparadas por valor canônico (`s`/`n` viram um conjunto por idioma mapeado para um booleano interno), jamais por texto traduzido. Provar que responder no idioma ativo e no idioma de fallback produz a mesma decisão.
- [ ] **I9B.9:** implementar `tests/check-i18n-catalogs.py` e integrá-lo ao gate canônico. O checker reprova: conjunto de chaves divergente entre os três catálogos; chave fora do padrão; chave duplicada; placeholders com índices ou aridade divergentes entre idiomas; `%` fora da allowlist; BOM, CRLF ou byte inválido; chave órfã (no catálogo e não usada no código); literal humano remanescente fora de `msg` em arquivo já migrado.
- [ ] **I9B.10:** fixar `PASSTHROUGH_LANG=pt-BR` nas suítes existentes para preservar as 12 asserções atuais, e acrescentar uma suíte nova que reexecuta os mesmos cenários sob `en` e `es` verificando **apenas** código de saída, canal de máquina e efeitos no host. Isso prova a invariante central: idioma não muda comportamento.
- [ ] **I9B.11:** garantir que os hooks libvirt continuem Bash puro e autossuficientes. Hook **não** carrega catálogo e **não** depende do diretório do repositório; suas mensagens permanecem fixas em `en`, com justificativa registrada, porque rodam fora da sessão do operador.
- [ ] **I9B.12:** acrescentar `tests/manifests/i9b-files.txt` e registrar todos os arquivos novos.

### Gate I9B

Três catálogos com o mesmo conjunto de chaves e placeholders compatíveis; `tests/i18n-pendentes.txt` vazio; nenhum literal humano fora de `msg` fora dos hooks; catálogo hostil inerte e comprovado; ausência de chave não aborta e não muda status; a suíte roda idêntica em `pt-BR`, `en` e `es` quanto a código de saída, canal de máquina e efeitos; nenhum item do canal de máquina foi traduzido; hooks permanecem independentes; segunda execução no-op; gate canônico aprovado.

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
- [ ] **I13.8:** testar Airlock positivo/negativo por IPv4 e IPv6 e política SSH efetiva. Esta tarefa inclui obrigatoriamente a descobribilidade e a prova operacional abaixo; a instalação existente pode ser usada como alvo de coleta, mas nunca como aprovação presumida.
  - **Instruções recuperáveis no fluxo público:** a etapa Airlock do `menu.sh` deve mostrar ou oferecer, de forma explícita, as instruções detalhadas de teste também quando o estado já estiver convergido, sem exigir reaplicação, troca de chave, desmontagem ou outra mutação apenas para rever o roteiro. O aceite deve confirmar em terminal que um usuário com VM já instalada consegue reencontrar o roteiro pela própria etapa; um simples `[ok]` no menu não satisfaz este item.
  - **Diagnóstico de instruções não vistas:** antes de atribuir causa, registrar a revisão do código e qual caminho foi usado: execução completa sem argumento, consulta automática/`--status`, `--verificar`, `--instalar-chave`, cancelamento ou falha anterior ao bloco final. Confirmar pela saída observada se o bloco foi realmente exibido e preservado antes do retorno ao menu. No comportamento auditado, somente a execução completa que alcança o fim imprime as sete verificações; os demais caminhos não provam que o usuário as viu. Distinguir ainda “não exibido”, “exibido mas não registrado” e “exibido, porém não executado”.
  - **Roteiro mínimo a mostrar e registrar separadamente:** (1) montagem e visão `fuse.bindfs`, incluindo visibilidade host↔chroot; (2) sintaxe e estado efetivo do `sshd`; (3) transferência SFTP real VM→host e host→VM; (4) confinamento, no qual `/` mostra somente a pasta publicada; (5) rejeição imediata sem a chave correta; (6) regra de firewall restrita ao IP/interface esperados, com testes positivos e negativos reais em IPv4 e IPv6; e (7) remontagem pelo hook em ciclo controlado da VM, comprovada por estado e logs. As instruções devem identificar pré-condições, resultado esperado, forma de registrar a evidência e recuperação segura; ações como desmontar, iniciar a VM ou testar rede real exigem a autorização, backup e console alternativo já requeridos por I13 e não podem ser disparadas automaticamente para apenas exibir o roteiro.
  - **Instalação existente como evidência candidata:** registrar a combinação exata, revisão do repositório, configuração redigida e baseline antes dos testes. Executar uma verificação contemporânea; somente status público `0` com sentinel válido conta como evidência host-side. Status `1`, `2` ou `3`, ausência de privilégio para observar política efetiva, valores ausentes ou qualquer pós-condição não comprovada mantêm o item pendente. Não alterar a instalação apenas para fazê-la parecer convergida antes de preservar o diagnóstico inicial.
  - **Limite da prova:** `[ok]`, `--verificar`, arquivos presentes, VM previamente criada ou a mera exibição do roteiro não comprovam transferência ponta a ponta. Para concluir I13.8, anexar resultados redigidos dos sete itens, horários/revisão, intervenções e limitações; a instalação reaproveitada pode provar esta tarefa se todos os testes forem realmente repetidos e observados, mas não substitui a instalação limpa de I13.2 nem qualifica outra combinação.
- [ ] **I13.9:** medir TRIM por blocos/alocação real.
- [ ] **I13.10:** testar bridge/NAT, conectividade, falha induzida e recuperação por console fora de banda. Neste host, enquanto só o Wi-Fi tiver IPv4, a campanha cobre NAT; bridge exige Ethernet ativa.
- [ ] **I13.11:** restaurar backup em mídia/ambiente separado e validar o resultado; "backup criado" não basta.
- [ ] **I13.12:** depois de registrar baseline e capturar snapshots/fingerprints vinculados à operação, executar, em instalação ou clone descartável separado e quando operacionalmente possível, um cenário de falha controlada e comprovar o rollback antes do caminho feliz de boot, libvirt, hooks, rede, Airlock e storage. Nunca invocar rollback sem estado `PREPARED` e snapshot pertencente à mesma operação. Quando essa ordem não for possível, registrar a razão e o controle alternativo antes de prosseguir.
- [ ] **I13.13:** registrar logs redigidos conforme a seção 3.9, evidências, toda intervenção manual e limitações; dados brutos de recuperação seguem a política local `0600`, diagnóstico usa apenas `recovery_id` e nada bruto é publicado.

**Aceite:** apenas a combinação exata testada pode ser marcada como qualificada. Ubuntu qualificado não implica Pop!_OS qualificado, nem vice-versa.

## I14: Providers de novas distribuições (fora do escopo mínimo Ubuntu)

Só começa após o marco `BASE_QUALIFICADA` (I0 a I13 completos, com as campanhas Ubuntu e Pop!_OS de I13 concluídas separadamente). Antes da primeira mudança, o usuário deve aprovar uma lista ordenada contendo **Debian, Fedora Workstation, Arch Linux, CachyOS e openSUSE Tumbleweed**; apenas um target ativo por vez; o próximo só começa após código, testes, documentação e campanha real do anterior. Preferir estabilizar APT/Pacman antes de DNF/zypper. Os comandos candidatos por distro estão em `commands-list/*.md` e não contam como provider nem como suporte.

Contrato mínimo de qualquer provider (capabilities explícitas e recusa de função ausente): 1) pacotes/repositórios; 2) cmdline/bootloader/initramfs; 3) backend libvirt e usuário QEMU; 4) driver NVIDIA compatível; 5) OVMF/UEFI; 6) AppArmor/SELinux; 7) bridge/rede e rollback; 8) UFW/firewalld; 9) reboot, pós-condições e rollback; 10) fixtures usando a biblioteca/provider real, instalação descartável e campanha operacional. Cada distro mutável repete **integralmente I13.1 a I13.13**.

### Valores de perfil pesquisados por distribuição (23/08/2026)

Estes valores são **ponto de partida pesquisado**, não fato qualificado. Cada um precisa ser reconfirmado no host real da campanha, e em rolling release a validade tem prazo (trava T13). Os atributos são os do bloco `case "$PLATAFORMA_ID"` de `lib/platform.sh`.

| Atributo | Debian | Fedora Workstation | Arch / CachyOS | openSUSE Tumbleweed |
|---|---|---|---|---|
| `PLATAFORMA_PERFIL` | `debian` | `fedora` | `arch` / `cachyos` | `opensuse-tumbleweed` |
| `PLATAFORMA_GERENCIADOR_PACOTES` | `apt` | `dnf` | `pacman` | `zypper` |
| `PLATAFORMA_QEMU_PACOTE` | `qemu-system-x86` | `qemu-kvm` | `qemu-desktop` ou `qemu-full` | **`qemu-x86`** |
| `PLATAFORMA_QEMU_COMANDO` | `qemu-system-x86_64` | `qemu-system-x86_64` | `qemu-system-x86_64` | `qemu-system-x86_64` |
| `PLATAFORMA_QEMU_USUARIO_PADRAO` | `libvirt-qemu` | `qemu` | confirmar (`nobody` é o padrão histórico do Arch) | `qemu` |
| `PLATAFORMA_QEMU_USUARIOS` | `libvirt-qemu qemu` | `qemu` | confirmar | **`qemu`** apenas |
| `PLATAFORMA_NVIDIA_ESTRATEGIA` | `debian-nvidia-driver` | RPMFusion `akmod-nvidia` ou repo CUDA, escolha explícita | `nvidia-dkms`, `nvidia` ou `nvidia-open` | `opensuse-repos-nvidia` |
| `PLATAFORMA_BOOT_BACKENDS` | `grub` | BLS via `grubby` | **detectar** GRUB ou systemd-boot; CachyOS acrescenta Limine | `grub2-suse` via `LOADER_TYPE` |
| `PLATAFORMA_INITRAMFS_BACKEND` | `update-initramfs` | `dracut` | **detectar** `mkinitcpio` ou `dracut` | `dracut` |
| `PLATAFORMA_LIBVIRT_SERVICOS` | `libvirtd virtqemud` | modular | confirmar | `virtqemud libvirtd` |
| `PLATAFORMA_LIBVIRT_GRUPO` / `KVM_GRUPO` | `libvirt` / `kvm` | `libvirt` / `kvm` | confirmar | `libvirt` / `kvm` |
| Diretório OVMF | `/usr/share/OVMF/OVMF_CODE_4M.fd` | `/usr/share/edk2/ovmf/` | pacote `edk2-ovmf` | `/usr/share/qemu/ovmf-x86_64-*.bin` |
| Backend de rede | `systemd-networkd` (decisão de projeto) | NetworkManager (`nmcli`) | detectar networkd ou NM | **`networkmanager` ou `wicked`** |
| Firewall | `ufw` (não é o padrão; nftables é) | `firewalld` | nenhum por padrão | `firewalld` |
| LSM | AppArmor | **SELinux enforcing** | AppArmor opcional | **SELinux enforcing por padrão** desde o snapshot 20250211 |

**Correção normativa:** a linha de I14.5 abaixo dizia "AppArmor" para openSUSE. Desde o snapshot 20250211 o instalador do Tumbleweed entrega **SELinux enforcing** como padrão em instalações novas, com AppArmor disponível por escolha manual e mantido em instalações antigas. O LSM do openSUSE é resolvido em **runtime**, nunca constante de perfil.

### Armadilhas específicas por alvo, já pesquisadas

**Debian:** `qemu-kvm` **não existe** (o valor do perfil Pop!_OS é inutilizável); não há `ubuntu-drivers` nem `system76-driver-nvidia`, o driver vem de `nvidia-driver` em `non-free`, exigindo os componentes `contrib non-free non-free-firmware`, e a instalação padrão do trixie habilita apenas `main` e `non-free-firmware`; não existe `OVMF_CODE.fd` sem sufixo; o Debian **não tem netplan** e não tem backend de rede único, então escolher `systemd-networkd` é decisão de projeto que precisa ser declarada como tal; `ufw` existe em `main` mas não vem instalado, e o framework padrão desde o Debian 10 é nftables.

**Fedora Workstation:** DNF5 é o padrão desde o Fedora 41 e `groupinstall` foi **removido**, então emitir `dnf groupinstall` quebra por sintaxe; o `dracut` roda com `hostonly=yes` por padrão, razão pela qual `add_drivers` sozinho pode não bastar e a verificação precisa ser por `lsinitrd -k <kver> | grep vfio`, **nunca** pelo código de saída do `dracut`; a cmdline mora em BLS, manipulada por `grubby`, não em `grub.cfg`; SELinux precisa permanecer **enforcing**, e `setenforce 0` não conta como suporte; preferir a autosseleção de firmware do libvirt aos caminhos fixos de OVMF.

**Arch e CachyOS:** o pacote `ovmf` **não existe**, é `edk2-ovmf`; `mkinitcpio` e `dracut` ambos declaram `provides=initramfs` e podem coexistir, então a detecção precisa de desempate ou recusa dura; o hook `modconf` do mkinitcpio só importa se o projeto passar a usar `options`/`softdep`, e hoje ele usa `/etc/modules-load.d/vfio.conf`, lido pelo `systemd-modules-load` já no sistema real; CachyOS tem dez variantes de kernel (`linux-cachyos` EEVDF é o padrão, mais `-bore`, `-bmq`, `-eevdf`, `-hardened`, `-lts`, `-rc`, `-rt-bore`, `-server`, `-deckify`) com headers em `<pkgbase>-headers` e repositórios `cachyos-v3`/`cachyos-v4`, e o hook `limine-mkinitcpio` depende de `mkinitcpio` e reescreve as entradas por `limine-entry-tool`; adicionar `systemd-boot` ou `limine` esbarra na trava T4.

**openSUSE Tumbleweed:** `qemu-kvm` **não existe** no OSS (existem `qemu`, `qemu-x86` e `qemu-tools`); `mkinitrd` **não está** no OSS e o comando canônico é `dracut --regenerate-all --force`; `swtpm-tools` **não existe** como pacote separado, os utilitários vêm no próprio `swtpm`; a unidade do sshd é `sshd.service` sem alias `ssh.service` (trava T7); os códigos de saída 100 a 107 do `zypper` abortam sob `set -euo pipefail` (trava T8); existe a divisão `/usr/etc` versus `/etc` (trava T9); `update-bootloader --config` pode sair com zero sem regenerar nada (REQ-BOOT-POSCONDICAO); e o Snapper com raiz Btrfs é uma **oportunidade real** de rollback de sistema, desde que a existência da raiz Btrfs e da config `root` seja comprovada e a ausência bloqueie a etapa em vez de degradar em silêncio.

Requisitos específicos por target:

- [ ] **I14.1 Debian:** APT/repositórios Debian, GRUB/update-initramfs, networkd ou backend explícito, NVIDIA sem `ubuntu-drivers`, libvirt/QEMU/AppArmor/OVMF/firewall comprovados.
- [ ] **I14.2 Fedora Workstation:** DNF, dracut+BLS, NetworkManager, firewalld e repositório NVIDIA explicitamente escolhido; SELinux deve permanecer enforcing, com contextos, relabel persistente e políticas/booleans estritamente necessários, testes positivo/negativo e rollback. `setenforce 0` não conta como suporte.
- [ ] **I14.3 Arch Linux:** Pacman, mkinitcpio ou dracut detectado, GRUB ou systemd-boot detectado, rede/firewall/libvirt/QEMU/OVMF/NVIDIA.
- [ ] **I14.4 CachyOS:** tudo de Arch mais kernels/headers próprios, Limine, compatibilidade NVIDIA/kernel/initramfs.
- [ ] **I14.5 openSUSE Tumbleweed:** `zypper dup`, natureza rolling release, dracut, update-bootloader, NetworkManager ou Wicked com rollback, firewalld, **SELinux enforcing** (padrão do instalador desde o snapshot 20250211; AppArmor apenas em instalação antiga ou escolha manual, resolvido em runtime e nunca constante de perfil), libvirt/OVMF/NVIDIA por snapshot qualificado.
- [ ] **I14.6 Fedora Silverblue:** manter diagnóstico ostree/imutabilidade; recusar todo mutador antes de `sudo`; testar menu, execução direta e bibliotecas com conteúdo/metadados/mtimes invariantes. Não implementar mutação tradicional.

**Aceite individual:** dez domínios completos, capabilities, fixtures reais, instalação descartável, matriz exata e repetição aprovada de I13.1 a I13.13 para a combinação. Só então remover `PLANEJADO` daquele target.
**Aceite de I14/plano integral:** os cinco providers mutáveis possuem evidência própria e I14.6 está aprovado; somente então registrar `EXPANSAO_TOTAL_QUALIFICADA`.

## I14B: Eixo CPU Intel

**Pré-condição:** `BASE_QUALIFICADA`, mais as tarefas I8.7 e I8.9 aprovadas. Alvo da trilha de expansão; **um alvo por vez**. Cumpre integralmente REQ-CPU-VENDOR e a seção 4.0.

**Custo relativo: o mais baixo dos oito alvos.** A troca de fabricante é mecânica e concentrada; o que custa é a topologia híbrida.

| AMD | Intel | Onde |
|---|---|---|
| `amd_iommu=on iommu=pt` | `intel_iommu=on iommu=pt` | `lib/shell/boot.sh:696` |
| chave derivada `amd_iommu` | chave derivada `intel_iommu`, **automática** | `boot_params_chaves`, `lib/shell/boot.sh:700` |
| flag `svm` | flag `vmx` | `etapas/01-verificar-bios.sh:16` e `:74` |
| prefixo `AMD-Vi:` | prefixo `DMAR:` | `etapas/30-iommu-vfio.sh:191`, `util/atualizar-host.sh:113`, `etapas/01-verificar-bios.sh:89` |
| módulo `kvm_amd` (`npt`, `avic`) | módulo `kvm_intel` (`ept`, `unrestricted_guest`, `enable_apicv`, `vpid`) | diagnóstico apenas, nunca condição de mutação |
| firmware: "SVM Mode" | firmware: "Intel VT-x" **e** "VT-d", tipicamente em menus separados | `etapas/01-verificar-bios.sh` |
| sem bloqueio por firmware | **RMRR** pode tornar o dispositivo inelegível | modo de falha exclusivo do caminho Intel |
| topologia uniforme | **híbrida P-core/E-core** a partir de Alder Lake | `libexec/passthrough_core/cpu.py` |

Notas de exatidão: `amd_iommu` oficialmente **não tem** valor `on` (o driver liga sozinho pelo IVRS do firmware); o projeto usa `amd_iommu=on` como marcador determinístico e isso continua correto. `iommu=pt` é arquitetural x86 e **não** muda por fabricante. Em Intel, `CONFIG_INTEL_IOMMU_DEFAULT_ON=y` torna `intel_iommu=on` redundante na prática, mas o projeto exige exatidão literal na cmdline, então permanece obrigatório como marcador.

### Tarefas

- [ ] **I14B.1:** substituir `plataforma_validar_cpu_amd` por `plataforma_validar_cpu_suportada`, resolvendo por nível de suporte do eixo, não por igualdade literal a `AuthenticAMD`. Manter o nome antigo apenas como alias durante o cutover, removido no fim da fase. Ponto único: `lib/platform.sh:723`, consumido por `lib/common.sh:208` e por `etapas/30-iommu-vfio.sh:28` e `:99`.
- [ ] **I14B.2:** esvaziar `IOMMU_PARAMS_PADRAO` no `source` (`lib/shell/boot.sh:696`) e passar a preenchê-lo pelo perfil de CPU. Todo consumidor recusa com diagnóstico próprio quando o valor está vazio, incluindo `boot_estado_iommu` (`:720`) e `iommu_vfio_transacao` (`:1028`), **antes** do primeiro snapshot. Isso torna estruturalmente impossível aplicar parâmetro de um fabricante em host do outro por omissão de código.
- [ ] **I14B.3:** tornar prefixo de dmesg, flag de virtualização e evidência positiva atributos de perfil. Evidência Intel reconhecível: `IOMMU enabled` e `Intel(R) Virtualization Technology for Directed I/O`. Não reaproveitar regex de evidência negativa AMD em host Intel: isso bloquearia host Intel saudável.
- [ ] **I14B.4:** implementar a detecção de tipo de core em `cpu.py` pela fonte autoritativa `/sys/devices/cpu_core/cpus` e `/sys/devices/cpu_atom/cpus`, capturada pelo Bash e entregue por payload. **Não** existe `/sys/devices/system/cpu/types` neste kernel, e `X86_FEATURE_HYBRID_CPU` **não tem string** em `/proc/cpuinfo`, portanto detecção por `grep` em flags é impossível. A coluna `CLUSTER` do `lscpu` é sinal auxiliar plausível, jamais fonte autoritativa. Evidência ausente, parcial ou conflitante produz estado tipado e **recusa**, nunca default.
- [ ] **I14B.5:** acrescentar `types_fingerprint` separado do `canonical_text` (`cpu.py:174`), **vazio em host uniforme**, de forma a não mover nenhum valor já validado em AMD. Sem isso, duas topologias híbridas com tipos trocados produzem o mesmo hash.
- [ ] **I14B.6:** fechar a janela silenciosa de SMT desligado descrita em REQ-CPU-VENDOR. `_plan_pinning` passa a exigir que o conjunto entregue à VM seja de **tipo único**, e o laço ordinal de `cpu.py:519` deixa de ser ordinal em host híbrido. Este é o item central da fase e o teste obrigatório é **híbrida com SMT desligado**.
- [ ] **I14B.7:** estender o isolamento (`isolcpus`, `nohz_full`, `rcu_nocbs`) para híbrida: a sintaxe **não muda**, a política muda. O conjunto isolado precisa ser de tipo único e o housekeeping precisa reter core do tipo alvo. Cobre `etapas/53-cpu-isolation.sh` e `etapas/52-cpu-pinning-hugepages.sh`.
- [ ] **I14B.8:** cobrir `etapas/02-detectar-config.sh`, onde o plano de CPU nasce (trava T5). Detecção, pergunta ao operador, reconciliação e persistência precisam conhecer o eixo e o tipo de core.
- [ ] **I14B.9:** tratar RMRR como diagnóstico próprio. Mensagem exata do kernel: `Device is ineligible for IOMMU domain attach due to platform RMRR requirement`. Aparece apenas no bind ou no start da VM, então precisa de pós-condição própria e mensagem acionável, nunca erro genérico.
- [ ] **I14B.10:** manter `intel_iommu=igfx_off` **fora** do padrão, com recusa explícita e justificativa registrada, porque reduz isolamento.
- [ ] **I14B.11:** reexecutar integralmente a suíte e a campanha I0 `full` em host AMD, provando byte a byte que o suporte existente não regrediu.
- [ ] **I14B.12:** repetir integralmente I13.1 a I13.13 em host Intel real, incluindo os dois reboots. Sem isso o eixo permanece `PLANEJADO`.

### Gate I14B

Eixo formalizado e recusando por padrão; AMD idêntico byte a byte; parâmetro vazio recusado em todo consumidor; tipo de core detectado pela fonte autoritativa; **híbrida com SMT desligado recusa em vez de pinar em E-cores**; `types_fingerprint` vazio em host uniforme; RMRR com diagnóstico próprio; `igfx_off` fora do padrão; campanha real registrada ou eixo permanece `PLANEJADO`.

## I14C: Eixo GPU AMD

**Pré-condição:** `BASE_QUALIFICADA`, mais a tarefa I8.8 aprovada. Alvo da trilha de expansão. Cumpre integralmente REQ-GPU-VENDOR e a seção 4.0.

**Custo relativo: alto.** Não é troca de nome de driver: o ciclo de vida do dispositivo é diferente, e o reset bug é um bloqueio de segurança operacional, não uma ressalva de rodapé.

### Tarefas

- [ ] **I14C.1:** criar o eixo de GPU em `lib/platform.sh` espelhando o eixo de CPU, com vendor PCI (`0x10de` NVIDIA, `0x1002` AMD, `0x8086` Intel) resolvido a partir de snapshot capturado pelo Bash, e acrescentar a guarda correspondente em `guard_mutation` (`lib/common.sh`, na cadeia da linha 208), que hoje **não tem** eixo de GPU.
- [~] **I14C.2:** renomear `nvidia.driver` para `gpu.driver` em `PLATAFORMA_CAPABILITIES_CONHECIDAS` (que tem **21** entradas, não 22), mantendo `nvidia.driver` como alias aceito durante o cutover e removido em I10. Revisar também `guest.driver` e `gpu.recover`, que são as outras duas capabilities do eixo. **A renomeação em si foi feita em I8.8 (2026-08-28)**, porque a tarefa I8.8 a exige nominalmente e mantê-la aberta aqui duplicaria o cutover: `gpu.driver` já é o canônico, `nvidia.driver` já é alias aceito, o array continua com 21 entradas e `lib/platform.sh`, `etapas/11-driver-nvidia.sh`, `menu.sh` e `tests/i1/mutators.tsv` foram atualizados juntos. Resta aqui apenas a revisão de `guest.driver` e `gpu.recover` sob o eixo, que depende de GPU AMD real.
- [ ] **I14C.3:** acrescentar ao `SCHEMA` de `libexec/passthrough_core/config.py` toda chave nova de configuração desta fase, com classe de dado conforme a seção 3.9. Chave sem entrada no schema é recusada pelo parser, então esta tarefa **precede** qualquer uso.
- [ ] **I14C.4:** implementar o caminho de liberação AMD sem `modprobe -r`. O laço de quatro módulos de `etapas/50-hooks-gpu-hd1.sh:511` é específico de NVIDIA. Em AMD: parar o display manager, esperar os nós DRM e deixar o unbind por dispositivo com `managed='yes'`. Justificativa registrada: em APU o mesmo `amdgpu` dirige iGPU e dGPU.
- [ ] **I14C.5:** implementar a prova de saúde AMD por sysfs, já que não há equivalente a `nvidia-smi` instalado por padrão: driver `amdgpu` ligado ao BDF, nó DRM em `/sys/bus/pci/devices/BDF/drm/card*` e `power_state` igual a `D0`. Substitui `etapas/50-hooks-gpu-hd1.sh:813` e `util/recuperar-gpu.sh:196` por caminho resolvido pelo eixo.
- [ ] **I14C.6:** implementar a **classificação de reset** por leitura de `/sys/bus/pci/devices/BDF/reset_method` (kernel 5.15 ou superior), com os estados `funcional`, `quebrado`, `coberto-por-vendor-reset` e `desconhecido`, conforme a tabela de famílias de REQ-GPU-VENDOR. Classificação diferente de `funcional` **impede** a promessa de retorno da GPU e exige aceite explícito do operador antes de qualquer entrega. O projeto apenas lê o arquivo; escrever é mutação de host e fica fora desta frente.
- [ ] **I14C.7:** recusar iGPU de APU AMD antes de qualquer efeito, com diagnóstico próprio: compartilha grupo IOMMU com o complexo raiz, não tem ROM própria e dirige o console do host.
- [ ] **I14C.8:** tratar `romfile` de vBIOS como caminho de primeira classe, não exceção. A necessidade é **mais frequente** em AMD quando a placa é a GPU de boot, que é exatamente o cenário deste projeto. Documentar que o dump só é confiável com a placa não inicializada pelo firmware.
- [ ] **I14C.9:** emitir o vendor nos hooks de entrega e retomada (`gerar_start` e `gerar_release` de `etapas/50-hooks-gpu-hd1.sh`), de forma que o hook gerado seja autossuficiente e não redescubra o fabricante em tempo de execução.
- [ ] **I14C.10:** tratar o driver do convidado. NVIDIA usa instalador com `setup.exe -s -noreboot` e catálogo público consultável (`libexec/passthrough_core/nvidia_lookup.py`); a AMD **não tem catálogo público consultável** e o Adrenalin é auto-extrator, invocado por `Setup.exe -INSTALL`. **Não** usar `-BOOT`, que reinicia o convidado. Se a instalação não interativa não se provar confiável, converter a etapa 16 em passo **manual documentado** para AMD, em vez de prometer automação não qualificável.
- [ ] **I14C.11:** decidir por teste se o convidado AMD precisa de `hyperv vendor_id` e de estado oculto, dado que os drivers de vídeo AMD fazem detecção rudimentar de máquina virtual. Registrar a decisão com evidência; não copiar a configuração NVIDIA por analogia.
- [ ] **I14C.12:** reexecutar integralmente a suíte e a campanha I0 `full` em host NVIDIA, provando que o fabricante existente não regrediu, e acrescentar `tests/manifests/i14c-files.txt`.
- [ ] **I14C.13:** repetir integralmente I13.1 a I13.13 em host com GPU Radeon real, com **ciclo duplo** de entrega e retomada. Sem isso o eixo permanece `PLANEJADO`.

### Gate I14C

Eixo formalizado e presente em `guard_mutation`; NVIDIA idêntico byte a byte; nenhum `modprobe -r` no caminho AMD; saúde provada por sysfs; **reset classificado antes de qualquer promessa de retorno**; APU recusada antes de efeito; schema de config completo; hooks emitem o vendor; driver do convidado automatizado com prova ou convertido em passo manual documentado; campanha real com ciclo duplo registrada ou eixo permanece `PLANEJADO`.

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

| REQ-I18N | catálogo en/pt-BR/es sem mudar comportamento | I9B | paridade de chaves, catálogo hostil inerte, suíte em 3 idiomas | revisão humana de tradução |
| REQ-CPU-VENDOR | eixo de CPU e topologia híbrida | I8 (modelo)/I14B | fixtures de vendor e de tipo de core, SMT desligado | host Intel real I14B |
| REQ-GPU-VENDOR | eixo de GPU e prova de retorno | I8 (modelo)/I14C | fixtures de vendor, reset_method, APU recusada | GPU Radeon real I14C |
| REQ-BOOT-POSCONDICAO | aplicador prova que regenerou | I9 | aplicador zero-sem-efeito, fonte restaurada com artefato divergente | bootloaders reais I13/I14 |

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

### 11.4 Novo eixo de hardware completo

Um eixo de hardware (fabricante de CPU ou de GPU) só sai de `PLANEJADO` quando, para a **combinação exata testada**:

- o eixo está formalizado conforme a seção 3.11, com fato tipado, motivo próprio de recusa e capability rebaixada quando incompatível;
- todo parâmetro, módulo, caminho de `/sys` e atributo de XML específico do fabricante é resolvido por perfil, nunca por literal espalhado;
- o fabricante anterior continua passando integralmente, provado por reexecução da suíte e da campanha I0 `full`;
- as fixtures cobrem o fabricante novo, o antigo, ausência, desconhecido e conflito de evidência;
- a campanha de I13.1 a I13.13 foi repetida **integralmente** em hardware real com esse fabricante, incluindo os dois reboots e o ciclo completo de entrega e retorno do dispositivo;
- o registro nomeia CPU/GPU exata, kernel, firmware, versão de driver e limitações conhecidas.

Fixture aprovada, parser que reconhece o vendor e código presente **não** qualificam. Um eixo implementado e não qualificado permanece recusado por padrão e é reportado como tal, exatamente como `debian` e `arch` são hoje no eixo de distribuição.

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
| Auditoria | 2026-08-23 | `2b10ae7` + working tree | nenhum arquivo de produção alterado | verificação por leitura de `etapas/51-usb-passthrough.sh:411`, `etapas/61-airlock.sh:230-296` e `:565`, `libexec/passthrough_core/domain_xml.py:582`, `lib/common.sh:2393/:2430/:3199`, busca por consumidores de `windows-install`, busca por `recovery_id`, existência de `platform.py`/`check-python-boundary.py`/`check-plan-traceability.py`, conferência da tabela de numeração contra `menu.sh`; contagem de saída humana (1783) e de `assert_text` (46, sendo 12 em PT) | I0-I5 CONFIRMADAS; I6-I14 CONFIRMADAS ABERTAS; plano **não** defasado no essencial; 2 pontos defasados corrigidos (REQ-IOMMU-TX na seção 16 e README na seção 1.4) | 27 commits entre 18/08 e 23/08 alteraram toda a árvore sem linha no registro; **o Gate I5 deixou de valer como baseline** | seção 1.5 | executar I6.0 antes de I6.1 |
| I6.0 (tentativa 1) | 2026-08-23 | `ea36127` + working tree | `.gitignore`, `.kiro/**/*.md` | `bash tests/run-gate-i1.sh` | **REPROVADO (rc=1), antes dos testes** | a atualização documental obrigatória tornou 26 arquivos Kiro rastreáveis e o manifesto cumulativo os recusou como untracked; não era regressão de produção | saída da sessão | criar manifesto documental explícito, sem voltar a ignorar `.kiro/` |
| I6.0 (tentativa 2) | 2026-08-23 | `ea36127` + working tree | `tests/run-gate-i1.sh`, `tests/manifests/i6-docs-files.txt` | `bash tests/run-gate-i1.sh` | **REPROVADO (rc=1)** | regressão preexistente confirmada: `etapas/55-driver-nvidia-vm.sh` usava `guest.driver`, mas faltava em `tests/i1/mutators.tsv`; as posições 16–21 do menu também estavam defasadas | saída da sessão | representar a etapa 55 e realinhar a matriz do menu |
| I6.0 | 2026-08-23 | `ea36127` + working tree | `.gitignore`, `.kiro/**/*.md`, `tests/manifests/i6-docs-files.txt`, `tests/run-gate-i1.sh`, `tests/i1/mutators.tsv`, este plano | gate canônico aprovado: manifesto com 113 arquivos; envelope I1 com 30 mutadores diretos e 23 seleções de menu em 6 perfis, duas vezes; validação atualizar-host em 29 cenários; campanha I0 integral com 42 grupos; 13 testes shell de regressão; core Python com 517 casos; `bash -n` em 54 arquivos; `compileall` em 2 árvores e `py_compile` em 28 arquivos; whitespace em 27 untracked; campanha I0 `full` repetida explicitamente, 42 grupos | **APROVADO (rc=0)** | ShellCheck ausente localmente, mas permanece obrigatório na CI; nenhuma operação de host/hardware foi executada | saída integral da sessão e gate canônico | iniciar I6.1 |

| I6 | 2026-08-23 | `ea36127` + working tree | `libexec/passthrough_core/inventory.py`, ponte/CLI, etapas 1/3/14/15/16, fixtures e testes I6, manifestos, este plano | `bash tests/test-i6-inventory.sh`; core Python com 546 casos; gate cumulativo aprovado e posteriormente reconfirmado no checkpoint I7.1 | **APROVADO** | probes e efeitos permaneceram em Bash; aliases físicos/USB ambíguos falham fechados; nenhuma validação de hardware real foi promovida | `.kiro/specs/repository-finalization/tasks.md`, saída das sessões e gate canônico | I7 liberada |
| I7.1 | 2026-08-24 | `ea36127` + working tree | `libexec/passthrough_core/network.py`, `tests/manifests/i7-files.txt`, `tests/run-gate-i1.sh`, este plano | smoke hermético: ordem determinística, XML semanticamente equivalente, fingerprint exato distinto e schema fechado; `bash tests/test-python-core.sh` = 546 casos; manifesto I7 = 132 arquivos; `bash tests/run-gate-i1.sh` = rc 0, campanha I0 `full` com 42 grupos, `bash -n` em 55 arquivos, `compileall` em 2 árvores, `py_compile` em 32 arquivos e whitespace em 46 untracked | **CHECKPOINT APROVADO; Gate I7 final PENDENTE** | somente modelo puro de snapshot/intenção e fingerprints; I7.2–I7.7 continuam abertas; ShellCheck ausente localmente e obrigatório na CI; LSP indisponível por ausência de `pyright-langserver` | saída integral da sessão e gate canônico | executar I7.2 |
| Correção udev bloco/caractere (I6) | 2026-08-24 | `ea36127` + working tree | `libexec/passthrough_core/inventory.py`, `tests/python/test_inventory.py`, `etapas/51-usb-passthrough.sh`, `README.md`, `Guia-QEMU-Passthrough.md`, este plano | reprodução contra o banco udev real do host (`13d3:3563` e `056a:030e` recusados pelo core antes da correção; resolvidos por serial e por porta depois); `UdevNamespaceTests` confirmada reprovando contra o código do `HEAD`; `bash tests/test-python-core.sh` = 549 casos; `bash tests/test-i6-inventory.sh`; `python3 tests/check-python-boundary.py --root libexec`; `bash tests/run-gate-i1.sh` = rc 0 com manifesto I7 de 132 arquivos, campanha I0 `full` com 42 grupos, envelope I1 com 30 mutadores e 23 seleções em 6 perfis duas vezes, `bash -n` em 55 arquivos, `compileall` em 2 árvores e `py_compile` em 32 arquivos, whitespace em 0 untracked | **APROVADO (rc=0)** | `_parse_udev` tratava `MAJOR:MINOR` como chave única global, mas bloco e caractere numeram em namespaces independentes: os `loopN` do snapd (bloco, major 7) colidiam com os `/dev/vcsN` (caractere, major 7) e derrubavam com `DataError` toda a seleção USB por identidade da etapa 15 neste host, sem que nenhum teste cobrisse o caminho de texto udev do USB; ShellCheck ausente localmente; anexar o rádio Bluetooth à VM exige sudo interativo e ficou com o usuário | `scratchpad/gate.log`, saída da sessão | usuário: rodar `bash etapas/51-usb-passthrough.sh` (modo 1) para o Bluetooth integrado `13d3:3563` e migrar o hostdev legado do Wacom; executor: I7.2 |
| Visualização (paleta do core e listas) | 2026-08-25 | `e7b4755` + working tree | `libexec/passthrough_core/colors.py` (novo), `libexec/passthrough_core/cli.py`, `libexec/passthrough_core_cli.py`, `lib/common.sh`, `etapas/02-detectar-config.sh`, `etapas/51-usb-passthrough.sh`, `tests/python/test_errors.py`, `tests/manifests/i7-files.txt`, este plano | diagnóstico do core conferido nos dois emissores com e sem TTY; `bash tests/test-i6-inventory.sh`; `bash tests/test-python-core.sh` = 555 casos; `bash tests/run-gate-i1.sh` = rc 0 com manifesto I7 de 133 arquivos, campanha I0 `full` com 42 grupos, envelope I1 com 30 mutadores e 23 seleções em 6 perfis duas vezes, `bash -n` em 55 arquivos, `py_compile` em 33 arquivos | **APROVADO (rc=0)** | cor só existe com terminal: sem TTY, com `NO_COLOR` ou com `TERM=dumb` a linha de diagnóstico sai byte a byte igual à histórica, então nenhum oráculo precisou mudar; o bootstrap duplica os literais de cor pelo mesmo motivo que já duplica os códigos de saída; marcar os dispositivos já anexados exigia uma leitura do XML antes da escolha, e ela foi fundida com a pré-checagem de duplicidade para não deslocar os contadores de `dumpxml` do harness I6; ShellCheck ausente localmente | `scratchpad/gate3.log`, saída da sessão | executor: corrigir a pós-condição da transação USB (falso conflito em libvirt real) |
| Correção da pós-condição USB (I6) | 2026-08-25 | `384741c` + working tree | `etapas/51-usb-passthrough.sh`, `tests/test-i6-inventory.sh`, este plano | reprodução no hardware real (a adição do rádio Bluetooth `13d3:3563` publicou o efeito e foi reportada como CONFLITO); dois casos novos no harness I6, com o `virsh` falso ensinado a normalizar como o libvirt; `bash tests/test-i6-inventory.sh` = rc 1 contra o código do `HEAD` com a falha nomeada e rc 0 com a correção; `bash tests/run-gate-i1.sh` = rc 0 com manifesto I7 de 133 arquivos, campanha I0 `full` com 42 grupos, core Python com 555 casos, `bash -n` em 55 arquivos | **APROVADO (rc=0)** | a pós-condição exigia igualdade canônica total entre candidato e publicado, o que é inalcançável: ao publicar um hostdev USB o libvirt aloca `<address type='usb'>` e reposiciona o elemento, e a comparação preserva ordem de propósito, então TODA adição virava falso conflito com o efeito já aplicado e o rollback recusado; a prova passou a ser por redução dos dois lados pela mesma identidade, somada à checagem de que a identidade está no estado pedido; a comparação é contra o CANDIDATO e não contra o original, porque a adoção de hostdev legado (migração do Wacom) removeria do original um dispositivo preexistente; o bug sobreviveu porque o `define` do harness era um `cp` do candidato; ShellCheck ausente localmente | `scratchpad/gate4.log`, saída da sessão | usuário: migrar o hostdev legado do Wacom pela etapa 15; executor: I7.2 |
| Correção do laço udev da GPU (D-GPU-UDEV-LOOP) | 2026-08-26 | `b4e512d` + working tree | `etapas/50-hooks-gpu-hd1.sh`, `util/recuperar-gpu.sh`, `tests/test-gpu-udev-loop.sh` (novo), `tests/test-i0-mutators.sh`, `tests/lib/mutator-dispatch.py`, `tests/manifests/i7-files.txt`, `Guia-QEMU-Passthrough.md`, `troubleshooting.md`, este plano | reprodução no hardware real pelo journal dos boots afetados (`Nvlink Core is being initialized` = 1 nos boots sem VM contra 564/3580/1738 nos boots com VM; `udev-worker ... nvidia: Process` = 0 contra 1308/3579/1736), com o `hooks.log` registrando `GPU e desktop restaurados com pós-condições verificadas` às 23:13:34 e o host resetado às 23:15:19; `udevadm verify` no override derivado; `bash tests/test-gpu-udev-loop.sh` reprovando contra o código do `HEAD` na asserção do display manager e aprovando com a correção; `bash tests/run-gate-i1.sh` = rc 0 com manifesto I7 de 134 arquivos, campanha I0 `full` com 42 grupos, envelope I1 com 30 mutadores e 23 seleções em 6 perfis duas vezes, core Python com 555 casos, `bash -n` em 56 arquivos, `py_compile` em 33 arquivos e whitespace em 1 untracked | **APROVADO (rc=0)** | as regras da distro em `/usr/lib/udev/rules.d/71-nvidia.rules` rodam `modprobe` direto a cada evento `add`/`remove` em `/bus/pci/drivers/nvidia`; com a GPU no `vfio-pci` esse `modprobe` puxa o módulo `nvidia`, que não sonda a GPU e é descarregado, gerando outro evento no mesmo caminho: um laço que se realimenta, atravessa o `release` e derruba `nvidia_drm` com a sessão gráfica já aberta; o hook não tinha como perceber porque suas pós-condições eram amostras instantâneas, e o journal só guardava o hook que falha; o override é derivado byte a byte do arquivo da distro, então uma atualização do pacote NVIDIA vira divergência no `--verificar` em vez de silêncio, e só as seis regras de `modprobe` mudam; carregar continua permitido fora da janela vfio porque não existe `softdep` que dê `nvidia_drm modeset=1` ao host no boot; o `release` e o `util/recuperar-gpu.sh` passaram a exigir estabilidade por janela e a recusar subir o display manager sobre GPU instável, mas só quando a GPU chegou pronta, para não mudar o comportamento histórico do caso “GPU nunca voltou”; adotar um `71-nvidia.rules` de terceiros é recusado; duas tentativas foram reprovadas pelo gate antes desta: guardar o `install -d` nas duas funções de instalação apagava efeitos que o oráculo I0 caracteriza (revertido, e o desvio virou opt-in usado só pelo filtro, porque `/usr/local/sbin` é `root:staff` 2775 por política da distro), e decidir a origem das regras com teste embutido do shell mais `grep` fazia as duas leituras discordarem sob sandbox (agora só o `grep` decide, e `/usr/lib/udev/rules.d` e `/lib/udev/rules.d` entraram nas raízes lógicas do harness); os efeitos da etapa 50 foram de 23 para 25 pelo par `install` do diretório mais `mv` atômico do arquivo novo, o mesmo custo de qualquer hook gerenciado, e todo ponto fixado a partir do efeito 15 deslocou +2; ShellCheck ausente localmente | `scratchpad/gate2.log`, saída da sessão | usuário: rodar `bash etapas/02-detectar-config.sh --redetectar` (as impressões digitais I6 de disco estão ausentes e bloqueiam a etapa 14) e depois `bash etapas/50-hooks-gpu-hd1.sh` para publicar o filtro; executor: I7.2 |
| I7.2 | 2026-08-26 | `82b874f` + working tree | `libexec/passthrough_core/network.py`, `libexec/passthrough_core/cli.py`, `tests/python/test_network.py` (novo), `tests/python/test_cli_domain.py`, `tests/manifests/i7-files.txt`, este plano | baseline `bash tests/run-gate-i1.sh` = rc 0 antes da primeira mudança; `python3 -I -S -B tests/python/run_tests.py` = 687 casos (eram 555); `bash tests/test-python-core.sh`; `python3 -I -S -B tests/check-python-boundary.py`; oráculo de paridade Bash/Python com `diff` vazio em 38 linhas; `bash tests/run-gate-i1.sh` = rc 0 na primeira tentativa, manifesto I7 com 135 arquivos, campanha I0 `full` com 42 grupos, `bash -n` em 56 arquivos, `py_compile` em 34 arquivos, whitespace em 1 untracked | **APROVADO (rc=0)** | o modelo de I7.1 estava órfão e sem teste nenhum: `network.py` não era importado por produção nem por `tests/python/`, e isso foi fechado aqui com 132 casos novos; `routes[]` passou a exigir `type` e a aceitar `device` ausente, porque `scope`/`protocol` não separam `local` de `broadcast` e `unreachable/prohibit/blackhole/throw` não têm `dev` (não havia produtor do schema antigo); duas bordas do Bash são recusadas de propósito pelo core, ambas bug real: octeto com zero à esquerda (`192.168.010.1` é lido como octal pela glibc, `lib/common.sh:2145`) e prefixo com zero à esquerda (`/024` vira `/20` em `cidr_intervalo`, `lib/common.sh:2162`); `_ENTITY_NAME` continua em 128 contra 63 do Bash porque o snapshot também transporta redes e VMs de terceiros que o Bash nunca validou; ShellCheck ausente localmente | seção 12, saída do gate | executar I7.3 |
| I7.3 + I7.7 | 2026-08-26 | `26e68c8` + working tree | `libexec/passthrough_core/network.py` (1189 → 2909 linhas), `libexec/passthrough_core/cli.py`, `tests/python/fixtures_i7.py` (novo), `tests/python/test_network.py`, `tests/python/test_cli_domain.py`, `tests/manifests/i7-files.txt`, este plano | `python3 -I -S -B tests/python/run_tests.py` = 746 casos (eram 687); `bash tests/test-python-core.sh`; `python3 -I -S -B tests/check-python-boundary.py`; verificação independente do plano gerado pelas duas fixtures: 11 efeitos NAT e 10 bridge na ordem exata, as duas strings de rollback idênticas, nenhum token de ferramenta no plano e saída byte a byte igual em duas execuções; `bash tests/run-gate-i1.sh` = rc 0 com manifesto I7 de 136 arquivos, campanha I0 `full` com 42 grupos, `bash -n` em 56 arquivos, `py_compile` em 35 arquivos | **APROVADO (rc=0)** | nenhuma etapa foi tocada, então a matriz de efeitos do oráculo I0 continua intacta; a recusa de `D-NET-UNMANAGED-BRIDGE` está modelada no plano mas a etapa continua só avisando, e a auditoria achou um **segundo** ponto de tolerância além do já conhecido: `verificar()` também aprova a rede alheia em `etapas/60-rede-bridge.sh:669`, e os dois foram cobertos juntos em I7.6, não em I7.5 como esta linha previa; a VM alvo viaja em `target` e não em `consumers`, porque o modelo fechado de I7.1 exige que interface `network` referencie a rede do snapshot e a NIC ainda aponta para `default` antes da migração; precondição de Wi-Fi e unicidade da bridge libvirt entre redes de terceiros exigem estender o snapshot e ficaram para I7.4; a escolha automática de sub-rede continua sendo descoberta em Bash, não plano; ShellCheck ausente localmente | seção 12, saída do gate | executar I7.4 |
| I7.4 | 2026-08-26 | `101a29d` + working tree | `libexec/passthrough_core/network.py` (2921 → 3565 linhas), `libexec/passthrough_core/cli.py`, `tests/python/fixtures_i7.py`, `tests/python/test_network.py`, `tests/python/test_cli_domain.py`, este plano | `python3 -I -S -B tests/python/run_tests.py` = 812 casos (eram 746); `bash tests/test-python-core.sh`; `python3 -I -S -B tests/check-python-boundary.py`; oráculo executável de paridade rodando `domain_xml.interface_state` sobre o XML de cada domínio do inventário; verificação independente de que os planos continuam com 11 efeitos NAT e 10 bridge na ordem exata, rollback idêntico e nenhum token de ferramenta; `bash tests/run-gate-i1.sh` = rc 0 com manifesto I7 de 136 arquivos, campanha I0 `full` com 42 grupos, envelope I1 com 30 mutadores e 23 seleções em 6 perfis duas vezes | **APROVADO (rc=0)** | três divergências deliberadas contra `domain-interfaces`, todas testadas: macvtap sobre a bridge candidata passa a contar (o Bash ignora `source/@dev`, e destruir a rede remove a bridge sob a VM); rede homônima sem marcador conta na paridade mas não como nossa; rede de outro nome com o marcador exato é reportada e **não** bloqueia, para não inventar recusa sem caso congelado. Nenhuma decisão da etapa muda por causa disso, porque o Bash só chega à contagem depois de aprovar a propriedade. O planner de I7.3 já divergia do Bash em `direct` sem estar documentado; agora está. `P-LIBVIRT-BRIDGE-UNIQUE` existe só no NAT porque `validar_bridge_libvirt_disponivel` só é chamada em `configurar_nat` (`etapas/60-rede-bridge.sh:1422`). Precondições: NAT de 12 para 13, bridge de 10 para 11. ShellCheck ausente localmente | seção 12, saída do gate | executar I7.5 |
| I7.5 (parcial) | 2026-08-26 | `c8341c4` + working tree | `etapas/60-rede-bridge.sh` (+155/−27), `tests/test-i0-mutators.sh` (+36/−27), este plano | campanha da etapa 60 isolada = 24 grupos (igual ao baseline do `HEAD` limpo); injeção de falha em cada um dos 11+10 efeitos com manifesto idêntico e nenhum `ROLLBACK INCOMPLETO` espúrio; recusa da confirmação = rc 1, **0 efeitos** e manifesto `exact` idêntico inclusive nos mtimes; dois cenários fora da campanha congelada exercitando `TX_NETPLAN_EXISTIA=1` e `TX_REDE_EXISTIA=1`; `python3 -I -S -B tests/python/run_tests.py` = 812 casos; `bash tests/run-gate-i1.sh` = rc 0 com campanha I0 `full` de 42 grupos | **APROVADO (rc=0), subetapa PARCIAL** | **bloqueio real de transporte:** `network-plan`, `network-route-audit` e `network-consumers` exigem payload aninhado com listas, bool e int, mas o canal de pares entrega `dict[str, str]` (`protocol.py:198-245`) com teto de 256 pares (`protocol.py:42`), e o Bash não constrói JSON por propriedade declarada do projeto (seção 3.8). Além disso `normalize_snapshot` e `snapshot_fingerprints` não têm subcomando no CLI. Sem isso, revalidar fingerprints exigiria uma tabela de expectativa por mutação escrita em Bash, ou seja, reimplementar o planner e criar o segundo caminho mutante que a regra 8 proíbe, então `D-NET-CONCURRENCY` **não** foi implementado e o oráculo de concorrência **não** foi invertido. Dois oráculos foram invertidos com comentário `I7.5:` citando literalmente o anterior: o de rollback divergente e o stdin do harness (`NAT_INPUT` deixou de ser vazio por causa da confirmação nova). As duas asserções de I7.6 (`TMP_DIR` vazio e ausência de `recovery_id=`) seguem intactas e passando. Nenhuma linha do harness precisou ser estendida: o único probe novo já era modelado. ShellCheck ausente localmente | seção 12, saída do gate | destravar o transporte e concluir I7.5 |
| I7.5 (transporte) | 2026-08-26 | `54da1ec` + working tree | `libexec/passthrough_core/network.py` (+834 linhas), `libexec/passthrough_core/cli.py`, `tests/python/fixtures_i7.py`, `tests/python/test_network.py`, `tests/python/test_cli_domain.py`, este plano | `python3 -I -S -B tests/python/run_tests.py` = 871 casos (eram 812); `bash tests/test-python-core.sh`; `python3 -I -S -B tests/check-python-boundary.py`; verificação independente de que o plano montado a partir de pares é byte a byte igual ao montado da estrutura aninhada nos dois modos, com 67 pares no NAT e 68 no bridge, 11/10 efeitos e rollback idênticos; prova fim a fim pela ponte real (`network-snapshot` com 21 pares devolveu o mesmo digest do caminho Python puro); `bash tests/run-gate-i1.sh` = rc 0 | **APROVADO (rc=0)** | o bloqueio da linha anterior era falta de adaptador, não impedimento arquitetural: o projeto já transportava coleção pelo canal de pares como item separado por nova linha, documentado em `domain_xml.py:144-158` e usado por `bridge_names`. A convenção foi estendida para registro de vários campos separados por TAB, com blob (XML e conteúdo de arquivo) sempre em par próprio indexado, porque blob pode conter TAB e nova linha. Nenhum normalizador foi afrouxado e `MAX_REQUEST_PAIRS` continua 256, com folga medida até 46 VMs consumidoras e teste prendendo a contagem para a conta não envelhecer calada. `lib/python-core.sh` não precisou mudar: `python_core_pares_payload` já servia. `network-fingerprints` virou `network-revalidate`, subcomando separado, porque comparar exige uma segunda entrada e responde outra pergunta; embutir criaria schema meio-aberto | seção 12, saída do gate | fiar a etapa 19 ao plano |
| I7.5 (fiação) | 2026-08-27 | `3a1958b` + working tree | `etapas/60-rede-bridge.sh` (1686 → 2839 linhas), `tests/lib/mutator-dispatch.py` (só `handle_ip`), `tests/test-i0-mutators.sh` (só o cenário de concorrência), este plano | campanha isolada da etapa 60 = 24 grupos; matriz de falha com 21 injeções (11 NAT + 10 bridge) com manifesto idêntico e sem falso commit; segunda execução = 7 e 6 efeitos, todos `custom:config-publish`, manifesto `exact` idêntico; `python3 -I -S -B tests/python/run_tests.py` = 871 casos; **gate canônico reexecutado por mim, não só pelo agente**: `bash tests/run-gate-i1.sh` = rc 0, manifesto I7 com 136 arquivos, campanha I0 `full` com 42 grupos, envelope I1 com 30 mutadores e 23 seleções em 6 perfis duas vezes, 871 casos no core, `bash -n` em 56 arquivos, `py_compile` em 35 arquivos, whitespace em 0 untracked | **APROVADO (rc=0)** | contrato de efeitos preservado sem exceção: 11 NAT e 10 bridge na ordem exata e as duas strings de rollback idênticas. Um oráculo invertido, o de concorrência, com comentário `I7.5:` citando literalmente o texto anterior. Leitura de projeto registrada: `revalidate` é usado como **conjunto autorizado a mudar**, e o provider compara o complemento dentro da superfície do plano; comparar só os listados nunca acusaria nada, porque entre duas observações a única mudança esperada é a nossa. A expansão de autorização (`links` ⊃ `bridge`; `libvirt_network` ⊃ `links`/`routes`/`bridge`) é conhecimento de provider, sem o qual `netplan apply` e `virsh net-start` gerariam falso conflito em host real. **Custo medido:** a etapa passou de ~3,5 s para ~11 s no harness (5 observações numa execução NAT), a campanha `full` de ~10 para ~28 min e o gate para ~40 min; orçamento formal de desempenho continua sendo I10.4. **Dívida deixada explícita para I7.6:** no modo bridge, rede homônima sem marcador é declarada como slot gerenciado ausente para preservar o oráculo atual, então `D-NET-UNMANAGED-BRIDGE` precisa remover essa exclusão na captura **e** a tolerância em `verificar()`. **Lacuna do modelo de I7.1:** VM presa por `<source bridge='virbr-vmnat'>` não é representável, porque `_validate_relations` só admite fonte `bridge` na bridge do host; o provider recusa fail-closed nomeando a VM, e fechar isso exige mexer no schema. ShellCheck ausente localmente | seção 12, `scratchpad/gate-i75-final.log` | executar I7.6 |
| I7.6 | 2026-08-27 | `f9a048f` + working tree | `etapas/60-rede-bridge.sh` (2839 → 3164 linhas), `tests/test-i0-mutators.sh` (1207 → 1675 linhas), `tests/lib/mutator-harness.sh` (+6), `libexec/passthrough_core/network.py` e `tests/python/test_network.py` (só comentário), este plano | campanha isolada da matriz de rollback com 51 execuções da etapa 60 = 6 grupos em 16m33s; 40 injeções `before`/`after` em 20 posições de passo cobrindo os 11 verbos de rollback; 6 execuções de sinal nas janelas mutantes que só existem com estado anterior; ciclo de vida completo do bundle provado, inclusive limpeza repetida com `find -printf '%p|%m|%s|%T@'` idêntico; caminho de sucesso provado negativamente em 15 pontos; `python3 -I -S -B tests/python/run_tests.py` = 871 casos; **gate canônico reexecutado por mim**: `bash tests/run-gate-i1.sh` = rc 0, campanha I0 `full` com **46 grupos** (eram 42), manifesto I7 com 136 arquivos, 871 casos no core, whitespace em 0 untracked | **APROVADO (rc=0)** | contrato de efeitos intacto: 11 NAT, 10 bridge, as duas strings de rollback e segunda execução 7/6 todos `custom:config-publish`. Dois oráculos invertidos com comentário `I7.6:` citando o texto anterior, e um terceiro **mudou de significado sem mudar de forma** (a asserção de `TMP_DIR` limpo agora mede que o temporário continua sendo apagado, porque o que é retido foi promovido para o bundle na raiz de estado), o que ficou documentado em vez de silencioso. Bug real corrigido no harness: `mutator_harness_seed_network` devolvia 1 quando a semeadura pedia `no` e derrubava o chamador sob `set -e`, motivo pelo qual toda chamada anterior usava `yes yes yes` e a rede sem autostart era insemeável. `$SRANDOM` (Bash 5.1+) é requisito duro do localizador e a recusa fail-closed sem ele não tem teste, por não haver Bash < 5.1 no ambiente. O bundle é material de recuperação, não recuperação automática: `--recuperacao` só mostra, como REQ-NET-TX pede. `P-UPLINK-EFFECTIVE` e `P-UPLINK-NOT-WIRELESS` não são exercidas ponta a ponta porque o harness sobrescreve os dois probes; ficam cobertas só no core. **Custo:** gate de ~40 para ~50 min. ShellCheck ausente localmente | seção 12, `scratchpad/gate-i76-final.log` | revisão semântica de rollback e fecho do Gate I7 |
| I7.8 | 2026-08-28 | `4590231` + working tree | `etapas/60-rede-bridge.sh` (3164 → 3282 linhas), `tests/test-i0-mutators.sh` (1675 → 1961 linhas), este plano | revisão semântica de rollback em três frentes paralelas (rollback, testes, plataforma); campanha isolada da etapa 60 = 28 grupos rc 0; grupos 30/50/61/70 = 28 grupos rc 0; sonda dedicada do sinal durante o rollback; **gate canônico reexecutado por mim**: `bash tests/run-gate-i1.sh` rc 0 com campanha I0 `full` de **49 grupos** (eram 46), manifesto de 136 arquivos, 871 casos no core, `bash -n` em 56 arquivos | **APROVADO (rc=0)** | 1 bloqueador e 3 defeitos relevantes corrigidos, todos com cenário concreto e nenhum detectável pela suíte anterior. **Provas de regressão, e não só provas de passagem:** o caso novo de sinal durante o rollback, rodado contra uma cópia com o `trap - EXIT INT TERM` antigo, mede **10 efeitos em vez de 12, rc 130/143, nenhum `ROLLBACK INCOMPLETO`, nenhum bundle e nenhum localizador** — exatamente o estado partido e mudo que a correção elimina; o agente de testes provou as três lacunas de oráculo com 11 injeções em cópias do projeto, incluindo os dois pares que mostram que a matriz `before`/`after` e a projeção `cut -f1,2,4` antigas seguiam verdes com as pós-condições de rollback apagadas. Cobertura de divergência silenciosa subiu de **1 para 15** das 20 posições; as 5 posições restantes foram medidas como no-op genuíno (a mentira é indistinguível da verdade ali) e estão nominadas, não escondidas. **Incidente de infraestrutura registrado:** a primeira campanha reprovou com `stderr.log: No such file or directory` porque o diretório do harness em `/tmp` sumiu no meio da execução; reexecutada com `MUTATOR_HARNESS_TMP_PARENT` isolado, passou. O gate final usou o mesmo isolamento. ShellCheck ausente localmente | seção 12, `scratchpad/gate-i7-final.log`, `grupo60-run2.log`, `grupos-30-50-61-70.log`, `regressao-t5.log` | executar I8 |
| Unificação de estado | 2026-08-28 | `4590231` + working tree | `lib/common.sh` (trabalho do usuário, preservado e ligado), `etapas/00-inventario.sh`, `etapas/30-iommu-vfio.sh`, `util/diagnostico.sh`, `tests/test-inventario-redetectar.sh` (+251 linhas), `Guia-QEMU-Passthrough.md`, `troubleshooting.md`, este plano | `bash tests/test-inventario-redetectar.sh` duas vezes, idêntico; `bash tests/test-i6-inventory.sh`; 9 regressões injetadas em cópias, 9 pegas; `find` de `~/inventario-hardware` e da raiz de estado antes/depois idênticos (host intacto); coberto pelo gate canônico de I7.8 | **APROVADO (rc=0)** | fora das fases do plano, pedido do usuário: os relatórios (inventário, diagnóstico e grupos IOMMU) passaram a viver na MESMA raiz de estado de `LOG_ACOES_DIR`, com o caminho literal existindo em um lugar só e migração conferida oferecida pela etapa 1. A migração é transação: copia preservando metadados, prova conjunto de caminhos, contagem, tipo, modo, mtime, alvo de link e digest, e só então remove a origem; qualquer divergência desfaz a cópia e mantém a origem. Recusar é seguro e não bloqueia a etapa. `--verificar` não alcança a pergunta, então o verificador continua read-only | seção 12 | — |
| I7 | 2026-08-28 | `4590231` + working tree | fases `I7.1` a `I7.8` | ver linhas acima | **CONCLUÍDA; Gate I7 APROVADO** | qualificação real de rede continua sendo I13, com hardware e autorização do usuário | seção 12 | executar I8 |
| I8 | 2026-08-28 | `4590231` + working tree | novos `libexec/passthrough_core/platform.py`, `tests/python/test_platform.py`, `tests/test-i8-platform.sh`, `tests/manifests/i8-files.txt`; alterados `lib/platform.sh`, `libexec/passthrough_core/cli.py`, `tests/check-python-boundary.py`, `tests/run-gate-i1.sh`, `etapas/11-driver-nvidia.sh`, `menu.sh`, `tests/i1/mutators.tsv`, este plano | oráculo diferencial do rascunho (55 casos, 12 variáveis, zero divergência) antes de pousar; diferencial de 43 cenários ANTES/DEPOIS para a resolução de unidade systemd, diff limpo; 8 regressões injetadas no teste das 11 fixtures, 8 pegas; fumaça no host real (ubuntu 26.04 `supported`, `AuthenticAMD` suportado, GPU `10de`/nvidia suportada); **gate canônico reexecutado por mim**: `bash tests/run-gate-i1.sh` rc 0, manifesto de 140 arquivos, campanha I0 `full` de 49 grupos, **992** casos no core, `bash -n` em 57 arquivos | **APROVADO (rc=0)** | os classificadores em Bash foram REMOVIDOS, não duplicados: saíram `_plataforma_ler_os_release`, `_plataforma_decodificar_valor`, `_plataforma_detectar_imutabilidade`, `_plataforma_classificar_suporte`, `_plataforma_id_like_contem`, `_plataforma_sondar_unidade_fixture` e `_plataforma_classificar_unidade`. `guard_mutation` não mudou em nenhum byte e nenhum eixo entrou nela. **Limites declarados:** a fachada ainda captura só `lscpu` no eixo de CPU (ligar `/proc/cpuinfo` quebraria o perfil `intel` do envelope I1, porque os harnesses trocam comando por `PATH` e não conseguem redirecionar arquivo — fica para I14B); `plataforma_detectar_gpu_vendor` existe e publica, mas nenhum consumidor ainda decide por ela, porque a interseção dos eixos é I14C; cinco divergências fail-closed em entrada degenerada da resolução de unidade (controle/NUL na fixture, teto de 60 KiB e 4096 linhas, TAB em valor de `systemctl show`, nome de unidade fora do padrão, e um processo `python3` a mais por chamada) estão nominadas em I8.6. Medição que vale registrar: o teste de I8.5 é **estritamente mais forte** que o oráculo do gate I1 num ponto — tirar o ponto final de `MSG_BLOCKED` passa pelo `grep -Eiq` do envelope e é reprovado por ele. ShellCheck ausente localmente | seção 12, `scratchpad/gate-i8-final.log` | executar I9 |
| I9 (I9.1 a I9.11) | 2026-08-30 a 2026-09-02 | `91cd349` a `43ec863` | novos `lib/shell/{base,ui,privilege,status,probes,storage,network-effects,libvirt,config,waivers}.sh`, `lib/policy/waivers.tsv`, `tests/check-waivers-matrix.py`, `tests/test-i9-{modulos,hooks-isolados,windows-state,airlock-verify,verify-helpers,waivers,revisao-semantica}.sh`, `tests/manifests/i9-files.txt`; alterados `lib/common.sh` (4145 para 80 linhas), `lib/shell/boot.sh`, `menu.sh`, `etapas/02-detectar-config.sh` | suítes dirigidas de I9.1 a I9.11 (37+9+50+59+41+24 casos); `GATE_FASE=I9 bash tests/run-gate-i1.sh` executado em 02/09/2026 com `MUTATOR_HARNESS_TMP_PARENT` e `TMPDIR` fora de `/tmp`: manifesto de **160** arquivos, envelope I1 com 30 mutadores diretos e 23 seleções de menu em 6 perfis duas vezes, `atualizar-host --validar` em 29 cenários, **campanha I0 `full` aprovada nos 49 grupos em 61 min**, e o laço histórico aprovado até `test-i9-airlock-verify.sh` | **PARCIAL: veredito final do gate NÃO observado** | O log do gate foi perdido antes de eu ler as linhas finais, e a notificação de "exit code 0" era do `awk` do wrapper, não do gate (a armadilha que a própria seção 12 já registra). Portanto o gate **não** conta como aprovado: nenhuma linha `OK: Gate I9 concluído` foi vista. Independentemente disso, **I9.12 reabriu a fase**, então o gate precisa ser reexecutado no fechamento dela. ShellCheck ausente neste host (a CI versionada o exige). Artefatos de I9B construídos nesta mesma sessão foram perdidos com o scratchpad e precisam ser reconstruídos | commit `43ec863`; `tests/test-i9-revisao-semantica.sh` (24 casos) no repositório | implementar I9.12 e reexecutar o Gate I9 |
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
| I9B | | | | | não iniciado | i18n en/pt-BR/es | | aguarda I9 |
| I14B Intel | | | | | PLANEJADO | exige host Intel | | trilha de expansão |
| I14C GPU AMD | | | | | PLANEJADO | exige GPU Radeon | | trilha de expansão |

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
- [~] REQ-IOMMU-TX aprovado, separando ativo/persistente (código `CONFORME` e **aprovado em I5**, conforme o catálogo da seção 4; a caixa estava desatualizada e foi corrigida na auditoria de 23/08/2026. Os dois reboots reais continuam `[H]` em I13).
- [~] REQ-LIBVIRT-BACKEND aprovado em backend monolítico/modular (resolução autoritativa e matriz por fixture aprovadas em I3; libvirt real é `[H]` de I13).
- [~] REQ-HOOKS-TX aprovado incluindo opções XML (opções dentro da transação, rollback comprovado e idempotência exata aprovados em I3; ciclo real de GPU/display é `[H]` de I13).
- [~] REQ-WINDOWS-STATE separa instalação/power/agent (metadata durável vinculada ao QCOW2 pronta e testada em I3; a decisão e os três eixos entram em I4/I9).
- [ ] REQ-AIRLOCK-VERIFY prova política efetiva.
- [~] REQ-VERIFY-FAILCLOSED não possui falso sucesso conhecido (o caso `atualizar-host --validar` foi corrigido em I1; auditoria completa pendente em I9).
- [x] REQ-WAIVERS tem efeito real ou foi removido com migração (I4: duas mantidas com efeito testado, duas removidas por migração segura).
- [ ] REQ-DISK-IDENTITY impede workingDisk igual a HD1 físico.
- [~] REQ-USB-IDENTITY recusa dispositivos ambíguos (a etapa 15 já recusa VID:PID duplicado em vez de escolher por ordem; serial/porta e revalidação antes do attach são de I6).
- [ ] REQ-NET-TX não deixa estado parcial e prova recuperação.

- [ ] REQ-BOOT-POSCONDICAO: nenhum aplicador de bootloader declara sucesso sem provar regeneração.
- [ ] REQ-I18N: idioma não altera código de saída, fluxo, canal de máquina nem byte publicado.
- [ ] REQ-CPU-VENDOR: nenhum plano de pinning mistura tipos de core; híbrida sem evidência é recusada.
- [ ] REQ-GPU-VENDOR: nenhuma promessa de retorno da GPU sem classificação de reset.

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
- [ ] Eixo CPU Intel (I14B) implementado, com AMD idêntico byte a byte, ou permanece `PLANEJADO`.
- [ ] Eixo GPU AMD (I14C) implementado, com NVIDIA idêntico byte a byte, ou permanece `PLANEJADO`.

- [ ] Marco `EXPANSAO_TOTAL_QUALIFICADA` registrado.
- [ ] Limitações de hardware estão explícitas.
- [ ] Não há temporários, dados reais ou segredos na working tree rastreada, no index nem em arquivos untracked; todos os novos pertencem ao manifesto.
- [ ] Usuário revisou o resultado antes de commit/tag/release.

**O plano só está integralmente concluído no marco `EXPANSAO_TOTAL_QUALIFICADA`. O objetivo mínimo do usuário (Ubuntu funcional) é atingido antes disso, em dois degraus verificáveis: (a) "código Ubuntu completo" conforme 11.1 ao final de I12; e (b) "Ubuntu operacionalmente qualificado" conforme 11.2 ao final da campanha Ubuntu de I13. Enquanto qualquer campanha/provider não for executado, mantenha o item `[H]`/`PLANEJADO` aberto; não reduza o critério para encerrar artificialmente.**
