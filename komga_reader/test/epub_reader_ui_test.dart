// The EPUB renderer in the one Reader: the controls, the slider and its previews, the position row, the end card
// and the next book.
import 'dart:async';

import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/epub/source.dart';
import 'package:komga_reader/reader/epub_renderer.dart';
import 'package:komga_reader/reader/reader_slider.dart';
import 'package:komga_reader/screens/open_book.dart';
import 'package:komga_reader/screens/reader.dart';
import 'package:komga_reader/settings.dart';

import 'support/epub_books.dart';
import 'support/no_network.dart';
import 'support/reader_server.dart';
import 'support/epub_reader.dart';

void main() {
  epubReaderSetUp();

  testWidgets("Windows: an eBook's title bar is the colour along the top - the page's, or with an inset page the "
      'surround round the sheet (user, 2026-10-22)', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final bars = <int>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('komga_reader/screen'),
        (c) async {
      if (c.method == 'titleBar') bars.add(c.arguments as int);
      return null;
    });
    addTearDown(() {
      AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(insetPage: InsetPage.wideScreen));
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('komga_reader/screen'), null);
    });
    await openEpub(tester, twoChapters());
    await settleEpub(tester);
    final page = AppSettings.instance.epub.colours.background;
    expect(bars.last, page.toARGB32(), reason: 'no inset page on a tall screen: the page colour');
    AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(insetPage: InsetPage.always));
    await settleEpub(tester);
    expect(bars.last, EpubRenderer.surround(page).toARGB32(), reason: 'an inset page: the surround');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets("the slider's thumb, dragged, shows a small drawing of the page picked, its number and chapter, over "
      'the thumb; letting go goes there (user, 2026-10-11: as comics have)', (tester) async {
    await openEpub(tester, twoChapters());
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
    await settleEpub(tester);
  });

  Future<void> previewDrawn(WidgetTester tester) async {
    for (var i = 0; i < 20 && find.byKey(const ValueKey('preview-loading')).evaluate().isNotEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('the preview of a chapter laid out for an earlier preview and let go since is laid out again (audit, '
      '2026-10-11: it span for ever)', (tester) async {
    final spine = [for (var i = 0; i < 6; i++) 'c$i.xhtml'];
    await openEpub(tester, MemorySource({for (final c in spine) c: '<html><body>${para('delta', 10)}</body></html>'},
        EpubInfo(spine: spine, toc: const [])));
    await tester.tapAt(const Offset(400, 600)); // the controls
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    final r = tester.getRect(find.byType(Slider));
    var g = await tester.startGesture(Offset(r.left + 20, r.center.dy)); // the thumb, on page 1
    await g.moveTo(Offset(r.left + 60, r.center.dy));
    await g.moveTo(Offset(r.right - 20, r.center.dy)); // the last chapter: laid out for the preview
    await tester.pump();
    await previewDrawn(tester);
    expect(find.byKey(const ValueKey('preview-loading')), findsNothing);
    await g.moveTo(Offset(r.left + 20, r.center.dy)); // back to page 1, and let go there
    await tester.pump();
    await g.up();
    await settleEpub(tester);
    await tester.tapAt(const Offset(400, 600)); // the controls away
    await tester.pump();
    await tester.tapAt(const Offset(760, 600)); // on to chapter 2: the last chapter let go
    await settleEpub(tester);
    await tester.tapAt(const Offset(400, 600));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    g = await tester.startGesture(Offset(r.left + 20 + (r.width - 40) / 5, r.center.dy)); // the thumb, on page 2
    await g.moveTo(Offset(r.right - 20, r.center.dy));
    await tester.pump();
    await previewDrawn(tester);
    expect(find.byKey(const ValueKey('preview-loading')), findsNothing, reason: 'laid out again, drawn');
    await g.moveTo(Offset(r.left + 20 + (r.width - 40) / 5, r.center.dy));
    await g.up();
    await settleEpub(tester);
  }, tags: 'slow');

  testWidgets("on a wide screen the preview draws the whole sheet's page, its ground under all of it (audit, "
      '2026-10-11: drawn at the sheet\'s size, it covered only part)', (tester) async {
    await openEpub(tester, twoChapters(), size: const Size(1600, 1000));
    await tester.tapAt(const Offset(800, 500)); // the controls
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    final r = tester.getRect(find.byType(Slider));
    final g = await tester.startGesture(Offset(r.left + 20, r.center.dy));
    await g.moveTo(Offset(r.left + 80, r.center.dy));
    await tester.pump();
    await previewDrawn(tester);
    final paint = find.descendant(of: find.byKey(const ValueKey('page-preview')),
        matching: find.byWidgetPredicate((w) => w is CustomPaint && w.painter.runtimeType.toString() == '_PagePainter'));
    expect(tester.getSize(paint), const Size(1600, 1000), reason: 'painted at the page size, shifted to the sheet');
    await g.moveTo(Offset(r.left + 20, r.center.dy));
    await g.up();
    await settleEpub(tester);
  });

  testWidgets('an EPUB follows the settings over the page, one set with comics (user, 2026-10-21): page counter, '
      'progress bar', (tester) async {
    AppSettings.instance.setDisplay(const DisplayPrefs(pageNote: PageNote.off, progressBar: false));
    await openEpub(tester, twoChapters());
    expect(find.byKey(const ValueKey('page-corner')), findsNothing, reason: 'Off');
    expect(find.byKey(const ValueKey('reading-progress')), findsNothing);
    final s = AppSettings.instance;
    s.setDisplay(s.display.copyWith(pageNote: PageNote.always, progressBar: true));
    await tester.pump();
    expect(find.byKey(const ValueKey('page-corner')), findsOneWidget);
    expect(find.byKey(const ValueKey('reading-progress')), findsOneWidget);
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
    await openEpub(tester, twoChapters());
    expect(requests, anyElement(equals(['DeviceOrientation.landscapeRight'])), reason: 'held the way it was held');
    wayUp = 'portrait';
    s.setDisplay(s.display.copyWith(rotation: Rotation.portrait)); // changed in the panel
    await tester.pump();
    await tester.pump();
    expect(requests.last, ['DeviceOrientation.portraitUp']);
    await tester.pumpWidget(const SizedBox());
    expect(requests.last, isEmpty, reason: 'closed: the app follows the device again');
  });

  testWidgets("the slider marks where each chapter starts, with the dots comics' slider has for pages - not a dot per "
      'page (user, 2026-10-22: "same marks used for chapters")', (tester) async {
    await openEpub(tester, twoChapters());
    await tester.tapAt(const Offset(400, 600)); // the controls
    await tester.pump();
    final total = int.parse(RegExp(r'/(\d+)').firstMatch(
        tester.widget<Text>(find.byKey(const ValueKey('pos-left-text'))).data!)!.group(1)!);
    final chapter1 = int.parse(RegExp(r'/(\d+)').firstMatch(
        tester.widget<Text>(find.byKey(const ValueKey('pos-right-text'))).data!)!.group(1)!);
    expect(chapter1, lessThan(total));
    final marks = tester.widget<CustomPaint>(find.byKey(const ValueKey('slider-marks'))).painter as SliderMarksPainter;
    final r = tester.getRect(find.byType(Slider));
    const inset = ReaderSlider.inset;
    // the second chapter's first page is page [chapter1] (from 0) of [total]: one mark, there
    expect(marks.xs, hasLength(1), reason: 'two chapters: the second one starts');
    expect(marks.xs.single, closeTo(inset + chapter1 / (total - 1) * (r.width - 2 * inset), 0.5));
    expect(SliderTheme.of(tester.element(find.byType(Slider))).tickMarkShape, SliderTickMarkShape.noTickMark,
        reason: "the Slider's own dot per page: none");
    // a bit more prominent than the Slider's own dots (user, build 137): larger than its radius (a quarter of the
    // track's 4) and stronger than its 38%
    expect(SliderMarksPainter.radius, greaterThan(4 / 4));
    expect(marks.before.a, greaterThan(0.38));
    expect(marks.after.a, greaterThan(0.38));
  });

  testWidgets('the slider: the position shown follows the finger while dragging; the page changes when it lifts',
      (tester) async {
    // six chapters, each a moment to load: the far one, let go of after counting, takes a while to come back
    final spine = [for (var i = 0; i < 6; i++) 'c$i.xhtml'];
    final source = SlowSource({for (final c in spine) c: '<html><body>${List.filled(6, para('gamma', 40)).join()}'
        '</body></html>'}, EpubInfo(spine: spine, toc: const []));
    await openEpub(tester, source); // (shown once counted: "Book · Pg. X/Y · n%")
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
    await settleEpub(tester);
    expect(tester.widget<Text>(find.textContaining(RegExp(r'^Book · Pg\. \d+/\d+ · '))).data, dragged, reason: 'gone there');
  });

  testWidgets("where you are (user's options F + H): the bar has the chapter's name with the book's page and % at "
      "the left and the chapter's page at the right; the page's corner has the book's page of its pages (\"1 / 342\", "
      "as comics' - user 2026-10-07) - always, for a moment after a turn, or not at all", (tester) async {
    final s = AppSettings.instance;
    addTearDown(() => s.setDisplay(s.display.copyWith(pageNote: const DisplayPrefs().pageNote)));
    s.setDisplay(s.display.copyWith(pageNote: PageNote.always));
    await openEpub(tester, twoChapters());
    String corner() => tester.widget<Text>(find.byKey(const ValueKey('page-corner'))).data!;
    double cornerOpacity() => tester.widget<AnimatedOpacity>(
        find.ancestor(of: find.byKey(const ValueKey('page-corner')), matching: find.byType(AnimatedOpacity))).opacity;
    expect(corner(), matches(RegExp(r'^1 / \d+$')), reason: "the book's page of its pages, as comics'");
    expect(cornerOpacity(), 1, reason: 'Always');
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
    await settleEpub(tester);
    expect(cornerOpacity(), 1, reason: 'just turned');
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 300));
    expect(cornerOpacity(), 0, reason: 'a moment later');
    // Off: no corner
    AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(pageNote: PageNote.off));
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
    await settleEpub(tester);
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
    await settleEpub(tester);
    expect(find.text('End of book'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settleEpub(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter); // OK on Close
    await settleEpub(tester);
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
    // a jump through Contents: the way back is marked on the slider (decision 4)
    await tester.tap(find.byTooltip('Contents'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chapter 3'));
    await settleEpub(tester);
    await tester.tapAt(const Offset(400, 600));
    await tester.pump();
    expect(find.byKey(const ValueKey('scrub-start')), findsOneWidget, reason: 'the way back to chapter 1');
    await tester.tapAt(const Offset(400, 600));
    await tester.pump();
    // on to the end card, then Next book (OK): the comic opens in the same Reader
    for (var i = 0; i < 40 && find.text('End of book').evaluate().isEmpty; i++) {
      await tester.tapAt(const Offset(750, 600));
      await settleEpub(tester);
    }
    expect(find.text('Test #2'), findsOneWidget, reason: 'the end card shows the comic up next');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settleEpub(tester);
    expect(api.marked, ['H1'], reason: 'the EPUB left from its end card is read');
    expect(find.byType(ReaderScreen), findsOneWidget, reason: 'the same Reader');
    expect(tester.widget<Text>(find.byKey(const ValueKey('page-corner'))).data, '1 / 3', reason: "the comic's pages");
    await tester.pump(const Duration(seconds: 5));
  }, tags: 'slow');

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
      await settleEpub(tester);
      expect(find.text(list == null ? 'Up next in the series' : 'Up next in this read list'), findsOneWidget);
      expect(find.text(list == null ? 'Hitchhiker #2' : 'Ender #1'), findsOneWidget);
      expect(api.listNextAsked, [list]);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft); // back to the page
      await settleEpub(tester);
      await tester.tapAt(const Offset(400, 600)); // the controls
      await tester.pump();
      await tester.tap(find.byTooltip('Previous book'));
      await settleEpub(tester);
      expect(api.listPrevAsked, [list]);
      expect(find.text(list == null ? 'This is the first book of the series' : 'This is the first book of the read list'),
          findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox());
    }
  });
}
