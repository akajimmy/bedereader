import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'settings.dart';

/// A decoded page and the file it came from.
class PageData {
  PageData(this.image, this.bytes);
  final ui.Image image;
  final Uint8List bytes;
}

/// Loads a book's pages once each and keeps the few around the current page (and the next two, preloaded).
class PageLoader {
  PageLoader(this.api, this.bookId, this.pageNumbers);
  final Komga api;
  final String bookId;
  final List<int> pageNumbers; // index -> Komga page number (1-based)
  final Map<int, Future<PageData>> _cache = {};

  Future<PageData> get(int i) => _cache.putIfAbsent(i, () async {
        try {
          final bytes = await api.pageBytes(bookId, pageNumbers[i]);
          final codec = await ui.instantiateImageCodec(bytes);
          final frame = await codec.getNextFrame();
          return PageData(frame.image, bytes);
        } catch (_) {
          _cache.remove(i); // let a later visit retry
          rethrow;
        }
      });

  /// Called on every page change: preload ahead, forget pages far away (the GC frees them).
  void around(int i) {
    for (final j in [i + 1, i + 2]) {
      if (j < pageNumbers.length) get(j).ignore();
    }
    _cache.removeWhere((k, _) => k < i - 2 || k > i + 3);
  }

  Future<Levels>? _bookLevels;

  /// Auto-levels for the whole book (user's choice: one consistent correction rather than per page), measured once
  /// from five pages spread through the book, skipping the cover.
  Future<Levels> bookLevels() => _bookLevels ??= () async {
        final n = pageNumbers.length;
        final picks = <int>{for (final f in [0.2, 0.35, 0.5, 0.65, 0.8]) (n * f).floor().clamp(n > 2 ? 1 : 0, n - 1)};
        final measured = <Levels>[];
        for (final i in picks) {
          try {
            measured.add(await Levels.measure(await api.pageBytes(bookId, pageNumbers[i])));
          } catch (_) {
            // a page that won't load just doesn't vote
          }
        }
        return Levels.combine(measured);
      }();
}

/// Per-channel black and white points (0..1). Stretching lo..hi to 0..1 fixes yellowed paper and grey blacks.
class Levels {
  const Levels(this.lo, this.hi);
  final List<double> lo, hi; // r, g, b
  static const identity = Levels([0, 0, 0], [1, 1, 1]);

  /// Median black and white point per channel across several pages.
  static Levels combine(List<Levels> all) {
    if (all.isEmpty) return identity;
    double median(List<double> v) => (v..sort())[v.length ~/ 2];
    return Levels(
      [for (var c = 0; c < 3; c++) median([for (final l in all) l.lo[c]])],
      [for (var c = 0; c < 3; c++) median([for (final l in all) l.hi[c]])],
    );
  }

  static Future<Levels> measure(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 96);
      final img = (await codec.getNextFrame()).image;
      final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      img.dispose();
      if (data == null) return identity;
      final px = data.buffer.asUint8List();
      final hist = List.generate(3, (_) => List<int>.filled(256, 0));
      for (var p = 0; p + 3 < px.length; p += 4) {
        hist[0][px[p]]++;
        hist[1][px[p + 1]]++;
        hist[2][px[p + 2]]++;
      }
      final n = px.length ~/ 4, cut = (n * 0.005).round();
      final lo = <double>[], hi = <double>[];
      for (final h in hist) {
        var a = 0, b = 255, acc = 0;
        while (a < 255 && (acc += h[a]) <= cut) { a++; }
        acc = 0;
        while (b > 0 && (acc += h[b]) <= cut) { b--; }
        // don't stretch pages that are mostly one tone (splash pages, covers) too hard
        a = math.min(a, 90);
        b = math.max(b, 165);
        lo.add(a / 255);
        hi.add(b / 255);
      }
      return Levels(lo, hi);
    } catch (_) {
      return identity;
    }
  }
}

/// Per-channel scale and offset (0..1 units) for levels -> contrast -> brightness.
class Tone {
  const Tone(this.scale, this.offset);
  final List<double> scale, offset;

  factory Tone.of(ReaderPrefs p, Levels levels) {
    final f = math.pow(2, p.contrast * 2).toDouble(); // contrast -0.5..0.5 -> x0.5..x2
    final scale = <double>[], offset = <double>[];
    for (var c = 0; c < 3; c++) {
      final sL = 1 / (levels.hi[c] - levels.lo[c]), oL = -levels.lo[c] * sL;
      scale.add(sL * f);
      offset.add((oL - 0.5) * f + 0.5 + p.brightness);
    }
    return Tone(scale, offset);
  }

  bool get isIdentity => scale.every((s) => (s - 1).abs() < 1e-4) && offset.every((o) => o.abs() < 1e-4);

  List<double> get matrix => [
        scale[0], 0, 0, 0, offset[0] * 255,
        0, scale[1], 0, 0, offset[1] * 255,
        0, 0, scale[2], 0, offset[2] * 255,
        0, 0, 0, 1, 0,
      ];
}

/// Sharpen is a plain on/off at a fixed, light strength (user's call after comparing on a 1968 scan: 30% of the
/// original scale looked best and stronger brought up JPEG speckle).
const sharpenAmount = 1.2 * 0.3;

Future<ui.FragmentProgram?>? _program;
Future<ui.FragmentProgram?> _sharpenProgram() => _program ??= ui.FragmentProgram.fromAsset('shaders/page.frag')
    .then<ui.FragmentProgram?>((p) => p)
    .catchError((Object _) => null);

/// One page, laid out by the fit mode and drawn with the series' image adjustments.
/// Fit width scrolls vertically inside the page and fit height horizontally, through [scroll] (the reader uses the
/// same controller to scroll with the remote before turning the page).
class PageCanvas extends StatefulWidget {
  const PageCanvas({super.key, required this.data, required this.prefs, required this.scroll,
      this.startAtEnd = false, this.onStartedAtEnd, this.levels, this.onZoomChanged, this.onWheel, this.onStepper,
      this.zoom, this.rtl = false, this.onPanChanged, this.onEdgeSwipe});
  final PageData data;
  final ReaderPrefs prefs;
  final ScrollController scroll;
  final bool startAtEnd; // came back from the next page: show the bottom (or right) of this one
  final VoidCallback? onStartedAtEnd;
  final Future<Levels> Function()? levels; // the book's auto-levels (used when auto-levels is on)
  final ValueChanged<bool>? onZoomChanged; // pinch-zoomed in or back to fit
  final ValueChanged<double>? onWheel; // mouse wheel over the page (desktop); Ctrl+wheel still zooms

  /// Hands the reader this page's zoomed-in stepper (null when the page goes away): step(forward) moves the zoomed
  /// view one screen along the reading path and returns false when it is already at the end (the page should turn).
  final ValueChanged<bool Function(bool forward)?>? onStepper;

  /// Optional outside controller for the zoom (tests); the page makes its own otherwise.
  final TransformationController? zoom;

  /// Right-to-left book: the zoomed path runs right to left, and fit height starts at the right edge.
  final bool rtl;

  /// Fit height with a page wider than the screen: true while the page can be dragged sideways (the reader stops
  /// page swipes then, so a drag moves the page instead).
  final ValueChanged<bool>? onPanChanged;

  /// Dragging on past the edge of such a page: turn the page (true = forward, in reading direction).
  final ValueChanged<bool>? onEdgeSwipe;

  @override
  State<PageCanvas> createState() => _PageCanvasState();
}

class _PageCanvasState extends State<PageCanvas> with SingleTickerProviderStateMixin {
  Levels _levels = Levels.identity;
  ui.FragmentProgram? _shader;
  late final TransformationController _zoom = widget.zoom ?? TransformationController();
  bool _zoomedIn = false;
  Size? _viewport; // fit-screen layout, for stepping: the viewer's size...
  Rect? _picture; // ...and where the page sits inside it (unzoomed)
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  Animation<Matrix4>? _move;

  @override
  void initState() {
    super.initState();
    _zoom.addListener(() {
      final z = _zoom.value.getMaxScaleOnAxis() > 1.01;
      if (z != _zoomedIn) {
        _zoomedIn = z;
        widget.onZoomChanged?.call(z);
      }
    });
    _anim.addListener(() { final m = _move; if (m != null) _zoom.value = m.value; });
    widget.onStepper?.call(_step);
    _prepare();
  }

  @override
  void dispose() {
    if (_panning == true) widget.onPanChanged?.call(false);
    widget.onStepper?.call(null);
    _anim.dispose();
    if (widget.zoom == null) _zoom.dispose();
    super.dispose();
  }

  /// Zoomed-in reading path (user's design): forward = one screen-width right, clamped to the page's right edge;
  /// from the right edge = back to the left edge and one screen-height down, clamped to the bottom; from the
  /// bottom-right corner = false (turn the page). Backward mirrors it (left; then right edge one screen up; top-left
  /// corner = false). A zoomed page narrower (or shorter) than the screen stays centred on that axis.
  /// Right-to-left books mirror the rows: start top-right, step leftwards, then the right edge one screen down.
  bool _step(bool forward) {
    final vp = _viewport, pic = _picture;
    if (vp == null || pic == null) return false;
    final m = _zoom.value;
    final k = m.getMaxScaleOnAxis();
    if (k <= 1.01) return false;
    final t = m.getTranslation();
    var tx = t.x, ty = t.y;
    // translations that keep the screen inside the page
    final minTx = vp.width - k * pic.right, maxTx = -k * pic.left;
    final minTy = vp.height - k * pic.bottom, maxTy = -k * pic.top;
    final fitsX = minTx >= maxTx, fitsY = minTy >= maxTy;
    final centreX = (minTx + maxTx) / 2, centreY = (minTy + maxTy) / 2;
    const eps = 0.5;
    final atRight = fitsX || tx <= minTx + eps, atLeft = fitsX || tx >= maxTx - eps;
    final atBottom = fitsY || ty <= minTy + eps, atTop = fitsY || ty >= maxTy - eps;
    // a row starts at the left edge (left to right) or the right edge (right to left)
    final rtl = widget.rtl;
    final atRowEnd = rtl ? atLeft : atRight, atRowStart = rtl ? atRight : atLeft;
    final rowStartTx = rtl ? minTx : maxTx, rowEndTx = rtl ? maxTx : minTx;
    double along(double by) => rtl ? math.min(tx + by, maxTx) : math.max(tx - by, minTx); // + = reading direction
    double backAlong(double by) => rtl ? math.max(tx - by, minTx) : math.min(tx + by, maxTx);
    if (forward) {
      if (!atRowEnd) {
        tx = along(vp.width);
      } else if (!atBottom) {
        tx = fitsX ? centreX : rowStartTx;
        ty = math.max(ty - vp.height, minTy);
      } else {
        return false;
      }
    } else {
      if (!atRowStart) {
        tx = backAlong(vp.width);
      } else if (!atTop) {
        tx = fitsX ? centreX : rowEndTx;
        ty = math.min(ty + vp.height, maxTy);
      } else {
        return false;
      }
    }
    if (fitsX) tx = centreX;
    if (fitsY) ty = centreY;
    final target = Matrix4.identity()
      ..translateByDouble(tx, ty, 0, 1)
      ..scaleByDouble(k, k, 1, 1);
    _move = Matrix4Tween(begin: m.clone(), end: target).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOut));
    _anim.forward(from: 0);
    return true;
  }

  @override
  void didUpdateWidget(PageCanvas old) {
    super.didUpdateWidget(old);
    if (old.prefs.autoLevels != widget.prefs.autoLevels || old.prefs.sharpen != widget.prefs.sharpen ||
        old.data != widget.data) {
      _prepare();
    }
    // a new page, a fresh controller (going back swaps it), or told to start at the end: place the scroll again
    if (old.data != widget.data || old.scroll != widget.scroll || (widget.startAtEnd && !old.startAtEnd)) _placed = false;
  }

  Future<void> _prepare() async {
    final p = widget.prefs;
    final levels = p.autoLevels && widget.levels != null ? await widget.levels!() : Levels.identity;
    final shader = p.sharpen ? await _sharpenProgram() : null;
    if (mounted) setState(() { _levels = levels; _shader = shader; });
  }

  @override
  Widget build(BuildContext context) {
    final img = widget.data.image;
    final aspect = img.width / img.height;
    final tone = Tone.of(widget.prefs, _levels);
    final sharpen = widget.prefs.sharpen;

    Widget picture(Size size) {
      if (sharpen && _shader != null) {
        return CustomPaint(size: size, painter: _ShaderPainter(img, _shader!.fragmentShader(), tone, sharpenAmount));
      }
      final raw = RawImage(image: img, width: size.width, height: size.height, fit: BoxFit.fill,
          filterQuality: FilterQuality.medium);
      return tone.isIdentity ? raw : ColorFiltered(colorFilter: ColorFilter.matrix(tone.matrix), child: raw);
    }

    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      switch (widget.prefs.fit) {
        case FitMode.screen:
          final s = aspect > w / h ? Size(w, w / aspect) : Size(h * aspect, h);
          _viewport = Size(w, h);
          _picture = Rect.fromLTWH((w - s.width) / 2, (h - s.height) / 2, s.width, s.height);
          return InteractiveViewer(transformationController: _zoom, maxScale: 4, child: _wheel(Center(child: picture(s))));
        case FitMode.width:
          final s = Size(w, w / aspect);
          _placeScroll(s.height > h);
          _setPan(false);
          return s.height <= h
              ? _wheel(Center(child: picture(s)))
              : SingleChildScrollView(controller: widget.scroll, child: _wheel(picture(s)));
        case FitMode.height:
          final s = Size(h * aspect, h);
          final wide = s.width > w;
          _placeScroll(wide);
          _setPan(wide);
          return !wide
              ? _wheel(Center(child: picture(s)))
              : _edgeSwipe(SingleChildScrollView(controller: widget.scroll, scrollDirection: Axis.horizontal,
                  reverse: widget.rtl, child: _wheel(picture(s))));
      }
    });
  }

  /// Claims mouse-wheel events over the page before the zoom viewer or scroll view can (they would zoom / scroll
  /// on their own); the reader decides whether a notch scrolls the page or turns it. Ctrl+wheel is left alone so
  /// it still zooms.
  Widget _wheel(Widget child) {
    final onWheel = widget.onWheel;
    if (onWheel == null) return child;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerSignal: (e) {
        if (e is PointerScrollEvent && !HardwareKeyboard.instance.isControlPressed) {
          GestureBinding.instance.pointerSignalResolver
              .register(e, (ev) => onWheel((ev as PointerScrollEvent).scrollDelta.dy));
        }
      },
      child: child,
    );
  }

  bool _placed = false; // the scroll position has been set for this page
  bool? _panning;
  double _overscroll = 0;

  /// Where a page that overflows in fit width/height opens: centred (user's call) - or at its end when coming back
  /// from the next page. Done once per page.
  void _placeScroll(bool overflows) {
    if (_placed || !overflows) return;
    _placed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = widget.scroll;
      if (!c.hasClients) return;
      if (widget.startAtEnd) {
        c.jumpTo(c.position.maxScrollExtent);
        widget.onStartedAtEnd?.call();
      } else {
        c.jumpTo(c.position.maxScrollExtent / 2);
      }
    });
  }

  void _setPan(bool pans) {
    if (_panning == pans) return;
    _panning = pans;
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) widget.onPanChanged?.call(pans); });
  }

  /// Dragging on past either edge of a sideways page turns the page (about 80 px of pull).
  Widget _edgeSwipe(Widget child) => NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n is ScrollStartNotification) _overscroll = 0;
          if (n is OverscrollNotification && n.dragDetails != null) {
            _overscroll += n.overscroll;
            if (_overscroll.abs() > 80) {
              final forward = _overscroll > 0; // past the far end = on in reading direction (reverse for right to left)
              _overscroll = 0;
              widget.onEdgeSwipe?.call(forward);
            }
          }
          return false;
        },
        child: child,
      );
}

/// Levels/contrast/brightness plus an unsharp mask, on the GPU (shaders/page.frag).
class _ShaderPainter extends CustomPainter {
  _ShaderPainter(this.image, this.shader, this.tone, this.sharpen);
  final ui.Image image;
  final ui.FragmentShader shader;
  final Tone tone;
  final double sharpen;

  @override
  void paint(Canvas canvas, Size size) {
    var i = 0;
    shader
      ..setFloat(i++, size.width)
      ..setFloat(i++, size.height)
      ..setFloat(i++, 1 / image.width)
      ..setFloat(i++, 1 / image.height);
    for (final v in [...tone.scale, ...tone.offset]) {
      shader.setFloat(i++, v);
    }
    shader
      ..setFloat(i++, sharpen)
      ..setImageSampler(0, image);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_ShaderPainter o) =>
      o.image != image || o.sharpen != sharpen || o.tone.matrix.toString() != tone.matrix.toString();
}
