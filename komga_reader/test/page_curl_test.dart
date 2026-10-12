// The page curl's drawing (lib/page_curl.dart, shaders/curl.frag): the back of the turning page in the colour given.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/page_curl.dart';

import 'support/helpers.dart';

void main() {
  setUpAll(preloadShaders);

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
