import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/page_image.dart';
import 'package:komga_reader/settings.dart';

import 'support/helpers.dart';

/// Fit width / fit height: an overflowing page opens centred; in fit height a wide page can be dragged sideways,
/// and dragging on past its edge turns the page.
void main() {
  Future<ScrollController> page(WidgetTester tester, FitMode fit, int w, int h,
      {bool startAtEnd = false, ValueChanged<bool>? onPan, ValueChanged<bool>? onEdge}) async {
    setView(tester, const Size(800, 1200)); // portrait tablet
    final scroll = ScrollController();
    final img = await testImage(tester, w, h);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PageCanvas(
      data: PageData(img, Uint8List(0)),
      prefs: ReaderPrefs(fit: fit),
      scroll: scroll,
      startAtEnd: startAtEnd,
      onPanChanged: onPan,
      onEdgeSwipe: onEdge,
    ))));
    await tester.pump();
    await tester.pump();
    return scroll;
  }

  testWidgets('fit height: a spread wider than the screen opens centred and can be dragged sideways', (tester) async {
    bool? pans;
    final scroll = await page(tester, FitMode.height, 1600, 1200, onPan: (p) => pans = p); // 1600 wide at 1200 tall
    expect(scroll.position.maxScrollExtent, 800);
    expect(scroll.offset, 400); // centred
    expect(pans, isTrue); // the reader pauses page swipes for this page
    await tester.drag(find.byType(PageCanvas), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(scroll.offset, lessThan(400)); // dragged towards the left edge
  });

  testWidgets('fit height: dragging on past the edge turns the page', (tester) async {
    final turns = <bool>[];
    final scroll = await page(tester, FitMode.height, 1600, 1200, onEdge: turns.add);
    scroll.jumpTo(scroll.position.maxScrollExtent); // at the right edge
    await tester.pump();
    await tester.drag(find.byType(PageCanvas), const Offset(-200, 0)); // keep pulling left
    await tester.pumpAndSettle();
    expect(turns, [true]); // forward
  });

  testWidgets('fit width: a tall page opens centred', (tester) async {
    final scroll = await page(tester, FitMode.width, 800, 2400); // 800 x 2400 on a 1200-tall screen
    expect(scroll.position.maxScrollExtent, 1200);
    expect(scroll.offset, 600);
  });

  testWidgets('fit width: coming back from the next page opens at its end, even if the page was still built',
      (tester) async {
    // test audit, 2026-09-30: one PageData throughout, as for a still-mounted neighbour page - a new one each pump
    // re-placed the page on its own, so the start-at-end / fresh-controller path wasn't what the test checked
    setView(tester, const Size(800, 1200));
    final data = PageData(await testImage(tester, 800, 2400), Uint8List(0)); // 800 x 2400 on a 1200-tall screen
    Future<ScrollController> show({required bool startAtEnd}) async {
      final scroll = ScrollController(); // the reader swaps in a fresh controller on the way back
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: PageCanvas(
          data: data, prefs: const ReaderPrefs(fit: FitMode.width), scroll: scroll, startAtEnd: startAtEnd))));
      await tester.pump();
      await tester.pump();
      return scroll;
    }

    final first = await show(startAtEnd: false);
    expect(first.offset, 600); // centred: the page was built, and placed, before
    final scroll = await show(startAtEnd: true); // same state, same page
    expect(scroll.position.maxScrollExtent, 1200);
    expect(scroll.offset, 1200, reason: 'at its end');
  });

  testWidgets('fit height on a wide page, then fit screen: page swipes are given back', (tester) async {
    // user's repro: cycling screen -> width -> height -> screen left swiping dead
    final pans = <bool>[];
    await page(tester, FitMode.height, 1600, 1200, onPan: pans.add);
    expect(pans, [true]);
    await page(tester, FitMode.screen, 1600, 1200, onPan: pans.add); // same page, fit changed
    expect(pans, [true, false]);
  });

  testWidgets('going round the fits again: a wide page in fit height is centred every time, not at the left edge',
      (tester) async {
    // user's repro (2026-09-30): the top bar's fit button, round twice - same page, same scroll controller
    setView(tester, const Size(800, 1200));
    // the reader keeps one per page; its offset isn't restored when the page's scroll view comes back (in the reader
    // it wasn't - hence the left edge), so no keepScrollOffset here
    final scroll = ScrollController(keepScrollOffset: false);
    final data = PageData(await testImage(tester, 1600, 1200), Uint8List(0)); // one page: the same data throughout, as in the reader
    Future<void> show(FitMode fit) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: PageCanvas(
          data: data, prefs: ReaderPrefs(fit: fit), scroll: scroll))));
      await tester.pump();
      await tester.pump();
    }

    await show(FitMode.height);
    expect(scroll.offset, 400); // centred
    await show(FitMode.screen);
    await show(FitMode.width);
    await show(FitMode.height); // round again
    expect(scroll.offset, 400, reason: 'centred again, not left at the edge');
  });

  testWidgets('moving off a zoomed page puts it back to fit (the reader forgets the zoom on a turn)', (tester) async {
    // code review, 2026-09-30: coming back, the page was still zoomed while the reader thought it wasn't
    setView(tester, const Size(800, 1200));
    final zoom = TransformationController();
    final data = PageData(await testImage(tester, 800, 1200), Uint8List(0));
    final zoomed = <bool>[];
    Future<void> show({required bool current}) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: PageCanvas(data: data, prefs: const ReaderPrefs(),
          scroll: ScrollController(), zoom: zoom, current: current, onZoomChanged: zoomed.add))));
      await tester.pump();
    }

    await show(current: true);
    zoom.value = Matrix4.diagonal3Values(2, 2, 1); // pinched in
    expect(zoomed, [true]);
    await show(current: false); // turned to the next page: this one is a neighbour now
    await tester.pump();
    expect(zoom.value.getMaxScaleOnAxis(), closeTo(1, 1e-6), reason: 'back to fit');
    expect(zoomed, [true, false]);
  });

  testWidgets('a page that fits is simply centred, nothing to drag', (tester) async {
    // test audit, 2026-09-30: `pans ?? false` passed if the reader was never told; the centring wasn't checked
    bool? pans;
    await page(tester, FitMode.height, 600, 1200, onPan: (p) => pans = p); // 600 wide fits in 800
    expect(pans, isFalse, reason: 'told: page swipes stay on');
    expect(find.byType(SingleChildScrollView), findsNothing); // nothing to drag
    final shown = tester.getRect(find.byType(RawImage));
    expect(shown, const Rect.fromLTWH(100, 0, 600, 1200)); // full height, centred across the 800-wide screen
  });
}
