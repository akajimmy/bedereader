import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

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
      this.startAtEnd = false, this.onStartedAtEnd, this.levels, this.onZoomChanged});
  final PageData data;
  final ReaderPrefs prefs;
  final ScrollController scroll;
  final bool startAtEnd; // came back from the next page: show the bottom (or right) of this one
  final VoidCallback? onStartedAtEnd;
  final Future<Levels> Function()? levels; // the book's auto-levels (used when auto-levels is on)
  final ValueChanged<bool>? onZoomChanged; // pinch-zoomed in or back to fit

  @override
  State<PageCanvas> createState() => _PageCanvasState();
}

class _PageCanvasState extends State<PageCanvas> {
  Levels _levels = Levels.identity;
  ui.FragmentProgram? _shader;
  final _zoom = TransformationController();
  bool _zoomedIn = false;

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
    _prepare();
  }

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(PageCanvas old) {
    super.didUpdateWidget(old);
    if (old.prefs.autoLevels != widget.prefs.autoLevels || old.prefs.sharpen != widget.prefs.sharpen ||
        old.data != widget.data) {
      _prepare();
    }
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
          return InteractiveViewer(transformationController: _zoom, maxScale: 4, child: Center(child: picture(s)));
        case FitMode.width:
          final s = Size(w, w / aspect);
          _jumpToEndIfNeeded();
          return s.height <= h
              ? Center(child: picture(s))
              : SingleChildScrollView(controller: widget.scroll, child: picture(s));
        case FitMode.height:
          final s = Size(h * aspect, h);
          _jumpToEndIfNeeded();
          return s.width <= w
              ? Center(child: picture(s))
              : SingleChildScrollView(controller: widget.scroll, scrollDirection: Axis.horizontal, child: picture(s));
      }
    });
  }

  void _jumpToEndIfNeeded() {
    if (!widget.startAtEnd) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = widget.scroll;
      if (c.hasClients) c.jumpTo(c.position.maxScrollExtent);
      widget.onStartedAtEnd?.call();
    });
  }
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
