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

# adb's background server is started on its own first, in a hidden window. Started by the first captured call below
# instead, it inherits that call's output pipe and holds it open for as long as it runs - the call never returns, and
# the install hung after build 37 until stopped by hand.
$server = Start-Process $adb -ArgumentList 'start-server' -WindowStyle Hidden -PassThru
if (-not $server.WaitForExit(20000)) {
    Say 'adb did not start within 20 s - install later with tools\install-android.ps1'
    exit 2
}

if (-not $Apk) {
    $Apk = Get-ChildItem (Join-Path $root 'dist') -Recurse -Filter '*-android.apk' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    if (-not $Apk) { throw 'No APK found in dist\ - run tools\build.ps1 first.' }
}

# 1. a connected device, or connect to one advertised on the Wi-Fi
# Connected devices as transport ids, newest connection first. (Names can contain spaces - after Wireless debugging
# is switched off and on the tablet reappears as "adb-... (2)" next to the stale old entry - so go by transport id.)
function Devices {
    @(Adb 'devices -l' | ForEach-Object {
            if ($_ -match '\sdevice\s.*transport_id:(\d+)') { [int]$Matches[1] }
        } | Sort-Object -Descending)
}
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
$before = (Adb "-t $device shell dumpsys package $package") | Select-String -Pattern 'versionCode=(\d+)' | Select-Object -First 1
Say "installing $(Split-Path $Apk -Leaf) on the tablet (connection $device) ..."
$result = Adb "-t $device install -r `"$Apk`""
if ($result -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE') {
    # the tablet's copy is signed with another key (the debug key, before release signing): Android won't update it.
    # Uninstalling deletes the app's data on the tablet, so that's left to the user.
    Say 'the tablet has a copy signed with a different key, so Android refuses to update it. Uninstall Komga Reader on'
    Say 'the tablet (this removes its settings and downloads there; what is synced through Komga comes back), then run'
    Say 'tools\install-android.ps1 again. This happens once, when moving to the release key.'
    exit 3
}
if (-not ($result -match '^Success')) { throw "install failed: $($result -join ' ')" }
$after = (Adb "-t $device shell dumpsys package $package") | Select-String -Pattern 'versionCode=(\d+)' | Select-Object -First 1
$b = if ($before) { $before.Matches[0].Groups[1].Value } else { 'none' }
Say "installed: build $b -> build $($after.Matches[0].Groups[1].Value)"
