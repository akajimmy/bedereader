// The EPUB renderer in the one Reader: the page and its sheet (Inset page), pictures, notes, counting and the text size.
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/epub/count_store.dart';
import 'package:komga_reader/epub/layout.dart' show EpubPage;
import 'package:komga_reader/epub/source.dart';
import 'package:komga_reader/reader/epub_renderer.dart';
import 'package:komga_reader/screens/reader.dart';
import 'package:komga_reader/settings.dart';

import 'support/epub_books.dart';
import 'support/no_network.dart';
import 'support/epub_reader.dart';

void main() {
  epubReaderSetUp();

  testWidgets('on a wide screen the surround is one still layer under the pages: a page dragged halfway moves its '
      'sheet, not the surround (user, 2026-10-11: the whole sheet slides); a portrait screen has none', (tester) async {
    final round = EpubRenderer.surround(AppSettings.instance.epub.colours.background);
    Finder surroundBox() => find.byWidgetPredicate((w) => w is ColoredBox && w.color == round);
    await openEpub(tester, twoChapters(), size: const Size(1600, 1000));
    expect(surroundBox(), findsOneWidget);
    expect(find.descendant(of: find.byType(PageView), matching: surroundBox()), findsNothing,
        reason: 'not drawn with each page (it would slide with them)');
    final before = tester.getRect(surroundBox());
    final drag = await tester.startGesture(const Offset(1200, 500));
    await drag.moveBy(const Offset(-500, 0));
    await tester.pump();
    expect(tester.getRect(surroundBox()), before, reason: 'mid-slide: still');
    await drag.up();
    await settleEpub(tester);

    await openEpub(tester, twoChapters());
    expect(surroundBox(), findsNothing, reason: '800 wide: the page fills the screen');
  }, tags: 'slow');

  testWidgets("the sheet on wide screens switched off on this device (user, 2026-10-11): the page's colour across the "
      'screen, no surround; the text laid out across the screen again (the sheet is the screen\'s now, the text inside '
      'it - 2026-10-22)',
      (tester) async {
    addTearDown(() => AppSettings.instance.setDisplay(const DisplayPrefs()));
    await openEpub(tester, twoChapters(), size: const Size(1600, 1000));
    final round = EpubRenderer.surround(AppSettings.instance.epub.colours.background);
    Finder surroundBox() => find.byWidgetPredicate((w) => w is ColoredBox && w.color == round);
    Set<Rect?> sheets() => tester
        .widgetList<CustomPaint>(find.byWidgetPredicate(
            (w) => w is CustomPaint && w.painter.runtimeType.toString() == '_PagePainter'))
        .map((w) => (w.painter as dynamic).sheet as Rect?)
        .toSet();
    List<Offset> lines() => (tester
            .widgetList<CustomPaint>(find.byWidgetPredicate((w) =>
                w is CustomPaint && w.painter.runtimeType.toString() == '_PagePainter' &&
                (w.painter as dynamic).page != null))
            .first
            .painter as dynamic)
        .page
        .textOrigins as List<Offset>;
    expect(surroundBox(), findsOneWidget);
    expect(sheets().whereType<Rect>(), isNotEmpty);
    final before = lines();
    AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(insetPage: InsetPage.never));
    await tester.pump(EpubRenderer.settleDelay);
    await settleEpub(tester);
    expect(surroundBox(), findsNothing, reason: 'no surround');
    expect(sheets(), {null}, reason: 'no sheet: the page fills the screen');
    expect(lines(), isNot(before), reason: 'laid out for the screen, not the sheet');
  });

  testWidgets("Inset page from the screen (user, 2026-10-22): on a tall screen, Always: the screen's height less 12 "
      "above and below, narrowed to the screen less 12 a side; the text inside it as though it were the screen - the "
      "margin setting's share of the sheet's width in from its edge; Margins: Book's: the chapter's own, in the sheet",
      (tester) async {
    addTearDown(() {
      AppSettings.instance.setDisplay(const DisplayPrefs());
      AppSettings.instance.setEpub(const EpubPrefs());
    });
    await openEpub(tester, twoChapters()); // 800 x 1200
    Set<Rect?> sheets() => tester
        .widgetList<CustomPaint>(find.byWidgetPredicate(
            (w) => w is CustomPaint && w.painter.runtimeType.toString() == '_PagePainter' &&
                (w.painter as dynamic).page != null))
        .map((w) => (w.painter as dynamic).sheet as Rect?)
        .toSet();
    List<Offset> lines() => (tester
            .widgetList<CustomPaint>(find.byWidgetPredicate((w) =>
                w is CustomPaint && w.painter.runtimeType.toString() == '_PagePainter' &&
                (w.painter as dynamic).page != null))
            .first
            .painter as dynamic)
        .page
        .textOrigins as List<Offset>;
    double left(List<Offset> l) => l.map((o) => o.dx).reduce(math.min);
    expect(sheets(), {null}, reason: 'Wide screen (the default): none on a tall screen');
    final e = AppSettings.instance.epub;
    AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(insetPage: InsetPage.always));
    await tester.pump(EpubRenderer.settleDelay);
    await settleEpub(tester);
    // (7:10 of 1176 is 823: wider than the 776 the screen has)
    const sheet = Rect.fromLTWH(12, 12, 776, 1176);
    expect(sheets(), {sheet}, reason: 'the height less 12 each end; too narrow a screen: 12 in at the sides');
    expect(left(lines()) - sheet.left, closeTo(EpubRenderer.sideMargin(e, sheet.width, inSheet: true), 0.5),
        reason: "the margin setting's share of the sheet, in from its edge");

    AppSettings.instance.setEpub(e.copyWith(margins: EpubMargins.book));
    await tester.pump(EpubRenderer.settleDelay);
    await settleEpub(tester);
    expect(sheets(), {sheet}, reason: "the screen's sheet, whatever the margins");
    // (this book sets no page margin of its own: its text the least edge in, from the sheet's)
    expect(left(lines()), inInclusiveRange(sheet.left, sheet.left + 20), reason: "Book's margins: from the sheet's edge");
  });

  testWidgets("on a wide screen, while Inset page settles the sheet stays the one the page is laid out for; then it "
      "changes with the layout (audit, 2026-10-11: it changed at once, the old layout's text over its edge)",
      (tester) async {
    addTearDown(() => AppSettings.instance.setDisplay(const DisplayPrefs()));
    await openEpub(tester, twoChapters(), size: const Size(1600, 1000));
    Set<Rect?> sheets() => tester
        .widgetList<CustomPaint>(find.byWidgetPredicate(
            (w) => w is CustomPaint && w.painter.runtimeType.toString() == '_PagePainter'))
        .map((w) => (w.painter as dynamic).sheet as Rect?)
        .toSet();
    final before = sheets();
    expect(before.whereType<Rect>(), isNotEmpty, reason: 'a sheet at 1600 wide');
    AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(insetPage: InsetPage.never));
    await tester.pump();
    expect(sheets(), before, reason: 'settling: the sheet of the layout shown');
    await tester.pump(EpubRenderer.settleDelay);
    await settleEpub(tester);
    expect(sheets(), {null}, reason: 'laid out without one: none');
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
    await openEpub(tester, MemorySource({
      'c1.xhtml': '<html><body><p><img src="map.png"/></p></body></html>',
      'c2.xhtml': '<html><body><p><img src="banner.png"/></p>${para('word', 30)}</body></html>',
    }, const EpubInfo(spine: ['c1.xhtml', 'c2.xhtml'], toc: []), binary: {'map.png': map, 'banner.png': banner}));
    // the map: a chapter of its own, at its own size, centred (300 x 500 at 250..550 x 350..850 on the 800 x 1200,
    // 1:1 screen) - a tap on it in the middle opens it
    await tester.tapAt(const Offset(400, 600));
    await settleEpub(tester);
    expect(find.byType(RawImage), findsOneWidget, reason: 'the picture full screen');
    await tester.tapAt(const Offset(400, 600));
    await settleEpub(tester);
    expect(find.byType(RawImage), findsNothing, reason: 'a tap closed it');
    expect(find.text('Close'), findsNothing, reason: 'and the controls stayed hidden');
    // the next chapter: a banner (96 tall) at the top - not opened; the middle shows the controls as usual
    await tester.tapAt(const Offset(750, 600));
    await settleEpub(tester);
    await tester.tapAt(const Offset(400, 80));
    await settleEpub(tester);
    expect(find.byType(RawImage), findsNothing, reason: 'a banner does not open');
    expect(find.text('Close'), findsOneWidget, reason: 'the controls instead');
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
    await openEpub(tester, MemorySource({'c1.xhtml': '<html><body><p><img src="map.png"/></p></body></html>'},
        const EpubInfo(spine: ['c1.xhtml'], toc: []), binary: {'map.png': map}));
    await tester.tapAt(const Offset(400, 600));
    await settleEpub(tester);

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
    await settleEpub(tester);
    expect(turns(), 1, reason: 'clockwise');
    expect(find.byType(RawImage), findsOneWidget, reason: 'still open');
    // turned: 500 x 300, as wide as the area (760), 456 tall
    expect(picture().width, closeTo(760, 0.5));
    expect(picture().height, closeTo(456, 0.5));
    expect((button('picture.rotate.ccw'), button('picture.rotate.cw')), (ccwAt, cwAt),
        reason: "the buttons stay where they were as the picture turns (on the picture's corners they moved - user)");

    await tester.tap(find.byKey(const ValueKey('picture.rotate.ccw')));
    await tester.tap(find.byKey(const ValueKey('picture.rotate.ccw')));
    await settleEpub(tester);
    expect(turns(), 3, reason: 'counterclockwise twice from a quarter: three quarters');

    // the remote: Right goes to a button, OK presses it (and doesn't close the picture)
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settleEpub(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settleEpub(tester);
    expect(find.byType(RawImage), findsOneWidget, reason: 'OK on a button turns, not closes');
    expect(turns(), 0, reason: 'Right: the clockwise one - three quarters and one');

    await tester.tapAt(const Offset(400, 600));
    await settleEpub(tester);
    expect(find.byType(RawImage), findsNothing, reason: 'a tap on the picture still closes it');
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
    await settleEpub(tester);
    expect(find.byKey(const ValueKey('epub-counting')), findsOneWidget); // the spinner's progress line
    expect(find.text('Chapter 6 of 6'), findsOneWidget, reason: 'five counted, on the sixth');
    expect(find.byType(PageView), findsNothing, reason: 'no page before the book is counted');
    await tester.tapAt(const Offset(750, 300)); // a turn's tap
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.tapAt(const Offset(400, 300)); // the controls' tap
    await settleEpub(tester);
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
    await openEpub(tester, MemorySource(files, info));
    final first = await epubLabel(tester);
    expect(store.kept, hasLength(1), reason: 'counted, and kept');
    await tester.pumpWidget(const SizedBox());

    // the same book again, its last chapter never coming: the counts kept stand in
    await openEpub(tester, HangingSource(files, info, hangs: 'c5.xhtml'));
    expect(await epubLabel(tester), first, reason: 'the same page of the same count, at once');

    // another text size: another layout, counted (the hanging chapter keeps it on the spinner)
    AppSettings.instance.setEpub(AppSettings.instance.epub.copyWith(size: 28));
    await settleEpub(tester);
    expect(find.byKey(const ValueKey('epub-counting')), findsOneWidget); // the spinner's progress line
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a device that turns: the book counted the other way up too, behind the page, and kept - turned, it '
      'shows at once, no count; a desktop that doesn\'t turn: only the way it is (user, 2026-10-22)', (tester) async {
    final store = EpubCountStore.instance as MemoryCountStore;
    final pause = EpubRenderer.otherWayPause;
    EpubRenderer.countOtherWay = true;
    EpubRenderer.otherWayPause = const Duration(milliseconds: 10);
    addTearDown(() {
      EpubRenderer.countOtherWay = false;
      EpubRenderer.otherWayPause = pause;
      debugDefaultTargetPlatformOverride = null;
    });
    final spine = [for (var i = 0; i < 6; i++) 'c$i.xhtml'];
    final files = {for (final c in spine) c: '<html><body>${List.filled(4, para('delta', 40)).join()}</body></html>'};
    final info = EpubInfo(spine: spine, toc: const []);
    await openEpub(tester, MemorySource(files, info)); // 800 x 1200, a phone or tablet (the test platform)
    await settleEpub(tester);
    await settleEpub(tester);
    expect(store.kept, hasLength(2), reason: 'this way up and the other');
    final before = await epubLabel(tester);

    tester.view.physicalSize = const Size(1200, 800);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('epub-counting')), findsNothing, reason: 'turned: no count');
    expect(find.byType(PageView), findsOneWidget, reason: 'the book at once');
    await settleEpub(tester);
    expect(store.kept, hasLength(2), reason: 'nothing more counted either way');
    expect(await epubLabel(tester), isNot(before), reason: 'its own count landscape (fewer pages)');
    await tester.pumpWidget(const SizedBox());

    // a desktop (no rotation sensor): the way it is only
    store.kept.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await openEpub(tester, MemorySource(files, info));
    await settleEpub(tester);
    await settleEpub(tester);
    expect(store.kept, hasLength(1), reason: "a screen that doesn't turn: the other way never needed");
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets("the book's own text size is measured on the first open and kept with its counts; the next open uses "
      'what was kept instead of loading chapters to measure it again (user, 2026-10-11)', (tester) async {
    final store = EpubCountStore.instance as MemoryCountStore;
    await openEpub(tester, twoChapters());
    expect(store.textSizes.values.single, (1.0, false), reason: 'measured, and kept');
    await tester.pumpWidget(const SizedBox());

    // what's kept is what's used: a size put there shows up in the layout the book is counted in
    final key = store.textSizes.keys.single;
    store.textSizes[key] = (0.5, false);
    store.kept.clear();
    await openEpub(tester, twoChapters());
    expect(store.kept.keys.single, contains('/0.5/'), reason: 'laid out with the kept size, not a fresh measurement');
    expect(store.textSizes[key], (0.5, false), reason: 'not measured again');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("a text size measured with a chapter that couldn't be read (the network, for a moment) isn't kept: the "
      'next open measures again (audit, 2026-10-11: the fallback size was kept until the next app build)',
      (tester) async {
    final store = EpubCountStore.instance as MemoryCountStore;
    final book = twoChapters();
    await openEpub(tester, FailsOnce(book.files, book.infoValue, fails: 'c2.xhtml'));
    expect(store.textSizes, isEmpty, reason: 'measured from fewer chapters: not kept');
    await tester.pumpWidget(const SizedBox());
    await openEpub(tester, twoChapters());
    expect(store.textSizes, hasLength(1), reason: 'every chapter read this time: kept');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("a note whose id is on an empty anchor before it, every note in one div (calibre's - Hogfather): only "
      'that note shows, not them all (tablet test, 2026-10-11)', (tester) async {
    await openEpub(tester, MemorySource({
      'c1.xhtml': '<html><body><p>Here<a href="notes.xhtml#f2">*</a> is a note.</p></body></html>',
      'notes.xhtml': '<html><body><div><p>Footnotes</p>'
          '<a id="f1"></a><p><a href="c1.xhtml"><sup>*</sup></a><span>The first note.</span></p>'
          '<a id="f2"></a><p><a href="c1.xhtml"><sup>*</sup></a><span>The second note.</span></p>'
          '<a id="f3"></a><p><a href="c1.xhtml"><sup>*</sup></a><span>The third note.</span></p>'
          '</div></body></html>',
    }, const EpubInfo(spine: ['c1.xhtml', 'notes.xhtml'], toc: [])));
    final drawn = tester.widget<CustomPaint>(find.descendant(of: find.byType(PageView), matching: find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter.runtimeType.toString() == '_PagePainter')));
    final marker = ((drawn.painter as dynamic).page as EpubPage).links.single;
    await tester.tapAt(tester.getTopLeft(find.byType(PageView)) + marker.rect.center);
    await settleEpub(tester);
    expect(find.text('The second note.'), findsOneWidget, reason: 'that note, alone');
    await tester.tapAt(const Offset(400, 20)); // outside the sheet
    await settleEpub(tester);
  });

  testWidgets("a footnote marker opens the note in a sheet over the page, as Define's (user, 2026-10-11); Back or a "
      'tap outside closes it; the page stays', (tester) async {
    await openEpub(tester, MemorySource({
      'c1.xhtml': '<html><body><p>Here<a href="notes.xhtml#n1">*</a> is a note.</p></body></html>',
      'notes.xhtml': '<html><body><p id="n1"><a href="c1.xhtml">*</a>The note itself.</p></body></html>',
    }, const EpubInfo(spine: ['c1.xhtml', 'notes.xhtml'], toc: [])));
    // the marker, from the page on screen as drawn (its links in page coordinates)
    final drawn = tester.widget<CustomPaint>(find.descendant(of: find.byType(PageView), matching: find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter.runtimeType.toString() == '_PagePainter')));
    final marker = ((drawn.painter as dynamic).page as EpubPage).links.single;
    expect(marker.text, '*');
    await tester.tapAt(tester.getTopLeft(find.byType(PageView)) + marker.rect.center);
    await settleEpub(tester);
    expect(find.text('The note itself.'), findsOneWidget, reason: "the note, its own marker (its link back) left out");
    expect(find.ancestor(of: find.text('The note itself.'), matching: find.byType(BottomSheet)), findsOneWidget,
        reason: 'a sheet, not a dialog');
    await tester.tapAt(const Offset(400, 20)); // outside the sheet
    await settleEpub(tester);
    expect(find.text('The note itself.'), findsNothing);
    expect(find.byType(PageView), findsOneWidget, reason: 'still on the page');
    // Back closes it too
    await tester.tapAt(tester.getTopLeft(find.byType(PageView)) + marker.rect.center);
    await settleEpub(tester);
    expect(find.text('The note itself.'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await settleEpub(tester);
    expect(find.text('The note itself.'), findsNothing);
    expect(find.byType(PageView), findsOneWidget, reason: 'Back closed the note, not the book');
  });
}
