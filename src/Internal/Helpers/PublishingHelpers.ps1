#requires -Version 5.1

Set-StrictMode -Version 2.0

function Write-DurablePublicationJson {
    param([Parameter(Mandatory = $true)]$Value, [Parameter(Mandatory = $true)][string]$Path)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null }
    $temporary = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 20))
        $stream = [System.IO.File]::Open($temporary, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if (Test-Path -LiteralPath $Path -PathType Leaf) { [System.IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [System.IO.File]::Move($temporary, $Path) }
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue } }
}

function Complete-VMBackupPublication {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot, [Parameter(Mandatory = $true)][string]$JournalPath,
        [scriptblock]$AfterStep = { param($Step) })

    [void](Assert-PathIsBelowRoot -Root (Join-Path $RepositoryRoot '_PUBLISHING') -Path $JournalPath)
    $journal = Get-Content -LiteralPath $JournalPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($journal.SchemaVersion -ne 2 -or -not $journal.Result.Success -or $journal.ArchiveBytes -le 0) { throw "Registro de publicacao invalido: $JournalPath" }
    $identity = New-VMStorageIdentity -Name $journal.Result.Name -VMId $journal.Result.VMId
    if ($identity -cne $journal.VMIdentity) { throw 'Identidade do registro de publicacao divergente.' }
    $paths = Get-BackupSetPathModel -RepositoryRoot $RepositoryRoot -BackupSetId $journal.BackupSetId -TierName $journal.TierName
    $vmRoot = Assert-PathIsBelowRoot -Root (Join-Path $RepositoryRoot '_STAGING') -Path $journal.SourceVMRoot
    $sourceArchive = Join-Path $vmRoot "Payload\$identity.7z"
    $sourceMetadata = Join-Path $vmRoot 'Metadata'
    $archive = Join-Path $paths.ArchivesRoot "$identity.7z"
    $metadata = Join-Path $paths.MetadataRoot $identity
    foreach ($dir in @($paths.ArchivesRoot, $paths.MetadataRoot)) {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
    }
    foreach ($pair in @(@($sourceMetadata, $metadata), @($sourceArchive, $archive))) {
        $sourceExists = Test-Path -LiteralPath $pair[0]
        $destinationExists = Test-Path -LiteralPath $pair[1]
        if ($sourceExists -and $destinationExists) { throw "Origem e destino coexistem; publicacao preservada para inspecao: $JournalPath" }
        if (-not $sourceExists -and -not $destinationExists) { throw "Payload da publicacao ausente: $($pair[0])" }
        if ($sourceExists) { Move-Item -LiteralPath $pair[0] -Destination $pair[1] -ErrorAction Stop }
        if ($pair[1] -eq $metadata) { & $AfterStep 'METADATA_MOVED' } else { & $AfterStep 'ARCHIVE_MOVED' }
    }
    if ((Get-Item -LiteralPath $archive -ErrorAction Stop).Length -ne [long]$journal.ArchiveBytes) { throw "Tamanho do arquivo publicado diverge do registro: $archive" }
    $hash = Get-OptionalPropertyValue -InputObject $journal.Result -Name SHA256
    if (-not [string]::IsNullOrWhiteSpace([string]$hash) -and (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $hash) { throw "Hash do arquivo publicado diverge do registro: $archive" }
    $result = $journal.Result
    $result.ArchivePath = $archive; $result.MetadataPath = $metadata
    $result.Archive = "Archives\$identity.7z"; $result.Metadata = "Metadata\$identity"
    $existing = @(Get-Schema2BackupTiers -RepositoryRoot $RepositoryRoot | Where-Object { $_.TierRoot -eq $paths.TierRoot })
    $results = @(); $alreadyCommitted = $false
    if ($existing.Count -eq 1) {
        $results = @($existing[0].Manifest.VMResults)
        $alreadyCommitted = @($results | Where-Object { $_.Success -and $_.VMId -eq $result.VMId -and $_.Archive -eq $result.Archive }).Count -eq 1
    }
    if (-not $alreadyCommitted) {
        $results = @($results | Where-Object { $_.VMId -ne $result.VMId }) + @($result)
        [void](Write-BackupTierManifestV2 -PathModel $paths -Status PARTIAL_SUCCESS -RunId $journal.RunId `
            -StartedAt ([datetime]$journal.StartedAt) -FinishedAt (Get-Date) -KeepRestorePoints $journal.KeepRestorePoints -VMResults $results)
    }
    & $AfterStep 'MANIFEST_COMMITTED'
    Remove-Item -LiteralPath $JournalPath -Force -ErrorAction Stop
    # Apos o commit, falha de limpeza nao deve reclassificar um arquivo valido.
    if (Test-Path -LiteralPath $vmRoot) { Remove-Item -LiteralPath $vmRoot -Recurse -Force -ErrorAction SilentlyContinue }
    return $result
}

function Publish-VMTransactionResult {
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)]$PathModel, [int]$KeepRestorePoints = 3,
        [scriptblock]$AfterStep = { param($Step) })

    if (-not $Result.Success) { throw "A VM '$($Result.Name)' nao foi aprovada para publicacao." }
    if (-not (Test-Path -LiteralPath $Context.ArchivePath -PathType Leaf)) { throw "Arquivo aprovado nao encontrado: $($Context.ArchivePath)" }
    [void](Assert-PathIsBelowRoot -Root (Join-Path $PathModel.RepositoryRoot '_STAGING') -Path $Context.VMRoot)
    foreach ($field in @('VMId', 'VMIdentity')) { $Result | Add-Member -NotePropertyName $field -NotePropertyValue $Context.$field -Force }
    $runId = [string](Get-OptionalPropertyValue -InputObject $Result -Name RunId -DefaultValue 'recovered')
    $startedAt = [string](Get-OptionalPropertyValue -InputObject $Result -Name StartedAt -DefaultValue (Get-Date).ToString('o'))
    $journalPath = Join-Path $PathModel.RepositoryRoot ("_PUBLISHING\$($PathModel.BackupSetId)\$($PathModel.TierName)\$($Context.VMIdentity).json")
    if (Test-Path -LiteralPath $journalPath) { throw "Publicacao pendente ja existe: $journalPath" }
    foreach ($destination in @((Join-Path $PathModel.ArchivesRoot "$($Context.VMIdentity).7z"), (Join-Path $PathModel.MetadataRoot $Context.VMIdentity))) {
        if (Test-Path -LiteralPath $destination) { throw "Destino final ja existe: $destination" }
    }
    $journal = [ordered]@{
        SchemaVersion = 2; State = 'PREPARED'; BackupSetId = $PathModel.BackupSetId; TierName = $PathModel.TierName
        VMIdentity = $Context.VMIdentity; SourceVMRoot = $Context.VMRoot; RunId = $runId; StartedAt = $startedAt
        KeepRestorePoints = $KeepRestorePoints; ArchiveBytes = [long](Get-Item -LiteralPath $Context.ArchivePath).Length; Result = $Result
    }
    Write-DurablePublicationJson -Value $journal -Path $journalPath
    & $AfterStep 'PREPARED'
    $committed = Complete-VMBackupPublication -RepositoryRoot $PathModel.RepositoryRoot -JournalPath $journalPath -AfterStep $AfterStep
    foreach ($field in @('ArchivePath', 'MetadataPath', 'Archive', 'Metadata')) { $Result.$field = $committed.$field }
    return $Result
}

function Repair-PendingVMBackupPublications {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
    $pending = Join-Path $RepositoryRoot '_PUBLISHING'
    if (-not (Test-Path -LiteralPath $pending)) { return @() }
    foreach ($journal in @(Get-ChildItem -LiteralPath $pending -File -Recurse -Filter '*.json' -ErrorAction Stop | Sort-Object FullName)) {
        Complete-VMBackupPublication -RepositoryRoot $RepositoryRoot -JournalPath $journal.FullName
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

    $manifest = New-BackupTierManifest `
        -BackupSetId $PathModel.BackupSetId `
        -TierName $PathModel.TierName `
        -Status $Status `
        -RunId $RunId `
        -StartedAt $StartedAt `
        -FinishedAt $FinishedAt `
        -KeepRestorePoints $KeepRestorePoints `
        -VMResults $VMResults
    # Este checkpoint e a referencia atomica de descoberta, inclusive se a
    # atualizacao dos marcadores de apresentacao for interrompida.
    Write-DurablePublicationJson -Value $manifest -Path (Join-Path $PathModel.TierRoot 'PUBLISHED.marker.json')
    Write-DurablePublicationJson -Value $manifest -Path $destination
    if (Test-Path -LiteralPath $other -PathType Leaf) {
        Remove-Item -LiteralPath $other -Force -ErrorAction Stop
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
