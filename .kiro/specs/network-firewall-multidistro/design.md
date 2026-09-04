# Design — Rede e firewall multi-distro

> **Status (03/09/2026):** `libexec/passthrough_core/network.py` e a transação da etapa 19 concluídos em I7 (Gate I7 aprovado em 28/08/2026, REQ-NET-TX fechado com `recovery_id` e bundle privado); `lib/shell/network-effects.sh` criado e REQ-AIRLOCK-VERIFY fechado em I9.8 (`tests/test-i9-airlock-verify.sh`). Checkboxes abaixo congelados até o alinhamento formal em I11.4 (tabela de coordenação do `PLANO-FINALIZACAO.md`); não reimplementar o que já existe. NetworkManager/networkd/Wicked/firewalld só em I14.
> **Escopo:** I7 cálculo puro, I9 efeitos/Airlock e I14 providers.
> **Dependências:** I6 aprovado antes de I7; I8/I9/I10 antes de I14.
> **Gate:** rollback semântico em I7/I9 e campanha de provider em I14.

## Arquitetura por fase

```text
etapas 19/20
   |
   +--> lib/python-core.sh
   |       `--> passthrough_core/network.py       plano puro (I7)
   |
   +--> lib/shell/network-effects.sh              efeitos (I9)
   |       `--> provider qualificado por alvo     expansão (I14)
   |
   `--> domain_xml.py / network_xml.py            XML puro já entregue em I3
```

Não será criada uma árvore de rede paralela. I7 modela backend de forma abstrata; I9 extrai o caminho mutante existente; I14 acrescenta somente o provider do alvo em qualificação.

## Estado atual

- **Implementado/parcial:** etapa 60 possui transação Netplan/libvirt e snapshots úteis; etapa 61 aplica configuração Airlock e chama `sshd -T -C` no caminho de aplicação.
- **Ausente em I7:** `network.py`, fingerprints completos, `recovery_id`, bundle/mapeamento durável e planner backend-neutral.
- **Ausente em I9:** `network-effects.sh` e verifier Airlock semântico completo.
- **Futuro I14:** NetworkManager, networkd, Wicked e firewalld, ligados aos alvos que realmente os usam.

## Planner e snapshot

`network.py` recebe snapshots capturados pelo Bash e usa `ipaddress` para validar CIDR, gateway, DHCP, host/VM, broadcast e sobreposição. Produz precondições, operações abstratas, pós-condições e rollback determinísticos. Não conhece comandos ou arquivos de provider.

O snapshot cobre uplink, rotas, links, bridge, configuração do host, rede libvirt, XML/MAC, estado ativo/persistente/autostart e VMs consumidoras. Fingerprints são revalidados antes de aplicar e restaurar.

## Recovery ID e bundle

Bash cria diretório privado e bundle `0600`, gera `recovery_id` aleatório e guarda mapeamento local. Logs exibem somente o ID e comando de recuperação. Commit remove bundle/mapeamento; falha retém pelo prazo normativo. Rollback executa ações em ordem inversa e compara estado semântico; divergência mantém erro grave e orientação.

## Airlock

A aplicação e a verificação compartilham a mesma função de avaliação efetiva. O verifier compara `sshd -T -C`, identidade/lock/grupos do usuário, chroot, chave/fingerprint/modos, bindfs, socket/serviço, regra mínima de firewall e IPv4/IPv6. Arquivo presente ou texto esperado isolado não basta.

## Providers

Netplan/UFW permanecem baseline até o cutover. NetworkManager/networkd/Wicked/firewalld entram somente no provider I14 correspondente. Detecção sem implementação produz diagnóstico, nunca fallback. Smoke tests reais exigem console fora de banda e ambiente descartável.
