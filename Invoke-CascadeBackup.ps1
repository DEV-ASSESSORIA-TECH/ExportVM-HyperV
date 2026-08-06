#requires -Version 5.1
#requires -RunAsAdministrator

<#
    Orquestra a cascata noturna: gera uma assinatura compartilhada (CascadeId) e roda
    cada lote definido em Config\Tiers.json em sequencia (SMALL -> MEDIUM -> BIG, ordem
    de MinSizeGB ascendente), um atras do outro, cada um como processo powershell.exe
    separado - assim os tres publicam dentro da mesma pasta na raiz do repositorio
    (ver Invoke-VMExportBackup.ps1, parametro -CascadeId), e o "exit" interno de cada
    lote nao encerra a cadeia inteira.

    Chamado uma vez por noite pela tarefa agendada unica criada por
    Install-VMExportBackupTask.ps1. Uma falha num lote nao impede os seguintes de
    rodar - cada lote ja alerta por e-mail individualmente (ver Invoke-VMExportBackup.ps1).
    O exit code deste wrapper so serve para o LastTaskResult do Agendador do Windows.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptPath = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$ScriptRoot = Split-Path -Parent $ScriptPath
$MainScript = Join-Path $ScriptRoot 'Invoke-VMExportBackup.ps1'
$TierHelpersPath = Join-Path $ScriptRoot 'TierHelpers.ps1'
$TiersConfigPath = Join-Path $ScriptRoot 'Config\Tiers.json'
$LogDir = Join-Path $ScriptRoot 'Logs'

if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

$LogPath = Join-Path $LogDir "Cascade-$((Get-Date).ToString('yyyy-MM-dd_HH-mm-ss')).log"

function Write-CascadeLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'SUCCESS', 'WARNING', 'ERROR')][string]$Level = 'INFO'
    )
    $line = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [$Level] $Message"
    Write-Host $line
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

Write-CascadeLog ('=' * 74)
Write-CascadeLog 'Inicio da cascata noturna (Invoke-CascadeBackup.ps1).'

if (-not (Test-Path -LiteralPath $MainScript -PathType Leaf)) {
    Write-CascadeLog "Script principal nao encontrado: $MainScript" 'ERROR'
    exit 1
}
if (-not (Test-Path -LiteralPath $TierHelpersPath -PathType Leaf)) {
    Write-CascadeLog "Modulo de lotes nao encontrado: $TierHelpersPath" 'ERROR'
    exit 1
}

. $TierHelpersPath

try {
    $tierDefinitions = Get-TierDefinitions -Path $TiersConfigPath
}
catch {
    Write-CascadeLog "Falha ao carregar $TiersConfigPath : $($_.Exception.Message)" 'ERROR'
    exit 1
}

if ($null -eq $tierDefinitions) {
    Write-CascadeLog "$TiersConfigPath nao encontrado. A cascata precisa da config de lotes para saber a ordem e a lista de lotes a rodar." 'ERROR'
    exit 1
}

# CascadeId gerado uma unica vez, antes do primeiro lote - garante que os tres
# processos publiquem na mesma pasta mesmo que a cascata atravesse a virada do dia
# (ex.: BIG terminando de madrugada do dia seguinte).
$CascadeId = "{0}_CASCATA_{1}" -f (Get-Date -Format 'yyyy-MM-dd'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
Write-CascadeLog "CascadeId: $CascadeId"
Write-CascadeLog "Ordem dos lotes: $(($tierDefinitions.Tiers | Select-Object -ExpandProperty Name) -join ' -> ')"

$allSucceeded = $true

foreach ($tier in $tierDefinitions.Tiers) {
    Write-CascadeLog ('-' * 74)
    Write-CascadeLog "Lote '$($tier.Name)': iniciando."
    $tierStart = Get-Date

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $MainScript -BatchName $tier.Name -Execute -CascadeId $CascadeId
    $exitCode = $LASTEXITCODE

    $tierDuration = (Get-Date) - $tierStart
    if ($exitCode -eq 0) {
        Write-CascadeLog "Lote '$($tier.Name)': concluido com sucesso. Duracao=$($tierDuration.ToString('hh\:mm\:ss'))." 'SUCCESS'
    }
    else {
        $allSucceeded = $false
        Write-CascadeLog "Lote '$($tier.Name)': terminou com ExitCode=$exitCode. Duracao=$($tierDuration.ToString('hh\:mm\:ss')). Verifique o relatorio/e-mail desse lote para o motivo - a cascata continua com o proximo lote." 'ERROR'
    }
}

Write-CascadeLog ('-' * 74)
if ($allSucceeded) {
    Write-CascadeLog "Cascata concluida. Todos os lotes terminaram com sucesso. CascadeId=$CascadeId" 'SUCCESS'
    exit 0
}
else {
    Write-CascadeLog "Cascata concluida com pelo menos um lote com problema. CascadeId=$CascadeId" 'ERROR'
    exit 1
}
