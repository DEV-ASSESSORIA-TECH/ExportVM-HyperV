$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'TestHelpers.ps1')

$repositoryRoot = Get-RepositoryRoot
$mainScriptPath = Join-Path $repositoryRoot 'Invoke-VMExportBackup.ps1'
$mainSource = Get-Content -LiteralPath $mainScriptPath -Raw

. (Get-ScriptFunction -Path $mainScriptPath -Name 'Get-SelectedVMs')
. (Get-ScriptFunction -Path $mainScriptPath -Name 'Select-IncludedVMs')

Describe 'Exclusao de VMs' {
    It 'ignora nome exato sem diferenciar maiusculas e preserva nomes parecidos' {
        function Write-Log { param($Message) }
        $ExcludeVMName = @('vm-teste')
        $candidates = @([pscustomobject]@{ Name = 'VM-TESTE' }, [pscustomobject]@{ Name = 'VM-TESTE-2' })
        $selected = @(Select-IncludedVMs -Candidates $candidates)
        $selected.Count | Should Be 1
        $selected[0].Name | Should Be 'VM-TESTE-2'
        $script:ExcludedVMs -join ',' | Should Be 'VM-TESTE'
    }

    It 'aplica exclusao mesmo em selecao explicita por VMName' {
        function Write-Log { param($Message) }
        function Get-VM { param($ErrorAction) [pscustomobject]@{ Name = 'VM-TESTE' } }
        function Get-VMSourceSize { param($Name) 1GB }
        $VMName = @('VM-TESTE')
        $ExcludeVMName = @('VM-TESTE')
        $TierDefinitions = $null
        $EffectiveBatchName = 'ADHOC'
        @(Get-SelectedVMs).Count | Should Be 0
        $script:ExcludedVMs -join ',' | Should Be 'VM-TESTE'
    }

    It 'nao interpreta curingas e permite lista vazia' {
        function Write-Log { param($Message) }
        $ExcludeVMName = @('VM-*')
        $candidates = @([pscustomobject]@{ Name = 'VM-TESTE' })
        @(Select-IncludedVMs -Candidates $candidates).Count | Should Be 1
        $ExcludeVMName = @()
        @(Select-IncludedVMs -Candidates $candidates).Count | Should Be 1
    }
}

Describe 'Funcoes do script principal' {
    It 'falha quando o host nao contem nenhuma VM' {
        function Get-VM { param($ErrorAction) return @() }

        { Get-SelectedVMs } | Should Throw 'Nenhuma VM encontrada no host.'
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
