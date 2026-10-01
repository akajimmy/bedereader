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
      this.autoLevels = false, this.direction = ReadingDirection.auto, this.crop = 0, this.ownLayout = true,
      this.ownImage = true});

  /// A series' settings come in two parts, each overriding the defaults or not (the panels' "Override the
  /// defaults" toggles, user 2026-09-30): the page layout (fit, direction) and the image settings. A part not
  /// overridden follows the defaults. Series saved before this override both (unchanged). Unused on the defaults.
  final bool ownLayout, ownImage;

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
          ReadingDirection? direction, double? crop, bool? ownLayout, bool? ownImage}) =>
      ReaderPrefs(fit: fit ?? this.fit, brightness: brightness ?? this.brightness, contrast: contrast ?? this.contrast,
          sharpen: sharpen ?? this.sharpen, autoLevels: autoLevels ?? this.autoLevels,
          direction: direction ?? this.direction, crop: crop ?? this.crop, ownLayout: ownLayout ?? this.ownLayout,
          ownImage: ownImage ?? this.ownImage);

  /// Same fit and direction, image settings back to neutral.
  ReaderPrefs imageReset() => ReaderPrefs(fit: fit, direction: direction, ownLayout: ownLayout, ownImage: ownImage);

  /// This one's page layout (fit, direction) with [image]'s image settings.
  ReaderPrefs withImageOf(ReaderPrefs image) => copyWith(brightness: image.brightness, contrast: image.contrast,
      sharpen: image.sharpen, autoLevels: image.autoLevels, crop: image.crop);

  Map<String, dynamic> toJson() => {
        'fit': fit.name, 'b': brightness, 'c': contrast, 's': sharpen, 'l': autoLevels, 'd': direction.name, 'x': crop,
        // written only when off, so everything saved before (and the defaults) reads exactly as it did
        if (!ownLayout) 'ol': false,
        if (!ownImage) 'oi': false,
      };

  factory ReaderPrefs.fromJson(Map<String, dynamic> j) => ReaderPrefs(
        fit: FitMode.values.firstWhere((f) => f.name == j['fit'], orElse: () => FitMode.screen),
        brightness: (j['b'] as num?)?.toDouble() ?? 0,
        contrast: (j['c'] as num?)?.toDouble() ?? 0,
        sharpen: j['s'] == true || (j['s'] is num && (j['s'] as num) > 0), // was a 0..1 slider in build 4
        autoLevels: j['l'] == true,
        direction: ReadingDirection.values.firstWhere((d) => d.name == j['d'], orElse: () => ReadingDirection.auto),
        crop: ((j['x'] as num?)?.toDouble() ?? 0).clamp(0.0, maxCrop),
        ownLayout: j['ol'] != false,
        ownImage: j['oi'] != false,
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

/// The app's accent colour (buttons, switches, highlights): full-strength colours that still sit well on the dark
/// background (the "Rich" set, 2026-09-30 - the first, pale set was too muted). Listed in the order shown; the names
/// are what's saved, so the original seven keep theirs (purple is now a violet).
enum Accent { blue, sky, cyan, teal, green, lime, yellow, amber, orange, red, pink, fuchsia, purple, indigo }

extension AccentColour on Accent {
  Color get colour => switch (this) {
        Accent.blue => const Color(0xFF3B82F6),
        Accent.sky => const Color(0xFF0EA5E9),
        Accent.cyan => const Color(0xFF06B6D4),
        Accent.teal => const Color(0xFF14B8A6),
        Accent.green => const Color(0xFF22C55E),
        Accent.lime => const Color(0xFF84CC16),
        Accent.yellow => const Color(0xFFEAB308),
        Accent.amber => const Color(0xFFF59E0B),
        Accent.orange => const Color(0xFFF97316),
        Accent.red => const Color(0xFFEF4444),
        Accent.pink => const Color(0xFFEC4899),
        Accent.fuchsia => const Color(0xFFD946EF),
        Accent.purple => const Color(0xFF8B5CF6),
        Accent.indigo => const Color(0xFF6366F1),
      };

  /// Text and icons on the accent (a selected choice, a filled button): black on the light ones, white on the dark.
  Color get onColour => colour.computeLuminance() > 0.25 ? const Color(0xFF101012) : const Color(0xFFFFFFFF);

  String get label => this == Accent.purple ? 'Violet' : '${name[0].toUpperCase()}${name.substring(1)}';
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
      this.textScale = 1.0, this.accent = Accent.blue, this.pagePreviews = true});
  final bool night;
  /// reader: a picture of the page over the slider's thumb while picking one. Komga makes each from the book file as
  /// it's asked, so on a slow link to the books they lag (user, 2026-09-30): off, just the page number.
  final bool pagePreviews;
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
          bool? progressBar, bool? nightSchedule, int? nightFrom, int? nightTo, double? textScale, Accent? accent,
          bool? pagePreviews}) =>
      DisplayPrefs(
          pagePreviews: pagePreviews ?? this.pagePreviews,
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
      'accent': accent.name, 'pagePreviews': pagePreviews};
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
        accent: pick(Accent.values, j['accent'], Accent.blue),
        pagePreviews: j['pagePreviews'] != false); // on unless switched off
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

  // Changes not on Komga yet. Kept on the device too ([_unsentKey]): lost with the app closing (or offline), Komga's
  // older copy used to win at the next start and the change was gone (code review, 2026-09-30).
  static const _unsentKey = 'readerPrefs.unsent';
  final Set<String> _dirtySeries = {};
  bool _dirtyDefault = false;
  // how many times each entry has changed: a send only clears the entries that didn't change again while it was on
  // its way (a change made mid-send used to be marked sent without being sent)
  final Map<String, int> _versions = {};
  int _defaultVersion = 0;
  bool _syncing = false, _syncAgain = false; // one sync at a time; one asked for meanwhile runs after it
  Timer? _syncTimer;

  /// Switch connection (online / offline) without reloading; a failed sync retries on its own.
  void useApi(Komga api) {
    _api = api;
    if (_dirtySeries.isNotEmpty || _dirtyDefault) _syncSoon();
  }

  void _syncSoon([Duration after = const Duration(seconds: 2)]) {
    _syncTimer?.cancel();
    _syncTimer = Timer(after, _sync);
  }

  Future<void> _saveUnsent() async {
    final p = await SharedPreferences.getInstance();
    if (_dirtySeries.isEmpty && !_dirtyDefault) {
      await p.remove(_unsentKey);
    } else {
      await p.setString(_unsentKey, jsonEncode({'series': _dirtySeries.toList(), 'default': _dirtyDefault}));
    }
  }

  /// Signed out: the account's synced settings go from this device (they come back from Komga on signing in again);
  /// this device's own display settings stay (code review, 2026-09-30: they carried over to the next account).
  Future<void> clearAccount() async {
    _syncTimer?.cancel();
    _api = null;
    defaults = const ReaderPrefs();
    series.clear();
    _dirtySeries.clear();
    _dirtyDefault = false;
    _versions.clear();
    syncError = null;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.remove(_localReader);
    await p.remove(_unsentKey);
  }

  /// A series' settings as they apply: each part (page layout, image) its own when overridden, else the defaults'.
  ReaderPrefs prefsFor(String? seriesId) {
    final own = seriesId != null ? series[seriesId] : null;
    if (own == null) return defaults.copyWith(ownLayout: false, ownImage: false);
    final layout = own.ownLayout ? own : defaults;
    final image = own.ownImage ? own : defaults;
    return layout.withImageOf(image).copyWith(ownLayout: own.ownLayout, ownImage: own.ownImage);
  }

  bool ownsLayout(String seriesId) => series[seriesId]?.ownLayout ?? false;
  bool ownsImage(String seriesId) => series[seriesId]?.ownImage ?? false;

  /// The series' page layout (fit, direction) from [p] - overriding the defaults from now on.
  void setSeriesLayout(String seriesId, ReaderPrefs p) {
    final now = prefsFor(seriesId);
    setSeries(seriesId, now.copyWith(fit: p.fit, direction: p.direction, ownLayout: true, ownImage: now.ownImage));
  }

  /// The series' image settings from [p] - overriding the defaults from now on.
  void setSeriesImage(String seriesId, ReaderPrefs p) {
    final now = prefsFor(seriesId);
    setSeries(seriesId, now.withImageOf(p).copyWith(ownImage: true, ownLayout: now.ownLayout));
  }

  /// A panel's "Override the defaults" toggle. On: the part starts from the defaults' values (nothing on the page
  /// changes) and can then be set; off: the part follows the defaults again. Neither part overridden: the series
  /// follows the defaults entirely, and its entry goes (synced).
  void setOverride(String seriesId, {bool? layout, bool? image}) {
    final now = prefsFor(seriesId); // an overridden part keeps its values; one not overridden has the defaults'
    final next = now.copyWith(ownLayout: layout ?? now.ownLayout, ownImage: image ?? now.ownImage);
    if (!next.ownLayout && !next.ownImage) {
      useDefaults(seriesId);
    } else {
      setSeries(seriesId, next);
    }
  }

  /// Local copy first (instant), then Komga's copy: it's the truth for everything except this device's changes that
  /// haven't reached it yet - those stay, and are sent.
  /// [fetch] false (offline mode): this device's copy only - nothing is sent or asked for.
  Future<void> load(Komga api, {bool fetch = true}) async {
    _api = api;
    final p = await SharedPreferences.getInstance();
    final d = p.getString(_localDisplay);
    if (d != null) display = DisplayPrefs.fromJson(jsonDecode(d) as Map<String, dynamic>);
    try {
      final u = jsonDecode(p.getString(_unsentKey) ?? '{}') as Map;
      _dirtySeries
        ..clear()
        ..addAll([for (final id in (u['series'] as List? ?? const [])) id as String]);
      _dirtyDefault = u['default'] == true;
    } catch (_) {
      // damaged: nothing counts as unsent
    }
    final r = p.getString(_localReader);
    if (r != null) _applyBlob(jsonDecode(r) as Map<String, dynamic>, remote: false);
    applyBacklight();
    notifyListeners();
    if (!fetch) return; // offline mode: this device's copy; what's unsent goes once online (useApi)
    try {
      final remote = await _fetchRemote();
      if (remote != null) {
        _applyBlob(remote, remote: true);
        await p.setString(_localReader, jsonEncode(_blob()));
        notifyListeners();
      }
      syncError = null;
    } catch (e) {
      _syncNote('Using the settings saved on this device: ${explain(e).reason}.', e);
    }
    if (_dirtySeries.isNotEmpty || _dirtyDefault) _syncSoon(); // what didn't reach Komga last time goes now
  }

  void setSeries(String seriesId, ReaderPrefs prefs) {
    series[seriesId] = prefs;
    _dirty(seriesId);
    _changedReader();
  }

  void _dirty(String seriesId) {
    _dirtySeries.add(seriesId);
    _versions[seriesId] = (_versions[seriesId] ?? 0) + 1;
  }

  /// Whether a series has its own settings (else it follows the defaults).
  bool hasOwn(String seriesId) => series.containsKey(seriesId);

  /// One series back to following the defaults (Image settings ⋮ > Use the defaults). Synced.
  void useDefaults(String seriesId) {
    if (series.remove(seriesId) == null) return;
    _dirty(seriesId); // sync removes it from Komga's copy
    _changedReader();
  }

  /// Every series back to following the defaults (Settings > Reading). Synced: other devices lose them too.
  void resetAllSeries() {
    series.keys.forEach(_dirty); // sync removes each from Komga's copy
    series.clear();
    _changedReader();
  }

  void setDefault(ReaderPrefs prefs) {
    defaults = prefs;
    _dirtyDefault = true;
    _defaultVersion++;
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
    _saveUnsent();
    _syncSoon();
  }

  Future<void> _sync() async {
    if (_syncing) { // one at a time: this one's turn comes after
      _syncAgain = true;
      return;
    }
    final api = _api;
    if (api == null || (_dirtySeries.isEmpty && !_dirtyDefault)) return;
    _syncing = true;
    final sending = {for (final id in _dirtySeries) id: _versions[id] ?? 0};
    final sendDefault = _dirtyDefault;
    final defaultVersion = _defaultVersion;
    try {
      final merged = await _fetchRemote() ?? <String, dynamic>{};
      final remoteSeries = Map<String, dynamic>.from((merged['series'] as Map?) ?? {});
      for (final id in sending.keys) {
        final p = series[id];
        if (p == null) { remoteSeries.remove(id); } else { remoteSeries[id] = p.toJson(); }
      }
      merged['v'] = 1;
      merged['series'] = remoteSeries;
      if (sendDefault || merged['default'] == null) merged['default'] = defaults.toJson();
      await api.putClientSetting(komgaKey, jsonEncode(merged));
      // sent - unless it changed again meanwhile: then it's still to send
      for (final e in sending.entries) {
        if ((_versions[e.key] ?? 0) == e.value) _dirtySeries.remove(e.key);
      }
      if (sendDefault && _defaultVersion == defaultVersion) _dirtyDefault = false;
      await _saveUnsent();
      syncError = null;
      if (_dirtySeries.isNotEmpty || _dirtyDefault) _syncAgain = true;
    } catch (e) {
      _syncNote('Settings saved on this device, not on Komga yet: ${explain(e).reason}.', e);
      _syncSoon(const Duration(minutes: 1));
    } finally {
      _syncing = false;
    }
    notifyListeners();
    if (_syncAgain) {
      _syncAgain = false;
      _syncSoon();
    }
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

  /// A saved copy - this device's ([remote] false) or Komga's - replaces what's here, except this device's changes
  /// that haven't reached Komga yet: those stay as they are (changed, or removed). So a series whose own settings were
  /// removed on another device goes here too (code review, 2026-09-30: it used to stay for good).
  void _applyBlob(Map<String, dynamic> b, {required bool remote}) {
    final d = b['default'];
    if (d is Map<String, dynamic> && !(remote && _dirtyDefault)) defaults = ReaderPrefs.fromJson(d);
    final s = b['series'];
    if (s is! Map) return;
    final next = <String, ReaderPrefs>{
      for (final e in s.entries)
        if (!(remote && _dirtySeries.contains(e.key)))
          e.key as String: ReaderPrefs.fromJson(Map<String, dynamic>.from(e.value as Map)),
    };
    if (remote) {
      for (final id in _dirtySeries) {
        final mine = series[id];
        if (mine != null) next[id] = mine; // unsent here: this device's version (absent = removed here)
      }
    }
    series
      ..clear()
      ..addAll(next);
  }
}
