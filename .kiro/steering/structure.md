# Estrutura

- `menu.sh`: orquestra as 21 etapas.
- `etapas/`: entrypoints operacionais; preservam nomes e ordem pública.
- `lib/common.sh` e `lib/platform.sh`: fachadas compatíveis durante a migração.
- `lib/python-core.sh`: única ponte Bash/Python.
- `libexec/passthrough_core/`: modelos e cálculos puros. I6 acrescentará `inventory.py`; `network.py` e `platform.py` pertencem a I7 e I8.
- `lib/shell/`: efeitos Bash modularizados; `boot.sh` já existe desde I5 e os módulos restantes pertencem sobretudo a I9.
- `tests/`: caracterização, regressão, fixtures, gates e manifestos de fase.
- `.kiro/specs/repository-finalization/`: spec ativo para I6; as seis specs anteriores são referências reconciliadas por subsistema.

Direção de dependência: `menu/etapas/util` → fachadas e módulos shell/ponte → entrypoint Python → módulos puros. Não criar uma segunda árvore mutável paralela.
