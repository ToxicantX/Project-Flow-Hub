[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')]
    [string]$Slug,

    [Parameter(Mandatory = $true)]
    [string]$SourceDirectory,

    [string]$CoverSource,

    [switch]$NoPush
)

$ErrorActionPreference = 'Stop'
$hubRoot = Split-Path -Parent $PSScriptRoot
$sourceRoot = (Resolve-Path -LiteralPath $SourceDirectory).Path
$worktree = Join-Path $env:TEMP ('project-flow-hub-sync-' + [guid]::NewGuid().ToString('N'))

# Git exports repository-local variables to hooks. They must not leak into
# commands targeting the independent Hub repository.
$gitLocalVariables = @(git rev-parse --local-env-vars 2>$null)
foreach ($name in $gitLocalVariables | Where-Object { $_ }) {
    Remove-Item "Env:$name" -ErrorAction SilentlyContinue
}

function Invoke-Checked {
    param([scriptblock]$Command, [string]$FailureMessage)
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw $FailureMessage
    }
}
Invoke-Checked { git -C $hubRoot fetch origin main } 'Unable to fetch Project-Flow-Hub main'
Invoke-Checked { git -C $hubRoot worktree add --detach $worktree origin/main } 'Unable to create sync worktree'

try {
    $importArguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $worktree 'scripts\import-archify.ps1'),
        '-Slug', $Slug,
        '-SourceDirectory', $sourceRoot
    )
    if ($CoverSource) {
        $importArguments += @('-CoverSource', $CoverSource)
    }
    Invoke-Checked { powershell.exe @importArguments } 'Archify artifact import failed'

    git -C $worktree diff --quiet -- "projects/$Slug"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "No flow changes detected for $Slug."
        return
    }
    if ($LASTEXITCODE -ne 1) {
        throw 'Unable to inspect imported project changes'
    }

    $manifestPath = Join-Path $worktree "projects\$Slug\project.json"
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
    $manifest.updated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
    $json = $manifest | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($manifestPath, $json + "`n", (New-Object Text.UTF8Encoding($false)))

    Invoke-Checked { npm --prefix $worktree test } 'Project-Flow-Hub tests failed'
    Invoke-Checked { npm --prefix $worktree run build } 'Project-Flow-Hub build failed'

    if ($NoPush) {
        Write-Host "Sync validation passed for $Slug; push skipped."
        return
    }

    $sourceCommit = git -C (Split-Path -Parent $sourceRoot) rev-parse --short HEAD 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $sourceCommit) {
        $sourceCommit = 'working-tree'
    }
    Invoke-Checked { git -C $worktree add -- "projects/$Slug" } 'Unable to stage synchronized flows'
    Invoke-Checked {
        git -C $worktree -c user.name='project-flow-sync' -c user.email='project-flow-sync@users.noreply.github.com' commit -m "chore($Slug): sync flows from $sourceCommit"
    } 'Unable to commit synchronized flows'
    Invoke-Checked { git -C $worktree push origin HEAD:main } 'Unable to push synchronized flows'
    Write-Host "Synchronized $Slug from $sourceCommit."
}
finally {
    $tempRoot = [IO.Path]::GetFullPath($env:TEMP) + [IO.Path]::DirectorySeparatorChar
    $resolvedWorktree = [IO.Path]::GetFullPath($worktree)
    if ($resolvedWorktree.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        git -C $hubRoot worktree remove --force $resolvedWorktree 2>$null
        git -C $hubRoot worktree prune 2>$null
    }
}
