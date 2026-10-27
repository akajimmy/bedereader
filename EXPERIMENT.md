# Experimental

Branch **experimental**, in its own folder: C:\Claude\KomgaClient-experimental (a git worktree of C:\Claude\KomgaClient). Restarted 2026-10-27 from 1.7, for trying out wackier things. The pre-1.6 experiment (non-Komga sources, rebuilt in 1.6) is retired: its last state is the tag archive/experimental-sources-pre-1.6 (its notes are in that tag's EXPERIMENT.md).

## The rules here

- This branch is never merged into a version branch as a whole. It may be dropped, or restarted from scratch. Whatever proves itself gets redone on a normal change branch from the development branch, with tests and a CHANGELOG entry.
- Quick prototypes are fine: no CHANGELOG, tests where they help.
- Commits stay local unless the user asks for the branch on GitHub.
- Builds: **tools\build-exp.ps1**, only when the user says to build. No build number, tag or push by itself; the branch's build.ps1 refuses -Bump. An iPhone / iPad build means pushing an exp-build-N tag (TestFlight builds it as BeDeReader Exp) - ask first.
- 1.7 moves on: merge it in when the experiment needs what's new there.

## The experimental app is its own app

Installed beside BeDeReader, never over it, with its own data - and the striped "under construction" icon.

- Android: **BeDeReader Exp**, app ID com.nickp.komga_reader.exp.
- iPhone / iPad: **BeDeReader Exp**, bundle ID com.nickp.bedereader.exp, a TestFlight app of its own, built from exp-build-N tags with N as the build number.
- Windows: Desktop\BeDeReader-Exp, window title "BeDeReader Exp", data in %LOCALAPPDATA%\KomgaReaderExp and %APPDATA%\com.nickp\Komga Reader Exp.
- The update check is off: a BeDeReader release isn't an update to it.
- Changed for that (and so never copied back to a version branch): android\app\build.gradle.kts (applicationId), AndroidManifest.xml (label), the iOS project and Info.plist, the TestFlight workflow's exp-build trigger, windows\runner Runner.rc, main.cpp and desktop_channel.cpp, lib\update_check.dart, the icons (tools\icon.svg, tools\make_icon.py and what it writes), tools\build.ps1 (no -Bump), tools\install-android.ps1 (-Package), tools\build-exp.ps1 (new).

## Ideas

(to be filled in as we go)

## Findings

(what was tried, what worked, what didn't)
