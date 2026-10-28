#requires -Version 5.1

Set-StrictMode -Version 2.0

function Add-UniqueDiagnosticFailure {
    param(
        [Parameter(Mandatory = $true)]$List,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not [string]::IsNullOrWhiteSpace($Message) -and -not $List.Contains($Message)) {
        $List.Add($Message)
    }
}

function Get-NightlyCascadeOutcome {
    param(
        [object[]]$TierExecutions = @(),
        [int]$DiagnosticFailureCount = 0
    )

    $hasBackupFailure = $false
    $hasWarning = $DiagnosticFailureCount -gt 0
    $allSkipped = $TierExecutions.Count -gt 0
    foreach ($execution in $TierExecutions) {
        $exitCode = [int]$execution.ExitCode
        $status = [string]$execution.Status
        if ($status -ne 'SKIPPED') { $allSkipped = $false }
        if ($exitCode -eq 1 -or $status -notin @('SUCCESS', 'SUCCESS_WITH_WARNINGS', 'SKIPPED')) {
            $hasBackupFailure = $true
        }
        elseif ($exitCode -eq 2 -or $status -eq 'SUCCESS_WITH_WARNINGS') {
            $hasWarning = $true
        }
        elseif ($exitCode -notin @(0, 1, 2)) {
            $hasBackupFailure = $true
        }
    }

    if ($hasBackupFailure) { return [pscustomobject]@{ Status = 'FAILED'; ExitCode = 1 } }
    if ($allSkipped) { return [pscustomobject]@{ Status = 'SKIPPED'; ExitCode = $(if ($hasWarning) { 2 } else { 0 }) } }
    if ($hasWarning) { return [pscustomobject]@{ Status = 'SUCCESS_WITH_WARNINGS'; ExitCode = 2 } }
    return [pscustomobject]@{ Status = 'SUCCESS'; ExitCode = 0 }
}

function Format-VMFailureDetails {
    param([Parameter(Mandatory = $true)]$Result, [string]$LogPath)

    $parts = New-Object System.Collections.Generic.List[string]
    $labels = [ordered]@{
        CurrentStage = 'Etapa'; FailedStage = 'Etapa'; FailureKind = 'Classificacao'
        Attempts = 'Tentativas'; RequiredFreeGB = 'Espaco minimo exigido'
        AvailableFreeGB = 'Espaco disponivel'; Error = 'Motivo'
    }
    foreach ($field in $labels.Keys) {
        if ($Result.PSObject.Properties.Name -notcontains $field -or $null -eq $Result.$field) { continue }
        $value = [string]$Result.$field
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        if ($field -in @('RequiredFreeGB', 'AvailableFreeGB')) { $value = '{0:N2} GB' -f [double]$Result.$field }
        $parts.Add("$($labels[$field]): $value")
    }
    if ($parts.Count -eq 0) { $parts.Add('Motivo indisponivel; consulte o log do lote.') }
    if (-not [string]::IsNullOrWhiteSpace($LogPath)) { $parts.Add("Log do lote: $LogPath") }
    return $parts -join ' | '
}

function Write-JsonSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateRange(2, 30)][int]$Depth = 15
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    }
    $temporary = "$Path.tmp-$PID-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    try {
        $Value | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $temporary -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-TextSnapshot {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    }
    $temporary = "$Path.tmp-$PID-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    try {
        Set-Content -LiteralPath $temporary -Value $Value -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}
