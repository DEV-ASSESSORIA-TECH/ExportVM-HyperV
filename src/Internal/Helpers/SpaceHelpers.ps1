#requires -Version 5.1

# Planejamento e execucao da liberacao de espaco usando exclusivamente payloads
# falhos. Backups validos nao entram nas entradas aceitas por estas funcoes.

Set-StrictMode -Version 2.0

function Get-VMRequiredFreeBytes {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(0, 1000000)]
        [double]$MinFreeGB
    )

    $required = [decimal]$MinFreeGB * [decimal]1GB
    if ($required -gt [long]::MaxValue) {
        throw 'A reserva de espaco calculada excede o limite suportado.'
    }
    return [long]$required
}

function Get-FailedPayloadCleanupQueue {
    param(
        [object[]]$Entries = @(),
        [ValidateRange(0, 30)][int]$KeepPerVM = 3
    )

    $retentionPlan = Get-FailedPayloadRetentionPlan -Entries $Entries -KeepPerVM $KeepPerVM
    $normal = @($retentionPlan.DeleteEntries | Sort-Object OccurredAt, OccurrenceRoot)
    $emergency = @($retentionPlan.KeepEntries | Sort-Object OccurredAt, OccurrenceRoot)

    return [pscustomobject][ordered]@{
        NormalRetentionEntries = $normal
        EmergencyEntries = $emergency
    }
}

function Invoke-FailedPayloadCleanupForSpace {
    param(
        [object[]]$Entries = @(),

        [ValidateRange(0, 30)]
        [int]$KeepPerVM = 3,

        [Parameter(Mandatory = $true)]
        [ValidateRange(0, [long]::MaxValue)]
        [long]$RequiredFreeBytes,

        [Parameter(Mandatory = $true)]
        [scriptblock]$GetFreeBytesAction,

        [scriptblock]$DeletePayloadAction = {
            param($FailedEntry, $DeletionReason, $SpaceBefore)
            Remove-FailedPayload -Entry $FailedEntry -Reason $DeletionReason -SpaceBeforeBytes $SpaceBefore
        },

        [scriptblock]$RecordSpaceAfterAction = {
            param($FailedEntry, $SpaceAfter)
            Update-FailedPayloadSpaceAfter -Entry $FailedEntry -SpaceAfterBytes $SpaceAfter
        }
    )

    $queue = Get-FailedPayloadCleanupQueue -Entries $Entries -KeepPerVM $KeepPerVM
    $events = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]
    $initialFreeBytes = [long](& $GetFreeBytesAction)

    foreach ($entry in $queue.NormalRetentionEntries) {
        $before = [long](& $GetFreeBytesAction)
        try {
            $deletionResult = & $DeletePayloadAction $entry 'RETENTION' $before
            $after = [long](& $GetFreeBytesAction)
            & $RecordSpaceAfterAction $entry $after
            $events.Add([pscustomobject][ordered]@{
                Reason = 'RETENTION'
                GroupKey = $entry.GroupKey
                OccurrenceRoot = $entry.OccurrenceRoot
                SpaceBeforeBytes = $before
                SpaceAfterBytes = $after
                BytesRecovered = [long](Get-OptionalPropertyValue -InputObject $deletionResult -Name 'BytesRecovered' -DefaultValue ($after - $before))
                Success = $true
                Error = $null
            })
        }
        catch {
            $errors.Add($_.Exception.Message)
            $events.Add([pscustomobject][ordered]@{
                Reason = 'RETENTION'
                GroupKey = $entry.GroupKey
                OccurrenceRoot = $entry.OccurrenceRoot
                SpaceBeforeBytes = $before
                SpaceAfterBytes = [long](& $GetFreeBytesAction)
                BytesRecovered = 0L
                Success = $false
                Error = $_.Exception.Message
            })
        }
    }

    $currentFreeBytes = [long](& $GetFreeBytesAction)
    $emergencyStatus = 'NOT_NEEDED'
    $missingBytes = [long]0
    $eligiblePayloadBytes = [long]0
    if ($currentFreeBytes -lt $RequiredFreeBytes) {
        $missingBytes = [long]($RequiredFreeBytes - $currentFreeBytes)
        $emergencyEntries = @($queue.EmergencyEntries | Where-Object {
            [long](Get-OptionalPropertyValue -InputObject $_ -Name 'PayloadBytes' -DefaultValue 0L) -gt 0
        })
        [decimal]$eligibleTotal = 0
        foreach ($entry in $emergencyEntries) {
            $eligibleTotal += [long](Get-OptionalPropertyValue -InputObject $entry -Name 'PayloadBytes' -DefaultValue 0L)
        }
        $eligiblePayloadBytes = if ($eligibleTotal -gt [long]::MaxValue) { [long]::MaxValue } else { [long]$eligibleTotal }

        if ($eligibleTotal -lt $missingBytes) {
            $emergencyStatus = 'SKIPPED_INSUFFICIENT_CANDIDATES'
        }
        else {
            $emergencyStatus = 'PERFORMED'
        }

        for ($index = 0; $emergencyStatus -eq 'PERFORMED' -and $index -lt $emergencyEntries.Count; $index++) {
            if ($currentFreeBytes -ge $RequiredFreeBytes) { break }
            [decimal]$remainingPotential = 0
            foreach ($remainingEntry in @($emergencyEntries | Select-Object -Skip $index)) {
                $remainingPotential += [long](Get-OptionalPropertyValue -InputObject $remainingEntry -Name 'PayloadBytes' -DefaultValue 0L)
            }
            if ($remainingPotential -lt ($RequiredFreeBytes - $currentFreeBytes)) {
                $emergencyStatus = 'STOPPED_INSUFFICIENT_REMAINING'
                break
            }

            $entry = $emergencyEntries[$index]
            $expectedBytes = [long](Get-OptionalPropertyValue -InputObject $entry -Name 'PayloadBytes' -DefaultValue 0L)
            $before = $currentFreeBytes
            try {
                $deletionResult = & $DeletePayloadAction $entry 'SPACE_PRESSURE' $before
                $currentFreeBytes = [long](& $GetFreeBytesAction)
                $actualRecovered = [long]($currentFreeBytes - $before)
                & $RecordSpaceAfterAction $entry $currentFreeBytes
                $events.Add([pscustomobject][ordered]@{
                    Reason = 'SPACE_PRESSURE'
                    GroupKey = $entry.GroupKey
                    OccurrenceRoot = $entry.OccurrenceRoot
                    SpaceBeforeBytes = $before
                    SpaceAfterBytes = $currentFreeBytes
                    PayloadBytesExpected = $expectedBytes
                    BytesRecovered = $actualRecovered
                    Success = $true
                    Error = $null
                })
                if ($actualRecovered -le 0) {
                    $emergencyStatus = 'STOPPED_NO_GAIN'
                    break
                }
            }
            catch {
                $errors.Add($_.Exception.Message)
                $currentFreeBytes = [long](& $GetFreeBytesAction)
                $events.Add([pscustomobject][ordered]@{
                    Reason = 'SPACE_PRESSURE'
                    GroupKey = $entry.GroupKey
                    OccurrenceRoot = $entry.OccurrenceRoot
                    SpaceBeforeBytes = $before
                    SpaceAfterBytes = $currentFreeBytes
                    PayloadBytesExpected = $expectedBytes
                    BytesRecovered = 0L
                    Success = $false
                    Error = $_.Exception.Message
                })
            }
        }
        if ($emergencyStatus -eq 'PERFORMED' -and $currentFreeBytes -lt $RequiredFreeBytes) {
            $emergencyStatus = 'EXHAUSTED'
        }
    }

    $finalFreeBytes = [long](& $GetFreeBytesAction)
    return [pscustomobject][ordered]@{
        RequiredFreeBytes = $RequiredFreeBytes
        InitialFreeBytes = $initialFreeBytes
        FinalFreeBytes = $finalFreeBytes
        Sufficient = $finalFreeBytes -ge $RequiredFreeBytes
        MissingBytes = $missingBytes
        EligiblePayloadBytes = $eligiblePayloadBytes
        EmergencyCleanupStatus = $emergencyStatus
        EmergencyDeletionOccurred = @($events | Where-Object { $_.Reason -eq 'SPACE_PRESSURE' -and $_.Success }).Count -gt 0
        Events = $events.ToArray()
        Errors = $errors.ToArray()
    }
}

function Invoke-VMSpacePreparation {
    param(
        [Parameter(Mandatory = $true)][double]$MinFreeGB,
        [object[]]$FailedPayloadEntries = @(),
        [ValidateRange(0, 30)][int]$KeepPerVM = 3,
        [Parameter(Mandatory = $true)][scriptblock]$GetFreeBytesAction,
        [scriptblock]$DeletePayloadAction,
        [scriptblock]$RecordSpaceAfterAction
    )

    $required = Get-VMRequiredFreeBytes -MinFreeGB $MinFreeGB
    $parameters = @{
        Entries = $FailedPayloadEntries
        KeepPerVM = $KeepPerVM
        RequiredFreeBytes = $required
        GetFreeBytesAction = $GetFreeBytesAction
    }
    if ($null -ne $DeletePayloadAction) { $parameters.DeletePayloadAction = $DeletePayloadAction }
    if ($null -ne $RecordSpaceAfterAction) { $parameters.RecordSpaceAfterAction = $RecordSpaceAfterAction }

    $cleanup = Invoke-FailedPayloadCleanupForSpace @parameters
    $failure = $null
    if (-not $cleanup.Sufficient) {
        $failure = [pscustomobject][ordered]@{
            FailureKind = 'INSUFFICIENT_SPACE'
            Retryable = $false
            RequiredFreeBytes = $required
            AvailableFreeBytes = $cleanup.FinalFreeBytes
            Error = "Espaco livre abaixo do minimo configurado. Minimo=$required bytes; disponivel=$($cleanup.FinalFreeBytes) bytes."
        }
    }

    return [pscustomobject][ordered]@{
        Sufficient = $cleanup.Sufficient
        RequiredFreeBytes = $required
        InitialFreeBytes = $cleanup.InitialFreeBytes
        FinalFreeBytes = $cleanup.FinalFreeBytes
        MissingBytes = $cleanup.MissingBytes
        EligiblePayloadBytes = $cleanup.EligiblePayloadBytes
        EmergencyCleanupStatus = $cleanup.EmergencyCleanupStatus
        EmergencyDeletionOccurred = $cleanup.EmergencyDeletionOccurred
        Events = $cleanup.Events
        Errors = $cleanup.Errors
        Failure = $failure
    }
}
