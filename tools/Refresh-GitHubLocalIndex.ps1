param(
    [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [switch] $CheckOnly,
    [switch] $Fast,
    [string] $Repo,
    [string] $RepoPath
)

$ErrorActionPreference = 'Stop'

$logDir = Join-Path $RepoRoot '99_private\logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logPath = Join-Path $logDir 'GitHubLocalIndexRefresh.log'

function Write-RefreshLog {
    param([string] $Message)

    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

function Add-PathIfExists {
    param([Parameter(Mandatory = $true)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $parts = @($env:Path -split ';' | Where-Object { $_ })
    if ($parts -notcontains $Path) {
        $env:Path = ($parts + $Path) -join ';'
    }
}

function Normalize-RefreshRepoSlug {
    param([AllowNull()] [string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $text = $Value.Trim() -replace '\\', '/'
    $text = $text -replace '\.git$', ''

    if ($text -match 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/]+)$') {
        return "$($matches['owner'])/$($matches['repo'])"
    }

    if ($text -match '^(?<owner>[^/\s]+)/(?<repo>[^/\s]+)$') {
        return "$($matches['owner'])/$($matches['repo'])"
    }

    return $text
}

function Resolve-IndexedClonePath {
    param(
        [Parameter(Mandatory = $true)] [string] $RepoRoot,
        [Parameter(Mandatory = $true)] [string] $Repo
    )

    $normalizedRepo = Normalize-RefreshRepoSlug $Repo
    if ([string]::IsNullOrWhiteSpace($normalizedRepo)) {
        return $null
    }

    $indexPath = Join-Path $RepoRoot '01_仓库索引\本地clone索引.md'
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
        return $null
    }

    foreach ($line in Get-Content -LiteralPath $indexPath) {
        if ($line -notmatch '^\|\s*(?<repo>[^|]+?)\s*\|\s*(?<path>[^|]+?)\s*\|') {
            continue
        }

        $rowRepo = Normalize-RefreshRepoSlug $matches['repo']
        if ($rowRepo -ne $normalizedRepo) {
            continue
        }

        $paths = @([string] $matches['path'] -split '<br>' | ForEach-Object { $_.Trim(' ', '`') } | Where-Object { $_ })
        foreach ($path in $paths) {
            if (Test-Path -LiteralPath $path -PathType Container) {
                return $path
            }
        }

        return ($paths | Select-Object -First 1)
    }

    return $null
}

function Invoke-GitScalar {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string[]] $Arguments
    )

    $output = & git -C $Path @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    return ([string] $output).Trim()
}

function Invoke-FastRepositoryRefresh {
    param(
        [Parameter(Mandatory = $true)] [string] $RepoRoot,
        [string] $Repo,
        [string] $RepoPath
    )

    $targetPath = $RepoPath
    if ([string]::IsNullOrWhiteSpace($targetPath)) {
        if ([string]::IsNullOrWhiteSpace($Repo)) {
            throw 'Fast refresh requires -Repo or -RepoPath.'
        }

        $targetPath = Resolve-IndexedClonePath -RepoRoot $RepoRoot -Repo $Repo
    }

    if ([string]::IsNullOrWhiteSpace($targetPath)) {
        throw "Cannot resolve local clone path for repo '$Repo'."
    }

    if (-not (Test-Path -LiteralPath $targetPath -PathType Container)) {
        throw "Local clone path does not exist: $targetPath"
    }

    $gitDir = Invoke-GitScalar -Path $targetPath -Arguments @('rev-parse', '--git-dir')
    if ([string]::IsNullOrWhiteSpace($gitDir)) {
        throw "Path is not a Git worktree: $targetPath"
    }

    $originUrl = Invoke-GitScalar -Path $targetPath -Arguments @('remote', 'get-url', 'origin')
    $resolvedRepo = if (-not [string]::IsNullOrWhiteSpace($Repo)) { Normalize-RefreshRepoSlug $Repo } else { Normalize-RefreshRepoSlug $originUrl }
    $branch = Invoke-GitScalar -Path $targetPath -Arguments @('branch', '--show-current')
    $upstream = Invoke-GitScalar -Path $targetPath -Arguments @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')
    $counts = if (-not [string]::IsNullOrWhiteSpace($upstream)) {
        Invoke-GitScalar -Path $targetPath -Arguments @('rev-list', '--left-right', '--count', 'HEAD...@{u}')
    } else {
        $null
    }
    $dirtyLines = @(& git -C $targetPath status --porcelain=v1 --untracked-files=normal 2>$null)

    $ahead = $null
    $behind = $null
    if ($counts -match '^(?<left>\d+)\s+(?<right>\d+)$') {
        $ahead = [int] $matches['left']
        $behind = [int] $matches['right']
    }

    $summary = [pscustomobject]@{
        Repo       = $resolvedRepo
        Path       = $targetPath
        Branch     = $branch
        Upstream   = $upstream
        Ahead      = $ahead
        Behind     = $behind
        DirtyCount = $dirtyLines.Count
    }

    Write-RefreshLog ("FAST repo={0} path={1} branch={2} upstream={3} ahead={4} behind={5} dirty={6}" -f `
        $summary.Repo, $summary.Path, $summary.Branch, $summary.Upstream, $summary.Ahead, $summary.Behind, $summary.DirtyCount)

    return $summary
}

function Invoke-RefreshStep {
    param(
        [string] $Name,
        [scriptblock] $ScriptBlock
    )

    Write-RefreshLog "START $Name"
    try {
        & $ScriptBlock
        Write-RefreshLog "OK $Name"
    }
    catch {
        Write-RefreshLog "FAILED $Name :: $($_.Exception.Message)"
        throw
    }
}

function Invoke-ConsistencyCheck {
    param([string] $Name)

    Invoke-RefreshStep $Name {
        . (Join-Path $RepoRoot 'tools\Test-GitHubLocalIndexConsistency.ps1')
        $result = Invoke-GitHubLocalIndexConsistencyCheck -RepoRoot $RepoRoot -SkipFetch
        Write-RefreshLog "CONSISTENCY compared=$($result.Compared) drift=$($result.DriftCount) stable=$($result.StableDriftCount) volatile=$($result.VolatileDriftCount)"
        if (-not $result.IsConsistent) {
            $files = ($result.DriftFiles | Select-Object -First 10) -join '; '
            Write-RefreshLog "CONSISTENCY drift files: $files"
            throw "GitHub local index drift detected in $($result.DriftCount) generated document(s)."
        }
    }
}

function Invoke-GitHubLocalIndexRefresh {
    Add-PathIfExists 'E:\Scoop\shims'
    Add-PathIfExists (Join-Path $env:USERPROFILE 'scoop\shims')
    Add-PathIfExists 'C:\Program Files\Git\cmd'

    Write-RefreshLog 'GitHub local index refresh started'

    if ($Fast -and $CheckOnly) {
        throw 'Use either -Fast or -CheckOnly, not both.'
    }

    if ($Fast) {
        $result = $null
        Invoke-RefreshStep 'fast repository refresh' {
            $script:FastRepositoryRefreshResult = Invoke-FastRepositoryRefresh -RepoRoot $RepoRoot -Repo $Repo -RepoPath $RepoPath
        }
        $result = $script:FastRepositoryRefreshResult
        Write-RefreshLog 'GitHub local index fast refresh finished'
        $result
        return
    }

    if ($CheckOnly) {
        Invoke-ConsistencyCheck 'consistency check only'
        Write-RefreshLog 'GitHub local index consistency check finished'
        return
    }

    Invoke-RefreshStep 'GitHub repository index' {
        & (Join-Path $RepoRoot 'tools\Update-GitHubIndex.ps1') -RepoRoot $RepoRoot -SkipFetch | Out-Null
    }

    Invoke-RefreshStep 'scheduled task health' {
        & (Join-Path $RepoRoot 'tools\Update-ScheduledTaskHealth.ps1') -RepoRoot $RepoRoot | Out-Null
    }

    Invoke-RefreshStep 'user automation map' {
        & (Join-Path $RepoRoot 'tools\Update-UserAutomationMap.ps1') -RepoRoot $RepoRoot | Out-Null
    }

    Write-RefreshLog 'GitHub local index refresh finished'
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-GitHubLocalIndexRefresh | Out-Host
        exit 0
    }
    catch {
        Write-RefreshLog "FAILED refresh :: $($_.Exception.Message)"
        exit 1
    }
}
