#requires -Version 7.0

[CmdletBinding(DefaultParameterSetName = 'Fixture')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Inspect', 'Delete')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$Repository,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_=-]+$')]
    [string]$ExpectedNodeId,

    [Parameter(Mandatory = $true)]
    [ValidateSet('PRIVATE')]
    [string]$ExpectedVisibility,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$ExpectedDefaultBranch,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_.-]+$')]
    [string]$ExpectedAuthenticatedLogin,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^sha256:[0-9a-f]{64}$')]
    [string]$ActionCardHash,

    [Parameter(Mandatory = $true)]
    [string]$ActionCardPath,

    [Parameter(Mandatory = $true)]
    [string]$JournalPath,

    [string]$ApprovalPath,
    [switch]$ApproveExactDeletion,

    [Parameter(Mandatory = $true, ParameterSetName = 'Fixture')]
    [string]$FixturePath,

    [Parameter(Mandatory = $true, ParameterSetName = 'Live')]
    [switch]$Live,

    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false, $true)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$script:RepoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\', '/')
$script:Fixture = $null
$script:FixtureResolvedPath = $null
$script:RunId = $null

function Throw-ContractError {
    param([Parameter(Mandatory = $true)][string]$Code)
    throw [InvalidOperationException]::new($Code)
}

function Read-StrictJson {
    param([Parameter(Mandatory = $true)][string]$Path, [int]$MaximumBytes = 131072)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Throw-ContractError 'file_missing' }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -gt $MaximumBytes) {
        Throw-ContractError 'unsafe_file'
    }
    $bytes = [IO.File]::ReadAllBytes($item.FullName)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        Throw-ContractError 'invalid_encoding'
    }
    try { return $utf8.GetString($bytes) | ConvertFrom-Json -Depth 30 }
    catch { Throw-ContractError 'invalid_json' }
}

function ConvertTo-CanonicalBytes {
    param([Parameter(Mandatory = $true)][object]$Value)
    # All persisted contract documents use ordered objects built by this script.
    return $utf8.GetBytes(($Value | ConvertTo-Json -Depth 30 -Compress) + "`n")
}

function Write-CanonicalJsonElement {
    param(
        [Parameter(Mandatory = $true)][Text.Json.Utf8JsonWriter]$Writer,
        [Parameter(Mandatory = $true)][Text.Json.JsonElement]$Element
    )
    switch ($Element.ValueKind) {
        ([Text.Json.JsonValueKind]::Object) {
            $Writer.WriteStartObject()
            foreach ($property in @($Element.EnumerateObject()) | Sort-Object -Property Name -CaseSensitive) {
                $Writer.WritePropertyName($property.Name)
                Write-CanonicalJsonElement -Writer $Writer -Element $property.Value
            }
            $Writer.WriteEndObject()
        }
        ([Text.Json.JsonValueKind]::Array) {
            $Writer.WriteStartArray()
            foreach ($item in $Element.EnumerateArray()) { Write-CanonicalJsonElement -Writer $Writer -Element $item }
            $Writer.WriteEndArray()
        }
        ([Text.Json.JsonValueKind]::String) { $Writer.WriteStringValue($Element.GetString()) }
        ([Text.Json.JsonValueKind]::Number) { $Writer.WriteRawValue($Element.GetRawText(), $true) }
        ([Text.Json.JsonValueKind]::True) { $Writer.WriteBooleanValue($true) }
        ([Text.Json.JsonValueKind]::False) { $Writer.WriteBooleanValue($false) }
        ([Text.Json.JsonValueKind]::Null) { $Writer.WriteNullValue() }
        default { Throw-ContractError 'invalid_json' }
    }
}

function Get-CanonicalJsonHash {
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    try { $document = [Text.Json.JsonDocument]::Parse([ReadOnlyMemory[byte]]::new($bytes)) }
    catch { Throw-ContractError 'invalid_json' }
    $stream = [IO.MemoryStream]::new()
    $options = [Text.Json.JsonWriterOptions]::new()
    $options.Indented = $false
    $options.Encoder = [Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping
    $writer = [Text.Json.Utf8JsonWriter]::new($stream, $options)
    try {
        Write-CanonicalJsonElement -Writer $writer -Element $document.RootElement
        $writer.Flush()
        return 'sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($stream.ToArray())
        ).ToLowerInvariant()
    } finally {
        $writer.Dispose()
        $stream.Dispose()
        $document.Dispose()
    }
}

function Write-AtomicJson {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Value)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { Throw-ContractError 'parent_missing' }
    $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $options = [IO.FileOptions]::WriteThrough
        $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, $options)
        try {
            $bytes = ConvertTo-CanonicalBytes -Value $Value
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally { $stream.Dispose() }
        [IO.File]::Move($temporary, $Path, $true)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Resolve-PrivateJournalPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { Throw-ContractError 'journal_path_invalid' }
    $resolved = [IO.Path]::GetFullPath($Path)
    $repoPrefix = $script:RepoRoot + [IO.Path]::DirectorySeparatorChar
    if ($resolved.Equals($script:RepoRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $resolved.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-ContractError 'journal_must_be_private'
    }
    $parent = Split-Path -Parent $resolved
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { Throw-ContractError 'journal_parent_missing' }
    $parentItem = Get-Item -LiteralPath $parent -Force
    if (($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Throw-ContractError 'journal_path_unsafe' }
    if (Test-Path -LiteralPath $resolved) {
        $item = Get-Item -LiteralPath $resolved -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Throw-ContractError 'journal_path_unsafe' }
    }
    return $resolved
}

function Read-ActionCard {
    $repositoryOwner = ($Repository -split '/', 2)[0]
    if ($repositoryOwner -cne $ExpectedAuthenticatedLogin) {
        Throw-ContractError 'repository_owner_identity_mismatch'
    }
    $card = Read-StrictJson -Path $ActionCardPath -MaximumBytes 131072
    $actualHash = Get-CanonicalJsonHash -Path $ActionCardPath
    if ($actualHash -cne $ActionCardHash -or
        $card.schema -cne 'personalos:s9-wp4-release-action-card.v1' -or
        [string]::IsNullOrWhiteSpace([string]$card.run_id)) {
        Throw-ContractError 'action_card_invalid'
    }
    $matching = @($card.steps | Where-Object { $_.name -ceq 'delete_legacy_remote' })
    if ($matching.Count -ne 1) { Throw-ContractError 'action_card_invalid' }
    $step = $matching[0]
    if ($step.irreversible -isnot [bool] -or -not [bool]$step.irreversible -or
        $step.owner -cne 'github_index' -or
        $step.operation -cne 'github-index:delete-health-remote' -or
        $step.request.repository -cne $Repository -or
        $step.request.node_id -cne $ExpectedNodeId -or
        $step.request.visibility -cne $ExpectedVisibility -or
        $step.request.default_branch -cne $ExpectedDefaultBranch -or
        $step.request.transition.from -ne $true -or
        $step.request.transition.key -cne 'remote_exists' -or
        $step.request.transition.to -ne $false) {
        Throw-ContractError 'action_card_identity_mismatch'
    }
    $script:RunId = [string]$card.run_id
}

function Read-Approval {
    if (-not $ApproveExactDeletion -or [string]::IsNullOrWhiteSpace($ApprovalPath)) {
        Throw-ContractError 'approval_required'
    }
    $approval = Read-StrictJson -Path $ApprovalPath -MaximumBytes 32768
    $names = @($approval.PSObject.Properties.Name | Sort-Object)
    $expected = @('action_card_hash', 'approved_steps', 'decision', 'run_id', 'schema')
    if (($names -join "`n") -cne (($expected | Sort-Object) -join "`n") -or
        $approval.schema -cne 'personalos:s9-wp4-irreversible-approval.v1' -or
        $approval.run_id -cne $script:RunId -or
        $approval.action_card_hash -cne $ActionCardHash -or
        $approval.decision -cne 'approved' -or
        @($approval.approved_steps).Count -ne 3 -or
        @($approval.approved_steps)[0] -cne 'delete_legacy_remote' -or
        @($approval.approved_steps)[1] -cne 'delete_legacy_directory' -or
        @($approval.approved_steps)[2] -cne 'delete_legacy_task') {
        Throw-ContractError 'approval_invalid'
    }
}

function Read-Fixture {
    $resolved = [IO.Path]::GetFullPath($FixturePath)
    $document = Read-StrictJson -Path $resolved
    if ($document.schema -cne 'github-index.repository-retirement-fixture.v1') { Throw-ContractError 'fixture_invalid' }
    $script:FixtureResolvedPath = $resolved
    $script:Fixture = $document
}

function Invoke-Gh {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'gh.exe'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $utf8
    $start.StandardErrorEncoding = $utf8
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
    try {
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $start
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        if (-not $process.WaitForExit(30000)) { try { $process.Kill($true) } catch {}; Throw-ContractError 'github_timeout' }
        $exitCode = $process.ExitCode
        $process.Dispose()
        return [pscustomobject]@{ exit_code = $exitCode; stdout = $stdout; stderr = $stderr }
    } catch [InvalidOperationException] { throw }
    catch { Throw-ContractError 'github_cli_unavailable' }
}

function Get-RepositorySnapshot {
    if ($PSCmdlet.ParameterSetName -eq 'Fixture') {
        if ($null -eq $script:Fixture) { Read-Fixture }
        if ($script:Fixture.fault -eq 'network_error') { Throw-ContractError 'github_network_error' }
        if ($script:Fixture.fault -eq 'auth_error') { Throw-ContractError 'github_auth_error' }
        if ($script:Fixture.fault -eq 'masked_404') {
            return [pscustomobject]@{ exists = $false; authenticated_login = [string]$script:Fixture.authenticated_login }
        }
        if (-not [bool]$script:Fixture.repository.exists) {
            return [pscustomobject]@{ exists = $false; authenticated_login = [string]$script:Fixture.authenticated_login }
        }
        return [pscustomobject]@{
            exists = $true
            authenticated_login = [string]$script:Fixture.authenticated_login
            name_with_owner = [string]$script:Fixture.repository.name_with_owner
            node_id = [string]$script:Fixture.repository.node_id
            visibility = [string]$script:Fixture.repository.visibility
            default_branch = [string]$script:Fixture.repository.default_branch
        }
    }

    $user = Invoke-Gh -Arguments @('api', 'user', '--jq', '.login')
    if ($user.exit_code -ne 0) { Throw-ContractError 'github_auth_error' }
    $login = $user.stdout.Trim()
    $response = Invoke-Gh -Arguments @('api', "repos/$Repository")
    if ($response.exit_code -ne 0) {
        if ($response.stderr -match '(?i)HTTP\s+404|not found') {
            return [pscustomobject]@{ exists = $false; authenticated_login = $login }
        }
        Throw-ContractError 'github_read_error'
    }
    try { $repositoryValue = $response.stdout | ConvertFrom-Json -Depth 20 }
    catch { Throw-ContractError 'github_response_invalid' }
    return [pscustomobject]@{
        exists = $true
        authenticated_login = $login
        name_with_owner = [string]$repositoryValue.full_name
        node_id = [string]$repositoryValue.node_id
        visibility = ([string]$repositoryValue.visibility).ToUpperInvariant()
        default_branch = [string]$repositoryValue.default_branch
    }
}

function Get-OwnerAuthority {
    if ($PSCmdlet.ParameterSetName -eq 'Fixture') {
        if ($script:Fixture.fault -eq 'masked_404') { Throw-ContractError 'github_authority_unavailable' }
        return [pscustomobject]@{
            login = [string]$script:Fixture.authenticated_login
            active = $true
            scopes = @($script:Fixture.auth_scopes)
        }
    }
    $response = Invoke-Gh -Arguments @('auth', 'status', '--json', 'hosts')
    if ($response.exit_code -ne 0) { Throw-ContractError 'github_auth_error' }
    try { $value = $response.stdout | ConvertFrom-Json -Depth 10 }
    catch { Throw-ContractError 'github_auth_response_invalid' }
    $activeEntries = @($value.hosts.'github.com' | Where-Object { $_.active -eq $true -and $_.state -ceq 'success' })
    if ($activeEntries.Count -ne 1) { Throw-ContractError 'github_auth_response_invalid' }
    $entry = $activeEntries[0]
    return [pscustomobject]@{
        login = [string]$entry.login
        active = [bool]$entry.active
        scopes = @(([string]$entry.scopes).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
}

function Get-OwnedRepositoryInventory {
    if ($PSCmdlet.ParameterSetName -eq 'Fixture') {
        if ($script:Fixture.fault -eq 'masked_404') { Throw-ContractError 'github_authority_unavailable' }
        if ([bool]$script:Fixture.repository.exists) {
            return @([pscustomobject]@{
                name_with_owner = [string]$script:Fixture.repository.name_with_owner
                node_id = [string]$script:Fixture.repository.node_id
            })
        }
        return @()
    }
    $response = Invoke-Gh -Arguments @(
        'api', '--method', 'GET', '--paginate', '--slurp',
        'user/repos?affiliation=owner&visibility=all&per_page=100'
    )
    if ($response.exit_code -ne 0) { Throw-ContractError 'github_owner_inventory_unavailable' }
    try { $pages = $response.stdout | ConvertFrom-Json -Depth 20 -NoEnumerate }
    catch { Throw-ContractError 'github_owner_inventory_invalid' }
    $items = [Collections.Generic.List[object]]::new()
    foreach ($page in @($pages)) {
        foreach ($item in @($page)) {
            $items.Add([pscustomobject]@{
                name_with_owner = [string]$item.full_name
                node_id = [string]$item.node_id
            })
        }
    }
    return @($items)
}

function Assert-AuthoritativeAbsence {
    $authority = Get-OwnerAuthority
    $normalizedScopes = @($authority.scopes | ForEach-Object { ([string]$_).ToLowerInvariant() })
    if (-not $authority.active -or $authority.login -cne $ExpectedAuthenticatedLogin -or
        $normalizedScopes -notcontains 'repo' -or $normalizedScopes -notcontains 'delete_repo') {
        Throw-ContractError 'github_authority_insufficient'
    }
    $inventory = @(Get-OwnedRepositoryInventory)
    if (@($inventory | Where-Object { $_.node_id -ceq $ExpectedNodeId -or $_.name_with_owner -ceq $Repository }).Count -ne 0) {
        Throw-ContractError 'repository_still_present'
    }
}

function Assert-ExactIdentity {
    param([Parameter(Mandatory = $true)][object]$Snapshot)
    if (-not $Snapshot.exists) { Throw-ContractError 'repository_absent_without_intent' }
    if ($Snapshot.authenticated_login -cne $ExpectedAuthenticatedLogin -or
        $Snapshot.name_with_owner -cne $Repository -or
        $Snapshot.node_id -cne $ExpectedNodeId -or
        $Snapshot.visibility -cne $ExpectedVisibility -or
        $Snapshot.default_branch -cne $ExpectedDefaultBranch) {
        Throw-ContractError 'repository_identity_mismatch'
    }
}

function Get-ExpectedJournalIdentity {
    return [ordered]@{
        schema = 'github-index.repository-retirement-journal.v1'
        repository = $Repository
        node_id = $ExpectedNodeId
        visibility = $ExpectedVisibility
        default_branch = $ExpectedDefaultBranch
        authenticated_login = $ExpectedAuthenticatedLogin
        action_card_hash = $ActionCardHash
        run_id = $script:RunId
    }
}

function Get-Journal {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $journal = Read-StrictJson -Path $Path
    $identity = Get-ExpectedJournalIdentity
    foreach ($key in $identity.Keys) {
        if ([string]$journal.$key -cne [string]$identity[$key]) { Throw-ContractError 'journal_conflict' }
    }
    if ($journal.state -notin @('prepared', 'complete')) { Throw-ContractError 'journal_invalid' }
    return $journal
}

function New-Journal {
    param([string]$State)
    $value = Get-ExpectedJournalIdentity
    $value.state = $State
    return $value
}

function Invoke-DeleteRepository {
    if ($PSCmdlet.ParameterSetName -eq 'Fixture') {
        if ($script:Fixture.fault -eq 'permission_denied' -or -not [bool]$script:Fixture.delete_permission) {
            Throw-ContractError 'github_permission_denied'
        }
        $script:Fixture.repository.exists = $false
        $fault = [string]$script:Fixture.fault
        $script:Fixture.fault = ''
        Write-AtomicJson -Path $script:FixtureResolvedPath -Value $script:Fixture
        if ($fault -eq 'exit_after_remote_delete') { Throw-ContractError 'github_delete_outcome_unknown' }
        return
    }
    $response = Invoke-Gh -Arguments @('api', '--method', 'DELETE', "repos/$Repository")
    if ($response.exit_code -ne 0) { Throw-ContractError 'github_delete_outcome_unknown' }
}

function New-Result {
    param([string]$Result, [bool]$Exists, [bool]$MutationPerformed)
    return [ordered]@{
        schema = 'github-index.repository-retirement-result.v1'
        action = $Action
        repository = $Repository
        node_id = $ExpectedNodeId
        visibility = $ExpectedVisibility
        default_branch = $ExpectedDefaultBranch
        authenticated_login = $ExpectedAuthenticatedLogin
        result = $Result
        exists = $Exists
        mutation_performed = $MutationPerformed
    }
}

try {
    $journalResolved = Resolve-PrivateJournalPath -Path $JournalPath
    if ($PSCmdlet.ParameterSetName -eq 'Fixture') { Read-Fixture }
    if ($PSCmdlet.ParameterSetName -eq 'Live') {
        $cardParent = [IO.Path]::GetFullPath((Split-Path -Parent $ActionCardPath))
        $journalParent = [IO.Path]::GetFullPath((Split-Path -Parent $journalResolved))
        $approvalParent = if ($ApprovalPath) { [IO.Path]::GetFullPath((Split-Path -Parent $ApprovalPath)) } else { $journalParent }
        if (-not $cardParent.Equals($journalParent, [StringComparison]::OrdinalIgnoreCase) -or
            -not $approvalParent.Equals($journalParent, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($ActionCardPath) -cne 'action-card.json' -or
            ($ApprovalPath -and [IO.Path]::GetFileName($ApprovalPath) -cne 'irreversible-approval.json')) {
            Throw-ContractError 'release_material_boundary_invalid'
        }
    }
    Read-ActionCard
    if ($Action -eq 'Inspect') {
        $snapshot = Get-RepositorySnapshot
        Assert-ExactIdentity -Snapshot $snapshot
        $result = New-Result -Result 'present_verified' -Exists $true -MutationPerformed $false
    } else {
        Read-Approval
        $journal = Get-Journal -Path $journalResolved
        $snapshot = Get-RepositorySnapshot
        if ($null -eq $journal) {
            Assert-ExactIdentity -Snapshot $snapshot
            Write-AtomicJson -Path $journalResolved -Value (New-Journal -State 'prepared')
            Invoke-DeleteRepository
            $snapshot = Get-RepositorySnapshot
            if ($snapshot.exists) { Throw-ContractError 'github_delete_not_applied' }
            Assert-AuthoritativeAbsence
            Write-AtomicJson -Path $journalResolved -Value (New-Journal -State 'complete')
            $result = New-Result -Result 'deleted_verified' -Exists $false -MutationPerformed $true
        } elseif ($journal.state -eq 'prepared') {
            $replayMutation = $false
            if ($snapshot.exists) {
                Assert-ExactIdentity -Snapshot $snapshot
                Invoke-DeleteRepository
                $replayMutation = $true
                $snapshot = Get-RepositorySnapshot
                if ($snapshot.exists) { Throw-ContractError 'github_delete_not_applied' }
            }
            if ($snapshot.authenticated_login -cne $ExpectedAuthenticatedLogin) { Throw-ContractError 'github_auth_identity_mismatch' }
            Assert-AuthoritativeAbsence
            Write-AtomicJson -Path $journalResolved -Value (New-Journal -State 'complete')
            $result = New-Result -Result 'deleted_verified' -Exists $false -MutationPerformed $replayMutation
        } else {
            if ($snapshot.exists) { Throw-ContractError 'repository_resurrected' }
            if ($snapshot.authenticated_login -cne $ExpectedAuthenticatedLogin) { Throw-ContractError 'github_auth_identity_mismatch' }
            Assert-AuthoritativeAbsence
            $result = New-Result -Result 'deleted_verified' -Exists $false -MutationPerformed $false
        }
    }

    if ($Json) { $result | ConvertTo-Json -Compress }
    else { [pscustomobject]$result }
    exit 0
}
catch {
    $code = if ($_.Exception.Message -match '^[a-z0-9_]+$') { $_.Exception.Message } else { 'repository_retirement_failed' }
    $failure = [ordered]@{
        schema = 'github-index.repository-retirement-error.v1'
        action = $Action
        code = $code
    }
    [Console]::Error.WriteLine(($failure | ConvertTo-Json -Compress))
    exit 2
}
