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
  HardwareKeyboard.instance.addHandler(_onKey);
  GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
}

bool _onKey(KeyEvent e) {
  if (e is KeyDownEvent && _navigationKeys.contains(e.logicalKey)) {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
  }
  return false; // only watching: the key still goes where it was going
}

void _onPointer(PointerEvent e) {
  if (e is PointerDownEvent) FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTouch;
}

/// Undoes [focusHighlightFollowsInput] (tests: so one test's watchers don't stay on for the next).
@visibleForTesting
void stopFollowingInput() {
  if (!_following) return;
  _following = false;
  HardwareKeyboard.instance.removeHandler(_onKey);
  GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
  FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
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

/// The readers' control bars (comics and EPUB): the control the remote is on gets a thick accent outline and a strong
/// accent fill, so it can be seen from the sofa. Touch never focuses these buttons, so this only ever shows while
/// using the remote.
ThemeData readerControlsTheme(BuildContext context) {
  final t = Theme.of(context);
  final style = strongFocusStyle(t.colorScheme.primary); // same as the rest of the app (main.dart)
  return t.copyWith(
    iconButtonTheme: IconButtonThemeData(style: style),
    textButtonTheme: TextButtonThemeData(style: style),
    filledButtonTheme: FilledButtonThemeData(style: style),
  );
}
