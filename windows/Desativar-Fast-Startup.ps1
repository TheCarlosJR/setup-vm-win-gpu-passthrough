# ============================================================================
# Desativar-Fast-Startup.ps1 - Capitulo 18 (rodar DENTRO da VM)
# ============================================================================
# Desativa a Inicializacao Rapida do Windows. Com ela ativa, "Desligar" faz
# uma hibernacao parcial e deixa o NTFS marcado como em uso ("sujo"), o que:
#   - impede a montagem somente leitura de emergencia do HD1 no host (Cap. 24)
#   - prejudica a consistencia de snapshots e backups (Cap. 25)
# Executar como ADMINISTRADOR.
# ============================================================================
#Requires -RunAsAdministrator

$chave = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
Set-ItemProperty -Path $chave -Name 'HiberbootEnabled' -Value 0 -Type DWord

$valor = (Get-ItemProperty -Path $chave -Name 'HiberbootEnabled').HiberbootEnabled
if ($valor -eq 0) {
    Write-Host "Inicializacao Rapida DESATIVADA (HiberbootEnabled=0)." -ForegroundColor Green
} else {
    Write-Host "Falha ao desativar (HiberbootEnabled=$valor)." -ForegroundColor Red
    exit 1
}
Write-Host "A partir de agora, 'Desligar' faz um desligamento completo de verdade."
