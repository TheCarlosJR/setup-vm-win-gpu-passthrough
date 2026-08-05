# Windows 11 em Máquina Virtual com GPU Passthrough sobre Pop!_OS

## Manual Técnico de Implantação, Configuração e Operação

**Objetivo:**

Documentação permanente de ambiente. Este documento foi escrito para permitir que qualquer administrador reproduza, audite e mantenha exatamente a configuração aqui descrita.

**Ambiente de referência:**
- Pop!_OS (host)
- Windows 11 (convidado, KVM/QEMU/Libvirt, VFIO GPU Passthrough de GPU única)
- AMD Ryzen 7 5700X
- NVIDIA RTX 3060
- RAM 32 GB DDR4 3200 MHz
- Placa mãe - ASUS TUF Gaming B550-Plus WiFi II

---

## Como usar este documento

Este manual não é um resumo nem um conjunto de dicas soltas. Ele é um procedimento operacional completo, escrito na forma de livro técnico, capítulo a capítulo, na ordem em que as ações devem ser executadas em um sistema novo, partindo de hardware recém-montado até uma máquina virtual Windows 11 totalmente funcional com aceleração gráfica nativa via GPU Passthrough.

Cada capítulo segue rigorosamente a seguinte estrutura:

| Seção | Finalidade |
|---|---|
| **Objetivo** | O que o capítulo entrega ao final, em termos concretos e verificáveis |
| **Pré-requisitos** | O que precisa já estar pronto antes de iniciar o capítulo |
| **Explicação** | O raciocínio técnico: por que o procedimento existe, como funciona internamente, vantagens e desvantagens das escolhas feitas |
| **Comandos** | Os comandos exatos, em blocos de código, com explicação linha a linha |
| **Arquivos modificados** | Lista explícita de todo arquivo criado, editado ou removido no capítulo |
| **Como verificar** | Comandos e critérios objetivos para confirmar que a etapa funcionou |
| **Resultado esperado** | Descrição do estado do sistema ao final do capítulo |
| **Como desfazer** | Procedimento de rollback, comando a comando |
| **Problemas comuns** | Sintomas, causas prováveis e correções |
| **Próxima etapa** | Para onde seguir no documento |

### Convenção de placeholders

Este documento **nunca inventa** valores que só existem no hardware do leitor: identificadores PCI, UUIDs de disco, nomes de dispositivo `/dev/sdX`, números de grupo IOMMU, endereços MAC, seriais de disco, etc. Sempre que um comando depende de um valor desse tipo, ele aparece como um *placeholder* entre `<` e `>`, e o capítulo correspondente explica exatamente qual comando executar para descobrir o valor real antes de substituí-lo.

Tabela de placeholders usados ao longo do documento:

| Placeholder | Significado | Como obter |
|---|---|---|
| `<GPU_PCI_ID>` | Endereço PCI da função de vídeo da RTX 3060 (ex.: `0000:0c:00.0`) | `lspci -nnk` — Capítulo 16 |
| `<GPU_AUDIO_PCI_ID>` | Endereço PCI da função de áudio HDMI da RTX 3060 (ex.: `0000:0c:00.1`) | `lspci -nnk` — Capítulo 16 |
| `<GPU_VENDOR_DEVICE_ID>` | Par `vendor:device` da GPU (ex.: `10de:2504`) | `lspci -nn` — Capítulo 16 |
| `<GPU_AUDIO_VENDOR_DEVICE_ID>` | Par `vendor:device` do áudio HDMI da GPU | `lspci -nn` — Capítulo 16 |
| `<IOMMU_GROUP_GPU>` | Número do grupo IOMMU em que a GPU está isolada | Script de listagem de grupos — Capítulo 16 |
| `<UUID_HD2>` | UUID do sistema de arquivos do HD2 (NTFS, `/mnt/docs4`) | `blkid` — Capítulo 11 |
| `<UUID_HD1>` | UUID (ou serial estável) do HD1, usado apenas para identificação, nunca montado no host | `blkid` / `ls -la /dev/disk/by-id` — Capítulo 11 e 19 |
| `<HD1_BY_ID_PATH>` | Caminho estável em `/dev/disk/by-id/` do HD1, usado no XML da VM | `ls -la /dev/disk/by-id/` — Capítulo 19 |
| `<NVME_DEVICE>` | Dispositivo de bloco do SSD NVMe (ex.: `/dev/nvme0n1`) | `lsblk` — Capítulo 3 e 5 |
| `<USUARIO_LINUX>` | Nome do usuário Linux (definido como `charles` neste ambiente, conforme especificação) | Definido na instalação — Capítulo 6 |
| `<HOSTNAME>` | Nome de máquina do host | Definido na instalação — Capítulo 6 |
| `<VM_NAME>` | Nome da máquina virtual no libvirt (ex.: `win11`) | Definido pelo administrador — Capítulo 17 |
| `<VERSAO_KERNEL>` | Versão do kernel em execução | `uname -r` |
| `<USB_MOUSE_VENDOR_ID>` / `<USB_MOUSE_PRODUCT_ID>` | IDs do mouse/teclado para passthrough USB dedicado (opcional) | `lsusb` — Capítulo 20 |
| `<REDE_MODO>` | Backend final da VM: `bridge` ou `nat` | Seleção guiada — Capítulo 23 |
| `<REDE_LIBVIRT>` | Nome da rede NAT dedicada (padrão `passthrough-nat`) | `passthrough.conf` / Capítulo 23 |
| `<REDE_BRIDGE_LIBVIRT>` | Bridge virtual do NAT (padrão `virbr-vmnat`) | `passthrough.conf` / Capítulo 23 |
| `<REDE_NAT_CIDR>` | Sub-rede privada `/24` sem colisões | Selecionada/validada pela etapa 60 |
| `<INTERFACE_AIRLOCK>` | `REDE_BRIDGE` em bridge ou `REDE_BRIDGE_LIBVIRT` em NAT | Derivada de `<REDE_MODO>` — Capítulo 24 |
| `<INICIO_DHCP>` / `<FIM_DHCP>` | Faixa dinâmica derivada da sub-rede NAT | Gerada pela etapa 60 |
| `<INTERFACE_FISICA>` | Uplink físico escolhido, Ethernet ou Wi-Fi (ex.: `enp5s0`, `wlp4s0`) | Enumeração por `/sys/class/net/*/device` — Capítulo 23 |
| `<VM_NIC_MAC>` | MAC persistido da NIC VirtIO; identifica a NIC sem depender da posição no XML | Etapa 40 / migração na etapa 60 — Capítulo 23 |
| `<VM_IP_FIXO>` | IP estável da VM: reserva no roteador (bridge) ou no DHCP libvirt (NAT) | Capítulos 23 e 24 |
| `<IP_FIXO_HOST>` | Endereço do host visto pela VM: IP LAN de `br0` ou gateway da bridge NAT | Capítulos 23 e 24 |
| `<TRANSFER_USER>` | Usuário de sistema dedicado às transferências do airlock (ex.: `vmtransfer`) | Definido pelo administrador — Capítulo 24 |

> **📝 NOTA:** Nunca copie e cole um comando contendo um placeholder sem antes substituí-lo pelo valor real do seu equipamento. Comandos com placeholders não substituídos falham propositalmente (o texto entre `<>` não é um caminho, UUID ou ID válido em nenhum sistema), como proteção contra execução acidental de um comando incompleto.

### Blocos usados neste documento

> **📝 NOTA:** Informação complementar, contexto ou explicação conceitual.

> **💡 DICA:** Prática recomendada, atalho ou forma de economizar tempo.

> **⚠️ ALERTA:** Ação com risco real de perda de dados, indisponibilidade do sistema ou necessidade de mídia de recuperação. Leia por completo antes de prosseguir.

> **🛑 PONTO DE NÃO RETORNO:** Etapas que, uma vez executadas, exigem procedimento de recuperação específico (não são revertidas com `Ctrl+C`).

---

## Sumário

1. Introdução
2. Arquitetura do Ambiente
3. Inventário de Hardware
4. Planejamento
5. Organização dos Discos
6. Instalação Limpa do Pop!_OS
7. Atualização do Sistema
8. Drivers NVIDIA no Host
9. Instalação dos Pacotes Base
10. Estrutura de Diretórios
11. Configuração Completa do Docs4 (fstab, UUID, ntfs-3g, windows_names, bind mounts)
12. Configuração da BIOS/UEFI (ASUS TUF Gaming B550-Plus WiFi II)
13. Instalação de KVM, QEMU, Libvirt, Virt-Manager, OVMF, SWTPM e VirtIO
14. Configuração de Usuário, Grupos e Serviços
15. Bootloader: GRUB vs systemd-boot no Pop!_OS
16. Configuração Completa de IOMMU e VFIO
17. Criação da Máquina Virtual no Virt-Manager
18. Instalação do Windows 11 e Drivers VirtIO/NVIDIA
19. GPU Passthrough Dinâmico (Hook Scripts) e HD1 Físico
20. Áudio HDMI e USB Passthrough
21. CPU Pinning, NUMA e HugePages
22. CPU Isolation e MSI Interrupts
23. Rede da VM: Bridge Ethernet ou NAT Libvirt
24. Compartilhamento Seguro de Arquivos (Airlock)
25. TRIM, Snapshots e Backup
26. Atualizações e Manutenção Contínua
27. Benchmarks
28. Troubleshooting
29. Recuperação de Emergência

---

# Capítulo 1 — Introdução

## Objetivo

Estabelecer o contexto, os objetivos técnicos, as premissas e os limites deste projeto, para que qualquer leitor — mesmo sem ter acompanhado decisões anteriores — entenda exatamente o que está sendo construído e por quê, antes de tocar em qualquer comando.

## Pré-requisitos

Nenhum. Este é o capítulo inicial do documento.

## Explicação

### O que é GPU Passthrough

GPU Passthrough é a técnica de ceder um dispositivo PCI Express físico — neste caso, uma placa de vídeo inteira, com sua GPU, memória VRAM, BIOS de vídeo (vBIOS) e função de áudio HDMI/DisplayPort — diretamente ao controle exclusivo de uma máquina virtual, removendo esse dispositivo do controle do sistema operacional hospedeiro (host) durante o tempo em que a VM o utiliza.

Isso é fundamentalmente diferente de virtualização de GPU tradicional (como um adaptador de vídeo virtual `virtio-gpu`, `qxl` ou `vmware svga`), na qual o host renderiza e repassa quadros já prontos para a VM. Em passthrough, o hypervisor apenas concede à VM acesso direto de leitura e escrita aos registradores PCI, à memória mapeada (MMIO) e às interrupções do dispositivo físico. O driver NVIDIA **dentro da VM Windows** conversa diretamente com o silício da GPU, sem intermediação de emulação gráfica. O resultado é desempenho de vídeo dentro da VM equivalente — tipicamente entre 95% e 99% — ao desempenho da mesma GPU rodando nativamente (bare metal), pois praticamente não há camada de tradução entre o jogo/aplicação e o hardware.

Isso é possível graças a três tecnologias de virtualização de hardware presentes no processador, no chipset e no firmware:

- **IOMMU (Input-Output Memory Management Unit)**: na plataforma AMD, chamado de **AMD-Vi**. É uma unidade de hardware que faz para dispositivos PCI o que a MMU da CPU faz para processos: tradução e isolamento de endereços de memória. Sem IOMMU, qualquer dispositivo PCI com acesso DMA (Direct Memory Access) poderia ler e escrever em qualquer endereço físico de RAM do sistema, o que tornaria repassar um dispositivo a uma VM um risco de segurança e estabilidade inaceitável (a VM, ou um driver malicioso dentro dela, poderia ler/escrever memória do host). O IOMMU cria uma tabela de tradução de endereços por dispositivo, restringindo o DMA da GPU passthrough apenas à memória alocada à VM.
- **VFIO (Virtual Function I/O)**: framework do kernel Linux que expõe um dispositivo PCI isolado pelo IOMMU como um nó de dispositivo seguro em userspace (`/dev/vfio/<grupo>`), que o QEMU consegue abrir e repassar à VM sem exigir um driver de kernel privilegiado dedicado a cada dispositivo.
- **SVM (Secure Virtual Machine)**: nome que a AMD dá à sua tecnologia de virtualização de CPU (equivalente ao Intel VT-x), que permite que o QEMU/KVM execute código de convidado diretamente na CPU física, em um modo com anéis de proteção adicionais, em vez de emular a CPU inteira em software.

### Por que Passthrough de GPU única (Single-GPU Passthrough)

O Ryzen 7 5700X **não possui GPU integrada** (é um processador da família Zen 3 sem gráficos integrados — os modelos com sufixo "G" possuem, o 5700X não). Isso significa que a RTX 3060 é a **única** GPU física do sistema. Diferente de um cenário com duas GPUs (uma dedicada ao host, outra dedicada à VM, popularmente chamado de *dual-GPU passthrough*), este ambiente exige uma técnica chamada **single-GPU passthrough**: a GPU é usada pelo Linux normalmente durante o uso diário, e é dinamicamente desacoplada do driver `nvidia` e reacoplada ao driver `vfio-pci` no exato momento em que a VM Windows é iniciada — e o processo é revertido automaticamente quando a VM é desligada.

Essa dinâmica é implementada via **hook scripts do libvirt**: pequenos scripts de shell, disparados automaticamente pelo `libvirtd` nos eventos de ciclo de vida da VM (`prepare`, `start`, `stopped`, `release`), que:

1. No início do boot da VM (`prepare/begin`): param o gerenciador de exibição gráfica (display manager), descarregam o driver `nvidia` da GPU, e vinculam a GPU ao driver `vfio-pci`.
2. No desligamento da VM (`release/end`): desvinculam a GPU do `vfio-pci`, recarregam o driver `nvidia`, e reiniciam o gerenciador de exibição, devolvendo o vídeo ao Linux.

Este comportamento está descrito no Capítulo 19 em profundidade, incluindo os scripts completos, comentados linha a linha.

> **⚠️ ALERTA:** Durante o tempo em que a VM Windows estiver ligada, o monitor conectado à RTX 3060 **não exibirá nada do Linux**. A tela ficará preta ou mudará de sinal (dependendo do monitor) até a VM assumir o controle da saída de vídeo. Isso é esperado e faz parte do desenho da solução, não é uma falha.

### O que este documento NÃO cobre

- Dual boot (não haverá; o Windows só existe dentro da VM).
- Passthrough de GPU AMD ou Intel (o procedimento é análogo, mas os nomes de driver e algumas particularidades de reset de dispositivo mudam).
- Ambientes com duas GPUs físicas (o procedimento seria mais simples, sem necessidade de hook scripts dinâmicos).
- Virtualização aninhada (nested virtualization) dentro da VM Windows.

### Premissas assumidas

| Item | Valor assumido | Onde é definido |
|---|---|---|
| Sistema hospedeiro | Pop!_OS (base Ubuntu LTS, kernel Linux, systemd) | Capítulo 6 |
| Usuário Linux principal | `charles` | Capítulo 6 |
| CPU | AMD Ryzen 7 5700X (8 núcleos / 16 threads, sem iGPU) | Capítulo 3 |
| GPU | NVIDIA RTX 3060 (única GPU do sistema) | Capítulo 3 |
| RAM | 32 GB DDR4 3200 MHz | Capítulo 3 |
| Placa-mãe | ASUS TUF Gaming B550-Plus WiFi II (chipset AMD B550, firmware UEFI AMI) | Capítulo 3 e 12 |
| Disco do sistema | 1x SSD NVMe | Capítulo 5 |
| HD1 | Disco NTFS dedicado exclusivamente à VM (passthrough físico) | Capítulo 5 e 19 |
| HD2 | Disco NTFS dedicado exclusivamente ao Linux, montado em `/mnt/docs4` | Capítulo 5 e 11 |
| Disco virtual da VM | `/vm/Windows11.qcow2`, QCOW2, alocação dinâmica, capacidade nominal 250 GB | Capítulo 17 |
| Pasta de trânsito Host↔VM ("airlock") | `/mnt/docs4/airlock` — única via de troca de arquivos com a VM; os diretórios reais do HD2 jamais são expostos | Capítulo 24 |
| Usuário de transferência | `<TRANSFER_USER>` — conta de sistema dedicada, sem shell e sem home, exclusiva do airlock | Capítulo 24 |
| Antivírus do convidado | Windows Defender (nativo), com proteção em tempo real ativa — sem EDR/AV de terceiros | Capítulos 18 e 24 |

## Comandos

Não aplicável neste capítulo — é introdutório e conceitual.

## Arquivos modificados

Nenhum.

## Como verificar

Não aplicável. Prossiga para o Capítulo 2.

## Resultado esperado

O leitor compreende o que é GPU Passthrough, por que este ambiente específico exige a variante de GPU única, quais tecnologias de hardware tornam isso possível (SVM, IOMMU, VFIO) e quais são as premissas fixas assumidas em todo o restante do documento.

## Como desfazer

Não aplicável.

## Problemas comuns

Não aplicável neste capítulo.

## Próxima etapa

Capítulo 2 — Arquitetura do Ambiente, onde o desenho final de discos, diretórios e fluxo de dados é apresentado visualmente antes de qualquer execução prática.

---

# Capítulo 2 — Arquitetura do Ambiente

## Objetivo

Apresentar, em diagramas e tabelas, a arquitetura final de armazenamento, diretórios e virtualização que este documento constrói, servindo como mapa de referência para todos os capítulos seguintes.

## Pré-requisitos

- Capítulo 1 lido.

## Explicação

### Visão geral de armazenamento

O ambiente possui três discos com papéis estritamente segregados. Essa segregação não é incidental: ela existe para que uma falha, reinstalação ou substituição de qualquer um dos discos afete o menor escopo possível.

```text
┌────────────────────────────────────────────────────────────────────────────┐
│                                   HOST FÍSICO                              │
│                                                                            │
│  ┌──────────────────────┐   ┌─────────────────────┐  ┌──────────────────┐  │
│  │  SSD NVMe            │   │   HD1 (NTFS)        │  │  HD2 (NTFS)      │  │
│  │  Pop!_OS             │   │   Exclusivo da VM   │  │  Exclusivo Linux │  │
│  │                      │   │                     │  │                  │  │
│  │  /        (raiz)     │   │  NÃO montado no     │  │  Montado em      │  │
│  │  /home               │   │  host.              │  │  /mnt/docs4      │  │
│  │  /var                │   │  Passado como       │  │                  │  │
│  │  /etc                │   │  disco físico cru   │  │  Bind mounts →   │  │
│  │  /vm/Windows11.qcow2 │   │  para dentro da VM  │  │  ~/Documentos    │  │
│  │                      │   │  (passthrough de    │  │  ~/Downloads     │  │
│  │                      │   │  disco inteiro)     │  │  ~/Imagens       │  │
│  │                      │   │                     │  │  ~/Músicas       │  │
│  │                      │   │  Contém: Steam,     │  │  ~/Vídeos        │  │
│  │                      │   │  Epic, Battle.net,  │  │                  │  │
│  │                      │   │  Jogos, Downloads   │  │                  │  │
│  │                      │   │  (do Windows)       │  │                  │  │
│  └──────────────────────┘   └─────────────────────┘  └──────────────────┘  │
└────────────────────────────────────────────────────────────────────────────┘
```

### Por que o HD1 é passthrough físico, e não pasta compartilhada

A especificação deste ambiente exige explicitamente que o HD1 seja entregue à VM como **disco físico**, e não como compartilhamento de pasta (isto excluiria tecnologias como VirtIO-FS, Samba ou 9p). As razões técnicas que sustentam essa decisão:

| Critério | Disco físico (passthrough) | Pasta compartilhada (VirtIO-FS/Samba/9p) |
|---|---|---|
| Compatibilidade com launchers (Steam, Epic, Battle.net) | Total — o Windows enxerga um disco NTFS nativo | Parcial — muitos jogos com anticheat/DRM rejeitam ou falham em unidades de rede/compartilhadas |
| Desempenho de I/O | Nativo (limitado apenas pela interface física do disco) | Overhead de protocolo de rede/compartilhamento |
| Permissões e atributos NTFS | Preservados nativamente pelo Windows | Podem ser traduzidos incorretamente pelo host |
| Complexidade de configuração | Baixa (um bloco `<disk>` no XML da VM) | Média/alta (serviço adicional, exportação, permissões) |
| Acesso simultâneo Linux+Windows | Não (ou o host monta, ou a VM monta — nunca os dois ao mesmo tempo) | Sim, mas com risco de corrupção em NTFS |

O HD2, por outro lado, permanece **exclusivamente com o Linux**. Ele nunca é passado à VM. Isso é proposital: o HD2 guarda os diretórios pessoais do usuário Linux (via bind mount), e sua integridade não pode depender da VM estar ligada, desligada, ou de qualquer estado do QEMU.

### Fluxo de arquivos entre Linux e Windows

Como HD2 nunca é compartilhado automaticamente com a VM, a transferência de arquivos entre os dois sistemas é sempre **manual e deliberada**, através da pasta de trânsito **airlock** (`/mnt/docs4/airlock`) — uma zona dedicada exclusivamente a arquivos em trânsito, que nunca guarda dados permanentes do usuário. O mecanismo completo (serviço, autenticação, firewall e automação) é especificado no Capítulo 24. Os métodos, em ordem de preferência:

1. **Pasta airlock via SFTP** (método padrão): a VM acessa, com chave SSH e firewall restrito ao seu IP, exclusivamente a pasta `/mnt/docs4/airlock` — nada além dela (Capítulo 24).
2. **Pasta airlock via Samba hardenizado** (alternativa de conveniência: unidade de rede mapeada no Explorer do Windows — Capítulo 24).
3. Um pen drive ou disco externo USB, passado pontualmente via USB passthrough ou hot-plug (Capítulo 20).
4. Montagem temporária e manual do HD1 no Linux, **somente leitura** e **somente com a VM desligada** (procedimento seguro no Capítulo 24; alertas no Capítulo 19).

```text
┌───────────────┐   SFTP com chave + firewall por IP  ┌──────────────┐
│  Linux Host   │ <─────────────────────────────────> │  VM Windows  │
│  /mnt/docs4   │   SOMENTE /mnt/docs4/airlock        │   HD1 (NTFS) │
│  ~/Documentos │                                     │   C: (qcow2) │
│  ~/Downloads  │        OU pen drive/USB             │              │
└───────────────┘ <─────────────────────────────────> └──────────────┘
```

> **⚠️ ALERTA:** Nenhum mecanismo de compartilhamento acessível pela VM deve jamais expor os diretórios reais do HD2 (`Documentos`, `Downloads`, `Imagens`, `Músicas`, `Vídeos`) — nem por SFTP, nem por Samba, nem por qualquer outro serviço. A única pasta visível à VM é `/mnt/docs4/airlock`. Isso preserva o princípio central deste capítulo: a integridade do HD2 não depende do estado da VM, e um malware dentro do Windows (vetor mais provável: downloads e launchers no HD1) não tem caminho de escrita aos dados reais do usuário.

### Diagrama de virtualização

```text
┌────────────────────────────────────────────────────────────────────┐
│  Pop!_OS (host)                                                    │
│  Kernel Linux ── módulos: kvm, kvm_amd, vfio, vfio_pci             │
│                                                                    │
│  libvirtd ──> QEMU/KVM (processo da VM)                            │
│                 │                                                  │
│                 ├── OVMF (firmware UEFI virtual)                   │
│                 ├── SWTPM (TPM 2.0 emulado, requisito Windows 11)  │
│                 ├── vCPUs (host-passthrough, pinadas em núcleos)   │
│                 ├── RAM alocada (hugepages opcionais)              │
│                 ├── /vm/Windows11.qcow2 (disco C:, VirtIO)         │
│                 ├── HD1 (disco físico D:, passthrough)             │
│                 ├── RTX 3060 (VFIO-PCI, passthrough completo)      │
│                 ├── Áudio HDMI da GPU (VFIO-PCI, mesma IOMMU)      │
│                 └── Rede (VirtIO-net: bridge Ethernet ou NAT libvirt)       │
└────────────────────────────────────────────────────────────────────┘
```

## Comandos

Não aplicável — capítulo de referência visual.

## Arquivos modificados

Nenhum.

## Como verificar

Não aplicável.

## Resultado esperado

O leitor tem, antes de executar qualquer comando, uma visão clara e completa do estado final do sistema: quais discos existem, o que cada um contém, como os dados fluem entre Linux e Windows, e como as peças de virtualização se encaixam.

## Como desfazer

Não aplicável.

## Problemas comuns

Não aplicável neste capítulo.

## Próxima etapa

Capítulo 3 — Inventário de Hardware, onde cada componente físico é identificado e documentado com comandos reais, antes do planejamento detalhado.

---

# Capítulo 3 — Inventário de Hardware

## Objetivo

Levantar, com comandos reais executados no próprio host, a identificação completa de cada componente de hardware relevante para a virtualização, deixando registrado o método de obtenção de cada dado — nunca um valor presumido.

## Pré-requisitos

- Pop!_OS já instalado e inicializado (ainda que em modo live/instalador, para inventário preliminar), **ou** qualquer live-CD Linux, caso o inventário seja feito antes da instalação definitiva (Capítulo 6).
- Acesso a um terminal com privilégios de administrador (`sudo`).

## Explicação

Antes de qualquer configuração de VFIO, é indispensável registrar o hardware exato instalado, pois:

- O suporte a IOMMU depende da CPU, da placa-mãe e da versão de firmware — não apenas do modelo genérico.
- Os IDs PCI da GPU (vendor:device) são usados literalmente dentro de arquivos de configuração do kernel (Capítulo 16). Um ID errado direciona o `vfio-pci` para o dispositivo errado, com risco de capturar, por exemplo, uma controladora de rede ou USB por engano.
- O layout de barramento PCI (a que grupo IOMMU cada dispositivo pertence) determina se o passthrough é viável sem patches adicionais (ACS override) ou não.

Cada subseção abaixo corresponde a um componente de hardware e ao comando exato para identificá-lo.

### CPU

```bash
lscpu
```

**O que este comando faz:** consulta `/proc/cpuinfo` e outras interfaces do kernel e apresenta um resumo estruturado do processador: modelo, número de núcleos físicos, threads, cache, e — mais importante para este projeto — as *flags* de CPU, entre as quais deve constar `svm` (suporte à virtualização AMD) na saída de:

```bash
lscpu | grep -i svm
```

Se a saída estiver vazia, o SVM está desabilitado na BIOS (ver Capítulo 12) ou o processador não suporta a extensão (o Ryzen 7 5700X suporta SVM nativamente).

> **📝 NOTA:** `svm` aqui é uma *flag* de CPU relatada pelo kernel, e é diferente do bit de habilitação em runtime, verificado adiante com `kvm-ok` ou por inspeção de `/sys/module/kvm_amd/parameters/nested`.

### Memória RAM

```bash
sudo dmidecode --type memory | less
```

**O que este comando faz:** lê a tabela SMBIOS/DMI da placa-mãe (informação gravada pelo firmware) e reporta cada pente de memória instalado: fabricante, capacidade, velocidade configurada e velocidade máxima suportada. Use isso para confirmar que os módulos DDR4 estão operando no perfil esperado (3200 MHz) — caso contrário, o perfil XMP/DOCP pode não estar habilitado na BIOS (ver Capítulo 12).

Alternativa mais simples, sem detalhes por pente:

```bash
free -h
```

### Placa-mãe e firmware

```bash
sudo dmidecode -t baseboard
sudo dmidecode -t bios
```

**O que estes comandos fazem:** o primeiro identifica fabricante e modelo exatos da placa-mãe (deve confirmar "ASUS" e o modelo "TUF GAMING B550-PLUS WIFI II" ou variação de nome reportada pelo firmware). O segundo relata a versão do firmware UEFI instalado — informação necessária ao consultar o site da ASUS para eventuais atualizações de BIOS que melhorem o suporte a IOMMU/ACS (ver Capítulo 12).

### GPU

```bash
lspci -nnk | grep -A3 -i vga
lspci -nnk | grep -A3 -i "3d controller"
```

**O que estes comandos fazem:** `lspci` lista todos os dispositivos no barramento PCI/PCIe. A flag `-nn` inclui os IDs numéricos `[vendor:device]` de cada dispositivo — os mesmos valores que serão usados como `<GPU_VENDOR_DEVICE_ID>` no Capítulo 16. A flag `-k` mostra qual driver de kernel está atualmente associado ao dispositivo (`Kernel driver in use:`). Filtrar por `vga` localiza a função de vídeo principal; a função de áudio HDMI da mesma placa aparece como um dispositivo PCI **separado**, mas no mesmo endereço de barramento, variando apenas a função (ex.: `0c:00.0` para vídeo, `0c:00.1` para áudio) — será detalhada no Capítulo 16.

> **⚠️ ALERTA:** Não copie os IDs de exemplo mostrados nas explicações genéricas encontradas em fóruns e tutoriais na internet. Os IDs PCI variam por modelo exato de placa, revisão e até mesmo posição do slot. **Sempre** use o resultado do `lspci -nnk` executado no seu próprio host, no Capítulo 16.

### Discos

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL
```

**O que este comando faz:** lista todos os dispositivos de bloco reconhecidos pelo kernel, com tamanho, sistema de arquivos (se já formatado), ponto de montagem atual e — crucialmente — modelo e número de série, que permitem identificar sem ambiguidade qual dispositivo físico (`/dev/sda`, `/dev/sdb`, `/dev/nvme0n1`, etc.) corresponde ao NVMe, ao HD1 e ao HD2 antes de particionar ou formatar qualquer um deles.

> **⚠️ ALERTA:** Os nomes `/dev/sdX` **não são estáveis** entre reinicializações — a ordem de enumeração de discos SATA/USB pode mudar conforme a ordem de inicialização dos controladores. Por isso, a partir do Capítulo 5, todas as referências permanentes a discos (fstab, XML da VM) usam identificadores estáveis (`UUID` ou `/dev/disk/by-id/...`), nunca `/dev/sdX` diretamente.

### IOMMU (suporte do firmware)

```bash
dmesg | grep -i -e DMAR -e IOMMU
```

**O que este comando faz:** procura, no log de boot do kernel, mensagens emitidas durante a inicialização do subsistema IOMMU. Antes de habilitar explicitamente o IOMMU via parâmetro de kernel (Capítulo 16), esse comando normalmente mostra pouco ou nada; ele volta a ser relevante — e essencial — **depois** da configuração do Capítulo 16, como parte da verificação daquele capítulo.

## Comandos

Resumo de todos os comandos deste capítulo, para execução sequencial e registro em log:

O script `etapas/00-inventario.sh` implementa esta coleta com publicação segura:
gera um temporário, publica `inventario-AAAAMMDD-HHMMSS-NNNNNNNNN.txt` somente
após todas as seções terminarem e troca atomicamente o symlink relativo
`ultimo-inventario.txt`. Assim, duas coletas no mesmo dia não se sobrescrevem e
uma coleta interrompida não substitui o último relatório completo.

```bash
bash etapas/00-inventario.sh
```

**O que este bloco faz:** executa todos os comandos de inventário em sequência e grava a saída completa em um arquivo de texto com data, usando `tee` para exibir na tela e salvar simultaneamente. Esse arquivo se torna a referência primária de hardware para o restante do documento — recomenda-se guardá-lo fora do disco que será reinstalado (Capítulo 6), por exemplo em um pen drive ou anotado externamente.

## Arquivos modificados

- `~/inventario-hardware/inventario-<data>-<hora>-<nanossegundos>.txt` (criado).
- `~/inventario-hardware/ultimo-inventario.txt` (symlink relativo atualizado atomicamente).

## Como verificar

- Abrir o arquivo gerado e confirmar que todas as seções (`CPU`, `RAM`, `BASEBOARD`, `BIOS`, `PCI`, `BLOCK DEVICES`, `IOMMU/DMAR`) possuem conteúdo, sem mensagens de erro de permissão.
- Confirmar visualmente, na seção `PCI`, a presença de uma linha contendo `NVIDIA Corporation` associada a `VGA compatible controller` e outra a `Audio device`, ambas no mesmo barramento (mesmos dois primeiros grupos do endereço, ex.: `0c:00.x`).

## Resultado esperado

Um arquivo de texto único, datado, contendo o inventário completo de CPU, memória, placa-mãe, firmware, dispositivos PCI e discos de bloco, que servirá de base factual para todos os capítulos seguintes — eliminando qualquer necessidade de "adivinhar" IDs, UUIDs ou nomes de dispositivo.

## Como desfazer

```bash
rm -rf ~/inventario-hardware
```

Este capítulo é somente leitura; não há qualquer alteração de configuração do sistema a desfazer.

## Problemas comuns

| Sintoma | Causa provável | Correção |
|---|---|---|
| `dmidecode: command not found` | Pacote `dmidecode` não instalado | `sudo apt install dmidecode` |
| `lscpu` não mostra `svm` | SVM desabilitado na BIOS | Habilitar em Advanced → CPU Configuration → SVM Mode (Capítulo 12) |
| `lspci` não lista a GPU | GPU não assentada corretamente no slot, ou alimentação PCIe não conectada | Verificar fisicamente o encaixe da placa e os conectores de energia de 8 pinos |
| Saída de `dmesg` sobre IOMMU vazia neste estágio | Esperado — IOMMU ainda não foi habilitado via parâmetros de kernel | Normal neste capítulo; será revisitado no Capítulo 16 |

## Próxima etapa

Capítulo 4 — Planejamento, onde os dados coletados aqui são usados para desenhar o particionamento de disco e o layout final antes de qualquer instalação.

---

# Capítulo 4 — Planejamento

## Objetivo

Consolidar decisões de particionamento, nomenclatura e sequenciamento de instalação em um plano único, escrito antes de qualquer ação destrutiva (particionamento/formatação), para reduzir a chance de decisões tomadas "no meio do caminho" sob pressão.

## Pré-requisitos

- Capítulo 3 concluído (inventário de hardware em mãos).

## Explicação

### Ordem de execução recomendada

A ordem dos capítulos deste documento não é arbitrária. Ela segue uma sequência de dependências reais:

```text
 1. Hardware inventariado         (Cap. 3)
 2. Plano de discos definido      (Cap. 4, este capítulo)
 3. BIOS configurada              (Cap. 12) ── precisa ocorrer ANTES da instalação do SO,
                                                pois SVM/IOMMU afetam o que o instalador enxerga
 4. Pop!_OS instalado             (Cap. 6)
 5. Sistema atualizado            (Cap. 7)
 6. Driver NVIDIA no host         (Cap. 8)  ── necessário para uso normal do Linux
                                                ANTES de introduzir VFIO
 7. Pacotes base instalados       (Cap. 9)
 8. Diretórios/Docs4 organizados  (Cap. 10, 11)
 9. Pilha de virtualização        (Cap. 13, 14)
10. VFIO/IOMMU configurados       (Cap. 16) ── por último entre as mudanças de baixo nível,
                                                pois é o passo que efetivamente tira a GPU
                                                do controle permanente do Linux
11. VM criada e Windows instalado (Cap. 17, 18)
12. Passthrough dinâmico ativado  (Cap. 19, 20)
13. Ajustes de desempenho         (Cap. 21, 22)
14. Rede final da VM             (Cap. 23) ── bridge Ethernet ou NAT Ethernet/Wi-Fi
15. Compartilhamento seguro      (Cap. 24) ── depende do IP estável criado
                                                pelo backend selecionado
16. Operação contínua            (Cap. 25 em diante)
```

> **💡 DICA:** Configurar a BIOS (Capítulo 12) antes de instalar o Pop!_OS evita ter que reiniciar em UEFI com CSM/Secure Boot incompatíveis já com o sistema instalado, o que por vezes exige reparo de bootloader.

### Nomenclatura adotada neste documento

| Termo | Definição fixa neste ambiente |
|---|---|
| Host | O sistema Pop!_OS instalado diretamente no hardware físico |
| Guest / VM | A máquina virtual Windows 11 |
| NVMe | SSD interno NVMe, único disco de sistema do host |
| HD1 | Disco NTFS dedicado à VM (passthrough físico), contém Steam/Epic/Battle.net/Jogos/Downloads do Windows |
| HD2 | Disco NTFS dedicado ao host, montado em `/mnt/docs4` |
| Docs4 | Nome do ponto de montagem do HD2 (`/mnt/docs4`) |
| `charles` | Usuário Linux principal |

### Checklist pré-instalação

- [ ] Backup de qualquer dado existente em HD1 e HD2 realizado em mídia externa (a instalação do Pop!_OS tocará apenas o NVMe, mas por prudência, ver alerta abaixo).
- [ ] Mídia de instalação do Pop!_OS gravada e testada (Capítulo 6).
- [ ] BIOS acessível e senha de administrador da BIOS conhecida (se configurada).
- [ ] Inventário de hardware (Capítulo 3) salvo fora do NVMe.
- [ ] Cabo de rede ou Wi-Fi configurável disponível para atualizações (Capítulo 7).

> **⚠️ ALERTA:** Embora o plano deste documento toque apenas o NVMe durante a instalação do Pop!_OS, o instalador do Pop!_OS exibe todos os discos conectados na tela de particionamento. Um clique equivocado no disco errado pode apagar HD1 ou HD2. Recomenda-se **desconectar fisicamente HD1 e HD2** durante a instalação do Pop!_OS (Capítulo 6) e reconectá-los somente depois, especificamente para eliminar esse risco.

## Comandos

Não aplicável — capítulo de planejamento documental. Nenhuma alteração de sistema é feita aqui.

## Arquivos modificados

Nenhum.

## Como verificar

Revisar o checklist acima manualmente, item a item, antes de avançar ao Capítulo 5.

## Resultado esperado

Um plano de ação claro, com ordem de capítulos justificada, nomenclatura fixa e um checklist de segurança cumprido, antes de qualquer operação destrutiva em disco.

## Como desfazer

Não aplicável.

## Problemas comuns

Não aplicável neste capítulo.

## Próxima etapa

Capítulo 5 — Organização dos Discos, que detalha o esquema de partição do NVMe e os cuidados com HD1 e HD2 antes da instalação do sistema.

---

# Capítulo 5 — Organização dos Discos

## Objetivo

Definir o esquema de particionamento do NVMe e o tratamento de HD1 e HD2, preparando o terreno físico de armazenamento antes da instalação do sistema operacional.

## Pré-requisitos

- Capítulo 4 concluído.
- Inventário de hardware (Capítulo 3) com os nomes de dispositivo (`/dev/nvme0n1`, e os discos SATA/HD identificados por modelo/serial).

## Explicação

### Por que o NVMe recebe apenas o sistema operacional

Todo o sistema Pop!_OS — incluindo `/home`, `/var`, `/etc` e o diretório `/vm` onde reside o arquivo de disco virtual `Windows11.qcow2` — vive em um único SSD NVMe. Esta é uma decisão deliberada de simplicidade: `/etc` **não pode**, em uma instalação padrão baseada em Debian/Ubuntu (como o Pop!_OS), ser um ponto de montagem separado do sistema de arquivos raiz, pois o processo de inicialização (`initramfs`, `systemd`) precisa localizar arquivos de configuração em `/etc` antes que qualquer montagem adicional (além da raiz) seja processada a partir do próprio `/etc/fstab`. Ou seja: `/etc/fstab` — que descreve *o que* montar — está dentro de `/etc`, criando uma dependência circular caso `/etc` fosse, ele próprio, uma partição separada montada via fstab.

Por essa razão, a "árvore" mostrada na especificação do projeto (`/home`, `/var`, `/etc`, `/vm` sob o NVMe) é tratada neste documento como uma **estrutura lógica de diretórios dentro de um único sistema de arquivos raiz**, e não como partições fisicamente segregadas — com uma exceção opcional e recomendada: `/home` pode, se desejado, ser uma partição separada dentro do mesmo NVMe, prática comum que facilita reinstalações futuras do sistema sem perder dados de usuário. Este documento adota essa recomendação.

Esquema de partição adotado para o NVMe:

| Partição | Ponto de montagem | Sistema de arquivos | Tamanho sugerido | Finalidade |
|---|---|---|---|---|
| `<NVME_DEVICE>p1` | `/boot/efi` | FAT32 (ESP) | 512 MiB | Partição de sistema EFI, contém o carregador de boot |
| `<NVME_DEVICE>p2` | `/` | ext4 | Restante menos `/home` | Sistema, `/etc`, `/var`, `/vm` |
| `<NVME_DEVICE>p3` | `/home` | ext4 | Conforme espaço livre | Diretórios de usuário (ver Capítulo 11 sobre bind mounts para HD2) |

> **📝 NOTA:** O Pop!_OS moderno frequentemente oferece, por padrão, instalação com **criptografia de disco inteiro** (LUKS) sobre LVM. Essa é uma escolha de segurança do usuário, ortogonal ao passthrough de GPU — pode ser adotada sem qualquer impacto negativo no procedimento de VFIO descrito neste documento. O Capítulo 6 aborda essa opção no momento da instalação.

### Por que `/vm` não é uma partição separada

O diretório `/vm`, onde reside `Windows11.qcow2`, é criado como um diretório comum dentro da partição raiz (Capítulo 10), não como uma partição própria. Isso simplifica o gerenciamento de espaço: como o arquivo QCOW2 tem alocação **dinâmica** (thin-provisioned), reservar uma partição de tamanho fixo para ele desperdiçaria espaço ou exigiria redimensionamento posterior. Mantendo `/vm` na partição raiz, o espaço livre é compartilhado com o restante do sistema.

### HD1 — não tocar durante a instalação do Pop!_OS

HD1 será, mais adiante (Capítulo 19), passado à VM como disco físico completo, exatamente como veio de fábrica ou como já estiver formatado pelo usuário (NTFS). **Nenhuma ação de particionamento deve ser feita em HD1 pelo Linux** além de, opcionalmente, identificá-lo com `lsblk`/`blkid` para fins de documentação — a formatação e o particionamento definitivo de HD1 serão feitos **pelo próprio instalador do Windows 11**, dentro da VM, no Capítulo 18, garantindo compatibilidade total de tabela de partição (GPT) e alinhamento com o padrão que o Windows espera.

> **⚠️ ALERTA:** Se HD1 já contiver dados de uma instalação anterior de Windows que se deseja preservar, **não** o formate em nenhuma etapa deste documento antes de confirmar que o backup está íntegro em outra mídia. O passthrough de disco físico preserva o conteúdo existente, mas qualquer erro de digitação em um comando de particionamento/formatação é irreversível.

### HD2 — preparado, mas não formatado

Conforme a especificação deste projeto, HD2 **já está formatado** (NTFS) e **não será formatado por este documento**. Ele será apenas identificado (UUID) e montado em `/mnt/docs4` no Capítulo 11. Nenhuma ação de particionamento é necessária aqui — apenas identificação.

### Diagrama consolidado

```text
NVMe (<NVME_DEVICE>)
 ├─ p1  512 MiB   FAT32   /boot/efi
 ├─ p2  restante  ext4    /            (contém /etc, /var, /vm)
 └─ p3  opcional  ext4    /home

HD1 (não particionado pelo Linux — será feito pelo instalador do Windows dentro da VM)

HD2 (já formatado em NTFS — apenas identificado e montado em /mnt/docs4, Capítulo 11)
```

## Comandos

Nesta etapa, o único comando necessário é de identificação, não de alteração — o particionamento efetivo do NVMe ocorre dentro do instalador gráfico do Pop!_OS, no Capítulo 6.

```bash
lsblk -o NAME,SIZE,TYPE,MODEL,SERIAL,TRAN
```

**O que este comando faz:** confirma, através da coluna `TRAN` (transporte: `nvme`, `sata`, `usb`), qual dispositivo é de fato o NVMe interno, evitando qualquer ambiguidade antes de iniciar o instalador.

> **🛑 PONTO DE NÃO RETORNO:** Confirme o nome exato de `<NVME_DEVICE>` (por exemplo `/dev/nvme0n1`) antes de avançar ao instalador do Capítulo 6. O particionamento manual, se optar por essa via em vez do assistente automático do instalador, é uma operação destrutiva sobre o disco selecionado.

## Arquivos modificados

Nenhum neste capítulo — apenas identificação.

## Como verificar

- A saída de `lsblk` deve mostrar exatamente um dispositivo com `TRAN = nvme`, correspondendo ao tamanho do SSD conhecido do inventário (Capítulo 3).
- HD1 e HD2 devem aparecer na listagem, mas **não** devem ser referenciados no instalador do Pop!_OS no próximo capítulo (idealmente, fisicamente desconectados, conforme alerta do Capítulo 4).

## Resultado esperado

Esquema de partição do NVMe definido e documentado, dispositivo NVMe identificado com certeza, e HD1/HD2 preservados intocados, prontos para a instalação do Pop!_OS restrita exclusivamente ao NVMe.

## Como desfazer

Não aplicável — nenhuma alteração foi feita neste capítulo.

## Problemas comuns

| Sintoma | Causa provável | Correção |
|---|---|---|
| Mais de um dispositivo com `TRAN = nvme` | Sistema com múltiplos SSDs NVMe (não é o caso do hardware de referência, mas pode ocorrer em variações) | Confirmar por tamanho e, se necessário, por `nvme id-ctrl` (pacote `nvme-cli`) qual corresponde ao SSD documentado no Capítulo 3 |
| HD1/HD2 aparecem na tela de particionamento do instalador | Discos ainda conectados fisicamente | Desligar a máquina e desconectar os cabos SATA/alimentação de HD1 e HD2 antes de religar para o instalador |

## Próxima etapa

Capítulo 6 — Instalação Limpa do Pop!_OS.

---

# Capítulo 6 — Instalação Limpa do Pop!_OS

## Objetivo

Instalar o Pop!_OS no SSD NVMe, com particionamento conforme planejado no Capítulo 5, criando o usuário `<USUARIO_LINUX>` e deixando o sistema pronto para as etapas de atualização e configuração de virtualização.

## Pré-requisitos

- Capítulo 5 concluído (NVMe identificado, HD1/HD2 preferencialmente desconectados).
- Mídia USB de instalação do Pop!_OS gravada previamente em outro computador (usando uma ferramenta como Etcher, Fedora Media Writer, ou `dd`), a partir da imagem ISO oficial baixada de `pop.system76.com`.
- BIOS já configurada com **UEFI puro** (sem CSM) — ver Capítulo 12, executado antes deste capítulo conforme o plano do Capítulo 4.

## Explicação

### Por que instalação limpa, e não upgrade

Uma instalação limpa garante um estado inicial conhecido e documentável, sem resíduos de configuração de instalações anteriores (drivers antigos, regras de udev obsoletas, módulos de kernel carregados incorretamente) que poderiam mascarar problemas reais de IOMMU/VFIO mais adiante, tornando o diagnóstico ambíguo.

### Modo de particionamento no instalador

O instalador gráfico do Pop!_OS oferece dois modos: **Clean Install** (automático, usa o disco inteiro) e **Custom (Advanced)**, que permite definir manualmente cada partição. Para seguir exatamente o esquema do Capítulo 5 (incluindo `/home` como partição separada), utilize o modo **Custom (Advanced)**.

Sequência dentro do instalador:

1. Selecionar idioma e layout de teclado.
2. Selecionar rede Wi-Fi (opcional nesta fase; pode ser configurada depois).
3. Na tela de tipo de instalação, escolher **Custom (Advanced)**.
4. Selecionar exclusivamente `<NVME_DEVICE>` como disco de destino (confirmando pelo tamanho, conforme identificado no Capítulo 5).
5. Criar as partições:
   - Nova partição EFI: 512 MiB, sistema de arquivos FAT32, ponto de montagem `/boot/efi`, flag `boot`/`esp` marcada.
   - Nova partição raiz: sistema de arquivos ext4, ponto de montagem `/`, tamanho = total menos a reserva de `/home`.
   - Nova partição home: sistema de arquivos ext4, ponto de montagem `/home`, restante do espaço.
6. Confirmar o mapeamento e prosseguir.
7. Definir nome de usuário `<USUARIO_LINUX>` (`charles`, conforme especificação), nome de máquina `<HOSTNAME>` e senha.
8. Concluir a instalação e reiniciar quando solicitado, removendo a mídia USB.

> **⚠️ ALERTA:** Ao chegar na tela de seleção de disco, confirme visualmente o tamanho e o nome do dispositivo antes de prosseguir. Se HD1 ou HD2 estiverem fisicamente conectados e aparecerem na lista, **não os selecione em hipótese alguma**.

> **💡 DICA:** Caso deseje habilitar criptografia de disco completo (LUKS), o instalador oferece essa opção antes da etapa de particionamento customizado. Ela é compatível com todo o restante deste documento; a única implicação prática é que o sistema solicitará uma senha de desbloqueio a cada boot, antes mesmo do carregador de boot listar o Windows/VM (o que, neste ambiente, não se aplica, pois não há dual boot — apenas o Pop!_OS inicializa diretamente).

## Comandos

A instalação em si é gráfica (assistente do instalador). Após o primeiro boot no sistema instalado, execute os comandos abaixo para confirmar o estado:

```bash
whoami
```
**O que faz:** confirma que a sessão atual pertence ao usuário `<USUARIO_LINUX>` recém-criado.

```bash
hostnamectl
```
**O que faz:** exibe o nome de máquina configurado (`<HOSTNAME>`), a versão do Pop!_OS e a versão do kernel em uso.

```bash
lsblk -f
```
**O que faz:** confirma que as partições foram criadas exatamente conforme planejado no Capítulo 5 (ESP em `/boot/efi`, raiz em `/`, home em `/home`), agora já com sistema de arquivos formatado e UUID atribuído pelo instalador.

## Arquivos modificados

- Tabela de partição do `<NVME_DEVICE>` (criada pelo instalador).
- `/etc/fstab` (gerado automaticamente pelo instalador com as entradas do NVMe).
- `/etc/passwd`, `/etc/shadow`, `/etc/group` (criação do usuário `<USUARIO_LINUX>`).
- `/etc/hostname`, `/etc/hosts` (definição de `<HOSTNAME>`).

## Como verificar

- `lsblk -f` mostra três partições no NVMe, com pontos de montagem `/boot/efi`, `/` e `/home`, cada uma com um UUID preenchido (nenhum campo vazio).
- `cat /etc/os-release` deve identificar `Pop!_OS` no campo `NAME`.
- O sistema inicializa diretamente em ambiente gráfico (GNOME, no caso do Pop!_OS) sem erros de boot.

## Resultado esperado

Um Pop!_OS recém-instalado, funcional, com o usuário `<USUARIO_LINUX>` criado, particionamento do NVMe conforme planejado, e HD1/HD2 ainda intocados (fisicamente desconectados ou simplesmente ignorados pelo instalador).

## Como desfazer

Reinstalação completa a partir da mesma mídia USB, repetindo este capítulo. Não existe um "desfazer" parcial de uma instalação de sistema operacional — em caso de erro grave de particionamento, o procedimento correto é reiniciar o processo de instalação do zero.

## Problemas comuns

| Sintoma | Causa provável | Correção |
|---|---|---|
| Instalador não lista o NVMe | Modo de armazenamento da BIOS em RAID/Intel RST equivalente, ou modo AHCI não selecionado | Verificar Advanced → Onboard Devices Configuration / SATA Configuration na BIOS (Capítulo 12) |
| Boot após instalação cai em prompt UEFI Shell ou não encontra sistema operacional | Secure Boot incompatível ou ESP não marcada corretamente | Revisar Capítulo 12 (Secure Boot) e refazer a etapa de partição EFI |
| Teclado com layout incorreto durante a instalação | Layout selecionado incorretamente na primeira tela | Reiniciar o instalador e selecionar o layout correto (ex.: "Portuguese (Brazil)") |

## Próxima etapa

Capítulo 7 — Atualização do Sistema.

---

# Capítulo 7 — Atualização do Sistema

## Objetivo

Levar o Pop!_OS recém-instalado a um estado totalmente atualizado (kernel, firmware de dispositivos e pacotes de sistema) antes de instalar drivers e a pilha de virtualização, reduzindo a chance de incompatibilidades por versões desatualizadas.

## Pré-requisitos

- Capítulo 6 concluído.
- Conexão à internet ativa (cabo ou Wi-Fi).

## Explicação

O Pop!_OS é baseado em Ubuntu LTS e utiliza o gerenciador de pacotes **APT**, com um sistema de atualização de firmware complementar chamado **fwupd**, e um mecanismo próprio de atualização em lote via **Pop!_Shop** ou linha de comando (`pop-upgrade`, quando disponível na versão instalada).

Atualizar o sistema **antes** de instalar KVM/QEMU/VFIO é importante por dois motivos:

1. O kernel Linux recebe correções frequentes relacionadas a IOMMU, reset de dispositivos PCI (função `FLR — Function Level Reset`) e suporte a hardware AMD, que impactam diretamente a estabilidade do passthrough.
2. Manter a base do sistema atualizada evita que a instalação subsequente de pacotes de virtualização traga versões conflitantes de bibliotecas.

## Comandos

```bash
sudo apt update
```
**O que faz:** contata os repositórios configurados em `/etc/apt/sources.list` e `/etc/apt/sources.list.d/`, baixando a lista mais recente de pacotes disponíveis e suas versões. Não instala nada — apenas atualiza os metadados locais.

```bash
sudo apt full-upgrade -y
```
**O que faz:** instala as versões mais novas de todos os pacotes já instalados, incluindo alterações de dependências (por exemplo, remoção de um pacote obsoleto em favor de outro que o substitui) — mais abrangente que `apt upgrade`, que se recusa a alterar dependências. É o comando recomendado pela documentação do Ubuntu/Pop!_OS para atualizações completas de sistema.

```bash
sudo apt autoremove -y
```
**O que faz:** remove pacotes que foram instalados como dependência de algo que não existe mais no sistema (por exemplo, um kernel antigo substituído pelo novo). Mantém o sistema limpo de versões de kernel obsoletas — embora seja prudente manter ao menos um kernel anterior como opção de recuperação (ver observação abaixo).

```bash
sudo apt install fwupd -y
sudo fwupdmgr refresh
sudo fwupdmgr get-updates
sudo fwupdmgr update
```
**O que fazem, em ordem:** instalam o utilitário de atualização de firmware `fwupd`; atualizam o catálogo de firmwares conhecidos (assinado pela LVFS — Linux Vendor Firmware Service); listam atualizações de firmware disponíveis para os componentes do sistema (por exemplo, firmware do próprio SSD NVMe); e aplicam as atualizações encontradas. Nem toda placa-mãe ou periférico possui firmware distribuído via LVFS — é normal a lista vir vazia em alguns componentes.

```bash
sudo reboot
```
**O que faz:** reinicia o sistema para que o novo kernel (se atualizado) e eventuais atualizações de firmware entrem em vigor.

> **💡 DICA:** Após o reboot, confirme a versão do kernel em uso com `uname -r` e compare com a versão instalada mostrada por `dpkg -l | grep linux-image`. Isso evita seguir os próximos capítulos "pensando" estar em um kernel diferente do que está realmente em execução.

## Arquivos modificados

- Pacotes do sistema em geral (via `dpkg`/`apt`), incluindo possivelmente o pacote `linux-image-*` (novo kernel).
- `/boot/` (nova entrada de kernel, se aplicável).
- Firmware de dispositivos, se atualizados via `fwupd` (gravado diretamente nos dispositivos, não em arquivos do sistema de arquivos).

## Como verificar

```bash
uname -r
apt list --upgradable
```

**Critério de sucesso:** `apt list --upgradable` não deve listar nenhum pacote pendente (saída vazia, ou apenas o cabeçalho informativo "Listing..."). `uname -r` deve corresponder à versão de kernel mais recente instalada, verificável com `dpkg -l | grep linux-image | tail -n 1`.

## Resultado esperado

Sistema Pop!_OS com todos os pacotes, kernel e firmware atualizados às versões mais recentes disponíveis nos repositórios e no LVFS, reiniciado e operando normalmente no novo kernel.

## Como desfazer

Não há "desfazer" de uma atualização de sistema no sentido estrito. Caso um novo kernel cause instabilidade:

```bash
# No menu do GRUB durante o boot, selecionar "Advanced options for Pop!_OS"
# e escolher a entrada do kernel anterior.
```

Para remover permanentemente um kernel problemático após confirmar qual é o de boa versão:

```bash
sudo apt remove --purge linux-image-<VERSAO_KERNEL_PROBLEMATICA>
sudo update-grub
```

## Problemas comuns

| Sintoma | Causa provável | Correção |
|---|---|---|
| `apt update` falha com erro de rede | Sem conectividade | Verificar `ip a`, reconectar Wi-Fi/cabo |
| `apt full-upgrade` interrompido no meio | Queda de energia/rede durante a atualização | Executar `sudo dpkg --configure -a` seguido de `sudo apt full-upgrade -y` novamente |
| Sistema não inicializa após reboot com o novo kernel | Regressão em driver específico do novo kernel (raro, mas possível) | Selecionar o kernel anterior no menu do GRUB (Advanced options) e reportar/aguardar correção antes de remover o kernel antigo |

## Próxima etapa

Capítulo 8 — Drivers NVIDIA no Host, para que o Linux tenha aceleração gráfica normal antes de qualquer configuração de VFIO.

---

# Capítulo 8 — Drivers NVIDIA no Host

## Objetivo

Instalar o driver proprietário NVIDIA no Pop!_OS para uso normal do desktop Linux, estabelecendo a configuração "padrão" da GPU que será dinamicamente substituída pelo `vfio-pci` apenas durante a execução da VM (Capítulo 19).

## Pré-requisitos

- Capítulo 7 concluído (sistema atualizado).
- GPU RTX 3060 identificada no inventário (Capítulo 3).

## Explicação

### Por que instalar o driver NVIDIA no host, mesmo sabendo que a GPU será cedida à VM

É uma dúvida comum e legítima: se a GPU vai ser repassada à VM, por que instalar o driver NVIDIA no Linux? A resposta decorre diretamente do modelo de single-GPU passthrough (Capítulo 1): a GPU **passa a maior parte do tempo** sob controle do Linux — é o driver `nvidia` que fornece a saída de vídeo, aceleração e todo o desktop gráfico do Pop!_OS no dia a dia. Somente durante o intervalo em que a VM Windows está ligada é que a GPU é temporariamente desvinculada do driver `nvidia` e vinculada ao `vfio-pci` pelos hook scripts (Capítulo 19). Sem o driver NVIDIA instalado, o Linux ficaria limitado ao driver genérico `nouveau` (de engenharia reversa, com desempenho e suporte a recursos bem inferiores) ou sem saída de vídeo alguma.

### Vantagens e desvantagens do driver proprietário NVIDIA

| Aspecto | Driver `nvidia` (proprietário) | Driver `nouveau` (livre) |
|---|---|---|
| Desempenho 3D | Alto, otimizado pela NVIDIA | Baixo/médio, engenharia reversa |
| Suporte a recursos recentes (Vulkan, CUDA, NVENC) | Completo | Parcial ou ausente |
| Facilidade de descarregar/recarregar dinamicamente (para VFIO) | Boa, com módulo `nvidia`, `nvidia_drm`, `nvidia_modeset`, `nvidia_uvm` gerenciáveis via `modprobe` | Também gerenciável, mas irrelevante aqui pois não é o driver de uso diário desejado |
| Licença | Proprietária | Código aberto |

Para este projeto, o driver proprietário é a escolha correta, pois o desktop Linux do dia a dia deve ter desempenho pleno, e os hook scripts do Capítulo 19 são desenhados especificamente em torno do ciclo de carga/descarga do módulo `nvidia`.

### Método de instalação no Pop!_OS

O Pop!_OS oferece uma variante de imagem ISO já com o driver NVIDIA pré-integrado ("Pop!_OS NVIDIA"). Caso a instalação do Capítulo 6 tenha usado essa variante, o driver **já está presente** e este capítulo serve como verificação. Caso a variante padrão (sem NVIDIA) tenha sido usada, o driver deve ser instalado manualmente via repositório oficial do Pop!_OS (`system76-driver` / pacotes `nvidia-driver-*`).

## Comandos

Verificar se o driver já está presente (caso da ISO com NVIDIA integrado):

```bash
nvidia-smi
```
**O que faz:** utilitário de linha de comando fornecido pelo driver NVIDIA que lista a GPU detectada, versão do driver, uso de memória de vídeo e processos em execução na GPU. Se o comando retornar "command not found", o driver não está instalado.

Caso não esteja instalado, listar drivers disponíveis nos repositórios do Pop!_OS:

```bash
sudo apt update
apt list --all-versions | grep -i nvidia-driver
```
**O que faz:** lista os pacotes de driver NVIDIA disponíveis nos repositórios configurados, permitindo escolher a versão mais recente estável.

Instalar o driver:

```bash
sudo apt install system76-driver-nvidia nvidia-driver -y
```
**O que faz:** instala o meta-pacote de driver NVIDIA do Pop!_OS (`system76-driver-nvidia`, que aplica ajustes específicos da distribuição, como o alternador de driver `system76-power` quando aplicável) junto com o pacote de driver `nvidia-driver`, que traz os módulos de kernel (`nvidia`, `nvidia-drm`, `nvidia-modeset`, `nvidia-uvm`) e as bibliotecas userspace (OpenGL, Vulkan, CUDA runtime básico).

```bash
sudo reboot
```
**O que faz:** necessário porque os módulos de kernel do driver precisam ser carregados a partir de um boot limpo, substituindo o driver genérico `nouveau` usado durante a instalação inicial.

## Arquivos modificados

- Pacotes `nvidia-driver`, `system76-driver-nvidia` e dependências (instalados via `dpkg`).
- `/etc/modprobe.d/` pode receber entradas de blacklist do `nouveau`, geradas automaticamente pelo instalador do driver.
- `/etc/X11/xorg.conf.d/` (se aplicável, configuração de X11 gerada automaticamente).
- `/lib/modules/<VERSAO_KERNEL>/updates/dkms/` (módulos compilados via DKMS, se o driver usar esse mecanismo).

## Como verificar

```bash
nvidia-smi
```

**Critério de sucesso:** a saída deve exibir uma tabela com o nome da GPU ("NVIDIA GeForce RTX 3060"), a versão do driver instalado, a versão de CUDA suportada e o consumo de memória de vídeo atual (baixo, em uso normal de desktop).

```bash
lspci -nnk | grep -A3 -i vga
```

**Critério de sucesso:** a linha `Kernel driver in use:` associada à GPU deve mostrar `nvidia` (não `nouveau`).

## Resultado esperado

Desktop Pop!_OS com aceleração gráfica plena via driver proprietário NVIDIA, `nvidia-smi` funcional, e a GPU claramente vinculada ao driver `nvidia` — este é o estado "de repouso" da GPU, para onde ela sempre retorna quando a VM Windows está desligada.

## Como desfazer

```bash
sudo apt purge nvidia-driver* system76-driver-nvidia -y
sudo apt autoremove -y
sudo reboot
```

**O que faz:** remove completamente os pacotes do driver proprietário e reinicia; o sistema volta a usar o driver `nouveau` genérico.

## Problemas comuns

| Sintoma | Causa provável | Correção |
|---|---|---|
| Tela preta após reboot com o driver instalado | Conflito entre `nouveau` (ainda carregado) e `nvidia` | Verificar `/etc/modprobe.d/blacklist-nouveau.conf`, regenerar initramfs com `sudo update-initramfs -u`, reiniciar |
| `nvidia-smi` retorna "No devices were found" | Módulo não carregado corretamente, ou GPU já vinculada a outro driver (verificar se algum passo do Capítulo 16 foi executado prematuramente) | `lsmod \| grep nvidia`; se vazio, `sudo modprobe nvidia`; revisar ordem dos capítulos |
| Versão do driver muito antiga para a RTX 3060 | Repositório desatualizado ou seleção de pacote incorreta | Confirmar com `apt list --all-versions \| grep nvidia-driver` e escolher explicitamente uma versão recente com `sudo apt install nvidia-driver-<versao>` |

## Próxima etapa

Capítulo 9 — Instalação dos Pacotes Base, cobrindo utilitários de sistema necessários para as etapas seguintes de disco e virtualização.

---

# Capítulo 9 — Instalação dos Pacotes Base

## Objetivo

Instalar o conjunto de utilitários de sistema (fora da pilha de virtualização propriamente dita, tratada no Capítulo 13) necessários para gerenciamento de disco, diagnóstico de hardware e suporte a NTFS.

## Pré-requisitos

- Capítulo 8 concluído.

## Explicação

Estes pacotes são pré-requisitos técnicos para os capítulos de organização de disco (10 e 11) e de diagnóstico de hardware/IOMMU (16), e são independentes da pilha de virtualização KVM/QEMU, instalada separadamente no Capítulo 13 para manter a separação de responsabilidades clara neste documento.

| Pacote | Finalidade |
|---|---|
| `ntfs-3g` | Driver FUSE de leitura/escrita em sistemas de arquivos NTFS, necessário para montar HD2 no Linux (Capítulo 11) |
| `pciutils` | Fornece o comando `lspci`, essencial para identificação de dispositivos PCI (Capítulos 3 e 16) |
| `usbutils` | Fornece o comando `lsusb`, usado no Capítulo 20 para passthrough de dispositivos USB |
| `dmidecode` | Leitura de tabelas SMBIOS/DMI (usado no Capítulo 3) |
| `curl`, `wget` | Utilitários de download, usados para obter ISOs e drivers (Capítulos 17 e 18) |
| `git` | Controle de versão, útil para clonar repositórios de scripts de hook (Capítulo 19), caso o administrador opte por versionar sua configuração |
| `htop` | Monitor interativo de processos e uso de CPU/RAM, útil para diagnosticar CPU pinning (Capítulo 21) |

## Comandos

```bash
sudo apt update
sudo apt install -y ntfs-3g pciutils usbutils dmidecode curl wget git htop
```

**O que faz:** instala, em um único comando, todos os utilitários listados acima a partir dos repositórios padrão do Pop!_OS/Ubuntu.

## Arquivos modificados

- Pacotes instalados via `dpkg`/`apt` (nenhum arquivo de configuração de usuário é alterado neste capítulo).

## Como verificar

```bash
ntfs-3g --version
lspci --version
lsusb --version
dmidecode --version
```

**Critério de sucesso:** cada comando retorna um número de versão, sem erro de "command not found".

## Resultado esperado

Todos os utilitários de diagnóstico e suporte a NTFS disponíveis no sistema, prontos para uso nos Capítulos 10 a 16.

## Como desfazer

```bash
sudo apt remove --purge ntfs-3g pciutils usbutils dmidecode curl wget git htop -y
```

> **⚠️ ALERTA:** Remover `pciutils` e `usbutils` compromete a capacidade de diagnóstico dos capítulos seguintes. Recomenda-se não desfazer este capítulo, exceto por razões de auditoria de pacotes.

## Problemas comuns

| Sintoma | Causa provável | Correção |
|---|---|---|
| `E: Unable to locate package` | Índice de pacotes desatualizado | `sudo apt update` antes de instalar |
| Conflito de dependências | Pacotes de terceiros instalados manualmente em conflito | Resolver com `sudo apt --fix-broken install` |

## Próxima etapa

Capítulo 10 — Estrutura de Diretórios.

---

# Capítulo 10 — Estrutura de Diretórios

## Objetivo

Criar a estrutura de diretórios que hospedará o arquivo de disco virtual da VM (`/vm`) e preparar o terreno para o ponto de montagem do HD2 (`/mnt/docs4`, detalhado no Capítulo 11), com permissões corretas.

## Pré-requisitos

- Capítulo 9 concluído.

## Explicação

### O diretório `/vm`

Segue a convenção do Filesystem Hierarchy Standard (FHS) de criar diretórios de propósito específico diretamente na raiz quando não há uma categoria padrão adequada (o FHS não define um diretório padrão para imagens de VM). Alternativas comuns incluem `/var/lib/libvirt/images` (padrão do próprio libvirt) — mas a especificação deste projeto define explicitamente `/vm/Windows11.qcow2` como localização, e este documento a respeita integralmente, ajustando a configuração do libvirt (Capítulo 17) e do AppArmor (ver observação abaixo) para reconhecer esse caminho não padrão.

> **📝 NOTA:** Por padrão, o Pop!_OS/Ubuntu utiliza o **AppArmor** para confinar o processo `qemu-system-x86_64` gerenciado pelo libvirt, restringindo quais caminhos de arquivo ele pode abrir. Como `/vm` não é um diretório padrão reconhecido pelos perfis do AppArmor para libvirt, será necessário um ajuste específico, detalhado no Capítulo 17, no momento em que o disco da VM é efetivamente referenciado.

### Por que criar `/vm` com o usuário `libvirt-qemu` em mente

O processo QEMU, quando gerenciado pelo `libvirtd` no modo padrão do sistema (system mode, não session mode), roda tipicamente sob o usuário de sistema `libvirt-qemu` (a depender da distribuição — no Pop!_OS/Ubuntu esse é o nome padrão). Esse usuário precisa de permissão de leitura e escrita no arquivo `Windows11.qcow2`. Este capítulo cria o diretório com permissões que serão refinadas no Capítulo 14, após a instalação da pilha de virtualização (quando o usuário `libvirt-qemu` já existe no sistema).

## Comandos

```bash
sudo mkdir -p /vm
```
**O que faz:** cria o diretório `/vm` na raiz do sistema de arquivos, com a flag `-p` evitando erro caso o diretório já exista (idempotente).

```bash
sudo mkdir -p /mnt/docs4
```
**O que faz:** cria o ponto de montagem para o HD2, ainda vazio nesta etapa — o mount efetivo ocorre no Capítulo 11. Criar o diretório antecipadamente aqui mantém a criação de estrutura de diretórios centralizada neste capítulo.

```bash
sudo chown root:root /vm
sudo chmod 755 /vm
```
**O que fazem:** definem o dono como `root` e permissão `755` (leitura/execução para todos, escrita apenas para o dono) como estado inicial seguro. A permissão específica para o usuário `libvirt-qemu` escrever o arquivo `.qcow2` dentro de `/vm` será tratada em detalhe no Capítulo 14, após esse usuário existir no sistema (criado pela instalação do pacote `libvirt-daemon-system`).

```bash
ls -ld /vm /mnt/docs4
```
**O que faz:** confirma visualmente dono, grupo e permissões dos diretórios recém-criados.

## Arquivos modificados

- `/vm` (diretório criado).
- `/mnt/docs4` (diretório criado, vazio até o Capítulo 11).

## Como verificar

```bash
stat /vm
stat /mnt/docs4
```

**Critério de sucesso:** ambos os comandos retornam informações de inode sem erro "No such file or directory", confirmando dono `root:root` e permissões `drwxr-xr-x`.

## Resultado esperado

Estrutura de diretórios `/vm` e `/mnt/docs4` criada na raiz do sistema de arquivos, prontos para receber, respectivamente, o disco virtual da VM (Capítulo 17) e a montagem do HD2 (Capítulo 11).

## Como desfazer

```bash
sudo rmdir /vm /mnt/docs4
```

> **⚠️ ALERTA:** `rmdir` só funciona em diretórios vazios. Se `/vm` já contiver `Windows11.qcow2` ou `/mnt/docs4` já estiver montado, este comando falhará propositalmente — comportamento correto, para evitar remoção acidental de dados. Desmonte (`sudo umount /mnt/docs4`) e/ou remova o arquivo de disco antes de remover os diretórios.

## Problemas comuns

| Sintoma | Causa provável | Correção |
|---|---|---|
| `mkdir: cannot create directory '/vm': Permission denied` | Comando executado sem `sudo` | Reexecutar com `sudo` |
| `rmdir: failed to remove '/mnt/docs4': Device or resource busy` | HD2 ainda montado | `sudo umount /mnt/docs4` antes de remover o diretório |

## Próxima etapa

Capítulo 11 — Configuração Completa do Docs4, onde o HD2 é identificado, montado permanentemente e integrado aos diretórios pessoais do usuário via bind mount.

---

# Capítulo 11 — Configuração Completa do Docs4

## Objetivo

Identificar o HD2 de forma estável (UUID), montá-lo permanentemente em `/mnt/docs4` via `ntfs-3g` com as opções corretas, e integrar os diretórios pessoais do usuário (`Documentos`, `Downloads`, `Imagens`, `Músicas`, `Vídeos`) a esse disco através de bind mounts, migrando dados existentes com segurança.

## Pré-requisitos

- Capítulo 10 concluído (`/mnt/docs4` criado).
- Capítulo 9 concluído (`ntfs-3g` instalado).
- HD2 fisicamente reconectado (se havia sido desconectado durante a instalação do Pop!_OS, conforme recomendado no Capítulo 6).
- HD2 já formatado em NTFS (conforme especificação — este capítulo **não formata** o HD2).

## Explicação

### Visão geral do capítulo

Este é um dos capítulos centrais do documento, e por isso é dividido em subseções que devem ser seguidas em ordem: identificação por UUID, montagem via `ntfs-3g`, entrada em `/etc/fstab`, a opção `windows_names`, os bind mounts, a migração de dados existentes e a verificação final.

```text
┌─────────────────────────────────────────────────────────────────┐
│ HD2 (NTFS)                                                        │
│   UUID: <UUID_HD2>                                                │
│   Montado em: /mnt/docs4  (via ntfs-3g, opções: windows_names,…)  │
│                                                                     │
│   /mnt/docs4/Documentos ◄──bind mount──► /home/charles/Documentos │
│   /mnt/docs4/Downloads  ◄──bind mount──► /home/charles/Downloads  │
│   /mnt/docs4/Imagens    ◄──bind mount──► /home/charles/Imagens    │
│   /mnt/docs4/Musicas    ◄──bind mount──► /home/charles/Músicas    │
│   /mnt/docs4/Videos     ◄──bind mount──► /home/charles/Vídeos     │
└─────────────────────────────────────────────────────────────────┘
```

### Subseção: UUID

Todo sistema de arquivos possui um identificador único (UUID) gravado em sua própria estrutura (superbloco), independente do nome de dispositivo (`/dev/sdb1`) que, como já discutido no Capítulo 5, pode variar entre boots. Por isso, `/etc/fstab` deve referenciar discos por UUID, nunca por `/dev/sdX`.

```bash
sudo blkid
```

**O que faz:** varre todos os dispositivos de bloco reconhecidos e imprime, para cada um, seu UUID, tipo de sistema de arquivos (`TYPE`) e rótulo (`LABEL`), se houver. Localize na saída a linha correspondente ao HD2 — identificável por `TYPE="ntfs"` e pelo tamanho/nome de dispositivo já conhecido do inventário (Capítulo 3). O valor da coluna `UUID=` **é** o que este documento chama de `<UUID_HD2>`.

Exemplo de formato de saída (valores meramente ilustrativos do *formato*, não valores reais a copiar):

```text
/dev/sdX1: UUID="XXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX" TYPE="ntfs" ...
```

> **⚠️ ALERTA:** Não copie o exemplo acima. Ele existe apenas para mostrar o formato esperado da linha. Use exclusivamente o UUID retornado pelo `blkid` executado no seu próprio sistema.

### Subseção: ntfs-3g

`ntfs-3g` é a implementação de espaço de usuário (FUSE) mais madura para leitura e escrita em sistemas de arquivos NTFS a partir do Linux. Diferente do suporte NTFS nativo introduzido em kernels Linux recentes (driver `ntfs3`, no kernel desde a série 5.15), o `ntfs-3g` tem décadas de maturidade, amplo suporte a permissões estilo POSIX mapeadas sobre NTFS, e é o padrão mais testado em cenários de uso misto Linux/Windows como este.

> **📝 NOTA:** O Pop!_OS moderno também suporta o driver de kernel nativo `ntfs3` para montagens simples. Este documento usa `ntfs-3g` deliberadamente pela opção `windows_names`, tratada a seguir, que é específica dessa implementação e adiciona uma camada de segurança relevante para este ambiente.

### Subseção: windows_names

A opção de montagem `windows_names` instrui o `ntfs-3g` a **rejeitar** a criação, pelo lado Linux, de nomes de arquivo que sejam inválidos no Windows (caracteres como `:`, `*`, `?`, `"`, `<`, `>`, `|`, espaços/pontos finais no nome, e nomes reservados como `CON`, `PRN`, `AUX`, `NUL`). Sem essa opção, é possível — a partir do Linux — criar em uma partição NTFS um arquivo com um nome tecnicamente válido para o NTFS mas que o Windows se recusa a abrir, renomear ou até mesmo listar corretamente, gerando inconsistências difíceis de diagnosticar mais tarde.

Como o HD2 é usado para armazenar os diretórios pessoais do usuário Linux, mas seu sistema de arquivos é NTFS (compartilhando o mesmo formato usado pelo HD1/Windows, ainda que HD2 nunca seja acessado pela VM), a opção `windows_names` é uma proteção de baixo custo contra a criação inadvertida de nomes de arquivo problemáticos.

### Subseção: fstab

O arquivo `/etc/fstab` ("file systems table") é lido pelo `systemd` durante o boot (através de uma geração automática de unidades `.mount`) e define quais sistemas de arquivos são montados automaticamente, onde, e com quais opções — eliminando a necessidade de montar manualmente o HD2 a cada boot.

Edite o arquivo com um editor de texto com privilégios de administrador:

```bash
sudo cp /etc/fstab /etc/fstab.bak-$(date +%Y%m%d)
sudo nano /etc/fstab
```

**O que fazem:** o primeiro comando cria uma cópia de segurança do `fstab` atual, com data no nome — prática indispensável antes de editar este arquivo, pois um `fstab` malformado pode impedir o boot normal do sistema (embora o systemd moderno geralmente apenas ignore a linha inválida e continue o boot, exibindo um aviso). O segundo abre o editor `nano` para edição.

Adicione a seguinte linha ao final do arquivo, substituindo o placeholder pelo UUID real obtido com `blkid`:

```fstab
UUID=<UUID_HD2>  /mnt/docs4  ntfs-3g  defaults,windows_names,uid=1000,gid=1000,umask=022,nofail  0  0
```

**Explicação campo a campo:**

| Campo | Valor | Significado |
|---|---|---|
| 1 | `UUID=<UUID_HD2>` | Identifica o sistema de arquivos de forma estável, independente do nome de dispositivo |
| 2 | `/mnt/docs4` | Ponto de montagem (criado no Capítulo 10) |
| 3 | `ntfs-3g` | Tipo de sistema de arquivos / driver a usar |
| 4a | `defaults` | Conjunto padrão de opções (`rw,suid,dev,exec,auto,nouser,async`) |
| 4b | `windows_names` | Rejeita nomes de arquivo inválidos no Windows, conforme explicado acima |
| 4c | `uid=1000,gid=1000` | Força o dono/grupo aparente de todos os arquivos para o UID/GID 1000, tipicamente o primeiro usuário criado (`<USUARIO_LINUX>`) — necessário porque NTFS não possui um modelo de permissões POSIX nativo; confirme o UID real com `id <USUARIO_LINUX>` antes de aplicar, caso o usuário não seja o primeiro criado no sistema |
| 4d | `umask=022` | Máscara de permissão aplicada a todos os arquivos montados (equivalente a arquivos `644`/diretórios `755`) |
| 4e | `nofail` | Impede que uma falha ao montar este disco (ex.: cabo desconectado) impeça o boot do restante do sistema |
| 5 | `0` | Campo `dump` — não utilizado por ferramentas modernas de backup, mantido em `0` por convenção |
| 6 | `0` | Campo `fsck` — deve ser `0` para sistemas de arquivos não-nativos do Linux (NTFS não é verificado por `fsck` do Linux) |

> **💡 DICA:** Execute `id <USUARIO_LINUX>` antes de editar o `fstab` para confirmar o UID/GID reais do usuário, em vez de assumir `1000`. Em instalações onde `<USUARIO_LINUX>` não foi o primeiro usuário criado, o UID pode ser diferente.

Salve o arquivo (`Ctrl+O`, `Enter`, `Ctrl+X` no `nano`).

### Subseção: montagem e teste antes do reboot

Antes de reiniciar o sistema (o que tornaria qualquer erro no `fstab` mais difícil de corrigir sem um live-CD), teste a montagem imediatamente:

```bash
sudo mount -a
```

**O que faz:** lê `/etc/fstab` e monta todas as entradas ainda não montadas — incluindo a linha recém-adicionada para o HD2. Se houver erro de sintaxe ou UUID incorreto, o erro aparece imediatamente no terminal, permitindo correção antes do reboot.

```bash
mount | grep docs4
df -h /mnt/docs4
```

**O que fazem:** confirmam que `/mnt/docs4` está de fato montado, com o tipo de sistema de arquivos `fuseblk` (como o `ntfs-3g` se apresenta ao kernel) e o espaço total/usado correspondente ao tamanho real do HD2.

### Subseção: bind mounts

Um *bind mount* é um recurso do kernel Linux que monta um diretório já existente em **outro** ponto da árvore de arquivos, fazendo os dois caminhos apontarem para o mesmo conteúdo subjacente — sem duplicar dados. Diferente de um link simbólico, um bind mount é transparente para praticamente todos os programas, incluindo aqueles que resolvem caminhos absolutos internamente ou verificam se um caminho está no mesmo sistema de arquivos.

Aqui, os bind mounts fazem os diretórios padrão do XDG (`~/Documentos`, `~/Downloads`, `~/Imagens`, `~/Músicas`, `~/Vídeos`) apontarem fisicamente para subdiretórios dentro de `/mnt/docs4` (no HD2), mesmo que `/home` esteja fisicamente no NVMe (Capítulo 5). O usuário e as aplicações continuam enxergando os caminhos padrão dentro de `/home/<USUARIO_LINUX>/`, mas os dados residem no HD2.

Primeiro, crie os diretórios de destino dentro do HD2 (se ainda não existirem):

```bash
sudo mkdir -p /mnt/docs4/Documentos /mnt/docs4/Downloads /mnt/docs4/Imagens /mnt/docs4/Musicas /mnt/docs4/Videos
sudo chown <USUARIO_LINUX>:<USUARIO_LINUX> /mnt/docs4/Documentos /mnt/docs4/Downloads /mnt/docs4/Imagens /mnt/docs4/Musicas /mnt/docs4/Videos
```

> **📝 NOTA:** Os nomes de diretório acima foram grafados sem acentos (`Musicas`, `Videos`) propositalmente, por prudência com a interoperabilidade de nomes de arquivo acentuados em NTFS via FUSE em diferentes locales. Os pontos de bind mount do lado Linux (em `/home/<USUARIO_LINUX>/`) preservam a grafia padrão do XDG em português (`Músicas`, `Vídeos`), como detalhado abaixo — a tradução de nomes ocorre apenas na camada de bind mount, e é totalmente transparente ao usuário.

> **📝 NOTA:** Em NTFS montado via `ntfs-3g` com `uid=`/`gid=`/`umask=` (a linha de fstab acima), dono, grupo e permissões de **todos** os arquivos do volume são sintetizados a partir das opções de montagem — comandos `chown`/`chmod` sobre esse conteúdo **não têm efeito persistente** (são ignorados silenciosamente ou retornam erro, conforme a versão do driver). O `chown` acima é mantido apenas por robustez, para o caso de o volume ser migrado no futuro para um sistema de arquivos POSIX. Essa mesma limitação é o motivo do desenho específico do compartilhamento seguro no Capítulo 24, que não depende de permissões por pasta dentro do HD2.

Adicione as entradas de bind mount ao `/etc/fstab` (mesmo arquivo já aberto anteriormente):

```bash
sudo nano /etc/fstab
```

```fstab
/mnt/docs4/Documentos  /home/<USUARIO_LINUX>/Documentos  none  bind,nofail  0  0
/mnt/docs4/Downloads   /home/<USUARIO_LINUX>/Downloads   none  bind,nofail  0  0
/mnt/docs4/Imagens     /home/<USUARIO_LINUX>/Imagens     none  bind,nofail  0  0
/mnt/docs4/Musicas     /home/<USUARIO_LINUX>/Músicas     none  bind,nofail  0  0
/mnt/docs4/Videos      /home/<USUARIO_LINUX>/Vídeos      none  bind,nofail  0  0
```

**Explicação:** o tipo de sistema de arquivos `none` combinado com a opção `bind` instrui o `mount` a ignorar o conceito de "tipo de sistema de arquivos" e simplesmente vincular o segundo caminho ao primeiro. A opção `nofail` mantém a mesma proteção de boot já explicada para a montagem principal do HD2 — e é especialmente importante aqui, pois as entradas de bind mount **dependem** de `/mnt/docs4` já estar montado; se o HD2 falhar ao montar, essas linhas também falhariam, e `nofail` impede que isso trave o boot.

> **⚠️ ALERTA:** A ordem das linhas no `/etc/fstab` importa para bind mounts: a linha de montagem do HD2 em `/mnt/docs4` deve aparecer **antes** das linhas de bind mount que dependem dela. O `systemd`, na prática, resolve a maior parte das dependências de montagem automaticamente através da geração de unidades `.mount` com dependências implícitas de caminho, mas manter a ordem lógica no arquivo facilita a leitura humana e a depuração.

### Subseção: migração das pastas

Se o usuário `<USUARIO_LINUX>` já possui arquivos dentro de `~/Documentos`, `~/Downloads`, etc. (criados durante o uso inicial do sistema, antes deste capítulo), esses arquivos precisam ser **movidos** para dentro do HD2 antes de os bind mounts serem ativados — caso contrário, o bind mount simplesmente "cobre" o conteúdo antigo (que continua existindo no NVMe, porém inacessível enquanto o bind mount estiver ativo).

```bash
sudo umount /home/<USUARIO_LINUX>/Documentos 2>/dev/null || true
```
**O que faz:** garante que, se por algum motivo o bind mount já tiver sido ativado manualmente antes da migração, ele seja desfeito primeiro — a expressão `2>/dev/null || true` evita que o comando pare o script com erro caso o diretório já não esteja montado (comportamento esperado na primeira execução).

```bash
rsync -avh --progress /home/<USUARIO_LINUX>/Documentos/ /mnt/docs4/Documentos/
rsync -avh --progress /home/<USUARIO_LINUX>/Downloads/  /mnt/docs4/Downloads/
rsync -avh --progress /home/<USUARIO_LINUX>/Imagens/    /mnt/docs4/Imagens/
rsync -avh --progress "/home/<USUARIO_LINUX>/Músicas/"  /mnt/docs4/Musicas/
rsync -avh --progress "/home/<USUARIO_LINUX>/Vídeos/"   /mnt/docs4/Videos/
```

**O que fazem:** `rsync` copia recursivamente (`-a`, modo arquivo, preservando timestamps e permissões o quanto o NTFS permitir), com saída legível (`-h`) e barra de progresso (`--progress`), o conteúdo de cada diretório de origem (barra final `/` importante — copia o *conteúdo*, não o diretório em si) para o destino correspondente dentro do HD2. Usar `rsync` em vez de `mv` permite retomar a cópia em caso de interrupção e verificar integridade antes de apagar os originais.

> **💡 DICA:** Só apague os diretórios originais do NVMe **depois** de confirmar, com `diff -rq` ou comparação manual de tamanhos (`du -sh`), que a cópia foi bem-sucedida e completa.

Após confirmar a integridade da cópia:

```bash
rm -rf /home/<USUARIO_LINUX>/Documentos/* /home/<USUARIO_LINUX>/Downloads/* /home/<USUARIO_LINUX>/Imagens/* "/home/<USUARIO_LINUX>/Músicas/"* "/home/<USUARIO_LINUX>/Vídeos/"*
```

**O que faz:** esvazia o conteúdo original dentro do NVMe (mas mantém os diretórios em si, que servirão como pontos de montagem para o bind mount). O uso de `/*` em vez de remover o diretório inteiro preserva o diretório vazio necessário como ponto de montagem.

> **⚠️ ALERTA:** Este comando é destrutivo e não passa por lixeira. Execute-o **somente** após validar a integridade da cópia feita pelo `rsync`. Recomenda-se rodar `rsync` uma segunda vez antes de apagar, sem `--delete`, para confirmar que nenhum arquivo adicional aparece como pendente de cópia (saída sem novas transferências indica que a cópia já está completa).

### Subseção: ativação final e verificação

```bash
sudo mount -a
```

**O que faz:** agora que os diretórios de origem foram esvaziados e as entradas de bind mount estão no `fstab`, este comando ativa todos os bind mounts pendentes.

## Comandos

Resumo sequencial de todos os comandos deste capítulo (para referência rápida; a explicação detalhada de cada um está nas subseções acima):

```bash
sudo blkid
sudo cp /etc/fstab /etc/fstab.bak-$(date +%Y%m%d)
sudo nano /etc/fstab   # adicionar linha do HD2 + linhas de bind mount
sudo mount -a
mount | grep docs4
sudo mkdir -p /mnt/docs4/Documentos /mnt/docs4/Downloads /mnt/docs4/Imagens /mnt/docs4/Musicas /mnt/docs4/Videos
sudo chown <USUARIO_LINUX>:<USUARIO_LINUX> /mnt/docs4/Documentos /mnt/docs4/Downloads /mnt/docs4/Imagens /mnt/docs4/Musicas /mnt/docs4/Videos
rsync -avh --progress /home/<USUARIO_LINUX>/Documentos/ /mnt/docs4/Documentos/
rsync -avh --progress /home/<USUARIO_LINUX>/Downloads/  /mnt/docs4/Downloads/
rsync -avh --progress /home/<USUARIO_LINUX>/Imagens/    /mnt/docs4/Imagens/
rsync -avh --progress "/home/<USUARIO_LINUX>/Músicas/"  /mnt/docs4/Musicas/
rsync -avh --progress "/home/<USUARIO_LINUX>/Vídeos/"   /mnt/docs4/Videos/
rm -rf /home/<USUARIO_LINUX>/Documentos/* /home/<USUARIO_LINUX>/Downloads/* /home/<USUARIO_LINUX>/Imagens/* "/home/<USUARIO_LINUX>/Músicas/"* "/home/<USUARIO_LINUX>/Vídeos/"*
sudo mount -a
```

## Arquivos modificados

- `/etc/fstab` (adicionadas 6 linhas: 1 de montagem do HD2, 5 de bind mount).
- `/etc/fstab.bak-<data>` (backup criado).
- `/mnt/docs4/Documentos`, `/Downloads`, `/Imagens`, `/Musicas`, `/Videos` (diretórios criados no HD2).
- Conteúdo movido de `/home/<USUARIO_LINUX>/{Documentos,Downloads,Imagens,Músicas,Vídeos}` para os diretórios correspondentes no HD2.

## Como verificar

```bash
mount | grep -E "docs4|Documentos|Downloads|Imagens|Músicas|Vídeos"
```

**Critério de sucesso:** seis linhas de saída — uma para `/mnt/docs4` (tipo `fuseblk`) e cinco para os bind mounts (mostrando a origem dentro de `/mnt/docs4/...` e o destino em `/home/<USUARIO_LINUX>/...`).

```bash
touch /home/<USUARIO_LINUX>/Documentos/teste-bind-mount.txt
ls -la /mnt/docs4/Documentos/teste-bind-mount.txt
rm /home/<USUARIO_LINUX>/Documentos/teste-bind-mount.txt
```

**Critério de sucesso:** o arquivo criado através do caminho `~/Documentos` aparece imediatamente no caminho físico `/mnt/docs4/Documentos`, confirmando que ambos os caminhos referenciam o mesmo armazenamento.

Teste da proteção `windows_names`:

```bash
touch "/mnt/docs4/Documentos/nome:invalido?.txt"
```

**Critério de sucesso:** o comando deve **falhar** com uma mensagem de erro do tipo "Invalid argument" — confirmando que a proteção contra nomes inválidos no Windows está ativa.

## Resultado esperado

HD2 montado permanentemente e automaticamente a cada boot em `/mnt/docs4`, com proteção `windows_names` ativa; diretórios pessoais do usuário (`Documentos`, `Downloads`, `Imagens`, `Músicas`, `Vídeos`) fisicamente residentes no HD2 através de bind mounts transparentes, com todo o conteúdo pré-existente migrado com integridade verificada.

## Como desfazer

```bash
sudo umount /home/<USUARIO_LINUX>/Documentos /home/<USUARIO_LINUX>/Downloads /home/<USUARIO_LINUX>/Imagens "/home/<USUARIO_LINUX>/Músicas" "/home/<USUARIO_LINUX>/Vídeos"
sudo umount /mnt/docs4
sudo cp /etc/fstab.bak-<data> /etc/fstab
sudo mount -a
```

**O que faz:** desfaz os bind mounts e a montagem do HD2 (na ordem inversa de dependência — bind mounts primeiro, disco base depois), restaura o `fstab` original a partir do backup, e remonta apenas o que o `fstab` original definia. Os dados permanecem fisicamente no HD2 (`/mnt/docs4/Documentos` etc.), acessíveis diretamente por esse caminho mesmo sem o bind mount ativo.

## Problemas comuns

| Sintoma | Causa provável | Correção |
|---|---|---|
| `mount -a` falha com "wrong fs type, bad option" | Pacote `ntfs-3g` não instalado (Capítulo 9 pulado) | `sudo apt install ntfs-3g` |
| Bind mount falha, "mount point does not exist" | Diretório de destino (`~/Documentos`) não existe | `mkdir -p /home/<USUARIO_LINUX>/Documentos` antes de montar |
| Arquivos aparecem com dono `root` em vez de `<USUARIO_LINUX>` | Opções `uid=`/`gid=` ausentes ou incorretas na linha de montagem do HD2 | Revisar a linha do `fstab`, confirmar UID/GID com `id <USUARIO_LINUX>` |
| Após reboot, `/mnt/docs4` não monta e o boot exibe aviso, mas continua | Opção `nofail` funcionando como esperado, mas o disco realmente não foi detectado (cabo solto, disco desconectado) | Verificar conexão física do HD2, `sudo mount -a` manualmente para ver o erro real |
| Bind mounts não voltam após reboot, embora `/mnt/docs4` esteja montado | Ordem de geração de unidades systemd, condição de corrida rara | Adicionar explicitamente `x-systemd.requires=/mnt/docs4` nas linhas de bind mount, como opção adicional |

## Próxima etapa

Capítulo 12 — Configuração da BIOS/UEFI, habilitando SVM, IOMMU e demais opções de firmware necessárias antes de instalar a pilha de virtualização.

---

# Capítulo 12 — Configuração da BIOS/UEFI (ASUS TUF Gaming B550-Plus WiFi II)

## Objetivo

Habilitar, no firmware UEFI da placa-mãe ASUS TUF Gaming B550-Plus WiFi II, todas as opções indispensáveis para virtualização com GPU passthrough: SVM, IOMMU, modo UEFI puro (sem CSM), e revisar Above 4G Decoding, Resizable BAR e Secure Boot.

## Pré-requisitos

- Acesso físico ao computador, teclado conectado diretamente (sem passar por hub USB problemático) para navegação na BIOS.
- Capítulo 3 concluído (confirmação de que a placa-mãe é de fato a ASUS TUF Gaming B550-Plus WiFi II, e a versão de firmware atual).

## Explicação

### Acessando a BIOS/UEFI

Ligue ou reinicie o computador e pressione repetidamente a tecla **Del** (Delete) durante o logotipo inicial da ASUS — esta é a tecla padrão de acesso à configuração UEFI em placas ASUS TUF. A tecla **F2** também funciona como atalho alternativo em muitas revisões de firmware.

> **📝 NOTA:** Os nomes exatos de menu e submenu podem variar ligeiramente entre versões de firmware (BIOS) da ASUS. As referências abaixo seguem a nomenclatura típica do firmware AMI UEFI usado pela ASUS em placas B550 na interface avançada (modo "Advanced Mode", acessado pela tecla **F7** a partir da tela inicial simplificada "EZ Mode"). Se um item não estiver exatamente com o nome descrito, procure por termos semelhantes dentro do mesmo menu — a função é a mesma, apenas o texto pode diferir por versão de firmware.

Ao entrar na BIOS, pressione **F7** para alternar da "EZ Mode" (tela inicial simplificada, com informações resumidas de hardware) para o **"Advanced Mode"**, que expõe todos os menus detalhados necessários neste capítulo.

### SVM (Secure Virtual Machine)

**Localização típica:** `Advanced` → `CPU Configuration` → `SVM Mode`.

**O que é:** SVM é a extensão de virtualização de hardware da AMD (equivalente ao Intel VT-x). Sem ela habilitada, o KVM não consegue executar código de convidado diretamente na CPU física, e toda a pilha de virtualização do Capítulo 13 simplesmente não funciona (o KVM se recusa a carregar).

**Ação:** alterar de `Disabled` para **`Enabled`**.

> **⚠️ ALERTA:** Em algumas versões de firmware ASUS, esta opção aparece nomeada apenas como "SVM Mode" dentro de "CPU Configuration"; em outras, pode aparecer sob "AMD CBS" (AMD Common BIOS Settings) → "CPU Common Options" → "SVM Mode" — ambas controlam o mesmo bit de hardware.

### IOMMU (AMD-Vi)

**Localização típica:** `Advanced` → `AMD CBS` → `NBIO Common Options` → `IOMMU`.

**O que é:** habilita a unidade de gerenciamento de memória de entrada/saída da plataforma AMD (AMD-Vi), condição de hardware necessária para o VFIO funcionar (Capítulo 16). Sem isso habilitado no firmware, o parâmetro de kernel `amd_iommu=on` (Capítulo 16) não tem efeito algum, pois a funcionalidade está desligada na origem.

**Ação:** alterar de `Auto`/`Disabled` para **`Enabled`**.

### Above 4G Decoding

**Localização típica:** `Advanced` → `PCI Subsystem Settings` → `Above 4G Decoding`.

**O que é:** permite que dispositivos PCIe com grandes requisitos de espaço de endereço de memória (BARs — Base Address Registers) — como GPUs modernas com grandes quantidades de VRAM, caso da RTX 3060 com 12 GB — sejam mapeados em endereços acima de 4 GiB, fora da faixa tradicionalmente reservada para dispositivos de 32 bits. Isso é praticamente obrigatório para passthrough estável de GPUs NVIDIA modernas, pois evita conflitos de mapeamento de memória entre a GPU e o restante do sistema quando ela é reatribuída à VM.

**Ação:** alterar para **`Enabled`**.

### Resizable BAR (Re-Size BAR Support)

**Localização típica:** `Advanced` → `PCI Subsystem Settings` → `Re-Size BAR Support` (depende de Above 4G Decoding já estar habilitado, geralmente aparecendo logo abaixo dessa opção).

**O que é:** tecnologia que permite à CPU acessar a VRAM inteira da GPU em uma única janela de endereço, em vez de blocos limitados a 256 MiB (comportamento tradicional de BAR). Em uso nativo (bare metal), isso pode melhorar desempenho em alguns jogos. Em passthrough, seu comportamento é mais sensível: alguns combos de GPU/driver/QEMU lidam bem com Resizable BAR habilitado; outros apresentam instabilidade.

> **💡 DICA:** Deixe Resizable BAR **habilitado** neste primeiro momento, seguindo a recomendação padrão para RTX 30 series. Caso o Capítulo 27 (Benchmarks) ou o Capítulo 28 (Troubleshooting) revelem instabilidade na VM (travamentos, "Code 43" mencionado no Capítulo 18), este é um dos primeiros itens a testar desabilitado, como parte do diagnóstico.

**Ação:** `Enabled` (revisar novamente em caso de instabilidade futura).

### Modo de boot: UEFI vs CSM

**Localização típica:** `Boot` → `CSM (Compatibility Support Module)`.

**O que é:** o CSM emula o comportamento de BIOS legado (boot em modo Legacy/MBR) sobre um firmware UEFI moderno, para compatibilidade com sistemas operacionais antigos. Este documento usa exclusivamente **UEFI puro**, necessário para OVMF (o firmware virtual usado pela VM, Capítulo 13/17) operar de forma consistente com o host, e para instalação do Windows 11 (que exige UEFI e GPT como requisito, não apenas recomendação).

**Ação:** alterar CSM para **`Disabled`**. Isso também é pré-requisito para a instalação do Pop!_OS em modo UEFI (Capítulo 6), devendo, portanto, ser configurado **antes** daquele capítulo, conforme a ordem definida no Capítulo 4.

### Secure Boot

**Localização típica:** `Boot` → `Secure Boot` → `OS Type`.

**O que é:** mecanismo que verifica assinaturas criptográficas dos carregadores de boot e drivers de firmware (UEFI), impedindo a execução de código não assinado por uma autoridade confiável, como proteção contra bootkits/rootkits.

**Decisão para este ambiente:** Secure Boot é **desabilitado** neste documento (`Other OS` em vez de `Windows UEFI Mode`), por dois motivos práticos: (1) módulos de kernel de terceiros usados na pilha de virtualização e no driver NVIDIA podem exigir assinatura própria (MOK — Machine Owner Key) para funcionar com Secure Boot ativo, adicionando complexidade sem benefício de segurança relevante neste cenário de uso; (2) como não há dual boot, a instalação do Windows dentro da VM usa o **OVMF com Secure Boot da própria VM** (independente do Secure Boot do host), tratado separadamente no Capítulo 17.

**Ação:** alterar `OS Type` para **`Other OS`**, efetivamente desabilitando a aplicação de Secure Boot no host.

> **📝 NOTA:** Esta é uma decisão documentada, não uma obrigação técnica absoluta. Um administrador que deseje manter Secure Boot ativo no host pode fazê-lo, desde que esteja disposto a assinar manualmente (via MOK) os módulos DKMS do driver NVIDIA a cada atualização de kernel. Este documento opta pela simplicidade operacional.

### Tabela-resumo de todas as alterações de BIOS deste capítulo

| Opção | Menu (típico) | Valor final |
|---|---|---|
| SVM Mode | Advanced → CPU Configuration (ou AMD CBS → CPU Common Options) | Enabled |
| IOMMU | Advanced → AMD CBS → NBIO Common Options | Enabled |
| Above 4G Decoding | Advanced → PCI Subsystem Settings | Enabled |
| Re-Size BAR Support | Advanced → PCI Subsystem Settings | Enabled |
| CSM | Boot | Disabled |
| Secure Boot → OS Type | Boot → Secure Boot | Other OS |

### Salvando e saindo

**Localização típica:** `Save & Exit` → `Save Changes and Reset` (ou tecla de atalho **F10**).

## Comandos

Este capítulo é executado inteiramente dentro da interface da BIOS/UEFI, sem terminal Linux disponível. A verificação por comando ocorre **após** o boot do sistema operacional, na seção seguinte.

## Arquivos modificados

- Configuração NVRAM da placa-mãe (armazenada em memória CMOS/flash do firmware, fora de qualquer sistema de arquivos do Linux).

## Como verificar

Após salvar e reiniciar, dentro do Pop!_OS já instalado (ou live-CD, se a verificação ocorrer antes da instalação):

```bash
lscpu | grep -i svm
```
**Critério de sucesso:** a flag `svm` deve aparecer na lista de flags de CPU (a flag em si já existe independentemente da BIOS, pois é uma capacidade do processador — mas sua *utilização efetiva* depende do bit habilitado na BIOS, verificável de forma mais direta a seguir).

```bash
sudo dmesg | grep -i -e "AMD-Vi" -e "IOMMU"
```
**Critério de sucesso (após os parâmetros de kernel do Capítulo 16 também estarem aplicados):** mensagens como "AMD-Vi: Interrupt remapping enabled" ou "AMD-Vi: Found IOMMU". Neste ponto do documento (antes do Capítulo 16), a saída pode ainda estar vazia mesmo com a BIOS corretamente configurada, pois o kernel só ativa o IOMMU quando explicitamente instruído via parâmetro de boot.

```bash
sudo dmesg | grep -i "Secure boot"
```
**Critério de sucesso:** deve indicar que o Secure Boot está desabilitado (ex.: "Secure boot disabled"), confirmando a alteração de `OS Type` para `Other OS`.

## Resultado esperado

Firmware UEFI da placa-mãe configurado com SVM e IOMMU habilitados, CSM desabilitado (boot 100% UEFI), Above 4G Decoding e Resizable BAR habilitados, e Secure Boot desabilitado — todas as pré-condições de firmware necessárias para os capítulos de virtualização e VFIO satisfeitas.

## Como desfazer

Reingressar na BIOS e reverter cada opção da tabela-resumo ao valor original (`Disabled` para SVM/IOMMU/Above 4G/Resizable BAR, `Enabled` para CSM, `Windows UEFI Mode` para Secure Boot), ou usar a opção de firmware `Load Optimized Defaults` (geralmente **F5**) para restaurar todos os valores de fábrica, reaplicando manualmente apenas as alterações desejadas em seguida.

> **⚠️ ALERTA:** Desabilitar IOMMU/SVM após já ter uma VM configurada (Capítulos 13 em diante) impede o `libvirtd`/QEMU de iniciar qualquer VM, e o passthrough VFIO deixa de funcionar completamente até que as opções sejam reabilitadas.

## Problemas comuns

| Sintoma | Causa provável | Correção |
|---|---|---|
| Opção "IOMMU" não aparece em "NBIO Common Options" | Versão de firmware diferente da esperada, ou menu renomeado | Atualizar a BIOS para a versão mais recente disponível no site da ASUS para o modelo TUF GAMING B550-PLUS WIFI II, e procurar por "IOMMU" em qualquer submenu de "AMD CBS" |
| Sistema não inicializa após desabilitar CSM | Instalação anterior do Pop!_OS foi feita em modo Legacy/MBR (antes deste capítulo, fora de ordem) | Reinstalar o Pop!_OS em modo UEFI puro (Capítulo 6), respeitando a ordem definida no Capítulo 4 |
| Tela permanece preta ao tentar acessar a BIOS | Tecla Del não registrada a tempo, ou boot muito rápido (Fast Boot habilitado) | Desligar completamente (não apenas reiniciar), religar pressionando Del repetidamente desde o primeiro instante |

## Próxima etapa

Capítulo 13 — Instalação de KVM, QEMU, Libvirt, Virt-Manager, OVMF, SWTPM e VirtIO.

---

# Capítulo 13 — Instalação de KVM, QEMU, Libvirt, Virt-Manager, OVMF, SWTPM e VirtIO

## Objetivo

Instalar e explicar cada componente da pilha de virtualização necessária para criar e operar a VM Windows 11: KVM, QEMU, libvirt, Virt-Manager, OVMF, SWTPM e os drivers VirtIO.

## Pré-requisitos

- Capítulo 12 concluído (SVM habilitado na BIOS).
- Capítulo 7 concluído (sistema atualizado).

## Explicação

### O que é cada componente

```text
┌─────────────────────────────────────────────────────────────────┐
│  Virt-Manager (interface gráfica)                                 │
│         │ usa a API de                                            │
│         ▼                                                         │
│  Libvirt (libvirtd — daemon de gerenciamento e abstração)          │
│         │ gera e controla                                         │
│         ▼                                                         │
│  QEMU (emulador de máquina / camada de dispositivos virtuais)      │
│         │ usa aceleração de                                       │
│         ▼                                                         │
│  KVM (módulo de kernel — acesso às extensões de virtualização CPU) │
│                                                                     │
│  Componentes auxiliares usados pelo QEMU/Libvirt:                 │
│    OVMF   → firmware UEFI para a VM                               │
│    SWTPM  → TPM 2.0 emulado em software (requisito Windows 11)    │
│    VirtIO → drivers paravirtualizados de alto desempenho           │
└─────────────────────────────────────────────────────────────────┘
```

**KVM (Kernel-based Virtual Machine):** não é um programa que se instala separadamente — é um conjunto de módulos de kernel (`kvm`, `kvm_amd` na plataforma AMD) que expõe as extensões de virtualização de hardware (SVM) da CPU como um dispositivo de caractere `/dev/kvm`. Programas em espaço de usuário (como o QEMU) abrem esse dispositivo e o utilizam para executar código de convidado quase diretamente na CPU física, com o kernel interceptando apenas instruções privilegiadas específicas. Isso é o que torna a virtualização baseada em KVM ordens de magnitude mais rápida do que emulação pura de CPU.

**QEMU (Quick EMUlator):** é o emulador de máquina completo — implementa em software todos os dispositivos virtuais que uma VM enxerga (placa-mãe virtual, controladores de disco, rede, USB, vídeo) e orquestra a execução da CPU virtual, usando o KVM como acelerador quando disponível (em vez de emular a CPU em software puro, modo muito mais lento chamado TCG — Tiny Code Generator, usado apenas como fallback).

**Libvirt:** camada de gerenciamento e abstração sobre o QEMU (e outros hypervisors, como Xen — não utilizados aqui). Fornece uma API estável e uma representação declarativa em XML de cada VM, além de um daemon (`libvirtd`) que mantém as VMs em execução mesmo sem uma interface gráfica aberta, gerencia redes virtuais, pools de armazenamento e políticas de permissão (via `polkit`).

**Virt-Manager:** interface gráfica (GTK) que consome a API do libvirt, permitindo criar, configurar e operar VMs sem editar XML manualmente na maior parte dos casos — embora este documento também mostre edições diretas de XML quando a interface gráfica não expõe a opção necessária (como no passthrough de GPU).

**OVMF (Open Virtual Machine Firmware):** implementação de firmware **UEFI** para máquinas virtuais QEMU/KVM, baseada no projeto TianoCore EDK II. É o análogo, dentro da VM, à BIOS/UEFI física do host (Capítulo 12). É obrigatório para instalar Windows 11 (que exige UEFI) e é o que permite à VM ter sua própria configuração de Secure Boot, independente do host.

**SWTPM (Software TPM):** emulador de software de um módulo TPM (Trusted Platform Module) 2.0, um chip de segurança que o Windows 11 **exige** como requisito mínimo de instalação (verificação de integridade de boot, armazenamento seguro de chaves, BitLocker). Como a placa-mãe física pode ou não expor seu TPM físico (fTPM da AMD) para passthrough direto à VM — e fazer isso reduziria a disponibilidade do TPM físico para o próprio host — este documento usa SWTPM, um TPM inteiramente emulado em software, dedicado exclusivamente à VM.

**VirtIO:** conjunto de especificações e drivers paravirtualizados (não emulam hardware real, mas expõem uma interface otimizada para comunicação entre convidado e hypervisor) para disco, rede, balão de memória e outros dispositivos. Drivers VirtIO no Windows exigem instalação manual (Capítulo 18), pois não são nativos do Windows — mas, uma vez instalados, oferecem desempenho de I/O sensivelmente superior à emulação de hardware legado (como um controlador IDE ou placa de rede Realtek emulados).

## Comandos

```bash
sudo apt update
sudo apt install -y \
  qemu-kvm \
  qemu-utils \
  libvirt-daemon-system \
  libvirt-clients \
  bridge-utils \
  virt-manager \
  ovmf \
  swtpm \
  swtpm-tools \
  virtinst
```

**O que cada pacote fornece:**

| Pacote | Função |
|---|---|
| `qemu-kvm` | Binários do QEMU com aceleração KVM |
| `qemu-utils` | Utilitários como `qemu-img` (criação/conversão de imagens de disco virtual, usado no Capítulo 17) |
| `libvirt-daemon-system` | O daemon `libvirtd` e integração com systemd; cria os usuários/grupos de sistema `libvirt-qemu` e `libvirt` |
| `libvirt-clients` | Utilitários de linha de comando (`virsh`) para gerenciar VMs sem interface gráfica |
| `bridge-utils` | Utilitários legados de configuração de bridge de rede (`brctl`), úteis para diagnóstico mesmo quando a bridge é gerenciada por `netplan`/`NetworkManager` (Capítulo 23) |
| `virt-manager` | Interface gráfica |
| `ovmf` | Firmware UEFI virtual (arquivos `OVMF_CODE.fd`/`OVMF_VARS.fd`) |
| `swtpm`, `swtpm-tools` | Emulador de TPM e utilitários de linha de comando associados |
| `virtinst` | Conjunto de ferramentas de linha de comando para criação de VMs (`virt-install`), usadas como alternativa/complemento ao Virt-Manager |

```bash
sudo systemctl enable --now libvirtd
```
**O que faz:** habilita o serviço `libvirtd` para iniciar automaticamente em todo boot (`enable`) e o inicia imediatamente (`--now`), sem precisar de um reboot para começar a usá-lo.

```bash
sudo systemctl status libvirtd
```
**O que faz:** exibe o estado atual do daemon — deve mostrar `active (running)`.

## Arquivos modificados

- Pacotes instalados via `apt`.
- `/etc/libvirt/` (diretório de configuração criado pela instalação, incluindo `qemu.conf`, `libvirtd.conf`, `qemu/networks/default.xml`).
- Novo usuário de sistema `libvirt-qemu` e grupo `libvirt` criados em `/etc/passwd`/`/etc/group`.
- `/usr/share/OVMF/` (arquivos de firmware `OVMF_CODE.fd` e `OVMF_VARS.fd`).
- Unidade systemd `libvirtd.service` habilitada.

## Como verificar

```bash
virsh --connect qemu:///system list --all
```
**O que faz:** conecta-se ao daemon `libvirtd` no modo sistema (`qemu:///system`, em oposição ao modo sessão de usuário, `qemu:///session` — este documento usa exclusivamente o modo sistema, por ser o padrão do Virt-Manager e por permitir compartilhar dispositivos PCI com privilégio de root necessário ao VFIO) e lista todas as VMs conhecidas.

**Critério de sucesso:** o comando retorna uma tabela vazia (nenhuma VM criada ainda) **sem** erro de conexão — um erro de conexão nesta etapa indica problema com o daemon `libvirtd` ou permissões, tratado no Capítulo 14.

```bash
kvm-ok 2>/dev/null || (sudo apt install -y cpu-checker && kvm-ok)
```
**O que faz:** o utilitário `kvm-ok` (do pacote `cpu-checker`) verifica se a aceleração KVM está de fato disponível — combinação de flag de CPU (`svm`), habilitação na BIOS (Capítulo 12) e módulo de kernel carregado.

**Critério de sucesso:** saída contendo "KVM acceleration can be used".

```bash
ls /usr/share/OVMF/
```
**Critério de sucesso:** lista os arquivos `OVMF_CODE.fd` e `OVMF_VARS.fd` (ou variantes com sufixo `_4M`, dependendo da versão do pacote).

## Resultado esperado

Pilha completa de virtualização instalada e operacional: `libvirtd` ativo, `virsh --connect qemu:///system list --all` funcional, KVM confirmado como disponível, firmware OVMF presente no sistema, `swtpm` instalado e pronto para uso na criação da VM (Capítulo 17).

## Como desfazer

```bash
sudo systemctl disable --now libvirtd
sudo apt purge -y qemu-kvm qemu-utils libvirt-daemon-system libvirt-clients bridge-utils virt-manager ovmf swtpm swtpm-tools virtinst
sudo apt autoremove -y
sudo rm -rf /etc/libvirt /var/lib/libvirt
```

> **⚠️ ALERTA:** `rm -rf /var/lib/libvirt` remove também os discos de VMs armazenados no local padrão do libvirt (`/var/lib/libvirt/images`). Como este ambiente usa `/vm/Windows11.qcow2` como local customizado (Capítulo 10), o arquivo de disco da VM **não** é apagado por este comando — mas confirme sempre a localização antes de executar remoções em massa.

## Problemas comuns

| Sintoma | Causa provável | Correção |
|---|---|---|
| `kvm-ok` reporta "KVM acceleration can NOT be used" | SVM desabilitado na BIOS (Capítulo 12 não aplicado ou revertido) | Revisar Capítulo 12 |
| `virsh --connect qemu:///system list --all` retorna erro de permissão/conexão | Usuário `<USUARIO_LINUX>` não está no grupo `libvirt` | Ver Capítulo 14 |
| `systemctl status libvirtd` mostra `failed` | Conflito de configuração ou módulo KVM não carregado | `sudo modprobe kvm_amd`; verificar `journalctl -u libvirtd -e` para o erro específico |

## Próxima etapa

Capítulo 14 — Configuração de Usuário, Grupos e Serviços, garantindo que `<USUARIO_LINUX>` opere o Virt-Manager sem precisar de `sudo` a cada ação.

---

# Capítulo 14 — Configuração de Usuário, Grupos e Serviços

## Objetivo

Adicionar o usuário `<USUARIO_LINUX>` aos grupos necessários para operar libvirt/QEMU sem privilégios administrativos explícitos a cada comando, ajustar a permissão do diretório `/vm` para o usuário de sistema do QEMU, e confirmar todos os serviços relevantes ativos.

## Pré-requisitos

- Capítulo 13 concluído (pacotes de virtualização instalados, criando os grupos `libvirt` e `kvm`).

## Explicação

### Por que grupos, e não sudo constante

O daemon `libvirtd` escuta em um socket Unix (`/var/run/libvirt/libvirt-sock`) cuja permissão de acesso é controlada por grupo. Adicionar o usuário ao grupo `libvirt` concede acesso a esse socket sem exigir `sudo` para cada operação do Virt-Manager ou `virsh`. Da mesma forma, o grupo `kvm` controla o acesso direto ao dispositivo `/dev/kvm`.

| Grupo | Concede acesso a |
|---|---|
| `libvirt` | Socket de gerenciamento do `libvirtd` (criar/parar/editar VMs) |
| `kvm` | Dispositivo `/dev/kvm` (aceleração de CPU) |

### Por que `/vm` precisa de ajuste de permissão

Conforme explicado no Capítulo 10, o processo QEMU real (o processo que efetivamente executa a VM) roda, no modo sistema do libvirt, sob o usuário de sistema `libvirt-qemu`, não sob `<USUARIO_LINUX>` — mesmo que seja `<USUARIO_LINUX>` quem clique em "Iniciar" no Virt-Manager. Isso é uma medida de segurança do libvirt: o processo que efetivamente toca hardware/dispositivos roda com privilégios mínimos, e apenas o daemon `libvirtd` (que gerencia, mas não executa diretamente o hardware da VM) roda como root.

Isso significa que o arquivo `/vm/Windows11.qcow2` (criado no Capítulo 17) precisa ser legível e gravável pelo usuário `libvirt-qemu`.

## Comandos

```bash
sudo usermod -aG libvirt <USUARIO_LINUX>
sudo usermod -aG kvm <USUARIO_LINUX>
```
**O que fazem:** adicionam (`-a`, "append", crucial para não remover o usuário de outros grupos já associados) o usuário `<USUARIO_LINUX>` aos grupos `libvirt` e `kvm`.

```bash
id <USUARIO_LINUX>
```
**O que faz:** lista todos os grupos do usuário. Os novos grupos só aparecem em **novas** sessões de login — é necessário logout/login (ou reboot) para que o shell atual reflita a mudança.

```bash
sudo chown root:libvirt-qemu /vm
sudo chmod 770 /vm
```
**O que fazem:** transferem o grupo do diretório `/vm` para `libvirt-qemu` (usuário/grupo de sistema criado pela instalação do libvirt no Capítulo 13) e ajustam a permissão para `770` (leitura/escrita/execução para dono e grupo, nenhum acesso para outros) — o processo QEMU (grupo `libvirt-qemu`) poderá criar e escrever o arquivo `.qcow2` dentro de `/vm`, mantendo o diretório inacessível a outros usuários do sistema.

> **📝 NOTA:** O nome exato do usuário/grupo de sistema do QEMU pode variar entre distribuições. No Pop!_OS/Ubuntu, é tipicamente `libvirt-qemu` tanto para usuário quanto grupo. Confirme com `getent passwd | grep libvirt` e `getent group | grep libvirt` antes de aplicar, caso o nome divirja do esperado.

```bash
getent passwd | grep libvirt
getent group | grep libvirt
```
**O que fazem:** confirmam os nomes exatos de usuário/grupo de sistema criados pela instalação do libvirt, evitando erro de digitação no comando `chown` acima.

```bash
sudo systemctl enable --now libvirtd
sudo systemctl status libvirtd --no-pager
sudo systemctl enable --now virtlogd
```
**O que fazem:** garantem que `libvirtd` (daemon principal) e `virtlogd` (daemon responsável por registrar a saída de console/log de cada VM) estejam habilitados e ativos.

## Arquivos modificados

- `/etc/group` (usuário `<USUARIO_LINUX>` adicionado aos grupos `libvirt` e `kvm`).
- Permissões e grupo do diretório `/vm` (dono/grupo alterados).

## Como verificar

Após logout/login (ou `newgrp libvirt` para uma verificação rápida na mesma sessão, sem afetar sessões futuras):

```bash
id
```
**Critério de sucesso:** a saída inclui `libvirt` e `kvm` na lista de grupos.

```bash
virsh --connect qemu:///system list --all
```
**Critério de sucesso:** executa **sem** `sudo` e sem erro de permissão, retornando a lista (vazia, neste ponto) de VMs.

```bash
sudo -u libvirt-qemu touch /vm/teste-permissao
ls -la /vm/teste-permissao
rm /vm/teste-permissao
```
**O que faz:** simula a criação de um arquivo pelo usuário `libvirt-qemu`, exatamente como ocorrerá ao criar o disco da VM no Capítulo 17. **Critério de sucesso:** o arquivo é criado sem erro de permissão.

## Resultado esperado

Usuário `<USUARIO_LINUX>` capaz de operar o Virt-Manager e o `virsh` sem `sudo`; diretório `/vm` com permissão correta para o processo QEMU criar e manter o disco virtual da VM; serviços `libvirtd` e `virtlogd` ativos e habilitados no boot.

## Como desfazer

```bash
sudo gpasswd -d <USUARIO_LINUX> libvirt
sudo gpasswd -d <USUARIO_LINUX> kvm
sudo chown root:root /vm
sudo chmod 755 /vm
```

## Problemas comuns

| Sintoma | Causa provável | Correção |
|---|---|---|
| `virsh --connect qemu:///system list` ainda pede senha/nega acesso após `usermod` | Sessão de shell antiga, grupos não recarregados | Fazer logout/login completo (não apenas fechar o terminal) |
| Virt-Manager não inicia a VM, erro mencionando `/vm/Windows11.qcow2: Permission denied` | Permissão de `/vm` incorreta, ou SELinux/AppArmor bloqueando (ver Capítulo 17) | Revisar `chown`/`chmod` deste capítulo; revisar perfil AppArmor no Capítulo 17 |
| `sudo -u libvirt-qemu touch` falha | Nome de usuário de sistema incorreto (variação de distribuição) | Reconfirmar com `getent passwd \| grep libvirt` |

## Próxima etapa

Capítulo 15 — Bootloader: GRUB vs systemd-boot no Pop!_OS, necessário antes de editar parâmetros de kernel para VFIO no Capítulo 16.

---

# Capítulo 15 — Bootloader: GRUB vs systemd-boot no Pop!_OS

## Objetivo

Determinar com certeza qual bootloader o Pop!_OS instalado está utilizando, pois o Capítulo 16 exige editar parâmetros de kernel de formas diferentes dependendo dessa resposta.

## Pré-requisitos

- Pop!_OS instalado (Capítulo 6).

## Explicação

### Por que isso importa

Diferentes bootloaders armazenam e aplicam parâmetros de linha de comando do kernel (como os parâmetros de IOMMU do Capítulo 16) em locais e formatos distintos:

| Bootloader | Onde os parâmetros de kernel são definidos |
|---|---|
| **GRUB** | `/etc/default/grub` (variável `GRUB_CMDLINE_LINUX_DEFAULT`), aplicado via `update-grub` |
| **systemd-boot** | Arquivos de entrada em `/boot/efi/loader/entries/*.conf` (ou gerenciados por `kernelstub` no caso específico do Pop!_OS) |

Aplicar o procedimento errado (por exemplo, editar `/etc/default/grub` em um sistema que na verdade usa `systemd-boot`) resulta em uma alteração que **nunca é lida** pelo bootloader real em uso — um erro sutil e frustrante de diagnosticar, pois nenhum erro é exibido: a alteração simplesmente não tem efeito algum no próximo boot.

### Qual bootloader o Pop!_OS usa

O Pop!_OS, a partir da versão 20.04 do sistema, **substituiu o GRUB por systemd-boot como padrão** em instalações que utilizam UEFI (não Legacy/CSM) — exatamente o cenário deste documento, dado que o Capítulo 12 desabilitou o CSM. O Pop!_OS gerencia as entradas do systemd-boot através de uma ferramenta própria chamada **`kernelstub`**, que atualiza automaticamente os parâmetros de kernel em todas as entradas de boot cadastradas.

> **⚠️ ALERTA:** Esta é a expectativa **padrão** para uma instalação UEFI limpa do Pop!_OS, mas **não deve ser assumida sem verificação**. Versões diferentes do Pop!_OS, instalações herdadas de versões antigas migradas, ou instalações em modo Legacy/CSM (que este documento explicitamente evita, Capítulo 12) podem usar GRUB. O comando abaixo remove qualquer ambiguidade.

### Como descobrir com certeza

```bash
test -d /sys/firmware/efi && echo "Sistema em modo UEFI" || echo "Sistema em modo Legacy/BIOS"
```
**O que faz:** confirma que o sistema está de fato inicializando em modo UEFI (pré-requisito para systemd-boot; se o sistema estiver em modo Legacy, o bootloader é necessariamente GRUB).

```bash
which kernelstub && echo "Este sistema usa kernelstub/systemd-boot (padrão Pop!_OS)"
```
**O que faz:** verifica a presença do utilitário `kernelstub`, exclusivo de instalações Pop!_OS com systemd-boot.

```bash
test -f /boot/efi/loader/loader.conf && echo "Configuração de systemd-boot encontrada em /boot/efi/loader/"
ls /boot/efi/loader/entries/ 2>/dev/null
```
**O que faz:** confirma a presença física dos arquivos de configuração do systemd-boot e lista as entradas de boot cadastradas (uma por versão de kernel instalada).

```bash
test -f /boot/grub/grub.cfg && echo "Configuração de GRUB encontrada em /boot/grub/grub.cfg — este sistema usa GRUB"
```
**O que faz:** verifica a presença do arquivo de configuração compilado do GRUB. Em uma instalação padrão do Pop!_OS com systemd-boot, este arquivo tipicamente **não existe**.

## Comandos

Bloco de diagnóstico único, recomendado para execução e registro:

```bash
{
  echo "== Modo de firmware =="
  test -d /sys/firmware/efi && echo "UEFI" || echo "Legacy/BIOS"
  echo "== kernelstub presente? =="
  which kernelstub 2>/dev/null || echo "não encontrado"
  echo "== systemd-boot loader.conf =="
  test -f /boot/efi/loader/loader.conf && cat /boot/efi/loader/loader.conf || echo "não encontrado"
  echo "== Entradas systemd-boot =="
  ls /boot/efi/loader/entries/ 2>/dev/null || echo "diretório não encontrado"
  echo "== grub.cfg =="
  test -f /boot/grub/grub.cfg && echo "encontrado — sistema usa GRUB" || echo "não encontrado"
} | tee ~/inventario-hardware/bootloader-$(date +%Y%m%d).txt
```

## Arquivos modificados

- `~/inventario-hardware/bootloader-<data>.txt` (criado, diagnóstico).

## Como verificar

Analisar a saída do bloco acima:

- Se `kernelstub` foi encontrado **e** `/boot/efi/loader/entries/` lista arquivos `.conf` **e** `/boot/grub/grub.cfg` **não** foi encontrado → o sistema usa **systemd-boot**, e o Capítulo 16 deve seguir o procedimento via `kernelstub`.
- Se `/boot/grub/grub.cfg` **foi** encontrado → o sistema usa **GRUB**, e o Capítulo 16 deve seguir o procedimento via `/etc/default/grub` + `update-grub`.

## Resultado esperado

Confirmação documentada e definitiva de qual bootloader este sistema específico utiliza, eliminando ambiguidade antes de editar parâmetros de kernel no Capítulo 16.

## Como desfazer

Não aplicável — capítulo de diagnóstico, sem alteração de sistema.

## Problemas comuns

| Sintoma | Causa provável | Correção |
|---|---|---|
| Ambos `kernelstub` e `grub.cfg` presentes | Sistema migrado de versão antiga, ou GRUB instalado manualmente por engano sobre um sistema systemd-boot | Priorizar o bootloader que efetivamente aparece no menu de boot ao ligar a máquina; em caso de dúvida, testar a alteração de um parâmetro trivial e observar `cat /proc/cmdline` após reboot para ver qual mecanismo teve efeito |
| Nenhum dos dois encontrado | Sistema em estado incomum ou comandos executados em ambiente incorreto (ex.: chroot parcial) | Reexecutar a partir de uma sessão normal do Pop!_OS já instalado e inicializado normalmente |

## Próxima etapa

Capítulo 16 — Configuração Completa de IOMMU e VFIO, o núcleo técnico deste documento.

---

# Capítulo 16 — Configuração Completa de IOMMU e VFIO

## Objetivo

Habilitar o IOMMU no kernel Linux, identificar com precisão os endereços PCI e IDs vendor:device da GPU e de sua função de áudio, verificar o isolamento em grupos IOMMU, e vincular esses dispositivos ao driver `vfio-pci` de forma controlada — preparando a GPU para ser repassada à VM sem, ainda, tirá-la permanentemente do uso do Linux (isso será feito de forma dinâmica no Capítulo 19).

## Pré-requisitos

- Capítulo 12 concluído (SVM e IOMMU habilitados na BIOS).
- Capítulo 15 concluído (bootloader identificado com certeza).
- Capítulo 8 concluído (driver NVIDIA funcional no host).

## Explicação

### O papel do IOMMU e dos grupos IOMMU

Como introduzido no Capítulo 1, o IOMMU (AMD-Vi) isola dispositivos PCI para que o DMA de um dispositivo repassado a uma VM não possa acessar memória fora do que foi alocado a essa VM. Na prática, o IOMMU não isola dispositivos individualmente, um a um — ele os agrupa em **grupos IOMMU**, de acordo com a topologia física do barramento PCIe (quais dispositivos compartilham o mesmo caminho de comutação/*bridge* PCIe).

**Regra fundamental:** todos os dispositivos dentro do mesmo grupo IOMMU devem ser repassados **juntos** à mesma VM (ou todos ficarem com o host) — não é possível dividir um grupo entre host e VM, pois o isolamento de DMA garantido pelo IOMMU só é válido no nível do grupo inteiro.

Para GPUs modernas em slots PCIe x16 dedicados (como é o caso típico de uma RTX 3060 no slot primário de uma B550-Plus), é comum e esperado que a função de vídeo e a função de áudio HDMI da própria placa apareçam **no mesmo grupo IOMMU** (ambas são funções do mesmo dispositivo PCI multifunção) — o que é desejável, pois ambas precisam ir para a VM de qualquer forma. Problemas surgem quando **outros** dispositivos não relacionados (por exemplo, uma controladora USB ou outra placa) aparecem agrupados junto com a GPU — nesse caso, seria necessário repassar tudo junto, o que raramente é desejável.

```text
Exemplo de topologia PCIe favorável (GPU isolada em seu próprio grupo):

Grupo IOMMU 14
 ├─ 0c:00.0  VGA compatible controller: NVIDIA RTX 3060
 └─ 0c:00.1  Audio device: NVIDIA (áudio HDMI da GPU)

Grupo IOMMU 15
 └─ 0d:00.0  Ethernet controller (permanece com o host, grupo separado)
```

### Identificando os dispositivos PCI da GPU

```bash
lspci -nn | grep -i nvidia
```
**O que faz:** lista, com IDs numéricos, todas as entradas PCI cujo nome contém "NVIDIA" — tipicamente duas linhas: a função de vídeo (VGA compatible controller) e a função de áudio HDMI, ambas no mesmo endereço de barramento/dispositivo, diferindo apenas no número de função (`.0` e `.1`).

Exemplo de **formato** de saída esperado (valores meramente ilustrativos):

```text
0c:00.0 VGA compatible controller [0300]: NVIDIA Corporation GA106 [GeForce RTX 3060] [10de:XXXX] (rev a1)
0c:00.1 Audio device [0403]: NVIDIA Corporation GA106 High Definition Audio Controller [10de:XXXX]
```

> **⚠️ ALERTA:** Os quatro dígitos após `10de:` (fabricante NVIDIA) variam conforme a variante exata do chip GA106 usado na sua RTX 3060 específica (há pequenas variações entre fabricantes de placa/BIOS de placa). **Nunca** copie um ID de exemplo de tutorial algum. Use exclusivamente a saída do `lspci -nn` do seu próprio sistema para obter `<GPU_VENDOR_DEVICE_ID>` e `<GPU_AUDIO_VENDOR_DEVICE_ID>`.

A partir da saída real do seu sistema:

- O endereço antes do primeiro espaço na linha de vídeo (ex.: `0c:00.0`) é o `<GPU_PCI_ID>` (adicione o prefixo de domínio `0000:` para uso em alguns comandos: `0000:0c:00.0`).
- O endereço equivalente na linha de áudio é o `<GPU_AUDIO_PCI_ID>`.
- O par entre colchetes ao final de cada linha (ex.: `[10de:2504]`) é, respectivamente, `<GPU_VENDOR_DEVICE_ID>` e `<GPU_AUDIO_VENDOR_DEVICE_ID>`.

### Verificando os grupos IOMMU

O IOMMU precisa estar habilitado no kernel (próxima subseção) para que os grupos sejam populados em `/sys/kernel/iommu_groups/`. Após habilitar (e reiniciar), use o script abaixo — amplamente utilizado pela comunidade de passthrough e reproduzido aqui por completo, com cada linha comentada:

```bash
#!/bin/bash
# Script: listar-grupos-iommu.sh
# Lista todos os dispositivos PCI agrupados por grupo IOMMU.
for grupo in /sys/kernel/iommu_groups/*; do
    numero_grupo="${grupo##*/}"                       # extrai apenas o número do grupo do caminho
    for dispositivo in "$grupo"/devices/*; do
        endereco="${dispositivo##*/}"                  # extrai o endereço PCI (ex.: 0000:0c:00.0)
        echo "Grupo IOMMU $numero_grupo: $(lspci -nns "${endereco#*:}")"
        # lspci -nns filtra pelo endereço exato e mostra nome + IDs
    done
done
```

Salve como `~/listar-grupos-iommu.sh`, torne executável e rode:

```bash
chmod +x ~/listar-grupos-iommu.sh
~/listar-grupos-iommu.sh | tee ~/inventario-hardware/grupos-iommu-$(date +%Y%m%d).txt
```

**Como interpretar:** localize as linhas correspondentes a `<GPU_PCI_ID>` e `<GPU_AUDIO_PCI_ID>` na saída — ambas devem estar no mesmo número de grupo (esse número é o `<IOMMU_GROUP_GPU>`). Verifique se **algum outro dispositivo não relacionado à GPU** também aparece nesse mesmo grupo.

> **📝 NOTA:** Este script só produz saída útil **depois** que o IOMMU estiver habilitado via parâmetro de kernel (próxima subseção) e o sistema tiver sido reiniciado. Antes disso, o diretório `/sys/kernel/iommu_groups/` está vazio ou não existe.

### Habilitando IOMMU no kernel (parâmetros de boot)

Com base no Capítulo 15, siga **apenas uma** das duas subseções abaixo, conforme o bootloader identificado.

#### Caso systemd-boot (padrão do Pop!_OS)

```bash
sudo kernelstub -a "amd_iommu=on iommu=pt"
```

**O que faz:** o utilitário `kernelstub`, específico do Pop!_OS, adiciona (`-a`, append) os parâmetros informados à linha de comando do kernel em **todas** as entradas de boot gerenciadas, persistindo a alteração em `/boot/efi/loader/entries/*.conf` automaticamente.

**Explicação dos parâmetros:**

- `amd_iommu=on`: força a ativação do AMD-Vi no kernel, mesmo que a detecção automática (`amd_iommu=auto`, o padrão) eventualmente hesite em algum cenário de firmware. É uma ativação explícita e inequívoca.
- `iommu=pt` ("passthrough" no sentido de modo de tradução, não confundir com VFIO passthrough de dispositivo): configura o modo de tradução IOMMU como *passthrough* para dispositivos que **não** estão explicitamente isolados para uma VM — ou seja, dispositivos usados normalmente pelo host (disco, rede, USB) continuam operando com tradução de endereço mínima/direta, evitando uma pequena sobrecarga de desempenho de I/O que o modo de tradução completo imporia a esses dispositivos. Dispositivos explicitamente vinculados ao `vfio-pci` (a GPU, quando ativado) continuam plenamente isolados, independentemente deste parâmetro.

#### Caso GRUB

```bash
sudo cp /etc/default/grub /etc/default/grub.bak-$(date +%Y%m%d)
sudo nano /etc/default/grub
```

Localize a linha `GRUB_CMDLINE_LINUX_DEFAULT` e adicione os parâmetros dentro das aspas existentes:

```text
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash amd_iommu=on iommu=pt"
```

Salve e aplique:

```bash
sudo update-grub
```
**O que faz:** relê `/etc/default/grub` e regenera `/boot/grub/grub.cfg`, o arquivo efetivamente lido pelo GRUB no boot.

### Reiniciando e confirmando

```bash
sudo reboot
```

Após o boot:

```bash
cat /proc/cmdline
```
**Critério de sucesso:** a linha exibida deve conter literalmente `amd_iommu=on` e `iommu=pt`, confirmando que o parâmetro foi de fato aplicado ao kernel em execução (não apenas salvo em um arquivo de configuração).

```bash
sudo dmesg | grep -i -e "AMD-Vi" -e "IOMMU" | head -n 20
```
**Critério de sucesso:** mensagens como "AMD-Vi: Found IOMMU" e "AMD-Vi: Interrupt remapping enabled" — confirmação, agora vinda do próprio kernel em execução, de que o hardware e o firmware (Capítulo 12) estão cooperando corretamente com o parâmetro de kernel recém-aplicado.

### Vinculando a GPU ao VFIO-PCI

Existem duas estratégias possíveis para vincular a GPU ao driver `vfio-pci`: **estática** (sempre vinculada ao `vfio-pci` desde o boot, via `initramfs`) ou **dinâmica** (vinculada apenas no momento em que a VM inicia, via hook scripts, revertendo ao desligar). Para o cenário de **GPU única** deste ambiente, a estratégia estática deixaria o Linux **permanentemente sem vídeo** (contrariando diretamente o requisito do Capítulo 1 de que "quando a VM desligar, a GPU deve voltar ao Linux"). Portanto, **este documento não vincula a GPU ao `vfio-pci` de forma estática/permanente no boot** — a vinculação estática é abordada aqui apenas para fins de teste pontual e entendimento; a vinculação real, dinâmica e reversível, é implementada pelos hook scripts do Capítulo 19.

> **📝 NOTA:** Ainda assim, o módulo `vfio-pci` precisa estar carregado e disponível no kernel para que os hook scripts do Capítulo 19 possam usá-lo sob demanda. Esta subseção prepara essa disponibilidade, sem prender a GPU a ele permanentemente.

Garanta que o módulo `vfio-pci` seja carregado no `initramfs` (early boot), **sem** o parâmetro `ids=` que o vincularia estaticamente à GPU:

```bash
echo "vfio" | sudo tee -a /etc/modules-load.d/vfio.conf
echo "vfio_pci" | sudo tee -a /etc/modules-load.d/vfio.conf
echo "vfio_iommu_type1" | sudo tee -a /etc/modules-load.d/vfio.conf
```
**O que fazem:** instruem o systemd a carregar os módulos `vfio`, `vfio_pci` e `vfio_iommu_type1` (interface de mapeamento de memória usada pelo VFIO) automaticamente em todo boot, ficando disponíveis para o `modprobe`/`echo` que os hook scripts do Capítulo 19 executarão sob demanda.

```bash
sudo update-initramfs -u -k all
```
**O que faz:** regenera o `initramfs` (sistema de arquivos temporário carregado antes da raiz real, no início do boot) para todas as versões de kernel instaladas (`-k all`), incorporando a nova configuração de carregamento automático de módulos.

> **⚠️ ALERTA:** Diferentemente de guias de passthrough que assumem duas GPUs (onde é seguro vincular a GPU dedicada à VM permanentemente ao `vfio-pci` desde o boot, via `options vfio-pci ids=<GPU_VENDOR_DEVICE_ID>,<GPU_AUDIO_VENDOR_DEVICE_ID>` em `/etc/modprobe.d/vfio.conf`), este documento **evita deliberadamente** esse padrão, pois neste hardware específico (GPU única) isso deixaria o Linux permanentemente sem saída de vídeo, mesmo com a VM desligada. Se você optar por essa abordagem estática de qualquer forma (por exemplo, em uma futura expansão do ambiente com uma segunda GPU dedicada ao host), o arquivo de configuração seria:
>
> ```text
> # /etc/modprobe.d/vfio.conf — SOMENTE aplicável em cenário de GPU dedicada separada para o host
> options vfio-pci ids=<GPU_VENDOR_DEVICE_ID>,<GPU_AUDIO_VENDOR_DEVICE_ID>
> ```

## Comandos

Resumo sequencial (systemd-boot):

```bash
lspci -nn | grep -i nvidia
chmod +x ~/listar-grupos-iommu.sh
sudo kernelstub -a "amd_iommu=on iommu=pt"
echo "vfio" | sudo tee -a /etc/modules-load.d/vfio.conf
echo "vfio_pci" | sudo tee -a /etc/modules-load.d/vfio.conf
echo "vfio_iommu_type1" | sudo tee -a /etc/modules-load.d/vfio.conf
sudo update-initramfs -u -k all
sudo reboot
# após o reboot:
cat /proc/cmdline
sudo dmesg | grep -i -e "AMD-Vi" -e "IOMMU"
~/listar-grupos-iommu.sh
```

## Arquivos modificados

- `/boot/efi/loader/entries/*.conf` (via `kernelstub`) **ou** `/etc/default/grub` + `/boot/grub/grub.cfg` (via GRUB), conforme o bootloader identificado no Capítulo 15.
- `/etc/modules-load.d/vfio.conf` (criado).
- `/boot/initrd.img-<VERSAO_KERNEL>` (regenerado para todas as versões de kernel instaladas).
- `~/inventario-hardware/grupos-iommu-<data>.txt` (criado, diagnóstico).

## Como verificar

```bash
cat /proc/cmdline | grep -o "amd_iommu=on iommu=pt"
lsmod | grep vfio
```

**Critério de sucesso:** o primeiro comando retorna a string dos parâmetros (confirmando que estão ativos no kernel em execução); o segundo lista os módulos `vfio`, `vfio_pci` e `vfio_iommu_type1` carregados.

```bash
~/listar-grupos-iommu.sh | grep -B1 -A1 -i nvidia
```

**Critério de sucesso:** as linhas de vídeo e áudio da NVIDIA aparecem sob o mesmo número de grupo IOMMU, idealmente sem nenhum outro dispositivo não relacionado nesse grupo.

## Resultado esperado

IOMMU habilitado e confirmado ativo no kernel em execução; GPU e sua função de áudio identificadas com precisão (endereços PCI e IDs vendor:device documentados); grupo IOMMU da GPU verificado e registrado; módulos `vfio`/`vfio_pci`/`vfio_iommu_type1` disponíveis para uso sob demanda pelos hook scripts do Capítulo 19.

## Como desfazer

Systemd-boot:
```bash
sudo kernelstub -d "amd_iommu=on iommu=pt"
```
GRUB:
```bash
sudo cp /etc/default/grub.bak-<data> /etc/default/grub
sudo update-grub
```
Ambos:
```bash
sudo rm /etc/modules-load.d/vfio.conf
sudo update-initramfs -u -k all
sudo reboot
```

## Problemas comuns

| Sintoma | Causa provável | Correção |
|---|---|---|
| `/proc/cmdline` não contém os parâmetros após reboot | Parâmetros aplicados ao bootloader errado (ver Capítulo 15) | Reconfirmar bootloader real em uso e reaplicar via o método correto |
| Grupo IOMMU da GPU contém dispositivos adicionais não relacionados | Topologia de barramento PCIe da placa-mãe agrupa múltiplos dispositivos sob a mesma bridge | Testar outro slot PCIe físico, se disponível; ou aplicar patch ACS override (fora do escopo padrão deste documento, tratado no Capítulo 28 como último recurso, com os riscos de segurança explicados) |
| `dmesg` não mostra mensagens de AMD-Vi mesmo com parâmetros corretos | BIOS com IOMMU ainda desabilitado (Capítulo 12 revertido ou não salvo corretamente) | Reentrar na BIOS e confirmar que a opção foi de fato salva (`Save & Exit`, não apenas `Exit`) |
| `lsmod \| grep vfio` vazio mesmo após `update-initramfs` | Módulos não compilados no kernel atual, ou `modules-load.d` com erro de digitação | Verificar `cat /etc/modules-load.d/vfio.conf`; testar `sudo modprobe vfio_pci` manualmente e observar erro |

## Próxima etapa

Capítulo 17 — Criação da Máquina Virtual no Virt-Manager.

---

# Capítulo 17 — Criação da Máquina Virtual no Virt-Manager

## Objetivo

Criar a VM Windows 11 no Virt-Manager, com firmware OVMF (UEFI + Secure Boot próprio), TPM emulado via SWTPM, disco de sistema QCOW2 dinâmico de 250 GB em `/vm/Windows11.qcow2`, CPU em modo host-passthrough, VirtIO para disco/rede, e as demais opções de RAM, vídeo (temporário, pré-passthrough) e áudio.

## Pré-requisitos

- Capítulo 13 concluído (pilha de virtualização instalada).
- Capítulo 14 concluído (permissões de usuário e `/vm` ajustadas).
- Capítulo 16 concluído (IOMMU habilitado — embora a vinculação efetiva da GPU ao VFIO só ocorra dinamicamente no Capítulo 19, o IOMMU já deve estar ativo).
- ISO do Windows 11 baixada (ver nota abaixo).
- ISO dos drivers VirtIO baixada (`virtio-win.iso`, projeto oficial `virtio-win` mantido pelos desenvolvedores do QEMU/Red Hat).

> **📝 NOTA:** Este documento não fornece links de download por dois motivos: (1) URLs de distribuição oficial podem mudar; (2) o leitor deve sempre obter essas imagens diretamente dos canais oficiais — `microsoft.com` para o Windows 11 e o repositório oficial do projeto `virtio-win` para os drivers — nunca de espelhos de terceiros não verificados.

## Explicação

### Instalação da VM: interface gráfica vs XML manual

O Virt-Manager gera, para cada VM, uma definição em XML consumida pelo `libvirtd`. A interface gráfica cobre a maioria das opções necessárias; algumas configurações mais avançadas (caminho customizado de OVMF_VARS, ajuste fino do disco físico HD1 como passthrough — Capítulo 19, e CPU pinning — Capítulo 21) exigem edição direta do XML, feita através de:

```bash
virsh --connect qemu:///system edit <VM_NAME>
```

**O que faz:** abre o XML da VM `<VM_NAME>` no editor padrão (`$EDITOR`, ou `vi` por padrão) dentro de uma transação seguro — se o XML salvo contiver um erro de sintaxe, o `virsh` rejeita a alteração e mantém a definição anterior intacta, evitando corromper a configuração da VM.

### Passo a passo no Virt-Manager

Abra o Virt-Manager (pode ser localizado no menu de aplicativos do Pop!_OS, ou executado via `virt-manager` no terminal). Clique em **"Criar uma nova máquina virtual"** (ícone de tela com um "+").

**Passo 1 — Método de instalação:** selecione "Mídia de instalação local (ISO de imagem ou CDROM)" e aponte para o arquivo ISO do Windows 11 já baixado.

**Passo 2 — Escolher o SO:** o Virt-Manager tentará detectar automaticamente "Microsoft Windows 11". Confirme a detecção; se não detectar automaticamente, selecione manualmente "Microsoft Windows 11" na lista, o que ajusta automaticamente algumas otimizações padrão de compatibilidade.

**Passo 3 — Memória e CPU (valores iniciais; refinados no Capítulo 21):**
- Memória: **16384 MiB** (16 GB) como ponto de partida razoável para 32 GB totais de RAM do host, deixando margem confortável para o Linux. Este valor pode ser ajustado depois via XML ou pela própria interface (VM desligada).
- CPUs: **8 vCPUs** como ponto de partida (dos 8 núcleos físicos/16 threads do Ryzen 7 5700X) — o CPU pinning refinado do Capítulo 21 revisará essa alocação com cuidado para não competir com os núcleos usados pelo host.

> **💡 DICA:** Não marque "Copiar a configuração da CPU do host" apenas na tela simplificada deste assistente — a opção de CPU **host-passthrough** completa e correta é configurada explicitamente na aba de detalhes do hardware, explicada adiante, pois o assistente inicial às vezes usa um modo intermediário ("host-model") em vez do "host-passthrough" desejado.

**Passo 4 — Armazenamento:** desmarque a opção de criar um disco automaticamente neste assistente ("Habilitar armazenamento para esta máquina virtual" pode ser desmarcado, ou criado e posteriormente substituído). O disco QCOW2 customizado será criado explicitamente via linha de comando, detalhada a seguir, para ter controle total sobre localização (`/vm/`) e nome (`Windows11.qcow2`).

**Passo 5 — Nome e revisão final:** defina o nome `<VM_NAME>` (por exemplo, `win11`). **Marque a opção "Customizar configuração antes de instalar"** — essencial, pois é essa opção que abre a tela de detalhes de hardware, onde o restante das configurações avançadas (OVMF, TPM, VirtIO, disco customizado) é definido antes do primeiro boot da instalação.

### Criando o disco QCOW2 explicitamente

Antes de finalizar o assistente (ou logo após, na tela de customização, seção "Armazenamento" → "Adicionar Hardware" → "Armazenamento"), crie o arquivo de disco via linha de comando, para ter controle total do formato e localização:

```bash
sudo -u libvirt-qemu qemu-img create -f qcow2 /vm/Windows11.qcow2 250G
```

**O que faz:** `qemu-img create` cria um novo arquivo de imagem de disco virtual. `-f qcow2` define o formato **QCOW2** (QEMU Copy-On-Write versão 2) — formato nativo do QEMU que suporta **alocação dinâmica** (thin provisioning: o arquivo cresce fisicamente no disco físico conforme dados são escritos dentro da VM, em vez de reservar 250 GB de imediato), *snapshots* internos (Capítulo 25), e compressão opcional. O tamanho `250G` é a capacidade **nominal máxima** que o sistema de arquivos dentro da VM enxergará — não o espaço ocupado imediatamente no NVMe. Executar o comando como o usuário `libvirt-qemu` (via `sudo -u`) garante que o arquivo já nasça com o dono correto, evitando problemas de permissão explicados no Capítulo 14.

```bash
ls -lh /vm/Windows11.qcow2
qemu-img info /vm/Windows11.qcow2
```
**O que fazem:** o primeiro confirma que o arquivo existe e mostra seu tamanho **físico** atual no disco (deve ser pequeno, poucos KB/MB, pois a alocação é dinâmica e nada foi escrito ainda). O segundo mostra metadados detalhados do arquivo QCOW2, incluindo a capacidade **virtual** (`virtual size: 250 GiB`) — confirmando a diferença entre tamanho alocado e capacidade nominal, central ao conceito de disco dinâmico.

> **📝 NOTA:** Alocação **dinâmica** (usada aqui) vs **fixa** (`qemu-img create -f qcow2 -o preallocation=full ...`, que reserva os 250 GB integralmente de imediato): a alocação dinâmica economiza espaço em disco enquanto a VM não estiver cheia, ao custo de uma fragmentação ligeiramente maior no NVMe ao longo do tempo e uma pequena sobrecarga de desempenho na primeira escrita em cada bloco novo (que precisa ser alocado antes de escrito). Para um SSD NVMe moderno, essa sobrecarga é imperceptível na prática, e a economia de espaço (especialmente antes de a VM estar cheia de jogos, que residem majoritariamente em HD1, não no QCOW2) justifica plenamente a escolha de alocação dinâmica especificada para este projeto.

### Configurando o hardware na tela de customização

Na tela de "Customizar configuração antes de instalar", ajuste os seguintes itens antes de clicar em "Iniciar a instalação":

**Visão geral (Overview):**
- **Firmware:** selecione a entrada OVMF correspondente a **UEFI x86_64: /usr/share/OVMF/OVMF_CODE.fd** (ou variante com sufixo, dependendo da versão do pacote, geralmente há uma opção explicitamente rotulada "OVMF" na lista suspensa). Isso instrui o libvirt a usar o firmware UEFI virtual em vez do BIOS legado padrão do QEMU (SeaBIOS), requisito obrigatório para o Windows 11.
- **Chipset:** manter **Q35** (chipset moderno com suporte nativo a PCIe, essencial para passthrough de dispositivos PCIe — o chipset legado i440FX não oferece topologia PCIe adequada).

**CPUs:**
- Na aba "CPUs", altere o **Modelo de CPU** de "Aplicar as configurações padrão do host" (host-model) para **"Copiar a configuração da CPU do host" (host-passthrough)**. A diferença é explicada em detalhe no Capítulo 21; em resumo, host-passthrough expõe ao Windows o conjunto completo e exato de instruções e identificação do Ryzen 7 5700X físico, maximizando compatibilidade e desempenho, ao custo de tornar a VM menos portável para migração a hardware diferente (irrelevante neste ambiente de host único e fixo).

**Memória:** confirme o valor de RAM definido no assistente (ajustável nesta tela também).

**Disco (Storage):** remova qualquer disco criado automaticamente pelo assistente que não seja o `/vm/Windows11.qcow2` desejado. Adicione o disco correto: "Adicionar Hardware" → "Armazenamento" → "Selecionar ou criar armazenamento customizado" → apontar para `/vm/Windows11.qcow2` (já criado via `qemu-img` acima). Em "Tipo de dispositivo", selecione **Disco de VirtIO** e em "Formato de barramento", **VirtIO** — isso instrui o QEMU a expor o disco através do driver paravirtualizado de alto desempenho, em vez de emular um controlador IDE/SATA legado (o driver VirtIO precisa ser carregado manualmente durante a instalação do Windows, tratado no Capítulo 18, pois o instalador do Windows não o reconhece nativamente).

**CD-ROM da instalação:** confirme que a ISO do Windows 11 está anexada como um dispositivo de CD-ROM (IDE, não VirtIO — o firmware de boot da VM precisa reconhecer esse dispositivo antes de qualquer driver VirtIO estar carregado).

**Segundo CD-ROM (drivers VirtIO):** adicione um segundo dispositivo de armazenamento tipo CD-ROM, apontando para a ISO `virtio-win.iso`, necessária durante a instalação do Windows para carregar o driver de disco VirtIO (Capítulo 18).

**Rede (NIC):** na aba de rede, altere o "Modelo de dispositivo" para **virtio** (em vez do padrão emulado e2000/rtl8139), pelo mesmo motivo de desempenho do disco. Nesta etapa inicial use a rede NAT `default` do libvirt em qualquer escolha: ela é um bootstrap seguro para instalar/ativar o Windows. O Capítulo 23 preserva o MAC dessa NIC e troca apenas sua fonte, identificando-a pelo `VM_NIC_MAC`: Ethernet pode terminar em bridge ou NAT dedicado; Wi-Fi termina obrigatoriamente no NAT dedicado.

**TPM:**
- "Adicionar Hardware" → "TPM" → **Tipo: Emulado**, **Versão do modelo: 2.0**. Isso instrui o libvirt a orquestrar automaticamente uma instância `swtpm` dedicada a esta VM (um processo `swtpm` separado por VM, com seu estado armazenado em `/var/lib/libvirt/swtpm/<UUID_DA_VM>/`), satisfazendo o requisito de TPM 2.0 do instalador do Windows 11.

**Vídeo:** nesta fase (antes do passthrough dinâmico do Capítulo 19), configure o modelo de vídeo como **QXL** ou **VirtIO** (ambos adequados para a instalação inicial do Windows via console gráfico do Virt-Manager, antes de a GPU física ser envolvida) — este dispositivo de vídeo virtual será usado apenas durante a instalação e para acesso de emergência via console (Capítulo 28); a saída de vídeo real, de alto desempenho, virá exclusivamente da RTX 3060 em passthrough, adicionada no Capítulo 19.

**USB:** manter o controlador USB padrão (geralmente `qemu xhci`, USB 3.0) habilitado nesta fase, para uso do teclado/mouse virtualizados (Tablet/Mouse EvTouch) durante a instalação — o passthrough de dispositivos USB físicos específicos é tratado no Capítulo 20.

**Áudio:** manter o dispositivo de áudio padrão emulado (ICH9, ou similar) nesta fase, para o instalador do Windows; o áudio de alta fidelidade via HDMI da própria GPU passa a existir automaticamente assim que a GPU for adicionada em passthrough (Capítulo 19/20) — a função de áudio HDMI da GPU é, tecnicamente, apenas mais um dispositivo PCI dentro do mesmo grupo IOMMU, adicionado junto com a função de vídeo.

### Ajuste do perfil AppArmor para o caminho customizado `/vm`

Como mencionado no Capítulo 10, o caminho `/vm/Windows11.qcow2` não está entre os diretórios padrão que o perfil AppArmor do `libvirtd` permite por padrão em algumas configurações mais restritivas.

```bash
sudo nano /etc/apparmor.d/local/abstractions/libvirt-qemu
```

Adicione a linha:

```text
"/vm/** rwk,
```

**O que faz:** concede ao perfil AppArmor aplicado aos processos QEMU gerenciados pelo libvirt permissão de leitura, escrita e manutenção de lock (`rwk`) sobre qualquer caminho dentro de `/vm/`, incluindo o arquivo `Windows11.qcow2` e, futuramente, quaisquer snapshots ou arquivos auxiliares.

```bash
sudo systemctl reload apparmor
```
**O que faz:** recarrega os perfis do AppArmor sem reiniciar o sistema, aplicando a nova regra imediatamente.

> **📝 NOTA:** Em muitas instalações padrão do Pop!_OS, o pacote `libvirt-daemon-system` já configura o perfil AppArmor de forma dinâmica por VM (gerando um perfil específico em `/etc/apparmor.d/libvirt/libvirt-<UUID>.files` que já inclui automaticamente qualquer disco referenciado na definição XML da VM). Se ao iniciar a VM (próxima etapa) não houver erro de "Permission denied" relacionado a `/vm/Windows11.qcow2`, este ajuste manual de perfil pode não ser estritamente necessário — mas é seguro aplicá-lo preventivamente, e o Capítulo 28 (Troubleshooting) volta a este tópico caso um erro de AppArmor apareça.

## Comandos

```bash
sudo -u libvirt-qemu qemu-img create -f qcow2 /vm/Windows11.qcow2 250G
qemu-img info /vm/Windows11.qcow2
sudo nano /etc/apparmor.d/local/abstractions/libvirt-qemu   # adicionar "/vm/** rwk,
sudo systemctl reload apparmor
virt-manager   # prosseguir pelo assistente conforme descrito acima
```

## Arquivos modificados

- `/vm/Windows11.qcow2` (criado, disco virtual dinâmico de até 250 GB).
- `/etc/libvirt/qemu/<VM_NAME>.xml` (definição da VM, gerenciada pelo libvirt a partir das escolhas do Virt-Manager).
- `/etc/apparmor.d/local/abstractions/libvirt-qemu` (regra customizada adicionada).
- `/var/lib/libvirt/swtpm/<UUID_DA_VM>/` (estado do TPM emulado, criado ao iniciar a VM pela primeira vez).
- Cópia de `OVMF_VARS.fd` específica da VM, criada automaticamente pelo libvirt em `/var/lib/libvirt/qemu/nvram/<VM_NAME>_VARS.fd` (variáveis UEFI graváveis, separadas do firmware `OVMF_CODE.fd` somente leitura compartilhado entre todas as VMs).

## Como verificar

```bash
virsh --connect qemu:///system list --all
```
**Critério de sucesso:** a VM `<VM_NAME>` aparece na lista, com estado `shut off` (antes de iniciar) ou `running` (após iniciar a instalação).

```bash
virsh --connect qemu:///system dumpxml <VM_NAME> | grep -E "loader|nvram|qcow2|model type"
```
**Critério de sucesso:** confirma, na definição XML real da VM, a presença do caminho para `OVMF_CODE.fd` (`loader`), o `nvram` específico da VM, o caminho `/vm/Windows11.qcow2`, e `model type='q35'` no elemento de máquina.

```bash
qemu-img info /vm/Windows11.qcow2 | grep "virtual size"
```
**Critério de sucesso:** confirma `virtual size: 250 GiB`.

## Resultado esperado

Máquina virtual `<VM_NAME>` criada e definida no libvirt, com firmware OVMF (UEFI), chipset Q35, CPU em modo host-passthrough, disco `/vm/Windows11.qcow2` de 250 GB dinâmico em VirtIO, TPM 2.0 emulado, ISOs de instalação do Windows e dos drivers VirtIO anexadas, pronta para o primeiro boot de instalação (Capítulo 18).

## Como desfazer

```bash
virsh --connect qemu:///system destroy <VM_NAME> 2>/dev/null || true
virsh --connect qemu:///system undefine <VM_NAME> --nvram
sudo rm -f /vm/Windows11.qcow2
```

**O que fazem:** `destroy` força o desligamento imediato caso a VM esteja em execução (equivalente a desligar fisicamente, não um shutdown gracioso); `undefine --nvram` remove a definição da VM do libvirt **e** o arquivo de variáveis UEFI associado; o último comando remove o arquivo de disco em si.

> **⚠️ ALERTA:** `rm -f /vm/Windows11.qcow2` é irreversível e apaga todo o conteúdo da instalação do Windows feita até aquele momento, incluindo jogos eventualmente instalados no disco C:. Use com extrema cautela, e apenas com certeza de que este é o disco que deseja remover (confirme sempre com `ls -lh /vm/` antes).

## Problemas comuns

| Sintoma | Causa provável | Correção |
|---|---|---|
| Virt-Manager não lista "OVMF" como opção de firmware | Pacote `ovmf` não instalado (Capítulo 13 pulado) | `sudo apt install ovmf` |
| Erro "Permission denied" ao iniciar a VM, referenciando `/vm/Windows11.qcow2` | Permissão do diretório `/vm` incorreta (Capítulo 14) ou perfil AppArmor bloqueando | Revisar Capítulo 14; revisar a seção de AppArmor deste capítulo; consultar `sudo journalctl -xe` e `sudo aa-status` para identificar a negação específica |
| VM não inicia, erro relacionado a TPM/swtpm | Pacote `swtpm` não instalado, ou serviço `swtpm` incapaz de criar seu diretório de estado | Confirmar `swtpm-tools` instalado (Capítulo 13); verificar permissões de `/var/lib/libvirt/swtpm/` |
| `qemu-img create` executado sem `sudo -u libvirt-qemu` resulta em arquivo de dono incorreto | Comando executado como `<USUARIO_LINUX>` diretamente | Ajustar dono retroativamente: `sudo chown libvirt-qemu:libvirt-qemu /vm/Windows11.qcow2` |

## Próxima etapa

Capítulo 18 — Instalação do Windows 11 e Drivers VirtIO/NVIDIA.

---

# Capítulo 18 — Instalação do Windows 11 e Drivers VirtIO/NVIDIA

## Objetivo

Instalar o Windows 11 dentro da VM criada no Capítulo 17, carregando o driver de disco VirtIO durante a instalação, integrando o HD1 físico como segundo disco do sistema, e instalando os drivers VirtIO restantes e o driver NVIDIA **dentro da VM** após a conclusão da instalação base.

## Pré-requisitos

- Capítulo 17 concluído (VM definida, discos e ISOs anexados).
- HD1 identificado (Capítulo 3) e, se ainda não passado à VM, seu passthrough configurado (ver seção específica abaixo, complementada em detalhe pelo Capítulo 19).

## Explicação

### Por que o driver VirtIO precisa ser carregado manualmente

O instalador do Windows 11, em sua mídia oficial, não inclui nativamente drivers para o controlador de disco `virtio-blk` ou `virtio-scsi` — esses são drivers de terceiros (mantidos pelo projeto `virtio-win`, mas não assinados/distribuídos pela Microsoft dentro da imagem padrão do Windows). Por isso, ao apontar o instalador para o disco `/vm/Windows11.qcow2` (exposto como um disco VirtIO, Capítulo 17), a tela de particionamento do instalador do Windows **não encontrará nenhum disco disponível** até que o driver seja carregado manualmente a partir da segunda ISO anexada (`virtio-win.iso`).

### Passo a passo da instalação

1. Inicie a VM pelo Virt-Manager (botão de "play" com o ícone de VM selecionada). O console gráfico abre automaticamente, exibindo o boot da mídia do Windows 11 via firmware OVMF.
2. Na primeira tela do instalador do Windows ("Windows Setup"), selecione idioma, formato de hora/moeda e layout de teclado, e clique em "Avançar" → "Instalar agora".
3. Insira a chave de produto (ou selecione "Não tenho uma chave de produto" para prosseguir e ativar posteriormente).
4. Selecione a edição do Windows 11 desejada (Home/Pro).
5. Aceite os termos de licença.
6. Selecione "Personalizada: instalar somente o Windows (avançado)".
7. Na tela "Onde você deseja instalar o Windows?", a lista estará **vazia** (nenhum disco detectado) — este é o comportamento esperado, conforme explicado acima. Clique em **"Carregar driver"**.
8. Clique em "Procurar" e navegue até a unidade de CD-ROM correspondente à ISO `virtio-win.iso`, então para o caminho `viostor\w11\amd64\` (driver de armazenamento VirtIO para Windows 11, arquitetura amd64) — ou `vioscsi\w11\amd64\`, caso o barramento configurado no Capítulo 17 tenha sido `virtio-scsi` em vez de `virtio-blk` (confirme qual foi escolhido; ambos os drivers estão disponíveis na mesma ISO, em pastas separadas).
9. Selecione o driver listado (algo como "Red Hat VirtIO SCSI controller" ou "VirtIO SCSI pass-through controller") e clique em "Avançar" para instalá-lo.
10. O disco `/vm/Windows11.qcow2` (250 GB) agora aparece na lista. Selecione-o, clique em "Avançar", e a instalação prossegue normalmente (cópia de arquivos, reinicializações automáticas).

> **💡 DICA:** Repita a busca de driver para a pasta `NetKVM\w11\amd64\` (driver de rede VirtIO) se a tela de instalação solicitar conectividade de rede durante o processo (comum em versões mais recentes do Windows 11 que exigem conta Microsoft/internet). Caso contrário, esse driver pode ser instalado normalmente após a conclusão da instalação base, junto aos demais.

11. Após a instalação base e o primeiro boot completo do Windows (chegando à área de trabalho), prossiga com a instalação completa dos drivers VirtIO restantes, descrita a seguir.

### Instalando o pacote completo de drivers VirtIO (pós-instalação)

Dentro do Windows já instalado, com a ISO `virtio-win.iso` ainda anexada como unidade de CD-ROM (reanexe pelo Virt-Manager, se necessário: "Detalhes da VM" → dispositivo de CD-ROM → "Conectar" → selecionar o arquivo ISO):

1. Abra o Explorador de Arquivos e navegue até a unidade correspondente ao CD-ROM do `virtio-win.iso`.
2. Execute o instalador gráfico `virtio-win-guest-tools.exe` (presente na raiz da ISO), que instala automaticamente todos os drivers restantes (rede, balão de memória, `qemu-guest-agent`, dispositivos seriais) em um único assistente.
3. Reinicie a VM quando solicitado.

**O que o `qemu-guest-agent` (instalado por esse pacote) faz:** um serviço em segundo plano dentro do Windows que se comunica com o `libvirtd` no host via um canal virtual serial (`virtio-serial`), permitindo operações como desligamento gracioso da VM a partir do host (`virsh --connect qemu:///system shutdown`), sincronização de horário, congelamento de sistema de arquivos para snapshots consistentes (Capítulo 25), e relatório de endereço IP da VM ao host — recursos usados em capítulos posteriores.

### Configurações recomendadas dentro do Windows (pós-instalação)

Dois ajustes do convidado fazem parte do desenho de segurança e manutenção deste ambiente e devem ser aplicados logo após a instalação base:

**Antivírus — o Windows Defender é suficiente.** Mantenha a **proteção em tempo real ativa**. Não instale EDR/antivírus de terceiros (desnecessário neste desenho), não desative a proteção em busca de FPS (o impacto de desempenho atual é desprezível) e não crie exclusões amplas de pasta — em particular, **nunca exclua a pasta de trânsito `airlock`** (Capítulo 24) da verificação: ela é justamente a única checagem de malware que os arquivos em trânsito entre Linux e Windows recebem.

**Desativar a Inicialização Rápida (Fast Startup).** Painel de Controle → Opções de Energia → "Escolher a função dos botões de energia" → "Alterar configurações não disponíveis no momento" → desmarcar **"Ligar inicialização rápida"** → Salvar alterações. Com a Inicialização Rápida ativa, "Desligar" executa uma hibernação parcial do sistema e pode deixar os volumes NTFS marcados como em uso ("sujos"), o que impede a montagem somente leitura de emergência do HD1 no host (Capítulo 24) e prejudica a consistência de snapshots e backups (Capítulo 25).

### Configuração do HD1 como disco físico dentro da VM

Conforme decidido no Capítulo 2, HD1 é passado à VM como **disco físico completo**, não como uma pasta compartilhada. A configuração detalhada desse passthrough — incluindo a obtenção do caminho estável `<HD1_BY_ID_PATH>` e a edição do XML da VM — é tratada em profundidade no **Capítulo 19**, junto com o passthrough dinâmico da GPU, pois ambos os procedimentos envolvem edição do XML da VM de forma correlata. Ao chegar a essa etapa (após concluir a instalação base do Windows e dos drivers VirtIO descrita neste capítulo), retorne aqui apenas para a etapa de particionamento do HD1 **dentro** do Windows, descrita a seguir.

Uma vez que o HD1 esteja anexado ao XML da VM (Capítulo 19) e a VM seja reiniciada, o disco aparecerá dentro do Windows como um disco físico não inicializado (idêntico ao que apareceria em um PC físico com um HD adicional recém-instalado):

1. Abra o "Gerenciamento de Disco" do Windows (clique direito no menu Iniciar → "Gerenciamento de Disco").
2. Se HD1 já contiver uma tabela de partição NTFS válida de uso anterior, ele aparecerá com sua letra de unidade automaticamente ou como "Online" — **não formate** neste caso; os dados existentes (Steam, Epic, Battle.net, jogos, downloads) já estarão acessíveis.
3. Se HD1 estiver realmente em branco (disco novo, sem partição), o Windows solicitará a inicialização do disco (escolher **GPT**, não MBR, por compatibilidade com UEFI) e, em seguida, será necessário criar um novo volume simples, formatado em **NTFS**, com uma letra de unidade à sua escolha (por exemplo, `D:`).

> **⚠️ ALERTA:** Se HD1 já continha dados de uma instalação Windows anterior que se deseja preservar, tenha certeza absoluta antes de aceitar qualquer prompt de inicialização/formatação do Gerenciamento de Disco — esses prompts são irreversíveis e apagam a tabela de partição existente.

### Instalando o driver NVIDIA dentro da VM

Com a GPU ainda **não** anexada à VM neste ponto do documento (isso ocorre no Capítulo 19), o Windows, ao ser instalado, usa apenas o adaptador de vídeo virtual QXL/VirtIO configurado no Capítulo 17 — suficiente para navegar o sistema, mas sem aceleração 3D real.

A instalação do driver NVIDIA dentro da VM deve ser feita **depois** que a GPU já estiver em passthrough (Capítulo 19), pois só nesse momento o Windows Gerenciador de Dispositivos detectará a RTX 3060 como hardware real. O procedimento, deixado registrado aqui para referência, é:

1. Dentro da VM (após o Capítulo 19), baixar o instalador mais recente do driver GeForce diretamente do site oficial da NVIDIA (`nvidia.com/drivers`), selecionando o modelo RTX 3060.
2. Executar o instalador, escolhendo a opção de instalação "Limpa" (Clean Install), que remove quaisquer resíduos de drivers genéricos anteriores.
3. Reiniciar a VM quando solicitado.

> **📝 NOTA:** Este documento não fornece link direto do instalador NVIDIA, seguindo o mesmo princípio já explicado: sempre obtenha diretamente do site oficial do fabricante.

## Comandos

A instalação em si é feita majoritariamente pela interface gráfica de instalação do Windows e do console do Virt-Manager, sem comandos de terminal Linux nesta etapa — exceto pela verificação de estado da VM:

```bash
virsh --connect qemu:///system list --all
virsh --connect qemu:///system domstate <VM_NAME>
```

## Arquivos modificados

- `/vm/Windows11.qcow2` (populado com a instalação completa do Windows 11).
- HD1 (tabela de partição GPT criada, se o disco estava em branco; ou preservada, se já continha dados).
- `/etc/libvirt/qemu/<VM_NAME>.xml` (dispositivo de CD-ROM da ISO do Windows pode ser removido/desanexado após a instalação, opcionalmente, via Virt-Manager).

## Como verificar

Dentro da VM Windows:

```powershell
Get-Disk
```
**O que faz (PowerShell dentro do Windows):** lista todos os discos reconhecidos pelo Windows. **Critério de sucesso:** deve listar dois discos — o disco de sistema (250 GB, correspondente ao `Windows11.qcow2`) e o HD1 físico (com o tamanho real do disco físico usado, uma vez anexado conforme Capítulo 19).

```powershell
Get-Service vioserial, QEMU-GA
```
**Critério de sucesso:** confirma que os serviços relacionados ao VirtIO e ao `qemu-guest-agent` estão em execução (`Running`), após a instalação do pacote `virtio-win-guest-tools.exe`.

No host:

```bash
virsh --connect qemu:///system qemu-agent-command <VM_NAME> '{"execute":"guest-ping"}'
```
**O que faz:** envia um comando de "ping" ao `qemu-guest-agent` rodando dentro da VM através do canal serial virtual. **Critério de sucesso:** retorna `{"return":{}}`, confirmando comunicação bidirecional funcional entre host e guest — pré-requisito para o desligamento gracioso e snapshots consistentes usados em capítulos posteriores.

## Resultado esperado

Windows 11 totalmente instalado e funcional dentro da VM, com todos os drivers VirtIO (disco, rede, balão de memória, guest agent) instalados, HD1 reconhecido e acessível (com dados preservados, se aplicável), e o sistema pronto para receber o driver NVIDIA assim que a GPU for anexada em passthrough no próximo capítulo.

## Como desfazer

Para refazer a instalação do zero, mantendo a definição da VM e apenas recriando o disco de sistema:

```bash
virsh --connect qemu:///system destroy <VM_NAME>
sudo -u libvirt-qemu rm /vm/Windows11.qcow2
sudo -u libvirt-qemu qemu-img create -f qcow2 /vm/Windows11.qcow2 250G
virsh --connect qemu:///system start <VM_NAME>
```

> **⚠️ ALERTA:** Este procedimento apaga toda a instalação do Windows feita no disco de sistema. HD1 (disco físico separado) **não** é afetado por este procedimento, desde que os comandos acima não referenciem HD1 em nenhum momento.

## Problemas comuns

| Sintoma | Causa provável | Correção |
|---|---|---|
| Instalador do Windows não lista nenhum disco, mesmo após carregar o driver VirtIO | Driver incompatível carregado (ex.: `viostor` quando o disco foi configurado como `virtio-scsi`, ou vice-versa) | Repetir a etapa de "Carregar driver" apontando para a pasta correta (`viostor` vs `vioscsi`) correspondente ao barramento efetivamente configurado no Capítulo 17 |
| Tela azul (BSOD) logo após a instalação, antes de qualquer driver adicional | Incompatibilidade rara entre firmware/CPU virtual e alguma feature específica | Revisar Capítulo 28 (Troubleshooting), seção de BSOD na instalação |
| `qemu-agent-command` retorna erro "QEMU guest agent is not connected" | `virtio-win-guest-tools.exe` não instalado, ou serviço `QEMU-GA` parado dentro da VM | Reinstalar o pacote de guest tools; verificar `Get-Service QEMU-GA` dentro da VM |
| HD1 aparece como "Não alocado" mesmo tendo dados anteriores | HD1 ainda não foi corretamente anexado como disco físico (etapa pendente do Capítulo 19), e o que aparece é outro disco | Confirmar, antes de qualquer ação no Gerenciamento de Disco, que o disco correto está selecionado, comparando tamanho/capacidade com o valor esperado do HD1 |

## Próxima etapa

Capítulo 19 — GPU Passthrough Dinâmico (Hook Scripts) e HD1 Físico, onde a GPU e o HD1 são efetivamente anexados à VM.

---

# Capítulo 19 — GPU Passthrough Dinâmico (Hook Scripts) e HD1 Físico

## Objetivo

Implementar o mecanismo de hook scripts do libvirt que vincula dinamicamente a RTX 3060 ao driver `vfio-pci` no início da VM e a devolve ao driver `nvidia`/Linux ao término, e anexar HD1 à VM como disco físico completo via caminho estável.

## Pré-requisitos

- Capítulo 16 concluído (IOMMU habilitado, IDs PCI e grupo IOMMU da GPU documentados).
- Capítulo 17 e 18 concluídos (VM criada e Windows instalado).
- `<GPU_PCI_ID>`, `<GPU_AUDIO_PCI_ID>`, `<GPU_VENDOR_DEVICE_ID>` e `<GPU_AUDIO_VENDOR_DEVICE_ID>` documentados (Capítulo 16).

## Explicação

### Por que hook scripts, e não vinculação estática

Como fundamentado nos Capítulos 1 e 16, este é um ambiente de **GPU única**. A GPU precisa alternar dinamicamente entre dois estados:

```text
Estado "repouso" (VM desligada)         Estado "passthrough" (VM ligada)
────────────────────────────────         ─────────────────────────────────
Driver: nvidia                            Driver: vfio-pci
Uso: desktop Linux normal                 Uso: exclusivo da VM Windows
Saída de vídeo: monitor via Linux         Saída de vídeo: monitor via Windows
```

Os **hook scripts do libvirt** são a ferramenta correta para essa transição, pois o `libvirtd` os invoca automaticamente, de forma síncrona, em pontos precisos do ciclo de vida da VM — antes de o QEMU sequer tentar abrir o dispositivo PCI da GPU (evento `prepare/begin`) e depois de o QEMU já ter liberado completamente o dispositivo (evento `release/end`).

```text
┌──────────────────────────────────────────────────────────────────┐
│  virsh --connect qemu:///system start <VM_NAME>                  │
│         │                                                          │
│         ▼                                                          │
│  Hook "prepare/begin"  →  para display manager, unbind nvidia,      │
│                            bind vfio-pci                            │
│         │                                                          │
│         ▼                                                          │
│  QEMU inicia, assume a GPU via VFIO, Windows usa a RTX 3060 nativa  │
│         │                                                          │
│         ▼  (usuário desliga o Windows dentro da VM, ou           │
│             virsh --connect qemu:///system shutdown/destroy)     │
│         ▼                                                          │
│  Hook "release/end"    →  unbind vfio-pci, bind nvidia,             │
│                            reiniciar display manager                │
│         │                                                          │
│         ▼                                                          │
│  Linux recupera a GPU e o vídeo volta ao desktop normal              │
└──────────────────────────────────────────────────────────────────┘
```

### Estrutura de diretórios de hook scripts do libvirt

O libvirt procura, para cada tipo de objeto gerenciado, um script executável em `/etc/libvirt/hooks/<objeto>` (por exemplo, `/etc/libvirt/hooks/qemu` para hooks relacionados a VMs QEMU). Esse script único recebe como argumentos o nome da VM, o nome do evento (`prepare`, `started`, `stopped`, `release`) e o sub-evento (`begin`/`end`), e é responsável por decidir internamente o que fazer com base nesses argumentos — tipicamente delegando para scripts específicos por VM e por evento, organizados em subdiretórios, prática adotada por este documento para manter a lógica organizada e legível.

```bash
sudo mkdir -p /etc/libvirt/hooks
sudo mkdir -p /etc/libvirt/hooks/qemu.d/<VM_NAME>/prepare/begin
sudo mkdir -p /etc/libvirt/hooks/qemu.d/<VM_NAME>/release/end
```
**O que fazem:** criam a estrutura de diretórios onde os scripts específicos desta VM residirão, separados por evento (`prepare/begin` executa antes de a VM iniciar; `release/end` executa depois que a VM já foi completamente finalizada e todos os seus recursos liberados pelo QEMU).

### O script dispatcher principal

```bash
sudo nano /etc/libvirt/hooks/qemu
```

```bash
#!/bin/bash
# /etc/libvirt/hooks/qemu
# Dispatcher principal de hooks do libvirt para objetos QEMU.
# Argumentos recebidos automaticamente pelo libvirtd:
#   $1 = nome da VM
#   $2 = nome do evento    (prepare, start, started, stopped, release)
#   $3 = sub-evento        (begin, end)
#   $4 = argumento extra (não utilizado aqui)

VM_NAME="$1"
EVENTO="$2"
SUBEVENTO="$3"

DIRETORIO_HOOK="/etc/libvirt/hooks/qemu.d/${VM_NAME}/${EVENTO}/${SUBEVENTO}"

# Se existir um diretório de scripts para esta combinação exata de
# VM + evento + sub-evento, executa todos os scripts executáveis
# encontrados nele, em ordem alfabética.
if [ -d "$DIRETORIO_HOOK" ]; then
    for script in "$DIRETORIO_HOOK"/*; do
        [ -x "$script" ] && "$script" "$VM_NAME" "$EVENTO" "$SUBEVENTO"
    done
fi

exit 0
```

```bash
sudo chmod +x /etc/libvirt/hooks/qemu
```
**O que faz:** torna o dispatcher executável — condição obrigatória para que o `libvirtd` sequer o invoque (o libvirt verifica a permissão de execução antes de chamar o hook).

### Script de `prepare/begin` — capturando a GPU para a VM

```bash
sudo nano /etc/libvirt/hooks/qemu.d/<VM_NAME>/prepare/begin/01-gpu-para-vfio.sh
```

```bash
#!/bin/bash
# 01-gpu-para-vfio.sh
# Executado pelo libvirtd ANTES de o QEMU iniciar a VM.
# Objetivo: liberar a GPU do driver "nvidia" e vinculá-la ao "vfio-pci".

set -e   # interrompe o script imediatamente se qualquer comando falhar

GPU_PCI="0000:<GPU_PCI_ID_SEM_PREFIXO>"          # ex.: 0000:0c:00.0
GPU_AUDIO_PCI="0000:<GPU_AUDIO_PCI_ID_SEM_PREFIXO>"  # ex.: 0000:0c:00.1
GPU_IDS="<GPU_VENDOR_DEVICE_ID>,<GPU_AUDIO_VENDOR_DEVICE_ID>"  # ex.: 10de:2504,10de:228e

echo "[hook] Parando o gerenciador de exibição (gdm3)..."
systemctl stop gdm3

echo "[hook] Aguardando liberação de sessões gráficas..."
sleep 2

echo "[hook] Descarregando módulos do driver NVIDIA..."
modprobe -r nvidia_uvm  || true
modprobe -r nvidia_drm  || true
modprobe -r nvidia_modeset || true
modprobe -r nvidia      || true

echo "[hook] Vinculando GPU (${GPU_PCI}) e áudio (${GPU_AUDIO_PCI}) ao vfio-pci..."
for dispositivo in "$GPU_PCI" "$GPU_AUDIO_PCI"; do
    if [ -e "/sys/bus/pci/devices/${dispositivo}/driver" ]; then
        echo "$dispositivo" > "/sys/bus/pci/devices/${dispositivo}/driver/unbind" || true
    fi
done

echo "$GPU_IDS" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || true

for dispositivo in "$GPU_PCI" "$GPU_AUDIO_PCI"; do
    echo "$dispositivo" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true
done

echo "[hook] GPU vinculada ao vfio-pci com sucesso."
```

**Explicação linha a linha das partes não triviais:**

- `set -e`: garante que, se qualquer comando falhar (por exemplo, `modprobe -r nvidia` falhar porque o módulo ainda está em uso por outro processo), o script pare imediatamente em vez de prosseguir para o `bind` com um estado inconsistente — embora a maioria dos comandos individuais use `|| true` para tolerar condições já esperadas (módulo já descarregado, dispositivo já desvinculado), mantendo o script resiliente a reexecuções.
- `systemctl stop gdm3`: para o gerenciador de exibição gráfico do Pop!_OS (GNOME Display Manager). Isso é necessário porque o driver `nvidia` não pode ser descarregado (`modprobe -r`) enquanto algum processo mantém um framebuffer ou contexto gráfico aberto sobre a GPU — o GDM, junto com toda a sessão GNOME, mantém exatamente esse tipo de referência.
- A sequência de `modprobe -r` respeita a ordem de dependência entre os módulos do driver NVIDIA: `nvidia_uvm` (Unified Memory) e `nvidia_drm`/`nvidia_modeset` dependem do módulo base `nvidia`, e por isso devem ser descarregados **antes** dele.
- `echo "$dispositivo" > .../driver/unbind`: instrui o kernel a desvincular o driver atualmente associado (`nvidia`) daquele endereço PCI específico — mecanismo padrão de sysfs para controle manual de driver por dispositivo.
- `echo "$GPU_IDS" > /sys/bus/pci/drivers/vfio-pci/new_id`: registra os pares vendor:device no driver `vfio-pci`, instruindo-o a se declarar capaz de gerenciar dispositivos com esses IDs — este passo é necessário mesmo com o `bind` explícito seguinte, pois alguns kernels exigem que o ID já esteja "conhecido" pelo driver antes do bind manual funcionar de forma confiável.
- `echo "$dispositivo" > /sys/bus/pci/drivers/vfio-pci/bind`: efetivamente associa o dispositivo ao driver `vfio-pci`, tornando-o disponível como um nó `/dev/vfio/<grupo>` que o QEMU, iniciado logo em seguida pelo próprio `libvirtd`, poderá abrir.

> **⚠️ ALERTA:** Substitua **todos** os placeholders (`<GPU_PCI_ID_SEM_PREFIXO>`, `<GPU_AUDIO_PCI_ID_SEM_PREFIXO>`, `<GPU_VENDOR_DEVICE_ID>`, `<GPU_AUDIO_VENDOR_DEVICE_ID>`) pelos valores reais documentados no Capítulo 16 antes de usar este script. Um ID incorreto pode desvincular um dispositivo PCI errado do sistema (por exemplo, uma controladora de armazenamento), potencialmente travando o host.

### Script de `release/end` — devolvendo a GPU ao Linux

```bash
sudo nano /etc/libvirt/hooks/qemu.d/<VM_NAME>/release/end/01-gpu-para-linux.sh
```

```bash
#!/bin/bash
# 01-gpu-para-linux.sh
# Executado pelo libvirtd DEPOIS que a VM foi completamente finalizada
# e o QEMU já liberou todos os seus recursos, incluindo a GPU.
# Objetivo: devolver a GPU ao driver "nvidia" e restaurar o desktop Linux.

set -e

GPU_PCI="0000:<GPU_PCI_ID_SEM_PREFIXO>"
GPU_AUDIO_PCI="0000:<GPU_AUDIO_PCI_ID_SEM_PREFIXO>"

echo "[hook] Desvinculando GPU do vfio-pci..."
for dispositivo in "$GPU_PCI" "$GPU_AUDIO_PCI"; do
    if [ -e "/sys/bus/pci/devices/${dispositivo}/driver" ]; then
        echo "$dispositivo" > "/sys/bus/pci/devices/${dispositivo}/driver/unbind" || true
    fi
done

echo "[hook] Recarregando o driver NVIDIA..."
modprobe nvidia
modprobe nvidia_modeset
modprobe nvidia_drm
modprobe nvidia_uvm

echo "[hook] Reiniciando o gerenciador de exibição (gdm3)..."
systemctl start gdm3

echo "[hook] GPU devolvida ao Linux com sucesso."
```

**Explicação:** o processo é o inverso exato do script de `prepare/begin` — desvincula do `vfio-pci`, recarrega os módulos NVIDIA na ordem correta de dependência (base primeiro, depois os módulos dependentes), e reinicia o `gdm3`, que automaticamente reabre uma sessão gráfica na GPU agora disponível.

```bash
sudo chmod +x /etc/libvirt/hooks/qemu.d/<VM_NAME>/prepare/begin/01-gpu-para-vfio.sh
sudo chmod +x /etc/libvirt/hooks/qemu.d/<VM_NAME>/release/end/01-gpu-para-linux.sh
```
**O que fazem:** tornam ambos os scripts executáveis — sem essa permissão, o dispatcher principal (que verifica `-x` antes de invocar) os ignora silenciosamente.

> **📝 NOTA:** O dispatcher executa **todos** os scripts executáveis do diretório do evento, em ordem alfabética — este é o mecanismo de extensão usado pelo restante do documento. O Capítulo 24 adiciona, neste mesmo diretório `prepare/begin`, o script `00-airlock.sh` (prefixo `00-`, portanto executado **antes** do `01-gpu-para-vfio.sh`), sem nenhuma alteração nos scripts deste capítulo. Mantenha os scripts de hook com dono `root:root`: eles são executados como root pelo `libvirtd`, e um script de hook gravável por usuário comum seria um vetor de escalação de privilégio.

> **⚠️ ALERTA:** Existe uma janela de tempo em que o Linux fica **sem** interface gráfica: entre o início do hook `prepare/begin` (que para o `gdm3`) e o momento em que a VM efetivamente assume a saída de vídeo. Durante essa janela — tipicamente poucos segundos — o monitor pode mostrar tela preta ou "sem sinal". Isso é esperado.

> **🛑 PONTO DE NÃO RETORNO:** Se o script de `release/end` falhar por qualquer motivo (por exemplo, o módulo `nvidia` não recarregar por um erro inesperado), o Linux pode ficar sem `gdm3` ativo e sem GPU utilizável pelo driver `nvidia`. O Capítulo 28 (Troubleshooting) e o Capítulo 29 (Recuperação de Emergência) descrevem os procedimentos de recuperação para esse cenário específico, incluindo acesso via TTY texto (`Ctrl+Alt+F3`) para diagnóstico e correção manual sem depender da interface gráfica.

### Anexando o dispositivo VFIO da GPU ao XML da VM

Com os hook scripts prontos, a VM ainda precisa ser instruída, em sua definição XML, a *usar* o dispositivo VFIO da GPU quando ele estiver disponível (o hook script apenas prepara o dispositivo no host; a definição da VM é o que diz ao QEMU para efetivamente anexá-lo).

```bash
virsh --connect qemu:///system edit <VM_NAME>
```

Dentro da seção `<devices>`, adicione dois blocos `<hostdev>` — um para a função de vídeo, outro para a função de áudio da GPU:

```xml
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x0000' bus='0x0c' slot='0x00' function='0x0'/>
  </source>
</hostdev>
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x0000' bus='0x0c' slot='0x00' function='0x1'/>
  </source>
</hostdev>
```

**Explicação campo a campo:** os valores `bus`, `slot` e `function` correspondem, em formato hexadecimal com prefixo `0x`, ao endereço PCI `<GPU_PCI_ID>` (ex.: `0000:0c:00.0` se decompõe em `domain=0x0000`, `bus=0x0c`, `slot=0x00`, `function=0x0`) e `<GPU_AUDIO_PCI_ID>` (mesma decomposição, com `function=0x1`). O atributo `managed='yes'` instrui o próprio libvirt a cuidar de desvincular/vincular o driver do dispositivo automaticamente ao iniciar/parar a VM — na prática, coexistindo com os hook scripts deste capítulo, que assumem parte adicional dessa responsabilidade (o desligamento do `gdm3`/driver `nvidia`, que o `managed='yes'` sozinho não cobre).

> **⚠️ ALERTA:** Substitua os valores de `bus`, `slot`, `function` pelos correspondentes exatos ao `<GPU_PCI_ID>` e `<GPU_AUDIO_PCI_ID>` do seu sistema, documentados no Capítulo 16. O exemplo acima usa `bus='0x0c'` apenas como ilustração de formato.

Remova (ou desabilite) o dispositivo de vídeo virtual QXL/VirtIO configurado no Capítulo 17, ou mantenha-o como uma segunda saída secundária — este documento recomenda **remover** o dispositivo de vídeo virtual assim que o passthrough da GPU estiver validado, evitando confusão sobre qual saída de vídeo está ativa, mas mantê-lo durante os primeiros testes é aceitável como rede de segurança (permite acessar o console via Virt-Manager caso a saída física HDMI/DisplayPort da GPU passthrough apresente problema).

### Anexando o HD1 físico ao XML da VM

Primeiro, identifique o caminho estável do HD1:

```bash
ls -la /dev/disk/by-id/ | grep -v -i "nvme\|part"
```

**O que faz:** lista os links simbólicos estáveis em `/dev/disk/by-id/`, que referenciam discos por modelo+serial (não por `/dev/sdX`, que pode mudar). Filtra visualmente entradas relacionadas ao NVMe e a partições individuais, deixando mais evidentes as entradas de disco inteiro correspondentes a HD1. Compare o modelo/serial exibido com o inventário do Capítulo 3 para confirmar com certeza qual link corresponde ao HD1 — este caminho completo é o `<HD1_BY_ID_PATH>`.

Adicione ao XML da VM, dentro de `<devices>`:

```xml
<disk type='block' device='disk'>
  <driver name='qemu' type='raw' cache='none'/>
  <source dev='/dev/disk/by-id/<HD1_BY_ID_PATH>'/>
  <target dev='vdb' bus='virtio'/>
</disk>
```

**Explicação campo a campo:**

- `type='block'` e `device='disk'`: informa ao QEMU que a fonte é um dispositivo de bloco físico completo, não um arquivo de imagem.
- `driver name='qemu' type='raw'`: `raw` porque um disco físico não possui "formato" de arquivo de imagem (diferente do `qcow2` do disco de sistema) — o QEMU simplesmente repassa os blocos brutos do disco.
- `cache='none'`: desabilita o cache de página do host para este disco, garantindo que escritas feitas pela VM sejam realmente persistidas no disco físico de forma consistente (importante porque este disco tem dados "reais" de jogos/aplicativos que devem sobreviver a qualquer falha do host, e evita duplicação de cache entre o cache de página do Linux e o cache interno do próprio disco).
- `source dev='/dev/disk/by-id/<HD1_BY_ID_PATH>'`: aponta para o caminho estável identificado acima — **nunca** usar `/dev/sdX` diretamente aqui, pelo motivo já explicado no Capítulo 5 (nomes não estáveis entre boots).
- `target dev='vdb' bus='virtio'`: expõe o disco à VM como um dispositivo VirtIO (`vdb`, o segundo disco virtio depois do `vda` do sistema), aproveitando o mesmo driver de alto desempenho já instalado no Capítulo 18.

> **⚠️ ALERTA:** Confirme três vezes que `<HD1_BY_ID_PATH>` corresponde exatamente ao HD1 e não, por engano, ao NVMe do próprio host ou ao HD2. Um erro aqui pode resultar na VM obtendo acesso de escrita bruta a um disco que não deveria — no pior caso, corrompendo o sistema de arquivos do próprio Pop!_OS ou os dados do HD2.

> **🛑 PONTO DE NÃO RETORNO:** Nunca monte HD1 simultaneamente no host **e** dentro da VM. Como reforçado no Capítulo 2, HD1 é de uso exclusivo da VM. Se for necessário acessá-lo pelo lado Linux em algum momento excepcional (procedimento seguro no Capítulo 24), a VM deve estar completamente desligada antes de qualquer tentativa de montagem manual no host, e a montagem deve ser desfeita antes de a VM ser religada.

## Comandos

Resumo sequencial deste capítulo:

```bash
sudo mkdir -p /etc/libvirt/hooks/qemu.d/<VM_NAME>/prepare/begin
sudo mkdir -p /etc/libvirt/hooks/qemu.d/<VM_NAME>/release/end
sudo nano /etc/libvirt/hooks/qemu                                    # dispatcher
sudo nano /etc/libvirt/hooks/qemu.d/<VM_NAME>/prepare/begin/01-gpu-para-vfio.sh
sudo nano /etc/libvirt/hooks/qemu.d/<VM_NAME>/release/end/01-gpu-para-linux.sh
sudo chmod +x /etc/libvirt/hooks/qemu
sudo chmod +x /etc/libvirt/hooks/qemu.d/<VM_NAME>/prepare/begin/01-gpu-para-vfio.sh
sudo chmod +x /etc/libvirt/hooks/qemu.d/<VM_NAME>/release/end/01-gpu-para-linux.sh
ls -la /dev/disk/by-id/ | grep -v -i "nvme\|part"
virsh --connect qemu:///system edit <VM_NAME>   # adicionar <hostdev> (GPU) e <disk> (HD1)
```

## Arquivos modificados

- `/etc/libvirt/hooks/qemu` (dispatcher criado).
- `/etc/libvirt/hooks/qemu.d/<VM_NAME>/prepare/begin/01-gpu-para-vfio.sh` (criado).
- `/etc/libvirt/hooks/qemu.d/<VM_NAME>/release/end/01-gpu-para-linux.sh` (criado).
- `/etc/libvirt/qemu/<VM_NAME>.xml` (adicionados blocos `<hostdev>` para GPU e `<disk>` para HD1).

## Como verificar

Antes de iniciar a VM, valide a sintaxe XML:

```bash
virsh --connect qemu:///system dumpxml <VM_NAME> | xmllint --noout -
```
**Critério de sucesso:** nenhuma saída de erro (XML bem formado).

Inicie a VM e observe o comportamento:

```bash
virsh --connect qemu:///system start <VM_NAME>
```

**Critério de sucesso:** o monitor conectado à GPU deve, em poucos segundos, mudar do desktop Linux para tela preta e então para o logotipo de boot do Windows (via OVMF), confirmando que a GPU foi assumida pela VM.

Após desligar a VM (dentro do Windows, "Desligar"), aguarde e observe:

```bash
watch virsh --connect qemu:///system domstate <VM_NAME>
```
**Critério de sucesso:** o estado muda para `shut off`, e o monitor deve retornar ao desktop Linux automaticamente em seguida (hook `release/end` executado).

Confirme os logs dos hooks:

```bash
sudo journalctl -u libvirtd -e | grep -i hook
```

## Resultado esperado

GPU vinculada dinamicamente ao `vfio-pci` sempre que a VM inicia, e devolvida automaticamente ao driver `nvidia`/Linux sempre que a VM é desligada, sem intervenção manual; HD1 anexado como disco físico completo à VM, visível dentro do Windows com seus dados preservados.

## Como desfazer

```bash
sudo rm -rf /etc/libvirt/hooks/qemu.d/<VM_NAME>
sudo rm -f /etc/libvirt/hooks/qemu
virsh --connect qemu:///system edit <VM_NAME>   # remover blocos <hostdev> e <disk> do HD1
```

Em caso de a GPU ficar presa ao `vfio-pci` após um desligamento anormal (script de release não executado):

```bash
sudo /etc/libvirt/hooks/qemu.d/<VM_NAME>/release/end/01-gpu-para-linux.sh
```
**O que faz:** executa manualmente o script de devolução da GPU, útil como recuperação imediata sem precisar reiniciar o host inteiro (ver também Capítulo 29).

## Problemas comuns

| Sintoma | Causa provável | Correção |
|---|---|---|
| VM não inicia, erro "Device or resource busy" relacionado à GPU | GPU ainda vinculada ao driver `nvidia` (hook `prepare/begin` falhou silenciosamente) | Executar manualmente cada linha do script `01-gpu-para-vfio.sh` para identificar onde falhou; verificar `sudo journalctl -u libvirtd -e` |
| Após desligar a VM, Linux não recupera vídeo | Hook `release/end` não foi executado (VM finalizada de forma abrupta, ex.: `virsh --connect qemu:///system destroy` em vez de desligamento gracioso) | Executar manualmente o script de release (comando acima); acessar via TTY texto (`Ctrl+Alt+F3`) se a interface gráfica não responder |
| HD1 aparece vazio/sem dados dentro do Windows | `<HD1_BY_ID_PATH>` incorreto, apontando para outro disco | Reconferir `ls -la /dev/disk/by-id/` comparando modelo/serial com o inventário do Capítulo 3 |
| GPU não reaparece para o `nvidia` mesmo após o script de release, exigindo reboot do host | Estado de hardware da GPU não resetado corretamente por function-level reset (FLR) — problema conhecido em algumas combinações de placa-mãe/GPU | Ver Capítulo 28, seção específica sobre "reset bug" de GPUs NVIDIA em passthrough |

## Próxima etapa

Capítulo 20 — Áudio HDMI e USB Passthrough.

---

# Capítulo 20 — Áudio HDMI e USB Passthrough

## Objetivo

Confirmar e ajustar o funcionamento do áudio via HDMI/DisplayPort da própria GPU dentro da VM, e configurar passthrough dedicado de dispositivos USB físicos (teclado, mouse, headset) para uso exclusivo pela VM quando ligada.

## Pré-requisitos

- Capítulo 19 concluído (GPU em passthrough funcional).

## Explicação

### Áudio HDMI — já incluído no passthrough da GPU

Como explicado no Capítulo 16, a função de áudio HDMI/DisplayPort de uma GPU NVIDIA moderna é um dispositivo PCI **separado**, mas do mesmo grupo IOMMU que a função de vídeo — e já foi anexado ao XML da VM no Capítulo 19, através do segundo bloco `<hostdev>`. Isso significa que, tecnicamente, o áudio HDMI **já está** em passthrough desde o capítulo anterior; este capítulo apenas confirma seu funcionamento e orienta a configuração do dispositivo de saída correto dentro do Windows.

Dentro da VM Windows, após a instalação do driver NVIDIA (Capítulo 18):

1. Clique com o botão direito no ícone de som na bandeja do sistema → "Sons" → aba "Reprodução".
2. Deve aparecer um dispositivo de áudio nomeado algo como "NVIDIA High Definition Audio" associado à saída HDMI/DisplayPort conectada ao monitor (ou receptor AV) usado pela VM.
3. Se o monitor/TV possui alto-falantes ou está conectado a um sistema de som via HDMI, selecione esse dispositivo como "Dispositivo Padrão".

> **📝 NOTA:** Se o monitor usado pela VM não possui saída de áudio (comum em monitores de PC sem alto-falantes) e o áudio é desejado através de um dispositivo separado (headset USB, caixas de som conectadas à placa-mãe), a saída de áudio da placa-mãe **não está disponível** para a VM neste desenho de single-GPU passthrough (a placa de som onboard não foi passada à VM). Nesse caso, a solução recomendada é passthrough de um dispositivo de áudio USB dedicado (headset, DAC USB), descrito na próxima subseção.

### USB Passthrough — dois métodos

Existem duas abordagens possíveis para disponibilizar dispositivos USB (teclado, mouse, headset) à VM:

| Método | Como funciona | Vantagem | Desvantagem |
|---|---|---|---|
| **Passthrough de dispositivo individual** (`<hostdev>` USB por vendor:product ID) | A VM assume um dispositivo USB específico assim que ele é conectado, identificado por seu ID de fabricante/produto | Simples de configurar, funciona com qualquer porta USB física | Se o mesmo modelo de teclado for usado por dois dispositivos diferentes, ambos seriam capturados |
| **Passthrough de controladora USB inteira** (repassar um controlador USB PCI inteiro, como fez com a GPU) | Toda uma controladora USB física (geralmente correspondente a um conjunto específico de portas traseiras da placa-mãe) é cedida à VM | Permite hot-plug de qualquer dispositivo USB nessas portas, sem precisar reconfigurar XML | Requer que essa controladora esteja em um grupo IOMMU isolado (nem sempre o caso) e reduz portas USB disponíveis ao host |

Este documento recomenda o **passthrough de dispositivo individual** por simplicidade e por não depender de uma controladora USB isolada em seu próprio grupo IOMMU (o que nem toda placa-mãe garante).

### Identificando os dispositivos USB

```bash
lsusb
```
**O que faz:** lista todos os dispositivos USB conectados, no formato `Bus XXX Device XXX: ID vendor:product Descrição`. Localize o teclado, mouse e/ou headset que se deseja passar exclusivamente à VM.

Exemplo de **formato** de saída (valores ilustrativos):

```text
Bus 001 Device 004: ID XXXX:YYYY Logitech USB Receiver
```

O par após `ID` é, respectivamente, `<USB_MOUSE_VENDOR_ID>` (ou do teclado/headset) e `<USB_MOUSE_PRODUCT_ID>`.

> **⚠️ ALERTA:** Assim como os IDs PCI, **nunca** copie o exemplo acima. Use exclusivamente o resultado do `lsusb` do seu próprio sistema.

### Anexando o dispositivo USB ao XML da VM

```bash
virsh --connect qemu:///system edit <VM_NAME>
```

Adicione, dentro de `<devices>`:

```xml
<hostdev mode='subsystem' type='usb' managed='yes'>
  <source>
    <vendor id='0x<USB_MOUSE_VENDOR_ID>'/>
    <product id='0x<USB_MOUSE_PRODUCT_ID>'/>
  </source>
</hostdev>
```

**Explicação:** diferente do `<hostdev type='pci'>` usado para a GPU (Capítulo 19), aqui `type='usb'` instrui o libvirt a localizar o dispositivo pelo seu par vendor:product (que não muda entre portas físicas, ao contrário do endereço PCI de barramento, que é fixo por slot). `managed='yes'` permite que o libvirt gerencie a captura do dispositivo automaticamente ao iniciar/parar a VM, sem necessidade de hook scripts adicionais — diferente da GPU, dispositivos USB suportam desconexão/reconexão em quente de forma nativa e seu driver de host (`usbhid`, por exemplo) libera e reconecta o dispositivo sem exigir a sequência elaborada de `modprobe`/`unbind` usada para a GPU.

> **💡 DICA:** Um teclado/mouse compartilhado entre host e VM (útil para alternar entre Linux e Windows sem trocar cabos fisicamente) pode ser obtido com um software de compartilhamento de KVM por software (como Barrier ou Synergy) em vez de passthrough USB dedicado — abordagem alternativa fora do escopo detalhado deste documento, mas mencionada aqui como opção válida para quem prefere não dedicar um teclado/mouse fisicamente exclusivo à VM.

## Comandos

```bash
lsusb
virsh --connect qemu:///system edit <VM_NAME>   # adicionar bloco <hostdev type='usb'>
virsh --connect qemu:///system start <VM_NAME>
```

## Arquivos modificados

- `/etc/libvirt/qemu/<VM_NAME>.xml` (adicionado bloco `<hostdev type='usb'>` por dispositivo passthrough).

## Como verificar

Dentro da VM Windows, com o dispositivo USB conectado e a VM em execução:

```powershell
Get-PnpDevice -Class Keyboard, Mouse, AudioEndpoint
```
**Critério de sucesso:** o dispositivo passado em passthrough aparece listado dentro do Windows como hardware nativo, com status "OK".

No host, confirme que o dispositivo **não** aparece mais disponível para o Linux enquanto a VM está ligada:

```bash
lsusb
```
**Critério de sucesso:** o dispositivo em passthrough continua listado (USB não desaparece do barramento do host da mesma forma que a GPU some do `lspci`), mas não responde a eventos de input no lado Linux enquanto capturado pela VM — comportamento esperado e correto.

Para áudio HDMI, dentro da VM:

```powershell
Get-CimInstance -ClassName Win32_SoundDevice | Select-Object Name, Status
```
**Critério de sucesso:** lista o dispositivo "NVIDIA High Definition Audio" com status "OK".

## Resultado esperado

Áudio HDMI/DisplayPort da GPU funcional dentro do Windows como saída de som padrão (quando aplicável ao monitor/receptor usado); teclado, mouse e/ou headset USB dedicados capturados automaticamente pela VM ao iniciar e liberados ao desligar, sem intervenção manual.

## Como desfazer

```bash
virsh --connect qemu:///system edit <VM_NAME>   # remover os blocos <hostdev type='usb'>
```

## Problemas comuns

| Sintoma | Causa provável | Correção |
|---|---|---|
| Nenhum dispositivo de áudio NVIDIA aparece dentro do Windows | Driver NVIDIA não instalado corretamente (Capítulo 18), ou a função de áudio da GPU não foi anexada corretamente no Capítulo 19 | Verificar Gerenciador de Dispositivos dentro do Windows por dispositivos com erro (ícone de exclamação); revisar o segundo bloco `<hostdev>` do Capítulo 19 |
| Dispositivo USB não é capturado pela VM ao iniciar | ID vendor:product incorreto, ou dispositivo desconectado no momento do boot da VM | Reconferir `lsusb`; conectar o dispositivo antes de iniciar a VM |
| Teclado/mouse ficam "presos" na VM mesmo após desligá-la, sem resposta no Linux | Falha rara de handoff USB | Desconectar e reconectar fisicamente o dispositivo USB |

## Próxima etapa

Capítulo 21 — CPU Pinning, NUMA e HugePages, primeiro capítulo de ajuste fino de desempenho.

---

# Capítulo 21 — CPU Pinning, NUMA e HugePages

## Objetivo

Configurar a alocação de núcleos de CPU física à VM (CPU pinning), avaliar a topologia NUMA do Ryzen 7 5700X, e habilitar HugePages para reduzir a sobrecarga de gerenciamento de memória, melhorando a consistência de desempenho (redução de *stuttering*/microengasgos) da VM.

## Pré-requisitos

- Capítulo 19 concluído (VM funcional com GPU em passthrough).
- Capítulo 3 (inventário: 8 núcleos físicos / 16 threads do Ryzen 7 5700X).

## Explicação

### Por que CPU pinning

Por padrão, o KVM permite que o escalonador do kernel Linux mova livremente as vCPUs da VM entre quaisquer núcleos físicos disponíveis, exatamente como faria com qualquer processo comum. Isso é flexível, mas introduz variabilidade: uma vCPU pode ser movida de um núcleo para outro no meio de uma carga de trabalho intensa, invalidando caches L1/L2 (específicos por núcleo) e causando picos ocasionais de latência — perceptíveis em jogos como microengasgos (*stutters*) mesmo com taxa de quadros média alta.

**CPU pinning** (fixação de CPU) resolve isso atribuindo, de forma fixa, cada vCPU da VM a um núcleo físico específico do host, e reservando esses núcleos para uso exclusivo da VM durante sua execução (na prática, evitando — não necessariamente proibindo tecnicamente, mas isolando na prática — que outros processos do host disputem os mesmos núcleos, tema aprofundado no Capítulo 22 com CPU isolation).

### Topologia do Ryzen 7 5700X

O Ryzen 7 5700X é um processador **monolítico single-CCX-por-CCD** (na realidade, a família Zen 3 unificou os dois CCX de 4 núcleos anteriores em um único CCX de 8 núcleos por CCD, compartilhando um único bloco de cache L3), com um único CCD (Core Complex Die) — ou seja, **não há topologia NUMA relevante a considerar** neste processador específico (NUMA múltiplo importa mais em processadores com múltiplos CCDs, como as variantes de 12+ núcleos da linha Ryzen 9, ou em processadores Threadripper/EPYC). Isso simplifica a configuração: não é necessário se preocupar em manter vCPUs e memória alocada dentro do mesmo nó NUMA, pois há efetivamente um único nó.

```bash
lscpu | grep -i numa
```
**O que faz:** confirma o número de nós NUMA detectados pelo kernel. **Resultado esperado para este hardware:** `NUMA node(s): 1`.

### Mapeamento de núcleos físicos e threads (SMT)

O Ryzen 7 5700X possui 8 núcleos físicos com SMT (Simultaneous Multi-Threading, equivalente ao Hyper-Threading da Intel), totalizando 16 threads lógicas. Cada núcleo físico corresponde a **dois** IDs de CPU lógica no Linux (ex.: núcleo físico 0 → CPUs lógicas 0 e 8, dependendo do esquema de numeração do kernel — deve ser confirmado, não presumido).

```bash
lscpu -e
```
**O que faz:** lista cada CPU lógica com seu núcleo físico (`CORE`) e soquete (`SOCKET`) correspondentes, revelando exatamente qual par de CPUs lógicas compartilha o mesmo núcleo físico (mesma linha na coluna `CORE`).

> **⚠️ ALERTA:** Não presuma que CPUs lógicas 0-7 são núcleos físicos separados e 8-15 são as threads irmãs — isso depende do kernel e não é garantido. **Sempre** confirme com `lscpu -e` no seu próprio sistema antes de definir o pinning.

### Estratégia de alocação adotada

Reservar **6 núcleos físicos (12 threads lógicas)** para a VM, deixando **2 núcleos físicos (4 threads lógicas)** para o host Linux (essencial para que o próprio Linux continue responsivo, executando o `libvirtd`, os hook scripts do Capítulo 19, e tarefas de sistema em segundo plano, mesmo com a VM em plena carga).

```text
Ryzen 7 5700X — 8 núcleos físicos / 16 threads lógicas (numeração ilustrativa,
                CONFIRME a numeração real com `lscpu -e` antes de aplicar)

 Núcleo físico:   0    1    2    3    4    5    6    7
 CPU lógica:     0/8  1/9 2/10 3/11 4/12 5/13 6/14 7/15
                 └──────────── VM (6 núcleos) ───────────┘  └── Host (2 núcleos) ──┘
                 núcleos 0-5 (CPUs 0,8,1,9,2,10,3,11,4,12,5,13)   núcleos 6-7 (CPUs 6,14,7,15)
```

> **📝 NOTA:** A proporção 6/2 (ou qualquer outra) é uma escolha de compromisso, não uma regra fixa. Sistemas com uso mais leve do host durante o jogo podem reservar apenas 1 núcleo físico ao host; o Capítulo 27 (Benchmarks) orienta como medir o impacto real de diferentes proporções no seu uso específico.

### Configurando CPU pinning no XML da VM

```bash
virsh --connect qemu:///system edit <VM_NAME>
```

Ajuste (ou adicione) os seguintes blocos, substituindo os números de CPU lógica pelos confirmados via `lscpu -e` no seu sistema:

```xml
<vcpu placement='static' cpuset='0,8,1,9,2,10,3,11,4,12,5,13'>12</vcpu>
<cputune>
  <vcpupin vcpu='0'  cpuset='0'/>
  <vcpupin vcpu='1'  cpuset='8'/>
  <vcpupin vcpu='2'  cpuset='1'/>
  <vcpupin vcpu='3'  cpuset='9'/>
  <vcpupin vcpu='4'  cpuset='2'/>
  <vcpupin vcpu='5'  cpuset='10'/>
  <vcpupin vcpu='6'  cpuset='3'/>
  <vcpupin vcpu='7'  cpuset='11'/>
  <vcpupin vcpu='8'  cpuset='4'/>
  <vcpupin vcpu='9'  cpuset='12'/>
  <vcpupin vcpu='10' cpuset='5'/>
  <vcpupin vcpu='11' cpuset='13'/>
  <emulatorpin cpuset='6,14,7,15'/>
</cputune>
```

**Explicação:**

- `<vcpu placement='static' cpuset='...'>12</vcpu>`: define 12 vCPUs totais para a VM (6 núcleos físicos × 2 threads SMT cada), restringindo o conjunto de CPUs físicas onde essas vCPUs podem, no total, ser escalonadas ao conjunto listado em `cpuset`.
- Cada `<vcpupin vcpu='N' cpuset='M'/>`: fixa a vCPU número `N` (numeração interna da VM, de `0` a `11`) exclusivamente à CPU lógica física `M` do host — a correspondência ideal é que vCPUs pareadas (0/1, representando os dois threads SMT de um mesmo núcleo virtual) sejam mapeadas às duas threads lógicas do **mesmo** núcleo físico do host, preservando a localidade de cache também dentro da VM.
- `<emulatorpin cpuset='6,14,7,15'/>`: fixa as threads auxiliares do próprio processo QEMU (que não são vCPUs de convidado, mas threads de emulação de I/O, rede, etc.) aos núcleos reservados ao host — mantendo essas threads fora dos núcleos dedicados à carga de trabalho principal da VM.

### Topologia de CPU exposta ao Windows

Ainda dentro do XML, ajuste o elemento `<cpu>` para expor ao Windows uma topologia de núcleos/threads coerente com o pinning acima (6 núcleos, 2 threads cada):

```xml
<cpu mode='host-passthrough' check='none' migratable='off'>
  <topology sockets='1' dies='1' cores='6' threads='2'/>
</cpu>
```

**Explicação:** sem essa correção explícita de topologia, o Windows pode enxergar 12 "CPUs" como 12 núcleos únicos sem SMT, o que confunde o escalonador de threads do próprio Windows (que toma decisões diferentes para núcleos físicos vs threads irmãs). Declarar explicitamente `cores='6' threads='2'` faz o Windows tratar a topologia da VM exatamente como trataria um processador físico real de 6 núcleos com SMT — decisão importante para jogos que otimizam o uso de threads com base na topologia detectada.

### HugePages

**O que são:** por padrão, o kernel Linux gerencia memória em páginas de 4 KiB. Para uma VM com muitos gigabytes de RAM (16 GB, neste caso), isso resulta em milhões de entradas na tabela de páginas, aumentando a sobrecarga de tradução de endereço (TLB — Translation Lookaside Buffer) a cada acesso à memória. **HugePages** permite alocar memória em páginas muito maiores (2 MiB ou 1 GiB, dependendo do suporte de hardware), reduzindo drasticamente o número de entradas de tabela necessárias e, com isso, a taxa de "TLB miss" — métrica que impacta diretamente a latência de acesso à memória e, por consequência, a consistência de quadros por segundo em jogos.

```bash
grep -i pdpe1gb /proc/cpuinfo | head -n1
```
**O que faz:** verifica se a CPU suporta HugePages de 1 GiB (flag `pdpe1gb`) — o Ryzen 7 5700X suporta. Caso a flag não apareça, apenas HugePages de 2 MiB estão disponíveis (ainda assim benéficas, apenas com uma granularidade menor).

Reservar HugePages de 1 GiB, suficientes para os 16 GB de RAM da VM (16 páginas de 1 GiB):

```bash
sudo kernelstub -a "default_hugepagesz=1G hugepagesz=1G hugepages=16"
```
**O que faz (systemd-boot/kernelstub):** adiciona parâmetros de kernel que reservam, já no boot, 16 HugePages de 1 GiB (16 GB) — essa reserva é feita **antes** de o restante do sistema alocar memória livremente, pois HugePages precisam ser reservadas como blocos contíguos, o que se torna progressivamente mais difícil (podendo falhar) se tentado após o sistema já estar em execução há um tempo e a memória já fragmentada.

Para GRUB, adicionar os mesmos parâmetros a `GRUB_CMDLINE_LINUX_DEFAULT` em `/etc/default/grub` e rodar `sudo update-grub`, conforme o padrão já estabelecido no Capítulo 16.

```bash
sudo reboot
```

Após reiniciar, confirme a reserva:

```bash
grep Huge /proc/meminfo
```
**Critério de sucesso:** `HugePages_Total: 16`, com `Hugepagesize: 1048576 kB` (1 GiB).

Configure o XML da VM para usar essas HugePages:

```xml
<memoryBacking>
  <hugepages/>
</memoryBacking>
```

**O que faz:** instrui o QEMU a alocar a memória RAM da VM a partir do pool de HugePages reservado, em vez de páginas normais de 4 KiB.

> **⚠️ ALERTA:** Reservar 16 GB em HugePages **remove permanentemente** essa memória do pool disponível para uso geral do Linux, mesmo quando a VM está desligada — a menos que a reserva seja desfeita (ver "Como desfazer"). Com 32 GB totais de RAM, reservar 16 GB fixos para a VM deixa 16 GB para o host, o que é confortável para uso normal de desktop, mas deve ser dimensionado com atenção caso o host também rode cargas de trabalho pesadas quando a VM está desligada.

## Comandos

```bash
lscpu | grep -i numa
lscpu -e
grep -i pdpe1gb /proc/cpuinfo | head -n1
sudo kernelstub -a "default_hugepagesz=1G hugepagesz=1G hugepages=16"
sudo reboot
grep Huge /proc/meminfo
virsh --connect qemu:///system edit <VM_NAME>   # adicionar <vcpu>, <cputune>, <cpu topology>, <memoryBacking>
```

## Arquivos modificados

- Parâmetros de kernel (via `kernelstub` ou GRUB, conforme Capítulo 15).
- `/etc/libvirt/qemu/<VM_NAME>.xml` (blocos `<vcpu>`, `<cputune>`, `<cpu>`, `<memoryBacking>`).

## Como verificar

```bash
virsh --connect qemu:///system start <VM_NAME>
sudo systemctl status libvirtd | grep -i qemu
taskset -pc <PID_DE_UMA_THREAD_QEMU>
```

Alternativa mais direta, usando o próprio `virsh`:

```bash
virsh --connect qemu:///system vcpuinfo <VM_NAME>
```
**Critério de sucesso:** cada vCPU listada mostra o campo `CPU affinity` restrito exatamente aos núcleos definidos no `vcpupin`, e não ao conjunto total de CPUs do host.

Dentro do Gerenciador de Tarefas do Windows (aba "Desempenho" → "CPU"), a topologia exibida deve corresponder a 6 núcleos/12 threads lógicas, consistente com o `<topology>` configurado.

## Resultado esperado

vCPUs da VM fixadas a núcleos físicos específicos do host, com threads SMT irmãs corretamente pareadas; 2 núcleos físicos reservados exclusivamente para o host Linux; 16 GB de HugePages de 1 GiB reservados e em uso pela VM, reduzindo sobrecarga de gerenciamento de memória.

## Como desfazer

```bash
sudo kernelstub -d "default_hugepagesz=1G hugepagesz=1G hugepages=16"
sudo reboot
virsh --connect qemu:///system edit <VM_NAME>   # remover <cputune>, <memoryBacking>, reverter <vcpu> e <cpu>
```

## Problemas comuns

| Sintoma | Causa provável | Correção |
|---|---|---|
| VM não inicia após habilitar `<memoryBacking><hugepages/></memoryBacking>` | HugePages não reservadas com sucesso (memória fragmentada, reserva pedida após uso prolongado do sistema) | Confirmar `grep Huge /proc/meminfo` mostra o total esperado; reiniciar logo após aplicar o parâmetro de kernel, antes de qualquer uso pesado de memória pelo host |
| Desempenho pior após CPU pinning | Threads SMT irmãs mapeadas incorretamente (não correspondem ao mesmo núcleo físico) | Reconferir `lscpu -e` e corrigir o mapeamento em `<vcpupin>` |
| Windows mostra topologia de CPU "estranha" (núcleos não correspondem ao esperado) | Bloco `<topology>` ausente ou incorreto no XML | Revisar a seção `<cpu>` do XML |

## Próxima etapa

Capítulo 22 — CPU Isolation e MSI Interrupts.

---

# Capítulo 22 — CPU Isolation e MSI Interrupts

## Objetivo

Isolar, no nível do escalonador do kernel Linux, os núcleos reservados à VM (Capítulo 21) de qualquer outro processo do host, e configurar interrupções MSI (Message Signaled Interrupts) para a GPU, reduzindo latência de interrupção em comparação com o modo de interrupção legado (INTx).

## Pré-requisitos

- Capítulo 21 concluído (CPU pinning configurado).

## Explicação

### Por que CPU isolation, além do pinning

O `vcpupin` do Capítulo 21 impede que as **vCPUs da VM** sejam escalonadas fora dos núcleos designados. Mas, por padrão, nada impede que **outros processos do host** (um processo de atualização em segundo plano, um serviço de indexação de arquivos, o próprio kernel processando interrupções de outros dispositivos) sejam escalonados **para dentro** desses mesmos núcleos, competindo pelo cache e por ciclos de CPU com a VM.

`isolcpus`, um parâmetro de kernel, resolve isso pelo lado oposto: remove os núcleos especificados do conjunto de escalonamento geral do kernel, fazendo com que **nenhum processo comum do host** seja automaticamente escalonado neles — apenas processos explicitamente afinizados a esses núcleos (como as vCPUs da VM, via `vcpupin`) rodam ali.

> **⚠️ ALERTA:** `isolcpus` é uma ferramenta poderosa, mas com efeitos colaterais: núcleos isolados também deixam de receber automaticamente certas tarefas de manutenção do kernel (balanceamento de carga, alguns temporizadores). Isso é desejável para os núcleos dedicados à VM (queremos exatamente esse isolamento), mas nunca deve ser aplicado aos núcleos reservados ao host.

### Configurando isolcpus

Usando o mesmo mapeamento de CPUs lógicas do Capítulo 21 (núcleos físicos 0-5, CPUs lógicas `0,8,1,9,2,10,3,11,4,12,5,13`, reservados à VM):

```bash
sudo kernelstub -a "isolcpus=0,8,1,9,2,10,3,11,4,12,5,13 nohz_full=0,8,1,9,2,10,3,11,4,12,5,13 rcu_nocbs=0,8,1,9,2,10,3,11,4,12,5,13"
```

**Explicação de cada parâmetro:**

- `isolcpus=...`: remove as CPUs lógicas listadas do escalonador geral de processos do kernel, conforme explicado acima.
- `nohz_full=...`: reduz a frequência do "tick" periódico do temporizador do kernel (usado para contabilidade e preempção) nos núcleos listados, quando esses núcleos têm apenas uma única tarefa em execução (o caso das vCPUs dedicadas) — reduz interrupções desnecessárias que tirariam brevemente a vCPU de execução.
- `rcu_nocbs=...`: move o processamento de callbacks RCU (Read-Copy-Update, um mecanismo de sincronização interno do kernel) para fora dos núcleos listados, para as CPUs reservadas ao host — outra fonte de interrupções ocasionais e curtas que, de outra forma, ocorreriam nos núcleos dedicados à VM.

```bash
sudo reboot
```

## Comandos

```bash
sudo kernelstub -a "isolcpus=<LISTA_CPUS_VM> nohz_full=<LISTA_CPUS_VM> rcu_nocbs=<LISTA_CPUS_VM>"
sudo reboot
cat /proc/cmdline
cat /sys/devices/system/cpu/isolated
```

**O que o último comando faz:** confirma, a partir da interface do próprio kernel, quais CPUs lógicas estão efetivamente isoladas do escalonador geral — deve corresponder exatamente à lista configurada.

### MSI Interrupts

**O que são:** dispositivos PCI podem sinalizar interrupções de duas formas — via uma linha física de interrupção compartilhada (INTx, mecanismo legado, potencialmente compartilhado entre múltiplos dispositivos, o que introduz latência de arbitragem) ou via **MSI/MSI-X** (Message Signaled Interrupts), em que o dispositivo escreve uma mensagem diretamente em um endereço de memória específico para sinalizar a interrupção, sem compartilhar linha física com outros dispositivos, reduzindo latência e evitando interrupções espúrias.

A maioria das GPUs NVIDIA modernas, incluindo a RTX 3060, já opera com MSI-X habilitado por padrão dentro do Windows quando o driver oficial NVIDIA é usado — mas em algumas configurações de passthrough, o Windows pode, por padrão, negociar INTx em vez de MSI para dispositivos passthrough, resultando em microengasgos perceptíveis (um problema documentado na comunidade de passthrough como uma das causas mais comuns de "stuttering" em VMs com GPU passthrough).

### Forçando MSI dentro do Windows via registro

Dentro da VM Windows, com o driver NVIDIA já instalado (Capítulo 18):

1. Abra o Gerenciador de Dispositivos (`devmgmt.msc`).
2. Localize a GPU em "Adaptadores de vídeo" → propriedades → aba "Detalhes" → propriedade "Caminhos de instância do dispositivo" — copie o identificador exibido.
3. Abra o Editor de Registro (`regedit.exe`) como Administrador.
4. Navegue até `HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\PCI\<ID_do_dispositivo_copiado>\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties`.
5. Se a chave `MSISupported` não existir, crie um valor **DWORD** chamado `MSISupported` com valor `1`.
6. Reinicie a VM.

> **📝 NOTA:** Esta é uma configuração feita **dentro do sistema operacional convidado** (Windows), não no host Linux — está incluída neste capítulo por ser conceitualmente parte do mesmo tema de otimização de interrupções, mesmo que a execução seja do lado guest.

## Arquivos modificados

- Parâmetros de kernel do host (via `kernelstub`/GRUB).
- Registro do Windows dentro da VM (`HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\PCI\...`).

## Como verificar

```bash
cat /sys/devices/system/cpu/isolated
```
**Critério de sucesso:** lista exatamente as CPUs lógicas reservadas à VM.

```bash
ps -eo pid,psr,comm | grep qemu
```
**O que faz:** lista, para cada thread do processo QEMU, em qual CPU física (`PSR`, Processor) está executando no momento da consulta. **Critério de sucesso:** todos os valores de `PSR` correspondem às CPUs pinadas para a VM (Capítulo 21).

Dentro do Windows, verifique se o valor `MSISupported` foi aplicado corretamente usando uma ferramenta de terceiros amplamente usada pela comunidade, como o utilitário gráfico "MSI Utility" (não confundir com a fabricante MSI — o nome refere-se à tecnologia de interrupção). Alternativamente, monitore a suavidade de quadros em um jogo antes e depois da alteração como teste prático indireto.

## Resultado esperado

Núcleos dedicados à VM isolados do escalonador geral do host; interrupções da GPU configuradas para o modo MSI dentro do Windows, reduzindo latência de interrupção e potenciais microengasgos.

## Como desfazer

```bash
sudo kernelstub -d "isolcpus=<LISTA_CPUS_VM> nohz_full=<LISTA_CPUS_VM> rcu_nocbs=<LISTA_CPUS_VM>"
sudo reboot
```

Para o registro do Windows, exclua o valor `MSISupported` criado ou defina-o de volta a `0`.

## Problemas comuns

| Sintoma | Causa provável | Correção |
|---|---|---|
| Host fica lento/travando em tarefas gerais após isolcpus | Poucos núcleos sobraram para o host (proporção mal dimensionada no Capítulo 21) | Revisar a proporção de núcleos reservados; reduzir o número isolado |
| Sistema não inicializa após aplicar `isolcpus` | Erro de digitação na lista de CPUs, isolando acidentalmente todos os núcleos, incluindo os do host | Reiniciar em modo de recuperação (Capítulo 29) e reverter o parâmetro de kernel |
| Sem melhora perceptível de stuttering após configurar MSI | Causa raiz do stuttering é outra (ver Capítulo 28) — MSI é apenas um entre vários fatores possíveis | Prosseguir para o checklist completo de troubleshooting do Capítulo 28 |

## Próxima etapa

Capítulo 23 — Rede da VM: Bridge Ethernet ou NAT Libvirt.

---

# Capítulo 23 — Rede da VM: Bridge Ethernet ou NAT Libvirt

## Objetivo

Aplicar o backend de rede escolhido na etapa 02 sem perder a identidade da NIC: bridge somente sobre Ethernet, colocando a VM na LAN, ou uma rede NAT libvirt dedicada sobre Ethernet/Wi-Fi, sem alterar Netplan. Nos dois casos, manter o MAC persistido, produzir endereçamento estável para o airlock e permitir verificação/reversão objetiva.

## Pré-requisitos

- Capítulo 18 concluído (driver de rede VirtIO instalado dentro da VM).
- Etapa 02 refeita com a versão atual: `REDE_MODO=bridge|nat` e `INTERFACE_FISICA` válidos.
- VM desligada; a etapa 40 já criou a NIC NAT `default` temporária e persistiu `VM_NIC_MAC` (configurações antigas são migradas pela 60).

## Explicação

### Seleção do uplink e matriz de suporte

A etapa 02 não procura mais prefixos `en*`/`eth*`. Ela sempre enumera todas as interfaces com `/sys/class/net/<iface>/device`, exclui `lo` e interfaces virtuais, mostra estado, carrier, IPv4, MAC e driver, e destaca explicitamente o dispositivo retornado por `ip -4 route get 1.1.1.1`. Essa é apenas uma consulta à decisão local de roteamento do kernel: nenhum pacote é enviado. A classificação Wi-Fi usa exclusivamente `/sys/class/net/<iface>/wireless`. Se NAT for escolhido em outra interface, a etapa 02 avisa e a 60 aborta antes de qualquer mutação até o adaptador selecionado virar a rota padrão (ou o outro ser desconectado/ter a métrica ajustada). Trocar o uplink mantendo bridge também limpa os IPs reservados da LAN anterior.

| Uplink | Bridge | NAT |
|---|---|---|
| Ethernet | suportada | suportada |
| Wi-Fi station | **não suportada** | suportada e vinculada ao adaptador escolhido |

Uma estação Wi-Fi 802.11 normalmente não consegue transportar os endereços MAC de convidados atrás dela. Isso exigiria 4addr/WDS compatível e habilitado tanto no adaptador quanto no ponto de acesso; por não ser uma propriedade portátil/confiável, o projeto rejeita bridge Wi-Fi e usa NAT libvirt.

### NAT vs Bridge

A rede `default` da etapa 40 é apenas temporária. Na etapa 60, `REDE_MODO=nat` cria uma rede libvirt **dedicada**, com bridge e sub-rede privadas próprias e `<forward mode='nat' dev='<INTERFACE_FISICA>'>`; `REDE_MODO=bridge` migra a NIC para a bridge Ethernet do host. NAT é menos exposto à LAN e funciona com Wi-Fi, mas tem estas diferenças em relação à bridge:

1. Outros dispositivos na rede local (por exemplo, outro computador tentando se conectar a um servidor de jogo hospedado na VM) não conseguem alcançar a VM diretamente pelo IP da rede doméstica, pois ela está "atrás" do NAT do libvirt.
2. Alguns jogos multiplayer e serviços de matchmaking têm melhor comportamento (menor NAT type restritivo, no jargão de consoles/jogos online) quando o dispositivo está na mesma sub-rede lógica do roteador.

### Modo bridge (somente Ethernet)

Uma **bridge** de rede resolve isso: cria uma interface virtual no host que atua como um switch de software, ao qual tanto a interface física do host quanto a interface virtual da VM se conectam. A VM passa a solicitar IP via DHCP diretamente ao roteador da rede doméstica, recebendo um endereço na mesma sub-rede que qualquer outro dispositivo físico da casa.

> **⚠️ ALERTA:** Em modo bridge, a VM e o host tornam-se **pares plenos e distintos na rede local**: a VM fica alcançável por qualquer dispositivo da LAN (incluindo dispositivos IoT e visitantes do Wi-Fi) e, na direção inversa, a VM alcança qualquer serviço que o host exponha. Isso expande a superfície de ataque nos dois sentidos. Por isso, nenhum serviço de compartilhamento de arquivos do host deve ficar aberto à rede inteira: o Capítulo 24 configura o firewall (`ufw`) restringindo o serviço de transferência exclusivamente ao IP fixo da VM. Dentro do Windows, mantenha o firewall ativo e o perfil de rede como **Rede pública**, salvo necessidade específica de descoberta na LAN.

```text
Roteador doméstico (DHCP)
      │
      ▼
Interface física do host (<INTERFACE_FISICA>, ex.: enp5s0)
      │
      ▼
   br0 (bridge)
   ├── <INTERFACE_FISICA>  (porta física)
   └── vnet0 (interface virtual da VM, criada automaticamente pelo libvirt)
```

### Identificando a interface física

```bash
ip link show
```
**O que faz:** lista todas as interfaces, inclusive virtuais. Para evitar escolher `lo`, bridges, veth/tap ou depender do prefixo do nome, use `bash etapas/02-detectar-config.sh --redetectar`: a seleção guiada consulta o sysfs e mantém o adaptador escolhido em `<INTERFACE_FISICA>` nos dois modos. Se ele for Wi-Fi, somente NAT será oferecida.

### Configurando a bridge via Netplan

O Pop!_OS usa o **Netplan** como camada declarativa sobre o renderer já escolhido pelo sistema. Este projeto não substitui o primeiro YAML encontrado e não força `networkd`: grava somente o arquivo dedicado `/etc/netplan/90-vm-passthrough-bridge.yaml`, preservando integralmente Wi-Fi e interfaces não relacionadas nos demais arquivos.

Se o dedicado já existir, faça backup dele; caso contrário, não há arquivo anterior a restaurar:

```bash
if sudo test -e /etc/netplan/90-vm-passthrough-bridge.yaml; then
  sudo cp -p /etc/netplan/90-vm-passthrough-bridge.yaml \
    /etc/netplan/90-vm-passthrough-bridge.yaml.bak-$(date +%Y%m%d-%H%M%S)
fi
sudo nano /etc/netplan/90-vm-passthrough-bridge.yaml
```

Conteúdo dedicado (adapte apenas os dois nomes):

```yaml
network:
  version: 2
  ethernets:
    <INTERFACE_FISICA>:
      dhcp4: no
      dhcp6: no
  bridges:
    br0:
      interfaces: [<INTERFACE_FISICA>]
      dhcp4: yes
      parameters:
        stp: true
        forward-delay: 4
```

O arquivo contém somente `network/version`, o uplink escolhido e a bridge; não declara renderer nem qualquer outra interface. `<INTERFACE_FISICA>` deixa de solicitar IP diretamente, `br0` assume o DHCP do host e `stp` protege contra loops. Na execução automatizada, a etapa 60 arma rollback antes de escrever: falha em `netplan generate`, `try`, `apply` ou nas pós-condições estruturais (`br0` `UP`, `<INTERFACE_FISICA>` com `master br0` e NIC da VM apontando para `br0` com o MAC preservado) restaura/remove o dedicado, executa `netplan generate` + `apply` para reaplicar o estado anterior e restaura o XML da VM. Quando essas pós-condições passam, Netplan, bridge `UP`, vínculo `master` e NIC podem ser commitados mesmo que `<VM_IP_FIXO>` e/ou `<IP_FIXO_HOST>` ainda estejam incompletos; nesse caso, `--verificar` e a etapa 61 permanecem pendentes até os dois endereços serem preenchidos e validados.

```bash
sudo netplan generate
sudo netplan try
```
**O que faz:** aplica a configuração de forma **temporária** e reversível — se a conectividade de rede não se recuperar dentro de um intervalo curto (o usuário precisa confirmar pressionando Enter), o Netplan reverte automaticamente à configuração anterior. Este é o comando recomendado para testar mudanças de rede remotamente ou em qualquer cenário em que perder a conectividade seria problemático.

```bash
sudo netplan apply
```
**O que faz:** aplica a configuração permanentemente, após confirmado que `netplan try` funcionou como esperado.

### Ajustando a VM para usar a bridge

```bash
virsh --connect qemu:///system edit <VM_NAME>
```

Localize o bloco `<interface type='network'>` (rede NAT padrão) e substitua por:

```xml
<interface type='bridge'>
  <mac address='<VM_NIC_MAC>'/>
  <source bridge='br0'/>
  <model type='virtio'/>
</interface>
```

**O que faz:** conecta a NIC cujo MAC foi persistido em `VM_NIC_MAC` à bridge `br0`. A etapa 60 seleciona esse bloco pelo MAC, nunca por `interface[1]`, troca somente tipo/fonte e confirma que o MAC foi preservado antes de redefinir a VM.

### Reserva de IP fixo para a VM (e para o host)

O Capítulo 24 restringirá o serviço de transferência de arquivos ao IP da VM. Para que essa regra de firewall seja estável, o IP da VM não pode mudar a cada renovação de DHCP — reserve um IP fixo no roteador:

```bash
virsh --connect qemu:///system domiflist <VM_NAME>
```

**O que faz:** lista as interfaces de rede da VM com seus endereços MAC. O valor da coluna `MAC` é o identificador a usar na reserva.

1. Acesse a interface administrativa do roteador (procedimento específico de cada fabricante, fora do escopo deste documento).
2. Localize a função de **reserva de DHCP** (também chamada de "DHCP estático" ou "IP/MAC binding").
3. Associe o MAC da interface da VM a um IP livre da sub-rede — este endereço passa a ser o `<VM_IP_FIXO>`.
4. Repita para o host, associando o MAC da `br0` (visível em `ip link show br0`) a outro IP fixo — este é o `<IP_FIXO_HOST>`, que o cliente SFTP dentro do Windows usará como destino (Capítulo 24).

> **💡 DICA:** Alternativa sem acesso ao roteador: configurar IP estático diretamente dentro do Windows (Configurações → Rede e Internet → Ethernet → atribuição de IP manual), usando um endereço fora da faixa dinâmica do DHCP. A reserva no roteador é preferível por concentrar a administração de endereços em um único lugar.

### Modo NAT dedicado (Ethernet ou Wi-Fi)

No NAT, a etapa 60 **não altera o uplink e não lê, cria nem substitui arquivos Netplan**. Ela apenas exige que `<INTERFACE_FISICA>` seja o dispositivo da rota IPv4 efetiva, procura uma `REDE_NAT_CIDR` privada `/24` sem sobreposição e cria/atualiza uma rede persistente (padrão `passthrough-nat`). O libvirt cria a bridge virtual, inicia uma instância `dnsmasq` para DHCP/DNS e instala no host as regras de encaminhamento/NAT; a configuração e a métrica do adaptador físico permanecem intactas.

Na detecção de colisão, nenhuma rota sobreposta é ignorada por estar na mesma bridge. A única exceção são as rotas `proto kernel` exatas da sub-rede atualmente configurada na rede gerenciada: o CIDR conectado, `local` do gateway e `broadcast` dos endereços de rede/broadcast. Qualquer outra rota sobreposta bloqueia antes da definição.

Estrutura conceitual gerada (os endereços reais vêm do `passthrough.conf`):

```xml
<network>
  <name>passthrough-nat</name>
  <description>vm-passthrough:60-rede-nat:v1</description>
  <forward mode='nat' dev='<INTERFACE_FISICA>'/>
  <bridge name='virbr-vmnat'/>
  <ip address='<IP_FIXO_HOST>' netmask='255.255.255.0'>
    <dhcp>
      <range start='<INICIO_DHCP>' end='<FIM_DHCP>'/>
      <host mac='<VM_NIC_MAC>' ip='<VM_IP_FIXO>'/>
    </dhcp>
  </ip>
</network>
```

A rede é iniciada e marcada para autostart. A reserva DHCP preenche `<VM_IP_FIXO>` e usa o gateway virtual como `<IP_FIXO_HOST>`; não há reserva no roteador. A NIC é localizada por `<VM_NIC_MAC>`. Em configurações antigas sem esse valor, a etapa consulta e conta **todas** as `/domain/devices/interface`: autoescolhe somente se o total for um; com várias, mostra todas e marca `network=default` como **RECOMENDADA**, sem filtrar as demais.

O campo `description` prova a propriedade. Uma `<REDE_LIBVIRT>` homônima sem o marcador nunca é adotada nem alterada. Antes da primeira mutação, a etapa captura XML persistente/ativo, existência/persistência, ativo/autostart da rede, XML inativo da VM e uma cópia exata do `passthrough.conf`. Definição da rede, reinício, autostart, troca da fonte da NIC e persistência pertencem à mesma transação. Qualquer falha ou `INT`/`TERM` restaura XML e estados originais, VM e configuração; se a rede não existia, destrói e remove a criação parcial. Falhas de rollback são exibidas individualmente, e o commit lógico só ocorre após todas as verificações finais.

Em uma atualização gerenciada, o UUID é preservado e o XML anterior também fica em `backups/rede-<nome>-<data>.xml`. Definição persistente e backend ativo são comparados separadamente. Os endereços só passam quando `<IP_FIXO_HOST>` está efetivamente na bridge e `<VM_IP_FIXO>` é unicast distinto no mesmo prefixo; `--verificar` repete essas checagens e a trava da rota IPv4 efetiva.

> **⚠️ MIGRAÇÃO NAT → BRIDGE:** antes de tocar Netplan, se a rede marcada existir,
> a etapa executa `virsh --connect qemu:///system list --all --name` e inspeciona
> o XML inativo de todas as outras VMs, ligadas ou desligadas, por `source
> network` e `source bridge`. Consumidores são listados e bloqueiam a migração.
> Sem consumidores, desabilita autostart e para a rede; no sucesso deixa sua
> definição inativa. Se a bridge falhar, a transação restaura esses estados. Uma
> rede homônima sem marcador é apenas avisada e jamais alterada.
>
> **⚠️ MIGRAÇÃO BRIDGE → NAT:** o NAT não desfaz Netplan. Restaure o backup do
> dedicado ou remova `/etc/netplan/90-vm-passthrough-bridge.yaml`, execute `sudo
> netplan generate && sudo netplan apply` e só então rode a etapa 60. Ela aborta
> enquanto `<INTERFACE_FISICA>` ainda estiver escravizada a qualquer bridge.

### Fluxo automatizado recomendado

```bash
bash etapas/02-detectar-config.sh --redetectar  # escolher uplink e modo
bash etapas/60-rede-bridge.sh                   # aplicar backend final
bash etapas/60-rede-bridge.sh --verificar      # conferir backend/uplink/NIC/IP
```

Apesar do nome histórico, `60-rede-bridge.sh` configura os dois modos, exige a VM desligada e conclui após o commit lógico do backend. Em bridge, esse commit pode abranger somente Netplan, bridge `UP`, vínculo `master` e NIC; se `<VM_IP_FIXO>` e/ou `<IP_FIXO_HOST>` ainda estiverem incompletos, `--verificar` e a etapa 61 permanecem pendentes.

## Comandos

Fluxo recomendado (ambos os modos):

```bash
bash etapas/02-detectar-config.sh --redetectar
bash etapas/60-rede-bridge.sh
bash etapas/60-rede-bridge.sh --verificar
```

Somente para uma implementação manual de **bridge Ethernet**:

```bash
ip -4 route get 1.1.1.1
sudo cp -p /etc/netplan/90-vm-passthrough-bridge.yaml \
  /etc/netplan/90-vm-passthrough-bridge.yaml.bak-$(date +%Y%m%d-%H%M%S)  # somente se existir
sudo nano /etc/netplan/90-vm-passthrough-bridge.yaml
sudo netplan generate
sudo netplan try
sudo netplan apply
virsh --connect qemu:///system edit <VM_NAME>
```

Para inspecionar o **NAT dedicado** (sem editar Netplan):

```bash
virsh --connect qemu:///system net-info passthrough-nat
virsh --connect qemu:///system net-dumpxml passthrough-nat
virsh --connect qemu:///system dumpxml <VM_NAME>
```

## Arquivos modificados

- `passthrough.conf`: modo, uplink, nomes do backend, `VM_NIC_MAC` e endereços.
- Nos dois modos: `/etc/libvirt/qemu/<VM_NAME>.xml` (fonte da NIC, com backup datado).
- Somente bridge: `/etc/netplan/90-vm-passthrough-bridge.yaml` (arquivo dedicado; backup datado se já existia; outros YAMLs preservados).
- Somente NAT: definição persistente da rede libvirt `REDE_LIBVIRT`, bridge virtual, `dnsmasq` e regras host de encaminhamento/NAT; nenhum arquivo Netplan é tocado.

## Como verificar

Primeiro use o verificador orientado pelo modo:

```bash
bash etapas/60-rede-bridge.sh --verificar
```

**Bridge Ethernet:** o commit estrutural deve confirmar `br0` ativa, `<INTERFACE_FISICA>` como porta e NIC identificada por `<VM_NIC_MAC>` com `source bridge='br0'`. Se `<VM_IP_FIXO>` e/ou `<IP_FIXO_HOST>` ainda estiverem incompletos, esses elementos permanecem aplicados, mas `--verificar` e a etapa 61 permanecem pendentes. Com os dois IPs gravados, o verificador também os valida; `ip addr show br0` mostra o IP LAN do host; `ipconfig` na VM mostra `<VM_IP_FIXO>` na mesma sub-rede do roteador; host e guest alcançam a internet.

**NAT Ethernet/Wi-Fi:** deve confirmar a rede dedicada ativa/autostart, `<forward mode='nat' dev='<INTERFACE_FISICA>'>`, bridge virtual, sub-rede/reserva DHCP, NIC com `source network='<REDE_LIBVIRT>'` e `INTERFACE_FISICA` igual ao dispositivo de `ip -4 route get 1.1.1.1`. `ipconfig` mostra `<VM_IP_FIXO>` na sub-rede privada; a VM alcança a internet e `<IP_FIXO_HOST>`.

## Resultado esperado

A VM usa exatamente o backend persistido em `<REDE_MODO>`: como par da LAN em bridge Ethernet, ou isolada em uma sub-rede NAT libvirt dedicada vinculada ao uplink Ethernet/Wi-Fi. O MAC permanece estável e o airlock recebe IPs determinísticos nos dois modos.

## Como desfazer

**Bridge:** falhas durante a etapa já disparam rollback automático. Para uma reversão manual, com a VM desligada, restaure o backup do dedicado (ou remova-o se ele não existia), gere/aplique e restaure o XML:

```bash
sudo cp /etc/netplan/90-vm-passthrough-bridge.yaml.bak-<data> \
  /etc/netplan/90-vm-passthrough-bridge.yaml  # ou: sudo rm ... se era novo
sudo netplan generate
sudo netplan apply
virsh --connect qemu:///system define backups/<vm>-<data>.xml
```

**NAT:** Netplan não precisa (e não deve) ser restaurado, pois não foi tocado. Restaure o backup XML da VM; para remover também o backend dedicado, confirme que nenhuma VM o usa e execute:

```bash
virsh --connect qemu:///system net-destroy <REDE_LIBVIRT>
virsh --connect qemu:///system net-undefine <REDE_LIBVIRT>
```

A rede `default` temporária foi preservada. Se quiser voltar a ela, execute `virsh --connect qemu:///system net-start default` e `virsh --connect qemu:///system net-autostart default`, depois restaure o XML de backup que continha `source network='default'`. Ao trocar de modo, rode a etapa 61: ela remove todas as regras UFW antigas com o comentário exato e só aceita a pós-condição de uma regra atual.

## Problemas comuns

| Sintoma | Causa provável | Correção |
|---|---|---|
| Host perde conectividade de rede após `netplan apply` | Erro de sintaxe YAML, ou nome de interface física incorreto | Usar sempre `netplan try` primeiro; reverter do backup se necessário |
| VM não recebe IP através da bridge | Bridge `br0` não está corretamente "up", ou firewall do roteador bloqueando novo dispositivo | Verificar `ip link show br0` (deve mostrar estado `UP`); verificar configuração do roteador |
| Bridge solicitada com uplink Wi-Fi | Wi-Fi station não transporta MACs adicionais sem 4addr/WDS | Escolher `REDE_MODO=nat`; bridge Wi-Fi é deliberadamente rejeitada pelo projeto |
| Etapa NAT aborta por colisão | `REDE_NAT_CIDR` sobrepõe rota/VPN ou outra rede libvirt | Escolher outra sub-rede privada `/24`; nada foi aplicado antes da detecção |
| Rede NAT existe, mas a VM recebeu outro IP | lease antigo no Windows ou XML/reserva divergente | Rodar `--verificar`, renovar DHCP/reiniciar o Windows e conferir o MAC persistido |

## Próxima etapa

Capítulo 24 — Compartilhamento Seguro de Arquivos (Airlock), que usa o IP estável e a interface produzidos pelo backend selecionado: `br0`/`REDE_BRIDGE` em bridge ou a bridge virtual libvirt em NAT.

---

# Capítulo 24 — Compartilhamento Seguro de Arquivos (Airlock)

## Objetivo

Estabelecer o único canal autorizado de troca de arquivos entre o host Linux e a VM Windows: a pasta de trânsito `/mnt/docs4/airlock` ("airlock"), fisicamente armazenada no HD2, exposta à VM exclusivamente por SFTP com chroot (método padrão; Samba hardenizado documentado como alternativa), com autenticação por chave, usuário de sistema dedicado (`<TRANSFER_USER>`), firewall restringindo o serviço ao `<VM_IP_FIXO>`, e criação automática e idempotente integrada aos hooks do Capítulo 19 — sem jamais expor os diretórios reais do usuário.

## Pré-requisitos

- Capítulo 11 concluído (HD2 montado em `/mnt/docs4` via `ntfs-3g`).
- Capítulo 19 concluído (estrutura de hooks do libvirt criada e funcional).
- Capítulo 23 concluído no modo escolhido; `<VM_IP_FIXO>` e `<IP_FIXO_HOST>` preenchidos pela etapa 60 (roteador em bridge, DHCP/gateway libvirt em NAT).
- VM Windows funcional (Capítulos 17 e 18), com a Inicialização Rápida desativada (Capítulo 18).

## Explicação

### O problema que este capítulo resolve

O vetor de ataque mais provável deste ambiente não é sofisticado: é um arquivo malicioso que entra na VM pelos downloads e launchers do HD1 e, a partir dela, procura um caminho de escrita até os dados reais do usuário. Dois fatos dos capítulos anteriores tornam esse risco concreto:

1. **Em bridge, a VM é um par pleno na LAN; em NAT, ela fica atrás da sub-rede libvirt.** Nos dois casos, a VM alcança serviços do host pelo endereço `<IP_FIXO_HOST>`, portanto a restrição por interface+IP e a autenticação forte continuam necessárias.
2. **Qualquer compartilhamento que apontasse para as pastas reais do HD2** (`Documentos`, `Downloads` etc.) anularia, na prática, o princípio do Capítulo 2: a integridade do HD2 não pode depender do estado da VM.

A solução é uma **zona de trânsito**: uma pasta dedicada e isolada, usada exclusivamente para arquivos em movimento entre os dois sistemas — nunca para dados permanentes. A VM enxerga essa pasta, e **somente** essa pasta.

```text
/mnt/docs4/
├── Documentos/     ← NUNCA exposto à VM
├── Downloads/      ← NUNCA exposto à VM
├── Imagens/        ← NUNCA exposto à VM
├── Musicas/        ← NUNCA exposto à VM
├── Videos/         ← NUNCA exposto à VM
└── airlock/        ← única pasta acessível pela VM (leitura+escrita), criada automaticamente
```

Requisitos de projeto deste capítulo:

| Requisito | Como é atendido |
|---|---|
| Localização dentro do HD2, como pasta irmã de `Documentos` | `/mnt/docs4/airlock` — os dados residem fisicamente no HD2, sem consumir o NVMe |
| Bidirecional (leitura **e** escrita nos dois lados) | Permissões da visão de serviço (`bindfs`, abaixo) + SFTP sem restrição de escrita |
| Criação automática e idempotente | Script `00-airlock.sh` no hook `prepare/begin` já existente (Capítulo 19) |
| Isolamento | Chroot do sshd + firewall por IP + usuário dedicado sem shell |

### Por que NTFS exige um desenho específico

O Capítulo 11 monta o HD2 com `uid=1000,gid=1000,umask=022`. Nesse modo, o `ntfs-3g` **sintetiza** dono e permissões de todos os arquivos a partir das opções de montagem, para o volume inteiro: `chown` e `chmod` por pasta não têm efeito persistente. Duas consequências diretas para um compartilhamento seguro:

1. O `sshd` exige que o diretório de `ChrootDirectory` (e todos os seus diretórios pais) pertença a `root` — impossível de garantir em um caminho dentro do HD2, onde tudo aparece como propriedade do `<USUARIO_LINUX>`.
2. Não é possível dar a um usuário dedicado permissão de escrita em **uma única pasta** do HD2 via permissões POSIX.

A solução adotada usa o **bindfs**, um sistema de arquivos FUSE que reapresenta um diretório existente com outro dono e outras permissões, sem copiar dados:

```text
Lado Linux (<USUARIO_LINUX>):   /mnt/docs4/airlock       (NTFS — dados físicos no HD2)
                                        ▲
                                        │  bindfs: visão remapeada
                                        │  (dono <TRANSFER_USER>, perms 0770,
                                        │   noexec, nosuid, nodev)
Lado serviço (SFTP/Samba):      /srv/airlock/files
Base do chroot (sshd):          /srv/airlock             (ext4, root:root — exigência do sshd)
```

- O usuário Linux continua usando `/mnt/docs4/airlock` diretamente (é o dono aparente de todo o volume, como sempre foi).
- O serviço de transferência enxerga a **mesma pasta** através de `/srv/airlock/files`, onde o dono aparente é o `<TRANSFER_USER>` — e não enxerga nada além dela.
- `/srv/airlock` fica no NVMe (ext4), onde permissões POSIX funcionam de verdade, satisfazendo a exigência do chroot. Apenas diretórios vazios vivem no NVMe; os arquivos em trânsito ocupam espaço somente no HD2.

### Métodos de acesso

| Método | Papel | Superfície de ataque |
|---|---|---|
| **SFTP com chroot** | **Padrão** | Porta 22 aberta somente para `<VM_IP_FIXO>`; autenticação somente por chave |
| Samba hardenizado | Alternativa (unidade mapeada no Explorer) | Porta 445 aberta somente para `<VM_IP_FIXO>`; SMB3 criptografado e assinado |
| Pen drive / USB passthrough | Pontual (Capítulo 20) | Nenhuma exposição de rede |
| Montagem manual do HD1, somente leitura | Emergência, com a VM desligada (seção 10 abaixo) | Nenhuma exposição de rede |

> **💡 DICA:** Escolha **um** método de rede e configure somente ele. O SFTP é o padrão recomendado por ter superfície menor e não manter compartilhamento montado em caráter permanente no lado Windows; o Samba é aceitável quando a conveniência da unidade mapeada no Explorer compensar o serviço contínuo adicional (`smbd`) no host.

> **📝 NOTA:** As transferências acontecem justamente **enquanto a VM está ligada** — período em que o host está sem interface gráfica (a GPU pertence à VM, Capítulo 19). Isso não é um problema: o `sshd` (e o `smbd`, se usado) são serviços de rede independentes da sessão gráfica e continuam operando normalmente com o host "headless".

### Por que um usuário dedicado

A credencial usada pela VM fica armazenada **dentro** da VM — exatamente o sistema tratado como não confiável neste desenho. Se essa credencial fosse a do `<USUARIO_LINUX>`, um comprometimento da VM entregaria acesso a tudo o que esse usuário alcança. Com o `<TRANSFER_USER>` (conta de sistema, sem shell de login, sem home real, sem senha), o "raio de alcance" de uma credencial roubada é: uma sessão SFTP confinada por chroot a uma única pasta de trânsito. Nada mais.

### Endurecimento global do SSH deste host

Instalar o `openssh-server` para o airlock significa abrir a porta 22 justamente para a VM — a origem de ameaça deste modelo. Duas diretivas globais acompanham obrigatoriamente esta configuração:

- `PasswordAuthentication no` (e `KbdInteractiveAuthentication no`): sem elas, a conta `<USUARIO_LINUX>` ficaria exposta a força bruta de senha a partir da VM. Com chave obrigatória, força bruta deixa de ser viável.
- `PermitRootLogin no`: elimina o alvo mais valioso.

> **⚠️ ALERTA:** `PasswordAuthentication no` vale para o host inteiro. Se você acessa este host por SSH **com senha** a partir de outros dispositivos (ex.: um notebook na LAN), configure chaves SSH para eles antes de aplicar, ou o acesso deles deixará de funcionar. O console local (teclado/monitor no próprio host) nunca é afetado.

### Limites do desenho

- **Spoofing/escopo da rede:** em bridge, outro dispositivo da LAN poderia tentar falsificar o IP/MAC da VM; no NAT, a regra existe somente na bridge virtual e a LAN não possui rota para a sub-rede privada. Em ambos, a chave privada continua sendo uma segunda barreira independente.
- **Conteúdo em trânsito é não confiável:** o Defender examina os arquivos no lado Windows (Capítulo 18), mas não há antivírus no lado Linux. A visão de serviço é montada com `noexec`, e a regra operacional é: **não execute binários ou scripts vindos do airlock**; trate-os como dados.
- **Zona de trânsito, não armazenamento:** a pasta airlock não guarda dados permanentes e fica **fora do escopo de backup** (Capítulo 25). Mova os arquivos para o destino final (`Documentos` etc.) após cada transferência.

### Antivírus no convidado — confirmado

O Windows Defender é suficiente para este ambiente; não instale EDR/antivírus de terceiros. O único cuidado, reforçado no Capítulo 18: manter a proteção em tempo real ativa e **não criar exclusão de pasta para o airlock** — isso anularia a única checagem de malware que os arquivos em trânsito recebem.

> **📝 NOTA:** Existe uma alternativa que dispensa completamente a rede: **VirtIO-FS**, que apresenta uma pasta do host diretamente à VM como dispositivo (driver `virtiofs` da ISO `virtio-win` + WinFsp no convidado, elemento `<filesystem>` e memória compartilhada no XML da VM). Elimina portas, credenciais e firewall, ao custo de mais software no convidado e configuração adicional de memória. A objeção do Capítulo 2 a pastas compartilhadas (anticheat/DRM) não se aplica aqui, pois o airlock não armazena jogos. Fica registrada como evolução possível, fora do fluxo padrão deste documento.

## Comandos

### 1. Grupo e usuário dedicados

```bash
sudo groupadd --system airlock-transfer
sudo useradd --system --no-create-home --home-dir /files --shell /usr/sbin/nologin --gid airlock-transfer <TRANSFER_USER>
id <TRANSFER_USER>
```

**O que fazem:** criam o grupo e a conta de sistema dedicados. `--shell /usr/sbin/nologin` bloqueia qualquer shell interativo; `--no-create-home` evita um home real (a conta não é para login); `--home-dir /files` define o "home" **relativo ao chroot** — é onde a sessão SFTP cai ao conectar, ou seja, diretamente na pasta gravável. Contas `--system` são criadas sem senha válida (travadas para autenticação por senha). O `id` confirma usuário e grupo criados.

### 2. Pastas

```bash
mountpoint -q /mnt/docs4 || echo "ERRO: HD2 nao esta montado - resolva antes de continuar (Capitulo 11)"
sudo mkdir -p /mnt/docs4/airlock
sudo mkdir -p /srv/airlock/files
sudo chown root:root /srv/airlock
sudo chmod 755 /srv/airlock
```

**O que fazem:** a primeira linha confirma que o HD2 está montado (criar a pasta com o disco desmontado poluiria o ponto de montagem vazio no NVMe, e não o HD2 real). Em seguida: a pasta de trânsito real no HD2 (dono aparente `<USUARIO_LINUX>`, definido pela montagem do Capítulo 11 — correto para o lado Linux); a base do chroot `/srv/airlock` em ext4, com dono `root:root` e permissão `755` (exigência do sshd); e `/srv/airlock/files`, o ponto de montagem vazio da visão de serviço.

### 3. Visão de serviço (bindfs)

```bash
sudo apt install -y bindfs
```

Adicione ao final do `/etc/fstab` (depois das linhas do Capítulo 11):

```fstab
/mnt/docs4/airlock  /srv/airlock/files  fuse.bindfs  force-user=<TRANSFER_USER>,force-group=airlock-transfer,perms=0770,chmod-ignore,chown-ignore,allow_other,noexec,nosuid,nodev,nofail,x-systemd.requires=/mnt/docs4  0  0
```

**Explicação campo a campo:**

| Opção | Significado |
|---|---|
| `force-user` / `force-group` | Na visão de serviço, todos os arquivos aparecem como propriedade de `<TRANSFER_USER>:airlock-transfer` — é o que dá ao usuário dedicado leitura+escrita plenas, **somente aqui** |
| `perms=0770` | Nega qualquer acesso a "outros" na visão de serviço |
| `chmod-ignore`, `chown-ignore` | Tentativas de alterar permissões/dono através da visão (clientes SFTP às vezes tentam "preservar permissões" no upload) são aceitas e ignoradas — em NTFS elas não teriam efeito de qualquer forma (Capítulo 11) |
| `allow_other` | Montagens FUSE, por padrão, só são visíveis ao usuário que montou (root, via fstab); esta opção permite que o `<TRANSFER_USER>` (via sshd) a enxergue |
| `noexec,nosuid,nodev` | Nada trazido pela VM é executável, setuid ou dispositivo através da visão de serviço |
| `nofail` | Ausência do HD2 não trava o boot (mesma proteção do Capítulo 11) |
| `x-systemd.requires=/mnt/docs4` | Ordena esta montagem para depois da montagem do HD2 |

```bash
sudo mount -a
mount | grep airlock
sudo -u <TRANSFER_USER> touch /srv/airlock/files/teste-escrita.txt
ls -la /mnt/docs4/airlock/
sudo -u <TRANSFER_USER> rm /srv/airlock/files/teste-escrita.txt
```

**O que fazem:** ativam a montagem e provam o desenho de ponta a ponta: um arquivo criado pelo `<TRANSFER_USER>` na visão de serviço aparece imediatamente na pasta real do HD2 (e vice-versa).

### 4. Servidor SSH

```bash
sudo apt install -y openssh-server
sudo mkdir -p /etc/ssh/authorized_keys
sudo chmod 755 /etc/ssh/authorized_keys
sudo nano /etc/ssh/sshd_config.d/10-airlock.conf
```

Conteúdo completo do arquivo `10-airlock.conf`:

```text
# Endurecimento global - a porta 22 fica alcancavel pela VM (ver Explicacao).
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no

# Confinamento do usuario de transferencia do airlock
Match User <TRANSFER_USER>
    ChrootDirectory /srv/airlock
    ForceCommand internal-sftp -u 0007
    AuthorizedKeysFile /etc/ssh/authorized_keys/%u
    PubkeyAuthentication yes
    AllowTcpForwarding no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTunnel no
```

**Por quê cada diretiva:**

- `ChrootDirectory /srv/airlock`: tranca a sessão dentro da base do chroot — o cliente não enxerga nada do host além de `files/`, mesmo que a credencial vaze.
- `ForceCommand internal-sftp`: desabilita shell e execução remota; só transferência de arquivos é permitida. O `-u 0007` aplica um umask coerente com a visão `0770`.
- `AuthorizedKeysFile /etc/ssh/authorized_keys/%u`: a conta não tem home; a chave pública fica em arquivo sob controle do root, fora do alcance de escrita do próprio usuário de transferência (endurecimento adicional).
- `AllowTcpForwarding`/`AllowAgentForwarding`/`X11Forwarding`/`PermitTunnel` em `no`: eliminam qualquer uso do canal SSH além do SFTP (nenhum túnel, nenhum repasse).

> **📝 NOTA:** No Ubuntu/Pop!_OS, o `sshd_config` principal inclui `sshd_config.d/*.conf` **no topo** do arquivo, e no sshd vale a **primeira** ocorrência de cada diretiva — por isso um drop-in com prefixo baixo (`10-`) tem precedência determinística sobre o restante da configuração, sem editar o arquivo principal.

```bash
sudo sshd -t
sudo systemctl enable --now ssh
sudo systemctl reload ssh
```

**O que fazem:** `sshd -t` valida a sintaxe (saída vazia = correta) **antes** de aplicar — nunca recarregue com erro de sintaxe; `enable --now` habilita e inicia o serviço (nome da unidade no Ubuntu/Pop: `ssh`); `reload` aplica a configuração às novas conexões.

### 5. Chave dentro do Windows e instalação no host

Dentro da VM, em PowerShell:

```powershell
mkdir $env:USERPROFILE\.ssh -Force | Out-Null
ssh-keygen -t ed25519 -f $env:USERPROFILE\.ssh\airlock -C "airlock-vm"
Get-Content $env:USERPROFILE\.ssh\airlock.pub
```

**O que fazem:** geram o par de chaves — a privada (`airlock`) permanece na VM; a pública (`airlock.pub`) é a linha única de ~80 caracteres exibida pelo último comando. O cliente OpenSSH é componente padrão do Windows 11; se `ssh-keygen` não for reconhecido, instale em Configurações → Aplicativos → Recursos opcionais → "Cliente OpenSSH".

Leve a **linha pública** ao host (é pública por definição: pode ser digitada manualmente, levada por pen drive, ou copiada pelo console do Virt-Manager) e instale-a:

```bash
sudo nano /etc/ssh/authorized_keys/<TRANSFER_USER>     # colar a linha unica: ssh-ed25519 AAAA... airlock-vm
sudo chown root:root /etc/ssh/authorized_keys/<TRANSFER_USER>
sudo chmod 644 /etc/ssh/authorized_keys/<TRANSFER_USER>
```

**O que fazem:** criam o arquivo de chaves autorizadas do `<TRANSFER_USER>` no caminho definido pelo `AuthorizedKeysFile`, legível pelo sshd e imutável para o próprio usuário de transferência.

> **💡 DICA:** Proteger a chave privada com passphrase é opcional aqui: a ameaça deste modelo é a própria VM e, uma vez comprometida, ela captura a passphrase no momento do uso. O confinamento real vem do chroot + `ForceCommand`, não da passphrase.

### 6. Firewall (ufw)

Defina `<INTERFACE_AIRLOCK>` como `br0`/`REDE_BRIDGE` em bridge ou como `virbr-vmnat`/`REDE_BRIDGE_LIBVIRT` em NAT. Para a etapa 61, o comentário `SFTP airlock - somente VM Windows` é a identidade da regra: ela captura **todas** as ocorrências, falha fechado se qualquer uma não tiver exatamente o formato esperado, remove cada regra com o comentário exato (sem fallback permissivo), confirma cardinalidade zero, adiciona a atual e exige exatamente uma regra marcada e exata para interface, IP, porta 22 e TCP.

```bash
sudo apt install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow in on <INTERFACE_AIRLOCK> from <VM_IP_FIXO> to any port 22 proto tcp comment 'SFTP airlock - somente VM Windows'
```

> **⚠️ ALERTA:** Se você administra este host por SSH a partir de **outro** dispositivo, adicione a regra correspondente **antes** do `ufw enable` (ex.: `sudo ufw allow from <IP_DO_DISPOSITIVO_ADMIN> to any port 22 proto tcp`), ou a próxima conexão desse dispositivo será bloqueada. O console local nunca é afetado pelo ufw.

```bash
sudo ufw enable
sudo ufw status verbose
```

**O que fazem:** com `deny incoming`, tudo que não for explicitamente liberado é bloqueado. A regra combina interface do backend, `<VM_IP_FIXO>`, porta 22 e TCP. `bash etapas/61-airlock.sh --verificar` exige `total marcado=1` e `exato=1`; qualquer regra residual ou marcada mas não parseável reprova.

> **📝 NOTA:** O ufw filtra tráfego destinado ao host. Em bridge, o encaminhamento L2 normal da VM não é bloqueado por essa regra; em NAT, o libvirt mantém suas próprias regras de saída. Acesso da VM ao airlock não exige port-forward em nenhum modo.

### 7. Criação automática e idempotente (hook `00-airlock.sh`)

```bash
sudo nano /etc/libvirt/hooks/qemu.d/<VM_NAME>/prepare/begin/00-airlock.sh
```

```bash
#!/bin/bash
# 00-airlock.sh
# Garante a pasta de transito e sua visao de servico antes da preparacao da GPU.
# Projetado para NUNCA impedir o inicio da VM: qualquer falha aqui apenas
# registra um aviso no journal (via logger) e o script termina com sucesso.

AIRLOCK_NTFS="/mnt/docs4/airlock"
AIRLOCK_BIND="/srv/airlock/files"

# 1) O HD2 precisa estar montado; sem ele, criar a pasta poluiria o ponto
#    de montagem vazio no NVMe, e nao o HD2 real (alerta do Capitulo 11).
if ! mountpoint -q /mnt/docs4; then
    logger -t hook-qemu "AVISO: /mnt/docs4 nao montado; airlock indisponivel nesta sessao da VM."
    exit 0
fi

# 2) Cria a pasta de transito, se ausente (idempotente).
#    Sem chown/chmod: em NTFS (ntfs-3g), dono e permissoes vem das opcoes
#    de montagem do fstab (Capitulo 11) e nao podem ser alterados por pasta.
if [ ! -d "$AIRLOCK_NTFS" ]; then
    mkdir -p "$AIRLOCK_NTFS" && logger -t hook-qemu "pasta airlock criada em $AIRLOCK_NTFS"
fi

# 3) Garante a visao de servico (bindfs) montada, usando a entrada do fstab.
if ! mountpoint -q "$AIRLOCK_BIND"; then
    if mount "$AIRLOCK_BIND" 2>/dev/null; then
        logger -t hook-qemu "visao bindfs do airlock montada em $AIRLOCK_BIND"
    else
        logger -t hook-qemu "AVISO: falha ao montar $AIRLOCK_BIND (verifique a linha bindfs no fstab)."
    fi
fi

exit 0
```

```bash
sudo chmod +x /etc/libvirt/hooks/qemu.d/<VM_NAME>/prepare/begin/00-airlock.sh
```

**Explicação:**

- O prefixo `00-` garante, pela ordem alfabética do dispatcher (Capítulo 19), execução **antes** do `01-gpu-para-vfio.sh` — sem tocar nesse script, que usa `set -e` e não deve receber comandos com falha tolerada.
- O script **nunca retorna erro**, deliberadamente: a VM não depende do airlock para funcionar, e um problema na pasta de transferência não deve impedir o uso da máquina. Esta é uma divergência consciente em relação ao errata que originou este capítulo (que sugeria abortar): aqui, a falha vira um aviso rastreável com `journalctl -t hook-qemu`.
- O `mount "$AIRLOCK_BIND"` reutiliza a definição do fstab (seção 3), mantendo a configuração da montagem em um único lugar.

### 8. Cliente no Windows (WinSCP)

1. Instale o WinSCP (`winscp.net`) dentro da VM — ou use o cliente nativo do Windows: `sftp -i $env:USERPROFILE\.ssh\airlock <TRANSFER_USER>@<IP_FIXO_HOST>`.
2. Nova sessão: protocolo **SFTP**; Host: `<IP_FIXO_HOST>` (IP LAN do host em bridge; gateway da bridge virtual em NAT); porta `22`; usuário `<TRANSFER_USER>`.
3. Em Advanced → SSH → Authentication → "Private key file", aponte para `%USERPROFILE%\.ssh\airlock` (o WinSCP oferece converter a chave para o formato `.ppk` — aceite).
4. Salve a sessão e conecte. Na primeira conexão, confirme a impressão digital do servidor — para conferir, execute no host: `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`.
5. A sessão abre diretamente em `/files` (a pasta airlock). Arraste arquivos nos dois sentidos normalmente.

### 9. Alternativa: Samba hardenizado

Somente se preferir unidade mapeada no Explorer em vez do WinSCP — neste caso, **não configure o SFTP** (mantenha a superfície mínima: um método só).

```bash
sudo apt install -y samba
sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.bak-$(date +%Y%m%d)
sudo nano /etc/samba/smb.conf
```

Na seção `[global]` **existente**, adicione:

```ini
   server min protocol = SMB3
   server signing = mandatory
   smb encrypt = required
   disable netbios = yes
   smb ports = 445
```

Ao final do arquivo, adicione a share:

```ini
[airlock]
   path = /srv/airlock/files
   valid users = <TRANSFER_USER>
   read only = no
   guest ok = no
   browseable = yes
```

**Por quê cada parâmetro:** `server min protocol = SMB3` exclui SMB1/SMB2 (elimina a classe de ataques do SMB legado — ex.: EternalBlue explora SMBv1); `server signing = mandatory` + `smb encrypt = required` forçam assinatura e criptografia de todo o tráfego; `disable netbios` e `smb ports = 445` desligam os serviços de nomes legados (porta 139); `valid users` restringe ao usuário dedicado; `guest ok = no` elimina acesso anônimo. A share aponta para a **visão bindfs**, então o `smbd` opera como `<TRANSFER_USER>` com o mesmo confinamento do método SFTP, sem necessidade de `force user`.

> **📝 NOTA:** `server min protocol` e `server signing` são parâmetros **globais** do Samba: colocados dentro da seção da share, seriam ignorados com aviso — erro presente na primeira versão do errata que originou este capítulo, corrigido aqui. O nome correto do parâmetro de assinatura é `server signing` (não existe `smb signing`).

```bash
sudo smbpasswd -a <TRANSFER_USER>
sudo smbpasswd -e <TRANSFER_USER>
testparm
sudo systemctl enable --now smbd
sudo ufw allow in on <INTERFACE_AIRLOCK> from <VM_IP_FIXO> to any port 445 proto tcp comment 'Samba airlock - somente VM Windows'
```

**O que fazem:** o Samba mantém uma base de senhas própria — `smbpasswd -a` cria a senha SMB do usuário (independente da senha de sistema, que a conta não tem) e `-e` habilita a conta; `testparm` valida a sintaxe do `smb.conf`; as demais linhas ativam o serviço e liberam a porta 445 apenas para a VM.

No Windows: Explorador de Arquivos → Este Computador → "Mapear unidade de rede" → `\\<IP_FIXO_HOST>\airlock`, marcando "Conectar usando credenciais diferentes" e informando `<TRANSFER_USER>` e a senha SMB.

### 10. Método de emergência: montagem manual do HD1 (somente leitura)

Para o caso excepcional de precisar ler o HD1 pelo Linux (ex.: a VM não inicializa e um arquivo precisa ser resgatado):

```bash
virsh --connect qemu:///system domstate <VM_NAME>
```

**O que faz:** confirma o estado da VM. **Só prossiga se a resposta for `shut off`** (desligada por completo — não `paused`, não `running`).

```bash
lsblk -f /dev/disk/by-id/<HD1_BY_ID_PATH>
sudo mkdir -p /mnt/hd1-ro
sudo mount -o ro,noexec,nosuid,nodev /dev/disk/by-id/<HD1_BY_ID_PATH>-part<N> /mnt/hd1-ro
```

**O que fazem:** o `lsblk -f` identifica a partição NTFS de dados do HD1 (a de maior tamanho, `FSTYPE ntfs`) — o número dela substitui `<N>` no sufixo `-part<N>`. A montagem usa `ro` (somente leitura: o HD1 é o disco "não confiável" do ambiente e jamais deve ser escrito pelo host) e `noexec,nosuid,nodev` (nada executável a partir dele). Após copiar o necessário:

```bash
sudo umount /mnt/hd1-ro
```

> **🛑 PONTO DE NÃO RETORNO:** Como estabelecido no Capítulo 19, **nunca** monte o HD1 com a VM ligada, e **sempre** desmonte antes de religá-la — NTFS não suporta montagem dupla, e a combinação corrompe o sistema de arquivos.

> **⚠️ ALERTA:** Se o Windows tiver sido desligado com a Inicialização Rápida ativa (o Capítulo 18 orienta desativá-la), o NTFS fica marcado como em uso e o `ntfs-3g` recusará a montagem (ou exigirá opções de força que **não** devem ser usadas). Nesse caso: ligue a VM, desligue-a corretamente por completo, e repita o procedimento.

## Arquivos modificados

- `/etc/fstab` (1 linha adicionada: montagem bindfs da visão de serviço).
- `/etc/ssh/sshd_config.d/10-airlock.conf` (criado).
- `/etc/ssh/authorized_keys/<TRANSFER_USER>` (criado).
- `/etc/libvirt/hooks/qemu.d/<VM_NAME>/prepare/begin/00-airlock.sh` (criado).
- `/srv/airlock/` e `/srv/airlock/files/` (criados, ext4/NVMe).
- `/mnt/docs4/airlock/` (criado, NTFS/HD2).
- `/etc/passwd`, `/etc/group` (usuário `<TRANSFER_USER>` e grupo `airlock-transfer`).
- Regras persistentes do ufw (geridas pelos comandos `ufw`).
- Somente na alternativa Samba: `/etc/samba/smb.conf` (+ backup datado) e base de senhas SMB.
- Dentro do Windows: par de chaves em `%USERPROFILE%\.ssh\` e sessão salva do WinSCP.

## Como verificar

Cada verificação abaixo cobre uma camada independente do desenho:

1. **Visão de serviço:** `mount | grep airlock` mostra a montagem `fuse.bindfs`; o teste de escrita da seção 3 (arquivo criado em `/srv/airlock/files` aparece em `/mnt/docs4/airlock`).
2. **Configuração do sshd:** `sudo sshd -t` sem saída; `systemctl status ssh` ativo.
3. **Transferência real:** conectar pelo WinSCP na VM → a sessão abre em `/files`; enviar um arquivo → ele aparece em `/mnt/docs4/airlock` no host; criar um arquivo no host → ele aparece no WinSCP.
4. **Confinamento:** no WinSCP, navegar para o diretório raiz (`/`) → deve exibir apenas `files/` (nenhum diretório do host visível).
5. **Autenticação:** da VM, `ssh <TRANSFER_USER>@<IP_FIXO_HOST>` **sem** a chave → recusa imediata com `Permission denied (publickey)` (senha nem sequer é oferecida). Com a chave, a mesma tentativa não abre shell (`ForceCommand` em ação).
6. **Escopo/cardinalidade do firewall:** `sudo ufw show added` contém exatamente uma regra com o comentário `SFTP airlock - somente VM Windows`, e ela corresponde a `<INTERFACE_AIRLOCK>`, `<VM_IP_FIXO>`, porta 22 e TCP. `bash etapas/61-airlock.sh --verificar` deve reportar `marcado=1/exato=1`.
7. **Hook:** com a VM desligada, `sudo umount /srv/airlock/files`; iniciar a VM; `journalctl -t hook-qemu -b` deve registrar a remontagem, e `mount | grep airlock` volta a exibir a visão de serviço.

## Resultado esperado

Um único canal de troca de arquivos entre host e VM, com todas as propriedades do desenho: a VM (e somente ela, no firewall) alcança somente a pasta airlock; autenticação exclusivamente por chave, com conta dedicada sem shell; pastas reais do HD2 inalcançáveis por qualquer serviço de rede; arquivos em trânsito sem bit de execução na visão de serviço; sshd do host endurecido (sem senha, sem root); pasta recriada automaticamente a cada início da VM.

## Como desfazer

```bash
sudo ufw --force delete allow in on <INTERFACE_AIRLOCK> from <VM_IP_FIXO> to any port 22 proto tcp comment 'SFTP airlock - somente VM Windows'
sudo rm /etc/ssh/sshd_config.d/10-airlock.conf
sudo sshd -t && sudo systemctl reload ssh
sudo rm /etc/ssh/authorized_keys/<TRANSFER_USER>
sudo rm /etc/libvirt/hooks/qemu.d/<VM_NAME>/prepare/begin/00-airlock.sh
sudo umount /srv/airlock/files
sudo nano /etc/fstab        # remover a linha do bindfs
sudo rm -rf /srv/airlock
sudo deluser --system <TRANSFER_USER>
sudo delgroup airlock-transfer
sudo apt remove --purge -y bindfs
```

**O que fazem:** revertem em ordem segura — firewall, configuração do sshd (validando antes de recarregar), chave, hook, montagem, fstab, estrutura no NVMe, conta e pacote. A pasta `/mnt/docs4/airlock` (e o que houver em trânsito nela) permanece no HD2; remova-a manualmente se desejar. Na alternativa Samba: `sudo smbpasswd -x <TRANSFER_USER>`, remover a share e os parâmetros adicionados do `smb.conf` (ou restaurar o backup datado) e `sudo systemctl disable --now smbd`.

## Problemas comuns

| Sintoma | Causa provável | Correção |
|---|---|---|
| Conexão SFTP cai imediatamente; journal do `ssh` registra "bad ownership or modes for chroot directory" | `/srv/airlock` não pertence a `root:root`, ou tem permissão mais aberta que `755` | Reaplicar `chown root:root` e `chmod 755` em `/srv/airlock` (seção 2) |
| `Permission denied (publickey)` mesmo com a chave configurada | Linha pública ausente/quebrada em `/etc/ssh/authorized_keys/<TRANSFER_USER>`, ou nome do arquivo diferente do nome do usuário | Conferir o arquivo (linha única iniciando com `ssh-ed25519`) e `journalctl -u ssh -e` |
| Login abre, mas não é possível gravar (ou a pasta aparece vazia) | Visão bindfs não montada — a sessão caiu no diretório vazio `files/` do ext4 | `sudo mount /srv/airlock/files`; conferir a linha do fstab e os avisos do hook (`journalctl -t hook-qemu`) |
| `mount: unknown filesystem type 'fuse.bindfs'` | Pacote `bindfs` não instalado | `sudo apt install bindfs` |
| A VM não alcança o host na porta 22 | IP real da VM difere de `<VM_IP_FIXO>` (reserva DHCP não aplicada), ou regra do ufw ausente | `ipconfig` na VM; conferir a reserva no roteador; `sudo ufw status verbose` |
| Outro dispositivo da LAN consegue conectar na porta 22 | Regra ufw permissiva antiga, ou ufw desabilitado | `sudo ufw status verbose`; remover regras amplas; `sudo ufw enable` |
| Windows rejeita ou exibe errado um nome de arquivo criado no Linux | Proteção `windows_names` do Capítulo 11 em ação (caractere fora do padrão do Windows) | Renomear o arquivo no lado que o criou |
| Após recriar a VM com outro nome, a pasta não é mais criada automaticamente | O diretório de hooks é por nome de VM (`qemu.d/<VM_NAME>`, Capítulo 19) | Recriar a estrutura de hooks para o novo nome e reinstalar o `00-airlock.sh` |

## Próxima etapa

Capítulo 25 — TRIM, Snapshots e Backup. (A pasta airlock é zona de trânsito e fica deliberadamente fora do escopo de backup do próximo capítulo.)

---

# Capítulo 25 — TRIM, Snapshots e Backup

## Objetivo

Garantir que comandos TRIM emitidos pelo Windows dentro da VM cheguem efetivamente ao SSD NVMe físico subjacente (mantendo desempenho de longo prazo do disco), configurar snapshots do disco QCOW2 para pontos de restauração rápidos, e estabelecer uma rotina de backup real do arquivo de disco da VM.

## Pré-requisitos

- Capítulo 18 concluído (Windows instalado com drivers VirtIO).
- Capítulo 19 concluído (GPU/HD1 em passthrough).

## Explicação

### TRIM em ambiente virtualizado

**O que é TRIM:** comando enviado por um sistema de arquivos a um SSD, informando quais blocos de dados não estão mais em uso (arquivos apagados), permitindo que o controlador do SSD os recicle proativamente durante operações de manutenção interna (garbage collection), mantendo o desempenho de escrita ao longo do tempo. Sem TRIM, um SSD gradualmente considera todos os blocos já escritos como "em uso" do seu próprio ponto de vista, mesmo que o sistema de arquivos os tenha marcado como livres, degradando o desempenho de escrita à medida que o disco se enche de blocos "sujos" na perspectiva do controlador.

**Por que isso é uma preocupação especial em VM:** o comando TRIM, quando emitido pelo NTFS dentro da VM, precisa atravessar três camadas antes de chegar ao SSD físico: o sistema de arquivos guest (NTFS) → o driver VirtIO de disco → o QEMU (que traduz para operações no arquivo `.qcow2`) → o sistema de arquivos do host (ext4, no NVMe) → o SSD físico real. Cada uma dessas camadas precisa suportar e repassar o comando TRIM (chamado de `discard` em contextos Linux/QEMU) para que ele chegue ao hardware.

```bash
lsblk --discard
```
**O que faz:** verifica, para cada dispositivo de bloco do host, incluindo o NVMe, se o suporte a `discard` (TRIM) está presente no nível do dispositivo físico — colunas `DISC-GRAN` (granularidade) e `DISC-MAX` (tamanho máximo de uma operação discard) com valores diferentes de zero confirmam suporte.

### Habilitando discard/TRIM no disco da VM

```bash
virsh --connect qemu:///system edit <VM_NAME>
```

Ajuste o bloco `<disk>` correspondente ao `Windows11.qcow2` (Capítulo 17) adicionando o atributo `discard`:

```xml
<disk type='file' device='disk'>
  <driver name='qemu' type='qcow2' cache='none' discard='unmap'/>
  <source file='/vm/Windows11.qcow2'/>
  <target dev='vda' bus='virtio'/>
</disk>
```

**O que `discard='unmap'` faz:** instrui o QEMU a repassar comandos TRIM/discard recebidos da VM até o arquivo `.qcow2` no host — dentro do arquivo QCOW2, isso libera o bloco correspondente (permitindo que o arquivo diminua de tamanho fisicamente no host, já que a alocação é dinâmica, Capítulo 17) e, adicionalmente, repassa a operação de discard para o próprio SSD NVMe subjacente, se o sistema de arquivos do host (ext4) e o dispositivo físico também suportarem (o que é o caso padrão de qualquer SSD NVMe moderno em Linux).

Dentro do Windows, o TRIM automático já é acionado pela tarefa agendada padrão "Otimizar Unidades" (antigo desfragmentador, que em discos SSD executa TRIM em vez de desfragmentação) — nenhuma configuração adicional dentro do Windows é necessária além de garantir, no Gerenciador de Otimização de Unidades do Windows, que o disco C: está marcado como SSD e a otimização está agendada.

### Snapshots (pontos de restauração rápidos)

**O que são:** um snapshot QCOW2 congela o estado do disco virtual em um determinado instante, permitindo, a qualquer momento posterior, reverter todo o conteúdo do disco a esse estado exato — útil antes de instalar software não testado, atualizações grandes do Windows, ou qualquer alteração arriscada.

> **⚠️ ALERTA:** Snapshots do QCOW2 **não substituem backup** (próxima subseção). Um snapshot ainda depende do mesmo arquivo físico `Windows11.qcow2` e do mesmo disco NVMe — se o SSD falhar fisicamente, todos os snapshots são perdidos junto com o disco.

```bash
bash util/snapshot-vm.sh criar antes-de-atualizar-windows "Snapshot antes de aplicar atualização cumulativa do Windows"
```
**O que faz:** com a VM desligada, identifica o `QCOW2_PATH` realmente ativo no
XML, cria nele um snapshot **interno** nomeado e passa `snapshot=no` para HD1 e
os demais discos. A pós-condição é relida de `snapshot-dumpxml`; um overlay
externo ativo ou metadados externos legados são recusados, pois não seriam
compatíveis com a reversão simples oferecida abaixo.

```bash
bash util/snapshot-vm.sh listar
```
**O que faz:** lista os snapshots associados à VM.

```bash
bash util/snapshot-vm.sh reverter antes-de-atualizar-windows
```
**O que faz:** após confirmação e com a VM desligada, reverte o QCOW2 principal
ao estado interno nomeado, descartando alterações posteriores. Snapshots
externos são bloqueados antes de chamar `snapshot-revert`.

```bash
bash util/snapshot-vm.sh apagar antes-de-atualizar-windows
```
**O que faz:** após confirmação, remove um snapshot interno específico. O
utilitário não tenta apagar ou consolidar automaticamente overlays externos.

> **💡 DICA:** snapshots internos acumulados consomem espaço e continuam no
mesmo QCOW2/disco físico. Remova pontos temporários quando não forem mais
necessários, mas mantenha backups independentes testados.

### Backup real

Diferente de um snapshot (que vive dentro do mesmo arquivo/disco), um backup real é uma **cópia completa e independente** do arquivo de disco, armazenada fisicamente em outro dispositivo — a única proteção real contra falha do NVMe.

```bash
virsh --connect qemu:///system shutdown <VM_NAME>
```
**O que faz:** solicita um desligamento gracioso da VM (via ACPI, repassado ao Windows, que executa seu procedimento normal de desligamento) — importante fazer **antes** de copiar o arquivo `.qcow2`, para garantir que o sistema de arquivos NTFS dentro dele esteja em um estado consistente, sem escritas pendentes em progresso.

```bash
watch virsh --connect qemu:///system domstate <VM_NAME>
```
**O que faz:** aguarda até o estado mudar para `shut off` antes de prosseguir.

```bash
bash util/backup-vm.sh
```
**O que faz:** desliga a VM graciosamente quando autorizado, confirma que
`QCOW2_PATH` é exatamente o `source file` ativo no XML e que o arquivo não tem
`backing-filename`, então copia com preservação sparse, executa `qemu-img check`
e repete a prova de independência na cópia. Se houver overlay/cadeia externa,
aborta antes de copiar uma base antiga. XML inativo, NVRAM e TPM são incluídos
quando disponíveis; HD1 e outros discos ficam listados como fora do escopo.

> **📝 NOTA:** Como o HD2 está fisicamente no mesmo computador (embora em disco separado do NVMe), este backup protege contra falha do **SSD NVMe especificamente**, mas não contra eventos que afetem o computador inteiro (incêndio, roubo, surto elétrico que danifique múltiplos discos simultaneamente). Para proteção completa, recomenda-se adicionalmente uma cópia periódica em mídia verdadeiramente externa/offsite — fora do escopo operacional deste documento, mas fortemente recomendada como prática complementar.

```bash
sudo mkdir -p /mnt/docs4/backups-vm
```
**O que faz:** cria o diretório de destino dos backups, executado uma única vez antes do primeiro backup.

## Comandos

```bash
lsblk --discard
virsh --connect qemu:///system edit <VM_NAME>   # adicionar discard='unmap' ao disco
bash util/snapshot-vm.sh criar <nome-do-snapshot> "<descrição>"
bash util/snapshot-vm.sh listar
bash util/snapshot-vm.sh reverter <nome-do-snapshot>
bash util/snapshot-vm.sh apagar <nome-do-snapshot>
bash util/backup-vm.sh
```

## Arquivos modificados

- `/etc/libvirt/qemu/<VM_NAME>.xml` (atributo `discard='unmap'` adicionado ao disco).
- `/mnt/docs4/backups-vm/` (diretório criado, recebe cópias de backup).
- Metadados internos do `QCOW2_PATH` (somente o disco principal recebe `snapshot=internal`; os demais recebem `snapshot=no`).
- Diretório datado em `BACKUPS_VM_DIR`, somente quando o QCOW2 ativo não possui backing chain.

## Como verificar

```bash
qemu-img info /vm/Windows11.qcow2
```
**Critério de sucesso:** o tamanho físico atual do arquivo (`disk size`) diminui após TRIM ser executado dentro do Windows e o arquivo ter blocos liberados, refletindo o repasse correto do `discard`.

```bash
virsh --connect qemu:///system snapshot-list <VM_NAME>
```
**Critério de sucesso:** lista os snapshots criados, com timestamps corretos.

```bash
ls -lh /mnt/docs4/backups-vm/
qemu-img info /mnt/docs4/backups-vm/Windows11-backup-<data>.qcow2
```
**Critério de sucesso:** o arquivo de backup existe, com tamanho coerente com o original, e `qemu-img info` consegue lê-lo sem erro (confirmando que a cópia não está corrompida).

## Resultado esperado

TRIM/discard repassado corretamente do NTFS dentro da VM até o SSD NVMe físico; mecanismo de snapshots disponível para pontos de restauração rápidos antes de alterações arriscadas; rotina de backup real do disco da VM estabelecida, com cópias armazenadas no HD2, fisicamente separado do NVMe.

## Como desfazer

```bash
virsh --connect qemu:///system edit <VM_NAME>   # remover discard='unmap'
bash util/snapshot-vm.sh apagar <nome-do-snapshot>
rm /mnt/docs4/backups-vm/Windows11-backup-<data>.qcow2
```

## Problemas comuns

| Sintoma | Causa provável | Correção |
|---|---|---|
| Arquivo `.qcow2` não diminui de tamanho mesmo após apagar arquivos grandes dentro do Windows | `discard='unmap'` não configurado, ou otimização automática do Windows desabilitada para o disco C: | Revisar o XML da VM; verificar "Otimizar Unidades" dentro do Windows |
| O utilitário recusa `reverter`/`apagar` por snapshot externo | Snapshot legado criado com `--disk-only`, gerando overlay incompatível com `snapshot-revert` simples | Não apague arquivos da cadeia; consolide manualmente com ferramentas do libvirt/qemu ou restaure um backup testado |
| O backup recusa overlay ou backing file | O XML não aponta diretamente para `QCOW2_PATH`, ou o QCOW2 depende de outro arquivo | Consolide a cadeia externa antes do backup; copiar apenas a base produziria estado antigo |
| Backup demora muito tempo / consome muito espaço no HD2 | Arquivo `.qcow2` já grande devido a jogos instalados no disco C: em vez de HD1 | Reforçar a prática de instalar jogos/aplicativos grandes em HD1 (D: dentro do Windows), mantendo C: (`Windows11.qcow2`) relativamente enxuto, conforme o desenho original do Capítulo 2 |

## Próxima etapa

Capítulo 26 — Atualizações e Manutenção Contínua.

---

# Capítulo 26 — Atualizações e Manutenção Contínua

## Objetivo

Estabelecer o procedimento seguro de atualização do host (kernel, driver NVIDIA, pacotes de virtualização) e da VM (Windows Update, driver NVIDIA guest), minimizando o risco de quebrar a configuração de passthrough a cada atualização.

## Pré-requisitos

- Ambiente totalmente configurado (Capítulos 1 a 25 concluídos).

## Explicação

### Por que atualizações são um ponto de risco em ambientes de passthrough

Diferente de um desktop Linux comum, este ambiente tem múltiplos pontos de acoplamento sensível a versões específicas:

- Atualizações de **kernel** podem, raramente, alterar o comportamento de reset de dispositivos PCI (function-level reset) ou nomes de módulos, afetando os hook scripts do Capítulo 19.
- Atualizações do **driver NVIDIA no host** podem, temporariamente, mudar nomes ou dependências de módulos (`nvidia`, `nvidia_drm`, etc.), exigindo revisão dos scripts de hook.
- Atualizações do **libvirt/QEMU** podem alterar nomes de atributos XML ou comportamento padrão de determinadas opções.
- Atualizações do **driver NVIDIA dentro da VM** raramente causam problemas de passthrough em si, mas seguem seu próprio ciclo de testes recomendado antes de aplicar em uma máquina de uso diário.

### Procedimento recomendado de atualização do host

1. **Antes de atualizar:** criar um snapshot da VM (Capítulo 25) e confirmar que um backup recente existe.
2. **Atualizar em uma janela de teste**, não imediatamente antes de uma sessão de jogo importante.

```bash
sudo apt update
sudo apt full-upgrade -y
```

3. **Antes de reiniciar**, verificar especificamente se o pacote do driver NVIDIA foi atualizado:

```bash
apt list --upgradable 2>/dev/null | grep -i nvidia
```

4. Reiniciar:

```bash
sudo reboot
```

5. **Após reiniciar, validar cada camada, em ordem, antes de considerar a atualização bem-sucedida:**

```bash
nvidia-smi
```
**Critério de sucesso:** driver NVIDIA funcional no host (desktop Linux normal).

```bash
cat /proc/cmdline | grep -o "amd_iommu=on iommu=pt"
sudo dmesg | grep -i "AMD-Vi"
```
**Critério de sucesso:** parâmetros de IOMMU ainda ativos (confirma que a atualização de kernel não afetou os parâmetros persistidos pelo `kernelstub`/GRUB).

```bash
virsh --connect qemu:///system start <VM_NAME>
```
**Critério de sucesso:** a VM inicia normalmente, a GPU é assumida corretamente (hook script `prepare/begin` funcionando), e o Windows inicializa exibindo vídeo através da RTX 3060.

6. Desligar a VM e confirmar que a GPU retorna ao Linux (hook `release/end`).

### Procedimento de atualização dentro da VM

Windows Update, dentro da VM, opera de forma equivalente a uma máquina física — nenhuma consideração especial de passthrough é necessária para atualizações cumulativas do Windows em si. A única recomendação específica deste ambiente:

> **💡 DICA:** Antes de uma grande atualização de funcionalidade do Windows (as atualizações semestrais/anuais maiores, não as cumulativas mensais de segurança), crie um snapshot (Capítulo 25) — essas atualizações maiores ocasionalmente reconfiguram drivers de dispositivo automaticamente, e reverter via snapshot é mais rápido que reinstalar o driver NVIDIA manualmente caso algo saia do esperado.

Atualizações do driver NVIDIA dentro da VM seguem o procedimento padrão já descrito no Capítulo 18 (download do site oficial, instalação limpa).

## Comandos

```bash
bash util/atualizar-host.sh
# O utilitário delega a util/snapshot-vm.sh e só considera proteção válida
# depois de comprovar snapshot interno; sem ele exige CONTINUAR SEM SNAPSHOT.
sudo reboot
bash util/atualizar-host.sh --validar
```

## Arquivos modificados

- Pacotes do sistema (via `apt`), variando conforme as atualizações disponíveis a cada execução.

## Como verificar

Seguir integralmente a sequência de validação em camadas descrita na explicação acima (driver NVIDIA no host → parâmetros de IOMMU → início da VM → passthrough da GPU → retorno da GPU ao desligar).

## Resultado esperado

Host e VM atualizados de forma segura e verificada, com cada camada da pilha de passthrough confirmada funcional após cada atualização, e um snapshot de segurança disponível para reversão rápida em caso de regressão inesperada.

## Como desfazer

```bash
bash util/snapshot-vm.sh reverter antes-atualizacao-host-<data-hora>
```

Para reverter uma atualização do host que causou regressão, selecionar o kernel anterior no menu de boot (Advanced options, conforme Capítulo 7) enquanto se investiga a causa antes de remover definitivamente o kernel novo.

## Problemas comuns

| Sintoma | Causa provável | Correção |
|---|---|---|
| Após atualização de kernel, hook scripts falham silenciosamente | Nome de módulo do driver NVIDIA mudou entre versões (raro, mas documentado historicamente em transições de branch do driver) | Revisar `lsmod \| grep nvidia` e ajustar os nomes de módulo nos scripts do Capítulo 19, se necessário |
| Atualização do driver NVIDIA no host quebra o passthrough | Versão de driver instável para esta combinação específica de hardware (raro) | Reverter para a versão anterior do driver via `apt install nvidia-driver-<versão-anterior>` |
| VM não inicia após atualização do libvirt/QEMU | Sintaxe XML deprecada em uma versão nova | Consultar `sudo journalctl -u libvirtd -e` para a mensagem de erro específica; revisar release notes do pacote `libvirt-daemon-system` |

## Próxima etapa

Capítulo 27 — Benchmarks.

---

# Capítulo 27 — Benchmarks

## Objetivo

Estabelecer um conjunto de testes objetivos para medir e comparar o desempenho da VM com GPU passthrough, permitindo validar o impacto de cada ajuste feito nos Capítulos 21-23 (CPU pinning, HugePages, isolamento, MSI) e detectar regressões futuras.

## Pré-requisitos

- Ambiente completo até o Capítulo 23.

## Explicação

### Por que medir, e não apenas "sentir"

Ajustes de desempenho em passthrough (CPU pinning, HugePages, isolamento) frequentemente produzem diferenças sutis, mais perceptíveis como redução de microengasgos ocasionais do que como aumento de taxa média de quadros por segundo. Sem medição objetiva (especialmente de métricas de **1% low** — a taxa de quadros dos piores 1% dos quadros renderizados, métrica muito mais sensível a stuttering do que a média simples), é fácil superestimar ou subestimar o efeito real de uma mudança.

### Ferramentas recomendadas dentro da VM

| Ferramenta | Finalidade |
|---|---|
| **3DMark** (Time Spy / Fire Strike) | Benchmark sintético de GPU, permite comparação direta com resultados publicados de hardware idêntico rodando nativamente (bare metal), quantificando o "overhead de virtualização" |
| **MSI Afterburner + RivaTuner Statistics Server** | Sobreposição de FPS, 1% low, uso de GPU/CPU e temperatura em tempo real, durante jogos reais |
| **CrystalDiskMark** | Benchmark de I/O de disco, útil para validar o ganho de desempenho de `cache='none'` e VirtIO no disco do sistema e no HD1 |
| **Contador de desempenho do Windows (`perfmon`)** | Monitoramento de uso de CPU por núcleo lógico dentro da VM, para confirmar que a topologia de CPU (Capítulo 21) está sendo utilizada como esperado pelo Windows |

### Procedimento de benchmark comparativo

1. **Antes de qualquer ajuste de desempenho** (ainda no estado do Capítulo 18/19, sem CPU pinning refinado, sem HugePages), execute o benchmark escolhido (por exemplo, 3DMark Time Spy) três vezes, registrando a pontuação e a variação entre execuções.
2. Aplique **um** ajuste de cada vez (por exemplo, apenas CPU pinning do Capítulo 21, sem ainda aplicar HugePages ou isolamento).
3. Repita o benchmark três vezes.
4. Compare as médias e, principalmente, a variação da pontuação entre as execuções — uma redução na variação é tão relevante quanto (ou mais relevante que) um aumento na pontuação média, pois indica maior consistência de desempenho.
5. Repita o processo para cada ajuste subsequente (HugePages, isolamento, MSI), mantendo um registro tabulado.

```text
Exemplo de tabela de registro a ser preenchida pelo leitor (valores meramente ilustrativos do formato):

| Configuração                          | 3DMark (média) | 1% low (jogo X) | Variação entre execuções |
|----------------------------------------|-----------------|-------------------|----------------------------|
| Base (sem ajustes)                     | —               | —                 | —                          |
| + CPU pinning                          | —               | —                 | —                          |
| + CPU pinning + HugePages              | —               | —                 | —                          |
| + CPU pinning + HugePages + isolcpus   | —               | —                 | —                          |
| + tudo acima + MSI                     | —               | —                 | —                          |
```

> **⚠️ ALERTA:** Os valores acima são apenas o **formato** de uma tabela de registro — este documento não fornece números de desempenho esperados, pois estes variam com a versão exata do driver NVIDIA, versão do Windows, versão do QEMU/kernel, e configuração térmica do próprio hardware. Meça sempre no seu próprio ambiente.

### Comparando com desempenho nativo (bare metal), quando possível

Se for viável testar a mesma RTX 3060 em uma instalação Windows nativa temporária (por exemplo, em outro SSD, antes de comprometer o ambiente definitivamente à virtualização) ou consultar resultados de 3DMark publicados publicamente para hardware idêntico (mesmo modelo exato de GPU, CPU e RAM), a comparação direta indica o "overhead de virtualização" real deste ambiente específico — tipicamente entre 1% e 5% de diferença para GPU passthrough bem configurado, mas este documento não assume esse valor como garantido para o seu hardware específico.

## Comandos

Não há comandos de terminal Linux específicos para este capítulo além dos já cobertos (início/parada da VM). Os benchmarks em si rodam inteiramente dentro do ambiente Windows da VM, através das ferramentas gráficas listadas acima.

## Arquivos modificados

Nenhum arquivo de configuração do sistema — apenas registros de medição mantidos pelo leitor (recomenda-se uma planilha ou arquivo de texto simples, versionado junto com este documento).

## Como verificar

Critério de sucesso é a existência de uma tabela de medições preenchida com dados reais do próprio ambiente, permitindo comparação objetiva entre configurações.

## Resultado esperado

Um conjunto de medições de linha de base e pós-ajuste, permitindo afirmar com dados objetivos — não apenas percepção subjetiva — se cada ajuste de desempenho (Capítulos 21-23) trouxe benefício real neste hardware específico.

## Como desfazer

Não aplicável — capítulo de medição, sem alteração de configuração.

## Problemas comuns

| Sintoma | Causa provável | Correção |
|---|---|---|
| Grande variação entre execuções do mesmo benchmark, mesmo após todos os ajustes | Processos de fundo do Windows (Windows Update, indexação) competindo por recursos durante o teste | Pausar atualizações e indexação antes de medir; considerar o modo "Assistente de Jogos" do Windows |
| Pontuação de benchmark muito abaixo do esperado para o hardware | Resizable BAR ou Above 4G Decoding desabilitados na BIOS (Capítulo 12), ou driver NVIDIA desatualizado | Revisar Capítulo 12; atualizar driver conforme Capítulo 18 |

## Próxima etapa

Capítulo 28 — Troubleshooting.

---

# Capítulo 28 — Troubleshooting

## Objetivo

Consolidar, em um único capítulo de referência, os problemas mais frequentes de todo o ambiente descrito neste documento, organizados por sintoma, com causas prováveis e correções — complementando as tabelas específicas já presentes em cada capítulo individual.

## Pré-requisitos

Nenhum — este capítulo é consultado conforme a necessidade surge, em qualquer estágio do documento.

## Explicação

### Metodologia de diagnóstico

Diante de qualquer problema neste ambiente, a metodologia recomendada é isolar a camada exata onde a falha ocorre, seguindo esta ordem (da mais fundamental à mais específica):

```text
1. Firmware (BIOS/UEFI)       — Capítulo 12
2. Kernel/parâmetros de boot  — Capítulo 15, 16
3. Módulos de kernel (vfio, nvidia) — Capítulo 8, 16
4. Daemon libvirtd / QEMU     — Capítulo 13, 14
5. Definição XML da VM        — Capítulo 17, 19, 20, 21, 23, 25
6. Hook scripts               — Capítulo 19, 24
7. Dentro do guest Windows    — Capítulo 18, 20, 22, 24
```

Diagnosticar de baixo para cima (do firmware para o guest) evita perder tempo investigando dentro do Windows um problema cuja causa raiz está, por exemplo, em uma opção de BIOS revertida acidentalmente.

### Problema: "Code 43" da GPU dentro do Windows

**Sintoma:** dentro do Gerenciador de Dispositivos do Windows, a GPU aparece com um ícone de aviso e a mensagem "Windows has stopped this device because it has reported problems. (Code 43)".

**Causa:** historicamente, drivers NVIDIA detectavam ativamente a presença de um hypervisor (via a instrução `CPUID`) e se recusavam a inicializar como medida anti-fraude/anti-cripto-mineração em VMs não identificadas como "confiáveis". A maioria dos drivers NVIDIA recentes já não apresenta esse comportamento para GPUs GeForce em configurações de passthrough padrão, mas o problema ainda pode ocorrer por diversas causas.

**Correções, em ordem de investigação:**

1. Confirmar que `<cpu mode='host-passthrough'>` está configurado (Capítulo 21) — a ocultação incompleta do hypervisor é uma causa comum.
2. Adicionar explicitamente ao XML da VM, dentro do bloco `<features><hyperv>`, elementos que ocultem a assinatura de virtualização do KVM ao driver, se ainda não presentes:

```xml
<features>
  <hyperv>
    <vendor_id state='on' value='randomid123'/>
  </hyperv>
  <kvm>
    <hidden state='on'/>
  </kvm>
</features>
```

**Explicação:** `<kvm><hidden state='on'/></kvm>` instrui o QEMU a ocultar assinaturas de identificação do KVM que, de outra forma, seriam visíveis a softwares dentro do guest via `CPUID` — reduzindo a chance de qualquer verificação de driver rejeitar a GPU por detectar virtualização. `<hyperv><vendor_id .../></hyperv>` similarmente mascara o vendor ID reportado nas extensões Hyper-V emuladas pelo QEMU (usadas para melhorar a integração/desempenho do guest Windows mesmo fora de um Hyper-V real).

3. Testar Resizable BAR desabilitado na BIOS (Capítulo 12), como segunda hipótese.
4. Confirmar que a vBIOS da GPU não requer um dump manual e injeção no XML (necessário em uma minoria de placas mais antigas ou com vBIOS problemática — fora do escopo padrão deste documento, mas documentado extensamente pela comunidade de passthrough caso as etapas acima não resolvam).

### Problema: GPU não retorna ao Linux após desligar a VM ("reset bug")

**Sintoma:** ao desligar a VM, o hook `release/end` (Capítulo 19) executa, mas `nvidia-smi` continua reportando "No devices were found", e o monitor permanece sem sinal.

**Causa:** algumas combinações de GPU/placa-mãe/versão de firmware não executam corretamente um "Function-Level Reset" (FLR) completo ao desvincular do `vfio-pci`, deixando a GPU em um estado que o driver `nvidia` não consegue reinicializar sem um reset físico completo da linha PCIe (equivalente a um novo power-on).

**Correções:**

1. Verificar se a versão de firmware da placa-mãe (Capítulo 3) é a mais recente disponível — atualizações de firmware da ASUS ocasionalmente corrigem comportamento de reset de PCIe.
2. Investigar se a GPU suporta reset via `vfio-pci` com parâmetro adicional (alguns kernels/GPUs se beneficiam de um pequeno atraso adicional entre unbind e bind, adicionável ao script de hook como um `sleep` extra antes do bind ao `vfio-pci` e antes de recarregar o `nvidia`).
3. Como último recurso funcional, um script de recuperação que desliga e religa fisicamente a alimentação da GPU via os pinos de PCIe (recurso avançado, dependente de suporte específico de hardware, tratado como tópico de pesquisa adicional fora do escopo padrão deste documento).
4. Na ausência de solução completa, o Capítulo 29 documenta o procedimento de recuperação via reboot completo do host como contingência confiável.

### Problema: Áudio entrecortado (crackling) através do HDMI da GPU

**Causa provável:** CPU pinning inadequado (Capítulo 21) fazendo com que o processamento de áudio compita por ciclos de CPU com o restante da carga de trabalho, ou buffer de áudio do driver NVIDIA configurado de forma agressiva.

**Correção:** revisar CPU isolation (Capítulo 22); dentro do Windows, aumentar o tamanho do buffer de áudio nas propriedades avançadas do dispositivo de som NVIDIA HD Audio.

### Problema: `virsh --connect qemu:///system start` falha com erro relacionado a `vfio-pci`/IOMMU

**Sintoma:** mensagem como "vfio: error, group ... is not viable" ou "Failed to open /dev/vfio/X".

**Causa provável:** o grupo IOMMU da GPU (Capítulo 16) contém outro dispositivo ainda vinculado a um driver de host, impedindo que o grupo IOMMU inteiro seja considerado "seguro" para passthrough.

**Correção:** reexecutar o script de listagem de grupos IOMMU (Capítulo 16) e confirmar se **todos** os dispositivos do grupo da GPU estão vinculados ao `vfio-pci` (ou não existem outros dispositivos além da GPU e seu áudio no mesmo grupo).

### Problema: grupo IOMMU da GPU contém dispositivos não relacionados (ACS override)

**Sintoma:** o script de listagem de grupos (Capítulo 16) mostra, no grupo da GPU, outros dispositivos além das funções de vídeo e áudio da própria placa (ex.: uma controladora USB ou de rede), e o início da VM falha com "group ... is not viable".

> **📝 NOTA:** Dispositivos do tipo *PCI bridge* (`pcieport`) no mesmo grupo são normais e **não** impedem o passthrough — não precisam (nem devem) ser vinculados ao `vfio-pci`. O problema real existe apenas com dispositivos de função (endpoints) não relacionados à GPU.

**Correções, em ordem de preferência:**

1. Instalar a GPU em outro slot PCIe x16 físico, se disponível (frequentemente ligado a outra raiz PCIe, com agrupamento mais favorável), e reexecutar a verificação do Capítulo 16.
2. Atualizar o firmware da placa-mãe (Capítulo 12) — fabricantes corrigem o agrupamento ACS em atualizações de BIOS.
3. Avaliar se os dispositivos "extras" podem simplesmente ser repassados juntos à VM (aceitável quando são dispositivos que a VM pode possuir sem prejuízo ao host).
4. **Último recurso — ACS override:** um patch de kernel (não incluído no kernel padrão do Pop!_OS; exige instalar um kernel de terceiros com o patch aplicado) que, através do parâmetro `pcie_acs_override=downstream,multifunction`, força a separação lógica dos grupos IOMMU.

> **⚠️ ALERTA:** O ACS override **mente para o kernel** sobre o isolamento real do barramento: os grupos passam a ser separados apenas logicamente, **sem garantia de isolamento de DMA em hardware** entre eles. Na prática, um dispositivo entregue à VM pode interagir por DMA com dispositivos que permaneceram com o host — a garantia do IOMMU descrita no Capítulo 1 deixa de existir entre os grupos divididos, e uma VM comprometida deixa de estar plenamente contida. Use somente após esgotar as alternativas acima, aceitando formalmente esse risco.

### Problema: Erros de AppArmor bloqueando a VM

**Sintoma:** `journalctl -xe` ou os logs do libvirt mencionam "apparmor" e "DENIED" referenciando caminhos como `/vm/Windows11.qcow2` ou dispositivos `/dev/disk/by-id/...` do HD1.

**Correção:**

```bash
sudo aa-status | grep -i libvirt
sudo journalctl -xe | grep -i apparmor | grep -i denied
```
**O que fazem:** o primeiro lista os perfis AppArmor ativos relacionados a libvirt/QEMU; o segundo localiza a negação específica, revelando exatamente qual caminho foi bloqueado — usar essa informação para revisar o Capítulo 17 (regra `/vm/** rwk,`) e adicionar regra equivalente para o caminho do HD1, se necessário:

```bash
sudo nano /etc/apparmor.d/local/abstractions/libvirt-qemu
```
```text
"/dev/disk/by-id/<HD1_BY_ID_PATH>" rwk,
```
```bash
sudo systemctl reload apparmor
```

## Comandos

Bloco de diagnóstico geral, útil como primeiro passo diante de qualquer problema não listado nas tabelas específicas de cada capítulo:

```bash
{
  echo "== Estado da VM =="; virsh --connect qemu:///system list --all
  echo "== IOMMU =="; sudo dmesg | grep -i -e "AMD-Vi" -e "IOMMU" | tail -n 20
  echo "== Módulos vfio/nvidia =="; lsmod | grep -e vfio -e nvidia
  echo "== Driver atual da GPU =="; lspci -nnk | grep -A3 -i vga
  echo "== Logs recentes do libvirtd =="; sudo journalctl -u libvirtd -e -n 50
  echo "== AppArmor =="; sudo journalctl -xe | grep -i apparmor | grep -i denied | tail -n 20
} | tee ~/inventario-hardware/diagnostico-$(date +%Y%m%d-%H%M).txt
```

## Arquivos modificados

Variável, conforme a correção aplicada (documentado em cada subseção).

## Como verificar

Cada subseção descreve seu próprio critério de sucesso específico.

## Resultado esperado

Um repertório de diagnóstico estruturado, permitindo identificar rapidamente em qual camada da pilha (firmware, kernel, libvirt, XML, hooks, guest) um problema se origina, e aplicar a correção documentada correspondente.

## Como desfazer

Não aplicável de forma geral — cada correção individual lista seu próprio procedimento de reversão nas subseções acima.

## Problemas comuns

Este capítulo é, em si, a tabela consolidada de problemas comuns do documento inteiro. Consulte também as tabelas específicas de cada capítulo individual (16, 17, 19, 21, 22) para sintomas não cobertos aqui.

## Próxima etapa

Capítulo 29 — Recuperação de Emergência.

---

# Capítulo 29 — Recuperação de Emergência

## Objetivo

Documentar os procedimentos de último recurso para restaurar o acesso ao sistema em cenários de falha severa: Linux sem interface gráfica após um hook script falho, sistema que não inicializa após uma alteração de kernel/bootloader, e recuperação a partir de mídia externa.

## Pré-requisitos

- Mídia USB de instalação do Pop!_OS (a mesma do Capítulo 6), mantida disponível permanentemente como ferramenta de recuperação, não apenas durante a instalação inicial.

## Explicação

### Cenário 1: Linux sem interface gráfica após falha no hook `release/end`

**Sintoma:** a VM foi desligada, mas o monitor permanece sem sinal ou preso em uma tela preta; o `gdm3` não reiniciou automaticamente.

**Procedimento de recuperação:**

1. Trocar para um terminal virtual de texto (TTY), que não depende da GPU estar disponível para o modo gráfico:

```text
Ctrl + Alt + F3
```

2. Fazer login com usuário e senha normalmente (a interface de texto do TTY funciona mesmo sem driver de vídeo funcional para o modo gráfico).

3. Executar manualmente o script de devolução da GPU (Capítulo 19):

```bash
sudo /etc/libvirt/hooks/qemu.d/<VM_NAME>/release/end/01-gpu-para-linux.sh
```

4. Se o script falhar em algum ponto específico, executar cada comando dele manualmente, um a um, observando a saída de erro exata:

```bash
sudo modprobe nvidia
sudo modprobe nvidia_modeset
sudo modprobe nvidia_drm
sudo systemctl start gdm3
```

5. Se `modprobe nvidia` falhar com erro relacionado ao dispositivo ainda estar vinculado ao `vfio-pci`:

```bash
GPU_PCI="0000:<GPU_PCI_ID_SEM_PREFIXO>"
GPU_AUDIO_PCI="0000:<GPU_AUDIO_PCI_ID_SEM_PREFIXO>"
echo "$GPU_PCI" | sudo tee /sys/bus/pci/devices/$GPU_PCI/driver/unbind
echo "$GPU_AUDIO_PCI" | sudo tee /sys/bus/pci/devices/$GPU_AUDIO_PCI/driver/unbind
sudo modprobe nvidia
```

6. Se nada disso resolver (GPU presa em um estado que não responde a `unbind`/`modprobe`, indicando o "reset bug" discutido no Capítulo 28):

```bash
sudo reboot
```

**Este é sempre um procedimento de recuperação válido e seguro** — reiniciar completamente o host garante que a GPU passe por um reset de hardware completo (power cycle da própria placa-mãe), resolvendo praticamente qualquer estado inconsistente de driver.

> **💡 DICA:** Um teclado conectado diretamente (não via passthrough USB dedicado, ver Capítulo 20) deve estar sempre disponível para o host, especificamente para permitir o acesso ao TTY neste tipo de cenário — evite passar o único teclado físico disponível inteiramente em passthrough dedicado sem um plano alternativo de acesso ao host.

### Cenário 2: Sistema não inicializa após alteração de parâmetro de kernel

**Sintoma:** após aplicar um parâmetro de kernel (IOMMU, isolcpus, HugePages), o sistema trava durante o boot, entra em pânico de kernel, ou não chega à tela de login.

**Procedimento de recuperação (systemd-boot):**

1. Reiniciar o computador.
2. No menu de boot do systemd-boot (pressionar uma tecla de seta durante a janela curta em que o menu aparece, geralmente logo após o POST da BIOS), selecionar uma entrada de kernel anterior, se disponível, ou uma entrada com parâmetros padrão.
3. Uma vez inicializado com sucesso, reverter a alteração problemática:

```bash
sudo kernelstub -p
```
**O que faz:** exibe (`print`) os parâmetros de kernel atualmente configurados pelo `kernelstub`, permitindo identificar exatamente qual parâmetro remover.

```bash
sudo kernelstub -d "<parametro-problematico>"
sudo reboot
```

**Procedimento de recuperação (GRUB):**

1. Reiniciar e, no menu do GRUB, selecionar "Advanced options for Pop!_OS".
2. Selecionar uma versão de kernel anterior à alteração.
3. Uma vez inicializado, reverter `/etc/default/grub` a partir do backup mais recente (cada capítulo deste documento que edita esse arquivo cria um backup com data, conforme convenção estabelecida no Capítulo 16):

```bash
sudo cp /etc/default/grub.bak-<data-do-backup-correto> /etc/default/grub
sudo update-grub
sudo reboot
```

### Cenário 3: Sistema completamente não inicializável — recuperação via mídia USB

**Sintoma:** nenhuma entrada de boot funciona; o sistema não chega nem ao menu do bootloader, ou trava antes disso.

**Procedimento:**

1. Inicializar a partir da mídia USB do Pop!_OS (Capítulo 6), selecionando "Experimentar Pop!_OS" (modo live, sem instalar) em vez de "Instalar".
2. Montar a partição raiz do NVMe manualmente para investigação:

```bash
sudo mkdir -p /mnt/sistema-recuperacao
sudo mount <NVME_DEVICE>p2 /mnt/sistema-recuperacao
sudo mount <NVME_DEVICE>p1 /mnt/sistema-recuperacao/boot/efi
```
**O que fazem:** montam a partição raiz (identificada no Capítulo 5) e a partição EFI dentro dela, replicando a estrutura que o sistema instalado veria durante um boot normal.

3. Entrar em modo `chroot` para operar como se estivesse dentro do sistema instalado:

```bash
for pasta in dev proc sys; do sudo mount --bind /$pasta /mnt/sistema-recuperacao/$pasta; done
sudo chroot /mnt/sistema-recuperacao
```
**O que fazem:** o `mount --bind` disponibiliza os sistemas de arquivos virtuais essenciais (`/dev`, `/proc`, `/sys`) dentro do ambiente montado, necessários para que comandos como `update-grub` ou `kernelstub` funcionem corretamente de dentro do `chroot`. `chroot` então troca a raiz do sistema de arquivos para o diretório montado, efetivamente "entrando" no sistema instalado a partir do ambiente live.

4. Dentro do `chroot`, reverter a alteração problemática (parâmetro de kernel, arquivo `fstab`, etc.) usando os mesmos comandos já apresentados ao longo deste documento.

5. Sair do `chroot` e reiniciar:

```bash
exit
for pasta in dev proc sys; do sudo umount /mnt/sistema-recuperacao/$pasta; done
sudo umount /mnt/sistema-recuperacao/boot/efi
sudo umount /mnt/sistema-recuperacao
sudo reboot
```

> **⚠️ ALERTA:** Remova a mídia USB de instalação antes deste reboot final, para garantir que o sistema tente inicializar a partir do NVMe recém-corrigido, não da própria mídia live novamente.

### Cenário 4: `/etc/fstab` malformado impede o boot (Capítulo 11)

**Sintoma:** o boot para em um prompt de emergência do `systemd` ("You are in emergency mode..."), mencionando falha ao montar um sistema de arquivos.

**Procedimento:**

1. No prompt de emergência, digitar a senha de root (ou do usuário `<USUARIO_LINUX>`, dependendo da configuração) quando solicitado.
2. Restaurar o backup do `fstab` (criado no Capítulo 11):

```bash
cp /etc/fstab.bak-<data> /etc/fstab
mount -a
systemctl default
```

> **💡 DICA:** Este é precisamente o cenário que a opção `nofail`, aplicada a todas as entradas de HD2 e dos bind mounts no Capítulo 11, foi desenhada para prevenir — um `fstab` com `nofail` corretamente aplicado não deveria, em circunstâncias normais, levar a este modo de emergência mesmo se o HD2 estiver fisicamente desconectado. Este cenário 4 aplica-se principalmente a erros de sintaxe genuínos no arquivo (UUID malformado, opção inexistente), não à ausência do disco em si.

## Comandos

Ver cada cenário acima para os comandos específicos e sequenciais de cada situação de recuperação.

## Arquivos modificados

Variável conforme o cenário e a causa raiz identificada.

## Como verificar

Após qualquer procedimento de recuperação deste capítulo, reexecutar o bloco de diagnóstico geral do Capítulo 28 como validação final de que o sistema retornou a um estado saudável e completo.

## Resultado esperado

Capacidade documentada de recuperar o ambiente a partir de qualquer um dos quatro cenários de falha descritos, sem necessidade de reinstalação completa do zero, preservando os dados do usuário (HD2, HD1) em todos os casos.

## Como desfazer

Não aplicável — este é, em si, o capítulo de reversão de emergência para o restante do documento.

## Problemas comuns

| Sintoma | Causa provável | Correção |
|---|---|---|
| `chroot` falha com "chroot: failed to run command '/bin/bash': No such file or directory" | Partição raiz não montada corretamente antes do `chroot`, ou arquitetura incompatível entre a mídia live e o sistema instalado (não deveria ocorrer usando a mesma mídia Pop!_OS) | Confirmar que `mount <NVME_DEVICE>p2 /mnt/sistema-recuperacao` foi bem-sucedido antes do `chroot` |
| Após recuperação, o sistema inicializa mas a VM não funciona mais | Alteração de emergência revertida também removeu configurações válidas feitas em capítulos posteriores | Revisar metodicamente, capítulo a capítulo, quais configurações ainda estão presentes após a recuperação, usando os comandos de "Como verificar" de cada capítulo relevante |

## Considerações finais

Este documento cobriu, do inventário inicial de hardware à recuperação de emergência, a implantação completa de um ambiente de virtualização com GPU Passthrough de GPU única sobre Pop!_OS, incluindo a segregação de armazenamento entre NVMe (sistema), HD1 (exclusivo da VM) e HD2 (exclusivo do Linux, com bind mounts para os diretórios pessoais do usuário). Cada decisão técnica foi documentada junto com sua justificativa, seus riscos e seu procedimento de reversão, na expectativa de que este manual sirva como referência permanente e reproduzível para a manutenção deste ambiente específico ao longo do tempo.

---

*Fim do documento — Windows11_VM_Passthrough_PopOS.md*
