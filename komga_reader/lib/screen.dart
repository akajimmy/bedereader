import 'dart:io';
import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_log.dart';
import 'rotation.dart';

const _channel = MethodChannel('komga_reader/screen');

/// Windows / macOS / Linux app (mouse, keyboard, resizable window) rather than a phone or tablet.
bool get isDesktop =>
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.linux;

/// Android and iOS let the app set the screen's backlight (iOS: its native side puts the person's own level back when
/// the reader lets go or the app is left - user, 2026-10-22); on a PC the brightness slider just dims.
bool get hasBacklightControl =>
    defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

/// The device can say whether it's on mobile data (Downloads' "Wi-Fi only"): Android and iOS.
bool get knowsMobileData =>
    defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

/// The font for eBooks' "Device serif": Georgia on Windows and iOS (iOS has no font called "serif" - it fell back on
/// its sans), the system's serif on Android.
String get deviceSerifFamily =>
    defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.iOS
        ? 'Georgia'
        : 'serif';

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

/// A phone or tablet turns - and a Windows PC with a rotation sensor (a tablet, a 2-in-1; user, 2026-10-22: "lock,
/// where it can"); a desktop's screen doesn't, so no rotation lock there.
bool get canRotate =>
    defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS ||
    (defaultTargetPlatform == TargetPlatform.windows && _pcRotates);

bool _pcRotates = false;

/// Windows, at start: does this PC turn its screen by itself (a rotation sensor)? Asked once.
Future<void> checkPcRotation() async {
  if (defaultTargetPlatform != TargetPlatform.windows) return;
  try {
    _pcRotates = await _channel.invokeMethod<bool>('canRotate') ?? false;
  } catch (_) {
    _pcRotates = false;
  }
}

/// iOS: the rotation lock is Auto / Locked - Locked holds the screen the way it is (user, 2026-10-22: "two: auto and
/// locked"; an app can't switch the device's own lock). Android: Auto / Portrait / Landscape.
bool get rotationLocksOnly => defaultTargetPlatform == TargetPlatform.iOS;

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
  if (!knowsMobileData) return true;
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

/// The readers' rotation lock (Settings > Comics > Rotation, and the readers' panels - user, 2026-10-07): Portrait
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
      if (defaultTargetPlatform == TargetPlatform.windows) return _pcHold('none');
      if (defaultTargetPlatform == TargetPlatform.android) return AutoRotation.instance.follow(); // (the app's own)
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

  /// iOS's Locked. [chosen] (Locked picked just now): the screen held the way it is now, and that way kept on this
  /// device. A book opened with Locked on: the way kept - locked in landscape, the next book opened with the iPad
  /// upright was held upright (user, 2026-10-25); the way it is now only if none is kept yet. Looked at again a moment
  /// after it's chosen: if the screen turned over instead (iOS may name its two landscapes the other way round from
  /// Android's - not checkable here), the other one.
  Future<void> holdNow({bool chosen = true}) async {
    final kept = chosen ? null : (await SharedPreferences.getInstance()).getString(lockedKey);
    final way = kept ?? await _wayUp();
    if (way == null) return; // not known: nothing held
    _portrait = way == 'portrait' || way == 'reversePortrait';
    _flipped = way.startsWith('reverse');
    await _apply();
    if (kept != null) return; // (kept as it was found to be, the check below done then)
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (_portrait == null) return; // let go meanwhile
    final now = await _wayUp();
    AppLog.instance.info('rotation', 'Locked: the screen was $way, a moment later ${now ?? 'not known'}');
    if (now != null && now == _opposite(way)) {
      _flipped = !_flipped;
      await _apply();
    }
    final held = switch ((_portrait!, _flipped)) {
      (true, false) => 'portrait',
      (true, true) => 'reversePortrait',
      (false, false) => 'landscape',
      (false, true) => 'reverseLandscape',
    };
    await (await SharedPreferences.getInstance()).setString(lockedKey, held);
  }

  /// The way iOS's Locked was last chosen in (this device).
  static const lockedKey = 'rotation.lockedWay';

  static String _opposite(String way) => switch (way) {
        'portrait' => 'reversePortrait',
        'reversePortrait' => 'portrait',
        'landscape' => 'reverseLandscape',
        _ => 'landscape',
      };

  /// The way the screen is up now (portrait, reversePortrait, landscape, reverseLandscape), or null.
  Future<String?> _wayUp() async {
    try {
      return await _channel.invokeMethod<String>('currentWayUp');
    } catch (_) {
      return null;
    }
  }

  /// The book closed: the app follows the device again.
  Future<void> release() async {
    if (_portrait != null) AppLog.instance.info('rotation', 'let go: the device turns the screen');
    _portrait = null;
    if (defaultTargetPlatform == TargetPlatform.windows) return _pcHold('none');
    if (defaultTargetPlatform == TargetPlatform.android) return AutoRotation.instance.follow();
    await SystemChrome.setPreferredOrientations(const []);
  }

  /// Windows: Flutter's orientations do nothing there - the runner asks Windows itself (its auto-rotation
  /// preference: portrait, landscape, their flipped ways, or none).
  Future<void> _pcHold(String way) async {
    try {
      await _channel.invokeMethod('holdOrientation', way);
    } catch (_) {
      // no native side: nothing held
    }
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
  Future<void> _apply() async {
    if (defaultTargetPlatform == TargetPlatform.android) await AutoRotation.instance.stop(); // the lock's now
    if (_portrait == null) return; // let go meanwhile
    await _hold();
  }

  Future<void> _hold() {
    // (rotation Locked unchecked on iOS - backlog)
    AppLog.instance.info('rotation', 'held ${_portrait! ? 'portrait' : 'landscape'}${_flipped ? ', the other way up' : ''}');
    return _holdNow();
  }

  Future<void> _holdNow() => defaultTargetPlatform == TargetPlatform.windows
      ? _pcHold(switch ((_portrait!, _flipped)) {
          (true, false) => 'portrait',
          (true, true) => 'reversePortrait',
          (false, false) => 'landscape',
          (false, true) => 'reverseLandscape',
        })
      : SystemChrome.setPreferredOrientations([
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

/// Installed app version as (name, build number), e.g. ("1.4.0", 134) - for the update check. Null where unknown.
Future<(String, int)?> appVersionInfo() async {
  try {
    final v = await _channel.invokeMapMethod<String, Object?>('appVersion');
    final name = v?['name'], code = v?['code'];
    if (name is! String || code is! num) return null;
    return (name, code.toInt());
  } catch (_) {
    return null;
  }
}

/// The app's own background, where no book sets another (lib/main.dart's scaffold colour).
const appBackground = Color(0xFF0B0B0C);

/// Windows: the title bar in [colour] - the colour of what's right under it (user, 2026-10-22: "the colour of the
/// title bar should match the colour of the background"); dark or light text to suit. Elsewhere, nothing.
Future<void> setTitleBarColour(Color colour) async {
  if (defaultTargetPlatform != TargetPlatform.windows) return;
  try {
    await _channel.invokeMethod('titleBar', colour.toARGB32());
  } catch (_) {
    // no native side
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
    final dir = await _channel.invokeMethod<String>('storageDir');
    if (dir != null && defaultTargetPlatform == TargetPlatform.iOS && !_backupAsked) {
      _backupAsked = true;
      await _keepOutOfBackup(dir);
    }
    return dir;
  } catch (_) {
    return null;
  }
}

/// iOS: the app's own folder the Files app shows (On My iPad > the app's name) - books copied in there, by the Files
/// app or Apple Devices over USB, make local libraries on this device (experimental/sources). Null elsewhere, or not
/// answered.
Future<String?> appDocumentsDir() async {
  if (defaultTargetPlatform != TargetPlatform.iOS) return null;
  try {
    return await _channel.invokeMethod<String>('documentsDir');
  } catch (_) {
    return null;
  }
}

/// iOS: the app's folder (the downloads, a few GB maybe) kept out of iCloud backup - iOS backs up Application Support
/// unless told not to, against the person's iCloud storage, and the books are on Komga anyway (backlog, 2026-10-25:
/// "left out of iCloud backup" was never done). Asked once a run (a folder made again is marked again); said in the
/// app's log.
Future<void> _keepOutOfBackup(String dir) async {
  try {
    final ok = await _channel.invokeMethod<bool>('excludeFromBackup', dir);
    AppLog.instance.info('storage', ok == true ? 'kept out of iCloud backup' : 'could not be kept out of iCloud backup');
  } catch (e) {
    AppLog.instance.warn('storage', 'could not be kept out of iCloud backup: $e');
  }
}

bool _backupAsked = false;

/// Tests: as at start-up, not asked yet this run.
@visibleForTesting
void resetBackupAsked() => _backupAsked = false;

// ---- Save page / Copy page (the reader, user 2026-10-02): the page's own image file, as Komga sends it ----------

/// Save and Copy are there to be had: Android, Windows and iOS (Photos, and the clipboard).
bool get canSaveCopyPictures =>
    defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// The phone or tablet's own side saves and copies the picture as it is (Android, iOS); Windows gets a file path and
/// pixels.
bool get _picturesNative =>
    defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

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

/// Saves a picture where the device keeps pictures - Android: the Pictures/BeDeReader album; iOS: Photos; Windows:
/// Pictures\BeDeReader (" (2)" etc. added if the name is taken). [name] without its extension. Returns where it went,
/// for the message.
Future<String> savePicture(Uint8List bytes, String name) async {
  final (ext, mime) = pictureType(bytes);
  final file = '${safeFileName(name)}.$ext';
  if (_picturesNative) {
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
  if (_picturesNative) {
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
/// else 0.01..1. Android; iOS (the screen's, put back as it was on -1 or when the app is left); a no-op on a PC.
Future<void> setScreenBrightness(double value) async {
  try {
    await _channel.invokeMethod('brightness', value);
  } catch (_) {
    // no native side on this platform
    return;
  }
  // in the app's log (brightness unchecked on iOS - backlog): following the system, or a level - a slider being
  // dragged once every 2 s at most, with what the screen says it's at
  final now = clock.now();
  if (value >= 0 && _brightnessLogged != null && now.difference(_brightnessLogged!) < const Duration(seconds: 2)) {
    return;
  }
  _brightnessLogged = value < 0 ? null : now;
  final screen = await getScreenBrightness();
  AppLog.instance.info('brightness', '${value < 0 ? 'the system\'s own' : 'set to ${value.toStringAsFixed(2)}'}'
      '${screen == null ? '' : ' - the screen says ${screen.toStringAsFixed(2)}'}');
}

DateTime? _brightnessLogged;
