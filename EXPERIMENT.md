# Experimental: non-Komga sources

Branch **experimental/sources**, in its own folder: C:\Claude\KomgaClient-experimental (a git worktree of C:\Claude\KomgaClient). Started 2026-10-24 from 1.5 at RC2 (build 153); the main app merged in since, up to **1.5.0 as released, through 1.6** (2026-10-25).

## The rules here

- This branch is never merged into the development branch (1.6 now) as a whole. It may be dropped, or restarted from scratch. Whatever proves itself gets redone on a normal change branch from the development branch, with tests and a CHANGELOG entry (punch list, item 15).
- Quick prototypes are fine: no CHANGELOG, tests where they help (each fix is still break-checked).
- Commits stay local unless the user asks for the branch on GitHub.
- Builds: **tools\build-exp.ps1**, only when the user says to build. No build number, tag, push or TestFlight. The branch's build.ps1 refuses -Bump.
- The main app is merged in from time to time (merge the development branch here; never the other way).

## The experimental app is its own app

- Android: **BeDeReader Exp**, app ID com.nickp.komga_reader.exp, installed beside the real one.
- Windows: Desktop\BeDeReader-Exp, window title "BeDeReader Exp", data in %LOCALAPPDATA%\KomgaReaderExp and %APPDATA%\com.nickp\Komga Reader Exp.
- Changed for that (and so not to be copied into 1.6): android\app\build.gradle.kts (applicationId), AndroidManifest.xml (label), windows\runner Runner.rc, main.cpp and desktop_channel.cpp, tools\build.ps1 (no -Bump), tools\install-android.ps1 (-Package), tools\build-exp.ps1 (new).

## Decided (2026-10-24 quiz)

- **First folders:** a folder on the NAS and a folder on the PC.
- **Formats:** CBZ and EPUB to stand it up. CBR matters and comes soon after. PDF not asked for.
- **Placement:** local libraries sit beside Komga's, in one library list. Komga stays the main source.
- **A completely local mode is a requirement** (user, 2026-10-24): the app must work with no Komga at all, on local libraries only - not only as an add-on to a Komga server.
- **Progress:** kept on the device first. A progress file in the folder itself (shared by the tablet and the PC) comes later.

## Test library

C:\Claude\BeDeReader-TestLibrary (made 2026-10-24, 31 books, 648 MB, copied from the NAS - the NAS only read); also on the tablet at /storage/emulated/0/BeDeReader-TestLibrary. Four libraries, one folder per series: Ongoing (modern digital: Absolute Batman, Absolute Martian Manhunter, the one-book Absolute Evil), Golden Age (Atomic Mouse, Plastic Man, Space Western), Spider-Man (Spider-Island - Cloak & Dagger, Spider-Verse Team-Up, The Amazing Spider-Man 1963), Books (EPUBs: Dune, Hitchhiker's Guide, and a _oneshots folder of single novels, as on the NAS - Komga's convention: each file there is its own series).

## How it's built

- **FolderKomga** (lib\local\folder_komga.dart): a stand-in for Komga answering from folders, built on the offline source that serves downloads, so the screens work unchanged. **No server** mode runs on it alone.
- **MixedKomga** (lib\local\mixed_komga.dart): signed in to Komga, the Komga client with the local libraries answered from their folders.
- **The scan** (lib\local\folder_scan.dart): one folder per series, _oneshots and loose books each their own; CBZ and EPUB; names, ComicInfo.xml, EPUB metadata; kept in index.json and rescanned in the background.
- **Storage** (lib\local\storage.dart): the device's own files, or an SMB share through dart_smb2 (Android, iOS); FileZip reads a CBZ in place.
- **The folder browser** (lib\local\folder_browser.dart) and getting at a folder (lib\local\access.dart: share logins, Android's All files access).

## Findings

### Slice 1 - local mode on Windows (2026-10-24)

- **How it works:** the sign-in screen has a third choice, **No server**: library folders, one per line. Each folder is a library; the folders in it are series (a _oneshots folder's files, and books loose in the library, are each a series of their own). Browsing, filters, sort, search, reading and progress work unchanged.
- **Scan:** CBZ and EPUB. Issue numbers from file names (after #, else after the series' own name, else the first number), the year from "(2025)", a title after the number ("Dune 02 - Dune Messiah"). EPUBs: title, author and cover from their own metadata. Pages: the CBZ's pictures in natural order, read out of the file where it is (not loaded whole). Posters: each book's first page or cover, made small and kept.
- **Progress:** kept on the device (%LOCALAPPDATA%\KomgaReaderExp\local), found again after a rescan: ids come from the file paths.
- **Settings:** stay on the device (nothing to sync with).
- **The test library:** 31 books scanned and all posters made in 1.5 s.
- **Tried by the user on the PC (2026-10-24):** browsed eBooks and comics, pinned a series, changed settings - no problems seen.

### Slice 2 - the NAS, and libraries in Settings (2026-10-24)

- **Ongoing on the NAS** (\\nick-nas\nas-share\COMICS\Ongoing, read only): 1,644 CBZs in 376 series. The first scan took 70 to 109 s reading one book at a time; read 8 at a time it takes **11 s**. A rescan opens only new and changed files (same size and date: what was read last time is kept): **1.5 s**.
- **A start** shows the last scan at once (kept in index.json) and scans again in the background. The first scan of a library shows its count on the sign-in button ("Reading folders… 640 books").
- **Posters** are made when a tile first shows (3 at a time), not all at the start.
- **Settings > Server and sync**, in local mode: the libraries listed with Rename and Remove, Add a library, and Scan again with its count while it runs. Removing a library takes it out of the app only; adding the folder back brings back its progress.

### Found trying slice 2 (2026-10-24)

- The Remove and Add a library icons didn't show: those two glyphs were left out of the icon font the build ships. Now the delete and add icons the app uses elsewhere.
- A pin to a series in a removed library stayed ("0 books"): hidden now in local mode, as offline (beside Komga: punch list 10). The pinned side menu kept removed libraries: reloads now on library changes.
- Books sorted by Date added looked jumbled: the sort is by the file's date (when it was put on the NAS), but the tiles show the release date - and from a file name only the year is known, so every release date shows as 1 January of its year (punch list 11).
- The page curl felt laggier here than in 1.5: measured (perf.log), the same through Komga as from a folder - not local mode. A GPU-heavy game was running meanwhile (user, 2026-10-25); on hold until measured without it (main backlog). The wasted decodes it found were fixed in 1.5 (build 154).

### Slice 3 - ComicInfo.xml and page sizes (2026-10-25)

- **ComicInfo.xml** (inside the CBZ, as Komga reads it): the book's title, number, summary, release date (year, month, day), writers, artists and the rest by role; the series' publisher, genres, book count, and manga read right to left. In the first 400 Ongoing books, 155 have one: all with a year, 42 with a full date, only 11 with a writer.
- **Page sizes** (two pages up, a wide page is a spread, alone; a webtoon's strip is laid out by them): from ComicInfo when it lists them (37 of the 400), else read from the start of each picture the first time the book is opened - 0.2 to 0.4 s for a 26-page book on the NAS - and kept.
- A scan made before this reads its books again once (what's kept from inside a file has a version).

### Slice 4 - local libraries beside Komga's (2026-10-25)

- **Signed in to Komga**, the local libraries (the same ones as local mode's, kept on this device) show beside Komga's: in the side menu, Home's Libraries, the library picker. Settings > Server and sync lists them above Komga's settings, to add, rename, remove and scan.
- A call about one book, series or library goes to whichever has it - a local book's pages, progress, next book never reach Komga. A view across every library (All libraries, Home's rows, search, the filter panel's lists) asks both and merges them in the order asked for.
- A local book is never downloaded or cached (it's on this device already), nor deleted from the app.
- **Tried by the user on the PC (2026-10-25)**, with slice 3: "looks good".

### Slice 5 - storage: SMB shares and the tablet's own files (2026-10-25)

- **Decided (quiz):** SMB through **dart_smb2** (BSD-3-Clause; a Dart binding of libsmb2, LGPL-2.1; SMB 2.02 to 3.1.1; its build fetches the libsmb2 binary for each platform from the package's GitHub release, checked against pinned SHA-256s). The tablet's folders through **All files access** (an Android permission granted once in Settings: plain paths; Google Play restricts it). Share passwords **kept encrypted** on the device, one login per share.
- **One way to write a share everywhere:** \\host\share\folder. Windows reads it itself (with its own login); Android (and iOS) through the app's SMB client. The same path on every device gives the same book ids - ready for progress shared later.
- The scan lists through the storage (a share's listing gives sizes and dates: no stat per file); the CBZ reader reads its directory in one read and each page in one more (round trips matter on a share); EPUBs read whole.
- **Getting at a folder:** adding a share with no login kept tries it as a guest first (user, 2026-10-25); refused, it asks for a user name and password and tries them; adding a tablet folder asks for All files access (Open Settings, then "I've allowed it") if it isn't granted.
- \\nick-nas couldn't be found from the tablet: the network's DNS (the ISP's) doesn't know the NAS; Windows asks the local network, Android only DNS - except a .local name (mDNS), which the NAS answers. A bare name DNS doesn't know is now tried as name.local (nick-nas.local, 10.0.0.226).
- The NAS takes the user's own login (it refuses a guest).

### Slice 6 - browsing for a library folder (2026-10-25)

- **Browse for a folder…** on the No server screen (adds a line), and Settings' Add a library opens the browser (with Type a folder… for a typed path).
- **Places:** Android - the device's storage and any card or USB drive (/storage/XXXX-XXXX), after All files access; Windows - the drives; iOS - the app's own folder, which the Files app shows as BeDeReader (Info.plist: UIFileSharingEnabled, LSSupportsOpeningDocumentsInPlace); and the servers the libraries are on, plus Connect to a server….
- **A server's shares:** Android and iOS through the app's SMB client (a guest first; refused, the login is asked for and also used for the share picked); Windows through net view, with Windows's own login.
- **Folders:** the system's own left out (hidden, @Recycle, #recycle, $RECYCLE.BIN); each folder says how many folders and books are in it. Up stops at the place it started from; a share's top goes up to its server's shares.

### Tried on the tablet (2026-10-25)

- **Slices 5 and 6, by the user:** in No server mode, connected to the NAS (\\nick-nas, found as nick-nas.local), browsed to the folder, and read from it - "successfully connected, browsed and read".
- **The tablet's own storage, over adb:** Add a library > This device asked for All files access, Open Settings went straight to the app's page there, and after "I've allowed it" the storage listed (the second time, no asking). Ongoing and Books added: 3 and 5 series; Absolute Batman #10 read (a wide spread shown alone, as measured), Frankenstein's EPUB read. No errors in the log.
- Seen meanwhile, both cosmetic and fixed the same day: the browser's title at the storage's top read "0" (the last part of /storage/emulated/0); Settings in No server mode showed the connection's Retry button, with nothing to retry.

### The code review (2026-10-25)

- The whole experiment against 1.6 (about 2,400 lines, 26 files), nine findings - all on the punch list below (items 1, 2, 3, 4, 8, 9, 10, 14). The SMB client reconnects by itself after a dropped connection (checked in dart_smb2).

### Punch list done

- **1. A library that can't be reached keeps its books** (2026-10-25). A rescan that can't read a library's folder - out of reach, refused, or cut off part-way - keeps that library's books from the scan before, and says so in the app log; files gone from a library that could be read still go.
  - **Out of reach or deleted?** (user, 2026-10-25) When the folder isn't there, the place it was in is asked: a share that answers (SMB), or any folder above it that's there - a drive, the device's storage, a share's top on Windows, where a share out of reach looks the same as a missing folder. The place answering: the folder **looks deleted**, and the user is asked "Library folder not found - Remove the library?" **Remove**: the library and its books go. **Keep it**: treated as out of reach - not asked again (kept on the device), and once the folder is back the next scan reads it; gone again later, asked again. The place not answering: out of reach, the books kept, nothing asked.
  - **File by file too** (user, 2026-10-25): a file the scan couldn't read because the share or the network stopped answering - a share dropping part-way, after the listing - keeps its book from the last scan; it lost every book after the drop. A file is only left out (not in the app after that scan; the file itself untouched, its progress kept, back once it can be read) when it's damaged - not a zip, a broken one, a format not read yet - or gone since the folder was listed.
  - Tests: a share that doesn't answer (books kept, nothing asked); the folder moved away (asked; Keep, back, gone again, Remove); the question's Remove and Keep (break-checked: item 1 alone never asked); listed but no file read (books kept), a damaged CBZ (left out) - break-checked: the old scan lost them all.

- **2. A scan says what it couldn't read** (2026-10-25).
  - **The app log:** one line per library per scan, however many files - a share dropping can be thousands (user, 2026-10-25): the count by reason (didn't answer, kept from the scan before; damaged or not readable yet, left out; gone since listed, left out), and at most five of the files left out by name ("... and 2 more"). A library not reached: "couldn't be reached" or "not found (it looks deleted)".
  - **Settings > local libraries:** that line under the library's path; a tap lists every file left out, with why.
  - **No server's Open:** a folder with no books among several is named - "(not found)" or "(couldn't be reached)" where known - and nothing is opened or saved until the line is corrected or taken out (it was saved as an empty library without a word).
  - Tests: seven damaged CBZs (one log line, five names; all seven in Settings); two folders, one empty (named, nothing saved) - break-checked against the code before. (The No server test first passed without Open getting anywhere - the scan can't run inside the test's fake time; it now scans beforehand.)

- **3. Signed in to Komga, the start doesn't wait for a local scan** (2026-10-25). With no local scan kept yet (a library just added, the kept scan lost), the start waited for the whole first scan before Home showed - 11 s and more on the NAS, longer with a share out of reach. Now the local libraries are attached at once and scanned in the background: Home shows Komga's books meanwhile, and the local ones come in when the scan is done (Home and the side menu already listen for that). No server mode still waits on its very first scan - there's nothing else to show. Test: the first look at the folder held back - attached at once, its books in once let go (break-checked: the old start waited, timed out). With that, a background scan's failure is now logged instead of left unhandled: the suite's double start (signed out and in again quickly) had two scans saving the kept scan at once, and one found the file busy.

- **5. Open screens refresh** (2026-10-25). A scan that changed something - books added, changed or gone, a library renamed, added or removed - reloads the library views open: the one on top at once, the others when they're back on top (the views' own refresh-on-return, which every library view has: Home, a library, a series, a collection, a read list, Search). A scan that found nothing new - every start's, mostly - reloads nothing. Tests: the view on top and the one underneath; a scan with nothing new, then one with a book added (break-checked).

## Punch list (2026-10-25) - in priority order

From the wrap-up list and the code review. Done items move to "Punch list done" above; this list is only what's left.
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
4. **Big CBZs (ZIP64) - only if one turns up** (moved last, user's call 2026-10-25). A sample of the NAS's CBZs (1,116: up to 200 from each COMICS folder - Archive, Events, Manga, Ongoing, Simpsons & Futurama, all of Demo Library and Webtoons) found none in ZIP64 form, and none over 4 GB. One that turns up shows in the log and Settings as "damaged or not readable yet" (item 2). About 40 lines in FileZip if it's ever needed. (Review finding 3.)

To consider after that: progress kept in the library folder (shared by the tablet and the PC without Komga); read lists and collections for local books; pins and series settings on local series (they sync through Komga to devices that don't have those series); nested folders and a folder of pictures as a book; other sources (OPDS: Kavita, Calibre-Web, Komga itself).
