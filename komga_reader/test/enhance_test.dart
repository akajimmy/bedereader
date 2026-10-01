import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/enhance.dart';

/// Enhance runs the real shaders (denoise; FSR 1 EASU to enlarge or Lanczos to shrink; RCAS) here: output size, a
/// flat colour stays flat, light speckle is smoothed away, a hard edge stays hard.
void main() {
  Future<ui.Image> fromPixels(int w, int h, int Function(int x, int y) grey) async {
    final bytes = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final v = grey(x, y).clamp(0, 255), i = (y * w + x) * 4;
        bytes..[i] = v..[i + 1] = v..[i + 2] = v..[i + 3] = 255;
      }
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final desc = ui.ImageDescriptor.raw(buffer, width: w, height: h, pixelFormat: ui.PixelFormat.rgba8888);
    final frame = await (await desc.instantiateCodec()).getNextFrame();
    return frame.image;
  }

  Future<List<int>> greys(ui.Image img) async {
    final d = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    return [for (var i = 0; i < d.lengthInBytes; i += 4) d.getUint8(i)];
  }

  double spread(List<int> v) {
    final mean = v.reduce((a, b) => a + b) / v.length;
    return math.sqrt(v.map((x) => (x - mean) * (x - mean)).reduce((a, b) => a + b) / v.length);
  }

  testWidgets('scales to the asked size, enlarging (EASU) or shrinking (the Lanczos path); a flat colour stays flat',
      (tester) async {
    // one test for both directions (they were two, the same steps - test audit, 2026-09-30)
    await tester.runAsync(() async {
      for (final (how, (w, h), grey, (outW, outH)) in [
        ('enlarging', (40, 60), 128, (55, 82)),
        ('shrinking', (80, 120), 90, (61, 92)),
      ]) {
        final src = await fromPixels(w, h, (x, y) => grey);
        final out = await Enhancer.run(src, outW, outH);
        expect(out, isNotNull, reason: '$how: shaders should compile and run in tests');
        expect((out!.width, out.height), (outW, outH), reason: how);
        expect((await greys(out)).every((v) => (v - grey).abs() <= 1), isTrue, reason: '$how: still flat');
      }
    });
  });

  testWidgets('light speckle (JPEG-like) is smoothed away', (tester) async {
    await tester.runAsync(() async {
      final rnd = math.Random(7);
      final noise = List.generate(60 * 60, (_) => 128 + rnd.nextInt(13) - 6); // +-6 of 255
      final src = await fromPixels(60, 60, (x, y) => noise[y * 60 + x]);
      final out = (await Enhancer.run(src, 60, 60))!;
      expect(spread(await greys(out)), lessThan(spread(noise) * 0.5));
    });
  });

  testWidgets('Enhance colours: yellowed paper to white, brown-black ink to black, a strong colour kept', (tester) async {
    await tester.runAsync(() async {
      // three bands: cream paper (244,226,206), faded ink (43,37,24), and a saturated red (200,40,40) - the
      // Secret Wars page's measured paper and ink; levels as the app measured them there
      final bytes = Uint8List(30 * 3 * 4);
      const colours = [[244, 226, 206], [43, 37, 24], [200, 40, 40]];
      for (var i = 0; i < 90; i++) {
        final c = colours[i ~/ 30];
        bytes..[i * 4] = c[0]..[i * 4 + 1] = c[1]..[i * 4 + 2] = c[2]..[i * 4 + 3] = 255;
      }
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final desc = ui.ImageDescriptor.raw(buffer, width: 30, height: 3, pixelFormat: ui.PixelFormat.rgba8888);
      final src = (await (await desc.instantiateCodec()).getNextFrame()).image;
      final out = (await Enhancer.colours(src, [45 / 255, 41 / 255, 28 / 255], [247 / 255, 229 / 255, 209 / 255]))!;
      final d = (await out.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      List<int> at(int x, int y) => [for (var c = 0; c < 3; c++) d.getUint8((y * 30 + x) * 4 + c)];
      expect(at(15, 0).every((v) => v >= 250), isTrue, reason: 'paper ${at(15, 0)}');
      expect(at(15, 1).every((v) => v <= 5), isTrue, reason: 'ink ${at(15, 1)}');
      final red = at(15, 2);
      expect(red[0], greaterThan(190), reason: 'red $red');
      expect(red[1], lessThan(40), reason: 'red $red');
    });
  });

  testWidgets('a hard black/white edge stays hard (ink lines are not blurred)', (tester) async {
    await tester.runAsync(() async {
      final src = await fromPixels(40, 40, (x, y) => x < 20 ? 20 : 235);
      final out = (await Enhancer.run(src, 60, 60))!; // enlarged 1.5x
      final g = await greys(out);
      final row = g.sublist(30 * 60, 31 * 60);
      expect(row.first, lessThan(30));
      expect(row.last, greaterThan(225));
      // from dark to light within ~3 screen pixels of the edge (at 1.5x a plain bilinear ramp is wider)
      final dark = row.lastIndexWhere((v) => v < 40), light = row.indexWhere((v) => v > 215);
      expect(light - dark, lessThanOrEqualTo(4));
    });
  });
}
