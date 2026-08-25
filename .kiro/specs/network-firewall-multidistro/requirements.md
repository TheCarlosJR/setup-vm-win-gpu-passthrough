# Requisitos — Rede e firewall multi-distro

> **Status:** transação Netplan/libvirt atual é parcial; I7, I9 e providers I14 permanecem abertos.
> **Escopo:** I7 cria planner backend-neutral; I9 extrai efeitos e fecha Airlock; I14 adiciona providers.
> **Dependências:** I6.0/I6 antes de I7; I8/I9 para providers; I13 antes de I14.
> **Gate:** Gate I7, Gate I9, gate canônico e campanhas individuais I14.

## Requisito 1 — Base I7

1. `libexec/passthrough_core/network.py` DEVE ser criado em I7 para modelar snapshots, CIDR, rotas, intenção e planos determinísticos.
2. Python NÃO DEVE abrir conexões, chamar Netplan/NetworkManager/networkd/Wicked, alterar libvirt ou executar firewall.
3. Bash DEVE capturar estado, confirmar, revalidar fingerprints, aplicar, verificar e restaurar.
4. O planner DEVE permanecer backend-neutral; I7 NÃO DEVE implementar providers de novas distros.
5. A transação existente da etapa 19 DEVE ser preservada e convergida, não substituída sem caracterização.

## Requisito 2 — Recuperação durável

1. Antes do primeiro efeito, O SISTEMA DEVE criar snapshot e bundle local privado da operação.
2. Cada operação DEVE receber `recovery_id` aleatório, não derivado de identificadores locais.
3. Diagnóstico PODE mostrar `recovery_id` e comando de recuperação, mas NÃO DEVE expor caminho completo nem dados locais brutos.
4. Falha, sinal ou ausência de confirmação DEVE executar rollback e verificar semanticamente a restauração.
5. SE o rollback divergir ou falhar, ENTÃO O SISTEMA DEVE manter o bundle conforme retenção definida e retornar erro grave com recuperação orientada.
6. Commit bem-sucedido DEVE remover bundle e mapeamento da operação.

## Requisito 3 — Rede e libvirt

1. Interface, rota, endereço, uplink e ownership DEVEM ser revalidados imediatamente antes da aplicação.
2. Rede NAT só pode ser gerenciada quando possuir marcador explícito; rede homônima externa deve ser preservada e causar recusa.
3. Bridge, XML, MAC, estado ativo/persistente/autostart e VMs consumidoras DEVEM integrar snapshot e fingerprints.
4. Alteração da NIC DEVE usar cardinalidade e pós-condições entregues em I3.
5. ICMP DEVE ser sinal complementar, nunca prova exclusiva.

## Requisito 4 — Efeitos e providers

1. `lib/shell/network-effects.sh` DEVE ser criado em I9 para efeitos, traps e rollback de rede.
2. O baseline Netplan/UFW atual DEVE ser preservado até o cutover; sua existência não comprova abstração completa.
3. NetworkManager, networkd, Wicked e firewalld DEVEM ser implementados somente nos alvos I14 que os exigirem.
4. Backend detectado sem provider qualificado DEVE permanecer diagnóstico/bloqueado, sem fallback Netplan.
5. Cada provider I14 DEVE preservar configurações externas e qualificar rollback em ambiente descartável.

## REQ-AIRLOCK-VERIFY — Verificação semântica

1. Em I9, a verificação Airlock DEVE reutilizar a mesma avaliação efetiva usada na aplicação.
2. `sshd -T -C` DEVE ser executado e comparado semanticamente para usuário, chroot, force command, authorized keys, autenticação e forwarding.
3. UID/GID, grupos, lock/senha, shell/home, ancestrais do chroot, fingerprint da chave, modos, bindfs e IPv4/IPv6 DEVEM ser comprovados.
4. Presença textual de drop-in/regra NÃO DEVE ser aceita como sucesso.
5. Firewall DEVE comprovar regra mínima exata e restaurar somente o escopo gerenciado.
6. Divergência em qualquer pós-condição DEVE retornar pendente/erro, nunca concluído.

## Requisito 6 — Segurança e testes

1. Testes DEVEM usar snapshots, wrappers e namespaces simulados, sem rede/firewall/SSH reais.
2. INT, TERM e EXIT DEVEM ter semântica de rollback testada sem falso commit.
3. Dados locais brutos DEVEM permanecer somente nos stores/IPC autorizados; fixtures publicáveis são sintéticas.
4. Smoke tests reais exigem console fora de banda, ambiente descartável e autorização explícita.
