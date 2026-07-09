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
    $lastOutput = @()
    $lastError = $null

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $global:LASTEXITCODE = 0
        try {
            $output = @(& $Command 2>&1)
            $exitCode = $LASTEXITCODE
            if ($null -eq $exitCode) {
                $exitCode = 0
            }
        }
        catch {
            $output = @($_.Exception.Message)
            $exitCode = if ($LASTEXITCODE -ne 0) { $LASTEXITCODE } else { 1 }
            $lastError = $_
        }

        $lastExitCode = $exitCode
        $lastOutput = $output

        if ($exitCode -eq 0) {
            return $output
        }

        if ($attempt -lt $MaxAttempts -and $DelaySeconds -gt 0) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    $summary = ($lastOutput | Select-Object -First 3) -join ' '
    if ([string]::IsNullOrWhiteSpace($summary) -and $lastError) {
        $summary = $lastError.Exception.Message
    }

    throw "$Operation failed after $MaxAttempts attempt(s). Last exit code: $lastExitCode. $summary"
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
        $rgConfigs = @(& rg @args 2>$null | Where-Object { -not (Test-IsTransientGitConfigPath $_) })
        return @(@($rootConfigs) + $rgConfigs | Sort-Object -Unique)
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

function Get-GitRepositorySeedPaths {
    param([string[]] $Roots)

    $existingRoots = @($Roots | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
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
                '-g', '!**/.cache/**'
            )
            $gitMarkers = @(& rg @arguments 2>$null)
        }
        else {
            $gitMarkers = @(foreach ($root in $rootsToScan) {
                Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -eq '.git' -or $_.FullName -match '\\.git\\config$' } |
                    Select-Object -ExpandProperty FullName
            })
        }

        foreach ($marker in $gitMarkers) {
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
            if ($seed -and -not (Test-IsTransientClonePath -Path $seed)) {
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
            if ($line -notmatch '^\|\s*[^|]+/[^|]+\|\s*(?<paths>[^|]+?)\s*\|') {
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
        if (Test-IsTransientClonePath -Path $repoPath) {
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
            if (@($clones | Where-Object { [string]::IsNullOrWhiteSpace([string] $_.Upstream) }).Count -gt 0) { $reasons += '无 upstream' }
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
        [switch] $SkipFetch
    )

    foreach ($repo in $Repositories) {
        $name = [string] $repo.nameWithOwner
        if (-not $CloneMap.ContainsKey($name)) {
            continue
        }

        $resolved = foreach ($clone in @($CloneMap[$name])) {
            $metadataJson = $repo | ConvertTo-Json -Depth 6 -Compress
            $metadataInvoker = { param($slug) [pscustomobject]@{ exit_code = 0; stdout = $metadataJson; stderr = '' } }.GetNewClosure()
            $admission = Get-ProjectAdmissionRecord `
                -Repo $name `
                -RepoPath $clone.Path `
                -Visibility ([string] $repo.visibility) `
                -DefaultBranch (Get-DefaultBranchName -Repository $repo) `
                -Fetch:(-not $SkipFetch) `
                -GitHubInvoker $metadataInvoker

            $repoErrorReasons = @($admission.errors | ForEach-Object { [string] $_.category })
            foreach ($worktree in @($admission.worktrees)) {
                $inspectionFailed = [bool] $worktree.inspection_error
                $ahead = if ($inspectionFailed -and $null -eq $worktree.ahead) { $null } elseif ($null -eq $worktree.ahead) { 0 } else { [int] $worktree.ahead }
                $behind = if ($inspectionFailed -and $null -eq $worktree.behind) { $null } elseif ($null -eq $worktree.behind) { 0 } else { [int] $worktree.behind }
                $dirtyCount = if ($inspectionFailed -and $null -eq $worktree.dirty_count) { $null } elseif ($null -eq $worktree.dirty_count) { 0 } else { [int] $worktree.dirty_count }
                $hasUpstream = -not [string]::IsNullOrWhiteSpace([string] $worktree.upstream)
                $state = if ($inspectionFailed) {
                    'worktree 检查失败（状态未知）'
                }
                elseif (-not $worktree.exists -or $worktree.prunable) {
                    'prunable worktree（路径缺失）'
                }
                else {
                    Get-RepoStateText -Branch ([string] $worktree.branch) -HasUpstream:$hasUpstream -Ahead $ahead -Behind $behind -DirtyCount $dirtyCount
                }
                $state += "（$($admission.remote_mode)）"

                $queueReasons = [System.Collections.Generic.List[string]]::new()
                if ($worktree.prunable) { $queueReasons.Add('prunable worktree') }
                if ($worktree.detached) { $queueReasons.Add('detached worktree') }
                if ($admission.remote_mode -eq 'cached') { $queueReasons.Add('cached 远端引用') }
                foreach ($errorReason in $repoErrorReasons) { $queueReasons.Add($errorReason) }
                $nextAction = if ($repoErrorReasons.Count -gt 0) {
                    '远端观察失败；当前仅使用 cached 引用，需人工复查'
                }
                elseif ($worktree.prunable) {
                    '清理或恢复 prunable worktree 元数据'
                }
                else {
                    Get-RepoNextAction -Visibility ([string] $repo.visibility) -HasUpstream:$hasUpstream -Ahead $ahead -Behind $behind -DirtyCount $dirtyCount
                }

                [pscustomobject]@{
                    Path = $worktree.path
                    Branch = [string] $worktree.branch
                    Upstream = [string] $worktree.upstream
                    Ahead = $ahead
                    Behind = $behind
                    DirtyCount = $dirtyCount
                    State = $state
                    NextAction = $nextAction
                    IsDirty = $dirtyCount -gt 0
                    NeedsReview = $inspectionFailed -or $repoErrorReasons.Count -gt 0 -or $worktree.prunable -or (-not $hasUpstream) -or $ahead -gt 0 -or $behind -gt 0 -or $dirtyCount -gt 0
                    QueueReasons = @($queueReasons)
                    RemoteMode = $admission.remote_mode
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
    $syncedRows = @($Rows | Where-Object { $_.HasLocalClone -and -not $_.NeedsReview } | Sort-Object NameWithOwner)
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
    $dashboardLines += '1. 用 `tools\Get-ProjectAdmission.ps1 -Repo <owner/name> -Json` 获取单仓库 admission 结论。'
    $dashboardLines += '2. 定期运行 `tools\Test-GitHubLocalIndexConsistency.ps1 -SkipFetch`；只读检查不得提交或推送。'
    $dashboardLines += '3. 对未推送队列中的公开仓库先做暴露面审查。'
    $dashboardLines += '4. 对未发现 clone 的仓库决定是否进入统一目录或标记远端存档；`wlyaaaaa/Key` 始终禁止克隆。'
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
