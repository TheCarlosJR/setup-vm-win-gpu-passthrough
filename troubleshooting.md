# Troubleshooting e rollback do passthrough

Guia operacional para diagnosticar e recuperar o host e a VM Windows 11 deste
projeto. Use o [Guia-QEMU-Passthrough.md](Guia-QEMU-Passthrough.md) para instalar
e configurar o ambiente; use este documento quando uma verificação reprovar,
uma etapa for interrompida ou for necessário desfazer uma mudança.

A implementação dos scripts é a fonte de verdade. Este guia descreve somente os
mecanismos presentes no repositório atual e não substitui os backups exibidos por
cada etapa.

## 1. Escopo e limites atuais

O fluxo operacional atual foi validado para:

- host Pop!_OS ou Ubuntu suportado por `lib/platform.sh`;
- CPU AMD com SVM/IOMMU;
- GPU NVIDIA dedicada ao passthrough dinâmico;
- KVM/QEMU/libvirt em `qemu:///system`;
- boot por `kernelstub` ou GRUB, conforme detectado e salvo na configuração;
- rede final em bridge Ethernet ou NAT libvirt dedicado;
- VM Windows 11 definida pela configuração local `passthrough.conf`.

CPU Intel, ACS override, hosts imutáveis e outras distribuições não fazem parte
do suporte operacional atual. Não adapte comandos AMD trocando apenas o nome do
parâmetro: os scripts bloqueiam plataformas não suportadas antes das mutações.

Execute os comandos a partir da raiz deste repositório. Substitua valores entre
`<...>` somente depois de confirmá-los no sistema. Nunca carregue
`passthrough.conf` com `source` ou `eval`; a biblioteca do projeto usa um parser
restrito porque o arquivo deve ser tratado como dados.

## 2. Comece sempre por aqui

### 2.1 Preserve o estado antes de tentar corrigir

1. Se a VM ainda estiver acessível, desligue o Windows normalmente.
2. Não force reset, não apague o QCOW2 e não altere XML, rede ou drivers enquanto
   ainda estiver coletando evidências.
3. Anote todo caminho de backup exibido pela etapa que falhou.
4. Preserve a saída completa do menu e da etapa; não use apenas a última linha.
5. Garanta acesso por TTY ou SSH antes de tocar GPU, rede, firewall ou SSH.

### 2.2 Consulte o estado observado

```bash
bash menu.sh --status
bash util/diagnostico.sh
```

O menu não usa um arquivo de conclusão. Cada item executa o `--verificar` da
etapa correspondente e consulta o estado real do host:

| Código | Significado | Ação inicial |
|---:|---|---|
| 0 | estado comprovadamente correto | prossiga para a próxima camada |
| 1 | pendente ou divergente | leia o diagnóstico da própria etapa |
| 2 | indeterminado | forneça a permissão/evidência que faltou e repita |
| 3 | erro do verificador | preserve a saída e corrija o erro antes de mutar o host |

`bash menu.sh --status` não abre uma sessão sudo. Uma leitura privilegiada que
não esteja disponível pode produzir estado indeterminado; isso não prova que a
configuração está errada. Quando necessário, rode o verificador específico em
uma sessão local controlada.

`util/diagnostico.sh` cria um relatório na raiz única de estado do projeto (a
mesma do inventário e do log de ações; respeita `XDG_STATE_HOME`):

```text
~/.local/state/vm-passthrough/inventario/diagnostico-AAAAMMDD-HHMM.txt
```

O relatório reúne informações de libvirt, IOMMU, linha de comando do kernel,
módulos VFIO/NVIDIA, PCI, `nvidia-smi`, HugePages, CPUs isoladas, montagens,
journals de libvirt/hooks e negações AppArmor. Ele pode conter IPs, MACs, UUIDs,
seriais e caminhos locais. Revise e remova dados sensíveis antes de compartilhar.
Duas execuções no mesmo minuto podem usar o mesmo nome.

### 2.3 Escolha o runbook pelo sintoma

| Sintoma | Seção |
|---|---|
| tela preta com a VM AINDA LIGADA (Windows sem driver NVIDIA) | seção 4, primeiro bloco |
| monitor não volta ao Linux depois de desligar a VM | seção 4, GPU não retorna ao host |
| `virsh start` falha ou o hook bloqueia a inicialização | seção 5, VM não inicia |
| host não inicia, IOMMU/VFIO não aparece ou grupo mudou | seção 6, Boot, IOMMU e VFIO |
| `/vm`, workingDisk, QCOW2 ou HD1 divergem | seção 7, Discos e armazenamento |
| rede ou SSH some após bridge/NAT | seção 8, Rede bridge e NAT |
| SFTP, bindfs, SSH ou UFW do Airlock falha | seção 9, Airlock |
| host perde RAM/CPUs ou VM falha com HugePages | seção 10, CPU e HugePages |
| é necessário voltar o estado do Windows/QCOW2 | seção 11, Snapshots e backups |
| hardware ou `passthrough.conf` mudou | seção 12, Configuração e inventário |
| problema está dentro do Windows | seção 13, Windows convidado |
| problema apareceu depois de atualizar o host | seção 14, Atualização do host |

## 3. Entenda qual proteção realmente existe

Snapshot, backup, rollback transacional e `--desfazer` não são equivalentes.
Antes de agir, identifique a proteção disponível para a etapa responsável.

| Componente | Proteção durante a execução | Reversão depois do sucesso |
|---|---|---|
| etapa 1, inventário | publica arquivo e symlink final de forma atômica | preserve ou volte manualmente para um inventário válido |
| etapa 3, configuração | cria backup restrito antes de redetectar | não há subcomando de restauração; use conscientemente o backup exato |
| etapa 11, IOMMU/VFIO | mutações individuais tentam rollback e verificam pós-condições | não existe `--desfazer` global; boot, `vfio.conf` e initramfs são revertidos separadamente |
| etapa 12, criação da VM | restaura apenas o selo temporário de `/vm` | não existe rollback global; definição, QCOW2, NVRAM e AppArmor exigem revisão separada |
| etapa 14, hooks/GPU/HD1 | hooks e XML são transacionais antes do commit | não existe teardown automático pós-commit; use os backups anunciados |
| etapa 17, pinning/HugePages | backup e rollback semântico do XML | possui `--desfazer`, em ordem inversa e possivelmente em duas execuções |
| etapa 18, isolamento | valida persistência e efeito no kernel | possui `--desfazer` para as três chaves de isolamento |
| etapa 19, bridge/NAT | restaura Netplan, rede libvirt, XML e configuração antes do commit; bridge usa `netplan try` | não possui `--desfazer`; restauração pós-commit é manual |
| etapa 20, Airlock | restaura arquivos, conta/grupo, mount, SSH e UFW dentro da transação | não possui teardown completo; pacotes instalados antes da transação não são removidos |
| etapa 21, TRIM | faz backup do XML e tenta restaurá-lo se a pós-condição falhar | não possui `--desfazer`; a pasta de backup é independente do XML |
| snapshot | ponto interno no QCOW2 principal | pode ser revertido pelo utilitário, com perda das mudanças posteriores |
| backup da VM | cópia offline validada do escopo documentado | não existe utilitário de restauração; o conjunto precisa ser testado isoladamente |

Se uma etapa informar que o rollback não foi comprovado, pare. Não reinicie o
host nem inicie a VM até comparar o estado atual com o backup indicado.

## 4. GPU não retorna ao host

### Antes de tudo: tela preta com a VM AINDA LIGADA não é defeito

Com GPU única, todo start da VM derruba o desktop por projeto (hook prepare da
etapa 14). Enquanto o Windows não tem o driver NVIDIA, o monitor físico fica
preto mesmo com a VM rodando: a saída primária do convidado é a QXL emulada,
visível só pelo console SPICE, que morreu junto com a sessão gráfica do host.

Recuperação correta, nesta ordem:

1. De outro dispositivo, por SSH:
   `virsh --connect qemu:///system shutdown <vm>` (o hook release devolve GPU
   e desktop sozinho ao final do desligamento);
2. se o desligamento gracioso não anda, `virsh destroy <vm>` e, se o desktop
   não voltar, utilitário u6 do menu (recuperar GPU);
3. NUNCA force o desligamento do host: ele interrompe a restauração no meio e
   mascara o diagnóstico.

Prevenção: instale o driver NVIDIA pela etapa 16 do menu (instalação
automática via qemu-guest-agent, sem monitor nem teclado dedicados). O
andamento da etapa 16 é acompanhável sem vídeo com
`journalctl -u vm-passthrough-driver-<vm> -f`.

Portas USB que somem do host com a VM ligada não são defeito quando a etapa 15
passou uma controladora inteira (`--controladora`): elas pertencem ao Windows
enquanto a VM roda e voltam sozinhas quando ela desliga. Para devolver em
definitivo: `bash etapas/51-usb-passthrough.sh --remover-controladora`.

Variante rápida do sintoma: a tela cai e o desktop VOLTA em poucos segundos
(parece só um logoff). Isso é o preflight dos hooks recusando o start e
revertendo; veja `journalctl -u libvirtd -e`. A causa comum é a sessão ainda
segurando os módulos nvidia no instante do descarregamento: o hook prepare
espera até 60 s e, se desistir, lista no journal os processos que ocupam a
GPU. Feche navegador, IDE e acesso remoto antes de iniciar a VM e tente de
novo.

### Sintomas

- monitor permanece sem sinal depois que o Windows foi desligado;
- desktop/display manager não volta;
- `nvidia-smi` falha no host;
- journal do hook informa driver inesperado ou restauração incompleta;
- permanece um arquivo em `/run/libvirt-gpu-passthrough/`;
- o desktop volta, o hook declara sucesso e o host congela segundos depois
  (veja o laço de recarga do nvidia mais abaixo).

### Diagnóstico

Entre por TTY (`Ctrl+Alt+F3`) ou SSH e confirme primeiro que a VM está realmente
desligada:

```bash
virsh --connect qemu:///system domstate <VM_NAME>
bash etapas/50-hooks-gpu-hd1.sh --verificar
bash util/diagnostico.sh
sudo journalctl -t hook-qemu -b --no-pager
sudo journalctl -u libvirtd -b -e --no-pager
```

Quando necessário, consulte também o serviço de display manager configurado:

```bash
sudo journalctl -u <DM_SERVICE> -b -e --no-pager
```

### Desktop volta e congela segundos depois

Este é um caso à parte: o hook grava `GPU e desktop restaurados com pós-condições
verificadas` em `/var/log/vm-passthrough/hooks.log`, o desktop realmente aparece
e, poucos segundos depois, o host trava e só sai no botão de reset.

A causa não é o hook. As regras udev da distro em
`/usr/lib/udev/rules.d/71-nvidia.rules` rodam `modprobe` direto a cada evento
`add`/`remove` em `/bus/pci/drivers/nvidia`. Enquanto a GPU está no `vfio-pci`
esse `modprobe` puxa o módulo `nvidia`, que não consegue sondar a GPU e é
descarregado; o descarregamento gera outro evento no mesmo caminho e a coisa se
realimenta. A tempestade atravessa o `release` e derruba `nvidia_drm` com a
sessão gráfica já aberta.

Confirme contando as recargas do boot afetado:

```bash
journalctl -k -b -1 | grep -c 'Nvlink Core is being initialized'
journalctl -b -1 | grep -c "udev-worker.*nvidia: Process"
```

Um boot saudável mostra **1** e **0**. Centenas ou milhares dos dois confirmam o
laço.

A etapa 14 fecha esse laço instalando `/usr/local/sbin/vm-passthrough-nvidia-udev`
e um override em `/etc/udev/rules.d/71-nvidia.rules`, derivado byte a byte do
arquivo da distro: só as seis regras de `modprobe` passam a consultar o estado
real do barramento antes de agir. Verifique e reinstale com:

```bash
bash etapas/50-hooks-gpu-hd1.sh --verificar
bash etapas/50-hooks-gpu-hd1.sh
```

Depois de instalado, o `release` também recusa subir o display manager quando
detecta a GPU instável: prefere deixar você em um TTY a congelar o host. Uma
atualização do pacote NVIDIA que mude as regras da distro aparece como
divergência no `--verificar`; reexecutar a etapa 14 regenera o override.

### Recuperação suportada

Com o estado da VM exatamente `shut off`, execute:

```bash
bash util/recuperar-gpu.sh
```

O utilitário adquire o lock da VM, revalida BDF, identidade PCI e grupo IOMMU,
recusa drivers inesperados, solicita ao libvirt o reattach quando aplicável,
carrega os módulos esperados, testa `nvidia-smi` e restaura o estado anterior do
display manager. O state file só é removido depois que todas as pós-condições são
comprovadas.

Se o state file não existir, há um override deliberadamente difícil de usar:

```bash
bash util/recuperar-gpu.sh --assumir-dm-ativo
```

Use-o somente depois de comprovar que o display manager deveria estar ativo. O
utilitário exige a confirmação literal `ASSUMIR`.

### Não faça

- não escreva manualmente em `bind`, `unbind`, `new_id` ou `drivers_probe`;
- não execute hooks antigos como `01-gpu-para-linux.sh`;
- não tente recuperar a GPU enquanto a VM estiver ligada, pausada ou em shutdown;
- não remova o state file para silenciar o erro;
- não presuma que recuperar a GPU remove a configuração persistente dos hooks.

O desenho atual usa `hostdev managed='yes'`: o libvirt é a autoridade do
detach/reattach. Se a recuperação suportada não comprovar sucesso, preserve os
journals e reinicie o host somente com a VM desligada. Depois do reboot, repita
`nvidia-smi`, o verificador da etapa 14 e o diagnóstico geral.

### Critério de sucesso

- `nvidia-smi` responde no host;
- o display manager está no estado anterior;
- o state file da VM foi removido pelo utilitário;
- `bash etapas/50-hooks-gpu-hd1.sh --verificar` não encontra instalação parcial.

## 5. VM não inicia

### Diagnóstico em camadas

```bash
virsh --connect qemu:///system list --all
virsh --connect qemu:///system domstate <VM_NAME>
bash etapas/30-iommu-vfio.sh --verificar
bash etapas/40-criar-vm.sh --verificar
bash etapas/50-hooks-gpu-hd1.sh --verificar
bash util/diagnostico.sh
sudo journalctl -u libvirtd -b -e --no-pager
sudo journalctl -t hook-qemu -b --no-pager
```

A etapa 12 verifica identidade do usuário QEMU, modelo de segurança de `/vm`,
QCOW2, ISOs, domínio, MAC e AppArmor. A etapa 14 verifica dispatcher, hooks,
marcador de instalação, GPU/áudio, grupo IOMMU, HD1 e cardinalidade dos
`hostdev` no XML.

### Criação parcial da VM

A etapa 12 não possui rollback global. Se `virt-install` deixou apenas uma
definição incompleta e a decisão for recriá-la, o comando indicado pela própria
etapa é:

```bash
virsh --connect qemu:///system undefine <VM_NAME> --nvram
```

Esse comando remove a definição e a NVRAM, mas preserva o QCOW2 porque não usa
`--remove-all-storage`. Não execute como correção genérica de uma VM que já tem
Windows instalado. Revise separadamente QCOW2, ISOs, regra AppArmor e backups.

Nunca use `--remove-all-storage` neste fluxo e nunca apague o QCOW2 para corrigir
um erro de definição.

### XML ou hooks divergentes

- Se a etapa 14 falhou antes do commit, deixe o bloqueio de instalação ativo,
  leia a saída preservada e corrija a causa antes de reexecutar.
- Se existe state file residual depois que a VM desligou, recupere primeiro a
  GPU pela seção anterior.
- Para restaurar XML, use somente o arquivo exato anunciado pela etapa e mantenha
  a VM desligada:

```bash
virsh --connect qemu:///system define backups/<BACKUP_XML_EXATO>.xml
```

Definir XML não restaura automaticamente NVRAM, TPM, discos nem configuração do
host. Compare o XML inativo e repita os verificadores responsáveis.

### Permissões e armazenamento

Não corrija `/vm` com `chmod -R`, `chown -R` ou ACL genérica. O modelo atual
exige `/vm` real, grupo dedicado, modo e ACLs específicos; o QCOW2 precisa ser
arquivo regular, canônico, com formato qcow2 e sem links inesperados. Rode a
etapa 12 para obter a divergência exata.

Se houver HD1 físico, confirme que o `/dev/disk/by-id/...` ainda representa o
mesmo dispositivo e que nenhuma partição está montada ou sendo usada no host.
Snapshots e backups do QCOW2 não protegem o HD1.

## 6. Boot, IOMMU e VFIO

### Sintomas

- host não inicia após mudança de parâmetros;
- `/proc/cmdline` não contém `amd_iommu=on iommu=pt`;
- `dmesg` não mostra AMD-Vi;
- módulos VFIO não carregam;
- grupo da GPU mudou ou contém endpoint adicional;
- libvirt informa grupo não viável ou erro em `/dev/vfio`.

### Diagnóstico

```bash
bash etapas/01-verificar-bios.sh --verificar
bash etapas/30-iommu-vfio.sh --verificar
bash util/listar-grupos-iommu.sh
cat /proc/cmdline
sudo dmesg | grep -i AMD-Vi
lsmod | grep vfio
```

A GPU e o áudio configurados devem estar no mesmo grupo. Além deles, somente
bridges PCI de classe `0x06` são toleradas. A listagem do grupo, sozinha, não
aprova isolamento DMA nem capacidade de reset.

### Como reverter a fase de boot

A etapa 11 aplica boot, `/etc/modules-load.d/vfio.conf` e initramfs, solicita
reboot e só depois registra o grupo validado. Não há `--desfazer` global.

Para host configurado por `kernelstub`, a própria etapa informa:

```bash
sudo kernelstub -d "amd_iommu=on iommu=pt"
sudo rm /etc/modules-load.d/vfio.conf
sudo update-initramfs -u -k all
```

Confirme que o arquivo pertence a este projeto antes de removê-lo. Em GRUB,
restaure o backup exato de `/etc/default/grub` mostrado pela etapa, execute:

```bash
sudo update-grub
```

e reinicie somente depois de verificar o arquivo restaurado e a saída do
comando. Uma falha posterior em `vfio.conf` ou no initramfs não desfaz
necessariamente um parâmetro de boot já confirmado.

Se o host não consegue iniciar, este projeto não fornece receita genérica de
live media/chroot. Partições, criptografia, LVM e bootloader variam por host.
Use o modo de recuperação da distribuição com um backup conhecido, sem copiar
comandos que presumam dispositivos como `nvme0n1p1` ou `nvme0n1p2`.

### Grupo IOMMU inseguro

Tente, nesta ordem:

1. atualizar o firmware/BIOS;
2. restaurar os defaults necessários e reativar SVM/IOMMU/Above 4G;
3. testar outro slot PCIe físico;
4. repetir inventário e detecção.

ACS override não é implementado porque pode reduzir o isolamento DMA. Não o
trate como correção suportada.

## 7. Discos e armazenamento

### Diagnóstico

```bash
bash etapas/00-inventario.sh --verificar
bash etapas/02-detectar-config.sh --verificar
bash etapas/14-working-disk.sh --verificar
bash etapas/40-criar-vm.sh --verificar
bash etapas/50-hooks-gpu-hd1.sh --verificar
bash etapas/70-trim-discard.sh --verificar
```

### workingDisk

O projeto apenas valida `WORKING_DISK_PATH`. Ele não cria, formata, monta,
descobre UUID nem grava a montagem principal no `fstab`. O caminho precisa ser
um diretório canônico e o mountpoint exato.

Se a montagem sumiu, restaure-a pelo mecanismo externo usado pelo host e só
depois repita a etapa 8. Não crie um diretório vazio no mesmo caminho para
contornar a verificação: isso pode direcionar backups e Airlock para o disco do
sistema.

### `/vm`, QCOW2 e ISOs

A etapa 12 não copia ISOs nem corrige automaticamente permissões inseguras. Os
arquivos precisam estar diretamente no armazenamento autorizado, ser regulares,
canônicos, sem links e legíveis pela identidade QEMU detectada.

Em criação parcial:

- preserve o QCOW2;
- diferencie definição libvirt, NVRAM, TPM, AppArmor e armazenamento;
- corrija apenas a camada reprovada;
- reexecute `--verificar` antes de iniciar a VM.

### HD1 físico

Antes de iniciar a VM, confirme:

- caminho persistente `/dev/disk/by-id/...`;
- identidade, tamanho e major:minor esperados;
- nenhuma partição montada;
- nenhum consumidor no host.

Se a identidade mudou, não edite apenas o XML. Refaça inventário e detecção
conscientemente. O HD1 não entra em snapshot, backup da VM ou rollback do XML.

### TRIM/discard

A etapa 21 cria backup do XML antes de aplicar `discard='unmap'`. Se a
pós-condição falhar, tenta restaurar o XML e compara o resultado. Se o script não
comprovar o rollback, não inicie a VM.

Não existe `--desfazer` para TRIM. Restaure o backup XML exato com a VM desligada
e repita o verificador. A criação da pasta de backups é independente da mutação
XML: uma pasta existente não prova que um backup da VM foi criado.

### Instalador do Windows não mostra o QCOW2

Na tela de discos do instalador, carregue o driver correspondente ao barramento
configurado. O fluxo atual usa:

```text
viostor\w11\amd64
```

Não inicialize ou formate o HD1 físico por engano. Compare capacidade e função
de cada disco antes de qualquer operação dentro do Windows.

## 8. Rede bridge e NAT

Faça mudanças de rede em console local ou em uma janela de manutenção. Bridge,
UFW e SSH podem cortar a sessão usada para administrar o host.

### Diagnóstico suportado

```bash
bash etapas/60-rede-bridge.sh --verificar
```

No modo bridge, o verificador comprova bridge UP, uplink como porta, NIC da VM
identificada por MAC em `source bridge`, IPs coerentes e NAT gerenciado inativo.
No modo NAT, comprova uplink IPv4 efetivo, rede libvirt ativa/autostart, XML
persistente e ativo, bridge virtual, reserva DHCP/MAC e NIC em `source network`.

A rede libvirt `default` é separada da rede NAT dedicada deste projeto.

### Falha durante a etapa 19

Antes da primeira mutação, a etapa captura:

- `passthrough.conf`;
- XML inativo da VM;
- `/etc/netplan/90-vm-passthrough-bridge.yaml`;
- existência, persistência, estado e XML da rede libvirt.

Falha ou sinal antes do commit dispara rollback desses componentes. No modo
bridge, `netplan try` também oferece retorno temporizado se a configuração não
for confirmada. Se o script relatar rollback incompleto, não tente uma segunda
execução antes de comparar cada estado preservado.

### Reversão pós-commit da bridge

Não existe `--desfazer`. Em console local:

1. restaure o backup datado exato ou remova somente o arquivo dedicado
   `/etc/netplan/90-vm-passthrough-bridge.yaml` quando ele tiver sido criado
   pelo projeto;
2. valide e aplique:

   ```bash
   sudo netplan generate
   sudo netplan apply
   ```

3. restaure o backup XML exato da VM;
4. confira que o uplink recuperou o endereço e a rota esperados;
5. revise a regra UFW/Airlock antes de depender novamente de SSH;
6. rode os verificadores 60 e 61.

Não altere outros YAMLs do Netplan como atalho.

### Reversão pós-commit do NAT

O NAT não modifica Netplan. Para voltar a NIC da VM:

1. desligue a VM;
2. restaure o XML exato anterior;
3. prove que nenhuma outra VM usa a rede dedicada;
4. somente para uma rede criada e marcada por este projeto, desative e remova a
   definição conforme necessário:

   ```bash
   virsh --connect qemu:///system net-destroy <REDE_LIBVIRT>
   virsh --connect qemu:///system net-undefine <REDE_LIBVIRT>
   ```

Não destrua uma rede homônima sem o marcador do projeto. Para reativar a rede
bootstrap `default`, quando ela já existir:

```bash
virsh --connect qemu:///system net-start default
virsh --connect qemu:///system net-autostart default
```

Na migração bridge para NAT, restaure/remova primeiro o Netplan dedicado e
aplique Netplan. O modo NAT recusa um uplink ainda anexado a uma bridge.

### Critério de sucesso

- etapa 19 retorna 0;
- uplink e rota padrão correspondem ao modo escolhido;
- XML ativo e persistente da rede não divergem;
- NIC da VM usa a fonte esperada pelo seu MAC;
- IPs do host e da VM são coerentes com bridge ou NAT.

## 9. Airlock, SSH e firewall

### Diagnóstico

```bash
bash etapas/61-airlock.sh --verificar
mount | grep airlock
sudo sshd -t
systemctl status ssh
sudo ufw show added
sudo journalctl -t hook-qemu -b --no-pager
```

O verificador cobre workingDisk, interface/IP, conta, bindfs, drop-in SSH, chave,
UFW e hook. Ele não substitui um teste SFTP real a partir do Windows.

O hook do Airlock é fail-open: uma falha de montagem gera journal, mas não
bloqueia a inicialização da VM.

### Falha durante a instalação

Dentro da transação, a etapa preserva e tenta restaurar `fstab`, drop-in SSH,
chave, hook, árvore UFW, estados de conta/grupo, mount e ativação UFW. Pacotes
como `bindfs`, `openssh-server` e `ufw` são instalados antes da transação e não
são removidos pelo rollback. Diretórios vazios também podem permanecer.

Não desabilite UFW ou relaxe SSH globalmente para fazer o verificador passar.
Compare os backups exatos e preserve um acesso administrativo alternativo.

### Chave SFTP

Para trocar apenas a chave:

```bash
bash etapas/61-airlock.sh --instalar-chave
```

A etapa valida a fingerprint, preserva a chave anterior em backup restrito e
não altera nada quando a entrada é vazia.

### Reversão pós-commit

Não há teardown completo. Restaure, nesta ordem e usando somente os backups
anunciados:

1. acesso administrativo alternativo;
2. chave e drop-in SSH;
3. valide com `sudo sshd -t` antes de recarregar SSH;
4. regra UFW marcada pelo projeto e estado anterior do firewall;
5. entrada bindfs marcada no `fstab` e montagem;
6. conta/grupo somente se foram criados exclusivamente para o Airlock;
7. hook e diretórios gerenciados;
8. etapa 20 `--verificar` e teste SFTP real.

A configuração pode aplicar globalmente `PasswordAuthentication no`,
`KbdInteractiveAuthentication no`, `PermitRootLogin no` e política UFW restrita.
Sem console ou chave administrativa alternativa, uma reversão incompleta pode
bloquear o próprio operador.

## 10. CPU pinning, política de memória e isolamento

### Diagnóstico

```bash
bash etapas/52-cpu-pinning-hugepages.sh --verificar
bash etapas/53-cpu-isolation.sh --verificar
grep -E 'HugePages_|Hugetlb|MemAvailable' /proc/meminfo
cat /sys/devices/system/cpu/isolated
```

Com a VM PARADA, o esperado é `HugePages_Total=0` e `Hugetlb=0` em qualquer
modo: nenhuma página fica reservada em repouso. Com a VM LIGADA, nos modos
`hugetlb-2m` e `hugetlb-1g`, `HugePages_Total` sobe para exatamente as páginas
da VM e volta a zero no stop.

O que o hook fez em cada ciclo fica registrado:

```bash
grep 'mem:' /var/log/vm-passthrough/hooks.log     # aquisição e devolução
sudo cat /var/lib/vm-passthrough/<VM_NAME>.memoria # estado da operação
```

O arquivo de estado some (ou fica em `RELEASED`) depois de uma devolução
comprovada. `RECOVERY_REQUIRED` significa que a devolução não pôde ser provada:
o resto da restauração (GPU, display, CPU) continuou, e este item precisa de
revisão manual antes do próximo start.

Com a VM ligada apenas para observação:

```bash
virsh --connect qemu:///system vcpuinfo <VM_NAME>
```

Isolamento (etapa 18) é o que ainda retira CPUs do scheduler geral do host
mesmo sem a VM, e por isso exige confirmação digitada. A etapa 17 mantém ao
menos um core físico completo para o host; a etapa 18 exige a CPU 0 no
housekeeping.

### Desfazer a etapa 17

Com a VM desligada:

```bash
bash etapas/52-cpu-pinning-hugepages.sh --desfazer
```

A reversão é intencionalmente inversa:

1. primeira execução cria backup e remove do XML a exigência de HugePages,
   qualquer que seja o tamanho de página declarado, preservando o pinning;
2. depois de comprovar o XML, execute `--desfazer` novamente para remover
   `default_hugepagesz`, `hugepagesz` e `hugepages` da persistência de boot.
   Essa fase existe para hosts que vieram do contrato antigo: a etapa 17 nunca
   mais grava essas chaves, e o `--desfazer` é o único caminho que as toca;
3. reinicie quando solicitado;
4. repita os verificadores 52 e 53.

Não remova apenas uma das três chaves de boot. Enquanto qualquer uma delas
existir, a etapa 17 recusa aplicar, em qualquer modo: o host ficaria com página
reservada permanentemente e o XML declarando outra política.

### Desfazer a etapa 18

```bash
bash etapas/53-cpu-isolation.sh --desfazer
```

O fluxo remove conjuntamente `isolcpus`, `nohz_full` e `rcu_nocbs`, valida a
persistência e exige reboot para comprovar o efeito. Se for necessário mudar o
mapa de pinning enquanto existe isolamento antigo, desfaça primeiro a etapa 18,
reinicie e só então altere a etapa 17.

### VM não inicia nos modos `hugetlb-*`

O start é recusado **pelo hook `prepare`**, de propósito e antes de derrubar o
display manager ou destacar a GPU: o desktop continua de pé. A causa está no
log, na linha `mem ERRO`:

```bash
grep 'mem ERRO' /var/log/vm-passthrough/hooks.log | tail -5
sudo cat /var/lib/vm-passthrough/<VM_NAME>.memoria
```

As causas, e o que cada uma quer dizer:

- **consumidor externo, `resv` ou `surplus` no pool**: outra VM ou processo já
  usa páginas desse pool. Não há como distinguir "nossa" de "dele" na devolução,
  então o start é recusado em vez de arriscar tirar página de terceiro. É
  transitória: some quando o outro consumidor sair;
- **alocação parcial**: o kernel entregou menos páginas do que o pedido. Em
  `hugetlb-1g` isso é esperado após uptime longo, porque cada página exige
  1 GiB fisicamente contíguo. O hook devolve o que adquiriu e recusa;
- **`MEM_PLANO_VALIDO=0`**: a recusa é ESTRUTURAL (modo desconhecido, RAM não
  múltipla do tamanho de página, pool ausente, NUMA divergente) e viajou assada
  no hook. Ela não se resolve esperando: corrija a configuração e **reexecute a
  etapa 14** para reassar os hooks.

Se o modo escolhido não for viável neste host, volte para `MEMORIA_MODO=normal`
pela etapa 3 e reexecute as etapas 17 e 14. Memória comum é o baseline do
requisito, não um remendo. Não reduza a reserva de RAM do host para forçar a
configuração, e use `--desfazer` em vez de editar XML e kernel separadamente.

## 11. Snapshots, backups e restauração

### Snapshot interno: retorno rápido, não backup

```bash
bash util/snapshot-vm.sh criar [nome] [descricao]
bash util/snapshot-vm.sh listar
bash util/snapshot-vm.sh reverter <nome>
bash util/snapshot-vm.sh apagar <nome>
```

O utilitário cria snapshot interno somente no disco cujo caminho é exatamente
`QCOW2_PATH`; HD1 e outros discos recebem `snapshot=no`. Criar e reverter exigem
VM desligada. O utilitário recusa snapshots externos legados ou metadados que
não comprovem exatamente um disco interno.

Reverter descarta todas as mudanças posteriores no QCOW2. Apagar um snapshot
não tem desfazer. Snapshots usam o mesmo armazenamento e não protegem contra
falha física, perda do XML, NVRAM, TPM ou configuração do host.

### Backup da VM

```bash
bash util/backup-vm.sh
```

`BACKUPS_VM_DIR` tem prioridade. Sem ele, o fallback é
`<WORKING_DISK_PATH>/backups-vm` somente quando o workingDisk está configurado.
O utilitário tenta desligamento ACPI, nunca usa `destroy`, valida o XML inativo,
recusa overlay/backing chain, confere espaço, copia sparse e executa
`qemu-img check`.

O conjunto pode incluir:

- QCOW2 principal;
- XML inativo;
- NVRAM;
- estado swtpm, quando encontrado;
- `ESCOPO-NAO-INCLUIDO.txt`.

Não inclui:

- HD1 ou outros discos físicos/adicionais;
- ISOs;
- configuração do host, hooks, boot, rede ou firewall;
- conteúdo do Airlock;
- consistência de aplicações dentro do Windows.

### Restauração

O projeto não possui utilitário de restauração. Não substitua arquivos de
produção diretamente para “testar” um backup. Um conjunto só deve ser tratado
como recuperável depois de:

1. ler `ESCOPO-NAO-INCLUIDO.txt`;
2. verificar integridade e backing chain do QCOW2 copiado;
3. revisar XML, NVRAM e TPM como um conjunto;
4. testar em VM/ambiente isolado, sem GPU/HD1/rede de produção;
5. documentar o procedimento específico daquele conjunto;
6. manter ao menos uma cópia offsite e em armazenamento fisicamente separado.

### Atualização do host não é rollback do host

`util/atualizar-host.sh` tenta criar snapshot offline antes de `apt
full-upgrade`. Se não conseguir, exige a frase reforçada `CONTINUAR SEM
SNAPSHOT`. Mesmo quando criado, esse snapshot protege somente o QCOW2; não
reverte kernel, NVIDIA, initramfs ou pacotes do host.

## 12. Configuração e inventário

### Diagnóstico

```bash
bash etapas/00-inventario.sh --verificar
bash etapas/02-detectar-config.sh --verificar
bash menu.sh --status
```

A etapa 1 publica o inventário validado em
`~/.local/state/vm-passthrough/inventario/inventario-<timestamp>.txt` (raiz única
de estado, que respeita `XDG_STATE_HOME`) e troca atomicamente o link
`ultimo-inventario.txt`. Uma coleta interrompida não substitui o último
inventário válido. Existindo a pasta antiga `~/inventario-hardware/`, a etapa 1
oferece uma migração conferida item por item (caminhos, contagem, tipo, modo,
mtime, alvo de link e digest) que só remove a origem depois da conferência;
recusar é seguro e não copia nem remove nada.

### Redetectar hardware

A execução normal da etapa 3 e `--redetectar`:

1. criam backup restrito em
   `backups/passthrough.conf.pre-redetectar-<timestamp>...bak`;
2. limpam atomicamente as escolhas administradas;
3. recomeçam a configuração em `Etapa 3.1/8`;
4. preservam opções externas ao fluxo, como caminhos de QCOW2, nomes de bridge,
   MAC, bind e destino de backup.

Cancelamento depois do reset não restaura automaticamente as escolhas antigas.
Não execute etapas dependentes com uma configuração incompleta.

### Restaurar uma configuração anterior

Não existe subcomando de restauração. Para voltar:

1. escolha o backup exato anterior à redetecção;
2. compare hardware, BDFs, discos, bootloader e uplink atuais;
3. restaure o arquivo preservando propriedade e modo restrito;
4. não use `source` para validá-lo;
5. rode etapa 3 `--verificar` e depois `menu.sh --status`;
6. se o hardware mudou, não force o backup antigo: faça novo inventário e nova
   detecção.

Inventários e diagnósticos também contêm identificadores sensíveis. Guarde uma
cópia fora do disco do sistema, mas não os publique sem revisão.

## 13. Windows convidado

### Desligar o Windows não devolve a GPU

Desative Fast Startup e hibernação dentro da VM executando, como administrador:

```text
windows/Desativar-Fast-Startup.ps1
```

Depois desligue pelo Windows e confirme no host que `domstate` chegou a
`shut off`. Suspensão, hibernação ou guest travado não equivalem a desligamento
completo para o utilitário de recuperação.

### Instalador não encontra o disco

Carregue `viostor\w11\amd64` a partir da ISO VirtIO usada pelo projeto. Confira o
tamanho antes de inicializar qualquer disco para não selecionar o HD1 físico.

### Guest agent não responde

Isso pode significar VM desligada, guest tools ausentes ou serviço parado. Após
instalar `virtio-win-guest-tools.exe`, teste no host:

```bash
virsh --connect qemu:///system qemu-agent-command <VM_NAME> '{"execute":"guest-ping"}'
```

Resposta esperada:

```json
{"return":{}}
```

### NVIDIA Code 43, tela preta ou instabilidade

1. preserve os logs do host e o estado do Gerenciador de Dispositivos;
2. confirme XML/GPU com a etapa 14;
3. faça instalação limpa do driver NVIDIA dentro do Windows;
4. teste uma mudança de firmware por vez;
5. Re-Size BAR pode ser testado desabilitado como diagnóstico e restaurado se
   não alterar o problema;
6. não aplique ACS override nem manipule sysfs no host.

Para interrupções/latência da GPU dentro do Windows, o script opcional
`windows/Ativar-MSI-GPU.ps1` deve ser executado como administrador somente após
a VM básica estar estável.

## 14. Atualização do host

Depois de kernel, driver NVIDIA ou pacotes libvirt:

```bash
bash util/atualizar-host.sh --validar
bash menu.sh --status
bash util/diagnostico.sh
```

Valide nesta ordem:

1. host iniciou no bootloader esperado;
2. driver NVIDIA e `nvidia-smi`;
3. IOMMU/VFIO e grupo da GPU;
4. libvirt e XML inativo;
5. hooks e recuperação da GPU;
6. CPU/HugePages/isolation;
7. rede e Airlock;
8. ciclo completo ligar/desligar da VM.

Não tente reverter pacotes usando o snapshot da VM. Rollback de kernel ou
pacotes é específico da distribuição e não é automatizado por este projeto.
Antes de remover um kernel antigo, mantenha ao menos uma entrada de boot
conhecidamente funcional.

## 15. Caminhos importantes

| Caminho | Função | Observação |
|---|---|---|
| `~/.local/state/vm-passthrough/inventario/` | inventários, diagnósticos e grupos IOMMU | raiz única de estado (respeita `XDG_STATE_HOME`); a etapa 1 oferece migração conferida da pasta antiga `~/inventario-hardware/` e recusar é seguro; pode conter identificadores sensíveis |
| `backups/` | XML e backups locais de configuração | não equivale ao backup completo da VM |
| `<BACKUPS_VM_DIR>` | conjuntos produzidos por `backup-vm.sh` | confirme disco físico e espaço |
| `/run/libvirt-gpu-passthrough/` | state file da entrega dinâmica da GPU | não remova manualmente |
| `/run/libvirt-gpu-locks/` | locks de hooks/recuperação | estado efêmero de runtime |
| `/etc/libvirt/hooks/qemu.d/<VM_NAME>/` | hooks gerenciados da VM | não misture scripts legados |
| `/etc/modules-load.d/vfio.conf` | carregamento persistente de VFIO | gerenciado pela etapa 11 |
| `/etc/netplan/90-vm-passthrough-bridge.yaml` | Netplan dedicado da bridge | não existe no modo NAT |
| `/etc/ssh/sshd_config.d/10-airlock.conf` | drop-in SSH do Airlock | valide com `sshd -t` |
| `/etc/ssh/authorized_keys/<TRANSFER_USER>` | chave SFTP restrita | root-only |
| `/etc/fstab.bak-<data>` | backup relacionado a mudanças de montagem | use o caminho exato anunciado |

Nomes e caminhos podem variar conforme a configuração. Não substitua um caminho
real por um exemplo sem confirmar sua origem.

## 16. O que este projeto não recupera automaticamente

- restauração completa de um conjunto criado por `backup-vm.sh`;
- HD1, outros discos físicos e dados do Airlock;
- rollback de kernel, driver ou pacotes do host;
- live media/chroot genérico para qualquer layout de disco;
- ACS override;
- CPU Intel;
- sessão gráfica anterior à entrega da GPU;
- reset físico de uma GPU travada;
- teardown pós-commit completo das etapas 11, 12, 14, 19, 20 e 21;
- consistência de aplicações e dados abertos dentro do Windows.

Quando o mecanismo necessário não existir, pare e crie um plano específico com
backup verificável. Não converta uma lacuna de automação em uma sequência de
comandos destrutivos improvisados.

## 17. Checklist depois da recuperação

Antes de considerar o incidente encerrado:

```bash
bash menu.sh --status
bash util/diagnostico.sh
```

Confirme também:

- VM desligada antes de qualquer nova mutação;
- nenhuma mensagem de rollback incompleto;
- `nvidia-smi` funcional no host;
- XML inativo e estado persistente coerentes;
- boot, HugePages e CPUs isoladas coerentes após reboot;
- rede e acesso administrativo funcionando pelo caminho esperado;
- ciclo completo de start e shutdown da VM;
- snapshot antigo não confundido com backup;
- novo backup offline criado e testado quando o incidente afetou dados.

Registre causa, evidência, arquivo restaurado e resultado dos verificadores. Isso
evita que um workaround temporário se torne uma dependência silenciosa do host.
