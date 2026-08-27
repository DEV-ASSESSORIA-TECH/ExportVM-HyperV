Set-StrictMode -Version 2.0

function Get-RepositoryRoot {
    return (Join-Path (Get-ProjectRoot) 'src')
}

function Get-ProjectRoot {
    return (Split-Path -Parent $PSScriptRoot)
}

function Get-ScriptFunction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$errors
    )

    if ($errors.Count -gt 0) {
        throw "Nao foi possivel interpretar '$Path': $($errors[0].Message)"
    }

    $matches = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $Name
    }, $true))

    if ($matches.Count -ne 1) {
        throw "Esperada uma funcao '$Name' em '$Path'; encontradas: $($matches.Count)."
    }

    return [scriptblock]::Create($matches[0].Extent.Text)
}
