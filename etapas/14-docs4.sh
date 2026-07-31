#!/bin/bash
# ============================================================================
# etapas/14-docs4.sh - Capítulo 11: Configuração Completa do Docs4
# ============================================================================
# Valida inequivocamente HD2, disco do sistema e HD1 antes de montar; testa a
# montagem; migra os dados para o HD2 preservando os originais em backups
# adjacentes; e só então publica uma imagem única e validada do fstab.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

DOCS4="/mnt/docs4"
FSTAB_LOCK_ARQUIVO="/run/lock/vm-passthrough-fstab.lock"
HD2_DIRS=(Documentos Downloads Imagens Musicas Videos)
XDG_CHAVES=(DOCUMENTS DOWNLOAD PICTURES MUSIC VIDEOS)
PT_DIRS=(Documentos Downloads Imagens "Músicas" "Vídeos")

IDENTIDADE_DIAGNOSTICO=""
USUARIO_DIAGNOSTICO=""
XDG_DIAGNOSTICO=""
MOUNT_DIAGNOSTICO=""
FSTAB_DIAGNOSTICO=""
DISCO_FISICO_CANONICO=""
HD2_PARTICAO=""
HD2_DISCO_CANONICO=""
DISCO_SISTEMA_CANONICO=""
HD1_DISCO_CANONICO=""
UID_USUARIO=""
GID_USUARIO=""
HOME_USUARIO=""
SUDO_USUARIO_NAO_INTERATIVO=0

TMP_DIR=""
FSTAB_ORIGINAL_TMP=""
FSTAB_CANDIDATO=""
FSTAB_BACKUP=""
FSTAB_STAGE=""
FSTAB_INSTALADO=0
FSTAB_RENAME_INTENCAO=0
FSTAB_RESTORE_INTENCAO=0
FSTAB_CONFLITO_CANDIDATO=""
FSTAB_LOCK_PID=""
FSTAB_LOCK_LEITURA=""
FSTAB_LOCK_ESCRITA=""
TRANSACAO_CONCLUIDA=0
ROLLBACK_EM_CURSO=0
ROLLBACK_FALHOU=0
TESTE_VALIDO=""
TESTE_INVALIDO=""
RSYNC_DIAGNOSTICO=""
RSYNC_STATUS_REAL=0

BACKUPS_ENCONTRADOS=()
declare -a DESTINOS=()
declare -a BIND_ATIVO_INICIAL=()
declare -a MOUNT_INTENCOES_ALVOS=()
declare -a MOUNT_INTENCOES_TIPOS=()
declare -a MOUNT_INTENCOES_IDS=()
MOUNT_INTENCAO_INDICE=-1
declare -a MIGRACAO_ORIGENS=()
declare -a MIGRACAO_BACKUPS=()
declare -a MIGRACAO_IDENTIDADES=()
declare -a ORFAO_ORIGENS=()
declare -a ORFAO_BACKUPS=()
declare -a ORFAO_IDENTIDADES=()
declare -a BACKUPS_RETIDOS=()
declare -a FSTAB_IDS=()
declare -a FSTAB_FONTES=()
declare -a FSTAB_ALVOS=()
declare -a FSTAB_TIPOS=()
declare -a FSTAB_OPCOES=()

validar_docs4_normativo() {
    if [ "${DOCS4_MONTAGEM:-$DOCS4}" != "$DOCS4" ]; then
        MOUNT_DIAGNOSTICO="DOCS4_MONTAGEM deve ser exatamente $DOCS4; encontrado: ${DOCS4_MONTAGEM:-<vazio>}."
        return 1
    fi
}

opcao_mount_presente() {
    local opcoes=",$1," opcao="$2"
    [[ "$opcoes" == *",$opcao,"* ]]
}

dispositivo_bloco_valido() {
    [[ "${1:-}" == /dev/* ]] && [ -b "$1" ]
}

resolver_disco_fisico() {
    local dispositivo="${1:-}" canonico saida nome tipo extra disco
    local -A discos=()

    DISCO_FISICO_CANONICO=""
    canonico="$(readlink -f -- "$dispositivo" 2>/dev/null || true)"
    if [ -z "$canonico" ] || [[ "$canonico" == *$'\n'* ]] \
        || ! dispositivo_bloco_valido "$canonico"; then
        IDENTIDADE_DIAGNOSTICO="Dispositivo de bloco inválido ou indisponível: $dispositivo"
        return 1
    fi

    saida="$(LC_ALL=C lsblk -srpn -o KNAME,TYPE -- "$canonico" 2>/dev/null)" || {
        IDENTIDADE_DIAGNOSTICO="Não foi possível percorrer a cadeia física de $canonico."
        return 1
    }
    [ -n "$saida" ] || {
        IDENTIDADE_DIAGNOSTICO="A cadeia física de $canonico está vazia."
        return 1
    }

    while read -r nome tipo extra; do
        [ -n "$nome" ] || continue
        if [ -n "${extra:-}" ] || [ -z "${tipo:-}" ]; then
            IDENTIDADE_DIAGNOSTICO="Saída lsblk ambígua ao resolver $canonico."
            return 1
        fi
        [[ "$nome" == /dev/* ]] || nome="/dev/$nome"
        nome="$(readlink -f -- "$nome" 2>/dev/null || true)"
        if [ "$tipo" = "disk" ]; then
            dispositivo_bloco_valido "$nome" || {
                IDENTIDADE_DIAGNOSTICO="Disco físico inválido na cadeia de $canonico: $nome"
                return 1
            }
            discos[$nome]=1
        fi
    done <<< "$saida"

    if [ "${#discos[@]}" -ne 1 ]; then
        IDENTIDADE_DIAGNOSTICO="A cadeia de $canonico não leva inequivocamente a um único disco físico."
        return 1
    fi
    for disco in "${!discos[@]}"; do
        DISCO_FISICO_CANONICO="$disco"
    done
}

executar_blkid() {
    local usar_sudo="$1"
    shift
    if [ "$usar_sudo" -eq 1 ]; then
        sudo blkid "$@"
    else
        blkid "$@"
    fi
}

enumerar_uuid_hd2_sem_cache() {
    local usar_sudo="$1" saida status linha canonico
    local -a dispositivos=()

    HD2_PARTICAO=""
    if saida="$(executar_blkid "$usar_sudo" -c /dev/null \
        -t "UUID=$UUID_HD2" -o device 2>/dev/null)"; then
        status=0
    else
        status=$?
        if [ "$status" -eq 2 ]; then
            saida=""
        else
            IDENTIDADE_DIAGNOSTICO="Falha ao enumerar UUID_HD2=$UUID_HD2 sem cache (status blkid $status)."
            return "$status"
        fi
    fi

    while IFS= read -r linha; do
        [ -n "$linha" ] || continue
        [[ "$linha" == /dev/* ]] && [[ "$linha" != *[[:cntrl:]]* ]] || {
            IDENTIDADE_DIAGNOSTICO="blkid retornou um dispositivo inválido para UUID_HD2: $linha"
            return 1
        }
        canonico="$(readlink -f -- "$linha" 2>/dev/null || true)"
        dispositivo_bloco_valido "$canonico" || {
            IDENTIDADE_DIAGNOSTICO="UUID_HD2 retornou um dispositivo de bloco indisponível: $linha"
            return 1
        }
        dispositivos+=("$canonico")
    done <<< "$saida"

    [ "${#dispositivos[@]}" -eq 1 ] || {
        IDENTIDADE_DIAGNOSTICO="UUID_HD2=$UUID_HD2 deve resolver sem cache para exatamente um dispositivo; encontrados: ${#dispositivos[@]}."
        return 1
    }
    HD2_PARTICAO="${dispositivos[0]}"
}

resolver_identidades() {
    local usar_sudo="$1" raiz origem nvme_canonico nvme_fisico
    local hd2 hd2_tipo hd2_fstype hd2_uuid hd2_pai_config
    local hd1_alvo hd1_rel hd1_fisico

    IDENTIDADE_DIAGNOSTICO=""
    HD2_PARTICAO=""
    HD2_DISCO_CANONICO=""
    DISCO_SISTEMA_CANONICO=""
    HD1_DISCO_CANONICO=""

    [[ "${UUID_HD2:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
        IDENTIDADE_DIAGNOSTICO="UUID_HD2 está ausente ou tem formato inválido."
        return 1
    }

    origem="$(findmnt -nro SOURCE --no-encode --target / 2>/dev/null)" || {
        IDENTIDADE_DIAGNOSTICO="Não foi possível identificar o dispositivo que contém /."
        return 1
    }
    [ -n "$origem" ] && [[ "$origem" != *$'\n'* ]] || {
        IDENTIDADE_DIAGNOSTICO="A origem de / não é única."
        return 1
    }
    origem="${origem%%\[*}"
    resolver_disco_fisico "$origem" || return 1
    DISCO_SISTEMA_CANONICO="$DISCO_FISICO_CANONICO"

    nvme_canonico="$(readlink -f -- "${NVME_DEVICE:-}" 2>/dev/null || true)"
    dispositivo_bloco_valido "$nvme_canonico" || {
        IDENTIDADE_DIAGNOSTICO="NVME_DEVICE é inválido ou indisponível: ${NVME_DEVICE:-<vazio>}"
        return 1
    }
    [ "$nvme_canonico" = "$NVME_DEVICE" ] || {
        IDENTIDADE_DIAGNOSTICO="NVME_DEVICE deve ser o caminho canônico do disco inteiro: $nvme_canonico"
        return 1
    }
    [ "$(lsblk -dnro TYPE -- "$nvme_canonico" 2>/dev/null)" = "disk" ] || {
        IDENTIDADE_DIAGNOSTICO="NVME_DEVICE deve apontar para um disco físico inteiro."
        return 1
    }
    resolver_disco_fisico "$nvme_canonico" || return 1
    nvme_fisico="$DISCO_FISICO_CANONICO"
    [ "$nvme_canonico" = "$nvme_fisico" ] \
        && [ "$nvme_fisico" = "$DISCO_SISTEMA_CANONICO" ] || {
        IDENTIDADE_DIAGNOSTICO="NVME_DEVICE não corresponde canonicamente ao disco físico que contém /."
        return 1
    }

    enumerar_uuid_hd2_sem_cache "$usar_sudo" || return 1
    hd2="$HD2_PARTICAO"
    hd2_tipo="$(lsblk -dnro TYPE -- "$hd2" 2>/dev/null || true)"
    [ "$hd2_tipo" = "part" ] || {
        IDENTIDADE_DIAGNOSTICO="UUID_HD2 deve identificar uma partição; tipo encontrado: ${hd2_tipo:-desconhecido}."
        return 1
    }
    hd2_fstype="$(lsblk -dnro FSTYPE -- "$hd2" 2>/dev/null || true)"
    [ "$hd2_fstype" = "ntfs" ] || [ "$hd2_fstype" = "ntfs3" ] || {
        IDENTIDADE_DIAGNOSTICO="UUID_HD2 deve identificar NTFS; tipo encontrado: ${hd2_fstype:-desconhecido}."
        return 1
    }
    hd2_uuid="$(lsblk -dnro UUID -- "$hd2" 2>/dev/null || true)"
    [ "$hd2_uuid" = "$UUID_HD2" ] || {
        IDENTIDADE_DIAGNOSTICO="A partição $hd2 não confirma UUID_HD2=$UUID_HD2."
        return 1
    }
    resolver_disco_fisico "$hd2" || return 1
    HD2_DISCO_CANONICO="$DISCO_FISICO_CANONICO"

    hd2_pai_config="$(readlink -f -- "${HD2_DISCO_PAI:-}" 2>/dev/null || true)"
    dispositivo_bloco_valido "$hd2_pai_config" || {
        IDENTIDADE_DIAGNOSTICO="HD2_DISCO_PAI é inválido ou indisponível: ${HD2_DISCO_PAI:-<vazio>}"
        return 1
    }
    [ "$hd2_pai_config" = "$HD2_DISCO_PAI" ] \
        && [ "$(lsblk -dnro TYPE -- "$hd2_pai_config" 2>/dev/null)" = "disk" ] || {
        IDENTIDADE_DIAGNOSTICO="HD2_DISCO_PAI deve ser o caminho canônico de um disco físico inteiro."
        return 1
    }
    resolver_disco_fisico "$hd2_pai_config" || return 1
    [ "$hd2_pai_config" = "$DISCO_FISICO_CANONICO" ] \
        && [ "$hd2_pai_config" = "$HD2_DISCO_CANONICO" ] || {
        IDENTIDADE_DIAGNOSTICO="HD2_DISCO_PAI diverge do disco físico canônico derivado de UUID_HD2."
        return 1
    }
    [ "$HD2_DISCO_CANONICO" != "$DISCO_SISTEMA_CANONICO" ] \
        && [ "$HD2_DISCO_CANONICO" != "$nvme_fisico" ] || {
        IDENTIDADE_DIAGNOSTICO="UUID_HD2 aponta para o disco do sistema/NVME_DEVICE; montagem recusada."
        return 1
    }

    [[ "${HD1_BY_ID_PATH:-}" == /dev/disk/by-id/* ]] || {
        IDENTIDADE_DIAGNOSTICO="HD1_BY_ID_PATH deve usar /dev/disk/by-id/."
        return 1
    }
    hd1_rel="${HD1_BY_ID_PATH#/dev/disk/by-id/}"
    [ -n "$hd1_rel" ] && [[ "$hd1_rel" != */* ]] \
        && [ "$hd1_rel" != "." ] && [ "$hd1_rel" != ".." ] \
        && [[ "$hd1_rel" != *[[:cntrl:]]* ]] || {
        IDENTIDADE_DIAGNOSTICO="HD1_BY_ID_PATH contém um nome inseguro."
        return 1
    }
    [ -L "$HD1_BY_ID_PATH" ] || {
        IDENTIDADE_DIAGNOSTICO="HD1_BY_ID_PATH deve ser um link by-id real e disponível."
        return 1
    }
    hd1_alvo="$(readlink -f -- "$HD1_BY_ID_PATH" 2>/dev/null || true)"
    dispositivo_bloco_valido "$hd1_alvo" \
        && [ "$(lsblk -dnro TYPE -- "$hd1_alvo" 2>/dev/null)" = "disk" ] || {
        IDENTIDADE_DIAGNOSTICO="HD1_BY_ID_PATH deve resolver para um disco físico inteiro."
        return 1
    }
    resolver_disco_fisico "$hd1_alvo" || return 1
    hd1_fisico="$DISCO_FISICO_CANONICO"
    [ "$hd1_alvo" = "$hd1_fisico" ] || {
        IDENTIDADE_DIAGNOSTICO="HD1_BY_ID_PATH não resolve canonicamente para o disco inteiro."
        return 1
    }
    [ "$hd1_fisico" != "$DISCO_SISTEMA_CANONICO" ] \
        && [ "$hd1_fisico" != "$nvme_fisico" ] || {
        IDENTIDADE_DIAGNOSTICO="HD1_BY_ID_PATH aponta para o disco do sistema/NVME_DEVICE."
        return 1
    }
    [ "$hd1_fisico" != "$HD2_DISCO_CANONICO" ] || {
        IDENTIDADE_DIAGNOSTICO="UUID_HD2/HD2_DISCO_PAI apontam para o mesmo disco físico do HD1."
        return 1
    }

    HD2_PARTICAO="$hd2"
    HD1_DISCO_CANONICO="$hd1_fisico"
}

carregar_usuario() {
    local registro nome senha uid gid gecos home shell uid_id gid_id home_real dono_home

    USUARIO_DIAGNOSTICO=""
    [[ "${USUARIO_LINUX:-}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || {
        USUARIO_DIAGNOSTICO="USUARIO_LINUX está ausente ou tem formato inválido."
        return 1
    }
    registro="$(getent passwd -- "$USUARIO_LINUX" 2>/dev/null || true)"
    [ -n "$registro" ] && [[ "$registro" != *$'\n'* ]] || {
        USUARIO_DIAGNOSTICO="USUARIO_LINUX não corresponde a uma única conta local/NSS."
        return 1
    }
    IFS=: read -r nome senha uid gid gecos home shell <<< "$registro"
    [ "$nome" = "$USUARIO_LINUX" ] \
        && [[ "$uid" =~ ^[0-9]+$ ]] && [[ "$gid" =~ ^[0-9]+$ ]] \
        && [[ "$home" == /* ]] && [[ "$home" != *[[:cntrl:]]* ]] || {
        USUARIO_DIAGNOSTICO="Registro NSS inválido para USUARIO_LINUX."
        return 1
    }
    uid_id="$(id -u -- "$USUARIO_LINUX" 2>/dev/null || true)"
    gid_id="$(id -g -- "$USUARIO_LINUX" 2>/dev/null || true)"
    [ "$uid" = "$uid_id" ] && [ "$gid" = "$gid_id" ] || {
        USUARIO_DIAGNOSTICO="UID/GID de getent e id divergem para $USUARIO_LINUX."
        return 1
    }
    [ ! -L "$home" ] && [ -d "$home" ] || {
        USUARIO_DIAGNOSTICO="HOME de $USUARIO_LINUX deve ser um diretório real, não um symlink: $home"
        return 1
    }
    home_real="$(readlink -f -- "$home" 2>/dev/null || true)"
    [ "$home_real" = "$home" ] || {
        USUARIO_DIAGNOSTICO="HOME de $USUARIO_LINUX não é um caminho canônico: $home"
        return 1
    }
    dono_home="$(stat -c '%u:%g' -- "$home" 2>/dev/null || true)"
    [ "$dono_home" = "$uid:$gid" ] || {
        USUARIO_DIAGNOSTICO="HOME de $USUARIO_LINUX deve pertencer a $uid:$gid; encontrado ${dono_home:-desconhecido}."
        return 1
    }

    UID_USUARIO="$uid"
    GID_USUARIO="$gid"
    HOME_USUARIO="$home"
}

como_usuario() {
    if [ "$(id -u)" = "$UID_USUARIO" ]; then
        env HOME="$HOME_USUARIO" XDG_CONFIG_HOME="$HOME_USUARIO/.config" "$@"
    elif [ "$SUDO_USUARIO_NAO_INTERATIVO" -eq 1 ]; then
        sudo -n -u "$USUARIO_LINUX" -- \
            env HOME="$HOME_USUARIO" XDG_CONFIG_HOME="$HOME_USUARIO/.config" "$@"
    else
        sudo -u "$USUARIO_LINUX" -- \
            env HOME="$HOME_USUARIO" XDG_CONFIG_HOME="$HOME_USUARIO/.config" "$@"
    fi
}

validar_componentes_sem_symlink() {
    local caminho="$1" relativo componente atual="$HOME_USUARIO"
    local -a componentes=()

    [ ! -L "$HOME_USUARIO" ] || return 1
    relativo="${caminho#"$HOME_USUARIO"/}"
    IFS=/ read -r -a componentes <<< "$relativo"
    for componente in "${componentes[@]}"; do
        [ -n "$componente" ] || return 1
        atual="$atual/$componente"
        [ ! -L "$atual" ] || return 1
        if [ -e "$atual" ] && [ ! -d "$atual" ]; then
            return 1
        fi
    done
}

resolver_dir_usuario() {
    local chave="$1" padrao="$2" resolvido canonico

    XDG_DIAGNOSTICO=""
    XDG_RESOLVIDO=""
    resolvido="$(como_usuario xdg-user-dir "$chave" 2>/dev/null)" || {
        XDG_DIAGNOSTICO="Não foi possível resolver XDG_$chave como $USUARIO_LINUX."
        return 1
    }
    if [ -z "$resolvido" ] || [ "$resolvido" = "$HOME_USUARIO" ]; then
        resolvido="$HOME_USUARIO/$padrao"
    fi
    [[ "$resolvido" == "$HOME_USUARIO/"* ]] \
        && [[ "$resolvido" != *[[:cntrl:]]* ]] || {
        XDG_DIAGNOSTICO="XDG_$chave deve ficar estritamente dentro de $HOME_USUARIO; encontrado: $resolvido"
        return 1
    }
    canonico="$(readlink -m -- "$resolvido" 2>/dev/null || true)"
    [ "$canonico" = "$resolvido" ] || {
        XDG_DIAGNOSTICO="XDG_$chave contém symlink, '..' ou caminho não canônico: $resolvido"
        return 1
    }
    if [ "$resolvido" = "$DOCS4" ] \
        || [[ "$resolvido" == "$DOCS4/"* ]] \
        || [[ "$DOCS4" == "$resolvido/"* ]]; then
        XDG_DIAGNOSTICO="XDG_$chave não pode ser igual, ancestral ou descendente de $DOCS4: $resolvido"
        return 1
    fi
    validar_componentes_sem_symlink "$resolvido" || {
        XDG_DIAGNOSTICO="XDG_$chave contém symlink ou componente que não é diretório: $resolvido"
        return 1
    }
    XDG_RESOLVIDO="$resolvido"
}

resolver_todos_destinos() {
    local i j destino outro
    local -A vistos=()

    DESTINOS=()
    for i in "${!HD2_DIRS[@]}"; do
        resolver_dir_usuario "${XDG_CHAVES[$i]}" "${PT_DIRS[$i]}" || return 1
        destino="$XDG_RESOLVIDO"
        [ -z "${vistos[$destino]+definido}" ] || {
            XDG_DIAGNOSTICO="Duas chaves XDG resolvem para o mesmo diretório: $destino"
            return 1
        }
        for j in "${!DESTINOS[@]}"; do
            outro="${DESTINOS[$j]}"
            if [[ "$destino" == "$outro/"* ]] || [[ "$outro" == "$destino/"* ]]; then
                XDG_DIAGNOSTICO="Diretórios XDG não podem ser aninhados: $destino e $outro"
                return 1
            fi
        done
        vistos[$destino]=1
        DESTINOS+=("$destino")
    done
}

obter_mount_exato() {
    local alvo="$1"

    MOUNT_SOURCE="$(findmnt -rn --no-encode -M "$alvo" -o SOURCE 2>/dev/null)" || return 1
    MOUNT_TARGET="$(findmnt -rn --no-encode -M "$alvo" -o TARGET 2>/dev/null)" || return 1
    MOUNT_FSTYPE="$(findmnt -rn --no-encode -M "$alvo" -o FSTYPE 2>/dev/null)" || return 1
    MOUNT_UUID="$(findmnt -rn --no-encode -M "$alvo" -o UUID 2>/dev/null)" || return 1
    MOUNT_OPTIONS="$(findmnt -rn --no-encode -M "$alvo" -o OPTIONS 2>/dev/null)" || return 1
    MOUNT_FSROOT="$(findmnt -rn --no-encode -M "$alvo" -o FSROOT 2>/dev/null)" || return 1
    [ -n "$MOUNT_SOURCE" ] && [ "$MOUNT_TARGET" = "$alvo" ] \
        && [[ "$MOUNT_SOURCE$MOUNT_TARGET$MOUNT_FSTYPE$MOUNT_UUID$MOUNT_OPTIONS$MOUNT_FSROOT" != *$'\n'* ]]
}

validar_opcoes_runtime_rw() {
    opcao_mount_presente "$1" rw && ! opcao_mount_presente "$1" ro
}

validar_base_montada() {
    local origem metadados

    MOUNT_DIAGNOSTICO=""
    obter_mount_exato "$DOCS4" || {
        MOUNT_DIAGNOSTICO="$DOCS4 não é um mountpoint exato."
        return 1
    }
    [[ "$MOUNT_SOURCE" != *"["* ]] && [[ "$MOUNT_SOURCE" != *"]"* ]] \
        && [ "$MOUNT_FSROOT" = "/" ] || {
        MOUNT_DIAGNOSTICO="$DOCS4 deve montar a raiz / da partição, sem root/subpath em SOURCE; encontrados SOURCE=${MOUNT_SOURCE:-desconhecido}, FSROOT=${MOUNT_FSROOT:-desconhecido}."
        return 1
    }
    origem="$(readlink -f -- "$MOUNT_SOURCE" 2>/dev/null || true)"
    [ "$origem" = "$HD2_PARTICAO" ] && [ "$MOUNT_UUID" = "$UUID_HD2" ] || {
        MOUNT_DIAGNOSTICO="$DOCS4 aponta para ${MOUNT_SOURCE:-origem desconhecida} (UUID=${MOUNT_UUID:-desconhecido}); esperados a raiz de $HD2_PARTICAO e UUID=$UUID_HD2."
        return 1
    }
    [ "$MOUNT_FSTYPE" = "fuseblk" ] || {
        MOUNT_DIAGNOSTICO="$DOCS4 usa '$MOUNT_FSTYPE'; esperado ntfs-3g (fuseblk)."
        return 1
    }
    validar_opcoes_runtime_rw "$MOUNT_OPTIONS" || {
        MOUNT_DIAGNOSTICO="$DOCS4 não possui opções runtime coerentes de leitura e escrita: $MOUNT_OPTIONS"
        return 1
    }
    metadados="$(stat -c '%u:%g:%a' -- "$DOCS4" 2>/dev/null || true)"
    [ "$metadados" = "$UID_USUARIO:$GID_USUARIO:755" ] || {
        MOUNT_DIAGNOSTICO="$DOCS4 não reflete uid=$UID_USUARIO,gid=$GID_USUARIO,umask=022; encontrado ${metadados:-desconhecido}."
        return 1
    }
}

validar_bind_ativo() {
    local fonte="$1" alvo="$2" identidade_fonte identidade_alvo

    MOUNT_DIAGNOSTICO=""
    [ ! -L "$fonte" ] && [ -d "$fonte" ] \
        && [ ! -L "$alvo" ] && [ -d "$alvo" ] || {
        MOUNT_DIAGNOSTICO="Fonte/alvo do bind não são diretórios reais: $fonte -> $alvo"
        return 1
    }
    obter_mount_exato "$alvo" || {
        MOUNT_DIAGNOSTICO="$alvo não é um mountpoint exato."
        return 1
    }
    [ "$MOUNT_UUID" = "$UUID_HD2" ] && [ "$MOUNT_FSTYPE" = "fuseblk" ] || {
        MOUNT_DIAGNOSTICO="$alvo não está no filesystem/UUID esperado de $HD2_PARTICAO."
        return 1
    }
    validar_opcoes_runtime_rw "$MOUNT_OPTIONS" || {
        MOUNT_DIAGNOSTICO="$alvo não possui opções runtime coerentes: $MOUNT_OPTIONS"
        return 1
    }
    identidade_fonte="$(stat -c '%d:%i' -- "$fonte" 2>/dev/null || true)"
    identidade_alvo="$(stat -c '%d:%i' -- "$alvo" 2>/dev/null || true)"
    [ -n "$identidade_fonte" ] && [ "$identidade_fonte" = "$identidade_alvo" ] || {
        MOUNT_DIAGNOSTICO="$alvo não é o bind exato de $fonte."
        return 1
    }
}

validar_sem_mounts_abaixo() {
    local caminho="$1" permitir_exato="$2" saida alvo

    MOUNT_DIAGNOSTICO=""
    saida="$(findmnt -rn --no-encode -o TARGET 2>/dev/null)" || {
        MOUNT_DIAGNOSTICO="Não foi possível listar mounts ao validar $caminho."
        return 1
    }
    while IFS= read -r alvo; do
        [ -n "$alvo" ] || continue
        if [ "$alvo" = "$caminho" ]; then
            if [ "$permitir_exato" -eq 1 ]; then
                continue
            fi
            MOUNT_DIAGNOSTICO="Mount inesperado em $caminho."
            return 1
        fi
        if [[ "$alvo" == "$caminho/"* ]]; then
            MOUNT_DIAGNOSTICO="Mount aninhado impediria uma migração segura: $alvo"
            return 1
        fi
    done <<< "$saida"
}

validar_destino_fora_hd2() {
    local caminho="$1" source uuid

    source="$(findmnt -rn --no-encode --target "$caminho" -o SOURCE 2>/dev/null)" || {
        XDG_DIAGNOSTICO="Não foi possível identificar o filesystem físico de $caminho."
        return 1
    }
    uuid="$(findmnt -rn --no-encode --target "$caminho" -o UUID 2>/dev/null)" || {
        XDG_DIAGNOSTICO="Não foi possível identificar o UUID do filesystem de $caminho."
        return 1
    }
    [[ "$source$uuid" != *$'\n'* ]] || {
        XDG_DIAGNOSTICO="Filesystem ambíguo ao validar destino XDG: $caminho"
        return 1
    }
    if [ "$uuid" = "$UUID_HD2" ] \
        || [ "$source" = "$HD2_PARTICAO" ] \
        || [[ "$source" == "$HD2_PARTICAO["* ]]; then
        XDG_DIAGNOSTICO="Destino XDG está fisicamente dentro do HD2 e foi recusado: $caminho (SOURCE=$source, UUID=${uuid:-desconhecido})."
        return 1
    fi
}

validar_underlay_docs4() {
    local metadados conteudo

    MOUNT_DIAGNOSTICO=""
    [ ! -L "$DOCS4" ] && [ -d "$DOCS4" ] || {
        MOUNT_DIAGNOSTICO="$DOCS4 deve ser um diretório real criado pela etapa 13."
        return 1
    }
    validar_sem_mounts_abaixo "$DOCS4" 0 || return 1
    metadados="$(stat -c '%u:%g:%a' -- "$DOCS4" 2>/dev/null || true)"
    [ "$metadados" = "0:0:755" ] || {
        MOUNT_DIAGNOSTICO="Underlay de $DOCS4 deve ser root:root 0755; encontrado ${metadados:-desconhecido}."
        return 1
    }
    conteudo="$(find "$DOCS4" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" || {
        MOUNT_DIAGNOSTICO="Não foi possível verificar o underlay de $DOCS4."
        return 1
    }
    [ -z "$conteudo" ] || {
        MOUNT_DIAGNOSTICO="Underlay de $DOCS4 não está vazio; primeiro item: $conteudo"
        return 1
    }
}

registrar_intencao_mount() {
    local alvo="$1" tipo="$2" i

    for i in "${!MOUNT_INTENCOES_ALVOS[@]}"; do
        [ "${MOUNT_INTENCOES_ALVOS[$i]}" != "$alvo" ] || {
            erro "Intenção de mount duplicada recusada: $alvo"
            return 1
        }
    done
    MOUNT_INTENCOES_ALVOS+=("$alvo")
    MOUNT_INTENCOES_TIPOS+=("$tipo")
    MOUNT_INTENCOES_IDS+=("")
    MOUNT_INTENCAO_INDICE=$((${#MOUNT_INTENCOES_ALVOS[@]} - 1))
}

registrar_mount_efetivo() {
    local indice="$1" alvo="$2" mount_id
    [[ "$indice" =~ ^[0-9]+$ ]] && [ "$indice" -lt "${#MOUNT_INTENCOES_ALVOS[@]}" ] \
        && [ "${MOUNT_INTENCOES_ALVOS[$indice]}" = "$alvo" ] || return 1
    mount_id="$(findmnt -rn --no-encode -M "$alvo" -o ID 2>/dev/null)" || return 1
    [[ "$mount_id" =~ ^[0-9]+$ ]] || return 1
    MOUNT_INTENCOES_IDS[$indice]="$mount_id"
}

montar_ou_validar_base() {
    local opcoes="windows_names,uid=$UID_USUARIO,gid=$GID_USUARIO,umask=022"

    if obter_mount_exato "$DOCS4"; then
        validar_base_montada \
            || falhar "Montagem preexistente recusada antes da migração: $MOUNT_DIAGNOSTICO"
        validar_sem_mounts_abaixo "$DOCS4" 1 \
            || falhar "$MOUNT_DIAGNOSTICO"
        info "Montagem preexistente validada por source/target/tipo/opções: $DOCS4"
        return 0
    fi

    validar_underlay_docs4 || falhar "$MOUNT_DIAGNOSTICO"
    registrar_intencao_mount "$DOCS4" base \
        || falhar "Não foi possível registrar intenção única de mount para $DOCS4."
    info "Montando temporariamente a partição validada $HD2_PARTICAO em $DOCS4..."
    if ! sudo mount -t ntfs-3g -o "$opcoes" -- "$HD2_PARTICAO" "$DOCS4"; then
        falhar "FALHA FATAL: não foi possível montar o HD2 validado; migração não iniciada."
    fi
    registrar_mount_efetivo "$MOUNT_INTENCAO_INDICE" "$DOCS4" \
        || falhar "Montagem criada, mas seu ID não pôde ser registrado; rollback automático não fará umount ambíguo."
    validar_base_montada \
        || falhar "FALHA FATAL: montagem recém-criada não corresponde ao HD2/opções esperados: $MOUNT_DIAGNOSTICO"
    validar_sem_mounts_abaixo "$DOCS4" 1 || falhar "$MOUNT_DIAGNOSTICO"
}

testar_montagem_antes_migracao() {
    TESTE_VALIDO="$DOCS4/.docs4-write-test-$$-$RANDOM"
    TESTE_INVALIDO="$DOCS4/.docs4-windows-names-test-$$:invalido?.tmp"

    [ ! -e "$TESTE_VALIDO" ] && [ ! -L "$TESTE_VALIDO" ] \
        && [ ! -e "$TESTE_INVALIDO" ] && [ ! -L "$TESTE_INVALIDO" ] \
        || falhar "FALHA FATAL: colisão nos nomes temporários de teste; migração não iniciada."
    como_usuario touch -- "$TESTE_VALIDO" \
        || falhar "FALHA FATAL: $USUARIO_LINUX não consegue escrever em $DOCS4; migração não iniciada."
    como_usuario rm -f -- "$TESTE_VALIDO" \
        || falhar "FALHA FATAL: não foi possível remover o teste de escrita em $DOCS4; migração não iniciada."
    TESTE_VALIDO=""

    if como_usuario touch -- "$TESTE_INVALIDO" 2>/dev/null; then
        como_usuario rm -f -- "$TESTE_INVALIDO" 2>/dev/null || true
        TESTE_INVALIDO=""
        falhar "FALHA FATAL: windows_names não está ativo (nome inválido foi aceito); migração não iniciada."
    fi
    if [ -e "$TESTE_INVALIDO" ] || [ -L "$TESTE_INVALIDO" ]; then
        falhar "FALHA FATAL: teste de windows_names deixou um artefato inesperado; migração não iniciada."
    fi
    TESTE_INVALIDO=""
    ok "Escrita válida e rejeição por windows_names confirmadas antes da migração."
}

preparar_diretorios_hd2() {
    local i caminho metadados

    for i in "${!HD2_DIRS[@]}"; do
        caminho="$DOCS4/${HD2_DIRS[$i]}"
        [ ! -L "$caminho" ] || falhar "Symlink recusado no destino do HD2: $caminho"
        if [ ! -e "$caminho" ]; then
            como_usuario mkdir -- "$caminho" \
                || falhar "Não foi possível criar $caminho como $USUARIO_LINUX."
        fi
        [ -d "$caminho" ] && [ ! -L "$caminho" ] \
            || falhar "Destino do HD2 deve ser diretório real: $caminho"
        metadados="$(stat -c '%u:%g' -- "$caminho" 2>/dev/null || true)"
        [ "$metadados" = "$UID_USUARIO:$GID_USUARIO" ] \
            || falhar "$caminho não reflete o UID/GID esperado ($UID_USUARIO:$GID_USUARIO)."
        validar_sem_mounts_abaixo "$caminho" 0 || falhar "$MOUNT_DIAGNOSTICO"
    done
}

preparar_destinos_xdg() {
    local i destino fonte metadados

    BIND_ATIVO_INICIAL=()
    for i in "${!DESTINOS[@]}"; do
        destino="${DESTINOS[$i]}"
        fonte="$DOCS4/${HD2_DIRS[$i]}"
        validar_componentes_sem_symlink "$destino" \
            || falhar "Symlink/componente inválido recusado no destino XDG: $destino"
        if [ ! -e "$destino" ]; then
            como_usuario mkdir -p -- "$destino" \
                || falhar "Não foi possível criar $destino como $USUARIO_LINUX."
        fi
        [ -d "$destino" ] && [ ! -L "$destino" ] \
            || falhar "Destino XDG deve ser diretório real: $destino"
        metadados="$(stat -c '%u:%g' -- "$destino" 2>/dev/null || true)"
        [ "$metadados" = "$UID_USUARIO:$GID_USUARIO" ] \
            || falhar "$destino deve pertencer a $UID_USUARIO:$GID_USUARIO; encontrado ${metadados:-desconhecido}."

        if obter_mount_exato "$destino"; then
            validar_bind_ativo "$fonte" "$destino" \
                || falhar "Mount preexistente desconhecido recusado em $destino: $MOUNT_DIAGNOSTICO"
            validar_sem_mounts_abaixo "$destino" 1 || falhar "$MOUNT_DIAGNOSTICO"
            BIND_ATIVO_INICIAL[$i]=1
        else
            validar_sem_mounts_abaixo "$destino" 0 || falhar "$MOUNT_DIAGNOSTICO"
            validar_destino_fora_hd2 "$destino" || falhar "$XDG_DIAGNOSTICO"
            BIND_ATIVO_INICIAL[$i]=0
        fi
    done
}

diretorio_vazio() {
    local primeiro
    primeiro="$(find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" || return 1
    [ -z "$primeiro" ]
}

rsync_filtrar_diferencas_conteudo() {
    local saida="$1" linha item

    RSYNC_DIFERENCAS=""
    while IFS= read -r linha; do
        [ -n "$linha" ] || continue
        item="${linha%% *}"
        if [ "${item:0:1}" != "." ]; then
            RSYNC_DIFERENCAS+="${RSYNC_DIFERENCAS:+$'\n'}$linha"
        fi
    done <<< "$saida"
}

rsync_copiar_e_comparar() {
    local origem="$1" alvo="$2" saida status
    local -a opcoes=(-a --checksum --one-file-system --no-owner --no-group
                     --no-perms --omit-dir-times)

    RSYNC_DIAGNOSTICO=""
    RSYNC_STATUS_REAL=0

    if saida="$(como_usuario rsync "${opcoes[@]}" --dry-run --existing \
        --itemize-changes --out-format='%i %n%L' -- "$origem/" "$alvo/")"; then
        :
    else
        status=$?
        RSYNC_STATUS_REAL="$status"
        RSYNC_DIAGNOSTICO="Falha no rsync de pré-validação de $origem (status $status)."
        return "$status"
    fi
    rsync_filtrar_diferencas_conteudo "$saida"
    if [ -n "$RSYNC_DIFERENCAS" ]; then
        RSYNC_DIAGNOSTICO="Conflito com conteúdo preexistente divergente no HD2 detectado por checksum; origem e destino foram preservados:"
        printf '%s\n' "$RSYNC_DIFERENCAS" >&2
        return 1
    fi

    if como_usuario rsync "${opcoes[@]}" --ignore-existing -- \
        "$origem/" "$alvo/"; then
        :
    else
        status=$?
        RSYNC_STATUS_REAL="$status"
        RSYNC_DIAGNOSTICO="Falha ao copiar somente itens ausentes de $origem (status rsync $status)."
        return "$status"
    fi

    if saida="$(como_usuario rsync "${opcoes[@]}" --dry-run \
        --itemize-changes --out-format='%i %n%L' -- "$origem/" "$alvo/")"; then
        :
    else
        status=$?
        RSYNC_STATUS_REAL="$status"
        RSYNC_DIAGNOSTICO="Falha na comparação final por checksum de $origem (status rsync $status)."
        return "$status"
    fi
    rsync_filtrar_diferencas_conteudo "$saida"
    if [ -n "$RSYNC_DIFERENCAS" ]; then
        RSYNC_DIAGNOSTICO="Comparação final por checksum encontrou conteúdo ausente/divergente; nenhum item preexistente no HD2 foi sobrescrito:"
        printf '%s\n' "$RSYNC_DIFERENCAS" >&2
        return 1
    fi
}

gerar_backup_unico() {
    local origem="$1" base candidato contador=0

    base="${origem}.docs4-backup-$(date +%Y%m%d-%H%M%S)-$$"
    candidato="$base"
    while [ -e "$candidato" ] || [ -L "$candidato" ]; do
        contador=$((contador + 1))
        candidato="$base-$contador"
    done
    BACKUP_UNICO="$candidato"
}

registrar_intencao_migracao() {
    local origem="$1" backup="$2" identidade="$3" i

    for i in "${!MIGRACAO_ORIGENS[@]}"; do
        [ "${MIGRACAO_ORIGENS[$i]}" != "$origem" ] \
            && [ "${MIGRACAO_BACKUPS[$i]}" != "$backup" ] || {
            erro "Intenção de rename de migração duplicada recusada: $origem -> $backup"
            return 1
        }
    done
    MIGRACAO_ORIGENS+=("$origem")
    MIGRACAO_BACKUPS+=("$backup")
    MIGRACAO_IDENTIDADES+=("$identidade")
}

registrar_intencao_orfao() {
    local backup="$1" origem="$2" identidade="$3" i

    for i in "${!ORFAO_ORIGENS[@]}"; do
        [ "${ORFAO_ORIGENS[$i]}" != "$origem" ] \
            && [ "${ORFAO_BACKUPS[$i]}" != "$backup" ] || {
            erro "Intenção de reconciliação duplicada recusada: $backup -> $origem"
            return 1
        }
    done
    ORFAO_BACKUPS+=("$backup")
    ORFAO_ORIGENS+=("$origem")
    ORFAO_IDENTIDADES+=("$identidade")
}

listar_backups_migracao() {
    local origem="$1" nullglob_ativo=0

    if shopt -q nullglob; then
        nullglob_ativo=1
    fi
    shopt -s nullglob
    BACKUPS_ENCONTRADOS=("$origem".docs4-backup-*)
    if [ "$nullglob_ativo" -eq 0 ]; then
        shopt -u nullglob
    fi
}

concluir_reconciliacao_orfa_indice() {
    local i="$1" origem backup esperado identidade_origem identidade_backup

    origem="${ORFAO_ORIGENS[$i]}"
    backup="${ORFAO_BACKUPS[$i]}"
    esperado="${ORFAO_IDENTIDADES[$i]}"
    identidade_origem="$(stat -c '%d:%i' -- "$origem" 2>/dev/null || true)"
    identidade_backup="$(stat -c '%d:%i' -- "$backup" 2>/dev/null || true)"

    if [ ! -e "$backup" ] && [ ! -L "$backup" ]; then
        [ "$identidade_origem" = "$esperado" ] || {
            erro "Reconciliação órfã está em estado desconhecido: $backup -> $origem"
            return 1
        }
        return 0
    fi
    [ -d "$backup" ] && [ ! -L "$backup" ] \
        && [ "$identidade_backup" = "$esperado" ] || {
        erro "Backup órfão mudou de identidade e foi preservado: $backup"
        return 1
    }
    if obter_mount_exato "$origem"; then
        erro "Mount ativo impede reconciliar backup órfão: $backup -> $origem"
        return 1
    fi
    if [ -e "$origem" ] || [ -L "$origem" ]; then
        [ -d "$origem" ] && [ ! -L "$origem" ] && diretorio_vazio "$origem" || {
            erro "Origem e backup órfão contêm estado; ambos foram preservados: $origem e $backup"
            return 1
        }
        como_usuario rmdir -- "$origem" || return 1
    fi
    como_usuario mv -T --no-clobber -- "$backup" "$origem" || return 1
    [ ! -e "$backup" ] && [ ! -L "$backup" ] \
        && [ "$(stat -c '%d:%i' -- "$origem" 2>/dev/null || true)" = "$esperado" ] || {
        erro "Rename de reconciliação não terminou no estado esperado: $backup -> $origem"
        return 1
    }
}

reconciliar_backups_orfaos() {
    local i origem backup identidade dispositivo_backup dispositivo_pai

    for i in "${!DESTINOS[@]}"; do
        origem="${DESTINOS[$i]}"
        listar_backups_migracao "$origem"
        [ "${#BACKUPS_ENCONTRADOS[@]}" -gt 0 ] || continue

        if [ "${BIND_ATIVO_INICIAL[$i]}" -eq 1 ]; then
            for backup in "${BACKUPS_ENCONTRADOS[@]}"; do
                [ -d "$backup" ] && [ ! -L "$backup" ] \
                    || falhar "Backup de migração retido tem tipo inseguro: $backup"
                BACKUPS_RETIDOS+=("$backup")
                aviso "Backup original retido detectado na reexecução: $backup"
            done
            continue
        fi

        [ "${#BACKUPS_ENCONTRADOS[@]}" -eq 1 ] || {
            falhar "Múltiplos backups órfãos para $origem; todos foram preservados para reconciliação manual."
        }
        backup="${BACKUPS_ENCONTRADOS[0]}"
        [ -d "$backup" ] && [ ! -L "$backup" ] \
            || falhar "Backup órfão tem tipo inseguro e foi preservado: $backup"
        diretorio_vazio "$origem" || {
            falhar "Backup órfão e origem não vazia detectados; ambos foram preservados: $backup e $origem"
        }
        dispositivo_backup="$(stat -c '%d' -- "$backup" 2>/dev/null || true)"
        dispositivo_pai="$(stat -c '%d' -- "${origem%/*}" 2>/dev/null || true)"
        [ -n "$dispositivo_backup" ] && [ "$dispositivo_backup" = "$dispositivo_pai" ] \
            || falhar "Backup órfão não está no filesystem esperado da origem: $backup"
        identidade="$(stat -c '%d:%i' -- "$backup" 2>/dev/null || true)"
        [ -n "$identidade" ] || falhar "Não foi possível identificar backup órfão: $backup"
        registrar_intencao_orfao "$backup" "$origem" "$identidade" \
            || falhar "Não foi possível registrar reconciliação única de $backup."
        concluir_reconciliacao_orfa_indice "$((${#ORFAO_ORIGENS[@]} - 1))" \
            || falhar "Falha ao reconciliar backup órfão; estados preservados: $backup e $origem"
        aviso "Backup órfão reconciliado como origem antes de repetir a migração: $origem"
    done
}

migrar_diretorios() {
    local i origem alvo backup dispositivo_origem dispositivo_pai modo identidade status

    titulo "Migração recuperável antes de persistir os binds"
    for i in "${!DESTINOS[@]}"; do
        origem="${DESTINOS[$i]}"
        alvo="$DOCS4/${HD2_DIRS[$i]}"
        if [ "${BIND_ATIVO_INICIAL[$i]}" -eq 1 ]; then
            info "$origem já é o bind exato de $alvo; migração não necessária."
            continue
        fi
        validar_sem_mounts_abaixo "$origem" 0 || falhar "$MOUNT_DIAGNOSTICO"
        validar_sem_mounts_abaixo "$alvo" 0 || falhar "$MOUNT_DIAGNOSTICO"
        if diretorio_vazio "$origem"; then
            info "$origem está vazio; nenhum dado original precisa de backup."
            continue
        fi

        dispositivo_origem="$(stat -c '%d' -- "$origem" 2>/dev/null || true)"
        dispositivo_pai="$(stat -c '%d' -- "${origem%/*}" 2>/dev/null || true)"
        [ -n "$dispositivo_origem" ] && [ "$dispositivo_origem" = "$dispositivo_pai" ] \
            || falhar "A origem $origem não está no mesmo filesystem do diretório pai; migração recusada."

        info "Copiando apenas ausentes após comparar preexistentes por checksum: $origem/ -> $alvo/"
        if rsync_copiar_e_comparar "$origem" "$alvo"; then
            :
        else
            status=$?
            erro "${RSYNC_DIAGNOSTICO:-Falha no rsync/comparação de $origem}; originais e destino foram preservados."
            exit "$status"
        fi

        gerar_backup_unico "$origem"
        backup="$BACKUP_UNICO"
        modo="$(stat -c '%a' -- "$origem" 2>/dev/null || true)"
        identidade="$(stat -c '%d:%i' -- "$origem" 2>/dev/null || true)"
        [ -n "$identidade" ] || falhar "Não foi possível identificar $origem antes do rename."
        registrar_intencao_migracao "$origem" "$backup" "$identidade" \
            || falhar "Não foi possível registrar intenção única de rename: $origem -> $backup"
        como_usuario mv -T --no-clobber -- "$origem" "$backup" \
            || falhar "Não foi possível preservar $origem no backup adjacente $backup."
        [ ! -e "$origem" ] && [ ! -L "$origem" ] \
            && [ -d "$backup" ] && [ ! -L "$backup" ] \
            && [ "$(stat -c '%d:%i' -- "$backup" 2>/dev/null || true)" = "$identidade" ] || {
            falhar "Colisão ou mudança de identidade ao reservar $backup; os estados foram preservados."
        }
        [ "$(stat -c '%d' -- "$backup" 2>/dev/null || true)" = "$dispositivo_pai" ] \
            || falhar "Backup $backup não permaneceu no mesmo filesystem da origem."
        como_usuario mkdir -- "$origem" \
            || falhar "Não foi possível recriar o mountpoint vazio $origem."
        [ -z "$modo" ] || como_usuario chmod "$modo" -- "$origem" \
            || falhar "Não foi possível restaurar o modo do mountpoint $origem."
        [ "$(stat -c '%u:%g' -- "$origem" 2>/dev/null || true)" = "$UID_USUARIO:$GID_USUARIO" ] \
            || falhar "Mountpoint recriado com UID/GID incorretos: $origem"

        # Fecha a janela entre a primeira comparação e o rename atômico.
        if rsync_copiar_e_comparar "$backup" "$alvo"; then
            :
        else
            status=$?
            erro "${RSYNC_DIAGNOSTICO:-Falha ao comparar $backup com $alvo}; backup e destino foram preservados."
            exit "$status"
        fi
        ok "Originais preservados no mesmo filesystem: $backup"
    done
}

escapar_fstab_campo() {
    local valor="$1"
    [[ "$valor" != *[[:cntrl:]]* ]] || return 1
    valor="${valor//\\/\\134}"
    valor="${valor// /\\040}"
    printf '%s' "$valor"
}

decodificar_fstab_campo() {
    local valor="$1" saida="" octal caractere i=0 codigo

    while [ "$i" -lt "${#valor}" ]; do
        caractere="${valor:i:1}"
        if [ "$caractere" != "\\" ]; then
            [[ "$caractere" != [[:cntrl:]] ]] || return 1
            saida+="$caractere"
            i=$((i + 1))
            continue
        fi
        octal="${valor:i+1:3}"
        [[ "$octal" =~ ^[0-7]{3}$ ]] || return 1
        codigo=$((8#$octal))
        [ "$codigo" -le 255 ] && [ "$codigo" -ne 0 ] \
            && [ "$codigo" -ne 10 ] && [ "$codigo" -ne 13 ] || return 1
        printf -v caractere '%b' "\\$octal"
        saida+="$caractere"
        i=$((i + 4))
    done
    FSTAB_CAMPO_DECODIFICADO="$saida"
}

parsear_linha_fstab() {
    local linha="$1"
    FSTAB_CAMPOS=()
    [[ "$linha" =~ ^[[:blank:]]*$ ]] && return 1
    [[ "$linha" =~ ^[[:blank:]]*# ]] && return 1
    IFS=$' \t' read -r -a FSTAB_CAMPOS <<< "$linha"
    [ "${#FSTAB_CAMPOS[@]}" -ge 4 ] || return 2
}

preparar_expectativas_fstab() {
    local i

    FSTAB_IDS=(docs4)
    FSTAB_FONTES=("UUID=$UUID_HD2")
    FSTAB_ALVOS=("$DOCS4")
    FSTAB_TIPOS=(ntfs-3g)
    FSTAB_OPCOES=("defaults,windows_names,uid=$UID_USUARIO,gid=$GID_USUARIO,umask=022,nofail")
    for i in "${!HD2_DIRS[@]}"; do
        FSTAB_IDS+=("docs4-bind-${HD2_DIRS[$i]}")
        FSTAB_FONTES+=("$DOCS4/${HD2_DIRS[$i]}")
        FSTAB_ALVOS+=("${DESTINOS[$i]}")
        FSTAB_TIPOS+=(none)
        FSTAB_OPCOES+=("bind,nofail,x-systemd.requires=$DOCS4")
    done
}

indice_fstab_por_id() {
    local id="$1" i
    for i in "${!FSTAB_IDS[@]}"; do
        if [ "${FSTAB_IDS[$i]}" = "$id" ]; then
            FSTAB_INDICE="$i"
            return 0
        fi
    done
    return 1
}

remover_blocos_gerenciados() {
    local entrada="$1" saida="$2" linha proxima id indice status fonte alvo numero=0
    local -A vistos=()

    : > "$saida" || return 1
    while IFS= read -r linha || [ -n "$linha" ]; do
        numero=$((numero + 1))
        if [[ "$linha" == "# vm-passthrough:"* ]]; then
            id="${linha#\# vm-passthrough:}"
            if ! indice_fstab_por_id "$id"; then
                # Marcadores de outras etapas pertencem a elas e são preservados.
                printf '%s\n' "$linha" >> "$saida" || return 1
                continue
            fi
            [ -z "${vistos[$id]+definido}" ] || {
                FSTAB_DIAGNOSTICO="Marcador gerenciado duplicado no fstab: $id"
                return 1
            }
            vistos[$id]=1
            proxima=""
            if IFS= read -r proxima; then
                :
            elif [ -z "$proxima" ]; then
                FSTAB_DIAGNOSTICO="Marcador $id não possui uma entrada subsequente."
                return 1
            fi
            numero=$((numero + 1))
            if parsear_linha_fstab "$proxima"; then
                :
            else
                status=$?
                FSTAB_DIAGNOSTICO="Entrada inválida após o marcador $id (status $status)."
                return 1
            fi
            decodificar_fstab_campo "${FSTAB_CAMPOS[0]}" || {
                FSTAB_DIAGNOSTICO="Source inválido após o marcador $id."
                return 1
            }
            fonte="$FSTAB_CAMPO_DECODIFICADO"
            decodificar_fstab_campo "${FSTAB_CAMPOS[1]}" || {
                FSTAB_DIAGNOSTICO="Target inválido após o marcador $id."
                return 1
            }
            alvo="$FSTAB_CAMPO_DECODIFICADO"
            indice="$FSTAB_INDICE"
            [ "$fonte" = "${FSTAB_FONTES[$indice]}" ] \
                && [ "$alvo" = "${FSTAB_ALVOS[$indice]}" ] || {
                FSTAB_DIAGNOSTICO="Marcador $id precede source/target inesperados; correção manual necessária."
                return 1
            }
            continue
        fi
        printf '%s\n' "$linha" >> "$saida" || return 1
    done < "$entrada"
}

canonicalizar_target_fstab() {
    local alvo="$1" canonico

    [[ "$alvo" == /* ]] && [[ "$alvo" != *[[:cntrl:]]* ]] || return 1
    canonico="$(readlink -m -- "$alvo" 2>/dev/null || true)"
    [ -n "$canonico" ] && [[ "$canonico" != *$'\n'* ]] || return 1
    FSTAB_TARGET_CANONICO="$canonico"
}

detectar_colisoes_targets() {
    local arquivo="$1" linha status alvo alvo_canonico esperado esperado_canonico i numero=0

    while IFS= read -r linha || [ -n "$linha" ]; do
        numero=$((numero + 1))
        if parsear_linha_fstab "$linha"; then
            :
        else
            status=$?
            if [ "$status" -eq 1 ]; then
                continue
            fi
            FSTAB_DIAGNOSTICO="Linha $numero malformada no fstab atual."
            return 1
        fi
        decodificar_fstab_campo "${FSTAB_CAMPOS[1]}" || {
            FSTAB_DIAGNOSTICO="Target inválido na linha $numero do fstab atual."
            return 1
        }
        alvo="$FSTAB_CAMPO_DECODIFICADO"
        if [[ "$alvo" != /* ]]; then
            continue
        fi
        canonicalizar_target_fstab "$alvo" || {
            FSTAB_DIAGNOSTICO="Target não pôde ser canonicalizado na linha $numero do fstab atual: $alvo"
            return 1
        }
        alvo_canonico="$FSTAB_TARGET_CANONICO"
        for i in "${!FSTAB_ALVOS[@]}"; do
            esperado="${FSTAB_ALVOS[$i]}"
            canonicalizar_target_fstab "$esperado" || {
                FSTAB_DIAGNOSTICO="Target esperado não pôde ser canonicalizado: $esperado"
                return 1
            }
            esperado_canonico="$FSTAB_TARGET_CANONICO"
            if [ "$alvo_canonico" = "$esperado_canonico" ]; then
                FSTAB_DIAGNOSTICO="Colisão por target canônico no fstab: $alvo representa $esperado e já possui entrada não gerenciada (linha $numero)."
                return 1
            fi
        done
    done < "$arquivo"
}

adicionar_entradas_esperadas() {
    local arquivo="$1" i fonte alvo

    printf '\n' >> "$arquivo" || return 1
    for i in "${!FSTAB_IDS[@]}"; do
        fonte="$(escapar_fstab_campo "${FSTAB_FONTES[$i]}")" || return 1
        alvo="$(escapar_fstab_campo "${FSTAB_ALVOS[$i]}")" || return 1
        printf '%s\n%s  %s  %s  %s  0  0\n' \
            "# vm-passthrough:${FSTAB_IDS[$i]}" \
            "$fonte" "$alvo" "${FSTAB_TIPOS[$i]}" "${FSTAB_OPCOES[$i]}" \
            >> "$arquivo" || return 1
    done
}

validar_fstab_exato() {
    local arquivo="$1" linha status fonte alvo i numero=0 base_linha=0
    local -a contagens=() marcadores=() linhas=()

    FSTAB_DIAGNOSTICO=""
    for i in "${!FSTAB_IDS[@]}"; do
        contagens[$i]=0
        marcadores[$i]=0
        linhas[$i]=0
    done

    while IFS= read -r linha || [ -n "$linha" ]; do
        numero=$((numero + 1))
        if [[ "$linha" == "# vm-passthrough:"* ]]; then
            if indice_fstab_por_id "${linha#\# vm-passthrough:}"; then
                marcadores[$FSTAB_INDICE]=$(( ${marcadores[$FSTAB_INDICE]} + 1 ))
            fi
            continue
        fi
        if parsear_linha_fstab "$linha"; then
            :
        else
            status=$?
            if [ "$status" -eq 1 ]; then
                continue
            fi
            FSTAB_DIAGNOSTICO="Linha $numero malformada no candidato fstab."
            return 1
        fi
        decodificar_fstab_campo "${FSTAB_CAMPOS[1]}" || {
            FSTAB_DIAGNOSTICO="Target inválido na linha $numero do candidato."
            return 1
        }
        alvo="$FSTAB_CAMPO_DECODIFICADO"
        for i in "${!FSTAB_ALVOS[@]}"; do
            if [ "$alvo" = "${FSTAB_ALVOS[$i]}" ]; then
                decodificar_fstab_campo "${FSTAB_CAMPOS[0]}" || {
                    FSTAB_DIAGNOSTICO="Source inválido na linha $numero do candidato."
                    return 1
                }
                fonte="$FSTAB_CAMPO_DECODIFICADO"
                contagens[$i]=$(( ${contagens[$i]} + 1 ))
                linhas[$i]="$numero"
                [ "$fonte" = "${FSTAB_FONTES[$i]}" ] \
                    && [ "${#FSTAB_CAMPOS[@]}" -eq 6 ] \
                    && [ "${FSTAB_CAMPOS[2]}" = "${FSTAB_TIPOS[$i]}" ] \
                    && [ "${FSTAB_CAMPOS[3]}" = "${FSTAB_OPCOES[$i]}" ] \
                    && [ "${FSTAB_CAMPOS[4]:-}" = "0" ] \
                    && [ "${FSTAB_CAMPOS[5]:-}" = "0" ] || {
                    FSTAB_DIAGNOSTICO="Source/target/tipo/opções/campos finais divergem para $alvo."
                    return 1
                }
            fi
        done
    done < "$arquivo"

    for i in "${!FSTAB_IDS[@]}"; do
        [ "${contagens[$i]}" -eq 1 ] && [ "${marcadores[$i]}" -eq 1 ] || {
            FSTAB_DIAGNOSTICO="${FSTAB_ALVOS[$i]} deve ter exatamente uma entrada e um marcador gerenciado."
            return 1
        }
    done
    base_linha="${linhas[0]}"
    for ((i = 1; i < ${#linhas[@]}; i++)); do
        [ "$base_linha" -lt "${linhas[$i]}" ] || {
            FSTAB_DIAGNOSTICO="A montagem base $DOCS4 deve aparecer antes de todos os binds."
            return 1
        }
    done
}

validar_metadados_fstab() {
    local metadados fstab_uid fstab_gid fstab_modo fstab_links
    [ ! -L "$FSTAB" ] && [ -f "$FSTAB" ] || {
        FSTAB_DIAGNOSTICO="$FSTAB deve ser arquivo regular, não symlink."
        return 1
    }
    metadados="$(stat -c '%u:%g:%a:%h' -- "$FSTAB" 2>/dev/null || true)"
    [ -n "$metadados" ] || {
        FSTAB_DIAGNOSTICO="Não foi possível consultar metadados de $FSTAB."
        return 1
    }
    IFS=: read -r fstab_uid fstab_gid fstab_modo fstab_links <<< "$metadados"
    [ "$fstab_uid" = "0" ] && [ "$fstab_gid" = "0" ] \
        && [ "$fstab_links" = "1" ] \
        && [[ "$fstab_modo" =~ ^[0-7]{3,4}$ ]] \
        && [ $((8#$fstab_modo & 8#22)) -eq 0 ] || {
        FSTAB_DIAGNOSTICO="$FSTAB deve ser root:root, link único e não gravável por grupo/outros."
        return 1
    }
}

preparar_lock_fstab() {
    local metadados estado coproc_pid leitura_fd escrita_fd

    sudo test ! -L "$FSTAB_LOCK_ARQUIVO" \
        || falhar "$FSTAB_LOCK_ARQUIVO não pode ser symlink."
    if ! sudo test -e "$FSTAB_LOCK_ARQUIVO"; then
        sudo bash -c 'umask 077; set -o noclobber; : > "$1"' _ "$FSTAB_LOCK_ARQUIVO" 2>/dev/null \
            || sudo test -f "$FSTAB_LOCK_ARQUIVO" \
            || falhar "Não foi possível criar o lock global do fstab."
    fi
    metadados="$(sudo stat -c '%u:%g:%a:%h' -- "$FSTAB_LOCK_ARQUIVO" 2>/dev/null || true)"
    [ "$metadados" = "0:0:600:1" ] \
        || falhar "Lock inseguro em $FSTAB_LOCK_ARQUIVO (esperado root:root 0600, link único)."

    # Impede que um sinal deixe um coprocess parcialmente publicado sem canal
    # de liberação. O trap normal é restaurado assim que PID e FDs são globais.
    trap '' HUP INT TERM
    coproc FSTAB_FLOCK {
        sudo flock -x -w 30 "$FSTAB_LOCK_ARQUIVO" \
            bash -c 'printf "%s\n" BLOQUEADO; IFS= read -r comando; [ "$comando" = LIBERAR ]'
    }
    coproc_pid="$FSTAB_FLOCK_PID"
    if ! exec {leitura_fd}<&"${FSTAB_FLOCK[0]}" \
        || ! exec {escrita_fd}>&"${FSTAB_FLOCK[1]}"; then
        printf '%s\n' LIBERAR >&"${FSTAB_FLOCK[1]}" 2>/dev/null || true
        [[ "${leitura_fd:-}" =~ ^[0-9]+$ ]] && exec {leitura_fd}<&-
        wait "$coproc_pid" 2>/dev/null || true
        trap 'exit 1' HUP INT TERM
        falhar "Não foi possível inicializar os canais do flock global."
    fi
    FSTAB_LOCK_LEITURA="$leitura_fd"
    FSTAB_LOCK_ESCRITA="$escrita_fd"
    FSTAB_LOCK_PID="$coproc_pid"
    trap 'exit 1' HUP INT TERM

    if ! IFS= read -r estado <&"$FSTAB_LOCK_LEITURA"; then
        liberar_lock_fstab 2>/dev/null || true
        falhar "Tempo esgotado ou falha ao adquirir o flock global de $FSTAB."
    fi
    [ "$estado" = "BLOQUEADO" ] || falhar "Resposta inesperada ao adquirir o lock do fstab."
}

liberar_lock_fstab() {
    local status=0
    if [[ "${FSTAB_LOCK_ESCRITA:-}" =~ ^[0-9]+$ ]]; then
        printf '%s\n' LIBERAR >&"$FSTAB_LOCK_ESCRITA" || status=1
        exec {FSTAB_LOCK_ESCRITA}>&-
        FSTAB_LOCK_ESCRITA=""
    fi
    if [[ "${FSTAB_LOCK_LEITURA:-}" =~ ^[0-9]+$ ]]; then
        exec {FSTAB_LOCK_LEITURA}<&-
        FSTAB_LOCK_LEITURA=""
    fi
    if [[ "${FSTAB_LOCK_PID:-}" =~ ^[0-9]+$ ]]; then
        wait "$FSTAB_LOCK_PID" || status=1
        FSTAB_LOCK_PID=""
    fi
    return "$status"
}

construir_candidato_fstab() {
    local base diagnostico

    validar_metadados_fstab || return 1
    FSTAB_ORIGINAL_TMP="$TMP_DIR/fstab.original"
    base="$TMP_DIR/fstab.base"
    FSTAB_CANDIDATO="$TMP_DIR/fstab.candidato"
    cp -- "$FSTAB" "$FSTAB_ORIGINAL_TMP" || {
        FSTAB_DIAGNOSTICO="Não foi possível copiar o fstab atual sob o lock."
        return 1
    }
    remover_blocos_gerenciados "$FSTAB_ORIGINAL_TMP" "$base" || return 1
    detectar_colisoes_targets "$base" || return 1
    cp -- "$base" "$FSTAB_CANDIDATO" || return 1
    adicionar_entradas_esperadas "$FSTAB_CANDIDATO" || {
        FSTAB_DIAGNOSTICO="Não foi possível montar o candidato único do fstab."
        return 1
    }
    validar_fstab_exato "$FSTAB_CANDIDATO" || return 1
    diagnostico="$(findmnt --verify --verbose --tab-file "$FSTAB_CANDIDATO" 2>&1)" || {
        FSTAB_DIAGNOSTICO="findmnt rejeitou o candidato do fstab: $diagnostico"
        return 1
    }
}

instalar_fstab_atomico() {
    local modo diagnostico

    cmp -s -- "$FSTAB_ORIGINAL_TMP" "$FSTAB" || {
        FSTAB_DIAGNOSTICO="$FSTAB mudou enquanto o candidato era validado; nada foi instalado."
        return 1
    }
    modo="$(stat -c '%a' -- "$FSTAB")" || return 1
    FSTAB_BACKUP="$(sudo mktemp -- "${FSTAB}.bak-docs4-$(date +%Y%m%d-%H%M%S).XXXXXX")" \
        || { FSTAB_DIAGNOSTICO="Não foi possível criar backup exclusivo do fstab."; return 1; }
    sudo cp --preserve=all -- "$FSTAB" "$FSTAB_BACKUP" \
        && sudo cmp -s -- "$FSTAB_ORIGINAL_TMP" "$FSTAB_BACKUP" || {
        FSTAB_DIAGNOSTICO="Falha ao preencher/verificar o backup exclusivo $FSTAB_BACKUP a partir do original validado."
        return 1
    }

    FSTAB_STAGE="$(sudo mktemp -- "${FSTAB%/*}/.fstab.docs4.XXXXXX")" \
        || { FSTAB_DIAGNOSTICO="Não foi possível criar staging no filesystem de $FSTAB."; return 1; }
    sudo install -o root -g root -m "$modo" -- "$FSTAB_CANDIDATO" "$FSTAB_STAGE" \
        || { FSTAB_DIAGNOSTICO="Não foi possível preparar o staging do fstab."; return 1; }
    diagnostico="$(sudo findmnt --verify --verbose --tab-file "$FSTAB_STAGE" 2>&1)" || {
        FSTAB_DIAGNOSTICO="Staging do fstab falhou na validação final: $diagnostico"
        return 1
    }
    sudo cmp -s -- "$FSTAB_CANDIDATO" "$FSTAB_STAGE" || {
        FSTAB_DIAGNOSTICO="Staging do fstab diverge do candidato validado."
        return 1
    }
    cmp -s -- "$FSTAB_ORIGINAL_TMP" "$FSTAB" || {
        FSTAB_DIAGNOSTICO="$FSTAB mudou antes do rename atômico; candidato não instalado."
        return 1
    }
    [ "$FSTAB_RENAME_INTENCAO" -eq 0 ] || {
        FSTAB_DIAGNOSTICO="Intenção duplicada de rename do fstab recusada."
        return 1
    }
    FSTAB_RENAME_INTENCAO=1
    if ! sudo mv -fT -- "$FSTAB_STAGE" "$FSTAB"; then
        if sudo cmp -s -- "$FSTAB_CANDIDATO" "$FSTAB"; then
            FSTAB_INSTALADO=1
            FSTAB_STAGE=""
        fi
        FSTAB_DIAGNOSTICO="Falha na instalação atômica de $FSTAB."
        return 1
    fi
    FSTAB_STAGE=""
    FSTAB_INSTALADO=1
}

preservar_candidato_fstab_conflito() {
    local modo

    [ -n "$FSTAB_CANDIDATO" ] && [ -f "$FSTAB_CANDIDATO" ] || return 1
    modo="$(stat -c '%a' -- "$FSTAB_BACKUP" 2>/dev/null || true)"
    [[ "$modo" =~ ^[0-7]{3,4}$ ]] || modo=0644
    FSTAB_CONFLITO_CANDIDATO="$(sudo mktemp -- \
        "${FSTAB}.candidato-docs4-conflito-$(date +%Y%m%d-%H%M%S).XXXXXX")" || return 1
    if ! sudo install -o root -g root -m "$modo" -- \
        "$FSTAB_CANDIDATO" "$FSTAB_CONFLITO_CANDIDATO" \
        || ! sudo cmp -s -- "$FSTAB_CANDIDATO" "$FSTAB_CONFLITO_CANDIDATO"; then
        sudo rm -f -- "$FSTAB_CONFLITO_CANDIDATO" 2>/dev/null || true
        FSTAB_CONFLITO_CANDIDATO=""
        return 1
    fi
}

restaurar_fstab_original() {
    local stage_restauro

    if [ "$FSTAB_INSTALADO" -ne 1 ]; then
        [ "$FSTAB_RENAME_INTENCAO" -eq 1 ] || return 0
        if [ -n "$FSTAB_CANDIDATO" ] && [ -f "$FSTAB_CANDIDATO" ] \
            && sudo cmp -s -- "$FSTAB_CANDIDATO" "$FSTAB"; then
            FSTAB_INSTALADO=1
        elif [ -n "$FSTAB_ORIGINAL_TMP" ] && [ -f "$FSTAB_ORIGINAL_TMP" ] \
            && sudo cmp -s -- "$FSTAB_ORIGINAL_TMP" "$FSTAB"; then
            return 0
        else
            preservar_candidato_fstab_conflito || true
            erro "Estado do rename do fstab é divergente; atual em $FSTAB, original em ${FSTAB_BACKUP:-indisponível} e candidato em ${FSTAB_CONFLITO_CANDIDATO:-${FSTAB_CANDIDATO:-indisponível}} foram preservados."
            return 1
        fi
    fi
    [ -n "$FSTAB_BACKUP" ] && sudo test -f "$FSTAB_BACKUP" \
        || { erro "Backup do fstab indisponível; restauração automática impossível."; return 1; }
    [ -n "$FSTAB_CANDIDATO" ] && [ -f "$FSTAB_CANDIDATO" ] || {
        erro "Candidato desta execução indisponível; $FSTAB atual e $FSTAB_BACKUP foram preservados."
        return 1
    }
    if ! sudo cmp -s -- "$FSTAB_CANDIDATO" "$FSTAB"; then
        preservar_candidato_fstab_conflito || true
        erro "Rollback CAS recusado: $FSTAB não é mais exatamente o candidato desta execução. Atual preservado em $FSTAB; original em $FSTAB_BACKUP; candidato em ${FSTAB_CONFLITO_CANDIDATO:-$FSTAB_CANDIDATO}."
        return 1
    fi

    stage_restauro="$(sudo mktemp -- "${FSTAB%/*}/.fstab.restore.XXXXXX")" || return 1
    if ! sudo cp --preserve=all -- "$FSTAB_BACKUP" "$stage_restauro" \
        || ! sudo cmp -s -- "$FSTAB_BACKUP" "$stage_restauro"; then
        sudo rm -f -- "$stage_restauro" 2>/dev/null || true
        erro "Falha ao preparar restauração atômica de $FSTAB a partir de $FSTAB_BACKUP."
        return 1
    fi
    if ! sudo cmp -s -- "$FSTAB_CANDIDATO" "$FSTAB"; then
        sudo rm -f -- "$stage_restauro" 2>/dev/null || true
        preservar_candidato_fstab_conflito || true
        erro "Rollback CAS recusado antes do swap: $FSTAB mudou; atual, original ($FSTAB_BACKUP) e candidato (${FSTAB_CONFLITO_CANDIDATO:-$FSTAB_CANDIDATO}) foram preservados."
        return 1
    fi
    if [ "$FSTAB_RESTORE_INTENCAO" -eq 0 ]; then
        FSTAB_RESTORE_INTENCAO=1
    fi
    if ! sudo mv -fT -- "$stage_restauro" "$FSTAB"; then
        sudo rm -f -- "$stage_restauro" 2>/dev/null || true
        if sudo cmp -s -- "$FSTAB_BACKUP" "$FSTAB"; then
            FSTAB_INSTALADO=0
            return 0
        fi
        erro "Falha ao restaurar atomicamente $FSTAB a partir de $FSTAB_BACKUP."
        return 1
    fi
    FSTAB_INSTALADO=0
    aviso "$FSTAB original restaurado por compare-and-swap após falha."
}

desmontar_mounts_criados() {
    local i caminho tipo indice retorno=0 esperado_id atual_id

    for ((i = ${#MOUNT_INTENCOES_ALVOS[@]} - 1; i >= 0; i--)); do
        caminho="${MOUNT_INTENCOES_ALVOS[$i]}"
        tipo="${MOUNT_INTENCOES_TIPOS[$i]}"
        esperado_id="${MOUNT_INTENCOES_IDS[$i]:-}"
        [ -n "$esperado_id" ] || continue
        atual_id="$(findmnt -rn --no-encode -M "$caminho" -o ID 2>/dev/null || true)"
        if [ "$atual_id" != "$esperado_id" ]; then
            [ -z "$atual_id" ] \
                || aviso "Não desmontado por segurança: mount ID de $caminho mudou ($esperado_id -> $atual_id)."
            continue
        fi
        obter_mount_exato "$caminho" || continue
        if [ "$tipo" = "base" ]; then
            if ! validar_base_montada; then
                aviso "Não desmontado por segurança: mount em $caminho mudou de identidade."
                retorno=1
                continue
            fi
        else
            indice="${tipo#bind:}"
            if ! validar_bind_ativo "$DOCS4/${HD2_DIRS[$indice]}" "$caminho"; then
                aviso "Não desmontado por segurança: bind em $caminho mudou de identidade."
                retorno=1
                continue
            fi
        fi
        if ! sudo umount -- "$caminho"; then
            aviso "Falha ao desmontar mount intentado nesta execução: $caminho"
            retorno=1
        elif obter_mount_exato "$caminho"; then
            aviso "Mount ainda está ativo após umount: $caminho"
            retorno=1
        fi
    done
    return "$retorno"
}

restaurar_migracoes() {
    local i origem backup esperado identidade_origem identidade_backup retorno=0

    for ((i = ${#MIGRACAO_ORIGENS[@]} - 1; i >= 0; i--)); do
        origem="${MIGRACAO_ORIGENS[$i]}"
        backup="${MIGRACAO_BACKUPS[$i]}"
        esperado="${MIGRACAO_IDENTIDADES[$i]}"
        if obter_mount_exato "$origem"; then
            aviso "Não foi possível restaurar $backup: $origem continua montado."
            retorno=1
            continue
        fi
        identidade_origem="$(stat -c '%d:%i' -- "$origem" 2>/dev/null || true)"
        identidade_backup="$(stat -c '%d:%i' -- "$backup" 2>/dev/null || true)"
        if [ ! -e "$backup" ] && [ ! -L "$backup" ]; then
            if [ "$identidade_origem" = "$esperado" ]; then
                continue
            fi
            aviso "Rename $origem -> $backup não está em estado restaurado nem recuperável."
            retorno=1
            continue
        fi
        [ -d "$backup" ] && [ ! -L "$backup" ] \
            && [ "$identidade_backup" = "$esperado" ] || {
            aviso "Backup mudou de identidade; nenhum estado foi alterado: $backup"
            retorno=1
            continue
        }
        if [ -e "$origem" ] || [ -L "$origem" ]; then
            if [ -d "$origem" ] && [ ! -L "$origem" ] && diretorio_vazio "$origem"; then
                como_usuario rmdir -- "$origem" || {
                    aviso "Não foi possível liberar $origem para restaurar $backup."
                    retorno=1
                    continue
                }
            else
                aviso "Dados novos em $origem impediram restaurar $backup; ambos foram preservados."
                retorno=1
                continue
            fi
        fi
        if como_usuario mv -T --no-clobber -- "$backup" "$origem" \
            && [ ! -e "$backup" ] && [ ! -L "$backup" ] \
            && [ "$(stat -c '%d:%i' -- "$origem" 2>/dev/null || true)" = "$esperado" ]; then
            aviso "Originais restaurados em $origem após falha."
        else
            aviso "Restaure manualmente $backup para $origem; nenhuma colisão foi sobrescrita."
            retorno=1
        fi
    done
    return "$retorno"
}

concluir_reconciliacoes_orfas() {
    local i retorno=0

    for ((i = ${#ORFAO_ORIGENS[@]} - 1; i >= 0; i--)); do
        concluir_reconciliacao_orfa_indice "$i" || retorno=1
    done
    return "$retorno"
}

encerrar_transacao() {
    local status=$? rollback_status=0
    trap - EXIT HUP INT TERM
    set +e
    set +u

    if [ "$status" -ne 0 ] && [ "$TRANSACAO_CONCLUIDA" -eq 0 ] \
        && [ "$ROLLBACK_EM_CURSO" -eq 0 ]; then
        ROLLBACK_EM_CURSO=1
        erro "A etapa falhou; iniciando rollback conservador sob o lock global."
        desmontar_mounts_criados || rollback_status=1
        restaurar_fstab_original || rollback_status=1
        restaurar_migracoes || rollback_status=1
        concluir_reconciliacoes_orfas || rollback_status=1
        if [ "$rollback_status" -ne 0 ]; then
            ROLLBACK_FALHOU=1
            erro "Rollback incompleto: estados divergentes foram preservados e exigem revisão manual."
        fi
    fi
    if [ -n "$TESTE_VALIDO" ] && { [ -e "$TESTE_VALIDO" ] || [ -L "$TESTE_VALIDO" ]; }; then
        como_usuario rm -f -- "$TESTE_VALIDO" 2>/dev/null || true
    fi
    if [ -n "$TESTE_INVALIDO" ] && { [ -e "$TESTE_INVALIDO" ] || [ -L "$TESTE_INVALIDO" ]; }; then
        como_usuario rm -f -- "$TESTE_INVALIDO" 2>/dev/null || true
    fi
    if [ -n "$FSTAB_STAGE" ]; then
        sudo rm -f -- "$FSTAB_STAGE" 2>/dev/null || true
    fi
    liberar_lock_fstab 2>/dev/null || true
    if [ -n "$TMP_DIR" ] && [[ "$TMP_DIR" == /tmp/docs4-transacao.* ]]; then
        rm -rf -- "$TMP_DIR"
    fi
    exit "$status"
}

ativar_e_validar_binds() {
    local i destino fonte

    for i in "${!DESTINOS[@]}"; do
        destino="${DESTINOS[$i]}"
        fonte="$DOCS4/${HD2_DIRS[$i]}"
        if [ "${BIND_ATIVO_INICIAL[$i]}" -eq 1 ]; then
            validar_bind_ativo "$fonte" "$destino" \
                || falhar "Bind preexistente mudou durante a transação: $MOUNT_DIAGNOSTICO"
            continue
        fi
        diretorio_vazio "$destino" \
            || falhar "Novos dados apareceram em $destino após a migração; bind recusado e dados preservados para revisão."
        registrar_intencao_mount "$destino" "bind:$i" \
            || falhar "Não foi possível registrar intenção única de mount para $destino."
        if ! sudo mount -- "$destino"; then
            falhar "Falha ao ativar o bind final $fonte -> $destino."
        fi
        registrar_mount_efetivo "$MOUNT_INTENCAO_INDICE" "$destino" \
            || falhar "Bind criado, mas seu ID não pôde ser registrado; rollback automático não fará umount ambíguo."
        validar_bind_ativo "$fonte" "$destino" \
            || falhar "Bind final não corresponde a source/target/opções esperados: $MOUNT_DIAGNOSTICO"
        validar_sem_mounts_abaixo "$destino" 1 || falhar "$MOUNT_DIAGNOSTICO"
    done
}

verificar() {
    local comando i fonte destino

    if ! validar_docs4_normativo; then
        v_falta "$MOUNT_DIAGNOSTICO"
        v_fim
    fi
    for comando in findmnt lsblk blkid readlink stat getent id xdg-user-dir; do
        command -v "$comando" >/dev/null 2>&1 \
            || v_falta "Comando necessário ausente: $comando"
    done
    [ "$V_FALHAS" -eq 0 ] || v_fim
    for comando in UUID_HD2 HD2_DISCO_PAI NVME_DEVICE HD1_BY_ID_PATH USUARIO_LINUX; do
        [ -n "${!comando:-}" ] || v_falta "$comando não definido."
    done
    [ "$V_FALHAS" -eq 0 ] || v_fim

    SUDO_USUARIO_NAO_INTERATIVO=1
    if carregar_usuario; then
        v_ok "XDG será resolvido como $USUARIO_LINUX ($UID_USUARIO:$GID_USUARIO)."
    else
        v_falta "$USUARIO_DIAGNOSTICO"
        v_fim
    fi
    if resolver_identidades 0; then
        v_ok "UUID_HD2, HD2_DISCO_PAI, NVME_DEVICE e HD1_BY_ID_PATH têm identidades canônicas distintas."
    else
        v_falta "$IDENTIDADE_DIAGNOSTICO"
        v_fim
    fi
    if resolver_todos_destinos; then
        v_ok "Cinco destinos XDG canônicos resolvidos como $USUARIO_LINUX."
    else
        v_falta "$XDG_DIAGNOSTICO"
        v_fim
    fi
    preparar_expectativas_fstab

    if validar_base_montada; then
        v_ok "$DOCS4 possui source/target/tipo/opções runtime coerentes com $HD2_PARTICAO."
    else
        v_falta "$MOUNT_DIAGNOSTICO"
    fi
    if validar_fstab_exato "$FSTAB"; then
        v_ok "fstab possui source/target/tipo/opções exatos e únicos, com base antes dos binds."
    else
        v_falta "$FSTAB_DIAGNOSTICO"
    fi
    for i in "${!HD2_DIRS[@]}"; do
        fonte="$DOCS4/${HD2_DIRS[$i]}"
        destino="${DESTINOS[$i]}"
        if [ -d "$fonte" ] && [ ! -L "$fonte" ] \
            && validar_bind_ativo "$fonte" "$destino"; then
            v_ok "bind exato: $fonte -> $destino (source/target/opções conferidos)."
        else
            v_falta "Bind ausente, desconhecido ou divergente: $fonte -> $destino${MOUNT_DIAGNOSTICO:+ ($MOUNT_DIAGNOSTICO)}"
        fi
    done
    v_fim
}
if [ "${1:-}" = "--verificar" ]; then
    [ "$#" -eq 1 ] || falhar "--verificar não aceita outras opções."
    verificar
fi
[ "$#" -eq 0 ] || falhar "Opção desconhecida: $1"

exigir_nao_root
exigir_sudo
exigir_comando rsync xdg-user-dir findmnt lsblk blkid readlink stat flock \
    mount umount mktemp install cmp mv find getent id touch rm mkdir rmdir cp
exigir_conf UUID_HD2 HD2_DISCO_PAI NVME_DEVICE HD1_BY_ID_PATH USUARIO_LINUX
validar_docs4_normativo || falhar "$MOUNT_DIAGNOSTICO"
dpkg -s ntfs-3g >/dev/null 2>&1 \
    || falhar "ntfs-3g não instalado. Execute a etapa 12 antes."

carregar_usuario || falhar "$USUARIO_DIAGNOSTICO"
resolver_identidades 1 || falhar "$IDENTIDADE_DIAGNOSTICO"
resolver_todos_destinos || falhar "$XDG_DIAGNOSTICO"
preparar_expectativas_fstab

titulo "Capítulo 11: Docs4 recuperável em $DOCS4"
info "HD2: $HD2_PARTICAO (UUID=$UUID_HD2; disco=$HD2_DISCO_CANONICO)"
info "Sistema: $DISCO_SISTEMA_CANONICO; HD1: $HD1_DISCO_CANONICO"
info "Usuário: $USUARIO_LINUX (uid=$UID_USUARIO gid=$GID_USUARIO)"

TMP_DIR="$(mktemp -d -- /tmp/docs4-transacao.XXXXXX)" \
    || falhar "Não foi possível criar diretório temporário seguro."
chmod 0700 -- "$TMP_DIR"
trap encerrar_transacao EXIT
trap 'exit 1' HUP INT TERM

# O lock global cobre toda mutação compartilhada: mounts, cópias, renames,
# publicação do fstab e eventual rollback.
preparar_lock_fstab
montar_ou_validar_base
testar_montagem_antes_migracao
preparar_diretorios_hd2
preparar_destinos_xdg
reconciliar_backups_orfaos
migrar_diretorios

construir_candidato_fstab || falhar "$FSTAB_DIAGNOSTICO"
instalar_fstab_atomico || falhar "$FSTAB_DIAGNOSTICO"
ativar_e_validar_binds
validar_base_montada || falhar "Montagem base divergiu após ativar binds: $MOUNT_DIAGNOSTICO"
validar_fstab_exato "$FSTAB" || falhar "$FSTAB_DIAGNOSTICO"

TRANSACAO_CONCLUIDA=1
liberar_lock_fstab || aviso "O lock global da transação foi liberado com status inesperado."

echo
ok "Docs4 concluído com montagem e cinco binds exatos."
info "Backup exclusivo do fstab: $FSTAB_BACKUP"
BACKUPS_A_EXIBIR=("${MIGRACAO_BACKUPS[@]}" "${BACKUPS_RETIDOS[@]}")
if [ "${#BACKUPS_A_EXIBIR[@]}" -gt 0 ]; then
    aviso "Os dados originais NÃO foram apagados. Backups no mesmo filesystem:"
    printf '  - %s\n' "${BACKUPS_A_EXIBIR[@]}"
    aviso "Valide seus dados e remova esses diretórios manualmente somente quando estiver seguro."
else
    info "Nenhum diretório original não vazio precisou ser movido para backup nesta execução."
fi
