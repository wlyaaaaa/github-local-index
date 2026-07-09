param(
    [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [switch] $NoWrite
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function ConvertTo-UserAutomationMarkdownCell {
    param([AllowNull()] [object] $Value)

    if ($null -eq $Value) {
        return ''
    }

    return ([string] $Value) -replace '\|', '\|' -replace "(\r\n|\n|\r)", '<br>'
}

function New-UserAutomationMarkdownTable {
    param(
        [string[]] $Headers,
        [string[]] $Properties,
        [object[]] $Rows
    )

    $lines = @()
    $lines += '| ' + ($Headers -join ' | ') + ' |'
    $lines += '| ' + (($Headers | ForEach-Object { '---' }) -join ' | ') + ' |'

    foreach ($row in $Rows) {
        $cells = foreach ($property in $Properties) {
            ConvertTo-UserAutomationMarkdownCell $row.$property
        }
        $lines += '| ' + ($cells -join ' | ') + ' |'
    }

    return $lines
}

function Set-UserAutomationTextFile {
    param(
        [string] $Path,
        [string[]] $Lines
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }

    $normalizedLines = @($Lines)
    while ($normalizedLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace([string] $normalizedLines[-1])) {
        if ($normalizedLines.Count -eq 1) {
            $normalizedLines = @()
            break
        }

        $normalizedLines = @($normalizedLines[0..($normalizedLines.Count - 2)])
    }

    $text = ($normalizedLines -join [Environment]::NewLine) + [Environment]::NewLine
    Set-Content -LiteralPath $Path -Value $text -Encoding UTF8 -NoNewline
}

function ConvertTo-UserAutomationTaskResultAssessment {
    param([AllowNull()] [object] $LastTaskResult)

    if ($null -eq $LastTaskResult) {
        return [pscustomobject]@{ Severity = '未知'; Summary = '尚无返回码'; CodeText = '' }
    }

    $signed = [int64] $LastTaskResult
    $unsigned = if ($signed -lt 0) { $signed + 4294967296 } else { $signed }
    $hex = '0x{0:X8}' -f $unsigned
    $codeText = "$unsigned / $hex"

    switch ($unsigned) {
        0 { return [pscustomobject]@{ Severity = '正常'; Summary = '返回码 0'; CodeText = $codeText } }
        267009 { return [pscustomobject]@{ Severity = '警告'; Summary = '任务仍在运行或上次状态未结束'; CodeText = $codeText } }
        267011 { return [pscustomobject]@{ Severity = '警告'; Summary = '任务尚未运行或无有效完成记录'; CodeText = $codeText } }
        3221225786 { return [pscustomobject]@{ Severity = '异常'; Summary = '中断退出，常见于注销、关机或任务被终止'; CodeText = $codeText } }
        default { return [pscustomobject]@{ Severity = '警告'; Summary = '非零返回码，需要结合任务日志复查'; CodeText = $codeText } }
    }
}

function Get-TaskActionTexts {
    param([object] $Task)

    $texts = @()
    foreach ($action in @($Task.Actions)) {
        $execute = [string] $action.Execute
        $arguments = [string] $action.Arguments
        $texts += (($execute, $arguments) -join ' ').Trim()
    }

    return @($texts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Test-IsCommonSoftwareTask {
    param([object] $Task)

    $name = [string] $Task.TaskName
    $path = [string] $Task.TaskPath
    $actionText = (Get-TaskActionTexts -Task $Task) -join ' '
    $combined = "$path $name $actionText"

    if ($path -like '\Microsoft\Windows\*') {
        return $true
    }

    $knownUserPattern = 'Backup|Sync|Mirror|Watchdog|Heartbeat|AutoPush|AutoStart'
    if ("$path $name $actionText" -match $knownUserPattern) {
        return $false
    }

    $commonPatterns = @(
        'GoogleUpdate',
        'MicrosoftEdgeUpdate',
        'Adobe.?Update',
        'AIDA64',
        'TrafficMonitor',
        'AMD',
        'Ryzen',
        'Driver Booster',
        'EXPERTool',
        '^GCC$',
        'iGCLite',
        'LConnect',
        'L-Connect',
        'MSIAfterburner',
        'RTSS',
        'SignalRgb',
        'StartAllBack',
        'StartAUEP',
        'StartCN',
        'StartDVR',
        'ViGEmBus',
        'XblGameSave',
        'SoftLanding',
        'CreateExplorerShellUnelevatedTask',
        'natpierce',
        'NVIDIA',
        'OneDrive',
        'Dropbox',
        'Steam Client',
        'Mozilla',
        'Chrome',
        'Intel',
        'Realtek',
        'Office'
    )

    foreach ($pattern in $commonPatterns) {
        if ($combined -match $pattern) {
            return $true
        }
    }

    return $false
}

function Test-IsUserAutomationTask {
    param([object] $Task)

    if (Test-IsCommonSoftwareTask -Task $Task) {
        return $false
    }

    $name = [string] $Task.TaskName
    $path = [string] $Task.TaskPath
    $actionText = (Get-TaskActionTexts -Task $Task) -join ' '
    $combined = "$path $name $actionText"

    $keywordPattern = 'Backup|AutoPush|Watchdog|Heartbeat|AutoStart|Sync|Mirror|Service|Gateway|自动|备份|同步|推送|看门狗|心跳|监控|自启'
    if ($combined -match $keywordPattern) {
        return $true
    }

    $pathPattern = '(^|["\s])([A-Z]:\\|powershell|pwsh|python|wscript|cscript|cmd\.exe|git\.exe)'
    if ($combined -match $pathPattern) {
        return $true
    }

    return $false
}

function Get-SanitizedPathFromText {
    param([AllowNull()] [string] $Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    $matches = [regex]::Matches($Text, '[A-Z]:\\.+?\.(ps1|vbs|bat|cmd|py|exe|js|ts|json|md|yml|yaml)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($matches.Count -eq 0) {
        $matches = [regex]::Matches($Text, '[A-Z]:\\[^\s"''<>|]+')
        if ($matches.Count -eq 0) {
            return ''
        }
    }

    $candidate = $matches[0].Value
    $extensionMatch = [regex]::Match($candidate, '^(?<path>.+?\.(ps1|vbs|bat|cmd|py|exe|js|ts|json|md|yml|yaml))(?=$|[^\w.-])', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($extensionMatch.Success) {
        return $extensionMatch.Groups['path'].Value
    }

    $parts = $candidate -split '\\'
    if ($parts.Count -gt 4) {
        return (($parts[0..3] -join '\') + '\...')
    }

    return $candidate
}

function Get-PublicActionSummary {
    param([object] $Task)

    $summaries = foreach ($action in @($Task.Actions)) {
        $execute = [string] $action.Execute
        $arguments = [string] $action.Arguments
        $exeName = if ([string]::IsNullOrWhiteSpace($execute)) { '未知执行器' } else { Split-Path -Leaf $execute }
        $scriptPath = Get-SanitizedPathFromText -Text $arguments
        if ([string]::IsNullOrWhiteSpace($scriptPath)) {
            $scriptPath = Get-SanitizedPathFromText -Text $execute
        }

        if ([string]::IsNullOrWhiteSpace($scriptPath)) {
            $exeName
        } else {
            "$exeName -> $scriptPath"
        }
    }

    return (@($summaries | Where-Object { $_ } | Sort-Object -Unique) -join '<br>')
}

function Get-RelatedPathHint {
    param(
        [string] $TaskName,
        [string] $ActionSummary
    )

    $path = Get-SanitizedPathFromText -Text "$TaskName $ActionSummary"
    if ($path) {
        return Split-Path -Parent $path
    }

    return ''
}

function Get-TaskPurposeInference {
    param(
        [string] $TaskName,
        [string] $ActionSummary
    )

    $combined = "$TaskName $ActionSummary"

    if ($combined -match 'Watchdog|Heartbeat|心跳|看门狗') {
        return [pscustomobject]@{
            Purpose = '看门狗/心跳守护'
            Why     = '保持本地服务、桥接或监控脚本持续可用，异常时便于自愈或告警。'
            Risk    = '若返回码持续非零或长时间 Running，需要确认是否卡住。'
        }
    }

    if ($combined -match 'AutoPush|\bgit(\.exe)?\b|推送') {
        return [pscustomobject]@{
            Purpose = '自动 Git 同步/推送'
            Why     = '减少本地改动滞留，保持备份或脚本仓库与 GitHub 同步。'
            Risk    = '公开仓库不能自动推送未脱敏内容；应保留显式审查。'
        }
    }

    if ($combined -match 'Sync|Mirror|同步|镜像') {
        return [pscustomobject]@{
            Purpose = '文件或配置同步'
            Why     = '减少重复手工复制并保持目标位置的恢复材料可用。'
            Risk    = '需要确认同步方向、删除策略、容量和失败重试边界。'
        }
    }

    if ($combined -match 'Backup|Snapshot|Memory|备份|快照') {
        return [pscustomobject]@{
            Purpose = '备份/恢复材料同步'
            Why     = '保留配置、记忆、知识库或个人数据的恢复点，支持换机和回滚。'
            Risk    = '私有备份仓库可保留敏感恢复材料；公开索引不得复制具体内容。'
        }
    }

    if ($combined -match 'AutoStart|Service|Gateway|Daemon|自启|服务') {
        return [pscustomobject]@{
            Purpose = '本地服务自启/运行保障'
            Why     = '登录或开机后自动恢复常驻服务，降低手工启动成本。'
            Risk    = '需要确认禁用任务是否仍有保留价值。'
        }
    }

    return [pscustomobject]@{
        Purpose = '用户自定义自动化'
        Why     = '任务名或动作指向用户脚本/仓库，推测用于减少重复手工操作。'
        Risk    = '用途需要结合脚本内容进一步确认。'
    }
}

function Get-IndexedRepositoryRows {
    param([string] $RepoRoot)

    $path = Join-Path $RepoRoot '01_仓库索引/GitHub仓库索引.md'
    if (-not (Test-Path -LiteralPath $path)) {
        return @()
    }

    $lines = Get-Content -LiteralPath $path
    foreach ($line in $lines) {
        if ($line -notmatch '^\| wlyaaaaa/') {
            continue
        }

        $cells = @($line.Trim('|') -split '\|')
        if ($cells.Count -lt 6) {
            continue
        }

        [pscustomobject]@{
            NameWithOwner = $cells[0].Trim()
            Visibility    = $cells[1].Trim()
            DefaultBranch = $cells[2].Trim()
            LocalPath     = $cells[3].Trim()
            LocalState    = $cells[4].Trim()
            NextAction    = $cells[5].Trim()
        }
    }
}

function Get-RepositoryTaskRecommendation {
    param(
        [string] $NameWithOwner,
        [string] $LocalPath,
        [string] $Visibility,
        [string[]] $ExistingTaskHints = @()
    )

    $hintText = ($ExistingTaskHints -join '；')

    if ($LocalPath -eq '未发现本地 clone') {
        $risk = '需要先决定是否 clone 到固定目录。'
        if ($NameWithOwner -eq 'wlyaaaaa/Key') {
            $risk = '严格禁止克隆；只记录远端私有备份存在，不创建本地任务。'
        }

        return [pscustomobject]@{
            Decision  = '不建议新增'
            Frequency = '无'
            Purpose   = '无本地 clone'
            Reason    = '本机没有可执行脚本或工作区，不能创建本地计划任务。'
            Risk      = $risk
        }
    }

    if ($ExistingTaskHints.Count -gt 0) {
        return [pscustomobject]@{
            Decision  = '已有任务覆盖'
            Frequency = '不新增'
            Purpose   = '已有计划任务与该仓库或路径有关'
            Reason    = "现有任务线索：$hintText"
            Risk      = '继续在 Task Scheduler 和机器配置中心复查现有任务即可。'
        }
    }

    if ($Visibility -eq 'PRIVATE') {
        return [pscustomobject]@{
            Decision  = '需人工确认'
            Frequency = '由拥有项目和机器配置中心决定'
            Purpose   = '私有仓库自动化候选'
            Reason    = '可见性允许承担备份职责，但索引不拥有任务频率、Action 或恢复策略。'
            Risk      = '确认数据规模、远端可见性和拥有项目的恢复要求。'
        }
    }

    return [pscustomobject]@{
        Decision  = '不建议新增'
        Frequency = '按需手动'
        Purpose   = '普通公开仓库'
        Reason    = '公开仓库默认不做定时提交/推送，优先保留人工审查。'
        Risk      = '自动化可能扩大误提交范围。'
    }
}

function Get-ExistingTaskHintsForRepository {
    param(
        [object] $Repository,
        [object[]] $TaskRows
    )

    $namePart = ($Repository.NameWithOwner -replace '^wlyaaaaa/', '')
    $localPath = [string] $Repository.LocalPath
    $hints = foreach ($task in $TaskRows) {
        $text = "$($task.TaskName) $($task.ActionSummary) $($task.RelatedPath)"
        if ($localPath -ne '未发现本地 clone' -and $text -like "*$localPath*") {
            $task.TaskName
            continue
        }

        if ($namePart -notin @('.agents', 'Key') -and $text -match [regex]::Escape($namePart)) {
            $task.TaskName
            continue
        }
    }

    return @($hints | Sort-Object -Unique)
}

function Get-UserAutomationTaskRows {
    $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { Test-IsUserAutomationTask -Task $_ } | Sort-Object TaskPath, TaskName)

    foreach ($task in $tasks) {
        $info = Get-ScheduledTaskInfo -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue
        $assessment = if ($info) { ConvertTo-UserAutomationTaskResultAssessment -LastTaskResult $info.LastTaskResult } else { [pscustomobject]@{ Severity = '未知'; Summary = '读取任务摘要失败'; CodeText = '' } }
        if ([string] $task.State -eq 'Disabled' -and $assessment.Severity -eq '警告') {
            $assessment = [pscustomobject]@{ Severity = '信息'; Summary = '任务已禁用，未参与自动运行'; CodeText = $assessment.CodeText }
        }

        $lastRun = if ($info -and $info.LastRunTime) { ([datetime] $info.LastRunTime).ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
        $nextRun = if ([string] $task.State -eq 'Disabled') { '' } elseif ($info -and $info.NextRunTime) { ([datetime] $info.NextRunTime).ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
        $actionSummary = Get-PublicActionSummary -Task $task
        $purpose = Get-TaskPurposeInference -TaskName ([string] $task.TaskName) -ActionSummary $actionSummary
        $relatedPath = Get-RelatedPathHint -TaskName ([string] $task.TaskName) -ActionSummary $actionSummary

        [pscustomobject]@{
            TaskName       = [string] $task.TaskName
            TaskPath       = [string] $task.TaskPath
            State          = [string] $task.State
            LastRunTime    = $lastRun
            NextRunTime    = $nextRun
            LastTaskResult = $assessment.CodeText
            Severity       = $assessment.Severity
            ActionSummary  = $actionSummary
            RelatedPath    = $relatedPath
            Purpose        = $purpose.Purpose
            Why            = $purpose.Why
            Risk           = if ($assessment.Severity -eq '正常') { $purpose.Risk } else { "$($assessment.Summary)；$($purpose.Risk)" }
        }
    }
}

function Get-RepositoryRecommendationRows {
    param(
        [string] $RepoRoot,
        [object[]] $TaskRows
    )

    $repos = @(Get-IndexedRepositoryRows -RepoRoot $RepoRoot)
    foreach ($repo in $repos) {
        $hints = @(Get-ExistingTaskHintsForRepository -Repository $repo -TaskRows $TaskRows)
        $recommendation = Get-RepositoryTaskRecommendation -NameWithOwner $repo.NameWithOwner -LocalPath $repo.LocalPath -Visibility $repo.Visibility -ExistingTaskHints $hints
        [pscustomobject]@{
            Repository        = $repo.NameWithOwner
            Visibility        = $repo.Visibility
            LocalPath         = $repo.LocalPath
            ExistingCoverage  = if ($hints.Count -gt 0) { $hints -join '；' } else { '未发现直接覆盖' }
            Decision          = $recommendation.Decision
            Frequency         = $recommendation.Frequency
            SuggestedPurpose  = $recommendation.Purpose
            Reason            = $recommendation.Reason
            Risk              = $recommendation.Risk
        }
    }
}

function Write-UserAutomationDocuments {
    param(
        [string] $RepoRoot,
        [object[]] $TaskRows,
        [object[]] $RecommendationRows
    )

    $date = [DateTime]::UtcNow.AddHours(8).ToString('yyyy-MM-dd')
    $taskLines = @(
        '# 用户自动化任务地图',
        '',
        "更新时间：$date",
        '',
        '本文件扩大到所有“像用户自己配置的自动化”的计划任务。用途、必要性和风险为公开摘要级推测；不保存完整任务 XML 或完整 Action 参数。',
        '',
        '## 判定规则',
        '',
        '- 非 Microsoft 系统任务，且不像常见软件更新器。',
        '- 任务名或动作包含备份、同步、自启、推送、看门狗、心跳、监控等语义。',
        '- Action 指向用户目录、`E:\`、`G:\`、Git 仓库、PowerShell、Python、VBS、bat/cmd 或 git。',
        '',
        '## 任务地图',
        ''
    )
    $taskLines += New-UserAutomationMarkdownTable -Headers @('任务', '状态', '上次运行', '下次运行', '返回码', '动作摘要', '关联路径', '推测用途', '为什么需要', '风险/复查点') -Properties @('TaskName', 'State', 'LastRunTime', 'NextRunTime', 'LastTaskResult', 'ActionSummary', 'RelatedPath', 'Purpose', 'Why', 'Risk') -Rows $TaskRows
    Set-UserAutomationTextFile -Path (Join-Path $RepoRoot '04_计划任务/用户自动化任务地图.md') -Lines $taskLines

    $recommendationLines = @(
        '# 仓库计划任务建议',
        '',
        "更新时间：$date",
        '',
        '本文件审阅已发现本地 clone 的 GitHub 仓库，推测是否需要新增 Windows 计划任务。结论为建议，不代表已创建任务。',
        '',
        '## 建议表',
        ''
    )
    $recommendationLines += New-UserAutomationMarkdownTable -Headers @('仓库', '可见性', '本地路径', '已有覆盖', '决策', '建议频率', '建议用途', '理由', '风险') -Properties @('Repository', 'Visibility', 'LocalPath', 'ExistingCoverage', 'Decision', 'Frequency', 'SuggestedPurpose', 'Reason', 'Risk') -Rows $RecommendationRows
    $recommendationLines += ''
    $recommendationLines += '## 当前最值得补的任务'
    $recommendationLines += ''
    $topRows = @($RecommendationRows | Where-Object { $_.Decision -eq '建议新增' })
    if ($topRows.Count -eq 0) {
        $recommendationLines += '当前没有强建议新增的计划任务。'
    } else {
        $recommendationLines += New-UserAutomationMarkdownTable -Headers @('仓库', '建议频率', '建议用途', '理由') -Properties @('Repository', 'Frequency', 'SuggestedPurpose', 'Reason') -Rows $topRows
    }
    Set-UserAutomationTextFile -Path (Join-Path $RepoRoot '04_计划任务/仓库计划任务建议.md') -Lines $recommendationLines
}

function Invoke-UpdateUserAutomationMap {
    param(
        [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot),
        [switch] $NoWrite
    )

    $taskRows = @(Get-UserAutomationTaskRows)
    $recommendationRows = @(Get-RepositoryRecommendationRows -RepoRoot $RepoRoot -TaskRows $taskRows)
    if (-not $NoWrite) {
        Write-UserAutomationDocuments -RepoRoot $RepoRoot -TaskRows $taskRows -RecommendationRows $recommendationRows
    }

    return [pscustomobject]@{
        TaskRows           = $taskRows
        RecommendationRows = $recommendationRows
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-UpdateUserAutomationMap -RepoRoot $RepoRoot -NoWrite:$NoWrite
}
