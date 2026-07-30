# ============================================================================
# Ativar-MSI-GPU.ps1 - Capitulo 22: MSI Interrupts (rodar DENTRO da VM)
# ============================================================================
# Localiza a(s) GPU(s) NVIDIA no Gerenciador de Dispositivos e cria/ajusta a
# chave de registro MSISupported=1, forcando interrupcoes MSI (menos latencia
# e menos microengasgos que o modo INTx legado).
# Executar como ADMINISTRADOR, com o driver NVIDIA ja instalado.
# Reinicie a VM depois de aplicar.
# ============================================================================
#Requires -RunAsAdministrator

$gpus = Get-PnpDevice -Class Display | Where-Object { $_.InstanceId -like 'PCI\VEN_10DE*' }
if (-not $gpus) {
    Write-Host "Nenhuma GPU NVIDIA encontrada. O driver NVIDIA ja foi instalado (Capitulo 18)?" -ForegroundColor Yellow
    exit 1
}

foreach ($gpu in $gpus) {
    Write-Host "GPU encontrada: $($gpu.FriendlyName)"
    Write-Host "  Instancia: $($gpu.InstanceId)"
    $chave = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($gpu.InstanceId)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
    if (-not (Test-Path $chave)) {
        New-Item -Path $chave -Force | Out-Null
        Write-Host "  Chave MessageSignaledInterruptProperties criada."
    }
    New-ItemProperty -Path $chave -Name 'MSISupported' -PropertyType DWord -Value 1 -Force | Out-Null
    $valor = (Get-ItemProperty -Path $chave -Name 'MSISupported').MSISupported
    Write-Host "  MSISupported = $valor" -ForegroundColor Green
}

Write-Host ""
Write-Host "Concluido. REINICIE a VM para o modo MSI entrar em vigor." -ForegroundColor Cyan
