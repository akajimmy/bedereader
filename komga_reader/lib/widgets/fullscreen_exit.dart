import 'package:flutter/material.dart';

import '../screen.dart';

/// Desktop, in full screen: an X at the right end of every screen's top bar that leaves full screen (a borderless
/// full-screen window has no title bar to do it with). Nothing otherwise. The reader has its own button.
class FullscreenExit extends StatelessWidget {
  const FullscreenExit({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: fullscreen,
        builder: (context, on, _) => !on
            ? const SizedBox.shrink()
            : IconButton(tooltip: 'Leave full screen (F11)', icon: const Icon(Icons.close), onPressed: toggleFullscreen),
      );
}
