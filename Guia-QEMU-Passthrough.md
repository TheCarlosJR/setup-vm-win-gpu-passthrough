# Windows 11 em QEMU/KVM com GPU em passthrough (Pop!_OS)

Guia direto de **instalação e configuração do QEMU** para rodar Windows 11 em
máquina virtual com uma GPU NVIDIA entregue fisicamente à VM.

O que este guia **não** cobre, de propósito: instalar o Pop!_OS, particionar o
disco do sistema e ajustar o firmware da placa-mãe fora do essencial. Ele começa
com o Linux já funcionando (ver "Sistema esperado") e vai até a VM em uso diário.

Para diagnóstico por sintomas, recuperação segura e rollback das etapas,
consulte [`troubleshooting.md`](troubleshooting.md).

---

## 1. Sistema esperado

Antes do primeiro comando, o host precisa estar assim:

| Item | Estado esperado | Como conferir |
|---|---|---|
| Distribuição | Pop!_OS 22.04 ou mais novo (qualquer Ubuntu recente serve com ajustes) | `lsb_release -a` |
| Modo de boot | UEFI, com CSM desabilitado | `[ -d /sys/firmware/efi ] && echo UEFI` |
| Bootloader | systemd-boot com `kernelstub` (padrão do Pop!_OS) ou GRUB | `command -v kernelstub`, `ls /boot/grub/grub.cfg` |
| CPU | AMD com SVM ativo na BIOS (CPU Intel ainda não é suportada pelos scripts) | `lscpu \| grep -iw svm` |
| GPU | NVIDIA dedicada com driver proprietário carregado | `nvidia-smi` |
| RAM | 16 GiB no mínimo (32 GiB é o cenário confortável) | `free -h` |
| Usuário | conta normal com `sudo`, nunca operar como root | `id` |
| Rede | um uplink físico Ethernet ou Wi-Fi; Ethernet aceita bridge/NAT, Wi-Fi somente NAT | `ip -o link show`, `/sys/class/net/<iface>/wireless` |
| Espaço | 250 GiB livres para o disco virtual do Windows | `df -h /` |

Opcionais, cada um adiciona um recurso:

- **workingDisk externo**: caminho absoluto opcional, já montado pelo operador,
  que pode hospedar airlock e backups. O projeto apenas valida o mountpoint e
  também aceita dispensa explícita.
- **Disco inteiro para a VM**: o Windows enxerga um disco físico real (útil para
  biblioteca de jogos). Totalmente opcional.
- **Segunda saída de vídeo (iGPU ou outra placa)**: permite manter o desktop
  Linux ativo enquanto a VM roda.

> Se o `nvidia-smi` não responder, resolva isso primeiro. O driver proprietário é
> o estado de repouso da GPU: ela volta para ele toda vez que a VM desliga.

---

## 2. Os sete cuidados que evitam prejuízo

Leia esta seção inteira antes de rodar qualquer coisa. Os riscos reais deste
projeto são só estes, e todos têm prevenção simples.

### 2.1 Não formatar o disco errado

O nome `/dev/sdX` **muda entre reinicializações**: a ordem de enumeração dos
controladores SATA/USB não é estável. Um script que confie em `/dev/sdb` pode
apontar para outro disco depois de um boot.

Regras práticas:

- Identifique disco sempre por **modelo, serial e tamanho**, comparando com o
  inventário gerado na etapa 1.
- Para o disco físico inteiro entregue à VM, use somente um caminho persistente
  `/dev/disk/by-id/...`, nunca `/dev/sdX`.
- `WORKING_DISK_PATH` não identifica um dispositivo: é apenas um caminho
  absoluto que já precisa ser um mountpoint ativo. A montagem é responsabilidade
  externa do operador; o projeto não cria a base, não monta, não formata e não
  grava uma entrada de montagem no `fstab`.
- Antes de entregar um disco à VM, confirme que ele **não tem nada montado** no
  host: `lsblk -o NAME,SIZE,MOUNTPOINT /dev/sdX`.
- O disco da raiz do Linux nunca vai para a VM. A etapa 3 detecta a raiz com
  `findmnt -no SOURCE /` e remove esse disco da lista de candidatos.

```bash
# a foto que você deve conferir antes de escolher qualquer disco
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL,TRAN
findmnt -no SOURCE /          # em qual partição está a raiz do Linux
```

### 2.2 Não ficar sem vídeo

Com **uma única GPU**, este é o comportamento normal, não um defeito:

1. Ao ligar a VM, o gerenciador de exibição é encerrado e o driver `nvidia` é
   descarregado. O desktop Linux sai do ar.
2. O monitor fica alguns segundos sem sinal e passa a mostrar o Windows.
3. Ao desligar o Windows, o caminho inverso acontece sozinho e o desktop volta.

O que preparar **antes** do primeiro teste:

- Saiba entrar no terminal de texto: `Ctrl+Alt+F3`. É por lá que você recupera a
  GPU se o desktop não voltar.
- Tenha o teclado do host disponível: nunca passe o único teclado para a VM.
- Guarde este comando de emergência: `bash util/recuperar-gpu.sh`.
- Reiniciar o host (`sudo reboot`) é sempre uma saída válida e segura: o ciclo de
  energia zera qualquer estado inconsistente da placa.
- Enquanto a VM roda, o Linux fica sem interface gráfica. Não programe nada que
  dependa do desktop nesse período.

### 2.3 Não entregar todos os recursos à VM

Um host sem folga trava, e um host travado prejudica a própria VM (é o QEMU que
roda nele). A etapa 3 impõe estes tetos automaticamente:

| Recurso | Regra |
|---|---|
| Núcleos | host mantém 1 núcleo físico, ou 2 quando há 6 ou mais |
| RAM | teto = total menos a reserva do host (25% do total, entre 4 e 8 GiB) |
| Disco | disco da raiz e qualquer disco montado/em uso ficam fora dos candidatos da VM; workingDisk não é persistido como disco físico |

Cuidado específico com **HugePages** (etapa 17): a RAM reservada sai do host de
forma permanente, no boot, mesmo com a VM desligada. Reservar demais deixa o
host sem memória para subir a sessão gráfica.

### 2.4 Baixar ISO só da fonte oficial

Windows 11 direto de `microsoft.com`; `virtio-win.iso` do projeto oficial
virtio-win. Nunca de espelho de terceiros: uma imagem adulterada compromete a VM
e, por consequência, o canal de arquivos com o host.

### 2.5 Respeitar o escopo do fstab

O projeto nunca adiciona a montagem do workingDisk ao `/etc/fstab`. A única
entrada relacionada a esse armazenamento que pode existir é a visão `bindfs`
do airlock, gerenciada pela etapa 20; ela não monta o workingDisk. Essa etapa
faz backup datado antes de editar e testa a visão antes de concluir.

### 2.6 Testar bridge de forma reversível

Somente `REDE_MODO=bridge` altera a rede declarada do host. A etapa 19 grava
exclusivamente `/etc/netplan/90-vm-passthrough-bridge.yaml`, sem impor renderer
nem substituir os demais YAMLs, e usa `sudo netplan try`. Se `generate`, `try`,
`apply` ou um passo posterior falhar, a transação restaura/remove o dedicado,
reaplica o Netplan anterior e restaura o XML da VM. O NAT não altera o uplink
nem executa Netplan.

### 2.7 Snapshot não é backup

Snapshot vive dentro do mesmo arquivo, no mesmo disco. Se o disco falhar, os dois
somem juntos. Backup real é cópia em **outro disco físico**
(`util/backup-vm.sh`).

---

## 3. Fluxo completo

Cada etapa é um script em `etapas/`. Todos aceitam `--verificar`, que consulta o
sistema e retorna 0 (pronto) ou 1 (pendente). O `menu.sh` mostra esse status ao
vivo e pede a senha do sudo uma única vez.

```bash
bash menu.sh              # menu interativo com status por etapa
bash menu.sh --status     # só o checklist
bash etapas/30-iommu-vfio.sh --verificar   # etapa 11
```

O número da etapa é o do menu (1 a 21). O nome do arquivo em `etapas/` mantém a
numeração histórica, que não é a mesma: use sempre o número do menu para
conversar sobre o fluxo e a coluna `Script` para localizar o arquivo.

| Etapa | Script em `etapas/` | O que faz | Parada |
|---|---|---|---|
| 1 | `00-inventario.sh` | publica inventário completo com nome único e atualiza `ultimo-inventario.txt` atomicamente | |
| 2 | `01-verificar-bios.sh` | checklist da BIOS e verificação pelo lado do Linux | |
| 3 | `02-detectar-config.sh` | usa o último inventário, faz backup/reset e pergunta hardware e rede novamente | |
| 4 | `10-atualizar-sistema.sh` | atualiza sistema e firmware | reboot |
| 5 | `11-driver-nvidia.sh` | driver NVIDIA no host | reboot |
| 6 | `12-pacotes-base.sh` | pacotes utilitários (inclui `xmlstarlet`) | |
| 7 | `13-diretorios.sh` | cria e converge somente `/vm` | |
| 8 | `14-working-disk.sh` | preflight não destrutivo do workingDisk externo, ou confirma a dispensa | |
| **9** | `20-virtualizacao.sh` | **instala QEMU/KVM/libvirt/OVMF/swtpm** | |
| 10 | `21-usuario-grupos.sh` | grupos do usuário e permissões de `/vm` | logout |
| 11 | `30-iommu-vfio.sh` | IOMMU e módulos VFIO | reboot |
| 12 | `40-criar-vm.sh` | cria a VM com `virt-install`, NAT `default` temporária, MAC persistido e canal do guest agent | |
| 13 | `41-instalacao-windows.sh` | instalação e pós-instalação do Windows (interativa) | |
| 14 | `50-hooks-gpu-hd1.sh` | hooks da GPU e disco físico no XML | |
| 15 | `51-usb-passthrough.sh` | USB em passthrough: dispositivos individuais ou controladora inteira (opcional) | |
| 16 | `55-driver-nvidia-vm.sh` | driver NVIDIA dentro da VM, automático via qemu-guest-agent (download oficial, instalação silenciosa, confirmação no convidado) | |
| 17 | `52-cpu-pinning-hugepages.sh` | CPU pinning e HugePages (opcional) | reboot |
| 18 | `53-cpu-isolation.sh` | isolamento de CPU (opcional) | reboot |
| 19 | `60-rede-bridge.sh` | aplica a rede final: bridge Ethernet ou NAT libvirt dedicado | |
| 20 | `61-airlock.sh` | airlock: SFTP na interface/endereço do modo selecionado | |
| 21 | `70-trim-discard.sh` | TRIM/discard e pasta de backups | |

Ordem obrigatória até a etapa 16 (a 15, USB, é opcional e recomendada antes
dela). As etapas 17 e 18 são ajustes opcionais; a
etapa 20 depende da rede finalizada pela etapa 19. A etapa 21 pode ser executada
depois da VM.

Etapas com vários sub-passos os anunciam como `Etapa N.x`: a etapa 3 vai de
`Etapa 3.1/8` a `Etapa 3.8/8`, a etapa 13 de `13.1` a `13.17`, e assim por
diante. É por esse número que o roteiro se refere a cada bloco.

---

## 4. Preparação do host

### 4.1 Inventário

```bash
bash etapas/00-inventario.sh
```

Gera primeiro um temporário e, somente após concluir todas as seções, publica
`~/inventario-hardware/inventario-AAAAMMDD-HHMMSS-NNNNNNNNN.txt`. O symlink
relativo `ultimo-inventario.txt` é atualizado atomicamente; coletas interrompidas
não substituem a referência anterior e os históricos são mantidos. **Guarde uma
cópia fora do disco do sistema**: é a referência para conferir modelo e serial.

> Esta etapa pede senha de administrador logo no início: `dmidecode` lê a tabela
> SMBIOS e o `dmesg` do Pop!_OS é restrito a root (`kernel.dmesg_restrict=1`).
> Rodar o bloco de inventário sem `sudo` produz seções vazias.

Confira na seção PCI que a GPU aparece com duas linhas no mesmo barramento, uma
de vídeo e uma de áudio HDMI (por exemplo `0c:00.0` e `0c:00.1`).

### 4.2 BIOS

```bash
bash etapas/01-verificar-bios.sh
```

Ajuste manualmente no firmware (nomes variam entre versões):

| Opção | Menu típico | Valor |
|---|---|---|
| SVM Mode | Advanced > CPU Configuration | Enabled |
| IOMMU | Advanced > AMD CBS > NBIO Common Options | Enabled |
| Above 4G Decoding | Advanced > PCI Subsystem Settings | Enabled |
| Re-Size BAR Support | Advanced > PCI Subsystem Settings | Enabled |
| CSM | Boot | Disabled |
| Secure Boot > OS Type | Boot > Secure Boot | Other OS |

Salve com "Save Changes and Reset", não apenas "Exit". O script confirma pelo
lado do Linux o que é verificável por comando: flag `svm`, modo UEFI e `/dev/kvm`.

### 4.3 Configuração central

```bash
bash etapas/02-detectar-config.sh
```

A execução normal sempre usa o alvo válido de `ultimo-inventario.txt` (ou o
inventário legado/novo temporalmente mais recente como fallback), compara CPU/topologia, RAM,
PCI e modelo/serial/tamanho dos discos com o estado atual e anuncia o caminho.
Uma divergência aborta antes de alterar a configuração e exige executar a etapa
1 novamente. Em seguida, cria backup restrito do `passthrough.conf`, limpa em
uma única atualização as escolhas da etapa 3 e recomeça em
`Etapa 3.1/8 Identidade`.
`--redetectar` é alias desse comportamento; `--verificar` é estritamente somente
leitura. Consultas e travas ao vivo de GPU, discos, CPU, RAM e rede continuam
sendo a autoridade.

Em Ethernet, escolha `bridge` (VM na LAN) ou `nat` (sub-rede privada libvirt).
Em Wi-Fi station, a etapa grava somente `nat`: bridge de camada 2 normalmente
exige 4addr/WDS no adaptador e no ponto de acesso e não é suportada. A lista de
interfaces é sempre completa e destaca explicitamente a rota IPv4 efetiva
obtida por `ip -4 route get 1.1.1.1`, uma consulta local que não envia pacote.
Se NAT for escolhido em outro adaptador, a etapa 3 avisa; a 60 não altera
uplink/métrica e aborta antes de qualquer mutação até `INTERFACE_FISICA` ser o
dispositivo efetivo. Trocar o uplink mantendo bridge limpa `VM_IP_FIXO` e
`IP_FIXO_HOST`, pois eram reservas da LAN anterior.

Executar novamente: `bash etapas/02-detectar-config.sh` ou o alias
`bash etapas/02-detectar-config.sh --redetectar`; ambos fazem backup e reiniciam
todas as perguntas.

Para o workingDisk, informe um caminho absoluto já montado (por exemplo,
`/mnt/workingDisk`) ou digite `0`. A etapa valida sintaxe, diretório e mountpoint
exato com `mountpoint`/`findmnt`, e salva somente `WORKING_DISK_PATH` e
`WORKING_DISK_DISPENSADO`. Ela não procura partições, não registra dispositivo
físico e não altera a montagem externa.

### 4.4 Sistema, driver e utilitários

```bash
bash etapas/10-atualizar-sistema.sh   # apt full-upgrade + firmware; reinicia
bash etapas/11-driver-nvidia.sh       # driver proprietário; reinicia se instalar
bash etapas/12-pacotes-base.sh
bash etapas/13-diretorios.sh          # somente /vm
bash etapas/14-working-disk.sh        # preflight opcional do mountpoint externo
```

Depois do reboot, confirme com `uname -r` que o kernel novo está em uso e com
`nvidia-smi` que o driver responde.

---

## 5. Instalar o QEMU e a pilha de virtualização

Esta é a parte central do guia.

```bash
bash etapas/20-virtualizacao.sh
```

Equivalente manual:

```bash
sudo apt install -y qemu-kvm qemu-utils libvirt-daemon-system libvirt-clients \
                    bridge-utils virt-manager ovmf swtpm swtpm-tools virtinst
sudo systemctl enable --now libvirtd
```

O que cada peça faz:

| Pacote | Papel |
|---|---|
| `qemu-kvm` | o emulador/virtualizador, usando a aceleração KVM do kernel |
| `qemu-utils` | ferramentas de imagem de disco, principalmente `qemu-img` |
| `libvirt-daemon-system` | serviço `libvirtd`, que gerencia as VMs no modo sistema |
| `libvirt-clients` | linha de comando `virsh` |
| `virtinst` | `virt-install`, criação de VM por comando |
| `virt-manager` | interface gráfica e console da VM |
| `ovmf` | firmware UEFI da VM, requisito do Windows 11 |
| `swtpm`, `swtpm-tools` | TPM 2.0 emulado, também requisito do Windows 11 |
| `bridge-utils` | apoio ao modo bridge Ethernet da etapa 19; o NAT libvirt não altera Netplan |

Verificação:

```bash
kvm-ok                                        # deve dizer que a aceleração pode ser usada
ls /usr/share/OVMF/                           # OVMF_CODE*.fd e OVMF_VARS*.fd presentes
systemctl is-active libvirtd                  # active
sudo virsh --connect qemu:///system list --all
```

Se o `kvm-ok` reprovar, o SVM não está ativo na BIOS: volte à seção 4.2.

### 5.1 Grupos e permissões

```bash
bash etapas/21-usuario-grupos.sh
```

Equivalente manual:

```bash
sudo usermod -aG libvirt,kvm "$USER"
sudo chown root:libvirt-qemu /vm
sudo chmod 770 /vm
```

**Faça logout e login** ao final: grupo novo só vale em sessão nova. Depois,
`virsh --connect qemu:///system list --all` deve funcionar sem `sudo`.

Sempre use `qemu:///system` (não `qemu:///session`). Passthrough de dispositivo
PCI exige o modo sistema.

---

## 6. IOMMU e VFIO

O IOMMU é o que permite isolar um dispositivo PCI e entregá-lo à VM com acesso
direto à memória, sem risco para o host.

```bash
bash etapas/30-iommu-vfio.sh     # aplica, pede reboot
# depois do reboot:
bash etapas/30-iommu-vfio.sh     # valida e registra o grupo IOMMU
```

Equivalente manual (Pop!_OS com systemd-boot):

```bash
sudo kernelstub -a "amd_iommu=on iommu=pt"        # GRUB: editar /etc/default/grub

sudo tee /etc/modules-load.d/vfio.conf >/dev/null <<'EOF'
vfio
vfio_pci
vfio_iommu_type1
EOF

sudo update-initramfs -u -k all
sudo reboot
```

> CPU Intel ainda não é suportada pela implementação atual. Não prossiga
> trocando apenas `amd_iommu=on` por `intel_iommu=on`; a detecção da plataforma
> bloqueia esse fluxo antes das mutações.

Verificação após o reboot:

```bash
cat /proc/cmdline                     # parâmetros presentes
sudo dmesg | grep -i AMD-Vi           # "Found IOMMU" e afins
lsmod | grep vfio                     # módulos carregados
bash util/listar-grupos-iommu.sh      # grupos e seus dispositivos
```

O grupo da sua GPU deve conter **apenas** ela: vídeo, áudio HDMI e, no máximo,
pontes PCI (`pcieport`), que são inofensivas. Qualquer outro dispositivo no mesmo
grupo (controladora de rede, USB, armazenamento) precisa ser resolvido antes:
use outro slot físico ou atualize a BIOS. ACS override não é implementado por
este projeto porque pode reduzir o isolamento DMA; consulte a seção de IOMMU em
[`troubleshooting.md`](troubleshooting.md).

> A GPU **não** é presa ao `vfio-pci` no boot. Com GPU única isso deixaria o
> Linux sem vídeo. A troca de driver é dinâmica, feita pelos hooks da seção 8.

---

## 7. Criar a VM

```bash
bash etapas/40-criar-vm.sh
```

O script exige que as duas ISOs já sejam arquivos regulares e canônicos em
`/vm`, legíveis pela identidade QEMU detectada e sem links. Ele não copia ISOs de
`/home` nem relaxa permissões automaticamente. Depois de validar espaço,
AppArmor e os demais pré-requisitos, cria a VM:

```bash
virt-install \
    --connect qemu:///system \
    --name win11 \
    --memory 16384 \
    --vcpus 12 \
    --cpu host-passthrough \
    --machine q35 \
    --os-variant win11 \
    --boot uefi \
    --tpm model=tpm-crb,backend.type=emulator,backend.version=2.0 \
    --disk path=/vm/Windows11.qcow2,format=qcow2,bus=virtio,cache=none \
    --disk path=/vm/iso/Win11.iso,device=cdrom,bus=sata \
    --disk path=/vm/iso/virtio-win.iso,device=cdrom,bus=sata \
    --network network=default,model=virtio \
    --graphics spice --video qxl \
    --sound ich9 \
    --noautoconsole
```

Por que cada escolha:

- **q35 + UEFI (OVMF) + TPM 2.0**: requisitos do Windows 11. Sem eles a
  instalação recusa a máquina.
- **`host-passthrough`**: expõe o modelo real da CPU, o que rende mais desempenho
  e evita que o Windows reclame de CPU desconhecida.
- **disco `virtio` com `cache=none`**: caminho mais rápido, sem cache duplicado
  entre host e guest.
- **vídeo QXL no início**: dá console gráfico para instalar o Windows antes de a
  GPU real entrar em cena. Remova depois: a etapa 14 rodando pelo menu oferece a
  remoção quando a GPU já está no XML (ou use `--remover-video`).
- **rede NAT `default` temporária**: garante conectividade durante a instalação em
  qualquer escolha. A etapa 12 persiste o MAC; a 60 troca a fonte dessa mesma NIC,
  identificada pelo MAC (não por posição), para `br0` ou para o NAT dedicado.

Regra do AppArmor, necessária porque `/vm` não é um caminho padrão do libvirt:

```bash
echo '/vm/** rwk,' | sudo tee -a /etc/apparmor.d/local/abstractions/libvirt-qemu
sudo systemctl reload apparmor
```

> A ISO do Windows mostra "Press any key to boot from CD" por poucos segundos.
> Abra o console imediatamente e pressione uma tecla, senão o boot cai no shell
> UEFI. Se perder o momento: `virsh --connect qemu:///system reset win11`.

### 7.1 Instalar o Windows

```bash
bash etapas/41-instalacao-windows.sh   # imprime o passo a passo e verifica no fim
```

Os dois pontos que costumam travar quem faz pela primeira vez:

1. **A lista de discos aparece vazia.** É esperado: o Windows não traz driver
   VirtIO. Clique em "Carregar driver", procure na unidade da `virtio-win.iso` e
   selecione `viostor\w11\amd64`. O disco aparece em seguida.
2. **Ao chegar na área de trabalho**, ainda com a ISO virtio anexada, execute
   `virtio-win-guest-tools.exe` (raiz da ISO) e reinicie. Isso instala o
   `qemu-guest-agent`, que habilita desligamento gracioso e snapshot consistente.
   O lado do host já foi resolvido pela etapa 12, que declara o canal virtio
   `org.qemu.guest_agent.0`: sem esse canal o serviço roda no Windows e o
   `guest-ping` nunca responde. Se a VM foi criada antes disso, a própria
   etapa 13 detecta a ausência e imprime o `attach-device` necessário.

Depois, dentro do Windows:

- Copie os três scripts de `windows/` para a VM antes de qualquer um deles. Com
  os guest tools instalados, o mais simples é arrastar os `.ps1` do host para
  dentro da janela do console (o `spice-vdagent` faz a transferência). Se o
  arrastar não funcionar, `etapas/41-instalacao-windows.sh` imprime, já com o IP
  e a bridge resolvidos, o comando de um servidor HTTP temporário na NAT
  `default` e o `Invoke-WebRequest` correspondente.
- Desative a Inicialização Rápida (`windows/Desativar-Fast-Startup.ps1`, como
  Administrador). Com ela ativa, "Desligar" faz hibernação parcial e deixa o
  NTFS marcado como em uso; depois de aplicar, desligue a VM por completo uma
  vez.
- O driver NVIDIA dentro da VM entra no sub-passo 13.15, depois de a etapa 14
  colocar a GPU real em passthrough. O roteiro completo está na própria etapa 13
  (`bash etapas/41-instalacao-windows.sh`).

Verificação do host:

```bash
virsh --connect qemu:///system qemu-agent-command win11 '{"execute":"guest-ping"}'
# esperado: {"return":{}}
```

---

## 8. Passthrough dinâmico da GPU

```bash
bash etapas/50-hooks-gpu-hd1.sh
```

O libvirt executa scripts em momentos definidos do ciclo de vida da VM. Três
hooks acompanham a GPU trocando de dono:

- `prepare/begin/01-gpu-preflight.sh`: valida identidade PCI, grupo IOMMU e o HD1,
  para o gerenciador de exibição e descarrega os módulos NVIDIA. Se qualquer
  pós-condição falhar, ele mesmo faz o rollback e religa o desktop.
- `start/begin/01-gpu-vfio-check.sh`: confere que o libvirt já entregou a GPU (e o
  áudio) ao `vfio-pci` e revalida o HD1 antes de liberar o QEMU.
- `release/end/01-gpu-restore.sh`: caminho inverso, devolve a GPU ao driver
  `nvidia`, valida `nvidia-smi` e religa o gerenciador de exibição.

O script gera os três com os IDs reais do seu `passthrough.conf`, instala o
dispatcher `/etc/libvirt/hooks/qemu`, reinicia o daemon libvirt resolvido pelo
perfil (`libvirtd` ou `virtqemud`) e anexa ao XML da VM:

```xml
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x0000' bus='0x0c' slot='0x00' function='0x0'/>
  </source>
</hostdev>
```

A função de áudio HDMI entra como um segundo `hostdev`. Se a placa não expõe essa
função, o script segue somente com vídeo.

Detalhe que costuma passar batido: **quem tira a GPU do host e a devolve é o
libvirt**, por causa do `managed='yes'` no `hostdev`. Nenhum hook deste projeto
escreve em `bind`, `unbind` ou `new_id` do `vfio-pci`, e a etapa recusa instalar
um hook de terceiros que tente fazer isso, porque duas autoridades disputando o
mesmo dispositivo é a origem clássica de GPU presa em meio-caminho. Os hooks
cuidam só do que o libvirt não faz: o gerenciador de exibição, os módulos NVIDIA
e a verificação das pós-condições.

Fora da árvore de hooks, a etapa também instala
`/usr/local/sbin/vm-passthrough-nvidia-udev` e um override em
`/etc/udev/rules.d/71-nvidia.rules`. As regras da distro rodam `modprobe` direto
a cada evento em `/bus/pci/drivers/nvidia`; enquanto a GPU está no `vfio-pci`
esse `modprobe` puxa o módulo `nvidia`, que não sonda a GPU e é descarregado,
gerando outro evento no mesmo caminho. O laço se realimenta, atravessa o
`release` e derruba `nvidia_drm` com o desktop já aberto. O override é derivado
byte a byte do arquivo da distro e muda **apenas** as seis regras de `modprobe`,
que passam a consultar o estado real do barramento antes de agir. Uma
atualização do pacote NVIDIA aparece como divergência em `--verificar`, e
reexecutar a etapa 14 regenera o arquivo.

Disco físico dedicado (só se você escolheu um na etapa 3):

```xml
<disk type='block' device='disk'>
  <driver name='qemu' type='raw' cache='none'/>
  <source dev='/dev/disk by-id do seu disco'/>
  <target dev='vdb' bus='virtio'/>
</disk>
```

Antes de anexar, o script fotografa o disco duas vezes e só segue se as duas
fotos coincidirem: o caminho tem de ser um `/dev/disk/by-id/*` (nunca `/dev/sdX`),
resolver para um disco inteiro, não ser nenhum ancestral da raiz do Linux nem o
disco do sistema, não ter partição montada ou em uso no host e ter WWN ou serial
verificável. Essa identidade fica registrada e é reconferida pelos hooks a cada
boot da VM: se o disco trocar de lugar ou for montado no host, o start é
abortado antes do QEMU.

### 8.1 O teste que importa

```bash
virsh --connect qemu:///system start win11
```

Esperado: o monitor sai do desktop Linux e fica sem sinal. Enquanto o Windows
não tem o driver NVIDIA, isso é normal e NÃO é travamento: a saída primária do
convidado ainda é a QXL emulada, visível só pelo console SPICE, que morre junto
com a sessão gráfica do host. Não force o desligamento; encerre por SSH com
`virsh --connect qemu:///system shutdown win11` e o desktop volta sozinho.

Por isso o primeiro start com GPU deve ser o da etapa 16 (Instalar driver
NVIDIA na VM): ela conduz esse ciclo inteiro sem vídeo, via qemu-guest-agent,
e confirma o driver com `nvidia-smi`. O roteiro manual do 13.15 continua
disponível como fallback, mas exige monitor na GPU e teclado e mouse dedicados
pela etapa 15 antes do start. Ao final, o Gerenciador de Dispositivos não deve
mostrar "Code 43".

Desligue o Windows normalmente e confirme que o desktop Linux volta sozinho.

```bash
sudo journalctl -u libvirtd -e | grep -i hook   # o que os hooks fizeram
```

Se o vídeo não voltar com a VM já desligada: por SSH (ou `Ctrl+Alt+F3`, se o
console local responder), login e `bash util/recuperar-gpu.sh`.

Com o passthrough validado, remova o vídeo virtual para a saída ficar
exclusivamente na GPU real. A etapa 14 rodando pelo menu detecta a pendência e
oferece a remoção; o equivalente direto é:

```bash
bash etapas/50-hooks-gpu-hd1.sh --remover-video
```

Enquanto o vídeo virtual existir junto com a GPU real, ele é o monitor primário
INVISÍVEL do Windows: menu Iniciar e janelas novas abrem fora da tela física.
Após a remoção, o XML mantém `<audio type='none'/>`: é o estado que o libvirt
persiste ao definir o domínio sem som, e não um resíduo.

Se aparecer "Code 43" no Windows, o caminho conhecido é ocultar o hypervisor:

```bash
bash etapas/50-hooks-gpu-hd1.sh --anti-code43
```

---

## 9. Ajustes de desempenho (opcionais)

Aplique **um por vez** e meça antes de seguir para o próximo. Todos têm custo
para o host.

| Etapa | Script em `etapas/` | O que faz | Custo |
|---|---|---|---|
| 15 | `51-usb-passthrough.sh` | USB em passthrough: dispositivo por vendor:product ou controladora inteira | o que for passado fica exclusivo da VM enquanto ela roda |
| 17 | `52-cpu-pinning-hugepages.sh` | CPU pinning, topologia real e HugePages | a RAM reservada sai do host no boot, mesmo com a VM desligada |
| 18 | `53-cpu-isolation.sh` | `isolcpus`: tira os núcleos da VM do escalonador | os núcleos isolados param de receber processos do host, sempre |

```bash
bash etapas/51-usb-passthrough.sh
bash etapas/52-cpu-pinning-hugepages.sh
bash etapas/53-cpu-isolation.sh
```

Dentro do Windows, o complemento da etapa 18 é ativar interrupções MSI para a
GPU: `windows/Ativar-MSI-GPU.ps1` (como administrador). Reduz microengasgos.

A etapa 15 tem dois modos. O modo por dispositivo (padrão) passa um USB
específico por vendor:product. O modo `--controladora` passa uma controladora
USB PCI inteira: a descoberta é dinâmica (só é elegível a controladora cujo
grupo IOMMU contém apenas USB; sem ACS override), um mapeamento interativo
mostra quais portas físicas pertencem a ela, e o Windows ganha hotplug nativo
nessas portas: qualquer dispositivo plugado nelas, inclusive adaptadores
Bluetooth, aparece na VM na hora. As portas somem do host enquanto a VM roda e
voltam quando ela desliga; `--remover-controladora` desfaz.

O Bluetooth integrado à placa-mãe entra pelo modo por dispositivo, nunca pelo
`--controladora`. Os dois mecanismos não se parecem por baixo: `--controladora`
é passthrough PCI por VFIO e leva o grupo IOMMU inteiro junto, enquanto o modo
por dispositivo abre o USB pelo usbfs e o expõe no `qemu-xhci` que a VM já tem,
sem consultar o grupo IOMMU e sem desbindar a controladora PCI. É por isso que
o rádio Bluetooth de uma porta cuja controladora divide grupo IOMMU com SATA,
NVMe e rede pode ser passado com segurança: esses três continuam no host.

Em placas com WiFi e Bluetooth no mesmo módulo (MediaTek, Intel, Realtek),
apenas o rádio Bluetooth é USB e é só ele que viaja; o WiFi é uma função PCIe
separada e permanece no host. Enquanto a VM estiver ligada o host perde o
`hci0`, então teclado, mouse, headset e áudio Bluetooth do Linux param até a VM
desligar. Dentro do Windows o rádio quase sempre exige o driver do fabricante
da placa; sem ele o aparelho fica como desconhecido no Gerenciador de
Dispositivos. Confirme com `Get-PnpDevice -Class Bluetooth`.

Evite deixar o host sem nenhum teclado ao usar a etapa 15: sem um segundo
teclado em porta do host, a recuperação de emergência é por SSH de outro
dispositivo (`virsh shutdown`) ou, em último caso, o botão POWER.

---

## 10. Rede e transferência de arquivos

```bash
bash etapas/60-rede-bridge.sh   # nome histórico; aplica bridge OU NAT
bash etapas/60-rede-bridge.sh --verificar
bash etapas/61-airlock.sh       # canal único de arquivos, por SFTP
bash etapas/70-trim-discard.sh  # TRIM do Windows libera espaço real no host
```

A escolha feita na etapa 3 controla todo o fluxo:

| Uplink | `REDE_MODO` | Backend final | Endereçamento |
|---|---|---|---|
| Ethernet | `bridge` | `REDE_BRIDGE` (padrão `br0`) via Netplan | DHCP/reservas do roteador; VM e host na LAN |
| Ethernet | `nat` | rede `REDE_LIBVIRT` + bridge virtual própria | DHCP/reserva do libvirt; sub-rede privada |
| Wi-Fi station | `nat` obrigatório | mesma rede NAT dedicada, com `<forward mode='nat' dev='INTERFACE_FISICA'>` | DHCP/reserva do libvirt; sub-rede privada |

**Bridge Ethernet:** a etapa escreve somente
`/etc/netplan/90-vm-passthrough-bridge.yaml`; não escolhe/substitui o primeiro
YAML, não impõe renderer e preserva as outras interfaces. Se o dedicado já
existir, cria backup datado. O arquivo contém apenas `network/version`, o uplink
selecionado e `REDE_BRIDGE`. Depois de `netplan generate`, usa `netplan try` e
`apply`, aponta a NIC da VM para a bridge mantendo o MAC e solicita as reservas
do roteador. Bridge Wi-Fi continua rejeitada.

**NAT Ethernet/Wi-Fi:** o NAT não altera configuração, métrica ou estado do
uplink e não lê/modifica Netplan. A etapa exige que `INTERFACE_FISICA` seja o
dispositivo da rota IPv4 efetiva para `1.1.1.1`; a consulta apenas resolve a
rota local, sem enviar pacote. O libvirt cria a bridge virtual, executa
`dnsmasq` para DHCP/DNS e instala regras de encaminhamento/NAT no host. A
reserva fornece `VM_IP_FIXO`, e `IP_FIXO_HOST` é o gateway usado para o airlock.
A LAN não ganha rota direta para a VM.

A sub-rede RFC1918 `/24` não pode sobrepor qualquer rota ou outra rede libvirt.
Ao revalidar a sub-rede já gerenciada, somente as rotas `proto kernel` exatas da
própria rede são desconsideradas: CIDR conectado, `local` do gateway e os dois
`broadcast`; qualquer outra sobreposição, inclusive na mesma bridge, bloqueia.
Uma rede homônima sem `vm-passthrough:60-rede-nat:v1` nunca é alterada.

**Transação e migrações:** antes da primeira mutação do NAT, a etapa captura o
XML anterior da rede, existência/persistência, ativo/autostart, XML da VM e
`passthrough.conf`. Rede e troca da fonte da NIC pertencem à mesma transação.
Falha ou sinal restaura tudo; se a rede não existia, uma criação parcial é
parada e removida. O bridge arma rollback antes de escrever Netplan ou parar a
NAT; uma falha em Netplan ou depois restaura/remove o dedicado, executa
`netplan generate` + `apply`, restaura a rede anterior e o XML da VM.
No bridge, o commit lógico exige Netplan aplicado, `REDE_BRIDGE`
administrativamente `UP`, uplink como `master` da bridge e NIC da VM apontando
para ela. `VM_IP_FIXO` e `IP_FIXO_HOST` podem permanecer incompletos; nesse caso,
o `--verificar` e a etapa 20 ficam pendentes.

Na migração NAT → bridge, antes de tocar Netplan, a etapa consulta com
`virsh --connect qemu:///system list --all --name` todas as outras VMs e seus
XMLs inativos. Consumidores por `source network` ou `source bridge`, ativos ou
não, são listados e bloqueiam a mudança. Sem consumidores, autostart é
desabilitado e a rede é parada; no sucesso sua definição permanece inativa. Uma
homônima sem marcador é avisada e intocada. Para bridge → NAT, restaure ou
remova o arquivo dedicado, aplique Netplan e só então rode a etapa 19: NAT
recusa uplink ainda escravizado a bridge.

`VM_NIC_MAC` identifica a interface sem depender da posição no XML. Na migração
de configuração antiga, a etapa conta todas as `/domain/devices/interface`:
autoescolhe somente quando existe uma; se houver várias, mostra todas e marca
`network=default` como **RECOMENDADA**, sem filtrar as demais. O `--verificar`
confere fonte da NIC, endereços, backend e também a igualdade entre uplink NAT e
rota IPv4 efetiva.

O **airlock** continua sendo o único caminho de arquivos: SFTP com chroot, chave
obrigatória, usuário sem shell e firewall. A etapa 20 trata toda regra com o
comentário `SFTP airlock - somente VM Windows` como gerenciada: falha fechado se
alguma não puder ser parseada, remove cada ocorrência antiga sem fallback,
confirma cardinalidade zero, adiciona a atual e exige exatamente uma regra
marcada e exata para interface, `VM_IP_FIXO`, porta 22 e TCP. O `--verificar`
repete a cardinalidade `marcada=1/exata=1`; o WinSCP usa `IP_FIXO_HOST`.

Onde fica a pasta de trânsito é configurável em `AIRLOCK_DIR`. Se ela estiver
vazia e o workingDisk estiver configurado, o padrão é
`$WORKING_DISK_PATH/airlock`; sem workingDisk, usa
`/var/lib/vm-passthrough/airlock`. Antes de criar ou escrever quando a pasta
está dentro do workingDisk, a etapa e o hook exigem que o mountpoint-base esteja
ativo e exato. A visão SFTP usa `noexec,nosuid,nodev`. Trate-a como zona de
passagem, sem dados permanentes e fora do backup; nunca execute binários vindos
dela.

---

## 11. Operação diária

```bash
virsh --connect qemu:///system start win11     # ligar (o monitor troca)
# desligar: pelo próprio Windows; o desktop Linux volta sozinho

util/snapshot-vm.sh criar antes-de-algo        # ponto de restauração rápido
util/backup-vm.sh                              # backup real em outro disco
util/atualizar-host.sh                         # atualização segura do host
util/atualizar-host.sh --validar               # validação em camadas pós-reboot
util/diagnostico.sh                            # qualquer problema: comece aqui
```

O utilitário de snapshot exige a VM desligada, identifica no XML o disco cujo
`source file` é `QCOW2_PATH`, cria nele um snapshot **interno** e exclui
explicitamente HD1 e os demais discos. Antes de `reverter` ou `apagar`, recusa
metadados externos, que exigem consolidação manual da cadeia. O backup também
recusa XML apontando para overlay e qualquer QCOW2 com backing file: copiar só
a base nesse estado produziria um backup desatualizado. `BACKUPS_VM_DIR`
explícito tem prioridade. Sem ele, o utilitário usa
`$WORKING_DISK_PATH/backups-vm` somente com workingDisk configurado; sem destino,
falha com orientação. A etapa 21 apenas avisa e pula a preparação do backup,
sem desfazer ou bloquear o TRIM. Destinos dentro do workingDisk exigem o
mountpoint-base ativo antes de qualquer criação ou escrita.

Depois de atualizar kernel ou driver NVIDIA, valide nesta ordem: `nvidia-smi`,
parâmetros de IOMMU no `/proc/cmdline`, VM liga (hook prepare), desktop volta ao
desligar (hook release).

---

## 12. Quando algo dá errado

Comece sempre por `bash util/diagnostico.sh`, que coleta todas as camadas em um
relatório datado. Diagnostique de baixo para cima: firmware, kernel, driver,
libvirt, VM, Windows.

| Sintoma | Causa provável | Ação |
|---|---|---|
| Desktop não volta ao desligar a VM | hook release falhou ou reset bug da GPU | `Ctrl+Alt+F3`, `bash util/recuperar-gpu.sh`; se não resolver, `sudo reboot` |
| Tela preta ao ligar a VM e nada acontece | GPU não foi vinculada ao `vfio-pci` | `sudo journalctl -u libvirtd -e \| grep -i hook` |
| "Code 43" no Windows | hypervisor detectado pelo driver | `bash etapas/50-hooks-gpu-hd1.sh --anti-code43`; teste Re-Size BAR desabilitado |
| Boot do Linux não completa depois da 52 ou 53 | parâmetro de kernel errado | no menu de boot, edite a linha do kernel e remova o parâmetro; depois `kernelstub -d` |
| Sem lista de discos ao instalar o Windows | driver VirtIO não carregado | "Carregar driver" e `viostor\w11\amd64` |
| `kvm-ok` reprova | SVM desabilitado na BIOS | seção 4.2 |
| Dispositivo estranho no grupo IOMMU | topologia PCI da placa | outro slot, atualização de BIOS, ACS override como último recurso |
| VM não inicia com erro de permissão em `/vm` | AppArmor ou dono de `/vm` | regra `/vm/** rwk,` e `chown root:libvirt-qemu /vm` |
| `dmesg` vazio ou sem permissão | `kernel.dmesg_restrict=1` no Pop!_OS | use `sudo dmesg` |

---

## 13. Reversão

Cada etapa imprime seu caminho de volta ao aplicar mudança de risco. As regras
gerais:

| O que desfazer | Como |
|---|---|
| Parâmetros de kernel | `sudo kernelstub -d "<parâmetros>"`, ou restaurar `/etc/default/grub.bak-<data>` e `sudo update-grub` |
| fstab | restaurar `/etc/fstab.bak-<data>`, ou remover as linhas marcadas com `# vm-passthrough:<id>`, e `sudo mount -a` |
| XML da VM | `virsh --connect qemu:///system define backups/<vm>-<data>.xml` (backup criado antes de toda alteração) |
| Rede bridge | rollback automático em falha; manualmente, restaurar/remover `/etc/netplan/90-vm-passthrough-bridge.yaml`, executar `sudo netplan generate && sudo netplan apply` e restaurar o XML da VM |
| Rede NAT | Netplan não foi tocado; restaurar o XML da VM e, sem consumidores, usar `virsh --connect qemu:///system net-destroy <REDE_LIBVIRT>` + `virsh --connect qemu:///system net-undefine <REDE_LIBVIRT>` |
| Hooks da GPU | `sudo rm -rf /etc/libvirt/hooks/qemu.d/<vm>` e `sudo systemctl restart libvirtd` |
| Filtro udev da NVIDIA | `sudo rm -f /etc/udev/rules.d/71-nvidia.rules /usr/local/sbin/vm-passthrough-nvidia-udev` e `sudo udevadm control --reload-rules` (volta a valer o arquivo da distro, com o laço de recarga) |
| VM inteira | `virsh --connect qemu:///system undefine <vm> --nvram` (o QCOW2 continua no disco) |

A rede `default` usada na instalação não é sobrescrita pela etapa 19. Para uma
reversão temporária, reative-a (`virsh --connect qemu:///system net-start
default`, `virsh --connect qemu:///system net-autostart default`) e restaure o
XML de backup cuja NIC apontava para `network='default'`.

---

## 14. Verificações rápidas

| Camada | Comando | Critério de sucesso |
|---|---|---|
| Virtualização | `kvm-ok` | aceleração KVM pode ser usada |
| Driver do host | `nvidia-smi` | tabela com a GPU e a versão do driver |
| IOMMU | `cat /proc/cmdline` e `sudo dmesg \| grep AMD-Vi` | parâmetros presentes, IOMMU encontrado |
| Grupo IOMMU | `bash util/listar-grupos-iommu.sh` | só GPU, áudio e pontes no grupo |
| VM definida | `virsh --connect qemu:///system dumpxml win11 \| grep -E "loader\|qcow2"` | OVMF e caminho do QCOW2 |
| Guest agent | `virsh --connect qemu:///system qemu-agent-command win11 '{"execute":"guest-ping"}'` | `{"return":{}}` |
| Passthrough | ligar a VM | boot do Windows pela GPU real, sem "Code 43" |
| Pinning | `virsh --connect qemu:///system vcpuinfo win11` (VM ligada) | afinidade restrita aos núcleos escolhidos |
| HugePages | `grep Huge /proc/meminfo` | `HugePages_Total` igual ao reservado |
| Isolamento | `cat /sys/devices/system/cpu/isolated` | exatamente as CPUs da VM |
| Rede bridge | `bash etapas/60-rede-bridge.sh --verificar` | bridge ativa, uplink Ethernet membro, NIC pelo MAC em `source bridge`, IPs da LAN |
| Rede NAT | `bash etapas/60-rede-bridge.sh --verificar` | rede dedicada ativa/autostart, forward no uplink, reserva DHCP e NIC em `source network` |
| Airlock | `mount \| grep airlock`; `sudo ufw show added` | bindfs `noexec`; exatamente uma regra marcada e exata para interface/IP/22/tcp |
