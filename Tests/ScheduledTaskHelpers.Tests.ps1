$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'TestHelpers.ps1')

$repositoryRoot = Get-RepositoryRoot
$helpersPath = Join-Path $repositoryRoot 'Internal\Helpers\ScheduledTaskHelpers.ps1'
$installerPath = Join-Path $repositoryRoot 'Install-VMExportBackupTask.ps1'

. $helpersPath

Describe 'Pasta da tarefa agendada' {
    It 'mantem a raiz como caminho padrao' {
        ConvertTo-ScheduledTaskPath -Path '\' | Should Be '\'
        ConvertTo-ScheduledTaskPath -Path '' | Should Be '\'
    }

    It 'normaliza uma pasta personalizada' {
        ConvertTo-ScheduledTaskPath -Path 'ASSESSORIA SCF' | Should Be '\ASSESSORIA SCF\'
        ConvertTo-ScheduledTaskPath -Path '\ASSESSORIA SCF\' | Should Be '\ASSESSORIA SCF\'
        ConvertTo-ScheduledTaskPath -Path 'TI/Backups' | Should Be '\TI\Backups\'
    }

    It 'rejeita navegacao relativa' {
        { ConvertTo-ScheduledTaskPath -Path 'TI\..\Backups' } | Should Throw 'TaskPath invalido'
    }

    It 'registra e remove copias da tarefa usando TaskPath explicitamente' {
        $source = Get-Content -LiteralPath $installerPath -Raw
        $source | Should Match 'Register-ScheduledTask\s+-TaskPath \$TaskPath'
        $source | Should Match 'Unregister-ScheduledTask -TaskPath \$duplicate\.TaskPath'
        $source | Should Not Match 'LegacyTaskNamePrefix|\$legacyTasks'
    }
}
