#requires -Version 7.0

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'tools/Add-PushRecord.ps1'
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

function Get-ScriptParameterNames {
    param([string] $Path)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref] $tokens, [ref] $errors)
    if ($errors.Count -gt 0) { throw ($errors | Out-String) }
    @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
}

function Start-PushRecordProcess {
    param(
        [string] $LogPath,
        [string] $Repo,
        [string] $Branch,
        [string] $Commit,
        [string] $Reason
    )

    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath,
        '-Repo', $Repo, '-Branch', $Branch, '-Commit', $Commit,
        '-Reason', $Reason, '-LogPath', $LogPath, '-Json'
    )
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'pwsh.exe'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    foreach ($argument in $arguments) { [void] $startInfo.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void] $process.Start()
    $process
}

function Complete-PushRecordProcess {
    param([object] $Handle)
    $stdout = $Handle.StandardOutput.ReadToEnd()
    $stderr = $Handle.StandardError.ReadToEnd()
    $Handle.WaitForExit()
    $exitCode = $Handle.ExitCode
    $Handle.Dispose()
    [pscustomobject]@{ ExitCode = $exitCode; StdOut = $stdout; StdErr = $stderr }
}

$parameterNames = @(Get-ScriptParameterNames -Path $scriptPath)
Assert-True ($parameterNames -contains 'LogPath') 'push-record script exposes an injectable log path'
Assert-True ($parameterNames -contains 'Json') 'push-record script exposes machine-readable result output'
Assert-True (-not ($parameterNames -contains 'PushIndex')) 'push-record script removes implicit push switch'
if ($script:Failures -gt 0) {
    throw "$script:Failures test(s) failed"
}

$source = Get-Content -LiteralPath $scriptPath -Raw -Encoding utf8
Assert-True (-not ($source -match '(?im)^\s*(?:&\s*)?git\s+(add|commit|push|pull|rebase)\b')) 'push-record script contains no Git transaction commands'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('github-index-push-record-' + [guid]::NewGuid().ToString('N'))
$logPath = Join-Path $tempRoot 'record.md'
try {
    New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
    Set-Content -LiteralPath $logPath -Encoding utf8 -Value @'
# Push records

更新时间：2026-01-01 00:00:00 +08:00

| 时间 | 仓库 | 分支 | Commit | 决策理由 |
|---|---|---|---|---|
'@
    & git init --initial-branch=main $tempRoot 2>&1 | Out-Null
    & git -C $tempRoot config user.name 'Push Record Test'
    & git -C $tempRoot config user.email 'push-record@example.invalid'
    & git -C $tempRoot add record.md 2>&1 | Out-Null
    & git -C $tempRoot commit -m baseline 2>&1 | Out-Null
    $headBefore = (& git -C $tempRoot rev-parse HEAD).Trim()

    $tick = [string] [char] 96
    $specialReason = "line1|tick$tick`nline2"
    $firstHandle = Start-PushRecordProcess -LogPath $logPath -Repo 'example/demo' -Branch 'feature|one' -Commit 'abc1234' -Reason $specialReason
    $first = Complete-PushRecordProcess -Handle $firstHandle
    Assert-Equal 0 $first.ExitCode 'first record write succeeds'
    $firstResult = $first.StdOut | ConvertFrom-Json
    Assert-True $firstResult.changed 'first record reports changed=true'
    $content = Get-Content -LiteralPath $logPath -Raw -Encoding utf8
    Assert-True ($content -match '\| 时间 \| 仓库 \| 分支 \| Commit \| 决策理由 \|') 'log keeps five-column header with commit'
    Assert-True ($content.Contains('feature\|one')) 'escapes Markdown pipe in branch cell'
    Assert-True ($content.Contains("tick\$tick")) 'escapes Markdown backtick in reason cell'
    Assert-True ($content.Contains('line1\|') -and $content.Contains('<br>line2')) 'escapes pipe and newline in reason cell'
    Assert-True ($content -match '\| abc1234 \|') 'writes commit column'

    $hashAfterFirst = (Get-FileHash -LiteralPath $logPath -Algorithm SHA256).Hash
    $secondHandle = Start-PushRecordProcess -LogPath $logPath -Repo 'EXAMPLE/demo' -Branch 'feature|one' -Commit 'ABC1234' -Reason 'duplicate should be ignored'
    $second = Complete-PushRecordProcess -Handle $secondHandle
    Assert-Equal 0 $second.ExitCode 'duplicate record returns success'
    $secondResult = $second.StdOut | ConvertFrom-Json
    Assert-True (-not $secondResult.changed) 'duplicate record reports changed=false'
    Assert-Equal $hashAfterFirst (Get-FileHash -LiteralPath $logPath -Algorithm SHA256).Hash 'duplicate record leaves file byte-identical'

    $headAfter = (& git -C $tempRoot rev-parse HEAD).Trim()
    Assert-Equal $headBefore $headAfter 'recording does not create a Git commit'

    $concurrentLog = Join-Path $tempRoot 'concurrent.md'
    Set-Content -LiteralPath $concurrentLog -Encoding utf8 -Value @'
# Push records

更新时间：2026-01-01 00:00:00 +08:00

| 时间 | 仓库 | 分支 | Commit | 决策理由 |
|---|---|---|---|---|
'@
    $handle1 = Start-PushRecordProcess -LogPath $concurrentLog -Repo 'example/concurrent' -Branch 'main' -Commit 'deadbee' -Reason 'writer one'
    $handle2 = Start-PushRecordProcess -LogPath $concurrentLog -Repo 'example/concurrent' -Branch 'main' -Commit 'deadbee' -Reason 'writer two'
    $result1 = Complete-PushRecordProcess -Handle $handle1
    $result2 = Complete-PushRecordProcess -Handle $handle2
    Assert-Equal 0 $result1.ExitCode 'first concurrent writer succeeds'
    Assert-Equal 0 $result2.ExitCode 'second concurrent writer succeeds'
    $concurrentRows = @(Get-Content -LiteralPath $concurrentLog -Encoding utf8 | Where-Object { $_ -match '^\| .*\| example/concurrent \| main \| deadbee \|' })
    Assert-Equal 1 $concurrentRows.Count 'concurrent duplicate writers produce one valid row'

    $beforeRejected = (Get-FileHash -LiteralPath $concurrentLog -Algorithm SHA256).Hash
    $fakeSecret = 'ghp_' + ('x' * 36)
    $rejectHandle = Start-PushRecordProcess -LogPath $concurrentLog -Repo 'example/reject' -Branch 'main' -Commit 'face123' -Reason $fakeSecret
    $rejected = Complete-PushRecordProcess -Handle $rejectHandle
    Assert-True ($rejected.ExitCode -ne 0) 'rejects obvious secret material in reason'
    Assert-Equal $beforeRejected (Get-FileHash -LiteralPath $concurrentLog -Algorithm SHA256).Hash 'rejected reason leaves log unchanged'

    $unsafeReasonCases = @(
        [pscustomobject]@{ Commit = 'badc0de'; Label = 'client_secret assignment'; Reason = 'client_secret=TEST_ONLY_VALUE_DO_NOT_USE' },
        [pscustomobject]@{ Commit = 'c0ffee1'; Label = 'password assignment'; Reason = 'password: TEST_ONLY_VALUE_DO_NOT_USE' },
        [pscustomobject]@{ Commit = 'decaf12'; Label = 'Authorization Bearer header'; Reason = 'Authorization: Bearer TEST_ONLY_VALUE_DO_NOT_USE' }
    )
    foreach ($case in $unsafeReasonCases) {
        $beforeUnsafeReason = (Get-FileHash -LiteralPath $concurrentLog -Algorithm SHA256).Hash
        $unsafeHandle = Start-PushRecordProcess -LogPath $concurrentLog -Repo 'example/reject' -Branch 'main' -Commit $case.Commit -Reason $case.Reason
        $unsafeResult = Complete-PushRecordProcess -Handle $unsafeHandle
        Assert-True ($unsafeResult.ExitCode -ne 0) "rejects $($case.Label) in reason"
        Assert-Equal $beforeUnsafeReason (Get-FileHash -LiteralPath $concurrentLog -Algorithm SHA256).Hash "$($case.Label) leaves log unchanged"
    }
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

Write-Host 'All push record tests passed.'
