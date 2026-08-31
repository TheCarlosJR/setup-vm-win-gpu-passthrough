#!/bin/bash
# ============================================================================
# lib/common.sh - fachada pública compartilhada por etapas e utilitários
# ============================================================================
# Este arquivo NÃO é executado diretamente: ele é carregado via "source" pelos
# scripts de etapas/ e util/, e é a ÚNICA porta de entrada deles.
#
# Desde a fase I9 este arquivo é um AGREGADOR determinístico: ele resolve os
# caminhos do projeto, carrega os módulos de lib/shell/ na ordem topológica das
# dependências e faz a inicialização que exige ordem. Nenhum algoritmo de
# domínio mora aqui; cada módulo é dono do seu domínio e recusa carga fora de
# ordem com diagnóstico próprio.
#
# Ordem de carga (seção 2.4 do PLANO-FINALIZACAO.md; o grafo não tem ciclo):
#
#   base -> platform/python-core -> ui -> libvirt -> privilege -> status
#        -> boot -> probes -> network-effects -> storage -> config -> waivers
#
# Referências: Guia-QEMU-Passthrough.md e troubleshooting.md.
# ============================================================================
LIB_COMMON_VERSION="1.0.0"

# --- Localização do projeto e arquivos centrais -----------------------------
# A resolução usa só expansão do bash e builtins (cd/pwd): um --verificar pode
# rodar com PATH restrito, e a fachada não pode depender de dirname externo
# para encontrar os próprios módulos.
COMMON_DIR="${BASH_SOURCE[0]%/*}"
[ "$COMMON_DIR" != "${BASH_SOURCE[0]}" ] || COMMON_DIR=.
COMMON_DIR="$(cd -- "$COMMON_DIR" && pwd)"
PROJETO_DIR="$(cd -- "$COMMON_DIR/.." && pwd)"
BACKUPS_DIR="$PROJETO_DIR/backups"

_common_exigir_modulo() {
    # Carga fail-closed: sem um módulo não existe fachada, e seguir adiante
    # produziria "command not found" no meio de uma mutação. O diagnóstico sai
    # antes de qualquer efeito.
    printf 'ERRO: lib/common.sh não conseguiu carregar %s.\n' "$1" >&2
    exit 1
}

# Fundação: primitivas de caminho, log local e predicados puros. Nenhum outro
# módulo pode ser carregado antes dela.
# shellcheck source=lib/shell/base.sh
source "$COMMON_DIR/shell/base.sh" || _common_exigir_modulo "lib/shell/base.sh"
# Provider de plataforma e ponte única para o core Python. O carregamento não
# produz efeito: nada é executado até que uma função seja chamada.
# shellcheck source=lib/platform.sh
source "$COMMON_DIR/platform.sh" || _common_exigir_modulo "lib/platform.sh"
# shellcheck source=lib/python-core.sh
source "$COMMON_DIR/python-core.sh" || _common_exigir_modulo "lib/python-core.sh"
# shellcheck source=lib/shell/ui.sh
source "$COMMON_DIR/shell/ui.sh" || _common_exigir_modulo "lib/shell/ui.sh"
# shellcheck source=lib/shell/libvirt.sh
source "$COMMON_DIR/shell/libvirt.sh" || _common_exigir_modulo "lib/shell/libvirt.sh"
# shellcheck source=lib/shell/privilege.sh
source "$COMMON_DIR/shell/privilege.sh" || _common_exigir_modulo "lib/shell/privilege.sh"
# shellcheck source=lib/shell/status.sh
source "$COMMON_DIR/shell/status.sh" || _common_exigir_modulo "lib/shell/status.sh"
# shellcheck source=lib/shell/boot.sh
source "$COMMON_DIR/shell/boot.sh" || _common_exigir_modulo "lib/shell/boot.sh"
# shellcheck source=lib/shell/probes.sh
source "$COMMON_DIR/shell/probes.sh" || _common_exigir_modulo "lib/shell/probes.sh"
# shellcheck source=lib/shell/network-effects.sh
source "$COMMON_DIR/shell/network-effects.sh" \
    || _common_exigir_modulo "lib/shell/network-effects.sh"
# shellcheck source=lib/shell/storage.sh
source "$COMMON_DIR/shell/storage.sh" || _common_exigir_modulo "lib/shell/storage.sh"
# shellcheck source=lib/shell/config.sh
source "$COMMON_DIR/shell/config.sh" || _common_exigir_modulo "lib/shell/config.sh"
# Política de dispensas (REQ-WAIVERS). Carrega só definições: a matriz em
# lib/policy/waivers.tsv é lida na primeira consulta, nunca no source, e
# nunca por source/eval. Depende apenas de PROJETO_DIR, definido acima.
# shellcheck source=lib/shell/waivers.sh
source "$COMMON_DIR/shell/waivers.sh" || _common_exigir_modulo "lib/shell/waivers.sh"

# --- Inicialização que exige ordem -------------------------------------------
# A raiz hermética de teste precisa ser resolvida antes de qualquer caminho de
# sistema ser materializado; é a única decisão de ordem que sobrou depois da
# modularização.
inicializar_raiz_teste
# Os caminhos persistentes de boot são resolvidos aqui, uma vez, porque
# consumidores fora do módulo (etapa 11, por exemplo) leem as variáveis
# diretamente em mensagens. O módulo em si continua sem efeito no source: a
# função é idempotente e respeita valor já definido pelo chamador.
boot_caminhos_resolver
