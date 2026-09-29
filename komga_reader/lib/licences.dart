import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The app's own licence, and third-party notices Flutter doesn't collect by itself - added to the licences page
/// (Info > Licences of included open-source software) alongside the ones it gathers from Flutter and the Dart
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

/// The AI usage disclosure (Info screen, README, THIRD_PARTY_NOTICES.md).
const aiDisclosure = 'This application was developed with the aid of AI coding tools (Claude, by Anthropic, through '
    'Claude Code), and reviewed and tested by a human.';

/// The Android version also carries AndroidX, Kotlin and kotlinx.coroutines (through Flutter's Android layer and the
/// settings package) - Apache 2.0, whose terms have to go with the app. Flutter's own notices don't cover them.
const androidLibraries = ['AndroidX libraries (activity, annotation, appcompat, core, datastore, fragment, lifecycle, '
    'preference, window and others)', 'Kotlin standard library', 'kotlinx.coroutines'];
const androidLibrariesNotice = 'Included in the Android version. Copyright The Android Open Source Project; '
    'JetBrains s.r.o. and Kotlin Programming Language contributors. Licensed under the Apache License, Version 2.0:';

var _registered = false;

void registerLicences() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(['Komga Reader'], appLicence);
    yield const LicenseEntryWithLineBreaks(['AMD FidelityFX Super Resolution 1 (FSR 1)'], amdFsrNotice);
    yield const LicenseEntryWithLineBreaks(['Material Icons'], materialIconsNotice);
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final apache = await rootBundle.loadString('assets/licences/apache-2.0.txt');
      yield LicenseEntryWithLineBreaks(androidLibraries, '$androidLibrariesNotice\n\n$apache');
    }
  });
}
