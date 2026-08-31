#!/bin/bash
# Regressões herméticas para UBU-001..UBU-010 e LIM-001.
set -euo pipefail
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$RAIZ/tests/fixtures/platform"
PATH_ORIGINAL="$PATH"
TMPDIR_TESTE="$(mktemp -d)"
trap 'rm -rf -- "$TMPDIR_TESTE"' EXIT

falha() { printf 'FALHA: %s\n' "$*" >&2; exit 1; }
igual() {
    [ "$1" = "$2" ] || falha "${3:-valores diferentes}: esperado '$2', obtido '$1'"
}
contem() {
    [[ "$1" == *"$2"* ]] || falha "${3:-texto ausente}: '$2'"
}

# Carrega exatamente as APIs usadas pelas etapas, sem executar etapa real.
# shellcheck source=../lib/common.sh
source "$RAIZ/lib/common.sh"

# --- Perfis Ubuntu/Pop e fixtures consumidos pela produção -------------------
plataforma_carregar "$FIXTURES/ubuntu/os-release" || falha "$PLATAFORMA_ERRO"
igual "$PLATAFORMA_ID" ubuntu 'ID Ubuntu'
igual "$PLATAFORMA_VERSION_ID" 26.04 'versão Ubuntu'
igual "$PLATAFORMA_QEMU_PACOTE" qemu-system-x86 'pacote QEMU Ubuntu'
igual "$PLATAFORMA_QEMU_COMANDO" qemu-system-x86_64 'capacidade QEMU Ubuntu'
igual "$PLATAFORMA_NVIDIA_ESTRATEGIA" ubuntu-drivers 'estratégia NVIDIA Ubuntu'
mapfile -t PACOTES_UBUNTU < <(plataforma_pacotes_virtualizacao)
printf '%s\n' "${PACOTES_UBUNTU[@]}" | grep -Fxq qemu-system-x86 \
    || falha 'perfil Ubuntu não instalaria qemu-system-x86'
if printf '%s\n' "${PACOTES_UBUNTU[@]}" | grep -Fxq qemu-kvm; then
    falha 'perfil Ubuntu ainda instalaria qemu-kvm'
fi

BIN_SERVICO="$TMPDIR_TESTE/bin-servico"
mkdir -p "$BIN_SERVICO"
export SERVICO_LOG="$TMPDIR_TESTE/systemctl.log"
: > "$SERVICO_LOG"
cat > "$BIN_SERVICO/systemctl" <<'SCRIPT'
#!/bin/bash
printf '%s\n' "$*" >> "$SERVICO_LOG"
printf '%s\n' loaded
SCRIPT
chmod +x "$BIN_SERVICO/systemctl"
if PATH="$BIN_SERVICO:$PATH_ORIGINAL" \
    plataforma_resolver_servico libvirt "$FIXTURES/ubuntu/systemctl-units.txt"; then
    falha 'fixture Ubuntu sem libvirt caiu no systemctl do host'
else
    RC=$?
fi
igual "$RC" 1 'unidade libvirt ausente deve ser pendência'
[ ! -s "$SERVICO_LOG" ] || falha 'systemctl foi consultado apesar da fixture autoritativa'
cat > "$TMPDIR_TESTE/libvirt-malformado.txt" <<'UNITS'
libvirtd.service|loaded|active|running|enabled|campo-extra
UNITS
if plataforma_resolver_servico libvirt "$TMPDIR_TESTE/libvirt-malformado.txt"; then
    falha 'fixture systemd malformada foi aceita'
else
    RC=$?
fi
igual "$RC" 2 'fixture systemd inválida deve ser erro operacional'
contem "$PLATAFORMA_ERRO" 'malformada' 'fixture systemd inválida sem diagnóstico'
cat > "$TMPDIR_TESTE/libvirt-units.txt" <<'UNITS'
# unit|load_state|active_state|sub_state|unit_file_state
virtqemud.service|loaded|active|running|enabled
UNITS
plataforma_resolver_servico libvirt "$TMPDIR_TESTE/libvirt-units.txt" \
    || falha 'serviço modular da fixture não foi resolvido'
igual "$PLATAFORMA_SERVICO_RESOLVIDO" virtqemud 'backend libvirt modular'
igual "$PLATAFORMA_UNIDADE_RESOLVIDA" virtqemud.service 'unidade libvirt modular'
igual "$PLATAFORMA_UNIDADE_ACAO" nenhuma 'unidade ativa não deveria ser reiniciada'
cat > "$TMPDIR_TESTE/libvirt-coexistencia.txt" <<'UNITS'
libvirtd.socket|loaded|inactive|dead|disabled
libvirtd.service|loaded|inactive|dead|enabled
virtqemud.socket|loaded|active|listening|enabled
virtqemud.service|loaded|inactive|dead|enabled
UNITS
plataforma_resolver_servico libvirt "$TMPDIR_TESTE/libvirt-coexistencia.txt" \
    || falha 'coexistência libvirtd/virtqemud não foi resolvida'
igual "$PLATAFORMA_UNIDADE_RESOLVIDA" virtqemud.socket \
    'resolver escolheu primeiro loaded em vez do socket ativo'
cat > "$TMPDIR_TESTE/libvirt-habilitavel.txt" <<'UNITS'
libvirtd.service|loaded|inactive|dead|enabled
virtqemud.socket|loaded|inactive|dead|disabled
UNITS
plataforma_resolver_servico libvirt "$TMPDIR_TESTE/libvirt-habilitavel.txt" \
    || falha 'socket habilitável não foi resolvido'
igual "$PLATAFORMA_UNIDADE_RESOLVIDA" virtqemud.socket 'socket habilitável não teve preferência'
igual "$PLATAFORMA_UNIDADE_ACAO" enable-now 'ação de socket habilitável'

plataforma_carregar "$FIXTURES/pop-os/os-release" || falha "$PLATAFORMA_ERRO"
igual "$PLATAFORMA_ID" pop 'ID Pop!_OS'
igual "$PLATAFORMA_QEMU_PACOTE" qemu-kvm 'pacote QEMU Pop!_OS'
igual "$PLATAFORMA_NVIDIA_ESTRATEGIA" system76 'estratégia NVIDIA Pop!_OS'
mapfile -t PACOTES_POP < <(plataforma_pacotes_virtualizacao)
printf '%s\n' "${PACOTES_POP[@]}" | grep -Fxq qemu-kvm \
    || falha 'perfil Pop!_OS perdeu qemu-kvm'

# A disponibilidade do pacote System76 não pode influenciar o ID do perfil.
BIN_NVIDIA="$TMPDIR_TESTE/bin-nvidia"
mkdir -p "$BIN_NVIDIA"
export NVIDIA_APT_CACHE_LOG="$TMPDIR_TESTE/apt-cache-nvidia.log"
: > "$NVIDIA_APT_CACHE_LOG"
cat > "$BIN_NVIDIA/apt-cache" <<'SCRIPT'
#!/bin/bash
printf '%s\n' "$*" >> "$NVIDIA_APT_CACHE_LOG"
exit 0
SCRIPT
chmod +x "$BIN_NVIDIA/apt-cache"
PATH="$BIN_NVIDIA:$PATH_ORIGINAL" plataforma_carregar "$FIXTURES/ubuntu/os-release" \
    || falha "$PLATAFORMA_ERRO"
igual "$PLATAFORMA_NVIDIA_ESTRATEGIA" ubuntu-drivers \
    'Ubuntu escolheu System76 pela disponibilidade do pacote'
[ ! -s "$NVIDIA_APT_CACHE_LOG" ] \
    || falha 'perfil consultou disponibilidade de pacote para decidir a distro'
PATH="$BIN_NVIDIA:$PATH_ORIGINAL" plataforma_carregar "$FIXTURES/pop-os/os-release" \
    || falha "$PLATAFORMA_ERRO"
igual "$PLATAFORMA_NVIDIA_ESTRATEGIA" system76 'Pop!_OS não escolheu System76'

PLATFORM_FIXTURE_BUILTIN_EXECUTED=0
if plataforma_carregar "$FIXTURES/malicious-os-release/os-release"; then
    falha 'os-release hostil foi aceito pelo parser de produção'
fi
igual "$PLATFORM_FIXTURE_BUILTIN_EXECUTED" 0 'fixture os-release executou conteúdo'
igual "$PLATAFORMA_CARREGADA" 0 'perfil inválido permaneceu carregado'
igual "$PLATAFORMA_PERFIL" '' 'dados de perfil anterior vazaram após falha'

# --- Identidade QEMU: qemu.conf explícito vence; ambiguidades falham ---------
plataforma_carregar "$FIXTURES/ubuntu/os-release" || falha "$PLATAFORMA_ERRO"
BIN_QEMU_NSS="$TMPDIR_TESTE/bin-qemu-nss"
mkdir -p "$BIN_QEMU_NSS"
cat > "$BIN_QEMU_NSS/getent" <<'SCRIPT'
#!/bin/bash
case "${1:-}:${2:-}" in
    passwd:libvirt-qemu) echo 'libvirt-qemu:x:64055:64055:Libvirt QEMU:/var/lib/libvirt:/usr/sbin/nologin' ;;
    passwd:qemu) echo 'qemu:x:107:107:QEMU:/var/lib/qemu:/usr/sbin/nologin' ;;
    *) exit 2 ;;
esac
SCRIPT
chmod +x "$BIN_QEMU_NSS/getent"
cat > "$TMPDIR_TESTE/qemu.conf" <<'CONF'
# user = "libvirt-qemu"
user="qemu"
CONF
PATH="$BIN_QEMU_NSS:$PATH_ORIGINAL" \
    plataforma_resolver_usuario_qemu "$TMPDIR_TESTE/qemu.conf" \
    || falha "$PLATAFORMA_ERRO"
igual "$PLATAFORMA_USUARIO_QEMU" qemu \
    'qemu.conf não selecionou qemu quando ambas as contas existem'
rm -f "$TMPDIR_TESTE/qemu-ausente.conf"
PATH="$BIN_QEMU_NSS:$PATH_ORIGINAL" \
    plataforma_resolver_usuario_qemu "$TMPDIR_TESTE/qemu-ausente.conf" \
    || falha "$PLATAFORMA_ERRO"
igual "$PLATAFORMA_USUARIO_QEMU" libvirt-qemu 'padrão único do perfil Ubuntu'
cat > "$TMPDIR_TESTE/qemu-ambiguo.conf" <<'CONF'
user = "qemu"
user = "libvirt-qemu"
CONF
if PATH="$BIN_QEMU_NSS:$PATH_ORIGINAL" \
    plataforma_resolver_usuario_qemu "$TMPDIR_TESTE/qemu-ambiguo.conf"; then
    falha 'qemu.conf com identidades conflitantes foi aceito'
else
    RC=$?
fi
igual "$RC" 2 'qemu.conf duplicado deve ser erro de configuração'
contem "$PLATAFORMA_ERRO" 'ambígua' 'conflito de identidade QEMU sem diagnóstico'
igual "$PLATAFORMA_USUARIO_QEMU" '' 'identidade parcial vazou após qemu.conf duplicado'
cat > "$TMPDIR_TESTE/qemu-proibido.conf" <<'CONF'
user = "root"
CONF
if PATH="$BIN_QEMU_NSS:$PATH_ORIGINAL" \
    plataforma_resolver_usuario_qemu "$TMPDIR_TESTE/qemu-proibido.conf"; then
    falha 'qemu.conf com usuário fora da allowlist foi aceito'
else
    RC=$?
fi
igual "$RC" 2 'usuário QEMU proibido deve ser erro de configuração'
contem "$PLATAFORMA_ERRO" 'não pertence ao conjunto permitido' \
    'usuário QEMU proibido sem diagnóstico'
printf 'user = "qemu"\n' > "$TMPDIR_TESTE/qemu-alvo.conf"
ln -s "$TMPDIR_TESTE/qemu-alvo.conf" "$TMPDIR_TESTE/qemu-link.conf"
if PATH="$BIN_QEMU_NSS:$PATH_ORIGINAL" \
    plataforma_resolver_usuario_qemu "$TMPDIR_TESTE/qemu-link.conf"; then
    falha 'qemu.conf linkado foi aceito'
else
    RC=$?
fi
igual "$RC" 2 'qemu.conf linkado deve ser erro de configuração'
contem "$PLATAFORMA_ERRO" 'não link' 'qemu.conf linkado sem diagnóstico'
ln -s "$TMPDIR_TESTE/qemu-alvo-inexistente.conf" "$TMPDIR_TESTE/qemu-link-pendente.conf"
if PATH="$BIN_QEMU_NSS:$PATH_ORIGINAL" \
    plataforma_resolver_usuario_qemu "$TMPDIR_TESTE/qemu-link-pendente.conf"; then
    falha 'qemu.conf em link pendente caiu no fallback do perfil'
else
    RC=$?
fi
igual "$RC" 2 'link pendente de qemu.conf deve ser erro de configuração'
mkdir "$TMPDIR_TESTE/qemu-nao-regular.conf"
if PATH="$BIN_QEMU_NSS:$PATH_ORIGINAL" \
    plataforma_resolver_usuario_qemu "$TMPDIR_TESTE/qemu-nao-regular.conf"; then
    falha 'qemu.conf não regular foi aceito'
else
    RC=$?
fi
igual "$RC" 2 'qemu.conf não regular/ilegível deve ser erro de configuração'
contem "$PLATAFORMA_ERRO" 'arquivo regular legível' \
    'qemu.conf não regular/ilegível sem diagnóstico'
# qemu.conf regular fechado ao root (modo 0600 do pacote) é o caso normal do
# Ubuntu/Pop!_OS: sem sudo a identidade é presumida, nunca diagnosticada como
# link nem promovida a erro de configuração.
if [ "$(id -u)" -ne 0 ]; then
    BIN_QEMU_SEM_SUDO="$TMPDIR_TESTE/bin-qemu-sem-sudo"
    mkdir -p "$BIN_QEMU_SEM_SUDO"
    cp "$BIN_QEMU_NSS/getent" "$BIN_QEMU_SEM_SUDO/getent"
    cat > "$BIN_QEMU_SEM_SUDO/sudo" <<'SCRIPT'
#!/bin/bash
exit 1
SCRIPT
    chmod +x "$BIN_QEMU_SEM_SUDO/sudo"
    printf 'user = "qemu"\n' > "$TMPDIR_TESTE/qemu-restrito.conf"
    chmod 000 "$TMPDIR_TESTE/qemu-restrito.conf"
    PATH="$BIN_QEMU_SEM_SUDO:$PATH_ORIGINAL" \
        plataforma_resolver_usuario_qemu "$TMPDIR_TESTE/qemu-restrito.conf" \
        || falha "qemu.conf fechado ao root virou falha: $PLATAFORMA_ERRO"
    igual "$PLATAFORMA_QEMU_ORIGEM" presumido \
        'qemu.conf fechado ao root não foi marcado como presunção'
    igual "$PLATAFORMA_ERRO" '' 'presunção de qemu.conf vazou diagnóstico de erro'
    [ -n "$PLATAFORMA_USUARIO_QEMU" ] \
        || falha 'presunção de qemu.conf não resolveu identidade alguma'
    chmod 644 "$TMPDIR_TESTE/qemu-restrito.conf"
fi
BIN_QEMU_NSS_AUSENTE="$TMPDIR_TESTE/bin-qemu-nss-ausente"
mkdir -p "$BIN_QEMU_NSS_AUSENTE"
cat > "$BIN_QEMU_NSS_AUSENTE/getent" <<'SCRIPT'
#!/bin/bash
exit 2
SCRIPT
chmod +x "$BIN_QEMU_NSS_AUSENTE/getent"
if PATH="$BIN_QEMU_NSS_AUSENTE:$PATH_ORIGINAL" \
    plataforma_resolver_usuario_qemu "$TMPDIR_TESTE/qemu-ausente.conf"; then
    falha 'conta QEMU NSS ausente foi tratada como resolvida'
else
    RC=$?
fi
igual "$RC" 1 'conta QEMU ausente deve permanecer pendência'
contem "$PLATAFORMA_ERRO" 'ainda não possui entrada NSS' \
    'conta QEMU ausente sem diagnóstico de pré-requisito'

# --- Boot efetivo GRUB versus configuração kernelstub ------------------------
plataforma_carregar "$FIXTURES/ubuntu/os-release" || falha "$PLATAFORMA_ERRO"
BIN_BOOT="$TMPDIR_TESTE/bin-boot"
mkdir -p "$BIN_BOOT"
export KERNELSTUB_LOG="$TMPDIR_TESTE/kernelstub.log"
: > "$KERNELSTUB_LOG"
cat > "$BIN_BOOT/kernelstub" <<'SCRIPT'
#!/bin/bash
printf '%s\n' "$*" >> "$KERNELSTUB_LOG"
exit 99
SCRIPT
cat > "$BIN_BOOT/bootctl" <<'SCRIPT'
#!/bin/bash
cat <<'STATUS'
System:
      Firmware: UEFI
Current Boot Loader:
       Product: GRUB 2.12
STATUS
SCRIPT
chmod +x "$BIN_BOOT/kernelstub" "$BIN_BOOT/bootctl"
GRUB_CFG_ARQUIVO="$TMPDIR_TESTE/grub.cfg"
printf '%s\n' 'menuentry fixture {}' > "$GRUB_CFG_ARQUIVO"
if PATH="$BIN_BOOT:$PATH_ORIGINAL" validar_bootloader_configurado kernelstub; then
    falha 'configuração kernelstub foi aceita com GRUB efetivo'
fi
contem "$BOOTLOADER_VALIDACAO_ERRO" 'Divergência de boot' 'divergência de boot não diagnosticada'
[ ! -s "$KERNELSTUB_LOG" ] || falha 'kernelstub obsoleto foi executado durante a reconciliação'
PATH="$BIN_BOOT:$PATH_ORIGINAL" validar_bootloader_configurado grub \
    || falha "GRUB efetivo e persistido não foram aceitos: $BOOTLOADER_VALIDACAO_ERRO"

# --- NSS, operador efetivo e confirmação reforçada ---------------------------
BIN_NSS="$TMPDIR_TESTE/bin-nss"
NSS_HOME="$TMPDIR_TESTE/home-alice"
mkdir -p "$BIN_NSS" "$NSS_HOME"
export NSS_HOME
cat > "$BIN_NSS/getent" <<'SCRIPT'
#!/bin/bash
case "${1:-}:${2:-}" in
    passwd:alice) printf 'alice:x:1001:1002:Alice:%s:/bin/bash\n' "$NSS_HOME" ;;
    *) exit 2 ;;
esac
SCRIPT
cat > "$BIN_NSS/id" <<'SCRIPT'
#!/bin/bash
case "${1:-}:${2:-}" in
    -u:alice) echo 1001 ;;
    -g:alice) echo 1002 ;;
    *) exit 2 ;;
esac
SCRIPT
chmod +x "$BIN_NSS/getent" "$BIN_NSS/id"
if PATH="$BIN_NSS:$PATH_ORIGINAL" validar_usuario_linux 'Alice!' bob; then
    falha 'nome de usuário inválido foi aceito'
fi
PATH="$BIN_NSS:$PATH_ORIGINAL" validar_usuario_linux alice bob \
    || falha "$USUARIO_VALIDACAO_ERRO"
igual "$USUARIO_VALIDADO_UID" 1001 'UID NSS'
igual "$USUARIO_VALIDADO_GID" 1002 'GID NSS'
igual "$USUARIO_VALIDADO_HOME" "$NSS_HOME" 'home NSS'
igual "$USUARIO_OPERADOR" bob 'operador injetado explicitamente'
igual "$USUARIO_DIFERE_OPERADOR" 1 'diferença de operador'
CONFIRMACAO_TOKEN=''
confirmar_digitando() { CONFIRMACAO_TOKEN="$1"; return 0; }
confirmar_usuario_linux_diferente alice || falha 'confirmação reforçada recusada no teste'
igual "$CONFIRMACAO_TOKEN" USAR-alice 'token de confirmação da conta diferente'
PATH="$BIN_NSS:$PATH_ORIGINAL" validar_usuario_linux alice alice \
    || falha "$USUARIO_VALIDACAO_ERRO"
igual "$USUARIO_DIFERE_OPERADOR" 0 'mesma conta marcada como diferente'

# --- APT independente de locale e fwupd --------------------------------------
BIN_APT="$TMPDIR_TESTE/bin-apt"
mkdir -p "$BIN_APT"
export APT_LOG="$TMPDIR_TESTE/apt.log"
cat > "$BIN_APT/apt-get" <<'SCRIPT'
#!/bin/bash
printf 'LC_ALL=%s ARGS=%s\n' "${LC_ALL:-}" "$*" >> "$APT_LOG"
[ "${LC_ALL:-}" = C ] || exit 90
operacao="${!#}"
case "${APT_CASO:-}:$operacao" in
    inst:dist-upgrade)
        printf '%s\n' 'Inst pacote-a [1] (2 Ubuntu:26.04 [amd64])'
        printf '%s\n' 'Inst pacote-b [1] (2 Ubuntu:26.04 [amd64])'
        ;;
    remv:dist-upgrade) printf '%s\n' 'Remv pacote-antigo [1]' ;;
    autoremove:autoremove) printf '%s\n' 'Remv pacote-orfao [1]' ;;
    deduplicado:dist-upgrade) printf '%s\n' 'Remv pacote-repetido [1]' ;;
    deduplicado:autoremove)
        printf '%s\n' 'Remv pacote-repetido [1]'
        printf '%s\n' 'Remv pacote-orfao [1]'
        ;;
    erro-dist:dist-upgrade) printf '%s\n' 'falha dist simulada' >&2; exit 100 ;;
    erro-auto:autoremove) printf '%s\n' 'falha autoremove simulada' >&2; exit 100 ;;
    zero:*|inst:autoremove|remv:autoremove|autoremove:dist-upgrade|erro-auto:dist-upgrade)
        printf '%s\n' '0 upgraded, 0 newly installed, 0 to remove.'
        ;;
    *) exit 91 ;;
esac
SCRIPT
chmod +x "$BIN_APT/apt-get"
: > "$APT_LOG"
APT_CASO=inst; export APT_CASO
LANG=C PATH="$BIN_APT:$PATH_ORIGINAL" apt_contar_atualizacoes > "$TMPDIR_TESTE/apt-c.out" \
    || falha "$APT_ATUALIZACOES_ERRO"
igual "$(< "$TMPDIR_TESTE/apt-c.out")" 2 'contagem APT Inst em locale C'
igual "$APT_ATUALIZACOES_TOTAL" 2 'estado APT Inst'
igual "$APT_DIST_INSTALACOES" 2 'categoria Inst do dist-upgrade'
LANG=pt_BR.UTF-8 PATH="$BIN_APT:$PATH_ORIGINAL" \
    apt_contar_atualizacoes > "$TMPDIR_TESTE/apt.out" \
    || falha "$APT_ATUALIZACOES_ERRO"
igual "$(< "$TMPDIR_TESTE/apt.out")" "$(< "$TMPDIR_TESTE/apt-c.out")" \
    'contagem APT divergiu entre C e pt_BR.UTF-8'
APT_CASO=zero
PATH="$BIN_APT:$PATH_ORIGINAL" apt_contar_atualizacoes > "$TMPDIR_TESTE/apt.out" \
    || falha "$APT_ATUALIZACOES_ERRO"
igual "$(< "$TMPDIR_TESTE/apt.out")" 0 'contagem APT zero'
APT_CASO=remv
PATH="$BIN_APT:$PATH_ORIGINAL" apt_contar_atualizacoes >/dev/null \
    || falha "$APT_ATUALIZACOES_ERRO"
igual "$APT_ATUALIZACOES_TOTAL" 1 'Remv do dist-upgrade ignorado'
igual "$APT_DIST_REMOCOES" 1 'categoria Remv do dist-upgrade'
APT_CASO=autoremove
PATH="$BIN_APT:$PATH_ORIGINAL" apt_contar_atualizacoes >/dev/null \
    || falha "$APT_ATUALIZACOES_ERRO"
igual "$APT_ATUALIZACOES_TOTAL" 1 'autoremove isolado ignorado'
igual "$APT_AUTOREMOVE_EXCLUSIVAS" 1 'categoria autoremove exclusiva'
APT_CASO=deduplicado
PATH="$BIN_APT:$PATH_ORIGINAL" apt_contar_atualizacoes >/dev/null \
    || falha "$APT_ATUALIZACOES_ERRO"
igual "$APT_ATUALIZACOES_TOTAL" 2 'pacote repetido foi contado duas vezes'
igual "$APT_AUTOREMOVE_EXCLUSIVAS" 1 'autoremove adicional deduplicado'
APT_CASO=erro-dist
if PATH="$BIN_APT:$PATH_ORIGINAL" apt_contar_atualizacoes > "$TMPDIR_TESTE/apt.out"; then
    falha 'falha do dist-upgrade simulado virou sucesso'
fi
contem "$APT_ATUALIZACOES_ERRO" 'Falha ao simular dist-upgrade APT' 'diagnóstico dist-upgrade ausente'
APT_CASO=erro-auto
if PATH="$BIN_APT:$PATH_ORIGINAL" apt_contar_atualizacoes > "$TMPDIR_TESTE/apt.out"; then
    falha 'falha do autoremove simulado virou sucesso'
fi
contem "$APT_ATUALIZACOES_ERRO" 'Falha ao simular autoremove APT' 'diagnóstico autoremove ausente'
grep -Fq -- '--simulate -o Debug::NoLocking=1 dist-upgrade' "$APT_LOG" \
    || falha 'status APT não simulou dist/full-upgrade sem lock'
grep -Fq -- '--simulate -o Debug::NoLocking=1 autoremove' "$APT_LOG" \
    || falha 'status APT não simulou autoremove sem lock'
grep -Fq 'LC_ALL=C' "$APT_LOG" || falha 'simulação APT não fixou locale C'
igual "$(fwupd_classificar_resultado get-updates 2)" sem-atualizacoes 'fwupd sem updates'
igual "$(fwupd_classificar_resultado update 0)" sucesso 'fwupd update concluído'
if fwupd_classificar_resultado refresh 2 > "$TMPDIR_TESTE/fwupd.out"; then
    falha 'fwupd refresh com falha/no-op foi aceito'
fi
igual "$(< "$TMPDIR_TESTE/fwupd.out")" erro 'classificação de falha fwupd'
if fwupd_classificar_resultado update 1 >/dev/null; then
    falha 'falha operacional fwupd virou sucesso'
fi

# --- Modelo compartilhado de /vm sem 777 ------------------------------------
BIN_VM="$TMPDIR_TESTE/bin-vm"
VM_DIR="$TMPDIR_TESTE/vm"
VM_FILE="$VM_DIR/novo.qcow2"
mkdir -p "$BIN_VM" "$VM_DIR"
: > "$VM_FILE"
export VM_DIR VM_FILE
cat > "$BIN_VM/getent" <<'SCRIPT'
#!/bin/bash
case "${1:-}:${2:-}" in
    group:vm-passthrough) echo 'vm-passthrough:x:991:alice,qemu' ;;
    group:vm-passthrough-lab) echo 'vm-passthrough-lab:x:992:alice,qemu' ;;
    *) exit 2 ;;
esac
SCRIPT
cat > "$BIN_VM/id" <<'SCRIPT'
#!/bin/bash
case "${1:-}:${2:-}" in
    -nG:alice) echo 'alice vm-passthrough' ;;
    -nG:qemu) echo 'qemu vm-passthrough' ;;
    *) exit 2 ;;
esac
SCRIPT
cat > "$BIN_VM/stat" <<'SCRIPT'
#!/bin/bash
formato=''
for ((i = 1; i <= $#; i++)); do
    if [ "${!i}" = -c ]; then
        j=$((i + 1)); formato="${!j}"
    fi
done
alvo="${!#}"
if [ "$alvo" = "$VM_DIR" ] && [ "$formato" = '%U:%G:%a' ]; then
    echo 'root:vm-passthrough:2770'
elif [ "$alvo" = "$VM_FILE" ] && [ "$formato" = '%h:%G:%a' ]; then
    echo '1:vm-passthrough:660'
else
    exit 2
fi
SCRIPT
cat > "$BIN_VM/getfacl" <<'SCRIPT'
#!/bin/bash
cat <<'ACL'
user::rwx
group::rwx
mask::rwx
other::---
default:user::rwx
default:group::rwx
default:mask::rwx
default:other::---
ACL
SCRIPT
chmod +x "$BIN_VM"/*
PATH="$BIN_VM:$PATH_ORIGINAL" \
    validar_modelo_diretorio_vm "$VM_DIR" alice qemu vm-passthrough \
    || falha "$GRUPO_VM_ERRO"
PATH="$BIN_VM:$PATH_ORIGINAL" \
    validar_arquivo_compartilhado_vm "$VM_FILE" vm-passthrough \
    || falha 'arquivo novo não foi reconhecido como grupo:0660'
nome_grupo_vm_dedicado_valido vm-passthrough-lab \
    || falha 'grupo dedicado configurável com sufixo foi recusado'
if nome_grupo_vm_dedicado_valido disk || validar_valor_conf VM_STORAGE_GROUP disk; then
    falha 'grupo privilegiado disk foi aceito como armazenamento dedicado'
fi
# I9: a convergência do diretório da VM mora no módulo de storage; a fachada
# apenas agrega.
grep -Fq 'sudo chmod 2770 "$diretorio"' "$RAIZ/lib/shell/storage.sh" \
    || falha 'convergência /vm não fixa setgid 2770'
grep -Fq "d:u::rwx,d:g::rwx,d:m::rwx,d:o::---" "$RAIZ/lib/shell/storage.sh" \
    || falha 'ACL default de /vm não está explícita'
grep -Fq 'acesso_identidade "$USUARIO_LINUX" rw "$TESTE_QEMU"' \
    "$RAIZ/etapas/21-usuario-grupos.sh" \
    || falha 'etapa 21 não testa leitura/escrita cruzada pelo operador'
grep -Fq 'acesso_identidade "$QEMU_USUARIO" rw "$TESTE_OPERADOR"' \
    "$RAIZ/etapas/21-usuario-grupos.sh" \
    || falha 'etapa 21 não testa leitura/escrita cruzada pela identidade QEMU'
if grep -rE 'chmod[[:space:]]+(-R[[:space:]]+)?777' \
    "$RAIZ/lib" "$RAIZ/etapas/13-diretorios.sh" \
    "$RAIZ/etapas/21-usuario-grupos.sh" "$RAIZ/etapas/40-criar-vm.sh"; then
    falha 'modelo /vm ainda contém chmod 777'
fi
if grep -E 'sudo[[:space:]]+(chgrp|chmod|chown|setfacl)[^\n]*(QCOW2|QCOW2_PATH)' \
    "$RAIZ/etapas/40-criar-vm.sh"; then
    falha 'etapa 40 ainda altera metadados do QCOW2 por pathname como root'
fi
grep -Fq 'QCOW2 recusado antes de sudo' "$RAIZ/etapas/40-criar-vm.sh" \
    || falha 'guarda de QCOW2 não antecede sudo na etapa 40'
grep -Fq 'ln -- "$temporario" "$destino"' "$RAIZ/etapas/40-criar-vm.sh" \
    || falha 'publicação atômica sem sobrescrita do QCOW2 novo ausente'

# --- Prova de acesso independente do coreutils da distribuição ---------------
# O uutils que o Ubuntu 25.10 e derivados instalam em /usr/bin/test ignora
# grupos suplementares em -r/-w/-x e nega o acesso que o kernel concede, que é
# exatamente como /vm é compartilhado. Nenhuma etapa pode voltar a delegar essa
# resposta a um binário de coreutils.
if grep -rnE 'sudo +-u +[^|&;]*\btest +-[rwx]\b' "$RAIZ/etapas" "$RAIZ/util" "$RAIZ/lib"; then
    falha 'prova de acesso voltou a depender do test(1) da distribuição'
fi
BIN_ACESSO="$TMPDIR_TESTE/bin-acesso"
mkdir -p "$BIN_ACESSO"
ALVO_ACESSO="$TMPDIR_TESTE/alvo-acesso.bin"
: > "$ALVO_ACESSO"
chmod 0660 "$ALVO_ACESSO"
# test(1) e [(1) externos envenenados: negam tudo, como o uutils faz quando o
# acesso só existe pela classe de grupo. A prova precisa ignorá-los.
cat > "$BIN_ACESSO/test" <<'SCRIPT'
#!/bin/bash
exit 1
SCRIPT
cp "$BIN_ACESSO/test" "$BIN_ACESSO/["
cat > "$BIN_ACESSO/sudo" <<'SCRIPT'
#!/bin/bash
[ "${1:-}" = -u ] && shift 2
exec "$@"
SCRIPT
chmod +x "$BIN_ACESSO/test" "$BIN_ACESSO/[" "$BIN_ACESSO/sudo"
PATH="$BIN_ACESSO:$PATH_ORIGINAL" acesso_identidade "$(id -un)" rw "$ALVO_ACESSO" \
    || falha "prova de acesso regrediu para o coreutils externo: $ACESSO_IDENTIDADE_ERRO"
PATH="$BIN_ACESSO:$PATH_ORIGINAL" acesso_identidade "$(id -un)" rwx "$TMPDIR_TESTE" \
    || falha "prova de acesso não confirmou rwx em diretório próprio: $ACESSO_IDENTIDADE_ERRO"
if PATH="$BIN_ACESSO:$PATH_ORIGINAL" acesso_identidade "$(id -un)" r 'relativo/nao-absoluto'; then
    falha 'prova de acesso aceitou caminho relativo'
fi
if [ "$(id -u)" -ne 0 ]; then
    # root ignora os bits de modo; a negativa só é observável sem privilégio.
    ALVO_NEGADO="$TMPDIR_TESTE/alvo-negado.bin"
    : > "$ALVO_NEGADO"
    chmod 0000 "$ALVO_NEGADO"
    set +e
    PATH="$BIN_ACESSO:$PATH_ORIGINAL" acesso_identidade "$(id -un)" r "$ALVO_NEGADO"
    RC_ACESSO=$?
    set -e
    igual "$RC_ACESSO" 1 'prova de acesso não reprovou caminho sem permissão'
fi
grep -Fq 'command -v "["' "$RAIZ/lib/shell/privilege.sh" \
    || falha 'prova de acesso não confirma mais que o test é embutido do shell'

# --- Discard somente no QCOW2 alvo e com cardinalidade -----------------------
cat > "$TMPDIR_TESTE/discard-ausente.xml" <<'XML'
<domain><devices>
  <disk type='file' device='disk'>
    <driver name='qemu' type='qcow2'/><source file='/vm/alvo.qcow2'/>
  </disk>
  <disk type='file' device='disk'>
    <driver name='qemu' type='qcow2' discard='unmap'/><source file='/vm/outro.qcow2'/>
  </disk>
</devices></domain>
XML
if xml_disco_qcow2_estado "$TMPDIR_TESTE/discard-ausente.xml" /vm/alvo.qcow2; then
    falha 'discard de outro disco foi atribuído ao QCOW2 alvo'
else
    RC=$?
fi
igual "$RC" 1 'retorno de discard ausente no alvo único'
igual "$DISCARD_XML_ESTADO" ausente 'estado de discard ausente'
cat > "$TMPDIR_TESTE/discard-ativo.xml" <<'XML'
<domain><devices>
  <disk type='file' device='disk'>
    <driver name='qemu' type='qcow2' discard='unmap'/><source file='/vm/alvo.qcow2'/>
  </disk>
  <disk type='file' device='cdrom'><source file='/vm/alvo.qcow2'/></disk>
</devices></domain>
XML
xml_disco_qcow2_estado "$TMPDIR_TESTE/discard-ativo.xml" /vm/alvo.qcow2 \
    || falha "$DISCARD_XML_ERRO"
cat > "$TMPDIR_TESTE/discard-duplicado.xml" <<'XML'
<domain><devices>
  <disk type='file' device='disk'><driver name='qemu' discard='unmap'/><source file='/vm/alvo.qcow2'/></disk>
  <disk type='file' device='disk'><driver name='qemu' discard='unmap'/><source file='/vm/alvo.qcow2'/></disk>
</devices></domain>
XML
if xml_disco_qcow2_estado "$TMPDIR_TESTE/discard-duplicado.xml" /vm/alvo.qcow2; then
    falha 'dois discos com o mesmo source foram aceitos'
else
    RC=$?
fi
igual "$RC" 2 'cardinalidade duplicada de discard'
igual "$DISCARD_XML_ESTADO" erro 'estado de cardinalidade duplicada'
cat > "$TMPDIR_TESTE/discard-fontes-duplicadas.xml" <<'XML'
<domain><devices>
  <disk type='file' device='disk'>
    <driver name='qemu' discard='unmap'/>
    <source file='/vm/alvo.qcow2'/><source file='/vm/alvo.qcow2'/>
  </disk>
</devices></domain>
XML
if xml_disco_qcow2_estado "$TMPDIR_TESTE/discard-fontes-duplicadas.xml" /vm/alvo.qcow2; then
    falha 'fontes duplicadas no mesmo disco alvo foram aceitas'
else
    RC=$?
fi
igual "$RC" 2 'cardinalidade duplicada de source/@file'

# --- Contrato 0/1/2/3 e diagnóstico preservado pelo menu ---------------------
PROJETO_MENU="$TMPDIR_TESTE/projeto-menu"
mkdir -p "$PROJETO_MENU/lib" "$PROJETO_MENU/etapas"
cp "$RAIZ/lib/common.sh" "$PROJETO_MENU/lib/common.sh"
cp "$RAIZ/lib/platform.sh" "$PROJETO_MENU/lib/platform.sh"
cp "$RAIZ/lib/python-core.sh" "$PROJETO_MENU/lib/python-core.sh"
# I9: a fachada carrega TODOS os módulos de lib/shell/ de forma
# incondicional, então o projeto mínimo copia o diretório inteiro em vez
# de uma lista nominal que envelhece a cada módulo novo.
mkdir -p "$PROJETO_MENU/lib/shell"
cp "$RAIZ/lib/shell/"*.sh "$PROJETO_MENU/lib/shell/"
# O módulo de dispensas lê a matriz de política em lib/policy/.
mkdir -p "$PROJETO_MENU/lib/policy"
cp "$RAIZ/lib/policy/waivers.tsv" "$PROJETO_MENU/lib/policy/waivers.tsv"
cp -a "$RAIZ/libexec" "$PROJETO_MENU/libexec"
cp "$RAIZ/menu.sh" "$PROJETO_MENU/menu.sh"
mapfile -t ARQUIVOS_MENU < <(awk -F'["|]' '/^    "[0-9][0-9]-/ { print $2 }' "$RAIZ/menu.sh")
for ARQUIVO_MENU in "${ARQUIVOS_MENU[@]}"; do
    cat > "$PROJETO_MENU/etapas/$ARQUIVO_MENU" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
v_ok 'conclusão simulada'
v_fim
SCRIPT
    chmod +x "$PROJETO_MENU/etapas/$ARQUIVO_MENU"
done
cat > "$PROJETO_MENU/etapas/00-inventario.sh" <<'SCRIPT'
#!/bin/bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
v_falta 'pendência deliberada por v_fim'
v_fim
SCRIPT
cat > "$PROJETO_MENU/etapas/10-atualizar-sistema.sh" <<'SCRIPT'
#!/bin/bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
v_indeterminado 'estado indeterminado simulado'
v_fim
SCRIPT
cat > "$PROJETO_MENU/etapas/20-virtualizacao.sh" <<'SCRIPT'
#!/bin/bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
v_erro 'falha operacional preservada'
v_fim
SCRIPT
cat > "$PROJETO_MENU/etapas/21-usuario-grupos.sh" <<'SCRIPT'
#!/bin/bash
printf '%s\n' 'aborto Bash cru com RC 1'
exit 1
SCRIPT
chmod +x "$PROJETO_MENU/etapas/"*.sh
set +e
PATH="$PATH_ORIGINAL" /bin/bash "$PROJETO_MENU/menu.sh" --status \
    > "$TMPDIR_TESTE/menu.out" 2>&1
MENU_RC=$?
set -e
igual "$MENU_RC" 3 'precedência de erro no menu'
MENU_SAIDA="$(< "$TMPDIR_TESTE/menu.out")"
contem "$MENU_SAIDA" '[!!]' 'menu não exibiu erro como [!!]'
contem "$MENU_SAIDA" '[??]' 'menu não distinguiu indeterminado'
contem "$MENU_SAIDA" '[  ]' 'menu não preservou pendência normal'
contem "$MENU_SAIDA" 'falha operacional preservada' 'diagnóstico de erro foi perdido'
contem "$MENU_SAIDA" 'aborto Bash cru com RC 1' 'diagnóstico do aborto RC 1 foi perdido'
contem "$MENU_SAIDA" 'sem sentinel válido' 'RC 1 cru não virou erro 3 autenticado'
if [[ "$MENU_SAIDA" == *'__PASSTHROUGH_STATUS_V1__:'* ]]; then
    falha 'sentinel interno vazou para a apresentação do menu'
fi

# --- Entry points reais 10/11/20/21/40 em sandbox PATH fechado --------------
PROJETO_EP="$TMPDIR_TESTE/projeto-entrypoints"
ROOT_EP="$TMPDIR_TESTE/raiz-entrypoints"
BIN_EP="$ROOT_EP/bin"
LOG_EP="$ROOT_EP/chamadas.log"
mkdir -p "$PROJETO_EP/lib" "$PROJETO_EP/etapas" \
    "$BIN_EP" "$ROOT_EP/etc/libvirt" "$ROOT_EP/etc/apparmor.d/local/abstractions" \
    "$ROOT_EP/usr/share/OVMF" "$ROOT_EP/home/alice" "$ROOT_EP/vm" \
    "$ROOT_EP/tmp" "$ROOT_EP/proc" "$ROOT_EP/sys/class/net/eth0"
cp "$RAIZ/lib/common.sh" "$PROJETO_EP/lib/common.sh"
cp "$RAIZ/lib/platform.sh" "$PROJETO_EP/lib/platform.sh"
cp "$RAIZ/lib/python-core.sh" "$PROJETO_EP/lib/python-core.sh"
# I9: a fachada carrega TODOS os módulos de lib/shell/ de forma
# incondicional, então o projeto mínimo copia o diretório inteiro em vez
# de uma lista nominal que envelhece a cada módulo novo.
mkdir -p "$PROJETO_EP/lib/shell"
cp "$RAIZ/lib/shell/"*.sh "$PROJETO_EP/lib/shell/"
# O módulo de dispensas lê a matriz de política em lib/policy/.
mkdir -p "$PROJETO_EP/lib/policy"
cp "$RAIZ/lib/policy/waivers.tsv" "$PROJETO_EP/lib/policy/waivers.tsv"
cp -a "$RAIZ/libexec" "$PROJETO_EP/libexec"
for ETAPA_EP in 10-atualizar-sistema.sh 11-driver-nvidia.sh 20-virtualizacao.sh \
    21-usuario-grupos.sh 40-criar-vm.sh; do
    cp "$RAIZ/etapas/$ETAPA_EP" "$PROJETO_EP/etapas/$ETAPA_EP"
done
: > "$ROOT_EP/usr/share/OVMF/OVMF_CODE.fd"
: > "$ROOT_EP/sys/class/net/eth0/device"
printf '1\n' > "$ROOT_EP/sys/class/net/eth0/type"
printf 'MemTotal:       16777216 kB\n' > "$ROOT_EP/proc/meminfo"
printf '/vm/** rwk,\n' > "$ROOT_EP/etc/apparmor.d/local/abstractions/libvirt-qemu"
printf 'aberto\n' > "$ROOT_EP/selo-vm.estado"
: > "$LOG_EP"

# Apenas utilitários locais não privilegiados ficam visíveis; comandos de
# sistema, NSS, libvirt e mutadores recebem mocks abaixo.
# python3 entra como o interpretador real: desde I3 os entrypoints consultam o
# core Python pela ponte única, e o core precisa ser exercitado de verdade (ele
# só escreve na raiz privada sob TMPDIR do harness).
for COMANDO_SEGURO in awk cat chmod cut df dirname grep head ln ls mktemp mv \
    python3 readlink rm sed sleep sort tail tee tr; do
    CAMINHO_SEGURO="$(type -P "$COMANDO_SEGURO")"
    ln -s "$CAMINHO_SEGURO" "$BIN_EP/$COMANDO_SEGURO"
done

cat > "$BIN_EP/id" <<'SCRIPT'
#!/bin/bash
case "$*" in
    '-u') echo 1000 ;;
    '-un') echo alice ;;
    '-u alice') echo 1001 ;;
    '-g alice') echo 1001 ;;
    '-nG') echo "${MOCK_ID_GRUPOS_SESSAO:-alice libvirt kvm vm-passthrough}" ;;
    '-nG alice') echo 'alice libvirt kvm vm-passthrough' ;;
    '-nG qemu') echo 'qemu vm-passthrough' ;;
    '-nG libvirt-qemu') echo 'libvirt-qemu vm-passthrough' ;;
    *) exit 2 ;;
esac
SCRIPT

cat > "$BIN_EP/getent" <<'SCRIPT'
#!/bin/bash
printf 'getent|%s\n' "$*" >> "$ENTRYPOINT_LOG"
case "${1:-}:${2:-}" in
    passwd:alice) printf 'alice:x:1001:1001:Alice:%s/home/alice:/bin/bash\n' "$PASSTHROUGH_TEST_ROOT" ;;
    passwd:qemu) echo 'qemu:x:107:107:QEMU:/var/lib/qemu:/usr/sbin/nologin' ;;
    passwd:libvirt-qemu) echo 'libvirt-qemu:x:64055:64055:Libvirt QEMU:/var/lib/libvirt:/usr/sbin/nologin' ;;
    group:libvirt) echo 'libvirt:x:120:alice' ;;
    group:kvm) echo 'kvm:x:121:alice' ;;
    group:vm-passthrough) echo 'vm-passthrough:x:991:alice,qemu,libvirt-qemu' ;;
    *) exit 2 ;;
esac
SCRIPT

cat > "$BIN_EP/stat" <<'SCRIPT'
#!/bin/bash
formato=''
for ((i = 1; i <= $#; i++)); do
    if [ "${!i}" = -c ]; then
        j=$((i + 1)); formato="${!j}"
    fi
done
alvo="${!#}"
case "$alvo:$formato" in
    "$PASSTHROUGH_TEST_ROOT/vm:%U:%G:%a")
        if grep -qx selado "$PASSTHROUGH_TEST_ROOT/selo-vm.estado"; then
            echo 'root:vm-passthrough:2750'
        else
            echo 'root:vm-passthrough:2770'
        fi
        ;;
    "$PASSTHROUGH_TEST_ROOT/vm/.teste-"*':%h:%G:%a') echo '1:vm-passthrough:660' ;;
    "$PASSTHROUGH_TEST_ROOT/vm/"*.qcow2':%G:%a') echo 'vm-passthrough:660' ;;
    *) exec /usr/bin/stat "$@" ;;
esac
SCRIPT

cat > "$BIN_EP/getfacl" <<'SCRIPT'
#!/bin/bash
cat <<'ACL'
user::rwx
group::rwx
mask::rwx
other::---
default:user::rwx
default:group::rwx
default:mask::rwx
default:other::---
ACL
SCRIPT
cat > "$BIN_EP/setfacl" <<'SCRIPT'
#!/bin/bash
printf 'escape|setfacl direto|%s\n' "$*" >> "$ENTRYPOINT_LOG"
exit 126
SCRIPT

cat > "$BIN_EP/sudo" <<'SCRIPT'
#!/bin/bash
printf 'sudo|%s\n' "$*" >> "$ENTRYPOINT_LOG"
if [ "${1:-}" = -n ] && [ "${2:-}" = true ] && [ "$#" -eq 2 ]; then
    exit 0
fi
if [ "${1:-}" = -v ] && [ "$#" -eq 1 ]; then
    exit 0
fi
usuario=''
if [ "${1:-}" = -u ]; then
    usuario="${2:-}"
    shift 2
fi
comando="${1:-}"
[ "$#" -gt 0 ] && shift
case "$comando" in
    apt)
        case "$*" in
            'update'|'full-upgrade -y'|'autoremove -y'|'install -y fwupd'|\
            'install -y nvidia-driver-555-open'|'install -y system76-driver-nvidia'|\
            'install -y qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients bridge-utils virt-manager ovmf swtpm swtpm-tools virtinst')
                exit 0
                ;;
            *)
                printf 'escape|sudo apt não permitido|%s\n' "$*" >> "$ENTRYPOINT_LOG"
                exit 126
                ;;
        esac
        ;;
    fwupdmgr)
        case "$*" in
            'refresh --force'|'get-updates'|'update') exit 0 ;;
            *)
                printf 'escape|sudo fwupdmgr não permitido|%s\n' "$*" >> "$ENTRYPOINT_LOG"
                exit 126
                ;;
        esac
        ;;
    systemctl)
        exit 0
        ;;
    virsh)
        exec "$PASSTHROUGH_TEST_ROOT/bin/virsh" "$@"
        ;;
    test)
        exec /usr/bin/test "$@"
        ;;
    sh)
        script="${2:-}"
        diretorio="${@: -2:1}"
        prefixo="${@: -1}"
        # Criadores O_EXCL da etapa 21, confinados às identidades esperadas.
        if [ "${1:-}" = -c ] && [[ "$script" == *'mktemp'* ]] \
           && [ "$diretorio" = "$PASSTHROUGH_TEST_ROOT/vm" ] \
           && { [ "$usuario:$prefixo" = 'alice:.teste-operador' ] \
                || [ "$usuario:$prefixo" = 'qemu:.teste-qemu' ]; }; then
            /bin/bash -c "$script" _ "$diretorio" "$prefixo"
            exit $?
        fi
        # Prova de acesso das etapas 21 e 40: roda de verdade sob bash, que
        # também resolve "[" pelo embutido, confinada à raiz da fixture.
        caminho_prova="${4:-}"
        if [ "${1:-}" = -c ] && [ "${3:-}" = _ ] && [ "$#" -ge 5 ] \
           && [[ "$script" == *'command -v "["'* ]] \
           && [[ "$script" == *'for modo in "$@"'* ]] \
           && [[ "$caminho_prova" == "$PASSTHROUGH_TEST_ROOT"/* ]]; then
            modos_prova_ok=1
            for modo_prova in "${@:5}"; do
                case "$modo_prova" in r|w|x) ;; *) modos_prova_ok=0 ;; esac
            done
            if [ "$modos_prova_ok" -eq 1 ]; then
                /bin/bash -c "$script" _ "${@:4}"
                exit $?
            fi
        fi
        # A única shell ampla permitida é exatamente o publicador QCOW2 de
        # produção, como qemu, para o destino/tamanho confinados da fixture.
        script_qcow2_esperado=$'\n'
        script_qcow2_esperado+=$'        set -eu\n'
        script_qcow2_esperado+=$'        destino=$1\n'
        script_qcow2_esperado+=$'        tamanho=$2\n'
        script_qcow2_esperado+=$'        diretorio=${destino%/*}\n'
        script_qcow2_esperado+=$'        nome=${destino##*/}\n'
        script_qcow2_esperado+=$'        temporario=$(mktemp "$diretorio/.${nome}.novo.XXXXXX")\n'
        script_qcow2_esperado+=$'        limpar() { rm -f -- "$temporario"; }\n'
        script_qcow2_esperado+=$'        trap limpar EXIT HUP INT TERM\n'
        script_qcow2_esperado+=$'        umask 0007\n'
        script_qcow2_esperado+=$'        qemu-img create -f qcow2 "$temporario" "$tamanho"\n'
        script_qcow2_esperado+=$'        chmod 0660 "$temporario"\n'
        script_qcow2_esperado+=$'        qemu-img info --output=json "$temporario" | grep -Eq \'"format"\'[[:space:]]*:[[:space:]]*\'"qcow2"\'\n'
        script_qcow2_esperado+=$'        ln -- "$temporario" "$destino"\n'
        script_qcow2_esperado+=$'        rm -f -- "$temporario"\n'
        script_qcow2_esperado+=$'        trap - EXIT HUP INT TERM\n'
        script_qcow2_esperado+=$'    '
        if [ "$usuario" = qemu ] && [ "$#" -eq 5 ] \
           && [ "${1:-}" = -c ] && [ "${3:-}" = _ ] \
           && [ "${4:-}" = "$PASSTHROUGH_TEST_ROOT/vm/Windows11.qcow2" ] \
           && [ "${5:-}" = 10G ] && [ "$script" = "$script_qcow2_esperado" ]; then
            MOCK_QCOW2_CREATE_ALLOWED=1 /bin/bash -c "$script" "${3:-}" "${4:-}" "${5:-}"
            exit $?
        fi
        printf 'escape|sudo sh não permitido|usuario=%s args=%s\n' \
            "$usuario" "$*" >> "$ENTRYPOINT_LOG"
        exit 126
        ;;
    chmod)
        modo="${1:-}"; alvo="${2:-}"
        if [ "$alvo" = "$PASSTHROUGH_TEST_ROOT/vm" ]; then
            case "$modo" in
                2750) printf 'selado\n' > "$PASSTHROUGH_TEST_ROOT/selo-vm.estado" ;;
                2770) printf 'aberto\n' > "$PASSTHROUGH_TEST_ROOT/selo-vm.estado" ;;
                *) printf 'escape|chmod inesperado em /vm|%s\n' "$modo" >> "$ENTRYPOINT_LOG"; exit 126 ;;
            esac
            exit 0
        fi
        ;;
    chown|setfacl|usermod|groupadd)
        exit 0
        ;;
    mkdir)
        alvo="${!#}"
        case "$alvo" in "$PASSTHROUGH_TEST_ROOT/etc/"*) /usr/bin/mkdir "$@"; exit $? ;; esac
        ;;
    touch)
        alvo="${!#}"
        case "$alvo" in "$PASSTHROUGH_TEST_ROOT/etc/"*) /usr/bin/touch "$@"; exit $? ;; esac
        ;;
    grep)
        alvo="${!#}"
        case "$alvo" in "$PASSTHROUGH_TEST_ROOT/etc/"*) /usr/bin/grep "$@"; exit $? ;; esac
        ;;
    rm)
        for argumento in "$@"; do
            case "$argumento" in
                -*|--) continue ;;
                "$PASSTHROUGH_TEST_ROOT/vm/.teste-"*) /usr/bin/rm -f -- "$argumento" ;;
                *) printf 'escape|sudo rm fora da raiz|%s\n' "$argumento" >> "$ENTRYPOINT_LOG"; exit 126 ;;
            esac
        done
        exit 0
        ;;
esac
printf 'escape|sudo não permitido|usuario=%s comando=%s args=%s\n' \
    "$usuario" "$comando" "$*" >> "$ENTRYPOINT_LOG"
exit 126
SCRIPT

cat > "$BIN_EP/systemctl" <<'SCRIPT'
#!/bin/bash
printf 'systemctl|%s\n' "$*" >> "$ENTRYPOINT_LOG"
[ "${1:-}" = show ] || { printf 'escape|systemctl mutante direto|%s\n' "$*" >> "$ENTRYPOINT_LOG"; exit 126; }
case "${MOCK_SYSTEMD_MODE:-coexist-active}" in
    falha)
        printf 'falha systemctl simulada para %s\n' "${2:-unidade ausente}" >&2
        exit 5
        ;;
    incompleto)
        printf 'LoadState=loaded\n'
        exit 0
        ;;
esac
unidade="${2:-}"
carga=not-found; ativo=inactive; sub=dead; unitfile=''
case "${MOCK_SYSTEMD_MODE:-coexist-active}:$unidade" in
    coexist-active:libvirtd.service) carga=loaded; ativo=inactive; sub=dead; unitfile=enabled ;;
    coexist-active:virtqemud.socket) carga=loaded; ativo=active; sub=listening; unitfile=enabled ;;
    coexist-active:virtqemud.service) carga=loaded; ativo=inactive; sub=dead; unitfile=enabled ;;
    socket:virtqemud.socket) carga=loaded; ativo=inactive; sub=dead; unitfile=disabled ;;
    socket:virtqemud.service) carga=loaded; ativo=inactive; sub=dead; unitfile=enabled ;;
    *:virtlogd.socket) carga=loaded; ativo=active; sub=listening; unitfile=enabled ;;
esac
printf 'LoadState=%s\nActiveState=%s\nSubState=%s\nUnitFileState=%s\n' \
    "$carga" "$ativo" "$sub" "$unitfile"
SCRIPT

cat > "$BIN_EP/virsh" <<'SCRIPT'
#!/bin/bash
printf 'virsh|%s\n' "$*" >> "$ENTRYPOINT_LOG"
case "$*" in
    # I9.9: a etapa 9 passou a provar a instalação com `--version`, que é
    # somente leitura. Sem este ramo o mock registra escape e sai 126, e o
    # verificador classifica a instalação como quebrada (rc 3).
    '--version') printf 'virsh 10.0.0\n'; exit 0 ;;
    '--connect qemu:///system list --all')
        [ "${MOCK_VIRSH_RC:-0}" -eq 0 ] && printf ' Id   Name      State\n -    fixture   shut off\n'
        exit "${MOCK_VIRSH_RC:-0}"
        ;;
    '--connect qemu:///system dominfo '*) exit 1 ;;
    '--connect qemu:///system net-info default')
        printf 'Name: default\nActive: yes\nAutostart: yes\n'
        ;;
    '--connect qemu:///system dumpxml --inactive fixture')
        cat <<'XML'
<domain type='kvm'>
  <name>fixture</name>
  <devices>
    <interface type='network'>
      <mac address='52:54:00:12:34:56'/>
      <source network='default'/>
    </interface>
  </devices>
</domain>
XML
        ;;
    '--connect qemu:///system dumpxml fixture')
        cat <<'XML'
<domain type='kvm'>
  <name>fixture</name>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <loader readonly='yes' type='pflash'>/usr/share/OVMF/OVMF_CODE.fd</loader>
    <nvram>/var/lib/libvirt/qemu/nvram/fixture_VARS.fd</nvram>
  </os>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='/vm/Windows11.qcow2'/>
    </disk>
  </devices>
</domain>
XML
        ;;
    *) printf 'escape|virsh mutante/desconhecido|%s\n' "$*" >> "$ENTRYPOINT_LOG"; exit 126 ;;
esac
SCRIPT

cat > "$BIN_EP/qemu-img" <<'SCRIPT'
#!/bin/bash
printf 'qemu-img|%s\n' "$*" >> "$ENTRYPOINT_LOG"
case "${1:-}" in
    # I9.9: sonda somente leitura da etapa 9.
    --version) printf 'qemu-img 8.2.2\n'; exit 0 ;;
    create)
        alvo="${4:-}"
        if [ "${MOCK_QCOW2_CREATE_ALLOWED:-0}" = 1 ] && [ "$#" -eq 5 ] \
           && [ "${2:-}" = -f ] && [ "${3:-}" = qcow2 ] && [ "${5:-}" = 10G ] \
           && [[ "$alvo" == "$PASSTHROUGH_TEST_ROOT/vm/.Windows11.qcow2.novo."?????? ]] \
           && [ -f "$alvo" ] && [ ! -L "$alvo" ]; then
            printf 'QCOW2-FIXTURE\n' > "$alvo"
            exit 0
        fi
        printf 'escape|qemu-img create não permitido|%s\n' "$*" >> "$ENTRYPOINT_LOG"
        exit 126
        ;;
    info)
        case "$#" in
            2) alvo="${2:-}" ;;
            3)
                [ "${2:-}" = --output=json ] \
                    || { printf 'escape|qemu-img info não permitido|%s\n' "$*" >> "$ENTRYPOINT_LOG"; exit 126; }
                alvo="${3:-}"
                ;;
            *)
                printf 'escape|qemu-img info não permitido|%s\n' "$*" >> "$ENTRYPOINT_LOG"
                exit 126
                ;;
        esac
        case "$alvo" in
            "$PASSTHROUGH_TEST_ROOT/vm/Windows11.qcow2"|\
            "$PASSTHROUGH_TEST_ROOT/vm/.Windows11.qcow2.novo."??????) ;;
            *)
                printf 'escape|qemu-img info fora da fixture|%s\n' "$alvo" >> "$ENTRYPOINT_LOG"
                exit 126
                ;;
        esac
        [ -f "$alvo" ] && [ ! -L "$alvo" ] \
            || { printf 'qemu-img: artefato ausente ou linkado: %s\n' "$alvo" >&2; exit 2; }
        printf '{"format":"qcow2","virtual-size":10737418240}\n'
        ;;
    *)
        printf 'escape|qemu-img operação não permitida|%s\n' "$*" >> "$ENTRYPOINT_LOG"
        exit 126
        ;;
esac
SCRIPT

cat > "$BIN_EP/apt" <<'SCRIPT'
#!/bin/bash
printf 'escape|apt direto|%s\n' "$*" >> "$ENTRYPOINT_LOG"
exit 126
SCRIPT
cat > "$BIN_EP/apt-get" <<'SCRIPT'
#!/bin/bash
printf 'apt-get|LC_ALL=%s|%s\n' "${LC_ALL:-}" "$*" >> "$ENTRYPOINT_LOG"
case "${!#}" in
    dist-upgrade|autoremove) echo '0 upgraded, 0 newly installed, 0 to remove.' ;;
    *) exit 126 ;;
esac
SCRIPT
cat > "$BIN_EP/apt-cache" <<'SCRIPT'
#!/bin/bash
printf 'apt-cache|%s\n' "$*" >> "$ENTRYPOINT_LOG"
[ "${1:-}" = show ]
SCRIPT
cat > "$BIN_EP/ubuntu-drivers" <<'SCRIPT'
#!/bin/bash
printf 'ubuntu-drivers|%s\n' "$*" >> "$ENTRYPOINT_LOG"
cat <<'OUT'
driver   : nvidia-driver-555-open - distro non-free recommended
OUT
SCRIPT
cat > "$BIN_EP/fwupdmgr" <<'SCRIPT'
#!/bin/bash
printf 'fwupdmgr|%s\n' "$*" >> "$ENTRYPOINT_LOG"
[ "$*" = get-updates ] || { printf 'escape|fwupdmgr mutante|%s\n' "$*" >> "$ENTRYPOINT_LOG"; exit 126; }
exit "${MOCK_FWUPD_RC:-2}"
SCRIPT
cat > "$BIN_EP/nvidia-smi" <<'SCRIPT'
#!/bin/bash
exit 1
SCRIPT
cat > "$BIN_EP/lspci" <<'SCRIPT'
#!/bin/bash
printf '%s\n' '01:00.0 VGA compatible controller: NVIDIA' 'Kernel driver in use: nvidia'
SCRIPT
cat > "$BIN_EP/dpkg" <<'SCRIPT'
#!/bin/bash
printf 'dpkg|%s\n' "$*" >> "$ENTRYPOINT_LOG"
case "$*" in
    '-s '*) exit 0 ;;
    '-l') printf 'ii  linux-image-6.8.0-fixture  6.8.0  amd64  kernel fixture\n' ;;
    *) exit 1 ;;
esac
SCRIPT
# I9.9: `dpkg -s` devolve 0 para pacote removido com config-files, então a
# prova de instalação passou a usar `dpkg-query -W -f='${Status}'`. Sem este
# shim o sandbox não tem a ferramenta e todo pacote vira indeterminado.
cat > "$BIN_EP/dpkg-query" <<'SCRIPT'
#!/bin/bash
printf 'dpkg-query|%s\n' "$*" >> "$ENTRYPOINT_LOG"
case "$*" in
    '-W -f=${Status} -- '*) printf 'install ok installed' ;;
    *) exit 1 ;;
esac
SCRIPT
cat > "$BIN_EP/uname" <<'SCRIPT'
#!/bin/bash
printf 'uname|%s\n' "$*" >> "$ENTRYPOINT_LOG"
[ "$*" = -r ] || exit 126
printf '6.8.0-fixture\n'
SCRIPT
cat > "$BIN_EP/qemu-system-x86_64" <<'SCRIPT'
#!/bin/bash
printf 'QEMU emulator version 9.0.0 (fixture)\n'
SCRIPT
cat > "$BIN_EP/kvm-ok" <<'SCRIPT'
#!/bin/bash
printf 'KVM acceleration can be used\n'
SCRIPT
cat > "$BIN_EP/lscpu" <<'SCRIPT'
#!/bin/bash
[ "$#" -eq 0 ] || exit 2
cat <<'OUT'
Architecture:        x86_64
CPU(s):              16
Vendor ID:           AuthenticAMD
OUT
SCRIPT
cat > "$BIN_EP/nproc" <<'SCRIPT'
#!/bin/bash
[ "$*" = --all ] || exit 2
printf '16\n'
SCRIPT
# I3: nenhum entrypoint consome mais xmlstarlet. O shim passou a ser um canário
# puro: qualquer chamada registra escape e falha, o que reprova a suíte se um
# consumidor operacional voltar.
cat > "$BIN_EP/xmlstarlet" <<'SCRIPT'
#!/bin/bash
printf 'escape|xmlstarlet foi chamado apesar da migração de I3|%s\n' "$*" >> "$ENTRYPOINT_LOG"
exit 126
SCRIPT
cat > "$BIN_EP/virt-install" <<'SCRIPT'
#!/bin/bash
# I9.9: `--version` é sonda somente leitura da etapa 9 e precisa responder
# antes da exigência de selo, que só vale para a criação real da VM.
if [ "$*" = --version ]; then
    printf 'virt-install|--version\n' >> "$ENTRYPOINT_LOG"
    printf 'virt-install 4.1.0\n'
    exit 0
fi
estado="$(cat "$PASSTHROUGH_TEST_ROOT/selo-vm.estado" 2>/dev/null || printf ausente)"
printf 'virt-install|selo=%s|%s\n' "$estado" "$*" >> "$ENTRYPOINT_LOG"
if [ "$estado" != selado ]; then
    printf 'escape|virt-install sem selo|estado=%s|%s\n' "$estado" "$*" >> "$ENTRYPOINT_LOG"
    exit 126
fi
exit 0
SCRIPT
for COMANDO_FAKE in virt-manager swtpm; do
    cat > "$BIN_EP/$COMANDO_FAKE" <<'SCRIPT'
#!/bin/bash
exit 0
SCRIPT
done
chmod +x "$BIN_EP"/*

preparar_perfil_ep() {
    local perfil="$1"
    cp "$FIXTURES/$perfil/os-release" "$ROOT_EP/etc/os-release"
}

escrever_conf_ep_basico() {
    cat > "$PROJETO_EP/passthrough.conf" <<'CONF'
USUARIO_LINUX="alice"
VM_STORAGE_GROUP="vm-passthrough"
CONF
}

escrever_conf_ep_40() {
    local qcow2="$1" iso_windows="$2" iso_virtio="$3"
    cat > "$PROJETO_EP/passthrough.conf" <<CONF
USUARIO_LINUX="alice"
VM_NAME="fixture"
VM_STORAGE_GROUP="vm-passthrough"
QCOW2_PATH="$qcow2"
QCOW2_TAMANHO="10G"
VM_RAM_MB="2048"
VM_VCPUS="2"
REDE_MODO="nat"
INTERFACE_FISICA="eth0"
ISO_WINDOWS="$iso_windows"
ISO_VIRTIO="$iso_virtio"
CONF
}

rodar_entrypoint_ep() {
    local etapa="$1" entrada="$2" saida="$3"
    shift 3
    printf '%b' "$entrada" | /usr/bin/timeout 20 /usr/bin/env -i \
        PATH="$BIN_EP" HOME="$ROOT_EP/home/alice" TMPDIR="$ROOT_EP/tmp" \
        LC_ALL=C LANG=C TERM=dumb USER=alice LOGNAME=alice \
        PASSTHROUGH_TEST_MODE=1 PASSTHROUGH_TEST_ROOT="$ROOT_EP" \
        ENTRYPOINT_LOG="$LOG_EP" \
        MOCK_SYSTEMD_MODE="${MOCK_SYSTEMD_MODE:-coexist-active}" \
        MOCK_VIRSH_RC="${MOCK_VIRSH_RC:-0}" MOCK_FWUPD_RC="${MOCK_FWUPD_RC:-2}" \
        MOCK_ID_GRUPOS_SESSAO="${MOCK_ID_GRUPOS_SESSAO:-alice libvirt kvm vm-passthrough}" \
        /bin/bash "$PROJETO_EP/etapas/$etapa" "$@" > "$saida" 2>&1
}

sem_escape_ep() {
    if grep -q '^escape|' "$LOG_EP"; then
        sed 's/^/  /' "$LOG_EP" >&2
        falha "um mock detectou escape no entrypoint: $1"
    fi
}

# Canários do próprio sandbox: PATH não contém host e sudo recusa alvo externo.
case ":$BIN_EP:" in *:/usr/bin:*|*:/bin:*) falha 'PATH do entrypoint não está fechado' ;; esac
: > "$LOG_EP"
set +e
ENTRYPOINT_LOG="$LOG_EP" PATH="$BIN_EP" apt install pacote-proibido >/dev/null 2>&1
RC_CANARIO_APT=$?
ENTRYPOINT_LOG="$LOG_EP" PASSTHROUGH_TEST_ROOT="$ROOT_EP" PATH="$BIN_EP" \
    sudo apt install -y pacote-proibido >/dev/null 2>&1
RC_CANARIO_SUDO_APT=$?
ENTRYPOINT_LOG="$LOG_EP" PASSTHROUGH_TEST_ROOT="$ROOT_EP" PATH="$BIN_EP" \
    sudo rm -f /etc/canario >/dev/null 2>&1
RC_CANARIO_SUDO=$?
set -e
igual "$RC_CANARIO_APT" 126 'canário apt escapou do PATH'
igual "$RC_CANARIO_SUDO_APT" 126 'canário sudo apt aceitou operação fora da allowlist'
igual "$RC_CANARIO_SUDO" 126 'canário sudo aceitou path externo'
grep -q '^escape|apt direto|' "$LOG_EP" || falha 'canário apt não foi registrado'
grep -q '^escape|sudo apt não permitido|' "$LOG_EP" \
    || falha 'canário sudo apt não foi registrado'
grep -q '^escape|sudo rm fora da raiz|' "$LOG_EP" || falha 'canário sudo não foi registrado'

# Etapa 11 real: Ubuntu consome ubuntu-drivers; Pop!_OS consome System76.
preparar_perfil_ep ubuntu
escrever_conf_ep_basico
: > "$LOG_EP"
rodar_entrypoint_ep 11-driver-nvidia.sh 'n\n' "$ROOT_EP/etapa11-ubuntu.out" \
    || falha "entrypoint 11 Ubuntu falhou: $(< "$ROOT_EP/etapa11-ubuntu.out")"
grep -Fq 'sudo|apt install -y nvidia-driver-555-open' "$LOG_EP" \
    || falha 'etapa 11 Ubuntu não consumiu o pacote recomendado'
sem_escape_ep 'etapa 11 Ubuntu'
preparar_perfil_ep pop-os
: > "$LOG_EP"
rodar_entrypoint_ep 11-driver-nvidia.sh 'n\n' "$ROOT_EP/etapa11-pop.out" \
    || falha "entrypoint 11 Pop!_OS falhou: $(< "$ROOT_EP/etapa11-pop.out")"
grep -Fq 'sudo|apt install -y system76-driver-nvidia' "$LOG_EP" \
    || falha 'etapa 11 Pop!_OS não consumiu o perfil System76'
sem_escape_ep 'etapa 11 Pop!_OS'

# Etapa 10 real em --verificar: consulta fwupd estritamente read-only.
preparar_perfil_ep ubuntu
: > "$LOG_EP"
MOCK_FWUPD_RC=2
export MOCK_FWUPD_RC
rodar_entrypoint_ep 10-atualizar-sistema.sh '' "$ROOT_EP/etapa10-ok.out" --verificar \
    || falha "verificador 10 sem updates falhou: $(< "$ROOT_EP/etapa10-ok.out")"
grep -Fxq 'fwupdmgr|get-updates' "$LOG_EP" || falha 'verificador 10 não chamou get-updates'
if grep -E '^fwupdmgr\|(refresh|update)|^sudo\|' "$LOG_EP"; then
    falha 'verificador 10 executou mutação/sudo'
fi
: > "$LOG_EP"
MOCK_FWUPD_RC=1
set +e
rodar_entrypoint_ep 10-atualizar-sistema.sh '' "$ROOT_EP/etapa10-erro.out" --verificar
RC_EP=$?
set -e
igual "$RC_EP" 3 'falha operacional fwupd no verificador 10'
contem "$(< "$ROOT_EP/etapa10-erro.out")" 'get-updates' 'diagnóstico fwupd read-only ausente'

# Etapa 10 real completa: somente a sequência mutante explicitamente permitida
# pode atravessar sudo; firmware percorre refresh, consulta e update.
: > "$LOG_EP"
MOCK_FWUPD_RC=0
export MOCK_FWUPD_RC
rodar_entrypoint_ep 10-atualizar-sistema.sh 'n\n' "$ROOT_EP/etapa10-fluxo.out" \
    || falha "entrypoint 10 completo falhou: $(< "$ROOT_EP/etapa10-fluxo.out") | chamadas: $(< "$LOG_EP")"
CHAMADAS_MUTANTES_10="$(grep -E '^sudo\|(apt|fwupdmgr)' "$LOG_EP")"
CHAMADAS_ESPERADAS_10=$'sudo|apt update\nsudo|apt full-upgrade -y\nsudo|apt autoremove -y\nsudo|apt install -y fwupd\nsudo|fwupdmgr refresh --force\nsudo|fwupdmgr get-updates\nsudo|fwupdmgr update'
igual "$CHAMADAS_MUTANTES_10" "$CHAMADAS_ESPERADAS_10" \
    'etapa 10 divergiu da sequência APT/fwupd exata'
grep -Fxq 'uname|-r' "$LOG_EP" || falha 'etapa 10 não usou o uname hermético'
grep -Fxq 'dpkg|-l' "$LOG_EP" || falha 'etapa 10 não usou o dpkg hermético'
if grep -Eq '^sudo\|reboot$|^apt\||^fwupdmgr\|' "$LOG_EP"; then
    falha 'etapa 10 escapou dos mocks sudo ou tentou reboot'
fi
sem_escape_ep 'etapa 10 fluxo principal'

# Etapa 20 real: socket habilitável, perfil Ubuntu e URI fatal.
escrever_conf_ep_basico
: > "$LOG_EP"
MOCK_SYSTEMD_MODE=socket MOCK_VIRSH_RC=0 MOCK_FWUPD_RC=2
export MOCK_SYSTEMD_MODE MOCK_VIRSH_RC MOCK_FWUPD_RC
rodar_entrypoint_ep 20-virtualizacao.sh '' "$ROOT_EP/etapa20-ok.out" \
    || falha "entrypoint 20 falhou: $(< "$ROOT_EP/etapa20-ok.out")"
grep -Fq 'sudo|apt install -y qemu-system-x86 ' "$LOG_EP" \
    || falha 'etapa 20 não consumiu o pacote QEMU do perfil Ubuntu'
grep -Fxq 'sudo|systemctl enable --now virtqemud.socket' "$LOG_EP" \
    || falha 'etapa 20 não ativou o socket modular resolvido'
grep -Fxq 'sudo|virsh --connect qemu:///system list --all' "$LOG_EP" \
    || falha 'etapa 20 não exigiu a URI como pós-condição'
sem_escape_ep 'etapa 20 sucesso'
: > "$LOG_EP"
MOCK_SYSTEMD_MODE=coexist-active MOCK_VIRSH_RC=1
export MOCK_SYSTEMD_MODE MOCK_VIRSH_RC
set +e
rodar_entrypoint_ep 20-virtualizacao.sh '' "$ROOT_EP/etapa20-verificar-erro.out" --verificar
RC_EP=$?
set -e
igual "$RC_EP" 3 'URI libvirt falha não foi fatal em --verificar'
contem "$(< "$ROOT_EP/etapa20-verificar-erro.out")" 'Pós-condição fatal' \
    'diagnóstico fatal da URI ausente no verificador 20'
: > "$LOG_EP"
MOCK_ID_GRUPOS_SESSAO='alice'
export MOCK_ID_GRUPOS_SESSAO
set +e
rodar_entrypoint_ep 20-virtualizacao.sh '' "$ROOT_EP/etapa20-verificar-sessao.out" --verificar
RC_EP=$?
set -e
igual "$RC_EP" 1 'sessão sem o grupo libvirt virou erro em vez de pendência'
contem "$(< "$ROOT_EP/etapa20-verificar-sessao.out")" 'logout/login' \
    'verificador 20 não orientou a sessão nova'
if grep -Fq 'Pós-condição fatal' "$ROOT_EP/etapa20-verificar-sessao.out"; then
    falha 'pendência de sessão foi anunciada como pós-condição fatal'
fi
unset MOCK_ID_GRUPOS_SESSAO
: > "$LOG_EP"
MOCK_SYSTEMD_MODE=socket
set +e
rodar_entrypoint_ep 20-virtualizacao.sh '' "$ROOT_EP/etapa20-exec-erro.out"
RC_EP=$?
set -e
[ "$RC_EP" -ne 0 ] || falha 'etapa 20 concluiu após falha da URI'
contem "$(< "$ROOT_EP/etapa20-exec-erro.out")" 'Pós-condição fatal' \
    'execução 20 perdeu diagnóstico da URI'
sem_escape_ep 'etapa 20 URI falha'

verificar_systemctl_erro_ep() {
    local etapa="$1" modo="$2" diagnostico="$3" rotulo="$4" saida rc
    saida="$ROOT_EP/${etapa%%-*}-systemctl-$modo.out"
    : > "$LOG_EP"
    MOCK_SYSTEMD_MODE="$modo" MOCK_VIRSH_RC=0
    export MOCK_SYSTEMD_MODE MOCK_VIRSH_RC
    set +e
    rodar_entrypoint_ep "$etapa" '' "$saida" --verificar
    rc=$?
    set -e
    igual "$rc" 3 "$rotulo"
    contem "$(< "$saida")" "$diagnostico" "$rotulo sem diagnóstico"
    sem_escape_ep "$rotulo"
}
verificar_systemctl_erro_ep 20-virtualizacao.sh falha \
    'Falha operacional ao consultar' 'etapa 20 rebaixou falha systemctl'
verificar_systemctl_erro_ep 20-virtualizacao.sh incompleto \
    'Resposta systemd incompleta' 'etapa 20 rebaixou resposta systemctl incompleta'

# Etapa 21 real: qemu.conf escolhe qemu com ambas as contas, usa canários
# O_EXCL e prova ACL/grupo sem seguir colisões simbólicas preexistentes.
CANARIO_EP="$TMPDIR_TESTE/canario-fora-raiz"
printf 'NAO-ALTERAR\n' > "$CANARIO_EP"
chmod 0640 "$CANARIO_EP"
HASH_CANARIO_EP="$(sha256sum "$CANARIO_EP" | awk '{print $1}')"
MODO_CANARIO_EP="$(stat -c '%a' "$CANARIO_EP")"
CANARIO_LINK_OPERADOR="$ROOT_EP/vm/.teste-operador.AAAAAA"
CANARIO_LINK_QEMU="$ROOT_EP/vm/.teste-qemu.AAAAAA"
ln -s "$CANARIO_EP" "$CANARIO_LINK_OPERADOR"
ln -s "$CANARIO_EP" "$CANARIO_LINK_QEMU"
cat > "$ROOT_EP/etc/libvirt/qemu.conf" <<'CONF'
user = "qemu"
user = "libvirt-qemu"
CONF
escrever_conf_ep_basico
: > "$LOG_EP"
MOCK_SYSTEMD_MODE=coexist-active MOCK_VIRSH_RC=0
export MOCK_SYSTEMD_MODE MOCK_VIRSH_RC
set +e
rodar_entrypoint_ep 21-usuario-grupos.sh '' "$ROOT_EP/etapa21-qemu-conf-invalido.out" --verificar
RC_EP=$?
set -e
igual "$RC_EP" 3 'etapa 21 rebaixou qemu.conf duplicado'
contem "$(< "$ROOT_EP/etapa21-qemu-conf-invalido.out")" 'identidade QEMU ambígua' \
    'etapa 21 perdeu diagnóstico de qemu.conf duplicado'
sem_escape_ep 'etapa 21 qemu.conf inválido'

cat > "$ROOT_EP/etc/libvirt/qemu.conf" <<'CONF'
user = "qemu"
CONF
verificar_systemctl_erro_ep 21-usuario-grupos.sh falha \
    'Falha operacional ao consultar' 'etapa 21 rebaixou falha systemctl'
verificar_systemctl_erro_ep 21-usuario-grupos.sh incompleto \
    'Resposta systemd incompleta' 'etapa 21 rebaixou resposta systemctl incompleta'
: > "$LOG_EP"
MOCK_SYSTEMD_MODE=coexist-active MOCK_VIRSH_RC=0
export MOCK_SYSTEMD_MODE MOCK_VIRSH_RC
rodar_entrypoint_ep 21-usuario-grupos.sh '' "$ROOT_EP/etapa21.out" \
    || falha "entrypoint 21 falhou: $(< "$ROOT_EP/etapa21.out")"
grep -Fxq 'sudo|usermod -aG vm-passthrough qemu' "$LOG_EP" \
    || falha 'etapa 21 não usou a identidade explícita qemu'
if grep -Fxq 'sudo|usermod -aG vm-passthrough libvirt-qemu' "$LOG_EP"; then
    falha 'etapa 21 voltou a escolher a primeira conta NSS'
fi
grep -Fq "sudo|chown root:vm-passthrough $ROOT_EP/vm" "$LOG_EP" \
    || falha 'etapa 21 não convergiu o grupo na raiz simulada'
grep -Fq "sudo|setfacl -m d:u::rwx,d:g::rwx,d:m::rwx,d:o::--- -- $ROOT_EP/vm" "$LOG_EP" \
    || falha 'etapa 21 não aplicou ACL default na raiz simulada'
grep -Fxq 'sudo|-u alice virsh --connect qemu:///system list --all' "$LOG_EP" \
    || falha 'etapa 21 não comprovou a URI como operador'
grep -Fxq "sudo|chmod 2750 $ROOT_EP/vm" "$LOG_EP" \
    || falha 'etapa 21 não selou /vm durante as provas cruzadas'
grep -Fxq "sudo|chmod 2770 $ROOT_EP/vm" "$LOG_EP" \
    || falha 'etapa 21 não restaurou /vm após as provas cruzadas'
igual "$(< "$ROOT_EP/selo-vm.estado")" aberto 'etapa 21 deixou /vm selado'
[ -L "$CANARIO_LINK_OPERADOR" ] && [ -L "$CANARIO_LINK_QEMU" ] \
    || falha 'mktemp/limpeza da etapa 21 removeu uma colisão simbólica preexistente'
igual "$(sha256sum "$CANARIO_EP" | awk '{print $1}')" "$HASH_CANARIO_EP" \
    'mktemp da etapa 21 truncou o alvo de um symlink preexistente'
igual "$(stat -c '%a' "$CANARIO_EP")" "$MODO_CANARIO_EP" \
    'etapa 21 alterou o modo do alvo de um symlink preexistente'
rm -f -- "$CANARIO_LINK_OPERADOR" "$CANARIO_LINK_QEMU"
sem_escape_ep 'etapa 21'

# Etapa 40 real: traversal, vírgula, symlink, hardlink e ambas as ISOs
# falham antes de sudo; o cenário válido consome os artefatos sob selo.
printf 'ISO-WINDOWS\n' > "$ROOT_EP/vm/windows.iso"
printf 'ISO-VIRTIO\n' > "$ROOT_EP/vm/virtio.iso"
chmod 0660 "$ROOT_EP/vm/windows.iso" "$ROOT_EP/vm/virtio.iso"

cat > "$ROOT_EP/etc/libvirt/qemu.conf" <<'CONF'
user = "qemu"
user = "libvirt-qemu"
CONF
escrever_conf_ep_40 '/vm/Windows11.qcow2' '/vm/windows.iso' '/vm/virtio.iso'
: > "$LOG_EP"
set +e
rodar_entrypoint_ep 40-criar-vm.sh '' "$ROOT_EP/etapa40-qemu-conf-invalido.out" --verificar
RC_EP=$?
set -e
igual "$RC_EP" 3 'etapa 40 rebaixou qemu.conf duplicado'
contem "$(< "$ROOT_EP/etapa40-qemu-conf-invalido.out")" 'identidade QEMU ambígua' \
    'etapa 40 perdeu diagnóstico de qemu.conf duplicado'
sem_escape_ep 'etapa 40 qemu.conf inválido'
cat > "$ROOT_EP/etc/libvirt/qemu.conf" <<'CONF'
user = "qemu"
CONF

escrever_conf_ep_40 '/vm/../canario-fora-raiz' '/vm/windows.iso' '/vm/virtio.iso'
: > "$LOG_EP"
set +e
rodar_entrypoint_ep 40-criar-vm.sh '' "$ROOT_EP/etapa40-traversal.out"
RC_EP=$?
set -e
[ "$RC_EP" -ne 0 ] || falha 'etapa 40 aceitou traversal em QCOW2_PATH'
if grep -q '^sudo|' "$LOG_EP"; then falha 'traversal alcançou sudo na etapa 40'; fi

ln -s "$CANARIO_EP" "$ROOT_EP/vm/Windows11.qcow2"
escrever_conf_ep_40 '/vm/Windows11.qcow2' '/vm/windows.iso' '/vm/virtio.iso'
: > "$LOG_EP"
set +e
rodar_entrypoint_ep 40-criar-vm.sh '' "$ROOT_EP/etapa40-symlink.out"
RC_EP=$?
set -e
[ "$RC_EP" -ne 0 ] || falha 'etapa 40 aceitou symlink de QCOW2'
contem "$(< "$ROOT_EP/etapa40-symlink.out")" 'link simbólico' 'symlink QCOW2 sem diagnóstico'
if grep -q '^sudo|' "$LOG_EP"; then falha 'symlink QCOW2 alcançou sudo'; fi
rm -f "$ROOT_EP/vm/Windows11.qcow2"

ln "$CANARIO_EP" "$ROOT_EP/vm/Windows11.qcow2"
: > "$LOG_EP"
set +e
rodar_entrypoint_ep 40-criar-vm.sh '' "$ROOT_EP/etapa40-hardlink.out"
RC_EP=$?
set -e
[ "$RC_EP" -ne 0 ] || falha 'etapa 40 aceitou hardlink de QCOW2'
contem "$(< "$ROOT_EP/etapa40-hardlink.out")" 'hardlinks' 'hardlink QCOW2 sem diagnóstico'
if grep -q '^sudo|' "$LOG_EP"; then falha 'hardlink QCOW2 alcançou sudo'; fi
rm -f "$ROOT_EP/vm/Windows11.qcow2"

escrever_conf_ep_40 '/vm/Windows11,format=raw.qcow2' '/vm/windows.iso' '/vm/virtio.iso'
: > "$LOG_EP"
set +e
rodar_entrypoint_ep 40-criar-vm.sh '' "$ROOT_EP/etapa40-virgula-qcow2.out"
RC_EP=$?
set -e
[ "$RC_EP" -ne 0 ] || falha 'etapa 40 aceitou vírgula em QCOW2_PATH'
if grep -q '^sudo|' "$LOG_EP"; then falha 'vírgula em QCOW2_PATH alcançou sudo'; fi

printf 'QCOW2-FIXTURE\n' > "$ROOT_EP/vm/Windows11.qcow2"
chmod 0660 "$ROOT_EP/vm/Windows11.qcow2"
escrever_conf_ep_40 '/vm/Windows11.qcow2' '/vm/windows,device=cdrom.iso' '/vm/virtio.iso'
: > "$LOG_EP"
set +e
rodar_entrypoint_ep 40-criar-vm.sh '\n' "$ROOT_EP/etapa40-virgula-windows.out"
RC_EP=$?
set -e
[ "$RC_EP" -ne 0 ] || falha 'etapa 40 aceitou vírgula em ISO_WINDOWS'
if grep -q '^sudo|' "$LOG_EP"; then falha 'vírgula em ISO_WINDOWS alcançou sudo'; fi

escrever_conf_ep_40 '/vm/Windows11.qcow2' '/vm/windows.iso' '/vm/virtio,device=cdrom.iso'
: > "$LOG_EP"
set +e
rodar_entrypoint_ep 40-criar-vm.sh '\n' "$ROOT_EP/etapa40-virgula-virtio.out"
RC_EP=$?
set -e
[ "$RC_EP" -ne 0 ] || falha 'etapa 40 aceitou vírgula em ISO_VIRTIO'
if grep -q '^sudo|' "$LOG_EP"; then falha 'vírgula em ISO_VIRTIO alcançou sudo'; fi

rm -f "$ROOT_EP/vm/windows.iso"
ln -s "$CANARIO_EP" "$ROOT_EP/vm/windows.iso"
escrever_conf_ep_40 '/vm/Windows11.qcow2' '/vm/windows.iso' '/vm/virtio.iso'
: > "$LOG_EP"
set +e
rodar_entrypoint_ep 40-criar-vm.sh '\n' "$ROOT_EP/etapa40-iso-windows.out"
RC_EP=$?
set -e
[ "$RC_EP" -ne 0 ] || falha 'etapa 40 aceitou symlink ISO_WINDOWS'
if grep -q '^sudo|' "$LOG_EP"; then falha 'symlink ISO_WINDOWS alcançou sudo'; fi
rm -f "$ROOT_EP/vm/windows.iso"
printf 'ISO-WINDOWS\n' > "$ROOT_EP/vm/windows.iso"
chmod 0660 "$ROOT_EP/vm/windows.iso"
rm -f "$ROOT_EP/vm/virtio.iso"
ln -s "$CANARIO_EP" "$ROOT_EP/vm/virtio.iso"
escrever_conf_ep_40 '/vm/Windows11.qcow2' '/vm/windows.iso' '/vm/virtio.iso'
: > "$LOG_EP"
set +e
rodar_entrypoint_ep 40-criar-vm.sh '\n' "$ROOT_EP/etapa40-iso-virtio.out"
RC_EP=$?
set -e
[ "$RC_EP" -ne 0 ] || falha 'etapa 40 aceitou symlink ISO_VIRTIO'
if grep -q '^sudo|' "$LOG_EP"; then falha 'symlink ISO_VIRTIO alcançou sudo'; fi
rm -f "$ROOT_EP/vm/virtio.iso"
printf 'ISO-VIRTIO\n' > "$ROOT_EP/vm/virtio.iso"
chmod 0660 "$ROOT_EP/vm/virtio.iso"

# Sucesso real do entrypoint partindo de QCOW2 ausente. Antes, a allowlist
# comprova que uma shell diferente não é executada pelo mock de sudo.
rm -f "$ROOT_EP/vm/Windows11.qcow2"
: > "$LOG_EP"
set +e
ENTRYPOINT_LOG="$LOG_EP" PASSTHROUGH_TEST_ROOT="$ROOT_EP" PATH="$BIN_EP" \
    sudo -u qemu sh -c 'printf ATAQUE > "$1"' _ "$CANARIO_EP" 10G \
    >/dev/null 2>&1
RC_CANARIO_QCOW2=$?
set -e
igual "$RC_CANARIO_QCOW2" 126 'mock sudo aceitou publicador QCOW2 não autorizado'
grep -q '^escape|sudo sh não permitido|' "$LOG_EP" \
    || falha 'recusa do publicador QCOW2 não autorizado não foi registrada'
igual "$(sha256sum "$CANARIO_EP" | awk '{print $1}')" "$HASH_CANARIO_EP" \
    'shell QCOW2 recusada alterou o canário externo'

# O mock aceita somente o script literal de produção como qemu, cria o fixture,
# exige validação de formato e a etapa o consome com /vm em 2750, restaurando 2770.
escrever_conf_ep_40 '/vm/Windows11.qcow2' '/vm/windows.iso' '/vm/virtio.iso'
printf 'aberto\n' > "$ROOT_EP/selo-vm.estado"
: > "$LOG_EP"
rodar_entrypoint_ep 40-criar-vm.sh 'n\n' "$ROOT_EP/etapa40-sucesso.out" \
    || falha "entrypoint 40 válido falhou: $(< "$ROOT_EP/etapa40-sucesso.out") | chamadas: $(< "$LOG_EP")"
mapfile -t CHAMADAS_CREATE_QCOW2 < <(grep '^qemu-img|create ' "$LOG_EP")
igual "${#CHAMADAS_CREATE_QCOW2[@]}" 1 'criação QCOW2 não ocorreu exatamente uma vez'
case "${CHAMADAS_CREATE_QCOW2[0]}" in
    "qemu-img|create -f qcow2 $ROOT_EP/vm/.Windows11.qcow2.novo."??????" 10G") ;;
    *) falha "qemu-img create saiu do temporário confinado: ${CHAMADAS_CREATE_QCOW2[0]}" ;;
esac
grep -Fq "qemu-img|info --output=json $ROOT_EP/vm/.Windows11.qcow2.novo." "$LOG_EP" \
    || falha 'QCOW2 temporário não teve formato validado antes da publicação'
[ -f "$ROOT_EP/vm/Windows11.qcow2" ] && [ ! -L "$ROOT_EP/vm/Windows11.qcow2" ] \
    || falha 'script seguro não publicou o QCOW2 regular'
igual "$(< "$ROOT_EP/vm/Windows11.qcow2")" 'QCOW2-FIXTURE' \
    'mock qemu-img não publicou o conteúdo fixture'
igual "$(/usr/bin/stat -c '%a' "$ROOT_EP/vm/Windows11.qcow2")" 660 \
    'QCOW2 novo não terminou em modo 0660'
if compgen -G "$ROOT_EP/vm/.Windows11.qcow2.novo.*" >/dev/null; then
    falha 'temporário QCOW2 permaneceu após a publicação atômica'
fi
grep -Fq "virt-install|selo=selado|--connect qemu:///system --name fixture" "$LOG_EP" \
    || falha 'virt-install não observou /vm selado durante o consumo'
grep -Fq -- "--disk path=$ROOT_EP/vm/Windows11.qcow2,format=qcow2,bus=virtio,cache=none" "$LOG_EP" \
    || falha 'virt-install não recebeu o QCOW2 físico validado'
grep -Fq -- "--disk path=$ROOT_EP/vm/windows.iso,device=cdrom,bus=sata" "$LOG_EP" \
    || falha 'virt-install não recebeu ISO_WINDOWS direta de /vm'
grep -Fq -- "--disk path=$ROOT_EP/vm/virtio.iso,device=cdrom,bus=sata" "$LOG_EP" \
    || falha 'virt-install não recebeu ISO_VIRTIO direta de /vm'
grep -Fxq "sudo|chmod 2750 $ROOT_EP/vm" "$LOG_EP" \
    || falha 'etapa 40 não selou /vm antes do virt-install'
grep -Fxq "sudo|chmod 2770 $ROOT_EP/vm" "$LOG_EP" \
    || falha 'etapa 40 não restaurou /vm depois do virt-install'
igual "$(< "$ROOT_EP/selo-vm.estado")" aberto 'etapa 40 não restaurou /vm após sucesso'
grep -Fq 'VM_NIC_MAC="52:54:00:12:34:56"' "$PROJETO_EP/passthrough.conf" \
    || falha 'etapa 40 não persistiu o MAC validado do XML real simulado'
sem_escape_ep 'etapa 40 com QCOW2 novo'

# Preserve também o sucesso anterior com QCOW2 já criado: o segundo fluxo não
# pode recriar nem alterar o artefato, mas ainda deve selar e restaurar /vm.
HASH_QCOW2_EXISTENTE="$(sha256sum "$ROOT_EP/vm/Windows11.qcow2" | awk '{print $1}')"
FINGERPRINT_QCOW2_EXISTENTE="$(/usr/bin/stat -Lc '%d:%i:%s:%Y:%Z:%h' "$ROOT_EP/vm/Windows11.qcow2")"
MODO_QCOW2_EXISTENTE="$(/usr/bin/stat -c '%a' "$ROOT_EP/vm/Windows11.qcow2")"
printf 'aberto\n' > "$ROOT_EP/selo-vm.estado"
: > "$LOG_EP"
rodar_entrypoint_ep 40-criar-vm.sh 'n\n' "$ROOT_EP/etapa40-existente-sucesso.out" \
    || falha "entrypoint 40 com QCOW2 existente falhou: $(< "$ROOT_EP/etapa40-existente-sucesso.out") | chamadas: $(< "$LOG_EP")"
if grep -q '^qemu-img|create ' "$LOG_EP"; then
    falha 'etapa 40 recriou um QCOW2 existente'
fi
igual "$(sha256sum "$ROOT_EP/vm/Windows11.qcow2" | awk '{print $1}')" \
    "$HASH_QCOW2_EXISTENTE" 'etapa 40 alterou o conteúdo do QCOW2 existente'
igual "$(/usr/bin/stat -Lc '%d:%i:%s:%Y:%Z:%h' "$ROOT_EP/vm/Windows11.qcow2")" \
    "$FINGERPRINT_QCOW2_EXISTENTE" 'etapa 40 trocou ou alterou o QCOW2 existente'
igual "$(/usr/bin/stat -c '%a' "$ROOT_EP/vm/Windows11.qcow2")" \
    "$MODO_QCOW2_EXISTENTE" 'etapa 40 alterou o modo do QCOW2 existente'
grep -Fq "virt-install|selo=selado|--connect qemu:///system --name fixture" "$LOG_EP" \
    || falha 'QCOW2 existente não foi consumido sob /vm selado'
grep -Fxq "sudo|chmod 2750 $ROOT_EP/vm" "$LOG_EP" \
    || falha 'etapa 40 não selou /vm ao consumir QCOW2 existente'
grep -Fxq "sudo|chmod 2770 $ROOT_EP/vm" "$LOG_EP" \
    || falha 'etapa 40 não restaurou /vm após consumir QCOW2 existente'
igual "$(< "$ROOT_EP/selo-vm.estado")" aberto \
    'etapa 40 não restaurou 2770 após consumir QCOW2 existente'
sem_escape_ep 'etapa 40 com QCOW2 existente'

igual "$(sha256sum "$CANARIO_EP" | awk '{print $1}')" "$HASH_CANARIO_EP" \
    'conteúdo do canário externo foi alterado'
igual "$(stat -c '%a' "$CANARIO_EP")" "$MODO_CANARIO_EP" \
    'modo do canário externo foi alterado'
sem_escape_ep 'etapa 40'

# Smoke do menu real: todos os --verificar usam a mesma raiz hermética e PATH
# fechado; RC 3 é esperado porque a configuração de fixture é incompleta.
: > "$LOG_EP"
set +e
/usr/bin/timeout 60 /usr/bin/env -i \
    PATH="$BIN_EP" HOME="$ROOT_EP/home/alice" TMPDIR="$ROOT_EP/tmp" \
    LC_ALL=C LANG=C TERM=dumb USER=alice LOGNAME=alice \
    PASSTHROUGH_TEST_MODE=1 PASSTHROUGH_TEST_ROOT="$ROOT_EP" \
    ENTRYPOINT_LOG="$LOG_EP" MOCK_SYSTEMD_MODE=coexist-active \
    MOCK_VIRSH_RC=0 MOCK_FWUPD_RC=2 \
    /bin/bash "$RAIZ/menu.sh" --status > "$ROOT_EP/menu-status-real.out" 2>&1
MENU_REAL_RC=$?
set -e
igual "$MENU_REAL_RC" 3 'smoke do menu.sh --status real'
contem "$(< "$ROOT_EP/menu-status-real.out")" 'Legenda:' \
    'smoke do menu real não apresentou a legenda final'
if grep -q '^sudo|' "$LOG_EP"; then
    falha 'menu.sh --status real tentou adquirir ou executar sudo'
fi
if grep -E '^fwupdmgr\|(refresh|update)|^apt\|' "$LOG_EP"; then
    falha 'menu.sh --status real tentou operação mutante de atualização'
fi

# --- LIM-001: AMD funciona; Intel bloqueia antes de qualquer mutação ----------
BIN_CPU="$TMPDIR_TESTE/bin-cpu"
mkdir -p "$BIN_CPU"
cat > "$BIN_CPU/lscpu" <<'SCRIPT'
#!/bin/bash
cat <<'CPU'
Architecture:                         x86_64
CPU(s):                               16
Vendor ID:                            AuthenticAMD
Model name:                           Fixture CPU
CPU
SCRIPT
chmod +x "$BIN_CPU/lscpu"
PATH="$BIN_CPU:$PATH_ORIGINAL" plataforma_detectar_cpu_vendor \
    || falha "$PLATAFORMA_ERRO"
igual "$PLATAFORMA_CPU_VENDOR" AuthenticAMD 'detecção AMD via lscpu estável'
if plataforma_validar_cpu_amd GenuineIntel; then
    falha 'CPU Intel foi aceita pela implementação AMD-only'
fi
contem "$PLATAFORMA_ERRO" 'não sofrerão qualquer mutação' 'bloqueio Intel sem diagnóstico explícito'
ETAPA_30="$RAIZ/etapas/30-iommu-vfio.sh"
LINHA_GUARDA="$(grep -n '^validar_cpu_amd_suportada || falhar' "$ETAPA_30" | cut -d: -f1)"
LINHA_NAO_ROOT="$(grep -n '^exigir_nao_root$' "$ETAPA_30" | cut -d: -f1)"
LINHA_SUDO="$(grep -n '^exigir_sudo$' "$ETAPA_30" | cut -d: -f1)"
[[ "$LINHA_GUARDA" =~ ^[0-9]+$ && "$LINHA_NAO_ROOT" =~ ^[0-9]+$ && "$LINHA_SUDO" =~ ^[0-9]+$ ]] \
    || falha 'não foi possível provar a ordem da guarda Intel'
[ "$LINHA_GUARDA" -lt "$LINHA_NAO_ROOT" ] && [ "$LINHA_GUARDA" -lt "$LINHA_SUDO" ] \
    || falha 'guarda AMD-only ocorre depois de pré-requisitos mutantes/sudo'

# --- Prompt opcional de ISO da etapa 02 nunca aborta pela política /vm --------
# Regressão do incidente de 16/08/2026: um caminho de ISO existente fora de
# /vm chegava a salvar_conf e derrubava a detecção inteira com
# "Valor inválido para a chave 'ISO_WINDOWS'", sem explicar a política.
CONF_ARQUIVO_ORIGINAL="$CONF_ARQUIVO"
CONF_ARQUIVO="$TMPDIR_TESTE/conf-iso-opcional.conf"
printf '# conf de teste do prompt de ISO\n' > "$CONF_ARQUIVO"

classificar_iso_opcional_conf '' || falha 'classificador recusou valor vazio'
igual "$ISO_OPCIONAL_ESTADO" vazia 'estado do classificador para valor vazio'

ISO_FORA_VM="$TMPDIR_TESTE/win11 em outro lugar.iso"
: > "$ISO_FORA_VM"
if classificar_iso_opcional_conf "$ISO_FORA_VM"; then
    falha 'ISO existente fora de /vm foi aceita pelo classificador'
fi
contem "$ISO_OPCIONAL_ERRO" 'filho direto' 'recusa fora de /vm sem diagnóstico da política'

if classificar_iso_opcional_conf '/vm/a,b.iso'; then
    falha 'ISO com vírgula foi aceita pelo classificador'
fi

classificar_iso_opcional_conf "/vm/iso-inexistente-teste-$$.iso" \
    || falha "caminho /vm válido porém ausente foi recusado: $ISO_OPCIONAL_ERRO"
igual "$ISO_OPCIONAL_ESTADO" ausente 'estado do classificador para arquivo ausente'

SAIDA_ISO="$(printf '%s\n\n' "$ISO_FORA_VM" \
    | perguntar_iso_opcional_conf ISO_WINDOWS 'ISO do Windows 11' 2>&1)" \
    || falha 'prompt opcional abortou diante de caminho existente fora de /vm'
contem "$SAIDA_ISO" 'filho direto' 'prompt não explicou a política /vm ao recusar'
contem "$SAIDA_ISO" 'etapa 12' 'prompt não orientou a decisão adiada para a etapa 12'
grep -qx 'ISO_WINDOWS=""' "$CONF_ARQUIVO" \
    || falha 'ISO_WINDOWS não ficou vazia após recusa seguida de ENTER'

SAIDA_ISO="$(printf '%s\n%s\n%s\n%s\n%s\n' \
    "$ISO_FORA_VM" "$ISO_FORA_VM" "$ISO_FORA_VM" "$ISO_FORA_VM" "$ISO_FORA_VM" \
    | perguntar_iso_opcional_conf ISO_VIRTIO 'ISO virtio-win' 2>&1)" \
    || falha 'prompt opcional abortou após cinco recusas consecutivas'
contem "$SAIDA_ISO" 'Cinco tentativas' 'limite de tentativas não foi comunicado'
grep -qx 'ISO_VIRTIO=""' "$CONF_ARQUIVO" \
    || falha 'ISO_VIRTIO não ficou vazia após o limite de tentativas'

SISTEMA_RAIZ_TESTE_ORIGINAL_ISO="$SISTEMA_RAIZ_TESTE"
SISTEMA_RAIZ_TESTE="$(readlink -f -- "$TMPDIR_TESTE")/raiz-iso"
mkdir -p "$SISTEMA_RAIZ_TESTE/vm"
: > "$SISTEMA_RAIZ_TESTE/vm/Win11.iso"
classificar_iso_opcional_conf /vm/Win11.iso \
    || falha "ISO regular em /vm foi recusada: $ISO_OPCIONAL_ERRO"
igual "$ISO_OPCIONAL_ESTADO" valida 'estado do classificador para ISO regular em /vm'
SAIDA_ISO="$(printf '/vm/Win11.iso\n' \
    | perguntar_iso_opcional_conf ISO_WINDOWS 'ISO do Windows 11' 2>&1)" \
    || falha 'prompt opcional recusou ISO regular válida em /vm'
contem "$SAIDA_ISO" 'validada sem links' 'confirmação da ISO válida ausente'
grep -qx 'ISO_WINDOWS="/vm/Win11.iso"' "$CONF_ARQUIVO" \
    || falha 'caminho válido de /vm não foi persistido'
SISTEMA_RAIZ_TESTE="$SISTEMA_RAIZ_TESTE_ORIGINAL_ISO"

CONF_ARQUIVO="$CONF_ARQUIVO_ORIGINAL"

# --- perguntar_validado repergunta em vez de estourar em salvar_conf ----------
perguntar_validado 'Nome da VM no libvirt' 'win11' nome_vm_valido 'Nome de VM inválido' \
    < <(printf 'nome com espaço\nvm-ok\n') > "$TMPDIR_TESTE/pv-aceita.out" 2>&1 \
    || falha 'perguntar_validado recusou entrada válida depois de uma recusa'
igual "$PERGUNTA_VALIDADA" vm-ok 'PERGUNTA_VALIDADA após aceitação'
contem "$(< "$TMPDIR_TESTE/pv-aceita.out")" 'Nome de VM inválido' \
    'recusa de perguntar_validado sem a mensagem do chamador'

set +e
perguntar_validado 'Nome da VM no libvirt' '' nome_vm_valido 'Nome de VM inválido' \
    < <(printf 'a b\na b\na b\na b\na b\n') > "$TMPDIR_TESTE/pv-limite.out" 2>&1
RC_PV=$?
set -e
igual "$RC_PV" 1 'limite de cinco recusas de perguntar_validado'
igual "$PERGUNTA_VALIDADA" '' 'PERGUNTA_VALIDADA vazia após o limite'

set +e
perguntar_validado 'Pergunta' '' validador_inexistente_xyz 'mensagem' \
    </dev/null > "$TMPDIR_TESTE/pv-validador.out" 2>&1
RC_PV=$?
set -e
igual "$RC_PV" 1 'validador desconhecido deve ser recusado'
contem "$(< "$TMPDIR_TESTE/pv-validador.out")" 'Validador desconhecido' \
    'diagnóstico de validador desconhecido ausente'

printf '%s\n' UBUNTU_AUDIT_REGRESSION_TESTS_OK
