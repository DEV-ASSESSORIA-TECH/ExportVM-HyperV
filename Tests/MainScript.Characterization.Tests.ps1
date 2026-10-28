$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'TestHelpers.ps1')

$repositoryRoot = Get-RepositoryRoot
$mainScriptPath = Join-Path $repositoryRoot 'Invoke-VMExportBackup.ps1'
$mainSource = Get-Content -LiteralPath $mainScriptPath -Raw

. (Get-ScriptFunction -Path $mainScriptPath -Name 'Get-SelectedVMs')
. (Join-Path $repositoryRoot 'Internal\Helpers\TierHelpers.ps1')

Describe 'Funcoes do script principal' {
    It 'falha quando o host nao contem nenhuma VM' {
        function Get-VM { param($ErrorAction) return @() }
        $SelectionPlanPath = ''; $ExcludeVMName = @(); $ExcludeVMId = @()
        $TierDefinitions = $null; $VMName = @(); $BackupSetId = 'test'

        { Get-SelectedVMs } | Should Throw 'Nenhuma VM encontrada no host.'
    }

    It 'preserva SKIPPED e justificativa ate o relatorio final sem exportacao' {
        $appRoot = Join-Path $TestDrive 'skip-app'
        Copy-Item -LiteralPath $repositoryRoot -Destination $appRoot -Recurse
        $entryPath = Join-Path $appRoot 'Invoke-VMExportBackup.ps1'
        $source = Get-Content -LiteralPath $entryPath -Raw
        $source = $source -replace '(?m)^#requires -RunAsAdministrator\s*$', ''
        $source = $source.Replace('$RunStart = Get-Date', '$RunStart = [datetime]''2026-10-28T21:00:00''')
        Set-Content -LiteralPath $entryPath -Value $source -Encoding UTF8
        $harness = Join-Path $TestDrive 'skip-harness.ps1'
        @'
function Import-Module { param($Name, $ErrorAction) }
function Get-VM {
    param($ErrorAction)
    [pscustomobject]@{ Name = 'VM-EXCLUIDA'; VMId = '11111111-1111-1111-1111-111111111111'; State = 'Running' }
}
function Get-Volume {
    param($DriveLetter, $ErrorAction)
    [pscustomobject]@{ SizeRemaining = 300GB; FileSystemLabel = 'BACKUP-HYPERV'; HealthStatus = 'Healthy'; FileSystem = 'NTFS' }
}
& (Join-Path $PSScriptRoot 'skip-app\Invoke-VMExportBackup.ps1') -BatchName ALL -Execute -SkipEmail `
    -BackupDrive ([System.IO.Path]::GetPathRoot($PSScriptRoot).TrimEnd('\')) -RepositoryFolder ((Join-Path $PSScriptRoot 'NoBackupExpected').Substring(3)) `
    -ExcludeVMId '11111111-1111-1111-1111-111111111111' -SevenZipPath (Join-Path $PSHOME 'powershell.exe') `
    -ResultPath (Join-Path $PSScriptRoot 'skipped-result.json')
'@ | Set-Content -LiteralPath $harness -Encoding UTF8
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $harness | Out-Null
        $LASTEXITCODE | Should Be 0
        $result = Get-Content -LiteralPath (Join-Path $TestDrive 'skipped-result.json') -Raw | ConvertFrom-Json
        if ($result.Error) { throw $result.Error }
        $result.Status | Should Be 'SKIPPED'
        $result.ExitCode | Should Be 0
        $result.VMCount | Should Be 0
        $result.SkipReason | Should Match 'Todas as VMs selecionadas foram excluidas'
        $result.RepositoryPublished | Should Be $false
        $result.RestorePointPath | Should Be $null
        Split-Path -Leaf $result.LogPath | Should Be ("ALL-2026-10-28_21-00-00-$($result.RunId.Substring(0, 8)).log")
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $harness | Out-Null
        $second = Get-Content -LiteralPath (Join-Path $TestDrive 'skipped-result.json') -Raw | ConvertFrom-Json
        $second.Status | Should Be 'SKIPPED'
        $second.LogPath | Should Not Be $result.LogPath
    }
}

Describe 'Fluxo produtivo v2.0' {
    It 'usa BackupSetId e o layout schema 2 por tier' {
        $mainSource | Should Match '\[string\]\$BackupSetId'
        $mainSource | Should Match 'Get-BackupSetPathModel'
        $mainSource | Should Match 'Write-BackupTierManifestV2'
    }

    It 'publica e preserva falhas de forma independente por VM' {
        $mainSource | Should Match 'Publish-VMTransactionResult'
        $mainSource | Should Match 'Save-FailedVMTransaction'
        $mainSource | Should Match 'PARTIAL_SUCCESS'
    }

    It 'ativa o orquestrador v2.0 no caminho de execucao' {
        $mainSource | Should Match 'Invoke-BackupExecutionV2'
        $mainSource | Should Match 'Get-BackupOutcome'
        $mainSource | Should Not Match 'if\s*\(\$false\)'
    }
}
