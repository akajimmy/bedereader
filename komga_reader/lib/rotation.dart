import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Auto rotation on Android, the app's own (user, 2026-10-24: "the app should handle the rotation so it's not turning
/// every time the tablet turns. We're just using the tablet setting to determine whether or not we should rotate").
///
/// The tablet's auto-rotate off: the screen stays as the tablet holds it (its lock). On: the screen is held one way up,
/// and turned only when the tablet has clearly turned - leaning within [within] degrees of another way up (not lying
/// flat, not near a diagonal) for [hold] without a break. A tilt and back within that time turns nothing (Android's
/// own rotation turned the screen out of landscape and back within a second, and each turn rebuilt the pages - the
/// app was closed for memory). The tilt and the setting come from the Android side (MainActivity, "komga_reader/
/// rotation"); the deciding is here.
class AutoRotation {
  AutoRotation._();
  static final instance = AutoRotation._();

  static const _channel = MethodChannel('komga_reader/rotation');
  static const _screen = MethodChannel('komga_reader/screen');

  /// How long the tablet must stay turned before the screen follows.
  static const hold = Duration(milliseconds: 700);

  /// How near a way up the tablet must lean (degrees either side; the rest, near the diagonals, turns nothing).
  static const within = 30;

  bool _following = false;
  bool _systemAuto = false;
  int? _way; // the way up held (degrees: 0 portrait, 90 landscape, 180 portrait upside down, 270 landscape the other)
  int? _leaning; // the way the tablet has been turned to, waiting out [hold]
  Timer? _timer;

  /// Following the tablet (Auto, no lock of the reader's): on Android, judged here; elsewhere, the device's own way.
  Future<void> follow() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      await SystemChrome.setPreferredOrientations(const []);
      return;
    }
    _channel.setMethodCallHandler(_onCall);
    _following = true;
    await SystemChrome.setPreferredOrientations(const []); // the tablet's own way, until its setting is known
    unawaited(_ask()); // (not waited for: nothing that lets go of a lock waits on the tablet's answer)
  }

  Future<void> _ask() async {
    bool? auto;
    try {
      auto = await _channel.invokeMethod<bool>('follow', true);
    } catch (_) {
      // no native side: the device's own way
    }
    if (_following) await _systemAutoIs(auto);
  }

  /// A lock of the reader's takes over (Portrait, Landscape, Locked): no more turning here.
  Future<void> stop() async {
    if (!_following) return;
    _following = false;
    _wait(null);
    unawaited(_channel.invokeMethod('follow', false).then((_) {}, onError: (Object _) {})); // (not waited for)
  }

  Future<void> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'systemAutoRotate':
        if (_following) await _systemAutoIs(call.arguments as bool?);
      case 'tilt':
        _tilt(call.arguments as int);
    }
  }

  /// The tablet's auto-rotate is [auto]: off (or not known), the screen as the tablet holds it; on, held the way it
  /// is up now - turned from there by [_tilt].
  Future<void> _systemAutoIs(bool? auto) async {
    _systemAuto = auto ?? false;
    _wait(null);
    if (!_systemAuto) {
      _way = null;
      await SystemChrome.setPreferredOrientations(const []); // the tablet's own way: its lock
      return;
    }
    final way = await _wayNow();
    // a lock of the reader's taken over meanwhile: it stands (code review, 2026-10-24: the way up applied after it)
    if (!_following || !_systemAuto) return;
    _way = way;
    if (_way == null) {
      await SystemChrome.setPreferredOrientations(const []);
    } else {
      await _apply(_way!);
    }
  }

  /// The tablet leans to [way] (degrees, as [_way]; -1 lying flat).
  void _tilt(int way) {
    if (!_following || !_systemAuto || _way == null) return;
    if (way < 0) return _wait(null); // flat: no way up
    final nearest = (way + 45) ~/ 90 % 4 * 90;
    final off = (way - nearest + 540) % 360 - 180;
    if (off.abs() > within || nearest == _way) return _wait(null); // near a diagonal, or back as it is
    if (nearest == _leaning) return; // still turned that way: the wait goes on
    _wait(nearest);
  }

  void _wait(int? way) {
    _timer?.cancel();
    _timer = null;
    _leaning = way;
    if (way == null) return;
    _timer = Timer(hold, () {
      _leaning = null;
      if (!_following || !_systemAuto) return;
      _way = way;
      _apply(way);
    });
  }

  Future<int?> _wayNow() async {
    try {
      return switch (await _screen.invokeMethod<String>('currentWayUp')) {
        'portrait' => 0,
        'landscape' => 90,
        'reversePortrait' => 180,
        'reverseLandscape' => 270,
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  static Future<void> _apply(int way) => SystemChrome.setPreferredOrientations([
        switch (way) {
          0 => DeviceOrientation.portraitUp,
          90 => DeviceOrientation.landscapeLeft, // (Android's LANDSCAPE)
          180 => DeviceOrientation.portraitDown,
          _ => DeviceOrientation.landscapeRight,
        },
      ]);
}
