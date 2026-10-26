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

### Found trying slice 2 (2026-10-24)

- The Remove and Add a library icons didn't show: those two glyphs were left out of the icon font the build ships (the other 111 icons used are in it). Now the delete and add icons the app uses elsewhere.
- A pin to a series in a removed library stayed ("0 books"): hidden now in local mode, as offline. The pinned side menu kept removed libraries: reloads now on library changes.
- Books sorted by Date added looked jumbled: the sort is by the file's date (when it was put on the NAS), but the tiles show the release date - and from a file name only the year is known, so every release date shows as 1 January of its year. Real dates need ComicInfo.xml (Year, Month, Day); without one, the tile should show the year only.

- The page curl felt laggier here than in 1.5: measured (perf.log), the same through Komga as from a folder - not local mode. A GPU-heavy game was running meanwhile, and 1.5 then felt laggy too (user, 2026-10-25). On hold until measured without it (main backlog).

### Slice 3 - ComicInfo.xml and page sizes (2026-10-25)

- **ComicInfo.xml** (inside the CBZ, as Komga reads it): the book's title, number, summary, release date (year, month, day), writers, artists and the rest by role; the series' publisher, genres, book count, and manga read right to left. In the first 400 Ongoing books, 155 have one: all with a year, 42 with a full date, only 11 with a writer.
- **Page sizes** (two pages up, a wide page is a spread, alone; a webtoon's strip is laid out by them): from ComicInfo when it lists them (37 of the 400), else read from the start of each picture the first time the book is opened - 0.2 to 0.4 s for a 26-page book on the NAS - and kept. Catwoman #81's 3976-wide spread found so.
- A scan made before this reads its books again once (what's kept from inside a file has a version).

### Slice 4 - local libraries beside Komga's (2026-10-25)

- **Signed in to Komga**, the local libraries (the same ones as local mode's, kept on this device) show beside Komga's: in the side menu, Home's Libraries, the library picker. Settings > Server and sync lists them above Komga's settings, to add, rename, remove and scan.
- **MixedKomga** (lib\local\mixed_komga.dart): the Komga client, with the local libraries answered from their folders. A call about one book, series or library goes to whichever has it - a local book's pages, progress, next book never reach Komga. A view across every library (All libraries, Home's rows, search, the filter panel's lists) asks both and merges them in the order asked for; Komga is asked for everything up to the page shown, so the merged page is right.
- A local book is never downloaded or cached (it's on this device already), nor deleted from the app.
- **Not yet:** offline mode shows the downloads only - the local libraries go with Komga; read lists and collections are Komga's only; pins and series settings on local series sync through Komga to other devices, where those series don't exist.

- **Slices 3 and 4 tried by the user on the PC (2026-10-25):** "looks good".

### Slice 5 - storage: SMB shares and the tablet's own files (2026-10-25)

- **Decided (quiz):** SMB through **dart_smb2** (BSD-3-Clause; a Dart binding of libsmb2, LGPL-2.1; SMB 2.02 to 3.1.1; its build fetches the libsmb2 binary for each platform from the package's GitHub release, checked against pinned SHA-256s). The tablet's folders through **All files access** (an Android permission granted once in Settings: plain paths, the existing code; Google Play restricts it). Share passwords **kept encrypted** on the device, one login per share.
- **One way to write a share everywhere:** \\host\share\folder. Windows reads it itself (with its own login, as before); Android (and iOS later) through the app's SMB client. The same path on every device gives the same book ids - ready for progress shared later.
- **lib\local\storage.dart:** LibraryFs - the device's files (LocalFs) or a share (SmbFs, one connection pool per share). The scan lists through it (a share's listing gives sizes and dates: no stat per file); the CBZ reader reads its directory in one read and each page in one more (round trips matter on a share); EPUBs read whole.
- **Getting at a folder (lib\local\access.dart):** adding a share with no login kept tries it as a guest first (a share open to anyone needs none - user, 2026-10-25); refused, it asks for a user name and password, tries them, and says so if the share refuses those; adding a tablet folder asks for All files access (Open Settings, then "I've allowed it") if it isn't granted.
- The NAS refuses the SMB client without a login (access denied) - the client itself loads and reaches it from Windows.

### Found trying slice 5 on the tablet (2026-10-25)

- \\nick-nas couldn't be found: the network's DNS (the ISP's) doesn't know the NAS; Windows finds it by asking the local network, Android only by DNS - except a .local name (mDNS), which the NAS answers. A bare name DNS doesn't know is now tried as name.local (nick-nas.local, 10.0.0.226 - pinged from the tablet).

### Slice 6 - browsing for a library folder (2026-10-25)

- **Browse for a folder…** on the No server screen (adds a line), and Settings' Add a library opens the browser (with Type a folder… for a typed path).
- **Places:** Android - the device's storage and any card or USB drive (/storage/XXXX-XXXX), after All files access; Windows - the drives; iOS - the app's own folder, which the Files app shows as BeDeReader (Info.plist: UIFileSharingEnabled, LSSupportsOpeningDocumentsInPlace); and the servers the libraries are on, plus Connect to a server….
- **A server's shares:** Android and iOS through the app's SMB client (a guest first; refused, the login is asked for and also used for the share picked); Windows through net view, with Windows's own login.
- **Folders:** the system's own left out (hidden, @Recycle, #recycle, $RECYCLE.BIN); each folder says how many folders and books are in it. Up stops at the place it started from; a share's top goes up to its server's shares.

- **Slices 5 and 6 tried by the user on the tablet (2026-10-25):** in No server mode, connected to the NAS (\\nick-nas, found as nick-nas.local), browsed to the folder, and read from it - "successfully connected, browsed and read".

- **The tablet's own storage, tried over adb (2026-10-25):** the test library copied to /storage/emulated/0/BeDeReader-TestLibrary (31 files, 648 MB). Add a library > This device asked for All files access, Open Settings went straight to the app's page there, and after "I've allowed it" the storage listed (the second time, no asking). Ongoing and Books added: 3 and 5 series; Absolute Batman #10 read (a wide spread shown alone, as measured), Frankenstein's EPUB read. No errors in the log.
- Seen meanwhile, both cosmetic (fixed the same day): the browser's title at the storage's top reads "0" (the last part of /storage/emulated/0) instead of the place's name; Settings in No server mode shows the connection's Retry button, with nothing to retry.

## Punch list (2026-10-25) - in priority order

From the wrap-up list and the code review of 2026-10-25 (the whole experiment against 1.6). Done items move to the findings above; this list is only what's left.

1. **A library that can't be reached keeps its books.** A rescan that can't read a library's folder (a share out of reach, the NAS restarting, away from home) currently empties it from the kept list: the books vanish until a later scan reaches it. Keep the last scan's books for any library that couldn't be read. (Review finding 1; also the ground for local libraries offline, item 6.)
2. **A scan says what it couldn't read.** Today a library or a file that fails is dropped without a word: say so (Settings' local libraries, and the app log), and No server's Open warns when one of several folders has no books. (Review findings 5 and 9.)
3. **Signed in to Komga, the start doesn't wait for a local scan.** With no local scan kept yet, the app waits for a full scan of the local libraries before Home shows. Use what's kept and scan in the background, as local mode does. (Review finding 2.)
4. **Big CBZs (ZIP64).** Archives over 4 GB, or written in ZIP64 form by some tools, are misread and left out. (Review finding 3.)
5. **Open screens refresh** when a background scan finds changes (today: go back, or Home's refresh).
6. **Local libraries in offline mode** (today they go with Komga), on the tablet's own folders and a share at home.
7. **CBR (RAR) comics.**
8. **"All libraries" with local libraries attached pages efficiently** - each page now asks Komga again for every page before it. (Review finding 4.)
9. **A poster that can't be made isn't tried again** each time its tile shows (an EPUB on the share was read whole every time). (Review finding 6.)
10. **Empty pins to local series hidden when signed in to Komga too** (only in No server mode now). (Review finding 7.)
11. **A date known only by its year shows the year**, not "1 January".
12. **iOS:** local mode on the iPad - a share, and the BeDeReader folder in the Files app (screenshots and logs from here over USB).
13. **A whole NAS library on the tablet** (thousands of books): scan time, memory, browsing.
14. **The curl's perf log out** (always on in the experiment; not to go to 1.6). (Review finding 8.)
15. **Into the real app:** redone as change branches with tests and CHANGELOG entries on 1.6.

To consider after that: progress kept in the library folder (shared by the tablet and the PC without Komga); read lists and collections for local books; pins and series settings on local series (they sync through Komga to devices that don't have those series).
