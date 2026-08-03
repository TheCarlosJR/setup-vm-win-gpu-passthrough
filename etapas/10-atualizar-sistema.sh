#!/bin/bash
# ============================================================================
# etapas/10-atualizar-sistema.sh - Capítulo 7: Atualização do Sistema
# ============================================================================
# Atualiza pacotes, kernel e firmware ANTES de instalar drivers e a pilha de
# virtualização. Termina pedindo reboot se algo foi atualizado.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

verificar() {
    local pendentes
    pendentes="$(apt list --upgradable 2>/dev/null | grep -vc 'Listing' || true)"
    if [ "${pendentes:-0}" -eq 0 ]; then
        v_ok "Nenhum pacote pendente de atualização."
    else
        v_falta "$pendentes pacote(s) pendente(s) de atualização."
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

exigir_nao_root

titulo "Antes de continuar"
info "Finalidade: atualizar índices, pacotes, kernel e firmware antes dos drivers e da virtualização."
info "Pré-requisitos: rede funcional, usuário com sudo e espaço livre para pacotes e kernels."
aviso "Alterações: o índice APT será atualizado; full-upgrade pode instalar ou remover pacotes; autoremove remove órfãos; fwupd pode atualizar firmware."
info "Recomendação: mantenha backup recente, energia estável e não interrompa o APT nem uma atualização de firmware."
aviso "Risco principal: interrupções ou regressões podem deixar pacotes inconsistentes ou afetar o próximo boot."
info "Reboot/retorno: ao concluir, reinicie; depois valide o kernel ativo com 'uname -r' e retorne ao menu."

exigir_sudo

titulo "Capítulo 7: Atualização do Sistema"
KERNEL_ANTES="$(uname -r)"

info "Atualizando índice de pacotes..."
sudo apt update

info "Aplicando atualizações completas (full-upgrade)..."
sudo apt full-upgrade -y

info "Removendo pacotes órfãos..."
sudo apt autoremove -y

titulo "Firmware (fwupd/LVFS)"
sudo apt install -y fwupd
sudo fwupdmgr refresh --force || aviso "fwupdmgr refresh falhou (sem rede ou LVFS indisponível); prosseguindo."
sudo fwupdmgr get-updates || info "Sem atualizações de firmware disponíveis (normal em muitos componentes)."
sudo fwupdmgr update || info "Nenhum firmware aplicado."

echo
ok "Atualização concluída."
info "Kernel em execução: $KERNEL_ANTES"
info "Kernel mais novo instalado: $(dpkg -l 2>/dev/null | awk '/^ii +linux-image-[0-9]/{print $2}' | sort -V | tail -n1)"
aviso "Após o reboot, confirme com 'uname -r' que o kernel esperado está em uso."
pedir_reboot
