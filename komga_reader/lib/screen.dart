import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('komga_reader/screen');

/// Windows / macOS / Linux app (mouse, keyboard, resizable window) rather than a phone or tablet.
bool get isDesktop =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux);

/// Only Android lets the app set the screen's backlight; elsewhere the brightness slider just dims.
bool get hasBacklightControl => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Volume keys can turn pages: on Android the app sees them first, and a key it uses doesn't change the volume. On a
/// PC the system changes the volume whatever the app does, so they're left alone there.
bool get hasVolumeKeys => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Desktop full screen: one state for the whole app, not just the open book - closing a book (Esc included) stays
/// full screen, the next book opens in it, and it's remembered across restarts (user, 2026-09-29). F11 anywhere,
/// or the reader's button.
final ValueNotifier<bool> fullscreen = ValueNotifier(false);
const _fullscreenKey = 'desktop.fullscreen';

Future<void> toggleFullscreen() async {
  final now = await setFullscreen(!fullscreen.value);
  fullscreen.value = now;
  await (await SharedPreferences.getInstance()).setBool(_fullscreenKey, now);
}

/// At start-up: back into full screen if the app was left in it.
Future<void> restoreFullscreen() async {
  if (!isDesktop) return;
  if ((await SharedPreferences.getInstance()).getBool(_fullscreenKey) ?? false) fullscreen.value = await setFullscreen(true);
}

/// Desktop: borderless full screen on/off - use [toggleFullscreen], which keeps [fullscreen] and the setting.
/// Returns whether it is now full screen.
Future<bool> setFullscreen(bool on) async {
  try {
    return await _channel.invokeMethod<bool>('fullscreen', on) ?? false;
  } catch (_) {
    return false;
  }
}

/// Only a phone or tablet turns; a PC window doesn't, so the reader's rotation lock is Android only.
bool get canRotate => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// The battery for the reader's clock: (level 0..100, charging), or null where there's none to read (a desktop PC,
/// the web).
Future<(int, bool)?> batteryState() async {
  try {
    final m = await _channel.invokeMethod<Map<Object?, Object?>>('battery');
    if (m == null) return null;
    return ((m['level'] as num).toInt(), m['charging'] == true);
  } catch (_) {
    return null;
  }
}

/// Whether the device is on Wi-Fi (or a cable) rather than mobile data - Downloads' "Wi-Fi only". A PC, the web, or
/// a check that fails count as Wi-Fi: better a download than a queue stuck for no reason.
Future<bool> onWifi() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return true;
  try {
    final n = await _channel.invokeMethod<String>('network');
    return n == null || n == 'wifi';
  } catch (_) {
    return true;
  }
}

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

/// The app's private folder for downloads (Android app storage; Windows %LOCALAPPDATA%\KomgaReader). Null where
/// there is none (web).
Future<String?> appStorageDir() async {
  try {
    return await _channel.invokeMethod<String>('storageDir');
  } catch (_) {
    return null;
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
