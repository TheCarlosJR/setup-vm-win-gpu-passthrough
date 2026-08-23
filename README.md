# Setup VM Windows com GPU Passthrough

Scripts de instalação e configuração da VM Windows (Windows 11) com GPU em passthrough (KVM/QEMU/libvirt + VFIO).
As etapas que alteram estado persistente descrevem seu impacto, pedem confirmação nos passos destrutivos e, quando aplicável, oferecem backup, rollback ou um modo `--verificar`.
Consulte as limitações de cada etapa antes de executá-la em um host de uso diário.

### Documentação

| Documento | Quando usar |
|---|---|
| **[Guia-QEMU-Passthrough.md](Guia-QEMU-Passthrough.md)** | leitura principal: o caminho completo, direto, focado em instalar e configurar o QEMU |
| **[troubleshooting.md](troubleshooting.md)** | diagnóstico por sintomas, recuperação segura, escopo dos backups e rollback das etapas |

**Ambiente de referência:** AMD Ryzen 7 5700X, NVIDIA RTX 3060 (GPU única),
32 GB DDR4, ASUS TUF Gaming B550-Plus WiFi II, Pop!_OS (host), Windows 11
(convidado, KVM/QEMU/libvirt, VFIO single-GPU passthrough). Os scripts detectam
o hardware real: nenhum valor é chumbado.

> AVISO: estes scripts alteram fstab, parâmetros de kernel, rede, firewall e
> a definição da VM. Leia a seção correspondente do guia antes de cada etapa.

---

## Estrutura

```
popos-win11-passthrough/
├── README.md                    visão geral, fluxo e testes
├── Guia-QEMU-Passthrough.md     instalação e configuração
├── troubleshooting.md           diagnóstico, recuperação e rollback
├── passthrough.conf.example     modelo da configuração central
├── passthrough.conf             (gerado pela etapa 3; valores do SEU hardware)
├── menu.sh                      orquestrador com status ao vivo das etapas
├── lib/
│   ├── common.sh                    funções compartilhadas
│   └── platform.sh                  detecção e perfil da plataforma
├── backups/                     (gerado) backups locais de XML/configuração
├── etapas/                      uma etapa = uma fase do fluxo (nº = etapa do menu)
│   ├── 00-inventario.sh             1  inventário de hardware
│   ├── 01-verificar-bios.sh         2  checklist BIOS + verificação
│   ├── 02-detectar-config.sh        3  detecta hardware/uplink e configura o host
│   ├── 10-atualizar-sistema.sh      4  update + fwupd                    <reboot>
│   ├── 11-driver-nvidia.sh          5  driver NVIDIA no host             <reboot>
│   ├── 12-pacotes-base.sh           6  utilitários (+xmlstarlet)
│   ├── 13-diretorios.sh             7  prepara /vm
│   ├── 14-working-disk.sh           8  preflight do workingDisk externo
│   ├── 20-virtualizacao.sh          9  KVM/QEMU/libvirt/OVMF/swtpm
│   ├── 21-usuario-grupos.sh         10 grupos + permissões               <logout>
│   ├── 30-iommu-vfio.sh             11 IOMMU + VFIO                      <reboot>
│   ├── 40-criar-vm.sh               12 VM + NAT default temporária
│   ├── 41-instalacao-windows.sh     13 instalação e pós-instalação do Windows
│   ├── 50-hooks-gpu-hd1.sh          14 hooks dinâmicos + HD1
│   ├── 51-usb-passthrough.sh        15 USB: dispositivos ou controladora (opcional)
│   ├── 55-driver-nvidia-vm.sh       16 driver NVIDIA na VM (automático)
│   ├── 52-cpu-pinning-hugepages.sh  17 pinning + HugePages               <reboot>
│   ├── 53-cpu-isolation.sh          18 isolcpus                          <reboot>
│   ├── 60-rede-bridge.sh            19 rede final: bridge Ethernet ou NAT
│   ├── 61-airlock.sh                20 SFTP seguro em bridge/NAT
│   └── 70-trim-discard.sh           21 TRIM/discard
├── util/                        operação contínua e emergência
│   ├── listar-grupos-iommu.sh       inspeciona grupos IOMMU
│   ├── snapshot-vm.sh               cria/lista/reverte/apaga snapshots
│   ├── backup-vm.sh                 backup offline da VM
│   ├── atualizar-host.sh            atualização e validação do host
│   ├── diagnostico.sh               relatório de diagnóstico
│   └── recuperar-gpu.sh             emergência: GPU de volta ao Linux
├── tests/                       testes herméticos e fixtures
└── windows/                     rodar DENTRO da VM (PowerShell como admin)
    ├── Desativar-Fast-Startup.ps1
    ├── Ativar-MSI-GPU.ps1
    └── Gerar-Chave-Airlock.ps1
```

---

## Versionamento por script e logs de ação

Cada script executável (`menu.sh`, `etapas/*.sh`, `util/*.sh`) declara uma
constante `SCRIPT_VERSION="X.Y.Z"` no topo, exibida pelo menu ao lado de cada
item. Regra de incremento a cada mudança no arquivo: **X** quando o fluxo ou o
contrato do script muda de forma incompatível; **Y** quando ganha funcionalidade
nova compatível; **Z** para correções e ajustes internos. A `lib/common.sh` usa
`LIB_COMMON_VERSION` com a mesma regra.

As ações do lado do HOST ficam registradas em dois logs locais, com rotação
simples em 1 MiB:

- `~/.local/state/vm-passthrough/acoes.log`: etapas e utilitários (ativado em
  execução interativa ou com `VM_PASSTHROUGH_LOG=1`; `=0` desliga);
- `/var/log/vm-passthrough/hooks.log`: os hooks do libvirt (prepare/start/
  release), gravado com sync linha a linha para sobreviver a travamentos e
  legível pelo grupo `adm` sem sudo. É a linha do tempo para diagnosticar a
  retomada da GPU (tela preta/sem sinal ao desligar a VM).

Privacidade por contrato: os logs registram somente eventos do host (drivers,
hooks, systemd, virsh, XML). Nunca registram conteúdo, tela, teclado, rede ou
qualquer dado de dentro da VM, e nada sai da máquina.

---

## Como usar

### 1. Levar os scripts para o Pop!_OS

Por pendrive, `scp` ou git. Depois, no Pop!_OS:

```bash
cd ~/popos-win11-passthrough
chmod +x menu.sh lib/common.sh etapas/*.sh util/*.sh   # opcional; o menu usa "bash script"
```

Os arquivos já estão com line endings LF. Se algum editor no Windows os
converter para CRLF, corrija com `sed -i 's/\r$//' arquivo.sh` (ou dos2unix).

### 2. Pré-requisitos manuais (fora do alcance de script)

1. **BIOS configurada** antes de tudo (etapa 2 mostra o checklist: SVM,
   IOMMU, Above 4G, Re-Size BAR, CSM off, Secure Boot "Other OS").
2. **Pop!_OS já instalado** em modo UEFI, com o driver NVIDIA proprietário
   funcionando (`nvidia-smi` responde). Ver "Sistema esperado" no
   [guia](Guia-QEMU-Passthrough.md).
3. **ISOs baixadas dos canais oficiais**: Windows 11 (microsoft.com) e
   virtio-win.iso (projeto oficial virtio-win). Nunca de espelhos.
4. **Conectividade física disponível**: Ethernet permite `bridge` ou `nat`;
   Wi-Fi station usa obrigatoriamente `nat`. Bridge Wi-Fi normalmente exige
   4addr/WDS dos dois lados e não é suportada. Reserva no roteador só existe no
   modo bridge; no NAT a etapa 19 cria a reserva DHCP libvirt automaticamente.
5. **workingDisk opcional já montado**, se for usado: o operador cria e monta
   externamente o caminho (por exemplo, `/mnt/workingDisk`) antes da etapa 3.
   O projeto apenas verifica o mountpoint; não o cria, monta, formata nem grava
   sua montagem no `fstab`.

### Senha do sudo

O `menu.sh` pede a senha do sudo **uma vez**, no início, e mantém a sessão
renovada em segundo plano enquanto estiver aberto (as etapas filhas herdam
essa autorização). A senha nunca é gravada em arquivo: o que é renovado é o
ticket do próprio `sudo`. Etapas rodadas fora do menu pedem a senha na
primeira necessidade e se comportam do mesmo jeito.

### 3. Rodar pelo menu (recomendado)

```bash
bash menu.sh
```

O menu mostra `[ok]`/`[  ]` por etapa consultando o sistema de verdade. Cada
etapa implementa seus próprios critérios no modo `--verificar`. Execute as etapas
em ordem; após cada `<reboot>`/`<logout>`, abra o menu de novo e continue do ponto
em que parou.

Também dá para rodar cada etapa direto, sem menu:

```bash
bash etapas/30-iommu-vfio.sh              # executa a etapa 11
bash etapas/30-iommu-vfio.sh --verificar  # só verifica (código de saída 0 = ok)
bash menu.sh --status                     # checklist completo sem menu
```

**Numeração.** A etapa é sempre o número do menu, de 1 a 21, e é assim que a
documentação e as mensagens dos scripts se referem a ela. O nome do arquivo em
`etapas/` mantém uma numeração histórica diferente (a etapa 11 é
`30-iommu-vfio.sh`); a tabela da seção 4 e a árvore acima fazem a tradução.
Etapas com vários blocos internos os anunciam como `Etapa N.x`, por exemplo
`Etapa 3.1/8 Identidade` ou o sub-passo `13.15` do driver NVIDIA.

### 4. Ordem completa (com pontos de parada)

| # | Etapa | Observação |
|---|-------|-----------|
| 1 | `00-inventario` | coleta somente dados do hardware (pede sudo para `dmidecode`/`dmesg`) e publica um relatório único; guarde uma cópia fora do disco do sistema |
| 2 | `01-verificar-bios` | manual + verificação; refaça até tudo passar |
| 3 | `02-detectar-config` | usa o último inventário completo, faz backup e reinicia todas as escolhas de GPU/workingDisk/disco da VM/CPU/RAM/bootloader/rede |
| 4 | `10-atualizar-sistema` | **reboot** ao final |
| 5 | `11-driver-nvidia` | **reboot** se instalar; valida `nvidia-smi` |
| 6 | `12-pacotes-base` | inclui xmlstarlet (edição segura de XML) |
| 7 | `13-diretorios` | cria e converge somente `/vm` |
| 8 | `14-working-disk` | preflight não destrutivo do mountpoint externo; sucesso imediato quando dispensado |
| 9 | `20-virtualizacao` | pilha completa + `kvm-ok` |
| 10 | `21-usuario-grupos` | **logout/login** obrigatório ao final |
| 11 | `30-iommu-vfio` | `Etapa 11.1/2` (fase A) aplica parâmetros, **reboot**, rodar de novo para a `Etapa 11.2/2` (fase B) validar e registrar o grupo IOMMU |
| 12 | `40-criar-vm` | cria qcow2 + AppArmor + VM via virt-install, já com o canal virtio `org.qemu.guest_agent.0`; a NIC nasce em NAT `default` temporária e seu MAC é persistido; abra o console no "Press any key..." |
| 13 | `41-instalacao-windows` | manual, em sub-passos `13.1` a `13.17`: instalação (driver `viostor\w11\amd64` na tela de discos, guest-tools) e pós-instalação (Fast Startup; o driver NVIDIA do `13.15` tem caminho automático na etapa 16, depois da etapa 14) |
| 14 | `50-hooks-gpu-hd1` | hooks com os IDs reais + GPU (e disco físico, se houver) no XML; teste o ciclo ligar/desligar |
| 15 | `51-usb-passthrough` | opcional; dispositivos individuais (vendor:product, inclui adaptadores Bluetooth) ou uma controladora USB PCI inteira com hotplug nativo nas portas dela |
| 16 | `55-driver-nvidia-vm` | instala o driver NVIDIA dentro do Windows sem monitor dedicado: baixa o pacote oficial, injeta o `qemu-guest-agent` no QCOW2 se faltar, dispara unidade systemd que liga a VM, instala silenciosamente (`-s -noreboot` via guest-exec), confirma no convidado e desliga |
| 17 | `52-cpu-pinning-hugepages` | XML + parâmetros de kernel; **reboot** |
| 18 | `53-cpu-isolation` | isolcpus; **reboot**; MSI se aplica dentro do Windows (`windows/Ativar-MSI-GPU.ps1`) |
| 19 | `60-rede-bridge` | aplica o modo escolhido: bridge somente em Ethernet (`netplan try` + reservas no roteador) ou NAT dedicado Ethernet/Wi-Fi (sem Netplan, reserva libvirt automática) |
| 20 | `61-airlock` | depende da etapa 19; SFTP chroot + ufw na `REDE_BRIDGE` ou `REDE_BRIDGE_LIBVIRT`; chave gerada NA VM e instalada com `--instalar-chave` |
| 21 | `70-trim-discard` | discard=unmap + pasta de backups |

### 5. Configuração central

Todos os valores do seu hardware moram em `passthrough.conf`. A opção 3 e a
execução direta de `etapas/02-detectar-config.sh` sempre criam um backup restrito
em `backups/`, limpam atomicamente as escolhas administradas pela etapa e
recomeçam em `Etapa 3.1/8 Identidade`; `--redetectar` é um alias compatível do mesmo
comportamento. `--verificar` apenas lê e não altera conteúdo nem data do arquivo.
Opções externas ao fluxo, como `QCOW2_PATH`, nomes de bridge, `VM_NIC_MAC`,
`AIRLOCK_BIND` e destinos de backup, são preservadas.

O que é configurável sem editar script: nome e RAM/CPU da VM, caminho e tamanho
do QCOW2, mountpoint externo opcional do workingDisk (`WORKING_DISK_PATH`),
dispensa explícita (`WORKING_DISK_DISPENSADO=sim`), pasta de trânsito do
airlock (`AIRLOCK_DIR`), visão exposta pelo SFTP (`AIRLOCK_BIND`) e destino
dos backups (`BACKUPS_VM_DIR`). `WORKING_DISK_PATH` precisa ser absoluto,
existir e ser exatamente um mountpoint já ativo; o projeto não cria sua base,
não monta, não descobre dispositivo/UUID e não escreve uma entrada de montagem
no `fstab`. `BACKUPS_VM_DIR` explícito tem prioridade; sem ele, o fallback é
`$WORKING_DISK_PATH/backups-vm` somente quando o workingDisk está configurado.
Também são configuráveis o usuário de transferência, uplink físico e modo de
rede. Os campos principais são `REDE_MODO`, `INTERFACE_FISICA`, `REDE_BRIDGE`,
`REDE_LIBVIRT`, `REDE_BRIDGE_LIBVIRT`, `REDE_NAT_CIDR` e `VM_NIC_MAC`.
`VM_IP_FIXO` é a reserva da VM nos dois modos; `IP_FIXO_HOST` é o endereço que a
VM usa para chegar ao host (IP LAN da bridge ou gateway virtual no NAT).

A etapa 3 sempre mostra **todas** as interfaces físicas elegíveis e destaca o
dispositivo retornado por `ip -4 route get 1.1.1.1` (consulta local: nenhum
pacote é enviado). No NAT, `INTERFACE_FISICA` precisa ser exatamente esse uplink
IPv4 efetivo: a etapa 3 avisa uma divergência, e a etapa 19 aborta antes de
qualquer mutação — inclusive do `passthrough.conf` — até o adaptador escolhido
virar a rota padrão ou o outro ser desconectado/ter sua métrica ajustada. Ao
trocar o uplink mantendo bridge, a etapa 3 limpa os IPs reservados da LAN
anterior.

A bridge usa exclusivamente `/etc/netplan/90-vm-passthrough-bridge.yaml`, sem
impor `renderer` e sem substituir os demais YAMLs; portanto Wi-Fi e interfaces
não relacionadas permanecem como estavam. Se o arquivo dedicado já existir,
ele recebe backup datado. Antes da primeira escrita, a etapa arma rollback: uma
falha em `netplan generate`, `try`, `apply` ou em qualquer passo posterior
restaura/remove o dedicado, reaplica o Netplan anterior e restaura o XML da VM.

No modo bridge, o commit estrutural cobre o Netplan aplicado, a `REDE_BRIDGE`
administrativamente `UP`, a `INTERFACE_FISICA` anexada como porta (com a bridge
como `master`) e a NIC da VM em `source bridge`. `VM_IP_FIXO` e `IP_FIXO_HOST`
podem permanecer pendentes sem desfazer essa estrutura; enquanto não estiverem
efetivos e coerentes, `bash etapas/60-rede-bridge.sh --verificar` e, por
dependência, a etapa `61-airlock` permanecem pendentes.

O NAT **não altera o uplink nem lê/modifica Netplan**. Ele cria uma bridge
virtual, uma instância `dnsmasq` para DHCP/DNS e regras de encaminhamento/NAT no
host por meio de uma rede libvirt dedicada. A etapa só atualiza uma
`REDE_LIBVIRT` com o marcador deste projeto; uma homônima sem marcador nunca é
alterada. Antes da primeira mutação, captura XML, existência/persistência,
estados ativo/autostart da rede, XML da VM e `passthrough.conf`. Rede, troca da
fonte da NIC e persistência formam uma transação única: qualquer falha ou sinal
restaura todos esses estados; uma criação parcial é destruída e removida. A
sub-rede `/24` também é recusada diante de qualquer rota sobreposta, exceto as
rotas `proto kernel` exatas da própria sub-rede gerenciada.

Na migração NAT → bridge, a etapa inspeciona o XML inativo de **todas** as outras
VMs definidas, ligadas ou desligadas, procurando `source network` ou `source
bridge`. Se houver consumidores, lista-os e recusa antes de tocar Netplan. Sem
consumidores, desabilita o autostart, para a rede gerenciada e, no sucesso,
mantém sua definição inativa; o rollback restaura o estado anterior. Uma rede
homônima sem marcador é apenas avisada e preservada. Na direção bridge → NAT,
remova ou restaure o arquivo dedicado e rode `sudo netplan apply` antes da etapa
18; o NAT não desfaz Netplan e recusa uplink ainda escravizado a uma bridge.

`VM_NIC_MAC` identifica a NIC sem depender de posição. Em configurações antigas,
a etapa conta todas as `/domain/devices/interface`: só escolhe automaticamente
se houver uma; com várias, apresenta todas e apenas marca `network=default` como
**RECOMENDADA**. Os IPs precisam estar efetivos e coerentes, e `--verificar`
repete inclusive a trava do uplink NAT.

#### Travas de segurança da etapa 3

Escolhas que poderiam inutilizar o host são impedidas na origem, não avisadas
depois:

| Recurso | Trava |
|---|---|
| GPU | com uma única GPU, explica que o desktop Linux sai do ar durante a VM e exige confirmação; com duas ou mais, obriga a escolher qual vai para a VM |
| CPU | teto de núcleos: o host sempre fica com 1 (2 quando há 6+ núcleos) |
| RAM | teto = total menos a reserva do host (25% do total, entre 4 e 8 GiB); valor sempre múltiplo de 1 GiB por causa das HugePages |
| Disco da VM | o disco da **raiz do Linux** e qualquer disco com partição montada/em uso são recusados; **"nenhum" é opção válida** (a VM fica só com o QCOW2). O workingDisk não é tratado como identidade de disco físico persistida. |
| Áudio HDMI | se a placa não expõe a função, segue somente com vídeo em vez de abortar |
| Rede | sempre enumera todas as interfaces físicas, destaca a rota IPv4 efetiva obtida por `ip route get`, rejeita bridge Wi-Fi e avisa NAT em outro uplink; trocar o uplink da bridge limpa os IPs da LAN anterior |
| Entradas numéricas | valor fora da faixa ou não numérico é reperguntado, nunca derruba o script |

### 6. Operação do dia a dia

```bash
virsh --connect qemu:///system start win11    # liga (monitor troca para o Windows)
# desligar: pelo próprio Windows; o desktop Linux volta sozinho
util/snapshot-vm.sh criar antes-de-algo       # ponto de restauração rápido
util/backup-vm.sh                             # backup real no destino configurado
util/atualizar-host.sh                        # atualização segura do host
util/atualizar-host.sh --validar              # validação em camadas pós-reboot
util/diagnostico.sh                           # qualquer problema: comece aqui
util/recuperar-gpu.sh                         # TTY (Ctrl+Alt+F3) se o vídeo não voltar
```

`snapshot-vm.sh` cria somente snapshot **interno** do `QCOW2_PATH` ativo, com a
VM desligada, e marca HD1/outros discos como `snapshot=no`; por isso os comandos
`reverter` e `apagar` são compatíveis com o que o próprio utilitário cria.
Snapshots externos legados são recusados em vez de executar uma operação
incompleta. `backup-vm.sh` também aborta se o XML apontar para um overlay ou se
o QCOW2 tiver backing file, evitando copiar uma base antiga como backup atual.

Scripts da pasta `windows/`: leve-os para dentro da VM (pendrive/airlock) e
execute no PowerShell como administrador.

---

## Como testar

### A. Teste a seco (em qualquer máquina com bash, antes de usar)

Valida sintaxe e formato sem executar nada no sistema:

```bash
# 1. Sintaxe de todos os scripts
for f in lib/common.sh menu.sh etapas/*.sh util/*.sh; do bash -n "$f" && echo "OK $f"; done

# 2. Nenhum CRLF (scripts bash quebram com \r)
grep -rlU $'\r' --include='*.sh' . && echo "CORRIGIR os arquivos acima" || echo "OK sem CRLF"

# 3. Nenhum placeholder do manual esquecido (formato <MAIUSCULAS>)
grep -rnE '<[A-Z_]{3,}>' etapas/ lib/ util/ | grep -v 'IP_FIXO_HOST' || echo "OK sem placeholders"

# 4. Testes automatizados sem alterar hardware, serviços ou discos
for teste in tests/test-*.sh; do bash "$teste" || exit 1; done

# 5. Linters opcionais, quando instalados
if command -v shellcheck >/dev/null; then
  shellcheck lib/common.sh etapas/*.sh util/*.sh menu.sh
fi
if command -v pwsh >/dev/null; then
  pwsh -NoProfile -Command 'Get-ChildItem windows -Filter *.ps1 | ForEach-Object { [void][scriptblock]::Create((Get-Content -Raw $_)); Write-Host "OK $($_.Name)" }'
fi
```

### B. No Pop!_OS, etapa a etapa

Cada etapa tem o modo `--verificar`, que consulta seus critérios diretamente no
sistema e retorna códigos de saída 0 (ok), 1 (pendente), 2 (indeterminado) ou 3
(erro):

```bash
bash menu.sh --status                       # visão geral
bash etapas/14-working-disk.sh --verificar  # mountpoint externo ativo ou dispensa explícita
```

Verificações chave por fase:

| Fase | Comando | Critério de sucesso |
|------|---------|---------------------|
| Driver host | `nvidia-smi` | tabela com a RTX 3060 e versão do driver |
| workingDisk | `bash etapas/14-working-disk.sh --verificar` e `findmnt --mountpoint /mnt/workingDisk` | caminho configurado é diretório e mountpoint exato, ou dispensa explícita |
| IOMMU | `cat /proc/cmdline` e `sudo dmesg \| grep AMD-Vi` | parâmetros presentes; "Found IOMMU" |
| Grupos | `util/listar-grupos-iommu.sh` | GPU e áudio no MESMO grupo, sem intrusos |
| VM criada | `virsh --connect qemu:///system dumpxml win11 \| grep -E "loader\|qcow2"` | OVMF + /vm/Windows11.qcow2 |
| Guest agent | `virsh --connect qemu:///system qemu-agent-command win11 '{"execute":"guest-ping"}'` | `{"return":{}}` |
| Pinning | `virsh --connect qemu:///system vcpuinfo win11` (VM ligada) | afinidade restrita aos núcleos pinados |
| HugePages | `grep Huge /proc/meminfo` | `HugePages_Total` = reservado, `Hugepagesize` 1 GiB |
| Isolation | `cat /sys/devices/system/cpu/isolated` | exatamente as CPUs da VM |
| Rede (bridge) | `bash etapas/60-rede-bridge.sh --verificar`, `ip addr show br0` | uplink Ethernet em `br0`, NIC pelo MAC em `source bridge`, host/VM na LAN |
| Rede (NAT) | `bash etapas/60-rede-bridge.sh --verificar`, `virsh --connect qemu:///system net-info passthrough-nat` | rede dedicada ativa/autostart, uplink igual à rota IPv4 efetiva, reserva DHCP e NIC em `source network` |

### C. Teste funcional do passthrough (o teste que importa)

1. `virsh --connect qemu:///system start win11`
2. Esperado: o monitor sai do desktop Linux, fica alguns segundos sem sinal e
   mostra o boot do Windows pela RTX 3060 (isso é o desenho, não é defeito).
3. Dentro do Windows: instalar o driver NVIDIA (nvidia.com, instalação limpa)
   na primeira vez; Gerenciador de Dispositivos sem "Code 43".
4. Desligar o Windows normalmente e conferir que o desktop Linux volta sozinho.
5. Logs dos hooks: `sudo journalctl -u libvirtd -e | grep -i hook`
6. Se o vídeo não voltar: Ctrl+Alt+F3 e `bash util/recuperar-gpu.sh`
   (reboot do host é sempre uma saída válida e segura).

### D. Testes funcionais do Airlock

1. Visão de serviço: `mount | grep airlock` (fuse.bindfs) e o teste de escrita
   que a própria etapa 20 executa.
2. `sudo sshd -t` sem saída e `systemctl status ssh` ativo.
3. Transferência real pelo WinSCP: sessão abre em `/files`; arquivo enviado
   aparece em `AIRLOCK_DIR` (por padrão, `/mnt/workingDisk/airlock` quando
   `WORKING_DISK_PATH=/mnt/workingDisk`) e vice-versa.
4. Confinamento: no WinSCP, subir para `/` mostra somente `files/`.
5. Autenticação: `ssh vmtransfer@<IP_FIXO_HOST>` sem chave responde
   `Permission denied (publickey)`; em bridge esse destino é o IP LAN do host,
   em NAT é o gateway da bridge virtual libvirt.
6. Firewall: `sudo ufw show added` deve conter **exatamente uma** regra com o
   comentário `SFTP airlock - somente VM Windows`, e ela deve corresponder
   exatamente à interface do modo, `VM_IP_FIXO`, porta 22 e TCP. Regra marcada
   residual ou não parseável reprova a etapa e seu `--verificar`.
7. Hook: com a VM desligada, `sudo umount /srv/airlock/files`, ligar a VM e
   conferir a remontagem em `journalctl -t hook-qemu -b`.

### E. Desempenho

Meça, não "sinta": 3DMark (3 execuções por configuração), MSI Afterburner/RTSS
para 1% low, CrystalDiskMark para I/O. Aplique UM ajuste por vez (pinning,
depois HugePages, depois isolcpus, depois MSI) e registre a média e a variação.

---

## Troubleshooting e reversão

Consulte **[troubleshooting.md](troubleshooting.md)** antes de desfazer qualquer
etapa. O documento organiza os procedimentos por sintoma e diferencia:

- rollback automático durante uma transação;
- `--desfazer` explícito das etapas 17 e 18;
- restauração manual por um backup exato;
- snapshot interno do QCOW2;
- backup offline da VM.

Essas proteções não são intercambiáveis. Em particular, as etapas 11, 12, 14,
18, 19 e 20 não possuem teardown completo pós-commit, e snapshot não protege
HD1, configuração do host, rede, NVRAM ou TPM. Se uma etapa informar rollback
incompleto, não reinicie nem inicie a VM até comparar o estado com o backup
anunciado.

Para incidentes, comece sempre por:

```bash
bash menu.sh --status
bash util/diagnostico.sh
```

Se a VM já estiver desligada e a GPU não voltar ao Linux, use o fluxo suportado:

```bash
bash util/recuperar-gpu.sh
```

## O que ficou de fora deliberadamente

- alternativa Samba para o Airlock: o fluxo suportado é SFTP;
- ACS override: não implementado porque pode reduzir o isolamento DMA;
- CPU Intel: ainda não suportada pela implementação atual;
- benchmarks automatizados dentro do Windows;
- restauração automática dos conjuntos criados por `backup-vm.sh`.
