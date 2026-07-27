#requires -Version 7.0

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot 'tools/GitHubIndex.Core.psm1'
$cliPath = Join-Path $repoRoot 'tools/Get-ProjectAdmission.ps1'
$publicExposurePolicyPath = Join-Path $repoRoot 'tools/PublicExposurePolicy.psd1'
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
Assert-True (Test-Path -LiteralPath $publicExposurePolicyPath -PathType Leaf) 'central public-exposure policy exists'
if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $cliPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $publicExposurePolicyPath -PathType Leaf)) {
    throw "$script:Failures test(s) failed"
}

Import-Module $modulePath -Force
$admissionModule = Get-Module GitHubIndex.Core

$publicExposurePolicy = Import-PowerShellDataFile -LiteralPath $publicExposurePolicyPath
$publicExposureCases = @($publicExposurePolicy.Cases)
$publicExposurePathCommand = & $admissionModule { Get-Command Test-PublicExposurePath -ErrorAction SilentlyContinue }
Assert-True ($null -ne $publicExposurePathCommand) 'admission core exposes the central public-exposure path classifier'
if ($publicExposurePathCommand) {
    foreach ($case in $publicExposureCases) {
        $actual = & $admissionModule {
            param($Path)
            Test-PublicExposurePath -Path $Path
        } $case.Path
        Assert-Equal $case.Blocked $actual "public-exposure policy classifies $($case.Path)"
    }
}

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

$integrationEvidenceCommand = Get-Command Get-GitDefaultBranchIntegrationEvidence -ErrorAction SilentlyContinue
$branchInventoryCommand = Get-Command Get-GitRepositoryBranchInventory -ErrorAction SilentlyContinue
$artifactGovernanceCommand = Get-Command Get-GitArtifactGovernance -ErrorAction SilentlyContinue
$artifactRetentionCommand = Get-Command Get-GitArtifactRetention -ErrorAction SilentlyContinue
$artifactRegistryReaderCommand = Get-Command Read-GitArtifactGovernanceRegistry -ErrorAction SilentlyContinue
Assert-True ($null -ne $integrationEvidenceCommand) 'admission core exposes default-branch integration evidence'
Assert-True ($null -ne $branchInventoryCommand) 'admission core exposes local branch inventory'
Assert-True ($null -ne $artifactGovernanceCommand) 'admission core exposes explicit artifact-owner governance'
Assert-True ($null -ne $artifactRetentionCommand) 'admission core exposes explicit necessary-retention evidence'
Assert-True ($null -ne $artifactRegistryReaderCommand) 'artifact registry exposes a fail-closed reader'
$registryTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    'github-index-registry-' + [guid]::NewGuid().ToString('N')
)
try {
    New-Item -ItemType Directory -Path $registryTestRoot | Out-Null
    $missingRegistryBlocked = $false
    try {
        Read-GitArtifactGovernanceRegistry -Path (Join-Path $registryTestRoot 'missing.json') | Out-Null
    }
    catch {
        $missingRegistryBlocked = $true
    }
    Assert-True $missingRegistryBlocked 'missing artifact registry fails closed'
    $wrongSchemaPath = Join-Path $registryTestRoot 'wrong-schema.json'
    Set-Content -LiteralPath $wrongSchemaPath -Value '{"schema":"wrong","entries":[],"retentions":[]}' -Encoding utf8
    $wrongSchemaBlocked = $false
    try {
        Read-GitArtifactGovernanceRegistry -Path $wrongSchemaPath | Out-Null
    }
    catch {
        $wrongSchemaBlocked = $true
    }
    Assert-True $wrongSchemaBlocked 'wrong artifact registry schema fails closed'
    $invalidEntryPath = Join-Path $registryTestRoot 'invalid-entry.json'
    Set-Content -LiteralPath $invalidEntryPath -Value @'
{"schema":"github-local-index.git-artifact-governance.v1","entries":[{"repo":"wlyaaaaa/.agents","owner":"","refs":["codex/example"]}],"retentions":[]}
'@ -Encoding utf8
    $invalidEntryBlocked = $false
    try {
        Read-GitArtifactGovernanceRegistry -Path $invalidEntryPath | Out-Null
    }
    catch {
        $invalidEntryBlocked = $true
    }
    Assert-True $invalidEntryBlocked 'invalid artifact owner entry fails closed'
    $duplicateRefPath = Join-Path $registryTestRoot 'duplicate-ref.json'
    Set-Content -LiteralPath $duplicateRefPath -Value @'
{"schema":"github-local-index.git-artifact-governance.v1","entries":[{"repo":"wlyaaaaa/.agents","owner":"PersonalOS","refs":["codex/example","origin/codex/example"]}],"retentions":[]}
'@ -Encoding utf8
    $duplicateRefBlocked = $false
    try {
        Read-GitArtifactGovernanceRegistry -Path $duplicateRefPath | Out-Null
    }
    catch {
        $duplicateRefBlocked = $true
    }
    Assert-True $duplicateRefBlocked 'duplicate normalized artifact ref fails closed'
}
finally {
    if (Test-Path -LiteralPath $registryTestRoot) {
        Remove-Item -LiteralPath $registryTestRoot -Recurse -Force
    }
}
$personalOSArtifact = Get-GitArtifactGovernance `
    -Repo 'wlyaaaaa/.agents' `
    -Branch 'origin/codex/personalos-beacon-receipt'
Assert-Equal 'PersonalOS' $personalOSArtifact.owner 'artifact registry identifies the explicit PersonalOS owner'
Assert-True ($null -eq (Get-GitArtifactGovernance `
    -Repo 'wlyaaaaa/.agents' `
    -Branch 'codex/ordinary-feature')) 'artifact registry does not suppress ordinary future feature branches'
$secretBrokerBackupArtifact = Get-GitArtifactGovernance `
    -Repo 'wlyaaaaa/PCConfig' `
    -Branch 'origin/secret-broker-backup'
Assert-Equal 'PCConfig Secret Broker' $secretBrokerBackupArtifact.owner `
    'artifact registry separates the contract-defined encrypted backup stream from default-branch feature convergence'
$governedEvidence = & $admissionModule {
    $worktree = [pscustomobject]@{ branch = 'codex/personalos-beacon-receipt' }
    $branch = [pscustomobject]@{ branch = 'origin/codex/personalos-beacon-receipt' }
    Add-GitArtifactGovernanceEvidence `
        -Repo 'wlyaaaaa/.agents' `
        -Worktrees @($worktree) `
        -Branches @($branch)
    [pscustomobject]@{ worktree = $worktree; branch = $branch }
}
Assert-True $governedEvidence.worktree.external_governance 'worktree evidence marks the explicit external owner'
Assert-True $governedEvidence.branch.external_governance 'remote branch evidence marks the explicit external owner'
$runtimeRetention = Get-GitArtifactRetention `
    -Repo 'wlyaaaaa/codex-local-remote' `
    -Path 'V:\Personal\Worktrees\codex-local-remote-v1-rollback' `
    -Head '2a76e3638e4d22db63e07389810dc47c1d1b03c3'
Assert-Equal 'PCConfig' $runtimeRetention.owner 'retention registry identifies the live runtime evidence owner'
Assert-True (-not [string]::IsNullOrWhiteSpace($runtimeRetention.exit_condition)) `
    'necessary retention always carries an explicit exit condition'
Assert-True ($null -eq (Get-GitArtifactRetention `
    -Repo 'wlyaaaaa/codex-local-remote' `
    -Path 'V:\Personal\Worktrees\codex-local-remote-v1-rollback' `
    -Head '0000000000000000000000000000000000000000')) `
    'retention registry never suppresses a path whose pinned commit changed'
$retentionEvidence = & $admissionModule {
    $worktree = [pscustomobject]@{
        branch = ''
        path = 'V:\Personal\Worktrees\codex-local-remote-v1-rollback'
        head = '2a76e3638e4d22db63e07389810dc47c1d1b03c3'
    }
    Add-GitArtifactGovernanceEvidence `
        -Repo 'wlyaaaaa/codex-local-remote' `
        -Worktrees @($worktree)
    $worktree
}
Assert-True $retentionEvidence.necessary_retention 'worktree evidence marks an exact necessary retention'
Assert-Equal 'PCConfig' $retentionEvidence.retention_owner 'worktree evidence preserves retention owner'

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
    Invoke-TestGit -Path $linkedPath -Arguments @('push', '-u', 'origin', 'feature') | Out-Null
    Invoke-TestGit -Path $linkedPath -Arguments @(
        'push', 'origin', 'feature:refs/heads/codex/remote-unmerged'
    ) | Out-Null
    Invoke-TestGit -Path $primaryPath -Arguments @(
        'push', 'origin', 'main:refs/heads/codex/remote-integrated'
    ) | Out-Null
    foreach ($remoteFixtureBranch in @('codex/remote-unmerged', 'codex/remote-integrated')) {
        Invoke-TestGit -Path $primaryPath -Arguments @(
            'fetch', 'origin',
            "refs/heads/$remoteFixtureBranch`:refs/remotes/origin/$remoteFixtureBranch"
        ) | Out-Null
    }

    $cached = Get-ProjectAdmissionRecord -Repo 'example/project' -RepoPath $primaryPath -Visibility 'PUBLIC' -DefaultBranch 'main'
    Assert-Equal 'github-local-index.project-admission.v1' $cached.schema 'uses versioned admission schema'
    Assert-Equal ([System.IO.Path]::GetFullPath($primaryPath).TrimEnd('\', '/')) $cached.local_root 'keeps the selected repository path as local root'
    Assert-Equal 'example/project' $cached.repo 'normalizes the repository slug in admission JSON'
    Assert-Equal 'https://github.com/example/project.git' $cached.remote_url 'keeps the real configured remote URL in cached admission JSON'
    $requiredAdmissionProperties = @(
        'schema', 'observed_utc', 'repo', 'remote_url', 'visibility', 'default_branch',
        'local_root', 'git_common_dir', 'remote_mode', 'metadata_mode', 'refs_mode',
        'target_worktree', 'target_ref', 'decision', 'push_decision', 'push_strategy',
        'reasons', 'errors', 'worktrees', 'branches'
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
    $cachedFeature = $cached.worktrees | Where-Object branch -eq 'feature'
    Assert-Equal 'in_sync' $cachedFeature.sync_state 'feature can be fully synchronized with its own upstream'
    Assert-Equal 'unmerged' $cachedFeature.integration_state 'feature synchronized to its upstream remains unmerged from default'
    Assert-Equal 1 $cachedFeature.missing_default_commits 'reports commits visible only from the feature worktree'
    Assert-True ($cached.reasons -contains 'default_branch_missing_commits') 'admission reports default branch missing feature commits'
    Assert-True (@($cached.branches | Where-Object branch -eq 'feature').Count -eq 1) 'admission retains local branch integration inventory'
    Assert-True (@($cached.branches | Where-Object {
        $_.branch -eq 'origin/codex/remote-unmerged' -and
        $_.ref_kind -eq 'remote_tracking' -and
        $_.integration_state -eq 'unmerged'
    }).Count -eq 1) 'admission detects a remote-only branch whose commit is missing from default'
    Assert-True (@($cached.branches | Where-Object {
        $_.branch -eq 'origin/codex/remote-integrated' -and
        $_.ref_kind -eq 'remote_tracking' -and
        $_.retirement_candidate
    }).Count -eq 1) 'admission detects an integrated remote-only branch as a retirement candidate'
    Assert-Equal 'warn' $cached.push_decision 'cached dirty admission warns before direct push'
    Assert-Equal 'clean_or_stage_explicitly' $cached.push_strategy 'dirty worktree takes precedence over cached evidence'
    Assert-True ([datetimeoffset]::Parse($cached.observed_utc).Offset -eq [timespan]::Zero) 'timestamps observation in UTC'

    $invalidVisibility = Get-ProjectAdmissionRecord -Repo 'example/project' -RepoPath $primaryPath -Visibility 'UNLISTED' -DefaultBranch 'main'
    Assert-Equal 'block' $invalidVisibility.decision 'invalid visibility fails closed'
    Assert-True ($invalidVisibility.reasons -contains 'visibility_invalid') 'invalid visibility has a stable blocking reason'
    Assert-True ($null -eq $invalidVisibility.visibility) 'invalid visibility never escapes the PUBLIC/PRIVATE/INTERNAL output enum'
    $internalVisibility = Get-ProjectAdmissionRecord -Repo 'example/project' -RepoPath $primaryPath -Visibility 'INTERNAL' -DefaultBranch 'main'
    Assert-Equal 'INTERNAL' $internalVisibility.visibility 'INTERNAL is accepted as the third closed-enum visibility'
    Assert-True (-not ($internalVisibility.reasons -contains 'visibility_invalid')) 'valid INTERNAL visibility is not rejected'

    $externalGovernance = Get-ProjectAdmissionRecord `
        -Repo 'wlyaaaaa/PersonalOS' `
        -RepoPath $primaryPath `
        -Visibility 'PRIVATE' `
        -DefaultBranch 'main'
    Assert-Equal 'block' $externalGovernance.decision 'external governance blocks local admission actions'
    Assert-True ($externalGovernance.reasons -contains 'external_governance_excluded') 'external governance has a stable blocking reason'
    Assert-True ($null -eq $externalGovernance.local_root) 'external governance ignores an explicitly supplied local path before Git inspection'
    Assert-Equal 0 @($externalGovernance.worktrees).Count 'external governance returns no local worktree evidence'

    $admissionParameters = (Get-Command Get-ProjectAdmissionRecord).Parameters.Keys
    Assert-True ($admissionParameters -contains 'LiveMetadata') 'admission exposes a read-only live metadata switch'
    Assert-True ($admissionParameters -contains 'RefreshRefs') 'admission exposes an explicit refs refresh switch'
    Assert-True ($admissionParameters -contains 'TargetWorktree') 'admission exposes an exact target worktree selector'
    Assert-True ($admissionParameters -contains 'TargetRef') 'admission exposes an exact target ref selector'
    if ($admissionParameters -contains 'TargetWorktree') {
        $targetedByWorktree = Get-ProjectAdmissionRecord `
            -Repo 'example/project' `
            -RepoPath $primaryPath `
            -Visibility 'PUBLIC' `
            -DefaultBranch 'main' `
            -TargetWorktree $primaryPath
        Assert-Equal ([System.IO.Path]::GetFullPath($primaryPath).TrimEnd('\', '/')) $targetedByWorktree.target_worktree 'target worktree is normalized in output'
        Assert-True (-not ($targetedByWorktree.reasons -contains 'no_upstream')) 'unrelated no-upstream worktrees do not pollute a targeted decision'
        Assert-True (-not ($targetedByWorktree.reasons -contains 'prunable_worktree')) 'unrelated prunable worktrees do not pollute a targeted decision'
        Assert-True (-not ($targetedByWorktree.reasons -contains 'detached_worktree')) 'unrelated detached worktrees do not pollute a targeted decision'
        Assert-Equal 4 @($targetedByWorktree.worktrees).Count 'targeted decisions retain all worktrees as evidence'
    }
    if ($admissionParameters -contains 'TargetRef') {
        $targetedByRef = Get-ProjectAdmissionRecord `
            -Repo 'example/project' `
            -RepoPath $primaryPath `
            -Visibility 'PUBLIC' `
            -DefaultBranch 'main' `
            -TargetRef 'refs/heads/main'
        Assert-Equal 'refs/heads/main' $targetedByRef.target_ref 'target ref is normalized in output'
        Assert-Equal ([System.IO.Path]::GetFullPath($primaryPath).TrimEnd('\', '/')) $targetedByRef.target_worktree 'target ref resolves to its exact worktree'
        Assert-True (-not ($targetedByRef.reasons -contains 'no_upstream')) 'unrelated worktrees do not pollute a target-ref decision'

        $missingTargetRef = Get-ProjectAdmissionRecord `
            -Repo 'example/project' `
            -RepoPath $primaryPath `
            -Visibility 'PUBLIC' `
            -DefaultBranch 'main' `
            -TargetRef 'refs/heads/does-not-exist'
        Assert-Equal 'block' $missingTargetRef.decision 'unknown target ref fails closed'
        Assert-True ($missingTargetRef.reasons -contains 'target_ref_not_found') 'unknown target ref has a stable reason'

        $mismatchedTargetScope = Get-ProjectAdmissionRecord `
            -Repo 'example/project' `
            -RepoPath $primaryPath `
            -Visibility 'PUBLIC' `
            -DefaultBranch 'main' `
            -TargetWorktree $primaryPath `
            -TargetRef 'refs/heads/feature'
        Assert-Equal 'block' $mismatchedTargetScope.decision 'mismatched ref and worktree fail closed'
        Assert-True ($mismatchedTargetScope.reasons -contains 'target_scope_mismatch') 'mismatched target scope has a stable reason'
    }

    $fetchSuccess = {
        param($path)
        $fetchOutput = @(& git -C $path fetch --prune origin 2>&1)
        [pscustomobject]@{ exit_code = $LASTEXITCODE; stdout = ($fetchOutput -join "`n"); stderr = '' }
    }
    $fetchFailure = { param($path) [pscustomobject]@{ exit_code = 1; stdout = ''; stderr = 'network unavailable' } }
    $ghSuccess = { param($repo) [pscustomobject]@{ exit_code = 0; stdout = '{"nameWithOwner":"example/project","visibility":"PUBLIC","defaultBranchRef":{"name":"main"},"url":"https://github.com/example/project"}'; stderr = '' } }
    $ghFailure = { param($repo) [pscustomobject]@{ exit_code = 1; stdout = ''; stderr = 'not authenticated' } }

    if ($admissionParameters -contains 'LiveMetadata' -and $admissionParameters -contains 'RefreshRefs') {
        $script:ReadOnlyFetchCalls = 0
        $readOnlyFetchGuard = {
            param($path)
            $script:ReadOnlyFetchCalls++
            [pscustomobject]@{ exit_code = 99; stdout = ''; stderr = 'fetch must not run' }
        }
        $metadataOnly = Get-ProjectAdmissionRecord `
            -Repo 'example/project' `
            -RepoPath $primaryPath `
            -Visibility 'PRIVATE' `
            -DefaultBranch 'main' `
            -LiveMetadata `
            -FetchInvoker $readOnlyFetchGuard `
            -GitHubInvoker $ghSuccess
        Assert-Equal 0 $script:ReadOnlyFetchCalls 'read-only live metadata never invokes git fetch'
        Assert-Equal 'live' $metadataOnly.metadata_mode 'read-only live metadata is labeled live'
        Assert-Equal 'cached' $metadataOnly.refs_mode 'read-only live metadata leaves refs cached'

        $script:RefreshMetadataCalls = 0
        $refreshMetadataGuard = {
            param($repo)
            $script:RefreshMetadataCalls++
            [pscustomobject]@{ exit_code = 99; stdout = ''; stderr = 'metadata must not run' }
        }
        $refsOnly = Get-ProjectAdmissionRecord `
            -Repo 'example/project' `
            -RepoPath $primaryPath `
            -Visibility 'PUBLIC' `
            -DefaultBranch 'main' `
            -RefreshRefs `
            -FetchInvoker $fetchSuccess `
            -GitHubInvoker $refreshMetadataGuard
        Assert-Equal 0 $script:RefreshMetadataCalls 'explicit refs refresh never invokes GitHub metadata'
        Assert-Equal 'cached' $refsOnly.metadata_mode 'refs-only refresh leaves metadata cached'
        Assert-Equal 'live' $refsOnly.refs_mode 'successful refs refresh is labeled live'
    }

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

    $integrationPath = Join-Path $tempRoot 'integration'
    Invoke-TestGit -Path $tempRoot -Arguments @('init', '--initial-branch=main', $integrationPath) | Out-Null
    Invoke-TestGit -Path $integrationPath -Arguments @('config', 'user.name', 'Integration Test') | Out-Null
    Invoke-TestGit -Path $integrationPath -Arguments @('config', 'user.email', 'integration@example.invalid') | Out-Null
    Set-Content -LiteralPath (Join-Path $integrationPath 'base.txt') -Value 'base' -Encoding utf8
    Invoke-TestGit -Path $integrationPath -Arguments @('add', 'base.txt') | Out-Null
    Invoke-TestGit -Path $integrationPath -Arguments @('commit', '-m', 'base') | Out-Null
    Invoke-TestGit -Path $integrationPath -Arguments @('switch', '-c', 'feature-equivalent') | Out-Null
    Set-Content -LiteralPath (Join-Path $integrationPath 'feature.txt') -Value 'feature' -Encoding utf8
    Invoke-TestGit -Path $integrationPath -Arguments @('add', 'feature.txt') | Out-Null
    Invoke-TestGit -Path $integrationPath -Arguments @('commit', '-m', 'feature patch') | Out-Null
    $featureEquivalentHead = Invoke-TestGit -Path $integrationPath -Arguments @('rev-parse', 'HEAD')
    Invoke-TestGit -Path $integrationPath -Arguments @('switch', 'main') | Out-Null
    Set-Content -LiteralPath (Join-Path $integrationPath 'main-only.txt') -Value 'main only' -Encoding utf8
    Invoke-TestGit -Path $integrationPath -Arguments @('add', 'main-only.txt') | Out-Null
    Invoke-TestGit -Path $integrationPath -Arguments @('commit', '-m', 'main only') | Out-Null
    Invoke-TestGit -Path $integrationPath -Arguments @('cherry-pick', $featureEquivalentHead) | Out-Null
    Invoke-TestGit -Path $integrationPath -Arguments @('branch', 'merged-residual') | Out-Null

    $patchEquivalent = Get-GitDefaultBranchIntegrationEvidence `
        -Path $integrationPath -DefaultBranch 'main' -Head $featureEquivalentHead -Branch 'feature-equivalent'
    Assert-Equal 'patch_equivalent' $patchEquivalent.integration_state 'detects a feature patch absorbed under a different commit'
    Assert-Equal 0 $patchEquivalent.missing_default_commits 'patch-equivalent feature leaves no content missing from default'
    $integrationBranches = @(Get-GitRepositoryBranchInventory -Path $integrationPath -DefaultBranch 'main')
    Assert-True (@($integrationBranches | Where-Object {
        $_.branch -eq 'merged-residual' -and $_.integration_state -eq 'merged_ancestry' -and $_.retirement_candidate
    }).Count -eq 1) 'detects an integrated local branch without a worktree as a retirement candidate'
    $unknownIntegration = Get-GitDefaultBranchIntegrationEvidence `
        -Path $integrationPath -DefaultBranch 'missing-default' -Head $featureEquivalentHead -Branch 'feature-equivalent'
    Assert-Equal 'unknown' $unknownIntegration.integration_state 'missing default ref fails closed as unknown'

    $singleBranchPath = Join-Path $tempRoot 'single-snapshot-branch'
    Invoke-TestGit -Path $tempRoot -Arguments @(
        'init', '--initial-branch=codex/snapshot', $singleBranchPath
    ) | Out-Null
    Invoke-TestGit -Path $singleBranchPath -Arguments @('config', 'user.name', 'Snapshot Test') | Out-Null
    Invoke-TestGit -Path $singleBranchPath -Arguments @('config', 'user.email', 'snapshot@example.invalid') | Out-Null
    Set-Content -LiteralPath (Join-Path $singleBranchPath 'snapshot.txt') -Value 'snapshot' -Encoding utf8
    Invoke-TestGit -Path $singleBranchPath -Arguments @('add', 'snapshot.txt') | Out-Null
    Invoke-TestGit -Path $singleBranchPath -Arguments @('commit', '-m', 'snapshot') | Out-Null
    $singleSnapshotHead = Invoke-TestGit -Path $singleBranchPath -Arguments @('rev-parse', 'HEAD')
    Set-Content -LiteralPath (Join-Path $singleBranchPath 'successor.txt') -Value 'successor' -Encoding utf8
    Invoke-TestGit -Path $singleBranchPath -Arguments @('add', 'successor.txt') | Out-Null
    Invoke-TestGit -Path $singleBranchPath -Arguments @('commit', '-m', 'successor') | Out-Null
    $singleRemoteHead = Invoke-TestGit -Path $singleBranchPath -Arguments @('rev-parse', 'HEAD')
    Invoke-TestGit -Path $singleBranchPath -Arguments @(
        'update-ref', 'refs/remotes/origin/codex/snapshot', $singleRemoteHead
    ) | Out-Null
    Invoke-TestGit -Path $singleBranchPath -Arguments @('reset', '--hard', $singleSnapshotHead) | Out-Null
    Invoke-TestGit -Path $singleBranchPath -Arguments @(
        'remote', 'add', 'origin', 'https://github.com/example/single-snapshot.git'
    ) | Out-Null
    $singleBranchInventory = @(
        Get-GitRepositoryBranchInventory -Path $singleBranchPath -DefaultBranch 'main'
    )
    Assert-Equal 2 $singleBranchInventory.Count `
        'single local branch plus a different remote-tracking tip remains an array'
    Assert-Equal 1 @($singleBranchInventory | Where-Object ref_kind -eq 'local').Count `
        'single-branch inventory preserves the local snapshot ref'
    Assert-Equal 1 @($singleBranchInventory | Where-Object ref_kind -eq 'remote_tracking').Count `
        'single-branch inventory appends the distinct remote-tracking ref'
    Assert-True (@($singleBranchInventory | Where-Object integration_state -eq 'unknown').Count -eq 2) `
        'missing default ref stays explicitly unknown without throwing'
    $singleBranchAdmission = Get-ProjectAdmissionRecord `
        -Repo 'example/single-snapshot' `
        -RepoPath $singleBranchPath `
        -Visibility 'PRIVATE' `
        -DefaultBranch 'main'
    Assert-True (@($singleBranchAdmission.errors | Where-Object {
        $_.category -eq 'default_branch_integration_failed'
    }).Count -eq 0) 'single-branch inventory no longer becomes a provider failure'

    $remoteGateBarePath = Join-Path $tempRoot 'remote-gate.git'
    $remoteGatePath = Join-Path $tempRoot 'remote-gate'
    Invoke-TestGit -Path $tempRoot -Arguments @('init', '--bare', $remoteGateBarePath) | Out-Null
    & git clone $remoteGateBarePath $remoteGatePath 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'failed to clone remote default gate fixture' }
    Invoke-TestGit -Path $remoteGatePath -Arguments @('config', 'user.name', 'Remote Gate Test') | Out-Null
    Invoke-TestGit -Path $remoteGatePath -Arguments @('config', 'user.email', 'remote-gate@example.invalid') | Out-Null
    Invoke-TestGit -Path $remoteGatePath -Arguments @('switch', '-c', 'main') | Out-Null
    Set-Content -LiteralPath (Join-Path $remoteGatePath 'base.txt') -Value 'base' -Encoding utf8
    Invoke-TestGit -Path $remoteGatePath -Arguments @('add', 'base.txt') | Out-Null
    Invoke-TestGit -Path $remoteGatePath -Arguments @('commit', '-m', 'base') | Out-Null
    Invoke-TestGit -Path $remoteGatePath -Arguments @('push', '-u', 'origin', 'main') | Out-Null
    Invoke-TestGit -Path $remoteGatePath -Arguments @('switch', '-c', 'gate-feature') | Out-Null
    Set-Content -LiteralPath (Join-Path $remoteGatePath 'gate.txt') -Value 'gate' -Encoding utf8
    Invoke-TestGit -Path $remoteGatePath -Arguments @('add', 'gate.txt') | Out-Null
    Invoke-TestGit -Path $remoteGatePath -Arguments @('commit', '-m', 'gate feature') | Out-Null
    $remoteGateTarget = Invoke-TestGit -Path $remoteGatePath -Arguments @('rev-parse', 'HEAD')
    Invoke-TestGit -Path $remoteGatePath -Arguments @('switch', 'main') | Out-Null
    Invoke-TestGit -Path $remoteGatePath -Arguments @('merge', '--ff-only', 'gate-feature') | Out-Null
    $beforeRemotePush = Get-GitDefaultBranchIntegrationEvidence `
        -Path $remoteGatePath -DefaultBranch 'main' -Head $remoteGateTarget -Branch 'gate-feature'
    Assert-Equal 'refs/remotes/origin/main' $beforeRemotePush.default_ref 'completion gate compares with the actual remote default ref'
    Assert-Equal 'unmerged' $beforeRemotePush.integration_state 'local default reachability alone does not pass before the remote default is pushed'
    Invoke-TestGit -Path $remoteGatePath -Arguments @('push', 'origin', 'main') | Out-Null
    $afterRemotePush = Get-GitDefaultBranchIntegrationEvidence `
        -Path $remoteGatePath -DefaultBranch 'main' -Head $remoteGateTarget -Branch 'gate-feature'
    Assert-Equal 'merged_ancestry' $afterRemotePush.integration_state 'remote default reachability passes after normal push'
    Assert-Equal 0 $afterRemotePush.missing_default_commits 'pushed default branch contains the target commit'

    $ownerBoundaryPath = Join-Path $tempRoot 'artifact-owner-boundary'
    Invoke-TestGit -Path $tempRoot -Arguments @('init', '--initial-branch=main', $ownerBoundaryPath) | Out-Null
    Invoke-TestGit -Path $ownerBoundaryPath -Arguments @('config', 'user.name', 'Owner Boundary Test') | Out-Null
    Invoke-TestGit -Path $ownerBoundaryPath -Arguments @('config', 'user.email', 'owner-boundary@example.invalid') | Out-Null
    Set-Content -LiteralPath (Join-Path $ownerBoundaryPath 'main.txt') -Value 'main' -Encoding utf8
    Invoke-TestGit -Path $ownerBoundaryPath -Arguments @('add', 'main.txt') | Out-Null
    Invoke-TestGit -Path $ownerBoundaryPath -Arguments @('commit', '-m', 'main') | Out-Null
    Invoke-TestGit -Path $ownerBoundaryPath -Arguments @(
        'switch', '-c', 'codex/personalos-beacon-receipt'
    ) | Out-Null
    Set-Content -LiteralPath (Join-Path $ownerBoundaryPath 'owner.txt') -Value 'external owner' -Encoding utf8
    Invoke-TestGit -Path $ownerBoundaryPath -Arguments @('add', 'owner.txt') | Out-Null
    Invoke-TestGit -Path $ownerBoundaryPath -Arguments @('commit', '-m', 'external owner fixture') | Out-Null
    Invoke-TestGit -Path $ownerBoundaryPath -Arguments @('switch', 'main') | Out-Null
    Invoke-TestGit -Path $ownerBoundaryPath -Arguments @(
        'remote', 'add', 'origin', 'https://github.com/wlyaaaaa/.agents.git'
    ) | Out-Null
    $ownerBoundaryAdmission = Get-ProjectAdmissionRecord `
        -Repo 'wlyaaaaa/.agents' `
        -RepoPath $ownerBoundaryPath `
        -Visibility 'PRIVATE' `
        -DefaultBranch 'main'
    $protectedOwnerBranch = $ownerBoundaryAdmission.branches | Where-Object {
        $_.branch -eq 'codex/personalos-beacon-receipt'
    }
    Assert-True $protectedOwnerBranch.external_governance 'admission preserves explicit cross-owner branch evidence'
    Assert-Equal 'PersonalOS' $protectedOwnerBranch.governance_owner 'admission reports the explicit artifact owner'
    Assert-True (-not ($ownerBoundaryAdmission.reasons -contains 'default_branch_missing_commits')) `
        'cross-owner branch commits do not become Codex default-branch integration actions'

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
    Set-Content -LiteralPath (Join-Path $sensitiveDirectory '.env.local') -Value 'TEST_ONLY=1' -Encoding utf8
    $publicConflict = Get-ProjectAdmissionRecord -Repo 'example/project' -RepoPath $primaryPath -Visibility 'PUBLIC' -DefaultBranch 'main'
    Assert-Equal 'block' $publicConflict.decision 'blocks nested .env variants containing Chinese and spaces'
    Assert-True ($publicConflict.reasons -contains 'public_exposure_conflict') 'reports public exposure conflict reason'
    Assert-Equal 'block' $publicConflict.push_decision 'public exposure conflict blocks push'
    Assert-Equal 'resolve_public_exposure' $publicConflict.push_strategy 'public exposure conflict has a dedicated remediation strategy'
    Remove-Item -LiteralPath (Split-Path -Parent $sensitiveDirectory) -Recurse -Force

    $trackedSensitivePath = Join-Path $primaryPath '.env'
    $renameSourceDirectory = Join-Path $primaryPath 'secrets'
    $renameSourcePath = Join-Path $renameSourceDirectory 'rename-fixture.txt'
    New-Item -ItemType Directory -Path $renameSourceDirectory -Force | Out-Null
    Set-Content -LiteralPath $trackedSensitivePath -Value 'TEST_ONLY=1' -Encoding utf8
    Set-Content -LiteralPath $renameSourcePath -Value 'rename fixture' -Encoding utf8
    Invoke-TestGit -Path $primaryPath -Arguments @('add', '--', '.env', 'secrets/rename-fixture.txt') | Out-Null
    Invoke-TestGit -Path $primaryPath -Arguments @('commit', '-m', 'sensitive remediation fixtures') | Out-Null

    Invoke-TestGit -Path $primaryPath -Arguments @('rm', '--', '.env') | Out-Null
    $deletionRemediation = Get-ProjectAdmissionRecord -Repo 'example/project' -RepoPath $primaryPath -Visibility 'PUBLIC' -DefaultBranch 'main'
    Assert-True (-not ($deletionRemediation.reasons -contains 'public_exposure_conflict')) 'pure deletion of a tracked sensitive path is remediation, not public exposure'
    Assert-True ($deletionRemediation.decision -ne 'block') 'pure deletion remains eligible for a remediation commit'
    Invoke-TestGit -Path $primaryPath -Arguments @('commit', '-m', 'remove sensitive fixture') | Out-Null

    Invoke-TestGit -Path $primaryPath -Arguments @('mv', '--', 'secrets/rename-fixture.txt', 'safe-renamed-fixture.txt') | Out-Null
    $renameRemediation = Get-ProjectAdmissionRecord -Repo 'example/project' -RepoPath $primaryPath -Visibility 'PUBLIC' -DefaultBranch 'main'
    Assert-True (-not ($renameRemediation.reasons -contains 'public_exposure_conflict')) 'rename from a sensitive source to a safe destination is remediation'
    Assert-True ($renameRemediation.decision -ne 'block') 'safe-destination rename remains eligible for a remediation commit'
    Invoke-TestGit -Path $primaryPath -Arguments @('commit', '-m', 'rename sensitive fixture safely') | Out-Null

    Set-Content -LiteralPath (Join-Path $primaryPath 'safe-rename-source.txt') -Value 'safe rename source' -Encoding utf8
    Invoke-TestGit -Path $primaryPath -Arguments @('add', '--', 'safe-rename-source.txt') | Out-Null
    Invoke-TestGit -Path $primaryPath -Arguments @('commit', '-m', 'safe rename source') | Out-Null
    Invoke-TestGit -Path $primaryPath -Arguments @('mv', '--', 'safe-rename-source.txt', '.env.production') | Out-Null
    $renameIntoSensitivePath = Get-ProjectAdmissionRecord -Repo 'example/project' -RepoPath $primaryPath -Visibility 'PUBLIC' -DefaultBranch 'main'
    Assert-Equal 'block' $renameIntoSensitivePath.decision 'rename into a sensitive destination fails closed'
    Assert-True ($renameIntoSensitivePath.reasons -contains 'public_exposure_conflict') 'rename destination is evaluated by the public-exposure policy'

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
    Assert-Equal 0 $LASTEXITCODE 'CLI success represents nonblocking admission only'
    Assert-True (-not ($cliRecord.PSObject.Properties.Name -contains 'publication_decision')) `
        'admission v1 deliberately does not claim publication authorization'
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
