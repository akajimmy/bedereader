import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../page_curl.dart';

/// The 3D page curl turn for a page view - both readers' (eBooks since 2026-10-11; comics, whose own came first, moved
/// onto it 2026-10-22 - user: "move comic reader to the shared code"): a turn jumps the page view to the target page
/// at once and draws the turning page over it from a snapshot - forward, this page curls away over the next; back, the
/// previous page uncurls over this one (a snapshot of this page covers the view until then). A drag moves the page's
/// corner with the pointer; let go before about a third and it springs back. The geometry and the shader are
/// lib/page_curl.dart's.
///
/// The renderer gives: the page view's place ([current]) and a way to [jump] it, and is told when a turn is over
/// ([done]: turned or not). What turns is asked for the view whose page curls - forward, the one on screen; back, the
/// one turned back to - as a spread can change shape from one view to the next (comics): where that page sits on
/// screen ([pageRect]), whether it turns over at a spine onto the page beside it ([spine]) and over what gap ([gap]),
/// and what of the view from before stays put meanwhile ([held]). [mirror]: a right-to-left book - drawn mirrored,
/// drags read in reading direction. [boundary] goes on a RepaintBoundary round the page view (the snapshots);
/// [overlay] over it.
class CurlTurns {
  CurlTurns({required TickerProvider vsync, required this.current, required this.jump, required this.pageRect,
      required this.done, required this.pixelRatio, this.paper, this.spine, this.held, this.gap, this.mirror}) {
    _anim = AnimationController(vsync: vsync, duration: const Duration(milliseconds: 380))
      ..addListener(_tick)
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) _end();
      });
  }

  final int Function() current;
  final void Function(int page) jump;

  /// The curling page on screen, at view [v] (the sheet on a wide screen; two pages up, the later page).
  final Rect Function(int v) pageRect;
  final void Function({required bool turned}) done;
  final double Function() pixelRatio;

  /// The back of the turning page's colour (eBooks: the page's own); white paper when not given (comics).
  final Color Function()? paper;

  /// At view [v], two pages side by side (user, 2026-10-16): the page turns over onto the one beside it, attached at
  /// the spine, and lands flat over it ([PageCurl.spineRadius]) - it doesn't go off past it.
  final bool Function(int v)? spine;

  /// Two pages side by side: the part of the view from before the turn that stays until the turning page lands on it -
  /// forward, the other page; back, the page the previous spread's comes back over (the other side shows that spread
  /// at once, under the page lifting away - user, 2026-10-16). [target]: the view turned to.
  final Rect? Function(bool forward, int target)? held;

  /// At view [v], two pages side by side, apart (the gutter; eBooks' two sheets): the page turns about its middle, so
  /// it lands over the other page, past the gap.
  final double Function(int v)? gap;

  /// A right-to-left book: the curl mirrored, page coordinates and drags in reading direction.
  final bool Function()? mirror;

  bool _spineAt(int v) => spine?.call(v) ?? false;
  double _gapAt(int v) => gap?.call(v) ?? 0;
  bool get _mirror => mirror?.call() ?? false;

  /// Where a turn of a page [width] wide at view [v] ends: off itself, or over the page beside it (past the gap).
  double _goneFor(double width, int v) => _spineAt(v) ? -width - _gapAt(v) : PageCurl.gone(width);

  final boundary = GlobalKey(debugLabel: 'curl-pages');
  late final AnimationController _anim;
  final _moved = ValueNotifier<int>(0);
  ui.FragmentShader? _shader;
  _Curl? _curl;

  /// A turn is on screen (dragged or playing).
  bool get active => _curl != null;

  /// A turn is playing out after the pointer let go: other turns wait for it (one during a spring-back skipped a
  /// page - user, 2026-09-30).
  bool get settling => _curl != null && _anim.isAnimating;

  /// The curl can be drawn here (its shader loaded).
  static bool get available => PageCurl.loaded != null;

  ui.Image? _snapshot() {
    final b = boundary.currentContext?.findRenderObject();
    if (b is! RenderRepaintBoundary || !b.hasSize) return null;
    try {
      return b.toImageSync(pixelRatio: pixelRatio());
    } catch (_) {
      return null;
    }
  }

  /// A whole turn, one page on ([next]) or back, to [target]: false if it couldn't start (the caller then turns
  /// without it).
  bool turn({required bool next, required int target}) {
    if (settling) return true; // (the one playing goes on; this one is dropped)
    final v = next ? current() : target;
    final page = pageRect(v);
    final grab = Offset(page.width, page.height * 0.72);
    if (!_start(next: next, target: target, page: page, grab: grab,
        finger: next ? grab : Offset(_goneFor(page.width, v), grab.dy))) {
      return false;
    }
    _animate(complete: true);
    return true;
  }

  bool _start({required bool next, required int target, required Rect page, required Offset grab,
      required Offset finger}) {
    finishNow();
    final now = _snapshot();
    if (now == null) return false;
    final v = next ? current() : target;
    final keep = held?.call(next, target);
    final c = _Curl(sheet: now, forward: next, page: page, grab: grab, finger: finger, from: current(),
        under: next ? (keep == null ? null : now) : now, underClip: keep, pending: !next, spine: _spineAt(v),
        gap: _gapAt(v));
    // two pages up, the turning page's back is a page (user, 2026-10-16: "the following left-hand page should be
    // shown on the back"): back, this spread's earlier page - the view now; forward, the next spread's, snapshot once
    // the view shows it
    if (c.spine && !next) c.back = now;
    _curl = c;
    jump(target); // (while the turn is set: a renderer can tell this jump from a reader's turn - active)
    _moved.value++;
    if (c.spine && next) _snapBack(c);
    if (!next) {
      // the previous page is now in the view (under the cover): snapshot it to uncurl
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_curl != c || !c.pending) return;
        final prev = _snapshot();
        if (prev == null) {
          _end(cancel: true);
          return;
        }
        c
          ..sheet = prev
          ..pending = false;
        _moved.value++;
      });
    }
    return true;
  }

  /// Two pages up, forward: the next spread is in the view now (under the cover) - snapshot it for the turning page's
  /// back, and again a moment later in case its pictures were still being drawn.
  void _snapBack(_Curl c) {
    void take() {
      if (_curl != c) return;
      final b = _snapshot();
      if (b == null) return;
      final old = c.back;
      c.back = b;
      _moved.value++;
      if (old != null) WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => take());
    c.backTimer = Timer(const Duration(milliseconds: 250), take);
  }

  void _animate({required bool complete}) {
    final c = _curl;
    if (c == null) return;
    final w = c.page.width;
    c
      ..completing = complete
      ..animFrom = c.finger
      ..animTo = c.forward == complete
          ? c.spine
              ? Offset(-w - c.gap, c.grab.dy) // turned over flat onto the page beside it, past the gap
              : Offset(PageCurl.gone(w), c.grab.dy - c.page.height * 0.08) // turned away, corner lifted a little
          : c.grab; // flat on the page
    _anim.forward(from: 0);
  }

  void _tick() {
    final c = _curl;
    if (c == null) return;
    c.finger = Offset.lerp(c.animFrom, c.animTo, Curves.easeOut.transform(_anim.value))!;
    _moved.value++;
  }

  /// The turn is over: let go before it counted -> back to where it started, and nothing counted.
  void _end({bool cancel = false}) {
    final c = _curl;
    if (c == null) return;
    final back = cancel || !c.completing;
    if (back) jump(c.from); // (still active: not a reader's turn)
    _curl = null;
    _moved.value++;
    done(turned: !back);
    WidgetsBinding.instance.addPostFrameCallback((_) => c.dispose());
  }

  /// Another turn, or a jump, while one is playing: that one ends at once.
  void finishNow() {
    if (_curl == null) return;
    _anim.stop();
    _end();
  }

  // ---- dragging: from anywhere on the page; the way to the edge it moves towards is the whole turn

  Offset? _dragStart; // where the pointer went down, on screen
  int _pages = 0;

  /// In reading direction (x from the right edge in a right-to-left book).
  Offset _reading(Offset p, Size area) => _mirror ? Offset(area.width - p.dx, p.dy) : p;

  /// [pages]: how many there are (a drag back from the first, or on from the last, does nothing).
  void dragStart(DragStartDetails d, {required int pages}) {
    finishNow(); // a quick second swipe: the turn still playing ends at once instead of eating this one
    _dragStart = d.localPosition;
    _pages = pages;
  }

  /// A drag can start anywhere: the distance from where it starts to the edge it moves towards is the whole turn (so
  /// from the middle, half the area turns the page fully) - the page doesn't have to be taken by its edge.
  void dragUpdate(DragUpdateDetails d, Size area) {
    final s0 = _dragStart;
    if (s0 == null) return;
    final s = _reading(s0, area), p = _reading(d.localPosition, area);
    if (_curl == null) {
      final dx = p.dx - s.dx;
      if (dx.abs() < 4) return;
      final next = dx < 0;
      final target = current() + (next ? 1 : -1);
      if (target < 0 || target >= _pages) {
        _dragStart = null;
        return;
      }
      final v = next ? current() : target;
      final page = pageRect(v);
      final grab = Offset(page.width, (s0.dy - page.top).clamp(0.0, page.height));
      if (!_start(next: next, target: target, page: page, grab: grab,
          finger: next ? grab : Offset(_goneFor(page.width, v), grab.dy))) {
        _dragStart = null;
        return;
      }
    }
    final c = _curl!;
    if (_anim.isAnimating) return;
    final w = c.page.width, gone = c.spine ? -w - c.gap : PageCurl.gone(w);
    final room = c.forward ? s.dx : area.width - s.dx; // from the start to the edge being dragged towards
    final moved = c.forward ? s.dx - p.dx : p.dx - s.dx;
    final t = (moved / math.max(room, 40.0)).clamp(0.0, 1.0);
    // the grabbed point follows the pointer up and down as well (user, 2026-10-22: "grab the top right corner of the
    // page and drag it down left"; it went half the way) - PageCurl.pinned keeps the spine down
    final y = c.grab.dy + (p.dy - s.dy);
    c.finger = c.forward ? Offset(w + (gone - w) * t, y) : Offset(gone + (w - gone) * t, y);
    _moved.value++;
  }

  void dragEnd(DragEndDetails d) {
    final c = _curl;
    _dragStart = null;
    if (c == null || _anim.isAnimating) return;
    final w = c.page.width, gone = c.spine ? -w - c.gap : PageCurl.gone(w);
    var vx = d.velocity.pixelsPerSecond.dx;
    if (_mirror) vx = -vx;
    final turned = (w - c.finger.dx) / (w - gone); // 0 = flat on this page, 1 = turned away
    // a flick (diagonal ones carry less sideways speed) or a slow drag about a third of the way
    final complete = c.forward ? vx < -250 || (vx < 250 && turned > 0.3) : vx > 250 || (vx > -250 && turned < 0.7);
    _animate(complete: complete);
  }

  /// The turning page, over the page view (nothing when no turn is on) - rebuilt as it moves, the reader isn't.
  Widget overlay() => ValueListenableBuilder<int>(
        valueListenable: _moved,
        builder: (_, __, ___) {
          final c = _curl;
          if (c == null) return const SizedBox.shrink();
          return IgnorePointer(
            child: Stack(fit: StackFit.expand, children: [
              if (c.under != null)
                c.underClip == null
                    ? RawImage(image: c.under, fit: BoxFit.fill)
                    : ClipRect(clipper: _RectClip(c.underClip!), child: RawImage(image: c.under, fit: BoxFit.fill)),
              if (!c.pending)
                CustomPaint(painter: _CurlPaint(program: PageCurl.loaded!, sheet: c.sheet, page: c.page,
                    grab: c.grab, finger: c.finger, mirror: _mirror, spine: c.spine, back: c.back,
                    gap: c.spine ? c.gap : 0, held: c.underClip,
                    paper: paper?.call() ?? PageCurlPainter.whitePaper,
                    shader: _shader ??= PageCurl.loaded!.fragmentShader())),
            ]),
          );
        },
      );

  void dispose() {
    _anim.dispose();
    _curl?.dispose();
    _curl = null;
    _shader?.dispose();
    _moved.dispose();
  }
}

/// What a test can see of the curl being drawn.
@visibleForTesting
abstract interface class CurlLayer {
  bool get mirror;

  /// The page curling (two pages up: a pair's later page).
  Rect get page;

  /// What of the view from before the turn stays over it meanwhile (two pages up, forward: the earlier page's
  /// picture); null: none, or all of it.
  Rect? get held;

  /// The page on the curling one's back (two pages up: a snapshot of the view holding it), and the curling page's own
  /// snapshot; [back] null: paper.
  ui.Image? get back;
  ui.Image get sheet;

  /// Where the grabbed edge is now (page coordinates, reading direction).
  Offset get finger;

  /// Turning over onto the page beside it, attached at the spine.
  bool get spine;
}

/// The curl's painter, with what stays put under it ([held]) for a test to see.
class _CurlPaint extends PageCurlPainter implements CurlLayer {
  _CurlPaint({required super.program, required super.sheet, required super.page, required super.grab,
      required super.finger, required super.mirror, super.shader, super.paper, super.spine, super.back, super.gap,
      this.held});
  @override
  final Rect? held;
}

/// Clips to a fixed rectangle.
class _RectClip extends CustomClipper<Rect> {
  _RectClip(this.rect);
  final Rect rect;
  @override
  Rect getClip(Size size) => rect;
  @override
  bool shouldReclip(_RectClip old) => old.rect != rect;
}

/// A page turn in progress.
class _Curl {
  _Curl({required this.sheet, required this.forward, required this.page, required this.grab, required this.finger,
      required this.from, this.under, this.underClip, this.pending = false, this.spine = false, this.gap = 0});
  ui.Image sheet; // the page that curls: this one going forward; the previous one coming back
  final ui.Image? under; // going back: this page, covering the view until the previous one has uncurled
  final Rect? underClip; // only this part of [under] (two pages up, forward: the other page's side)
  final bool spine; // two pages up: turns over onto the page beside it, attached at the spine
  final double gap; // two pages up: the gap it turns over (on screen)
  final bool forward;
  final Rect page; // the curling page on screen
  final Offset grab; // where the page was taken hold of (its right edge, page coordinates in reading direction)
  Offset finger; // where that point is now
  final int from; // the page before the turn, to go back to if it's let go
  bool pending; // going back: the previous page's snapshot isn't taken yet
  ui.Image? back; // two pages up: the view holding the page on the turning one's back (null: paper, for now)
  Timer? backTimer; // its second snapshot
  bool completing = true;
  Offset animFrom = Offset.zero, animTo = Offset.zero;

  void dispose() {
    backTimer?.cancel();
    sheet.dispose();
    if (under != null && !identical(under, sheet)) under!.dispose();
    if (back != null && !identical(back, sheet) && !identical(back, under)) back!.dispose();
  }
}
