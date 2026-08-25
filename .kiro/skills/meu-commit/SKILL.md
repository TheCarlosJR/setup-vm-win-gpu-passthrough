---
name: meu-commit
description: Cria os commits do trabalho pendente seguindo o padrão de mensagens já usado no histórico do repositório, com granularidade razoável, usando o autor padrão do Git e sem qualquer menção a ferramentas de IA (Kiro, Claude, Codex) ou ao modelo, nem na mensagem nem como co-autor. Use ao pedir para commitar, agrupar mudanças em commits ou escrever mensagens de commit.
---

## Contexto adicional do usuário

$ARGUMENTS

## Objetivo

Transformar o trabalho pendente da árvore em uma sequência de commits limpa,
com granularidade razoável, seguindo o padrão de mensagens do próprio
repositório e a identidade padrão do Git configurada na máquina.

## Regras invioláveis

1. **Nenhuma menção a IA.** A mensagem de commit (assunto e corpo) nunca pode
   citar Kiro, Claude, Codex, Copilot, "agente", "LLM", o nome do modelo ou o
   fato de a mudança ter sido assistida.
2. **Nenhum co-autor artificial.** Não adicione `Co-authored-by:`,
   `Generated-by:`, `Assisted-by:`, `Signed-off-by:` de ferramenta, nem
   qualquer trailer equivalente.
3. **Autor padrão.** Use exatamente `git config user.name` / `git config
   user.email` já configurados. Não passe `--author`, não altere `git config`
   e não exporte `GIT_AUTHOR_*` / `GIT_COMMITTER_*`.
4. **Sem push, sem tag, sem release.** Apenas commits locais, salvo pedido
   explícito.
5. **Sem `--amend`, `reset --hard`, `clean -f` ou checkout destrutivo.**
6. **Sem `git add -A` / `git add .`.** Stage sempre por caminho explícito, para
   não arrastar mudança alheia ao commit.

## Descobrir o padrão do projeto antes de escrever qualquer mensagem

Não presuma Conventional Commits. Inspecione o histórico e reproduza o padrão
observado:

```bash
git log --pretty=format:'%h | %an <%ae> | %s' -40
git log --pretty=format:'=== %h%n%B' -12   # há corpo ou só assunto?
git config user.name; git config user.email
```

Registre e siga: idioma, modo verbal (imperativo?), capitalização inicial,
presença ou ausência de prefixo/escopo, pontuação final, comprimento típico do
assunto e se o histórico usa corpo.

## Fluxo

1. `git status --porcelain=v1` e `git branch --show-current`. Se o branch for
   `main`/`master`, apenas commite; não faça push.
2. Levante o escopo real: `git diff --stat`, `git diff --numstat`, e leia os
   arquivos novos relevantes. Entenda a mudança antes de nomeá-la.
3. Procure a estrutura que o próprio projeto já usa para organizar trabalho
   (plano/spec/fases, manifestos de arquivos novos, diretórios por subsistema)
   e use-a como base do agrupamento.
4. Monte o plano de commits e **mostre ao usuário** o agrupamento arquivo→commit
   com os assuntos propostos antes do primeiro `git commit`.
5. Para cada commit: stage por caminho explícito, confira com
   `git status --short` / `git diff --cached --stat` e só então commite.
6. Ao terminar: `git log --pretty=format:'%h | %an <%ae> | %s' -N`,
   `git status --short` (deve estar limpo, exceto arquivos ignorados) e a
   verificação do projeto (gate/suíte/build/lint) na ponta do histórico.

## Granularidade razoável

- Um commit por mudança lógica coerente; nem um commit único gigante, nem um
  commit por arquivo.
- Prefira agrupar por arquivos inteiros. Só recorra a stage parcial por hunk se
  o usuário pedir explicitamente.
- Quando um arquivo central (biblioteca compartilhada, fachada, config) é tocado
  por várias frentes, coloque-o no commit que o introduz/reconstrói e deixe os
  commits seguintes com os call sites por subsistema.
- Ordene os commits por dependência: documento/base, fundação, módulos,
  cutover, call sites, testes e CI.
- Deleção de arquivo obsoleto viaja junto com o substituto, quando houver.

## Verificação e honestidade

- A suíte/gate é verificada na **ponta** do histórico. Se commits intermediários
  não passam isoladamente por causa de dependências entre arquivos, diga isso
  ao usuário em vez de afirmar que todos passam.
- Antes de commitar, sinalize arquivos que possam conter segredos (`.env`,
  credenciais, chaves) e caminhos com dados locais de hardware.
- Se `git commit` falhar por hook, corrija a causa, re-stage e faça um commit
  **novo**; nunca `--amend` depois de falha de hook.
