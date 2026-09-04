# Estrutura

- `menu.sh`: orquestra as 21 etapas (numeração do menu na tabela "Numeração das etapas" do plano; o nome do arquivo em `etapas/` é histórico).
- `etapas/`: entrypoints operacionais; preservam nomes, ordem pública e opções `--verificar`/`--desfazer`.
- `lib/common.sh`: agregador de 80 linhas, sem algoritmo de domínio (I9.4). Carrega, nesta ordem, `lib/shell/base.sh`, `lib/platform.sh`, `lib/python-core.sh`, depois `ui`, `libvirt`, `privilege`, `status`, `boot`, `probes`, `network-effects`, `storage`, `config`, `waivers`. Cada módulo declara pré-requisitos e recusa ordem errada.
- `lib/platform.sh`: fachada de plataforma; o resolvedor é `platform.py` desde I8.
- `lib/python-core.sh`: única ponte Bash/Python. Payload sempre por stdin ou arquivo `0600`, nunca em `argv`; o Bash não constrói JSON (canal de pares `chave\0valor\0`).
- `lib/policy/waivers.tsv`: matriz versionada de dispensas (REQ-WAIVERS).
- `libexec/passthrough_core_cli.py` + `libexec/passthrough_core/`: núcleo puro (`errors`, `protocol`, `cli`, `xmlutil`, `domain_xml`, `network_xml`, `qemu_image`, `config`, `cpu`, `inventory`, `network`, `platform`, `resources`, `nvidia_lookup`, `colors`). Não executa comandos, não abre caminhos do host, não eleva privilégio. Não existe `hooks.sh` nem `boot.py` por decisão registrada (I9-D8 e limitações de I5).
- `tests/`: suítes `test-*.sh` (todas herméticas), `python/` (unittest sob `-I -S -B`), `fixtures/`, `lib/` (harnesses), `manifests/` (um por fase, ordem C), `i0/` (oráculo e deltas históricos), `run-gate-i1.sh` (gate canônico cumulativo), `check-*.{sh,py}` (gates estáticos).
- `.kiro/specs/`: `repository-finalization` está concluída (I6). As seis specs multidistribuição são referências congeladas até I11.3/I11.4 (tabela de coordenação do plano); seus checkboxes não refletem o estado atual e não devem ser lidos como lista de trabalho.
- Ainda não existem (pertencem a I9B): `lang/*.msg`, `lib/shell/i18n.sh`, `libexec/passthrough_core/messages.py`, `tests/check-i18n-catalogs.py`, `tests/i18n-pendentes.txt`.

Direção de dependência: `menu/etapas/util` → fachadas e módulos shell/ponte → entrypoint Python → módulos puros. Não criar uma segunda árvore mutável paralela. Todo arquivo novo entra em um manifesto de fase.
