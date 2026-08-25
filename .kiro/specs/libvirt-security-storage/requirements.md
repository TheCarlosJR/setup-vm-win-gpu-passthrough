# Requisitos — Libvirt, segurança e armazenamento

> **Status:** núcleo XML/JSON e QCOW2 implementado em I3; efeitos/modularização e providers permanecem parciais/futuros.
> **Escopo:** preservar entregas I3, fechar deltas operacionais e modularizar efeitos em I9; sem promoção de hardware real.
> **Dependências:** I3 histórico, I6 para identidades, I8 para plataforma, I9 para módulos shell e I14 para novos providers.
> **Gate:** regressões I3, gates das fases aplicáveis e campanhas reais separadas.

## Requisito 1 — Entregas preservadas de I3

1. `domain_xml.py` DEVE continuar responsável por parsing/mutação XML de domínio, cardinalidade e preservação de conteúdo não gerenciado.
2. `network_xml.py` DEVE continuar responsável por XML de rede e marcador/semântica gerenciada.
3. `qemu_image.py` DEVE continuar responsável por parsing/validação pura de dados de imagem.
4. Python NÃO DEVE chamar `virsh`, `qemu-img`, `virt-xml-validate`, serviços ou ferramentas do host.
5. Bash DEVE validar candidatos, aplicar, reler estado e comprovar pós-condições.

## Requisito 2 — Runtime e efeitos

1. Runtime libvirt monolítico/modular/socket-activated DEVE ser resolvido por evidência, sem nome fixo nas etapas.
2. URI, serviços/sockets e estado anterior DEVEM ser capturados antes de qualquer alteração.
3. A modularização residual DEVE ocorrer em `lib/shell/` durante I9, preservando fachadas e sem recriar cálculo XML no Bash.
4. Falta ou ambiguidade de provider DEVE bloquear mutação e manter diagnóstico.

## Requisito 3 — Identidade e storage

1. O SISTEMA NÃO DEVE presumir usuário/grupo QEMU fixo.
2. Acesso do operador e da identidade QEMU a diretórios, QCOW2 e ISOs DEVE ser comprovado separadamente.
3. Falta de arquivo e falta de travessia/permissão DEVEM ser distinguidas.
4. Owner, grupo, modo e ACL alterados DEVEM integrar snapshot e rollback.
5. Identidade cruzada de discos depende de REQ-DISK-IDENTITY em I6 e permanece parcial até seu gate.

## Requisito 4 — Segurança MAC e capabilities

1. AppArmor, SELinux, nenhum MAC e estado desconhecido DEVEM ser detectados no runtime.
2. O SISTEMA NÃO DEVE desabilitar globalmente AppArmor/SELinux.
3. Caminhos não padrão DEVEM bloquear quando a política não puder ser comprovada.
4. Firmware, NVRAM, TPM, máquina e dispositivos DEVEM ser descobertos por capabilities/domcapabilities, não por caminho fixo.
5. Providers SELinux/libvirt de novas distros pertencem aos alvos I14 correspondentes.

## Requisito 5 — Transações e XML

1. Criação/alteração DEVE validar storage, ISOs, segurança, rede, firmware e XML antes de definir domínio.
2. A transação DEVE distinguir artefatos preexistentes dos criados e nunca remover storage preexistente no rollback.
3. Toda mutação XML DEVE exigir cardinalidade antes/depois e reler o XML inativo após aplicação.
4. Anti-Code43, hostdev, USB, pinning e discard NÃO DEVEM declarar sucesso quando a pós-condição faltar.
5. Hooks DEVEM permanecer Bash puro, atômicos, sintaticamente validados e fail-closed.

## Requisito 6 — Backup, snapshot e QCOW2

1. Garantias de backup DEVEM refletir capacidades reais de sparse, owner/group, mode, ACL, xattrs e hardlinks.
2. Destino não POSIX NÃO DEVE receber promessa de fidelidade POSIX integral sem encapsulamento comprovado.
3. NVRAM/SWTPM DEVEM ser descobertos por XML/API e incluídos em manifesto verificável.
4. Unidades e cálculo de espaço QCOW2 DEVEM usar o mesmo conjunto validado e evitar overflow.
5. Cadeia QCOW2 e estado da VM DEVEM ser verificados antes/depois.

## Requisito 7 — Evidência e hardware

1. Fixtures DEVEM cobrir XML, runtime, segurança, permissões e falhas transacionais com dados sintéticos.
2. Teste hermético NÃO DEVE promover GPU, CPU, distro, storage ou libvirt reais.
3. Smoke tests reais só podem ocorrer em ambiente descartável, com autorização e registro de limitações.
4. O baseline de hardware permanece AMD/NVIDIA; demais eixos continuam bloqueados até I14B/I14C.
