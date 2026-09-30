# Changelog

What changed in each build of BeDeReader, newest first. The version is on the About screen: **0.1.1 (build 32)**
means version 0.1.1, build number 32. Build numbers only ever go up.

## Unreleased

## 0.1.1 - offline reading and better pages

**Released as build 40, tagged `v0.1.1`** (2026-09-29) - the first public release. Release candidates: build 37
(`v0.1.1-rc.2`) and build 35 (`v0.1.1-rc.1`). Builds 21-26 still showed version 0.1.0.

### Build 46 - 2026-09-30

**Changed**
- The page number after a turn ("12 / 36") now shows in the bottom-left corner instead of the bottom right.
- The reader's **Reader** panel:
  - Its two groups say what they're for: "*Series* · this series" and "This device".
  - Direction is three icons (Auto, left to right, right to left).
  - Page number after a turn, Double-tap to zoom and Keep the screen on can now be changed there mid-book, as well as
    in Settings.
- The **Image** panel's Reset to original, Make default and Use the defaults are buttons under the settings instead of
  a ⋮ menu.

### Build 44 - 2026-09-30

**New**
- **Poster size button** (a grid icon with S, M or L) at the top of Home, libraries, series, collections and read
  lists: Small, Medium or Large posters, the same setting as Settings > Library & Home.

**Changed**
- Settings and the reader panels: the choice buttons on a page are all the same width, lined up on the right.

### Build 43 - 2026-09-30

**Changed**
- **Settings, redesigned** to be easier to take in at a glance:
  - One page at a time. The pages are listed down the side on a wide screen, or across the top on a phone.
  - Every setting is one row: its name on the left, its switch or choices on the right, one short line of explanation
    at most.
  - Each page says once where its settings are kept.
- **The reader's Reader and Image panels** use the same rows.
  - On a wide screen they open from the side, so the page stays in view while you adjust it.
  - Reader: fit is three icons, and the background is three swatches.
  - Image: Enhance and Enhance colours come first. Reset to original, Make these the default and a new **Use the
    defaults**, which drops a series' own settings, are in the ⋮ menu. The panel says whether the series has its own
    settings or follows the defaults.

### Build 42 - 2026-09-30

**New**
- **Double-tap to zoom** (fit screen): double-tap a spot to zoom in on it, double-tap again to zoom back out. To tell
  a double tap from a single one, taps wait a quarter of a second before turning the page or showing the controls;
  switch it off in Settings > Reader for instant taps.
- **Page previews on the slider**: while you pick a page on the slider (by touch, mouse or remote), a small picture of
  it shows over the thumb, with its page number.
- **Volume keys turn pages** (Android): volume down for the next page, volume up for the previous one. With the
  controls showing they change the volume as usual. On by default; switch it off in Settings > Reader.
- New settings, all kept on this device:
  - **'Next book' before the last page** (Settings > Reader): what happens to the book you're leaving - mark it
    read, no change (it stays in progress), or ask (as before).
  - **Background** (Settings > Reader): black, dark grey or white around the page.
  - **Keep the screen on** (Settings > Reader): off, 5, 10, 20 or 30 minutes after the last page turn or touch, or
    always. **Off by default**: until now the screen stayed on for as long as a book was open.
  - **Poster size** (Settings > Library & Home): small, medium or large posters in grids and on Home.
  - **Book posters show** (Settings > Library & Home): "Series #N" and the title, or the title only.
  - **Delete a downloaded book once it's read** (Settings > Downloads): when a book becomes read, here, offline or on
    another device, its download goes. A book open in the reader goes when it's closed.
  - **Reset this device's settings** (Settings > About): everything kept on this device back to the defaults. Synced
    settings, your sign-in and your downloads stay.

**Changed**
- Settings: the Reading card is now two cards. **Reading defaults** holds the defaults synced through Komga; **Reader**
  holds how the reader behaves on this device.
- Page turn animation is now **None / Wipe / Curl** (None was "Instant flip"). Your choice carries over.

### Build 41 - 2026-09-29

**New**
- Series, read list and collection screens show where they sit in the title bar: **Ongoing › Absolute Flash**,
  **Read lists › Civil War**, **Collections › Cosmic**.

**Fixed**
- On the PC, the first Continue reading book showed the keyboard/remote highlight as soon as the app opened. The
  highlight now shows only once an arrow, Tab or Enter key is used, and goes away again with a click or a touch.

### Build 39 - 2026-09-29

**Changed**
- **The app is now called BeDeReader** - a library and reader for Komga.
  Nothing to do: settings, downloads, reading progress and the Android install carry over. On Windows the program
  is now `BeDeReader.exe`, and the files in each release are named `BeDeReader-...`.
- Errors are in plain words everywhere - what happened and what to do - instead of the raw error text: "Can't
  reach Komga at 192.168.1.10:25600. Check you're on your home network and the server is running." A failed action
  names itself ("Couldn't mark "Saga #3" as read: can't reach Komga."), and each message has a **Details** link
  with the technical text (Copy). The last 50 errors are kept in **Settings > About > Error log**.
- If Komga stops accepting the API key (deleted in Komga, say), the app says so and offers **Use downloaded
  books** (they need no key) or **Sign in again**.
- A page that won't load now says why under the icon, and a book that won't open says so instead of spinning.
- Deleting without an admin account in Komga now says that's why, instead of blaming the API key.

**Fixed**
- Offline, the end of a book no longer skips ahead: if the book that comes next in the series or read list isn't
  downloaded, the end card says so and the arrow closes the book (it used to offer the next book that *was*
  downloaded, jumping over the missing ones). Books downloaded before this build still skip ahead in a series until
  they're downloaded again.
- End of book: the next book's poster was blurry (Komga's thumbnails are small). The book's cover page itself now
  replaces it, sharp, fetched ahead as you reach the last pages.

### Build 38 - 2026-09-29

**Fixed**
- With Enhance colours (or Enhance, or Crop edges) on, page turns hitched - most visibly the 3D page curl. The
  pages around the one you're reading are now processed between turns instead of during them, and in every page turn
  animation the next page is ready before you turn to it.
- Sign-in: an address typed without `http://`, or with a space after the colon (the tablet keyboard adds one), no
  longer fails with a "FormatException" - it's tidied up and the field shows the address used. The keyboard's
  word suggestions are off in that field.

### Build 37 - 2026-09-29

**Changed**
- Sign-in: the server field starts empty (with an example); signing in again fills in the last address.
- Android builds are now signed with the project's own release key. Installing one over an earlier test build needs
  that build uninstalled first, once.
- 3D page curl: the page stays attached along its spine - a diagonal drag tilts the curl but no longer peels the
  page up or down from the inside edge.
- 3D page curl: diagonal drags and flicks turn the page more readily, and a quick second swipe while a page is still
  turning turns the next one instead of being ignored.

**Fixed**
- After switching the fit mode through Fit height and back to Fit screen, swiping no longer turned pages.

### Build 36 - 2026-09-29

**Changed**
- Side menu: **App settings** is now **Settings**, and **Info** is now **About**. The server's address, status and
  Retry are in Settings > Server & connection only (About no longer repeats them).
- 3D page curl: only the comic page curls, not the black bars around it.
- 3D page curl: a drag can start anywhere on the screen - the distance to the edge you drag towards is the whole
  turn, so a slow drag from the middle finishes the page too.

### Build 35 - 2026-09-29

**Fixed**
- Licences: the Android version now carries the Apache 2.0 terms for the AndroidX and Kotlin libraries it includes
  (Info > licences page), and the third-party list covers each platform's extra parts. The Windows program's
  copyright line and the web version's title and description no longer show template text.

### Build 33 - 2026-09-29

**New**
- **What's new** and **Read me** in App settings > About and on the Info screen: this changelog, and what the
  app does, how to get started and where your settings live.
- **Third-party software** (App settings > About, and Info): everything the app relies on - libraries, fonts,
  services and build tools - with their licences.
- Komga Reader is now open source under the **MIT licence**. The licences page (Info) also carries AMD's notice for
  the page enhancement and the Material Icons attribution; the Info screen has an AI usage disclosure.

### Build 32 - 2026-09-29

**New**
- **3D page curl** - a third choice for *Page turn animation*. On a slow drag the page's corner follows your finger
  (hold it low to curl from the corner, mid-height to fold straight across); let go past halfway, or flick, and the
  page turns, otherwise it springs back. Taps, arrow keys, the remote and the mouse wheel play the whole curl; going
  back uncurls the previous page over the current one. The back of the page shows the print faintly, as through thin
  paper. Right-to-left books curl the other way. Zoomed in, or on a wide page in fit height, a drag still moves the
  page as before.
- **Crop edges** (Image settings) - cut 0 to 10% off every side of the page, per series (default in App settings >
  Reading), so the art fills more of the screen.

**Changed**
- *Page turn* is now **Page turn animation**, with **Wipe** / **Instant flip** / **3D page curl**. It only changes how
  a page change looks - tapping, swiping and the arrows turn pages the same way in all of them.
- With Instant flip or the page curl, the pages either side of the current one are kept ready, so the one you land
  on shows at once.

**Fixed**
- Opening a book with Enhance colours or Enhance no longer flashes the uncorrected page first - the page waits until
  it's ready. A book's colour measurement is now remembered, so reopening it is instant.

### Build 31 - 2026-09-29

**New**
- **Enhance colours** (Image settings) replaces Auto-levels: as well as balancing the page, it whitens yellowed paper
  and deepens faded ink, while leaving strong colours alone. Series that had Auto-levels on get it automatically.

**Changed**
- **Enhance** now enlarges pages with an edge-aware upscaler (AMD FSR 1), so diagonal lines and lettering stay smooth.

### Build 30 - 2026-09-29

**New**
- **Enhance** (Image settings) replaces Sharpen: the page is cleaned of JPEG speckle and grain, scaled with a
  high-quality filter and sharpened - once per page, on the graphics chip. Tuned on real old scans: lines about 1.2x
  crisper with less grain than no processing at all. Series that had Sharpen on get it automatically.
- **Page number after a turn** - "12 / 36" appears in the bottom-right corner for a moment (can be switched off).
- **Series details** (series menu) - poster, publisher, status, first release, how many books are read, language,
  age rating, genres and tags, summary, and the credits of all its books.
- **Hide from On deck** (book and series menus) - a series never shows there; a book is skipped until it's read.
  App settings shows what's hidden, with *Show all again*. Synced to your other devices.
- **Full screen on the PC**: an X at the right of every top bar leaves full screen.

**Changed**
- **App settings is the one place for every setting**, in sections that say where each is kept (this device, or
  synced through Komga): Server & connection, Reading (defaults for series you haven't adjusted, and *Reset all* for
  those you have), Display, Library & Home, Downloads, About. The reader's own panels are unchanged.
- Side menu: Reader settings and Sign out moved into App settings; tidier labels.

**Fixed**
- Sharpen used to draw pages unfiltered, which made enlarged pages blocky and shrunk pages shimmer.

### Build 29 - 2026-09-29

**Changed**
- **PC full screen is app-wide and remembered**: Esc closes the book and you stay in full screen, the next book opens
  in it, it's restored at start-up, and F11 works on every screen.

**Fixed**
- Closing a book from the end card now marks it read (it could save nothing if you'd just turned past the last page).
- PC: the mouse wheel no longer zooms the page when scrolling up. Ctrl+wheel zooms.

### Build 28 - 2026-09-29

**New**
- **Up next** on the end-of-book card: the next book's poster, number and title ("in the series" or "in this read
  list"), or "End of the series" on the last one.
- **Night mode** is also in App settings, since it tints the library screens too.

### Build 27 - 2026-09-29

**New**
- **Reading progress made offline reaches Komga** when it's back. If Komga changed too (you read on the web, say),
  the further position wins - nothing ever goes backwards or un-finishes - and a message lists those books.
- **Automatic offline mode**: when Komga can't be reached the app offers your downloaded books, and offers to go back
  online when Komga answers again. App settings > *If Komga can't be reached*: Ask first, or Automatic.
- **Downloaded badges** on posters: a blue tick when downloaded, a ring while downloading; series and read lists show
  how many of their books are downloaded.
- Fit width / fit height: a page bigger than the screen opens centred; in fit height a wide page can be dragged
  sideways to see the cut-off parts, and dragging on past its edge turns the page.

### Build 26 - 2026-09-28

**New**
- **Search** (Home and library screens): series, books, read lists and collections as you type. From a library it
  searches that library first; offline it searches your downloads.

**Changed**
- PC: Esc hides the reader's controls, or closes the book when they're hidden.

### Build 25 - 2026-09-28

**New**
- **Dockable side menu**: the pin in its header keeps it open beside the page on wider screens.
- **Pinned views are posters** on Home - a 2x2 of the view's first four items.
- **‹ › buttons** on Home rows to scroll them a screen at a time (mouse and remote friendly).

### Build 24 - 2026-09-28

**New**
- Four optional Home rows: **Recently read**, **Recently added books**, **Recently added series**, **Recent releases**.
- **Arrange Home**: reorder and show/hide every section (Home's ⋮ menu, or App settings).

### Build 23 - 2026-09-28

**Changed**
- Side menu order: Home, then libraries, then offline mode, downloads and the settings.
- A left-to-right swipe anywhere on Home and library screens opens the side menu.
- Offline, empty Home rows say "Nothing downloaded in progress" / "Nothing downloaded on deck".

### Build 22 - 2026-09-28

**New**
- Downloads: **Cancel all**, and **Download** for a multi-selected group of books.

**Fixed**
- Offline, pins with nothing downloaded are hidden, and opening one no longer claims it "no longer exists".

### Build 21 - 2026-09-28

**New**
- **Downloads**: download a book, or a series' / read list's unread or all books. Pages are saved with their place in
  the library, the queue survives restarts, and there's a storage limit (default 10 GB).
- **Downloads screen**: the queue with live progress, pause / resume / cancel / retry, and everything downloaded.
- **Offline mode** switch: the whole app shows just your downloaded books, and nothing contacts the server.
- **App settings** screen.

## 0.1.0-rc.1 - first release candidate

Build 20, tagged `v0.1.0-rc.1`. Everything from the first day of the project.

### Build 20 - 2026-09-28

**New**
- **Right-to-left reading**: follows each series' reading direction in Komga, or a per-series override. Taps, swipes,
  the arrows and the page slider all follow it.
- **Item count** in the header of library, series, collection and read-list screens.
- **Pull down to refresh** everywhere.

**Changed**
- Hide read is an icon-only button.

### Build 19 - 2026-09-28

**New**
- **Sort menu**: pick a field, then the direction. Remembered per library, kept in pins.
- **Series order**: oldest first / newest first.
- **Zoomed-in reading path**: forward steps across then down the page before turning it.
- **Page turn** setting: Swipe or Straight flip.

### Build 18 - 2026-09-28

**New**
- **Windows desktop app**: right-click menus, mouse-wheel page turns, F11 full screen, keyboard shortcuts, remembered
  window size and position.

### Build 17 - 2026-09-28

**New**
- **Info screen**: version, server status with Retry, credits for Komga.

**Fixed**
- The remote's highlight only appears once you press an arrow.

### Build 16 - 2026-09-28

**New**
- **Book details** (summary, credits) and **View series** in the book menu.
- Show or hide each Home section.

### Build 15 - 2026-09-28

**New**
- **Multi-select** for books, with Mark as read / unread and Delete.
- From the leftmost item, Left opens the side menu.

**Changed**
- Bigger, brighter read tick; a strong highlight for the remote everywhere; icon-only reader controls.

### Builds 12-14 - 2026-09-28

**New**
- The app icon.
- **Pins**: pin any library, series, collection or read-list view to Home under your own name. Synced to your
  other devices.

**Fixed**
- Long titles no longer shrink their poster; no yellow frame around the screen after using the remote.

### Builds 6-11 - 2026-09-28

**New**
- **Read-list posters** made of their first four unread books; long-press a series or read list to mark it all read
  or unread.
- **Reader controls, reworked**: a big Close button, fit / night / mark read / delete buttons, previous and next book;
  separate **Reader settings** and **Image settings** panels.
- Remote: Left/Right along a bar of controls, Up/Down between bars.

**Changed**
- Filtering is one **Hide read** toggle (in progress counts as unread). Pinch-zoom no longer turns pages by accident.

### Build 5 - 2026-09-28

**Changed**
- Progress is only saved once you've turned a page; mark read/unread in the reader sticks; *Next book* mid-book asks
  whether to mark it read; clearer "can't reach Komga" errors instead of endless spinners.

### Build 4 - 2026-09-28

**New**
- **Fit modes** (screen, width, height), **image adjustments** (brightness, contrast, sharpen, auto-levels), **night
  mode** and **screen brightness** - remembered per series, synced through Komga.
- Remote: OK shows and hides the reader's controls; Back hides them before closing the book.

### Build 3 - 2026-09-28

**New**
- The screen stays awake while reading; every grid loads more as you scroll.

### Build 2 - 2026-09-28

**New**
- **Home**: Continue reading, On deck and your libraries; a side menu; a better page slider in the reader.

### Build 1 - 2026-09-28

**New**
- The first build: sign in with a Komga API key, browse libraries, series, books, collections and read lists with
  posters, read with touch or a remote page-turner, mark read and unread, delete, and pages that follow the tablet's
  rotation.
