[CmdletBinding()]
param(
    [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')]
    [string]$Slug,

    [switch]$NoPush
)

$ErrorActionPreference = 'Stop'
$hubRoot = Split-Path -Parent $PSScriptRoot
$projectsRoot = Join-Path $hubRoot 'projects'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('project-flow-hub-remotes-' + [guid]::NewGuid().ToString('N'))

function Invoke-Checked {
    param([scriptblock]$Command, [string]$FailureMessage)

    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw $FailureMessage
    }
}

function Get-ContainedDirectory {
    param([string]$Root, [string]$RelativePath, [string]$Field)

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath)) {
        throw "$Field must be a non-empty relative path"
    }
    $rootPath = [IO.Path]::GetFullPath($Root)
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootPath $RelativePath))
    $prefix = $rootPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $comparison = if ($env:OS -eq 'Windows_NT') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $candidate.StartsWith($prefix, $comparison) -or -not (Test-Path -LiteralPath $candidate -PathType Container)) {
        throw "$Field must stay inside the cloned repository"
    }
    return $candidate
}

New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
try {
    $manifests = @(Get-ChildItem -LiteralPath $projectsRoot -Directory |
        Where-Object { -not $_.Name.StartsWith('_') } |
        ForEach-Object { Join-Path $_.FullName 'project.json' })
    $selected = 0
    foreach ($manifestPath in $manifests) {
        $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
        if ($Slug -and $manifest.slug -ne $Slug) {
            continue
        }
        if (-not $manifest.source -or $manifest.source.mode -ne 'remote') {
            continue
        }
        $selected++
        $repository = [string]$manifest.source.repository
        $ref = [string]$manifest.source.ref
        $directory = [string]$manifest.source.directory
        if ($repository -notmatch '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?$') {
            throw "$($manifest.slug): remote source must be a public GitHub HTTPS repository"
        }
        if ($ref -notmatch '^[A-Za-z0-9._/-]+$' -or $ref.Contains('..')) {
            throw "$($manifest.slug): invalid source ref"
        }

        $cloneRoot = Join-Path $tempRoot ([string]$manifest.slug)
        Invoke-Checked { git clone --quiet --depth 1 --branch $ref --single-branch $repository $cloneRoot } "Unable to clone $repository@$ref"
        $sourceDirectory = Get-ContainedDirectory -Root $cloneRoot -RelativePath $directory -Field "$($manifest.slug).source.directory"
        if (-not (Test-Path -LiteralPath (Join-Path $sourceDirectory 'project-flow.json') -PathType Leaf)) {
            throw "$($manifest.slug): project-flow.json is missing from the remote source directory"
        }
        $sourceCommit = (git -C $cloneRoot rev-parse HEAD).Trim()
        & (Join-Path $PSScriptRoot 'import-archify.ps1') -Slug $manifest.slug -SourceDirectory $sourceDirectory -SourceCommit $sourceCommit
    }
    if ($Slug -and $selected -eq 0) {
        throw "No remote project matched slug: $Slug"
    }

    $changes = @(git -C $hubRoot status --porcelain -- projects)
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to inspect synchronized projects'
    }
    if (-not $changes.Count) {
        if ($env:GITHUB_OUTPUT) { Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value 'changed=false' }
        Write-Host 'No remote project flow changes detected.'
        return
    }

    Invoke-Checked { npm --prefix $hubRoot test } 'Project-Flow-Hub tests failed'
    Invoke-Checked { npm --prefix $hubRoot run build } 'Project-Flow-Hub build failed'
    if ($NoPush) {
        Write-Host 'Remote synchronization validation passed; push skipped.'
        return
    }

    Invoke-Checked { git -C $hubRoot add -- projects } 'Unable to stage synchronized projects'
    Invoke-Checked {
        git -C $hubRoot -c user.name='project-flow-sync' -c user.email='project-flow-sync@users.noreply.github.com' commit -m 'chore: sync remote project flows'
    } 'Unable to commit synchronized projects'

    $pushed = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        git -C $hubRoot push origin HEAD:main
        if ($LASTEXITCODE -eq 0) {
            $pushed = $true
            break
        }
        if ($attempt -eq 3) { break }
        Invoke-Checked { git -C $hubRoot fetch origin main } 'Unable to fetch Hub main after a push conflict'
        git -C $hubRoot rebase origin/main
        if ($LASTEXITCODE -ne 0) {
            git -C $hubRoot rebase --abort 2>$null
            throw 'Unable to rebase remote project synchronization onto Hub main'
        }
        Invoke-Checked { npm --prefix $hubRoot test } 'Project-Flow-Hub tests failed after rebase'
        Invoke-Checked { npm --prefix $hubRoot run build } 'Project-Flow-Hub build failed after rebase'
    }
    if (-not $pushed) {
        throw 'Unable to push remote project synchronization after 3 attempts'
    }
    $commit = (git -C $hubRoot rev-parse HEAD).Trim()
    if ($env:GITHUB_OUTPUT) {
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value 'changed=true'
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "commit=$commit"
    }
    Write-Host "Synchronized remote projects in $commit."
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
