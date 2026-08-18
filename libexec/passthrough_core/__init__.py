"""Core Python puro do projeto de passthrough.

Este package contém somente cálculo, validação, parsing e serialização. Ele
não executa comandos do host, não eleva privilégio, não controla serviços e
não conhece o shell: efeitos, `sudo`, snapshots, aplicação e rollback ficam
integralmente em Bash (seção 2.1 do PLANO-FINALIZACAO.md).

O import é feito exclusivamente por `libexec/passthrough_core_cli.py`, que é o
entrypoint único chamado pela ponte `lib/python-core.sh`. Não há `__main__.py`
nem segundo entrypoint: o gate de fronteira de I10 reprova ambos.

Este módulo é deliberadamente vazio de lógica para que `import passthrough_core`
não produza efeito algum.
"""
