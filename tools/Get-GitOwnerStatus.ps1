#requires -Version 7.0

[CmdletBinding()]
param(
    [string] $Owner = 'wlyaaaaa',
    [string] $ExpectedRepository = 'wlyaaaaa/github-local-index',
    [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [switch] $MigrateBaseline,
    [switch] $Json
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'GitHubIndex.PrivateNavigation.psm1') -Force

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

    if ($value -in @(
        '未发现本地 clone',
        '本机已发现 clone（路径不公开）',
        '外部治理（不读取本地路径）',
        '专门 owner 治理（不公开本地路径）'
    )) {
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
                expected = [pscustomobject][ordered]@{ count = $baselineRoots.Count }
                actual = [pscustomobject][ordered]@{ count = $observedRoots.Count }
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

function ConvertFrom-GitOwnerMilestoneMarkdownCell {
    param([Parameter(Mandatory = $true)] [string] $Value)

    return $Value.Replace('\|', '|').Replace('\`', '`').Replace('<br>', "`n")
}

function Get-GitOwnerMilestoneCells {
    param([Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Line)

    if (-not $Line.StartsWith('|') -or -not $Line.EndsWith('|')) {
        return @()
    }
    $inner = $Line.Substring(1, $Line.Length - 2)
    return @([regex]::Split($inner, '(?<!\\)\|') | ForEach-Object {
        ConvertFrom-GitOwnerMilestoneMarkdownCell $_.Trim()
    })
}

function Assert-GitOwnerMilestoneReasonSafe {
    param([Parameter(Mandatory = $true)] [string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 1000 -or
        @($Value -split "`r?`n").Count -gt 20) {
        throw 'milestone_record_reason_invalid'
    }
    foreach ($pattern in @(
        '-----BEGIN[ A-Z]+PRIVATE KEY-----',
        'ghp_[A-Za-z0-9]{36,}',
        'github_pat_[A-Za-z0-9_]{20,}',
        'xox[baprs]-[A-Za-z0-9-]{20,}',
        'sk-[A-Za-z0-9]{20,}',
        '\b(?:client[_-]?secret|password|passwd|pwd)\s*[:=]\s*\S+',
        '\bauthorization\s*:\s*bearer\s+\S+'
    )) {
        if ($Value -match $pattern) {
            throw 'milestone_record_reason_unsafe'
        }
    }
}

function ConvertTo-GitOwnerMilestoneUtcTimestamp {
    param([Parameter(Mandatory = $true)] [string] $Value)

    try {
        $timestamp = [datetimeoffset]::ParseExact(
            $Value,
            'yyyy-MM-dd HH:mm:ss zzz',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AllowWhiteSpaces
        )
        return $timestamp.ToUniversalTime().ToString(
            'o', [Globalization.CultureInfo]::InvariantCulture
        )
    }
    catch {
        throw 'milestone_record_timestamp_invalid'
    }
}

function New-GitOwnerMilestoneUnavailable {
    param([Parameter(Mandatory = $true)] [string] $Reason)

    return [pscustomobject][ordered]@{
        schema = 'github-local-index.milestone-records.v1'
        status = 'unavailable'
        coverage_state = 'unknown'
        bootstrap_gap = $true
        retained_window_only = $true
        retention_limit = 50
        record_count = 0
        semantic_sha256 = $null
        entries = @()
        gaps = @(
            [pscustomobject][ordered]@{
                code = ConvertTo-GitOwnerSafeReason `
                    -Reason $Reason -Fallback 'milestone_source_unavailable'
                scope = 'milestone_records'
            },
            [pscustomobject][ordered]@{ code = 'bootstrap_gap'; scope = 'prior_milestone_history' },
            [pscustomobject][ordered]@{ code = 'retained_window_only'; scope = 'milestone_records' }
        )
    }
}

function Get-GitOwnerMilestoneRecords {
    param([Parameter(Mandatory = $true)] [string] $Path)

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw 'milestone_source_missing'
        }
        if ((Get-Item -LiteralPath $Path).Length -gt 131072) {
            throw 'milestone_source_too_large'
        }

        $lines = @(Get-Content -LiteralPath $Path -Encoding utf8)
        $header = '| 时间 | 仓库 | 分支 | Commit | 决策理由 |'
        $separator = '|---|---|---|---|---|'
        if (@($lines | Where-Object { $_ -ceq $header }).Count -ne 1 -or
            @($lines | Where-Object { $_ -ceq $separator }).Count -ne 1 -or
            @($lines | Where-Object { $_ -like '更新时间：*' }).Count -ne 1) {
            throw 'milestone_source_schema_invalid'
        }

        $entries = [System.Collections.Generic.List[object]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::Ordinal
        )
        foreach ($line in $lines) {
            if (-not $line.StartsWith('|') -or $line -ceq $header -or $line -ceq $separator) {
                continue
            }
            $cells = @(Get-GitOwnerMilestoneCells -Line $line)
            if ($cells.Count -ne 5) {
                throw 'milestone_source_schema_invalid'
            }

            $repo = ([string]$cells[1]).Trim().ToLowerInvariant()
            $branch = ([string]$cells[2]).Trim()
            $commit = ([string]$cells[3]).Trim().ToLowerInvariant()
            $reason = ([string]$cells[4]).Trim()
            if ($repo -notmatch '^[a-z0-9_.-]+/[a-z0-9_.-]+$' -or
                [string]::IsNullOrWhiteSpace($branch) -or $branch.Length -gt 255 -or
                $branch -match '[\x00-\x1f]' -or $commit -notmatch '^[0-9a-f]{7,64}$') {
                throw 'milestone_record_identity_invalid'
            }
            Assert-GitOwnerMilestoneReasonSafe -Value $reason
            $occurredAt = ConvertTo-GitOwnerMilestoneUtcTimestamp -Value ([string]$cells[0]).Trim()
            $key = "$repo`u{001f}$branch`u{001f}$commit"
            if (-not $seen.Add($key)) {
                throw 'milestone_record_duplicate'
            }
            $entries.Add([pscustomobject][ordered]@{
                record_id = 'push:' + (Get-GitOwnerSha256 -Text $key).Substring(7)
                occurred_at = $occurredAt
                repository = $repo
                branch = $branch
                commit = $commit
                reason = $reason
            })
            if ($entries.Count -gt 50) {
                throw 'milestone_retention_limit_exceeded'
            }
        }

        $canonicalJson = ConvertTo-Json -InputObject @($entries) -Depth 5 -Compress
        return [pscustomobject][ordered]@{
            schema = 'github-local-index.milestone-records.v1'
            status = 'current'
            coverage_state = 'partial'
            bootstrap_gap = $true
            retained_window_only = $true
            retention_limit = 50
            record_count = $entries.Count
            semantic_sha256 = Get-GitOwnerSha256 -Text $canonicalJson
            entries = @($entries)
            gaps = @(
                [pscustomobject][ordered]@{ code = 'bootstrap_gap'; scope = 'prior_milestone_history' },
                [pscustomobject][ordered]@{ code = 'retained_window_only'; scope = 'milestone_records' }
            )
        }
    }
    catch {
        return New-GitOwnerMilestoneUnavailable -Reason $_.Exception.Message
    }
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

function ConvertTo-GitOwnerRowsFromBaselineSnapshot {
    param(
        [Parameter(Mandatory = $true)] [object] $IdentitySnapshot,
        [Parameter(Mandatory = $true)] [object] $LocalRootSnapshot
    )

    $rootByRepo = @{}
    foreach ($entry in @($LocalRootSnapshot.entries)) {
        $rootByRepo[([string]$entry.repo).ToLowerInvariant()] = $entry.local_root
    }
    return @($IdentitySnapshot.identities | ForEach-Object {
        $repo = ([string]$_.repo).ToLowerInvariant()
        $root = if ($rootByRepo.ContainsKey($repo)) { $rootByRepo[$repo] } else { $null }
        [pscustomobject][ordered]@{
            NameWithOwner = $repo
            Visibility = [string]$_.visibility
            DefaultBranch = [string]$_.default_branch
            LocalPath = if ($null -eq $root) { '未发现本地 clone' } else { [string]$root }
            ExternalGovernance = $false
        }
    })
}

function ConvertTo-GitOwnerUtcTimestamp {
    param([AllowNull()] [object] $Value)

    if ($null -eq $Value) { return $null }
    try {
        $timestamp = if ($Value -is [datetimeoffset]) {
            [datetimeoffset]$Value
        }
        elseif ($Value -is [datetime]) {
            [datetimeoffset]([datetime]$Value).ToUniversalTime()
        }
        else {
            [datetimeoffset]::Parse(
                [string]$Value,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
            )
        }
        return $timestamp.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        throw 'owner_baseline_v3_timestamp_invalid'
    }
}

function ConvertTo-GitOwnerBaselineState {
    param([Parameter(Mandatory = $true)] [object] $StoreResult)

    if ([string]$StoreResult.status -ne 'current') {
        $reason = switch ([string]$StoreResult.status) {
            'missing' { 'owner_baseline_v3_missing' }
            default { 'owner_baseline_v3_invalid' }
        }
        return [pscustomobject][ordered]@{
            status = 'unavailable'
            reason = $reason
            rows = @()
            history = $null
        }
    }

    $store = $StoreResult.store
    $rows = @(ConvertTo-GitOwnerRowsFromBaselineSnapshot `
        -IdentitySnapshot $store.current `
        -LocalRootSnapshot $store.current_local_roots)
    $transitionDeltas = @()
    if ($null -ne $store.previous) {
        $previousRows = @(ConvertTo-GitOwnerRowsFromBaselineSnapshot `
            -IdentitySnapshot $store.previous `
            -LocalRootSnapshot $store.previous_local_roots)
        $previousFacts = ConvertTo-GitOwnerFactSet -Rows $previousRows
        $currentFacts = ConvertTo-GitOwnerFactSet -Rows $rows
        $transitionDeltas = @(Compare-GitOwnerFactSets `
            -BaselineFacts $previousFacts.facts -ObservedFacts $currentFacts.facts)
    }
    return [pscustomobject][ordered]@{
        status = 'current'
        reason = $null
        rows = $rows
        history = [pscustomobject][ordered]@{
            schema = 'github-local-index.owner-history.v1'
            state = if ([bool]$store.receipt.history_gap) { 'bootstrap_gap' } else { 'continuous' }
            current_observed_at = ConvertTo-GitOwnerUtcTimestamp -Value $store.current.observed_at
            previous_observed_at = if ($null -eq $store.previous) {
                $null
            }
            else {
                ConvertTo-GitOwnerUtcTimestamp -Value $store.previous.observed_at
            }
            current_identity_sha256 = [string]$store.current.identities_sha256
            previous_identity_sha256 = if ($null -eq $store.previous) { $null } else { [string]$store.previous.identities_sha256 }
            transition_delta_count = $transitionDeltas.Count
            transition_deltas = $transitionDeltas
        }
    }
}

function Read-GitOwnerBaselineState {
    param([Parameter(Mandatory = $true)] [string] $RepoRoot)

    return ConvertTo-GitOwnerBaselineState `
        -StoreResult (Get-GitHubOwnerBaselineStore -RepoRoot $RepoRoot)
}

function Add-GitOwnerBaselineHistory {
    param(
        [Parameter(Mandatory = $true)] [object] $Status,
        [AllowNull()] [object] $History
    )

    if ($null -eq $History) { return $Status }
    $attentions = @()
    $historyBlocks = $false
    if ([string]$History.state -eq 'bootstrap_gap') {
        $attentions += [pscustomobject][ordered]@{
            code = 'owner_history_gap'
            scope = 'prior_full_owner_baseline'
        }
        if ([string]$Status.domain_status -eq 'current') {
            $Status.domain_status = 'unknown'
        }
        $historyBlocks = $true
    }
    if ([int]$History.transition_delta_count -gt 0) {
        $attentions += [pscustomobject][ordered]@{
            code = 'owner_baseline_transition_recorded'
            scope = 'previous_to_current'
        }
    }
    $Status | Add-Member -NotePropertyName history -NotePropertyValue $History -Force
    $Status | Add-Member -NotePropertyName attentions -NotePropertyValue @($attentions) -Force
    $Status.summary | Add-Member -NotePropertyName attention_count -NotePropertyValue $attentions.Count -Force
    if ($historyBlocks) {
        $Status.blocking_scopes = @($Status.blocking_scopes + 'git_owner_history' | Sort-Object -Unique)
    }
    return $Status
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

function New-GitOwnerBaselineMigrationResult {
    param(
        [string] $ExecutionStatus = 'completed',
        [string] $DomainStatus = 'unknown',
        [bool] $MutationsPerformed = $false,
        [string] $Reason = '',
        [datetimeoffset] $ObservedAt = [datetimeoffset]::UtcNow,
        [AllowNull()] [object] $Store,
        [int] $LegacyNavigationEntries = 0,
        [int] $VerifiedLocalRoots = 0,
        [int] $NullableLocalRoots = 0
    )

    return [pscustomobject][ordered]@{
        schema = 'github-local-index.owner-baseline-migration.v1'
        execution_status = $ExecutionStatus
        domain_status = $DomainStatus
        observed_at = $ObservedAt.UtcDateTime.ToString('o')
        zero_fetch = $true
        mutations_performed = $MutationsPerformed
        reason = if ([string]::IsNullOrWhiteSpace($Reason)) { $null } else { ConvertTo-GitOwnerSafeReason -Reason $Reason }
        history_gap = if ($null -eq $Store) { $null } else { [bool]$Store.receipt.history_gap }
        bootstrap_reason = if ($null -eq $Store) { $null } else { $Store.receipt.bootstrap_reason }
        repository_count = if ($null -eq $Store) { 0 } else { [int]$Store.current.repository_count }
        legacy_navigation_entries = $LegacyNavigationEntries
        verified_local_roots = $VerifiedLocalRoots
        nullable_local_roots = $NullableLocalRoots
        current_identity_sha256 = if ($null -eq $Store) { $null } else { [string]$Store.current.identities_sha256 }
        previous_identity_sha256 = if ($null -eq $Store -or $null -eq $Store.previous) { $null } else { [string]$Store.previous.identities_sha256 }
        payload_sha256 = if ($null -eq $Store) { $null } else { [string]$Store.payload_sha256 }
    }
}

function Invoke-GitOwnerBaselineMigration {
    param(
        [Parameter(Mandatory = $true)] [string] $Owner,
        [Parameter(Mandatory = $true)] [string] $ExpectedRepository,
        [Parameter(Mandatory = $true)] [string] $RepoRoot,
        [AllowNull()] [scriptblock] $IdentityResolver,
        [AllowNull()] [scriptblock] $RemoteReader,
        [AllowNull()] [scriptblock] $NavigationReader,
        [AllowNull()] [scriptblock] $BaselineWriter
    )

    $observedAt = [datetimeoffset]::UtcNow
    $identity = if ($null -ne $IdentityResolver) {
        & $IdentityResolver $RepoRoot
    }
    else {
        Get-GitOwnerIndexIdentity -RepoRoot $RepoRoot
    }
    $identityIssue = Get-GitOwnerIndexIdentityIssueCode `
        -IndexIdentity $identity -ExpectedRepository $ExpectedRepository
    if (-not [string]::IsNullOrWhiteSpace($identityIssue)) {
        return New-GitOwnerBaselineMigrationResult `
            -DomainStatus 'blocked' -Reason $identityIssue -ObservedAt $observedAt
    }

    $remote = if ($null -ne $RemoteReader) {
        & $RemoteReader $Owner
    }
    else {
        Get-GitOwnerRemoteRows -Owner $Owner
    }
    if (-not [bool]$remote.available) {
        return New-GitOwnerBaselineMigrationResult `
            -ExecutionStatus 'error' -DomainStatus 'unknown' `
            -Reason $remote.reason -ObservedAt $observedAt
    }
    $navigation = if ($null -ne $NavigationReader) {
        & $NavigationReader $RepoRoot
    }
    else {
        Get-GitHubIndexPrivateNavigationEntries -RepoRoot $RepoRoot
    }
    $navigationEntries = if ([string]$navigation.status -eq 'current') {
        @($navigation.entries)
    }
    else {
        @()
    }
    $navigationByRepo = @{}
    foreach ($entry in $navigationEntries) {
        $repo = ([string]$entry.repo).Trim().ToLowerInvariant()
        $navigationByRepo[$repo] = $entry
    }

    $identityRows = [System.Collections.Generic.List[object]]::new()
    $localRootRows = [System.Collections.Generic.List[object]]::new()
    $verifiedLocalRoots = 0
    $remoteRepos = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($row in @($remote.rows)) {
        $repo = ([string]$row.NameWithOwner).Trim().ToLowerInvariant()
        [void]$remoteRepos.Add($repo)
        $identityRows.Add([pscustomobject][ordered]@{
            repo = $repo
            visibility = ([string]$row.Visibility).Trim().ToUpperInvariant()
            default_branch = ([string]$row.DefaultBranch).Trim()
        })
        $localRoot = $null
        if ($navigationByRepo.ContainsKey($repo)) {
            $candidateRoot = [string]$navigationByRepo[$repo].path
            if (Test-Path -LiteralPath $candidateRoot -PathType Container) {
                $candidateRepo = Get-GitOwnerRootRemoteSlug -RepositoryRoot $candidateRoot
                if ($candidateRepo -ne $repo) {
                    throw 'legacy_navigation_identity_mismatch'
                }
                $localRoot = $candidateRoot
                $verifiedLocalRoots++
            }
        }
        $localRootRows.Add([pscustomobject][ordered]@{
            repo = $repo
            local_root = $localRoot
        })
    }
    if (@($navigationEntries | Where-Object {
        -not $remoteRepos.Contains(([string]$_.repo).Trim().ToLowerInvariant())
    }).Count -gt 0) {
        throw 'legacy_navigation_repository_missing_remote'
    }

    $priorSource = if ([string]$navigation.status -eq 'current') {
        'private_navigation_v2_without_identity_history'
    }
    else {
        'no_prior_owner_identity_baseline'
    }
    $writeResult = if ($null -ne $BaselineWriter) {
        & $BaselineWriter $RepoRoot $Owner @($identityRows) @($localRootRows) $observedAt $priorSource
    }
    else {
        Write-GitHubOwnerBaselineStore `
            -RepoRoot $RepoRoot -Owner $Owner `
            -IdentityRows @($identityRows) -LocalRootRows @($localRootRows) `
            -ObservedAt $observedAt -PriorSource $priorSource
    }
    $store = $writeResult.store
    return New-GitOwnerBaselineMigrationResult `
        -DomainStatus $(if ([bool]$store.receipt.history_gap) { 'attention' } else { 'current' }) `
        -MutationsPerformed $true -ObservedAt $observedAt -Store $store `
        -LegacyNavigationEntries $navigationEntries.Count `
        -VerifiedLocalRoots $verifiedLocalRoots `
        -NullableLocalRoots (@($localRootRows | Where-Object { $null -eq $_.local_root }).Count)
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
        [AllowNull()] [scriptblock] $RemoteMerger,
        [AllowNull()] [scriptblock] $MilestoneReader
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

    $baselineState = if ($null -ne $IndexReader) {
        [pscustomobject][ordered]@{
            status = 'current'
            reason = $null
            rows = @(& $IndexReader $RepoRoot)
            history = [pscustomobject][ordered]@{
                schema = 'github-local-index.owner-history.v1'
                state = 'continuous'
                current_observed_at = $null
                previous_observed_at = $null
                current_identity_sha256 = $null
                previous_identity_sha256 = $null
                transition_delta_count = 0
                transition_deltas = @()
            }
        }
    }
    else {
        Read-GitOwnerBaselineState -RepoRoot $RepoRoot
    }
    $registryIdentity = if ($null -ne $RegistryReader) {
        & $RegistryReader $RepoRoot
    }
    else {
        Read-GitOwnerGovernanceRegistryIdentity -RepoRoot $RepoRoot
    }
    if ([string]$baselineState.status -ne 'current') {
        return New-GitOwnerUnavailableStatus -Reason $baselineState.reason `
            -IndexIdentity $identity -RegistryIdentity $registryIdentity
    }
    $baselineRows = @($baselineState.rows)
    $identity = Add-GitOwnerIndexBaselineContext `
        -IndexIdentity $identity -BaselineRows $baselineRows
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
    $status = Invoke-GitOwnerStatus -BaselineRows $baselineRows `
        -ObservedRows $observedRows -IndexIdentity $identity `
        -RegistryIdentity $registryIdentity `
        -ExpectedRepository $ExpectedRepository
    $status = Add-GitOwnerBaselineHistory `
        -Status $status -History $baselineState.history
    $milestoneRecords = if ($null -ne $MilestoneReader) {
        & $MilestoneReader $RepoRoot
    }
    else {
        Get-GitOwnerMilestoneRecords `
            -Path (Join-Path $RepoRoot '03_推送决策\已推送记录.md')
    }
    $status | Add-Member -NotePropertyName milestone_records `
        -NotePropertyValue $milestoneRecords -Force
    return $status
}

if ($MyInvocation.InvocationName -ne '.') {
    $status = $null
    try {
        $status = if ($MigrateBaseline) {
            Invoke-GitOwnerBaselineMigration -Owner $Owner `
                -ExpectedRepository $ExpectedRepository -RepoRoot $RepoRoot
        }
        else {
            Invoke-GitOwnerProvider -Owner $Owner `
                -ExpectedRepository $ExpectedRepository -RepoRoot $RepoRoot
        }
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
