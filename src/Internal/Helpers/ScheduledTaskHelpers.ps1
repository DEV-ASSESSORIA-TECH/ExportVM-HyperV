#requires -Version 5.1

Set-StrictMode -Version 2.0

function ConvertTo-ScheduledTaskPath {
    <#
        Normaliza o namespace de pastas do Agendador. A raiz e representada por
        "\"; pastas personalizadas sempre recebem barra inicial e final.
    #>
    param(
        [AllowEmptyString()]
        [string]$Path = '\'
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return '\' }

    $trimmed = $Path.Trim().Replace('/', '\').Trim([char]'\')
    if ([string]::IsNullOrWhiteSpace($trimmed)) { return '\' }

    $segments = @($trimmed -split '\\+' | ForEach-Object { $_.Trim() })
    if (@($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        throw "TaskPath invalido: '$Path'."
    }
    if (@($segments | Where-Object { $_ -eq '.' -or $_ -eq '..' }).Count -gt 0) {
        throw "TaskPath invalido: '$Path'. Segmentos '.' e '..' nao sao aceitos."
    }

    return '\' + ($segments -join '\') + '\'
}
