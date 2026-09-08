#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$TaskName = 'Backup Hyper-V - Cascata Noturna',

    [string]$TaskPath = '\'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$mainScript = Join-Path $scriptRoot 'Invoke-VMExportBackup.ps1'
$cascadeScript = Join-Path $scriptRoot 'Invoke-CascadeBackup.ps1'
$tierHelpersPath = Join-Path $scriptRoot 'TierHelpers.ps1'
$scheduledTaskHelpersPath = Join-Path $scriptRoot 'ScheduledTaskHelpers.ps1'
$configDir = Join-Path $scriptRoot 'Config'
$tiersConfigPath = Join-Path $configDir 'Tiers.json'
$settingsConfigPath = Join-Path $configDir 'Settings.json'

if (-not (Test-Path -LiteralPath $mainScript)) {
    throw "Script principal nao encontrado: $mainScript"
}
if (-not (Test-Path -LiteralPath $cascadeScript)) {
    throw "Wrapper de cascata nao encontrado: $cascadeScript"
}
if (-not (Test-Path -LiteralPath $tierHelpersPath)) {
    throw "Modulo de lotes nao encontrado: $tierHelpersPath"
}
if (-not (Test-Path -LiteralPath $scheduledTaskHelpersPath)) {
    throw "Helper do Agendador nao encontrado: $scheduledTaskHelpersPath"
}

. $tierHelpersPath
. $scheduledTaskHelpersPath
$TaskPath = ConvertTo-ScheduledTaskPath -Path $TaskPath

# A cascata precisa da config de lotes para saber a ordem e o horario de disparo -
# diferente do script principal, aqui nao ha "modo sem lote" util.
$tierDefinitions = Get-TierDefinitions -Path $tiersConfigPath
if ($null -eq $tierDefinitions) {
    throw "$tiersConfigPath nao encontrado. Crie a config de lotes antes de instalar a tarefa agendada."
}

# Timeouts/RetryCount usados so para o comparativo informativo abaixo devem refletir
# o que o script principal realmente vai usar em tempo de execucao (Settings.json,
# quando presente, senao os defaults de param() do script principal).
$effective = [ordered]@{
    ExportTimeoutHours = 12
    CompressionTimeoutHours = 12
    IntegrityTimeoutHours = 8
    RetryCount = 1
}
$settingsConfig = Import-JsonConfigFile -Path $settingsConfigPath
if ($null -ne $settingsConfig) {
    foreach ($key in @($effective.Keys)) {
        if ($settingsConfig.PSObject.Properties.Name -contains $key) {
            $effective[$key] = $settingsConfig.$key
        }
    }
}

Write-Host "Contando VMs por lote (Hyper-V, tamanho logico atual)..."
$vmCountByTier = @{}
foreach ($tier in $tierDefinitions.Tiers) { $vmCountByTier[$tier.Name] = 0 }

try {
    Import-Module Hyper-V -ErrorAction Stop
    $allVMs = @(Get-VM -ErrorAction Stop)
    foreach ($vm in $allVMs) {
        $sizeBytes = Get-VMSourceSize -Name $vm.Name
        $tierName = Resolve-VMTier -SizeBytes $sizeBytes -TierDefinitions $tierDefinitions
        if ($vmCountByTier.ContainsKey($tierName)) {
            $vmCountByTier[$tierName]++
        }
    }
}
catch {
    Write-Warning "Nao foi possivel enumerar VMs do host para o comparativo informativo de ExecutionTimeLimit ($($_.Exception.Message))."
}

# Comparativo informativo (nao bloqueante): soma do pior caso teorico por lote contra
# o CascadeExecutionTimeLimitHours configurado. Diferente da v1.1.0, esse valor NAO e
# usado para preencher o ExecutionTimeLimit automaticamente - a cascata usa sempre o
# valor unico configurado em Tiers.json, calibrado com duracoes reais observadas.
$estimatedTotalHours = 0
foreach ($tier in $tierDefinitions.Tiers) {
    $vmCount = [int]$vmCountByTier[$tier.Name]
    $tierWorstCase = Get-TierWorstCaseHours -VMCount $vmCount -RetryCount ([int]$effective.RetryCount) `
        -ExportTimeoutHours ([double]$effective.ExportTimeoutHours) `
        -CompressionTimeoutHours ([double]$effective.CompressionTimeoutHours) `
        -IntegrityTimeoutHours ([double]$effective.IntegrityTimeoutHours)
    $estimatedTotalHours += $tierWorstCase
    Write-Host "Lote '$($tier.Name)': $vmCount VM(s), pior caso individual calculado = ${tierWorstCase}h."
}
Write-Host "Soma dos piores casos calculados: ${estimatedTotalHours}h | CascadeExecutionTimeLimitHours configurado: $($tierDefinitions.CascadeExecutionTimeLimitHours)h."
if ($tierDefinitions.CascadeExecutionTimeLimitHours -lt $estimatedTotalHours) {
    Write-Warning "CascadeExecutionTimeLimitHours ($($tierDefinitions.CascadeExecutionTimeLimitHours)h) e menor que a soma dos piores casos calculados (${estimatedTotalHours}h). Normal se o valor configurado ja reflete duracoes reais observadas (mais realista que o pior caso teorico) - so fique atento se o parque de VMs crescer bastante."
}

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$cascadeScript`"" `
    -WorkingDirectory $scriptRoot

$parts = $tierDefinitions.CascadeStartTime.Split(':')
$today = Get-Date
$at = Get-Date -Year $today.Year -Month $today.Month -Day $today.Day -Hour ([int]$parts[0]) -Minute ([int]$parts[1]) -Second 0
$trigger = New-ScheduledTaskTrigger -Daily -At $at

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours $tierDefinitions.CascadeExecutionTimeLimitHours) `
    -RestartCount 1 `
    -RestartInterval (New-TimeSpan -Minutes 30)

$principal = New-ScheduledTaskPrincipal `
    -UserId 'SYSTEM' `
    -LogonType ServiceAccount `
    -RunLevel Highest

$tierNamesJoined = ($tierDefinitions.Tiers | Select-Object -ExpandProperty Name) -join ' -> '

$task = New-ScheduledTask `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description "Roda a cascata noturna de backup Hyper-V ($tierNamesJoined) via Invoke-CascadeBackup.ps1: cada lote comeca assim que o anterior termina, classificacao automatica por tamanho, retencao propria por lote, e-mail so em falha."

Register-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -InputObject $task -Force | Out-Null

Write-Host "Tarefa criada/atualizada: $TaskPath$TaskName | Horario=$($tierDefinitions.CascadeStartTime) | ExecutionTimeLimit=$($tierDefinitions.CascadeExecutionTimeLimitHours)h | Ordem=$tierNamesJoined"

# Ao trocar TaskPath, remove copias anteriores de mesmo nome somente depois que a
# nova tarefa foi registrada com sucesso. Isso evita duas cascatas concorrentes.
$duplicateTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskName -eq $TaskName -and $_.TaskPath -ne $TaskPath
    })
foreach ($duplicate in $duplicateTasks) {
    Write-Host "Removendo copia anterior da tarefa: $($duplicate.TaskPath)$($duplicate.TaskName)" -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskPath $duplicate.TaskPath -TaskName $duplicate.TaskName -Confirm:$false
}

Write-Host ''
Write-Host 'Resumo: 1 tarefa de cascata instalada.'
Write-Host "Conta: SYSTEM"
Write-Host "Wrapper: $cascadeScript"
Write-Host "Config de lotes: $tiersConfigPath"
