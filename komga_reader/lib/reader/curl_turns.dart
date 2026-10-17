import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../page_curl.dart';

/// The 3D page curl turn for a page view (eBooks, user 2026-10-11 - the comic reader has its own, the first one): a
/// turn jumps the page view to the target page at once and draws the turning page over it from a snapshot - forward,
/// this page curls away over the next; back, the previous page uncurls over this one (a snapshot of this page covers
/// the view until then). A drag moves the page's corner with the finger; let go before about a third and it springs
/// back. The geometry and the shader are lib/page_curl.dart's, as the comics'.
///
/// The renderer gives: the page view's place ([current]) and a way to [jump] it, where the page sits on screen
/// ([pageRect] - the sheet on a wide screen), and is told when a turn is over ([done]: turned or not). [boundary]
/// goes on a RepaintBoundary round the page view (the snapshots); [overlay] over it.
class CurlTurns {
  CurlTurns({required TickerProvider vsync, required this.current, required this.jump, required this.pageRect,
      required this.done, required this.pixelRatio, this.paper, this.spine, this.held, this.gap}) {
    _anim = AnimationController(vsync: vsync, duration: const Duration(milliseconds: 380))
      ..addListener(_tick)
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) _end();
      });
  }

  final int Function() current;
  final void Function(int page) jump;
  final Rect Function() pageRect;
  final void Function({required bool turned}) done;
  final double Function() pixelRatio;

  /// The back of the turning page's colour (the page's own); white paper when not given.
  final Color Function()? paper;

  /// Two pages side by side (user, 2026-10-16): the page turns over onto the one beside it, attached at the spine,
  /// and lands flat over it ([PageCurl.spineRadius]) - it doesn't go off past it.
  final bool Function()? spine;

  /// Two pages side by side: the part of the view from before the turn that stays until the turning page lands on it -
  /// forward, the other page; back ([forward] false), the page the previous spread's comes back over (the other side
  /// shows that spread at once, under the page lifting away - user, 2026-10-16).
  final Rect? Function(bool forward)? held;

  /// Two pages side by side as two sheets (Inset page): the gap between them - the page turns about its middle, so
  /// it lands over the other sheet (user, 2026-10-16: "two discrete pages, with a gap between").
  final double Function()? gap;

  bool get _spine => spine?.call() ?? false;

  /// Where a turn of a page [width] wide ends: off itself, or over the page beside it (past the gap between).
  double _goneFor(double width, bool spine) => spine ? -width - (gap?.call() ?? 0) : PageCurl.gone(width);

  final boundary = GlobalKey(debugLabel: 'curl-pages');
  late final AnimationController _anim;
  final _moved = ValueNotifier<int>(0);
  ui.FragmentShader? _shader;
  _Curl? _curl;

  /// A turn is on screen (dragged or playing).
  bool get active => _curl != null;

  /// A turn is playing out after the finger let go: other turns wait for it.
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

  /// A whole turn, one page on ([next]) or back to [target]: false if it couldn't start (the caller then turns
  /// without it).
  bool turn({required bool next, required int target}) {
    if (settling) return true; // (the one playing goes on; this one is dropped, as the comics')
    final page = pageRect();
    final grab = Offset(page.width, page.height * 0.72);
    if (!_start(next: next, target: target, page: page, grab: grab,
        finger: next ? grab : Offset(_goneFor(page.width, _spine), grab.dy))) {
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
    final keep = held?.call(next);
    final c = _Curl(sheet: now, forward: next, page: page, grab: grab, finger: finger, from: current(),
        under: next ? (keep == null ? null : now) : now, underClip: keep, pending: !next, spine: _spine);
    // two pages up, the turning page's back is a page (user, 2026-10-16: "the following left-hand page should be
    // shown on the back"): back, this spread's earlier page - the view now; forward, the next spread's, snapshot once
    // the view shows it
    if (c.spine && !next) c.back = now;
    _curl = c;
    jump(target);
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
  /// back, and again a moment later in case it was still being drawn.
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
              ? Offset(_goneFor(w, true), c.grab.dy) // turned over flat onto the page beside it
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

  /// The turn is over: let go before it counted -> back to where it started.
  void _end({bool cancel = false}) {
    final c = _curl;
    if (c == null) return;
    final back = cancel || !c.completing;
    if (back) jump(c.from);
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

  Offset? _dragStart;
  int _pages = 0;

  /// [pages]: how many there are (a drag back from the first, or on from the last, does nothing).
  void dragStart(DragStartDetails d, {required int pages}) {
    finishNow(); // a quick second swipe: the turn still playing ends at once
    _dragStart = d.localPosition;
    _pages = pages;
  }

  void dragUpdate(DragUpdateDetails d, Size area) {
    final s = _dragStart;
    if (s == null) return;
    final p = d.localPosition;
    if (_curl == null) {
      final dx = p.dx - s.dx;
      if (dx.abs() < 4) return;
      final next = dx < 0;
      final target = current() + (next ? 1 : -1);
      final page = pageRect();
      if (target < 0 || target >= _pages) {
        _dragStart = null;
        return;
      }
      final grab = Offset(page.width, (s.dy - page.top).clamp(0.0, page.height));
      if (!_start(next: next, target: target, page: page, grab: grab,
          finger: next ? grab : Offset(_goneFor(page.width, _spine), grab.dy))) {
        _dragStart = null;
        return;
      }
    }
    final c = _curl!;
    if (_anim.isAnimating) return;
    final w = c.page.width, gone = _goneFor(w, c.spine);
    final room = c.forward ? s.dx : area.width - s.dx;
    final moved = c.forward ? s.dx - p.dx : p.dx - s.dx;
    final t = (moved / math.max(room, 40.0)).clamp(0.0, 1.0);
    final y = c.grab.dy + (p.dy - s.dy) * 0.5; // a diagonal drag tilts the page by half its height change
    c.finger = c.forward ? Offset(w + (gone - w) * t, y) : Offset(gone + (w - gone) * t, y);
    _moved.value++;
  }

  void dragEnd(DragEndDetails d) {
    final c = _curl;
    _dragStart = null;
    if (c == null || _anim.isAnimating) return;
    final w = c.page.width, gone = _goneFor(w, c.spine);
    final vx = d.velocity.pixelsPerSecond.dx;
    final turned = (w - c.finger.dx) / (w - gone); // 0 = flat on this page, 1 = turned away
    final complete = c.forward ? vx < -250 || (vx < 250 && turned > 0.3) : vx > 250 || (vx > -250 && turned < 0.7);
    _animate(complete: complete);
  }

  /// The turning page, over the page view (nothing when no turn is on).
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
                CustomPaint(painter: PageCurlPainter(program: PageCurl.loaded!, sheet: c.sheet, page: c.page,
                    grab: c.grab, finger: c.finger, mirror: false, spine: c.spine, back: c.back,
                    gap: c.spine ? gap?.call() ?? 0 : 0,
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
      required this.from, this.under, this.underClip, this.pending = false, this.spine = false});
  ui.Image sheet; // the page that curls: this one going forward; the previous one coming back
  final ui.Image? under; // going back: this page, covering the view until the previous one has uncurled
  final Rect? underClip; // only this part of [under] (two pages up, forward: the other page's side)
  final bool spine; // two pages up: turns over onto the page beside it, attached at the spine
  final bool forward;
  final Rect page; // the curling page on screen
  final Offset grab; // where the page was taken hold of (its right edge, page coordinates)
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
