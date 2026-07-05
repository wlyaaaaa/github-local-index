param(
    [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

$logDir = Join-Path $RepoRoot '99_private\logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logPath = Join-Path $logDir 'GitHubLocalIndexRefresh.log'

function Write-RefreshLog {
    param([string] $Message)

    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

function Add-PathIfExists {
    param([Parameter(Mandatory = $true)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $parts = @($env:Path -split ';' | Where-Object { $_ })
    if ($parts -notcontains $Path) {
        $env:Path = ($parts + $Path) -join ';'
    }
}

function Invoke-RefreshStep {
    param(
        [string] $Name,
        [scriptblock] $ScriptBlock
    )

    Write-RefreshLog "START $Name"
    try {
        & $ScriptBlock
        Write-RefreshLog "OK $Name"
    }
    catch {
        Write-RefreshLog "FAILED $Name :: $($_.Exception.Message)"
        throw
    }
}

try {
    Add-PathIfExists 'E:\Scoop\shims'
    Add-PathIfExists (Join-Path $env:USERPROFILE 'scoop\shims')
    Add-PathIfExists 'C:\Program Files\Git\cmd'

    Write-RefreshLog 'GitHub local index refresh started'

    Invoke-RefreshStep 'GitHub repository index' {
        & (Join-Path $RepoRoot 'tools\Update-GitHubIndex.ps1') -RepoRoot $RepoRoot -SkipFetch | Out-Null
    }

    Invoke-RefreshStep 'scheduled task health' {
        & (Join-Path $RepoRoot 'tools\Update-ScheduledTaskHealth.ps1') -RepoRoot $RepoRoot | Out-Null
    }

    Invoke-RefreshStep 'user automation map' {
        & (Join-Path $RepoRoot 'tools\Update-UserAutomationMap.ps1') -RepoRoot $RepoRoot | Out-Null
    }

    Write-RefreshLog 'GitHub local index refresh finished'
    exit 0
}
catch {
    Write-RefreshLog "FAILED refresh :: $($_.Exception.Message)"
    exit 1
}
