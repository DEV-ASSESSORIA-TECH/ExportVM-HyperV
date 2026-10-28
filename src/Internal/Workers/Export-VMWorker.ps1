#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VMName,

    [Parameter(Mandatory = $true)]
    [string]$ExportPath,

    [Parameter(Mandatory = $true)]
    [string]$ResultPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$started = Get-Date

try {
    Import-Module Hyper-V -ErrorAction Stop
    $vm = Get-VM -Name $VMName -ErrorAction Stop

    if (-not (Test-Path -LiteralPath $ExportPath)) {
        New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null
    }

    Write-Output "Inicio da exportacao: VM=$($vm.Name), VMId=$($vm.VMId), Estado=$($vm.State), Destino=$ExportPath"

    $command = Get-Command Export-VM -ErrorAction Stop
    if ($command.Parameters.ContainsKey('CaptureLiveState')) {
        Export-VM `
            -VM $vm `
            -Path $ExportPath `
            -CaptureLiveState CaptureDataConsistentState `
            -ErrorAction Stop
    }
    else {
        Export-VM -VM $vm -Path $ExportPath -ErrorAction Stop
    }

    $files = @(Get-ChildItem -LiteralPath $ExportPath -File -Recurse -Force -ErrorAction Stop)
    $bytes = [long](($files | Measure-Object -Property Length -Sum).Sum)
    if ($files.Count -eq 0 -or $bytes -lt 1MB) {
        throw 'A exportacao terminou sem arquivos validos.'
    }

    $result = [ordered]@{
        Success = $true
        VMName = $vm.Name
        VMId = [string]$vm.VMId
        State = [string]$vm.State
        StartedAt = $started.ToString('o')
        FinishedAt = (Get-Date).ToString('o')
        FileCount = $files.Count
        Bytes = $bytes
        Error = $null
    }

    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
    Write-Output "Exportacao concluida. Arquivos=$($files.Count), Bytes=$bytes"
    exit 0
}
catch {
    $result = [ordered]@{
        Success = $false
        VMName = $VMName
        VMId = $null
        State = $null
        StartedAt = $started.ToString('o')
        FinishedAt = (Get-Date).ToString('o')
        FileCount = 0
        Bytes = 0
        Error = $_.Exception.Message
        Stack = $_.ScriptStackTrace
    }

    try {
        $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
    }
    catch { }

    Write-Error $_.Exception.Message
    exit 1
}
