# Design — Finalização do repositório: I6

> **Status:** desenho proposto; nenhuma implementação I6 realizada.
> **Escopo:** normalização, comparação e identidade física; efeitos continuam no Bash existente.
> **Dependências:** I6.0 aprovado e contratos I0–I5 preservados.
> **Gate:** Gate I6 mais gate canônico cumulativo.

## Arquitetura

```text
etapas 1/3/14/15 e fachadas Bash
        |
        | snapshots, arquivos controlados e escalares validados
        v
lib/python-core.sh
        |
        v
libexec/passthrough_core_cli.py
        |
        v
libexec/passthrough_core/inventory.py
```

`inventory.py` fará parsing, normalização, validação, ordenação e diff semântico. `domain_xml.py` continua responsável pelas transformações XML já entregues em I3. Bash continua responsável por probes, seleção interativa, snapshots, publicação atômica, comandos do host, pós-condições e rollback. Nenhum segundo entrypoint Python ou caminho mutável paralelo será criado.

## Modelo de inventário

O snapshot representa CPU, memória, PCI, discos e suas identidades, USB, interfaces e boot. Cada fato carrega estado tipado (`presente`, `ausente`, `indisponível`, `erro`, `vazio`) e evidência sintética nos testes. Coleções são ordenadas por chave semântica, nunca pela ordem textual da captura.

O parser aceita os formatos atual e legado comprovados pelos fixtures. Entrada truncada, duplicada, inconsistente ou com conteúdo executável é dado inválido. O diff separa mudança física de mudança de formato/renderização.

## Disco

A resolução reaproveita a base atual por `/dev/disk/by-id/`, `ID_WWN_WITH_EXTENSION`, `ID_WWN` e `ID_SERIAL`. O plano compara a identidade física dos papéis sistema, workingDisk e HD1 e recusa alias incompatível. O Python decide sobre snapshots; o Bash revalida o host imediatamente antes de aplicar.

## USB

O modelo combina vendor/product com serial e/ou caminho de porta física. Bus e device são observações efêmeras, não identidade. Zero, múltiplos candidatos ou evidência conflitante bloqueiam a operação. A mutação XML continua cardinalizada em `domain_xml.py`; a etapa Bash aplica e relê o XML.

## Publicação e recuperação

Relatórios continuam com nome histórico e symlink relativo, publicados atomicamente. Candidatos e temporários ficam em escopo controlado. Em falha depois do primeiro efeito, Bash restaura e comprova a pós-condição; falha de restauração mantém estado de erro.

## Testes

- caracterização dos formatos atual e legado;
- ordem textual invariante e serialização determinística;
- truncamento, duplicata, inconsistência e payload hostil;
- alias entre sistema, workingDisk e HD1;
- USB estável após renumeração e USB ambíguo;
- fronteira Python sem comandos do host;
- segunda execução convergente sem alteração;
- gate canônico e Gate I6 sem tocar hardware real.
