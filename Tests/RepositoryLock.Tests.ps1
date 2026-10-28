$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'TestHelpers.ps1')
$repositoryRoot = Get-RepositoryRoot
$helper = Join-Path $repositoryRoot 'Internal\Helpers\RepositoryHelpers.ps1'
. $helper

Describe 'Bloqueio exclusivo do repositorio' {
    It 'recusa um segundo dono e permite reabrir o arquivo persistente apos liberar' {
        $repo = Join-Path $TestDrive 'exclusive'
        $first = Enter-BackupRepositoryLock -RepositoryRoot $repo -RunId first
        try { { Enter-BackupRepositoryLock -RepositoryRoot $repo -RunId second } | Should Throw 'bloqueio exclusivo' }
        finally { Exit-BackupRepositoryLock -Lock $first }
        Test-Path -LiteralPath $first.Path | Should Be $true
        $second = Enter-BackupRepositoryLock -RepositoryRoot $repo -RunId second
        Exit-BackupRepositoryLock -Lock $second
    }

    It 'bloqueia outro processo e e liberado pelo SO apos encerramento abrupto' {
        $repo = Join-Path $TestDrive 'process-lock'
        $ready = Join-Path $TestDrive 'ready.txt'
        $owner = Join-Path $TestDrive 'owner.ps1'
        @'
param($Helper, $Repository, $Ready)
. $Helper
$lock = Enter-BackupRepositoryLock -RepositoryRoot $Repository -RunId owner
Set-Content -LiteralPath $Ready -Value ready
while ($true) { Start-Sleep -Seconds 1 }
'@ | Set-Content -LiteralPath $owner -Encoding UTF8
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Helper "{1}" -Repository "{2}" -Ready "{3}"' -f $owner, $helper, $repo, $ready
        $process = Start-Process -FilePath powershell.exe -ArgumentList $arguments -WindowStyle Hidden -PassThru
        try {
            $deadline = (Get-Date).AddSeconds(10)
            while (-not (Test-Path -LiteralPath $ready) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
            Test-Path -LiteralPath $ready | Should Be $true
            { Enter-BackupRepositoryLock -RepositoryRoot $repo -RunId contender } | Should Throw 'bloqueio exclusivo'
            Stop-Process -Id $process.Id -Force
            [void]$process.WaitForExit(5000)
            $lock = Enter-BackupRepositoryLock -RepositoryRoot $repo -RunId recovered
            Exit-BackupRepositoryLock -Lock $lock
        }
        finally {
            if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
            $process.Dispose()
        }
    }
}
