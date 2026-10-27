import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_identity.dart';

/// The app's own licence, and third-party notices Flutter doesn't collect by itself - added to the licences page
/// (About > Licences of included open-source software) alongside the ones it gathers from Flutter and the Dart
/// packages. Same texts as LICENSE and THIRD_PARTY_NOTICES.md in the repository.
const appCopyright = 'Copyright (c) 2026 Nick Perusse';
const appLicenceName = 'MIT licence';

const _mitBody = '''
Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.''';

/// AMD FidelityFX Super Resolution 1: Enhance adapts its EASU upscaler and RCAS sharpener (shaders/easu.frag,
/// shaders/rcas.frag). MIT - its notice must go with the app.
const amdFsrNotice = 'Copyright (c) 2021 Advanced Micro Devices, Inc. All rights reserved.\n$_mitBody';

const appLicence = '$appCopyright\n$_mitBody';

/// The icons: Material Icons (with Flutter), CC BY 4.0 - which asks for an attribution.
const materialIconsNotice = 'Material Icons by Google, licensed under the Creative Commons Attribution 4.0 '
    'International licence (https://creativecommons.org/licenses/by/4.0/). Used unmodified, as the font supplied '
    'with Flutter.';

/// libsmb2 (network shares: dart_smb2's build bundles it, renamed, on every platform - LGPL-2.1 or later, loaded as
/// its own library). Its notice asks for the LGPL text, the notice, and where its source is (the release pinned by
/// dart_smb2 0.2.3's build hook: libsmb2-r9).
const libsmb2Notice = 'libsmb2 - SMB2/3 client library, used for network shares. Copyright (C) Ronnie Sahlberg and '
    'the libsmb2 contributors. Licensed under the GNU Lesser General Public License, version 2.1 or later (the full '
    'text follows). It is included unmodified and loaded as a separate library.\n\n'
    'Source: https://github.com/sahlberg/libsmb2\n'
    'The binaries in this app: release libsmb2-r9 of https://github.com/ales-drnz/dart_smb2 '
    '(https://github.com/ales-drnz/dart_smb2/releases/tag/libsmb2-r9), built by '
    'https://github.com/ales-drnz/libsmb2-scripts - the release names the commit it was built from, the corresponding '
    'source of its binaries.';

/// Komga's K, drawn by the source icons (lib/widgets/source_badge.dart) from the outline of Komga's tray icon. MIT.
const komgaNotice = "Komga's K (the source icon for Komga's books) is drawn from the outline of Komga's tray icon "
    '(komga-tray/src/main/resources/icons/komga-gray-minimal.svg, https://github.com/gotson/komga).\n\n'
    'MIT License\n\nCopyright (c) 2019 Gauthier Roebroeck\n$_mitBody';

/// The AI usage disclosure on the About screen (user's wording, 2026-09-29). README and THIRD_PARTY_NOTICES.md say
/// which tools were used.
const aiDisclosure =
    'This application was developed with the aid of AI coding tools, but was designed, reviewed, and tested by a human.';

/// The Android version also carries AndroidX, Kotlin, kotlinx.coroutines and the libraries they and the encrypted
/// storage bring (Flutter's Android layer, the settings and secure storage packages) - all Apache 2.0, whose terms
/// have to go with the app. Flutter's own notices don't cover them. (The release build's list, from Gradle's
/// releaseRuntimeClasspath, 10-27.)
const androidLibraries = ['AndroidX libraries (activity, annotation, appcompat, collection, concurrent-futures, core, '
    'datastore, fragment, lifecycle, preference, window and others)', 'Kotlin standard library', 'kotlinx.coroutines',
    'Google Tink', 'Gson', 'Okio', 'ReLinker', 'JSR 305 annotations', 'Error Prone annotations', 'JetBrains annotations',
    'JSpecify'];
const androidLibrariesNotice = 'Included in the Android version. Copyright The Android Open Source Project; '
    'JetBrains s.r.o. and Kotlin Programming Language contributors; Google LLC (Tink, Gson, Error Prone, Guava); '
    'Square, Inc. (Okio); KeepSafe Software, Inc. (ReLinker); the JSR 305 expert group; the JSpecify authors. '
    'Licensed under the Apache License, Version 2.0:';

var _registered = false;

void registerLicences() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks([appName], appLicence);
    yield const LicenseEntryWithLineBreaks(['AMD FidelityFX Super Resolution 1 (FSR 1)'], amdFsrNotice);
    yield const LicenseEntryWithLineBreaks(['Material Icons'], materialIconsNotice);
    yield const LicenseEntryWithLineBreaks(['Komga'], komgaNotice);
    // network shares: libsmb2 (LGPL-2.1, its notice and source), and the RAR reader's adapted code (libarchive's RAR
    // readers, rardecode: BSD; PPMd: public domain) - package NOTICE files Flutter doesn't gather by itself
    yield LicenseEntryWithLineBreaks(['libsmb2'], '$libsmb2Notice\n\n'
        '${await rootBundle.loadString('assets/licences/dart_smb2-NOTICE.txt')}\n\n'
        '${await rootBundle.loadString('assets/licences/lgpl-2.1.txt')}');
    yield LicenseEntryWithLineBreaks(['koni_rar'], await rootBundle.loadString('assets/licences/koni_rar-NOTICE.txt'));
    // EPUB reading fonts (SIL Open Font Licence 1.1), hyphenation patterns (hyph-utf8) and the dictionary (CC BY 4.0
    // over the WordNet licence): their own texts
    for (final (name, file) in const [
      ('Literata', 'assets/fonts/Literata-OFL.txt'),
      ('Lora', 'assets/fonts/Lora-OFL.txt'),
      ('Atkinson Hyperlegible Next', 'assets/fonts/AtkinsonHyperlegibleNext-OFL.txt'),
      ('EB Garamond', 'assets/fonts/EBGaramond-OFL.txt'),
      ('Hyphenation patterns (hyph-utf8): English, French', 'assets/hyphenation/LICENSE.txt'),
      ('Open English WordNet (the dictionary behind Define), from Princeton WordNet', 'assets/dictionary/LICENSE.txt'),
    ]) {
      yield LicenseEntryWithLineBreaks([name], await rootBundle.loadString(file));
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      final apache = await rootBundle.loadString('assets/licences/apache-2.0.txt');
      yield LicenseEntryWithLineBreaks(androidLibraries, '$androidLibrariesNotice\n\n$apache');
    }
  });
}
