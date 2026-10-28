$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'TestHelpers.ps1')
$repositoryRoot = Get-ProjectRoot

Describe 'Documentacao de producao v2.1.0' {
    $readme = Get-Content -LiteralPath (Join-Path $repositoryRoot 'README.md') -Raw
    $runbook = Get-Content -LiteralPath (Join-Path $repositoryRoot 'docs\RUNBOOK.md') -Raw
    $quick = Get-Content -LiteralPath (Join-Path $repositoryRoot 'docs\LEIA-ME.txt') -Raw

    It 'documenta v2.1.0 bloqueio recuperacao e estados sem instrucoes obsoletas' {
        $readme | Should Match 'v2\.1\.0'
        $runbook | Should Match 'v2\.1\.0'
        $quick | Should Match 'v2\.1\.0'
        $readme | Should Match 'FileShare.None'
        $readme | Should Match '_PUBLISHING'
        $readme | Should Match 'PUBLISHED.marker.json'
        $readme | Should Match '\| `SKIPPED` \|'
        $readme | Should Not Match 'tier vazio'
        $runbook | Should Not Match 'tier estava vazio'
        $runbook | Should Match 'plan\\\.json'
        Test-Path -LiteralPath (Join-Path $repositoryRoot 'docs\RELEASE-v2.1.0.md') | Should Be $true
    }

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

    It 'documenta a auditoria operacional atual' {
        $quick | Should Match 'Não existe _AUDIT'
        $readme | Should Not Match 'Compatibilidade com versões anteriores'
        $runbook | Should Not Match 'Migração da v1\.2 ou anterior'
    }

    It 'documenta instalacao em pasta personalizada do Agendador' {
        $readme | Should Match "-TaskPath '\\ASSESSORIA SCF\\'"
        $runbook | Should Match 'pasta lógica do Agendador é independente'
        $quick | Should Match 'remove outras cópias de mesmo TaskName'
    }
}
