# Design — Núcleo de plataforma multi-distro

> **Status:** baseline Bash implementado; migração pura de I8 ainda futura.
> **Escopo:** fatos, resolução, capabilities e diagnóstico; providers mutáveis ficam fora.
> **Dependências:** I6.0 → I6 → I7 → I8; expansão somente em I14 após I13.
> **Gate:** fixtures de plataforma, Gate I8 e gate canônico cumulativo.

## Arquitetura híbrida

```text
menu.sh / etapas
       |
       v
lib/platform.sh                  fachada e guards compatíveis
       |
       +--> Bash captura evidências e mantém efeitos/providers
       |
       v
lib/python-core.sh               ponte única
       v
libexec/passthrough_core_cli.py  entrypoint único
       v
libexec/passthrough_core/platform.py  parsing e resolução puros (I8)
```

Não será criada uma árvore `platform` paralela. `platform.py` recebe por stdin ou arquivo controlado os snapshots capturados pelo Bash, normaliza fatos, resolve capacidades e devolve um plano/diagnóstico determinístico. Ele não lê `/etc/os-release`, não consulta o host, não eleva privilégio e não executa providers.

## Estado atual e alvo

- **Implementado:** `lib/platform.sh`, guards pré-efeito, perfis mutáveis Ubuntu/Pop!_OS e harness histórico.
- **Parcial:** fatos e eixos ainda resolvidos em Bash; eixo GPU está espalhado; backend libvirt precisa resolução autoritativa.
- **Futuro I8:** `platform.py`, fatos tipados, origem/confiança, CPU/GPU independentes e cutover atrás da fachada.
- **Futuro I14:** providers de novas distribuições, um alvo por vez e só após `BASE_QUALIFICADA`.

## Modelo público

Campos usam `PLATAFORMA_*`, incluindo distribuição, família, versão, arquitetura, mutabilidade, nível de suporte, provider e motivos de bloqueio. Os níveis válidos são:

- `supported`: mutação permitida apenas nas capabilities comprovadas;
- `diagnostic-only`: observação sem mutação;
- `family-unverified`: família reconhecida sem qualificação do alvo;
- `blocked`: conflito, imutabilidade ou requisito não atendido.

Eixos de distribuição, CPU e GPU são independentes. Hoje somente Ubuntu/Pop!_OS + AMD + NVIDIA formam o baseline mutável.

## Resolução

1. validar fatos capturados;
2. preferir identidade exata à família;
3. cruzar candidatos com evidência runtime;
4. resolver cada capability e eixo separadamente;
5. bloquear conflito/ausência sem default permissivo;
6. apresentar resumo antes do menu e motivo por opção.

`BOOTLOADER` permanece enum/configuração compatível e override legado. Ele nunca substitui evidência runtime.

## Segurança e testes

O parser usa allowlist e mantém conteúdo hostil inerte. Fixtures podem substituir snapshots, mas não executar comandos. Os 11 cenários normativos comprovam determinismo e fail-closed; eles não qualificam hardware ou distro. O cutover só termina quando a fachada Bash delegar o cálculo puro, a comparação diferencial tiver sido removida e o gate cumulativo estiver aprovado.
