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
- **A completely local mode is a requirement** (user, 2026-10-24): the app must work with no Komga at all, on local libraries only - not only as an add-on to a Komga server.
- **Progress:** kept on the device first. A progress file in the folder itself (shared by the tablet and the PC) comes later.

## Test library

C:\Claude\BeDeReader-TestLibrary (made 2026-10-24, 31 books, 648 MB, copied from the NAS - the NAS only read). Four libraries, one folder per series: Ongoing (modern digital: Absolute Batman, Absolute Martian Manhunter, the one-book Absolute Evil), Golden Age (Atomic Mouse, Plastic Man, Space Western), Spider-Man (Spider-Island - Cloak & Dagger, Spider-Verse Team-Up, The Amazing Spider-Man 1963), Books (EPUBs: Dune, Hitchhiker's Guide, and a _oneshots folder of single novels, as on the NAS - Komga's convention: each file there is its own series).

## Ideas

- A "FolderKomga": a stand-in for Komga answering from a folder, as OfflineKomga does for downloads, so the screens work unchanged.
- Layout: library folder, then one folder per series, then the books. Later: nested folders, loose books, a folder of images as a book.
- Metadata from file names first; then ComicInfo.xml inside the CBZ (title, number, summary, year, manga read right to left) and the EPUB's own. Covers from the first page, cached.
- Scan when the library is added, rescan on refresh, keep the index cached.
- First slice: Windows only, one library added by path, CBZ and EPUB, names only, progress on the device.
- Later sources: OPDS (Kavita, Calibre-Web, Komga itself).

## Findings

### Slice 1 - local mode on Windows (2026-10-24)

- **How it works:** the sign-in screen has a third choice, **No server**: library folders, one per line. Each folder is a library; the folders in it are series (a _oneshots folder's files, and books loose in the library, are each a series of their own). The app then runs on **FolderKomga** (lib\local), a stand-in for Komga built on the offline source that serves downloads, so the screens work unchanged: browsing, filters, sort, search, reading, progress.
- **Scan:** CBZ and EPUB. Issue numbers from file names (after #, else after the series' own name, else the first number), the year from "(2025)", a title after the number ("Dune 02 - Dune Messiah"). EPUBs: title, author and cover from their own metadata. Pages: the CBZ's pictures in natural order, read out of the file where it is (not loaded whole). Posters: each book's first page or cover, made small and kept.
- **Progress:** kept on the device (%LOCALAPPDATA%\KomgaReaderExp\local), found again after a rescan: ids come from the file paths.
- **Settings:** stay on the device (nothing to sync with).
- **The test library:** 31 books scanned and all posters made in 1.5 s.
- **Tried by the user on the PC (2026-10-24):** browsed eBooks and comics, pinned a series, changed settings - no problems seen. The page curl felt a bit laggy against the main build (not measured yet).
- **Not yet (then):** rescanning while the app runs, changing the libraries without signing out - both done in slice 2.

### Slice 2 - the NAS, and libraries in Settings (2026-10-24)

- **Ongoing on the NAS** (\\nick-nas\nas-share\COMICS\Ongoing, read only): 1,644 CBZs in 376 series. The first scan took 70 to 109 s reading one book at a time; read 8 at a time it takes **11 s**. A rescan opens only new and changed files (same size and date: what was read last time is kept): **1.5 s**.
- **A start** shows the last scan at once (kept in index.json) and scans again in the background. The first scan of a library shows its count on the sign-in button ("Reading folders… 640 books").
- **Posters** are made when a tile first shows (3 at a time), not all at the start.
- **Settings > Server and sync**, in local mode: the libraries listed with Rename and Remove, Add a library (a folder; a UNC path works), and Scan again with its count while it runs. Removing a library takes it out of the app only; adding the folder back brings back its progress.
- **Not yet:** screens already open don't refresh by themselves when a background scan finds changes (going back to them, or Home's refresh, shows them).

### Still to do

- Two-page pairing by page size (page sizes aren't read yet), ComicInfo.xml, CBR, Android, local libraries beside Komga's, progress kept in the folder.
