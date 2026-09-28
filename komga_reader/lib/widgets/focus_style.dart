import 'package:flutter/material.dart';

/// The remote's "you are here" look, used on every button in the app (the Home pills, app-bar buttons, the reader's
/// controls, dialogs): a thick accent outline and a strong accent fill with white text/icon. It only ever shows for
/// keyboard/remote focus - touch doesn't focus buttons.
ButtonStyle strongFocusStyle(Color accent) {
  WidgetStateProperty<T?> onFocus<T>(T v) =>
      WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.focused) ? v : null);
  return ButtonStyle(
    backgroundColor: onFocus(accent.withValues(alpha: 0.45)),
    foregroundColor: onFocus(Colors.white),
    iconColor: onFocus(Colors.white),
    side: onFocus(BorderSide(color: accent, width: 3)),
    overlayColor: onFocus(Colors.transparent),
  );
}
