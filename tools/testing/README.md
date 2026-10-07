# Testing helpers

Small scripts for checking builds on real devices. They're developer tools, not part of the app; paths assume the
toolchain in `C:\Dev` (see the main README).

| Script | What it does |
|---|---|
| `tab.py` | Drives the tablet over adb: `list` (labelled elements and their centres), `tap "<label>"`, `xy <x> <y>`, `shot <file.png>`, `key <KEYCODE>`. |
| `taps.py` | Taps to turn pages: `<count> <gap seconds> [back]` - all taps in one adb shell, so short gaps are real. |
| `swipes.py` | Swipes pages: `<count> <gap seconds> [back] [ms per swipe]`. |
| `sf.py` | Frame pacing as the screen saw it (SurfaceFlinger's present times) for a burst of taps or swipes: `taps\|swipes <count> <gap> [back]` - frames shown, missed refreshes, each turn's gaps. |
| `win.ps1` | Drives the Windows app's window: `start`, `info`, `shot <file>`, `click`/`rclick <x> <y>`, `key <SendKeys>`, `wheel <x> <y> -c <notches>`, `size <w> <h>`. Open BeDeReader yourself first: a copy started from a sandboxed session (an MSIX-packaged app such as the Claude desktop app) reads a redirected AppData. |
| `breakcheck_old.sh` | Runs a test file against the `1.2` branch's versions of the named lib files (the unfixed code), then restores them: `breakcheck_old.sh <test> <lib files...>`; set `HOOK=<script.py>` to patch the old files first (e.g. stubs so new tests compile). Commit your work first. |

The EPUB reader's frame timings (frame times, late starts, page-change timer, mirrored to logcat as `epub: ...`) are
compiled in only by a measuring build: `tools\build.ps1 -Bump -Timing`.
