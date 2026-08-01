# Windows 11 VM com GPU Passthrough no Pop!_OS: scripts de instalação

Scripts de instalação e configuração da VM Windows 11 com GPU em passthrough
(KVM/QEMU/libvirt + VFIO). Cada etapa é idempotente, faz backup datado antes de
editar arquivo crítico, pede confirmação explícita nos passos destrutivos e traz
um modo `--verificar` com critério objetivo de sucesso.

### Documentação

| Documento | Quando usar |
|---|---|
| **[Guia-QEMU-Passthrough.md](Guia-QEMU-Passthrough.md)** | leitura principal: o caminho completo, direto, focado em instalar e configurar o QEMU |
| **Windows11_VM_Passthrough_PopOS_v2.md** | referência de consulta (29 capítulos): explicação longa, "como desfazer" e troubleshooting detalhado por assunto |

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
├── README.md                    este arquivo
├── Guia-QEMU-Passthrough.md     guia enxuto (leitura principal)
├── passthrough.conf.example     modelo do arquivo de configuração central
├── passthrough.conf             (gerado pela etapa 02; valores do SEU hardware)
├── menu.sh                      orquestrador com status ao vivo das etapas
├── lib/common.sh                funções compartilhadas
├── backups/                     (gerado) backups de XML da VM
├── etapas/                      uma etapa = um capítulo do manual
│   ├── 00-inventario.sh             Cap. 3   inventário de hardware
│   ├── 01-verificar-bios.sh         Cap. 12  checklist BIOS + verificação
│   ├── 02-detectar-config.sh        detecta placeholders e grava o conf
│   ├── 10-atualizar-sistema.sh      Cap. 7   update + fwupd          <reboot>
│   ├── 11-driver-nvidia.sh          Cap. 8   driver NVIDIA no host   <reboot>
│   ├── 12-pacotes-base.sh           Cap. 9   utilitários (+xmlstarlet)
│   ├── 13-diretorios.sh             Cap. 10  /vm e /mnt/docs4
│   ├── 14-docs4.sh                  Cap. 11  fstab + binds + migração
│   ├── 20-virtualizacao.sh          Cap. 13  KVM/QEMU/libvirt/OVMF/swtpm
│   ├── 21-usuario-grupos.sh         Cap. 14  grupos + permissões     <logout>
│   ├── 30-iommu-vfio.sh             Caps. 15/16  IOMMU + VFIO        <reboot>
│   ├── 40-criar-vm.sh               Cap. 17  VM via virt-install
│   ├── 41-instalacao-windows.sh     Cap. 18  guia da instalação (manual)
│   ├── 50-hooks-gpu-hd1.sh          Cap. 19  hooks dinâmicos + HD1
│   ├── 51-usb-passthrough.sh        Cap. 20  USB (opcional)
│   ├── 52-cpu-pinning-hugepages.sh  Cap. 21  pinning + HugePages     <reboot>
│   ├── 53-cpu-isolation.sh          Cap. 22  isolcpus                <reboot>
│   ├── 60-rede-bridge.sh            Cap. 23  bridge br0 + IP fixo
│   ├── 61-airlock.sh                Cap. 24  SFTP seguro (airlock)
│   └── 70-trim-discard.sh           Cap. 25  TRIM/discard
├── util/                        operação contínua e emergência
│   ├── listar-grupos-iommu.sh       Cap. 16
│   ├── snapshot-vm.sh               Cap. 25  criar/listar/reverter/apagar
│   ├── backup-vm.sh                 Cap. 25  backup real no HD2
│   ├── atualizar-host.sh            Cap. 26  atualização segura (+ --validar)
│   ├── diagnostico.sh               Cap. 28  relatório de diagnóstico
│   └── recuperar-gpu.sh             Cap. 29  emergência: GPU de volta ao Linux
└── windows/                     rodar DENTRO da VM (PowerShell como admin)
    ├── Desativar-Fast-Startup.ps1   Cap. 18
    ├── Ativar-MSI-GPU.ps1           Cap. 22
    └── Gerar-Chave-Airlock.ps1      Cap. 24
```

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

1. **BIOS configurada** antes de tudo (etapa 01 mostra o checklist: SVM,
   IOMMU, Above 4G, Re-Size BAR, CSM off, Secure Boot "Other OS").
2. **Pop!_OS já instalado** em modo UEFI, com o driver NVIDIA proprietário
   funcionando (`nvidia-smi` responde). Ver "Sistema esperado" no
   [guia](Guia-QEMU-Passthrough.md).
3. **ISOs baixadas dos canais oficiais**: Windows 11 (microsoft.com) e
   virtio-win.iso (projeto oficial virtio-win). Nunca de espelhos.
4. **Reserva de IP fixo no roteador** (necessária só a partir da etapa 60).

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

O menu mostra `[ok]`/`[  ]` por etapa consultando o sistema de verdade (cada
etapa tem um modo `--verificar` com os critérios do "Como verificar" do
capítulo). Execute as etapas em ordem; após cada `<reboot>`/`<logout>`, abra o
menu de novo e continue do ponto em que parou.

Também dá para rodar cada etapa direto, sem menu:

```bash
bash etapas/30-iommu-vfio.sh              # executa
bash etapas/30-iommu-vfio.sh --verificar  # só verifica (código de saída 0 = ok)
bash menu.sh --status                     # checklist completo sem menu
```

### 4. Ordem completa (com pontos de parada)

| # | Etapa | Observação |
|---|-------|-----------|
| 1 | `00-inventario` | somente leitura (pede sudo: `dmidecode` e `dmesg` exigem); guarde o arquivo gerado fora do disco do sistema |
| 2 | `01-verificar-bios` | manual + verificação; refaça até tudo passar |
| 3 | `02-detectar-config` | detecta GPU/discos/CPU/RAM/bootloader e grava o `passthrough.conf`; confirme cada valor |
| 4 | `10-atualizar-sistema` | **reboot** ao final |
| 5 | `11-driver-nvidia` | **reboot** se instalar; valida `nvidia-smi` |
| 6 | `12-pacotes-base` | inclui xmlstarlet (edição segura de XML) |
| 7 | `13-diretorios` | `/vm` e `/mnt/docs4` |
| 8 | `14-docs4` | fstab + bind mounts + migração; o único passo destrutivo exige digitar `SIM` |
| 9 | `20-virtualizacao` | pilha completa + `kvm-ok` |
| 10 | `21-usuario-grupos` | **logout/login** obrigatório ao final |
| 11 | `30-iommu-vfio` | fase A aplica parâmetros, **reboot**, rodar de novo para a fase B validar e registrar o grupo IOMMU |
| 12 | `40-criar-vm` | cria qcow2 + AppArmor + VM completa via virt-install; abra o console e pressione uma tecla no "Press any key..." |
| 13 | `41-instalacao-windows` | manual (driver `viostor\w11\amd64` na tela de discos; guest-tools ao final) |
| 14 | `50-hooks-gpu-hd1` | hooks com os IDs reais + GPU (e disco físico, se houver) no XML; teste o ciclo ligar/desligar |
| 15 | `51-usb-passthrough` | opcional |
| 16 | `52-cpu-pinning-hugepages` | XML + parâmetros de kernel; **reboot** |
| 17 | `53-cpu-isolation` | isolcpus; **reboot**; MSI se aplica dentro do Windows (`windows/Ativar-MSI-GPU.ps1`) |
| 18 | `60-rede-bridge` | `netplan try` reversível; depois reserve os IPs no roteador e informe ao script |
| 19 | `61-airlock` | SFTP chroot + ufw; a chave é gerada NA VM (`windows/Gerar-Chave-Airlock.ps1`) e instalada com `--instalar-chave` |
| 20 | `70-trim-discard` | discard=unmap + pasta de backups |

### 5. Configuração central

Todos os valores do seu hardware moram em `passthrough.conf` (gerado pela
etapa 02, editável à mão). Nenhum script contém valor chumbado; se faltar
algo, a etapa aborta apontando para a 02. Para refazer uma detecção:
`bash etapas/02-detectar-config.sh --redetectar`.

O que é configurável sem editar script: nome e RAM/CPU da VM, caminho e tamanho
do QCOW2, ponto de montagem do HD2 (`DOCS4_MONTAGEM`), pasta de trânsito do
airlock (`AIRLOCK_DIR`), visão exposta pelo SFTP (`AIRLOCK_BIND`), destino dos
backups (`BACKUPS_VM_DIR`), usuário de transferência e interface de rede.

#### Travas de segurança da etapa 02

Escolhas que poderiam inutilizar o host são impedidas na origem, não avisadas
depois:

| Recurso | Trava |
|---|---|
| GPU | com uma única GPU, explica que o desktop Linux sai do ar durante a VM e exige confirmação; com duas ou mais, obriga a escolher qual vai para a VM |
| CPU | teto de núcleos: o host sempre fica com 1 (2 quando há 6+ núcleos) |
| RAM | teto = total menos a reserva do host (25% do total, entre 4 e 8 GiB); valor sempre múltiplo de 1 GiB por causa das HugePages |
| Disco da VM | o disco da **raiz do Linux** e o disco do HD2 nem aparecem na lista; disco com partição montada é recusado; **"nenhum" é opção válida** (a VM fica só com o QCOW2) |
| Áudio HDMI | se a placa não expõe a função, segue somente com vídeo em vez de abortar |
| Entradas numéricas | valor fora da faixa ou não numérico é reperguntado, nunca derruba o script |

### 6. Operação do dia a dia

```bash
virsh --connect qemu:///system start win11    # liga (monitor troca para o Windows)
# desligar: pelo próprio Windows; o desktop Linux volta sozinho
util/snapshot-vm.sh criar antes-de-algo       # ponto de restauração rápido
util/backup-vm.sh                             # backup real no HD2
util/atualizar-host.sh                        # atualização segura (Cap. 26)
util/atualizar-host.sh --validar              # validação em camadas pós-reboot
util/diagnostico.sh                           # qualquer problema: comece aqui
util/recuperar-gpu.sh                         # TTY (Ctrl+Alt+F3) se o vídeo não voltar
```

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

# 4. (opcional) shellcheck, se instalado
shellcheck lib/common.sh etapas/*.sh util/*.sh menu.sh || true
```

### B. No Pop!_OS, etapa a etapa

Cada etapa tem o modo `--verificar`, que implementa o "Como verificar" do
capítulo correspondente e retorna código de saída 0 (ok) ou 1 (pendente):

```bash
bash menu.sh --status                # visão geral
bash etapas/14-docs4.sh --verificar  # exemplo: montagem + 5 binds ativos
```

Verificações chave por fase (as mesmas do manual):

| Fase | Comando | Critério de sucesso |
|------|---------|---------------------|
| Driver host | `nvidia-smi` | tabela com a RTX 3060 e versão do driver |
| Docs4 | `mount \| grep docs4` e `touch ~/Documentos/t; ls /mnt/docs4/Documentos/t` | 6 montagens; arquivo aparece nos dois caminhos |
| windows_names | `touch "/mnt/docs4/x:y.txt"` | deve FALHAR (proteção ativa) |
| IOMMU | `cat /proc/cmdline` e `sudo dmesg \| grep AMD-Vi` | parâmetros presentes; "Found IOMMU" |
| Grupos | `util/listar-grupos-iommu.sh` | GPU e áudio no MESMO grupo, sem intrusos |
| VM criada | `virsh --connect qemu:///system dumpxml win11 \| grep -E "loader\|qcow2"` | OVMF + /vm/Windows11.qcow2 |
| Guest agent | `virsh --connect qemu:///system qemu-agent-command win11 '{"execute":"guest-ping"}'` | `{"return":{}}` |
| Pinning | `virsh --connect qemu:///system vcpuinfo win11` (VM ligada) | afinidade restrita aos núcleos pinados |
| HugePages | `grep Huge /proc/meminfo` | `HugePages_Total` = reservado, `Hugepagesize` 1 GiB |
| Isolation | `cat /sys/devices/system/cpu/isolated` | exatamente as CPUs da VM |
| Bridge | `ip addr show br0` e `ipconfig` na VM | ambos com IP da sub-rede da casa |

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

### D. Testes do airlock (as 7 verificações do Capítulo 24)

1. Visão de serviço: `mount | grep airlock` (fuse.bindfs) e o teste de escrita
   que a própria etapa 61 executa.
2. `sudo sshd -t` sem saída e `systemctl status ssh` ativo.
3. Transferência real pelo WinSCP: sessão abre em `/files`; arquivo enviado
   aparece em `/mnt/docs4/airlock` (e vice-versa).
4. Confinamento: no WinSCP, subir para `/` mostra somente `files/`.
5. Autenticação: `ssh vmtransfer@<IP_FIXO_HOST>` sem chave responde
   `Permission denied (publickey)` na hora (senha nem é oferecida).
6. Firewall (teste negativo): de OUTRO dispositivo da LAN, a porta 22 dá
   timeout; da VM, conecta.
7. Hook: com a VM desligada, `sudo umount /srv/airlock/files`, ligar a VM e
   conferir a remontagem em `journalctl -t hook-qemu -b`.

### E. Desempenho (Capítulo 27)

Meça, não "sinta": 3DMark (3 execuções por configuração), MSI Afterburner/RTSS
para 1% low, CrystalDiskMark para I/O. Aplique UM ajuste por vez (pinning,
depois HugePages, depois isolcpus, depois MSI) e registre a média e a variação.

---

## Reversão

Cada etapa imprime seu caminho de reversão ao aplicar mudanças de risco, e o
manual traz o "Como desfazer" completo por capítulo. Regras gerais:

- fstab: restaurar o backup `/etc/fstab.bak-<data>` (ou remover as linhas
  marcadas com `# vm-passthrough:<id>`), depois `sudo mount -a`.
- Parâmetros de kernel: `sudo kernelstub -d "<parâmetros>"` (ou restaurar
  `/etc/default/grub.bak-<data>` + `sudo update-grub`).
- XML da VM: `virsh define backups/<vm>-<data>.xml` (backup criado antes de
  toda alteração).
- Netplan: restaurar `<arquivo>.yaml.bak-<data>` + `sudo netplan apply`.
- Emergências (sem vídeo, boot quebrado, fstab malformado): Capítulo 29 do
  manual; `util/recuperar-gpu.sh` cobre o cenário 1.

## O que ficou de fora (deliberadamente)

- Alternativa Samba do airlock (o manual manda escolher UM método; o padrão
  aqui é SFTP). Instruções completas na seção 9 do Capítulo 24.
- ACS override (último recurso com risco de segurança; Capítulo 28).
- Benchmarks automatizados (rodam dentro do Windows; Capítulo 27).
