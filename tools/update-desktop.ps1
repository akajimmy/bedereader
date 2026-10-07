<#
.SYNOPSIS
    Unzips a Windows build over the copy on the Desktop (Desktop\BeDeReader), for everyday use on this PC.
.DESCRIPTION
    The owner's own copy of the app ("dogfooding", 2026-09-29): tools\build.ps1 runs this after every Windows build,
    next to installing on the tablet. The build is unpacked into a new folder and swapped in; the copy it replaces
    stays beside it as BeDeReader.previous (the one before that goes). The settings and downloads aren't in these
    folders (they live in %APPDATA% and %LOCALAPPDATA%).
    If the app is open from that folder its files are locked: nothing is changed, it says so and exits with code 2 -
    close the app and run this again.
.PARAMETER Zip
    The Windows zip to unpack. Default: the newest *-windows.zip in dist\.
.PARAMETER Dest
    Default: <Desktop>\BeDeReader.
.EXAMPLE
    C:\Claude\KomgaClient\tools\update-desktop.cmd
    (or double-click it) - runs this script with the execution policy bypassed for that one run; Windows blocks
    .ps1 files by default.
#>
param(
    [string]$Zip,
    [string]$Dest = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'BeDeReader')
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
function Say([string]$text) { Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $text) }

if (-not $Zip) {
    $Zip = Get-ChildItem (Join-Path $root 'dist') -Recurse -Filter '*-windows.zip' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    if (-not $Zip) { throw 'No Windows build found in dist\ - run tools\build.ps1 first.' }
}

# open from that folder: its files are locked - leave everything as it is
$open = Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -and $_.Path.StartsWith($Dest.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}
if ($open) {
    Say "Desktop copy not updated: $($open[0].ProcessName) is open from $Dest - close it, then run tools\update-desktop.cmd"
    exit 2
}

# Unpacked into a new folder first, then swapped in (test audit, 2026-09-30): unpacking over the copy left files
# from older builds behind, and a failure part way left a mixed copy. The copy it replaces is kept beside it as
# "<Dest>.previous" (the one before that goes) - put it back by renaming if a build misbehaves.
$fresh = "$($Dest.TrimEnd('\')).new"
$previous = "$($Dest.TrimEnd('\')).previous"
if (Test-Path $fresh) { Remove-Item $fresh -Recurse -Force }
Expand-Archive -Path $Zip -DestinationPath $fresh
$exe = Join-Path $fresh 'BeDeReader.exe'
if (-not (Test-Path $exe)) {
    Remove-Item $fresh -Recurse -Force
    throw "$(Split-Path $Zip -Leaf) has no BeDeReader.exe - the Desktop copy was left as it was"
}
$movedAside = $false
if (Test-Path $Dest) {
    if (Test-Path $previous) { Remove-Item $previous -Recurse -Force }
    Rename-Item $Dest (Split-Path $previous -Leaf)
    $movedAside = $true
}
try {
    Rename-Item $fresh (Split-Path $Dest -Leaf) -ErrorAction Stop
} catch {
    # the new copy couldn't take its place (antivirus scanning the new .exe, say): the old copy goes back, so there's
    # always a Desktop copy - it used to be left with none (code review 2026-10-05, #9). The new one stays as ".new".
    if ($movedAside -and -not (Test-Path $Dest)) { Rename-Item $previous (Split-Path $Dest -Leaf) }
    throw "the new copy couldn't be put in place ($($_.Exception.Message)) - the Desktop copy was left as it was; the new build is in $fresh"
}
$version = (Get-Item (Join-Path $Dest 'BeDeReader.exe')).VersionInfo.ProductVersion
Say "Desktop copy updated: $(Split-Path $Zip -Leaf) -> $Dest (BeDeReader.exe $version; the copy before it: $previous)"
exit 0
