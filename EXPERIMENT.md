# Experimental: non-Komga sources

Branch **experimental/sources**, in its own folder: C:\Claude\KomgaClient-experimental (a git worktree of C:\Claude\KomgaClient). Started 2026-10-24 from 1.5 at RC2 (build 153).

## The rules here

- This branch is never merged into 1.5 as a whole. It may be dropped, or restarted from scratch. Whatever proves itself gets redone on a normal change branch from the development branch, with tests and a CHANGELOG entry.
- Quick prototypes are fine: no CHANGELOG, tests where they help.
- Commits stay local unless the user asks for the branch on GitHub.
- Builds: **tools\build-exp.ps1**, only when the user says to build. No build number, tag, push or TestFlight. The branch's build.ps1 refuses -Bump.

## The experimental app is its own app

- Android: **BeDeReader Exp**, app ID com.nickp.komga_reader.exp, installed beside the real one.
- Windows: Desktop\BeDeReader-Exp, window title "BeDeReader Exp", data in %LOCALAPPDATA%\KomgaReaderExp and %APPDATA%\com.nickp\Komga Reader Exp.
- Changed for that (and so not to be copied back to 1.5): android\app\build.gradle.kts (applicationId), AndroidManifest.xml (label), windows\runner Runner.rc, main.cpp and desktop_channel.cpp, tools\build.ps1 (no -Bump), tools\install-android.ps1 (-Package), tools\build-exp.ps1 (new).

## Decided (2026-10-24 quiz)

- **First folders:** a folder on the NAS and a folder on the PC.
- **Formats:** CBZ and EPUB to stand it up. CBR matters and comes soon after. PDF not asked for.
- **Placement:** local libraries sit beside Komga's, in one library list. Komga stays the main source.
- **Progress:** kept on the device first. A progress file in the folder itself (shared by the tablet and the PC) comes later.

## Ideas

- A "FolderKomga": a stand-in for Komga answering from a folder, as OfflineKomga does for downloads, so the screens work unchanged.
- Layout: library folder, then one folder per series, then the books. Later: nested folders, loose books, a folder of images as a book.
- Metadata from file names first; then ComicInfo.xml inside the CBZ (title, number, summary, year, manga read right to left) and the EPUB's own. Covers from the first page, cached.
- Scan when the library is added, rescan on refresh, keep the index cached.
- First slice: Windows only, one library added by path, CBZ and EPUB, names only, progress on the device.
- Later sources: OPDS (Kavita, Calibre-Web, Komga itself).

## Findings

(what was tried, what worked, what didn't)
