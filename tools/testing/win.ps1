# Drives the BeDeReader Windows app for testing.
#   win.ps1 start                     - start Desktop\BeDeReader\BeDeReader.exe (if not running), bring it forward
#   win.ps1 shot <file.png>           - screenshot of the app's window
#   win.ps1 click <x> <y>             - left click at window-relative pixel x,y (as in the screenshot)
#   win.ps1 rclick <x> <y>            - right click
#   win.ps1 key <keys>                - SendKeys string to the app (e.g. "{RIGHT}", "{ESC}", "{PGDN}")
#   win.ps1 press <keys>              - keys as a real keyboard sends them (scan codes), held together: "ctrl c",
#                                       "ctrl a", "f11", "right", "esc" - SendKeys' Ctrl+C never reached the
#                                       selection (2026-10-11); this does
#   win.ps1 drag <x1> <y1> "<x2>,<y2>"   - left-button drag (mouse selection)
#   win.ps1 unpin                     - the window no longer kept on top (Front pins it)
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
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
  public struct RECT { public int Left, Top, Right, Bottom; }
  public struct POINT { public int X, Y; public POINT(int x, int y) { X = x; Y = y; } }
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Explicit, Size = 40)] public struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public KEYBDINPUT ki; }
  [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
  [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint type);
  public static INPUT Key(ushort vk, bool up) {
    var i = new INPUT(); i.type = 1;
    i.ki.wVk = vk; i.ki.wScan = (ushort)MapVirtualKey(vk, 0); i.ki.dwFlags = up ? 2u : 0u;
    return i;
  }
}
'@
[void][W]::SetProcessDPIAware()
Add-Type -AssemblyName System.Drawing, System.Windows.Forms

function App {
    $p = Get-Process -Name BeDeReader -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $p) { throw 'BeDeReader is not running (win.ps1 start)' }
    $p
}
# Bring the app forward. Windows ignores SetForegroundWindow from a program that isn't in front (this session, when
# the user hasn't just clicked the app themselves), so: pin it on top (it shows and takes clicks without being the
# active window), and borrow the active window's input to make it active too (no keystrokes sent anywhere).
function Front($p) {
    $h = $p.MainWindowHandle
    [void][W]::ShowWindow($h, 9)
    [void][W]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x0003)  # HWND_TOPMOST; SWP_NOSIZE | SWP_NOMOVE
    $fg = [W]::GetForegroundWindow()
    if ($fg -ne $h) {
        $pid0 = [uint32]0
        $fgThread = [W]::GetWindowThreadProcessId($fg, [ref]$pid0)
        $me = [W]::GetCurrentThreadId()
        [void][W]::AttachThreadInput($me, $fgThread, $true)
        [void][W]::BringWindowToTop($h); [void][W]::SetForegroundWindow($h)
        [void][W]::AttachThreadInput($me, $fgThread, $false)
    }
    Start-Sleep -Milliseconds 250
}
function Rect($p) { $r = New-Object W+RECT; [void][W]::GetWindowRect($p.MainWindowHandle, [ref]$r); $r }

# The window under screen point x,y belongs to the app - else throw: a click must never land on another program.
function MustBeApp($p, [int]$x, [int]$y) {
    $under = [W]::GetAncestor([W]::WindowFromPoint((New-Object W+POINT $x, $y)), 2)  # GA_ROOT
    $pid0 = [uint32]0
    [void][W]::GetWindowThreadProcessId($under, [ref]$pid0)
    if ($pid0 -ne $p.Id) { throw "not clicking: the window at $x,$y is another program's (pid $pid0), not BeDeReader's" }
}

switch ($cmd) {
    'start' {
        $p = Get-Process -Name BeDeReader -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if (-not $p) {
            # through Explorer: started by it, not by this (possibly sandboxed) session, the app reads the user's own
            # AppData, not a redirected copy
            Start-Process explorer.exe -ArgumentList "`"$env:USERPROFILE\Desktop\BeDeReader\BeDeReader.exe`""
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
        MustBeApp $p ($r.Left + [int]$a) ($r.Top + [int]$b)
        [void][W]::SetCursorPos($r.Left + [int]$a, $r.Top + [int]$b); Start-Sleep -Milliseconds 80
        if ($cmd -eq 'click') { [W]::mouse_event(2, 0, 0, 0, 0); [W]::mouse_event(4, 0, 0, 0, 0) }
        else { [W]::mouse_event(8, 0, 0, 0, 0); [W]::mouse_event(16, 0, 0, 0, 0) }
        "$cmd at $a,$b"
    }
    'wheel' {
        $p = App; Front $p; $r = Rect $p
        MustBeApp $p ($r.Left + [int]$a) ($r.Top + [int]$b)
        [void][W]::SetCursorPos($r.Left + [int]$a, $r.Top + [int]$b); Start-Sleep -Milliseconds 80
        [W]::mouse_event(0x800, 0, 0, 120 * [int]$c, 0)
        "wheel $c at $a,$b"
    }
    'key' {
        $p = App; Front $p
        # keys go to the active window: only if that is the app
        if ([W]::GetForegroundWindow() -ne $p.MainWindowHandle) { throw 'not sending keys: BeDeReader is not the active window' }
        [System.Windows.Forms.SendKeys]::SendWait($a); "keys $a"
    }
    'drag' {
        # left button down at a,b; move to c,d in steps; up (window-relative)
        $p = App; Front $p; $r = Rect $p
        $x1 = $r.Left + [int]$a; $y1 = $r.Top + [int]$b; $parts = $c -split ','; $x2 = $r.Left + [int]$parts[0]; $y2 = $r.Top + [int]$parts[1]
        MustBeApp $p $x1 $y1; MustBeApp $p $x2 $y2
        [void][W]::SetCursorPos($x1, $y1); Start-Sleep -Milliseconds 80
        [W]::mouse_event(2, 0, 0, 0, 0)
        for ($i = 1; $i -le 20; $i++) {
            [void][W]::SetCursorPos([int]($x1 + ($x2 - $x1) * $i / 20), [int]($y1 + ($y2 - $y1) * $i / 20)); Start-Sleep -Milliseconds 20
        }
        [W]::mouse_event(4, 0, 0, 0, 0)
        "drag $a,$b -> $c"
    }
    'press' {
        $p = App; Front $p
        if ([W]::GetForegroundWindow() -ne $p.MainWindowHandle) { throw 'not pressing keys: BeDeReader is not the active window' }
        $vk = @{ ctrl = 0x11; shift = 0x10; alt = 0x12; a = 0x41; c = 0x43; f11 = 0x7A; esc = 0x1B; enter = 0x0D;
                 space = 0x20; left = 0x25; up = 0x26; right = 0x27; down = 0x28; pgup = 0x21; pgdn = 0x22 }
        $names = $a -split '\s+' | Where-Object { $_ }
        $codes = foreach ($n in $names) { if (-not $vk.ContainsKey($n.ToLower())) { throw "unknown key $n" }; [uint16]$vk[$n.ToLower()] }
        $inputs = @(foreach ($k in $codes) { [W]::Key($k, $false) }) + @(foreach ($k in $codes[($codes.Count - 1)..0]) { [W]::Key($k, $true) })
        $sent = [W]::SendInput([uint32]$inputs.Count, $inputs, [Runtime.InteropServices.Marshal]::SizeOf([type][W+INPUT]))
        "pressed $($names -join '+') ($sent events)"
    }
    'unpin' { $p = App; [void][W]::SetWindowPos($p.MainWindowHandle, [IntPtr](-2), 0, 0, 0, 0, 0x0003); 'no longer on top' }  # HWND_NOTOPMOST
    'size' { $p = App; [void][W]::ShowWindow($p.MainWindowHandle, 9); [void][W]::MoveWindow($p.MainWindowHandle, 40, 40, [int]$a, [int]$b, $true); Start-Sleep -Milliseconds 400; "sized $a x $b" }
    default { 'usage: start | shot f | click x y | rclick x y | drag x1 y1 "x2,y2" | key k | press "ctrl c" | size w h | wheel x y n | unpin | info' }
}
