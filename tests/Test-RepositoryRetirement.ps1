#requires -Version 7.0

[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $repoRoot 'tools/Invoke-RepositoryRetirement.ps1'
$script:Failures = 0

function Assert-Equal {
    param([AllowNull()][object]$Expected, [AllowNull()][object]$Actual, [string]$Name)
    if ($Expected -ne $Actual) {
        Write-Host "FAIL: $Name"
        Write-Host "  expected: $Expected"
        Write-Host "  actual:   $Actual"
        $script:Failures++
    } else { Write-Host "PASS: $Name" }
}

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { Write-Host "FAIL: $Name"; $script:Failures++ }
    else { Write-Host "PASS: $Name" }
}

$toolText = Get-Content -LiteralPath $tool -Raw -Encoding UTF8
Assert-True ($toolText.Contains('Invoke-Gh -Arguments @(''api'', ''--method'', ''DELETE'', "repos/$Repository")')) 'live deletion uses GitHub REST DELETE repository endpoint'
Assert-True ($toolText -notmatch 'deleteRepository\s*\(\s*input') 'live deletion does not depend on a nonexistent GraphQL mutation'

function Write-Fixture {
    param([string]$Path, [bool]$Exists = $true, [string]$Fault = '')
    $value = [ordered]@{
        schema = 'github-index.repository-retirement-fixture.v1'
        authenticated_login = 'synthetic-owner'
        auth_scopes = @('delete_repo', 'repo')
        delete_permission = $true
        repository = [ordered]@{
            name_with_owner = 'synthetic-owner/private-project'
            node_id = 'R_synthetic_private_project'
            visibility = 'PRIVATE'
            default_branch = 'main'
            exists = $Exists
        }
        fault = $Fault
    }
    [IO.File]::WriteAllText($Path, (($value | ConvertTo-Json -Depth 10 -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
}

function Invoke-Tool {
    param(
        [string]$Action,
        [string]$Fixture,
        [string]$Journal,
        [string]$Approval,
        [string]$ActionCard,
        [string]$ActionCardHash,
        [string]$NodeId = 'R_synthetic_private_project',
        [string]$ExpectedLogin = 'synthetic-owner',
        [switch]$ApproveExactDeletion
    )
    $arguments = @(
        '-NoProfile', '-File', $tool,
        '-Action', $Action,
        '-Repository', 'synthetic-owner/private-project',
        '-ExpectedNodeId', $NodeId,
        '-ExpectedVisibility', 'PRIVATE',
        '-ExpectedDefaultBranch', 'main',
        '-ExpectedAuthenticatedLogin', $ExpectedLogin,
        '-ActionCardPath', $ActionCard,
        '-ActionCardHash', $ActionCardHash,
        '-JournalPath', $Journal,
        '-FixturePath', $Fixture,
        '-Json'
    )
    if ($Approval) { $arguments += @('-ApprovalPath', $Approval) }
    if ($ApproveExactDeletion) { $arguments += '-ApproveExactDeletion' }
    $output = @(& pwsh @arguments 2>&1)
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = ($output -join "`n") }
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('github-index-retirement-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $temp | Out-Null
    $fixture = Join-Path $temp 'fixture.json'
    $journal = Join-Path $temp 'journal.json'
    $approval = Join-Path $temp 'approval.json'
    $actionCard = Join-Path $temp 'action-card.json'
    $actionCardCanonical = '{"run_id":"run_synthetic","schema":"personalos:s9-wp4-release-action-card.v1","steps":[{"irreversible":true,"name":"delete_legacy_remote","operation":"github-index:delete-health-remote","owner":"github_index","request":{"default_branch":"main","node_id":"R_synthetic_private_project","repository":"synthetic-owner/private-project","transition":{"from":true,"key":"remote_exists","to":false},"visibility":"PRIVATE"}}]}'
    [IO.File]::WriteAllText($actionCard, ($actionCardCanonical + "`n"), [Text.UTF8Encoding]::new($false))
    $actionCardHash = 'sha256:' + [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($actionCardCanonical))
    ).ToLowerInvariant()
    $approvalValue = [ordered]@{
        schema = 'personalos:s9-wp4-irreversible-approval.v1'
        run_id = 'run_synthetic'
        action_card_hash = $actionCardHash
        decision = 'approved'
        approved_steps = @('delete_legacy_remote', 'delete_legacy_directory', 'delete_legacy_task')
    }
    [IO.File]::WriteAllText($approval, (($approvalValue | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))

    Write-Fixture -Path $fixture
    $inspect = Invoke-Tool -Action Inspect -Fixture $fixture -Journal $journal -ActionCard $actionCard -ActionCardHash $actionCardHash
    Assert-Equal 0 $inspect.ExitCode 'exact private repository inspection succeeds'
    $inspectJson = $inspect.Text | ConvertFrom-Json
    Assert-Equal 'present_verified' $inspectJson.result 'inspection returns verified present state'
    Assert-True (-not (Test-Path -LiteralPath $journal)) 'inspection is read-only'

    $wrongIdentity = Invoke-Tool -Action Inspect -Fixture $fixture -Journal $journal -ActionCard $actionCard -ActionCardHash $actionCardHash -NodeId 'R_wrong'
    Assert-True ($wrongIdentity.ExitCode -ne 0) 'node identity mismatch fails closed'
    Assert-True ((Get-Content -LiteralPath $fixture -Raw).Contains('"exists":true')) 'identity mismatch performs no mutation'

    $withoutApproval = Invoke-Tool -Action Delete -Fixture $fixture -Journal $journal -ActionCard $actionCard -ActionCardHash $actionCardHash
    Assert-True ($withoutApproval.ExitCode -ne 0) 'delete requires approval material'
    Assert-True ((Get-Content -LiteralPath $fixture -Raw).Contains('"exists":true')) 'missing approval leaves repository present'

    $delete = Invoke-Tool -Action Delete -Fixture $fixture -Journal $journal -Approval $approval -ActionCard $actionCard -ActionCardHash $actionCardHash -ApproveExactDeletion
    Assert-Equal 0 $delete.ExitCode 'approved exact deletion succeeds'
    $deleteJson = $delete.Text | ConvertFrom-Json
    Assert-Equal 'deleted_verified' $deleteJson.result 'delete verifies remote absence'
    Assert-True ((Get-Content -LiteralPath $fixture -Raw).Contains('"exists":false')) 'fixture remote is absent after delete'
    Assert-Equal 'complete' ((Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json).state) 'durable journal is complete'

    Remove-Item -LiteralPath $journal -Force
    Write-Fixture -Path $fixture -Exists $false
    $unexplainedAbsence = Invoke-Tool -Action Delete -Fixture $fixture -Journal $journal -Approval $approval -ActionCard $actionCard -ActionCardHash $actionCardHash -ApproveExactDeletion
    Assert-True ($unexplainedAbsence.ExitCode -ne 0) 'absence without matching durable intent is not treated as successful deletion'

    Write-Fixture -Path $fixture -Fault 'exit_after_remote_delete'
    $lostResponse = Invoke-Tool -Action Delete -Fixture $fixture -Journal $journal -Approval $approval -ActionCard $actionCard -ActionCardHash $actionCardHash -ApproveExactDeletion
    Assert-True ($lostResponse.ExitCode -ne 0) 'response loss after remote deletion reports unknown'
    Assert-True ((Get-Content -LiteralPath $fixture -Raw).Contains('"exists":false')) 'response-loss fixture applied the remote deletion'
    Assert-Equal 'prepared' ((Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json).state) 'response loss preserves prepared intent'
    $replay = Invoke-Tool -Action Delete -Fixture $fixture -Journal $journal -Approval $approval -ActionCard $actionCard -ActionCardHash $actionCardHash -ApproveExactDeletion
    Assert-Equal 0 $replay.ExitCode 'replay closes response-loss window'
    Assert-Equal 'deleted_verified' (($replay.Text | ConvertFrom-Json).result) 'replay proves deletion from matching intent'

    Remove-Item -LiteralPath $journal -Force
    Write-Fixture -Path $fixture -Fault 'permission_denied'
    $permission = Invoke-Tool -Action Delete -Fixture $fixture -Journal $journal -Approval $approval -ActionCard $actionCard -ActionCardHash $actionCardHash -ApproveExactDeletion
    Assert-True ($permission.ExitCode -ne 0) 'permission failure is not mapped to absence'
    Assert-True ((Get-Content -LiteralPath $fixture -Raw).Contains('"exists":true')) 'permission failure leaves repository present'

    Remove-Item -LiteralPath $journal -Force -ErrorAction SilentlyContinue
    Write-Fixture -Path $fixture -Fault 'exit_after_remote_delete'
    $lostResponse = Invoke-Tool -Action Delete -Fixture $fixture -Journal $journal -Approval $approval -ActionCard $actionCard -ActionCardHash $actionCardHash -ApproveExactDeletion
    Assert-True ($lostResponse.ExitCode -ne 0) 'second response-loss setup reports unknown'
    $fixtureValue = Get-Content -LiteralPath $fixture -Raw | ConvertFrom-Json -Depth 10
    $fixtureValue.repository.exists = $true
    $fixtureValue.fault = 'masked_404'
    [IO.File]::WriteAllText($fixture, (($fixtureValue | ConvertTo-Json -Depth 10 -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
    $masked = Invoke-Tool -Action Delete -Fixture $fixture -Journal $journal -Approval $approval -ActionCard $actionCard -ActionCardHash $actionCardHash -ApproveExactDeletion
    Assert-True ($masked.ExitCode -ne 0) 'masked 404 after prepared intent remains unknown'
    Assert-Equal 'prepared' ((Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json).state) 'masked 404 does not complete the deletion journal'

    $collaboratorOwner = Invoke-Tool -Action Delete -Fixture $fixture -Journal $journal -Approval $approval -ActionCard $actionCard -ActionCardHash $actionCardHash -ExpectedLogin 'synthetic-collaborator' -ApproveExactDeletion
    Assert-True ($collaboratorOwner.ExitCode -ne 0) 'prepared masked-404 replay rejects a login that is not the repository owner'
    Assert-Equal 'prepared' ((Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json).state) 'owner mismatch cannot complete the prepared journal'

    $fixtureValue = Get-Content -LiteralPath $fixture -Raw | ConvertFrom-Json -Depth 10
    $fixtureValue.fault = ''
    [IO.File]::WriteAllText($fixture, (($fixtureValue | ConvertTo-Json -Depth 10 -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
    $preparedPresentReplay = Invoke-Tool -Action Delete -Fixture $fixture -Journal $journal -Approval $approval -ActionCard $actionCard -ActionCardHash $actionCardHash -ApproveExactDeletion
    Assert-Equal 0 $preparedPresentReplay.ExitCode 'prepared journal with repository still present can resume the exact deletion'
    Assert-True ([bool](($preparedPresentReplay.Text | ConvertFrom-Json).mutation_performed)) 'resumed deletion reports that this invocation performed the mutation'

    $tamperedCard = Get-Content -LiteralPath $actionCard -Raw | ConvertFrom-Json -Depth 20
    $tamperedCard.steps[0].request.node_id = 'R_other'
    [IO.File]::WriteAllText($actionCard, (($tamperedCard | ConvertTo-Json -Depth 20 -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
    Write-Fixture -Path $fixture
    Remove-Item -LiteralPath $journal -Force
    $selfCertified = Invoke-Tool -Action Delete -Fixture $fixture -Journal $journal -Approval $approval -ActionCard $actionCard -ActionCardHash $actionCardHash -ApproveExactDeletion
    Assert-True ($selfCertified.ExitCode -ne 0) 'tampered action card cannot reuse the approved hash'
    Assert-True ((Get-Content -LiteralPath $fixture -Raw).Contains('"exists":true')) 'tampered action card performs no deletion'
}
finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}

if ($script:Failures -gt 0) { throw "$script:Failures test(s) failed" }
Write-Host 'All repository retirement tests passed.'
