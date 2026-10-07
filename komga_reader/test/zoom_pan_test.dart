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

  group('Zoom in from the remote or keys: to where reading starts (user, 2026-10-06/07)', () {
    /// A square page on a 400 x 600 screen: fitted, it's 400 x 400 from y 100 (bars above and below).
    Future<(TransformationController, void Function(bool))> square(WidgetTester tester, {bool rtl = false}) async {
      setView(tester, const Size(400, 600));
      final zoom = TransformationController();
      void Function(bool)? zoomStep;
      final img = await testImage(tester, 600, 600);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: PageCanvas(
        data: PageData(img, Uint8List(0)),
        prefs: const ReaderPrefs(),
        scroll: ScrollController(),
        zoom: zoom,
        onStepper: (_) {},
        onZoomStep: (s) => zoomStep = s,
        rtl: rtl,
      ))));
      await tester.pump();
      return (zoom, zoomStep!);
    }

    double scale(TransformationController z) => z.value.getMaxScaleOnAxis();

    testWidgets("from the whole page: the page's top-left corner at the screen's; again (pressed quickly): further in, "
        'still on the corner', (tester) async {
      final (zoom, zoomIn) = await square(tester);
      zoomIn(true);
      await tester.pumpAndSettle();
      expect(scale(zoom), closeTo(1.5, 0.01));
      expect(at(zoom), const Offset(0, -150), reason: 'the page top (100 x 1.5) at the screen top, its left edge at 0');

      zoomIn(true);
      await tester.pump(const Duration(milliseconds: 50)); // the third press while the second is still moving
      zoomIn(true);
      await tester.pumpAndSettle();
      expect(scale(zoom), closeTo(1.5 * 1.5 * 1.5, 0.01), reason: 'each press a full step, however quick');
      expect(at(zoom), Offset(0, -(100 * 1.5 * 1.5 * 1.5).roundToDouble()), reason: 'still the top-left corner');
    });

    testWidgets('a right-to-left book: the top-right corner', (tester) async {
      final (zoom, zoomIn) = await square(tester, rtl: true);
      zoomIn(true);
      await tester.pumpAndSettle();
      expect(at(zoom), const Offset(400 - 400 * 1.5, -150), reason: "the page's right edge at the screen's");
    });

    testWidgets('panned somewhere: a further step keeps what is at the reading corner where it is', (tester) async {
      final (zoom, zoomIn) = await square(tester);
      zoom.value = Matrix4.identity()
        ..translateByDouble(-200, -300, 0, 1)
        ..scaleByDouble(2, 2, 1, 1); // the screen's corner shows page point (100, 150)
      zoomIn(true);
      await tester.pumpAndSettle();
      expect(at(zoom), const Offset(-300, -450), reason: 'page point (100, 150) x3 still at the corner');
    });
  });
}

