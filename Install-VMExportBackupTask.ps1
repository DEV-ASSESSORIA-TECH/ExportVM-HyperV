#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$TaskName = 'Backup Hyper-V - Exportacao Completa',

    [ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')]
    [string]$DailyAt = '00:30',

    [ValidatePattern('^[A-Za-z]:$')]
    [string]$BackupDrive = 'F:',

    [string]$ExpectedVolumeLabel = 'BACKUP-HYPERV',

    [ValidateRange(1, 30)]
    [int]$KeepRestorePoints = 3,

    [ValidateRange(0, 9)]
    [int]$CompressionLevel = 3,

    [switch]$SkipEmail,

    [switch]$SkipHash
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$mainScript = Join-Path $scriptRoot 'Invoke-VMExportBackup.ps1'

if (-not (Test-Path -LiteralPath $mainScript)) {
    throw "Script principal nao encontrado: $mainScript"
}

$arguments = New-Object System.Collections.Generic.List[string]
$arguments.Add('-NoProfile')
$arguments.Add('-ExecutionPolicy Bypass')
$arguments.Add('-File')
$arguments.Add(('"{0}"' -f $mainScript))
$arguments.Add('-Execute')
$arguments.Add('-BackupDrive')
$arguments.Add($BackupDrive)
$arguments.Add('-ExpectedVolumeLabel')
$arguments.Add(('"{0}"' -f $ExpectedVolumeLabel))
$arguments.Add('-KeepRestorePoints')
$arguments.Add([string]$KeepRestorePoints)
$arguments.Add('-CompressionLevel')
$arguments.Add([string]$CompressionLevel)
if ($SkipEmail) { $arguments.Add('-SkipEmail') }
if ($SkipHash) { $arguments.Add('-SkipHash') }

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument ($arguments -join ' ') `
    -WorkingDirectory $scriptRoot

$today = Get-Date
$parts = $DailyAt.Split(':')
$at = Get-Date -Year $today.Year -Month $today.Month -Day $today.Day -Hour ([int]$parts[0]) -Minute ([int]$parts[1]) -Second 0
$trigger = New-ScheduledTaskTrigger -Daily -At $at

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 20) `
    -RestartCount 1 `
    -RestartInterval (New-TimeSpan -Minutes 30)

$principal = New-ScheduledTaskPrincipal `
    -UserId 'SYSTEM' `
    -LogonType ServiceAccount `
    -RunLevel Highest

$task = New-ScheduledTask `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description 'Exporta cada VM do Hyper-V, compacta individualmente em 7z, testa integridade, gera relatorio e aplica retencao somente apos sucesso completo.'

Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force | Out-Null

Write-Host "Tarefa criada/atualizada: $TaskName"
Write-Host "Horario diario: $DailyAt"
Write-Host "Conta: SYSTEM"
Write-Host "Script: $mainScript"
Write-Host "Destino: $BackupDrive"
Write-Host "Retencao: $KeepRestorePoints pontos completos"
