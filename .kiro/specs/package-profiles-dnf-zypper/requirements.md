# Requisitos — Perfis DNF e Zypper

> **Status:** futuro; não há provider operacional DNF/Zypper no estado atual.
> **Escopo:** Fedora Workstation I14.2, openSUSE Tumbleweed I14.5 e Fedora Silverblue diagnóstico I14.6.
> **Dependências:** I8–I10 concluídos, I13 aprovado e `BASE_QUALIFICADA`.
> **Gate:** gate canônico e campanha individual do alvo; nenhuma promoção por fixture.

## Requisito 1 — Alvos permitidos

1. Fedora Workstation mutável DEVE ser tratado somente em I14.2.
2. openSUSE Tumbleweed mutável DEVE ser tratado somente em I14.5.
3. Fedora Silverblue DEVE ser tratado em I14.6 apenas para diagnóstico e recusa segura de mutação tradicional.
4. Nobara, openSUSE Leap, Kinoite, Bazzite e MicroOS NÃO FAZEM PARTE desta spec ativa.
5. Os três alvos NÃO DEVEM ser implementados ou promovidos em conjunto.

## Requisito 2 — DNF/Fedora Workstation

1. O provider DEVE detectar a interface efetiva, incluindo diferenças de DNF5, sem fixar parsing a uma versão única.
2. O provider DEVE separar consulta, refresh, instalação, upgrade e remoção de órfãos.
3. O provider NÃO DEVE habilitar RPM Fusion, COPR ou outro repositório de terceiros.
4. Pacote ausente DEVE bloquear a capability correspondente e explicar a precondição sem alterá-la.
5. Verificações DEVEM usar RPM e pós-condições concretas quando disponíveis.

## Requisito 3 — Zypper/openSUSE Tumbleweed

1. O provider DEVE usar Zypper/RPM com plano explícito e pós-condições.
2. Vendor change, troca de repositório ou substituição inesperada NÃO DEVE ocorrer silenciosamente.
3. O fluxo DEVE detectar `update-bootloader` e outros mecanismos de boot/initramfs em runtime; sua presença isolada não autoriza uso.
4. O provider NÃO DEVE habilitar repositórios externos automaticamente.
5. Somente Tumbleweed comprovado PODE avançar à campanha I14.5.

## Requisito 4 — Segurança e runtime

1. Fedora DEVE resolver SELinux em runtime; openSUSE Tumbleweed DEVE resolver AppArmor em runtime.
2. O perfil PODE sugerir SELinux ou AppArmor, mas evidência contraditória DEVE bloquear a capability.
3. O SISTEMA NÃO DEVE usar `setenforce 0`, desabilitar SELinux/AppArmor ou copiar caminhos de outra distro como workaround.
4. NetworkManager, Wicked, firewalld, dracut, GRUB e `update-bootloader` DEVEM ser resolvidos pela capability efetiva, não pelo nome da distro.

## Requisito 5 — Silverblue

1. QUANDO rpm-ostree/deployment imutável for comprovado, O SISTEMA DEVE retornar diagnóstico explícito e bloquear DNF mutável.
2. O SISTEMA NÃO DEVE remontar `/` ou `/usr`, estratificar pacotes ou oferecer fallback DNF tradicional.
3. I14.6 NÃO DEVE promover suporte mutável.

## Requisito 6 — Fronteiras e qualificação

1. Cálculo de fatos e plano DEVE permanecer no core Python; execução e verificação do host permanecem no Bash.
2. Etapas comuns NÃO DEVEM conter branches ou comandos Fedora/openSUSE específicos.
3. Fixtures DEVEM usar dados sintéticos e comprovar DNF5, Zypper, segurança e imutabilidade sem rede.
4. Suporte `supported` exige campanha real do alvo, registro de versões, providers, capabilities e limitações.
