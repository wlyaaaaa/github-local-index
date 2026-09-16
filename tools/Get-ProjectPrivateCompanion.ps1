#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Repo,
    [string] $RepoPath,
    [string] $IndexRoot = (Split-Path -Parent $PSScriptRoot),
    [switch] $Json
)

Import-Module (Join-Path $PSScriptRoot 'GitHubIndex.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'GitHubIndex.PrivateNavigation.psm1')

function Join-CompanionRelativePath {
    param([string] $Root, [string] $Relative)
    if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative)) { throw 'invalid_relative_path' }
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $path = [IO.Path]::GetFullPath((Join-Path $base $Relative))
    if (-not $path.StartsWith($base + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'invalid_relative_path' }
    return $path
}

function Get-ProjectPrivateCompanion {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Repo, [string] $RepoPath,
        [string] $IndexRoot = (Split-Path -Parent $PSScriptRoot))

    $ErrorActionPreference = 'Stop'
    $result = [pscustomobject][ordered]@{
        schema = 'github-local-index.private-companion.v1'
        status = 'unregistered'
        source_repository = ConvertTo-GitHubRepoSlug $Repo
        source_path = $RepoPath
        source_identity_verified = $false
        registered_target = $null
        prefix = $null
        files = @()
        issues = @()
        requires_live_revalidation_before_write = $true
    }
    $issues = [Collections.Generic.List[string]]::new()
    try {
        $registryPath = Join-Path $IndexRoot '99_private/registries/public-project-private-companion.json'
        if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) { return $result }
        $registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($registry.schema -ne 'github-local-index.public-project-private-companion.v1' -or
            -not (ConvertTo-GitHubRepoSlug $registry.repository) -or -not $registry.local_path) { throw 'registry_invalid' }
        $targetPath = [string]$registry.local_path
        $result.registered_target = [pscustomobject]@{
            repository = $registry.repository; path = $targetPath
            registered_visibility = $registry.visibility; live_visibility = 'unknown'
            identity_verified = $false; dirty = $null
        }
        $result.status = 'registered_unmapped'
        if (-not $RepoPath) {
            $navigation = Get-GitHubIndexPrivateRepositoryNavigation -RepoRoot $IndexRoot -Repo $result.source_repository
            if ($navigation.status -eq 'current') { $RepoPath = $navigation.path; $result.source_path = $RepoPath }
            else { $issues.Add('source_navigation_' + $navigation.status) }
        }
        $sourceIdentity = $null
        if ($RepoPath) {
            $origin = Invoke-GitCommandResult -Path $RepoPath -Arguments @('remote', 'get-url', 'origin')
            $sourceIdentity = ConvertTo-GitHubRepoSlug $origin.stdout
            if ($origin.exit_code -ne 0 -or -not $sourceIdentity -or $sourceIdentity -ine $result.source_repository) {
                $issues.Add('source_identity_mismatch'); $result.status = 'conflict'; return $result
            }
            $result.source_identity_verified = $true
        }
        $origin = Invoke-GitCommandResult -Path $targetPath -Arguments @('remote', 'get-url', 'origin')
        if ($origin.exit_code -ne 0 -or (ConvertTo-GitHubRepoSlug $origin.stdout) -ine $registry.repository) {
            $issues.Add('target_identity_mismatch'); $result.status = 'conflict'; return $result
        }
        $result.registered_target.identity_verified = $true
        $dirty = Invoke-GitCommandResult -Path $targetPath -Arguments @('status', '--porcelain=v1', '--untracked-files=normal')
        if ($dirty.exit_code -eq 0) { $result.registered_target.dirty = -not [string]::IsNullOrWhiteSpace($dirty.stdout) }
        else { $issues.Add('target_status_unavailable') }
        $catalogPath = Join-CompanionRelativePath $targetPath $registry.catalog
        $catalog = Get-Content -LiteralPath $catalogPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($catalog.schema -ne 'public-project-private-backup.catalog.v1' -or $catalog.target_id -ne $registry.target_id) { throw 'catalog_invalid' }
        $entries = @($catalog.sources | Where-Object { $_.source_repository -ieq $result.source_repository })
        if ($entries.Count -gt 1) { $issues.Add('catalog_mapping_ambiguous'); $result.status = 'conflict'; return $result }
        $entry = if ($entries.Count -eq 1) { $entries[0] } else { $null }
        if ($result.source_identity_verified) {
            $configRepo = Invoke-GitCommandResult -Path $RepoPath -Arguments @('config', '--local', '--get', 'codex.private-backup-repository')
            $configPrefix = Invoke-GitCommandResult -Path $RepoPath -Arguments @('config', '--local', '--get', 'codex.private-backup-prefix')
            if (($configRepo.stdout -and (ConvertTo-GitHubRepoSlug $configRepo.stdout) -ine $registry.repository) -or
                ($configPrefix.stdout -and (-not $entry -or $configPrefix.stdout.TrimEnd('/') -cne ([string]$entry.prefix).TrimEnd('/')))) {
                $issues.Add('source_config_conflict'); $result.status = 'conflict'; return $result
            }
        }
        if (-not $entry) { return $result }
        $result.prefix = $entry.prefix
        $prefixPath = Join-CompanionRelativePath $targetPath $entry.prefix
        $manifestPath = Join-CompanionRelativePath $targetPath $entry.manifest
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($manifest.schema -ne 'public-project-private-backup.manifest.v1' -or $manifest.source_repository -ine $result.source_repository) { throw 'manifest_invalid' }
        $result.files = @(
            foreach ($file in $manifest.files) {
                $targetFile = Join-CompanionRelativePath $prefixPath $file.target_relative_path
                $targetExists = Test-Path -LiteralPath $targetFile -PathType Leaf
                $hashStatus = if (-not $targetExists) { 'missing' } elseif ((Get-FileHash -LiteralPath $targetFile -Algorithm SHA256).Hash -ieq $file.sha256) { 'match' } else { 'drift' }
                $sourceFile = $null; $sourceStatus = 'unknown'; $linkTarget = $null
                if ($result.source_identity_verified) {
                    $sourceFile = Join-CompanionRelativePath $RepoPath $file.source_relative_path
                    $item = Get-Item -LiteralPath $sourceFile -Force -ErrorAction SilentlyContinue
                    if (-not $item) { $sourceStatus = 'missing' }
                    elseif ($item.LinkType) {
                        $resolved = $item.ResolveLinkTarget($true)
                        $linkTarget = if ($resolved) { $resolved.FullName } else { $null }
                        $sourceStatus = if (-not $resolved -or -not $resolved.Exists) { 'broken_link' } elseif ($linkTarget -ieq $targetFile) { 'linked' } else { 'link_mismatch' }
                    }
                    else { $sourceStatus = 'regular_file' }
                }
                [pscustomobject]@{
                    source_relative_path = $file.source_relative_path; source_path = $sourceFile
                    target_relative_path = $file.target_relative_path; target_path = $targetFile
                    source_status = $sourceStatus; link_target = $linkTarget; manifest_hash_status = $hashStatus
                }
            }
        )
        $result.status = 'mapped'
    }
    catch { $issues.Add('metadata_or_file_unavailable'); $result.status = 'unavailable' }
    finally { $result.issues = @($issues) }
    return $result
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Get-ProjectPrivateCompanion -Repo $Repo -RepoPath $RepoPath -IndexRoot $IndexRoot
    if ($Json) { $result | ConvertTo-Json -Depth 8 } else { $result }
}
