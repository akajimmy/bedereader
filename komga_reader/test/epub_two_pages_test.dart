// eBooks in Dual page mode (user, 2026-10-16): two pages side by side, each chapter starting on a right-hand page,
// the sheets meeting at the spine, the curl turning the right-hand page over onto the left, selection on either page.
// (The pairing itself: spreads_test.dart.)
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/epub/count_store.dart';
import 'package:komga_reader/page_curl.dart';
import 'package:komga_reader/reader/epub_renderer.dart';
import 'package:komga_reader/reader/spreads.dart';
import 'package:komga_reader/screens/reader.dart';
import 'package:komga_reader/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/client_settings.dart';
import 'support/epub_books.dart';
import 'support/helpers.dart';
import 'support/no_network.dart';

class _Komga extends TestKomga with EmptyClientSettings {
  @override
  Future<Map<String, dynamic>?> nextBook(String bookId, {String? readListId}) async => null;
  @override
  ImageProvider thumbImage(String ref) => MemoryImage(onePixelPng);
}

void main() {
  setUpAll(preloadShaders);
  late EpubCountStore counts;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppSettings.instance.setDisplay(const DisplayPrefs());
    AppSettings.instance.setEpub(const EpubPrefs());
    counts = EpubCountStore.instance;
    EpubCountStore.instance = MemoryCountStore();
    twoPagesAllowed = true; // (off for every other test file - flutter_test_config.dart)
  });
  tearDown(() {
    EpubCountStore.instance = counts;
    twoPagesAllowed = false;
    AppSettings.instance.setDisplay(const DisplayPrefs());
    AppSettings.instance.setEpub(const EpubPrefs());
  });

  Future<void> open(WidgetTester tester, {Size size = const Size(1600, 1000)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: noNetwork(_Komga.new),
        book: const {'id': 'B1', 'name': 'Book', 'media': {'mediaProfile': 'EPUB'}}, epubSource: twoChapters(),
        saveProgress: false)));
    for (var i = 0; i < 200; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      if (find.byType(PageView).evaluate().isNotEmpty && i > 10) break;
    }
    expect(find.byType(PageView), findsOneWidget);
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The position's left and right spots ("Book · Pg. 2-3/9 · 20%", "Ch. · Pg. 2/5"), the controls up for a moment.
  Future<(String, String)?> spots(WidgetTester tester) async {
    final mid = tester.view.physicalSize.center(Offset.zero);
    await tester.tapAt(mid);
    await tester.pump();
    final left = find.byKey(const ValueKey('pos-left-text')), right = find.byKey(const ValueKey('pos-right-text'));
    final t = left.evaluate().isEmpty
        ? null
        : (tester.widget<Text>(left).data!, right.evaluate().isEmpty ? '' : tester.widget<Text>(right).data!);
    await tester.tapAt(mid);
    await tester.pump();
    return t;
  }

  Future<void> turn(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
  }

  String pages(String left) => RegExp(r'Pg\. ([0-9-]+)/').firstMatch(left)!.group(1)!;
  int of(String spot) => int.parse(RegExp(r'/(\d+)').firstMatch(spot)!.group(1)!);

  testWidgets('a wide screen (the default, Wide screen): two pages side by side - chapters starting on the next page '
      '(the default) or on a right-hand page (the setting), then pairs; a turn goes a spread on, to the end card',
      (tester) async {
    for (final start in [ChapterStart.nextPage, ChapterStart.rightPage]) {
      AppSettings.instance.setEpub(AppSettings.instance.epub.copyWith(chapterStart: start));
      await open(tester);
      final first = (await spots(tester))!;
      final total = of(first.$1), chapter1 = of(first.$2);
      final expected = [
        for (final s in pairChapters([chapter1, total - chapter1], rightHand: start == ChapterStart.rightPage))
          s.pages.length == 1 ? '${s.first + 1}' : '${s.first + 1}-${s.last + 1}',
      ];
      final seen = [pages(first.$1)];
      for (var i = 1; i < expected.length; i++) {
        await turn(tester);
        seen.add(pages((await spots(tester))!.$1));
      }
      expect(seen, expected, reason: '$start');
      expect(seen.first, '1', reason: '$start: the first page on a right-hand page, alone');
      if (start == ChapterStart.rightPage) {
        expect(seen, contains('${chapter1 + 1}'), reason: 'the second chapter alone on the right too');
      } else {
        expect(seen, isNot(contains('${chapter1 + 1}')), reason: 'the second chapter beside a page, not alone');
      }
      await turn(tester);
      expect(find.text('You finished the book'), findsNothing); // (the end card's own text is the Reader's)
      await tester.pumpWidget(const SizedBox());
    }
    AppSettings.instance.setEpub(const EpubPrefs());
  });

  testWidgets('chapters set to start elsewhere while reading: the book paired again, on the same page', (tester) async {
    await open(tester);
    final first = (await spots(tester))!;
    final chapter1 = of(first.$2);
    // to the spread holding the second chapter's first page (next page: beside the first chapter's last, or after)
    while (!pages((await spots(tester))!.$1).split('-').contains('${chapter1 + 1}')) {
      await turn(tester);
    }
    final before = pages((await spots(tester))!.$1);
    AppSettings.instance.setEpub(AppSettings.instance.epub.copyWith(chapterStart: ChapterStart.rightPage));
    await settle(tester);
    final after = pages((await spots(tester))!.$1);
    // the spread had the second chapter's first page beside another; now a chapter starts alone on the right - and
    // the place (the spread's earlier page) is still on screen
    expect(after, isNot(before), reason: 'paired again: $before -> $after');
    expect(after.split('-'), contains(before.split('-').first), reason: 'the place kept: $before -> $after');
    AppSettings.instance.setEpub(const EpubPrefs());
    await settle(tester);
  });

  testWidgets('a tall screen: one page at a time; Off: one on a wide screen too; Always: two on a tall one',
      (tester) async {
    await open(tester, size: const Size(1000, 1600));
    await turn(tester);
    expect(pages((await spots(tester))!.$1), '2');
    await turn(tester);
    expect(pages((await spots(tester))!.$1), '3', reason: 'page by page');

    AppSettings.instance.setEpub(AppSettings.instance.epub.copyWith(twoPages: TwoPages.always));
    await settle(tester);
    await settle(tester);
    expect(pages((await spots(tester))!.$1), contains('-'), reason: 'Always: a pair, a tall screen too');

    AppSettings.instance.setEpub(AppSettings.instance.epub.copyWith(twoPages: TwoPages.off));
    tester.view.physicalSize = const Size(1600, 1000);
    await settle(tester);
    await settle(tester);
    final now = pages((await spots(tester))!.$1);
    expect(now, isNot(contains('-')), reason: 'Off: one page on a wide screen');
    await turn(tester);
    expect(pages((await spots(tester))!.$1), '${int.parse(now) + 1}');
  });

  /// The sheets drawn on screen now, left to right.
  List<Rect> sheetsOnScreen(WidgetTester tester, double width) {
    final sheets = <Rect>[];
    for (final e in find.byWidgetPredicate((w) => w is CustomPaint && w.painter.runtimeType.toString() == '_PagePainter')
        .evaluate()) {
      final sheet = ((e.widget as CustomPaint).painter as dynamic).sheet as Rect?;
      final box = e.renderObject as RenderBox;
      if (sheet == null || !box.attached) continue;
      final at = box.localToGlobal(Offset.zero);
      if (at.dx < -1 || at.dx > width - 1) continue; // (the neighbours built ahead, off screen)
      sheets.add(sheet.shift(at));
    }
    return sheets..sort((a, b) => a.left.compareTo(b.left));
  }

  testWidgets('Inset page with two pages up: two pages apart (user, 2026-10-16: "two discrete pages, with a gap '
      'between"), 24 apart, each sheet 60 out from its own text at the sides and 24 above and below', (tester) async {
    AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(insetPage: InsetPage.always));
    for (final width in [1600.0, 2400.0]) {
      await open(tester, size: Size(width, 1000));
      await turn(tester); // a pair: both sides with a page
      final sheets = sheetsOnScreen(tester, width);
      expect(sheets.length, 2, reason: '$width: $sheets');
      final side = EpubRenderer.sideMargin(AppSettings.instance.epub, width / 2), text = width / 2 - 2 * side;
      expect(sheets[0].width, closeTo(text + 120, 0.5), reason: '$width: 60 out at the sides');
      expect((sheets[0].top, sheets[0].bottom), (16, 984), reason: '$width: 24 above and below');
      expect(sheets[1].size, sheets[0].size);
      expect(sheets[0].right, closeTo(width / 2 - 12, 0.5), reason: '$width: 24 apart, about the middle');
      expect(sheets[1].left, closeTo(width / 2 + 12, 0.5));
    }
    // the Gutter setting (user, 2026-10-20: 24 by default): 80 apart, the open book's page as it was
    expect(AppSettings.instance.epub.gutter, 24);
    final before = pages((await spots(tester))!.$1);
    AppSettings.instance.setEpub(AppSettings.instance.epub.copyWith(gutter: 80));
    await settle(tester);
    final apart = sheetsOnScreen(tester, 2400);
    expect(apart[1].left - apart[0].right, closeTo(80, 0.5));
    expect(apart[0].right, closeTo(1160, 0.5), reason: 'about the middle');
    expect(pages((await spots(tester))!.$1), before, reason: 'not laid out again: the same pages');
    AppSettings.instance.setEpub(const EpubPrefs());
    await settle(tester);
  });

  testWidgets("one page or two, the same page size (1600 wide two up, then an 800-wide window: one): the same place, "
      'not laid out again', (tester) async {
    await open(tester);
    await turn(tester); // (the pair after the first chapter's opening page)
    final two = pages((await spots(tester))!.$1);
    expect(two, contains('-'));
    tester.view.physicalSize = const Size(800, 1000);
    await settle(tester);
    final one = pages((await spots(tester))!.$1);
    expect(one, two.split('-').first, reason: 'one page: the earlier one of the pair - the place');
    tester.view.physicalSize = const Size(1600, 1000);
    await settle(tester);
    expect(pages((await spots(tester))!.$1), two, reason: 'two again: the same pair');
  });

  testWidgets('without Inset page the two pages are one even colour across the gutter (user, 2026-10-21: a shade down '
      'the middle read as a different colour from the page)', (tester) async {
    AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(insetPage: InsetPage.never));
    await open(tester);
    await turn(tester); // a pair
    expect(pages((await spots(tester))!.$1), contains('-'), reason: 'two pages up');
    // nothing drawn over the pages: no shade (a gradient) down the middle
    final shades = find.byWidgetPredicate((w) =>
        w is DecoratedBox && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).gradient != null);
    expect(shades, findsNothing);
  });

  testWidgets('the curl, two pages up: the right-hand page turns over onto the left, attached at the spine; the '
      'left-hand one held meanwhile', (tester) async {
    AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(insetPage: InsetPage.never));
    AppSettings.instance.setEpub(const EpubPrefs(turn: EpubTurn.curl));
    await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    final curls = tester.widgetList<CustomPaint>(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is PageCurlPainter));
    final c = curls.single.painter as PageCurlPainter;
    expect(c.spine, isTrue);
    expect((c.page.left, c.page.right), (800, 1600), reason: 'the right-hand page');
    final held = tester.widgetList<ClipRect>(find.byType(ClipRect)).where((w) => w.clipper != null).toList();
    expect(held, isNotEmpty, reason: 'the left side of the view from before the turn, held');
    // its back: the next spread's left-hand page (user, 2026-10-16: "the following left-hand page should be shown on
    // the back") - a snapshot of the view once it shows that spread
    await tester.pump();
    final turning = tester.widgetList<CustomPaint>(find.byWidgetPredicate((w) => w is CustomPaint &&
        w.painter is PageCurlPainter)).single.painter as PageCurlPainter;
    expect(turning.back, isNotNull);
    expect(identical(turning.back, turning.sheet), isFalse, reason: 'not the page turning');
    expect(turning.gap, 0, reason: 'no gap between the pages');
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    expect(pages((await spots(tester))!.$1), contains('-'));
  });

  testWidgets('the curl back, two pages up: the left side shows the previous spread at once, under the page lifting '
      'away; only the right side holds the old view until the page lands on it (user, 2026-10-16)', (tester) async {
    AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(insetPage: InsetPage.never));
    AppSettings.instance.setEpub(const EpubPrefs(turn: EpubTurn.curl));
    await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    final held = tester.widgetList<ClipRect>(find.byType(ClipRect)).where((w) => w.clipper != null)
        .map((w) => w.clipper!.getClip(const Size(1600, 1000))).toList();
    expect(held, [const Rect.fromLTWH(800, 0, 800, 1000)], reason: 'the right side only');
    await tester.pump();
    final turning = tester.widgetList<CustomPaint>(find.byWidgetPredicate((w) => w is CustomPaint &&
        w.painter is PageCurlPainter)).single.painter as PageCurlPainter;
    expect(turning.back, isNotNull, reason: "its back: the left-hand page of the spread the turn started from");
    expect(identical(turning.back, turning.sheet), isFalse);
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
  });

  testWidgets('the curl with Inset page (user, 2026-10-16: "how are you handling page curl + inset page"): the '
      'right-hand sheet turns, about the middle of the gap, and lands over the left one, the same size', (tester) async {
    AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(insetPage: InsetPage.always));
    AppSettings.instance.setEpub(const EpubPrefs(turn: EpubTurn.curl));
    await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    final c = tester.widgetList<CustomPaint>(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is PageCurlPainter))
        .single.painter as PageCurlPainter;
    expect(c.spine, isTrue);
    final side = EpubRenderer.sideMargin(AppSettings.instance.epub, 800), gap = 24.0;
    final right = Rect.fromLTWH(800 + gap / 2, 16, 800 - 2 * side + 120, 968);
    expect(c.page, right, reason: 'the right-hand sheet');
    expect(c.gap, gap, reason: 'its back lands past the gap, over the left sheet');
    // near the end of the turn its edge is its width and the gap past where it was hinged: over the left sheet
    await tester.pump(const Duration(milliseconds: 370));
    final end = tester.widgetList<CustomPaint>(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is PageCurlPainter))
        .single.painter as PageCurlPainter;
    expect(end.finger.dx, closeTo(-(right.width + gap), 4), reason: 'its edge over the left sheet\'s outer edge');
    await tester.pump(const Duration(milliseconds: 200));
    await settle(tester);
  });

  testWidgets('a double click on a word of the right-hand page selects it there - the pane over it', (tester) async {
    EpubRenderer.doubleTapWait = const Duration(milliseconds: 250);
    addTearDown(() => EpubRenderer.doubleTapWait = kDoubleTapTimeout);
    await open(tester);
    await turn(tester); // a pair
    Future<void> click(Offset at) async {
      final g = await tester.startGesture(at, kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
      await g.up();
      await tester.pump(const Duration(milliseconds: 40));
    }

    const word = Offset(1000, 300); // the middle third, on the right-hand page
    await click(word);
    await click(word);
    await tester.pump();
    final pane = find.byKey(const ValueKey('epub-selection-pane'));
    expect(pane, findsOneWidget, reason: 'a word selected on the right-hand page');
    expect(find.text('Copy'), findsOneWidget);
    expect(tester.getCenter(find.text('Copy')).dx, greaterThan(800), reason: 'over the selection, on the right');
  });
}
