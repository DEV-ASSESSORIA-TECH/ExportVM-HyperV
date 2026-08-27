#requires -Version 5.1

# Classificacao central das falhas de uma transacao. Operacoes podem anexar uma
# classificacao explicita a Exception.Data; o fallback usa tipo e etapa.

Set-StrictMode -Version 2.0

function New-VMFailureException {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][string]$FailureKind,
        [Parameter(Mandatory = $true)][bool]$Retryable,
        [System.Exception]$InnerException
    )

    $exception = if ($null -eq $InnerException) {
        New-Object System.Exception($Message)
    } else {
        New-Object System.Exception($Message, $InnerException)
    }
    $exception.Data['FailureKind'] = $FailureKind
    $exception.Data['Retryable'] = $Retryable
    return $exception
}

function Throw-VMFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][string]$FailureKind,
        [Parameter(Mandatory = $true)][bool]$Retryable,
        [System.Exception]$InnerException
    )

    throw (New-VMFailureException -Message $Message -FailureKind $FailureKind -Retryable $Retryable -InnerException $InnerException)
}

function Get-VMFailureClassification {
    param(
        [Parameter(Mandatory = $true)][System.Exception]$Exception,
        [Parameter(Mandatory = $true)][string]$Stage
    )

    if ($Exception.Data.Contains('FailureKind')) {
        $kind = [string]$Exception.Data['FailureKind']
        $retryable = if ($Exception.Data.Contains('Retryable')) { [bool]$Exception.Data['Retryable'] } else { $false }
        return [pscustomobject]@{ FailureKind = $kind; Retryable = $retryable; Source = 'EXPLICIT' }
    }

    if ($Exception -is [System.UnauthorizedAccessException] -or $Exception -is [System.Security.SecurityException]) {
        return [pscustomobject]@{ FailureKind = 'ACCESS_DENIED'; Retryable = $false; Source = 'EXCEPTION_TYPE' }
    }
    if ($Exception -is [System.IO.IOException]) {
        return [pscustomobject]@{ FailureKind = 'IO_TRANSIENT'; Retryable = $true; Source = 'EXCEPTION_TYPE' }
    }
    if ($Exception -is [System.TimeoutException]) {
        return [pscustomobject]@{ FailureKind = 'PROCESS_TIMEOUT'; Retryable = $true; Source = 'EXCEPTION_TYPE' }
    }
    if ($Exception -is [System.ComponentModel.Win32Exception]) {
        return [pscustomobject]@{ FailureKind = 'PROCESS_TRANSIENT'; Retryable = $true; Source = 'EXCEPTION_TYPE' }
    }

    switch ($Stage) {
        'EXPORT' { return [pscustomobject]@{ FailureKind = 'EXPORT_TRANSIENT'; Retryable = $true; Source = 'STAGE' } }
        'COMPRESS' { return [pscustomobject]@{ FailureKind = 'SEVEN_ZIP_TRANSIENT'; Retryable = $true; Source = 'STAGE' } }
        'INTEGRITY' { return [pscustomobject]@{ FailureKind = 'SEVEN_ZIP_TRANSIENT'; Retryable = $true; Source = 'STAGE' } }
        'HASH' { return [pscustomobject]@{ FailureKind = 'HASH_TRANSIENT'; Retryable = $true; Source = 'STAGE' } }
        'STRUCTURE' { return [pscustomobject]@{ FailureKind = 'INVALID_STRUCTURE'; Retryable = $false; Source = 'STAGE' } }
        default { return [pscustomobject]@{ FailureKind = 'DETERMINISTIC_OPERATION'; Retryable = $false; Source = 'DEFAULT' } }
    }
}
