#!/bin/bash
# ============================================================================
# etapas/13-diretorios.sh - Etapa 7: Estrutura de Diretórios
# ============================================================================
# Cria e converge somente /vm com o grupo compartilhado dedicado. A etapa 10
# acrescenta a identidade QEMU ao mesmo grupo.
# ============================================================================
SCRIPT_VERSION="1.0.0"
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf
VM_STORAGE_GROUP="${VM_STORAGE_GROUP:-vm-passthrough}"

verificar() {
    local usuario_valido=0 diretorio_vm=""
    diretorio_vm="$(caminho_sistema /vm)" || diretorio_vm=""
    if [ -z "${USUARIO_LINUX:-}" ]; then
        v_falta "USUARIO_LINUX não definido (etapa 3)."
    elif validar_usuario_linux "$USUARIO_LINUX"; then
        usuario_valido=1
        if [ "$USUARIO_DIFERE_OPERADOR" -eq 1 ]; then
            v_erro "USUARIO_LINUX='$USUARIO_LINUX' difere do operador efetivo '$USUARIO_OPERADOR'; a execução exigirá confirmação reforçada."
        else
            v_ok "Conta do operador validada no NSS: uid=$USUARIO_VALIDADO_UID gid=$USUARIO_VALIDADO_GID home=$USUARIO_VALIDADO_HOME."
        fi
    else
        v_erro "$USUARIO_VALIDACAO_ERRO"
    fi
    # validar_modelo_diretorio_vm devolve 1 tanto para "modelo divergente"
    # quanto para "não consegui olhar" (getfacl/getent/stat ausentes, ou
    # filesystem sem suporte a ACL, caso real em partições NTFS/fuseblk).
    # Cada impedimento de OBSERVAÇÃO é separado antes da chamada.
    if ! nome_grupo_vm_dedicado_valido "$VM_STORAGE_GROUP"; then
        v_erro "VM_STORAGE_GROUP deve usar o namespace dedicado vm-passthrough[-sufixo]: '$VM_STORAGE_GROUP'."
    elif [ "$usuario_valido" -ne 1 ]; then
        v_falta "Modelo base de /vm pendente: usuário ainda não validado."
    elif [ -z "$diretorio_vm" ]; then
        v_indeterminado "Não foi possível resolver /vm; o modelo de diretórios não pôde ser observado."
    elif [ ! -d "$diretorio_vm" ]; then
        v_falta "Modelo base de /vm pendente: Diretório $diretorio_vm não existe."
    elif ! v_exigir_comando getfacl getent stat id; then
        : # v_exigir_comando já classificou a falta de ferramenta.
    elif ! getfacl -cp -- "$diretorio_vm" >/dev/null 2>&1; then
        v_indeterminado "Não foi possível ler as ACLs de $diretorio_vm; o filesystem pode não suportar ACL ou o acesso pode estar negado."
    elif validar_modelo_diretorio_vm "$diretorio_vm" "$USUARIO_LINUX" "" "$VM_STORAGE_GROUP"; then
        v_ok "/vm usa root:$VM_STORAGE_GROUP, modo 2770 e ACL padrão rwx/rwx/---."
    else
        v_falta "Modelo base de /vm pendente: ${GRUPO_VM_ERRO:-usuário ainda não validado}."
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

guard_mutation storage.prepare || exit 1
exigir_nao_root
exigir_conf USUARIO_LINUX
exigir_usuario_linux_valido "$USUARIO_LINUX"
exigir_comando setfacl getfacl
nome_grupo_vm_dedicado_valido "$VM_STORAGE_GROUP" \
    || falhar "VM_STORAGE_GROUP deve usar o namespace dedicado vm-passthrough[-sufixo]: '$VM_STORAGE_GROUP'."

titulo "Antes de continuar"
info "Finalidade: preparar somente /vm para o disco virtual da VM."
info "Pré-requisitos: conta Linux validada, pacote acl (etapa 6), sudo e confirmação do caminho."
aviso "Alterações: cria o grupo dedicado '$VM_STORAGE_GROUP', acrescenta o operador, cria /vm e converge o diretório para root:$VM_STORAGE_GROUP 2770 com ACL de herança."
info "A etapa 10 acrescentará a identidade QEMU detectada ao mesmo grupo; não se usa 777 nem o grupo interno libvirt-qemu como proprietário."
info "Recomendação: inspecione conteúdo, ACLs e permissões preexistentes de /vm antes de continuar."
aviso "Risco principal: ACLs preexistentes de /vm são substituídas pelo modelo dedicado; arquivos existentes não são removidos."
info "O workingDisk é externo e não é criado, montado ou alterado por esta etapa."
info "Reboot/retorno: os novos grupos exigem logout/login; a etapa 10 reforçará esse requisito antes da criação da VM."

exigir_sudo

titulo "Etapa 7: Estrutura de diretórios"

if ! getent group "$VM_STORAGE_GROUP" >/dev/null; then
    sudo groupadd --system "$VM_STORAGE_GROUP"
fi
sudo usermod -aG "$VM_STORAGE_GROUP" "$USUARIO_LINUX"
sudo mkdir -p /vm
configurar_modelo_diretorio_vm /vm "$VM_STORAGE_GROUP"
validar_modelo_diretorio_vm /vm "$USUARIO_LINUX" "" "$VM_STORAGE_GROUP" \
    || falhar "Pós-condição de /vm não comprovada: $GRUPO_VM_ERRO"

ok "Diretório /vm garantido:"
ls -ld /vm
getfacl -cp /vm | sed 's/^/  /'
info "/vm está em root:$VM_STORAGE_GROUP 2770 com ACL padrão; a etapa 10 integrará a identidade QEMU e testará arquivos novos pelas duas contas."
