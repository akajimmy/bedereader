# Komga Reader

A comic reader for your own [Komga](https://komga.org) server - for an Android tablet or phone, a Windows PC, or a
web browser. Browse your libraries with proper posters, read with touch, keyboard, mouse or a remote page-turner,
take books with you offline, and make old scans look their best.

Komga Reader is a client: your comics, reading progress, read lists and collections all stay on the Komga server.
This app shows them and keeps everything in sync.

## What it does

**Browsing**
- **Home**: Continue reading, On deck, pinned views, your libraries, and optional rows for recently read, recently
  added and recent releases - each can be shown, hidden and rearranged.
- **Libraries, series, books, collections and read lists** as poster grids that load as you scroll, with sorting, a
  *Hide read* toggle, item counts and pull-to-refresh.
- **Search** across series, books, read lists and collections.
- **Pins**: save any view (a library, a series, a read list with read books hidden...) to Home under your own name.
- **Details** for books and series: summary, credits, publisher, genres and more.
- Mark books, whole series or read lists as read or unread; select several books at once; hide books or series from
  On deck.

**Reading**
- Fit to screen, width or height; pinch or Ctrl+wheel to zoom; a zoomed-in page is read across and down before
  turning.
- Tap the sides, swipe, use the arrow keys, the mouse wheel or a remote. Page turn animation: Wipe, Instant flip or
  a 3D page curl that follows your finger.
- Right-to-left books (manga) follow Komga's reading direction, or your own setting per series.
- **Image settings per series**: Crop edges, brightness, contrast, **Enhance** (cleans up speckle and grain, then
  sharpens - on the graphics chip, once per page) and **Enhance colours** (whitens yellowed paper, deepens faded ink).
- Night mode (warm tint), a brightness slider that can go darker than the screen's minimum, and the screen kept on
  while reading.
- At the end of a book: the next one in the series or read list, with its poster.

**Offline**
- Download single books, or a series or read list's unread (or all) books, with a storage limit.
- Offline mode shows just your downloaded books - by hand, or offered automatically when Komga can't be reached.
- Reading done offline is sent to Komga when it's back; if you also read elsewhere, the further position wins.

**On the PC**
- Right-click menus, keyboard shortcuts, remembered window size and position, full screen (F11) that stays on
  across books.

## Getting started

1. In Komga's web interface, create an API key: your account (top right) > API keys > Create.
2. Install the app:
   - **Android**: install `KomgaReader-<version>-android.apk` (allow installs from this source when asked).
   - **Windows**: unzip `KomgaReader-<version>-windows.zip` anywhere and run `KomgaReader.exe`.
   - **Web**: serve the contents of `KomgaReader-<version>-web.zip`; Komga has to allow requests from that address
     (CORS).
3. Enter your Komga address (for example `http://192.168.1.10:25600`) and the API key.

## Where your settings live

- **On Komga, for every device**: reading progress, per-series reader and image settings and their defaults, pins,
  and what's hidden from On deck.
- **On this device**: the server address and API key, screen brightness and night mode, page turn animation, Home's
  layout, remembered filters and sort orders, downloads and the offline mode switch.

Settings (side menu) has everything in one place, each section labelled with where it's kept.

## Remote page-turners

Bluetooth remotes that send arrow keys and Enter work throughout the app: arrows move between items, OK opens. In
the reader, OK shows the controls, Left/Right turn pages, and Back closes the controls, then the book.

## Credits and licence

Made by **Nick Perusse** 🍁.

Komga Reader is free software under the **MIT licence** (see `LICENSE`): use it, change it and share it, keeping the
copyright notice.

It's an independent app, not part of the Komga project. [Komga](https://komga.org) is free, open-source software
(MIT) by Gauthier Roebroeck (gotson) and contributors. The app is built with [Flutter](https://flutter.dev), and its
page enhancement adapts AMD FidelityFX Super Resolution 1 (MIT). Everything the project relies on - libraries, fonts,
build tools - is listed, with the notices they require, in `THIRD_PARTY_NOTICES.md` (in the app: About >
Third-party software). What's new in each build is in `CHANGELOG.md` (About > What's new).

**AI usage:** this application was developed with the aid of AI coding tools (Claude, by Anthropic, through Claude
Code), and reviewed and tested by a human.

## For developers

The rest of this file is about building the app.

### The repository

- `komga_reader\` - the Flutter app: Dart in `lib\`, shaders in `shaders\`, tests in `test\`, native code in
  `android\` and `windows\`.
- `CHANGELOG.md` - what each build contains. `README.md` - this file. `THIRD_PARTY_NOTICES.md` - everything the
  project relies on, and the notices it must carry. All three are bundled into the app by the build.
- `LICENSE` - MIT.
- `tools\build.ps1` - the build pipeline; `tools\install-android.ps1` - installs on the tablet over wireless ADB.
- `tools\make_icon.py` - draws every app icon from one set of shapes.
- `tools\image-lab\` - a browser tool for tuning the page processing (serve the repository folder with
  `python -m http.server 8765` and open `/tools/image-lab/index.html`); `tools\sharpen_compare.py` and
  `tools\extract_pages.py` go with it. Test pages go in `testpages\`, which isn't committed.
- `keytest\` - a page for finding out which keys a remote sends.
- `dev_setup.py` - downloads and verifies the toolchain.

### Toolchain (this PC)

Nothing is on PATH; the build script sets it up itself.

| What | Where |
|---|---|
| Flutter 3.47 | `C:\Dev\flutter` |
| JDK 17 | `C:\Dev\jdk17` |
| Android SDK | `C:\Dev\android-sdk` |
| Visual Studio Build Tools 2022 (C++) | for Windows builds |
| Windows Developer Mode | on (needed for plugins) |

For an interactive shell:

```powershell
$env:JAVA_HOME = 'C:\Dev\jdk17'; $env:PATH = "C:\Dev\flutter\bin;$env:PATH"; Set-Location C:\Claude\KomgaClient\komga_reader
```

Everyday commands, from `komga_reader\`:

```powershell
flutter analyze            # static checks
flutter test               # the test suite
flutter run -d windows     # run on this PC with hot reload
```

### Building

```powershell
C:\Claude\KomgaClient\tools\build.ps1 -Bump
```

Checks the working tree is committed, runs analyze and the tests (stopping on any failure), raises the build number,
files the changelog's *Unreleased* entries under the new build, bundles the README, changelog and third-party notices
into the app,
builds Android, Windows and web into `dist\<version>\` with checksums and a BUILD-INFO.txt, then commits and tags
`build-<n>`. If a build fails, the version, changelog and bundled documents are put back.

Options: `-Platforms android` (or `windows`, `web`) builds a subset; `-SkipTests` skips the tests; `-NoInstall`
skips the tablet; `-AllowDirty` allows uncommitted changes (for a throwaway build). Progress is in `dist\build.log`.
Close Komga Reader on this PC before a Windows build.

After an Android build the APK is installed on the paired tablet over wireless ADB. Pairing is a one-time step:
`& 'C:\Dev\android-sdk\platform-tools\adb.exe' pair <IP>:<port>` with the code from the tablet's Settings > Developer
options > Wireless debugging > Pair device with pairing code. Wireless debugging must be on for installs (Android
switches it off whenever the tablet leaves the Wi-Fi); if the tablet can't be reached the build still succeeds and
says so - install later with `tools\install-android.ps1`.

**Release signing (Android):** the APK is signed with the key named in `komga_reader\android\key.properties`
(copy `key.properties.example`; never committed), whose keystore lives outside the repository. Without that file the
build falls back to the debug key and says so. Android only updates an app signed with the same key, so the release
key must never change: keep a backup of the keystore and its password.

Outputs in `dist\<version>\`:
- `KomgaReader-<ver>-android.apk` - install on the tablet (sideload)
- `KomgaReader-<ver>-windows.zip` - portable: unzip anywhere, run `KomgaReader.exe`
- `KomgaReader-<ver>-web.zip` - static site; needs Komga to allow cross-origin requests (CORS) from where it's served

### Renaming the app

"Komga Reader" is a placeholder. A rename is a display-only change; everyone keeps their settings, downloads and
updates, because the internal identifiers never change:

- **Change** (the name people see): `komga_reader\lib\app_identity.dart` (`appName` - every screen);
  `android\app\src\main\AndroidManifest.xml` (`android:label`); `windows\runner\main.cpp` (window title);
  `windows\runner\Runner.rc` (`FileDescription`, `InternalName`, `OriginalFilename`); `windows\CMakeLists.txt`
  (`BINARY_NAME`, the .exe); `web\index.html` and `web\manifest.json`; `tools\build.ps1` (`$product`, the file names
  in `dist\`); this README, the changelog's intro, `THIRD_PARTY_NOTICES.md`, `lib\licences.dart` (the AI disclosure).
- **Never change** (internal): the Android application ID and Kotlin package `com.nickp.komga_reader`; the Dart
  package `komga_reader`; `Runner.rc`'s `CompanyName` and `ProductName` (they name the Windows settings folder
  `%APPDATA%\com.nickp\Komga Reader`); the Windows data folder `%LOCALAPPDATA%\KomgaReader`
  (`desktop_channel.cpp`); the Komga client-setting keys `komgareader.*`.

### Working on changes

- Development happens on a version branch (now `1.1`); releases are tagged (`v0.1.0-rc.1`).
- One branch per change, off the version branch: `git switch -c feature/two-page-mode 1.1`, commit there, keep
  `flutter analyze` and `flutter test` green, then merge back into `1.1`.
- New behaviour gets a test in `test\`. Screens that talk to Komga are tested against a fake `Komga` subclass (see
  `test\reader_test.dart`); shaders are run for real in tests (`test\enhance_test.dart`).
- Add a line to `CHANGELOG.md` under *Unreleased*; the build moves it under the new build number.
