import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/scheduler.dart' show Ticker;

import '../page_image.dart' show PageCanvas;
import '../settings.dart' show FitMode;


/// A webtoon read as one continuous vertical strip (user, 2026-10-22 - NOTES, "Webtoon support"): the book's pages,
/// slices of one long strip, stacked in a column (a [gutter] between them) and scrolled through, at the width its fit
/// gives ([columnWidth]), centred. Each slice keeps its place from Komga's page sizes before it has loaded, so the
/// scroll never jumps. Two fingers zoom it (Ctrl + the wheel, the zoom keys - [WebtoonController.zoomBy]).
///
/// The place is the slice across the middle of the screen ([onPlace]); after the last slice, the end card. Where in
/// that slice the screen is ([onSettled]) is kept, to open there again ([WebtoonController.startShare]).
class WebtoonView extends StatefulWidget {
  const WebtoonView({super.key, required this.sizes, required this.page, required this.endCard,
      required this.controller, required this.onPlace, required this.background, this.fit = FitMode.original,
      this.gutter = 0, this.onWheel, this.onSettled});

  /// Each slice's size (Komga's - width and height in pixels; a slice with none counts as square).
  final List<Size> sizes;

  /// Slice [i]'s picture (loaded).
  final Widget Function(BuildContext context, int i) page;

  final Widget Function() endCard;
  final WebtoonController controller;
  final ValueChanged<int> onPlace;
  final Color background;

  /// How wide the strip is: its own size, Fit width (edge to edge) or Fit page height ([columnWidth]).
  final FitMode fit;

  /// The space between one picture and the next, points - the page colours showing through, as a page break (user,
  /// 2026-10-22: "a vertical gutter between images, like page breaks"). None after the last.
  final double gutter;

  /// The mouse wheel over the strip: the reader's to scroll by (Smooth or Page) - not the list's own scrolling, which
  /// heard it first and moved by the wheel's distance in both modes (user, 2026-10-22: Page "feels very similar to
  /// smooth scroll").
  final ValueChanged<double>? onWheel;

  /// The strip came to rest: the slice across the middle, and how far into it the top of the screen is - a share of
  /// that slice's height (negative: above it) - to open at exactly there again (user, 2026-10-22: "1 ... for sure" -
  /// a page number alone opened up to a screen and a half off).
  final void Function(int slice, double share)? onSettled;

  /// The strip's width on an [area]: edge to edge (Fit width), its own size - one picture pixel to a screen pixel
  /// ([imageWidth] at [pixelRatio]), never wider than the screen (user, 2026-10-22: "default should be to show at
  /// native resolution for webtoons") - or Fit page height ([FitMode.height]; "fit 1 page to screen height"): one
  /// page - a full slice, [pageRatio] wide for its height - as tall as the screen. Pictures of no known width: edge to
  /// edge.
  static double columnWidth(Size area,
      {required FitMode fit, required double imageWidth, double pageRatio = 0, required double pixelRatio}) {
    if (fit == FitMode.width || imageWidth <= 0) return area.width;
    if (fit == FitMode.height && pageRatio > 0) return math.min(area.width, area.height * pageRatio);
    return math.min(area.width, imageWidth / pixelRatio);
  }

  /// The fit a strip reads in: Fit width, Fit page height, or its own size - Fit screen (comics' default) is its own
  /// size (user, 2026-10-22: "original + edge to edge + fit 1 page to screen height").
  static FitMode fitOf(FitMode f) => f == FitMode.width || f == FitMode.height ? f : FitMode.original;

  /// How far the strip zooms in (user, 2026-10-22: pinch to zoom, "for sure").
  static const maxZoom = 4.0;

  @override
  State<WebtoonView> createState() => _WebtoonViewState();
}

/// Where the strip is and what moves it - the renderer's handle on the view ([WebtoonView]).
class WebtoonController {
  WebtoonController(this.start, {this.startShare = 0});

  /// The slice to open at, and how far into it the top of the screen is (a share of its height; 0: its top).
  final int start;
  final double startShare;

  ScrollController? _scroll;
  List<double> _tops = const []; // each slice's top, and the end card's, in the strip
  double _view = 0; // the height the screen shows of the strip (zoomed in: less)

  bool get ready => _scroll?.hasClients ?? false;
  ScrollPosition? get position => ready ? _scroll!.position : null;
  double get viewport => _view;

  /// The top of slice [i] (the end card's: [i] = the slices' count).
  double topOf(int i) => _tops.isEmpty ? 0 : _tops[i.clamp(0, _tops.length - 1)];

  /// Slice [i]'s height in the strip (its gutter included).
  double heightOf(int i) => i < 0 || i + 1 >= _tops.length ? 0 : _tops[i + 1] - _tops[i];

  /// The slice across [y] (a point in the strip).
  int sliceAt(double y) {
    if (_tops.length < 2) return 0;
    var lo = 0, hi = _tops.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (_tops[mid] <= y) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// Straight to slice [i] (the slider, the strip, another device's place).
  void jumpTo(int i) {
    final p = position;
    if (p == null) return;
    _state?._stopGlide();
    p.jumpTo(topOf(i).clamp(0.0, p.maxScrollExtent));
  }

  _WebtoonViewState? _state;

  /// Glides [by] pixels down (up when negative), on from where a glide under way is going (a held key's presses, a
  /// spun wheel's notches add up).
  void glide(double by, {Duration duration = const Duration(milliseconds: 220)}) =>
      _state?._glide(by, duration);

  /// A glide under way.
  bool get gliding => _state?._anim.isAnimating ?? false;

  /// Zooms in ([factor] over 1) or out, about the middle of the screen - the zoom keys, Ctrl + the wheel.
  void zoomBy(double factor) => _state?._zoomBy(factor);

  /// How far it's zoomed in (1: not).
  double get zoom => _state?._zoom ?? 1;

  /// A double tap at [local] (in the view): zoomed in about it, as a comic's page is ([PageCanvas.doubleTapScale]) -
  /// or, zoomed in, back out.
  void toggleZoomAt(Offset local) =>
      _state?._zoomTo(zoom > 1.01 ? 1 : PageCanvas.doubleTapScale, local);

  // ---- auto-scroll (user, 2026-10-22: "sounds kinda neat")

  /// Auto-scroll's speed, screen points a second (zoomed in, the strip moves past as fast on the screen).
  double autoSpeed = 60;

  /// Auto-scroll stopped by itself: a touch on the strip, or the end reached.
  VoidCallback? onAutoStopped;

  /// The strip scrolling down by itself.
  bool get autoOn => _state?._auto.isActive ?? false;

  void startAuto() => _state?._startAuto();

  /// The last touch on the strip stopped auto-scroll (the tap it ends in brings the controls and play).
  bool get touchStoppedAuto => _downStopped;
  bool _downStopped = false;
  void stopAuto() => _state?._stopAuto(tell: false);

  bool get atEnd {
    final p = position;
    return p != null && p.pixels >= p.maxScrollExtent - 1;
  }

  bool get atStart {
    final p = position;
    return p == null || p.pixels <= 1;
  }
}

class _WebtoonViewState extends State<WebtoonView> with TickerProviderStateMixin {
  ScrollController? _scroll;
  double _width = 0;
  int _place = -1;
  Size _area = Size.zero;

  // a glide, moved here a frame at a time: the list's own animateTo has its pictures ignore the pointer while it runs,
  // so the wheel's next notch went past the reader to the list - half a spun wheel was lost
  late final AnimationController _anim = AnimationController(vsync: this)..addListener(_glideFrame);
  double _from = 0, _to = 0;

  // zoom: the strip [_zoom] times bigger, [_panX] across from centred (a finger, zoomed in, moves it sideways)
  double _zoom = 1, _panX = 0;
  final Map<int, Offset> _fingers = {}; // fingers on the strip (two: a pinch)
  double? _pinchFrom; // the fingers' distance as the pinch began
  double _zoomFrom = 1;

  Timer? _settle; // the place kept a moment after the strip stops

  // auto-scroll: a frame at a time, as far as the speed says for the time since the last
  late final Ticker _auto = createTicker(_autoTick);
  Duration _autoLast = Duration.zero;

  void _startAuto() {
    _stopGlide();
    if (_auto.isActive) return;
    _autoLast = Duration.zero;
    _auto.start();
  }

  void _stopAuto({bool tell = true}) {
    if (!_auto.isActive) return;
    _auto.stop();
    if (tell) widget.controller.onAutoStopped?.call();
  }

  void _autoTick(Duration elapsed) {
    final s = _scroll;
    final dt = (elapsed - _autoLast).inMicroseconds / 1e6;
    _autoLast = elapsed;
    if (s == null || !s.hasClients) return;
    final p = s.position;
    final to = p.pixels + widget.controller.autoSpeed * dt / _zoom;
    s.jumpTo(math.min(to, p.maxScrollExtent));
    if (to >= p.maxScrollExtent) _stopAuto(); // the end card: it stops there
  }

  @override
  void dispose() {
    if (identical(widget.controller._state, this)) widget.controller._state = null;
    _settled(); // (closed mid-way: where it was)
    _settle?.cancel();
    _auto.dispose();
    _anim.dispose();
    _scroll?.dispose();
    super.dispose();
  }

  void _glide(double by, Duration duration) {
    final s = _scroll;
    if (s == null || !s.hasClients) return;
    final p = s.position;
    final from = _anim.isAnimating ? _to : p.pixels;
    final to = (from + by).clamp(0.0, p.maxScrollExtent);
    if ((to - p.pixels).abs() < 0.5) return;
    _from = p.pixels;
    _to = to;
    _anim.duration = duration;
    _anim.forward(from: 0);
  }

  void _glideFrame() {
    final s = _scroll;
    if (s == null || !s.hasClients) return;
    s.jumpTo(_from + (_to - _from) * Curves.easeOut.transform(_anim.value));
  }

  /// A finger, a mouse button or a jump takes the strip: no glide goes on under it.
  void _stopGlide() => _anim.stop();

  void _onScroll() {
    final s = _scroll!;
    if (!s.hasClients) return;
    final c = widget.controller;
    final i = c.sliceAt(s.position.pixels + s.position.viewportDimension / 2);
    if (i != _place) {
      _place = i;
      widget.onPlace(i);
    }
    _settle?.cancel();
    _settle = Timer(const Duration(milliseconds: 400), _settled);
  }

  /// Where the strip is: the slice across the middle, and the top of the screen as a share of it.
  void _settled() {
    final s = _scroll, done = widget.onSettled;
    if (s == null || !s.hasClients || done == null) return;
    final c = widget.controller, p = s.position;
    final i = c.sliceAt(p.pixels + p.viewportDimension / 2);
    final h = c.heightOf(i);
    if (h <= 0) return; // (the end card)
    done(i, (p.pixels - c.topOf(i)) / h);
  }

  // ---- zoom

  /// Sets the zoom to [z] keeping the strip's point under [focus] (on the screen) where it is.
  void _zoomTo(double z, Offset focus) {
    final s = _scroll;
    z = z.clamp(1.0, WebtoonView.maxZoom);
    if (s == null || !s.hasClients || z == _zoom) return;
    final old = _zoom, left = _left(old);
    // down the strip: the point under the focus stays (the list's offset is in the strip's own points)
    final y = s.position.pixels + focus.dy / old;
    // across: the same
    final x = (focus.dx - left) / old;
    setState(() {
      _zoom = z;
      _panX = 0;
      _panX = _clampPan(focus.dx - x * z - _left(z));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && s.hasClients) s.jumpTo((y - focus.dy / z).clamp(0.0, s.position.maxScrollExtent));
    });
  }

  void _zoomBy(double factor) => _zoomTo(_zoom * factor, _area.center(Offset.zero));

  /// The strip's left edge on the screen at zoom [z] (centred, then panned).
  double _left(double z) => (_area.width - _width * z) / 2 + _panX;

  /// [pan] kept so the zoomed strip covers the screen's width where it's wider (centred where it isn't).
  double _clampPan(double pan) {
    final spare = (_width * _zoom - _area.width) / 2;
    return spare <= 0 ? 0 : pan.clamp(-spare, spare);
  }

  void _onDown(PointerDownEvent e) {
    _stopGlide();
    widget.controller._downStopped = _auto.isActive;
    _stopAuto(); // any touch stops auto-scroll (user, 2026-10-22)
    if (e.kind == PointerDeviceKind.mouse) return;
    _fingers[e.pointer] = e.localPosition;
    if (_fingers.length == 2) {
      final f = _fingers.values.toList();
      _pinchFrom = (f[0] - f[1]).distance;
      _zoomFrom = _zoom;
      setState(() {}); // (the list stops following the fingers - below)
    }
  }

  void _onMove(PointerMoveEvent e) {
    if (!_fingers.containsKey(e.pointer)) return;
    final before = _fingers[e.pointer]!;
    _fingers[e.pointer] = e.localPosition;
    final from = _pinchFrom;
    if (_fingers.length >= 2 && from != null && from > 0) {
      final f = _fingers.values.toList();
      _zoomTo(_zoomFrom * (f[0] - f[1]).distance / from, (f[0] + f[1]) / 2);
    } else if (_fingers.length == 1 && _zoom > 1) {
      // zoomed in, one finger: sideways moves the strip across (down the strip is the list's)
      final pan = _clampPan(_panX + e.localPosition.dx - before.dx);
      if (pan != _panX) setState(() => _panX = pan);
    }
  }

  void _onUp(PointerEvent e) {
    if (_fingers.remove(e.pointer) == null) return;
    if (_fingers.length < 2 && _pinchFrom != null) setState(() => _pinchFrom = null);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final area = Size(box.maxWidth, box.maxHeight);
        _area = area;
        // (a full page: the tallest - the last slice is often short)
        final tallest = widget.sizes.fold(Size.zero, (t, s) => s.height > t.height ? s : t);
        final width = WebtoonView.columnWidth(area,
            fit: widget.fit,
            imageWidth: widget.sizes.fold(0.0, (w, s) => math.max(w, s.width)),
            pageRatio: tallest.height > 0 ? tallest.width / tallest.height : 0,
            pixelRatio: MediaQuery.devicePixelRatioOf(context));
        final gap = widget.gutter;
        // each slice's place: its picture and, but for the last, the gutter under it
        final heights = [
          for (final (i, s) in widget.sizes.indexed)
            (s.width > 0 && s.height > 0 ? s.height * width / s.width : width) +
                (i < widget.sizes.length - 1 ? gap : 0),
        ];
        final tops = <double>[0];
        for (final h in heights) {
          tops.add(tops.last + h);
        }
        final view = area.height / _zoom; // (zoomed in, the screen shows less of the strip)
        final c = widget.controller
          .._tops = tops
          .._view = view;
        if (_scroll == null) {
          // opened at the place: as far into its slice as when it was left (else its top) at the top of the screen
          final start = c.start.clamp(0, tops.length - 1);
          final h = start + 1 < tops.length ? tops[start + 1] - tops[start] : 0.0;
          _scroll = ScrollController(initialScrollOffset: math.max(0, tops[start] + c.startShare * h))
            ..addListener(_onScroll);
          _place = c.start;
        } else if (width != _width && _scroll!.hasClients && _width > 0) {
          // a new width (turned, a window resized): the same point of the same slice at the top
          final old = _scroll!.position.pixels;
          final scale = width / _width;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _scroll!.hasClients) _scroll!.jumpTo(old * scale);
          });
        }
        _width = width;
        _panX = _clampPan(_panX);
        c
          .._scroll = _scroll
          .._state = this;
        final list = ListView.builder(
          controller: _scroll,
          // two fingers on it: a pinch, not a scroll
          physics: _pinchFrom != null ? const NeverScrollableScrollPhysics() : null,
          // every slice's height known ahead (Komga's sizes): no jumps as they load
          itemExtentBuilder: (i, _) => i < heights.length ? heights[i] : area.height,
          itemCount: heights.length + 1, // + the end card
          scrollCacheExtent: ScrollCacheExtent.pixels(area.height), // a screen's worth ready either side
          // (each item hears the wheel before the list does: the wheel is the reader's - [onWheel]; with Ctrl, a zoom)
          itemBuilder: (context, i) => Listener(
            onPointerSignal: (e) {
              if (e is! PointerScrollEvent) return;
              if (HardwareKeyboard.instance.isControlPressed) {
                GestureBinding.instance.pointerSignalResolver.register(e, (ev) {
                  final dy = (ev as PointerScrollEvent).scrollDelta.dy;
                  final at = _localOf(ev.position); // (the pointer, on the screen)
                  _zoomTo(_zoom * (dy < 0 ? 1.15 : 1 / 1.15), at);
                });
                return;
              }
              final wheel = widget.onWheel;
              if (wheel != null) {
                GestureBinding.instance.pointerSignalResolver
                    .register(e, (ev) => wheel((ev as PointerScrollEvent).scrollDelta.dy));
              }
            },
            child: i < heights.length
                ? Padding(
                    padding: EdgeInsets.only(bottom: i < heights.length - 1 ? gap : 0),
                    child: widget.page(context, i))
                : OverflowBox(maxWidth: area.width / _zoom, child: widget.endCard()),
          ),
        );
        return Listener(
          onPointerDown: _onDown,
          onPointerMove: _onMove,
          onPointerUp: _onUp,
          onPointerCancel: _onUp,
          child: ColoredBox(
            color: widget.background,
            child: ClipRect(
              child: Stack(children: [
                // the column, [_zoom] times bigger from its top-left corner, placed centred (then panned)
                Positioned(
                  left: _left(_zoom),
                  top: 0,
                  width: width,
                  height: view,
                  child: Transform.scale(scale: _zoom, alignment: Alignment.topLeft, child: list),
                ),
              ]),
            ),
          ),
        );
      });

  /// [global] (the screen) in this view's own terms.
  Offset _localOf(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    return box == null ? global : box.globalToLocal(global);
  }
}
