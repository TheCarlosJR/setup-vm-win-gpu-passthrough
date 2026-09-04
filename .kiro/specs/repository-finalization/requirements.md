# Requisitos — Finalização do repositório: I6

> **Status:** spec concluída; I6.0 aprovado e I6 encerrada em 23/08/2026 (Gate I6). Referência histórica: a fase ativa está em `PLANO-FINALIZACAO.md`, seção 0.0.
> **Escopo:** inventário e identidades físicas de I6, sem antecipar I7–I14.
> **Dependências:** entregas históricas I0–I5 e revalidação I6.0.
> **Gate:** `bash tests/run-gate-i1.sh`, campanha I0 `full` e Gate I6 descrito no `PLANO-FINALIZACAO.md`.

## REQ-I6-BASELINE — Precondição obrigatória

1. QUANDO qualquer implementação de I6 for iniciada, O EXECUTOR DEVE primeiro executar I6.0 sobre a árvore preservada.
2. QUANDO I6.0 for executado, O EXECUTOR DEVE rodar o gate canônico e a campanha I0 `full` e registrar o resultado numa nova linha da seção 12 do plano.
3. SE qualquer verificação de I6.0 reprovar, ENTÃO O EXECUTOR DEVE tratar a falha como preexistente e corrigi-la antes de I6.1.
4. ENQUANTO I6.0 não estiver executado e registrado, O EXECUTOR NÃO DEVE marcar nem implementar tarefas I6.1–I6.6.

## REQ-I6-INVENTARIO — Snapshot normalizado

1. QUANDO o Bash fornecer snapshots de CPU, memória, PCI, discos/IDs, interfaces e boot, O CORE DEVE normalizá-los e ordená-los deterministicamente.
2. O CORE DEVE distinguir fato ausente, indisponível, com erro e presente porém vazio.
3. O Python NÃO DEVE sondar o host; probes e publicação permanecem em Bash.

## REQ-I6-LEGADO — Leitura e comparação

1. QUANDO receber inventário atual ou legado válido, O CORE DEVE produzir o mesmo modelo semântico aplicável.
2. SE a entrada estiver truncada, duplicada, inconsistente ou contiver texto executável, ENTÃO O CORE DEVE recusá-la sem executar conteúdo.
3. QUANDO apenas ordem ou renderização mudar, O DIFF NÃO DEVE relatar mudança física.
4. QUANDO uma identidade física relevante mudar, O SISTEMA DEVE bloquear o plano dependente ou exigir redetecção.

## REQ-DISK-IDENTITY — Identidade de disco

1. QUANDO um disco for selecionado, O SISTEMA DEVE resolver identidade física estável com as evidências já capturadas pelo Bash.
2. SE disco do sistema, workingDisk e HD1 resolverem para o mesmo dispositivo físico em papéis incompatíveis, ENTÃO O SISTEMA DEVE recusar a operação.
3. O SISTEMA DEVE preservar a base atual por `/dev/disk/by-id/`, WWN e serial, tratando a cobertura como parcial até o cruzamento integral dos papéis.
4. Migração de conteúdo NTFS NÃO FAZ PARTE de I6; o workingDisk continua montado externamente pelo operador.

## REQ-USB-IDENTITY — Identidade USB

1. QUANDO um USB for configurado para passthrough, O SISTEMA DEVE usar identidade estável por serial e/ou porta física comprovada, não apenas bus/device efêmeros.
2. SE a identidade estiver ausente, duplicada ou ambígua, ENTÃO O SISTEMA DEVE bloquear a mutação e explicar a evidência insuficiente.
3. QUANDO o dispositivo reaparecer com bus/device diferentes e a mesma identidade comprovada, O SISTEMA DEVE reconhecê-lo como o mesmo dispositivo.
4. O XML candidato DEVE preservar cardinalidade e ser validado semanticamente antes de qualquer efeito Bash.

## REQ-I6-SEGURANCA — Fronteiras

1. O CORE Python DEVE usar somente biblioteca padrão e produzir saída determinística.
2. O Bash DEVE capturar, confirmar, publicar atomicamente, verificar a pós-condição e restaurar em falha.
3. Fixtures DEVEM usar somente dados sintéticos; identificadores locais brutos não devem aparecer em artefatos publicáveis.
4. O status público DEVE continuar `0/1/2/3`, sem converter entrada incerta em sucesso.
