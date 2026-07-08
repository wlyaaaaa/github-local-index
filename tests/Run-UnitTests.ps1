#requires -Version 7.0

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'tools/Update-GitHubIndex.ps1')
. (Join-Path $repoRoot 'tools/Update-ScheduledTaskHealth.ps1')
. (Join-Path $repoRoot 'tools/Update-UserAutomationMap.ps1')

$script:Failures = 0

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)] [object] $Expected,
        [Parameter(Mandatory = $true)] [object] $Actual,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    if ($Expected -ne $Actual) {
        Write-Host "FAIL: $Name"
        Write-Host "  expected: $Expected"
        Write-Host "  actual:   $Actual"
        $script:Failures++
        return
    }

    Write-Host "PASS: $Name"
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)] [bool] $Condition,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    if (-not $Condition) {
        Write-Host "FAIL: $Name"
        $script:Failures++
        return
    }

    Write-Host "PASS: $Name"
}

Assert-Equal 'wlyaaaaa/TURZX-SideScreen' (Normalize-GitHubRepoSlug 'https://github.com/wlyaaaaa/TURZX-SideScreen.git') 'normalizes HTTPS remotes'
Assert-Equal 'wlyaaaaa/Key' (Normalize-GitHubRepoSlug 'git@github.com:wlyaaaaa/Key.git') 'normalizes SSH remotes'
Assert-Equal 'wlyaaaaa/ai-llm-job-prep' (Normalize-GitHubRepoSlug 'ssh://git@github.com/wlyaaaaa/ai-llm-job-prep.git') 'normalizes ssh:// remotes'

$script:RetryAttempts = 0
$retryResult = Invoke-ExternalCommandWithRetry -Operation 'unit retry success' -MaxAttempts 3 -DelaySeconds 0 -Command {
    $script:RetryAttempts++
    if ($script:RetryAttempts -lt 3) {
        throw 'temporary failure'
    }

    return 'ok'
}
Assert-Equal 3 $script:RetryAttempts 'retries transient external command failures'
Assert-Equal 'ok' ($retryResult -join '') 'returns successful retry output'

$script:RetryFailureAttempts = 0
$retryFailureThrown = $false
try {
    Invoke-ExternalCommandWithRetry -Operation 'unit retry failure' -MaxAttempts 2 -DelaySeconds 0 -Command {
        $script:RetryFailureAttempts++
        throw 'still failing'
    } | Out-Null
}
catch {
    $retryFailureThrown = $_.Exception.Message -match 'unit retry failure'
}
Assert-Equal 2 $script:RetryFailureAttempts 'stops retrying after max attempts'
Assert-True $retryFailureThrown 'retry failure includes operation name'

$tempRepo = Join-Path $repoRoot ('99_private\unit-test-root-repo-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $tempRepo '.git') | Out-Null
Set-Content -LiteralPath (Join-Path $tempRepo '.git/config') -Value @'
[remote "origin"]
    url = https://github.com/wlyaaaaa/TURZX-SideScreen.git
'@ -Encoding UTF8
try {
    $rootConfigPaths = @(Get-GitConfigPaths -Roots @($tempRepo))
    Assert-Equal (Join-Path $tempRepo '.git\config') $rootConfigPaths[0] 'discovers git config when scan root is repository'
}
finally {
    Remove-Item -LiteralPath $tempRepo -Recurse -Force -ErrorAction SilentlyContinue
}

$repos = @(
    [pscustomobject]@{
        nameWithOwner    = 'wlyaaaaa/TURZX-SideScreen'
        visibility       = 'PUBLIC'
        url              = 'https://github.com/wlyaaaaa/TURZX-SideScreen'
        defaultBranchRef = [pscustomobject]@{ name = 'main' }
        pushedAt         = '2026-07-05T05:22:00Z'
        updatedAt        = '2026-07-05T05:22:34Z'
    },
    [pscustomobject]@{
        nameWithOwner    = 'wlyaaaaa/Key'
        visibility       = 'PRIVATE'
        url              = 'https://github.com/wlyaaaaa/Key'
        defaultBranchRef = [pscustomobject]@{ name = 'main' }
        pushedAt         = '2026-07-01T00:00:00Z'
        updatedAt        = '2026-07-01T00:00:00Z'
    }
)

$cloneMap = @{
    'wlyaaaaa/TURZX-SideScreen' = @(
        [pscustomobject]@{
            Path        = 'E:\TURZX-SideScreen'
            Branch      = 'main'
            Upstream    = 'origin/main'
            Ahead       = 0
            Behind      = 0
            DirtyCount  = 0
            State       = '`main` 已同步，`0/0`'
            NextAction  = '正常维护'
            IsDirty     = $false
            NeedsReview = $false
        }
    )
}

$rows = @(ConvertTo-GitHubIndexRows -Repositories $repos -CloneMap $cloneMap)
$turzx = $rows | Where-Object { $_.NameWithOwner -eq 'wlyaaaaa/TURZX-SideScreen' }
$key = $rows | Where-Object { $_.NameWithOwner -eq 'wlyaaaaa/Key' }
$sortedRows = @(Sort-GitHubIndexRows @(
    [pscustomobject]@{ NameWithOwner = 'wlyaaaaa/zeta' },
    [pscustomobject]@{ NameWithOwner = 'wlyaaaaa/alpha' }
))

Assert-Equal 'E:\TURZX-SideScreen' $turzx.LocalPath 'marks discovered clone path'
Assert-Equal '`main` 已同步，`0/0`' $turzx.LocalState 'uses clone sync state'
Assert-Equal '未发现本地 clone' $key.LocalPath 'marks missing clone path'
Assert-True ($key.NextAction -match '确认本机没有 clone') 'keeps Key as confirmed missing clone'
Assert-True ($key.NextAction -match '严格禁止克隆') 'keeps Key as do-not-clone repository'
Assert-True (-not ($key.NextAction -match 'clone 到')) 'does not suggest cloning Key'
Assert-Equal 'wlyaaaaa/alpha' $sortedRows[0].NameWithOwner 'sorts github index rows deterministically'

$normalTask = ConvertTo-TaskResultAssessment -LastTaskResult 0
$normalTaskRow = ConvertTo-PublicTaskRow `
    -Task ([pscustomobject]@{ TaskName = 'Demo Backup'; TaskPath = '\'; State = 'Ready' }) `
    -Info ([pscustomobject]@{ LastTaskResult = 0; LastRunTime = '2026-07-05T00:00:00'; NextRunTime = '2026-07-05T12:00:00' })
$disabledTaskRow = ConvertTo-PublicTaskRow `
    -Task ([pscustomobject]@{ TaskName = 'Disabled Backup'; TaskPath = '\'; State = 'Disabled' }) `
    -Info ([pscustomobject]@{ LastTaskResult = 267011; LastRunTime = '1999-11-30T00:00:00'; NextRunTime = '2026-07-05T13:00:00' })
$interruptedUnsigned = ConvertTo-TaskResultAssessment -LastTaskResult 3221225786
$interruptedSigned = ConvertTo-TaskResultAssessment -LastTaskResult -1073741510

Assert-Equal '正常' $normalTask.Severity 'classifies zero task result'
Assert-Equal '0 / 0x00000000' $normalTaskRow.LastTaskResult 'keeps zero task result visible'
Assert-Equal '信息' $disabledTaskRow.Severity 'marks disabled task warning as informational'
Assert-Equal '' $disabledTaskRow.NextRunTime 'omits volatile next run time for disabled tasks'
Assert-Equal '异常' $interruptedUnsigned.Severity 'classifies unsigned interrupted task result'
Assert-Equal '异常' $interruptedSigned.Severity 'classifies signed interrupted task result'
Assert-True ($interruptedUnsigned.Summary -match '中断') 'explains interrupted task result'

$userTask = [pscustomobject]@{
    TaskName = 'Codex Memory Backup'
    TaskPath = '\'
    Actions = @([pscustomobject]@{
        Execute = 'wscript.exe'
        Arguments = '"E:\CodexMemoryBackup\tools\codex_memory_backup_hidden.vbs" --token secret'
    })
}
$systemTask = [pscustomobject]@{
    TaskName = 'GoogleUpdateTaskMachineUA'
    TaskPath = '\'
    Actions = @([pscustomobject]@{
        Execute = 'C:\Program Files (x86)\Google\Update\GoogleUpdate.exe'
        Arguments = '/ua'
    })
}
$softwareAutostartTask = [pscustomobject]@{
    TaskName = 'AIDA64 AutoStart'
    TaskPath = '\'
    Actions = @([pscustomobject]@{
        Execute = 'E:\Downloads\aida64extreme800\aida64.exe'
        Arguments = ''
    })
}
$downloadsSyncTask = [pscustomobject]@{
    TaskName = 'DownloadsToUSB-Daily'
    TaskPath = '\'
    Actions = @([pscustomobject]@{
        Execute = 'wscript.exe'
        Arguments = '"E:\Scripts\Sync-DownloadsToH-Hidden.vbs"'
    })
}

$actionSummary = Get-PublicActionSummary -Task $userTask
$purpose = Get-TaskPurposeInference -TaskName 'WeFlow Watchdog' -ActionSummary 'powershell.exe -> E:\WeFlowBridge\weflow_heartbeat.ps1'
$downloadsActionSummary = Get-PublicActionSummary -Task $downloadsSyncTask
$downloadsPurpose = Get-TaskPurposeInference -TaskName 'DownloadsToUSB-Daily' -ActionSummary $downloadsActionSummary
$downloadsRelatedPath = Get-RelatedPathHint -TaskName 'DownloadsToUSB-Daily' -ActionSummary $downloadsActionSummary
$memoryRecommendation = Get-RepositoryTaskRecommendation -NameWithOwner 'wlyaaaaa/codex-memory' -LocalPath 'E:\CodexMemoryBackup' -Visibility 'PRIVATE' -ExistingTaskHints @('Codex Memory Backup')
$publicRecommendation = Get-RepositoryTaskRecommendation -NameWithOwner 'wlyaaaaa/md-triple-tactics-talent-solver' -LocalPath 'E:\Pictures\三战之才' -Visibility 'PUBLIC' -ExistingTaskHints @()
$agentsRecommendation = Get-RepositoryTaskRecommendation -NameWithOwner 'wlyaaaaa/.agents' -LocalPath 'E:\.agents' -Visibility 'PRIVATE' -ExistingTaskHints @()
$aiCoachRecommendation = Get-RepositoryTaskRecommendation -NameWithOwner 'wlyaaaaa/ai-coach' -LocalPath 'G:\ai-coach' -Visibility 'PRIVATE' -ExistingTaskHints @()
$steamRecommendation = Get-RepositoryTaskRecommendation -NameWithOwner 'wlyaaaaa/steam-millennium-config-backup' -LocalPath 'E:\steam-millennium-config-backup' -Visibility 'PUBLIC' -ExistingTaskHints @()
$steamCoveredRecommendation = Get-RepositoryTaskRecommendation -NameWithOwner 'wlyaaaaa/steam-millennium-config-backup' -LocalPath 'E:\steam-millennium-config-backup' -Visibility 'PUBLIC' -ExistingTaskHints @('SteamMillenniumConfigSnapshot')
$indexCoveredRecommendation = Get-RepositoryTaskRecommendation -NameWithOwner 'wlyaaaaa/github-local-index' -LocalPath 'E:\GitHub总索引' -Visibility 'PUBLIC' -ExistingTaskHints @('GitHubLocalIndex Refresh')
$indexRefreshScriptPath = Join-Path $repoRoot 'tools/Refresh-GitHubLocalIndex.ps1'
$indexRefreshHiddenLauncherPath = Join-Path $repoRoot 'tools/Refresh-GitHubLocalIndex-Hidden.vbs'
$indexRegisterScriptPath = Join-Path $repoRoot 'tools/Register-GitHubLocalIndexRefreshTask.ps1'
$taskHealthScriptPath = Join-Path $repoRoot 'tools/Update-ScheduledTaskHealth.ps1'

Assert-True (Test-IsUserAutomationTask -Task $userTask) 'classifies user-owned backup task'
Assert-True (-not (Test-IsUserAutomationTask -Task $systemTask)) 'excludes common software updater task'
Assert-True (-not (Test-IsUserAutomationTask -Task $softwareAutostartTask)) 'excludes common software autostart task'
Assert-True ($actionSummary -match 'wscript.exe') 'keeps executable name in public action summary'
Assert-True ($actionSummary -match 'E:\\CodexMemoryBackup\\tools\\codex_memory_backup_hidden.vbs') 'keeps sanitized script path in public action summary'
Assert-True (-not ($actionSummary -match 'secret')) 'redacts action arguments after known script path'
Assert-True ($purpose.Purpose -match '看门狗|心跳') 'infers watchdog purpose'
Assert-Equal 'E:\Downloads -> H:\03_下载与安装包' $downloadsRelatedPath 'maps downloads usb sync to source and target paths'
Assert-True ($downloadsPurpose.Purpose -match '下载目录同步') 'infers downloads usb sync purpose'
Assert-True ($downloadsPurpose.Risk -match '不删除') 'documents downloads sync no-delete risk control'
Assert-Equal '已有任务覆盖' $memoryRecommendation.Decision 'recognizes existing private backup task coverage'
Assert-Equal '不建议新增' $publicRecommendation.Decision 'does not auto-schedule public content repository'
Assert-Equal '不建议新增' $agentsRecommendation.Decision 'does not auto-schedule private rules source repository'
Assert-Equal '不建议新增' $aiCoachRecommendation.Decision 'does not auto-schedule ai coach learning audit repository'
Assert-True ($aiCoachRecommendation.Purpose -match '学习|复盘|审计') 'classifies ai coach as learning audit repository'
Assert-Equal '建议新增' $steamRecommendation.Decision 'recommends low-frequency steam millennium config snapshot'
Assert-Equal '已有任务覆盖' $steamCoveredRecommendation.Decision 'recognizes steam snapshot task coverage'
Assert-Equal '已有任务覆盖' $indexCoveredRecommendation.Decision 'recognizes github index refresh task coverage'
Assert-True (Test-Path -LiteralPath $indexRefreshScriptPath) 'has github local index refresh wrapper'
if (Test-Path -LiteralPath $indexRefreshScriptPath) {
    $indexRefreshScript = Get-Content -LiteralPath $indexRefreshScriptPath -Raw
    Assert-True ($indexRefreshScript -match 'Update-GitHubIndex\.ps1') 'refresh wrapper updates github index'
    Assert-True ($indexRefreshScript -match '-SkipFetch') 'refresh wrapper avoids fetching other repositories'
    Assert-True ($indexRefreshScript -match 'Update-ScheduledTaskHealth\.ps1') 'refresh wrapper updates task health'
    Assert-True ($indexRefreshScript -match 'Update-UserAutomationMap\.ps1') 'refresh wrapper updates user automation map'
    Assert-True ($indexRefreshScript -match 'Test-GitHubLocalIndexConsistency\.ps1') 'refresh wrapper can run consistency check'
    Assert-True ($indexRefreshScript -match 'CheckOnly') 'refresh wrapper supports check-only consistency mode'
    Assert-True (-not ($indexRefreshScript -match 'git\s+(commit|push)')) 'refresh wrapper does not auto commit or push'
    Assert-True ($indexRefreshScript -match 'E:\\Scoop\\shims') 'refresh wrapper adds Scoop shims for scheduled task PATH'
    Assert-True ($indexRefreshScript -match 'FAILED') 'refresh wrapper logs failed refresh steps'
}

Assert-True (Test-Path -LiteralPath $indexRefreshHiddenLauncherPath) 'has github local index zero-flash launcher'
if (Test-Path -LiteralPath $indexRefreshHiddenLauncherPath) {
    $indexRefreshHiddenLauncher = Get-Content -LiteralPath $indexRefreshHiddenLauncherPath -Raw
    Assert-True ($indexRefreshHiddenLauncher -match 'shell\.Run\(command, 0, True\)') 'zero-flash launcher waits hidden and preserves exit code'
    Assert-True ($indexRefreshHiddenLauncher -match 'pwsh\.exe') 'zero-flash launcher prefers PowerShell 7 for UTF-8 scripts'
    Assert-True ($indexRefreshHiddenLauncher -match 'powershell\.exe') 'zero-flash launcher falls back to Windows PowerShell'
    Assert-True ($indexRefreshHiddenLauncher -match 'CheckOnly') 'zero-flash launcher supports check-only consistency mode'
}

Assert-True (Test-Path -LiteralPath $indexRegisterScriptPath) 'has github local index task registration script'
if (Test-Path -LiteralPath $indexRegisterScriptPath) {
    $indexRegisterScript = Get-Content -LiteralPath $indexRegisterScriptPath -Raw
    Assert-True ($indexRegisterScript -match 'wscript\.exe') 'refresh task registration uses zero-flash launcher'
    Assert-True ($indexRegisterScript -match 'Refresh-GitHubLocalIndex-Hidden\.vbs') 'refresh task registration points at hidden VBS launcher'
    Assert-True ($indexRegisterScript -match 'CheckOnly') 'refresh task registration supports check-only consistency task'
    Assert-True ($indexRegisterScript -match 'GitHubLocalIndex Consistency Check') 'refresh task registration has consistency task default name'
}

Assert-True (Test-Path -LiteralPath $taskHealthScriptPath) 'has scheduled task health script'
if (Test-Path -LiteralPath $taskHealthScriptPath) {
    $taskHealthScript = Get-Content -LiteralPath $taskHealthScriptPath -Raw
    Assert-True ($taskHealthScript -match '\*GitHubLocalIndex\*') 'health summary tracks github local index task'
    Assert-True ($taskHealthScript -match '\*SteamMillennium\*') 'health summary tracks steam millennium task'
}

$consistencyScriptPath = Join-Path $repoRoot 'tools/Test-GitHubLocalIndexConsistency.ps1'
Assert-True (Test-Path -LiteralPath $consistencyScriptPath) 'has github local index consistency check script'
if (Test-Path -LiteralPath $consistencyScriptPath) {
    . $consistencyScriptPath

    $generatedDocPaths = @(Get-GitHubLocalIndexGeneratedDocumentPaths)
    Assert-True ($generatedDocPaths -contains '00_总览\当前同步看板.md') 'consistency check covers dashboard'
    Assert-True ($generatedDocPaths -contains '02_同步诊断\未推送队列.md') 'consistency check covers queue'
    Assert-True ($generatedDocPaths -contains '04_计划任务\用户自动化任务地图.md') 'consistency check covers automation map'
    $stableDocPaths = @(Get-GitHubLocalIndexStableDocumentPaths)
    Assert-True ($stableDocPaths -contains '02_同步诊断\未推送队列.md') 'consistency check treats queue as stable'
    Assert-True (-not ($stableDocPaths -contains '04_计划任务\计划任务健康摘要.md')) 'consistency check treats task health as volatile'

    $compareRoot = Join-Path $repoRoot ('99_private\unit-test-consistency-' + [guid]::NewGuid().ToString('N'))
    $currentRoot = Join-Path $compareRoot 'current'
    $generatedRoot = Join-Path $compareRoot 'generated'
    try {
        New-Item -ItemType Directory -Force -Path $currentRoot, $generatedRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $currentRoot 'same.md') -Value "same`n" -Encoding UTF8 -NoNewline
        Set-Content -LiteralPath (Join-Path $generatedRoot 'same.md') -Value "same`n" -Encoding UTF8 -NoNewline
        Set-Content -LiteralPath (Join-Path $currentRoot 'different.md') -Value "old`n" -Encoding UTF8 -NoNewline
        Set-Content -LiteralPath (Join-Path $generatedRoot 'different.md') -Value "new`nextra`n" -Encoding UTF8 -NoNewline
        Set-Content -LiteralPath (Join-Path $generatedRoot 'missing-current.md') -Value "generated only`n" -Encoding UTF8 -NoNewline
        New-Item -ItemType Directory -Force -Path `
            (Join-Path $currentRoot '01_仓库索引'), `
            (Join-Path $currentRoot '02_同步诊断'), `
            (Join-Path $generatedRoot '01_仓库索引'), `
            (Join-Path $generatedRoot '02_同步诊断') | Out-Null

        $selfIndexPath = '01_仓库索引\GitHub仓库索引.md'
        $selfClonePath = '01_仓库索引\本地clone索引.md'
        $selfBranchPath = '02_同步诊断\分支与远端诊断.md'
        Set-Content -LiteralPath (Join-Path $currentRoot $selfIndexPath) -Value '| wlyaaaaa/github-local-index | PUBLIC | main | E:\GitHub总索引 | 本次刷新目标仓库；提交推送后复查 | 提交并推送本索引刷新结果 |' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $generatedRoot $selfIndexPath) -Value '| wlyaaaaa/github-local-index | PUBLIC | main | E:\GitHub总索引 | `main` 已同步，`0/0` | 正常维护 |' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $currentRoot $selfClonePath) -Value '| wlyaaaaa/github-local-index | E:\GitHub总索引 | 本次刷新目标仓库；提交推送后复查 |' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $generatedRoot $selfClonePath) -Value '| wlyaaaaa/github-local-index | E:\GitHub总索引 | `main` 已同步，`0/0` |' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $currentRoot $selfBranchPath) -Value '| wlyaaaaa/github-local-index | E:\GitHub总索引 | 本次刷新目标仓库；提交推送后复查 |' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $generatedRoot $selfBranchPath) -Value '| wlyaaaaa/github-local-index | E:\GitHub总索引 | `main` 已同步，`0/0` |' -Encoding UTF8

        $comparisonRows = @(Compare-GitHubLocalIndexDocuments -RepoRoot $currentRoot -GeneratedRoot $generatedRoot -RelativePaths @('same.md', 'different.md', 'missing-current.md', $selfIndexPath, $selfClonePath, $selfBranchPath))
        $sameRow = $comparisonRows | Where-Object { $_.File -eq 'same.md' }
        $differentRow = $comparisonRows | Where-Object { $_.File -eq 'different.md' }
        $missingCurrentRow = $comparisonRows | Where-Object { $_.File -eq 'missing-current.md' }
        $selfIndexRow = $comparisonRows | Where-Object { $_.File -eq $selfIndexPath }
        $selfCloneRow = $comparisonRows | Where-Object { $_.File -eq $selfClonePath }
        $selfBranchRow = $comparisonRows | Where-Object { $_.File -eq $selfBranchPath }

        Assert-Equal 6 $comparisonRows.Count 'compares requested consistency document set'
        Assert-True $sameRow.Same 'marks identical generated documents consistent'
        Assert-True (-not $differentRow.Same) 'marks changed generated documents inconsistent'
        Assert-Equal 1 $differentRow.CurrentLines 'counts current document lines'
        Assert-Equal 2 $differentRow.GeneratedLines 'counts generated document lines'
        Assert-True (-not $missingCurrentRow.CurrentExists) 'records missing current document'
        Assert-True $selfIndexRow.Same 'ignores self-index placeholder drift in repository index'
        Assert-True $selfCloneRow.Same 'ignores self-index placeholder drift in clone index'
        Assert-True $selfBranchRow.Same 'ignores self-index placeholder drift in branch diagnostics'
    }
    finally {
        Remove-Item -LiteralPath $compareRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($script:Failures -gt 0) {
    throw "$script:Failures test(s) failed"
}

Write-Host 'All unit tests passed.'
