[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRepository,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')]
    [string]$Slug,

    [string]$DiagramsDirectory = 'diagrams',

    [string]$CoverSource
)

$ErrorActionPreference = 'Stop'
$hubRoot = Split-Path -Parent $PSScriptRoot
$sourceRoot = (Resolve-Path -LiteralPath $SourceRepository).Path
$watchPath = $DiagramsDirectory.Replace('\', '/').Trim('/')
if ([IO.Path]::IsPathRooted($DiagramsDirectory) -or $watchPath.Split('/') -contains '..' -or -not $watchPath) {
    throw 'DiagramsDirectory must stay inside the source repository'
}
$sourceDiagrams = (Resolve-Path -LiteralPath (Join-Path $sourceRoot $DiagramsDirectory)).Path
$sourcePrefix = $sourceDiagrams.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if ($CoverSource) {
    if ([IO.Path]::IsPathRooted($CoverSource)) {
        throw 'CoverSource must stay inside the diagrams directory'
    }
    $resolvedCover = [IO.Path]::GetFullPath((Join-Path $sourceDiagrams $CoverSource))
    if (-not $resolvedCover.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'CoverSource must stay inside the diagrams directory'
    }
}
$gitDirectory = git -C $sourceRoot rev-parse --git-dir
if ($LASTEXITCODE -ne 0 -or -not $gitDirectory) {
    throw "Not a Git repository: $sourceRoot"
}
if (-not [IO.Path]::IsPathRooted($gitDirectory)) {
    $gitDirectory = Join-Path $sourceRoot $gitDirectory
}

$hookPath = Join-Path (Join-Path $gitDirectory 'hooks') 'post-commit'
$marker = '# project-flow-hub managed hook'
if (Test-Path -LiteralPath $hookPath -PathType Leaf) {
    $existing = Get-Content -Raw -LiteralPath $hookPath
    if (-not $existing.Contains($marker)) {
        throw "Existing post-commit hook is not managed by Project-Flow-Hub: $hookPath"
    }
}

$syncScript = (Join-Path (Join-Path $hubRoot 'scripts') 'sync-project.ps1').Replace('\', '/')
$diagramsPath = $sourceDiagrams.Replace('\', '/')
$escapedSyncScript = $syncScript.Replace('\', '\\').Replace('"', '\"').Replace('$', '\$').Replace('`', '\`')
$escapedDiagramsPath = $diagramsPath.Replace('\', '\\').Replace('"', '\"').Replace('$', '\$').Replace('`', '\`')
$escapedWatchPath = $watchPath.Replace('\', '\\').Replace('"', '\"').Replace('$', '\$').Replace('`', '\`')
$escapedCover = if ($CoverSource) { $CoverSource.Replace('\', '/').Replace('"', '\"').Replace('$', '\$').Replace('`', '\`') } else { '' }
$coverArgument = if ($CoverSource) { " -CoverSource `"$escapedCover`"" } else { '' }
$template = @'
#!/bin/sh
# project-flow-hub managed hook
changed="$(git diff-tree --root --no-commit-id --name-only -r HEAD -- "__WATCH_PATH__/")"
if [ -z "$changed" ]; then
  exit 0
fi

failure_marker="$(git rev-parse --git-dir)/project-flow-hub-sync.failed"
if powershell.exe -NoProfile -ExecutionPolicy Bypass -File "__SYNC_SCRIPT__" -Slug "__SLUG__" -SourceDirectory "__DIAGRAMS_PATH__"__COVER_ARGUMENT__; then
  rm -f "$failure_marker"
else
  printf '%s\n' "Project-Flow-Hub synchronization failed. Re-run the commit or invoke sync-project.ps1 manually." > "$failure_marker"
  echo "Project-Flow-Hub synchronization failed; see $failure_marker" >&2
  exit 1
fi
'@
$content = $template.Replace('__SYNC_SCRIPT__', $escapedSyncScript).Replace('__SLUG__', $Slug).Replace('__DIAGRAMS_PATH__', $escapedDiagramsPath).Replace('__WATCH_PATH__', $escapedWatchPath).Replace('__COVER_ARGUMENT__', $coverArgument)
$content = $content.Replace("`r`n", "`n")
[IO.File]::WriteAllText($hookPath, $content, (New-Object Text.UTF8Encoding($false)))

Write-Host "Installed Project-Flow-Hub hook: $hookPath"
