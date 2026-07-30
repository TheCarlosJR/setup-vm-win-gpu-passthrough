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
exigir_sudo

titulo "Capítulo 10: Estrutura de diretórios"

sudo mkdir -p /vm
sudo mkdir -p "$DOCS4"
sudo chown root:root /vm
sudo chmod 755 /vm

ok "Diretórios criados:"
ls -ld /vm "$DOCS4"
info "Estado inicial seguro (root:root 755); a etapa 21 ajusta /vm para o grupo libvirt-qemu."
