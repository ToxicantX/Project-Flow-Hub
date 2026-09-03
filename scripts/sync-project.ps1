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
$systemTemp = [IO.Path]::GetTempPath()
$worktree = Join-Path $systemTemp ('project-flow-hub-sync-' + [guid]::NewGuid().ToString('N'))
$powerShellHost = if ($env:OS -eq 'Windows_NT') { 'powershell.exe' } else { 'pwsh' }

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

$sourceRepository = git -C $sourceRoot rev-parse --show-toplevel 2>$null
$sourceCommit = if ($LASTEXITCODE -eq 0 -and $sourceRepository) {
    git -C $sourceRepository rev-parse HEAD 2>$null
} else {
    $null
}
if ($LASTEXITCODE -ne 0 -or -not $sourceCommit) {
    $sourceCommit = 'working-tree'
}
$sourceCommit = $sourceCommit.Trim()

Invoke-Checked { git -C $hubRoot fetch origin main } 'Unable to fetch Project-Flow-Hub main'
Invoke-Checked { git -C $hubRoot worktree add --detach $worktree origin/main } 'Unable to create sync worktree'

try {
    $importArguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path (Join-Path $worktree 'scripts') 'import-archify.ps1'),
        '-Slug', $Slug,
        '-SourceDirectory', $sourceRoot,
        '-SourceCommit', $sourceCommit
    )
    if ($CoverSource) {
        $importArguments += @('-CoverSource', $CoverSource)
    }
    Invoke-Checked { & $powerShellHost @importArguments } 'Archify artifact import failed'

    $changes = @(git -C $worktree status --porcelain -- "projects/$Slug")
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to inspect imported project changes'
    }
    if (-not $changes.Count) {
        Write-Host "No flow changes detected for $Slug."
        return
    }

    Invoke-Checked { npm --prefix $worktree test } 'Project-Flow-Hub tests failed'
    Invoke-Checked { npm --prefix $worktree run build } 'Project-Flow-Hub build failed'

    if ($NoPush) {
        Write-Host "Sync validation passed for $Slug; push skipped."
        return
    }

    Invoke-Checked { git -C $worktree add -- "projects/$Slug" } 'Unable to stage synchronized flows'
    $shortCommit = if ($sourceCommit -eq 'working-tree') { $sourceCommit } else { $sourceCommit.Substring(0, [Math]::Min(12, $sourceCommit.Length)) }
    Invoke-Checked {
        git -C $worktree -c user.name='project-flow-sync' -c user.email='project-flow-sync@users.noreply.github.com' commit -m "chore($Slug): sync flows from $shortCommit"
    } 'Unable to commit synchronized flows'

    $pushed = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        git -C $worktree push origin HEAD:main
        if ($LASTEXITCODE -eq 0) {
            $pushed = $true
            break
        }
        if ($attempt -eq 3) {
            break
        }
        Invoke-Checked { git -C $worktree fetch origin main } 'Unable to refresh Project-Flow-Hub main after a push conflict'
        git -C $worktree rebase origin/main
        if ($LASTEXITCODE -ne 0) {
            git -C $worktree rebase --abort 2>$null
            throw 'Unable to rebase synchronized flows onto the latest Project-Flow-Hub main'
        }
        Invoke-Checked { npm --prefix $worktree test } 'Project-Flow-Hub tests failed after rebase'
        Invoke-Checked { npm --prefix $worktree run build } 'Project-Flow-Hub build failed after rebase'
    }
    if (-not $pushed) {
        throw 'Unable to push synchronized flows after 3 attempts'
    }
    Write-Host "Synchronized $Slug from $shortCommit."
} finally {
    $tempRoot = [IO.Path]::GetFullPath($systemTemp).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $resolvedWorktree = [IO.Path]::GetFullPath($worktree)
    if ($resolvedWorktree.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        git -C $hubRoot worktree remove --force $resolvedWorktree 2>$null
        git -C $hubRoot worktree prune 2>$null
    }
}
