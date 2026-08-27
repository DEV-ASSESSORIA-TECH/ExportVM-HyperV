#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$testsPath = Join-Path $scriptRoot 'Tests'

Import-Module Pester -RequiredVersion 3.4.0 -ErrorAction Stop
$result = Invoke-Pester -Path $testsPath -PassThru

if ($result.FailedCount -gt 0) {
    exit 1
}

exit 0
