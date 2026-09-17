#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'tools/GitHubIndex.Core.psm1') -Force
$module = Get-Module GitHubIndex.Core
$cases = @(
    @{ code=128; stderr='fatal: detected dubious ownership'; expected='git_ownership_restricted' },
    @{ code=128; stderr='fatal: Permission denied'; expected='git_access_denied' },
    @{ code=127; stderr='Unable to start external command'; expected='git_executable_unavailable' },
    @{ code=124; stderr='timeout'; expected='git_read_timeout' },
    @{ code=128; stderr='fatal: not a git repository'; expected='not_git_repository' },
    @{ code=128; stderr='other failure'; expected='local_git_read_failed' },
    @{ code=1; stderr=''; expected='remote_missing' }
)
foreach ($case in $cases) {
    $actual = & $module {
        param($case)
        Get-GitReadFailureReason -Result ([pscustomobject]@{exit_code=$case.code;stderr=$case.stderr;stdout=''}) -OriginConfig
    } $case
    if ($actual -cne $case.expected) { throw "wrong error classification: $($case.expected) / $actual" }
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ('admission-read-errors-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $temp '.git') -Force | Out-Null
try {
    $result = & $module {
        param($path)
        $original = (Get-Command Invoke-GitCommandResult).ScriptBlock
        try {
            Set-Item Function:script:Invoke-GitCommandResult { param($Path,$Arguments) [pscustomobject]@{exit_code=128;stdout='';stderr='fatal: detected dubious ownership'} }
            Get-ProjectAdmissionRecord -Repo example/video-test -RepoPath $path -Visibility PUBLIC -DefaultBranch main
        }
        finally { Set-Item Function:script:Invoke-GitCommandResult $original }
    } $temp
    if ($result.decision -ne 'block' -or $result.reasons -notcontains 'git_ownership_restricted') { throw 'unreadable Git identity did not block with its actual reason' }
    if ($result.reasons -contains 'missing_repo_path' -or $result.reasons -contains 'remote_mismatch') { throw 'Git execution failure misreported as missing path or verified remote conflict' }
}
finally { Remove-Item -LiteralPath $temp -Recurse -Force }
Write-Output 'PASS: 7 error categories and actual admission ownership-failure path'

$pwsh=(Get-Command pwsh).Source
$large=Invoke-ExternalCommandResult -FilePath $pwsh -ArgumentList @('-NoProfile','-Command',"[Console]::Out.Write(('o'*131072));[Console]::Error.Write(('e'*131072))") -TimeoutSeconds 15
if($large.exit_code -ne 0 -or $large.stdout.Length -ne 131072 -or $large.stderr.Length -ne 131072){throw 'concurrent process pipe draining failed'}
$timed=Invoke-ExternalCommandResult -FilePath $pwsh -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 20') -TimeoutSeconds 1
if($timed.exit_code -ne 124){throw 'external command deadline did not produce explicit timeout'}
Write-Output 'PASS: concurrent stdout/stderr draining and bounded process timeout'
