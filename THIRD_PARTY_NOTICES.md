# Third-party software and notices

BeDeReader is MIT-licensed (see `LICENSE`). This file lists everything the project relies on - whether it ends up
inside the app, is fetched while the app runs, or is only used to build and develop it - and carries the notices the
included pieces require.

## AI assistance

This application was developed with the aid of AI coding tools, but was designed, reviewed, and tested by a human.

## Needed at run time, not included

| What | Licence | Role |
|---|---|---|
| [Komga](https://komga.org) | MIT | The comics server the app reads from, over its web API. No Komga code is in the app. BeDeReader is not affiliated with the Komga project. |

## Inside the app

| What | Version | Licence | Role |
|---|---|---|---|
| [Flutter](https://flutter.dev) framework and engine (Skia / Impeller) | 3.47.5 | BSD-3-Clause | The whole app: layout, drawing, GPU shaders |
| [Dart](https://dart.dev) runtime and core libraries | 3.13.4 | BSD-3-Clause | The language the app is written in |
| Material Icons font | with Flutter | CC BY 4.0 | The icons |
| AMD FidelityFX Super Resolution 1 - EASU and RCAS, adapted | 1.0 | MIT | Enhance's upscaler and sharpener (notice below) |
| Fonts: [Literata](https://github.com/googlefonts/literata), [Lora](https://github.com/cyrealtype/Lora-Cyrillic), [Atkinson Hyperlegible Next](https://www.brailleinstitute.org/freefont/), [EB Garamond](https://github.com/georgd/EB-Garamond) (from [Google Fonts](https://github.com/google/fonts)) | as of 2026-10-06 | SIL Open Font Licence 1.1 | Reading fonts for EPUB books |
| Hyphenation patterns from [hyph-utf8](https://github.com/hyphenation/tex-hyphen): US English (Gerard D.C. Kuiken), French (Daniel Flipo, Bernard Gaulle, Arthur Reutenauer) | 2005 / 2016 | permissive notice; MIT | Breaking words at line ends in EPUB books |
| [Open English WordNet](https://github.com/globalwordnet/english-wordnet) (the Open English Wordnet team), from Princeton WordNet (Princeton University) | 2025 edition | CC BY 4.0, over the WordNet licence | The offline English dictionary behind Define in EPUB books |
| `http` | 1.6.0 | BSD-3-Clause | Talking to Komga |
| `shared_preferences` and its Android / Apple / Linux / Windows parts | 2.5.5 | BSD-3-Clause | Settings kept on the device |
| `path_provider` Linux / Windows parts, `xdg_directories` | 2.2.2 / 2.3.0, 1.1.0 | BSD-3-Clause | Where settings are stored (desktop) |
| `flutter_secure_storage` and its Windows part | 11.2.0 / 4.2.2 | BSD-3-Clause | The API key, stored encrypted |
| `path_provider` and its Android part, `win32`, `jni`, `jni_flutter`, `jni_util`, `crypto`, `logging` | 2.1.6 / 2.3.1, 6.4.0, 1.1.0, 1.0.4, 1.0.0, 3.0.7, 1.3.0 | BSD-3-Clause | Used by the encrypted storage |
| flutter_secure_storage_darwin, path_provider_foundation, objective_c | 0.4.3, 2.6.0, 9.5.0 | BSD-3-Clause | The encrypted key storage and file locations on iPhone and iPad |
| `material_color_utilities` | 0.13.0 | Apache-2.0 | Material colour handling (part of Flutter) |
| async, characters, collection, ffi, file, http_parser, meta, path, platform, plugin_platform_interface, source_span, string_scanner, term_glyph, typed_data, vector_math | various | BSD-3-Clause | Supporting libraries used by the above |
| clock | 1.1.3 | BSD-3-Clause | The time for page-turn and refresh timing (testable) |

**Windows version** - also `flutter_windows.dll` (the Flutter engine) and ICU Unicode data (`icudtl.dat`, Unicode
licence); both covered by Flutter's notices.

**Android version** - also these native libraries, brought in by Flutter's Android layer and the settings package
(Apache-2.0; the licence terms are on the app's licences page on Android):

| What | Version | Licence |
|---|---|---|
| AndroidX: activity, annotation, appcompat, arch.core, asynclayoutinflater, coordinatorlayout, core, cursoradapter, customview, datastore, documentfile, drawerlayout, exifinterface, fragment, interpolator, legacy, lifecycle, loader, localbroadcastmanager, preference, print, profileinstaller, recyclerview, savedstate, slidingpanelayout, startup, swiperefreshlayout, tracing, transition, vectordrawable, versionedparcelable, viewpager, window | 1.0.0 - 2.7.0 (per library) | Apache-2.0 |
| Kotlin standard library | with Kotlin 2.4 | Apache-2.0 |
| kotlinx.coroutines (core, android) | 1.7.3 | Apache-2.0 |
| Google Tink (tink-android), brought in by the encrypted storage | 1.23.0 | Apache-2.0 |

**iPhone / iPad version** - also the Flutter engine (Flutter.framework) and the Apple parts of the settings, file
location and encrypted storage packages (the rows above); all covered by Flutter's and those packages' notices.

Flutter gathers the full licence texts of the framework, engine and Dart packages into every build; they're shown
in the app under About > *Licences of included open-source software*, together with the app's own licence, AMD's
notice, the Material Icons attribution, the reading fonts' Open Font Licences, the hyphenation patterns' notices, the dictionary's licences and
(on Android) the Apache 2.0 terms for the libraries above.

## Used to build and develop it (not shipped)

| What | Version | Licence | Role |
|---|---|---|---|
| Flutter SDK and Dart SDK (analyzer, test runner, `flutter_lints`) | 3.47.5 / 3.13.4 | BSD-3-Clause | Building, static checks, the test suite |
| Android SDK (platforms 35-36, build tools, platform tools / ADB) | 35-36 | Android SDK licence | Android builds; installing on the tablet over wireless ADB |
| Gradle; Android Gradle Plugin; Kotlin | 9.3.1; 9.1.0; 2.4.0 | Apache-2.0 | Android builds |
| Eclipse Temurin JDK | 17.0.20.1 | GPL-2.0 with Classpath Exception | Running the Android build tools |
| Visual Studio Build Tools 2022 (MSVC, CMake) | 2022 | Microsoft licence | Windows builds |
| Git, Git for Windows | 2.55 | GPL-2.0 | Version control |
| GitHub, GitHub Actions (actions/checkout, subosito/flutter-action, actions/upload-artifact); GitHub CLI | -; v7, v2, v4; 2.101 | GitHub terms; MIT | Hosting, the automatic checks on every push, the iPhone / iPad builds, publishing; Dependabot and secret scanning (on since 2026-10-23) |
| Xcode and CocoaPods, on GitHub's macOS runners | Xcode 26 | Apple licence; MIT | iPhone and iPad builds |
| codemagic-cli-tools | latest (0.70 on 2026-10-23) | GPL-3.0-or-later | Signing the iPhone / iPad build and uploading it to TestFlight |
| App Store Connect, TestFlight | - | Apple terms | Distributing the iPhone / iPad test builds |
| Windows PowerShell | 5.1 | Microsoft | The build and install scripts |
| Python, with Pillow | 3.13, 12.3 | PSF; MIT-CMU | Icon generation (`tools\make_icon.py`), toolchain setup (`dev_setup.py`) |
| Claude Code (Anthropic) | - | Anthropic terms | AI coding assistant (see *AI assistance*) |

Pages from the owner's own comics are used locally to tune the image processing; they're not part of the project.

## Notices

### AMD FidelityFX Super Resolution 1 (FSR 1)

Enhance adapts FSR 1's EASU upscaler (`komga_reader\shaders\easu.frag`) and RCAS sharpener
(`komga_reader\shaders\rcas.frag`).
<https://github.com/GPUOpen-Effects/FidelityFX-FSR>

```
Copyright (c) 2021 Advanced Micro Devices, Inc. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

### Material Icons

Material Icons by Google, licensed under the Creative Commons Attribution 4.0 International licence
(<https://creativecommons.org/licenses/by/4.0/>). Used unmodified, as the font supplied with Flutter.
