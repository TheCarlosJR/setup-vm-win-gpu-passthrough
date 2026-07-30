# ============================================================================
# Gerar-Chave-Airlock.ps1 - Capitulo 24 (rodar DENTRO da VM)
# ============================================================================
# Gera o par de chaves ed25519 do airlock:
#   - a chave PRIVADA fica na VM:  %USERPROFILE%\.ssh\airlock
#   - a chave PUBLICA (uma linha) e exibida ao final: leve-a ao host e instale
#     com: etapas/61-airlock.sh --instalar-chave
# O cliente OpenSSH e componente padrao do Windows 11; se ssh-keygen nao for
# reconhecido: Configuracoes > Aplicativos > Recursos opcionais > Cliente OpenSSH.
# ============================================================================

$sshDir = Join-Path $env:USERPROFILE '.ssh'
New-Item -ItemType Directory -Path $sshDir -Force | Out-Null

$chave = Join-Path $sshDir 'airlock'
if (Test-Path $chave) {
    Write-Host "Ja existe uma chave em $chave (nada foi sobrescrito)." -ForegroundColor Yellow
} else {
    ssh-keygen -t ed25519 -f $chave -C 'airlock-vm'
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ssh-keygen falhou. Instale o Cliente OpenSSH (Recursos opcionais)." -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "=== LINHA PUBLICA (copie-a por inteiro para o host) ===" -ForegroundColor Cyan
Get-Content "$chave.pub"
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "No host: bash etapas/61-airlock.sh --instalar-chave  (e cole a linha acima)"
Write-Host "Depois conecte com WinSCP: SFTP, host <IP_FIXO_HOST>, usuario <TRANSFER_USER>,"
Write-Host "chave privada $chave (o WinSCP converte para .ppk automaticamente)."
