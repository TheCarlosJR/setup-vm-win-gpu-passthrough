#!/bin/bash
# ============================================================================
# etapas/21-usuario-grupos.sh - Capítulo 14: Usuário, Grupos e Serviços
# ============================================================================
# Integra operador e identidade QEMU ao grupo dedicado de /vm e garante o
# serviço libvirt sondado pelo perfil da plataforma.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf
VM_STORAGE_GROUP="${VM_STORAGE_GROUP:-vm-passthrough}"
VM_DIR="$(caminho_sistema /vm)" || falhar "Não foi possível resolver /vm."
QEMU_CONF_ARQUIVO="$(caminho_sistema /etc/libvirt/qemu.conf)" \
    || falhar "Não foi possível resolver qemu.conf."

ativar_unidade_systemd() {
    local unidade="$1" acao="$2"
    case "$acao" in
        nenhuma) info "Unidade já ativa: $unidade" ;;
        enable-now) sudo systemctl enable --now "$unidade" ;;
        start) sudo systemctl start "$unidade" ;;
        *) falhar "Ação systemd inválida para $unidade: $acao" ;;
    esac
}

VM_DIR_SELADO=0
restaurar_selo_etapa21() {
    [ "$VM_DIR_SELADO" -eq 1 ] || return 0
    if restaurar_diretorio_vm "$VM_DIR" "$VM_STORAGE_GROUP"; then
        VM_DIR_SELADO=0
        return 0
    fi
    erro "Falha ao restaurar /vm após os testes cruzados: $SELO_VM_ERRO"
    return 1
}

finalizar_etapa21() {
    local rc=$?
    trap - EXIT INT TERM
    if ! restaurar_selo_etapa21; then
        rc=3
    fi
    encerrar_sudo_keepalive
    exit "$rc"
}

verificar() {
    local usuario_ok=0 qemu_ok=0 grupos qemu_rc servico_rc
    if ! plataforma_carregar; then
        v_erro "$PLATAFORMA_ERRO"
        v_fim
    fi
    if [ -z "${USUARIO_LINUX:-}" ]; then
        v_falta "USUARIO_LINUX não definido (etapa 02)."
    elif validar_usuario_linux "$USUARIO_LINUX"; then
        usuario_ok=1
        if [ "$USUARIO_DIFERE_OPERADOR" -eq 1 ]; then
            v_erro "USUARIO_LINUX='$USUARIO_LINUX' difere do operador '$USUARIO_OPERADOR'."
        else
            v_ok "Operador validado no NSS: uid=$USUARIO_VALIDADO_UID gid=$USUARIO_VALIDADO_GID."
        fi
    else
        v_erro "$USUARIO_VALIDACAO_ERRO"
    fi
    if plataforma_resolver_usuario_qemu "$QEMU_CONF_ARQUIVO"; then
        QEMU_USUARIO="$PLATAFORMA_USUARIO_QEMU"
        qemu_ok=1
        v_ok "Identidade QEMU resolvida por qemu.conf/perfil: $QEMU_USUARIO."
    else
        qemu_rc=$?
        if [ "$qemu_rc" -eq 1 ]; then
            v_falta "$PLATAFORMA_ERRO"
        else
            v_erro "$PLATAFORMA_ERRO"
        fi
        QEMU_USUARIO=""
    fi
    if [ "$usuario_ok" -eq 1 ]; then
        grupos="$(id -nG "$USUARIO_LINUX" 2>/dev/null || true)"
        grep -qw "$PLATAFORMA_LIBVIRT_GRUPO" <<< "$grupos" \
            && v_ok "Usuário no grupo $PLATAFORMA_LIBVIRT_GRUPO." \
            || v_falta "Usuário fora do grupo $PLATAFORMA_LIBVIRT_GRUPO."
        grep -qw "$PLATAFORMA_KVM_GRUPO" <<< "$grupos" \
            && v_ok "Usuário no grupo $PLATAFORMA_KVM_GRUPO." \
            || v_falta "Usuário fora do grupo $PLATAFORMA_KVM_GRUPO."
    fi
    if [ "$usuario_ok" -eq 1 ] && [ "$qemu_ok" -eq 1 ] \
       && validar_modelo_diretorio_vm "$VM_DIR" "$USUARIO_LINUX" "$QEMU_USUARIO" "$VM_STORAGE_GROUP"; then
        v_ok "/vm compartilhado por operador e QEMU via $VM_STORAGE_GROUP, 2770 e ACL padrão."
    else
        v_falta "Modelo completo de /vm pendente: ${GRUPO_VM_ERRO:-identidades ainda indisponíveis}."
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        v_indeterminado "systemctl indisponível para sondar libvirt."
    elif plataforma_resolver_servico libvirt; then
        if [ "$PLATAFORMA_UNIDADE_ACAO" = nenhuma ]; then
            v_ok "$PLATAFORMA_UNIDADE_RESOLVIDA ativo."
        else
            v_falta "$PLATAFORMA_UNIDADE_RESOLVIDA requer $PLATAFORMA_UNIDADE_ACAO."
        fi
    else
        servico_rc=$?
        if [ "$servico_rc" -eq 1 ]; then
            v_falta "$PLATAFORMA_ERRO"
        else
            v_erro "$PLATAFORMA_ERRO"
        fi
    fi
    if command -v virsh >/dev/null 2>&1; then
        virsh --connect qemu:///system list --all >/dev/null 2>&1 \
            && v_ok "Operador acessa qemu:///system sem sudo." \
            || v_erro "Operador não conseguiu consultar qemu:///system; grupo/sessão ou runtime libvirt está inválido."
    else
        v_falta "virsh ausente."
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

exigir_plataforma_suportada
exigir_nao_root
exigir_conf USUARIO_LINUX
exigir_usuario_linux_valido "$USUARIO_LINUX"
exigir_comando setfacl getfacl
nome_grupo_vm_dedicado_valido "$VM_STORAGE_GROUP" \
    || falhar "VM_STORAGE_GROUP deve usar o namespace dedicado vm-passthrough[-sufixo]: '$VM_STORAGE_GROUP'."
plataforma_resolver_usuario_qemu "$QEMU_CONF_ARQUIVO" \
    || falhar "$PLATAFORMA_ERRO Execute a etapa 20 antes."
QEMU_USUARIO="$PLATAFORMA_USUARIO_QEMU"
[ -d "$VM_DIR" ] || falhar "/vm não existe; execute a etapa 13 antes."

titulo "Antes de continuar"
info "Objetivo: permitir que o operador use libvirt/KVM e compartilhar /vm com a identidade QEMU '$QEMU_USUARIO'."
info "Grupo de armazenamento dedicado: $VM_STORAGE_GROUP; grupos operacionais: $PLATAFORMA_LIBVIRT_GRUPO e $PLATAFORMA_KVM_GRUPO."
info "Alterações: acrescenta ambas as identidades aos grupos necessários, converge /vm para root:$VM_STORAGE_GROUP 2770 com ACL padrão e ativa serviços sondados."
info "Recomendação: execute antes de criar a VM e confirme depois, em sessão nova, id e virsh sem sudo."
aviso "Riscos: os grupos concedem controle sobre VMs/KVM; ACLs anteriores de /vm são substituídas pelo modelo dedicado, nunca por 777."
info "Retorno/reboot: não exige reboot, mas logout/login de toda a sessão é obrigatório antes da etapa 30/40."

exigir_sudo

titulo "Capítulo 14: Usuário, grupos e serviços"

for GRUPO_NECESSARIO in "$PLATAFORMA_LIBVIRT_GRUPO" "$PLATAFORMA_KVM_GRUPO"; do
    getent group "$GRUPO_NECESSARIO" >/dev/null \
        || falhar "Grupo '$GRUPO_NECESSARIO' não existe; revise a instalação da etapa 20."
done
if ! getent group "$VM_STORAGE_GROUP" >/dev/null; then
    sudo groupadd --system "$VM_STORAGE_GROUP"
fi

info "Adicionando $USUARIO_LINUX aos grupos operacionais e de armazenamento..."
sudo usermod -aG "$PLATAFORMA_LIBVIRT_GRUPO" "$USUARIO_LINUX"
sudo usermod -aG "$PLATAFORMA_KVM_GRUPO" "$USUARIO_LINUX"
sudo usermod -aG "$VM_STORAGE_GROUP" "$USUARIO_LINUX"
info "Adicionando a identidade QEMU '$QEMU_USUARIO' somente ao grupo dedicado de armazenamento..."
sudo usermod -aG "$VM_STORAGE_GROUP" "$QEMU_USUARIO"

info "Convergindo /vm para o modelo compartilhado sem permissões globais..."
configurar_modelo_diretorio_vm "$VM_DIR" "$VM_STORAGE_GROUP"
validar_modelo_diretorio_vm "$VM_DIR" "$USUARIO_LINUX" "$QEMU_USUARIO" "$VM_STORAGE_GROUP" \
    || falhar "Pós-condição de /vm não comprovada: $GRUPO_VM_ERRO"

plataforma_resolver_servico libvirt \
    || falhar "Endpoint libvirt não pôde ser sondado: $PLATAFORMA_ERRO"
SERVICO_LIBVIRT="$PLATAFORMA_SERVICO_RESOLVIDO"
UNIDADE_LIBVIRT="$PLATAFORMA_UNIDADE_RESOLVIDA"
ativar_unidade_systemd "$UNIDADE_LIBVIRT" "$PLATAFORMA_UNIDADE_ACAO"
if plataforma_resolver_servico virtlogd; then
    ativar_unidade_systemd "$PLATAFORMA_UNIDADE_RESOLVIDA" "$PLATAFORMA_UNIDADE_ACAO"
else
    aviso "virtlogd separado não foi encontrado; mantendo a estratégia integrada do libvirt."
fi
sudo -u "$USUARIO_LINUX" virsh --connect qemu:///system list --all >/dev/null \
    || falhar "Pós-condição fatal: '$USUARIO_LINUX' não acessa qemu:///system após a configuração de grupos."

titulo "Teste de arquivos novos pelas duas identidades"
TESTE_OPERADOR=""
TESTE_QEMU=""
limpar_testes_vm() {
    local -a alvos=()
    [ -z "$TESTE_OPERADOR" ] || alvos+=("$TESTE_OPERADOR")
    [ -z "$TESTE_QEMU" ] || alvos+=("$TESTE_QEMU")
    [ "${#alvos[@]}" -eq 0 ] || sudo rm -f -- "${alvos[@]}"
}
criar_teste_exclusivo_vm() {
    local identidade="$1" prefixo="$2"
    sudo -u "$identidade" sh -c '
        set -eu
        diretorio=$1
        prefixo=$2
        arquivo=$(mktemp "$diretorio/${prefixo}.XXXXXX")
        chmod 0660 "$arquivo"
        printf "%s\n" "$arquivo"
    ' _ "$VM_DIR" "$prefixo"
}
TESTE_OPERADOR="$(criar_teste_exclusivo_vm "$USUARIO_LINUX" .teste-operador)" \
    || { limpar_testes_vm; falhar "O operador não conseguiu criar canário exclusivo em /vm."; }
TESTE_QEMU="$(criar_teste_exclusivo_vm "$QEMU_USUARIO" .teste-qemu)" \
    || { limpar_testes_vm; falhar "QEMU não conseguiu criar canário exclusivo em /vm."; }
[[ "$TESTE_OPERADOR" == "$VM_DIR"/.teste-operador.?????? ]] \
    && [[ "$TESTE_QEMU" == "$VM_DIR"/.teste-qemu.?????? ]] \
    && [ -f "$TESTE_OPERADOR" ] && [ ! -L "$TESTE_OPERADOR" ] \
    && [ -f "$TESTE_QEMU" ] && [ ! -L "$TESTE_QEMU" ] \
    || { limpar_testes_vm; falhar "mktemp não produziu canários regulares confinados em /vm."; }

# Depois da criação O_EXCL, remove write do diretório durante as provas. Isso
# impede que outra identidade substitua um canário entre stat e test.
VM_DIR_SELADO=1
trap finalizar_etapa21 EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
selar_diretorio_vm "$VM_DIR" "$VM_STORAGE_GROUP" \
    || { limpar_testes_vm; falhar "Não foi possível proteger os testes contra TOCTOU: $SELO_VM_ERRO"; }
if ! validar_arquivo_compartilhado_vm "$TESTE_OPERADOR" "$VM_STORAGE_GROUP" \
   || ! validar_arquivo_compartilhado_vm "$TESTE_QEMU" "$VM_STORAGE_GROUP" \
   || ! sudo -u "$USUARIO_LINUX" test -r "$TESTE_QEMU" \
   || ! sudo -u "$USUARIO_LINUX" test -w "$TESTE_QEMU" \
   || ! sudo -u "$QEMU_USUARIO" test -r "$TESTE_OPERADOR" \
   || ! sudo -u "$QEMU_USUARIO" test -w "$TESTE_OPERADOR"; then
    limpar_testes_vm
    falhar "Herança, modo 0660 ou acesso cruzado entre operador/QEMU não foi comprovado."
fi
limpar_testes_vm
restaurar_selo_etapa21 \
    || falhar "Testes passaram, mas /vm não voltou ao modelo 2770/ACL: $SELO_VM_ERRO"
trap encerrar_sudo_keepalive EXIT INT TERM
ok "Operador e QEMU criam com O_EXCL, leem e escrevem arquivos herdados como $VM_STORAGE_GROUP:0660."

echo
ok "Etapa concluída. Endpoint libvirt: $UNIDADE_LIBVIRT."
aviso "IMPORTANTE: os novos grupos só valem em sessões NOVAS."
aviso "Encerre este menu e faça LOGOUT e LOGIN de toda a sessão (ou reinicie) antes da etapa 30/40."
info "Depois do login, confirme com: id"
info "E teste sem sudo: virsh --connect qemu:///system list --all"
