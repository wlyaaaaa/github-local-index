#requires -Version 7.0

[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $repoRoot 'tools/Invoke-ProtectedGitHubMajorAction.ps1'
$contractPath = Join-Path $repoRoot 'docs/contracts/git.protected-major-actions.md'
$agentsPath = Join-Path $repoRoot 'AGENTS.md'
$script:Failures = 0

function Assert-Equal {
    param(
        [AllowNull()][object] $Expected,
        [AllowNull()][object] $Actual,
        [string] $Name
    )
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

Assert-True (Test-Path -LiteralPath $tool -PathType Leaf) `
    'protected GitHub major-action adapter exists'
if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
    throw "$script:Failures test(s) failed"
}

. $tool

$script:Fixture = [ordered]@{
    visibility = 'PRIVATE'
    default_branch = 'main'
    ref_present = $true
    ref_oid = ('a' * 40)
    native_effects = 0
    broker_calls = [Collections.Generic.List[object]]::new()
}

function New-AdmissionFixture {
    [pscustomobject][ordered]@{
        schema = 'github-local-index.project-admission.v1'
        repo = 'synthetic-owner/protected-repo'
        remote_url = 'https://github.com/synthetic-owner/protected-repo'
        visibility = $script:Fixture.visibility
        default_branch = $script:Fixture.default_branch
        local_root = 'C:\synthetic\protected-repo'
        git_common_dir = 'C:\synthetic\protected-repo\.git'
        remote_mode = 'live'
        metadata_mode = 'live'
        refs_mode = 'live'
        decision = 'proceed'
        reasons = @()
        errors = @()
    }
}

$admissionInvoker = {
    param([string] $Repository, [string] $RepoPath)
    if ($Repository -cne 'synthetic-owner/protected-repo' -or
        $RepoPath -cne 'C:\synthetic\protected-repo') {
        throw 'unexpected admission target'
    }
    New-AdmissionFixture
}

$metadataInvoker = {
    param([string] $Repository, [bool] $AllowMissing)
    [pscustomobject]@{
        exit_code = 0
        value = [pscustomobject][ordered]@{
            id = 17001
            node_id = 'R_synthetic_protected_repo'
            full_name = 'synthetic-owner/protected-repo'
            html_url = 'https://github.com/synthetic-owner/protected-repo'
            visibility = $script:Fixture.visibility.ToLowerInvariant()
            default_branch = $script:Fixture.default_branch
        }
        stderr = ''
    }
}

$nativeInvoker = {
    param(
        [string] $Kind,
        [string] $Executable,
        [string[]] $Arguments,
        [string] $WorkingDirectory,
        [bool] $AllowFailure
    )
    if ($Kind -ne 'git') { throw "unexpected native kind: $Kind" }
    $joined = $Arguments -join ' '
    if ($joined -match 'rev-parse --verify refs/heads/protected') {
        if ($script:Fixture.ref_present) {
            return [pscustomobject]@{
                exit_code = 0
                stdout = $script:Fixture.ref_oid
                stderr = ''
            }
        }
        return [pscustomobject]@{
            exit_code = 1
            stdout = ''
            stderr = 'unknown revision'
        }
    }
    if ($joined -match 'update-ref -d refs/heads/protected') {
        $script:Fixture.native_effects++
        $script:Fixture.ref_present = $false
        return [pscustomobject]@{ exit_code = 0; stdout = ''; stderr = '' }
    }
    throw "unexpected native invocation: $joined"
}

$brokerInvoker = {
    param(
        [string] $Action,
        [string] $InputPath,
        [string] $OperationId,
        [string] $SelectedAuthorityFactor,
        [string] $SelectedAccountProvider
    )
    $input = Get-Content -LiteralPath $InputPath -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 40
    $factorClass = $SelectedAuthorityFactor.ToLowerInvariant()
    $script:Fixture.broker_calls.Add([pscustomobject]@{
        action = $Action
        input = $input
        operation_id = $OperationId
        authority_factor = $SelectedAuthorityFactor
        account_provider = $SelectedAccountProvider
    })
    if ($Action -eq 'AuthorizeMajorAction') {
        return [pscustomobject]@{
            exit_code = 0
            value = [pscustomobject]@{
                schema = 'pcconfig.secret-broker-result.v1'
                status = 'pass'
                authorization_status = 'authorized'
                authority_factor_class = $factorClass
                runtime_proof_verified = $true
                major_action_capability = [pscustomobject]@{
                    schema = if ($factorClass -eq 'runtime') {
                        'pcconfig.major-action-capability.v1'
                    }
                    else { 'pcconfig.major-action-capability.v2' }
                    capability_id = '11111111-1111-4111-8111-111111111111'
                }
            }
        }
    }
    $execute = -not [bool]$input.dry_run
    [pscustomobject]@{
        exit_code = 0
        value = [pscustomobject]@{
            schema = 'pcconfig.secret-broker-result.v1'
            status = 'pass'
            authorization_status = 'authorized'
            authority_factor_class = $factorClass
            runtime_proof_verified = $true
            capability_verified = $true
            capability_consumed = $execute
            execute_allowed = $execute
            dry_run = [bool]$input.dry_run
        }
    }
}

$script:CreateFixture = [ordered]@{
    target_present = $false
    metadata_calls = 0
    present_on_metadata_call = 0
    login = 'synthetic-owner'
    local_branch = 'main'
    local_head_oid = ('b' * 40)
    local_clean = $true
    native_effects = 0
    effect_argv = @()
    post_exit_code = 0
    post_creates_target = $true
    post_response_id = 17002
    post_response_node_id = 'R_synthetic_created_repo'
    post_response_full_name = 'synthetic-owner/created-repo'
    post_response_private = $true
    post_response_visibility = 'private'
    readback_id = 17002
    readback_node_id = 'R_synthetic_created_repo'
    readback_full_name = 'synthetic-owner/created-repo'
    readback_private = $true
    readback_visibility = 'private'
}

$createAdmissionInvoker = {
    throw 'create-repository must not use normal project admission'
}

$createMetadataInvoker = {
    param([string] $Repository, [bool] $AllowMissing)
    if ($Repository -cne 'synthetic-owner/created-repo') {
        throw "unexpected create metadata target: $Repository"
    }
    $script:CreateFixture.metadata_calls++
    if ($script:CreateFixture.present_on_metadata_call -gt 0 -and
        $script:CreateFixture.metadata_calls -ge
            $script:CreateFixture.present_on_metadata_call) {
        $script:CreateFixture.target_present = $true
    }
    if (-not $script:CreateFixture.target_present) {
        return [pscustomobject]@{
            exit_code = 1
            missing = $true
            value = $null
            stderr = 'HTTP 404: Not Found'
        }
    }
    [pscustomobject]@{
        exit_code = 0
        missing = $false
        value = [pscustomobject][ordered]@{
            id = $script:CreateFixture.readback_id
            node_id = $script:CreateFixture.readback_node_id
            full_name = $script:CreateFixture.readback_full_name
            private = $script:CreateFixture.readback_private
            visibility = $script:CreateFixture.readback_visibility
            default_branch = 'main'
        }
        stderr = ''
    }
}

$createAccountInvoker = {
    [pscustomobject]@{
        exit_code = 0
        value = [pscustomobject]@{ login = $script:CreateFixture.login }
        stderr = ''
    }
}

$createNativeInvoker = {
    param(
        [string] $Kind,
        [string] $Executable,
        [string[]] $Arguments,
        [string] $WorkingDirectory,
        [bool] $AllowFailure
    )
    $joined = $Arguments -join ' '
    if ($Kind -eq 'git') {
        if ($joined -match 'rev-parse --show-toplevel') {
            return [pscustomobject]@{
                exit_code = 0
                stdout = 'C:\synthetic\created-repo'
                stderr = ''
            }
        }
        if ($joined -match 'rev-parse --git-common-dir') {
            return [pscustomobject]@{
                exit_code = 0
                stdout = '.git'
                stderr = ''
            }
        }
        if ($joined -match 'symbolic-ref --quiet --short HEAD') {
            return [pscustomobject]@{
                exit_code = 0
                stdout = $script:CreateFixture.local_branch
                stderr = ''
            }
        }
        if ($joined -match 'rev-parse --verify HEAD') {
            return [pscustomobject]@{
                exit_code = 0
                stdout = $script:CreateFixture.local_head_oid
                stderr = ''
            }
        }
        if ($joined -match 'status --porcelain=v1') {
            return [pscustomobject]@{
                exit_code = 0
                stdout = $(if ($script:CreateFixture.local_clean) { '' }
                    else { ' M README.md' })
                stderr = ''
            }
        }
        throw "unexpected create git invocation: $joined"
    }
    if ($Kind -eq 'gh' -and $Arguments -contains 'user/repos') {
        $script:CreateFixture.native_effects++
        $script:CreateFixture.effect_argv = @($Arguments)
        if ($script:CreateFixture.post_creates_target) {
            $script:CreateFixture.target_present = $true
        }
        $postResponse = [pscustomobject][ordered]@{
            id = $script:CreateFixture.post_response_id
            node_id = $script:CreateFixture.post_response_node_id
            full_name = $script:CreateFixture.post_response_full_name
            private = $script:CreateFixture.post_response_private
            visibility = $script:CreateFixture.post_response_visibility
        }
        return [pscustomobject]@{
            exit_code = $script:CreateFixture.post_exit_code
            stdout = ($postResponse | ConvertTo-Json -Compress)
            stderr = $(if ($script:CreateFixture.post_exit_code -eq 0) { '' }
                else { 'HTTP 422: repository already exists' })
        }
    }
    throw "unexpected create native invocation: $Kind $joined"
}

$arguments = [ordered]@{
    ref = 'refs/heads/protected'
    expected_oid = ('a' * 40)
}
$proposal = New-ProtectedGitHubMajorActionProposal `
    -EffectFamily 'git-local' `
    -Operation 'delete-local-ref' `
    -Repository 'synthetic-owner/protected-repo' `
    -RepoPath 'C:\synthetic\protected-repo' `
    -Arguments $arguments `
    -Decision 'allow' `
    -Reason '顶级模型确认该 synthetic ref 可安全删除。' `
    -UserIntent '对 synthetic 仓库执行受保护删除测试。' `
    -AdmissionInvoker $admissionInvoker `
    -MetadataInvoker $metadataInvoker `
    -NativeInvoker $nativeInvoker

Assert-Equal 'github-local-index.protected-major-action-proposal.v1' `
    $proposal.schema 'Prepare emits the proposal schema'
Assert-Equal 'pcconfig.major-action-authorization-request.v1' `
    $proposal.authorization_request.schema `
    'Prepare emits the broker authorization schema'
Assert-Equal 'github.protected-major-actions.v1' `
    $proposal.authorization_request.adapter_id `
    'Prepare binds the GitHub adapter id'
Assert-Equal 'R_synthetic_protected_repo' `
    $proposal.authorization_request.stable_target.repository_node_id `
    'Prepare binds a stable provider repository id'
Assert-Equal 'codex-root' $proposal.runtime_principal `
    'Prepare selects the registered Codex root factor'
Assert-True `
    ($proposal.authorization_request.executor_sha256 -match '^[a-f0-9]{64}$') `
    'Prepare binds the adapter hash'
Assert-Equal `
    (Get-FileHash -LiteralPath $tool -Algorithm SHA256).Hash.ToLowerInvariant() `
    $proposal.authorization_request.executor_sha256 `
    'authorization binds the exact adapter script'
Assert-True `
    ($proposal.authorization_request.parameters.native_executor_sha256 -match
        '^[a-f0-9]{64}$') `
    'authorization also binds the native git executor hash'
Assert-Equal 'allow' $proposal.authorization_request.assessment.decision `
    'Prepare binds the model decision'
Assert-Equal 'execute' $proposal.authorization_request.execution_mode `
    'Prepare binds the real execution mode'
Assert-Equal $arguments.ref `
    $proposal.authorization_request.parameters.arguments.ref `
    'Prepare binds typed arguments'
Assert-Equal 'runtime_allowed' `
    $proposal.authorization_request.authorization_requirement `
    'the highest-authority allow decision maps to runtime authority'

$deleteRepositoryArguments = [ordered]@{
    expected_visibility = 'PRIVATE'
    expected_default_branch = 'main'
}
$deleteRepositoryProposal = New-ProtectedGitHubMajorActionProposal `
    -EffectFamily 'github-api' `
    -ExecutionMode 'dry_run' `
    -Operation 'delete-repository' `
    -Repository 'synthetic-owner/protected-repo' `
    -RepoPath 'C:\synthetic\protected-repo' `
    -Arguments $deleteRepositoryArguments `
    -Decision 'step_up' `
    -Reason 'synthetic semantic step-up test' `
    -UserIntent 'verify the highest-authority decision requests human presence' `
    -AdmissionInvoker $admissionInvoker `
    -MetadataInvoker $metadataInvoker `
    -NativeInvoker $nativeInvoker
Assert-Equal 'human_required' `
    $deleteRepositoryProposal.authorization_request.authorization_requirement `
    'repository deletion follows the highest-authority step-up decision'

$deleteRepositoryAllowedProposal = New-ProtectedGitHubMajorActionProposal `
    -EffectFamily 'github-api' `
    -ExecutionMode 'dry_run' `
    -Operation 'delete-repository' `
    -Repository 'synthetic-owner/protected-repo' `
    -RepoPath 'C:\synthetic\protected-repo' `
    -Arguments $deleteRepositoryArguments `
    -Decision 'allow' `
    -Reason 'synthetic semantic allow test' `
    -UserIntent 'prove the adapter does not derive human presence from effect type' `
    -AdmissionInvoker $admissionInvoker `
    -MetadataInvoker $metadataInvoker `
    -NativeInvoker $nativeInvoker
Assert-Equal 'runtime_allowed' `
    $deleteRepositoryAllowedProposal.authorization_request.authorization_requirement `
    'the same delete effect remains runtime-allowed when the authority says allow'

foreach ($blockedAssessment in @(
        @{ decision = 'deny'; error = 'model_assessment_denied' },
        @{
            decision = 'needs_evidence'
            error = 'model_assessment_needs_evidence'
        },
        @{
            decision = 'suspected_tamper'
            error = 'model_assessment_suspected_tamper'
        }
    )) {
    $blockedAssessmentObserved = ''
    try {
        New-ProtectedGitHubMajorActionProposal `
            -EffectFamily 'github-api' `
            -ExecutionMode 'dry_run' `
            -Operation 'delete-repository' `
            -Repository 'synthetic-owner/protected-repo' `
            -RepoPath 'C:\synthetic\protected-repo' `
            -Arguments $deleteRepositoryArguments `
            -Decision $blockedAssessment.decision `
            -Reason 'synthetic non-executable semantic decision test' `
            -UserIntent 'prove non-executable decisions never reach the broker' | Out-Null
    }
    catch { $blockedAssessmentObserved = $_.Exception.Message }
    Assert-Equal $blockedAssessment.error $blockedAssessmentObserved `
        "semantic $($blockedAssessment.decision) blocks proposal creation"
}

$privateToPublicArguments = [ordered]@{
    expected_visibility = 'PRIVATE'
    new_visibility = 'PUBLIC'
}
$privateToPublicProposal = New-ProtectedGitHubMajorActionProposal `
    -EffectFamily 'github-api' `
    -Operation 'set-visibility' `
    -Repository 'synthetic-owner/protected-repo' `
    -RepoPath 'C:\synthetic\protected-repo' `
    -Arguments $privateToPublicArguments `
    -Decision 'step_up' `
    -Reason 'synthetic public exposure semantic step-up test' `
    -UserIntent 'verify semantic step-up requests human presence' `
    -AdmissionInvoker $admissionInvoker `
    -MetadataInvoker $metadataInvoker `
    -NativeInvoker $nativeInvoker
Assert-Equal 'human_required' `
    $privateToPublicProposal.authorization_request.authorization_requirement `
    'PRIVATE-to-PUBLIC follows the highest-authority step-up decision'

$setDefaultBranchArguments = [ordered]@{
    expected_default_branch = 'main'
    new_default_branch = 'stable'
}
$setDefaultBranchProposal = New-ProtectedGitHubMajorActionProposal `
    -EffectFamily 'github-api' `
    -Operation 'set-default-branch' `
    -Repository 'synthetic-owner/protected-repo' `
    -RepoPath 'C:\synthetic\protected-repo' `
    -Arguments $setDefaultBranchArguments `
    -Decision 'allow' `
    -Reason 'synthetic default branch classification test' `
    -UserIntent 'verify ordinary default branch change stays unattended' `
    -AdmissionInvoker $admissionInvoker `
    -MetadataInvoker $metadataInvoker `
    -NativeInvoker $nativeInvoker
Assert-Equal 'runtime_allowed' `
    $setDefaultBranchProposal.authorization_request.authorization_requirement `
    'set-default-branch follows the highest-authority allow decision'

$renameArguments = [ordered]@{
    expected_name = 'protected-repo'
    new_name = 'renamed-repo'
    expected_visibility = 'PRIVATE'
    expected_default_branch = 'main'
    expected_target_absent = $true
}
$script:RenameApplied = $false
$script:RenameEffects = 0
$renameMetadataInvoker = {
    param([string] $Repository, [bool] $AllowMissing)
    if ($Repository -ceq 'synthetic-owner/protected-repo' -and
        -not $script:RenameApplied) {
        return [pscustomobject]@{
            exit_code = 0
            value = [pscustomobject][ordered]@{
                id = 17001
                node_id = 'R_synthetic_protected_repo'
                full_name = 'synthetic-owner/protected-repo'
                html_url = 'https://github.com/synthetic-owner/protected-repo'
                visibility = 'private'
                default_branch = 'main'
            }
            missing = $false
            stderr = ''
        }
    }
    if ($Repository -ceq 'synthetic-owner/renamed-repo') {
        if (-not $script:RenameApplied) {
            return [pscustomobject]@{
                exit_code = 1
                value = $null
                missing = $true
                stderr = 'not found'
            }
        }
        return [pscustomobject]@{
            exit_code = 0
            value = [pscustomobject][ordered]@{
                id = 17001
                node_id = 'R_synthetic_protected_repo'
                full_name = 'synthetic-owner/renamed-repo'
                html_url = 'https://github.com/synthetic-owner/renamed-repo'
                visibility = 'private'
                default_branch = 'main'
            }
            missing = $false
            stderr = ''
        }
    }
    throw "unexpected rename metadata target: $Repository"
}
$renameNativeInvoker = {
    param(
        [string] $Kind,
        [string] $Executable,
        [string[]] $Arguments,
        [string] $WorkingDirectory,
        [bool] $AllowFailure
    )
    $joined = $Arguments -join ' '
    if ($Kind -eq 'git') {
        if ($joined -match 'rev-parse --show-toplevel') {
            return [pscustomobject]@{
                exit_code = 0; stdout = 'C:\synthetic\protected-repo'; stderr = ''
            }
        }
        if ($joined -match 'symbolic-ref --quiet --short HEAD') {
            return [pscustomobject]@{ exit_code = 0; stdout = 'main'; stderr = '' }
        }
        if ($joined -match 'remote get-url --all origin') {
            return [pscustomobject]@{
                exit_code = 0
                stdout = 'https://github.com/synthetic-owner/protected-repo'
                stderr = ''
            }
        }
        if ($joined -match 'status --porcelain=v1') {
            return [pscustomobject]@{ exit_code = 0; stdout = ''; stderr = '' }
        }
        if ($joined -match 'rev-parse --verify (?:HEAD|refs/remotes/origin/main)') {
            return [pscustomobject]@{
                exit_code = 0; stdout = ('d' * 40); stderr = ''
            }
        }
        throw "unexpected rename git invocation: $joined"
    }
    if ($Kind -ne 'gh' -or
        $joined -notmatch 'api --method PATCH .*repos/synthetic-owner/protected-repo' -or
        $joined -notmatch 'name=renamed-repo') {
        throw "unexpected rename native invocation: $Kind $joined"
    }
    $script:RenameEffects++
    $script:RenameApplied = $true
    [pscustomobject]@{ exit_code = 0; stdout = '{}'; stderr = '' }
}
$renameProposal = New-ProtectedGitHubMajorActionProposal `
    -EffectFamily 'github-api' `
    -Operation 'rename-repository' `
    -Repository 'synthetic-owner/protected-repo' `
    -RepoPath 'C:\synthetic\protected-repo' `
    -Arguments $renameArguments `
    -Decision 'allow' `
    -Reason 'synthetic stable-identity repository rename' `
    -UserIntent 'verify same-repository rename stays private and unattended' `
    -AdmissionInvoker $admissionInvoker `
    -MetadataInvoker $renameMetadataInvoker `
    -NativeInvoker $renameNativeInvoker

$renameWarnAdmission = [pscustomobject][ordered]@{
    schema = 'github-local-index.project-admission.v1'
    decision = 'warn'
    remote_mode = 'live'
    metadata_mode = 'live'
    refs_mode = 'live'
    repo = 'synthetic-owner/protected-repo'
    local_root = 'C:\synthetic\protected-repo'
    default_branch = 'main'
    reasons = @('default_branch_missing_commits', 'merged_residual_branch')
    errors = @()
    worktrees = @([pscustomobject][ordered]@{
        path = 'C:\synthetic\protected-repo'
        exists = $true
        head = ('d' * 40)
        branch = 'main'
        ahead = 0
        behind = 0
        dirty_count = 0
        sync_state = 'in_sync'
        inspection_error = $false
        is_default_branch = $true
        default_head = ('d' * 40)
    })
}
Assert-True (Test-RenameAdmissionRecord `
        -Admission $renameWarnAdmission `
        -Repository 'synthetic-owner/protected-repo' `
        -RepoPath 'C:\synthetic\protected-repo') `
    'rename admits only default-clean branch-history warnings without discarding refs'
$renameWarnAdmission.reasons = @('dirty_worktree')
Assert-True (-not (Test-RenameAdmissionRecord `
        -Admission $renameWarnAdmission `
        -Repository 'synthetic-owner/protected-repo' `
        -RepoPath 'C:\synthetic\protected-repo')) `
    'rename rejects unrelated admission warnings'
Assert-Equal 'runtime_allowed' `
    $renameProposal.authorization_request.authorization_requirement `
    'same-owner repository rename follows the semantic allow decision'
Assert-Equal 'synthetic-owner/renamed-repo' `
    $renameProposal.authorization_request.preconditions.rename_target.repository `
    'rename proposal binds the absent destination slug'
Assert-True `
    ($renameProposal.authorization_request.parameters.argv -contains
        'name=renamed-repo') `
    'rename plan closes the GitHub payload to the new name'
$script:Fixture.broker_calls.Clear()
$renameExecuted = Invoke-ProtectedGitHubMajorActionProposal `
    -Proposal $renameProposal `
    -AdmissionInvoker $admissionInvoker `
    -MetadataInvoker $renameMetadataInvoker `
    -NativeInvoker $renameNativeInvoker `
    -BrokerInvoker $brokerInvoker
Assert-Equal 'pass' $renameExecuted.status `
    'rename executes after capability consumption and stable-id read-back'
Assert-Equal 1 $script:RenameEffects `
    'rename performs the exact typed effect once'
Assert-True $renameExecuted.read_back_verified `
    'rename read-back observes the same database and node identities'
$script:RenameApplied = $false

$script:Fixture.visibility = 'PUBLIC'
try {
    $publicToPrivateArguments = [ordered]@{
        expected_visibility = 'PUBLIC'
        new_visibility = 'PRIVATE'
    }
    $publicToPrivateProposal = New-ProtectedGitHubMajorActionProposal `
        -EffectFamily 'github-api' `
        -Operation 'set-visibility' `
        -Repository 'synthetic-owner/protected-repo' `
        -RepoPath 'C:\synthetic\protected-repo' `
        -Arguments $publicToPrivateArguments `
        -Decision 'allow' `
        -Reason 'synthetic private convergence classification test' `
        -UserIntent 'verify public to private remains unattended' `
        -AdmissionInvoker $admissionInvoker `
        -MetadataInvoker $metadataInvoker `
        -NativeInvoker $nativeInvoker
    Assert-Equal 'runtime_allowed' `
        $publicToPrivateProposal.authorization_request.authorization_requirement `
        'PUBLIC-to-PRIVATE follows the highest-authority allow decision'
}
finally { $script:Fixture.visibility = 'PRIVATE' }

$transferArguments = [ordered]@{
    expected_owner = 'synthetic-owner'
    new_owner = 'synthetic-destination'
}
$transferProposal = New-ProtectedGitHubMajorActionProposal `
    -EffectFamily 'github-api' `
    -Operation 'transfer-repository' `
    -Repository 'synthetic-owner/protected-repo' `
    -RepoPath 'C:\synthetic\protected-repo' `
    -Arguments $transferArguments `
    -Decision 'step_up' `
    -Reason 'synthetic transfer semantic step-up test' `
    -UserIntent 'verify semantic step-up requests human presence' `
    -AdmissionInvoker $admissionInvoker `
    -MetadataInvoker $metadataInvoker `
    -NativeInvoker $nativeInvoker
Assert-Equal 'human_required' `
    $transferProposal.authorization_request.authorization_requirement `
    'repository transfer follows the highest-authority step-up decision'
$transferPlan = Get-EffectPlan `
    -EffectFamily 'github-api' `
    -Operation 'transfer-repository' `
    -Repository 'synthetic-owner/protected-repo' `
    -RepoPath 'C:\synthetic\protected-repo' `
    -Arguments $transferArguments
Assert-True ($transferPlan.argv -contains
        'repos/synthetic-owner/protected-repo/transfer') `
    'transfer uses the dedicated GitHub transfer endpoint'
$transferReadBackRequest = [pscustomobject]@{
    effect_family = 'github-api'
    stable_target = [pscustomobject]@{
        repository = 'synthetic-owner/protected-repo'
        repository_node_id = 'R_synthetic_protected_repo'
        canonical_worktree = 'C:\synthetic\protected-repo'
    }
    parameters = [pscustomobject]@{
        operation = 'transfer-repository'
        arguments = [pscustomobject]$transferArguments
    }
}
$script:TransferReadBackRepository = ''
$transferMetadataInvoker = {
    param([string] $Repository, [bool] $AllowMissing)
    $script:TransferReadBackRepository = $Repository
    [pscustomobject]@{
        exit_code = 0
        missing = $false
        value = [pscustomobject]@{
            node_id = 'R_synthetic_protected_repo'
            full_name = 'synthetic-destination/protected-repo'
            visibility = 'private'
            default_branch = 'main'
        }
    }
}
Assert-True (Invoke-ReadBack `
        -Request $transferReadBackRequest `
        -MetadataInvoker $transferMetadataInvoker `
        -NativeInvoker $nativeInvoker) `
    'transfer read-back verifies the repository at its new owner'
Assert-Equal 'synthetic-destination/protected-repo' `
    $script:TransferReadBackRepository `
    'transfer read-back queries the new canonical repository slug'

$createArguments = [ordered]@{
    expected_absent = $true
    visibility = 'PRIVATE'
    expected_local_branch = 'main'
    expected_head_oid = ('b' * 40)
}
$createProposal = New-ProtectedGitHubMajorActionProposal `
    -EffectFamily 'github-api' `
    -Operation 'create-repository' `
    -Repository 'synthetic-owner/created-repo' `
    -RepoPath 'C:\synthetic\created-repo' `
    -Arguments $createArguments `
    -Decision 'allow' `
    -Reason '顶级模型确认先建立空 PRIVATE 远端。' `
    -UserIntent '为已验证的本地 worktree 建立空 PRIVATE GitHub 远端。' `
    -AdmissionInvoker $createAdmissionInvoker `
    -MetadataInvoker $createMetadataInvoker `
    -AccountInvoker $createAccountInvoker `
    -NativeInvoker $createNativeInvoker
Assert-Equal 'repository-slug:synthetic-owner/created-repo' `
    $createProposal.authorization_request.stable_target.resource `
    'create Prepare binds the repository slug without fabricating an ID'
$createStableTargetKeys = @(Get-MapKeys `
        -Value $createProposal.authorization_request.stable_target)
Assert-True (($createStableTargetKeys -notcontains 'repository_database_id') -and
    ($createStableTargetKeys -notcontains 'repository_node_id')) `
    'create Prepare does not fabricate precreation database or node IDs'
Assert-Equal 'synthetic-owner' `
    $createProposal.authorization_request.preconditions.authenticated_owner.login `
    'create Prepare binds the authenticated GitHub owner'
Assert-Equal 'main' `
    $createProposal.authorization_request.preconditions.local_worktree.branch `
    'create Prepare binds the clean local branch'
Assert-Equal ('b' * 40) `
    $createProposal.authorization_request.preconditions.local_worktree.head_oid `
    'create Prepare binds the local HEAD OID'
Assert-True ([bool]$createProposal.authorization_request.preconditions.target.absent) `
    'create Prepare verifies the target repository is absent'
Assert-Equal 'runtime_allowed' `
    $createProposal.authorization_request.authorization_requirement `
    'PRIVATE repository creation follows the semantic allow decision'
$createPlan = Get-EffectPlan `
    -EffectFamily 'github-api' `
    -Operation 'create-repository' `
    -Repository 'synthetic-owner/created-repo' `
    -RepoPath 'C:\synthetic\created-repo' `
    -Arguments $createArguments
$expectedCreateArgv = @(
    'api', '--method', 'POST',
    '-H', 'Accept: application/vnd.github+json',
    '-H', 'X-GitHub-Api-Version: 2022-11-28',
    'user/repos',
    '-f', 'name=created-repo',
    '-f', 'private=true',
    '-f', 'auto_init=false'
)
Assert-True (Test-ExactValue $expectedCreateArgv $createPlan.argv) `
    'create effect uses only the fixed POST user/repos argv'

$script:Fixture.broker_calls.Clear()
$script:CreateFixture.target_present = $false
$script:CreateFixture.metadata_calls = 0
$script:CreateFixture.present_on_metadata_call = 0
$script:CreateFixture.native_effects = 0
$createDryRunProposal = New-ProtectedGitHubMajorActionProposal `
    -EffectFamily 'github-api' `
    -ExecutionMode 'dry_run' `
    -Operation 'create-repository' `
    -Repository 'synthetic-owner/created-repo' `
    -RepoPath 'C:\synthetic\created-repo' `
    -Arguments $createArguments `
    -Decision 'allow' `
    -Reason '只验证建仓能力，不创建远端。' `
    -UserIntent '对空 PRIVATE 建仓请求进行无副作用验证。' `
    -AdmissionInvoker $createAdmissionInvoker `
    -MetadataInvoker $createMetadataInvoker `
    -AccountInvoker $createAccountInvoker `
    -NativeInvoker $createNativeInvoker
$createDryRun = Invoke-ProtectedGitHubMajorActionProposal `
    -Proposal $createDryRunProposal `
    -DryRun:$true `
    -AdmissionInvoker $createAdmissionInvoker `
    -MetadataInvoker $createMetadataInvoker `
    -AccountInvoker $createAccountInvoker `
    -NativeInvoker $createNativeInvoker `
    -BrokerInvoker $brokerInvoker
Assert-Equal 'dry_run_verified' $createDryRun.result `
    'create dry-run verifies authorization without invoking POST'
Assert-Equal 0 $script:CreateFixture.native_effects `
    'create dry-run never invokes the gh effect'
Assert-True (-not $script:CreateFixture.target_present) `
    'create dry-run leaves the synthetic target absent'

$script:Fixture.broker_calls.Clear()
$script:CreateFixture.target_present = $false
$script:CreateFixture.metadata_calls = 0
$script:CreateFixture.present_on_metadata_call = 0
$script:CreateFixture.native_effects = 0
$createExecuted = Invoke-ProtectedGitHubMajorActionProposal `
    -Proposal $createProposal `
    -AdmissionInvoker $createAdmissionInvoker `
    -MetadataInvoker $createMetadataInvoker `
    -AccountInvoker $createAccountInvoker `
    -NativeInvoker $createNativeInvoker `
    -BrokerInvoker $brokerInvoker
Assert-Equal 'executed_verified' $createExecuted.result `
    'create Execute succeeds only after private read-back'
Assert-Equal 1 $script:CreateFixture.native_effects `
    'create Execute invokes the fixed gh effect exactly once'
Assert-True (Test-ExactValue $expectedCreateArgv $script:CreateFixture.effect_argv) `
    'create Execute preserves the fixed argv without a shell'

$script:Fixture.broker_calls.Clear()
$script:CreateFixture.target_present = $false
$script:CreateFixture.metadata_calls = 0
$script:CreateFixture.present_on_metadata_call = 0
$script:CreateFixture.native_effects = 0
$script:CreateFixture.post_exit_code = 1
$script:CreateFixture.post_creates_target = $true
$createCollision = Invoke-ProtectedGitHubMajorActionProposal `
    -Proposal $createProposal `
    -AdmissionInvoker $createAdmissionInvoker `
    -MetadataInvoker $createMetadataInvoker `
    -AccountInvoker $createAccountInvoker `
    -NativeInvoker $createNativeInvoker `
    -BrokerInvoker $brokerInvoker
Assert-Equal 'effect_failed_state_unknown' $createCollision.result `
    'create does not claim a competing repository after POST fails'
Assert-True (-not [bool]$createCollision.mutation_performed) `
    'failed create POST does not claim this adapter performed the mutation'
Assert-True ([bool]$createCollision.mutation_may_have_occurred) `
    'failed create POST preserves the ambiguous external state'

$script:Fixture.broker_calls.Clear()
$script:CreateFixture.target_present = $false
$script:CreateFixture.metadata_calls = 0
$script:CreateFixture.native_effects = 0
$script:CreateFixture.post_exit_code = 0
$script:CreateFixture.readback_id = 17003
$createReadBackMismatch = Invoke-ProtectedGitHubMajorActionProposal `
    -Proposal $createProposal `
    -AdmissionInvoker $createAdmissionInvoker `
    -MetadataInvoker $createMetadataInvoker `
    -AccountInvoker $createAccountInvoker `
    -NativeInvoker $createNativeInvoker `
    -BrokerInvoker $brokerInvoker
Assert-Equal 'read_back_failed' $createReadBackMismatch.result `
    'create rejects a GET read-back that does not match the POST repository ID'
Assert-True ([bool]$createReadBackMismatch.mutation_performed) `
    'successful create POST remains a performed mutation when read-back mismatches'
$script:CreateFixture.readback_id = 17002

$script:Fixture.broker_calls.Clear()
$script:CreateFixture.target_present = $false
$script:CreateFixture.metadata_calls = 0
$script:CreateFixture.native_effects = 0
$script:CreateFixture.post_response_id = 'not-a-database-id'
$script:CreateFixture.readback_id = 'not-a-database-id'
$createInvalidDatabaseId = Invoke-ProtectedGitHubMajorActionProposal `
    -Proposal $createProposal `
    -AdmissionInvoker $createAdmissionInvoker `
    -MetadataInvoker $createMetadataInvoker `
    -AccountInvoker $createAccountInvoker `
    -NativeInvoker $createNativeInvoker `
    -BrokerInvoker $brokerInvoker
Assert-Equal 'read_back_failed' $createInvalidDatabaseId.result `
    'create rejects matching POST and GET responses with a nonnumeric database ID'
$script:CreateFixture.post_response_id = 17002
$script:CreateFixture.readback_id = 17002

$script:Fixture.broker_calls.Clear()
$script:CreateFixture.target_present = $false
$script:CreateFixture.metadata_calls = 0
$script:CreateFixture.present_on_metadata_call = 0
$script:CreateFixture.native_effects = 0
$createDriftProposal = New-ProtectedGitHubMajorActionProposal `
    -EffectFamily 'github-api' `
    -Operation 'create-repository' `
    -Repository 'synthetic-owner/created-repo' `
    -RepoPath 'C:\synthetic\created-repo' `
    -Arguments $createArguments `
    -Decision 'allow' `
    -Reason '验证能力消费后的目标出现漂移。' `
    -UserIntent '验证新仓库在 POST 前出现时拒绝执行。' `
    -AdmissionInvoker $createAdmissionInvoker `
    -MetadataInvoker $createMetadataInvoker `
    -AccountInvoker $createAccountInvoker `
    -NativeInvoker $createNativeInvoker
$script:CreateFixture.present_on_metadata_call = 4
$createDrift = Invoke-ProtectedGitHubMajorActionProposal `
    -Proposal $createDriftProposal `
    -AdmissionInvoker $createAdmissionInvoker `
    -MetadataInvoker $createMetadataInvoker `
    -AccountInvoker $createAccountInvoker `
    -NativeInvoker $createNativeInvoker `
    -BrokerInvoker $brokerInvoker
Assert-Equal 'target_precondition_changed_after_consume' $createDrift.error `
    'create rejects a 404-to-present drift before POST'
Assert-Equal 0 $script:CreateFixture.native_effects `
    '404-to-present drift causes zero create effects'

$script:CreateFixture.target_present = $false
$script:CreateFixture.metadata_calls = 0
$script:CreateFixture.present_on_metadata_call = 0
$script:CreateFixture.login = 'different-owner'
$loginMismatchRejected = $false
try {
    New-ProtectedGitHubMajorActionProposal `
        -EffectFamily 'github-api' `
        -Operation 'create-repository' `
        -Repository 'synthetic-owner/created-repo' `
        -RepoPath 'C:\synthetic\created-repo' `
        -Arguments $createArguments `
        -Decision 'allow' `
        -Reason 'synthetic authenticated-owner mismatch' `
        -UserIntent 'reject a mismatched GitHub account' `
        -AdmissionInvoker $createAdmissionInvoker `
        -MetadataInvoker $createMetadataInvoker `
        -AccountInvoker $createAccountInvoker `
        -NativeInvoker $createNativeInvoker | Out-Null
}
catch { $loginMismatchRejected = $_.Exception.Message -eq 'authenticated_owner_mismatch' }
Assert-True $loginMismatchRejected `
    'create rejects a slug owner that does not exactly match the authenticated login'
$script:CreateFixture.login = 'synthetic-owner'

$publicCreateArguments = [ordered]@{
    expected_absent = $true
    visibility = 'PUBLIC'
    expected_local_branch = 'main'
    expected_head_oid = ('b' * 40)
}
$publicCreateRejected = $false
try {
    New-ProtectedGitHubMajorActionProposal `
        -EffectFamily 'github-api' `
        -Operation 'create-repository' `
        -Repository 'synthetic-owner/created-repo' `
        -RepoPath 'C:\synthetic\created-repo' `
        -Arguments $publicCreateArguments `
        -Decision 'allow' `
        -Reason 'synthetic direct public create' `
        -UserIntent 'prove direct public creation is rejected' `
        -AdmissionInvoker $createAdmissionInvoker `
        -MetadataInvoker $createMetadataInvoker `
        -AccountInvoker $createAccountInvoker `
        -NativeInvoker $createNativeInvoker | Out-Null
}
catch { $publicCreateRejected = $_.Exception.Message -eq 'typed_arguments_invalid' }
Assert-True $publicCreateRejected `
    'create rejects direct PUBLIC repository creation'

$extraCreateArguments = [ordered]@{
    expected_absent = $true
    visibility = 'PRIVATE'
    expected_local_branch = 'main'
    expected_head_oid = ('b' * 40)
    shell = 'gh repo create --public'
}
$extraCreateRejected = $false
try {
    New-ProtectedGitHubMajorActionProposal `
        -EffectFamily 'github-api' `
        -Operation 'create-repository' `
        -Repository 'synthetic-owner/created-repo' `
        -RepoPath 'C:\synthetic\created-repo' `
        -Arguments $extraCreateArguments `
        -Decision 'allow' `
        -Reason 'synthetic extra create field' `
        -UserIntent 'prove create schema is exact-key' `
        -AdmissionInvoker $createAdmissionInvoker `
        -MetadataInvoker $createMetadataInvoker `
        -AccountInvoker $createAccountInvoker `
        -NativeInvoker $createNativeInvoker | Out-Null
}
catch { $extraCreateRejected = $_.Exception.Message -eq 'typed_arguments_invalid' }
Assert-True $extraCreateRejected `
    'create rejects extra fields and shell payloads'

$script:Fixture.broker_calls.Clear()
$script:Fixture.native_effects = 0
$script:Fixture.ref_present = $true
$dryRunProposal = New-ProtectedGitHubMajorActionProposal `
    -EffectFamily 'git-local' `
    -ExecutionMode 'dry_run' `
    -Operation 'delete-local-ref' `
    -Repository 'synthetic-owner/protected-repo' `
    -RepoPath 'C:\synthetic\protected-repo' `
    -Arguments $arguments `
    -Decision 'allow' `
    -Reason '顶级模型确认只验证 synthetic 请求，不执行。' `
    -UserIntent '对 synthetic 仓库执行无副作用授权验收。' `
    -AdmissionInvoker $admissionInvoker `
    -MetadataInvoker $metadataInvoker `
    -NativeInvoker $nativeInvoker
$dryRunResult = Invoke-ProtectedGitHubMajorActionProposal `
    -Proposal $dryRunProposal `
    -DryRun:$true `
    -AdmissionInvoker $admissionInvoker `
    -MetadataInvoker $metadataInvoker `
    -NativeInvoker $nativeInvoker `
    -BrokerInvoker $brokerInvoker
Assert-Equal 'pass' $dryRunResult.status 'DryRun passes exact authorization verification'
Assert-Equal 'dry_run_verified' $dryRunResult.result `
    'DryRun clearly reports verification without execution'
Assert-Equal 0 $script:Fixture.native_effects `
    'DryRun performs no adapter effect'
Assert-Equal 2 $script:Fixture.broker_calls.Count `
    'DryRun authorizes and verifies the one-time capability'
Assert-Equal 'AuthorizeMajorAction' $script:Fixture.broker_calls[0].action `
    'DryRun calls AuthorizeMajorAction first'
Assert-Equal 'pcconfig.major-action-authorization-request.v1' `
    $script:Fixture.broker_calls[0].input.schema `
    'Authorize request uses the fixed PCConfig schema'
Assert-Equal 'ConsumeMajorActionCapability' `
    $script:Fixture.broker_calls[1].action `
    'DryRun calls ConsumeMajorActionCapability second'
Assert-Equal 'pcconfig.major-action-consume-request.v1' `
    $script:Fixture.broker_calls[1].input.schema `
    'Consume request uses the fixed PCConfig schema'
Assert-True ([bool]$script:Fixture.broker_calls[1].input.dry_run) `
    'DryRun asks the broker for non-consuming verification'
Assert-Equal 'dry_run' `
    $script:Fixture.broker_calls[1].input.authorization_request.execution_mode `
    'DryRun capability is mechanically bound to dry-run mode'
Assert-Equal 'Runtime' $script:Fixture.broker_calls[0].authority_factor `
    'Auto resolves a frozen runtime-allowed request to Runtime'
Assert-Equal 'Runtime' $script:Fixture.broker_calls[1].authority_factor `
    'capability consumption preserves the resolved Runtime factor'

$script:Fixture.broker_calls.Clear()
$humanDryRun = Invoke-ProtectedGitHubMajorActionProposal `
    -Proposal $deleteRepositoryProposal `
    -DryRun:$true `
    -AdmissionInvoker $admissionInvoker `
    -MetadataInvoker $metadataInvoker `
    -NativeInvoker $nativeInvoker `
    -BrokerInvoker $brokerInvoker
Assert-Equal 'pass' $humanDryRun.status `
    'Auto can verify a frozen human-required request without an effect'
Assert-Equal 'Passkey' $script:Fixture.broker_calls[0].authority_factor `
    'Auto resolves a frozen human-required request to Passkey'
Assert-Equal 'Passkey' $script:Fixture.broker_calls[1].authority_factor `
    'capability consumption preserves the resolved human factor'
Assert-Equal 0 $script:Fixture.native_effects `
    'human-required DryRun performs no GitHub effect'

$script:Fixture.broker_calls.Clear()
$accountDryRun = Invoke-ProtectedGitHubMajorActionProposal `
    -Proposal $deleteRepositoryProposal `
    -AuthorityFactor 'Account' `
    -AccountProvider 'Google' `
    -DryRun:$true `
    -AdmissionInvoker $admissionInvoker `
    -MetadataInvoker $metadataInvoker `
    -NativeInvoker $nativeInvoker `
    -BrokerInvoker $brokerInvoker
Assert-Equal 'pass' $accountDryRun.status `
    'Account can satisfy a human-required synthetic DryRun'
Assert-Equal 'Account' $script:Fixture.broker_calls[0].authority_factor `
    'Account remains the human-factor class sent to the broker'
Assert-Equal 'Google' $script:Fixture.broker_calls[0].account_provider `
    'Google is sent separately as the Account provider'
Assert-Equal 'Account' $script:Fixture.broker_calls[1].authority_factor `
    'capability consumption preserves the Account factor class'
Assert-Equal 'Google' $script:Fixture.broker_calls[1].account_provider `
    'capability consumption preserves the Account provider'

$script:Fixture.broker_calls.Clear()
$missingAccountProvider = Invoke-ProtectedGitHubMajorActionProposal `
    -Proposal $deleteRepositoryProposal `
    -AuthorityFactor 'Account' `
    -DryRun:$true `
    -AdmissionInvoker $admissionInvoker `
    -MetadataInvoker $metadataInvoker `
    -NativeInvoker $nativeInvoker `
    -BrokerInvoker $brokerInvoker
Assert-Equal 'account_provider_required' $missingAccountProvider.error `
    'Account requires one separately selected registered provider'
Assert-Equal 0 $script:Fixture.broker_calls.Count `
    'missing Account provider fails before broker or effect'

$script:Fixture.broker_calls.Clear()
$runtimeCannotLowerHuman = Invoke-ProtectedGitHubMajorActionProposal `
    -Proposal $deleteRepositoryProposal `
    -AuthorityFactor 'runtime' `
    -DryRun:$true `
    -AdmissionInvoker $admissionInvoker `
    -MetadataInvoker $metadataInvoker `
    -NativeInvoker $nativeInvoker `
    -BrokerInvoker $brokerInvoker
Assert-Equal 'highest_authority_verification_required' `
    $runtimeCannotLowerHuman.error `
    'explicit Runtime cannot lower a semantic step-up request, regardless of case'
Assert-Equal 0 $script:Fixture.broker_calls.Count `
    'human-required Runtime mismatch fails before broker or effect'

$tamperedRequirement = $deleteRepositoryProposal | ConvertTo-Json -Depth 50 |
    ConvertFrom-Json -Depth 50
$tamperedRequirement.authorization_request.authorization_requirement =
    'runtime_allowed'
$tamperedRequirementRejected = $false
try { Assert-Proposal $tamperedRequirement }
catch {
    $tamperedRequirementRejected =
        $_.Exception.Message -eq 'proposal_invalid'
}
Assert-True $tamperedRequirementRejected `
    'a caller cannot detach the frozen requirement from the semantic decision'

$script:Fixture.broker_calls.Clear()
$modeMismatch = Invoke-ProtectedGitHubMajorActionProposal `
    -Proposal $proposal `
    -DryRun:$true `
    -AdmissionInvoker $admissionInvoker `
    -MetadataInvoker $metadataInvoker `
    -NativeInvoker $nativeInvoker `
    -BrokerInvoker $brokerInvoker
Assert-Equal 'execution_mode_mismatch' $modeMismatch.error `
    'an execute capability cannot be downgraded or replayed as DryRun'
Assert-Equal 0 $script:Fixture.broker_calls.Count `
    'execution-mode mismatch is blocked before broker authorization'

$script:Fixture.broker_calls.Clear()
$script:Fixture.native_effects = 0
$script:Fixture.ref_present = $true
$executed = Invoke-ProtectedGitHubMajorActionProposal `
    -Proposal $proposal `
    -AdmissionInvoker $admissionInvoker `
    -MetadataInvoker $metadataInvoker `
    -NativeInvoker $nativeInvoker `
    -BrokerInvoker $brokerInvoker
Assert-Equal 'pass' $executed.status `
    'Execute passes after authorization and read-back'
Assert-Equal 'executed_verified' $executed.result `
    'Execute reports verified effect'
Assert-Equal 1 $script:Fixture.native_effects `
    'Execute performs the exact typed effect once'
Assert-True (-not $script:Fixture.ref_present) `
    'Execute read-back observes the deleted synthetic ref'

$script:Fixture.broker_calls.Clear()
$script:Fixture.native_effects = 0
$script:Fixture.ref_present = $true
$ambiguousNativeInvoker = {
    param(
        [string] $Kind,
        [string] $Executable,
        [string[]] $Arguments,
        [string] $WorkingDirectory,
        [bool] $AllowFailure
    )
    $joined = $Arguments -join ' '
    if ($joined -match 'rev-parse --verify refs/heads/protected') {
        if ($script:Fixture.ref_present) {
            return [pscustomobject]@{
                exit_code = 0
                stdout = $script:Fixture.ref_oid
                stderr = ''
            }
        }
        return [pscustomobject]@{
            exit_code = 1
            stdout = ''
            stderr = 'unknown revision'
        }
    }
    if ($joined -match 'update-ref -d refs/heads/protected') {
        $script:Fixture.native_effects++
        $script:Fixture.ref_present = $false
        return [pscustomobject]@{
            exit_code = 1
            stdout = ''
            stderr = 'synthetic response loss after mutation'
        }
    }
    throw "unexpected native invocation: $joined"
}
$reconciled = Invoke-ProtectedGitHubMajorActionProposal `
    -Proposal $proposal `
    -AdmissionInvoker $admissionInvoker `
    -MetadataInvoker $metadataInvoker `
    -NativeInvoker $ambiguousNativeInvoker `
    -BrokerInvoker $brokerInvoker
Assert-Equal 'pass' $reconciled.status `
    'nonzero effect exit is reconciled against authoritative read-back'
Assert-True $reconciled.read_back_verified `
    'read-back proves the effect despite a lost native response'
Assert-True $reconciled.mutation_performed `
    'reconciled result truthfully reports the observed mutation'

$script:Fixture.broker_calls.Clear()
$script:Fixture.native_effects = 0
$script:Fixture.ref_present = $true
$verificationBroker = {
    param(
        [string] $Action,
        [string] $InputPath,
        [string] $OperationId,
        [string] $SelectedAuthorityFactor,
        [string] $SelectedAccountProvider
    )
    [pscustomobject]@{
        exit_code = 2
        value = [pscustomobject]@{
            schema = 'pcconfig.secret-broker-result.v1'
            status = 'blocked'
            error = 'highest_authority_verification_required'
            authorization_status = 'verification_required'
            execute_allowed = $false
            mutations_performed = $false
        }
    }
}
$verificationRequired = Invoke-ProtectedGitHubMajorActionProposal `
    -Proposal $proposal `
    -AdmissionInvoker $admissionInvoker `
    -MetadataInvoker $metadataInvoker `
    -NativeInvoker $nativeInvoker `
    -BrokerInvoker $verificationBroker
Assert-Equal 'highest_authority_verification_required' `
    $verificationRequired.error `
    'missing factor routes to highest-authority verification'
Assert-Equal 'verification_required' `
    $verificationRequired.authorization_status `
    'missing factor is not reported as a permanent deny'
Assert-Equal 0 $script:Fixture.native_effects `
    'missing factor performs no adapter effect'
Assert-Equal $null (Get-OptionalMapValue $verificationRequired 'reason_code') `
    'older broker responses do not invent an underlying reason'

$reasonBroker = {
    param($Action, $InputPath, $OperationId, $SelectedAuthorityFactor, $SelectedAccountProvider)
    $response = & $verificationBroker $Action $InputPath $OperationId $SelectedAuthorityFactor $SelectedAccountProvider
    $response.value | Add-Member -NotePropertyName reason_code -NotePropertyValue 'runtime_agent_not_registered'
    $response
}
$reasonRequired = Invoke-ProtectedGitHubMajorActionProposal `
    -Proposal $proposal -AdmissionInvoker $admissionInvoker `
    -MetadataInvoker $metadataInvoker -NativeInvoker $nativeInvoker `
    -BrokerInvoker $reasonBroker
Assert-Equal 'runtime_agent_not_registered' $reasonRequired.reason_code `
    'authorization preserves the broker reason without changing its meaning'
Assert-Equal 'verification_required' $reasonRequired.authorization_status `
    'a detailed reason does not grant authority'

$script:ReasonTestSuccessBroker = $brokerInvoker
$consumeReasonBroker = {
    param($Action, $InputPath, $OperationId, $SelectedAuthorityFactor, $SelectedAccountProvider)
    if ($Action -eq 'ConsumeMajorActionCapability') {
        return (& $reasonBroker $Action $InputPath $OperationId $SelectedAuthorityFactor $SelectedAccountProvider)
    }
    & $script:ReasonTestSuccessBroker $Action $InputPath $OperationId $SelectedAuthorityFactor $SelectedAccountProvider
}
$consumeReason = Invoke-ProtectedGitHubMajorActionProposal `
    -Proposal $proposal -AdmissionInvoker $admissionInvoker `
    -MetadataInvoker $metadataInvoker -NativeInvoker $nativeInvoker `
    -BrokerInvoker $consumeReasonBroker
Assert-Equal 'runtime_agent_not_registered' $consumeReason.reason_code `
    'consume preserves the broker reason too'
Assert-Equal 0 $script:Fixture.native_effects `
    'verification reasons never invoke a native effect'

$script:Fixture.visibility = 'PUBLIC'
$script:Fixture.native_effects = 0
$drifted = Invoke-ProtectedGitHubMajorActionProposal `
    -Proposal $proposal `
    -AdmissionInvoker $admissionInvoker `
    -MetadataInvoker $metadataInvoker `
    -NativeInvoker $nativeInvoker `
    -BrokerInvoker $brokerInvoker
Assert-Equal 'target_precondition_changed' $drifted.error `
    'Execute fails closed when live target state drifts'
Assert-Equal 0 $script:Fixture.native_effects `
    'target drift performs no adapter effect'
$script:Fixture.visibility = 'PRIVATE'

$invalidArguments = [ordered]@{
    ref = 'refs/heads/protected'
    expected_oid = ('a' * 40)
    shell = 'Remove-Item -Recurse C:\'
}
$invalidRejected = $false
try {
    New-ProtectedGitHubMajorActionProposal `
        -EffectFamily 'git-local' `
        -Operation 'delete-local-ref' `
        -Repository 'synthetic-owner/protected-repo' `
        -RepoPath 'C:\synthetic\protected-repo' `
        -Arguments $invalidArguments `
        -Decision 'allow' `
        -Reason 'synthetic invalid request' `
        -UserIntent 'prove arbitrary shell fields are rejected' `
        -AdmissionInvoker $admissionInvoker `
        -MetadataInvoker $metadataInvoker `
        -NativeInvoker $nativeInvoker | Out-Null
}
catch {
    $invalidRejected = $_.Exception.Message -eq 'typed_arguments_invalid'
}
Assert-True $invalidRejected `
    'typed operation rejects extra shell-string fields'

$toolText = Get-Content -LiteralPath $tool -Raw -Encoding utf8
$contractText = Get-Content -LiteralPath $contractPath -Raw -Encoding utf8
$agentsText = Get-Content -LiteralPath $agentsPath -Raw -Encoding utf8
Assert-True ($toolText.Contains(
        "'C:\ProgramData\PCConfig\AuthorityHost\tools\Invoke-SecretBroker.ps1'"
    )) 'adapter fixes the production PCConfig broker entry'
Assert-True ($toolText.Contains(
        "'C:\Program Files\PowerShell\7\pwsh.exe'"
    ) -and -not $toolText.Contains('[Environment]::ProcessPath')) `
    'adapter uses only the fixed Program Files PowerShell runtime'
Assert-True ($toolText.Contains("'-AuthorityFactor', `$SelectedAuthorityFactor")) `
    'adapter routes only the post-freeze selected factor to the broker'
Assert-True ($toolText.Contains("'-AccountProvider', `$SelectedAccountProvider")) `
    'adapter routes Account provider separately from the factor class'
Assert-True ($toolText.Contains("[string] `$AuthorityFactor = 'Auto'")) `
    'adapter defaults to post-freeze automatic factor selection'
Assert-True ($toolText.Contains(
        "[ValidateSet('Auto', 'Runtime', 'Passkey', 'Totp', 'Recovery', 'Account')]"
    ) -and -not $toolText.Contains(
        "[ValidateSet('Auto', 'Runtime', 'Passkey', 'Totp', 'Recovery', 'Google', 'Microsoft')]"
    )) 'Google and Microsoft are not independent authority-factor classes'
Assert-True ($toolText.Contains("-RuntimePrincipal', 'codex-root'")) `
    'adapter uses the unified codex-root principal'
Assert-True ($contractText -match
    '(?s)最高权限智能体.{0,500}allow.{0,160}step_up.{0,300}human_required') `
    'owner contract makes the semantic decision authoritative for human presence'
Assert-True ($contractText -match
    '(?s)不能.{0,160}(effect|操作类型).{0,260}(自行|机械).{0,160}(human_required|人类因子)') `
    'owner contract forbids effect-type-derived human requirements'
Assert-True ($contractText -match
    '(?s)Passkey.{0,120}TOTP.{0,120}Recovery.{0,120}Account.{0,260}Google.{0,100}Microsoft.{0,180}provider') `
    'owner contract records four human-factor classes and Account providers'
Assert-True ($agentsText -match
    '最高权限智能体.{0,320}人类因子.{0,220}Account provider.{0,320}git\.protected-major-actions') `
    'project entry summarizes semantic human-presence and Account-provider rules'
Assert-True ($toolText.Contains("'-c', 'core.hooksPath=NUL'")) `
    'git-local effects suppress repository hooks'
Assert-True ($toolText.Contains("'GIT_CONFIG_NOSYSTEM'")) `
    'native invocation suppresses system Git configuration'
Assert-True ($toolText.Contains('-AllowHostGitConfig $true')) `
    'read-only admission can use the host Git credential configuration'
Assert-True ($toolText.Contains("'-TargetWorktree', `$RepoPath")) `
    'protected admission scopes repository effects to the exact worktree'
Assert-True ($toolText.Contains("'GIT_REDIRECT_STDOUT'")) `
    'native invocation removes Git output redirection controls'
Assert-True ($toolText.Contains('.ArgumentList.Add(')) `
    'native execution uses direct argument-list invocation'
Assert-True ($toolText.Contains("'executor_changed_after_consume'")) `
    'final pre-effect gate rechecks adapter and native executor hashes'
Assert-True ($toolText.Contains('adapter_effect_failed_state_unknown')) `
    'ambiguous native failures are not falsely reported as zero mutation'
Assert-True ($toolText -notmatch '\bInvoke-Expression\b|\bcmd(?:\.exe)?\s+/c\b|\bpowershell(?:\.exe)?\s+-Command\b') `
    'adapter has no shell-string execution route'
Assert-True ($toolText -notmatch '\[string\]\s*\$Executable\s*=') `
    'CLI exposes no arbitrary executable parameter'

$gitConfigEnvironmentNames = @(
    'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_SYSTEM', 'GIT_CONFIG_NOSYSTEM',
    'GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0'
)
$savedGitConfigEnvironment = @{}
foreach ($name in $gitConfigEnvironmentNames) {
    $savedGitConfigEnvironment[$name] =
        [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
    $env:GIT_CONFIG_GLOBAL = 'attacker-global'
    $env:GIT_CONFIG_SYSTEM = 'attacker-system'
    $env:GIT_CONFIG_NOSYSTEM = '0'
    $env:GIT_CONFIG_COUNT = '1'
    $env:GIT_CONFIG_KEY_0 = 'alias.fetch'
    $env:GIT_CONFIG_VALUE_0 = '! attacker'
    $inspectEnvironment = @'
[ordered]@{
    global = [string]$env:GIT_CONFIG_GLOBAL
    system = [string]$env:GIT_CONFIG_SYSTEM
    no_system = [string]$env:GIT_CONFIG_NOSYSTEM
    count = [string]$env:GIT_CONFIG_COUNT
    key0 = [string]$env:GIT_CONFIG_KEY_0
    value0 = [string]$env:GIT_CONFIG_VALUE_0
    terminal_prompt = [string]$env:GIT_TERMINAL_PROMPT
} | ConvertTo-Json -Compress
'@
    $admissionEnvironment = Invoke-HardenedNative `
        -Kind pwsh `
        -Executable (Get-FixedPowerShell) `
        -Arguments @('-NoProfile', '-NonInteractive', '-Command',
            $inspectEnvironment) `
        -AllowHostGitConfig $true
    $admissionConfig = $admissionEnvironment.stdout |
        ConvertFrom-Json -Depth 5
    Assert-Equal '' $admissionConfig.global `
        'admission clears caller Git global-config overrides'
    Assert-Equal '' $admissionConfig.system `
        'admission clears caller Git system-config overrides'
    Assert-Equal '' $admissionConfig.no_system `
        'admission permits the host Git system configuration'
    Assert-Equal '' $admissionConfig.count `
        'admission clears caller injected Git config count'
    Assert-Equal '' $admissionConfig.key0 `
        'admission clears caller injected Git config keys'
    Assert-Equal '' $admissionConfig.value0 `
        'admission clears caller injected Git config values'
    Assert-Equal '0' $admissionConfig.terminal_prompt `
        'admission remains non-interactive'

    $effectEnvironment = Invoke-HardenedNative `
        -Kind pwsh `
        -Executable (Get-FixedPowerShell) `
        -Arguments @('-NoProfile', '-NonInteractive', '-Command',
            $inspectEnvironment)
    $effectConfig = $effectEnvironment.stdout | ConvertFrom-Json -Depth 5
    Assert-Equal 'NUL' $effectConfig.global `
        'effect invocation suppresses the host Git global configuration'
    Assert-Equal 'NUL' $effectConfig.system `
        'effect invocation suppresses the host Git system configuration'
    Assert-Equal '1' $effectConfig.no_system `
        'effect invocation disables the Git system configuration'
    Assert-Equal '0' $effectConfig.count `
        'effect invocation rejects injected Git config entries'
    Assert-Equal '' $effectConfig.key0 `
        'effect invocation clears injected Git config keys'
    Assert-Equal '' $effectConfig.value0 `
        'effect invocation clears injected Git config values'
}
finally {
    foreach ($name in $gitConfigEnvironmentNames) {
        $saved = $savedGitConfigEnvironment[$name]
        if ($null -eq $saved) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }
        else {
            [Environment]::SetEnvironmentVariable($name, $saved, 'Process')
        }
    }
}

$privateTemp = New-PrivateTemporaryDirectory
try {
    $privateAcl = Get-Acl -LiteralPath $privateTemp
    $privateRules = @($privateAcl.GetAccessRules(
            $true,
            $false,
            [Security.Principal.SecurityIdentifier]
        ))
    $expectedSids = @(
        [Security.Principal.WindowsIdentity]::GetCurrent().User.Value,
        'S-1-5-18',
        'S-1-5-32-544'
    )
    Assert-True ([bool]$privateAcl.AreAccessRulesProtected) `
        'capability temp directory disables inherited ACLs'
    Assert-Equal 3 $privateRules.Count `
        'capability temp directory has exactly three access principals'
    Assert-True (-not [bool]@($privateRules | Where-Object {
                $_.IdentityReference.Value -notin $expectedSids -or
                $_.AccessControlType -ne
                    [Security.AccessControl.AccessControlType]::Allow
            })) 'capability temp directory allows only user, SYSTEM and Administrators'
}
finally {
    Remove-Item -LiteralPath $privateTemp -Recurse -Force
}

if ($script:Failures -gt 0) {
    throw "$script:Failures test(s) failed"
}
Write-Host 'All protected GitHub major-action tests passed.'
