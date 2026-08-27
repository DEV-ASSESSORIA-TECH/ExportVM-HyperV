#requires -Version 5.1

# Modelo testavel da transacao de uma unica VM. As operacoes de Hyper-V, 7-Zip e
# hash entram como callbacks para manter a orquestracao isolada da infraestrutura.

Set-StrictMode -Version 2.0

function New-VMTransactionContext {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StagingRoot,

        [Parameter(Mandatory = $true)]
        [string]$VMName,

        [Parameter(Mandatory = $true)]
        [string]$VMId,

        [Parameter(Mandatory = $true)]
        [string]$TierName,

        [Parameter(Mandatory = $true)]
        [string]$OccurrenceId
    )

    $identity = New-VMStorageIdentity -Name $VMName -VMId $VMId
    $normalizedVMId = ConvertTo-NormalizedVMId -VMId $VMId
    $vmRoot = Join-Path (Join-Path $StagingRoot 'VMs') $identity
    $payloadRoot = Join-Path $vmRoot 'Payload'

    return [pscustomobject][ordered]@{
        SchemaVersion = 2
        VMName = $VMName
        VMId = $normalizedVMId
        VMIdentity = $identity
        TierName = ConvertTo-RepositorySafeName -Name $TierName
        OccurrenceId = ConvertTo-RepositorySafeName -Name $OccurrenceId
        VMRoot = $vmRoot
        ExportRoot = Join-Path $vmRoot 'Export'
        PayloadRoot = $payloadRoot
        MetadataRoot = Join-Path $vmRoot 'Metadata'
        ArchivePartialPath = Join-Path $payloadRoot "$identity.partial.7z"
        ArchivePath = Join-Path $payloadRoot "$identity.7z"
    }
}

function Initialize-VMTransactionDirectories {
    param(
        [Parameter(Mandatory = $true)]
        $Context
    )

    foreach ($path in @($Context.VMRoot, $Context.ExportRoot, $Context.PayloadRoot, $Context.MetadataRoot)) {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop | Out-Null
        }
    }
}

function Get-StageResultProperty {
    param(
        [AllowNull()]
        $StageResult,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        $DefaultValue = $null
    )

    if ($null -eq $StageResult -or $StageResult.PSObject.Properties.Name -notcontains $Name) {
        return $DefaultValue
    }
    return $StageResult.$Name
}

function Invoke-VMTransaction {
    param(
        [Parameter(Mandatory = $true)]
        $Context,

        [scriptblock]$InitializeAction = { param($TransactionContext) Initialize-VMTransactionDirectories -Context $TransactionContext },

        [Parameter(Mandatory = $true)]
        [scriptblock]$ResetAction,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ExportAction,

        [Parameter(Mandatory = $true)]
        [scriptblock]$CompressAction,

        [Parameter(Mandatory = $true)]
        [scriptblock]$IntegrityAction,

        [Parameter(Mandatory = $true)]
        [scriptblock]$StructureAction,

        [scriptblock]$HashAction,

        [scriptblock]$FinalizeAction,

        [ValidateRange(0, 3)]
        [int]$RetryCount = 0,

        [ValidateRange(0, 3600)]
        [int]$RetryDelaySeconds = 60,

        [scriptblock]$FailureClassifierAction = {
            param($FailureException, $FailureStage)
            Get-VMFailureClassification -Exception $FailureException -Stage $FailureStage
        },

        [scriptblock]$WaitAction = { param($Seconds) Start-Sleep -Seconds $Seconds }
    )

    $startedAt = Get-Date
    $stageResults = New-Object System.Collections.Generic.List[object]
    $result = [pscustomobject][ordered]@{
        SchemaVersion = 2
        Name = $Context.VMName
        VMId = $Context.VMId
        VMIdentity = $Context.VMIdentity
        TierName = $Context.TierName
        OccurrenceId = $Context.OccurrenceId
        Success = $false
        Status = 'FAILED'
        CurrentStage = 'INITIALIZE'
        Attempts = 0
        ExportDuration = [timespan]::Zero
        CompressionDuration = [timespan]::Zero
        IntegrityDuration = [timespan]::Zero
        StructureDuration = [timespan]::Zero
        HashDuration = [timespan]::Zero
        ExportBytes = 0L
        ArchiveBytes = 0L
        ArchiveListedBytes = 0L
        ArchiveFileCount = 0
        ArchiveFolderCount = 0
        VirtualDiskCount = 0
        VmcxCount = 0
        SHA256 = $null
        HashEnabled = $null -ne $HashAction
        ArchivePath = $Context.ArchivePath
        MetadataPath = $Context.MetadataRoot
        Archive = $null
        Metadata = $null
        FailureKind = $null
        Retryable = $false
        ErrorType = $null
        Error = $null
        StartedAt = $startedAt.ToString('o')
        FinishedAt = $null
        StageResults = @()
    }

    for ($attempt = 1; $attempt -le ($RetryCount + 1); $attempt++) {
        $result.Attempts = $attempt
        $result.ExportBytes = 0L
        $result.ArchiveBytes = 0L
        $result.ArchiveListedBytes = 0L
        $result.ExportDuration = [timespan]::Zero
        $result.CompressionDuration = [timespan]::Zero
        $result.IntegrityDuration = [timespan]::Zero
        $result.StructureDuration = [timespan]::Zero
        $result.HashDuration = [timespan]::Zero
        $result.ArchiveFileCount = 0
        $result.ArchiveFolderCount = 0
        $result.VirtualDiskCount = 0
        $result.VmcxCount = 0
        $result.SHA256 = $null
        try {
            $result.CurrentStage = 'INITIALIZE'
            & $InitializeAction $Context

            $result.CurrentStage = 'RESET'
            & $ResetAction $Context $attempt

            $result.CurrentStage = 'EXPORT'
            $export = & $ExportAction $Context $attempt
            $result.ExportBytes = [long](Get-StageResultProperty -StageResult $export -Name 'ExportBytes' -DefaultValue 0L)
            $result.ExportDuration = Get-StageResultProperty -StageResult $export -Name 'Duration' -DefaultValue ([timespan]::Zero)
            $stageResults.Add([pscustomobject]@{ Stage = 'EXPORT'; Attempt = $attempt; Result = $export })

            $result.CurrentStage = 'COMPRESS'
            $compression = & $CompressAction $Context $attempt
            $result.ArchiveBytes = [long](Get-StageResultProperty -StageResult $compression -Name 'ArchiveBytes' -DefaultValue 0L)
            $result.CompressionDuration = Get-StageResultProperty -StageResult $compression -Name 'Duration' -DefaultValue ([timespan]::Zero)
            $stageResults.Add([pscustomobject]@{ Stage = 'COMPRESS'; Attempt = $attempt; Result = $compression })

            $result.CurrentStage = 'INTEGRITY'
            $integrity = & $IntegrityAction $Context $attempt
            $result.IntegrityDuration = Get-StageResultProperty -StageResult $integrity -Name 'Duration' -DefaultValue ([timespan]::Zero)
            $stageResults.Add([pscustomobject]@{ Stage = 'INTEGRITY'; Attempt = $attempt; Result = $integrity })

            $result.CurrentStage = 'STRUCTURE'
            $structure = & $StructureAction $Context $attempt
            $result.StructureDuration = Get-StageResultProperty -StageResult $structure -Name 'Duration' -DefaultValue ([timespan]::Zero)
            $result.ArchiveListedBytes = [long](Get-StageResultProperty -StageResult $structure -Name 'ArchiveListedBytes' -DefaultValue 0L)
            $result.ArchiveFileCount = [int](Get-StageResultProperty -StageResult $structure -Name 'ArchiveFileCount' -DefaultValue 0)
            $result.ArchiveFolderCount = [int](Get-StageResultProperty -StageResult $structure -Name 'ArchiveFolderCount' -DefaultValue 0)
            $result.VirtualDiskCount = [int](Get-StageResultProperty -StageResult $structure -Name 'VirtualDiskCount' -DefaultValue 0)
            $result.VmcxCount = [int](Get-StageResultProperty -StageResult $structure -Name 'VmcxCount' -DefaultValue 0)
            $stageResults.Add([pscustomobject]@{ Stage = 'STRUCTURE'; Attempt = $attempt; Result = $structure })

            if ($null -ne $HashAction) {
                $result.CurrentStage = 'HASH'
                $hash = & $HashAction $Context $attempt
                $result.SHA256 = [string](Get-StageResultProperty -StageResult $hash -Name 'SHA256')
                $result.HashDuration = Get-StageResultProperty -StageResult $hash -Name 'Duration' -DefaultValue ([timespan]::Zero)
                $stageResults.Add([pscustomobject]@{ Stage = 'HASH'; Attempt = $attempt; Result = $hash })
            }

            if ($null -ne $FinalizeAction) {
                $result.CurrentStage = 'FINALIZE'
                $finalization = & $FinalizeAction $Context $attempt
                $stageResults.Add([pscustomobject]@{ Stage = 'FINALIZE'; Attempt = $attempt; Result = $finalization })
            }

            $result.Success = $true
            $result.Status = 'SUCCESS'
            $result.CurrentStage = 'COMPLETE'
            $result.FailureKind = $null
            $result.Retryable = $false
            $result.ErrorType = $null
            $result.Error = $null
            break
        }
        catch {
            $result.Success = $false
            $result.Status = 'FAILED'
            $classification = & $FailureClassifierAction $_.Exception $result.CurrentStage
            $result.FailureKind = [string]$classification.FailureKind
            $result.Retryable = [bool]$classification.Retryable
            $result.ErrorType = $_.Exception.GetType().FullName
            $result.Error = $_.Exception.Message
            $stageResults.Add([pscustomobject]@{
                Stage = $result.CurrentStage
                Attempt = $attempt
                FailureKind = $result.FailureKind
                Retryable = $result.Retryable
                ErrorType = $result.ErrorType
                Error = $result.Error
            })

            if ($result.Retryable -and $attempt -le $RetryCount) {
                & $WaitAction $RetryDelaySeconds
            } else {
                break
            }
        }
    }

    $result.FinishedAt = (Get-Date).ToString('o')
    $result.StageResults = $stageResults.ToArray()
    return $result
}
