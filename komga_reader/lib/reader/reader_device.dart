import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../offline/connection.dart';
import '../offline/downloads.dart';
import '../screen.dart';
import '../settings.dart';

/// What a reader does to the device while a book is open - the same for every kind of book (the one Reader, user
/// 2026-10-07; reports\plan-reader-renderer-2026-10-07.md): the screen kept on, the rotation lock, the system bars
/// hidden, desktop full screen followed, and the app told a reader is open (an automatic switch back online and
/// Delete once read wait for it to close; the brightness setting is the reader's).
///
/// [openDevice] in initState; closing in two parts - [closeDevice], then the reader's last save, then
/// [deviceClosed] - so a book finished here is marked read before Downloads hears the book closed.
mixin ReaderDevice<T extends StatefulWidget> on State<T> {
  AppSettings get _settings => AppSettings.instance;

  /// Settings changed (not only brightness or warmth: those are drawn over the whole app). The reader rebuilds what
  /// it shows.
  void onReaderSettings();

  /// Desktop full screen switched (the reader's button shows it).
  void onFullscreenChanged() {
    if (mounted) setState(() {});
  }

  void openDevice() {
    Connection.instance.readerOpened(); // an automatic switch back online waits for the book to close
    Downloads.instance.readerOpened(); // Delete once read waits for it too
    _settings.readerOpened(); // the screen brightness setting is the reader's
    // rotation as set (the app otherwise follows the sensor, via the manifest), the system bars hidden, the screen on
    _applyRotation();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    awake();
    _settings.addListener(_onDeviceSettings);
    fullscreen.addListener(onFullscreenChanged); // F11 is app-wide (main.dart): the button follows
  }

  /// Everything but Downloads: the reader saves next, then calls [deviceClosed].
  void closeDevice() {
    _awakeTimer?.cancel();
    Connection.instance.readerClosed();
    _settings.readerClosed(); // the screen follows the system again
    _settings.removeListener(_onDeviceSettings);
    fullscreen.removeListener(onFullscreenChanged);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (_rotation != Rotation.auto) OrientationLock.instance.release(); // a lock ends with the book
    if (_screenHeld) keepScreenOn(false);
  }

  /// After the reader's last save: Delete once read may go ahead.
  void deviceClosed() => Downloads.instance.readerClosed();

  void _onDeviceSettings() {
    if (!mounted) return;
    _applyRotation();
    if (_settings.display.screenOn != _screenOnFor) awake(); // Keep the screen on changed
    onReaderSettings();
  }

  // ---- Rotation (Settings > Reader, and the readers' panels): follow the device, or hold portrait / landscape
  Rotation? _rotation;

  void _applyRotation() {
    final r = _settings.display.rotation;
    if (r == _rotation) return;
    _rotation = r;
    OrientationLock.instance.hold(portrait: r == Rotation.portrait, landscape: r == Rotation.landscape);
  }

  // ---- Keep the screen on (Settings > Reader): always while a book is open, for N minutes after the last page turn
  // or touch, or never (the system's own timeout)
  Timer? _awakeTimer;
  bool _screenHeld = false;
  int? _screenOnFor;

  /// A turn or a touch: the screen stays on for the chosen minutes from now.
  void awake() {
    final minutes = _screenOnFor = _settings.display.screenOn;
    _awakeTimer?.cancel();
    final hold = minutes != 0;
    if (hold != _screenHeld) {
      _screenHeld = hold;
      keepScreenOn(hold);
    }
    if (minutes > 0) {
      _awakeTimer = Timer(Duration(minutes: minutes), () {
        _screenHeld = false;
        keepScreenOn(false); // the system's timeout takes over; the next turn or touch holds it again
      });
    }
  }
}
