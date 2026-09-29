import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/page_image.dart';
import 'package:komga_reader/settings.dart';

/// Walks a zoomed-in page along the reading path: right, then left edge one screen down, ... bottom-right = turn.
void main() {
  Future<ui.Image> blankImage(WidgetTester tester, int w, int h) async {
    late ui.Image img;
    await tester.runAsync(() async {
      final rec = ui.PictureRecorder();
      Canvas(rec).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = Colors.white);
      img = await rec.endRecording().toImage(w, h);
    });
    return img;
  }

  Future<(TransformationController, bool Function(bool))> setUpPage(WidgetTester tester, Size screen, int w, int h) async {
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final zoom = TransformationController();
    bool Function(bool)? step;
    final img = await blankImage(tester, w, h);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PageCanvas(
      data: PageData(img, Uint8List(0)),
      prefs: const ReaderPrefs(),
      scroll: ScrollController(),
      zoom: zoom,
      onStepper: (s) => step = s,
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
}
