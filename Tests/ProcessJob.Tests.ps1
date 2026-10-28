$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'TestHelpers.ps1')
$helper = Join-Path (Get-RepositoryRoot) 'Internal\Helpers\RepositoryHelpers.ps1'
. $helper

Describe 'Workers vinculados ao dono do repositorio' {
    It 'encerra o grupo no timeout do monitor e libera os handles' {
        $main = Join-Path (Get-RepositoryRoot) 'Invoke-VMExportBackup.ps1'
        foreach ($name in @('Invoke-MonitoredProcess', 'Format-Duration', 'Format-Bytes', 'Get-TailText')) {
            . (Get-ScriptFunction -Path $main -Name $name)
        }
        function Write-Log { param($Message, $Level) }
        $HeartbeatSeconds = 30
        $script:RepositoryLock = Enter-BackupRepositoryLock -RepositoryRoot (Join-Path $TestDrive 'timeout') -RunId test
        try {
            $result = Invoke-MonitoredProcess -DisplayName timeout -FilePath powershell.exe `
                -ArgumentString '-NoProfile -Command "Start-Sleep -Seconds 120"' -Timeout ([timespan]::FromMilliseconds(50)) `
                -StdOutPath (Join-Path $TestDrive 'timeout-out') -StdErrPath (Join-Path $TestDrive 'timeout-err')
            $result.TimedOut | Should Be $true
            $script:RepositoryLock.Job.ActiveProcesses | Should Be 0
        } finally { Exit-BackupRepositoryLock $script:RepositoryLock; $script:RepositoryLock = $null }
    }

    It 'drena grupo remanescente antes de entregar o novo lock' {
        $repo = Join-Path $TestDrive 'stale-group'
        $old = Enter-BackupRepositoryLock -RepositoryRoot $repo -RunId old
        $next = $null; $process = $null
        try {
            $process = Start-BackupJobProcess -Job $old.Job -FilePath powershell.exe -ArgumentString '-NoProfile -Command "Start-Sleep -Seconds 120"' `
                -StdOutPath (Join-Path $TestDrive 'stale-out') -StdErrPath (Join-Path $TestDrive 'stale-err')
            # Simula o lock liberado antes do ultimo handle do grupo antigo fechar.
            $old.Stream.Dispose()
            $next = Enter-BackupRepositoryLock -RepositoryRoot $repo -RunId next
            $next.Job.Name | Should Be $old.Job.Name
            $next.Job.ActiveProcesses | Should Be 0
            $process.WaitForExit(5000) | Should Be $true
        } finally {
            Exit-BackupRepositoryLock $next
            Exit-BackupRepositoryLock $old
            if ($process) { $process.Dispose() }
        }
    }

    It 'preserva exit code e saidas e permite reutilizar o grupo' {
        $lock = Enter-BackupRepositoryLock -RepositoryRoot (Join-Path $TestDrive 'io') -RunId test
        try {
            foreach ($code in @(7, 0)) {
                $out = Join-Path $TestDrive "out$code.txt"; $err = Join-Path $TestDrive "err$code.txt"
                $args = '-NoProfile -Command "[Console]::WriteLine(''saida''); [Console]::Error.WriteLine(''erro''); exit {0}"' -f $code
                $process = Start-BackupJobProcess -Job $lock.Job -FilePath powershell.exe -ArgumentString $args -StdOutPath $out -StdErrPath $err
                try {
                    $process.WaitForExit(10000) | Should Be $true
                    $process.ExitCode | Should Be $code
                    (Get-Content $out -Raw).Trim() | Should Be 'saida'
                    (Get-Content $err -Raw).Trim() | Should Be 'erro'
                } finally { $lock.Job.Stop(10000); $process.Dispose() }
            }
        } finally { Exit-BackupRepositoryLock $lock }
    }

    It 'encerra worker ativo antes de liberar o repositorio' {
        $repo = Join-Path $TestDrive 'stop'
        $lock = Enter-BackupRepositoryLock -RepositoryRoot $repo -RunId test
        $process = $null
        try {
            $process = Start-BackupJobProcess -Job $lock.Job -FilePath powershell.exe -ArgumentString '-NoProfile -Command "Start-Sleep -Seconds 120"' `
                -StdOutPath (Join-Path $TestDrive 'stop-out') -StdErrPath (Join-Path $TestDrive 'stop-err')
            Exit-BackupRepositoryLock $lock; $lock = $null
            $process.WaitForExit(5000) | Should Be $true
            $lock = Enter-BackupRepositoryLock -RepositoryRoot $repo -RunId next
            $lock.Job.ActiveProcesses | Should Be 0
        } finally { Exit-BackupRepositoryLock $lock; if ($process) { $process.Dispose() } }
    }

    It 'encerra worker e neto quando o dono morre e permite novo dono' {
        $repo = Join-Path $TestDrive 'death'
        $ready = Join-Path $TestDrive 'descendants.json'
        $worker = Join-Path $TestDrive 'worker.ps1'
        @'
param($Ready)
$child = Start-Process powershell.exe -ArgumentList '-NoProfile -Command "Start-Sleep -Seconds 120"' -WindowStyle Hidden -PassThru
@{ Worker = $PID; Child = $child.Id } | ConvertTo-Json | Set-Content -LiteralPath "$Ready.tmp"
Move-Item -LiteralPath "$Ready.tmp" -Destination $Ready
Start-Sleep -Seconds 120
'@ | Set-Content -LiteralPath $worker
        $owner = Join-Path $TestDrive 'job-owner.ps1'
        @'
param($Helper, $Repository, $Worker, $Ready)
$ErrorActionPreference = 'Stop'
. $Helper
$lock = Enter-BackupRepositoryLock -RepositoryRoot $Repository -RunId owner
$arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Ready "{1}"' -f $Worker, $Ready
$p = Start-BackupJobProcess -Job $lock.Job -FilePath powershell.exe -ArgumentString $arguments -StdOutPath "$Ready.out" -StdErrPath "$Ready.err"
Start-Sleep -Seconds 120
'@ | Set-Content -LiteralPath $owner
        $args = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Helper "{1}" -Repository "{2}" -Worker "{3}" -Ready "{4}"' -f $owner, $helper, $repo, $worker, $ready
        $process = Start-Process powershell.exe -ArgumentList $args -WindowStyle Hidden -PassThru
        $descendants = @()
        try {
            $deadline = (Get-Date).AddSeconds(20)
            while (-not (Test-Path $ready) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
            Test-Path $ready | Should Be $true
            $ids = Get-Content $ready -Raw | ConvertFrom-Json
            $descendants = @((Get-Process -Id $ids.Worker), (Get-Process -Id $ids.Child))
            Stop-Process -Id $process.Id -Force
            [void]$process.WaitForExit(5000)
            $lock = Enter-BackupRepositoryLock -RepositoryRoot $repo -RunId next
            try {
                $lock.Job.ActiveProcesses | Should Be 0
                foreach ($child in $descendants) { $child.WaitForExit(5000) | Should Be $true }
            } finally { Exit-BackupRepositoryLock $lock }
        } finally {
            if (-not $process.HasExited) { $process.Kill() }
            foreach ($child in $descendants) { if (-not $child.HasExited) { $child.Kill() }; $child.Dispose() }
            $process.Dispose()
        }
    }
}
