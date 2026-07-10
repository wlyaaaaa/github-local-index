#requires -Version 7.0

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot 'tools/GitHubIndex.Core.psm1'
$cliPath = Join-Path $repoRoot 'tools/Get-ProjectAdmission.ps1'
$script:Failures = 0

function Assert-Equal {
    param([AllowNull()] [object] $Expected, [AllowNull()] [object] $Actual, [string] $Name)
    if ($Expected -ne $Actual) {
        Write-Host "FAIL: $Name"
        Write-Host "  expected: $Expected"
        Write-Host "  actual:   $Actual"
        $script:Failures++
    }
    else { Write-Host "PASS: $Name" }
}

function Assert-True {
    param([bool] $Condition, [string] $Name)
    if (-not $Condition) {
        Write-Host "FAIL: $Name"
        $script:Failures++
    }
    else { Write-Host "PASS: $Name" }
}

function Invoke-TestGit {
    param([string] $Path, [string[]] $Arguments)
    $output = @(& git -C $Path @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git -C $Path $($Arguments -join ' ') failed: $($output -join ' ')"
    }
    $output
}

Assert-True (Test-Path -LiteralPath $modulePath -PathType Leaf) 'admission core module exists'
Assert-True (Test-Path -LiteralPath $cliPath -PathType Leaf) 'admission CLI exists'
if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf) -or -not (Test-Path -LiteralPath $cliPath -PathType Leaf)) {
    throw "$script:Failures test(s) failed"
}

Import-Module $modulePath -Force
$admissionModule = Get-Module GitHubIndex.Core

$statusParser = Get-Command ConvertFrom-GitStatusPorcelainV1Z -ErrorAction SilentlyContinue
Assert-True ($null -ne $statusParser) 'admission core exposes a NUL-delimited status parser'
if ($statusParser) {
    $newlinePath = "中文 空格`n换行目录/嵌套/.env"
    $parsedStatus = @(ConvertFrom-GitStatusPorcelainV1Z -Text ("?? $newlinePath" + [char] 0))
    Assert-Equal 1 $parsedStatus.Count 'NUL status parser keeps one entry for a path containing a newline'
    Assert-Equal $newlinePath $parsedStatus[0].paths[0] 'NUL status parser preserves Chinese, spaces and newlines verbatim'
}

$dirtySummaryCommand = & $admissionModule { Get-Command Get-GitDirtySummary -ErrorAction SilentlyContinue }
Assert-True ($null -ne $dirtySummaryCommand) 'admission core exposes a private dirty summary classifier'
if ($dirtySummaryCommand) {
    $statusFixture = @(
        'A  staged.txt',
        ' M unstaged.txt',
        '?? untracked.txt',
        'UU conflicted.txt'
    ) -join [char] 0
    $statusFixture += [char] 0
    $dirtySummary = & $admissionModule {
        param($Text)
        Get-GitDirtySummary -Entries @(ConvertFrom-GitStatusPorcelainV1Z -Text $Text)
    } $statusFixture
    Assert-Equal 4 $dirtySummary.total 'dirty summary counts all status entries'
    Assert-Equal 1 $dirtySummary.staged 'dirty summary counts staged entries'
    Assert-Equal 1 $dirtySummary.unstaged 'dirty summary counts unstaged entries'
    Assert-Equal 1 $dirtySummary.untracked 'dirty summary counts untracked entries'
    Assert-Equal 1 $dirtySummary.conflicted 'dirty summary counts conflicts without double-counting columns'
}

$syncStateCommand = & $admissionModule { Get-Command Get-GitSyncState -ErrorAction SilentlyContinue }
Assert-True ($null -ne $syncStateCommand) 'admission core exposes a private sync state classifier'
if ($syncStateCommand) {
    $syncCases = @(
        @{ upstream = 'origin/main'; ahead = 0; behind = 0; error = $false; expected = 'in_sync' },
        @{ upstream = 'origin/main'; ahead = 1; behind = 0; error = $false; expected = 'ahead' },
        @{ upstream = 'origin/main'; ahead = 0; behind = 1; error = $false; expected = 'behind' },
        @{ upstream = 'origin/main'; ahead = 1; behind = 1; error = $false; expected = 'diverged' },
        @{ upstream = $null; ahead = $null; behind = $null; error = $false; expected = 'no_upstream' },
        @{ upstream = 'origin/main'; ahead = $null; behind = $null; error = $true; expected = 'unknown' }
    )
    foreach ($case in $syncCases) {
        $actual = & $admissionModule {
            param($Upstream, $Ahead, $Behind, $InspectionError)
            Get-GitSyncState -Upstream $Upstream -Ahead $Ahead -Behind $Behind -InspectionError $InspectionError
        } $case.upstream $case.ahead $case.behind $case.error
        Assert-Equal $case.expected $actual "sync state classifies $($case.expected)"
    }
}

$pushGuidanceCommand = & $admissionModule { Get-Command Get-ProjectPushGuidance -ErrorAction SilentlyContinue }
Assert-True ($null -ne $pushGuidanceCommand) 'admission core exposes a private push guidance classifier'
if ($pushGuidanceCommand) {
    $cleanSummary = [pscustomobject]@{ total = 0; staged = 0; unstaged = 0; untracked = 0; conflicted = 0 }
    $dirtySummaryFixture = [pscustomobject]@{ total = 1; staged = 0; unstaged = 0; untracked = 1; conflicted = 0 }
    $pushCases = @(
        @{ name = 'cached clean in-sync'; decision = 'warn'; reasons = @('cached_observation'); mode = 'cached'; worktrees = @([pscustomobject]@{ exists = $true; sync_state = 'in_sync'; dirty_summary = $cleanSummary }); expectedDecision = 'warn'; expectedStrategy = 'fetch_recheck' },
        @{ name = 'live clean ahead'; decision = 'proceed'; reasons = @(); mode = 'live'; worktrees = @([pscustomobject]@{ exists = $true; sync_state = 'ahead'; dirty_summary = $cleanSummary }); expectedDecision = 'proceed'; expectedStrategy = 'normal' },
        @{ name = 'live clean in-sync'; decision = 'proceed'; reasons = @(); mode = 'live'; worktrees = @([pscustomobject]@{ exists = $true; sync_state = 'in_sync'; dirty_summary = $cleanSummary }); expectedDecision = 'proceed'; expectedStrategy = 'none' },
        @{ name = 'dirty'; decision = 'warn'; reasons = @('dirty_worktree'); mode = 'live'; worktrees = @([pscustomobject]@{ exists = $true; sync_state = 'in_sync'; dirty_summary = $dirtySummaryFixture }); expectedDecision = 'warn'; expectedStrategy = 'clean_or_stage_explicitly' },
        @{ name = 'no upstream'; decision = 'warn'; reasons = @('no_upstream'); mode = 'live'; worktrees = @([pscustomobject]@{ exists = $true; sync_state = 'no_upstream'; dirty_summary = $cleanSummary }); expectedDecision = 'warn'; expectedStrategy = 'set_upstream' },
        @{ name = 'behind'; decision = 'warn'; reasons = @(); mode = 'live'; worktrees = @([pscustomobject]@{ exists = $true; sync_state = 'behind'; dirty_summary = $cleanSummary }); expectedDecision = 'block'; expectedStrategy = 'update_then_recheck' },
        @{ name = 'diverged'; decision = 'warn'; reasons = @(); mode = 'live'; worktrees = @([pscustomobject]@{ exists = $true; sync_state = 'diverged'; dirty_summary = $cleanSummary }); expectedDecision = 'block'; expectedStrategy = 'reconcile_then_recheck' },
        @{ name = 'public exposure'; decision = 'block'; reasons = @('public_exposure_conflict'); mode = 'live'; worktrees = @([pscustomobject]@{ exists = $true; sync_state = 'in_sync'; dirty_summary = $dirtySummaryFixture }); expectedDecision = 'block'; expectedStrategy = 'resolve_public_exposure' }
    )
    foreach ($case in $pushCases) {
        $guidance = & $admissionModule {
            param($AdmissionDecision, $Reasons, $RemoteMode, $Worktrees)
            Get-ProjectPushGuidance -AdmissionDecision $AdmissionDecision -Reasons $Reasons -RemoteMode $RemoteMode -Worktrees $Worktrees
        } $case.decision $case.reasons $case.mode $case.worktrees
        Assert-Equal $case.expectedDecision $guidance.decision "push decision classifies $($case.name)"
        Assert-Equal $case.expectedStrategy $guidance.strategy "push strategy classifies $($case.name)"
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('github-index-admission-' + [guid]::NewGuid().ToString('N'))
$remotePath = Join-Path $tempRoot 'remote.git'
$primaryPath = Join-Path $tempRoot 'primary'
$linkedPath = Join-Path $tempRoot 'linked'
$detachedPath = Join-Path $tempRoot 'detached'
$stalePath = Join-Path $tempRoot 'stale'
$publisherPath = Join-Path $tempRoot 'publisher'

try {
    New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
    & git init --bare --initial-branch=main $remotePath 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'failed to initialize test remote' }
    & git clone $remotePath $primaryPath 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'failed to clone test repository' }

    Invoke-TestGit -Path $primaryPath -Arguments @('config', 'user.name', 'Admission Test') | Out-Null
    Invoke-TestGit -Path $primaryPath -Arguments @('config', 'user.email', 'admission@example.invalid') | Out-Null
    Set-Content -LiteralPath (Join-Path $primaryPath 'README.md') -Value 'fixture' -Encoding utf8
    Invoke-TestGit -Path $primaryPath -Arguments @('add', 'README.md') | Out-Null
    Invoke-TestGit -Path $primaryPath -Arguments @('commit', '-m', 'fixture') | Out-Null
    Invoke-TestGit -Path $primaryPath -Arguments @('push', '-u', 'origin', 'main') | Out-Null

    Invoke-TestGit -Path $primaryPath -Arguments @('worktree', 'add', '-b', 'feature', $linkedPath) | Out-Null
    Invoke-TestGit -Path $primaryPath -Arguments @('worktree', 'add', '--detach', $detachedPath, 'HEAD') | Out-Null
    Invoke-TestGit -Path $primaryPath -Arguments @('worktree', 'add', '-b', 'stale-fixture', $stalePath) | Out-Null
    $resolvedStale = [System.IO.Path]::GetFullPath($stalePath)
    if (-not $resolvedStale.StartsWith([System.IO.Path]::GetFullPath($tempRoot), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'refusing to remove an unexpected worktree fixture path'
    }
    Remove-Item -LiteralPath $resolvedStale -Recurse -Force

    Set-Content -LiteralPath (Join-Path $primaryPath 'dirty.txt') -Value 'dirty fixture' -Encoding utf8
    $fileUrl = 'file:///' + (($remotePath -replace '\\', '/') -replace '^([A-Za-z]):', '$1:')
    Invoke-TestGit -Path $primaryPath -Arguments @('remote', 'set-url', 'origin', 'https://github.com/example/project.git') | Out-Null
    Invoke-TestGit -Path $primaryPath -Arguments @('config', "url.$fileUrl.insteadOf", 'https://github.com/example/project.git') | Out-Null

    & git clone $remotePath $publisherPath 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'failed to clone publisher fixture' }
    Invoke-TestGit -Path $publisherPath -Arguments @('config', 'user.name', 'Publisher Test') | Out-Null
    Invoke-TestGit -Path $publisherPath -Arguments @('config', 'user.email', 'publisher@example.invalid') | Out-Null
    Add-Content -LiteralPath (Join-Path $publisherPath 'README.md') -Value 'remote update' -Encoding utf8
    Invoke-TestGit -Path $publisherPath -Arguments @('add', 'README.md') | Out-Null
    Invoke-TestGit -Path $publisherPath -Arguments @('commit', '-m', 'remote update') | Out-Null
    Invoke-TestGit -Path $publisherPath -Arguments @('push', 'origin', 'main') | Out-Null

    $worktrees = @(Get-GitRepositoryWorktrees -Path $primaryPath)
    Assert-Equal 4 $worktrees.Count 'enumerates primary, linked, detached and prunable worktrees'
    Assert-True (@($worktrees | Where-Object detached).Count -eq 1) 'labels detached worktree'
    Assert-True (@($worktrees | Where-Object prunable).Count -eq 1) 'preserves prunable worktree metadata'
    Assert-True (@($worktrees | Where-Object { $_.exists -and -not $_.upstream }).Count -ge 2) 'labels reachable worktrees without upstream'
    Assert-True (@($worktrees | Where-Object { $_.dirty_count -gt 0 }).Count -eq 1) 'observes dirty primary worktree'
    Assert-True (@($worktrees | Where-Object { $null -ne $_.dirty_summary }).Count -eq $worktrees.Count) 'all worktrees expose dirty summaries'
    Assert-True (@($worktrees | Where-Object { $_.sync_state -in @('in_sync', 'ahead', 'behind', 'diverged', 'no_upstream', 'unknown') }).Count -eq $worktrees.Count) 'all worktrees expose recognized sync states'
    Assert-Equal 'in_sync' ($worktrees | Where-Object branch -eq 'main').sync_state 'real worktree fixture produces in_sync'
    Assert-True (@($worktrees | Where-Object { $_.exists -and $_.sync_state -eq 'no_upstream' }).Count -ge 2) 'real worktree fixture produces no_upstream'
    $sortedPaths = @($worktrees.path | Sort-Object)
    Assert-Equal ($sortedPaths -join '|') (@($worktrees.path) -join '|') 'sorts worktrees by normalized path'

    Set-Content -LiteralPath (Join-Path $linkedPath 'ahead.txt') -Value 'ahead fixture' -Encoding utf8
    Invoke-TestGit -Path $linkedPath -Arguments @('add', 'ahead.txt') | Out-Null
    Invoke-TestGit -Path $linkedPath -Arguments @('commit', '-m', 'ahead fixture') | Out-Null
    Invoke-TestGit -Path $linkedPath -Arguments @('branch', '--set-upstream-to=origin/main', 'feature') | Out-Null
    $aheadWorktrees = @(Get-GitRepositoryWorktrees -Path $primaryPath)
    Assert-Equal 'ahead' ($aheadWorktrees | Where-Object branch -eq 'feature').sync_state 'real worktree fixture produces ahead'
    Invoke-TestGit -Path $linkedPath -Arguments @('branch', '--unset-upstream', 'feature') | Out-Null

    $cached = Get-ProjectAdmissionRecord -Repo 'example/project' -RepoPath $primaryPath -Visibility 'PUBLIC' -DefaultBranch 'main'
    Assert-Equal 'github-local-index.project-admission.v1' $cached.schema 'uses versioned admission schema'
    Assert-Equal ([System.IO.Path]::GetFullPath($primaryPath).TrimEnd('\', '/')) $cached.local_root 'keeps the selected repository path as local root'
    Assert-Equal 'example/project' $cached.repo 'normalizes the repository slug in admission JSON'
    Assert-Equal 'https://github.com/example/project.git' $cached.remote_url 'keeps the real configured remote URL in cached admission JSON'
    $requiredAdmissionProperties = @(
        'schema', 'observed_utc', 'repo', 'remote_url', 'visibility', 'default_branch',
        'local_root', 'git_common_dir', 'remote_mode', 'decision', 'push_decision',
        'push_strategy', 'reasons', 'errors', 'worktrees'
    )
    foreach ($propertyName in $requiredAdmissionProperties) {
        Assert-True ($cached.PSObject.Properties.Name -contains $propertyName) "normal admission JSON contains $propertyName"
    }
    Invoke-TestGit -Path $primaryPath -Arguments @('remote', 'set-url', 'origin', 'https://TEST_ONLY_USERINFO@github.com/example/project.git') | Out-Null
    $credentialSafeRemote = Get-ProjectAdmissionRecord -Repo 'example/project' -RepoPath $primaryPath -Visibility 'PRIVATE' -DefaultBranch 'main'
    Assert-Equal 'https://github.com/example/project.git' $credentialSafeRemote.remote_url 'removes userinfo before exposing a configured remote URL'
    Invoke-TestGit -Path $primaryPath -Arguments @('remote', 'set-url', 'origin', 'https://github.com/example/project.git') | Out-Null
    $recordFactory = Get-Command New-ProjectAdmissionRecord -ErrorAction SilentlyContinue
    Assert-True ($null -ne $recordFactory) 'admission core exposes one stable record factory'
    if ($recordFactory) {
        $errorRecord = New-ProjectAdmissionRecord `
            -ObservedUtc '2026-07-10T00:00:00.0000000Z' `
            -Repo 'example/project' `
            -RemoteMode 'cached' `
            -Decision 'block' `
            -Reasons @('internal_error') `
            -Errors @([pscustomobject]@{ category = 'internal_error'; exit_code = 1 }) `
            -Worktrees @()
        Assert-Equal ($cached.PSObject.Properties.Name -join '|') ($errorRecord.PSObject.Properties.Name -join '|') 'normal and exceptional admission records keep the same JSON shape'
        Assert-Equal 'example/project' $errorRecord.repo 'exceptional admission JSON keeps the normalized repo slug'
    }
    $cliSource = Get-Content -LiteralPath $cliPath -Raw -Encoding utf8
    Assert-True ($cliSource -match 'New-ProjectAdmissionRecord') 'CLI exceptional JSON uses the shared stable record factory'
    Assert-Equal 'cached' $cached.remote_mode 'labels cached observation explicitly'
    Assert-Equal 'warn' $cached.decision 'warns for cached and local worktree issues'
    Assert-True ($cached.reasons -contains 'cached_observation') 'reports cached observation reason'
    Assert-True ($cached.reasons -contains 'dirty_worktree') 'reports dirty worktree reason'
    Assert-True ($cached.reasons -contains 'no_upstream') 'reports no-upstream reason'
    Assert-True ($cached.reasons -contains 'prunable_worktree') 'reports prunable worktree reason'
    Assert-Equal 'warn' $cached.push_decision 'cached dirty admission warns before direct push'
    Assert-Equal 'clean_or_stage_explicitly' $cached.push_strategy 'dirty worktree takes precedence over cached evidence'
    Assert-True ([datetimeoffset]::Parse($cached.observed_utc).Offset -eq [timespan]::Zero) 'timestamps observation in UTC'

    $fetchSuccess = {
        param($path)
        $fetchOutput = @(& git -C $path fetch --prune origin 2>&1)
        [pscustomobject]@{ exit_code = $LASTEXITCODE; stdout = ($fetchOutput -join "`n"); stderr = '' }
    }
    $fetchFailure = { param($path) [pscustomobject]@{ exit_code = 1; stdout = ''; stderr = 'network unavailable' } }
    $ghSuccess = { param($repo) [pscustomobject]@{ exit_code = 0; stdout = '{"nameWithOwner":"example/project","visibility":"PUBLIC","defaultBranchRef":{"name":"main"},"url":"https://github.com/example/project"}'; stderr = '' } }
    $ghFailure = { param($repo) [pscustomobject]@{ exit_code = 1; stdout = ''; stderr = 'not authenticated' } }

    $live = Get-ProjectAdmissionRecord -Repo 'example/project' -RepoPath $primaryPath -Visibility 'PUBLIC' -DefaultBranch 'main' -Fetch -FetchInvoker $fetchSuccess -GitHubInvoker $ghSuccess
    Assert-Equal 'live' $live.remote_mode 'labels successful fetch and metadata observation live'
    Assert-Equal 'https://github.com/example/project' $live.remote_url 'uses the real GitHub metadata URL in live admission JSON'
    Assert-Equal 'warn' $live.decision 'keeps local worktree warnings under live observation'
    Assert-True (-not ($live.reasons -contains 'cached_observation')) 'removes cached warning after live evidence succeeds'
    $livePrimary = $live.worktrees | Where-Object branch -eq 'main'
    Assert-Equal 1 $livePrimary.behind 'recomputes ahead/behind after a successful live fetch'
    Assert-Equal 'behind' $livePrimary.sync_state 'classifies a fetched behind worktree'
    Assert-Equal 'block' $live.push_decision 'behind worktree blocks direct push without blocking read-only admission'
    Assert-Equal 'update_then_recheck' $live.push_strategy 'behind worktree requires update and recheck'
    Invoke-TestGit -Path $linkedPath -Arguments @('branch', '--set-upstream-to=origin/main', 'feature') | Out-Null
    $divergedWorktrees = @(Get-GitRepositoryWorktrees -Path $primaryPath)
    Assert-Equal 'diverged' ($divergedWorktrees | Where-Object branch -eq 'feature').sync_state 'real worktree fixture produces diverged'
    Invoke-TestGit -Path $linkedPath -Arguments @('branch', '--unset-upstream', 'feature') | Out-Null

    $failedFetch = Get-ProjectAdmissionRecord -Repo 'example/project' -RepoPath $primaryPath -Visibility 'PUBLIC' -DefaultBranch 'main' -Fetch -FetchInvoker $fetchFailure -GitHubInvoker $ghSuccess
    Assert-Equal 'cached' $failedFetch.remote_mode 'falls back to cached when fetch fails'
    Assert-Equal 'block' $failedFetch.decision 'blocks when requested live fetch evidence is unavailable'
    Assert-True (@($failedFetch.errors | Where-Object category -eq 'fetch_failed').Count -eq 1) 'categorizes fetch failure'

    $failedMetadata = Get-ProjectAdmissionRecord -Repo 'example/project' -RepoPath $primaryPath -Visibility 'PUBLIC' -DefaultBranch 'main' -Fetch -FetchInvoker $fetchSuccess -GitHubInvoker $ghFailure
    Assert-Equal 'cached' $failedMetadata.remote_mode 'falls back to cached when GitHub metadata fails'
    Assert-Equal 'block' $failedMetadata.decision 'blocks when requested live metadata is unavailable'
    Assert-True (@($failedMetadata.errors | Where-Object category -eq 'github_metadata_failed').Count -eq 1) 'categorizes GitHub metadata failure'

    $mismatch = Get-ProjectAdmissionRecord -Repo 'example/other' -RepoPath $primaryPath -Visibility 'PUBLIC' -DefaultBranch 'main'
    Assert-Equal 'block' $mismatch.decision 'blocks a remote mismatch'
    Assert-True ($mismatch.reasons -contains 'remote_mismatch') 'reports remote mismatch reason'

    $sensitiveDirectory = Join-Path $primaryPath '中文 空格\嵌套'
    New-Item -ItemType Directory -Path $sensitiveDirectory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $sensitiveDirectory '.env') -Value 'TEST_ONLY=1' -Encoding utf8
    $publicConflict = Get-ProjectAdmissionRecord -Repo 'example/project' -RepoPath $primaryPath -Visibility 'PUBLIC' -DefaultBranch 'main'
    Assert-Equal 'block' $publicConflict.decision 'blocks nested sensitive paths containing Chinese and spaces'
    Assert-True ($publicConflict.reasons -contains 'public_exposure_conflict') 'reports public exposure conflict reason'
    Assert-Equal 'block' $publicConflict.push_decision 'public exposure conflict blocks push'
    Assert-Equal 'resolve_public_exposure' $publicConflict.push_strategy 'public exposure conflict has a dedicated remediation strategy'
    Remove-Item -LiteralPath (Split-Path -Parent $sensitiveDirectory) -Recurse -Force

    $indexPath = Invoke-TestGit -Path $primaryPath -Arguments @('rev-parse', '--git-path', 'index')
    if (-not [System.IO.Path]::IsPathRooted($indexPath)) { $indexPath = Join-Path $primaryPath $indexPath }
    $indexBytes = [System.IO.File]::ReadAllBytes($indexPath)
    try {
        [System.IO.File]::WriteAllBytes($indexPath, [byte[]] @(1, 2, 3, 4))
        $inspectionFailure = Get-ProjectAdmissionRecord -Repo 'example/project' -RepoPath $primaryPath -Visibility 'PRIVATE' -DefaultBranch 'main'
        Assert-Equal 'block' $inspectionFailure.decision 'fails closed when any reachable worktree inspection fails'
        Assert-True (@($inspectionFailure.errors | Where-Object category -eq 'worktree_inspection_failed').Count -eq 1) 'preserves worktree inspection failure in admission errors'
    }
    finally {
        [System.IO.File]::WriteAllBytes($indexPath, $indexBytes)
    }

    $jsonOutput = @(& pwsh -NoProfile -ExecutionPolicy Bypass -File $cliPath -Repo 'example/project' -RepoPath $primaryPath -Visibility 'PRIVATE' -DefaultBranch 'main' -Json 2>&1)
    Assert-Equal 0 $LASTEXITCODE 'CLI returns success for cached nonblocking admission'
    $cliRecord = ($jsonOutput -join "`n") | ConvertFrom-Json
    Assert-Equal 'github-local-index.project-admission.v1' $cliRecord.schema 'CLI emits parseable versioned JSON'
    Assert-Equal 'cached' $cliRecord.remote_mode 'CLI JSON exposes observation mode'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        $resolvedRoot = [System.IO.Path]::GetFullPath($tempRoot)
        $tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        if ($resolvedRoot.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($script:Failures -gt 0) {
    throw "$script:Failures test(s) failed"
}

Write-Host 'All project admission tests passed.'
