// The EPUB renderer in the one Reader over a small book held in memory: turning and moving through the book.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/epub/source.dart';
import 'package:komga_reader/page_curl.dart';
import 'package:komga_reader/screens/open_book.dart';
import 'package:komga_reader/screens/reader.dart';
import 'package:komga_reader/settings.dart';

import 'support/epub_books.dart';
import 'support/no_network.dart';
import 'support/epub_reader.dart';

void main() {
  epubReaderSetUp();

  group('Page turn: Curl (user, 2026-10-11: the comics\' 3D curl for eBooks)', () {
    setUp(() {
      AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(epubTurn: EpubTurn.curl));
      addTearDown(() => AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(epubTurn: EpubTurn.slide)));
    });
    tearDown(() => AppSettings.instance.setEpub(const EpubPrefs()));

    Finder curling() => find.byWidgetPredicate((w) => w is CustomPaint && w.painter is PageCurlPainter);
    double page(WidgetTester tester) => tester.widget<PageView>(find.byType(PageView)).controller!.page!;

    testWidgets('a tap on the right curls the page over the next and lands there; a key does the same', (tester) async {
      expect(PageCurl.loaded, isNotNull);
      await openEpub(tester, twoChapters());
      await tester.tapAt(const Offset(760, 600));
      await tester.pump();
      expect(curling(), findsOneWidget, reason: 'this page curling away');
      expect(page(tester), 1.0, reason: 'the next page already underneath');
      // the back of the page in the page's own colour, not white paper (user, 2026-10-11)
      expect((tester.widget<CustomPaint>(curling()).painter! as PageCurlPainter).paper,
          AppSettings.instance.epub.colours.background);
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
      await settleEpub(tester);
    });

    testWidgets('a drag curls the page with the finger: let go early, it springs back to where it was; dragged '
        'past a third, it turns', (tester) async {
      await openEpub(tester, twoChapters());
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
      await settleEpub(tester);
    });
  });

  test("an EPUB is told from a comic by its media profile (the one Reader picks its renderer by it)", () {
    expect(isEpub({'id': 'e', 'media': {'mediaProfile': 'EPUB'}}), isTrue);
    expect(isEpub({'id': 'c', 'media': {'mediaProfile': 'DIVINA'}}), isFalse);
  });

  testWidgets('opens on the first page, "page X of Y"; forward and back turn a page each way - a tap on the right / '
      'left, the mouse wheel down / up (as with comics: it did nothing in the Windows app - build 79), the remote\'s '
      'Right / Left', (tester) async {
    await openEpub(tester, twoChapters());
    expect(await epubLabel(tester), startsWith('Book · Pg. 1/'));
    Future<void> wheel(double dy) async {
      // a turn at most every 250 ms
      await tester.pump(const Duration(milliseconds: 300)); // (the test's clock: the renderer reads it through package:clock)
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
      await settleEpub(tester);
      expect(await epubLabel(tester), startsWith('Book · Pg. 2/'), reason: '$input: forward');
      await back();
      await settleEpub(tester);
      expect(await epubLabel(tester), startsWith('Book · Pg. 1/'), reason: '$input: back');
    }
  }, tags: 'slow');

  testWidgets("the pages either side are built ahead, as the comic reader's are: a tap's turn doesn't build the "
      'incoming page in its first frame (tap turns missed a refresh there - tablet, build 76)', (tester) async {
    await openEpub(tester, twoChapters());
    expect(tester.widget<PageView>(find.byType(PageView)).allowImplicitScrolling, isTrue);
    expect(find.byType(CustomPaint, skipOffstage: false).evaluate().length, greaterThan(1),
        reason: 'the next page exists before any turn');
  });

  testWidgets("resizing the window there and back lands on the same page - each new size used to start from the page "
      'on screen, earlier than the place, and walked back (Windows, build 79: two resizes and back, a page back)',
      (tester) async {
    final words = [for (var i = 0; i < 400; i++) ['a', 'bb', 'ccc', 'dddd', 'eeeee'][i % 5]].join(' ');
    await openEpub(tester, MemorySource({
      'c1.xhtml': '<html><body>${List.filled(6, '<p>$words</p>').join()}</body></html>',
    }, const EpubInfo(spine: ['c1.xhtml'], toc: [], title: 'Book')));
    for (var i = 0; i < 5; i++) {
      await tester.tapAt(const Offset(750, 600));
      await settleEpub(tester);
    }
    final before = await epubLabel(tester);
    for (final s in const [Size(560, 1200), Size(1000, 700), Size(700, 1000), Size(800, 1200)]) {
      tester.view.physicalSize = s;
      await tester.pump();
      await settleEpub(tester);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await settleEpub(tester);
    }
    expect(await epubLabel(tester), before, reason: 'back at the first size: the same page');
  }, tags: 'slow');

  testWidgets('contents: jumps to a chapter; turning on from the last page of a chapter goes into the next; the end '
      'card after the last page', (tester) async {
    await openEpub(tester, twoChapters());
    await tester.tapAt(const Offset(400, 600));
    await tester.pump();
    await tester.tap(find.byTooltip('Contents'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Two'));
    await settleEpub(tester);
    final atTwo = await epubLabel(tester);
    final total = int.parse(RegExp(r'/(\d+) ·').firstMatch(atTwo)!.group(1)!);
    final here = int.parse(RegExp(r'Pg\. (\d+)/').firstMatch(atTwo)!.group(1)!);
    expect(here, greaterThan(1), reason: 'chapter two is past chapter one');
    // to the end and past it
    for (var i = here; i <= total; i++) {
      await tester.tapAt(const Offset(750, 600));
      await settleEpub(tester);
    }
    expect(find.text('End of book'), findsOneWidget);
  });

  // ---- moving through the book (EPUB review 2026-10-06, R1-R3)

  /// [n] chapters; [failing]: one whose file is missing (it fails every time it's loaded).
  testWidgets("R1: jumped far, then straight back into a chapter that isn't laid out yet - its LAST page, not its "
      'first', (tester) async {
    await openEpub(tester, chapters(7));
    await contentsTo(tester, 'Chapter 6');
    await tester.pump(const Duration(milliseconds: 50)); // straight back - before chapter 5 is laid out ahead
    await tester.tapAt(const Offset(50, 600));
    await settleEpub(tester);
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
    await settleEpub(tester);
    expect(find.text('Retry'), findsOneWidget);
    await tester.tapAt(const Offset(400, 600)); // the controls still come up
    await tester.pump();
    expect(find.byTooltip('Contents'), findsOneWidget);
    await tester.tapAt(const Offset(400, 600));
    await tester.pump();
    await tester.tapAt(const Offset(750, 600)); // and a turn goes on to chapter 3
    await settleEpub(tester);
    expect(find.text('Retry'), findsNothing);
    expect(await inChapter(tester), startsWith('Chapter 3 '));
  });

  testWidgets('R12: the window shrunk to nothing (minimised) and back - the same page, not the chapter start',
      (tester) async {
    await openEpub(tester, chapters(3));
    for (var i = 0; i < 4; i++) {
      await tester.tapAt(const Offset(750, 600));
      await settleEpub(tester);
    }
    final before = await epubLabel(tester);
    tester.view.physicalSize = Size.zero;
    await tester.pump();
    await settleEpub(tester);
    tester.view.physicalSize = const Size(800, 1200);
    await tester.pump();
    await settleEpub(tester);
    expect(await epubLabel(tester), before, reason: 'the same page of the same count');
  });

  testWidgets("R3: a swipe past a chapter's last page goes on into the next (the whole book is one page view)",
      (tester) async {
    await openEpub(tester, chapters(7));
    await settleEpub(tester);
    // to chapter 1's last page by taps, then swipe on
    for (var i = 0; i < 40; i++) {
      final at = await inChapter(tester);
      final m = RegExp(r'Pg\. (\d+)/(\d+)').firstMatch(at)!;
      if (m.group(1) == m.group(2)) break;
      await tester.tapAt(const Offset(750, 600));
      await settleEpub(tester);
    }
    await tester.fling(find.byType(PageView), const Offset(-500, 0), 2000);
    await settleEpub(tester);
    expect(await inChapter(tester), startsWith('Chapter 2 '));
  }, tags: 'slow');

  testWidgets('a held Right key keeps turning pages, one each time the slide ends (user, build 82, Windows: it crept '
      'and never turned - each repeat restarted the slide)', (tester) async {
    await openEpub(tester, chapters(1));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    for (var i = 0; i < 30; i++) {
      // a keyboard's repeats, about 30 a second, for about a second
      await tester.pump(const Duration(milliseconds: 33));
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await settleEpub(tester);
    final page = int.parse(RegExp(r'Pg\. (\d+)/').firstMatch(await epubLabel(tester))![1]!);
    expect(page, greaterThanOrEqualTo(3), reason: 'about a second of a held key: a few pages on');
  });

  testWidgets('a held remote button that sends fresh presses turns a page each time the slide ends, and stops '
      'after one more when let go; quick taps turn a page each - never creeping (user, 2026-10-07: each turn asked '
      'for mid-slide started the slide over, and the page crept without turning)', (tester) async {
    await openEpub(tester, chapters(1));
    int at() => (tester.widget<PageView>(find.byType(PageView)).controller!.page ?? 0).round();
    // a remote held: a fresh press every 50 ms for about a second (not the keyboard's repeats)
    for (var i = 0; i < 20; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 50));
    }
    final held = at();
    expect(held, greaterThanOrEqualTo(2), reason: 'about a second held: a page per slide (it crept on page 0-1)');
    await settleEpub(tester);
    expect(at(), lessThanOrEqualTo(held + 1), reason: 'let go: at most one more');
    final c = tester.widget<PageView>(find.byType(PageView)).controller!;
    expect(c.page, c.page!.roundToDouble(), reason: 'it settles on a page');

    // three quick taps on the right, 60 ms apart: three pages
    final before = at();
    for (var i = 0; i < 3; i++) {
      await tester.tapAt(const Offset(750, 600));
      await tester.pump(const Duration(milliseconds: 60));
    }
    await settleEpub(tester);
    expect(at(), before + 3);
  });

  testWidgets("with the controls up the remote walks them (the comic reader's model): Down to the bottom bar, Right "
      'along it, OK presses; Back closes the controls, not the book', (tester) async {
    await openEpub(tester, twoChapters());
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
}
