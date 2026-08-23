#requires -Version 7.0

Set-StrictMode -Version Latest

$script:PrivateNavigationSchema = 'github-local-index.private-repository-navigation.v2'
$script:OwnerBaselineStoreSchema = 'github-local-index.owner-baseline-store.v3'
$script:OwnerIdentitySnapshotSchema = 'github-local-index.owner-identity-baseline.v3'
$script:OwnerLocalRootSnapshotSchema = 'github-local-index.owner-local-root-baseline.v3'
$script:OwnerBaselineReceiptSchema = 'github-local-index.owner-baseline-receipt.v3'

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

function Get-GitHubOwnerBaselineStoreLocation {
    param([Parameter(Mandatory = $true)] [string] $RepoRoot)

    $navigationLocation = Get-GitHubIndexPrivateNavigationCachePath -RepoRoot $RepoRoot
    $baselinePath = [System.IO.Path]::GetFullPath((
            Join-Path $navigationLocation.private_root 'registries/git-owner-baselines-v3.json'
        ))
    $privatePrefix = $navigationLocation.private_root + [System.IO.Path]::DirectorySeparatorChar
    if (-not $baselinePath.StartsWith($privatePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Git owner baseline path escapes 99_private.'
    }
    return [pscustomobject]@{
        private_root = $navigationLocation.private_root
        baseline_path = $baselinePath
    }
}

function Get-GitHubOwnerBaselineSha256 {
    param([Parameter(Mandatory = $true)] [string] $Text)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return 'sha256:' + [System.Convert]::ToHexString($hash).ToLowerInvariant()
}

function ConvertTo-GitHubOwnerBaselineTimestamp {
    param([Parameter(Mandatory = $true)] [object] $Value)

    if ($Value -is [datetimeoffset]) {
        return $Value.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [datetime]) {
        return ([datetimeoffset]$Value.ToUniversalTime()).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    return [datetimeoffset]::Parse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture
    ).ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-GitHubOwnerIdentityEntries {
    param(
        [Parameter(Mandatory = $true)] [object[]] $Rows,
        [Parameter(Mandatory = $true)] [string] $Owner
    )

    $normalizedOwner = $Owner.Trim().ToLowerInvariant()
    if ($normalizedOwner -notmatch '^[a-z0-9_.-]+$') {
        throw 'Git owner baseline owner is invalid.'
    }
    $entries = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($row in @($Rows)) {
        $repoProperty = if ($null -ne $row.PSObject.Properties['repo']) { 'repo' } else { 'NameWithOwner' }
        $visibilityProperty = if ($null -ne $row.PSObject.Properties['visibility']) { 'visibility' } else { 'Visibility' }
        $branchProperty = if ($null -ne $row.PSObject.Properties['default_branch']) { 'default_branch' } else { 'DefaultBranch' }
        $repo = ([string]$row.$repoProperty).Trim().ToLowerInvariant()
        $visibility = ([string]$row.$visibilityProperty).Trim().ToUpperInvariant()
        $defaultBranch = ([string]$row.$branchProperty).Trim()
        if ($repo -notmatch '^[a-z0-9_.-]+/[a-z0-9_.-]+$' -or
            -not $repo.StartsWith($normalizedOwner + '/', [System.StringComparison]::Ordinal) -or
            $visibility -notin @('PUBLIC', 'PRIVATE', 'INTERNAL') -or
            [string]::IsNullOrWhiteSpace($defaultBranch) -or
            -not $seen.Add($repo)) {
            throw 'Git owner identity baseline row is invalid.'
        }
        $entries.Add([pscustomobject][ordered]@{
            repo = $repo
            visibility = $visibility
            default_branch = $defaultBranch
        })
    }
    if ($entries.Count -eq 0) {
        throw 'Git owner identity baseline is empty.'
    }
    return @($entries | Sort-Object repo)
}

function New-GitHubOwnerIdentitySnapshot {
    param(
        [Parameter(Mandatory = $true)] [object[]] $Rows,
        [Parameter(Mandatory = $true)] [string] $Owner,
        [Parameter(Mandatory = $true)] [datetimeoffset] $ObservedAt,
        [string] $SnapshotId = ([guid]::NewGuid().ToString('N')),
        [string] $Source = 'live_github_metadata'
    )

    if ($SnapshotId -notmatch '^[a-f0-9]{32}$' -or $Source -notmatch '^[a-z0-9_]{1,80}$') {
        throw 'Git owner identity snapshot metadata is invalid.'
    }
    $entries = @(ConvertTo-GitHubOwnerIdentityEntries -Rows $Rows -Owner $Owner)
    $entriesJson = $entries | ConvertTo-Json -Depth 6 -Compress
    return [pscustomobject][ordered]@{
        schema = $script:OwnerIdentitySnapshotSchema
        snapshot_id = $SnapshotId
        observed_at = $ObservedAt.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        source = $Source
        completeness = 'complete_owner_inventory'
        repository_count = $entries.Count
        identities_sha256 = Get-GitHubOwnerBaselineSha256 -Text $entriesJson
        identities = $entries
    }
}

function ConvertTo-GitHubOwnerLocalRootEntries {
    param(
        [Parameter(Mandatory = $true)] [object[]] $IdentityEntries,
        [AllowEmptyCollection()] [object[]] $LocalRootRows = @()
    )

    $rootByRepo = @{}
    foreach ($row in @($LocalRootRows)) {
        $repoProperty = if ($null -ne $row.PSObject.Properties['repo']) { 'repo' } else { 'NameWithOwner' }
        $rootProperty = if ($null -ne $row.PSObject.Properties['local_root']) { 'local_root' } else { 'LocalPath' }
        $repo = ([string]$row.$repoProperty).Trim().ToLowerInvariant()
        if ($repo -notmatch '^[a-z0-9_.-]+/[a-z0-9_.-]+$' -or $rootByRepo.ContainsKey($repo)) {
            throw 'Git owner local-root baseline row is invalid.'
        }
        $value = ([string]$row.$rootProperty).Trim()
        $root = $null
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            if (-not [System.IO.Path]::IsPathFullyQualified($value)) {
                throw 'Git owner local-root baseline path is not fully qualified.'
            }
            $root = [System.IO.Path]::GetFullPath($value).TrimEnd('\', '/')
        }
        $rootByRepo[$repo] = $root
    }

    $identityRepos = @($IdentityEntries | ForEach-Object { [string]$_.repo })
    if (@($rootByRepo.Keys | Where-Object { $_ -notin $identityRepos }).Count -gt 0) {
        throw 'Git owner local-root baseline contains an unknown repository.'
    }
    return @($IdentityEntries | ForEach-Object {
        $repo = [string]$_.repo
        [pscustomobject][ordered]@{
            repo = $repo
            local_root = if ($rootByRepo.ContainsKey($repo)) { $rootByRepo[$repo] } else { $null }
        }
    })
}

function New-GitHubOwnerLocalRootSnapshot {
    param(
        [Parameter(Mandatory = $true)] [object[]] $IdentityEntries,
        [AllowEmptyCollection()] [object[]] $LocalRootRows = @(),
        [Parameter(Mandatory = $true)] [datetimeoffset] $ObservedAt
    )

    $entries = @(ConvertTo-GitHubOwnerLocalRootEntries `
        -IdentityEntries $IdentityEntries -LocalRootRows $LocalRootRows)
    $entriesJson = $entries | ConvertTo-Json -Depth 6 -Compress
    return [pscustomobject][ordered]@{
        schema = $script:OwnerLocalRootSnapshotSchema
        observed_at = $ObservedAt.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        nullable = $true
        repository_count = $entries.Count
        roots_present = @($entries | Where-Object { $null -ne $_.local_root }).Count
        roots_sha256 = Get-GitHubOwnerBaselineSha256 -Text $entriesJson
        entries = $entries
    }
}

function Test-GitHubOwnerIdentitySnapshot {
    param(
        [AllowNull()] [object] $Snapshot,
        [Parameter(Mandatory = $true)] [string] $Owner
    )

    if ($null -eq $Snapshot -or -not (Test-GitHubIndexExactPropertyNames -Object $Snapshot -Expected @(
                'schema', 'snapshot_id', 'observed_at', 'source', 'completeness',
                'repository_count', 'identities_sha256', 'identities'
            )) -or
        [string]$Snapshot.schema -ne $script:OwnerIdentitySnapshotSchema -or
        [string]$Snapshot.snapshot_id -notmatch '^[a-f0-9]{32}$' -or
        [string]$Snapshot.source -notmatch '^[a-z0-9_]{1,80}$' -or
        [string]$Snapshot.completeness -ne 'complete_owner_inventory') {
        return $false
    }
    try {
        $observedAt = [datetimeoffset]::Parse([string]$Snapshot.observed_at, [Globalization.CultureInfo]::InvariantCulture)
        if ($observedAt -gt [datetimeoffset]::UtcNow.AddMinutes(5)) { return $false }
        $entries = @(ConvertTo-GitHubOwnerIdentityEntries -Rows @($Snapshot.identities) -Owner $Owner)
        $hash = Get-GitHubOwnerBaselineSha256 -Text ($entries | ConvertTo-Json -Depth 6 -Compress)
        return ([int]$Snapshot.repository_count -eq $entries.Count -and
            [string]$Snapshot.identities_sha256 -ceq $hash)
    }
    catch {
        return $false
    }
}

function Test-GitHubOwnerLocalRootSnapshot {
    param(
        [AllowNull()] [object] $Snapshot,
        [Parameter(Mandatory = $true)] [object[]] $IdentityEntries
    )

    if ($null -eq $Snapshot -or -not (Test-GitHubIndexExactPropertyNames -Object $Snapshot -Expected @(
                'schema', 'observed_at', 'nullable', 'repository_count',
                'roots_present', 'roots_sha256', 'entries'
            )) -or
        [string]$Snapshot.schema -ne $script:OwnerLocalRootSnapshotSchema -or
        -not [bool]$Snapshot.nullable) {
        return $false
    }
    try {
        $observedAt = [datetimeoffset]::Parse([string]$Snapshot.observed_at, [Globalization.CultureInfo]::InvariantCulture)
        if ($observedAt -gt [datetimeoffset]::UtcNow.AddMinutes(5)) { return $false }
        $entries = @(ConvertTo-GitHubOwnerLocalRootEntries `
            -IdentityEntries $IdentityEntries -LocalRootRows @($Snapshot.entries))
        $hash = Get-GitHubOwnerBaselineSha256 -Text ($entries | ConvertTo-Json -Depth 6 -Compress)
        return ([int]$Snapshot.repository_count -eq $entries.Count -and
            [int]$Snapshot.roots_present -eq @($entries | Where-Object { $null -ne $_.local_root }).Count -and
            [string]$Snapshot.roots_sha256 -ceq $hash)
    }
    catch {
        return $false
    }
}

function Get-GitHubOwnerBaselinePayloadHash {
    param([Parameter(Mandatory = $true)] [object] $Store)

    $parts = @(
        [string]$Store.schema,
        [string]$Store.owner,
        [string]$Store.current.snapshot_id,
        (ConvertTo-GitHubOwnerBaselineTimestamp -Value $Store.current.observed_at),
        [string]$Store.current.identities_sha256,
        $(if ($null -eq $Store.previous) { '' } else { [string]$Store.previous.snapshot_id }),
        $(if ($null -eq $Store.previous) { '' } else { ConvertTo-GitHubOwnerBaselineTimestamp -Value $Store.previous.observed_at }),
        $(if ($null -eq $Store.previous) { '' } else { [string]$Store.previous.identities_sha256 }),
        [string]$Store.current_local_roots.roots_sha256,
        $(if ($null -eq $Store.previous_local_roots) { '' } else { [string]$Store.previous_local_roots.roots_sha256 }),
        [string]$Store.receipt.schema,
        (ConvertTo-GitHubOwnerBaselineTimestamp -Value $Store.receipt.written_at),
        [string]$Store.receipt.mode,
        ([bool]$Store.receipt.history_gap).ToString().ToLowerInvariant(),
        [string]$Store.receipt.bootstrap_reason,
        [string]$Store.receipt.prior_source,
        [string]$Store.receipt.current_identity_sha256,
        [string]$Store.receipt.previous_identity_sha256,
        [string]$Store.receipt.current_local_roots_sha256,
        [string]$Store.receipt.previous_local_roots_sha256
    )
    return Get-GitHubOwnerBaselineSha256 -Text ($parts -join "`n")
}

function Get-GitHubOwnerBaselineStore {
    param(
        [Parameter(Mandatory = $true)] [string] $RepoRoot,
        [string] $BaselinePath = ''
    )

    $location = Get-GitHubOwnerBaselineStoreLocation -RepoRoot $RepoRoot
    $path = if ([string]::IsNullOrWhiteSpace($BaselinePath)) {
        $location.baseline_path
    }
    else {
        [System.IO.Path]::GetFullPath($BaselinePath)
    }
    $privatePrefix = $location.private_root + [System.IO.Path]::DirectorySeparatorChar
    if (-not $path.StartsWith($privatePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ status = 'invalid_path'; store = $null; path = $path }
    }
    if (-not (Test-GitHubIndexPrivateNavigationPathChain -Location ([pscustomobject]@{
                    private_root = $location.private_root
                    cache_path = $path
                }))) {
        return [pscustomobject]@{ status = 'invalid_reparse_point'; store = $null; path = $path }
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{ status = 'missing'; store = $null; path = $path }
    }
    $item = Get-Item -LiteralPath $path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        return [pscustomobject]@{ status = 'invalid_reparse_point'; store = $null; path = $path }
    }

    try {
        $store = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
        if (-not (Test-GitHubIndexExactPropertyNames -Object $store -Expected @(
                    'schema', 'owner', 'current', 'previous', 'current_local_roots',
                    'previous_local_roots', 'receipt', 'payload_sha256'
                )) -or
            [string]$store.schema -ne $script:OwnerBaselineStoreSchema -or
            [string]$store.owner -notmatch '^[a-z0-9_.-]+$' -or
            [string]$store.payload_sha256 -notmatch '^sha256:[a-f0-9]{64}$') {
            throw 'store shape invalid'
        }
        $owner = [string]$store.owner
        if (-not (Test-GitHubOwnerIdentitySnapshot -Snapshot $store.current -Owner $owner) -or
            -not (Test-GitHubOwnerLocalRootSnapshot `
                -Snapshot $store.current_local_roots -IdentityEntries @($store.current.identities))) {
            throw 'current snapshot invalid'
        }
        $hasPrevious = $null -ne $store.previous
        if ($hasPrevious -ne ($null -ne $store.previous_local_roots)) {
            throw 'previous snapshot pair invalid'
        }
        if ($hasPrevious -and
            (-not (Test-GitHubOwnerIdentitySnapshot -Snapshot $store.previous -Owner $owner) -or
                -not (Test-GitHubOwnerLocalRootSnapshot `
                    -Snapshot $store.previous_local_roots -IdentityEntries @($store.previous.identities)))) {
            throw 'previous snapshot invalid'
        }
        if (-not (Test-GitHubIndexExactPropertyNames -Object $store.receipt -Expected @(
                    'schema', 'written_at', 'mode', 'history_gap', 'bootstrap_reason',
                    'prior_source', 'current_identity_sha256', 'previous_identity_sha256',
                    'current_local_roots_sha256', 'previous_local_roots_sha256'
                )) -or
            [string]$store.receipt.schema -ne $script:OwnerBaselineReceiptSchema -or
            [string]$store.receipt.mode -notin @('bootstrap', 'advance') -or
            [bool]$store.receipt.history_gap -ne (-not $hasPrevious)) {
            throw 'store receipt shape invalid'
        }
        if ([string]$store.receipt.current_identity_sha256 -cne [string]$store.current.identities_sha256 -or
            [string]$store.receipt.current_local_roots_sha256 -cne [string]$store.current_local_roots.roots_sha256 -or
            ([string]$store.receipt.previous_identity_sha256) -cne $(if ($hasPrevious) { [string]$store.previous.identities_sha256 } else { '' }) -or
            ([string]$store.receipt.previous_local_roots_sha256) -cne $(if ($hasPrevious) { [string]$store.previous_local_roots.roots_sha256 } else { '' })) {
            throw 'store receipt hash binding invalid'
        }
        $computedPayloadHash = Get-GitHubOwnerBaselinePayloadHash -Store $store
        if ([string]$store.payload_sha256 -cne $computedPayloadHash) {
            throw ('store payload hash invalid expected=' + [string]$store.payload_sha256 + ' actual=' + $computedPayloadHash)
        }
        [void][datetimeoffset]::Parse([string]$store.receipt.written_at, [Globalization.CultureInfo]::InvariantCulture)
        return [pscustomobject]@{ status = 'current'; store = $store; path = $path; reason = $null }
    }
    catch {
        return [pscustomobject]@{ status = 'invalid'; store = $null; path = $path; reason = $_.Exception.Message }
    }
}

function Write-GitHubOwnerBaselineStore {
    param(
        [Parameter(Mandatory = $true)] [string] $RepoRoot,
        [Parameter(Mandatory = $true)] [string] $Owner,
        [Parameter(Mandatory = $true)] [object[]] $IdentityRows,
        [AllowEmptyCollection()] [object[]] $LocalRootRows = @(),
        [Parameter(Mandatory = $true)] [datetimeoffset] $ObservedAt,
        [string] $PriorSource = 'legacy_navigation_without_full_identity_history'
    )

    if ($PriorSource -notmatch '^[a-z0-9_]{1,80}$') {
        throw 'Git owner baseline prior source is invalid.'
    }
    $location = Get-GitHubOwnerBaselineStoreLocation -RepoRoot $RepoRoot
    $existing = Get-GitHubOwnerBaselineStore -RepoRoot $RepoRoot
    if ($existing.status -notin @('missing', 'current')) {
        throw 'Refusing to replace an invalid Git owner baseline store.'
    }
    $current = New-GitHubOwnerIdentitySnapshot `
        -Rows $IdentityRows -Owner $Owner -ObservedAt $ObservedAt
    $currentRoots = New-GitHubOwnerLocalRootSnapshot `
        -IdentityEntries @($current.identities) -LocalRootRows $LocalRootRows `
        -ObservedAt $ObservedAt
    $previous = if ($existing.status -eq 'current') { $existing.store.current } else { $null }
    $previousRoots = if ($existing.status -eq 'current') { $existing.store.current_local_roots } else { $null }
    $historyGap = $null -eq $previous
    $writtenAt = [datetimeoffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    $receipt = [pscustomobject][ordered]@{
        schema = $script:OwnerBaselineReceiptSchema
        written_at = $writtenAt
        mode = if ($historyGap) { 'bootstrap' } else { 'advance' }
        history_gap = $historyGap
        bootstrap_reason = if ($historyGap) { 'prior_full_owner_baseline_unavailable' } else { $null }
        prior_source = if ($historyGap) { $PriorSource } else { 'owner_baseline_store_v3' }
        current_identity_sha256 = [string]$current.identities_sha256
        previous_identity_sha256 = if ($null -eq $previous) { '' } else { [string]$previous.identities_sha256 }
        current_local_roots_sha256 = [string]$currentRoots.roots_sha256
        previous_local_roots_sha256 = if ($null -eq $previousRoots) { '' } else { [string]$previousRoots.roots_sha256 }
    }
    $storeWithoutHash = [pscustomobject][ordered]@{
        schema = $script:OwnerBaselineStoreSchema
        owner = $Owner.Trim().ToLowerInvariant()
        current = $current
        previous = $previous
        current_local_roots = $currentRoots
        previous_local_roots = $previousRoots
        receipt = $receipt
    }
    $store = [pscustomobject][ordered]@{
        schema = $storeWithoutHash.schema
        owner = $storeWithoutHash.owner
        current = $storeWithoutHash.current
        previous = $storeWithoutHash.previous
        current_local_roots = $storeWithoutHash.current_local_roots
        previous_local_roots = $storeWithoutHash.previous_local_roots
        receipt = $storeWithoutHash.receipt
        payload_sha256 = Get-GitHubOwnerBaselinePayloadHash -Store $storeWithoutHash
    }

    $directory = Split-Path -Parent $location.baseline_path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    if (-not (Test-GitHubIndexPrivateNavigationPathChain -Location ([pscustomobject]@{
                    private_root = $location.private_root
                    cache_path = $location.baseline_path
                }))) {
        throw 'Git owner baseline path must not traverse a reparse point.'
    }
    $temporaryPath = Join-Path $directory ('.git-owner-baselines-v3.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllText(
            $temporaryPath,
            ($store | ConvertTo-Json -Depth 12) + [Environment]::NewLine,
            [System.Text.UTF8Encoding]::new($false))
        $temporaryReadback = Get-GitHubOwnerBaselineStore `
            -RepoRoot $RepoRoot -BaselinePath $temporaryPath
        if ($temporaryReadback.status -ne 'current' -or
            [string]$temporaryReadback.store.payload_sha256 -cne [string]$store.payload_sha256) {
            throw ('Git owner baseline temporary readback failed: ' + [string]$temporaryReadback.reason)
        }
        [System.IO.File]::Move($temporaryPath, $location.baseline_path, $true)
        $finalReadback = Get-GitHubOwnerBaselineStore -RepoRoot $RepoRoot
        if ($finalReadback.status -ne 'current' -or
            [string]$finalReadback.store.payload_sha256 -cne [string]$store.payload_sha256) {
            throw 'Git owner baseline final readback failed.'
        }
        return [pscustomobject]@{
            status = 'current'
            path = $location.baseline_path
            store = $finalReadback.store
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            [System.IO.File]::Delete($temporaryPath)
        }
    }
}

Export-ModuleMember -Function @(
    'Get-GitHubIndexPrivateNavigationEntries',
    'Get-GitHubIndexPrivateRepositoryNavigation',
    'Write-GitHubIndexPrivateNavigationCache',
    'Get-GitHubOwnerBaselineStore',
    'Write-GitHubOwnerBaselineStore'
)
