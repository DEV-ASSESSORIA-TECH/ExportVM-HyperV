$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'TestHelpers.ps1')

$repositoryRoot = Get-RepositoryRoot
. (Join-Path $repositoryRoot 'Internal\Helpers\RepositoryHelpers.ps1')
. (Join-Path $repositoryRoot 'Internal\Helpers\FailureClassificationHelpers.ps1')
. (Join-Path $repositoryRoot 'Internal\Helpers\VMTransactionHelpers.ps1')

function New-RetryTestContext {
    return New-VMTransactionContext `
        -StagingRoot (Join-Path $TestDrive 'retry-staging') `
        -VMName 'SRV-ERP' `
        -VMId 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' `
        -TierName 'SMALL' `
        -OccurrenceId '2026-08-27_21-00-00--01234567'
}

Describe 'Classificacao de falhas' {
    It 'preserva classificacao explicita independente da etapa' {
        $exception = New-VMFailureException -Message 'sem espaco' -FailureKind 'INSUFFICIENT_SPACE' -Retryable $false
        $classification = Get-VMFailureClassification -Exception $exception -Stage 'EXPORT'

        $classification.FailureKind | Should Be 'INSUFFICIENT_SPACE'
        $classification.Retryable | Should Be $false
        $classification.Source | Should Be 'EXPLICIT'
    }

    It 'classifica I/O e timeout como transitorios' {
        (Get-VMFailureClassification -Exception (New-Object System.IO.IOException('I/O ocupado')) -Stage 'INITIALIZE').Retryable | Should Be $true
        (Get-VMFailureClassification -Exception (New-Object System.TimeoutException('timeout')) -Stage 'STRUCTURE').Retryable | Should Be $true
    }

    It 'classifica acesso negado e estrutura invalida como deterministicas' {
        (Get-VMFailureClassification -Exception (New-Object System.UnauthorizedAccessException('negado')) -Stage 'EXPORT').Retryable | Should Be $false
        $structure = Get-VMFailureClassification -Exception (New-Object System.Exception('estrutura divergente')) -Stage 'STRUCTURE'
        $structure.FailureKind | Should Be 'INVALID_STRUCTURE'
        $structure.Retryable | Should Be $false
    }
}

Describe 'Aplicacao de retry na transacao' {
    It 'nao repete nem aguarda uma falha deterministica explicita' {
        $context = New-RetryTestContext
        $state = [pscustomobject]@{ Exports = 0; Waits = 0 }

        $result = Invoke-VMTransaction `
            -Context $context `
            -ResetAction { } `
            -ExportAction {
                $state.Exports++
                Throw-VMFailure -Message 'sem espaco' -FailureKind 'INSUFFICIENT_SPACE' -Retryable $false
            } `
            -CompressAction { } -IntegrityAction { } -StructureAction { } `
            -RetryCount 3 -WaitAction { $state.Waits++ }

        $result.Success | Should Be $false
        $result.Attempts | Should Be 1
        $result.FailureKind | Should Be 'INSUFFICIENT_SPACE'
        $result.Retryable | Should Be $false
        $state.Exports | Should Be 1
        $state.Waits | Should Be 0
    }

    It 'repete uma falha transitoria e aguarda somente entre tentativas' {
        $context = New-RetryTestContext
        $state = [pscustomobject]@{ Exports = 0; Waits = 0 }

        $result = Invoke-VMTransaction `
            -Context $context `
            -ResetAction { } `
            -ExportAction {
                $state.Exports++
                if ($state.Exports -eq 1) { throw (New-Object System.IO.IOException('arquivo em uso')) }
                [pscustomobject]@{ ExportBytes = 1000L }
            } `
            -CompressAction { [pscustomobject]@{ ArchiveBytes = 500L } } `
            -IntegrityAction { [pscustomobject]@{ Passed = $true } } `
            -StructureAction { [pscustomobject]@{ ArchiveListedBytes = 1000L } } `
            -RetryCount 1 -RetryDelaySeconds 60 -WaitAction { param($seconds) $state.Waits++ }

        $result.Success | Should Be $true
        $result.Attempts | Should Be 2
        $state.Exports | Should Be 2
        $state.Waits | Should Be 1
    }

    It 'nao repete uma divergencia estrutural mesmo com retries disponiveis' {
        $context = New-RetryTestContext
        $state = [pscustomobject]@{ Structures = 0; Waits = 0 }

        $result = Invoke-VMTransaction `
            -Context $context `
            -ResetAction { } `
            -ExportAction { [pscustomobject]@{ ExportBytes = 1000L } } `
            -CompressAction { [pscustomobject]@{ ArchiveBytes = 500L } } `
            -IntegrityAction { [pscustomobject]@{ Passed = $true } } `
            -StructureAction { $state.Structures++; throw 'VMCX ausente' } `
            -RetryCount 3 -WaitAction { $state.Waits++ }

        $result.Success | Should Be $false
        $result.Attempts | Should Be 1
        $result.FailureKind | Should Be 'INVALID_STRUCTURE'
        $state.Structures | Should Be 1
        $state.Waits | Should Be 0
    }
}
