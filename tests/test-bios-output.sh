#!/bin/bash
# Teste puro da leitura de dmesg da etapa BIOS sob set -o pipefail.
set -euo pipefail
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

falha() { echo "FALHA: $*" >&2; exit 1; }
TMPDIR_TESTE="$(mktemp -d)"
trap 'rm -rf -- "$TMPDIR_TESTE"' EXIT
PROJETO_TESTE="$TMPDIR_TESTE/projeto"
BIN="$TMPDIR_TESTE/bin"
mkdir -p "$PROJETO_TESTE/lib" "$PROJETO_TESTE/etapas" "$BIN"
cp "$RAIZ/lib/common.sh" "$PROJETO_TESTE/lib/common.sh"
cp "$RAIZ/lib/platform.sh" "$PROJETO_TESTE/lib/platform.sh"
cp "$RAIZ/lib/python-core.sh" "$PROJETO_TESTE/lib/python-core.sh"
# I9: a fachada carrega TODOS os módulos de lib/shell/ de forma
# incondicional, então o projeto mínimo copia o diretório inteiro em vez
# de uma lista nominal que envelhece a cada módulo novo.
mkdir -p "$PROJETO_TESTE/lib/shell"
cp "$RAIZ/lib/shell/"*.sh "$PROJETO_TESTE/lib/shell/"
# O módulo de dispensas lê a matriz de política em lib/policy/.
mkdir -p "$PROJETO_TESTE/lib/policy"
cp "$RAIZ/lib/policy/waivers.tsv" "$PROJETO_TESTE/lib/policy/waivers.tsv"
# A fachada carrega a ponte e os consumidores de produção usam o core
# Python desde I3, então o projeto mínimo precisa do libexec real.
cp -a "$RAIZ/libexec" "$PROJETO_TESTE/libexec"
cp "$RAIZ/etapas/01-verificar-bios.sh" "$PROJETO_TESTE/etapas/01-verificar-bios.sh"

cat > "$BIN/sudo" <<'SCRIPT'
#!/bin/bash
case "${1:-}" in
    -n) shift ;;
    -v) exit 0 ;;
esac
exec "$@"
SCRIPT
cat > "$BIN/dmesg" <<'SCRIPT'
#!/bin/bash
for i in $(seq 1 20000); do
    printf 'AMD-Vi: fixture %s\n' "$i"
done
for i in $(seq 1 5); do
    printf 'Secure boot: fixture %s\n' "$i"
done
SCRIPT
chmod +x "$BIN/sudo" "$BIN/dmesg"

SAIDA="$(PATH="$BIN:$PATH" bash "$PROJETO_TESTE/etapas/01-verificar-bios.sh")"
QTD_IOMMU="$(grep -c '^AMD-Vi: fixture ' <<< "$SAIDA")"
QTD_SECURE="$(grep -c '^Secure boot: fixture ' <<< "$SAIDA")"
[ "$QTD_IOMMU" -eq 10 ] || falha "esperadas 10 linhas IOMMU, obtidas $QTD_IOMMU"
[ "$QTD_SECURE" -eq 3 ] || falha "esperadas 3 linhas Secure Boot, obtidas $QTD_SECURE"
[[ "$SAIDA" != *'(vazio: normal ANTES da etapa 30'* ]] || falha "mensagens IOMMU existentes foram reportadas como vazias"

printf '%s\n' BIOS_OUTPUT_TESTS_OK
