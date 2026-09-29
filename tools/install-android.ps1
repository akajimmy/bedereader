<#
.SYNOPSIS
    Installs a Komga Reader APK on the paired tablet over wireless ADB (no browser, no prompts; settings kept).

.DESCRIPTION
    Finds the tablet (already connected, or discovered on the Wi-Fi via mDNS), installs the APK as an update and
    checks the installed version afterwards. If no tablet is reachable it says so and exits with code 2 - usually
    Wireless debugging was switched off (Settings > Developer options > Wireless debugging) or the tablet is asleep
    and off the Wi-Fi. Pairing is a one-time step done by hand:
        & 'C:\Dev\android-sdk\platform-tools\adb.exe' pair <IP>:<port>      (then type the code the tablet shows)

.PARAMETER Apk
    APK to install. Default: the newest one in dist\.

.EXAMPLE
    .\tools\install-android.ps1
#>
param([string]$Apk)

$ErrorActionPreference = 'Stop'
$adb = 'C:\Dev\android-sdk\platform-tools\adb.exe'
$root = Split-Path -Parent $PSScriptRoot
$package = 'com.nickp.komga_reader'

function Say([string]$text) { Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $text) }
function Adb([string]$arguments) { cmd /c "`"$adb`" $arguments 2>&1" }

if (-not $Apk) {
    $Apk = Get-ChildItem (Join-Path $root 'dist') -Recurse -Filter 'KomgaReader-*-android.apk' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    if (-not $Apk) { throw 'No APK found in dist\ - run tools\build.ps1 first.' }
}

# 1. a connected device, or connect to one advertised on the Wi-Fi
function Devices { @(Adb 'devices' | Where-Object { $_ -match '\sdevice$' } | ForEach-Object { ($_ -split '\s+')[0] }) }
$devices = @(Devices)  # @() keeps a single device a list (else [0] is its first letter)
if ($devices.Count -eq 0) {
    Say 'no tablet connected - looking for it on the Wi-Fi ...'
    $service = Adb 'mdns services' | Where-Object { $_ -match '_adb-tls-connect\._tcp\s+(\S+)' } | Select-Object -First 1
    if ($service -and $service -match '_adb-tls-connect\._tcp\s+(\S+)') {
        Adb "connect $($Matches[1])" | Out-Null
        Start-Sleep -Seconds 2
        $devices = @(Devices)
    }
}
if ($devices.Count -eq 0) {
    Say 'tablet not reachable - is Wireless debugging on (Settings > Developer options)? APK not installed.'
    exit 2
}
$device = $devices[0]

# 2. install as an update and check the version that is now there
$before = (Adb "-s $device shell dumpsys package $package") | Select-String -Pattern 'versionCode=(\d+)' | Select-Object -First 1
Say "installing $(Split-Path $Apk -Leaf) on $device ..."
$result = Adb "-s $device install -r `"$Apk`""
if (-not ($result -match '^Success')) { throw "install failed: $($result -join ' ')" }
$after = (Adb "-s $device shell dumpsys package $package") | Select-String -Pattern 'versionCode=(\d+)' | Select-Object -First 1
$b = if ($before) { $before.Matches[0].Groups[1].Value } else { 'none' }
Say "installed: build $b -> build $($after.Matches[0].Groups[1].Value)"
