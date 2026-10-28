$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'TestHelpers.ps1')
$repositoryRoot = Get-RepositoryRoot
foreach ($helper in @('RepositoryHelpers', 'RetentionHelpers', 'PublishingHelpers', 'VMTransactionHelpers')) {
    . (Join-Path $repositoryRoot "Internal\Helpers\$helper.ps1")
}

function New-TestPublication {
    param([string]$Root, [string]$Name = 'SRV', [string]$VMId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
    $context = New-VMTransactionContext -StagingRoot (Join-Path $Root '_STAGING\run') -VMName $Name `
        -VMId $VMId -TierName SMALL -OccurrenceId test
    Initialize-VMTransactionDirectories -Context $context
    Set-Content -LiteralPath $context.ArchivePath -Value 'arquivo aprovado'
    Set-Content -LiteralPath (Join-Path $context.MetadataRoot 'vm.json') -Value '{}'
    $result = [pscustomobject]@{
        Name = $Name; Success = $true; Status = 'SUCCESS'; VMId = $context.VMId
        ArchivePath = $context.ArchivePath; MetadataPath = $context.MetadataRoot; Archive = $null; Metadata = $null
        RunId = 'test'; StartedAt = (Get-Date).ToString('o'); FinishedAt = (Get-Date).ToString('o')
    }
    return [pscustomobject]@{
        Context = $context; Result = $result
        Paths = Get-BackupSetPathModel -RepositoryRoot $Root -BackupSetId 2026-10-28-01234567 -TierName SMALL
    }
}

Describe 'Recuperacao idempotente da publicacao' {
    It 'preserva VMs ja publicadas ao recuperar a seguinte e mantem a retencao' {
        $repo = Join-Path $TestDrive 'multiple'
        $first = New-TestPublication -Root $repo
        Publish-VMTransactionResult -Context $first.Context -Result $first.Result -PathModel $first.Paths -KeepRestorePoints 5 | Out-Null
        $second = New-TestPublication -Root $repo -Name OUTRA -VMId bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
        { Publish-VMTransactionResult -Context $second.Context -Result $second.Result -PathModel $second.Paths -KeepRestorePoints 5 `
            -AfterStep { param($Step) if ($Step -eq 'ARCHIVE_MOVED') { throw 'interrompido' } } } | Should Throw
        @(Repair-PendingVMBackupPublications -RepositoryRoot $repo).Count | Should Be 1
        @(Get-Schema2ValidBackupEntries -RepositoryRoot $repo).Count | Should Be 2
        $tiers = @(Get-Schema2BackupTiers -RepositoryRoot $repo)
        $tiers[0].Manifest.KeepRestorePoints | Should Be 5
        $tiers[0].Manifest.VMResults.Count | Should Be 2
    }

    It 'verifica o hash registrado mesmo se o arquivo alterado mantiver o tamanho' {
        $repo = Join-Path $TestDrive 'hash'
        $fixture = New-TestPublication -Root $repo
        $fixture.Result | Add-Member -NotePropertyName SHA256 -NotePropertyValue (Get-FileHash -LiteralPath $fixture.Context.ArchivePath).Hash
        { Publish-VMTransactionResult -Context $fixture.Context -Result $fixture.Result -PathModel $fixture.Paths `
            -AfterStep { param($Step) if ($Step -eq 'PREPARED') { throw 'interrompido' } } } | Should Throw
        $bytes = [IO.File]::ReadAllBytes($fixture.Context.ArchivePath)
        $bytes[0] = $bytes[0] -bxor 1
        [IO.File]::WriteAllBytes($fixture.Context.ArchivePath, $bytes)
        { Repair-PendingVMBackupPublications -RepositoryRoot $repo } | Should Throw 'Hash'
        @(Get-Schema2ValidBackupEntries -RepositoryRoot $repo).Count | Should Be 0
    }
    foreach ($phase in @('PREPARED', 'METADATA_MOVED', 'ARCHIVE_MOVED', 'MANIFEST_COMMITTED')) {
        It "recupera interrupcao em $phase sem perder o arquivo aprovado" {
            $repo = Join-Path $TestDrive $phase
            $fixture = New-TestPublication -Root $repo
            { Publish-VMTransactionResult -Context $fixture.Context -Result $fixture.Result -PathModel $fixture.Paths `
                -AfterStep { param($Step) if ($Step -eq $phase) { throw 'interrupcao simulada' } } } | Should Throw 'interrupcao simulada'
            @(Repair-PendingVMBackupPublications -RepositoryRoot $repo).Count | Should Be 1
            $valid = @(Get-Schema2ValidBackupEntries -RepositoryRoot $repo)
            $valid.Count | Should Be 1
            Test-Path -LiteralPath $valid[0].MetadataPath | Should Be $true
            @(Repair-PendingVMBackupPublications -RepositoryRoot $repo).Count | Should Be 0
            @(Get-ChildItem -LiteralPath (Join-Path $repo '_PUBLISHING') -File -Recurse -Filter '*.json').Count | Should Be 0
        }
    }

    It 'nao promove payload divergente e preserva o registro para inspecao' {
        $repo = Join-Path $TestDrive 'changed'
        $fixture = New-TestPublication -Root $repo
        { Publish-VMTransactionResult -Context $fixture.Context -Result $fixture.Result -PathModel $fixture.Paths `
            -AfterStep { param($Step) if ($Step -eq 'PREPARED') { throw 'interrompido' } } } | Should Throw
        Add-Content -LiteralPath $fixture.Context.ArchivePath -Value 'alterado'
        { Repair-PendingVMBackupPublications -RepositoryRoot $repo } | Should Throw 'Tamanho'
        @(Get-Schema2ValidBackupEntries -RepositoryRoot $repo).Count | Should Be 0
        @(Get-ChildItem -LiteralPath (Join-Path $repo '_PUBLISHING') -Recurse -File -Filter '*.json').Count | Should Be 1
    }

    It 'recusa registro que redirecione a origem para fora do staging' {
        $repo = Join-Path $TestDrive 'unsafe'
        $fixture = New-TestPublication -Root $repo
        { Publish-VMTransactionResult -Context $fixture.Context -Result $fixture.Result -PathModel $fixture.Paths `
            -AfterStep { param($Step) if ($Step -eq 'PREPARED') { throw 'interrompido' } } } | Should Throw
        $journal = Get-ChildItem -LiteralPath (Join-Path $repo '_PUBLISHING') -Recurse -File -Filter '*.json' | Select-Object -First 1
        $state = Get-Content -LiteralPath $journal.FullName -Raw | ConvertFrom-Json
        $state.SourceVMRoot = Join-Path $TestDrive 'outside'
        Write-DurablePublicationJson -Value $state -Path $journal.FullName
        { Repair-PendingVMBackupPublications -RepositoryRoot $repo } | Should Throw 'raiz permitida'
        Test-Path -LiteralPath $fixture.Context.ArchivePath | Should Be $true
    }

    It 'descobre o checkpoint mesmo durante a troca dos marcadores finais' {
        $repo = Join-Path $TestDrive 'markers'
        $fixture = New-TestPublication -Root $repo
        Publish-VMTransactionResult -Context $fixture.Context -Result $fixture.Result -PathModel $fixture.Paths | Out-Null
        Copy-Item -LiteralPath $fixture.Paths.PartialMarkerPath -Destination $fixture.Paths.CompleteMarkerPath
        @(Get-Schema2ValidBackupEntries -RepositoryRoot $repo).Count | Should Be 1
        Remove-Item -LiteralPath $fixture.Paths.PartialMarkerPath, $fixture.Paths.CompleteMarkerPath
        @(Get-Schema2ValidBackupEntries -RepositoryRoot $repo).Count | Should Be 1
    }

    It 'recupera apos matar um processo real entre o arquivo e o manifesto' {
        $repo = Join-Path $TestDrive 'killed'
        $fixture = New-TestPublication -Root $repo
        $inputPath = Join-Path $TestDrive 'input.json'
        $fixture | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $inputPath -Encoding UTF8
        $ready = Join-Path $TestDrive 'publish-ready.txt'
        $owner = Join-Path $TestDrive 'publisher.ps1'
        @'
param($Source, $InputPath, $Ready)
foreach ($helper in @('RepositoryHelpers','RetentionHelpers','PublishingHelpers')) { . (Join-Path $Source "Internal\Helpers\$helper.ps1") }
$data = Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json
$lock = Enter-BackupRepositoryLock -RepositoryRoot $data.Paths.RepositoryRoot -RunId publisher
Publish-VMTransactionResult -Context $data.Context -Result $data.Result -PathModel $data.Paths -AfterStep {
    param($Step)
    if ($Step -eq 'ARCHIVE_MOVED') { Set-Content -LiteralPath $Ready -Value ready; while ($true) { Start-Sleep -Seconds 1 } }
}
'@ | Set-Content -LiteralPath $owner -Encoding UTF8
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Source "{1}" -InputPath "{2}" -Ready "{3}"' -f $owner, $repositoryRoot, $inputPath, $ready
        $process = Start-Process -FilePath powershell.exe -ArgumentList $arguments -WindowStyle Hidden -PassThru
        try {
            $deadline = (Get-Date).AddSeconds(10)
            while (-not (Test-Path -LiteralPath $ready) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
            Test-Path -LiteralPath $ready | Should Be $true
            Stop-Process -Id $process.Id -Force
            [void]$process.WaitForExit(5000)
            $lock = Enter-BackupRepositoryLock -RepositoryRoot $repo -RunId recovery
            try { @(Repair-PendingVMBackupPublications -RepositoryRoot $repo).Count | Should Be 1 }
            finally { Exit-BackupRepositoryLock -Lock $lock }
            @(Get-Schema2ValidBackupEntries -RepositoryRoot $repo).Count | Should Be 1
        }
        finally { if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }; $process.Dispose() }
    }
}
