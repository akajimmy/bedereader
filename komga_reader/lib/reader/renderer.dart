import 'package:flutter/widgets.dart';

import '../api.dart';

/// What a renderer - the pages of one kind of book (comic pages, an EPUB) - may ask of the Reader it's in (the one
/// Reader, user 2026-10-07; reports\plan-reader-renderer-2026-10-07.md). The Reader implements it; the renderer
/// never needs to know more of it.
///
/// Places: what the Reader counts in - the comic renderer's are its pages, 0..last, and last + 1 is the end card.
abstract class ReaderHost {
  BuildContext get context;
  bool get mounted;
  TickerProvider get vsync;
  Komga get api;

  /// The controls are up (the page's own gestures wait).
  bool get controlsUp;

  /// Another book is on its way: turns wait for it.
  bool get busy;

  /// The place picked on the slider right now (null: none) - the page strip follows it.
  int? get scrub;

  /// The place to come back to after a slider or strip jump (null: none) - marked on the strip.
  int? get wayBack;

  /// Something the Reader draws from the renderer changed: rebuild.
  void changed();

  /// A touch or a turn: the screen stays on.
  void awake();

  /// A single tap at [x] (0..1 across the screen), not taken by the page: the Reader's tap zones.
  void tap(double x);

  /// Right-click: the controls up or down.
  void toggleControls();

  /// The page view moved to [place]. [curling]: a page curl started it - it counts as a turn once the curl
  /// completes ([turned]), not yet.
  void pageChanged(int place, {required bool curling});

  /// A page curl completed: the turn to [place] counts now.
  void turned(int place);

  /// Forward from the end card: the next book.
  void nextBook();

  /// A jump picked on the renderer's own controls (the page strip): as one from the slider - the way back is kept.
  void jumpTo(int place);

  /// The page after the last: what's next.
  Widget endCard();
}

/// A control the renderer adds to the Reader's bars, with its focus node for the remote's walk.
class BarButton {
  const BarButton(this.node, this.child);
  final FocusNode node;
  final Widget child;
}
