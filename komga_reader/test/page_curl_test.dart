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

  test('two pages up, the back of the turning page is the page given (user, 2026-10-16: "the following left-hand '
      'page should be shown on the back"): each point of it shows what lies where it lands, so the landed page is '
      'exactly the page under it - left to right, right to left, and over the gap between two sheets', () async {
    const size = Size(440, 300), red = Color(0xFFFF0000), yellow = Color(0xFFFFFF00), blue = Color(0xFF0000FF);
    final program = (await PageCurl.program())!;
    final sheet = await solidImage(440, 300, const Color(0xFF00FF00));
    // the page on the back, where it lies: two stripes, [a, a + 100) red and [a + 100, a + 200) yellow, blue elsewhere
    Future<ui.Image> backAt(double a) {
      final rec = ui.PictureRecorder(), c = Canvas(rec);
      c.drawRect(Offset.zero & size, Paint()..color = blue);
      c.drawRect(Rect.fromLTWH(a, 0, 100, 300), Paint()..color = red);
      c.drawRect(Rect.fromLTWH(a + 100, 0, 100, 300), Paint()..color = yellow);
      return rec.endRecording().toImage(440, 300);
    }

    Future<Color> at(PageCurlPainter p, double x) async {
      final rec = ui.PictureRecorder();
      p.paint(Canvas(rec), size);
      final img = await rec.endRecording().toImage(440, 300);
      final px = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
      img.dispose();
      final i = (150 * 440 + x.round()) * 4;
      return Color.fromARGB(255, px[i], px[i + 1], px[i + 2]);
    }

    Future<void> check({required Rect page, required bool mirror, required double gap, required double a}) async {
      final back = await backAt(a);
      final landed = PageCurlPainter(program: program, sheet: sheet, page: page, grab: const Offset(200, 150),
          finger: Offset(-200 - gap, 150), mirror: mirror, spine: true, back: back, gap: gap);
      // turned over flat: the back page as it lies (the light on the curl's back aside: red stays reddest, and so on)
      // (10 px either side of the stripes' edge: off by the gap, 20, and it's the other colour)
      for (final (x, want) in [(a + 90, red), (a + 110, yellow), (a + 150, yellow)]) {
        final c = await at(landed, x);
        expect(c.r > 0.5 && c.b < 0.3 && (c.g > 0.5) == (want == yellow), isTrue,
            reason: '$page${mirror ? ' mirrored' : ''}, gap $gap: at $x $c, wanted $want');
      }
      // half way: the part over the other page shows the back page too (red or yellow), not paper or the front
      final half = PageCurlPainter(program: program, sheet: sheet, page: page, grab: const Offset(200, 150),
          finger: Offset(-100 - gap, 150), mirror: mirror, spine: true, back: back, gap: gap);
      final c = await at(half, mirror ? page.right + 50 : page.left - 50);
      expect(c.r > 0.5 && c.b < 0.3, isTrue, reason: 'half way: $c');
      back.dispose();
    }

    await check(page: const Rect.fromLTWH(200, 0, 200, 300), mirror: false, gap: 0, a: 0);
    await check(page: const Rect.fromLTWH(0, 0, 200, 300), mirror: true, gap: 0, a: 200);
    await check(page: const Rect.fromLTWH(220, 0, 200, 300), mirror: false, gap: 20, a: 0);
    sheet.dispose();
  });
}
