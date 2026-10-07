import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'reader_bars.dart';

/// The slider's scrub: the place picked while a finger is on the slider or the remote scrubs it - shown as it moves,
/// gone to when it ends. Kept by the reader (its position text shows the place picked), changed by [ReaderSlider].
class SliderScrub {
  int? value; // the place picked, not gone to yet (null: none)
  bool remote = false; // the remote is scrubbing (OK on the slider)
  int? _pointer; // the finger scrubbing (one at a time)

  bool get active => value != null;

  void reset() {
    value = null;
    remote = false;
  }

  /// A finger still on the slider is let go of: hidden by Esc / Back mid-scrub, the scrub is cancelled - its lift
  /// still reaches the slider's listener (Flutter sends a pointer's events where it went down) and went to the place
  /// picked (user, 2026-10-02).
  void release() => _pointer = null;
}

/// The readers' slider (the one Reader, user 2026-10-07): through the book, places 0..[last]; [shown] is the place
/// drawn (the one picked while scrubbing). Touch is followed here, not by the Slider's own drag - that could be
/// cancelled mid-drag, which jumped with the finger still down (user, 2026-09-30): the place changes when the finger
/// lifts. Under the remote: OK starts scrubbing, the arrows move [step] places, OK goes there.
///
/// [wayBack]: the place to come back to (where the reader was before scrubbing or jumping) - a finger near it lands
/// on it, and while [markWayBack] a short bar marks it (user, 2026-10-02). [preview]: drawn over the thumb while a
/// place is being picked (the comic reader's page picture). [rtl]: place 0 at the right end (the caller sets the
/// Directionality the Slider is drawn in).
class ReaderSlider extends StatelessWidget {
  const ReaderSlider({super.key, required this.node, required this.scrub, required this.shown, required this.at,
      required this.last, required this.onJump, required this.changed, this.rtl = false, this.wayBack,
      this.markWayBack = false, this.preview, this.innerNode, this.step = 1, this.upDownStep = false,
      this.onScrubStart, this.label});

  final FocusNode node;
  final FocusNode? innerNode; // the Slider's own (the wrapper takes focus)
  final SliderScrub scrub;
  final int shown, at, last;
  final void Function(int place) onJump;
  final VoidCallback changed; // the scrub changed: the reader rebuilds
  final bool rtl;
  final int? wayBack;
  final bool markWayBack;
  final Widget Function(int shown, double x)? preview;
  final int step;
  final bool upDownStep; // Up / Down step too while scrubbing (the comic reader's)
  final VoidCallback? onScrubStart;
  final String? label;

  /// A known inset, so the preview can sit over the thumb: the track runs edge to edge inside it.
  static const inset = 20.0;
  static const snap = 14.0; // a finger this close to the way-back mark lands on it

  int _placeAt(double x, double width) {
    final along = ((x - inset) / (width - 2 * inset)).clamp(0.0, 1.0);
    return ((rtl ? 1 - along : along) * last).round();
  }

  /// Where place [i] sits on the slider (right to left: place 0 at the right end).
  double xOf(int i, double width) {
    final along = inset + (last == 0 ? 0 : i / last) * (width - 2 * inset);
    return rtl ? width - along : along;
  }

  /// The place under a finger dragging along the slider: the way-back place when it's close to it.
  int _dragAt(double x, double width) {
    final back = wayBack;
    return back != null && (x - xOf(back, width)).abs() <= snap ? back : _placeAt(x, width);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (isOkKey(k)) {
      if (e is! KeyDownEvent) return KeyEventResult.handled;
      if (scrub.remote) {
        final target = scrub.value ?? at;
        scrub.reset();
        changed();
        onJump(target);
      } else {
        onScrubStart?.call();
        scrub
          ..remote = true
          ..value = at;
        changed();
      }
      return KeyEventResult.handled;
    }
    // Left / Right follow the reading direction (right to left: Left goes forward); Up / Down and Page Up / Down don't
    final fwd = k == (rtl ? LogicalKeyboardKey.arrowLeft : LogicalKeyboardKey.arrowRight) ||
        k == LogicalKeyboardKey.pageDown || (upDownStep && k == LogicalKeyboardKey.arrowDown);
    final back = k == (rtl ? LogicalKeyboardKey.arrowRight : LogicalKeyboardKey.arrowLeft) ||
        k == LogicalKeyboardKey.pageUp || (upDownStep && k == LogicalKeyboardKey.arrowUp);
    if (scrub.remote && (fwd || back)) {
      scrub.value = ((scrub.value ?? at) + (fwd ? step : -step)).clamp(0, last);
      changed();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored; // not scrubbing: the arrows go on to the next control
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final top = math.max(1, last);
    return Focus(
      focusNode: node,
      onKeyEvent: _onKey,
      onFocusChange: (_) {
        if (!node.hasFocus) scrub.reset();
        changed();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: node.hasFocus ? accent.withValues(alpha: scrub.remote ? 0.5 : 0.3) : Colors.transparent,
          border: Border.all(color: node.hasFocus ? accent : Colors.transparent, width: 3),
        ),
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            inactiveTrackColor: Colors.white24,
            showValueIndicator: ShowValueIndicator.never, // the preview / the position text says where
            padding: const EdgeInsets.symmetric(horizontal: inset, vertical: 12),
          ),
          child: LayoutBuilder(builder: (context, box) {
            final width = box.maxWidth;
            final back = wayBack;
            return Stack(clipBehavior: Clip.none, children: [
              Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (e) {
                  if (scrub._pointer != null) return; // one finger scrubs
                  scrub._pointer = e.pointer;
                  onScrubStart?.call();
                  scrub.value = _dragAt(e.localPosition.dx, width);
                  changed();
                },
                onPointerMove: (e) {
                  if (e.pointer != scrub._pointer) return;
                  final p = _dragAt(e.localPosition.dx, width);
                  if (p != scrub.value) {
                    scrub.value = p;
                    changed();
                  }
                },
                onPointerUp: (e) {
                  if (e.pointer != scrub._pointer) return;
                  scrub._pointer = null;
                  onJump(_dragAt(e.localPosition.dx, width));
                  scrub.value = null;
                  changed();
                },
                onPointerCancel: (e) {
                  if (e.pointer != scrub._pointer) return;
                  scrub._pointer = null;
                  scrub.value = null; // the system took the touch: stay where we were
                  changed();
                },
                child: IgnorePointer(
                  child: Slider(
                    focusNode: innerNode,
                    min: 0,
                    max: top.toDouble(),
                    divisions: top,
                    value: shown.clamp(0, top).toDouble(),
                    label: label,
                    onChanged: (_) {}, // the enabled look; touch and keys are handled above
                  ),
                ),
              ),
              // over the track, under the preview: while scrubbing, and whenever there's a place to go back to
              if (back != null && markWayBack)
                Positioned(
                  left: xOf(back, width) - 1.5,
                  top: 0,
                  bottom: 0,
                  width: 3,
                  child: IgnorePointer(
                    child: Center(
                      child: Container(
                        key: const ValueKey('scrub-start'),
                        height: 22,
                        decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(1.5),
                            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 2)]),
                      ),
                    ),
                  ),
                ),
              if (scrub.active && preview != null) preview!(shown, xOf(shown, width)),
            ]);
          }),
        ),
      ),
    );
  }
}
