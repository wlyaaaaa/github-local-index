[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Repo,

    [Parameter(Mandatory=$true)]
    [string]$Branch,

    [Parameter(Mandatory=$true)]
    [string]$Commit,

    [Parameter(Mandatory=$true)]
    [string]$Reason,

    [Parameter(Mandatory=$false)]
    [switch]$PushIndex
)

# 1. 自动计算中国时间 (UTC+8)
$utcNow = [DateTime]::UtcNow
$chinaTime = $utcNow.AddHours(8)
$timeStr = $chinaTime.ToString("yyyy-MM-dd HH:mm:ss") + " +08:00"

# 2. 定位日志文件绝对路径
$logPath = Join-Path $PSScriptRoot "..\03_推送决策\已推送记录.md"
$logPath = [System.IO.Path]::GetFullPath($logPath)

if (-not (Test-Path -Path $logPath)) {
    Write-Error "❌ Target log file does not exist at: $logPath"
    exit 1
}

# 3. 读取现有日志内容并 Prepend 插入 (引入全局 Mutex 锁防止并发争用)
$mutexName = "Global\GitHubLocalIndexMutex"
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($false, $mutexName, [ref]$createdNew)

Write-Host "Acquiring file write lock..." -ForegroundColor Gray
$hasLock = $mutex.WaitOne(15000) # 最多等待 15 秒

if (-not $hasLock) {
    Write-Error "❌ Timeout waiting for another Agent to finish writing the log file."
    $mutex.Dispose()
    exit 1
}

try {
    Write-Host "Reading log file: $logPath" -ForegroundColor Gray
    $contentLines = Get-Content -Path $logPath -Encoding utf8

    $newRow = "| $timeStr | ``$Repo`` | ``$Branch`` | $Reason |"
    $newLines = [System.Collections.Generic.List[string]]::new()
    $updatedTimestamp = $false
    $insertedRow = $false

    foreach ($line in $contentLines) {
        if ($line -like "更新时间：*") {
            $newLines.Add("更新时间：$timeStr")
            $updatedTimestamp = $true
        } elseif ($line -eq "|---|---|---|---|") {
            $newLines.Add($line)
            $newLines.Add($newRow)
            $insertedRow = $true
        } else {
            $newLines.Add($line)
        }
    }

    if (-not $updatedTimestamp) {
        Write-Warning "⚠️ Could not find '更新时间：' line to update."
    }
    if (-not $insertedRow) {
        Write-Warning "⚠️ Could not find table separator '|---|---|---|---|' to prepend row."
    }

    # 4. Safe-Save 防丢保存规程
    $tmpPath = $logPath + ".tmp"
    try {
        # 强制写入临时文件 (使用 UTF-8)
        $newLines | Set-Content -Path $tmpPath -Encoding utf8

        # 门禁验证大小 (由于是 Slimmed 日志，文件必须大于 50 字节且大于或等于原文件大小扣除少许偏差)
        $originalSize = (Get-Item -Path $logPath).Length
        $tmpSize = (Get-Item -Path $tmpPath).Length

        if ($tmpSize -ge ($originalSize - 100) -and $tmpSize -gt 50) {
            # 原子性覆盖
            Move-Item -Path $tmpPath -Destination $logPath -Force
            Write-Host "✅ Log successfully prepended and verified: $logPath" -ForegroundColor Green
        } else {
            throw "Validation failed: Temp file size ($tmpSize) is abnormally smaller than original ($originalSize)."
        }
    }
    catch {
        if (Test-Path -Path $tmpPath) {
            Remove-Item -Path $tmpPath -Force
        }
        throw $_
    }
}
finally {
    # 释放互斥锁
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}

# 5. Git 本地 Commit 与按需 Push
$indexRoot = Join-Path $PSScriptRoot ".."
$indexRoot = [System.IO.Path]::GetFullPath($indexRoot)

function Test-SecretsLeak {
    # 获取暂存和未跟踪的文件（排除已被 gitignore 的）
    $gitFiles = git status --porcelain | ForEach-Object {
        if ($_ -match '^[AM\?\s]{2}\s+(.+)$') {
            $Matches[1].Trim('"')
        }
    }

    if (-not $gitFiles) { return $true }

    # 敏感文件名/路径黑名单模式
    $blacklistedPaths = @(
        "99_private/",
        "secrets/",
        "private_key",
        "client_secret",
        "\.env$",
        "\.pem$",
        "\.key$"
    )

    # 敏感内容正则表达式模式
    $blacklistedContentPatterns = @(
        "-----BEGIN[ A-Z]+PRIVATE KEY-----",
        "ghp_[a-zA-Z0-9]{36}",
        "xox[bapr]-[0-9]+-[0-9]+-[a-zA-Z0-9]+" # Slack token
    )

    # 排除白名单文件（这些文件允许包含常规索引词）
    $whitelistFiles = @(
        ".gitignore",
        "AGENTS.md",
        "README.md",
        "03_推送决策/已推送记录.md",
        "03_推送决策/已推送记录_2026_归档.md",
        "tools/Add-PushRecord.ps1",
        "tools/Install-GitHook.ps1"
    )

    foreach ($file in $gitFiles) {
        # 排除白名单
        if ($file -in $whitelistFiles -or $file -match "tools/Add-PushRecord.ps1" -or $file -match "tools/Install-GitHook.ps1") { continue }

        # 1. 校验路径是否触网
        foreach ($pattern in $blacklistedPaths) {
            if ($file -match $pattern) {
                Write-Host "❌ [Security Alert] Blocked file path matching pattern '$pattern': $file" -ForegroundColor Red
                return $false
            }
        }

        # 2. 校验文件内容是否触网 (只扫描文本文件)
        $fullPath = Join-Path $indexRoot $file
        $fullPath = [System.IO.Path]::GetFullPath($fullPath)

        if (Test-Path -Path $fullPath -PathType Leaf) {
            $fileItem = Get-Item -Path $fullPath
            if ($fileItem.Length -gt 5MB) { continue }

            try {
                $content = Get-Content -Path $fullPath -Raw -Encoding utf8
                foreach ($pattern in $blacklistedContentPatterns) {
                    if ($content -match $pattern) {
                        Write-Host "❌ [Security Alert] Blocked file '$file' contains sensitive pattern '$pattern'" -ForegroundColor Red
                        return $false
                    }
                }
            }
            catch {
                # 忽略读取失败（可能是二进制文件）
            }
        }
    }

    return $true
}

Push-Location $indexRoot
try {
    Write-Host "Running pre-commit security scan..." -ForegroundColor Gray
    if (-not (Test-SecretsLeak)) {
        Write-Error "❌ Git commit aborted due to security policy violations."
        exit 1
    }

    Write-Host "Staging and committing index changes..." -ForegroundColor Gray
    git add "03_推送决策/已推送记录.md" "03_推送决策/已推送记录_2026_归档.md"

    $commitMsg = "docs: log push of $Repo ($Commit)"
    git commit -m $commitMsg

    if ($PushIndex) {
        $maxRetries = 3
        $retryCount = 0
        $pushed = $false

        while (-not $pushed -and $retryCount -lt $maxRetries) {
            $retryCount++
            Write-Host "🚀 Pushing index repository (Attempt $retryCount/$maxRetries)..." -ForegroundColor Cyan
            git push

            if ($LASTEXITCODE -eq 0) {
                $pushed = $true
                Write-Host "✅ Push succeeded!" -ForegroundColor Green
            } else {
                if ($retryCount -lt $maxRetries) {
                    Write-Warning "⚠️ Git push rejected. Attempting to pull and rebase..."
                    git pull --rebase origin main
                    if ($LASTEXITCODE -ne 0) {
                        Write-Error "❌ Git pull --rebase failed. Manual conflict resolution required."
                        exit 1
                    }
                }
            }
        }

        if (-not $pushed) {
            Write-Error "❌ Failed to push index repository after $maxRetries attempts."
            exit 1
        }
    } else {
        Write-Host "💡 Tier 1 Closeout: Commit finalized locally. Remote push deferred." -ForegroundColor Yellow
    }
}
catch {
    Write-Error "❌ Git operation encountered an error: $_"
    exit 1
}
finally {
    Pop-Location
}
