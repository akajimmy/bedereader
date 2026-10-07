import 'package:flutter/material.dart';

import '../settings.dart';

/// The three spots of the position text over the slider (the one Reader, user 2026-10-07, decision 5 - mockup "A").
enum PositionSpot { left, centre, right }

/// What a renderer puts in a spot: [text], and [name] for what it is (a hidden spot is "Show the title" to a screen
/// reader).
class SpotText {
  const SpotText(this.text, this.name);
  final String text, name;
}

/// The reader's position, on two lines over the slider: [centre] on its own line on top (the title: the longest),
/// [left] and [right] sharing the line just above the slider's ends. A spot the renderer leaves null isn't there
/// (comics fill two). Each spot is tapped to hide it - then nothing is drawn there, but its place stays and a tap on it
/// shows it again; that's kept on this device, for both kinds of book ([DisplayPrefs.hiddenSpots]). [picking]: a place
/// is being picked on the slider - the text is in the accent colour.
class ReaderPositionRow extends StatelessWidget {
  const ReaderPositionRow({super.key, required this.kind, this.left, this.centre, this.right, this.picking = false});
  final BookKind kind; // which kind's spots are hidden (each kind its own - user, 2026-10-07)
  final SpotText? left, centre, right;
  final bool picking;

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    final kp = s.display.kind(kind);
    final hidden = kp.hiddenSpots;
    final colour = picking ? Theme.of(context).colorScheme.primary : Colors.white;
    Widget spot(PositionSpot at, SpotText t, TextAlign align, double size) {
      final off = hidden.contains(at.name);
      return GestureDetector(
        key: ValueKey('pos-${at.name}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => s.setDisplay(s.display.withKind(kind,
            kp.copyWith(hiddenSpots: off ? (List.of(hidden)..remove(at.name)) : [...hidden, at.name]))),
        // hidden: nothing drawn (user, 2026-10-07: no "hidden - tap to show" box, gone) - its place stays, an
        // invisible line as tall as its text, so a tap there brings it back and the slider doesn't move
        child: off
            ? Semantics(button: true, label: 'Show the ${t.name}',
                child: SizedBox(key: ValueKey('pos-${at.name}-hidden'), width: double.infinity, height: size * 1.4))
            : Text(t.text, key: ValueKey('pos-${at.name}-text'), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: align,
                style: TextStyle(color: colour, fontSize: size, fontFeatures: const [FontFeature.tabularFigures()])),
      );
    }

    final l = left, c = centre, r = right;
    return Padding(
      // over the slider: its ends are past the book buttons
      padding: const EdgeInsets.fromLTRB(60, 0, 60, 2),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (c != null) Center(child: spot(PositionSpot.centre, c, TextAlign.center, 13)),
        if (l != null || r != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(children: [
              Expanded(child: Align(alignment: Alignment.centerLeft,
                  child: l == null ? const SizedBox.shrink() : spot(PositionSpot.left, l, TextAlign.left, 14))),
              const SizedBox(width: 12),
              Expanded(child: Align(alignment: Alignment.centerRight,
                  child: r == null ? const SizedBox.shrink() : spot(PositionSpot.right, r, TextAlign.right, 14))),
            ]),
          ),
      ]),
    );
  }
}
