#!/usr/bin/env bash
# Gate dirigido I9.8: prova semântica do Airlock (REQ-AIRLOCK-VERIFY).
#
# O que este teste protege: `61-airlock.sh --verificar` precisa provar a
# POLÍTICA EFETIVA, e não a presença de texto. O oráculo anterior aceitava
# `[ -f "$SSHD_DROPIN" ] && v_ok "Drop-in do sshd presente."`, ou seja, um
# arquivo no disco valia por "o sshd confina o usuário do airlock". Cada caso
# abaixo encena um estado em que o TEXTO continua lá e a política NÃO é
# efetiva, e exige que o verificador falhe.
#
# Hermético por construção (regra 12 da seção 0.1): tudo roda dentro do
# sandbox bubblewrap do mutator-harness, contra uma raiz simulada, com shims
# para sudo/sshd/ufw/findmnt/mountpoint/passwd/getent/stat. Nenhum sudo real,
# nenhum systemctl, nenhum mount e nenhuma escrita fora do sandbox.
#
# Códigos do protocolo: 0 concluído, 1 pendente, 2 indeterminado, 3 erro.
set -uo pipefail
RAIZ="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$RAIZ/tests/lib/mutator-harness.sh"

CASOS=0
fail() {
    printf 'FALHA I9.8 airlock-verify: %s\n' "$*" >&2
    if [[ -n ${MUTATOR_OUTPUT:-} && -s ${MUTATOR_OUTPUT:-/dev/null} ]]; then
        printf '%s\n' '--- stdout do verificador ---' >&2
        /usr/bin/sed 's/^/  /' "$MUTATOR_OUTPUT" >&2
    fi
    if [[ -n ${MUTATOR_ERROR:-} && -s ${MUTATOR_ERROR:-/dev/null} ]]; then
        printf '%s\n' '--- stderr do verificador ---' >&2
        /usr/bin/sed 's/^/  /' "$MUTATOR_ERROR" >&2
    fi
    if [[ -n ${MUTATOR_FORBIDDEN_LOG:-} && -s ${MUTATOR_FORBIDDEN_LOG:-/dev/null} ]]; then
        printf '%s\n' '--- acessos recusados ---' >&2
        /usr/bin/sed 's/^/  /' "$MUTATOR_FORBIDDEN_LOG" >&2
    fi
    exit 1
}
pass() { CASOS=$((CASOS + 1)); }

mutator_harness_setup || fail 'não foi possível preparar o sandbox'
trap 'mutator_harness_cleanup' EXIT HUP INT TERM

# Entrada do apply completo: confirma o drop-in, cola uma chave pública válida,
# recusa a regra anti-lockout e ativa o ufw.
CHAVE_VALIDA='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureChavePublicaDoAirlock airlock-vm'
APLICAR_INPUT=$'s\n'"$CHAVE_VALIDA"$'\nn\ns\n'
APLICADO="$MUTATOR_HARNESS_DIR/aplicado"

aplicar_airlock() {
    mutator_harness_run 61-airlock.sh "$APLICAR_INPUT"
}

salvar_aplicado() {
    /usr/bin/rm -rf "$APLICADO.root" "$APLICADO.state"
    /usr/bin/cp -a "$MUTATOR_ROOT" "$APLICADO.root"
    /usr/bin/cp -a "$MUTATOR_STATE_DIR" "$APLICADO.state"
}

restaurar_aplicado() {
    [[ -d $APLICADO.root ]] || fail 'estado aplicado não foi capturado'
    /usr/bin/rm -rf "$MUTATOR_ROOT" "$MUTATOR_STATE_DIR"
    /usr/bin/cp -a "$APLICADO.root" "$MUTATOR_ROOT"
    /usr/bin/cp -a "$APLICADO.state" "$MUTATOR_STATE_DIR"
    mutator_harness_clear_instrumentation
}

verificar_airlock() {
    mutator_harness_run 61-airlock.sh "" --verificar
}

# caso DESCRICAO RC_ESPERADO [TRECHO_OBRIGATORIO]
caso() {
    local descricao="$1" esperado="$2" trecho="${3:-}"
    verificar_airlock
    [[ $MUTATOR_RC -eq $esperado ]] \
        || fail "$descricao: esperado rc=$esperado, obtido rc=$MUTATOR_RC"
    [[ ! -s $MUTATOR_FORBIDDEN_LOG ]] \
        || fail "$descricao: o verificador tentou sair da raiz simulada"
    if [[ -n $trecho ]]; then
        /usr/bin/grep -Fq -- "$trecho" "$MUTATOR_OUTPUT" "$MUTATOR_ERROR" \
            || fail "$descricao: a saída não explica o motivo ('$trecho')"
    fi
    pass
}

perfil_sshd() { printf '%s\n' "$@" > "$MUTATOR_STATE_DIR/sshd-profile"; }

# ---------------------------------------------------------------------------
# 1. Host virgem: nada aplicado é PENDÊNCIA, nunca sucesso e nunca erro.
# ---------------------------------------------------------------------------
mutator_harness_reset
caso 'host virgem' 1 'Usuário vmtransfer ausente'
/usr/bin/grep -Fq 'Endurecimento global do sshd não é efetivo' "$MUTATOR_OUTPUT" \
    || fail 'host virgem: o endurecimento global não foi avaliado pela política efetiva'

# ---------------------------------------------------------------------------
# 2. Estado convergido: o apply real do sandbox produz rc 0.
# ---------------------------------------------------------------------------
mutator_harness_reset
aplicar_airlock
[[ $MUTATOR_RC -eq 0 ]] || fail "apply do airlock falhou (rc=$MUTATOR_RC)"
salvar_aplicado
mutator_harness_clear_instrumentation
caso 'estado aplicado' 0 'Confinamento efetivo de vmtransfer provado'

# ---------------------------------------------------------------------------
# 3. O falso sucesso central: drop-in presente, política inefetiva.
# ---------------------------------------------------------------------------
restaurar_aplicado
perfil_sshd 'contexto:-chrootdirectory'
[[ -f $MUTATOR_ROOT/etc/ssh/sshd_config.d/10-airlock.conf ]] \
    || fail 'o cenário exige o drop-in presente no disco'
/usr/bin/grep -q 'ChrootDirectory' "$MUTATOR_ROOT/etc/ssh/sshd_config.d/10-airlock.conf" \
    || fail 'o cenário exige ChrootDirectory escrito no drop-in'
caso 'drop-in presente sem chroot efetivo' 1 'chrootdirectory=<ausente>'

restaurar_aplicado
perfil_sshd 'contexto:forcecommand internal-sftp'
caso 'forcecommand efetivo divergente' 1 'forcecommand=internal-sftp (esperado'

restaurar_aplicado
perfil_sshd 'contexto:allowtcpforwarding yes'
caso 'allowtcpforwarding reaberto no Match' 1 'allowtcpforwarding=yes'

restaurar_aplicado
perfil_sshd 'contexto:authorizedkeysfile .ssh/authorized_keys'
caso 'authorizedkeysfile fora do controle do root' 1 'authorizedkeysfile=.ssh/authorized_keys'

restaurar_aplicado
perfil_sshd 'global:passwordauthentication yes'
caso 'passwordauthentication yes global' 1 'Endurecimento global do sshd não é efetivo'

restaurar_aplicado
perfil_sshd 'global:permitrootlogin yes'
caso 'permitrootlogin yes global' 1 'permitrootlogin=yes'

# ---------------------------------------------------------------------------
# 4. Saída inesperada do sshd: indeterminado, nunca pendência nem sucesso.
# ---------------------------------------------------------------------------
restaurar_aplicado
perfil_sshd '__modo=vazio'
caso 'sshd -T sem saída' 2 'vazia ou truncada'

restaurar_aplicado
perfil_sshd '__modo=truncado'
caso 'sshd -T truncado' 2 'vazia ou truncada'

restaurar_aplicado
perfil_sshd '__modo=erro'
caso 'sshd -T falhando' 2 'não pôde ser consultado'

restaurar_aplicado
/usr/bin/rm -f "$MUTATOR_ROOT/bin/sshd"
caso 'sshd fora do PATH' 2 'Ferramenta ausente (sshd)'

# ---------------------------------------------------------------------------
# 5. Sem sudo sem senha: indeterminado. É o estado real deste host de
#    desenvolvimento, e ele não pode virar pendência nem sucesso.
# ---------------------------------------------------------------------------
restaurar_aplicado
: > "$MUTATOR_STATE_DIR/sudo-sem-senha-negado"
caso 'sem sudo sem senha' 2 'Sem sudo sem senha'
/usr/bin/grep -Fq 'Linha bindfs do fstab provada' "$MUTATOR_OUTPUT" \
    || fail 'sem sudo: as provas não privilegiadas deveriam continuar sendo feitas'

# ---------------------------------------------------------------------------
# 6. Conta: identidade, GID primário, shell e cardinalidade no NSS.
# ---------------------------------------------------------------------------
restaurar_aplicado
printf '%s\n' \
    'fixture:x:1000:1000:Fixture:/home/fixture:/bin/bash' \
    'vmtransfer:x:998:998::/files:/bin/bash' > "$MUTATOR_STATE_DIR/nss-passwd"
caso 'shell com login na conta de transferência' 3 'precisa de nologin/false'

restaurar_aplicado
printf '%s\n' \
    'fixture:x:1000:1000:Fixture:/home/fixture:/bin/bash' \
    'vmtransfer:x:998:1000::/files:/usr/sbin/nologin' > "$MUTATOR_STATE_DIR/nss-passwd"
caso 'GID primário fora do grupo do airlock' 3 'GID primário de vmtransfer'

restaurar_aplicado
printf '%s\n' \
    'fixture:x:1000:1000:Fixture:/home/fixture:/bin/bash' \
    'vmtransfer:x:998:998::/files:/usr/sbin/nologin' \
    'vmtransfer:x:1001:1001::/home/vmtransfer:/bin/bash' > "$MUTATOR_STATE_DIR/nss-passwd"
caso 'duas entradas para a mesma conta' 3 'identidade da conta do airlock é ambígua'

# Conta compartilhada com a administração do host: a etapa aceita o valor
# (o useradd só roda quando a conta não existe) e o próprio texto da etapa
# 20.4 avisa contra ele. É o estado real deste host de desenvolvimento.
restaurar_aplicado
mutator_harness_set_conf TRANSFER_USER fixture
caso 'conta de transferência igual à de administração' 3 'mesma conta usada para administrar o host'
mutator_harness_set_conf TRANSFER_USER vmtransfer

restaurar_aplicado
printf 'P\n' > "$MUTATOR_STATE_DIR/passwd-status"
caso 'conta com senha utilizável' 3 'senha utilizável'

restaurar_aplicado
printf 'NP\n' > "$MUTATOR_STATE_DIR/passwd-status"
caso 'conta sem senha definida' 0 'sem senha definida'

# ---------------------------------------------------------------------------
# 7. fstab e montagem: configurado e ativo são fatos independentes.
# ---------------------------------------------------------------------------
restaurar_aplicado
/usr/bin/sed -i 's/,noexec//' "$MUTATOR_ROOT/etc/fstab"
caso 'fstab sem noexec' 1 'opções obrigatórias (noexec)'

restaurar_aplicado
/usr/bin/rm -f "$MUTATOR_STATE_DIR/airlock-mounted"
caso 'fstab correto e visão não montada' 1 'Nada montado em'

restaurar_aplicado
printf 'ext4|%s|rw,relatime\n' "$MUTATOR_AIRLOCK_TRANSIT" > "$MUTATOR_STATE_DIR/airlock-mount"
caso 'visão montada como ext4' 1 'é do tipo ext4, esperado fuse.bindfs'

restaurar_aplicado
printf 'fuse.bindfs|/outra/origem|rw,noexec,nosuid,nodev\n' > "$MUTATOR_STATE_DIR/airlock-mount"
caso 'visão montada a partir de outra origem' 1 'vem de /outra/origem'

restaurar_aplicado
printf 'fuse.bindfs|%s|rw,nosuid,nodev,relatime\n' "$MUTATOR_AIRLOCK_TRANSIT" \
    > "$MUTATOR_STATE_DIR/airlock-mount"
caso 'visão montada sem noexec' 1 "sem a opção obrigatória 'noexec'"

# ---------------------------------------------------------------------------
# 8. Chave: fingerprint, cardinalidade e modos.
# ---------------------------------------------------------------------------
restaurar_aplicado
printf 'isto nao e uma chave publica\n' > "$MUTATOR_ROOT/etc/ssh/authorized_keys/vmtransfer"
caso 'chave reprovada pelo ssh-keygen' 3 'não passa no ssh-keygen'

restaurar_aplicado
printf '%s\n%s\n' "$CHAVE_VALIDA" "$CHAVE_VALIDA" \
    > "$MUTATOR_ROOT/etc/ssh/authorized_keys/vmtransfer"
caso 'duas chaves autorizadas' 3 'autoriza 2 chaves'

restaurar_aplicado
/usr/bin/chmod 0644 "$MUTATOR_ROOT/etc/ssh/authorized_keys/vmtransfer"
caso 'chave em modo 644' 3 'esperado 600'

restaurar_aplicado
/usr/bin/rm -f "$MUTATOR_ROOT/etc/ssh/authorized_keys/vmtransfer"
caso 'chave ausente' 1 'Chave pública de vmtransfer pendente'

restaurar_aplicado
printf '%s|fixture|fixture\n' "$MUTATOR_ROOT/srv/airlock" > "$MUTATOR_STATE_DIR/stat-owners"
caso 'base do chroot fora do root' 3 'esperado root:root'

restaurar_aplicado
/usr/bin/chmod 0777 "$MUTATOR_ROOT/srv/airlock"
caso 'base do chroot escrevível por outros' 3 'o sshd recusa esse ChrootDirectory'

# ---------------------------------------------------------------------------
# 9. Firewall: políticas padrão, cardinalidade das regras e família IPv6.
# ---------------------------------------------------------------------------
restaurar_aplicado
printf 'allow allow\n' > "$MUTATOR_STATE_DIR/ufw-defaults"
caso 'ufw com default allow incoming' 1 "Política padrão de entrada do ufw é 'allow'"

restaurar_aplicado
/usr/bin/rm -f "$MUTATOR_STATE_DIR/ufw-active"
caso 'ufw inativo' 1 'ufw inativo'
/usr/bin/grep -Fq 'sudo sem senha' "$MUTATOR_OUTPUT" \
    && fail 'ufw inativo voltou a ser confundido com falta de sudo sem senha'

restaurar_aplicado
printf "ufw allow in on virbr-vmnat from 192.168.177.10 to any port 2222 proto tcp comment '%s'\n" \
    'SFTP airlock - somente VM Windows' >> "$MUTATOR_ROOT/etc/ufw/added.rules"
caso 'regra marcada fora do formato seguro' 3 'fora do formato seguro'

restaurar_aplicado
: > "$MUTATOR_STATE_DIR/ufw-v6-aberta"
caso 'IPV6=yes com a porta 22 aberta em v6' 1 'libera a porta 22 em IPv6'

restaurar_aplicado
/usr/bin/sed -i 's/^IPV6=.*/IPV6=no/' "$MUTATOR_ROOT/etc/default/ufw"
caso 'sshd em IPv6 com ufw sem IPv6' 1 'o ufw está com IPV6=no'

restaurar_aplicado
/usr/bin/sed -i 's/^IPV6=.*/IPV6=no/' "$MUTATOR_ROOT/etc/default/ufw"
perfil_sshd 'global:addressfamily inet'
caso 'sshd restrito a IPv4 com ufw sem IPv6' 0 'sshd restrito a inet'

# ---------------------------------------------------------------------------
# 10. Hook: presente, executável e gerado para ESTA configuração.
# ---------------------------------------------------------------------------
HOOK="$MUTATOR_ROOT/etc/libvirt/hooks/qemu.d/fixture-win11/prepare/begin/00-airlock.sh"

restaurar_aplicado
/usr/bin/rm -f "$HOOK"
caso 'hook ausente' 1 'Hook 00-airlock.sh ausente'

restaurar_aplicado
/usr/bin/chmod 0644 "$HOOK"
caso 'hook sem permissão de execução' 1 'sem permissão de execução'

restaurar_aplicado
/usr/bin/sed -i 's|^AIRLOCK_BIND=.*|AIRLOCK_BIND="/srv/outro/airlock"|' "$HOOK"
caso 'hook gerado para outra configuração' 1 'instalado para outra configuração'

# ---------------------------------------------------------------------------
# 11. O verificador não tem efeito colateral e é estável (regra 17).
# ---------------------------------------------------------------------------
restaurar_aplicado
mutator_harness_observable_manifest "$MUTATOR_HARNESS_DIR/verify-antes.exact" exact
verificar_airlock
[[ $MUTATOR_RC -eq 0 ]] || fail "verificação de controle deveria ser 0 (obtido $MUTATOR_RC)"
[[ $(mutator_harness_effect_count) -eq 0 ]] \
    || fail "--verificar registrou efeitos no host ($(mutator_harness_effect_count))"
/usr/bin/cp "$MUTATOR_OUTPUT" "$MUTATOR_HARNESS_DIR/verify-1.out"
mutator_harness_observable_manifest "$MUTATOR_HARNESS_DIR/verify-depois.exact" exact
/usr/bin/cmp -s "$MUTATOR_HARNESS_DIR/verify-antes.exact" "$MUTATOR_HARNESS_DIR/verify-depois.exact" \
    || fail '--verificar alterou conteúdo, modos ou mtimes da raiz simulada'
verificar_airlock
[[ $MUTATOR_RC -eq 0 ]] || fail 'segunda verificação divergiu da primeira'
/usr/bin/cmp -s "$MUTATOR_HARNESS_DIR/verify-1.out" "$MUTATOR_OUTPUT" \
    || fail 'segunda verificação não é no-op exato: a saída mudou'
mutator_harness_observable_manifest "$MUTATOR_HARNESS_DIR/verify-terceiro.exact" exact
/usr/bin/cmp -s "$MUTATOR_HARNESS_DIR/verify-antes.exact" "$MUTATOR_HARNESS_DIR/verify-terceiro.exact" \
    || fail 'segunda execução do verificador alterou a raiz simulada'
pass

# ---------------------------------------------------------------------------
# 12. O apply usa o MESMO avaliador: política inefetiva recusa e faz rollback,
#     inclusive quando a divergência só aparece DEPOIS do reload (pós-commit).
# ---------------------------------------------------------------------------
mutator_harness_reset
perfil_sshd 'contexto:-chrootdirectory'
aplicar_airlock
[[ $MUTATOR_RC -ne 0 ]] || fail 'o apply aceitou uma política efetiva sem chroot'
/usr/bin/grep -Fq 'Confinamento do usuário Airlock não é efetivo' "$MUTATOR_ERROR" \
    || fail 'o apply não usou o avaliador compartilhado para recusar'
[[ ! -e $MUTATOR_ROOT/etc/ssh/sshd_config.d/10-airlock.conf ]] \
    || fail 'o apply recusado deixou o drop-in publicado'
pass

mutator_harness_reset
printf '%s\n' 'contexto:-forcecommand' > "$MUTATOR_STATE_DIR/sshd-profile-apos-reload"
aplicar_airlock
[[ $MUTATOR_RC -ne 0 ]] || fail 'o apply aceitou divergência surgida após o reload'
/usr/bin/grep -Fq 'depois do reload' "$MUTATOR_ERROR" \
    || fail 'a pós-condição pós-commit do sshd não foi reavaliada após o reload'
[[ ! -e $MUTATOR_ROOT/etc/ssh/sshd_config.d/10-airlock.conf ]] \
    || fail 'a falha pós-commit não restaurou o drop-in anterior'
pass

printf 'I9_AIRLOCK_VERIFY_TESTS_OK (%s casos)\n' "$CASOS"
