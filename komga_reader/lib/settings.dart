import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'screen.dart';

enum FitMode { screen, width, height }

extension FitModeLabel on FitMode {
  String get label => switch (this) { FitMode.screen => 'Screen', FitMode.width => 'Width', FitMode.height => 'Height' };
}

/// Page order for a series: follow Komga's reading direction for it (auto), or force one.
enum ReadingDirection { auto, ltr, rtl }

extension ReadingDirectionLabel on ReadingDirection {
  String get label =>
      switch (this) { ReadingDirection.auto => 'Auto', ReadingDirection.ltr => 'Left to right', ReadingDirection.rtl => 'Right to left' };
}

/// How pages are shown. Saved per series (a new series starts from the global default) and synced through Komga.
@immutable
class ReaderPrefs {
  const ReaderPrefs({this.fit = FitMode.screen, this.brightness = 0, this.contrast = 0, this.sharpen = false,
      this.autoLevels = false, this.direction = ReadingDirection.auto, this.crop = 0});

  final FitMode fit;
  final ReadingDirection direction; // auto = the series' reading direction in Komga
  final double brightness; // -0.5 .. 0.5, added to every channel
  final double contrast; // -0.5 .. 0.5, stretch around mid-grey
  final bool sharpen; // shown as "Enhance": denoise + Lanczos scaling + RCAS (lib/enhance.dart); key kept for sync
  final bool autoLevels; // shown as "Enhance colours": auto-levels + whiten paper + deepen ink (lib/enhance.dart)
  final double crop; // "Crop edges": this fraction of the page cut off every side (0 .. 0.1)

  static const maxCrop = 0.10;

  bool get neutralImage => brightness == 0 && contrast == 0 && !sharpen && !autoLevels && crop == 0;

  ReaderPrefs copyWith({FitMode? fit, double? brightness, double? contrast, bool? sharpen, bool? autoLevels,
          ReadingDirection? direction, double? crop}) =>
      ReaderPrefs(fit: fit ?? this.fit, brightness: brightness ?? this.brightness, contrast: contrast ?? this.contrast,
          sharpen: sharpen ?? this.sharpen, autoLevels: autoLevels ?? this.autoLevels,
          direction: direction ?? this.direction, crop: crop ?? this.crop);

  /// Same fit and direction, image settings back to neutral.
  ReaderPrefs imageReset() => ReaderPrefs(fit: fit, direction: direction);

  Map<String, dynamic> toJson() =>
      {'fit': fit.name, 'b': brightness, 'c': contrast, 's': sharpen, 'l': autoLevels, 'd': direction.name, 'x': crop};

  factory ReaderPrefs.fromJson(Map<String, dynamic> j) => ReaderPrefs(
        fit: FitMode.values.firstWhere((f) => f.name == j['fit'], orElse: () => FitMode.screen),
        brightness: (j['b'] as num?)?.toDouble() ?? 0,
        contrast: (j['c'] as num?)?.toDouble() ?? 0,
        sharpen: j['s'] == true || (j['s'] is num && (j['s'] as num) > 0), // was a 0..1 slider in build 4
        autoLevels: j['l'] == true,
        direction: ReadingDirection.values.firstWhere((d) => d.name == j['d'], orElse: () => ReadingDirection.auto),
        crop: ((j['x'] as num?)?.toDouble() ?? 0).clamp(0.0, maxCrop),
      );

  @override
  bool operator ==(Object other) => other is ReaderPrefs && jsonEncode(other.toJson()) == jsonEncode(toJson());
  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// How a page change looks - not how it's triggered: tap, swipe and the arrows turn pages in all of them.
enum PageTurn { swipe, flip, curl }

extension PageTurnLabel on PageTurn {
  String get label => switch (this) {
        PageTurn.swipe => 'Wipe',
        PageTurn.flip => 'Instant flip',
        PageTurn.curl => '3D page curl',
      };
}

/// App-wide display settings: kept on this device only (a phone and the tablet need different brightness).
@immutable
class DisplayPrefs {
  const DisplayPrefs({this.night = false, this.warmth = 0.5, this.brightness, this.pageTurn = PageTurn.swipe,
      this.pageNumber = true});
  final bool night;
  final bool pageNumber; // reader: flash "12 / 36" in the corner for a moment after each page turn (this device)
  final PageTurn pageTurn; // reader page-turn animation (this device)
  final double warmth; // 0..1, how amber night mode is
  final double? brightness; // null = follow the system; 0..1 where the bottom [dimZone] goes below the minimum

  static const dimZone = 0.2;

  /// Screen backlight for this app's window: -1 = system setting, else 0.01..1.
  /// Android can set the backlight; on desktop the whole slider is a dimming layer (0 = darkest, 1 = none).
  static bool backlightControl = hasBacklightControl;

  double get backlight {
    final b = brightness;
    if (b == null || !backlightControl) return -1;
    if (b <= dimZone) return 0.01;
    return 0.01 + (b - dimZone) / (1 - dimZone) * 0.99;
  }

  /// Slider position that gives this backlight level (the inverse of [backlight]).
  static double sliderFor(double backlight) =>
      dimZone + ((backlight - 0.01) / 0.99).clamp(0.0, 1.0) * (1 - dimZone);

  /// Black overlay opacity for "darker than the minimum".
  double get dimOverlay {
    final b = brightness;
    if (b == null) return 0;
    if (!backlightControl) return (1 - b) * 0.75;
    if (b >= dimZone) return 0;
    return (dimZone - b) / dimZone * 0.75;
  }

  DisplayPrefs copyWith({bool? night, double? warmth, double? Function()? brightness, PageTurn? pageTurn,
          bool? pageNumber}) =>
      DisplayPrefs(
          night: night ?? this.night, warmth: warmth ?? this.warmth,
          brightness: brightness != null ? brightness() : this.brightness, pageTurn: pageTurn ?? this.pageTurn,
          pageNumber: pageNumber ?? this.pageNumber);

  Map<String, dynamic> toJson() =>
      {'night': night, 'warmth': warmth, 'brightness': brightness, 'pageTurn': pageTurn.name, 'pageNumber': pageNumber};
  factory DisplayPrefs.fromJson(Map<String, dynamic> j) => DisplayPrefs(
      night: j['night'] == true, warmth: (j['warmth'] as num?)?.toDouble() ?? 0.5,
      brightness: (j['brightness'] as num?)?.toDouble(),
      pageTurn: PageTurn.values.firstWhere((t) => t.name == j['pageTurn'], orElse: () => PageTurn.swipe),
      pageNumber: j['pageNumber'] != false); // on unless switched off
}

/// Holds reader prefs (global default + per series, synced to the user's Komga client settings) and display prefs
/// (this device). Changes apply immediately; the Komga copy is written a moment later, merged with whatever is on
/// the server so two devices don't wipe each other's series.
class AppSettings extends ChangeNotifier {
  AppSettings._();
  static final AppSettings instance = AppSettings._();

  static const komgaKey = 'komgareader.readerprefs';
  static const _localReader = 'readerPrefs';
  static const _localDisplay = 'displayPrefs';

  Komga? _api;
  ReaderPrefs defaults = const ReaderPrefs();
  final Map<String, ReaderPrefs> series = {};
  DisplayPrefs display = const DisplayPrefs();
  String? syncError; // last Komga sync problem, shown in the Display panel

  final Set<String> _dirtySeries = {};
  bool _dirtyDefault = false;
  Timer? _syncTimer;

  /// Switch connection (online / offline) without reloading; a failed sync retries on its own.
  void useApi(Komga api) {
    _api = api;
    if (_dirtySeries.isNotEmpty || _dirtyDefault) {
      _syncTimer?.cancel();
      _syncTimer = Timer(const Duration(seconds: 2), _sync);
    }
  }

  ReaderPrefs prefsFor(String? seriesId) => (seriesId != null ? series[seriesId] : null) ?? defaults;

  /// Local copy first (instant), then the Komga copy replaces it if the server has one.
  Future<void> load(Komga api) async {
    _api = api;
    final p = await SharedPreferences.getInstance();
    final d = p.getString(_localDisplay);
    if (d != null) display = DisplayPrefs.fromJson(jsonDecode(d) as Map<String, dynamic>);
    final r = p.getString(_localReader);
    if (r != null) _applyBlob(jsonDecode(r) as Map<String, dynamic>);
    applyBacklight();
    notifyListeners();
    try {
      final remote = await _fetchRemote();
      if (remote != null) {
        _applyBlob(remote);
        await p.setString(_localReader, jsonEncode(_blob()));
        notifyListeners();
      }
      syncError = null;
    } catch (e) {
      syncError = 'Could not read settings from Komga: $e';
    }
  }

  void setSeries(String seriesId, ReaderPrefs prefs) {
    series[seriesId] = prefs;
    _dirtySeries.add(seriesId);
    _changedReader();
  }

  /// Every series back to following the defaults (App settings > Reading). Synced: other devices lose them too.
  void resetAllSeries() {
    _dirtySeries.addAll(series.keys); // sync removes each from Komga's copy
    series.clear();
    _changedReader();
  }

  void setDefault(ReaderPrefs prefs) {
    defaults = prefs;
    _dirtyDefault = true;
    _changedReader();
  }

  void setDisplay(DisplayPrefs d) {
    final backlightChanged = d.backlight != display.backlight;
    display = d;
    if (backlightChanged) applyBacklight();
    notifyListeners();
    SharedPreferences.getInstance().then((p) => p.setString(_localDisplay, jsonEncode(d.toJson())));
  }

  void applyBacklight() => setScreenBrightness(display.backlight);

  void _changedReader() {
    notifyListeners();
    SharedPreferences.getInstance().then((p) => p.setString(_localReader, jsonEncode(_blob())));
    _syncTimer?.cancel();
    _syncTimer = Timer(const Duration(seconds: 2), _sync);
  }

  Future<void> _sync() async {
    final api = _api;
    if (api == null || (_dirtySeries.isEmpty && !_dirtyDefault)) return;
    final sending = Set<String>.of(_dirtySeries);
    final sendDefault = _dirtyDefault;
    try {
      final merged = await _fetchRemote() ?? <String, dynamic>{};
      final remoteSeries = Map<String, dynamic>.from((merged['series'] as Map?) ?? {});
      for (final id in sending) {
        final p = series[id];
        if (p == null) { remoteSeries.remove(id); } else { remoteSeries[id] = p.toJson(); }
      }
      merged['v'] = 1;
      merged['series'] = remoteSeries;
      if (sendDefault || merged['default'] == null) merged['default'] = defaults.toJson();
      await api.putClientSetting(komgaKey, jsonEncode(merged));
      _dirtySeries.removeAll(sending);
      if (sendDefault) _dirtyDefault = false;
      syncError = null;
    } catch (e) {
      syncError = 'Settings not saved to Komga yet (kept on this device): $e';
      _syncTimer = Timer(const Duration(minutes: 1), _sync);
    }
    notifyListeners();
  }

  Future<Map<String, dynamic>?> _fetchRemote() async {
    final raw = (await _api!.clientSettings())[komgaKey]?['value'];
    return raw is String ? jsonDecode(raw) as Map<String, dynamic> : null;
  }

  Map<String, dynamic> _blob() => {
        'v': 1,
        'default': defaults.toJson(),
        'series': {for (final e in series.entries) e.key: e.value.toJson()},
      };

  void _applyBlob(Map<String, dynamic> b) {
    final d = b['default'];
    if (d is Map<String, dynamic> && !_dirtyDefault) defaults = ReaderPrefs.fromJson(d);
    final s = b['series'];
    if (s is Map) {
      for (final e in s.entries) {
        if (_dirtySeries.contains(e.key)) continue; // a local change still waiting to be sent wins
        series[e.key as String] = ReaderPrefs.fromJson(Map<String, dynamic>.from(e.value as Map));
      }
    }
  }
}
