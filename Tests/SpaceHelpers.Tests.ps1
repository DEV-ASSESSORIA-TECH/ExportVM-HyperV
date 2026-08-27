$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'TestHelpers.ps1')

$repositoryRoot = Get-RepositoryRoot
. (Join-Path $repositoryRoot 'RepositoryHelpers.ps1')
. (Join-Path $repositoryRoot 'RetentionHelpers.ps1')
. (Join-Path $repositoryRoot 'SpaceHelpers.ps1')

function New-FailedSpaceEntry {
    param(
        [string]$GroupKey,
        [datetime]$OccurredAt,
        [string]$Suffix
    )
    return [pscustomobject]@{
        GroupKey = $GroupKey
        OccurredAt = $OccurredAt
        OccurrenceRoot = "occurrence-$Suffix"
        HasPayload = $true
    }
}

Describe 'Reserva exata por VM' {
    It 'soma MinFreeGB a duas vezes o tamanho atual sem margem adicional' {
        Get-VMRequiredFreeBytes -MinFreeGB 200 -SourceBytes 25GB | Should Be 250GB
    }

    It 'produz falha deterministica quando todos os payloads sao insuficientes' {
        $state = [pscustomobject]@{ Free = [long]100GB }
        $entries = @(
            New-FailedSpaceEntry -GroupKey 'vm-a' -OccurredAt ([datetime]'2026-08-24') -Suffix '1'
            New-FailedSpaceEntry -GroupKey 'vm-a' -OccurredAt ([datetime]'2026-08-25') -Suffix '2'
        )
        $result = Invoke-VMSpacePreparation `
            -SourceBytes 20GB -MinFreeGB 100 -FailedPayloadEntries $entries -KeepPerVM 3 `
            -GetFreeBytesAction { $state.Free } `
            -DeletePayloadAction { param($entry, $reason, $before) $state.Free += 10GB; [pscustomobject]@{ BytesRecovered = 10GB } } `
            -RecordSpaceAfterAction { }

        $result.Sufficient | Should Be $false
        $result.RequiredFreeBytes | Should Be 140GB
        $result.FinalFreeBytes | Should Be 120GB
        $result.Failure.FailureKind | Should Be 'INSUFFICIENT_SPACE'
        $result.Failure.Retryable | Should Be $false
    }
}

Describe 'Ordem de limpeza de FAILED' {
    It 'aplica retencao normal antes da pressao e para assim que houver espaco' {
        $entries = @()
        foreach ($day in 20..24) {
            $entries += New-FailedSpaceEntry -GroupKey 'vm-a' -OccurredAt ([datetime]"2026-08-$day") -Suffix "$day"
        }
        $state = [pscustomobject]@{ Free = [long]100GB }
        $deleted = New-Object System.Collections.Generic.List[string]

        $result = Invoke-FailedPayloadCleanupForSpace `
            -Entries $entries -KeepPerVM 3 -RequiredFreeBytes 125GB `
            -GetFreeBytesAction { $state.Free } `
            -DeletePayloadAction {
                param($entry, $reason, $before)
                $deleted.Add("$reason/$($entry.OccurrenceRoot)")
                $state.Free += 10GB
                [pscustomobject]@{ BytesRecovered = 10GB }
            } `
            -RecordSpaceAfterAction { }

        $deleted.ToArray() -join ',' | Should Be 'RETENTION/occurrence-20,RETENTION/occurrence-21,SPACE_PRESSURE/occurrence-22'
        $result.Sufficient | Should Be $true
        $result.FinalFreeBytes | Should Be 130GB
        $result.EmergencyDeletionOccurred | Should Be $true
        $result.Events.Count | Should Be 3
    }

    It 'nao faz exclusao emergencial quando a retencao normal ja basta' {
        $entries = @()
        foreach ($day in 20..23) {
            $entries += New-FailedSpaceEntry -GroupKey 'vm-a' -OccurredAt ([datetime]"2026-08-$day") -Suffix "$day"
        }
        $state = [pscustomobject]@{ Free = [long]100GB }

        $result = Invoke-FailedPayloadCleanupForSpace `
            -Entries $entries -KeepPerVM 3 -RequiredFreeBytes 105GB `
            -GetFreeBytesAction { $state.Free } `
            -DeletePayloadAction { param($entry, $reason, $before) $state.Free += 10GB; [pscustomobject]@{ BytesRecovered = 10GB } } `
            -RecordSpaceAfterAction { }

        $result.Sufficient | Should Be $true
        $result.EmergencyDeletionOccurred | Should Be $false
        $result.Events.Count | Should Be 1
        $result.Events[0].Reason | Should Be 'RETENTION'
    }

    It 'ordena exclusoes emergenciais globalmente da mais antiga para a mais nova' {
        $entries = @(
            New-FailedSpaceEntry -GroupKey 'vm-a' -OccurredAt ([datetime]'2026-08-25') -Suffix 'a25'
            New-FailedSpaceEntry -GroupKey 'vm-b' -OccurredAt ([datetime]'2026-08-22') -Suffix 'b22'
            New-FailedSpaceEntry -GroupKey 'vm-a' -OccurredAt ([datetime]'2026-08-23') -Suffix 'a23'
        )
        $state = [pscustomobject]@{ Free = [long]0 }
        $deleted = New-Object System.Collections.Generic.List[string]

        Invoke-FailedPayloadCleanupForSpace `
            -Entries $entries -KeepPerVM 3 -RequiredFreeBytes 2 `
            -GetFreeBytesAction { $state.Free } `
            -DeletePayloadAction { param($entry, $reason, $before) $deleted.Add($entry.OccurrenceRoot); $state.Free++ } `
            -RecordSpaceAfterAction { } | Out-Null

        $deleted.ToArray() -join ',' | Should Be 'occurrence-b22,occurrence-a23'
    }

    It 'registra erro de exclusao e continua tentando outros payloads falhos' {
        $entries = @(
            New-FailedSpaceEntry -GroupKey 'vm-a' -OccurredAt ([datetime]'2026-08-22') -Suffix 'bad'
            New-FailedSpaceEntry -GroupKey 'vm-b' -OccurredAt ([datetime]'2026-08-23') -Suffix 'good'
        )
        $state = [pscustomobject]@{ Free = [long]0 }

        $result = Invoke-FailedPayloadCleanupForSpace `
            -Entries $entries -KeepPerVM 3 -RequiredFreeBytes 1 `
            -GetFreeBytesAction { $state.Free } `
            -DeletePayloadAction {
                param($entry, $reason, $before)
                if ($entry.OccurrenceRoot -eq 'occurrence-bad') { throw 'arquivo bloqueado' }
                $state.Free++
            } `
            -RecordSpaceAfterAction { }

        $result.Sufficient | Should Be $true
        $result.Errors.Count | Should Be 1
        $result.Events.Count | Should Be 2
        @($result.Events | Where-Object { -not $_.Success }).Count | Should Be 1
    }
}
