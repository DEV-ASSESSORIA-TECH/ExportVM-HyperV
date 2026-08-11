#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z]:$')]
    [string]$BackupDrive = 'F:',

    [string]$ExpectedVolumeLabel = 'BACKUP-HYPERV',

    [string]$RepositoryFolder = 'HyperV-Exports',

    [string[]]$VMName,

    [ValidateRange(1, 30)]
    [int]$KeepRestorePoints = 3,

    [ValidateRange(0, 9)]
    [int]$CompressionLevel = 3,

    [ValidateRange(15, 600)]
    [int]$HeartbeatSeconds = 30,

    [ValidateRange(1, 48)]
    [int]$ExportTimeoutHours = 12,

    [ValidateRange(1, 48)]
    [int]$CompressionTimeoutHours = 12,

    [ValidateRange(1, 24)]
    [int]$IntegrityTimeoutHours = 8,

    [ValidateRange(20, 1000)]
    [int]$MinFreeGB = 200,

    [ValidateRange(0, 3)]
    [int]$RetryCount = 1,

    [ValidateRange(0, 60)]
    [int]$FailedRetentionDays = 7,

    [string]$SevenZipPath = 'C:\Program Files\7-Zip\7z.exe',

    [string]$SmtpServer = '192.168.4.10',

    [ValidateRange(1, 65535)]
    [int]$SmtpPort = 25,

    [string]$MailFrom = 'alertas@assessoriatech.com',

    [string[]]$MailTo = @('suporte@assessoriatech.com'),

    [switch]$SkipEmail,

    [switch]$SkipHash,

    [switch]$Execute
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ScriptVersion = '1.0.5'
$RunId = [guid]::NewGuid().ToString('N')
$RunStart = Get-Date
$Mode = if ($Execute) { 'EXECUTE' } else { 'PLAN' }
$ComputerName = $env:COMPUTERNAME
$ScriptPath = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$ScriptRoot = Split-Path -Parent $ScriptPath
$LogDir = Join-Path $ScriptRoot 'Logs'
$ReportDir = Join-Path $ScriptRoot 'Reports'
$LockDir = Join-Path $ScriptRoot 'Locks'
$ConfigDir = Join-Path $ScriptRoot 'Config'
$WorkerPath = Join-Path $ScriptRoot 'Export-VMWorker.ps1'
$HashWorkerPath = Join-Path $ScriptRoot 'Get-FileHashWorker.ps1'
$Timestamp = $RunStart.ToString('yyyy-MM-dd_HH-mm-ss')
$LogPath = Join-Path $LogDir "VMExportBackup-$Timestamp.log"
$JsonPath = Join-Path $ReportDir "VMExportBackup-$Timestamp.json"
$HtmlPath = Join-Path $ReportDir "VMExportBackup-$Timestamp.html"
$LockPath = Join-Path $LockDir 'VMExportBackup.lock.json'
$RepositoryRoot = Join-Path ($BackupDrive + '\') $RepositoryFolder
$StagingRoot = Join-Path $RepositoryRoot '_STAGING'
$FailedRoot = Join-Path $RepositoryRoot '_FAILED'
$RestorePointName = "$Timestamp-$($RunId.Substring(0, 8))"
$StagingPoint = Join-Path $StagingRoot $RestorePointName
$FinalPoint = Join-Path $RepositoryRoot $RestorePointName
$CurrentStage = 'Inicializacao'
$ExitCode = 1
$LockAcquired = $false
$MailSent = $false
$MailError = $null
$GlobalError = $null
$Warnings = New-Object System.Collections.Generic.List[string]
$VMResults = New-Object System.Collections.Generic.List[object]
$DeletedRestorePoints = New-Object System.Collections.Generic.List[string]
$SelectedVMs = @()
$InitialFreeGB = $null
$FinalFreeGB = $null
$RepositoryPublished = $false
$OverallStatus = 'FAILED'

foreach ($dir in @($LogDir, $ReportDir, $LockDir, $ConfigDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'SUCCESS', 'WARNING', 'ERROR', 'WAIT')]
        [string]$Level = 'INFO'
    )

    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$stamp] [$Level] $Message"
    Write-Host $line
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Write-Stage {
    param(
        [int]$Number,
        [int]$Total,
        [string]$Title
    )

    $script:CurrentStage = $Title
    Write-Log ('=' * 74)
    Write-Log ("[ETAPA {0:00}/{1:00}] {2}" -f $Number, $Total, $Title)
    Write-Log ('=' * 74)
}

function ConvertTo-HtmlText {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    return [System.Security.SecurityElement]::Escape([string]$Value)
}

function Format-Bytes {
    param([long]$Bytes)

    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Format-Duration {
    param([TimeSpan]$Duration)
    return ('{0:00}:{1:00}:{2:00}' -f [math]::Floor($Duration.TotalHours), $Duration.Minutes, $Duration.Seconds)
}

function Get-FreeGB {
    $driveLetter = $BackupDrive.TrimEnd(':')
    $volume = Get-Volume -DriveLetter $driveLetter -ErrorAction Stop
    return [math]::Round(($volume.SizeRemaining / 1GB), 2)
}

function Get-SafeName {
    param([string]$Name)
    return ($Name -replace '[\\/:*?"<>|]', '_').Trim()
}

function Quote-Argument {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Get-TailText {
    param(
        [string]$Path,
        [int]$Lines = 5
    )

    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        return ((Get-Content -LiteralPath $Path -Tail $Lines -ErrorAction Stop) -join ' | ').Trim()
    }
    catch {
        return ''
    }
}

function Invoke-MonitoredProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DisplayName,

        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string]$ArgumentString,

        [Parameter(Mandatory = $true)]
        [TimeSpan]$Timeout,

        [Parameter(Mandatory = $true)]
        [string]$StdOutPath,

        [Parameter(Mandatory = $true)]
        [string]$StdErrPath
    )

    foreach ($path in @($StdOutPath, $StdErrPath)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }

    $process = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $ArgumentString `
        -PassThru `
        -WindowStyle Hidden `
        -RedirectStandardOutput $StdOutPath `
        -RedirectStandardError $StdErrPath

    Write-Log "$DisplayName iniciado. PID=$($process.Id) | Timeout=$(Format-Duration $Timeout)."

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastTail = ''
    $timedOut = $false
    $pollSeconds = 2
    $nextHeartbeatSeconds = [double]$HeartbeatSeconds

    # O processo e consultado a cada 2 segundos. O heartbeat continua no intervalo
    # configurado, mas processos rapidos nao ficam artificialmente presos por 30 s.
    while ($true) {
        try {
            $process.Refresh()
            if ($process.HasExited) { break }
        }
        catch {
            break
        }

        if ($watch.Elapsed -ge $Timeout) {
            $timedOut = $true
            Write-Log "$DisplayName excedeu o timeout de $(Format-Duration $Timeout). Encerrando PID $($process.Id)." 'ERROR'
            try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch { }
            break
        }

        if ($watch.Elapsed.TotalSeconds -ge $nextHeartbeatSeconds) {
            $cpuSeconds = $null
            $workingSet = $null
            try {
                $processInfo = Get-Process -Id $process.Id -ErrorAction Stop
                $cpuSeconds = [math]::Round($processInfo.CPU, 1)
                $workingSet = Format-Bytes $processInfo.WorkingSet64
            }
            catch {
                # O processo pode ter terminado entre as consultas.
            }

            $parts = New-Object System.Collections.Generic.List[string]
            $parts.Add("$DisplayName")
            $parts.Add("decorrido=$(Format-Duration $watch.Elapsed)")
            $parts.Add("PID=$($process.Id)")
            if ($null -ne $cpuSeconds) { $parts.Add("CPU=${cpuSeconds}s") }
            if ($null -ne $workingSet) { $parts.Add("RAM=$workingSet") }
            Write-Log ($parts -join ' | ') 'WAIT'

            $tail = Get-TailText -Path $StdOutPath -Lines 3
            if (-not [string]::IsNullOrWhiteSpace($tail) -and $tail -ne $lastTail) {
                Write-Log "$DisplayName saida: $tail" 'INFO'
                $lastTail = $tail
            }

            $nextHeartbeatSeconds += [double]$HeartbeatSeconds
        }

        Start-Sleep -Seconds $pollSeconds
    }

    # WaitForExit() sem limite pode aguardar varios minutos pelos handles dos arquivos
    # redirecionados, mesmo depois de powershell.exe ja ter encerrado. Usamos apenas uma
    # espera curta e limitada para consolidar o objeto Process.
    try {
        $process.Refresh()
        if (-not $process.HasExited) {
            [void]$process.WaitForExit(5000)
        }
        else {
            [void]$process.WaitForExit(1000)
        }
        $process.Refresh()
    }
    catch { }

    $watch.Stop()

    $exit = $null
    try { $exit = $process.ExitCode } catch { }

    $stdout = Get-TailText -Path $StdOutPath -Lines 30
    $stderr = Get-TailText -Path $StdErrPath -Lines 30

    Write-Log "$DisplayName finalizado. Duracao=$(Format-Duration $watch.Elapsed) | ExitCode=$(if ($null -eq $exit) { 'indisponivel' } else { $exit })." 'INFO'

    return [pscustomobject]@{
        DisplayName = $DisplayName
        ProcessId = $process.Id
        ExitCode = $exit
        TimedOut = $timedOut
        Duration = $watch.Elapsed
        StdOutPath = $StdOutPath
        StdErrPath = $StdErrPath
        StdOutTail = $stdout
        StdErrTail = $stderr
    }
}

function Read-JsonResultFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [ValidateRange(1, 120)]
        [int]$WaitSeconds = 15
    )

    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        if (Test-Path -LiteralPath $Path) {
            try {
                $item = Get-Item -LiteralPath $Path -ErrorAction Stop
                if ($item.Length -gt 0) {
                    return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
                }
            }
            catch {
                # O worker pode estar terminando a gravacao; tentamos novamente.
            }
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    return $null
}

function Get-DirectorySize {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return 0L }
    $measure = Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum
    if ($null -eq $measure.Sum) { return 0L }
    return [long]$measure.Sum
}

function Get-SevenZipArchiveStructure {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ListText
    )

    # O primeiro bloco da saida -slt descreve o proprio arquivo 7z. As entradas
    # compactadas aparecem somente depois da linha formada por hifens.
    $separator = [regex]::Match($ListText, '(?m)^-{10,}\s*$')
    if (-not $separator.Success) {
        throw 'A listagem tecnica do 7-Zip nao contem o separador das entradas.'
    }

    $entryText = $ListText.Substring($separator.Index + $separator.Length).Trim()
    if ([string]::IsNullOrWhiteSpace($entryText)) {
        throw 'A listagem tecnica do 7-Zip nao contem entradas.'
    }

    $files = @()
    $folders = @()
    $blocks = [regex]::Split($entryText, '(?:\r?\n){2,}')

    foreach ($block in $blocks) {
        $pathMatch = [regex]::Match($block, '(?m)^Path = (.+?)\s*$')
        if (-not $pathMatch.Success) { continue }

        $entryPath = $pathMatch.Groups[1].Value.Trim()
        $sizeMatch = [regex]::Match($block, '(?m)^Size = (\d+)\s*$')
        $attributesMatch = [regex]::Match($block, '(?m)^Attributes = (.*?)\s*$')

        [long]$entrySize = 0
        if ($sizeMatch.Success) {
            $entrySize = [long]$sizeMatch.Groups[1].Value
        }

        $attributes = if ($attributesMatch.Success) { $attributesMatch.Groups[1].Value.Trim() } else { '' }
        $isDirectory = $attributes -match '(?i)(^|\s)D(\s|$)'

        $entry = [pscustomobject]@{
            Path = $entryPath
            Size = $entrySize
            Attributes = $attributes
        }

        if ($isDirectory) {
            $folders += $entry
        }
        else {
            $files += $entry
        }
    }

    if ($files.Count -eq 0) {
        throw 'A listagem tecnica do 7-Zip nao apresentou nenhum arquivo.'
    }

    [long]$totalBytes = 0
    foreach ($file in $files) {
        $totalBytes += [long]$file.Size
    }

    $virtualDisks = @($files | Where-Object { $_.Path -match '(?i)\.(?:a?vhdx?)$' })
    $vmcxFiles = @($files | Where-Object { $_.Path -match '(?i)\.vmcx$' })

    return [pscustomobject]@{
        FileCount = $files.Count
        FolderCount = $folders.Count
        TotalUncompressedBytes = $totalBytes
        VirtualDiskCount = $virtualDisks.Count
        VmcxCount = $vmcxFiles.Count
        Files = $files
    }
}

function Acquire-Lock {
    if (Test-Path -LiteralPath $LockPath) {
        $existing = $null
        try {
            $existing = Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json
        }
        catch {
            $Warnings.Add("Lock anterior ilegivel removido: $LockPath")
        }

        if ($null -ne $existing -and $existing.Pid) {
            $active = Get-Process -Id ([int]$existing.Pid) -ErrorAction SilentlyContinue
            if ($null -ne $active) {
                throw "Ja existe uma execucao ativa. PID=$($existing.Pid), RunId=$($existing.RunId), inicio=$($existing.StartTime)."
            }
        }

        Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
    }

    [ordered]@{
        Pid = $PID
        RunId = $RunId
        StartTime = $RunStart.ToString('o')
        Script = $ScriptPath
    } | ConvertTo-Json | Set-Content -LiteralPath $LockPath -Encoding UTF8

    $script:LockAcquired = $true
    Write-Log "Lock criado: $LockPath | PID=$PID."
}

function Remove-Lock {
    if ($script:LockAcquired -and (Test-Path -LiteralPath $LockPath)) {
        Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
        Write-Log "Lock removido: $LockPath."
    }
}

function Get-SelectedVMs {
    $all = @(Get-VM -ErrorAction Stop | Sort-Object Name)
    if ($all.Count -eq 0) { throw 'Nenhuma VM encontrada no host.' }

    if ($null -eq $VMName -or $VMName.Count -eq 0) {
        return $all
    }

    $selected = New-Object System.Collections.Generic.List[object]
    foreach ($name in $VMName) {
        $vm = $all | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
        if ($null -eq $vm) { throw "VM solicitada nao encontrada: $name" }
        $selected.Add($vm)
    }
    return @($selected | Sort-Object Name)
}

function Get-VMSourceSize {
    param([string]$Name)

    $paths = @(Get-VMHardDiskDrive -VMName $Name -ErrorAction SilentlyContinue |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.Path) } |
        Select-Object -ExpandProperty Path -Unique)

    $total = 0L
    foreach ($path in $paths) {
        $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if ($null -ne $item) { $total += [long]$item.Length }
    }
    return $total
}

function Write-HostInventory {
    param([string]$Path)

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $hostInfo = Get-VMHost -ErrorAction SilentlyContinue
    $hyperVModule = Get-Module Hyper-V -ListAvailable -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    $switches = @(Get-VMSwitch -ErrorAction SilentlyContinue | ForEach-Object {
        [ordered]@{
            Name = $_.Name
            Id = [string]$_.Id
            SwitchType = [string]$_.SwitchType
            NetAdapterInterfaceDescription = $_.NetAdapterInterfaceDescription
        }
    })

    $vmInventory = @($SelectedVMs | ForEach-Object {
        $vm = $_
        [ordered]@{
            Name = $vm.Name
            VMId = [string]$vm.VMId
            State = [string]$vm.State
            Generation = $vm.Generation
            Version = [string]$vm.Version
            ConfigurationLocation = $vm.ConfigurationLocation
            CheckpointFileLocation = $vm.CheckpointFileLocation
            SmartPagingFilePath = $vm.SmartPagingFilePath
            ProcessorCount = $vm.ProcessorCount
            MemoryStartupBytes = $vm.MemoryStartup
            Disks = @(Get-VMHardDiskDrive -VMName $vm.Name -ErrorAction SilentlyContinue | ForEach-Object {
                [ordered]@{
                    ControllerType = [string]$_.ControllerType
                    ControllerNumber = $_.ControllerNumber
                    ControllerLocation = $_.ControllerLocation
                    Path = $_.Path
                }
            })
            NetworkAdapters = @(Get-VMNetworkAdapter -VMName $vm.Name -ErrorAction SilentlyContinue | ForEach-Object {
                $adapter = $_
                $vlanSetting = $null
                try {
                    $vlanSetting = [string](Get-VMNetworkAdapterVlan -VMNetworkAdapter $adapter -ErrorAction Stop)
                }
                catch {
                    $vlanSetting = $null
                }
                [ordered]@{
                    Name = $adapter.Name
                    SwitchName = $adapter.SwitchName
                    MacAddress = $adapter.MacAddress
                    DynamicMacAddressEnabled = $adapter.DynamicMacAddressEnabled
                    VlanSetting = $vlanSetting
                }
            })
            Checkpoints = @(Get-VMSnapshot -VMName $vm.Name -ErrorAction SilentlyContinue | ForEach-Object {
                [ordered]@{
                    Name = $_.Name
                    Id = [string]$_.Id
                    SnapshotType = [string]$_.SnapshotType
                    CreationTime = $_.CreationTime
                }
            })
        }
    })

    [ordered]@{
        GeneratedAt = (Get-Date).ToString('o')
        Host = [ordered]@{
            ComputerName = $ComputerName
            OperatingSystem = if ($null -ne $os) { $os.Caption } else { $null }
            OSVersion = if ($null -ne $os) { $os.Version } else { $null }
            # Get-VMHost no Windows Server 2022/PowerShell 5.1 nao expoe a propriedade Version.
            # Registramos a versao do modulo Hyper-V, que existe de forma consistente.
            HyperVModuleVersion = if ($null -ne $hyperVModule) { [string]$hyperVModule.Version } else { $null }
            VirtualMachinePath = if ($null -ne $hostInfo) { $hostInfo.VirtualMachinePath } else { $null }
            VirtualHardDiskPath = if ($null -ne $hostInfo) { $hostInfo.VirtualHardDiskPath } else { $null }
        }
        VMSwitches = $switches
        VMs = $vmInventory
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Write-RestorePointMarker {
    param(
        [string]$Path,
        [string]$Status
    )

    # PowerShell 5.1 pode falhar ao converter diretamente List[T] com @(...).
    # Materializamos explicitamente em array para manter compatibilidade.
    $resultArray = $VMResults.ToArray()

    $marker = [ordered]@{
        RunId = $RunId
        Status = $Status
        ComputerName = $ComputerName
        CreatedAt = $RunStart.ToString('o')
        FinishedAt = (Get-Date).ToString('o')
        RestorePointName = $RestorePointName
        VMCount = $SelectedVMs.Count
        SuccessfulVMCount = @($resultArray | Where-Object { $_.Success }).Count
        FailedVMCount = @($resultArray | Where-Object { -not $_.Success }).Count
        ScriptVersion = $ScriptVersion
        Results = $resultArray
    }

    $marker | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-Retention {
    Write-Log "Aplicando retencao: manter $KeepRestorePoints pontos completos."

    $complete = New-Object System.Collections.Generic.List[object]
    $directories = @(Get-ChildItem -LiteralPath $RepositoryRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('_STAGING', '_FAILED') })

    foreach ($directory in $directories) {
        $markerPath = Join-Path $directory.FullName 'COMPLETE.marker.json'
        if (-not (Test-Path -LiteralPath $markerPath)) { continue }

        try {
            $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
            if ($marker.Status -eq 'COMPLETE') {
                $complete.Add([pscustomobject]@{
                    Directory = $directory
                    CreatedAt = [datetime]$marker.CreatedAt
                })
            }
        }
        catch {
            $Warnings.Add("Marcador invalido ignorado: $markerPath")
        }
    }

    $ordered = @($complete | Sort-Object CreatedAt -Descending)
    $toDelete = @($ordered | Select-Object -Skip $KeepRestorePoints)

    foreach ($item in $toDelete) {
        Write-Log "Retencao: removendo ponto antigo completo: $($item.Directory.FullName)." 'WARNING'
        Remove-Item -LiteralPath $item.Directory.FullName -Recurse -Force -ErrorAction Stop
        $DeletedRestorePoints.Add($item.Directory.FullName)
    }

    Write-Log "Retencao concluida. Pontos completos encontrados=$($ordered.Count), removidos=$($toDelete.Count)." 'SUCCESS'
}

function Remove-ExpiredFailedPoints {
    if ($FailedRetentionDays -le 0 -or -not (Test-Path -LiteralPath $FailedRoot)) { return }

    $limit = (Get-Date).AddDays(-$FailedRetentionDays)
    $expired = @(Get-ChildItem -LiteralPath $FailedRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $limit })

    foreach ($item in $expired) {
        try {
            Write-Log "Removendo tentativa falha expirada: $($item.FullName)." 'WARNING'
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
        }
        catch {
            $Warnings.Add("Nao foi possivel remover tentativa falha: $($item.FullName): $($_.Exception.Message)")
        }
    }
}

function New-HtmlReport {
    param([System.Collections.IDictionary]$Summary)

    $statusClass = switch ($Summary.Status) {
        'SUCCESS' { 'ok' }
        'PLAN' { 'plan' }
        default { 'fail' }
    }

    $rows = New-Object System.Text.StringBuilder
    foreach ($item in $VMResults) {
        $state = if ($item.Success) { '<span class="okText">SUCESSO</span>' } else { '<span class="failText">FALHA</span>' }
        [void]$rows.AppendLine('<tr>')
        [void]$rows.AppendLine("<td>$(ConvertTo-HtmlText $item.Name)</td>")
        [void]$rows.AppendLine("<td>$(ConvertTo-HtmlText $item.VMId)</td>")
        [void]$rows.AppendLine("<td>$state</td>")
        [void]$rows.AppendLine("<td>$(ConvertTo-HtmlText $item.Attempts)</td>")
        [void]$rows.AppendLine("<td>$(ConvertTo-HtmlText $item.ExportDuration)</td>")
        [void]$rows.AppendLine("<td>$(ConvertTo-HtmlText $item.CompressionDuration)</td>")
        [void]$rows.AppendLine("<td>$(ConvertTo-HtmlText $item.IntegrityDuration)</td>")
        [void]$rows.AppendLine("<td>$(ConvertTo-HtmlText $item.ArchiveStructure)</td>")
        [void]$rows.AppendLine("<td>$(ConvertTo-HtmlText $item.ExportSize)</td>")
        [void]$rows.AppendLine("<td>$(ConvertTo-HtmlText $item.ArchiveSize)</td>")
        [void]$rows.AppendLine("<td>$(ConvertTo-HtmlText $item.CompressionRatio)</td>")
        [void]$rows.AppendLine("<td class='small'>$(ConvertTo-HtmlText $item.Error)</td>")
        [void]$rows.AppendLine('</tr>')
    }

    $warningHtml = if ($Warnings.Count -gt 0) {
        '<h2>Avisos</h2><ul>' + (($Warnings | ForEach-Object { '<li>' + (ConvertTo-HtmlText $_) + '</li>' }) -join '') + '</ul>'
    } else { '' }

    $errorHtml = if (-not [string]::IsNullOrWhiteSpace($GlobalError)) {
        '<h2>Erro geral</h2><pre>' + (ConvertTo-HtmlText $GlobalError) + '</pre>'
    } else { '' }

    return @"
<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<title>Backup Hyper-V por exportacao - $ComputerName</title>
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #222; }
h1, h2 { margin-bottom: 8px; }
.badge { display: inline-block; padding: 7px 12px; border-radius: 6px; font-weight: 700; }
.ok { background: #dff6dd; color: #116b18; }
.plan { background: #e8f1ff; color: #164f9c; }
.fail { background: #ffe3e3; color: #9a1111; }
.okText { color: #116b18; font-weight: 700; }
.failText { color: #9a1111; font-weight: 700; }
table { border-collapse: collapse; width: 100%; margin: 12px 0 24px; }
th, td { border: 1px solid #ccc; text-align: left; padding: 7px; vertical-align: top; }
th { background: #f2f2f2; }
.small { font-size: 12px; }
pre { white-space: pre-wrap; background: #f7f7f7; padding: 12px; border: 1px solid #ddd; }
</style>
</head>
<body>
<h1>Backup Hyper-V por exportacao e 7-Zip</h1>
<p><span class="badge $statusClass">$(ConvertTo-HtmlText $Summary.Status)</span></p>
<h2>Resumo</h2>
<table>
<tr><th>Servidor</th><td>$(ConvertTo-HtmlText $ComputerName)</td></tr>
<tr><th>RunId</th><td>$(ConvertTo-HtmlText $RunId)</td></tr>
<tr><th>Modo</th><td>$(ConvertTo-HtmlText $Mode)</td></tr>
<tr><th>Inicio</th><td>$(ConvertTo-HtmlText $Summary.StartTime)</td></tr>
<tr><th>Fim</th><td>$(ConvertTo-HtmlText $Summary.EndTime)</td></tr>
<tr><th>Duracao</th><td>$(ConvertTo-HtmlText $Summary.Duration)</td></tr>
<tr><th>Destino</th><td>$(ConvertTo-HtmlText $RepositoryRoot)</td></tr>
<tr><th>Ponto publicado</th><td>$(ConvertTo-HtmlText $Summary.RestorePointPath)</td></tr>
<tr><th>VMs</th><td>$(ConvertTo-HtmlText $Summary.VMCount)</td></tr>
<tr><th>Sucessos</th><td>$(ConvertTo-HtmlText $Summary.SuccessCount)</td></tr>
<tr><th>Falhas</th><td>$(ConvertTo-HtmlText $Summary.FailureCount)</td></tr>
<tr><th>Livre antes</th><td>$(ConvertTo-HtmlText $Summary.InitialFreeGB) GB</td></tr>
<tr><th>Livre depois</th><td>$(ConvertTo-HtmlText $Summary.FinalFreeGB) GB</td></tr>
<tr><th>Retencao</th><td>$(ConvertTo-HtmlText $KeepRestorePoints) pontos completos</td></tr>
<tr><th>Pontos removidos</th><td>$(ConvertTo-HtmlText $DeletedRestorePoints.Count)</td></tr>
</table>
<h2>Resultado por VM</h2>
<table>
<tr><th>VM</th><th>VMId</th><th>Status</th><th>Tentativas</th><th>Exportacao</th><th>Compactacao</th><th>Teste 7z</th><th>Estrutura 7z</th><th>Exportado</th><th>Arquivo</th><th>Reducao</th><th>Erro</th></tr>
$($rows.ToString())
</table>
$warningHtml
$errorHtml
<p class="small">Log: $(ConvertTo-HtmlText $LogPath)</p>
<p class="small">JSON: $(ConvertTo-HtmlText $JsonPath)</p>
</body>
</html>
"@
}

function Send-ReportEmail {
    param(
        [string]$Subject,
        [string]$HtmlBody
    )

    if ($SkipEmail) {
        Write-Log 'Envio de e-mail desativado por -SkipEmail.'
        return
    }

    if ($MailTo.Count -eq 0) {
        $Warnings.Add('Nenhum destinatario configurado; e-mail nao enviado.')
        return
    }

    $message = New-Object System.Net.Mail.MailMessage
    $smtp = New-Object System.Net.Mail.SmtpClient($SmtpServer, $SmtpPort)
    $attachments = New-Object System.Collections.ArrayList

    try {
        $message.From = New-Object System.Net.Mail.MailAddress($MailFrom)
        foreach ($recipient in $MailTo) {
            if (-not [string]::IsNullOrWhiteSpace($recipient)) {
                [void]$message.To.Add($recipient)
            }
        }
        $message.Subject = $Subject
        $message.SubjectEncoding = [System.Text.Encoding]::UTF8
        $message.Body = $HtmlBody
        $message.BodyEncoding = [System.Text.Encoding]::UTF8
        $message.IsBodyHtml = $true

        foreach ($path in @($LogPath, $JsonPath, $HtmlPath)) {
            if (Test-Path -LiteralPath $path) {
                $attachment = New-Object System.Net.Mail.Attachment($path)
                [void]$attachments.Add($attachment)
                [void]$message.Attachments.Add($attachment)
            }
        }

        $smtp.Send($message)
        $script:MailSent = $true
        Write-Log "Relatorio enviado por e-mail para: $($MailTo -join ', ')." 'SUCCESS'
    }
    catch {
        $script:MailError = $_.Exception.Message
        Write-Log "Falha ao enviar e-mail: $($script:MailError)" 'WARNING'
    }
    finally {
        foreach ($attachment in $attachments) { $attachment.Dispose() }
        $message.Dispose()
        $smtp.Dispose()
    }
}

Write-Log ('=' * 74)
Write-Log "Inicio do Invoke-VMExportBackup.ps1 v$ScriptVersion."
Write-Log "RunId: $RunId"
Write-Log "Modo: $Mode"
Write-Log "Repositorio: $RepositoryRoot"
Write-Log ('=' * 74)

try {
    Acquire-Lock

    Write-Stage -Number 1 -Total 9 -Title 'Validar host, destino e ferramentas'

    Import-Module Hyper-V -ErrorAction Stop

    if (-not (Test-Path -LiteralPath $SevenZipPath -PathType Leaf)) {
        throw "7-Zip nao encontrado: $SevenZipPath"
    }
    if (-not (Test-Path -LiteralPath $WorkerPath -PathType Leaf)) {
        throw "Worker de exportacao nao encontrado: $WorkerPath"
    }
    if (-not $SkipHash -and -not (Test-Path -LiteralPath $HashWorkerPath -PathType Leaf)) {
        throw "Worker de hash nao encontrado: $HashWorkerPath"
    }

    $volume = Get-Volume -DriveLetter $BackupDrive.TrimEnd(':') -ErrorAction Stop
    if (-not [string]::IsNullOrWhiteSpace($ExpectedVolumeLabel) -and $volume.FileSystemLabel -ne $ExpectedVolumeLabel) {
        throw "Rotulo incorreto em $BackupDrive. Esperado='$ExpectedVolumeLabel', encontrado='$($volume.FileSystemLabel)'."
    }
    if ($volume.HealthStatus -ne 'Healthy') {
        throw "Volume $BackupDrive nao esta saudavel. HealthStatus=$($volume.HealthStatus)."
    }

    $InitialFreeGB = Get-FreeGB
    Write-Log "Destino: $BackupDrive | Rotulo=$($volume.FileSystemLabel) | Sistema=$($volume.FileSystem) | Saude=$($volume.HealthStatus) | Livre=${InitialFreeGB}GB."

    if ($Execute -and $InitialFreeGB -lt $MinFreeGB) {
        throw "Espaco livre insuficiente. Livre=${InitialFreeGB}GB, minimo configurado=${MinFreeGB}GB."
    }

    Write-Stage -Number 2 -Total 9 -Title 'Selecionar VMs e registrar inventario'

    $SelectedVMs = @(Get-SelectedVMs)
    Write-Log "VMs selecionadas: $($SelectedVMs.Count)."

    foreach ($vm in $SelectedVMs) {
        $sourceBytes = Get-VMSourceSize -Name $vm.Name
        Write-Log "VM=$($vm.Name) | GUID=$($vm.VMId) | Estado=$($vm.State) | VHDX atuais=$(Format-Bytes $sourceBytes)."
    }

    if (-not $Execute) {
        $OverallStatus = 'PLAN'
        $ExitCode = 0
        Write-Log 'Plano validado. Nenhuma exportacao ou exclusao foi executada.' 'SUCCESS'
    }
    else {
        foreach ($dir in @($RepositoryRoot, $StagingRoot, $FailedRoot)) {
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
        }

        Remove-ExpiredFailedPoints

        if (Test-Path -LiteralPath $StagingPoint) {
            throw "Diretorio de staging ja existe: $StagingPoint"
        }

        $workingRoot = Join-Path $StagingPoint 'Working'
        $archivesRoot = Join-Path $StagingPoint 'Archives'
        $metadataRoot = Join-Path $StagingPoint 'Metadata'
        foreach ($dir in @($StagingPoint, $workingRoot, $archivesRoot, $metadataRoot)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        Write-HostInventory -Path (Join-Path $metadataRoot 'HostInventory.json')
        Copy-Item -LiteralPath $LogPath -Destination (Join-Path $metadataRoot 'Initial.log') -Force -ErrorAction SilentlyContinue

        Write-Stage -Number 3 -Total 9 -Title 'Exportar, compactar e validar cada VM'

        $vmIndex = 0
        foreach ($vm in $SelectedVMs) {
            $vmIndex++
            $safeName = Get-SafeName -Name $vm.Name
            $vmWorkPath = Join-Path $workingRoot $safeName
            $archivePartial = Join-Path $archivesRoot "$safeName.partial.7z"
            $archiveFinal = Join-Path $archivesRoot "$safeName.7z"
            $workerResultPath = Join-Path $metadataRoot "$safeName-export-result.json"
            $hashResultPath = Join-Path $metadataRoot "$safeName-hash-result.json"
            $vmStart = Get-Date
            $vmSucceeded = $false
            $lastError = $null
            $attemptUsed = 0
            $exportDuration = [timespan]::Zero
            $compressionDuration = [timespan]::Zero
            $integrityDuration = [timespan]::Zero
            $structureDuration = [timespan]::Zero
            $hashDuration = [timespan]::Zero
            $exportBytes = 0L
            $archiveBytes = 0L
            $archiveListedBytes = 0L
            $archiveFileCount = 0
            $archiveFolderCount = 0
            $virtualDiskCount = 0
            $vmcxCount = 0
            $sha256 = $null

            Write-Log ('-' * 74)
            Write-Log "[VM $vmIndex/$($SelectedVMs.Count)] $($vm.Name) | GUID=$($vm.VMId) | Estado=$($vm.State)."

            for ($attempt = 1; $attempt -le ($RetryCount + 1); $attempt++) {
                $attemptUsed = $attempt
                try {
                    if ((Get-FreeGB) -lt $MinFreeGB) {
                        throw "Espaco livre abaixo do minimo antes da VM $($vm.Name)."
                    }

                    foreach ($path in @($vmWorkPath, $archivePartial, $archiveFinal, $workerResultPath, $hashResultPath)) {
                        if (Test-Path -LiteralPath $path) {
                            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                        }
                    }
                    New-Item -ItemType Directory -Path $vmWorkPath -Force | Out-Null

                    Write-Log "[$($vm.Name)] Tentativa $attempt/$($RetryCount + 1): iniciando exportacao consistente."
                    $exportOut = Join-Path $metadataRoot "$safeName-export-attempt$attempt.stdout.log"
                    $exportErr = Join-Path $metadataRoot "$safeName-export-attempt$attempt.stderr.log"
                    $exportArgs = @(
                        '-NoProfile',
                        '-ExecutionPolicy Bypass',
                        '-File', (Quote-Argument $WorkerPath),
                        '-VMName', (Quote-Argument $vm.Name),
                        '-ExportPath', (Quote-Argument $vmWorkPath),
                        '-ResultPath', (Quote-Argument $workerResultPath)
                    ) -join ' '

                    $exportProcess = Invoke-MonitoredProcess `
                        -DisplayName "Export-VM $($vm.Name)" `
                        -FilePath 'powershell.exe' `
                        -ArgumentString $exportArgs `
                        -Timeout ([timespan]::FromHours($ExportTimeoutHours)) `
                        -StdOutPath $exportOut `
                        -StdErrPath $exportErr

                    $exportDuration = $exportProcess.Duration
                    if ($exportProcess.TimedOut) { throw "Exportacao excedeu $ExportTimeoutHours hora(s)." }

                    # Para workers PowerShell, o JSON e a fonte de verdade. No Windows
                    # PowerShell 5.1, ExitCode pode ficar indisponivel quando ha redirecionamento,
                    # mesmo depois de o worker gravar Success=true e concluir a exportacao.
                    $workerResult = Read-JsonResultFile -Path $workerResultPath -WaitSeconds 15
                    if ($null -eq $workerResult) {
                        $detail = if ($exportProcess.StdErrTail) { $exportProcess.StdErrTail } else { $exportProcess.StdOutTail }
                        throw "Worker terminou sem resultado JSON valido. ExitCode=$($exportProcess.ExitCode). $detail"
                    }
                    if (-not $workerResult.Success) {
                        throw "Exportacao reportou falha: $($workerResult.Error)"
                    }
                    if ($null -eq $exportProcess.ExitCode) {
                        Write-Log "[$($vm.Name)] ExitCode do worker indisponivel; sucesso confirmado pelo JSON e pelos arquivos exportados." 'WARNING'
                    }
                    elseif ($exportProcess.ExitCode -ne 0) {
                        Write-Log "[$($vm.Name)] Worker retornou ExitCode=$($exportProcess.ExitCode), mas o JSON reportou sucesso. Validando arquivos antes de continuar." 'WARNING'
                    }

                    $exportBytes = Get-DirectorySize -Path $vmWorkPath
                    if ($exportBytes -lt 1MB) {
                        throw "Exportacao invalida ou vazia: $(Format-Bytes $exportBytes)."
                    }
                    Write-Log "[$($vm.Name)] Exportacao concluida: $(Format-Bytes $exportBytes) em $(Format-Duration $exportDuration)." 'SUCCESS'

                    Write-Log "[$($vm.Name)] Iniciando compactacao 7-Zip nivel $CompressionLevel."
                    $compressOut = Join-Path $metadataRoot "$safeName-7zip.stdout.log"
                    $compressErr = Join-Path $metadataRoot "$safeName-7zip.stderr.log"
                    $sourcePattern = Join-Path $vmWorkPath '*'
                    $compressArgs = @(
                        'a',
                        '-t7z',
                        "-mx=$CompressionLevel",
                        '-mmt=8',
                        '-ms=on',
                        '-bd',
                        '-bb1',
                        '-bso1',
                        '-bse1',
                        '--',
                        (Quote-Argument $archivePartial),
                        (Quote-Argument $sourcePattern)
                    ) -join ' '

                    $compressProcess = Invoke-MonitoredProcess `
                        -DisplayName "7-Zip compactar $($vm.Name)" `
                        -FilePath $SevenZipPath `
                        -ArgumentString $compressArgs `
                        -Timeout ([timespan]::FromHours($CompressionTimeoutHours)) `
                        -StdOutPath $compressOut `
                        -StdErrPath $compressErr

                    $compressionDuration = $compressProcess.Duration
                    if ($compressProcess.TimedOut) { throw "Compactacao excedeu $CompressionTimeoutHours hora(s)." }
                    $compressOutput = "$($compressProcess.StdOutTail) $($compressProcess.StdErrTail)"
                    $compressTextSuccess = $compressOutput -match '(?i)Everything is Ok'
                    if (($null -ne $compressProcess.ExitCode -and $compressProcess.ExitCode -gt 1) -or
                        ($null -eq $compressProcess.ExitCode -and -not $compressTextSuccess)) {
                        $detail = if ($compressProcess.StdErrTail) { $compressProcess.StdErrTail } else { $compressProcess.StdOutTail }
                        throw "7-Zip falhou ao compactar. ExitCode=$($compressProcess.ExitCode). $detail"
                    }
                    if ($null -eq $compressProcess.ExitCode -and $compressTextSuccess) {
                        Write-Log "[$($vm.Name)] ExitCode do 7-Zip indisponivel; conclusao confirmada pela saida 'Everything is Ok'." 'WARNING'
                    }
                    if (-not (Test-Path -LiteralPath $archivePartial)) {
                        throw "Arquivo parcial nao foi criado: $archivePartial"
                    }

                    $archiveBytes = (Get-Item -LiteralPath $archivePartial).Length
                    if ($archiveBytes -le 0) {
                        throw 'O arquivo compactado foi criado com tamanho zero.'
                    }
                    Write-Log "[$($vm.Name)] Compactacao concluida: $(Format-Bytes $archiveBytes) em $(Format-Duration $compressionDuration)." 'SUCCESS'

                    Write-Log "[$($vm.Name)] Testando integralmente o arquivo 7z."
                    $testOut = Join-Path $metadataRoot "$safeName-7zip-test.stdout.log"
                    $testErr = Join-Path $metadataRoot "$safeName-7zip-test.stderr.log"
                    $testArgs = @(
                        't',
                        '-bd',
                        '-bb1',
                        '-bso1',
                        '-bse1',
                        '--',
                        (Quote-Argument $archivePartial)
                    ) -join ' '

                    $testProcess = Invoke-MonitoredProcess `
                        -DisplayName "7-Zip testar $($vm.Name)" `
                        -FilePath $SevenZipPath `
                        -ArgumentString $testArgs `
                        -Timeout ([timespan]::FromHours($IntegrityTimeoutHours)) `
                        -StdOutPath $testOut `
                        -StdErrPath $testErr

                    $integrityDuration = $testProcess.Duration
                    if ($testProcess.TimedOut) { throw "Teste do arquivo excedeu $IntegrityTimeoutHours hora(s)." }
                    $testOutput = "$($testProcess.StdOutTail) $($testProcess.StdErrTail)"
                    $testTextSuccess = $testOutput -match '(?i)Everything is Ok'
                    if (($null -ne $testProcess.ExitCode -and $testProcess.ExitCode -ne 0) -or
                        ($null -eq $testProcess.ExitCode -and -not $testTextSuccess)) {
                        $detail = if ($testProcess.StdErrTail) { $testProcess.StdErrTail } else { $testProcess.StdOutTail }
                        throw "Teste 7-Zip falhou. ExitCode=$($testProcess.ExitCode). $detail"
                    }
                    if ($null -eq $testProcess.ExitCode -and $testTextSuccess) {
                        Write-Log "[$($vm.Name)] ExitCode do teste 7-Zip indisponivel; integridade confirmada pela saida 'Everything is Ok'." 'WARNING'
                    }
                    Write-Log "[$($vm.Name)] Arquivo aprovado no teste integral do 7-Zip em $(Format-Duration $integrityDuration)." 'SUCCESS'

                    Write-Log "[$($vm.Name)] Validando estrutura e tamanho descompactado do arquivo 7z."
                    $listOut = Join-Path $metadataRoot "$safeName-7zip-list.stdout.log"
                    $listErr = Join-Path $metadataRoot "$safeName-7zip-list.stderr.log"
                    $listArgs = @(
                        'l',
                        '-slt',
                        '-bd',
                        '-bso1',
                        '-bse1',
                        '--',
                        (Quote-Argument $archivePartial)
                    ) -join ' '

                    $listProcess = Invoke-MonitoredProcess `
                        -DisplayName "7-Zip listar $($vm.Name)" `
                        -FilePath $SevenZipPath `
                        -ArgumentString $listArgs `
                        -Timeout ([timespan]::FromHours($IntegrityTimeoutHours)) `
                        -StdOutPath $listOut `
                        -StdErrPath $listErr

                    $structureDuration = $listProcess.Duration
                    if ($listProcess.TimedOut) {
                        throw "Listagem estrutural do arquivo excedeu $IntegrityTimeoutHours hora(s)."
                    }

                    $listText = ''
                    if (Test-Path -LiteralPath $listOut) {
                        $listText = Get-Content -LiteralPath $listOut -Raw -ErrorAction Stop
                    }
                    $listTypeConfirmed = $listText -match '(?im)^Type = 7z\s*$'
                    if (($null -ne $listProcess.ExitCode -and $listProcess.ExitCode -ne 0) -or
                        ($null -eq $listProcess.ExitCode -and -not $listTypeConfirmed)) {
                        $detail = if ($listProcess.StdErrTail) { $listProcess.StdErrTail } else { $listProcess.StdOutTail }
                        throw "Nao foi possivel listar a estrutura do arquivo 7z. ExitCode=$($listProcess.ExitCode). $detail"
                    }
                    if ($null -eq $listProcess.ExitCode -and $listTypeConfirmed) {
                        Write-Log "[$($vm.Name)] ExitCode da listagem 7-Zip indisponivel; formato confirmado pela saida tecnica." 'WARNING'
                    }

                    $archiveStructure = Get-SevenZipArchiveStructure -ListText $listText
                    $archiveListedBytes = [long]$archiveStructure.TotalUncompressedBytes
                    $archiveFileCount = [int]$archiveStructure.FileCount
                    $archiveFolderCount = [int]$archiveStructure.FolderCount
                    $virtualDiskCount = [int]$archiveStructure.VirtualDiskCount
                    $vmcxCount = [int]$archiveStructure.VmcxCount

                    if ($virtualDiskCount -lt 1) {
                        throw 'A estrutura do arquivo nao contem nenhum disco virtual VHD/VHDX/AVHD/AVHDX.'
                    }
                    if ($vmcxCount -lt 1) {
                        throw 'A estrutura do arquivo nao contem o arquivo de configuracao VMCX.'
                    }
                    if ($archiveListedBytes -ne $exportBytes) {
                        throw "O tamanho descompactado listado pelo 7-Zip difere da exportacao. Exportado=$(Format-Bytes $exportBytes); listado=$(Format-Bytes $archiveListedBytes)."
                    }

                    Write-Log "[$($vm.Name)] Estrutura aprovada: arquivos=$archiveFileCount | pastas=$archiveFolderCount | discos=$virtualDiskCount | VMCX=$vmcxCount | listado=$(Format-Bytes $archiveListedBytes), igual ao exportado." 'SUCCESS'

                    if (-not $SkipHash) {
                        Write-Log "[$($vm.Name)] Calculando SHA-256."
                        $hashOut = Join-Path $metadataRoot "$safeName-hash.stdout.log"
                        $hashErr = Join-Path $metadataRoot "$safeName-hash.stderr.log"
                        $hashArgs = @(
                            '-NoProfile',
                            '-ExecutionPolicy Bypass',
                            '-File', (Quote-Argument $HashWorkerPath),
                            '-FilePath', (Quote-Argument $archivePartial),
                            '-ResultPath', (Quote-Argument $hashResultPath)
                        ) -join ' '

                        $hashProcess = Invoke-MonitoredProcess `
                            -DisplayName "SHA-256 $($vm.Name)" `
                            -FilePath 'powershell.exe' `
                            -ArgumentString $hashArgs `
                            -Timeout ([timespan]::FromHours($IntegrityTimeoutHours)) `
                            -StdOutPath $hashOut `
                            -StdErrPath $hashErr

                        $hashDuration = $hashProcess.Duration
                        if ($hashProcess.TimedOut) { throw "Calculo SHA-256 excedeu $IntegrityTimeoutHours hora(s)." }
                        $hashResult = Read-JsonResultFile -Path $hashResultPath -WaitSeconds 15
                        if ($null -eq $hashResult) {
                            throw "Worker SHA-256 terminou sem resultado JSON valido. ExitCode=$($hashProcess.ExitCode). $($hashProcess.StdErrTail)"
                        }
                        if (-not $hashResult.Success) { throw "Falha SHA-256: $($hashResult.Error)" }
                        if ($null -eq $hashProcess.ExitCode) {
                            Write-Log "[$($vm.Name)] ExitCode do worker SHA-256 indisponivel; sucesso confirmado pelo JSON." 'WARNING'
                        }
                        elseif ($hashProcess.ExitCode -ne 0) {
                            Write-Log "[$($vm.Name)] Worker SHA-256 retornou ExitCode=$($hashProcess.ExitCode), mas o JSON reportou sucesso." 'WARNING'
                        }
                        $sha256 = $hashResult.Hash
                        Write-Log "[$($vm.Name)] SHA-256=$sha256" 'SUCCESS'
                    }

                    Move-Item -LiteralPath $archivePartial -Destination $archiveFinal -Force
                    Remove-Item -LiteralPath $vmWorkPath -Recurse -Force -ErrorAction Stop
                    Write-Log "[$($vm.Name)] Exportacao temporaria removida; arquivo final publicado no staging." 'SUCCESS'
                    $vmSucceeded = $true
                    break
                }
                catch {
                    $lastError = $_.Exception.Message
                    Write-Log "[$($vm.Name)] Tentativa $attempt falhou: $lastError" 'ERROR'
                    if ($attempt -le $RetryCount) {
                        Write-Log "[$($vm.Name)] Nova tentativa em 60 segundos." 'WARNING'
                        Start-Sleep -Seconds 60
                    }
                }
            }

            $ratio = $null
            if ($exportBytes -gt 0 -and $archiveBytes -gt 0) {
                $ratio = ('{0:N1}%' -f (100 - (($archiveBytes / [double]$exportBytes) * 100)))
            }

            $VMResults.Add([pscustomobject][ordered]@{
                Name = $vm.Name
                VMId = [string]$vm.VMId
                State = [string]$vm.State
                Success = $vmSucceeded
                Attempts = $attemptUsed
                ExportDuration = Format-Duration $exportDuration
                CompressionDuration = Format-Duration $compressionDuration
                IntegrityDuration = Format-Duration $integrityDuration
                StructureDuration = Format-Duration $structureDuration
                HashDuration = Format-Duration $hashDuration
                ExportBytes = $exportBytes
                ExportSize = Format-Bytes $exportBytes
                ArchiveBytes = $archiveBytes
                ArchiveSize = Format-Bytes $archiveBytes
                ArchiveListedBytes = $archiveListedBytes
                ArchiveListedSize = Format-Bytes $archiveListedBytes
                ArchiveFileCount = $archiveFileCount
                ArchiveFolderCount = $archiveFolderCount
                VirtualDiskCount = $virtualDiskCount
                VmcxCount = $vmcxCount
                ArchiveStructure = if ($vmSucceeded) { "$archiveFileCount arquivo(s) | $virtualDiskCount disco(s) | $vmcxCount VMCX | $(Format-Bytes $archiveListedBytes)" } else { $null }
                CompressionRatio = $ratio
                Archive = if ($vmSucceeded) { "Archives\\$safeName.7z" } else { $null }
                SHA256 = $sha256
                Error = if ($vmSucceeded) { $null } else { $lastError }
                StartedAt = $vmStart.ToString('o')
                FinishedAt = (Get-Date).ToString('o')
            })
        }

        Write-Stage -Number 4 -Total 9 -Title 'Avaliar o conjunto completo'

        $failureCount = @($VMResults | Where-Object { -not $_.Success }).Count
        if ($failureCount -gt 0) {
            $OverallStatus = 'PARTIAL_FAILED'
            Write-RestorePointMarker -Path (Join-Path $StagingPoint 'FAILED.marker.json') -Status 'PARTIAL_FAILED'
            $failedDestination = Join-Path $FailedRoot $RestorePointName
            if (Test-Path -LiteralPath $failedDestination) {
                Remove-Item -LiteralPath $failedDestination -Recurse -Force
            }
            Move-Item -LiteralPath $StagingPoint -Destination $failedDestination
            $FinalPoint = $failedDestination
            throw "$failureCount VM(s) falharam. O conjunto parcial foi preservado em $failedDestination e nao conta para retencao."
        }

        Write-Stage -Number 5 -Total 9 -Title 'Publicar ponto de restauracao atomico'

        Write-RestorePointMarker -Path (Join-Path $StagingPoint 'COMPLETE.marker.json') -Status 'COMPLETE'
        if (Test-Path -LiteralPath $FinalPoint) {
            throw "Destino final ja existe: $FinalPoint"
        }
        Move-Item -LiteralPath $StagingPoint -Destination $FinalPoint
        $RepositoryPublished = $true
        Write-Log "Ponto de restauracao publicado: $FinalPoint" 'SUCCESS'

        Write-Stage -Number 6 -Total 9 -Title 'Aplicar retencao somente apos sucesso'
        Invoke-Retention

        Write-Stage -Number 7 -Total 9 -Title 'Confirmar arquivos publicados'
        $finalArchives = @(Get-ChildItem -LiteralPath (Join-Path $FinalPoint 'Archives') -Filter '*.7z' -File -ErrorAction Stop)
        if ($finalArchives.Count -ne $SelectedVMs.Count) {
            throw "Quantidade de arquivos publicada difere da quantidade de VMs. Esperado=$($SelectedVMs.Count), encontrado=$($finalArchives.Count)."
        }
        Write-Log "Confirmacao final: $($finalArchives.Count) arquivos 7z presentes." 'SUCCESS'

        Write-Stage -Number 8 -Total 9 -Title 'Finalizar execucao'
        $OverallStatus = 'SUCCESS'
        $ExitCode = 0
    }
}
catch {
    $GlobalError = $_.Exception.Message
    Write-Log $GlobalError 'ERROR'
    if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
        Write-Log ("Pilha: " + ($_.ScriptStackTrace -replace "`r?`n", ' | ')) 'ERROR'
    }

    if ($OverallStatus -eq 'FAILED' -and $Execute -and (Test-Path -LiteralPath $StagingPoint)) {
        try {
            if (-not (Test-Path -LiteralPath $FailedRoot)) {
                New-Item -ItemType Directory -Path $FailedRoot -Force | Out-Null
            }
            Write-RestorePointMarker -Path (Join-Path $StagingPoint 'FAILED.marker.json') -Status 'FAILED'
            $failedDestination = Join-Path $FailedRoot $RestorePointName
            if (Test-Path -LiteralPath $failedDestination) {
                Remove-Item -LiteralPath $failedDestination -Recurse -Force
            }
            Move-Item -LiteralPath $StagingPoint -Destination $failedDestination
            $FinalPoint = $failedDestination
            Write-Log "Tentativa falha preservada em: $failedDestination" 'WARNING'
        }
        catch {
            $Warnings.Add("Falha ao preservar staging: $($_.Exception.Message)")
        }
    }

    $ExitCode = 1
}
finally {
    Write-Stage -Number 9 -Total 9 -Title 'Gerar relatorios e enviar e-mail'

    try { $FinalFreeGB = Get-FreeGB } catch { }
    $end = Get-Date
    $duration = $end - $RunStart

    # Evita o erro "Os tipos de argumento nao correspondem" do Windows PowerShell 5.1
    # ao inserir List[T] diretamente em arrays/hashtables.
    $vmResultArray = $VMResults.ToArray()
    $warningArray = $Warnings.ToArray()
    $deletedRestorePointArray = $DeletedRestorePoints.ToArray()
    $successCount = @($vmResultArray | Where-Object { $_.Success }).Count
    $failureCount = @($vmResultArray | Where-Object { -not $_.Success }).Count

    $summary = [ordered]@{
        RunId = $RunId
        ScriptVersion = $ScriptVersion
        ComputerName = $ComputerName
        Status = $OverallStatus
        Mode = $Mode
        StartTime = $RunStart.ToString('yyyy-MM-dd HH:mm:ss')
        EndTime = $end.ToString('yyyy-MM-dd HH:mm:ss')
        Duration = Format-Duration $duration
        BackupDrive = $BackupDrive
        ExpectedVolumeLabel = $ExpectedVolumeLabel
        RepositoryRoot = $RepositoryRoot
        RestorePointPath = if ($Execute) { $FinalPoint } else { $null }
        RepositoryPublished = $RepositoryPublished
        VMCount = $SelectedVMs.Count
        SuccessCount = $successCount
        FailureCount = $failureCount
        InitialFreeGB = $InitialFreeGB
        FinalFreeGB = $FinalFreeGB
        KeepRestorePoints = $KeepRestorePoints
        DeletedRestorePoints = $deletedRestorePointArray
        MailSent = $MailSent
        MailError = $MailError
        Warnings = $warningArray
        Error = $GlobalError
        VMResults = $vmResultArray
        LogPath = $LogPath
        JsonPath = $JsonPath
        HtmlPath = $HtmlPath
    }

    try {
        $summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $JsonPath -Encoding UTF8
        $html = New-HtmlReport -Summary $summary
        $html | Set-Content -LiteralPath $HtmlPath -Encoding UTF8
        Write-Log "Resultado JSON: $JsonPath"
        Write-Log "Relatorio HTML: $HtmlPath"

        $subjectPrefix = switch ($OverallStatus) {
            'SUCCESS' { '[SUCESSO]' }
            'PLAN' { '[PLANO]' }
            default { '[FALHA]' }
        }
        $subject = "$subjectPrefix Backup Hyper-V por exportacao - $ComputerName - $successCount/$($SelectedVMs.Count) VMs"
        Send-ReportEmail -Subject $subject -HtmlBody $html
    }
    catch {
        Write-Log "Falha ao gerar ou enviar relatorio: $($_.Exception.Message)" 'ERROR'
        if ($ExitCode -eq 0) { $ExitCode = 1 }
    }

    Remove-Lock
    Write-Log "Fim da rotina. Status=$OverallStatus | ExitCode=$ExitCode | Duracao=$(Format-Duration $duration)."
    Write-Log ('=' * 74)
}

exit $ExitCode
