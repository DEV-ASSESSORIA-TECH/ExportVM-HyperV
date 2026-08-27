#requires -Version 5.1

# Descoberta, planejamento e aplicacao isolada de retencao para o schema 2.
# O chamador produtivo sera conectado somente quando a publicacao v1.3 for ativada.

Set-StrictMode -Version 2.0

function Get-OptionalPropertyValue {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()]$DefaultValue = $null
    )

    if ($null -eq $InputObject -or $InputObject.PSObject.Properties.Name -notcontains $Name) {
        return $DefaultValue
    }
    return $InputObject.$Name
}

function Resolve-PathBelowRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$ExpectedTopDirectory
    )

    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "Path relativo esperado, recebido: '$RelativePath'."
    }

    $normalizedRelative = $RelativePath -replace '/', '\'
    $segments = @($normalizedRelative -split '\\')
    if ($segments.Count -lt 2 -or $segments[0] -cne $ExpectedTopDirectory -or $segments -contains '..') {
        throw "Path fora da estrutura '$ExpectedTopDirectory': '$RelativePath'."
    }

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $rootFull $normalizedRelative))
    $prefix = $rootFull + '\'
    if (-not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapa da raiz permitida: '$RelativePath'."
    }
    return $candidate
}

function Assert-PathIsBelowRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    if (-not $pathFull.StartsWith($rootFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path '$Path' nao esta abaixo da raiz permitida '$Root'."
    }
    return $pathFull
}

function Get-DirectoryLength {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return 0L }
    $measure = Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum
    if ($null -eq $measure.Sum) { return 0L }
    return [long]$measure.Sum
}

function Get-Schema2ValidBackupEntries {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($tier in @(Get-Schema2BackupTiers -RepositoryRoot $RepositoryRoot)) {
        $manifest = $tier.Manifest
        $keep = [int](Get-OptionalPropertyValue -InputObject $manifest -Name 'KeepRestorePoints' -DefaultValue 3)
        if ($keep -lt 1) { continue }

        foreach ($vmResult in @(Get-OptionalPropertyValue -InputObject $manifest -Name 'VMResults' -DefaultValue @())) {
            try {
                if (-not [bool](Get-OptionalPropertyValue -InputObject $vmResult -Name 'Success' -DefaultValue $false)) { continue }

                $vmId = ConvertTo-NormalizedVMId -VMId ([string](Get-OptionalPropertyValue -InputObject $vmResult -Name 'VMId'))
                $archiveRelative = [string](Get-OptionalPropertyValue -InputObject $vmResult -Name 'Archive')
                $metadataRelative = [string](Get-OptionalPropertyValue -InputObject $vmResult -Name 'Metadata')
                $archivePath = Resolve-PathBelowRoot -Root $tier.TierRoot -RelativePath $archiveRelative -ExpectedTopDirectory 'Archives'
                $metadataPath = Resolve-PathBelowRoot -Root $tier.TierRoot -RelativePath $metadataRelative -ExpectedTopDirectory 'Metadata'
                if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) { continue }

                $finishedText = [string](Get-OptionalPropertyValue -InputObject $vmResult -Name 'FinishedAt' -DefaultValue $manifest.FinishedAt)
                $entries.Add([pscustomobject][ordered]@{
                    VMId = $vmId
                    VMName = [string](Get-OptionalPropertyValue -InputObject $vmResult -Name 'Name')
                    VMIdentity = [string](Get-OptionalPropertyValue -InputObject $vmResult -Name 'VMIdentity')
                    BackupSetId = $tier.BackupSetId
                    TierName = $tier.TierName
                    CreatedAt = [datetime]$finishedText
                    KeepRestorePoints = $keep
                    ArchivePath = $archivePath
                    MetadataPath = $metadataPath
                    ArchivesRoot = Join-Path $tier.TierRoot 'Archives'
                    TierRoot = $tier.TierRoot
                    BackupSetRoot = $tier.BackupSetRoot
                })
            }
            catch {
                # Resultado incompleto, path inseguro ou VMId invalido nao pertence ao
                # conjunto elegivel para exclusao automatica.
            }
        }
    }
    return $entries.ToArray()
}

function Get-ValidBackupRetentionPlan {
    param(
        [object[]]$Entries = @(),
        [ValidateRange(1, 30)][int]$DefaultKeepRestorePoints = 3
    )

    $keepEntries = New-Object System.Collections.Generic.List[object]
    $deleteEntries = New-Object System.Collections.Generic.List[object]

    foreach ($group in @($Entries | Group-Object VMId)) {
        $ordered = @($group.Group | Sort-Object CreatedAt, BackupSetId -Descending)
        if ($ordered.Count -eq 0) { continue }
        $keep = [int](Get-OptionalPropertyValue -InputObject $ordered[0] -Name 'KeepRestorePoints' -DefaultValue $DefaultKeepRestorePoints)
        if ($keep -lt 1) { $keep = $DefaultKeepRestorePoints }

        foreach ($entry in @($ordered | Select-Object -First $keep)) { $keepEntries.Add($entry) }
        foreach ($entry in @($ordered | Select-Object -Skip $keep)) { $deleteEntries.Add($entry) }
    }

    return [pscustomobject][ordered]@{
        KeepEntries = $keepEntries.ToArray()
        DeleteEntries = $deleteEntries.ToArray()
    }
}

function Remove-ValidBackupEntry {
    param([Parameter(Mandatory = $true)]$Entry)

    [void](Assert-PathIsBelowRoot -Root $Entry.BackupSetRoot -Path $Entry.TierRoot)
    $archivePath = Assert-PathIsBelowRoot -Root $Entry.ArchivesRoot -Path $Entry.ArchivePath
    $metadataPath = Assert-PathIsBelowRoot -Root (Join-Path $Entry.TierRoot 'Metadata') -Path $Entry.MetadataPath

    $archiveBytes = 0L
    if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
        $archiveBytes = [long](Get-Item -LiteralPath $archivePath -Force -ErrorAction Stop).Length
        Remove-Item -LiteralPath $archivePath -Force -ErrorAction Stop
    }
    if (Test-Path -LiteralPath $metadataPath) {
        Remove-Item -LiteralPath $metadataPath -Recurse -Force -ErrorAction Stop
    }

    $archiveChildren = @()
    if (Test-Path -LiteralPath $Entry.ArchivesRoot -PathType Container) {
        $archiveChildren = @(Get-ChildItem -LiteralPath $Entry.ArchivesRoot -Force -ErrorAction SilentlyContinue)
    }
    if ($archiveChildren.Count -eq 0 -and (Test-Path -LiteralPath $Entry.TierRoot -PathType Container)) {
        Remove-Item -LiteralPath $Entry.TierRoot -Recurse -Force -ErrorAction Stop
    }

    $tierChildren = @()
    if (Test-Path -LiteralPath $Entry.BackupSetRoot -PathType Container) {
        $tierChildren = @(Get-ChildItem -LiteralPath $Entry.BackupSetRoot -Force -ErrorAction SilentlyContinue)
    }
    if ($tierChildren.Count -eq 0 -and (Test-Path -LiteralPath $Entry.BackupSetRoot -PathType Container)) {
        Remove-Item -LiteralPath $Entry.BackupSetRoot -Force -ErrorAction Stop
    }

    return [pscustomobject]@{ VMId = $Entry.VMId; ArchivePath = $Entry.ArchivePath; BytesRecovered = $archiveBytes }
}

function Get-Schema2FailedPayloadEntries {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $failedRoot = Join-Path $RepositoryRoot '_FAILED'
    if (-not (Test-Path -LiteralPath $failedRoot -PathType Container)) { return @() }

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($vmDirectory in @(Get-ChildItem -LiteralPath $failedRoot -Directory -ErrorAction SilentlyContinue)) {
        foreach ($occurrence in @(Get-ChildItem -LiteralPath $vmDirectory.FullName -Directory -ErrorAction SilentlyContinue)) {
            $failurePath = Join-Path $occurrence.FullName 'failure.json'
            if (-not (Test-Path -LiteralPath $failurePath -PathType Leaf)) { continue }
            try {
                $failure = Get-Content -LiteralPath $failurePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if ([int](Get-OptionalPropertyValue -InputObject $failure -Name 'SchemaVersion' -DefaultValue 0) -ne 2) { continue }
                $vmIdText = [string](Get-OptionalPropertyValue -InputObject $failure -Name 'VMId')
                $groupKey = if ([string]::IsNullOrWhiteSpace($vmIdText)) { $vmDirectory.Name } else { ConvertTo-NormalizedVMId -VMId $vmIdText }
                $occurredAt = [datetime](Get-OptionalPropertyValue -InputObject $failure -Name 'OccurredAt' -DefaultValue $occurrence.CreationTime.ToString('o'))
                $payloadRoot = Join-Path $occurrence.FullName 'Payload'
                $payloadExists = Test-Path -LiteralPath $payloadRoot -PathType Container
                $entries.Add([pscustomobject][ordered]@{
                    GroupKey = $groupKey
                    VMId = $vmIdText
                    OccurredAt = $occurredAt
                    FailedRoot = $failedRoot
                    OccurrenceRoot = $occurrence.FullName
                    PayloadRoot = $payloadRoot
                    FailurePath = $failurePath
                    HasPayload = $payloadExists
                    PayloadBytes = if ($payloadExists) { Get-DirectoryLength -Path $payloadRoot } else { 0L }
                })
            }
            catch {
                # Registros invalidos ficam intocados para analise manual.
            }
        }
    }
    return $entries.ToArray()
}

function Get-FailedPayloadRetentionPlan {
    param(
        [object[]]$Entries = @(),
        [ValidateRange(0, 30)][int]$KeepPerVM = 3
    )

    $keepEntries = New-Object System.Collections.Generic.List[object]
    $deleteEntries = New-Object System.Collections.Generic.List[object]
    foreach ($group in @($Entries | Where-Object { $_.HasPayload } | Group-Object GroupKey)) {
        $ordered = @($group.Group | Sort-Object OccurredAt, OccurrenceRoot -Descending)
        foreach ($entry in @($ordered | Select-Object -First $KeepPerVM)) { $keepEntries.Add($entry) }
        foreach ($entry in @($ordered | Select-Object -Skip $KeepPerVM)) { $deleteEntries.Add($entry) }
    }
    return [pscustomobject][ordered]@{
        KeepEntries = $keepEntries.ToArray()
        DeleteEntries = $deleteEntries.ToArray()
    }
}

function Remove-FailedPayload {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)][string]$Reason,
        [AllowNull()][Nullable[long]]$SpaceBeforeBytes = $null,
        [AllowNull()][Nullable[long]]$SpaceAfterBytes = $null
    )

    $failedRoot = [string](Get-OptionalPropertyValue -InputObject $Entry -Name 'FailedRoot')
    if ([string]::IsNullOrWhiteSpace($failedRoot)) {
        throw 'Entrada de payload falho nao informa FailedRoot.'
    }
    [void](Assert-PathIsBelowRoot -Root $failedRoot -Path $Entry.OccurrenceRoot)
    $payloadRoot = Assert-PathIsBelowRoot -Root $Entry.OccurrenceRoot -Path $Entry.PayloadRoot
    $failurePath = Assert-PathIsBelowRoot -Root $Entry.OccurrenceRoot -Path $Entry.FailurePath
    $payloadBytes = if (Test-Path -LiteralPath $payloadRoot -PathType Container) {
        Get-DirectoryLength -Path $payloadRoot
    } else { 0L }

    $failure = Get-Content -LiteralPath $failurePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $failure | Add-Member -NotePropertyName PayloadStatus -NotePropertyValue 'DELETION_PENDING' -Force
    $failure | Add-Member -NotePropertyName PayloadDeletionRequestedAt -NotePropertyValue (Get-Date).ToString('o') -Force
    $failure | Add-Member -NotePropertyName PayloadDeletionReason -NotePropertyValue $Reason -Force
    $failure | Add-Member -NotePropertyName PayloadBytesRecovered -NotePropertyValue $payloadBytes -Force
    $failure | Add-Member -NotePropertyName SpaceBeforeBytes -NotePropertyValue $SpaceBeforeBytes -Force
    $failure | Add-Member -NotePropertyName SpaceAfterBytes -NotePropertyValue $SpaceAfterBytes -Force
    $failure | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $failurePath -Encoding UTF8 -ErrorAction Stop

    if (Test-Path -LiteralPath $payloadRoot -PathType Container) {
        Remove-Item -LiteralPath $payloadRoot -Recurse -Force -ErrorAction Stop
    }

    $failure | Add-Member -NotePropertyName PayloadStatus -NotePropertyValue 'DELETED' -Force
    $failure | Add-Member -NotePropertyName PayloadDeletedAt -NotePropertyValue (Get-Date).ToString('o') -Force
    $failure | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $failurePath -Encoding UTF8 -ErrorAction Stop

    return [pscustomobject]@{ GroupKey = $Entry.GroupKey; FailurePath = $failurePath; BytesRecovered = $payloadBytes; Reason = $Reason }
}

function Update-FailedPayloadSpaceAfter {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)][long]$SpaceAfterBytes
    )

    $failedRoot = [string](Get-OptionalPropertyValue -InputObject $Entry -Name 'FailedRoot')
    if ([string]::IsNullOrWhiteSpace($failedRoot)) {
        throw 'Entrada de payload falho nao informa FailedRoot.'
    }
    [void](Assert-PathIsBelowRoot -Root $failedRoot -Path $Entry.OccurrenceRoot)
    $failurePath = Assert-PathIsBelowRoot -Root $Entry.OccurrenceRoot -Path $Entry.FailurePath
    $failure = Get-Content -LiteralPath $failurePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $failure | Add-Member -NotePropertyName SpaceAfterBytes -NotePropertyValue $SpaceAfterBytes -Force
    $failure | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $failurePath -Encoding UTF8 -ErrorAction Stop
}
