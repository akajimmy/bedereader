// Webtoons (user, 2026-10-22 - NOTES, "Webtoon support"): the pages one continuous strip scrolled down - when Komga
// says Webtoon, or a series set to Vertical scroll; a column on a wide screen; the wheel, taps and keys glide it.
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/page_image.dart' show PageData;
import 'package:komga_reader/reader/comic_renderer.dart';
import 'package:komga_reader/reader/webtoon_view.dart';
import 'package:komga_reader/screens/reader.dart';
import 'package:komga_reader/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/no_network.dart';
import 'support/reader_server.dart';

/// A webtoon: ten slices 800 wide, 1280 tall but the last (400), its pages loading at once.
class _Strip extends ReaderServer {
  static late Uint8List png;
  @override
  Future<List<dynamic>> pages(String bookId) async =>
      [for (var n = 1; n <= 10; n++) {'number': n, 'width': 800, 'height': n == 10 ? 400 : 1280}];
  @override
  Future<Uint8List> pageBytes(String bookId, int number) async => png;
  @override
  Future<Uint8List> pageThumbBytes(String bookId, int number) async => png;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppSettings.instance.setDisplay(const DisplayPrefs());
    AppSettings.instance.setDefault(const ReaderPrefs());
    AppSettings.instance.setWebtoonDefault(AppSettings.webtoonStart);
    AppSettings.instance.webtoonSeries.clear();
    ReaderServer.direction = 'WEBTOON';
  });
  tearDown(() {
    ReaderServer.direction = 'LEFT_TO_RIGHT';
    AppSettings.instance.setDisplay(const DisplayPrefs());
    AppSettings.instance.setDefault(const ReaderPrefs());
    AppSettings.instance.setWebtoonDefault(AppSettings.webtoonStart);
    AppSettings.instance.webtoonSeries.clear();
  });

  Future<_Strip> open(WidgetTester tester, {Size size = const Size(800, 1200), int? start}) async {
    _Strip.png = (await tester.runAsync(() => solidPng(80, 128, const Color(0xFFE0D0B0))))!;
    setView(tester, size);
    final api = noNetwork(_Strip.new);
    if (start != null) api.savedProgress['B1'] = {'page': start, 'completed': false};
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: api, book: api.withProgress(api.theBook)!)));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    return api;
  }

  ScrollPosition strip(WidgetTester tester) => tester
      .state<ScrollableState>(find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)))
      .position;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets('Komga says Webtoon: one strip scrolled down, the slices edge to edge, the full width of a tall screen '
      '(no page view)', (tester) async {
    await open(tester);
    expect(find.byType(PageView), findsNothing);
    expect(find.byType(ListView), findsOneWidget);
    // each slice's place in the strip (the second, half on screen, may still be loading)
    strip(tester).jumpTo(600); // (both slices on screen)
    await tester.pump();
    final slices = find.descendant(of: find.byType(ListView), matching: find.byType(FutureBuilder<PageData>),
        skipOffstage: false);
    final first = tester.getRect(slices.at(0)), second = tester.getRect(slices.at(1));
    expect(first.width, 800, reason: 'the width of a tall screen');
    expect(first.height, 1280, reason: "Komga's size, at that width");
    expect(second.top, first.bottom, reason: 'edge to edge');
  });

  testWidgets("by default at its own size - one picture pixel to a screen pixel, centred (user, 2026-10-22: \"default "
      'should be to show at native resolution"; it was blown up to the screen held upright); Fit width: edge to edge',
      (tester) async {
    await open(tester, size: const Size(1600, 1000));
    Rect first() =>
        tester.getRect(find.descendant(of: find.byType(ListView), matching: find.byType(RawImage)).first);
    expect(first().width, 800, reason: "its own 800 px (the default fit, Fit screen, is a webtoon's own size)");
    expect(first().center.dx, 800, reason: 'centred');
    expect(first().height, 1280);

    AppSettings.instance.setWebtoonDefault(const ReaderPrefs(fit: FitMode.width));
    await tester.pump();
    await tester.pump();
    expect(first().width, 1600, reason: 'Fit width: edge to edge');
    expect(first().height, 2560, reason: 'in proportion');
  });

  testWidgets('its own size on a denser screen: 800 picture pixels at 2 screen pixels a point are 400 wide; never '
      'wider than the screen', (tester) async {
    tester.view.devicePixelRatio = 2;
    await open(tester, size: const Size(1600, 2400)); // (physical: 800 x 1200 points)
    tester.view.devicePixelRatio = 2;
    await tester.pump();
    final first = tester.getRect(find.descendant(of: find.byType(ListView), matching: find.byType(RawImage)).first);
    expect(first.width, 400);
    expect(WebtoonView.columnWidth(const Size(300, 600), fit: FitMode.original, imageWidth: 800, pixelRatio: 1), 300,
        reason: 'a narrower screen: its width');
  });

  testWidgets("Page scrolling: the wheel goes a screen at a time, not by how far it's spun (user, 2026-10-22: Page "
      'felt like Smooth)', (tester) async {
    AppSettings.instance.setDisplay(const DisplayPrefs(webtoonScroll: WebtoonScroll.page));
    await open(tester);
    final pointer = TestPointer(1, PointerDeviceKind.mouse)..hover(const Offset(400, 600));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 100))); // one notch
    await settle(tester);
    expect(strip(tester).pixels, closeTo(ComicRenderer.pageStep * 1200, 1), reason: 'one notch: a screen');
  });

  testWidgets('no scroll bar over the strip on Windows (user, 2026-10-22: one appeared; the slider says where you '
      'are)', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await open(tester);
      expect(find.byType(ListView), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is RawScrollbar), findsNothing);
      await tester.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets("a clean split (user, 2026-10-22): Komga's webtoon follows webtoons' defaults, not comics' - and a comic "
      'series set to Vertical scroll keeps its comic settings', (tester) async {
    Rect first() =>
        tester.getRect(find.descendant(of: find.byType(ListView), matching: find.byType(RawImage)).first);
    AppSettings.instance.setDefault(const ReaderPrefs(fit: FitMode.width)); // comics: Fit width
    await open(tester, size: const Size(1600, 1000));
    expect(first().width, 800, reason: "the webtoon: webtoons' default, its own size - not comics' Fit width");
    await tester.pumpWidget(const SizedBox());

    // a comic series read as a strip: comics' defaults (Fit width), whatever webtoons' say
    ReaderServer.direction = 'LEFT_TO_RIGHT';
    AppSettings.instance.setDefault(const ReaderPrefs(fit: FitMode.width, direction: ReadingDirection.vertical));
    await open(tester, size: const Size(1600, 1000));
    expect(find.byType(ListView), findsOneWidget, reason: 'a strip');
    expect(first().width, 1600, reason: "comics' Fit width");
  });

  testWidgets('Fit page height: one page - a full slice - as tall as the screen (user, 2026-10-22: "fit 1 page to '
      'screen height")', (tester) async {
    AppSettings.instance.setWebtoonDefault(const ReaderPrefs(fit: FitMode.height));
    await open(tester); // 800 x 1200
    final first = tester.getRect(find.descendant(of: find.byType(ListView), matching: find.byType(RawImage)).first);
    expect(first.height, 1200, reason: "a full page: the screen's height");
    expect(first.width, 750, reason: '800 x 1280 in proportion');
  });

  testWidgets('Tap zones Top / bottom: the bottom third scrolls down, the top up, the middle shows the controls (user, '
      '2026-10-22)', (tester) async {
    AppSettings.instance.setDisplay(const DisplayPrefs(webtoonTaps: WebtoonTaps.topBottom));
    await open(tester);
    await tester.tapAt(const Offset(400, 1100)); // the bottom, in the middle across
    await settle(tester);
    expect(strip(tester).pixels, closeTo(ComicRenderer.smoothStep * 1200, 1), reason: 'down');
    await tester.tapAt(const Offset(400, 100));
    await settle(tester);
    expect(strip(tester).pixels, closeTo(0, 1), reason: 'back up');
    expect(find.byType(Slider), findsNothing);
    await tester.tapAt(const Offset(760, 600)); // the right side, half way down: the middle zone
    await tester.pump();
    expect(find.byType(Slider), findsOneWidget, reason: 'the controls');
    expect(strip(tester).pixels, closeTo(0, 1), reason: 'no scroll');
  });

  testWidgets('opens at the page its progress is on - that slice at the top', (tester) async {
    await open(tester, start: 4);
    expect(strip(tester).pixels, 3 * 1280.0);
  });

  testWidgets('the wheel glides the strip as far as it spins, and the place follows the slice across the middle',
      (tester) async {
    await open(tester);
    final pointer = TestPointer(1, PointerDeviceKind.mouse)..hover(const Offset(400, 600));
    for (var i = 0; i < 20; i++) {
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 100)));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await settle(tester);
    expect(strip(tester).pixels, closeTo(2000, 1), reason: '20 notches of 100');
    // the middle of the screen at 2000 + 600 = 2600: the third slice (from 2560) - on the slider, the controls up
    await tester.tapAt(const Offset(400, 600));
    await tester.pump();
    expect(tester.widget<Slider>(find.byType(Slider)).value, 2);
  });

  testWidgets('a tap at the side glides a short way (Smooth) or most of a screen (Page); the other side back; a held '
      'key glides on steadily', (tester) async {
    await open(tester);
    await tester.tapAt(const Offset(760, 600));
    await settle(tester);
    expect(strip(tester).pixels, closeTo(ComicRenderer.smoothStep * 1200, 1), reason: 'Smooth: a short glide');
    await tester.tapAt(const Offset(40, 600));
    await settle(tester);
    expect(strip(tester).pixels, closeTo(0, 1), reason: 'back');

    AppSettings.instance.setDisplay(const DisplayPrefs(webtoonScroll: WebtoonScroll.page));
    await tester.pump();
    await tester.tapAt(const Offset(760, 600));
    await settle(tester);
    expect(strip(tester).pixels, closeTo(ComicRenderer.pageStep * 1200, 1), reason: 'Page: most of a screen');

    // a held key: Page - a screen each time the last one has landed, never part of one
    Future<double> hold() async {
      final before = strip(tester).pixels;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 40));
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
      await settle(tester);
      return strip(tester).pixels - before;
    }

    final screens = await hold() / (ComicRenderer.pageStep * 1200);
    expect(screens, closeTo(screens.roundToDouble(), 0.01), reason: 'whole screens: $screens');
    expect(screens, inInclusiveRange(1, 3), reason: 'one per glide, not one per repeat');

    // Smooth: its repeats glide on, a little each - no leaps of a screen
    AppSettings.instance.setDisplay(const DisplayPrefs());
    await tester.pump();
    final moved = await hold();
    expect(moved, greaterThan(0), reason: 'it scrolled');
    expect(moved, lessThan(1200 * (ComicRenderer.smoothStep + 10 * ComicRenderer.heldStep) + 1),
        reason: 'the first press a step, the repeats a little each');
  });

  testWidgets('a series set to Vertical scroll reads as a strip whatever Komga says; Auto on a left-to-right series '
      'is the page view', (tester) async {
    ReaderServer.direction = 'LEFT_TO_RIGHT';
    await open(tester);
    expect(find.byType(PageView), findsOneWidget, reason: 'Auto, left to right: pages');
    await tester.pumpWidget(const SizedBox());
    AppSettings.instance.setDefault(const ReaderPrefs(direction: ReadingDirection.vertical));
    await open(tester);
    expect(find.byType(ListView), findsOneWidget, reason: 'Vertical scroll: the strip');
    expect(find.byType(PageView), findsNothing);
  });
}
