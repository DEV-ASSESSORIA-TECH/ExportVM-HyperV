$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'TestHelpers.ps1')
$repositoryRoot = Get-ProjectRoot

Describe 'Documentacao de producao v2.0' {
    $readme = Get-Content -LiteralPath (Join-Path $repositoryRoot 'README.md') -Raw
    $runbook = Get-Content -LiteralPath (Join-Path $repositoryRoot 'docs\RUNBOOK.md') -Raw
    $quick = Get-Content -LiteralPath (Join-Path $repositoryRoot 'docs\LEIA-ME.txt') -Raw

    It 'documenta layout identidade e restauracao parcial' {
        $readme | Should Match 'BackupSetId'
        $readme | Should Match '<nome-seguro>--<VMId-curto>'
        $readme | Should Match 'PARTIAL\.marker\.json'
        $runbook | Should Match 'Restauração de uma VM publicada'
    }

    It 'documenta retencao falha SHA opcional e codigos' {
        $readme | Should Match 'FailedPayloadKeepPerVM'
        $readme | Should Match '"SkipHash": true'
        $readme | Should Match 'SUCCESS_WITH_WARNINGS.+2'
        $quick | Should Match '(?s)Espaço mínimo exigido antes de cada VM:.+MinFreeGB'
        $quick | Should Not Match 'MinFreeGB \+ 2 x SourceBytes'
        (Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\Invoke-VMExportBackup.ps1') -Raw) |
            Should Match '\[switch\]\$SkipHash\s*=\s*\$true'
    }

    It 'explicita a incompatibilidade operacional com layouts antigos' {
        $readme | Should Match 'não são migradas, contadas ou apagadas'
        $runbook | Should Match 'Não existe migração automática'
        $quick | Should Match 'Não existe _AUDIT'
    }

    It 'documenta instalacao em pasta personalizada do Agendador' {
        $readme | Should Match "-TaskPath '\\ASSESSORIA SCF\\'"
        $runbook | Should Match 'pasta lógica do Agendador é independente'
        $quick | Should Match 'remove outras cópias de mesmo TaskName'
    }
}
