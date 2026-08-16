#requires -Version 7.0

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'tools/Update-GitHubIndex.ps1')
. (Join-Path $repoRoot 'tools/Update-ScheduledTaskHealth.ps1')
. (Join-Path $repoRoot 'tools/Update-UserAutomationMap.ps1')
. (Join-Path $repoRoot 'tools/Test-GitHubLocalIndexConsistency.ps1')
. (Join-Path $repoRoot 'tools/Refresh-GitHubLocalIndex.ps1')

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

& (Join-Path $PSScriptRoot 'Test-GitOwnerStatus.ps1')

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

$jsonStdout = Invoke-ExternalCommandWithRetry -Operation 'unit native stream separation' -MaxAttempts 1 -DelaySeconds 0 -Command {
    & pwsh -NoProfile -NonInteractive -Command @'
[Console]::Out.WriteLine('{"status":"ok"}')
[Console]::Error.WriteLine('Progress: enumerating repositories')
exit 0
'@
}
Assert-Equal '{"status":"ok"}' ($jsonStdout -join '') 'successful native command returns stdout without stderr progress'

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

$script:NativeFailureAttempts = 0
$nativeFailureMessage = ''
try {
    Invoke-ExternalCommandWithRetry -Operation 'unit native bounded failure' -MaxAttempts 2 -DelaySeconds 0 -Command {
        $script:NativeFailureAttempts++
        & pwsh -NoProfile -NonInteractive -Command @'
[Console]::Out.WriteLine('stdout diagnostic')
[Console]::Error.WriteLine('stderr-marker ' + ('x' * 2000))
exit 19
'@
    } | Out-Null
}
catch {
    $nativeFailureMessage = $_.Exception.Message
}
Assert-Equal 2 $script:NativeFailureAttempts 'native failure preserves retry attempts'
Assert-True ($nativeFailureMessage -match 'Last exit code: 19') 'native failure preserves the final exit code'
Assert-True ($nativeFailureMessage -match 'stderr-marker') 'native failure retains a stderr summary'
Assert-True ($nativeFailureMessage.Length -le 768) 'native failure stderr summary is bounded'

$script:FetchRetryAttempts = 0
$fetchRetryResult = Invoke-GitFetchWithRetry `
    -Path 'C:\fixture' `
    -MaxAttempts 2 `
    -DelaySeconds 0 `
    -Invoker {
        param($path)
        $script:FetchRetryAttempts++
        if ($script:FetchRetryAttempts -eq 1) {
            [pscustomobject]@{ exit_code = 128; stdout = ''; stderr = 'transient connection failure' }
        }
        else {
            [pscustomobject]@{ exit_code = 0; stdout = ''; stderr = '' }
        }
    }
Assert-Equal 2 $script:FetchRetryAttempts 'Git refs refresh retries one transient failure'
Assert-Equal 0 $fetchRetryResult.exit_code 'Git refs refresh returns the successful retry evidence'
$script:FetchFailureAttempts = 0
$fetchFailureResult = Invoke-GitFetchWithRetry `
    -Path 'C:\fixture' `
    -MaxAttempts 2 `
    -DelaySeconds 0 `
    -Invoker {
        param($path)
        $script:FetchFailureAttempts++
        [pscustomobject]@{ exit_code = 128; stdout = ''; stderr = 'persistent failure' }
    }
Assert-Equal 2 $script:FetchFailureAttempts 'Git refs refresh keeps retries bounded'
Assert-Equal 128 $fetchFailureResult.exit_code 'persistent Git refs failure remains explicit for fail-closed admission'

$testFixtureRoot = Join-Path $repoRoot '99_private/test-fixtures'
New-Item -ItemType Directory -Path $testFixtureRoot -Force | Out-Null
$resolveRetryRoot = Join-Path $testFixtureRoot (
    'github-index-resolve-retry-' + [guid]::NewGuid().ToString('N')
)
try {
    & git init --initial-branch=main $resolveRetryRoot *> $null
    if ($LASTEXITCODE -ne 0) { throw 'failed to initialize resolve retry fixture' }
    & git -C $resolveRetryRoot config user.name 'Resolve Retry Test'
    & git -C $resolveRetryRoot config user.email 'resolve-retry@example.invalid'
    Set-Content -LiteralPath (Join-Path $resolveRetryRoot 'fixture.txt') -Value 'fixture' -Encoding utf8
    & git -C $resolveRetryRoot add fixture.txt
    & git -C $resolveRetryRoot commit -m 'fixture' *> $null
    & git -C $resolveRetryRoot remote add origin https://github.com/example/retry.git
    $resolveRetryMap = @{
        'example/retry' = @(
            [pscustomobject]@{ Path = $resolveRetryRoot; CommonDir = (Join-Path $resolveRetryRoot '.git') }
        )
    }
    $resolveRetryRepo = [pscustomobject]@{
        nameWithOwner = 'example/retry'
        visibility = 'PRIVATE'
        url = 'https://github.com/example/retry'
        defaultBranchRef = [pscustomobject]@{ name = 'main' }
        pushedAt = '2026-07-26T00:00:00Z'
        updatedAt = '2026-07-26T00:00:00Z'
    }
    $script:ResolveRetryAttempts = 0
    Resolve-CloneStatuses `
        -CloneMap $resolveRetryMap `
        -Repositories @($resolveRetryRepo) `
        -FetchInvoker {
            param($path)
            $script:ResolveRetryAttempts++
            if ($script:ResolveRetryAttempts -eq 1) {
                [pscustomobject]@{ exit_code = 128; stdout = ''; stderr = 'transient failure' }
            }
            else {
                [pscustomobject]@{ exit_code = 0; stdout = ''; stderr = '' }
            }
        }
    $resolvedRetryClone = @($resolveRetryMap['example/retry'])[0]
    Assert-Equal 2 $script:ResolveRetryAttempts 'clone resolver performs the bounded fetch retry in its own scope'
    Assert-Equal 'live' $resolvedRetryClone.RemoteMode 'clone resolver hands successful fetch evidence across the module boundary'
    Assert-True (-not (@($resolvedRetryClone.QueueReasons) -contains 'fetch_failed')) `
        'successful retry does not leave a stale fetch_failed action'
}
finally {
    if (Test-Path -LiteralPath $resolveRetryRoot) {
        Remove-Item -LiteralPath $resolveRetryRoot -Recurse -Force
    }
}

$pinnedPreflightContainer = Join-Path $testFixtureRoot (
    'github-index-pinned-preflight-' + [guid]::NewGuid().ToString('N')
)
try {
    New-Item -ItemType Directory -Path $pinnedPreflightContainer | Out-Null
    $pinnedSeed = Join-Path $pinnedPreflightContainer 'seed'
    & git init --initial-branch=main $pinnedSeed *> $null
    & git -C $pinnedSeed config user.name 'Pinned Preflight Test'
    & git -C $pinnedSeed config user.email 'pinned-preflight@example.invalid'
    Set-Content -LiteralPath (Join-Path $pinnedSeed 'fixture.txt') -Value 'fixture' -Encoding utf8
    & git -C $pinnedSeed add fixture.txt
    & git -C $pinnedSeed commit -m 'fixture' *> $null
    $pinnedHead = (& git -C $pinnedSeed rev-parse HEAD).Trim()
    $pinnedPrefix = $pinnedHead.Substring(0, 7)
    $pinnedClonePath = Join-Path $pinnedPreflightContainer "demo-audit-$pinnedPrefix"
    Move-Item -LiteralPath $pinnedSeed -Destination $pinnedClonePath
    & git -C $pinnedClonePath remote add origin https://github.com/example/pinned.git
    & git -C $pinnedClonePath switch --detach $pinnedHead *> $null
    & git -C $pinnedClonePath branch -D main *> $null
    $pinnedPreflight = Get-CommitPinnedClonePreflight -Path $pinnedClonePath
    Assert-Equal $pinnedPrefix $pinnedPreflight.commit_prefix `
        'clean detached audit clone is recognized before refs refresh'
    $pinnedResolveMap = @{
        'example/pinned' = @(
            [pscustomobject]@{ Path = $pinnedClonePath; CommonDir = (Join-Path $pinnedClonePath '.git') }
        )
    }
    $pinnedResolveRepo = [pscustomobject]@{
        nameWithOwner = 'example/pinned'
        visibility = 'PRIVATE'
        url = 'https://github.com/example/pinned'
        defaultBranchRef = [pscustomobject]@{ name = 'main' }
        pushedAt = '2026-07-26T00:00:00Z'
        updatedAt = '2026-07-26T00:00:00Z'
    }
    $script:PinnedFetchAttempts = 0
    Resolve-CloneStatuses `
        -CloneMap $pinnedResolveMap `
        -Repositories @($pinnedResolveRepo) `
        -FetchInvoker {
            param($path)
            $script:PinnedFetchAttempts++
            [pscustomobject]@{ exit_code = 128; stdout = ''; stderr = 'must not run' }
        }
    $resolvedPinnedClone = @($pinnedResolveMap['example/pinned'])[0]
    Assert-Equal 0 $script:PinnedFetchAttempts 'commit-pinned clone skips automatic refs fetch'
    Assert-True $resolvedPinnedClone.IsPinnedSnapshot 'commit-pinned clone remains explicit in generated evidence'
    Assert-True (-not (@($resolvedPinnedClone.QueueReasons) -contains 'fetch_failed')) `
        'intentional pinned refs cache never becomes a fetch failure'
}
finally {
    if (Test-Path -LiteralPath $pinnedPreflightContainer) {
        Remove-Item -LiteralPath $pinnedPreflightContainer -Recurse -Force
    }
}

$script:IsolationAttempts = 0
$isolatedResult = Invoke-ExternalCommandWithRetry -Operation 'unit retry scope isolation' -MaxAttempts 2 -DelaySeconds 0 -Command {
    $script:IsolationAttempts++
    $attempt = 999
    $stdout = 'caller mutation'
    $stderr = 'caller mutation'
    $lastExitCode = 999
    if ($script:IsolationAttempts -eq 1) {
        & pwsh -NoProfile -NonInteractive -Command 'exit 17'
    }
    else {
        & pwsh -NoProfile -NonInteractive -Command '[Console]::Out.WriteLine("isolated"); exit 0'
    }
}
Assert-Equal 2 $script:IsolationAttempts 'caller locals cannot corrupt retry-loop state'
Assert-Equal 'isolated' ($isolatedResult -join '') 'isolated retry still returns final stdout'

$pinnedSnapshotClassifier = Get-Command Get-CommitPinnedSnapshotState -ErrorAction SilentlyContinue
Assert-True ($null -ne $pinnedSnapshotClassifier) 'commit-pinned snapshot classifier exists'
if ($pinnedSnapshotClassifier) {
    $pinnedSnapshot = Get-CommitPinnedSnapshotState `
        -Path 'V:\Personal\Worktrees\legal-filing-kit-1.0-audit-87dcfd1' `
        -Head '87dcfd16b13231b157b21911cf21689866fcffac' `
        -HasUpstream $true -Ahead 0 -Behind 2 -DirtyCount 0 -Exists $true -Prunable $false
    Assert-Equal '87dcfd1' $pinnedSnapshot.commit_prefix 'recognizes a clean audit path pinned to its HEAD prefix'
    Assert-Equal 2 $pinnedSnapshot.observed_behind 'retains non-actionable remote distance as evidence'
    Assert-True ($null -eq (Get-CommitPinnedSnapshotState `
        -Path 'V:\Personal\Worktrees\legal-filing-kit-1.0-audit-87dcfd1' `
        -Head '87dcfd16b13231b157b21911cf21689866fcffac' `
        -HasUpstream $true -Ahead 0 -Behind 2 -DirtyCount 1 -Exists $true -Prunable $false)) 'dirty audit worktree is never suppressed as pinned'
    Assert-True ($null -eq (Get-CommitPinnedSnapshotState `
        -Path 'V:\Personal\Worktrees\legal-filing-kit-1.0-audit-87dcfd1' `
        -Head '87dcfd16b13231b157b21911cf21689866fcffac' `
        -HasUpstream $true -Ahead 1 -Behind 0 -DirtyCount 0 -Exists $true -Prunable $false)) 'ahead audit worktree is never suppressed as pinned'
    Assert-True ($null -eq (Get-CommitPinnedSnapshotState `
        -Path 'V:\Personal\Worktrees\legal-filing-kit-1.0-audit-87dcfd1' `
        -Head '87dcfd16b13231b157b21911cf21689866fcffac' `
        -HasUpstream $true -Ahead $null -Behind 2 -DirtyCount 0 -Exists $true -Prunable $false)) 'missing upstream distance evidence is never coerced into pinned'
    Assert-True ($null -eq (Get-CommitPinnedSnapshotState `
        -Path 'V:\Personal\Worktrees\legal-filing-kit-active-87dcfd1' `
        -Head '87dcfd16b13231b157b21911cf21689866fcffac' `
        -HasUpstream $true -Ahead 0 -Behind 2 -DirtyCount 0 -Exists $true -Prunable $false)) 'commit suffix without an audit marker remains actionable'
    foreach ($falseMarker in @('reviewer', 'auditor', 'snapshotter', 'acceptance')) {
        Assert-True ($null -eq (Get-CommitPinnedSnapshotState `
            -Path "V:\Personal\Worktrees\demo-$falseMarker-87dcfd1" `
            -Head '87dcfd16b13231b157b21911cf21689866fcffac' `
            -HasUpstream $true -Ahead 0 -Behind 2 -DirtyCount 0 -Exists $true -Prunable $false)) "non-contract marker '$falseMarker' remains actionable"
    }
    $detachedPinnedSnapshot = Get-CommitPinnedSnapshotState `
        -Path 'V:\Personal\Worktrees\llm-backend-toolkit-cache-review-25d2794' `
        -Head '25d2794c11989d451164713e6f72544b1b0a0671' `
        -HasUpstream $false -Detached $true -Ahead 0 -Behind 0 -DirtyCount 0 -Exists $true -Prunable $false
    Assert-Equal '25d2794' $detachedPinnedSnapshot.commit_prefix 'recognizes a clean detached review path pinned to its HEAD prefix'
    Assert-True ($null -eq (Get-CommitPinnedSnapshotState `
        -Path 'V:\Personal\Worktrees\llm-backend-toolkit-cache-review-25d2794' `
        -Head '25d2794c11989d451164713e6f72544b1b0a0671' `
        -HasUpstream $false -Detached $false -Ahead 0 -Behind 0 -DirtyCount 0 -Exists $true -Prunable $false)) 'ordinary no-upstream branch remains actionable'
    Assert-True ($null -eq (Get-CommitPinnedSnapshotState `
        -Path 'V:\Personal\Worktrees\llm-backend-toolkit-cache-review-25d2794' `
        -Head '25d2794c11989d451164713e6f72544b1b0a0671' `
        -HasUpstream $false -Detached $true -Ahead $null -Behind $null -DirtyCount $null -Exists $true -Prunable $false)) 'detached snapshot requires a real clean observation'
    Assert-True ($null -eq (Get-CommitPinnedSnapshotState `
        -Path 'V:\Personal\Worktrees\llm-backend-toolkit-cache-review-25d2794' `
        -Head '25d2794c11989d451164713e6f72544b1b0a0671' `
        -HasUpstream $false -Detached $true -Ahead 1 -Behind 0 -DirtyCount 0 -Exists $true -Prunable $false)) 'detached snapshot with contradictory ahead evidence remains actionable'
    Assert-True ($null -eq (Get-CommitPinnedSnapshotState `
        -Path 'V:\Personal\Worktrees\llm-backend-toolkit-cache-review-25d2794' `
        -Head '25d2794c11989d451164713e6f72544b1b0a0671' `
        -HasUpstream $false -Detached $true -Ahead 0 -Behind 1 -DirtyCount 0 -Exists $true -Prunable $false)) 'detached snapshot with contradictory behind evidence remains actionable'
}

$necessaryRetentionClassifier = Get-Command Get-RegisteredNecessaryRetentionState -ErrorAction SilentlyContinue
Assert-True ($null -ne $necessaryRetentionClassifier) 'explicit necessary-retention classifier exists'
if ($necessaryRetentionClassifier) {
    $registeredRuntime = [pscustomobject]@{
        necessary_retention = $true
        exists = $true
        prunable = $false
        retention_owner = 'PCConfig'
        retention_purpose = 'live runtime rollback'
        retention_exit_condition = 'accepted replacement runtime'
    }
    $runtimeRetention = Get-RegisteredNecessaryRetentionState `
        -Worktree $registeredRuntime -InspectionFailed:$false -DirtyCount 0
    Assert-Equal 'PCConfig' $runtimeRetention.owner 'healthy exact retention is non-actionable'
    Assert-True ($null -eq (Get-RegisteredNecessaryRetentionState `
        -Worktree $registeredRuntime -InspectionFailed:$false -DirtyCount 1)) `
        'dirty registered retention becomes actionable again'
    Assert-True ($null -eq (Get-RegisteredNecessaryRetentionState `
        -Worktree $registeredRuntime -InspectionFailed:$true -DirtyCount 0)) `
        'uninspectable registered retention fails closed'
    $missingExitRuntime = $registeredRuntime.PSObject.Copy()
    $missingExitRuntime.retention_exit_condition = ''
    Assert-True ($null -eq (Get-RegisteredNecessaryRetentionState `
        -Worktree $missingExitRuntime -InspectionFailed:$false -DirtyCount 0)) `
        'retention without an exit condition is never suppressed'
}

$convergenceClassifier = Get-Command Get-BranchConvergenceDisposition -ErrorAction SilentlyContinue
Assert-True ($null -ne $convergenceClassifier) 'default-branch convergence classifier exists'
if ($convergenceClassifier) {
    $unintegrated = Get-BranchConvergenceDisposition `
        -IntegrationState 'unmerged' -IsDefaultBranch:$false -DirtyCount 0 -HasWorktree:$true
    Assert-True $unintegrated.needs_review 'clean feature with commits missing from default requires review'
    Assert-Equal 'unintegrated_worktree_commit' $unintegrated.queue_reason 'classifies worktree-only commits'
    Assert-True (-not $unintegrated.retirement_candidate) 'unintegrated feature is never a retirement candidate'

    $mergedWorktree = Get-BranchConvergenceDisposition `
        -IntegrationState 'merged_ancestry' -IsDefaultBranch:$false -DirtyCount 0 -HasWorktree:$true
    Assert-True $mergedWorktree.retirement_candidate 'clean merged worktree becomes a retirement candidate'
    Assert-Equal 'merged_residual_worktree' $mergedWorktree.queue_reason 'classifies merged residual worktree'

    $mergedBranch = Get-BranchConvergenceDisposition `
        -IntegrationState 'patch_equivalent' -IsDefaultBranch:$false -DirtyCount 0 -HasWorktree:$false
    Assert-True $mergedBranch.retirement_candidate 'patch-equivalent branch without worktree becomes a retirement candidate'
    Assert-Equal 'merged_residual_branch' $mergedBranch.queue_reason 'classifies merged residual branch'

    $dirtyMerged = Get-BranchConvergenceDisposition `
        -IntegrationState 'merged_ancestry' -IsDefaultBranch:$false -DirtyCount 1 -HasWorktree:$true
    Assert-True (-not $dirtyMerged.retirement_candidate) 'dirty merged worktree is never auto-cleanable'
    Assert-Equal 'active_dirty_worktree' $dirtyMerged.queue_reason 'dirty worktree remains an active-work queue item'

    $pinnedMerged = Get-BranchConvergenceDisposition `
        -IntegrationState 'merged_ancestry' -IsDefaultBranch:$false -DirtyCount 0 -HasWorktree:$true -PinnedSnapshot
    Assert-True (-not $pinnedMerged.needs_review) 'pinned snapshot takes precedence over convergence cleanup'
    Assert-True (-not $pinnedMerged.retirement_candidate) 'pinned snapshot is never a retirement candidate'

    $unknownConvergence = Get-BranchConvergenceDisposition `
        -IntegrationState 'unknown' -IsDefaultBranch:$false -DirtyCount 0 -HasWorktree:$true
    Assert-True $unknownConvergence.needs_review 'unknown integration state fails closed'
    Assert-Equal 'default_branch_integration_unknown' $unknownConvergence.queue_reason 'unknown state has a stable queue reason'
    Assert-True ($unknownConvergence.next_action -match '继续追溯.*BLOCK') 'unknown state cannot become a permanent keep-for-later outcome'
}

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
Assert-True (Test-IsExternallyGovernedGitHubRepository -Repo 'wlyaaaaa/PersonalOS') 'PersonalOS remote is marked as externally governed'
Assert-True (Test-IsExternallyGovernedLocalPath -Path 'X:\fixtures\PersonalOS-worktrees\fixture') 'PersonalOS worktree paths are excluded before local discovery'
Assert-True (-not (Test-IsExternallyGovernedLocalPath -Path 'V:\Personal\Projects\ordinary-project')) 'ordinary project paths remain discoverable'
if ($seedDiscovery) {
    # Repository discovery deliberately excludes system-temp clones. Keep this
    # fixture beside (not inside) the checkout so it exercises a durable future
    # project root without being mistaken for either transient data or a nested
    # repository inside the index worktree.
    $seedRoot = Join-Path (Split-Path -Parent $repoRoot) ('github-index-seed-' + [guid]::NewGuid().ToString('N'))
    $primarySeed = Join-Path $seedRoot 'primary'
    $linkedSeed = Join-Path $seedRoot 'linked-only-scan-root'
    $futureProjectsRoot = Join-Path $seedRoot 'future-projects'
    $futureRepo = Join-Path $futureProjectsRoot 'new-repository'
    $externalFutureRepo = Join-Path $futureProjectsRoot 'PersonalOS-future'
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

        & git init --initial-branch=main $futureRepo 2>&1 | Out-Null
        & git init --initial-branch=main $externalFutureRepo 2>&1 | Out-Null
        $futureSeeds = @(Get-GitRepositorySeedPaths -Roots @($futureProjectsRoot))
        Assert-True ($futureSeeds -contains [System.IO.Path]::GetFullPath($futureRepo)) 'central discovery finds a future repository without per-repo injection'
        Assert-True (-not ($futureSeeds -contains [System.IO.Path]::GetFullPath($externalFutureRepo))) 'central discovery excludes future externally governed PersonalOS paths before Git inspection'
    }
    finally {
        if (Test-Path -LiteralPath $seedRoot) { Remove-Item -LiteralPath $seedRoot -Recurse -Force }
    }
}

$inspectionRoot = Join-Path $testFixtureRoot ('github-index-inspection-' + [guid]::NewGuid().ToString('N'))
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
        },
        [pscustomobject]@{
            Path = 'V:\Personal\Worktrees\personal-os-artifact'
            Branch = 'codex/personalos-beacon-receipt'
            Upstream = '[external-owner]'
            Ahead = 0
            Behind = 0
            DirtyCount = 0
            State = 'PersonalOS owner artifact'
            NextAction = 'external owner'
            IsDirty = $false
            NeedsReview = $false
            ExternalGovernance = $true
            QueueReasons = @()
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
Assert-True (-not $demoRow.LocalPath.Contains('personal-os-artifact')) 'shared repositories never publish externally governed worktree paths'
Assert-True ($demoRow.LocalState.Contains('PersonalOS owner artifact')) 'shared repositories retain owner classification without publishing the worktree path'
Assert-Equal '未发现本地 clone' $keyRow.LocalPath 'marks Key as missing local clone'
Assert-True ($keyRow.NextAction -match '受管私有路径') 'keeps Key managed-clone rule'
Assert-True ($keyRow.NextAction -match '密文') 'limits Key checkout to encrypted artifacts'

$cachedEvidenceRows = @(ConvertTo-GitHubIndexRows -Repositories @([pscustomobject]@{
    nameWithOwner = 'wlyaaaaa/cached-evidence'
    visibility = 'PRIVATE'
    url = 'https://github.com/wlyaaaaa/cached-evidence'
    defaultBranchRef = [pscustomobject]@{ name = 'main' }
}) -CloneMap @{
    'wlyaaaaa/cached-evidence' = @([pscustomobject]@{
        Path = 'E:\cached-evidence'
        State = 'main (cached)'
        NextAction = '需人工复查'
        NeedsReview = $false
        RemoteMode = 'cached'
        Ahead = 0
        Behind = 0
        DirtyCount = 0
        Upstream = 'origin/main'
    })
})
Assert-True $cachedEvidenceRows[0].NeedsReview 'cached remote evidence is aggregated into repository NeedsReview'
Assert-True ($cachedEvidenceRows[0].QueueReason -match 'cached 远端引用') 'cached remote evidence remains visible in the repository queue reason'

$pinnedRows = @(ConvertTo-GitHubIndexRows -Repositories @([pscustomobject]@{
    nameWithOwner = 'wlyaaaaa/pinned-demo'
    visibility = 'PRIVATE'
    url = 'https://github.com/wlyaaaaa/pinned-demo'
    defaultBranchRef = [pscustomobject]@{ name = 'main' }
    pushedAt = '2026-07-01T00:00:00Z'
    updatedAt = '2026-07-01T00:00:00Z'
}) -CloneMap @{
    'wlyaaaaa/pinned-demo' = @(
        [pscustomobject]@{
            Path = 'V:\Personal\Worktrees\pinned-demo-audit-87dcfd1'
            Branch = 'audit'
            Upstream = 'origin/audit'
            Ahead = 0
            Behind = 0
            DirtyCount = 0
            State = 'pinned'
            NextAction = 'preserve'
            IsDirty = $false
            IsPinnedSnapshot = $true
            PinnedObservedBehind = 2
            NeedsReview = $false
            QueueReasons = @()
        },
        [pscustomobject]@{
            Path = 'V:\Personal\Worktrees\pinned-demo-review-25d2794'
            Branch = ''
            Upstream = ''
            Ahead = 0
            Behind = 0
            DirtyCount = 0
            State = 'pinned detached'
            NextAction = 'preserve'
            IsDirty = $false
            IsPinnedSnapshot = $true
            PinnedObservedBehind = $null
            NeedsReview = $false
            QueueReasons = @()
        }
    )
})
Assert-Equal 2 $pinnedRows[0].PinnedSnapshotCount 'row aggregation preserves pinned snapshot count'
Assert-Equal 2 $pinnedRows[0].PinnedObservedBehind 'row aggregation preserves non-actionable observed behind'
Assert-Equal 0 $pinnedRows[0].Behind 'pinned observed behind never becomes actionable behind'
Assert-True (-not $pinnedRows[0].NeedsReview) 'clean pinned snapshots do not create a review queue'
Assert-Equal '' $pinnedRows[0].QueueReason 'pinned detached snapshot does not create no-upstream noise'

$externalRows = @(ConvertTo-GitHubIndexRows -Repositories @([pscustomobject]@{
    nameWithOwner = 'wlyaaaaa/PersonalOS'
    visibility = 'PRIVATE'
    url = 'https://github.com/wlyaaaaa/PersonalOS'
    defaultBranchRef = [pscustomobject]@{ name = 'main' }
    pushedAt = '2026-07-01T00:00:00Z'
    updatedAt = '2026-07-01T00:00:00Z'
}) -CloneMap @{
    'wlyaaaaa/PersonalOS' = @([pscustomobject]@{ Path = 'SHOULD_NOT_BE_EXPOSED' })
})
Assert-Equal '外部治理（不读取本地路径）' $externalRows[0].LocalPath 'external governance never publishes or acts on a PersonalOS local path'
Assert-Equal '不行动；由外部治理 owner 维护' $externalRows[0].NextAction 'external governance remote fact has an explicit no-action decision'
$externalRecommendation = Get-RepositoryTaskRecommendation `
    -NameWithOwner 'wlyaaaaa/PersonalOS' `
    -LocalPath '外部治理（不读取本地路径）' `
    -Visibility 'PRIVATE' `
    -ExistingTaskHints @('SHOULD_NOT_BE_USED')
Assert-Equal '外部治理' $externalRecommendation.Decision 'automation recommendation preserves the external-governance no-action boundary'
Assert-Equal '无' $externalRecommendation.Frequency 'external governance never creates a task cadence'

$documentRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('github-index-docs-' + [guid]::NewGuid().ToString('N'))
try {
    Write-GitHubIndexDocuments -RepoRoot $documentRoot -Owner 'wlyaaaaa' -Rows $rows
    $overviewPath = Join-Path $documentRoot '00_总览/GitHub总览.md'
    $overviewText = Get-Content -LiteralPath $overviewPath -Raw -Encoding utf8
    Assert-True ($overviewText -match '\| 2 \| 1 \| 1 \| 1 \|') 'overview counts come from the same repository row set'
    $dashboardPath = Join-Path $documentRoot '00_总览/当前同步看板.md'
    $dashboardText = Get-Content -LiteralPath $dashboardPath -Raw -Encoding utf8
    Assert-True ($dashboardText.Contains('不确定性会影响决策时，按需用')) 'generated dashboard makes admission conditional on decision-relevant uncertainty'
    Assert-True (-not $dashboardText.Contains('1. 用 `tools\Get-ProjectAdmission.ps1 -Repo <owner/name> -Json` 获取单仓库 admission 结论。')) 'generated dashboard excludes the unconditional admission-first instruction'
    $firstOverviewHash = (Get-FileHash -LiteralPath $overviewPath -Algorithm SHA256).Hash
    Write-GitHubIndexDocuments -RepoRoot $documentRoot -Owner 'wlyaaaaa' -Rows $rows
    Assert-Equal $firstOverviewHash (Get-FileHash -LiteralPath $overviewPath -Algorithm SHA256).Hash 'Git document generation is deterministic for a stable row set'
    Write-GitHubIndexDocuments -RepoRoot $documentRoot -Owner 'wlyaaaaa' -Rows $pinnedRows
    $pinnedBranchText = Get-Content -LiteralPath (Join-Path $documentRoot '02_同步诊断/分支与远端诊断.md') -Raw -Encoding utf8
    Assert-True ($pinnedBranchText.Contains('## 无行动项')) 'pinned-only repository is grouped as no-action, not synchronized'
    Assert-True (-not $pinnedBranchText.Contains('## 已同步')) 'pinned-only repository is never labeled synchronized by its section'
    Assert-True ($pinnedBranchText.Contains('wlyaaaaa/pinned-demo') -and $pinnedBranchText.Contains('pinned detached')) 'pinned-only grouping retains explicit snapshot state'
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
Assert-True ($actionSummary -match 'backup\.ps1') 'keeps only the script leaf name in public task summary'
Assert-True (-not ($actionSummary -match '[A-Z]:\\')) 'public task summary omits drive-qualified action paths'
Assert-True (-not ($actionSummary -match 'should-not-appear')) 'drops task arguments after the script path'
$internalPathHint = Get-RelatedPathHint -TaskName $userTask.TaskName -ActionSummary ((Get-TaskActionTexts -Task $userTask) -join ' ')
Assert-Equal 'E:\Projects\Tools\demo' $internalPathHint 'keeps full paths only in memory for repository coverage matching'
Assert-Equal '有运行记录' (Get-PublicLastRunLabel -LastRunTime ([datetime]'2026-07-09T12:00:00')) 'public task map redacts exact last-run timestamps'
Assert-Equal '已计划' (Get-PublicNextRunLabel -State 'Ready' -NextRunTime ([datetime]'2026-07-09T23:10:00')) 'public task map redacts exact next-run timestamps'

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
Assert-True (-not ($updateSource -match "Join-Path\s+\`$ownerVolumeRoot\s+'PersonalOS")) 'default discovery does not seed PersonalOS local roots'
Assert-True ($updateSource -match 'Test-IsExternallyGovernedLocalPath') 'future repository discovery applies the central external-governance path exclusion'
Assert-True ($updateSource -match 'external_governance') 'index generator consumes explicit artifact-owner evidence'
Assert-True ($updateSource -match 'necessary_retention') 'index generator consumes explicit necessary-retention evidence'
Assert-True ($updateSource -match '不纳入 Codex 收敛判断') 'externally governed artifacts do not become Codex cleanup recommendations'
$artifactGovernancePath = Join-Path $repoRoot 'config/git-artifact-governance.json'
Assert-True (Test-Path -LiteralPath $artifactGovernancePath -PathType Leaf) 'explicit Git artifact-owner registry exists'
$artifactGovernance = Get-Content -LiteralPath $artifactGovernancePath -Raw -Encoding utf8 | ConvertFrom-Json
Assert-Equal 'github-local-index.git-artifact-governance.v1' $artifactGovernance.schema 'artifact-owner registry has a stable schema'
Assert-True (@($artifactGovernance.entries | Where-Object {
    $_.repo -eq 'wlyaaaaa/.agents' -and $_.owner -eq 'PersonalOS'
}).Count -eq 1) 'artifact-owner registry protects explicit PersonalOS refs without suppressing the whole .agents repository'
Assert-True (@($artifactGovernance.entries | Where-Object {
    $_.repo -eq 'wlyaaaaa/PCConfig' -and
    $_.owner -eq 'PCConfig Secret Broker' -and
    @($_.refs) -contains 'secret-broker-backup'
}).Count -eq 1) 'artifact-owner registry classifies the contract-defined encrypted backup stream separately from feature convergence'
Assert-True (@($artifactGovernance.entries | Where-Object {
    $_.repo -eq 'wlyaaaaa/wlyaaaaa' -and
    $_.owner -eq 'GitHub Actions deployment artifact' -and
    @($_.refs) -contains 'output' -and
    $_.purpose -eq '由 .github/workflows/snake.yml 发布并被 README SVG 引用的 orphan 生成分支' -and
    $_.exit_condition -eq '同时移除 README 中的 output 引用并修改或停用该 workflow'
}).Count -eq 1) 'artifact-owner registry retains the workflow-backed output deployment branch with its exit condition'
$outputGovernance = Get-GitArtifactGovernance -Repo 'wlyaaaaa/wlyaaaaa' -Branch 'origin/output'
Assert-Equal 'GitHub Actions deployment artifact' $outputGovernance.owner 'output deployment branch resolves to its explicit external owner'
Assert-True (@($artifactGovernance.retentions | Where-Object {
    $_.repo -eq 'wlyaaaaa/codex-local-remote' -and
    $_.path -eq 'V:\Personal\Worktrees\codex-local-remote-v1-rollback' -and
    $_.head -eq '2a76e3638e4d22db63e07389810dc47c1d1b03c3' -and
    $_.owner -eq 'PCConfig' -and
    -not [string]::IsNullOrWhiteSpace([string] $_.exit_condition)
}).Count -eq 1) 'artifact registry pins the exact runtime rollback with owner and exit condition'

$refreshPath = Join-Path $repoRoot 'tools/Refresh-GitHubLocalIndex.ps1'
$refreshTokens = $null
$refreshErrors = $null
$refreshAst = [System.Management.Automation.Language.Parser]::ParseFile($refreshPath, [ref] $refreshTokens, [ref] $refreshErrors)
$refreshParameters = @($refreshAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
Assert-True ($refreshParameters -contains 'Json') 'fast refresh exposes JSON output'
Assert-True ((Get-Content -LiteralPath $refreshPath -Raw -Encoding utf8) -match 'Get-ProjectAdmissionRecord') 'fast refresh consumes one admission record'

$generationAtomicRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('github-index-generation-atomic-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $generationAtomicRoot -Force | Out-Null
    $generationPaths = @(Get-RefreshGeneratedDocumentPaths)
    $oldGenerationId = 'old-generation-fixture'
    $oldGenerationDirectory = Join-Path $generationAtomicRoot ("00_总览/generations/$oldGenerationId")
    $oldDocumentsDirectory = Join-Path $oldGenerationDirectory 'documents'
    $oldDocumentRecords = @()
    foreach ($relativePath in $generationPaths) {
        $oldPath = Join-Path $oldDocumentsDirectory $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $oldPath) -Force | Out-Null
        Set-Content -LiteralPath $oldPath -Value @("<!-- generation_id=$oldGenerationId -->", "old:$relativePath") -Encoding utf8
        $projectionPath = Join-Path $generationAtomicRoot $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $projectionPath) -Force | Out-Null
        Copy-Item -LiteralPath $oldPath -Destination $projectionPath -Force
        $oldDocumentRecords += [ordered]@{
            path = ('documents/' + $relativePath.Replace('\', '/'))
            projection_path = $relativePath.Replace('\', '/')
            sha256 = (Get-FileHash -LiteralPath $oldPath -Algorithm SHA256).Hash
            bytes = [System.IO.File]::ReadAllBytes($oldPath).Length
        }
    }
    $oldManifestPath = Join-Path $oldGenerationDirectory 'manifest.json'
    $oldGenerationManifest = [ordered]@{
        schema = 'github-local-index.generation.v1'
        generation_id = $oldGenerationId
        observed_at = '2026-08-16T00:00:00.0000000Z'
        immutable = $true
        integrity_authoritative_for_generation = $true
        decision_authority = $false
        as_of_observed_at = '2026-08-16T00:00:00.0000000Z'
        owner = 'E:\GitHub总索引'
        source = 'unit-test immutable generation fixture'
        documents = @($oldDocumentRecords)
    }
    Set-Content -LiteralPath $oldManifestPath -Value ($oldGenerationManifest | ConvertTo-Json -Depth 8) -Encoding utf8
    $oldPointer = [ordered]@{
        schema = 'github-local-index.current-generation.v1'
        generation_id = $oldGenerationId
        observed_at = '2026-08-16T00:00:00.0000000Z'
        authoritative = $false
        integrity_authoritative_for_generation = $true
        decision_authority = $false
        as_of_observed_at = '2026-08-16T00:00:00.0000000Z'
        owner = 'E:\GitHub总索引'
        generation_root = "00_总览/generations/$oldGenerationId"
        generation_manifest_sha256 = (Get-FileHash -LiteralPath $oldManifestPath -Algorithm SHA256).Hash
        projection_role = 'compatibility_only'
        documents = @($oldDocumentRecords)
        retention_policy = 'current+previous'
        previous_generation_id = $null
        publication = 'pointer_switch_after_immutable_generation_and_projection_readback'
    }
    New-Item -ItemType Directory -Path (Join-Path $generationAtomicRoot '00_总览') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $generationAtomicRoot '00_总览/current-generation.json') -Value ($oldPointer | ConvertTo-Json -Depth 8) -Encoding utf8
    $oldHashes = @{}
    foreach ($record in $oldDocumentRecords) {
        $oldHashes[[string] $record.path] = [string] $record.sha256
    }

    $newGenerationId = 'new-generation-fixture'
    $newStage = Join-Path $generationAtomicRoot 'temporary-generation'
    foreach ($relativePath in $generationPaths) {
        $newPath = Join-Path $newStage $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $newPath) -Force | Out-Null
        Set-Content -LiteralPath $newPath -Value @("<!-- generation_id=$newGenerationId -->", "new:$relativePath") -Encoding utf8
    }
    $injectedFailure = $false
    try {
        Publish-GitHubLocalIndexGeneration `
            -GenerationRoot $newStage `
            -RepoRoot $generationAtomicRoot `
            -GenerationId $newGenerationId `
            -ObservedAt '2026-08-16T00:01:00.0000000Z' `
            -FailAfterPublishCount 1 | Out-Null
    }
    catch {
        $injectedFailure = $true
    }
    Assert-True $injectedFailure 'generation failure injection stops before pointer switch'
    $oldStateAfterFailure = Get-GitHubLocalIndexCurrentGenerationState -RepoRoot $generationAtomicRoot
    Assert-True $oldStateAfterFailure.valid 'old pointer remains valid after partial projection failure'
    Assert-True (-not $oldStateAfterFailure.projection_valid) 'partial projection failure records stale compatibility state without invalidating old generation'
    Assert-Equal $oldGenerationId $oldStateAfterFailure.generation_id 'old pointer remains current after partial projection failure'
    foreach ($record in $oldDocumentRecords) {
        $oldPath = Join-Path $generationAtomicRoot ('00_总览/generations/' + $oldGenerationId + '/' + ([string] $record.path).Replace('/', '\'))
        Assert-Equal $oldHashes[[string] $record.path] (Get-FileHash -LiteralPath $oldPath -Algorithm SHA256).Hash `
            "old immutable document remains unchanged: $($record.path)"
    }

    # A failed projection may leave compatibility files mixed with a valid old
    # immutable generation. The next complete publish must repair them rather
    # than being blocked by the stale projections.
    $successGenerationId = 'successful-generation-fixture'
    $successStage = Join-Path $generationAtomicRoot 'successful-temporary-generation'
    foreach ($relativePath in $generationPaths) {
        $successPath = Join-Path $successStage $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $successPath) -Force | Out-Null
        Set-Content -LiteralPath $successPath -Value @("<!-- generation_id=$successGenerationId -->", "success:$relativePath") -Encoding utf8
    }
    $successfulPublication = Publish-GitHubLocalIndexGeneration `
        -GenerationRoot $successStage `
        -RepoRoot $generationAtomicRoot `
        -GenerationId $successGenerationId `
        -ObservedAt '2026-08-16T00:02:00.0000000Z'
    Assert-Equal 'published' $successfulPublication.publication_status 'complete publish repairs stale compatibility projections'
    $finalGenerationState = Get-GitHubLocalIndexCurrentGenerationState -RepoRoot $generationAtomicRoot
    Assert-True $finalGenerationState.valid 'published pointer and immutable generation pass readback validation'
    Assert-True $finalGenerationState.projection_valid 'published compatibility projections match immutable hashes'
    Assert-Equal $successGenerationId $finalGenerationState.generation_id 'successful publish switches pointer after readback'
    $finalPointer = Get-Content -LiteralPath (Join-Path $generationAtomicRoot '00_总览/current-generation.json') -Raw -Encoding utf8 | ConvertFrom-Json
    $finalManifestPath = Join-Path $generationAtomicRoot ('00_总览/generations/' + $successGenerationId + '/manifest.json')
    Assert-Equal (Get-FileHash -LiteralPath $finalManifestPath -Algorithm SHA256).Hash $finalPointer.generation_manifest_sha256 'pointer records the immutable manifest hash'
    $finalManifestText = Get-Content -LiteralPath $finalManifestPath -Raw -Encoding utf8
    $finalPointerPath = Join-Path $generationAtomicRoot '00_总览/current-generation.json'
    $finalPointerText = Get-Content -LiteralPath $finalPointerPath -Raw -Encoding utf8
    $maliciousManifest = $finalManifestText | ConvertFrom-Json
    $maliciousManifest.documents[0].projection_path = 'README.md'
    Set-Content -LiteralPath $finalManifestPath -Value ($maliciousManifest | ConvertTo-Json -Depth 8) -Encoding utf8
    $maliciousPointer = $finalPointerText | ConvertFrom-Json
    $maliciousPointer.generation_manifest_sha256 = (Get-FileHash -LiteralPath $finalManifestPath -Algorithm SHA256).Hash
    $maliciousPointer.documents[0].projection_path = 'README.md'
    Set-Content -LiteralPath $finalPointerPath -Value ($maliciousPointer | ConvertTo-Json -Depth 8) -Encoding utf8
    $maliciousProjectionState = Get-GitHubLocalIndexCurrentGenerationState -RepoRoot $generationAtomicRoot
    Assert-True (-not $maliciousProjectionState.valid) 'generation rejects a projection path outside the fixed document mapping'
    [System.IO.File]::WriteAllText($finalManifestPath, $finalManifestText, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($finalPointerPath, $finalPointerText, [System.Text.UTF8Encoding]::new($false))
    $extraGenerationFile = Join-Path $generationAtomicRoot ('00_总览/generations/' + $successGenerationId + '/unexpected.tmp')
    Set-Content -LiteralPath $extraGenerationFile -Value 'must be rejected' -Encoding utf8
    $extraFileState = Get-GitHubLocalIndexCurrentGenerationState -RepoRoot $generationAtomicRoot
    Assert-True (-not $extraFileState.valid) 'generation closure rejects an extra unlisted file'
    Remove-Item -LiteralPath $extraGenerationFile -Force
    $unknownFieldPointer = $finalPointer | Select-Object *
    Add-Member -InputObject $unknownFieldPointer -NotePropertyName unknown_field -NotePropertyValue 'reject-me'
    Set-Content -LiteralPath $finalPointerPath -Value ($unknownFieldPointer | ConvertTo-Json -Depth 8) -Encoding utf8
    $unknownFieldState = Get-GitHubLocalIndexCurrentGenerationState -RepoRoot $generationAtomicRoot
    Assert-True (-not $unknownFieldState.valid) 'current pointer rejects unknown schema fields'
    [System.IO.File]::WriteAllText($finalPointerPath, $finalPointerText, [System.Text.UTF8Encoding]::new($false))

    $caseVariantPointerText = $finalPointerText -replace '"generation_id"\s*:', '"Generation_Id":'
    [System.IO.File]::WriteAllText($finalPointerPath, $caseVariantPointerText, [System.Text.UTF8Encoding]::new($false))
    $caseVariantPointerState = Get-GitHubLocalIndexCurrentGenerationState -RepoRoot $generationAtomicRoot
    Assert-True (-not $caseVariantPointerState.valid) 'current pointer rejects case-variant schema fields'
    [System.IO.File]::WriteAllText($finalPointerPath, $finalPointerText, [System.Text.UTF8Encoding]::new($false))

    $unknownManifest = $finalManifestText | ConvertFrom-Json
    Add-Member -InputObject $unknownManifest -NotePropertyName unknown_field -NotePropertyValue 'reject-me'
    $unknownManifestText = $unknownManifest | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($finalManifestPath, $unknownManifestText, [System.Text.UTF8Encoding]::new($false))
    $manifestHashPointer = $finalPointerText | ConvertFrom-Json
    $manifestHashPointer.generation_manifest_sha256 = (Get-FileHash -LiteralPath $finalManifestPath -Algorithm SHA256).Hash
    [System.IO.File]::WriteAllText($finalPointerPath, ($manifestHashPointer | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
    $unknownManifestState = Get-GitHubLocalIndexCurrentGenerationState -RepoRoot $generationAtomicRoot
    Assert-True (-not $unknownManifestState.valid) 'generation manifest rejects unknown schema fields'
    [System.IO.File]::WriteAllText($finalManifestPath, $finalManifestText, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($finalPointerPath, $finalPointerText, [System.Text.UTF8Encoding]::new($false))

    $unknownDocumentManifest = $finalManifestText | ConvertFrom-Json
    Add-Member -InputObject $unknownDocumentManifest.documents[0] -NotePropertyName unknown_field -NotePropertyValue 'reject-me'
    [System.IO.File]::WriteAllText($finalManifestPath, ($unknownDocumentManifest | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
    $documentHashPointer = $finalPointerText | ConvertFrom-Json
    $documentHashPointer.generation_manifest_sha256 = (Get-FileHash -LiteralPath $finalManifestPath -Algorithm SHA256).Hash
    [System.IO.File]::WriteAllText($finalPointerPath, ($documentHashPointer | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
    $unknownDocumentState = Get-GitHubLocalIndexCurrentGenerationState -RepoRoot $generationAtomicRoot
    Assert-True (-not $unknownDocumentState.valid) 'generation document rejects unknown schema fields'
    [System.IO.File]::WriteAllText($finalManifestPath, $finalManifestText, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($finalPointerPath, $finalPointerText, [System.Text.UTF8Encoding]::new($false))

    $reparseFixtureRoot = Join-Path $generationAtomicRoot 'reparse-fixture'
    $outsideTarget = Join-Path $generationAtomicRoot 'reparse-outside'
    $junctionPath = Join-Path $reparseFixtureRoot 'projection-parent'
    $outsideSentinel = Join-Path $outsideTarget 'sentinel.md'
    $junctionCreated = $false
    try {
        New-Item -ItemType Directory -Path $reparseFixtureRoot, $outsideTarget -Force | Out-Null
        Set-Content -LiteralPath $outsideSentinel -Value 'outside-sentinel' -Encoding utf8
        try {
            New-Item -ItemType Junction -Path $junctionPath -Target $outsideTarget -ErrorAction Stop | Out-Null
            $junctionCreated = $true
        }
        catch {
            Write-Host 'SKIP: reparse-point publication test is unavailable on this host'
        }
        if ($junctionCreated) {
            $sourceFixture = Join-Path $reparseFixtureRoot 'source.md'
            Set-Content -LiteralPath $sourceFixture -Value 'source' -Encoding utf8
            $reparseBlocked = $false
            try {
                Publish-RefreshGenerationFile `
                    -SourcePath $sourceFixture `
                    -TargetPath (Join-Path $junctionPath 'sentinel.md') `
                    -ContainmentRoot $reparseFixtureRoot
            }
            catch {
                $reparseBlocked = $true
            }
            Assert-True $reparseBlocked 'reparse-point projection parent fails closed before write'
            Assert-Equal 'outside-sentinel' (Get-Content -LiteralPath $outsideSentinel -Raw -Encoding utf8).Trim() 'reparse-point rejection leaves outside sentinel untouched'
        }
    }
    finally {
        if ($junctionCreated -and (Test-Path -LiteralPath $junctionPath)) {
            Remove-Item -LiteralPath $junctionPath -Force
        }
        if (Test-Path -LiteralPath $reparseFixtureRoot) {
            Remove-Item -LiteralPath $reparseFixtureRoot -Recurse -Force
        }
        if (Test-Path -LiteralPath $outsideTarget) {
            Remove-Item -LiteralPath $outsideTarget -Recurse -Force
        }
    }
}
finally {
    if (Test-Path -LiteralPath $generationAtomicRoot) {
        Remove-Item -LiteralPath $generationAtomicRoot -Recurse -Force
    }
}

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
$publicExposurePolicyPath = Join-Path $repoRoot 'tools/PublicExposurePolicy.psd1'
Assert-True (Test-Path -LiteralPath $publicExposurePolicyPath -PathType Leaf) 'hook and ignore gate have one central path policy'
$publicExposurePolicy = Import-PowerShellDataFile -LiteralPath $publicExposurePolicyPath
$ignoreCases = @($publicExposurePolicy.Cases)
$ignoreLines = @(Get-Content -LiteralPath (Join-Path $repoRoot '.gitignore') -Encoding utf8)
foreach ($pattern in @($publicExposurePolicy.GitIgnorePatterns)) {
    Assert-True ($ignoreLines -ccontains [string] $pattern) ".gitignore contains canonical policy pattern $pattern"
}
foreach ($case in $ignoreCases) {
    & git -C $repoRoot check-ignore --no-index --quiet -- $case.Path
    $ignored = $LASTEXITCODE -eq 0
    Assert-Equal $case.Blocked $ignored ".gitignore classifies $($case.Path)"
}
if ($hookParameters -contains 'RepoPath') {
    $hookRepo = Join-Path ([System.IO.Path]::GetTempPath()) ('github-index-hook-' + [guid]::NewGuid().ToString('N'))
    try {
        & git init --initial-branch=main $hookRepo | Out-Null
        & git -C $hookRepo config user.name 'Hook Test'
        & git -C $hookRepo config user.email 'hook@example.invalid'
        & git -C $hookRepo config core.quotePath true
        $syntheticSecret = 'github_pat_' + ('A' * 24)
        New-Item -ItemType Directory -Path (Join-Path $hookRepo 'secrets') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $hookRepo '.env') -Value 'TEST_ONLY=1' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $hookRepo 'secrets/rename-fixture.txt') -Value 'rename fixture' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $hookRepo 'remove-secret.txt') -Value $syntheticSecret -Encoding utf8
        Set-Content -LiteralPath (Join-Path $hookRepo 'type-change-fixture.txt') -Value 'safe regular file' -Encoding utf8
        & git -C $hookRepo add -- '.env' 'secrets/rename-fixture.txt' 'remove-secret.txt' 'type-change-fixture.txt'
        & git -C $hookRepo commit -m 'hook remediation fixtures' | Out-Null

        & pwsh -NoProfile -ExecutionPolicy Bypass -File $hookPath -RepoPath $hookRepo | Out-Null
        Assert-Equal 0 $LASTEXITCODE 'hook installer succeeds in a temporary repository'
        $installedHook = Join-Path $hookRepo '.git/hooks/pre-commit'
        $hookBytes = [System.IO.File]::ReadAllBytes($installedHook)
        Assert-True (-not ($hookBytes.Length -ge 3 -and $hookBytes[0] -eq 0xEF -and $hookBytes[1] -eq 0xBB -and $hookBytes[2] -eq 0xBF)) 'installed hook has no UTF-8 BOM'
        Assert-True (@($hookBytes | Where-Object { $_ -gt 127 }).Count -eq 0) 'installed hook is ASCII only'
        $installedText = [System.Text.Encoding]::ASCII.GetString($hookBytes)
        Assert-True (-not $installedText.Contains("`r")) 'installed hook uses LF line endings'
        Assert-True ($installedText.StartsWith('#!/bin/sh')) 'installed hook keeps a valid Git Bash shebang'
        Assert-True ($installedText -match 'name-only[^\r\n]+-z') 'installed hook requests NUL-delimited staged paths'
        Assert-True ($installedText -match 'diff-filter=ACMRT') 'installed hook excludes pure deletions while retaining staged type changes'
        Assert-True ($installedText -match 'read -r -d') 'installed hook reads staged paths with a NUL delimiter'
        Assert-True ($installedText.Contains([string] $publicExposurePolicy.AlwaysBlockedPathRegex)) 'installed hook embeds the canonical always-blocked path expression'
        Assert-True ($installedText.Contains([string] $publicExposurePolicy.EnvPathRegex)) 'installed hook embeds the canonical env-family expression'
        Assert-True ($installedText.Contains([string] $publicExposurePolicy.AllowedTemplateRegex)) 'installed hook embeds the canonical template exception expression'
        $firstHookHash = (Get-FileHash -LiteralPath $installedHook -Algorithm SHA256).Hash
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $hookPath -RepoPath $hookRepo | Out-Null
        Assert-Equal $firstHookHash (Get-FileHash -LiteralPath $installedHook -Algorithm SHA256).Hash 'hook installation is byte deterministic'

        $sensitiveHookDirectory = Join-Path $hookRepo '中文 空格\嵌套'
        New-Item -ItemType Directory -Path $sensitiveHookDirectory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $sensitiveHookDirectory '.env') -Value 'TEST_ONLY=1' -Encoding utf8
        & git -C $hookRepo add -- . 2>&1 | Out-Null
        $hookCommitOutput = @(& git -C $hookRepo commit -m 'must be blocked' 2>&1)
        Assert-True ($LASTEXITCODE -ne 0) 'hook blocks a staged nested .env path containing Chinese and spaces'
        Assert-True (($hookCommitOutput -join "`n") -match 'Blocked staged path') 'hook rejection is caused by the sensitive-path gate'
        & git -C $hookRepo reset -- . 2>&1 | Out-Null
        Remove-Item -LiteralPath (Join-Path $hookRepo '中文 空格') -Recurse -Force

        foreach ($sensitiveEnvPath in @('.env.local', '.env.production', 'service.env', 'service.env.local')) {
            Set-Content -LiteralPath (Join-Path $hookRepo $sensitiveEnvPath) -Value 'TEST_ONLY=1' -Encoding utf8
            & git -C $hookRepo add -- $sensitiveEnvPath 2>&1 | Out-Null
            $envVariantOutput = @(& git -C $hookRepo commit -m "must block $sensitiveEnvPath" 2>&1)
            Assert-True ($LASTEXITCODE -ne 0) "hook blocks staged path $sensitiveEnvPath"
            Assert-True (($envVariantOutput -join "`n") -match 'Blocked staged path') "hook path policy rejects $sensitiveEnvPath"
            & git -C $hookRepo reset -- $sensitiveEnvPath 2>&1 | Out-Null
            Remove-Item -LiteralPath (Join-Path $hookRepo $sensitiveEnvPath) -Force
        }

        foreach ($templateEnvPath in @('.env.example', '.env.sample', '.env.template', '.env.dist', 'service.env.example')) {
            Set-Content -LiteralPath (Join-Path $hookRepo $templateEnvPath) -Value 'TEST_ONLY_PLACEHOLDER=replace-me' -Encoding utf8
            & git -C $hookRepo add -- $templateEnvPath 2>&1 | Out-Null
            $templateOutput = @(& git -C $hookRepo commit -m "allow template $templateEnvPath" 2>&1)
            Assert-Equal 0 $LASTEXITCODE "hook allows public-safe env template path $templateEnvPath"
        }

        Set-Content -LiteralPath (Join-Path $hookRepo '.env.example') -Value $syntheticSecret -Encoding utf8
        & git -C $hookRepo add -- '.env.example' 2>&1 | Out-Null
        $templateSecretOutput = @(& git -C $hookRepo commit -m 'must block secret in env template' 2>&1)
        Assert-True ($LASTEXITCODE -ne 0) 'template path exception does not bypass secret content scanning'
        Assert-True (($templateSecretOutput -join "`n") -match 'Blocked staged content') 'secret-bearing env template is rejected by the content gate'
        & git -C $hookRepo reset -- '.env.example' 2>&1 | Out-Null
        Set-Content -LiteralPath (Join-Path $hookRepo '.env.example') -Value 'TEST_ONLY_PLACEHOLDER=replace-me' -Encoding utf8

        Set-Content -LiteralPath (Join-Path $hookRepo 'added-secret.txt') -Value $syntheticSecret -Encoding utf8
        & git -C $hookRepo add -- 'added-secret.txt' 2>&1 | Out-Null
        $addedSecretOutput = @(& git -C $hookRepo commit -m 'must block added secret' 2>&1)
        Assert-True ($LASTEXITCODE -ne 0) 'hook still blocks a newly added secret-shaped value'
        Assert-True (($addedSecretOutput -join "`n") -match 'Blocked staged content') 'new secret rejection is caused by the content gate'
        & git -C $hookRepo reset -- 'added-secret.txt' 2>&1 | Out-Null
        Remove-Item -LiteralPath (Join-Path $hookRepo 'added-secret.txt') -Force

        Set-Content -LiteralPath (Join-Path $hookRepo 'plus-prefixed-secret.txt') -Value ('++ ' + $syntheticSecret) -Encoding utf8
        & git -C $hookRepo add -- 'plus-prefixed-secret.txt' 2>&1 | Out-Null
        $plusPrefixedSecretOutput = @(& git -C $hookRepo commit -m 'must block plus-prefixed secret' 2>&1)
        Assert-True ($LASTEXITCODE -ne 0) 'hook blocks a newly added secret-shaped value whose line begins with plus signs'
        Assert-True (($plusPrefixedSecretOutput -join "`n") -match 'Blocked staged content') 'plus-prefixed secret rejection is caused by the content gate'
        & git -C $hookRepo reset -- 'plus-prefixed-secret.txt' 2>&1 | Out-Null
        Remove-Item -LiteralPath (Join-Path $hookRepo 'plus-prefixed-secret.txt') -Force

        $encodedPrivateKeyHeader = 'LS0tLS1CRUdJTi' + 'BQUklWQVRFIEtFWS0tLS0t'
        Set-Content -LiteralPath (Join-Path $hookRepo 'encoded-material.txt') -Value ('payload=' + $encodedPrivateKeyHeader) -Encoding utf8
        & git -C $hookRepo add -- 'encoded-material.txt' 2>&1 | Out-Null
        $encodedPrivateKeyOutput = @(& git -C $hookRepo commit -m 'must block encoded private key' 2>&1)
        Assert-True ($LASTEXITCODE -ne 0) 'hook blocks a Base64-encoded PEM private-key header'
        Assert-True (($encodedPrivateKeyOutput -join "`n") -match 'Blocked staged content') 'encoded private-key rejection is caused by the content gate'
        & git -C $hookRepo reset -- 'encoded-material.txt' 2>&1 | Out-Null
        Remove-Item -LiteralPath (Join-Path $hookRepo 'encoded-material.txt') -Force

        $syntheticOpenAiKey = ('sk-' + 'proj-' + ('B' * 32))
        Set-Content -LiteralPath (Join-Path $hookRepo 'openai-key.txt') -Value $syntheticOpenAiKey -Encoding utf8
        & git -C $hookRepo add -- 'openai-key.txt' 2>&1 | Out-Null
        $openAiKeyOutput = @(& git -C $hookRepo commit -m 'must block OpenAI key' 2>&1)
        Assert-True ($LASTEXITCODE -ne 0) 'hook blocks a high-confidence OpenAI API key shape'
        Assert-True (($openAiKeyOutput -join "`n") -match 'Blocked staged content') 'OpenAI key rejection is caused by the content gate'
        & git -C $hookRepo reset -- 'openai-key.txt' 2>&1 | Out-Null
        Remove-Item -LiteralPath (Join-Path $hookRepo 'openai-key.txt') -Force

        $syntheticGoogleApiKey = ('AI' + 'za' + ('C' * 35))
        Set-Content -LiteralPath (Join-Path $hookRepo 'google-api-key.txt') -Value $syntheticGoogleApiKey -Encoding utf8
        & git -C $hookRepo add -- 'google-api-key.txt' 2>&1 | Out-Null
        $googleApiKeyOutput = @(& git -C $hookRepo commit -m 'must block Google API key' 2>&1)
        Assert-True ($LASTEXITCODE -ne 0) 'hook blocks a high-confidence Google API key shape'
        Assert-True (($googleApiKeyOutput -join "`n") -match 'Blocked staged content') 'Google API key rejection is caused by the content gate'
        & git -C $hookRepo reset -- 'google-api-key.txt' 2>&1 | Out-Null
        Remove-Item -LiteralPath (Join-Path $hookRepo 'google-api-key.txt') -Force

        Set-Content -LiteralPath (Join-Path $hookRepo 'safe-base64.txt') -Value 'U29tZSBwdWJsaWMgZG9jdW1lbnRhdGlvbiBmaXh0dXJlLg==' -Encoding utf8
        & git -C $hookRepo add -- 'safe-base64.txt' 2>&1 | Out-Null
        $safeBase64Output = @(& git -C $hookRepo commit -m 'allow ordinary Base64' 2>&1)
        Assert-Equal 0 $LASTEXITCODE 'hook does not block ordinary Base64 content'

        $typeChangeBlob = [string]($syntheticSecret | & git -C $hookRepo hash-object -w --stdin)
        Assert-Equal 0 $LASTEXITCODE 'creates a synthetic secret blob for the type-change fixture'
        $typeChangeBlob = $typeChangeBlob.Trim()
        & git -C $hookRepo update-index --cacheinfo "120000,$typeChangeBlob,type-change-fixture.txt" 2>&1 | Out-Null
        Assert-Equal 0 $LASTEXITCODE 'stages a regular-file to symlink type change through the index'
        $typeChangeStatus = @(& git -C $hookRepo diff --cached --name-status -- 'type-change-fixture.txt' 2>&1)
        Assert-True (($typeChangeStatus -join "`n") -match '^T\s+type-change-fixture\.txt$') 'type-change regression fixture has Git status T'
        $typeChangeSecretOutput = @(& git -C $hookRepo commit -m 'must block type-change secret' 2>&1)
        Assert-True ($LASTEXITCODE -ne 0) 'hook blocks secret-shaped content introduced by a staged type change'
        Assert-True (($typeChangeSecretOutput -join "`n") -match 'Blocked staged content') 'type-change secret rejection is caused by the content gate'
        & git -C $hookRepo reset -- 'type-change-fixture.txt' 2>&1 | Out-Null

        & git -C $hookRepo rm -- '.env' 2>&1 | Out-Null
        $deleteSensitiveOutput = @(& git -C $hookRepo commit -m 'allow sensitive path deletion' 2>&1)
        Assert-Equal 0 $LASTEXITCODE 'hook allows a pure deletion of a tracked sensitive path'

        Set-Content -LiteralPath (Join-Path $hookRepo 'remove-secret.txt') -Value 'safe replacement' -Encoding utf8
        & git -C $hookRepo add -- 'remove-secret.txt' 2>&1 | Out-Null
        $deleteSecretLineOutput = @(& git -C $hookRepo commit -m 'allow secret line deletion' 2>&1)
        Assert-Equal 0 $LASTEXITCODE 'hook allows deleting a secret-shaped line when no secret is added'

        & git -C $hookRepo mv -- 'secrets/rename-fixture.txt' 'safe-renamed-fixture.txt' 2>&1 | Out-Null
        $safeRenameOutput = @(& git -C $hookRepo commit -m 'allow safe destination rename' 2>&1)
        Assert-Equal 0 $LASTEXITCODE 'hook allows renaming a sensitive source path to a safe destination'

        Set-Content -LiteralPath (Join-Path $hookRepo 'rename-into-sensitive.txt') -Value 'rename destination fixture' -Encoding utf8
        & git -C $hookRepo add -- 'rename-into-sensitive.txt'
        & git -C $hookRepo commit -m 'rename destination fixture' | Out-Null
        & git -C $hookRepo mv -- 'rename-into-sensitive.txt' '.env.production'
        $sensitiveRenameOutput = @(& git -C $hookRepo commit -m 'must block sensitive rename destination' 2>&1)
        Assert-True ($LASTEXITCODE -ne 0) 'hook blocks renaming a safe path into .env.production'
        Assert-True (($sensitiveRenameOutput -join "`n") -match 'Blocked staged path') 'hook evaluates the rename destination with the central path policy'
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
Assert-True ($hiddenLauncherSource -match '-ReceiptPath') 'hidden task launcher requests an actionable structured receipt'
Assert-True ($hiddenLauncherSource -match '99_private\\runtime\\github-index-consistency-last\.json') 'hidden task receipt stays in the ignored private runtime area'

$consistencySource = Get-Content -LiteralPath (Join-Path $repoRoot 'tools/Test-GitHubLocalIndexConsistency.ps1') -Raw -Encoding utf8
$consistencyCommand = Get-Command Invoke-GitHubLocalIndexConsistencyCheck -ErrorAction SilentlyContinue
$receiptWriter = Get-Command Write-GitHubLocalIndexConsistencyReceipt -ErrorAction SilentlyContinue
Assert-True ($null -ne $receiptWriter) 'consistency checker exposes an atomic owner-local receipt writer'
Assert-True ($consistencySource -match '\[string\]\s*\$ReceiptPath') 'consistency CLI accepts an explicit private receipt path'
if ($receiptWriter) {
    $receiptRepoRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('github-index-receipt-' + [guid]::NewGuid().ToString('N'))
    $receiptPath = Join-Path $receiptRepoRoot '99_private\runtime\github-index-consistency-last.json'
    try {
        $receipt = [pscustomobject][ordered]@{
            schema = 'github-local-index.consistency-receipt.v1'
            task_key = 'github_local_index_consistency'
            observed_at = '2026-07-25T00:00:00.0000000Z'
            outcome = 'drift'
            exit_code = 1
            drift_files = @('fixture.md')
        }
        Write-GitHubLocalIndexConsistencyReceipt -RepoRoot $receiptRepoRoot -ReceiptPath $receiptPath -Receipt $receipt
        $receiptJson = Get-Content -LiteralPath $receiptPath -Raw -Encoding utf8 | ConvertFrom-Json
        Assert-Equal 'github_local_index_consistency' $receiptJson.task_key 'receipt exposes the stable PCConfig task key'
        Assert-Equal 'drift' $receiptJson.outcome 'receipt preserves the actionable task outcome'
        Assert-Equal 'fixture.md' @($receiptJson.drift_files)[0] 'receipt preserves drift file names'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath (Split-Path -Parent $receiptPath) -Filter '*.tmp' -Force).Count 'atomic receipt publication leaves no temp file'
    }
    finally {
        if (Test-Path -LiteralPath $receiptRepoRoot) { Remove-Item -LiteralPath $receiptRepoRoot -Recurse -Force }
    }
}
Assert-True (-not ($consistencySource -match 'C:\\Users\\10979|G:\\')) 'consistency checker does not embed machine scan roots'
Assert-True ($consistencySource.Contains(". (Join-Path `$RepoRoot 'tools\Update-GitHubIndex.ps1') -RepoRoot `$RepoRoot -Owner `$Owner -ScanRoots `$ScanRoots -SkipFetch:`$SkipFetch")) 'consistency checker preserves every caller-selected generator parameter when dot-sourcing the generator'

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
