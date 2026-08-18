#!/usr/bin/env bash
# Wrapper de comandos sem efeito usado pelo harness I0. Recusa operandos
# absolutos fora da sandbox; comandos stateful nunca passam por este arquivo.
set -euo pipefail

cmd=${MUTATOR_SAFE_COMMAND:-${0##*/}}
harness=${MUTATOR_HARNESS_DIR:?}

# /proc real nunca é lido. A fase B da etapa 30 enxerga somente o cmdline
# sintético mantido pelo dispatcher dentro do state dir.
if [[ $cmd == cat && $# -eq 1 && $1 == /proc/cmdline ]]; then
    exec /usr/bin/cat "${MUTATOR_STATE_DIR:?}/cmdline"
fi

argument_index=0
for argument in "$@"; do
    argument_index=$((argument_index + 1))
    # dirname/basename tratam o argumento apenas como texto. O primeiro
    # argumento de awk é o programa, não um caminho de arquivo.
    [[ $cmd == dirname || $cmd == basename || ( $cmd == awk && $argument_index -eq 1 ) ]] && continue
    case "$argument" in
        /dev/null|"$harness"|"$harness"/*) ;;
        /vm/*)
            # Os helpers Python atuais recebem QCOW2_PATH como identificador
            # escalar para comparação XML; não o abrem. Só este formato
            # validado é permitido sem remapeamento.
            [[ $cmd == python3 ]] || {
                printf '%s\n' "safe:$cmd:${argument//|/\\x7c}" >> "${MUTATOR_FORBIDDEN_LOG:?}"
                exit 126
            }
            ;;
        /*)
            printf '%s\n' "safe:$cmd:${argument//|/\\x7c}" >> "${MUTATOR_FORBIDDEN_LOG:?}"
            printf 'mutator-harness: %s recusou caminho externo: %s\n' "$cmd" "$argument" >&2
            exit 126
            ;;
    esac
done

# Desde I4 a publicação da configuração acontece dentro do core Python, por
# `renameat`, e deixou de ser um `mv` observável pelo dispatcher. Para não perder
# a contagem nem a injeção de falha/sinal nessa janela mutante, `config-publish`
# é registrado como efeito antes de o interpretador rodar. A leitura
# (`config-load`) continua sendo o que é: leitura, sem efeito.
#
# O registro precisa ser feito por `exec`, e não por subprocesso: a injeção de
# sinal envia INT/TERM ao processo pai, que tem de ser o shell da etapa para que
# os traps da transação disparem. Com uma camada extra de bash no meio, o sinal
# atingiria o wrapper e o shell veria apenas um filho morto, sem trap.
if [[ $cmd == python3 ]]; then
    for argumento in "$@"; do
        if [[ $argumento == config-publish ]]; then
            executable=${MUTATOR_SAFE_EXECUTABLE:-/usr/bin/python3}
            [[ $executable == /usr/* && -x $executable ]] || {
                printf '%s\n' "safe:invalid-executable:$cmd" >> "${MUTATOR_FORBIDDEN_LOG:?}"
                exit 126
            }
            exec /usr/bin/python3 -I -S -B "${MUTATOR_SAFE_DISPATCH:?}" \
                mutator-effect-exec config-publish "$executable" "$@"
        fi
    done
fi

case "$cmd" in
    awk|basename|bash|cat|cmp|cut|date|dirname|env|grep|head|paste|python3|readlink|sed|sha256sum|sleep|sort|tail|tr|wc)
        executable=${MUTATOR_SAFE_EXECUTABLE:-/usr/bin/$cmd}
        [[ $executable == /usr/* && -x $executable ]] || {
            printf '%s\n' "safe:invalid-executable:$cmd" >> "${MUTATOR_FORBIDDEN_LOG:?}"
            exit 126
        }
        exec "$executable" "$@"
        ;;
    *)
        printf '%s\n' "safe:unknown:$cmd" >> "${MUTATOR_FORBIDDEN_LOG:?}"
        exit 126
        ;;
esac
