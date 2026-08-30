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
    # REQ-WAIVERS: a execução direta não pode inferir conclusão pela dispensa
    # nem sair calada com 0, que o menu renderizava como "Execução concluída.".
    # Ela informa a política e recusa sem efeito.
    if waiver_estado 14-working-disk.sh; then
        info "$(waiver_politica_texto 14-working-disk.sh)"
    else
        info "Escolha de modo registrada em WORKING_DISK_DISPENSADO=sim."
    fi
    info "Enquanto essa escolha estiver registrada, esta etapa não tem o que verificar: o fluxo não usa workingDisk externo."
    # Recusa SEM EFEITO, que é a segunda alternativa autorizada pelo requisito.
    # A outra (confirmar aqui e limpar a flag) foi considerada e recusada: esta
    # etapa é somente leitura, não declara capability em menu.sh e não aparece
    # como mutadora no envelope I1. Escrever passthrough.conf a partir daqui
    # ampliaria a superfície de mutação para fazer o que a etapa 3 já faz de
    # forma atômica, publicando caminho, fingerprint e dispensa dos dois papéis
    # em um único rename. A transição nas duas direções pertence a ela.
    cancelar_etapa "Para passar a usar um workingDisk externo, execute a etapa 3 e informe o mountpoint; ela troca a escolha e o caminho na mesma transação. Nada foi alterado aqui."
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
