#requires -Version 5.1
#requires -RunAsAdministrator

<#
    Orquestra a cascata noturna: gera uma assinatura compartilhada (BackupSetId) e roda
    cada lote definido em Config\Tiers.json em sequencia (SMALL -> MEDIUM -> BIG, ordem
    de MinSizeGB ascendente), um atras do outro, cada um como processo powershell.exe
    separado - assim os tres publicam dentro da mesma pasta na raiz do repositorio
    (ver Invoke-VMExportBackup.ps1, parametro -BackupSetId), e o "exit" interno de cada
    lote nao encerra a cadeia inteira.

    Chamado uma vez por noite pela tarefa agendada unica criada por
    Install-VMExportBackupTask.ps1. Uma falha num lote nao impede os seguintes de
    rodar. O wrapper envia um unico alerta consolidado com os motivos das falhas.
    O exit code deste wrapper so serve para o LastTaskResult do Agendador do Windows.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptPath = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$ScriptRoot = Split-Path -Parent $ScriptPath
$MainScript = Join-Path $ScriptRoot 'Invoke-VMExportBackup.ps1'
$TierHelpersPath = Join-Path $ScriptRoot 'Internal\Helpers\TierHelpers.ps1'
$RepositoryHelpersPath = Join-Path $ScriptRoot 'Internal\Helpers\RepositoryHelpers.ps1'
$ObservabilityHelpersPath = Join-Path $ScriptRoot 'Internal\Helpers\ObservabilityHelpers.ps1'
$TiersConfigPath = Join-Path $ScriptRoot 'Config\Tiers.json'
$SettingsConfigPath = Join-Path $ScriptRoot 'Config\Settings.json'
$LogDir = Join-Path $ScriptRoot 'Logs'
$ReportDir = Join-Path $ScriptRoot 'Reports'
$DiagnosticFailures = New-Object System.Collections.Generic.List[string]
$TierExecutions = New-Object System.Collections.Generic.List[object]

foreach ($dir in @($LogDir, $ReportDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
        catch { $DiagnosticFailures.Add("Nao foi possivel criar '$dir': $($_.Exception.Message)") }
    }
}

$RunId = [guid]::NewGuid().ToString('N')
$LogPath = Join-Path $LogDir "Cascade-$((Get-Date).ToString('yyyy-MM-dd_HH-mm-ss'))-$($RunId.Substring(0, 8)).log"

function Write-CascadeLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'SUCCESS', 'WARNING', 'ERROR')][string]$Level = 'INFO'
    )
    $line = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [$Level] $Message"
    Write-Host $line
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop }
    catch {
        $diagnostic = "Falha ao gravar log da cascata '$LogPath': $($_.Exception.Message)"
        if (-not $DiagnosticFailures.Contains($diagnostic)) { $DiagnosticFailures.Add($diagnostic) }
    }
}

function ConvertTo-CascadeHtmlText {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return '' }
    return [System.Security.SecurityElement]::Escape([string]$Value)
}

function New-CascadeHtmlReport {
    param([Parameter(Mandatory = $true)]$Summary)

    $rows = New-Object System.Text.StringBuilder
    $failureRows = New-Object System.Text.StringBuilder
    foreach ($execution in $TierExecutions) {
        $result = $execution.Result
        $skipReason = ''; $tierLogPath = ''
        if ($null -ne $result) {
            if ($result.PSObject.Properties.Name -contains 'SkipReason') { $skipReason = [string]$result.SkipReason }
            if ($result.PSObject.Properties.Name -contains 'LogPath') { $tierLogPath = [string]$result.LogPath }
        }
        [void]$rows.AppendLine("<tr><td>$(ConvertTo-CascadeHtmlText $execution.TierName)</td><td>$(ConvertTo-CascadeHtmlText $execution.Status)</td><td>$(ConvertTo-CascadeHtmlText $execution.ExitCode)</td><td>$(ConvertTo-CascadeHtmlText $execution.SuccessCount)</td><td>$(ConvertTo-CascadeHtmlText $execution.FailureCount)</td><td>$(ConvertTo-CascadeHtmlText $skipReason)</td><td>$(ConvertTo-CascadeHtmlText $tierLogPath)</td><td>$(ConvertTo-CascadeHtmlText $execution.ResultPath)</td></tr>")
        if ($null -eq $result) {
            [void]$failureRows.AppendLine("<tr><td>$(ConvertTo-CascadeHtmlText $execution.TierName)</td><td>Lote</td><td>Resultado indisponivel; consulte o log do lote. Codigo de saida: $(ConvertTo-CascadeHtmlText $execution.ExitCode).</td></tr>")
            continue
        }
        if ($result.PSObject.Properties.Name -contains 'Error' -and -not [string]::IsNullOrWhiteSpace($result.Error)) {
            [void]$failureRows.AppendLine("<tr><td>$(ConvertTo-CascadeHtmlText $execution.TierName)</td><td>Lote</td><td>$(ConvertTo-CascadeHtmlText ($result.Error + ' | Log do lote: ' + $tierLogPath))</td></tr>")
        }
        if ($result.PSObject.Properties.Name -contains 'VMResults') {
            foreach ($vm in @($result.VMResults | Where-Object { -not $_.Success })) {
                $details = Format-VMFailureDetails -Result $vm -LogPath $tierLogPath
                [void]$failureRows.AppendLine("<tr><td>$(ConvertTo-CascadeHtmlText $execution.TierName)</td><td>$(ConvertTo-CascadeHtmlText $vm.Name)</td><td>$(ConvertTo-CascadeHtmlText $details)</td></tr>")
            }
        }
    }
    $failures = if ($failureRows.Length -gt 0) {
        '<h2>Motivos das falhas</h2><table><tr><th>Lote</th><th>VM / Escopo</th><th>Motivo</th></tr>' + $failureRows.ToString() + '</table>'
    } else { '' }
    $diagnostics = if ($DiagnosticFailures.Count -gt 0) {
        '<h2>Falhas de observabilidade</h2><ul>' + (($DiagnosticFailures | ForEach-Object { '<li>' + (ConvertTo-CascadeHtmlText $_) + '</li>' }) -join '') + '</ul>'
    } else { '' }
    $selectionHtml = ''
    $hasSelection = if ($Summary -is [System.Collections.IDictionary]) { $Summary.Contains('SelectionPlan') } else { $Summary.PSObject.Properties.Name -contains 'SelectionPlan' }
    if ($hasSelection -and $null -ne $Summary.SelectionPlan) {
        $selection = $Summary.SelectionPlan
        if (@($selection.Warnings).Count -gt 0) {
            $selectionHtml += '<h2>Avisos de exclusao</h2><ul>' + (($selection.Warnings | ForEach-Object { '<li>' + (ConvertTo-CascadeHtmlText $_) + '</li>' }) -join '') + '</ul>'
        }
        if (@($selection.ExcludedVMs).Count -gt 0) {
            $selectionHtml += '<h2>VMs ignoradas antes da classificacao</h2><ul>' + (($selection.ExcludedVMs | ForEach-Object {
                '<li>' + (ConvertTo-CascadeHtmlText ("$($_.Name) | VMId: $($_.VMId) | Regra: $($_.Reason)")) + '</li>'
            }) -join '') + '</ul>'
        }
    }
    return @"
<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><title>Cascata Backup Hyper-V</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222}table{border-collapse:collapse;width:100%}th,td{border:1px solid #ccc;padding:7px;text-align:left}th{background:#f2f2f2}</style></head>
<body><h1>Cascata Backup Hyper-V</h1><p>Status: <strong>$(ConvertTo-CascadeHtmlText $Summary.Status)</strong></p>
<p>BackupSetId: $(ConvertTo-CascadeHtmlText $Summary.BackupSetId)</p>
$failures
<table><tr><th>Lote</th><th>Status</th><th>Codigo</th><th>Sucessos</th><th>Falhas</th><th>Justificativa</th><th>Log do lote</th><th>Resultado</th></tr>$($rows.ToString())</table>
$selectionHtml
$diagnostics</body></html>
"@
}

function Save-CascadeSnapshots {
    param([Parameter(Mandatory = $true)]$Summary)
    $html = $null
    try { Write-JsonSnapshot -Value $Summary -Path $CascadeJsonPath -Depth 15 }
    catch { Add-UniqueDiagnosticFailure -List $DiagnosticFailures -Message "Falha ao gravar JSON consolidado: $($_.Exception.Message)" }
    try {
        $html = New-CascadeHtmlReport -Summary $Summary
        Write-TextSnapshot -Value $html -Path $CascadeHtmlPath
    }
    catch { Add-UniqueDiagnosticFailure -List $DiagnosticFailures -Message "Falha ao gravar HTML consolidado: $($_.Exception.Message)" }
    return $html
}

function Send-CascadeEmail {
    param([Parameter(Mandatory = $true)][string]$Subject, [Parameter(Mandatory = $true)][string]$HtmlBody)

    $message = $null
    $smtp = $null
    $attachments = New-Object System.Collections.ArrayList
    try {
        $message = New-Object System.Net.Mail.MailMessage
        $smtp = New-Object System.Net.Mail.SmtpClient($SmtpServer, $SmtpPort)
        $message.From = New-Object System.Net.Mail.MailAddress($MailFrom)
        foreach ($recipient in $MailTo) {
            if (-not [string]::IsNullOrWhiteSpace($recipient)) { [void]$message.To.Add($recipient) }
        }
        if ($message.To.Count -eq 0) { throw 'Nenhum destinatario configurado.' }
        $message.Subject = $Subject; $message.SubjectEncoding = [System.Text.Encoding]::UTF8
        $message.Body = $HtmlBody; $message.BodyEncoding = [System.Text.Encoding]::UTF8; $message.IsBodyHtml = $true
        foreach ($path in @($CascadeJsonPath, $CascadeHtmlPath)) {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $attachment = New-Object System.Net.Mail.Attachment($path)
                [void]$attachments.Add($attachment); [void]$message.Attachments.Add($attachment)
            }
        }
        $smtp.Send($message)
        $script:MailSent = $true; $script:NotificationStatus = 'SENT'
        Write-CascadeLog "Alerta consolidado enviado para: $($MailTo -join ', ')." 'SUCCESS'
    }
    catch {
        $script:MailError = $_.Exception.Message; $script:NotificationStatus = 'FAILED'
        Add-UniqueDiagnosticFailure -List $DiagnosticFailures -Message "Falha SMTP consolidada: $($script:MailError)"
        Write-CascadeLog "Falha ao enviar alerta consolidado: $($script:MailError)" 'WARNING'
    }
    finally {
        foreach ($attachment in $attachments) { $attachment.Dispose() }
        if ($null -ne $message) { $message.Dispose() }
        if ($null -ne $smtp) { $smtp.Dispose() }
    }
}

Write-CascadeLog ('=' * 74)
Write-CascadeLog 'Inicio da cascata noturna (Invoke-CascadeBackup.ps1).'

if (-not (Test-Path -LiteralPath $MainScript -PathType Leaf)) {
    Write-CascadeLog "Script principal nao encontrado: $MainScript" 'ERROR'
    exit 1
}
if (-not (Test-Path -LiteralPath $TierHelpersPath -PathType Leaf)) {
    Write-CascadeLog "Modulo de lotes nao encontrado: $TierHelpersPath" 'ERROR'
    exit 1
}
if (-not (Test-Path -LiteralPath $RepositoryHelpersPath -PathType Leaf)) {
    Write-CascadeLog "Modulo de repositorio nao encontrado: $RepositoryHelpersPath" 'ERROR'
    exit 1
}
if (-not (Test-Path -LiteralPath $ObservabilityHelpersPath -PathType Leaf)) {
    Write-CascadeLog "Modulo de observabilidade nao encontrado: $ObservabilityHelpersPath" 'ERROR'
    exit 1
}

. $TierHelpersPath
. $RepositoryHelpersPath
. $ObservabilityHelpersPath

$SmtpServer = '192.168.4.10'; $SmtpPort = 25
$MailFrom = 'alertas@assessoriatech.com'; $MailTo = @('suporte@assessoriatech.com')
$settings = $null
if (Test-Path -LiteralPath $SettingsConfigPath -PathType Leaf) {
    try {
        $settings = Get-Content -LiteralPath $SettingsConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        foreach ($name in @('SmtpServer', 'SmtpPort', 'MailFrom', 'MailTo')) {
            if ($settings.PSObject.Properties.Name -contains $name) { Set-Variable -Name $name -Value $settings.$name }
        }
        $MailTo = @($MailTo)
    }
    catch { Add-UniqueDiagnosticFailure -List $DiagnosticFailures -Message "Falha ao ler SMTP de Settings.json: $($_.Exception.Message)" }
}

try {
    $tierDefinitions = Get-TierDefinitions -Path $TiersConfigPath
}
catch {
    Write-CascadeLog "Falha ao carregar $TiersConfigPath : $($_.Exception.Message)" 'ERROR'
    exit 1
}

if ($null -eq $tierDefinitions) {
    Write-CascadeLog "$TiersConfigPath nao encontrado. A cascata precisa da config de lotes para saber a ordem e a lista de lotes a rodar." 'ERROR'
    exit 1
}

# BackupSetId gerado uma unica vez, antes do primeiro lote - garante que os tres
# processos publiquem na mesma pasta mesmo que a cascata atravesse a virada do dia
# (ex.: BIG terminando de madrugada do dia seguinte).
$BackupSetId = New-BackupSetId
Write-CascadeLog "BackupSetId: $BackupSetId"
Write-CascadeLog "Ordem dos lotes: $(($tierDefinitions.Tiers | Select-Object -ExpandProperty Name) -join ' -> ')"

$CascadeJsonPath = Join-Path $ReportDir "Cascade-$BackupSetId.json"
$CascadeHtmlPath = Join-Path $ReportDir "Cascade-$BackupSetId.html"
$MailSent = $false; $MailError = $null; $NotificationStatus = 'NOT_REQUIRED'
$cascadeStartedAt = Get-Date
$selectionPlan = $null
$selectionWarningCount = 0
$SelectionPlanPath = Join-Path $ReportDir "Cascade-$BackupSetId.plan.json"
$planReady = $false
try {
    $excludeNames = @(); $excludeIds = @()
    if (Test-Path -LiteralPath $SettingsConfigPath -PathType Leaf) {
        if ($null -eq $settings) { throw 'Settings.json invalido; planejamento cancelado para preservar as exclusoes.' }
        [void](Assert-SettingsSchemaV2 -ConfigObject $settings)
        if ($settings.PSObject.Properties.Name -contains 'ExcludeVMName') { $excludeNames = @($settings.ExcludeVMName) }
        if ($settings.PSObject.Properties.Name -contains 'ExcludeVMId') { $excludeIds = @($settings.ExcludeVMId) }
    }
    Import-Module Hyper-V -ErrorAction Stop
    $selectionPlan = New-VMSelectionPlan -AllVMs @(Get-VM -ErrorAction Stop) -TierDefinitions $tierDefinitions `
        -ExcludeVMName $excludeNames -ExcludeVMId $excludeIds -BackupSetId $BackupSetId
    Write-JsonSnapshot -Value $selectionPlan -Path $SelectionPlanPath
    $selectionWarningCount = @($selectionPlan.Warnings).Count
    foreach ($warning in $selectionPlan.Warnings) { Write-CascadeLog $warning 'WARNING' }
    $planReady = $true
}
catch {
    $planError = $_.Exception.Message
    Write-CascadeLog "Falha no planejamento: $planError" 'ERROR'
    $TierExecutions.Add([pscustomobject]@{
        TierName = 'PLANEJAMENTO'; Status = 'FAILED'; ExitCode = 1; SuccessCount = 0; FailureCount = 0
        ResultPath = $SelectionPlanPath; Result = [pscustomobject]@{ Error = $planError; LogPath = $LogPath }
    })
}

foreach ($tier in $tierDefinitions.Tiers) {
    if (-not $planReady) { break }
    Write-CascadeLog ('-' * 74)
    Write-CascadeLog "Lote '$($tier.Name)': iniciando."
    $tierStart = Get-Date

    $safeTierName = ConvertTo-RepositorySafeName -Name $tier.Name
    $tierResultPath = Join-Path $ReportDir "BackupSet-$BackupSetId-$safeTierName.result.json"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $MainScript -BatchName $tier.Name -Execute `
        -BackupSetId $BackupSetId -SelectionPlanPath $SelectionPlanPath -DeferEmail -ResultPath $tierResultPath
    $exitCode = $LASTEXITCODE

    $tierDuration = (Get-Date) - $tierStart
    $tierResult = $null
    try {
        $tierResult = Get-Content -LiteralPath $tierResultPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Add-UniqueDiagnosticFailure -List $DiagnosticFailures -Message "Resultado do tier '$($tier.Name)' indisponivel: $($_.Exception.Message)"
    }
    $tierStatus = if ($null -ne $tierResult) { [string]$tierResult.Status } elseif ($exitCode -eq 1) { 'FAILED' } else { 'UNKNOWN' }
    $TierExecutions.Add([pscustomobject][ordered]@{
        TierName = $tier.Name; Status = $tierStatus; ExitCode = $exitCode
        SuccessCount = if ($null -ne $tierResult) { [int]$tierResult.SuccessCount } else { 0 }
        FailureCount = if ($null -ne $tierResult) { [int]$tierResult.FailureCount } else { 0 }
        Duration = $tierDuration.ToString('hh\:mm\:ss'); ResultPath = $tierResultPath; Result = $tierResult
    })

    if ($tierStatus -eq 'SKIPPED') {
        Write-CascadeLog "Lote '$($tier.Name)': SKIPPED. $($tierResult.SkipReason)" 'INFO'
    }
    elseif ($exitCode -eq 0) {
        Write-CascadeLog "Lote '$($tier.Name)': concluido com sucesso. Duracao=$($tierDuration.ToString('hh\:mm\:ss'))." 'SUCCESS'
    }
    elseif ($exitCode -eq 2) {
        Write-CascadeLog "Lote '$($tier.Name)': concluido com avisos. Duracao=$($tierDuration.ToString('hh\:mm\:ss'))." 'WARNING'
    }
    else {
        Write-CascadeLog "Lote '$($tier.Name)': terminou com ExitCode=$exitCode. Duracao=$($tierDuration.ToString('hh\:mm\:ss')). A cascata continua com o proximo lote." 'ERROR'
    }
}

Write-CascadeLog ('-' * 74)
$tierExecutionArray = $TierExecutions.ToArray()
$outcome = Get-NightlyCascadeOutcome -TierExecutions $tierExecutionArray -DiagnosticFailureCount ($DiagnosticFailures.Count + $selectionWarningCount)
$summary = [ordered]@{
    SchemaVersion = 2; BackupSetId = $BackupSetId; Status = $outcome.Status; ExitCode = $outcome.ExitCode
    StartedAt = $cascadeStartedAt.ToString('o'); FinishedAt = (Get-Date).ToString('o')
    TierExecutions = $tierExecutionArray; DiagnosticFailures = $DiagnosticFailures.ToArray()
    SelectionPlan = $selectionPlan; SelectionPlanPath = $SelectionPlanPath; RunId = $RunId
    NotificationStatus = $NotificationStatus; MailSent = $MailSent; MailError = $MailError
    LogPath = $LogPath; JsonPath = $CascadeJsonPath; HtmlPath = $CascadeHtmlPath
}
$html = Save-CascadeSnapshots -Summary $summary

# Um alerta, somente depois de todos os tiers. Os filhos sempre usam -DeferEmail.
if ($outcome.ExitCode -eq 1 -or $selectionWarningCount -gt 0) {
    $NotificationStatus = 'PENDING'
    if ([string]::IsNullOrWhiteSpace($html)) {
        try { $html = New-CascadeHtmlReport -Summary $summary }
        catch { Add-UniqueDiagnosticFailure -List $DiagnosticFailures -Message "Falha ao gerar corpo consolidado: $($_.Exception.Message)" }
    }
    if (-not [string]::IsNullOrWhiteSpace($html)) {
        $prefix = if ($outcome.ExitCode -eq 1) { '[FALHA]' } else { '[AVISO]' }
        Send-CascadeEmail -Subject "$prefix Backup Hyper-V - $env:COMPUTERNAME - $BackupSetId" -HtmlBody $html
    }
}

$outcome = Get-NightlyCascadeOutcome -TierExecutions $tierExecutionArray -DiagnosticFailureCount ($DiagnosticFailures.Count + $selectionWarningCount)
$summary.Status = $outcome.Status; $summary.ExitCode = $outcome.ExitCode
$summary.FinishedAt = (Get-Date).ToString('o'); $summary.DiagnosticFailures = $DiagnosticFailures.ToArray()
$summary.NotificationStatus = $NotificationStatus; $summary.MailSent = $MailSent; $summary.MailError = $MailError
[void](Save-CascadeSnapshots -Summary $summary)

$level = if ($outcome.ExitCode -eq 0) { 'SUCCESS' } elseif ($outcome.ExitCode -eq 2) { 'WARNING' } else { 'ERROR' }
Write-CascadeLog "Cascata concluida. Status=$($outcome.Status) | ExitCode=$($outcome.ExitCode) | BackupSetId=$BackupSetId" $level
exit $outcome.ExitCode
