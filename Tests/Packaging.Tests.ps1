$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'TestHelpers.ps1')
$projectRoot = Get-ProjectRoot
$packageScript = Join-Path $projectRoot 'scripts\Package.ps1'
$workflowPath = Join-Path $projectRoot '.github\workflows\release.yml'

Describe 'Versionamento 2.0.3' {
    It 'mantem VERSION e ScriptVersion sincronizados' {
        (Get-Content -LiteralPath (Join-Path $projectRoot 'VERSION') -Raw).Trim() | Should Be '2.0.3'
        Get-Content -LiteralPath (Join-Path $projectRoot 'src\Invoke-VMExportBackup.ps1') -Raw |
            Should Match "(?m)^\`$ScriptVersion\s*=\s*'2\.0\.3'\s*$"
    }
}

Describe 'Pacote de release' {
    It 'gera ZIP instalavel e checksum sem arquivos de desenvolvimento' {
        $output = Join-Path $TestDrive 'dist'
        $result = & $packageScript -Version '2.0.3' -OutputDirectory $output

        Test-Path -LiteralPath $result.ArchivePath -PathType Leaf | Should Be $true
        Test-Path -LiteralPath $result.ChecksumPath -PathType Leaf | Should Be $true
        $result.Tag | Should Be 'v2.0.3'

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [System.IO.Compression.ZipFile]::OpenRead($result.ArchivePath)
        try { $entries = @($archive.Entries | Select-Object -ExpandProperty FullName) }
        finally { $archive.Dispose() }

        $entries -contains 'VM-Export-Backup-2.0.3\Invoke-VMExportBackup.ps1' | Should Be $true
        $entries -contains 'VM-Export-Backup-2.0.3\Config\Settings.json' | Should Be $true
        $entryPoints = @('Invoke-VMExportBackup.ps1', 'Invoke-CascadeBackup.ps1', 'Install-VMExportBackupTask.ps1')
        $rootScripts = @($entries | Where-Object { $_ -match '^VM-Export-Backup-2\.0\.3\\[^\\]+\.ps1$' })
        $rootScripts.Count | Should Be 3
        foreach ($entryPoint in $entryPoints) {
            $entries -contains "VM-Export-Backup-2.0.3\$entryPoint" | Should Be $true
        }
        $internalFiles = @(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'src\Internal') -File -Recurse -Filter '*.ps1')
        $internalFiles.Count | Should Be 11
        foreach ($internalFile in $internalFiles) {
            $relative = $internalFile.FullName.Substring((Join-Path $projectRoot 'src').Length + 1)
            $entries -contains "VM-Export-Backup-2.0.3\$relative" | Should Be $true
        }
        $extractRoot = Join-Path $TestDrive 'extracted'
        [System.IO.Compression.ZipFile]::ExtractToDirectory($result.ArchivePath, $extractRoot)
        $installedRoot = Join-Path $extractRoot 'VM-Export-Backup-2.0.3'
        foreach ($entryPoint in $entryPoints) {
            $source = Get-Content -LiteralPath (Join-Path $installedRoot $entryPoint) -Raw
            $references = [regex]::Matches($source, "'(Internal\\[^']+\.ps1)'")
            $references.Count | Should BeGreaterThan 0
            foreach ($reference in $references) {
                Test-Path -LiteralPath (Join-Path $installedRoot $reference.Groups[1].Value) -PathType Leaf | Should Be $true
            }
        }
        foreach ($scriptFile in @(Get-ChildItem -LiteralPath $installedRoot -File -Recurse -Filter '*.ps1')) {
            $tokens = $null; $parseErrors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$parseErrors)
            $parseErrors.Count | Should Be 0
        }
        @($entries | Where-Object { $_ -match '\\Tests\\|\\scripts\\|\.github' }).Count | Should Be 0
    }

    It 'recusa empacotar uma versao diferente de VERSION' {
        { & $packageScript -Version '2.0.0' -OutputDirectory (Join-Path $TestDrive 'invalid') } |
            Should Throw "difere de VERSION '2.0.3'"
    }
}

Describe 'Workflow exclusivo de release' {
    It 'publica apenas quando uma tag versionada e enviada' {
        $source = Get-Content -LiteralPath $workflowPath -Raw
        $source | Should Match "tags:\s*\r?\n\s*- 'v\*\.\*\.\*'"
        $source | Should Match 'contents:\s*write'
        $source | Should Match 'gh release create'
        $source | Should Match '--verify-tag'
        $source | Should Not Match 'Invoke-Tests|Invoke-Pester|\btest\b'
    }
}
