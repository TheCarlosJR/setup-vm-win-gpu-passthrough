# Design — Perfis DNF e Zypper

> **Status:** desenho futuro de I14; nenhum adaptador implementado.
> **Escopo:** Fedora Workstation, openSUSE Tumbleweed e recusa diagnóstica de Silverblue.
> **Dependências:** core/fachadas estabilizados em I8–I10 e base qualificada em I13.
> **Gate:** um alvo por campanha I14, sempre sobre o gate canônico.

## Arquitetura híbrida

```text
etapas comuns
   |
   +--> lib/python-core.sh --> plataforma/catálogo/plano puros
   |
   +--> módulos de efeitos Bash --> DNF5/DNF, Zypper/RPM e pós-condições
```

Os providers não formam uma segunda árvore de plataforma. Diferenças ficam atrás das fachadas e dos módulos de efeitos estabilizados em I9/I10. Python não executa gerenciadores, serviços ou ferramentas de boot.

## Sequência autorizada

| Fase | Alvo | Resultado permitido |
|---|---|---|
| I14.2 | Fedora Workstation | provider mutável após campanha real |
| I14.5 | openSUSE Tumbleweed | provider mutável após campanha real |
| I14.6 | Fedora Silverblue | diagnóstico e recusa segura |

Nobara, Leap e outros derivados não são candidatos desta spec.

## Fedora Workstation

O provider identifica DNF5/DNF e RPM por capability, sem assumir compatibilidade textual entre versões. NetworkManager, firewalld, SELinux, dracut, GRUB e libvirt são candidatos que precisam evidência runtime. Repositórios externos nunca são habilitados; driver indisponível permanece bloqueado.

## openSUSE Tumbleweed

Zypper separa refresh, plano, confirmação, transação e verificação RPM. Vendor change e mudança de repositório exigem recusa/decisão explícita. AppArmor, Wicked/NetworkManager, firewalld, dracut, GRUB e `update-bootloader` são detectados no runtime. O perfil não copia pressupostos Ubuntu/Fedora.

## Silverblue

Marcadores rpm-ostree/deployment produzem `diagnostic-only`; providers mutáveis de pacote, boot, rede e firewall ficam bloqueados. Não há fallback DNF, remount ou suporte mutável implícito.

## Testes e promoção

Wrappers sintéticos cobrem DNF5/DNF, Zypper/RPM, repositório ausente, vendor change, SELinux/AppArmor, provider alternativo e Silverblue. Fixtures somente validam cálculo e recusa. Cada provider mutável exige VM/host descartável, versão registrada, pós-condições e gate completo; o alvo seguinte não herda promoção por semelhança.
