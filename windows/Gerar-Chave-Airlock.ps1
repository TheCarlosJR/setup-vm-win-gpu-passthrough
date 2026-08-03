# ============================================================================
# Gerar-Chave-Airlock.ps1 - chave SSH do Airlock dentro da VM Windows
# ============================================================================
# Cria uma chave ed25519 no perfil do usuário atual ou reutiliza a privada
# existente sem sobrescrevê-la nem validar o par. Somente a chave pública deve
# ser levada ao host; a privada permanece protegida na VM.
# ============================================================================

$sshDir = Join-Path $env:USERPROFILE '.ssh'
New-Item -ItemType Directory -Path $sshDir -Force | Out-Null

$chave = Join-Path $sshDir 'airlock'
Write-Host "Finalidade: criar ou reutilizar o par SSH usado pelo WinSCP/SFTP no Airlock." -ForegroundColor Cyan
Write-Host "Pre-requisitos: execute como o usuario Windows que usara o WinSCP (Administrador nao e necessario); ssh-keygen deve existir."
Write-Host "Efeito: cria $chave e $chave.pub quando a privada ainda nao existe; nao configura host, SFTP, firewall ou WinSCP."
Write-Host "Recomendacao: defina uma passphrase forte quando o ssh-keygen solicitar e guarde-a; nunca copie a chave privada para o host."
Write-Host "Reuso/risco: se $chave ja existir, ela sera reutilizada sem validar tipo, permissao ou correspondencia com a publica."
Write-Host "Se a privada existir sem .pub, este script nao a recria nem imprime a publica. Execute e rode o script novamente:"
Write-Host "  ssh-keygen -y -f `"$chave`" | Set-Content -Encoding ascii `"$chave.pub`""
Write-Host "Nao abrange: instalacao/revogacao da publica no host, verificacao de fingerprint ou rotacao da credencial."
Write-Host "Retorno/reboot: falha do ssh-keygen sai 1; no reuso, confira manualmente a .pub e o par. Nenhum reboot e necessario."

if (Test-Path $chave) {
    Write-Host "Ja existe uma chave privada em $chave; ela sera reutilizada e nada sera sobrescrito." -ForegroundColor Yellow
} else {
    Write-Host "O ssh-keygen perguntara pela passphrase; evite deixa-la vazia sem avaliar o risco."
    ssh-keygen -t ed25519 -f $chave -C 'airlock-vm'
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ssh-keygen falhou. Instale o Cliente OpenSSH em Configuracoes > Aplicativos > Recursos opcionais." -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "=== LINHA PUBLICA (copie-a por inteiro para o host; nunca copie a privada) ===" -ForegroundColor Cyan
Get-Content "$chave.pub"
Write-Host "=============================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "No host, na raiz do projeto, instale a linha publica com:"
Write-Host "  bash etapas/61-airlock.sh --instalar-chave"
Write-Host "Consulte os valores efetivos, sem adivinhar enderecos ou usuarios:"
Write-Host "  grep -E '^(IP_FIXO_HOST|TRANSFER_USER)=' passthrough.conf"
Write-Host "No WinSCP use SFTP, o valor de IP_FIXO_HOST como host, o valor de TRANSFER_USER como usuario,"
Write-Host "e este arquivo como chave privada: $chave"
Write-Host "Se a sua versao do WinSCP solicitar conversao para .ppk, aceite a conversao local e proteja o arquivo convertido."
