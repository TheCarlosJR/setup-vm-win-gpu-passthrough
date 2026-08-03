#!/bin/bash
# ============================================================================
# etapas/13-diretorios.sh - Capítulo 10: Estrutura de Diretórios
# ============================================================================
# Cria /vm (disco virtual da VM) e /mnt/docs4 (ponto de montagem do HD2).
# A permissão fina de /vm para o usuário libvirt-qemu é feita na etapa 21,
# depois que a pilha de virtualização criar esse usuário de sistema.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf
DOCS4="${DOCS4_MONTAGEM:-/mnt/docs4}"

verificar() {
    [ -d /vm ]       && v_ok "/vm existe."       || v_falta "/vm não existe."
    [ -d "$DOCS4" ]  && v_ok "$DOCS4 existe."    || v_falta "$DOCS4 não existe."
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

exigir_nao_root

titulo "Antes de continuar"
info "Finalidade: preparar /vm para o disco virtual e $DOCS4 como diretório de montagem do Docs4."
info "Pré-requisitos: usuário com sudo e confirmação de que /vm e $DOCS4 são os caminhos desejados."
aviso "Alterações: cria os diretórios e redefine /vm como root:root 755; $DOCS4 (por padrão /mnt/docs4) é só ponto de montagem, nenhum disco é montado nesta etapa."
info "Recomendação: inspecione conteúdo e permissões preexistentes antes de continuar."
aviso "Risco principal: um /vm já em uso pode ter suas permissões alteradas, ou dados locais podem ficar ocultos por montagem futura."
aviso "Se o HD2 foi dispensado, configure AIRLOCK_DIR fora de $DOCS4 antes da etapa 61; o padrão $DOCS4/airlock ocuparia o disco do sistema."
info "Reboot/retorno: não exige reboot; retorne ao menu e siga para a etapa 14, ou pule-a se Docs4 foi dispensado."

exigir_sudo

titulo "Capítulo 10: Estrutura de diretórios"

sudo mkdir -p /vm
sudo mkdir -p "$DOCS4"
sudo chown root:root /vm
sudo chmod 755 /vm

ok "Diretórios garantidos:"
ls -ld /vm "$DOCS4"
info "/vm está em root:root 755; a etapa 21 o ajusta para o grupo libvirt-qemu. $DOCS4 continua apenas como ponto de montagem."
