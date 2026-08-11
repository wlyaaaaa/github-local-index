#requires -Version 7.0

[CmdletBinding()]
param(
    [ValidateSet('Prepare', 'Execute')]
    [string] $Mode = 'Prepare',
    [ValidateSet('git-local', 'github-api')]
    [string] $EffectFamily,
    [ValidateSet('execute', 'dry_run')]
    [string] $ExecutionMode = 'execute',
    [ValidateSet('Runtime', 'Passkey', 'Totp', 'Recovery', 'Google', 'Microsoft')]
    [string] $AuthorityFactor = 'Runtime',
    [ValidateSet(
        'delete-local-ref',
        'force-update-local-ref',
        'replace-remote-url',
        'create-repository',
        'set-visibility',
        'set-default-branch',
        'delete-repository',
        'transfer-repository'
    )]
    [string] $Operation,
    [string] $Repository,
    [string] $RepoPath,
    [string] $ArgumentsPath,
    [ValidateSet('allow', 'deny')]
    [string] $Decision,
    [string] $Reason,
    [string] $UserIntent,
    [string] $ProposalPath,
    [string] $OutputPath,
    [switch] $DryRun,
    [switch] $Json
)

[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:AdapterId = 'github.protected-major-actions.v1'
$script:OwnerId = 'github'
$script:BrokerEntry = `
    'C:\ProgramData\PCConfig\AuthorityHost\tools\Invoke-SecretBroker.ps1'
$script:AdmissionEntry = Join-Path $PSScriptRoot 'Get-ProjectAdmission.ps1'
$script:AdapterEntry = [IO.Path]::GetFullPath($PSCommandPath)
$script:ResultSchema = 'github-local-index.protected-major-action-result.v1'
$script:ProposalSchema = `
    'github-local-index.protected-major-action-proposal.v1'
$script:AuthorizationSchema = `
    'pcconfig.major-action-authorization-request.v1'
$script:ConsumeSchema = 'pcconfig.major-action-consume-request.v1'
$script:AuthorityFactor = $AuthorityFactor
$script:Utf8NoBom = [Text.UTF8Encoding]::new($false)

function Throw-ProtectedActionError {
    param([Parameter(Mandatory)][string] $Code)
    throw [InvalidOperationException]::new($Code)
}

function Get-MapKeys {
    param([Parameter(Mandatory)][object] $Value)
    if ($Value -is [Collections.IDictionary]) {
        return @($Value.Keys | ForEach-Object { [string]$_ })
    }
    return @($Value.PSObject.Properties.Name)
}

function Test-ExactKeys {
    param(
        [Parameter(Mandatory)][object] $Value,
        [Parameter(Mandatory)][string[]] $Expected
    )
    $actual = @(Get-MapKeys -Value $Value | Sort-Object -CaseSensitive)
    $wanted = @($Expected | Sort-Object -CaseSensitive)
    return (($actual -join "`n") -ceq ($wanted -join "`n"))
}

function Get-MapValue {
    param(
        [Parameter(Mandatory)][object] $Value,
        [Parameter(Mandatory)][string] $Name
    )
    if ($Value -is [Collections.IDictionary]) { return $Value[$Name] }
    return $Value.$Name
}

function Get-OptionalMapValue {
    param(
        [AllowNull()][object] $Value,
        [Parameter(Mandatory)][string] $Name,
        [AllowNull()][object] $Default = $null
    )
    if ($null -eq $Value) { return $Default }
    if ($Value -is [Collections.IDictionary]) {
        if ($Value.Contains($Name)) { return $Value[$Name] }
        return $Default
    }
    $property = $Value.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    $property.Value
}

function ConvertTo-CanonicalNode {
    param([AllowNull()][object] $Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object -CaseSensitive)) {
            $result[[string]$key] = ConvertTo-CanonicalNode $Value[$key]
        }
        return $result
    }
    if ($Value -is [pscustomobject]) {
        $result = [ordered]@{}
        foreach ($property in @(
                $Value.PSObject.Properties | Sort-Object Name -CaseSensitive
            )) {
            $result[$property.Name] = ConvertTo-CanonicalNode $property.Value
        }
        return $result
    }
    if ($Value -is [Collections.IEnumerable] -and
        $Value -isnot [string]) {
        $items = [Collections.Generic.List[object]]::new()
        foreach ($item in $Value) {
            $items.Add((ConvertTo-CanonicalNode $item))
        }
        return ,$items.ToArray()
    }
    return $Value
}

function ConvertTo-CanonicalJson {
    param([Parameter(Mandatory)][object] $Value)
    ConvertTo-CanonicalNode $Value | ConvertTo-Json -Depth 50 -Compress
}

function Test-ExactValue {
    param(
        [Parameter(Mandatory)][object] $Left,
        [Parameter(Mandatory)][object] $Right
    )
    (ConvertTo-CanonicalJson $Left) -ceq (ConvertTo-CanonicalJson $Right)
}

function Read-BoundedJsonObject {
    param([Parameter(Mandatory)][string] $Path)
    $resolved = [IO.Path]::GetFullPath($Path)
    $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
    if ($item.PSIsContainer -or $item.LinkType -or $item.Length -gt 262144) {
        Throw-ProtectedActionError 'input_json_invalid'
    }
    try {
        $value = Get-Content -LiteralPath $resolved -Raw -Encoding utf8 |
            ConvertFrom-Json -Depth 50
    }
    catch { Throw-ProtectedActionError 'input_json_invalid' }
    if ($null -eq $value -or $value -isnot [pscustomobject]) {
        Throw-ProtectedActionError 'input_json_invalid'
    }
    $value
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][object] $Value
    )
    $resolved = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $resolved
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        Throw-ProtectedActionError 'output_parent_missing'
    }
    [IO.File]::WriteAllText(
        $resolved,
        (($Value | ConvertTo-Json -Depth 50) + "`n"),
        $script:Utf8NoBom
    )
}

function New-PrivateTemporaryDirectory {
    $path = Join-Path ([IO.Path]::GetTempPath()) (
        'protected-github-major-action-' + [guid]::NewGuid().ToString('N')
    )
    [void](New-Item -ItemType Directory -Path $path -ErrorAction Stop)
    try {
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $allowedSids = @(
            $currentSid,
            [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
            [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
        )
        $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit `
            -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetOwner($currentSid)
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in $allowedSids) {
            $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                $sid,
                [Security.AccessControl.FileSystemRights]::FullControl,
                $inheritance,
                [Security.AccessControl.PropagationFlags]::None,
                [Security.AccessControl.AccessControlType]::Allow
            )
            [void]$acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $path -AclObject $acl
        $observed = Get-Acl -LiteralPath $path
        $observedRules = @($observed.GetAccessRules(
                $true,
                $false,
                [Security.Principal.SecurityIdentifier]
            ))
        $allowedValues = @($allowedSids | ForEach-Object { $_.Value })
        $unsafeRule = @($observedRules | Where-Object {
                $_.IdentityReference.Value -notin $allowedValues -or
                $_.AccessControlType -ne
                    [Security.AccessControl.AccessControlType]::Allow
            })
        if (-not $observed.AreAccessRulesProtected -or
            $observedRules.Count -ne 3 -or $unsafeRule.Count -ne 0) {
            Throw-ProtectedActionError 'private_temp_acl_invalid'
        }
        [IO.Path]::GetFullPath($path)
    }
    catch {
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Get-FixedPowerShell {
    $resolved = [IO.Path]::GetFullPath(
        'C:\Program Files\PowerShell\7\pwsh.exe'
    )
    if (Test-Path -LiteralPath $resolved -PathType Leaf) { return $resolved }
    Throw-ProtectedActionError 'fixed_powershell_missing'
}

function Get-FixedExecutor {
    param([Parameter(Mandatory)][ValidateSet('git', 'gh')][string] $Kind)
    $candidates = if ($Kind -eq 'git') {
        @(
            'C:\Program Files\Git\cmd\git.exe',
            'C:\Program Files\Git\bin\git.exe'
        )
    }
    else {
        @(
            'E:\Scoop\apps\gh\current\bin\gh.exe',
            'C:\Program Files\GitHub CLI\gh.exe'
        )
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    Throw-ProtectedActionError "fixed_${Kind}_executor_missing"
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string] $Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Invoke-HardenedNative {
    param(
        [Parameter(Mandatory)][ValidateSet('git', 'gh', 'pwsh')]
        [string] $Kind,
        [Parameter(Mandatory)][string] $Executable,
        [Parameter(Mandatory)][string[]] $Arguments,
        [string] $WorkingDirectory = $PSScriptRoot,
        [bool] $AllowFailure = $false,
        [bool] $AllowHostGitConfig = $false
    )
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = [IO.Path]::GetFullPath($Executable)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
    foreach ($argument in $Arguments) {
        [void]$start.ArgumentList.Add([string]$argument)
    }
    foreach ($name in @(
            'GIT_DIR', 'GIT_COMMON_DIR', 'GIT_WORK_TREE',
            'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES',
            'GIT_EXEC_PATH', 'GIT_EXTERNAL_DIFF', 'GIT_DIFF_OPTS',
            'GIT_SSH', 'GIT_SSH_COMMAND', 'GIT_ASKPASS', 'SSH_ASKPASS',
            'GIT_REDIRECT_STDIN', 'GIT_REDIRECT_STDOUT',
            'GIT_REDIRECT_STDERR', 'GH_HOST', 'GH_EDITOR', 'GH_PAGER',
            'GIT_EDITOR', 'PAGER', 'GIT_CONFIG_NOSYSTEM',
            'GIT_CONFIG_SYSTEM', 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_COUNT'
        )) {
        [void]$start.Environment.Remove($name)
    }
    foreach ($name in @($start.Environment.Keys)) {
        if ([string]$name -cmatch '^GIT_CONFIG_(?:KEY|VALUE)_[0-9]+$') {
            [void]$start.Environment.Remove([string]$name)
        }
    }
    if (-not $AllowHostGitConfig) {
        $start.Environment['GIT_CONFIG_NOSYSTEM'] = '1'
        $start.Environment['GIT_CONFIG_SYSTEM'] = 'NUL'
        $start.Environment['GIT_CONFIG_GLOBAL'] = 'NUL'
        $start.Environment['GIT_CONFIG_COUNT'] = '0'
    }
    $start.Environment['GIT_TERMINAL_PROMPT'] = '0'
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) {
        Throw-ProtectedActionError 'native_process_start_failed'
    }
    $process.StandardInput.Close()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult().Trim()
    $stderr = $stderrTask.GetAwaiter().GetResult().Trim()
    $exitCode = $process.ExitCode
    $process.Dispose()
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        Throw-ProtectedActionError "${Kind}_invocation_failed"
    }
    [pscustomobject]@{
        exit_code = $exitCode
        stdout = $stdout
        stderr = $stderr
    }
}

function Invoke-NativeAdapter {
    param(
        [Parameter(Mandatory)][scriptblock] $Invoker,
        [Parameter(Mandatory)][string] $Kind,
        [Parameter(Mandatory)][string] $Executable,
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [bool] $AllowFailure = $false
    )
    & $Invoker `
        -Kind $Kind `
        -Executable $Executable `
        -Arguments $Arguments `
        -WorkingDirectory $WorkingDirectory `
        -AllowFailure $AllowFailure
}

function Get-DefaultAdmissionInvoker {
    {
        param([string] $Repository, [string] $RepoPath)
        $pwsh = Get-FixedPowerShell
        $result = Invoke-HardenedNative `
            -Kind pwsh `
            -Executable $pwsh `
            -Arguments @(
                '-NoProfile', '-NonInteractive', '-File',
                $script:AdmissionEntry,
                '-Repo', $Repository,
                '-RepoPath', $RepoPath,
                '-LiveMetadata', '-RefreshRefs', '-Json'
            ) `
            -WorkingDirectory $PSScriptRoot `
            -AllowFailure $true `
            -AllowHostGitConfig $true
        try { $record = $result.stdout | ConvertFrom-Json -Depth 30 }
        catch { Throw-ProtectedActionError 'project_admission_invalid' }
        if ($result.exit_code -ne 0 -or $record.decision -ne 'proceed') {
            Throw-ProtectedActionError 'project_admission_blocked'
        }
        $record
    }
}

function Get-DefaultMetadataInvoker {
    {
        param([string] $Repository, [bool] $AllowMissing)
        $gh = Get-FixedExecutor -Kind gh
        $result = Invoke-HardenedNative `
            -Kind gh `
            -Executable $gh `
            -Arguments @(
                'api', '--method', 'GET',
                '-H', 'Accept: application/vnd.github+json',
                '-H', 'X-GitHub-Api-Version: 2022-11-28',
                "repos/$Repository"
            ) `
            -WorkingDirectory $PSScriptRoot `
            -AllowFailure $true
        if ($result.exit_code -ne 0) {
            $missing = $AllowMissing -and
                (($result.stderr + $result.stdout) -match '(?i)HTTP\s+404')
            return [pscustomobject]@{
                exit_code = $result.exit_code
                missing = $missing
                value = $null
                stderr = $result.stderr
            }
        }
        try { $value = $result.stdout | ConvertFrom-Json -Depth 30 }
        catch { Throw-ProtectedActionError 'github_metadata_invalid' }
        [pscustomobject]@{
            exit_code = 0
            missing = $false
            value = $value
            stderr = ''
        }
    }
}

function Get-DefaultAccountInvoker {
    {
        $gh = Get-FixedExecutor -Kind gh
        $result = Invoke-HardenedNative `
            -Kind gh `
            -Executable $gh `
            -Arguments @(
                'api', '--method', 'GET',
                '-H', 'Accept: application/vnd.github+json',
                '-H', 'X-GitHub-Api-Version: 2022-11-28',
                'user'
            ) `
            -WorkingDirectory $PSScriptRoot `
            -AllowFailure $true
        if ($result.exit_code -ne 0) {
            return [pscustomobject]@{
                exit_code = $result.exit_code
                value = $null
                stderr = $result.stderr
            }
        }
        try { $value = $result.stdout | ConvertFrom-Json -Depth 30 }
        catch { Throw-ProtectedActionError 'github_authenticated_account_invalid' }
        [pscustomobject]@{
            exit_code = 0
            value = $value
            stderr = ''
        }
    }
}

function Get-DefaultNativeInvoker {
    {
        param(
            [string] $Kind,
            [string] $Executable,
            [string[]] $Arguments,
            [string] $WorkingDirectory,
            [bool] $AllowFailure
        )
        Invoke-HardenedNative `
            -Kind $Kind `
            -Executable $Executable `
            -Arguments $Arguments `
            -WorkingDirectory $WorkingDirectory `
            -AllowFailure $AllowFailure
    }
}

function Get-DefaultBrokerInvoker {
    {
        param([string] $Action, [string] $InputPath, [string] $OperationId)
        if (-not (Test-Path -LiteralPath $script:BrokerEntry -PathType Leaf)) {
            Throw-ProtectedActionError 'authority_broker_unavailable'
        }
        $pwsh = Get-FixedPowerShell
        $brokerArguments = @(
            '-NoProfile', '-NonInteractive', '-File',
            $script:BrokerEntry,
            '-Action', $Action,
            '-AuthorityFactor', $script:AuthorityFactor,
            '-InputPath', $InputPath,
            '-OperationId', $OperationId,
            '-Json'
        )
        if ($script:AuthorityFactor -ceq 'Runtime') {
            $brokerArguments += @('-RuntimePrincipal', 'codex-root')
        }
        $result = Invoke-HardenedNative `
            -Kind pwsh `
            -Executable $pwsh `
            -Arguments $brokerArguments `
            -WorkingDirectory $PSScriptRoot `
            -AllowFailure $true
        try { $value = $result.stdout | ConvertFrom-Json -Depth 50 }
        catch { Throw-ProtectedActionError 'authority_broker_response_invalid' }
        [pscustomobject]@{ exit_code = $result.exit_code; value = $value }
    }
}

function Assert-RepositorySlug {
    param([Parameter(Mandatory)][string] $Repository)
    if ($Repository -cnotmatch `
        '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]{1,100}$') {
        Throw-ProtectedActionError 'repository_invalid'
    }
}

function Assert-GitOid {
    param([Parameter(Mandatory)][string] $Oid)
    if ($Oid -cnotmatch '^(?:[a-f0-9]{40}|[a-f0-9]{64})$') {
        Throw-ProtectedActionError 'typed_arguments_invalid'
    }
}

function Assert-GitRef {
    param([Parameter(Mandatory)][string] $Ref)
    if ($Ref -cnotmatch '^refs/(?:heads|tags)/[A-Za-z0-9][A-Za-z0-9._/-]{0,240}$' -or
        $Ref.Contains('..') -or $Ref.Contains('@{') -or
        $Ref.EndsWith('.') -or $Ref.EndsWith('/') -or
        $Ref.Contains('//') -or $Ref.Contains('\')) {
        Throw-ProtectedActionError 'typed_arguments_invalid'
    }
}

function Assert-GitBranchName {
    param([Parameter(Mandatory)][string] $Branch)
    if ($Branch -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,240}$' -or
        $Branch.Contains('..') -or $Branch.Contains('@{') -or
        $Branch.EndsWith('.') -or $Branch.EndsWith('/') -or
        $Branch.Contains('//') -or $Branch.Contains('\')) {
        Throw-ProtectedActionError 'typed_arguments_invalid'
    }
}

function Assert-TypedArguments {
    param(
        [Parameter(Mandatory)][string] $EffectFamily,
        [Parameter(Mandatory)][string] $Operation,
        [Parameter(Mandatory)][object] $Arguments
    )
    $allowed = if ($EffectFamily -eq 'git-local') {
        @('delete-local-ref', 'force-update-local-ref', 'replace-remote-url')
    }
    else {
        @(
            'create-repository', 'set-visibility', 'set-default-branch', 'delete-repository',
            'transfer-repository'
        )
    }
    if ($Operation -notin $allowed) {
        Throw-ProtectedActionError 'effect_family_operation_mismatch'
    }
    $expectedKeys = switch ($Operation) {
        'delete-local-ref' { @('ref', 'expected_oid') }
        'force-update-local-ref' { @('ref', 'expected_old_oid', 'new_oid') }
        'replace-remote-url' { @('remote', 'expected_url', 'new_url') }
        'create-repository' {
            @(
                'expected_absent', 'visibility', 'expected_local_branch',
                'expected_head_oid'
            )
        }
        'set-visibility' { @('expected_visibility', 'new_visibility') }
        'set-default-branch' {
            @('expected_default_branch', 'new_default_branch')
        }
        'delete-repository' {
            @('expected_visibility', 'expected_default_branch')
        }
        'transfer-repository' { @('expected_owner', 'new_owner') }
    }
    if (-not (Test-ExactKeys -Value $Arguments -Expected $expectedKeys)) {
        Throw-ProtectedActionError 'typed_arguments_invalid'
    }
    switch ($Operation) {
        'delete-local-ref' {
            Assert-GitRef ([string](Get-MapValue $Arguments 'ref'))
            Assert-GitOid ([string](Get-MapValue $Arguments 'expected_oid'))
        }
        'force-update-local-ref' {
            Assert-GitRef ([string](Get-MapValue $Arguments 'ref'))
            Assert-GitOid ([string](Get-MapValue $Arguments 'expected_old_oid'))
            Assert-GitOid ([string](Get-MapValue $Arguments 'new_oid'))
        }
        'replace-remote-url' {
            $remote = [string](Get-MapValue $Arguments 'remote')
            $expected = [string](Get-MapValue $Arguments 'expected_url')
            $new = [string](Get-MapValue $Arguments 'new_url')
            if ($remote -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or
                $expected.Length -gt 2048 -or $new.Length -gt 2048 -or
                $expected -notmatch '^(?:https://github\.com/|git@github\.com:)' -or
                $new -notmatch '^(?:https://github\.com/|git@github\.com:)') {
                Throw-ProtectedActionError 'typed_arguments_invalid'
            }
        }
        'create-repository' {
            $expectedAbsent = Get-MapValue $Arguments 'expected_absent'
            $visibility = [string](Get-MapValue $Arguments 'visibility')
            if ($expectedAbsent -isnot [bool] -or $expectedAbsent -ne $true -or
                $visibility -cne 'PRIVATE') {
                Throw-ProtectedActionError 'typed_arguments_invalid'
            }
            Assert-GitBranchName ([string](Get-MapValue `
                    $Arguments 'expected_local_branch'))
            Assert-GitOid ([string](Get-MapValue $Arguments 'expected_head_oid'))
        }
        'set-visibility' {
            $old = [string](Get-MapValue $Arguments 'expected_visibility')
            $new = [string](Get-MapValue $Arguments 'new_visibility')
            if ($old.ToUpperInvariant() -notin @('PUBLIC', 'PRIVATE', 'INTERNAL') -or
                $new.ToUpperInvariant() -notin @('PUBLIC', 'PRIVATE', 'INTERNAL') -or
                $old -ieq $new) {
                Throw-ProtectedActionError 'typed_arguments_invalid'
            }
        }
        'set-default-branch' {
            foreach ($name in @('expected_default_branch', 'new_default_branch')) {
                $branch = [string](Get-MapValue $Arguments $name)
                if ($branch -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,240}$' -or
                    $branch.Contains('..') -or $branch.Contains('@{')) {
                    Throw-ProtectedActionError 'typed_arguments_invalid'
                }
            }
        }
        'delete-repository' {
            $visibility = [string](Get-MapValue $Arguments 'expected_visibility')
            $branch = [string](Get-MapValue $Arguments 'expected_default_branch')
            if ($visibility.ToUpperInvariant() -notin @(
                    'PUBLIC', 'PRIVATE', 'INTERNAL'
                ) -or [string]::IsNullOrWhiteSpace($branch)) {
                Throw-ProtectedActionError 'typed_arguments_invalid'
            }
        }
        'transfer-repository' {
            foreach ($name in @('expected_owner', 'new_owner')) {
                $owner = [string](Get-MapValue $Arguments $name)
                if ($owner -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}$') {
                    Throw-ProtectedActionError 'typed_arguments_invalid'
                }
            }
        }
    }
}

function Get-GitArgumentsPrefix {
    param([Parameter(Mandatory)][string] $RepoPath)
    @(
        '--no-pager',
        '-c', 'core.hooksPath=NUL',
        '-c', 'credential.helper=',
        '-c', 'core.pager=',
        '-C', [IO.Path]::GetFullPath($RepoPath)
    )
}

function Get-EffectPlan {
    param(
        [Parameter(Mandatory)][string] $EffectFamily,
        [Parameter(Mandatory)][string] $Operation,
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $RepoPath,
        [Parameter(Mandatory)][object] $Arguments
    )
    Assert-TypedArguments $EffectFamily $Operation $Arguments
    if ($EffectFamily -eq 'git-local') {
        $executable = Get-FixedExecutor -Kind git
        $argv = @(Get-GitArgumentsPrefix $RepoPath)
        switch ($Operation) {
            'delete-local-ref' {
                $argv += @(
                    'update-ref', '-d',
                    [string](Get-MapValue $Arguments 'ref'),
                    [string](Get-MapValue $Arguments 'expected_oid')
                )
            }
            'force-update-local-ref' {
                $argv += @(
                    'update-ref',
                    [string](Get-MapValue $Arguments 'ref'),
                    [string](Get-MapValue $Arguments 'new_oid'),
                    [string](Get-MapValue $Arguments 'expected_old_oid')
                )
            }
            'replace-remote-url' {
                $argv += @(
                    'remote', 'set-url',
                    [string](Get-MapValue $Arguments 'remote'),
                    [string](Get-MapValue $Arguments 'new_url')
                )
            }
        }
        return [pscustomobject][ordered]@{
            kind = 'git'
            executable = $executable
            native_executor_sha256 = Get-FileSha256 $executable
            argv = $argv
        }
    }
    $executable = Get-FixedExecutor -Kind gh
    $endpoint = switch ($Operation) {
        'create-repository' { 'user/repos' }
        'transfer-repository' { "repos/$Repository/transfer" }
        default { "repos/$Repository" }
    }
    $method = switch ($Operation) {
        'create-repository' { 'POST' }
        'delete-repository' { 'DELETE' }
        'transfer-repository' { 'POST' }
        default { 'PATCH' }
    }
    $base = @(
        'api', '--method', $method,
        '-H', 'Accept: application/vnd.github+json',
        '-H', 'X-GitHub-Api-Version: 2022-11-28',
        $endpoint
    )
    switch ($Operation) {
        'create-repository' {
            $name = $Repository.Split('/')[1]
            $base += @(
                '-f', "name=$name",
                '-f', 'private=true',
                '-f', 'auto_init=false'
            )
        }
        'set-visibility' {
            $base += @(
                '-f', ('visibility=' +
                    ([string](Get-MapValue $Arguments 'new_visibility')).ToLowerInvariant())
            )
        }
        'set-default-branch' {
            $base += @(
                '-f', ('default_branch=' +
                    [string](Get-MapValue $Arguments 'new_default_branch'))
            )
        }
        'transfer-repository' {
            $base += @(
                '-f', ('new_owner=' +
                    [string](Get-MapValue $Arguments 'new_owner'))
            )
        }
    }
    [pscustomobject][ordered]@{
        kind = 'gh'
        executable = $executable
        native_executor_sha256 = Get-FileSha256 $executable
        argv = $base
    }
}

function Get-NormalizedIdentity {
    param(
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $RepoPath,
        [Parameter(Mandatory)][scriptblock] $AdmissionInvoker,
        [Parameter(Mandatory)][scriptblock] $MetadataInvoker
    )
    Assert-RepositorySlug $Repository
    $admission = & $AdmissionInvoker $Repository $RepoPath
    if ($null -eq $admission -or
        $admission.schema -cne 'github-local-index.project-admission.v1' -or
        $admission.decision -cne 'proceed' -or
        $admission.remote_mode -cne 'live' -or
        $admission.metadata_mode -cne 'live' -or
        $admission.refs_mode -cne 'live' -or
        [string]$admission.repo -ine $Repository) {
        Throw-ProtectedActionError 'project_admission_blocked'
    }
    $metadataResult = & $MetadataInvoker $Repository $false
    if ($metadataResult.exit_code -ne 0 -or $null -eq $metadataResult.value) {
        Throw-ProtectedActionError 'github_metadata_unavailable'
    }
    $metadata = $metadataResult.value
    if ([string]$metadata.full_name -ine $Repository -or
        [string]::IsNullOrWhiteSpace([string]$metadata.node_id) -or
        $null -eq $metadata.id -or
        [string]$admission.visibility -ine [string]$metadata.visibility -or
        [string]$admission.default_branch -cne
            [string]$metadata.default_branch -or
        [IO.Path]::GetFullPath([string]$admission.local_root) -ine
            [IO.Path]::GetFullPath($RepoPath)) {
        Throw-ProtectedActionError 'stable_repository_identity_mismatch'
    }
    [pscustomobject][ordered]@{
        admission = [pscustomobject][ordered]@{
            repo = ([string]$admission.repo).ToLowerInvariant()
            remote_url = [string]$admission.remote_url
            visibility = ([string]$admission.visibility).ToUpperInvariant()
            default_branch = [string]$admission.default_branch
            canonical_worktree = [IO.Path]::GetFullPath(
                [string]$admission.local_root
            )
            git_common_dir = [IO.Path]::GetFullPath(
                [string]$admission.git_common_dir
            )
            decision = 'proceed'
            remote_mode = 'live'
            metadata_mode = 'live'
            refs_mode = 'live'
        }
        provider = [pscustomobject][ordered]@{
            repository = ([string]$metadata.full_name).ToLowerInvariant()
            repository_database_id = [string]$metadata.id
            repository_node_id = [string]$metadata.node_id
            html_url = [string]$metadata.html_url
            visibility = ([string]$metadata.visibility).ToUpperInvariant()
            default_branch = [string]$metadata.default_branch
        }
    }
}

function Get-CreateRepositoryLocalWorktree {
    param(
        [Parameter(Mandatory)][string] $RepoPath,
        [Parameter(Mandatory)][object] $Arguments,
        [Parameter(Mandatory)][scriptblock] $NativeInvoker
    )
    $requestedWorktree = [IO.Path]::GetFullPath($RepoPath)
    $git = Get-FixedExecutor -Kind git
    $prefix = @(Get-GitArgumentsPrefix $requestedWorktree)
    $topLevel = Invoke-NativeAdapter `
        -Invoker $NativeInvoker -Kind git -Executable $git `
        -Arguments ($prefix + @('rev-parse', '--show-toplevel')) `
        -WorkingDirectory $requestedWorktree -AllowFailure $true
    if ($topLevel.exit_code -ne 0 -or
        [string]::IsNullOrWhiteSpace([string]$topLevel.stdout)) {
        Throw-ProtectedActionError 'create_repository_local_worktree_invalid'
    }
    try {
        $canonicalWorktree = [IO.Path]::GetFullPath($topLevel.stdout.Trim())
    }
    catch { Throw-ProtectedActionError 'create_repository_local_worktree_invalid' }
    if ($canonicalWorktree -cne $requestedWorktree) {
        Throw-ProtectedActionError 'create_repository_local_worktree_invalid'
    }
    $commonDir = Invoke-NativeAdapter `
        -Invoker $NativeInvoker -Kind git -Executable $git `
        -Arguments ($prefix + @('rev-parse', '--git-common-dir')) `
        -WorkingDirectory $requestedWorktree -AllowFailure $true
    if ($commonDir.exit_code -ne 0 -or
        [string]::IsNullOrWhiteSpace([string]$commonDir.stdout)) {
        Throw-ProtectedActionError 'create_repository_local_worktree_invalid'
    }
    try {
        $commonDirText = $commonDir.stdout.Trim()
        $gitCommonDir = if ([IO.Path]::IsPathRooted($commonDirText)) {
            [IO.Path]::GetFullPath($commonDirText)
        }
        else {
            [IO.Path]::GetFullPath((Join-Path $canonicalWorktree $commonDirText))
        }
    }
    catch { Throw-ProtectedActionError 'create_repository_local_worktree_invalid' }
    $branchResult = Invoke-NativeAdapter `
        -Invoker $NativeInvoker -Kind git -Executable $git `
        -Arguments ($prefix + @('symbolic-ref', '--quiet', '--short', 'HEAD')) `
        -WorkingDirectory $requestedWorktree -AllowFailure $true
    $branch = $branchResult.stdout.Trim()
    if ($branchResult.exit_code -ne 0 -or
        [string]::IsNullOrWhiteSpace($branch)) {
        Throw-ProtectedActionError 'create_repository_local_worktree_invalid'
    }
    try { Assert-GitBranchName $branch }
    catch { Throw-ProtectedActionError 'create_repository_local_worktree_invalid' }
    if ($branch -cne [string](Get-MapValue $Arguments 'expected_local_branch')) {
        Throw-ProtectedActionError 'operation_precondition_mismatch'
    }
    $headResult = Invoke-NativeAdapter `
        -Invoker $NativeInvoker -Kind git -Executable $git `
        -Arguments ($prefix + @('rev-parse', '--verify', 'HEAD')) `
        -WorkingDirectory $requestedWorktree -AllowFailure $true
    $headOid = $headResult.stdout.Trim()
    if ($headResult.exit_code -ne 0 -or
        $headOid -cnotmatch '^(?:[a-f0-9]{40}|[a-f0-9]{64})$') {
        Throw-ProtectedActionError 'create_repository_local_worktree_invalid'
    }
    if ($headOid -cne [string](Get-MapValue $Arguments 'expected_head_oid')) {
        Throw-ProtectedActionError 'operation_precondition_mismatch'
    }
    $status = Invoke-NativeAdapter `
        -Invoker $NativeInvoker -Kind git -Executable $git `
        -Arguments ($prefix + @(
                'status', '--porcelain=v1', '--untracked-files=all',
                '--ignore-submodules=none'
            )) `
        -WorkingDirectory $requestedWorktree -AllowFailure $true
    if ($status.exit_code -ne 0 -or
        -not [string]::IsNullOrWhiteSpace([string]$status.stdout)) {
        Throw-ProtectedActionError 'create_repository_local_worktree_dirty'
    }
    [pscustomobject][ordered]@{
        canonical_worktree = $canonicalWorktree
        git_common_dir = $gitCommonDir
        branch = $branch
        head_oid = $headOid
        clean = $true
    }
}

function Get-CreateRepositoryIdentity {
    param(
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $RepoPath,
        [Parameter(Mandatory)][object] $Arguments,
        [Parameter(Mandatory)][scriptblock] $MetadataInvoker,
        [Parameter(Mandatory)][scriptblock] $AccountInvoker,
        [Parameter(Mandatory)][scriptblock] $NativeInvoker
    )
    Assert-RepositorySlug $Repository
    $owner, $name = $Repository.Split('/', 2)
    $metadataResult = & $MetadataInvoker $Repository $true
    if ($null -eq $metadataResult -or
        $metadataResult.exit_code -eq 0 -or
        (Get-OptionalMapValue $metadataResult 'missing' $false) -ne $true -or
        $null -ne (Get-OptionalMapValue $metadataResult 'value')) {
        Throw-ProtectedActionError 'create_repository_target_not_absent'
    }
    $accountResult = & $AccountInvoker
    if ($null -eq $accountResult -or $accountResult.exit_code -ne 0 -or
        $null -eq $accountResult.value -or
        [string]::IsNullOrWhiteSpace(
            [string](Get-OptionalMapValue $accountResult.value 'login')
        )) {
        Throw-ProtectedActionError 'github_authenticated_account_unavailable'
    }
    $login = [string](Get-OptionalMapValue $accountResult.value 'login')
    if ($login -cne $owner) {
        Throw-ProtectedActionError 'authenticated_owner_mismatch'
    }
    $localWorktree = Get-CreateRepositoryLocalWorktree `
        -RepoPath $RepoPath -Arguments $Arguments -NativeInvoker $NativeInvoker
    [pscustomobject][ordered]@{
        target = [pscustomobject][ordered]@{
            repository = $Repository
            owner = $owner
            name = $name
            absent = $true
        }
        authenticated_owner = [pscustomobject][ordered]@{ login = $login }
        local_worktree = $localWorktree
    }
}

function Get-OperationState {
    param(
        [Parameter(Mandatory)][string] $EffectFamily,
        [Parameter(Mandatory)][string] $Operation,
        [Parameter(Mandatory)][string] $RepoPath,
        [Parameter(Mandatory)][object] $Arguments,
        [Parameter(Mandatory)][object] $Identity,
        [Parameter(Mandatory)][scriptblock] $NativeInvoker
    )
    if ($EffectFamily -eq 'github-api') {
        switch ($Operation) {
            'create-repository' {
                if ($Identity.target.absent -ne $true -or
                    $Identity.local_worktree.branch -cne
                        [string](Get-MapValue $Arguments 'expected_local_branch') -or
                    $Identity.local_worktree.head_oid -cne
                        [string](Get-MapValue $Arguments 'expected_head_oid')) {
                    Throw-ProtectedActionError 'operation_precondition_mismatch'
                }
                return [pscustomobject][ordered]@{
                    expected_absent = $true
                    visibility = 'PRIVATE'
                    expected_local_branch = $Identity.local_worktree.branch
                    expected_head_oid = $Identity.local_worktree.head_oid
                }
            }
            'set-visibility' {
                if ($Identity.provider.visibility -ine
                    [string](Get-MapValue $Arguments 'expected_visibility')) {
                    Throw-ProtectedActionError 'operation_precondition_mismatch'
                }
            }
            'set-default-branch' {
                if ($Identity.provider.default_branch -cne
                    [string](Get-MapValue $Arguments 'expected_default_branch')) {
                    Throw-ProtectedActionError 'operation_precondition_mismatch'
                }
            }
            'delete-repository' {
                if ($Identity.provider.visibility -ine
                    [string](Get-MapValue $Arguments 'expected_visibility') -or
                    $Identity.provider.default_branch -cne
                    [string](Get-MapValue $Arguments 'expected_default_branch')) {
                    Throw-ProtectedActionError 'operation_precondition_mismatch'
                }
            }
            'transfer-repository' {
                $owner = ([string]$Identity.provider.repository).Split('/')[0]
                if ($owner -ine
                    [string](Get-MapValue $Arguments 'expected_owner')) {
                    Throw-ProtectedActionError 'operation_precondition_mismatch'
                }
            }
        }
        return [pscustomobject][ordered]@{
            visibility = $Identity.provider.visibility
            default_branch = $Identity.provider.default_branch
            repository_node_id = $Identity.provider.repository_node_id
        }
    }
    $git = Get-FixedExecutor -Kind git
    $prefix = @(Get-GitArgumentsPrefix $RepoPath)
    switch ($Operation) {
        { $_ -in @('delete-local-ref', 'force-update-local-ref') } {
            $ref = [string](Get-MapValue $Arguments 'ref')
            $expected = if ($Operation -eq 'delete-local-ref') {
                [string](Get-MapValue $Arguments 'expected_oid')
            }
            else {
                [string](Get-MapValue $Arguments 'expected_old_oid')
            }
            $result = Invoke-NativeAdapter `
                -Invoker $NativeInvoker -Kind git -Executable $git `
                -Arguments ($prefix + @('rev-parse', '--verify', $ref)) `
                -WorkingDirectory $RepoPath -AllowFailure $true
            if ($result.exit_code -ne 0 -or $result.stdout.Trim() -cne $expected) {
                Throw-ProtectedActionError 'operation_precondition_mismatch'
            }
            return [pscustomobject][ordered]@{ ref = $ref; oid = $expected }
        }
        'replace-remote-url' {
            $remote = [string](Get-MapValue $Arguments 'remote')
            $expected = [string](Get-MapValue $Arguments 'expected_url')
            $result = Invoke-NativeAdapter `
                -Invoker $NativeInvoker -Kind git -Executable $git `
                -Arguments ($prefix + @('remote', 'get-url', '--all', $remote)) `
                -WorkingDirectory $RepoPath -AllowFailure $true
            $urls = @($result.stdout -split "`r?`n" | Where-Object { $_ })
            if ($result.exit_code -ne 0 -or $urls.Count -ne 1 -or
                $urls[0] -cne $expected) {
                Throw-ProtectedActionError 'operation_precondition_mismatch'
            }
            return [pscustomobject][ordered]@{
                remote = $remote
                remote_url = $expected
            }
        }
    }
}

function Get-LiveBinding {
    param(
        [Parameter(Mandatory)][string] $EffectFamily,
        [Parameter(Mandatory)][string] $Operation,
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $RepoPath,
        [Parameter(Mandatory)][object] $Arguments,
        [Parameter(Mandatory)][scriptblock] $AdmissionInvoker,
        [Parameter(Mandatory)][scriptblock] $MetadataInvoker,
        [Parameter(Mandatory)][scriptblock] $AccountInvoker,
        [Parameter(Mandatory)][scriptblock] $NativeInvoker
    )
    Assert-TypedArguments $EffectFamily $Operation $Arguments
    if ($EffectFamily -eq 'github-api' -and $Operation -eq 'create-repository') {
        $identity = Get-CreateRepositoryIdentity `
            -Repository $Repository -RepoPath $RepoPath -Arguments $Arguments `
            -MetadataInvoker $MetadataInvoker -AccountInvoker $AccountInvoker `
            -NativeInvoker $NativeInvoker
        $plan = Get-EffectPlan `
            -EffectFamily $EffectFamily -Operation $Operation `
            -Repository $Repository -RepoPath $RepoPath -Arguments $Arguments
        $operationState = Get-OperationState `
            -EffectFamily $EffectFamily -Operation $Operation `
            -RepoPath $RepoPath -Arguments $Arguments -Identity $identity `
            -NativeInvoker $NativeInvoker
        return [pscustomobject][ordered]@{
            stable_target = [pscustomobject][ordered]@{
                provider = 'github'
                repository = $identity.target.repository
                repository_owner = $identity.target.owner
                repository_name = $identity.target.name
                canonical_worktree = $identity.local_worktree.canonical_worktree
                git_common_dir = $identity.local_worktree.git_common_dir
                resource = 'repository-slug:' + $identity.target.repository
            }
            parameters = [pscustomobject][ordered]@{
                operation = $Operation
                executor_kind = $plan.kind
                native_executor_sha256 = $plan.native_executor_sha256
                argv = @($plan.argv)
                arguments = ConvertTo-CanonicalNode $Arguments
            }
            preconditions = [pscustomobject][ordered]@{
                target = [pscustomobject][ordered]@{ absent = $true }
                authenticated_owner = $identity.authenticated_owner
                local_worktree = $identity.local_worktree
                operation_state = $operationState
            }
            plan = $plan
            adapter_sha256 = Get-FileSha256 $script:AdapterEntry
        }
    }
    $identity = Get-NormalizedIdentity `
        -Repository $Repository -RepoPath $RepoPath `
        -AdmissionInvoker $AdmissionInvoker `
        -MetadataInvoker $MetadataInvoker
    $plan = Get-EffectPlan `
        -EffectFamily $EffectFamily -Operation $Operation `
        -Repository $Repository -RepoPath $RepoPath -Arguments $Arguments
    $operationState = Get-OperationState `
        -EffectFamily $EffectFamily -Operation $Operation `
        -RepoPath $RepoPath -Arguments $Arguments -Identity $identity `
        -NativeInvoker $NativeInvoker
    $resource = switch ($Operation) {
        { $_ -in @('delete-local-ref', 'force-update-local-ref') } {
            [string](Get-MapValue $Arguments 'ref')
        }
        'replace-remote-url' {
            'remote:' + [string](Get-MapValue $Arguments 'remote')
        }
        default { 'repository:' + $identity.provider.repository_node_id }
    }
    [pscustomobject][ordered]@{
        stable_target = [pscustomobject][ordered]@{
            provider = 'github'
            repository = $identity.provider.repository
            repository_database_id = $identity.provider.repository_database_id
            repository_node_id = $identity.provider.repository_node_id
            remote_url = $identity.admission.remote_url
            canonical_worktree = $identity.admission.canonical_worktree
            git_common_dir = $identity.admission.git_common_dir
            visibility = $identity.provider.visibility
            default_branch = $identity.provider.default_branch
            resource = $resource
        }
        parameters = [pscustomobject][ordered]@{
            operation = $Operation
            executor_kind = $plan.kind
            native_executor_sha256 = $plan.native_executor_sha256
            argv = @($plan.argv)
            arguments = ConvertTo-CanonicalNode $Arguments
        }
        preconditions = [pscustomobject][ordered]@{
            admission = $identity.admission
            provider = $identity.provider
            operation_state = $operationState
        }
        plan = $plan
        adapter_sha256 = Get-FileSha256 $script:AdapterEntry
    }
}

function New-ProtectedGitHubMajorActionProposal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('git-local', 'github-api')]
        [string] $EffectFamily,
        [ValidateSet('execute', 'dry_run')]
        [string] $ExecutionMode = 'execute',
        [Parameter(Mandatory)][string] $Operation,
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $RepoPath,
        [Parameter(Mandatory)][object] $Arguments,
        [Parameter(Mandatory)][ValidateSet('allow', 'deny')]
        [string] $Decision,
        [Parameter(Mandatory)][string] $Reason,
        [Parameter(Mandatory)][string] $UserIntent,
        [scriptblock] $AdmissionInvoker = (Get-DefaultAdmissionInvoker),
        [scriptblock] $MetadataInvoker = (Get-DefaultMetadataInvoker),
        [scriptblock] $AccountInvoker = (Get-DefaultAccountInvoker),
        [scriptblock] $NativeInvoker = (Get-DefaultNativeInvoker)
    )
    if ([string]::IsNullOrWhiteSpace($Reason) -or $Reason.Length -gt 4096 -or
        [string]::IsNullOrWhiteSpace($UserIntent) -or
        $UserIntent.Length -gt 4096) {
        Throw-ProtectedActionError 'assessment_invalid'
    }
    $repoRoot = [IO.Path]::GetFullPath($RepoPath)
    $binding = Get-LiveBinding `
        -EffectFamily $EffectFamily -Operation $Operation `
        -Repository $Repository -RepoPath $repoRoot -Arguments $Arguments `
        -AdmissionInvoker $AdmissionInvoker `
        -MetadataInvoker $MetadataInvoker -AccountInvoker $AccountInvoker `
        -NativeInvoker $NativeInvoker
    [pscustomobject][ordered]@{
        schema = $script:ProposalSchema
        prepared_utc = [DateTimeOffset]::UtcNow.ToString('o')
        runtime_principal = 'codex-root'
        authorization_request = [pscustomobject][ordered]@{
            schema = $script:AuthorizationSchema
            adapter_id = $script:AdapterId
            owner_id = $script:OwnerId
            effect_family = $EffectFamily
            execution_mode = $ExecutionMode
            stable_target = $binding.stable_target
            executor_sha256 = $binding.adapter_sha256
            parameters = $binding.parameters
            preconditions = $binding.preconditions
            assessment = [pscustomobject][ordered]@{
                decision = $Decision
                reason = $Reason
                user_intent = $UserIntent
            }
            ttl_seconds = 30
        }
    }
}

function Assert-Proposal {
    param([Parameter(Mandatory)][object] $Proposal)
    if (-not (Test-ExactKeys $Proposal @(
                'schema', 'prepared_utc', 'runtime_principal',
                'authorization_request'
            )) -or $Proposal.schema -cne $script:ProposalSchema -or
        $Proposal.runtime_principal -cne 'codex-root') {
        Throw-ProtectedActionError 'proposal_invalid'
    }
    $request = $Proposal.authorization_request
    if (-not (Test-ExactKeys $request @(
                'schema', 'adapter_id', 'owner_id', 'effect_family',
                'execution_mode', 'stable_target', 'executor_sha256', 'parameters',
                'preconditions', 'assessment', 'ttl_seconds'
            )) -or $request.schema -cne $script:AuthorizationSchema -or
        $request.adapter_id -cne $script:AdapterId -or
        $request.owner_id -cne $script:OwnerId -or
        $request.effect_family -notin @('git-local', 'github-api') -or
        $request.execution_mode -notin @('execute', 'dry_run') -or
        $request.executor_sha256 -cnotmatch '^[a-f0-9]{64}$' -or
        [int]$request.ttl_seconds -ne 30 -or
        -not (Test-ExactKeys $request.assessment @(
                'decision', 'reason', 'user_intent'
            )) -or $request.assessment.decision -notin @('allow', 'deny')) {
        Throw-ProtectedActionError 'proposal_invalid'
    }
    if (-not (Test-ExactKeys $request.parameters @(
                'operation', 'executor_kind', 'native_executor_sha256',
                'argv', 'arguments'
            ))) {
        Throw-ProtectedActionError 'proposal_invalid'
    }
    Assert-TypedArguments `
        -EffectFamily $request.effect_family `
        -Operation $request.parameters.operation `
        -Arguments $request.parameters.arguments
    if ($request.parameters.operation -eq 'create-repository') {
        $target = $request.stable_target
        $preconditions = $request.preconditions
        $expectedLocalBranch = [string](Get-MapValue `
                -Value $request.parameters.arguments `
                -Name 'expected_local_branch')
        $expectedHeadOid = [string](Get-MapValue `
                -Value $request.parameters.arguments `
                -Name 'expected_head_oid')
        if ($request.parameters.executor_kind -cne 'gh' -or
            -not (Test-ExactKeys $target @(
                    'provider', 'repository', 'repository_owner',
                    'repository_name', 'canonical_worktree', 'git_common_dir',
                    'resource'
                )) -or
            $target.provider -cne 'github') {
            Throw-ProtectedActionError 'proposal_invalid'
        }
        try { Assert-RepositorySlug ([string]$target.repository) }
        catch { Throw-ProtectedActionError 'proposal_invalid' }
        $owner, $name = ([string]$target.repository).Split('/', 2)
        if ($target.repository_owner -cne $owner -or
            $target.repository_name -cne $name -or
            $target.resource -cne "repository-slug:$($target.repository)" -or
            -not (Test-ExactKeys $preconditions @(
                    'target', 'authenticated_owner', 'local_worktree',
                    'operation_state'
                )) -or
            -not (Test-ExactKeys $preconditions.target @('absent')) -or
            $preconditions.target.absent -ne $true -or
            -not (Test-ExactKeys $preconditions.authenticated_owner @('login')) -or
            $preconditions.authenticated_owner.login -cne $owner -or
            -not (Test-ExactKeys $preconditions.local_worktree @(
                    'canonical_worktree', 'git_common_dir', 'branch', 'head_oid',
                    'clean'
                )) -or
            $preconditions.local_worktree.clean -ne $true -or
            $preconditions.local_worktree.branch -cne
                $expectedLocalBranch -or
            $preconditions.local_worktree.head_oid -cne
                $expectedHeadOid -or
            -not (Test-ExactKeys $preconditions.operation_state @(
                    'expected_absent', 'visibility', 'expected_local_branch',
                    'expected_head_oid'
                )) -or
            $preconditions.operation_state.expected_absent -ne $true -or
            $preconditions.operation_state.visibility -cne 'PRIVATE' -or
            $preconditions.operation_state.expected_local_branch -cne
                $preconditions.local_worktree.branch -or
            $preconditions.operation_state.expected_head_oid -cne
                $preconditions.local_worktree.head_oid) {
            Throw-ProtectedActionError 'proposal_invalid'
        }
    }
}

function New-BlockedResult {
    param(
        [Parameter(Mandatory)][string] $Error,
        [string] $AuthorizationStatus = 'denied'
    )
    [pscustomobject][ordered]@{
        schema = $script:ResultSchema
        status = 'blocked'
        result = if ($AuthorizationStatus -eq 'verification_required') {
            'verification_required'
        }
        else { 'not_executed' }
        error = $Error
        authorization_status = $AuthorizationStatus
        runtime_principal = 'codex-root'
        capability_verified = $false
        capability_consumed = $false
        mutation_performed = $false
        read_back_verified = $false
    }
}

function Test-LiveProposalBinding {
    param(
        [Parameter(Mandatory)][object] $Request,
        [Parameter(Mandatory)][scriptblock] $AdmissionInvoker,
        [Parameter(Mandatory)][scriptblock] $MetadataInvoker,
        [Parameter(Mandatory)][scriptblock] $AccountInvoker,
        [Parameter(Mandatory)][scriptblock] $NativeInvoker
    )
    try {
        $live = Get-LiveBinding `
            -EffectFamily $Request.effect_family `
            -Operation $Request.parameters.operation `
            -Repository $Request.stable_target.repository `
            -RepoPath $Request.stable_target.canonical_worktree `
            -Arguments $Request.parameters.arguments `
            -AdmissionInvoker $AdmissionInvoker `
            -MetadataInvoker $MetadataInvoker -AccountInvoker $AccountInvoker `
            -NativeInvoker $NativeInvoker
    }
    catch {
        if ($_.Exception.Message -in @(
                'operation_precondition_mismatch',
                'stable_repository_identity_mismatch',
                'project_admission_blocked',
                'github_metadata_unavailable',
                'create_repository_target_not_absent',
                'github_authenticated_account_unavailable',
                'authenticated_owner_mismatch',
                'create_repository_local_worktree_invalid',
                'create_repository_local_worktree_dirty'
            )) {
            return $false
        }
        throw
    }
    (Test-ExactValue $Request.stable_target $live.stable_target) -and
        (Test-ExactValue $Request.parameters $live.parameters) -and
        (Test-ExactValue $Request.preconditions $live.preconditions) -and
        $Request.executor_sha256 -ceq $live.adapter_sha256
}

function Invoke-ReadBack {
    param(
        [Parameter(Mandatory)][object] $Request,
        [Parameter(Mandatory)][scriptblock] $MetadataInvoker,
        [Parameter(Mandatory)][scriptblock] $NativeInvoker,
        [object] $EffectResult = $null
    )
    $operation = [string]$Request.parameters.operation
    $arguments = $Request.parameters.arguments
    $repo = [string]$Request.stable_target.repository
    $repoPath = [string]$Request.stable_target.canonical_worktree
    if ($Request.effect_family -eq 'git-local') {
        $git = Get-FixedExecutor -Kind git
        $prefix = @(Get-GitArgumentsPrefix $repoPath)
        if ($operation -in @('delete-local-ref', 'force-update-local-ref')) {
            $ref = [string](Get-MapValue $arguments 'ref')
            $result = Invoke-NativeAdapter `
                -Invoker $NativeInvoker -Kind git -Executable $git `
                -Arguments ($prefix + @('rev-parse', '--verify', $ref)) `
                -WorkingDirectory $repoPath -AllowFailure $true
            if ($operation -eq 'delete-local-ref') {
                return ($result.exit_code -ne 0)
            }
            return ($result.exit_code -eq 0 -and
                $result.stdout.Trim() -ceq
                [string](Get-MapValue $arguments 'new_oid'))
        }
        $remote = [string](Get-MapValue $arguments 'remote')
        $result = Invoke-NativeAdapter `
            -Invoker $NativeInvoker -Kind git -Executable $git `
            -Arguments ($prefix + @('remote', 'get-url', '--all', $remote)) `
            -WorkingDirectory $repoPath -AllowFailure $true
        $urls = @($result.stdout -split "`r?`n" | Where-Object { $_ })
        return ($result.exit_code -eq 0 -and $urls.Count -eq 1 -and
            $urls[0] -ceq [string](Get-MapValue $arguments 'new_url'))
    }
    $readBackRepo = if ($operation -eq 'transfer-repository') {
        $newOwner = [string](Get-MapValue $arguments 'new_owner')
        $name = $repo.Split('/')[1]
        "$newOwner/$name"
    }
    else { $repo }
    $metadataResult = & $MetadataInvoker `
        $readBackRepo ($operation -eq 'delete-repository')
    if ($operation -eq 'delete-repository') {
        return ($metadataResult.exit_code -ne 0 -and
            [bool]$metadataResult.missing)
    }
    if ($metadataResult.exit_code -ne 0 -or $null -eq $metadataResult.value) {
        return $false
    }
    $metadata = $metadataResult.value
    if ($operation -eq 'create-repository') {
        if ($null -eq $EffectResult -or $EffectResult.exit_code -ne 0 -or
            [string]::IsNullOrWhiteSpace([string]$EffectResult.stdout)) {
            return $false
        }
        try {
            $created = $EffectResult.stdout | ConvertFrom-Json -Depth 20
        }
        catch { return $false }
        if ([string]$created.full_name -cne $repo -or
            $created.private -ne $true -or
            [string]$created.visibility -ine 'PRIVATE' -or
            $null -eq $created.id -or
            [string]::IsNullOrWhiteSpace([string]$created.node_id)) {
            return $false
        }
        return (
            [string]$metadata.full_name -ceq [string]$created.full_name -and
            $metadata.private -eq $true -and
            [string]$metadata.visibility -ieq 'PRIVATE' -and
            [string]$metadata.id -ceq [string]$created.id -and
            [string]$metadata.node_id -ceq [string]$created.node_id
        )
    }
    if ([string]$metadata.node_id -cne
        [string]$Request.stable_target.repository_node_id) { return $false }
    switch ($operation) {
        'set-visibility' {
            return ([string]$metadata.visibility -ieq
                [string](Get-MapValue $arguments 'new_visibility'))
        }
        'set-default-branch' {
            return ([string]$metadata.default_branch -ceq
                [string](Get-MapValue $arguments 'new_default_branch'))
        }
        'transfer-repository' {
            $newOwner = [string](Get-MapValue $arguments 'new_owner')
            $name = ([string]$Request.stable_target.repository).Split('/')[1]
            return ([string]$metadata.full_name -ieq "$newOwner/$name")
        }
    }
    $false
}

function Invoke-ProtectedGitHubMajorActionProposal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Proposal,
        [switch] $DryRun,
        [scriptblock] $AdmissionInvoker = (Get-DefaultAdmissionInvoker),
        [scriptblock] $MetadataInvoker = (Get-DefaultMetadataInvoker),
        [scriptblock] $AccountInvoker = (Get-DefaultAccountInvoker),
        [scriptblock] $NativeInvoker = (Get-DefaultNativeInvoker),
        [scriptblock] $BrokerInvoker = (Get-DefaultBrokerInvoker)
    )
    Assert-Proposal $Proposal
    $request = $Proposal.authorization_request
    $expectedDryRun = $request.execution_mode -ceq 'dry_run'
    if ([bool]$DryRun -ne $expectedDryRun) {
        return New-BlockedResult 'execution_mode_mismatch'
    }
    try {
        if (-not (Test-LiveProposalBinding `
                -Request $request -AdmissionInvoker $AdmissionInvoker `
                -MetadataInvoker $MetadataInvoker `
                -AccountInvoker $AccountInvoker `
                -NativeInvoker $NativeInvoker)) {
            return New-BlockedResult 'target_precondition_changed'
        }
    }
    catch {
        if ($_.Exception.Message -in @(
                'operation_precondition_mismatch',
                'stable_repository_identity_mismatch',
                'project_admission_blocked',
                'github_metadata_unavailable',
                'create_repository_target_not_absent',
                'github_authenticated_account_unavailable',
                'authenticated_owner_mismatch',
                'create_repository_local_worktree_invalid',
                'create_repository_local_worktree_dirty'
            )) {
            return New-BlockedResult 'target_precondition_changed'
        }
        throw
    }
    if ($request.assessment.decision -ne 'allow') {
        return New-BlockedResult 'model_assessment_denied'
    }
    $operationId = [guid]::NewGuid().ToString()
    $tempRoot = $null
    try {
        $tempRoot = New-PrivateTemporaryDirectory
        $authorizationPath = Join-Path $tempRoot 'authorization.json'
        Write-JsonFile $authorizationPath $request
        $authorization = & $BrokerInvoker `
            'AuthorizeMajorAction' $authorizationPath $operationId
        if ((Get-OptionalMapValue $authorization.value 'error') -eq
            'highest_authority_verification_required' -or
            (Get-OptionalMapValue $authorization.value 'authorization_status') -eq
            'verification_required') {
            return New-BlockedResult `
                -Error 'highest_authority_verification_required' `
                -AuthorizationStatus 'verification_required'
        }
        if ($authorization.exit_code -ne 0 -or
            $authorization.value.status -ne 'pass' -or
            $authorization.value.authorization_status -ne 'authorized' -or
            $authorization.value.runtime_proof_verified -ne $true -or
            $null -eq $authorization.value.major_action_capability) {
            return New-BlockedResult 'major_action_authorization_failed'
        }
        if (-not (Test-LiveProposalBinding `
                -Request $request -AdmissionInvoker $AdmissionInvoker `
                -MetadataInvoker $MetadataInvoker `
                -AccountInvoker $AccountInvoker `
                -NativeInvoker $NativeInvoker)) {
            return New-BlockedResult 'target_precondition_changed'
        }
        $consumeEnvelope = [pscustomobject][ordered]@{
            schema = $script:ConsumeSchema
            authorization_request = $request
            capability = $authorization.value.major_action_capability
            dry_run = [bool]$DryRun
        }
        $consumePath = Join-Path $tempRoot 'consume.json'
        Write-JsonFile $consumePath $consumeEnvelope
        $consume = & $BrokerInvoker `
            'ConsumeMajorActionCapability' $consumePath $operationId
        if ((Get-OptionalMapValue $consume.value 'error') -eq
            'highest_authority_verification_required' -or
            (Get-OptionalMapValue $consume.value 'authorization_status') -eq
            'verification_required') {
            return New-BlockedResult `
                -Error 'highest_authority_verification_required' `
                -AuthorizationStatus 'verification_required'
        }
        if ($consume.exit_code -ne 0 -or
            $consume.value.status -ne 'pass' -or
            $consume.value.capability_verified -ne $true) {
            return New-BlockedResult 'major_action_capability_invalid'
        }
        if ($DryRun) {
            if ($consume.value.execute_allowed -ne $false -or
                $consume.value.capability_consumed -ne $false) {
                return New-BlockedResult 'dry_run_broker_contract_invalid'
            }
            return [pscustomobject][ordered]@{
                schema = $script:ResultSchema
                status = 'pass'
                result = 'dry_run_verified'
                authorization_status = 'authorized'
                runtime_principal = 'codex-root'
                capability_verified = $true
                capability_consumed = $false
                mutation_performed = $false
                read_back_verified = $false
            }
        }
        if ($consume.value.execute_allowed -ne $true -or
            $consume.value.capability_consumed -ne $true) {
            return New-BlockedResult 'major_action_capability_not_consumed'
        }
        if (-not (Test-LiveProposalBinding `
                -Request $request -AdmissionInvoker $AdmissionInvoker `
                -MetadataInvoker $MetadataInvoker `
                -AccountInvoker $AccountInvoker `
                -NativeInvoker $NativeInvoker)) {
            return New-BlockedResult 'target_precondition_changed_after_consume'
        }
        $plan = Get-EffectPlan `
            -EffectFamily $request.effect_family `
            -Operation $request.parameters.operation `
            -Repository $request.stable_target.repository `
            -RepoPath $request.stable_target.canonical_worktree `
            -Arguments $request.parameters.arguments
        if ($plan.native_executor_sha256 -cne
            $request.parameters.native_executor_sha256 -or
            (Get-FileSha256 $script:AdapterEntry) -cne
            $request.executor_sha256) {
            return New-BlockedResult 'executor_changed_after_consume'
        }
        $effect = Invoke-NativeAdapter `
            -Invoker $NativeInvoker -Kind $plan.kind `
            -Executable $plan.executable -Arguments $plan.argv `
            -WorkingDirectory $request.stable_target.canonical_worktree `
            -AllowFailure $true
        $verified = $false
        try {
            $verified = Invoke-ReadBack `
                -Request $request -MetadataInvoker $MetadataInvoker `
                -NativeInvoker $NativeInvoker -EffectResult $effect
        }
        catch {
            $verified = $false
        }
        if ($verified) {
            return [pscustomobject][ordered]@{
                schema = $script:ResultSchema
                status = 'pass'
                result = 'executed_verified'
                authorization_status = 'authorized'
                runtime_principal = 'codex-root'
                capability_verified = $true
                capability_consumed = $true
                mutation_performed = $true
                read_back_verified = $true
            }
        }
        if ($effect.exit_code -ne 0) {
            return [pscustomobject][ordered]@{
                schema = $script:ResultSchema
                status = 'error'
                result = 'effect_failed_state_unknown'
                error = 'adapter_effect_failed_state_unknown'
                authorization_status = 'authorized'
                runtime_principal = 'codex-root'
                capability_verified = $true
                capability_consumed = $true
                mutation_performed = $false
                mutation_may_have_occurred = $true
                read_back_verified = $false
            }
        }
        return [pscustomobject][ordered]@{
            schema = $script:ResultSchema
            status = 'error'
            result = 'read_back_failed'
            error = 'adapter_read_back_failed'
            authorization_status = 'authorized'
            runtime_principal = 'codex-root'
            capability_verified = $true
            capability_consumed = $true
            mutation_performed = $true
            read_back_verified = $false
        }
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($tempRoot) -and
            (Test-Path -LiteralPath $tempRoot -PathType Container)) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

function Invoke-ProtectedGitHubMajorActionCli {
    if ($Mode -eq 'Prepare') {
        if ([string]::IsNullOrWhiteSpace($EffectFamily) -or
            [string]::IsNullOrWhiteSpace($Operation) -or
            [string]::IsNullOrWhiteSpace($Repository) -or
            [string]::IsNullOrWhiteSpace($RepoPath) -or
            [string]::IsNullOrWhiteSpace($ArgumentsPath) -or
            [string]::IsNullOrWhiteSpace($Decision) -or
            [string]::IsNullOrWhiteSpace($Reason) -or
            [string]::IsNullOrWhiteSpace($UserIntent) -or
            [string]::IsNullOrWhiteSpace($OutputPath) -or $DryRun) {
            Throw-ProtectedActionError 'prepare_parameters_invalid'
        }
        $arguments = Read-BoundedJsonObject $ArgumentsPath
        $proposal = New-ProtectedGitHubMajorActionProposal `
            -EffectFamily $EffectFamily -Operation $Operation `
            -ExecutionMode $ExecutionMode `
            -Repository $Repository -RepoPath $RepoPath `
            -Arguments $arguments -Decision $Decision `
            -Reason $Reason -UserIntent $UserIntent
        Write-JsonFile $OutputPath $proposal
        return $proposal
    }
    if ([string]::IsNullOrWhiteSpace($ProposalPath) -or
        -not [string]::IsNullOrWhiteSpace($OutputPath) -or
        -not [string]::IsNullOrWhiteSpace($ArgumentsPath)) {
        Throw-ProtectedActionError 'execute_parameters_invalid'
    }
    $proposal = Read-BoundedJsonObject $ProposalPath
    Invoke-ProtectedGitHubMajorActionProposal `
        -Proposal $proposal -DryRun:$DryRun
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $result = Invoke-ProtectedGitHubMajorActionCli
        [Console]::Out.Write(($result | ConvertTo-Json -Depth 50) + "`n")
        $status = [string](Get-OptionalMapValue $result 'status')
        if ($status -eq 'blocked' -or $status -eq 'error') {
            exit 2
        }
        exit 0
    }
    catch {
        $result = New-BlockedResult -Error $_.Exception.Message
        [Console]::Out.Write(($result | ConvertTo-Json -Depth 20) + "`n")
        exit 2
    }
}
