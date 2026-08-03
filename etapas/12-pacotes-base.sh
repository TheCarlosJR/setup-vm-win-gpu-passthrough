#!/bin/bash
# ============================================================================
# etapas/12-pacotes-base.sh - Capítulo 9: Instalação dos Pacotes Base
# ============================================================================
# Utilitários de disco, diagnóstico e suporte a NTFS usados pelas próximas
# etapas. Acrescenta xmlstarlet (usado pelos scripts para editar o XML da VM
# com segurança) à lista do manual.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

PACOTES=(ntfs-3g pciutils usbutils dmidecode curl wget git htop xmlstarlet rsync)

verificar() {
    local p
    for p in "${PACOTES[@]}"; do
        if dpkg -s "$p" >/dev/null 2>&1; then
            v_ok "$p instalado."
        else
            v_falta "$p ausente."
        fi
    done
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

exigir_nao_root

titulo "Antes de continuar"
info "Finalidade: instalar utilitários de NTFS, inventário, download, versionamento, monitoramento e edição de XML."
info "Pré-requisitos: rede funcional, APT sem transações pendentes e usuário com sudo."
info "Alterações: atualiza o índice APT e instala a lista abaixo, além das dependências resolvidas pelo APT."
info "Pacotes/finalidades: ntfs-3g (NTFS/Docs4); pciutils, usbutils e dmidecode (inventário de hardware)."
info "  curl e wget (downloads); git (versionamento); htop (monitoramento); xmlstarlet (XML da VM); rsync (migração e backup)."
info "A etapa Docs4 e o backup da VM dependem de rsync, incluído nesta lista."
aviso "Risco principal: interrupção ou conflito do APT pode deixar a instalação de pacotes incompleta."
info "Reboot/retorno: não exige reboot; ao concluir, retorne ao menu e siga para a etapa 13."

exigir_sudo

titulo "Capítulo 9: Pacotes base"
sudo apt update
sudo apt install -y "${PACOTES[@]}"

echo
ok "Pacotes instalados. Versões:"
ntfs-3g --version 2>&1 | head -n1
lspci --version
lsusb --version
dmidecode --version
xmlstarlet --version | head -n1
