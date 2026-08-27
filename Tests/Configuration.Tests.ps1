$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'TestHelpers.ps1')

$repositoryRoot = Get-RepositoryRoot
$tierHelpersPath = Join-Path $repositoryRoot 'TierHelpers.ps1'
$settingsPath = Join-Path $repositoryRoot 'Config\Settings.json'
$tiersPath = Join-Path $repositoryRoot 'Config\Tiers.json'

. $tierHelpersPath

Describe 'Configuracao atual' {
    It 'carrega Settings.json com o schema e defaults da v1.3' {
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
