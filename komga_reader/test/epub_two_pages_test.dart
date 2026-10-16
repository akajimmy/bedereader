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

  testWidgets('a wide screen (the default, Wide screen): two pages side by side - each chapter starts on a '
      'right-hand page, then pairs; a turn goes a spread on, to the end card', (tester) async {
    await open(tester);
    final first = (await spots(tester))!;
    final total = of(first.$1), chapter1 = of(first.$2);
    final expected = [
      for (final s in pairChapters([chapter1, total - chapter1]))
        s.pages.length == 1 ? '${s.first + 1}' : '${s.first + 1}-${s.last + 1}',
    ];
    final seen = [pages(first.$1)];
    for (var i = 1; i < expected.length; i++) {
      await turn(tester);
      seen.add(pages((await spots(tester))!.$1));
    }
    expect(seen, expected);
    expect(seen.first, '1', reason: 'the first chapter on a right-hand page, alone');
    expect(seen, contains('${chapter1 + 1}'), reason: 'the second one too');
    await turn(tester);
    expect(find.text('You finished the book'), findsNothing); // (the end card's own text is the Reader's)
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
      'between"), a fixed distance (32, then set to 100), each sheet 20 out round its own text', (tester) async {
    AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(insetPage: InsetPage.always));
    for (final width in [1600.0, 2400.0]) {
      await open(tester, size: Size(width, 1000));
      await turn(tester); // a pair: both sides with a page
      final sheets = sheetsOnScreen(tester, width);
      expect(sheets.length, 2, reason: '$width: $sheets');
      final side = EpubRenderer.sideMargin(AppSettings.instance.epub, width / 2), text = width / 2 - 2 * side;
      expect(sheets[0].width, closeTo(text + 40, 0.5), reason: '$width: 20 out round the text');
      expect((sheets[0].top, sheets[0].bottom), (20, 980));
      expect(sheets[1].size, sheets[0].size);
      expect(sheets[0].right, closeTo(width / 2 - 16, 0.5), reason: '$width: 32 apart, about the middle');
      expect(sheets[1].left, closeTo(width / 2 + 16, 0.5));
    }
    // dialled in (the panel's slider, for now)
    AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(insetBetween: 100));
    await settle(tester);
    final apart = sheetsOnScreen(tester, 2400);
    expect(apart[1].left - apart[0].right, closeTo(100, 0.5));
    expect(apart[0].right, closeTo(1150, 0.5));
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
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    expect(pages((await spots(tester))!.$1), contains('-'));
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
    final side = EpubRenderer.sideMargin(AppSettings.instance.epub, 800), gap = 32.0;
    final right = Rect.fromLTWH(800 + gap / 2, 20, 800 - 2 * side + 40, 960);
    expect(c.page, right, reason: 'the right-hand sheet');
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
