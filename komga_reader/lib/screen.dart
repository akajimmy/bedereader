import 'package:flutter/services.dart';

const _channel = MethodChannel('komga_reader/screen');

/// Stops the tablet from dimming and sleeping while a book is open (Android; a no-op on web/Windows).
Future<void> keepScreenOn(bool on) async {
  try {
    await _channel.invokeMethod('keepOn', on);
  } catch (_) {
    // no native side on this platform
  }
}

/// The screen's current brightness 0..1 (this app's own level if set, else the tablet's). Null where unknown.
Future<double?> getScreenBrightness() async {
  try {
    return (await _channel.invokeMethod<num>('getBrightness'))?.toDouble();
  } catch (_) {
    return null;
  }
}

/// Installed app version, e.g. "0.1.0 (build 17)". Null where unknown (web/desktop).
Future<String?> getAppVersion() async {
  try {
    final v = await _channel.invokeMapMethod<String, Object?>('appVersion');
    if (v == null) return null;
    return '${v['name']} (build ${v['code']})';
  } catch (_) {
    return null;
  }
}

/// Opens a link in the device's browser. False if it couldn't.
Future<bool> openUrl(String url) async {
  try {
    return await _channel.invokeMethod<bool>('openUrl', url) ?? false;
  } catch (_) {
    return false;
  }
}

/// Backlight for this app's window only (the rest of the tablet keeps its setting): -1 = follow the system,
/// else 0.01..1. Android; a no-op elsewhere.
Future<void> setScreenBrightness(double value) async {
  try {
    await _channel.invokeMethod('brightness', value);
  } catch (_) {
    // no native side on this platform
  }
}
