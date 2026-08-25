# Design — Libvirt, segurança e armazenamento

> **Status:** cálculo puro central entregue em I3; efeitos e providers ainda parciais.
> **Escopo:** manter módulos Python existentes e concluir a separação de efeitos em I9/I14.
> **Dependências:** I6 para identidades, I8 para plataforma, I9 para modularização e I14 para expansão.
> **Gate:** regressões I3 e gates das fases; hardware real permanece evidência separada.

## Arquitetura reconciliada

```text
etapas 9/10/12/14/15/17/21 e utilitários
   |
   +--> lib/python-core.sh
   |       +--> domain_xml.py
   |       +--> network_xml.py
   |       `--> qemu_image.py
   |
   `--> lib/shell/ e etapas
           probes, virsh/qemu-img, segurança, snapshots, aplicação e rollback
```

Não será criada uma segunda árvore de libvirt/segurança/storage. Os módulos de I3 são a fonte para XML/JSON/cálculo puro; Bash mantém efeitos e será modularizado em I9 atrás das fachadas atuais.

## Estado por preocupação

| Preocupação | Estado |
|---|---|
| XML de domínio/cardinalidade | implementado em I3; consumidores ainda precisam convergência |
| XML de rede/marcador | implementado em I3; integrado à transação de rede parcial |
| dados QCOW2 | implementado em I3; efeitos `qemu-img` continuam Bash |
| identidade física de disco/USB | parcial, depende de I6 |
| runtime libvirt e storage | parcial, ainda distribuído em etapas/`common.sh` |
| AppArmor baseline | existente/parcial; abstração residual em I9 |
| SELinux e novos layouts libvirt | futuro nos providers I14 aplicáveis |
| hardware real | não promovido por esta spec |

## Runtime e armazenamento

Bash detecta URI, sockets/unidades, identidade QEMU e capacidades. A conexão funcional prevalece sobre um `is-active` isolado. Preflight distingue ENOENT/EACCES, valida travessia e comprova acesso do operador e QEMU. Alterações de owner/grupo/mode/ACL entram no snapshot e rollback.

## Segurança

AppArmor/SELinux são resolvidos em runtime. Caminhos efetivos determinam regras/contextos; segurança global nunca é desabilitada. Estado desconhecido bloqueia caminhos não padrão. Providers novos só nas fases I14 qualificadas.

## XML e transação

Python conta nós, gera candidato determinístico e preserva conteúdo não gerenciado. Bash valida com ferramenta do host, define, relê XML inativo e compara semanticamente. O journal registra artefatos preexistentes/criados; rollback remove apenas o que a operação criou e preserva QCOW2 preexistente.

Hooks permanecem Bash puro, com `PATH` controlado, instalação atômica, `bash -n`, marcadores fail-closed e nenhuma dependência do checkout/Python.

## Backup e testes

Backup classifica fidelidade do filesystem, inclui manifesto/checksums e não promete POSIX integral em destino incompatível. NVRAM/SWTPM vêm do XML/API. Fixtures cobrem runtime, XML zero/um/múltiplos, permissões e falhas em cada estado. Smoke test real é separado e nunca promove hardware ou distro por si só.
