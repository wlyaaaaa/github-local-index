#requires -Version 7.0

Set-StrictMode -Version Latest

$script:PrivateNavigationSchema = 'github-local-index.private-repository-navigation.v2'

function Get-GitHubIndexPrivateNavigationCachePath {
    param([Parameter(Mandatory = $true)] [string] $RepoRoot)

    $resolvedRepoRoot = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    $privateRoot = [System.IO.Path]::GetFullPath((Join-Path $resolvedRepoRoot '99_private')).TrimEnd('\', '/')
    $cachePath = [System.IO.Path]::GetFullPath((Join-Path $privateRoot 'registries/repository-paths.json'))
    $privatePrefix = $privateRoot + [System.IO.Path]::DirectorySeparatorChar
    if (-not $cachePath.StartsWith($privatePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Private navigation cache path escapes 99_private.'
    }
    return [pscustomobject]@{
        private_root = $privateRoot
        cache_path = $cachePath
    }
}

function Test-GitHubIndexExactPropertyNames {
    param(
        [Parameter(Mandatory = $true)] [object] $Object,
        [Parameter(Mandatory = $true)] [string[]] $Expected
    )

    $actual = @($Object.PSObject.Properties.Name)
    return @(Compare-Object ($Expected | Sort-Object) ($actual | Sort-Object)).Count -eq 0
}

function Test-GitHubIndexPrivateNavigationPathChain {
    param([Parameter(Mandatory = $true)] [pscustomobject] $Location)

    foreach ($path in @($Location.private_root, (Split-Path -Parent $Location.cache_path))) {
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }
        $item = Get-Item -LiteralPath $path -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $false
        }
    }
    return $true
}

function Get-GitHubIndexPrivateNavigationEntries {
    param([Parameter(Mandatory = $true)] [string] $RepoRoot)

    $location = Get-GitHubIndexPrivateNavigationCachePath -RepoRoot $RepoRoot
    if (-not (Test-GitHubIndexPrivateNavigationPathChain -Location $location)) {
        return [pscustomobject]@{ status = 'invalid_reparse_point'; entries = @(); observed_at = $null }
    }
    if (-not (Test-Path -LiteralPath $location.cache_path -PathType Leaf)) {
        return [pscustomobject]@{ status = 'missing'; entries = @(); observed_at = $null }
    }
    $cacheItem = Get-Item -LiteralPath $location.cache_path -Force
    if (($cacheItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        return [pscustomobject]@{ status = 'invalid_reparse_point'; entries = @(); observed_at = $null }
    }

    try {
        $cache = Get-Content -LiteralPath $location.cache_path -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
        if (-not (Test-GitHubIndexExactPropertyNames -Object $cache -Expected @(
                    'schema', 'observed_at', 'authoritative', 'freshness', 'expires_after', 'source', 'entries'
                )) -or
            [string] $cache.schema -ne $script:PrivateNavigationSchema -or
            [bool] $cache.authoritative -or
            [string] $cache.freshness -ne 'last_successful_discovery' -or
            [string] $cache.expires_after -ne 'next_successful_discovery' -or
            [string] $cache.source -ne 'verified_git_origin_and_worktree_discovery') {
            throw 'cache shape invalid'
        }
        $observed = [DateTimeOffset]::Parse(
            [string] $cache.observed_at,
            [Globalization.CultureInfo]::InvariantCulture)
        if ($observed -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) {
            throw 'cache observation time is in the future'
        }

        $entries = @($cache.entries)
        foreach ($entry in $entries) {
            if (-not (Test-GitHubIndexExactPropertyNames -Object $entry -Expected @(
                        'repo', 'path', 'visibility', 'default_branch'
                    )) -or
                [string]::IsNullOrWhiteSpace([string] $entry.repo) -or
                -not [System.IO.Path]::IsPathRooted([string] $entry.path) -or
                [string] $entry.visibility -notin @('PUBLIC', 'PRIVATE', 'INTERNAL') -or
                [string]::IsNullOrWhiteSpace([string] $entry.default_branch)) {
                throw 'cache repository entry is malformed'
            }
        }
        if (@($entries | Group-Object { ([string] $_.repo).ToLowerInvariant() } | Where-Object Count -ne 1).Count -gt 0) {
            throw 'cache repository identities are ambiguous'
        }
        $normalizedEntries = @($entries | ForEach-Object {
            [pscustomobject]@{
                repo = [string] $_.repo
                path = [System.IO.Path]::GetFullPath([string] $_.path).TrimEnd('\', '/')
                visibility = [string] $_.visibility
                default_branch = [string] $_.default_branch
            }
        })
        return [pscustomobject]@{
            status = 'current'
            entries = $normalizedEntries
            observed_at = $observed.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        }
    }
    catch {
        return [pscustomobject]@{ status = 'invalid'; entries = @(); observed_at = $null }
    }
}

function Get-GitHubIndexPrivateRepositoryNavigation {
    param(
        [Parameter(Mandatory = $true)] [string] $RepoRoot,
        [Parameter(Mandatory = $true)] [string] $Repo
    )

    $cache = Get-GitHubIndexPrivateNavigationEntries -RepoRoot $RepoRoot
    if ($cache.status -ne 'current') {
        return [pscustomobject]@{ status = $cache.status; path = $null; observed_at = $cache.observed_at }
    }
    $matches = @($cache.entries | Where-Object { [string] $_.repo -ieq $Repo })
    if ($matches.Count -eq 0) {
        return [pscustomobject]@{ status = 'repo_missing'; path = $null; observed_at = $cache.observed_at }
    }
    return [pscustomobject]@{
        status = 'current'
        path = [string] $matches[0].path
        visibility = [string] $matches[0].visibility
        default_branch = [string] $matches[0].default_branch
        observed_at = $cache.observed_at
    }
}

function Write-GitHubIndexPrivateNavigationCache {
    param(
        [Parameter(Mandatory = $true)] [string] $RepoRoot,
        [Parameter(Mandatory = $true)] [object[]] $Rows,
        [string] $ObservedAt
    )

    $location = Get-GitHubIndexPrivateNavigationCachePath -RepoRoot $RepoRoot
    if (-not (Test-GitHubIndexPrivateNavigationPathChain -Location $location)) {
        throw 'Private navigation cache path must not traverse a reparse point.'
    }
    $entries = @($Rows | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string] $_.NavigationPath)
    } | ForEach-Object {
        [ordered]@{
            repo = [string] $_.NameWithOwner
            path = [System.IO.Path]::GetFullPath([string] $_.NavigationPath).TrimEnd('\', '/')
            visibility = [string] $_.Visibility
            default_branch = [string] $_.DefaultBranch
        }
    } | Sort-Object { ([string] $_.repo).ToLowerInvariant() })
    if (@($entries | Where-Object {
        [string]::IsNullOrWhiteSpace([string] $_.repo) -or
        [string] $_.visibility -notin @('PUBLIC', 'PRIVATE', 'INTERNAL') -or
        [string]::IsNullOrWhiteSpace([string] $_.default_branch)
    }).Count -gt 0) {
        throw 'Private navigation cache contains malformed repository metadata.'
    }
    if (@($entries | Group-Object { ([string] $_.repo).ToLowerInvariant() } | Where-Object Count -ne 1).Count -gt 0) {
        throw 'Private navigation cache contains duplicate repository identities.'
    }

    $observed = if ([string]::IsNullOrWhiteSpace($ObservedAt)) {
        [DateTimeOffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    else {
        [DateTimeOffset]::Parse($ObservedAt, [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    $cache = [ordered]@{
        schema = $script:PrivateNavigationSchema
        observed_at = $observed
        authoritative = $false
        freshness = 'last_successful_discovery'
        expires_after = 'next_successful_discovery'
        source = 'verified_git_origin_and_worktree_discovery'
        entries = $entries
    }
    $directory = Split-Path -Parent $location.cache_path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    if (-not (Test-GitHubIndexPrivateNavigationPathChain -Location $location)) {
        throw 'Private navigation cache path must not traverse a reparse point.'
    }
    $temporaryPath = Join-Path $directory ('.repository-paths.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $text = ($cache | ConvertTo-Json -Depth 6) + [Environment]::NewLine
        [System.IO.File]::WriteAllText($temporaryPath, $text, [System.Text.UTF8Encoding]::new($false))
        $readback = Get-Content -LiteralPath $temporaryPath -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
        if ([string] $readback.schema -ne $script:PrivateNavigationSchema -or
            [bool] $readback.authoritative -or
            @($readback.entries).Count -ne $entries.Count -or
            @($readback.entries | Where-Object {
                -not (Test-GitHubIndexExactPropertyNames -Object $_ -Expected @('repo', 'path', 'visibility', 'default_branch'))
            }).Count -gt 0) {
            throw 'Private navigation cache readback validation failed.'
        }
        [System.IO.File]::Move($temporaryPath, $location.cache_path, $true)
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
    return $location.cache_path
}

Export-ModuleMember -Function @(
    'Get-GitHubIndexPrivateNavigationEntries',
    'Get-GitHubIndexPrivateRepositoryNavigation',
    'Write-GitHubIndexPrivateNavigationCache'
)
