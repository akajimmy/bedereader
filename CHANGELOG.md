# Changelog

Newest first. Build numbers are the `+n` in `komga_reader\pubspec.yaml` and the `build-<n>` git tags.

## Unreleased

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
