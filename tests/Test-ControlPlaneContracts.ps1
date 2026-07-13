#requires -Version 7.0

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$script:Failures = 0

function ConvertTo-LfNewlines {
    param([AllowEmptyString()] [string] $Text)
    $Text.Replace("`r`n", "`n").Replace("`r", "`n")
}

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

function Get-ContractContentViolations {
    param([Parameter(Mandatory = $true)] [string] $Text)

    $Text = ConvertTo-LfNewlines $Text
    $violations = [System.Collections.Generic.List[string]]::new()
    $dynamicFactName = '(?:observed_utc|current_branch|default_branch|branch|commit|head|dirty_count|ahead|behind)'
    $providerJsonField = '(?:schema|observed_utc|repo|remote_url|visibility|default_branch|local_root|git_common_dir|remote_mode|decision|push_decision|push_strategy|reasons|errors|worktrees|dirty_summary|sync_state)'
    $dynamicFactAssignmentPattern = "(?im)^\s*$dynamicFactName\s*[:=]\s*\S+"
    $dynamicFactTablePattern = "(?im)^\s*\|?\s*$dynamicFactName\s*\|\s*(?![-:|\s]*(?:\|\s*)?$)[^|\r\n]+(?:\|\s*)?$"
    $providerJsonPattern = '(?is)"{0}"\s*:' -f $providerJsonField

    if ($Text -match '(?i)\b[0-9a-f]{40}\b') {
        $violations.Add('commit_hash')
    }
    if ($Text -match $dynamicFactAssignmentPattern -or $Text -match $dynamicFactTablePattern) {
        $violations.Add('dynamic_git_fact')
    }
    if ($Text -match $providerJsonPattern) {
        $violations.Add('raw_provider_json')
    }
    if ($Text -match '(?m)^\| 时间 \| 仓库 \| 分支 \| Commit \| 决策理由 \|$') {
        $violations.Add('old_push_record_table')
    }
    if ($Text -match '(?i)E:\\PCConfig\\registries\\|(?:project_config_keys|project_cards|tasks|task_purpose_catalog|scheduled_task_rebuild_plan)\.json') {
        $violations.Add('pcconfig_registry')
    }
    if ($Text -match '(?i)(raw[_ -]?log|原始日志|\.log\b|\\logs?\\)') {
        $violations.Add('raw_log')
    }
    if ($Text -match '(?i)<\?xml|<Task\b|<TaskDefinition\b') {
        $violations.Add('task_xml')
    }
    if ($Text -match '(?i)(?:ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|(?:password|token|secret|client_secret)\s*[:=]\s*\S{8,}|Authorization\s*:\s*Bearer\s+\S+)') {
        $violations.Add('secret_value')
    }

    $violations
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
    'git.project-admission' = @('git_project|repo_identity|project_entry', 'optional structured evidence', 'decision=block', 'read-only diagnosis', 'cached', 'github-local-index.project-admission.v1')
    'git.worktree-sync' = @('worktree|dirty|sync|ahead_behind', 'all worktrees', 'fails closed', 'locked', 'prunable')
    'git.push-publication' = @('push|publication|visibility|public_repo', 'transport readiness', 'candidate commits', '不输出 publication_decision', 'PUBLIC review', '唯一维护')
    'git.refresh-consistency' = @('refresh|consistency|index_drift', 'compatibility mode', 'private log', 'CheckOnly', 'system temp', '日常项目任务不需要')
    'git.milestone-record' = @('milestone|push_record', 'pure-file', 'idempotent', 'not zero-write', 'no Git transaction', 'no runtime provider/schema')
}

$unsafeFixtures = @(
    [pscustomobject]@{
        Name = 'unfenced provider-shaped JSON'
        Text = '{"observed_utc":"2026-07-10T00:00:00Z","worktrees":[]}'
        Violation = 'raw_provider_json'
    },
    [pscustomobject]@{
        Name = 'uppercase fenced provider-shaped JSON'
        Text = @'
```JSON
{"SCHEMA":"github-local-index.project-admission.v1","WORKTREES":[]}
```
'@
        Violation = 'raw_provider_json'
    },
    [pscustomobject]@{
        Name = 'Markdown current branch fact'
        Text = '| branch | main |'
        Violation = 'dynamic_git_fact'
    },
    [pscustomobject]@{
        Name = 'compact case-insensitive branch fact'
        Text = 'BRANCH|main'
        Violation = 'dynamic_git_fact'
    },
    [pscustomobject]@{
        Name = 'fenced mixed-case branch fact'
        Text = @'
```text
Branch | main
```
'@
        Violation = 'dynamic_git_fact'
    }
)
foreach ($fixture in $unsafeFixtures) {
    $violations = @(Get-ContractContentViolations -Text $fixture.Text)
    Assert-True ($violations -contains $fixture.Violation) "validator rejects $($fixture.Name)"
}

$stableBranchProse = 'A branch without upstream is a stable limitation, not a current Git fact.'
Assert-Equal 0 @(Get-ContractContentViolations -Text $stableBranchProse).Count 'validator allows stable branch limitation prose'

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
    $text = ConvertTo-LfNewlines (Get-Content -LiteralPath $path -Raw -Encoding utf8)
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

    $contentViolations = @(Get-ContractContentViolations -Text $text)
    Assert-True (-not ($contentViolations -contains 'commit_hash')) "$id excludes commit hashes"
    Assert-True (-not ($contentViolations -contains 'dynamic_git_fact')) "$id excludes dynamic Git fact fields and tables"
    Assert-True (-not ($contentViolations -contains 'raw_provider_json')) "$id excludes raw provider JSON regardless of fence or case"
    Assert-True (-not ($contentViolations -contains 'old_push_record_table')) "$id excludes old push-record tables"
    Assert-True (-not ($contentViolations -contains 'pcconfig_registry')) "$id excludes PCConfig registries"
    Assert-True (-not ($contentViolations -contains 'raw_log')) "$id excludes raw logs"
    Assert-True (-not ($contentViolations -contains 'task_xml')) "$id excludes task XML"
    Assert-True (-not ($contentViolations -contains 'secret_value')) "$id excludes secret-shaped values"
}

Assert-True ($totalBytes -le 20480) 'all Git contract cards total at most 20 KiB'

$matrixPath = '05_规则与模板/推送放行与否决规则.md'
$matrixText = Get-Content -LiteralPath (Join-Path $repoRoot $matrixPath) -Raw -Encoding utf8
$matrixLines = @(
    'decision=block => insufficient admission evidence; no write or direct transport, read-only diagnosis remains allowed',
    'decision!=block && push_decision!=proceed => direct transport not ready; diagnosis remains allowed',
    'push_decision=proceed => transport conditions only, never publication authorization',
    'visibility=PUBLIC => review fresh visibility, candidate commits, paths and content'
)
$lastIndex = -1
foreach ($line in $matrixLines) {
    $index = $matrixText.IndexOf($line, [System.StringComparison]::Ordinal)
    Assert-True ($index -gt $lastIndex) "$matrixPath contains ordered matrix line: $line"
    $lastIndex = $index
}

$summaryDocuments = @('AGENTS.md', 'README.md', '我的 GitHub 项目管理指南.md')
foreach ($relativePath in $summaryDocuments) {
    $documentText = Get-Content -LiteralPath (Join-Path $repoRoot $relativePath) -Raw -Encoding utf8
    Assert-True ($documentText.Contains('推送放行与否决规则')) "$relativePath points to the sole publication matrix"
    foreach ($line in $matrixLines) {
        Assert-True (-not $documentText.Contains($line)) "$relativePath does not duplicate full matrix line: $line"
    }
}

$matrixSignature = $matrixLines[-1]
$matrixCopies = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter '*.md' | Where-Object {
    (Get-Content -LiteralPath $_.FullName -Raw -Encoding utf8).Contains($matrixSignature)
})
Assert-Equal 1 $matrixCopies.Count 'full publication matrix has exactly one Markdown copy'
Assert-Equal $matrixPath ($matrixCopies[0].FullName.Substring($repoRoot.Length + 1).Replace('\', '/')) 'full publication matrix lives in the designated rule file'

$fixedRitualPhrases = @(
    '以后修改任意 Git 项目时',
    '普通项目任务直接运行 admission/fast-path',
    '如果改动涉及绝对路径',
    '本地必须通过运行 `tools/Install-GitHook.ps1`',
    '项目收尾可用 `tools/Refresh-GitHubLocalIndex.ps1 -Fast',
    '项目开工先查 admission'
)
foreach ($relativePath in $summaryDocuments) {
    $documentText = Get-Content -LiteralPath (Join-Path $repoRoot $relativePath) -Raw -Encoding utf8
    foreach ($phrase in $fixedRitualPhrases) {
        Assert-True (-not $documentText.Contains($phrase)) "$relativePath excludes fixed ritual: $phrase"
    }
}

$activeMarkdownFiles = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter '*.md' | Where-Object {
    $relativePath = $_.FullName.Substring($repoRoot.Length + 1).Replace('\', '/')
    $relativePath -notmatch '^(?:99_private|docs/superpowers/plans|90_历史审计)/'
})
$absolutePathPcConfigRequirement = '(?im)^(?=[^\r\n]*涉及绝对路径)(?=[^\r\n]*PCConfig)(?=[^\r\n]*(?:必须|都应|应当|需要|需查询))[^\r\n]*$'
$ordinaryRefreshRequirement = '(?im)^(?=[^\r\n]*(?:任何|普通))(?=[^\r\n]*(?:移动|归档|删除|总索引更新))(?=[^\r\n]*(?:刷新|refresh))(?=[^\r\n]*PCConfig)(?=[^\r\n]*(?:必须|都应|应当|需要|需查询))[^\r\n]*$'
foreach ($file in $activeMarkdownFiles) {
    $relativePath = $file.FullName.Substring($repoRoot.Length + 1).Replace('\', '/')
    $documentText = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
    Assert-True (-not ($documentText -match $absolutePathPcConfigRequirement)) "$relativePath does not require PCConfig merely because an absolute path is involved"
    Assert-True (-not ($documentText -match $ordinaryRefreshRequirement)) "$relativePath does not force PCConfig refresh for ordinary move, archive, delete, or index work"
}

$agentsText = Get-Content -LiteralPath (Join-Path $repoRoot 'AGENTS.md') -Raw -Encoding utf8
$readmeText = Get-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Raw -Encoding utf8
$guideText = Get-Content -LiteralPath (Join-Path $repoRoot '我的 GitHub 项目管理指南.md') -Raw -Encoding utf8
Assert-True ($agentsText.Contains('信息价值')) 'AGENTS routes provider use by information value'
Assert-True ($readmeText.Contains('不要求每个 Git 任务执行固定命令链')) 'README rejects a fixed command chain'
Assert-True ($guideText.Contains('不是每个项目任务必须逐站通过的流水线')) 'guide explains owner dispatch instead of a pipeline'
Assert-True ($guideText.Contains('只有当前决定依赖路径')) 'guide uses semantic PCConfig routing'

foreach ($relativePath in @('AGENTS.md', 'README.md')) {
    $routeText = Get-Content -LiteralPath (Join-Path $repoRoot $relativePath) -Raw -Encoding utf8
    Assert-True ($routeText -match 'docs[/\\]contracts') "$relativePath exposes the owner-local contract whitebox route"
}

$pushRuleText = $matrixText
Assert-True ($pushRuleText.Contains('read-only diagnosis remains allowed')) 'push rule preserves read-only diagnosis when admission evidence blocks writes'
Assert-True ($pushRuleText.Contains('preserve exact content')) 'push rule preserves exact content for trusted private backup targets'
Assert-True ($pushRuleText.Contains('wlyaaaaa/Key')) 'push rule preserves the Key no-clone boundary'
Assert-True ($pushRuleText.Contains('transport ready') -and $pushRuleText.Contains('publication safe') -and $pushRuleText.Contains('authorization present')) 'push rule separates transport, publication, and authorization'

if ($script:Failures -gt 0) {
    throw "$script:Failures test(s) failed"
}

Write-Host 'All control-plane contract tests passed.'
