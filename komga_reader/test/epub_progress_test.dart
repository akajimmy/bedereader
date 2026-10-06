// EPUB progress through Komga's Readium progression (lib/epub/progress.dart) and the reader's use of it.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/epub/progress.dart';
import 'package:komga_reader/screens/epub_reader.dart';
import 'package:komga_reader/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/no_network.dart';

const _base = 'http://test/api/v1/books/B1/resource/';

String _para(String w, int n) => '<p>${List.filled(n, w).join(' ')}</p>';

/// A Komga with one EPUB (two chapters), its positions, and a progression that can be read and saved.
class EpubKomga extends TestKomga {
  EpubKomga({this.saved, this.slow = Duration.zero});
  Map<String, dynamic>? saved;
  final Duration slow; // each chapter file takes this long to come (as over the network)
  final puts = <Map<String, dynamic>>[];
  final marked = <String>[];

  final files = {
    'OEBPS/c1.xhtml': '<html><body><h1>One</h1>${List.filled(10, _para('alpha', 40)).join()}</body></html>',
    'OEBPS/c2.xhtml': '<html><body><h1>Two</h1>${List.filled(10, _para('beta', 40)).join()}</body></html>',
  };

  @override
  Future<Map<String, dynamic>?> epubManifest(String bookId) async => {
        'readingOrder': [{'href': '${_base}OEBPS/c1.xhtml'}, {'href': '${_base}OEBPS/c2.xhtml'}],
        'toc': [],
      };

  @override
  Future<Uint8List> epubResource(String bookId, String path) async {
    if (slow > Duration.zero) await Future<void>.delayed(slow);
    return Uint8List.fromList(utf8.encode(files[path]!));
  }

  // Komga's positions: hrefs as it writes them (full URLs), 3 per chapter
  @override
  Future<List<dynamic>> epubPositions(String bookId) async => [
        for (final (i, ch) in ['c1', 'c2'].indexed)
          for (var k = 0; k < 3; k++)
            {'href': '${_base}OEBPS/$ch.xhtml', 'type': 'application/xhtml+xml',
              'locations': {'position': i * 3 + k + 1, 'progression': k / 3}},
      ];

  @override
  Future<Map<String, dynamic>?> epubProgression(String bookId) async => saved;

  @override
  Future<void> setEpubProgression(String bookId, Map<String, dynamic> progression) async => puts.add(progression);

  @override
  Future<void> markRead(String bookId) async => marked.add(bookId);
}

Map<String, dynamic> _saved(String href, double progression) =>
    {'locator': {'href': href, 'type': 'application/xhtml+xml', 'locations': {'progression': progression}}};

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppSettings.instance.setDisplay(const DisplayPrefs());
  });

  test("where to open: the saved progression (Komga's full-URL href made a path in the book)", () async {
    final api = noNetwork(() => EpubKomga(saved: _saved('${_base}OEBPS/c2.xhtml', 0.4)));
    final at = await EpubProgress(api, 'B1').load({'id': 'B1'});
    expect(at!.path, 'OEBPS/c2.xhtml');
    expect(at.progression, 0.4);
  });

  test('no progression saved (read to a page elsewhere): the read progress page through the positions; not started: '
      'nothing', () async {
    final api = noNetwork(EpubKomga.new);
    final p = EpubProgress(api, 'B1');
    final at = await p.load({'id': 'B1', 'readProgress': {'page': 5}}); // position 5: c2, a third in
    expect(at!.path, 'OEBPS/c2.xhtml');
    expect(at.progression, closeTo(1 / 3, 1e-9));
    expect(await p.load({'id': 'B1'}), isNull);
  });

  test("a save: Komga's own href for the chapter, the position at or just before the place, both progressions, this "
      'device (the same id every time)', () async {
    final api = noNetwork(EpubKomga.new);
    final p = EpubProgress(api, 'B1');
    await p.save('OEBPS/c2.xhtml', 0.5, 0.75);
    await p.save('OEBPS/c1.xhtml', 0.0, 0.0);
    final first = api.puts[0]['locator'] as Map;
    expect(first['href'], '${_base}OEBPS/c2.xhtml');
    expect((first['locations'] as Map)['position'], 5, reason: 'c2 at 1/3 (position 5) is the last at or before 0.5');
    expect((first['locations'] as Map)['progression'], 0.5);
    expect((first['locations'] as Map)['totalProgression'], 0.75);
    expect(((api.puts[1]['locator'] as Map)['locations'] as Map)['position'], 1);
    final device = api.puts[0]['device'] as Map;
    expect(device['id'], isNotEmpty);
    expect(api.puts[1]['device'], device, reason: 'the same device both times');
    expect(api.puts[0]['modified'], isA<String>());
  });

  Future<void> run(WidgetTester tester, Duration d) async {
    for (var t = Duration.zero; t < d; t += const Duration(milliseconds: 100)) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<EpubKomga> open(WidgetTester tester, {Map<String, dynamic>? saved}) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = noNetwork(() => EpubKomga(saved: saved));
    await tester.pumpWidget(MaterialApp(home: EpubReaderScreen(api: api,
        book: const {'id': 'B1', 'name': 'Book', 'media': {'mediaProfile': 'EPUB'}})));
    await run(tester, const Duration(seconds: 2));
    expect(find.byType(PageView), findsOneWidget);
    return api;
  }

  Future<String> label(WidgetTester tester) async {
    await tester.tapAt(const Offset(400, 600));
    await tester.pump();
    final t = tester.widgetList<Text>(find.byKey(const ValueKey('epub-book-position'))).single.data!;
    await tester.tapAt(const Offset(400, 600));
    await tester.pump();
    return t;
  }

  testWidgets('the reader opens where reading stopped (chapter two, halfway); opening alone saves nothing',
      (tester) async {
    final api = await open(tester, saved: _saved('${_base}OEBPS/c2.xhtml', 0.5));
    final l = await label(tester);
    final page = int.parse(RegExp(r'^(\d+) /').firstMatch(l)!.group(1)!);
    final total = int.parse(RegExp(r'/ (\d+)').firstMatch(l)!.group(1)!);
    expect(page, greaterThan(total * 0.6), reason: 'halfway through the second of two chapters: $l');
    await run(tester, const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox()); // closing the book
    await run(tester, const Duration(milliseconds: 300));
    expect(api.puts, isEmpty, reason: 'nothing turned: nothing saved, not even on closing (another device\'s place '
        'stays)');
  });

  // NB: this passes on the code before the fix too - the test's timing doesn't reproduce the tablet's (where the
  // book opened at the chapter's start: checked on the tablet, 2026-10-06, before and after). Kept for the case.
  testWidgets('the screen changing size while the book opens (the system bars hiding, as on the tablet) still opens '
      'at the saved place', (tester) async {
    tester.view.physicalSize = const Size(800, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = noNetwork(() => EpubKomga(saved: _saved('${_base}OEBPS/c2.xhtml', 0.5),
        slow: const Duration(milliseconds: 300)));
    await tester.pumpWidget(MaterialApp(home: EpubReaderScreen(api: api,
        book: const {'id': 'B1', 'name': 'Book', 'media': {'mediaProfile': 'EPUB'}})));
    // the book opens and is laid out once; its chapter is still on its way when the bars go
    final laidOut = find.descendant(of: find.byType(EpubReaderScreen), matching: find.byType(LayoutBuilder));
    for (var i = 0; i < 40 && laidOut.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    tester.view.physicalSize = const Size(800, 1200); // the bars go
    await tester.pump();
    await run(tester, const Duration(seconds: 1));
    for (var i = 0; i < 40 && find.byType(PageView).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await run(tester, const Duration(seconds: 2));
    final l = await label(tester);
    final page = int.parse(RegExp(r'^(\d+) /').firstMatch(l)!.group(1)!);
    final total = int.parse(RegExp(r'/ (\d+)').firstMatch(l)!.group(1)!);
    expect(page, greaterThan(total * 0.6), reason: 'halfway through the second of two chapters: $l');
  });

  testWidgets('a turn is saved once the page has been on screen 1.5 s (quick turns: only the last); the end card '
      'marks the book read', (tester) async {
    final api = await open(tester);
    await tester.tapAt(const Offset(750, 600));
    await run(tester, const Duration(milliseconds: 500));
    await tester.tapAt(const Offset(750, 600));
    await run(tester, const Duration(milliseconds: 600));
    expect(api.puts, isEmpty, reason: 'not settled yet');
    await run(tester, const Duration(seconds: 2));
    expect(api.puts.length, 1, reason: 'one save, for the page turned to last');
    expect((((api.puts.single['locator'] as Map)['locations']) as Map)['totalProgression'], greaterThan(0),
        reason: 'two pages on from the start');
    // on to the end
    for (var i = 0; i < 200 && api.marked.isEmpty; i++) {
      await tester.tapAt(const Offset(750, 600));
      await run(tester, const Duration(milliseconds: 300));
    }
    expect(api.marked, ['B1']);
    expect(find.text('The end'), findsOneWidget);
  });
}

// keeps the analyzer quiet about the unused Komga import in some setups
// ignore: unused_element
typedef _K = Komga;
