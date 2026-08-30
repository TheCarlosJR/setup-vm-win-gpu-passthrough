#!/bin/bash
# ============================================================================
# etapas/20-virtualizacao.sh - Etapa 9: KVM, QEMU, Libvirt, Virt-Manager,
#                              OVMF, SWTPM e VirtIO
# ============================================================================
SCRIPT_VERSION="1.0.0"
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

PACOTES=()
inicializar_perfil_virtualizacao() {
    plataforma_carregar || return 1
    mapfile -t PACOTES < <(plataforma_pacotes_virtualizacao)
    [ "${#PACOTES[@]}" -gt 0 ]
}

# Prova funcional de um comando da pilha: presença no PATH não distingue
# binário quebrado de binário instalado, e um pacote meio instalado deixa o
# nome resolvendo para algo que não executa. O subcomando é somente leitura.
prova_comando_virtualizacao() {
    local comando="${1:-}"
    command -v "$comando" >/dev/null 2>&1 || return 1
    "$comando" --version >/dev/null 2>&1 || return 3
    return 0
}

verificar() {
    local p ovmf_dir servico_rc rc_comando
    local ovmf_code="" ovmf_vars=""
    local -a ovmf_codigos=() ovmf_variaveis=()
    if ! inicializar_perfil_virtualizacao; then
        v_erro "$PLATAFORMA_ERRO"
        v_fim
    fi
    ovmf_dir="$(caminho_sistema /usr/share/OVMF)" \
        || { v_erro "Não foi possível resolver o diretório OVMF."; v_fim; }
    # `dpkg -s` devolve 0 para pacote removido com config-files: era prova de
    # que o dpkg conhece o nome, não de que o pacote está instalado.
    v_prova_pacote "$PLATAFORMA_QEMU_PACOTE" || true
    rc_comando=0
    prova_comando_virtualizacao "$PLATAFORMA_QEMU_COMANDO" || rc_comando=$?
    v_classificar "$rc_comando" \
        "Capacidade QEMU x86 disponível: $PLATAFORMA_QEMU_COMANDO." \
        "Capacidade QEMU x86 indisponível: $PLATAFORMA_QEMU_COMANDO." \
        "Capacidade QEMU x86 não pôde ser sondada: $PLATAFORMA_QEMU_COMANDO." \
        "Capacidade QEMU x86 presente, mas '$PLATAFORMA_QEMU_COMANDO --version' falhou; a instalação está quebrada."
    for p in qemu-img virsh virt-install virt-manager swtpm; do
        rc_comando=0
        prova_comando_virtualizacao "$p" || rc_comando=$?
        v_classificar "$rc_comando" \
            "Comando $p disponível." \
            "Comando $p ausente." \
            "Comando $p não pôde ser sondado." \
            "Comando $p presente, mas '$p --version' falhou; a instalação está quebrada."
    done
    if ! command -v systemctl >/dev/null 2>&1; then
        v_indeterminado "systemctl indisponível para sondar o perfil libvirt."
    elif libvirt_backend_resolver; then
        if [ "$LIBVIRT_BACKEND_ACAO" = nenhuma ]; then
            v_ok "Endpoint libvirt ativo: $LIBVIRT_BACKEND_UNIDADE (backend $LIBVIRT_BACKEND_SERVICO)."
        else
            v_falta "Endpoint libvirt $LIBVIRT_BACKEND_UNIDADE está disponível, mas requer '$LIBVIRT_BACKEND_ACAO'."
        fi
    else
        servico_rc=$?
        if [ "$servico_rc" -eq 1 ]; then
            v_falta "$LIBVIRT_BACKEND_ERRO"
        else
            v_erro "$LIBVIRT_BACKEND_ERRO"
        fi
    fi
    # A ausência do virsh já foi contabilizada acima como pendência de pacote.
    if command -v virsh >/dev/null 2>&1; then
        if libvirt_acesso_operador; then
            v_ok "URI libvirt qemu:///system operacional."
        elif [ "$LIBVIRT_ACESSO_MOTIVO" = runtime ]; then
            v_erro "Pós-condição fatal: virsh não conseguiu consultar qemu:///system. $LIBVIRT_ACESSO_ERRO"
        else
            v_falta "$LIBVIRT_ACESSO_ERRO"
        fi
    fi
    # O glob sozinho não prova legibilidade, tipo de arquivo nem o PAR
    # CODE/VARS que a VM exige; um OVMF_CODE sem OVMF_VARS não inicializa
    # firmware nenhum.
    mapfile -t ovmf_codigos < <(compgen -G "$ovmf_dir/OVMF_CODE*.fd" 2>/dev/null \
        | LC_ALL=C sort || true)
    if [ "${#ovmf_codigos[@]}" -eq 0 ]; then
        v_falta "Arquivos OVMF não encontrados em $ovmf_dir."
    else
        ovmf_code="${ovmf_codigos[0]}"
        v_prova_arquivo "$ovmf_code" "Firmware OVMF" || true
        ovmf_vars="${ovmf_code//OVMF_CODE/OVMF_VARS}"
        if [ ! -e "$ovmf_vars" ]; then
            mapfile -t ovmf_variaveis < <(compgen -G "$ovmf_dir/OVMF_VARS*.fd" 2>/dev/null \
                | LC_ALL=C sort || true)
            ovmf_vars="${ovmf_variaveis[0]:-}"
        fi
        if [ -z "$ovmf_vars" ]; then
            v_falta "Par do firmware OVMF incompleto: nenhum OVMF_VARS*.fd em $ovmf_dir."
        else
            v_prova_arquivo "$ovmf_vars" "Modelo de variáveis OVMF" || true
        fi
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

guard_mutation virtualization.manage || exit 1
inicializar_perfil_virtualizacao || falhar "$PLATAFORMA_ERRO"
[ "$PLATAFORMA_GERENCIADOR_PACOTES" = apt ] \
    || falhar "A etapa 9 requer o perfil APT de Ubuntu/Pop!_OS."
exigir_nao_root

titulo "Antes de continuar"
info "Objetivo: instalar a pilha KVM/QEMU/libvirt usada para criar e executar a VM do Windows 11."
info "Perfil: $PLATAFORMA_PERFIL; pacote QEMU: $PLATAFORMA_QEMU_PACOTE; capacidade esperada: $PLATAFORMA_QEMU_COMANDO."
info "Pré-requisitos: SVM/virtualização habilitada na BIOS, rede para o APT e a etapa 6 concluída."
info "Pacotes do perfil: ${PACOTES[*]}."
info "Alterações: atualiza o APT, instala a pilha e habilita a unidade libvirt realmente encontrada entre as alternativas do perfil."
info "Recomendação: não interrompa o APT e só avance depois de confirmar KVM, OVMF e a conexão qemu:///system."
aviso "Riscos: uma interrupção pode deixar pacotes ou serviço incompletos; esta etapa não cria nem altera discos ou VMs."
info "Retorno/reboot: não há rollback automático nem reboot obrigatório; confirme que nenhuma VM depende da pilha antes de removê-la."

exigir_sudo

titulo "Etapa 9: Pilha de virtualização"
sudo apt update
sudo apt install -y "${PACOTES[@]}"

libvirt_backend_resolver \
    || falhar "A instalação terminou, mas nenhum endpoint libvirt pôde ser resolvido: $LIBVIRT_BACKEND_ERRO"
SERVICO_LIBVIRT="$LIBVIRT_BACKEND_SERVICO"
UNIDADE_LIBVIRT="$LIBVIRT_BACKEND_UNIDADE"
ACAO_LIBVIRT="$LIBVIRT_BACKEND_ACAO"
info "Ativando o endpoint libvirt resolvido por estado/perfil: $UNIDADE_LIBVIRT ($ACAO_LIBVIRT)"
ativar_unidade_systemd "$UNIDADE_LIBVIRT" "$ACAO_LIBVIRT"
sudo systemctl status "$UNIDADE_LIBVIRT" --no-pager | head -n 5 || true
if plataforma_resolver_servico virtlogd; then
    ativar_unidade_systemd "$PLATAFORMA_UNIDADE_RESOLVIDA" "$PLATAFORMA_UNIDADE_ACAO"
else
    aviso "Nenhum endpoint virtlogd separado foi encontrado; o perfil libvirt pode usar ativação integrada."
fi

titulo "Verificações da etapa 9"
command -v "$PLATAFORMA_QEMU_COMANDO" >/dev/null 2>&1 \
    && "$PLATAFORMA_QEMU_COMANDO" --version | head -n1 \
    || falhar "O pacote foi instalado, mas $PLATAFORMA_QEMU_COMANDO continua indisponível."

info "Aceleração KVM:"
info "Resultado esperado do kvm-ok: /dev/kvm existe e 'KVM acceleration can be used'."
if ! command -v kvm-ok >/dev/null 2>&1; then
    info "kvm-ok não está disponível; instalando cpu-checker para executar a verificação."
    sudo apt install -y cpu-checker
fi
kvm-ok || aviso "kvm-ok reprovou: revise SVM na BIOS (etapa 2)."

info "Firmware OVMF:"
OVMF_DIR="$(caminho_sistema /usr/share/OVMF)" \
    || falhar "Não foi possível resolver o diretório OVMF."
ls "$OVMF_DIR/"

info "Conexão com o libvirt (modo sistema):"
sudo virsh --connect qemu:///system list --all \
    || falhar "Pós-condição fatal: qemu:///system não respondeu após ativar $UNIDADE_LIBVIRT. Consulte o journal dessa unidade."
ok "$UNIDADE_LIBVIRT responde em qemu:///system (o acesso sem sudo será comprovado na etapa 10)."

echo
ok "Pilha instalada. Próxima etapa: 21 (grupos e permissões do usuário)."
