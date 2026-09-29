# Changelog

Newest first. Build numbers are the `+n` in `komga_reader\pubspec.yaml` and the `build-<n>` git tags.

## Unreleased

## Build 26 - 2026-09-28

- Search (button on Home and library screens): Komga's search across series, books, read lists and collections,
  results as you type in poster rows with counts. From a library it searches that library, with a chip for all
  libraries. Offline it searches the downloaded titles.

- Reader: Esc hides the controls if they're showing, otherwise closes the book (leaving full screen with it).

## Build 25 - 2026-09-28

- Home rows have ‹ › buttons at the right of their title (like Plex): each scrolls about a screen's width, greyed at
  the ends; on every device, and reachable with the remote.

- Pinned views on Home are posters: a 2x2 of the first four items of the pinned view (its filter and sort), the
  pin's name and the view's count; long-press / right-click to rename or unpin. Read-list posters share the code.

- Side menu can be docked: the pin in its header keeps it open beside the page (the page shifts right) on screens at
  least 720 wide; the pin again lets it slide away. Remote: Left from the leftmost tile moves into it, Right back.
  Remembered on the device; on narrow screens it always slides out.

## Build 24 - 2026-09-28

- Home: four optional rows - Recently read, Recently added books, Recently added series, Recent releases (off by
  default; each fetched only while shown; offline they show the downloaded books).
- Home sections can be rearranged: App settings > Home and Home's ⋮ > Arrange sections… list every section with its
  switch, ▲▼ buttons (remote) and a drag handle (touch). The ⋮ menu keeps the quick show/hide ticks.

## Build 23 - 2026-09-28

- Side menu order: Home | libraries | Offline mode, Downloads, App settings, Reader settings, Info, Sign out.
- A left-to-right swipe anywhere on Home and library screens opens the side menu (sideways rows still scroll).

- Offline, empty Home rows read "Nothing downloaded in progress" / "Nothing downloaded on deck".

## Build 22 - 2026-09-28

- Downloads screen: Cancel all (asks first) - empties the queue, stops the book downloading; finished downloads stay.
- Multi-select: Download button queues the ticked books in the order picked.
- Offline: pins whose view has nothing downloaded (with the pin's filter) are hidden on Home; reaching one says
  "Nothing from … is downloaded" instead of "no longer exists on the server". Online, that message now has a close
  button besides Unpin.

## Build 21 - 2026-09-28

- Offline mode switch (side menu and App settings): the whole app shows only the downloaded books, with a banner on
  Home and Go online; downloads hold and nothing contacts the server; remembered across restarts.
- Downloads: saves are written safely one after another (a crash can't leave a half-written queue or index), and
  signing out and back in mid-download can't stall the queue.

- Downloads (1.1, part 1 of offline mode): Download / Remove download on a book; Download unread / Download all
  on a series or read list. Books download page by page into app storage with their place in the library (series,
  read lists, collections) and posters; the queue survives restarts and resumes where it stopped.
- Downloads screen (side menu, with a count while books are queued): the queue with live progress (page n of m,
  size), pause / resume, cancel, failed books with the reason and Retry; everything downloaded with sizes and Remove.
- App settings > Downloads: space used and a storage limit (2-100 GB or no limit, default 10 GB). A book that
  would go over the limit stops with a note and carries on when the limit is raised.

- App settings (side menu, above Reader settings): server address with Sign out / change server (asks first),
  and the Home section switches - the same setting as Home's ⋮ menu.

## Build 20 - 2026-09-28

- Header count: the number of items in the current view (with the active filter) in a small box, left of Hide read,
  on library, series, collection and read-list screens.
- Hide read is an icon-only button (crossed-out eye, tinted while read items are hidden).
- Right-to-left reading: follows each series' reading direction in Komga, or a per-series override in Reader
  settings (Auto / Left to right / Right to left). In right-to-left books Left goes forward, the tap zones and
  swipes flip, the page slider runs right to left, the zoomed path starts top-right, fit height starts at the
  right edge. Vertical/webtoon series still read as pages.
- Pull down to refresh everywhere: library, series, collection and read-list grids (also when empty or showing an
  error), book Details, and Home even when its content is short.

## Build 19 - 2026-09-28

- Library sort menu: pick a field (Title, Date added, Date updated, Release date), then the direction
  (A → Z / Z → A, Newest / Oldest first). Remembered per library, kept in pins, reset by Clear filters.
- Series: order toggle in the top bar - oldest first / newest first by issue number. Remembered per series,
  kept in pins.
- Reader, zoomed in: next steps through the page - one screen right, then back to the left edge one screen down
  (clamped at the edges); at the bottom-right corner it turns the page (unzoomed). Back mirrors it. Works for
  arrows, the remote, tap zones, Space and the mouse wheel.
- Reader settings: Page turn - Swipe (slide) or Straight flip (instant). Per device.

## Build 18 - 2026-09-28

- Windows desktop: right-click menus, mouse-wheel page turns (Ctrl+wheel zooms), F11 full-screen reader,
  Space / Shift+Space, remembered window size and position, keep-awake, version and links on the Info screen,
  dimming-only brightness slider, named "Komga Reader" (`KomgaReader.exe`) with the app icon.
- Build pipeline: `tools\build.ps1` builds Android, Windows and web after analyze + tests.

## Build 17 - 2026-09-28

- Info screen: version, author, licence placeholder, server status with Retry, Komga credits.
- App icon beside the name in the side menu.
- The remote highlight on buttons waits for an arrow press (auto-selected buttons no longer look selected).

## Build 16 - 2026-09-28

- Book menu: Details (summary, credits by role, Read / Mark / View series) and View series.
- Home menu: show/hide Continue reading, On deck, Pinned, Libraries.
- Action menus scroll instead of overflowing on short screens.

## Build 15 - 2026-09-28

- Left past the first item opens the side menu; Right closes it.
- Bigger green read tick; strong remote highlight on every button.
- Reader controls icon-only except Close.
- Book menu: Mark as read / Mark as unread / Select multiple / Delete; multi-select in series, read lists and
  library Books mode.

## Builds 1-14 - 2026-09-28

First day: browsing (libraries, series, books, collections, read lists), posters, the reader (fit modes, image
settings, night mode, brightness, remote support, rotation), Home (Continue reading, On deck, pins), per-series
settings synced through Komga, infinite scroll, keep-awake, the app icon. Details in `NOTES.md`.
