# Tecnologia

A arquitetura é híbrida Bash/Python.

- Python 3.10+ e biblioteca padrão executam cálculo puro: parsing, normalização, validação, comparação semântica, diffs e planos declarativos. Invocação sempre por `python3 -I -S -B` via `lib/python-core.sh`; nenhum `.pyc` no checkout.
- Bash mantém menu, probes do host, confirmações, `sudo`, snapshots, locks, aplicação, verificação, commit e rollback. Os efeitos vivem nas etapas e em `lib/shell/`.
- Python não executa comandos do host, não eleva privilégio e não controla libvirt, serviços, rede, boot ou disco. `tests/check-python-boundary.py` reprova import proibido e, nos módulos puros (`inventory`, `platform`, `resources`), qualquer abertura de caminho.
- Hooks libvirt permanecem Bash puro, autossuficientes e independentes do checkout; `tests/test-i9-hooks-isolados.sh` apaga o projeto antes de executá-los. A aritmética de memória do hook é Bash e o núcleo Python é o planejador; o oráculo diferencial de `tests/test-i912-memoria-hooks.sh` impede divergência silenciosa.

## Gate canônico

`bash tests/run-gate-i1.sh` (rótulo por `GATE_FASE`, padrão `I9`). Leva cerca de 1 hora por causa da campanha I0 `full` (49 grupos). Regras práticas:

- rodar com `TMPDIR` e `MUTATOR_HARNESS_TMP_PARENT` apontando para um diretório próprio fora de `/tmp`;
- não editar nenhum arquivo do checkout enquanto o gate roda: `tests/test-python-core.sh` fotografa conteúdo e mtime de tudo fora de `.git` e reprova qualquer mudança;
- o veredito é a linha `OK: Gate <fase> concluído sem mascarar status`; código de saída de wrapper ou de `awk` não conta;
- `tests/test-python-core.sh` procura a linha literal `OK` do unittest; com `FORCE_COLOR` no ambiente (comum em terminais de assistentes) o Python 3.14 colore a linha e o teste reprova sem defeito real. Rode com `FORCE_COLOR` desligado ou `NO_COLOR=1`;
- teste dirigido primeiro, gate depois; segunda execução de operação convergente precisa ser no-op exato.

## Fatos medidos que decidem desenho

Reverificados em 03/09/2026 neste host:

- O `printf` embutido do bash 5.3.9 recusa o especificador posicional `%N$s` (`printf: '$': caractere de formato inválido`); só `/usr/bin/printf` aceita. Mensagens traduzidas (I9B) são renderizadas por expansão de parâmetro, nunca pelo `printf` com o valor do catálogo como formato.
- O coreutils deste host é o uutils (`/usr/bin/test` aponta para `/usr/lib/cargo/bin/coreutils/test`); o `test` externo ignora grupos suplementares em `-r`/`-w`/`-x`, os builtins do bash acertam.
- HugePages de 1 GiB reservadas no boot foram devolvidas em runtime neste kernel (7.0.0-30, `CONFIG_CONTIG_ALLOC=y`): 21,8 GiB sem reiniciar. O que persiste é a política do bootloader, não a página.

Anotados pela sessão de 02/09/2026 e não reproduzidos na árvore (reconfirmar antes de depender):

- `mapfile -t` lê 2400 linhas em cerca de 1 ms; um fork por linha (`$( )`) custa segundos. Catálogo é carregado uma vez por processo, no shell pai, porque `$(msg ...)` roda em subshell.
- `menu.sh --status` abre 22 processos; qualquer custo por carga de fachada é multiplicado por 22.
