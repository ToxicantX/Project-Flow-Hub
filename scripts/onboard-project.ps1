[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRepository,

    [string]$DiagramsDirectory = 'diagrams'
)

$ErrorActionPreference = 'Stop'
$hubRoot = Split-Path -Parent $PSScriptRoot
$sourceRoot = (Resolve-Path -LiteralPath $SourceRepository).Path
$diagramsRoot = (Resolve-Path -LiteralPath (Join-Path $sourceRoot $DiagramsDirectory)).Path
$sourceManifest = Join-Path $diagramsRoot 'project-flow.json'

if (-not (Test-Path -LiteralPath $sourceManifest -PathType Leaf)) {
    throw "Source manifest not found: $sourceManifest"
}
$manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $sourceManifest | ConvertFrom-Json
$slug = [string]$manifest.slug
if ($slug -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
    throw "Invalid project slug: $slug"
}

$repositoryRoot = git -C $sourceRoot rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0 -or -not $repositoryRoot) {
    throw "Not a Git repository: $sourceRoot"
}
$sourceCommit = git -C $repositoryRoot rev-parse HEAD 2>$null
if ($LASTEXITCODE -ne 0 -or -not $sourceCommit) {
    $sourceCommit = 'working-tree'
}

& (Join-Path $PSScriptRoot 'import-archify.ps1') -Slug $slug -SourceDirectory $diagramsRoot -SourceCommit $sourceCommit.Trim()

npm --prefix $hubRoot test
if ($LASTEXITCODE -ne 0) {
    throw 'Project-Flow-Hub tests failed'
}
npm --prefix $hubRoot run build
if ($LASTEXITCODE -ne 0) {
    throw 'Project-Flow-Hub build failed'
}

$remoteHead = @(git -C $sourceRoot ls-remote --symref origin HEAD 2>$null)
$mode = if ($manifest.source -and $manifest.source.mode) { [string]$manifest.source.mode } else { 'local' }
if ($mode -eq 'local' -or $LASTEXITCODE -ne 0 -or -not ($remoteHead -match '^ref: refs/heads/')) {
    & (Join-Path $PSScriptRoot 'install-local-hook.ps1') -SourceRepository $sourceRoot -Slug $slug -DiagramsDirectory $DiagramsDirectory
    Write-Host "Onboarded $slug with local post-commit synchronization."
} else {
    Write-Host "Onboarded $slug for remote synchronization from $($manifest.source.repository)@$($manifest.source.ref)."
}

Write-Host 'Review and commit the Hub project changes when ready.'
