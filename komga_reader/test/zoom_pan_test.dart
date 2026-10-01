import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/page_image.dart';
import 'package:komga_reader/settings.dart';

import 'support/helpers.dart';

/// Walks a zoomed-in page along the reading path: right, then left edge one screen down, ... bottom-right = turn.
void main() {
  Future<(TransformationController, bool Function(bool))> setUpPage(WidgetTester tester, Size screen, int w, int h,
      {bool rtl = false, ValueChanged<void Function(Offset)?>? onZoomToggle}) async {
    setView(tester, screen);
    final zoom = TransformationController();
    bool Function(bool)? step;
    final img = await testImage(tester, w, h);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PageCanvas(
      data: PageData(img, Uint8List(0)),
      prefs: const ReaderPrefs(),
      scroll: ScrollController(),
      zoom: zoom,
      onStepper: (s) => step = s,
      onZoomToggle: onZoomToggle,
      rtl: rtl,
    ))));
    await tester.pump();
    return (zoom, step!);
  }

  Offset at(TransformationController z) {
    final t = z.value.getTranslation();
    return Offset(t.x.roundToDouble(), t.y.roundToDouble());
  }

  testWidgets('zoomed 2x on a page that fills the screen: right, down-left, right, then turn', (tester) async {
    final (zoom, step) = await setUpPage(tester, const Size(400, 600), 800, 1200); // page fills 400x600
    expect(step(true), isFalse); // not zoomed: nothing to pan, the page turns
    zoom.value = Matrix4.identity()..scaleByDouble(2, 2, 1, 1); // top-left quarter showing

    expect(step(true), isTrue);
    await tester.pumpAndSettle();
    expect(at(zoom), const Offset(-400, 0)); // one screen right = the right edge

    expect(step(true), isTrue);
    await tester.pumpAndSettle();
    expect(at(zoom), const Offset(0, -600)); // left edge, one screen down = the bottom

    expect(step(true), isTrue);
    await tester.pumpAndSettle();
    expect(at(zoom), const Offset(-400, -600)); // bottom-right corner

    expect(step(true), isFalse); // at the end: the page turns

    // and back again, mirrored
    expect(step(false), isTrue);
    await tester.pumpAndSettle();
    expect(at(zoom), const Offset(0, -600));
    expect(step(false), isTrue);
    await tester.pumpAndSettle();
    expect(at(zoom), const Offset(-400, 0)); // right edge, one screen up
    expect(step(false), isTrue);
    await tester.pumpAndSettle();
    expect(at(zoom), const Offset(0, 0));
    expect(step(false), isFalse); // top-left: previous page
  });

  testWidgets('clamps: a 3x zoom takes more than one step per row, the last step stops at the edge', (tester) async {
    final (zoom, step) = await setUpPage(tester, const Size(400, 600), 800, 1200);
    zoom.value = Matrix4.identity()..scaleByDouble(3, 3, 1, 1); // page is 1200 x 1800 on screen
    step(true);
    await tester.pumpAndSettle();
    expect(at(zoom), const Offset(-400, 0));
    step(true);
    await tester.pumpAndSettle();
    expect(at(zoom), const Offset(-800, 0)); // right edge (1200 - 400)
    step(true);
    await tester.pumpAndSettle();
    expect(at(zoom), const Offset(0, -600)); // next row
  });

  testWidgets('a zoomed page still narrower than a wide screen stays centred and only steps down', (tester) async {
    // landscape screen 1200x600, portrait page: fits as 400x600 in the middle (x 400..800); 1.5x -> 600 wide
    final (zoom, step) = await setUpPage(tester, const Size(1200, 600), 800, 1200);
    zoom.value = Matrix4.identity()
      ..translateByDouble(-300, 0, 0, 1)
      ..scaleByDouble(1.5, 1.5, 1, 1);
    step(true);
    await tester.pumpAndSettle();
    // centred horizontally: page spans 400*1.5=600..1200 on screen before centring; centre tx = (1200-600)/2 - 600 = -300
    expect(at(zoom), const Offset(-300, -300)); // down to the bottom (900 tall, 600 screen)
    expect(step(true), isFalse);
  });

  testWidgets('right to left: starts top-right, steps left, then the right edge one screen down', (tester) async {
    final (zoom, step) = await setUpPage(tester, const Size(400, 600), 800, 1200, rtl: true);
    zoom.value = Matrix4.identity()
      ..translateByDouble(-400, 0, 0, 1) // top-right quarter showing
      ..scaleByDouble(2, 2, 1, 1);
    step(true);
    await tester.pumpAndSettle();
    expect(at(zoom), const Offset(0, 0)); // one screen left = the left edge
    step(true);
    await tester.pumpAndSettle();
    expect(at(zoom), const Offset(-400, -600)); // right edge, one screen down
    step(true);
    await tester.pumpAndSettle();
    expect(at(zoom), const Offset(0, -600)); // bottom-left: the end of a right-to-left page
    expect(step(true), isFalse);
    step(false);
    await tester.pumpAndSettle();
    expect(at(zoom), const Offset(-400, -600)); // back: rightwards
  });

  group('double-tap zoom', () {
    testWidgets('zooms 2x with the tapped spot staying put; again: back to fit', (tester) async {
      late void Function(Offset) toggle;
      final (zoom, _) = await setUpPage(tester, const Size(400, 600), 800, 1200,
          onZoomToggle: (t) { if (t != null) toggle = t; });
      toggle(const Offset(100, 500));
      await tester.pumpAndSettle();
      expect(zoom.value.getMaxScaleOnAxis(), closeTo(2, 1e-6));
      expect(at(zoom), const Offset(-100, -500)); // (100, 500) * 2 - 100, 500 = still at (100, 500)
      toggle(const Offset(300, 100)); // zoomed in: anywhere zooms back out
      await tester.pumpAndSettle();
      expect(zoom.value.getMaxScaleOnAxis(), closeTo(1, 1e-6));
      expect(at(zoom), Offset.zero);
    });

    testWidgets('near an edge the page is kept on screen; a page narrower than the screen stays centred',
        (tester) async {
      late void Function(Offset) toggle;
      // landscape 1200x600, portrait page shown as 400x600 at x 400..800; 2x = 800 wide, still narrower
      final (zoom, _) = await setUpPage(tester, const Size(1200, 600), 800, 1200,
          onZoomToggle: (t) { if (t != null) toggle = t; });
      toggle(const Offset(1150, 20)); // in the black bar, near the top
      await tester.pumpAndSettle();
      expect(at(zoom), const Offset(-600, -20)); // centred across (the page at 200..1000), the tapped row stays
    });
  });
}

