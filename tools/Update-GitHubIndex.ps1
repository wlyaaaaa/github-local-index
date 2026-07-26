param(
    [string] $Owner = 'wlyaaaaa',
    [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string[]] $ScanRoots = @(),
    [switch] $SkipFetch,
    [switch] $NoWrite
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
Import-Module (Join-Path $PSScriptRoot 'GitHubIndex.Core.psm1') -Force

function Normalize-GitHubRepoSlug {
    param([AllowNull()] [string] $RemoteUrl)

    ConvertTo-GitHubRepoSlug $RemoteUrl
}

function ConvertTo-MarkdownCell {
    param([AllowNull()] [object] $Value)

    if ($null -eq $Value) {
        return ''
    }

    return ([string] $Value) -replace '\|', '\|' -replace "(\r\n|\n|\r)", '<br>'
}

function New-MarkdownTable {
    param(
        [string[]] $Headers,
        [string[]] $Properties,
        [object[]] $Rows
    )

    $lines = @()
    $lines += '| ' + ($Headers -join ' | ') + ' |'
    $lines += '| ' + (($Headers | ForEach-Object { '---' }) -join ' | ') + ' |'

    foreach ($row in $Rows) {
        $cells = foreach ($property in $Properties) {
            ConvertTo-MarkdownCell $row.$property
        }
        $lines += '| ' + ($cells -join ' | ') + ' |'
    }

    return $lines
}

function Invoke-ExternalCommandWithRetry {
    param(
        [Parameter(Mandatory = $true)] [scriptblock] $Command,
        [string] $Operation = 'external command',
        [int] $MaxAttempts = 3,
        [int] $DelaySeconds = 2
    )

    if ($MaxAttempts -lt 1) {
        throw 'MaxAttempts must be at least 1.'
    }

    $lastExitCode = $null
    $lastStdout = @()
    $lastStderr = @()
    $lastError = $null

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $global:LASTEXITCODE = 0
        $stdout = @()
        $stderr = @()
        $attemptError = $null
        try {
            # Dot-source only inside a disposable child scope: this captures
            # native $LASTEXITCODE without exposing the retry loop's locals to
            # the caller-provided script block.
            $execution = & {
                param([scriptblock] $CommandToInvoke)

                $global:LASTEXITCODE = 0
                $capturedOutput = @(. $CommandToInvoke 2>&1)
                [pscustomobject]@{
                    exit_code = [int] $global:LASTEXITCODE
                    output = @($capturedOutput)
                }
            } $Command
            $combinedOutput = @($execution.output)
            $exitCode = [int] $execution.exit_code
            foreach ($item in $combinedOutput) {
                if ($item -is [System.Management.Automation.ErrorRecord]) {
                    $stderr += [string] $item
                }
                else {
                    $stdout += $item
                }
            }
            if ($null -eq $exitCode) {
                $exitCode = 0
            }
        }
        catch {
            $stderr = @($_.Exception.Message)
            $exitCode = if ($global:LASTEXITCODE -ne 0) { $global:LASTEXITCODE } else { 1 }
            $attemptError = $_
        }

        $lastExitCode = $exitCode
        $lastStdout = $stdout
        $lastStderr = $stderr
        $lastError = $attemptError

        if ($exitCode -eq 0) {
            return $stdout
        }

        if ($attempt -lt $MaxAttempts -and $DelaySeconds -gt 0) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    $summaryItems = @(
        @($lastStderr) + @($lastStdout) |
            ForEach-Object { ([string] $_).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -First 3
    )
    $summary = $summaryItems -join ' '
    if ([string]::IsNullOrWhiteSpace($summary) -and $lastError) {
        $summary = $lastError.Exception.Message
    }
    if ($summary.Length -gt 512) {
        $summary = $summary.Substring(0, 509) + '...'
    }

    throw "$Operation failed after $MaxAttempts attempt(s). Last exit code: $lastExitCode. $summary"
}

function Invoke-GitFetchWithRetry {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [int] $MaxAttempts = 3,
        [int] $DelaySeconds = 2,
        [scriptblock] $Invoker
    )

    if ($MaxAttempts -lt 1) {
        throw 'MaxAttempts must be at least 1.'
    }
    $lastResult = $null
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $lastResult = if ($Invoker) {
            & $Invoker $Path
        }
        else {
            Invoke-GitCommandResult -Path $Path -Arguments @('fetch', '--prune', 'origin')
        }
        if ($null -eq $lastResult -or $null -eq $lastResult.PSObject.Properties['exit_code']) {
            throw 'Git fetch invoker returned an invalid result.'
        }
        if ([int] $lastResult.exit_code -eq 0) {
            return $lastResult
        }
        if ($attempt -lt $MaxAttempts -and $DelaySeconds -gt 0) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }
    return $lastResult
}

function Get-DefaultBranchName {
    param([object] $Repository)

    if ($Repository.defaultBranchRef -and $Repository.defaultBranchRef.name) {
        return [string] $Repository.defaultBranchRef.name
    }

    return ''
}

function Get-MissingCloneAction {
    param(
        [string] $NameWithOwner,
        [string] $Visibility
    )

    if ($NameWithOwner -eq 'wlyaaaaa/Key') {
        return '需要时 clone 到受管私有路径；checkout 只保留密文和公开安全说明'
    }

    if ($Visibility -eq 'PRIVATE') {
        return '需要时统一 clone 到私有目录，或标记为远端备份仓库'
    }

    return '需要时统一 clone，或标记远端存档'
}

function Get-RepoNextAction {
    param(
        [string] $Visibility,
        [bool] $HasUpstream,
        [int] $Ahead,
        [int] $Behind,
        [int] $DirtyCount
    )

    if (-not $HasUpstream) {
        return '需人工确认 upstream 后再判断推送策略'
    }

    if ($Behind -gt 0) {
        return '先同步远端变更，再决定是否提交或推送'
    }

    if ($DirtyCount -gt 0) {
        if ($Visibility -eq 'PUBLIC') {
            return '公开仓库先做暴露面审查，再按显式路径提交'
        }

        return '私有仓库按备份需求确认后提交'
    }

    if ($Ahead -gt 0) {
        if ($Visibility -eq 'PRIVATE') {
            return '私有备份策略放行，可推送'
        }

        return '公开仓库完成脱敏审查后推送'
    }

    return '正常维护'
}

function Sort-GitHubIndexRows {
    param([object[]] $Rows)

    return @($Rows | Sort-Object NameWithOwner)
}

function Get-RepoStateText {
    param(
        [string] $Branch,
        [bool] $HasUpstream,
        [int] $Ahead,
        [int] $Behind,
        [int] $DirtyCount
    )

    $branchText = if ([string]::IsNullOrWhiteSpace($Branch)) { 'detached' } else { $Branch }

    if (-not $HasUpstream) {
        if ($DirtyCount -gt 0) {
            return "``$branchText`` 无 upstream，脏工作区 $DirtyCount 项"
        }
        return "``$branchText`` 无 upstream"
    }

    $state = "``$branchText`` "
    if ($Ahead -eq 0 -and $Behind -eq 0) {
        $state += "已同步，``$Ahead/$Behind``"
    } else {
        $state += "ahead/behind ``$Ahead/$Behind``"
    }

    if ($DirtyCount -gt 0) {
        $state += "，脏工作区 $DirtyCount 项"
    }

    return $state
}

function Get-CommitPinnedSnapshotState {
    param(
        [string] $Path,
        [string] $Head,
        [bool] $HasUpstream,
        [bool] $Detached = $false,
        [AllowNull()] [object] $Ahead,
        [AllowNull()] [object] $Behind,
        [AllowNull()] [object] $DirtyCount,
        [bool] $Exists,
        [bool] $Prunable
    )

    if (-not $Exists -or $Prunable -or
        $null -eq $DirtyCount -or [int] $DirtyCount -ne 0 -or
        [string]::IsNullOrWhiteSpace($Path) -or
        $Head -notmatch '^[0-9a-fA-F]{40}$') {
        return $null
    }
    if ($HasUpstream) {
        if ($null -eq $Ahead -or $null -eq $Behind -or [int] $Ahead -ne 0) {
            return $null
        }
    }
    else {
        if (-not $Detached -or
            ($null -ne $Ahead -and [int] $Ahead -ne 0) -or
            ($null -ne $Behind -and [int] $Behind -ne 0)) {
            return $null
        }
    }

    $leaf = [System.IO.Path]::GetFileName(([string] $Path).TrimEnd('\', '/'))
    if ($leaf -notmatch '(?i)(?:^|[-_.])(?:audit|reaudit|snapshot|review)[-_.](?:.*[-_.])?(?<commit>[0-9a-f]{7,40})$') {
        return $null
    }

    $commitPrefix = [string] $matches['commit']
    if (-not $Head.StartsWith($commitPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    return [pscustomobject]@{
        commit_prefix = $commitPrefix.ToLowerInvariant()
        observed_behind = if ($HasUpstream) { [int] $Behind } else { $null }
        detached = [bool] $Detached
    }
}

function Get-CommitPinnedClonePreflight {
    param([Parameter(Mandatory = $true)] [string] $Path)

    try {
        $worktrees = @(Get-GitRepositoryWorktrees -Path $Path)
        if ($worktrees.Count -ne 1) {
            return $null
        }
        $worktree = $worktrees[0]
        $normalizedObservedPath = [System.IO.Path]::GetFullPath([string] $worktree.path).TrimEnd('\', '/')
        $normalizedRequestedPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
        if (-not $normalizedObservedPath.Equals(
            $normalizedRequestedPath,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            return $null
        }
        $hasUpstream = -not [string]::IsNullOrWhiteSpace([string] $worktree.upstream)
        return Get-CommitPinnedSnapshotState `
            -Path ([string] $worktree.path) `
            -Head ([string] $worktree.head) `
            -HasUpstream:$hasUpstream `
            -Detached ([bool] $worktree.detached) `
            -Ahead $worktree.ahead `
            -Behind $worktree.behind `
            -DirtyCount $worktree.dirty_count `
            -Exists ([bool] $worktree.exists) `
            -Prunable ([bool] $worktree.prunable)
    }
    catch {
        return $null
    }
}

function Get-RegisteredNecessaryRetentionState {
    param(
        [Parameter(Mandatory = $true)] [object] $Worktree,
        [bool] $InspectionFailed,
        [AllowNull()] [object] $DirtyCount
    )

    if ($null -eq $Worktree.PSObject.Properties['necessary_retention'] -or
        -not [bool] $Worktree.necessary_retention -or
        $InspectionFailed -or
        -not [bool] $Worktree.exists -or
        [bool] $Worktree.prunable -or
        $null -eq $DirtyCount -or [int] $DirtyCount -ne 0 -or
        [string]::IsNullOrWhiteSpace([string] $Worktree.retention_owner) -or
        [string]::IsNullOrWhiteSpace([string] $Worktree.retention_purpose) -or
        [string]::IsNullOrWhiteSpace([string] $Worktree.retention_exit_condition)) {
        return $null
    }

    return [pscustomobject]@{
        owner = [string] $Worktree.retention_owner
        purpose = [string] $Worktree.retention_purpose
        exit_condition = [string] $Worktree.retention_exit_condition
    }
}

function Get-BranchConvergenceDisposition {
    param(
        [ValidateSet('default', 'merged_ancestry', 'patch_equivalent', 'unmerged', 'unknown')]
        [string] $IntegrationState = 'unknown',
        [bool] $IsDefaultBranch,
        [AllowNull()] [object] $DirtyCount,
        [bool] $HasWorktree = $true,
        [switch] $PinnedSnapshot,
        [switch] $Locked,
        [switch] $Prunable,
        [switch] $Detached,
        [bool] $Exists = $true
    )

    $result = [ordered]@{
        needs_review = $false
        retirement_candidate = $false
        queue_reason = ''
        next_action = ''
    }
    if ($IsDefaultBranch) {
        return [pscustomobject] $result
    }
    if ($PinnedSnapshot) {
        $result.next_action = '保持提交固定审计快照；需要新证据时创建新审计副本'
        return [pscustomobject] $result
    }
    if (-not $Exists -or $Prunable) {
        $result.needs_review = $true
        $result.queue_reason = 'worktree_unavailable'
        $result.next_action = '清理或恢复 prunable worktree 元数据'
        return [pscustomobject] $result
    }
    if ($Detached) {
        $result.needs_review = $true
        $result.queue_reason = 'detached_worktree'
        $result.next_action = '确认 detached worktree 的保留或收敛用途'
        return [pscustomobject] $result
    }
    if ($HasWorktree -and ($null -eq $DirtyCount -or [int] $DirtyCount -gt 0)) {
        $result.needs_review = $true
        $result.queue_reason = if ($null -eq $DirtyCount) {
            'default_branch_integration_unknown'
        }
        else {
            'active_dirty_worktree'
        }
        $result.next_action = if ($null -eq $DirtyCount) {
            '当前收尾继续追溯默认分支可达性；无法查清则 BLOCK'
        }
        else {
            '保留活跃脏工作区；完成并验证后再整合到默认分支'
        }
        return [pscustomobject] $result
    }
    if ($Locked) {
        $result.needs_review = $true
        $result.queue_reason = 'locked_worktree'
        $result.next_action = '保留 locked worktree；解除交接依赖后再评审'
        return [pscustomobject] $result
    }
    if ($IntegrationState -eq 'unknown') {
        $result.needs_review = $true
        $result.queue_reason = 'default_branch_integration_unknown'
        $result.next_action = '当前收尾继续追溯 owner、独有内容和默认分支可达性；无法查清则 BLOCK'
        return [pscustomobject] $result
    }
    if ($IntegrationState -eq 'unmerged') {
        $result.needs_review = $true
        $result.queue_reason = if ($HasWorktree) {
            'unintegrated_worktree_commit'
        }
        else {
            'unintegrated_branch_commit'
        }
        $result.next_action = '验证后将独有提交整合到仓库实际默认分支'
        return [pscustomobject] $result
    }
    if ($IntegrationState -in @('merged_ancestry', 'patch_equivalent')) {
        $result.needs_review = $true
        $result.retirement_candidate = $true
        $result.queue_reason = if ($HasWorktree) {
            'merged_residual_worktree'
        }
        else {
            'merged_residual_branch'
        }
        $result.next_action = if ($HasWorktree) {
            '确认无活跃依赖后移除已整合的临时 worktree，再删除分支'
        }
        else {
            '确认无活跃依赖后删除已整合的残留分支'
        }
    }

    return [pscustomobject] $result
}

function Get-GitConfigPaths {
    param([string[]] $Roots)

    $existingRoots = @($Roots |
        Where-Object { -not (Test-IsExternallyGovernedLocalPath -Path $_) } |
        Where-Object { Test-Path -LiteralPath $_ })
    if ($existingRoots.Count -eq 0) {
        return @()
    }

    $rootConfigs = foreach ($root in $existingRoots) {
        $configPath = Join-Path $root '.git\config'
        if (Test-Path -LiteralPath $configPath) {
            $configPath
        }
    }

    if (Get-Command rg -ErrorAction SilentlyContinue) {
        $args = @('--files', '--hidden', '--no-ignore')
        $args += $existingRoots
        $args += @(
            '-g', '**/.git/config',
            '-g', '!**/node_modules/**',
            '-g', '!**/.cache/**',
            '--iglob', '!**/*personalos*/**',
            '--iglob', '!**/*personalso*/**'
        )
        $rgConfigs = @(& rg @args 2>$null | Where-Object { -not (Test-IsTransientGitConfigPath $_) })
        return @(@($rootConfigs) + $rgConfigs | Sort-Object -Unique)
    }

    return @($rootConfigs | Sort-Object -Unique)
}

function Test-IsTransientGitConfigPath {
    param([string] $ConfigPath)

    $normalized = ([string] $ConfigPath) -replace '\\', '/'
    $normalized = $normalized.ToLowerInvariant()
    $transientFragments = @(
        '/appdata/local/temp/',
        '/.cache/',
        '/node_modules/'
    )

    foreach ($fragment in $transientFragments) {
        if ($normalized.Contains($fragment)) {
            return $true
        }
    }

    return $false
}

function Get-GitConfigRemoteSlugs {
    param([string] $ConfigPath)

    $content = Get-Content -LiteralPath $ConfigPath -ErrorAction SilentlyContinue
    if (-not $content) {
        return @()
    }

    $slugs = foreach ($line in $content) {
        if ($line -match '^\s*url\s*=\s*(?<url>.+?)\s*$') {
            Normalize-GitHubRepoSlug $matches['url']
        }
    }

    return @($slugs | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-RepoPathFromConfigPath {
    param([string] $ConfigPath)

    $gitDir = Split-Path -Parent $ConfigPath
    return Split-Path -Parent $gitDir
}

function Get-GitRepositorySeedPaths {
    param([string[]] $Roots)

    $existingRoots = @($Roots |
        Where-Object { -not (Test-IsExternallyGovernedLocalPath -Path $_) } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Container })
    if ($existingRoots.Count -eq 0) {
        return @()
    }

    $seeds = [System.Collections.Generic.List[string]]::new()
    $rootsToScan = [System.Collections.Generic.List[string]]::new()
    foreach ($root in $existingRoots) {
        $resolvedRoot = [System.IO.Path]::GetFullPath($root)
        $insideResult = Invoke-GitCommandResult -Path $resolvedRoot -Arguments @('rev-parse', '--is-inside-work-tree')
        if ($insideResult.exit_code -eq 0 -and $insideResult.stdout -eq 'true') {
            $seeds.Add($resolvedRoot)
        }
        else {
            $rootsToScan.Add($resolvedRoot)
        }
    }

    if ($rootsToScan.Count -gt 0) {
        if (Get-Command rg -ErrorAction SilentlyContinue) {
            $arguments = @('--files', '--hidden', '--no-ignore') + @($rootsToScan) + @(
                '-g', '**/.git',
                '-g', '**/.git/config',
                '-g', '!**/node_modules/**',
                '-g', '!**/.cache/**',
                '--iglob', '!**/*personalos*/**',
                '--iglob', '!**/*personalso*/**'
            )
            $gitMarkers = @(& rg @arguments 2>$null)
        }
        else {
            throw 'rg is required for governance-safe repository discovery.'
        }

        foreach ($marker in $gitMarkers) {
            if (Test-IsExternallyGovernedLocalPath -Path ([string] $marker)) {
                continue
            }
            $normalized = ([string] $marker) -replace '/', '\'
            $seed = if ($normalized -match '\\.git\\config$') {
                Split-Path -Parent (Split-Path -Parent $normalized)
            }
            elseif ($normalized -match '\\.git$') {
                Split-Path -Parent $normalized
            }
            else {
                $null
            }
            if ($seed -and
                -not (Test-IsTransientClonePath -Path $seed) -and
                -not (Test-IsExternallyGovernedLocalPath -Path $seed)) {
                $seeds.Add([System.IO.Path]::GetFullPath($seed))
            }
        }
    }

    return @($seeds | Sort-Object -Unique)
}

function Get-IndexedCloneScanRoots {
    param([Parameter(Mandatory = $true)] [string] $RepoRoot)

    $indexPath = Join-Path $RepoRoot '01_仓库索引/本地clone索引.md'
    $roots = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $indexPath -PathType Leaf) {
        foreach ($line in Get-Content -LiteralPath $indexPath -Encoding utf8) {
            if ($line -notmatch '^\|\s*(?<repo>[^|]+/[^|]+?)\s*\|\s*(?<paths>[^|]+?)\s*\|') {
                continue
            }
            if (Test-IsExternallyGovernedGitHubRepository -Repo $matches['repo'].Trim(' ', '`')) {
                continue
            }
            foreach ($candidate in @($matches['paths'] -split '<br>')) {
                $path = $candidate.Trim(' ', '`')
                if ($path -and $path -ne '未发现本地 clone' -and (Test-Path -LiteralPath $path -PathType Container)) {
                    $roots.Add([System.IO.Path]::GetFullPath($path))
                }
            }
        }
    }
    if (Test-Path -LiteralPath $RepoRoot -PathType Container) {
        $roots.Add([System.IO.Path]::GetFullPath($RepoRoot))
    }

    # The previous index is useful for preserving existing worktree paths, but it
    # cannot discover a repository that was created under a newly adopted root.
    # Seed every current canonical/compatibility root as well, then let the
    # repository map keep only remotes owned by the indexed GitHub account.
    $ownerVolumeRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($RepoRoot))
    $canonicalCandidates = @(
        (Join-Path $ownerVolumeRoot '.agents'),
        (Join-Path $ownerVolumeRoot 'PCConfig'),
        (Join-Path $ownerVolumeRoot 'Projects'),
        (Join-Path $ownerVolumeRoot '.worktrees'),
        'V:\Personal\Projects',
        'V:\Personal\Worktrees',
        'V:\Work',
        'V:\Dev'
    )
    foreach ($candidate in $canonicalCandidates) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            $roots.Add([System.IO.Path]::GetFullPath($candidate))
        }
    }

    return @($roots | Sort-Object -Unique)
}

function Test-IsTransientClonePath {
    param([string] $Path)

    $normalized = $Path -replace '/', '\'
    $transientPatterns = @(
        '\AppData\Local\Temp\',
        '\Documents\Codex\'
    )

    foreach ($pattern in $transientPatterns) {
        if ($normalized -match [regex]::Escape($pattern)) {
            return $true
        }
    }

    return $false
}

function Get-LocalCloneMap {
    param(
        [string[]] $Roots,
        [switch] $SkipFetch
    )

    $map = @{}
    $seenCommonDirs = @{}
    foreach ($repoPath in Get-GitRepositorySeedPaths -Roots $Roots) {
        if ((Test-IsTransientClonePath -Path $repoPath) -or (Test-IsExternallyGovernedLocalPath -Path $repoPath)) {
            continue
        }

        $commonResult = Invoke-GitCommandResult -Path $repoPath -Arguments @('rev-parse', '--path-format=absolute', '--git-common-dir')
        if ($commonResult.exit_code -ne 0) {
            continue
        }
        $commonKey = ([System.IO.Path]::GetFullPath($commonResult.stdout)).ToLowerInvariant()
        if ($seenCommonDirs.ContainsKey($commonKey)) {
            continue
        }

        $remoteResult = Invoke-GitCommandResult -Path $repoPath -Arguments @('config', '--get', 'remote.origin.url')
        $slug = if ($remoteResult.exit_code -eq 0) { Normalize-GitHubRepoSlug $remoteResult.stdout } else { $null }
        if (-not $slug) {
            continue
        }

        $seenCommonDirs[$commonKey] = $true
        if (-not $map.ContainsKey($slug)) {
            $map[$slug] = @()
        }
        $map[$slug] += [pscustomobject]@{ Path = $repoPath; CommonDir = $commonResult.stdout }
    }

    return $map
}

function ConvertTo-GitHubIndexRows {
    param(
        [object[]] $Repositories,
        [hashtable] $CloneMap
    )

    foreach ($repo in $Repositories) {
        $name = [string] $repo.nameWithOwner
        $visibility = [string] $repo.visibility
        $defaultBranch = Get-DefaultBranchName -Repository $repo
        if (Test-IsExternallyGovernedGitHubRepository -Repo $name) {
            [pscustomobject]@{
                NameWithOwner = $name
                Visibility    = $visibility
                DefaultBranch = $defaultBranch
                LocalPath     = '外部治理（不读取本地路径）'
                LocalState    = '仅保留 GitHub 目录事实'
                NextAction    = '不行动；由外部治理 owner 维护'
                HasLocalClone = $false
                NeedsReview   = $false
                Ahead         = 0
                Behind        = 0
                DirtyCount    = 0
                PinnedSnapshotCount = 0
                PinnedObservedBehind = 0
                NecessaryRetentionCount = 0
                QueueReason   = ''
                PushedAt      = $repo.pushedAt
                UpdatedAt     = $repo.updatedAt
                Url           = $repo.url
            }
            continue
        }
        $clones = @()
        if ($CloneMap.ContainsKey($name)) {
            $clones = @($CloneMap[$name])
        }

        if ($clones.Count -eq 0) {
            [pscustomobject]@{
                NameWithOwner = $name
                Visibility    = $visibility
                DefaultBranch = $defaultBranch
                LocalPath     = '未发现本地 clone'
                LocalState    = '无法评估本地变化'
                NextAction    = Get-MissingCloneAction -NameWithOwner $name -Visibility $visibility
                HasLocalClone = $false
                NeedsReview   = $false
                Ahead         = 0
                Behind        = 0
                DirtyCount    = 0
                PinnedSnapshotCount = 0
                PinnedObservedBehind = 0
                NecessaryRetentionCount = 0
                QueueReason   = ''
                PushedAt      = $repo.pushedAt
                UpdatedAt     = $repo.updatedAt
                Url           = $repo.url
            }
            continue
        }

        $primary = $clones | Select-Object -First 1
        $paths = ($clones | ForEach-Object { $_.Path } | Select-Object -Unique) -join '<br>'
        $states = ($clones | ForEach-Object { $_.State }) -join '<br>'
        $actions = ($clones | ForEach-Object { $_.NextAction } | Sort-Object -Unique) -join '<br>'
        $needsReview = @($clones | Where-Object { $_.NeedsReview }).Count -gt 0
        $dirtyCount = @($clones | Measure-Object -Property DirtyCount -Sum).Sum
        $ahead = @($clones | Measure-Object -Property Ahead -Sum).Sum
        $behind = @($clones | Measure-Object -Property Behind -Sum).Sum
        $pinnedSnapshots = @($clones | Where-Object {
            $null -ne $_.PSObject.Properties['IsPinnedSnapshot'] -and [bool] $_.IsPinnedSnapshot
        })
        $necessaryRetentions = @($clones | Where-Object {
            $null -ne $_.PSObject.Properties['IsNecessaryRetention'] -and [bool] $_.IsNecessaryRetention
        })
        $pinnedObservedBehindValues = @($pinnedSnapshots | ForEach-Object {
            if ($null -ne $_.PinnedObservedBehind) { [int] $_.PinnedObservedBehind }
        })
        $pinnedObservedBehind = if ($pinnedObservedBehindValues.Count -gt 0) {
            [int] (@($pinnedObservedBehindValues | Measure-Object -Sum).Sum)
        }
        else {
            0
        }

        $queueReason = ''
        if ($needsReview) {
            $reasons = @()
            if ($ahead -gt 0) { $reasons += "ahead $ahead" }
            if ($behind -gt 0) { $reasons += "behind $behind" }
            if ($dirtyCount -gt 0) { $reasons += "脏工作区 $dirtyCount 项" }
            if (@($clones | Where-Object {
                (-not ($null -ne $_.PSObject.Properties['IsPinnedSnapshot'] -and [bool] $_.IsPinnedSnapshot)) -and
                (-not ($null -ne $_.PSObject.Properties['IsNecessaryRetention'] -and [bool] $_.IsNecessaryRetention)) -and
                [string]::IsNullOrWhiteSpace([string] $_.Upstream)
            }).Count -gt 0) { $reasons += '无 upstream' }
            foreach ($cloneReason in @($clones | ForEach-Object { @($_.QueueReasons) })) {
                if (-not [string]::IsNullOrWhiteSpace([string] $cloneReason)) {
                    $reasons += [string] $cloneReason
                }
            }
            $queueReason = ($reasons | Sort-Object -Unique) -join '；'
        }

        [pscustomobject]@{
            NameWithOwner = $name
            Visibility    = $visibility
            DefaultBranch = $defaultBranch
            LocalPath     = $paths
            LocalState    = $states
            NextAction    = $actions
            HasLocalClone = $true
            NeedsReview   = $needsReview
            Ahead         = [int] $ahead
            Behind        = [int] $behind
            DirtyCount    = [int] $dirtyCount
            PinnedSnapshotCount = $pinnedSnapshots.Count
            PinnedObservedBehind = $pinnedObservedBehind
            NecessaryRetentionCount = $necessaryRetentions.Count
            QueueReason   = $queueReason
            PushedAt      = $repo.pushedAt
            UpdatedAt     = $repo.updatedAt
            Url           = $repo.url
        }
    }
}

function ConvertTo-DocumentRows {
    param(
        [object[]] $Rows,
        [string] $Owner
    )

    return @($Rows)
}

function Get-GitHubRepositories {
    param([string] $Owner)

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw 'GitHub CLI gh is required before refreshing the index.'
    }

    Invoke-ExternalCommandWithRetry -Operation 'GitHub CLI auth status' -Command {
        & gh auth status *> $null
    } | Out-Null

    $json = Invoke-ExternalCommandWithRetry -Operation 'read repository list from GitHub' -Command {
        & gh repo list $Owner --limit 200 --json nameWithOwner,visibility,url,defaultBranchRef,pushedAt,updatedAt
    }

    return @($json | ConvertFrom-Json)
}

function Resolve-CloneStatuses {
    param(
        [hashtable] $CloneMap,
        [object[]] $Repositories,
        [switch] $SkipFetch,
        [scriptblock] $FetchInvoker
    )

    foreach ($repo in $Repositories) {
        $name = [string] $repo.nameWithOwner
        if (-not $CloneMap.ContainsKey($name)) {
            continue
        }

        $resolved = foreach ($clone in @($CloneMap[$name])) {
            $metadataJson = $repo | ConvertTo-Json -Depth 6 -Compress
            $metadataInvoker = { param($slug) [pscustomobject]@{ exit_code = 0; stdout = $metadataJson; stderr = '' } }.GetNewClosure()
            $pinnedPreflight = if (-not $SkipFetch) {
                Get-CommitPinnedClonePreflight -Path $clone.Path
            }
            else {
                $null
            }
            $shouldRefreshRefs = (-not $SkipFetch) -and $null -eq $pinnedPreflight
            $fetchResult = if ($shouldRefreshRefs) {
                Invoke-GitFetchWithRetry -Path $clone.Path -Invoker $FetchInvoker
            }
            else {
                $null
            }
            $admissionFetchInvoker = if ($null -ne $fetchResult) {
                $capturedFetchResult = $fetchResult
                {
                    param($path)
                    $capturedFetchResult
                }.GetNewClosure()
            }
            else {
                $null
            }
            $admission = Get-ProjectAdmissionRecord `
                -Repo $name `
                -RepoPath $clone.Path `
                -Visibility ([string] $repo.visibility) `
                -DefaultBranch (Get-DefaultBranchName -Repository $repo) `
                -LiveMetadata:(-not $SkipFetch) `
                -RefreshRefs:$shouldRefreshRefs `
                -FetchInvoker $admissionFetchInvoker `
                -GitHubInvoker $metadataInvoker

            $repoErrorReasons = @($admission.errors | ForEach-Object { [string] $_.category })
            foreach ($worktree in @($admission.worktrees)) {
                $inspectionFailed = [bool] $worktree.inspection_error
                $observedAhead = $worktree.ahead
                $observedBehind = $worktree.behind
                $observedDirtyCount = $worktree.dirty_count
                $ahead = if ($inspectionFailed -and $null -eq $observedAhead) { $null } elseif ($null -eq $observedAhead) { 0 } else { [int] $observedAhead }
                $behind = if ($inspectionFailed -and $null -eq $observedBehind) { $null } elseif ($null -eq $observedBehind) { 0 } else { [int] $observedBehind }
                $dirtyCount = if ($inspectionFailed -and $null -eq $observedDirtyCount) { $null } elseif ($null -eq $observedDirtyCount) { 0 } else { [int] $observedDirtyCount }
                $hasUpstream = -not [string]::IsNullOrWhiteSpace([string] $worktree.upstream)
                $pinnedSnapshot = if (-not $inspectionFailed) {
                    Get-CommitPinnedSnapshotState `
                        -Path ([string] $worktree.path) `
                        -Head ([string] $worktree.head) `
                        -HasUpstream:$hasUpstream `
                        -Detached ([bool] $worktree.detached) `
                        -Ahead $observedAhead `
                        -Behind $observedBehind `
                        -DirtyCount $observedDirtyCount `
                        -Exists ([bool] $worktree.exists) `
                        -Prunable ([bool] $worktree.prunable)
                }
                else {
                    $null
                }
                $externalGovernance = $null -ne $worktree.PSObject.Properties['external_governance'] -and
                    [bool] $worktree.external_governance
                $governanceOwner = if ($externalGovernance) {
                    [string] $worktree.governance_owner
                }
                else {
                    $null
                }
                $necessaryRetentionState = Get-RegisteredNecessaryRetentionState `
                    -Worktree $worktree `
                    -InspectionFailed:$inspectionFailed `
                    -DirtyCount $observedDirtyCount
                $necessaryRetention = $null -ne $necessaryRetentionState
                $retentionOwner = if ($necessaryRetention) {
                    [string] $necessaryRetentionState.owner
                }
                else {
                    $null
                }
                $retentionPurpose = if ($necessaryRetention) {
                    [string] $necessaryRetentionState.purpose
                }
                else {
                    $null
                }
                $retentionExitCondition = if ($necessaryRetention) {
                    [string] $necessaryRetentionState.exit_condition
                }
                else {
                    $null
                }
                $protectedRetention = [bool] $pinnedSnapshot -or $necessaryRetention
                $integrationState = if ($null -ne $worktree.PSObject.Properties['integration_state'] -and
                    -not [string]::IsNullOrWhiteSpace([string] $worktree.integration_state)) {
                    [string] $worktree.integration_state
                }
                else {
                    'unknown'
                }
                $isDefaultBranch = $null -ne $worktree.PSObject.Properties['is_default_branch'] -and
                    [bool] $worktree.is_default_branch
                $missingDefaultCommits = if ($null -ne $worktree.PSObject.Properties['missing_default_commits']) {
                    $worktree.missing_default_commits
                }
                else {
                    $null
                }
                $uniqueCommitsVsDefault = if ($null -ne $worktree.PSObject.Properties['unique_commits_vs_default']) {
                    $worktree.unique_commits_vs_default
                }
                else {
                    $null
                }
                $convergence = Get-BranchConvergenceDisposition `
                    -IntegrationState $integrationState `
                    -IsDefaultBranch:$isDefaultBranch `
                    -DirtyCount $observedDirtyCount `
                    -HasWorktree:$true `
                    -PinnedSnapshot:$protectedRetention `
                    -Locked:([bool] $worktree.locked) `
                    -Prunable:([bool] $worktree.prunable) `
                    -Detached:([bool] $worktree.detached) `
                    -Exists ([bool] $worktree.exists)
                $actionableBehind = if ($protectedRetention) { 0 } else { $behind }
                $state = if ($externalGovernance) {
                    "``$([string] $worktree.branch)`` 由 $governanceOwner 外部 owner 治理，不纳入 Codex 收敛判断"
                }
                elseif ($necessaryRetention) {
                    "必要保留：$retentionPurpose；owner：$retentionOwner；退出条件：$retentionExitCondition"
                }
                elseif ($pinnedSnapshot) {
                    $distance = if ($pinnedSnapshot.detached) {
                        'detached 且无 upstream'
                    }
                    elseif ($behind -gt 0) {
                        "远端领先 $behind"
                    }
                    else {
                        '与当前远端引用同位'
                    }
                    "历史审计快照固定于 ``$($pinnedSnapshot.commit_prefix)``，$distance，不自动同步"
                }
                elseif ($inspectionFailed) {
                    'worktree 检查失败（状态未知）'
                }
                elseif (-not $worktree.exists -or $worktree.prunable) {
                    'prunable worktree（路径缺失）'
                }
                else {
                    Get-RepoStateText -Branch ([string] $worktree.branch) -HasUpstream:$hasUpstream -Ahead $ahead -Behind $behind -DirtyCount $dirtyCount
                }
                if (-not $externalGovernance -and -not $protectedRetention -and
                    -not $isDefaultBranch -and -not $worktree.detached) {
                    if ($integrationState -eq 'unmerged') {
                        $missingText = if ($null -ne $missingDefaultCommits) { [int] $missingDefaultCommits } else { '?' }
                        $state += "，默认分支缺少 $missingText 个提交"
                    }
                    elseif ($integrationState -in @('merged_ancestry', 'patch_equivalent')) {
                        $state += '，内容已由默认分支吸收'
                    }
                    elseif ($integrationState -eq 'unknown') {
                        $state += '，默认分支整合状态未知'
                    }
                }
                $state += "（$($admission.remote_mode)）"

                $queueReasons = [System.Collections.Generic.List[string]]::new()
                if (-not $externalGovernance) {
                    if ($worktree.prunable) { $queueReasons.Add('prunable worktree') }
                    if ($worktree.detached -and -not $protectedRetention) { $queueReasons.Add('detached worktree') }
                    if (-not [string]::IsNullOrWhiteSpace([string] $convergence.queue_reason)) {
                        $queueReasons.Add([string] $convergence.queue_reason)
                    }
                    if (-not $protectedRetention -and $integrationState -eq 'unmerged' -and
                        $convergence.queue_reason -ne 'unintegrated_worktree_commit') {
                        $queueReasons.Add('unintegrated_worktree_commit')
                    }
                    if (-not $protectedRetention -and $admission.remote_mode -eq 'cached') {
                        $queueReasons.Add('cached 远端引用')
                    }
                    foreach ($errorReason in $repoErrorReasons) { $queueReasons.Add($errorReason) }
                }
                $nextAction = if ($externalGovernance) {
                    "无；由 $governanceOwner owner 管理"
                }
                elseif ($repoErrorReasons.Count -gt 0) {
                    '远端观察失败；当前仅使用 cached 引用，需人工复查'
                }
                elseif ($worktree.prunable) {
                    '清理或恢复 prunable worktree 元数据'
                }
                elseif ($necessaryRetention) {
                    "保持必要保留；退出条件：$retentionExitCondition"
                }
                elseif ($pinnedSnapshot) {
                    '保持提交固定审计快照；需要新证据时创建新审计副本'
                }
                elseif (-not [string]::IsNullOrWhiteSpace([string] $convergence.next_action)) {
                    [string] $convergence.next_action
                }
                else {
                    Get-RepoNextAction -Visibility ([string] $repo.visibility) -HasUpstream:$hasUpstream -Ahead $ahead -Behind $actionableBehind -DirtyCount $dirtyCount
                }

                [pscustomobject]@{
                    Path = $worktree.path
                    Branch = [string] $worktree.branch
                    Upstream = if ($externalGovernance) { '[external-owner]' } else { [string] $worktree.upstream }
                    Ahead = if ($externalGovernance) { 0 } else { $ahead }
                    Behind = if ($externalGovernance) { 0 } else { $actionableBehind }
                    DirtyCount = if ($externalGovernance) { 0 } else { $dirtyCount }
                    State = $state
                    NextAction = $nextAction
                    IsDirty = (-not $externalGovernance) -and $dirtyCount -gt 0
                    IsPinnedSnapshot = [bool] $pinnedSnapshot
                    PinnedSnapshotCommit = if ($pinnedSnapshot) { [string] $pinnedSnapshot.commit_prefix } else { $null }
                    PinnedObservedBehind = if ($pinnedSnapshot -and $null -ne $pinnedSnapshot.observed_behind) { [int] $pinnedSnapshot.observed_behind } else { $null }
                    IsNecessaryRetention = $necessaryRetention
                    RetentionOwner = $retentionOwner
                    RetentionPurpose = $retentionPurpose
                    RetentionExitCondition = $retentionExitCondition
                    IntegrationState = $integrationState
                    IsDefaultBranch = $isDefaultBranch
                    UniqueCommitsVsDefault = $uniqueCommitsVsDefault
                    MissingDefaultCommits = $missingDefaultCommits
                    RetirementCandidate = (-not $externalGovernance) -and
                        (-not $necessaryRetention) -and [bool] $convergence.retirement_candidate
                    NeedsReview = (-not $externalGovernance) -and (
                        $inspectionFailed -or $repoErrorReasons.Count -gt 0 -or
                        $worktree.prunable -or ((-not $hasUpstream) -and -not $protectedRetention) -or
                        $ahead -gt 0 -or $actionableBehind -gt 0 -or
                        $dirtyCount -gt 0 -or [bool] $convergence.needs_review
                    )
                    QueueReasons = @($queueReasons)
                    RemoteMode = $admission.remote_mode
                    ExternalGovernance = $externalGovernance
                    GovernanceOwner = $governanceOwner
                }
            }
            foreach ($branchRecord in @($admission.branches | Where-Object {
                -not $_.has_worktree -and -not $_.is_default_branch
            })) {
                $branchIntegrationState = if ([string]::IsNullOrWhiteSpace([string] $branchRecord.integration_state)) {
                    'unknown'
                }
                else {
                    [string] $branchRecord.integration_state
                }
                $branchExternalGovernance = $null -ne $branchRecord.PSObject.Properties['external_governance'] -and
                    [bool] $branchRecord.external_governance
                $branchGovernanceOwner = if ($branchExternalGovernance) {
                    [string] $branchRecord.governance_owner
                }
                else {
                    $null
                }
                $branchConvergence = Get-BranchConvergenceDisposition `
                    -IntegrationState $branchIntegrationState `
                    -IsDefaultBranch:$false `
                    -DirtyCount 0 `
                    -HasWorktree:$false
                $branchRefLabel = if ($branchRecord.ref_kind -eq 'remote_tracking') {
                    'remote-tracking branch ref'
                }
                else {
                    '本地 branch ref'
                }
                $branchState = if ($branchExternalGovernance) {
                    "``$($branchRecord.branch)`` 由 $branchGovernanceOwner 外部 owner 治理，不纳入 Codex 收敛判断"
                }
                elseif ($branchIntegrationState -eq 'unmerged') {
                    $missingText = if ($null -ne $branchRecord.missing_default_commits) {
                        [int] $branchRecord.missing_default_commits
                    }
                    else {
                        '?'
                    }
                    "``$($branchRecord.branch)`` 仅有 $branchRefLabel，默认分支缺少 $missingText 个提交"
                }
                elseif ($branchIntegrationState -in @('merged_ancestry', 'patch_equivalent')) {
                    "``$($branchRecord.branch)`` 仅有 $branchRefLabel，内容已由默认分支吸收"
                }
                else {
                    "``$($branchRecord.branch)`` 仅有 $branchRefLabel，默认分支整合状态未知"
                }
                $branchState += "（$($admission.remote_mode)）"
                $branchQueueReasons = [System.Collections.Generic.List[string]]::new()
                if (-not $branchExternalGovernance) {
                    if (-not [string]::IsNullOrWhiteSpace([string] $branchConvergence.queue_reason)) {
                        $branchQueueReasons.Add([string] $branchConvergence.queue_reason)
                    }
                    if ($admission.remote_mode -eq 'cached') { $branchQueueReasons.Add('cached 远端引用') }
                    foreach ($errorReason in $repoErrorReasons) { $branchQueueReasons.Add($errorReason) }
                }

                [pscustomobject]@{
                    Path = $clone.Path
                    Branch = [string] $branchRecord.branch
                    Upstream = if ($branchExternalGovernance) {
                        '[external-owner]'
                    }
                    else {
                        [string] $branchRecord.upstream
                    }
                    Ahead = 0
                    Behind = 0
                    DirtyCount = 0
                    State = $branchState
                    NextAction = if ($branchExternalGovernance) {
                        "无；由 $branchGovernanceOwner owner 管理"
                    }
                    else {
                        [string] $branchConvergence.next_action
                    }
                    IsDirty = $false
                    IsPinnedSnapshot = $false
                    PinnedSnapshotCommit = $null
                    PinnedObservedBehind = $null
                    IsNecessaryRetention = $false
                    RetentionOwner = $null
                    RetentionPurpose = $null
                    RetentionExitCondition = $null
                    IntegrationState = $branchIntegrationState
                    IsDefaultBranch = $false
                    UniqueCommitsVsDefault = $branchRecord.unique_commits_vs_default
                    MissingDefaultCommits = $branchRecord.missing_default_commits
                    RetirementCandidate = (-not $branchExternalGovernance) -and
                        [bool] $branchConvergence.retirement_candidate
                    NeedsReview = (-not $branchExternalGovernance) -and (
                        $repoErrorReasons.Count -gt 0 -or [bool] $branchConvergence.needs_review
                    )
                    QueueReasons = @($branchQueueReasons)
                    RemoteMode = $admission.remote_mode
                    IsBranchOnly = $true
                    ExternalGovernance = $branchExternalGovernance
                    GovernanceOwner = $branchGovernanceOwner
                }
            }
        }

        $CloneMap[$name] = @($resolved)
    }
}

function Set-TextFile {
    param(
        [string] $Path,
        [string[]] $Lines
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }

    $normalizedLines = @($Lines)
    while ($normalizedLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace([string] $normalizedLines[-1])) {
        if ($normalizedLines.Count -eq 1) {
            $normalizedLines = @()
            break
        }

        $normalizedLines = @($normalizedLines[0..($normalizedLines.Count - 2)])
    }

    $text = ($normalizedLines -join [Environment]::NewLine) + [Environment]::NewLine
    Set-Content -LiteralPath $Path -Value $text -Encoding UTF8 -NoNewline
}

function Write-GitHubIndexDocuments {
    param(
        [string] $RepoRoot,
        [string] $Owner,
        [object[]] $Rows
    )

    $Rows = @(Sort-GitHubIndexRows (ConvertTo-DocumentRows -Rows $Rows -Owner $Owner))
    $date = [DateTime]::UtcNow.AddHours(8).ToString('yyyy-MM-dd')
    $total = $Rows.Count
    $localRows = @($Rows | Where-Object { $_.HasLocalClone } | Sort-Object NameWithOwner)
    $missingRows = @($Rows | Where-Object { -not $_.HasLocalClone } | Sort-Object NameWithOwner)
    $queueRows = @($Rows | Where-Object { $_.HasLocalClone -and $_.NeedsReview } | Sort-Object NameWithOwner)
    $noActionRows = @($Rows | Where-Object { $_.HasLocalClone -and -not $_.NeedsReview } | Sort-Object NameWithOwner)
    $dirtyRows = @($Rows | Where-Object { $_.DirtyCount -gt 0 } | Sort-Object NameWithOwner)

    $overviewLines = @(
        '# GitHub 总览',
        '',
        "更新时间：$date",
        '',
        '本机 GitHub 工作区按公开索引、私有备份仓库和公开业务仓库三类管理。详细事实来自同一组仓库行，不在总览中维护第二份项目清单。',
        '',
        '## 当前计数',
        '',
        '| GitHub 仓库 | 已发现本地 clone | 未发现 clone | 当前审核队列 |',
        '|---|---|---|---|',
        "| $total | $($localRows.Count) | $($missingRows.Count) | $($queueRows.Count) |",
        '',
        '## 发布边界',
        '',
        '- 私有备份仓库可按用户恢复需求保存敏感恢复材料；本公开索引只记录公开安全结论。',
        '- 公开仓库在提交前执行暴露面审查，不记录 secret 值、原始日志、任务 XML 或私有 payload。',
        '- Git 与 GitHub 事实由本仓库维护；机器路径、计划任务配置和恢复事实由 PCConfig 维护。',
        '',
        '## 历史审计',
        '',
        '- [2026-07-05 GitHub 仓库与计划任务审计](../90_历史审计/2026/2026-07-05-GitHub仓库与计划任务审计.md)'
    )
    Set-TextFile -Path (Join-Path $RepoRoot '00_总览/GitHub总览.md') -Lines $overviewLines

    $indexLines = @(
        '# GitHub 仓库索引',
        '',
        "更新时间：$date",
        '',
        "当前 ``$Owner`` 账号共有 $total 个仓库。本文件由 ``tools/Update-GitHubIndex.ps1`` 刷新。",
        ''
    )
    $indexLines += New-MarkdownTable -Headers @('GitHub 仓库', '可见性', '默认分支', '本地路径', '本地状态', '下次动作') -Properties @('NameWithOwner', 'Visibility', 'DefaultBranch', 'LocalPath', 'LocalState', 'NextAction') -Rows $Rows
    Set-TextFile -Path (Join-Path $RepoRoot '01_仓库索引/GitHub仓库索引.md') -Lines $indexLines

    $cloneLines = @(
        '# 本地 Clone 索引',
        '',
        "更新时间：$date",
        '',
        '## 已确认本地位置',
        ''
    )
    $cloneLines += New-MarkdownTable -Headers @('GitHub 仓库', '本地路径', '状态') -Properties @('NameWithOwner', 'LocalPath', 'LocalState') -Rows $localRows
    Set-TextFile -Path (Join-Path $RepoRoot '01_仓库索引/本地clone索引.md') -Lines $cloneLines

    $missingLines = @(
        '# 未发现本地 Clone',
        '',
        "更新时间：$date",
        '',
        '扩大搜索范围后仍未发现本地 clone 的仓库：',
        ''
    )
    if ($missingRows.Count -gt 0) {
        $missingLines += New-MarkdownTable -Headers @('GitHub 仓库', '可见性', '当前决策') -Properties @('NameWithOwner', 'Visibility', 'NextAction') -Rows $missingRows
    } else {
        $missingLines += '当前没有未发现本地 clone 的 GitHub 仓库。'
    }
    $missingLines += ''
    $missingLines += '说明：`Key` 仓库可 clone 到受管私有路径，但 checkout 只允许密文和公开安全说明；解密明文、口令与密钥文件不得进入仓库。'
    Set-TextFile -Path (Join-Path $RepoRoot '01_仓库索引/未发现本地clone.md') -Lines $missingLines

    $queueLines = @(
        '# 未推送队列',
        '',
        "更新时间：$date",
        '',
        '## 当前队列',
        ''
    )
    if ($queueRows.Count -gt 0) {
        $queueLines += New-MarkdownTable -Headers @('仓库', '可见性', '状态', '队列原因', '决策') -Properties @('NameWithOwner', 'Visibility', 'LocalState', 'QueueReason', 'NextAction') -Rows $queueRows
    } else {
        $queueLines += '| 仓库 | 可见性 | 状态 | 决策 |'
        $queueLines += '|---|---|---|---|'
        $queueLines += '| 无 | - | - | 当前已发现本地 clone 的仓库均无未推送队列项 |'
    }
    Set-TextFile -Path (Join-Path $RepoRoot '02_同步诊断/未推送队列.md') -Lines $queueLines

    $branchLines = @(
        '# 分支与远端诊断',
        '',
        "更新时间：$date",
        '',
        '## 无行动项',
        ''
    )
    if ($noActionRows.Count -gt 0) {
        $branchLines += New-MarkdownTable -Headers @('仓库', '本地路径', '分支状态') -Properties @('NameWithOwner', 'LocalPath', 'LocalState') -Rows $noActionRows
    } else {
        $branchLines += '当前没有无需行动的本地 clone。'
    }
    $branchLines += ''
    $branchLines += '## 仍需处理'
    $branchLines += ''
    if ($queueRows.Count -gt 0) {
        $branchLines += New-MarkdownTable -Headers @('仓库', '分支状态', '原因') -Properties @('NameWithOwner', 'LocalState', 'QueueReason') -Rows $queueRows
    } else {
        $branchLines += '| 仓库 | 分支 | 原因 |'
        $branchLines += '|---|---|---|'
        $branchLines += '| 无 | - | 当前已发现本地 clone 的仓库均无待处理项 |'
    }
    Set-TextFile -Path (Join-Path $RepoRoot '02_同步诊断/分支与远端诊断.md') -Lines $branchLines

    $dirtyLines = @(
        '# 工作区脏状态',
        '',
        "更新时间：$date",
        ''
    )
    if ($dirtyRows.Count -gt 0) {
        $dirtyLines += New-MarkdownTable -Headers @('仓库', '本地路径', '脏状态', '处理策略') -Properties @('NameWithOwner', 'LocalPath', 'LocalState', 'NextAction') -Rows $dirtyRows
    } else {
        $dirtyLines += '当前已发现本地 clone 的仓库没有脏工作区。'
    }
    $dirtyLines += ''
    $dirtyLines += '原则：脏工作区不等于必须提交。公开仓库的混合产物应先整理，再用显式路径 stage。'
    Set-TextFile -Path (Join-Path $RepoRoot '02_同步诊断/工作区脏状态.md') -Lines $dirtyLines

    $dashboardRows = @(
        [pscustomobject]@{
            NameWithOwner = '仓库总数'
            Visibility    = '-'
            LocalState    = "$total 个 GitHub 仓库，$($localRows.Count) 个已发现本地 clone，$($missingRows.Count) 个未发现 clone"
            NextAction    = '持续刷新'
        },
        [pscustomobject]@{
            NameWithOwner = '未推送队列'
            Visibility    = '-'
            LocalState    = "$($queueRows.Count) 个需处理项"
            NextAction    = if ($queueRows.Count -gt 0) { '逐项审查' } else { '无需处理' }
        },
        [pscustomobject]@{
            NameWithOwner = '工作区脏状态'
            Visibility    = '公开索引'
            LocalState    = "$($dirtyRows.Count) 个仓库存在脏 worktree"
            NextAction    = if ($dirtyRows.Count -gt 0) { '逐项审查暴露面和提交边界' } else { '无需处理' }
        },
        [pscustomobject]@{
            NameWithOwner = '公开发布门禁'
            Visibility    = 'PUBLIC'
            LocalState    = '公开仓库只接收代码、文档和脱敏后的 Git 状态摘要'
            NextAction    = '发现 secret、原始日志或私有 payload 时阻止发布'
        }
    )
    $dashboardLines = @(
        '# 当前同步看板',
        '',
        "更新时间：$date",
        ''
    )
    $dashboardLines += New-MarkdownTable -Headers @('项目', '可见性', '当前状态', '决策') -Properties @('NameWithOwner', 'Visibility', 'LocalState', 'NextAction') -Rows $dashboardRows
    $dashboardLines += ''
    $dashboardLines += '## 下一步优先级'
    $dashboardLines += ''
    $dashboardLines += '1. 当仓库 identity、worktree、sync 或 visibility 的不确定性会影响决策时，按需用 `tools\Get-ProjectAdmission.ps1 -Repo <owner/name> -Json` 取得单仓库证据。'
    $dashboardLines += '2. 定期运行 `tools\Test-GitHubLocalIndexConsistency.ps1 -SkipFetch`；只读检查不得提交或推送。'
    $dashboardLines += '3. 对未推送队列中的公开仓库先做暴露面审查。'
    $dashboardLines += '4. 对未发现 clone 的仓库决定是否进入统一目录或标记远端存档；`wlyaaaaa/Key` 仅允许受管私有 clone 和密文维护。'
    $dashboardLines += '5. 只有明确里程碑或索引事实变化时才记录 push milestone；普通推送不制造索引提交。'
    Set-TextFile -Path (Join-Path $RepoRoot '00_总览/当前同步看板.md') -Lines $dashboardLines
}

function Invoke-UpdateGitHubIndex {
    param(
        [string] $Owner = 'wlyaaaaa',
        [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot),
        [string[]] $ScanRoots = @(),
        [switch] $SkipFetch,
        [switch] $NoWrite
    )

    $repositories = @(Get-GitHubRepositories -Owner $Owner)
    $effectiveScanRoots = @($ScanRoots)
    if ($effectiveScanRoots.Count -eq 0) {
        $effectiveScanRoots = @(Get-IndexedCloneScanRoots -RepoRoot $RepoRoot)
    }
    if ($effectiveScanRoots.Count -eq 0) {
        throw 'No Git scan roots are available. Pass -ScanRoots for bootstrap discovery.'
    }
    $cloneMap = Get-LocalCloneMap -Roots $effectiveScanRoots -SkipFetch:$SkipFetch
    Resolve-CloneStatuses -CloneMap $cloneMap -Repositories $repositories -SkipFetch:$SkipFetch
    $rows = @(Sort-GitHubIndexRows (ConvertTo-GitHubIndexRows -Repositories $repositories -CloneMap $cloneMap))

    if (-not $NoWrite) {
        Write-GitHubIndexDocuments -RepoRoot $RepoRoot -Owner $Owner -Rows $rows
    }

    return $rows
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-UpdateGitHubIndex -Owner $Owner -RepoRoot $RepoRoot -ScanRoots $ScanRoots -SkipFetch:$SkipFetch -NoWrite:$NoWrite
}
