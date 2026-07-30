#!/bin/bash
# ============================================================================
# etapas/14-docs4.sh - Capítulo 11: Configuração Completa do Docs4
# ============================================================================
# 1. Monta o HD2 (NTFS) permanentemente em /mnt/docs4 via ntfs-3g com
#    windows_names/uid/gid/umask/nofail (linha gerenciada no fstab).
# 2. Cria os diretórios de destino no HD2 (sem acentos, como no manual).
# 3. Adiciona os 5 bind mounts (Documentos, Downloads, Imagens, Músicas,
#    Vídeos) apontando para o HD2.
# 4. Migra o conteúdo existente com rsync (verificação dupla) e só apaga os
#    originais após confirmação explícita digitando SIM.
#
# Segurança: backup datado do fstab antes de qualquer edição; linhas
# idempotentes (reexecutar não duplica); nofail em tudo.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf
DOCS4="${DOCS4_MONTAGEM:-/mnt/docs4}"

# Pastas no HD2 (sem acento, por interoperabilidade NTFS: nota do Capítulo 11)
HD2_DIRS=(Documentos Downloads Imagens Musicas Videos)
# Chaves XDG correspondentes (para achar o caminho REAL de cada pasta do usuário)
XDG_CHAVES=(DOCUMENTS DOWNLOAD PICTURES MUSIC VIDEOS)
# Nomes padrão em pt-BR (fallback quando xdg-user-dir não resolver)
PT_DIRS=(Documentos Downloads Imagens "Músicas" "Vídeos")

resolver_dir_usuario() {
    # resolver_dir_usuario CHAVE_XDG NOME_PADRAO -> caminho real da pasta
    local chave="$1" padrao="$2" home_usuario resolvido
    home_usuario="$(getent passwd "$USUARIO_LINUX" | cut -d: -f6)"
    resolvido="$(xdg-user-dir "$chave" 2>/dev/null || true)"
    # xdg-user-dir devolve o próprio $HOME quando a pasta não está configurada:
    # nesse caso (ou fora do home do usuário), usa o nome padrão do manual.
    if [ -z "$resolvido" ] || [ "$resolvido" = "$home_usuario" ] || [[ "$resolvido" != "$home_usuario"/* ]]; then
        resolvido="$home_usuario/$padrao"
    fi
    echo "$resolvido"
}

escapar_fstab() { sed 's/ /\\040/g' <<< "$1"; }

verificar() {
    [ -n "${USUARIO_LINUX:-}" ] || { v_falta "USUARIO_LINUX não definido (etapa 02)."; v_fim; }
    if mountpoint -q "$DOCS4"; then
        v_ok "$DOCS4 montado."
    else
        v_falta "$DOCS4 não está montado."
    fi
    local i destino
    for i in "${!HD2_DIRS[@]}"; do
        destino="$(resolver_dir_usuario "${XDG_CHAVES[$i]}" "${PT_DIRS[$i]}")"
        if mountpoint -q "$destino" 2>/dev/null; then
            v_ok "bind ativo: $destino"
        else
            v_falta "bind inativo: $destino"
        fi
    done
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

exigir_nao_root
exigir_sudo
exigir_comando rsync
exigir_conf UUID_HD2 USUARIO_LINUX
dpkg -s ntfs-3g >/dev/null 2>&1 || falhar "ntfs-3g não instalado. Execute a etapa 12 antes."

UID_USUARIO="$(id -u "$USUARIO_LINUX")"
GID_USUARIO="$(id -g "$USUARIO_LINUX")"
HOME_USUARIO="$(getent passwd "$USUARIO_LINUX" | cut -d: -f6)"

titulo "Capítulo 11: Docs4 (HD2 em $DOCS4)"
info "Usuário: $USUARIO_LINUX (uid=$UID_USUARIO gid=$GID_USUARIO)  UUID do HD2: $UUID_HD2"

# ----------------------------------------------------------------------------
# 1. Montagem do HD2 via fstab
# ----------------------------------------------------------------------------
titulo "1/4 Montagem do HD2"
fstab_backup
fstab_definir_linha docs4 \
    "UUID=$UUID_HD2  $(escapar_fstab "$DOCS4")  ntfs-3g  defaults,windows_names,uid=$UID_USUARIO,gid=$GID_USUARIO,umask=022,nofail  0  0"

info "Testando a montagem antes de qualquer reboot (mount -a)..."
sudo mount -a
mountpoint -q "$DOCS4" || falhar "HD2 não montou em $DOCS4. Confira 'sudo blkid' e a linha adicionada ao fstab."
ok "HD2 montado:"
df -h "$DOCS4" | sed 's/^/  /'

# ----------------------------------------------------------------------------
# 2. Diretórios de destino no HD2
# ----------------------------------------------------------------------------
titulo "2/4 Diretórios no HD2"
for d in "${HD2_DIRS[@]}"; do
    sudo mkdir -p "$DOCS4/$d"
done
# Em NTFS com uid/gid/umask o chown não persiste (nota do Capítulo 11);
# mantido por robustez para o caso de migração futura a um FS POSIX.
sudo chown "$USUARIO_LINUX:$USUARIO_LINUX" "${HD2_DIRS[@]/#/$DOCS4/}" 2>/dev/null || true
ok "Diretórios garantidos: ${HD2_DIRS[*]}"

# ----------------------------------------------------------------------------
# 3. Bind mounts no fstab
# ----------------------------------------------------------------------------
titulo "3/4 Bind mounts"
declare -a DESTINOS=()
for i in "${!HD2_DIRS[@]}"; do
    DESTINO="$(resolver_dir_usuario "${XDG_CHAVES[$i]}" "${PT_DIRS[$i]}")"
    DESTINOS+=("$DESTINO")
    mkdir -p "$DESTINO" 2>/dev/null || sudo -u "$USUARIO_LINUX" mkdir -p "$DESTINO"
    fstab_definir_linha "docs4-bind-${HD2_DIRS[$i]}" \
        "$(escapar_fstab "$DOCS4/${HD2_DIRS[$i]}")  $(escapar_fstab "$DESTINO")  none  bind,nofail,x-systemd.requires=$(escapar_fstab "$DOCS4")  0  0"
done

# ----------------------------------------------------------------------------
# 4. Migração dos dados existentes (antes de ativar os binds)
# ----------------------------------------------------------------------------
titulo "4/4 Migração de dados"
declare -a MIGRADOS=()
for i in "${!HD2_DIRS[@]}"; do
    ORIGEM="${DESTINOS[$i]}"
    ALVO="$DOCS4/${HD2_DIRS[$i]}"

    if mountpoint -q "$ORIGEM"; then
        info "$ORIGEM já é um bind mount ativo; migração desnecessária."
        continue
    fi
    if [ -z "$(ls -A "$ORIGEM" 2>/dev/null)" ]; then
        info "$ORIGEM está vazio; nada a migrar."
        continue
    fi

    info "Migrando: $ORIGEM/ -> $ALVO/"
    rsync -avh --progress "$ORIGEM/" "$ALVO/"

    # Segunda passada (dry-run): nada pode restar pendente de cópia
    PENDENTES="$(rsync -a --itemize-changes --dry-run "$ORIGEM/" "$ALVO/" | grep -c '^[<>]f' || true)"
    if [ "${PENDENTES:-0}" -ne 0 ]; then
        falhar "Verificação da cópia de $ORIGEM falhou ($PENDENTES arquivo(s) pendente(s)). Nada foi apagado."
    fi
    ok "Cópia íntegra: $ORIGEM ($(du -sh "$ORIGEM" 2>/dev/null | cut -f1))"
    MIGRADOS+=("$ORIGEM")
done

if [ "${#MIGRADOS[@]}" -gt 0 ]; then
    echo
    echo "Diretórios migrados cujo conteúdo ORIGINAL (no NVMe) será apagado:"
    printf '  - %s\n' "${MIGRADOS[@]}"
    if confirmar_digitando "SIM" "Ação DESTRUTIVA e sem lixeira. A cópia no HD2 já foi verificada (rsync 2x)."; then
        for ORIGEM in "${MIGRADOS[@]}"; do
            find "$ORIGEM" -mindepth 1 -delete
            info "Limpo: $ORIGEM"
        done
    else
        aviso "Limpeza cancelada. Os bind mounts vão COBRIR o conteúdo antigo do NVMe"
        aviso "(os arquivos continuam lá, ocupando espaço, mas inacessíveis com o bind ativo)."
    fi
fi

info "Ativando bind mounts (mount -a)..."
sudo mount -a

echo
titulo "Verificação final"
mount | grep -E "docs4|Documentos|Downloads|Imagens|Músicas|Vídeos|Documents|Pictures|Music|Videos" || true
TESTE="$DOCS4/Documentos/.teste-bind-$$.txt"
sudo -u "$USUARIO_LINUX" touch "${DESTINOS[0]}/.teste-bind-$$.txt"
if [ -f "$TESTE" ]; then
    ok "Bind mount confirmado: arquivo criado via ${DESTINOS[0]} apareceu no HD2."
    rm -f "$TESTE"
else
    aviso "Teste de bind não confirmado; revise 'mount | grep docs4'."
fi

# Proteção windows_names deve REJEITAR nomes inválidos no Windows
if touch "$DOCS4/teste:invalido?.txt" 2>/dev/null; then
    aviso "windows_names NÃO está ativo (o nome inválido foi aceito). Revise a linha do fstab."
    rm -f "$DOCS4/teste:invalido?.txt" 2>/dev/null || true
else
    ok "Proteção windows_names ativa (nome inválido rejeitado, como esperado)."
fi

echo
ok "Docs4 concluído. Reversão: restaurar o backup do fstab e desmontar (Capítulo 11, 'Como desfazer')."
