#!/bin/bash
# ============================================================================
# etapas/12-pacotes-base.sh - Etapa 6: Instalação dos Pacotes Base
# ============================================================================
# Utilitários de diagnóstico, cópia e administração usados pelas próximas
# etapas. Inclui xmlstarlet, rsync (backups) e
# I3: nenhuma etapa consome mais xmlstarlet operacionalmente (todo XML passa
# pelo core Python). O pacote continua listado por decisão explícita do plano
# (risco "Remoção de xmlstarlet"): pacote e documentação saem em I10, depois de
# a busca por consumidores ficar vazia no gate arquitetural.
# acl (modelo de permissões compartilhadas em /vm).
# ============================================================================
SCRIPT_VERSION="1.0.0"
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

PACOTES=(pciutils usbutils dmidecode curl wget git htop xmlstarlet rsync
    xorriso guestfs-tools acl)

verificar() {
    local p
    # `dpkg -s` devolve 0 para pacote REMOVIDO que deixou config-files, então a
    # etapa relatava como instalado um pacote que não existe mais no host.
    # v_prova_pacote é a prova real e depende do gerenciador do perfil: sem
    # perfil resolvido não há autoridade para afirmar instalação nenhuma.
    if ! plataforma_carregar; then
        v_erro "$PLATAFORMA_ERRO"
        v_fim
    fi
    for p in "${PACOTES[@]}"; do
        v_prova_pacote "$p" || true
    done
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

guard_mutation packages.base || exit 1
exigir_nao_root

titulo "Antes de continuar"
info "Finalidade: instalar utilitários de inventário, download, versionamento, monitoramento, XML, backup e ACL."
info "Pré-requisitos: rede funcional, APT sem transações pendentes e usuário com sudo."
info "Alterações: atualiza o índice APT e instala a lista abaixo, além das dependências resolvidas pelo APT."
info "Pacotes/finalidades: pciutils, usbutils e dmidecode (inventário de hardware)."
info "  curl e wget (downloads); git (versionamento); htop (monitoramento); xmlstarlet (mantido até I10, sem consumidor operacional); rsync (backup); acl (herança segura em /vm)."
info "  xorriso (ISO de payload da etapa 16) e guestfs-tools (virt-customize, injeção offline do qemu-guest-agent na etapa 16)."
info "O backup da VM depende de rsync; as etapas 7/10 dependem de setfacl/getfacl do pacote acl."
aviso "Risco principal: interrupção ou conflito do APT pode deixar a instalação de pacotes incompleta."
info "Reboot/retorno: não exige reboot; ao concluir, retorne ao menu e siga para a etapa 7."

exigir_sudo

titulo "Etapa 6: Pacotes base"
sudo apt update
sudo apt install -y "${PACOTES[@]}"

echo
ok "Pacotes instalados. Versões:"
lspci --version
lsusb --version
dmidecode --version
xmlstarlet --version | head -n1
