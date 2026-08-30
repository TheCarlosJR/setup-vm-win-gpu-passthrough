#!/bin/bash
# Testes sem efeitos no host para os contratos de segurança da auditoria.
set -euo pipefail
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

falha() { echo "FALHA: $*" >&2; exit 1; }
exigir_texto() {
    local arquivo="$1" texto="$2"
    grep -Fq -- "$texto" "$RAIZ/$arquivo" || falha "$arquivo não contém: $texto"
}
rejeitar_texto() {
    local arquivo="$1" texto="$2"
    ! grep -Fq -- "$texto" "$RAIZ/$arquivo" || falha "$arquivo ainda contém texto proibido: $texto"
}
# Extrai o corpo de uma função shell (da linha "nome() {" até o "}" na coluna
# 0). É o que permite afirmar onde um comando aparece, e não apenas que ele
# existe em algum lugar do arquivo: o defeito de I9.8 era exatamente ter
# `sshd -T -C` só no caminho de aplicação.
corpo_funcao() {
    local arquivo="$1" funcao="$2"
    awk -v f="$funcao" '
        $0 == f "() {" { dentro = 1; next }
        dentro && $0 == "}" { exit }
        dentro { print }
    ' "$RAIZ/$arquivo"
}
exigir_texto_em_funcao() {
    local arquivo="$1" funcao="$2" texto="$3" corpo
    corpo="$(corpo_funcao "$arquivo" "$funcao")"
    [ -n "$corpo" ] || falha "$arquivo não define a função $funcao"
    grep -Fq -- "$texto" <<< "$corpo" \
        || falha "$arquivo: a função $funcao não contém: $texto"
}
rejeitar_texto_em_funcao() {
    local arquivo="$1" funcao="$2" texto="$3" corpo
    corpo="$(corpo_funcao "$arquivo" "$funcao")"
    [ -n "$corpo" ] || falha "$arquivo não define a função $funcao"
    ! grep -Fq -- "$texto" <<< "$corpo" \
        || falha "$arquivo: a função $funcao ainda contém texto proibido: $texto"
}

bash -n "$RAIZ/etapas/11-driver-nvidia.sh" "$RAIZ/etapas/12-pacotes-base.sh" \
    "$RAIZ/etapas/14-working-disk.sh" "$RAIZ/etapas/61-airlock.sh" \
    "$RAIZ/etapas/70-trim-discard.sh" "$RAIZ/util/snapshot-vm.sh" \
    "$RAIZ/util/atualizar-host.sh" "$RAIZ/util/backup-vm.sh"

exigir_texto etapas/14-working-disk.sh 'validar_working_disk_montado'
for texto_proibido in sudo mkdir fstab rsync xdg-user-dir; do
    rejeitar_texto etapas/14-working-disk.sh "$texto_proibido"
done
if grep -Eq -- '(^|[;&|[:space:]])mount([[:space:]]|$)' "$RAIZ/etapas/14-working-disk.sh"; then
    falha 'etapas/14-working-disk.sh ainda executa mount'
fi
if grep -Eq -- 'find[[:space:]].*-delete' "$RAIZ/etapas/14-working-disk.sh"; then
    falha 'etapas/14-working-disk.sh ainda contém remoção via find -delete'
fi
exigir_texto util/backup-vm.sh 'qemu-img check'
# I3: o campo backing-filename do JSON do qemu-img é lido pelo core Python. O
# utilitário continua obrigado a exigir ausência de backing chain e a nomear o
# arquivo encontrado no diagnóstico.
exigir_texto util/backup-vm.sh 'qemu-image-inspect'
exigir_texto util/backup-vm.sh 'backing file detectado'
exigir_texto libexec/passthrough_core/qemu_image.py 'full-backing-filename'
exigir_texto libexec/passthrough_core/qemu_image.py 'backing-filename'
exigir_texto util/snapshot-vm.sh 'vm_desligada "$VM_NAME" || falhar'
exigir_texto util/snapshot-vm.sh 'SNAPSHOT_DISKSPECS+=(--diskspec "$alvo,snapshot=$modo")'
rejeitar_texto util/snapshot-vm.sh '--disk-only'
exigir_texto util/atualizar-host.sh 'CONTINUAR SEM SNAPSHOT'
exigir_texto util/atualizar-host.sh 'util/snapshot-vm.sh'
rejeitar_texto util/atualizar-host.sh 'snapshot-create-as'
exigir_texto etapas/12-pacotes-base.sh 'acl)'
exigir_texto etapas/11-driver-nvidia.sh 'ubuntu-drivers devices'
exigir_texto etapas/61-airlock.sh 'ssh-keygen -l -f'
exigir_texto etapas/61-airlock.sh 'airlock_rollback()'
exigir_texto etapas/61-airlock.sh 'classificar_airlock_working_disk'
exigir_texto etapas/61-airlock.sh 'readlink -m -- "$AIRLOCK_TRANSITO"'
# I9.8 (REQ-AIRLOCK-VERIFY): o verificador precisa consultar a POLÍTICA
# EFETIVA. Antes, `sshd -T -C` existia apenas no caminho de aplicação e o
# verificador se contentava com a presença do arquivo.
exigir_texto_em_funcao etapas/61-airlock.sh verificar 'airlock_aval_sshd_efetivo'
exigir_texto_em_funcao etapas/61-airlock.sh verificar 'airlock_aval_politica_positiva'
exigir_texto_em_funcao etapas/61-airlock.sh verificar 'airlock_aval_politica_negativa'
exigir_texto_em_funcao etapas/61-airlock.sh airlock_aval_sshd_efetivo 'sshd -T -C'
rejeitar_texto_em_funcao etapas/61-airlock.sh verificar '[ -f "$SSHD_DROPIN" ]'
rejeitar_texto_em_funcao etapas/61-airlock.sh verificar 'Drop-in do sshd presente.'
# O mesmo avaliador serve ao apply, antes e depois do reload (pós-commit).
exigir_texto etapas/61-airlock.sh 'airlock_exigir_politica_sshd "antes do reload"'
exigir_texto etapas/61-airlock.sh 'airlock_exigir_politica_sshd "depois do reload"'
rejeitar_texto etapas/61-airlock.sh 'sshd -T -C "user=$TRANSFER_USER,addr=$VM_IP_FIXO,host=airlock" >/dev/null'
# Hermeticidade: os caminhos de sistema da etapa passam por caminho_sistema,
# senão o verificador leria o /etc real durante os testes.
exigir_texto etapas/61-airlock.sh 'caminho_sistema /etc/ssh/sshd_config.d/10-airlock.conf'
exigir_texto etapas/61-airlock.sh 'caminho_sistema /etc/ssh/authorized_keys'
exigir_texto etapas/61-airlock.sh 'caminho_sistema /etc/default/ufw'
exigir_texto etapas/61-airlock.sh 'caminho_sistema /etc/libvirt/hooks/qemu.d'
exigir_texto etapas/70-trim-discard.sh 'classificar_destino_backups'
exigir_texto util/backup-vm.sh 'classificar_destino_backup "$alvo"'

echo "AUDIT_SAFETY_TESTS_OK"
