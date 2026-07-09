param(
    [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string[]] $NamePatterns = @('*Backup*', '*Sync*', '*Mirror*', '*Watchdog*', '*Heartbeat*', '*AutoPush*', '*AutoStart*', '*GitHubLocalIndex*'),
    [switch] $NoWrite
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function ConvertTo-TaskResultAssessment {
    param([AllowNull()] [object] $LastTaskResult)

    if ($null -eq $LastTaskResult) {
        return [pscustomobject]@{
            Code     = ''
            HexCode  = ''
            Severity = '未知'
            Summary  = '尚无返回码'
        }
    }

    $signed = [int64] $LastTaskResult
    $unsigned = if ($signed -lt 0) { $signed + 4294967296 } else { $signed }
    $hex = '0x{0:X8}' -f $unsigned

    switch ($unsigned) {
        0 {
            return [pscustomobject]@{
                Code     = $unsigned
                HexCode  = $hex
                Severity = '正常'
                Summary  = '返回码 0'
            }
        }
        267009 {
            return [pscustomobject]@{
                Code     = $unsigned
                HexCode  = $hex
                Severity = '警告'
                Summary  = '任务仍在运行或上次状态未结束'
            }
        }
        267011 {
            return [pscustomobject]@{
                Code     = $unsigned
                HexCode  = $hex
                Severity = '警告'
                Summary  = '任务尚未运行或无有效完成记录'
            }
        }
        3221225786 {
            return [pscustomobject]@{
                Code     = $unsigned
                HexCode  = $hex
                Severity = '异常'
                Summary  = '中断退出，常见于注销、关机或任务被终止'
            }
        }
        default {
            return [pscustomobject]@{
                Code     = $unsigned
                HexCode  = $hex
                Severity = '警告'
                Summary  = '非零返回码，需要结合任务日志复查'
            }
        }
    }
}

function ConvertTo-PublicTaskRow {
    param(
        [object] $Task,
        [object] $Info
    )

    $assessment = ConvertTo-TaskResultAssessment -LastTaskResult $Info.LastTaskResult
    if ([string] $Task.State -eq 'Disabled' -and $assessment.Severity -eq '警告') {
        $assessment = [pscustomobject]@{
            Code     = $assessment.Code
            HexCode  = $assessment.HexCode
            Severity = '信息'
            Summary  = '任务已禁用，未参与自动运行'
        }
    }
    $lastRun = if ($Info.LastRunTime) { ([datetime] $Info.LastRunTime).ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
    $nextRun = if ([string] $Task.State -eq 'Disabled') { '' } elseif ($Info.NextRunTime) { ([datetime] $Info.NextRunTime).ToString('yyyy-MM-dd HH:mm:ss') } else { '' }

    return [pscustomobject]@{
        TaskName       = [string] $Task.TaskName
        TaskPath       = [string] $Task.TaskPath
        State          = [string] $Task.State
        LastRunTime    = $lastRun
        NextRunTime    = $nextRun
        LastTaskResult = if ([string]::IsNullOrWhiteSpace([string] $assessment.HexCode)) { '' } else { "$($assessment.Code) / $($assessment.HexCode)" }
        Severity       = $assessment.Severity
        Summary        = $assessment.Summary
    }
}

function Get-MonitoredScheduledTaskRows {
    param([string[]] $NamePatterns)

    $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
        if ($_.TaskPath -like '\Microsoft\Windows\*') {
            return $false
        }

        $name = $_.TaskName
        $path = $_.TaskPath
        foreach ($pattern in $NamePatterns) {
            if ($name -like $pattern -or $path -like $pattern) {
                return $true
            }
        }
        return $false
    } | Sort-Object TaskPath, TaskName)

    foreach ($task in $tasks) {
        try {
            $info = Get-ScheduledTaskInfo -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop
            ConvertTo-PublicTaskRow -Task $task -Info $info
        } catch {
            [pscustomobject]@{
                TaskName       = [string] $task.TaskName
                TaskPath       = [string] $task.TaskPath
                State          = [string] $task.State
                LastRunTime    = ''
                NextRunTime    = ''
                LastTaskResult = ''
                Severity       = '异常'
                Summary        = '读取任务摘要失败'
            }
        }
    }
}

function ConvertTo-MarkdownCell {
    param([AllowNull()] [object] $Value)

    if ($null -eq $Value) {
        return ''
    }

    return ([string] $Value) -replace '\|', '\|' -replace "(\r\n|\n|\r)", '<br>'
}

function New-MarkdownTable {
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
            ConvertTo-MarkdownCell $row.$property
        }
        $lines += '| ' + ($cells -join ' | ') + ' |'
    }

    return $lines
}

function Set-TextFile {
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

function Write-ScheduledTaskDocuments {
    param(
        [string] $RepoRoot,
        [object[]] $Rows
    )

    $date = [DateTime]::UtcNow.AddHours(8).ToString('yyyy-MM-dd')
    $normalRows = @($Rows | Where-Object { $_.Severity -eq '正常' })
    $warningRows = @($Rows | Where-Object { $_.Severity -eq '警告' })
    $errorRows = @($Rows | Where-Object { $_.Severity -eq '异常' })
    $reviewRows = @($Rows | Where-Object { $_.Severity -ne '正常' })

    $summaryLines = @(
        '# 计划任务健康摘要',
        '',
        "更新时间：$date",
        '',
        "本文件由 ``tools/Update-ScheduledTaskHealth.ps1`` 只读刷新。脚本只记录任务名、状态、运行时间和返回码摘要，不保存完整任务 XML 或完整 Action 命令。",
        '',
        '口径说明：本文件只汇总当前 Task Scheduler 的公开安全运行态，不保存任务 Action、触发器或恢复配置。机器配置、任务目的与恢复规则由机器配置中心维护。',
        '',
        '## 当前统计',
        '',
        "| 总数 | 正常 | 警告 | 异常 |",
        "|---|---|---|---|",
        "| $($Rows.Count) | $($normalRows.Count) | $($warningRows.Count) | $($errorRows.Count) |",
        '',
        '## 任务摘要',
        ''
    )
    if ($Rows.Count -gt 0) {
        $summaryLines += New-MarkdownTable -Headers @('任务', '路径', '状态', '上次运行', '下次运行', '返回码', '判断') -Properties @('TaskName', 'TaskPath', 'State', 'LastRunTime', 'NextRunTime', 'LastTaskResult', 'Summary') -Rows $Rows
    } else {
        $summaryLines += '当前匹配范围内没有计划任务。'
    }
    $summaryLines += ''
    $summaryLines += '## 诊断边界'
    $summaryLines += ''
    $summaryLines += '- 返回码 `0` 视为正常。'
    $summaryLines += '- 返回码 `0xC000013A` 视为中断退出，常见于注销、关机或任务被终止。'
    $summaryLines += '- 其他非零返回码先列为警告，后续结合 Task Scheduler Operational 日志复查。'
    Set-TextFile -Path (Join-Path $RepoRoot '04_计划任务/计划任务健康摘要.md') -Lines $summaryLines

    $anomalyLines = @(
        '# 计划任务异常清单',
        '',
        "更新时间：$date",
        '',
        '## 异常与需复查',
        ''
    )
    if ($reviewRows.Count -gt 0) {
        $anomalyLines += New-MarkdownTable -Headers @('任务', '路径', '状态', '上次运行', '返回码', '级别', '复查点') -Properties @('TaskName', 'TaskPath', 'State', 'LastRunTime', 'LastTaskResult', 'Severity', 'Summary') -Rows $reviewRows
    } else {
        $anomalyLines += '| 任务 | 异常 |'
        $anomalyLines += '|---|---|'
        $anomalyLines += '| 无 | 当前匹配范围内没有非正常返回码 |'
    }
    $anomalyLines += ''
    $anomalyLines += '下一步建议：'
    $anomalyLines += ''
    $anomalyLines += '1. 对异常任务复跑一次，确认是否仍复现。'
    $anomalyLines += '2. 如果仍为 `0xC000013A`，优先排查关机、注销、任务超时或被终止。'
    $anomalyLines += '3. 如需定位动作路径或脚本内容，只在本机私有目录复查，不把完整命令写入公开索引。'
    Set-TextFile -Path (Join-Path $RepoRoot '04_计划任务/计划任务异常清单.md') -Lines $anomalyLines
}

function Invoke-UpdateScheduledTaskHealth {
    param(
        [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot),
        [string[]] $NamePatterns = @('*Backup*', '*Sync*', '*Mirror*', '*Watchdog*', '*Heartbeat*', '*AutoPush*', '*AutoStart*', '*GitHubLocalIndex*'),
        [switch] $NoWrite
    )

    $rows = @(Get-MonitoredScheduledTaskRows -NamePatterns $NamePatterns)
    if (-not $NoWrite) {
        Write-ScheduledTaskDocuments -RepoRoot $RepoRoot -Rows $rows
    }

    return $rows
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-UpdateScheduledTaskHealth -RepoRoot $RepoRoot -NamePatterns $NamePatterns -NoWrite:$NoWrite
}
