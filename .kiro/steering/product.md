# Produto

Este repositório automatiza, por 21 etapas de menu, a preparação e a operação de passthrough de uma VM Windows 11 em host Linux.

## Estado atual

- I0–I5 são entregas históricas; a auditoria de 23/08/2026 confirmou o código correspondente.
- I6.0 foi aprovado em 23/08/2026 após corrigir a regressão preexistente do manifesto de guardas; I6 está liberada e ativa.
- I6–I12 estão abertos ou parciais; I13 exige qualificação operacional real; I14 é expansão posterior à base qualificada.
- O suporte mutável atual é Ubuntu e Pop!_OS, CPU AMD e GPU NVIDIA. Outros alvos permanecem bloqueados ou somente diagnósticos até suas fases e evidências.

## Contratos públicos

Preservar os 21 itens do menu, os entrypoints Bash e o status público: `0=concluído`, `1=pendente`, `2=indeterminado`, `3=erro`. Códigos internos `20=voltar` e `21=sair` não são status públicos.
