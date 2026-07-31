#!/bin/bash
# ============================================================================
# etapas/41-instalacao-windows.sh - Capítulo 18: Instalação do Windows 11
# ============================================================================
# A instalação é interativa (console gráfico). Este script imprime o passo a
# passo exato do manual, abre o console se desejado e usa a comunicação com o
# qemu-guest-agent apenas como indicador de acessibilidade do guest.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

XML_DIAGNOSTICO=""

consultar_estado_vm() {
    LC_ALL=C $VIRSH domstate "$1" 2>/dev/null
}

validar_xml_instalacao() {
    local modo="$1" xml resultado status opcao=()
    XML_DIAGNOSTICO=""
    if [ "$modo" = "inativo" ]; then
        opcao=(--inactive)
    elif [ "$modo" != "ativo" ]; then
        XML_DIAGNOSTICO="Modo interno inválido ao validar o XML: $modo."
        return 1
    fi
    if ! xml="$(LC_ALL=C $VIRSH dumpxml "${opcao[@]}" "$VM_NAME" 2>/dev/null)"; then
        XML_DIAGNOSTICO="Não foi possível obter o XML $modo de '$VM_NAME'."
        return 1
    fi
    if resultado="$(printf '%s' "$xml" | python3 -c '
import sys
import xml.etree.ElementTree as ET

qcow2, iso_windows, iso_virtio = sys.argv[1:4]
erros = []
try:
    root = ET.fromstring(sys.stdin.read())
except Exception as exc:
    print(f"XML inválido: {exc}")
    raise SystemExit(1)

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
    erros.append(f"esperado exatamente um disco de dados, encontrados {len(data_disks)}")
if len(cdroms) != 2:
    erros.append(f"esperados exatamente dois CD-ROMs, encontrados {len(cdroms)}")
if outros or len(disks) != 3:
    erros.append("somente o QCOW2 e as duas ISOs podem estar expostos durante a instalação")
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
        erros.append(f"{label} não usa exclusivamente source file={path}")
        return False
    return True

if len(data_disks) == 1:
    disk = data_disks[0]
    if disk.get("type") != "file":
        erros.append("o único disco de dados deve ser file/device=disk")
    fonte_arquivo_exata(disk, qcow2, "disco do sistema")
    drivers = disk.findall("driver")
    targets = disk.findall("target")
    if len(drivers) != 1 or drivers[0].get("name") != "qemu" or drivers[0].get("type") != "qcow2" or drivers[0].get("cache") != "none":
        erros.append("o disco do sistema deve usar um único driver qemu/qcow2 com cache=none")
    if len(targets) != 1 or targets[0].get("bus") != "virtio":
        erros.append("o disco do sistema deve possuir um único target virtio")

for path, label in ((iso_windows, "ISO do Windows"), (iso_virtio, "ISO VirtIO")):
    matches = [d for d in cdroms if len(d.findall("source")) == 1 and d.find("source").get("file") == path]
    if len(matches) != 1:
        erros.append(f"{label} deve aparecer exatamente uma vez")
        continue
    cdrom = matches[0]
    if cdrom.get("type") != "file" or not fonte_arquivo_exata(cdrom, path, label):
        erros.append(f"{label} deve ser file/device=cdrom")
    drivers = cdrom.findall("driver")
    targets = cdrom.findall("target")
    if len(drivers) != 1 or drivers[0].get("name") != "qemu" or drivers[0].get("type") != "raw":
        erros.append(f"{label} deve possuir um único driver qemu/raw")
    if len(targets) != 1 or targets[0].get("bus") != "sata":
        erros.append(f"{label} deve possuir um único target sata")
    if len(cdrom.findall("readonly")) != 1:
        erros.append(f"{label} deve estar marcada readonly exatamente uma vez")

if erros:
    print("; ".join(erros))
    raise SystemExit(1)
' "$QCOW2_PATH" "$ISO_WINDOWS" "$ISO_VIRTIO" 2>&1)"; then
        return 0
    else
        status=$?
        XML_DIAGNOSTICO="Topologia de armazenamento $modo insegura: ${resultado:-validação falhou com status $status}."
        return 1
    fi
}

validar_topologia_estado() {
    local estado="$1"
    validar_xml_instalacao inativo || return 1
    case "$estado" in
        running|paused)
            validar_xml_instalacao ativo || return 1
            ;;
    esac
}

verificar() {
    local chave estado configuracao_ok=1
    for chave in VM_NAME QCOW2_PATH ISO_WINDOWS ISO_VIRTIO; do
        if [ -n "${!chave:-}" ]; then
            v_ok "$chave definido."
        else
            v_falta "$chave não definido (etapa 40)."
            configuracao_ok=0
        fi
    done
    if ! command -v python3 >/dev/null 2>&1; then
        v_falta "Comando 'python3' ausente."
        configuracao_ok=0
    fi
    [ "$configuracao_ok" -eq 1 ] || v_fim
    [ "$ISO_WINDOWS" != "$ISO_VIRTIO" ] \
        || { v_falta "ISO_WINDOWS e ISO_VIRTIO não podem ser iguais."; v_fim; }
    if ! vm_existe "$VM_NAME"; then
        v_falta "VM '$VM_NAME' não existe (etapa 40)."
        v_fim
    fi
    if ! estado="$(consultar_estado_vm "$VM_NAME")"; then
        v_falta "Não foi possível consultar o estado de '$VM_NAME'."
        v_fim
    fi
    case "$estado" in
        "shut off"|running)
            if validar_topologia_estado "$estado"; then
                v_ok "Somente o QCOW2 configurado e as duas ISOs estão expostos à instalação."
            else
                v_falta "$XML_DIAGNOSTICO"
            fi
            ;;
        *)
            v_falta "Estado não suportado para validar a instalação: '$estado'."
            ;;
    esac
    if $VIRSH qemu-agent-command "$VM_NAME" '{"execute":"guest-ping"}' >/dev/null 2>&1; then
        v_ok "qemu-guest-agent acessível."
        info "A resposta é apenas um indicador de acesso; não comprova a instalação completa do Windows."
    else
        v_falta "guest-agent sem resposta (guest tools pendentes, VM desligada ou guest inacessível)."
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

oferecer_console() {
    if confirmar "Abrir o console gráfico agora?"; then
        exigir_comando virt-manager
        nohup virt-manager --connect qemu:///system --show-domain-console "$VM_NAME" >/dev/null 2>&1 &
    fi
}

interromper_inicio_inseguro() {
    local motivo="$1"
    if $VIRSH destroy "$VM_NAME" >/dev/null 2>&1; then
        aviso "A VM iniciada por este script foi interrompida e permaneceu definida para diagnóstico."
    else
        erro "Não foi possível interromper a VM após uma falha de validação; desligue-a imediatamente."
        motivo="$motivo A interrupção automática também falhou."
    fi
    falhar "$motivo"
}

exigir_comando python3
exigir_conf VM_NAME QCOW2_PATH ISO_WINDOWS ISO_VIRTIO
[ "$ISO_WINDOWS" != "$ISO_VIRTIO" ] \
    || falhar "ISO_WINDOWS e ISO_VIRTIO devem apontar para arquivos distintos."
vm_existe "$VM_NAME" || falhar "VM '$VM_NAME' não existe. Execute a etapa 40 antes."
if ! ESTADO_VM="$(consultar_estado_vm "$VM_NAME")"; then
    falhar "Não foi possível consultar o estado da VM '$VM_NAME'."
fi
case "$ESTADO_VM" in
    "shut off"|running)
        ;;
    *)
        falhar "Estado não suportado para instalação interativa: '$ESTADO_VM'. Deixe a VM running ou shut off."
        ;;
esac
validar_topologia_estado "$ESTADO_VM" || falhar "$XML_DIAGNOSTICO"

titulo "Capítulo 18: Instalação do Windows 11 (interativa)"
info "Estado atual da VM: $ESTADO_VM"
info "Pré-condição validada: o guest vê somente C: ($QCOW2_PATH) e as duas ISOs; HD1 está excluído."

cat <<'GUIA'
PASSO A PASSO (dentro do console gráfico da VM):

 1. Boot pela ISO: pressione uma tecla em "Press any key to boot from CD".
 2. Idioma/teclado > Avançar > "Instalar agora".
 3. Chave de produto: insira, ou "Não tenho uma chave de produto".
 4. Escolha a edição (Home/Pro) e aceite os termos.
 5. "Personalizada: instalar somente o Windows (avançado)".
 6. A lista de discos estará VAZIA: é o esperado (driver VirtIO ausente).
 7. Clique em "Carregar driver" > "Procurar" > unidade do CD virtio-win >
        viostor\w11\amd64
    (use vioscsi\w11\amd64 apenas se o disco foi configurado como virtio-scsi)
 8. Selecione "Red Hat VirtIO SCSI controller" > Avançar.
 9. O disco de 250 GB aparece: selecione e prossiga a instalação.
10. Se o instalador exigir rede/conta Microsoft: "Carregar driver" novamente em
        NetKVM\w11\amd64
11. Ao chegar na área de trabalho, ainda com a virtio-win.iso anexada:
    executar virtio-win-guest-tools.exe (raiz da ISO) e reiniciar.

PÓS-INSTALAÇÃO (desenho de segurança do manual):
  - Windows Defender: manter proteção em tempo real ATIVA; não instalar
    antivírus de terceiros; NUNCA excluir a pasta airlock da verificação.
  - Desativar a Inicialização Rápida (Fast Startup):
    use windows/Desativar-Fast-Startup.ps1 (PowerShell como administrador)
    ou Painel de Controle > Opções de Energia.
  - O driver NVIDIA dentro da VM só é instalado APÓS a etapa 50
    (quando a GPU real estiver em passthrough): baixar de nvidia.com/drivers,
    opção "Instalação limpa".

O disco HD1 físico é anexado na etapa 50; o particionamento dele (se estiver
em branco) é feito no Gerenciamento de Disco do Windows: GPT + NTFS.
Se o HD1 JÁ TEM dados: NÃO formate; ele aparece pronto com letra de unidade.
GUIA

case "$ESTADO_VM" in
    "shut off")
        if confirmar "A VM está desligada. Iniciar agora?"; then
            validar_xml_instalacao inativo || falhar "$XML_DIAGNOSTICO"
            if ! $VIRSH start "$VM_NAME" --paused; then
                ESTADO_APOS_FALHA="$(consultar_estado_vm "$VM_NAME" 2>/dev/null || true)"
                if [ "$ESTADO_APOS_FALHA" = "shut off" ]; then
                    falhar "Não foi possível iniciar a VM '$VM_NAME' pausada."
                fi
                interromper_inicio_inseguro "O start pausado falhou sem confirmar que a VM permaneceu desligada."
            fi
            if ! ESTADO_VM="$(consultar_estado_vm "$VM_NAME")"; then
                interromper_inicio_inseguro "A VM foi iniciada pausada, mas seu estado não pôde ser consultado."
            fi
            [ "$ESTADO_VM" = "paused" ] \
                || interromper_inicio_inseguro "Após o start seguro, a VM entrou no estado inesperado '$ESTADO_VM'."
            if ! validar_topologia_estado "$ESTADO_VM"; then
                DIAGNOSTICO_POS_START="$XML_DIAGNOSTICO"
                interromper_inicio_inseguro "$DIAGNOSTICO_POS_START"
            fi
            $VIRSH resume "$VM_NAME" >/dev/null \
                || interromper_inicio_inseguro "A topologia ativa foi validada, mas a VM não pôde ser retomada."
            if ! ESTADO_VM="$(consultar_estado_vm "$VM_NAME")"; then
                interromper_inicio_inseguro "A VM foi retomada, mas o estado running não pôde ser confirmado."
            fi
            [ "$ESTADO_VM" = "running" ] \
                || interromper_inicio_inseguro "Após resume, a VM entrou no estado inesperado '$ESTADO_VM'."
            if ! validar_topologia_estado "$ESTADO_VM"; then
                DIAGNOSTICO_POS_START="$XML_DIAGNOSTICO"
                interromper_inicio_inseguro "A topologia ativa mudou após resume: $DIAGNOSTICO_POS_START"
            fi
            oferecer_console
        else
            info "VM mantida desligada; inicie-a quando estiver pronto para instalar."
        fi
        ;;
    running)
        oferecer_console
        ;;
esac

echo
titulo "Verificação (quando o Windows + guest tools estiverem instalados)"
if $VIRSH qemu-agent-command "$VM_NAME" '{"execute":"guest-ping"}' >/dev/null 2>&1; then
    ok "qemu-guest-agent acessível: {\"return\":{}}"
    aviso "Este ping confirma acessibilidade do agente, não a instalação completa do Windows."
    info "Dentro do Windows, confirme também: Get-Disk  e  Get-Service QEMU-GA"
else
    info "guest-agent ainda sem resposta. Normal antes de instalar o virtio-win-guest-tools."
    info "Rode '41-instalacao-windows.sh --verificar' depois da instalação."
fi
