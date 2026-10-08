import 'package:flutter/material.dart';

import '../settings.dart';

/// Sits over the whole app (MaterialApp.builder): the night-mode warm tint (everywhere), and the "darker than
/// minimum" layer - only while a book is open, as the brightness setting is the reader's (user, 2026-10-05).
/// Neither takes touches. The app itself stays child 0 of the Stack, so switching these on and off never rebuilds it.
class NightOverlay extends StatelessWidget {
  const NightOverlay({super.key, required this.child});
  final Widget child;

  /// Warm tint as a colour matrix: blue cut most, green a little, red untouched.
  static List<double> warmMatrix(double w) => [
        1, 0, 0, 0, 0,
        0, 1 - 0.18 * w, 0, 0, 0,
        0, 0, 1 - 0.6 * w, 0, 0,
        0, 0, 0, 1, 0,
      ];

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    return ListenableBuilder(
      listenable: s,
      child: child,
      builder: (context, app) {
        final d = s.display;
        return Stack(fit: StackFit.expand, children: [
          app!,
          if (d.night)
            IgnorePointer(
              child: BackdropFilter(filter: ColorFilter.matrix(warmMatrix(d.warmth)), child: const SizedBox.expand()),
            ),
          if (s.brightnessShown && d.dimOverlay > 0)
            IgnorePointer(child: ColoredBox(color: Colors.black.withValues(alpha: d.dimOverlay))),
        ]);
      },
    );
  }
}
