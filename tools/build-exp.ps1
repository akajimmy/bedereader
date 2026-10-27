<#
.SYNOPSIS
    An experimental build (branch experimental): built from this worktree, installed beside the real app.

.DESCRIPTION
    The experiment's app is its own app: "BeDeReader Exp", Android ID com.nickp.komga_reader.exp, Windows data in
    %LOCALAPPDATA%\KomgaReaderExp and %APPDATA%\com.nickp\Komga Reader Exp. So it never touches the real app's
    install, settings or downloads.

    Unlike build.ps1 -Bump: no build number taken, nothing committed, tagged or pushed, nothing sent to TestFlight.
    Uncommitted changes are fine (an experiment), and the tests are skipped unless -Tests; flutter analyze still runs.

      .\tools\build-exp.ps1                    Android + Windows, installed on the tablet and in Desktop\BeDeReader-Exp
      .\tools\build-exp.ps1 -Platforms android
      .\tools\build-exp.ps1 -Tests             with the test suite first
#>
[CmdletBinding()]
param(
    [ValidateSet('android', 'windows')]
    [string[]]$Platforms = @('android', 'windows'),
    [switch]$Tests,
    [switch]$NoInstall
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$package = 'com.nickp.komga_reader.exp'
$desktop = Join-Path ([Environment]::GetFolderPath('Desktop')) 'BeDeReader-Exp'

# the real app's identity must not be what's built here (a merge from 1.5 could bring it back)
$gradle = [IO.File]::ReadAllText((Join-Path $root 'komga_reader\android\app\build.gradle.kts'))
if ($gradle -notmatch "applicationId = `"$([regex]::Escape($package))`"") {
    throw "build.gradle.kts doesn't have applicationId $package - this would install over the real app. Not built."
}

$buildArgs = @{ Platforms = $Platforms; AllowDirty = $true; NoInstall = $true }
if (-not $Tests) { $buildArgs.SkipTests = $true }
& (Join-Path $PSScriptRoot 'build.ps1') @buildArgs

$pubspec = [IO.File]::ReadAllText((Join-Path $root 'komga_reader\pubspec.yaml'))
$m = [regex]::Match($pubspec, '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)')
$out = Join-Path $root "dist\$($m.Groups[1].Value)+$($m.Groups[2].Value)"
if ($NoInstall) { Write-Host "built in $out (not installed: -NoInstall)"; return }

if ($Platforms -contains 'android') {
    $apk = Get-ChildItem $out -Filter '*-android.apk' | Select-Object -First 1
    & (Join-Path $PSScriptRoot 'install-android.ps1') -Apk $apk.FullName -Package $package
}
if ($Platforms -contains 'windows') {
    $zip = Get-ChildItem $out -Filter '*-windows.zip' | Select-Object -First 1
    & (Join-Path $PSScriptRoot 'update-desktop.ps1') -Zip $zip.FullName -Dest $desktop
}
