<#
.SYNOPSIS
    Marks a build as a release candidate or as the release (user's workflow, 2026-09-30).

.DESCRIPTION
    Builds after a release are the next version's builds (the version in pubspec.yaml, e.g. 1.2.0). A few of them
    become release candidates; one becomes the release; the build after that is the first build of the next version.

      release.ps1 -Rc 1              tag the newest build v1.2.0-rc.1 (or -Build 52 for another one)
      release.ps1 -Final             tag the newest build v1.2.0, then move pubspec.yaml on to 1.3.0 so the next
                                     build is the first 1.3.0 build

    Both note it in CHANGELOG.md (the version's section) and commit that. Nothing is pushed: pushing the tag and
    main to GitHub, and publishing a GitHub release, stay separate steps.
#>
[CmdletBinding()]
param(
    [int]$Rc = 0,            # release candidate number
    [switch]$Final,          # the release itself
    [int]$Build = 0          # which build (default: the newest build-<n> tag)
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Git([string]$gitArgs) {
    $out = cmd /c "git $gitArgs 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "git $gitArgs failed: $out" }
    return $out
}

if (($Rc -gt 0) -eq [bool]$Final) { throw 'Say either -Rc <n> or -Final.' }
if ("$(Git 'status --porcelain')".Trim()) { throw 'The working tree has uncommitted changes - commit them first.' }

# the build: its tag, and the version it was built as (from pubspec.yaml at that commit)
if ($Build -eq 0) {
    $Build = (Git 'tag -l build-*' | ForEach-Object { [int]($_ -replace 'build-', '') } | Measure-Object -Maximum).Maximum
}
$buildTag = "build-$Build"
$commit = (Git "rev-list -n1 $buildTag").Trim()
$pubspecThen = Git "show ${commit}:komga_reader/pubspec.yaml"
$m = [regex]::Match(($pubspecThen -join "`n"), '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)')
if (-not $m.Success) { throw "No version line in pubspec.yaml at $buildTag" }
$name = "$($m.Groups[1].Value).$($m.Groups[2].Value).$($m.Groups[3].Value)"
$tag = if ($Final) { "v$name" } else { "v$name-rc.$Rc" }
if ((Git "tag -l $tag")) { throw "$tag already exists." }

$date = Get-Date -Format 'yyyy-MM-dd'
$message = if ($Final) { "$name (build $Build) - release" } else { "$name release candidate $Rc (build $Build)" }
Git "tag -a $tag $commit -m `"$message`"" | Out-Null
Write-Host "tagged $tag -> $buildTag ($($commit.Substring(0, 7)))"

# CHANGELOG: the version's section says which builds are candidates / the release
$clPath = Join-Path $root 'CHANGELOG.md'
$cl = [IO.File]::ReadAllText($clPath)
$sec = [regex]::Match($cl, "(?m)^## $([regex]::Escape($name))\b[^\n]*\n\n([^\n#][^\n]*(\n[^\n#][^\n]*)*)?")
if (-not $sec.Success) { throw "No '## $name' section in CHANGELOG.md" }
$candidates = @(Git "tag -l v$name-rc.*" | Sort-Object { [int]($_ -replace '.*-rc\.', '') } |
    ForEach-Object { "build $([int]((Git "describe --tags --match build-* $_") -replace '^build-(\d+).*', '$1')) (``$_``)" })
$rcText = if ($candidates.Count) { "Release candidates: $($candidates -join ', ')." } else { 'No release candidates.' }
$note = if ($Final) {
    "## $name`n`n**Released as build $Build, tagged ``v$name``** ($date). $rcText"
} else {
    "## $name - in development`n`nNot released yet. $rcText"
}
$cl = $cl.Substring(0, $sec.Index) + $note + $cl.Substring($sec.Index + $sec.Length)
[IO.File]::WriteAllText($clPath, $cl)
Copy-Item $clPath (Join-Path $root 'komga_reader\assets\docs\CHANGELOG.md') -Force

$files = 'CHANGELOG.md komga_reader/assets/docs/CHANGELOG.md'
if ($Final) {
    # the next build is the first build of the next version
    $pub = Join-Path $root 'komga_reader\pubspec.yaml'
    $text = [IO.File]::ReadAllText($pub)
    $now = [regex]::Match($text, '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)')
    $next = "$($now.Groups[1].Value).$([int]$now.Groups[2].Value + 1).0"
    $text = $text.Substring(0, $now.Index) + "version: $next+$($now.Groups[4].Value)" + $text.Substring($now.Index + $now.Length)
    [IO.File]::WriteAllText($pub, $text)
    $files += ' komga_reader/pubspec.yaml'
    Write-Host "pubspec.yaml: the next build is the first $next build"
}
Git "add $files" | Out-Null
Git "commit -q -m `"$(if ($Final) { "Release $name (build $Build)" } else { "Release candidate $Rc of $name (build $Build)" })`"" | Out-Null
Write-Host "CHANGELOG noted and committed. Not pushed: push main and $tag when you want them on GitHub."
