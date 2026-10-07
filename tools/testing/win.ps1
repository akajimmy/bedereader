# Drives the BeDeReader Windows app for testing.
#   win.ps1 start                     - start Desktop\BeDeReader\BeDeReader.exe (if not running), bring it forward
#   win.ps1 shot <file.png>           - screenshot of the app's window
#   win.ps1 click <x> <y>             - left click at window-relative pixel x,y (as in the screenshot)
#   win.ps1 rclick <x> <y>            - right click
#   win.ps1 key <keys>                - SendKeys string to the app (e.g. "{RIGHT}", "{ESC}", "{PGDN}")
#   win.ps1 size <w> <h>              - move the window to 40,40 and size it w x h
#   win.ps1 wheel <x> <y> <clicks>    - mouse wheel at x,y (negative = down)
#   win.ps1 info                      - window position and size, process id
param([string]$cmd, [string]$a, [string]$b, [string]$c)
$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class W {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool r);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(int f, int dx, int dy, int d, int e);
  public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
[void][W]::SetProcessDPIAware()
Add-Type -AssemblyName System.Drawing, System.Windows.Forms

function App {
    $p = Get-Process -Name BeDeReader -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $p) { throw 'BeDeReader is not running (win.ps1 start)' }
    $p
}
function Front($p) { [void][W]::ShowWindow($p.MainWindowHandle, 9); [void][W]::SetForegroundWindow($p.MainWindowHandle); Start-Sleep -Milliseconds 250 }
function Rect($p) { $r = New-Object W+RECT; [void][W]::GetWindowRect($p.MainWindowHandle, [ref]$r); $r }

switch ($cmd) {
    'start' {
        $p = Get-Process -Name BeDeReader -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if (-not $p) {
            Start-Process "$env:USERPROFILE\Desktop\BeDeReader\BeDeReader.exe" -WorkingDirectory "$env:USERPROFILE\Desktop\BeDeReader"
            for ($i = 0; $i -lt 40 -and -not $p; $i++) {
                Start-Sleep -Milliseconds 500
                $p = Get-Process -Name BeDeReader -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
            }
        }
        if (-not $p) { throw 'did not start' }
        Front $p
        "started: pid $($p.Id) version $($p.MainModule.FileVersionInfo.ProductVersion)"
    }
    'info' { $p = App; $r = Rect $p; "pid $($p.Id) at $($r.Left),$($r.Top) size $($r.Right - $r.Left)x$($r.Bottom - $r.Top)" }
    'shot' {
        $p = App; Front $p; $r = Rect $p
        $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
        $bmp = New-Object System.Drawing.Bitmap $w, $h
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
        $bmp.Save($a, [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose()
        "saved $a ($w x $h)"
    }
    { $_ -in 'click', 'rclick' } {
        $p = App; Front $p; $r = Rect $p
        [void][W]::SetCursorPos($r.Left + [int]$a, $r.Top + [int]$b); Start-Sleep -Milliseconds 80
        if ($cmd -eq 'click') { [W]::mouse_event(2, 0, 0, 0, 0); [W]::mouse_event(4, 0, 0, 0, 0) }
        else { [W]::mouse_event(8, 0, 0, 0, 0); [W]::mouse_event(16, 0, 0, 0, 0) }
        "$cmd at $a,$b"
    }
    'wheel' {
        $p = App; Front $p; $r = Rect $p
        [void][W]::SetCursorPos($r.Left + [int]$a, $r.Top + [int]$b); Start-Sleep -Milliseconds 80
        [W]::mouse_event(0x800, 0, 0, 120 * [int]$c, 0)
        "wheel $c at $a,$b"
    }
    'key' { $p = App; Front $p; [System.Windows.Forms.SendKeys]::SendWait($a); "keys $a" }
    'size' { $p = App; [void][W]::ShowWindow($p.MainWindowHandle, 9); [void][W]::MoveWindow($p.MainWindowHandle, 40, 40, [int]$a, [int]$b, $true); Start-Sleep -Milliseconds 400; "sized $a x $b" }
    default { 'usage: start | shot f | click x y | rclick x y | key k | size w h | wheel x y n | info' }
}
