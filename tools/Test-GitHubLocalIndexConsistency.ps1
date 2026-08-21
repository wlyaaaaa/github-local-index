param(
    [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $Owner = 'wlyaaaaa',
    [string[]] $ScanRoots = @(),
    [switch] $SkipFetch,
    [switch] $Strict,
    [switch] $KeepGenerated,
    [string] $ReceiptPath
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

function Get-GitHubLocalIndexGeneratedDocumentPaths {
    return @(
        '00_总览\GitHub总览.md',
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

function Get-ConsistencyExpectedProjectionMap {
    $map = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($relativePath in @(Get-GitHubLocalIndexGeneratedDocumentPaths)) {
        $normalized = $relativePath.Replace('\', '/')
        $map['documents/' + $normalized] = $normalized
    }
    return $map
}

function Get-GitHubLocalIndexStableDocumentPaths {
    return @(
        '00_总览\GitHub总览.md',
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

function Resolve-ConsistencyContainedPath {
    param(
        [Parameter(Mandatory = $true)] [string] $BasePath,
        [Parameter(Mandatory = $true)] [string] $RelativePath,
        [Parameter(Mandatory = $true)] [string] $Label
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "$Label must be a relative path under its owner root."
    }
    $resolvedBase = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\', '/')
    $resolvedPath = [System.IO.Path]::GetFullPath((Join-Path $resolvedBase $RelativePath)).TrimEnd('\', '/')
    $prefix = $resolvedBase + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escapes its owner root: $RelativePath"
    }
    return $resolvedPath
}

function Assert-ConsistencyExactPropertyNames {
    param(
        [Parameter(Mandatory = $true)] [object] $Object,
        [Parameter(Mandatory = $true)] [string[]] $Expected,
        [Parameter(Mandatory = $true)] [string] $Label
    )

    $actual = @($Object.PSObject.Properties.Name)
    if ($actual.Count -ne $Expected.Count -or
        (@($actual | Where-Object { $Expected -cnotcontains $_ }).Count -gt 0) -or
        (@($Expected | Where-Object { $actual -cnotcontains $_ }).Count -gt 0)) {
        throw "$Label has unexpected or missing fields."
    }
}

function Assert-ConsistencyNotReparsePoint {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $Label
    )

    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label cannot be a reparse point: $Path"
        }
    }
}

function Assert-ConsistencyPathChainNotReparsePoint {
    param(
        [Parameter(Mandatory = $true)] [string] $BasePath,
        [Parameter(Mandatory = $true)] [string] $TargetPath,
        [Parameter(Mandatory = $true)] [string] $Label
    )

    $resolvedBase = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\', '/')
    $resolvedTarget = [System.IO.Path]::GetFullPath($TargetPath).TrimEnd('\', '/')
    $prefix = $resolvedBase + [System.IO.Path]::DirectorySeparatorChar
    if ($resolvedTarget -ne $resolvedBase -and -not $resolvedTarget.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label is outside its checked path chain: $TargetPath"
    }
    Assert-ConsistencyNotReparsePoint -Path $resolvedBase -Label $Label
    if ($resolvedTarget -eq $resolvedBase) {
        return
    }
    $current = $resolvedBase
    foreach ($segment in ($resolvedTarget.Substring($prefix.Length) -split '[\\/]')) {
        if ([string]::IsNullOrWhiteSpace($segment)) {
            continue
        }
        $current = Join-Path $current $segment
        if (Test-Path -LiteralPath $current) {
            Assert-ConsistencyNotReparsePoint -Path $current -Label $Label
        }
    }
}

function Assert-ConsistencyGenerationTreeClosed {
    param(
        [Parameter(Mandatory = $true)] [string] $GenerationRoot,
        [Parameter(Mandatory = $true)] [string[]] $DocumentRelativePaths
    )

    $resolvedRoot = [System.IO.Path]::GetFullPath($GenerationRoot).TrimEnd('\', '/')
    Assert-ConsistencyPathChainNotReparsePoint -BasePath $resolvedRoot -TargetPath $resolvedRoot -Label 'generation tree root'
    $prefix = $resolvedRoot + [System.IO.Path]::DirectorySeparatorChar
    $allowedFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $allowedDirectories = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $allowedDirectories.Add($resolvedRoot) | Out-Null
    $allowedFiles.Add((Join-Path $resolvedRoot 'manifest.json')) | Out-Null
    foreach ($relativePath in @($DocumentRelativePaths)) {
        $filePath = Resolve-ConsistencyContainedPath -BasePath $resolvedRoot -RelativePath ([string] $relativePath).Replace('/', '\') -Label 'generation tree document path'
        $allowedFiles.Add($filePath) | Out-Null
        $parent = Split-Path -Parent $filePath
        while (-not [string]::IsNullOrWhiteSpace($parent) -and $parent -ne $resolvedRoot) {
            if (-not $parent.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Generation tree parent escapes its root: $relativePath"
            }
            $allowedDirectories.Add($parent) | Out-Null
            $parent = Split-Path -Parent $parent
        }
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $resolvedRoot -Recurse -Force -ErrorAction Stop)) {
        $resolved = [System.IO.Path]::GetFullPath($item.FullName).TrimEnd('\', '/')
        if (-not $resolved.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Generation tree item escapes its root: $($item.FullName)"
        }
        Assert-ConsistencyNotReparsePoint -Path $resolved -Label 'generation tree item'
        if ($item.PSIsContainer) {
            if (-not $allowedDirectories.Contains($resolved)) {
                throw "Unexpected directory in immutable generation: $resolved"
            }
        }
        elseif (-not $allowedFiles.Contains($resolved)) {
            throw "Unexpected file in immutable generation: $resolved"
        }
    }
    return $true
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

    # The index repository reports its own dirty-file count in several
    # generated documents. That count necessarily changes while a refresh is
    # writing those documents, so it is a volatile self-reference rather than
    # meaningful document drift.
    $Line = $Line -replace '脏工作区 \d+ 项', '脏工作区 __SELF_INDEX_DIRTY__ 项'

    $cells = [regex]::Split($Line, '\|')
    switch ($RelativePath) {
        '01_仓库索引\GitHub仓库索引.md' {
            if ($cells.Count -ge 8) {
                $state = $cells[5].Trim()
                $action = $cells[6].Trim()
                $knownState = $state -eq '本次刷新目标仓库；提交推送后复查' -or $state -match '^`[^`]+` 已同步，`0/0`(?:（(?:cached|live)）)?$'
                $knownAction = $action -in @('提交并推送本索引刷新结果', '正常维护')
                if ($knownState -and $knownAction) {
                    $cells[5] = ' __SELF_INDEX_STATE__ '
                    $cells[6] = ' __SELF_INDEX_ACTION__ '
                    return ($cells -join '|')
                }
            }
        }
        { $_ -in @('01_仓库索引\本地clone索引.md', '02_同步诊断\分支与远端诊断.md') } {
            if ($cells.Count -ge 5) {
                $state = $cells[3].Trim()
                if ($state -eq '本次刷新目标仓库；提交推送后复查' -or $state -match '^`[^`]+` 已同步，`0/0`(?:（(?:cached|live)）)?$') {
                    $cells[3] = ' __SELF_INDEX_STATE__ '
                    return ($cells -join '|')
                }
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

    return Join-Path ([System.IO.Path]::GetTempPath()) ('github-local-index-consistency-' + [guid]::NewGuid().ToString('N'))
}

function Remove-GitHubLocalIndexConsistencyTempRoot {
    param(
        [string] $RepoRoot,
        [string] $TempRoot
    )

    if ([string]::IsNullOrWhiteSpace($TempRoot) -or -not (Test-Path -LiteralPath $TempRoot)) {
        return
    }

    $systemTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $resolvedTemp = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $TempRoot).Path)
    $leaf = Split-Path -Leaf $resolvedTemp
    if (-not $resolvedTemp.StartsWith($systemTempRoot, [System.StringComparison]::OrdinalIgnoreCase) -or $leaf -notlike 'github-local-index-consistency-*') {
        throw "Refusing to remove unexpected consistency temp path: $resolvedTemp"
    }

    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
}

function Get-GitHubLocalIndexCurrentGenerationState {
    param([Parameter(Mandatory = $true)] [string] $RepoRoot)

    $manifestPath = Join-Path $RepoRoot '00_总览/current-generation.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return [pscustomobject]@{ present = $false; valid = $null; projection_valid = $null; generation_id = $null; observed_at = $null; reason = 'manifest_missing' }
    }
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json -DateKind String -ErrorAction Stop
        Assert-ConsistencyExactPropertyNames -Object $manifest -Expected @(
            'schema', 'generation_id', 'observed_at', 'authoritative',
            'integrity_authoritative_for_generation', 'decision_authority',
            'as_of_observed_at', 'owner', 'generation_root',
            'generation_manifest_sha256', 'projection_role', 'documents',
            'retention_policy', 'previous_generation_id', 'publication'
        ) -Label 'current generation pointer'
        if ([string] $manifest.schema -ne 'github-local-index.current-generation.v1' -or
            [string]::IsNullOrWhiteSpace([string] $manifest.generation_id) -or
            [bool] $manifest.authoritative -or
            -not [bool] $manifest.integrity_authoritative_for_generation -or
            [bool] $manifest.decision_authority -or
            [string]::IsNullOrWhiteSpace([string] $manifest.generation_manifest_sha256) -or
            @($manifest.documents).Count -eq 0) {
            return [pscustomobject]@{ present = $true; valid = $false; projection_valid = $false; generation_id = $null; observed_at = $null; reason = 'manifest_shape_invalid' }
        }
        Assert-ConsistencyNotReparsePoint -Path $manifestPath -Label 'current generation pointer'
        $generationBase = Join-Path $RepoRoot '00_总览/generations'
        Assert-ConsistencyPathChainNotReparsePoint -BasePath $RepoRoot -TargetPath $generationBase -Label 'generations root'
        Assert-ConsistencyNotReparsePoint -Path $generationBase -Label 'generations root'
        $generationRoot = Resolve-ConsistencyContainedPath `
            -BasePath $RepoRoot `
            -RelativePath ([string] $manifest.generation_root).Replace('/', '\') `
            -Label 'current pointer generation_root'
        $expectedGenerationRoot = [System.IO.Path]::GetFullPath((Join-Path $generationBase ([string] $manifest.generation_id))).TrimEnd('\', '/')
        if ($generationRoot -ne $expectedGenerationRoot) {
            throw 'current pointer generation_root must be exactly 00_总览/generations/<generation_id>'
        }
        Assert-ConsistencyPathChainNotReparsePoint -BasePath $RepoRoot -TargetPath $generationRoot -Label 'immutable generation root'
        Assert-ConsistencyNotReparsePoint -Path $generationRoot -Label 'immutable generation root'
        $generationManifestPath = Join-Path $generationRoot 'manifest.json'
        if (-not (Test-Path -LiteralPath $generationManifestPath -PathType Leaf)) {
            throw 'immutable generation manifest is missing'
        }
        Assert-ConsistencyNotReparsePoint -Path $generationManifestPath -Label 'immutable generation manifest'
        $generationManifestHash = (Get-FileHash -LiteralPath $generationManifestPath -Algorithm SHA256).Hash
        if ($generationManifestHash -ne [string] $manifest.generation_manifest_sha256) {
            throw 'current pointer generation manifest hash mismatch'
        }
        $generation = Get-Content -LiteralPath $generationManifestPath -Raw -Encoding utf8 | ConvertFrom-Json -DateKind String -ErrorAction Stop
        Assert-ConsistencyExactPropertyNames -Object $generation -Expected @(
            'schema', 'generation_id', 'observed_at', 'immutable',
            'integrity_authoritative_for_generation', 'decision_authority',
            'as_of_observed_at', 'owner', 'source', 'documents'
        ) -Label 'immutable generation manifest'
        if ([string] $generation.schema -ne 'github-local-index.generation.v1' -or
            [string] $generation.generation_id -ne [string] $manifest.generation_id -or
            -not [bool] $generation.immutable -or
            -not [bool] $generation.integrity_authoritative_for_generation -or
            [bool] $generation.decision_authority) {
            throw 'immutable generation manifest authority contract is invalid'
        }
        $expectedDocuments = @(Get-GitHubLocalIndexGeneratedDocumentPaths | ForEach-Object { 'documents/' + $_.Replace('\', '/') })
        $actualDocuments = @($generation.documents | ForEach-Object { ([string] $_.path).Replace('\', '/') })
        if ($actualDocuments.Count -ne $expectedDocuments.Count -or
            (@($actualDocuments | Sort-Object -Unique).Count -ne $actualDocuments.Count) -or
            (@($actualDocuments | Where-Object { $expectedDocuments -cnotcontains $_ }).Count -gt 0) -or
            (@($expectedDocuments | Where-Object { $actualDocuments -cnotcontains $_ }).Count -gt 0)) {
            throw 'immutable generation documents must exactly match the generated document set'
        }
        $expectedProjectionMap = Get-ConsistencyExpectedProjectionMap
        Assert-ConsistencyGenerationTreeClosed -GenerationRoot $generationRoot -DocumentRelativePaths $actualDocuments | Out-Null
        $projectionValid = $true
        $pointerByPath = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
        foreach ($document in @($manifest.documents)) {
            Assert-ConsistencyExactPropertyNames -Object $document -Expected @('path', 'projection_path', 'sha256', 'bytes') -Label 'current pointer document'
            $pointerByPath[[string] $document.path] = $document
        }
        if ($pointerByPath.Count -ne @($manifest.documents).Count) {
            throw 'current pointer documents contain duplicate paths'
        }
        foreach ($document in @($generation.documents)) {
            Assert-ConsistencyExactPropertyNames -Object $document -Expected @('path', 'projection_path', 'sha256', 'bytes') -Label 'generation manifest document'
            if ([string]::IsNullOrWhiteSpace([string] $document.path) -or
                [string]::IsNullOrWhiteSpace([string] $document.projection_path) -or
                [string] $document.sha256 -notmatch '^[0-9A-Fa-f]{64}$' -or
                [string]::IsNullOrWhiteSpace([string] $document.bytes)) {
                throw 'immutable generation document record is malformed'
            }
            $normalizedDocumentPath = ([string] $document.path).Replace('\', '/')
            $normalizedProjectionPath = ([string] $document.projection_path).Replace('\', '/')
            if (-not $expectedProjectionMap.ContainsKey($normalizedDocumentPath) -or
                $normalizedProjectionPath -cne $expectedProjectionMap[$normalizedDocumentPath]) {
                throw "immutable generation projection mapping is invalid: $normalizedDocumentPath"
            }
            try { $recordBytes = [int64] $document.bytes } catch { throw 'immutable generation document bytes are malformed' }
            if ($recordBytes -lt 0) {
                throw 'immutable generation document bytes are negative'
            }
            $relativePath = ([string] $document.path).Replace('/', '\')
            $path = Resolve-ConsistencyContainedPath -BasePath $generationRoot -RelativePath $relativePath -Label 'generation document path'
            Assert-ConsistencyPathChainNotReparsePoint -BasePath $generationRoot -TargetPath $path -Label 'generation document path'
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "generation document is missing: $relativePath"
            }
            Assert-ConsistencyNotReparsePoint -Path $path -Label 'generation document'
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne [string] $document.sha256) {
                throw "generation document hash mismatch: $relativePath"
            }
            if ([int64] ([System.IO.File]::ReadAllBytes($path).Length) -ne $recordBytes) {
                throw "generation document byte count mismatch: $relativePath"
            }
            $text = Get-Content -LiteralPath $path -Raw -Encoding utf8
            if ($text -notmatch "(?m)^<!-- generation_id=$([regex]::Escape([string] $manifest.generation_id)) -->\r?$") {
                throw "generation document provenance mismatch: $relativePath"
            }
            $pointerDocument = $pointerByPath[[string] $document.path]
            if ($null -eq $pointerDocument -or
                [string] $pointerDocument.sha256 -ne [string] $document.sha256 -or
                ([string] $pointerDocument.projection_path).Replace('/', '\') -ne ([string] $document.projection_path).Replace('/', '\') -or
                [int64] $pointerDocument.bytes -ne $recordBytes) {
                throw "current pointer document is missing or hash-inconsistent: $relativePath"
            }
            $projectionRelativePath = ([string] $document.projection_path).Replace('/', '\')
            $projectionPath = Resolve-ConsistencyContainedPath -BasePath $RepoRoot -RelativePath $projectionRelativePath -Label 'compatibility projection path'
            Assert-ConsistencyPathChainNotReparsePoint -BasePath $RepoRoot -TargetPath $projectionPath -Label 'compatibility projection path'
            if (-not (Test-Path -LiteralPath $projectionPath -PathType Leaf)) {
                $projectionValid = $false
            }
            else {
                Assert-ConsistencyNotReparsePoint -Path $projectionPath -Label 'compatibility projection'
                if ((Get-FileHash -LiteralPath $projectionPath -Algorithm SHA256).Hash -ne [string] $document.sha256) {
                    $projectionValid = $false
                }
                else {
                    $projectionText = Get-Content -LiteralPath $projectionPath -Raw -Encoding utf8
                    if ($projectionText -notmatch "(?m)^<!-- generation_id=$([regex]::Escape([string] $manifest.generation_id)) -->\r?$") {
                        $projectionValid = $false
                    }
                }
            }
        }
        if ($pointerByPath.Count -ne $actualDocuments.Count) {
            throw 'current pointer documents contain extra or missing entries'
        }
        return [pscustomobject]@{
            present = $true
            valid = $true
            projection_valid = $projectionValid
            generation_id = [string] $manifest.generation_id
            observed_at = [string] $manifest.observed_at
            reason = if ($projectionValid) { $null } else { 'compatibility_projection_stale' }
        }
    }
    catch {
        return [pscustomobject]@{ present = $true; valid = $false; projection_valid = $false; generation_id = $null; observed_at = $null; reason = 'manifest_invalid:' + $_.Exception.Message }
    }
}

function Resolve-GitHubLocalIndexConsistencyReceiptPath {
    param(
        [Parameter(Mandatory = $true)] [string] $RepoRoot,
        [Parameter(Mandatory = $true)] [string] $ReceiptPath
    )

    $resolvedRepoRoot = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    $privateRoot = [System.IO.Path]::GetFullPath((Join-Path $resolvedRepoRoot '99_private')).TrimEnd('\', '/')
    $resolvedReceipt = [System.IO.Path]::GetFullPath($ReceiptPath)
    $privatePrefix = $privateRoot + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedReceipt.StartsWith($privatePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Consistency receipt must remain under the ignored 99_private directory.'
    }
    if ([System.IO.Path]::GetExtension($resolvedReceipt) -ine '.json') {
        throw 'Consistency receipt must use a .json filename.'
    }
    return $resolvedReceipt
}

function Write-GitHubLocalIndexConsistencyReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $RepoRoot,
        [Parameter(Mandatory = $true)] [string] $ReceiptPath,
        [Parameter(Mandatory = $true)] [object] $Receipt
    )

    $resolvedReceipt = Resolve-GitHubLocalIndexConsistencyReceiptPath -RepoRoot $RepoRoot -ReceiptPath $ReceiptPath
    $receiptDirectory = Split-Path -Parent $resolvedReceipt
    if (-not (Test-Path -LiteralPath $receiptDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $receiptDirectory -Force | Out-Null
    }

    $tempPath = Join-Path $receiptDirectory ('.' + (Split-Path -Leaf $resolvedReceipt) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = $Receipt | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($tempPath, $json + "`n", [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($tempPath, $resolvedReceipt, $true)
    }
    finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
}

function New-GitHubLocalIndexConsistencyReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [ValidateSet('success', 'drift', 'error')] [string] $Outcome,
        [Parameter(Mandatory = $true)] [ValidateSet(0, 1, 2)] [int] $ExitCode,
        [object] $Result,
        [string] $ErrorCategory,
        [string] $ErrorMessage
    )

    [pscustomobject][ordered]@{
        schema = 'github-local-index.consistency-receipt.v1'
        task_key = 'github_local_index_consistency'
        observed_at = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        outcome = $Outcome
        exit_code = $ExitCode
        strict = if ($Result) { [bool] $Result.Strict } else { $null }
        compared = if ($Result) { [int] $Result.Compared } else { $null }
        drift_count = if ($Result) { [int] $Result.DriftCount } else { $null }
        stable_drift_count = if ($Result) { [int] $Result.StableDriftCount } else { $null }
        volatile_drift_count = if ($Result) { [int] $Result.VolatileDriftCount } else { $null }
        drift_files = if ($Result) { @($Result.DriftFiles) } else { @() }
        stable_drift_files = if ($Result) { @($Result.StableDriftFiles) } else { @() }
        volatile_drift_files = if ($Result) { @($Result.VolatileDriftFiles) } else { @() }
        error_category = if ([string]::IsNullOrWhiteSpace($ErrorCategory)) { $null } else { $ErrorCategory }
        error_message = if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { $null } else { $ErrorMessage }
    }
}

function Invoke-GitHubLocalIndexConsistencyCheck {
    param(
        [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot),
        [string] $Owner = 'wlyaaaaa',
        [string[]] $ScanRoots = @(),
        [switch] $SkipFetch,
        [switch] $Strict,
        [switch] $KeepGenerated
    )

    $generatedRoot = New-GitHubLocalIndexConsistencyTempRoot -RepoRoot $RepoRoot
    New-Item -ItemType Directory -Path $generatedRoot -Force | Out-Null

    try {
        $currentGeneration = Get-GitHubLocalIndexCurrentGenerationState -RepoRoot $RepoRoot
        # Dot-sourcing runs each script's param block in this scope. Pass the
        # caller's values explicitly so their defaults cannot silently reset
        # the requested observation mode or repository root.
        . (Join-Path $RepoRoot 'tools\Update-GitHubIndex.ps1') -RepoRoot $RepoRoot -Owner $Owner -ScanRoots $ScanRoots -SkipFetch:$SkipFetch -NoWrite
        . (Join-Path $RepoRoot 'tools\Update-ScheduledTaskHealth.ps1') -RepoRoot $RepoRoot -NoWrite
        . (Join-Path $RepoRoot 'tools\Update-UserAutomationMap.ps1') -RepoRoot $RepoRoot -NoWrite

        $effectiveScanRoots = @($ScanRoots)
        if ($effectiveScanRoots.Count -eq 0) {
            $effectiveScanRoots = @(Get-IndexedCloneScanRoots -RepoRoot $RepoRoot)
        }
        Invoke-UpdateGitHubIndex -Owner $Owner -RepoRoot $RepoRoot -OutputRoot $generatedRoot -GenerationId $currentGeneration.generation_id -ObservedAt $currentGeneration.observed_at -ScanRoots $effectiveScanRoots -SkipFetch:$SkipFetch | Out-Null
        Invoke-UpdateScheduledTaskHealth -RepoRoot $RepoRoot -OutputRoot $generatedRoot -GenerationId $currentGeneration.generation_id -ObservedAt $currentGeneration.observed_at | Out-Null
        Invoke-UpdateUserAutomationMap -RepoRoot $RepoRoot -OutputRoot $generatedRoot -GenerationId $currentGeneration.generation_id -ObservedAt $currentGeneration.observed_at | Out-Null

        $comparisons = @(Compare-GitHubLocalIndexDocuments -RepoRoot $RepoRoot -GeneratedRoot $generatedRoot)
        $driftRows = @($comparisons | Where-Object { -not $_.Same })
        $stablePaths = @(Get-GitHubLocalIndexStableDocumentPaths)
        $stableDriftRows = @($driftRows | Where-Object { $stablePaths -contains $_.File })
        $volatileDriftRows = @($driftRows | Where-Object { $stablePaths -notcontains $_.File })
        $manifestConsistent = -not $currentGeneration.present -or [bool] $currentGeneration.valid
        $driftConsistent = if ($Strict) { $driftRows.Count -eq 0 } else { $stableDriftRows.Count -eq 0 }
        $isConsistent = $manifestConsistent -and $driftConsistent

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
            CurrentGenerationPresent = [bool] $currentGeneration.present
            CurrentGenerationValid = $currentGeneration.valid
            CurrentGenerationReason = $currentGeneration.reason
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
        $exitCode = if ($result.IsConsistent) { 0 } else { 1 }
        $outcome = if ($result.IsConsistent) { 'success' } else { 'drift' }
        if (-not [string]::IsNullOrWhiteSpace($ReceiptPath)) {
            $receipt = New-GitHubLocalIndexConsistencyReceipt -Outcome $outcome -ExitCode $exitCode -Result $result
            Write-GitHubLocalIndexConsistencyReceipt -RepoRoot $RepoRoot -ReceiptPath $ReceiptPath -Receipt $receipt
        }
        Write-GitHubLocalIndexConsistencyResult -Result $result
        exit $exitCode
    }
    catch {
        $errorMessage = $_.Exception.Message
        if (-not [string]::IsNullOrWhiteSpace($ReceiptPath)) {
            try {
                $receipt = New-GitHubLocalIndexConsistencyReceipt `
                    -Outcome 'error' `
                    -ExitCode 2 `
                    -ErrorCategory 'consistency_check_failed' `
                    -ErrorMessage $errorMessage
                Write-GitHubLocalIndexConsistencyReceipt -RepoRoot $RepoRoot -ReceiptPath $ReceiptPath -Receipt $receipt
            }
            catch {
                Write-Error "Consistency receipt publication failed: $($_.Exception.Message)"
            }
        }
        Write-Error $errorMessage
        exit 2
    }
}
