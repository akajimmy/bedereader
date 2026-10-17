// Comics in two pages side by side (user, 2026-10-16 - NOTES, "Dual-page mode"; the pairing: spreads_test.dart).
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/page_image.dart';
import 'package:komga_reader/reader/spreads.dart' show twoPagesAllowed;
import 'package:komga_reader/screens/reader.dart';
import 'package:komga_reader/settings.dart';
import 'package:komga_reader/synced_ids.dart';
import 'package:komga_reader/widgets/setting_rows.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/no_network.dart';
import 'support/reader_server.dart';

/// A 9-page book whose 7th page is a spread: the cover, 1|2, 3|4, 5 alone (an odd run before the spread, anchored),
/// the spread, 7|8 - as pages from 1: [1] [2|3] [4|5] ... see [expectedSpreads].
class SpreadBook extends ReaderServer {
  // (from 1) 1 cover, 2-6 single (five: odd - one alone after the cover), 7 wide, 8-9
  static const wide = {7};

  /// Pages that load (the curl tests: pairs joined): [png] for each.
  static bool real = false;
  static late Uint8List png;
  @override
  Future<Uint8List> pageBytes(String bookId, int number) => real ? Future.value(png) : super.pageBytes(bookId, number);
  @override
  Future<List<dynamic>> pages(String bookId) async => [
        for (var n = 1; n <= 9; n++) {'number': n, 'width': wide.contains(n) ? 2400 : 1200, 'height': 1800},
      ];
}

void main() {
  setUpAll(preloadShaders);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    twoPagesAllowed = true; // (off for every other test file - flutter_test_config.dart)
    PairShift.instance.reset();
  });
  tearDown(() {
    twoPagesAllowed = false;
    AppSettings.instance.setDisplay(const DisplayPrefs());
    AppSettings.instance.setDefault(const ReaderPrefs());
    AppSettings.instance.useDefaults('S1');
    ReaderServer.direction = 'LEFT_TO_RIGHT';
  });

  late SpreadBook api;

  Future<void> open(WidgetTester tester, {Size size = const Size(1600, 1000)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    api = noNetwork(SpreadBook.new);
    await tester.pumpWidget(const SizedBox()); // (a reader opened before in the test: gone, not reused)
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: api, book: api.theBook)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// The position text with the controls up ("Pg. 2-3/9 · 33%"), the controls hidden again after.
  Future<String> position(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.enter); // OK: the controls
    await tester.pump();
    final t = tester.widgetList<Text>(find.textContaining('Pg. ')).single.data!;
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    return t;
  }

  Future<void> turn(WidgetTester tester, {bool back = false}) async {
    await tester.sendKeyEvent(back ? LogicalKeyboardKey.arrowLeft : LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('a wide screen: two pages side by side - the cover alone, then pairs anchored on the spread, the spread '
      'alone; a turn goes a pair on; progress is the later page shown, so the last pair finishes the book',
      (tester) async {
    await open(tester);
    expect(await position(tester), startsWith('Pg. 1/9'), reason: 'the cover alone');
    final seen = <String>[];
    for (var i = 0; i < 5; i++) {
      await turn(tester);
      seen.add((await position(tester)).split(' ·').first);
    }
    // 2 alone (the dropped inside cover), 3|4, 5|6 meeting the spread, the spread, 8|9
    expect(seen, ['Pg. 2/9', 'Pg. 3-4/9', 'Pg. 5-6/9', 'Pg. 7/9', 'Pg. 8-9/9']);
    expect(api.saves.last, 9, reason: 'the later page of the pair');
    expect(api.finished, isNotEmpty, reason: 'the last pair shown: read to the end');
    await turn(tester, back: true);
    expect((await position(tester)).split(' ·').first, 'Pg. 7/9', reason: 'back a spread');
  });

  testWidgets('a tall screen (Wide screen, the default): one page at a time; Always: two there too; Off: one on a wide '
      'screen too', (tester) async {
    await open(tester, size: const Size(1000, 1600));
    await turn(tester);
    expect(await position(tester), startsWith('Pg. 2/9'));
    await turn(tester);
    expect(await position(tester), startsWith('Pg. 3/9'), reason: 'page by page');

    final s = AppSettings.instance;
    s.setDefault(s.defaults.copyWith(twoPages: TwoPages.always));
    await tester.pump();
    await tester.pump();
    expect(await position(tester), startsWith('Pg. 3-4/9'), reason: 'Always: the pair page 3 is in');

    await open(tester);
    s.setDefault(s.defaults.copyWith(twoPages: TwoPages.off));
    await tester.pump();
    await tester.pump();
    await turn(tester);
    expect(await position(tester), startsWith('Pg. 2/9'));
    await turn(tester);
    expect(await position(tester), startsWith('Pg. 3/9'), reason: 'Off: page by page on a wide screen');
  });

  testWidgets("dual page mode in the reader's Comic settings, a default a series overrides (user, 2026-10-16): the "
      "series' own Off - one page at a time on a wide screen, the default still Wide screen", (tester) async {
    await open(tester);
    await turn(tester);
    await turn(tester);
    expect(await position(tester), startsWith('Pg. 3-4/9'));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.tap(find.byTooltip('Comic settings'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100)); // (no settling: the pages never load)
    }
    await tester.tap(find.text('Override defaults'));
    await tester.pump();
    final row = find.ancestor(of: find.text('Dual page mode'), matching: find.byType(SegmentRow<TwoPages>));
    await tester.tap(find.descendant(of: row, matching: find.text('Off')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final s = AppSettings.instance;
    expect(s.prefsFor('S1').twoPages, TwoPages.off, reason: "the series' own");
    expect(s.defaults.twoPages, TwoPages.wideScreen, reason: 'the default unchanged');
    await tester.ensureVisible(find.text('Make default'));
    await tester.tap(find.text('Make default'));
    await tester.pump();
    expect(s.defaults.twoPages, TwoPages.off, reason: "Make default: the series' layout, dual page mode with it");
    s.setDefault(s.defaults.copyWith(twoPages: TwoPages.wideScreen));
    Navigator.of(tester.element(find.text('Dual page mode'))).pop();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    if (find.byTooltip('Comic settings').evaluate().isNotEmpty) {
      await tester.sendKeyEvent(LogicalKeyboardKey.enter); // (the controls away)
      await tester.pump();
    }
    expect(await position(tester), startsWith('Pg. 4/9'), reason: 'one page: the page being read');
    await turn(tester);
    expect(await position(tester), startsWith('Pg. 5/9'));
  });

  testWidgets('turned from wide to tall mid-book: the same page, now alone; and back: its pair', (tester) async {
    await open(tester);
    await turn(tester);
    await turn(tester); // 3|4
    expect(await position(tester), startsWith('Pg. 3-4/9'));
    tester.view.physicalSize = const Size(1000, 1600);
    await tester.pump();
    await tester.pump();
    expect(await position(tester), startsWith('Pg. 4/9'), reason: 'the later page of the pair, the page being read');
    tester.view.physicalSize = const Size(1600, 1000);
    await tester.pump();
    await tester.pump();
    expect(await position(tester), startsWith('Pg. 3-4/9'));
  });

  testWidgets('"Shift pairing by one" on the bottom bar (two pages up only): the pages before the spread pair the other '
      'way, kept for this book - and pairing after the spread stays', (tester) async {
    await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.tap(find.byTooltip('Shift pairing by one'));
    await tester.pump();
    await tester.pump();
    expect(PairShift.instance.shifted('B1'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    final seen = <String>[];
    for (var i = 0; i < 5; i++) {
      await turn(tester);
      seen.add((await position(tester)).split(' ·').first);
    }
    expect(seen, ['Pg. 2-3/9', 'Pg. 4-5/9', 'Pg. 6/9', 'Pg. 7/9', 'Pg. 8-9/9']);

    await open(tester, size: const Size(1000, 1600));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.byTooltip('Shift pairing by one'), findsNothing, reason: 'one page at a time: nothing to shift');
  });

  testWidgets('Save page with a pair up asks which: the left, the right, or both; right to left, the earlier page is '
      'on the right', (tester) async {
    await open(tester);
    await turn(tester);
    await turn(tester); // 3|4
    Future<List<String>> choices() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      // (no settling: the pages never load, their spinners turn for good)
      Future<void> frames() async {
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await tester.tap(find.byTooltip('Comic settings'));
      await frames();
      await tester.ensureVisible(find.text('Save page'));
      await tester.tap(find.text('Save page'));
      await frames();
      final options = [
        for (final o in tester.widgetList<SimpleDialogOption>(find.byType(SimpleDialogOption)))
          ((o.child as Text).data!),
      ];
      Navigator.of(tester.element(find.text('Which page?'))).pop(); // (nothing picked: nothing saved)
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      return options;
    }

    expect(await choices(), ['Left (page 3)', 'Right (page 4)', 'Both, as one picture']);
    ReaderServer.direction = 'RIGHT_TO_LEFT';
    await open(tester);
    await turn(tester, back: true); // (right to left: Left is forward)
    await turn(tester, back: true);
    expect(await choices(), ['Left (page 4)', 'Right (page 3)', 'Both, as one picture']);
  });

  group('the page curl, two pages up (user, 2026-10-16: the right-hand page turns over onto the left)', () {
    setUp(() => AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(pageTurn: PageTurn.curl)));

    /// The book with real pictures (2 x 3, as the page list says): pairs are joined.
    Future<void> openReal(WidgetTester tester) async {
      SpreadBook.png = (await tester.runAsync(() => solidPng(200, 300, const Color(0xFFE0D0B0))))!;
      SpreadBook.real = true;
      addTearDown(() => SpreadBook.real = false);
      await open(tester);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
    }

    CurlLayer? curl(WidgetTester tester) {
      final f = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is CurlLayer);
      return f.evaluate().isEmpty ? null : tester.widget<CustomPaint>(f).painter as CurlLayer;
    }

    /// To the pair 3|4 (the cover, page 2 alone, then it), with its picture joined.
    Future<void> toPair(WidgetTester tester, {bool rtl = false}) async {
      AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(pageTurn: PageTurn.flip));
      await turn(tester, back: rtl); // (right to left: Left is forward)
      await turn(tester, back: rtl);
      AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(pageTurn: PageTurn.curl));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50))); // decoded, joined
        await tester.pump();
      }
      expect(await position(tester), startsWith('Pg. 3-4/9'));
    }

    // 1600 x 1000, a pair of 2 x 3 pages: the joined picture 1333 wide, from 133 to 1467, its gutter at 800
    testWidgets('forward from a pair: only the right-hand page curls, from the gutter; the left-hand one stays',
        (tester) async {
      await openReal(tester);
      await toPair(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      final c = curl(tester)!;
      expect(c.page.left, closeTo(800, 1), reason: 'its spine at the gutter');
      expect(c.page.right, closeTo(1467, 1));
      // only the left-hand page's picture held - round it, the next view at once (user, 2026-10-16: "make sure it works
      // properly for single images and double-page spreads": a wider page beneath shows past it)
      expect(c.held!.left, closeTo(133, 1), reason: 'the left-hand page held');
      expect((c.held!.top, c.held!.bottom), (0, 1000));
      expect(c.held!.right, closeTo(800, 1));
      expect(c.mirror, isFalse);
      // (user, 2026-10-16: "the following left-hand page should be shown on the back")
      expect(curl(tester)!.back, isNotNull, reason: 'its back: the next spread, snapshot once in the view');
      expect(identical(curl(tester)!.back, curl(tester)!.sheet), isFalse, reason: 'not the page turning');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(curl(tester), isNull);
      expect(await position(tester), startsWith('Pg. 5-6/9'));
    });

    testWidgets("back to a pair: its right-hand page uncurls back over the right; right to left, mirrored - the "
        "later page on the left, turning from the gutter", (tester) async {
      await openReal(tester);
      await toPair(tester);
      AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(pageTurn: PageTurn.flip));
      await turn(tester); // 5|6
      AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(pageTurn: PageTurn.curl));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.pump();
      final back = curl(tester)!;
      expect(back.page.left, closeTo(800, 1), reason: "3|4's right-hand page comes back");
      // only the right side of the old view stays, until the page lands on it: the left shows 3|4's left-hand page
      // at once, under the page lifting away (user, 2026-10-16: the old left page showed under the curl)
      expect(back.held!.left, closeTo(800, 1), reason: "the right-hand page's picture held, from the gutter");
      expect(back.held!.right, closeTo(1467, 1));
      expect((back.held!.top, back.held!.bottom), (0, 1000));
      expect(back.back, isNotNull, reason: "its back: 5|6's left-hand page, in the view the turn started from");
      expect(identical(back.back, back.sheet), isFalse);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      ReaderServer.direction = 'RIGHT_TO_LEFT';
      await openReal(tester);
      await toPair(tester, rtl: true);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft); // (right to left: forward)
      await tester.pump();
      final c = curl(tester)!;
      expect(c.mirror, isTrue);
      expect(c.page.left, closeTo(133, 1), reason: 'the left-hand page, the later');
      expect(c.page.right, closeTo(800, 1));
      expect(c.held!.left, closeTo(800, 1), reason: 'the right-hand page held');
      expect(c.held!.right, closeTo(1467, 1));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
    });

    testWidgets('dragged to full stretch, the page goes no further than over the page beside it - attached at the '
        'spine (user, 2026-10-16: it pulled away from the spine, the page beneath showing)', (tester) async {
      await openReal(tester);
      await toPair(tester);
      // (a drag turns the page fully once it has come as far as from where it started to the screen's edge)
      final g = await tester.startGesture(const Offset(900, 500));
      for (var i = 1; i <= 30; i++) {
        await g.moveTo(Offset(900 - i * 30.0, 500)); // to the screen's left edge
        await tester.pump(const Duration(milliseconds: 30));
      }
      final c = curl(tester)!;
      expect(c.spine, isTrue);
      expect(c.finger.dx, closeTo(-c.page.width, 1), reason: 'its edge at most over the outer edge of the other page');
      await g.up();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(await position(tester), startsWith('Pg. 5-6/9'));
    });

    testWidgets('a spread in one picture turns as a pair does (user, 2026-10-16): its right half over its middle, the '
        'left half held; back onto it, its right half comes back', (tester) async {
      await openReal(tester);
      AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(pageTurn: PageTurn.flip));
      for (var i = 0; i < 4; i++) {
        await turn(tester); // [1] [2] [3|4] [5|6] then the spread, page 7
      }
      AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(pageTurn: PageTurn.curl));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      expect(await position(tester), startsWith('Pg. 7/9'));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      final c = curl(tester)!;
      expect(c.spine, isTrue);
      expect(c.page.left, closeTo(800, 1), reason: "from the picture's middle");
      expect(c.held!.right, closeTo(800, 1), reason: 'its left half held');
      await tester.pump();
      expect(curl(tester)!.back, isNotNull, reason: "its back: 8|9's left-hand page");
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(await position(tester), startsWith('Pg. 8-9/9'));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.pump();
      final back = curl(tester)!;
      expect(back.spine, isTrue);
      expect(back.page.left, closeTo(800, 1), reason: "the spread's right half comes back");
      expect(back.back, isNotNull, reason: "its back: 8|9's left-hand page");
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
    });

    testWidgets('a page alone (the cover) curls whole, as with one page up', (tester) async {
      await openReal(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      final c = curl(tester)!;
      expect(c.held, isNull);
      expect(c.spine, isFalse, reason: 'it turns away as a single page does');
      expect(c.page.width, lessThan(800), reason: 'the cover itself, centred');
      await tester.pump();
      expect(curl(tester)!.back, isNull, reason: 'it turns away: paper on its back');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
    });

    testWidgets('from a page alone to a pair, the page alone turns as a double page as wide as the pair, background '
        'either side of it (user, 2026-10-17: "turn the single into a double by including background empty space to '
        'each side")', (tester) async {
      await openReal(tester);
      AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(pageTurn: PageTurn.flip));
      await turn(tester); // [1] then [2], alone, before the pair 3|4
      AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(pageTurn: PageTurn.curl));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      expect(await position(tester), startsWith('Pg. 2/9'));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.pump();
      final c = curl(tester)!;
      // page 2 is 667 wide, 467 to 1133; the pair underneath 133 to 1467, its gutter at 800
      expect(c.spine, isTrue, reason: 'it turns over at the gutter, as a pair does');
      expect(c.page.left, closeTo(800, 1), reason: 'its right half, from the gutter');
      expect(c.page.right, closeTo(1467, 1), reason: "and the background beside it, out to the pair's edge");
      expect(c.held!.left, closeTo(133, 1), reason: 'its left half held, the background beside it too');
      expect(c.held!.right, closeTo(800, 1));
      expect(c.back, isNotNull, reason: "its back: the pair's left-hand page");
      // the background beside page 2 is in the snapshot of the old view, solid: what's held of it hides the new
      // spread until the page lands (user, 2026-10-17: transparent, the spread beside the cover "just pops into
      // existence as soon as the curl starts")
      final sheet = c.sheet, scale = sheet.width / 1600;
      final px = (await tester.runAsync(() => sheet.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
      final at = ((500 * scale).round() * sheet.width + (200 * scale).round()) * 4;
      expect(px.getUint8(at + 3), 255, reason: 'the bar left of page 2, held: opaque');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(await position(tester), startsWith('Pg. 3-4/9'));

      // back onto it the same way (user, 2026-10-17: "cover the reverse turn the same way"): its made-up right half
      // comes back over the pair's right-hand page, which stays until it lands
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.pump();
      final back = curl(tester)!;
      expect(back.spine, isTrue);
      expect(back.page.left, closeTo(800, 1));
      expect(back.page.right, closeTo(1467, 1));
      expect(back.held!.left, closeTo(800, 1), reason: "the pair's right-hand page held");
      expect(back.held!.right, closeTo(1467, 1));
      expect(back.back, isNotNull, reason: "its back: the pair's left-hand page");
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(await position(tester), startsWith('Pg. 2/9'));
    });
  });

  test('two pages joined: the shorter scaled to the taller one\'s height, side by side, edge to edge', () async {
    Future<ui.Image> image(int w, int h) {
      final rec = ui.PictureRecorder();
      Canvas(rec).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = const Color(0xFF808080));
      return rec.endRecording().toImage(w, h);
    }

    final joined = await joinPages([await image(100, 150), await image(200, 300)]);
    expect((joined.width, joined.height), (400, 300), reason: '100 x 150 at 300 high is 200 wide, then 200');
  });
}
