# Tecnologia

A arquitetura é híbrida Bash/Python.

- Python 3.10+ e biblioteca padrão executam cálculo puro: parsing, normalização, validação, comparação semântica, diffs e planos declarativos.
- `lib/python-core.sh` é a única ponte para `libexec/passthrough_core_cli.py` e `libexec/passthrough_core/`.
- Bash mantém menu, probes do host, confirmações, `sudo`, snapshots, locks, aplicação, verificação, commit e rollback. Os efeitos ficam nas etapas e, progressivamente, em `lib/shell/`.
- Python não executa comandos do host, não eleva privilégio e não controla libvirt, serviços, rede, boot ou disco.
- Hooks libvirt permanecem Bash puro, autossuficientes e independentes do checkout.

O gate canônico cumulativo é `bash tests/run-gate-i1.sh`. I6 só pode começar depois da execução e do registro de I6.0.
