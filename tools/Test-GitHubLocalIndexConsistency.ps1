param(
    [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $Owner = 'wlyaaaaa',
    [string[]] $ScanRoots = @('C:\Users\10979', 'E:\', 'G:\'),
    [switch] $SkipFetch,
    [switch] $Strict,
    [switch] $KeepGenerated
)

$ErrorActionPreference = 'Stop'

function Get-GitHubLocalIndexGeneratedDocumentPaths {
    return @(
        '00_总览\当前同步看板.md',
        '01_仓库索引\GitHub仓库索引.md',
        '01_仓库索引\本地clone索引.md',
        '01_仓库索引\未发现本地clone.md',
        '02_同步诊断\未推送队列.md',
        '02_同步诊断\工作区脏状态.md',
        '02_同步诊断\分支与远端诊断.md',
        '04_计划任务\计划任务健康摘要.md',
        '04_计划任务\计划任务异常清单.md',
        '04_计划任务\用户自动化任务地图.md',
        '04_计划任务\仓库计划任务建议.md'
    )
}

function Get-GitHubLocalIndexStableDocumentPaths {
    return @(
        '00_总览\当前同步看板.md',
        '01_仓库索引\GitHub仓库索引.md',
        '01_仓库索引\本地clone索引.md',
        '01_仓库索引\未发现本地clone.md',
        '02_同步诊断\未推送队列.md',
        '02_同步诊断\工作区脏状态.md',
        '02_同步诊断\分支与远端诊断.md'
    )
}

function Get-ConsistencyFileHash {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-ConsistencyLineCount {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return 0
    }

    return @(Get-Content -LiteralPath $Path).Count
}

function ConvertTo-ConsistencyComparableLine {
    param(
        [string] $Line,
        [string] $RelativePath
    )

    if ($Line -notmatch '\|\s*wlyaaaaa/github-local-index\s*\|') {
        return $Line
    }

    $cells = [regex]::Split($Line, '\|')
    switch ($RelativePath) {
        '01_仓库索引\GitHub仓库索引.md' {
            if ($cells.Count -ge 8) {
                $cells[5] = ' __SELF_INDEX_STATE__ '
                $cells[6] = ' __SELF_INDEX_ACTION__ '
                return ($cells -join '|')
            }
        }
        { $_ -in @('01_仓库索引\本地clone索引.md', '02_同步诊断\分支与远端诊断.md') } {
            if ($cells.Count -ge 5) {
                $cells[3] = ' __SELF_INDEX_STATE__ '
                return ($cells -join '|')
            }
        }
    }

    return $Line
}

function Get-ConsistencyComparableHash {
    param(
        [string] $Path,
        [string] $RelativePath
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    $lines = @(Get-Content -LiteralPath $Path | ForEach-Object {
        ConvertTo-ConsistencyComparableLine -Line $_ -RelativePath $RelativePath
    })
    $text = $lines -join "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $sha.Dispose()
    }
}

function Compare-GitHubLocalIndexDocuments {
    param(
        [Parameter(Mandatory = $true)] [string] $RepoRoot,
        [Parameter(Mandatory = $true)] [string] $GeneratedRoot,
        [string[]] $RelativePaths = (Get-GitHubLocalIndexGeneratedDocumentPaths)
    )

    foreach ($relativePath in $RelativePaths) {
        $currentPath = Join-Path $RepoRoot $relativePath
        $generatedPath = Join-Path $GeneratedRoot $relativePath
        $currentExists = Test-Path -LiteralPath $currentPath
        $generatedExists = Test-Path -LiteralPath $generatedPath
        $currentHash = Get-ConsistencyComparableHash -Path $currentPath -RelativePath $relativePath
        $generatedHash = Get-ConsistencyComparableHash -Path $generatedPath -RelativePath $relativePath

        [pscustomobject]@{
            File           = $relativePath
            Same           = $currentExists -and $generatedExists -and $currentHash -eq $generatedHash
            CurrentExists  = $currentExists
            GeneratedExists = $generatedExists
            CurrentLines   = Get-ConsistencyLineCount -Path $currentPath
            GeneratedLines = Get-ConsistencyLineCount -Path $generatedPath
        }
    }
}

function New-GitHubLocalIndexConsistencyTempRoot {
    param([string] $RepoRoot)

    $privateRoot = Join-Path $RepoRoot '99_private'
    if (-not (Test-Path -LiteralPath $privateRoot)) {
        New-Item -ItemType Directory -Path $privateRoot | Out-Null
    }

    $tempParent = Join-Path $privateRoot 'consistency-checks'
    New-Item -ItemType Directory -Path $tempParent -Force | Out-Null
    return Join-Path $tempParent ('generated-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
}

function Remove-GitHubLocalIndexConsistencyTempRoot {
    param(
        [string] $RepoRoot,
        [string] $TempRoot
    )

    if ([string]::IsNullOrWhiteSpace($TempRoot) -or -not (Test-Path -LiteralPath $TempRoot)) {
        return
    }

    $privateRoot = (Resolve-Path -LiteralPath (Join-Path $RepoRoot '99_private')).Path
    $resolvedTemp = (Resolve-Path -LiteralPath $TempRoot).Path
    if (-not $resolvedTemp.StartsWith($privateRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove unexpected consistency temp path: $resolvedTemp"
    }

    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
}

function Invoke-GitHubLocalIndexConsistencyCheck {
    param(
        [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot),
        [string] $Owner = 'wlyaaaaa',
        [string[]] $ScanRoots = @('C:\Users\10979', 'E:\', 'G:\'),
        [switch] $SkipFetch,
        [switch] $Strict,
        [switch] $KeepGenerated
    )

    $generatedRoot = New-GitHubLocalIndexConsistencyTempRoot -RepoRoot $RepoRoot
    New-Item -ItemType Directory -Path $generatedRoot -Force | Out-Null

    try {
        . (Join-Path $RepoRoot 'tools\Update-GitHubIndex.ps1')
        . (Join-Path $RepoRoot 'tools\Update-ScheduledTaskHealth.ps1')
        . (Join-Path $RepoRoot 'tools\Update-UserAutomationMap.ps1')

        Invoke-UpdateGitHubIndex -Owner $Owner -RepoRoot $generatedRoot -ScanRoots $ScanRoots -SkipFetch:$SkipFetch | Out-Null
        Invoke-UpdateScheduledTaskHealth -RepoRoot $generatedRoot | Out-Null
        Invoke-UpdateUserAutomationMap -RepoRoot $generatedRoot | Out-Null

        $comparisons = @(Compare-GitHubLocalIndexDocuments -RepoRoot $RepoRoot -GeneratedRoot $generatedRoot)
        $driftRows = @($comparisons | Where-Object { -not $_.Same })
        $stablePaths = @(Get-GitHubLocalIndexStableDocumentPaths)
        $stableDriftRows = @($driftRows | Where-Object { $stablePaths -contains $_.File })
        $volatileDriftRows = @($driftRows | Where-Object { $stablePaths -notcontains $_.File })
        $isConsistent = if ($Strict) { $driftRows.Count -eq 0 } else { $stableDriftRows.Count -eq 0 }

        return [pscustomobject]@{
            IsConsistent      = $isConsistent
            Strict            = [bool] $Strict
            Compared          = $comparisons.Count
            DriftCount        = $driftRows.Count
            StableDriftCount  = $stableDriftRows.Count
            VolatileDriftCount = $volatileDriftRows.Count
            DriftFiles        = @($driftRows | ForEach-Object { $_.File })
            StableDriftFiles  = @($stableDriftRows | ForEach-Object { $_.File })
            VolatileDriftFiles = @($volatileDriftRows | ForEach-Object { $_.File })
            GeneratedRoot = $generatedRoot
            Comparisons   = $comparisons
        }
    }
    finally {
        if (-not $KeepGenerated) {
            Remove-GitHubLocalIndexConsistencyTempRoot -RepoRoot $RepoRoot -TempRoot $generatedRoot
        }
    }
}

function Write-GitHubLocalIndexConsistencyResult {
    param([object] $Result)

    "Compared documents: $($Result.Compared)"
    "Drift count: $($Result.DriftCount)"
    "Stable drift count: $($Result.StableDriftCount)"
    "Volatile drift count: $($Result.VolatileDriftCount)"
    "Strict mode: $($Result.Strict)"
    if ($Result.DriftCount -gt 0) {
        'Drift files:'
        $Result.Comparisons |
            Where-Object { -not $_.Same } |
            Select-Object File, CurrentExists, GeneratedExists, CurrentLines, GeneratedLines |
            Format-Table -AutoSize
        if (Test-Path -LiteralPath $Result.GeneratedRoot) {
            "Generated root: $($Result.GeneratedRoot)"
        }
        else {
            'Generated root was cleaned up. Re-run with -KeepGenerated to retain files for manual diff.'
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $result = Invoke-GitHubLocalIndexConsistencyCheck -RepoRoot $RepoRoot -Owner $Owner -ScanRoots $ScanRoots -SkipFetch:$SkipFetch -Strict:$Strict -KeepGenerated:$KeepGenerated
        Write-GitHubLocalIndexConsistencyResult -Result $result
        if ($result.IsConsistent) {
            exit 0
        }

        exit 1
    }
    catch {
        Write-Error $_.Exception.Message
        exit 2
    }
}
