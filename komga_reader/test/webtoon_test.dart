// Webtoons (user, 2026-10-22 - NOTES, "Webtoon support"): the pages one continuous strip scrolled down - when Komga
// says Webtoon, or a series set to Vertical scroll; a column on a wide screen; the wheel, taps and keys glide it.
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/page_image.dart' show PageCanvas, PageData, ProcessedPicture;
import 'package:komga_reader/reader/comic_renderer.dart';
import 'package:komga_reader/reader_keys.dart';
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

/// The reader's own slider (a webtoon also shows auto-scroll's speed).
Finder readerSlider() =>
    find.byWidgetPredicate((w) => w is Slider && w.key != const ValueKey('auto-scroll-speed'));

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppSettings.instance.setDisplay(const DisplayPrefs());
    AppSettings.instance.setDefault(const ReaderPrefs());
    AppSettings.instance.setWebtoonDefault(AppSettings.webtoonStart);
    AppSettings.instance.webtoonSeries.clear();
    ReaderServer.direction = 'WEBTOON';
    ComicRenderer.doubleTapWait = Duration.zero; // (a tap at once - but in the double tap's own test)
  });
  tearDown(() {
    ReaderServer.direction = 'LEFT_TO_RIGHT';
    ComicRenderer.doubleTapWait = const Duration(milliseconds: 250);
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
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    return api;
  }

  ScrollPosition strip(WidgetTester tester) => tester
      // (the strip's own - the end card can hold another)
      .state<ScrollableState>(find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first)
      .position;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets('Komga says Webtoon: one strip scrolled down, the slices one under the other (the gutter None: edge to '
      'edge), the full width of a tall screen (no page view)', (tester) async {
    AppSettings.instance.setWebtoonDefault(AppSettings.webtoonStart.copyWith(gutter: 0));
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
    expect(readerSlider(), findsNothing);
    await tester.tapAt(const Offset(760, 600)); // the right side, half way down: the middle zone
    await tester.pump();
    expect(readerSlider(), findsOneWidget, reason: 'the controls');
    expect(strip(tester).pixels, closeTo(0, 1), reason: 'no scroll');
  });

  testWidgets('opened again, just where it was left - not the top of that page (user, 2026-10-22: "1 ... for sure"; '
      'Komga keeps only the page)', (tester) async {
    final api = await open(tester);
    const at = 3 * (1280.0 + ReaderPrefs.defaultGutter) + 500; // part way down the fourth slice
    strip(tester).jumpTo(at);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600)); // (kept once it rests)
    await tester.pumpWidget(const SizedBox()); // closed
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    // Komga's page: the slice across the middle (at + 600 - the fourth), as the reader saved it
    api.savedProgress['B1'] = {'page': 4, 'completed': false};
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: api, book: api.withProgress(api.theBook)!)));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(strip(tester).pixels, closeTo(at, 1), reason: 'the same spot');

    // another device moved on to page 6: its top, as before
    await tester.pumpWidget(const SizedBox());
    api.savedProgress['B1'] = {'page': 6, 'completed': false};
    await tester.pumpWidget(MaterialApp(home: ReaderScreen(api: api, book: api.withProgress(api.theBook)!)));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(strip(tester).pixels, closeTo(5 * (1280.0 + ReaderPrefs.defaultGutter), 1), reason: "page 6's top");
  });

  testWidgets('two fingers zoom the strip about the point between them, one then moves it across; Ctrl + the wheel '
      'zooms too (user, 2026-10-22: pinch to zoom, "for sure")', (tester) async {
    await open(tester); // 800 x 1200, the strip 800 wide
    Rect first() =>
        tester.getRect(find.descendant(of: find.byType(ListView), matching: find.byType(RawImage)).first);
    expect(first().width, 800);
    final a = await tester.startGesture(const Offset(300, 400), pointer: 7);
    final b = await tester.startGesture(const Offset(500, 400), pointer: 8);
    await tester.pump();
    for (var i = 1; i <= 10; i++) {
      await a.moveTo(Offset(300 - i * 10.0, 400));
      await b.moveTo(Offset(500 + i * 10.0, 400));
      await tester.pump();
    }
    await a.up();
    await b.up();
    await tester.pump();
    await tester.pump();
    // 200 apart to 400: twice the size, the point between the fingers (400 across) where it was
    expect(first().width, closeTo(1600, 1), reason: 'zoomed in twice');
    // (within a few points: the test moves one finger, then the other - the point between them wobbles)
    expect(first().left, closeTo(-400, 5), reason: 'about the middle');
    // one finger across: the strip follows it
    final g = await tester.startGesture(const Offset(400, 600));
    await g.moveBy(const Offset(150, 0));
    await tester.pump();
    await g.up();
    await tester.pump();
    expect(first().left, closeTo(-250, 5), reason: 'moved across');

    // Ctrl + the wheel down: back out
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final mouse = TestPointer(9, PointerDeviceKind.mouse)..hover(const Offset(400, 600));
    for (var i = 0; i < 8; i++) {
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 100)));
      await tester.pump();
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(first().width, closeTo(800, 1), reason: 'not under its own size');
  });

  testWidgets('auto-scroll (user, 2026-10-22): play scrolls the strip down by itself at its speed and puts the '
      'controls away; the tap that stops it brings the controls and play where the tap was - which carries on; the '
      'next tap is a tap (no paused state); it stops at the end', (tester) async {
    AppSettings.instance.setDisplay(const DisplayPrefs(autoScrollSpeed: 100));
    await open(tester);
    Future<void> run(int frames) async {
      for (var i = 0; i < frames; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await tester.tapAt(const Offset(400, 600)); // the controls
    await tester.pump();
    await tester.tap(find.byTooltip('Auto-scroll'));
    await tester.pump();
    expect(readerSlider(), findsNothing, reason: 'the controls away, to read');
    await run(20);
    expect(strip(tester).pixels, closeTo(100, 10), reason: 'a second at 100 points a second');

    // the tap that stops it: the controls, and play where the tap was (user, 2026-10-22)
    await tester.tapAt(const Offset(300, 500));
    await tester.pump();
    final stopped = strip(tester).pixels;
    await run(10);
    expect(strip(tester).pixels, closeTo(stopped, 1), reason: 'stopped');
    expect(readerSlider(), findsOneWidget, reason: 'the controls');
    final play = find.byKey(const ValueKey('auto-scroll-play'));
    expect(play, findsOneWidget);
    expect((tester.getCenter(play) - const Offset(300, 500)).distance, lessThan(2), reason: 'where the tap was');
    expect(find.byTooltip('Auto-scroll'), findsOneWidget, reason: "the bar's: play (stopped is stopped)");
    // it carries on from there: the controls away again
    await tester.tap(find.byTooltip('Resume auto-scroll'));
    await tester.pump();
    await run(10);
    expect(strip(tester).pixels, greaterThan(stopped + 30), reason: 'on again');
    expect(readerSlider(), findsNothing);
    expect(play, findsNothing);

    // stopped again; the next tap elsewhere puts the controls and the play button away - still stopped
    await tester.tapAt(const Offset(300, 500));
    await tester.pump();
    expect(play, findsOneWidget);
    final still = strip(tester).pixels;
    await tester.tapAt(const Offset(700, 300)); // (the right side: no step down either)
    await tester.pump();
    await run(10);
    expect(play, findsNothing, reason: 'the play button away');
    expect(readerSlider(), findsNothing, reason: 'the controls away');
    expect(strip(tester).pixels, still, reason: 'still stopped');

    // the end: it stops there (the end card)
    strip(tester).jumpTo(strip(tester).maxScrollExtent - 50);
    await tester.pump();
    if (find.byTooltip('Auto-scroll').evaluate().isEmpty) {
      await tester.tapAt(const Offset(400, 600));
      await tester.pump();
    }
    await tester.tap(find.byTooltip('Auto-scroll'));
    await run(30);
    expect(strip(tester).pixels, strip(tester).maxScrollExtent, reason: 'at the end');
  });

  testWidgets('a right-click that stops auto-scroll brings the controls and play where it was, as a tap does (user, '
      '2026-10-23)', (tester) async {
    AppSettings.instance.setDisplay(const DisplayPrefs(autoScrollSpeed: 100));
    await open(tester);
    await tester.tapAt(const Offset(400, 600)); // the controls
    await tester.pump();
    await tester.tap(find.byTooltip('Auto-scroll'));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(readerSlider(), findsNothing);

    await tester.tapAt(const Offset(300, 500), buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
    await tester.pump();
    final stopped = strip(tester).pixels;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(strip(tester).pixels, closeTo(stopped, 1), reason: 'stopped');
    expect(readerSlider(), findsOneWidget, reason: 'the controls');
    final play = find.byKey(const ValueKey('auto-scroll-play'));
    expect(play, findsOneWidget);
    expect((tester.getCenter(play) - const Offset(300, 500)).distance, lessThan(2), reason: 'where the click was');
  });

  testWidgets("auto-scroll's keys - none by default; given keys, one starts and stops it and the others change its "
      'speed (user, 2026-10-22: "create new empty hotkeys for scroll speed")', (tester) async {
    for (final a in [ReaderAction.autoScroll, ReaderAction.scrollFaster, ReaderAction.scrollSlower]) {
      expect(ReaderKeys.defaults[a], isEmpty, reason: '${a.name}: no key by default');
    }
    addTearDown(ReaderKeys.instance.reset);
    await ReaderKeys.instance.assign(ReaderAction.autoScroll, LogicalKeyboardKey.keyA);
    await ReaderKeys.instance.assign(ReaderAction.scrollFaster, LogicalKeyboardKey.keyF);
    await ReaderKeys.instance.assign(ReaderAction.scrollSlower, LogicalKeyboardKey.keyS);
    AppSettings.instance.setDisplay(const DisplayPrefs(autoScrollSpeed: 100));
    await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pump();
    expect(AppSettings.instance.display.autoScrollSpeed, closeTo(125, 0.01), reason: 'faster, and kept');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.pump();
    expect(AppSettings.instance.display.autoScrollSpeed, closeTo(80, 0.01), reason: 'slower');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA); // on
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(strip(tester).pixels, closeTo(80, 10), reason: 'a second at 80');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA); // off
    await tester.pump();
    final at = strip(tester).pixels;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(strip(tester).pixels, at, reason: 'off');
  });

  testWidgets("a double tap zooms the strip in about the spot - as far as a comic's page - and out again; a tap "
      'alone waits for a second, then is a tap (user, 2026-10-22: double-tap to zoom, as comics have it)',
      (tester) async {
    ComicRenderer.doubleTapWait = const Duration(milliseconds: 250);
    await open(tester); // 800 x 1200, the strip 800 wide
    Rect first() =>
        tester.getRect(find.descendant(of: find.byType(ListView), matching: find.byType(ProcessedPicture)).first);
    Future<void> doubleTap(Offset at) async {
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(at);
      await tester.pump();
      await tester.pump();
    }

    await doubleTap(const Offset(400, 300));
    expect(first().width, closeTo(800 * PageCanvas.doubleTapScale, 1), reason: 'zoomed in');
    expect(readerSlider(), findsNothing, reason: 'no controls: a pair is a zoom');
    await doubleTap(const Offset(400, 300));
    expect(first().width, closeTo(800, 1), reason: 'and out');

    // one tap in the middle: the controls, once a second tap is ruled out
    await tester.tapAt(const Offset(400, 600));
    await tester.pump(const Duration(milliseconds: 100));
    expect(readerSlider(), findsNothing, reason: 'not yet');
    await tester.pump(const Duration(milliseconds: 300));
    expect(readerSlider(), findsOneWidget, reason: 'then the controls');

    // switched off (Settings > Webtoons): a tap at once
    await tester.tapAt(const Offset(400, 600)); // (the controls away)
    await tester.pump();
    AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(webtoonDoubleTap: false));
    await tester.pump();
    await tester.tapAt(const Offset(400, 600));
    await tester.pump();
    expect(readerSlider(), findsOneWidget, reason: 'no wait');
  });

  testWidgets("webtoons' image settings (user, 2026-10-22): the slices drawn as a comic's pages are "
      '(ProcessedPicture - Enhance, Enhance colours, Crop edges); a crop takes the sides only, the strip running on',
      (tester) async {
    AppSettings.instance.setWebtoonDefault(AppSettings.webtoonStart.copyWith(crop: 0.04));
    await open(tester); // 800 x 1200
    final pictures = find.descendant(of: find.byType(ListView), matching: find.byType(ProcessedPicture));
    expect(pictures, findsWidgets, reason: "the comics' processing");
    final p = tester.widget<ProcessedPicture>(pictures.first);
    expect((p.prefs.crop, p.sidesOnly), (0.04, true), reason: 'the crop, sides only');
    final r = tester.getRect(pictures.first);
    // 800 wide less 4% each side: 736 at its own size; the full 1280 tall - the top and bottom kept
    expect(r.width, closeTo(736, 1));
    expect(r.height, closeTo(1280, 1));
  });

  testWidgets('opens at the page its progress is on - that slice at the top', (tester) async {
    await open(tester, start: 4);
    expect(strip(tester).pixels, 3 * (1280.0 + ReaderPrefs.defaultGutter), reason: 'three slices and their gutters');
  });

  testWidgets('the gutter: the page colours between one picture and the next, as a page break - 2 px unless set '
      '(user, 2026-10-22: "same as comics, starting with 2px")', (tester) async {
    Future<double> gapAfterFirst() async {
      strip(tester).jumpTo(600); // (both slices on screen)
      await tester.pump();
      final pictures = find.descendant(of: find.byType(ListView), matching: find.byType(FutureBuilder<PageData>),
          skipOffstage: false);
      return tester.getRect(pictures.at(1)).top - tester.getRect(pictures.at(0)).bottom;
    }

    await open(tester);
    expect(await gapAfterFirst(), 2, reason: 'the default: 2 px');
    await tester.pumpWidget(const SizedBox());
    AppSettings.instance.setWebtoonDefault(AppSettings.webtoonStart.copyWith(gutter: 16));
    await open(tester);
    expect(await gapAfterFirst(), 16);
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
    expect(tester.widget<Slider>(readerSlider()).value, 2);
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
