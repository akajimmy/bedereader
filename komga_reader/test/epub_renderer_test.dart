// The EPUB renderer in the one Reader (lib/reader/epub_renderer.dart) over a small book held in memory.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/epub/count_store.dart';
import 'package:komga_reader/epub/source.dart';
import 'package:komga_reader/screens/open_book.dart';
import 'package:komga_reader/screens/reader.dart';
import 'package:komga_reader/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/epub_books.dart';
import 'support/no_network.dart';
import 'support/reader_server.dart';

/// A Komga that knows the book after this one ([next]; null: the series' last) and serves a 1-pixel poster.
class EndKomga extends TestKomga {
  EndKomga(this.next);
  final Map<String, dynamic>? next;
  @override
  Future<Map<String, dynamic>?> nextBook(String bookId, {String? readListId}) async => next;
  @override
  ImageProvider thumbImage(String ref) => MemoryImage(onePixelPng);
}

/// A book in a series and in a read list RL1: next in the series is [series], next in the read list [inList]; what
/// was asked is kept.
class ReadListKomga extends TestKomga {
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

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppSettings.instance.setDisplay(const DisplayPrefs());
  });

  Future<void> open(WidgetTester tester, MemorySource source, {Komga? api}) async {
    tester.view.physicalSize = const Size(800, 1200);
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

  Future<String> label(WidgetTester tester) async {
    await tester.tapAt(const Offset(400, 600)); // the middle: the controls
    await tester.pump();
    final t = tester.widgetList<Text>(find.byKey(const ValueKey('pos-left-text'))).single.data!;
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

  testWidgets('EPUBs and comics open in the one Reader (user, 2026-10-07), each with its renderer', (tester) async {
    final api = plainKomga();
    expect(readerFor(api, {'id': 'e', 'media': {'mediaProfile': 'EPUB'}}), isA<ReaderScreen>());
    expect(readerFor(api, {'id': 'c', 'media': {'mediaProfile': 'DIVINA'}}), isA<ReaderScreen>());
    expect(isEpub({'id': 'e', 'media': {'mediaProfile': 'EPUB'}}), isTrue);
    expect(isEpub({'id': 'c', 'media': {'mediaProfile': 'DIVINA'}}), isFalse);
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
    expect(find.text('End of book'), findsOneWidget);
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
    // the chapter by its name on top (the right spot has no number - user, 2026-10-07), then its page: "Chapter 5 · Ch. · Pg. 3/9"
    final name = tester.widgetList<Text>(find.byKey(const ValueKey('pos-centre-text'))).single.data!;
    final t = '$name · ${tester.widgetList<Text>(find.byKey(const ValueKey('pos-right-text'))).single.data!}';
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
    final at = await inChapter(tester); // "Chapter 5 · Ch. · Pg. X/Y"
    final m = RegExp(r'Pg\. (\d+)/(\d+)').firstMatch(at)!;
    expect(at, startsWith('Chapter 5 '));
    expect(m.group(1), m.group(2), reason: 'the last page of chapter 5: $at');
  });

  testWidgets('R2: a chapter that keeps failing leaves the controls and turns working - past it to the next chapter',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: noNetwork(() => EndKomga(null)),
        book: const {'id': 'B1', 'name': 'Book', 'media': {'mediaProfile': 'EPUB'}},
        epubSource: chapters(3, failing: 'c2.xhtml'), saveProgress: false)));
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
    expect(await inChapter(tester), startsWith('Chapter 3 '));
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

  testWidgets("R3: a swipe past a chapter's last page goes on into the next (the whole book is one page view)",
      (tester) async {
    await open(tester, chapters(7));
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
    expect(await inChapter(tester), startsWith('Chapter 2 '));
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

  testWidgets('the rotation lock holds in EPUBs too (it was offered in the panel but never applied): one way up, the '
      'way the tablet is held; it ends with the book', (tester) async {
    final requests = <Object?>[];
    var wayUp = 'reverseLandscape';
    final m = tester.binding.defaultBinaryMessenger;
    m.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') requests.add(call.arguments);
      return null;
    });
    m.setMockMethodCallHandler(const MethodChannel('komga_reader/screen'),
        (call) async => call.method == 'currentWayUp' ? wayUp : null);
    final s = AppSettings.instance;
    addTearDown(() {
      s.setDisplay(s.display.copyWith(rotation: Rotation.auto));
      m.setMockMethodCallHandler(SystemChannels.platform, null);
      m.setMockMethodCallHandler(const MethodChannel('komga_reader/screen'), null);
    });
    s.setDisplay(s.display.copyWith(rotation: Rotation.landscape));
    await open(tester, twoChapters());
    expect(requests, anyElement(equals(['DeviceOrientation.landscapeRight'])), reason: 'held the way it was held');
    wayUp = 'portrait';
    s.setDisplay(s.display.copyWith(rotation: Rotation.portrait)); // changed in the panel
    await tester.pump();
    await tester.pump();
    expect(requests.last, ['DeviceOrientation.portraitUp']);
    await tester.pumpWidget(const SizedBox());
    expect(requests.last, isEmpty, reason: 'closed: the app follows the device again');
  });

  testWidgets('a held Right key keeps turning pages, one each time the slide ends (user, build 82, Windows: it crept '
      'and never turned - each repeat restarted the slide)', (tester) async {
    await open(tester, chapters(1));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    for (var i = 0; i < 30; i++) {
      // a keyboard's repeats, about 30 a second, for about a second
      await tester.pump(const Duration(milliseconds: 33));
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    final page = int.parse(RegExp(r'Pg\. (\d+)/').firstMatch(await label(tester))![1]!);
    expect(page, greaterThanOrEqualTo(3), reason: 'about a second of a held key: a few pages on');
  });

  testWidgets('a held remote button that sends fresh presses turns a page each time the slide ends, and stops '
      'after one more when let go; quick taps turn a page each - never creeping (user, 2026-10-07: each turn asked '
      'for mid-slide started the slide over, and the page crept without turning)', (tester) async {
    await open(tester, chapters(1));
    int at() => (tester.widget<PageView>(find.byType(PageView)).controller!.page ?? 0).round();
    // a remote held: a fresh press every 50 ms for about a second (not the keyboard's repeats)
    for (var i = 0; i < 20; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 50));
    }
    final held = at();
    expect(held, greaterThanOrEqualTo(2), reason: 'about a second held: a page per slide (it crept on page 0-1)');
    await settle(tester);
    expect(at(), lessThanOrEqualTo(held + 1), reason: 'let go: at most one more');
    final c = tester.widget<PageView>(find.byType(PageView)).controller!;
    expect(c.page, c.page!.roundToDouble(), reason: 'it settles on a page');

    // three quick taps on the right, 60 ms apart: three pages
    final before = at();
    for (var i = 0; i < 3; i++) {
      await tester.tapAt(const Offset(750, 600));
      await tester.pump(const Duration(milliseconds: 60));
    }
    await settle(tester);
    expect(at(), before + 3);
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
    expect(find.byType(ReaderScreen), findsOneWidget);
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
      "the left and the chapter's page at the right; the page's corner has the book's page of its pages (\"1 / 342\", "
      "as comics' - user 2026-10-07) - always, for a moment after a turn, or not at all", (tester) async {
    await open(tester, twoChapters());
    String corner() => tester.widget<Text>(find.byKey(const ValueKey('page-corner'))).data!;
    double cornerOpacity() => tester.widget<AnimatedOpacity>(
        find.ancestor(of: find.byKey(const ValueKey('page-corner')), matching: find.byType(AnimatedOpacity))).opacity;
    expect(corner(), matches(RegExp(r'^1 / \d+$')), reason: "the book's page of its pages, as comics'");
    expect(cornerOpacity(), 1, reason: 'Always (the default)');
    await tester.tapAt(const Offset(400, 600));
    await tester.pump();
    expect(cornerOpacity(), 0, reason: 'not under the controls');
    expect(tester.widget<Text>(find.byKey(const ValueKey('pos-centre-text'))).data, 'One');
    expect(tester.widget<Text>(find.byKey(const ValueKey('pos-right-text'))).data, matches(RegExp(r'^Ch\. · Pg\. 1/\d+$')),
        reason: "no chapter number: it's the book's file count, not the chapter's (user, 2026-10-07)");
    expect(tester.widget<Text>(find.byKey(const ValueKey('pos-left-text'))).data,
        matches(RegExp(r'^Book · Pg\. 1/\d+ · \d+%$')));
    await tester.tapAt(const Offset(400, 600));
    await tester.pump();
    // After a turn: hidden until a page turns, then for a moment
    AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(pageNote: PageNote.afterTurn));
    await tester.pump();
    expect(cornerOpacity(), 0);
    await tester.tapAt(const Offset(750, 600));
    await settle(tester);
    expect(cornerOpacity(), 1, reason: 'just turned');
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 300));
    expect(cornerOpacity(), 0, reason: 'a moment later');
    // Off: no corner
    AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(pageNote: PageNote.off));
    await tester.pump();
    expect(find.byKey(const ValueKey('page-corner')), findsNothing);
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
    unawaited(nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => ReaderScreen(
        api: noNetwork(() => EndKomga(const {'id': 'B2', 'seriesTitle': 'Homeland', 'metadata': {'number': '2',
            'title': 'Exile'}})),
        book: const {'id': 'B1', 'name': 'Book', 'media': {'mediaProfile': 'EPUB'}},
        epubSource: MemorySource({'c1.xhtml': '<html><body><p>A short book.</p></body></html>'},
            const EpubInfo(spine: ['c1.xhtml'], toc: [])),
        saveProgress: false))));
    for (var i = 0; i < 60 && find.byType(PageView).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    String? focused() => FocusManager.instance.primaryFocus?.debugLabel;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight); // the only page -> the end card
    await settle(tester);
    expect(find.text('End of book'), findsOneWidget);
    expect(find.text('Homeland #2'), findsOneWidget);
    expect(find.text('Exile'), findsOneWidget);
    expect(find.byKey(const ValueKey('next-poster')), findsOneWidget);
    expect(focused(), 'end-next', reason: 'the remote starts on Next book');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(focused(), 'end-close');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(focused(), 'end-next');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft); // back to the last page
    await settle(tester);
    expect(find.text('End of book'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter); // OK on Close
    await settle(tester);
    await tester.pumpAndSettle();
    expect(find.byType(ReaderScreen), findsNothing, reason: 'closed');
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('one Reader for both kinds (user, 2026-10-07): from an EPUB\'s end card Next book opens a comic in the '
      'same Reader - no new screen; the EPUB has Night and Delete in its top bar; a Contents jump leaves the way back '
      'marked on the slider', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = noNetwork(ReaderServer.new)
      ..next = {'id': 'B2', 'seriesId': 'S1', 'seriesTitle': 'Test', 'metadata': {'number': '2', 'title': 'Comic'}};
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: api,
        book: const {'id': 'H1', 'name': 'Book', 'media': {'mediaProfile': 'EPUB'}},
        epubSource: chapters(3), saveProgress: false)));
    for (var i = 0; i < 60 && find.byType(PageView).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    // the top bar: Night and Delete, as comics have (decision 2)
    await tester.tapAt(const Offset(400, 600));
    await tester.pump();
    expect(find.byTooltip('Night mode on'), findsOneWidget);
    expect(find.byTooltip('Delete book'), findsOneWidget);
    // a jump through Contents: the way back is marked on the slider (decision 4)
    await tester.tap(find.byTooltip('Contents'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chapter 3'));
    await settle(tester);
    await tester.tapAt(const Offset(400, 600));
    await tester.pump();
    expect(find.byKey(const ValueKey('scrub-start')), findsOneWidget, reason: 'the way back to chapter 1');
    await tester.tapAt(const Offset(400, 600));
    await tester.pump();
    // on to the end card, then Next book (OK): the comic opens in the same Reader
    for (var i = 0; i < 40 && find.text('End of book').evaluate().isEmpty; i++) {
      await tester.tapAt(const Offset(750, 600));
      await settle(tester);
    }
    expect(find.text('Test #2'), findsOneWidget, reason: 'the end card shows the comic up next');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(api.marked, ['H1'], reason: 'the EPUB left from its end card is read');
    expect(find.byType(ReaderScreen), findsOneWidget, reason: 'the same Reader');
    expect(tester.widget<Text>(find.byKey(const ValueKey('page-corner'))).data, '1 / 3', reason: "the comic's pages");
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets("opened from a read list, the next and previous books are the read list's (user, 2026-10-07: "
      "Hitchhiker's Guide from the NPR Top 100 list went on to its series' book 2, not Ender's Game); opened from "
      "its series, the series'", (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const hitchhiker = {'id': 'H1', 'name': 'Hitchhiker', 'media': {'mediaProfile': 'EPUB'}};
    // readerFor - every place that opens a book, the next book's reader included - hands the read list and skip read
    // on (they were dropped for EPUBs)
    final handed = readerFor(noNetwork(ReadListKomga.new), hitchhiker, readListId: 'RL1', skipRead: true);
    expect(handed, isA<ReaderScreen>());
    expect(((handed as ReaderScreen).readListId, handed.skipRead), ('RL1', true));

    for (final list in ['RL1', null]) {
      final api = noNetwork(ReadListKomga.new);
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ReaderScreen(
            api: api, book: hitchhiker, readListId: list, saveProgress: false,
            epubSource: MemorySource({'c1.xhtml': '<html><body><p>A short book.</p></body></html>'},
                const EpubInfo(spine: ['c1.xhtml'], toc: []))))),
        child: const Text('open'),
      ))));
      await tester.tap(find.text('open'));
      for (var i = 0; i < 60 && find.byType(PageView).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight); // the only page -> the end card
      await settle(tester);
      expect(find.text(list == null ? 'Up next in the series' : 'Up next in this read list'), findsOneWidget);
      expect(find.text(list == null ? 'Hitchhiker #2' : 'Ender #1'), findsOneWidget);
      expect(api.listNextAsked, [list]);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft); // back to the page
      await settle(tester);
      await tester.tapAt(const Offset(400, 600)); // the controls
      await tester.pump();
      await tester.tap(find.byTooltip('Previous book'));
      await settle(tester);
      expect(api.listPrevAsked, [list]);
      expect(find.text(list == null ? 'This is the first book of the series' : 'This is the first book of the read list'),
          findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('the book shows once it is counted (user, 2026-10-07): until then a spinner with the chapter being '
      'counted, and Close; nothing on it turns or opens the controls', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final spine = [for (var i = 0; i < 6; i++) 'c$i.xhtml'];
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: nav, home: const Text('home')));
    // the last chapter never comes: the book is never counted
    unawaited(nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => ReaderScreen(
        api: noNetwork(() => EndKomga(null)), book: const {'id': 'B1', 'name': 'Book', 'media': {'mediaProfile': 'EPUB'}},
        epubSource: HangingSource({for (final c in spine) c: '<html><body>${para('delta', 40)}</body></html>'},
            EpubInfo(spine: spine, toc: const []), hangs: 'c5.xhtml'),
        saveProgress: false))));
    await settle(tester);
    expect(find.text('Laying out the book'), findsOneWidget);
    expect(find.text('Chapter 6 of 6'), findsOneWidget, reason: 'five counted, on the sixth');
    expect(find.byType(PageView), findsNothing, reason: 'no page before the book is counted');
    await tester.tapAt(const Offset(750, 300)); // a turn's tap
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.tapAt(const Offset(400, 300)); // the controls' tap
    await settle(tester);
    expect(find.byTooltip('Contents'), findsNothing);
    expect(find.text('Chapter 6 of 6'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget, reason: 'closed');
  });

  testWidgets('counts are remembered per book and layout: opened again the same way, the book shows at once - even '
      'with a chapter that would never come; at another text size it is counted again', (tester) async {
    final store = MemoryCountStore();
    EpubCountStore.instance = store;
    addTearDown(() {
      EpubCountStore.instance = FileCountStore();
      AppSettings.instance.setEpub(const EpubPrefs());
    });
    final spine = [for (var i = 0; i < 6; i++) 'c$i.xhtml'];
    final files = {for (final c in spine) c: '<html><body>${List.filled(4, para('delta', 40)).join()}</body></html>'};
    final info = EpubInfo(spine: spine, toc: const []);
    await open(tester, MemorySource(files, info));
    final first = await label(tester);
    expect(store.kept, hasLength(1), reason: 'counted, and kept');
    await tester.pumpWidget(const SizedBox());

    // the same book again, its last chapter never coming: the counts kept stand in
    await open(tester, HangingSource(files, info, hangs: 'c5.xhtml'));
    expect(await label(tester), first, reason: 'the same page of the same count, at once');

    // another text size: another layout, counted (the hanging chapter keeps it on the spinner)
    AppSettings.instance.setEpub(AppSettings.instance.epub.copyWith(size: 28));
    await settle(tester);
    expect(find.text('Laying out the book'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a footnote marker opens the note over the page; the page stays', (tester) async {
    await open(tester, MemorySource({
      'c1.xhtml': '<html><body><p>Here<a href="notes.xhtml#n1">*</a> is a note.</p></body></html>',
      'notes.xhtml': '<html><body><p id="n1"><a href="c1.xhtml">*</a>The note itself.</p></body></html>',
    }, const EpubInfo(spine: ['c1.xhtml', 'notes.xhtml'], toc: [])));
    // the marker sits right after "Here" on the first line: find it through the page's links
    final state = tester.state(find.byType(ReaderScreen));
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
