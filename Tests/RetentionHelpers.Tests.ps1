$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'TestHelpers.ps1')

$repositoryRoot = Get-RepositoryRoot
. (Join-Path $repositoryRoot 'Internal\Helpers\RepositoryHelpers.ps1')
. (Join-Path $repositoryRoot 'Internal\Helpers\RetentionHelpers.ps1')

function New-RetentionEntry {
    param(
        [string]$VMId,
        [datetime]$CreatedAt,
        [string]$BackupSetId,
        [int]$Keep = 3
    )
    return [pscustomobject]@{ VMId = $VMId; CreatedAt = $CreatedAt; BackupSetId = $BackupSetId; KeepRestorePoints = $Keep }
}

Describe 'Descoberta de arquivos validos do schema 2' {
    It 'materializa somente resultados aprovados com paths confinados ao tier' {
        $repo = Join-Path $TestDrive 'discover-repo'
        $tierRoot = Join-Path $repo '2026-08-27-01234567\SMALL'
        $archiveRelative = 'Archives\SRV-ERP--aaaaaaaa.7z'
        $metadataRelative = 'Metadata\SRV-ERP--aaaaaaaa'
        New-Item -ItemType Directory -Path (Join-Path $tierRoot $metadataRelative) -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $tierRoot 'Archives') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $tierRoot $archiveRelative) -Value 'arquivo valido'

        $results = @(
            [pscustomobject]@{
                Name = 'SRV-ERP'; VMId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; VMIdentity = 'SRV-ERP--aaaaaaaa'
                Success = $true; Archive = $archiveRelative; Metadata = $metadataRelative; FinishedAt = '2026-08-27T22:00:00.0000000'
            },
            [pscustomobject]@{
                Name = 'INVALIDA'; VMId = 'bbbbbbbb-cccc-dddd-eeee-ffffffffffff'; VMIdentity = 'INVALIDA--bbbbbbbb'
                Success = $true; Archive = 'Archives\..\outside.7z'; Metadata = 'Metadata\INVALIDA--bbbbbbbb'; FinishedAt = '2026-08-27T22:00:00.0000000'
            }
        )
        New-BackupTierManifest `
            -BackupSetId '2026-08-27-01234567' -TierName 'SMALL' -Status 'SUCCESS' -RunId 'run-1' `
            -StartedAt ([datetime]'2026-08-27T21:00:00') -FinishedAt ([datetime]'2026-08-27T22:00:00') -VMResults $results |
            ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $tierRoot 'COMPLETE.marker.json') -Encoding UTF8

        $entries = @(Get-Schema2ValidBackupEntries -RepositoryRoot $repo)

        $entries.Count | Should Be 1
        $entries[0].VMId | Should Be 'aaaaaaaabbbbccccddddeeeeeeeeeeee'
        $entries[0].KeepRestorePoints | Should Be 3
    }
}

Describe 'Planejamento de backups validos por VM' {
    It 'mantem tres por VM atraves de nomes noites e tiers diferentes' {
        $vmId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        $entries = @(
            New-RetentionEntry -VMId $vmId -CreatedAt ([datetime]'2026-08-24') -BackupSetId '2026-08-24-00000001'
            New-RetentionEntry -VMId $vmId -CreatedAt ([datetime]'2026-08-25') -BackupSetId '2026-08-25-00000002'
            New-RetentionEntry -VMId $vmId -CreatedAt ([datetime]'2026-08-26') -BackupSetId '2026-08-26-00000003'
            New-RetentionEntry -VMId $vmId -CreatedAt ([datetime]'2026-08-27') -BackupSetId '2026-08-27-00000004'
        )

        $plan = Get-ValidBackupRetentionPlan -Entries $entries

        $plan.KeepEntries.Count | Should Be 3
        $plan.DeleteEntries.Count | Should Be 1
        $plan.DeleteEntries[0].BackupSetId | Should Be '2026-08-24-00000001'
    }

    It 'nao mistura historicos de VMIds diferentes' {
        $entries = @()
        foreach ($day in 20..23) {
            $entries += New-RetentionEntry -VMId 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' -CreatedAt ([datetime]"2026-08-$day") -BackupSetId "2026-08-$day-aaaaaaaa"
            $entries += New-RetentionEntry -VMId 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -CreatedAt ([datetime]"2026-08-$day") -BackupSetId "2026-08-$day-bbbbbbbb"
        }

        $plan = Get-ValidBackupRetentionPlan -Entries $entries

        $plan.KeepEntries.Count | Should Be 6
        $plan.DeleteEntries.Count | Should Be 2
        @($plan.DeleteEntries | Group-Object VMId).Count | Should Be 2
    }
}

Describe 'Remocao conjunta de arquivo e metadata' {
    It 'remove somente a VM escolhida quando o tier ainda contem outro arquivo' {
        $setRoot = Join-Path $TestDrive 'repo\2026-08-24-00000001'
        $tierRoot = Join-Path $setRoot 'SMALL'
        $archives = Join-Path $tierRoot 'Archives'
        $metadata = Join-Path $tierRoot 'Metadata\vm-a'
        New-Item -ItemType Directory -Path $metadata -Force | Out-Null
        New-Item -ItemType Directory -Path $archives -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $archives 'vm-a.7z') -Value 'aaaa'
        Set-Content -LiteralPath (Join-Path $archives 'vm-b.7z') -Value 'bbbb'

        $entry = [pscustomobject]@{
            VMId = 'a'; ArchivePath = Join-Path $archives 'vm-a.7z'; MetadataPath = $metadata
            ArchivesRoot = $archives; TierRoot = $tierRoot; BackupSetRoot = $setRoot
        }
        $removed = Remove-ValidBackupEntry -Entry $entry

        Test-Path -LiteralPath $entry.ArchivePath | Should Be $false
        Test-Path -LiteralPath $metadata | Should Be $false
        Test-Path -LiteralPath (Join-Path $archives 'vm-b.7z') | Should Be $true
        Test-Path -LiteralPath $tierRoot | Should Be $true
        $removed.BytesRecovered | Should BeGreaterThan 0
    }

    It 'remove tier e BackupSetId quando o ultimo arquivo desaparece' {
        $setRoot = Join-Path $TestDrive 'repo-last\2026-08-24-00000001'
        $tierRoot = Join-Path $setRoot 'SMALL'
        $archives = Join-Path $tierRoot 'Archives'
        $metadata = Join-Path $tierRoot 'Metadata\vm-a'
        New-Item -ItemType Directory -Path $metadata -Force | Out-Null
        New-Item -ItemType Directory -Path $archives -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $archives 'vm-a.7z') -Value 'aaaa'

        $entry = [pscustomobject]@{
            VMId = 'a'; ArchivePath = Join-Path $archives 'vm-a.7z'; MetadataPath = $metadata
            ArchivesRoot = $archives; TierRoot = $tierRoot; BackupSetRoot = $setRoot
        }
        Remove-ValidBackupEntry -Entry $entry | Out-Null

        Test-Path -LiteralPath $tierRoot | Should Be $false
        Test-Path -LiteralPath $setRoot | Should Be $false
    }

    It 'recusa excluir um arquivo que escape da raiz Archives' {
        $setRoot = Join-Path $TestDrive 'repo-safe\2026-08-24-00000001'
        $tierRoot = Join-Path $setRoot 'SMALL'
        $archives = Join-Path $tierRoot 'Archives'
        $metadata = Join-Path $tierRoot 'Metadata\vm-a'
        $outside = Join-Path $setRoot 'outside.7z'
        New-Item -ItemType Directory -Path $metadata -Force | Out-Null
        New-Item -ItemType Directory -Path $archives -Force | Out-Null
        Set-Content -LiteralPath $outside -Value 'nao apagar'

        $entry = [pscustomobject]@{
            VMId = 'a'; ArchivePath = $outside; MetadataPath = $metadata
            ArchivesRoot = $archives; TierRoot = $tierRoot; BackupSetRoot = $setRoot
        }

        { Remove-ValidBackupEntry -Entry $entry } | Should Throw
        Test-Path -LiteralPath $outside -PathType Leaf | Should Be $true
    }
}

Describe 'Retencao de payloads falhos' {
    It 'preserva todos os failure.json e somente os tres payloads mais novos' {
        $repo = Join-Path $TestDrive 'failed-repo'
        $vmRoot = Join-Path $repo '_FAILED\SRV-ERP--aaaaaaaa'
        foreach ($day in 24..27) {
            $occurrence = Join-Path $vmRoot "2026-08-$day--0000000$day"
            $payload = Join-Path $occurrence 'Payload'
            New-Item -ItemType Directory -Path $payload -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $payload 'payload.partial.7z') -Value ('x' * $day)
            [ordered]@{
                SchemaVersion = 2
                VMId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
                OccurredAt = ([datetime]"2026-08-${day}T21:00:00").ToString('o')
                Error = 'falha de teste'
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $occurrence 'failure.json') -Encoding UTF8
        }

        $entries = @(Get-Schema2FailedPayloadEntries -RepositoryRoot $repo)
        $plan = Get-FailedPayloadRetentionPlan -Entries $entries -KeepPerVM 3
        $plan.DeleteEntries.Count | Should Be 1
        Remove-FailedPayload -Entry $plan.DeleteEntries[0] -Reason 'RETENTION' | Out-Null

        @(Get-ChildItem -LiteralPath $vmRoot -Filter 'failure.json' -File -Recurse).Count | Should Be 4
        @(Get-ChildItem -LiteralPath $vmRoot -Directory -Filter 'Payload' -Recurse).Count | Should Be 3
        $updated = Get-Content -LiteralPath $plan.DeleteEntries[0].FailurePath -Raw | ConvertFrom-Json
        $updated.PayloadStatus | Should Be 'DELETED'
        $updated.PayloadDeletionReason | Should Be 'RETENTION'
        $updated.PayloadBytesRecovered | Should BeGreaterThan 0
        Test-Path -LiteralPath (Join-Path $repo '_AUDIT') | Should Be $false
    }
}
