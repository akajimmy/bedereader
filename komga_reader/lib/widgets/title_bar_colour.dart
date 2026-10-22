import 'package:flutter/widgets.dart';

import '../screen.dart';

/// Windows' title bar in [colour] while this is on screen - what's along the top of the reader - and back to the
/// app's own when it goes (user, 2026-10-22: "the colour of the title bar should match the colour of the background
/// ... in a reader with a different background it stands out again"). [colour] is asked again whenever [changes]
/// fires (the settings: a page colour, an inset page), without rebuilding what's under it. Elsewhere, nothing.
class TitleBarColour extends StatefulWidget {
  const TitleBarColour({super.key, required this.colour, required this.changes, required this.child});
  final Color Function() colour;
  final Listenable changes;
  final Widget child;

  @override
  State<TitleBarColour> createState() => _TitleBarColourState();
}

class _TitleBarColourState extends State<TitleBarColour> {
  Color? _set;

  void _apply() {
    if (!mounted) return;
    final c = widget.colour();
    if (c == _set) return;
    _set = c;
    setTitleBarColour(c);
  }

  /// A setting changed: asked again once the reader has been laid out with it (an inset page's sheet is worked out
  /// in its layout) - now, and after the next frame.
  void _changed() {
    _apply();
    WidgetsBinding.instance.addPostFrameCallback((_) => _apply());
  }

  @override
  void initState() {
    super.initState();
    widget.changes.addListener(_changed);
    _changed();
  }

  @override
  void didUpdateWidget(TitleBarColour old) {
    super.didUpdateWidget(old);
    if (old.changes != widget.changes) {
      old.changes.removeListener(_changed);
      widget.changes.addListener(_changed);
    }
    _changed(); // (the reader rebuilt: a book opened, the page colour changed)
  }

  @override
  void dispose() {
    widget.changes.removeListener(_changed);
    setTitleBarColour(appBackground);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
