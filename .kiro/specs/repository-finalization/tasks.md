# Tarefas — Finalização do repositório: I6

> **Status:** I6.0–I6.6 concluídas; Gate I6 aprovado em 23/08/2026.
> **Escopo:** somente I6.
> **Dependências:** executadas na ordem após a aprovação de I6.0 em 23/08/2026.
> **Gate:** testes direcionados e Gate I6 cumulativo aprovados.

- [x] 0. Executar I6.0: rodar `bash tests/run-gate-i1.sh`, repetir a campanha I0 `full` e registrar o resultado na seção 12 do plano.
- [x] 1. Caracterizar em testes os formatos de inventário atual e legado sem alterar o host.
- [x] 2. Definir o schema fechado do snapshot de CPU, memória, PCI, discos, USB, interfaces e boot.
- [x] 3. Implementar `inventory.py` para normalização e ordenação determinística de snapshots recebidos.
- [x] 4. Implementar parsers atual/legado com rejeição de truncamento, duplicata, inconsistência e payload executável.
- [x] 5. Implementar diff semântico que ignore somente ordem e renderização.
- [x] 6. Expor os subcomandos I6 pela CLI e por `lib/python-core.sh`, preservando protocolo e códigos de erro.
- [x] 7. Migrar a etapa 1 para probes/publicação Bash e normalização/comparação Python.
- [x] 8. Migrar a etapa 3 para consumir o snapshot normalizado sem criar segundo caminho mutante.
- [x] 9. Completar REQ-DISK-IDENTITY cruzando sistema, workingDisk e HD1 por identidade física.
- [x] 10. Completar REQ-USB-IDENTITY por serial/porta e integrar a mutação XML cardinalizada existente.
- [x] 11. Acrescentar fixtures sintéticas, testes de convergência e casos de mudança concorrente de I6.
- [x] 12. Criar o manifesto nominal de I6 e integrá-lo ao gate canônico cumulativo.
- [x] 13. Executar Gate I6, revisar fronteiras Bash/Python e registrar evidências e limitações sem promover hardware real.

## Evidências de fechamento

- `bash tests/run-gate-i1.sh`: aprovado; manifesto I6 com 130 arquivos e campanha I0 `full` com 42 grupos.
- `tests/test-python-core.sh`: 546 casos `unittest` aprovados.
- `tests/test-i6-inventory.sh`: inventário/legado/diff, raiz multidisco, identidades clonadas, USB serial/porta, migração, sinais, concorrência e rollback aprovados com fixtures e shims.
- Fronteira Python/Bash, sintaxe Bash/Python e whitespace: aprovados no Gate I6.
- Revisão semântica final: aprovada sem achados acionáveis após as correções.
- Limitações: ShellCheck não estava instalado localmente; a CI versionada o provisiona e exige. Nenhum hardware, serviço, disco, rede, libvirt ou privilégio real foi exercitado ou promovido.
