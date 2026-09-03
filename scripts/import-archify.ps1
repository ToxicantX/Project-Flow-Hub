[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')]
    [string]$Slug,

    [Parameter(Mandatory = $true)]
    [string]$SourceDirectory,

    [string]$CoverSource
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$projectRoot = Join-Path $repoRoot "projects\$Slug"
$manifestPath = Join-Path $projectRoot 'project.json'

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Project manifest not found: $manifestPath"
}

$sourceRoot = (Resolve-Path -LiteralPath $SourceDirectory).Path
$manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
$files = @($manifest.flows | ForEach-Object { $_.file; $_.spec })

foreach ($relativePath in $files | Where-Object { $_ } | Select-Object -Unique) {
    $sourcePath = Join-Path $sourceRoot (Split-Path -Leaf $relativePath)
    $targetPath = Join-Path $projectRoot $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Source artifact not found: $sourcePath"
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $targetPath) | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Force
}

$coverName = if ($CoverSource) { $CoverSource } else { Split-Path -Leaf $manifest.cover }
$coverSourcePath = Join-Path $sourceRoot $coverName
$coverTargetPath = Join-Path $projectRoot $manifest.cover
if (-not (Test-Path -LiteralPath $coverSourcePath -PathType Leaf)) {
    throw "Source cover not found: $coverSourcePath"
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $coverTargetPath) | Out-Null
Copy-Item -LiteralPath $coverSourcePath -Destination $coverTargetPath -Force

Write-Host "Imported $($files.Count + 1) artifacts for $Slug."
