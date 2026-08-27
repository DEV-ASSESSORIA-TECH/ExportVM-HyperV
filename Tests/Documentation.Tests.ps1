$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'TestHelpers.ps1')
$repositoryRoot = Get-RepositoryRoot

Describe 'Documentacao de producao v1.3' {
    $readme = Get-Content -LiteralPath (Join-Path $repositoryRoot 'README.md') -Raw
    $runbook = Get-Content -LiteralPath (Join-Path $repositoryRoot 'RUNBOOK.md') -Raw
    $quick = Get-Content -LiteralPath (Join-Path $repositoryRoot 'LEIA-ME.txt') -Raw

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
        $quick | Should Match 'MinFreeGB \+ 2 x SourceBytes'
        (Get-Content -LiteralPath (Join-Path $repositoryRoot 'Invoke-VMExportBackup.ps1') -Raw) |
            Should Match '\[switch\]\$SkipHash\s*=\s*\$true'
    }

    It 'explicita a incompatibilidade operacional com layouts antigos' {
        $readme | Should Match 'não são migradas, contadas ou apagadas'
        $runbook | Should Match 'Não existe migração automática'
        $quick | Should Match 'Não existe _AUDIT'
    }
}
