#requires -Version 5.1

# Funcoes puras de nomes, paths, manifests e descoberta do repositorio schema 2.
# Este arquivo e carregado via dot-source pelos scripts produtivos e pelos testes.

Set-StrictMode -Version 2.0

$script:RepositorySchemaVersion = 2

function ConvertTo-RepositorySafeName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $safe = ($Name -replace '[\\/:*?"<>|]', '_').Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($safe)) {
        throw 'O nome nao produz um componente de caminho valido.'
    }
    return $safe
}

function ConvertTo-NormalizedVMId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VMId
    )

    try {
        return ([guid]$VMId).ToString('N').ToLowerInvariant()
    }
    catch {
        throw "VMId invalido: '$VMId'."
    }
}

function New-VMStorageIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$VMId
    )

    $safeName = ConvertTo-RepositorySafeName -Name $Name
    $normalizedVMId = ConvertTo-NormalizedVMId -VMId $VMId
    return "${safeName}--$($normalizedVMId.Substring(0, 8))"
}

function Test-BackupSetId {
    param([AllowNull()][string]$BackupSetId)

    return -not [string]::IsNullOrWhiteSpace($BackupSetId) -and
        $BackupSetId -match '^\d{4}-\d{2}-\d{2}-[0-9a-f]{8}$'
}

function New-BackupSetId {
    param(
        [datetime]$StartedAt = (Get-Date),
        [guid]$UniqueId = [guid]::Empty
    )

    if ($UniqueId -eq [guid]::Empty) {
        $UniqueId = [guid]::NewGuid()
    }

    return '{0}-{1}' -f $StartedAt.ToString('yyyy-MM-dd'), $UniqueId.ToString('N').Substring(0, 8)
}

function Get-BackupSetPathModel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$BackupSetId,

        [Parameter(Mandatory = $true)]
        [string]$TierName
    )

    if (-not (Test-BackupSetId -BackupSetId $BackupSetId)) {
        throw "BackupSetId invalido: '$BackupSetId'."
    }

    $safeTierName = ConvertTo-RepositorySafeName -Name $TierName
    $backupSetRoot = Join-Path $RepositoryRoot $BackupSetId
    $tierRoot = Join-Path $backupSetRoot $safeTierName

    return [pscustomobject][ordered]@{
        RepositoryRoot = $RepositoryRoot
        BackupSetId = $BackupSetId
        BackupSetRoot = $backupSetRoot
        TierName = $safeTierName
        TierRoot = $tierRoot
        ArchivesRoot = Join-Path $tierRoot 'Archives'
        MetadataRoot = Join-Path $tierRoot 'Metadata'
        CompleteMarkerPath = Join-Path $tierRoot 'COMPLETE.marker.json'
        PartialMarkerPath = Join-Path $tierRoot 'PARTIAL.marker.json'
    }
}

function Get-FailedVMPathModel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$VMName,

        [Parameter(Mandatory = $true)]
        [string]$VMId,

        [Parameter(Mandatory = $true)]
        [string]$OccurrenceId
    )

    $identity = New-VMStorageIdentity -Name $VMName -VMId $VMId
    $safeOccurrenceId = ConvertTo-RepositorySafeName -Name $OccurrenceId
    $failedRoot = Join-Path $RepositoryRoot '_FAILED'
    $vmRoot = Join-Path $failedRoot $identity
    $occurrenceRoot = Join-Path $vmRoot $safeOccurrenceId

    return [pscustomobject][ordered]@{
        FailedRoot = $failedRoot
        VMIdentity = $identity
        VMId = ConvertTo-NormalizedVMId -VMId $VMId
        VMRoot = $vmRoot
        OccurrenceId = $safeOccurrenceId
        OccurrenceRoot = $occurrenceRoot
        PayloadRoot = Join-Path $occurrenceRoot 'Payload'
        FailurePath = Join-Path $occurrenceRoot 'failure.json'
    }
}

function New-BackupTierManifest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupSetId,

        [Parameter(Mandatory = $true)]
        [string]$TierName,

        [Parameter(Mandatory = $true)]
        [ValidateSet('SUCCESS', 'PARTIAL_SUCCESS')]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [string]$RunId,

        [Parameter(Mandatory = $true)]
        [datetime]$StartedAt,

        [Parameter(Mandatory = $true)]
        [datetime]$FinishedAt,

        [ValidateRange(1, 30)]
        [int]$KeepRestorePoints = 3,

        [object[]]$VMResults = @()
    )

    if (-not (Test-BackupSetId -BackupSetId $BackupSetId)) {
        throw "BackupSetId invalido: '$BackupSetId'."
    }

    return [pscustomobject][ordered]@{
        SchemaVersion = $script:RepositorySchemaVersion
        BackupSetId = $BackupSetId
        TierName = ConvertTo-RepositorySafeName -Name $TierName
        Status = $Status
        RunId = $RunId
        KeepRestorePoints = $KeepRestorePoints
        StartedAt = $StartedAt.ToString('o')
        FinishedAt = $FinishedAt.ToString('o')
        VMResults = @($VMResults)
    }
}

function Get-Schema2BackupTiers {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    if (-not (Test-Path -LiteralPath $RepositoryRoot -PathType Container)) {
        return @()
    }

    $discovered = New-Object System.Collections.Generic.List[object]
    $backupSetDirectories = @(Get-ChildItem -LiteralPath $RepositoryRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-BackupSetId -BackupSetId $_.Name })

    foreach ($backupSetDirectory in $backupSetDirectories) {
        $tierDirectories = @(Get-ChildItem -LiteralPath $backupSetDirectory.FullName -Directory -ErrorAction SilentlyContinue)
        foreach ($tierDirectory in $tierDirectories) {
            $markers = @(@(
                (Join-Path $tierDirectory.FullName 'COMPLETE.marker.json'),
                (Join-Path $tierDirectory.FullName 'PARTIAL.marker.json')
            ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })

            if ($markers.Count -ne 1) { continue }

            try {
                $manifest = Get-Content -LiteralPath $markers[0] -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                $properties = @($manifest.PSObject.Properties.Name)
                if ($properties -notcontains 'SchemaVersion' -or [int]$manifest.SchemaVersion -ne $script:RepositorySchemaVersion) { continue }
                if ($properties -notcontains 'BackupSetId' -or [string]$manifest.BackupSetId -cne $backupSetDirectory.Name) { continue }
                if ($properties -notcontains 'TierName' -or [string]$manifest.TierName -cne $tierDirectory.Name) { continue }
                if ($properties -notcontains 'Status' -or [string]$manifest.Status -notin @('SUCCESS', 'PARTIAL_SUCCESS')) { continue }

                $discovered.Add([pscustomobject][ordered]@{
                    BackupSetId = $backupSetDirectory.Name
                    BackupSetRoot = $backupSetDirectory.FullName
                    TierName = $tierDirectory.Name
                    TierRoot = $tierDirectory.FullName
                    MarkerPath = $markers[0]
                    Manifest = $manifest
                })
            }
            catch {
                # Descoberta e deliberadamente tolerante: entradas invalidas nao pertencem
                # ao schema 2 e ficam intocadas para inspecao manual.
            }
        }
    }

    return $discovered.ToArray()
}
