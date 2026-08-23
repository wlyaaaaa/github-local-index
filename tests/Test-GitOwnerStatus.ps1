#requires -Version 7.0

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$providerPath = Join-Path $repoRoot 'tools/Get-GitOwnerStatus.ps1'

if (-not (Test-Path -LiteralPath $providerPath -PathType Leaf)) {
    throw "Missing Git owner provider: $providerPath"
}

. $providerPath

$failures = 0

function Assert-OwnerEqual {
    param(
        [AllowNull()] [object] $Expected,
        [AllowNull()] [object] $Actual,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    if ($Expected -ne $Actual) {
        Write-Host "FAIL: $Name"
        Write-Host "  expected: $Expected"
        Write-Host "  actual:   $Actual"
        $script:failures++
        return
    }

    Write-Host "PASS: $Name"
}

function Assert-OwnerTrue {
    param(
        [Parameter(Mandatory = $true)] [bool] $Condition,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    if (-not $Condition) {
        Write-Host "FAIL: $Name"
        $script:failures++
        return
    }

    Write-Host "PASS: $Name"
}

$baselineRows = @(
    [pscustomobject]@{
        NameWithOwner = 'wlyaaaaa/github-local-index'
        Visibility = 'PUBLIC'
        DefaultBranch = 'main'
        LocalPath = 'E:\GitHub总索引'
        LocalState = '`main` 已同步，`0/0`'
        DirtyCount = 0
        Ahead = 0
        Behind = 0
    },
    [pscustomobject]@{
        NameWithOwner = 'wlyaaaaa/PersonalOS'
        Visibility = 'PRIVATE'
        DefaultBranch = 'main'
        LocalPath = '外部治理（不读取本地路径）'
        ExternalGovernance = $true
    }
)

$externalPathFixture = 'X:\external-owner-root\must-never-leak'
$observedRows = @(
    [pscustomobject]@{
        NameWithOwner = 'WLYAAAAA/GITHUB-LOCAL-INDEX'
        Visibility = 'public'
        DefaultBranch = 'main'
        LocalPath = 'e:/github总索引/'
        LocalState = '`feature` ahead 99, dirty 12'
        DirtyCount = 12
        Ahead = 99
        Behind = 7
        TaskName = 'must-not-be-observed'
    },
    [pscustomobject]@{
        NameWithOwner = 'wlyaaaaa/PersonalOS'
        Visibility = 'PRIVATE'
        DefaultBranch = 'main'
        LocalPath = $externalPathFixture
    }
)

$indexIdentity = [pscustomobject]@{
    repository = 'wlyaaaaa/github-local-index'
    default_branch = 'main'
    head = '84afc15025ca8643bf2a29f9c3f24d353fab8fa8'
}

$registryA = ConvertTo-GitOwnerGovernanceRegistryIdentity -Registry ([pscustomobject]@{
    schema = 'github-local-index.git-artifact-governance.v1'
    entries = @(
        [pscustomobject]@{ repo = 'wlyaaaaa/PCConfig'; owner = 'PersonalOS'; refs = @('z-ref', 'a-ref') },
        [pscustomobject]@{ repo = 'wlyaaaaa/.agents'; owner = 'PersonalOS'; refs = @('main') }
    )
    retentions = @()
})
$registryB = ConvertTo-GitOwnerGovernanceRegistryIdentity -Registry ([pscustomobject]@{
    retentions = @()
    entries = @(
        [pscustomobject]@{ refs = @('main'); owner = 'PersonalOS'; repo = 'WLYAAAAA/.AGENTS' },
        [pscustomobject]@{ refs = @('a-ref', 'z-ref'); owner = 'PersonalOS'; repo = 'WLYAAAAA/PCCONFIG' }
    )
    schema = 'github-local-index.git-artifact-governance.v1'
})
$registryC = ConvertTo-GitOwnerGovernanceRegistryIdentity -Registry ([pscustomobject]@{
    schema = 'github-local-index.git-artifact-governance.v1'
    entries = @(
        [pscustomobject]@{ repo = 'wlyaaaaa/.agents'; owner = 'PersonalOS'; refs = @('refs/heads/main') },
        [pscustomobject]@{ repo = 'wlyaaaaa/PCConfig'; owner = 'PersonalOS'; refs = @('refs/heads/z-ref', 'origin/a-ref') }
    )
    retentions = @()
})
Assert-OwnerTrue ([bool]$registryA.valid) 'governance registry identity validates the owner schema'
Assert-OwnerEqual $registryA.fingerprint $registryB.fingerprint 'governance registry fingerprint ignores JSON property, entry and ref order'
Assert-OwnerEqual $registryA.fingerprint $registryC.fingerprint 'governance registry fingerprint canonicalizes refs/heads and origin prefixes'

$duplicateLogicalRefRegistry = ConvertTo-GitOwnerGovernanceRegistryIdentity -Registry ([pscustomobject]@{
    schema = 'github-local-index.git-artifact-governance.v1'
    entries = @(
        [pscustomobject]@{ repo = 'wlyaaaaa/example'; owner = 'owner-a'; refs = @('main') },
        [pscustomobject]@{ repo = 'WLYAAAAA/EXAMPLE'; owner = 'owner-b'; refs = @('origin/main') }
    )
    retentions = @()
})
Assert-OwnerTrue (-not [bool]$duplicateLogicalRefRegistry.valid) 'logically duplicate refs are rejected across registry entries'

$overrideRegistryA = ConvertTo-GitOwnerGovernanceRegistryIdentity -Registry ([pscustomobject]@{
    schema = 'github-local-index.git-artifact-governance.v1'
    entries = @()
    repository_overrides = @([pscustomobject]@{
        repo = 'wlyaaaaa/PersonalOS-Retired'
        policy = 'frozen_history'
        owner = 'retirement owner'
        purpose = 'retain historical refs'
        exit_condition = 'explicit retirement-history migration approval'
    })
    retentions = @()
})
$overrideRegistryB = ConvertTo-GitOwnerGovernanceRegistryIdentity -Registry ([pscustomobject]@{
    retentions = @()
    repository_overrides = @([pscustomobject]@{
        exit_condition = 'explicit retirement-history migration approval'
        purpose = 'retain historical refs'
        owner = 'retirement owner'
        policy = 'FROZEN_HISTORY'
        repo = 'WLYAAAAA/PERSONALOS-RETIRED'
    })
    entries = @()
    schema = 'github-local-index.git-artifact-governance.v1'
})
Assert-OwnerTrue ([bool]$overrideRegistryA.valid) 'frozen-history repository override validates'
Assert-OwnerEqual $overrideRegistryA.fingerprint $overrideRegistryB.fingerprint `
    'repository override fingerprint is stable across case and property order'

$invalidOverrideRegistry = ConvertTo-GitOwnerGovernanceRegistryIdentity -Registry ([pscustomobject]@{
    schema = 'github-local-index.git-artifact-governance.v1'
    entries = @()
    repository_overrides = @([pscustomobject]@{
        repo = 'wlyaaaaa/example'
        policy = 'merge_history'
        owner = 'fixture-owner'
        purpose = 'invalid policy'
        exit_condition = 'never'
    })
    retentions = @()
})
Assert-OwnerTrue (-not [bool]$invalidOverrideRegistry.valid) 'unknown repository override policy is rejected'

$invalidRetentionRegistry = ConvertTo-GitOwnerGovernanceRegistryIdentity -Registry ([pscustomobject]@{
    schema = 'github-local-index.git-artifact-governance.v1'
    entries = @()
    retentions = @(
        [pscustomobject]@{
            repo = 'wlyaaaaa/example'
            path = 'relative-root'
            head = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            disposition = 'delete'
            owner = 'fixture-owner'
            purpose = ''
            exit_condition = ''
        }
    )
})
Assert-OwnerTrue (-not [bool]$invalidRetentionRegistry.valid) 'retention validation matches rooted retain-only owner semantics'

$splitEntryRegistryA = ConvertTo-GitOwnerGovernanceRegistryIdentity -Registry ([pscustomobject]@{
    schema = 'github-local-index.git-artifact-governance.v1'
    entries = @(
        [pscustomobject]@{ repo = 'wlyaaaaa/example'; owner = 'fixture-owner'; refs = @('main') },
        [pscustomobject]@{ repo = 'wlyaaaaa/example'; owner = 'fixture-owner'; refs = @('dev') }
    )
    retentions = @()
})
$splitEntryRegistryB = ConvertTo-GitOwnerGovernanceRegistryIdentity -Registry ([pscustomobject]@{
    schema = 'github-local-index.git-artifact-governance.v1'
    entries = @(
        [pscustomobject]@{ repo = 'wlyaaaaa/example'; owner = 'fixture-owner'; refs = @('dev') },
        [pscustomobject]@{ repo = 'wlyaaaaa/example'; owner = 'fixture-owner'; refs = @('main') }
    )
    retentions = @()
})
Assert-OwnerEqual $splitEntryRegistryA.fingerprint $splitEntryRegistryB.fingerprint 'registry fingerprint is stable when equal sort keys arrive in reverse order'

$current = Invoke-GitOwnerStatus `
    -BaselineRows $baselineRows `
    -ObservedRows $observedRows `
    -IndexIdentity $indexIdentity `
    -RegistryIdentity $registryA `
    -ObservedAt ([datetimeoffset]'2026-08-01T00:00:00Z')

Assert-OwnerEqual 'github-local-index.owner-status.v1' $current.schema 'provider emits the compact owner-status schema'
Assert-OwnerEqual 'completed' $current.execution_status 'successful provider execution is explicit'
Assert-OwnerEqual 'current' $current.domain_status 'dynamic worktree facts do not create owner drift'
Assert-OwnerEqual 0 @($current.deltas).Count 'current owner facts emit no deltas'
Assert-OwnerEqual 0 (Get-GitOwnerStatusProcessExitCode -Status $current) 'current domain status exits successfully'
Assert-OwnerTrue ([bool]$current.zero_write) 'provider declares the zero-write effect contract'
Assert-OwnerTrue ($current.fingerprint.value -match '^sha256:[0-9a-f]{64}$') 'fingerprint uses a stable SHA-256 representation'
Assert-OwnerTrue ([bool]$current.registry.valid) 'compact output exposes governance registry validity without its contents'
Assert-OwnerEqual $indexIdentity.head $current.provenance.index_head 'index HEAD is retained only as provider provenance'

$mismatchedIdentity = [pscustomobject]@{
    repository = 'attacker/github-local-index'
    default_branch = 'main'
    head = $indexIdentity.head
}
$identityBlocked = Invoke-GitOwnerStatus `
    -BaselineRows $baselineRows `
    -ObservedRows $observedRows `
    -IndexIdentity $mismatchedIdentity `
    -RegistryIdentity $registryA `
    -ObservedAt ([datetimeoffset]'2026-08-01T00:00:00Z')
Assert-OwnerEqual 'completed' $identityBlocked.execution_status 'index repository mismatch remains a completed identity observation'
Assert-OwnerEqual 'blocked' $identityBlocked.domain_status 'index repository mismatch can never be owner-current'
Assert-OwnerTrue (@($identityBlocked.issues | Where-Object code -EQ 'index_repository_mismatch').Count -eq 1) 'index repository mismatch emits a bounded blocking issue'

$missingIdentity = Invoke-GitOwnerStatus `
    -BaselineRows $baselineRows `
    -ObservedRows $observedRows `
    -IndexIdentity ([pscustomobject]@{ repository=$null; default_branch='main'; head=$indexIdentity.head }) `
    -RegistryIdentity $registryA `
    -ObservedAt ([datetimeoffset]'2026-08-01T00:00:00Z')
Assert-OwnerEqual 'blocked' $missingIdentity.domain_status 'unresolved index repository identity can never be owner-current'
Assert-OwnerTrue (@($missingIdentity.issues | Where-Object code -EQ 'index_repository_unresolved').Count -eq 1) 'unresolved index repository emits a bounded blocking issue'

foreach ($gateCase in @(
    [pscustomobject]@{
        name = 'mismatch'
        identity = $mismatchedIdentity
        issue = 'index_repository_mismatch'
    },
    [pscustomobject]@{
        name = 'unresolved'
        identity = [pscustomobject]@{
            repository = $null
            default_branch = $null
            head = $indexIdentity.head
        }
        issue = 'index_repository_unresolved'
    }
)) {
    $probeCounts = [ordered]@{
        identity = 0
        read_index = 0
        read_registry = 0
        gh = 0
        local_path = 0
    }
    $gateIdentity = $gateCase.identity
    $gateStatus = Invoke-GitOwnerProvider `
        -Owner 'wlyaaaaa' `
        -ExpectedRepository 'wlyaaaaa/github-local-index' `
        -RepoRoot $repoRoot `
        -IdentityResolver {
            param($Root)
            $probeCounts.identity++
            return $gateIdentity
        } `
        -IndexReader {
            param($Root)
            $probeCounts.read_index++
            throw 'index_reader_must_not_run'
        } `
        -RegistryReader {
            param($Root)
            $probeCounts.read_registry++
            throw 'registry_reader_must_not_run'
        } `
        -RemoteReader {
            param($OwnerName)
            $probeCounts.gh++
            throw 'gh_must_not_run'
        } `
        -RemoteMerger {
            param($Baseline,$Remote)
            $probeCounts.local_path++
            throw 'local_path_probe_must_not_run'
        }
    Assert-OwnerEqual 'completed' $gateStatus.execution_status "$($gateCase.name) identity gate remains a completed observation"
    Assert-OwnerEqual 'blocked' $gateStatus.domain_status "$($gateCase.name) identity gate blocks before owner sources"
    Assert-OwnerTrue (
        @($gateStatus.issues | Where-Object code -EQ $gateCase.issue).Count -eq 1
    ) "$($gateCase.name) identity gate returns its bounded issue"
    Assert-OwnerTrue (
        $probeCounts.identity -eq 1 -and
        $probeCounts.read_index -eq 0 -and
        $probeCounts.read_registry -eq 0 -and
        $probeCounts.gh -eq 0 -and
        $probeCounts.local_path -eq 0
    ) "$($gateCase.name) identity gate performs zero untrusted-source or local-path calls"
}

$validProbeCounts = [ordered]@{
    identity = 0
    read_index = 0
    read_registry = 0
    gh = 0
    local_path = 0
}
$validGateStatus = Invoke-GitOwnerProvider `
    -Owner 'wlyaaaaa' `
    -ExpectedRepository 'wlyaaaaa/github-local-index' `
    -RepoRoot $repoRoot `
    -IdentityResolver {
        param($Root)
        $validProbeCounts.identity++
        return $indexIdentity
    } `
    -IndexReader {
        param($Root)
        $validProbeCounts.read_index++
        return $baselineRows
    } `
    -RegistryReader {
        param($Root)
        $validProbeCounts.read_registry++
        return $registryA
    } `
    -RemoteReader {
        param($OwnerName)
        $validProbeCounts.gh++
        return [pscustomobject]@{
            available = $true
            reason = $null
            rows = $observedRows
        }
    } `
    -RemoteMerger {
        param($Baseline,$Remote)
        $validProbeCounts.local_path++
        return $observedRows
    }
Assert-OwnerEqual 'current' $validGateStatus.domain_status 'valid identity preserves the owner-current path'
Assert-OwnerTrue (
    $validProbeCounts.identity -eq 1 -and
    $validProbeCounts.read_index -eq 1 -and
    $validProbeCounts.read_registry -eq 1 -and
    $validProbeCounts.gh -eq 1 -and
    $validProbeCounts.local_path -eq 1
) 'valid identity invokes each downstream owner source exactly once'

Assert-OwnerEqual $null `
    (ConvertTo-GitOwnerCanonicalRoot -Path '本机已发现 clone（路径不公开）') `
    'public-safe clone-presence sentinel never becomes a filesystem root'

$baselineV3Root = Join-Path ([IO.Path]::GetTempPath()) (
    'git-owner-baseline-v3-' + [guid]::NewGuid().ToString('N')
)
$baselineV3Clone = Join-Path $baselineV3Root 'clones/public-index'
try {
    [void][IO.Directory]::CreateDirectory((Join-Path $baselineV3Clone '.git'))
    [IO.File]::WriteAllText(
        (Join-Path $baselineV3Clone '.git/HEAD'),
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`n",
        [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText(
        (Join-Path $baselineV3Clone '.git/config'),
        "[remote `"origin`"]`n  url = https://github.com/fixture-owner/index.git`n",
        [Text.UTF8Encoding]::new($false))
    Write-GitHubIndexPrivateNavigationCache -RepoRoot $baselineV3Root -Rows @(
        [pscustomobject]@{
            NameWithOwner = 'fixture-owner/index'
            NavigationPath = $baselineV3Clone
            Visibility = 'PUBLIC'
            DefaultBranch = 'main'
        }
    ) | Out-Null
    $publicProjectionPath = Join-Path $baselineV3Root '01_仓库索引/GitHub仓库索引.md'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $publicProjectionPath))
    [IO.File]::WriteAllText(
        $publicProjectionPath,
        "| GitHub 仓库 | 可见性 | 默认分支 | 本地路径 |`n| --- | --- | --- | --- |`n| fixture-owner/index | PUBLIC | main | 本机已发现 clone（路径不公开） |`n",
        [Text.UTF8Encoding]::new($false))

    $missingV3 = Read-GitOwnerBaselineState -RepoRoot $baselineV3Root
    Assert-OwnerEqual 'unavailable' $missingV3.status 'legacy v2 navigation never impersonates a complete v3 identity baseline'
    Assert-OwnerEqual 'owner_baseline_v3_missing' $missingV3.reason 'missing v3 baseline fails with a stable unknown reason'

    $fixtureIndexIdentity = [pscustomobject]@{
        repository = 'fixture-owner/index'
        default_branch = 'main'
        head = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    }
    $fixtureRemoteRows = @(
        [pscustomobject]@{ NameWithOwner='fixture-owner/index'; Visibility='PUBLIC'; DefaultBranch='main'; LocalPath='未发现本地 clone'; ExternalGovernance=$false },
        [pscustomobject]@{ NameWithOwner='fixture-owner/private-data'; Visibility='PRIVATE'; DefaultBranch='main'; LocalPath='未发现本地 clone'; ExternalGovernance=$false }
    )
    $fixtureRemoteReader = {
        param($OwnerName)
        [pscustomobject]@{ available=$true; reason=$null; rows=$fixtureRemoteRows }
    }
    $bootstrapMigration = Invoke-GitOwnerBaselineMigration `
        -Owner 'fixture-owner' -ExpectedRepository 'fixture-owner/index' `
        -RepoRoot $baselineV3Root `
        -IdentityResolver { param($Root) $fixtureIndexIdentity } `
        -RemoteReader $fixtureRemoteReader
    Assert-OwnerEqual 'completed' $bootstrapMigration.execution_status 'v2 navigation migrates through the bounded v3 owner path'
    Assert-OwnerEqual 'attention' $bootstrapMigration.domain_status 'first v3 bootstrap preserves its history gap'
    Assert-OwnerTrue ([bool]$bootstrapMigration.history_gap) 'bootstrap receipt never invents a prior full-owner baseline'
    Assert-OwnerEqual 2 $bootstrapMigration.repository_count 'v3 identity baseline includes PUBLIC and PRIVATE repositories'
    Assert-OwnerEqual 1 $bootstrapMigration.verified_local_roots 'v2 local root is verified through exact .git origin identity'
    Assert-OwnerEqual 1 $bootstrapMigration.nullable_local_roots 'repository without a clone keeps a nullable local root'

    $bootstrapStore = Get-GitHubOwnerBaselineStore -RepoRoot $baselineV3Root
    Assert-OwnerEqual 'current' $bootstrapStore.status 'v3 store passes schema, hash and final readback validation'
    Assert-OwnerTrue ($null -eq $bootstrapStore.store.previous) 'bootstrap store has an explicit absent previous snapshot'
    Assert-OwnerTrue (@($bootstrapStore.store.current_local_roots.entries | Where-Object {
        $_.repo -eq 'fixture-owner/private-data' -and $null -eq $_.local_root
    }).Count -eq 1) 'identity inventory and nullable local-root metadata remain separate'

    $bootstrapStatus = Invoke-GitOwnerProvider `
        -Owner 'fixture-owner' -ExpectedRepository 'fixture-owner/index' `
        -RepoRoot $baselineV3Root `
        -IdentityResolver { param($Root) $fixtureIndexIdentity } `
        -RegistryReader { param($Root) $registryA } `
        -RemoteReader $fixtureRemoteReader
    Assert-OwnerEqual 'unknown' $bootstrapStatus.domain_status 'current identities plus missing prior history remain explicit unknown'
    Assert-OwnerEqual 0 $bootstrapStatus.summary.delta_count 'PUBLIC-only projection creates no false full-owner delta'
    Assert-OwnerEqual 0 $bootstrapStatus.summary.issue_count 'hidden path sentinel creates no invalid-local-root issue'
    Assert-OwnerTrue (@($bootstrapStatus.attentions | Where-Object code -EQ 'owner_history_gap').Count -eq 1) 'bootstrap history gap is not swallowed'
    $bootstrapJson = $bootstrapStatus | ConvertTo-Json -Depth 14 -Compress
    Assert-OwnerTrue (-not $bootstrapJson.Contains($baselineV3Clone)) 'compact status never emits a private local root'
    Assert-OwnerTrue (-not ($bootstrapJson -match '(?i)[A-Z]:\\')) 'compact status remains free of drive-qualified paths'

    $fixtureRemoteRows = @(
        $fixtureRemoteRows +
        [pscustomobject]@{ NameWithOwner='fixture-owner/new-private'; Visibility='PRIVATE'; DefaultBranch='main'; LocalPath='未发现本地 clone'; ExternalGovernance=$false }
    )
    $liveChange = Invoke-GitOwnerProvider `
        -Owner 'fixture-owner' -ExpectedRepository 'fixture-owner/index' `
        -RepoRoot $baselineV3Root `
        -IdentityResolver { param($Root) $fixtureIndexIdentity } `
        -RegistryReader { param($Root) $registryA } `
        -RemoteReader $fixtureRemoteReader
    Assert-OwnerEqual 'review_needed' $liveChange.domain_status 'new PRIVATE repository remains a real owner delta'
    Assert-OwnerTrue (@($liveChange.deltas | Where-Object {
        $_.kind -eq 'repo_added' -and $_.repo -eq 'fixture-owner/new-private'
    }).Count -eq 1) 'new PRIVATE identity is not filtered out of owner comparison'

    $changeMigration = Invoke-GitOwnerBaselineMigration `
        -Owner 'fixture-owner' -ExpectedRepository 'fixture-owner/index' `
        -RepoRoot $baselineV3Root `
        -IdentityResolver { param($Root) $fixtureIndexIdentity } `
        -RemoteReader $fixtureRemoteReader
    Assert-OwnerTrue (-not [bool]$changeMigration.history_gap) 'second v3 snapshot establishes continuous current+previous history'
    $transitionStatus = Invoke-GitOwnerProvider `
        -Owner 'fixture-owner' -ExpectedRepository 'fixture-owner/index' `
        -RepoRoot $baselineV3Root `
        -IdentityResolver { param($Root) $fixtureIndexIdentity } `
        -RegistryReader { param($Root) $registryA } `
        -RemoteReader $fixtureRemoteReader
    Assert-OwnerEqual 'review_needed' $transitionStatus.domain_status 'baseline advance retains its previous-to-current review delta'
    Assert-OwnerEqual 1 $transitionStatus.history.transition_delta_count 'transition history retains the added repository exactly once'

    [void](Invoke-GitOwnerBaselineMigration `
        -Owner 'fixture-owner' -ExpectedRepository 'fixture-owner/index' `
        -RepoRoot $baselineV3Root `
        -IdentityResolver { param($Root) $fixtureIndexIdentity } `
        -RemoteReader $fixtureRemoteReader)
    $stableStatus = Invoke-GitOwnerProvider `
        -Owner 'fixture-owner' -ExpectedRepository 'fixture-owner/index' `
        -RepoRoot $baselineV3Root `
        -IdentityResolver { param($Root) $fixtureIndexIdentity } `
        -RegistryReader { param($Root) $registryA } `
        -RemoteReader $fixtureRemoteReader
    Assert-OwnerEqual 'current' $stableStatus.domain_status 'next stable comparison clears a reviewed baseline transition'
    Assert-OwnerEqual 0 $stableStatus.history.transition_delta_count 'stable current+previous snapshots have no history delta'
}
finally {
    $baselineV3Full = [IO.Path]::GetFullPath($baselineV3Root)
    $tempFull = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($baselineV3Full.StartsWith($tempFull, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $baselineV3Full -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$entryGateRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'git-owner-entry-gate-' + [guid]::NewGuid().ToString('N')
)
$entryGitRoot = Join-Path $entryGateRoot '.git'
[void][IO.Directory]::CreateDirectory($entryGitRoot)
try {
    [IO.File]::WriteAllText(
        (Join-Path $entryGitRoot 'HEAD'),
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`n",
        [Text.Encoding]::ASCII
    )
    [IO.File]::WriteAllText(
        (Join-Path $entryGitRoot 'config'),
        "[remote `"origin`"]`n  url = https://github.com/attacker/github-local-index.git`n",
        [Text.UTF8Encoding]::new($false)
    )
    $entryArguments = @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',$providerPath,
        '-RepoRoot',$entryGateRoot,
        '-Owner','invalid owner',
        '-Json'
    )
    $entryMismatchJson = & pwsh @entryArguments
    Assert-OwnerEqual 0 $LASTEXITCODE 'entry mismatch blocks before missing index/registry or invalid gh owner can fail execution'
    $entryMismatch = $entryMismatchJson | ConvertFrom-Json -Depth 12
    Assert-OwnerEqual 'blocked' $entryMismatch.domain_status 'entry mismatch returns blocked from .git identity alone'
    Assert-OwnerTrue (@($entryMismatch.issues | Where-Object code -EQ 'index_repository_mismatch').Count -eq 1) 'entry mismatch exposes only its bounded identity issue'

    [IO.File]::WriteAllText(
        (Join-Path $entryGitRoot 'config'),
        "[core]`n  repositoryformatversion = 0`n",
        [Text.UTF8Encoding]::new($false)
    )
    $entryUnresolvedJson = & pwsh @entryArguments
    Assert-OwnerEqual 0 $LASTEXITCODE 'entry unresolved blocks before missing index/registry or invalid gh owner can fail execution'
    $entryUnresolved = $entryUnresolvedJson | ConvertFrom-Json -Depth 12
    Assert-OwnerEqual 'blocked' $entryUnresolved.domain_status 'entry unresolved returns blocked from .git identity alone'
    Assert-OwnerTrue (@($entryUnresolved.issues | Where-Object code -EQ 'index_repository_unresolved').Count -eq 1) 'entry unresolved exposes only its bounded identity issue'
}
finally {
    $entryGateFull = [IO.Path]::GetFullPath($entryGateRoot)
    $entryGateTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($entryGateFull.StartsWith(
        $entryGateTemp, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $entryGateFull -Recurse -Force
    }
}

$otherHeadIdentity = [pscustomobject]@{
    repository = $indexIdentity.repository
    default_branch = $indexIdentity.default_branch
    head = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
}
$otherHead = Invoke-GitOwnerStatus `
    -BaselineRows $baselineRows `
    -ObservedRows $observedRows `
    -IndexIdentity $otherHeadIdentity `
    -RegistryIdentity $registryA `
    -ObservedAt ([datetimeoffset]'2026-08-03T00:00:00Z')
Assert-OwnerEqual $current.fingerprint.value $otherHead.fingerprint.value 'unrelated index HEAD changes do not perturb the stable owner fingerprint'

$reordered = Invoke-GitOwnerStatus `
    -BaselineRows @($baselineRows[1], $baselineRows[0]) `
    -ObservedRows @($observedRows[1], $observedRows[0]) `
    -IndexIdentity $indexIdentity `
    -RegistryIdentity $registryB `
    -ObservedAt ([datetimeoffset]'2026-08-02T12:34:56Z')

Assert-OwnerEqual $current.fingerprint.value $reordered.fingerprint.value 'fingerprint excludes observation time and input order'

$changedRows = @(
    $observedRows[1],
    [pscustomobject]@{
        NameWithOwner = 'wlyaaaaa/github-local-index'
        Visibility = 'PUBLIC'
        DefaultBranch = 'trunk'
        LocalPath = 'E:\GitHub总索引'
    }
)
$changed = Invoke-GitOwnerStatus `
    -BaselineRows $baselineRows `
    -ObservedRows $changedRows `
    -IndexIdentity $indexIdentity `
    -RegistryIdentity $registryA `
    -ObservedAt ([datetimeoffset]'2026-08-01T00:00:00Z')

Assert-OwnerEqual 'completed' $changed.execution_status 'owner drift is not an execution failure'
Assert-OwnerEqual 'review_needed' $changed.domain_status 'stable owner drift requests review'
Assert-OwnerEqual 0 (Get-GitOwnerStatusProcessExitCode -Status $changed) 'review-needed domain status does not trigger process retry semantics'
Assert-OwnerTrue (@($changed.deltas | Where-Object kind -EQ 'default_branch_changed').Count -eq 1) 'default branch drift is reported as a stable fact delta'
Assert-OwnerTrue ($changed.fingerprint.value -ne $current.fingerprint.value) 'stable owner drift changes the fingerprint'

$blockedRows = @(
    [pscustomobject]@{
        NameWithOwner = 'wlyaaaaa/github-local-index'
        Visibility = 'UNVERIFIED'
        DefaultBranch = 'main'
        LocalPath = 'E:\GitHub总索引'
    }
)
$blocked = Invoke-GitOwnerStatus `
    -BaselineRows $baselineRows `
    -ObservedRows $blockedRows `
    -IndexIdentity $indexIdentity `
    -RegistryIdentity $registryA `
    -ObservedAt ([datetimeoffset]'2026-08-01T00:00:00Z')

Assert-OwnerEqual 'completed' $blocked.execution_status 'invalid owner facts remain a completed observation'
Assert-OwnerEqual 'blocked' $blocked.domain_status 'invalid owner facts fail the domain closed'
Assert-OwnerEqual 0 (Get-GitOwnerStatusProcessExitCode -Status $blocked) 'blocked domain status remains distinct from process failure'

$duplicateFactA = @(
    [pscustomobject]@{ NameWithOwner = 'wlyaaaaa/example'; Visibility = 'PRIVATE'; DefaultBranch = 'main'; LocalPath = '未发现本地 clone' },
    [pscustomobject]@{ NameWithOwner = 'wlyaaaaa/example'; Visibility = 'PRIVATE'; DefaultBranch = 'trunk'; LocalPath = '未发现本地 clone' }
)
$duplicateFactB = @($duplicateFactA[1], $duplicateFactA[0])
$duplicateStatusA = Invoke-GitOwnerStatus -BaselineRows @() -ObservedRows $duplicateFactA -IndexIdentity $indexIdentity -RegistryIdentity $registryA
$duplicateStatusB = Invoke-GitOwnerStatus -BaselineRows @() -ObservedRows $duplicateFactB -IndexIdentity $indexIdentity -RegistryIdentity $registryA
Assert-OwnerEqual 'blocked' $duplicateStatusA.domain_status 'duplicate repository facts fail the owner domain closed'
Assert-OwnerEqual $duplicateStatusA.fingerprint.value $duplicateStatusB.fingerprint.value 'blocked duplicate facts remain fingerprint-stable across input order'

$invalidRegistry = ConvertTo-GitOwnerGovernanceRegistryIdentity -Registry ([pscustomobject]@{
    schema = 'unexpected.registry.v1'
    entries = @()
    retentions = @()
})
$registryBlocked = Invoke-GitOwnerStatus `
    -BaselineRows $baselineRows `
    -ObservedRows $observedRows `
    -IndexIdentity $indexIdentity `
    -RegistryIdentity $invalidRegistry `
    -ObservedAt ([datetimeoffset]'2026-08-01T00:00:00Z')
Assert-OwnerEqual 'blocked' $registryBlocked.domain_status 'invalid governance registry blocks owner-currentness'
Assert-OwnerTrue (@($registryBlocked.issues | Where-Object code -EQ 'governance_registry_invalid').Count -eq 1) 'invalid registry is reported by a bounded public-safe code'

$remoteFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'git-owner-remote-fixture-' + [guid]::NewGuid().ToString('N')
)
[void][IO.Directory]::CreateDirectory($remoteFixtureRoot)
try {
    $missingCli = Get-GitOwnerRemoteRows -Owner 'wlyaaaaa' `
        -GhCommandPath (Join-Path $remoteFixtureRoot 'missing-gh.cmd')
    Assert-OwnerEqual 'github_cli_unavailable' $missingCli.reason 'missing gh executable is reported as provider unavailability'

    $transportCliPath = Join-Path $remoteFixtureRoot 'gh-transport.cmd'
    [IO.File]::WriteAllText(
        $transportCliPath,
        "@echo off`r`nexit /b 7`r`n",
        [Text.Encoding]::ASCII
    )
    $transportFailure = Get-GitOwnerRemoteRows -Owner 'wlyaaaaa' `
        -GhCommandPath $transportCliPath
    Assert-OwnerEqual 'remote_metadata_unavailable' $transportFailure.reason 'nonzero gh transport is a provider failure'

    $invalidJsonCliPath = Join-Path $remoteFixtureRoot 'gh-invalid-json.cmd'
    [IO.File]::WriteAllText(
        $invalidJsonCliPath,
        "@echo off`r`necho not-json`r`nexit /b 0`r`n",
        [Text.Encoding]::ASCII
    )
    $invalidJson = Get-GitOwnerRemoteRows -Owner 'wlyaaaaa' `
        -GhCommandPath $invalidJsonCliPath
    Assert-OwnerEqual 'remote_metadata_invalid' $invalidJson.reason 'syntactically invalid gh JSON is a provider failure'
}
finally {
    $fixtureFull = [IO.Path]::GetFullPath($remoteFixtureRoot)
    $tempFull = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($fixtureFull.StartsWith($tempFull, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $fixtureFull -Recurse -Force
    }
}

$unknown = New-GitOwnerUnavailableStatus `
    -Reason 'remote_metadata_unavailable' `
    -IndexIdentity $indexIdentity `
    -ObservedAt ([datetimeoffset]'2026-08-01T00:00:00Z')
Assert-OwnerEqual 'error' $unknown.execution_status 'remote transport failure is a provider execution error'
Assert-OwnerEqual 'unknown' $unknown.domain_status 'provider execution failure does not invent a domain conclusion'
Assert-OwnerEqual 2 (Get-GitOwnerStatusProcessExitCode -Status $unknown) 'remote transport failure requests scheduler retry'

foreach ($providerReason in @(
    'github_cli_unavailable',
    'remote_metadata_unavailable',
    'remote_metadata_invalid'
)) {
    $providerFailure = New-GitOwnerUnavailableStatus `
        -Reason $providerReason `
        -IndexIdentity $indexIdentity `
        -ObservedAt ([datetimeoffset]'2026-08-01T00:00:00Z')
    Assert-OwnerEqual 'error' $providerFailure.execution_status "$providerReason is classified as provider execution error"
    Assert-OwnerEqual 2 (Get-GitOwnerStatusProcessExitCode -Status $providerFailure) "$providerReason returns a nonzero provider exit"
}

$domainUnknown = New-GitOwnerUnavailableStatus `
    -Reason 'owner_evidence_incomplete' `
    -IndexIdentity $indexIdentity `
    -ObservedAt ([datetimeoffset]'2026-08-01T00:00:00Z')
Assert-OwnerEqual 'completed' $domainUnknown.execution_status 'valid evidence uncertainty remains a completed provider observation'
Assert-OwnerEqual 'unknown' $domainUnknown.domain_status 'valid evidence uncertainty remains domain unknown'
Assert-OwnerEqual 0 (Get-GitOwnerStatusProcessExitCode -Status $domainUnknown) 'valid domain unknown does not request provider retry'
$unknownWithHistory = Add-GitOwnerBaselineHistory -Status $domainUnknown -History ([pscustomobject]@{
    state = 'continuous'
    transition_delta_count = 1
})
Assert-OwnerEqual 'unknown' $unknownWithHistory.domain_status 'baseline transition review never upgrades incomplete evidence out of unknown'

$executionFailure = New-GitOwnerExecutionFailure -Reason 'provider_execution_failed' -ObservedAt ([datetimeoffset]'2026-08-01T00:00:00Z')
Assert-OwnerEqual 'error' $executionFailure.execution_status 'unexpected provider failure is an execution error'
Assert-OwnerEqual 2 (Get-GitOwnerStatusProcessExitCode -Status $executionFailure) 'only execution failure returns a nonzero process exit'
Assert-OwnerTrue ($executionFailure.fingerprint.value -match '^sha256:[0-9a-f]{64}$') 'execution failures retain a bounded stable fingerprint for consumers'

$currentJson = $current | ConvertTo-Json -Depth 12 -Compress
Assert-OwnerTrue (-not $currentJson.Contains($externalPathFixture)) 'external-governance local paths are excluded from output'
Assert-OwnerTrue (-not ($currentJson -match '(?i)dirty|ahead|behind|taskname')) 'task and worktree dynamics are absent from compact output'

$providerSource = Get-Content -LiteralPath $providerPath -Raw -Encoding utf8
Assert-OwnerTrue (-not ($providerSource -match '(?i)Set-Content|Add-Content|Out-File|WriteAllText|WriteAllBytes|Move-Item|Remove-Item|New-Item')) 'provider source contains no filesystem mutation primitive'
Assert-OwnerTrue (-not ($providerSource -match 'Update-GitHubIndex|Test-GitHubLocalIndexConsistency|ScheduledTask|04_计划任务')) 'provider does not reuse write-capable refresh or task-health paths'
Assert-OwnerTrue (-not ($providerSource -match '(?i)[''"][a-z]:\\')) 'provider does not embed any Windows local root'

if ($script:failures -gt 0) {
    throw "$script:failures Git owner provider test(s) failed"
}

Write-Host 'Git owner provider tests passed.'
