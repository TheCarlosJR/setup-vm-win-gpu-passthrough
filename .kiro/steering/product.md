# Produto

Este repositório automatiza, por 21 etapas de menu, a preparação e a operação de passthrough de uma VM Windows 11 em host Linux (KVM/QEMU/libvirt + VFIO), com GPU única NVIDIA e CPU AMD.

## Fonte de verdade

`PLANO-FINALIZACAO.md`, na raiz do repositório, é o único documento normativo. Antes de qualquer tarefa, leia a seção 0.0 ("Comece por aqui"), a auditoria mais recente da seção 1 e a última linha preenchida da seção 12. Estes arquivos de steering apenas resumem; quando divergirem do plano, o plano vence. O bloco "Estado" abaixo é refrescado no mesmo commit que altera o cabeçalho do plano (regra 20 da seção 0.1); se a data dele for anterior à última linha preenchida da seção 12, o plano está à frente e este resumo está atrasado. O plano é executado por Kiro e Claude Code em alternância, nunca ao mesmo tempo (regra 21).

## Estado em 03/09/2026

- I0 a I8 concluídas, cada uma com gate aprovado e registrado (I8 em 28/08/2026).
- I9 (modularização Bash e requisitos P1) está REABERTA por I9.12, REQ-VM-RESOURCE-LIFECYCLE: recursos dedicados à VM voltam ao host quando ela para. Feito: migração do host, núcleo `resources.py`, hooks com aquisição e devolução de memória, contratos das etapas 17 e 18 substituídos. Pendente: teste dirigido da etapa 18, pergunta de `MEMORIA_MODO` na etapa 3, reexecução do Gate I9 com veredito observado.
- I9B (internacionalização en/pt-BR/es) é a próxima fase. A infraestrutura construída em 02/09/2026 foi PERDIDA sem commit; nenhum arquivo dela existe na árvore (`lang/`, `lib/shell/i18n.sh`, `messages.py`, `tests/check-i18n-catalogs.py`). As decisões e medições recuperadas estão na fase I9B do plano.
- I10 a I12 abertas; I13 exige hardware real e autorização do operador; I14, I14B e I14C só após o marco `BASE_QUALIFICADA`.
- Suporte mutável: Ubuntu e Pop!_OS, CPU AMD, GPU NVIDIA. Todo o resto é bloqueado ou somente diagnóstico até prova em campanha real. Fixture aprovada não promove nada.

## Contratos públicos

Preservar os 21 itens do menu, os entrypoints Bash e o status público: `0=concluído`, `1=pendente`, `2=indeterminado`, `3=erro`. Códigos internos `20=voltar` e `21=sair` não são status públicos. Mensagens usadas por testes ou recuperação são API operacional: mudar texto exige teste e documentação juntos.
