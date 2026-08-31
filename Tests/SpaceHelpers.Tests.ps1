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
        [string]$Suffix,
        [long]$PayloadBytes = 10GB
    )
    return [pscustomobject]@{
        GroupKey = $GroupKey
        OccurredAt = $OccurredAt
        OccurrenceRoot = "occurrence-$Suffix"
        HasPayload = $true
        PayloadBytes = $PayloadBytes
    }
}

Describe 'Minimo configurado antes de cada VM' {
    It 'usa somente MinFreeGB como requisito em bytes' {
        Get-VMRequiredFreeBytes -MinFreeGB 200 | Should Be 200GB
    }

    It 'nao depende do tamanho atual dos discos da VM' {
        $state = [pscustomobject]@{ Free = [long]200GB }
        $result = Invoke-VMSpacePreparation -MinFreeGB 200 `
            -GetFreeBytesAction { $state.Free } `
            -DeletePayloadAction { throw 'nao deve excluir' } `
            -RecordSpaceAfterAction { }

        $result.Sufficient | Should Be $true
        $result.RequiredFreeBytes | Should Be 200GB
        $result.EmergencyCleanupStatus | Should Be 'NOT_NEEDED'
    }

    It 'falha de forma deterministica sem apagar protegidos quando a soma e insuficiente' {
        $state = [pscustomobject]@{ Free = [long]100GB }
        $entries = @(
            New-FailedSpaceEntry -GroupKey 'vm-a' -OccurredAt ([datetime]'2026-08-24') -Suffix '1' -PayloadBytes 10GB
            New-FailedSpaceEntry -GroupKey 'vm-b' -OccurredAt ([datetime]'2026-08-25') -Suffix '2' -PayloadBytes 10GB
        )
        $deleted = New-Object System.Collections.Generic.List[string]
        $result = Invoke-VMSpacePreparation -MinFreeGB 200 -FailedPayloadEntries $entries -KeepPerVM 3 `
            -GetFreeBytesAction { $state.Free } `
            -DeletePayloadAction { param($entry) $deleted.Add($entry.OccurrenceRoot) } `
            -RecordSpaceAfterAction { }

        $result.Sufficient | Should Be $false
        $result.RequiredFreeBytes | Should Be 200GB
        $result.MissingBytes | Should Be 100GB
        $result.EligiblePayloadBytes | Should Be 20GB
        $result.EmergencyCleanupStatus | Should Be 'SKIPPED_INSUFFICIENT_CANDIDATES'
        $deleted.Count | Should Be 0
        $result.Failure.FailureKind | Should Be 'INSUFFICIENT_SPACE'
        $result.Failure.Retryable | Should Be $false
    }

    It 'avalia novamente a VM seguinte depois de uma falha isolada' {
        $state = [pscustomobject]@{ Free = [long]100GB }
        $first = Invoke-VMSpacePreparation -MinFreeGB 200 -GetFreeBytesAction { $state.Free }
        $state.Free = 210GB
        $second = Invoke-VMSpacePreparation -MinFreeGB 200 -GetFreeBytesAction { $state.Free }

        $first.Sufficient | Should Be $false
        $second.Sufficient | Should Be $true
    }
}

Describe 'Limpeza conservadora de FAILED' {
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
            } `
            -RecordSpaceAfterAction { }

        $deleted.ToArray() -join ',' | Should Be 'RETENTION/occurrence-20,RETENTION/occurrence-21,SPACE_PRESSURE/occurrence-22'
        $result.Sufficient | Should Be $true
        $result.FinalFreeBytes | Should Be 130GB
        $result.EmergencyCleanupStatus | Should Be 'PERFORMED'
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
            -DeletePayloadAction { param($entry) $state.Free += 10GB } `
            -RecordSpaceAfterAction { }

        $result.Sufficient | Should Be $true
        $result.EmergencyCleanupStatus | Should Be 'NOT_NEEDED'
        $result.Events.Count | Should Be 1
        $result.Events[0].Reason | Should Be 'RETENTION'
    }

    It 'ordena exclusoes emergenciais globalmente da mais antiga para a mais nova' {
        $entries = @(
            New-FailedSpaceEntry -GroupKey 'vm-a' -OccurredAt ([datetime]'2026-08-25') -Suffix 'a25' -PayloadBytes 1
            New-FailedSpaceEntry -GroupKey 'vm-b' -OccurredAt ([datetime]'2026-08-22') -Suffix 'b22' -PayloadBytes 1
            New-FailedSpaceEntry -GroupKey 'vm-a' -OccurredAt ([datetime]'2026-08-23') -Suffix 'a23' -PayloadBytes 1
        )
        $state = [pscustomobject]@{ Free = [long]0 }
        $deleted = New-Object System.Collections.Generic.List[string]

        Invoke-FailedPayloadCleanupForSpace `
            -Entries $entries -KeepPerVM 3 -RequiredFreeBytes 2 `
            -GetFreeBytesAction { $state.Free } `
            -DeletePayloadAction { param($entry) $deleted.Add($entry.OccurrenceRoot); $state.Free++ } `
            -RecordSpaceAfterAction { } | Out-Null

        $deleted.ToArray() -join ',' | Should Be 'occurrence-b22,occurrence-a23'
    }

    It 'preserva todos os protegidos quando o total elegivel nao cobre o deficit' {
        $entries = @(
            New-FailedSpaceEntry -GroupKey 'vm-a' -OccurredAt ([datetime]'2026-08-22') -Suffix 'a' -PayloadBytes 20GB
            New-FailedSpaceEntry -GroupKey 'vm-b' -OccurredAt ([datetime]'2026-08-23') -Suffix 'b' -PayloadBytes 20GB
        )
        $state = [pscustomobject]@{ Free = [long]100GB }
        $deleted = New-Object System.Collections.Generic.List[string]

        $result = Invoke-FailedPayloadCleanupForSpace `
            -Entries $entries -KeepPerVM 3 -RequiredFreeBytes 150GB `
            -GetFreeBytesAction { $state.Free } `
            -DeletePayloadAction { param($entry) $deleted.Add($entry.OccurrenceRoot) } `
            -RecordSpaceAfterAction { }

        $deleted.Count | Should Be 0
        $result.EmergencyCleanupStatus | Should Be 'SKIPPED_INSUFFICIENT_CANDIDATES'
    }

    It 'ignora payload vazio na selecao emergencial' {
        $entries = @(
            New-FailedSpaceEntry -GroupKey 'vm-a' -OccurredAt ([datetime]'2026-08-20') -Suffix 'empty' -PayloadBytes 0
            New-FailedSpaceEntry -GroupKey 'vm-b' -OccurredAt ([datetime]'2026-08-21') -Suffix 'useful' -PayloadBytes 20GB
        )
        $state = [pscustomobject]@{ Free = [long]100GB }
        $deleted = New-Object System.Collections.Generic.List[string]

        $result = Invoke-FailedPayloadCleanupForSpace `
            -Entries $entries -KeepPerVM 3 -RequiredFreeBytes 120GB `
            -GetFreeBytesAction { $state.Free } `
            -DeletePayloadAction { param($entry) $deleted.Add($entry.OccurrenceRoot); $state.Free += 20GB } `
            -RecordSpaceAfterAction { }

        $deleted.ToArray() -join ',' | Should Be 'occurrence-useful'
        $result.Sufficient | Should Be $true
    }

    It 'interrompe a emergencia quando uma exclusao nao aumenta o espaco livre' {
        $entries = @(
            New-FailedSpaceEntry -GroupKey 'vm-a' -OccurredAt ([datetime]'2026-08-20') -Suffix 'first' -PayloadBytes 20GB
            New-FailedSpaceEntry -GroupKey 'vm-b' -OccurredAt ([datetime]'2026-08-21') -Suffix 'second' -PayloadBytes 20GB
        )
        $state = [pscustomobject]@{ Free = [long]100GB }
        $deleted = New-Object System.Collections.Generic.List[string]

        $result = Invoke-FailedPayloadCleanupForSpace `
            -Entries $entries -KeepPerVM 3 -RequiredFreeBytes 120GB `
            -GetFreeBytesAction { $state.Free } `
            -DeletePayloadAction { param($entry) $deleted.Add($entry.OccurrenceRoot) } `
            -RecordSpaceAfterAction { }

        $deleted.ToArray() -join ',' | Should Be 'occurrence-first'
        $result.EmergencyCleanupStatus | Should Be 'STOPPED_NO_GAIN'
        $result.Sufficient | Should Be $false
    }

    It 'para quando o ganho parcial torna os candidatos restantes insuficientes' {
        $entries = @(
            New-FailedSpaceEntry -GroupKey 'vm-a' -OccurredAt ([datetime]'2026-08-20') -Suffix 'first' -PayloadBytes 20GB
            New-FailedSpaceEntry -GroupKey 'vm-b' -OccurredAt ([datetime]'2026-08-21') -Suffix 'second' -PayloadBytes 20GB
        )
        $state = [pscustomobject]@{ Free = [long]100GB }
        $deleted = New-Object System.Collections.Generic.List[string]

        $result = Invoke-FailedPayloadCleanupForSpace `
            -Entries $entries -KeepPerVM 3 -RequiredFreeBytes 130GB `
            -GetFreeBytesAction { $state.Free } `
            -DeletePayloadAction { param($entry) $deleted.Add($entry.OccurrenceRoot); $state.Free += 5GB } `
            -RecordSpaceAfterAction { }

        $deleted.ToArray() -join ',' | Should Be 'occurrence-first'
        $result.EmergencyCleanupStatus | Should Be 'STOPPED_INSUFFICIENT_REMAINING'
        $result.Sufficient | Should Be $false
    }

    It 'registra erro de exclusao e usa outro payload quando ele ainda pode resolver' {
        $entries = @(
            New-FailedSpaceEntry -GroupKey 'vm-a' -OccurredAt ([datetime]'2026-08-22') -Suffix 'bad' -PayloadBytes 1
            New-FailedSpaceEntry -GroupKey 'vm-b' -OccurredAt ([datetime]'2026-08-23') -Suffix 'good' -PayloadBytes 1
        )
        $state = [pscustomobject]@{ Free = [long]0 }

        $result = Invoke-FailedPayloadCleanupForSpace `
            -Entries $entries -KeepPerVM 3 -RequiredFreeBytes 1 `
            -GetFreeBytesAction { $state.Free } `
            -DeletePayloadAction {
                param($entry)
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
