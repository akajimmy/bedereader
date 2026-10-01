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
    if (-not $Build) { throw 'No build-<n> tags - make a build with tools\build.ps1 -Bump first.' }
}
$buildTag = "build-$Build"
if (-not (Git "tag -l $buildTag")) { throw "No $buildTag tag." }
$commit = (Git "rev-list -n1 $buildTag").Trim()
$pubspecThen = Git "show ${commit}:komga_reader/pubspec.yaml"
$m = [regex]::Match(($pubspecThen -join "`n"), '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)')
if (-not $m.Success) { throw "No version line in pubspec.yaml at $buildTag" }
$name = "$($m.Groups[1].Value).$($m.Groups[2].Value).$($m.Groups[3].Value)"
$tag = if ($Final) { "v$name" } else { "v$name-rc.$Rc" }
if ((Git "tag -l $tag")) { throw "$tag already exists." }

# is that build fit to release? (test audit, 2026-09-30) Its BUILD-INFO must say the tests passed, the tree was clean
# and the APK is signed with the release key; its files must still match SHA256SUMS.txt.
$out = Join-Path $root "dist\$name+$Build"
$info = Join-Path $out 'BUILD-INFO.txt'
if (-not (Test-Path $info)) { throw "No $info - can't tell whether that build passed its checks." }
$infoText = [IO.File]::ReadAllText($info)
if ($infoText -notmatch '(?m)^tests:\s+passed') { throw "$buildTag didn't pass its tests (BUILD-INFO.txt) - not released." }
if ($infoText -match 'UNCOMMITTED') { throw "$buildTag was built with uncommitted changes (BUILD-INFO.txt) - not released." }
if ($infoText -match '(?m)^android:\s+signed with' -and $infoText -notmatch '(?m)^android:\s+signed with the release key') {
    throw "$buildTag's APK isn't signed with the release key (BUILD-INFO.txt) - not released."
}
$sums = Join-Path $out 'SHA256SUMS.txt'
if (-not (Test-Path $sums)) { throw "No $sums." }
foreach ($line in [IO.File]::ReadAllLines($sums)) {
    if (-not $line.Trim()) { continue }
    $hash, $file = $line -split '\s+', 2
    $p = Join-Path $out $file.Trim()
    if (-not (Test-Path $p)) { throw "$file (in SHA256SUMS.txt) is missing from $out." }
    if ((Get-FileHash $p -Algorithm SHA256).Hash.ToLower() -ne $hash.ToLower()) { throw "$file doesn't match SHA256SUMS.txt - not released." }
}

$date = Get-Date -Format 'yyyy-MM-dd'

# Everything is checked and prepared first; the files are written, committed, and only then tagged - so a problem
# on the way leaves no tag behind (and git puts the files back).

# CHANGELOG: the version's section says which builds are candidates / the release (works with either line ending,
# and keeps the one the file has)
$clPath = Join-Path $root 'CHANGELOG.md'
$raw = [IO.File]::ReadAllText($clPath)
$nl = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
$cl = $raw.Replace("`r`n", "`n")
# the section's heading line, and its intro paragraph if it has one (build.ps1 starts a new version's section without
# one: the heading, then straight its first "### Build"). The note replaces both and is always followed by a blank
# line - without that, the next heading was glued onto the note (code review, 2026-09-30).
$sec = [regex]::Match($cl, "(?m)^## $([regex]::Escape($name))\b[^\n]*\n(\n*[^\n#][^\n]*(\n[^\n#][^\n]*)*)?\n*")
if (-not $sec.Success) { throw "No '## $name' section in CHANGELOG.md - nothing changed" }
$rcs = @(Git "tag -l v$name-rc.*" | Where-Object { $_ })
$candidates = @($rcs | ForEach-Object { [pscustomobject]@{ n = [int]($_ -replace '.*-rc\.', ''); tag = $_;
    build = [int]((Git "describe --tags --match build-* $_") -replace '^build-(\d+).*', '$1') } })
if (-not $Final) { $candidates += [pscustomobject]@{ n = $Rc; tag = $tag; build = $Build } }
$rcText = if ($candidates.Count) {
    "Release candidates: $(($candidates | Sort-Object n | ForEach-Object { "build $($_.build) (``$($_.tag)``)" }) -join ', ')."
} else { 'No release candidates.' }
$note = if ($Final) {
    "## $name`n`n**Released as build $Build, tagged ``v$name``** ($date). $rcText"
} else {
    "## $name - in development`n`nNot released yet. $rcText"
}
$cl = $cl.Substring(0, $sec.Index) + $note + "`n`n" + $cl.Substring($sec.Index + $sec.Length)

$files = 'CHANGELOG.md komga_reader/assets/docs/CHANGELOG.md'
$pub = Join-Path $root 'komga_reader\pubspec.yaml'
if ($Final) {
    # the next build is the first build of the next version
    $pubText = [IO.File]::ReadAllText($pub)
    $now = [regex]::Match($pubText, '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)')
    if (-not $now.Success) { throw 'No version line in pubspec.yaml - nothing changed' }
    $next = "$($now.Groups[1].Value).$([int]$now.Groups[2].Value + 1).0"
    $pubText = $pubText.Substring(0, $now.Index) + "version: $next+$($now.Groups[4].Value)" +
        $pubText.Substring($now.Index + $now.Length)
    $files += ' komga_reader/pubspec.yaml'
}

try {
    [IO.File]::WriteAllText($clPath, $cl.Replace("`n", $nl))
    Copy-Item $clPath (Join-Path $root 'komga_reader\assets\docs\CHANGELOG.md') -Force
    if ($Final) { [IO.File]::WriteAllText($pub, $pubText) }
    Git "add $files" | Out-Null
    Git "commit -q -m `"$(if ($Final) { "Release $name (build $Build)" } else { "Release candidate $Rc of $name (build $Build)" })`"" | Out-Null
} catch {
    Git "checkout -- $files" | Out-Null # back as they were
    throw
}
$message = if ($Final) { "$name (build $Build) - release" } else { "$name release candidate $Rc (build $Build)" }
Git "tag -a $tag $commit -m `"$message`"" | Out-Null
Write-Host "tagged $tag -> $buildTag ($($commit.Substring(0, 7))); CHANGELOG noted and committed"
if ($Final) { Write-Host "pubspec.yaml: the next build is the first $next build" }
Write-Host "Not pushed: push main and $tag when you want them on GitHub."
