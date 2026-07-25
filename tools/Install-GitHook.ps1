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

$policyPath = Join-Path $PSScriptRoot 'PublicExposurePolicy.psd1'
$policy = Import-PowerShellDataFile -LiteralPath $policyPath
$alwaysBlockedPaths = [string] $policy.AlwaysBlockedPathRegex
$envPaths = [string] $policy.EnvPathRegex
$allowedTemplatePaths = [string] $policy.AllowedTemplateRegex
foreach ($expression in @($alwaysBlockedPaths, $envPaths, $allowedTemplatePaths)) {
    if ([string]::IsNullOrWhiteSpace($expression) -or $expression.Contains("'") -or $expression -match '[^\x20-\x7e]') {
        throw 'Public exposure path policy is not safe to embed in the portable hook.'
    }
}

$hookTemplate = @'
#!/bin/sh

# Public repository secret gate. Keep this file ASCII and deterministic.
always_blocked_paths='__ALWAYS_BLOCKED_PATH_REGEX__'
env_paths='__ENV_PATH_REGEX__'
allowed_template_paths='__ALLOWED_TEMPLATE_PATH_REGEX__'
secret_patterns='-----BEGIN[ A-Z]+PRIVATE KEY-----|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|sk-(proj-|svcacct-)?[A-Za-z0-9_-]{20,}|AIza[A-Za-z0-9_-]{35}|L[S]0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0t|L[S]0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQ|L[S]0tLS1CRUdJTiBFQyBQUklWQVRFIEtFWS0tLS0t|L[S]0tLS1CRUdJTiBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0'

git diff --cached --name-only --diff-filter=ACMRT -z | while IFS= read -r -d '' file; do
    [ -z "$file" ] && continue
    if printf '%s\n' "$file" | grep -Eiq "$always_blocked_paths" ||
       { printf '%s\n' "$file" | grep -Eiq "$env_paths" &&
         ! printf '%s\n' "$file" | grep -Eiq "$allowed_template_paths"; }; then
        printf '%s\n' "Blocked staged path: $file" >&2
        exit 1
    fi
    if git diff --cached --no-ext-diff --unified=0 --diff-filter=ACMRT -- "$file" |
        awk '/^@@ / { in_hunk = 1; next } in_hunk && /^\+/ { print }' |
        grep -Eiq -- "$secret_patterns"; then
        printf '%s\n' "Blocked staged content in: $file" >&2
        exit 1
    fi
done
'@
$hookContent = $hookTemplate.Replace('__ALWAYS_BLOCKED_PATH_REGEX__', $alwaysBlockedPaths)
$hookContent = $hookContent.Replace('__ENV_PATH_REGEX__', $envPaths)
$hookContent = $hookContent.Replace('__ALLOWED_TEMPLATE_PATH_REGEX__', $allowedTemplatePaths)

$normalized = $hookContent.Replace("`r`n", "`n").TrimEnd("`n") + "`n"
[System.IO.File]::WriteAllText($hookPath, $normalized, [System.Text.UTF8Encoding]::new($false))
[pscustomobject]@{ hook_path = $hookPath; installed = $true }
