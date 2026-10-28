$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'TestHelpers.ps1')
$repositoryRoot = Get-RepositoryRoot
. (Join-Path $repositoryRoot 'Internal\Helpers\ObservabilityHelpers.ps1')

Describe 'Motivos de falha no email consolidado' {
    It 'inclui erro global e falha por VM no HTML com escape de caracteres' {
        $wrapper = Join-Path $repositoryRoot 'Invoke-CascadeBackup.ps1'
        . (Get-ScriptFunction -Path $wrapper -Name 'ConvertTo-CascadeHtmlText')
        . (Get-ScriptFunction -Path $wrapper -Name 'New-CascadeHtmlReport')
        $DiagnosticFailures = New-Object System.Collections.Generic.List[string]
        $TierExecutions = @(
            [pscustomobject]@{
                TierName = 'BIG'; Status = 'FAILED'; ExitCode = 1
                SuccessCount = 0; FailureCount = 1; ResultPath = 'BIG.json'
                Result = [pscustomobject]@{
                    Error = 'Destino <indisponivel>'
                    LogPath = 'C:\Logs\BIG-test.log'
                    VMResults = @([pscustomobject]@{
                        Name = 'VM & Dados'; Success = $false; CurrentStage = 'INITIALIZE'
                        FailureKind = 'INSUFFICIENT_SPACE'; Error = 'Espaco livre abaixo do minimo configurado.'
                        Attempts = 1; RequiredFreeGB = 200; AvailableFreeGB = 120
                    })
                }
            }
        ) | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $html = New-CascadeHtmlReport -Summary ([pscustomobject]@{ Status = 'FAILED'; BackupSetId = 'test' })
        $html | Should Match 'Motivos das falhas'
        $html | Should Match 'Destino &lt;indisponivel&gt;'
        $html | Should Match 'VM &amp; Dados'
        $html | Should Match 'INSUFFICIENT_SPACE'
        $html | Should Match 'Espaco livre abaixo do minimo'
        $html | Should Match 'Etapa: INITIALIZE'
        $html | Should Match 'Tentativas: 1'
        $html | Should Match 'Espaco minimo exigido: 200[.,]00 GB'
        $html | Should Match 'Espaco disponivel: 120[.,]00 GB'
        $html | Should Match 'BIG-test.log'
    }

    It 'mostra SKIPPED justificativa exclusoes e avisos no consolidado' {
        $wrapper = Join-Path $repositoryRoot 'Invoke-CascadeBackup.ps1'
        . (Get-ScriptFunction -Path $wrapper -Name 'ConvertTo-CascadeHtmlText')
        . (Get-ScriptFunction -Path $wrapper -Name 'New-CascadeHtmlReport')
        $DiagnosticFailures = New-Object System.Collections.Generic.List[string]
        $TierExecutions = @([pscustomobject]@{
            TierName = 'BIG'; Status = 'SKIPPED'; ExitCode = 0; SuccessCount = 0; FailureCount = 0
            ResultPath = 'BIG.json'; Result = [pscustomobject]@{ SkipReason = 'Todas as VMs foram excluidas'; LogPath = 'BIG.log' }
        })
        $summary = [ordered]@{ Status = 'SKIPPED'; BackupSetId = 'test'; SelectionPlan = [pscustomobject]@{
            Warnings = @('Nome antigo nao encontrado <teste>')
            ExcludedVMs = @([pscustomobject]@{ Name = 'VM & Dados'; VMId = 'test-id'; Reason = 'ExcludeVMId' })
        } }
        $html = New-CascadeHtmlReport -Summary $summary
        $html | Should Match 'SKIPPED'
        $html | Should Match 'Todas as VMs foram excluidas'
        $html | Should Match 'Nome antigo nao encontrado &lt;teste&gt;'
        $html | Should Match 'VM &amp; Dados'
        $html | Should Match 'ExcludeVMId'
    }

    It 'mostra diagnostico quando o processo nao entrega resultado' {
        $wrapper = Join-Path $repositoryRoot 'Invoke-CascadeBackup.ps1'
        . (Get-ScriptFunction -Path $wrapper -Name 'ConvertTo-CascadeHtmlText')
        . (Get-ScriptFunction -Path $wrapper -Name 'New-CascadeHtmlReport')
        $DiagnosticFailures = New-Object System.Collections.Generic.List[string]
        $TierExecutions = @([pscustomobject]@{
            TierName = 'BIG'; Status = 'FAILED'; ExitCode = 1
            SuccessCount = 0; FailureCount = 0; ResultPath = 'BIG.json'; Result = $null
        })
        $html = New-CascadeHtmlReport -Summary ([pscustomobject]@{ Status = 'FAILED'; BackupSetId = 'test' })
        $html | Should Match 'Resultado indisponivel'
    }
}

Describe 'Precedencia da cascata noturna' {
    It 'preserva SKIPPED quando todos os lotes sao ignorados e sucesso quando algum executa' {
        $skipped = [pscustomobject]@{ Status = 'SKIPPED'; ExitCode = 0 }
        (Get-NightlyCascadeOutcome -TierExecutions @($skipped, $skipped)).Status | Should Be 'SKIPPED'
        (Get-NightlyCascadeOutcome -TierExecutions @($skipped) -DiagnosticFailureCount 1).ExitCode | Should Be 2
        (Get-NightlyCascadeOutcome -TierExecutions @($skipped, [pscustomobject]@{ Status = 'SUCCESS'; ExitCode = 0 })).Status | Should Be 'SUCCESS'
    }
    It 'mantem codigo 1 quando backup e observabilidade falham juntos' {
        $executions = @(
            [pscustomobject]@{ Status = 'PARTIAL_SUCCESS'; ExitCode = 1 },
            [pscustomobject]@{ Status = 'SUCCESS_WITH_WARNINGS'; ExitCode = 2 }
        )

        $outcome = Get-NightlyCascadeOutcome -TierExecutions $executions -DiagnosticFailureCount 2

        $outcome.Status | Should Be 'FAILED'
        $outcome.ExitCode | Should Be 1
    }

    It 'retorna codigo 2 somente quando nao ha falha de backup' {
        $executions = @(
            [pscustomobject]@{ Status = 'SUCCESS'; ExitCode = 0 },
            [pscustomobject]@{ Status = 'SUCCESS_WITH_WARNINGS'; ExitCode = 2 }
        )

        (Get-NightlyCascadeOutcome -TierExecutions $executions).ExitCode | Should Be 2
        (Get-NightlyCascadeOutcome -TierExecutions @([pscustomobject]@{ Status = 'SUCCESS'; ExitCode = 0 })).ExitCode | Should Be 0
    }

    It 'trata codigo de processo desconhecido como falha' {
        $outcome = Get-NightlyCascadeOutcome -TierExecutions @([pscustomobject]@{ Status = ''; ExitCode = 17 })
        $outcome.ExitCode | Should Be 1
        (Get-NightlyCascadeOutcome -TierExecutions @([pscustomobject]@{ Status = 'UNKNOWN'; ExitCode = 0 })).ExitCode | Should Be 1
    }
}

Describe 'Snapshots de relatorio' {
    It 'substitui JSON e texto somente depois de concluir a gravacao temporaria' {
        $jsonPath = Join-Path $TestDrive 'reports\result.json'
        $htmlPath = Join-Path $TestDrive 'reports\result.html'

        Write-JsonSnapshot -Value ([ordered]@{ Status = 'SUCCESS'; MailSent = $false }) -Path $jsonPath
        Write-TextSnapshot -Value '<html>ok</html>' -Path $htmlPath

        (Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json).Status | Should Be 'SUCCESS'
        Get-Content -LiteralPath $htmlPath -Raw | Should Match '<html>ok</html>'
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $jsonPath) -Filter '*.tmp-*').Count | Should Be 0
    }
}

Describe 'Integracao de observabilidade' {
    $mainSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'Invoke-VMExportBackup.ps1') -Raw
    $wrapperSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'Invoke-CascadeBackup.ps1') -Raw

    It 'planeja uma vez antes dos discos e compartilha o plano com todos os filhos' {
        $appRoot = Join-Path $TestDrive 'cascade-app'
        Copy-Item -LiteralPath $repositoryRoot -Destination $appRoot -Recurse
        $entryPath = Join-Path $appRoot 'Invoke-CascadeBackup.ps1'
        $source = (Get-Content -LiteralPath $entryPath -Raw) -replace '(?m)^#requires -RunAsAdministrator\s*$', ''
        Set-Content -LiteralPath $entryPath -Value $source -Encoding UTF8
        $settingsPath = Join-Path $appRoot 'Config\Settings.json'
        $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        $settings.ExcludeVMId = @('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
        $settings | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
        $harness = Join-Path $TestDrive 'cascade-harness.ps1'
        @'
$global:vmQueries = 0
$global:planPaths = New-Object System.Collections.Generic.List[string]
function Import-Module { param($Name, $ErrorAction) }
function Get-VM {
    param($ErrorAction)
    $global:vmQueries++
    [pscustomobject]@{ Name = 'RENOMEADA'; VMId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
}
function Get-VMHardDiskDrive { throw 'Consultou disco de VM excluida.' }
function powershell.exe {
    $arguments = @($args)
    $planPath = [string]$arguments[([array]::IndexOf($arguments, '-SelectionPlanPath') + 1)]
    $resultPath = [string]$arguments[([array]::IndexOf($arguments, '-ResultPath') + 1)]
    if (-not (Test-Path -LiteralPath $planPath)) { throw 'Plano nao foi persistido antes dos filhos.' }
    $global:planPaths.Add($planPath)
    [pscustomobject]@{
        Status = 'SKIPPED'; SuccessCount = 0; FailureCount = 0; VMResults = @()
        Error = $null; LogPath = 'filho.log'; SkipReason = 'Todas as VMs excluidas pelo plano'
    } | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
    $global:LASTEXITCODE = 0
}
& (Join-Path $PSScriptRoot 'cascade-app\Invoke-CascadeBackup.ps1')
[pscustomobject]@{ VMQueries = $global:vmQueries; PlanPaths = $global:planPaths.ToArray() } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'cascade-audit.json') -Encoding UTF8
'@ | Set-Content -LiteralPath $harness -Encoding UTF8
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $harness | Out-Null
        $audit = Get-Content -LiteralPath (Join-Path $TestDrive 'cascade-audit.json') -Raw | ConvertFrom-Json
        $audit.VMQueries | Should Be 1
        @($audit.PlanPaths).Count | Should Be 3
        @($audit.PlanPaths | Select-Object -Unique).Count | Should Be 1
        $summaryPath = Get-ChildItem -LiteralPath (Join-Path $appRoot 'Reports') -Filter 'Cascade-*.json' |
            Where-Object { $_.Name -notmatch '\.plan\.json$' } | Select-Object -First 1
        $summary = Get-Content -LiteralPath $summaryPath.FullName -Raw | ConvertFrom-Json
        $summary.Status | Should Be 'SKIPPED'
        $summary.ExitCode | Should Be 0
        @($summary.SelectionPlan.VMs).Count | Should Be 0
        $summary.SelectionPlan.ExcludedVMs[0].Reason | Should Be 'ExcludeVMId'
        $summary.NotificationStatus | Should Be 'NOT_REQUIRED'
    }

    It 'faz os tiers adiarem email e entregarem resultado deterministico ao wrapper' {
        $wrapperSource | Should Match '-DeferEmail\s+-ResultPath\s+\$tierResultPath'
        $mainSource | Should Match "NotificationStatus\s*=\s*'DEFERRED_TO_WRAPPER'"
    }

    It 'possui somente um ponto de envio consolidado depois do loop dos tiers' {
        ([regex]::Matches($wrapperSource, 'Send-CascadeEmail -Subject')).Count | Should Be 1
        $wrapperSource.IndexOf('Send-CascadeEmail -Subject') | Should BeGreaterThan $wrapperSource.IndexOf('foreach ($tier in $tierDefinitions.Tiers)')
    }

    It 'persiste o resultado da notificacao nos relatorios locais' {
        $mainSource | Should Match '\$summary\.NotificationStatus\s*=\s*\$NotificationStatus'
        $mainSource | Should Match '\$summary\.MailSent\s*=\s*\$MailSent'
        $wrapperSource | Should Match '\$summary\.MailError\s*=\s*\$MailError'
    }
}

Describe 'Logs tolerantes a falha de arquivo' {
    It 'mantem console e registra diagnostico quando o log do tier nao pode ser escrito' {
        . (Get-ScriptFunction -Path (Join-Path $repositoryRoot 'Invoke-VMExportBackup.ps1') -Name 'Write-Log')
        $script:LogPath = $TestDrive
        $script:DiagnosticFailures = New-Object System.Collections.Generic.List[string]

        { Write-Log -Message 'continua' } | Should Not Throw
        $script:DiagnosticFailures.Count | Should Be 1
    }

    It 'nao interrompe a cascata quando seu arquivo de log esta indisponivel' {
        . (Get-ScriptFunction -Path (Join-Path $repositoryRoot 'Invoke-CascadeBackup.ps1') -Name 'Write-CascadeLog')
        $script:LogPath = $TestDrive
        $script:DiagnosticFailures = New-Object System.Collections.Generic.List[string]

        { Write-CascadeLog -Message 'continua' } | Should Not Throw
        $script:DiagnosticFailures.Count | Should Be 1
    }
}
