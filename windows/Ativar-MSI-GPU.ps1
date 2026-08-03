# ============================================================================
# Ativar-MSI-GPU.ps1 - solicitar MSI para GPUs NVIDIA dentro da VM Windows
# ============================================================================
# Define MSISupported=1 para cada adaptador NVIDIA da classe Display encontrado.
# A alteração só é usada após recarregar o driver e não garante ganho de
# desempenho ou compatibilidade em todo hardware/driver.
# ============================================================================
#Requires -RunAsAdministrator

Write-Host "Finalidade: solicitar interrupcoes MSI para todas as GPUs NVIDIA da classe Display encontradas na VM." -ForegroundColor Cyan
Write-Host "Pre-requisitos: PowerShell como Administrador, GPU NVIDIA visivel, driver NVIDIA instalado e Get-PnpDevice disponivel."
Write-Host "Efeito: cria/ajusta no Registro de cada GPU a propriedade DWord MSISupported=1; reinicio da VM e necessario."
Write-Host "Recomendacao/risco: anote o estado anterior; o script nao o salva e MSI pode nao trazer beneficio ou ser inadequado a um driver."
Write-Host "Nao abrange: outras GPUs/dispositivos, confirmacao do modo de interrupcao apos reboot ou teste de desempenho/estabilidade."
Write-Host "Retorno/reboot: sai 1 se nenhuma GPU for encontrada; nao reinicia automaticamente nem prova que MSI ja esta ativo."

$gpus = Get-PnpDevice -Class Display | Where-Object { $_.InstanceId -like 'PCI\VEN_10DE*' }
if (-not $gpus) {
    Write-Host "Nenhuma GPU NVIDIA encontrada. Confirme no Gerenciador de Dispositivos se a GPU e o driver NVIDIA estao presentes." -ForegroundColor Yellow
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
    Write-Host "  Valor gravado e relido: MSISupported = $valor" -ForegroundColor Green
    Write-Host "  Reversao manual desta GPU (Administrador; escolha conforme o estado anterior, que nao foi salvo):" -ForegroundColor Yellow
    Write-Host "    Set-ItemProperty -LiteralPath '$chave' -Name 'MSISupported' -Value 0 -Type DWord"
    Write-Host "    ou, se a propriedade nao existia: Remove-ItemProperty -LiteralPath '$chave' -Name 'MSISupported'"
}

Write-Host ""
Write-Host "Alteracao solicitada. REINICIE a VM e confirme o modo de interrupcao/estabilidade antes de considerar concluido." -ForegroundColor Cyan
