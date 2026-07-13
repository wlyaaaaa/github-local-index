Set-StrictMode -Version Latest

$script:AdmissionSchema = 'github-local-index.project-admission.v1'

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

function Test-PublicExposurePath {
    [CmdletBinding()]
    param([AllowNull()] [string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    $normalized = $Path.Trim(' ', '"') -replace '\\', '/'
    return $normalized -match '(?i)(^|/)(99_private|secrets?)(/|$)|(^|/)(\.env(?:\..*)?|[^/]*(?:private[_-]?key|client[_-]?secret)[^/]*)$|\.(?:pem|key|p12|pfx)$'
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
            error = $true
        }
    }
    $dirtySummary = Get-GitDirtySummary -Entries $entries
    $exposureConflict = $false
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
            if (Test-PublicExposurePath -Path $candidate) {
                $exposureConflict = $true
                break
            }
        }
        if ($exposureConflict) { break }
    }

    return [pscustomobject]@{
        dirty_count = $dirtySummary.total
        dirty_summary = $dirtySummary
        public_exposure_conflict = $exposureConflict
        error = $false
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
            visibility = $matches['visibility'].Trim().ToUpperInvariant()
            default_branch = $matches['branch'].Trim(' ', '`')
            paths = $paths
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
        [ValidateSet('proceed', 'warn', 'block')] [string] $Decision = 'block',
        [ValidateSet('proceed', 'warn', 'block')] [string] $PushDecision = 'block',
        [ValidateSet('none', 'normal', 'fetch_recheck', 'clean_or_stage_explicitly', 'set_upstream', 'update_then_recheck', 'reconcile_then_recheck', 'resolve_public_exposure', 'resolve_admission_block')] [string] $PushStrategy = 'resolve_admission_block',
        [string[]] $Reasons = @(),
        [object[]] $Errors = @(),
        [object[]] $Worktrees = @()
    )

    [pscustomobject][ordered]@{
        schema = $script:AdmissionSchema
        observed_utc = $ObservedUtc
        repo = $Repo
        remote_url = $RemoteUrl
        visibility = $Visibility
        default_branch = $DefaultBranch
        local_root = $LocalRoot
        git_common_dir = $GitCommonDir
        remote_mode = $RemoteMode
        decision = $Decision
        push_decision = $PushDecision
        push_strategy = $PushStrategy
        reasons = @($Reasons)
        errors = @($Errors)
        worktrees = @($Worktrees)
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
        [scriptblock] $FetchInvoker,
        [scriptblock] $GitHubInvoker
    )

    $observedUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    $normalizedRepo = ConvertTo-GitHubRepoSlug $Repo
    $reasons = [System.Collections.Generic.List[string]]::new()
    $errors = [System.Collections.Generic.List[object]]::new()
    $worktrees = @()
    $remoteSlug = $null
    $remoteUrl = $null
    $localRoot = $null
    $gitCommonDir = $null
    $remoteMode = 'cached'

    if (-not $normalizedRepo) {
        $reasons.Add('invalid_repo')
    }

    $facts = $null
    if ($normalizedRepo -and -not [string]::IsNullOrWhiteSpace($IndexRoot)) {
        $facts = Get-IndexedProjectFacts -IndexRoot $IndexRoot -Repo $normalizedRepo
    }
    if ([string]::IsNullOrWhiteSpace($Visibility) -and $facts) {
        $Visibility = $facts.visibility
    }
    if ([string]::IsNullOrWhiteSpace($DefaultBranch) -and $facts) {
        $DefaultBranch = $facts.default_branch
    }

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($RepoPath)) {
        $candidates = @($RepoPath)
    }
    elseif ($facts) {
        $candidates = @($facts.paths)
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
        try {
            $worktrees = @(Get-GitRepositoryWorktrees -Path $RepoPath)
        }
        catch {
            $errors.Add((New-AdmissionError -Category 'worktree_enumeration_failed' -ExitCode 1))
            $reasons.Add('missing_repo_path')
        }

        $localRoot = ConvertTo-NormalizedGitPath $RepoPath
        $commonResult = Invoke-GitCommandResult -Path $RepoPath -Arguments @('rev-parse', '--path-format=absolute', '--git-common-dir')
        if ($commonResult.exit_code -eq 0) {
            $gitCommonDir = ConvertTo-NormalizedGitPath $commonResult.stdout
        }
        $remoteResult = Invoke-GitCommandResult -Path $RepoPath -Arguments @('config', '--get', 'remote.origin.url')
        if ($remoteResult.exit_code -eq 0) {
            $remoteSlug = ConvertTo-GitHubRepoSlug $remoteResult.stdout
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

    if ($Fetch -and -not [string]::IsNullOrWhiteSpace($RepoPath)) {
        $fetchResult = if ($FetchInvoker) { & $FetchInvoker $RepoPath } else { Invoke-GitCommandResult -Path $RepoPath -Arguments @('fetch', '--prune', 'origin') }
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

        if ($fetchResult.exit_code -ne 0) {
            $errors.Add((New-AdmissionError -Category 'fetch_failed' -ExitCode ([int] $fetchResult.exit_code)))
        }

        if ($fetchResult.exit_code -eq 0 -and $metadata) {
            try {
                $worktrees = @(Get-GitRepositoryWorktrees -Path $RepoPath)
                $remoteMode = 'live'
                $Visibility = ([string] $metadata.visibility).ToUpperInvariant()
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
            catch {
                $errors.Add((New-AdmissionError -Category 'post_fetch_worktree_inspection_failed' -ExitCode 1))
                $reasons.Add('live_evidence_unavailable')
            }
        }
        else {
            $reasons.Add('live_evidence_unavailable')
        }
    }
    elseif ($Fetch) {
        $reasons.Add('live_evidence_unavailable')
    }

    $Visibility = if ([string]::IsNullOrWhiteSpace($Visibility)) { $null } else { $Visibility.Trim().ToUpperInvariant() }
    $DefaultBranch = if ([string]::IsNullOrWhiteSpace($DefaultBranch)) { $null } else { $DefaultBranch.Trim() }
    if (-not $Visibility) { $reasons.Add('visibility_unknown') }
    if (-not $DefaultBranch) { $reasons.Add('default_branch_unknown') }

    if ($remoteMode -eq 'cached') { $reasons.Add('cached_observation') }
    if (@($worktrees | Where-Object { $_.dirty_count -gt 0 }).Count -gt 0) { $reasons.Add('dirty_worktree') }
    if (@($worktrees | Where-Object { $_.exists -and [string]::IsNullOrWhiteSpace([string] $_.upstream) }).Count -gt 0) { $reasons.Add('no_upstream') }
    if (@($worktrees | Where-Object prunable).Count -gt 0) { $reasons.Add('prunable_worktree') }
    if (@($worktrees | Where-Object detached).Count -gt 0) { $reasons.Add('detached_worktree') }
    if (@($worktrees | Where-Object inspection_error).Count -gt 0) {
        $reasons.Add('worktree_inspection_error')
        $errors.Add((New-AdmissionError -Category 'worktree_inspection_failed' -ExitCode 1))
    }
    if ($Visibility -eq 'PUBLIC' -and @($worktrees | Where-Object public_exposure_conflict).Count -gt 0) {
        $reasons.Add('public_exposure_conflict')
    }

    $reasonArray = @($reasons | Sort-Object -Unique)
    $blockingReasons = @('invalid_repo', 'missing_repo_path', 'ambiguous_repo_path', 'remote_mismatch', 'public_exposure_conflict', 'live_evidence_unavailable', 'visibility_unknown', 'default_branch_unknown', 'worktree_inspection_error')
    $decision = if (@($reasonArray | Where-Object { $_ -in $blockingReasons }).Count -gt 0) {
        'block'
    }
    elseif ($reasonArray.Count -gt 0) {
        'warn'
    }
    else {
        'proceed'
    }
    $pushGuidance = Get-ProjectPushGuidance -AdmissionDecision $decision -Reasons $reasonArray -RemoteMode $remoteMode -Worktrees $worktrees

    New-ProjectAdmissionRecord `
        -ObservedUtc $observedUtc `
        -Repo $normalizedRepo `
        -RemoteUrl $remoteUrl `
        -Visibility $Visibility `
        -DefaultBranch $DefaultBranch `
        -LocalRoot $localRoot `
        -GitCommonDir $gitCommonDir `
        -RemoteMode $remoteMode `
        -Decision $decision `
        -PushDecision $pushGuidance.decision `
        -PushStrategy $pushGuidance.strategy `
        -Reasons $reasonArray `
        -Errors @($errors) `
        -Worktrees @($worktrees)
}

Export-ModuleMember -Function @(
    'Invoke-ExternalCommandResult',
    'Invoke-GitCommandResult',
    'ConvertTo-GitHubRepoSlug',
    'ConvertTo-PublicGitHubRemoteUrl',
    'ConvertFrom-GitWorktreePorcelain',
    'ConvertFrom-GitStatusPorcelainV1Z',
    'Get-GitRepositoryWorktrees',
    'Get-IndexedProjectFacts',
    'New-ProjectAdmissionRecord',
    'Get-ProjectAdmissionRecord'
)
