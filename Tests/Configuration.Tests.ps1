$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'TestHelpers.ps1')

$repositoryRoot = Get-RepositoryRoot
$tierHelpersPath = Join-Path $repositoryRoot 'Internal\Helpers\TierHelpers.ps1'
$settingsPath = Join-Path $repositoryRoot 'Config\Settings.json'
$tiersPath = Join-Path $repositoryRoot 'Config\Tiers.json'

. $tierHelpersPath

Describe 'Configuracao atual' {
    It 'valida exclusoes por VMId sem aceitar GUID invalido ou vazio' {
        $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        $settings.ExcludeVMId = @('11111111-1111-1111-1111-111111111111')
        Assert-SettingsSchemaV2 -ConfigObject $settings | Should Be $true
        $settings.ExcludeVMId = @('invalido')
        { Assert-SettingsSchemaV2 -ConfigObject $settings } | Should Throw 'GUIDs validos'
        $settings.ExcludeVMId = @([guid]::Empty.ToString())
        { Assert-SettingsSchemaV2 -ConfigObject $settings } | Should Throw 'GUIDs validos'
        $settings.ExcludeVMId = '11111111-1111-1111-1111-111111111111'
        { Assert-SettingsSchemaV2 -ConfigObject $settings } | Should Throw 'lista JSON'
    }
    It 'valida a lista opcional de exclusoes' {
        $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        @($settings.ExcludeVMName).Count | Should Be 0
        $settings.ExcludeVMName = @('VM-TESTE')
        Assert-SettingsSchemaV2 -ConfigObject $settings | Should Be $true
        $settings.ExcludeVMName = 'VM-TESTE'
        { Assert-SettingsSchemaV2 -ConfigObject $settings } | Should Throw 'lista JSON'
        $settings.ExcludeVMName = @('')
        { Assert-SettingsSchemaV2 -ConfigObject $settings } | Should Throw 'nao vazios'
    }
    It 'carrega Settings.json com o schema e defaults da v2.0' {
        $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json

        $settings.SchemaVersion | Should Be 2
        $settings.FailedPayloadKeepPerVM | Should Be 3
        $settings.PSObject.Properties.Name -contains 'FailedRetentionDays' | Should Be $false
        $settings.SkipHash | Should Be $true
        $settings.KeepRestorePoints | Should Be 3
        Assert-SettingsSchemaV2 -ConfigObject $settings | Should Be $true
    }

    It 'rejeita Settings.json antigo ou com campo legado' {
        { Assert-SettingsSchemaV2 -ConfigObject ([pscustomobject]@{ SchemaVersion = 1; FailedPayloadKeepPerVM = 3; SkipHash = $true }) } |
            Should Throw 'SchemaVersion 2'
        { Assert-SettingsSchemaV2 -ConfigObject ([pscustomobject]@{ SchemaVersion = 2; FailedRetentionDays = 7; FailedPayloadKeepPerVM = 3; SkipHash = $true }) } |
            Should Throw 'nao aceita FailedRetentionDays'
    }

    It 'carrega e ordena os tiers configurados' {
        $definitions = Get-TierDefinitions -Path $tiersPath

        $definitions.Tiers.Count | Should Be 3
        @($definitions.Tiers | Select-Object -ExpandProperty Name) -join ',' | Should Be 'SMALL,MEDIUM,BIG'
        $definitions.CascadeStartTime | Should Be '21:00'
        $definitions.CascadeExecutionTimeLimitHours | Should Be 20
    }

    It 'classifica os limites de tamanho sem lacunas' {
        $definitions = Get-TierDefinitions -Path $tiersPath

        Resolve-VMTier -SizeBytes 0 -TierDefinitions $definitions | Should Be 'SMALL'
        Resolve-VMTier -SizeBytes (25GB - 1) -TierDefinitions $definitions | Should Be 'SMALL'
        Resolve-VMTier -SizeBytes 25GB -TierDefinitions $definitions | Should Be 'MEDIUM'
        Resolve-VMTier -SizeBytes 75GB -TierDefinitions $definitions | Should Be 'BIG'
    }

    It 'rejeita uma configuracao de tiers com lacuna' {
        $invalidPath = Join-Path $TestDrive 'Tiers-invalid.json'
        @'
{
  "SchemaVersion": 2,
  "CascadeStartTime": "21:00",
  "CascadeExecutionTimeLimitHours": 20,
  "Tiers": [
    { "Name": "SMALL", "MinSizeGB": 0, "MaxSizeGB": 20, "KeepRestorePoints": 3 },
    { "Name": "BIG", "MinSizeGB": 25, "MaxSizeGB": null, "KeepRestorePoints": 3 }
  ],
  "DefaultTier": "SMALL"
}

'@ | Set-Content -LiteralPath $invalidPath -Encoding UTF8

        { Get-TierDefinitions -Path $invalidPath } | Should Throw
    }
}

Describe 'Plano unico de selecao e exclusoes antes dos discos' {
    It 'exclui por VMId apos renomeacao sem consultar discos da VM ignorada' {
        $vms = @(
            [pscustomobject]@{ Name = 'NOVO-NOME'; VMId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' },
            [pscustomobject]@{ Name = 'INCLUIDA'; VMId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' }
        )
        $plan = New-VMSelectionPlan -AllVMs $vms -ExcludeVMId @('{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}') -GetSizeAction {
            param($Name)
            if ($Name -ne 'INCLUIDA') { throw 'Consultou disco de VM excluida.' }
            1GB
        }
        @($plan.VMs).Count | Should Be 1
        $plan.VMs[0].Name | Should Be 'INCLUIDA'
        $plan.ExcludedVMs[0].Reason | Should Be 'ExcludeVMId'
    }

    It 'usa nomes exatos sem diferenciar maiusculas nem interpretar curingas' {
        $vms = @(
            [pscustomobject]@{ Name = 'VM-TESTE'; VMId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' },
            [pscustomobject]@{ Name = 'VM-TESTE-2'; VMId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' }
        )
        $plan = New-VMSelectionPlan -AllVMs $vms -ExcludeVMName @('vm-teste', 'VM-*') -GetSizeAction { param($Name) 1GB }
        @($plan.VMs).Count | Should Be 1
        $plan.VMs[0].Name | Should Be 'VM-TESTE-2'
        @($plan.Warnings).Count | Should Be 1
        $plan.Warnings[0] | Should Match 'nao encontrada no host'
    }

    It 'mantem exclusao mesmo quando VMName solicita a VM explicitamente' {
        $vms = @([pscustomobject]@{ Name = 'EXCLUIDA'; VMId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' })
        $plan = New-VMSelectionPlan -AllVMs $vms -RequestedNames EXCLUIDA -ExcludeVMName EXCLUIDA -GetSizeAction { throw 'Nao deve consultar discos.' }
        @($plan.VMs).Count | Should Be 0
        @($plan.ExcludedVMs).Count | Should Be 1
    }

    It 'persiste lotes uma vez e resolve por VMId mesmo com renomeacao posterior' {
        $definitions = Get-TierDefinitions -Path $tiersPath
        $vms = @(
            [pscustomobject]@{ Name = 'PEQUENA'; VMId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' },
            [pscustomobject]@{ Name = 'GRANDE'; VMId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' }
        )
        $plan = New-VMSelectionPlan -AllVMs $vms -TierDefinitions $definitions -GetSizeAction {
            param($Name)
            if ($Name -eq 'PEQUENA') { 1GB } else { 100GB }
        }
        $plan = $plan | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $vms[0].Name = 'RENOMEADA'
        $small = @(Resolve-VMSelectionPlan -Plan $plan -AllVMs $vms -BatchName SMALL)
        $big = @(Resolve-VMSelectionPlan -Plan $plan -AllVMs $vms -BatchName BIG)
        $small.Count | Should Be 1
        $small[0].Name | Should Be 'RENOMEADA'
        $small[0].SourceBytes | Should Be 1GB
        $big.Count | Should Be 1
        $big[0].Name | Should Be 'GRANDE'
        @(Resolve-VMSelectionPlan -Plan $plan -AllVMs $vms -BatchName MEDIUM).Count | Should Be 0
        $missing = @(Resolve-VMSelectionPlan -Plan $plan -AllVMs @($vms[1]) -BatchName ALL)
        $missing.Count | Should Be 2
        $unavailable = @($missing | Where-Object { $_.PSObject.Properties.Name -contains 'SelectionError' })
        $unavailable.Count | Should Be 1
        $unavailable[0].SelectionError | Should Match 'VM do plano nao encontrada'
    }
}
