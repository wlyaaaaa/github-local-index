param(
    [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [switch] $NoWrite
)

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

    $knownUserPattern = 'AIModelsBackup|AutoDigitalBackupToH|CleanupOrphanedMillennium|Codex Memory|DevConfigBackup|Gemini Memory|LibreHardwareMonitor|OllamaStable|OpenClaw|PinDefaultAudio|RAMDisk_Code_Backup|Scripts_AutoPush|TimeAudit|TURZX|WeChat AutoStart|WeChatBackup|WeFlow'
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

    $keywordPattern = 'Backup|AutoPush|Watchdog|Heartbeat|Memory|OpenClaw|WeFlow|TimeAudit|DevConfig|WeChat|Scripts|Ramdisk|RAMDisk|Sunshine|Audio|Guardian|Sync|Mirror|GitHub|Codex|Gemini|Claude|AIModels|CleanupOrphanedMillennium|自动|备份|同步|推送|看门狗|心跳|监控|自启'
    if ($combined -match $keywordPattern) {
        return $true
    }

    $pathPattern = '(^|["\s])(E:\\|G:\\|C:\\Users\\10979\\ProxyTools\\|C:\\Users\\10979\\AppData\\Roaming\\npm\\node_modules\\openclaw\\|powershell|pwsh|python|wscript|cscript|cmd\.exe|git\.exe)'
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

    $combined = "$TaskName $ActionSummary"
    if ($combined -match 'Gemini Memory') { return 'E:\GeminiMemoryBackup' }
    if ($combined -match 'OpenClaw') { return 'E:\OpenClawGateway' }
    if ($combined -match 'WeFlow') { return 'E:\WeFlowBridge' }
    if ($combined -match 'TimeAudit|LibreHardwareMonitor') { return 'E:\TimeAudit' }
    if ($combined -match 'TURZX') { return 'E:\TURZX-SideScreen' }
    if ($combined -match 'Millennium') { return 'E:\steam-millennium-config-backup' }

    $knownRoots = @(
        'E:\CodexMemoryBackup',
        'E:\GeminiMemoryBackup',
        'E:\ClaudeMemoryBackup',
        'E:\OpenClawGateway',
        'E:\OpenClawBackup',
        'E:\WeFlowBridge',
        'E:\TimeAudit',
        'E:\DevConfigBackup',
        'E:\Scripts',
        'E:\RamdiskGuardian',
        'E:\SunshineRemote',
        'G:\AI大模型',
        'C:\Users\10979\ProxyTools'
    )

    foreach ($root in $knownRoots) {
        if ($combined -like "*$root*") {
            return $root
        }
    }

    $path = Get-SanitizedPathFromText -Text $combined
    if ($path) {
        $parts = $path -split '\\'
        if ($parts.Count -ge 2) {
            return ($parts[0..1] -join '\')
        }
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

    if ($combined -match 'CleanupOrphanedMillennium|Millennium') {
        return [pscustomobject]@{
            Purpose = '配置/组件清理维护'
            Why     = '清理孤立组件或过期配置，减少本地环境漂移和残留文件。'
            Risk    = '高频清理任务需确认不会误删仍在使用的配置。'
        }
    }

    if ($combined -match 'Backup|Memory|备份|Codex|Claude|Gemini|DevConfig|WeChatBackup|AIModels') {
        return [pscustomobject]@{
            Purpose = '备份/恢复材料同步'
            Why     = '保留配置、记忆、知识库或个人数据的恢复点，支持换机和回滚。'
            Risk    = '私有备份仓库可保留敏感恢复材料；公开索引不得复制具体内容。'
        }
    }

    if ($combined -match 'AutoStart|Gateway|OpenClaw|WeFlow|TimeAudit|TURZX|Ollama|自启') {
        return [pscustomobject]@{
            Purpose = '本地服务自启/运行保障'
            Why     = '登录或开机后自动恢复常驻服务，降低手工启动成本。'
            Risk    = '需要确认禁用任务是否仍有保留价值。'
        }
    }

    if ($combined -match 'Audio|Speaker') {
        return [pscustomobject]@{
            Purpose = '桌面环境偏好修复'
            Why     = '自动恢复音频等本机偏好，减少重启或设备切换后的手工修复。'
            Risk    = '非零返回码通常说明脚本路径或设备名需要复查。'
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

    $name = $NameWithOwner
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
        $risk = '继续复查现有任务返回码即可'
        if ($name -eq 'wlyaaaaa/github-local-index') {
            $risk = '只读刷新已覆盖；提交推送仍保留人工/Codex 审查。'
        }
        elseif ($name -eq 'wlyaaaaa/steam-millennium-config-backup') {
            $risk = '继续保持 allowlist 快照和公开敏感扫描，避免 Steam 账号、缓存或日志入库。'
        }
        elseif ($name -match 'rtx5090d-ollama-agent-bundle') {
            $risk = '健康检查只允许无监听时启动；不得强杀 Ollama 或打断长推理。'
        }
        elseif ($name -eq 'wlyaaaaa/sunshine-remote-streaming') {
            $risk = '当前非提升权限无法创建登录触发，已降级为每日轻量验证；修复脚本仍需人工触发。'
        }

        return [pscustomobject]@{
            Decision  = '已有任务覆盖'
            Frequency = '不新增'
            Purpose   = '已有计划任务与该仓库或路径有关'
            Reason    = "现有任务线索：$hintText"
            Risk      = $risk
        }
    }

    if ($name -eq 'wlyaaaaa/github-local-index') {
        return [pscustomobject]@{
            Decision  = '建议新增'
            Frequency = '每日或每周只读刷新'
            Purpose   = '定期刷新 GitHub 总索引和计划任务摘要'
            Reason    = '本仓库已经具备刷新脚本，但当前没有稳定计划任务覆盖。'
            Risk      = '只应自动生成公开摘要；提交推送仍建议保留审查。'
        }
    }

    if ($name -eq 'wlyaaaaa/.agents') {
        return [pscustomobject]@{
            Decision  = '不建议新增'
            Frequency = '按需手动'
            Purpose   = '个人规则和能力源码维护'
            Reason    = '这是长期源码和规则库，改动应由 Codex 工作流显式提交同步，不适合后台自动推送。'
            Risk      = '定时推送可能误公开个人规则、路径或运维细节。'
        }
    }

    if ($name -eq 'wlyaaaaa/ai-coach') {
        return [pscustomobject]@{
            Decision  = '不建议新增'
            Frequency = '按需手动'
            Purpose   = '学习记录/复盘/审计仓库'
            Reason    = '该仓库保存学习状态、checkpoint 和面试教练材料，应该由学习会话显式更新，不适合后台定时改动。'
            Risk      = '自动任务可能把未确认进度、草稿回答或临时 checkpoint 当成正式学习记录。'
        }
    }

    if ($name -eq 'wlyaaaaa/steam-millennium-config-backup') {
        return [pscustomobject]@{
            Decision  = '建议新增'
            Frequency = '每周一次或登录后低频快照'
            Purpose   = 'Steam Millennium 配置快照'
            Reason    = '当前像一次性快照仓库，缺少持续更新入口；低频 allowlist 快照能保持配置恢复点。'
            Risk      = '必须严格 allowlist，避免 Steam 账号、缓存、本机标识或运行日志进入公开仓库。'
        }
    }

    if ($name -match 'rtx5090d-ollama-agent-bundle') {
        return [pscustomobject]@{
            Decision  = '需人工确认'
            Frequency = '如需 24/7 本地模型，每 15 分钟健康检查'
            Purpose   = 'Ollama 32100 服务自愈'
            Reason    = '已有启动任务偏登录/开机启动，未必覆盖服务崩溃后的自愈。'
            Risk      = '健康检查误判可能打断长推理；需确认 GPU/VRAM 占用和端口边界。'
        }
    }

    if ($name -eq 'wlyaaaaa/sunshine-remote-streaming') {
        return [pscustomobject]@{
            Decision  = '需人工确认'
            Frequency = '登录后延迟 1-2 分钟轻量验证'
            Purpose   = '远程串流服务修复/验证'
            Reason    = '如果远程串流是刚需，登录后自愈能降低 Sunshine/Tailscale 配置漂移影响。'
            Risk      = '修复脚本可能重启服务并短暂断流；日志不能记录敏感网络配置。'
        }
    }

    if ($name -match 'codex-memory|gemini-memory|claude-memory|openclaw-backup|devconfig-backup') {
        return [pscustomobject]@{
            Decision  = '建议新增'
            Frequency = '每日或登录后'
            Purpose   = '私有备份/恢复材料同步'
            Reason    = '私有备份类仓库适合定期保留恢复点，若当前无任务覆盖则存在遗漏。'
            Risk      = '确认远端仍为 PRIVATE；不要把敏感内容同步到公开仓库。'
        }
    }

    if ($name -match 'WeFlowBridge|OpenClawGateway|TimeAudit') {
        return [pscustomobject]@{
            Decision  = '需人工确认'
            Frequency = '看门狗 5-15 分钟或登录自启'
            Purpose   = '本地服务守护'
            Reason    = '服务/桥接/监控类仓库通常需要自启或心跳任务，但需确认是否已有外部方式覆盖。'
            Risk      = '避免重复启动多个实例。'
        }
    }

    if ($name -match 'Scripts') {
        return [pscustomobject]@{
            Decision  = '需人工确认'
            Frequency = '每日或变更后'
            Purpose   = '脚本仓库同步'
            Reason    = '脚本仓库可能有 AutoPush 需求，但公开推送前仍需确认没有临时脚本或敏感片段。'
            Risk      = '公开仓库自动推送风险较高。'
        }
    }

    if ($name -match 'md-triple|video|LocalOCR|TURZX|ProxyClean|vault-tool|RamdiskGuardian') {
        return [pscustomobject]@{
            Decision  = '不建议新增'
            Frequency = '按需手动'
            Purpose   = '项目型或内容型仓库'
            Reason    = '这类仓库更适合手工生成、审查和提交，避免把原始日志、截图或临时产物自动发布。'
            Risk      = '如需自动化，应只生成摘要，不直接自动推送公开产物。'
        }
    }

    if ($Visibility -eq 'PRIVATE') {
        return [pscustomobject]@{
            Decision  = '需人工确认'
            Frequency = '每日或每周'
            Purpose   = '私有仓库备份'
            Reason    = '私有仓库可承担备份职责，但需要确认数据规模和同步成本。'
            Risk      = '大文件仓库不宜高频同步。'
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
    if ($namePart -eq 'ProxyClean') {
        return @()
    }

    $localPath = [string] $Repository.LocalPath
    $hints = foreach ($task in $TaskRows) {
        $text = "$($task.TaskName) $($task.ActionSummary) $($task.RelatedPath)"
        if ($localPath -ne '未发现本地 clone' -and $text -like "*$localPath*") {
            $task.TaskName
            continue
        }

        if ($namePart -notin @('.agents', 'Key', 'EGO', 'Scripts') -and $text -match [regex]::Escape($namePart)) {
            $task.TaskName
            continue
        }

        if ($namePart -eq 'codex-memory' -and $text -match 'Codex Memory') { $task.TaskName; continue }
        if ($namePart -eq 'gemini-memory' -and $text -match 'Gemini Memory') { $task.TaskName; continue }
        if ($namePart -eq 'claude-memory' -and $text -match 'Claude Memory|OpenClaw Memory') { $task.TaskName; continue }
        if ($namePart -eq 'ai-llm-job-prep' -and $text -match 'AIModels|AI大模型') { $task.TaskName; continue }
        if ($namePart -eq 'OpenClawGateway' -and $text -match 'OpenClaw') { $task.TaskName; continue }
        if ($namePart -eq 'openclaw-backup' -and $text -match 'OpenClaw Memory|OpenClawBackup') { $task.TaskName; continue }
        if ($namePart -eq 'WeFlowBridge' -and $text -match 'WeFlow|WeChat AutoStart') { $task.TaskName; continue }
        if ($namePart -eq 'TimeAudit' -and $text -match 'TimeAudit') { $task.TaskName; continue }
        if ($namePart -eq 'Scripts' -and $text -match 'Scripts_AutoPush') { $task.TaskName; continue }
        if ($namePart -eq 'RamdiskGuardian' -and $text -match 'RAMDisk|Ramdisk') { $task.TaskName; continue }
        if ($namePart -eq 'devconfig-backup' -and $text -match 'DevConfig') { $task.TaskName; continue }
        if ($namePart -eq 'rtx5090d-ollama-agent-bundle' -and $text -match 'OllamaStable') { $task.TaskName; continue }
        if ($namePart -eq 'steam-millennium-config-backup' -and $text -match 'CleanupOrphanedMillennium') { $task.TaskName; continue }
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

    $date = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
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
