#requires -Version 5.1

# Funcoes compartilhadas entre Invoke-VMExportBackup.ps1 e Install-VMExportBackupTask.ps1
# para carregar, validar e aplicar a definicao de lotes (tiers) por tamanho de VM.
# Este arquivo e destinado a ser carregado via dot-source (. $path), nao executado direto.

Set-StrictMode -Version 2.0

function Import-JsonConfigFile {
    <#
        Leitura tolerante de um arquivo JSON de configuracao. Arquivo ausente ou
        vazio retorna $null (o chamador decide o fallback). Erro de parse tambem
        retorna $null, mas registra o motivo em $WarningList (se fornecida) ou via
        Write-Warning, sem derrubar a execucao - usado para configuracoes opcionais
        como Settings.json, onde um JSON quebrado nao deve impedir o backup de rodar
        com os defaults do script.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [System.Collections.Generic.List[string]]$WarningList
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $null
        }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        $message = "Falha ao ler/interpretar '$Path': $($_.Exception.Message)"
        if ($null -ne $WarningList) {
            $WarningList.Add($message)
        }
        else {
            Write-Warning $message
        }
        return $null
    }
}

function Assert-SettingsSchemaV2 {
    param([Parameter(Mandatory = $true)]$ConfigObject)

    $properties = @($ConfigObject.PSObject.Properties.Name)
    if ($properties -notcontains 'SchemaVersion' -or [int]$ConfigObject.SchemaVersion -ne 2) {
        throw 'Settings.json deve usar SchemaVersion 2.'
    }
    if ($properties -contains 'FailedRetentionDays') {
        throw 'Settings.json schema 2 nao aceita FailedRetentionDays; use FailedPayloadKeepPerVM.'
    }
    if ($properties -notcontains 'FailedPayloadKeepPerVM') {
        throw 'Settings.json schema 2 exige FailedPayloadKeepPerVM.'
    }
    if ($properties -notcontains 'SkipHash') {
        throw 'Settings.json schema 2 exige SkipHash.'
    }
    if ($properties -contains 'ExcludeVMName') {
        if ($ConfigObject.ExcludeVMName -isnot [System.Array]) {
            throw 'ExcludeVMName deve ser uma lista JSON de nomes de VMs (ou [] para nenhuma exclusao).'
        }
        foreach ($name in $ConfigObject.ExcludeVMName) {
            if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name)) {
                throw 'ExcludeVMName deve conter somente nomes de VMs nao vazios.'
            }
        }
    }
    if ($properties -contains 'ExcludeVMId') {
        if ($ConfigObject.ExcludeVMId -isnot [System.Array]) { throw 'ExcludeVMId deve ser uma lista JSON de GUIDs.' }
        foreach ($id in $ConfigObject.ExcludeVMId) {
            $parsed = [guid]::Empty
            if ($id -isnot [string] -or -not [guid]::TryParse($id, [ref]$parsed) -or $parsed -eq [guid]::Empty) {
                throw 'ExcludeVMId deve conter somente GUIDs validos e nao vazios.'
            }
        }
    }
    return $true
}

function New-VMSelectionPlan {
    param(
        [object[]]$AllVMs = @(),
        $TierDefinitions,
        [string[]]$ExcludeVMName = @(),
        [string[]]$ExcludeVMId = @(),
        [string[]]$RequestedNames = @(),
        [string]$BackupSetId,
        [scriptblock]$GetSizeAction = { param($Name) Get-VMSourceSize -Name $Name }
    )

    if ($AllVMs.Count -eq 0) { throw 'Nenhuma VM encontrada no host.' }
    $RequestedNames = @($RequestedNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $ids = @($ExcludeVMId | ForEach-Object {
        $id = [guid]$_
        if ($id -eq [guid]::Empty) { throw 'ExcludeVMId nao aceita GUID vazio.' }
        $id.ToString('D')
    })
    $warnings = New-Object System.Collections.Generic.List[string]
    foreach ($name in $ExcludeVMName) {
        if (@($AllVMs | Where-Object { $_.Name -ieq $name }).Count -eq 0) {
            $warnings.Add("Exclusao por nome nao encontrada no host: '$name'. Verifique se a VM foi renomeada; prefira ExcludeVMId.")
        }
    }
    foreach ($id in $ids) {
        if (@($AllVMs | Where-Object { ([guid]$_.VMId).ToString('D') -eq $id }).Count -eq 0) {
            $warnings.Add("Exclusao por VMId nao encontrada no host: '$id'.")
        }
    }
    foreach ($name in $RequestedNames) {
        if (@($AllVMs | Where-Object { $_.Name -ieq $name }).Count -eq 0) { throw "VM solicitada nao encontrada: $name" }
    }
    $included = New-Object System.Collections.Generic.List[object]
    $excluded = New-Object System.Collections.Generic.List[object]
    foreach ($vm in @($AllVMs | Sort-Object Name)) {
        $id = ([guid]$vm.VMId).ToString('D')
        $reason = if ($ids -contains $id) { 'ExcludeVMId' } elseif ($ExcludeVMName -icontains $vm.Name) { 'ExcludeVMName' } else { $null }
        if ($reason) {
            $excluded.Add([pscustomobject]@{ Name = $vm.Name; VMId = $id; Reason = $reason })
            continue
        }
        if ($RequestedNames.Count -gt 0 -and $RequestedNames -inotcontains $vm.Name) { continue }
        $size = [long](& $GetSizeAction $vm.Name)
        $tier = if ($null -ne $TierDefinitions) { Resolve-VMTier -SizeBytes $size -TierDefinitions $TierDefinitions } else { $null }
        $included.Add([pscustomobject]@{ Name = $vm.Name; VMId = $id; SourceBytes = $size; Tier = $tier })
    }
    return [pscustomobject][ordered]@{
        SchemaVersion = 2; BackupSetId = $BackupSetId; ComputerName = $env:COMPUTERNAME
        CreatedAt = (Get-Date).ToString('o'); VMs = $included.ToArray()
        ExcludedVMs = $excluded.ToArray(); Warnings = $warnings.ToArray()
    }
}

function Resolve-VMSelectionPlan {
    param([Parameter(Mandatory = $true)]$Plan, [object[]]$AllVMs = @(), [string]$BatchName)

    if ($Plan.SchemaVersion -ne 2) { throw 'Plano de selecao deve usar SchemaVersion 2.' }
    $selected = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($Plan.VMs)) {
        if ($BatchName -notin @('ALL', 'ADHOC') -and $entry.Tier -ne $BatchName) { continue }
        $vm = $AllVMs | Where-Object { ([guid]$_.VMId) -eq ([guid]$entry.VMId) } | Select-Object -First 1
        if ($null -eq $vm) {
            $vm = [pscustomobject]@{
                Name = $entry.Name; VMId = $entry.VMId; State = 'Missing'
                SelectionError = "VM do plano nao encontrada no host: $($entry.Name) (VMId=$($entry.VMId))."
            }
        }
        Add-Member -InputObject $vm -NotePropertyName SourceBytes -NotePropertyValue ([long]$entry.SourceBytes) -Force
        Add-Member -InputObject $vm -NotePropertyName Tier -NotePropertyValue $entry.Tier -Force
        $selected.Add($vm)
    }
    return $selected.ToArray()
}

function Get-TierDefinitions {
    <#
        Carrega e valida Tiers.json. Diferente de Import-JsonConfigFile, um erro de
        estrutura aqui e sempre fatal (throw): um arquivo de tiers corrompido ou
        inconsistente decidir errado qual VM pertence a qual lote e qual retencao
        se aplica, entao e preferivel parar a execucao a seguir com uma classificacao
        potencialmente errada.

        Retorna $null se o arquivo simplesmente nao existir (uso sem tiering,
        comportamento ALL/legado). Retorna um objeto com .Tiers (array ordenado por
        MinSizeGB), .DefaultTier, .CascadeStartTime e .CascadeExecutionTimeLimitHours
        quando o arquivo existe e e valido.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Nao foi possivel interpretar '$Path': $($_.Exception.Message)"
    }

    if ($null -eq $raw -or $null -eq $raw.Tiers -or @($raw.Tiers).Count -eq 0) {
        throw "'$Path' nao contem nenhum tier definido em 'Tiers'."
    }

    $tiers = @($raw.Tiers | ForEach-Object {
        [pscustomobject]@{
            Name = [string]$_.Name
            MinSizeGB = [double]$_.MinSizeGB
            MaxSizeGB = if ($null -eq $_.MaxSizeGB) { $null } else { [double]$_.MaxSizeGB }
            KeepRestorePoints = [int]$_.KeepRestorePoints
        }
    }) | Sort-Object MinSizeGB

    foreach ($tier in $tiers) {
        if ([string]::IsNullOrWhiteSpace($tier.Name)) {
            throw "'$Path' contem um tier sem 'Name'."
        }
        if ($tier.KeepRestorePoints -lt 1) {
            throw "Tier '$($tier.Name)' em '$Path' tem KeepRestorePoints invalido: deve ser >= 1."
        }
    }

    # Desde o schema v2, o agendamento e um unico gatilho em cascata (nao mais um
    # horario por lote): os lotes rodam em sequencia, um atras do outro, a partir de
    # CascadeStartTime. ExecutionTimeLimit tambem passa a ser um teto unico para a
    # cadeia inteira, ja que o Agendador do Windows so aplica um limite por tarefa.
    # Acesso via PSObject.Properties.Name primeiro (nao direto em $raw.X): sob
    # Set-StrictMode -Version 2.0, ler uma propriedade que nao existe de jeito nenhum
    # no objeto (nao so nula) lanca erro antes mesmo do throw customizado abaixo rodar.
    $hasCascadeStartTime = $raw.PSObject.Properties.Name -contains 'CascadeStartTime'
    if (-not $hasCascadeStartTime -or [string]::IsNullOrWhiteSpace([string]$raw.CascadeStartTime)) {
        throw "'$Path' nao define 'CascadeStartTime' (horario de inicio da cascata, formato HH:mm)."
    }
    if (-not ([string]$raw.CascadeStartTime -match '^([01]\d|2[0-3]):[0-5]\d$')) {
        throw "'$Path' tem CascadeStartTime invalido: '$($raw.CascadeStartTime)'. Use HH:mm."
    }
    $cascadeStartTime = [string]$raw.CascadeStartTime

    $hasCascadeLimit = $raw.PSObject.Properties.Name -contains 'CascadeExecutionTimeLimitHours'
    if (-not $hasCascadeLimit -or $null -eq $raw.CascadeExecutionTimeLimitHours) {
        throw "'$Path' nao define 'CascadeExecutionTimeLimitHours' (teto de horas para a cascata inteira)."
    }
    $cascadeExecutionTimeLimitHours = [double]$raw.CascadeExecutionTimeLimitHours
    if ($cascadeExecutionTimeLimitHours -le 0) {
        throw "'$Path' tem CascadeExecutionTimeLimitHours invalido: deve ser maior que zero."
    }

    $names = @($tiers | Select-Object -ExpandProperty Name)
    $duplicateNames = @($names | Group-Object | Where-Object { $_.Count -gt 1 } | Select-Object -ExpandProperty Name)
    if ($duplicateNames.Count -gt 0) {
        throw "Nomes de tier duplicados em '$Path': $($duplicateNames -join ', ')."
    }

    $reserved = @('ALL', 'ADHOC', 'LEGACY')
    $reservedHit = @($names | Where-Object { $reserved -icontains $_ })
    if ($reservedHit.Count -gt 0) {
        throw "Nomes de tier reservados nao podem ser usados em '$Path': $($reservedHit -join ', ')."
    }

    $openEndedCount = @($tiers | Where-Object { $null -eq $_.MaxSizeGB }).Count
    if ($openEndedCount -ne 1) {
        throw "'$Path' deve ter exatamente um tier com MaxSizeGB nulo (o tier mais alto, sem limite superior). Encontrado: $openEndedCount."
    }

    for ($i = 0; $i -lt $tiers.Count - 1; $i++) {
        $current = $tiers[$i]
        $next = $tiers[$i + 1]
        if ($null -eq $current.MaxSizeGB) {
            throw "Tier '$($current.Name)' tem MaxSizeGB nulo mas nao e o ultimo tier ao ordenar por tamanho."
        }
        if ($current.MaxSizeGB -ne $next.MinSizeGB) {
            throw "Faixas de tamanho descontinuas entre '$($current.Name)' (MaxSizeGB=$($current.MaxSizeGB)) e '$($next.Name)' (MinSizeGB=$($next.MinSizeGB)). Os limites devem ser continuos, sem lacuna nem sobreposicao."
        }
    }

    $defaultTier = if ([string]::IsNullOrWhiteSpace([string]$raw.DefaultTier)) { $tiers[0].Name } else { [string]$raw.DefaultTier }
    if ($names -notcontains $defaultTier) {
        throw "DefaultTier '$defaultTier' declarado em '$Path' nao corresponde a nenhum tier definido."
    }

    return [pscustomobject]@{
        Tiers = $tiers
        DefaultTier = $defaultTier
        CascadeStartTime = $cascadeStartTime
        CascadeExecutionTimeLimitHours = $cascadeExecutionTimeLimitHours
    }
}

function Get-VMSourceSize {
    <#
        Soma o tamanho logico atual dos discos virtuais (VHD/VHDX/AVHDX) de uma VM.
        Compartilhada entre Invoke-VMExportBackup.ps1 (classificacao por lote a cada
        execucao) e Install-VMExportBackupTask.ps1 (contagem de VMs por lote no momento
        da instalacao, para calcular ExecutionTimeLimit). Requer o modulo Hyper-V
        carregado pelo chamador.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

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

function Resolve-VMTier {
    <#
        Dado um tamanho em bytes e a definicao de tiers carregada por
        Get-TierDefinitions, devolve o nome do tier correspondente. MinSizeGB e
        inclusivo, MaxSizeGB e exclusivo. Se por algum motivo o tamanho nao bater
        em nenhuma faixa (nao deveria acontecer apos a validacao de continuidade em
        Get-TierDefinitions, mas cobre casos como tamanho negativo/NaN), cai no
        DefaultTier em vez de falhar a classificacao de uma VM inteira.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [double]$SizeBytes,

        [Parameter(Mandatory = $true)]
        $TierDefinitions
    )

    $sizeGB = $SizeBytes / 1GB
    foreach ($tier in $TierDefinitions.Tiers) {
        $matchesMin = $sizeGB -ge $tier.MinSizeGB
        $matchesMax = ($null -eq $tier.MaxSizeGB) -or ($sizeGB -lt $tier.MaxSizeGB)
        if ($matchesMin -and $matchesMax) {
            return $tier.Name
        }
    }

    return $TierDefinitions.DefaultTier
}

function Get-TierWorstCaseHours {
    <#
        Calcula um teto de tempo (em horas) para um lote inteiro. Usado pelo
        instalador (Install-VMExportBackupTask.ps1) apenas como referencia
        informativa - a soma desse valor por lote e comparada (em log, sem bloquear)
        contra CascadeExecutionTimeLimitHours configurado, para sinalizar se o teto
        da cascata parece baixo demais.

        O IntegrityTimeoutHours governa TRES etapas por VM por tentativa dentro de
        Invoke-VMExportBackup.ps1 (teste "7z t", listagem estrutural "7z l -slt" e o
        worker de hash SHA-256), nao duas - por isso o fator 3 abaixo. Ignorar isso
        subestimaria o pior caso real do script.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [int]$VMCount,

        [Parameter(Mandatory = $true)]
        [int]$RetryCount,

        [Parameter(Mandatory = $true)]
        [double]$ExportTimeoutHours,

        [Parameter(Mandatory = $true)]
        [double]$CompressionTimeoutHours,

        [Parameter(Mandatory = $true)]
        [double]$IntegrityTimeoutHours
    )

    if ($VMCount -le 0) { $VMCount = 1 }

    $perAttemptHours = $ExportTimeoutHours + $CompressionTimeoutHours + (3 * $IntegrityTimeoutHours)
    $total = $VMCount * ($RetryCount + 1) * $perAttemptHours

    # +2h de folga fixa para inventario, staging, retencao e geracao de relatorio.
    return [int][math]::Ceiling($total) + 2
}
