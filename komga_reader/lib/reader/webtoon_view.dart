import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../settings.dart' show FitMode;


/// A webtoon read as one continuous vertical strip (user, 2026-10-22 - NOTES, "Webtoon support"): the book's pages,
/// slices of one long strip, stacked edge to edge in a column and scrolled through. On a tall screen the column fills
/// the width - or at its own size: [columnWidth]
/// centred. Each slice keeps its place from Komga's page sizes before it has loaded, so the scroll never jumps.
///
/// The place is the slice across the middle of the screen ([onPlace]); after the last slice, the end card.
class WebtoonView extends StatefulWidget {
  const WebtoonView({super.key, required this.sizes, required this.page, required this.endCard,
      required this.controller, required this.onPlace, required this.background, this.fit = FitMode.original, this.gutter = 0,
      this.onWheel});

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

  /// The column on an [area]: the width, or on a screen wider than tall its height (the width held upright).
  /// The strip's width on an [area]: edge to edge ([fill] - Fit width), or its own size - one picture pixel to a
  /// screen pixel ([imageWidth] at [pixelRatio]), never wider than the screen (user, 2026-10-22: "default should be
  /// to show at native resolution for webtoons"; it was as wide as the screen held upright - blown up 1.5 times on
  /// the tablet). Pictures of no known width: edge to edge.
  /// Fit page height ([FitMode.height]; user, 2026-10-22: "fit 1 page to screen height"): one page - a full slice,
  /// [pageRatio] wide for its height - as tall as the screen.
  static double columnWidth(Size area,
      {required FitMode fit, required double imageWidth, double pageRatio = 0, required double pixelRatio}) {
    if (fit == FitMode.width || imageWidth <= 0) return area.width;
    if (fit == FitMode.height && pageRatio > 0) return math.min(area.width, area.height * pageRatio);
    return math.min(area.width, imageWidth / pixelRatio);
  }

  /// The fit a strip reads in: Fit width, Fit page height, or its own size - Fit screen (comics' default) is its own
  /// size (user, 2026-10-22: "original + edge to edge + fit 1 page to screen height").
  static FitMode fitOf(FitMode f) => f == FitMode.width || f == FitMode.height ? f : FitMode.original;

  @override
  State<WebtoonView> createState() => _WebtoonViewState();
}

/// Where the strip is and what moves it - the renderer's handle on the view ([WebtoonView]).
class WebtoonController {
  WebtoonController(this.start);

  /// The slice to open at (its top at the top of the screen).
  final int start;

  ScrollController? _scroll;
  List<double> _tops = const []; // each slice's top, and the end card's, in the strip
  double _view = 0; // the screen's height

  bool get ready => _scroll?.hasClients ?? false;
  ScrollPosition? get position => ready ? _scroll!.position : null;
  double get viewport => _view;

  /// The top of slice [i] (the end card's: [i] = the slices' count).
  double topOf(int i) => _tops.isEmpty ? 0 : _tops[i.clamp(0, _tops.length - 1)];

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

  bool get atEnd {
    final p = position;
    return p != null && p.pixels >= p.maxScrollExtent - 1;
  }

  bool get atStart {
    final p = position;
    return p == null || p.pixels <= 1;
  }
}

class _WebtoonViewState extends State<WebtoonView> with SingleTickerProviderStateMixin {
  ScrollController? _scroll;
  double _width = 0;
  int _place = -1;

  // a glide, moved here a frame at a time: the list's own animateTo has its pictures ignore the pointer while it runs,
  // so the wheel's next notch went past the reader to the list - half a spun wheel was lost
  late final AnimationController _anim = AnimationController(vsync: this)..addListener(_glideFrame);
  double _from = 0, _to = 0;

  @override
  void dispose() {
    if (identical(widget.controller._state, this)) widget.controller._state = null;
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
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final area = Size(box.maxWidth, box.maxHeight);
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
        final c = widget.controller
          .._tops = tops
          .._view = area.height;
        if (_scroll == null) {
          // opened at the place: its slice's top at the top of the screen
          _scroll = ScrollController(initialScrollOffset: tops[c.start.clamp(0, tops.length - 1)])
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
        c
          .._scroll = _scroll
          .._state = this;
        return Listener(
          onPointerDown: (_) => _stopGlide(),
          child: ColoredBox(
          color: widget.background,
          child: Center(
            child: SizedBox(
              width: width,
              child: ListView.builder(
                controller: _scroll,
                // every slice's height known ahead (Komga's sizes): no jumps as they load
                itemExtentBuilder: (i, _) => i < heights.length ? heights[i] : area.height,
                itemCount: heights.length + 1, // + the end card
                scrollCacheExtent: ScrollCacheExtent.pixels(area.height), // a screen's worth ready either side
                // (each item hears the wheel before the list does: the wheel is the reader's - [onWheel])
                itemBuilder: (context, i) => Listener(
                  onPointerSignal: (e) {
                    final wheel = widget.onWheel;
                    if (wheel != null && e is PointerScrollEvent && !HardwareKeyboard.instance.isControlPressed) {
                      GestureBinding.instance.pointerSignalResolver
                          .register(e, (ev) => wheel((ev as PointerScrollEvent).scrollDelta.dy));
                    }
                  },
                  child: i < heights.length
                      ? Padding(
                          padding: EdgeInsets.only(bottom: i < heights.length - 1 ? gap : 0),
                          child: widget.page(context, i))
                      : OverflowBox(maxWidth: area.width, child: widget.endCard()),
                ),
              ),
            ),
          ),
          ),
        );
      });
}
