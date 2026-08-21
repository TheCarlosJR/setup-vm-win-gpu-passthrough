#!/bin/bash
# ============================================================================
# etapas/10-atualizar-sistema.sh - Etapa 4: Atualização do Sistema
# ============================================================================
# Atualiza pacotes, kernel e firmware ANTES de instalar drivers e a pilha de
# virtualização. Termina pedindo reboot se algo foi atualizado.
# ============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
carregar_conf

verificar() {
    local pendentes saida_fw rc_fw estado_fw
    if ! plataforma_carregar; then
        v_erro "$PLATAFORMA_ERRO"
        v_fim
    fi
    if [ "$PLATAFORMA_GERENCIADOR_PACOTES" != apt ]; then
        v_erro "O perfil $PLATAFORMA_PERFIL não oferece APT para esta etapa."
        v_fim
    fi
    if ! apt_contar_atualizacoes >/dev/null; then
        v_erro "$APT_ATUALIZACOES_ERRO"
    else
        pendentes="$APT_ATUALIZACOES_TOTAL"
        if [ "$pendentes" -eq 0 ]; then
            v_ok "Nenhuma ação APT pendente em dist-upgrade/autoremove."
        else
            v_falta "$pendentes pacote(s) único(s) com ação APT pendente (dist-upgrade: $APT_DIST_INSTALACOES instalar/atualizar, $APT_DIST_REMOCOES remover; autoremove: $APT_AUTOREMOVE_EXCLUSIVAS remoções adicionais)."
        fi
    fi
    if ! command -v fwupdmgr >/dev/null 2>&1; then
        v_falta "fwupdmgr ausente; o estado de firmware ainda não pode ser consultado."
    else
        if saida_fw="$(fwupdmgr get-updates 2>&1)"; then
            rc_fw=0
        else
            rc_fw=$?
        fi
        if estado_fw="$(fwupd_classificar_resultado get-updates "$rc_fw")"; then
            case "$estado_fw" in
                sem-atualizacoes) v_ok "Nenhuma atualização de firmware disponível." ;;
                sucesso) v_falta "Há atualização de firmware disponível; execute a etapa 4." ;;
                *) v_erro "Estado fwupd inesperado: $estado_fw." ;;
            esac
        else
            v_erro "Consulta somente leitura 'fwupdmgr get-updates' falhou com código $rc_fw: ${saida_fw:-sem diagnóstico}."
        fi
    fi
    v_fim
}
[ "${1:-}" = "--verificar" ] && verificar

guard_mutation host.update || exit 1

FWUPD_ULTIMO_ESTADO=""
FWUPD_ULTIMO_RC=0
fwupd_rodar() {
    local operacao="$1" rc estado
    shift
    if sudo fwupdmgr "$@"; then
        rc=0
    else
        rc=$?
    fi
    FWUPD_ULTIMO_RC="$rc"
    if estado="$(fwupd_classificar_resultado "$operacao" "$rc")"; then
        FWUPD_ULTIMO_ESTADO="$estado"
        return 0
    fi
    FWUPD_ULTIMO_ESTADO=erro
    return 1
}

exigir_plataforma_suportada
[ "$PLATAFORMA_GERENCIADOR_PACOTES" = apt ] \
    || falhar "A etapa 4 requer o perfil APT de Ubuntu/Pop!_OS."
exigir_nao_root

titulo "Antes de continuar"
info "Finalidade: atualizar índices, pacotes, kernel e firmware antes dos drivers e da virtualização."
info "Plataforma detectada: $PLATAFORMA_PERFIL ${PLATAFORMA_VERSION_ID:-versão não informada}."
info "Pré-requisitos: rede funcional, usuário com sudo e espaço livre para pacotes e kernels."
aviso "Alterações: o índice APT será atualizado; full-upgrade pode instalar ou remover pacotes; autoremove remove órfãos; fwupd pode atualizar firmware."
info "Recomendação: mantenha backup recente, energia estável e não interrompa o APT nem uma atualização de firmware."
aviso "Risco principal: interrupções ou regressões podem deixar pacotes inconsistentes ou afetar o próximo boot."
info "Falhas de fwupd abortam por padrão; continuar sem firmware exige confirmação textual explícita."
info "Reboot/retorno: ao concluir, reinicie; depois valide o kernel ativo com 'uname -r' e retorne ao menu."

exigir_sudo

titulo "Etapa 4: Atualização do Sistema"
KERNEL_ANTES="$(uname -r)"

info "Atualizando índice de pacotes..."
sudo apt update

info "Aplicando atualizações completas (full-upgrade)..."
sudo apt full-upgrade -y

info "Removendo pacotes órfãos..."
sudo apt autoremove -y

titulo "Firmware (fwupd/LVFS)"
sudo apt install -y fwupd
PULAR_FIRMWARE=0
FIRMWARE_CONCLUIDO=1
if ! fwupd_rodar refresh refresh --force; then
    erro "fwupdmgr refresh falhou com código $FWUPD_ULTIMO_RC; isso não significa 'sem atualização'."
    if confirmar_digitando CONTINUAR-SEM-FIRMWARE \
        "Modo best-effort: pular toda a fase de firmware nesta execução e concluir somente o APT?"; then
        PULAR_FIRMWARE=1
        FIRMWARE_CONCLUIDO=0
        aviso "Firmware explicitamente ignorado nesta execução; corrija fwupd antes de considerar a etapa integralmente validada."
    else
        falhar "Falha operacional do fwupd; firmware não foi consultado nem atualizado."
    fi
fi

if [ "$PULAR_FIRMWARE" -eq 0 ]; then
    if fwupd_rodar get-updates get-updates; then
        if [ "$FWUPD_ULTIMO_ESTADO" = sem-atualizacoes ]; then
            ok "Nenhuma atualização de firmware disponível."
        elif fwupd_rodar update update; then
            if [ "$FWUPD_ULTIMO_ESTADO" = sem-atualizacoes ]; then
                ok "Nenhuma atualização de firmware precisava ser aplicada."
            else
                ok "Comando de atualização de firmware concluído."
            fi
        else
            falhar "fwupdmgr update falhou com código $FWUPD_ULTIMO_RC; o estado do firmware precisa ser revisado."
        fi
    else
        erro "fwupdmgr get-updates falhou com código $FWUPD_ULTIMO_RC; isso não é ausência normal de atualização."
        if confirmar_digitando CONTINUAR-SEM-FIRMWARE \
            "Continuar somente com as atualizações APT, registrando a fase de firmware como não concluída?"; then
            FIRMWARE_CONCLUIDO=0
            aviso "Consulta de firmware explicitamente ignorada; revise fwupd separadamente."
        else
            falhar "Falha operacional ao consultar firmware."
        fi
    fi
fi

echo
if [ "$FIRMWARE_CONCLUIDO" -eq 1 ]; then
    ok "Atualização de pacotes e fase de firmware concluídas."
else
    aviso "APT concluído, mas a fase de firmware permanece com falha operacional; o status continuará em erro até 'get-updates' funcionar."
fi
info "Kernel em execução: $KERNEL_ANTES"
info "Kernel mais novo instalado: $(dpkg -l 2>/dev/null | awk '/^ii +linux-image-[0-9]/{print $2}' | sort -V | tail -n1)"
aviso "Após o reboot, confirme com 'uname -r' que o kernel esperado está em uso."
pedir_reboot
