# Tests tools\update-desktop.ps1 on temporary folders (never the real Desktop copy): the normal swap, and the final
# rename failing - the old copy must be back in place. Run with: powershell -ExecutionPolicy Bypass -File <this>
param([string]$script = 'C:\Claude\KomgaClient\tools\update-desktop.ps1')
$ErrorActionPreference = 'Stop'
"script under test: $script"
$base = Join-Path $env:TEMP "ud-test-$(Get-Random)"
New-Item -ItemType Directory $base | Out-Null
$zipSrc = Join-Path $base 'zipsrc'; New-Item -ItemType Directory $zipSrc | Out-Null
'new build' | Set-Content (Join-Path $zipSrc 'BeDeReader.exe')
$zip = Join-Path $base 'BeDeReader-test-windows.zip'
Compress-Archive -Path "$zipSrc\*" -DestinationPath $zip
$dest = Join-Path $base 'BeDeReader'
function Old { New-Item -ItemType Directory $dest -Force | Out-Null; 'old build' | Set-Content (Join-Path $dest 'BeDeReader.exe') }
$results = @()

# 1. the normal swap
Old
& $script -Zip $zip -Dest $dest *> $null
$results += "normal: Dest has the new build: $((Get-Content (Join-Path $dest 'BeDeReader.exe')) -eq 'new build'); previous has the old: $((Get-Content (Join-Path "$dest.previous" 'BeDeReader.exe')) -eq 'old build')"

# 2. the new copy can't be renamed into place
Remove-Item $dest, "$dest.previous" -Recurse -Force
Old
$global:renames = @()
function Rename-Item { [CmdletBinding()] param([Parameter(Position = 0)]$Path, [Parameter(Position = 1)]$NewName)
    $global:renames += "$(Split-Path $Path -Leaf) -> $NewName"
    if ($Path -like '*.new') { throw 'simulated: file in use' }
    Microsoft.PowerShell.Management\Rename-Item -Path $Path -NewName $NewName }
$failed = $false
try { & $script -Zip $zip -Dest $dest *> $null } catch { $failed = $true; $msg = $_.Exception.Message }
Remove-Item Function:\Rename-Item
$results += "failure: renames tried: $($global:renames -join ' | ')"
$results += "failure: reported: $failed ($msg)"
$results += "failure: Dest still exists: $(Test-Path $dest); it is the old build: $((Get-Content (Join-Path $dest 'BeDeReader.exe')) -eq 'old build'); the new one kept as .new: $(Test-Path "$dest.new")"

Remove-Item $base -Recurse -Force
$results
