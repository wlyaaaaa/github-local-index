#requires -Version 7.0

[CmdletBinding()]
param(
    [string] $TaskName = 'GitHubLocalIndex Consistency Check',
    [datetime] $At = ([datetime]::Today.AddHours(23).AddMinutes(10)),
    [switch] $CheckOnly,
    [switch] $Apply,
    [switch] $Json
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$wrapperPath = Join-Path $PSScriptRoot 'Refresh-GitHubLocalIndex-Hidden.vbs'

function Get-GitHubLocalIndexTaskDefinition {
    if (-not (Test-Path -LiteralPath $wrapperPath -PathType Leaf)) {
        throw 'Hidden consistency launcher was not found.'
    }
    [pscustomobject][ordered]@{
        task_name = $TaskName
        schedule = [pscustomobject]@{ frequency = 'daily'; at = $At.ToString('HH:mm:ss') }
        action = [pscustomobject]@{
            execute = (Join-Path $env:WINDIR 'System32\wscript.exe')
            arguments = '"{0}" CheckOnly' -f $wrapperPath
            working_directory = $repoRoot
        }
        description = 'Runs a read-only GitHub local index consistency check. It does not refresh Markdown, commit, or push.'
        mutation = 'none'
    }
}

if ($CheckOnly -and $Apply) {
    throw 'Use either -CheckOnly or -Apply, not both.'
}
if (-not $CheckOnly -and -not $Apply) {
    throw 'Use -CheckOnly for a dry-run or -Apply for an explicitly authorized live registration.'
}

$definition = Get-GitHubLocalIndexTaskDefinition
if ($CheckOnly) {
    if ($Json) { $definition | ConvertTo-Json -Depth 6 } else { $definition }
    exit 0
}

$action = New-ScheduledTaskAction `
    -Execute $definition.action.execute `
    -Argument $definition.action.arguments `
    -WorkingDirectory $definition.action.working_directory
$trigger = New-ScheduledTaskTrigger -Daily -At $At
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description $definition.description -Force | Out-Null
Get-ScheduledTask -TaskName $TaskName
