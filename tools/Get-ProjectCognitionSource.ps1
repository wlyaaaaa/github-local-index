#requires -Version 7.0

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$')]
    [string] $Owner = 'wlyaaaaa',
    [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [ValidateRange(1, 20)] [int] $MaxPages = 20,
    [ValidateRange(1, 2000)] [int] $MaxRepositories = 1000,
    [ValidateRange(0, 256)] [int] $MaxCompareFiles = 64,
    [string] $CompareRepositoryId = '',
    [string] $CompareBaseOid = '',
    [string] $CompareHeadOid = '',
    [switch] $Json
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'GitHubIndex.PrivateNavigation.psm1') -Force

$script:ProjectCognitionSchema = 'github-local-index.project-cognition-source.v1'
$script:ProjectCognitionNodeIdPattern = '^[A-Za-z0-9_=-]{3,160}$'
$script:ProjectCognitionOidPattern = '^[a-fA-F0-9]{40}(?:[a-fA-F0-9]{24})?$'

function Get-ProjectCognitionSha256 {
    param([Parameter(Mandatory)] [string] $Text)

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    return [Convert]::ToHexString($hash).ToLowerInvariant()
}

function ConvertTo-ProjectCognitionSafeCode {
    param(
        [AllowNull()] [string] $Value,
        [string] $Fallback = 'provider_execution_failed'
    )

    $normalized = ([string]$Value).Trim().ToLowerInvariant()
    if ($normalized -notmatch '^[a-z0-9_]{1,80}$') {
        return $Fallback
    }
    return $normalized
}

function ConvertTo-ProjectCognitionRepoSlug {
    param([AllowNull()] [string] $Remote)

    $value = ([string]$Remote).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }

    $slug = $null
    if ($value -match '^(?i)https://github\.com/([^/\s]+/[^/\s]+?)(?:\.git)?/?$') {
        $slug = $Matches[1]
    }
    elseif ($value -match '^(?i)git@github\.com:([^/\s]+/[^/\s]+?)(?:\.git)?$') {
        $slug = $Matches[1]
    }
    elseif ($value -match '^(?i)ssh://git@github\.com/([^/\s]+/[^/\s]+?)(?:\.git)?/?$') {
        $slug = $Matches[1]
    }
    if ($null -eq $slug) { return $null }
    return $slug.TrimEnd('/').ToLowerInvariant()
}

function ConvertTo-ProjectCognitionUtc {
    param([AllowNull()] [object] $Value)

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try {
        return [DateTimeOffset]::Parse(
            $text,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal
        ).ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        throw 'remote_metadata_invalid'
    }
}

function Invoke-ProjectCognitionGhJson {
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [ValidateRange(1, 3)] [int] $MaxAttempts = 2,
        [ValidateRange(1000, 120000)] [int] $TimeoutMilliseconds = 90000
    )

    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if ($null -eq $gh) { throw 'github_cli_unavailable' }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $process = $null
        try {
            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.FileName = $gh.Source
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            $start.StandardOutputEncoding = [Text.Encoding]::UTF8
            $start.StandardErrorEncoding = [Text.Encoding]::UTF8
            $start.Environment['GH_PROMPT_DISABLED'] = '1'
            foreach ($argument in $Arguments) { $null = $start.ArgumentList.Add($argument) }

            $process = [Diagnostics.Process]::new()
            $process.StartInfo = $start
            if (-not $process.Start()) { throw 'github_transport_unavailable' }
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit($TimeoutMilliseconds)) {
                try { $process.Kill($true) } catch {}
                throw 'github_transport_timeout'
            }
            $stdout = $stdoutTask.GetAwaiter().GetResult()
            $null = $stderrTask.GetAwaiter().GetResult()
            if ($process.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($stdout)) {
                throw 'github_transport_unavailable'
            }
            return $stdout | ConvertFrom-Json -Depth 20 -ErrorAction Stop
        }
        catch {
            if ($attempt -eq $MaxAttempts) {
                $code = ConvertTo-ProjectCognitionSafeCode -Value $_.Exception.Message -Fallback 'github_transport_unavailable'
                if ($code -eq 'github_cli_unavailable') { throw $code }
                if ($code -eq 'github_transport_timeout') { throw $code }
                throw 'github_transport_unavailable'
            }
        }
        finally {
            if ($null -ne $process) { $process.Dispose() }
        }
        Start-Sleep -Milliseconds 250
    }
}

function Get-ProjectCognitionRemotePage {
    param(
        [Parameter(Mandatory)] [string] $Owner,
        [AllowNull()] [string] $Cursor,
        [ValidateRange(1, 100)] [int] $PageSize = 100
    )

    $query = @'
query($login:String!,$cursor:String,$pageSize:Int!) {
  repositoryOwner(login:$login) {
    id
    repositories(first:$pageSize,after:$cursor,orderBy:{field:NAME,direction:ASC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        id
        nameWithOwner
        visibility
        isArchived
        defaultBranchRef { name target { oid } }
        releases(first:1,orderBy:{field:CREATED_AT,direction:DESC}) {
          nodes { id tagName createdAt publishedAt updatedAt isDraft isPrerelease }
        }
      }
    }
  }
}
'@
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($argument in @('api', 'graphql', '--method', 'POST', '-f', "query=$query", '-F', "login=$Owner", '-F', "pageSize=$PageSize")) {
        $arguments.Add($argument)
    }
    if (-not [string]::IsNullOrWhiteSpace($Cursor)) {
        $arguments.Add('-F')
        $arguments.Add("cursor=$Cursor")
    }

    $response = Invoke-ProjectCognitionGhJson -Arguments $arguments.ToArray()
    $ownerNode = $response.data.repositoryOwner
    if ($null -eq $ownerNode) { throw 'github_owner_not_found' }
    $connection = $ownerNode.repositories
    if ($null -eq $connection -or $null -eq $connection.pageInfo) { throw 'remote_metadata_invalid' }
    return [pscustomobject][ordered]@{
        owner_id = [string]$ownerNode.id
        nodes = @($connection.nodes)
        page_info = [pscustomobject][ordered]@{
            has_next_page = [bool]$connection.pageInfo.hasNextPage
            end_cursor = if ($null -eq $connection.pageInfo.endCursor) { $null } else { [string]$connection.pageInfo.endCursor }
        }
    }
}

function Get-ProjectCognitionCanonicalOrigin {
    param([Parameter(Mandatory)] [string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $null
    }
    $output = & git -C $Path remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ([string]($output -join '')).Trim()
}

function Get-ProjectCognitionRemoteCompare {
    param(
        [Parameter(Mandatory)] [string] $NameWithOwner,
        [Parameter(Mandatory)] [string] $BaseOid,
        [Parameter(Mandatory)] [string] $HeadOid,
        [ValidateRange(0, 256)] [int] $MaxFiles
    )

    $response = Invoke-ProjectCognitionGhJson -Arguments @(
        'api', '--method', 'GET', "repos/$NameWithOwner/compare/$BaseOid...$HeadOid"
    )
    $commitTimes = @(
        @(
            foreach ($item in @($response.commits)) {
                $value = if ($null -ne $item.commit -and $null -ne $item.commit.committer) {
                    $item.commit.committer.date
                }
                elseif ($null -ne $item.commit -and $null -ne $item.commit.author) {
                    $item.commit.author.date
                }
                else { $null }
                if ($null -ne $value) { ConvertTo-ProjectCognitionUtc $value }
            }
        ) | Sort-Object
    )
    $totalCommits = [int64]$response.total_commits
    $commitTimeRangeComplete = $totalCommits -gt 0 -and $commitTimes.Count -eq $totalCommits
    return [pscustomobject][ordered]@{
        status = [string]$response.status
        ahead_by = [int64]$response.ahead_by
        behind_by = [int64]$response.behind_by
        total_commits = $totalCommits
        first_committed_at = if (-not $commitTimeRangeComplete) { $null } else { $commitTimes[0] }
        last_committed_at = if (-not $commitTimeRangeComplete) { $null } else { $commitTimes[-1] }
        files = @($response.files)
    }
}

function ConvertTo-ProjectCognitionRepository {
    param([Parameter(Mandatory)] [object] $Node)

    $nodeId = ([string]$Node.id).Trim()
    if ($nodeId -notmatch $script:ProjectCognitionNodeIdPattern) { throw 'remote_metadata_invalid' }
    $name = ([string]$Node.nameWithOwner).Trim()
    if ($name -notmatch '^[^/\s]{1,100}/[^/\s]{1,100}$') { throw 'remote_metadata_invalid' }
    $visibility = ([string]$Node.visibility).Trim().ToUpperInvariant()
    if ($visibility -notin @('PUBLIC', 'PRIVATE', 'INTERNAL')) { throw 'remote_metadata_invalid' }

    $defaultBranch = $null
    if ($null -ne $Node.defaultBranchRef) {
        $branchName = ([string]$Node.defaultBranchRef.name).Trim()
        $oid = ([string]$Node.defaultBranchRef.target.oid).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($branchName) -or $branchName.Length -gt 255 -or
            $branchName -match '[\x00-\x1f]' -or $oid -notmatch $script:ProjectCognitionOidPattern) {
            throw 'remote_metadata_invalid'
        }
        $defaultBranch = [pscustomobject][ordered]@{ name = $branchName; oid = $oid }
    }

    $release = $null
    $releaseSentinel = 'none'
    $releaseNodes = @()
    if ($null -ne $Node.releases) { $releaseNodes = @($Node.releases.nodes) }
    if ($releaseNodes.Count -gt 1) { throw 'remote_metadata_invalid' }
    if ($releaseNodes.Count -eq 1) {
        $releaseNode = $releaseNodes[0]
        $releaseId = ([string]$releaseNode.id).Trim()
        $tagName = ([string]$releaseNode.tagName).Trim()
        if ($releaseId -notmatch $script:ProjectCognitionNodeIdPattern -or
            [string]::IsNullOrWhiteSpace($tagName) -or $tagName.Length -gt 255 -or $tagName -match '[\x00-\x1f]') {
            throw 'remote_metadata_invalid'
        }
        $release = [pscustomobject][ordered]@{
            node_id = $releaseId
            tag_name = $tagName
            created_at = ConvertTo-ProjectCognitionUtc $releaseNode.createdAt
            published_at = ConvertTo-ProjectCognitionUtc $releaseNode.publishedAt
            updated_at = ConvertTo-ProjectCognitionUtc $releaseNode.updatedAt
            draft = [bool]$releaseNode.isDraft
            prerelease = [bool]$releaseNode.isPrerelease
        }
        $sentinelPayload = @(
            $release.node_id, $release.tag_name, $release.created_at,
            $release.published_at, $release.updated_at,
            ([string]$release.draft).ToLowerInvariant(),
            ([string]$release.prerelease).ToLowerInvariant()
        ) -join "`n"
        $releaseSentinel = 'sha256:' + (Get-ProjectCognitionSha256 -Text $sentinelPayload)
    }

    return [pscustomobject][ordered]@{
        repository_key = "repository:github:$nodeId"
        node_id = $nodeId
        name_with_owner = $name
        visibility = $visibility
        archived = [bool]$Node.isArchived
        default_branch = $defaultBranch
        release = $release
        release_sentinel = $releaseSentinel
    }
}

function New-ProjectCognitionGap {
    param(
        [Parameter(Mandatory)] [string] $Code,
        [AllowNull()] [string] $RepositoryNodeId = $null,
        [AllowNull()] [string] $Repository = $null
    )

    [pscustomobject][ordered]@{
        code = ConvertTo-ProjectCognitionSafeCode -Value $Code -Fallback 'provider_gap'
        repository_node_id = if ([string]::IsNullOrWhiteSpace($RepositoryNodeId)) { $null } else { $RepositoryNodeId }
        repository = if ([string]::IsNullOrWhiteSpace($Repository)) { $null } else { $Repository }
    }
}

function Invoke-ProjectCognitionSource {
    [CmdletBinding()]
    param(
        [ValidatePattern('^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$')]
        [string] $Owner = 'wlyaaaaa',
        [Parameter(Mandatory)] [string] $RepoRoot,
        [ValidateRange(1, 20)] [int] $MaxPages = 20,
        [ValidateRange(1, 2000)] [int] $MaxRepositories = 1000,
        [ValidateRange(0, 256)] [int] $MaxCompareFiles = 64,
        [string] $CompareRepositoryId = '',
        [string] $CompareBaseOid = '',
        [string] $CompareHeadOid = '',
        [scriptblock] $PageReader = ${function:Get-ProjectCognitionRemotePage},
        [scriptblock] $NavigationReader = { param($Root) Get-GitHubIndexPrivateNavigationEntries -RepoRoot $Root },
        [scriptblock] $OriginReader = ${function:Get-ProjectCognitionCanonicalOrigin},
        [scriptblock] $CompareReader = ${function:Get-ProjectCognitionRemoteCompare},
        [DateTimeOffset] $ObservedAt = [DateTimeOffset]::UtcNow
    )

    $normalizedOwner = $Owner.Trim().ToLowerInvariant()
    $inventoryGaps = [Collections.Generic.List[object]]::new()
    $repositories = [Collections.Generic.List[object]]::new()
    $nodeIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $ownerNodeId = $null
    $cursor = $null
    $pageCount = 0
    $paginationClosed = $false

    while ($pageCount -lt $MaxPages) {
        $page = & $PageReader $normalizedOwner $cursor 100
        $pageCount++
        $pageOwnerId = ([string]$page.owner_id).Trim()
        if ($pageOwnerId -notmatch $script:ProjectCognitionNodeIdPattern) { throw 'remote_metadata_invalid' }
        if ($null -eq $ownerNodeId) { $ownerNodeId = $pageOwnerId }
        elseif ($ownerNodeId -cne $pageOwnerId) { throw 'owner_identity_changed' }

        foreach ($node in @($page.nodes)) {
            if ($repositories.Count -ge $MaxRepositories) {
                $inventoryGaps.Add((New-ProjectCognitionGap -Code 'repository_limit_reached'))
                break
            }
            try {
                $repository = ConvertTo-ProjectCognitionRepository -Node $node
            }
            catch {
                $inventoryGaps.Add((New-ProjectCognitionGap -Code 'remote_repository_metadata_invalid'))
                continue
            }
            if (-not $nodeIds.Add($repository.node_id)) {
                $inventoryGaps.Add((New-ProjectCognitionGap -Code 'duplicate_repository_node_id' -RepositoryNodeId $repository.node_id))
                continue
            }
            if (-not $names.Add($repository.name_with_owner)) {
                $inventoryGaps.Add((New-ProjectCognitionGap -Code 'duplicate_repository_name' -RepositoryNodeId $repository.node_id -Repository $repository.name_with_owner))
                continue
            }
            $repositories.Add($repository)
        }

        if ($repositories.Count -ge $MaxRepositories -and [bool]$page.page_info.has_next_page) { break }
        if (-not [bool]$page.page_info.has_next_page) {
            $paginationClosed = $true
            break
        }
        $nextCursor = ([string]$page.page_info.end_cursor).Trim()
        if ([string]::IsNullOrWhiteSpace($nextCursor) -or $nextCursor -ceq $cursor) {
            $inventoryGaps.Add((New-ProjectCognitionGap -Code 'pagination_cursor_invalid'))
            break
        }
        $cursor = $nextCursor
    }
    $inventoryGapCodes = @($inventoryGaps | ForEach-Object { $_.code })
    if (-not $paginationClosed -and -not ($inventoryGapCodes -contains 'repository_limit_reached') -and
        -not ($inventoryGapCodes -contains 'pagination_cursor_invalid')) {
        $inventoryGaps.Add((New-ProjectCognitionGap -Code 'pagination_limit_reached'))
    }

    $repositoriesByName = @{}
    $repositoriesById = @{}
    foreach ($repository in $repositories) {
        $repositoriesByName[$repository.name_with_owner.ToLowerInvariant()] = $repository
        $repositoriesById[$repository.node_id] = $repository
    }

    $cloneGaps = [Collections.Generic.List[object]]::new()
    $cloneOccurrences = [Collections.Generic.List[object]]::new()
    $cloneByRepositoryId = @{}
    $navigation = & $NavigationReader $RepoRoot
    if ([string]$navigation.status -ne 'current') {
        $cloneGaps.Add((New-ProjectCognitionGap -Code ('navigation_' + (ConvertTo-ProjectCognitionSafeCode -Value ([string]$navigation.status) -Fallback 'unavailable'))))
    }
    else {
        $navigationEntries = @($navigation.entries)
        if ($navigationEntries.Count -gt $MaxRepositories) {
            $cloneGaps.Add((New-ProjectCognitionGap -Code 'navigation_limit_reached'))
            $navigationEntries = @($navigationEntries | Select-Object -First $MaxRepositories)
        }
        foreach ($entry in $navigationEntries) {
            $entryRepo = ([string]$entry.repo).Trim().ToLowerInvariant()
            if (-not $repositoriesByName.ContainsKey($entryRepo)) {
                $cloneGaps.Add((New-ProjectCognitionGap -Code 'navigation_repo_not_in_live_inventory' -Repository $entryRepo))
                continue
            }
            $repository = $repositoriesByName[$entryRepo]
            if ($cloneByRepositoryId.ContainsKey($repository.node_id)) {
                $cloneGaps.Add((New-ProjectCognitionGap -Code 'multiple_canonical_navigation_entries' -RepositoryNodeId $repository.node_id -Repository $repository.name_with_owner))
                continue
            }
            $path = ([string]$entry.path).Trim()
            if ([string]::IsNullOrWhiteSpace($path) -or $path.Length -gt 1024 -or $path -match '[\x00-\x1f]') {
                $cloneGaps.Add((New-ProjectCognitionGap -Code 'navigation_path_invalid' -RepositoryNodeId $repository.node_id -Repository $repository.name_with_owner))
                continue
            }
            $origin = & $OriginReader $path
            $originRepo = ConvertTo-ProjectCognitionRepoSlug -Remote ([string]$origin)
            if ($originRepo -cne $entryRepo) {
                $cloneGaps.Add((New-ProjectCognitionGap -Code 'navigation_origin_mismatch' -RepositoryNodeId $repository.node_id -Repository $repository.name_with_owner))
                continue
            }
            $occurrence = [pscustomobject][ordered]@{
                occurrence_key = "clone:github:$($repository.node_id):canonical"
                repository_node_id = $repository.node_id
                name_with_owner = $repository.name_with_owner
                path = $path
                origin_verified = $true
            }
            $cloneOccurrences.Add($occurrence)
            $cloneByRepositoryId[$repository.node_id] = $occurrence
        }
    }

    $finalRepositories = @(
        foreach ($repository in $repositories) {
            $clone = if ($cloneByRepositoryId.ContainsKey($repository.node_id)) { $cloneByRepositoryId[$repository.node_id] } else { $null }
            [pscustomobject][ordered]@{
                repository_key = $repository.repository_key
                node_id = $repository.node_id
                name_with_owner = $repository.name_with_owner
                visibility = $repository.visibility
                archived = $repository.archived
                default_branch = $repository.default_branch
                release = $repository.release
                release_sentinel = $repository.release_sentinel
                remote_only = ($null -eq $clone)
                canonical_clone_occurrence_key = if ($null -eq $clone) { $null } else { $clone.occurrence_key }
            }
        }
    )

    $compare = [pscustomobject][ordered]@{
        status = 'not_requested'
        repository_node_id = $null
        base_oid = $null
        head_oid = $null
        ahead_by = $null
        behind_by = $null
        total_commits = $null
        first_committed_at = $null
        last_committed_at = $null
        changed_files = @()
        files_truncated = $false
        gaps = @()
    }
    $hasCompareId = -not [string]::IsNullOrWhiteSpace($CompareRepositoryId)
    $hasCompareBase = -not [string]::IsNullOrWhiteSpace($CompareBaseOid)
    $hasCompareHead = -not [string]::IsNullOrWhiteSpace($CompareHeadOid)
    if ($hasCompareId -xor $hasCompareBase) { throw 'compare_contract_invalid' }
    if ($hasCompareHead -and -not $hasCompareId) { throw 'compare_contract_invalid' }
    if ($hasCompareId) {
        $compareId = $CompareRepositoryId.Trim()
        $baseOid = $CompareBaseOid.Trim().ToLowerInvariant()
        $requestedHeadOid = if ($hasCompareHead) { $CompareHeadOid.Trim().ToLowerInvariant() } else { '' }
        if ($compareId -notmatch $script:ProjectCognitionNodeIdPattern -or $baseOid -notmatch $script:ProjectCognitionOidPattern -or
            ($hasCompareHead -and $requestedHeadOid -notmatch $script:ProjectCognitionOidPattern)) {
            throw 'compare_contract_invalid'
        }
        $compare.repository_node_id = $compareId
        $compare.base_oid = $baseOid
        if (-not $repositoriesById.ContainsKey($compareId)) {
            $compare.status = 'unavailable'
            $compare.gaps = @((New-ProjectCognitionGap -Code 'compare_repository_not_found' -RepositoryNodeId $compareId))
        }
        else {
            $repository = $repositoriesById[$compareId]
            if ($null -eq $repository.default_branch) {
                $compare.status = 'unavailable'
                $compare.gaps = @((New-ProjectCognitionGap -Code 'compare_default_branch_absent' -RepositoryNodeId $compareId -Repository $repository.name_with_owner))
            }
            else {
                $headOid = if ($hasCompareHead) { $requestedHeadOid } else { $repository.default_branch.oid }
                $compare.head_oid = $headOid
                if ($baseOid -ceq $headOid) {
                    $compare.status = 'identical'
                    $compare.ahead_by = [int64]0
                    $compare.behind_by = [int64]0
                    $compare.total_commits = [int64]0
                }
                else {
                    try {
                        $remoteCompare = & $CompareReader $repository.name_with_owner $baseOid $headOid $MaxCompareFiles
                        $remoteStatus = ([string]$remoteCompare.status).Trim().ToLowerInvariant()
                        if ($remoteStatus -notin @('ahead', 'behind', 'diverged', 'identical')) { throw 'remote_compare_invalid' }
                        $compare.status = $remoteStatus
                        $compare.ahead_by = [int64]$remoteCompare.ahead_by
                        $compare.behind_by = [int64]$remoteCompare.behind_by
                        $compare.total_commits = [int64]$remoteCompare.total_commits
                        $compare.first_committed_at = $remoteCompare.first_committed_at
                        $compare.last_committed_at = $remoteCompare.last_committed_at
                        $files = @($remoteCompare.files)
                        $boundedFiles = @(
                            foreach ($file in @($files | Select-Object -First $MaxCompareFiles)) {
                                $filename = ([string]$file.filename).Trim()
                                $fileStatus = ([string]$file.status).Trim().ToLowerInvariant()
                                if ([string]::IsNullOrWhiteSpace($filename) -or $filename.Length -gt 512 -or $filename -match '[\x00-\x1f]' -or
                                    $fileStatus -notmatch '^[a-z_]{1,32}$') { continue }
                                [pscustomobject][ordered]@{
                                    path = $filename
                                    status = $fileStatus
                                    additions = [int64]$file.additions
                                    deletions = [int64]$file.deletions
                                    changes = [int64]$file.changes
                                }
                            }
                        )
                        $compare.changed_files = $boundedFiles
                        $compare.files_truncated = ($files.Count -gt $MaxCompareFiles)
                        if ($compare.files_truncated) {
                            $compare.gaps = @((New-ProjectCognitionGap -Code 'compare_files_truncated' -RepositoryNodeId $compareId -Repository $repository.name_with_owner))
                        }
                    }
                    catch {
                        $compare.status = 'unavailable'
                        $compare.gaps = @((New-ProjectCognitionGap -Code 'remote_compare_unavailable' -RepositoryNodeId $compareId -Repository $repository.name_with_owner))
                    }
                }
            }
        }
    }

    $inventoryStatus = if ($paginationClosed -and $inventoryGaps.Count -eq 0) { 'complete' } else { 'partial' }
    $cloneStatus = if ([string]$navigation.status -eq 'current' -and $cloneGaps.Count -eq 0) { 'complete' } else { 'partial' }
    return [pscustomobject][ordered]@{
        schema = $script:ProjectCognitionSchema
        status = if ($inventoryStatus -eq 'complete' -and $cloneStatus -eq 'complete') { 'complete' } else { 'partial' }
        observed_at = $ObservedAt.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        source = [pscustomobject][ordered]@{
            source_key = "github.owner:$ownerNodeId"
            root_locator = "github://owner/$ownerNodeId/repositories"
            owner_node_id = $ownerNodeId
            owner_login = $normalizedOwner
        }
        coverage = [pscustomobject][ordered]@{
            status = $inventoryStatus
            pagination_closed = $paginationClosed
            page_count = $pageCount
            repository_count = $finalRepositories.Count
            max_pages = $MaxPages
            max_repositories = $MaxRepositories
            gaps = @($inventoryGaps)
        }
        repositories = $finalRepositories
        clone_coverage = [pscustomobject][ordered]@{
            status = $cloneStatus
            navigation_status = [string]$navigation.status
            occurrence_count = $cloneOccurrences.Count
            gaps = @($cloneGaps)
        }
        clone_occurrences = @($cloneOccurrences)
        compare = $compare
        bounds = [pscustomobject][ordered]@{
            repositories = $MaxRepositories
            pages = $MaxPages
            compare_files = $MaxCompareFiles
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = $null
    $exitCode = 0
    try {
        $result = Invoke-ProjectCognitionSource -Owner $Owner -RepoRoot $RepoRoot `
            -MaxPages $MaxPages -MaxRepositories $MaxRepositories `
            -MaxCompareFiles $MaxCompareFiles `
            -CompareRepositoryId $CompareRepositoryId -CompareBaseOid $CompareBaseOid `
            -CompareHeadOid $CompareHeadOid
    }
    catch {
        $exitCode = 2
        $result = [pscustomobject][ordered]@{
            schema = $script:ProjectCognitionSchema
            status = 'error'
            reason = ConvertTo-ProjectCognitionSafeCode -Value $_.Exception.Message
            observed_at = [DateTimeOffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        }
    }

    if ($Json) { $result | ConvertTo-Json -Depth 12 -Compress }
    else { $result }
    exit $exitCode
}
