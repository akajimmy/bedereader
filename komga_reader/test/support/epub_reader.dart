// The EPUB reader's tests: a book held in memory opened in the one Reader, settled, and where it is read off the
// position row - shared by the epub_renderer / epub_reader_ui / epub_page tests (test audit, 2026-10-23: one file of
// them was the suite's longest by far, so it was split in three).
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/epub/count_store.dart';
import 'package:komga_reader/epub/source.dart';
import 'package:komga_reader/reader/epub_renderer.dart';
import 'package:komga_reader/screens/reader.dart';
import 'package:komga_reader/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'client_settings.dart';
import 'epub_books.dart';
import 'helpers.dart';
import 'no_network.dart';

/// A book whose chapter [fails] can't be read the first time it's asked for (the network, for a moment).
class FailsOnce extends MemorySource {
  FailsOnce(super.files, super.infoValue, {required this.fails});
  final String fails;
  bool _failed = false;
  @override
  Future<Uint8List> resource(String path) {
    if (path == fails && !_failed) {
      _failed = true;
      return Future.error(StateError('offline'));
    }
    return super.resource(path);
  }
}

/// A Komga that knows the book after this one ([next]; null: the series' last) and serves a 1-pixel poster.
class EndKomga extends TestKomga with EmptyClientSettings {
  EndKomga(this.next);
  final Map<String, dynamic>? next;
  @override
  Future<Map<String, dynamic>?> nextBook(String bookId, {String? readListId}) async => next;
  @override
  ImageProvider thumbImage(String ref) => MemoryImage(onePixelPng);
}

/// A book in a series and in a read list RL1: next in the series is [inSeries], next in the read list [inList]; what
/// was asked is kept.
class ReadListKomga extends TestKomga with EmptyClientSettings {
  static const inSeries = {'id': 'S2', 'seriesTitle': 'Hitchhiker', 'metadata': {'number': '2', 'title': 'Restaurant'}};
  static const inList = {'id': 'E1', 'seriesTitle': 'Ender', 'metadata': {'number': '1', 'title': "Ender's Game"}};
  final listNextAsked = <String?>[], listPrevAsked = <String?>[];
  @override
  Future<Map<String, dynamic>?> nextBook(String bookId, {String? readListId}) async {
    listNextAsked.add(readListId);
    return readListId == 'RL1' ? inList : inSeries;
  }

  @override
  Future<Map<String, dynamic>?> previousBook(String bookId, {String? readListId}) async {
    listPrevAsked.add(readListId);
    return null;
  }

  @override
  ImageProvider thumbImage(String ref) => MemoryImage(onePixelPng);
}

/// Each file's set-up, from its main(): a middle tap shows the controls at once (no double tap waited for), the curl's
/// shader loaded first, every book counted afresh in memory (never on disk), the default display settings.
void epubReaderSetUp() {
  setUpAll(() => EpubRenderer.doubleTapWait = Duration.zero);
  // the curl's shader, before any test: loaded inside a group after a widget test, it never finished (the whole file
  // hung - 2026-10-11)
  setUpAll(preloadShaders);
  late EpubCountStore counts;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppSettings.instance.setDisplay(const DisplayPrefs());
    counts = EpubCountStore.instance;
    EpubCountStore.instance = MemoryCountStore();
  });
  tearDown(() => EpubCountStore.instance = counts);
}

/// [source] opened in the Reader on a [size] screen, as book B1 of a series whose last book it is (unless [api] says
/// otherwise); back once the pages show and the book is counted.
Future<void> openEpub(WidgetTester tester, MemorySource source, {Komga? api, Size size = const Size(800, 1200)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: api ?? noNetwork(() => EndKomga(null)),
      book: const {'id': 'B1', 'name': 'Book', 'media': {'mediaProfile': 'EPUB'}}, epubSource: source, saveProgress: false)));
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

/// The position row's left text ("page X of Y"), the controls brought up for it and put away again.
Future<String> epubLabel(WidgetTester tester) async {
  await tester.tapAt(const Offset(400, 600)); // the middle: the controls
  await tester.pump();
  final t = tester.widgetList<Text>(find.byKey(const ValueKey('pos-left-text'))).single.data!;
  await tester.tapAt(const Offset(400, 600)); // and away again
  await tester.pump();
  return t;
}

/// Lets the reader's real work (chapters loading, laying out, counting) run, with frames between.
Future<void> settleEpub(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// [n] chapters of 40 paragraphs; [failing]: one whose file is missing (it fails every time it's loaded).
MemorySource chapters(int n, {String? failing}) => MemorySource({
      for (var i = 1; i <= n; i++)
        if ('c$i.xhtml' != failing)
          'c$i.xhtml': '<html><body><h1>Chapter $i</h1>${List.filled(40, para('word$i', 40)).join()}</body></html>',
    }, EpubInfo(spine: [for (var i = 1; i <= n; i++) 'c$i.xhtml'],
        toc: [for (var i = 1; i <= n; i++) TocEntry('Chapter $i', 'c$i.xhtml', 0)], title: 'Book'));

/// The chapter by its name on top (the right spot has no number - user, 2026-10-07), then its page:
/// "Chapter 5 · Ch. · Pg. 3/9".
Future<String> inChapter(WidgetTester tester) async {
  await tester.tapAt(const Offset(400, 600));
  await tester.pump();
  final name = tester.widgetList<Text>(find.byKey(const ValueKey('pos-centre-text'))).single.data!;
  final t = '$name · ${tester.widgetList<Text>(find.byKey(const ValueKey('pos-right-text'))).single.data!}';
  await tester.tapAt(const Offset(400, 600));
  await tester.pump();
  return t;
}

/// Contents opened from the controls, and [entry] picked.
Future<void> contentsTo(WidgetTester tester, String entry) async {
  await tester.tapAt(const Offset(400, 600));
  await tester.pump();
  await tester.tap(find.byTooltip('Contents'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(entry));
  await tester.pump();
}
