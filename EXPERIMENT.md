# Experimental: non-Komga sources

Branch **experimental/sources**, in its own folder: C:\Claude\KomgaClient-experimental (a git worktree of C:\Claude\KomgaClient). Started 2026-10-24 from 1.5 at RC2 (build 153); the main app merged in since, up to **1.6 with the Home-after-closing-a-book fix** (2026-10-25). Last built for the tablet 2026-10-25 (Android only, with punch list items 1 to 7).

## Where it stands (2026-10-25)

- **Works:** No server mode, and local libraries beside Komga's; libraries on the device, a card or USB drive, or an SMB share; CBZ, CBR (RAR4 and RAR5) and EPUB; a folder browser to add them; ComicInfo.xml; page sizes; a library out of reach keeps its books, one deleted is asked about; what a scan couldn't read is reported; open screens refresh after a scan; offline mode keeps the local libraries.
- **Tried on the tablet** (2026-10-25, see Findings): all of that in No server mode, except the parts below.
- **Not tried on a device yet:** signed in to Komga with local libraries beside it, and offline with them (item 6) - needs a sign-in; a share going out of reach after it was added. **iOS** started (2026-10-26, TestFlight): No server mode with the NAS works.
- **Next:** the punch list below, from the top.

## The rules here

- This branch is never merged into the development branch (1.6 now) as a whole. It may be dropped, or restarted from scratch. Whatever proves itself gets redone on a normal change branch from the development branch, with tests and a CHANGELOG entry (punch list, item 15).
- Quick prototypes are fine: no CHANGELOG, tests where they help (each fix is still break-checked).
- Commits stay local unless the user asks for the branch on GitHub.
- Builds: **tools\build-exp.ps1**, only when the user says to build (-Platforms android for the tablet alone). No build number, tag, push or TestFlight. The branch's build.ps1 refuses -Bump.
- iOS (2026-10-26): through TestFlight as its own app, **BeDeReader Exp**, from an **exp-build-N** tag pushed to GitHub (the experiment's copy of testflight.yml; N is the iOS build number, counted on its own from 1). The repository is public: a tag puts this branch's commits there. Each push needs the user's yes.
- The main app is merged in from time to time (merge the development branch here; never the other way).

## The experimental app is its own app

- Android: **BeDeReader Exp**, app ID com.nickp.komga_reader.exp, installed beside the real one.
- Windows: Desktop\BeDeReader-Exp, window title "BeDeReader Exp", data in %LOCALAPPDATA%\KomgaReaderExp and %APPDATA%\com.nickp\Komga Reader Exp.
- Changed for that (and so not to be copied into 1.6): android\app\build.gradle.kts (applicationId), AndroidManifest.xml (label), windows\runner Runner.rc, main.cpp and desktop_channel.cpp, tools\build.ps1 (no -Bump), tools\install-android.ps1 (-Package), tools\build-exp.ps1 (new); for iOS, ios\Runner.xcodeproj\project.pbxproj (bundle ID com.nickp.bedereader.exp), ios\Runner\Info.plist (name), .github\workflows\testflight.yml (exp-build-N tags, the bundle ID, the build number).
- iOS: **BeDeReader Exp**, bundle ID com.nickp.bedereader.exp, its own App Store Connect record and TestFlight; the Files app shows its folder as BeDeReader Exp.
- The version check is off (lib\update_check.dart, UpdateCheck.inThisApp): a BeDeReader release isn't an update to BeDeReader Exp (user, 2026-10-26: "1.5.0 is not an update to exp").

## Decided

- **First folders** (2026-10-24 quiz): a folder on the NAS and a folder on the PC.
- **Formats:** CBZ and EPUB first, then CBR (done 2026-10-25 - the user's library is all CBZ, "but komga should support CBR too"). PDF not asked for.
- **Placement:** local libraries sit beside Komga's, in one library list. Komga stays the main source.
- **A completely local mode is a requirement** (user, 2026-10-24): the app must work with no Komga at all, on local libraries only - not only as an add-on to a Komga server.
- **Each source on its own** (user, 2026-10-25): "local library should always be available. Network libraries should be available as long as the network is reachable, and Komga libraries should be available when Komga is reachable. All of those should be independent of each other, and any combination should be possible."
- **Progress:** kept on the device first. A progress file in the folder itself (shared by the tablet and the PC) comes later.
- **SMB** through dart_smb2; the tablet's folders through All files access; share passwords kept encrypted (slice 5).
- **RAR** through koni_rar, pure Dart (user's pick, 2026-10-25, over a native UnRAR wrapper or a port of our own).

## Test libraries

- C:\Claude\BeDeReader-TestLibrary (made 2026-10-24, 31 books, 648 MB, copied from the NAS - the NAS only read); also on the tablet at /storage/emulated/0/BeDeReader-TestLibrary. Four libraries, one folder per series: Ongoing (modern digital: Absolute Batman, Absolute Martian Manhunter, the one-book Absolute Evil), Golden Age (Atomic Mouse, Plastic Man, Space Western), Spider-Man (Spider-Island - Cloak & Dagger, Spider-Verse Team-Up, The Amazing Spider-Man 1963), Books (EPUBs: Dune, Hitchhiker's Guide, and a _oneshots folder of single novels, as on the NAS - Komga's convention: each file there is its own series).
- On the tablet, /storage/emulated/0/BeDeReader-CBRTest/CBR (2026-10-25): one CBR of each kind, copied from Z:\COMICSEEDING - Expanse (RAR5 compressed), Captain America - Reborn (RAR4, best compression), Shadow War (RAR4 compressed, 4 MB pages), Bone Orchard (RAR stored), Batman Beyond (a zip named .cbr) - plus two files broken on purpose in Expanse (Broken 006.cbz, Cut short 007.cbr). A library in BeDeReader Exp.
- On the tablet, /storage/emulated/0/BeDeReader-MissTest/Lib-away: the folder-gone test's library (two Atomic Mouse CBZs), no longer a library.
- CBRs: the NAS's COMICS has none; Z:\COMICSEEDING has 2,219.

## How it's built

- **FolderKomga** (lib\local\folder_komga.dart): a stand-in for Komga answering from folders, built on the offline source that serves downloads, so the screens work unchanged. **No server** mode runs on it alone.
- **LocalBeside** (lib\local\mixed_komga.dart): the local libraries beside another source - every call about a local book, series or library goes to the folders, views across every library ask both and merge. On the Komga client (**MixedKomga**, signed in) and on the offline source (**OfflineBeside**, offline: the downloads and the local libraries).
- **The scan** (lib\local\folder_scan.dart): one folder per series, _oneshots and loose books each their own; CBZ, CBR and EPUB; names, ComicInfo.xml, EPUB metadata; kept in index.json and rescanned in the background. What it couldn't read, and why, per library (LibraryScan).
- **Storage** (lib\local\storage.dart): the device's own files, or an SMB share through dart_smb2 (Android, iOS).
- **Comic archives, read in place** (lib\local\file_zip.dart, file_rar.dart): ComicArchive opens FileZip or FileRar by the file's first bytes. FileRar decodes in a background isolate, its file reads done in the app's own; koni_rar is vendored in komga_reader\third_party\koni_rar (one addition, readHead).
- **The folder browser** (lib\local\folder_browser.dart) and getting at a folder (lib\local\access.dart: share logins, Android's All files access).
- **The missing-folder question** (lib\local\missing_prompt.dart), asked from main.dart whenever a scan finds one.

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

### Tried on the tablet, slices 5 and 6 (2026-10-25)

- **By the user:** in No server mode, connected to the NAS (\\nick-nas, found as nick-nas.local), browsed to the folder, and read from it - "successfully connected, browsed and read".
- **The tablet's own storage, over adb:** Add a library > This device asked for All files access, Open Settings went straight to the app's page there, and after "I've allowed it" the storage listed (the second time, no asking). Ongoing and Books added: 3 and 5 series; Absolute Batman #10 read (a wide spread shown alone, as measured), Frankenstein's EPUB read. No errors in the log.
- Seen meanwhile, both cosmetic and fixed the same day: the browser's title at the storage's top read "0" (the last part of /storage/emulated/0); Settings in No server mode showed the connection's Retry button, with nothing to retry.

### The code review (2026-10-25)

- The whole experiment against 1.6 (about 2,400 lines, 26 files), nine findings - all on the punch list (items 1, 2, 3, 4, 8, 9, 10, 14). The SMB client reconnects by itself after a dropped connection (checked in dart_smb2).

### Tried on the tablet, items 1 to 7 (2026-10-25, over adb)

The full write-up: C:\Claude\KomgaClient\reports\10-25-exp-tablet-test.md. No server mode, libraries Archive (the NAS), Ongoing, Books, and the CBR test library added for it.

- **CBR:** all five kinds listed with posters and read. First opens (page sizes read then, and kept): Shadow War, 43 pages of 4 MB, 2.8 s; the others 0.9 to 1.2 s; the zip named .cbr 0.5 s. Pages were ready at each tap; 12 turns 0.7 s apart missed one refresh in all - the decoding doesn't show on the screen.
- **The NAS:** Crossover #1 from Archive opened in 0.75 s, a double-page spread shown alone.
- **Folder gone (item 1):** asked; Keep it - not asked on the next scan, the book kept, Settings' line "Not found on the last scan (it looks deleted)"; folder back with a book added - read again, the line gone, the library view underneath showed both books on its own (item 5); gone again - asked again; Remove took the library off.
- **Scan report (item 2):** a broken .cbz shown under the library in Settings and listed with why, and in the app log.
- **Home** after closing a book: the book at the head of Continue reading at once. An EPUB from a local library read.
- **Found:** punch list 16 to 20. **Not tried:** item 6 (needs a sign-in to Komga); a share going out of reach after it was added (adb runs over the same Wi-Fi).

### Punch list done

- **1. A library that can't be reached keeps its books** (2026-10-25). A rescan that can't read a library's folder - out of reach, refused, or cut off part-way - keeps that library's books from the scan before, and says so in the app log; files gone from a library that could be read still go.
  - **Out of reach or deleted?** (user, 2026-10-25) When the folder isn't there, the place it was in is asked: a share that answers (SMB), or any folder above it that's there - a drive, the device's storage, a share's top on Windows, where a share out of reach looks the same as a missing folder. The place answering: the folder **looks deleted**, and the user is asked "Library folder not found - Remove the library?" **Remove**: the library and its books go. **Keep it**: treated as out of reach - not asked again (kept on the device), and once the folder is back the next scan reads it; gone again later, asked again. The place not answering: out of reach, the books kept, nothing asked.
  - **File by file too** (user, 2026-10-25): a file the scan couldn't read because the share or the network stopped answering - a share dropping part-way, after the listing - keeps its book from the last scan; it lost every book after the drop. A file is only left out (not in the app after that scan; the file itself untouched, its progress kept, back once it can be read) when it's damaged - not a zip, a broken one, a format not read yet - or gone since the folder was listed.
  - Tests: a share that doesn't answer (books kept, nothing asked); the folder moved away (asked; Keep, back, gone again, Remove); the question's Remove and Keep (break-checked: item 1 alone never asked); listed but no file read (books kept), a damaged CBZ (left out) - break-checked: the old scan lost them all.
  - Tried on the tablet (2026-10-25): asked, Keep, back, gone again, Remove - as above.

- **2. A scan says what it couldn't read** (2026-10-25).
  - **The app log:** one line per library per scan, however many files - a share dropping can be thousands (user, 2026-10-25): the count by reason (didn't answer, kept from the scan before; damaged or not readable yet, left out; gone since listed, left out), and at most five of the files left out by name ("... and 2 more"). A library not reached: "couldn't be reached" or "not found (it looks deleted)".
  - **Settings > local libraries:** that line under the library's path; a tap lists every file left out, with why.
  - **No server's Open:** a folder with no books among several is named - "(not found)" or "(couldn't be reached)" where known - and nothing is opened or saved until the line is corrected or taken out (it was saved as an empty library without a word).
  - Tests: seven damaged CBZs (one log line, five names; all seven in Settings); two folders, one empty (named, nothing saved) - break-checked against the code before. (The No server test first passed without Open getting anywhere - the scan can't run inside the test's fake time; it now scans beforehand.)
  - Tried on the tablet (2026-10-25): a broken .cbz - the line, the list, the log line.

- **3. Signed in to Komga, the start doesn't wait for a local scan** (2026-10-25). With no local scan kept yet (a library just added, the kept scan lost), the start waited for the whole first scan before Home showed - 11 s and more on the NAS, longer with a share out of reach. Now the local libraries are attached at once and scanned in the background: Home shows Komga's books meanwhile, and the local ones come in when the scan is done (Home and the side menu already listen for that). No server mode still waits on its very first scan - there's nothing else to show. Test: the first look at the folder held back - attached at once, its books in once let go (break-checked: the old start waited, timed out). With that, a background scan's failure is now logged instead of left unhandled: the suite's double start (signed out and in again quickly) had two scans saving the kept scan at once, and one found the file busy.

- **5. Open screens refresh** (2026-10-25). A scan that changed something - books added, changed or gone, a library renamed, added or removed - reloads the library views open: the one on top at once, the others when they're back on top (the views' own refresh-on-return, which every library view has: Home, a library, a series, a collection, a read list, Search). A scan that found nothing new - every start's, mostly - reloads nothing. Tests: the view on top and the one underneath; a scan with nothing new, then one with a book added (break-checked). Tried on the tablet (2026-10-25): a book added, the library view underneath Settings showed it on return.

- **6. Each source there whenever it can be reached** (2026-10-25; the user's words under Decided). Offline - by hand, or after "Can't reach Komga" - the local libraries now stay beside the downloaded books: listed, read, and their place saved, Komga not asked (offline was the downloads alone). A share's library is read while the share answers, Komga or not; one out of reach keeps its books (item 1). The "Can't reach Komga" and "key not accepted" prompts offer going offline when there are local books, even with nothing downloaded, and name what's there ("your downloaded books and your local libraries"); the key prompt's button is now "Read offline". Settings' server line says "showing downloaded books and the local libraries". The code: the routing that put local books beside Komga's is shared by the online and the offline source (LocalBeside). Tests: offline, a download and a local book listed together, the local one read and its place saved with nothing sent to Komga; nothing downloaded but local books, going offline offered - both break-checked. **Not tried on a device yet** (punch list 20).

- **7. CBR comics** (2026-10-25). A .cbr in a local library is a book like a CBZ: listed, its pages read in place (on the device or a share), a page's size from its start. RAR4 and RAR5, stored or compressed, solid too; a .cbr that's a zip inside is read as a zip (which one is told by the file's first bytes, not its name).
  - **What's out there:** the 2,219 CBRs in Z:\COMICSEEDING (none in COMICS) - 89% RAR4 compressed, 5% RAR5 compressed, 10% stored, 1 a renamed zip. None solid.
  - **The decoder:** koni_rar 0.9.0 (pure Dart, MIT - every platform, nothing native), its source read first (no network, processes or native code). Vendored with one addition, readHead: a page's first 64 KB decoded alone, for its size - on the PC about 10 ms a page against 67 ms for the whole one, network reads included.
  - **Off the screen's thread:** compressed RAR decodes at 30-40 MB/s on the PC (zlib's CBZ pages are native and far faster), up to 125 ms for one big page - so the decoding runs in a background isolate, one for all the CBRs open, gone when none is. The file reads it needs are done in the app's own isolate, where a share's connection lives; a share that stops answering fails the read as the share's error, so the scan keeps the book (item 1), not "damaged".
  - **Checked on real files:** 98 of the COMICSEEDING CBRs (80 at random plus each kind's examples): 97 RAR, all 5,208 pages decoded with matching CRCs, every 64 KB start the same as the whole page's; the renamed zip skipped there (the app reads it as a zip).
  - Tests: a stored RAR4 (written by the tests), RAR5 pages, a RAR4 through its x86 filter and one in a solid RAR4 (koni_rar's own fixtures): read whole and by their start; a .cbr that's a zip; a share dropping part-way; a library with two CBRs - listed, their pages' sizes, a page read. Break-checked: the scan not listing .cbr, every comic opened as a zip, a share's failure passed on as a damaged file - each fails its test.
  - Tried on the tablet (2026-10-25): see Findings - smooth; a CBR cut short got in as a book (punch list 16).

## Punch list - in priority order (updated 2026-10-25)

From the wrap-up list, the code review and the tablet test. Done items move to "Punch list done" above; this list is only what's left. Numbers stay with their items.

- **16. A CBR cut short is let in as a book.** One with only its first 4 KB was listed with 1 page, and opening it says "This page didn't load" (UnexpectedEofException: "entry data extends past the end of the archive"). koni_rar lists the headers it finds and stops at the end of the file without an error: the scan should check each entry's data is inside the file, and leave it out as damaged otherwise.
- **17. A share that doesn't answer asks for a login.** Typing a folder on an address with nothing there opened "Sign in to \\10.0.0.254\x" with "Couldn't reach the share (connection) ... Socket connect failed with 113" above the user name and password. A login can't help: say it can't be reached, with Retry; ask for the login only when a share refuses.
- **8. "All libraries" with local libraries attached pages efficiently** - each page now asks Komga again for every page before it. (Review finding 4.)
- **9. A poster that can't be made isn't tried again** each time its tile shows (an EPUB on the share was read whole every time). (Review finding 6.)
- **10. Empty pins to local series hidden when signed in to Komga too** (only in No server mode now). (Review finding 7.)
- **11. A date known only by its year shows the year**, not "1 January" (seen again on the tablet: "1 Jan 2023").
- **18. A leading number in a file name is taken as the issue:** "021 - Captain America - Reborn 01.cbr" is #21; it's issue 1. And a book numbered by its place (no number in its name) counts the files left out beside it: "Expanse_DragonTooth_005_DIGITAL" went from #1 to #3 when two broken files were put next to it.
- **19. Wording in the log:** the reader says "from Komga" in No server mode ("opened ... (DIVINA, 43 pages, from Komga)"); a CBR's failure reads "FormatException: FormatException: UnexpectedEofException ...".
- **20. Item 6 on a device:** signed in to Komga with local libraries beside it - then offline by hand, and Komga out of reach: the local books still listed and read. Needs a sign-in (the user's API key).
- **12. iOS:** local mode on the iPad - a share, and the BeDeReader folder in the Files app (screenshots and logs from here over USB). **Started 2026-10-26** with TestFlight build exp-build-1: in No server mode the user added Ongoing from the NAS, the whole scan ran, and a book read - "a success". Left: the Files app's folder, CBR, the missing-folder question, offline beside Komga.
- **13. A whole NAS library on the tablet** (thousands of books): scan time, memory, browsing. Also a share going out of reach after it was added (needs the NAS off, or the tablet away from home - adb runs over the same Wi-Fi).
- **14. The curl's perf log out** (always on in the experiment; not to go to 1.6). (Review finding 8.)
- **15. Into the real app:** redone as change branches with tests and CHANGELOG entries on 1.6.
- **4. Big CBZs (ZIP64) - only if one turns up** (moved last, user's call 2026-10-25). A sample of the NAS's CBZs (1,116: up to 200 from each COMICS folder - Archive, Events, Manga, Ongoing, Simpsons & Futurama, all of Demo Library and Webtoons) found none in ZIP64 form, and none over 4 GB. One that turns up shows in the log and Settings as "damaged or not readable yet" (item 2). About 40 lines in FileZip if it's ever needed. (Review finding 3.)

To consider after that: progress kept in the library folder (shared by the tablet and the PC without Komga); read lists and collections for local books; pins and series settings on local series (they sync through Komga to devices that don't have those series); nested folders and a folder of pictures as a book; other sources (OPDS: Kavita, Calibre-Web, Komga itself).
