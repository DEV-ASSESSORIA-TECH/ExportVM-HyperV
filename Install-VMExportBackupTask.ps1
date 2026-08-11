#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$TaskNamePrefix = 'Backup Hyper-V - Lote'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$mainScript = Join-Path $scriptRoot 'Invoke-VMExportBackup.ps1'
$tierHelpersPath = Join-Path $scriptRoot 'TierHelpers.ps1'
$configDir = Join-Path $scriptRoot 'Config'
$tiersConfigPath = Join-Path $configDir 'Tiers.json'
$settingsConfigPath = Join-Path $configDir 'Settings.json'

if (-not (Test-Path -LiteralPath $mainScript)) {
    throw "Script principal nao encontrado: $mainScript"
}
if (-not (Test-Path -LiteralPath $tierHelpersPath)) {
    throw "Modulo de lotes nao encontrado: $tierHelpersPath"
}

. $tierHelpersPath

# Diferente do script principal (que tolera a ausencia de Tiers.json e roda tudo em
# modo ALL/manual), o instalador exige a config de lotes: sua unica funcao e criar uma
# tarefa agendada por lote, entao nao ha um "modo sem lote" util aqui.
$tierDefinitions = Get-TierDefinitions -Path $tiersConfigPath
if ($null -eq $tierDefinitions) {
    throw "$tiersConfigPath nao encontrado. Crie a config de lotes antes de instalar as tarefas agendadas."
}

# Timeouts/RetryCount usados para calcular o pior caso de duracao por lote devem
# refletir o que o script principal realmente vai usar em tempo de execucao
# (Settings.json, quando presente, senao os defaults de param() do script principal).
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
    Write-Warning "Nao foi possivel enumerar VMs do host para calcular ExecutionTimeLimit ($($_.Exception.Message)). Usando contagem minima de 1 VM por lote para o calculo de pior caso."
}

$principal = New-ScheduledTaskPrincipal `
    -UserId 'SYSTEM' `
    -LogonType ServiceAccount `
    -RunLevel Highest

$createdTasks = New-Object System.Collections.Generic.List[object]

foreach ($tier in $tierDefinitions.Tiers) {
    $taskName = "$TaskNamePrefix $($tier.Name)"
    $vmCount = [int]$vmCountByTier[$tier.Name]

    $worstCaseHours = Get-TierWorstCaseHours `
        -VMCount $vmCount `
        -RetryCount ([int]$effective.RetryCount) `
        -ExportTimeoutHours ([double]$effective.ExportTimeoutHours) `
        -CompressionTimeoutHours ([double]$effective.CompressionTimeoutHours) `
        -IntegrityTimeoutHours ([double]$effective.IntegrityTimeoutHours)

    $limitHours = $worstCaseHours
    if ($null -ne $tier.ExecutionTimeLimitHours) {
        $limitHours = [double]$tier.ExecutionTimeLimitHours
        if ($limitHours -lt $worstCaseHours) {
            Write-Warning "Lote '$($tier.Name)': ExecutionTimeLimitHours configurado ($limitHours h) e menor que o pior caso calculado ($worstCaseHours h para $vmCount VM(s)). Mantendo o valor configurado - o Task Scheduler pode encerrar a execucao a forca antes de terminar."
        }
    }

    $arguments = New-Object System.Collections.Generic.List[string]
    $arguments.Add('-NoProfile')
    $arguments.Add('-ExecutionPolicy Bypass')
    $arguments.Add('-File')
    $arguments.Add(('"{0}"' -f $mainScript))
    $arguments.Add('-Execute')
    $arguments.Add('-BatchName')
    $arguments.Add($tier.Name)

    $action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument ($arguments -join ' ') `
        -WorkingDirectory $scriptRoot

    $parts = $tier.ScheduleTime.Split(':')
    $today = Get-Date
    $at = Get-Date -Year $today.Year -Month $today.Month -Day $today.Day -Hour ([int]$parts[0]) -Minute ([int]$parts[1]) -Second 0
    $trigger = New-ScheduledTaskTrigger -Daily -At $at

    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Hours $limitHours) `
        -RestartCount 1 `
        -RestartInterval (New-TimeSpan -Minutes 30)

    $task = New-ScheduledTask `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal `
        -Description "Exporta as VMs do lote $($tier.Name) (classificacao automatica por tamanho), compacta individualmente em 7z, testa integridade, gera relatorio e aplica retencao propria do lote somente apos sucesso completo."

    Register-ScheduledTask -TaskName $taskName -InputObject $task -Force | Out-Null

    $createdTasks.Add([pscustomobject]@{
        TaskName = $taskName
        Tier = $tier.Name
        ScheduleTime = $tier.ScheduleTime
        VMCount = $vmCount
        ExecutionTimeLimitHours = $limitHours
        WorstCaseHours = $worstCaseHours
    })

    Write-Host "Tarefa criada/atualizada: $taskName | Horario=$($tier.ScheduleTime) | VMs=$vmCount | ExecutionTimeLimit=${limitHours}h (pior caso calculado=${worstCaseHours}h)"
}

# Checagem diagnostica de colisao: nao bloqueia, so avisa. O lock global do script
# principal ja impede duas execucoes simultaneas - se um lote ainda estiver rodando
# quando o proximo disparar, o proximo falha na hora (e agora isso vira e-mail de
# falha), em vez de esperar. Melhor avisar aqui do que descobrir isso durante a noite.
$sortedByTime = @($createdTasks | Sort-Object { [datetime]::ParseExact($_.ScheduleTime, 'HH:mm', $null) })
for ($i = 0; $i -lt $sortedByTime.Count; $i++) {
    $current = $sortedByTime[$i]
    $next = if ($i -lt $sortedByTime.Count - 1) { $sortedByTime[$i + 1] } else { $sortedByTime[0] }

    $currentStart = [datetime]::ParseExact($current.ScheduleTime, 'HH:mm', $null)
    $currentEnd = $currentStart.AddHours($current.ExecutionTimeLimitHours)
    $nextStart = [datetime]::ParseExact($next.ScheduleTime, 'HH:mm', $null)
    if ($i -eq $sortedByTime.Count - 1) { $nextStart = $nextStart.AddDays(1) }

    if ($currentEnd -gt $nextStart) {
        Write-Warning "Possivel colisao de agenda: lote '$($current.Tier)' (inicio $($current.ScheduleTime), ate $($current.ExecutionTimeLimitHours) h de execucao) pode ainda estar rodando quando o lote '$($next.Tier)' (inicio $($next.ScheduleTime)) disparar. Isso NAO enfileira - o segundo lote falha imediatamente por causa do lock global do script principal. Ajuste ScheduleTime em $tiersConfigPath se isso nao for intencional."
    }
}

# Remove tarefas de lotes que existiam antes mas saíram de Tiers.json, para nao deixar
# uma tarefa orfa tentando rodar -BatchName <lote removido> (o script principal
# rejeitaria isso, mas e melhor nao deixar a tentativa acontecer).
$currentTaskNames = @($createdTasks | Select-Object -ExpandProperty TaskName)
$existingTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like "$TaskNamePrefix *" })
$staleTasks = @($existingTasks | Where-Object { $currentTaskNames -notcontains $_.TaskName })

foreach ($stale in $staleTasks) {
    Write-Host "Removendo tarefa de lote descontinuado: $($stale.TaskName)" -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $stale.TaskName -Confirm:$false
}

Write-Host ''
Write-Host "Resumo: $($createdTasks.Count) tarefa(s) criada(s)/atualizada(s), $($staleTasks.Count) tarefa(s) orfa(s) removida(s)."
Write-Host "Conta: SYSTEM"
Write-Host "Script principal: $mainScript"
Write-Host "Config de lotes: $tiersConfigPath"
