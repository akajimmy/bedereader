import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// "3D page curl" page turn (Reader settings > Page turn animation; user, 2026-09-29): the page is a snapshot bent
/// around a cylinder (shaders/curl.frag). Its corner follows the finger on a slow drag; a swipe, tap, arrow or the
/// remote plays the whole turn. Geometry is worked out as for a left-to-right book - the page lifts from the right
/// edge and turns over to the left - and mirrored for right-to-left books.
class PageCurl {
  static Future<ui.FragmentProgram?>? _program;

  /// The curl shader once loaded (null until then, or where it can't run - pages then turn instantly).
  static ui.FragmentProgram? loaded;

  /// Loads the curl shader (the reader starts this when it opens).
  static Future<ui.FragmentProgram?> program() => _program ??= ui.FragmentProgram.fromAsset('shaders/curl.frag')
      .then<ui.FragmentProgram?>((p) => loaded = p)
      .catchError((Object e) {
        debugPrint('page curl: shader unavailable ($e)');
        return null;
      });

  /// Cylinder radius for an area [width] wide.
  static double radius(double width) => width * 0.07;

  /// Finger x where the page has turned completely out of view (the curl's end).
  static double gone(double width) => -width - 2 * radius(width) - 4;

  /// The fold for a page whose grabbed point [grab] (on the right edge) has been brought to [finger]:
  /// (a point on the fold line, its normal towards the lifting side). The page then reaches the finger exactly,
  /// once over the cylinder. Null while the page lies flat (finger at the grab point).
  static (Offset, Offset)? fold(Offset grab, Offset finger, double r) {
    final v = grab - finger;
    final len = v.distance;
    if (len < 0.5) return null;
    final n = v / len;
    return (finger + n * ((len - math.pi * r) / 2), n);
  }
}

/// Paints the curling page (see [PageCurl]). [finger] and [grab] are in reading-direction space (for a right-to-left
/// book, x counted from the right edge); [mirror] flips it back for display.
class PageCurlPainter extends CustomPainter {
  PageCurlPainter({required this.program, required this.sheet, required this.grab, required this.finger,
      required this.mirror});
  final ui.FragmentProgram program;
  final ui.Image sheet;
  final Offset grab, finger;
  final bool mirror;

  @override
  void paint(Canvas canvas, Size size) {
    final r = PageCurl.radius(size.width);
    final f = PageCurl.fold(grab, finger, r);
    if (f == null) {
      // flat: just the page
      canvas.drawImageRect(sheet, Offset.zero & Size(sheet.width.toDouble(), sheet.height.toDouble()),
          Offset.zero & size, Paint()..filterQuality = FilterQuality.medium);
      return;
    }
    final (point, normal) = f;
    final shader = program.fragmentShader()
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, point.dx)
      ..setFloat(3, point.dy)
      ..setFloat(4, normal.dx)
      ..setFloat(5, normal.dy)
      ..setFloat(6, r)
      ..setFloat(7, mirror ? 1 : 0)
      ..setImageSampler(0, sheet, filterQuality: FilterQuality.medium);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
    shader.dispose();
  }

  @override
  bool shouldRepaint(PageCurlPainter o) => o.sheet != sheet || o.grab != grab || o.finger != finger || o.mirror != mirror;
}
