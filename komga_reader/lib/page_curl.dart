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

  /// Cylinder radius for a page [width] wide.
  static double radius(double width) => width * 0.07;

  /// Finger x (page coordinates) where the page has turned completely off itself (the curl's end).
  static double gone(double width) => -width - 2 * radius(width) - 4;

  /// A page turning over onto the page beside it (two pages side by side - its spine at the gutter): the cylinder
  /// narrows as it turns, to nothing (0.5 px - the shader divides by it) once the grabbed edge reaches [width] past
  /// the spine. The fold then never passes the spine: the page stays attached there and lands flat, exactly over the
  /// other page (user, 2026-10-16: at full stretch it pulled away from the spine, the page beneath showing).
  static double spineRadius(double width, Offset grab, Offset finger) {
    final turned = ((grab.dx - finger.dx) / (2 * width)).clamp(0.0, 1.0);
    return math.max(0.5, radius(width) * (1 - turned));
  }

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

  /// [finger], held so the page stays attached along its spine (the left edge, x = 0, of a page [height] tall): a
  /// diagonal drag tilts the fold, but no more than keeps both spine corners flat - past that the page would peel
  /// away from the spine, up or down, like a tear (user, 2026-09-29). The finger's height is brought back towards
  /// the grab's until the corners lie flat, or no lower than they would with a straight (vertical) fold, which only
  /// lifts them at the very end of the turn.
  static Offset pinned(Offset grab, Offset finger, double r, double height) {
    final spine = [Offset.zero, Offset(0, height)];
    double lift(Offset f, Offset c) {
      final fl = fold(grab, f, r);
      return fl == null ? -1 : (c - fl.$1).dx * fl.$2.dx + (c - fl.$1).dy * fl.$2.dy;
    }

    final straight = Offset(finger.dx, grab.dy);
    bool ok(Offset f) => spine.every((c) => lift(f, c) <= math.max(0.0, lift(straight, c)) + 0.5);
    if (ok(finger)) return finger;
    var lo = 0.0, hi = 1.0; // share of the finger's height change kept
    for (var i = 0; i < 14; i++) {
      final mid = (lo + hi) / 2;
      ok(Offset(finger.dx, grab.dy + (finger.dy - grab.dy) * mid)) ? lo = mid : hi = mid;
    }
    return Offset(finger.dx, grab.dy + (finger.dy - grab.dy) * lo);
  }
}

/// Paints the curling page (see [PageCurl]): only the page's image ([page], its rectangle on screen - not the black
/// bars around it), cut from [sheet], a snapshot of the whole area. [grab] and [finger] are in the page's own
/// coordinates in reading direction (origin at its top-left, or top-right for a right-to-left book: [mirror]).
class PageCurlPainter extends CustomPainter {
  /// [shader]: one kept by the caller and used for every paint (else one is made, and freed, per paint).
  PageCurlPainter({required this.program, required this.sheet, required this.page, required this.grab,
      required this.finger, required this.mirror, this.shader, this.paper = whitePaper, this.spine = false});
  final ui.FragmentProgram program;
  final ui.FragmentShader? shader;
  final ui.Image sheet;
  final Rect page;
  final Offset grab, finger;
  final bool mirror;

  /// It turns over onto the page beside it, attached at the spine ([PageCurl.spineRadius]) - two pages side by side.
  final bool spine;

  /// The back of the page: white paper (comics), or the page's own colour (eBooks - user, 2026-10-11: a light back
  /// on the dark page looked wrong).
  final Color paper;
  static const whitePaper = Color(0xFFF7F5F0);

  @override
  void paint(Canvas canvas, Size size) {
    final r = spine ? PageCurl.spineRadius(page.width, grab, finger) : PageCurl.radius(page.width);
    final f = PageCurl.fold(grab, PageCurl.pinned(grab, finger, r, page.height), r);
    if (f == null) {
      // flat: just the page
      final scale = sheet.width / size.width;
      canvas.drawImageRect(sheet, Rect.fromLTWH(page.left * scale, page.top * scale, page.width * scale,
          page.height * scale), page, Paint()..filterQuality = FilterQuality.medium);
      return;
    }
    final (point, normal) = f;
    var i = 0;
    final s = shader ?? program.fragmentShader();
    for (final v in [size.width, size.height, page.left, page.top, page.width, page.height, point.dx, point.dy,
        normal.dx, normal.dy, r, mirror ? 1.0 : 0.0, paper.r, paper.g, paper.b]) {
      s.setFloat(i++, v);
    }
    s.setImageSampler(0, sheet, filterQuality: FilterQuality.medium);
    canvas.drawRect(Offset.zero & size, Paint()..shader = s);
    if (shader == null) s.dispose();
  }

  @override
  bool shouldRepaint(PageCurlPainter o) =>
      o.sheet != sheet || o.page != page || o.grab != grab || o.finger != finger || o.mirror != mirror ||
      o.paper != paper || o.spine != spine;
}
