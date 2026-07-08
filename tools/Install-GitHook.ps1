# Install-GitHook.ps1
# 安装 Git Pre-Commit Hook 物理防泄露门禁

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$gitHooksDir = Join-Path $scriptPath "..\.git\hooks"
$gitHooksDir = [System.IO.Path]::GetFullPath($gitHooksDir)

if (-not (Test-Path -Path $gitHooksDir)) {
    Write-Error "❌ Git hooks directory not found at: $gitHooksDir. Make sure this is a Git repository."
    exit 1
}

$hookPath = Join-Path $gitHooksDir "pre-commit"

# Shell 拦截代码内容
$hookContent = @'
#!/bin/sh

# Get staged files
staged_files=$(git diff --cached --name-only)

# If staged is empty, exit early to avoid syntax errors
[ -z "$staged_files" ] && exit 0

# Blacklisted paths and extensions
blacklist_paths="99_private/|secrets/|private_key|client_secret|\.env$|\.pem$|\.key$"

for file in $staged_files; do
    # Skip whitelist files
    if [ "$file" = ".gitignore" ] || [ "$file" = "AGENTS.md" ] || [ "$file" = "README.md" ] || [ "$file" = "03_推送决策/已推送记录.md" ] || [ "$file" = "03_推送决策/已推送记录_2026_归档.md" ] || [ "$file" = "tools/Add-PushRecord.ps1" ] || [ "$file" = "tools/Install-GitHook.ps1" ]; then
        continue
    fi

    # 1. Check path blacklist
    if echo "$file" | grep -Ei "$blacklist_paths" > /dev/null; then
        echo "❌ [Security Alert] Blocked staged file path: $file"
        exit 1
    fi

    # 2. Check content for private keys or tokens
    if git diff --cached "$file" | grep -Ei -e "-----BEGIN[ A-Z]+PRIVATE KEY-----|ghp_[a-zA-Z0-9]{36}" > /dev/null; then
        echo "❌ [Security Alert] Blocked commit: File '$file' contains sensitive private keys or tokens."
        exit 1
    fi
done

exit 0
'@

try {
    # 强制将 CRLF 转换为 LF，确保 Git Bash 兼容 shebang 并防止 Unexpected Token 报错
    $unixContent = $hookContent.Replace("`r`n", "`n")
    # 使用 UTF-8 无 BOM 编码保存文件，防止中文路径乱码并支持 Unix Bash Shebang
    $utf8NoBOM = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($hookPath, $unixContent, $utf8NoBOM)
    Write-Host "✅ Git pre-commit hook installed successfully at: $hookPath" -ForegroundColor Green
}
catch {
    Write-Error "❌ Failed to install Git hook: $_"
    exit 1
}
