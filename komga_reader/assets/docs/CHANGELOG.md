# Changelog

What changed in each build of Komga Reader, newest first. The version is on the Info screen: **0.1.1 (build 32)**
means version 0.1.1, build number 32. Build numbers only ever go up.

## Unreleased

**New**
- **What's new** and **Read me** in App settings > About and on the Info screen: this changelog, and what the
  app does, how to get started and where your settings live.
- **Third-party software** (App settings > About, and Info): everything the app relies on - libraries, fonts,
  services and build tools - with their licences.
- Komga Reader is now open source under the **MIT licence**. The licences page (Info) also carries AMD's notice for
  the page enhancement and the Material Icons attribution; the Info screen has an AI usage disclosure.

## 0.1.1 - offline reading and better pages

Builds 21-32, on the way to the next release. Builds 21-26 still showed version 0.1.0.

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
