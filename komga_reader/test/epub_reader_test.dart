// The EPUB reader screen (lib/screens/epub_reader.dart) over a small book held in memory.
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/epub/source.dart';
import 'package:komga_reader/screens/epub_reader.dart';
import 'package:komga_reader/screens/open_book.dart';
import 'package:komga_reader/screens/reader.dart';
import 'package:komga_reader/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/no_network.dart';

class MemorySource implements EpubSource {
  MemorySource(this.files, this.infoValue, {this.binary = const {}});
  final Map<String, String> files;
  final Map<String, Uint8List> binary; // pictures
  final EpubInfo infoValue;
  @override
  Future<EpubInfo> info() async => infoValue;
  @override
  Future<Uint8List> resource(String path) async {
    final pic = binary[path];
    if (pic != null) return pic;
    final f = files[path];
    if (f == null) throw StateError('no $path');
    return Uint8List.fromList(utf8.encode(f));
  }
}

/// A [MemorySource] whose files take a moment to read (a chapter coming back takes a while, as on a device).
class SlowSource extends MemorySource {
  SlowSource(super.files, super.infoValue);
  bool slow = false; // on once the book is open (its first loads run before the test's clock does)
  @override
  Future<Uint8List> resource(String path) async {
    if (slow) await Future<void>.delayed(const Duration(milliseconds: 30));
    return super.resource(path);
  }
}

/// A Komga that knows the book after this one ([next]; null: the series' last) and serves a 1-pixel poster.
class EndKomga extends TestKomga {
  EndKomga(this.next);
  final Map<String, dynamic>? next;
  @override
  Future<Map<String, dynamic>?> nextBook(String bookId, {String? readListId}) async => next;
  @override
  ImageProvider thumbImage(String ref) => MemoryImage(onePixelPng);
}

/// A 1 x 1 PNG.
final onePixelPng = Uint8List.fromList(base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='));

/// A [MemorySource] where one file ([hangs]) never comes: the book is never wholly counted.
class HangingSource extends MemorySource {
  HangingSource(super.files, super.infoValue, {required this.hangs});
  final String hangs;
  @override
  Future<Uint8List> resource(String path) => path == hangs ? Completer<Uint8List>().future : super.resource(path);
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

  Future<void> open(WidgetTester tester, MemorySource source, {Komga? api}) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: EpubReaderScreen(api: api ?? noNetwork(() => EndKomga(null)),
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
    final t = tester.widgetList<Text>(find.byKey(const ValueKey('epub-book-position'))).single.data!;
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
    expect(await label(tester), startsWith('Book · Pg. 1/'));
    await tester.tapAt(const Offset(750, 600));
    await settle(tester);
    expect(await label(tester), startsWith('Book · Pg. 2/'));
    await tester.tapAt(const Offset(50, 600));
    await settle(tester);
    expect(await label(tester), startsWith('Book · Pg. 1/'));
  });

  testWidgets("the pages either side are built ahead, as the comic reader's are: a tap's turn doesn't build the "
      'incoming page in its first frame (tap turns missed a refresh there - tablet, build 76)', (tester) async {
    await open(tester, twoChapters());
    expect(tester.widget<PageView>(find.byType(PageView)).allowImplicitScrolling, isTrue);
    expect(find.byType(CustomPaint, skipOffstage: false).evaluate().length, greaterThan(1),
        reason: 'the next page exists before any turn');
  });

  testWidgets("resizing the window there and back lands on the same page - each new size used to start from the page "
      'on screen, earlier than the place, and walked back (Windows, build 79: two resizes and back, a page back)',
      (tester) async {
    final words = [for (var i = 0; i < 400; i++) ['a', 'bb', 'ccc', 'dddd', 'eeeee'][i % 5]].join(' ');
    await open(tester, MemorySource({
      'c1.xhtml': '<html><body>${List.filled(6, '<p>$words</p>').join()}</body></html>',
    }, const EpubInfo(spine: ['c1.xhtml'], toc: [], title: 'Book')));
    for (var i = 0; i < 5; i++) {
      await tester.tapAt(const Offset(750, 600));
      await settle(tester);
    }
    final before = await label(tester);
    for (final s in const [Size(560, 1200), Size(1000, 700), Size(700, 1000), Size(800, 1200)]) {
      tester.view.physicalSize = s;
      await tester.pump();
      await settle(tester);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await settle(tester);
    }
    expect(await label(tester), before, reason: 'back at the first size: the same page');
  });

  testWidgets('the mouse wheel turns pages, as with comics (it did nothing in the Windows app - build 79)',
      (tester) async {
    await open(tester, twoChapters());
    expect(await label(tester), startsWith('Book · Pg. 1/'));
    Future<void> wheel(double dy) async {
      final pointer = TestPointer(1, PointerDeviceKind.mouse)..hover(const Offset(400, 600));
      await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
      await settle(tester);
    }
    await wheel(120); // one notch down
    expect(await label(tester), startsWith('Book · Pg. 2/'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300))); // a turn at most every 250 ms
    await wheel(-120); // and up
    expect(await label(tester), startsWith('Book · Pg. 1/'));
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
    final total = int.parse(RegExp(r'/(\d+) ·').firstMatch(atTwo)!.group(1)!);
    final here = int.parse(RegExp(r'Pg\. (\d+)/').firstMatch(atTwo)!.group(1)!);
    expect(here, greaterThan(1), reason: 'chapter two is past chapter one');
    // to the end and past it
    for (var i = here; i <= total; i++) {
      await tester.tapAt(const Offset(750, 600));
      await settle(tester);
    }
    expect(find.text('The End'), findsOneWidget);
  });

  // ---- moving through the book (EPUB review 2026-10-06, R1-R3)

  /// [n] chapters; [failing]: one whose file is missing (it fails every time it's loaded).
  MemorySource chapters(int n, {String? failing}) => MemorySource({
        for (var i = 1; i <= n; i++)
          if ('c$i.xhtml' != failing)
            'c$i.xhtml': '<html><body><h1>Chapter $i</h1>${List.filled(40, para('word$i', 40)).join()}</body></html>',
      }, EpubInfo(spine: [for (var i = 1; i <= n; i++) 'c$i.xhtml'],
          toc: [for (var i = 1; i <= n; i++) TocEntry('Chapter $i', 'c$i.xhtml', 0)], title: 'Book'));

  Future<String> inChapter(WidgetTester tester) async {
    await tester.tapAt(const Offset(400, 600));
    await tester.pump();
    final t = tester.widgetList<Text>(find.byKey(const ValueKey('epub-chapter-position'))).single.data!;
    await tester.tapAt(const Offset(400, 600));
    await tester.pump();
    return t;
  }

  Future<void> contentsTo(WidgetTester tester, String entry) async {
    await tester.tapAt(const Offset(400, 600));
    await tester.pump();
    await tester.tap(find.byTooltip('Contents'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(entry));
    await tester.pump();
  }

  testWidgets("R1: jumped far, then straight back into a chapter that isn't laid out yet - its LAST page, not its "
      'first', (tester) async {
    await open(tester, chapters(7));
    await contentsTo(tester, 'Chapter 6');
    await tester.pump(const Duration(milliseconds: 50)); // straight back - before chapter 5 is laid out ahead
    await tester.tapAt(const Offset(50, 600));
    await settle(tester);
    final at = await inChapter(tester); // "Ch. 5 · Pg. X/Y"
    final m = RegExp(r'Pg\. (\d+)/(\d+)').firstMatch(at)!;
    expect(at, startsWith('Ch. 5'));
    expect(m.group(1), m.group(2), reason: 'the last page of chapter 5: $at');
  });

  testWidgets('R2: a chapter that keeps failing leaves the controls and turns working - past it to the next chapter',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: EpubReaderScreen(api: noNetwork(() => EndKomga(null)),
        book: const {'id': 'B1', 'name': 'Book', 'media': {'mediaProfile': 'EPUB'}},
        source: chapters(3, failing: 'c2.xhtml'), saveProgress: false)));
    for (var i = 0; i < 40 && find.byType(PageView).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    // into chapter 2 (it fails), with the controls
    await contentsTo(tester, 'Chapter 2');
    await settle(tester);
    expect(find.text('Retry'), findsOneWidget);
    await tester.tapAt(const Offset(400, 600)); // the controls still come up
    await tester.pump();
    expect(find.byTooltip('Contents'), findsOneWidget);
    await tester.tapAt(const Offset(400, 600));
    await tester.pump();
    await tester.tapAt(const Offset(750, 600)); // and a turn goes on to chapter 3
    await settle(tester);
    expect(find.text('Retry'), findsNothing);
    expect(await inChapter(tester), startsWith('Ch. 3'));
  });

  testWidgets('R12: the window shrunk to nothing (minimised) and back - the same page, not the chapter start',
      (tester) async {
    await open(tester, chapters(3));
    for (var i = 0; i < 4; i++) {
      await tester.tapAt(const Offset(750, 600));
      await settle(tester);
    }
    final before = await label(tester);
    tester.view.physicalSize = Size.zero;
    await tester.pump();
    await settle(tester);
    tester.view.physicalSize = const Size(800, 1200);
    await tester.pump();
    await settle(tester);
    // (the place, not the wording: counting may finish meanwhile - "16%" becomes "Pg. 5/27 · 16%")
    String pct(String l) => RegExp(r'(\d+)%').firstMatch(l)!.group(1)!;
    expect(pct(await label(tester)), pct(before));
  });

  testWidgets("R3: chapter by chapter (not counted yet), a swipe past the chapter's last page goes on to the next",
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // one chapter never comes: the book is never wholly counted - it stays chapter by chapter
    await tester.pumpWidget(MaterialApp(home: EpubReaderScreen(api: noNetwork(() => EndKomga(null)),
        book: const {'id': 'B1', 'name': 'Book', 'media': {'mediaProfile': 'EPUB'}},
        source: HangingSource(chapters(7).files, chapters(7).infoValue, hangs: 'c7.xhtml'), saveProgress: false)));
    for (var i = 0; i < 40 && find.byType(PageView).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await settle(tester);
    // to chapter 1's last page by taps, then swipe on
    for (var i = 0; i < 40; i++) {
      final at = await inChapter(tester);
      final m = RegExp(r'Pg\. (\d+)/(\d+)').firstMatch(at)!;
      if (m.group(1) == m.group(2)) break;
      await tester.tapAt(const Offset(750, 600));
      await settle(tester);
    }
    await tester.fling(find.byType(PageView), const Offset(-500, 0), 2000);
    await settle(tester);
    expect(await inChapter(tester), startsWith('Ch. 2'));
  });

  testWidgets("the EPUB reader's panels (Aa, Contents) look like the comic reader's: a side sheet with its title and "
      'Done on a wide screen', (tester) async {
    await open(tester, twoChapters());
    for (final (tooltip, title) in [('Text and page settings', 'Text and page'), ('Contents', 'Contents')]) {
      if (find.byTooltip(tooltip).evaluate().isEmpty) {
        await tester.tapAt(const Offset(400, 600)); // the controls (they stay up behind a panel, as with comics)
        await tester.pump();
      }
      await tester.tap(find.byTooltip(tooltip));
      await tester.pumpAndSettle();
      expect(find.text(title), findsWidgets);
      expect(find.text('Done'), findsOneWidget, reason: '$title: the comic panels\' Done');
      final sheet = tester.getSize(find.byWidgetPredicate(
          (w) => w is Material && w.color == const Color(0xF2141416))); // the comic panels' sheet colour
      expect(sheet.width, 380, reason: "$title: the comic panels' side sheet");
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('the remote: Right turns forward, Left back, OK shows the controls', (tester) async {
    await open(tester, twoChapters());
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    expect(await label(tester), startsWith('Book · Pg. 2/'));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await settle(tester);
    expect(await label(tester), startsWith('Book · Pg. 1/'));
  });

  testWidgets("with the controls up the remote walks them (the comic reader's model): Down to the bottom bar, Right "
      'along it, OK presses; Back closes the controls, not the book', (tester) async {
    await open(tester, twoChapters());
    await tester.sendKeyEvent(LogicalKeyboardKey.enter); // OK: the controls
    await tester.pump();
    expect(find.text('Close'), findsOneWidget, reason: "the comic reader's Close button");
    final before = await (() async => tester.widget<Text>(find.textContaining(RegExp(r'^Book · Pg\. \d+/\d+ · '))).data!)();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown); // the bottom bar: Previous book
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight); // the slider
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight); // Contents
    await tester.pump();
    expect(tester.widget<Text>(find.textContaining(RegExp(r'^Book · Pg\. \d+/\d+ · '))).data, before, reason: 'Right moved, not turned');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter); // presses Contents
    await tester.pumpAndSettle();
    expect(find.text('Contents'), findsWidgets);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    // Back: the controls go, the book stays
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    await nav.maybePop();
    await tester.pumpAndSettle();
    expect(find.text('Close'), findsNothing);
    expect(find.byType(EpubReaderScreen), findsOneWidget);
  });

  testWidgets('the slider: the position shown follows the finger while dragging; the page changes when it lifts',
      (tester) async {
    // six chapters, each a moment to load: the far one, let go of after counting, takes a while to come back
    final spine = [for (var i = 0; i < 6; i++) 'c$i.xhtml'];
    final source = SlowSource({for (final c in spine) c: '<html><body>${List.filled(6, para('gamma', 40)).join()}'
        '</body></html>'}, EpubInfo(spine: spine, toc: const []));
    await open(tester, source);
    await tester.tapAt(const Offset(400, 600));
    await tester.pump();
    for (var i = 0; i < 100 && find.textContaining(RegExp(r'^Book · Pg\. \d+/\d+ · ')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20))); // counted: "Book · Pg. X/Y - n%"
      await tester.pump(const Duration(milliseconds: 50)); // (counting pauses between chapters on the test's clock)
    }
    source.slow = true;
    final slider = find.byType(Slider);
    final r = tester.getRect(slider);
    final g = await tester.startGesture(r.centerLeft + const Offset(24, 0));
    await tester.pump();
    final start = tester.widget<Text>(find.textContaining(RegExp(r'^Book · Pg\. \d+/\d+ · '))).data!;
    await g.moveTo(r.centerRight - const Offset(24, 0));
    await tester.pump();
    final dragged = tester.widget<Text>(find.textContaining(RegExp(r'^Book · Pg\. \d+/\d+ · '))).data!;
    expect(dragged, isNot(start), reason: 'the label moves with the finger');
    await g.up();
    await tester.pump(); // the finger up: still on the page picked while the reader goes there - not back to where it
    // was for a moment, then the new page (the slider jumped - user, build 70)
    expect(tester.widget<Text>(find.textContaining(RegExp(r'^Book · Pg\. \d+/\d+ · '))).data, dragged);
    await settle(tester);
    expect(tester.widget<Text>(find.textContaining(RegExp(r'^Book · Pg\. \d+/\d+ · '))).data, dragged, reason: 'gone there');
  });

  testWidgets('a big picture tapped in the middle opens full screen over the book; a tap closes it; a small one '
      "(a banner) doesn't open, the middle shows the controls", (tester) async {
    Future<Uint8List> png(int w, int h) async {
      final rec = ui.PictureRecorder();
      Canvas(rec).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = const Color(0xFF808080));
      final img = await rec.endRecording().toImage(w, h);
      return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    }
    final (map, banner) = (await tester.runAsync(() async => (await png(300, 500), await png(321, 96))))!;
    await open(tester, MemorySource({
      'c1.xhtml': '<html><body><p><img src="map.png"/></p></body></html>',
      'c2.xhtml': '<html><body><p><img src="banner.png"/></p>${para('word', 30)}</body></html>',
    }, const EpubInfo(spine: ['c1.xhtml', 'c2.xhtml'], toc: []), binary: {'map.png': map, 'banner.png': banner}));
    // the map: a chapter of its own, at its own size, centred (300 x 500 at 250..550 x 350..850 on the 800 x 1200,
    // 1:1 screen) - a tap on it in the middle opens it
    await tester.tapAt(const Offset(400, 600));
    await settle(tester);
    expect(find.byType(RawImage), findsOneWidget, reason: 'the picture full screen');
    await tester.tapAt(const Offset(400, 600));
    await settle(tester);
    expect(find.byType(RawImage), findsNothing, reason: 'a tap closed it');
    expect(find.text('Close'), findsNothing, reason: 'and the controls stayed hidden');
    // the next chapter: a banner (96 tall) at the top - not opened; the middle shows the controls as usual
    await tester.tapAt(const Offset(750, 600));
    await settle(tester);
    await tester.tapAt(const Offset(400, 80));
    await settle(tester);
    expect(find.byType(RawImage), findsNothing, reason: 'a banner does not open');
    expect(find.text('Close'), findsOneWidget, reason: 'the controls instead');
  });

  testWidgets("where you are (user's options F + H): the bar has the chapter's name with the book's page and % at "
      "the left and the chapter's page at the right; the page's corner has the pages left in the chapter and the "
      "book's % - always, for a moment after a turn, or not at all", (tester) async {
    await open(tester, twoChapters());
    String corner() => tester.widget<Text>(find.byKey(const ValueKey('epub-corner'))).data!;
    double cornerOpacity() => tester.widget<AnimatedOpacity>(
        find.ancestor(of: find.byKey(const ValueKey('epub-corner')), matching: find.byType(AnimatedOpacity))).opacity;
    expect(corner(), matches(RegExp(r'^\d+ left in chapter · \d+%$')));
    expect(cornerOpacity(), 1, reason: 'Always (the default)');
    await tester.tapAt(const Offset(400, 600));
    await tester.pump();
    expect(find.byKey(const ValueKey('epub-corner')), findsNothing, reason: 'not under the controls');
    expect(tester.widget<Text>(find.byKey(const ValueKey('epub-chapter-title'))).data, 'One');
    expect(tester.widget<Text>(find.byKey(const ValueKey('epub-chapter-position'))).data, matches(RegExp(r'^Ch\. 1 · Pg\. 1/\d+$')));
    expect(tester.widget<Text>(find.byKey(const ValueKey('epub-book-position'))).data,
        matches(RegExp(r'^Book · Pg\. 1/\d+ · \d+%$')));
    await tester.tapAt(const Offset(400, 600));
    await tester.pump();
    // After a turn: hidden until a page turns, then for a moment
    AppSettings.instance.setEpub(AppSettings.instance.epub.copyWith(corner: EpubCorner.afterTurn));
    await tester.pump();
    expect(cornerOpacity(), 0);
    await tester.tapAt(const Offset(750, 600));
    await settle(tester);
    expect(cornerOpacity(), 1, reason: 'just turned');
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 300));
    expect(cornerOpacity(), 0, reason: 'a moment later');
    // Off: no corner
    AppSettings.instance.setEpub(AppSettings.instance.epub.copyWith(corner: EpubCorner.off));
    await tester.pump();
    expect(find.byKey(const ValueKey('epub-corner')), findsNothing);
    AppSettings.instance.setEpub(const EpubPrefs());
  });

  testWidgets("the end card: the next book's poster and title (as in the comic reader); the remote on Next book, "
      'Down to Close, Up back, Left to the last page; OK on Close closes the book (user, build 71: the remote could '
      'reach neither)', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: nav, home: const Text('home')));
    unawaited(nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => EpubReaderScreen(
        api: noNetwork(() => EndKomga(const {'id': 'B2', 'seriesTitle': 'Homeland', 'metadata': {'number': '2',
            'title': 'Exile'}})),
        book: const {'id': 'B1', 'name': 'Book', 'media': {'mediaProfile': 'EPUB'}},
        source: MemorySource({'c1.xhtml': '<html><body><p>A short book.</p></body></html>'},
            const EpubInfo(spine: ['c1.xhtml'], toc: [])),
        saveProgress: false))));
    for (var i = 0; i < 60 && find.byType(PageView).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    String? focused() => FocusManager.instance.primaryFocus?.debugLabel;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight); // the only page -> the end card
    await settle(tester);
    expect(find.text('The End'), findsOneWidget);
    expect(find.text('Homeland #2'), findsOneWidget);
    expect(find.text('Exile'), findsOneWidget);
    expect(find.byKey(const ValueKey('next-poster')), findsOneWidget);
    expect(focused(), 'epub-end-next', reason: 'the remote starts on Next book');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(focused(), 'epub-end-close');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(focused(), 'epub-end-next');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft); // back to the last page
    await settle(tester);
    expect(find.text('The End'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter); // OK on Close
    await settle(tester);
    await tester.pumpAndSettle();
    expect(find.byType(EpubReaderScreen), findsNothing, reason: 'closed');
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('the slider runs through the whole book even before every chapter is counted (user: it ran through '
      "the chapter, so it couldn't go far): 60% of the way along lands in the fourth of six chapters", (tester) async {
    final spine = [for (var i = 0; i < 6; i++) 'c$i.xhtml'];
    await open(tester, HangingSource({for (final c in spine) c: '<html><body>${List.filled(4, para('delta', 40)).join()}'
        '</body></html>'}, EpubInfo(spine: spine, toc: const []), hangs: 'c5.xhtml'));
    await tester.tapAt(const Offset(400, 600));
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const ValueKey('epub-book-position'))).data, startsWith('Book · '),
        reason: 'not counted: the last chapter never comes');
    final r = tester.getRect(find.byType(Slider));
    final g = await tester.startGesture(r.centerLeft + const Offset(24, 0));
    await tester.pump();
    await g.moveTo(Offset(r.left + 20 + 0.6 * (r.width - 40), r.center.dy));
    await tester.pump();
    await g.up();
    await settle(tester);
    if (find.byKey(const ValueKey('epub-chapter-position')).evaluate().isEmpty) {
      await tester.tapAt(const Offset(400, 600));
      await tester.pump();
    }
    expect(tester.widget<Text>(find.byKey(const ValueKey('epub-chapter-position'))).data, startsWith('Ch. 4 '));
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
