param()

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

function Assert-True {
    param(
        [Parameter(Mandatory = $true)] [bool] $Condition,
        [Parameter(Mandatory = $true)] [string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)] [object[]] $Items,
        [Parameter(Mandatory = $true)] [string] $Expected,
        [Parameter(Mandatory = $true)] [string] $Message
    )

    Assert-True -Condition ($Items -contains $Expected) -Message $Message
}

function Get-ScriptAst {
    param([Parameter(Mandatory = $true)] [string] $Path)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref] $tokens, [ref] $errors)
    Assert-True -Condition ($errors.Count -eq 0) -Message ("Parser errors in {0}: {1}" -f $Path, ($errors | Out-String))
    return $ast
}

function Test-RefreshFastPathContract {
    $path = Join-Path $repoRoot 'tools\Refresh-GitHubLocalIndex.ps1'
    $ast = Get-ScriptAst -Path $path

    $paramNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    Assert-Contains -Items $paramNames -Expected 'Fast' -Message 'Refresh script must expose -Fast for single-repository refresh.'
    Assert-Contains -Items $paramNames -Expected 'Repo' -Message 'Refresh script must expose -Repo for target owner/name.'
    Assert-Contains -Items $paramNames -Expected 'RepoPath' -Message 'Refresh script must expose -RepoPath to avoid full clone scanning.'

    $functionNames = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
    Assert-Contains -Items $functionNames -Expected 'Resolve-IndexedClonePath' -Message 'Refresh script must resolve a repo from the existing clone index.'
    Assert-Contains -Items $functionNames -Expected 'Invoke-FastRepositoryRefresh' -Message 'Refresh script must implement a fast repo-only refresh path.'
}

Test-RefreshFastPathContract

'All unit tests passed.'
