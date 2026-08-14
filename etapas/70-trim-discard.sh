#!/bin/bash
# ============================================================================
# etapas/70-trim-discard.sh - Capítulo 25: TRIM/discard
# ============================================================================
# Habilita discard='unmap' exclusivamente no disco device='disk' cujo
# source/@file é exatamente QCOW2_PATH, exigindo cardinalidade um.
# ============================================================================
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
        BACKUP_DESTINO_ERRO="Defina BACKUPS_VM_DIR ou configure WORKING_DISK_PATH na etapa 02."
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
    local tmp rc
    [ -n "${VM_NAME:-}" ] || { v_falta "VM_NAME não definido."; v_fim; }
    [ -n "${QCOW2_PATH:-}" ] || { v_falta "QCOW2_PATH não definido."; v_fim; }
    if ! command -v python3 >/dev/null 2>&1; then
        v_erro "python3 indisponível para validar cardinalidade do disco QCOW2."
    elif ! vm_existe "$VM_NAME"; then
        v_falta "VM '$VM_NAME' não existe."
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
    elif [ -d "$DESTINO_BACKUPS" ]; then
        v_ok "Backup: pasta de destino existe (isso não comprova que haja backup)."
    else
        v_falta "Backup pendente: pasta $DESTINO_BACKUPS ausente."
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

exigir_nao_root
exigir_conf VM_NAME QCOW2_PATH
exigir_comando python3 xmlstarlet virt-xml-validate
caminho_absoluto_seguro "$QCOW2_PATH" || falhar "QCOW2_PATH inválido: '$QCOW2_PATH'."

titulo "Capítulo 25: TRIM/discard"

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

XML_ATUAL="$(mktemp)"
XML_CANDIDATO="$(mktemp)"
XML_POS="$(mktemp)"
limpar_xml_temporario() { rm -f -- "$XML_ATUAL" "$XML_CANDIDATO" "$XML_POS"; }
$VIRSH dumpxml --inactive "$VM_NAME" > "$XML_ATUAL" \
    || { limpar_xml_temporario; falhar "Não foi possível ler o XML inativo da VM."; }

if xml_disco_qcow2_estado "$XML_ATUAL" "$QCOW2_PATH"; then
    info "discard='unmap' já está configurado no único disco alvo."
else
    XML_ESTADO_RC=$?
    if [ "$XML_ESTADO_RC" -ne 1 ]; then
        limpar_xml_temporario
        falhar "XML recusado antes de qualquer mutação: $DISCARD_XML_ERRO"
    fi
    exigir_vm_desligada "$VM_NAME"
    $VIRSH help define 2>/dev/null | grep -q -- '--validate' \
        || { limpar_xml_temporario; falhar "Este virsh não oferece define --validate; nada foi alterado."; }
    xml_backup "$VM_NAME"
    cp -- "$XML_ATUAL" "$XML_CANDIDATO"
    XPATH_ALVO="/domain/devices/disk[@device='disk'][source/@file='$QCOW2_PATH']/driver"
    xmlstarlet ed -L -d "$XPATH_ALVO/@discard" "$XML_CANDIDATO"
    xmlstarlet ed -L -i "$XPATH_ALVO" -t attr -n discard -v unmap "$XML_CANDIDATO"
    virt-xml-validate "$XML_CANDIDATO" domain >/dev/null \
        || { limpar_xml_temporario; falhar "O XML candidato com discard não passa no schema libvirt."; }
    xml_disco_qcow2_estado "$XML_CANDIDATO" "$QCOW2_PATH" \
        || { limpar_xml_temporario; falhar "Pós-condição do candidato recusada: $DISCARD_XML_ERRO"; }
    if ! $VIRSH define --validate "$XML_CANDIDATO" >/dev/null; then
        limpar_xml_temporario
        falhar "virsh define recusou o XML candidato; o domínio original foi preservado."
    fi
    if ! $VIRSH dumpxml --inactive "$VM_NAME" > "$XML_POS" \
       || ! virt-xml-validate "$XML_POS" domain >/dev/null \
       || ! xml_disco_qcow2_estado "$XML_POS" "$QCOW2_PATH"; then
        erro "A pós-condição de discard falhou; tentando restaurar o backup XML $XML_BACKUP_PATH."
        if $VIRSH define --validate "$XML_BACKUP_PATH" >/dev/null; then
            aviso "XML anterior restaurado."
        else
            erro "ROLLBACK XML NÃO COMPROVADO. Não inicie a VM antes de revisar $XML_BACKUP_PATH."
        fi
        limpar_xml_temporario
        falhar "discard não foi comprovado no disco alvo após a definição."
    fi
    ok "discard='unmap' aplicado exclusivamente ao disco $QCOW2_PATH."
fi
limpar_xml_temporario

titulo "Pasta de backups"
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
Operação contínua (Capítulo 25):
  - Dentro do Windows, "Otimizar Unidades" deve listar o C: como SSD.
  - Compare qemu-img info antes/depois; redução imediata não é garantida.
  - Snapshots rápidos: util/snapshot-vm.sh criar|listar|reverter|apagar
  - Backup real: util/backup-vm.sh em outro disco físico.
DICAS
info "Fim da etapa 70: TRIM e disponibilidade do destino de backup são estados independentes."
