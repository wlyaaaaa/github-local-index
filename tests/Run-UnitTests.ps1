#requires -Version 7.0

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'tools/Update-GitHubIndex.ps1')
. (Join-Path $repoRoot 'tools/Update-ScheduledTaskHealth.ps1')
. (Join-Path $repoRoot 'tools/Update-UserAutomationMap.ps1')
. (Join-Path $repoRoot 'tools/Test-GitHubLocalIndexConsistency.ps1')

$script:Failures = 0

function Assert-Equal {
    param(
        [AllowNull()] [object] $Expected,
        [AllowNull()] [object] $Actual,
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
Assert-Equal 'wlyaaaaa/ai-llm-job-prep' (Normalize-GitHubRepoSlug 'ssh://git@github.com/wlyaaaaa/ai-llm-job-prep.git') 'normalizes ssh URL remotes'

$script:RetryAttempts = 0
$retryResult = Invoke-ExternalCommandWithRetry -Operation 'unit retry success' -MaxAttempts 3 -DelaySeconds 0 -Command {
    $script:RetryAttempts++
    if ($script:RetryAttempts -lt 3) {
        throw 'temporary failure'
    }
    'ok'
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

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('github-index-unit-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot '.git') | Out-Null
    Set-Content -LiteralPath (Join-Path $tempRoot '.git/config') -Value @'
[remote "origin"]
    url = https://github.com/wlyaaaaa/TURZX-SideScreen.git
'@ -Encoding utf8
    $rootConfigPaths = @(Get-GitConfigPaths -Roots @($tempRoot))
    Assert-Equal (Join-Path $tempRoot '.git\config') $rootConfigPaths[0] 'discovers git config when scan root is repository'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

$seedDiscovery = Get-Command Get-GitRepositorySeedPaths -ErrorAction SilentlyContinue
Assert-True ($null -ne $seedDiscovery) 'repository discovery exposes common-dir/worktree seed enumeration'
if ($seedDiscovery) {
    $seedRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('github-index-seed-' + [guid]::NewGuid().ToString('N'))
    $primarySeed = Join-Path $seedRoot 'primary'
    $linkedSeed = Join-Path $seedRoot 'linked-only-scan-root'
    try {
        & git init --initial-branch=main $primarySeed 2>&1 | Out-Null
        & git -C $primarySeed config user.name 'Seed Test'
        & git -C $primarySeed config user.email 'seed@example.invalid'
        Set-Content -LiteralPath (Join-Path $primarySeed 'seed.txt') -Value 'seed' -Encoding utf8
        & git -C $primarySeed add seed.txt 2>&1 | Out-Null
        & git -C $primarySeed commit -m seed 2>&1 | Out-Null
        & git -C $primarySeed worktree add -b linked-seed $linkedSeed 2>&1 | Out-Null
        $seeds = @(Get-GitRepositorySeedPaths -Roots @($linkedSeed))
        Assert-True ($seeds -contains [System.IO.Path]::GetFullPath($linkedSeed)) 'discovers a linked worktree when its primary checkout is outside scan roots'
    }
    finally {
        if (Test-Path -LiteralPath $seedRoot) { Remove-Item -LiteralPath $seedRoot -Recurse -Force }
    }
}

$inspectionRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('github-index-inspection-' + [guid]::NewGuid().ToString('N'))
try {
    & git init --initial-branch=main $inspectionRoot 2>&1 | Out-Null
    & git -C $inspectionRoot config user.name 'Inspection Test'
    & git -C $inspectionRoot config user.email 'inspection@example.invalid'
    Set-Content -LiteralPath (Join-Path $inspectionRoot 'fixture.txt') -Value 'fixture' -Encoding utf8
    & git -C $inspectionRoot add fixture.txt 2>&1 | Out-Null
    & git -C $inspectionRoot commit -m fixture 2>&1 | Out-Null
    & git -C $inspectionRoot remote add origin 'https://github.com/wlyaaaaa/inspection-fixture.git'
    $inspectionIndex = [string] (& git -C $inspectionRoot rev-parse --git-path index)
    if (-not [System.IO.Path]::IsPathRooted($inspectionIndex)) { $inspectionIndex = Join-Path $inspectionRoot $inspectionIndex }
    [System.IO.File]::WriteAllBytes($inspectionIndex, [byte[]] @(1, 2, 3, 4))

    $inspectionRepositories = @([pscustomobject]@{
        nameWithOwner = 'wlyaaaaa/inspection-fixture'
        visibility = 'PRIVATE'
        url = 'https://github.com/wlyaaaaa/inspection-fixture'
        defaultBranchRef = [pscustomobject]@{ name = 'main' }
    })
    $inspectionCloneMap = @{
        'wlyaaaaa/inspection-fixture' = @([pscustomobject]@{ Path = $inspectionRoot })
    }
    Resolve-CloneStatuses -CloneMap $inspectionCloneMap -Repositories $inspectionRepositories -SkipFetch
    $inspectionRow = @($inspectionCloneMap['wlyaaaaa/inspection-fixture'])[0]
    Assert-True ($null -eq $inspectionRow.DirtyCount) 'generator does not coerce failed worktree inspection to dirty count zero'
    Assert-True ($inspectionRow.State -match '检查失败') 'generator labels failed worktree inspection explicitly'
    Assert-True ($inspectionRow.QueueReasons -contains 'worktree_inspection_failed') 'generator preserves worktree inspection error category'
    Assert-True $inspectionRow.NeedsReview 'generator always queues failed worktree inspection for review'
}
finally {
    if (Test-Path -LiteralPath $inspectionRoot) { Remove-Item -LiteralPath $inspectionRoot -Recurse -Force }
}

$repositories = @(
    [pscustomobject]@{
        nameWithOwner = 'wlyaaaaa/demo'
        visibility = 'PUBLIC'
        url = 'https://github.com/wlyaaaaa/demo'
        defaultBranchRef = [pscustomobject]@{ name = 'main' }
        pushedAt = '2026-07-01T00:00:00Z'
        updatedAt = '2026-07-01T00:00:00Z'
    },
    [pscustomobject]@{
        nameWithOwner = 'wlyaaaaa/Key'
        visibility = 'PRIVATE'
        url = 'https://github.com/wlyaaaaa/Key'
        defaultBranchRef = [pscustomobject]@{ name = 'main' }
        pushedAt = '2026-07-01T00:00:00Z'
        updatedAt = '2026-07-01T00:00:00Z'
    }
)

$cloneMap = @{
    'wlyaaaaa/demo' = @(
        [pscustomobject]@{
            Path = 'E:\demo'
            Branch = 'main'
            Upstream = 'origin/main'
            Ahead = 1
            Behind = 0
            DirtyCount = 0
            State = 'main ahead 1'
            NextAction = 'review ahead'
            IsDirty = $false
            NeedsReview = $true
        },
        [pscustomobject]@{
            Path = 'E:\demo-worktree'
            Branch = 'feature'
            Upstream = ''
            Ahead = 0
            Behind = 2
            DirtyCount = 3
            State = 'feature no upstream and dirty'
            NextAction = 'review worktree'
            IsDirty = $true
            NeedsReview = $true
        }
    )
}

$rows = @(ConvertTo-GitHubIndexRows -Repositories $repositories -CloneMap $cloneMap)
$demoRow = $rows | Where-Object NameWithOwner -eq 'wlyaaaaa/demo'
$keyRow = $rows | Where-Object NameWithOwner -eq 'wlyaaaaa/Key'
Assert-True ($demoRow.QueueReason -match 'ahead 1') 'queue aggregates ahead reason'
Assert-True ($demoRow.QueueReason -match 'behind 2') 'queue aggregates behind reason'
Assert-True ($demoRow.QueueReason -match '脏工作区 3 项') 'queue aggregates dirty reason'
Assert-True ($demoRow.QueueReason -match '无 upstream') 'queue preserves no-upstream reason from a secondary worktree'
Assert-Equal '未发现本地 clone' $keyRow.LocalPath 'marks Key as missing local clone'
Assert-True ($keyRow.NextAction -match '严格禁止克隆') 'keeps Key do-not-clone rule'
Assert-True (-not ($keyRow.NextAction -match 'clone 到')) 'never suggests cloning Key'

$documentRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('github-index-docs-' + [guid]::NewGuid().ToString('N'))
try {
    Write-GitHubIndexDocuments -RepoRoot $documentRoot -Owner 'wlyaaaaa' -Rows $rows
    $overviewPath = Join-Path $documentRoot '00_总览/GitHub总览.md'
    $overviewText = Get-Content -LiteralPath $overviewPath -Raw -Encoding utf8
    Assert-True ($overviewText -match '\| 2 \| 1 \| 1 \| 1 \|') 'overview counts come from the same repository row set'
    $firstOverviewHash = (Get-FileHash -LiteralPath $overviewPath -Algorithm SHA256).Hash
    Write-GitHubIndexDocuments -RepoRoot $documentRoot -Owner 'wlyaaaaa' -Rows $rows
    Assert-Equal $firstOverviewHash (Get-FileHash -LiteralPath $overviewPath -Algorithm SHA256).Hash 'Git document generation is deterministic for a stable row set'
}
finally {
    if (Test-Path -LiteralPath $documentRoot) { Remove-Item -LiteralPath $documentRoot -Recurse -Force }
}

$sortedRows = @(Sort-GitHubIndexRows @(
    [pscustomobject]@{ NameWithOwner = 'wlyaaaaa/zeta' },
    [pscustomobject]@{ NameWithOwner = 'wlyaaaaa/alpha' }
))
Assert-Equal 'wlyaaaaa/alpha' $sortedRows[0].NameWithOwner 'sorts repository rows deterministically'

$normalTask = ConvertTo-TaskResultAssessment -LastTaskResult 0
$interruptedTask = ConvertTo-TaskResultAssessment -LastTaskResult 3221225786
Assert-Equal '正常' $normalTask.Severity 'classifies zero task result'
Assert-Equal '异常' $interruptedTask.Severity 'classifies interrupted task result'
Assert-True ($interruptedTask.Summary -match '中断') 'explains interrupted task result'

$userTask = [pscustomobject]@{
    TaskName = 'Demo Backup'
    TaskPath = '\'
    Actions = @([pscustomobject]@{
        Execute = 'wscript.exe'
        Arguments = '"E:\Projects\Tools\demo\backup.ps1" --token should-not-appear'
    })
}
$actionSummary = Get-PublicActionSummary -Task $userTask
Assert-True ($actionSummary -match 'wscript\.exe') 'keeps executable name in public task summary'
Assert-True ($actionSummary -match 'E:\\Projects\\Tools\\demo\\backup\.ps1') 'keeps the sanitized script path'
Assert-True (-not ($actionSummary -match 'should-not-appear')) 'drops task arguments after the script path'

$generatedPaths = @(Get-GitHubLocalIndexGeneratedDocumentPaths)
Assert-True ($generatedPaths -contains '00_总览\GitHub总览.md') 'consistency coverage includes GitHub overview'
Assert-True ($generatedPaths -contains '00_总览\当前同步看板.md') 'consistency coverage includes dashboard'
Assert-True ($generatedPaths -contains '02_同步诊断\未推送队列.md') 'consistency coverage includes queue'

$readOnlyRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('github-index-readonly-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $readOnlyRoot -Force | Out-Null
    $refreshPath = Join-Path $repoRoot 'tools/Refresh-GitHubLocalIndex.ps1'
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $refreshPath -RepoRoot $readOnlyRoot -CheckOnly 2>&1 | Out-Null
    Assert-True ($LASTEXITCODE -ne 0) 'CheckOnly fixture reports its intentionally missing generator scripts'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $readOnlyRoot -Force -Recurse).Count 'Refresh CheckOnly writes nothing inside the repository tree even on failure'
}
finally {
    if (Test-Path -LiteralPath $readOnlyRoot) { Remove-Item -LiteralPath $readOnlyRoot -Recurse -Force }
}

$consistencyReadOnlyRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('github-index-consistency-root-' + [guid]::NewGuid().ToString('N'))
$consistencyTempRoot = $null
try {
    New-Item -ItemType Directory -Path $consistencyReadOnlyRoot -Force | Out-Null
    $consistencyTempRoot = New-GitHubLocalIndexConsistencyTempRoot -RepoRoot $consistencyReadOnlyRoot
    $normalizedRepoRoot = [System.IO.Path]::GetFullPath($consistencyReadOnlyRoot).TrimEnd('\', '/')
    $normalizedGeneratedRoot = [System.IO.Path]::GetFullPath($consistencyTempRoot).TrimEnd('\', '/')
    Assert-True (-not $normalizedGeneratedRoot.StartsWith($normalizedRepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) 'consistency generation uses system temp outside the repository tree'
    New-Item -ItemType Directory -Path $consistencyTempRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $consistencyTempRoot 'fixture.txt') -Value 'fixture' -Encoding utf8
    Remove-GitHubLocalIndexConsistencyTempRoot -RepoRoot $consistencyReadOnlyRoot -TempRoot $consistencyTempRoot
    Assert-True (-not (Test-Path -LiteralPath $consistencyTempRoot)) 'consistency temp root is removed after the check'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $consistencyReadOnlyRoot -Force -Recurse).Count 'consistency check leaves no repository-tree temp directories'
}
finally {
    if ($consistencyTempRoot -and (Test-Path -LiteralPath $consistencyTempRoot)) { Remove-Item -LiteralPath $consistencyTempRoot -Recurse -Force }
    if (Test-Path -LiteralPath $consistencyReadOnlyRoot) { Remove-Item -LiteralPath $consistencyReadOnlyRoot -Recurse -Force }
}

$updateSource = Get-Content -LiteralPath (Join-Path $repoRoot 'tools/Update-GitHubIndex.ps1') -Raw -Encoding utf8
Assert-True ($updateSource -match 'GitHubIndex\.Core\.psm1') 'index generator imports the shared admission core'
Assert-True ($updateSource -match 'Get-ProjectAdmissionRecord') 'index generator consumes admission records'
Assert-True (-not ($updateSource -match 'PCConfig v0\.1|GitHub-indexed 项目迁移|计划任务治理')) 'Git index dashboard does not embed machine-configuration milestones'
Assert-True ($updateSource -match 'UtcNow\.AddHours\(8\)') 'Git index document date uses China time'
Assert-True (-not ($updateSource -match 'C:\\Users\\10979|G:\\')) 'index generator derives default scan roots from Git-owned facts'
Assert-True (-not ($updateSource -match '&\s*git\s+-C\s+\$Path\s+fetch')) 'index generator has no legacy fetch path that discards exit status'

$refreshPath = Join-Path $repoRoot 'tools/Refresh-GitHubLocalIndex.ps1'
$refreshTokens = $null
$refreshErrors = $null
$refreshAst = [System.Management.Automation.Language.Parser]::ParseFile($refreshPath, [ref] $refreshTokens, [ref] $refreshErrors)
$refreshParameters = @($refreshAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
Assert-True ($refreshParameters -contains 'Json') 'fast refresh exposes JSON output'
Assert-True ((Get-Content -LiteralPath $refreshPath -Raw -Encoding utf8) -match 'Get-ProjectAdmissionRecord') 'fast refresh consumes one admission record'

$scheduledTaskSource = Get-Content -LiteralPath (Join-Path $repoRoot 'tools/Update-ScheduledTaskHealth.ps1') -Raw -Encoding utf8
Assert-True (-not ($scheduledTaskSource -match 'PurposeCatalogPath|E:\\PCConfig')) 'task health generator does not embed PCConfig registry paths'
Assert-True ($scheduledTaskSource -match 'UtcNow\.AddHours\(8\)') 'task health document date uses China time'

$automationSource = Get-Content -LiteralPath (Join-Path $repoRoot 'tools/Update-UserAutomationMap.ps1') -Raw -Encoding utf8
Assert-True (-not ($automationSource -match 'E:\\Projects\\(?:Backups|Tools|Decisions)|C:\\Users\\10979|32100')) 'automation map does not embed mutable project paths or ports'
Assert-True (-not ($automationSource -match 'rtx5090d-ollama-agent-bundle|steam-millennium-config-backup|OpenClawGateway|WeFlowBridge|TimeAudit')) 'automation map does not embed project-specific task policy'
Assert-True ($automationSource -match 'UtcNow\.AddHours\(8\)') 'automation document date uses China time'

$hookPath = Join-Path $repoRoot 'tools/Install-GitHook.ps1'
$hookTokens = $null
$hookErrors = $null
$hookAst = [System.Management.Automation.Language.Parser]::ParseFile($hookPath, [ref] $hookTokens, [ref] $hookErrors)
$hookParameters = @($hookAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
Assert-True ($hookParameters -contains 'RepoPath') 'hook installer accepts an explicit repository path'
$hookSource = Get-Content -LiteralPath $hookPath -Raw -Encoding utf8
Assert-True ($hookSource -match 'rev-parse.+--git-path.+hooks') 'hook installer resolves hooks through Git plumbing'
if ($hookParameters -contains 'RepoPath') {
    $hookRepo = Join-Path ([System.IO.Path]::GetTempPath()) ('github-index-hook-' + [guid]::NewGuid().ToString('N'))
    try {
        & git init --initial-branch=main $hookRepo | Out-Null
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $hookPath -RepoPath $hookRepo | Out-Null
        Assert-Equal 0 $LASTEXITCODE 'hook installer succeeds in a temporary repository'
        $installedHook = Join-Path $hookRepo '.git/hooks/pre-commit'
        $hookBytes = [System.IO.File]::ReadAllBytes($installedHook)
        Assert-True (-not ($hookBytes.Length -ge 3 -and $hookBytes[0] -eq 0xEF -and $hookBytes[1] -eq 0xBB -and $hookBytes[2] -eq 0xBF)) 'installed hook has no UTF-8 BOM'
        Assert-True (@($hookBytes | Where-Object { $_ -gt 127 }).Count -eq 0) 'installed hook is ASCII only'
        $installedText = [System.Text.Encoding]::ASCII.GetString($hookBytes)
        Assert-True (-not $installedText.Contains("`r")) 'installed hook uses LF line endings'
        Assert-True ($installedText.StartsWith('#!/bin/sh')) 'installed hook keeps a valid Git Bash shebang'
        Assert-True ($installedText -match 'name-only -z') 'installed hook requests NUL-delimited staged paths'
        Assert-True ($installedText -match 'read -r -d') 'installed hook reads staged paths with a NUL delimiter'
        $firstHookHash = (Get-FileHash -LiteralPath $installedHook -Algorithm SHA256).Hash
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $hookPath -RepoPath $hookRepo | Out-Null
        Assert-Equal $firstHookHash (Get-FileHash -LiteralPath $installedHook -Algorithm SHA256).Hash 'hook installation is byte deterministic'

        & git -C $hookRepo config user.name 'Hook Test'
        & git -C $hookRepo config user.email 'hook@example.invalid'
        & git -C $hookRepo config core.quotePath true
        $sensitiveHookDirectory = Join-Path $hookRepo '中文 空格\嵌套'
        New-Item -ItemType Directory -Path $sensitiveHookDirectory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $sensitiveHookDirectory '.env') -Value 'TEST_ONLY=1' -Encoding utf8
        & git -C $hookRepo add -- . 2>&1 | Out-Null
        $hookCommitOutput = @(& git -C $hookRepo commit -m 'must be blocked' 2>&1)
        Assert-True ($LASTEXITCODE -ne 0) 'hook blocks a staged nested .env path containing Chinese and spaces'
        Assert-True (($hookCommitOutput -join "`n") -match 'Blocked staged path') 'hook rejection is caused by the sensitive-path gate'
    }
    finally {
        if (Test-Path -LiteralPath $hookRepo) { Remove-Item -LiteralPath $hookRepo -Recurse -Force }
    }
}

$registerPath = Join-Path $repoRoot 'tools/Register-GitHubLocalIndexRefreshTask.ps1'
$registerTokens = $null
$registerErrors = $null
$registerAst = [System.Management.Automation.Language.Parser]::ParseFile($registerPath, [ref] $registerTokens, [ref] $registerErrors)
$registerParameters = @($registerAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
Assert-True ($registerParameters -contains 'Json') 'task registration dry-run exposes JSON output'
Assert-True ($registerParameters -contains 'Apply') 'task registration requires an explicit apply switch for live mutation'
$registerSource = Get-Content -LiteralPath $registerPath -Raw -Encoding utf8
Assert-True ($registerSource -match 'Get-GitHubLocalIndexTaskDefinition') 'task registration separates definition from live apply'
if ($registerParameters -contains 'Json' -and $registerParameters -contains 'Apply') {
    $definitionJson = @(& pwsh -NoProfile -ExecutionPolicy Bypass -File $registerPath -CheckOnly -Json 2>&1)
    Assert-Equal 0 $LASTEXITCODE 'task definition dry-run succeeds without registration'
    $definition = ($definitionJson -join "`n") | ConvertFrom-Json
    Assert-Equal 'GitHubLocalIndex Consistency Check' $definition.task_name 'dry-run targets the read-only consistency task'
    Assert-True ($definition.action.arguments -match 'Refresh-GitHubLocalIndex-Hidden\.vbs"\s+-CheckOnly$') 'dry-run action must invoke the hidden launcher with the explicit -CheckOnly token'
    Assert-True (-not ($definition.action.arguments -match 'Refresh-GitHubLocalIndex\.ps1|commit|push')) 'dry-run action cannot invoke write refresh, commit or push'
}

$hiddenLauncherSource = Get-Content -LiteralPath (Join-Path $repoRoot 'tools/Refresh-GitHubLocalIndex-Hidden.vbs') -Raw -Encoding utf8
Assert-True ($hiddenLauncherSource -match 'Test-GitHubLocalIndexConsistency\.ps1') 'hidden task launcher calls the read-only consistency script'
Assert-True (-not ($hiddenLauncherSource -match 'Refresh-GitHubLocalIndex\.ps1')) 'hidden task launcher cannot call the write refresh wrapper'
Assert-True (-not ($hiddenLauncherSource -match '(?i)powershell\.exe')) 'hidden task launcher never falls back to unsupported Windows PowerShell 5.1'
Assert-True ($hiddenLauncherSource -match 'If whereCode <> 0 Then\s*WScript\.Quit [1-9]') 'hidden task launcher exits nonzero when pwsh is unavailable'

$consistencySource = Get-Content -LiteralPath (Join-Path $repoRoot 'tools/Test-GitHubLocalIndexConsistency.ps1') -Raw -Encoding utf8
Assert-True (-not ($consistencySource -match 'C:\\Users\\10979|G:\\')) 'consistency checker does not embed machine scan roots'

$compareRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('github-index-consistency-' + [guid]::NewGuid().ToString('N'))
$currentRoot = Join-Path $compareRoot 'current'
$generatedRoot = Join-Path $compareRoot 'generated'
try {
    New-Item -ItemType Directory -Force -Path $currentRoot, $generatedRoot | Out-Null
    $relativePath = '01_仓库索引\GitHub仓库索引.md'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent (Join-Path $currentRoot $relativePath)), (Split-Path -Parent (Join-Path $generatedRoot $relativePath)) | Out-Null

    $placeholder = '| wlyaaaaa/github-local-index | PUBLIC | main | E:\GitHub总索引 | 本次刷新目标仓库；提交推送后复查 | 提交并推送本索引刷新结果 |'
    $clean = '| wlyaaaaa/github-local-index | PUBLIC | main | E:\GitHub总索引 | `main` 已同步，`0/0` | 正常维护 |'
    Set-Content -LiteralPath (Join-Path $currentRoot $relativePath) -Value $placeholder -Encoding utf8
    Set-Content -LiteralPath (Join-Path $generatedRoot $relativePath) -Value $clean -Encoding utf8
    $placeholderComparison = Compare-GitHubLocalIndexDocuments -RepoRoot $currentRoot -GeneratedRoot $generatedRoot -RelativePaths @($relativePath)
    Assert-True $placeholderComparison.Same 'normalizes only the known self-index placeholder pair'

    $realDirty = '| wlyaaaaa/github-local-index | PUBLIC | main | E:\GitHub总索引 | `main` 已同步，`0/0`，脏工作区 2 项 | 公开仓库先做暴露面审查 |'
    Set-Content -LiteralPath (Join-Path $currentRoot $relativePath) -Value $realDirty -Encoding utf8
    $dirtyComparison = Compare-GitHubLocalIndexDocuments -RepoRoot $currentRoot -GeneratedRoot $generatedRoot -RelativePaths @($relativePath)
    Assert-True (-not $dirtyComparison.Same) 'does not normalize away real self-index dirty drift'

    $selfDocumentRow = @(ConvertTo-DocumentRows -Owner 'wlyaaaaa' -Rows @([pscustomobject]@{
        NameWithOwner = 'wlyaaaaa/github-local-index'
        Visibility = 'PUBLIC'
        DefaultBranch = 'main'
        LocalPath = 'E:\GitHub总索引'
        LocalState = '`main` 已同步，`0/0`，脏工作区 2 项'
        NextAction = 'review public exposure'
        HasLocalClone = $true
        NeedsReview = $true
        Ahead = 0
        Behind = 0
        DirtyCount = 2
        QueueReason = '脏工作区 2 项'
        PushedAt = $null
        UpdatedAt = $null
        Url = 'https://github.com/wlyaaaaa/github-local-index'
    }))[0]
    Assert-Equal 2 $selfDocumentRow.DirtyCount 'document rows retain real self-index dirty count'
    Assert-True ($selfDocumentRow.LocalState -match '脏工作区 2 项') 'document rows retain real self-index dirty state'
}
finally {
    if (Test-Path -LiteralPath $compareRoot) {
        Remove-Item -LiteralPath $compareRoot -Recurse -Force
    }
}

if ($script:Failures -gt 0) {
    throw "$script:Failures test(s) failed"
}

Write-Host 'All unit tests passed.'
