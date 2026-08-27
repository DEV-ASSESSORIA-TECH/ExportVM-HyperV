$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'TestHelpers.ps1')

$repositoryRoot = Get-RepositoryRoot
. (Join-Path $repositoryRoot 'RepositoryHelpers.ps1')

Describe 'Identificadores e paths do repositorio schema 2' {
    It 'gera BackupSetId deterministico no formato esperado' {
        $id = New-BackupSetId -StartedAt ([datetime]'2026-08-27T21:00:00') -UniqueId ([guid]'01234567-89ab-cdef-0123-456789abcdef')

        $id | Should Be '2026-08-27-01234567'
        Test-BackupSetId -BackupSetId $id | Should Be $true
    }

    It 'rejeita identificadores antigos e reservados' {
        Test-BackupSetId -BackupSetId '2026-08-27_CASCATA_01234567' | Should Be $false
        Test-BackupSetId -BackupSetId '2026-08-27_RUN_01234567' | Should Be $false
        Test-BackupSetId -BackupSetId '_STAGING' | Should Be $false
    }

    It 'combina nome legivel com a identidade permanente da VM' {
        $identity = New-VMStorageIdentity -Name 'SRV/ERP' -VMId 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'

        $identity | Should Be 'SRV_ERP--aaaaaaaa'
    }

    It 'mantem VMIds diferentes distintos mesmo com nomes sanitizados iguais' {
        $first = New-VMStorageIdentity -Name 'SRV/ERP' -VMId 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        $second = New-VMStorageIdentity -Name 'SRV:ERP' -VMId 'bbbbbbbb-cccc-dddd-eeee-ffffffffffff'

        $first | Should Not Be $second
    }

    It 'modela o tier diretamente sob o BackupSetId' {
        $repo = Join-Path $TestDrive 'HyperV-Exports'
        $paths = Get-BackupSetPathModel -RepositoryRoot $repo -BackupSetId '2026-08-27-01234567' -TierName 'SMALL'

        $paths.TierRoot | Should Be (Join-Path $repo '2026-08-27-01234567\SMALL')
        $paths.ArchivesRoot | Should Be (Join-Path $repo '2026-08-27-01234567\SMALL\Archives')
        $paths.MetadataRoot | Should Be (Join-Path $repo '2026-08-27-01234567\SMALL\Metadata')
    }

    It 'modela FAILED por VM sem incluir o tier' {
        $repo = Join-Path $TestDrive 'HyperV-Exports'
        $paths = Get-FailedVMPathModel `
            -RepositoryRoot $repo `
            -VMName 'SRV-ERP' `
            -VMId 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' `
            -OccurrenceId '2026-08-27_21-10-00--01234567'

        $paths.OccurrenceRoot | Should Be (Join-Path $repo '_FAILED\SRV-ERP--aaaaaaaa\2026-08-27_21-10-00--01234567')
        $paths.PayloadRoot | Should Be (Join-Path $repo '_FAILED\SRV-ERP--aaaaaaaa\2026-08-27_21-10-00--01234567\Payload')
        $paths.OccurrenceRoot | Should Not Match 'SMALL|MEDIUM|BIG'
    }
}

Describe 'Manifest e descoberta exclusiva do schema 2' {
    It 'cria manifest com contrato minimo e resultados' {
        $manifest = New-BackupTierManifest `
            -BackupSetId '2026-08-27-01234567' `
            -TierName 'SMALL' `
            -Status 'PARTIAL_SUCCESS' `
            -RunId 'run-1' `
            -StartedAt ([datetime]'2026-08-27T21:00:00') `
            -FinishedAt ([datetime]'2026-08-27T22:00:00') `
            -VMResults @([pscustomobject]@{ VMId = 'a'; Success = $true })

        $manifest.SchemaVersion | Should Be 2
        $manifest.BackupSetId | Should Be '2026-08-27-01234567'
        $manifest.Status | Should Be 'PARTIAL_SUCCESS'
        $manifest.VMResults.Count | Should Be 1
    }

    It 'descobre somente tiers com nome e manifest schema 2 coerentes' {
        $repo = Join-Path $TestDrive 'repository'
        $validTier = Join-Path $repo '2026-08-27-01234567\SMALL'
        $partialTier = Join-Path $repo '2026-08-28-89abcdef\BIG'
        $legacyTier = Join-Path $repo '2026-08-26_CASCATA_deadbeef\SMALL'
        $schema1Tier = Join-Path $repo '2026-08-25-fedcba98\MEDIUM'
        $mismatchTier = Join-Path $repo '2026-08-24-11111111\SMALL'

        foreach ($path in @($validTier, $partialTier, $legacyTier, $schema1Tier, $mismatchTier)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }

        New-BackupTierManifest -BackupSetId '2026-08-27-01234567' -TierName 'SMALL' -Status 'SUCCESS' -RunId '1' -StartedAt (Get-Date) -FinishedAt (Get-Date) |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $validTier 'COMPLETE.marker.json') -Encoding UTF8
        New-BackupTierManifest -BackupSetId '2026-08-28-89abcdef' -TierName 'BIG' -Status 'PARTIAL_SUCCESS' -RunId '2' -StartedAt (Get-Date) -FinishedAt (Get-Date) |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $partialTier 'PARTIAL.marker.json') -Encoding UTF8
        @{ SchemaVersion = 2; BackupSetId = '2026-08-26_CASCATA_deadbeef'; TierName = 'SMALL'; Status = 'SUCCESS' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $legacyTier 'COMPLETE.marker.json') -Encoding UTF8
        @{ SchemaVersion = 1; BackupSetId = '2026-08-25-fedcba98'; TierName = 'MEDIUM'; Status = 'SUCCESS' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $schema1Tier 'COMPLETE.marker.json') -Encoding UTF8
        @{ SchemaVersion = 2; BackupSetId = '2026-08-24-22222222'; TierName = 'SMALL'; Status = 'SUCCESS' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $mismatchTier 'COMPLETE.marker.json') -Encoding UTF8

        $found = @(Get-Schema2BackupTiers -RepositoryRoot $repo)

        $found.Count | Should Be 2
        @($found | Select-Object -ExpandProperty BackupSetId | Sort-Object) -join ',' | Should Be '2026-08-27-01234567,2026-08-28-89abcdef'
    }

    It 'trata repositorio ausente como descoberta vazia' {
        @(Get-Schema2BackupTiers -RepositoryRoot (Join-Path $TestDrive 'missing')).Count | Should Be 0
    }
}
