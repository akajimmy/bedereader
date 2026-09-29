import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/licences.dart';
import 'package:komga_reader/screens/document.dart';
import 'package:komga_reader/widgets/markdown.dart';

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
    expect(find.textContaining('Build 1 - 2026-09-28', findRichText: true), findsNothing); // far down, not built yet
    expect(find.textContaining('Changelog', findRichText: true), findsOneWidget);
  });

  testWidgets('Read me shows the README up to the developer part', (tester) async {
    tester.view.physicalSize = const Size(800, 20000); // everything built, so "not there" means not there
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: DocumentScreen.readMe()));
    await tester.pumpAndSettle();
    expect(find.textContaining('Getting started', findRichText: true), findsOneWidget);
    expect(find.textContaining('For developers', findRichText: true), findsNothing);
    expect(find.textContaining('Toolchain', findRichText: true), findsNothing);
  });

  testWidgets('Third-party software lists what the app relies on, with the AI disclosure', (tester) async {
    tester.view.physicalSize = const Size(900, 30000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
    expect(textOf('Komga Reader').single, contains('Permission is hereby granted'));
    expect(textOf('AMD FidelityFX Super Resolution 1 (FSR 1)').single, contains('Advanced Micro Devices'));
    expect(textOf('Material Icons').single, contains('Creative Commons Attribution 4.0'));
  });
}
