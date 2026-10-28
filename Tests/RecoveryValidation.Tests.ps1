$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'TestHelpers.ps1')
$main = Join-Path (Get-RepositoryRoot) 'Invoke-VMExportBackup.ps1'
foreach ($name in @('Test-RecoveryArchive', 'Quote-Argument', 'Invoke-MonitoredProcess')) {
    . (Get-ScriptFunction -Path $main -Name $name)
}

Describe 'Validacao obrigatoria da recuperacao' {
    $LogDir = $TestDrive; $SevenZipPath = '7z.exe'; $IntegrityTimeoutHours = 1
    It 'recusa codigo de saida desconhecido mesmo com texto de sucesso' {
        Mock Invoke-MonitoredProcess { [pscustomobject]@{ ExitCode = $null; TimedOut = $false; StdOutTail = 'Everything is Ok'; StdErrTail = '' } }
        { Test-RecoveryArchive -ArchivePath 'C:\backup\arquivo.7z' } | Should Throw 'Integridade'
    }
    It 'recusa timeout mesmo com codigo zero' {
        Mock Invoke-MonitoredProcess { [pscustomobject]@{ ExitCode = 0; TimedOut = $true; StdOutTail = ''; StdErrTail = '' } }
        { Test-RecoveryArchive -ArchivePath 'C:\backup\arquivo.7z' } | Should Throw 'timeout'
    }
    It 'recusa aviso do 7-Zip mesmo com texto de sucesso' {
        Mock Invoke-MonitoredProcess { [pscustomobject]@{ ExitCode = 1; TimedOut = $false; StdOutTail = 'Everything is Ok'; StdErrTail = 'warning' } }
        { Test-RecoveryArchive -ArchivePath 'C:\backup\arquivo.7z' } | Should Throw 'Integridade'
    }
}
