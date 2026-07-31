#!/bin/bash
# ============================================================================
# etapas/70-trim-discard.sh - Capítulo 25: TRIM/discard
# ============================================================================
# Habilita discard='unmap' somente no QCOW2 configurado para o C:. Isso permite
# propagar descartes, mas não garante redução física imediata do arquivo QCOW2.
# Também cria backups-vm apenas sobre o mount exato esperado do Docs4/HD2.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

DOCS4="/mnt/docs4"
TMP_DIR=""
XML_ORIGINAL=""
XML_CANDIDATO=""
XML_POST=""
XML_ROLLBACK=""
DISCO_INDICE=""
DISCO_DISCARD_PRESENTE=0
DISCO_DISCARD=""
XML_DIAGNOSTICO=""
MOUNT_DIAGNOSTICO=""
DEFINE_TENTADO=0
TRANSACAO_CONCLUIDA=0
ROLLBACK_FALHOU=0

encerrar() {
    local status="$?"
    trap - EXIT
    if [ "$status" -ne 0 ] && [ "$DEFINE_TENTADO" -eq 1 ] \
        && [ "$TRANSACAO_CONCLUIDA" -eq 0 ] && [ -s "$XML_ORIGINAL" ]; then
        erro "Falha após a tentativa de define; restaurando o XML original capturado."
        if LC_ALL=C $VIRSH define "$XML_ORIGINAL" >/dev/null 2>&1; then
            if LC_ALL=C $VIRSH dumpxml --inactive "$VM_NAME" > "$XML_ROLLBACK" 2>/dev/null \
                && cmp -s -- "$XML_ORIGINAL" "$XML_ROLLBACK"; then
                aviso "XML original restaurado e confirmado após a falha."
            else
                ROLLBACK_FALHOU=1
                erro "O define de restauração retornou sucesso, mas o XML original não pôde ser confirmado byte a byte."
            fi
        else
            ROLLBACK_FALHOU=1
            erro "FALHA CRÍTICA: não foi possível restaurar automaticamente o XML original."
        fi
    fi
    if [ "$ROLLBACK_FALHOU" -eq 1 ]; then
        erro "Arquivos da transação preservados para recuperação manual: $TMP_DIR"
    elif [ -n "$TMP_DIR" ] && [[ "$TMP_DIR" == /tmp/trim-discard.* ]]; then
        rm -rf -- "$TMP_DIR"
    fi
    exit "$status"
}
trap encerrar EXIT
trap 'exit 1' HUP INT TERM

xml_valor() {
    local arquivo="$1" xpath="$2"
    xmlstarlet sel -t -v "$xpath" "$arquivo"
}

xml_contagem() {
    local arquivo="$1" xpath="$2"
    xml_valor "$arquivo" "count($xpath)"
}

validar_qcow2_path() {
    local normalizado
    XML_DIAGNOSTICO=""
    [[ "${QCOW2_PATH:-}" == /* ]] && [[ "$QCOW2_PATH" != *[[:cntrl:]]* ]] || {
        XML_DIAGNOSTICO="QCOW2_PATH deve ser absoluto e não conter caracteres de controle."
        return 1
    }
    normalizado="$(readlink -m -- "$QCOW2_PATH" 2>/dev/null)" || {
        XML_DIAGNOSTICO="Não foi possível normalizar QCOW2_PATH."
        return 1
    }
    [ "$normalizado" = "$QCOW2_PATH" ] || {
        XML_DIAGNOSTICO="QCOW2_PATH deve estar normalizado, sem '.', '..' ou barras redundantes: $QCOW2_PATH"
        return 1
    }
}

localizar_disco_qcow2() {
    local arquivo="$1" total i tipo dispositivo drivers fontes origem encontrados=0 indice=""

    XML_DIAGNOSTICO=""
    DISCO_INDICE=""
    xmlstarlet val -q "$arquivo" >/dev/null 2>&1 || {
        XML_DIAGNOSTICO="XML inativo inválido."
        return 1
    }
    total="$(xml_contagem "$arquivo" "/domain/devices/disk")" || {
        XML_DIAGNOSTICO="Não foi possível contar os discos no XML."
        return 1
    }
    [[ "$total" =~ ^(0|[1-9][0-9]*)$ ]] || {
        XML_DIAGNOSTICO="Contagem inválida de discos no XML: '$total'."
        return 1
    }

    for ((i = 1; i <= total; i++)); do
        tipo="$(xml_valor "$arquivo" "/domain/devices/disk[$i]/@type")" || {
            XML_DIAGNOSTICO="Falha ao consultar o tipo do disco $i."
            return 1
        }
        dispositivo="$(xml_valor "$arquivo" "/domain/devices/disk[$i]/@device")" || {
            XML_DIAGNOSTICO="Falha ao consultar device do disco $i."
            return 1
        }
        [ "$tipo" = "file" ] && [ "$dispositivo" = "disk" ] || continue
        drivers="$(xml_contagem "$arquivo" "/domain/devices/disk[$i]/driver[@type='qcow2']")" || {
            XML_DIAGNOSTICO="Falha ao validar o driver do disco $i."
            return 1
        }
        [ "$drivers" = "1" ] || continue
        [ "$(xml_contagem "$arquivo" "/domain/devices/disk[$i]/driver")" = "1" ] || {
            XML_DIAGNOSTICO="O disco $i possui múltiplos elementos driver."
            return 1
        }
        fontes="$(xml_contagem "$arquivo" "/domain/devices/disk[$i]/source[@file]")" || {
            XML_DIAGNOSTICO="Falha ao validar a source do disco $i."
            return 1
        }
        [ "$fontes" = "1" ] || continue
        origem="$(xml_valor "$arquivo" "/domain/devices/disk[$i]/source/@file")" || {
            XML_DIAGNOSTICO="Falha ao ler a source do disco $i."
            return 1
        }
        if [ "$origem" = "$QCOW2_PATH" ]; then
            encontrados=$((encontrados + 1))
            indice="$i"
        fi
    done

    [ "$encontrados" -eq 1 ] || {
        XML_DIAGNOSTICO="O XML deve conter exatamente um file/device=disk/driver=qcow2 com source '$QCOW2_PATH'; encontrados: $encontrados."
        return 1
    }
    DISCO_INDICE="$indice"
}

obter_discard_selecionado() {
    local arquivo="$1" indice="$2" quantidade

    DISCO_DISCARD_PRESENTE=0
    DISCO_DISCARD=""
    [[ "$indice" =~ ^[1-9][0-9]*$ ]] || {
        XML_DIAGNOSTICO="Índice interno inválido ao consultar discard."
        return 1
    }
    quantidade="$(xml_contagem "$arquivo" "/domain/devices/disk[$indice]/driver/@discard")" || {
        XML_DIAGNOSTICO="Falha ao contar o atributo discard do disco selecionado."
        return 1
    }
    [ "$quantidade" = "0" ] || [ "$quantidade" = "1" ] || {
        XML_DIAGNOSTICO="O driver do disco selecionado possui múltiplos atributos discard."
        return 1
    }
    if [ "$quantidade" = "1" ]; then
        DISCO_DISCARD="$(xml_valor "$arquivo" "/domain/devices/disk[$indice]/driver/@discard")" || {
            XML_DIAGNOSTICO="Falha ao ler discard do disco selecionado."
            return 1
        }
        DISCO_DISCARD_PRESENTE=1
    fi
}

validar_discard_no_xml() {
    local arquivo="$1"
    validar_qcow2_path || return 1
    localizar_disco_qcow2 "$arquivo" || return 1
    obter_discard_selecionado "$arquivo" "$DISCO_INDICE" || return 1
    [ "$DISCO_DISCARD_PRESENTE" -eq 1 ] && [ "$DISCO_DISCARD" = "unmap" ] || {
        XML_DIAGNOSTICO="discard='unmap' está ausente no driver do QCOW2_PATH selecionado."
        return 1
    }
}

estado_vm() {
    LC_ALL=C $VIRSH domstate "$VM_NAME" 2>/dev/null
}

exigir_vm_shut_off_exata() {
    local estado
    LC_ALL=C $VIRSH dominfo "$VM_NAME" >/dev/null 2>&1 \
        || falhar "A VM '$VM_NAME' não existe ou não pôde ser consultada."
    estado="$(estado_vm)" \
        || falhar "Não foi possível consultar o estado de '$VM_NAME'."
    [ "$estado" = "shut off" ] \
        || falhar "A VM '$VM_NAME' deve estar exatamente 'shut off'; encontrado: ${estado:-<vazio>}."
}

obter_mount_docs4() {
    MOUNT_SOURCE="$(findmnt -rn --no-encode -M "$DOCS4" -o SOURCE 2>/dev/null)" || return 1
    MOUNT_TARGET="$(findmnt -rn --no-encode -M "$DOCS4" -o TARGET 2>/dev/null)" || return 1
    MOUNT_UUID="$(findmnt -rn --no-encode -M "$DOCS4" -o UUID 2>/dev/null)" || return 1
    MOUNT_FSTYPE="$(findmnt -rn --no-encode -M "$DOCS4" -o FSTYPE 2>/dev/null)" || return 1
    MOUNT_FSROOT="$(findmnt -rn --no-encode -M "$DOCS4" -o FSROOT 2>/dev/null)" || return 1
    MOUNT_OPTIONS="$(findmnt -rn --no-encode -M "$DOCS4" -o OPTIONS 2>/dev/null)" || return 1
    MOUNT_ID="$(findmnt -rn --no-encode -M "$DOCS4" -o ID 2>/dev/null)" || return 1
    [ -n "$MOUNT_SOURCE" ] && [ "$MOUNT_TARGET" = "$DOCS4" ] \
        && [[ "$MOUNT_SOURCE$MOUNT_TARGET$MOUNT_UUID$MOUNT_FSTYPE$MOUNT_FSROOT$MOUNT_OPTIONS$MOUNT_ID" != *$'\n'* ]]
}

validar_mount_docs4() {
    local opcoes
    MOUNT_DIAGNOSTICO=""
    [ "${DOCS4_MONTAGEM:-}" = "$DOCS4" ] || {
        MOUNT_DIAGNOSTICO="DOCS4_MONTAGEM deve ser exatamente $DOCS4."
        return 1
    }
    [[ "${UUID_HD2:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
        MOUNT_DIAGNOSTICO="UUID_HD2 ausente ou inválido."
        return 1
    }
    obter_mount_docs4 || {
        MOUNT_DIAGNOSTICO="$DOCS4 não é um mountpoint exato consultável."
        return 1
    }
    [[ "$MOUNT_SOURCE" != *"["* ]] && [[ "$MOUNT_SOURCE" != *"]"* ]] \
        && [ "$MOUNT_FSROOT" = "/" ] || {
        MOUNT_DIAGNOSTICO="$DOCS4 não monta a raiz exata da partição esperada."
        return 1
    }
    [ "$MOUNT_UUID" = "$UUID_HD2" ] || {
        MOUNT_DIAGNOSTICO="$DOCS4 usa UUID=${MOUNT_UUID:-desconhecido}; esperado UUID=$UUID_HD2."
        return 1
    }
    [ "$MOUNT_FSTYPE" = "fuseblk" ] || [ "$MOUNT_FSTYPE" = "ntfs3" ] || {
        MOUNT_DIAGNOSTICO="$DOCS4 não está montado como NTFS."
        return 1
    }
    opcoes=",$MOUNT_OPTIONS,"
    [[ "$opcoes" == *",rw,"* ]] && [[ "$opcoes" != *",ro,"* ]] || {
        MOUNT_DIAGNOSTICO="$DOCS4 não está montado em leitura e escrita."
        return 1
    }
    [[ "$MOUNT_ID" =~ ^[1-9][0-9]*$ ]] || {
        MOUNT_DIAGNOSTICO="ID de mount inválido para $DOCS4."
        return 1
    }
    [ -d "$DOCS4" ] && [ ! -L "$DOCS4" ] || {
        MOUNT_DIAGNOSTICO="$DOCS4 deve ser diretório real, não-symlink."
        return 1
    }
}

verificar() {
    local xml_verificacao mount_id_inicial=""

    [ -n "${VM_NAME:-}" ] || v_falta "VM_NAME não definido."
    [ -n "${QCOW2_PATH:-}" ] || v_falta "QCOW2_PATH não definido."
    [ -n "${UUID_HD2:-}" ] || v_falta "UUID_HD2 não definido."
    [ -n "${DOCS4_MONTAGEM:-}" ] || v_falta "DOCS4_MONTAGEM não definido."
    command -v xmlstarlet >/dev/null 2>&1 || v_falta "Comando necessário ausente: xmlstarlet"
    command -v readlink >/dev/null 2>&1 || v_falta "Comando necessário ausente: readlink"
    command -v findmnt >/dev/null 2>&1 || v_falta "Comando necessário ausente: findmnt"
    [ "$V_FALHAS" -eq 0 ] || v_fim

    if ! LC_ALL=C $VIRSH dominfo "$VM_NAME" >/dev/null 2>&1; then
        v_falta "A VM '$VM_NAME' não existe ou não pôde ser consultada."
    elif ! validar_qcow2_path; then
        v_falta "$XML_DIAGNOSTICO"
    else
        TMP_DIR="$(mktemp -d -- /tmp/trim-discard.XXXXXX)" || {
            v_falta "Não foi possível criar diretório temporário."
            v_fim
        }
        chmod 0700 -- "$TMP_DIR"
        xml_verificacao="$TMP_DIR/verificar.xml"
        if ! LC_ALL=C $VIRSH dumpxml --inactive "$VM_NAME" > "$xml_verificacao"; then
            v_falta "Não foi possível consultar o XML inativo da VM."
        elif validar_discard_no_xml "$xml_verificacao"; then
            v_ok "discard='unmap' ativo no nó exato selecionado de QCOW2_PATH."
        else
            v_falta "$XML_DIAGNOSTICO"
        fi
    fi

    if validar_mount_docs4; then
        mount_id_inicial="$MOUNT_ID"
        if [ -d "$DOCS4/backups-vm" ] && [ ! -L "$DOCS4/backups-vm" ] \
            && validar_mount_docs4 && [ "$MOUNT_ID" = "$mount_id_inicial" ]; then
            v_ok "Pasta de backups existe no mount exato do Docs4/HD2."
        else
            v_falta "Pasta backups-vm ausente/insegura ou mount do Docs4 mudou."
        fi
    else
        v_falta "$MOUNT_DIAGNOSTICO"
    fi
    v_fim
}
if [ "${1:-}" = "--verificar" ]; then
    [ "$#" -eq 1 ] || falhar "Uso: $0 [--verificar]"
    verificar
fi
[ "$#" -eq 0 ] || falhar "Opção desconhecida. Uso: $0 [--verificar]"

exigir_nao_root
exigir_comando xmlstarlet readlink findmnt cmp lsblk sed
exigir_conf VM_NAME QCOW2_PATH UUID_HD2 DOCS4_MONTAGEM
validar_qcow2_path || falhar "$XML_DIAGNOSTICO"
exigir_vm_shut_off_exata
exigir_sudo

titulo "Capítulo 25: TRIM/discard"
info "Suporte anunciado a discard no host (não é garantia de redução física do QCOW2):"
if ! lsblk --discard | sed 's/^/  /'; then
    aviso "Não foi possível exibir as capacidades de discard do host."
fi

TMP_DIR="$(mktemp -d -- /tmp/trim-discard.XXXXXX)" \
    || falhar "Não foi possível criar diretório temporário seguro."
chmod 0700 -- "$TMP_DIR"
XML_ORIGINAL="$TMP_DIR/original.xml"
XML_CANDIDATO="$TMP_DIR/candidato.xml"
XML_POST="$TMP_DIR/post.xml"
XML_ROLLBACK="$TMP_DIR/rollback.xml"

LC_ALL=C $VIRSH dumpxml --inactive "$VM_NAME" > "$XML_ORIGINAL" \
    || falhar "Falha ao capturar o XML inativo original de '$VM_NAME'."
xmlstarlet val -q "$XML_ORIGINAL" \
    || falhar "O XML inativo original é inválido."
localizar_disco_qcow2 "$XML_ORIGINAL" || falhar "$XML_DIAGNOSTICO"
INDICE_ORIGINAL="$DISCO_INDICE"
obter_discard_selecionado "$XML_ORIGINAL" "$INDICE_ORIGINAL" \
    || falhar "$XML_DIAGNOSTICO"

if [ "$DISCO_DISCARD_PRESENTE" -eq 1 ] && [ "$DISCO_DISCARD" = "unmap" ]; then
    info "discard='unmap' já está configurado no nó exato de QCOW2_PATH; nenhum define necessário."
else
    cp -- "$XML_ORIGINAL" "$XML_CANDIDATO" \
        || falhar "Não foi possível criar o XML candidato."
    XPATH_DRIVER="/domain/devices/disk[$INDICE_ORIGINAL]/driver"
    xmlstarlet ed -L \
        -d "$XPATH_DRIVER/@discard" \
        -i "$XPATH_DRIVER" -t attr -n discard -v unmap \
        "$XML_CANDIDATO" \
        || falhar "Falha ao editar o XML candidato."
    xmlstarlet val -q "$XML_CANDIDATO" \
        || falhar "O XML candidato é inválido."
    localizar_disco_qcow2 "$XML_CANDIDATO" || falhar "$XML_DIAGNOSTICO"
    [ "$DISCO_INDICE" = "$INDICE_ORIGINAL" ] \
        || falhar "O nó de QCOW2_PATH mudou de posição no XML candidato."
    obter_discard_selecionado "$XML_CANDIDATO" "$DISCO_INDICE" \
        || falhar "$XML_DIAGNOSTICO"
    [ "$DISCO_DISCARD_PRESENTE" -eq 1 ] && [ "$DISCO_DISCARD" = "unmap" ] \
        || falhar "O XML candidato não contém discard='unmap' no nó exato."

    exigir_vm_shut_off_exata
    DEFINE_TENTADO=1
    LC_ALL=C $VIRSH define "$XML_CANDIDATO" >/dev/null \
        || falhar "Falha no único define do XML candidato."

    LC_ALL=C $VIRSH dumpxml --inactive "$VM_NAME" > "$XML_POST" \
        || falhar "Define retornou sucesso, mas o XML pós-operação não pôde ser capturado."
    validar_discard_no_xml "$XML_POST" || falhar "Pós-validação falhou: $XML_DIAGNOSTICO"
    [ "$DISCO_INDICE" = "$INDICE_ORIGINAL" ] \
        || falhar "Pós-validação localizou QCOW2_PATH em nó diferente do original."
    ok "discard='unmap' aplicado e pós-validado somente em $QCOW2_PATH."
    info "Isso permite propagar descartes do convidado; não promete redução física imediata do QCOW2."
fi

titulo "Pasta de backups no HD2"
if validar_mount_docs4; then
    MOUNT_ID_ANTES="$MOUNT_ID"
    if [ -e "$DOCS4/backups-vm" ] || [ -L "$DOCS4/backups-vm" ]; then
        [ -d "$DOCS4/backups-vm" ] && [ ! -L "$DOCS4/backups-vm" ] \
            || falhar "$DOCS4/backups-vm existe, mas não é um diretório real seguro."
    else
        sudo mkdir -- "$DOCS4/backups-vm" \
            || falhar "Não foi possível criar $DOCS4/backups-vm."
    fi
    validar_mount_docs4 && [ "$MOUNT_ID" = "$MOUNT_ID_ANTES" ] \
        || falhar "O mount do Docs4 mudou durante a criação de backups-vm."
    ok "$DOCS4/backups-vm pronto no mount exato UUID=$UUID_HD2."
else
    aviso "$MOUNT_DIAGNOSTICO"
    aviso "Pasta backups-vm não criada fora do mount exato esperado."
fi

TRANSACAO_CONCLUIDA=1

echo
cat <<'DICAS'
Operação contínua (Capítulo 25):
  - Dentro do Windows: "Otimizar Unidades" pode emitir TRIM para o C:.
  - O QCOW2 pode ou não reduzir o tamanho físico imediatamente; snapshots,
    alocação do QCOW2 e comportamento do filesystem do host influenciam.
  - fstrim no filesystem do host que contém /vm é uma camada separada: valide
    primeiro o mount e o suporte a discard antes de executá-lo no host.
  - Snapshots offline: util/snapshot-vm.sh criar|listar|reverter|apagar
  - Backup standalone no HD2: util/backup-vm.sh
  - Snapshot NÃO substitui backup: ambos protegem contra riscos diferentes.
DICAS
ok "Etapa 70 concluída sem prometer redução física do QCOW2."
