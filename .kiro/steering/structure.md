# Estrutura

- `menu.sh`: orquestra as 21 etapas.
- `etapas/`: entrypoints operacionais; preservam nomes e ordem pública.
- `lib/common.sh` e `lib/platform.sh`: fachadas compatíveis durante a migração.
- `lib/python-core.sh`: única ponte Bash/Python.
- `libexec/passthrough_core/`: modelos e cálculos puros. I6 acrescentará `inventory.py`; `network.py` e `platform.py` pertencem a I7 e I8.
- `lib/shell/`: efeitos Bash modularizados (I9): `base`, `ui`, `privilege`, `status`, `probes`, `storage`, `libvirt`, `boot`, `network-effects`, `config` e `waivers`. Cada módulo declara os pré-requisitos de carga e recusa ordem errada com diagnóstico; a fachada é quem compõe. Não existe `hooks.sh`: o hook libvirt é gerado autossuficiente pela etapa 14.
- `tests/`: caracterização, regressão, fixtures, gates e manifestos de fase.
- `.kiro/specs/repository-finalization/`: spec ativo para I6; as seis specs anteriores são referências reconciliadas por subsistema.

Direção de dependência: `menu/etapas/util` → fachadas e módulos shell/ponte → entrypoint Python → módulos puros. Não criar uma segunda árvore mutável paralela.
