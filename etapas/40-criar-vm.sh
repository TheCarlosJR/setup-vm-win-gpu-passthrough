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
    local status
    QCOW2_ESTADO=""
    validar_pai_qcow2 || { QCOW2_ESTADO="inacessivel"; return 1; }

    if executar_como_qemu test -L -- "$QCOW2_PATH"; then
        QCOW2_ESTADO="link"
        QCOW2_DIAGNOSTICO="QCOW2_PATH já existe como link simbólico: $QCOW2_PATH"
        return 0
    else
        status=$?
        if [ "$status" -ne 1 ]; then
            QCOW2_ESTADO="inacessivel"
            QCOW2_DIAGNOSTICO="Não foi possível consultar se o QCOW2 é link simbólico (status $status)."
            return 1
        fi
    fi
    if executar_como_qemu test -e -- "$QCOW2_PATH"; then
        QCOW2_ESTADO="existente"
        return 0
    else
        status=$?
        if [ "$status" -ne 1 ]; then
            QCOW2_ESTADO="inacessivel"
            QCOW2_DIAGNOSTICO="Não foi possível consultar o QCOW2 como libvirt-qemu (status $status)."
            return 1
        fi
    fi
    QCOW2_ESTADO="ausente"
    QCOW2_DIAGNOSTICO="QCOW2 ausente: $QCOW2_PATH"
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
    if ! executar_como_qemu ln -- "$temporario" "$QCOW2_PATH"; then
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
    local diretorio nome novo="" backup="" original=0 status backup_preservado=""
    diretorio="${APPARMOR_LOCAL%/*}"
    nome="${APPARMOR_LOCAL##*/}"

    limpar_apparmor_temporarios() {
        [ -z "$novo" ] || executar_sudo rm -f -- "$novo" >/dev/null 2>&1 || true
        [ -z "$backup" ] || executar_sudo rm -f -- "$backup" >/dev/null 2>&1 || true
    }
    trap 'status=$?; trap - EXIT; limpar_apparmor_temporarios; exit "$status"' EXIT
    trap 'exit 1' HUP INT TERM

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
    executar_sudo mv -fT -- "$novo" "$APPARMOR_LOCAL" \
        || { erro "Não foi possível instalar atomicamente a regra AppArmor."; return 1; }
    novo=""

    if executar_sudo systemctl reload apparmor; then
        if [ -n "$backup" ]; then
            executar_sudo rm -f -- "$backup" \
                || aviso "Regra ativa, mas o backup temporário não pôde ser removido: $backup"
        fi
        backup=""
        ok "Regra '$REGRA_APPARMOR' instalada atomicamente e AppArmor recarregado."
        return 0
    fi

    erro "Reload do AppArmor falhou; restaurando o arquivo anterior."
    if [ "$original" -eq 1 ]; then
        if executar_sudo mv -fT -- "$backup" "$APPARMOR_LOCAL"; then
            backup=""
        else
            backup_preservado="$backup"
            backup=""
            erro "Falha ao restaurar $APPARMOR_LOCAL; backup preservado em $backup_preservado."
            return 1
        fi
    else
        executar_sudo rm -f -- "$APPARMOR_LOCAL" \
            || { erro "Falha ao remover a regra nova após erro de reload."; return 1; }
    fi
    if ! executar_sudo systemctl reload apparmor; then
        erro "Arquivo anterior restaurado, mas o reload da política restaurada também falhou."
    else
        info "Arquivo e política AppArmor anteriores restaurados."
    fi
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
    VM_XML=""
    if ! VM_XML="$(virsh_privilegiado dumpxml --inactive "$VM_NAME" 2>/dev/null)"; then
        VM_DIAGNOSTICO="VM '$VM_NAME' existe, mas não foi possível obter seu XML inativo."
        return 1
    fi
}

validar_xml_vm() {
    local resultado status
    if resultado="$(printf '%s' "$VM_XML" | python3 -c '
import sys
import xml.etree.ElementTree as ET

qcow2, iso_windows, iso_virtio = sys.argv[1:4]
erros = []
try:
    root = ET.fromstring(sys.stdin.read())
except Exception as exc:
    print(f"XML inválido: {exc}")
    raise SystemExit(1)

os_node = root.find("./os")
type_node = root.find("./os/type")
machine = "" if type_node is None else type_node.get("machine", "")
if machine not in ("q35", "pc-q35") and not machine.startswith("pc-q35-"):
    erros.append(f"chipset não é Q35 ({machine or 'ausente'})")
loader = None if os_node is None else os_node.find("loader")
firmware = "" if os_node is None else os_node.get("firmware", "")
loader_pflash = loader is not None and loader.get("type") == "pflash"
if firmware != "efi" and not loader_pflash:
    erros.append("firmware UEFI/pflash ausente")
if loader is not None and loader.get("type") != "pflash":
    erros.append("loader UEFI não usa pflash")

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
def source_file(disk):
    source = disk.find("source")
    return None if source is None else source.get("file")

def unique_disk(path, device, label):
    encontrados = [d for d in disks if d.get("device") == device and source_file(d) == path]
    if len(encontrados) != 1:
        erros.append(f"{label} deve ser referenciado exatamente uma vez por {path}")
        return None
    return encontrados[0]

sistema = unique_disk(qcow2, "disk", "disco do sistema")
if sistema is not None:
    driver = sistema.find("driver")
    target = sistema.find("target")
    if driver is None or driver.get("name") != "qemu" or driver.get("type") != "qcow2" or driver.get("cache") != "none":
        erros.append("driver do QCOW2 deve ser qemu/qcow2 com cache=none")
    if target is None or target.get("bus") != "virtio":
        erros.append("disco do sistema não usa barramento virtio")

for path, label in ((iso_windows, "ISO do Windows"), (iso_virtio, "ISO VirtIO")):
    cdrom = unique_disk(path, "cdrom", label)
    if cdrom is None:
        continue
    driver = cdrom.find("driver")
    target = cdrom.find("target")
    if driver is None or driver.get("name") != "qemu" or driver.get("type") != "raw":
        erros.append(f"{label} não usa driver qemu/raw")
    if target is None or target.get("bus") != "sata":
        erros.append(f"{label} não usa barramento sata")
    if cdrom.find("readonly") is None:
        erros.append(f"{label} não está marcada somente leitura")

cdrom_files = [source_file(d) for d in disks if d.get("device") == "cdrom" and source_file(d) is not None]
if sorted(cdrom_files) != sorted([iso_windows, iso_virtio]):
    erros.append("CD-ROMs de arquivo não correspondem exatamente às duas ISOs configuradas")

interfaces = root.findall("./devices/interface")
if not any((model := interface.find("model")) is not None and model.get("type") == "virtio"
           for interface in interfaces):
    erros.append("interface de rede com modelo virtio ausente")

if erros:
    print("; ".join(erros))
    raise SystemExit(1)
' "$QCOW2_PATH" "$ISO_WINDOWS" "$ISO_VIRTIO" 2>&1)"; then
        return 0
    else
        status=$?
        VM_DIAGNOSTICO="XML da VM divergente: ${resultado:-validação falhou com status $status}."
        return 1
    fi
}

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
        if obter_xml_vm && [ "$parametros_ok" -eq 1 ] && [ "$isos_ok" -eq 1 ] \
            && validar_xml_vm; then
            v_ok "VM '$VM_NAME' referencia os recursos exatos e usa Q35, UEFI, TPM2 e drivers esperados."
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
    obter_xml_vm || falhar "$VM_DIAGNOSTICO"
    validar_xml_vm || falhar "$VM_DIAGNOSTICO"
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

virt-install \
    --connect qemu:///system \
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
    falhar "virt-install terminou, mas a VM '$VM_NAME' não pôde ser confirmada: $VM_DIAGNOSTICO"
fi
obter_xml_vm || falhar "$VM_DIAGNOSTICO"
validar_xml_vm || falhar "$VM_DIAGNOSTICO"

echo
ok "VM criada, validada e instalação iniciada em segundo plano."
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
