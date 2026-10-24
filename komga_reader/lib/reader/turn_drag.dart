import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// How a page turn is told from a drag, the same in both readers, for touch, mouse and pen, in every page-turn mode
/// (user, 2026-10-22: "don't fix these as individual cases but consider what they mean for how page turns should be
/// captured" - a mouse couldn't curl a comic page at all, a steep diagonal lost to the page's zoom, a corner couldn't
/// be taken hold of).
///
/// The reader decides, not whichever of the page's own gestures claims the pointer first: this sits over the page
/// (its gestures hear a pointer before the page's - the zoom, the text selection, a page's scrolling) and, with one
/// pointer down and the page able to turn ([canTurn] at the press: not zoomed, nothing selected...), takes a drag
/// that has moved a few pixels with a sideways part - up to [maxAngle] degrees from horizontal (a page that scrolls
/// up and down keeps the steeper ones). Anything else it leaves to the page: a steeper drag, a second finger (a
/// pinch), and a pointer held still for [hold] before it moves - the eBooks' "hold to select" (user, 2026-10-22).
///
/// Not a sloppy tap (user, 2026-10-22: "make sure ... it [doesn't count] a sloppy tap that moves a few pixels as a
/// full drag"): a finger is taken only past the taps' own slop (18 px - until then it's a tap); a mouse is taken at
/// its first couple of pixels (the zoom's pan claims a mouse at two) but turns only from 12 px - let go before, it's
/// a click after all ([onTap]); and a turn that travelled less than 32 px is no flick - it turns only if dragged far
/// enough. A mouse drag steeper than [maxAngle] does nothing.
class TurnDragRecognizer extends OneSequenceGestureRecognizer {
  TurnDragRecognizer({super.debugOwner});

  /// At the press: may this drag turn the page at all.
  bool Function() canTurn = () => true;

  /// The steepest drag that still turns, in degrees from horizontal.
  double Function() maxAngle = () => 60;

  /// Held still this long, the pointer is the page's (a long press, a selection). Null: a page with nothing to do on a
  /// hold (comics) - a finger held before it moves still turns (user, 2026-10-24: a curl held a moment first "doesn't
  /// seem to register most of the time").
  Duration? hold = kLongPressTimeout;

  /// The turn: [onStart] from where the pointer went down, [onUpdate] as it moves (delta and primaryDelta: the
  /// horizontal part), [onEnd] with its velocity (primaryVelocity: horizontal); [onCancel] when a second pointer
  /// lands mid-turn.
  GestureDragStartCallback? onStart;
  GestureDragUpdateCallback? onUpdate;
  GestureDragEndCallback? onEnd;
  VoidCallback? onCancel;

  /// A mouse taken for a drag (so the page's own tap lost it) but let go before it turned: the click it was.
  GestureTapUpCallback? onTap;

  /// A mouse held for [hold] with no more than [holdSlop] of drift - a hand on a mouse is never quite still, and the
  /// first two pixels made it a drag here, so the page never saw a hold (user, 2026-10-22: "Allow drift during hold"):
  /// the hold is this recognizer's to report, as it has the pointer. [onHoldStart] where the button went down,
  /// [onHoldUpdate] as it moves on, [onHoldEnd] at the release. Unset: a held mouse is as any other (comics).
  ValueChanged<Offset>? onHoldStart, onHoldUpdate;
  VoidCallback? onHoldEnd;
  static const holdSlop = 8.0;

  // a finger: at the taps' own slop - a tap until then (and under the zoom's 36; level with a scroll's 18, but heard
  // first)
  static const _touchSlop = kTouchSlop;
  static const _mouseSlop = 2.0; // the zoom's pan claims a mouse at 2 px
  static const _judgeAt = 12.0; // a mouse: a turn from here (its direction judged); let go before, a click
  static const _flickAtLeast = 32.0; // a shorter turn has no flick: only how far it was dragged counts

  int? _pointer;
  Offset _downGlobal = Offset.zero, _downLocal = Offset.zero, _lastGlobal = Offset.zero;
  PointerDeviceKind _kind = PointerDeviceKind.touch;
  bool _accepted = false; // won the arena
  bool _turning = false; // [onStart] called: a turn under way
  bool _dud = false; // a mouse drag taken but too steep: does nothing
  bool _holding = false; // a mouse held (with its drift): [onHoldUpdate] from here
  VelocityTracker? _velocity;
  Timer? _holdTimer;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (_pointer != null) {
      // a second pointer: a pinch - the page's
      if (_turning) onCancel?.call();
      _giveUp();
      return;
    }
    if (!canTurn()) return;
    super.addAllowedPointer(event);
    _pointer = event.pointer;
    _kind = event.kind;
    _downGlobal = _lastGlobal = _lastAt = event.position;
    _downLocal = event.localPosition;
    _accepted = _turning = _dud = _holding = false;
    _velocity = VelocityTracker.withKind(event.kind)..addPosition(event.timeStamp, event.position);
    final hold = this.hold;
    if (hold == null) return;
    _holdTimer = Timer(hold, () {
      if (!_accepted) {
        _giveUp(); // held: a long press, a selection
      } else if (!_turning && !_dud && onHoldStart != null && (_lastAt - _downGlobal).distance <= holdSlop) {
        // a mouse taken by its drift, but held: the hold it was
        _holding = true;
        onHoldStart!(_downGlobal);
        onHoldUpdate?.call(_lastAt);
      }
    });
  }

  Offset _lastAt = Offset.zero; // where the pointer is now

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) return;
    if (event is PointerMoveEvent) {
      _velocity?.addPosition(event.timeStamp, event.position);
      _lastAt = event.position;
      if (_holding) {
        onHoldUpdate?.call(event.position);
        return;
      }
      final moved = event.position - _downGlobal;
      final mouse = _kind == PointerDeviceKind.mouse;
      if (!_accepted) {
        if (moved.distance < (mouse ? _mouseSlop : _touchSlop)) return;
        if (!mouse && !_sideways(moved)) {
          _giveUp(); // steeper: a scroll, the page's
          return;
        }
        _accepted = true;
        // (a mouse's hold is still to be told from its drift - [onHoldStart]; a finger's is the page's)
        if (!mouse || onHoldStart == null) _holdTimer?.cancel();
        resolve(GestureDisposition.accepted);
      }
      if (!_turning && !_dud) {
        if (moved.distance < _judgeAt) return; // (a mouse: its direction a few pixels on)
        _holdTimer?.cancel(); // (on its way: no hold)
        if (!_sideways(moved)) {
          _dud = true;
          return;
        }
        _turning = true;
        onStart?.call(DragStartDetails(globalPosition: _downGlobal, localPosition: _downLocal, kind: _kind));
        _lastGlobal = _downGlobal;
      }
      if (_turning) {
        final delta = event.position - _lastGlobal;
        _lastGlobal = event.position;
        onUpdate?.call(DragUpdateDetails(globalPosition: event.position, localPosition: event.localPosition,
            delta: Offset(delta.dx, 0), primaryDelta: delta.dx, kind: _kind));
      }
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      if (_holding) {
        onHoldEnd?.call();
        _reset();
        stopTrackingPointer(event.pointer);
        return;
      }
      final travel = (event.position - _downGlobal).distance;
      if (_turning) {
        // the horizontal part (a turn's speed; Flutter's drag ends carry one axis) - none for a short one
        final vx = event is PointerUpEvent && travel >= _flickAtLeast
            ? _velocity!.getVelocity().pixelsPerSecond.dx
            : 0.0;
        onEnd?.call(DragEndDetails(velocity: Velocity(pixelsPerSecond: Offset(vx, 0)), primaryVelocity: vx,
            globalPosition: event.position, localPosition: event.localPosition));
      }
      if (!_accepted) {
        _giveUp(); // a tap: the page's taps
      } else {
        // a mouse taken but let go before it turned: a click (a wobbly one)
        if (!_turning && !_dud && event is PointerUpEvent) {
          onTap?.call(TapUpDetails(kind: _kind, globalPosition: event.position, localPosition: event.localPosition));
        }
        _reset();
        stopTrackingPointer(event.pointer);
      }
    }
  }

  bool _sideways(Offset moved) {
    if (moved.dx == 0) return false;
    final angle = math.atan2(moved.dy.abs(), moved.dx.abs()) * 180 / math.pi;
    return angle <= maxAngle();
  }

  /// Stands aside: the pointer is the page's.
  void _giveUp() {
    final p = _pointer;
    _reset();
    if (p != null) {
      resolve(GestureDisposition.rejected);
      stopTrackingPointer(p);
    }
  }

  void _reset() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _pointer = null;
    _accepted = _turning = _dud = _holding = false;
    _velocity = null;
  }

  @override
  void acceptGesture(int pointer) {}

  @override
  void rejectGesture(int pointer) {
    // another gesture won the pointer first (a double tap's, say): no turn
    if (pointer == _pointer) {
      if (_turning) onCancel?.call();
      _reset();
      stopTrackingPointer(pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  @override
  String get debugDescription => 'page turn drag';
}

/// The page turn's drag over the whole of [child]'s area, without taking its taps or anything else: put over the page
/// (last in a Stack), so it hears a pointer before the page does.
class TurnDragArea extends StatelessWidget {
  const TurnDragArea({super.key, required this.configure, this.child});

  /// Sets the recognizer's callbacks and tests (run on each build).
  final void Function(TurnDragRecognizer r) configure;
  final Widget? child;

  @override
  Widget build(BuildContext context) => RawGestureDetector(
        behavior: HitTestBehavior.translucent,
        gestures: {
          TurnDragRecognizer: GestureRecognizerFactoryWithHandlers<TurnDragRecognizer>(
              () => TurnDragRecognizer(debugOwner: this), configure),
        },
        child: child ?? const SizedBox.expand(),
      );
}
