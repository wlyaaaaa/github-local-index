#requires -Version 7.0

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$script:Failures = 0

function Assert-Equal {
    param(
        [AllowNull()] [object] $Expected,
        [AllowNull()] [object] $Actual,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    if ($Expected -ne $Actual) {
        Write-Host "FAIL: $Name"
        Write-Host "  expected: $Expected"
        Write-Host "  actual:   $Actual"
        $script:Failures++
        return
    }

    Write-Host "PASS: $Name"
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)] [bool] $Condition,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    if (-not $Condition) {
        Write-Host "FAIL: $Name"
        $script:Failures++
        return
    }

    Write-Host "PASS: $Name"
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$contractRoot = Join-Path $repoRoot 'docs/contracts'
$ids = @(
    'git.project-admission',
    'git.worktree-sync',
    'git.push-publication',
    'git.refresh-consistency',
    'git.milestone-record'
)
$headings = @(
    '产品目标', '触发条件', 'owner 与权威', '权威输入', '核心机制', '输出合同',
    '失败与降级', '验证证据', '上下文策略', '已知限制', '扩展入口'
)
$requiredContent = @{
    'git.project-admission' = @('git_project|repo_identity|project_entry', 'decision', 'read-only admission', 'cached', 'warn', 'Markdown', 'machine authority')
    'git.worktree-sync' = @('worktree|dirty|sync|ahead_behind', 'all worktrees', 'fails closed', 'locked', 'prunable')
    'git.push-publication' = @('push|publication|visibility|public_repo', 'transport readiness', '不代表公开发布授权', '不输出 publication_decision', 'PUBLIC')
    'git.refresh-consistency' = @('refresh|consistency|index_drift', 'Fast', 'private log', 'CheckOnly', 'system temp', 'zero_write')
    'git.milestone-record' = @('milestone|push_record', 'pure-file', 'idempotent', 'not zero-write', 'no Git transaction', 'no runtime provider/schema')
}

$actualFiles = @()
if (Test-Path -LiteralPath $contractRoot) {
    $actualFiles = @(Get-ChildItem -LiteralPath $contractRoot -File -Filter '*.md' | Sort-Object Name)
}
$expectedNames = @($ids | ForEach-Object { "$_.md" } | Sort-Object)
$actualNames = @($actualFiles.Name)
Assert-Equal ($expectedNames -join '|') ($actualNames -join '|') 'contract directory contains exactly the five Git contract files'

$totalBytes = 0L
foreach ($id in $ids) {
    $path = Join-Path $contractRoot "$id.md"
    $exists = Test-Path -LiteralPath $path -PathType Leaf
    Assert-True $exists "$id contract exists"
    if (-not $exists) { continue }

    $file = Get-Item -LiteralPath $path
    $text = Get-Content -LiteralPath $path -Raw -Encoding utf8
    $lines = @([regex]::Split($text.TrimEnd(), "`r?`n"))
    $actualHeadings = @([regex]::Matches($text, '(?m)^## (.+)$') | ForEach-Object { $_.Groups[1].Value })
    $totalBytes += $file.Length

    Assert-True ($text -match ('\A# ' + [regex]::Escape($id) + '\r?\n')) "$id begins with its exact ID"
    Assert-Equal ($headings -join '|') ($actualHeadings -join '|') "$id has the eleven ordered H2 headings"
    Assert-True ($text -match '(?m)^owner: E:\\GitHub总索引$') "$id declares the GitHub index owner"
    Assert-True ($file.Length -le 4096) "$id is at most 4 KiB"
    Assert-True ($lines.Count -le 80) "$id is at most 80 lines"

    foreach ($phrase in $requiredContent[$id]) {
        Assert-True ($text.Contains($phrase)) "$id contains required phrase: $phrase"
    }

    Assert-True (-not ($text -match '(?i)\b[0-9a-f]{40}\b')) "$id excludes commit hashes"
    Assert-True (-not ($text -match '(?im)^\s*(observed_utc|current_branch|default_branch|branch|commit|head|dirty_count|ahead|behind)\s*:')) "$id excludes dynamic Git fact fields"
    Assert-True (-not ($text -match '(?ms)```json\b.*?"(?:schema|worktrees|observed_utc)"\s*:')) "$id excludes raw provider JSON"
    Assert-True (-not ($text -match '(?m)^\| 时间 \| 仓库 \| 分支 \| Commit \| 决策理由 \|$')) "$id excludes old push-record tables"
    Assert-True (-not ($text -match '(?i)E:\\PCConfig\\registries\\|(?:project_config_keys|project_cards|tasks|task_purpose_catalog|scheduled_task_rebuild_plan)\.json')) "$id excludes PCConfig registries"
    Assert-True (-not ($text -match '(?i)(raw[_ -]?log|原始日志|\.log\b|\\logs?\\)')) "$id excludes raw logs"
    Assert-True (-not ($text -match '(?i)<\?xml|<Task\b|<TaskDefinition\b')) "$id excludes task XML"
    Assert-True (-not ($text -match '(?i)(?:ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|(?:password|token|secret|client_secret)\s*[:=]\s*\S{8,}|Authorization\s*:\s*Bearer\s+\S+)')) "$id excludes secret-shaped values"
}

Assert-True ($totalBytes -le 20480) 'all Git contract cards total at most 20 KiB'

$twoGateLines = @(
    'decision=block => no write or push',
    'decision!=block && push_decision!=proceed => read-only diagnosis allowed, direct transport blocked',
    'push_decision=proceed => transport conditions only',
    'visibility=PUBLIC => separate publication review of rules, visibility, commits, paths and content'
)
$semanticDocuments = @(
    'AGENTS.md',
    'README.md',
    '我的 GitHub 项目管理指南.md',
    '05_规则与模板/推送放行与否决规则.md'
)
foreach ($relativePath in $semanticDocuments) {
    $documentText = Get-Content -LiteralPath (Join-Path $repoRoot $relativePath) -Raw -Encoding utf8
    $lastIndex = -1
    foreach ($line in $twoGateLines) {
        $index = $documentText.IndexOf($line, [System.StringComparison]::Ordinal)
        Assert-True ($index -gt $lastIndex) "$relativePath contains ordered two-gate line: $line"
        $lastIndex = $index
    }
}

foreach ($relativePath in @('AGENTS.md', 'README.md')) {
    $routeText = Get-Content -LiteralPath (Join-Path $repoRoot $relativePath) -Raw -Encoding utf8
    Assert-True ($routeText -match 'docs[/\\]contracts') "$relativePath exposes the owner-local contract whitebox route"
}

if ($script:Failures -gt 0) {
    throw "$script:Failures test(s) failed"
}

Write-Host 'All control-plane contract tests passed.'
