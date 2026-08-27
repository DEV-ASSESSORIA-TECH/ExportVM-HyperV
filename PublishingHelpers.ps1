#requires -Version 5.1

Set-StrictMode -Version 2.0

function Publish-VMTransactionResult {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)]$PathModel
    )

    if (-not $Result.Success) { throw "A VM '$($Result.Name)' nao foi aprovada para publicacao." }
    if (-not (Test-Path -LiteralPath $Context.ArchivePath -PathType Leaf)) {
        throw "Arquivo aprovado nao encontrado: $($Context.ArchivePath)"
    }

    foreach ($path in @($PathModel.ArchivesRoot, $PathModel.MetadataRoot)) {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop | Out-Null
        }
    }

    $archiveDestination = Join-Path $PathModel.ArchivesRoot "$($Context.VMIdentity).7z"
    $metadataDestination = Join-Path $PathModel.MetadataRoot $Context.VMIdentity
    if (Test-Path -LiteralPath $archiveDestination) { throw "Arquivo final ja existe: $archiveDestination" }
    if (Test-Path -LiteralPath $metadataDestination) { throw "Metadata final ja existe: $metadataDestination" }

    $metadataMoved = $false
    $archiveMoved = $false
    try {
        Move-Item -LiteralPath $Context.MetadataRoot -Destination $metadataDestination -ErrorAction Stop
        $metadataMoved = $true
        Move-Item -LiteralPath $Context.ArchivePath -Destination $archiveDestination -ErrorAction Stop
        $archiveMoved = $true

        $Result.ArchivePath = $archiveDestination
        $Result.MetadataPath = $metadataDestination
        $Result.Archive = "Archives\$($Context.VMIdentity).7z"
        $Result.Metadata = "Metadata\$($Context.VMIdentity)"

        if (Test-Path -LiteralPath $Context.VMRoot -PathType Container) {
            Remove-Item -LiteralPath $Context.VMRoot -Recurse -Force -ErrorAction Stop
        }
        return $Result
    }
    catch {
        if ($archiveMoved -and (Test-Path -LiteralPath $archiveDestination -PathType Leaf)) {
            if (-not (Test-Path -LiteralPath $Context.PayloadRoot -PathType Container)) {
                New-Item -ItemType Directory -Path $Context.PayloadRoot -Force | Out-Null
            }
            Move-Item -LiteralPath $archiveDestination -Destination $Context.ArchivePath -Force -ErrorAction SilentlyContinue
        }
        if ($metadataMoved -and (Test-Path -LiteralPath $metadataDestination -PathType Container)) {
            if (-not (Test-Path -LiteralPath $Context.VMRoot -PathType Container)) {
                New-Item -ItemType Directory -Path $Context.VMRoot -Force | Out-Null
            }
            Move-Item -LiteralPath $metadataDestination -Destination $Context.MetadataRoot -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Save-FailedVMTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Result
    )

    $paths = Get-FailedVMPathModel `
        -RepositoryRoot $RepositoryRoot `
        -VMName $Context.VMName `
        -VMId $Context.VMId `
        -OccurrenceId $Context.OccurrenceId

    if (Test-Path -LiteralPath $paths.OccurrenceRoot) {
        throw "Ocorrencia falha ja existe: $($paths.OccurrenceRoot)"
    }
    New-Item -ItemType Directory -Path $paths.OccurrenceRoot -Force -ErrorAction Stop | Out-Null

    if (Test-Path -LiteralPath $Context.VMRoot -PathType Container) {
        Move-Item -LiteralPath $Context.VMRoot -Destination $paths.PayloadRoot -ErrorAction Stop
    }

    [ordered]@{
        SchemaVersion = 2
        VMName = $Context.VMName
        VMId = $Context.VMId
        VMIdentity = $Context.VMIdentity
        TierName = $Context.TierName
        BackupSetId = Get-OptionalPropertyValue -InputObject $Result -Name 'BackupSetId'
        RunId = Get-OptionalPropertyValue -InputObject $Result -Name 'RunId'
        OccurrenceId = $Context.OccurrenceId
        OccurredAt = (Get-Date).ToString('o')
        Status = 'FAILED'
        FailureKind = $Result.FailureKind
        Retryable = $Result.Retryable
        FailedStage = $Result.CurrentStage
        Attempts = $Result.Attempts
        ErrorType = $Result.ErrorType
        Error = $Result.Error
        PayloadStatus = if (Test-Path -LiteralPath $paths.PayloadRoot -PathType Container) { 'PRESENT' } else { 'NONE' }
        Result = $Result
    } | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $paths.FailurePath -Encoding UTF8 -ErrorAction Stop

    return $paths
}

function Write-BackupTierManifestV2 {
    param(
        [Parameter(Mandatory = $true)]$PathModel,
        [Parameter(Mandatory = $true)][ValidateSet('SUCCESS', 'PARTIAL_SUCCESS')][string]$Status,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][datetime]$StartedAt,
        [Parameter(Mandatory = $true)][datetime]$FinishedAt,
        [Parameter(Mandatory = $true)][int]$KeepRestorePoints,
        [object[]]$VMResults = @()
    )

    if (-not (Test-Path -LiteralPath $PathModel.TierRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $PathModel.TierRoot -Force -ErrorAction Stop | Out-Null
    }
    $destination = if ($Status -eq 'SUCCESS') { $PathModel.CompleteMarkerPath } else { $PathModel.PartialMarkerPath }
    $other = if ($Status -eq 'SUCCESS') { $PathModel.PartialMarkerPath } else { $PathModel.CompleteMarkerPath }
    $temporary = "$destination.tmp-$PID-$([guid]::NewGuid().ToString('N').Substring(0, 8))"

    $manifest = New-BackupTierManifest `
        -BackupSetId $PathModel.BackupSetId `
        -TierName $PathModel.TierName `
        -Status $Status `
        -RunId $RunId `
        -StartedAt $StartedAt `
        -FinishedAt $FinishedAt `
        -KeepRestorePoints $KeepRestorePoints `
        -VMResults $VMResults
    try {
        $manifest | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $temporary -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $destination -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $other -PathType Leaf) {
            Remove-Item -LiteralPath $other -Force -ErrorAction Stop
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
    return $destination
}

function Get-BackupOutcome {
    param(
        [object[]]$VMResults = @(),
        [int]$WarningCount = 0
    )

    $successCount = @($VMResults | Where-Object { $_.Success }).Count
    $failureCount = @($VMResults | Where-Object { -not $_.Success }).Count
    if ($failureCount -gt 0) {
        if ($successCount -gt 0) {
            return [pscustomobject]@{ Status = 'PARTIAL_SUCCESS'; ExitCode = 1; SuccessCount = $successCount; FailureCount = $failureCount }
        }
        return [pscustomobject]@{ Status = 'FAILED'; ExitCode = 1; SuccessCount = 0; FailureCount = $failureCount }
    }
    if ($WarningCount -gt 0) {
        return [pscustomobject]@{ Status = 'SUCCESS_WITH_WARNINGS'; ExitCode = 2; SuccessCount = $successCount; FailureCount = 0 }
    }
    return [pscustomobject]@{ Status = 'SUCCESS'; ExitCode = 0; SuccessCount = $successCount; FailureCount = 0 }
}
