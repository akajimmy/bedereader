# Changelog

What changed in each build of BeDeReader, newest first. The version is on the About screen: **1.2.0 (build 52)**
means version 1.2.0, build number 52. Build numbers only ever go up.

Versions follow the releases' names from 1.2 on: builds after the 1.1 release are 1.2.0 builds, a few of them
become release candidates (`v1.2.0-rc.1`, ...), one becomes the release (`v1.2.0`), and the next build is the
first 1.3.0 build. The 1.1 release was numbered 0.1.1 (tag `v0.1.1`), and the 1.0 line 0.1.0.

## Unreleased

## 1.2.0 - in development

Everything built since the 1.1 release (build 40). Not released yet; no release candidate chosen yet.

### Build 59 - 2026-10-02

**Added**
- Reader, the page slider: while you pick a page, a line marks the page you started from, and a drag that comes close
  to it snaps onto it - so after looking at another page you can get straight back. The mark stays after you jump away
  (the next time you scrub it still shows the page you came from) until you turn a page normally - you're reading on
  from there - or you're back on that page.

### Build 58 - 2026-09-30

**Fixed**
- Settings with the remote: moving Up / Down a row now scrolls it into view - on a page taller than the screen the
  focus could end up below the bottom edge (found auditing the tests).
- On deck: hiding or showing something while offline reaches Komga as soon as the app is back online, not only at the
  next start (as pins and reader settings already did).
- Reader: with Fit height, a page wider than the screen dropping out of the page view (two turns on) made the reader
  rebuild at a moment Flutter doesn't allow - an error in debug builds (found auditing the tests).
- Offline mode (found auditing the tests):
  - Starting the app with offline mode on still asked Komga for the reader settings, pins and On deck hidden, and
    for Home's rows. Nothing is sent now; they load from this device.
  - Switched offline by hand after the "can't reach Komga" prompt, a late answer from Komga still offered "Komga is
    reachable again - Go online".
- Settings with the remote (found auditing the tests):
  - On Library & Home, Up and Down took the rows in the wrong order: up from the first library jumped down to Home
    sections (off the screen), and down from Posters skipped the libraries.
  - A page chosen from the list opened as far down as the page before it had been scrolled.
- Remote and keys: keys saved by older builds could leave no key that shows the reader's controls. Its default keys
  come back now.
- Signing out: coming back to the app afterwards still checked Komga with the old key. The connection and the
  download queue now let go of it.
- Tools (test audit): lint findings now fail the build and CI (they were all let through); a tagged build refuses
  -AllowDirty / -SkipTests, files changed by pub get, and an existing tag; the tablet install checks the tablet reports
  this build and holds this exact APK; the Desktop copy is unpacked fresh and swapped in (the old one kept as
  BeDeReader.previous, files from older builds no longer linger); release.ps1 only tags a build whose BUILD-INFO
  shows tests passed, a clean tree and release signing, and whose files match their checksums.
- A pinned side menu stays open beside a series, a collection and a read list too (it went away on those).
- Reader (from a code review):
  - A second "forward" while the next book was loading (a held key, a double press) opened the book after it and
    marked the one in between read. Page turns and book moves now wait while a book loads.
  - Next book part-way through a series' last book marked it read, then closing saved it back to "in progress".
  - Closing the reader while the next book loaded, or that book failing to open, saved your page to the wrong book.
    The book you're reading now stays current until the next one has loaded.
  - A page curl let go before halfway counted as a page turn (and could un-read a finished book); a tap while it
    sprang back could skip a page. Only finished curls count now, and taps wait for the curl to settle.
  - Going back to a page you'd zoomed into left it zoomed while the reader thought it wasn't (keys and swipes
    misbehaved). A page goes back to fit when you move off it.
  - Reaching the last page marks the book read straight away; after Mark unread there, the tick shows unread.
  - Turning "Override the defaults" on keeps a fit you'd picked for this book from the top bar.
  - A book with no pages crashed the controls. It now says so, with Next book and Close.
- Settings and pins kept in Komga (from a code review):
  - A reader-settings or pin change made while Komga couldn't be reached was lost at the next start (Komga's older
    copy won). It's now kept on the device, sent when Komga answers, and wins until it has been.
  - Series settings removed on another device (Reset all, Use the defaults) now go on this one too.
  - A change made while an earlier one was still being sent could be marked sent without reaching Komga.
  - Signing out now clears the account's pins, reader settings and On deck list from the device, so they can't show
    under - or be sent to - the next account. They come back from Komga when you sign in again.
- Downloads and offline (from a code review):
  - A page cut off mid-download (the app closed or killed) was counted as downloaded and stayed unreadable. Pages
    are now saved whole or not at all.
  - When Komga or the network went away, every queued book failed in turn. Now they wait ("waiting for Komga") and
    carry on by themselves when Komga answers. Offline mode is applied before the queue starts.
  - Pause is kept across a restart (it showed Pause while a book stayed stuck as paused).
  - Each server's downloads are kept apart: signing in to another server deleted the first one's unsent reading
    progress. Today's downloads stay where they are, as the current server's.
  - A deleted series, or one book Komga kept refusing, stopped the offline progress sync for everything after it.
    Now they're skipped; a deleted series' downloads show "no longer on Komga".
  - A page slower than 45 s no longer makes the app think Komga is down (no "go offline?" prompt for it).
  - Delete once read = Ask no longer asks again about a book you chose to keep.
- Screens and the remote (from a code review):
  - Remote and keys: Back (and Esc) in the "press a key" dialog cancel - Back used to be taken as the key, and then
    no longer closed the book. And the only key that shows the controls can't be given away: it says why.
  - Search results update after deleting or marking a book or series from its menu.
  - Deleting a series from its own screen closes that screen.
  - Book details, series details and the documents (What's new, Read me...): the remote's Up / Down scroll the page
    once there's no button that way - long summaries and the changelog couldn't be read past the screen.
  - A read list whose remaining books are in progress no longer shows as read: in progress counts as still to read.
- Windows: the window reopens where it was, at the size it was - with two monitors at different scaling it could come
  back on the other one at the wrong size, and with the taskbar at the top or left it crept each time (code review).
- Tools (code review): release.ps1 no longer glues the next build's heading onto the version note (it would have from
  1.3.0 on); build.ps1 won't commit or tag a -Bump build that isn't signed with the release key, and a failed tablet
  install or Desktop update is reported without stopping the rest.

**Added**
- Download on Wi-Fi only (Settings > Downloads, Android; off by default): on mobile data the queue waits - a book
  part way through keeps its pages - and carries on by itself back on Wi-Fi. The Downloads screen says it's waiting.
- Esc goes back one screen, like the remote's Back (a dialog, a menu or the side menu still closes first; on Home it
  does nothing).
- A downloaded book deleted on Komga is marked "no longer on Komga" on the Downloads screen, as a whole deleted series
  already was. It stays readable until you remove it.
- Going back online fetches the reader settings, pins and On deck hidden from Komga again (changed on another device
  meanwhile, or not fetched at all after starting offline); what was changed on this device is sent first.

### Build 57 - 2026-09-30

**Fixed**
- Moving on from the end card opened the next book on its own end card (so the card showed the book after that),
  instead of at its first page: the page view kept the last book's place. Each book now gets its own.

### Build 56 - 2026-09-30

**Fixed**
- Remote: holding OK on a poster opened its menu and at once pressed the menu's first entry (Details), because the
  held key kept repeating into it. The rest of a held press is now spent on opening the menu.

### Build 55 - 2026-09-30

**Added**
- Page previews setting (Settings > Reader, and the reader's panel): off, the slider shows just the page number
  while you pick a page, and nothing is asked of Komga - for when the link to your books is slow.

**Fixed**
- Page slider previews on a slow server: pages the reader already has (the one showing, its neighbours) preview
  at once, without asking Komga; while a page's picture is on its way the last one is shown faded under a spinner,
  so it isn't taken for this page; and a preview that takes too long no longer tells the app Komga is unreachable.
  (Komga makes each preview from the book file as it's asked: seconds each when the NAS is slow.)

### Build 54 - 2026-09-30

**Fixed**
- Remote in Settings and the reader panels: Up and Down always go to the row above or below, instead of skipping a
  row when a wide control sat over a short one. Home's sections count as a row each.
- Remote and keys: each key is one stop for the remote (it was two: the key, then its ✕).
- Choices beside their labels line up again, one width for the page; choices under their label span the row.
- With Override the defaults off, the choice in force stays highlighted (dimmed), so you can see the default.
- Going round the fits from the top bar a second time left a wide page at the left edge; it's centred every time.
- Page slider: scrubbing back and forth no longer freezes the preview (it asked Komga for every page passed, all at
  once; now only the page under your finger), and the page changes only when you let go.
- A series, a collection or a read list: Left from the leftmost book opens the side menu, as on Home and the libraries
  (a swipe does too). The back arrow stays.
- Home (Continue reading and the rest) could be out of date: it only reloaded when a screen it opened itself closed.
  Now Home, the libraries, series, collections, read lists and search results load afresh whenever they're back on
  top, however you got there (the side menu's Home, say), and when the app comes back into view.

### Build 53 - 2026-09-30

**New**
- **Hold OK on the remote to open an item's menu** (a book, series, read list, collection or pin) - the same menu as
  a long press or a right-click. A short press still opens it.

**Changed**
- **Override the defaults**, at the top of both reader panels' series settings ("Settings for Series: *name*"):
  - Off: the series follows your defaults, and the controls below are greyed out showing the default values. On:
    they're the series' own, starting from the defaults.
  - The Reader panel's covers fit and direction, the Image panel's the image settings - separately. The Image panel's
    Use the defaults button is gone (the toggle does it); Reset to original and Make default show with it on.
  - The top bar's fit button still works either way: for a series with its own layout it changes the series' fit;
    otherwise it changes the fit for this book only, for now (not saved).
  - Series with settings of their own from before keep them (both parts overridden).

### Build 52 - 2026-09-30

**New**
- **Zoom in and zoom out keys** (Remote and keys): + (or =) and - by default, a step each press, in fit screen.
- **Delete a downloaded book once it's read** is now **Never / Ask / Always**. Ask gathers the books you finish
  (here, offline or elsewhere) and asks once, with no book open. Anyone who had it on has Always.

**Changed**
- Accent colours: fourteen stronger colours instead of seven pale ones (your choice carries over, in its stronger
  version).
- **Volume keys turn pages** moved to the Remote and keys page.
- The Image panel's heading reads "Settings for Series: *name*".
- Fit width and fit height use double-headed arrows (↔ ↕).
- Brightness and contrast move in steps of 5, screen brightness and warmth in steps of 5 %.
- Night mode has no line of explanation under it any more.

**Fixed**
- With a remote, you can move off a slider in Settings and the reader's panels (Up and Down go to the next row;
  Left and Right adjust).
- In the reader's side sheets, sliders use the full width, and Keep the screen on no longer runs off the edge.
- A book that stopped for lack of room carries on when space is available - also when you delete a download, not
  only when the limit is raised (the note under the limit said otherwise).

### Build 51 - 2026-09-30

**Changed**
- **Previous book goes back through what you've read**: it returns to the book you read before this one since
  opening the reader (even though it's read now), and after going back, Next retraces forward again - like a
  browser's back and forward. Before the first book of the visit it goes to the previous book - with Hide read on,
  the previous one you haven't read.

### Build 50 - 2026-09-30

**New**
- **Remote and keys** (a new Settings page): choose which keys turn to the next or previous page, show the controls
  and close the book - for remotes that send other keys (media keys, letters). Press **Add** and then the key. A key
  has one job at a time; Show the controls always keeps one key; Reset keys goes back to the usual ones. Moving
  around the controls stays arrows and OK.

### Build 49 - 2026-09-30

**New**
- **Libraries on this device** (Settings > Library & Home): switch off libraries you don't want on this device. They're
  left out everywhere here - the side menu, Home and its rows (Continue reading, On deck...), All libraries, search,
  and offline. It's a per-device tidy-up; Komga's user permissions still decide what an account can see. At least one
  library stays shown.

### Build 48 - 2026-09-30

**New** (Settings > Display)
- **Night mode on a schedule**: on at one time and off at another (21:00 to 07:00 to start with). You can still switch
  it by hand in between; the schedule takes over again at its next change.
- **Text size**: 90 %, 100 %, 115 % or 130 % for this app, on top of the device's own text size.
- **Accent colour**: blue (as before), teal, green, amber, orange, pink or purple, for buttons, switches and
  highlights.

### Build 47 - 2026-09-30

**New**
- **Rotation lock** (Android; Settings > Reader, and the reader's Reader panel): in the reader, follow the device, or
  stay in portrait or landscape - for reading lying down.
- **Clock and battery** in the reader (Settings > Reader), which hides the system's status bar: off, with the controls
  (on the top bar, or just under it on a phone), or always (top right). The battery shows where the device has one.
- **Progress bar** (Settings > Reader): a thin line along the bottom of the page showing how far through the book you
  are, while the controls are hidden (with them up, the page slider shows it).

**Changed**
- **Next book follows Hide read.** Open a book from a series, read list or library with Hide read on, and the next book
  is the next one you haven't read, skipping books already read ("Next unread in the series" at the end of the
  book). Opened with Hide read off, or from Home or search, the next book is simply the next in order, as before.

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

## 0.1.1 - offline reading and better pages (the 1.1 release)

**Released as build 40, tagged `v0.1.1`** (2026-09-29) - the first public release. Release candidates: build 37
(`v0.1.1-rc.2`) and build 35 (`v0.1.1-rc.1`). Builds 21-26 still showed version 0.1.0.
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
