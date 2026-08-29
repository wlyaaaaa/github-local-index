#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Repo,
    [switch] $Fetch,
    [switch] $LiveMetadata,
    [switch] $RefreshRefs,
    [switch] $ForPublication,
    [switch] $Json,
    [string] $RepoPath,
    [string] $Visibility,
    [string] $DefaultBranch,
    [string] $TargetWorktree,
    [string] $TargetRef,
    [string] $IndexRoot = (Split-Path -Parent $PSScriptRoot)
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'GitHubIndex.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'GitHubIndex.PrivateNavigation.psm1') -Force

function Invoke-ProjectAdmissionCli {
    $effectiveRepoPath = $RepoPath
    $effectiveVisibility = $Visibility
    $effectiveDefaultBranch = $DefaultBranch
    $navigation = [pscustomobject]@{ status = 'explicit'; path = $RepoPath }
    if ([string]::IsNullOrWhiteSpace($effectiveRepoPath)) {
        $navigationRepo = ConvertTo-GitHubRepoSlug $Repo
        if ([string]::IsNullOrWhiteSpace($navigationRepo)) {
            $navigationRepo = $Repo
        }
        $navigation = Get-GitHubIndexPrivateRepositoryNavigation -RepoRoot $IndexRoot -Repo $navigationRepo
        if ($navigation.status -eq 'current') {
            if ([string]::IsNullOrWhiteSpace($TargetWorktree)) {
                $effectiveRepoPath = [string] $navigation.path
            }
            if ([string]::IsNullOrWhiteSpace($effectiveVisibility)) {
                $effectiveVisibility = [string] $navigation.visibility
            }
            if ([string]::IsNullOrWhiteSpace($effectiveDefaultBranch)) {
                $effectiveDefaultBranch = [string] $navigation.default_branch
            }
        }
    }

    $record = Get-ProjectAdmissionRecord `
        -Repo $Repo `
        -RepoPath $effectiveRepoPath `
        -Visibility $effectiveVisibility `
        -DefaultBranch $effectiveDefaultBranch `
        -IndexRoot $null `
        -Fetch:$Fetch `
        -LiveMetadata:$LiveMetadata `
        -RefreshRefs:$RefreshRefs `
        -ForPublication:$ForPublication `
        -TargetWorktree $TargetWorktree `
        -TargetRef $TargetRef
    if ([string]::IsNullOrWhiteSpace($TargetWorktree) -and
        $navigation.status -notin @('explicit', 'current') -and
        @($record.reasons) -contains 'missing_repo_path') {
        $record.reasons = @($record.reasons + ('private_navigation_cache_' + $navigation.status + '_bootstrap_required') | Sort-Object -Unique)
    }
    return $record
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
