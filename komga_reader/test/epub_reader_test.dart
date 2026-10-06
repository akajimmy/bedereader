// The EPUB reader screen (lib/screens/epub_reader.dart) over a small book held in memory.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/epub/source.dart';
import 'package:komga_reader/screens/epub_reader.dart';
import 'package:komga_reader/screens/open_book.dart';
import 'package:komga_reader/screens/reader.dart';
import 'package:komga_reader/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/no_network.dart';

class MemorySource implements EpubSource {
  MemorySource(this.files, this.infoValue);
  final Map<String, String> files;
  final EpubInfo infoValue;
  @override
  Future<EpubInfo> info() async => infoValue;
  @override
  Future<Uint8List> resource(String path) async {
    final f = files[path];
    if (f == null) throw StateError('no $path');
    return Uint8List.fromList(utf8.encode(f));
  }
}

String para(String word, int n) => '<p>${List.filled(n, word).join(' ')}</p>';

MemorySource twoChapters() => MemorySource({
      'c1.xhtml': '<html><body><h1>One</h1>${List.filled(12, para('alpha', 40)).join()}'
          '<p>Here<a href="notes.xhtml#n1">*</a> is a note.</p></body></html>',
      'c2.xhtml': '<html><body><h1 id="two">Two</h1>${List.filled(12, para('beta', 40)).join()}</body></html>',
      'notes.xhtml': '<html><body><p id="n1"><a href="c1.xhtml">*</a>The note itself.</p></body></html>',
    }, const EpubInfo(spine: ['c1.xhtml', 'c2.xhtml'], toc: [
      TocEntry('One', 'c1.xhtml', 0),
      TocEntry('Two', 'c2.xhtml#two', 0),
    ], title: 'Book'));

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppSettings.instance.setDisplay(const DisplayPrefs());
  });

  Future<void> open(WidgetTester tester, MemorySource source) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: EpubReaderScreen(api: plainKomga(),
        book: const {'id': 'B1', 'name': 'Book', 'media': {'mediaProfile': 'EPUB'}}, source: source, saveProgress: false)));
    // loading, laying out and counting run on real futures: until the pages show and the book is counted
    for (var i = 0; i < 200; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      if (find.byType(PageView).evaluate().isNotEmpty && i > 10) break;
    }
    expect(find.byType(PageView), findsOneWidget, reason: 'the book opened; on screen: '
        '${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList()} '
        '${find.byType(CircularProgressIndicator).evaluate().length} spinners');
  }

  Future<String> label(WidgetTester tester) async {
    await tester.tapAt(const Offset(400, 600)); // the middle: the controls
    await tester.pump();
    final t = tester.widgetList<Text>(find.textContaining(RegExp(r'^(Page|Chapter) '))).single.data!;
    await tester.tapAt(const Offset(400, 600)); // and away again
    await tester.pump();
    return t;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('EPUBs open in the EPUB reader, comics in the comic reader', (tester) async {
    final api = plainKomga();
    expect(readerFor(api, {'id': 'e', 'media': {'mediaProfile': 'EPUB'}}), isA<EpubReaderScreen>());
    expect(readerFor(api, {'id': 'c', 'media': {'mediaProfile': 'DIVINA'}}), isA<ReaderScreen>());
  });

  testWidgets('opens on the first page; once every chapter is counted the position reads "page X of Y"; a tap on '
      'the right turns forward, on the left back', (tester) async {
    await open(tester, twoChapters());
    expect(await label(tester), startsWith('Page 1 of '));
    await tester.tapAt(const Offset(750, 600));
    await settle(tester);
    expect(await label(tester), startsWith('Page 2 of '));
    await tester.tapAt(const Offset(50, 600));
    await settle(tester);
    expect(await label(tester), startsWith('Page 1 of '));
  });

  testWidgets('contents: jumps to a chapter; turning on from the last page of a chapter goes into the next; the end '
      'card after the last page', (tester) async {
    await open(tester, twoChapters());
    await tester.tapAt(const Offset(400, 600));
    await tester.pump();
    await tester.tap(find.byTooltip('Contents'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Two'));
    await settle(tester);
    final atTwo = await label(tester);
    final total = int.parse(RegExp(r'of (\d+)').firstMatch(atTwo)!.group(1)!);
    final here = int.parse(RegExp(r'Page (\d+)').firstMatch(atTwo)!.group(1)!);
    expect(here, greaterThan(1), reason: 'chapter two is past chapter one');
    // to the end and past it
    for (var i = here; i <= total; i++) {
      await tester.tapAt(const Offset(750, 600));
      await settle(tester);
    }
    expect(find.text('The end'), findsOneWidget);
  });

  testWidgets('a footnote marker opens the note over the page; the page stays', (tester) async {
    await open(tester, MemorySource({
      'c1.xhtml': '<html><body><p>Here<a href="notes.xhtml#n1">*</a> is a note.</p></body></html>',
      'notes.xhtml': '<html><body><p id="n1"><a href="c1.xhtml">*</a>The note itself.</p></body></html>',
    }, const EpubInfo(spine: ['c1.xhtml', 'notes.xhtml'], toc: [])));
    // the marker sits right after "Here" on the first line: find it through the page's links
    final state = tester.state(find.byType(EpubReaderScreen));
    expect(state, isNotNull);
    // tap along the first line until the note opens (the marker's exact x depends on the font)
    var opened = false;
    for (var x = 36.0; x < 400 && !opened; x += 6) {
      await tester.tapAt(Offset(x, 55));
      await settle(tester);
      opened = find.textContaining('The note itself.').evaluate().isNotEmpty;
    }
    expect(opened, isTrue);
    expect(find.text('The note itself.'), findsOneWidget, reason: "the note's own marker (its link back) left out");
    await tester.tap(find.text('Close'));
    await settle(tester);
    expect(find.text('The note itself.'), findsNothing);
    expect(find.byType(PageView), findsOneWidget, reason: 'still on the page');
  });
}
