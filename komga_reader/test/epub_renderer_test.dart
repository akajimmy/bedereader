// The EPUB renderer in the one Reader (lib/reader/epub_renderer.dart) over a small book held in memory.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/epub/count_store.dart';
import 'package:komga_reader/epub/layout.dart' show EpubPage;
import 'package:komga_reader/epub/source.dart';
import 'package:komga_reader/page_curl.dart';
import 'package:komga_reader/reader/epub_renderer.dart';
import 'package:komga_reader/screens/open_book.dart';
import 'package:komga_reader/screens/reader.dart';
import 'package:komga_reader/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/client_settings.dart';
import 'support/epub_books.dart';
import 'support/helpers.dart';
import 'support/no_network.dart';
import 'support/reader_server.dart';

/// A Komga that knows the book after this one ([next]; null: the series' last) and serves a 1-pixel poster.
/// A book whose chapter [fails] can't be read the first time it's asked for (the network, for a moment).
class _FailsOnce extends MemorySource {
  _FailsOnce(super.files, super.infoValue, {required this.fails});
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

class EndKomga extends TestKomga with EmptyClientSettings {
  EndKomga(this.next);
  final Map<String, dynamic>? next;
  @override
  Future<Map<String, dynamic>?> nextBook(String bookId, {String? readListId}) async => next;
  @override
  ImageProvider thumbImage(String ref) => MemoryImage(onePixelPng);
}

/// A book in a series and in a read list RL1: next in the series is [series], next in the read list [inList]; what
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

void main() {
  // the curl's shader, before any test: loaded inside a group after a widget test, it never finished (the whole file
  // hung - 2026-10-11)
  setUpAll(preloadShaders);
  late EpubCountStore counts;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppSettings.instance.setDisplay(const DisplayPrefs());
    counts = EpubCountStore.instance;
    EpubCountStore.instance = MemoryCountStore(); // each test's books counted afresh, never on disk
  });
  tearDown(() => EpubCountStore.instance = counts);

  Future<void> open(WidgetTester tester, MemorySource source, {Komga? api, Size size = const Size(800, 1200)}) async {
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

  testWidgets("the slider's thumb, dragged, shows a small drawing of the page picked, its number and chapter, over "
      'the thumb; letting go goes there (user, 2026-10-11: as comics have)', (tester) async {
    await open(tester, twoChapters());
    await tester.tapAt(const Offset(400, 600)); // the controls
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    final r = tester.getRect(find.byType(Slider));
    final g = await tester.startGesture(Offset(r.left + 20, r.center.dy)); // the thumb, on page 1
    await g.moveTo(Offset(r.left + 60, r.center.dy));
    await g.moveTo(Offset(r.right - 20, r.center.dy)); // the last page
    await tester.pump();
    for (var i = 0; i < 20 && find.byKey(const ValueKey('preview-loading')).evaluate().isNotEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    const preview = ValueKey('page-preview');
    expect(find.byKey(preview), findsOneWidget);
    expect(find.byKey(const ValueKey('preview-loading')), findsNothing, reason: 'the page drawn, not a spinner');
    expect(find.descendant(of: find.byKey(preview), matching: find.byType(CustomPaint)), findsWidgets);
    expect(find.descendant(of: find.byKey(preview), matching: find.text('Two')), findsOneWidget,
        reason: "the last page's chapter");
    final p = tester.getRect(find.byKey(preview));
    expect(p.center.dx, closeTo(r.right - 20, 1), reason: 'over the thumb');
    expect(p.bottom, lessThan(r.top));
    await g.up();
    await tester.pump();
    expect(find.byKey(preview), findsNothing);
    await settle(tester);
  });

  group('Page turn: Curl (user, 2026-10-11: the comics\' 3D curl for eBooks)', () {
    setUp(() => AppSettings.instance.setEpub(AppSettings.instance.epub.copyWith(turn: EpubTurn.curl)));
    tearDown(() => AppSettings.instance.setEpub(const EpubPrefs()));

    Finder curling() => find.byWidgetPredicate((w) => w is CustomPaint && w.painter is PageCurlPainter);
    double page(WidgetTester tester) => tester.widget<PageView>(find.byType(PageView)).controller!.page!;

    testWidgets('a tap on the right curls the page over the next and lands there; a key does the same', (tester) async {
      expect(PageCurl.loaded, isNotNull);
      await open(tester, twoChapters());
      await tester.tapAt(const Offset(760, 600));
      await tester.pump();
      expect(curling(), findsOneWidget, reason: 'this page curling away');
      expect(page(tester), 1.0, reason: 'the next page already underneath');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(curling(), findsNothing);
      expect(page(tester), 1.0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(curling(), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(page(tester), 2.0);
      await settle(tester);
    });

    testWidgets('a drag curls the page with the finger: let go early, it springs back to where it was; dragged '
        'past a third, it turns', (tester) async {
      await open(tester, twoChapters());
      Future<void> drag(double to) async {
        final g = await tester.startGesture(const Offset(700, 600));
        for (var i = 1; i <= 10; i++) {
          await g.moveTo(Offset(700 - (700 - to) * i / 10, 600));
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(curling(), findsOneWidget, reason: 'the page follows the finger');
        await g.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();
      }

      await drag(640);
      expect(page(tester), 0.0, reason: 'sprang back');
      await drag(150);
      expect(page(tester), 1.0, reason: 'turned');
      await settle(tester);
    });
  });

  testWidgets('on a wide screen the surround is one still layer under the pages: a page dragged halfway moves its '
      'sheet, not the surround (user, 2026-10-11: the whole sheet slides); a portrait screen has none', (tester) async {
    final round = EpubRenderer.surround(AppSettings.instance.epub.colours.background);
    Finder surroundBox() => find.byWidgetPredicate((w) => w is ColoredBox && w.color == round);
    await open(tester, twoChapters(), size: const Size(1600, 1000));
    expect(surroundBox(), findsOneWidget);
    expect(find.descendant(of: find.byType(PageView), matching: surroundBox()), findsNothing,
        reason: 'not drawn with each page (it would slide with them)');
    final before = tester.getRect(surroundBox());
    final drag = await tester.startGesture(const Offset(1200, 500));
    await drag.moveBy(const Offset(-500, 0));
    await tester.pump();
    expect(tester.getRect(surroundBox()), before, reason: 'mid-slide: still');
    await drag.up();
    await settle(tester);

    await open(tester, twoChapters());
    expect(surroundBox(), findsNothing, reason: '800 wide: the page fills the screen');
  });

  test("an EPUB is told from a comic by its media profile (the one Reader picks its renderer by it)", () {
    expect(isEpub({'id': 'e', 'media': {'mediaProfile': 'EPUB'}}), isTrue);
    expect(isEpub({'id': 'c', 'media': {'mediaProfile': 'DIVINA'}}), isFalse);
  });

  testWidgets('opens on the first page, "page X of Y"; forward and back turn a page each way - a tap on the right / '
      'left, the mouse wheel down / up (as with comics: it did nothing in the Windows app - build 79), the remote\'s '
      'Right / Left', (tester) async {
    await open(tester, twoChapters());
    expect(await label(tester), startsWith('Book · Pg. 1/'));
    Future<void> wheel(double dy) async {
      // a turn at most every 250 ms
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      final pointer = TestPointer(1, PointerDeviceKind.mouse)..hover(const Offset(400, 600));
      await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
    }
    for (final (input, forward, back) in <(String, Future<void> Function(), Future<void> Function())>[
      ('tap', () => tester.tapAt(const Offset(750, 600)), () => tester.tapAt(const Offset(50, 600))),
      ('wheel', () => wheel(120), () => wheel(-120)), // a notch down, a notch up
      ('remote', () => tester.sendKeyEvent(LogicalKeyboardKey.arrowRight),
          () => tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft)),
    ]) {
      await forward();
      await settle(tester);
      expect(await label(tester), startsWith('Book · Pg. 2/'), reason: '$input: forward');
      await back();
      await settle(tester);
      expect(await label(tester), startsWith('Book · Pg. 1/'), reason: '$input: back');
    }
  });

  testWidgets("an EPUB follows the eBooks' own reading settings, not the comics' (user, 2026-10-07: set apart per "
      'kind): page corner, progress bar', (tester) async {
    AppSettings.instance.setDisplay(const DisplayPrefs(
        comics: KindPrefs(pageNote: PageNote.always, progressBar: true),
        ebooks: KindPrefs(pageNote: PageNote.off, progressBar: false)));
    await open(tester, twoChapters());
    expect(find.byKey(const ValueKey('page-corner')), findsNothing, reason: "eBooks' Off, not comics' Always");
    expect(find.byKey(const ValueKey('reading-progress')), findsNothing);
    final s = AppSettings.instance;
    s.setDisplay(s.display.withKind(BookKind.ebooks, s.display.ebooks.copyWith(pageNote: PageNote.always)));
    await tester.pump();
    expect(find.byKey(const ValueKey('page-corner')), findsOneWidget);
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
    expect(find.byType(PageView), findsOneWidget, reason: 'opened, the failing chapter counted as one page');
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
    expect(await label(tester), before, reason: 'the same page of the same count');
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
    for (final (tooltip, title) in [('eBook settings', 'eBook settings'), ('Contents', 'Contents')]) {
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
      s.setDisplay(s.display.bothKinds((k) => k.copyWith(rotation: Rotation.auto)));
      m.setMockMethodCallHandler(SystemChannels.platform, null);
      m.setMockMethodCallHandler(const MethodChannel('komga_reader/screen'), null);
    });
    s.setDisplay(s.display.bothKinds((k) => k.copyWith(rotation: Rotation.landscape)));
    await open(tester, twoChapters());
    expect(requests, anyElement(equals(['DeviceOrientation.landscapeRight'])), reason: 'held the way it was held');
    wayUp = 'portrait';
    s.setDisplay(s.display.bothKinds((k) => k.copyWith(rotation: Rotation.portrait))); // changed in the panel
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
    await open(tester, source); // (shown once counted: "Book · Pg. X/Y · n%")
    await tester.tapAt(const Offset(400, 600));
    await tester.pump();
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

  testWidgets('a right-click shows the controls, and another hides them again (Windows, 2026-10-11: it only showed '
      'them)', (tester) async {
    await open(tester, MemorySource({'c1.xhtml': '<html><body>${para('word', 40)}</body></html>'},
        const EpubInfo(spine: ['c1.xhtml'], toc: [])));
    await tester.tapAt(const Offset(400, 600), buttons: kSecondaryButton);
    await settle(tester);
    expect(find.text('Close'), findsOneWidget, reason: 'shown');
    await tester.tapAt(const Offset(400, 600), buttons: kSecondaryButton);
    await settle(tester);
    expect(find.text('Close'), findsNothing, reason: 'hidden again');
  });

  testWidgets('the picture takes 95% of the screen; a button in each top corner of the screen turns it a quarter, '
      'left counterclockwise, right clockwise, without closing it - and stays put as it turns (user, 2026-10-08)',
      (tester) async {
    final map = (await tester.runAsync(() async {
      final rec = ui.PictureRecorder();
      Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 300, 500), Paint()..color = const Color(0xFF808080));
      final img = await rec.endRecording().toImage(300, 500);
      return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    }))!;
    await open(tester, MemorySource({'c1.xhtml': '<html><body><p><img src="map.png"/></p></body></html>'},
        const EpubInfo(spine: ['c1.xhtml'], toc: []), binary: {'map.png': map}));
    await tester.tapAt(const Offset(400, 600));
    await settle(tester);

    int turns() => tester.widget<RotatedBox>(find.byKey(const ValueKey('picture.turned'))).quarterTurns;
    Rect picture() => tester.getRect(find.byType(RawImage));
    // 300 x 500 in 95% of the 800 x 1200 screen (760 x 1140): as tall as that, 684 wide, centred
    expect(picture().height, closeTo(1140, 0.5));
    expect(picture().center.dx, closeTo(400, 0.5));
    expect(picture().center.dy, closeTo(600, 0.5));
    // the screen's top corners (800 x 1200), not the picture's
    Rect button(String key) => tester.getRect(find.byKey(ValueKey(key)));
    bool inTopCorner(String key, {required bool left}) {
      final b = button(key);
      return b.top < 24 && (left ? b.left < 24 : 800 - b.right < 24);
    }
    expect(inTopCorner('picture.rotate.ccw', left: true), isTrue);
    expect(inTopCorner('picture.rotate.cw', left: false), isTrue);
    final (ccwAt, cwAt) = (button('picture.rotate.ccw'), button('picture.rotate.cw'));

    await tester.tap(find.byKey(const ValueKey('picture.rotate.cw')));
    await settle(tester);
    expect(turns(), 1, reason: 'clockwise');
    expect(find.byType(RawImage), findsOneWidget, reason: 'still open');
    // turned: 500 x 300, as wide as the area (760), 456 tall
    expect(picture().width, closeTo(760, 0.5));
    expect(picture().height, closeTo(456, 0.5));
    expect((button('picture.rotate.ccw'), button('picture.rotate.cw')), (ccwAt, cwAt),
        reason: "the buttons stay where they were as the picture turns (on the picture's corners they moved - user)");

    await tester.tap(find.byKey(const ValueKey('picture.rotate.ccw')));
    await tester.tap(find.byKey(const ValueKey('picture.rotate.ccw')));
    await settle(tester);
    expect(turns(), 3, reason: 'counterclockwise twice from a quarter: three quarters');

    // the remote: Right goes to a button, OK presses it (and doesn't close the picture)
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(find.byType(RawImage), findsOneWidget, reason: 'OK on a button turns, not closes');
    expect(turns(), 0, reason: 'Right: the clockwise one - three quarters and one');

    await tester.tapAt(const Offset(400, 600));
    await settle(tester);
    expect(find.byType(RawImage), findsNothing, reason: 'a tap on the picture still closes it');
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
    AppSettings.instance.setDisplay(AppSettings.instance.display.bothKinds((k) => k.copyWith(pageNote: PageNote.afterTurn)));
    await tester.pump();
    expect(cornerOpacity(), 0);
    await tester.tapAt(const Offset(750, 600));
    await settle(tester);
    expect(cornerOpacity(), 1, reason: 'just turned');
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 300));
    expect(cornerOpacity(), 0, reason: 'a moment later');
    // Off: no corner
    AppSettings.instance.setDisplay(AppSettings.instance.display.bothKinds((k) => k.copyWith(pageNote: PageNote.off)));
    await tester.pump();
    expect(find.byKey(const ValueKey('page-corner')), findsNothing);
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
    expect(find.byKey(const ValueKey('epub-counting')), findsOneWidget); // the spinner's progress line
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
    final store = EpubCountStore.instance as MemoryCountStore;
    addTearDown(() => AppSettings.instance.setEpub(const EpubPrefs()));
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
    expect(find.byKey(const ValueKey('epub-counting')), findsOneWidget); // the spinner's progress line
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("the book's own text size is measured on the first open and kept with its counts; the next open uses "
      'what was kept instead of loading chapters to measure it again (user, 2026-10-11)', (tester) async {
    final store = EpubCountStore.instance as MemoryCountStore;
    await open(tester, twoChapters());
    expect(store.textSizes.values.single, (1.0, false), reason: 'measured, and kept');
    await tester.pumpWidget(const SizedBox());

    // what's kept is what's used: a size put there shows up in the layout the book is counted in
    final key = store.textSizes.keys.single;
    store.textSizes[key] = (0.5, false);
    store.kept.clear();
    await open(tester, twoChapters());
    expect(store.kept.keys.single, contains('/0.5/'), reason: 'laid out with the kept size, not a fresh measurement');
    expect(store.textSizes[key], (0.5, false), reason: 'not measured again');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("a text size measured with a chapter that couldn't be read (the network, for a moment) isn't kept: the "
      'next open measures again (audit, 2026-10-11: the fallback size was kept until the next app build)',
      (tester) async {
    final store = EpubCountStore.instance as MemoryCountStore;
    final book = twoChapters();
    await open(tester, _FailsOnce(book.files, book.infoValue, fails: 'c2.xhtml'));
    expect(store.textSizes, isEmpty, reason: 'measured from fewer chapters: not kept');
    await tester.pumpWidget(const SizedBox());
    await open(tester, twoChapters());
    expect(store.textSizes, hasLength(1), reason: 'every chapter read this time: kept');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a footnote marker opens the note over the page; the page stays', (tester) async {
    await open(tester, MemorySource({
      'c1.xhtml': '<html><body><p>Here<a href="notes.xhtml#n1">*</a> is a note.</p></body></html>',
      'notes.xhtml': '<html><body><p id="n1"><a href="c1.xhtml">*</a>The note itself.</p></body></html>',
    }, const EpubInfo(spine: ['c1.xhtml', 'notes.xhtml'], toc: [])));
    // the marker, from the page on screen as drawn (its links in page coordinates)
    final drawn = tester.widget<CustomPaint>(find.descendant(of: find.byType(PageView), matching: find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter.runtimeType.toString() == '_PagePainter')));
    final marker = ((drawn.painter as dynamic).page as EpubPage).links.single;
    expect(marker.text, '*');
    await tester.tapAt(tester.getTopLeft(find.byType(PageView)) + marker.rect.center);
    await settle(tester);
    expect(find.text('The note itself.'), findsOneWidget, reason: "the note, its own marker (its link back) left out");
    await tester.tap(find.text('Close'));
    await settle(tester);
    expect(find.text('The note itself.'), findsNothing);
    expect(find.byType(PageView), findsOneWidget, reason: 'still on the page');
  });
}
