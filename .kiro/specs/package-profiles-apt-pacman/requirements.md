# Requisitos — Perfis de pacotes APT e pacman

> **Status (03/09/2026):** baseline APT de Ubuntu/Pop!_OS inalterado; `platform.py` (I8) e os módulos `lib/shell/` (I9) já existem; convergência, gates estáticos e remoção de `xmlstarlet` continuam em I10; providers Debian/Arch/CachyOS só em I14. Checkboxes abaixo congelados até o alinhamento formal em I11.4 (tabela de coordenação do `PLANO-FINALIZACAO.md`); não reimplementar o que já existe.
> **Escopo:** convergência do baseline e providers individuais I14.1/I14.3/I14.4; sem migração NTFS.
> **Dependências:** I8–I10 para contratos; I13 e `BASE_QUALIFICADA` antes de I14.
> **Gate:** gate canônico, gates estáticos de I10 e campanha real por alvo I14.

## Requisito 1 — Contrato de capabilities

1. As etapas comuns DEVEM solicitar capabilities e pós-condições, não presumir pacotes literais.
2. Python PODE resolver catálogo e plano puro; Bash DEVE executar o gerenciador, confirmar e verificar.
3. Pacote virtual ou transitório NÃO DEVE ser considerado instalado sem a capability concreta.
4. Falta de candidato DEVE bloquear antes do primeiro efeito e listar a capability ausente.

## Requisito 2 — Baseline APT

1. Ubuntu e Pop!_OS DEVEM preservar o comportamento mutável atual enquanto chamadas APT diretas forem convergidas.
2. Ubuntu NÃO DEVE selecionar componentes System76; Pop!_OS só pode fazê-lo com `ID=pop` e evidência válida.
3. QEMU/virt-install DEVEM ser verificados por executáveis e capabilities concretas, não por alias.
4. `xmlstarlet` DEVE ser tratado somente como compatibilidade transitória residual até I10; não é capability operacional futura.
5. I10 SÓ DEVE remover `xmlstarlet` depois de comprovar busca vazia de consumidores; `virt-xml-validate` permanece.

## Requisito 3 — Expansão individual

1. Debian DEVE ser implementado e qualificado isoladamente em I14.1, sem habilitar repositórios externos automaticamente.
2. Arch Linux DEVE ser implementado e qualificado isoladamente em I14.3, sem atualização parcial insegura.
3. CachyOS DEVE ser implementado e qualificado isoladamente em I14.4, herdando apenas contratos comprovados do provider Arch.
4. Derivados não qualificados DEVEM permanecer `family-unverified` ou bloqueados.
5. Nenhum desses alvos PODE ser promovido em conjunto nem antes de I13 e `BASE_QUALIFICADA`.

## Requisito 4 — NVIDIA e hardware

1. A estratégia DEVE validar o vendor e o BDF da GPU antes de resolver driver.
2. Ubuntu DEVE usar a estratégia oficial comprovada; Pop!_OS PODE usar System76 somente no perfil exato.
3. Arch/CachyOS DEVEM considerar kernel e módulo apenas em suas fases I14.
4. Secure Boot ou pós-condição de módulo não comprovada DEVE bloquear sucesso.
5. A spec NÃO promove hardware real; GPU NVIDIA permanece o único baseline atual.

## Requisito 5 — Bootstrap e fronteiras

1. Ferramentas de inventário DEVEM estar disponíveis antes do primeiro uso operacional, sem instalação automática em diagnóstico.
2. Saída analisada DEVE usar formato de máquina ou locale controlado.
3. Após I10, gates DEVEM impedir chamadas operacionais de gerenciador fora dos módulos de efeitos autorizados.
4. Instalação parcial DEVE informar pós-condições atendidas e ausentes; rollback automático de pacotes não é presumido.

## Requisito 6 — Fora de escopo

1. Migração de dados ou montagem NTFS NÃO FAZ PARTE deste spec; workingDisk permanece responsabilidade operacional externa.
2. Boot, initramfs, rede, firewall e segurança NÃO DEVEM ser inferidos pelo provider de pacotes.
3. Repositórios de terceiros NÃO DEVEM ser habilitados automaticamente.
