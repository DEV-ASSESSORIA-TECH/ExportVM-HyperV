#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$Version,
    [string]$OutputDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptRoot
$sourceRoot = Join-Path $projectRoot 'src'
$versionPath = Join-Path $projectRoot 'VERSION'

if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
    throw "Arquivo VERSION nao encontrado: $versionPath"
}
$declaredVersion = (Get-Content -LiteralPath $versionPath -Raw -ErrorAction Stop).Trim()
if ([string]::IsNullOrWhiteSpace($Version)) { $Version = $declaredVersion }
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Versao invalida: '$Version'. Use MAJOR.MINOR.PATCH." }
if ($Version -cne $declaredVersion) { throw "Versao solicitada '$Version' difere de VERSION '$declaredVersion'." }

$mainScriptPath = Join-Path $sourceRoot 'Invoke-VMExportBackup.ps1'
if (-not (Test-Path -LiteralPath $mainScriptPath -PathType Leaf)) { throw "Script principal nao encontrado: $mainScriptPath" }
$mainSource = Get-Content -LiteralPath $mainScriptPath -Raw -ErrorAction Stop
if ($mainSource -notmatch "(?m)^\`$ScriptVersion\s*=\s*'$([regex]::Escape($Version))'\s*$") {
    throw "Invoke-VMExportBackup.ps1 nao declara ScriptVersion '$Version'."
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $projectRoot 'dist'
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force -ErrorAction Stop | Out-Null
}

$packageName = "VM-Export-Backup-$Version"
$archivePath = Join-Path $OutputDirectory "$packageName.zip"
$checksumPath = "$archivePath.sha256"
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vm-export-package-" + [guid]::NewGuid().ToString('N'))
$packageRoot = Join-Path $temporaryRoot $packageName

try {
    New-Item -ItemType Directory -Path $packageRoot -Force -ErrorAction Stop | Out-Null

    foreach ($file in @(Get-ChildItem -LiteralPath $sourceRoot -File -Filter '*.ps1' -ErrorAction Stop)) {
        Copy-Item -LiteralPath $file.FullName -Destination $packageRoot -Force -ErrorAction Stop
    }
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'Config') -Destination $packageRoot -Recurse -Force -ErrorAction Stop
    Copy-Item -LiteralPath (Join-Path $projectRoot 'docs') -Destination $packageRoot -Recurse -Force -ErrorAction Stop
    foreach ($name in @('README.md', 'CHANGELOG.md', 'VERSION')) {
        Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination $packageRoot -Force -ErrorAction Stop
    }

    $required = @(
        'Invoke-VMExportBackup.ps1', 'Invoke-CascadeBackup.ps1', 'Install-VMExportBackupTask.ps1',
        'Config\Settings.json', 'Config\Tiers.json', 'README.md', 'VERSION'
    )
    foreach ($relativePath in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $packageRoot $relativePath))) {
            throw "Arquivo obrigatorio ausente do staging do pacote: $relativePath"
        }
    }

    if (Test-Path -LiteralPath $archivePath -PathType Leaf) { Remove-Item -LiteralPath $archivePath -Force -ErrorAction Stop }
    if (Test-Path -LiteralPath $checksumPath -PathType Leaf) { Remove-Item -LiteralPath $checksumPath -Force -ErrorAction Stop }
    Compress-Archive -LiteralPath $packageRoot -DestinationPath $archivePath -CompressionLevel Optimal -ErrorAction Stop

    $hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    Set-Content -LiteralPath $checksumPath -Value "$hash  $([System.IO.Path]::GetFileName($archivePath))" -Encoding ASCII -ErrorAction Stop

    [pscustomobject][ordered]@{
        Version = $Version
        Tag = "v$Version"
        ArchivePath = $archivePath
        ChecksumPath = $checksumPath
        SHA256 = $hash
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
