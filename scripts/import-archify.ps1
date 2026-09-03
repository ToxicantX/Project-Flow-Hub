[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')]
    [string]$Slug,

    [Parameter(Mandatory = $true)]
    [string]$SourceDirectory,

    [string]$CoverSource,

    [string]$SourceCommit
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$projectsRoot = Join-Path $repoRoot 'projects'
$projectRoot = Join-Path $projectsRoot $Slug
$manifestPath = Join-Path $projectRoot 'project.json'
$sourceRoot = (Resolve-Path -LiteralPath $SourceDirectory).Path
$sourceManifestPath = Join-Path $sourceRoot 'project-flow.json'
$comparison = if ($env:OS -eq 'Windows_NT') {
    [StringComparison]::OrdinalIgnoreCase
} else {
    [StringComparison]::Ordinal
}

function Get-ContainedPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Field,
        [switch]$MustExist
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath)) {
        throw "$Field must be a non-empty relative path"
    }
    $rootPath = [IO.Path]::GetFullPath($Root)
    $rootPrefix = $rootPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootPath $RelativePath))
    if (-not $candidate.StartsWith($rootPrefix, $comparison)) {
        throw "$Field must stay inside $rootPath"
    }
    if ($MustExist -and -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "$Field not found: $candidate"
    }
    return $candidate
}

function Set-ObjectProperty {
    param([object]$Object, [string]$Name, [object]$Value)

    if ($Object.PSObject.Properties.Name -contains $Name) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

$manifestInput = if (Test-Path -LiteralPath $sourceManifestPath -PathType Leaf) {
    $sourceManifestPath
} elseif (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    $manifestPath
} else {
    throw "Project manifest not found in source or Hub: $sourceManifestPath"
}
$manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestInput | ConvertFrom-Json
if ($manifest.slug -ne $Slug) {
    throw "Source manifest slug '$($manifest.slug)' does not match '$Slug'"
}
if (-not @($manifest.flows).Count) {
    throw "${Slug}: flows cannot be empty"
}

$copyPlan = [Collections.Generic.List[object]]::new()
$targetPaths = [Collections.Generic.HashSet[string]]::new(
    $(if ($env:OS -eq 'Windows_NT') { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal })
)

foreach ($flow in @($manifest.flows)) {
    $sourceFile = if ($flow.PSObject.Properties.Name -contains 'sourceFile' -and $flow.sourceFile) {
        [string]$flow.sourceFile
    } else {
        Split-Path -Leaf ([string]$flow.file)
    }
    $sourceSpec = if ($flow.PSObject.Properties.Name -contains 'sourceSpec' -and $flow.sourceSpec) {
        [string]$flow.sourceSpec
    } else {
        Split-Path -Leaf ([string]$flow.spec)
    }
    $sourceHtmlPath = Get-ContainedPath -Root $sourceRoot -RelativePath $sourceFile -Field "$Slug.$($flow.id).sourceFile" -MustExist
    $sourceSpecPath = Get-ContainedPath -Root $sourceRoot -RelativePath $sourceSpec -Field "$Slug.$($flow.id).sourceSpec" -MustExist
    $null = Get-ContainedPath -Root $projectRoot -RelativePath ([string]$flow.file) -Field "$Slug.$($flow.id).file"
    $null = Get-ContainedPath -Root $projectRoot -RelativePath ([string]$flow.spec) -Field "$Slug.$($flow.id).spec"
    foreach ($target in @([string]$flow.file, [string]$flow.spec)) {
        if (-not $targetPaths.Add($target.Replace('\', '/'))) {
            throw "${Slug}: duplicate target path $target"
        }
    }
    $html = Get-Content -Raw -Encoding UTF8 -LiteralPath $sourceHtmlPath
    if (-not $html.Contains('name="generator" content="archify')) {
        throw "$Slug.$($flow.id): source HTML is not an Archify delivery"
    }
    try {
        Get-Content -Raw -Encoding UTF8 -LiteralPath $sourceSpecPath | ConvertFrom-Json | Out-Null
    } catch {
        throw "$Slug.$($flow.id): source JSON spec is invalid: $($_.Exception.Message)"
    }
    $copyPlan.Add([pscustomobject]@{ Source = $sourceHtmlPath; Target = [string]$flow.file })
    $copyPlan.Add([pscustomobject]@{ Source = $sourceSpecPath; Target = [string]$flow.spec })
}

$configuredCover = if ($manifest.PSObject.Properties.Name -contains 'source' -and
    $manifest.source -and $manifest.source.PSObject.Properties.Name -contains 'cover' -and $manifest.source.cover) {
    [string]$manifest.source.cover
} else {
    Split-Path -Leaf ([string]$manifest.cover)
}
$coverName = if ($CoverSource) { $CoverSource } else { $configuredCover }
$coverSourcePath = Get-ContainedPath -Root $sourceRoot -RelativePath $coverName -Field "$Slug.source.cover" -MustExist
$null = Get-ContainedPath -Root $projectRoot -RelativePath ([string]$manifest.cover) -Field "$Slug.cover"
if (-not $targetPaths.Add(([string]$manifest.cover).Replace('\', '/'))) {
    throw "${Slug}: duplicate target path $($manifest.cover)"
}
$copyPlan.Add([pscustomobject]@{ Source = $coverSourcePath; Target = [string]$manifest.cover })

$token = [guid]::NewGuid().ToString('N')
$stagingRoot = Join-Path $projectsRoot ".$Slug.import-$token"
$backupRoot = Join-Path $projectsRoot ".$Slug.backup-$token"
New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null

try {
    foreach ($item in $copyPlan) {
        $targetPath = Get-ContainedPath -Root $stagingRoot -RelativePath $item.Target -Field "$Slug.importTarget"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $targetPath) | Out-Null
        Copy-Item -LiteralPath $item.Source -Destination $targetPath -Force
    }

    Set-ObjectProperty -Object $manifest -Name 'updated' -Value (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
    if ($SourceCommit) {
        $hashLines = foreach ($item in $copyPlan | Sort-Object Target) {
            $targetPath = Get-ContainedPath -Root $stagingRoot -RelativePath $item.Target -Field "$Slug.hashTarget" -MustExist
            "{0}`t{1}" -f $item.Target.Replace('\', '/'), (Get-FileHash -Algorithm SHA256 -LiteralPath $targetPath).Hash.ToLowerInvariant()
        }
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            $hashBytes = [Text.Encoding]::UTF8.GetBytes(($hashLines -join "`n"))
            $artifactHash = ([BitConverter]::ToString($sha256.ComputeHash($hashBytes))).Replace('-', '').ToLowerInvariant()
        } finally {
            $sha256.Dispose()
        }
        Set-ObjectProperty -Object $manifest -Name 'provenance' -Value ([pscustomobject]@{
            commit = $SourceCommit
            artifactHash = $artifactHash
        })
    }

    $json = $manifest | ConvertTo-Json -Depth 30
    [IO.File]::WriteAllText((Join-Path $stagingRoot 'project.json'), $json + "`n", (New-Object Text.UTF8Encoding($false)))

    $hadExisting = Test-Path -LiteralPath $projectRoot
    if ($hadExisting) {
        Move-Item -LiteralPath $projectRoot -Destination $backupRoot
    }
    try {
        Move-Item -LiteralPath $stagingRoot -Destination $projectRoot
    } catch {
        if ($hadExisting -and (Test-Path -LiteralPath $backupRoot) -and -not (Test-Path -LiteralPath $projectRoot)) {
            Move-Item -LiteralPath $backupRoot -Destination $projectRoot
        }
        throw
    }
    if (Test-Path -LiteralPath $backupRoot) {
        Remove-Item -LiteralPath $backupRoot -Recurse -Force
    }
} finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}

Write-Host "Imported $($copyPlan.Count) artifacts for $Slug."
