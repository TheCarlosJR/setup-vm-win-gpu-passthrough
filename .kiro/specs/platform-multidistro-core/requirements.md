# Requisitos — Núcleo de plataforma multi-distro

> **Status (03/09/2026):** I8 APROVADO em 28/08/2026: `libexec/passthrough_core/platform.py` existe e é o resolvedor por trás de `lib/platform.sh` (I8.4), eixos de CPU e GPU modelados como fatos tipados (I8.7/I8.8), backend libvirt resolvido pelo core (I8.6), 11 fixtures em `tests/test-i8-platform.sh`; os classificadores em Bash foram removidos. Checkboxes abaixo congelados até o alinhamento formal em I11.3 (tabela de coordenação do `PLANO-FINALIZACAO.md`); não reimplementar o que já existe. Nenhuma distro foi promovida.
> **Escopo:** detecção somente leitura, fatos/capabilities e eixos de suporte; não implementa providers de I14.
> **Dependências:** I6.0, I6 e I7 aprovados antes de I8; I14 somente após I13 e `BASE_QUALIFICADA`.
> **Gate:** Gate I8 mais `bash tests/run-gate-i1.sh`; fixtures não promovem suporte.

## Estado reconciliado

O suporte mutável atual é somente Ubuntu/Pop!_OS, CPU AMD e GPU NVIDIA. Distribuições reconhecidas sem provider qualificado continuam em diagnóstico ou bloqueadas. Os estados fechados são `supported`, `diagnostic-only`, `family-unverified` e `blocked`. Campos públicos de plataforma usam o prefixo `PLATAFORMA_*`; a fachada Bash atual permanece compatível durante o cutover.

## Requisito 1 — Detecção segura

1. QUANDO a plataforma for resolvida antes do menu, O SISTEMA DEVE usar apenas evidências capturadas sem efeitos.
2. ENQUANTO a detecção estiver em execução, O SISTEMA NÃO DEVE usar `sudo`, instalar pacotes, alterar serviços, boot, rede ou firewall.
3. QUANDO receber `os-release`, O PARSER DEVE aceitar somente campos permitidos e manter `source`, `eval` e substituições inertes.
4. SE a evidência estiver ausente, malformada ou conflitante, ENTÃO O SISTEMA DEVE bloquear a capability afetada e explicar o motivo.

## Requisito 2 — Modelo normalizado

1. O SISTEMA DEVE representar identidade, família, versão, arquitetura, mutabilidade e perfil em campos `PLATAFORMA_*`.
2. O SISTEMA DEVE manter origem e estado tipado da evidência, sem default silencioso.
3. Pacotes, boot, initramfs, rede, MAC, firewall, libvirt, CPU e GPU DEVEM ser eixos/capabilities separados.
4. Python DEVE receber snapshots do Bash; `platform.py` NÃO DEVE abrir arquivos do host nem executar comandos.

## Requisito 3 — Resolução conservadora

1. QUANDO `ID` exato tiver suporte comprovado, O SISTEMA DEVE preferi-lo a `ID_LIKE`.
2. QUANDO apenas a família for reconhecida, O SISTEMA DEVE usar `family-unverified` sem liberar mutações.
3. QUANDO o alvo for reconhecido sem provider qualificado, O SISTEMA DEVE usar `diagnostic-only`.
4. QUANDO houver conflito, imutabilidade ou requisito não atendido, O SISTEMA DEVE usar `blocked` na capability correspondente.
5. O SISTEMA NÃO DEVE introduzir estado `experimental` fora dessa enumeração.

## Requisito 4 — Baseline e expansão

1. I8 DEVE preservar exatamente o comportamento permitido de Ubuntu/Pop!_OS e os bloqueios atuais.
2. I8 DEVE modelar CPU e GPU como eixos independentes sem habilitar Intel ou GPUs não NVIDIA.
3. Debian, Fedora Workstation, Arch, CachyOS e openSUSE Tumbleweed DEVEM permanecer sem mutação até seus alvos individuais de I14.
4. Fedora Silverblue DEVE permanecer somente diagnóstico e fail-closed.
5. Nenhum alvo de I14 PODE ser promovido antes de I13 e `BASE_QUALIFICADA`, nem por fixture.

## Requisito 5 — Integração e compatibilidade

1. `lib/platform.sh` DEVE permanecer fachada compatível até o cutover de I8.
2. A implementação pura futura DEVE residir em `libexec/passthrough_core/platform.py` e ser invocada somente por `lib/python-core.sh`.
3. Providers mutáveis e efeitos DEVEM continuar no Bash; não deve surgir árvore mutável paralela.
4. `BOOTLOADER` existente DEVE ser tratado como enum/configuração e override legado, nunca como prova runtime suficiente.
5. Opções incompatíveis DEVEM ser bloqueadas antes do primeiro efeito, preservando diagnóstico somente leitura.

## Requisito 6 — Testabilidade e segurança

1. Fixtures DEVEM cobrir Ubuntu, Pop!_OS, alvos diagnósticos, derivada, desconhecida, imutável e payload hostil.
2. Testes DEVEM provar determinismo, malícia inerte, ausência de mutação e redução de confiança em conflito.
3. A comparação diferencial temporária com a fachada Bash DEVE ser removida no cutover.
4. A promoção de suporte DEVE exigir campanha operacional real do alvo correspondente.
