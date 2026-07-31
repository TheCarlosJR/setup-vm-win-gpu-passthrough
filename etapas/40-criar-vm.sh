#!/bin/bash
# ============================================================================
# etapas/40-criar-vm.sh - Capítulo 17: Criação da Máquina Virtual
# ============================================================================
# Versão automatizada (virt-install) da criação feita no Virt-Manager pelo
# manual, com exatamente as mesmas escolhas:
#   - Firmware OVMF (UEFI) + chipset Q35
#   - TPM 2.0 emulado (swtpm)
#   - Disco /vm/Windows11.qcow2 (qcow2 dinâmico, VirtIO, cache=none)
#   - 2 CD-ROMs: ISO do Windows 11 + virtio-win.iso
#   - CPU host-passthrough, rede NAT 'default' com modelo virtio (bridge: etapa 60)
#   - Vídeo QXL temporário (a GPU real entra na etapa 50)
# Também aplica a regra AppArmor para o caminho customizado /vm.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

APPARMOR_LOCAL="/etc/apparmor.d/local/abstractions/libvirt-qemu"
REGRA_APPARMOR='/vm/** rwk,'
ISO_WINDOWS_DESTINO="/vm/iso/windows11.iso"
ISO_VIRTIO_DESTINO="/vm/iso/virtio-win.iso"
SUDO_NAO_INTERATIVO=0

VM_DIAGNOSTICO=""
VM_XML=""
QCOW2_DIAGNOSTICO=""
QCOW2_ESTADO=""
QCOW2_PAI=""
QCOW2_TAMANHO_BYTES=""
ISO_DIAGNOSTICO=""
APPARMOR_DIAGNOSTICO=""
APPARMOR_ESTADO=""

executar_sudo() {
    if [ "$SUDO_NAO_INTERATIVO" -eq 1 ]; then
        sudo -n "$@"
    else
        sudo "$@"
    fi
}

executar_como_qemu() {
    if [ "$SUDO_NAO_INTERATIVO" -eq 1 ]; then
        sudo -n -u libvirt-qemu "$@"
    else
        sudo -u libvirt-qemu "$@"
    fi
}

virsh_privilegiado() {
    executar_sudo env LC_ALL=C virsh --connect qemu:///system "$@"
}

virt_install_privilegiado() {
    executar_sudo env LC_ALL=C virt-install --connect qemu:///system "$@"
}

caminho_absoluto_normalizado() {
    local caminho="${1:-}"
    [[ "$caminho" == /* ]] || return 1
    [ "$caminho" != "/" ] || return 1
    case "$caminho" in
        *//*|*/./*|*/../*|*/.|*/..|*/)
            return 1
            ;;
    esac
}

tamanho_qcow2_em_bytes() {
    local valor="$1" numero sufixo multiplicador limite
    [[ "$valor" =~ ^([1-9][0-9]*)([KMGT])$ ]] || return 1
    numero="${BASH_REMATCH[1]}"
    sufixo="${BASH_REMATCH[2]}"
    case "$sufixo" in
        K) multiplicador=1024 ;;
        M) multiplicador=1048576 ;;
        G) multiplicador=1073741824 ;;
        T) multiplicador=1099511627776 ;;
    esac
    limite=$((9223372036854775807 / multiplicador))
    if [ "${#numero}" -gt "${#limite}" ] \
        || { [ "${#numero}" -eq "${#limite}" ] && [[ "$numero" > "$limite" ]]; }; then
        return 1
    fi
    printf '%s\n' "$((10#$numero * multiplicador))"
}

validar_parametros_qcow2() {
    QCOW2_DIAGNOSTICO=""
    QCOW2_TAMANHO_BYTES=""
    if ! caminho_absoluto_normalizado "${QCOW2_PATH:-}" \
        || [[ "${QCOW2_PATH:-}" != /vm/* ]]; then
        QCOW2_DIAGNOSTICO="QCOW2_PATH deve ser um caminho absoluto normalizado sob /vm."
        return 1
    fi
    if ! QCOW2_TAMANHO_BYTES="$(tamanho_qcow2_em_bytes "${QCOW2_TAMANHO:-}")"; then
        QCOW2_DIAGNOSTICO="QCOW2_TAMANHO deve usar inteiro positivo e sufixo K, M, G ou T sem exceder o limite suportado."
        return 1
    fi
}

validar_diretorio_vm() {
    local metadados dono grupo modo status
    VM_DIAGNOSTICO=""

    if executar_sudo test -L /vm; then
        VM_DIAGNOSTICO="/vm não pode ser um link simbólico."
        return 1
    fi
    if ! executar_sudo test -e /vm; then
        VM_DIAGNOSTICO="/vm não existe. Execute a etapa 21 antes."
        return 1
    fi
    if ! executar_sudo test -d /vm; then
        VM_DIAGNOSTICO="/vm deve ser um diretório real."
        return 1
    fi
    if executar_sudo mountpoint -q -- /vm; then
        VM_DIAGNOSTICO="/vm é um ponto de montagem inesperado; revise a preparação do diretório."
        return 1
    else
        status=$?
        if [ "$status" -ne 32 ]; then
            VM_DIAGNOSTICO="Não foi possível determinar se /vm é mountpoint (status $status)."
            return 1
        fi
    fi
    if ! metadados="$(executar_sudo stat -c '%U %G %a' -- /vm)"; then
        VM_DIAGNOSTICO="Não foi possível consultar dono, grupo e modo de /vm."
        return 1
    fi
    read -r dono grupo modo <<< "$metadados"
    if [ "$dono:$grupo:$modo" != "root:libvirt-qemu:770" ]; then
        VM_DIAGNOSTICO="/vm deve ser root:libvirt-qemu modo 0770; encontrado $dono:$grupo modo $modo."
        return 1
    fi
    if ! executar_como_qemu test -r /vm \
        || ! executar_como_qemu test -w /vm \
        || ! executar_como_qemu test -x /vm; then
        VM_DIAGNOSTICO="libvirt-qemu não possui acesso efetivo rwx a /vm."
        return 1
    fi
}

validar_pai_qcow2() {
    local relativo componente atual="/vm"
    local -a componentes=()
    QCOW2_PAI="${QCOW2_PATH%/*}"
    QCOW2_DIAGNOSTICO=""

    if [ "$QCOW2_PAI" != "/vm" ]; then
        relativo="${QCOW2_PAI#/vm/}"
        IFS='/' read -r -a componentes <<< "$relativo"
        for componente in "${componentes[@]}"; do
            atual="$atual/$componente"
            if executar_como_qemu test -L -- "$atual"; then
                QCOW2_DIAGNOSTICO="Diretório pai do QCOW2 não pode conter link simbólico: $atual"
                return 1
            fi
            if ! executar_como_qemu test -e -- "$atual"; then
                QCOW2_DIAGNOSTICO="Diretório pai do QCOW2 está ausente: $atual"
                return 1
            fi
            if ! executar_como_qemu test -d -- "$atual" \
                || ! executar_como_qemu test -x -- "$atual"; then
                QCOW2_DIAGNOSTICO="Diretório pai do QCOW2 é inválido ou inacessível para libvirt-qemu: $atual"
                return 1
            fi
        done
    fi
    if ! executar_como_qemu test -d -- "$QCOW2_PAI" \
        || ! executar_como_qemu test -x -- "$QCOW2_PAI"; then
        QCOW2_DIAGNOSTICO="Diretório pai do QCOW2 está inacessível para libvirt-qemu: $QCOW2_PAI"
        return 1
    fi
}

consultar_estado_qcow2() {
    local resultado status
    QCOW2_ESTADO=""
    validar_pai_qcow2 || { QCOW2_ESTADO="inacessivel"; return 1; }

    if resultado="$(executar_como_qemu python3 -c '
import os
import stat
import sys

try:
    metadados = os.lstat(sys.argv[1])
except FileNotFoundError:
    print("ausente")
except OSError as exc:
    detalhe = exc.strerror or exc.__class__.__name__
    print(f"errno={exc.errno}: {detalhe}", file=sys.stderr)
    raise SystemExit(1)
else:
    print("link" if stat.S_ISLNK(metadados.st_mode) else "existente")
' "$QCOW2_PATH" 2>&1)"; then
        case "$resultado" in
            ausente)
                QCOW2_ESTADO="ausente"
                QCOW2_DIAGNOSTICO="QCOW2 ausente: $QCOW2_PATH"
                ;;
            link)
                QCOW2_ESTADO="link"
                QCOW2_DIAGNOSTICO="QCOW2_PATH já existe como link simbólico: $QCOW2_PATH"
                ;;
            existente)
                QCOW2_ESTADO="existente"
                ;;
            *)
                QCOW2_ESTADO="inacessivel"
                QCOW2_DIAGNOSTICO="Resposta inesperada ao consultar o QCOW2 como libvirt-qemu: ${resultado:-vazia}."
                return 1
                ;;
        esac
        return 0
    else
        status=$?
        QCOW2_ESTADO="inacessivel"
        QCOW2_DIAGNOSTICO="Não foi possível consultar o QCOW2 como libvirt-qemu (${resultado:-status $status})."
        return 1
    fi
}

validar_qcow2_existente() {
    local metadados dono grupo info formato tamanho
    local regex_formato='"format"[[:space:]]*:[[:space:]]*"([^"]+)"'
    local regex_tamanho='"virtual-size"[[:space:]]*:[[:space:]]*([0-9]+)'

    QCOW2_DIAGNOSTICO=""
    consultar_estado_qcow2 || return 1
    case "$QCOW2_ESTADO" in
        ausente)
            QCOW2_DIAGNOSTICO="QCOW2 ausente: $QCOW2_PATH"
            return 1
            ;;
        link)
            return 1
            ;;
        existente)
            ;;
        *)
            QCOW2_DIAGNOSTICO="Estado desconhecido do QCOW2."
            return 1
            ;;
    esac

    if ! executar_como_qemu test -f -- "$QCOW2_PATH"; then
        QCOW2_DIAGNOSTICO="QCOW2_PATH existe, mas não é arquivo regular: $QCOW2_PATH"
        return 1
    fi
    if ! executar_como_qemu test -r -- "$QCOW2_PATH" \
        || ! executar_como_qemu test -w -- "$QCOW2_PATH"; then
        QCOW2_DIAGNOSTICO="QCOW2 existe, mas está inacessível para leitura/escrita por libvirt-qemu: $QCOW2_PATH"
        return 1
    fi
    if ! metadados="$(executar_como_qemu stat -c '%U %G' -- "$QCOW2_PATH")"; then
        QCOW2_DIAGNOSTICO="Não foi possível consultar dono e grupo do QCOW2 como libvirt-qemu."
        return 1
    fi
    read -r dono grupo <<< "$metadados"
    if [ "$dono:$grupo" != "libvirt-qemu:libvirt-qemu" ]; then
        QCOW2_DIAGNOSTICO="QCOW2 deve pertencer a libvirt-qemu:libvirt-qemu; encontrado $dono:$grupo."
        return 1
    fi
    if ! info="$(executar_como_qemu qemu-img info --output=json "$QCOW2_PATH" 2>/dev/null)"; then
        QCOW2_DIAGNOSTICO="QCOW2 existe, mas qemu-img não conseguiu consultá-lo como libvirt-qemu."
        return 1
    fi
    if [[ "$info" =~ $regex_formato ]]; then
        formato="${BASH_REMATCH[1]}"
    else
        QCOW2_DIAGNOSTICO="qemu-img não informou o formato do disco."
        return 1
    fi
    if [ "$formato" != "qcow2" ]; then
        QCOW2_DIAGNOSTICO="Formato do disco inválido: $formato (esperado qcow2)."
        return 1
    fi
    if [[ "$info" =~ $regex_tamanho ]]; then
        tamanho="${BASH_REMATCH[1]}"
    else
        QCOW2_DIAGNOSTICO="qemu-img não informou o virtual-size do disco."
        return 1
    fi
    if [ "$tamanho" != "$QCOW2_TAMANHO_BYTES" ]; then
        QCOW2_DIAGNOSTICO="virtual-size do QCOW2 é $tamanho bytes; esperado $QCOW2_TAMANHO_BYTES bytes ($QCOW2_TAMANHO)."
        return 1
    fi
}

criar_qcow2_atomico() (
    local temporario_dir="" temporario="" status

    limpar_qcow2_temporario() {
        [ -z "$temporario" ] || executar_como_qemu rm -f -- "$temporario" >/dev/null 2>&1 || true
        [ -z "$temporario_dir" ] || executar_como_qemu rmdir -- "$temporario_dir" >/dev/null 2>&1 || true
    }
    trap 'status=$?; trap - EXIT; limpar_qcow2_temporario; exit "$status"' EXIT
    trap 'exit 1' HUP INT TERM

    consultar_estado_qcow2 || return 1
    [ "$QCOW2_ESTADO" = "ausente" ] || {
        erro "Recusando criar o QCOW2: o caminho não está ausente ($QCOW2_ESTADO)."
        return 1
    }
    executar_como_qemu test -w -- "$QCOW2_PAI" || {
        erro "libvirt-qemu não pode criar arquivos em $QCOW2_PAI."
        return 1
    }

    temporario_dir="$(executar_como_qemu mktemp -d -- "$QCOW2_PAI/.qcow2-create.XXXXXXXX")" \
        || { erro "Falha ao reservar diretório temporário para o QCOW2."; return 1; }
    temporario="$temporario_dir/disco.qcow2"
    if executar_como_qemu test -e -- "$temporario" \
        || executar_como_qemu test -L -- "$temporario"; then
        erro "Caminho temporário inesperadamente existente; qemu-img não será executado."
        return 1
    fi

    executar_como_qemu qemu-img create -f qcow2 "$temporario" "$QCOW2_TAMANHO" \
        || { erro "qemu-img não conseguiu criar o QCOW2 temporário."; return 1; }
    if ! executar_como_qemu ln -T -- "$temporario" "$QCOW2_PATH"; then
        erro "QCOW2_PATH apareceu durante a criação; o conteúdo existente foi preservado."
        return 1
    fi
    executar_como_qemu rm -- "$temporario" \
        || { erro "QCOW2 instalado, mas o arquivo temporário não pôde ser removido."; return 1; }
    temporario=""
    executar_como_qemu rmdir -- "$temporario_dir" \
        || { erro "QCOW2 instalado, mas o diretório temporário não pôde ser removido."; return 1; }
    temporario_dir=""
)

validar_iso_estrutural() {
    local caminho="$1" descricao="$2"
    ISO_DIAGNOSTICO=""
    if [[ "$caminho" != /* ]]; then
        ISO_DIAGNOSTICO="$descricao deve usar caminho absoluto."
        return 1
    fi
    if executar_sudo test -L -- "$caminho"; then
        ISO_DIAGNOSTICO="$descricao não pode ser link simbólico: $caminho"
        return 1
    fi
    if ! executar_sudo test -e -- "$caminho"; then
        ISO_DIAGNOSTICO="$descricao não existe ou está inacessível: $caminho"
        return 1
    fi
    if ! executar_sudo test -f -- "$caminho"; then
        ISO_DIAGNOSTICO="$descricao deve ser arquivo regular: $caminho"
        return 1
    fi
}

iso_legivel_pelo_qemu() {
    executar_como_qemu test -r -- "$1"
}

copiar_iso_sem_sobrescrever() (
    local origem="$1" destino="$2" diretorio="/vm/iso"
    local temporario="" status_cmp status

    limpar_iso_temporaria() {
        [ -z "$temporario" ] || executar_sudo rm -f -- "$temporario" >/dev/null 2>&1 || true
    }
    trap 'status=$?; trap - EXIT; limpar_iso_temporaria; exit "$status"' EXIT
    trap 'exit 1' HUP INT TERM

    if executar_sudo test -L -- "$diretorio"; then
        erro "$diretorio não pode ser link simbólico."
        return 1
    fi
    if executar_sudo test -e -- "$diretorio"; then
        executar_sudo test -d -- "$diretorio" \
            || { erro "$diretorio existe, mas não é diretório."; return 1; }
    elif ! executar_sudo install -d -o root -g libvirt-qemu -m 0750 -- "$diretorio"; then
        erro "Não foi possível criar $diretorio de forma segura."
        return 1
    fi
    executar_como_qemu test -x -- "$diretorio" \
        || { erro "$diretorio não é acessível por libvirt-qemu."; return 1; }

    if executar_sudo test -L -- "$destino"; then
        erro "Destino de ISO não pode ser link simbólico: $destino"
        return 1
    fi
    if executar_sudo test -e -- "$destino"; then
        executar_sudo test -f -- "$destino" \
            || { erro "Destino de ISO existe, mas não é arquivo regular: $destino"; return 1; }
        if executar_sudo cmp -s -- "$origem" "$destino"; then
            info "Destino já contém a mesma ISO; conteúdo preservado: $destino"
        else
            status_cmp=$?
            if [ "$status_cmp" -eq 1 ]; then
                erro "Destino já contém conteúdo divergente; nada foi sobrescrito: $destino"
            else
                erro "Não foi possível comparar a ISO com o destino: $destino"
            fi
            return 1
        fi
        executar_sudo chown root:libvirt-qemu -- "$destino" \
            || { erro "Não foi possível ajustar o grupo de $destino."; return 1; }
        executar_sudo chmod 0640 -- "$destino" \
            || { erro "Não foi possível ajustar o modo de $destino."; return 1; }
        return 0
    fi

    temporario="$(executar_sudo mktemp -- "$diretorio/.iso-copy.XXXXXXXX")" \
        || { erro "Falha ao criar arquivo temporário em $diretorio."; return 1; }
    executar_sudo cp -- "$origem" "$temporario" \
        || { erro "Falha ao copiar a ISO para o arquivo temporário."; return 1; }
    if ! executar_sudo cmp -s -- "$origem" "$temporario"; then
        erro "A cópia temporária da ISO diverge da origem; destino não instalado."
        return 1
    fi
    executar_sudo chown root:libvirt-qemu -- "$temporario" \
        || { erro "Não foi possível ajustar o grupo da cópia temporária."; return 1; }
    executar_sudo chmod 0640 -- "$temporario" \
        || { erro "Não foi possível ajustar o modo da cópia temporária."; return 1; }
    if ! executar_sudo ln -- "$temporario" "$destino"; then
        erro "O destino surgiu durante a cópia; nenhum conteúdo foi sobrescrito: $destino"
        return 1
    fi
    executar_sudo rm -- "$temporario" \
        || { erro "ISO instalada, mas o arquivo temporário não pôde ser removido."; return 1; }
    temporario=""
)

solicitar_iso() {
    local variavel="$1" descricao="$2" orientacao="$3" caminho
    caminho="${!variavel:-}"
    if [ -n "$caminho" ] && validar_iso_estrutural "$caminho" "$descricao"; then
        return 0
    fi
    [ -z "$caminho" ] || aviso "$ISO_DIAGNOSTICO"
    info "$orientacao"
    caminho="$(perguntar "Caminho da $descricao")"
    salvar_conf "$variavel" "$caminho"
    validar_iso_estrutural "$caminho" "$descricao" || falhar "$ISO_DIAGNOSTICO"
}

preparar_iso_para_qemu() {
    local variavel="$1" descricao="$2" destino="$3" caminho
    local oferecer_copia=0
    caminho="${!variavel}"

    validar_iso_estrutural "$caminho" "$descricao" || falhar "$ISO_DIAGNOSTICO"
    if [[ "$caminho" == /home/* ]]; then
        aviso "$caminho está dentro de /home; use /vm/iso para evitar bloqueio de travessia pelo QEMU."
        oferecer_copia=1
    elif ! iso_legivel_pelo_qemu "$caminho"; then
        aviso "$descricao não está legível para libvirt-qemu: $caminho"
        oferecer_copia=1
    fi

    if [ "$oferecer_copia" -eq 1 ] && confirmar "Copiar para $destino (recomendado)?"; then
        copiar_iso_sem_sobrescrever "$caminho" "$destino" \
            || falhar "Não foi possível instalar $descricao em $destino."
        salvar_conf "$variavel" "$destino"
        caminho="$destino"
    fi
    validar_iso_estrutural "$caminho" "$descricao" || falhar "$ISO_DIAGNOSTICO"
    iso_legivel_pelo_qemu "$caminho" \
        || falhar "$descricao não é legível por libvirt-qemu; copie-a para o destino fixo $destino."
}

validar_arquivo_apparmor() {
    local metadados dono grupo modo
    APPARMOR_DIAGNOSTICO=""
    APPARMOR_ESTADO=""

    if executar_sudo test -L -- "$APPARMOR_LOCAL"; then
        APPARMOR_DIAGNOSTICO="$APPARMOR_LOCAL não pode ser link simbólico."
        return 1
    fi
    if ! executar_sudo test -e -- "$APPARMOR_LOCAL"; then
        APPARMOR_ESTADO="ausente"
        return 0
    fi
    if ! executar_sudo test -f -- "$APPARMOR_LOCAL"; then
        APPARMOR_DIAGNOSTICO="$APPARMOR_LOCAL deve ser arquivo regular."
        return 1
    fi
    if ! metadados="$(executar_sudo stat -c '%u %g %a' -- "$APPARMOR_LOCAL")"; then
        APPARMOR_DIAGNOSTICO="Não foi possível consultar os metadados de $APPARMOR_LOCAL."
        return 1
    fi
    read -r dono grupo modo <<< "$metadados"
    if [ "$dono:$grupo" != "0:0" ]; then
        APPARMOR_DIAGNOSTICO="$APPARMOR_LOCAL deve pertencer a root:root."
        return 1
    fi
    if ! [[ "$modo" =~ ^[0-7]{3,4}$ ]] || [ $((8#$modo & 8#22)) -ne 0 ]; then
        APPARMOR_DIAGNOSTICO="$APPARMOR_LOCAL não pode ser gravável por grupo ou outros (modo atual: $modo)."
        return 1
    fi
    APPARMOR_ESTADO="existente"
}

regra_apparmor_presente() {
    [ "$APPARMOR_ESTADO" = "existente" ] \
        && executar_sudo grep -Fxq -- "$REGRA_APPARMOR" "$APPARMOR_LOCAL"
}

instalar_regra_apparmor() (
    local diretorio nome novo="" backup="" original=0 status
    local publicado=0 reload_confirmado=0
    diretorio="${APPARMOR_LOCAL%/*}"
    nome="${APPARMOR_LOCAL##*/}"

    restaurar_apparmor_publicado() {
        local reload_status=0

        [ "$publicado" -eq 1 ] && [ "$reload_confirmado" -eq 0 ] || return 0
        if [ "$original" -eq 1 ]; then
            if [ -z "$backup" ]; then
                erro "Não há backup disponível para restaurar $APPARMOR_LOCAL."
                return 1
            fi
            if executar_sudo mv -fT -- "$backup" "$APPARMOR_LOCAL"; then
                backup=""
                publicado=0
            else
                erro "Falha ao restaurar $APPARMOR_LOCAL; backup preservado em $backup."
                return 1
            fi
        elif executar_sudo rm -f -- "$APPARMOR_LOCAL"; then
            publicado=0
        else
            erro "Falha ao remover a regra AppArmor publicada sem arquivo anterior."
            return 1
        fi

        if executar_sudo systemctl reload apparmor; then
            info "Arquivo e política AppArmor anteriores restaurados."
        else
            erro "Arquivo anterior restaurado, mas o reload da política restaurada falhou."
            reload_status=1
        fi
        return "$reload_status"
    }

    finalizar_apparmor() {
        local saida="$1" restauracao_status=0
        trap - EXIT
        trap '' HUP INT TERM

        restaurar_apparmor_publicado || restauracao_status=$?
        [ -z "$novo" ] || executar_sudo rm -f -- "$novo" >/dev/null 2>&1 || true
        if [ -n "$backup" ]; then
            if [ "$publicado" -eq 1 ] && [ "$reload_confirmado" -eq 0 ]; then
                aviso "Backup AppArmor preservado após falha de restauração: $backup"
            else
                executar_sudo rm -f -- "$backup" >/dev/null 2>&1 || true
            fi
        fi
        if [ "$saida" -eq 0 ] && [ "$restauracao_status" -ne 0 ]; then
            saida="$restauracao_status"
        fi
        exit "$saida"
    }

    trap 'status=$?; finalizar_apparmor "$status"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    executar_sudo mkdir -p -- "$diretorio" \
        || { erro "Não foi possível preparar o diretório local do AppArmor."; return 1; }
    validar_arquivo_apparmor || { erro "$APPARMOR_DIAGNOSTICO"; return 1; }
    if regra_apparmor_presente; then
        executar_sudo systemctl reload apparmor \
            || { erro "Reload obrigatório do AppArmor falhou."; return 1; }
        info "Regra AppArmor já presente e política recarregada."
        return 0
    fi

    if [ "$APPARMOR_ESTADO" = "existente" ]; then
        original=1
    fi
    novo="$(executar_sudo mktemp -- "$diretorio/.${nome}.new.XXXXXXXX")" \
        || { erro "Não foi possível criar arquivo temporário para AppArmor."; return 1; }
    if [ "$original" -eq 1 ]; then
        backup="$(executar_sudo mktemp -- "$diretorio/.${nome}.bak.XXXXXXXX")" \
            || { erro "Não foi possível reservar backup do AppArmor."; return 1; }
        executar_sudo cp --preserve=all -- "$APPARMOR_LOCAL" "$backup" \
            || { erro "Não foi possível criar o backup do AppArmor."; return 1; }
        executar_sudo cp -- "$APPARMOR_LOCAL" "$novo" \
            || { erro "Não foi possível preparar a nova regra AppArmor."; return 1; }
    fi
    printf '\n%s\n' "$REGRA_APPARMOR" | executar_sudo tee -a "$novo" >/dev/null \
        || { erro "Não foi possível gravar a regra AppArmor temporária."; return 1; }
    executar_sudo chown root:root -- "$novo" \
        || { erro "Não foi possível definir root:root na regra AppArmor temporária."; return 1; }
    executar_sudo chmod 0644 -- "$novo" \
        || { erro "Não foi possível proteger a regra AppArmor temporária."; return 1; }
    publicado=1
    if ! executar_sudo mv -fT -- "$novo" "$APPARMOR_LOCAL"; then
        publicado=0
        erro "Não foi possível instalar atomicamente a regra AppArmor."
        return 1
    fi
    novo=""

    if executar_sudo systemctl reload apparmor; then
        reload_confirmado=1
        if [ -n "$backup" ]; then
            if executar_sudo rm -f -- "$backup"; then
                backup=""
            else
                aviso "Regra ativa, mas o backup temporário foi preservado: $backup"
                backup=""
            fi
        fi
        ok "Regra '$REGRA_APPARMOR' instalada atomicamente e AppArmor recarregado."
        return 0
    fi

    erro "Reload do AppArmor falhou; o arquivo anterior será restaurado."
    return 1
)

consultar_vm_definida() {
    local lista nome
    VM_DIAGNOSTICO=""
    VM_XML=""
    if ! lista="$(virsh_privilegiado list --all --name 2>/dev/null)"; then
        VM_DIAGNOSTICO="Não foi possível consultar as VMs no libvirt com acesso privilegiado."
        return 1
    fi
    while IFS= read -r nome; do
        if [ "$nome" = "$VM_NAME" ]; then
            return 0
        fi
    done <<< "$lista"
    return 2
}

obter_xml_vm() {
    local modo="${1:-inativo}"
    local -a opcoes=()
    VM_XML=""
    case "$modo" in
        inativo)
            opcoes=(--inactive)
            ;;
        ativo)
            ;;
        *)
            VM_DIAGNOSTICO="Modo interno inválido ao obter XML da VM: '$modo'."
            return 1
            ;;
    esac
    if ! VM_XML="$(virsh_privilegiado dumpxml "${opcoes[@]}" "$VM_NAME" 2>/dev/null)"; then
        VM_DIAGNOSTICO="VM '$VM_NAME' existe, mas não foi possível obter seu XML $modo."
        return 1
    fi
}

validar_xml_vm() {
    local resultado status
    if resultado="$(printf '%s' "$VM_XML" | python3 -c '
import sys
import xml.etree.ElementTree as ET

qcow2, iso_windows, iso_virtio, vm_ram_mb, vm_vcpus = sys.argv[1:6]
erros = []
try:
    memoria_esperada = int(vm_ram_mb) * 1024 * 1024
    vcpus_esperadas = int(vm_vcpus)
    if memoria_esperada <= 0 or vcpus_esperadas <= 0:
        raise ValueError
except ValueError:
    print("VM_RAM_MB e VM_VCPUS devem ser inteiros positivos")
    raise SystemExit(1)
try:
    root = ET.fromstring(sys.stdin.read())
except Exception as exc:
    print(f"XML inválido: {exc}")
    raise SystemExit(1)

os_node = root.find("./os")
type_node = root.find("./os/type")
machine = "" if type_node is None else type_node.get("machine", "")
if machine not in ("q35", "pc-q35") and not machine.startswith("pc-q35-"):
    machine_label = machine or "ausente"
    erros.append(f"chipset não é Q35 ({machine_label})")
loader = None if os_node is None else os_node.find("loader")
firmware = "" if os_node is None else os_node.get("firmware", "")
loader_pflash = loader is not None and loader.get("type") == "pflash"
if firmware != "efi" and not loader_pflash:
    erros.append("firmware UEFI/pflash ausente")
if loader is not None and loader.get("type") != "pflash":
    erros.append("loader UEFI não usa pflash")

nvrams = [] if os_node is None else os_node.findall("nvram")
def nvram_tem_destino(nvram):
    if (nvram.text or "").strip():
        return True
    source = nvram.find("source")
    return source is not None and any(source.get(attr) for attr in ("file", "dev", "name", "volume"))

if len(nvrams) != 1 or not nvram_tem_destino(nvrams[0]):
    erros.append("NVRAM UEFI deve possuir exatamente um destino persistente")

fatores_memoria = {
    "b": 1,
    "bytes": 1,
    "KB": 1000,
    "k": 1024,
    "KiB": 1024,
    "MB": 1000 ** 2,
    "M": 1024 ** 2,
    "MiB": 1024 ** 2,
    "GB": 1000 ** 3,
    "G": 1024 ** 3,
    "GiB": 1024 ** 3,
    "TB": 1000 ** 4,
    "T": 1024 ** 4,
    "TiB": 1024 ** 4,
}
def memoria_em_bytes(node):
    valor = int((node.text or "").strip())
    unidade = node.get("unit", "KiB")
    if valor < 0 or unidade not in fatores_memoria:
        raise ValueError
    return valor * fatores_memoria[unidade]

def validar_memoria(nodes, label, obrigatoria):
    if len(nodes) != 1:
        if obrigatoria or nodes:
            erros.append(f"{label} deve aparecer exatamente uma vez")
        return
    try:
        valor = memoria_em_bytes(nodes[0])
    except (TypeError, ValueError):
        erros.append(f"{label} possui valor ou unidade inválida")
        return
    if valor != memoria_esperada:
        erros.append(f"{label} diverge de VM_RAM_MB ({vm_ram_mb} MiB)")

validar_memoria(root.findall("./memory"), "memória da VM", True)
validar_memoria(root.findall("./currentMemory"), "memória atual da VM", False)

vcpus = root.findall("./vcpu")
if len(vcpus) != 1:
    erros.append("vcpu deve aparecer exatamente uma vez")
else:
    try:
        limite_vcpus = int((vcpus[0].text or "").strip())
        atuais_vcpus = int(vcpus[0].get("current", str(limite_vcpus)))
    except ValueError:
        erros.append("vcpu possui valor inválido")
    else:
        if limite_vcpus != vcpus_esperadas or atuais_vcpus != vcpus_esperadas:
            erros.append(f"vcpu diverge de VM_VCPUS ({vm_vcpus})")

tpms = root.findall("./devices/tpm")
if not any(t.get("model") == "tpm-crb" and
           (b := t.find("backend")) is not None and
           b.get("type") == "emulator" and b.get("version") == "2.0"
           for t in tpms):
    erros.append("TPM CRB emulado versão 2.0 ausente")

cpu = root.find("./cpu")
if cpu is None or cpu.get("mode") != "host-passthrough":
    erros.append("CPU host-passthrough ausente")

disks = root.findall("./devices/disk")
data_disks = [d for d in disks if d.get("device") == "disk"]
cdroms = [d for d in disks if d.get("device") == "cdrom"]
outros = [d for d in disks if d.get("device") not in ("disk", "cdrom")]
armazenamento_alternativo = (
    root.findall("./devices/filesystem")
    + root.findall("./devices/hostdev")
    + root.findall("./devices/redirdev")
)

if len(data_disks) != 1:
    erros.append(f"deve existir exatamente um disco de dados durante a instalação (encontrados {len(data_disks)})")
if len(cdroms) != 2:
    erros.append(f"devem existir exatamente dois CD-ROMs durante a instalação (encontrados {len(cdroms)})")
if outros or len(disks) != 3:
    erros.append("o conjunto de armazenamento da instalação deve conter somente o QCOW2 e as duas ISOs")
if armazenamento_alternativo:
    erros.append("hostdev, filesystem e redirecionamento USB são proibidos durante a instalação")

def fonte_arquivo_exata(disk, path, label):
    sources = disk.findall("source")
    if len(sources) != 1:
        erros.append(f"{label} deve possuir exatamente uma source")
        return False
    source = sources[0]
    alternativos = [attr for attr in ("dev", "name", "volume", "protocol") if source.get(attr)]
    if source.get("file") != path or alternativos:
        erros.append(f"{label} deve usar somente source file={path}")
        return False
    return True

if len(data_disks) == 1:
    sistema = data_disks[0]
    if sistema.get("type") != "file":
        erros.append("disco do sistema deve ser file/device=disk")
    fonte_arquivo_exata(sistema, qcow2, "disco do sistema")
    drivers = sistema.findall("driver")
    targets = sistema.findall("target")
    if len(drivers) != 1 or drivers[0].get("name") != "qemu" or drivers[0].get("type") != "qcow2" or drivers[0].get("cache") != "none":
        erros.append("driver do QCOW2 deve ser único e usar qemu/qcow2 com cache=none")
    if len(targets) != 1 or targets[0].get("bus") != "virtio":
        erros.append("disco do sistema deve possuir um único target no barramento virtio")

for path, label in ((iso_windows, "ISO do Windows"), (iso_virtio, "ISO VirtIO")):
    encontrados = [d for d in cdroms if len(d.findall("source")) == 1 and d.find("source").get("file") == path]
    if len(encontrados) != 1:
        erros.append(f"{label} deve ser referenciada exatamente uma vez por {path}")
        continue
    cdrom = encontrados[0]
    if cdrom.get("type") != "file" or not fonte_arquivo_exata(cdrom, path, label):
        erros.append(f"{label} deve ser file/device=cdrom")
    drivers = cdrom.findall("driver")
    targets = cdrom.findall("target")
    if len(drivers) != 1 or drivers[0].get("name") != "qemu" or drivers[0].get("type") != "raw":
        erros.append(f"{label} deve possuir um único driver qemu/raw")
    if len(targets) != 1 or targets[0].get("bus") != "sata":
        erros.append(f"{label} deve possuir um único target no barramento sata")
    if len(cdrom.findall("readonly")) != 1:
        erros.append(f"{label} deve possuir exatamente uma marca readonly")

interfaces = root.findall("./devices/interface")
if len(interfaces) != 1:
    erros.append(f"deve existir exatamente uma interface de rede (encontradas {len(interfaces)})")
else:
    interface = interfaces[0]
    models = interface.findall("model")
    if len(models) != 1 or models[0].get("type") != "virtio":
        erros.append("a única interface de rede deve usar modelo virtio")
    sources = interface.findall("source")
    if len(sources) != 1:
        erros.append("a única interface de rede deve possuir exatamente uma source")
    else:
        source = sources[0]
        tipo = interface.get("type")
        rede_default = tipo == "network" and source.get("network") == "default" and source.get("bridge") is None
        bridge_br0 = tipo == "bridge" and source.get("bridge") == "br0" and source.get("network") is None
        if not (rede_default or bridge_br0):
            erros.append("source da interface deve ser network=default ou bridge=br0")

if erros:
    print("; ".join(erros))
    raise SystemExit(1)
' "$QCOW2_PATH" "$ISO_WINDOWS" "$ISO_VIRTIO" "${VM_RAM_MB:-}" "${VM_VCPUS:-}" 2>&1)"; then
        return 0
    else
        status=$?
        VM_DIAGNOSTICO="XML da VM divergente: ${resultado:-validação falhou com status $status}."
        return 1
    fi
}

consultar_estado_vm_definida() {
    virsh_privilegiado domstate "$VM_NAME" 2>/dev/null
}

validar_vm_definida() {
    local estado
    obter_xml_vm inativo || return 1
    validar_xml_vm || return 1
    if ! estado="$(consultar_estado_vm_definida)"; then
        VM_DIAGNOSTICO="Não foi possível consultar o estado da VM '$VM_NAME'."
        return 1
    fi
    case "$estado" in
        "shut off")
            return 0
            ;;
        running|paused)
            obter_xml_vm ativo || return 1
            validar_xml_vm || return 1
            ;;
        *)
            VM_DIAGNOSTICO="Estado '$estado' não permite validar com segurança a topologia de instalação de '$VM_NAME'."
            return 1
            ;;
    esac
}

falhar_inicio_vm() {
    local motivo="$1" estado="" rollback=""
    if ! estado="$(consultar_estado_vm_definida)" || [ "$estado" != "shut off" ]; then
        if virsh_privilegiado destroy "$VM_NAME" >/dev/null 2>&1; then
            rollback=" A VM foi interrompida e permaneceu definida para diagnóstico."
        else
            rollback=" ATENÇÃO: não foi possível confirmar a interrupção da VM; desligue-a imediatamente."
        fi
    fi
    VM_DIAGNOSTICO="$motivo$rollback"
    return 1
}

iniciar_vm_definida_validada() {
    local estado diagnostico
    validar_vm_definida || return 1
    estado="$(consultar_estado_vm_definida)" \
        || { VM_DIAGNOSTICO="Não foi possível confirmar o estado pré-start de '$VM_NAME'."; return 1; }
    [ "$estado" = "shut off" ] \
        || { VM_DIAGNOSTICO="A VM deve estar exatamente 'shut off' antes do start controlado; encontrado '$estado'."; return 1; }

    if ! virsh_privilegiado start "$VM_NAME" --paused >/dev/null; then
        falhar_inicio_vm "Não foi possível iniciar '$VM_NAME' pausada."
        return 1
    fi
    if ! estado="$(consultar_estado_vm_definida)" || [ "$estado" != "paused" ]; then
        falhar_inicio_vm "A VM não confirmou o estado 'paused' após o start seguro; encontrado '${estado:-indisponível}'."
        return 1
    fi
    if ! validar_vm_definida; then
        diagnostico="$VM_DIAGNOSTICO"
        falhar_inicio_vm "A topologia ativa divergiu antes do primeiro ciclo de CPU: $diagnostico"
        return 1
    fi
    if ! virsh_privilegiado resume "$VM_NAME" >/dev/null; then
        falhar_inicio_vm "A topologia foi validada, mas não foi possível retomar '$VM_NAME'."
        return 1
    fi
    if ! estado="$(consultar_estado_vm_definida)" || [ "$estado" != "running" ]; then
        falhar_inicio_vm "A VM não confirmou o estado 'running' após resume; encontrado '${estado:-indisponível}'."
        return 1
    fi
    if ! validar_vm_definida; then
        diagnostico="$VM_DIAGNOSTICO"
        falhar_inicio_vm "A topologia ativa mudou imediatamente após resume: $diagnostico"
        return 1
    fi
}

definir_vm_sem_iniciar() (
    local temporario=""
    umask 077
    limpar_xml_temporario() {
        [ -z "$temporario" ] || rm -f -- "$temporario" "$temporario.sanitized" >/dev/null 2>&1 || true
    }
    trap 'status=$?; trap - EXIT; limpar_xml_temporario; exit "$status"' EXIT
    trap 'exit 1' HUP INT TERM

    temporario="$(mktemp -- /tmp/vm-definition.XXXXXXXX.xml)" \
        || { erro "Não foi possível reservar o XML temporário da VM."; exit 1; }
    virt_install_privilegiado "$@" --print-xml > "$temporario" \
        || { erro "virt-install não conseguiu gerar o XML candidato sem iniciar a VM."; exit 1; }
    python3 -c '
import os
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
tree = ET.parse(path)
root = tree.getroot()
devices = root.find("./devices")
if devices is None:
    raise SystemExit(2)
for redirdev in list(devices.findall("redirdev")):
    devices.remove(redirdev)
sanizado = path + ".sanitized"
tree.write(sanizado, encoding="utf-8", xml_declaration=True)
os.replace(sanizado, path)
' "$temporario" \
        || { erro "virt-install gerou um XML inválido ou não foi possível remover o redirecionamento USB."; exit 1; }
    virsh_privilegiado define "$temporario" >/dev/null \
        || { erro "libvirt recusou a definição candidata da VM."; exit 1; }
)

verificar() {
    local comandos_ok=1 parametros_ok=0 isos_ok=0 consulta_status
    local comando
    SUDO_NAO_INTERATIVO=1

    for comando in sudo qemu-img virsh python3 mountpoint stat grep; do
        if ! command -v "$comando" >/dev/null 2>&1; then
            v_falta "Comando '$comando' ausente."
            comandos_ok=0
        fi
    done
    [ "$comandos_ok" -eq 1 ] || v_fim
    if ! sudo -n true >/dev/null 2>&1; then
        v_falta "Acesso sudo não interativo indisponível; verificação privilegiada não executada."
        v_fim
    fi

    if [ -n "${VM_NAME:-}" ]; then
        v_ok "VM_NAME definido."
    else
        v_falta "VM_NAME não definido (etapa 02)."
    fi
    if validar_parametros_qcow2; then
        v_ok "QCOW2_PATH absoluto sob /vm e tamanho configurado válido."
        parametros_ok=1
    else
        v_falta "$QCOW2_DIAGNOSTICO"
    fi
    if validar_diretorio_vm; then
        v_ok "/vm é diretório real, não mountpoint e root:libvirt-qemu 0770."
    else
        v_falta "$VM_DIAGNOSTICO"
    fi

    if [ -n "${ISO_WINDOWS:-}" ] && [ -n "${ISO_VIRTIO:-}" ] \
        && [ "$ISO_WINDOWS" != "$ISO_VIRTIO" ] \
        && validar_iso_estrutural "$ISO_WINDOWS" "ISO do Windows" \
        && iso_legivel_pelo_qemu "$ISO_WINDOWS" \
        && validar_iso_estrutural "$ISO_VIRTIO" "ISO VirtIO" \
        && iso_legivel_pelo_qemu "$ISO_VIRTIO"; then
        v_ok "As duas ISOs são absolutas, regulares, não symlink e legíveis por libvirt-qemu."
        isos_ok=1
    else
        v_falta "ISOs inválidas, iguais ou inacessíveis para libvirt-qemu${ISO_DIAGNOSTICO:+: $ISO_DIAGNOSTICO}."
    fi

    if [ "$parametros_ok" -eq 1 ]; then
        if validar_qcow2_existente; then
            v_ok "QCOW2 regular, não symlink, libvirt-qemu:libvirt-qemu, formato e virtual-size corretos."
        else
            v_falta "$QCOW2_DIAGNOSTICO"
        fi
    fi

    if validar_arquivo_apparmor; then
        if regra_apparmor_presente; then
            v_ok "Arquivo AppArmor root:root regular, seguro e com regra exata para /vm."
        elif [ "$APPARMOR_ESTADO" = "ausente" ]; then
            v_falta "$APPARMOR_LOCAL está ausente."
        else
            v_falta "Regra AppArmor exata para /vm está ausente."
        fi
    else
        v_falta "$APPARMOR_DIAGNOSTICO"
    fi

    if [ -z "${VM_NAME:-}" ]; then
        v_fim
    fi
    if consultar_vm_definida; then
        if [ "$parametros_ok" -eq 1 ] && [ "$isos_ok" -eq 1 ] \
            && validar_vm_definida; then
            v_ok "VM '$VM_NAME' referencia somente os recursos de instalação exatos nos XMLs ativo/inativo e usa Q35, UEFI, TPM2 e drivers esperados."
        else
            v_falta "${VM_DIAGNOSTICO:-Não foi possível validar integralmente o XML da VM.}"
        fi
    else
        consulta_status=$?
        if [ "$consulta_status" -eq 2 ]; then
            v_falta "VM '$VM_NAME' não definida."
        else
            v_falta "$VM_DIAGNOSTICO"
        fi
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

exigir_nao_root
exigir_sudo
exigir_comando virt-install qemu-img virsh python3 mountpoint stat mktemp cmp
exigir_conf VM_NAME QCOW2_PATH QCOW2_TAMANHO VM_RAM_MB VM_VCPUS
validar_parametros_qcow2 || falhar "$QCOW2_DIAGNOSTICO"
validar_diretorio_vm || falhar "$VM_DIAGNOSTICO"

titulo "Capítulo 17: Criação da VM '$VM_NAME'"

# ----------------------------------------------------------------------------
# 1. ISOs (sempre de canais oficiais; o manual não fornece links de propósito)
# ----------------------------------------------------------------------------
titulo "1/5 ISOs de instalação"
solicitar_iso ISO_WINDOWS "ISO do Windows 11" \
    "Baixe a ISO do Windows 11 em microsoft.com (nunca de espelhos de terceiros)."
solicitar_iso ISO_VIRTIO "virtio-win.iso" \
    "Baixe a virtio-win.iso do projeto oficial virtio-win (QEMU/Red Hat)."
[ "$ISO_WINDOWS" != "$ISO_VIRTIO" ] \
    || falhar "ISO_WINDOWS e ISO_VIRTIO devem apontar para arquivos distintos."

if consultar_vm_definida; then
    validar_iso_estrutural "$ISO_WINDOWS" "ISO do Windows" || falhar "$ISO_DIAGNOSTICO"
    validar_iso_estrutural "$ISO_VIRTIO" "ISO VirtIO" || falhar "$ISO_DIAGNOSTICO"
    iso_legivel_pelo_qemu "$ISO_WINDOWS" \
        || falhar "A VM existente referencia uma ISO do Windows inacessível para libvirt-qemu: $ISO_WINDOWS"
    iso_legivel_pelo_qemu "$ISO_VIRTIO" \
        || falhar "A VM existente referencia uma ISO VirtIO inacessível para libvirt-qemu: $ISO_VIRTIO"
    validar_qcow2_existente || falhar "$QCOW2_DIAGNOSTICO"
    validar_vm_definida || falhar "$VM_DIAGNOSTICO"
    titulo "2/5 AppArmor"
    instalar_regra_apparmor || falhar "AppArmor não foi aplicado; a VM existente não será alterada."
    ok "VM '$VM_NAME' já existe e está conforme; reexecução concluída sem redefini-la."
    exit 0
else
    consulta_status=$?
    [ "$consulta_status" -eq 2 ] || falhar "$VM_DIAGNOSTICO"
fi

preparar_iso_para_qemu ISO_WINDOWS "ISO do Windows" "$ISO_WINDOWS_DESTINO"
preparar_iso_para_qemu ISO_VIRTIO "ISO VirtIO" "$ISO_VIRTIO_DESTINO"

# ----------------------------------------------------------------------------
# 2. Regra AppArmor para o caminho customizado /vm
# ----------------------------------------------------------------------------
titulo "2/5 AppArmor"
instalar_regra_apparmor || falhar "Não foi possível aplicar a regra AppArmor de forma segura."

# ----------------------------------------------------------------------------
# 3. Disco QCOW2 (dinâmico, criado já com o dono correto)
# ----------------------------------------------------------------------------
titulo "3/5 Disco do sistema"
consultar_estado_qcow2 || falhar "$QCOW2_DIAGNOSTICO"
case "$QCOW2_ESTADO" in
    ausente)
        criar_qcow2_atomico || falhar "Falha na criação atômica do QCOW2."
        ;;
    existente)
        info "Disco já existe e será validado antes do uso: $QCOW2_PATH"
        ;;
    link|inacessivel)
        falhar "$QCOW2_DIAGNOSTICO"
        ;;
    *)
        falhar "Estado inesperado do QCOW2: $QCOW2_ESTADO"
        ;;
esac
validar_qcow2_existente || falhar "$QCOW2_DIAGNOSTICO"
executar_como_qemu qemu-img info "$QCOW2_PATH" | sed 's/^/  /'

# ----------------------------------------------------------------------------
# 4. Rede default do libvirt ativa (NAT, suficiente até a etapa 60)
# ----------------------------------------------------------------------------
titulo "4/5 Rede NAT default"
if ! $VIRSH net-info default 2>/dev/null | grep -q 'Active:.*yes'; then
    $VIRSH net-start default || true
    $VIRSH net-autostart default || true
fi
$VIRSH net-info default | sed 's/^/  /' || aviso "Rede 'default' indisponível; verifique o libvirt."

# ----------------------------------------------------------------------------
# 5. Definição da VM via virt-install
# ----------------------------------------------------------------------------
titulo "5/5 virt-install"
OSV="win10"
if command -v osinfo-query >/dev/null 2>&1 && osinfo-query os 2>/dev/null | grep -qw win11; then
    OSV="win11"
fi
info "os-variant: $OSV"

definir_vm_sem_iniciar \
    --name "$VM_NAME" \
    --metadata title="Windows 11 (GPU passthrough)" \
    --memory "$VM_RAM_MB" \
    --vcpus "$VM_VCPUS" \
    --cpu host-passthrough \
    --machine q35 \
    --os-variant "$OSV" \
    --boot uefi \
    --tpm model=tpm-crb,backend.type=emulator,backend.version=2.0 \
    --disk path="$QCOW2_PATH",format=qcow2,bus=virtio,cache=none \
    --disk path="$ISO_WINDOWS",device=cdrom,bus=sata \
    --disk path="$ISO_VIRTIO",device=cdrom,bus=sata \
    --network network=default,model=virtio \
    --graphics spice \
    --video qxl \
    --sound ich9 \
    --noautoconsole

if ! consultar_vm_definida; then
    falhar "A definição terminou, mas a VM '$VM_NAME' não pôde ser confirmada: $VM_DIAGNOSTICO"
fi
validar_vm_definida || falhar "A VM foi definida sem iniciar, mas seu XML foi recusado: $VM_DIAGNOSTICO"
iniciar_vm_definida_validada || falhar "$VM_DIAGNOSTICO"

echo
ok "VM definida, validada ainda pausada e instalação iniciada somente após a topologia ativa ser aprovada."
$VIRSH list --all

info "Conferência do XML (loader OVMF, nvram, qcow2, q35):"
virsh_privilegiado dumpxml --inactive "$VM_NAME" \
    | grep -E "loader|nvram|qcow2|machine=" | sed 's/^/  /'

echo
aviso "A ISO do Windows pede 'Press any key to boot from CD' logo no início:"
aviso "abra o console AGORA e pressione uma tecla, senão o boot cai no shell UEFI."
if confirmar "Abrir o console gráfico da VM agora (virt-manager)?"; then
    exigir_comando virt-manager
    nohup virt-manager --connect qemu:///system --show-domain-console "$VM_NAME" >/dev/null 2>&1 &
    info "Console aberto. Siga a etapa 41 para o passo a passo da instalação."
else
    info "Abra depois com: virt-manager --connect qemu:///system --show-domain-console $VM_NAME"
fi
info "Se perder o momento do boot: virsh --connect qemu:///system reset $VM_NAME"
