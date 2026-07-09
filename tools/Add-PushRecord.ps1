#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Repo,
    [Parameter(Mandatory = $true)] [string] $Branch,
    [Parameter(Mandatory = $true)] [string] $Commit,
    [Parameter(Mandatory = $true)] [string] $Reason,
    [string] $LogPath = (Join-Path $PSScriptRoot '..\03_推送决策\已推送记录.md'),
    [switch] $Json
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

function ConvertTo-PushRecordMarkdownCell {
    param([Parameter(Mandatory = $true)] [string] $Value)

    $escaped = $Value.Replace('|', '\|')
    $escaped = $escaped.Replace('`', '\`')
    return $escaped -replace "(`r`n|`n|`r)", '<br>'
}

function ConvertFrom-PushRecordMarkdownCell {
    param([Parameter(Mandatory = $true)] [string] $Value)

    return $Value.Replace('\|', '|').Replace('\`', '`').Replace('<br>', "`n")
}

function Get-PushRecordCells {
    param([Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Line)

    if (-not $Line.StartsWith('|') -or -not $Line.EndsWith('|')) {
        return @()
    }
    $inner = $Line.Substring(1, $Line.Length - 2)
    return @([regex]::Split($inner, '(?<!\\)\|') | ForEach-Object {
        ConvertFrom-PushRecordMarkdownCell $_.Trim()
    })
}

function Get-PushRecordMutexName {
    param([Parameter(Mandatory = $true)] [string] $Path)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant())
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
        return "Global\GitHubLocalIndexPushRecord_$($hash.Substring(0, 24))"
    }
    finally {
        $sha.Dispose()
    }
}

function Test-PushRecordReasonSafety {
    param([Parameter(Mandatory = $true)] [string] $Value)

    if ($Value.Length -gt 1000) {
        throw 'Reason must be at most 1000 characters.'
    }
    if (@($Value -split "`r?`n").Count -gt 20) {
        throw 'Reason must be a concise summary, not a raw log.'
    }
    $secretPatterns = @(
        '-----BEGIN[ A-Z]+PRIVATE KEY-----',
        'ghp_[A-Za-z0-9]{36,}',
        'github_pat_[A-Za-z0-9_]{20,}',
        'xox[baprs]-[A-Za-z0-9-]{20,}',
        'sk-[A-Za-z0-9]{20,}'
    )
    foreach ($pattern in $secretPatterns) {
        if ($Value -match $pattern) {
            throw 'Reason contains material that resembles a secret.'
        }
    }
}

function Test-PushRecordDocument {
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [AllowEmptyCollection()] [string[]] $Lines,
        [string] $ExpectedRepo,
        [string] $ExpectedBranch,
        [string] $ExpectedCommit
    )

    $header = '| 时间 | 仓库 | 分支 | Commit | 决策理由 |'
    $separator = '|---|---|---|---|---|'
    if ($Lines -notcontains $header -or $Lines -notcontains $separator) {
        throw 'Push record document must use the five-column schema.'
    }
    if (@($Lines | Where-Object { $_ -like '更新时间：*' }).Count -ne 1) {
        throw 'Push record document must contain exactly one update timestamp.'
    }

    if ($ExpectedRepo) {
        $matches = 0
        foreach ($line in $Lines) {
            $cells = @(Get-PushRecordCells -Line $line)
            if ($cells.Count -ne 5) { continue }
            if ($cells[1] -ieq $ExpectedRepo -and $cells[2] -ceq $ExpectedBranch -and $cells[3] -ieq $ExpectedCommit) {
                $matches++
            }
        }
        if ($matches -ne 1) {
            throw 'Push record validation did not find exactly one idempotency key.'
        }
    }
}

function Add-PushRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Repo,
        [Parameter(Mandatory = $true)] [string] $Branch,
        [Parameter(Mandatory = $true)] [string] $Commit,
        [Parameter(Mandatory = $true)] [string] $Reason,
        [Parameter(Mandatory = $true)] [string] $LogPath
    )

    if ($Repo -notmatch '^(?<owner>[A-Za-z0-9_.-]+)/(?<name>[A-Za-z0-9_.-]+)$') {
        throw 'Repo must be a normalized owner/name slug.'
    }
    $normalizedRepo = "$($matches['owner'].ToLowerInvariant())/$($matches['name'].ToLowerInvariant())"
    if ([string]::IsNullOrWhiteSpace($Branch) -or $Branch.Length -gt 255) {
        throw 'Branch must be nonempty and at most 255 characters.'
    }
    if ($Commit -notmatch '^[0-9a-fA-F]{7,64}$') {
        throw 'Commit must be a 7-64 character hexadecimal identifier.'
    }
    $normalizedCommit = $Commit.ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($Reason)) {
        throw 'Reason must be nonempty.'
    }
    Test-PushRecordReasonSafety -Value $Reason

    $resolvedLogPath = [System.IO.Path]::GetFullPath($LogPath)
    if (-not (Test-Path -LiteralPath $resolvedLogPath -PathType Leaf)) {
        throw 'Push record document does not exist.'
    }

    $mutex = [System.Threading.Mutex]::new($false, (Get-PushRecordMutexName -Path $resolvedLogPath))
    $hasLock = $false
    try {
        try {
            $hasLock = $mutex.WaitOne([timespan]::FromSeconds(15))
        }
        catch [System.Threading.AbandonedMutexException] {
            $hasLock = $true
        }
        if (-not $hasLock) {
            throw 'Timed out waiting for the push record file lock.'
        }

        $lines = @(Get-Content -LiteralPath $resolvedLogPath -Encoding utf8)
        Test-PushRecordDocument -Lines $lines
        foreach ($line in $lines) {
            $cells = @(Get-PushRecordCells -Line $line)
            if ($cells.Count -ne 5) { continue }
            if ($cells[1] -ieq $normalizedRepo -and $cells[2] -ceq $Branch -and $cells[3] -ieq $normalizedCommit) {
                return [pscustomobject][ordered]@{
                    changed = $false
                    repo = $normalizedRepo
                    branch = $Branch
                    commit = $normalizedCommit
                }
            }
        }

        $time = [DateTime]::UtcNow.AddHours(8).ToString('yyyy-MM-dd HH:mm:ss') + ' +08:00'
        $newRow = '| {0} | {1} | {2} | {3} | {4} |' -f `
            $time,
            (ConvertTo-PushRecordMarkdownCell $normalizedRepo),
            (ConvertTo-PushRecordMarkdownCell $Branch),
            $normalizedCommit,
            (ConvertTo-PushRecordMarkdownCell $Reason)

        $newLines = [System.Collections.Generic.List[string]]::new()
        $inserted = $false
        foreach ($line in $lines) {
            if ($line -like '更新时间：*') {
                $newLines.Add("更新时间：$time")
            }
            else {
                $newLines.Add($line)
                if (-not $inserted -and $line -eq '|---|---|---|---|---|') {
                    $newLines.Add($newRow)
                    $inserted = $true
                }
            }
        }
        if (-not $inserted) {
            throw 'Could not locate the push record table separator.'
        }

        $text = ($newLines -join [Environment]::NewLine) + [Environment]::NewLine
        $directory = Split-Path -Parent $resolvedLogPath
        $temporaryPath = Join-Path $directory ('.push-record-{0}-{1}.tmp' -f $PID, [guid]::NewGuid().ToString('N'))
        $backupPath = Join-Path $directory ('.push-record-{0}-{1}.bak' -f $PID, [guid]::NewGuid().ToString('N'))
        try {
            [System.IO.File]::WriteAllText($temporaryPath, $text, [System.Text.UTF8Encoding]::new($false))
            $writtenLines = @(Get-Content -LiteralPath $temporaryPath -Encoding utf8)
            Test-PushRecordDocument -Lines $writtenLines -ExpectedRepo $normalizedRepo -ExpectedBranch $Branch -ExpectedCommit $normalizedCommit
            [System.IO.File]::Replace($temporaryPath, $resolvedLogPath, $backupPath, $true)
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
        finally {
            Remove-Item -LiteralPath $temporaryPath, $backupPath -Force -ErrorAction SilentlyContinue
        }

        return [pscustomobject][ordered]@{
            changed = $true
            repo = $normalizedRepo
            branch = $Branch
            commit = $normalizedCommit
        }
    }
    finally {
        if ($hasLock) {
            [void] $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $result = Add-PushRecord -Repo $Repo -Branch $Branch -Commit $Commit -Reason $Reason -LogPath $LogPath
        if ($Json) {
            $result | ConvertTo-Json -Compress
        }
        else {
            $result
        }
        exit 0
    }
    catch {
        if ($Json) {
            [Console]::Error.WriteLine(([pscustomobject]@{ changed = $false; error = 'push_record_rejected' } | ConvertTo-Json -Compress))
        }
        else {
            Write-Error $_.Exception.Message
        }
        exit 1
    }
}
