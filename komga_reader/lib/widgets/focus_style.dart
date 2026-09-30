import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The "you are here" highlight (tiles, buttons - everything that follows Flutter's focus highlight mode) shows only
/// while the keyboard or a remote is being used: from the first arrow / Tab / Enter until the next click or touch.
/// Flutter's own rule starts desktop apps in keyboard mode and keeps them there with a mouse, so on Windows the first
/// Continue reading book (which gets focus for the remote) showed highlighted on start-up (user, 2026-09-29).
void focusHighlightFollowsInput() {
  FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTouch; // start plain, on every platform
  if (_following) return;
  _following = true;
  HardwareKeyboard.instance.addHandler((e) {
    if (e is KeyDownEvent && _navigationKeys.contains(e.logicalKey)) {
      FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
    }
    return false; // only watching: the key still goes where it was going
  });
  GestureBinding.instance.pointerRouter.addGlobalRoute((e) {
    if (e is PointerDownEvent) FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTouch;
  });
}

bool _following = false;
final _navigationKeys = {
  LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowRight,
  LogicalKeyboardKey.tab, LogicalKeyboardKey.enter, LogicalKeyboardKey.numpadEnter, LogicalKeyboardKey.select,
};

/// The remote's "you are here" look, used on every button in the app (the Home pills, app-bar buttons, the reader's
/// controls, dialogs): a thick accent outline and a strong accent fill with white text/icon. It only ever shows for
/// keyboard/remote focus: a button that merely starts with focus (autofocus - Retry, Read, a dialog's Cancel) stays
/// plain until an arrow key has been pressed (Flutter's "traditional" highlight mode), like the poster tiles.
ButtonStyle strongFocusStyle(Color accent) {
  bool remote() => FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
  WidgetStateProperty<T?> onFocus<T>(T v) =>
      WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.focused) && remote() ? v : null);
  return ButtonStyle(
    backgroundColor: onFocus(accent.withValues(alpha: 0.45)),
    foregroundColor: onFocus(Colors.white),
    iconColor: onFocus(Colors.white),
    side: onFocus(BorderSide(color: accent, width: 3)),
    overlayColor: onFocus(Colors.transparent),
  );
}
