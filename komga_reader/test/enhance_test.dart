import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/enhance.dart';

/// Enhance runs the real shaders (denoise, Lanczos, RCAS) here: output size, a flat colour stays flat, light speckle
/// is smoothed away, a hard edge stays hard.
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

  testWidgets('scales to the asked size; a flat colour stays flat', (tester) async {
    await tester.runAsync(() async {
      final src = await fromPixels(40, 60, (x, y) => 128);
      final out = await Enhancer.run(src, 55, 82);
      expect(out, isNotNull, reason: 'shaders should compile and run in tests');
      expect((out!.width, out.height), (55, 82));
      final g = await greys(out);
      expect(g.every((v) => (v - 128).abs() <= 1), isTrue);
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
