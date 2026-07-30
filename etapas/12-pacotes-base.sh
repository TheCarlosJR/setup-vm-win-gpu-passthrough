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

PACOTES=(ntfs-3g pciutils usbutils dmidecode curl wget git htop xmlstarlet)

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
