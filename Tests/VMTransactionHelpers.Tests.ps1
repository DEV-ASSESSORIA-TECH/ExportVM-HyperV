$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'TestHelpers.ps1')

$repositoryRoot = Get-RepositoryRoot
. (Join-Path $repositoryRoot 'RepositoryHelpers.ps1')
. (Join-Path $repositoryRoot 'FailureClassificationHelpers.ps1')
. (Join-Path $repositoryRoot 'VMTransactionHelpers.ps1')

function New-TestTransactionContext {
    param(
        [string]$Name = 'SRV-ERP',
        [string]$VMId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    )

    return New-VMTransactionContext `
        -StagingRoot (Join-Path $TestDrive 'staging') `
        -VMName $Name `
        -VMId $VMId `
        -TierName 'SMALL' `
        -OccurrenceId '2026-08-27_21-00-00--01234567'
}

Describe 'Contexto isolado por VM' {
    It 'reserva payload exportacao e metadata dentro da raiz exclusiva da VM' {
        $context = New-TestTransactionContext

        $context.VMRoot | Should Match 'VMs\\SRV-ERP--aaaaaaaa$'
        $context.ExportRoot | Should Be (Join-Path $context.VMRoot 'Export')
        $context.PayloadRoot | Should Be (Join-Path $context.VMRoot 'Payload')
        $context.MetadataRoot | Should Be (Join-Path $context.VMRoot 'Metadata')
        $context.ArchivePath | Should Be (Join-Path $context.PayloadRoot 'SRV-ERP--aaaaaaaa.7z')
    }

    It 'nao compartilha paths entre VMs com o mesmo nome' {
        $first = New-TestTransactionContext -VMId 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        $second = New-TestTransactionContext -VMId 'bbbbbbbb-cccc-dddd-eeee-ffffffffffff'

        $first.VMRoot | Should Not Be $second.VMRoot
        $first.MetadataRoot | Should Not Be $second.MetadataRoot
    }
}

Describe 'Orquestracao da transacao de VM' {
    It 'converte falha ao preparar os diretorios em resultado da propria VM' {
        $context = New-TestTransactionContext -Name 'SRV-NEW' -VMId 'cccccccc-dddd-eeee-ffff-000000000000'
        $state = [pscustomobject]@{ ExportCalled = $false }

        $result = Invoke-VMTransaction `
            -Context $context `
            -InitializeAction { throw 'staging sem acesso' } `
            -ResetAction { } `
            -ExportAction { $state.ExportCalled = $true } `
            -CompressAction { } `
            -IntegrityAction { } `
            -StructureAction { }

        $result.Success | Should Be $false
        $result.CurrentStage | Should Be 'INITIALIZE'
        $result.FailureKind | Should Be 'DETERMINISTIC_OPERATION'
        $result.Retryable | Should Be $false
        $result.Error | Should Be 'staging sem acesso'
        $state.ExportCalled | Should Be $false
    }

    It 'executa as etapas em ordem e materializa o resultado aprovado' {
        $context = New-TestTransactionContext
        $calls = New-Object System.Collections.Generic.List[string]

        $result = Invoke-VMTransaction `
            -Context $context `
            -ResetAction { param($ctx, $attempt) $calls.Add("RESET:$attempt") } `
            -ExportAction { param($ctx, $attempt) $calls.Add('EXPORT'); [pscustomobject]@{ ExportBytes = 1000L } } `
            -CompressAction { param($ctx, $attempt) $calls.Add('COMPRESS'); [pscustomobject]@{ ArchiveBytes = 600L } } `
            -IntegrityAction { param($ctx, $attempt) $calls.Add('INTEGRITY'); [pscustomobject]@{ Passed = $true } } `
            -StructureAction { param($ctx, $attempt) $calls.Add('STRUCTURE'); [pscustomobject]@{ ArchiveListedBytes = 1000L; ArchiveFileCount = 8; ArchiveFolderCount = 3; VirtualDiskCount = 1; VmcxCount = 1 } }

        $calls.ToArray() -join ',' | Should Be 'RESET:1,EXPORT,COMPRESS,INTEGRITY,STRUCTURE'
        $result.Success | Should Be $true
        $result.Status | Should Be 'SUCCESS'
        $result.CurrentStage | Should Be 'COMPLETE'
        $result.Attempts | Should Be 1
        $result.ExportBytes | Should Be 1000L
        $result.ArchiveBytes | Should Be 600L
        $result.ArchiveListedBytes | Should Be 1000L
        $result.VirtualDiskCount | Should Be 1
        $result.VmcxCount | Should Be 1
        $result.HashEnabled | Should Be $false
        $result.StageResults.Count | Should Be 4
    }

    It 'executa hash somente quando o callback foi fornecido' {
        $context = New-TestTransactionContext

        $result = Invoke-VMTransaction `
            -Context $context `
            -ResetAction { } `
            -ExportAction { [pscustomobject]@{ ExportBytes = 1000L } } `
            -CompressAction { [pscustomobject]@{ ArchiveBytes = 600L } } `
            -IntegrityAction { [pscustomobject]@{ Passed = $true } } `
            -StructureAction { [pscustomobject]@{ ArchiveListedBytes = 1000L } } `
            -HashAction { [pscustomobject]@{ SHA256 = ('a' * 64) } }

        $result.Success | Should Be $true
        $result.HashEnabled | Should Be $true
        $result.SHA256 | Should Be ('a' * 64)
        @($result.StageResults | Select-Object -ExpandProperty Stage) -contains 'HASH' | Should Be $true
    }

    It 'so aprova a transacao depois de finalizar o arquivo da VM' {
        $context = New-TestTransactionContext

        $result = Invoke-VMTransaction `
            -Context $context `
            -ResetAction { } `
            -ExportAction { [pscustomobject]@{ ExportBytes = 1000L } } `
            -CompressAction { [pscustomobject]@{ ArchiveBytes = 600L } } `
            -IntegrityAction { [pscustomobject]@{ Passed = $true } } `
            -StructureAction { [pscustomobject]@{ ArchiveListedBytes = 1000L } } `
            -FinalizeAction { throw 'nao foi possivel finalizar o arquivo' }

        $result.Success | Should Be $false
        $result.CurrentStage | Should Be 'FINALIZE'
        $result.Status | Should Be 'FAILED'
        $result.Error | Should Be 'nao foi possivel finalizar o arquivo'
    }

    It 'interrompe etapas posteriores registra a falha e preserva o payload da VM' {
        $context = New-TestTransactionContext
        $calls = New-Object System.Collections.Generic.List[string]

        $result = Invoke-VMTransaction `
            -Context $context `
            -ResetAction { $calls.Add('RESET') } `
            -ExportAction { $calls.Add('EXPORT'); [pscustomobject]@{ ExportBytes = 1000L } } `
            -CompressAction { $calls.Add('COMPRESS'); throw '7-Zip indisponivel' } `
            -IntegrityAction { $calls.Add('INTEGRITY') } `
            -StructureAction { $calls.Add('STRUCTURE') }

        $calls.ToArray() -join ',' | Should Be 'RESET,EXPORT,COMPRESS'
        $result.Success | Should Be $false
        $result.Status | Should Be 'FAILED'
        $result.CurrentStage | Should Be 'COMPRESS'
        $result.FailureKind | Should Be 'SEVEN_ZIP_TRANSIENT'
        $result.Retryable | Should Be $true
        $result.Error | Should Be '7-Zip indisponivel'
        Test-Path -LiteralPath $context.PayloadRoot -PathType Container | Should Be $true
    }

    It 'registra cada tentativa sem misturar o estado de outra VM' {
        $context = New-TestTransactionContext
        $state = [pscustomobject]@{ Exports = 0; Waits = 0 }

        $result = Invoke-VMTransaction `
            -Context $context `
            -ResetAction { } `
            -ExportAction { $state.Exports++; if ($state.Exports -eq 1) { throw 'falha temporaria' }; [pscustomobject]@{ ExportBytes = 1000L } } `
            -CompressAction { [pscustomobject]@{ ArchiveBytes = 600L } } `
            -IntegrityAction { [pscustomobject]@{ Passed = $true } } `
            -StructureAction { [pscustomobject]@{ ArchiveListedBytes = 1000L } } `
            -RetryCount 1 `
            -RetryDelaySeconds 60 `
            -WaitAction { param($seconds) $state.Waits++ }

        $result.Success | Should Be $true
        $result.Attempts | Should Be 2
        $state.Exports | Should Be 2
        $state.Waits | Should Be 1
        @($result.StageResults | Where-Object {
            $_.PSObject.Properties.Name -contains 'Error' -and -not [string]::IsNullOrWhiteSpace([string]$_.Error)
        }).Count | Should Be 1
    }
}
