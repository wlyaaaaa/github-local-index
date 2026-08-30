Set-StrictMode -Version Latest

function Read-GitArtifactGovernanceRegistry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'Git artifact governance registry is missing.'
    }
    try {
        $registry = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
    }
    catch {
        throw 'Git artifact governance registry is not valid JSON.'
    }
    if ($null -eq $registry -or
        $null -eq $registry.PSObject.Properties['schema'] -or
        [string] $registry.schema -ne 'github-local-index.git-artifact-governance.v1' -or
        $null -eq $registry.PSObject.Properties['entries'] -or
        $null -eq $registry.PSObject.Properties['retentions']) {
        throw 'Git artifact governance registry has an unsupported schema.'
    }

    $seenRefs = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($entry in @($registry.entries)) {
        if ([string] $entry.repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
            [string]::IsNullOrWhiteSpace([string] $entry.owner) -or
            $null -eq $entry.PSObject.Properties['refs'] -or @($entry.refs).Count -eq 0) {
            throw 'Git artifact governance registry contains an invalid owner entry.'
        }
        foreach ($ref in @($entry.refs)) {
            $logicalRef = ([string] $ref).Trim() -replace '^refs/heads/', '' -replace '^origin/', ''
            if ([string]::IsNullOrWhiteSpace($logicalRef) -or
                -not $seenRefs.Add("$([string] $entry.repo)|$logicalRef")) {
                throw 'Git artifact governance registry contains an invalid or duplicate ref.'
            }
        }
    }

    $seenRepositoryOverrides = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    if ($null -ne $registry.PSObject.Properties['repository_overrides']) {
        foreach ($entry in @($registry.repository_overrides)) {
            if ([string] $entry.repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
                [string] $entry.policy -ne 'frozen_history' -or
                [string]::IsNullOrWhiteSpace([string] $entry.owner) -or
                [string]::IsNullOrWhiteSpace([string] $entry.purpose) -or
                [string]::IsNullOrWhiteSpace([string] $entry.exit_condition) -or
                -not $seenRepositoryOverrides.Add([string] $entry.repo)) {
                throw 'Git artifact governance registry contains an invalid repository override.'
            }
        }
    }

    $seenRetentions = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($entry in @($registry.retentions)) {
        if ([string] $entry.repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
            -not [System.IO.Path]::IsPathRooted([string] $entry.path) -or
            [string] $entry.head -notmatch '^[0-9a-fA-F]{40}$' -or
            [string] $entry.disposition -ne 'retain' -or
            [string]::IsNullOrWhiteSpace([string] $entry.owner) -or
            [string]::IsNullOrWhiteSpace([string] $entry.purpose) -or
            [string]::IsNullOrWhiteSpace([string] $entry.exit_condition)) {
            throw 'Git artifact governance registry contains an invalid retention entry.'
        }
        $retentionKey = "$([string] $entry.repo)|$([string] $entry.path)|$([string] $entry.head)"
        if (-not $seenRetentions.Add($retentionKey)) {
            throw 'Git artifact governance registry contains a duplicate retention entry.'
        }
    }
    return $registry
}

$script:AdmissionSchema = 'github-local-index.project-admission.v1'
$script:ExternalGovernanceRepositories = @()
$script:PublicExposurePolicyPath = Join-Path $PSScriptRoot 'PublicExposurePolicy.psd1'
$script:PublicExposurePolicy = Import-PowerShellDataFile -LiteralPath $script:PublicExposurePolicyPath
$script:GitArtifactGovernancePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'config/git-artifact-governance.json'
$script:GitArtifactGovernance = Read-GitArtifactGovernanceRegistry -Path $script:GitArtifactGovernancePath
if ([string] $script:PublicExposurePolicy.Schema -cne 'github-local-index.public-exposure-path-policy.v2' -or
    [string]::IsNullOrWhiteSpace([string] $script:PublicExposurePolicy.AlwaysBlockedPathRegex) -or
    [string]::IsNullOrWhiteSpace([string] $script:PublicExposurePolicy.ReviewCandidatePathRegex) -or
    [string]::IsNullOrWhiteSpace([string] $script:PublicExposurePolicy.EnvPathRegex) -or
    [string]::IsNullOrWhiteSpace([string] $script:PublicExposurePolicy.AllowedTemplateRegex)) {
    throw 'Public exposure policy has an unsupported schema or is missing a required path expression.'
}

function Invoke-ExternalCommandResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $FilePath,
        [string[]] $ArgumentList = @(),
        [string] $WorkingDirectory
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }
    foreach ($argument in $ArgumentList) {
        [void] $startInfo.ArgumentList.Add([string] $argument)
    }

    $process = $null
    try {
        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        [void] $process.Start()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        return [pscustomobject]@{
            exit_code = [int] $process.ExitCode
            stdout = $stdout.TrimEnd("`r", "`n")
            stderr = $stderr.TrimEnd("`r", "`n")
        }
    }
    catch {
        return [pscustomobject]@{
            exit_code = 127
            stdout = ''
            stderr = "Unable to start external command '$FilePath'."
        }
    }
    finally {
        if ($process) {
            $process.Dispose()
        }
    }
}

function Invoke-GitCommandResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string[]] $Arguments
    )

    $gitArguments = @('-C', $Path) + @($Arguments)
    Invoke-ExternalCommandResult -FilePath 'git.exe' -ArgumentList $gitArguments
}

function ConvertTo-GitHubRepoSlug {
    [CmdletBinding()]
    param([AllowNull()] [string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $text = $Value.Trim() -replace '\\', '/'
    if ($text -match '^git@github\.com:(?<owner>[^/]+)/(?<repo>[^/#?]+?)(?:\.git)?$') {
        return "$($matches['owner'])/$($matches['repo'])"
    }

    if ($text -match '^ssh://(?:[^/@]+@)?github\.com/(?<owner>[^/]+)/(?<repo>[^/#?]+?)(?:\.git)?/?$') {
        return "$($matches['owner'])/$($matches['repo'])"
    }

    if ($text -match '^(?<owner>[A-Za-z0-9_.-]+)/(?<repo>[A-Za-z0-9_.-]+?)(?:\.git)?$') {
        return "$($matches['owner'])/$($matches['repo'])"
    }

    try {
        $uri = [uri] $text
        if ($uri.IsAbsoluteUri -and $uri.Host -ieq 'github.com') {
            $parts = @($uri.AbsolutePath.Trim('/') -split '/')
            if ($parts.Count -eq 2) {
                $repo = $parts[1] -replace '\.git$', ''
                if ($parts[0] -match '^[A-Za-z0-9_.-]+$' -and $repo -match '^[A-Za-z0-9_.-]+$') {
                    return "$($parts[0])/$repo"
                }
            }
        }
    }
    catch {
        return $null
    }

    return $null
}

function Test-IsExternallyGovernedGitHubRepository {
    [CmdletBinding()]
    param([AllowNull()] [string] $Repo)

    $normalized = ConvertTo-GitHubRepoSlug $Repo
    return $normalized -and @($script:ExternalGovernanceRepositories | Where-Object { $_ -ieq $normalized }).Count -gt 0
}

function Get-GitArtifactGovernance {
    [CmdletBinding()]
    param(
        [AllowNull()] [string] $Repo,
        [AllowNull()] [string] $Branch
    )

    $normalizedRepo = ConvertTo-GitHubRepoSlug $Repo
    if (-not $normalizedRepo -or
        [string]::IsNullOrWhiteSpace($Branch) -or
        $null -eq $script:GitArtifactGovernance -or
        $script:GitArtifactGovernance.schema -ne 'github-local-index.git-artifact-governance.v1') {
        return $null
    }
    $logicalBranch = $Branch.Trim() -replace '^refs/heads/', '' -replace '^origin/', ''
    foreach ($entry in @($script:GitArtifactGovernance.entries)) {
        if (-not ([string] $entry.repo).Equals(
            $normalizedRepo,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            continue
        }
        if (@($entry.refs | Where-Object {
            ([string] $_).Equals($logicalBranch, [System.StringComparison]::OrdinalIgnoreCase)
        }).Count -eq 0) {
            continue
        }
        return [pscustomobject]@{
            owner = [string] $entry.owner
            reason = 'explicit_artifact_owner'
        }
    }
    return $null
}

function Get-GitRepositoryOverride {
    [CmdletBinding()]
    param([AllowNull()] [string] $Repo)

    $normalizedRepo = ConvertTo-GitHubRepoSlug $Repo
    if (-not $normalizedRepo -or
        $null -eq $script:GitArtifactGovernance -or
        $script:GitArtifactGovernance.schema -ne 'github-local-index.git-artifact-governance.v1' -or
        $null -eq $script:GitArtifactGovernance.PSObject.Properties['repository_overrides']) {
        return $null
    }

    foreach ($entry in @($script:GitArtifactGovernance.repository_overrides)) {
        if (-not ([string] $entry.repo).Equals(
            $normalizedRepo,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or [string] $entry.policy -ne 'frozen_history') {
            continue
        }
        if ([string]::IsNullOrWhiteSpace([string] $entry.owner) -or
            [string]::IsNullOrWhiteSpace([string] $entry.purpose) -or
            [string]::IsNullOrWhiteSpace([string] $entry.exit_condition)) {
            return $null
        }
        return [pscustomobject]@{
            policy = [string] $entry.policy
            owner = [string] $entry.owner
            purpose = [string] $entry.purpose
            exit_condition = [string] $entry.exit_condition
            reason = 'explicit_repository_override'
        }
    }
    return $null
}

function Get-GitArtifactRetention {
    [CmdletBinding()]
    param(
        [AllowNull()] [string] $Repo,
        [AllowNull()] [string] $Path,
        [AllowNull()] [string] $Head
    )

    $normalizedRepo = ConvertTo-GitHubRepoSlug $Repo
    if (-not $normalizedRepo -or
        [string]::IsNullOrWhiteSpace($Path) -or
        $Head -notmatch '^[0-9a-fA-F]{40}$' -or
        $null -eq $script:GitArtifactGovernance -or
        $script:GitArtifactGovernance.schema -ne 'github-local-index.git-artifact-governance.v1') {
        return $null
    }

    try {
        $normalizedPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/') -replace '/', '\'
    }
    catch {
        return $null
    }

    foreach ($entry in @($script:GitArtifactGovernance.retentions)) {
        if (-not ([string] $entry.repo).Equals(
            $normalizedRepo,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or [string] $entry.disposition -ne 'retain') {
            continue
        }
        try {
            $entryPath = [System.IO.Path]::GetFullPath([string] $entry.path).TrimEnd('\', '/') -replace '/', '\'
        }
        catch {
            continue
        }
        if (-not $entryPath.Equals($normalizedPath, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not ([string] $entry.head).Equals($Head, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        if ([string]::IsNullOrWhiteSpace([string] $entry.owner) -or
            [string]::IsNullOrWhiteSpace([string] $entry.purpose) -or
            [string]::IsNullOrWhiteSpace([string] $entry.exit_condition)) {
            return $null
        }
        return [pscustomobject]@{
            owner = [string] $entry.owner
            purpose = [string] $entry.purpose
            exit_condition = [string] $entry.exit_condition
            reason = 'explicit_necessary_retention'
        }
    }
    return $null
}

function Test-IsExternallyGovernedLocalPath {
    [CmdletBinding()]
    param([AllowNull()] [string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    return $false
}

function ConvertTo-PublicGitHubRemoteUrl {
    [CmdletBinding()]
    param([AllowNull()] [string] $Value)

    $slug = ConvertTo-GitHubRepoSlug $Value
    if (-not $slug) {
        return $null
    }

    $text = $Value.Trim()
    if ($text -match '^https?://') {
        try {
            $uri = [uri] $text
            if (-not [string]::IsNullOrEmpty($uri.UserInfo) -or -not [string]::IsNullOrEmpty($uri.Query) -or -not [string]::IsNullOrEmpty($uri.Fragment)) {
                return "https://github.com/$slug.git"
            }
        }
        catch {
            return $null
        }
    }

    return $text
}

function ConvertTo-NormalizedGitPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string] $Path)

    try {
        return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    }
    catch {
        return $Path.Trim().TrimEnd('\', '/')
    }
}

function ConvertFrom-GitWorktreePorcelain {
    [CmdletBinding()]
    param([AllowEmptyString()] [string] $Text)

    $records = [System.Collections.Generic.List[object]]::new()
    $current = $null
    foreach ($line in @($Text -split "`r?`n")) {
        if ($line -match '^worktree\s+(?<value>.+)$') {
            if ($current) {
                $records.Add([pscustomobject] $current)
            }
            $current = [ordered]@{
                path = ConvertTo-NormalizedGitPath $matches['value']
                listed_head = $null
                listed_branch = $null
                listed_detached = $false
                locked = $false
                lock_reason = $null
                prunable = $false
                prune_reason = $null
            }
            continue
        }
        if (-not $current -or [string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        if ($line -match '^HEAD\s+(?<value>[0-9a-fA-F]+)$') {
            $current.listed_head = $matches['value'].ToLowerInvariant()
        }
        elseif ($line -match '^branch\s+refs/heads/(?<value>.+)$') {
            $current.listed_branch = $matches['value']
        }
        elseif ($line -eq 'detached') {
            $current.listed_detached = $true
        }
        elseif ($line -match '^locked(?:\s+(?<value>.*))?$') {
            $current.locked = $true
            $current.lock_reason = if ($matches['value']) { $matches['value'] } else { $null }
        }
        elseif ($line -match '^prunable(?:\s+(?<value>.*))?$') {
            $current.prunable = $true
            $current.prune_reason = if ($matches['value']) { $matches['value'] } else { $null }
        }
    }
    if ($current) {
        $records.Add([pscustomobject] $current)
    }

    return @($records)
}

function Get-PublicExposurePathAssessment {
    [CmdletBinding()]
    param([AllowNull()] [string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject][ordered]@{
            path = $null
            always_blocked = $false
            review_candidate = $false
            reason = $null
        }
    }

    $normalized = $Path.Trim(' ', '"') -replace '\\', '/'
    $alwaysBlocked = $normalized -match ('(?i)' + [string] $script:PublicExposurePolicy.AlwaysBlockedPathRegex)
    $envPath = $normalized -match ('(?i)' + [string] $script:PublicExposurePolicy.EnvPathRegex)
    $allowedTemplate = $normalized -match ('(?i)' + [string] $script:PublicExposurePolicy.AllowedTemplateRegex)
    if ($envPath -and -not $allowedTemplate) {
        $alwaysBlocked = $true
    }

    $reviewCandidate = (-not $alwaysBlocked) -and
        ($normalized -match ('(?i)' + [string] $script:PublicExposurePolicy.ReviewCandidatePathRegex))
    $reason = if ($alwaysBlocked) {
        'secret_or_credential_path'
    }
    elseif ($reviewCandidate) {
        'review_candidate_path'
    }
    else {
        $null
    }

    [pscustomobject][ordered]@{
        path = $normalized
        always_blocked = [bool] $alwaysBlocked
        review_candidate = [bool] $reviewCandidate
        reason = $reason
    }
}

function Test-PublicExposurePath {
    [CmdletBinding()]
    param([AllowNull()] [string] $Path)

    return [bool] (Get-PublicExposurePathAssessment -Path $Path).always_blocked
}

function ConvertFrom-GitStatusPorcelainV1Z {
    [CmdletBinding()]
    param([AllowEmptyString()] [string] $Text)

    $entries = [System.Collections.Generic.List[object]]::new()
    $segments = @($Text.Split([char] 0, [System.StringSplitOptions]::RemoveEmptyEntries))
    for ($index = 0; $index -lt $segments.Count; $index++) {
        $segment = [string] $segments[$index]
        if ($segment.Length -lt 3 -or $segment[2] -ne ' ') {
            throw 'Invalid NUL-delimited Git status record.'
        }

        $status = $segment.Substring(0, 2)
        $paths = [System.Collections.Generic.List[string]]::new()
        $paths.Add($segment.Substring(3))
        if ($status -match '[RC]') {
            if ($index + 1 -ge $segments.Count) {
                throw 'Incomplete NUL-delimited Git rename record.'
            }
            $index++
            $paths.Add([string] $segments[$index])
        }

        $entries.Add([pscustomobject]@{
            status = $status
            paths = @($paths)
        })
    }

    return @($entries)
}

function Get-GitDirtySummary {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $Entries)

    $staged = 0
    $unstaged = 0
    $untracked = 0
    $conflicted = 0
    $conflictCodes = @('DD', 'AU', 'UD', 'UA', 'DU', 'AA', 'UU')

    foreach ($entry in @($Entries)) {
        $status = [string] $entry.status
        if ($status -in $conflictCodes) {
            $conflicted++
            continue
        }
        if ($status -eq '??') {
            $untracked++
            continue
        }
        if ($status.Length -ge 2) {
            if ($status[0] -ne ' ') { $staged++ }
            if ($status[1] -ne ' ') { $unstaged++ }
        }
    }

    [pscustomobject][ordered]@{
        total = @($Entries).Count
        staged = $staged
        unstaged = $unstaged
        untracked = $untracked
        conflicted = $conflicted
    }
}

function New-UnknownGitDirtySummary {
    [pscustomobject][ordered]@{
        total = $null
        staged = $null
        unstaged = $null
        untracked = $null
        conflicted = $null
    }
}

function Get-GitSyncState {
    [CmdletBinding()]
    param(
        [AllowNull()] [string] $Upstream,
        [AllowNull()] [Nullable[int]] $Ahead,
        [AllowNull()] [Nullable[int]] $Behind,
        [bool] $InspectionError = $false
    )

    if ($InspectionError) { return 'unknown' }
    if ([string]::IsNullOrWhiteSpace($Upstream)) { return 'no_upstream' }
    if ($null -eq $Ahead -or $null -eq $Behind) { return 'unknown' }
    if ($Ahead -gt 0 -and $Behind -gt 0) { return 'diverged' }
    if ($Ahead -gt 0) { return 'ahead' }
    if ($Behind -gt 0) { return 'behind' }
    return 'in_sync'
}

function Get-GitStatusObservation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string] $Path)

    $result = Invoke-GitCommandResult -Path $Path -Arguments @('status', '--porcelain=v1', '-z', '--untracked-files=all')
    if ($result.exit_code -ne 0) {
        return [pscustomobject]@{
            dirty_count = $null
            dirty_summary = New-UnknownGitDirtySummary
            public_exposure_conflict = $false
            public_exposure_review_candidates = @()
            error = $true
        }
    }

    try {
        $entries = @(ConvertFrom-GitStatusPorcelainV1Z -Text $result.stdout)
    }
    catch {
        return [pscustomobject]@{
            dirty_count = $null
            dirty_summary = New-UnknownGitDirtySummary
            public_exposure_conflict = $false
            public_exposure_review_candidates = @()
            error = $true
        }
    }
    $dirtySummary = Get-GitDirtySummary -Entries $entries
    $exposureConflict = $false
    $reviewCandidates = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $entries) {
        $status = [string] $entry.status
        if ($status -in @('D ', ' D')) {
            continue
        }

        $candidatePaths = @($entry.paths)
        if ($status -match '[RC]' -and $candidatePaths.Count -gt 0) {
            $candidatePaths = @($candidatePaths[0])
        }
        foreach ($candidate in $candidatePaths) {
            $assessment = Get-PublicExposurePathAssessment -Path $candidate
            if ($assessment.always_blocked) {
                $exposureConflict = $true
                break
            }
            if ($assessment.review_candidate -and -not $reviewCandidates.Contains($assessment.path)) {
                $reviewCandidates.Add($assessment.path)
            }
        }
        if ($exposureConflict) { break }
    }

    return [pscustomobject]@{
        dirty_count = $dirtySummary.total
        dirty_summary = $dirtySummary
        public_exposure_conflict = $exposureConflict
        public_exposure_review_candidates = @($reviewCandidates | Sort-Object -Unique)
        error = $false
    }
}

function Get-GitDefaultBranchIntegrationEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $DefaultBranch,
        [Parameter(Mandatory = $true)] [string] $Head,
        [AllowNull()] [string] $Branch
    )

    $result = [ordered]@{
        integration_state = 'unknown'
        is_default_branch = $false
        # Completion evidence must come from the remote-tracking default ref.
        # A local branch with the same name is not proof that the remote has
        # absorbed the worktree commit.
        default_ref = if ([string]::IsNullOrWhiteSpace($DefaultBranch)) { $null } else { "refs/remotes/origin/$DefaultBranch" }
        default_head = $null
        default_only_commits = $null
        unique_commits_vs_default = $null
        missing_default_commits = $null
        patch_equivalent = $null
        inspection_error = $true
    }
    if ([string]::IsNullOrWhiteSpace($DefaultBranch) -or
        [string]::IsNullOrWhiteSpace($Head) -or
        -not (Test-Path -LiteralPath $Path -PathType Container)) {
        return [pscustomobject] $result
    }

    $remoteDefaultRef = "refs/remotes/origin/$DefaultBranch"
    $remoteDefaultResult = Invoke-GitCommandResult -Path $Path -Arguments @(
        'rev-parse', '--verify', "$remoteDefaultRef^{commit}"
    )
    $defaultRef = $remoteDefaultRef
    $result.default_ref = $defaultRef
    # Do not fall back to refs/heads/<default>.  Without a remote-tracking
    # ref the remote state is unknown and all integration decisions fail
    # closed.
    $defaultResult = $remoteDefaultResult
    if ($defaultResult.exit_code -ne 0 -or $defaultResult.stdout -notmatch '^[0-9a-fA-F]{40}$') {
        return [pscustomobject] $result
    }
    $result.default_head = $defaultResult.stdout.ToLowerInvariant()
    $result.is_default_branch = -not [string]::IsNullOrWhiteSpace($Branch) -and
        $Branch.Equals($DefaultBranch, [System.StringComparison]::OrdinalIgnoreCase)
    if ($result.is_default_branch -and
        $Head.Equals($result.default_head, [System.StringComparison]::OrdinalIgnoreCase)) {
        $result.integration_state = 'default'
        $result.default_only_commits = 0
        $result.unique_commits_vs_default = 0
        $result.missing_default_commits = 0
        $result.patch_equivalent = $true
        $result.inspection_error = $false
        return [pscustomobject] $result
    }

    $distanceResult = Invoke-GitCommandResult -Path $Path -Arguments @(
        'rev-list', '--left-right', '--count', "$defaultRef...$Head"
    )
    if ($distanceResult.exit_code -ne 0 -or
        $distanceResult.stdout -notmatch '^(?<default>\d+)\s+(?<branch>\d+)$') {
        return [pscustomobject] $result
    }

    $defaultOnly = [int] $matches['default']
    $branchOnly = [int] $matches['branch']
    $result.default_only_commits = $defaultOnly
    $result.unique_commits_vs_default = $branchOnly
    $result.inspection_error = $false
    if ($branchOnly -eq 0) {
        $result.integration_state = 'merged_ancestry'
        $result.missing_default_commits = 0
        $result.patch_equivalent = $true
        return [pscustomobject] $result
    }

    $cherryResult = Invoke-GitCommandResult -Path $Path -Arguments @('cherry', $defaultRef, $Head)
    if ($cherryResult.exit_code -eq 0) {
        $cherryLines = @(
            $cherryResult.stdout -split "\r?\n" |
                ForEach-Object { ([string] $_).Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        $plusCount = @($cherryLines | Where-Object { $_ -match '^\+' }).Count
        $minusCount = @($cherryLines | Where-Object { $_ -match '^-' }).Count
        if ($plusCount -eq 0 -and $minusCount -gt 0) {
            $result.integration_state = 'patch_equivalent'
            $result.missing_default_commits = 0
            $result.patch_equivalent = $true
            return [pscustomobject] $result
        }
        $result.integration_state = 'unmerged'
        $result.missing_default_commits = if ($plusCount -gt 0) { $plusCount } else { $branchOnly }
        $result.patch_equivalent = $false
        return [pscustomobject] $result
    }

    $result.integration_state = 'unmerged'
    $result.missing_default_commits = $branchOnly
    $result.patch_equivalent = $false
    return [pscustomobject] $result
}

function Add-GitDefaultBranchIntegrationEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $DefaultBranch,
        [object[]] $Worktrees = @()
    )

    foreach ($worktree in @($Worktrees)) {
        $evidence = if ($worktree.exists -and -not $worktree.prunable -and
            -not [string]::IsNullOrWhiteSpace([string] $worktree.head)) {
            Get-GitDefaultBranchIntegrationEvidence `
                -Path ([string] $worktree.path) `
                -DefaultBranch $DefaultBranch `
                -Head ([string] $worktree.head) `
                -Branch ([string] $worktree.branch)
        }
        else {
            [pscustomobject]@{
                integration_state = 'unknown'
                is_default_branch = $false
                default_ref = "refs/heads/$DefaultBranch"
                default_head = $null
                default_only_commits = $null
                unique_commits_vs_default = $null
                missing_default_commits = $null
                patch_equivalent = $null
                inspection_error = $true
            }
        }
        foreach ($propertyName in @(
            'integration_state', 'is_default_branch', 'default_ref', 'default_head',
            'default_only_commits', 'unique_commits_vs_default',
            'missing_default_commits', 'patch_equivalent'
        )) {
            $worktree | Add-Member -NotePropertyName $propertyName -NotePropertyValue $evidence.$propertyName -Force
        }
    }

    return @($Worktrees)
}

function Get-GitRepositoryBranchInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $DefaultBranch,
        [object[]] $Worktrees = @()
    )

    if ($Worktrees.Count -eq 0) {
        $listResult = Invoke-GitCommandResult -Path $Path -Arguments @('worktree', 'list', '--porcelain')
        if ($listResult.exit_code -eq 0) {
            $Worktrees = @(ConvertFrom-GitWorktreePorcelain -Text $listResult.stdout | ForEach-Object {
                [pscustomobject]@{ path = $_.path; branch = $_.listed_branch }
            })
        }
    }

    $branchResult = Invoke-GitCommandResult -Path $Path -Arguments @(
        'for-each-ref', '--format=%(refname:short)', 'refs/heads'
    )
    if ($branchResult.exit_code -ne 0) {
        throw "Unable to enumerate local branches (exit $($branchResult.exit_code))."
    }

    $branches = @(foreach ($branchName in @(
        $branchResult.stdout -split "\r?\n" |
            ForEach-Object { ([string] $_).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )) {
        $headResult = Invoke-GitCommandResult -Path $Path -Arguments @('rev-parse', '--verify', "refs/heads/$branchName")
        if ($headResult.exit_code -ne 0 -or $headResult.stdout -notmatch '^[0-9a-fA-F]{40}$') {
            continue
        }
        $upstreamResult = Invoke-GitCommandResult -Path $Path -Arguments @(
            'for-each-ref', '--format=%(upstream:short)', "refs/heads/$branchName"
        )
        $upstream = if ($upstreamResult.exit_code -eq 0 -and
            -not [string]::IsNullOrWhiteSpace($upstreamResult.stdout)) {
            $upstreamResult.stdout.Trim()
        }
        else {
            $null
        }
        $matchingWorktree = @($Worktrees | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string] $_.branch) -and
            ([string] $_.branch).Equals($branchName, [System.StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1)
        $hasWorktree = $matchingWorktree.Count -gt 0
        $evidencePath = if ($hasWorktree -and
            -not [string]::IsNullOrWhiteSpace([string] $matchingWorktree[0].path)) {
            [string] $matchingWorktree[0].path
        }
        else {
            $Path
        }
        $evidence = Get-GitDefaultBranchIntegrationEvidence `
            -Path $evidencePath `
            -DefaultBranch $DefaultBranch `
            -Head $headResult.stdout `
            -Branch $branchName

        [pscustomobject]@{
            branch = $branchName
            ref_kind = 'local'
            ref_name = "refs/heads/$branchName"
            head = $headResult.stdout.ToLowerInvariant()
            upstream = $upstream
            has_worktree = $hasWorktree
            worktree_path = if ($hasWorktree) { [string] $matchingWorktree[0].path } else { $null }
            integration_state = $evidence.integration_state
            is_default_branch = $evidence.is_default_branch
            default_only_commits = $evidence.default_only_commits
            unique_commits_vs_default = $evidence.unique_commits_vs_default
            missing_default_commits = $evidence.missing_default_commits
            patch_equivalent = $evidence.patch_equivalent
            retirement_candidate = (-not $hasWorktree) -and
                (-not $evidence.is_default_branch) -and
                $evidence.integration_state -in @('merged_ancestry', 'patch_equivalent')
        }
    })

    $remoteBranchResult = Invoke-GitCommandResult -Path $Path -Arguments @(
        'for-each-ref',
        '--format=%(refname:short)%09%(objectname)',
        'refs/remotes/origin'
    )
    if ($remoteBranchResult.exit_code -eq 0) {
        foreach ($line in @(
            $remoteBranchResult.stdout -split "\r?\n" |
                ForEach-Object { ([string] $_).Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )) {
            if ($line -notmatch '^(?<ref>origin/(?<branch>.+?))\t(?<head>[0-9a-fA-F]{40})$') {
                continue
            }
            $remoteShortRef = [string] $matches['ref']
            $logicalBranch = [string] $matches['branch']
            $remoteHead = ([string] $matches['head']).ToLowerInvariant()
            if ($logicalBranch -eq 'HEAD' -or
                $logicalBranch.Equals($DefaultBranch, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            $sameLocal = @($branches | Where-Object {
                $_.ref_kind -eq 'local' -and
                ([string] $_.branch).Equals($logicalBranch, [System.StringComparison]::OrdinalIgnoreCase) -and
                ([string] $_.head).Equals($remoteHead, [System.StringComparison]::OrdinalIgnoreCase)
            }).Count -gt 0
            if ($sameLocal) {
                continue
            }
            $remoteEvidence = Get-GitDefaultBranchIntegrationEvidence `
                -Path $Path `
                -DefaultBranch $DefaultBranch `
                -Head $remoteHead `
                -Branch $logicalBranch
            $branches += [pscustomobject]@{
                branch = $remoteShortRef
                ref_kind = 'remote_tracking'
                ref_name = "refs/remotes/$remoteShortRef"
                head = $remoteHead
                upstream = $remoteShortRef
                has_worktree = $false
                worktree_path = $null
                integration_state = $remoteEvidence.integration_state
                is_default_branch = $false
                default_only_commits = $remoteEvidence.default_only_commits
                unique_commits_vs_default = $remoteEvidence.unique_commits_vs_default
                missing_default_commits = $remoteEvidence.missing_default_commits
                patch_equivalent = $remoteEvidence.patch_equivalent
                retirement_candidate = $remoteEvidence.integration_state -in @(
                    'merged_ancestry', 'patch_equivalent'
                )
            }
        }
    }

    return @($branches | Sort-Object branch)
}

function Add-GitArtifactGovernanceEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Repo,
        [object[]] $Worktrees = @(),
        [object[]] $Branches = @()
    )

    $repositoryOverride = Get-GitRepositoryOverride -Repo $Repo
    foreach ($artifact in @($Worktrees) + @($Branches)) {
        $branchName = if ($null -ne $artifact.PSObject.Properties['branch']) {
            [string] $artifact.branch
        }
        else {
            $null
        }
        $governance = Get-GitArtifactGovernance -Repo $Repo -Branch $branchName
        $artifact | Add-Member -NotePropertyName external_governance `
            -NotePropertyValue ($null -ne $governance) -Force
        $artifact | Add-Member -NotePropertyName governance_owner `
            -NotePropertyValue $(if ($governance) { [string] $governance.owner } else { $null }) -Force
        $artifact | Add-Member -NotePropertyName governance_reason `
            -NotePropertyValue $(if ($governance) { [string] $governance.reason } else { $null }) -Force
        $isBranchInventoryRecord = $null -ne $artifact.PSObject.Properties['has_worktree']
        $isDefaultBranch = $null -ne $artifact.PSObject.Properties['is_default_branch'] -and
            [bool] $artifact.is_default_branch
        $historicalRetention = $null -ne $repositoryOverride -and
            $isBranchInventoryRecord -and -not $isDefaultBranch
        $artifact | Add-Member -NotePropertyName historical_retention `
            -NotePropertyValue $historicalRetention -Force
        $artifact | Add-Member -NotePropertyName historical_retention_owner `
            -NotePropertyValue $(if ($historicalRetention) { [string] $repositoryOverride.owner } else { $null }) -Force
        $artifact | Add-Member -NotePropertyName historical_retention_purpose `
            -NotePropertyValue $(if ($historicalRetention) { [string] $repositoryOverride.purpose } else { $null }) -Force
        $artifact | Add-Member -NotePropertyName historical_retention_exit_condition `
            -NotePropertyValue $(if ($historicalRetention) { [string] $repositoryOverride.exit_condition } else { $null }) -Force
        $retention = if ($null -ne $artifact.PSObject.Properties['path'] -and
            $null -ne $artifact.PSObject.Properties['head']) {
            Get-GitArtifactRetention `
                -Repo $Repo `
                -Path ([string] $artifact.path) `
                -Head ([string] $artifact.head)
        }
        else {
            $null
        }
        $artifact | Add-Member -NotePropertyName necessary_retention `
            -NotePropertyValue ($null -ne $retention) -Force
        $artifact | Add-Member -NotePropertyName retention_owner `
            -NotePropertyValue $(if ($retention) { [string] $retention.owner } else { $null }) -Force
        $artifact | Add-Member -NotePropertyName retention_purpose `
            -NotePropertyValue $(if ($retention) { [string] $retention.purpose } else { $null }) -Force
        $artifact | Add-Member -NotePropertyName retention_exit_condition `
            -NotePropertyValue $(if ($retention) { [string] $retention.exit_condition } else { $null }) -Force
    }
}

function Get-GitRepositoryWorktrees {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string] $Path)

    $listResult = Invoke-GitCommandResult -Path $Path -Arguments @('worktree', 'list', '--porcelain')
    if ($listResult.exit_code -ne 0) {
        throw "Unable to enumerate Git worktrees (exit $($listResult.exit_code))."
    }

    $observations = foreach ($record in ConvertFrom-GitWorktreePorcelain -Text $listResult.stdout) {
        $exists = Test-Path -LiteralPath $record.path -PathType Container
        $head = $record.listed_head
        $branch = $record.listed_branch
        $detached = [bool] $record.listed_detached
        $upstream = $null
        $ahead = $null
        $behind = $null
        $dirtyCount = $null
        $dirtySummary = New-UnknownGitDirtySummary
        $exposureConflict = $false
        $reviewCandidates = @()
        $inspectionError = $false

        if ($exists) {
            $headResult = Invoke-GitCommandResult -Path $record.path -Arguments @('rev-parse', 'HEAD')
            if ($headResult.exit_code -eq 0 -and $headResult.stdout -match '^[0-9a-fA-F]+$') {
                $head = $headResult.stdout.ToLowerInvariant()
            }
            else {
                $inspectionError = $true
            }

            $branchResult = Invoke-GitCommandResult -Path $record.path -Arguments @('branch', '--show-current')
            if ($branchResult.exit_code -eq 0) {
                $branch = if ([string]::IsNullOrWhiteSpace($branchResult.stdout)) { $null } else { $branchResult.stdout }
                $detached = [string]::IsNullOrWhiteSpace($branch)
            }

            $upstreamResult = Invoke-GitCommandResult -Path $record.path -Arguments @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')
            if ($upstreamResult.exit_code -eq 0 -and -not [string]::IsNullOrWhiteSpace($upstreamResult.stdout)) {
                $upstream = $upstreamResult.stdout
                $countResult = Invoke-GitCommandResult -Path $record.path -Arguments @('rev-list', '--left-right', '--count', 'HEAD...@{u}')
                if ($countResult.exit_code -eq 0 -and $countResult.stdout -match '^(?<ahead>\d+)\s+(?<behind>\d+)$') {
                    $ahead = [int] $matches['ahead']
                    $behind = [int] $matches['behind']
                }
                else {
                    $inspectionError = $true
                }
            }

            $status = Get-GitStatusObservation -Path $record.path
            $dirtyCount = $status.dirty_count
            $dirtySummary = $status.dirty_summary
            $exposureConflict = $status.public_exposure_conflict
            $reviewCandidates = @($status.public_exposure_review_candidates)
            if ($status.error) {
                $inspectionError = $true
            }
        }

        [pscustomobject]@{
            path = $record.path
            exists = $exists
            head = $head
            branch = $branch
            detached = $detached
            upstream = $upstream
            ahead = $ahead
            behind = $behind
            dirty_count = $dirtyCount
            dirty_summary = $dirtySummary
            sync_state = Get-GitSyncState -Upstream $upstream -Ahead $ahead -Behind $behind -InspectionError ($inspectionError -or -not $exists)
            locked = [bool] $record.locked
            prunable = [bool] $record.prunable
            inspection_error = $inspectionError
            public_exposure_conflict = $exposureConflict
            public_exposure_review_candidates = @($reviewCandidates)
        }
    }

    return @($observations | Sort-Object @{ Expression = { ([string] $_.path).ToLowerInvariant() } }, branch, head)
}

function Get-IndexedProjectFacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $IndexRoot,
        [Parameter(Mandatory = $true)] [string] $Repo
    )

    $indexPath = Join-Path $IndexRoot '01_仓库索引/GitHub仓库索引.md'
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
        return $null
    }

    foreach ($line in Get-Content -LiteralPath $indexPath -Encoding utf8) {
        if ($line -notmatch '^\|\s*(?<repo>[^|]+?)\s*\|\s*(?<visibility>[^|]+?)\s*\|\s*(?<branch>[^|]+?)\s*\|\s*(?<paths>[^|]+?)\s*\|') {
            continue
        }
        $rowRepo = ConvertTo-GitHubRepoSlug $matches['repo'].Trim(' ', '`')
        if ($rowRepo -ine $Repo) {
            continue
        }
        $paths = @($matches['paths'] -split '<br>' | ForEach-Object { $_.Trim(' ', '`') } | Where-Object { $_ -and $_ -ne '未发现本地 clone' })
        return [pscustomobject]@{
            # Markdown is only a navigation hint.  Visibility/default branch
            # are deliberately not returned because they are dynamic owner
            # facts and must come from live metadata or an explicit caller.
            source = 'markdown_navigation_hint'
            authoritative = $false
            paths = if (Test-IsExternallyGovernedGitHubRepository -Repo $Repo) { @() } else { $paths }
        }
    }

    return $null
}

function Resolve-AdmissionRepoPath {
    [CmdletBinding()]
    param([string[]] $CandidatePaths)

    $existing = @($CandidatePaths | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | ForEach-Object { ConvertTo-NormalizedGitPath $_ } | Sort-Object -Unique)
    if ($existing.Count -eq 0) {
        return [pscustomobject]@{ path = $null; ambiguous = $false }
    }
    if ($existing.Count -eq 1) {
        return [pscustomobject]@{ path = $existing[0]; ambiguous = $false }
    }

    $commonDirs = foreach ($candidate in $existing) {
        $result = Invoke-GitCommandResult -Path $candidate -Arguments @('rev-parse', '--path-format=absolute', '--git-common-dir')
        if ($result.exit_code -eq 0) { ConvertTo-NormalizedGitPath $result.stdout } else { "missing::$candidate" }
    }
    if (@($commonDirs | Sort-Object -Unique).Count -eq 1) {
        return [pscustomobject]@{ path = $existing[0]; ambiguous = $false }
    }

    return [pscustomobject]@{ path = $null; ambiguous = $true }
}

function Resolve-AdmissionVisibilityValue {
    [CmdletBinding()]
    param([AllowNull()] [string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return [pscustomobject]@{
            present = $false
            valid = $true
            value = $null
        }
    }

    $normalized = $Value.Trim().ToUpperInvariant()
    [pscustomobject]@{
        present = $true
        valid = $normalized -in @('PUBLIC', 'PRIVATE', 'INTERNAL')
        value = if ($normalized -in @('PUBLIC', 'PRIVATE', 'INTERNAL')) { $normalized } else { $null }
    }
}

function ConvertTo-AdmissionTargetRef {
    [CmdletBinding()]
    param([AllowNull()] [string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $normalized = $Value.Trim()
    if ($normalized -match '^[0-9a-fA-F]{40}$') {
        return $normalized.ToLowerInvariant()
    }
    if ($normalized.StartsWith('refs/', [System.StringComparison]::Ordinal)) {
        return $normalized
    }
    return "refs/heads/$normalized"
}

function Resolve-AdmissionTargetScope {
    [CmdletBinding()]
    param(
        [object[]] $Worktrees = @(),
        [string] $TargetWorktree,
        [string] $TargetRef
    )

    $hasTargetWorktree = -not [string]::IsNullOrWhiteSpace($TargetWorktree)
    $hasTargetRef = -not [string]::IsNullOrWhiteSpace($TargetRef)
    if (-not $hasTargetWorktree -and -not $hasTargetRef) {
        return [pscustomobject]@{
            target_worktree = $null
            target_ref = $null
            decision_worktrees = @($Worktrees)
            reasons = @()
        }
    }

    $normalizedTargetWorktree = if ($hasTargetWorktree) { ConvertTo-NormalizedGitPath $TargetWorktree } else { $null }
    $normalizedTargetRef = if ($hasTargetRef) { ConvertTo-AdmissionTargetRef $TargetRef } else { $null }
    $selected = @($Worktrees)
    $reasons = [System.Collections.Generic.List[string]]::new()

    if ($hasTargetWorktree) {
        $selected = @($selected | Where-Object { ([string] $_.path) -ieq $normalizedTargetWorktree })
        if ($selected.Count -eq 0) {
            $reasons.Add('target_worktree_not_found')
        }
    }

    if ($hasTargetRef -and $selected.Count -gt 0) {
        $refMatches = @($selected | Where-Object {
            if ($normalizedTargetRef -match '^refs/heads/(?<branch>.+)$') {
                return ([string] $_.branch) -ceq $matches['branch']
            }
            if ($normalizedTargetRef -match '^[0-9a-f]{40}$') {
                return ([string] $_.head) -ieq $normalizedTargetRef
            }
            return $false
        })
        if ($refMatches.Count -eq 0) {
            $reasons.Add($(if ($hasTargetWorktree) { 'target_scope_mismatch' } else { 'target_ref_not_found' }))
        }
        $selected = $refMatches
    }

    if ($selected.Count -gt 1) {
        $reasons.Add('target_scope_ambiguous')
        $selected = @()
    }
    if ($selected.Count -eq 1 -and (-not $selected[0].exists -or $selected[0].prunable)) {
        $reasons.Add('target_worktree_unavailable')
    }

    $resolvedTargetWorktree = if ($selected.Count -eq 1) { [string] $selected[0].path } else { $normalizedTargetWorktree }
    $resolvedTargetRef = $normalizedTargetRef
    if (-not $resolvedTargetRef -and $selected.Count -eq 1) {
        $resolvedTargetRef = if (-not [string]::IsNullOrWhiteSpace([string] $selected[0].branch)) {
            "refs/heads/$([string] $selected[0].branch)"
        }
        else {
            [string] $selected[0].head
        }
    }

    [pscustomobject]@{
        target_worktree = $resolvedTargetWorktree
        target_ref = $resolvedTargetRef
        decision_worktrees = @($selected)
        reasons = @($reasons)
    }
}

function New-AdmissionError {
    param([string] $Category, [int] $ExitCode)
    [pscustomobject]@{ category = $Category; exit_code = $ExitCode }
}

function Get-ProjectPushGuidance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [ValidateSet('proceed', 'warn', 'block')] [string] $AdmissionDecision,
        [string[]] $Reasons = @(),
        [ValidateSet('cached', 'live')] [string] $RemoteMode = 'cached',
        [object[]] $Worktrees = @()
    )

    if ($AdmissionDecision -eq 'block') {
        $strategy = if (@($Reasons) -contains 'public_exposure_conflict') { 'resolve_public_exposure' } else { 'resolve_admission_block' }
        return [pscustomobject]@{ decision = 'block'; strategy = $strategy }
    }
    if (@($Worktrees | Where-Object { $_.sync_state -eq 'diverged' }).Count -gt 0) {
        return [pscustomobject]@{ decision = 'block'; strategy = 'reconcile_then_recheck' }
    }
    if (@($Worktrees | Where-Object { $_.sync_state -eq 'behind' }).Count -gt 0) {
        return [pscustomobject]@{ decision = 'block'; strategy = 'update_then_recheck' }
    }
    if (@($Worktrees | Where-Object { $null -ne $_.dirty_summary -and $_.dirty_summary.total -gt 0 }).Count -gt 0) {
        return [pscustomobject]@{ decision = 'warn'; strategy = 'clean_or_stage_explicitly' }
    }
    if (@($Reasons) -contains 'default_branch_missing_commits') {
        return [pscustomobject]@{ decision = 'warn'; strategy = 'integrate_default_branch' }
    }
    if (@($Reasons) -contains 'default_branch_integration_unknown') {
        return [pscustomobject]@{ decision = 'warn'; strategy = 'inspect_default_branch_integration' }
    }
    if (@($Reasons) -contains 'merged_residual_worktree' -or
        @($Reasons) -contains 'merged_residual_branch') {
        return [pscustomobject]@{ decision = 'warn'; strategy = 'retire_integrated_branch' }
    }
    if (@($Worktrees | Where-Object { $_.exists -and $_.sync_state -eq 'no_upstream' }).Count -gt 0) {
        return [pscustomobject]@{ decision = 'warn'; strategy = 'set_upstream' }
    }
    if ($RemoteMode -eq 'cached') {
        return [pscustomobject]@{ decision = 'warn'; strategy = 'fetch_recheck' }
    }
    if (@($Worktrees | Where-Object { $_.sync_state -eq 'ahead' }).Count -gt 0) {
        return [pscustomobject]@{ decision = 'proceed'; strategy = 'normal' }
    }
    return [pscustomobject]@{ decision = 'proceed'; strategy = 'none' }
}

function New-ProjectAdmissionRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $ObservedUtc,
        [AllowNull()] [string] $Repo,
        [AllowNull()] [string] $RemoteUrl,
        [AllowNull()] [string] $Visibility,
        [AllowNull()] [string] $DefaultBranch,
        [AllowNull()] [string] $LocalRoot,
        [AllowNull()] [string] $GitCommonDir,
        [ValidateSet('cached', 'live')] [string] $RemoteMode = 'cached',
        [ValidateSet('cached', 'live')] [string] $MetadataMode = 'cached',
        [ValidateSet('cached', 'live')] [string] $RefsMode = 'cached',
        [AllowNull()] [string] $TargetWorktree,
        [AllowNull()] [string] $TargetRef,
        [ValidateSet('proceed', 'warn', 'block')] [string] $Decision = 'block',
        [ValidateSet('proceed', 'warn', 'block')] [string] $PushDecision = 'block',
        [ValidateSet('none', 'normal', 'fetch_recheck', 'clean_or_stage_explicitly', 'set_upstream', 'update_then_recheck', 'reconcile_then_recheck', 'integrate_default_branch', 'inspect_default_branch_integration', 'retire_integrated_branch', 'resolve_public_exposure', 'resolve_admission_block')] [string] $PushStrategy = 'resolve_admission_block',
        [string[]] $Reasons = @(),
        [object[]] $Errors = @(),
        [object[]] $Worktrees = @(),
        [object[]] $Branches = @()
    )

    $liveChecked = (
        $RemoteMode -ceq 'live' -and
        $MetadataMode -ceq 'live' -and
        $RefsMode -ceq 'live'
    )
    $freshness = if ($liveChecked) {
        'live'
    }
    elseif ($MetadataMode -ceq 'live' -or $RefsMode -ceq 'live') {
        'mixed'
    }
    else {
        'cached'
    }

    [pscustomobject][ordered]@{
        schema = $script:AdmissionSchema
        observed_utc = $ObservedUtc
        repo = if ([string]::IsNullOrWhiteSpace($Repo)) { $null } else { $Repo }
        remote_url = if ([string]::IsNullOrWhiteSpace($RemoteUrl)) { $null } else { $RemoteUrl }
        visibility = if ([string]::IsNullOrWhiteSpace($Visibility)) { $null } else { $Visibility }
        default_branch = if ([string]::IsNullOrWhiteSpace($DefaultBranch)) { $null } else { $DefaultBranch }
        local_root = if ([string]::IsNullOrWhiteSpace($LocalRoot)) { $null } else { $LocalRoot }
        git_common_dir = if ([string]::IsNullOrWhiteSpace($GitCommonDir)) { $null } else { $GitCommonDir }
        remote_mode = $RemoteMode
        metadata_mode = $MetadataMode
        refs_mode = $RefsMode
        evidence_source = [pscustomobject][ordered]@{
            local_git = if ([string]::IsNullOrWhiteSpace($LocalRoot)) { 'unavailable' } else { 'live' }
            github_metadata = $MetadataMode
            remote_refs = $RefsMode
        }
        freshness = $freshness
        live_checked = [bool] $liveChecked
        target_worktree = if ([string]::IsNullOrWhiteSpace($TargetWorktree)) { $null } else { $TargetWorktree }
        target_ref = if ([string]::IsNullOrWhiteSpace($TargetRef)) { $null } else { $TargetRef }
        decision = $Decision
        push_decision = $PushDecision
        push_strategy = $PushStrategy
        reasons = @($Reasons)
        errors = @($Errors)
        worktrees = @($Worktrees)
        branches = @($Branches)
    }
}

function Get-ProjectAdmissionRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Repo,
        [string] $RepoPath,
        [string] $Visibility,
        [string] $DefaultBranch,
        [string] $IndexRoot,
        [switch] $Fetch,
        [switch] $LiveMetadata,
        [switch] $RefreshRefs,
        [switch] $ForPublication,
        [string] $TargetWorktree,
        [string] $TargetRef,
        [scriptblock] $FetchInvoker,
        [scriptblock] $GitHubInvoker
    )

    $observedUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    $normalizedRepo = ConvertTo-GitHubRepoSlug $Repo
    $isExternalGovernance = Test-IsExternallyGovernedGitHubRepository -Repo $normalizedRepo
    $reasons = [System.Collections.Generic.List[string]]::new()
    $errors = [System.Collections.Generic.List[object]]::new()
    $worktrees = @()
    $branches = @()
    $remoteSlug = $null
    $remoteUrl = $null
    $localRoot = $null
    $gitCommonDir = $null
    $remoteMode = 'cached'
    $metadataMode = 'cached'
    $refsMode = 'cached'
    $useLiveMetadata = [bool] ($ForPublication -or $LiveMetadata -or $Fetch)
    $useRefreshRefs = [bool] ($ForPublication -or $RefreshRefs -or $Fetch)
    $visibilityWasSupplied = -not [string]::IsNullOrWhiteSpace($Visibility)
    $visibilityInvalidObserved = $false

    if (-not $normalizedRepo) {
        $reasons.Add('invalid_repo')
    }
    elseif ($isExternalGovernance) {
        $reasons.Add('external_governance_excluded')
    }

    if ($visibilityWasSupplied) {
        $visibilityResolution = Resolve-AdmissionVisibilityValue -Value $Visibility
        if ($visibilityResolution.valid) {
            $Visibility = $visibilityResolution.value
        }
        else {
            $Visibility = $null
            $visibilityInvalidObserved = $true
        }
    }

    $facts = $null
    if ($normalizedRepo -and -not [string]::IsNullOrWhiteSpace($IndexRoot)) {
        $facts = Get-IndexedProjectFacts -IndexRoot $IndexRoot -Repo $normalizedRepo
    }
    $candidates = @()
    $navigationHintUsed = $false
    if ($isExternalGovernance) {
        $candidates = @()
    }
    elseif (-not [string]::IsNullOrWhiteSpace($RepoPath)) {
        $candidates = @($RepoPath)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($TargetWorktree)) {
        # An exact target worktree is already a stronger local path hint than
        # a generated or cached navigation entry. Its .git identity is still
        # verified below before any local facts are admitted.
        $candidates = @($TargetWorktree)
    }
    elseif ($facts) {
        $candidates = @($facts.paths)
        $navigationHintUsed = $candidates.Count -gt 0
    }
    $pathResolution = Resolve-AdmissionRepoPath -CandidatePaths $candidates
    if ($pathResolution.ambiguous) {
        $reasons.Add('ambiguous_repo_path')
    }
    elseif ([string]::IsNullOrWhiteSpace($pathResolution.path)) {
        $reasons.Add('missing_repo_path')
    }
    else {
        $RepoPath = $pathResolution.path
        # A Markdown-derived path is untrusted until its .git identity is
        # checked.  This prevents a stale navigation row from causing local
        # facts to be collected from an unrelated repository.
        $remoteResult = Invoke-GitCommandResult -Path $RepoPath -Arguments @('config', '--get', 'remote.origin.url')
        $candidateRemoteSlug = if ($remoteResult.exit_code -eq 0) {
            ConvertTo-GitHubRepoSlug $remoteResult.stdout
        }
        else {
            $null
        }
        $commonResult = Invoke-GitCommandResult -Path $RepoPath -Arguments @('rev-parse', '--path-format=absolute', '--git-common-dir')
        $candidateCommonDir = if ($commonResult.exit_code -eq 0) {
            ConvertTo-NormalizedGitPath $commonResult.stdout
        }
        else {
            $null
        }
        if ($navigationHintUsed -and (-not $candidateRemoteSlug -or
            ($normalizedRepo -and $candidateRemoteSlug -ine $normalizedRepo) -or
            [string]::IsNullOrWhiteSpace($candidateCommonDir))) {
            if (-not $candidateRemoteSlug -or ($normalizedRepo -and $candidateRemoteSlug -ine $normalizedRepo)) {
                $reasons.Add('remote_mismatch')
            }
            if ([string]::IsNullOrWhiteSpace($candidateCommonDir)) {
                $reasons.Add('local_git_identity_unavailable')
            }
            $RepoPath = $null
        }
        else {
            try {
                $worktrees = @(Get-GitRepositoryWorktrees -Path $RepoPath)
            }
            catch {
                $errors.Add((New-AdmissionError -Category 'worktree_enumeration_failed' -ExitCode 1))
                $reasons.Add('missing_repo_path')
            }

            $localRoot = ConvertTo-NormalizedGitPath $RepoPath
            if ($commonResult.exit_code -eq 0) {
                $gitCommonDir = $candidateCommonDir
            }
            if ($remoteResult.exit_code -eq 0) {
                $remoteSlug = $candidateRemoteSlug
                $remoteUrl = ConvertTo-PublicGitHubRemoteUrl $remoteResult.stdout
            }
            if (-not $remoteSlug -or ($normalizedRepo -and $remoteSlug -ine $normalizedRepo)) {
                $reasons.Add('remote_mismatch')
            }

            if ([string]::IsNullOrWhiteSpace($DefaultBranch)) {
                $defaultResult = Invoke-GitCommandResult -Path $RepoPath -Arguments @('symbolic-ref', '--short', 'refs/remotes/origin/HEAD')
                if ($defaultResult.exit_code -eq 0 -and $defaultResult.stdout -match '^origin/(?<branch>.+)$') {
                    $DefaultBranch = $matches['branch']
                }
            }
        }
    }

    if ($useRefreshRefs -and -not $isExternalGovernance) {
        if (-not [string]::IsNullOrWhiteSpace($RepoPath)) {
            $fetchResult = if ($FetchInvoker) {
                & $FetchInvoker $RepoPath
            }
            else {
                Invoke-GitCommandResult -Path $RepoPath -Arguments @('fetch', '--prune', 'origin')
            }
            if ($fetchResult.exit_code -eq 0) {
                try {
                    $worktrees = @(Get-GitRepositoryWorktrees -Path $RepoPath)
                    $refsMode = 'live'
                }
                catch {
                    $errors.Add((New-AdmissionError -Category 'post_fetch_worktree_inspection_failed' -ExitCode 1))
                    $reasons.Add('live_evidence_unavailable')
                }
            }
            else {
                $errors.Add((New-AdmissionError -Category 'fetch_failed' -ExitCode ([int] $fetchResult.exit_code)))
                $reasons.Add('live_evidence_unavailable')
            }
        }
        else {
            $reasons.Add('live_evidence_unavailable')
        }
    }

    if ($useLiveMetadata) {
        if ($normalizedRepo) {
            $metadataResult = if ($GitHubInvoker) {
                & $GitHubInvoker $normalizedRepo
            }
            else {
                Invoke-ExternalCommandResult -FilePath 'gh.exe' -ArgumentList @('repo', 'view', $normalizedRepo, '--json', 'nameWithOwner,visibility,defaultBranchRef,url')
            }

            $metadata = $null
            if ($metadataResult.exit_code -eq 0) {
                try {
                    $metadata = $metadataResult.stdout | ConvertFrom-Json -ErrorAction Stop
                    $metadataRepo = ConvertTo-GitHubRepoSlug ([string] $metadata.nameWithOwner)
                    if (-not $metadataRepo -or $metadataRepo -ine $normalizedRepo) {
                        $metadata = $null
                        $errors.Add((New-AdmissionError -Category 'github_metadata_mismatch' -ExitCode 1))
                    }
                }
                catch {
                    $metadata = $null
                    $errors.Add((New-AdmissionError -Category 'github_metadata_invalid' -ExitCode 1))
                }
            }
            else {
                $errors.Add((New-AdmissionError -Category 'github_metadata_failed' -ExitCode ([int] $metadataResult.exit_code)))
            }

            if ($metadata) {
                $metadataMode = 'live'
                $visibilityResolution = Resolve-AdmissionVisibilityValue -Value ([string] $metadata.visibility)
                if ($visibilityResolution.valid) {
                    $Visibility = $visibilityResolution.value
                }
                else {
                    $Visibility = $null
                    $visibilityInvalidObserved = $true
                }
                if ($metadata.defaultBranchRef -and $metadata.defaultBranchRef.name) {
                    $DefaultBranch = [string] $metadata.defaultBranchRef.name
                }
                if (-not [string]::IsNullOrWhiteSpace([string] $metadata.url)) {
                    $metadataRemoteUrl = ConvertTo-PublicGitHubRemoteUrl ([string] $metadata.url)
                    if ($metadataRemoteUrl) {
                        $remoteUrl = $metadataRemoteUrl
                    }
                }
            }
            else {
                $reasons.Add('live_evidence_unavailable')
            }
        }
        else {
            $reasons.Add('live_evidence_unavailable')
        }
    }

    if ($metadataMode -eq 'live' -and $refsMode -eq 'live') {
        $remoteMode = 'live'
    }

    $finalVisibilityResolution = Resolve-AdmissionVisibilityValue -Value $Visibility
    if ($finalVisibilityResolution.valid) {
        $Visibility = $finalVisibilityResolution.value
    }
    else {
        $Visibility = $null
        $visibilityInvalidObserved = $true
    }
    $DefaultBranch = if ([string]::IsNullOrWhiteSpace($DefaultBranch)) { $null } else { $DefaultBranch.Trim() }
    if ($visibilityInvalidObserved) {
        $reasons.Add('visibility_invalid')
        $errors.Add((New-AdmissionError -Category 'visibility_invalid' -ExitCode 1))
    }
    elseif (-not $Visibility) {
        $reasons.Add('visibility_unknown')
    }
    if (-not $DefaultBranch) { $reasons.Add('default_branch_unknown') }
    if ($DefaultBranch -and -not [string]::IsNullOrWhiteSpace($RepoPath) -and $worktrees.Count -gt 0) {
        try {
            $worktrees = @(Add-GitDefaultBranchIntegrationEvidence `
                -Path $RepoPath -DefaultBranch $DefaultBranch -Worktrees @($worktrees))
            $branches = @(Get-GitRepositoryBranchInventory `
                -Path $RepoPath -DefaultBranch $DefaultBranch -Worktrees @($worktrees))
        }
        catch {
            foreach ($worktree in @($worktrees)) {
                if ($null -eq $worktree.PSObject.Properties['integration_state']) {
                    $worktree | Add-Member -NotePropertyName integration_state -NotePropertyValue 'unknown' -Force
                    $worktree | Add-Member -NotePropertyName is_default_branch -NotePropertyValue $false -Force
                    $worktree | Add-Member -NotePropertyName unique_commits_vs_default -NotePropertyValue $null -Force
                    $worktree | Add-Member -NotePropertyName missing_default_commits -NotePropertyValue $null -Force
                }
            }
            $reasons.Add('default_branch_integration_unknown')
            $errors.Add((New-AdmissionError -Category 'default_branch_integration_failed' -ExitCode 1))
        }
    }
    Add-GitArtifactGovernanceEvidence `
        -Repo $normalizedRepo `
        -Worktrees @($worktrees) `
        -Branches @($branches)

    $targetScope = Resolve-AdmissionTargetScope -Worktrees @($worktrees) -TargetWorktree $TargetWorktree -TargetRef $TargetRef
    foreach ($targetReason in @($targetScope.reasons)) {
        $reasons.Add([string] $targetReason)
    }
    $selectedDecisionWorktrees = @($targetScope.decision_worktrees)
    if ((-not [string]::IsNullOrWhiteSpace($TargetWorktree) -or
        -not [string]::IsNullOrWhiteSpace($TargetRef)) -and
        @($selectedDecisionWorktrees | Where-Object external_governance).Count -gt 0) {
        $reasons.Add('external_governance_excluded')
    }
    $decisionWorktrees = @($selectedDecisionWorktrees | Where-Object { -not $_.external_governance })

    if ($remoteMode -eq 'cached') { $reasons.Add('cached_observation') }
    if (@($decisionWorktrees | Where-Object { $_.dirty_count -gt 0 }).Count -gt 0) { $reasons.Add('dirty_worktree') }
    if (@($decisionWorktrees | Where-Object { $_.exists -and [string]::IsNullOrWhiteSpace([string] $_.upstream) }).Count -gt 0) { $reasons.Add('no_upstream') }
    if (@($decisionWorktrees | Where-Object prunable).Count -gt 0) { $reasons.Add('prunable_worktree') }
    if (@($decisionWorktrees | Where-Object detached).Count -gt 0) { $reasons.Add('detached_worktree') }
    if (@($decisionWorktrees | Where-Object {
        -not $_.detached -and -not $_.is_default_branch -and $_.integration_state -eq 'unmerged'
    }).Count -gt 0) {
        $reasons.Add('default_branch_missing_commits')
    }
    if (@($decisionWorktrees | Where-Object {
        -not $_.detached -and -not $_.is_default_branch -and $_.integration_state -eq 'unknown'
    }).Count -gt 0) {
        $reasons.Add('default_branch_integration_unknown')
    }
    if (@($decisionWorktrees | Where-Object {
        -not $_.detached -and -not $_.is_default_branch -and
        $_.dirty_count -eq 0 -and -not $_.locked -and -not $_.prunable -and
        $_.integration_state -in @('merged_ancestry', 'patch_equivalent')
    }).Count -gt 0) {
        $reasons.Add('merged_residual_worktree')
    }
    if ([string]::IsNullOrWhiteSpace($TargetWorktree) -and [string]::IsNullOrWhiteSpace($TargetRef)) {
        if (@($branches | Where-Object {
            -not $_.external_governance -and -not $_.historical_retention -and -not $_.has_worktree -and
            -not $_.is_default_branch -and $_.integration_state -eq 'unmerged'
        }).Count -gt 0) {
            $reasons.Add('default_branch_missing_commits')
        }
        if (@($branches | Where-Object {
            -not $_.external_governance -and -not $_.historical_retention -and -not $_.has_worktree -and
            -not $_.is_default_branch -and $_.integration_state -eq 'unknown'
        }).Count -gt 0) {
            $reasons.Add('default_branch_integration_unknown')
        }
        if (@($branches | Where-Object {
            -not $_.external_governance -and -not $_.historical_retention -and $_.retirement_candidate
        }).Count -gt 0) {
            $reasons.Add('merged_residual_branch')
        }
    }
    if (@($decisionWorktrees | Where-Object inspection_error).Count -gt 0) {
        $reasons.Add('worktree_inspection_error')
        $errors.Add((New-AdmissionError -Category 'worktree_inspection_failed' -ExitCode 1))
    }
    if ($Visibility -eq 'PUBLIC' -and @($decisionWorktrees | Where-Object public_exposure_conflict).Count -gt 0) {
        $reasons.Add('public_exposure_conflict')
    }

    $reasonArray = @($reasons | Sort-Object -Unique)
    $blockingReasons = @(
        'invalid_repo',
        'missing_repo_path',
        'ambiguous_repo_path',
        'remote_mismatch',
        'public_exposure_conflict',
        'live_evidence_unavailable',
        'visibility_unknown',
        'visibility_invalid',
        'default_branch_unknown',
        'worktree_inspection_error',
        'target_worktree_not_found',
        'target_ref_not_found',
        'target_scope_mismatch',
        'target_scope_ambiguous',
        'target_worktree_unavailable',
        'external_governance_excluded'
    )
    $decision = if (@($reasonArray | Where-Object { $_ -in $blockingReasons }).Count -gt 0) {
        'block'
    }
    elseif ($reasonArray.Count -gt 0) {
        'warn'
    }
    else {
        'proceed'
    }
    $pushGuidance = Get-ProjectPushGuidance -AdmissionDecision $decision -Reasons $reasonArray -RemoteMode $remoteMode -Worktrees $decisionWorktrees

    New-ProjectAdmissionRecord `
        -ObservedUtc $observedUtc `
        -Repo $normalizedRepo `
        -RemoteUrl $remoteUrl `
        -Visibility $Visibility `
        -DefaultBranch $DefaultBranch `
        -LocalRoot $localRoot `
        -GitCommonDir $gitCommonDir `
        -RemoteMode $remoteMode `
        -MetadataMode $metadataMode `
        -RefsMode $refsMode `
        -TargetWorktree $targetScope.target_worktree `
        -TargetRef $targetScope.target_ref `
        -Decision $decision `
        -PushDecision $pushGuidance.decision `
        -PushStrategy $pushGuidance.strategy `
        -Reasons $reasonArray `
        -Errors @($errors) `
        -Worktrees @($worktrees) `
        -Branches @($branches)
}

Export-ModuleMember -Function @(
    'Read-GitArtifactGovernanceRegistry',
    'Invoke-ExternalCommandResult',
    'Invoke-GitCommandResult',
    'ConvertTo-GitHubRepoSlug',
    'Test-IsExternallyGovernedGitHubRepository',
    'Get-GitArtifactGovernance',
    'Get-GitRepositoryOverride',
    'Get-GitArtifactRetention',
    'Test-IsExternallyGovernedLocalPath',
    'ConvertTo-PublicGitHubRemoteUrl',
    'ConvertFrom-GitWorktreePorcelain',
    'ConvertFrom-GitStatusPorcelainV1Z',
    'Get-PublicExposurePathAssessment',
    'Test-PublicExposurePath',
    'Get-GitRepositoryWorktrees',
    'Get-GitDefaultBranchIntegrationEvidence',
    'Get-GitRepositoryBranchInventory',
    'Get-IndexedProjectFacts',
    'New-ProjectAdmissionRecord',
    'Get-ProjectAdmissionRecord'
)
