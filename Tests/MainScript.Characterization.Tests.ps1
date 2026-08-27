$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'TestHelpers.ps1')

$repositoryRoot = Get-RepositoryRoot
$mainScriptPath = Join-Path $repositoryRoot 'Invoke-VMExportBackup.ps1'
$mainSource = Get-Content -LiteralPath $mainScriptPath -Raw

. (Get-ScriptFunction -Path $mainScriptPath -Name 'Get-SafeName')
. (Get-ScriptFunction -Path $mainScriptPath -Name 'Get-SelectedVMs')

Describe 'Funcoes do script principal' {
    It 'normaliza somente caracteres invalidos de caminho e espacos externos' {
        Get-SafeName -Name '  VM\A/B:C*D?E"F<G>H|I  ' | Should Be 'VM_A_B_C_D_E_F_G_H_I'
    }

    It 'falha quando o host nao contem nenhuma VM' {
        function Get-VM { param($ErrorAction) return @() }

        { Get-SelectedVMs } | Should Throw 'Nenhuma VM encontrada no host.'
    }
}

Describe 'Fluxo produtivo v1.3' {
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

    It 'ativa o orquestrador v1.3 no caminho de execucao' {
        $mainSource | Should Match 'Invoke-BackupExecutionV13'
        $mainSource | Should Match 'Get-BackupOutcome'
    }
}
