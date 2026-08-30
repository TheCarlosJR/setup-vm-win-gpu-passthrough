#!/bin/bash
# ============================================================================
# etapas/70-trim-discard.sh - Etapa 21: TRIM/discard
# ============================================================================
# Habilita discard='unmap' exclusivamente no disco device='disk' cujo
# source/@file é exatamente QCOW2_PATH, exigindo cardinalidade um.
# ============================================================================
SCRIPT_VERSION="1.0.0"
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf
WORKING_DISK="${WORKING_DISK_PATH:-}"
DESTINO_BACKUPS=""
BACKUP_DESTINO_ERRO=""
BACKUP_DEPENDS_ON_WORKING_DISK=0
classificar_destino_backups() {
    local rc
    BACKUP_DEPENDS_ON_WORKING_DISK=0
    [ -n "$WORKING_DISK" ] || return 0
    if caminho_dentro_working_disk "$DESTINO_BACKUPS" "$WORKING_DISK"; then
        BACKUP_DEPENDS_ON_WORKING_DISK=1
        return 0
    else
        rc=$?
    fi
    [ "$rc" -eq 1 ] && return 0
    BACKUP_DESTINO_ERRO="Destino de backup recusado por contenção insegura no workingDisk: $WORKING_DISK_CONTENCAO_ERRO"
    return 1
}
resolver_destino_backups() {
    DESTINO_BACKUPS=""
    BACKUP_DESTINO_ERRO=""
    BACKUP_DEPENDS_ON_WORKING_DISK=0
    if [ -n "${BACKUPS_VM_DIR:-}" ]; then
        DESTINO_BACKUPS="$BACKUPS_VM_DIR"
    elif [ -n "$WORKING_DISK" ] && [ "${WORKING_DISK_DISPENSADO:-}" != "sim" ]; then
        DESTINO_BACKUPS="${WORKING_DISK%/}/backups-vm"
    else
        BACKUP_DESTINO_ERRO="Defina BACKUPS_VM_DIR ou configure WORKING_DISK_PATH na etapa 3."
        return 1
    fi
    caminho_absoluto_seguro "$DESTINO_BACKUPS" \
        || { BACKUP_DESTINO_ERRO="Destino de backup inseguro: '$DESTINO_BACKUPS'."; return 1; }
    classificar_destino_backups
}
BACKUP_DESTINO_RESOLVIDO=0
if resolver_destino_backups; then
    BACKUP_DESTINO_RESOLVIDO=1
fi

verificar() {
    local tmp rc vm_estado=0
    # I9.9 (REQ-VERIFY-FAILCLOSED): `[ -n ]` aceitava qualquer literal. Ausente
    # continua sendo pendência; valor presente e fora do formato é erro de
    # configuração, porque reexecutar a etapa não conserta um literal inválido.
    v_var_definida VM_NAME nome_vm_valido || v_fim
    v_var_definida QCOW2_PATH caminho_absoluto_seguro || v_fim
    # `vm_existe` fundia "domínio ausente" com "libvirt não respondeu, virsh
    # ausente ou permissão negada", e os dois viravam pendência.
    vm_existe_estado "$VM_NAME" || vm_estado=$?
    if ! command -v python3 >/dev/null 2>&1; then
        v_erro "python3 indisponível para validar cardinalidade do disco QCOW2."
    elif [ "$vm_estado" -eq 1 ]; then
        v_falta "VM '$VM_NAME' não existe."
    elif [ "$vm_estado" -ne 0 ]; then
        v_indeterminado "Estado da VM '$VM_NAME' não pôde ser observado: ${VM_EXISTE_MOTIVO:-sem diagnóstico}."
    else
        tmp="$(mktemp)" || { v_erro "Não foi possível criar temporário para o XML."; v_fim; }
        if ! $VIRSH dumpxml --inactive "$VM_NAME" > "$tmp"; then
            v_indeterminado "Não foi possível ler o XML inativo da VM."
        elif xml_disco_qcow2_estado "$tmp" "$QCOW2_PATH"; then
            v_ok "TRIM: discard='unmap' ativo no único disco alvo $QCOW2_PATH."
        else
            rc=$?
            if [ "$rc" -eq 1 ]; then
                v_falta "TRIM: disco alvo único encontrado, mas discard='unmap' está ausente."
            else
                v_erro "TRIM: $DISCARD_XML_ERRO"
            fi
        fi
        rm -f -- "$tmp"
    fi
    if [ "$BACKUP_DESTINO_RESOLVIDO" -ne 1 ]; then
        v_falta "Backup não preparado: $BACKUP_DESTINO_ERRO"
    elif [ "$BACKUP_DEPENDS_ON_WORKING_DISK" -eq 1 ] \
         && ! validar_working_disk_montado "$WORKING_DISK"; then
        v_falta "Backup protegido pelo workingDisk indisponível: $WORKING_DISK_ERRO"
    elif [ ! -d "$DESTINO_BACKUPS" ]; then
        v_falta "Backup pendente: pasta $DESTINO_BACKUPS ausente."
    else
        # I9.9 (REQ-VERIFY-FAILCLOSED): o ramo anterior fechava em rc 0 com a
        # mensagem "isso não comprova que haja backup", ou seja, admitia por
        # escrito que estava aprovando sem prova. A pasta pronta é condição
        # necessária e nunca suficiente: sem um conjunto de backup com data (e
        # tamanho, quando o conjunto é arquivo) legíveis, o estado não foi
        # observado e o resultado é indeterminado.
        provar_backup_existente
    fi
    v_fim
}

provar_backup_existente() {
    local entrada nome alvo="" alvo_mtime=0 mtime tamanho data descricao
    if [ ! -r "$DESTINO_BACKUPS" ] || [ ! -x "$DESTINO_BACKUPS" ]; then
        v_indeterminado "Backup não comprovado: a pasta $DESTINO_BACKUPS existe mas não pôde ser lida."
        return 0
    fi
    v_exigir_comando stat || return 0
    for entrada in "$DESTINO_BACKUPS"/*; do
        [ -e "$entrada" ] || continue
        mtime="$(LC_ALL=C stat -c '%Y' -- "$entrada" 2>/dev/null)" || mtime=""
        [ -n "$mtime" ] || continue
        case "$mtime" in
            ''|*[!0-9]*) continue ;;
        esac
        if [ "$mtime" -gt "$alvo_mtime" ]; then
            alvo="$entrada"
            alvo_mtime="$mtime"
        fi
    done
    if [ -z "$alvo" ]; then
        v_indeterminado "Backup não comprovado: a pasta $DESTINO_BACKUPS existe, mas nenhum conjunto de backup com data legível foi encontrado (esta etapa só prepara a pasta; o backup em si é feito por util/backup-vm.sh)."
        return 0
    fi
    nome="${alvo##*/}"
    data="$(LC_ALL=C date -d "@$alvo_mtime" '+%F %T' 2>/dev/null)" || data=""
    [ -n "$data" ] || data="epoch $alvo_mtime"
    if [ -d "$alvo" ]; then
        descricao="conjunto em diretório, modificado em $data"
    else
        tamanho="$(LC_ALL=C stat -c '%s' -- "$alvo" 2>/dev/null)" || tamanho=""
        if [ -z "$tamanho" ]; then
            v_indeterminado "Backup não comprovado: '$nome' existe em $DESTINO_BACKUPS, mas o tamanho não pôde ser lido."
            return 0
        fi
        descricao="$tamanho bytes, modificado em $data"
    fi
    v_ok "Backup: conjunto mais recente em $DESTINO_BACKUPS é '$nome' ($descricao)."
}
[ "${1:-}" = "--verificar" ] && verificar

guard_mutation trim.configure || exit 1
exigir_nao_root
exigir_conf VM_NAME QCOW2_PATH
exigir_comando python3 virt-xml-validate
python_core_disponivel \
    || falhar "O core Python do projeto não respondeu: ${PYTHON_CORE_ERRO:-diagnóstico ausente}."
caminho_absoluto_seguro "$QCOW2_PATH" || falhar "QCOW2_PATH inválido: '$QCOW2_PATH'."

titulo "Etapa 21.1/2 TRIM/discard no XML da VM"

cat <<ORIENTACAO
Finalidade: habilitar discard somente no disco cujo source/@file seja
exatamente $QCOW2_PATH e preparar, separadamente, o diretório de backups.
Zero ou mais de um disco alvo bloqueiam a operação. Se o XML mudar, a VM deve
estar desligada, o XML recebe backup e a pós-condição é relida do libvirt.
TRIM não substitui backup nem garante redução imediata do espaço alocado.
ORIENTACAO

exigir_sudo
info "Suporte a discard no host (DISC-GRAN/DISC-MAX diferentes de zero = OK):"
lsblk --discard | sed 's/^/  /'

# --- Transação de discard (REQ-TRIM-TX) --------------------------------------
# Estados explícitos, traps armados antes do primeiro define e commit somente
# depois da prova semântica relida do libvirt. Retorno zero de `define` nunca é
# tratado como evidência: toda restauração é relida e comparada.

TRIM_ESTADO=IDLE            # IDLE|PREPARED|APPLIED|VERIFIED|COMMITTED|ROLLING_BACK
TRIM_FINGERPRINT_ORIGINAL=""
TRIM_PRESERVAR_EVIDENCIA=0
XML_ATUAL="$(mktemp)"
XML_CANDIDATO="$(mktemp)"
XML_POS="$(mktemp)"
XML_ROLLBACK="$(mktemp)"

limpar_xml_temporario() {
    rm -f -- "$XML_CANDIDATO" "$XML_POS" "$XML_ROLLBACK"
    if [ "$TRIM_PRESERVAR_EVIDENCIA" -eq 0 ]; then
        rm -f -- "$XML_ATUAL"
    else
        erro "XML original preservado para recuperação em: $XML_ATUAL"
    fi
}

trim_rollback() {
    # Restaura o XML original e PROVA a restauração relendo o domínio. Um
    # `define` que retorna zero sem aplicar (rollback divergente) precisa ser
    # detectado aqui, não anunciado como sucesso.
    local rc_compare=0
    TRIM_ESTADO=ROLLING_BACK
    # Primeiro: o domínio ainda está no estado original? Se a falha ocorreu
    # antes de qualquer mutação efetiva, não há efeito a desfazer.
    if $VIRSH dumpxml --inactive "$VM_NAME" > "$XML_ROLLBACK" 2>/dev/null \
       && xml_dominio_fingerprint "$XML_ROLLBACK" \
       && [ -n "$TRIM_FINGERPRINT_ORIGINAL" ] \
       && [ "$XML_DOMINIO_FINGERPRINT" = "$TRIM_FINGERPRINT_ORIGINAL" ]; then
        aviso "Nenhuma mutação efetiva do XML a desfazer; o domínio segue idêntico ao original."
        return 0
    fi
    if ! $VIRSH define --validate "$XML_ATUAL" >/dev/null 2>&1; then
        erro "ROLLBACK XML NÃO COMPROVADO. O virsh recusou restaurar o XML original."
        TRIM_PRESERVAR_EVIDENCIA=1
        return 1
    fi
    if ! $VIRSH dumpxml --inactive "$VM_NAME" > "$XML_ROLLBACK" 2>/dev/null; then
        erro "ROLLBACK XML NÃO COMPROVADO. Não foi possível reler o domínio após a restauração."
        TRIM_PRESERVAR_EVIDENCIA=1
        return 1
    fi
    xml_dominio_equivalente "$XML_ATUAL" "$XML_ROLLBACK" full || rc_compare=$?
    if [ "$rc_compare" -eq 0 ]; then
        aviso "XML anterior restaurado e comprovado por releitura semântica."
        return 0
    fi
    if [ "$rc_compare" -eq 2 ]; then
        erro "ROLLBACK XML NÃO COMPROVADO. Falha ao comparar o domínio restaurado: $XML_COMPARACAO_ERRO"
    else
        erro "ROLLBACK XML NÃO COMPROVADO. O domínio restaurado divergiu do original: ${XML_COMPARACAO_DIFERENCA:-divergência semântica}."
    fi
    TRIM_PRESERVAR_EVIDENCIA=1
    return 1
}

trim_finalizar() {
    local rc=$?
    trap - EXIT INT TERM
    case "$TRIM_ESTADO" in
        # PREPARED entra na restauração de propósito: entre armar os traps e
        # confirmar o define não é possível saber se a mutação já valeu, e
        # trim_rollback começa comparando o fingerprint, então um estado
        # inalterado não gera nenhum efeito adicional.
        PREPARED|APPLIED|VERIFIED|ROLLING_BACK)
            erro "Transação de TRIM interrompida antes do commit; restaurando o XML original."
            if ! trim_rollback; then
                erro "Recuperação manual necessária: restaure o backup XML informado acima antes de iniciar a VM."
                [ "$rc" -ne 0 ] || rc=1
            fi
            ;;
    esac
    limpar_xml_temporario
    python_core_temporarios_limpar
    encerrar_sudo_keepalive
    exit "$rc"
}

$VIRSH dumpxml --inactive "$VM_NAME" > "$XML_ATUAL" \
    || { limpar_xml_temporario; falhar "Não foi possível ler o XML inativo da VM."; }
[ -s "$XML_ATUAL" ] \
    || { limpar_xml_temporario; falhar "O XML inativo capturado está vazio."; }

if xml_disco_qcow2_estado "$XML_ATUAL" "$QCOW2_PATH"; then
    info "discard='unmap' já está configurado no único disco alvo."
    limpar_xml_temporario
else
    XML_ESTADO_RC=$?
    if [ "$XML_ESTADO_RC" -ne 1 ]; then
        limpar_xml_temporario
        falhar "XML recusado antes de qualquer mutação: $DISCARD_XML_ERRO"
    fi
    exigir_vm_desligada "$VM_NAME"
    $VIRSH help define 2>/dev/null | grep -q -- '--validate' \
        || { limpar_xml_temporario; falhar "Este virsh não oferece define --validate; nada foi alterado."; }

    # Fingerprint do estado original: base da prova de rollback e da detecção
    # de mudança concorrente.
    xml_dominio_fingerprint "$XML_ATUAL" \
        || { limpar_xml_temporario; falhar "Não foi possível medir o XML original: $XML_DOMINIO_ERRO"; }
    TRIM_FINGERPRINT_ORIGINAL="$XML_DOMINIO_FINGERPRINT"

    # Candidato gerado e integralmente validado antes da primeira mutação.
    xml_candidato_discard "$XML_ATUAL" "$XML_CANDIDATO" "$QCOW2_PATH" \
        || { limpar_xml_temporario; falhar "Candidato de discard recusado: $XML_CANDIDATO_ERRO"; }
    [ "$XML_CANDIDATO_FINGERPRINT_ANTES" = "$TRIM_FINGERPRINT_ORIGINAL" ] \
        || { limpar_xml_temporario; falhar "O XML mudou entre a captura e a geração do candidato; nada foi alterado."; }
    virt-xml-validate "$XML_CANDIDATO" domain >/dev/null \
        || { limpar_xml_temporario; falhar "O XML candidato com discard não passa no schema libvirt."; }
    xml_disco_qcow2_estado "$XML_CANDIDATO" "$QCOW2_PATH" \
        || { limpar_xml_temporario; falhar "Pós-condição do candidato recusada: $DISCARD_XML_ERRO"; }
    xml_backup "$VM_NAME"

    # Traps armados ANTES do primeiro define: sinal ou falha em qualquer ponto
    # da janela mutante cai na restauração comprovada, preservando o código.
    trap 'trim_finalizar' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    TRIM_ESTADO=PREPARED

    $VIRSH define --validate "$XML_CANDIDATO" >/dev/null \
        || falhar "virsh define recusou o XML candidato; a transação restaurará o XML original."
    TRIM_ESTADO=APPLIED
    $VIRSH dumpxml --inactive "$VM_NAME" > "$XML_POS" \
        || falhar "Não foi possível reler o XML após o define; a transação restaurará o original."
    virt-xml-validate "$XML_POS" domain >/dev/null \
        || falhar "O XML persistido não passa no schema libvirt; a transação restaurará o original."
    xml_disco_qcow2_estado "$XML_POS" "$QCOW2_PATH" \
        || falhar "discard não foi comprovado no disco alvo após a definição: ${DISCARD_XML_ERRO:-estado divergente}."
    TRIM_ESTADO=VERIFIED

    # Commit lógico: só a partir daqui o trap deixa de restaurar. O trap volta
    # a ser o do ticket sudo, instalado por exigir_sudo.
    TRIM_ESTADO=COMMITTED
    trap encerrar_sudo_keepalive EXIT INT TERM
    limpar_xml_temporario
    ok "discard='unmap' aplicado exclusivamente ao disco $QCOW2_PATH."
fi

titulo "Etapa 21.2/2 Pasta de backups"
BACKUP_DESTINO_RESOLVIDO=0
if resolver_destino_backups; then
    BACKUP_DESTINO_RESOLVIDO=1
fi
if [ "$BACKUP_DESTINO_RESOLVIDO" -ne 1 ]; then
    aviso "$BACKUP_DESTINO_ERRO"
    aviso "Preparação do backup pulada; a configuração de TRIM acima permanece válida."
elif [ "$BACKUP_DEPENDS_ON_WORKING_DISK" -eq 1 ] \
     && ! validar_working_disk_montado "$WORKING_DISK"; then
    aviso "$WORKING_DISK_ERRO"
    aviso "Destino dentro do workingDisk não será criado; TRIM não é afetado."
else
    sudo mkdir -p "$DESTINO_BACKUPS"
    ok "$DESTINO_BACKUPS pronto; nenhum backup foi executado por esta etapa."
    if [ "$(disco_de "$DESTINO_BACKUPS" 2>/dev/null || true)" = "$(disco_raiz 2>/dev/null || true)" ]; then
        aviso "O destino está no mesmo disco físico da raiz do host; use outro disco físico para o backup real."
    fi
fi

echo
cat <<'DICAS'
Operação contínua (etapa 21):
  - Dentro do Windows, "Otimizar Unidades" deve listar o C: como SSD.
  - Compare qemu-img info antes/depois; redução imediata não é garantida.
  - Snapshots rápidos: util/snapshot-vm.sh criar|listar|reverter|apagar
  - Backup real: util/backup-vm.sh em outro disco físico.
DICAS
info "Fim da etapa 21: TRIM e disponibilidade do destino de backup são estados independentes."
