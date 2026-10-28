#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z]:$')]
    [string]$BackupDrive = 'F:',

    [string]$ExpectedVolumeLabel = 'BACKUP-HYPERV',

    [string]$RepositoryFolder = 'HyperV-Exports',

    [string[]]$VMName,

    [string[]]$ExcludeVMName = @(),

    [string[]]$ExcludeVMId = @(),

    # Plano persistido pelo wrapper; fixa a selecao e o lote durante a cascata.
    [string]$SelectionPlanPath,

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

    # O e-mail direto dispara em FAILED/PARTIAL_SUCCESS e em avisos de exclusao
    # nas execucoes reais. PLAN fica silencioso. -SkipEmail significa "forcar silencio
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

$ScriptVersion = '2.0.3'
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
$WorkerPath = Join-Path $ScriptRoot 'Internal\Workers\Export-VMWorker.ps1'
$HashWorkerPath = Join-Path $ScriptRoot 'Internal\Workers\Get-FileHashWorker.ps1'
$TierHelpersPath = Join-Path $ScriptRoot 'Internal\Helpers\TierHelpers.ps1'
$RepositoryHelpersPath = Join-Path $ScriptRoot 'Internal\Helpers\RepositoryHelpers.ps1'
$RetentionHelpersPath = Join-Path $ScriptRoot 'Internal\Helpers\RetentionHelpers.ps1'
$SpaceHelpersPath = Join-Path $ScriptRoot 'Internal\Helpers\SpaceHelpers.ps1'
$FailureHelpersPath = Join-Path $ScriptRoot 'Internal\Helpers\FailureClassificationHelpers.ps1'
$TransactionHelpersPath = Join-Path $ScriptRoot 'Internal\Helpers\VMTransactionHelpers.ps1'
$PublishingHelpersPath = Join-Path $ScriptRoot 'Internal\Helpers\PublishingHelpers.ps1'
$ObservabilityHelpersPath = Join-Path $ScriptRoot 'Internal\Helpers\ObservabilityHelpers.ps1'
$SettingsConfigPath = Join-Path $ConfigDir 'Settings.json'
$TiersConfigPath = Join-Path $ConfigDir 'Tiers.json'
$Timestamp = $RunStart.ToString('yyyy-MM-dd_HH-mm-ss')
$logBatch = if (-not [string]::IsNullOrWhiteSpace($BatchName)) { $BatchName } elseif ($VMName) { 'ADHOC' } else { 'ALL' }
$logBatch = [regex]::Replace($logBatch, '[^A-Za-z0-9_-]', '_')
$artifactName = "$logBatch-$Timestamp-$($RunId.Substring(0, 8))"
$LogPath = Join-Path $LogDir "$artifactName.log"
$JsonPath = Join-Path $ReportDir "$artifactName.json"
$HtmlPath = Join-Path $ReportDir "$artifactName.html"
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
$ExcludedVMs = @()
$ExcludedVMDetails = @()
$SelectionWarnings = @()
$SkipReason = $null
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
    if (-not [string]::IsNullOrWhiteSpace($SelectionPlanPath)) {
        $plan = Get-Content -LiteralPath $SelectionPlanPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($plan.BackupSetId -ne $BackupSetId -or $plan.ComputerName -ne $env:COMPUTERNAME) {
            throw 'Plano de selecao pertence a outro BackupSetId ou host.'
        }
    }
    else {
        $plan = New-VMSelectionPlan -AllVMs $all -TierDefinitions $TierDefinitions -ExcludeVMName $ExcludeVMName `
            -ExcludeVMId $ExcludeVMId -RequestedNames $VMName -BackupSetId $BackupSetId
    }
    $script:ExcludedVMDetails = @($plan.ExcludedVMs)
    $script:SelectionWarnings = @($plan.Warnings)
    $script:ExcludedVMs = @($plan.ExcludedVMs | Select-Object -ExpandProperty Name)
    foreach ($entry in $script:ExcludedVMDetails) { Write-Log "VM ignorada por $($entry.Reason): $($entry.Name) | VMId=$($entry.VMId)." }
    foreach ($message in $plan.Warnings) {
        $Warnings.Add([string]$message)
        Write-Log $message 'WARNING'
    }
    $selected = @(Resolve-VMSelectionPlan -Plan $plan -AllVMs $all -BatchName $EffectiveBatchName)
    if ($selected.Count -eq 0) {
        $script:SkipReason = if (@($plan.VMs).Count -eq 0 -and $script:ExcludedVMs.Count -gt 0) {
            "Todas as VMs selecionadas foram excluidas antes da classificacao ($($script:ExcludedVMs.Count) VM(s))."
        } else {
            "Nenhuma VM elegivel para o lote '$EffectiveBatchName' no plano. VMs excluidas antes da classificacao: $($script:ExcludedVMs.Count)."
        }
    }
    return $selected
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
            [void]$failureRows.AppendLine("<td>$(ConvertTo-HtmlText (Format-VMFailureDetails -Result $item -LogPath $LogPath))</td>")
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
<tr><th>VMs ignoradas</th><td>$(ConvertTo-HtmlText ($ExcludedVMs -join ', '))</td></tr>
<tr><th>Justificativa de lote ignorado</th><td>$(ConvertTo-HtmlText $SkipReason)</td></tr>
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
        $space = Invoke-VMSpacePreparation -MinFreeGB $MinFreeGB `
            -FailedPayloadEntries $failedEntries -KeepPerVM $FailedPayloadKeepPerVM `
            -GetFreeBytesAction { Get-FreeBytes }
        foreach ($spaceError in @($space.Errors)) { $Warnings.Add("Falha na limpeza de _FAILED: $spaceError") }
        foreach ($event in @($space.Events)) {
            if ($event.Success) {
                $expectedText = if ($event.PSObject.Properties.Name -contains 'PayloadBytesExpected') { " | payload estimado=$(Format-Bytes $event.PayloadBytesExpected) | recuperado real=$(Format-Bytes $event.BytesRecovered)" } else { '' }
                Write-Log "Payload falho removido ($($event.Reason)): $($event.OccurrenceRoot) | livre antes=$(Format-Bytes $event.SpaceBeforeBytes) | depois=$(Format-Bytes $event.SpaceAfterBytes)$expectedText." 'WARNING'
            }
        }
        if ($space.EmergencyCleanupStatus -eq 'SKIPPED_INSUFFICIENT_CANDIDATES') {
            $message = "Limpeza SPACE_PRESSURE nao executada antes de $($vm.Name): faltam $(Format-Bytes $space.MissingBytes), mas os payloads elegiveis somam apenas $(Format-Bytes $space.EligiblePayloadBytes). Minimo configurado=$(Format-Bytes $space.RequiredFreeBytes)."
            Write-Log $message 'WARNING'
            $Warnings.Add($message)
        }
        elseif ($space.EmergencyCleanupStatus -in @('STOPPED_NO_GAIN', 'STOPPED_INSUFFICIENT_REMAINING', 'EXHAUSTED')) {
            $message = "Limpeza SPACE_PRESSURE interrompida antes de $($vm.Name): estado=$($space.EmergencyCleanupStatus) | minimo=$(Format-Bytes $space.RequiredFreeBytes) | livre=$(Format-Bytes $space.FinalFreeBytes)."
            Write-Log $message 'WARNING'
            $Warnings.Add($message)
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

        $availableFreeGB = [math]::Round(($space.FinalFreeBytes / 1GB), 2)
        if (-not $result.Success) { try { $availableFreeGB = Get-FreeGB } catch { } }
        $result | Add-Member -NotePropertyName RequiredFreeGB -NotePropertyValue ([math]::Round(($space.RequiredFreeBytes / 1GB), 2)) -Force
        $result | Add-Member -NotePropertyName AvailableFreeGB -NotePropertyValue $availableFreeGB -Force
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
                if (Test-Path -LiteralPath $failedPaths.PayloadRoot -PathType Container) {
                    Write-Log "[$($vm.Name)] Payload falho preservado em $($failedPaths.OccurrenceRoot)." 'WARNING'
                }
                else {
                    Write-Log "[$($vm.Name)] Registro da falha preservado em $($failedPaths.OccurrenceRoot); nenhum payload foi criado." 'WARNING'
                }
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
# poder ligar execucao real, ampliar a selecao ou resuprimir e-mail de falha.
# ExcludeVMName e uma exclusao persistente intencional e pode vir do JSON.
$ConfigurableSettingNames = @(
    'BackupDrive', 'ExpectedVolumeLabel', 'RepositoryFolder', 'CompressionLevel',
    'HeartbeatSeconds', 'ExportTimeoutHours', 'CompressionTimeoutHours', 'IntegrityTimeoutHours',
    'MinFreeGB', 'RetryCount', 'FailedPayloadKeepPerVM', 'SevenZipPath',
    'SmtpServer', 'SmtpPort', 'MailFrom', 'MailTo', 'SkipHash', 'KeepRestorePoints', 'ExcludeVMName', 'ExcludeVMId'
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
    elseif ($SelectedVMs.Count -eq 0) {
        $OverallStatus = 'SKIPPED'
        $ExitCode = 0
        $FinalPoint = $null
        Write-Log "$SkipReason Nenhum backup ou retencao executado." 'INFO'
    }
    else {
        Invoke-BackupExecutionV2
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
    elseif ($OverallStatus -notin @('SKIPPED', 'PLAN')) {
        $outcome = Get-BackupOutcome -VMResults $vmResultArray -WarningCount ($Warnings.Count + $DiagnosticFailures.Count)
        $OverallStatus = $outcome.Status
        $ExitCode = $outcome.ExitCode
    }

    if ($OverallStatus -eq 'SKIPPED' -and ($Warnings.Count + $DiagnosticFailures.Count) -gt 0) { $ExitCode = 2 }
    $summary = [ordered]@{
        SchemaVersion = 2
        RunId = $RunId
        ScriptVersion = $ScriptVersion
        ComputerName = $ComputerName
        BatchName = $EffectiveBatchName
        BackupSetId = $BackupSetId
        Status = $OverallStatus
        ExitCode = $ExitCode
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
        ExcludedVMs = @($ExcludedVMs)
        ExcludedVMDetails = @($ExcludedVMDetails)
        SkipReason = $SkipReason
        SelectionPlanPath = $SelectionPlanPath
        SelectionWarnings = @($SelectionWarnings)
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
        'SKIPPED' { '[AVISO]' }
        default { '[FALHA]' }
    }
    $batchLabel = if ([string]::IsNullOrWhiteSpace($EffectiveBatchName)) { 'DESCONHECIDO' } else { $EffectiveBatchName }
    $subject = "$subjectPrefix [Lote $batchLabel] Backup Hyper-V por exportacao - $ComputerName - $successCount/$($SelectedVMs.Count) VMs"

    if ($DeferEmail) {
        $NotificationStatus = 'DEFERRED_TO_WRAPPER'
        Write-Log 'E-mail adiado para consolidacao pelo wrapper.'
    }
    elseif ($OverallStatus -in @('FAILED', 'PARTIAL_SUCCESS') -or ($Execute -and $SelectionWarnings.Count -gt 0)) {
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
    if (-not $backupFailed -and $OverallStatus -notin @('SKIPPED', 'PLAN')) {
        $outcome = Get-BackupOutcome -VMResults $vmResultArray -WarningCount ($Warnings.Count + $DiagnosticFailures.Count)
        $OverallStatus = $outcome.Status
        $ExitCode = $outcome.ExitCode
    }
    if ($OverallStatus -eq 'SKIPPED' -and ($Warnings.Count + $DiagnosticFailures.Count) -gt 0) { $ExitCode = 2 }
    $summary.Status = $OverallStatus
    $summary.ExitCode = $ExitCode
    $summary.MailSent = $MailSent
    $summary.MailError = $MailError
    $summary.NotificationStatus = $NotificationStatus
    $summary.DiagnosticFailures = $DiagnosticFailures.ToArray()
    [void](Save-LocalReportSnapshots -Summary $summary)

    Write-Log "Fim da rotina. Status=$OverallStatus | ExitCode=$ExitCode | Duracao=$(Format-Duration $duration)."
    Write-Log ('=' * 74)
}

exit $ExitCode
