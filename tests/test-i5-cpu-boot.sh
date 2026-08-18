#!/usr/bin/env bash
# ============================================================================
# tests/test-i5-cpu-boot.sh - fase I5: CPU/RAM/HugePages no core e REQ-IOMMU-TX
# ============================================================================
# Hermético: nenhuma escrita fora da raiz temporária, nenhum sudo real, nenhum
# comando de boot do host. O `sudo` do PATH é o mock confinado exigido por
# inicializar_raiz_teste, e /etc/default/grub, /boot/grub/grub.cfg e
# /etc/modules-load.d/vfio.conf são materializados dentro da raiz de teste.
#
# O que este arquivo prova, além do que a campanha I0 já cobre pela etapa 30:
#
#   * o bloco gerenciado de vfio.conf preserva conteúdo de terceiros, absorve o
#     formato antigo sem duplicar módulo e é idempotente;
#   * "ativo neste boot" e "persistido para o próximo" são medidos separadamente
#     e nenhuma combinação parcial vira convergência;
#   * falha em cada janela da transação restaura todos os recursos e prova a
#     restauração; rollback não comprovado é erro grave, não aviso;
#   * a revalidação TOCTOU das etapas 52/53 bloqueia aplicar plano calculado
#     sobre topologia obsoleta;
#   * não sobrou implementação mutante paralela em lib/common.sh.
# ============================================================================
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMPDIR_TESTE="$(mktemp -d "${TMPDIR:-/tmp}/i5-cpu-boot.XXXXXXXX")"
trap 'rm -rf -- "$TMPDIR_TESTE"' EXIT

CHECKS=0
falha() {
    printf 'FALHA I5: %s\n' "$*" >&2
    exit 1
}
passou() { CHECKS=$((CHECKS + 1)); }
igual() {
    local esperado="$1" obtido="$2" descricao="$3"
    [ "$esperado" = "$obtido" ] \
        || falha "$descricao (esperado=[$esperado]; obtido=[$obtido])"
}
contem() {
    local texto="$1" trecho="$2" descricao="$3"
    case "$texto" in
        *"$trecho"*) ;;
        *) falha "$descricao (não encontrei [$trecho] em [$texto])" ;;
    esac
}
esperar_falha() {
    local descricao="$1"
    shift
    if "$@"; then
        falha "$descricao deveria ter sido recusado"
    fi
}

# --- Raiz hermética -----------------------------------------------------------
ROOT="$TMPDIR_TESTE/raiz"
BIN="$ROOT/bin"
mkdir -p "$BIN" "$ROOT/etc/default" "$ROOT/etc/modules-load.d" \
    "$ROOT/boot/grub" "$ROOT/proc" "$ROOT/estado"
for COMANDO in awk basename cat chmod cmp cp cut date dirname grep head ln ls \
    mkdir mktemp mv printf python3 readlink rm sed sort stat tail tee touch tr wc; do
    CAMINHO="$(type -P "$COMANDO" || true)"
    [ -n "$CAMINHO" ] || falha "comando base ausente no host de teste: $COMANDO"
    ln -sf "$CAMINHO" "$BIN/$COMANDO"
done

# `update-grub` regenera o grub.cfg a partir da fonte, como o comando real;
# `update-initramfs` só registra que rodou. Ambos honram injeção de falha por
# arquivo-sinalizador, e a variante ".sticky" continua falhando (é assim que se
# prova rollback NÃO comprovado).
cat > "$BIN/update-grub" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
ESTADO="$PASSTHROUGH_TEST_ROOT/estado"
CHAMADA=$(( $(cat "$ESTADO/update-grub.contagem" 2>/dev/null || printf 0) + 1 ))
printf '%s\n' "$CHAMADA" > "$ESTADO/update-grub.contagem"
if [ -e "$ESTADO/falhar-update-grub.sticky" ]; then exit 1; fi
if [ -s "$ESTADO/falhar-update-grub-a-partir-de" ] \
   && [ "$CHAMADA" -ge "$(cat "$ESTADO/falhar-update-grub-a-partir-de")" ]; then
    exit 1
fi
PARAMS="$(awk -F'"' '/^GRUB_CMDLINE_LINUX_DEFAULT=/ {print $2}' \
    "$PASSTHROUGH_TEST_ROOT/etc/default/grub")"
{
    printf 'menuentry normal {\n linux /vmlinuz root=/dev/fixture %s\n}\n' "$PARAMS"
    printf 'menuentry recovery {\n linux /vmlinuz root=/dev/fixture recovery nomodeset\n}\n'
} > "$PASSTHROUGH_TEST_ROOT/boot/grub/grub.cfg"
printf 'update-grub\n' >> "$ESTADO/chamadas.log"
SCRIPT
cat > "$BIN/update-initramfs" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
ESTADO="$PASSTHROUGH_TEST_ROOT/estado"
[ "$*" = "-u -k all" ] || exit 64
if [ -e "$ESTADO/falhar-initramfs.sticky" ]; then exit 1; fi
if [ -e "$ESTADO/falhar-initramfs" ]; then
    rm -f -- "$ESTADO/falhar-initramfs"
    exit 1
fi
printf 'initramfs\n' >> "$ESTADO/chamadas.log"
: > "$ESTADO/initramfs-atualizado"
SCRIPT
# O mock de sudo não eleva nada: ele apenas executa como o próprio operador,
# dentro da raiz de teste. É o que inicializar_raiz_teste exige para aceitar o
# redirecionamento de /etc e /boot.
cat > "$BIN/sudo" <<'SCRIPT'
#!/bin/bash
while [ "${1:-}" = "-n" ] || [ "${1:-}" = "-v" ]; do
    [ "$1" = "-v" ] && exit 0
    shift
done
[ "${1:-}" = "true" ] && exit 0
ESTADO="$PASSTHROUGH_TEST_ROOT/estado"
if [ "${1:-}" = "mv" ] && [ -e "$ESTADO/falhar-mv-vfio" ]; then
    for ARGUMENTO in "$@"; do
        case "$ARGUMENTO" in
            */modules-load.d/vfio.conf)
                rm -f -- "$ESTADO/falhar-mv-vfio"
                exit 1
                ;;
        esac
    done
fi
exec "$@"
SCRIPT
chmod +x "$BIN/update-grub" "$BIN/update-initramfs" "$BIN/sudo"

cat > "$ROOT/etc/os-release" <<'OSREL'
ID=ubuntu
ID_LIKE=debian
VERSION_ID="26.04"
PRETTY_NAME="Ubuntu 26.04 LTS"
OSREL
printf 'MemTotal:       33554432 kB\n' > "$ROOT/proc/meminfo"
: > "$ROOT/estado/chamadas.log"

export PATH="$BIN"
export PASSTHROUGH_TEST_MODE=1
export PASSTHROUGH_TEST_ROOT="$ROOT"
export LC_ALL=C

semear_boot() {
    local params="${1:-quiet splash}"
    cat > "$ROOT/etc/default/grub" <<GRUB
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_CMDLINE_LINUX_DEFAULT="$params"
GRUB_CMDLINE_LINUX=""
GRUB
    {
        printf 'menuentry normal {\n linux /vmlinuz root=/dev/fixture %s\n}\n' "$params"
        printf 'menuentry recovery {\n linux /vmlinuz root=/dev/fixture recovery nomodeset\n}\n'
    } > "$ROOT/boot/grub/grub.cfg"
    rm -f -- "$ROOT/etc/modules-load.d/vfio.conf" \
        "$ROOT/etc/modules-load.d/vfio.conf".vm-passthrough-* \
        "$ROOT/etc/default/grub".bak-* "$ROOT/estado/initramfs-atualizado" \
        "$ROOT/estado/update-grub.contagem" \
        "$ROOT/estado/falhar-update-grub-a-partir-de" \
        "$ROOT/estado/falhar-update-grub.sticky" "$ROOT/estado/falhar-initramfs" \
        "$ROOT/estado/falhar-mv-vfio"
    : > "$ROOT/estado/chamadas.log"
}

semear_boot
# shellcheck source=../lib/common.sh
source "$RAIZ/lib/common.sh"
BOOTLOADER=grub
plataforma_carregar || falha "provider de plataforma não carregou na raiz hermética: $PLATAFORMA_ERRO"

igual "$ROOT/etc/default/grub" "$GRUB_DEFAULT_ARQUIVO" 'GRUB_DEFAULT_ARQUIVO não seguiu a raiz hermética'
igual "$ROOT/etc/modules-load.d/vfio.conf" "$VFIO_MODULES_ARQUIVO" 'VFIO_MODULES_ARQUIVO não seguiu a raiz hermética'
passou

# --- 1. Bloco gerenciado de vfio.conf ----------------------------------------
BLOCO_CANONICO="$(printf '%s\n%s\n%s\n%s\n%s' \
    "$VFIO_MARCADOR_INICIO" vfio vfio_pci vfio_iommu_type1 "$VFIO_MARCADOR_FIM")"

igual "$BLOCO_CANONICO" "$(_vfio_candidato_de '')" \
    'candidato de vfio.conf ausente não é o bloco canônico'

LEGADO="$(printf '%s\n%s\n%s' vfio vfio_pci vfio_iommu_type1)"
igual "$BLOCO_CANONICO" "$(_vfio_candidato_de "$LEGADO")" \
    'formato antigo não converge para o bloco gerenciado'

TERCEIROS="$(printf '%s\n%s\n%s' '# modulo de outro pacote' 'outro_modulo' 'vfio')"
CANDIDATO_TERCEIROS="$(_vfio_candidato_de "$TERCEIROS")"
contem "$CANDIDATO_TERCEIROS" '# modulo de outro pacote' 'comentário de terceiros foi descartado'
contem "$CANDIDATO_TERCEIROS" 'outro_modulo' 'módulo de terceiros foi descartado'
igual 1 "$(printf '%s\n' "$CANDIDATO_TERCEIROS" | grep -c '^vfio$')" \
    'módulo gerenciado ficou duplicado após a migração'
igual "$CANDIDATO_TERCEIROS" "$(_vfio_candidato_de "$CANDIDATO_TERCEIROS")" \
    'candidato de vfio.conf não é idempotente'

COM_SUFIXO="$(printf '%s\n%s\n%s' "$VFIO_MARCADOR_INICIO" "$VFIO_MARCADOR_FIM" 'depois_do_bloco')"
contem "$(_vfio_candidato_de "$COM_SUFIXO")" 'depois_do_bloco' \
    'conteúdo posterior ao bloco gerenciado foi perdido'

esperar_falha 'marcador de abertura sem fechamento' \
    _vfio_marcadores_validos "$(printf '%s\nvfio' "$VFIO_MARCADOR_INICIO")"
contem "$VFIO_MODULES_ERRO" 'desemparelhados' 'diagnóstico de marcador desemparelhado ausente'
# O caminho real é `vfio_modules_estado`: se a validação vivesse dentro de uma
# substituição de comando, a mensagem se perderia no subshell e o operador
# receberia recusa sem diagnóstico.
printf '%s\nvfio\n' "$VFIO_MARCADOR_INICIO" > "$ROOT/etc/modules-load.d/vfio.conf"
VFIO_MODULES_ERRO=""
RC_VFIO=0
vfio_modules_estado || RC_VFIO=$?
igual 2 "$RC_VFIO" 'marcador desemparelhado deveria ser erro de formato (2), não divergência'
contem "$VFIO_MODULES_ERRO" 'desemparelhados' \
    'diagnóstico do marcador se perdeu no subshell de vfio_modules_estado'
rm -f -- "$ROOT/etc/modules-load.d/vfio.conf"
passou

# --- 2. Ativo e persistente são fatos independentes ---------------------------
matriz_estado() {
    # $1=ativo simulado, $2=persistente simulado
    local ativo="$1" persistente="$2"
    (
        cmdline_parametros_exatos() { [ "$ativo" = exato ]; }
        cmdline_possui_alguma_chave() { [ "$ativo" = divergente ]; }
        kernel_parametros_persistentes_exatos() { [ "$persistente" = exato ]; }
        kernel_param_chaves_persistentes_ausentes() {
            KERNEL_PERSISTENCIA_TIPO=pendente
            KERNEL_PERSISTENCIA_ERRO='divergente'
            [ "$persistente" = ausente ]
        }
        boot_estado_iommu "$IOMMU_PARAMS_PADRAO" >/dev/null 2>&1 || true
        printf '%s/%s\n' "$BOOT_IOMMU_ATIVO" "$BOOT_IOMMU_PERSISTENTE"
    )
}
igual 'exato/exato' "$(matriz_estado exato exato)" 'estado convergido não foi reconhecido'
igual 'ausente/exato' "$(matriz_estado ausente exato)" 'reboot pendente não foi distinguido'
igual 'exato/ausente' "$(matriz_estado exato ausente)" 'ativo sem persistência não foi distinguido'
igual 'divergente/divergente' "$(matriz_estado divergente divergente)" 'divergência não foi distinguida'
passou

# --- 3. Transação REQ-IOMMU-TX ------------------------------------------------
executar_transacao() {
    # Reproduz exatamente o envelope de traps da etapa 30.
    (
        finalizar() {
            local rc=$?
            trap - EXIT INT TERM
            case "$IOMMU_TX_ESTADO" in
                PREPARED|BOOT|VFIO|INITRAMFS|VERIFIED|ROLLING_BACK)
                    iommu_vfio_rollback || { [ "$rc" -ne 0 ] || rc=1; }
                    ;;
            esac
            exit "$rc"
        }
        trap 'finalizar' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        iommu_vfio_transacao "$IOMMU_PARAMS_PADRAO" \
            || falhar "${IOMMU_TX_ERRO:-transação recusada}"
        trap - EXIT INT TERM
        exit 0
    )
}

manifesto_boot() {
    python3 - "$ROOT" <<'PY'
import hashlib, sys
from pathlib import Path
root = Path(sys.argv[1])
for alvo in ("etc/default/grub", "boot/grub/grub.cfg", "etc/modules-load.d/vfio.conf"):
    caminho = root / alvo
    if caminho.is_file():
        print("%s|%s" % (alvo, hashlib.sha256(caminho.read_bytes()).hexdigest()))
    else:
        print("%s|ausente" % alvo)
residuos = sorted(
    p.name for p in (root / "etc/modules-load.d").glob("vfio.conf.vm-passthrough-*")
)
print("residuos|%s" % ",".join(residuos))
PY
}

# 3a. Aplicação completa a partir do estado limpo.
semear_boot
ANTES="$(manifesto_boot)"
executar_transacao > "$TMPDIR_TESTE/tx.log" 2>&1 \
    || falha "transação limpa falhou: $(tail -3 "$TMPDIR_TESTE/tx.log")"
grep -q 'amd_iommu=on iommu=pt' "$ROOT/etc/default/grub" \
    || falha 'a fonte do GRUB não recebeu os parâmetros'
grep -q 'amd_iommu=on iommu=pt' "$ROOT/boot/grub/grub.cfg" \
    || falha 'o grub.cfg efetivo não foi regenerado'
igual "$BLOCO_CANONICO" "$(cat "$ROOT/etc/modules-load.d/vfio.conf")" \
    'vfio.conf publicado difere do bloco canônico'
[ -e "$ROOT/estado/initramfs-atualizado" ] || falha 'initramfs não foi regenerado'
igual 'update-grub initramfs' "$(tr '\n' ' ' < "$ROOT/estado/chamadas.log" | sed 's/ $//')" \
    'a ordem exigida (boot e vfio antes do initramfs) não foi respeitada'
igual 'residuos|' "$(manifesto_boot | tail -1)" \
    'sobrou temporário da transação de vfio.conf após o commit'
passou

# 3b. Segunda execução sobre estado convergido: no-op exato.
CONVERGIDO_CONTEUDO="$(manifesto_boot)"
CONVERGIDO_MTIME="$(stat -c '%n|%Y|%i' "$ROOT/etc/default/grub" \
    "$ROOT/boot/grub/grub.cfg" "$ROOT/etc/modules-load.d/vfio.conf")"
: > "$ROOT/estado/chamadas.log"
executar_transacao > "$TMPDIR_TESTE/tx2.log" 2>&1 \
    || falha "segunda transação falhou: $(tail -3 "$TMPDIR_TESTE/tx2.log")"
igual "$CONVERGIDO_CONTEUDO" "$(manifesto_boot)" 'segunda execução mudou conteúdo'
igual "$CONVERGIDO_MTIME" \
    "$(stat -c '%n|%Y|%i' "$ROOT/etc/default/grub" "$ROOT/boot/grub/grub.cfg" \
        "$ROOT/etc/modules-load.d/vfio.conf")" \
    'segunda execução deixou de ser no-op exato (mtime ou inode mudaram)'
igual '' "$(cat "$ROOT/estado/chamadas.log")" \
    'segunda execução ainda chamou update-grub/update-initramfs'
contem "$(cat "$TMPDIR_TESTE/tx2.log")" 'já convergidos' 'no-op não foi anunciado'
passou

# 3c. Falha no initramfs: boot e vfio.conf voltam ao original, e o initramfs é
#     ressincronizado para não ficar em versão incompatível.
semear_boot
ANTES="$(manifesto_boot)"
: > "$ROOT/estado/falhar-initramfs"
if executar_transacao > "$TMPDIR_TESTE/tx3.log" 2>&1; then
    falha 'falha no initramfs não derrubou a transação'
fi
igual "$ANTES" "$(manifesto_boot)" 'falha no initramfs deixou estado persistente parcial'
contem "$(cat "$TMPDIR_TESTE/tx3.log")" 'restaurados e comprovados' \
    'rollback de boot não foi comprovado por releitura'
contem "$(cat "$TMPDIR_TESTE/tx3.log")" 'Initramfs regenerado' \
    'initramfs não foi ressincronizado após o rollback'
passou

# 3d. Falha ao publicar o vfio.conf: os parâmetros de boot voltam atrás.
semear_boot
ANTES="$(manifesto_boot)"
: > "$ROOT/estado/falhar-mv-vfio"
if executar_transacao > "$TMPDIR_TESTE/tx4.log" 2>&1; then
    falha 'falha ao publicar vfio.conf não derrubou a transação'
fi
igual "$ANTES" "$(manifesto_boot)" 'falha no vfio.conf deixou os parâmetros de boot aplicados'
rm -f -- "$ROOT/estado/falhar-mv-vfio"
passou

# 3e. Rollback não comprovado é erro grave, com instrução de recuperação.
#     O boot é aplicado (update-grub 1), o initramfs falha e a restauração do
#     boot também falha (update-grub 2 em diante): é o caso em que o operador
#     precisa ser proibido de reiniciar, não apenas avisado.
semear_boot
: > "$ROOT/estado/falhar-initramfs"
printf '2\n' > "$ROOT/estado/falhar-update-grub-a-partir-de"
if executar_transacao > "$TMPDIR_TESTE/tx5.log" 2>&1; then
    falha 'rollback impossível não derrubou a transação'
fi
contem "$(cat "$TMPDIR_TESTE/tx5.log")" 'ROLLBACK DE BOOT NÃO COMPROVADO' \
    'rollback de boot não comprovado foi anunciado como sucesso'
contem "$(cat "$TMPDIR_TESTE/tx5.log")" 'NÃO REINICIE' \
    'rollback não comprovado não instruiu a não reiniciar'
passou

# 3f. Conteúdo de terceiros sobrevive a uma transação completa.
semear_boot
printf '%s\n%s\n' '# preservar isto' 'outro_modulo' \
    > "$ROOT/etc/modules-load.d/vfio.conf"
executar_transacao > "$TMPDIR_TESTE/tx6.log" 2>&1 \
    || falha "transação com vfio.conf de terceiros falhou: $(tail -3 "$TMPDIR_TESTE/tx6.log")"
contem "$(cat "$ROOT/etc/modules-load.d/vfio.conf")" '# preservar isto' \
    'a transação descartou conteúdo não gerenciado de vfio.conf'
contem "$(cat "$ROOT/etc/modules-load.d/vfio.conf")" 'vfio_iommu_type1' \
    'a transação não acrescentou o bloco gerenciado'
passou

# --- 4. Revalidação TOCTOU das etapas 52 e 53 ---------------------------------
TOPO_A=$'0,0,0,0,Y\n4,0,0,0,Y\n1,1,0,0,Y\n5,1,0,0,Y'
TOPO_B=$'0,0,0,0,Y\n4,0,0,0,Y\n1,1,0,0,Y\n5,1,0,0,N'
for ETAPA in 52-cpu-pinning-hugepages.sh 53-cpu-isolation.sh; do
    (
        source "$RAIZ/etapas/$ETAPA" 2>/dev/null || true
        cpu_topologia_csv() { printf '%s\n' "$TOPO_A"; }
        cpu_topologia_fingerprint "$TOPO_A" || exit 1
        TOPOLOGIA_FINGERPRINT="$CPU_TOPOLOGIA_FINGERPRINT"
        exigir_topologia_inalterada || exit 1
        cpu_topologia_csv() { printf '%s\n' "$TOPO_B"; }
        if ( exigir_topologia_inalterada ) 2>/dev/null; then
            exit 1
        fi
        exit 0
    ) || falha "revalidação TOCTOU da etapa ${ETAPA%%-*} não bloqueou topologia alterada"
    (
        source "$RAIZ/etapas/$ETAPA" 2>/dev/null || true
        TOPOLOGIA_FINGERPRINT=""
        if ( exigir_topologia_inalterada ) 2>/dev/null; then
            exit 1
        fi
        exit 0
    ) || falha "etapa ${ETAPA%%-*} aplicaria sem fingerprint da topologia"
done
passou

# --- 5. Uma implementação mutante só (I5.6) -----------------------------------
for FUNCAO in detectar_bootloader validar_bootloader_configurado cmdline_tem \
    kernel_param_add kernel_param_del _grub_aplicar_cmdline \
    _kernelstub_aplicar_estado kernel_parametros_persistentes; do
    igual 1 "$(grep -c "^${FUNCAO}() {" "$RAIZ/lib/shell/boot.sh")" \
        "$FUNCAO não tem exatamente uma definição em lib/shell/boot.sh"
    igual 0 "$(grep -c "^${FUNCAO}() {" "$RAIZ/lib/common.sh")" \
        "$FUNCAO ficou duplicada em lib/common.sh após o cutover"
done
grep -q 'source "\$COMMON_DIR/shell/boot.sh"' "$RAIZ/lib/common.sh" \
    || falha 'lib/common.sh deixou de carregar o módulo lib/shell/boot.sh'
grep -q 'iommu_vfio_transacao' "$RAIZ/etapas/30-iommu-vfio.sh" \
    || falha 'a etapa 30 não usa a transação de REQ-IOMMU-TX'
passou

# --- 6. Aritmética de memória com uma implementação só ------------------------
igual 8192 "$(ram_reserva_host_mib)" 'reserva do host divergente do core'
igual 24576 "$(ram_max_vm_mib)" 'teto de RAM da VM divergente do core'
plano_memoria_vm "$(ram_total_mib)" 22528 22 \
    || falha "plano de memória coerente recusado: $CPU_MEMORIA_ERRO"
igual 22 "$CPUMEM_HUGEPAGES_1G" 'contagem de HugePages derivada incorreta'
esperar_falha 'RAM acima do teto' plano_memoria_vm "$(ram_total_mib)" 30720 30
contem "$CPU_MEMORIA_ERRO" 'excede o teto' 'diagnóstico de teto de RAM ausente'
passou

printf 'OK: I5 (CPU/RAM/HugePages no core, REQ-IOMMU-TX e cutover de boot.sh; %d grupos)\n' "$CHECKS"
