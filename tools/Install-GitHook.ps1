#requires -Version 7.0

[CmdletBinding()]
param(
    [string] $RepoPath = (Split-Path -Parent $PSScriptRoot)
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$hooksOutput = @(& git -C $RepoPath rev-parse --path-format=absolute --git-path hooks 2>&1)
if ($LASTEXITCODE -ne 0 -or $hooksOutput.Count -ne 1) {
    throw 'Unable to resolve the Git hooks directory.'
}
$hooksDirectory = [System.IO.Path]::GetFullPath([string] $hooksOutput[0])
if (-not (Test-Path -LiteralPath $hooksDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $hooksDirectory -Force | Out-Null
}
$hookPath = Join-Path $hooksDirectory 'pre-commit'

$hookContent = @'
#!/bin/sh

# Public repository secret gate. Keep this file ASCII and deterministic.
blacklist_paths='(^|/)(99_private|secrets?)(/|$)|private[_-]?key|client[_-]?secret|\.env$|\.(pem|key|p12|pfx)$'
secret_patterns='-----BEGIN[ A-Z]+PRIVATE KEY-----|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}'

git diff --cached --name-only | while IFS= read -r file; do
    [ -z "$file" ] && continue
    if printf '%s\n' "$file" | grep -Eiq "$blacklist_paths"; then
        printf '%s\n' "Blocked staged path: $file" >&2
        exit 1
    fi
    if git diff --cached -- "$file" | grep -Eiq -- "$secret_patterns"; then
        printf '%s\n' "Blocked staged content in: $file" >&2
        exit 1
    fi
done
'@

$normalized = $hookContent.Replace("`r`n", "`n").TrimEnd("`n") + "`n"
[System.IO.File]::WriteAllText($hookPath, $normalized, [System.Text.UTF8Encoding]::new($false))
[pscustomobject]@{ hook_path = $hookPath; installed = $true }
