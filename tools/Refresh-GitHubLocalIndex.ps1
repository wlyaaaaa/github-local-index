param(
    [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [switch] $CheckOnly,
    [switch] $Fast,
    [switch] $ZeroFetchAtomic,
    [int] $FailAfterPublishCount = 0,
    [string] $Repo,
    [string] $RepoPath,
    [switch] $Json
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'GitHubIndex.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'GitHubIndex.PrivateNavigation.psm1') -Force

$logDir = Join-Path $RepoRoot '99_private\logs'
$logPath = Join-Path $logDir 'GitHubLocalIndexRefresh.log'
$script:RefreshLoggingEnabled = -not $CheckOnly

function Write-RefreshLog {
    param([string] $Message)

    if (-not $script:RefreshLoggingEnabled) {
        return
    }
    if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
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

function Normalize-RefreshRepoSlug {
    param([AllowNull()] [string] $Value)

    ConvertTo-GitHubRepoSlug $Value
}

function Resolve-IndexedClonePath {
    param(
        [Parameter(Mandatory = $true)] [string] $RepoRoot,
        [Parameter(Mandatory = $true)] [string] $Repo
    )

    $normalizedRepo = Normalize-RefreshRepoSlug $Repo
    if ([string]::IsNullOrWhiteSpace($normalizedRepo)) {
        return $null
    }

    $navigation = Get-GitHubIndexPrivateRepositoryNavigation -RepoRoot $RepoRoot -Repo $normalizedRepo
    if ($navigation.status -eq 'current') {
        return [string] $navigation.path
    }
    return $null
}

function Invoke-GitScalar {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string[]] $Arguments
    )

    $output = & git -C $Path @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    return ([string] $output).Trim()
}

function Invoke-FastRepositoryRefresh {
    param(
        [Parameter(Mandatory = $true)] [string] $RepoRoot,
        [string] $Repo,
        [string] $RepoPath
    )

    $targetPath = $RepoPath
    if ([string]::IsNullOrWhiteSpace($targetPath)) {
        if ([string]::IsNullOrWhiteSpace($Repo)) {
            throw 'Fast refresh requires -Repo or -RepoPath.'
        }

        $targetPath = Resolve-IndexedClonePath -RepoRoot $RepoRoot -Repo $Repo
    }

    if ([string]::IsNullOrWhiteSpace($targetPath)) {
        throw "Cannot resolve local clone path for repo '$Repo'. Run a full refresh to rebuild the ignored private navigation cache, or pass -RepoPath for bootstrap."
    }

    if (-not (Test-Path -LiteralPath $targetPath -PathType Container)) {
        throw "Local clone path does not exist: $targetPath"
    }

    $gitDir = Invoke-GitScalar -Path $targetPath -Arguments @('rev-parse', '--git-dir')
    if ([string]::IsNullOrWhiteSpace($gitDir)) {
        throw "Path is not a Git worktree: $targetPath"
    }

    $originUrl = Invoke-GitScalar -Path $targetPath -Arguments @('remote', 'get-url', 'origin')
    $resolvedRepo = if (-not [string]::IsNullOrWhiteSpace($Repo)) { Normalize-RefreshRepoSlug $Repo } else { Normalize-RefreshRepoSlug $originUrl }
    if ([string]::IsNullOrWhiteSpace($resolvedRepo)) {
        throw "Cannot normalize GitHub remote for path: $targetPath"
    }

    $summary = Get-ProjectAdmissionRecord -Repo $resolvedRepo -RepoPath $targetPath -IndexRoot $RepoRoot

    Write-RefreshLog ("FAST repo={0} root={1} mode={2} decision={3} worktrees={4}" -f `
        $summary.repo, $summary.local_root, $summary.remote_mode, $summary.decision, @($summary.worktrees).Count)

    return $summary
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

function Invoke-ConsistencyCheck {
    param([string] $Name)

    Invoke-RefreshStep $Name {
        . (Join-Path $RepoRoot 'tools\Test-GitHubLocalIndexConsistency.ps1')
        $result = Invoke-GitHubLocalIndexConsistencyCheck -RepoRoot $RepoRoot -SkipFetch
        Write-RefreshLog "CONSISTENCY compared=$($result.Compared) drift=$($result.DriftCount) stable=$($result.StableDriftCount) volatile=$($result.VolatileDriftCount)"
        if (-not $result.IsConsistent) {
            $files = ($result.DriftFiles | Select-Object -First 10) -join '; '
            Write-RefreshLog "CONSISTENCY drift files: $files"
            throw "GitHub local index drift detected in $($result.DriftCount) generated document(s)."
        }
    }
}

function Get-RefreshCurrentPointerHash {
    param([Parameter(Mandatory = $true)] [string] $RepoRoot)

    $pointerPath = Join-Path $RepoRoot '00_总览/current-generation.json'
    if (-not (Test-Path -LiteralPath $pointerPath -PathType Leaf)) {
        return ''
    }
    return (Get-FileHash -LiteralPath $pointerPath -Algorithm SHA256).Hash
}

function Resolve-RefreshContainedPath {
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

function Assert-RefreshExactPropertyNames {
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

function Assert-RefreshNotReparsePoint {
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

function Assert-RefreshPathChainNotReparsePoint {
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
    if ($resolvedTarget -eq $resolvedBase) {
        Assert-RefreshNotReparsePoint -Path $resolvedBase -Label $Label
        return
    }
    Assert-RefreshNotReparsePoint -Path $resolvedBase -Label $Label
    $current = $resolvedBase
    foreach ($segment in ($resolvedTarget.Substring($prefix.Length) -split '[\\/]')) {
        if ([string]::IsNullOrWhiteSpace($segment)) {
            continue
        }
        $current = Join-Path $current $segment
        if (Test-Path -LiteralPath $current) {
            Assert-RefreshNotReparsePoint -Path $current -Label $Label
        }
    }
}

function Assert-RefreshGenerationTreeClosed {
    param(
        [Parameter(Mandatory = $true)] [string] $GenerationRoot,
        [Parameter(Mandatory = $true)] [string[]] $DocumentRelativePaths
    )

    $resolvedRoot = [System.IO.Path]::GetFullPath($GenerationRoot).TrimEnd('\', '/')
    Assert-RefreshPathChainNotReparsePoint -BasePath $resolvedRoot -TargetPath $resolvedRoot -Label 'generation tree root'
    $prefix = $resolvedRoot + [System.IO.Path]::DirectorySeparatorChar
    $allowedFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $allowedDirectories = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $allowedDirectories.Add($resolvedRoot) | Out-Null
    $allowedFiles.Add((Join-Path $resolvedRoot 'manifest.json')) | Out-Null
    foreach ($relativePath in @($DocumentRelativePaths)) {
        $filePath = Resolve-RefreshContainedPath -BasePath $resolvedRoot -RelativePath ([string] $relativePath).Replace('/', '\') -Label 'generation tree document path'
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
        Assert-RefreshNotReparsePoint -Path $resolved -Label 'generation tree item'
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

function Enter-GitHubLocalIndexRefreshMutex {
    param([Parameter(Mandatory = $true)] [string] $RepoRoot)

    $normalizedRoot = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalizedRoot.ToLowerInvariant()))
    }
    finally {
        $hash.Dispose()
    }
    $suffix = ([BitConverter]::ToString($digest) -replace '-', '').Substring(0, 24)
    $mutex = [Threading.Mutex]::new($false, "Global\GitHubLocalIndexRefresh-$suffix")
    try {
        $acquired = $mutex.WaitOne(0)
    }
    catch [Threading.AbandonedMutexException] {
        $acquired = $true
    }
    if (-not $acquired) {
        $mutex.Dispose()
        throw "Another GitHub local index refresh is already publishing for $normalizedRoot."
    }
    return $mutex
}

function Get-RefreshGeneratedDocumentPaths {
    return @(
        '00_总览/GitHub总览.md',
        '00_总览/当前同步看板.md',
        '01_仓库索引/GitHub仓库索引.md',
        '01_仓库索引/本地clone索引.md',
        '01_仓库索引/未发现本地clone.md',
        '02_同步诊断/未推送队列.md',
        '02_同步诊断/工作区脏状态.md',
        '02_同步诊断/分支与远端诊断.md'
    )
}

function Get-RefreshExpectedProjectionMap {
    $map = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($relativePath in @(Get-RefreshGeneratedDocumentPaths)) {
        $normalized = $relativePath.Replace('\', '/')
        $map['documents/' + $normalized] = $normalized
    }
    return $map
}

function Invoke-RefreshIncomingRecovery {
    param(
        [Parameter(Mandatory = $true)] [string] $RepoRoot,
        [Parameter(Mandatory = $true)] [string] $ExcludeGenerationId
    )

    $generationsRoot = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot '00_总览/generations')).TrimEnd('\', '/')
    Assert-RefreshPathChainNotReparsePoint -BasePath $RepoRoot -TargetPath $generationsRoot -Label 'generations root'
    if (-not (Test-Path -LiteralPath $generationsRoot -PathType Container)) {
        return @()
    }
    Assert-RefreshNotReparsePoint -Path $generationsRoot -Label 'generations root'
    $prefix = $generationsRoot + [System.IO.Path]::DirectorySeparatorChar
    $recovered = @()
    foreach ($directory in @(Get-ChildItem -LiteralPath $generationsRoot -Directory -Force)) {
        if (-not $directory.Name.EndsWith('.incoming', [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        if ($directory.Name -eq ($ExcludeGenerationId + '.incoming')) {
            continue
        }
        if ($directory.Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.incoming$') {
            throw "Refusing stale .incoming with an unsafe name: $($directory.Name)"
        }
        $resolved = [System.IO.Path]::GetFullPath($directory.FullName).TrimEnd('\', '/')
        if (-not $resolved.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing stale .incoming recovery outside $generationsRoot"
        }
        Assert-RefreshNotReparsePoint -Path $resolved -Label 'stale .incoming generation'
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
        $recovered += $directory.Name
    }
    return @($recovered)
}

function Write-RefreshAtomicBytesFile {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [byte[]] $Bytes
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $tempPath = Join-Path $directory ('.' + (Split-Path -Leaf $Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $stream = [System.IO.FileStream]::new(
            $tempPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None)
        try {
            $stream.Write($Bytes, 0, $Bytes.Length)
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [System.IO.File]::Move($tempPath, $Path, $true)
        }
        else {
            [System.IO.File]::Move($tempPath, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-RefreshAtomicTextFile {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $Text
    )

    Write-RefreshAtomicBytesFile `
        -Path $Path `
        -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($Text))
}

function Publish-RefreshGenerationFile {
    param(
        [Parameter(Mandatory = $true)] [string] $SourcePath,
        [Parameter(Mandatory = $true)] [string] $TargetPath,
        [string] $ContainmentRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ContainmentRoot)) {
        Assert-RefreshPathChainNotReparsePoint -BasePath $ContainmentRoot -TargetPath $TargetPath -Label 'atomic publication target'
    }
    $targetDirectory = Split-Path -Parent $TargetPath
    if (-not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
    }
    $tempPath = Join-Path $targetDirectory ('.' + (Split-Path -Leaf $TargetPath) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $bytes = [System.IO.File]::ReadAllBytes($SourcePath)
        $stream = [System.IO.FileStream]::new(
            $tempPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }
        if (Test-Path -LiteralPath $TargetPath -PathType Leaf) {
            [System.IO.File]::Move($tempPath, $TargetPath, $true)
        }
        else {
            [System.IO.File]::Move($tempPath, $TargetPath)
        }
        if (-not [string]::IsNullOrWhiteSpace($ContainmentRoot)) {
            Assert-RefreshPathChainNotReparsePoint -BasePath $ContainmentRoot -TargetPath $TargetPath -Label 'atomic publication target'
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Assert-RefreshPublishedGenerationReadback {
    param(
        [Parameter(Mandatory = $true)] [string] $RepoRoot,
        [Parameter(Mandatory = $true)] [string] $PointerPath,
        [Parameter(Mandatory = $true)] [string] $GenerationId,
        [Parameter(Mandatory = $true)] [string] $ExpectedManifestHash,
        [switch] $RequireProjectionMatch
    )

    Assert-RefreshNotReparsePoint -Path $PointerPath -Label 'current generation pointer'
    $pointer = Get-Content -LiteralPath $PointerPath -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
    Assert-RefreshExactPropertyNames -Object $pointer -Expected @(
        'schema', 'generation_id', 'observed_at', 'authoritative',
        'integrity_authoritative_for_generation', 'decision_authority',
        'as_of_observed_at', 'owner', 'generation_root',
        'generation_manifest_sha256', 'projection_role', 'documents',
        'retention_policy', 'previous_generation_id', 'publication'
    ) -Label 'current generation pointer'
    if ([string] $pointer.schema -ne 'github-local-index.current-generation.v1' -or
        [string] $pointer.generation_id -ne $GenerationId -or
        [bool] $pointer.authoritative -or
        -not [bool] $pointer.integrity_authoritative_for_generation -or
        [bool] $pointer.decision_authority) {
        throw 'Current generation pointer readback failed its authority contract.'
    }
    $generationBase = Join-Path $RepoRoot '00_总览/generations'
    Assert-RefreshNotReparsePoint -Path $generationBase -Label 'generations root'
    $generationRoot = Resolve-RefreshContainedPath `
        -BasePath $RepoRoot `
        -RelativePath ([string] $pointer.generation_root).Replace('/', '\') `
        -Label 'current pointer generation_root'
    $expectedGenerationRoot = [System.IO.Path]::GetFullPath((Join-Path $generationBase $GenerationId)).TrimEnd('\', '/')
    if ($generationRoot -ne $expectedGenerationRoot) {
        throw 'Current generation pointer generation_root does not match generation_id.'
    }
    Assert-RefreshPathChainNotReparsePoint -BasePath $RepoRoot -TargetPath $generationRoot -Label 'immutable generation path'
    Assert-RefreshNotReparsePoint -Path $generationRoot -Label 'immutable generation root'
    $manifestPath = Join-Path $generationRoot 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw 'Current generation pointer manifest readback failed: manifest missing.'
    }
    Assert-RefreshNotReparsePoint -Path $manifestPath -Label 'immutable generation manifest'
    $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    if ($manifestHash -ne $ExpectedManifestHash -or $manifestHash -ne [string] $pointer.generation_manifest_sha256) {
        throw 'Current generation pointer manifest hash readback failed.'
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
    Assert-RefreshExactPropertyNames -Object $manifest -Expected @(
        'schema', 'generation_id', 'observed_at', 'immutable',
        'integrity_authoritative_for_generation', 'decision_authority',
        'as_of_observed_at', 'owner', 'source', 'documents'
    ) -Label 'generation manifest'
    if ([string] $manifest.schema -ne 'github-local-index.generation.v1' -or
        [string] $manifest.generation_id -ne $GenerationId -or
        -not [bool] $manifest.immutable -or
        -not [bool] $manifest.integrity_authoritative_for_generation -or
        [bool] $manifest.decision_authority) {
        throw 'Generation manifest readback failed its authority contract.'
    }

    $expectedPaths = @(Get-RefreshGeneratedDocumentPaths | ForEach-Object { 'documents/' + $_.Replace('\', '/') })
    $manifestPaths = @($manifest.documents | ForEach-Object { ([string] $_.path).Replace('\', '/') })
    if ($manifestPaths.Count -ne $expectedPaths.Count -or
        (@($manifestPaths | Sort-Object -Unique).Count -ne $manifestPaths.Count) -or
        (@($manifestPaths | Where-Object { $expectedPaths -cnotcontains $_ }).Count -gt 0) -or
        (@($expectedPaths | Where-Object { $manifestPaths -cnotcontains $_ }).Count -gt 0)) {
        throw 'Generation manifest documents are not the closed generated document set.'
    }
    $expectedProjectionMap = Get-RefreshExpectedProjectionMap
    Assert-RefreshGenerationTreeClosed -GenerationRoot $generationRoot -DocumentRelativePaths $manifestPaths | Out-Null
    $pointerByPath = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    foreach ($document in @($pointer.documents)) {
        Assert-RefreshExactPropertyNames -Object $document -Expected @('path', 'projection_path', 'sha256', 'bytes') -Label 'current pointer document'
        $pointerByPath[[string] $document.path] = $document
    }
    if ($pointerByPath.Count -ne $manifestPaths.Count) {
        throw 'Current pointer documents contain missing or extra entries.'
    }
    foreach ($document in @($manifest.documents)) {
        Assert-RefreshExactPropertyNames -Object $document -Expected @('path', 'projection_path', 'sha256', 'bytes') -Label 'generation manifest document'
        if ([string]::IsNullOrWhiteSpace([string] $document.path) -or
            [string]::IsNullOrWhiteSpace([string] $document.projection_path) -or
            [string] $document.sha256 -notmatch '^[0-9A-Fa-f]{64}$' -or
            [string]::IsNullOrWhiteSpace([string] $document.bytes)) {
            throw 'Current pointer generation document record is malformed.'
        }
        $normalizedDocumentPath = ([string] $document.path).Replace('\', '/')
        $normalizedProjectionPath = ([string] $document.projection_path).Replace('\', '/')
        if (-not $expectedProjectionMap.ContainsKey($normalizedDocumentPath) -or
            $normalizedProjectionPath -cne $expectedProjectionMap[$normalizedDocumentPath]) {
            throw "Generation projection mapping is invalid: $normalizedDocumentPath"
        }
        try { $recordBytes = [int64] $document.bytes } catch { throw 'Current pointer generation document bytes are malformed.' }
        if ($recordBytes -lt 0) {
            throw 'Current pointer generation document bytes are negative.'
        }
        $relativePath = ([string] $document.path).Replace('/', '\')
        $immutablePath = Resolve-RefreshContainedPath -BasePath $generationRoot -RelativePath $relativePath -Label 'generation document path'
        Assert-RefreshPathChainNotReparsePoint -BasePath $generationRoot -TargetPath $immutablePath -Label 'generation document path'
        if (-not (Test-Path -LiteralPath $immutablePath -PathType Leaf)) {
            throw "Generation document readback failed: $relativePath"
        }
        Assert-RefreshNotReparsePoint -Path $immutablePath -Label 'generation document'
        $hash = (Get-FileHash -LiteralPath $immutablePath -Algorithm SHA256).Hash
        if ($hash -ne [string] $document.sha256) {
            throw "Generation document hash readback failed: $relativePath"
        }
        $actualBytes = [System.IO.File]::ReadAllBytes($immutablePath).Length
        if ([int64] $actualBytes -ne $recordBytes) {
            throw "Generation document byte count readback failed: $relativePath"
        }
        $pointerDocument = $pointerByPath[[string] $document.path]
        if ($null -eq $pointerDocument -or
            [string] $pointerDocument.sha256 -ne $hash -or
            ([string] $pointerDocument.projection_path).Replace('/', '\') -ne ([string] $document.projection_path).Replace('/', '\') -or
            [int64] $pointerDocument.bytes -ne $recordBytes) {
            throw "Current pointer document hash readback failed: $relativePath"
        }
        $projectionPath = Resolve-RefreshContainedPath -BasePath $RepoRoot -RelativePath ([string] $document.projection_path).Replace('/', '\') -Label 'compatibility projection path'
        Assert-RefreshPathChainNotReparsePoint -BasePath $RepoRoot -TargetPath $projectionPath -Label 'compatibility projection path'
        if (-not (Test-Path -LiteralPath $projectionPath -PathType Leaf)) {
            if ($RequireProjectionMatch) {
                throw "Compatibility projection readback failed: $($document.projection_path)"
            }
            continue
        }
        Assert-RefreshNotReparsePoint -Path $projectionPath -Label 'compatibility projection'
        if ((Get-FileHash -LiteralPath $projectionPath -Algorithm SHA256).Hash -ne $hash) {
            if ($RequireProjectionMatch) {
                throw "Compatibility projection hash readback failed: $($document.projection_path)"
            }
        }
    }
    return $true
}

function Assert-RefreshImmutableGenerationDirectory {
    param(
        [Parameter(Mandatory = $true)] [string] $RepoRoot,
        [Parameter(Mandatory = $true)] [string] $GenerationId
    )

    $generationRoot = Resolve-RefreshContainedPath `
        -BasePath $RepoRoot `
        -RelativePath ('00_总览/generations/' + $GenerationId) `
        -Label 'immutable generation root'
    Assert-RefreshPathChainNotReparsePoint -BasePath $RepoRoot -TargetPath $generationRoot -Label 'immutable generation root'
    if (-not (Test-Path -LiteralPath $generationRoot -PathType Container)) {
        throw "Immutable generation is missing: $GenerationId"
    }
    $manifestPath = Join-Path $generationRoot 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Immutable generation manifest is missing: $GenerationId"
    }
    Assert-RefreshNotReparsePoint -Path $manifestPath -Label 'immutable generation manifest'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
    Assert-RefreshExactPropertyNames -Object $manifest -Expected @(
        'schema', 'generation_id', 'observed_at', 'immutable',
        'integrity_authoritative_for_generation', 'decision_authority',
        'as_of_observed_at', 'owner', 'source', 'documents'
    ) -Label 'immutable generation manifest'
    if ([string] $manifest.schema -ne 'github-local-index.generation.v1' -or
        [string] $manifest.generation_id -ne $GenerationId -or
        -not [bool] $manifest.immutable -or
        -not [bool] $manifest.integrity_authoritative_for_generation -or
        [bool] $manifest.decision_authority) {
        throw "Immutable generation manifest is not verified: $GenerationId"
    }
    $expectedPaths = @(Get-RefreshGeneratedDocumentPaths | ForEach-Object { 'documents/' + $_.Replace('\', '/') })
    $actualPaths = @($manifest.documents | ForEach-Object { ([string] $_.path).Replace('\', '/') })
    if ($actualPaths.Count -ne $expectedPaths.Count -or
        (@($actualPaths | Sort-Object -Unique).Count -ne $actualPaths.Count) -or
        (@($actualPaths | Where-Object { $expectedPaths -cnotcontains $_ }).Count -gt 0) -or
        (@($expectedPaths | Where-Object { $actualPaths -cnotcontains $_ }).Count -gt 0)) {
        throw "Immutable generation document set is not closed: $GenerationId"
    }
    $expectedProjectionMap = Get-RefreshExpectedProjectionMap
    Assert-RefreshGenerationTreeClosed -GenerationRoot $generationRoot -DocumentRelativePaths $actualPaths | Out-Null
    foreach ($document in @($manifest.documents)) {
        Assert-RefreshExactPropertyNames -Object $document -Expected @('path', 'projection_path', 'sha256', 'bytes') -Label 'immutable generation document'
        if ([string]::IsNullOrWhiteSpace([string] $document.path) -or
            [string]::IsNullOrWhiteSpace([string] $document.projection_path) -or
            [string] $document.sha256 -notmatch '^[0-9A-Fa-f]{64}$' -or
            [string]::IsNullOrWhiteSpace([string] $document.bytes)) {
            throw "Immutable generation document record is malformed: $GenerationId"
        }
        $normalizedDocumentPath = ([string] $document.path).Replace('\', '/')
        $normalizedProjectionPath = ([string] $document.projection_path).Replace('\', '/')
        if (-not $expectedProjectionMap.ContainsKey($normalizedDocumentPath) -or
            $normalizedProjectionPath -cne $expectedProjectionMap[$normalizedDocumentPath]) {
            throw "Immutable generation projection mapping is invalid: $GenerationId"
        }
        try { $recordBytes = [int64] $document.bytes } catch { throw "Immutable generation document bytes are malformed: $GenerationId" }
        if ($recordBytes -lt 0) {
            throw "Immutable generation document bytes are negative: $GenerationId"
        }
        $relativePath = ([string] $document.path).Replace('/', '\')
        $path = Resolve-RefreshContainedPath -BasePath $generationRoot -RelativePath $relativePath -Label 'immutable generation document path'
        Assert-RefreshPathChainNotReparsePoint -BasePath $generationRoot -TargetPath $path -Label 'immutable generation document path'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Immutable generation document is missing: $relativePath"
        }
        Assert-RefreshNotReparsePoint -Path $path -Label 'immutable generation document'
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne [string] $document.sha256) {
            throw "Immutable generation document hash is invalid: $relativePath"
        }
        if ([int64] ([System.IO.File]::ReadAllBytes($path).Length) -ne $recordBytes) {
            throw "Immutable generation document byte count is invalid: $relativePath"
        }
        $text = Get-Content -LiteralPath $path -Raw -Encoding utf8
        if ($text -notmatch "(?m)^<!-- generation_id=$([regex]::Escape($GenerationId)) -->\r?$") {
            throw "Immutable generation document provenance is invalid: $relativePath"
        }
    }
    return $true
}

function Invoke-RefreshGenerationRetention {
    param(
        [Parameter(Mandatory = $true)] [string] $RepoRoot,
        [Parameter(Mandatory = $true)] [string] $CurrentGenerationId,
        [AllowNull()] [string] $PreviousGenerationId
    )

    $generationsRoot = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot '00_总览/generations')).TrimEnd('\', '/')
    Assert-RefreshPathChainNotReparsePoint -BasePath $RepoRoot -TargetPath $generationsRoot -Label 'generations root'
    if (-not (Test-Path -LiteralPath $generationsRoot -PathType Container)) {
        return @()
    }
    Assert-RefreshNotReparsePoint -Path $generationsRoot -Label 'generations root'
    $retained = @($CurrentGenerationId, $PreviousGenerationId) |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) } |
        Sort-Object -Unique
    $removed = @()
    foreach ($directory in @(Get-ChildItem -LiteralPath $generationsRoot -Directory)) {
        Assert-RefreshNotReparsePoint -Path $directory.FullName -Label 'generation retention candidate'
        if ($directory.Name.EndsWith('.incoming', [System.StringComparison]::OrdinalIgnoreCase) -or
            $retained -contains $directory.Name) {
            continue
        }
        if ($directory.Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            throw "Refusing generation retention cleanup with an unsafe name: $($directory.Name)"
        }
        $resolved = [System.IO.Path]::GetFullPath($directory.FullName).TrimEnd('\', '/')
        $prefix = $generationsRoot + [System.IO.Path]::DirectorySeparatorChar
        if (-not $resolved.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing generation retention cleanup outside $generationsRoot"
        }
        Assert-RefreshNotReparsePoint -Path $resolved -Label 'generation retention target'
        Assert-RefreshImmutableGenerationDirectory -RepoRoot $RepoRoot -GenerationId $directory.Name | Out-Null
        Remove-Item -LiteralPath $resolved -Recurse -Force
        $removed += $directory.Name
    }
    return @($removed)
}

function Publish-GitHubLocalIndexGeneration {
    param(
        [Parameter(Mandatory = $true)] [string] $GenerationRoot,
        [Parameter(Mandatory = $true)] [string] $RepoRoot,
        [Parameter(Mandatory = $true)] [string] $GenerationId,
        [Parameter(Mandatory = $true)] [string] $ObservedAt,
        [string] $ExpectedPointerHash,
        [int] $FailAfterPublishCount = 0,
        [string[]] $RecoveredIncoming = @()
    )

    if ($GenerationId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "Generation id is not a safe directory name: $GenerationId"
    }
    $relativePaths = @(Get-RefreshGeneratedDocumentPaths)
    $generationDirectory = Join-Path $RepoRoot ('00_总览/generations/' + $GenerationId)
    $generationIncomingDirectory = Join-Path $RepoRoot ('00_总览/generations/' + $GenerationId + '.incoming')
    $generationDocumentsDirectory = Join-Path $generationIncomingDirectory 'documents'
    Assert-RefreshPathChainNotReparsePoint -BasePath $RepoRoot -TargetPath $generationIncomingDirectory -Label 'incoming generation path'
    if ((Test-Path -LiteralPath $generationDirectory -PathType Container) -or
        (Test-Path -LiteralPath $generationIncomingDirectory -PathType Container)) {
        throw "Generation already exists and is immutable: $GenerationId"
    }
    $previousGenerationId = $null
    $recoveredIncoming = @($RecoveredIncoming)
    $recoveredIncoming += @(Invoke-RefreshIncomingRecovery -RepoRoot $RepoRoot -ExcludeGenerationId $GenerationId)
    $currentPointerPath = Join-Path $RepoRoot '00_总览/current-generation.json'
    if (Test-Path -LiteralPath $currentPointerPath -PathType Leaf) {
        try {
            $currentPointer = Get-Content -LiteralPath $currentPointerPath -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
            $previousGenerationId = [string] $currentPointer.generation_id
            $existingManifestHash = [string] $currentPointer.generation_manifest_sha256
            if ([string]::IsNullOrWhiteSpace($existingManifestHash)) {
                throw 'Current generation pointer has no generation manifest hash.'
            }
            Assert-RefreshPublishedGenerationReadback `
                -RepoRoot $RepoRoot `
                -PointerPath $currentPointerPath `
                -GenerationId $previousGenerationId `
                -ExpectedManifestHash $existingManifestHash | Out-Null
        }
        catch {
            throw "Current generation pointer closure is invalid; refusing to overwrite it: $($_.Exception.Message)"
        }
    }
    New-Item -ItemType Directory -Path $generationDocumentsDirectory -Force | Out-Null

    $documents = foreach ($relativePath in $relativePaths) {
        $sourcePath = Join-Path $GenerationRoot $relativePath
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "Generation is incomplete; missing document: $relativePath"
        }
        $text = Get-Content -LiteralPath $sourcePath -Raw -Encoding utf8
        if ($text -notmatch "(?m)^<!-- generation_id=$([regex]::Escape($GenerationId)) -->\r?$") {
            throw "Generation provenance is incomplete: $relativePath"
        }
        $generationPath = Join-Path $generationDocumentsDirectory $relativePath
        Assert-RefreshPathChainNotReparsePoint -BasePath $generationIncomingDirectory -TargetPath $generationPath -Label 'incoming generation document path'
        Publish-RefreshGenerationFile -SourcePath $sourcePath -TargetPath $generationPath -ContainmentRoot $generationIncomingDirectory
        $hash = (Get-FileHash -LiteralPath $generationPath -Algorithm SHA256).Hash
        $bytes = [System.IO.File]::ReadAllBytes($generationPath).Length
        if ($hash -ne (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash) {
            throw "Generation readback hash mismatch: $relativePath"
        }
        [ordered]@{
            path = ('documents/' + $relativePath.Replace('\', '/'))
            projection_path = $relativePath.Replace('\', '/')
            sha256 = $hash
            bytes = $bytes
        }
    }

    $generationManifest = [ordered]@{
        schema = 'github-local-index.generation.v1'
        generation_id = $GenerationId
        observed_at = $ObservedAt
        immutable = $true
        integrity_authoritative_for_generation = $true
        decision_authority = $false
        as_of_observed_at = $ObservedAt
        owner = 'github-local-index'
        source = 'validated temporary generation from Git and GitHub owner providers'
        documents = @($documents)
    }
    $generationManifestPath = Join-Path $generationIncomingDirectory 'manifest.json'
    Write-RefreshAtomicTextFile -Path $generationManifestPath -Text (($generationManifest | ConvertTo-Json -Depth 8) + "`n")
    if (-not (Test-Path -LiteralPath $generationManifestPath -PathType Leaf)) {
        throw 'Immutable generation manifest readback failed.'
    }
    Assert-RefreshGenerationTreeClosed `
        -GenerationRoot $generationIncomingDirectory `
        -DocumentRelativePaths @($documents | ForEach-Object { [string] $_.path }) | Out-Null

    # Only a complete, read-back-verified incoming directory becomes an
    # immutable generation visible to the pointer.  A crash before this rename
    # leaves an .incoming recovery candidate, never a half-valid final id.
    [System.IO.Directory]::Move($generationIncomingDirectory, $generationDirectory)
    if (-not (Test-Path -LiteralPath $generationDirectory -PathType Container)) {
        throw 'Immutable generation directory rename readback failed.'
    }
    Assert-RefreshImmutableGenerationDirectory -RepoRoot $RepoRoot -GenerationId $GenerationId | Out-Null

    $generationManifestPath = Join-Path $generationDirectory 'manifest.json'
    $generationManifestHash = (Get-FileHash -LiteralPath $generationManifestPath -Algorithm SHA256).Hash

    $publishCount = 0
    foreach ($document in @($documents)) {
        if ($FailAfterPublishCount -gt 0 -and $publishCount -ge $FailAfterPublishCount) {
            throw "Injected generation publication failure after $publishCount projection(s); current pointer was not switched."
        }
        $projectionPath = Join-Path $RepoRoot ([string] $document.projection_path)
        # Revalidate the complete existing parent chain before the write. A
        # fixed relative path is not sufficient protection against a junction
        # introduced between generation validation and projection publication.
        Assert-RefreshPathChainNotReparsePoint -BasePath $RepoRoot -TargetPath $projectionPath -Label 'compatibility projection path'
        Publish-RefreshGenerationFile `
            -SourcePath (Join-Path $generationDirectory ([string] $document.path)) `
            -TargetPath $projectionPath `
            -ContainmentRoot $RepoRoot
        Assert-RefreshPathChainNotReparsePoint -BasePath $RepoRoot -TargetPath $projectionPath -Label 'compatibility projection path'
        if ((Get-FileHash -LiteralPath $projectionPath -Algorithm SHA256).Hash -ne [string] $document.sha256) {
            throw "Compatibility projection readback hash mismatch: $($document.projection_path)"
        }
        $publishCount++
    }

    $currentPointerHash = Get-RefreshCurrentPointerHash -RepoRoot $RepoRoot
    if ($PSBoundParameters.ContainsKey('ExpectedPointerHash') -and $currentPointerHash -ne $ExpectedPointerHash) {
        throw 'Current generation pointer changed during refresh; refusing to switch it over a concurrent writer.'
    }

    $pointer = [ordered]@{
        schema = 'github-local-index.current-generation.v1'
        generation_id = $GenerationId
        observed_at = $ObservedAt
        authoritative = $false
        integrity_authoritative_for_generation = $true
        decision_authority = $false
        as_of_observed_at = $ObservedAt
        owner = 'github-local-index'
        generation_root = ('00_总览/generations/' + $GenerationId)
        generation_manifest_sha256 = $generationManifestHash
        projection_role = 'compatibility_only'
        documents = @($documents)
        retention_policy = 'current+previous'
        previous_generation_id = $previousGenerationId
        publication = 'pointer_switch_after_immutable_generation_and_projection_readback'
    }
    $manifestPath = Join-Path $RepoRoot '00_总览/current-generation.json'
    Assert-RefreshPathChainNotReparsePoint -BasePath $RepoRoot -TargetPath $manifestPath -Label 'current generation pointer path'
    # The pointer is the final transaction boundary. A failure before this
    # write leaves the previous pointer and immutable documents intact, but
    # compatibility projections may be mixed/stale and remain repairable.
    Write-RefreshAtomicTextFile -Path $manifestPath -Text (($pointer | ConvertTo-Json -Depth 8) + "`n")
    Assert-RefreshPublishedGenerationReadback `
        -RepoRoot $RepoRoot `
        -PointerPath $manifestPath `
        -GenerationId $GenerationId `
        -ExpectedManifestHash $generationManifestHash `
        -RequireProjectionMatch | Out-Null

    $removedGenerations = @()
    $publicationStatus = 'published'
    $cleanupWarning = $null
    try {
        $removedGenerations = @(Invoke-RefreshGenerationRetention `
            -RepoRoot $RepoRoot `
            -CurrentGenerationId $GenerationId `
            -PreviousGenerationId $previousGenerationId)
    }
    catch {
        $publicationStatus = 'published_with_cleanup_warning'
        $cleanupWarning = $_.Exception.Message
        Write-RefreshLog "WARNING published generation=$GenerationId cleanup_failed=$cleanupWarning"
    }
    return [pscustomobject]@{
        publication_status = $publicationStatus
        generation_id = $GenerationId
        manifest_path = $manifestPath
        generation_root = $generationDirectory
        document_count = $relativePaths.Count
        removed_generations = @($removedGenerations)
        recovered_incoming = @($recoveredIncoming | Sort-Object -Unique)
        cleanup_warning = $cleanupWarning
    }
}

function Invoke-AtomicGitHubLocalIndexRefresh {
    $refreshMutex = Enter-GitHubLocalIndexRefreshMutex -RepoRoot $RepoRoot
    $expectedPointerHash = Get-RefreshCurrentPointerHash -RepoRoot $RepoRoot
    $generationId = [guid]::NewGuid().ToString('N')
    $observedAt = [DateTimeOffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    $tempBase = [System.IO.Path]::GetTempPath()
    $generationRoot = Join-Path $tempBase ('github-local-index-generation-' + $generationId)
    try {
        New-Item -ItemType Directory -Path $generationRoot -Force | Out-Null
        Invoke-RefreshStep 'GitHub repository index (temporary generation)' {
            & (Join-Path $RepoRoot 'tools\Update-GitHubIndex.ps1') `
                -RepoRoot $RepoRoot -OutputRoot $generationRoot -GenerationId $generationId -ObservedAt $observedAt `
                -SkipFetch:$ZeroFetchAtomic | Out-Null
        }
        $publication = Publish-GitHubLocalIndexGeneration `
            -GenerationRoot $generationRoot `
            -RepoRoot $RepoRoot `
            -GenerationId $generationId `
            -ObservedAt $observedAt `
            -ExpectedPointerHash $expectedPointerHash `
            -FailAfterPublishCount $FailAfterPublishCount
        Write-RefreshLog "PUBLISHED generation=$generationId documents=$($publication.document_count) manifest=$($publication.manifest_path)"
        return $publication
    }
    finally {
        if (Test-Path -LiteralPath $generationRoot -PathType Container) {
            Remove-Item -LiteralPath $generationRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        try {
            $refreshMutex.ReleaseMutex()
        }
        finally {
            $refreshMutex.Dispose()
        }
    }
}

function Invoke-GitHubLocalIndexRefresh {
    Add-PathIfExists 'E:\Scoop\shims'
    Add-PathIfExists (Join-Path $env:USERPROFILE 'scoop\shims')
    Add-PathIfExists 'C:\Program Files\Git\cmd'

    Write-RefreshLog 'GitHub local index refresh started'

    if ($Fast -and $CheckOnly) {
        throw 'Use either -Fast or -CheckOnly, not both.'
    }
    if ($ZeroFetchAtomic -and ($Fast -or $CheckOnly)) {
        throw 'ZeroFetchAtomic applies only to the full atomic refresh.'
    }

    if ($Fast) {
        $result = $null
        Invoke-RefreshStep 'fast repository refresh' {
            $script:FastRepositoryRefreshResult = Invoke-FastRepositoryRefresh -RepoRoot $RepoRoot -Repo $Repo -RepoPath $RepoPath
        }
        $result = $script:FastRepositoryRefreshResult
        Write-RefreshLog 'GitHub local index fast refresh finished'
        $result
        return
    }

    if ($CheckOnly) {
        Invoke-ConsistencyCheck 'consistency check only'
        Write-RefreshLog 'GitHub local index consistency check finished'
        return
    }

    $publication = Invoke-AtomicGitHubLocalIndexRefresh

    Write-RefreshLog 'GitHub local index refresh finished'
    return $publication
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $result = Invoke-GitHubLocalIndexRefresh
        if ($Json -and $null -ne $result) {
            $result | ConvertTo-Json -Depth 10
        }
        elseif ($null -ne $result) {
            $result | Out-Host
        }
        exit 0
    }
    catch {
        Write-RefreshLog "FAILED refresh :: $($_.Exception.Message)"
        exit 1
    }
}
