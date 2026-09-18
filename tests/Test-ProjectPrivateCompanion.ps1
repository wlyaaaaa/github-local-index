#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tools/Get-ProjectPrivateCompanion.ps1') -Repo example/source
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('companion-' + [guid]::NewGuid().ToString('N'))
function Assert-Companion($Condition, $Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    Write-Host "PASS: $Name"
}
function Write-TestJson($Path, $Value) { $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding utf8 }
function Read-Companion { Get-ProjectPrivateCompanion -Repo example/source -RepoPath $source -IndexRoot $index }
try {
    $source = Join-Path $testRoot 'source'; $target = Join-Path $testRoot 'target'; $index = Join-Path $testRoot 'index'
    $registryDir = Join-Path $index '99_private/registries'
    $null = New-Item -ItemType Directory -Path $source, $target, $registryDir -Force
    foreach ($path in @($source, $target)) {
        & git -C $path init -q
        & git -C $path config user.name Fixture
        & git -C $path config user.email fixture@example.invalid
    }
    & git -C $source remote add origin https://github.com/example/source.git
    & git -C $target remote add origin https://github.com/example/companion.git
    Assert-Companion ((Read-Companion).status -eq 'unregistered') 'absent registry is optional'
    $registryPath = Join-Path $registryDir 'public-project-private-companion.json'
    Write-TestJson $registryPath @{ schema='github-local-index.public-project-private-companion.v1'; target_id='fixture'; repository='example/companion'; local_path=$target; visibility='PRIVATE'; catalog='catalog.json' }
    $catalogPath = Join-Path $target 'catalog.json'
    Write-TestJson $catalogPath @{ schema='public-project-private-backup.catalog.v1'; target_id='fixture'; sources=@() }
    $r = Read-Companion
    Assert-Companion ($r.status -eq 'registered_unmapped' -and $r.registered_target.repository -eq 'example/companion') 'unmapped source exposes registered planning target'
    $prefix = 'projects/example/source'
    $prefixPath = Join-Path $target $prefix
    $null = New-Item -ItemType Directory -Path (Join-Path $prefixPath 'files') -Force
    $document = Join-Path $prefixPath 'files/note.md'
    Set-Content $document 'fixture private body'
    Write-TestJson $catalogPath @{ schema='public-project-private-backup.catalog.v1'; target_id='fixture'; sources=@(@{source_repository='example/source'; prefix=$prefix; manifest="$prefix/manifest.json"}) }
    Write-TestJson (Join-Path $prefixPath 'manifest.json') @{schema='public-project-private-backup.manifest.v1'; source_repository='example/source'; files=@(@{source_relative_path='note.md'; target_relative_path='files/note.md'; sha256=(Get-FileHash $document).Hash})}
    & git -C $target add -- catalog.json projects
    & git -C $target commit -qm fixture
    $r = Read-Companion
    Assert-Companion ($r.status -eq 'mapped' -and $r.files.Count -eq 1 -and $r.files[0].source_status -eq 'missing') 'catalog discovers mapping without local config'
    Assert-Companion ($r.files[0].manifest_hash_status -eq 'match' -and $r.registered_target.dirty -eq $false) 'matching manifest and clean target'
    Assert-Companion ($r.requires_live_revalidation_before_write -and $r.registered_target.live_visibility -eq 'unknown') 'cached private metadata never grants writes'
    Assert-Companion (($r | ConvertTo-Json -Depth 8) -notmatch 'fixture private body') 'provider does not return document body'
    $null = New-Item -ItemType SymbolicLink -Path (Join-Path $source 'note.md') -Target $document
    Assert-Companion ((Read-Companion).files[0].source_status -eq 'linked') 'source link resolves to exact target'
    Set-Content $document 'changed'
    $r = Read-Companion
    Assert-Companion ($r.files[0].manifest_hash_status -eq 'drift' -and $r.registered_target.dirty) 'dirty target and manifest hash drift are visible'
    Move-Item -LiteralPath $document -Destination ($document + '.moved')
    Assert-Companion ((Read-Companion).files[0].source_status -eq 'broken_link') 'broken source link is visible'
    & git -C $source config codex.private-backup-prefix wrong/prefix
    Assert-Companion ((Read-Companion).issues -contains 'source_config_conflict') 'conflicting local pointer is explicit'
    & git -C $source config --unset codex.private-backup-prefix
    & git -C $target remote set-url origin https://github.com/example/wrong.git
    Assert-Companion ((Read-Companion).issues -contains 'target_identity_mismatch') 'target identity mismatch rejects catalog'
    & git -C $target remote set-url origin https://github.com/example/companion.git
    & git -C $source config codex.private-backup-repository example/other
    Assert-Companion ((Read-Companion).issues -contains 'source_config_conflict') 'conflicting target repository pointer is explicit'
    & git -C $source config --unset codex.private-backup-repository
    $admissionJson = & pwsh -NoProfile -File (Join-Path $root 'tools/Get-ProjectAdmission.ps1') -Repo example/source -RepoPath $source -IndexRoot $index -Visibility PUBLIC -DefaultBranch main -Json
    $admission = $admissionJson | ConvertFrom-Json
    Assert-Companion ($admission.private_companion.status -eq 'mapped') 'admission attaches companion facts'
    $decision = $admission.decision
    Set-Content -LiteralPath $registryPath '{invalid'
    $admission = (& pwsh -NoProfile -File (Join-Path $root 'tools/Get-ProjectAdmission.ps1') -Repo example/source -RepoPath $source -IndexRoot $index -Visibility PUBLIC -DefaultBranch main -Json) | ConvertFrom-Json
    Assert-Companion ($admission.decision -eq $decision -and $admission.private_companion.status -eq 'unavailable') 'malformed companion metadata does not block unrelated admission'
    Write-TestJson $registryPath @{ schema='github-local-index.public-project-private-companion.v1'; target_id='fixture'; repository='example/companion'; local_path=$target; visibility='PRIVATE'; catalog='catalog.json' }
    $originalGitReader = (Get-Command Invoke-GitCommandResult).ScriptBlock
    $script:failedGitPath = $target
    function Invoke-GitCommandResult {
        param([string]$Path,[string[]]$Arguments)
        if ($Path -eq $script:failedGitPath) { return [pscustomobject]@{exit_code=128;stdout='';stderr='synthetic unavailable Git read'} }
        return & $originalGitReader -Path $Path -Arguments $Arguments
    }
    try {
        $r=Read-Companion
        Assert-Companion ($r.status-eq 'unavailable' -and $r.issues-contains 'target_git_read_failed' -and $r.issues-notcontains 'target_identity_mismatch') 'failed target Git read remains unknown, not conflicting identity'
        $script:failedGitPath=$source
        $r=Read-Companion
        Assert-Companion ($r.status-eq 'unavailable' -and $r.issues-contains 'source_git_read_failed' -and $r.issues-notcontains 'source_identity_mismatch') 'failed source Git read remains unknown, not conflicting identity'
    } finally { Set-Item Function:\Invoke-GitCommandResult $originalGitReader }
    & git -C $source remote set-url origin https://github.com/example/wrong.git
    Assert-Companion ((Read-Companion).issues -contains 'source_identity_mismatch') 'source identity mismatch rejects mapping'
}
finally {
    $full = [IO.Path]::GetFullPath($testRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $full.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected fixture root' }
    Remove-Item -LiteralPath $full -Recurse -Force
}
