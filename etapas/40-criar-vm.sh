#!/bin/bash
# ============================================================================
# etapas/40-criar-vm.sh - Etapa 12: Criação da Máquina Virtual
# ============================================================================
# Versão automatizada (virt-install) da criação feita no Virt-Manager pelo
# manual, com exatamente as mesmas escolhas:
#   - Firmware OVMF (UEFI) + chipset Q35
#   - TPM 2.0 emulado (swtpm)
#   - Disco /vm/Windows11.qcow2 (qcow2 dinâmico, VirtIO, cache=none)
#   - 2 CD-ROMs: ISO do Windows 11 + virtio-win.iso
#   - CPU host-passthrough, NIC virtio em NAT 'default' TEMPORÁRIA
#     (a etapa 18 aplica o modo final bridge ou NAT dedicado)
#   - Vídeo QXL temporário (a GPU real entra na etapa 14)
# Também aplica a regra AppArmor para o caminho customizado /vm.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf
VM_STORAGE_GROUP="${VM_STORAGE_GROUP:-vm-passthrough}"
QEMU_USUARIO=""
VM_DIR="$(caminho_sistema /vm)" || falhar "Não foi possível resolver /vm."
QEMU_CONF_ARQUIVO="$(caminho_sistema /etc/libvirt/qemu.conf)" \
    || falhar "Não foi possível resolver qemu.conf."
APPARMOR_LOCAL="$(caminho_sistema /etc/apparmor.d/local/abstractions/libvirt-qemu)" \
    || falhar "Não foi possível resolver a configuração AppArmor."
HOOKS_QEMU_DIR="$(caminho_sistema /etc/libvirt/hooks/qemu.d)" \
    || falhar "Não foi possível resolver os hooks libvirt."
REGRA_APPARMOR='/vm/** rwk,'
QCOW2_USO=""
QCOW2_ESTADO_INICIAL=""
QCOW2_FINGERPRINT_ESPERADO=""
ISO_WINDOWS_USO=""
ISO_WINDOWS_FINGERPRINT=""
ISO_VIRTIO_USO=""
ISO_VIRTIO_FINGERPRINT=""
VM_DIR_SELADO=0

restaurar_selo_etapa40() {
    [ "$VM_DIR_SELADO" -eq 1 ] || return 0
    if restaurar_diretorio_vm "$VM_DIR" "$VM_STORAGE_GROUP"; then
        VM_DIR_SELADO=0
        return 0
    fi
    erro "Falha ao restaurar /vm após a janela protegida: $SELO_VM_ERRO"
    return 1
}

finalizar_etapa40() {
    local rc=$?
    trap - EXIT INT TERM
    if ! restaurar_selo_etapa40; then
        rc=3
    fi
    encerrar_sudo_keepalive
    exit "$rc"
}

pedir_iso() {
    # Valida arquivo regular/canônico antes de qualquer sudo. Não copia nem
    # altera permissões automaticamente; uma falha exige correção consciente.
    local var="$1" desc="$2" dica="$3" caminho tentativas=0
    caminho="${!var:-}"
    while ! validar_iso_configurada "$caminho"; do
        if [ -n "$caminho" ]; then
            erro "$ARMAZENAMENTO_ERRO"
            info "Copie a ISO como operador para um nome direto e exclusivo em /vm, com grupo $VM_STORAGE_GROUP e modo 0660; depois informe esse caminho."
        fi
        info "$dica"
        caminho="$(perguntar "Caminho da $desc (ENTER cancela)" '')"
        [ -n "$caminho" ] || falhar "Sem a $desc não há como instalar o Windows. Cancelado."
        caminho="${caminho/#\~/$HOME}"
        tentativas=$((tentativas + 1))
        [ "$tentativas" -lt 5 ] \
            || falhar "Cinco tentativas sem uma $desc regular, canônica e segura. Cancelado."
    done
    salvar_conf "$var" "$caminho"
    ok "$desc validada sem links: $caminho"
}

preparar_iso_para_uso() {
    local var="$1" caminho uso fingerprint
    caminho="${!var}"
    validar_iso_configurada "$caminho" || falhar "$ARMAZENAMENTO_ERRO"
    uso="$ARMAZENAMENTO_CAMINHO_FISICO"
    fingerprint="$ARMAZENAMENTO_FINGERPRINT"
    printf -v "${var}_USO" '%s' "$uso"
    printf -v "${var}_FINGERPRINT" '%s' "$fingerprint"
}

comprovar_fingerprint() {
    local caminho="$1" esperado="$2" descricao="$3" atual
    atual="$(armazenamento_fingerprint_atual "$caminho" 2>/dev/null || true)"
    [ -n "$atual" ] && [ "$atual" = "$esperado" ] \
        || falhar "$descricao foi trocado após a validação; nenhuma operação continuará."
}

revalidar_artefatos_vm() {
    local fingerprint_original="$QCOW2_FINGERPRINT_ESPERADO"
    validar_qcow2_configurado "$QCOW2_PATH" "$VM_STORAGE_GROUP" \
        || falhar "QCOW2 deixou de ser seguro: $ARMAZENAMENTO_ERRO"
    [ "$ARMAZENAMENTO_QCOW2_ESTADO" = existente ] \
        || falhar "QCOW2 desapareceu após a preparação."
    [ -n "$fingerprint_original" ] && [ "$ARMAZENAMENTO_FINGERPRINT" = "$fingerprint_original" ] \
        || falhar "QCOW2 foi trocado após a validação; recusei a janela TOCTOU."
    comprovar_fingerprint "$ISO_WINDOWS_USO" "$ISO_WINDOWS_FINGERPRINT" "ISO do Windows"
    comprovar_fingerprint "$ISO_VIRTIO_USO" "$ISO_VIRTIO_FINGERPRINT" "ISO VirtIO"
}

criar_qcow2_novo() {
    # O temporário nasce como a identidade QEMU dentro do diretório setgid. O
    # hardlink publica o nome final de forma atômica e falha se alguém criar o
    # destino durante a janela; nenhum chmod/chgrp root toca o pathname final.
    sudo -u "$QEMU_USUARIO" sh -c '
        set -eu
        destino=$1
        tamanho=$2
        diretorio=${destino%/*}
        nome=${destino##*/}
        temporario=$(mktemp "$diretorio/.${nome}.novo.XXXXXX")
        limpar() { rm -f -- "$temporario"; }
        trap limpar EXIT HUP INT TERM
        umask 0007
        qemu-img create -f qcow2 "$temporario" "$tamanho"
        chmod 0660 "$temporario"
        qemu-img info --output=json "$temporario" | grep -Eq '"'"'"format"'"'"[[:space:]]*:[[:space:]]*"'"'"qcow2"'"'"'
        ln -- "$temporario" "$destino"
        rm -f -- "$temporario"
        trap - EXIT HUP INT TERM
    ' _ "$QCOW2_USO" "$QCOW2_TAMANHO" \
        || falhar "Não foi possível criar/publicar o QCOW2 atomicamente como $QEMU_USUARIO."
}

verificar() {
    [ -n "${VM_NAME:-}" ] || { v_falta "VM_NAME não definido (etapa 3)."; v_fim; }
    local usuario_ok=0 qemu_ok=0 qemu_rc
    if ! plataforma_carregar; then
        v_erro "$PLATAFORMA_ERRO"
    elif [ -z "${USUARIO_LINUX:-}" ]; then
        v_falta "USUARIO_LINUX não definido."
    elif validar_usuario_linux "$USUARIO_LINUX"; then
        usuario_ok=1
        if [ "$USUARIO_DIFERE_OPERADOR" -eq 1 ]; then
            v_erro "USUARIO_LINUX='$USUARIO_LINUX' difere do operador '$USUARIO_OPERADOR'."
        else
            v_ok "Operador validado no NSS: $USUARIO_LINUX."
        fi
    else
        v_erro "$USUARIO_VALIDACAO_ERRO"
    fi
    if [ "$PLATAFORMA_CARREGADA" -eq 1 ]; then
        if plataforma_resolver_usuario_qemu "$QEMU_CONF_ARQUIVO"; then
            QEMU_USUARIO="$PLATAFORMA_USUARIO_QEMU"
            qemu_ok=1
            if [ "$PLATAFORMA_QEMU_ORIGEM" = presumido ]; then
                v_ok "Identidade QEMU presumida sem privilégio: $QEMU_USUARIO (qemu.conf só é legível pelo root)."
            else
                v_ok "Identidade QEMU resolvida: $QEMU_USUARIO."
            fi
        else
            qemu_rc=$?
            if [ "$qemu_rc" -eq 1 ]; then
                v_falta "$PLATAFORMA_ERRO"
            else
                v_erro "$PLATAFORMA_ERRO"
            fi
            QEMU_USUARIO=""
        fi
    fi
    if [ "$usuario_ok" -eq 1 ] && [ "$qemu_ok" -eq 1 ] \
       && validar_modelo_diretorio_vm "$VM_DIR" "$USUARIO_LINUX" "$QEMU_USUARIO" "$VM_STORAGE_GROUP"; then
        v_ok "/vm pronto para operador e QEMU via $VM_STORAGE_GROUP."
    else
        v_falta "Modelo de acesso a /vm pendente: ${GRUPO_VM_ERRO:-identidades indisponíveis}."
    fi
    if validar_config_rede; then
        v_ok "Rede final selecionada: $REDE_MODO via $INTERFACE_FISICA (NAT default permanece temporária até a etapa 18)."
    else
        v_falta "$REDE_CONFIG_ERRO"
    fi
    if [ -z "${QCOW2_PATH:-}" ]; then
        v_falta "QCOW2_PATH não definido."
    elif ! command -v qemu-img >/dev/null 2>&1; then
        v_falta "qemu-img ausente para validar o QCOW2."
    elif validar_qcow2_configurado "$QCOW2_PATH" "$VM_STORAGE_GROUP"; then
        if [ "$ARMAZENAMENTO_QCOW2_ESTADO" = existente ]; then
            v_ok "QCOW2 regular, canônico e validado: $QCOW2_PATH."
        else
            v_falta "QCOW2 seguro ainda não existe: $QCOW2_PATH."
        fi
    else
        v_erro "$ARMAZENAMENTO_ERRO"
    fi
    if [ -n "${ISO_WINDOWS:-}" ]; then
        validar_iso_configurada "$ISO_WINDOWS" \
            && v_ok "ISO do Windows regular e sem links." \
            || v_erro "$ARMAZENAMENTO_ERRO"
    else
        v_falta "ISO_WINDOWS não definida."
    fi
    if [ -n "${ISO_VIRTIO:-}" ]; then
        validar_iso_configurada "$ISO_VIRTIO" \
            && v_ok "ISO VirtIO regular e sem links." \
            || v_erro "$ARMAZENAMENTO_ERRO"
    else
        v_falta "ISO_VIRTIO não definida."
    fi
    if vm_existe "$VM_NAME"; then
        v_ok "VM '$VM_NAME' definida no libvirt."
        if [ -n "${VM_NIC_MAC:-}" ]; then
            mac_valido "$VM_NIC_MAC" \
                && v_ok "MAC persistido da NIC: $VM_NIC_MAC" \
                || v_falta "VM_NIC_MAC inválido: $VM_NIC_MAC"
        else
            v_ok "Configuração antiga: a etapa 18 registrará VM_NIC_MAC antes de alterar a NIC."
        fi
    else
        v_falta "VM '$VM_NAME' não definida."
    fi
    if grep -qF "$REGRA_APPARMOR" "$APPARMOR_LOCAL" 2>/dev/null; then
        v_ok "Regra AppArmor para /vm presente."
    else
        v_falta "Regra AppArmor para /vm ausente."
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

guard_mutation domain.create || exit 1
exigir_plataforma_suportada
exigir_nao_root
exigir_conf USUARIO_LINUX VM_NAME QCOW2_PATH QCOW2_TAMANHO VM_RAM_MB VM_VCPUS
exigir_usuario_linux_valido "$USUARIO_LINUX"
plataforma_resolver_usuario_qemu "$QEMU_CONF_ARQUIVO" \
    || falhar "$PLATAFORMA_ERRO Execute a etapa 9 antes."
QEMU_USUARIO="$PLATAFORMA_USUARIO_QEMU"
nome_grupo_vm_dedicado_valido "$VM_STORAGE_GROUP" \
    || falhar "VM_STORAGE_GROUP deve usar o namespace dedicado vm-passthrough[-sufixo]: '$VM_STORAGE_GROUP'."
exigir_config_rede
nome_vm_valido "$VM_NAME" || falhar "VM_NAME='$VM_NAME' contém caracteres não seguros para libvirt/caminhos."

titulo "Antes de continuar"
info "Objetivo: preparar o armazenamento e definir/iniciar a VM do Windows 11 com UEFI, TPM, VirtIO e NAT temporária."
info "Pré-requisitos: etapas 9, 10 (já em sessão nova) e 11 fase B concluídas, ISOs oficiais disponíveis e espaço suficiente no volume do QCOW2."
info "Alterações: salva caminhos de ISOs já legíveis; adiciona '/vm/** rwk,' à abstração local do AppArmor e a recarrega; cria atomicamente o QCOW2 como QEMU se ausente; ativa a rede default; virt-install define e inicia a VM."
info "Arquivos existentes nunca recebem chmod/chgrp/ACL automáticos; metadados ou acesso divergentes causam falha com instrução segura."
info "Recomendação: mantenha backup de qualquer QCOW2 existente, confirme o espaço livre e use somente ISOs obtidas dos canais oficiais."
aviso "Riscos: a regra AppArmor concede ao QEMU leitura/escrita/bloqueio sob /vm; falta de espaço pode corromper o convidado; uma interrupção pode deixar disco, configuração ou definição parciais."
info "VM existente: a etapa aborta antes dessas alterações. 'undefine --nvram' remove a definição e a NVRAM, mas não apaga o QCOW2 sem --remove-all-storage; o arquivo existente permanece e será reutilizado."
aviso "virsh reset é um reset forçado, equivalente ao botão físico: só é aceitável no primeiro boot, enquanto não houver dados importantes; depois use desligamento/reinício normal do Windows."
info "Retorno/reboot: não exige reboot do host e não há rollback automático; com a VM desligada, undefine remove apenas a definição/NVRAM, enquanto QCOW2, ISOs e a regra AppArmor exigem revisão manual separada."

# Toda entrada configurável de armazenamento é validada antes da primeira
# aquisição/execução sudo. Caminho inseguro nunca alcança um comando privilegiado.
exigir_comando virt-install qemu-img virsh getfacl readlink stat
python_core_disponivel \
    || falhar "O core Python do projeto não respondeu: ${PYTHON_CORE_ERRO:-diagnóstico ausente}."
validar_modelo_diretorio_vm "$VM_DIR" "$USUARIO_LINUX" "$QEMU_USUARIO" "$VM_STORAGE_GROUP" \
    || falhar "Modelo de /vm inválido: $GRUPO_VM_ERRO Execute a etapa 10 e faça logout/login."
[ -r "$VM_DIR" ] && [ -w "$VM_DIR" ] && [ -x "$VM_DIR" ] \
    || falhar "O operador efetivo ainda não possui acesso rwx a /vm; faça logout/login após a etapa 10."
validar_qcow2_configurado "$QCOW2_PATH" "$VM_STORAGE_GROUP" \
    || falhar "QCOW2 recusado antes de sudo: $ARMAZENAMENTO_ERRO"
QCOW2_USO="$ARMAZENAMENTO_CAMINHO_FISICO"
QCOW2_ESTADO_INICIAL="$ARMAZENAMENTO_QCOW2_ESTADO"
QCOW2_FINGERPRINT_ESPERADO="$ARMAZENAMENTO_FINGERPRINT"

titulo "Etapa 12.1/5 ISOs de instalação"
pedir_iso ISO_WINDOWS "ISO do Windows 11" \
    "Baixe a ISO do Windows 11 em microsoft.com (nunca de espelhos de terceiros)."
pedir_iso ISO_VIRTIO "ISO virtio-win" \
    "Baixe a virtio-win.iso do projeto oficial virtio-win (QEMU/Red Hat)."
preparar_iso_para_uso ISO_WINDOWS
preparar_iso_para_uso ISO_VIRTIO
info "As ISOs serão usadas somente como filhos diretos de /vm e se o QEMU já puder lê-las; nenhum chmod, chgrp, ACL ou sudo install será aplicado."

titulo "Etapa 12: Criação da VM '$VM_NAME'"
info "Modo final selecionado: $REDE_MODO via $INTERFACE_FISICA; a criação usa NAT default somente até a etapa 18."

# Rede de segurança: o conf pode ter sido editado à mão depois da etapa 3.
RAM_MAX="$(ram_max_vm_mib)"
if [ "$VM_RAM_MB" -gt "$RAM_MAX" ]; then
    erro "VM_RAM_MB=$VM_RAM_MB MiB passa do teto seguro deste host ($RAM_MAX MiB)."
    erro "O host precisa da diferença para si (cache, desktop, o próprio processo QEMU)."
    falhar "Corrija com: bash etapas/02-detectar-config.sh --redetectar"
fi
CPUS_TOTAL="$(nproc --all)"
if [ "$VM_VCPUS" -ge "$CPUS_TOTAL" ]; then
    erro "VM_VCPUS=$VM_VCPUS é igual/maior que o total de CPUs lógicas do host ($CPUS_TOTAL)."
    falhar "Deixe pelo menos um núcleo físico para o host: etapas/02-detectar-config.sh --redetectar"
fi
info "Recursos: ${VM_RAM_MB} MiB de RAM (teto ${RAM_MAX}), ${VM_VCPUS} vCPUs de ${CPUS_TOTAL}."

if vm_existe "$VM_NAME"; then
    falhar "A VM '$VM_NAME' já existe. Para recriar: virsh --connect qemu:///system undefine $VM_NAME --nvram (CUIDADO: leia 'Como desfazer' da etapa 12 no Guia)."
fi

# Só agora é permitido obter sudo. As primeiras operações são provas de acesso,
# não correções de metadados em paths configuráveis.
exigir_sudo

if [ "$PLATAFORMA_QEMU_ORIGEM" = presumido ]; then
    # Com o ticket sudo em mãos, qemu.conf volta a ser autoritativo. Uma
    # divergência invalida as validações já feitas com a identidade presumida.
    QEMU_USUARIO_PRESUMIDO="$QEMU_USUARIO"
    plataforma_resolver_usuario_qemu "$QEMU_CONF_ARQUIVO" \
        || falhar "$PLATAFORMA_ERRO"
    [ "$PLATAFORMA_USUARIO_QEMU" = "$QEMU_USUARIO_PRESUMIDO" ] \
        || falhar "qemu.conf define a identidade QEMU '$PLATAFORMA_USUARIO_QEMU', divergente da presumida '$QEMU_USUARIO_PRESUMIDO'. Reexecute as etapas 10 e 12 para reconvergir /vm."
    QEMU_USUARIO="$PLATAFORMA_USUARIO_QEMU"
fi

acesso_identidade "$QEMU_USUARIO" rwx "$VM_DIR" \
    || falhar "A identidade QEMU '$QEMU_USUARIO' não possui acesso rwx a /vm. $ACESSO_IDENTIDADE_ERRO"
acesso_identidade "$QEMU_USUARIO" r "$ISO_WINDOWS_USO" \
    && acesso_identidade "$QEMU_USUARIO" r "$ISO_VIRTIO_USO" \
    || falhar "QEMU não lê uma das ISOs. Copie-a como operador para um nome direto em /vm, preserve grupo $VM_STORAGE_GROUP:0660 e atualize o conf; esta etapa não mudará permissões."
comprovar_fingerprint "$ISO_WINDOWS_USO" "$ISO_WINDOWS_FINGERPRINT" "ISO do Windows"
comprovar_fingerprint "$ISO_VIRTIO_USO" "$ISO_VIRTIO_FINGERPRINT" "ISO VirtIO"
if [ "$QCOW2_ESTADO_INICIAL" = existente ]; then
    acesso_identidade "$QEMU_USUARIO" rw "$QCOW2_USO" \
        || falhar "QEMU não possui rw no QCOW2 existente. Corrija conscientemente o arquivo após conferir inode/formato; nenhuma permissão será alterada aqui."
    comprovar_fingerprint "$QCOW2_USO" "$QCOW2_FINGERPRINT_ESPERADO" "QCOW2"
fi
HOOKS_RESIDUAIS="$HOOKS_QEMU_DIR/$VM_NAME"
if sudo test -e "$HOOKS_RESIDUAIS" || sudo test -L "$HOOKS_RESIDUAIS"; then
    falhar "Existem hooks residuais para '$VM_NAME' em $HOOKS_RESIDUAIS. Revise/arquive-os manualmente antes de recriar a VM; eles não serão removidos automaticamente."
fi

# ----------------------------------------------------------------------------
# 2. Regra AppArmor para o caminho customizado /vm
# ----------------------------------------------------------------------------
titulo "Etapa 12.2/5 AppArmor"
sudo mkdir -p "$(dirname "$APPARMOR_LOCAL")"
sudo touch "$APPARMOR_LOCAL"
if sudo grep -qF "$REGRA_APPARMOR" "$APPARMOR_LOCAL"; then
    info "Regra AppArmor já presente."
else
    echo "$REGRA_APPARMOR" | sudo tee -a "$APPARMOR_LOCAL" >/dev/null
    sudo systemctl reload apparmor
    ok "Regra '$REGRA_APPARMOR' adicionada e AppArmor recarregado."
fi

# ----------------------------------------------------------------------------
# 3. Disco QCOW2 (dinâmico, criado já com o dono correto)
# ----------------------------------------------------------------------------
titulo "Etapa 12.3/5 Disco do sistema"
if [ "$QCOW2_ESTADO_INICIAL" = existente ]; then
    info "QCOW2 existente validado e mantido sem alteração de owner/grupo/modo: $QCOW2_PATH."
else
    # QCOW2 cresce sob demanda, mas alocar mais do que o disco tem só adia o
    # problema para o meio de uma sessão do Windows (ENOSPC = corrupção).
    DIR_QCOW2="$VM_DIR"
    LIVRE_GB="$(df -BG --output=avail "$DIR_QCOW2" 2>/dev/null | tail -n1 | tr -dc '0-9')"
    NUM_ALVO="$(tr -dc '0-9' <<< "$QCOW2_TAMANHO")"
    case "${QCOW2_TAMANHO: -1}" in
        T|t) ALVO_GB=$((NUM_ALVO * 1024)) ;;
        M|m) ALVO_GB=$((NUM_ALVO / 1024)) ;;
        *)   ALVO_GB="$NUM_ALVO" ;;
    esac
    if [ -n "$LIVRE_GB" ] && [ -n "$ALVO_GB" ] && [ "$LIVRE_GB" -lt "$ALVO_GB" ]; then
        aviso "Espaço livre em /vm: ${LIVRE_GB} GiB, menor que o disco pedido (${ALVO_GB} GiB)."
        aviso "O QCOW2 cresce sob demanda; se o disco encher com a VM ligada, o Windows corrompe."
        confirmar "Criar assim mesmo?" \
            || falhar "Cancelado. Ajuste QCOW2_TAMANHO no passthrough.conf ou libere espaço."
    fi
    criar_qcow2_novo
    validar_qcow2_configurado "$QCOW2_PATH" "$VM_STORAGE_GROUP" \
        || falhar "QCOW2 recém-criado não passou na pós-condição: $ARMAZENAMENTO_ERRO"
    [ "$ARMAZENAMENTO_QCOW2_ESTADO" = existente ] \
        || falhar "QCOW2 recém-criado não foi publicado."
    QCOW2_FINGERPRINT_ESPERADO="$ARMAZENAMENTO_FINGERPRINT"
    acesso_identidade "$QEMU_USUARIO" rw "$QCOW2_USO" \
        || falhar "QCOW2 novo não ficou acessível à identidade QEMU. $ACESSO_IDENTIDADE_ERRO"
fi
revalidar_artefatos_vm
qemu-img info "$QCOW2_USO" | sed 's/^/  /'

# ----------------------------------------------------------------------------
# 4. Rede default do libvirt ativa (NAT de bootstrap até a etapa 18)
# ----------------------------------------------------------------------------
titulo "Etapa 12.4/5 Rede NAT default temporária"
# LC_ALL=C mantém os rótulos de net-info em inglês: com locale pt_BR a rede
# ativa aparece como "Ativo: sim", o filtro por "Active:.*yes" nunca casa e o
# net-start abaixo é chamado numa rede que já está no ar.
if ! LC_ALL=C $VIRSH net-info default 2>/dev/null | grep -q 'Active:.*yes'; then
    $VIRSH net-start default || true
    $VIRSH net-autostart default || true
fi
$VIRSH net-info default | sed 's/^/  /' || aviso "Rede 'default' indisponível; verifique o libvirt."

# ----------------------------------------------------------------------------
# 5. Definição da VM via virt-install
# ----------------------------------------------------------------------------
titulo "Etapa 12.5/5 virt-install"
OSV="win10"
if command -v osinfo-query >/dev/null 2>&1 && osinfo-query os 2>/dev/null | grep -qw win11; then
    OSV="win11"
fi
info "os-variant: $OSV"
# A raiz fica sem write de grupo desde a última validação até virt-install
# retornar com o domínio iniciado. Assim QEMU/outro membro não pode renomear
# nenhum dos três artefatos no intervalo check/open.
VM_DIR_SELADO=1
trap finalizar_etapa40 EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
selar_diretorio_vm "$VM_DIR" "$VM_STORAGE_GROUP" \
    || falhar "Não foi possível proteger /vm contra TOCTOU: $SELO_VM_ERRO"
revalidar_artefatos_vm

virt-install \
    --connect qemu:///system \
    --name "$VM_NAME" \
    --metadata title="Windows 11 (GPU passthrough)" \
    --memory "$VM_RAM_MB" \
    --vcpus "$VM_VCPUS" \
    --cpu host-passthrough \
    --machine q35 \
    --os-variant "$OSV" \
    --boot uefi \
    --tpm model=tpm-crb,backend.type=emulator,backend.version=2.0 \
    --disk path="$QCOW2_USO",format=qcow2,bus=virtio,cache=none \
    --disk path="$ISO_WINDOWS_USO",device=cdrom,bus=sata \
    --disk path="$ISO_VIRTIO_USO",device=cdrom,bus=sata \
    --network network=default,model=virtio \
    --graphics spice \
    --video qxl \
    --sound ich9 \
    --noautoconsole

restaurar_selo_etapa40 \
    || falhar "A VM foi iniciada, mas /vm não voltou ao modelo 2770/ACL: $SELO_VM_ERRO"
trap encerrar_sudo_keepalive EXIT INT TERM

# O MAC da NIC NAT temporária vem do core Python com cardinalidade exigida. A
# versão anterior usava `interface[...][1]`, ou seja, escolhia silenciosamente a
# primeira interface, o que a seção 3.5 proíbe: zero ou várias interfaces na
# rede `default` agora bloqueiam a etapa em vez de persistir um MAC arbitrário.
NIC40_PERMITIDAS=(
    "${CORE_PARES_ENVELOPE[@]}"
    NIC_COUNT MAC_COUNT CONSUMER_COUNT NETWORK_MATCH_COUNT NETWORK_MATCH_MAC
    MAC_TYPE MAC_NETWORK MAC_BRIDGE MAC_DEV MAC_HAS_ADDRESS
    'NIC_#_MAC' 'NIC_#_TYPE' 'NIC_#_NETWORK' 'NIC_#_SOURCE'
)
XML_VM_CRIADA="$($VIRSH dumpxml --inactive "$VM_NAME")" \
    || falhar "A VM foi criada, mas seu XML inativo não pôde ser lido."
NIC40_PAYLOAD=(xml "$XML_VM_CRIADA" network_name default)
python_core_pares_payload NIC40_PERMITIDAS NIC40_ domain-interfaces NIC40_PAYLOAD \
    || falhar "A VM foi criada, mas suas interfaces não pôderam ser analisadas."
[ "$NIC40_NETWORK_MATCH_COUNT" = 1 ] \
    || falhar "A VM foi criada com $NIC40_NETWORK_MATCH_COUNT interfaces na rede 'default'; esperado exatamente 1."
VM_NIC_MAC_DETECTADO="$NIC40_NETWORK_MATCH_MAC"
mac_valido "$VM_NIC_MAC_DETECTADO" \
    || falhar "A VM foi criada, mas não foi possível obter com segurança o MAC da NIC NAT temporária."
salvar_conf VM_NIC_MAC "${VM_NIC_MAC_DETECTADO,,}"
ok "NIC virtio temporária em network=default; MAC persistido: $VM_NIC_MAC."

echo
ok "VM criada e instalação iniciada em segundo plano."
$VIRSH list --all

info "Conferência do XML (loader OVMF, nvram, qcow2, q35):"
$VIRSH dumpxml "$VM_NAME" | grep -E "loader|nvram|qcow2|machine=" | sed 's/^/  /'

echo
aviso "A ISO do Windows pede 'Press any key to boot from CD' logo no início:"
aviso "abra o console AGORA e pressione uma tecla, senão o boot cai no shell UEFI."
if confirmar "Abrir o console gráfico da VM agora (virt-manager)?"; then
    nohup virt-manager --connect qemu:///system --show-domain-console "$VM_NAME" >/dev/null 2>&1 &
    info "Console aberto. Siga a etapa 13 para o passo a passo da instalação."
else
    info "Abra depois com: virt-manager --connect qemu:///system --show-domain-console $VM_NAME"
fi
info "Se perder o momento do boot: virsh --connect qemu:///system reset $VM_NAME"
