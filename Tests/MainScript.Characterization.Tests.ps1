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

Describe 'Fluxo produtivo v1.2 antes da repaginacao' {
    It 'usa CascadeId e uma subpasta de execucao dentro da pasta da noite' {
        $mainSource | Should Match '\[string\]\$CascadeId'
        $mainSource | Should Match '\$FinalPoint\s*=\s*Join-Path \(Join-Path \$RepositoryRoot \$CascadeGroupName\) \$RestorePointName'
    }

    It 'move o staging inteiro para FAILED quando alguma VM falha' {
        $mainSource | Should Match '\$OverallStatus\s*=\s*''PARTIAL_FAILED'''
        $mainSource | Should Match 'Move-Item -LiteralPath \$StagingPoint -Destination \$failedDestination'
    }

    It 'publica somente um lote completo com codigo zero' {
        $mainSource | Should Match "Write-RestorePointMarker.+-Status 'COMPLETE'"
        $mainSource | Should Match '\$OverallStatus\s*=\s*''SUCCESS'''
        $mainSource | Should Match '\$ExitCode\s*=\s*0'
    }
}
