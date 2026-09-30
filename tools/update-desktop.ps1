<#
.SYNOPSIS
    Unzips a Windows build over the copy on the Desktop (Desktop\BeDeReader), for everyday use on this PC.
.DESCRIPTION
    The owner's own copy of the app ("dogfooding", 2026-09-29): tools\build.ps1 runs this after every Windows build,
    next to installing on the tablet. Files are overwritten in place; nothing else in the folder is touched, and the
    settings and downloads aren't in it (they live in %APPDATA% and %LOCALAPPDATA%).
    If the app is open from that folder its files are locked: nothing is changed, it says so and exits with code 2 -
    close the app and run this again.
.PARAMETER Zip
    The Windows zip to unpack. Default: the newest *-windows.zip in dist\.
.PARAMETER Dest
    Default: <Desktop>\BeDeReader.
.EXAMPLE
    C:\Claude\KomgaClient\tools\update-desktop.ps1
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
    Say "Desktop copy not updated: $($open[0].ProcessName) is open from $Dest - close it, then run tools\update-desktop.ps1"
    exit 2
}

New-Item -ItemType Directory -Force $Dest | Out-Null
Expand-Archive -Path $Zip -DestinationPath $Dest -Force
Say "Desktop copy updated: $(Split-Path $Zip -Leaf) -> $Dest"
exit 0
