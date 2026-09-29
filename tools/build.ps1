<#
.SYNOPSIS
    Builds Komga Reader for every platform into dist\<version>\ - after the checks pass.

.DESCRIPTION
    1. Checks: working tree clean (unless -AllowDirty), flutter analyze, flutter test. Any failure stops the build.
    2. -Bump: raises the build number in komga_reader\pubspec.yaml (0.1.0+17 -> 0.1.0+18).
    3. Builds the requested platforms:
         android  -> KomgaReader-<ver>-android.apk
         windows  -> KomgaReader-<ver>-windows.zip   (portable folder: unzip anywhere, run KomgaReader.exe)
         web      -> KomgaReader-<ver>-web.zip
    4. Writes SHA256SUMS.txt and BUILD-INFO.txt next to them.
    5. With -Bump, commits the version change and tags it build-<n>.
    6. Installs the APK on the paired tablet over wireless ADB (tools\install-android.ps1) unless -NoInstall;
       if the tablet isn't reachable the build still counts and it says so.

    Each step prints a timestamped line; the tools' full output goes to dist\build.log
    (watch it with: Get-Content C:\Claude\KomgaClient\dist\build.log -Wait -Tail 20).

.EXAMPLE
    .\tools\build.ps1 -Bump
    .\tools\build.ps1 -Platforms android
    .\tools\build.ps1 -Platforms windows,web -SkipTests
#>
param(
    [switch]$Bump,
    [ValidateSet('android', 'windows', 'web')]
    [string[]]$Platforms = @('android', 'windows', 'web'),
    [switch]$SkipTests,
    [switch]$AllowDirty,
    [switch]$NoInstall      # don't install the APK on the paired tablet afterwards
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot          # C:\Claude\KomgaClient
$app = Join-Path $root 'komga_reader'
$dist = Join-Path $root 'dist'
$log = Join-Path $dist 'build.log'
$env:JAVA_HOME = 'C:\Dev\jdk17'
$env:PATH = "C:\Dev\flutter\bin;$env:PATH"
$started = Get-Date

New-Item -ItemType Directory -Force $dist | Out-Null
"==== build started $started ====" | Out-File $log -Encoding utf8

function Say([string]$text) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $text
    Write-Host $line
    $line | Out-File $log -Append -Encoding utf8
}

# Runs a command through cmd so stdout+stderr land in the log (PowerShell 5.1 would turn stderr lines into
# errors). Throws with the log's tail if it fails.
function Run([string]$what, [string]$command) {
    Say "$what ..."
    $t = Get-Date
    Push-Location $app
    try {
        cmd /c "$command >> `"$log`" 2>&1"
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($code -ne 0) {
        Write-Host '---- last lines of the log ----'
        Get-Content $log -Tail 25 | ForEach-Object { Write-Host "  $_" }
        throw "$what failed (exit code $code). Full log: $log"
    }
    Say ('{0} done ({1:N0} s)' -f $what, ((Get-Date) - $t).TotalSeconds)
}

function Git([string]$arguments) {
    $out = cmd /c "git -C `"$root`" $arguments 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "git $arguments failed: $out" }
    return $out
}

# ---- 1. checks ---------------------------------------------------------------------------------------------------
$dirty = Git 'status --porcelain'
if ($dirty -and -not $AllowDirty) {
    throw "Uncommitted changes - commit them first (or pass -AllowDirty for a throwaway build):`n$($dirty -join "`n")"
}
# only a copy running from the build folder is in the way (a portable copy elsewhere is fine)
$buildDir = Join-Path $app 'build\windows'
$blocking = Get-Process KomgaReader -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($buildDir, [StringComparison]::OrdinalIgnoreCase) }
if ($Platforms -contains 'windows' -and $blocking) {
    throw "Komga Reader is running from the build folder ($($blocking[0].Path)) - close it first (the Windows build replaces its files)."
}
Run 'flutter pub get' 'flutter pub get'
Run 'flutter analyze' 'flutter analyze --no-fatal-infos'
if (-not $SkipTests) { Run 'flutter test' 'flutter test' } else { Say 'tests skipped (-SkipTests)' }

# ---- 2. version --------------------------------------------------------------------------------------------------
$pubspec = Join-Path $app 'pubspec.yaml'
$text = [IO.File]::ReadAllText($pubspec)
$originalPubspec = $text
$m = [regex]::Match($text, '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)')
if (-not $m.Success) { throw 'No "version: x.y.z+n" line in pubspec.yaml' }
$name = $m.Groups[1].Value
$build = [int]$m.Groups[2].Value
if ($Bump) {
    $build++
    $text = $text.Substring(0, $m.Index) + "version: $name+$build" + $text.Substring($m.Index + $m.Length)
    [IO.File]::WriteAllText($pubspec, $text, (New-Object Text.UTF8Encoding($false)))  # no BOM
    Say "version bumped to $name+$build"
}
# ---- 2b. changelog, and the documents bundled into the app (About > What's new / Read me) ---------------------------
# Done before building so the app's copy of the changelog already lists this build. Put back if the build fails.
$changelog = Join-Path $root 'CHANGELOG.md'
$docsDir = Join-Path $app 'assets\docs'
$utf8 = New-Object Text.UTF8Encoding($false)
$originalChangelog = if (Test-Path $changelog) { [IO.File]::ReadAllText($changelog) } else { $null }
$originalDocs = @{}
foreach ($f in 'README.md', 'CHANGELOG.md', 'THIRD_PARTY_NOTICES.md') {
    $p = Join-Path $docsDir $f
    $originalDocs[$f] = if (Test-Path $p) { [IO.File]::ReadAllText($p) } else { $null }
}
$filed = $false
if ($Bump -and $originalChangelog) {
    # the "Unreleased" entries become "### Build <n> - <date>", first in this version's "## <version>" section
    # (a new section is started above the others for a new version)
    $cl = $originalChangelog
    $u = [regex]::Match($cl, '(?ms)^## Unreleased[^\n]*\n(.*?)(?=^## |\z)')
    if ($u.Success -and $u.Groups[1].Value.Trim()) {
        $entries = $u.Groups[1].Value.Trim()
        $cl = $cl.Substring(0, $u.Index) + "## Unreleased`n`n" + $cl.Substring($u.Index + $u.Length)
        $heading = "### Build $build - $(Get-Date -Format 'yyyy-MM-dd')`n`n$entries`n`n"
        $v = [regex]::Match($cl, "(?m)^## $([regex]::Escape($name))\b[^\n]*\n")
        if ($v.Success) {
            $firstBuild = [regex]::Match($cl.Substring($v.Index), '(?m)^### ')
            $at = if ($firstBuild.Success) { $v.Index + $firstBuild.Index } else { $v.Index + $v.Length }
            $cl = $cl.Substring(0, $at) + $heading + $cl.Substring($at)
        } else {
            $top = [regex]::Match($cl, '(?m)^## Unreleased[^\n]*\n\s*')
            $at = $top.Index + $top.Length
            $cl = $cl.Substring(0, $at) + "## $name`n`n" + $heading + $cl.Substring($at)
        }
        [IO.File]::WriteAllText($changelog, $cl, $utf8)
        $filed = $true
        Say "CHANGELOG: Unreleased entries filed under Build $build ($name)"
    }
}
New-Item -ItemType Directory -Force $docsDir | Out-Null
foreach ($f in 'README.md', 'CHANGELOG.md', 'THIRD_PARTY_NOTICES.md') {
    $src = Join-Path $root $f
    if (Test-Path $src) { Copy-Item $src (Join-Path $docsDir $f) -Force }
}

function Restore-Documents {
    if ($filed) { [IO.File]::WriteAllText($changelog, $originalChangelog, $utf8) }
    foreach ($f in 'README.md', 'CHANGELOG.md', 'THIRD_PARTY_NOTICES.md') {
        $p = Join-Path $docsDir $f
        if ($null -eq $originalDocs[$f]) { if (Test-Path $p) { Remove-Item $p } }
        else { [IO.File]::WriteAllText($p, $originalDocs[$f], $utf8) }
    }
}

$version = "$name-b$build"
$out = Join-Path $dist "$name+$build"
New-Item -ItemType Directory -Force $out | Out-Null
Say "building $name+$build for: $($Platforms -join ', ') -> $out"

# ---- 3. platforms ------------------------------------------------------------------------------------------------
$artifacts = @()
try {
if ($Platforms -contains 'android') {
    $keyProps = Join-Path $app 'android\key.properties'
    $signing = if (Test-Path $keyProps) { 'release key (android\key.properties)' } else { 'DEBUG key - no android\key.properties' }
    if (-not (Test-Path $keyProps)) {
        Say 'WARNING: no android\key.properties - the APK is signed with the debug key (fine for testing, not for release)'
    }
    Run 'Android APK' 'flutter build apk --release'
    $apk = Join-Path $out "KomgaReader-$version-android.apk"
    Copy-Item (Join-Path $app 'build\app\outputs\flutter-apk\app-release.apk') $apk -Force
    $artifacts += $apk
}
if ($Platforms -contains 'windows') {
    Run 'Windows app' 'flutter build windows --release'
    $zip = Join-Path $out "KomgaReader-$version-windows.zip"
    if (Test-Path $zip) { Remove-Item $zip }
    Compress-Archive -Path (Join-Path $app 'build\windows\x64\runner\Release\*') -DestinationPath $zip
    $artifacts += $zip
}
if ($Platforms -contains 'web') {
    Run 'Web app' 'flutter build web --release'
    $zip = Join-Path $out "KomgaReader-$version-web.zip"
    if (Test-Path $zip) { Remove-Item $zip }
    Compress-Archive -Path (Join-Path $app 'build\web\*') -DestinationPath $zip
    $artifacts += $zip
}

# ---- 4. checksums + build info -------------------------------------------------------------------------------------
$sums = foreach ($a in $artifacts) { '{0}  {1}' -f (Get-FileHash $a -Algorithm SHA256).Hash.ToLower(), (Split-Path $a -Leaf) }
$sums | Out-File (Join-Path $out 'SHA256SUMS.txt') -Encoding ascii
$commit = (Git 'rev-parse --short HEAD') | Select-Object -First 1
$flutter = (cmd /c 'flutter --version --machine 2>nul' | Out-String)
$fv = [regex]::Match($flutter, '"frameworkVersion"\s*:\s*"([^"]+)"').Groups[1].Value
@(
    "Komga Reader $name+$build",
    "built:    $(Get-Date -Format 'yyyy-MM-dd HH:mm')",
    "commit:   $commit$(if ($Bump) { ' (+ this version bump)' })$(if ($dirty) { ' - WORKING TREE HAD UNCOMMITTED CHANGES' })",
    "flutter:  $fv",
    "tests:    $(if ($SkipTests) { 'skipped' } else { 'passed' })",
    "android:  $(if ($Platforms -contains 'android') { "signed with the $signing" } else { 'not built' })",
    '',
    'files:'
) + ($artifacts | ForEach-Object { '  {0}  ({1:N1} MB)' -f (Split-Path $_ -Leaf), ((Get-Item $_).Length / 1MB) }) |
    Out-File (Join-Path $out 'BUILD-INFO.txt') -Encoding utf8
} catch {
    # a failed build must not leave a half-done version bump, changelog or document copy behind
    Restore-Documents
    if ($Bump) {
        [IO.File]::WriteAllText($pubspec, $originalPubspec, (New-Object Text.UTF8Encoding($false)))
        Say "build failed - version put back to $name+$($build - 1); changelog and bundled documents put back"
    }
    throw
}

# ---- 5. commit + tag the bump ----------------------------------------------------------------------------------------
if ($Bump) {
    # the changelog was filed and the documents bundled before building (step 2b)
    Git "add CHANGELOG.md komga_reader/assets/docs komga_reader/pubspec.yaml" | Out-Null
    Git "commit -q -m `"Build $build`"" | Out-Null
    Git "tag build-$build" | Out-Null
    Say "committed and tagged build-$build"
}

# ---- 6. put it on the tablet ---------------------------------------------------------------------------------------
if ($Platforms -contains 'android' -and -not $NoInstall) {
    $apk = $artifacts | Where-Object { $_ -like '*-android.apk' } | Select-Object -First 1
    & (Join-Path $PSScriptRoot 'install-android.ps1') -Apk $apk
    if ($LASTEXITCODE -eq 2) { Say 'build finished; install it later with tools\install-android.ps1' }
    if ($LASTEXITCODE -eq 3) { Say 'build finished; not installed - the tablet needs the old copy uninstalled first (see above)' }
}

Say ('all done in {0:N0} s' -f ((Get-Date) - $started).TotalSeconds)
$artifacts | ForEach-Object { Write-Host ('  {0}  ({1:N1} MB)' -f $_, ((Get-Item $_).Length / 1MB)) }

# the build itself succeeded (a skipped tablet install is reported above, not a failure)
exit 0
