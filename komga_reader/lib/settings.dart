import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'errors.dart';
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

/// How a page change looks - not how it's triggered: tap, swipe and the arrows turn pages in all of them. Listed in
/// the order shown (None, Wipe, Curl); the names are what's saved, so they stay as they were.
enum PageTurn { flip, swipe, curl }

extension PageTurnLabel on PageTurn {
  String get label => switch (this) {
        PageTurn.flip => 'None',
        PageTurn.swipe => 'Wipe',
        PageTurn.curl => 'Curl',
      };
}

/// Next book before the last page: ask whether to mark this one read (the original behaviour), or don't ask.
enum MidBook { ask, markRead, keep }

extension MidBookLabel on MidBook {
  String get label => switch (this) { MidBook.ask => 'Ask', MidBook.markRead => 'Mark read', MidBook.keep => 'No change' };
}

/// What's around the page in the reader.
enum ReaderBackground { black, grey, white }

extension ReaderBackgroundLabel on ReaderBackground {
  String get label => switch (this) {
        ReaderBackground.black => 'Black',
        ReaderBackground.grey => 'Dark grey',
        ReaderBackground.white => 'White',
      };
  Color get colour => switch (this) {
        ReaderBackground.black => const Color(0xFF000000),
        ReaderBackground.grey => const Color(0xFF2B2C30),
        ReaderBackground.white => const Color(0xFFFFFFFF),
      };

  /// Text and icons drawn straight on the background (the end card, a page that didn't load).
  Color get ink => this == ReaderBackground.white ? const Color(0xFF1A1A1A) : const Color(0xFFFFFFFF);
}

/// The reader's rotation: follow the device (as the rest of the app does), or hold portrait or landscape.
enum Rotation { auto, portrait, landscape }

extension RotationLabel on Rotation {
  String get label => switch (this) { Rotation.auto => 'Auto', Rotation.portrait => 'Portrait', Rotation.landscape => 'Landscape' };
}

/// When the reader shows something extra (the clock and battery): never, only with the controls up, or always.
enum ShowWhen { off, withControls, always }

extension ShowWhenLabel on ShowWhen {
  String get label =>
      switch (this) { ShowWhen.off => 'Off', ShowWhen.withControls => 'With the controls', ShowWhen.always => 'Always' };
}

/// The app's accent colour (buttons, switches, highlights): pale tones that read on the dark background.
enum Accent { blue, teal, green, amber, orange, pink, purple }

extension AccentColour on Accent {
  Color get colour => switch (this) {
        Accent.blue => const Color(0xFF8AB4F8),
        Accent.teal => const Color(0xFF5DCAA5),
        Accent.green => const Color(0xFF97C459),
        Accent.amber => const Color(0xFFEFB04A),
        Accent.orange => const Color(0xFFF0997B),
        Accent.pink => const Color(0xFFED93B1),
        Accent.purple => const Color(0xFFAFA9EC),
      };
  String get label => '${name[0].toUpperCase()}${name.substring(1)}';
}

/// Library grids and Home's rows: how big the posters are.
enum PosterSize { small, medium, large }

extension PosterSizeLabel on PosterSize {
  String get label => switch (this) { PosterSize.small => 'Small', PosterSize.medium => 'Medium', PosterSize.large => 'Large' };
  double get scale => switch (this) { PosterSize.small => 0.8, PosterSize.medium => 1.0, PosterSize.large => 1.3 };
}

/// App-wide display settings: kept on this device only (a phone and the tablet need different brightness).
@immutable
class DisplayPrefs {
  const DisplayPrefs({this.night = false, this.warmth = 0.5, this.brightness, this.pageTurn = PageTurn.swipe,
      this.pageNumber = true, this.doubleTapZoom = true, this.volumeKeys = true, this.midBook = MidBook.ask,
      this.background = ReaderBackground.black, this.screenOn = 0, this.posterSize = PosterSize.medium,
      this.posterTitleOnly = false, this.rotation = Rotation.auto, this.clock = ShowWhen.withControls,
      this.progressBar = false, this.nightSchedule = false, this.nightFrom = 21 * 60, this.nightTo = 7 * 60,
      this.textScale = 1.0, this.accent = Accent.blue});
  final bool night;
  final bool nightSchedule; // night mode on at [nightFrom] and off at [nightTo] by itself (still switchable by hand)
  final int nightFrom, nightTo; // minutes after midnight
  final double textScale; // this app's text size, on top of the device's (one of [textScales])
  final Accent accent;

  static const textScales = [0.9, 1.0, 1.15, 1.3];
  final Rotation rotation; // reader: follow the device, or hold portrait / landscape (Android)
  final ShowWhen clock; // reader: the time and battery - top right, or on the top bar with the controls up
  final bool progressBar; // reader: a thin line along the bottom while the controls are hidden (their slider shows it)
  final bool pageNumber; // reader: flash "12 / 36" in the corner for a moment after each page turn (this device)
  final bool doubleTapZoom; // reader, fit screen: double-tap zooms in on the spot (single taps then wait a moment)
  final bool volumeKeys; // reader, Android: volume down = next page, volume up = previous
  final MidBook midBook; // reader: Next book before the last page
  final ReaderBackground background; // reader: around the page
  final int screenOn; // reader: minutes the screen stays on after the last page turn; 0 = the system's timeout
  final PosterSize posterSize; // library grids and Home's rows
  final bool posterTitleOnly; // book posters: just the title, not "Series #N" over it

  static const alwaysOn = -1; // [screenOn]: as long as a book is open
  static const screenOnChoices = [0, 5, 10, 20, 30, alwaysOn];
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
          bool? pageNumber, bool? doubleTapZoom, bool? volumeKeys, MidBook? midBook, ReaderBackground? background,
          int? screenOn, PosterSize? posterSize, bool? posterTitleOnly, Rotation? rotation, ShowWhen? clock,
          bool? progressBar, bool? nightSchedule, int? nightFrom, int? nightTo, double? textScale, Accent? accent}) =>
      DisplayPrefs(
          nightSchedule: nightSchedule ?? this.nightSchedule, nightFrom: nightFrom ?? this.nightFrom,
          nightTo: nightTo ?? this.nightTo, textScale: textScale ?? this.textScale, accent: accent ?? this.accent,
          rotation: rotation ?? this.rotation, clock: clock ?? this.clock, progressBar: progressBar ?? this.progressBar,
          night: night ?? this.night, warmth: warmth ?? this.warmth,
          brightness: brightness != null ? brightness() : this.brightness, pageTurn: pageTurn ?? this.pageTurn,
          pageNumber: pageNumber ?? this.pageNumber, doubleTapZoom: doubleTapZoom ?? this.doubleTapZoom,
          volumeKeys: volumeKeys ?? this.volumeKeys, midBook: midBook ?? this.midBook,
          background: background ?? this.background, screenOn: screenOn ?? this.screenOn,
          posterSize: posterSize ?? this.posterSize, posterTitleOnly: posterTitleOnly ?? this.posterTitleOnly);

  Map<String, dynamic> toJson() => {'night': night, 'warmth': warmth, 'brightness': brightness,
      'pageTurn': pageTurn.name, 'pageNumber': pageNumber, 'doubleTapZoom': doubleTapZoom, 'volumeKeys': volumeKeys,
      'midBook': midBook.name, 'background': background.name, 'screenOn': screenOn, 'posterSize': posterSize.name,
      'posterTitleOnly': posterTitleOnly, 'rotation': rotation.name, 'clock': clock.name, 'progressBar': progressBar,
      'nightSchedule': nightSchedule, 'nightFrom': nightFrom, 'nightTo': nightTo, 'textScale': textScale,
      'accent': accent.name};
  factory DisplayPrefs.fromJson(Map<String, dynamic> j) {
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.firstWhere((v) => v.name == name, orElse: () => fallback);
    final on = j['screenOn'];
    int minutes(Object? v, int fallback) => v is int && v >= 0 && v < 24 * 60 ? v : fallback;
    return DisplayPrefs(
        night: j['night'] == true, warmth: (j['warmth'] as num?)?.toDouble() ?? 0.5,
        brightness: (j['brightness'] as num?)?.toDouble(),
        pageTurn: pick(PageTurn.values, j['pageTurn'], PageTurn.swipe),
        // on unless switched off
        pageNumber: j['pageNumber'] != false, doubleTapZoom: j['doubleTapZoom'] != false,
        volumeKeys: j['volumeKeys'] != false,
        midBook: pick(MidBook.values, j['midBook'], MidBook.ask),
        background: pick(ReaderBackground.values, j['background'], ReaderBackground.black),
        // default Off (user, 2026-09-30): "always on" drained the tablet's battery overnight when they fell asleep reading
        screenOn: on is int && screenOnChoices.contains(on) ? on : 0,
        posterSize: pick(PosterSize.values, j['posterSize'], PosterSize.medium),
        posterTitleOnly: j['posterTitleOnly'] == true,
        rotation: pick(Rotation.values, j['rotation'], Rotation.auto),
        clock: pick(ShowWhen.values, j['clock'], ShowWhen.withControls),
        progressBar: j['progressBar'] == true,
        nightSchedule: j['nightSchedule'] == true,
        nightFrom: minutes(j['nightFrom'], 21 * 60),
        nightTo: minutes(j['nightTo'], 7 * 60),
        textScale: textScales.contains(j['textScale']) ? (j['textScale'] as num).toDouble() : 1.0,
        accent: pick(Accent.values, j['accent'], Accent.blue));
  }
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

  /// A sync problem, in plain words; recorded in the error log when it changes (retries repeat it every minute).
  void _syncNote(String note, Object error) {
    if (note != syncError) ErrorLog.instance.record(note, error);
    syncError = note;
  }

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
      _syncNote('Using the settings saved on this device: ${explain(e).reason}.', e);
    }
  }

  void setSeries(String seriesId, ReaderPrefs prefs) {
    series[seriesId] = prefs;
    _dirtySeries.add(seriesId);
    _changedReader();
  }

  /// Whether a series has its own settings (else it follows the defaults).
  bool hasOwn(String seriesId) => series.containsKey(seriesId);

  /// One series back to following the defaults (Image settings ⋮ > Use the defaults). Synced.
  void useDefaults(String seriesId) {
    if (series.remove(seriesId) == null) return;
    _dirtySeries.add(seriesId); // sync removes it from Komga's copy
    _changedReader();
  }

  /// Every series back to following the defaults (Settings > Reading). Synced: other devices lose them too.
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
      _syncNote('Settings saved on this device, not on Komga yet: ${explain(e).reason}.', e);
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
