import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/page_image.dart';
import 'package:komga_reader/settings.dart';

/// Fit width / fit height: an overflowing page opens centred; in fit height a wide page can be dragged sideways,
/// and dragging on past its edge turns the page.
void main() {
  Future<ui.Image> image(WidgetTester tester, int w, int h) async {
    late ui.Image img;
    await tester.runAsync(() async {
      final rec = ui.PictureRecorder();
      Canvas(rec).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = Colors.white);
      img = await rec.endRecording().toImage(w, h);
    });
    return img;
  }

  Future<ScrollController> page(WidgetTester tester, FitMode fit, int w, int h,
      {bool startAtEnd = false, ValueChanged<bool>? onPan, ValueChanged<bool>? onEdge}) async {
    tester.view.physicalSize = const Size(800, 1200); // portrait tablet
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final scroll = ScrollController();
    final img = await image(tester, w, h);
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
    await page(tester, FitMode.width, 800, 2400); // same state reused below, as a still-mounted neighbour page is
    final scroll = await page(tester, FitMode.width, 800, 2400, startAtEnd: true); // the reader swaps in a fresh controller
    expect(scroll.offset, scroll.position.maxScrollExtent);
  });

  testWidgets('a page that fits is simply centred, nothing to drag', (tester) async {
    bool? pans;
    await page(tester, FitMode.height, 600, 1200, onPan: (p) => pans = p); // 600 wide fits in 800
    expect(pans ?? false, isFalse);
  });
}
