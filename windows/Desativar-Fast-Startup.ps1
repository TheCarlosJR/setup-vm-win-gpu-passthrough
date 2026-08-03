# ============================================================================
# Desativar-Fast-Startup.ps1 - executar dentro da VM Windows
# ============================================================================
# Define HiberbootEnabled=0. Isso desativa o boot híbrido nos desligamentos
# seguintes, mas não desativa hibernação/suspensão nem garante consistência de
# snapshots ou backups por si só.
# ============================================================================
#Requires -RunAsAdministrator

$chave = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
Write-Host "Finalidade: desativar a Inicializacao Rapida (boot hibrido) dentro da VM." -ForegroundColor Cyan
Write-Host "Pre-requisito: PowerShell como Administrador; politicas corporativas podem reaplicar o valor."
Write-Host "Motivo: evitar que 'Desligar' deixe o Windows/NTFS em estado parcialmente hibernado, o que dificulta acesso seguro pelo host."
Write-Host "Efeito: grava HiberbootEnabled=0 em $chave; desligamentos seguintes deixam de usar Fast Startup."
Write-Host "Recomendacao/risco: faca um desligamento completo antes de acessar discos no host; a inicializacao pode ficar um pouco mais lenta."
Write-Host "Nao abrange: hibernacao, suspensao, hiberfile, consistencia de aplicativos ou validacao de snapshot/backup."
Write-Host "Retorno/reboot: sai 1 se a releitura nao for 0; nao reinicia. Depois, desligue completamente a VM ao menos uma vez."

Set-ItemProperty -Path $chave -Name 'HiberbootEnabled' -Value 0 -Type DWord

$valor = (Get-ItemProperty -Path $chave -Name 'HiberbootEnabled').HiberbootEnabled
if ($valor -eq 0) {
    Write-Host "Inicializacao Rapida DESATIVADA (HiberbootEnabled=0)." -ForegroundColor Green
} else {
    Write-Host "Falha ao desativar (HiberbootEnabled=$valor)." -ForegroundColor Red
    exit 1
}
Write-Host "Efeito pratico: nos proximos 'Desligar', o Fast Startup nao sera usado; isto nao substitui validar o estado do disco."
Write-Host "Reversao manual (PowerShell como Administrador):" -ForegroundColor Yellow
Write-Host "  Set-ItemProperty -Path '$chave' -Name 'HiberbootEnabled' -Value 1 -Type DWord"
Write-Host "Depois da reversao, faca novo desligamento/reboot conforme sua politica e confirme o valor efetivo."
