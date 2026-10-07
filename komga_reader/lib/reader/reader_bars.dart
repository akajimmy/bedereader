import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../screen.dart';
import '../settings.dart';
import '../widgets/focus_style.dart';
import '../widgets/reader_clock.dart';

/// The readers' bars - the same for every kind of book (the one Reader, user 2026-10-07): a top bar (Close, the book's
/// heading and title, the clock, the reader's own buttons) and a bottom bar (previous book, the reader's middle - the
/// position and the slider -, its own buttons, next book), over the page while the controls are up. Each reader
/// passes its buttons; the frame, the colours, the clock and the remote's walk between them are shared here.
const readerBarColour = Color(0xE6101012);

/// An icon-only control (user: no labels except Close); the label is its tooltip. White icon.
Widget barIcon({required FocusNode node, required IconData icon, required String label,
        required VoidCallback onPressed, double size = 26}) =>
    IconButton(focusNode: node, tooltip: label, icon: Icon(icon, color: Colors.white, size: size), onPressed: onPressed);

/// The top bar: Close, [heading] over [title] (no heading: the title alone, larger), the clock where there's room, then
/// [buttons]. On a narrow screen the clock sits just under the bar instead.
class ReaderTopBar extends StatelessWidget {
  const ReaderTopBar({super.key, required this.closeNode, required this.heading, required this.title,
      required this.buttons, this.clock = ShowWhen.withControls});
  final FocusNode closeNode;
  final ShowWhen clock; // the open kind's Clock and battery
  final String? heading;
  final String title;
  final List<Widget> buttons;

  @override
  Widget build(BuildContext context) {
    final showClock = clock != ShowWhen.off; // with the controls: With the controls / Always
    final clockInBar = MediaQuery.sizeOf(context).width >= 700; // a phone's top bar has no room for it
    final head = heading;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Material(
        color: readerBarColour,
        child: Theme(
          data: readerControlsTheme(context),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 12, 8, 12),
              child: Row(children: [
                FilledButton.tonalIcon(
                  focusNode: closeNode,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                    textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back, size: 24),
                  label: const Text('Close'),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    if (head != null)
                      Text(head, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 17)),
                    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: head != null
                            ? const TextStyle(color: Colors.white60, fontSize: 13)
                            : const TextStyle(color: Colors.white, fontSize: 17)),
                  ]),
                ),
                // Clock and battery with the controls up, where the bar has room (else just under it, below)
                if (showClock && clockInBar)
                  const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: ReaderClock()),
                ...buttons,
              ]),
            ),
          ),
        ),
      ),
      // narrow screens: no room on the top bar - the clock sits just under it, at the right
      if (showClock && !clockInBar)
        Align(
          alignment: Alignment.centerRight,
          child: IgnorePointer(
            child: Container(
              margin: const EdgeInsets.fromLTRB(0, 8, 10, 0),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: readerBarColour, borderRadius: BorderRadius.circular(10)),
              child: const ReaderClock(fontSize: 12),
            ),
          ),
        ),
    ]);
  }
}

/// The bottom bar: previous book, [middle] (the slider - give it an Expanded), [buttons], next book; [position] (the
/// position text, lib/reader/position_row.dart) over them in the bar; [above] (the comic reader's page strip) just
/// over the bar.
class ReaderBottomBar extends StatelessWidget {
  const ReaderBottomBar({super.key, required this.prevNode, required this.onPrev, required this.nextNode,
      required this.onNext, required this.middle, required this.buttons, this.above, this.position});
  final FocusNode prevNode, nextNode;
  final VoidCallback onPrev, onNext;
  final List<Widget> middle;
  final List<Widget> buttons;
  final Widget? above;
  final Widget? position;

  @override
  Widget build(BuildContext context) {
    final controls = Row(children: [
      IconButton(focusNode: prevNode, tooltip: 'Previous book', onPressed: onPrev,
          icon: const Icon(Icons.skip_previous, size: 28)),
      const SizedBox(width: 4),
      ...middle,
      ...buttons,
      IconButton(focusNode: nextNode, tooltip: 'Next book', onPressed: onNext,
          icon: const Icon(Icons.skip_next, size: 28)),
    ]);
    final pos = position;
    final bar = Material(
      color: readerBarColour,
      child: Theme(
        data: readerControlsTheme(context),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            child: pos == null
                ? controls
                : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [pos, controls]),
          ),
        ),
      ),
    );
    final row = above;
    if (row == null) return bar;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [row, bar]);
  }
}

/// The bars over the page, for the reader's Stack: [top] at the top, [bottom] at the bottom, and - given
/// [onTapOutside] - a tap anywhere else hides them.
List<Widget> readerBars({required Widget top, required Widget bottom, VoidCallback? onTapOutside}) => [
      if (onTapOutside != null)
        Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTapOutside)),
      Positioned(left: 0, right: 0, top: 0, child: top),
      Positioned(left: 0, right: 0, bottom: 0, child: bottom),
    ];

/// Where the remote goes next among the controls.
sealed class WalkTo {
  const WalkTo();
}

/// To this control.
class WalkToNode extends WalkTo {
  const WalkToNode(this.node);
  final FocusNode node;
}

/// Into the row between the bars (the page strip): the reader puts the focus there.
class WalkToRow extends WalkTo {
  const WalkToRow();
}

/// Off the bars: nothing selected (OK then hides the controls).
class WalkOff extends WalkTo {
  const WalkOff();
}

/// The remote among the controls (user's layout): Left / Right move along a bar and stop at its ends; Up / Down
/// switch between the top and bottom bar, keeping the position as near as it goes. Up from the top bar or Down from the
/// bottom bar leaves the bars ("nothing selected"). From nothing selected: Down -> the bottom bar, anything else -> the
/// top bar. With [row] (the page strip, open) it's a row of its own just above the bottom bar: Up from the bottom bar
/// or Down from the top bar go into it; from it Up goes to the top bar, Down to [rowBelow] on the bottom bar.
WalkTo walkControls({required List<FocusNode> top, required List<FocusNode> bottom, required int dx, required int dy,
    FocusNode? row, FocusNode? rowBelow}) {
  final inTop = top.indexWhere((n) => n.hasFocus);
  final inBottom = bottom.indexWhere((n) => n.hasFocus);
  if (row != null && row.hasFocus) {
    if (dy == 0) return WalkToNode(row); // Left / Right in the row are its own
    return WalkToNode(dy < 0 ? top.first : (rowBelow ?? bottom.first));
  }
  if (inTop < 0 && inBottom < 0) return WalkToNode(dy > 0 ? bottom.first : top.first);
  if (dx != 0) {
    final bar = inTop >= 0 ? top : bottom, i = inTop >= 0 ? inTop : inBottom;
    return WalkToNode(bar[(i + dx).clamp(0, bar.length - 1)]);
  }
  if (inTop >= 0) {
    if (dy > 0 && row != null) return const WalkToRow(); // down from the top bar: the row comes first
    return dy > 0 ? WalkToNode(bottom[inTop.clamp(0, bottom.length - 1)]) : const WalkOff();
  }
  if (dy < 0 && row != null) return const WalkToRow(); // up from the bottom bar: into the row
  return dy < 0 ? WalkToNode(top[inBottom.clamp(0, top.length - 1)]) : const WalkOff();
}

/// The fixed keys among the controls (not remappable, so a mapping can't strand the remote): OK.
bool isOkKey(LogicalKeyboardKey k) =>
    k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.numpadEnter;

/// A key while the controls are up (fixed keys, as [isOkKey]): Esc / Back hide them; the arrows walk them ([move]);
/// OK with [nothingSelected] hides them, like a tap; OK on a control is left to reach it (= tapping it).
KeyEventResult controlsKey(KeyEvent e, {required bool nothingSelected, required VoidCallback hide,
    required void Function({int dx, int dy}) move}) {
  final k = e.logicalKey;
  if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.goBack) {
    hide();
    return KeyEventResult.handled;
  }
  if (k == LogicalKeyboardKey.arrowRight) { move(dx: 1); return KeyEventResult.handled; }
  if (k == LogicalKeyboardKey.arrowLeft) { move(dx: -1); return KeyEventResult.handled; }
  if (k == LogicalKeyboardKey.arrowDown) { move(dy: 1); return KeyEventResult.handled; }
  if (k == LogicalKeyboardKey.arrowUp) { move(dy: -1); return KeyEventResult.handled; }
  if (isOkKey(k) && nothingSelected) {
    if (e is KeyDownEvent) hide();
    return KeyEventResult.handled;
  }
  return KeyEventResult.ignored;
}

/// Desktop full screen, for the top bar: the button that switches it (F11 anywhere does too).
Widget fullscreenButton(FocusNode node) => barIcon(
      node: node,
      icon: fullscreen.value ? Icons.fullscreen_exit : Icons.fullscreen,
      label: fullscreen.value ? 'Leave full screen (F11)' : 'Full screen (F11)',
      onPressed: toggleFullscreen, // stays on after the book closes (user)
    );
