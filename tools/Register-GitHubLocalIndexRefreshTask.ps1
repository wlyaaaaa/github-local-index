param(
    [string] $TaskName = 'GitHubLocalIndex Refresh',
    [datetime] $At = ([datetime]::Today.AddHours(23).AddMinutes(10))
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $PSScriptRoot 'Refresh-GitHubLocalIndex.ps1'

if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Refresh script not found: $scriptPath"
}

$pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
if ($pwsh) {
    $execute = $pwsh.Source
    $argument = '-NoProfile -WindowStyle Hidden -File "{0}"' -f $scriptPath
}
else {
    $execute = 'powershell.exe'
    $argument = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $scriptPath
}

$action = New-ScheduledTaskAction -Execute $execute -Argument $argument -WorkingDirectory $repoRoot
$trigger = New-ScheduledTaskTrigger -Daily -At $At
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

$description = 'Refreshes local public GitHub index Markdown from local/GitHub/Task Scheduler state. Does not git commit or git push.'
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description $description -Force | Out-Null
Get-ScheduledTask -TaskName $TaskName
