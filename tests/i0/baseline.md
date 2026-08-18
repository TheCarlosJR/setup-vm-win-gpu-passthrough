# Baseline I0 — oráculo e caracterização

Data de fechamento: 2026-08-14. Escopo: somente I0 de `PLANO-INTEGRADO-MELHORIAS-MIGRACAO-PYTHON.md`. O checkout-base foi `8b34a4c0cf351a511481d0ed61f74c5296e832a9`. Nenhum arquivo de produção foi alterado; as mudanças são plano, testes, fixtures, harnesses e estes artefatos. Não houve instalação, `sudo`, commit, tag, push, boot, rede, libvirt, disco, serviço ou VM real.

## Ambiente e preflight

- GNU Bash `5.3.9(1)-release`; Python `3.14.4` (atende Python 3.10+); Git `2.53.0`; Bubblewrap `0.11.1` usado como barreira de filesystem/namespaces nos harnesses mutantes.
- `shellcheck`, `pwsh`, `pyright`, `pyright-langserver`, `xmlstarlet` e `virt-xml-validate` estavam ausentes e não foram instalados. A ausência de `pyright-langserver` impede diagnóstico LSP Python; AST stdlib foi usado como validação local.
- Estado inicial relevante: o plano já estava não rastreado; `passthrough.conf`, `.kiro/` e `semantic-review/` estavam ignorados. Alterações do usuário foram preservadas.
- Preflight anterior às adições I0: `bash -n` passou em `38/38` scripts rastreados; os oito `tests/test-*.sh` então existentes passaram (`8/8`). Não havia falha preexistente da suíte. As lacunas funcionais catalogadas em `oracle.tsv` e `deltas.tsv` são comportamento atual reproduzido, não regressões introduzidas pela I0.
- A medição pré-I0 da suíte então existente (oito testes) teve mediana `8935 ms`; ela é mantida somente como diagnóstico histórico do delta introduzido pela caracterização. O orçamento normativo usa o runner final de dez testes medido sob a mesma condição e está registrado em **Desempenho reproduzido**. A medição histórica de `menu.sh --status` teve mediana `2987 ms` e também foi substituída abaixo pela campanha autoritativa final.

## Artefatos e método

- `oracle.tsv`: classificação de todos os itens da tabela 1.3 e dos 13 requisitos da seção 4. Resultado dos requisitos: `AUSENTE` para REQ-CONF-ISO, REQ-WINDOWS-STATE e REQ-USB-IDENTITY; os outros dez estão `PARCIAL`; nenhum está `CONFORME`.
- `traceability.tsv`: origem/API, consumidor ou wrapper atual, fronteira dado/probe/efeito, módulo-alvo e testes. Foram inventariados 11 heredocs Python de produção, usos de `xmlstarlet`, parsers AWK/XML/JSON, efeitos que devem permanecer em Bash e uma linha verificável para cada uma das 41 chaves públicas de configuração; as duas dispensas sem consumidor operacional são registradas explicitamente como lacunas.
- `deltas.tsv`: 32 deltas conhecidos, com evidência, fase futura e limite de aceite. A tabela caracteriza problemas; não antecipa I1 ou fases posteriores.
- `tests/fixtures/i0/`: dados exclusivamente sintéticos e públicos para configuração, domínio/rede XML, JSON `qemu-img`, CPU e inventário.
- `tests/test-i0-characterization.sh`: chama APIs reais de `lib/common.sh` sobre cópias temporárias. Reset/backup também permanecem cobertos por `tests/test-inventario-redetectar.sh`.
- `tests/lib/mutator-harness.sh`, `mutator-dispatch.py` e `mutator-safe-command.sh`: executam cópias dos scripts reais das etapas 30, 50, 60, 61 e 70 com `bubblewrap 0.11.1`, raiz mínima em `tmpfs`, namespaces isolados, somente runtime imutável (`/usr`, bibliotecas e cache do loader) montado read-only, `/run` efêmero, cwd/bind gravável limitado ao `mktemp`, `/sys` e `/proc/cmdline` sintéticos, `PATH` fechado e shims stateful. A árvore real do host — inclusive `/home`, `/var/tmp` e demais locais possíveis de socket — não é montada. Caminhos absolutos externos, travessia, redirecionamentos crus, código Bash/Python/AWK com escrita externa e assinaturas/operações stateful não modeladas são recusados; canários AF_UNIX sob `/run` e `/var/tmp` comprovam que sockets reais não são alcançáveis, e o cleanup remove somente as raízes exatas criadas pelo teste.
- `tests/test-i0-mutators.sh`: `gate` é a prova rápida usada pela suíte normal; `smoke` e `full` são campanhas dirigidas. Variáveis `I0_MUTATOR_SKIP_*` existem somente para depuração isolada; a campanha final foi executada com todas removidas do ambiente.

## Cobertura de caracterização

Configuração cobre literal/quoting/escapes, comentários e ordem, newline final ausente, duplicata, chave desconhecida, malícia inerte, load-save-load, lote todo-ou-nada, reset/backup `0600`, modo/estado do arquivo, symlink, hardlink, troca concorrente de inode e invariância byte a byte/metadados do exemplo. Hardlink aceito e publicação após troca concorrente são oráculos de lacunas futuras, não aprovação.

XML/JSON cobre cardinalidade zero/um/múltiplos e malformado para os seletores gerenciados, QCOW2 e block, GPU/áudio PCI `managed=yes`, NIC por MAC, TPM, NVRAM, CPU, HugePages, discard, vídeo/gráficos, conteúdo não gerenciado, ordem/espaços semanticamente equivalentes, hotplug/NUMA e redes gerenciada/não gerenciada/ambígua. JSON cobre raw, qcow2, backing chain, campos ausentes, tipos/valores inválidos e sintaxe malformada. O oráculo de fixtures valida a intenção estrutural; ele não é o futuro core e não substitui teste direto do parser hoje embutido em `util/backup-vm.sh`.

CPU/inventário cobre multissocket, SMT, core dividido, ordem canônica, CPU offline, IDs esparsos, NUMA, formatos atual/legado, reordenação, ausência, truncamento, mudança de identidade e ponteiro relativo/externo. A sensibilidade atual à ordem de CPU/discos é lacuna registrada para I6.

A matriz mutante cobre:

- etapa 30: sucesso, cada fronteira antes/depois, `INT`/`TERM`/`EXIT`, fase pós-reboot modelada e segunda execução;
- etapa 50: 23 fronteiras da transação principal, sinais, quatro combinações de opções, efeitos pós-commit, rollback XML divergente e segunda execução;
- etapa 60: NAT/bridge, conversões, falha em cada mutação, sinais em toda janela, ordem e falhas antes/depois do rollback, rollback rc=0 divergente, concorrência, rede não gerenciada, consumidores, colisão, cardinalidade de NIC, segunda execução e confinamento;
- etapa 61: 14 fronteiras, sinais, falha do próprio rollback, política modelada e segunda execução;
- etapa 70: sucesso, falha antes/depois do define, sinais, releitura, rollback normal/divergente/falho e no-op da segunda execução.

## Comandos e resultados finais

| Comando | Resultado |
|---|---|
| `env -u I0_MUTATOR_SKIP_30 ... -u I0_MUTATOR_SKIP_70 LC_ALL=C I0_MUTATOR_MATRIX=full bash tests/test-i0-mutators.sh` sob `bubblewrap` | PASS; `39` grupos; repetição final `535,52 s`; `17016 KiB` de RSS máximo; sem skips; raiz mínima, runtime read-only, `/run` efêmero e `/sys` sintético |
| `LC_ALL=C bash tests/test-i0-characterization.sh` | PASS; intenção das fixtures e caracterização real aprovadas |
| `LC_ALL=C bash tests/test-i0-mutators.sh` | PASS; gate rápido, confinamento e rollback representativo da etapa 60; `2` grupos |
| loop `LC_ALL=C` sobre todos os dez `tests/test-*.sh` | PASS `10/10`; três amostras autoritativas registradas abaixo |
| `bash -n` em arquivos retornados por `git ls-files -co --exclude-standard -- '*.sh'` | PASS `42/42` |
| `python3 -I -S -B` com `ast.parse` nos `.py` rastreados ou não ignorados | PASS `2/2` |
| validação fechada de colunas TSV e cobertura da allowlist | PASS: `oracle` 32×8, `traceability` 76×7 com 41/41 chaves, `deltas` 32×7 |
| revisão semântica final independente | `APROVADO`; issues `0`; bloqueadores de assinatura interna, AF_UNIX e registro normativo reproduzidos como corrigidos |
| `git diff --check` | PASS |

Campanhas intermediárias anteriores à raiz mínima com `bubblewrap` foram mantidas apenas como diagnóstico de desenvolvimento. O registro normativo é a campanha full isolada de `535,52 s` acima; uma campanha `smoke` posterior ao reforço também passou, mas não substitui a matriz completa.

## Desempenho reproduzido

Condição autoritativa: `LC_ALL=C`, mesmo checkout e fixtures, cache aquecido por execução prévia, execução serial e saída descartada fora do repositório. O alvo "runner completo" é exatamente o loop de dez `tests/test-*.sh` que o gate executa; seu próprio valor, e não o runner histórico de oito testes, define o orçamento pós-migração.

| Alvo | Amostra 1 | Amostra 2 | Amostra 3 | Mediana | Orçamento `max(2×baseline, baseline+2 s)` |
|---|---:|---:|---:|---:|---:|
| runner completo final, dez testes | `14266 ms` | `14137 ms` | `14167 ms` | `14167 ms` | `28334 ms` |
| `menu.sh --status` | `3177 ms` | `3085 ms` | `3055 ms` | `3085 ms` | `6170 ms` |

As três execuções do runner terminaram em `0`; as três de `menu.sh --status` retornaram `3`. O retorno `3` é o código público agregado para erro/estado não comprovado no host atual e foi preservado como baseline, nunca reclassificado como sucesso. A saída de status, que pode conter identificadores locais, foi descartada sem ser publicada. As amostras anteriores dos oito testes (`8853/8880/8871 ms`) permanecem apenas como série histórica de um alvo diferente e não participam do orçamento normativo.

## Specs I0.10

A auditoria read-only encontrou seis arquivos `.kiro/specs/*/tasks.md`, 59 checkboxes no total: uma marcada e 58 desmarcadas. Somente a tarefa 1 de `.kiro/specs/platform-multidistro-core/tasks.md` está `[x]`; todas as tarefas dos outros cinco arquivos permanecem `[ ]`. Nenhum checkbox local foi alterado. `.kiro/` continua ignorado e fora do índice; portanto este relatório rastreado registra o estado sem designorar dados locais.

## Configuração e histórico I0.11

- `.gitignore` ignora `passthrough.conf` na linha 2 e `.kiro/` na linha 7; ambos estão fora do índice. A cópia local não foi apagada nem copiada para fixtures/artefatos.
- Nenhum caminho histórico nomeado exatamente `passthrough.conf` ou `.kiro/` foi encontrado no banco local alcançável. `passthrough.conf.example` possui nove blobs históricos; o exemplo baseline tem SHA-256 público `770ccd4d0dec50d256a8f9bf1dd75ed0e3a4aff98d93f39f91d091598a559d69`, `6241` bytes e allowlist de 41 chaves.
- A configuração local exata não foi encontrada no banco local de objetos. Um blob inalcançável (`255497927cc6876f84bcda4abb09f8adf007abd9`) menciona o nome `passthrough.conf`, aparenta ser documentação e não teve origem atribuível; objetos relacionados observados: commit `b2d4baa423829be6c775d18533111caddc7c6655` e tree `6383dd6957c527922945819cec298d5f5d7ccc7f`.
- A varredura não encontrou assinaturas fortes comuns de segredo, mas isso não prova ausência. Limites: somente este clone e seu banco local, sem remotos/reflogs externos, outras cópias, scanner especializado ou auditoria do provedor. I4 deve manter a orientação de revisão/rotação caso uma fonte autoritativa revele exposição.

## Integridade e limites

- Os testes automatizados usam apenas dados sintéticos, cópias temporárias e shims. Nenhum resultado mockado qualifica boot, IOMMU/VFIO, passthrough, reset de GPU, libvirt, rede, TRIM físico, Windows, Airlock ou backup real.
- O harness usa `bubblewrap` com raiz mínima em `tmpfs`; monta somente `/usr`, bibliotecas e cache do loader read-only, o diretório exato de `mktemp` como bind gravável, `/run` efêmero e fixtures para `/sys` e `/proc/cmdline`. Nenhuma árvore geral do host é espelhada. Canários independentes do dispatcher comprovam recusa de escrita na árvore real, ausência de vazamento pelo `/tmp` e impossibilidade de conectar a sockets AF_UNIX reais tanto sob `/run` quanto sob `/var/tmp`, fora dos overlays explícitos. O dispatcher também falha fechado, com rc `126` e registro, para operações, opções, gramáticas e operandos não modelados de `systemctl`, `netplan`, `ip`, `ufw`, `virsh`, `xmlstarlet` e demais famílias stateful.
- Ferramentas opcionais ausentes não foram simuladas como validação real. `bash -n`, AST stdlib, testes diretos e os shims são as evidências disponíveis.
- A classificação permanece estrita: uma implementação parcial não vira `CONFORME` porque há um helper ou teste. As falhas conhecidas são deltas para I1/I3/I4/I5/I6/I7/I9/I13; nenhuma foi corrigida ou antecipada em I0.
- Comparação final privada de conteúdo, owner/grupo, modo e mtime de `passthrough.conf`: APROVADA nas campanhas rápida e completa; nenhum digest ou valor local foi versionado. O estado ignorado de `.kiro/` também não foi editado.
