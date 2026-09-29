# Komga Reader

A reading client for a [Komga](https://komga.org) comics server - Android first, Windows desktop, web.
Built for one home library: dark UI, a remote page-turner, per-series display settings, pins, read lists.

- `komga_reader\` - the Flutter app (Dart in `lib\`, tests in `test\`, native bits in `android\` and `windows\`)
- `NOTES.md` - requirements, decisions, and the backlog of ideas
- `CHANGELOG.md` - what each build contains
- `tools\build.ps1` - the build pipeline (all platforms into `dist\`)
- `tools\make_icon.py` - draws every app icon from one set of shapes
- `keytest\` - page for finding out which keys a remote sends
- `dev_setup.py` - downloads and verifies the toolchain (Flutter, JDK 17, Android command-line tools)

## Toolchain (this PC)

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

## Everyday commands (from `komga_reader\`)

```powershell
flutter analyze            # static checks
flutter test               # the test suite
flutter run -d windows     # run on this PC with hot reload
```

## Building everything

```powershell
C:\Claude\KomgaClient\tools\build.ps1 -Bump
```

Runs analyze + tests (stops on any failure), raises the build number, builds Android, Windows and web into
`dist\<version>\` with checksums and a BUILD-INFO.txt, then commits and tags `build-<n>`.
`-Platforms android` (or `windows`, `web`) builds a subset; `-SkipTests` skips the tests; progress is in
`dist\build.log`. Close Komga Reader on this PC before a Windows build.

Outputs:
- `KomgaReader-<ver>-android.apk` - install on the tablet (sideload)
- `KomgaReader-<ver>-windows.zip` - portable: unzip anywhere, run `KomgaReader.exe`
- `KomgaReader-<ver>-web.zip` - static site; needs Komga to allow cross-origin requests (CORS) from wherever it is served

## Working on enhancements

- `main` is always releasable; builds come from `main` only.
- One branch per enhancement: `git switch -c feature/two-page-mode`, work and commit there, keep
  `flutter analyze` and `flutter test` green, then `git switch main` and `git merge feature/two-page-mode`.
- New behaviour gets a test in `test\`. Screens that talk to Komga are tested against a fake `Komga`
  subclass (see `test\reader_test.dart`).
- Add a line to `CHANGELOG.md` under "Unreleased"; the build moves it under the new build number.
- Ideas that aren't being built yet go in `NOTES.md` under Backlog.

## Settings the app keeps

- Server address, API key, device display settings (brightness, night mode), remembered filters:
  on the device (Android app storage; Windows `%APPDATA%\com.nickp\Komga Reader\`).
- Per-series reader settings and pins: also synced to the Komga user's client settings, so other devices get them.
- Reading progress: only ever on the Komga server.
