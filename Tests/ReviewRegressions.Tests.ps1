$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'TestHelpers.ps1')
$repositoryRoot = Get-RepositoryRoot

Describe 'Falha individual da VM removida' {
    It 'grava inventario minimo para VM removida sem consultar seus discos' {
        $main = Join-Path $repositoryRoot 'Invoke-VMExportBackup.ps1'
        . (Get-ScriptFunction -Path $main -Name Write-HostInventory)
        function Get-CimInstance { param($ClassName, $ErrorAction) return $null }
        function Get-VMHost { param($ErrorAction) return $null }
        function Get-Module { param($Name, [switch]$ListAvailable, $ErrorAction) return @() }
        function Get-VMSwitch { param($ErrorAction) return @() }
        function Get-VMHardDiskDrive { throw 'Nao deve consultar VM removida.' }
        $ComputerName = 'test'
        $SelectedVMs = @([pscustomobject]@{
            Name = 'REMOVIDA'; VMId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            Tier = 'BIG'; SourceBytes = 100GB; SelectionError = 'VM removida apos planejamento.'
        })
        $path = Join-Path $TestDrive 'missing-inventory.json'
        Write-HostInventory -Path $path
        $inventory = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $inventory.VMs[0].State | Should Be 'Missing'
        $inventory.VMs[0].Error | Should Match 'VM removida'
    }
    It 'produz VM_NOT_FOUND sem executar exportacao nem preparar diretorios' {
        foreach ($helper in @('RepositoryHelpers', 'FailureClassificationHelpers', 'VMTransactionHelpers')) {
            . (Join-Path $repositoryRoot "Internal\Helpers\$helper.ps1")
        }
        $main = Join-Path $repositoryRoot 'Invoke-VMExportBackup.ps1'
        foreach ($name in @('Invoke-ConfiguredVMTransaction', 'Format-Bytes', 'Format-Duration')) {
            . (Get-ScriptFunction -Path $main -Name $name)
        }
        function Write-Log { param($Message, $Level) }
        $RetryCount = 1; $SkipHash = $true
        $context = New-VMTransactionContext -StagingRoot (Join-Path $TestDrive 'missing') -VMName 'REMOVIDA' `
            -VMId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' -TierName BIG -OccurrenceId test
        $vm = [pscustomobject]@{ Name = 'REMOVIDA'; State = 'Missing'; SelectionError = 'VM removida apos planejamento.' }
        $result = Invoke-ConfiguredVMTransaction -VM $vm -Context $context
        $result.Success | Should Be $false
        $result.FailureKind | Should Be 'VM_NOT_FOUND'
        $result.Attempts | Should Be 1
        Test-Path -LiteralPath $context.VMRoot | Should Be $false
    }
}

Describe 'Falhas de inicializacao e resultado da cascata' {
    foreach ($scenario in @('helper-ausente', 'tiers-invalido', 'resultado-ausente', 'resultado-invalido', 'contagem-invalida')) {
        It "persiste FAILED e tenta notificar em $scenario sem SMTP real" {
            $app = Join-Path $TestDrive $scenario
            Copy-Item -LiteralPath $repositoryRoot -Destination $app -Recurse
            $entry = Join-Path $app 'Invoke-CascadeBackup.ps1'
            $source = (Get-Content -LiteralPath $entry -Raw) -replace '(?m)^#requires -RunAsAdministrator\s*$', ''
            $source = $source.Replace('Send-CascadeEmail -Subject', 'Save-TestEmail -Subject')
            Set-Content -LiteralPath $entry -Value $source -Encoding UTF8
            $settingsPath = Join-Path $app 'Config\Settings.json'
            $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
            $settings.ExcludeVMName = @('EXCLUIDA')
            $settings | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
            if ($scenario -eq 'helper-ausente') { Remove-Item -LiteralPath (Join-Path $app 'Internal\Helpers\ObservabilityHelpers.ps1') }
            if ($scenario -eq 'tiers-invalido') { Set-Content -LiteralPath (Join-Path $app 'Config\Tiers.json') -Value 'invalido' }
            $harness = Join-Path $app 'harness.ps1'
            @'
$global:folder = $PSScriptRoot
function Import-Module { param($Name, $ErrorAction) }
function Get-VM { param($ErrorAction) [pscustomobject]@{Name='EXCLUIDA'; VMId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'} }
function Save-TestEmail { param($Subject, $HtmlBody) $HtmlBody | Set-Content -LiteralPath (Join-Path $global:folder 'email.html') -Encoding UTF8 }
function powershell.exe {
    $arguments = @($args)
    if ((Split-Path $global:folder -Leaf) -eq 'resultado-invalido') {
        '{}' | Set-Content -LiteralPath $arguments[([array]::IndexOf($arguments, '-ResultPath') + 1)]
    }
    if ((Split-Path $global:folder -Leaf) -eq 'contagem-invalida') {
        '{"Status":"SUCCESS","SuccessCount":"invalido","FailureCount":0}' | Set-Content -LiteralPath $arguments[([array]::IndexOf($arguments, '-ResultPath') + 1)]
    }
    $global:LASTEXITCODE = 0
}
& (Join-Path $PSScriptRoot 'Invoke-CascadeBackup.ps1')
'@ | Set-Content -LiteralPath $harness -Encoding UTF8
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $harness | Out-Null
            $report = Get-ChildItem -LiteralPath (Join-Path $app 'Reports') -Filter 'Cascade-*.json' |
                Where-Object { $_.Name -notmatch '\.plan\.json$' } | Select-Object -First 1
            $summary = Get-Content -LiteralPath $report.FullName -Raw | ConvertFrom-Json
            $summary.Status | Should Be 'FAILED'
            $summary.ExitCode | Should Be 1
            Test-Path -LiteralPath (Join-Path $app 'email.html') | Should Be $true
        }
    }
}
