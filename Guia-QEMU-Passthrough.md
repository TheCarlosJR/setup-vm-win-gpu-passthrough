# Windows 11 em QEMU/KVM com GPU em passthrough (Pop!_OS)

Guia direto de **instalação e configuração do QEMU** para rodar Windows 11 em
máquina virtual com uma GPU NVIDIA entregue fisicamente à VM.

O que este guia **não** cobre, de propósito: instalar o Pop!_OS, particionar o
disco do sistema e ajustar o firmware da placa-mãe fora do essencial. Ele começa
com o Linux já funcionando (ver "Sistema esperado") e vai até a VM em uso diário.

Para explicação longa, "como desfazer" item por item e troubleshooting extenso,
consulte o manual de referência `Windows11_VM_Passthrough_PopOS_v2.md`.

---

## 1. Sistema esperado

Antes do primeiro comando, o host precisa estar assim:

| Item | Estado esperado | Como conferir |
|---|---|---|
| Distribuição | Pop!_OS 22.04 ou mais novo (qualquer Ubuntu recente serve com ajustes) | `lsb_release -a` |
| Modo de boot | UEFI, com CSM desabilitado | `[ -d /sys/firmware/efi ] && echo UEFI` |
| Bootloader | systemd-boot com `kernelstub` (padrão do Pop!_OS) ou GRUB | `command -v kernelstub`, `ls /boot/grub/grub.cfg` |
| CPU | AMD com SVM ativo na BIOS (Intel exige trocar `amd_iommu` por `intel_iommu` nos comandos) | `lscpu \| grep -iw svm` |
| GPU | NVIDIA dedicada com driver proprietário carregado | `nvidia-smi` |
| RAM | 16 GiB no mínimo (32 GiB é o cenário confortável) | `free -h` |
| Usuário | conta normal com `sudo`, nunca operar como root | `id` |
| Rede | cabo Ethernet ligado (bridge sobre Wi-Fi não é coberta) | `ip -o link show` |
| Espaço | 250 GiB livres para o disco virtual do Windows | `df -h /` |

Opcionais, cada um adiciona um recurso:

- **Segundo disco NTFS (HD2)**: guarda seus documentos no Linux e hospeda a pasta
  de transferência com a VM. Necessário para a etapa 14 e para o airlock.
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
  inventário gerado na etapa 00.
- Em configuração permanente (fstab, XML da VM), use apenas `UUID=...` ou
  `/dev/disk/by-id/...`, nunca `/dev/sdX`.
- Antes de entregar um disco à VM, confirme que ele **não tem nada montado** no
  host: `lsblk -o NAME,SIZE,MOUNTPOINT /dev/sdX`.
- O disco da raiz do Linux nunca vai para a VM. A etapa 02 detecta a raiz com
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
roda nele). A etapa 02 impõe estes tetos automaticamente:

| Recurso | Regra |
|---|---|
| Núcleos | host mantém 1 núcleo físico, ou 2 quando há 6 ou mais |
| RAM | teto = total menos a reserva do host (25% do total, entre 4 e 8 GiB) |
| Disco | disco da raiz e disco do HD2 fora da lista de candidatos |

Cuidado específico com **HugePages** (etapa 52): a RAM reservada sai do host de
forma permanente, no boot, mesmo com a VM desligada. Reservar demais deixa o
host sem memória para subir a sessão gráfica.

### 2.4 Baixar ISO só da fonte oficial

Windows 11 direto de `microsoft.com`; `virtio-win.iso` do projeto oficial
virtio-win. Nunca de espelho de terceiros: uma imagem adulterada compromete a VM
e, por consequência, o canal de arquivos com o host.

### 2.5 Editar o fstab com rede de segurança

Linha malformada no `/etc/fstab` impede o boot. Os scripts fazem backup datado
antes de qualquer edição e sempre incluem `nofail`, que faz o boot seguir mesmo
se a montagem falhar. Se editar à mão, teste com `sudo mount -a` **antes** de
reiniciar.

### 2.6 Testar mudança de rede de forma reversível

Configurar a bridge pode derrubar a conectividade. Use `sudo netplan try`: sem a
sua confirmação, a configuração anterior volta sozinha em cerca de 120 segundos.

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
bash etapas/30-iommu-vfio.sh --verificar
```

| Etapa | O que faz | Parada |
|---|---|---|
| 00 | inventário de hardware em arquivo datado | |
| 01 | checklist da BIOS e verificação pelo lado do Linux | |
| 02 | detecta GPU, discos, CPU, RAM e grava o `passthrough.conf` | |
| 10 | atualiza sistema e firmware | reboot |
| 11 | driver NVIDIA no host | reboot |
| 12 | pacotes utilitários (inclui `xmlstarlet`) | |
| 13 | cria `/vm` e o ponto de montagem do HD2 | |
| 14 | monta o HD2 e redireciona as pastas do usuário | |
| **20** | **instala QEMU/KVM/libvirt/OVMF/swtpm** | |
| 21 | grupos do usuário e permissões de `/vm` | logout |
| 30 | IOMMU e módulos VFIO | reboot |
| 40 | cria a VM com `virt-install` | |
| 41 | instalação do Windows (interativa) | |
| 50 | hooks da GPU e disco físico no XML | |
| 51 | USB em passthrough (opcional) | |
| 52 | CPU pinning e HugePages (opcional) | reboot |
| 53 | isolamento de CPU (opcional) | reboot |
| 60 | rede em bridge | |
| 61 | airlock: transferência de arquivos por SFTP | |
| 70 | TRIM/discard e pasta de backups | |

Ordem obrigatória até a etapa 50. Da 51 em diante, opcional e em qualquer ordem.

---

## 4. Preparação do host

### 4.1 Inventário

```bash
bash etapas/00-inventario.sh
```

Gera `~/inventario-hardware/inventario-<data>.txt` com CPU, RAM, placa-mãe,
dispositivos PCI e discos. **Guarde uma cópia fora do disco do sistema**: é a
referência para conferir modelo e serial na hora de escolher disco.

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

Detecta tudo no seu hardware e grava em `passthrough.conf`, que todas as demais
etapas leem. Nenhum script tem valor chumbado. Aqui você decide, com os tetos da
seção 2.3 aplicados: qual GPU vai para a VM, quantos núcleos, quanta RAM, qual
disco físico (ou nenhum) e onde fica a pasta de transferência.

Para refazer: `bash etapas/02-detectar-config.sh --redetectar`.

### 4.4 Sistema, driver e utilitários

```bash
bash etapas/10-atualizar-sistema.sh   # apt full-upgrade + firmware; reinicia
bash etapas/11-driver-nvidia.sh       # driver proprietário; reinicia se instalar
bash etapas/12-pacotes-base.sh
bash etapas/13-diretorios.sh          # /vm e /mnt/docs4
bash etapas/14-docs4.sh               # opcional: HD2 e pastas do usuário
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
| `bridge-utils` | apoio à rede em bridge (etapa 60) |

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

Em CPU Intel, troque `amd_iommu=on` por `intel_iommu=on`.

Verificação após o reboot:

```bash
cat /proc/cmdline                     # parâmetros presentes
sudo dmesg | grep -i AMD-Vi           # "Found IOMMU" e afins
lsmod | grep vfio                     # módulos carregados
bash util/listar-grupos-iommu.sh      # grupos e seus dispositivos
```

O grupo da sua GPU deve conter **apenas** ela: vídeo, áudio HDMI e, no máximo,
pontes PCI (`pcieport`), que são inofensivas. Qualquer outro dispositivo no mesmo
grupo (controladora de rede, USB, armazenamento) precisa ser resolvido antes: use
outro slot físico, atualize a BIOS ou, como último recurso e com custo real de
segurança, o patch ACS override (Capítulo 28 do manual).

> A GPU **não** é presa ao `vfio-pci` no boot. Com GPU única isso deixaria o
> Linux sem vídeo. A troca de driver é dinâmica, feita pelos hooks da seção 8.

---

## 7. Criar a VM

```bash
bash etapas/40-criar-vm.sh
```

O script pede as duas ISOs (repergunta até o arquivo existir), copia para
`/vm/iso/` quando estão em `/home` (o processo do QEMU pode não conseguir ler seu
home), confere espaço livre, adiciona a regra do AppArmor para o caminho `/vm` e
cria a VM:

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
  GPU real entrar em cena. Remova depois (`--remover-video` na etapa 50).
- **rede NAT `default`**: suficiente até a bridge da etapa 60.

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

Depois, dentro do Windows:

- Desative a Inicialização Rápida (`windows/Desativar-Fast-Startup.ps1`). Com ela
  ativa, "Desligar" faz hibernação parcial e deixa o NTFS marcado como em uso.
- Mantenha o Windows Defender ativo. Não crie exclusão para a pasta de
  transferência.
- O driver NVIDIA dentro da VM só na próxima seção, quando a GPU real estiver em
  passthrough.

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

O libvirt executa scripts em momentos definidos do ciclo de vida da VM. Dois
hooks fazem a GPU trocar de dono:

- `prepare/begin/01-gpu-para-vfio.sh`: para o gerenciador de exibição, descarrega
  os módulos NVIDIA e vincula a GPU ao `vfio-pci`.
- `release/end/01-gpu-para-linux.sh`: caminho inverso, devolve a GPU ao driver
  `nvidia` e religa o desktop.

O script gera os dois com os IDs reais do seu `passthrough.conf`, instala o
dispatcher `/etc/libvirt/hooks/qemu`, reinicia o `libvirtd` e anexa ao XML da VM:

```xml
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x0000' bus='0x0c' slot='0x00' function='0x0'/>
  </source>
</hostdev>
```

A função de áudio HDMI entra como um segundo `hostdev`. Se a placa não expõe essa
função, o script segue somente com vídeo.

Detalhe que costuma passar batido: o arquivo `new_id` do `vfio-pci` aceita **um
par por escrita**, no formato `vendor device` separado por espaço. Escrever
`10de:2504,10de:228e` de uma vez é recusado pelo kernel, e o erro fica invisível
porque a escrita é silenciada. Os hooks gerados aqui fazem uma escrita por
dispositivo.

Disco físico dedicado (só se você escolheu um na etapa 02):

```xml
<disk type='block' device='disk'>
  <driver name='qemu' type='raw' cache='none'/>
  <source dev='/dev/disk by-id do seu disco'/>
  <target dev='vdb' bus='virtio'/>
</disk>
```

Antes de anexar, o script confere três coisas: que o disco existe, que não é o
disco da raiz do Linux e que não tem nada montado no host.

### 8.1 O teste que importa

```bash
virsh --connect qemu:///system start win11
```

Esperado: o monitor sai do desktop Linux, fica alguns segundos sem sinal e mostra
o boot do Windows pela GPU real. Na primeira vez, instale o driver NVIDIA dentro
do Windows (baixado de `nvidia.com`, opção "Instalação limpa"). O Gerenciador de
Dispositivos não deve mostrar "Code 43".

Desligue o Windows normalmente e confirme que o desktop Linux volta sozinho.

```bash
sudo journalctl -u libvirtd -e | grep -i hook   # o que os hooks fizeram
```

Se o vídeo não voltar: `Ctrl+Alt+F3`, login, `bash util/recuperar-gpu.sh`.

Com o passthrough validado, remova o vídeo virtual para a saída ficar
exclusivamente na GPU real:

```bash
bash etapas/50-hooks-gpu-hd1.sh --remover-video
```

Se aparecer "Code 43" no Windows, o caminho conhecido é ocultar o hypervisor:

```bash
bash etapas/50-hooks-gpu-hd1.sh --anti-code43
```

---

## 9. Ajustes de desempenho (opcionais)

Aplique **um por vez** e meça antes de seguir para o próximo. Todos têm custo
para o host.

| Etapa | O que faz | Custo |
|---|---|---|
| 51 | USB em passthrough por vendor:product | o dispositivo fica exclusivo da VM enquanto ela roda |
| 52 | CPU pinning, topologia real e HugePages | a RAM reservada sai do host no boot, mesmo com a VM desligada |
| 53 | `isolcpus`: tira os núcleos da VM do escalonador | os núcleos isolados param de receber processos do host, sempre |

```bash
bash etapas/51-usb-passthrough.sh
bash etapas/52-cpu-pinning-hugepages.sh
bash etapas/53-cpu-isolation.sh
```

Dentro do Windows, o complemento da etapa 53 é ativar interrupções MSI para a
GPU: `windows/Ativar-MSI-GPU.ps1` (como administrador). Reduz microengasgos.

Nunca passe o único teclado do host na etapa 51: você precisa dele para o
terminal de emergência.

---

## 10. Rede e transferência de arquivos

```bash
bash etapas/60-rede-bridge.sh   # bridge br0: a VM ganha IP da sua rede local
bash etapas/61-airlock.sh       # canal único de arquivos, por SFTP
bash etapas/70-trim-discard.sh  # TRIM do Windows libera espaço real no host
```

A bridge coloca a VM na mesma sub-rede da casa, em vez da rede NAT
`192.168.122.x`. O script usa `netplan try`, que reverte sozinho se você não
confirmar. Depois, reserve IP fixo para os dois MACs no roteador.

O **airlock** é o único caminho de arquivos entre host e VM: uma pasta de trânsito
exposta por SFTP com chroot, chave obrigatória, usuário de sistema sem shell e
firewall liberando a porta 22 apenas para o IP da VM. As pastas reais do host
nunca ficam visíveis.

Onde fica a pasta de trânsito é configurável em `AIRLOCK_DIR`
(`passthrough.conf`); o padrão é `/mnt/docs4/airlock`. A visão exposta pelo SFTP
é montada com `noexec,nosuid,nodev`.

Regras de uso, que valem mais que a configuração: trate a pasta como zona de
passagem, sem nada permanente, fora do backup; nunca execute binário vindo dela;
nunca crie exclusão do Defender para ela dentro do Windows.

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
| XML da VM | `virsh define backups/<vm>-<data>.xml` (backup criado antes de toda alteração) |
| Netplan | restaurar `<arquivo>.yaml.bak-<data>` e `sudo netplan apply` |
| Hooks da GPU | `sudo rm -rf /etc/libvirt/hooks/qemu.d/<vm>` e `sudo systemctl restart libvirtd` |
| VM inteira | `virsh --connect qemu:///system undefine <vm> --nvram` (o QCOW2 continua no disco) |

---

## 14. Verificações rápidas

| Camada | Comando | Critério de sucesso |
|---|---|---|
| Virtualização | `kvm-ok` | aceleração KVM pode ser usada |
| Driver do host | `nvidia-smi` | tabela com a GPU e a versão do driver |
| IOMMU | `cat /proc/cmdline` e `sudo dmesg \| grep AMD-Vi` | parâmetros presentes, IOMMU encontrado |
| Grupo IOMMU | `bash util/listar-grupos-iommu.sh` | só GPU, áudio e pontes no grupo |
| VM definida | `virsh --connect qemu:///system dumpxml win11 \| grep -E "loader\|qcow2"` | OVMF e caminho do QCOW2 |
| Guest agent | `virsh ... qemu-agent-command win11 '{"execute":"guest-ping"}'` | `{"return":{}}` |
| Passthrough | ligar a VM | boot do Windows pela GPU real, sem "Code 43" |
| Pinning | `virsh ... vcpuinfo win11` (VM ligada) | afinidade restrita aos núcleos escolhidos |
| HugePages | `grep Huge /proc/meminfo` | `HugePages_Total` igual ao reservado |
| Isolamento | `cat /sys/devices/system/cpu/isolated` | exatamente as CPUs da VM |
| Bridge | `ip addr show br0` e `ipconfig` na VM | ambos na sub-rede da casa |
| Airlock | `mount \| grep airlock` | tipo `fuse.bindfs`, com `noexec` |
