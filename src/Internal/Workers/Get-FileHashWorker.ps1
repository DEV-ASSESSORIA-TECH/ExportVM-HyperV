#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    [Parameter(Mandatory = $true)]
    [string]$ResultPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$started = Get-Date

try {
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw "Arquivo nao encontrado: $FilePath"
    }

    $hash = Get-FileHash -LiteralPath $FilePath -Algorithm SHA256 -ErrorAction Stop
    [ordered]@{
        Success = $true
        FilePath = $FilePath
        Algorithm = $hash.Algorithm
        Hash = $hash.Hash
        StartedAt = $started.ToString('o')
        FinishedAt = (Get-Date).ToString('o')
        Error = $null
    } | ConvertTo-Json | Set-Content -LiteralPath $ResultPath -Encoding UTF8

    Write-Output "$($hash.Algorithm) $($hash.Hash)"
    exit 0
}
catch {
    [ordered]@{
        Success = $false
        FilePath = $FilePath
        Algorithm = 'SHA256'
        Hash = $null
        StartedAt = $started.ToString('o')
        FinishedAt = (Get-Date).ToString('o')
        Error = $_.Exception.Message
    } | ConvertTo-Json | Set-Content -LiteralPath $ResultPath -Encoding UTF8

    Write-Error $_.Exception.Message
    exit 1
}
