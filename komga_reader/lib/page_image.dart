import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'errors.dart' show PageUnreadable;
import 'enhance.dart';
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
          final ui.FrameInfo frame;
          try {
            frame = await (await ui.instantiateImageCodec(bytes)).getNextFrame();
          } catch (e) {
            throw PageUnreadable(e); // arrived, but can't be decoded: damaged, or a format this device can't read
          }
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
  /// from five pages spread through the book, skipping the cover - all five at once - and remembered on the device,
  /// so opening the book again has nothing to wait for.
  Future<Levels> bookLevels() => _bookLevels ??= () async {
        final key = 'levels.$bookId';
        final prefs = await SharedPreferences.getInstance();
        final saved = prefs.getString(key);
        if (saved != null) {
          final v = saved.split(',').map(double.tryParse).toList();
          if (v.length == 6 && v.every((x) => x != null)) return Levels(v.sublist(0, 3).cast(), v.sublist(3).cast());
        }
        final n = pageNumbers.length;
        final picks = <int>{for (final f in [0.2, 0.35, 0.5, 0.65, 0.8]) (n * f).floor().clamp(n > 2 ? 1 : 0, n - 1)};
        final measured = await Future.wait([
          for (final i in picks)
            api.pageBytes(bookId, pageNumbers[i]).then<Levels?>(Levels.measure).catchError((Object _) => null),
        ]); // a page that won't load just doesn't vote
        final got = measured.whereType<Levels>().toList();
        final levels = Levels.combine(got);
        if (got.length == picks.length) await prefs.setString(key, [...levels.lo, ...levels.hi].join(','));
        return levels;
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

/// Crop edges: [img] with [share] of its width and height cut off every side (a quick GPU copy, once per page).
Future<ui.Image> cropEdges(ui.Image img, double share) {
  final dx = (img.width * share).round(), dy = (img.height * share).round();
  final w = img.width - 2 * dx, h = img.height - 2 * dy;
  final rec = ui.PictureRecorder();
  Canvas(rec).drawImageRect(img, Rect.fromLTWH(dx.toDouble(), dy.toDouble(), w.toDouble(), h.toDouble()),
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..filterQuality = FilterQuality.none);
  final picture = rec.endRecording();
  return picture.toImage(w, h).whenComplete(picture.dispose);
}

/// One page, laid out by the fit mode and drawn with the series' image adjustments.
/// Fit width scrolls vertically inside the page and fit height horizontally, through [scroll] (the reader uses the
/// same controller to scroll with the remote before turning the page).
class PageCanvas extends StatefulWidget {
  const PageCanvas({super.key, required this.data, required this.prefs, required this.scroll,
      this.startAtEnd = false, this.onStartedAtEnd, this.levels, this.onZoomChanged, this.onWheel, this.onStepper,
      this.zoom, this.rtl = false, this.onPanChanged, this.onEdgeSwipe, this.onPageRect, this.idle, this.onZoomToggle,
      this.onZoomStep});
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

  /// Hands the reader this page's double-tap zoom (null when the page goes away): toggle(globalPosition) zooms in on
  /// that spot, or back out to fit when zoomed in. Fit screen only.
  final ValueChanged<void Function(Offset global)?>? onZoomToggle;

  /// Hands the reader this page's zoom step (null when the page goes away): step(true) zooms in, step(false) out.
  final ValueChanged<void Function(bool zoomIn)?>? onZoomStep;

  /// Optional outside controller for the zoom (tests); the page makes its own otherwise.
  final TransformationController? zoom;

  /// Right-to-left book: the zoomed path runs right to left, and fit height starts at the right edge.
  final bool rtl;

  /// Fit height with a page wider than the screen: true while the page can be dragged sideways (the reader stops
  /// page swipes then, so a drag moves the page instead).
  final ValueChanged<bool>? onPanChanged;

  /// Dragging on past the edge of such a page: turn the page (true = forward, in reading direction).
  final ValueChanged<bool>? onEdgeSwipe;

  /// Where the page's image sits in this widget (unzoomed), as laid out - not the bars around it. The page curl
  /// bends only this part.
  final ValueChanged<Rect>? onPageRect;

  /// For a page off screen (the reader's neighbours): completes once no page turn is playing. Enhance colours and
  /// Enhance wait for it, so their GPU work doesn't land on a turn's frames - a curl or wipe hitched while the page
  /// after next was processed during it (user, 2026-09-29). Null: process at once (the page on screen).
  final Future<void> Function()? idle;

  @override
  State<PageCanvas> createState() => _PageCanvasState();
}

class _PageCanvasState extends State<PageCanvas> with SingleTickerProviderStateMixin {
  Levels _levels = Levels.identity;
  // Enhance colours (lib/enhance.dart): the page after auto-levels + whiten paper + deepen ink, at page size
  // Crop edges: the page with the chosen share cut off every side (null = not cropped)
  ui.Image? _cropped;
  double _croppedBy = 0;
  ui.Image? _coloured;
  bool _colourFailed = false; // the shaders can't run here: show the page with plain auto-levels
  int _colourRun = 0;
  // Enhance (lib/enhance.dart): the page processed at the exact physical size it's shown at, made once per size
  ui.Image? _enhanced;
  Size? _enhancedFor;
  bool _enhanceFailed = false;
  int _enhanceRun = 0; // a newer request (page / size / switch changed) makes older results stale
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
    widget.onZoomToggle?.call(_toggleZoom);
    widget.onZoomStep?.call(_zoomStep);
    _prepare();
  }

  @override
  void dispose() {
    if (_panning == true) widget.onPanChanged?.call(false);
    widget.onStepper?.call(null);
    widget.onZoomToggle?.call(null);
    widget.onZoomStep?.call(null);
    _enhanceRun++;
    _enhanced?.dispose();
    _colourRun++;
    _coloured?.dispose();
    _cropped?.dispose();
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
    _animateTo(Matrix4.identity()
      ..translateByDouble(tx, ty, 0, 1)
      ..scaleByDouble(k, k, 1, 1));
    return true;
  }

  void _animateTo(Matrix4 target) {
    _move = Matrix4Tween(begin: _zoom.value.clone(), end: target)
        .animate(CurvedAnimation(parent: _anim, curve: Curves.easeOut));
    _anim.forward(from: 0);
  }

  static const doubleTapScale = 2.0;

  /// Double-tap zoom: in to [doubleTapScale] with the tapped spot staying where it is - moved just enough to keep
  /// the screen inside the page (a tap in the black bars beside a page zooms on its nearest edge) - or, zoomed in
  /// (by double tap or pinch), back out to fit.
  void _toggleZoom(Offset global) {
    final vp = _viewport, pic = _picture, box = context.findRenderObject();
    if (vp == null || pic == null || box is! RenderBox || !box.attached) return;
    if (_zoom.value.getMaxScaleOnAxis() > 1.01) {
      _animateTo(Matrix4.identity());
      return;
    }
    const k = doubleTapScale;
    final p = box.globalToLocal(global);
    final tx = _keep(p.dx * (1 - k), vp.width - k * pic.right, -k * pic.left);
    final ty = _keep(p.dy * (1 - k), vp.height - k * pic.bottom, -k * pic.top);
    _animateTo(Matrix4.identity()
      ..translateByDouble(tx, ty, 0, 1)
      ..scaleByDouble(k, k, 1, 1));
  }

  /// Same bounds as the stepper's: the screen stays inside the page; a page narrower (or shorter) than the screen
  /// when zoomed stays centred.
  static double _keep(double t, double min, double max) => min >= max ? (min + max) / 2 : t.clamp(min, max);

  /// Zoom one step in or out (Remote and keys: Zoom in / Zoom out), x1.5 a step between fit and 4x, the middle of
  /// the screen staying on the same spot of the page. Fit screen only.
  void _zoomStep(bool zoomIn) {
    final vp = _viewport, pic = _picture;
    if (vp == null || pic == null) return;
    final m = _zoom.value;
    final k = m.getMaxScaleOnAxis();
    final target = (zoomIn ? k * 1.5 : k / 1.5).clamp(1.0, 4.0);
    if ((target - k).abs() < 1e-3) return;
    if (target <= 1.01) {
      _animateTo(Matrix4.identity());
      return;
    }
    final t = m.getTranslation();
    final cx = vp.width / 2, cy = vp.height / 2;
    final sx = (cx - t.x) / k, sy = (cy - t.y) / k; // the point of the page now in the middle of the screen
    final tx = _keep(cx - target * sx, vp.width - target * pic.right, -target * pic.left);
    final ty = _keep(cy - target * sy, vp.height - target * pic.bottom, -target * pic.top);
    _animateTo(Matrix4.identity()
      ..translateByDouble(tx, ty, 0, 1)
      ..scaleByDouble(target, target, 1, 1));
  }

  @override
  void didUpdateWidget(PageCanvas old) {
    super.didUpdateWidget(old);
    final cropChanged = old.prefs.crop != widget.prefs.crop;
    if (old.prefs.autoLevels != widget.prefs.autoLevels || old.data != widget.data || cropChanged) {
      if (old.data != widget.data || !widget.prefs.autoLevels || cropChanged) {
        _coloured?.dispose();
        _coloured = null;
      }
      if (old.data != widget.data || cropChanged) {
        _cropped?.dispose();
        _cropped = null;
      }
      _colourFailed = false;
      _dropEnhanced();
      _prepare();
    }
    if (old.data != widget.data || !widget.prefs.sharpen) _dropEnhanced();
    // a new page, a fresh controller (going back swaps it), or told to start at the end: place the scroll again
    if (old.data != widget.data || old.scroll != widget.scroll || (widget.startAtEnd && !old.startAtEnd)) _placed = false;
  }

  /// Enhance colours: the book's levels, then the colour-corrected page (the page shows with plain auto-levels
  /// until it's ready; without the shaders that's what stays).
  Future<void> _prepare() async {
    final p = widget.prefs;
    final run = ++_colourRun;
    if (p.crop > 0 || p.autoLevels) {
      await widget.idle?.call(); // off screen: the crop and colour passes wait until no page turn is playing
      if (!mounted || run != _colourRun) return;
    }
    var img = widget.data.image;
    if (p.crop > 0) {
      if (_cropped == null || _croppedBy != p.crop) {
        final cut = await cropEdges(img, p.crop);
        if (!mounted || run != _colourRun) { cut.dispose(); return; }
        setState(() {
          _cropped?.dispose();
          _cropped = cut;
          _croppedBy = p.crop;
        });
      }
      img = _cropped!;
    }
    final levels = p.autoLevels && widget.levels != null ? await widget.levels!() : Levels.identity;
    if (!mounted || run != _colourRun) return;
    setState(() => _levels = levels);
    ui.Image? coloured;
    if (p.autoLevels) coloured = await Enhancer.colours(img, levels.lo, levels.hi);
    if (!mounted || run != _colourRun) { coloured?.dispose(); return; }
    setState(() {
      _coloured?.dispose();
      _coloured = coloured;
      _colourFailed = p.autoLevels && coloured == null;
      _dropEnhanced(); // Enhance starts again from the new colours
    });
  }

  void _dropEnhanced() {
    _enhanceFailed = false;
    _enhanceRun++;
    _enhanced?.dispose();
    _enhanced = null;
    _enhancedFor = null;
  }

  /// Makes the enhanced picture for [physical] (after this frame; the page shows plain until it's ready).
  void _enhance(Size physical, ui.Image img) {
    if (_enhancedFor == physical) return;
    _enhancedFor = physical; // requested: don't ask again for this size
    final run = ++_enhanceRun;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (run != _enhanceRun || !mounted) return;
      await widget.idle?.call(); // off screen: not during a page turn
      if (run != _enhanceRun || !mounted) return;
      final out = await Enhancer.run(img, physical.width.round(), physical.height.round());
      if (out == null) {
        if (run == _enhanceRun && mounted) setState(() => _enhanceFailed = true); // can't run here: plain
        return;
      }
      if (run != _enhanceRun || !mounted) { out.dispose(); return; }
      setState(() {
        _enhanced?.dispose();
        _enhanced = out;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final img = widget.data.image;
    final cropping = widget.prefs.crop > 0;
    final base = _coloured ?? (cropping ? _cropped : null) ?? img; // Enhance colours already applied levels and crop
    final aspect = base.width / base.height;
    final tone = Tone.of(widget.prefs, _coloured != null ? Levels.identity : _levels);
    final enhance = widget.prefs.sharpen; // the setting is still called sharpen in the synced settings
    final dpr = MediaQuery.devicePixelRatioOf(context);

    Widget picture(Size size) {
      // hold the page until its processing is ready, rather than flash the unprocessed page (user, 2026-09-29)
      Widget waiting() => SizedBox(width: size.width, height: size.height,
          child: const Center(child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2))));
      if (widget.prefs.autoLevels && _coloured == null && !_colourFailed) return waiting();
      if (cropping && _cropped == null) return waiting();
      var source = base;
      if (enhance && !_enhanceFailed) {
        final physical = Size((size.width * dpr).roundToDouble(), (size.height * dpr).roundToDouble());
        if (physical.longestSide <= 8192) { // GPU texture limits; beyond that it stays plain
          _enhance(physical, base);
          // until the first picture is ready: wait; after a resize (rotation): the old one, stretched, meanwhile
          if (_enhanced == null) return waiting();
          source = _enhanced!;
        }
      }
      // medium: at rest the enhanced picture is drawn 1:1 (so unchanged); pinch-zoomed it's smoothly magnified
      final raw = RawImage(image: source, width: size.width, height: size.height, fit: BoxFit.fill,
          filterQuality: FilterQuality.medium);
      return tone.isIdentity ? raw : ColorFiltered(colorFilter: ColorFilter.matrix(tone.matrix), child: raw);
    }

    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      switch (widget.prefs.fit) {
        case FitMode.screen:
          final s = aspect > w / h ? Size(w, w / aspect) : Size(h * aspect, h);
          widget.onPageRect?.call(Rect.fromLTWH((w - s.width) / 2, (h - s.height) / 2, s.width, s.height));
          _viewport = Size(w, h);
          _picture = Rect.fromLTWH((w - s.width) / 2, (h - s.height) / 2, s.width, s.height);
          _setPan(false); // was a wide page in fit height: page swipes back on (else they stay off)
          // scaleFactor infinity: the viewer's own wheel zoom off (it zooms on every notch, whoever claims the wheel -
          // wheel up zoomed while turning back). Pinch is unaffected; Ctrl+wheel zooms through _wheel instead.
          return InteractiveViewer(transformationController: _zoom, maxScale: 4, scaleFactor: double.infinity,
              child: _wheel(Center(child: picture(s)), ctrlZooms: true));
        case FitMode.width:
          final s = Size(w, w / aspect);
          // taller than the screen: it fills it (scrolling); else centred with bars above and below
          widget.onPageRect?.call(s.height > h ? Rect.fromLTWH(0, 0, w, h) : Rect.fromLTWH(0, (h - s.height) / 2, w, s.height));
          _placeScroll(s.height > h);
          _setPan(false);
          return s.height <= h
              ? _wheel(Center(child: picture(s)))
              : SingleChildScrollView(controller: widget.scroll, child: _wheel(picture(s)));
        case FitMode.height:
          final s = Size(h * aspect, h);
          final wide = s.width > w;
          widget.onPageRect?.call(wide ? Rect.fromLTWH(0, 0, w, h) : Rect.fromLTWH((w - s.width) / 2, 0, s.width, h));
          _placeScroll(wide);
          _setPan(wide);
          return !wide
              ? _wheel(Center(child: picture(s)))
              : _edgeSwipe(SingleChildScrollView(controller: widget.scroll, scrollDirection: Axis.horizontal,
                  reverse: widget.rtl, child: _wheel(picture(s))));
      }
    });
  }

  /// Claims mouse-wheel events over the page before a scroll view can (it would scroll on its own); the reader
  /// decides whether a notch scrolls the page or turns it. Ctrl+wheel: zooms in fit screen ([ctrlZooms]), else is
  /// left to the scroll view.
  Widget _wheel(Widget child, {bool ctrlZooms = false}) {
    final onWheel = widget.onWheel;
    if (onWheel == null) return child;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerSignal: (e) {
        if (e is! PointerScrollEvent) return;
        if (!HardwareKeyboard.instance.isControlPressed) {
          GestureBinding.instance.pointerSignalResolver
              .register(e, (ev) => onWheel((ev as PointerScrollEvent).scrollDelta.dy));
        } else if (ctrlZooms && e.scrollDelta.dy != 0) {
          GestureBinding.instance.pointerSignalResolver
              .register(e, (ev) => _wheelZoom(ev.localPosition, (ev as PointerScrollEvent).scrollDelta.dy));
        }
      },
      child: child,
    );
  }

  /// Ctrl+wheel zoom (fit screen), about the pointer, between fit (1x) and 4x - the zoom viewer's own rate.
  void _wheelZoom(Offset scenePoint, double dy) {
    final m = _zoom.value;
    final k = m.getMaxScaleOnAxis();
    final target = (k * math.exp(-dy / 200)).clamp(1.0, 4.0);
    if ((target - k).abs() < 1e-6) return;
    if (target <= 1.0 + 1e-6) {
      _zoom.value = Matrix4.identity(); // back to fit
      return;
    }
    final f = target / k;
    final p = MatrixUtils.transformPoint(m, scenePoint); // the pointer on screen stays over the same spot
    _zoom.value = Matrix4.translationValues(p.dx, p.dy, 0)
        .multiplied(Matrix4.diagonal3Values(f, f, 1))
        .multiplied(Matrix4.translationValues(-p.dx, -p.dy, 0))
        .multiplied(m);
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

