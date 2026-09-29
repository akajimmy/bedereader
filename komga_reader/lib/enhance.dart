import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// "Enhance" (Image settings, per series; replaces the old Sharpen): the page is cleaned up, scaled and sharpened on
/// the GPU once, at the exact size it's shown at, and that picture is drawn 1:1. Tuned by the user in tools/image-lab
/// on two test pages (a soft 1999 JPEG scan enlarged, a 1984 paper scan shrunk), 2026-09-29:
///   1. Denoise 0.75 - edge-preserving smoothing at page resolution (shaders/denoise.frag)
///   2. scaling to the screen: enlarging with FSR 1 EASU, edge-directed (shaders/easu.frag, added 2026-09-29 by the
///      user's pick); shrinking with Lanczos 3, anti-aliased (shaders/lanczos.frag, two passes)
///   3. RCAS sharpening 0.6 at screen resolution (shaders/rcas.frag)
/// Measured against plain scaling: lines ~1.2x crisper with grain 0.6x (enlarged scan) / 1.0x (shrunk scan) - the
/// old Sharpen gave 1.35-1.56x lines but 2.7-3.6x grain, mostly from sampling the page unfiltered.
class Enhancer {
  static const denoise = 0.75;
  static const sharpen = 0.6;

  static Future<_Programs?>? _programs;

  static Future<_Programs?> _load() => _programs ??= () async {
        try {
          final r = await Future.wait([
            ui.FragmentProgram.fromAsset('shaders/denoise.frag'),
            ui.FragmentProgram.fromAsset('shaders/lanczos.frag'),
            ui.FragmentProgram.fromAsset('shaders/rcas.frag'),
            ui.FragmentProgram.fromAsset('shaders/colours.frag'),
            ui.FragmentProgram.fromAsset('shaders/easu.frag'),
          ]);
          return _Programs(r[0], r[1], r[2], r[3], r[4]);
        } catch (e) {
          debugPrint('enhance: shaders unavailable ($e) - pages are drawn plain');
          return null;
        }
      }();

  /// [src] processed to [width] x [height] physical pixels, or null if the shaders can't run here (then draw plain).
  static Future<ui.Image?> run(ui.Image src, int width, int height) async {
    final p = await _load();
    if (p == null || width <= 0 || height <= 0) return null;
    final watch = Stopwatch()..start();
    final sw = src.width, sh = src.height;

    final clean = await _pass(p.denoise, src, sw, sh, (s) {
      s
        ..setFloat(0, sw.toDouble())
        ..setFloat(1, sh.toDouble())
        ..setFloat(2, 0.2 * denoise);
    });
    final ui.Image scaled;
    if (width >= sw && height >= sh) {
      // enlarging: FSR 1 EASU, edge-directed, one pass
      scaled = await _pass(p.easu, clean, width, height, (s) {
        s
          ..setFloat(0, width.toDouble())
          ..setFloat(1, height.toDouble())
          ..setFloat(2, sw.toDouble())
          ..setFloat(3, sh.toDouble());
      });
      clean.dispose();
    } else {
      // shrinking: Lanczos 3, widened so fine detail averages out (two passes: across, then down)
      final wide = await _pass(p.lanczos, clean, width, sh, (s) => _lanczos(s, width, sh, sw, sh, 0, width / sw));
      clean.dispose();
      scaled = await _pass(p.lanczos, wide, width, height, (s) => _lanczos(s, width, height, width, sh, 1, height / sh));
      wide.dispose();
    }
    final out = await _pass(p.rcas, scaled, width, height, (s) {
      s
        ..setFloat(0, width.toDouble())
        ..setFloat(1, height.toDouble())
        ..setFloat(2, sharpen);
    });
    scaled.dispose();
    debugPrint('enhance: ${sw}x$sh -> ${width}x$height in ${watch.elapsedMilliseconds} ms');
    return out;
  }

  /// "Enhance colours": [src] with auto-levels ([lo]/[hi] per channel, 0..1), then Whiten paper and Deepen ink at
  /// full strength (the user's pick in tools/image-lab), at the page's own size. Null if the shaders can't run here.
  static const whiten = 1.0, ink = 1.0;
  static Future<ui.Image?> colours(ui.Image src, List<double> lo, List<double> hi) async {
    final p = await _load();
    if (p == null) return null;
    final w = src.width, h = src.height;
    return _pass(p.colours, src, w, h, (s) {
      var i = 0;
      s
        ..setFloat(i++, w.toDouble())
        ..setFloat(i++, h.toDouble());
      for (final v in [...lo, ...hi]) {
        s.setFloat(i++, v);
      }
      s
        ..setFloat(i++, whiten)
        ..setFloat(i++, ink);
    });
  }

  static void _lanczos(ui.FragmentShader s, int outW, int outH, int inW, int inH, int axis, double scale) {
    s
      ..setFloat(0, outW.toDouble())
      ..setFloat(1, outH.toDouble())
      ..setFloat(2, inW.toDouble())
      ..setFloat(3, inH.toDouble())
      ..setFloat(4, axis.toDouble())
      ..setFloat(5, scale < 1 ? 1 / scale : 1);
  }

  /// One shader pass over [input], drawn into a new [w] x [h] image.
  static Future<ui.Image> _pass(ui.FragmentProgram program, ui.Image input, int w, int h,
      void Function(ui.FragmentShader) uniforms) {
    final shader = program.fragmentShader();
    uniforms(shader);
    shader.setImageSampler(0, input, filterQuality: FilterQuality.none); // exact pixels: the shaders filter themselves
    final rec = ui.PictureRecorder();
    Canvas(rec).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..shader = shader);
    final picture = rec.endRecording();
    return picture.toImage(w, h).whenComplete(() {
      picture.dispose();
      shader.dispose();
    });
  }
}

class _Programs {
  _Programs(this.denoise, this.lanczos, this.rcas, this.colours, this.easu);
  final ui.FragmentProgram denoise, lanczos, rcas, colours, easu;
}
