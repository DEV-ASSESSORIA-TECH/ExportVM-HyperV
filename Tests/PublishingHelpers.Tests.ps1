$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'TestHelpers.ps1')
$repositoryRoot = Get-RepositoryRoot
. (Join-Path $repositoryRoot 'Internal\Helpers\RepositoryHelpers.ps1')
. (Join-Path $repositoryRoot 'Internal\Helpers\RetentionHelpers.ps1')
. (Join-Path $repositoryRoot 'Internal\Helpers\PublishingHelpers.ps1')

Describe 'Publicacao independente por VM' {
    It 'publica arquivo e metadata usando a identidade permanente' {
        $repo = Join-Path $TestDrive 'repo'
        $context = [pscustomobject]@{
            VMName = 'SRV-ERP'; VMId = 'aaaaaaaabbbbccccddddeeeeeeeeeeee'; VMIdentity = 'SRV-ERP--aaaaaaaa'; TierName = 'SMALL'
            VMRoot = Join-Path $TestDrive 'staging\vm'; PayloadRoot = Join-Path $TestDrive 'staging\vm\Payload'
            MetadataRoot = Join-Path $TestDrive 'staging\vm\Metadata'; ArchivePath = Join-Path $TestDrive 'staging\vm\Payload\SRV-ERP--aaaaaaaa.7z'
            OccurrenceId = 'occ-1'
        }
        New-Item -ItemType Directory -Path $context.MetadataRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $context.PayloadRoot -Force | Out-Null
        Set-Content -LiteralPath $context.ArchivePath -Value 'archive'
        Set-Content -LiteralPath (Join-Path $context.MetadataRoot 'result.json') -Value '{}'
        $result = [pscustomobject]@{ Name = 'SRV-ERP'; Success = $true; ArchivePath = $context.ArchivePath; MetadataPath = $context.MetadataRoot; Archive = $null; Metadata = $null }
        $paths = Get-BackupSetPathModel -RepositoryRoot $repo -BackupSetId '2026-08-27-01234567' -TierName 'SMALL'

        Publish-VMTransactionResult -Context $context -Result $result -PathModel $paths | Out-Null

        Test-Path -LiteralPath (Join-Path $paths.ArchivesRoot 'SRV-ERP--aaaaaaaa.7z') -PathType Leaf | Should Be $true
        Test-Path -LiteralPath (Join-Path $paths.MetadataRoot 'SRV-ERP--aaaaaaaa') -PathType Container | Should Be $true
        $result.Archive | Should Be 'Archives\SRV-ERP--aaaaaaaa.7z'
        $result.Metadata | Should Be 'Metadata\SRV-ERP--aaaaaaaa'
        Test-Path -LiteralPath $context.VMRoot | Should Be $false
    }

    It 'preserva somente o payload da VM falha fora dos tiers' {
        $repo = Join-Path $TestDrive 'failed-repo'
        $context = [pscustomobject]@{
            VMName = 'SRV-ERP'; VMId = 'aaaaaaaabbbbccccddddeeeeeeeeeeee'; VMIdentity = 'SRV-ERP--aaaaaaaa'; TierName = 'SMALL'
            VMRoot = Join-Path $TestDrive 'failed-staging\vm'; OccurrenceId = '2026-08-27--run1'
        }
        New-Item -ItemType Directory -Path (Join-Path $context.VMRoot 'Export') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $context.VMRoot 'Export\disk.vhdx') -Value 'partial'
        $result = [pscustomobject]@{
            FailureKind = 'EXPORT_TRANSIENT'; Retryable = $true; CurrentStage = 'EXPORT'; Attempts = 2
            ErrorType = 'System.Exception'; Error = 'falhou'; BackupSetId = '2026-08-27-01234567'; RunId = 'run1'
        }

        $failed = Save-FailedVMTransaction -RepositoryRoot $repo -Context $context -Result $result

        Test-Path -LiteralPath $failed.PayloadRoot -PathType Container | Should Be $true
        Test-Path -LiteralPath $failed.FailurePath -PathType Leaf | Should Be $true
        $failed.OccurrenceRoot | Should Not Match 'SMALL|MEDIUM|BIG'
        (Get-Content -LiteralPath $failed.FailurePath -Raw | ConvertFrom-Json).SchemaVersion | Should Be 2
    }
}

Describe 'Estados e marcadores schema 2' {
    It 'aplica a precedencia de status e codigos' {
        $mixed = Get-BackupOutcome -VMResults @([pscustomobject]@{ Success = $true }, [pscustomobject]@{ Success = $false }) -WarningCount 2
        $mixed.Status | Should Be 'PARTIAL_SUCCESS'
        $mixed.ExitCode | Should Be 1

        (Get-BackupOutcome -VMResults @([pscustomobject]@{ Success = $false })).Status | Should Be 'FAILED'
        (Get-BackupOutcome -VMResults @([pscustomobject]@{ Success = $true }) -WarningCount 1).ExitCode | Should Be 2
        (Get-BackupOutcome -VMResults @([pscustomobject]@{ Success = $true })).ExitCode | Should Be 0
    }

    It 'grava PARTIAL marker atomico com schema 2' {
        $repo = Join-Path $TestDrive 'marker-repo'
        $paths = Get-BackupSetPathModel -RepositoryRoot $repo -BackupSetId '2026-08-27-01234567' -TierName 'SMALL'
        $results = @([pscustomobject]@{ Name = 'ok'; VMId = 'a'; Success = $true }, [pscustomobject]@{ Name = 'bad'; VMId = 'b'; Success = $false })

        $marker = Write-BackupTierManifestV2 -PathModel $paths -Status 'PARTIAL_SUCCESS' -RunId 'run1' -StartedAt (Get-Date) -FinishedAt (Get-Date) -KeepRestorePoints 3 -VMResults $results

        $manifest = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
        $manifest.SchemaVersion | Should Be 2
        $manifest.Status | Should Be 'PARTIAL_SUCCESS'
        Test-Path -LiteralPath $paths.CompleteMarkerPath | Should Be $false
    }

    It 'classifica dez VMs com uma falha como sucesso parcial sem perder as nove validas' {
        $results = New-Object System.Collections.Generic.List[object]
        1..9 | ForEach-Object { $results.Add([pscustomobject]@{ Name = "vm$_"; Success = $true }) }
        $results.Add([pscustomobject]@{ Name = 'vm10'; Success = $false })

        $outcome = Get-BackupOutcome -VMResults $results.ToArray()

        $outcome.Status | Should Be 'PARTIAL_SUCCESS'
        $outcome.ExitCode | Should Be 1
        $outcome.SuccessCount | Should Be 9
        $outcome.FailureCount | Should Be 1
    }
}
