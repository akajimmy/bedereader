import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/app_identity.dart';
import 'package:komga_reader/licences.dart';
import 'package:komga_reader/screens/document.dart';
import 'package:komga_reader/widgets/markdown.dart';

import 'support/helpers.dart';

/// About > What's new / Read me: the bundled CHANGELOG and README, shown with the app's small Markdown renderer.
void main() {
  test('markdown: headings, paragraphs joined across lines, bullets with continuation lines, numbers, code, tables', () {
    final blocks = MarkdownView.parseBlocks('''
# Title

A paragraph
over two lines.

## Section

- first item
  continued here
- second **bold** item
  - nested
1. numbered

```powershell
flutter test
```

| What | Where |
|---|---|
| Flutter | `C:\\Dev\\flutter` |
''');
    expect(blocks.map((b) => b.runtimeType.toString()).toList(), [
      'MdHeading', 'MdParagraph', 'MdHeading', 'MdListItem', 'MdListItem', 'MdListItem', 'MdListItem', 'MdCode', 'MdTable',
    ]);
    expect((blocks[1] as MdParagraph).text, 'A paragraph over two lines.');
    expect((blocks[3] as MdListItem).text, 'first item continued here');
    expect((blocks[5] as MdListItem).indent, 1);
    expect((blocks[6] as MdListItem).marker, '1.');
    expect((blocks[7] as MdCode).code, 'flutter test');
    expect((blocks[8] as MdTable).rows, [['What', 'Where'], ['Flutter', r'`C:\Dev\flutter`']]);
  });

  test('badge lines (images, for GitHub) are left out; the text around them stays', () {
    final blocks = MarkdownView.parseBlocks('''
# Title

[![AI assisted](https://img.shields.io/badge/AI-assisted-5b8def)](#credits)
![plain image](https://example.org/x.png)

Text after.
''');
    expect(blocks.map((b) => b.runtimeType.toString()).toList(), ['MdHeading', 'MdParagraph']);
    expect((blocks[1] as MdParagraph).text, 'Text after.');
  });

  test('inline: bold, italic, code and links become styled spans', () {
    final spans = inlineSpans('a **b** *c* `d` [e](https://komga.org)', const TextStyle());
    final texts = [for (final s in spans) (s as TextSpan).text];
    expect(texts, ['a ', 'b', ' ', 'c', ' ', 'd', ' ', 'e']);
    expect((spans[1] as TextSpan).style!.fontWeight, FontWeight.w700);
    expect((spans[7] as TextSpan).recognizer, isNotNull); // tappable link
  });

  testWidgets("What's new shows the bundled changelog", (tester) async {
    await tester.pumpWidget(MaterialApp(home: DocumentScreen.whatsNew()));
    await tester.pumpAndSettle();
    expect(find.text("What's new"), findsOneWidget);
    expect(find.textContaining('Changelog', findRichText: true), findsOneWidget);
    // the newest entry - the first heading under the title - is at the top (it used to check that the oldest build
    // was too far down to be built, which depended on how long the changelog is - test audit, 2026-09-30)
    final newest = File('assets/docs/CHANGELOG.md').readAsLinesSync().firstWhere((l) => RegExp(r'^#{2,3} ').hasMatch(l))
        .replaceFirst(RegExp(r'^#+ '), '');
    expect(find.textContaining(newest, findRichText: true), findsOneWidget, reason: newest);
  });

  testWidgets("What's new rebuilt (a setting changed elsewhere in the app) stays where it was scrolled to - it loaded "
      'again and jumped to the top (code review 2026-10-05, #48)', (tester) async {
    final rebuild = ValueNotifier(0);
    await tester.pumpWidget(ValueListenableBuilder(valueListenable: rebuild, builder: (_, n, __) => MaterialApp(
        theme: ThemeData(visualDensity: n.isEven ? VisualDensity.standard : VisualDensity.compact),
        home: DocumentScreen.whatsNew())));
    await tester.pumpAndSettle();
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    scroll.jumpTo(1500);
    await tester.pump();
    rebuild.value++; // the app rebuilt round it
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing, reason: 'not loading again');
    expect(tester.state<ScrollableState>(find.byType(Scrollable).first).position.pixels, 1500);
  });

  testWidgets('Read me shows the README up to the developer part', (tester) async {
    setView(tester, const Size(800, 20000)); // everything built, so "not there" means not there
    await tester.pumpWidget(MaterialApp(home: DocumentScreen.readMe()));
    await tester.pumpAndSettle();
    expect(find.textContaining('Getting started', findRichText: true), findsOneWidget);
    expect(find.textContaining('For developers', findRichText: true), findsNothing);
    expect(find.textContaining('Toolchain', findRichText: true), findsNothing);
  });

  testWidgets('Third-party software lists what the app relies on, with the AI disclosure', (tester) async {
    setView(tester, const Size(900, 30000));
    await tester.pumpWidget(MaterialApp(home: DocumentScreen.thirdParty()));
    await tester.pumpAndSettle();
    for (final t in ['AI assistance', 'Komga', 'Flutter', 'shared_preferences', 'AMD FidelityFX Super Resolution 1',
        'Material Icons', 'Eclipse Temurin JDK']) {
      expect(find.textContaining(t, findRichText: true), findsWidgets, reason: t);
    }
  });

  test("licences page: the app's MIT licence, AMD's FSR notice and the Material Icons attribution", () async {
    registerLicences();
    final entries = await LicenseRegistry.licenses.toList();
    List<String> textOf(String package) => [
          for (final e in entries)
            if (e.packages.contains(package)) e.paragraphs.map((p) => p.text).join(' ')
        ];
    expect(textOf(appName).single, contains('Permission is hereby granted'));
    expect(textOf('AMD FidelityFX Super Resolution 1 (FSR 1)').single, contains('Advanced Micro Devices'));
    expect(textOf('Material Icons').single, contains('Creative Commons Attribution 4.0'));
    // the EPUB reading fonts (OFL) and hyphenation patterns, with their own texts
    for (final font in ['Literata', 'Lora', 'Atkinson Hyperlegible Next', 'EB Garamond']) {
      expect(textOf(font).single, contains('SIL OPEN FONT LICENSE'), reason: font);
    }
    final hyph = textOf('Hyphenation patterns (hyph-utf8): English, French').single;
    expect(hyph, contains('Gerard D.C. Kuiken'));
    expect(hyph, contains('Daniel Flipo'));
  });

  testWidgets('Android: the AndroidX / Kotlin libraries with the Apache 2.0 terms; not on other platforms', (tester) async {
    registerLicences();
    Future<List<LicenseEntry>> entries() async =>
        (await tester.runAsync(() => LicenseRegistry.licenses.toList()))!;
    bool hasAndroid(List<LicenseEntry> all) => all.any((e) => e.packages.contains('kotlinx.coroutines'));
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(hasAndroid(await entries()), isFalse);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final all = await entries();
      expect(hasAndroid(all), isTrue);
      final text = all.firstWhere((e) => e.packages.contains('kotlinx.coroutines')).paragraphs.map((p) => p.text).join(' ');
      expect(text, contains('Apache License'));
      expect(text, contains('END OF TERMS AND CONDITIONS'));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
