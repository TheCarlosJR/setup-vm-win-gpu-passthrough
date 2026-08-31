#!/bin/bash
# ============================================================================
# lib/shell/storage.sh - arquivos, diretórios da VM, working disk, qcow2/ISO e fstab
# ============================================================================
# Este arquivo NÃO é executado diretamente: ele é carregado via "source" por
# lib/common.sh, que continua sendo a fachada pública das etapas.
#
# Fronteiras (seções 2.1, 2.3 e 2.4 do PLANO-FINALIZACAO.md):
#
#   * aqui fica a ADMINISTRAÇÃO de arquivo e diretório: publicação e migração
#     do inventário, contenção do working disk, validação de qcow2/ISO,
#     selo do diretório da VM e linhas gerenciadas do fstab;
#   * a observação do host vem de probes.sh; este módulo nunca reimplementa
#     uma sonda (decisão I9-D2 do plano);
#   * toda escrita é transacional ou idempotente e prova a pós-condição.
#
# Pré-requisitos de carga: lib/python-core.sh, lib/shell/base.sh, lib/shell/probes.sh, lib/shell/ui.sh.
# Carregar fora de ordem é recusado com diagnóstico, nunca com falha obscura.
#
# Sourcing deste arquivo não produz efeito: apenas define variáveis e funções.
# ============================================================================

if ! declare -F caminho_sistema > /dev/null 2>&1; then
    printf 'ERRO: lib/shell/storage.sh exige %s carregado antes.\n' 'lib/shell/base.sh' >&2
    return 1 2>/dev/null || exit 1
fi
if ! declare -F falhar > /dev/null 2>&1; then
    printf 'ERRO: lib/shell/storage.sh exige %s carregado antes.\n' 'lib/shell/ui.sh' >&2
    return 1 2>/dev/null || exit 1
fi
if ! declare -F discos_raiz > /dev/null 2>&1; then
    printf 'ERRO: lib/shell/storage.sh exige %s carregado antes.\n' 'lib/shell/probes.sh' >&2
    return 1 2>/dev/null || exit 1
fi
if ! declare -F python_core_pares_payload > /dev/null 2>&1; then
    printf 'ERRO: lib/shell/storage.sh exige %s carregado antes.\n' 'lib/python-core.sh' >&2
    return 1 2>/dev/null || exit 1
fi

[ -n "${STORAGE_SH_CARREGADO:-}" ] && return 0
STORAGE_SH_CARREGADO=1

resolver_ultimo_inventario() {
    # Imprime o inventário principal mais recente. O diretório opcional existe
    # para testes; em produção a única fonte é o acessor diretorio_inventario.
    local diretorio="${1:-$(diretorio_inventario)}"
    local ponteiro="$diretorio/ultimo-inventario.txt" alvo nome candidato
    local -a candidatos=()
    INVENTARIO_ERRO=""
    INVENTARIO_RESOLVIDO=""
    [ -d "$diretorio" ] \
        || { INVENTARIO_ERRO="Diretório de inventários não existe: $diretorio"; return 1; }

    if [ -L "$ponteiro" ]; then
        alvo="$(readlink -- "$ponteiro" 2>/dev/null || true)"
        # O gerador publica links relativos para um arquivo direto no diretório.
        # Isso impede escape por caminho absoluto, '..' ou subdiretórios.
        if [[ "$alvo" != */* ]] \
           && [[ "$alvo" =~ ^inventario-[0-9]{8}(-[0-9]{6}-[0-9]{9})?\.txt$ ]] \
           && [ -f "$diretorio/$alvo" ] && [ ! -L "$diretorio/$alvo" ] \
           && [ -r "$diretorio/$alvo" ] && [ -s "$diretorio/$alvo" ] \
           && validar_inventario_principal "$diretorio/$alvo"; then
            INVENTARIO_RESOLVIDO="$diretorio/$alvo"
            printf '%s\n' "$INVENTARIO_RESOLVIDO"
            return 0
        fi
        INVENTARIO_ERRO="Ponteiro de inventário inválido, quebrado, incompleto ou fora do diretório: $ponteiro"
        return 1
    elif [ -e "$ponteiro" ]; then
        INVENTARIO_ERRO="Ponteiro de inventário não é um link simbólico: $ponteiro"
        return 1
    fi

    # Sem ponteiro, recupera deterministicamente históricos completos nos
    # formatos novo e legado. Artefatos, links, vazios e parciais não entram.
    for candidato in "$diretorio"/inventario-*.txt; do
        [ -f "$candidato" ] && [ ! -L "$candidato" ] && [ -r "$candidato" ] && [ -s "$candidato" ] || continue
        nome="${candidato##*/}"
        [[ "$nome" =~ ^inventario-[0-9]{8}(-[0-9]{6}-[0-9]{9})?\.txt$ ]] || continue
        validar_inventario_principal "$candidato" || continue
        candidatos+=("$candidato")
    done
    if [ "${#candidatos[@]}" -gt 0 ]; then
        local chave data hora nanos
        local -a candidatos_ordenados=()
        for candidato in "${candidatos[@]}"; do
            nome="${candidato##*/}"
            if [[ "$nome" =~ ^inventario-([0-9]{8})\.txt$ ]]; then
                data="${BASH_REMATCH[1]}"; hora="000000"; nanos="000000000"
            else
                [[ "$nome" =~ ^inventario-([0-9]{8})-([0-9]{6})-([0-9]{9})\.txt$ ]] || continue
                data="${BASH_REMATCH[1]}"; hora="${BASH_REMATCH[2]}"; nanos="${BASH_REMATCH[3]}"
            fi
            chave="$data-$hora-$nanos"
            candidatos_ordenados+=("$chave|$candidato")
        done
        INVENTARIO_RESOLVIDO="$(printf '%s\n' "${candidatos_ordenados[@]}" | LC_ALL=C sort | tail -n1 | cut -d'|' -f2-)"
        INVENTARIO_ERRO=""
        printf '%s\n' "$INVENTARIO_RESOLVIDO"
        return 0
    fi
    [ -n "$INVENTARIO_ERRO" ] \
        || INVENTARIO_ERRO="Nenhum inventário principal válido e legível em $diretorio."
    return 1
}

validar_inventario_principal() {
    local arquivo="${1:-}" conteudo
    local -a permitidas=(
        "${CORE_PARES_ENVELOPE[@]}" VALID ERROR SCHEMA_VERSION SOURCE_FORMAT COVERAGE
        CPU_STATE MEMORY_STATE PCI_STATE DISKS_STATE USB_STATE INTERFACES_STATE BOOT_STATE
        SNAPSHOT_FINGERPRINT IDENTITY_FINGERPRINT DECISION_FINGERPRINT
    ) payload=()
    INVENTARIO_ERRO=""
    [ -f "$arquivo" ] && [ ! -L "$arquivo" ] && [ -r "$arquivo" ] && [ -s "$arquivo" ] \
        || { INVENTARIO_ERRO="Inventário inválido, vazio ou ilegível: ${arquivo:-vazio}"; return 1; }
    conteudo="$(<"$arquivo")" || { INVENTARIO_ERRO="Inventário não pôde ser lido."; return 1; }
    payload=(report_text "$conteudo")
    python_core_pares_payload permitidas INVP_ inventory-parse payload 2>/dev/null || {
        INVENTARIO_ERRO="${PYTHON_CORE_ERRO:-Inventário truncado, inconsistente ou fora do schema I6.}"
        return 1
    }
    [ "$INVP_VALID" = 1 ] || {
        INVENTARIO_ERRO="${INVP_ERROR:-Inventário inválido.}"
        return 1
    }
    INVENTARIO_DECISION_FINGERPRINT="$INVP_DECISION_FINGERPRINT"
}

INVENTARIO_PUBLICADO=""
publicar_inventario_completo() {
    # Publica um temporário já concluído e só então troca atomicamente o
    # ponteiro. O timestamp opcional torna o contrato testável sem relógio real.
    local temporario="${1:-}" diretorio="${2:-}" timestamp="${3:-$(date +%Y%m%d-%H%M%S-%N)}"
    local diretorio_real temporario_dir_real arquivo tmp_link
    INVENTARIO_ERRO=""
    INVENTARIO_PUBLICADO=""
    [ -d "$diretorio" ] \
        || { INVENTARIO_ERRO="Diretório de inventários não existe: ${diretorio:-vazio}"; return 1; }
    validar_inventario_principal "$temporario" || return 1
    [[ "$timestamp" =~ ^[0-9]{8}-[0-9]{6}-[0-9]{9}$ ]] \
        || { INVENTARIO_ERRO="Timestamp inválido para publicação: $timestamp"; return 1; }
    diretorio_real="$(readlink -f -- "$diretorio")" || return 1
    temporario_dir_real="$(readlink -f -- "$(dirname -- "$temporario")")" || return 1
    [ "$temporario_dir_real" = "$diretorio_real" ] \
        || { INVENTARIO_ERRO="O temporário precisa estar dentro de $diretorio."; return 1; }

    arquivo="$diretorio/inventario-${timestamp}.txt"
    tmp_link="$diretorio/.ultimo-inventario.tmp.$timestamp"
    [ ! -e "$arquivo" ] && [ ! -L "$arquivo" ] \
        || { INVENTARIO_ERRO="Nome de inventário já existe: $arquivo"; return 1; }
    [ ! -e "$tmp_link" ] && [ ! -L "$tmp_link" ] \
        || { INVENTARIO_ERRO="Temporário do ponteiro já existe: $tmp_link"; return 1; }

    mv -- "$temporario" "$arquivo" \
        || { INVENTARIO_ERRO="Não foi possível publicar o inventário completo."; return 1; }
    if ! ln -s -- "${arquivo##*/}" "$tmp_link"; then
        INVENTARIO_ERRO="Inventário publicado, mas não foi possível preparar o novo ponteiro; o anterior foi preservado."
        return 1
    fi
    if ! mv -Tf -- "$tmp_link" "$diretorio/ultimo-inventario.txt"; then
        rm -f -- "$tmp_link"
        INVENTARIO_ERRO="Inventário publicado, mas não foi possível atualizar o ponteiro; o anterior foi preservado."
        return 1
    fi
    INVENTARIO_PUBLICADO="$arquivo"
    printf '%s\n' "$arquivo"
}

# --- Migração da pasta legada de relatórios ----------------------------------
# Até a unificação, os relatórios moravam em ~/inventario-hardware, fora da raiz
# de estado. A migração é uma TRANSAÇÃO explícita e sempre confirmada pelo
# operador: copia preservando metadados, PROVA que a cópia confere (conjunto de
# caminhos, contagem, tipo, modo, mtime, alvo de link e digest do conteúdo) e só
# então remove a origem. Qualquer divergência remove o que foi copiado, deixa a
# origem intacta e diagnostica. Com a migração já feita, a pasta legada não
# existe mais e toda execução seguinte é um no-op exato, sem pergunta.
INVENTARIO_MIGRACAO_ERRO=""
INVENTARIO_MIGRACAO_ITENS=0
INVENTARIO_LEGADO_ITENS=0

_inventario_entradas_relativas() {
    # _inventario_entradas_relativas ARRAY BASE: preenche ARRAY com todo caminho
    # relativo da árvore, separados por NUL (nomes com quebra de linha entram
    # sem ambiguidade) e sem seguir links simbólicos.
    local -n _inv_entradas_ref="$1"
    local base="${2:-}" lista rel
    _inv_entradas_ref=()
    [ -d "$base" ] && [ ! -L "$base" ] || return 1
    lista="$(mktemp "${TMPDIR:-/tmp}/.inventario-migracao.XXXXXXXXX")" || return 1
    if ! ( cd -- "$base" && LC_ALL=C find . -mindepth 1 -print0 ) > "$lista" 2>/dev/null; then
        rm -f -- "$lista" 2>/dev/null || true
        return 1
    fi
    while IFS= read -r -d '' rel; do
        _inv_entradas_ref+=("${rel#./}")
    done < "$lista"
    rm -f -- "$lista" 2>/dev/null || true
    return 0
}

_inventario_linha_manifesto() {
    # Uma linha por entrada: caminho|tipo|modo|mtime|conteúdo. Links entram pelo
    # alvo textual (nunca pelo destino resolvido) e arquivos pelo digest, para
    # que "a cópia confere" seja uma afirmação sobre bytes e metadados, não
    # sobre o retorno do cp.
    local base="${1:-}" rel="${2:-}" caminho meta modo mtime dado
    caminho="$base/$rel"
    if [ -L "$caminho" ]; then
        dado="$(readlink -- "$caminho")" || return 1
        printf '%s|L|-|-|%s\n' "$rel" "$dado"
        return 0
    fi
    if [ ! -e "$caminho" ]; then
        printf '%s|X|-|-|\n' "$rel"
        return 0
    fi
    meta="$(stat -c '%a %Y' -- "$caminho")" || return 1
    modo="${meta%% *}"
    mtime="${meta##* }"
    if [ -d "$caminho" ]; then
        printf '%s|D|%s|%s|\n' "$rel" "$modo" "$mtime"
    elif [ -f "$caminho" ]; then
        dado="$(sha256sum -- "$caminho")" || return 1
        printf '%s|F|%s|%s|%s\n' "$rel" "$modo" "$mtime" "${dado%% *}"
    else
        printf '%s|O|%s|%s|\n' "$rel" "$modo" "$mtime"
    fi
}

_inventario_manifesto_de() {
    # _inventario_manifesto_de BASE ENTRADA...: manifesto na ordem recebida.
    local base="${1:-}" rel
    shift || return 1
    for rel in "$@"; do
        _inventario_linha_manifesto "$base" "$rel" || return 1
    done
}

inventario_legado_pendente() {
    # 0 somente quando existe pasta legada REAL, distinta do destino e com pelo
    # menos uma entrada. Pasta ausente, link simbólico e pasta vazia são no-op.
    local origem="$INVENTARIO_LEGADO_DIR" destino
    local -a _inv_legado_entradas=()
    INVENTARIO_LEGADO_ITENS=0
    destino="$(diretorio_inventario)"
    [ -d "$origem" ] && [ ! -L "$origem" ] || return 1
    [ "$origem" != "$destino" ] || return 1
    _inventario_entradas_relativas _inv_legado_entradas "$origem" || return 1
    INVENTARIO_LEGADO_ITENS="${#_inv_legado_entradas[@]}"
    [ "$INVENTARIO_LEGADO_ITENS" -gt 0 ] || return 1
    return 0
}

_inventario_desfazer_copia() {
    # Remove do destino EXATAMENTE os nomes de topo que a transação criou. A
    # checagem de colisão garante que nenhum deles existia antes da cópia.
    local destino="${1:-}" topo
    shift || return 0
    for topo in "$@"; do
        rm -rf -- "$destino/$topo" 2>/dev/null || true
    done
}

migrar_inventario_legado() {
    local origem destino topo rel
    local -a origem_entradas=() destino_entradas=() origem_confirmacao=() topos_migrados=()
    local -A origem_conjunto=() destino_conjunto=() topos_vistos=()
    local manifesto_origem manifesto_destino ponteiro alvo

    INVENTARIO_MIGRACAO_ERRO=""
    INVENTARIO_MIGRACAO_ITENS=0
    origem="$INVENTARIO_LEGADO_DIR"
    destino="$(diretorio_inventario)"

    inventario_legado_pendente || {
        INVENTARIO_MIGRACAO_ERRO="Nada a migrar: $origem não existe, está vazio ou já é o destino."
        return 1
    }
    _inventario_entradas_relativas origem_entradas "$origem" || {
        INVENTARIO_MIGRACAO_ERRO="Não foi possível listar a pasta legada: $origem"
        return 1
    }
    for rel in "${origem_entradas[@]}"; do
        origem_conjunto["$rel"]=1
        topo="${rel%%/*}"
        if [ -z "${topos_vistos[$topo]:-}" ]; then
            topos_vistos["$topo"]=1
            topos_migrados+=("$topo")
        fi
    done

    [ ! -L "$destino" ] \
        || { INVENTARIO_MIGRACAO_ERRO="Destino de inventários é um link simbólico: $destino"; return 1; }
    mkdir -p -- "$destino" \
        || { INVENTARIO_MIGRACAO_ERRO="Não foi possível criar o destino de inventários: $destino"; return 1; }

    # Colisão de nome nunca é resolvida sozinha: sobrescrever é perder dado.
    for topo in "${topos_migrados[@]}"; do
        if [ -e "$destino/$topo" ] || [ -L "$destino/$topo" ]; then
            INVENTARIO_MIGRACAO_ERRO="Migração recusada: '$topo' já existe em $destino. Nada foi copiado nem removido; resolva o conflito manualmente."
            return 1
        fi
    done

    if ! cp -a -- "$origem/." "$destino/"; then
        _inventario_desfazer_copia "$destino" "${topos_migrados[@]}"
        INVENTARIO_MIGRACAO_ERRO="Falha ao copiar $origem para $destino; a pasta antiga foi mantida intacta e a cópia parcial foi removida."
        return 1
    fi

    # --- Prova da cópia, antes de qualquer remoção ---------------------------
    if ! _inventario_entradas_relativas destino_entradas "$destino"; then
        _inventario_desfazer_copia "$destino" "${topos_migrados[@]}"
        INVENTARIO_MIGRACAO_ERRO="Não foi possível conferir o destino $destino; a pasta antiga foi mantida intacta."
        return 1
    fi
    local -a destino_migradas=()
    for rel in "${destino_entradas[@]}"; do
        topo="${rel%%/*}"
        [ -n "${topos_vistos[$topo]:-}" ] || continue
        destino_migradas+=("$rel")
        destino_conjunto["$rel"]=1
    done
    if [ "${#destino_migradas[@]}" -ne "${#origem_entradas[@]}" ]; then
        _inventario_desfazer_copia "$destino" "${topos_migrados[@]}"
        INVENTARIO_MIGRACAO_ERRO="Cópia divergente: ${#origem_entradas[@]} entradas na origem e ${#destino_migradas[@]} no destino; a pasta antiga foi mantida intacta."
        return 1
    fi
    for rel in "${origem_entradas[@]}"; do
        if [ -z "${destino_conjunto[$rel]:-}" ]; then
            _inventario_desfazer_copia "$destino" "${topos_migrados[@]}"
            INVENTARIO_MIGRACAO_ERRO="Cópia incompleta: '$rel' não chegou a $destino; a pasta antiga foi mantida intacta."
            return 1
        fi
    done
    for rel in "${destino_migradas[@]}"; do
        if [ -z "${origem_conjunto[$rel]:-}" ]; then
            _inventario_desfazer_copia "$destino" "${topos_migrados[@]}"
            INVENTARIO_MIGRACAO_ERRO="Cópia inesperada: '$rel' apareceu em $destino sem origem; a pasta antiga foi mantida intacta."
            return 1
        fi
    done

    manifesto_origem="$(_inventario_manifesto_de "$origem" "${origem_entradas[@]}")" || {
        _inventario_desfazer_copia "$destino" "${topos_migrados[@]}"
        INVENTARIO_MIGRACAO_ERRO="Não foi possível descrever a pasta legada $origem; nada foi removido."
        return 1
    }
    manifesto_destino="$(_inventario_manifesto_de "$destino" "${origem_entradas[@]}")" || {
        _inventario_desfazer_copia "$destino" "${topos_migrados[@]}"
        INVENTARIO_MIGRACAO_ERRO="Não foi possível descrever a cópia em $destino; a pasta antiga foi mantida intacta."
        return 1
    }
    if [ "$manifesto_origem" != "$manifesto_destino" ]; then
        _inventario_desfazer_copia "$destino" "${topos_migrados[@]}"
        INVENTARIO_MIGRACAO_ERRO="Conteúdo ou metadados divergiram entre $origem e $destino; a pasta antiga foi mantida intacta."
        return 1
    fi

    # A origem não pode ter mudado durante a transação.
    _inventario_entradas_relativas origem_confirmacao "$origem" || {
        _inventario_desfazer_copia "$destino" "${topos_migrados[@]}"
        INVENTARIO_MIGRACAO_ERRO="A pasta legada $origem ficou ilegível durante a migração; nada foi removido."
        return 1
    }
    if [ "${#origem_confirmacao[@]}" -ne "${#origem_entradas[@]}" ]; then
        _inventario_desfazer_copia "$destino" "${topos_migrados[@]}"
        INVENTARIO_MIGRACAO_ERRO="A pasta legada $origem mudou durante a migração; nada foi removido."
        return 1
    fi

    # O ponteiro é relativo por contrato: depois da cópia ele precisa continuar
    # resolvendo dentro do destino, sem apontar para a pasta antiga.
    ponteiro="$origem/ultimo-inventario.txt"
    if [ -L "$ponteiro" ]; then
        alvo="$(readlink -- "$destino/ultimo-inventario.txt" 2>/dev/null || true)"
        if [ ! -L "$destino/ultimo-inventario.txt" ] || [[ "$alvo" == /* ]] \
           || [ ! -e "$destino/$alvo" ]; then
            _inventario_desfazer_copia "$destino" "${topos_migrados[@]}"
            INVENTARIO_MIGRACAO_ERRO="O ponteiro ultimo-inventario.txt não ficou válido em $destino; a pasta antiga foi mantida intacta."
            return 1
        fi
    fi

    # --- Só agora a origem sai ------------------------------------------------
    [[ "$origem" == /* ]] && [ "$origem" != / ] && [ -d "$origem" ] && [ ! -L "$origem" ] \
        && [ "$origem" = "$HOME/inventario-hardware" ] \
        || { INVENTARIO_MIGRACAO_ERRO="Recusa de segurança: a origem $origem não é a pasta legada esperada."; return 1; }
    if ! rm -rf -- "$origem"; then
        INVENTARIO_MIGRACAO_ERRO="A cópia foi conferida em $destino, mas $origem não pôde ser removida; remova-a manualmente após conferir."
        return 1
    fi
    if [ -e "$origem" ] || [ -L "$origem" ]; then
        INVENTARIO_MIGRACAO_ERRO="A cópia foi conferida em $destino, mas $origem continua presente; remova-a manualmente após conferir."
        return 1
    fi
    INVENTARIO_MIGRACAO_ITENS="${#origem_entradas[@]}"
    return 0
}

inventario_migracao_interativa() {
    # Pergunta UMA vez, na etapa 1, e só quando há pasta legada com conteúdo.
    # Recusar não quebra nada: os relatórios novos vão para o destino unificado.
    local destino
    destino="$(diretorio_inventario)"
    inventario_legado_pendente || return 0
    echo
    aviso "Relatórios antigos encontrados em $INVENTARIO_LEGADO_DIR ($INVENTARIO_LEGADO_ITENS itens)."
    info "Este projeto passou a guardar tudo sob uma raiz única de estado: $destino"
    info "A migração copia preservando metadados, confere a cópia inteira e só então remove a pasta antiga."
    if confirmar "Migrar agora os relatórios antigos para a raiz de estado?"; then
        migrar_inventario_legado || falhar "$INVENTARIO_MIGRACAO_ERRO"
        ok "Migração concluída: $INVENTARIO_MIGRACAO_ITENS itens conferidos em $destino."
        info "A pasta antiga $INVENTARIO_LEGADO_DIR foi removida somente depois da conferência."
    else
        aviso "Migração recusada: $INVENTARIO_LEGADO_DIR continua onde está e nada foi copiado nem removido."
        info "Os relatórios novos vão para $destino, e a verificação da etapa 1 considera apenas esse diretório."
    fi
}

inventario_revalidar_papeis_disco_configurados() {
    # Reobserva os três papéis persistidos pela I6 como um único plano. Esta
    # função só faz probes de leitura no Bash; o core compara as identidades e
    # recusa troca de mídia, alias entre papéis ou evidência incompleta.
    local sistema="${NVME_DEVICE:-}" working="${WORKING_DISK_PATH:-}"
    local hd1="${HD1_BY_ID_PATH:-}" system_members working_members="" hd1_members=""
    INVENTARIO_ERRO=""

    [ -n "$sistema" ] && [ -n "${SYSTEM_DISK_FINGERPRINT:-}" ] || {
        INVENTARIO_ERRO="Identidade física do disco do sistema ausente; execute a etapa 3 com --redetectar."
        return 1
    }
    if [ -n "$working" ] && [ "${WORKING_DISK_DISPENSADO:-}" = sim ]; then
        INVENTARIO_ERRO="workingDisk está simultaneamente configurado e dispensado."
        return 1
    fi
    if [ -n "$hd1" ] && [ "${HD1_DISPENSADO:-}" = sim ]; then
        INVENTARIO_ERRO="HD1 está simultaneamente configurado e dispensado."
        return 1
    fi

    system_members="$(discos_raiz 2>/dev/null)" || {
        INVENTARIO_ERRO="Não foi possível reobservar todos os discos físicos da raiz do sistema."
        return 1
    }
    [ -n "$system_members" ] || {
        INVENTARIO_ERRO="O papel sistema não resolveu para disco físico."
        return 1
    }

    if [ -n "$working" ]; then
        [ -n "${WORKING_DISK_FINGERPRINT:-}" ] || {
            INVENTARIO_ERRO="Identidade física do workingDisk ausente; execute a etapa 3 com --redetectar."
            return 1
        }
        validar_working_disk_montado "$working" || {
            INVENTARIO_ERRO="${WORKING_DISK_ERRO:-O workingDisk não pôde ser revalidado.}"
            return 1
        }
        working_members="$(discos_fisicos_de "$WORKING_DISK_SOURCE" 2>/dev/null)" || {
            INVENTARIO_ERRO="Não foi possível reobservar todos os discos físicos do workingDisk."
            return 1
        }
        [ -n "$working_members" ] || {
            INVENTARIO_ERRO="O workingDisk não resolveu para disco físico."
            return 1
        }
    elif [ -n "${WORKING_DISK_FINGERPRINT:-}" ]; then
        INVENTARIO_ERRO="Fingerprint de workingDisk existe sem WORKING_DISK_PATH."
        return 1
    fi

    if [ -n "$hd1" ]; then
        [ -n "${HD1_DISK_FINGERPRINT:-}" ] || {
            INVENTARIO_ERRO="Identidade física do HD1 ausente; execute a etapa 3 com --redetectar."
            return 1
        }
        hd1_members="$(readlink -f -- "$hd1" 2>/dev/null)" || {
            INVENTARIO_ERRO="O localizador persistente do HD1 não pôde ser resolvido."
            return 1
        }
        [ -n "$hd1_members" ] || {
            INVENTARIO_ERRO="O localizador persistente do HD1 resolveu vazio."
            return 1
        }
    elif [ -n "${HD1_DISK_FINGERPRINT:-}" ]; then
        INVENTARIO_ERRO="Fingerprint de HD1 existe sem HD1_BY_ID_PATH."
        return 1
    fi

    inventario_planejar_papeis_disco \
        "$system_members" "$working_members" "$hd1_members" \
        "$SYSTEM_DISK_FINGERPRINT" "${WORKING_DISK_FINGERPRINT:-}" \
        "${HD1_DISK_FINGERPRINT:-}" || return 1
}

# Parsers current-v1, legacy-v0 e v2 vivem exclusivamente em inventory.py.
# A fachada Bash só transporta o relatório como dado pelo canal controlado.

comparar_inventario_com_hardware() {
    # O segundo argumento current-v1 continua aceito para caracterização. Em
    # produção, Bash recaptura todos os fatos e o core compara dois modelos.
    local arquivo="${1:-}" atual="${2:-}" esperado tmp=""
    local -a payload=() captura=() permitidas=(
        "${CORE_PARES_ENVELOPE[@]}" EQUAL PHYSICAL_CHANGED STATE_CHANGED
        COVERAGE_CHANGED FORMAT_ONLY REQUIRES_REDETECT CHANGE_COUNT
        'CHANGE_#_CATEGORY' 'CHANGE_#_PATH' 'CHANGE_#_OLD_STATE'
        'CHANGE_#_NEW_STATE' 'CHANGE_#_MESSAGE'
    )
    INVENTARIO_DIFERENCAS=""
    validar_inventario_principal "$arquivo" || return 1
    esperado="$(<"$arquivo")" || { INVENTARIO_ERRO="Não foi possível reler o inventário validado."; return 1; }
    if [ -z "$atual" ]; then
        coletar_snapshot_inventario captura || {
            INVENTARIO_ERRO="Não foi possível obter a captura atual do hardware."
            return 1
        }
        tmp="$(umask 077; mktemp "${TMPDIR:-/tmp}/inventario-atual.XXXXXXXX")" || return 1
        if ! inventario_normalizar_snapshot captura "$tmp"; then
            rm -f -- "$tmp"
            return 1
        fi
        atual="$(<"$tmp")"
        rm -f -- "$tmp"
    fi
    payload=(expected_report "$esperado" actual_capture "$atual")
    python_core_pares_payload permitidas INVDIFF_ inventory-diff payload || {
        INVENTARIO_DIFERENCAS="${PYTHON_CORE_ERRO:-Captura atual inválida.}"
        INVENTARIO_ERRO="${PYTHON_CORE_ERRO:-Não foi possível comparar o inventário com a captura atual.}"
        return 1
    }
    if [ "$INVDIFF_REQUIRES_REDETECT" = 1 ]; then
        local indice nome_categoria nome_caminho nome_mensagem caminho_rotulo
        for (( indice=0; indice<INVDIFF_CHANGE_COUNT; indice++ )); do
            nome_categoria="INVDIFF_CHANGE_${indice}_CATEGORY"
            nome_caminho="INVDIFF_CHANGE_${indice}_PATH"
            nome_mensagem="INVDIFF_CHANGE_${indice}_MESSAGE"
            case "${!nome_caminho}" in
                cpu) caminho_rotulo=CPU ;;
                memory) caminho_rotulo=RAM ;;
                pci) caminho_rotulo=PCI ;;
                disks) caminho_rotulo=Discos ;;
                usb) caminho_rotulo=USB ;;
                interfaces) caminho_rotulo=Interfaces ;;
                boot) caminho_rotulo=Boot ;;
                *) caminho_rotulo="${!nome_caminho}" ;;
            esac
            INVENTARIO_DIFERENCAS+="$caminho_rotulo: ${!nome_mensagem} (${!nome_categoria})."$'\n'
        done
        INVENTARIO_DIFERENCAS="${INVENTARIO_DIFERENCAS%$'\n'}"
        INVENTARIO_ERRO="O hardware atual diverge semanticamente do último inventário completo."
        return 1
    fi
}

WORKING_DISK_ERRO=""
WORKING_DISK_SOURCE=""
WORKING_DISK_FSTYPE=""
validar_working_disk_montado() {
    # O operador monta o workingDisk externamente. Esta função apenas comprova
    # que o caminho configurado é canônico, um mountpoint ativo e coleta um
    # diagnóstico; nunca cria diretório, monta, formata ou altera o fstab.
    local caminho="${1:-}" alvo caminho_lexico caminho_fisico
    WORKING_DISK_ERRO=""
    WORKING_DISK_SOURCE=""
    WORKING_DISK_FSTYPE=""
    caminho_absoluto_seguro "$caminho" \
        || { WORKING_DISK_ERRO="WORKING_DISK_PATH inseguro: '${caminho:-vazio}'."; return 1; }
    [ -d "$caminho" ] \
        || { WORKING_DISK_ERRO="WORKING_DISK_PATH não é um diretório existente: $caminho"; return 1; }
    command -v readlink >/dev/null 2>&1 \
        && command -v mountpoint >/dev/null 2>&1 \
        && command -v findmnt >/dev/null 2>&1 \
        || { WORKING_DISK_ERRO="readlink/mountpoint/findmnt são necessários para validar o workingDisk."; return 1; }
    caminho_lexico="$(_caminho_lexico_normalizado "$caminho")" \
        || { WORKING_DISK_ERRO="Não foi possível normalizar WORKING_DISK_PATH: $caminho"; return 1; }
    caminho_fisico="$(readlink -f -- "$caminho" 2>/dev/null)" \
        || { WORKING_DISK_ERRO="Não foi possível canonicalizar WORKING_DISK_PATH: $caminho"; return 1; }
    [ "$caminho" = "$caminho_lexico" ] && [ "$caminho_fisico" = "$caminho" ] \
        || { WORKING_DISK_ERRO="WORKING_DISK_PATH precisa ser canônico e não pode conter componentes simbólicos: $caminho"; return 1; }
    mountpoint -q -- "$caminho" \
        || { WORKING_DISK_ERRO="workingDisk não está montado exatamente em $caminho."; return 1; }
    alvo="$(findmnt -rn --raw --mountpoint "$caminho" --output TARGET 2>/dev/null)" \
        || { WORKING_DISK_ERRO="findmnt não confirmou o mountpoint exato $caminho."; return 1; }
    [ "$alvo" = "$caminho" ] \
        || { WORKING_DISK_ERRO="mountpoint divergente: configurado '$caminho', ativo '${alvo:-desconhecido}'."; return 1; }
    WORKING_DISK_SOURCE="$(findmnt -rn --raw --mountpoint "$caminho" --output SOURCE 2>/dev/null)" \
        || { WORKING_DISK_ERRO="findmnt não informou a origem de $caminho."; return 1; }
    WORKING_DISK_FSTYPE="$(findmnt -rn --raw --mountpoint "$caminho" --output FSTYPE 2>/dev/null)" \
        || { WORKING_DISK_ERRO="findmnt não informou o filesystem de $caminho."; return 1; }
    [ -n "$WORKING_DISK_SOURCE" ] && [ -n "$WORKING_DISK_FSTYPE" ] \
        || { WORKING_DISK_ERRO="Diagnóstico incompleto do workingDisk em $caminho."; return 1; }
}

WORKING_DISK_CONTENCAO_ERRO=""
WORKING_DISK_CAMINHO_FISICO=""
WORKING_DISK_BASE_FISICA=""
WORKING_DISK_CONTENCAO_ESTADO=""
caminho_dentro_working_disk() {
    # Retornos: 0=dentro (inclusive alias externo que resolve para dentro),
    # 1=fora comprovado, 2=inválido/escape simbólico. Destinos podem não existir.
    local caminho="${1:-}" base="${2:-${WORKING_DISK_PATH:-}}"
    local caminho_lexico base_lexica caminho_fisico base_fisica
    local lexical_dentro=0 fisico_dentro=0
    WORKING_DISK_CONTENCAO_ERRO=""
    WORKING_DISK_CAMINHO_FISICO=""
    WORKING_DISK_BASE_FISICA=""
    WORKING_DISK_CONTENCAO_ESTADO=""
    if ! caminho_absoluto_seguro "$caminho" || ! caminho_absoluto_seguro "$base"; then
        WORKING_DISK_CONTENCAO_ERRO="Destino ou WORKING_DISK_PATH possui sintaxe insegura: destino='${caminho:-vazio}', base='${base:-vazia}'."
        WORKING_DISK_CONTENCAO_ESTADO=erro
        return 2
    fi
    command -v readlink >/dev/null 2>&1 \
        || { WORKING_DISK_CONTENCAO_ERRO="readlink é necessário para comprovar a contenção no workingDisk."; WORKING_DISK_CONTENCAO_ESTADO=erro; return 2; }
    caminho_lexico="$(_caminho_lexico_normalizado "$caminho")" \
        && base_lexica="$(_caminho_lexico_normalizado "$base")" \
        || { WORKING_DISK_CONTENCAO_ERRO="Não foi possível normalizar destino/base do workingDisk."; WORKING_DISK_CONTENCAO_ESTADO=erro; return 2; }
    caminho_fisico="$(readlink -m -- "$caminho" 2>/dev/null)" \
        && base_fisica="$(readlink -m -- "$base" 2>/dev/null)" \
        || { WORKING_DISK_CONTENCAO_ERRO="Não foi possível resolver fisicamente destino/base do workingDisk."; WORKING_DISK_CONTENCAO_ESTADO=erro; return 2; }
    WORKING_DISK_CAMINHO_FISICO="$caminho_fisico"
    WORKING_DISK_BASE_FISICA="$base_fisica"
    if [ "$base" != "$base_lexica" ] || [ "$base_fisica" != "$base_lexica" ]; then
        WORKING_DISK_CONTENCAO_ERRO="WORKING_DISK_PATH precisa ser canônico e não pode conter componentes simbólicos: $base"
        WORKING_DISK_CONTENCAO_ESTADO=erro
        return 2
    fi
    _caminho_igual_ou_filho "$caminho_lexico" "$base_lexica" && lexical_dentro=1
    _caminho_igual_ou_filho "$caminho_fisico" "$base_fisica" && fisico_dentro=1
    if [ "$lexical_dentro" -eq 1 ] && [ "$fisico_dentro" -ne 1 ]; then
        WORKING_DISK_CONTENCAO_ERRO="Destino lexicalmente interno ao workingDisk resolve para fora dele: '$caminho' -> '$caminho_fisico'."
        WORKING_DISK_CONTENCAO_ESTADO=erro
        return 2
    fi
    if [ "$fisico_dentro" -eq 1 ]; then
        WORKING_DISK_CONTENCAO_ESTADO=dentro
        return 0
    fi
    WORKING_DISK_CONTENCAO_ESTADO=fora
    return 1
}

# Artefatos entregues à gramática `--disk` do virt-install ficam diretamente
# em /vm e nunca contêm vírgula (delimitador interno dessa opção). Além de
# evitar reinterpretação, a raiz única pode ser selada contra rename no open.
caminho_artefato_vm_logico_valido() {
    local caminho="${1:-}" nome
    caminho_absoluto_seguro "$caminho" || return 1
    [[ "$caminho" != *,* && "$caminho" == /vm/* ]] || return 1
    nome="${caminho#/vm/}"
    [ -n "$nome" ] && [[ "$nome" != */* ]] && [ "$caminho" = "/vm/$nome" ]
}

caminho_qcow2_logico_valido() {
    caminho_artefato_vm_logico_valido "${1:-}"
}

ARMAZENAMENTO_ERRO=""
ARMAZENAMENTO_CAMINHO_FISICO=""
ARMAZENAMENTO_FINGERPRINT=""
ARMAZENAMENTO_QCOW2_ESTADO=""

_caminho_configurado_fisico() {
    local caminho="${1:-}"
    caminho_absoluto_seguro "$caminho" || return 1
    caminho_sistema "$caminho"
}

_armazenamento_caminho_existente_canonico() {
    local caminho="${1:-}" pai real_pai real_alvo
    [ -f "$caminho" ] && [ ! -L "$caminho" ] || return 1
    pai="$(dirname -- "$caminho")" || return 1
    real_pai="$(readlink -f -- "$pai" 2>/dev/null)" || return 1
    real_alvo="$(readlink -f -- "$caminho" 2>/dev/null)" || return 1
    [ "$real_pai" = "$pai" ] && [ "$real_alvo" = "$caminho" ]
}

armazenamento_fingerprint_atual() {
    local caminho="${1:-}"
    _armazenamento_caminho_existente_canonico "$caminho" || return 1
    stat -c '%d:%i:%s:%Y:%f:%h' -- "$caminho" 2>/dev/null
}

validar_qcow2_configurado() {
    # Aceita estado existente ou ausente, mas nunca link, hardlink, componente
    # simbólico, formato diferente de qcow2 ou metadados que exigiriam reparo
    # privilegiado. Define caminho físico/fingerprint/estado para o chamador.
    local logico="${1:-}" grupo="${2:-}" fisico raiz real_raiz pai estado info links
    ARMAZENAMENTO_ERRO=""
    ARMAZENAMENTO_CAMINHO_FISICO=""
    ARMAZENAMENTO_FINGERPRINT=""
    ARMAZENAMENTO_QCOW2_ESTADO=""
    caminho_qcow2_logico_valido "$logico" \
        || { ARMAZENAMENTO_ERRO="QCOW2_PATH deve ser canônico e um filho direto de /vm: '$logico'."; return 1; }
    nome_grupo_vm_dedicado_valido "$grupo" \
        || { ARMAZENAMENTO_ERRO="Grupo de armazenamento inválido: '$grupo'."; return 1; }
    fisico="$(_caminho_configurado_fisico "$logico")" \
        || { ARMAZENAMENTO_ERRO="Não foi possível mapear QCOW2_PATH."; return 1; }
    raiz="$(caminho_sistema /vm)" \
        || { ARMAZENAMENTO_ERRO="Não foi possível resolver /vm."; return 1; }
    [ -d "$raiz" ] && [ ! -L "$raiz" ] \
        || { ARMAZENAMENTO_ERRO="/vm precisa ser diretório real, não link."; return 1; }
    real_raiz="$(readlink -f -- "$raiz" 2>/dev/null)" \
        || { ARMAZENAMENTO_ERRO="Não foi possível canonicalizar /vm."; return 1; }
    [ "$real_raiz" = "$raiz" ] \
        || { ARMAZENAMENTO_ERRO="/vm contém componente simbólico ou não canônico."; return 1; }
    pai="$(dirname -- "$fisico")"
    [ "$pai" = "$raiz" ] \
        || { ARMAZENAMENTO_ERRO="QCOW2_PATH físico escapou da raiz /vm."; return 1; }
    [ ! -L "$fisico" ] \
        || { ARMAZENAMENTO_ERRO="QCOW2_PATH não pode ser link simbólico."; return 1; }
    ARMAZENAMENTO_CAMINHO_FISICO="$fisico"
    if [ ! -e "$fisico" ]; then
        ARMAZENAMENTO_QCOW2_ESTADO=ausente
        return 0
    fi
    _armazenamento_caminho_existente_canonico "$fisico" \
        || { ARMAZENAMENTO_ERRO="QCOW2 existente deve ser arquivo regular canônico, sem links em nenhum componente."; return 1; }
    links="$(stat -c '%h' -- "$fisico" 2>/dev/null)" \
        || { ARMAZENAMENTO_ERRO="Não foi possível inspecionar os links do QCOW2."; return 1; }
    [ "$links" = 1 ] \
        || { ARMAZENAMENTO_ERRO="QCOW2 com hardlinks foi recusado (nlink=$links)."; return 1; }
    estado="$(stat -c '%G:%a' -- "$fisico" 2>/dev/null)" \
        || { ARMAZENAMENTO_ERRO="Não foi possível inspecionar grupo/modo do QCOW2."; return 1; }
    [ "$estado" = "$grupo:660" ] \
        || { ARMAZENAMENTO_ERRO="QCOW2 está como $estado; esperado $grupo:660. Corrija-o manualmente após conferir o inode, sem executar esta etapa como root."; return 1; }
    command -v qemu-img >/dev/null 2>&1 \
        || { ARMAZENAMENTO_ERRO="qemu-img indisponível para validar o formato antes de sudo."; return 1; }
    info="$(qemu-img info --output=json "$fisico" 2>&1)" \
        || { ARMAZENAMENTO_ERRO="qemu-img recusou o arquivo: ${info:-sem diagnóstico}."; return 1; }
    grep -Eq '"format"[[:space:]]*:[[:space:]]*"qcow2"' <<< "$info" \
        || { ARMAZENAMENTO_ERRO="O arquivo existente não declara formato qcow2."; return 1; }
    ARMAZENAMENTO_FINGERPRINT="$(armazenamento_fingerprint_atual "$fisico")" \
        || { ARMAZENAMENTO_ERRO="Não foi possível fixar a identidade do QCOW2."; return 1; }
    ARMAZENAMENTO_QCOW2_ESTADO=existente
}

validar_iso_configurada() {
    # ISOs são somente leitura: não há cópia, chmod, chgrp nem ACL automática.
    # O acesso do QEMU é comprovado separadamente depois que sudo está disponível.
    local logico="${1:-}" fisico links
    ARMAZENAMENTO_ERRO=""
    ARMAZENAMENTO_CAMINHO_FISICO=""
    ARMAZENAMENTO_FINGERPRINT=""
    caminho_artefato_vm_logico_valido "$logico" \
        || { ARMAZENAMENTO_ERRO="ISO deve ser um filho direto canônico de /vm e não pode conter vírgula: '$logico'."; return 1; }
    fisico="$(_caminho_configurado_fisico "$logico")" \
        || { ARMAZENAMENTO_ERRO="Não foi possível mapear a ISO."; return 1; }
    [ ! -L "$fisico" ] \
        || { ARMAZENAMENTO_ERRO="ISO não pode ser link simbólico: $logico"; return 1; }
    _armazenamento_caminho_existente_canonico "$fisico" \
        || { ARMAZENAMENTO_ERRO="ISO deve ser arquivo regular canônico, sem componentes simbólicos: $logico"; return 1; }
    [ -r "$fisico" ] \
        || { ARMAZENAMENTO_ERRO="O operador não consegue ler a ISO: $logico"; return 1; }
    links="$(stat -c '%h' -- "$fisico" 2>/dev/null)" \
        || { ARMAZENAMENTO_ERRO="Não foi possível inspecionar a ISO: $logico"; return 1; }
    [ "$links" = 1 ] \
        || { ARMAZENAMENTO_ERRO="ISO com hardlinks foi recusada: $logico"; return 1; }
    ARMAZENAMENTO_CAMINHO_FISICO="$fisico"
    ARMAZENAMENTO_FINGERPRINT="$(armazenamento_fingerprint_atual "$fisico")" \
        || { ARMAZENAMENTO_ERRO="Não foi possível fixar a identidade da ISO: $logico"; return 1; }
}

GRUPO_VM_ERRO=""
validar_acl_diretorio_vm() {
    local diretorio="${1:-/vm}" saida linha
    local u=0 g=0 m=0 o=0 du=0 dg=0 dm=0 do_=0
    GRUPO_VM_ERRO=""
    command -v getfacl >/dev/null 2>&1 \
        || { GRUPO_VM_ERRO="getfacl indisponível para comprovar a herança de /vm."; return 1; }
    saida="$(getfacl -cp -- "$diretorio" 2>/dev/null)" \
        || { GRUPO_VM_ERRO="Não foi possível ler as ACLs de $diretorio."; return 1; }
    while IFS= read -r linha || [ -n "$linha" ]; do
        [ -n "$linha" ] || continue
        case "$linha" in
            user::rwx) u=$((u + 1)) ;;
            group::rwx) g=$((g + 1)) ;;
            mask::rwx) m=$((m + 1)) ;;
            other::---) o=$((o + 1)) ;;
            default:user::rwx) du=$((du + 1)) ;;
            default:group::rwx) dg=$((dg + 1)) ;;
            default:mask::rwx) dm=$((dm + 1)) ;;
            default:other::---) do_=$((do_ + 1)) ;;
            \#*) ;;
            *) GRUPO_VM_ERRO="ACL inesperada em $diretorio: $linha"; return 1 ;;
        esac
    done <<< "$saida"
    [ "$u" -eq 1 ] && [ "$g" -eq 1 ] && [ "$m" -eq 1 ] && [ "$o" -eq 1 ] \
        && [ "$du" -eq 1 ] && [ "$dg" -eq 1 ] && [ "$dm" -eq 1 ] && [ "$do_" -eq 1 ] \
        || { GRUPO_VM_ERRO="ACL de acesso/default de $diretorio não é exatamente rwx/rwx/--- com máscara rwx."; return 1; }
}

validar_modelo_diretorio_vm() {
    # validar_modelo_diretorio_vm DIRETORIO OPERADOR [USUARIO_QEMU] [GRUPO]
    local diretorio="${1:-/vm}" operador="${2:-}" qemu="${3:-}"
    local grupo="${4:-${VM_STORAGE_GROUP:-vm-passthrough}}" estado
    local nome senha gid membros extra
    local -a registros=()
    GRUPO_VM_ERRO=""
    nome_grupo_vm_dedicado_valido "$grupo" \
        || { GRUPO_VM_ERRO="Grupo de armazenamento precisa usar o namespace dedicado 'vm-passthrough[-sufixo]': '$grupo'."; return 1; }
    mapfile -t registros < <(getent group "$grupo" 2>/dev/null)
    [ "${#registros[@]}" -eq 1 ] \
        || { GRUPO_VM_ERRO="Grupo compartilhado '$grupo' não possui entrada NSS única."; return 1; }
    IFS=: read -r nome senha gid membros extra <<< "${registros[0]}"
    [ "$nome" = "$grupo" ] && [ -z "$extra" ] && inteiro_na_faixa "$gid" 1 2147483647 \
        || { GRUPO_VM_ERRO="Entrada NSS inconsistente para o grupo dedicado '$grupo'."; return 1; }
    [ -d "$diretorio" ] \
        || { GRUPO_VM_ERRO="Diretório $diretorio não existe."; return 1; }
    estado="$(stat -c '%U:%G:%a' -- "$diretorio" 2>/dev/null)" \
        || { GRUPO_VM_ERRO="Não foi possível inspecionar $diretorio."; return 1; }
    [ "$estado" = "root:$grupo:2770" ] \
        || { GRUPO_VM_ERRO="$diretorio está como $estado; esperado root:$grupo:2770."; return 1; }
    usuario_pertence_grupo "$operador" "$grupo" \
        || { GRUPO_VM_ERRO="Operador '$operador' não pertence ao grupo '$grupo'."; return 1; }
    if [ -n "$qemu" ]; then
        usuario_pertence_grupo "$qemu" "$grupo" \
            || { GRUPO_VM_ERRO="Identidade QEMU '$qemu' não pertence ao grupo '$grupo'."; return 1; }
    fi
    validar_acl_diretorio_vm "$diretorio"
}

configurar_modelo_diretorio_vm() {
    local diretorio="${1:-/vm}" grupo="${2:-${VM_STORAGE_GROUP:-vm-passthrough}}"
    nome_grupo_vm_dedicado_valido "$grupo" \
        || falhar "Grupo de armazenamento precisa usar o namespace dedicado 'vm-passthrough[-sufixo]': '$grupo'."
    sudo chown "root:$grupo" "$diretorio"
    sudo setfacl -b -k -- "$diretorio"
    sudo setfacl -m 'u::rwx,g::rwx,m::rwx,o::---' -- "$diretorio"
    sudo setfacl -m 'd:u::rwx,d:g::rwx,d:m::rwx,d:o::---' -- "$diretorio"
    sudo chmod 2770 "$diretorio"
}

SELO_VM_ERRO=""
selar_diretorio_vm() {
    # Remove somente o write do grupo na raiz fixa /vm. Arquivos já abertos
    # continuam graváveis, mas nenhum membro do grupo pode criar/renomear uma
    # entrada entre a validação e o consumidor abrir o pathname.
    local diretorio="${1:-}" grupo="${2:-}" raiz estado real
    SELO_VM_ERRO=""
    raiz="$(caminho_sistema /vm)" \
        || { SELO_VM_ERRO="Não foi possível resolver /vm para selagem."; return 1; }
    [ "$diretorio" = "$raiz" ] && [ -d "$diretorio" ] && [ ! -L "$diretorio" ] \
        || { SELO_VM_ERRO="A selagem só aceita a raiz fixa /vm, regular e sem link."; return 1; }
    nome_grupo_vm_dedicado_valido "$grupo" \
        || { SELO_VM_ERRO="Grupo inválido para selagem de /vm: '$grupo'."; return 1; }
    real="$(readlink -f -- "$diretorio" 2>/dev/null)" \
        || { SELO_VM_ERRO="Não foi possível canonicalizar /vm para selagem."; return 1; }
    [ "$real" = "$diretorio" ] \
        || { SELO_VM_ERRO="A raiz /vm não é canônica para selagem."; return 1; }
    estado="$(stat -c '%U:%G:%a' -- "$diretorio" 2>/dev/null)" \
        || { SELO_VM_ERRO="Não foi possível inspecionar /vm antes da selagem."; return 1; }
    [ "$estado" = "root:$grupo:2770" ] \
        || { SELO_VM_ERRO="Estado inesperado antes da selagem: $estado."; return 1; }
    sudo chmod 2750 "$diretorio" \
        || { SELO_VM_ERRO="Falha ao remover write do grupo em /vm."; return 1; }
    estado="$(stat -c '%U:%G:%a' -- "$diretorio" 2>/dev/null)" \
        || { SELO_VM_ERRO="Não foi possível comprovar a selagem de /vm."; return 1; }
    [ "$estado" = "root:$grupo:2750" ] \
        || { SELO_VM_ERRO="Selagem de /vm não convergiu: $estado."; return 1; }
}

restaurar_diretorio_vm() {
    local diretorio="${1:-}" grupo="${2:-}" raiz estado
    SELO_VM_ERRO=""
    raiz="$(caminho_sistema /vm)" \
        || { SELO_VM_ERRO="Não foi possível resolver /vm para restauração."; return 1; }
    [ "$diretorio" = "$raiz" ] && [ -d "$diretorio" ] && [ ! -L "$diretorio" ] \
        || { SELO_VM_ERRO="A restauração só aceita a raiz fixa /vm."; return 1; }
    nome_grupo_vm_dedicado_valido "$grupo" \
        || { SELO_VM_ERRO="Grupo inválido para restauração de /vm: '$grupo'."; return 1; }
    sudo chmod 2770 "$diretorio" \
        || { SELO_VM_ERRO="Falha ao restaurar write do grupo em /vm."; return 1; }
    estado="$(stat -c '%U:%G:%a' -- "$diretorio" 2>/dev/null)" \
        || { SELO_VM_ERRO="Não foi possível comprovar a restauração de /vm."; return 1; }
    [ "$estado" = "root:$grupo:2770" ] \
        || { SELO_VM_ERRO="Restauração de /vm não convergiu: $estado."; return 1; }
    validar_acl_diretorio_vm "$diretorio" \
        || { SELO_VM_ERRO="ACL de /vm não foi restaurada: $GRUPO_VM_ERRO"; return 1; }
}

validar_arquivo_compartilhado_vm() {
    local arquivo="$1" grupo="$2" estado
    [ -f "$arquivo" ] && [ ! -L "$arquivo" ] || return 1
    estado="$(stat -c '%h:%G:%a' -- "$arquivo" 2>/dev/null)" || return 1
    [ "$estado" = "1:$grupo:660" ]
}

# --- fstab gerenciado (linhas com marcador, idempotentes) ----------------------
FSTAB="/etc/fstab"

fstab_backup() {
    local destino="${FSTAB}.bak-$(date +%Y%m%d-%H%M%S)"
    sudo cp "$FSTAB" "$destino"
    info "Backup do fstab criado: $destino"
}

fstab_definir_linha() {
    # fstab_definir_linha ID "linha completa"
    # Adiciona (ou substitui) uma linha marcada com "# vm-passthrough:ID".
    local id="$1" linha="$2"
    sudo sed -i "/^# vm-passthrough:${id}\$/,+1d" "$FSTAB"
    printf '%s\n%s\n' "# vm-passthrough:${id}" "$linha" | sudo tee -a "$FSTAB" >/dev/null
    info "fstab: linha '${id}' definida."
}

fstab_remover_linha() {
    local id="$1"
    sudo sed -i "/^# vm-passthrough:${id}\$/,+1d" "$FSTAB"
}

fstab_tem_linha() {
    grep -q "^# vm-passthrough:${1}\$" "$FSTAB" 2>/dev/null
}
