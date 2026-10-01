import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A page of text under a remote (book / series details, the documents): Up and Down move to a button above or below
/// when there is one, and otherwise scroll the page - a long summary, the credits or the changelog couldn't be read
/// past the screen with a remote, the arrows only ever moved between buttons (code review, 2026-09-30).
///
/// Wraps the whole screen (so keys reach it wherever the focus is, the app bar's back arrow included); [builder] gets
/// the controller for the page's scroll view.
class ArrowScroll extends StatefulWidget {
  const ArrowScroll({super.key, required this.builder});
  final Widget Function(ScrollController controller) builder;

  @override
  State<ArrowScroll> createState() => _ArrowScrollState();
}

class _ArrowScrollState extends State<ArrowScroll> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final down = e.logicalKey == LogicalKeyboardKey.arrowDown;
    if (!down && e.logicalKey != LogicalKeyboardKey.arrowUp) return KeyEventResult.ignored;
    // a button that way: go to it, as usual
    final f = FocusManager.instance.primaryFocus;
    if (f != null && f.focusInDirection(down ? TraversalDirection.down : TraversalDirection.up)) {
      return KeyEventResult.handled;
    }
    // none: scroll (most of a screen at a time)
    if (!_scroll.hasClients) return KeyEventResult.ignored;
    final p = _scroll.position;
    final step = p.viewportDimension * 0.8;
    final target = (p.pixels + (down ? step : -step)).clamp(p.minScrollExtent, p.maxScrollExtent);
    if ((target - p.pixels).abs() < 1) return KeyEventResult.ignored; // at the end already
    _scroll.animateTo(target, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) =>
      Focus(canRequestFocus: false, skipTraversal: true, onKeyEvent: _onKey, child: widget.builder(_scroll));
}
