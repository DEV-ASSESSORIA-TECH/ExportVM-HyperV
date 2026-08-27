#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z]:$')]
    [string]$BackupDrive = 'F:',

    [string]$ExpectedVolumeLabel = 'BACKUP-HYPERV',

    [string]$RepositoryFolder = 'HyperV-Exports',

    [string[]]$VMName,

    [string]$BatchName,

    # Passado pelo wrapper Invoke-CascadeBackup.ps1 para que os lotes de uma mesma
    # cascata noturna publiquem dentro da mesma pasta na raiz do repositorio. Quando
    # ausente (execucao manual/avulsa), o script gera seu proprio identificador.
    [string]$BackupSetId,

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

    [ValidateRange(0, 30)]
    [int]$FailedPayloadKeepPerVM = 3,

    [string]$SevenZipPath = 'C:\Program Files\7-Zip\7z.exe',

    [string]$SmtpServer = '192.168.4.10',

    [ValidateRange(1, 65535)]
    [int]$SmtpPort = 25,

    [string]$MailFrom = 'alertas@assessoriatech.com',

    [string[]]$MailTo = @('suporte@assessoriatech.com'),

    # O e-mail direto dispara em FAILED/PARTIAL_SUCCESS (SUCCESS/PLAN
    # ficam silenciosos por padrao). -SkipEmail passou a significar "forcar silencio
    # mesmo em falha", util para testes manuais onde uma falha e esperada.
    [switch]$SkipEmail,

    # Uso interno do wrapper: adia a notificacao e entrega o resultado neste path.
    [switch]$DeferEmail,

    [string]$ResultPath,

    [switch]$SkipHash = $true,

    [switch]$Execute
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ScriptVersion = '2.0.0'
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
$TierHelpersPath = Join-Path $ScriptRoot 'TierHelpers.ps1'
$RepositoryHelpersPath = Join-Path $ScriptRoot 'RepositoryHelpers.ps1'
$RetentionHelpersPath = Join-Path $ScriptRoot 'RetentionHelpers.ps1'
$SpaceHelpersPath = Join-Path $ScriptRoot 'SpaceHelpers.ps1'
$FailureHelpersPath = Join-Path $ScriptRoot 'FailureClassificationHelpers.ps1'
$TransactionHelpersPath = Join-Path $ScriptRoot 'VMTransactionHelpers.ps1'
$PublishingHelpersPath = Join-Path $ScriptRoot 'PublishingHelpers.ps1'
$ObservabilityHelpersPath = Join-Path $ScriptRoot 'ObservabilityHelpers.ps1'
$SettingsConfigPath = Join-Path $ConfigDir 'Settings.json'
$TiersConfigPath = Join-Path $ConfigDir 'Tiers.json'
$Timestamp = $RunStart.ToString('yyyy-MM-dd_HH-mm-ss')
$LogPath = Join-Path $LogDir "VMExportBackup-$Timestamp.log"
$JsonPath = Join-Path $ReportDir "VMExportBackup-$Timestamp.json"
$HtmlPath = Join-Path $ReportDir "VMExportBackup-$Timestamp.html"
if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
    $JsonPath = [System.IO.Path]::GetFullPath($ResultPath)
    $HtmlPath = [System.IO.Path]::ChangeExtension($JsonPath, '.html')
}
$LockPath = Join-Path $LockDir 'VMExportBackup.lock.json'
# RepositoryRoot/StagingRoot/FailedRoot/RestorePointName/StagingPoint/FinalPoint sao
# calculados mais adiante, depois do merge de Config\Settings.json e da resolucao do
# lote (BatchName), pois RestorePointName agora incorpora o nome do lote. Inicializados
# como $null aqui (em vez de deixar indefinidos) porque Set-StrictMode -Version 2.0
# barraria a leitura dessas variaveis no bloco finally caso o script falhe antes de
# resolve-las (ex.: TierHelpers.ps1 ausente, Tiers.json invalido, lock ja ativo).
$RepositoryRoot = $null
$StagingRoot = $null
$FailedRoot = $null
$RestorePointName = $null
$StagingPoint = $null
$FinalPoint = $null
$BackupSetPathModel = $null
$CurrentStage = 'Inicializacao'
$ExitCode = 1
$LockAcquired = $false
$MailSent = $false
$MailError = $null
$GlobalError = $null
$NotificationStatus = 'NOT_REQUESTED'
$DiagnosticFailures = New-Object System.Collections.Generic.List[string]
$Warnings = New-Object System.Collections.Generic.List[string]
$VMResults = New-Object System.Collections.Generic.List[object]
$DeletedRestorePoints = New-Object System.Collections.Generic.List[string]
$SelectedVMs = @()
$InitialFreeGB = $null
$FinalFreeGB = $null
$RepositoryPublished = $false
$OverallStatus = 'FAILED'
$TierDefinitions = $null
$EffectiveBatchName = $null

foreach ($dir in @($LogDir, $ReportDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
        catch { $DiagnosticFailures.Add("Nao foi possivel criar o diretorio de observabilidade '$dir': $($_.Exception.Message)") }
    }
}
foreach ($dir in @($LockDir, $ConfigDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
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
    try {
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        $diagnostic = "Falha ao gravar log '$LogPath': $($_.Exception.Message)"
        if (-not $DiagnosticFailures.Contains($diagnostic)) { $DiagnosticFailures.Add($diagnostic) }
    }
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

function Get-FreeBytes {
    $driveLetter = $BackupDrive.TrimEnd(':')
    $volume = Get-Volume -DriveLetter $driveLetter -ErrorAction Stop
    return [long]$volume.SizeRemaining
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

    # Tamanho e lote sao calculados para TODA VM do host, independente do modo de
    # selecao, para que o inventario (HostInventory.json/VMResults) sempre reflita a
    # classificacao natural de cada VM, mesmo quando -VMName escolhe um subconjunto.
    foreach ($vm in $all) {
        $sizeBytes = Get-VMSourceSize -Name $vm.Name
        $tierName = if ($null -ne $TierDefinitions) { Resolve-VMTier -SizeBytes $sizeBytes -TierDefinitions $TierDefinitions } else { $null }
        Add-Member -InputObject $vm -NotePropertyName 'SourceBytes' -NotePropertyValue $sizeBytes -Force
        Add-Member -InputObject $vm -NotePropertyName 'Tier' -NotePropertyValue $tierName -Force
    }

    if ($null -ne $VMName -and $VMName.Count -gt 0) {
        $selected = New-Object System.Collections.Generic.List[object]
        foreach ($name in $VMName) {
            $vm = $all | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
            if ($null -eq $vm) { throw "VM solicitada nao encontrada: $name" }
            $selected.Add($vm)
        }
        return @($selected | Sort-Object Name)
    }

    if ($EffectiveBatchName -eq 'ALL') {
        return $all
    }

    $matched = @($all | Where-Object { $_.Tier -eq $EffectiveBatchName })
    if ($matched.Count -eq 0) {
        throw "Nenhuma VM do host se enquadra no lote '$EffectiveBatchName' com os limiares atuais de $TiersConfigPath."
    }
    return @($matched | Sort-Object Name)
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
            Tier = $vm.Tier
            SourceBytes = $vm.SourceBytes
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
        TierName = $EffectiveBatchName
        BackupSetId = $BackupSetId
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

function Get-NestedLeafDirectories {
    <#
        Enumera pastas-folha (pontos de restauracao individuais, por lote) sob uma
        raiz que pode misturar dois layouts: o antigo, raso (pontos publicados antes
        da v1.2.0, onde a propria pasta de primeiro nivel JA e o ponto) e o atual,
        aninhado (pasta da cascata da noite > subpasta por lote). Uma pasta e folha
        quando contem -LeafIndicator diretamente; caso contrario e tratada como
        container de cascata e seus filhos diretos sao verificados no lugar dela.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$LeafIndicator,

        [string[]]$ExcludeNames = @()
    )

    $result = New-Object System.Collections.Generic.List[object]
    $topLevel = @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $ExcludeNames -notcontains $_.Name })

    foreach ($entry in $topLevel) {
        if (Test-Path -LiteralPath (Join-Path $entry.FullName $LeafIndicator)) {
            $result.Add([pscustomobject]@{ Leaf = $entry; GroupParent = $null })
            continue
        }

        $children = @(Get-ChildItem -LiteralPath $entry.FullName -Directory -ErrorAction SilentlyContinue)
        foreach ($child in $children) {
            if (Test-Path -LiteralPath (Join-Path $child.FullName $LeafIndicator)) {
                $result.Add([pscustomobject]@{ Leaf = $child; GroupParent = $entry })
            }
        }
    }

    return $result.ToArray()
}

function Get-EffectiveKeepRestorePoints {
    # A retencao propria de um tier (definida em Tiers.json) sempre tem prioridade,
    # mesmo quando o tier resolvido nao e o do run atual. Nomes que nao correspondem a
    # nenhum tier configurado (LEGACY, ADHOC, ou um tier ja removido do config) usam o
    # KeepRestorePoints global resolvido para esta execucao (CLI > Settings.json > default).
    param([Parameter(Mandatory = $true)][string]$TierNameToResolve)

    if ($null -ne $TierDefinitions) {
        $match = $TierDefinitions.Tiers | Where-Object { $_.Name -eq $TierNameToResolve } | Select-Object -First 1
        if ($null -ne $match) { return [int]$match.KeepRestorePoints }
    }
    return $KeepRestorePoints
}

function Invoke-Retention {
    $entries = Get-NestedLeafDirectories -Root $RepositoryRoot -LeafIndicator 'COMPLETE.marker.json' -ExcludeNames @('_STAGING', '_FAILED')

    $complete = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $entries) {
        $directory = $entry.Leaf
        $markerPath = Join-Path $directory.FullName 'COMPLETE.marker.json'

        try {
            $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
            if ($marker.Status -eq 'COMPLETE') {
                # Pontos publicados por versoes anteriores do script nao tem TierName;
                # caem num grupo LEGACY proprio em vez de serem contados junto de um
                # tier real (o que poderia apagar pontos de um lote por engano).
                $tierName = 'LEGACY'
                if ($marker.PSObject.Properties.Name -contains 'TierName' -and -not [string]::IsNullOrWhiteSpace([string]$marker.TierName)) {
                    $tierName = [string]$marker.TierName
                }
                $complete.Add([pscustomobject]@{
                    Directory = $directory
                    GroupParent = $entry.GroupParent
                    CreatedAt = [datetime]$marker.CreatedAt
                    TierName = $tierName
                })
            }
        }
        catch {
            $Warnings.Add("Marcador invalido ignorado: $markerPath")
        }
    }

    $groups = @($complete | Group-Object TierName)
    if ($groups.Count -eq 0) {
        Write-Log 'Retencao: nenhum ponto completo encontrado para avaliar.' 'SUCCESS'
        return
    }

    $totalFound = 0
    $totalDeleted = 0
    foreach ($group in $groups) {
        $keep = Get-EffectiveKeepRestorePoints -TierNameToResolve $group.Name
        Write-Log "Aplicando retencao do lote '$($group.Name)': manter $keep ponto(s) completo(s) de $($group.Count) encontrado(s)."
        $totalFound += $group.Count

        $ordered = @($group.Group | Sort-Object CreatedAt -Descending)
        $toDelete = @($ordered | Select-Object -Skip $keep)

        foreach ($item in $toDelete) {
            Write-Log "Retencao [$($group.Name)]: removendo ponto antigo completo: $($item.Directory.FullName)." 'WARNING'
            Remove-Item -LiteralPath $item.Directory.FullName -Recurse -Force -ErrorAction Stop
            $DeletedRestorePoints.Add($item.Directory.FullName)
            $totalDeleted++

            # Se essa era a ultima subpasta restante da pasta da noite, remove tambem
            # o container vazio (evita acumular pastas de data sem conteudo).
            if ($null -ne $item.GroupParent -and (Test-Path -LiteralPath $item.GroupParent.FullName)) {
                $remaining = @(Get-ChildItem -LiteralPath $item.GroupParent.FullName -Force -ErrorAction SilentlyContinue)
                if ($remaining.Count -eq 0) {
                    Remove-Item -LiteralPath $item.GroupParent.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    Write-Log "Retencao concluida. Pontos completos encontrados=$totalFound, removidos=$totalDeleted." 'SUCCESS'
}

function Remove-ExpiredFailedPoints {
    if ($FailedRetentionDays -le 0 -or -not (Test-Path -LiteralPath $FailedRoot)) { return }

    $limit = (Get-Date).AddDays(-$FailedRetentionDays)
    # 'Metadata' e criado logo no inicio do staging de toda execucao (com ou sem
    # sucesso), entao serve como indicador confiavel de pasta-folha aqui, igual ao
    # marker.json serve para Invoke-Retention.
    $entries = Get-NestedLeafDirectories -Root $FailedRoot -LeafIndicator 'Metadata'
    $expired = @($entries | Where-Object { $_.Leaf.LastWriteTime -lt $limit })

    foreach ($item in $expired) {
        try {
            Write-Log "Removendo tentativa falha expirada: $($item.Leaf.FullName)." 'WARNING'
            Remove-Item -LiteralPath $item.Leaf.FullName -Recurse -Force -ErrorAction Stop
        }
        catch {
            $Warnings.Add("Nao foi possivel remover tentativa falha: $($item.Leaf.FullName): $($_.Exception.Message)")
        }

        if ($null -ne $item.GroupParent -and (Test-Path -LiteralPath $item.GroupParent.FullName)) {
            $remaining = @(Get-ChildItem -LiteralPath $item.GroupParent.FullName -Force -ErrorAction SilentlyContinue)
            if ($remaining.Count -eq 0) {
                Remove-Item -LiteralPath $item.GroupParent.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Remove-OrphanedStagingDirectories {
    if (-not (Test-Path -LiteralPath $StagingRoot)) { return }

    # Acquire-Lock ja garante uma unica execucao ativa por vez: qualquer diretorio
    # pre-existente aqui, no momento desta checagem, nao pertence a nenhum processo vivo.
    # So pode ter sobrado de uma execucao anterior morta abruptamente (kill do Task
    # Scheduler por estouro de ExecutionTimeLimit, queda de energia, Stop-Process manual).
    $orphans = @(Get-ChildItem -LiteralPath $StagingRoot -Directory -ErrorAction SilentlyContinue)
    if ($orphans.Count -eq 0) { return }

    if (-not (Test-Path -LiteralPath $FailedRoot)) {
        New-Item -ItemType Directory -Path $FailedRoot -Force | Out-Null
    }

    foreach ($orphan in $orphans) {
        $runningMarkerPath = Join-Path $orphan.FullName 'RUNNING.marker.json'
        $context = 'sem RUNNING.marker.json (a execucao anterior pode ter morrido antes de grava-lo).'
        if (Test-Path -LiteralPath $runningMarkerPath) {
            try {
                $running = Get-Content -LiteralPath $runningMarkerPath -Raw | ConvertFrom-Json
                $context = "RunId=$($running.RunId), Lote=$($running.TierName), PID=$($running.Pid), inicio=$($running.StartTime)."
            }
            catch {
                $context = "RUNNING.marker.json ilegivel: $($_.Exception.Message)"
            }
        }

        $destination = Join-Path $FailedRoot $orphan.Name
        Write-Log "Staging orfao encontrado: $($orphan.FullName) | $context" 'WARNING'
        $Warnings.Add("Staging orfao movido para _FAILED: $($orphan.Name) ($context)")

        try {
            if (Test-Path -LiteralPath $destination) {
                Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction Stop
            }
            [ordered]@{
                Status = 'ORPHANED'
                DetectedAt = (Get-Date).ToString('o')
                DetectedByRunId = $RunId
                Detail = $context
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $orphan.FullName 'ORPHANED.marker.json') -Encoding UTF8

            Move-Item -LiteralPath $orphan.FullName -Destination $destination -Force
            Write-Log "Staging orfao movido para: $destination" 'WARNING'
        }
        catch {
            $Warnings.Add("Falha ao mover staging orfao '$($orphan.FullName)' para _FAILED: $($_.Exception.Message)")
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
    $diagnosticHtml = if ($DiagnosticFailures.Count -gt 0) {
        '<h2>Falhas de observabilidade</h2><ul>' + (($DiagnosticFailures | ForEach-Object { '<li>' + (ConvertTo-HtmlText $_) + '</li>' }) -join '') + '</ul>'
    } else { '' }

    # Bloco de falha montado a parte e inserido logo apos o badge de status, antes do
    # Resumo - como o e-mail direto so dispara em FAILED/PARTIAL_SUCCESS, quem abre o
    # ticket precisa ver o motivo sem rolar a pagina inteira primeiro.
    $failedVMs = @($VMResults | Where-Object { -not $_.Success })
    $failureSummaryHtml = ''
    if (-not [string]::IsNullOrWhiteSpace($GlobalError) -or $failedVMs.Count -gt 0) {
        $failureRows = New-Object System.Text.StringBuilder
        foreach ($item in $failedVMs) {
            [void]$failureRows.AppendLine('<tr>')
            [void]$failureRows.AppendLine("<td>$(ConvertTo-HtmlText $item.Name)</td>")
            [void]$failureRows.AppendLine("<td>$(ConvertTo-HtmlText $item.Attempts)</td>")
            [void]$failureRows.AppendLine("<td>$(ConvertTo-HtmlText $item.Error)</td>")
            [void]$failureRows.AppendLine('</tr>')
        }

        $globalErrorHtml = if (-not [string]::IsNullOrWhiteSpace($GlobalError)) {
            '<pre>' + (ConvertTo-HtmlText $GlobalError) + '</pre>'
        } else { '' }

        $failedTableHtml = if ($failedVMs.Count -gt 0) {
            @"
<table>
<tr><th>VM</th><th>Tentativas</th><th>Erro</th></tr>
$($failureRows.ToString())
</table>
"@
        } else { '' }

        $failureSummaryHtml = @"
<div class="failureBox">
<h2>Motivo da falha</h2>
$globalErrorHtml
$failedTableHtml
</div>
"@
    }

    return @"
<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<title>Backup Hyper-V por exportacao - $ComputerName - Lote $(ConvertTo-HtmlText $Summary.BatchName)</title>
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #222; }
h1, h2 { margin-bottom: 8px; }
.badge { display: inline-block; padding: 7px 12px; border-radius: 6px; font-weight: 700; }
.ok { background: #dff6dd; color: #116b18; }
.plan { background: #e8f1ff; color: #164f9c; }
.fail { background: #ffe3e3; color: #9a1111; }
.okText { color: #116b18; font-weight: 700; }
.failText { color: #9a1111; font-weight: 700; }
.failureBox { background: #fff5f5; border: 1px solid #f0b4b4; border-radius: 6px; padding: 4px 16px 12px; margin: 12px 0 24px; }
table { border-collapse: collapse; width: 100%; margin: 12px 0 24px; }
th, td { border: 1px solid #ccc; text-align: left; padding: 7px; vertical-align: top; }
th { background: #f2f2f2; }
.small { font-size: 12px; }
pre { white-space: pre-wrap; background: #f7f7f7; padding: 12px; border: 1px solid #ddd; }
</style>
</head>
<body>
<h1>Backup Hyper-V por exportacao e 7-Zip</h1>
<p><span class="badge $statusClass">$(ConvertTo-HtmlText $Summary.Status)</span> Lote: <strong>$(ConvertTo-HtmlText $Summary.BatchName)</strong></p>
$failureSummaryHtml
<h2>Resumo</h2>
<table>
<tr><th>Servidor</th><td>$(ConvertTo-HtmlText $ComputerName)</td></tr>
<tr><th>Lote</th><td>$(ConvertTo-HtmlText $Summary.BatchName)</td></tr>
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
$diagnosticHtml
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
        $script:NotificationStatus = 'SUPPRESSED'
        Write-Log 'Envio de e-mail suprimido por -SkipEmail (mesmo em falha).'
        return
    }

    if ($MailTo.Count -eq 0) {
        $script:NotificationStatus = 'FAILED'
        $script:MailError = 'Nenhum destinatario configurado; e-mail nao enviado.'
        Add-UniqueDiagnosticFailure -List $DiagnosticFailures -Message $script:MailError
        return
    }

    $message = $null
    $smtp = $null
    $attachments = New-Object System.Collections.ArrayList

    try {
        $message = New-Object System.Net.Mail.MailMessage
        $smtp = New-Object System.Net.Mail.SmtpClient($SmtpServer, $SmtpPort)
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
        $script:NotificationStatus = 'SENT'
        Write-Log "Relatorio enviado por e-mail para: $($MailTo -join ', ')." 'SUCCESS'
    }
    catch {
        $script:MailError = $_.Exception.Message
        $script:NotificationStatus = 'FAILED'
        Add-UniqueDiagnosticFailure -List $DiagnosticFailures -Message "Falha SMTP: $($script:MailError)"
        Write-Log "Falha ao enviar e-mail: $($script:MailError)" 'WARNING'
    }
    finally {
        foreach ($attachment in $attachments) { $attachment.Dispose() }
        if ($null -ne $message) { $message.Dispose() }
        if ($null -ne $smtp) { $smtp.Dispose() }
    }
}

function Save-LocalReportSnapshots {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Summary)

    $html = $null
    try {
        Write-JsonSnapshot -Value $Summary -Path $JsonPath -Depth 15
    }
    catch {
        Add-UniqueDiagnosticFailure -List $DiagnosticFailures -Message "Falha ao gravar JSON '$JsonPath': $($_.Exception.Message)"
    }
    try {
        $html = New-HtmlReport -Summary $Summary
        Write-TextSnapshot -Value $html -Path $HtmlPath
    }
    catch {
        Add-UniqueDiagnosticFailure -List $DiagnosticFailures -Message "Falha ao gravar HTML '$HtmlPath': $($_.Exception.Message)"
    }
    return $html
}

function Invoke-ConfiguredVMTransaction {
    param(
        [Parameter(Mandatory = $true)]$VM,
        [Parameter(Mandatory = $true)]$Context
    )

    $resetAction = {
        param($ctx, $attempt)
        foreach ($path in @($ctx.ExportRoot, $ctx.PayloadRoot)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop }
            New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop | Out-Null
        }
        Write-Log "[$($VM.Name)] Tentativa $attempt/$($RetryCount + 1): preparando transacao isolada."
    }

    $exportAction = {
        param($ctx, $attempt)
        $resultPath = Join-Path $ctx.MetadataRoot "export-result-attempt$attempt.json"
        $stdout = Join-Path $ctx.MetadataRoot "export-attempt$attempt.stdout.log"
        $stderr = Join-Path $ctx.MetadataRoot "export-attempt$attempt.stderr.log"
        $arguments = @(
            '-NoProfile', '-ExecutionPolicy Bypass', '-File', (Quote-Argument $WorkerPath),
            '-VMName', (Quote-Argument $VM.Name), '-ExportPath', (Quote-Argument $ctx.ExportRoot),
            '-ResultPath', (Quote-Argument $resultPath)
        ) -join ' '
        $process = Invoke-MonitoredProcess -DisplayName "Export-VM $($VM.Name)" -FilePath 'powershell.exe' `
            -ArgumentString $arguments -Timeout ([timespan]::FromHours($ExportTimeoutHours)) -StdOutPath $stdout -StdErrPath $stderr
        if ($process.TimedOut) { throw (New-Object System.TimeoutException("Exportacao excedeu $ExportTimeoutHours hora(s).")) }
        $workerResult = Read-JsonResultFile -Path $resultPath -WaitSeconds 15
        if ($null -eq $workerResult) {
            $detail = if ($process.StdErrTail) { $process.StdErrTail } else { $process.StdOutTail }
            throw "Worker terminou sem resultado JSON valido. ExitCode=$($process.ExitCode). $detail"
        }
        if (-not $workerResult.Success) { throw "Exportacao reportou falha: $($workerResult.Error)" }
        $bytes = Get-DirectorySize -Path $ctx.ExportRoot
        if ($bytes -lt 1MB) { Throw-VMFailure -Message "Exportacao invalida ou vazia: $(Format-Bytes $bytes)." -FailureKind 'INVALID_EXPORT' -Retryable $false }
        Write-Log "[$($VM.Name)] Exportacao concluida: $(Format-Bytes $bytes) em $(Format-Duration $process.Duration)." 'SUCCESS'
        return [pscustomobject]@{ ExportBytes = $bytes; Duration = $process.Duration }
    }

    $compressAction = {
        param($ctx, $attempt)
        $stdout = Join-Path $ctx.MetadataRoot "7zip-attempt$attempt.stdout.log"
        $stderr = Join-Path $ctx.MetadataRoot "7zip-attempt$attempt.stderr.log"
        $arguments = @(
            'a', '-t7z', "-mx=$CompressionLevel", '-mmt=8', '-ms=on', '-bd', '-bb1', '-bso1', '-bse1', '--',
            (Quote-Argument $ctx.ArchivePartialPath), (Quote-Argument (Join-Path $ctx.ExportRoot '*'))
        ) -join ' '
        $process = Invoke-MonitoredProcess -DisplayName "7-Zip compactar $($VM.Name)" -FilePath $SevenZipPath `
            -ArgumentString $arguments -Timeout ([timespan]::FromHours($CompressionTimeoutHours)) -StdOutPath $stdout -StdErrPath $stderr
        if ($process.TimedOut) { throw (New-Object System.TimeoutException("Compactacao excedeu $CompressionTimeoutHours hora(s).")) }
        $textSuccess = "$($process.StdOutTail) $($process.StdErrTail)" -match '(?i)Everything is Ok'
        if (($null -ne $process.ExitCode -and $process.ExitCode -gt 1) -or ($null -eq $process.ExitCode -and -not $textSuccess)) {
            $detail = if ($process.StdErrTail) { $process.StdErrTail } else { $process.StdOutTail }
            throw "7-Zip falhou ao compactar. ExitCode=$($process.ExitCode). $detail"
        }
        if (-not (Test-Path -LiteralPath $ctx.ArchivePartialPath -PathType Leaf)) { throw "Arquivo parcial nao foi criado: $($ctx.ArchivePartialPath)" }
        $bytes = [long](Get-Item -LiteralPath $ctx.ArchivePartialPath).Length
        if ($bytes -le 0) { throw 'O arquivo compactado foi criado com tamanho zero.' }
        Write-Log "[$($VM.Name)] Compactacao concluida: $(Format-Bytes $bytes) em $(Format-Duration $process.Duration)." 'SUCCESS'
        return [pscustomobject]@{ ArchiveBytes = $bytes; Duration = $process.Duration }
    }

    $integrityAction = {
        param($ctx, $attempt)
        $stdout = Join-Path $ctx.MetadataRoot "7zip-test-attempt$attempt.stdout.log"
        $stderr = Join-Path $ctx.MetadataRoot "7zip-test-attempt$attempt.stderr.log"
        $arguments = @('t', '-bd', '-bb1', '-bso1', '-bse1', '--', (Quote-Argument $ctx.ArchivePartialPath)) -join ' '
        $process = Invoke-MonitoredProcess -DisplayName "7-Zip testar $($VM.Name)" -FilePath $SevenZipPath `
            -ArgumentString $arguments -Timeout ([timespan]::FromHours($IntegrityTimeoutHours)) -StdOutPath $stdout -StdErrPath $stderr
        if ($process.TimedOut) { throw (New-Object System.TimeoutException("Teste do arquivo excedeu $IntegrityTimeoutHours hora(s).")) }
        $textSuccess = "$($process.StdOutTail) $($process.StdErrTail)" -match '(?i)Everything is Ok'
        if (($null -ne $process.ExitCode -and $process.ExitCode -ne 0) -or ($null -eq $process.ExitCode -and -not $textSuccess)) {
            $detail = if ($process.StdErrTail) { $process.StdErrTail } else { $process.StdOutTail }
            throw "Teste 7-Zip falhou. ExitCode=$($process.ExitCode). $detail"
        }
        Write-Log "[$($VM.Name)] Arquivo aprovado no teste integral do 7-Zip em $(Format-Duration $process.Duration)." 'SUCCESS'
        return [pscustomobject]@{ Passed = $true; Duration = $process.Duration }
    }

    $structureAction = {
        param($ctx, $attempt)
        $stdout = Join-Path $ctx.MetadataRoot "7zip-list-attempt$attempt.stdout.log"
        $stderr = Join-Path $ctx.MetadataRoot "7zip-list-attempt$attempt.stderr.log"
        $arguments = @('l', '-slt', '-bd', '-bso1', '-bse1', '--', (Quote-Argument $ctx.ArchivePartialPath)) -join ' '
        $process = Invoke-MonitoredProcess -DisplayName "7-Zip listar $($VM.Name)" -FilePath $SevenZipPath `
            -ArgumentString $arguments -Timeout ([timespan]::FromHours($IntegrityTimeoutHours)) -StdOutPath $stdout -StdErrPath $stderr
        if ($process.TimedOut) { throw (New-Object System.TimeoutException("Listagem estrutural excedeu $IntegrityTimeoutHours hora(s).")) }
        $listText = if (Test-Path -LiteralPath $stdout) { Get-Content -LiteralPath $stdout -Raw -ErrorAction Stop } else { '' }
        $typeConfirmed = $listText -match '(?im)^Type = 7z\s*$'
        if (($null -ne $process.ExitCode -and $process.ExitCode -ne 0) -or ($null -eq $process.ExitCode -and -not $typeConfirmed)) {
            Throw-VMFailure -Message "Nao foi possivel listar a estrutura do arquivo 7z. ExitCode=$($process.ExitCode)." -FailureKind 'INVALID_STRUCTURE' -Retryable $false
        }
        $structure = Get-SevenZipArchiveStructure -ListText $listText
        if ([int]$structure.VirtualDiskCount -lt 1) { Throw-VMFailure -Message 'A estrutura nao contem disco virtual.' -FailureKind 'INVALID_STRUCTURE' -Retryable $false }
        if ([int]$structure.VmcxCount -lt 1) { Throw-VMFailure -Message 'A estrutura nao contem VMCX.' -FailureKind 'INVALID_STRUCTURE' -Retryable $false }
        $exportBytes = Get-DirectorySize -Path $ctx.ExportRoot
        if ([long]$structure.TotalUncompressedBytes -ne $exportBytes) {
            Throw-VMFailure -Message "Tamanho listado difere da exportacao. Exportado=$exportBytes; listado=$($structure.TotalUncompressedBytes)." -FailureKind 'INVALID_STRUCTURE' -Retryable $false
        }
        Write-Log "[$($VM.Name)] Estrutura do arquivo aprovada." 'SUCCESS'
        return [pscustomobject]@{
            ArchiveListedBytes = [long]$structure.TotalUncompressedBytes; ArchiveFileCount = [int]$structure.FileCount
            ArchiveFolderCount = [int]$structure.FolderCount; VirtualDiskCount = [int]$structure.VirtualDiskCount
            VmcxCount = [int]$structure.VmcxCount; Duration = $process.Duration
        }
    }

    $hashAction = $null
    if (-not $SkipHash) {
        $hashAction = {
            param($ctx, $attempt)
            $resultPath = Join-Path $ctx.MetadataRoot "hash-result-attempt$attempt.json"
            $stdout = Join-Path $ctx.MetadataRoot "hash-attempt$attempt.stdout.log"
            $stderr = Join-Path $ctx.MetadataRoot "hash-attempt$attempt.stderr.log"
            $arguments = @('-NoProfile', '-ExecutionPolicy Bypass', '-File', (Quote-Argument $HashWorkerPath), '-FilePath', (Quote-Argument $ctx.ArchivePartialPath), '-ResultPath', (Quote-Argument $resultPath)) -join ' '
            $process = Invoke-MonitoredProcess -DisplayName "SHA-256 $($VM.Name)" -FilePath 'powershell.exe' `
                -ArgumentString $arguments -Timeout ([timespan]::FromHours($IntegrityTimeoutHours)) -StdOutPath $stdout -StdErrPath $stderr
            if ($process.TimedOut) { throw (New-Object System.TimeoutException("SHA-256 excedeu $IntegrityTimeoutHours hora(s).")) }
            $hashResult = Read-JsonResultFile -Path $resultPath -WaitSeconds 15
            if ($null -eq $hashResult -or -not $hashResult.Success) { throw "Falha SHA-256: $($hashResult.Error)" }
            return [pscustomobject]@{ SHA256 = [string]$hashResult.Hash; Duration = $process.Duration }
        }
    }

    $finalizeAction = {
        param($ctx, $attempt)
        Move-Item -LiteralPath $ctx.ArchivePartialPath -Destination $ctx.ArchivePath -Force -ErrorAction Stop
        Remove-Item -LiteralPath $ctx.ExportRoot -Recurse -Force -ErrorAction Stop
        Write-Log "[$($VM.Name)] Exportacao temporaria removida; VM pronta para publicar." 'SUCCESS'
    }

    $parameters = @{
        Context = $Context; ResetAction = $resetAction; ExportAction = $exportAction; CompressAction = $compressAction
        IntegrityAction = $integrityAction; StructureAction = $structureAction; FinalizeAction = $finalizeAction
        RetryCount = $RetryCount; RetryDelaySeconds = 60
        WaitAction = { param($seconds) Write-Log "[$($VM.Name)] Falha transitoria; nova tentativa em $seconds segundos." 'WARNING'; Start-Sleep -Seconds $seconds }
    }
    if ($null -ne $hashAction) { $parameters.HashAction = $hashAction }
    $result = Invoke-VMTransaction @parameters

    $result | Add-Member -NotePropertyName State -NotePropertyValue ([string]$VM.State) -Force
    $result | Add-Member -NotePropertyName ExportSize -NotePropertyValue (Format-Bytes $result.ExportBytes) -Force
    $result | Add-Member -NotePropertyName ArchiveSize -NotePropertyValue (Format-Bytes $result.ArchiveBytes) -Force
    $result | Add-Member -NotePropertyName ArchiveListedSize -NotePropertyValue (Format-Bytes $result.ArchiveListedBytes) -Force
    $result | Add-Member -NotePropertyName ArchiveStructure -NotePropertyValue $(if ($result.Success) { "$($result.ArchiveFileCount) arquivo(s) | $($result.VirtualDiskCount) disco(s) | $($result.VmcxCount) VMCX | $(Format-Bytes $result.ArchiveListedBytes)" } else { $null }) -Force
    $ratio = if ($result.ExportBytes -gt 0 -and $result.ArchiveBytes -gt 0) { '{0:N1}%' -f (100 - (($result.ArchiveBytes / [double]$result.ExportBytes) * 100)) } else { $null }
    $result | Add-Member -NotePropertyName CompressionRatio -NotePropertyValue $ratio -Force
    foreach ($name in @('ExportDuration', 'CompressionDuration', 'IntegrityDuration', 'StructureDuration', 'HashDuration')) {
        $result.$name = Format-Duration $result.$name
    }
    return $result
}

function Invoke-BackupExecutionV2 {
    foreach ($dir in @($RepositoryRoot, $StagingRoot, $FailedRoot)) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        }
    }

    # Stagings interrompidos nao sao backups validos. Eles ficam preservados como
    # payload orfao para diagnostico e podem ser descartados pela pressao de espaco.
    $orphanRoot = Join-Path $FailedRoot '_ORPHANED'
    foreach ($orphan in @(Get-ChildItem -LiteralPath $StagingRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($orphan.FullName -eq $StagingPoint) { continue }
        $occurrenceRoot = Join-Path $orphanRoot $orphan.Name
        if (Test-Path -LiteralPath $occurrenceRoot) {
            $occurrenceRoot = Join-Path $orphanRoot ("$($orphan.Name)--$([guid]::NewGuid().ToString('N').Substring(0, 8))")
        }
        New-Item -ItemType Directory -Path $occurrenceRoot -Force -ErrorAction Stop | Out-Null
        Move-Item -LiteralPath $orphan.FullName -Destination (Join-Path $occurrenceRoot 'Payload') -ErrorAction Stop
        [ordered]@{
            SchemaVersion = 2; VMName = '_ORPHANED'; VMId = $null; VMIdentity = '_ORPHANED'
            TierName = $null; BackupSetId = $null; RunId = $null; OccurrenceId = $orphan.Name
            OccurredAt = (Get-Date).ToString('o'); Status = 'FAILED'; FailureKind = 'ORPHANED_STAGING'
            Retryable = $false; FailedStage = 'RECOVERY'; Attempts = 0
            ErrorType = $null; Error = 'Staging interrompido recuperado na execucao seguinte.'
            PayloadStatus = 'PRESENT'
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $occurrenceRoot 'failure.json') -Encoding UTF8 -ErrorAction Stop
        Write-Log "Staging interrompido movido para: $occurrenceRoot" 'WARNING'
    }

    if (Test-Path -LiteralPath $StagingPoint) { throw "Diretorio de staging ja existe: $StagingPoint" }
    if (Test-Path -LiteralPath $BackupSetPathModel.TierRoot) { throw "Destino final ja existe: $($BackupSetPathModel.TierRoot)" }

    $tierMetadata = Join-Path $StagingPoint 'TierMetadata'
    New-Item -ItemType Directory -Path $tierMetadata -Force -ErrorAction Stop | Out-Null
    [ordered]@{
        SchemaVersion = 2; Pid = $PID; RunId = $RunId; BackupSetId = $BackupSetId
        TierName = $EffectiveBatchName; StartTime = $RunStart.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $StagingPoint 'RUNNING.marker.json') -Encoding UTF8
    Write-HostInventory -Path (Join-Path $tierMetadata 'HostInventory.json')
    Copy-Item -LiteralPath $LogPath -Destination (Join-Path $tierMetadata 'Initial.log') -Force -ErrorAction SilentlyContinue

    Write-Stage -Number 3 -Total 9 -Title 'Exportar, validar e publicar cada VM'
    $vmIndex = 0
    foreach ($vm in $SelectedVMs) {
        $vmIndex++
        Write-Log ('-' * 74)
        Write-Log "[VM $vmIndex/$($SelectedVMs.Count)] $($vm.Name) | GUID=$($vm.VMId) | Estado=$($vm.State)."

        $occurrenceId = "${Timestamp}--$($RunId.Substring(0, 8))"
        $context = New-VMTransactionContext -StagingRoot $StagingPoint -VMName $vm.Name `
            -VMId ([string]$vm.VMId) -TierName $EffectiveBatchName -OccurrenceId $occurrenceId

        $failedEntries = @(Get-Schema2FailedPayloadEntries -RepositoryRoot $RepositoryRoot)
        $space = Invoke-VMSpacePreparation -SourceBytes ([long]$vm.SourceBytes) -MinFreeGB $MinFreeGB `
            -FailedPayloadEntries $failedEntries -KeepPerVM $FailedPayloadKeepPerVM `
            -GetFreeBytesAction { Get-FreeBytes }
        foreach ($spaceError in @($space.Errors)) { $Warnings.Add("Falha na limpeza de _FAILED: $spaceError") }
        foreach ($event in @($space.Events)) {
            if ($event.Success) {
                Write-Log "Payload falho removido ($($event.Reason)): $($event.OccurrenceRoot) | livre antes=$(Format-Bytes $event.SpaceBeforeBytes) | depois=$(Format-Bytes $event.SpaceAfterBytes)." 'WARNING'
            }
        }
        if ($space.EmergencyDeletionOccurred) {
            $Warnings.Add("Pressao de espaco exigiu remover payloads falhos adicionais antes de $($vm.Name).")
        }

        if ($space.Sufficient) {
            $result = Invoke-ConfiguredVMTransaction -VM $vm -Context $context
        }
        else {
            $spaceFailure = $space.Failure
            $result = Invoke-VMTransaction -Context $context -RetryCount 0 `
                -InitializeAction { param($ctx) throw (New-VMFailureException -Message $spaceFailure.Error -FailureKind $spaceFailure.FailureKind -Retryable $false) } `
                -ResetAction { param($ctx, $attempt) } -ExportAction { param($ctx, $attempt) } `
                -CompressAction { param($ctx, $attempt) } -IntegrityAction { param($ctx, $attempt) } `
                -StructureAction { param($ctx, $attempt) }
            $result | Add-Member -NotePropertyName State -NotePropertyValue ([string]$vm.State) -Force
            $result | Add-Member -NotePropertyName ExportSize -NotePropertyValue (Format-Bytes 0) -Force
            $result | Add-Member -NotePropertyName ArchiveSize -NotePropertyValue (Format-Bytes 0) -Force
            $result | Add-Member -NotePropertyName ArchiveListedSize -NotePropertyValue (Format-Bytes 0) -Force
            $result | Add-Member -NotePropertyName ArchiveStructure -NotePropertyValue $null -Force
            $result | Add-Member -NotePropertyName CompressionRatio -NotePropertyValue $null -Force
            foreach ($durationName in @('ExportDuration', 'CompressionDuration', 'IntegrityDuration', 'StructureDuration', 'HashDuration')) {
                $result.$durationName = Format-Duration $result.$durationName
            }
        }

        $result | Add-Member -NotePropertyName BackupSetId -NotePropertyValue $BackupSetId -Force
        $result | Add-Member -NotePropertyName RunId -NotePropertyValue $RunId -Force
        if ($result.Success) {
            try {
                [void](Publish-VMTransactionResult -Context $context -Result $result -PathModel $BackupSetPathModel)
                Write-Log "[$($vm.Name)] Publicada atomicamente em $($result.ArchivePath)." 'SUCCESS'
            }
            catch {
                $result.Success = $false; $result.Status = 'FAILED'; $result.CurrentStage = 'PUBLISH'
                $result.FailureKind = 'PUBLISH_IO'; $result.Retryable = $false
                $result.ErrorType = $_.Exception.GetType().FullName; $result.Error = $_.Exception.Message
                $result.FinishedAt = (Get-Date).ToString('o')
            }
        }

        if (-not $result.Success) {
            Write-Log "[$($vm.Name)] Falha isolada em $($result.CurrentStage): $($result.Error)" 'ERROR'
            try {
                $failedPaths = Save-FailedVMTransaction -RepositoryRoot $RepositoryRoot -Context $context -Result $result
                Write-Log "[$($vm.Name)] Payload falho preservado em $($failedPaths.OccurrenceRoot)." 'WARNING'
            }
            catch {
                $Warnings.Add("Falha ao preservar payload de $($vm.Name): $($_.Exception.Message)")
            }

            # A ocorrencia recem-criada tambem participa imediatamente do limite.
            $failedPlan = Get-FailedPayloadRetentionPlan `
                -Entries @(Get-Schema2FailedPayloadEntries -RepositoryRoot $RepositoryRoot) `
                -KeepPerVM $FailedPayloadKeepPerVM
            foreach ($entry in @($failedPlan.DeleteEntries)) {
                try {
                    $before = Get-FreeBytes
                    [void](Remove-FailedPayload -Entry $entry -Reason 'RETENTION' -SpaceBeforeBytes $before)
                    $after = Get-FreeBytes
                    Update-FailedPayloadSpaceAfter -Entry $entry -SpaceAfterBytes $after
                    Write-Log "Payload falho excedente removido: $($entry.OccurrenceRoot)." 'WARNING'
                }
                catch { $Warnings.Add("Falha na retencao de payload falho: $($_.Exception.Message)") }
            }
        }
        $VMResults.Add($result)
    }

    Write-Stage -Number 4 -Total 9 -Title 'Consolidar e publicar o tier'
    $vmResultArray = $VMResults.ToArray()
    $successCount = @($vmResultArray | Where-Object { $_.Success }).Count
    $failureCount = @($vmResultArray | Where-Object { -not $_.Success }).Count

    if ($successCount -gt 0) {
        $tierMetadataDestination = Join-Path $BackupSetPathModel.MetadataRoot '_Tier'
        if (-not (Test-Path -LiteralPath $BackupSetPathModel.MetadataRoot -PathType Container)) {
            New-Item -ItemType Directory -Path $BackupSetPathModel.MetadataRoot -Force -ErrorAction Stop | Out-Null
        }
        Move-Item -LiteralPath $tierMetadata -Destination $tierMetadataDestination -ErrorAction Stop
        $markerStatus = if ($failureCount -gt 0) { 'PARTIAL_SUCCESS' } else { 'SUCCESS' }
        [void](Write-BackupTierManifestV2 -PathModel $BackupSetPathModel -Status $markerStatus `
            -RunId $RunId -StartedAt $RunStart -FinishedAt (Get-Date) `
            -KeepRestorePoints $KeepRestorePoints -VMResults $vmResultArray)
        $script:RepositoryPublished = $true
        $script:FinalPoint = $BackupSetPathModel.TierRoot
        Write-Log "Tier publicado com estado $markerStatus em $($BackupSetPathModel.TierRoot)." 'SUCCESS'

        Write-Stage -Number 5 -Total 9 -Title 'Aplicar retencao valida por VM'
        $validPlan = Get-ValidBackupRetentionPlan `
            -Entries @(Get-Schema2ValidBackupEntries -RepositoryRoot $RepositoryRoot) `
            -DefaultKeepRestorePoints $KeepRestorePoints
        foreach ($entry in @($validPlan.DeleteEntries)) {
            try {
                [void](Remove-ValidBackupEntry -Entry $entry)
                $DeletedRestorePoints.Add($entry.ArchivePath)
                Write-Log "Backup valido antigo removido por VMId: $($entry.ArchivePath)." 'WARNING'
            }
            catch { $Warnings.Add("Falha na retencao valida de $($entry.ArchivePath): $($_.Exception.Message)") }
        }

        Write-Stage -Number 6 -Total 9 -Title 'Confirmar arquivos publicados'
        foreach ($published in @($vmResultArray | Where-Object { $_.Success })) {
            if (-not (Test-Path -LiteralPath $published.ArchivePath -PathType Leaf)) {
                throw "Arquivo publicado desapareceu antes da confirmacao: $($published.ArchivePath)"
            }
        }
    }
    else {
        $script:FinalPoint = $null
        if (Test-Path -LiteralPath $tierMetadata -PathType Container) {
            Remove-Item -LiteralPath $tierMetadata -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (Test-Path -LiteralPath $StagingPoint -PathType Container) {
        Remove-Item -LiteralPath $StagingPoint -Recurse -Force -ErrorAction Stop
    }
    $outcome = Get-BackupOutcome -VMResults $vmResultArray -WarningCount $Warnings.Count
    $script:OverallStatus = $outcome.Status
    $script:ExitCode = $outcome.ExitCode
    Write-Stage -Number 8 -Total 9 -Title "Finalizar execucao: $($outcome.Status)"
}

# Nomes de parametro elegiveis para receber valor default de Config\Settings.json
# quando nao informados explicitamente na linha de comando. Switches de escopo/seguranca
# (-Execute, -VMName, -BatchName, -SkipEmail) ficam de fora de proposito: um JSON nao deve
# poder ligar execucao real, mudar quais VMs sao processadas ou resuprimir e-mail de falha.
$ConfigurableSettingNames = @(
    'BackupDrive', 'ExpectedVolumeLabel', 'RepositoryFolder', 'CompressionLevel',
    'HeartbeatSeconds', 'ExportTimeoutHours', 'CompressionTimeoutHours', 'IntegrityTimeoutHours',
    'MinFreeGB', 'RetryCount', 'FailedPayloadKeepPerVM', 'SevenZipPath',
    'SmtpServer', 'SmtpPort', 'MailFrom', 'MailTo', 'SkipHash', 'KeepRestorePoints'
)

function Merge-ConfiguredDefaults {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$BoundParameters,

        [AllowNull()]
        [object]$ConfigObject,

        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    if ($null -eq $ConfigObject) { return }

    foreach ($name in $Names) {
        if ($BoundParameters.ContainsKey($name)) { continue }
        if ($ConfigObject.PSObject.Properties.Name -notcontains $name) { continue }

        Set-Variable -Name $name -Scope Script -Value $ConfigObject.$name
        Write-Log "Config: $name definido por Settings.json = $($ConfigObject.$name)."
    }
}

Write-Log ('=' * 74)
Write-Log "Inicio do Invoke-VMExportBackup.ps1 v$ScriptVersion."
Write-Log "RunId: $RunId"
Write-Log "Modo: $Mode"
Write-Log ('=' * 74)

try {
    Acquire-Lock

    foreach ($helperPath in @(
        $TierHelpersPath, $RepositoryHelpersPath, $RetentionHelpersPath, $SpaceHelpersPath,
        $FailureHelpersPath, $TransactionHelpersPath, $PublishingHelpersPath, $ObservabilityHelpersPath
    )) {
        if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) { throw "Modulo requerido nao encontrado: $helperPath" }
        . $helperPath
    }

    $settingsFileExists = Test-Path -LiteralPath $SettingsConfigPath -PathType Leaf
    $SettingsConfig = Import-JsonConfigFile -Path $SettingsConfigPath -WarningList $Warnings
    if ($settingsFileExists) {
        if ($null -eq $SettingsConfig) { throw "$SettingsConfigPath existe, mas nao contem JSON valido." }
        [void](Assert-SettingsSchemaV2 -ConfigObject $SettingsConfig)
    }
    Merge-ConfiguredDefaults -BoundParameters $PSBoundParameters -ConfigObject $SettingsConfig -Names $ConfigurableSettingNames

    try {
        $TierDefinitions = Get-TierDefinitions -Path $TiersConfigPath
    }
    catch {
        throw "Falha ao carregar $TiersConfigPath : $($_.Exception.Message)"
    }

    $explicitBatchName = $PSBoundParameters.ContainsKey('BatchName')
    $explicitVMName = $PSBoundParameters.ContainsKey('VMName') -and $VMName.Count -gt 0

    if ($explicitBatchName) {
        $validBatchNames = @('ALL')
        if ($null -ne $TierDefinitions) {
            $validBatchNames += @($TierDefinitions.Tiers | Select-Object -ExpandProperty Name)
        }
        if ($validBatchNames -notcontains $BatchName) {
            throw "BatchName '$BatchName' invalido. Valores aceitos: $($validBatchNames -join ', ')."
        }
        $EffectiveBatchName = $BatchName
    }
    elseif ($explicitVMName) {
        $EffectiveBatchName = 'ADHOC'
    }
    elseif ($null -eq $TierDefinitions) {
        $EffectiveBatchName = 'ALL'
    }
    else {
        throw "$TiersConfigPath esta presente. Informe -BatchName <nome> ou -VMName <lista> explicitamente antes de rodar o backup."
    }

    $RepositoryRoot = Join-Path ($BackupDrive + '\') $RepositoryFolder
    $StagingRoot = Join-Path $RepositoryRoot '_STAGING'
    $FailedRoot = Join-Path $RepositoryRoot '_FAILED'
    if ($PSBoundParameters.ContainsKey('BackupSetId') -and -not [string]::IsNullOrWhiteSpace($BackupSetId)) {
        if (-not (Test-BackupSetId -BackupSetId $BackupSetId)) { throw "BackupSetId invalido: '$BackupSetId'." }
    } else {
        $BackupSetId = New-BackupSetId -StartedAt $RunStart
    }
    $RestorePointName = "{0}_{1}_{2}" -f $BackupSetId, (ConvertTo-RepositorySafeName $EffectiveBatchName), $RunId.Substring(0, 8)
    $StagingPoint = Join-Path $StagingRoot $RestorePointName
    $BackupSetPathModel = Get-BackupSetPathModel -RepositoryRoot $RepositoryRoot -BackupSetId $BackupSetId -TierName $EffectiveBatchName
    $FinalPoint = $BackupSetPathModel.TierRoot

    Write-Log "Lote: $EffectiveBatchName"
    Write-Log "BackupSetId: $BackupSetId"
    Write-Log "Repositorio: $RepositoryRoot"

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

    Write-Stage -Number 2 -Total 9 -Title 'Selecionar VMs e registrar inventario'

    $SelectedVMs = @(Get-SelectedVMs)
    Write-Log "VMs selecionadas: $($SelectedVMs.Count)."

    foreach ($vm in $SelectedVMs) {
        Write-Log "VM=$($vm.Name) | GUID=$($vm.VMId) | Estado=$($vm.State) | Lote=$($vm.Tier) | VHDX atuais=$(Format-Bytes $vm.SourceBytes)."
    }

    if (-not $Execute) {
        $OverallStatus = 'PLAN'
        $ExitCode = 0
        Write-Log 'Plano validado. Nenhuma exportacao ou exclusao foi executada.' 'SUCCESS'
    }
    else {
        Invoke-BackupExecutionV2
    }

    # Fluxo v1.2 mantido temporariamente como referencia inerte durante a ativacao
    # incremental da v2.0. O caminho produtivo acima e o unico executado.
    if ($false) {
        foreach ($dir in @($RepositoryRoot, $StagingRoot, $FailedRoot)) {
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
        }

        Remove-ExpiredFailedPoints
        Remove-OrphanedStagingDirectories

        if (Test-Path -LiteralPath $StagingPoint) {
            throw "Diretorio de staging ja existe: $StagingPoint"
        }

        $workingRoot = Join-Path $StagingPoint 'Working'
        $archivesRoot = Join-Path $StagingPoint 'Archives'
        $metadataRoot = Join-Path $StagingPoint 'Metadata'
        foreach ($dir in @($StagingPoint, $workingRoot, $archivesRoot, $metadataRoot)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        [ordered]@{
            Pid = $PID
            RunId = $RunId
            TierName = $EffectiveBatchName
            StartTime = $RunStart.ToString('o')
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $StagingPoint 'RUNNING.marker.json') -Encoding UTF8

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
            $failedDestination = Join-Path (Join-Path $FailedRoot $CascadeGroupName) $RestorePointName
            if (Test-Path -LiteralPath $failedDestination) {
                Remove-Item -LiteralPath $failedDestination -Recurse -Force
            }
            $failedDestinationParent = Split-Path -Parent $failedDestination
            if (-not (Test-Path -LiteralPath $failedDestinationParent)) {
                New-Item -ItemType Directory -Path $failedDestinationParent -Force | Out-Null
            }
            Move-Item -LiteralPath $StagingPoint -Destination $failedDestination
            $FinalPoint = $failedDestination
            throw "$failureCount VM(s) falharam. O conjunto parcial foi preservado em $failedDestination e nao conta para retencao."
        }

        Write-Stage -Number 5 -Total 9 -Title 'Publicar ponto de restauracao atomico'

        $runningMarkerPath = Join-Path $StagingPoint 'RUNNING.marker.json'
        if (Test-Path -LiteralPath $runningMarkerPath) {
            Remove-Item -LiteralPath $runningMarkerPath -Force -ErrorAction SilentlyContinue
        }

        Write-RestorePointMarker -Path (Join-Path $StagingPoint 'COMPLETE.marker.json') -Status 'COMPLETE'
        if (Test-Path -LiteralPath $FinalPoint) {
            throw "Destino final ja existe: $FinalPoint"
        }
        $finalPointParent = Split-Path -Parent $FinalPoint
        if (-not (Test-Path -LiteralPath $finalPointParent)) {
            New-Item -ItemType Directory -Path $finalPointParent -Force | Out-Null
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

    if ($Execute -and -not [string]::IsNullOrWhiteSpace($StagingPoint) -and (Test-Path -LiteralPath $StagingPoint)) {
        try {
            $orphanRoot = Join-Path $FailedRoot '_ORPHANED'
            if (-not (Test-Path -LiteralPath $orphanRoot -PathType Container)) {
                New-Item -ItemType Directory -Path $orphanRoot -Force | Out-Null
            }
            $failedDestination = Join-Path $orphanRoot $RestorePointName
            if (Test-Path -LiteralPath $failedDestination) {
                $failedDestination = Join-Path $orphanRoot ("$RestorePointName--$([guid]::NewGuid().ToString('N').Substring(0, 8))")
            }
            New-Item -ItemType Directory -Path $failedDestination -Force | Out-Null
            Move-Item -LiteralPath $StagingPoint -Destination (Join-Path $failedDestination 'Payload')
            [ordered]@{
                SchemaVersion = 2; VMName = '_ORPHANED'; VMId = $null; VMIdentity = '_ORPHANED'
                TierName = $EffectiveBatchName; BackupSetId = $BackupSetId; RunId = $RunId
                OccurrenceId = $RestorePointName; OccurredAt = (Get-Date).ToString('o')
                Status = 'FAILED'; FailureKind = 'UNEXPECTED_RUN_FAILURE'; Retryable = $false
                FailedStage = $CurrentStage; Attempts = 0; ErrorType = $null; Error = $GlobalError
                PayloadStatus = 'PRESENT'
            } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $failedDestination 'failure.json') -Encoding UTF8
            $FinalPoint = $failedDestination
            Write-Log "Staging inesperado preservado em: $failedDestination" 'WARNING'
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

    $backupFailed = -not [string]::IsNullOrWhiteSpace($GlobalError) -or $failureCount -gt 0 -or $OverallStatus -in @('FAILED', 'PARTIAL_SUCCESS')
    if ($backupFailed) {
        $OverallStatus = if ($successCount -gt 0) { 'PARTIAL_SUCCESS' } else { 'FAILED' }
        $ExitCode = 1
    }
    else {
        $outcome = Get-BackupOutcome -VMResults $vmResultArray -WarningCount ($Warnings.Count + $DiagnosticFailures.Count)
        $OverallStatus = $outcome.Status
        $ExitCode = $outcome.ExitCode
    }

    $summary = [ordered]@{
        SchemaVersion = 2
        RunId = $RunId
        ScriptVersion = $ScriptVersion
        ComputerName = $ComputerName
        BatchName = $EffectiveBatchName
        BackupSetId = $BackupSetId
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
        NotificationStatus = $NotificationStatus
        Warnings = $warningArray
        DiagnosticFailures = $DiagnosticFailures.ToArray()
        Error = $GlobalError
        VMResults = $vmResultArray
        LogPath = $LogPath
        JsonPath = $JsonPath
        HtmlPath = $HtmlPath
    }

    $html = Save-LocalReportSnapshots -Summary $summary
    Write-Log "Resultado JSON: $JsonPath"
    Write-Log "Relatorio HTML: $HtmlPath"

    $subjectPrefix = switch ($OverallStatus) {
        'SUCCESS' { '[SUCESSO]' }
        'SUCCESS_WITH_WARNINGS' { '[AVISO]' }
        'PLAN' { '[PLANO]' }
        default { '[FALHA]' }
    }
    $batchLabel = if ([string]::IsNullOrWhiteSpace($EffectiveBatchName)) { 'DESCONHECIDO' } else { $EffectiveBatchName }
    $subject = "$subjectPrefix [Lote $batchLabel] Backup Hyper-V por exportacao - $ComputerName - $successCount/$($SelectedVMs.Count) VMs"

    if ($DeferEmail) {
        $NotificationStatus = 'DEFERRED_TO_WRAPPER'
        Write-Log 'E-mail adiado para consolidacao pelo wrapper.'
    }
    elseif ($OverallStatus -in @('FAILED', 'PARTIAL_SUCCESS')) {
        if ([string]::IsNullOrWhiteSpace($html)) {
            try { $html = New-HtmlReport -Summary $summary }
            catch { Add-UniqueDiagnosticFailure -List $DiagnosticFailures -Message "Falha ao gerar corpo do e-mail: $($_.Exception.Message)" }
        }
        if (-not [string]::IsNullOrWhiteSpace($html)) { Send-ReportEmail -Subject $subject -HtmlBody $html }
    }
    else {
        $NotificationStatus = if ($SkipEmail) { 'SUPPRESSED' } else { 'NOT_REQUIRED' }
        Write-Log "E-mail nao enviado (Status=$OverallStatus, SkipEmail=$SkipEmail)."
    }

    Remove-Lock

    # SMTP e a primeira gravacao de relatorio podem adicionar diagnosticos. Recalcula
    # somente estados sem falha de backup; codigo 1 sempre prevalece.
    if (-not $backupFailed) {
        $outcome = Get-BackupOutcome -VMResults $vmResultArray -WarningCount ($Warnings.Count + $DiagnosticFailures.Count)
        $OverallStatus = $outcome.Status
        $ExitCode = $outcome.ExitCode
    }
    $summary.Status = $OverallStatus
    $summary.MailSent = $MailSent
    $summary.MailError = $MailError
    $summary.NotificationStatus = $NotificationStatus
    $summary.DiagnosticFailures = $DiagnosticFailures.ToArray()
    [void](Save-LocalReportSnapshots -Summary $summary)

    Write-Log "Fim da rotina. Status=$OverallStatus | ExitCode=$ExitCode | Duracao=$(Format-Duration $duration)."
    Write-Log ('=' * 74)
}

exit $ExitCode
