import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;


/// A webtoon read as one continuous vertical strip (user, 2026-10-22 - NOTES, "Webtoon support"): the book's pages,
/// slices of one long strip, stacked edge to edge in a column and scrolled through. On a tall screen the column fills
/// the width; on a wider one it's as wide as the strip would be with the screen held upright ([columnWidth]),
/// centred. Each slice keeps its place from Komga's page sizes before it has loaded, so the scroll never jumps.
///
/// The place is the slice across the middle of the screen ([onPlace]); after the last slice, the end card.
class WebtoonView extends StatefulWidget {
  const WebtoonView({super.key, required this.sizes, required this.page, required this.endCard,
      required this.controller, required this.onPlace, required this.background});

  /// Each slice's size (Komga's - width and height in pixels; a slice with none counts as square).
  final List<Size> sizes;

  /// Slice [i]'s picture (loaded).
  final Widget Function(BuildContext context, int i) page;

  final Widget Function() endCard;
  final WebtoonController controller;
  final ValueChanged<int> onPlace;
  final Color background;

  /// The column on an [area]: the width, or on a screen wider than tall its height (the width held upright).
  static double columnWidth(Size area) => math.min(area.width, area.height);

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
    p.jumpTo(topOf(i).clamp(0.0, p.maxScrollExtent));
  }

  double? _target; // where a glide under way is going (a held key's presses add up)

  /// Glides [by] pixels down (up when negative), adding to a glide already under way.
  void glide(double by, {Duration duration = const Duration(milliseconds: 220)}) {
    final p = position;
    if (p == null) return;
    final from = _target != null && p.isScrollingNotifier.value ? _target! : p.pixels;
    final to = (from + by).clamp(0.0, p.maxScrollExtent);
    if ((to - p.pixels).abs() < 0.5) return;
    _target = to;
    _scroll!.animateTo(to, duration: duration, curve: Curves.easeOut).whenComplete(() {
      if (_target == to) _target = null;
    });
  }

  bool get atEnd {
    final p = position;
    return p != null && p.pixels >= p.maxScrollExtent - 1;
  }

  bool get atStart {
    final p = position;
    return p == null || p.pixels <= 1;
  }
}

class _WebtoonViewState extends State<WebtoonView> {
  ScrollController? _scroll;
  double _width = 0;
  int _place = -1;

  @override
  void dispose() {
    _scroll?.dispose();
    super.dispose();
  }

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
        final width = WebtoonView.columnWidth(area);
        final heights = [
          for (final s in widget.sizes) s.width > 0 && s.height > 0 ? s.height * width / s.width : width,
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
        c._scroll = _scroll;
        return ColoredBox(
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
                itemBuilder: (context, i) => i < heights.length
                    ? widget.page(context, i)
                    : OverflowBox(maxWidth: area.width, child: widget.endCard()),
              ),
            ),
          ),
        );
      });
}
