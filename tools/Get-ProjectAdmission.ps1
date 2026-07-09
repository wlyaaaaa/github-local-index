#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Repo,
    [switch] $Fetch,
    [switch] $Json,
    [string] $RepoPath,
    [string] $Visibility,
    [string] $DefaultBranch,
    [string] $IndexRoot = (Split-Path -Parent $PSScriptRoot)
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'GitHubIndex.Core.psm1') -Force

function Invoke-ProjectAdmissionCli {
    Get-ProjectAdmissionRecord `
        -Repo $Repo `
        -RepoPath $RepoPath `
        -Visibility $Visibility `
        -DefaultBranch $DefaultBranch `
        -IndexRoot $IndexRoot `
        -Fetch:$Fetch
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $record = Invoke-ProjectAdmissionCli
        if ($Json) {
            $record | ConvertTo-Json -Depth 10
        }
        else {
            $record
        }
        if ($record.decision -ne 'block') { exit 0 }
        exit 2
    }
    catch {
        if ($Json) {
            New-ProjectAdmissionRecord `
                -ObservedUtc ([DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)) `
                -Repo (ConvertTo-GitHubRepoSlug $Repo) `
                -RemoteMode 'cached' `
                -Decision 'block' `
                -Reasons @('internal_error') `
                -Errors @([pscustomobject]@{ category = 'internal_error'; exit_code = 1 }) `
                -Worktrees @() |
                ConvertTo-Json -Depth 10
        }
        else {
            Write-Error 'Project admission failed.'
        }
        exit 2
    }
}
