import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('komga_reader/screen');

/// Windows / macOS / Linux app (mouse, keyboard, resizable window) rather than a phone or tablet.
bool get isDesktop =>
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.linux;

/// Only Android lets the app set the screen's backlight; elsewhere the brightness slider just dims.
bool get hasBacklightControl => defaultTargetPlatform == TargetPlatform.android;

/// Volume keys can turn pages: on Android the app sees them first, and a key it uses doesn't change the volume. On a
/// PC the system changes the volume whatever the app does, so they're left alone there.
bool get hasVolumeKeys => defaultTargetPlatform == TargetPlatform.android;

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
bool get canRotate => defaultTargetPlatform == TargetPlatform.android;

/// The battery for the reader's clock: (level 0..100, charging), or null where there's none to read (a desktop PC).
Future<(int, bool)?> batteryState() async {
  try {
    final m = await _channel.invokeMethod<Map<Object?, Object?>>('battery');
    if (m == null) return null;
    return ((m['level'] as num).toInt(), m['charging'] == true);
  } catch (_) {
    return null;
  }
}

/// Whether the device is on Wi-Fi (or a cable) rather than mobile data - Downloads' "Wi-Fi only". A PC, or a check
/// that fails, count as Wi-Fi: better a download than a queue stuck for no reason.
Future<bool> onWifi() async {
  if (defaultTargetPlatform != TargetPlatform.android) return true;
  try {
    final n = await _channel.invokeMethod<String>('network');
    return n == null || n == 'wifi';
  } catch (_) {
    return true;
  }
}

/// Stops the tablet from dimming and sleeping while a book is open (Android; a no-op on Windows).
Future<void> keepScreenOn(bool on) async {
  try {
    await _channel.invokeMethod('keepOn', on);
  } catch (_) {
    // no native side on this platform
  }
}

/// The readers' rotation lock (Settings > Reader > Rotation, and the readers' panels - user, 2026-10-07): Portrait
/// or Landscape held exactly one way up, the tablet turning doesn't move it. The way up is the screen's when the
/// lock starts (opening a book with it on, or choosing it), so it starts the way the tablet is held; choosing it
/// again turns it over (180°) - to read upside down on purpose. The way up isn't stored: only Auto / Portrait /
/// Landscape is. Auto: the device's own way.
class OrientationLock {
  OrientationLock._();
  static final instance = OrientationLock._();

  bool? _portrait; // the axis held: true portrait, false landscape, null none
  bool _flipped = false; // the other way up of it (portrait down, landscape right)

  bool get held => _portrait != null;

  /// [portrait] or [landscape] held (a new axis starts the way the screen is up now), or neither: the device's way.
  Future<void> hold({required bool portrait, required bool landscape}) async {
    if (!portrait && !landscape) {
      _portrait = null;
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      return;
    }
    if (_portrait != portrait) {
      _portrait = portrait;
      _flipped = await _upsideDownNow(portrait);
    }
    await _apply();
  }

  /// The lock turned over (the choice tapped again). Nothing when no lock is held.
  Future<void> flip() async {
    if (_portrait == null) return;
    _flipped = !_flipped;
    await _apply();
  }

  /// The book closed: the app follows the device again.
  Future<void> release() async {
    _portrait = null;
    await SystemChrome.setPreferredOrientations(const []);
  }

  /// The screen is now the other way up of [portrait] / landscape (Android; elsewhere: no).
  Future<bool> _upsideDownNow(bool portrait) async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      final now = await _channel.invokeMethod<String>('currentWayUp');
      return now == (portrait ? 'reversePortrait' : 'reverseLandscape');
    } catch (_) {
      return false; // not known: the usual way up
    }
  }

  // one orientation, exactly (on Android: PORTRAIT / REVERSE_PORTRAIT / LANDSCAPE / REVERSE_LANDSCAPE - fixed, not
  // the sensor's)
  Future<void> _apply() => SystemChrome.setPreferredOrientations([
        switch ((_portrait!, _flipped)) {
          (true, false) => DeviceOrientation.portraitUp,
          (true, true) => DeviceOrientation.portraitDown,
          (false, false) => DeviceOrientation.landscapeLeft,
          (false, true) => DeviceOrientation.landscapeRight,
        },
      ]);
}

/// The screen's current brightness 0..1 (this app's own level if set, else the tablet's). Null where unknown.
Future<double?> getScreenBrightness() async {
  try {
    return (await _channel.invokeMethod<num>('getBrightness'))?.toDouble();
  } catch (_) {
    return null;
  }
}

/// Installed app version, e.g. "0.1.0 (build 17)". Null where unknown.
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

/// The app's private folder for downloads (Android app storage; Windows %LOCALAPPDATA%\KomgaReader). Null if the
/// platform side can't say.
Future<String?> appStorageDir() async {
  try {
    return await _channel.invokeMethod<String>('storageDir');
  } catch (_) {
    return null;
  }
}

// ---- Save page / Copy page (the reader, user 2026-10-02): the page's own image file, as Komga sends it ----------

/// Save and Copy are there to be had: Android and Windows.
bool get canSaveCopyPictures =>
    defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.windows;

/// What a picture file is, from its first bytes: (file extension, MIME type). Unknown: a JPEG, as Komga's pages
/// mostly are.
(String, String) pictureType(Uint8List b) {
  bool starts(List<int> sig, [int at = 0]) =>
      b.length >= at + sig.length && [for (var i = 0; i < sig.length; i++) b[at + i] == sig[i]].every((x) => x);
  if (starts([0x89, 0x50, 0x4E, 0x47])) return ('png', 'image/png');
  if (starts([0x52, 0x49, 0x46, 0x46]) && starts([0x57, 0x45, 0x42, 0x50], 8)) return ('webp', 'image/webp');
  if (starts([0x47, 0x49, 0x46, 0x38])) return ('gif', 'image/gif');
  return ('jpg', 'image/jpeg');
}

/// A file name Windows and Android both accept: no \ / : * ? " < > | and no trailing dots or spaces.
String safeFileName(String name) =>
    name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').replaceAll(RegExp(r'[. ]+$'), '').trim();

/// Saves a picture where the device keeps pictures - Android: the Pictures/BeDeReader album; Windows:
/// Pictures\BeDeReader (" (2)" etc. added if the name is taken). [name] without its extension. Returns where it went,
/// for the message.
Future<String> savePicture(Uint8List bytes, String name) async {
  final (ext, mime) = pictureType(bytes);
  final file = '${safeFileName(name)}.$ext';
  if (defaultTargetPlatform == TargetPlatform.android) {
    final where = await _channel.invokeMethod<String>('savePicture', {'bytes': bytes, 'name': file, 'mime': mime});
    if (where == null) throw StateError('nowhere to save pictures');
    return where;
  }
  final dir = await _channel.invokeMethod<String>('picturesDir');
  if (dir == null) throw StateError('no Pictures folder');
  final dot = file.lastIndexOf('.');
  var path = '$dir${Platform.pathSeparator}$file';
  for (var n = 2; await File(path).exists(); n++) {
    path = '$dir${Platform.pathSeparator}${file.substring(0, dot)} ($n)${file.substring(dot)}';
  }
  await File(path).writeAsBytes(bytes, flush: true);
  return path;
}

/// Puts a picture on the clipboard. Windows: as a bitmap and as PNG (what Paint, Office and browsers paste);
/// Android: as an image (shared from the app's cache).
Future<void> copyPicture(Uint8List bytes, String name) async {
  final (ext, mime) = pictureType(bytes);
  if (defaultTargetPlatform == TargetPlatform.android) {
    final ok = await _channel.invokeMethod<bool>('copyPicture',
        {'bytes': bytes, 'name': '${safeFileName(name)}.$ext', 'mime': mime});
    if (ok != true) throw StateError('the clipboard took nothing');
    return;
  }
  final codec = await ui.instantiateImageCodec(bytes);
  final image = (await codec.getNextFrame()).image;
  try {
    final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
    final png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    final ok = await _channel.invokeMethod<bool>('copyPicture',
        {'width': image.width, 'height': image.height, 'rgba': rgba, 'png': png});
    if (ok != true) throw StateError('the clipboard took nothing');
  } finally {
    image.dispose();
    codec.dispose();
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
