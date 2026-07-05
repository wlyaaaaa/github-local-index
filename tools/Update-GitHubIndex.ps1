param(
    [string] $Owner = 'wlyaaaaa',
    [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string[]] $ScanRoots = @('C:\Users\10979', 'E:\', 'G:\'),
    [switch] $SkipFetch,
    [switch] $NoWrite
)

function Normalize-GitHubRepoSlug {
    param([AllowNull()] [string] $RemoteUrl)

    if ([string]::IsNullOrWhiteSpace($RemoteUrl)) {
        return $null
    }

    $value = $RemoteUrl.Trim() -replace '\\', '/'
    $patterns = @(
        '^https://github\.com/(?<owner>[^/]+)/(?<repo>[^/#?]+?)(?:\.git)?/?$',
        '^git@github\.com:(?<owner>[^/]+)/(?<repo>[^/#?]+?)(?:\.git)?$',
        '^ssh://git@github\.com/(?<owner>[^/]+)/(?<repo>[^/#?]+?)(?:\.git)?/?$'
    )

    foreach ($pattern in $patterns) {
        $match = [regex]::Match($value, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            $repo = $match.Groups['repo'].Value -replace '\.git$', ''
            return "$($match.Groups['owner'].Value)/$repo"
        }
    }

    return $null
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
        return '已确认本机没有 clone；严格禁止克隆；仅保留远端私有备份状态'
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

function Get-LocalRepoStatus {
    param(
        [string] $Path,
        [string] $Visibility,
        [switch] $SkipFetch
    )

    if (-not $SkipFetch) {
        & git -C $Path fetch --prune origin *> $null
    }

    $branch = (& git -C $Path branch --show-current 2>$null)
    if ($null -eq $branch) { $branch = '' }
    $branch = ([string] $branch).Trim()

    $upstream = (& git -C $Path rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null)
    $hasUpstream = $LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($upstream)

    $ahead = 0
    $behind = 0
    if ($hasUpstream) {
        $counts = (& git -C $Path rev-list --left-right --count 'HEAD...@{u}' 2>$null)
        if ($LASTEXITCODE -eq 0 -and $counts) {
            $parts = ([string] $counts).Trim() -split '\s+'
            if ($parts.Count -ge 2) {
                $ahead = [int] $parts[0]
                $behind = [int] $parts[1]
            }
        }
    }

    $dirtyLines = @(& git -C $Path status --porcelain=v1 --untracked-files=normal 2>$null)
    $dirtyCount = $dirtyLines.Count
    $state = Get-RepoStateText -Branch $branch -HasUpstream:$hasUpstream -Ahead $ahead -Behind $behind -DirtyCount $dirtyCount
    $nextAction = Get-RepoNextAction -Visibility $Visibility -HasUpstream:$hasUpstream -Ahead $ahead -Behind $behind -DirtyCount $dirtyCount

    return [pscustomobject]@{
        Path        = $Path
        Branch      = $branch
        Upstream    = if ($hasUpstream) { ([string] $upstream).Trim() } else { '' }
        Ahead       = $ahead
        Behind      = $behind
        DirtyCount  = $dirtyCount
        State       = $state
        NextAction  = $nextAction
        IsDirty     = $dirtyCount -gt 0
        NeedsReview = (-not $hasUpstream) -or $ahead -gt 0 -or $behind -gt 0 -or $dirtyCount -gt 0
    }
}

function Get-GitConfigPaths {
    param([string[]] $Roots)

    $existingRoots = @($Roots | Where-Object { Test-Path -LiteralPath $_ })
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
        $args += @('-g', '**/.git/config', '-g', '!**/node_modules/**', '-g', '!**/.cache/**')
        $rgConfigs = @(& rg @args 2>$null)
        return @(@($rootConfigs) + $rgConfigs | Where-Object { -not (Test-IsTransientGitConfigPath $_) } | Sort-Object -Unique)
    }

    $paths = foreach ($root in $existingRoots) {
        Get-ChildItem -LiteralPath $root -Recurse -Force -Filter config -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\\.git\\config$' -and -not (Test-IsTransientGitConfigPath $_.FullName) } |
            Select-Object -ExpandProperty FullName
    }

    return @(@($rootConfigs) + @($paths) | Sort-Object -Unique)
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
    foreach ($config in Get-GitConfigPaths -Roots $Roots) {
        $repoPath = Get-RepoPathFromConfigPath -ConfigPath $config
        if (Test-IsTransientClonePath -Path $repoPath) {
            continue
        }

        foreach ($slug in Get-GitConfigRemoteSlugs -ConfigPath $config) {
            if (-not $map.ContainsKey($slug)) {
                $map[$slug] = @()
            }

            $map[$slug] += [pscustomobject]@{
                Path        = $repoPath
                Branch      = ''
                Upstream    = ''
                Ahead       = 0
                Behind      = 0
                DirtyCount  = 0
                State       = '待检查'
                NextAction  = '待检查'
                IsDirty     = $false
                NeedsReview = $true
            }
        }
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
                QueueReason   = ''
                PushedAt      = $repo.pushedAt
                UpdatedAt     = $repo.updatedAt
                Url           = $repo.url
            }
            continue
        }

        $primary = $clones | Select-Object -First 1
        $paths = ($clones | ForEach-Object { $_.Path }) -join '<br>'
        $states = ($clones | ForEach-Object { $_.State }) -join '<br>'
        $actions = ($clones | ForEach-Object { $_.NextAction } | Sort-Object -Unique) -join '<br>'
        $needsReview = @($clones | Where-Object { $_.NeedsReview }).Count -gt 0
        $dirtyCount = @($clones | Measure-Object -Property DirtyCount -Sum).Sum
        $ahead = @($clones | Measure-Object -Property Ahead -Sum).Sum
        $behind = @($clones | Measure-Object -Property Behind -Sum).Sum

        $queueReason = ''
        if ($needsReview) {
            $reasons = @()
            if ($ahead -gt 0) { $reasons += "ahead $ahead" }
            if ($behind -gt 0) { $reasons += "behind $behind" }
            if ($dirtyCount -gt 0) { $reasons += "脏工作区 $dirtyCount 项" }
            if ([string]::IsNullOrWhiteSpace($primary.Upstream)) { $reasons += '无 upstream' }
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

    $indexRepoName = "$Owner/github-local-index"
    foreach ($row in $Rows) {
        if ($row.NameWithOwner -eq $indexRepoName -and $row.DirtyCount -gt 0) {
            [pscustomobject]@{
                NameWithOwner = $row.NameWithOwner
                Visibility    = $row.Visibility
                DefaultBranch = $row.DefaultBranch
                LocalPath     = $row.LocalPath
                LocalState    = '本次刷新目标仓库；提交推送后复查'
                NextAction    = '提交并推送本索引刷新结果'
                HasLocalClone = $row.HasLocalClone
                NeedsReview   = $false
                Ahead         = 0
                Behind        = 0
                DirtyCount    = 0
                QueueReason   = ''
                PushedAt      = $row.PushedAt
                UpdatedAt     = $row.UpdatedAt
                Url           = $row.Url
            }
            continue
        }

        $row
    }
}

function Get-GitHubRepositories {
    param([string] $Owner)

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw 'GitHub CLI gh is required before refreshing the index.'
    }

    & gh auth status *> $null
    if ($LASTEXITCODE -ne 0) {
        throw 'GitHub CLI is not authenticated. Run gh auth login first.'
    }

    $json = & gh repo list $Owner --limit 200 --json nameWithOwner,visibility,url,defaultBranchRef,pushedAt,updatedAt
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to read repository list from GitHub.'
    }

    return @($json | ConvertFrom-Json)
}

function Resolve-CloneStatuses {
    param(
        [hashtable] $CloneMap,
        [object[]] $Repositories,
        [switch] $SkipFetch
    )

    foreach ($repo in $Repositories) {
        $name = [string] $repo.nameWithOwner
        if (-not $CloneMap.ContainsKey($name)) {
            continue
        }

        $resolved = foreach ($clone in @($CloneMap[$name])) {
            Get-LocalRepoStatus -Path $clone.Path -Visibility ([string] $repo.visibility) -SkipFetch:$SkipFetch
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

    $Rows = @(ConvertTo-DocumentRows -Rows $Rows -Owner $Owner)
    $date = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
    $total = $Rows.Count
    $localRows = @($Rows | Where-Object { $_.HasLocalClone } | Sort-Object NameWithOwner)
    $missingRows = @($Rows | Where-Object { -not $_.HasLocalClone } | Sort-Object NameWithOwner)
    $queueRows = @($Rows | Where-Object { $_.HasLocalClone -and $_.NeedsReview } | Sort-Object NameWithOwner)
    $syncedRows = @($Rows | Where-Object { $_.HasLocalClone -and -not $_.NeedsReview } | Sort-Object NameWithOwner)
    $dirtyRows = @($Rows | Where-Object { $_.DirtyCount -gt 0 } | Sort-Object NameWithOwner)

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
    $missingLines += '说明：`Key` 仓库严格禁止克隆到本机；本公开索引只记录“远端私有备份存在 / 本机无 clone”状态，不做恢复、展开或内容复制。'
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
        '## 已同步',
        ''
    )
    if ($syncedRows.Count -gt 0) {
        $branchLines += New-MarkdownTable -Headers @('仓库', '本地路径', '分支状态') -Properties @('NameWithOwner', 'LocalPath', 'LocalState') -Rows $syncedRows
    } else {
        $branchLines += '当前没有已同步的本地 clone。'
    }
    $branchLines += ''
    $branchLines += '## 仍需处理'
    $branchLines += ''
    if ($queueRows.Count -gt 0) {
        $branchLines += New-MarkdownTable -Headers @('仓库', '分支状态', '原因') -Properties @('NameWithOwner', 'LocalState', 'QueueReason') -Rows $queueRows
    } else {
        $branchLines += '| 仓库 | 分支 | 原因 |'
        $branchLines += '|---|---|---|'
        $branchLines += '| 无 | - | 当前已发现本地 clone 的仓库均已同步 |'
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
            NameWithOwner = 'Codex 默认联动'
            Visibility    = '规则'
            LocalState    = '实际修改任意 Git 工作区后，默认提交/推送目标仓库并同步本索引'
            NextAction    = '用户明确要求只本地、不提交或不推送时跳过'
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
    $dashboardLines += '1. Codex 实际修改任意 Git 工作区后，默认同步目标仓库，再同步本索引。'
    $dashboardLines += '2. 对未推送队列中的公开仓库先做暴露面审查。'
    $dashboardLines += '3. 对未发现 clone 的仓库决定是否 clone 到固定目录或标记远端存档。'
    $dashboardLines += '4. 若私有仓库可见性发生变化，立即重新审计密钥备份策略。'
    Set-TextFile -Path (Join-Path $RepoRoot '00_总览/当前同步看板.md') -Lines $dashboardLines
}

function Invoke-UpdateGitHubIndex {
    param(
        [string] $Owner = 'wlyaaaaa',
        [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot),
        [string[]] $ScanRoots = @('C:\Users\10979', 'E:\', 'G:\'),
        [switch] $SkipFetch,
        [switch] $NoWrite
    )

    $repositories = @(Get-GitHubRepositories -Owner $Owner)
    $cloneMap = Get-LocalCloneMap -Roots $ScanRoots -SkipFetch:$SkipFetch
    Resolve-CloneStatuses -CloneMap $cloneMap -Repositories $repositories -SkipFetch:$SkipFetch
    $rows = @(ConvertTo-GitHubIndexRows -Repositories $repositories -CloneMap $cloneMap)

    if (-not $NoWrite) {
        Write-GitHubIndexDocuments -RepoRoot $RepoRoot -Owner $Owner -Rows $rows
    }

    return $rows
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-UpdateGitHubIndex -Owner $Owner -RepoRoot $RepoRoot -ScanRoots $ScanRoots -SkipFetch:$SkipFetch -NoWrite:$NoWrite
}
