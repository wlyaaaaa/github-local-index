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

$unknown = New-GitOwnerUnavailableStatus `
    -Reason 'remote_metadata_unavailable' `
    -IndexIdentity $indexIdentity `
    -ObservedAt ([datetimeoffset]'2026-08-01T00:00:00Z')
Assert-OwnerEqual 'completed' $unknown.execution_status 'source unavailability is a completed provider execution'
Assert-OwnerEqual 'unknown' $unknown.domain_status 'source unavailability is explicit domain uncertainty'
Assert-OwnerEqual 0 (Get-GitOwnerStatusProcessExitCode -Status $unknown) 'domain uncertainty does not request scheduler retry'

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
