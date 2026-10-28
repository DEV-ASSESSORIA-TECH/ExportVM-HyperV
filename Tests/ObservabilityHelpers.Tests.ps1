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
                    VMResults = @([pscustomobject]@{
                        Name = 'VM & Dados'; Success = $false; CurrentStage = 'INITIALIZE'
                        FailureKind = 'INSUFFICIENT_SPACE'; Error = 'Espaco livre abaixo do minimo configurado.'
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
        $html | Should Match 'CurrentStage: INITIALIZE'
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
