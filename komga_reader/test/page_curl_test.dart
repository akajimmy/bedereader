// The page curl's drawing (lib/page_curl.dart, shaders/curl.frag): the back of the turning page in the colour given.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/page_curl.dart';

import 'support/helpers.dart';

void main() {
  setUpAll(preloadShaders);

  test('turning over onto the page beside it (two pages up): the fold never passes the spine - the page stays '
      'attached there all through the turn and lands flat, its grabbed edge exactly over the outer edge of the other '
      '(user, 2026-10-16: at full stretch it pulled away from the spine, the page beneath showing)', () {
    const w = 800.0, grab = Offset(w, 500);
    for (var x = w; x >= -w; x -= 20) {
      final finger = Offset(x, 500);
      final r = PageCurl.spineRadius(w, grab, finger);
      final f = PageCurl.fold(grab, finger, r);
      if (f == null) continue;
      expect(f.$1.dx, greaterThanOrEqualTo(-1), reason: 'the fold at finger $x (under a pixel)');
    }
    expect(PageCurl.spineRadius(w, grab, grab), PageCurl.radius(w), reason: 'flat: the usual curl');
    final end = PageCurl.fold(grab, const Offset(-w, 500), PageCurl.spineRadius(w, grab, const Offset(-w, 500)))!;
    expect(end.$1.dx, closeTo(0, 1), reason: 'turned over: the fold on the spine, the page flat');
    // the old curl at that point: the fold well past the spine (the page lifted off it)
    expect(PageCurl.fold(grab, const Offset(-w, 500), PageCurl.radius(w))!.$1.dx, lessThan(-50));
  });

  test("the back of the turning page is the colour given: white paper for comics, the eBook page's own (user, "
      '2026-10-11: a light back on the dark page looked wrong)', () async {
    const size = Size(200, 300);
    final sheet = await solidImage(200, 300, const Color(0xFF808080));
    Future<double> lightness(Color paper) async {
      final rec = ui.PictureRecorder();
      PageCurlPainter(program: (await PageCurl.program())!, sheet: sheet, page: Offset.zero & size,
              grab: const Offset(200, 216), finger: const Offset(60, 216), mirror: false, paper: paper)
          .paint(Canvas(rec), size);
      final img = await rec.endRecording().toImage(200, 300);
      final px = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
      img.dispose();
      var sum = 0;
      for (var i = 0; i < px.length; i += 4) {
        sum += px[i] + px[i + 1] + px[i + 2];
      }
      return sum / (px.length / 4 * 3);
    }

    final white = await lightness(PageCurlPainter.whitePaper), dark = await lightness(const Color(0xFF101010));
    expect(dark, lessThan(white - 20), reason: 'the turned-over part drawn dark on a dark page: $dark vs $white');
    sheet.dispose();
  });
}
