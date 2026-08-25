#!/bin/bash
# ============================================================================
# etapas/14-working-disk.sh - Etapa 8: preflight do workingDisk externo
# ============================================================================
# Verificação estritamente não destrutiva. O workingDisk é montado e gerenciado
# externamente pelo operador; esta etapa nunca cria diretórios, monta, formata,
# copia dados ou altera configuração persistente do host.
# ============================================================================
SCRIPT_VERSION="1.0.0"
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf
WORKING_DISK="${WORKING_DISK_PATH:-}"

verificar() {
    if [ -n "$WORKING_DISK" ] && [ "${WORKING_DISK_DISPENSADO:-}" = "sim" ]; then
        v_erro "Configuração contraditória: WORKING_DISK_PATH definido e WORKING_DISK_DISPENSADO=sim."
    elif [ "${WORKING_DISK_DISPENSADO:-}" = "sim" ]; then
        v_ok "workingDisk dispensado explicitamente; nenhum preflight é necessário."
    elif [ -z "$WORKING_DISK" ]; then
        v_falta "workingDisk ainda não configurado nem dispensado; execute a etapa 3."
    elif validar_working_disk_montado "$WORKING_DISK"; then
        if [ -z "${WORKING_DISK_FINGERPRINT:-}" ] || [ -z "${SYSTEM_DISK_FINGERPRINT:-}" ]; then
            v_indeterminado "Identidade física I6 do workingDisk/sistema ausente; execute a etapa 3 com --redetectar."
        elif inventario_revalidar_papeis_disco_configurados; then
            v_ok "workingDisk ativo e identidade física convergida em $WORKING_DISK (source=$WORKING_DISK_SOURCE; fstype=$WORKING_DISK_FSTYPE)."
        else
            v_falta "Identidade física do workingDisk recusada: $INVENTARIO_ERRO"
        fi
    else
        v_falta "$WORKING_DISK_ERRO"
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

if [ -n "$WORKING_DISK" ] && [ "${WORKING_DISK_DISPENSADO:-}" = "sim" ]; then
    falhar "Configuração contraditória: WORKING_DISK_PATH definido e WORKING_DISK_DISPENSADO=sim."
fi
if [ "${WORKING_DISK_DISPENSADO:-}" = "sim" ]; then
    titulo "Etapa 8: workingDisk externo"
    ok "Dispensa explícita registrada; nada foi alterado."
    exit 0
fi
[ -n "$WORKING_DISK" ] \
    || falhar "workingDisk não configurado. Execute a etapa 3 e informe um mountpoint já ativo ou escolha 0."
exigir_comando mountpoint findmnt lsblk udevadm
python_core_disponivel \
    || falhar "O core Python do projeto não respondeu: ${PYTHON_CORE_ERRO:-diagnóstico ausente}."

titulo "Etapa 8: preflight do workingDisk externo"
info "Verificação somente leitura: caminho seguro, mountpoint exato e identidade física I6."
validar_working_disk_montado "$WORKING_DISK" || falhar "$WORKING_DISK_ERRO"
inventario_revalidar_papeis_disco_configurados \
    || falhar "Identidade física do workingDisk recusada: $INVENTARIO_ERRO"
info "Caminho: $WORKING_DISK"
info "Source: $WORKING_DISK_SOURCE"
info "Filesystem: $WORKING_DISK_FSTYPE"
ok "workingDisk disponível e fisicamente convergido; nenhuma montagem ou configuração persistente foi criada."
