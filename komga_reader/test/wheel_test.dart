import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/page_image.dart';
import 'package:komga_reader/settings.dart';

/// Desktop mouse wheel over a page in fit screen: it turns pages (the reader decides), and never zooms - up or down,
/// over the picture or the black margin beside it. Ctrl+wheel is the zoom.
void main() {
  Future<(List<double>, TransformationController)> page(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000); // landscape window, portrait page: margins left and right
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late ui.Image img;
    await tester.runAsync(() async {
      final rec = ui.PictureRecorder();
      Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 600, 900), Paint()..color = Colors.white);
      img = await rec.endRecording().toImage(600, 900);
    });
    final wheel = <double>[];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PageCanvas(
      data: PageData(img, Uint8List(0)),
      prefs: const ReaderPrefs(fit: FitMode.screen),
      scroll: ScrollController(),
      onWheel: wheel.add,
    ))));
    await tester.pump();
    final viewer = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    return (wheel, viewer.transformationController!);
  }

  Future<void> scroll(WidgetTester tester, Offset at, double dy, {PointerDeviceKind kind = PointerDeviceKind.mouse}) async {
    final p = TestPointer(1, kind);
    await tester.sendEventToBinding(p.hover(at));
    await tester.sendEventToBinding(p.scroll(Offset(0, dy)));
    await tester.pump();
  }

  testWidgets('Ctrl+wheel zooms in and back out to fit, and turns nothing', (tester) async {
    final (wheel, zoom) = await page(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await scroll(tester, const Offset(800, 500), -120);
    expect(zoom.value.getMaxScaleOnAxis(), greaterThan(1.5));
    await scroll(tester, const Offset(800, 500), 1200); // well past fit
    expect(zoom.value.getMaxScaleOnAxis(), 1.0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(wheel, isEmpty);
  });

  for (final (name, at) in [('picture', const Offset(800, 500)), ('margin', const Offset(100, 500))]) {
    for (final dy in [-120.0, 120.0]) {
      testWidgets('wheel ${dy < 0 ? 'up' : 'down'} over the $name: turns, no zoom', (tester) async {
        final (wheel, zoom) = await page(tester);
        await scroll(tester, at, dy);
        expect(zoom.value.getMaxScaleOnAxis(), 1.0);
        expect(wheel, [dy]);
      });
    }
  }
}
