#requires -Version 7.0

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$providerPath = Join-Path $repoRoot 'tools/Get-ProjectCognitionSource.ps1'
if (-not (Test-Path -LiteralPath $providerPath -PathType Leaf)) {
    throw "Missing project cognition provider: $providerPath"
}

. $providerPath

$script:failures = 0
function Assert-CognitionEqual {
    param(
        [AllowNull()] [object] $Expected,
        [AllowNull()] [object] $Actual,
        [Parameter(Mandatory)] [string] $Name
    )
    if ($Expected -ne $Actual) {
        Write-Host "FAIL: $Name"
        Write-Host "  expected: $Expected"
        Write-Host "  actual:   $Actual"
        $script:failures++
        return
    }
    Write-Host "PASS: $Name"
}

function Assert-CognitionTrue {
    param(
        [Parameter(Mandatory)] [bool] $Condition,
        [Parameter(Mandatory)] [string] $Name
    )
    if (-not $Condition) {
        Write-Host "FAIL: $Name"
        $script:failures++
        return
    }
    Write-Host "PASS: $Name"
}

$pageOne = [pscustomobject]@{
    owner_id = 'U_ownerStable1'
    nodes = @(
        [pscustomobject]@{
            id = 'R_repoStable1'
            nameWithOwner = 'wlyaaaaa/alpha'
            visibility = 'PRIVATE'
            isArchived = $false
            defaultBranchRef = [pscustomobject]@{
                name = 'main'
                target = [pscustomobject]@{ oid = ('a' * 40) }
            }
            releases = [pscustomobject]@{
                nodes = @([pscustomobject]@{
                    id = 'RE_releaseStable1'
                    tagName = 'v1.0.0'
                    createdAt = '2026-08-01T00:00:00Z'
                    publishedAt = '2026-08-02T00:00:00Z'
                    updatedAt = '2026-08-03T00:00:00Z'
                    isDraft = $false
                    isPrerelease = $false
                })
            }
        }
    )
    page_info = [pscustomobject]@{ has_next_page = $true; end_cursor = 'cursor-1' }
}
$pageTwo = [pscustomobject]@{
    owner_id = 'U_ownerStable1'
    nodes = @(
        [pscustomobject]@{
            id = 'R_repoStable2'
            nameWithOwner = 'wlyaaaaa/empty-archive'
            visibility = 'PUBLIC'
            isArchived = $true
            defaultBranchRef = $null
            releases = [pscustomobject]@{ nodes = @() }
        }
    )
    page_info = [pscustomobject]@{ has_next_page = $false; end_cursor = $null }
}

$script:pageCalls = 0
$pageReader = {
    param($Owner, $Cursor, $PageSize)
    $script:pageCalls++
    Assert-CognitionEqual 'wlyaaaaa' $Owner 'fixture reader receives normalized owner'
    Assert-CognitionEqual 100 $PageSize 'fixture reader receives bounded page size'
    if ($null -eq $Cursor) { return $pageOne }
    Assert-CognitionEqual 'cursor-1' $Cursor 'second page follows returned cursor'
    return $pageTwo
}
$navigationReader = {
    param($Root)
    [pscustomobject]@{
        status = 'current'
        observed_at = '2026-08-23T00:00:00Z'
        entries = @(
            [pscustomobject]@{
                repo = 'wlyaaaaa/alpha'
                path = 'X:\private\alpha'
                visibility = 'PRIVATE'
                default_branch = 'main'
            },
            [pscustomobject]@{
                repo = 'wlyaaaaa/missing-live-repo'
                path = 'X:\private\stale'
                visibility = 'PRIVATE'
                default_branch = 'main'
            }
        )
    }
}
$originReader = {
    param($Path)
    if ($Path -eq 'X:\private\alpha') { return 'git@github.com:wlyaaaaa/alpha.git' }
    return 'https://github.com/wlyaaaaa/other.git'
}
$compareReader = {
    param($NameWithOwner, $BaseOid, $HeadOid, $MaxFiles)
    [pscustomobject]@{
        status = 'ahead'
        ahead_by = 3
        behind_by = 0
        total_commits = 3
        files = @(
            [pscustomobject]@{ filename = 'docs/one.md'; status = 'modified'; additions = 2; deletions = 1; changes = 3 },
            [pscustomobject]@{ filename = 'src/two.ps1'; status = 'added'; additions = 9; deletions = 0; changes = 9 }
        )
    }
}

$result = Invoke-ProjectCognitionSource -Owner 'WLYAAAAA' -RepoRoot $repoRoot `
    -PageReader $pageReader -NavigationReader $navigationReader -OriginReader $originReader `
    -CompareReader $compareReader -CompareRepositoryId 'R_repoStable1' `
    -CompareBaseOid ('b' * 40) -MaxCompareFiles 1 `
    -ObservedAt ([datetimeoffset]'2026-08-23T00:00:00Z')

Assert-CognitionEqual 'github-local-index.project-cognition-source.v1' $result.schema 'provider schema is versioned'
Assert-CognitionEqual 'complete' $result.coverage.status 'two-page inventory closes pagination'
Assert-CognitionEqual 2 $result.coverage.page_count 'all pages are counted'
Assert-CognitionEqual 2 $result.coverage.repository_count 'all repositories are returned'
Assert-CognitionEqual 2 $script:pageCalls 'pagination reader is called until closure'
Assert-CognitionEqual 'github.owner:U_ownerStable1' $result.source.source_key 'owner node id anchors source identity'
Assert-CognitionEqual 'github://owner/U_ownerStable1/repositories' $result.source.root_locator 'owner node id anchors root locator'
Assert-CognitionEqual 'repository:github:R_repoStable1' $result.repositories[0].repository_key 'repository node id anchors repository identity'
Assert-CognitionEqual ('a' * 40) $result.repositories[0].default_branch.oid 'default branch OID is preserved'
Assert-CognitionTrue ($result.repositories[0].release_sentinel -match '^sha256:[a-f0-9]{64}$') 'release sentinel is independently fingerprinted'
Assert-CognitionEqual 'none' $result.repositories[1].release_sentinel 'repository without releases has an explicit sentinel'
Assert-CognitionEqual $true $result.repositories[1].remote_only 'repository without a verified canonical clone is remote-only'
Assert-CognitionEqual 1 $result.clone_occurrences.Count 'only origin-verified canonical clones are linked'
Assert-CognitionEqual 'R_repoStable1' $result.clone_occurrences[0].repository_node_id 'clone occurrence links to repository node id'
Assert-CognitionEqual 'X:\private\alpha' $result.clone_occurrences[0].path 'runtime provider preserves canonical private navigation path'
Assert-CognitionTrue (@($result.clone_coverage.gaps.code) -contains 'navigation_repo_not_in_live_inventory') 'stale private navigation entry becomes an exact gap'
Assert-CognitionEqual 'ahead' $result.compare.status 'remote compare status is preserved'
Assert-CognitionEqual 1 $result.compare.changed_files.Count 'remote compare file output is bounded'
Assert-CognitionEqual $true $result.compare.files_truncated 'bounded remote compare reports truncation'
Assert-CognitionTrue (@($result.compare.gaps.code) -contains 'compare_files_truncated') 'remote compare truncation is an exact gap'

$singlePageReader = {
    param($Owner, $Cursor, $PageSize)
    [pscustomobject]@{
        owner_id = $pageOne.owner_id
        nodes = @($pageOne.nodes)
        page_info = [pscustomobject]@{ has_next_page = $false; end_cursor = $null }
    }
}
$sameResult = Invoke-ProjectCognitionSource -Owner 'wlyaaaaa' -RepoRoot $repoRoot `
    -PageReader $singlePageReader `
    -NavigationReader { param($Root) [pscustomobject]@{ status = 'missing'; observed_at = $null; entries = @() } } `
    -OriginReader { param($Path) throw 'must not run' } `
    -CompareReader { param($Name, $Base, $Head, $Limit) throw 'must not run for identical OIDs' } `
    -CompareRepositoryId 'R_repoStable1' -CompareBaseOid ('a' * 40)
Assert-CognitionEqual 'identical' $sameResult.compare.status 'identical OIDs avoid a network compare'
Assert-CognitionEqual 'partial' $sameResult.clone_coverage.status 'missing canonical navigation is an explicit partial coverage state'

$limitResult = Invoke-ProjectCognitionSource -Owner 'wlyaaaaa' -RepoRoot $repoRoot `
    -PageReader { param($Owner, $Cursor, $PageSize) $pageOne } `
    -NavigationReader { param($Root) [pscustomobject]@{ status = 'current'; observed_at = $null; entries = @() } } `
    -OriginReader { param($Path) '' } -MaxPages 1
Assert-CognitionEqual 'partial' $limitResult.coverage.status 'page bound never masquerades as complete coverage'
Assert-CognitionTrue (@($limitResult.coverage.gaps.code) -contains 'pagination_limit_reached') 'page bound has an exact gap'

$mismatchResult = Invoke-ProjectCognitionSource -Owner 'wlyaaaaa' -RepoRoot $repoRoot `
    -PageReader $singlePageReader `
    -NavigationReader { param($Root) [pscustomobject]@{
            status = 'current'; observed_at = $null
            entries = @([pscustomobject]@{ repo = 'wlyaaaaa/alpha'; path = 'X:\private\wrong'; visibility = 'PRIVATE'; default_branch = 'main' })
        } } `
    -OriginReader { param($Path) 'https://github.com/wlyaaaaa/not-alpha.git' }
Assert-CognitionEqual 0 $mismatchResult.clone_occurrences.Count 'origin mismatch never creates a clone link'
Assert-CognitionTrue (@($mismatchResult.clone_coverage.gaps.code) -contains 'navigation_origin_mismatch') 'origin mismatch is an exact gap'

$serializedResult = $result | ConvertTo-Json -Depth 12 -Compress
Assert-CognitionTrue (-not ($serializedResult -match '(?i)ghp_|github_pat_|authorization|bearer')) 'fixture output contains no credential material'

$providerSource = Get-Content -LiteralPath $providerPath -Raw -Encoding utf8
Assert-CognitionTrue (-not ($providerSource -match '(?i)Set-Content|Add-Content|Out-File|WriteAllText|WriteAllBytes|Move-Item|Remove-Item|New-Item')) 'provider contains no filesystem mutation primitive'
Assert-CognitionTrue (-not ($providerSource -match 'Update-GitHubIndex|Refresh-GitHubLocalIndex|ScheduledTask')) 'provider never reuses write-capable refresh or task paths'
Assert-CognitionTrue (-not ($providerSource -match '(?i)[''"][a-z]:\\')) 'provider embeds no local Windows root'

if ($script:failures -gt 0) {
    throw "$script:failures project cognition provider test(s) failed"
}

Write-Host 'Project cognition source provider tests passed.'
