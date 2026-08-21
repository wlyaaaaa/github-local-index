#requires -Version 7.0

[CmdletBinding()]
param(
    [string] $Owner = 'wlyaaaaa',
    [string] $ExpectedRepository = 'wlyaaaaa/github-local-index',
    [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [switch] $Json
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

function ConvertTo-GitOwnerSafeReason {
    param(
        [AllowNull()] [string] $Reason,
        [string] $Fallback = 'owner_status_unavailable'
    )

    $value = ([string]$Reason).Trim().ToLowerInvariant()
    if ($value -notmatch '^[a-z0-9_]{1,80}$') {
        return $Fallback
    }

    return $value
}

function ConvertTo-GitOwnerCanonicalRoot {
    param([AllowNull()] [string] $Path)

    $value = ([string]$Path).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    if ($value -in @('未发现本地 clone', '外部治理（不读取本地路径）', '专门 owner 治理（不公开本地路径）')) {
        return $null
    }

    $value = $value.Replace('/', '\').TrimEnd([char[]]'\/')
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    return $value.ToLowerInvariant()
}

function Test-GitOwnerExternalGovernanceRow {
    param([Parameter(Mandatory = $true)] [object] $Row)

    $repo = ([string]$Row.NameWithOwner).Trim().ToLowerInvariant()
    if ($repo -eq 'wlyaaaaa/personalos') {
        return $true
    }

    $property = $Row.PSObject.Properties['ExternalGovernance']
    if ($null -ne $property -and [bool]$property.Value) {
        return $true
    }

    $localPath = [string]$Row.LocalPath
    return $localPath -in @('外部治理（不读取本地路径）', '专门 owner 治理（不公开本地路径）')
}

function ConvertTo-GitOwnerFactSet {
    param([AllowEmptyCollection()] [object[]] $Rows = @())

    $candidates = [System.Collections.Generic.List[object]]::new()
    $issues = [System.Collections.Generic.List[object]]::new()

    foreach ($row in @($Rows)) {
        if ($null -eq $row) {
            $issues.Add([pscustomobject][ordered]@{ code = 'null_row'; repo = $null })
            continue
        }

        $repo = ([string]$row.NameWithOwner).Trim().ToLowerInvariant()
        if ($repo -notmatch '^[^/\s]+/[^/\s]+$') {
            $issues.Add([pscustomobject][ordered]@{ code = 'invalid_repo'; repo = $null })
            continue
        }

        $visibility = ([string]$row.Visibility).Trim().ToUpperInvariant()
        if ($visibility -notin @('PUBLIC', 'PRIVATE', 'INTERNAL')) {
            $issues.Add([pscustomobject][ordered]@{ code = 'invalid_visibility'; repo = $repo })
        }

        $defaultBranch = ([string]$row.DefaultBranch).Trim()
        if ([string]::IsNullOrWhiteSpace($defaultBranch)) {
            $issues.Add([pscustomobject][ordered]@{ code = 'missing_default_branch'; repo = $repo })
        }

        $externalGovernance = Test-GitOwnerExternalGovernanceRow -Row $row
        $roots = @()
        if (-not $externalGovernance) {
            $roots = @(
                ([string]$row.LocalPath -split '<br>') |
                    ForEach-Object { ConvertTo-GitOwnerCanonicalRoot -Path $_ } |
                    Where-Object { $null -ne $_ } |
                    Sort-Object -Unique
            )

            foreach ($root in $roots) {
                if (-not [System.IO.Path]::IsPathFullyQualified($root)) {
                    $issues.Add([pscustomobject][ordered]@{ code = 'invalid_local_root'; repo = $repo })
                }
            }
        }

        $candidates.Add([pscustomobject][ordered]@{
            repo = $repo
            visibility = $visibility
            default_branch = $defaultBranch
            external_governance = [bool]$externalGovernance
            local_roots = @($roots)
        })
    }

    $facts = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $sortedCandidates = @(
        $candidates |
            Sort-Object repo, visibility, default_branch, external_governance, @{ Expression = { $_.local_roots -join "`u{001f}" } }
    )
    foreach ($candidate in $sortedCandidates) {
        if (-not $seen.Add([string]$candidate.repo)) {
            $issues.Add([pscustomobject][ordered]@{ code = 'duplicate_repo'; repo = [string]$candidate.repo })
            continue
        }
        $facts.Add($candidate)
    }

    return [pscustomobject][ordered]@{
        facts = @($facts)
        issues = @($issues | Sort-Object repo, code)
    }
}

function Compare-GitOwnerFactSets {
    param(
        [AllowEmptyCollection()] [object[]] $BaselineFacts = @(),
        [AllowEmptyCollection()] [object[]] $ObservedFacts = @()
    )

    $baselineByRepo = @{}
    foreach ($fact in @($BaselineFacts)) {
        $baselineByRepo[[string]$fact.repo] = $fact
    }

    $observedByRepo = @{}
    foreach ($fact in @($ObservedFacts)) {
        $observedByRepo[[string]$fact.repo] = $fact
    }

    $deltas = [System.Collections.Generic.List[object]]::new()
    $repos = @($baselineByRepo.Keys + $observedByRepo.Keys | Sort-Object -Unique)
    foreach ($repo in $repos) {
        $baseline = $baselineByRepo[$repo]
        $observed = $observedByRepo[$repo]
        if ($null -eq $baseline) {
            $deltas.Add([pscustomobject][ordered]@{
                kind = 'repo_added'
                repo = $repo
                field = 'repository'
                expected = $null
                actual = 'present'
            })
            continue
        }
        if ($null -eq $observed) {
            $deltas.Add([pscustomobject][ordered]@{
                kind = 'repo_removed'
                repo = $repo
                field = 'repository'
                expected = 'present'
                actual = $null
            })
            continue
        }

        foreach ($field in @('visibility', 'default_branch', 'external_governance')) {
            if ($baseline.$field -ne $observed.$field) {
                $deltas.Add([pscustomobject][ordered]@{
                    kind = "${field}_changed"
                    repo = $repo
                    field = $field
                    expected = $baseline.$field
                    actual = $observed.$field
                })
            }
        }

        $baselineRoots = @($baseline.local_roots)
        $observedRoots = @($observed.local_roots)
        if (($baselineRoots -join "`u{001f}") -ne ($observedRoots -join "`u{001f}")) {
            $deltas.Add([pscustomobject][ordered]@{
                kind = 'local_roots_changed'
                repo = $repo
                field = 'local_roots'
                expected = $baselineRoots
                actual = $observedRoots
            })
        }
    }

    return @($deltas | Sort-Object repo, kind, field)
}

function ConvertTo-GitOwnerCanonicalIndexIdentity {
    param([AllowNull()] [object] $IndexIdentity)

    if ($null -eq $IndexIdentity) {
        return [pscustomobject][ordered]@{
            repository = $null
            default_branch = $null
            head = $null
        }
    }

    $repository = ([string]$IndexIdentity.repository).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($repository)) { $repository = $null }
    $defaultBranch = ([string]$IndexIdentity.default_branch).Trim()
    if ([string]::IsNullOrWhiteSpace($defaultBranch)) { $defaultBranch = $null }
    $head = ([string]$IndexIdentity.head).Trim().ToLowerInvariant()
    if ($head -notmatch '^[0-9a-f]{40}$') { $head = $null }

    return [pscustomobject][ordered]@{
        repository = $repository
        default_branch = $defaultBranch
        head = $head
    }
}

function Get-GitOwnerIndexIdentityIssueCode {
    param(
        [AllowNull()] [object] $IndexIdentity,
        [string] $ExpectedRepository = 'wlyaaaaa/github-local-index'
    )

    $identity = ConvertTo-GitOwnerCanonicalIndexIdentity `
        -IndexIdentity $IndexIdentity
    $expectedRepositoryValue = ([string]$ExpectedRepository).Trim().ToLowerInvariant()
    if ($expectedRepositoryValue -notmatch
        '^[a-z0-9_.-]+/[a-z0-9_.-]+$') {
        return 'expected_repository_invalid'
    }
    if ([string]::IsNullOrWhiteSpace([string]$identity.repository)) {
        return 'index_repository_unresolved'
    }
    if ([string]$identity.repository -cne $expectedRepositoryValue) {
        return 'index_repository_mismatch'
    }
    return $null
}

function ConvertTo-GitOwnerFingerprintIndexIdentity {
    param([AllowNull()] [object] $IndexIdentity)

    $identity = ConvertTo-GitOwnerCanonicalIndexIdentity -IndexIdentity $IndexIdentity
    return [pscustomobject][ordered]@{
        repository = $identity.repository
        default_branch = $identity.default_branch
    }
}

function New-GitOwnerProvenance {
    param([AllowNull()] [object] $IndexIdentity)

    $identity = ConvertTo-GitOwnerCanonicalIndexIdentity -IndexIdentity $IndexIdentity
    return [pscustomobject][ordered]@{
        index_repository = $identity.repository
        index_default_branch = $identity.default_branch
        index_head = $identity.head
    }
}

function Get-GitOwnerSha256 {
    param([Parameter(Mandatory = $true)] [string] $Text)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return 'sha256:' + [System.Convert]::ToHexString($hash).ToLowerInvariant()
}

function ConvertTo-GitOwnerGovernanceRegistryIdentity {
    param([AllowNull()] [object] $Registry)

    $valid = $null -ne $Registry
    $schema = if ($null -eq $Registry) { $null } else { ([string]$Registry.schema).Trim() }
    if ($schema -ne 'github-local-index.git-artifact-governance.v1') {
        $valid = $false
    }
    if ($null -eq $Registry -or
        $null -eq $Registry.PSObject.Properties['schema'] -or
        $null -eq $Registry.PSObject.Properties['entries'] -or
        $null -eq $Registry.PSObject.Properties['retentions']) {
        $valid = $false
    }

    $entries = [System.Collections.Generic.List[object]]::new()
    $seenRefs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($null -ne $Registry) {
        foreach ($entry in @($Registry.entries)) {
            $repo = ([string]$entry.repo).Trim().ToLowerInvariant()
            $entryOwner = ([string]$entry.owner).Trim()
            $hasRefs = $null -ne $entry.PSObject.Properties['refs'] -and @($entry.refs).Count -gt 0
            if ($repo -notmatch '^[a-z0-9_.-]+/[a-z0-9_.-]+$' -or [string]::IsNullOrWhiteSpace($entryOwner) -or -not $hasRefs) {
                $valid = $false
            }

            $refs = [System.Collections.Generic.List[string]]::new()
            foreach ($ref in @($entry.refs)) {
                $logicalRef = ([string]$ref).Trim() -replace '^refs/heads/', '' -replace '^origin/', ''
                $logicalRef = $logicalRef.ToLowerInvariant()
                if ([string]::IsNullOrWhiteSpace($logicalRef) -or -not $seenRefs.Add("$repo|$logicalRef")) {
                    $valid = $false
                }
                if (-not [string]::IsNullOrWhiteSpace($logicalRef)) {
                    $refs.Add($logicalRef)
                }
            }
            $entries.Add([pscustomobject][ordered]@{
                repo = $repo
                owner = $entryOwner
                refs = @($refs | Sort-Object -Unique)
            })
        }
    }

    $repositoryOverrides = [System.Collections.Generic.List[object]]::new()
    $seenRepositoryOverrides = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($null -ne $Registry -and $null -ne $Registry.PSObject.Properties['repository_overrides']) {
        foreach ($entry in @($Registry.repository_overrides)) {
            $repo = ([string]$entry.repo).Trim().ToLowerInvariant()
            $policy = ([string]$entry.policy).Trim().ToLowerInvariant()
            $entryOwner = ([string]$entry.owner).Trim()
            $purpose = ([string]$entry.purpose).Trim()
            $exitCondition = ([string]$entry.exit_condition).Trim()
            if ($repo -notmatch '^[a-z0-9_.-]+/[a-z0-9_.-]+$' -or
                $policy -ne 'frozen_history' -or
                [string]::IsNullOrWhiteSpace($entryOwner) -or
                [string]::IsNullOrWhiteSpace($purpose) -or
                [string]::IsNullOrWhiteSpace($exitCondition) -or
                -not $seenRepositoryOverrides.Add($repo)) {
                $valid = $false
            }
            $repositoryOverrides.Add([pscustomobject][ordered]@{
                repo = $repo
                policy = $policy
                owner = $entryOwner
                purpose = $purpose
                exit_condition = $exitCondition
            })
        }
    }

    $retentions = [System.Collections.Generic.List[object]]::new()
    $retentionKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($null -ne $Registry) {
        foreach ($retention in @($Registry.retentions)) {
            $repo = ([string]$retention.repo).Trim().ToLowerInvariant()
            $rawPath = ([string]$retention.path).Trim()
            $path = ConvertTo-GitOwnerCanonicalRoot -Path $rawPath
            $head = ([string]$retention.head).Trim().ToLowerInvariant()
            $disposition = ([string]$retention.disposition).Trim().ToLowerInvariant()
            $retentionOwner = ([string]$retention.owner).Trim()
            $purpose = ([string]$retention.purpose).Trim()
            $exitCondition = ([string]$retention.exit_condition).Trim()
            if ($repo -notmatch '^[a-z0-9_.-]+/[a-z0-9_.-]+$' -or
                -not [System.IO.Path]::IsPathRooted($rawPath) -or
                $head -notmatch '^[0-9a-f]{40}$' -or
                $disposition -ne 'retain' -or
                [string]::IsNullOrWhiteSpace($retentionOwner) -or
                [string]::IsNullOrWhiteSpace($purpose) -or
                [string]::IsNullOrWhiteSpace($exitCondition)) {
                $valid = $false
            }
            $key = "$repo`u{001f}$path`u{001f}$head"
            if (-not $retentionKeys.Add($key)) { $valid = $false }
            $retentions.Add([pscustomobject][ordered]@{
                repo = $repo
                path = $path
                head = $head
                disposition = $disposition
                owner = $retentionOwner
                purpose = $purpose
                exit_condition = $exitCondition
            })
        }
    }

    $canonical = [pscustomobject][ordered]@{
        schema = $schema
        valid = [bool]$valid
        entries = @($entries | Sort-Object repo, owner, @{ Expression = { $_.refs -join "`u{001f}" } })
        repository_overrides = @($repositoryOverrides | Sort-Object repo, policy, owner, purpose, exit_condition)
        retentions = @($retentions | Sort-Object repo, path, head, disposition, owner, purpose, exit_condition)
    }
    $canonicalJson = $canonical | ConvertTo-Json -Depth 10 -Compress

    return [pscustomobject][ordered]@{
        schema = $schema
        valid = [bool]$valid
        fingerprint = Get-GitOwnerSha256 -Text $canonicalJson
    }
}

function Read-GitOwnerGovernanceRegistryIdentity {
    param([Parameter(Mandatory = $true)] [string] $RepoRoot)

    $registryPath = Join-Path $RepoRoot 'config/git-artifact-governance.json'
    if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
        return ConvertTo-GitOwnerGovernanceRegistryIdentity -Registry $null
    }

    try {
        $registry = Get-Content -LiteralPath $registryPath -Raw -Encoding utf8 | ConvertFrom-Json
        return ConvertTo-GitOwnerGovernanceRegistryIdentity -Registry $registry
    }
    catch {
        return ConvertTo-GitOwnerGovernanceRegistryIdentity -Registry $null
    }
}

function ConvertTo-GitOwnerCanonicalRegistryIdentity {
    param([AllowNull()] [object] $RegistryIdentity)

    if ($null -eq $RegistryIdentity) {
        return [pscustomobject][ordered]@{
            schema = $null
            valid = $null
            fingerprint = $null
        }
    }

    $fingerprint = ([string]$RegistryIdentity.fingerprint).Trim().ToLowerInvariant()
    if ($fingerprint -notmatch '^sha256:[0-9a-f]{64}$') { $fingerprint = $null }
    return [pscustomobject][ordered]@{
        schema = ([string]$RegistryIdentity.schema).Trim()
        valid = [bool]$RegistryIdentity.valid
        fingerprint = $fingerprint
    }
}

function Get-GitOwnerFingerprint {
    param(
        [AllowEmptyCollection()] [object[]] $BaselineFacts = @(),
        [AllowEmptyCollection()] [object[]] $ObservedFacts = @(),
        [AllowEmptyCollection()] [object[]] $Issues = @(),
        [AllowNull()] [object] $IndexIdentity,
        [AllowNull()] [object] $RegistryIdentity
    )

    $canonicalIssues = @(
        $Issues |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    code = [string]$_.code
                    repo = if ($null -eq $_.repo) { $null } else { [string]$_.repo }
                }
            } |
            Sort-Object repo, code
    )
    $canonical = [pscustomobject][ordered]@{
        schema = 'github-local-index.owner-fingerprint.v1'
        baseline = @($BaselineFacts | Sort-Object repo)
        observed = @($ObservedFacts | Sort-Object repo)
        issues = $canonicalIssues
        index_identity = ConvertTo-GitOwnerFingerprintIndexIdentity -IndexIdentity $IndexIdentity
        registry_identity = ConvertTo-GitOwnerCanonicalRegistryIdentity -RegistryIdentity $RegistryIdentity
    }
    $canonicalJson = $canonical | ConvertTo-Json -Depth 10 -Compress

    return [pscustomobject][ordered]@{
        schema = 'github-local-index.owner-fingerprint.v1'
        algorithm = 'sha256'
        value = Get-GitOwnerSha256 -Text $canonicalJson
    }
}

function Invoke-GitOwnerStatus {
    param(
        [AllowEmptyCollection()] [object[]] $BaselineRows = @(),
        [AllowEmptyCollection()] [object[]] $ObservedRows = @(),
        [AllowNull()] [object] $IndexIdentity,
        [AllowNull()] [object] $RegistryIdentity,
        [string] $ExpectedRepository = 'wlyaaaaa/github-local-index',
        [datetimeoffset] $ObservedAt = [datetimeoffset]::UtcNow
    )

    $baseline = ConvertTo-GitOwnerFactSet -Rows $BaselineRows
    $observed = ConvertTo-GitOwnerFactSet -Rows $ObservedRows
    $issues = @($baseline.issues) + @($observed.issues)
    $registry = ConvertTo-GitOwnerCanonicalRegistryIdentity -RegistryIdentity $RegistryIdentity
    if ($null -ne $registry.valid -and -not [bool]$registry.valid) {
        $issues += [pscustomobject][ordered]@{ code = 'governance_registry_invalid'; repo = $null }
    }
    $identity = ConvertTo-GitOwnerCanonicalIndexIdentity -IndexIdentity $IndexIdentity
    $identityIssueCode = Get-GitOwnerIndexIdentityIssueCode `
        -IndexIdentity $identity -ExpectedRepository $ExpectedRepository
    if (-not [string]::IsNullOrWhiteSpace($identityIssueCode)) {
        $issueRepository = if ($identityIssueCode -ceq
            'index_repository_mismatch') {
            [string]$identity.repository
        } else { $null }
        $issues += [pscustomobject][ordered]@{
            code = $identityIssueCode
            repo = $issueRepository
        }
    }
    $deltas = @(Compare-GitOwnerFactSets -BaselineFacts $baseline.facts -ObservedFacts $observed.facts)
    $domainStatus = if ($issues.Count -gt 0) {
        'blocked'
    }
    elseif ($deltas.Count -gt 0) {
        'review_needed'
    }
    else {
        'current'
    }
    $fingerprint = Get-GitOwnerFingerprint `
        -BaselineFacts $baseline.facts `
        -ObservedFacts $observed.facts `
        -Issues $issues `
        -IndexIdentity $identity `
        -RegistryIdentity $registry

    $blockingScopes = @()
    switch ($domainStatus) {
        'review_needed' { $blockingScopes = @('git_owner_review') }
        'blocked' { $blockingScopes = @('git_owner_validity') }
    }

    return [pscustomobject][ordered]@{
        schema = 'github-local-index.owner-status.v1'
        owner = $identity.repository
        scope = 'stable_git_owner_facts'
        execution_status = 'completed'
        domain_status = $domainStatus
        observed_at = $ObservedAt.UtcDateTime.ToString('o')
        zero_write = $true
        fetch_performed = $false
        fingerprint = $fingerprint
        provenance = New-GitOwnerProvenance -IndexIdentity $identity
        registry = $registry
        summary = [pscustomobject][ordered]@{
            baseline_repositories = @($baseline.facts).Count
            observed_repositories = @($observed.facts).Count
            delta_count = $deltas.Count
            issue_count = $issues.Count
        }
        deltas = $deltas
        issues = @($issues | Sort-Object repo, code)
        blocking_scopes = $blockingScopes
    }
}

function New-GitOwnerUnavailableStatus {
    param(
        [string] $Reason = 'owner_source_unavailable',
        [AllowNull()] [object] $IndexIdentity,
        [AllowNull()] [object] $RegistryIdentity,
        [datetimeoffset] $ObservedAt = [datetimeoffset]::UtcNow
    )

    $safeReason = ConvertTo-GitOwnerSafeReason -Reason $Reason
    if ($safeReason -in @(
        'github_cli_unavailable',
        'remote_metadata_unavailable',
        'remote_metadata_invalid',
        'invalid_owner'
    )) {
        return New-GitOwnerExecutionFailure -Reason $safeReason -ObservedAt $ObservedAt
    }
    $identity = ConvertTo-GitOwnerCanonicalIndexIdentity -IndexIdentity $IndexIdentity
    $registry = ConvertTo-GitOwnerCanonicalRegistryIdentity -RegistryIdentity $RegistryIdentity
    $canonical = [pscustomobject][ordered]@{
        schema = 'github-local-index.owner-fingerprint.v1'
        availability = 'unknown'
        reason = $safeReason
        index_identity = ConvertTo-GitOwnerFingerprintIndexIdentity -IndexIdentity $identity
        registry_identity = $registry
    } | ConvertTo-Json -Depth 6 -Compress

    $domainStatus = if ($null -ne $registry.valid -and -not [bool]$registry.valid) { 'blocked' } else { 'unknown' }
    $issueCode = if ($domainStatus -eq 'blocked') { 'governance_registry_invalid' } else { $safeReason }
    $blockingScope = if ($domainStatus -eq 'blocked') { 'git_owner_validity' } else { 'git_owner_freshness' }

    return [pscustomobject][ordered]@{
        schema = 'github-local-index.owner-status.v1'
        owner = $identity.repository
        scope = 'stable_git_owner_facts'
        execution_status = 'completed'
        domain_status = $domainStatus
        observed_at = $ObservedAt.UtcDateTime.ToString('o')
        zero_write = $true
        fetch_performed = $false
        fingerprint = [pscustomobject][ordered]@{
            schema = 'github-local-index.owner-fingerprint.v1'
            algorithm = 'sha256'
            value = Get-GitOwnerSha256 -Text $canonical
        }
        provenance = New-GitOwnerProvenance -IndexIdentity $identity
        registry = $registry
        summary = [pscustomobject][ordered]@{
            baseline_repositories = 0
            observed_repositories = 0
            delta_count = 0
            issue_count = 1
        }
        deltas = @()
        issues = @([pscustomobject][ordered]@{ code = $issueCode; repo = $null })
        blocking_scopes = @($blockingScope)
    }
}

function New-GitOwnerExecutionFailure {
    param(
        [string] $Reason = 'provider_execution_failed',
        [datetimeoffset] $ObservedAt = [datetimeoffset]::UtcNow
    )

    $safeReason = ConvertTo-GitOwnerSafeReason -Reason $Reason -Fallback 'provider_execution_failed'
    $canonical = [pscustomobject][ordered]@{
        schema = 'github-local-index.owner-fingerprint.v1'
        execution = 'error'
        reason = $safeReason
    } | ConvertTo-Json -Compress
    return [pscustomobject][ordered]@{
        schema = 'github-local-index.owner-status.v1'
        owner = $null
        scope = 'stable_git_owner_facts'
        execution_status = 'error'
        domain_status = 'unknown'
        observed_at = $ObservedAt.UtcDateTime.ToString('o')
        zero_write = $true
        fetch_performed = $false
        fingerprint = [pscustomobject][ordered]@{
            schema = 'github-local-index.owner-fingerprint.v1'
            algorithm = 'sha256'
            value = Get-GitOwnerSha256 -Text $canonical
        }
        provenance = $null
        registry = $null
        summary = [pscustomobject][ordered]@{
            baseline_repositories = 0
            observed_repositories = 0
            delta_count = 0
            issue_count = 1
        }
        deltas = @()
        issues = @([pscustomobject][ordered]@{ code = $safeReason; repo = $null })
        blocking_scopes = @('git_owner_provider_execution')
    }
}

function Get-GitOwnerStatusProcessExitCode {
    param([Parameter(Mandatory = $true)] [object] $Status)

    if ([string]$Status.execution_status -eq 'completed') {
        return 0
    }

    return 2
}

function Read-GitOwnerIndexRows {
    param([Parameter(Mandatory = $true)] [string] $RepoRoot)

    $indexPath = Join-Path $RepoRoot '01_仓库索引/GitHub仓库索引.md'
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
        throw 'Git owner index is unavailable.'
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($line in Get-Content -LiteralPath $indexPath -Encoding utf8) {
        if ($line -notmatch '^\|') { continue }
        $cells = @($line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() })
        if ($cells.Count -lt 4) { continue }
        if ($cells[0] -in @('GitHub 仓库', '---')) { continue }
        if ($cells[0] -notmatch '^[^/\s]+/[^/\s]+$') { continue }

        $externalGovernance = $cells[3] -in @('外部治理（不读取本地路径）', '专门 owner 治理（不公开本地路径）')
        $rows.Add([pscustomobject][ordered]@{
            NameWithOwner = $cells[0]
            Visibility = $cells[1]
            DefaultBranch = $cells[2]
            LocalPath = $cells[3]
            ExternalGovernance = $externalGovernance
        })
    }

    if ($rows.Count -eq 0) {
        throw 'Git owner index contains no repository facts.'
    }

    return @($rows)
}

function ConvertTo-GitOwnerRepoSlug {
    param([AllowNull()] [string] $RemoteUrl)

    $value = ([string]$RemoteUrl).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    $value = $value -replace '\.git/?$', ''

    if ($value -match '^https?://github\.com/(?<slug>[^/]+/[^/]+)/?$') {
        return $Matches.slug.ToLowerInvariant()
    }
    if ($value -match '^git@github\.com:(?<slug>[^/]+/[^/]+)$') {
        return $Matches.slug.ToLowerInvariant()
    }
    if ($value -match '^ssh://git@github\.com/(?<slug>[^/]+/[^/]+)$') {
        return $Matches.slug.ToLowerInvariant()
    }

    return $null
}

function Resolve-GitOwnerGitDirectory {
    param([Parameter(Mandatory = $true)] [string] $RepositoryRoot)

    $dotGit = Join-Path $RepositoryRoot '.git'
    if (Test-Path -LiteralPath $dotGit -PathType Container) {
        return $dotGit
    }
    if (-not (Test-Path -LiteralPath $dotGit -PathType Leaf)) {
        return $null
    }

    $pointer = (Get-Content -LiteralPath $dotGit -TotalCount 1 -Encoding utf8).Trim()
    if ($pointer -notmatch '^gitdir:\s*(?<path>.+)$') {
        return $null
    }

    $gitDirectory = $Matches.path.Trim()
    if (-not [System.IO.Path]::IsPathFullyQualified($gitDirectory)) {
        $gitDirectory = Join-Path $RepositoryRoot $gitDirectory
    }
    if (-not (Test-Path -LiteralPath $gitDirectory -PathType Container)) {
        return $null
    }

    return [System.IO.Path]::GetFullPath($gitDirectory)
}

function Resolve-GitOwnerCommonDirectory {
    param([Parameter(Mandatory = $true)] [string] $GitDirectory)

    $commonPointer = Join-Path $GitDirectory 'commondir'
    if (-not (Test-Path -LiteralPath $commonPointer -PathType Leaf)) {
        return $GitDirectory
    }

    $commonDirectory = (Get-Content -LiteralPath $commonPointer -TotalCount 1 -Encoding utf8).Trim()
    if (-not [System.IO.Path]::IsPathFullyQualified($commonDirectory)) {
        $commonDirectory = Join-Path $GitDirectory $commonDirectory
    }
    if (-not (Test-Path -LiteralPath $commonDirectory -PathType Container)) {
        return $null
    }

    return [System.IO.Path]::GetFullPath($commonDirectory)
}

function Get-GitOwnerRootRemoteSlug {
    param([Parameter(Mandatory = $true)] [string] $RepositoryRoot)

    try {
        $gitDirectory = Resolve-GitOwnerGitDirectory -RepositoryRoot $RepositoryRoot
        if ([string]::IsNullOrWhiteSpace($gitDirectory)) { return $null }
        $commonDirectory = Resolve-GitOwnerCommonDirectory -GitDirectory $gitDirectory
        if ([string]::IsNullOrWhiteSpace($commonDirectory)) { return $null }
        $configPath = Join-Path $commonDirectory 'config'
        if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return $null }

        $config = Get-Content -LiteralPath $configPath -Raw -Encoding utf8
        $origin = [regex]::Match($config, '(?ms)^\[remote\s+"origin"\]\s*(?<body>.*?)(?=^\[|\z)')
        if (-not $origin.Success) { return $null }
        $url = [regex]::Match($origin.Groups['body'].Value, '(?m)^\s*url\s*=\s*(?<url>.+?)\s*$')
        if (-not $url.Success) { return $null }
        return ConvertTo-GitOwnerRepoSlug -RemoteUrl $url.Groups['url'].Value
    }
    catch {
        return $null
    }
}

function Get-GitOwnerVerifiedLocalRoots {
    param([Parameter(Mandatory = $true)] [object] $Fact)

    if ([bool]$Fact.external_governance) {
        return @()
    }

    $verified = foreach ($root in @($Fact.local_roots)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $remoteSlug = Get-GitOwnerRootRemoteSlug -RepositoryRoot $root
        if ($remoteSlug -eq [string]$Fact.repo) {
            $root
        }
    }

    return @($verified | Sort-Object -Unique)
}

function Get-GitOwnerRemoteRows {
    param(
        [Parameter(Mandatory = $true)] [string] $Owner,
        [AllowEmptyString()] [string] $GhCommandPath = ''
    )

    if ($Owner -notmatch '^[a-zA-Z0-9_.-]+$') {
        return [pscustomobject][ordered]@{ available = $false; reason = 'invalid_owner'; rows = @() }
    }

    $ghSource = $null
    if (-not [string]::IsNullOrWhiteSpace($GhCommandPath)) {
        $candidateGhPath = [IO.Path]::GetFullPath($GhCommandPath)
        if (Test-Path -LiteralPath $candidateGhPath -PathType Leaf) {
            $ghSource = $candidateGhPath
        }
    }
    else {
        $gh = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue
        if ($null -ne $gh) { $ghSource = $gh.Source }
    }
    if ([string]::IsNullOrWhiteSpace($ghSource)) {
        return [pscustomobject][ordered]@{
            available = $false
            reason = 'github_cli_unavailable'
            rows = @()
        }
    }

    $stdout = @(& $ghSource repo list $Owner --limit 1000 --json nameWithOwner,visibility,defaultBranchRef 2>$null)
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject][ordered]@{ available = $false; reason = 'remote_metadata_unavailable'; rows = @() }
    }

    $remoteJson = ($stdout -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($remoteJson)) {
        return [pscustomobject][ordered]@{ available = $false; reason = 'remote_metadata_invalid'; rows = @() }
    }

    try {
        $parsedMetadata = ConvertFrom-Json -InputObject $remoteJson -NoEnumerate
        if ($parsedMetadata -isnot [System.Array]) {
            throw 'remote metadata root is not an array'
        }
        $metadata = @($parsedMetadata)
    }
    catch {
        return [pscustomobject][ordered]@{ available = $false; reason = 'remote_metadata_invalid'; rows = @() }
    }

    $rows = foreach ($repository in $metadata) {
        [pscustomobject][ordered]@{
            NameWithOwner = [string]$repository.nameWithOwner
            Visibility = [string]$repository.visibility
            DefaultBranch = [string]$repository.defaultBranchRef.name
            LocalPath = '未发现本地 clone'
            ExternalGovernance = $false
        }
    }

    return [pscustomobject][ordered]@{ available = $true; reason = $null; rows = @($rows) }
}

function Merge-GitOwnerRemoteAndLocalFacts {
    param(
        [AllowEmptyCollection()] [object[]] $BaselineRows = @(),
        [AllowEmptyCollection()] [object[]] $RemoteRows = @()
    )

    $baseline = ConvertTo-GitOwnerFactSet -Rows $BaselineRows
    $baselineByRepo = @{}
    foreach ($fact in @($baseline.facts)) {
        $baselineByRepo[[string]$fact.repo] = $fact
    }

    $observed = foreach ($remote in @($RemoteRows)) {
        $repo = ([string]$remote.NameWithOwner).Trim().ToLowerInvariant()
        $baselineFact = $baselineByRepo[$repo]
        $externalGovernance = $null -ne $baselineFact -and [bool]$baselineFact.external_governance
        $roots = if ($null -eq $baselineFact -or $externalGovernance) {
            @()
        }
        else {
            @(Get-GitOwnerVerifiedLocalRoots -Fact $baselineFact)
        }

        [pscustomobject][ordered]@{
            NameWithOwner = $remote.NameWithOwner
            Visibility = $remote.Visibility
            DefaultBranch = $remote.DefaultBranch
            LocalPath = if ($externalGovernance) { '外部治理（不读取本地路径）' } elseif ($roots.Count -gt 0) { $roots -join '<br>' } else { '未发现本地 clone' }
            ExternalGovernance = $externalGovernance
        }
    }

    return @($observed)
}

function Get-GitOwnerHeadFromFiles {
    param([Parameter(Mandatory = $true)] [string] $RepositoryRoot)

    try {
        $gitDirectory = Resolve-GitOwnerGitDirectory -RepositoryRoot $RepositoryRoot
        if ([string]::IsNullOrWhiteSpace($gitDirectory)) { return $null }
        $commonDirectory = Resolve-GitOwnerCommonDirectory -GitDirectory $gitDirectory
        if ([string]::IsNullOrWhiteSpace($commonDirectory)) { return $null }
        $headPath = Join-Path $gitDirectory 'HEAD'
        if (-not (Test-Path -LiteralPath $headPath -PathType Leaf)) { return $null }
        $head = (Get-Content -LiteralPath $headPath -TotalCount 1 -Encoding ascii).Trim()
        if ($head -match '^[0-9a-fA-F]{40}$') { return $head.ToLowerInvariant() }
        if ($head -notmatch '^ref:\s*(?<ref>.+)$') { return $null }

        $refName = $Matches.ref.Trim().Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $refPath = Join-Path $commonDirectory $refName
        if (Test-Path -LiteralPath $refPath -PathType Leaf) {
            $value = (Get-Content -LiteralPath $refPath -TotalCount 1 -Encoding ascii).Trim()
            if ($value -match '^[0-9a-fA-F]{40}$') { return $value.ToLowerInvariant() }
        }

        $packedRefsPath = Join-Path $commonDirectory 'packed-refs'
        if (Test-Path -LiteralPath $packedRefsPath -PathType Leaf) {
            $gitRefName = $Matches.ref.Trim()
            foreach ($line in Get-Content -LiteralPath $packedRefsPath -Encoding ascii) {
                if ($line -match "^(?<hash>[0-9a-fA-F]{40})\s+$([regex]::Escape($gitRefName))$") {
                    return $Matches.hash.ToLowerInvariant()
                }
            }
        }
    }
    catch {
        return $null
    }

    return $null
}

function Get-GitOwnerIndexIdentity {
    param([Parameter(Mandatory = $true)] [string] $RepoRoot)

    $repository = Get-GitOwnerRootRemoteSlug -RepositoryRoot $RepoRoot
    return [pscustomobject][ordered]@{
        repository = $repository
        default_branch = $null
        head = Get-GitOwnerHeadFromFiles -RepositoryRoot $RepoRoot
    }
}

function Add-GitOwnerIndexBaselineContext {
    param(
        [AllowNull()] [object] $IndexIdentity,
        [AllowEmptyCollection()] [object[]] $BaselineRows = @()
    )

    $identity = ConvertTo-GitOwnerCanonicalIndexIdentity `
        -IndexIdentity $IndexIdentity
    $defaultBranch = @(
        $BaselineRows |
            Where-Object {
                ([string]$_.NameWithOwner).Trim().ToLowerInvariant() -eq
                    [string]$identity.repository
            } |
            Select-Object -First 1 -ExpandProperty DefaultBranch
    )
    return [pscustomobject][ordered]@{
        repository = $identity.repository
        default_branch = if ($defaultBranch.Count -gt 0) {
            [string]$defaultBranch[0]
        } else { $identity.default_branch }
        head = $identity.head
    }
}

function Invoke-GitOwnerProvider {
    param(
        [Parameter(Mandatory = $true)] [string] $Owner,
        [Parameter(Mandatory = $true)] [string] $ExpectedRepository,
        [Parameter(Mandatory = $true)] [string] $RepoRoot,
        [AllowNull()] [scriptblock] $IdentityResolver,
        [AllowNull()] [scriptblock] $IndexReader,
        [AllowNull()] [scriptblock] $RegistryReader,
        [AllowNull()] [scriptblock] $RemoteReader,
        [AllowNull()] [scriptblock] $RemoteMerger
    )

    $identity = if ($null -ne $IdentityResolver) {
        & $IdentityResolver $RepoRoot
    }
    else {
        Get-GitOwnerIndexIdentity -RepoRoot $RepoRoot
    }
    $identityIssue = Get-GitOwnerIndexIdentityIssueCode `
        -IndexIdentity $identity -ExpectedRepository $ExpectedRepository
    if (-not [string]::IsNullOrWhiteSpace($identityIssue)) {
        return Invoke-GitOwnerStatus `
            -BaselineRows @() -ObservedRows @() `
            -IndexIdentity $identity -RegistryIdentity $null `
            -ExpectedRepository $ExpectedRepository
    }

    $baselineRows = if ($null -ne $IndexReader) {
        @(& $IndexReader $RepoRoot)
    }
    else {
        @(Read-GitOwnerIndexRows -RepoRoot $RepoRoot)
    }
    $identity = Add-GitOwnerIndexBaselineContext `
        -IndexIdentity $identity -BaselineRows $baselineRows
    $registryIdentity = if ($null -ne $RegistryReader) {
        & $RegistryReader $RepoRoot
    }
    else {
        Read-GitOwnerGovernanceRegistryIdentity -RepoRoot $RepoRoot
    }
    $remote = if ($null -ne $RemoteReader) {
        & $RemoteReader $Owner
    }
    else {
        Get-GitOwnerRemoteRows -Owner $Owner
    }
    if (-not [bool]$remote.available) {
        return New-GitOwnerUnavailableStatus -Reason $remote.reason `
            -IndexIdentity $identity -RegistryIdentity $registryIdentity
    }
    $observedRows = if ($null -ne $RemoteMerger) {
        @(& $RemoteMerger $baselineRows @($remote.rows))
    }
    else {
        @(Merge-GitOwnerRemoteAndLocalFacts `
            -BaselineRows $baselineRows -RemoteRows @($remote.rows))
    }
    return Invoke-GitOwnerStatus -BaselineRows $baselineRows `
        -ObservedRows $observedRows -IndexIdentity $identity `
        -RegistryIdentity $registryIdentity `
        -ExpectedRepository $ExpectedRepository
}

if ($MyInvocation.InvocationName -ne '.') {
    $status = $null
    try {
        $status = Invoke-GitOwnerProvider -Owner $Owner `
            -ExpectedRepository $ExpectedRepository -RepoRoot $RepoRoot
    }
    catch {
        $status = New-GitOwnerExecutionFailure `
            -Reason 'provider_execution_failed'
    }

    if ($Json) {
        $status | ConvertTo-Json -Depth 12 -Compress
    }
    else {
        $status
    }
    exit (Get-GitOwnerStatusProcessExitCode -Status $status)
}
