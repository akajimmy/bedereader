import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Color, Size;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'errors.dart';
import 'local/book_names.dart' show isLocalId;
import 'refresh_gate.dart';
import 'screen.dart';
import 'book_source.dart';

/// [original]: the page at its own size, one page pixel to one screen pixel (user, 2026-10-02).
enum FitMode { screen, width, height, original }

extension FitModeLabel on FitMode {
  String get label => switch (this) {
        FitMode.screen => 'Screen',
        FitMode.width => 'Width',
        FitMode.height => 'Height',
        FitMode.original => 'Original',
      };
}

/// Page order for a series: follow Komga's reading direction for it (auto), or force one. [vertical]: the pages one
/// continuous strip, scrolled down (a webtoon - user, 2026-10-22; Auto reads one so where Komga says Webtoon).
enum ReadingDirection { auto, ltr, rtl, vertical }

extension ReadingDirectionLabel on ReadingDirection {
  String get label => switch (this) {
        ReadingDirection.auto => 'Auto',
        ReadingDirection.ltr => 'Left to right',
        ReadingDirection.rtl => 'Right to left',
        ReadingDirection.vertical => 'Vertical scroll',
      };
}

/// How a webtoon's single presses scroll ([DisplayPrefs.webtoonScroll]; user, 2026-10-22: "a setting between scroll
/// modes: smooth scroll / page scroll"): a short glide, or most of a screen. The wheel and held keys scroll smoothly
/// in both.
enum WebtoonScroll { smooth, page }

/// A webtoon's tap zones ([DisplayPrefs.webtoonTaps]; user, 2026-10-22): the left and right thirds (as a comic's), or
/// the top and bottom thirds - the bottom scrolls down; the middle shows the controls in both.
enum WebtoonTaps { sides, topBottom }

/// How pages are shown. Saved per series (a new series starts from the global default) and synced through Komga.
@immutable
class ReaderPrefs {
  const ReaderPrefs({this.fit = FitMode.screen, this.sharpen = false,
      this.autoLevels = false, this.direction = ReadingDirection.auto, this.crop = 0, this.ownLayout = true,
      this.ownImage = true, this.background = ReaderBackground.black, this.twoPages = TwoPages.wideScreen,
      this.gutter = defaultGutter});

  /// A series' settings come in two parts, each overriding the defaults or not (the panels' "Override the
  /// defaults" toggles, user 2026-09-30): the page layout (fit, direction, background) and the image settings. A part
  /// not overridden follows the defaults. Series saved before this override both (unchanged). Unused on the defaults.
  final bool ownLayout, ownImage;

  final FitMode fit;
  final ReadingDirection direction; // auto = the series' reading direction in Komga
  // around the page - a reading default with a series' own (user, 2026-10-05; it was a setting of each device)
  final ReaderBackground background;
  // Dual page mode: two pages side by side - part of the page layout, a reading default with a series' own (user,
  // 2026-10-16: "make it part of the defaults that are over-rideable per series"; it was a setting of each device)
  final TwoPages twoPages;

  /// Dual page mode: the space between a pair's two pages, logical px on screen at the page's fit (user, 2026-10-20:
  /// "gutter width (space between pages) measured in pixels" - comics 2 by default). Part of the page layout.
  final double gutter;
  static const defaultGutter = 2.0;

  final bool sharpen; // shown as "Enhance": denoise + Lanczos scaling + RCAS (lib/enhance.dart); key kept for sync
  final bool autoLevels; // shown as "Enhance colours": auto-levels + whiten paper + deepen ink (lib/enhance.dart)
  final double crop; // "Crop edges": this fraction of the page cut off every side - one of [crops]

  /// Crop edges' steps (user, 2026-10-21: "Off, 2%, 4%, 6%" - it was a 1% slider to 10%). A share saved that isn't
  /// one of them reads as Off (no migration - user rule).
  static const crops = [0.0, 0.02, 0.04, 0.06];

  /// The Gutter's steps, px (user, 2026-10-21: "a few steps" - it was a slider to dial in).
  static const gutters = [0.0, 2.0, 8.0, 16.0];

  bool get neutralImage => !sharpen && !autoLevels && crop == 0;

  ReaderPrefs copyWith({FitMode? fit, bool? sharpen, bool? autoLevels,
          ReadingDirection? direction, double? crop, bool? ownLayout, bool? ownImage, ReaderBackground? background,
          TwoPages? twoPages, double? gutter}) =>
      ReaderPrefs(fit: fit ?? this.fit,
          sharpen: sharpen ?? this.sharpen, autoLevels: autoLevels ?? this.autoLevels,
          direction: direction ?? this.direction, crop: crop ?? this.crop, ownLayout: ownLayout ?? this.ownLayout,
          ownImage: ownImage ?? this.ownImage, background: background ?? this.background,
          twoPages: twoPages ?? this.twoPages, gutter: gutter ?? this.gutter);

  /// Same page layout (fit, direction, background, dual page mode), image settings back to neutral.
  ReaderPrefs imageReset() => ReaderPrefs(fit: fit, direction: direction, ownLayout: ownLayout, ownImage: ownImage,
      background: background, twoPages: twoPages, gutter: gutter);

  /// This one's page layout (fit, direction, background) with [image]'s image settings.
  ReaderPrefs withImageOf(ReaderPrefs image) => copyWith(
      sharpen: image.sharpen, autoLevels: image.autoLevels, crop: image.crop);

  Map<String, dynamic> toJson() => {
        'fit': fit.name, 's': sharpen, 'l': autoLevels, 'd': direction.name, 'x': crop,
        // written only when off, so everything saved before (and the defaults) reads exactly as it did
        if (!ownLayout) 'ol': false,
        if (!ownImage) 'oi': false,
        if (background != ReaderBackground.black) 'bg': background.name, // (likewise: black, as before, unwritten)
        if (twoPages != TwoPages.wideScreen) 'tp': twoPages.name, // (likewise: the default unwritten)
        if (gutter != defaultGutter) 'gut': gutter, // (likewise)
      };

  factory ReaderPrefs.fromJson(Map<String, dynamic> j) => ReaderPrefs(
        fit: FitMode.values.firstWhere((f) => f.name == j['fit'], orElse: () => FitMode.screen),
        sharpen: j['s'] == true,
        autoLevels: j['l'] == true,
        direction: ReadingDirection.values.firstWhere((d) => d.name == j['d'], orElse: () => ReadingDirection.auto),
        crop: crops.contains((j['x'] as num?)?.toDouble()) ? (j['x'] as num).toDouble() : 0,
        ownLayout: j['ol'] != false,
        ownImage: j['oi'] != false,
        background: ReaderBackground.values.firstWhere((b) => b.name == j['bg'], orElse: () => ReaderBackground.black),
        twoPages: TwoPages.values.firstWhere((t) => t.name == j['tp'], orElse: () => TwoPages.wideScreen),
        gutter: gutters.contains((j['gut'] as num?)?.toDouble()) ? (j['gut'] as num).toDouble() : defaultGutter,
      );

  @override
  bool operator ==(Object other) => other is ReaderPrefs && jsonEncode(other.toJson()) == jsonEncode(toJson());
  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// How a page change looks - not how it's triggered: tap, swipe and the arrows turn pages in all of them. Listed in
/// the order shown (None, Slide, Curl); the names are what's saved, so they stay as they were.
enum PageTurn { flip, swipe, curl }

extension PageTurnLabel on PageTurn {
  String get label => switch (this) {
        PageTurn.flip => 'None',
        PageTurn.swipe => 'Slide', // as eBooks' (user, 2026-10-07: it was "Wipe")
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
/// [locked]: iOS's - the screen held the way it is when the lock starts (Android has [portrait] / [landscape]).
enum Rotation { auto, portrait, landscape, locked }

extension RotationLabel on Rotation {
  String get label => switch (this) {
        Rotation.auto => 'Auto',
        Rotation.portrait => 'Portrait',
        Rotation.landscape => 'Landscape',
        Rotation.locked => 'Locked',
      };
}

/// The app's accent colour (buttons, switches, highlights), listed in the order shown: the user's own palette (10-27
/// worksheet, reports\10-27-accent-worksheet.html: bolder, more of them - "a bright fire engine red, a bold forest
/// green"). The name is what's saved: a device on a name that's gone (blue, red, purple...) starts on [defaultAccent].
/// In hue order round the wheel, cut between Salmon and Crimson so the reds stay together (user, 2026-10-27, "A'" -
/// cut at 0 degrees, Crimson at 348 went to the far end), then the earth tones, then the greys light to dark.
enum Accent { crimson, fireRed, coral, orange, yellow, lime, neon, forest, green, mint, cyan, royal, navy, violet,
  electric, darkPink, hotPink, salmon, bronze, olive, white, grey, charcoal, nearBlack }

/// A fresh install's accent, and one saved under a name that's gone (user, 2026-10-27: Blue was the default - gone).
const defaultAccent = Accent.royal;

extension AccentColour on Accent {
  Color get colour => switch (this) {
        Accent.fireRed => const Color(0xFFFF1F1F),
        Accent.crimson => const Color(0xFFD7163E),
        Accent.coral => const Color(0xFFFF6B57),
        Accent.orange => const Color(0xFFF76B15),
        Accent.yellow => const Color(0xFFF5D90A),
        Accent.lime => const Color(0xFF00FF00),
        Accent.neon => const Color(0xFF3DFF5A),
        Accent.green => const Color(0xFF30A46C),
        Accent.forest => const Color(0xFF1E8C3A),
        Accent.mint => const Color(0xFF3DE8B5),
        Accent.cyan => const Color(0xFF00D2F0),
        Accent.navy => const Color(0xFF000080),
        Accent.royal => const Color(0xFF2F5BFF),
        Accent.violet => const Color(0xFF6E56CF),
        Accent.electric => const Color(0xFFB026FF),
        Accent.darkPink => const Color(0xFFA02372),
        Accent.hotPink => const Color(0xFFFF2E93),
        Accent.salmon => const Color(0xFFFF91A4),
        Accent.bronze => const Color(0xFFAD7F58),
        Accent.olive => const Color(0xFF8E8C5C),
        Accent.white => const Color(0xFFEDEDED),
        Accent.grey => const Color(0xFF9999A0),
        Accent.charcoal => const Color(0xFF4A4F57),
        Accent.nearBlack => const Color(0xFF1B1B1B), // (the user's call: as it is, though it sits close to the background)
      };

  /// Text and icons on the accent (a selected choice, a filled button): black on the light ones, white on the dark.
  Color get onColour => colour.computeLuminance() > 0.25 ? const Color(0xFF101012) : const Color(0xFFFFFFFF);

  /// As the user named them (10-27).
  String get label => switch (this) {
        Accent.fireRed => 'Fire red',
        Accent.darkPink => 'Dark Pink',
        Accent.hotPink => 'Hot pink',
        Accent.nearBlack => 'Near Black',
        _ => '${name[0].toUpperCase()}${name.substring(1)}',
      };

  /// Where the remote's focus is shown: the accent, or on the dark greys a lighter one - charcoal on the app's
  /// near-black was hard to find.
  Color get focus => colour.computeLuminance() < 0.1 ? Color.lerp(colour, const Color(0xFFFFFFFF), 0.45)! : colour;
}

/// Library grids and Home's rows: how big the posters are.
enum PosterSize { small, medium, large }

extension PosterSizeLabel on PosterSize {
  String get label => switch (this) { PosterSize.small => 'Small', PosterSize.medium => 'Medium', PosterSize.large => 'Large' };
  double get scale => switch (this) { PosterSize.small => 0.8, PosterSize.medium => 1.0, PosterSize.large => 1.3 };
}

/// The note in the page's corner while reading ([KindPrefs.pageNote]): always there, for a moment after each
/// turn, or not at all (user, 2026-10-06: option H, for EPUBs; both kinds since 2026-10-07).
enum PageNote { always, afterTurn, off }

/// eBooks' page as a sheet with a surround ([DisplayPrefs.insetPage]; user, 2026-10-12: "inset page"): never - the
/// page's colour across the screen; on a wide screen, where the lines leave room to spare; always - on a narrow screen
/// too, a card in from all four edges (user, 2026-10-15).
enum InsetPage { never, wideScreen, always }

/// Dual page mode, two pages side by side ([ReaderPrefs.twoPages]; user, 2026-10-16): never; on a wide screen (wider
/// than tall); always (a portrait screen too).
enum TwoPages {
  off,
  wideScreen,
  always;

  /// Two pages side by side on a screen of [size].
  bool on(Size size) => switch (this) {
        TwoPages.off => false,
        TwoPages.wideScreen => size.width > size.height,
        TwoPages.always => true,
      };
}

/// eBooks in Dual page mode: where a chapter starts (user, 2026-10-18 - a setting, after a book of 36 one-page
/// chapters showed every left-hand page blank): on the next page, left or right, the pages running on through the
/// book; or always on a right-hand page, as in print, the page before it left blank as needed.
enum ChapterStart { nextPage, rightPage }

/// The two kinds of book the one Reader reads (a renderer each).
enum BookKind { comics, ebooks, webtoons } // (webtoons: comics' own kind since 2026-10-22 - a clean split)

/// The reading settings each kind of book has its own of: the position text (user, 2026-10-07, settings option A set
/// apart the page corner, rotation, clock and progress bar too; 2026-10-21: those are one set for both kinds now -
/// [DisplayPrefs.rotation] and the rest). This device.
@immutable
class KindPrefs {
  const KindPrefs({this.hiddenSpots = const []});

  /// The position text's spots not shown ('left', 'centre', 'right' - lib/reader/position_row.dart).
  final List<String> hiddenSpots;

  KindPrefs copyWith({List<String>? hiddenSpots}) => KindPrefs(hiddenSpots: hiddenSpots ?? this.hiddenSpots);

  Map<String, dynamic> toJson() => {'hiddenSpots': hiddenSpots};

  /// From [j]; anything it lacks, [fallback]'s (the kind's defaults).
  factory KindPrefs.fromJson(Map<String, dynamic> j, {KindPrefs fallback = const KindPrefs()}) {
    final spots = j['hiddenSpots'];
    return KindPrefs(hiddenSpots: spots is List ? [for (final v in spots) if (v is String) v] : fallback.hiddenSpots);
  }

  @override
  bool operator ==(Object other) => other is KindPrefs && jsonEncode(other.toJson()) == jsonEncode(toJson());
  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// App-wide display settings: kept on this device only (a phone and the tablet need different brightness).
@immutable
class DisplayPrefs {
  const DisplayPrefs({this.night = false, this.warmth = 0.5, this.brightness, this.pageTurn = PageTurn.swipe,
      this.epubTurn = EpubTurn.slide,
      this.doubleTapZoom = true, this.midBook = MidBook.ask,
      this.screenOn = 0, this.posterSize = PosterSize.medium,
      this.nightSchedule = false, this.nightFrom = 21 * 60, this.nightTo = 7 * 60,
      this.textScale = 1.0, this.accent = defaultAccent, this.pageStrip = false,
      this.comics = const KindPrefs(), this.ebooks = const KindPrefs(), this.webtoons = const KindPrefs(),
      this.insetPage = InsetPage.wideScreen, this.rotation = Rotation.auto, this.pageNote = PageNote.afterTurn,
      this.showClock = false, this.showBattery = false, this.progressBar = false,
      this.webtoonScroll = WebtoonScroll.smooth, this.webtoonTaps = WebtoonTaps.sides,
      this.autoScrollSpeed = autoScrollStart, this.webtoonDoubleTap = true, this.sourceIcon = false});
  final bool night;

  /// Posters and libraries show where they come from - this device, a network share, Komga (Settings > Library &
  /// Home; user, 2026-10-26: "show source icon").
  final bool sourceIcon;

  /// A webtoon's single presses: a short glide or most of a screen ([WebtoonScroll]) - this device's, as the page
  /// turn is.
  final WebtoonScroll webtoonScroll;

  /// A webtoon's tap zones: the sides, or the top and bottom ([WebtoonTaps]) - this device's.
  final WebtoonTaps webtoonTaps;

  /// A webtoon's double tap: zooms in on the spot, and out again (user, 2026-10-22) - comics' own is [doubleTapZoom].
  final bool webtoonDoubleTap;

  /// A webtoon's auto-scroll speed, screen points a second - the last one set (its slider, its keys), this device's.
  final double autoScrollSpeed;
  static const autoScrollStart = 60.0, autoScrollSlowest = 10.0, autoScrollFastest = 400.0;

  // Rotation and what's over the page: one set for comics and eBooks (user, 2026-10-21 - each kind had its own; the
  // defaults are the comics' ones). This device.
  final Rotation rotation; // in the reader: follow the device, or hold portrait / landscape (Android)
  /// The note in the page's bottom-right corner, "12 / 36" ("Page counter").
  final PageNote pageNote;
  /// With the controls hidden: the time and the battery, top right, each on or off (with the controls up both are
  /// on the top bar).
  final bool showClock, showBattery;
  final bool progressBar; // a thin line along the bottom while the controls are hidden (their slider shows it)

  /// eBooks: the page as a sheet on a surround - never, on a wide screen, or always ([InsetPage]) - this device's own
  /// (user, 2026-10-11: "per device setting", not in the reader's panel; three choices since 2026-10-15).
  final InsetPage insetPage;

  /// The reading settings set apart per kind of book ([KindPrefs]).
  final KindPrefs comics, ebooks, webtoons;
  KindPrefs kind(BookKind k) => switch (k) {
        BookKind.comics => comics,
        BookKind.ebooks => ebooks,
        BookKind.webtoons => webtoons,
      };

  // (posters' captions: synced since 2026-10-22 - [LibraryPrefs])
  /// reader: the page strip (the Pages button) is open - it stays open, book after book, until closed with the
  /// button (user, 2026-10-02)
  final bool pageStrip;
  final bool nightSchedule; // night mode on at [nightFrom] and off at [nightTo] by itself (still switchable by hand)
  final int nightFrom, nightTo; // minutes after midnight
  final double textScale; // this app's text size, on top of the device's (one of [textScales])
  final Accent accent;

  static const textScales = [0.9, 1.0, 1.15, 1.3];
  final bool doubleTapZoom; // reader, fit screen: double-tap zooms in on the spot (single taps then wait a moment)
  final MidBook midBook; // reader: Next book before the last page
  final int screenOn; // reader: minutes the screen stays on after the last page turn; 0 = the system's timeout
  final PosterSize posterSize; // library grids and Home's rows

  static const alwaysOn = -1; // [screenOn]: as long as a book is open
  // (user, 2026-10-21: Off, 10 min, Always - it was 0, 5, 10, 20, 30, Always; another saved value reads as Off)
  static const screenOnChoices = [0, 10, alwaysOn];
  final PageTurn pageTurn; // comics' page turn (this device)
  // eBooks' page turn - this device's too (user, 2026-10-21: "both on this device"; it was synced, in EpubPrefs)
  final EpubTurn epubTurn;
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

  /// Each kind's own reading settings are changed with [withKind].
  DisplayPrefs copyWith({bool? night, double? warmth, double? Function()? brightness, PageTurn? pageTurn,
          EpubTurn? epubTurn,
          bool? doubleTapZoom, MidBook? midBook, int? screenOn, PosterSize? posterSize,
          bool? nightSchedule, int? nightFrom, int? nightTo, double? textScale, Accent? accent,
          bool? pageStrip,
          KindPrefs? comics, KindPrefs? ebooks, KindPrefs? webtoons, InsetPage? insetPage, Rotation? rotation,
          PageNote? pageNote, bool? showClock, bool? showBattery, bool? progressBar, WebtoonScroll? webtoonScroll,
          WebtoonTaps? webtoonTaps, double? autoScrollSpeed, bool? webtoonDoubleTap, bool? sourceIcon}) =>
      DisplayPrefs(
        comics: comics ?? this.comics, ebooks: ebooks ?? this.ebooks, webtoons: webtoons ?? this.webtoons,
        insetPage: insetPage ?? this.insetPage, webtoonTaps: webtoonTaps ?? this.webtoonTaps,
        autoScrollSpeed: autoScrollSpeed ?? this.autoScrollSpeed,
        webtoonDoubleTap: webtoonDoubleTap ?? this.webtoonDoubleTap,
        sourceIcon: sourceIcon ?? this.sourceIcon,
        rotation: rotation ?? this.rotation, pageNote: pageNote ?? this.pageNote,
        showClock: showClock ?? this.showClock, showBattery: showBattery ?? this.showBattery,
        progressBar: progressBar ?? this.progressBar,
        webtoonScroll: webtoonScroll ?? this.webtoonScroll,
        pageStrip: pageStrip ?? this.pageStrip,
        nightSchedule: nightSchedule ?? this.nightSchedule, nightFrom: nightFrom ?? this.nightFrom,
        nightTo: nightTo ?? this.nightTo, textScale: textScale ?? this.textScale, accent: accent ?? this.accent,
        night: night ?? this.night, warmth: warmth ?? this.warmth,
        brightness: brightness != null ? brightness() : this.brightness, pageTurn: pageTurn ?? this.pageTurn,
        epubTurn: epubTurn ?? this.epubTurn,
        doubleTapZoom: doubleTapZoom ?? this.doubleTapZoom, midBook: midBook ?? this.midBook,
        screenOn: screenOn ?? this.screenOn, posterSize: posterSize ?? this.posterSize);

  /// Kind [k]'s reading settings changed.
  DisplayPrefs withKind(BookKind k, KindPrefs p) => switch (k) {
        BookKind.comics => copyWith(comics: p),
        BookKind.ebooks => copyWith(ebooks: p),
        BookKind.webtoons => copyWith(webtoons: p),
      };

  Map<String, dynamic> toJson() => {'night': night, 'warmth': warmth, 'brightness': brightness,
      'pageTurn': pageTurn.name, 'epubTurn': epubTurn.name, 'doubleTapZoom': doubleTapZoom,
      'midBook': midBook.name, 'screenOn': screenOn, 'posterSize': posterSize.name,
      'nightSchedule': nightSchedule, 'nightFrom': nightFrom, 'nightTo': nightTo, 'textScale': textScale,
      'accent': accent.name, 'pageStrip': pageStrip,
      'comics': comics.toJson(), 'ebooks': ebooks.toJson(), 'webtoons': webtoons.toJson(),
      'insetPage': insetPage.name, 'webtoonTaps': webtoonTaps.name, 'autoScrollSpeed': autoScrollSpeed,
      'webtoonDoubleTap': webtoonDoubleTap,
      // new keys (the kinds' old ones are left unread: these start from the defaults - no migration)
      'rotation': rotation.name, 'pageNote': pageNote.name, 'showClock': showClock, 'showBattery': showBattery,
      'progressBar': progressBar, 'webtoonScroll': webtoonScroll.name, 'sourceIcon': sourceIcon};
  factory DisplayPrefs.fromJson(Map<String, dynamic> j) {
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.firstWhere((v) => v.name == name, orElse: () => fallback);
    final on = j['screenOn'];
    int minutes(Object? v, int fallback) => v is int && v >= 0 && v < 24 * 60 ? v : fallback;
    const none = DisplayPrefs();
    KindPrefs kind(String key, KindPrefs fallback) =>
        j[key] is Map ? KindPrefs.fromJson(Map<String, dynamic>.from(j[key] as Map), fallback: fallback) : fallback;
    return DisplayPrefs(
        night: j['night'] == true, warmth: (j['warmth'] as num?)?.toDouble() ?? 0.5,
        brightness: (j['brightness'] as num?)?.toDouble(),
        pageTurn: pick(PageTurn.values, j['pageTurn'], PageTurn.swipe),
        epubTurn: pick(EpubTurn.values, j['epubTurn'], EpubTurn.slide),
        doubleTapZoom: j['doubleTapZoom'] != false,
        midBook: pick(MidBook.values, j['midBook'], MidBook.ask),
        // default Off (user, 2026-09-30): "always on" drained the tablet's battery overnight when they fell asleep reading
        screenOn: on is int && screenOnChoices.contains(on) ? on : 0,
        posterSize: pick(PosterSize.values, j['posterSize'], PosterSize.medium),
        nightSchedule: j['nightSchedule'] == true,
        nightFrom: minutes(j['nightFrom'], 21 * 60),
        nightTo: minutes(j['nightTo'], 7 * 60),
        textScale: textScales.contains(j['textScale']) ? (j['textScale'] as num).toDouble() : 1.0,
        accent: pick(Accent.values, j['accent'], defaultAccent),
        pageStrip: j['pageStrip'] == true,
        comics: kind('comics', none.comics),
        webtoons: kind('webtoons', none.webtoons),
        webtoonTaps: pick(WebtoonTaps.values, j['webtoonTaps'], WebtoonTaps.sides),
        webtoonDoubleTap: j['webtoonDoubleTap'] != false,
        autoScrollSpeed: switch (j['autoScrollSpeed']) {
          final num v when v >= autoScrollSlowest && v <= autoScrollFastest => v.toDouble(),
          _ => autoScrollStart,
        },
        ebooks: kind('ebooks', none.ebooks),
        insetPage: pick(InsetPage.values, j['insetPage'], InsetPage.wideScreen),
        rotation: pick(Rotation.values, j['rotation'], none.rotation),
        pageNote: pick(PageNote.values, j['pageNote'], none.pageNote),
        showClock: j['showClock'] == true,
        showBattery: j['showBattery'] == true,
        progressBar: j['progressBar'] == true,
        webtoonScroll: pick(WebtoonScroll.values, j['webtoonScroll'], WebtoonScroll.smooth),
        sourceIcon: j['sourceIcon'] == true);
  }
}

/// Holds reader prefs (global default + per series, synced to the user's Komga client settings) and display prefs
/// (this device). Changes apply immediately; the Komga copy is written a moment later, merged with whatever is on
/// the server so two devices don't wipe each other's series.
// ---- EPUB books (reports\epub-plan-2026-10-06.md; user's choices 2026-10-06): one set for every book, synced

enum EpubFont {
  literata('Literata', 'Literata'),
  lora('Lora', 'Lora'),
  garamond('EB Garamond', 'EB Garamond'),
  atkinson('Atkinson Hyperlegible Next', 'Atkinson'),
  deviceSerif(null, 'Device serif'),
  deviceSans(null, 'Device sans');

  const EpubFont(this.family, this.label);
  final String? family; // a bundled font's family; null: the device's own
  final String label;
}

enum EpubColours {
  black(Color(0xFF000000), Color(0xFFC9C9C9), 'Black'),
  dark(Color(0xFF1B1B1D), Color(0xFFE4E0D8), 'Dark'),
  sepia(Color(0xFFEFE4CC), Color(0xFF2A2018), 'Sepia'),
  light(Color(0xFFFFFFFF), Color(0xFF1A1A1A), 'Light');

  const EpubColours(this.background, this.text, this.label);
  final Color background, text;
  final String label;
}

/// The page's left and right margins (user, 2026-10-08: "wider margins than currently possible" - five steps; the top
/// and bottom no longer follow them: [topBottom] is the same for all).
enum EpubMargins {
  // the book's own page margin (its body's), as a browser shows it - no share, no line length (user, 2026-10-11)
  book(0, 0, "Book's"),
  narrow(0.04, 40, 'Narrow'),
  normal(0.08, 34, 'Normal'),
  wide(0.14, 28, 'Wide'),
  wider(0.20, 24, 'Wider'); // (Widest went - user, 2026-10-21; saved, it reads as Normal)

  const EpubMargins(this.share, this.lineEms, this.label);

  /// Each side's margin as a share of the page's width - at least.
  final double share;

  /// The longest a line gets, in ems: on a wide screen the rest goes to the margins - so on a tablet or the PC the
  /// margins are set by this more than by [share] (user, 2026-10-06: the setting "doesn't seem to do anything").
  final double lineEms;
  final String label;

  /// The top and bottom margins, whichever the sides are (user, 2026-10-08).
  static const double topBottom = 40;
}

/// The gap between paragraphs (user, 2026-10-06: "an option to increase the spacing between paragraphs"; 2026-10-11:
/// the setting owns the gaps). Book's: the book's own gaps, as it sets them. A step: that gap, in ems of the text,
/// in place of the chapter's usual one (Default: none) - never closer than the book's where it keeps one for a reason
/// (a paragraph it doesn't indent, under a picture, a gap that differs from the usual).
enum EpubParagraphGap {
  // four steps (user, 2026-10-21: "Book's, None, Normal (today's medium), Large (today's extra large)"). Saved by
  // name: 'small' is half a line, 'huge' a line and a half, as they were; 'tiny' and 'large' went (they read as None)
  book(null, "Book's"),
  none(0, 'None'),
  small(0.5, 'Normal'),
  huge(1.5, 'Large');

  const EpubParagraphGap(this.ems, this.label);
  final double? ems; // null: the book's
  final String label;
}

enum EpubTurn { slide, none, curl } // curl: 3D page curl, as the comics' (2026-10-11)

/// The text's alignment (user, 2026-10-07: "Book's formatting" split in three): the book's own, or every paragraph
/// justified or ragged-right.
enum EpubAlign {
  book("Book's"), justified('Justified'), left('Left');

  const EpubAlign(this.label);
  final String label;
}

@immutable
class EpubPrefs {
  const EpubPrefs({this.font = EpubFont.literata, this.size = 19, this.lineSpacing = 1.5,
      this.margins = EpubMargins.normal, this.colours = EpubColours.dark, this.align = EpubAlign.justified,
      this.hyphenate = true,
      this.paragraphGap = EpubParagraphGap.none, this.twoPages = TwoPages.wideScreen,
      this.chapterStart = ChapterStart.nextPage, this.gutter = defaultGutter});
  final EpubFont font;
  final double size; // px at the app's text size
  final double lineSpacing;
  final EpubMargins margins;
  final EpubColours colours;
  final EpubAlign align;
  final bool hyphenate;
  final EpubParagraphGap paragraphGap;

  /// Dual page mode: two pages side by side, as an open book (user, 2026-10-16: eBooks as comics - the Aa panel).
  final TwoPages twoPages;

  /// Dual page mode: where each chapter starts ([ChapterStart]) - the next page unless asked.
  final ChapterStart chapterStart;

  /// Dual page mode with Inset page: the space between the two sheets, logical px (user, 2026-10-20: "gutter width
  /// ... the default value for ebooks at whatever it currently uses" - 24, dialled in on the tablet 2026-10-16).
  /// Without Inset page the two pages are one surface and meet, as before.
  final double gutter;
  static const defaultGutter = 24.0;

  /// The Gutter's steps, px (user, 2026-10-21: "12, 24, 48").
  static const gutters = [12.0, 24.0, 48.0];

  static const sizes = [14.0, 15.0, 16.0, 17.0, 18.0, 19.0, 20.0, 22.0, 24.0, 26.0, 28.0, 32.0];
  /// Line spacing's steps (user, 2026-10-08: 1 to 2 by a quarter, "names as above": Compact .. Double).
  // (user, 2026-10-21: Tight, Normal, Loose - Compact and Double went; another saved spacing reads as Normal)
  static const spacings = [1.25, 1.5, 1.75];

  EpubPrefs copyWith({EpubFont? font, double? size, double? lineSpacing, EpubMargins? margins, EpubColours? colours,
          EpubAlign? align, bool? hyphenate,
          EpubParagraphGap? paragraphGap, TwoPages? twoPages, ChapterStart? chapterStart, double? gutter}) =>
      EpubPrefs(font: font ?? this.font, size: size ?? this.size, lineSpacing: lineSpacing ?? this.lineSpacing,
          margins: margins ?? this.margins, colours: colours ?? this.colours, align: align ?? this.align,
          hyphenate: hyphenate ?? this.hyphenate,
          paragraphGap: paragraphGap ?? this.paragraphGap, twoPages: twoPages ?? this.twoPages,
          chapterStart: chapterStart ?? this.chapterStart, gutter: gutter ?? this.gutter);

  Map<String, dynamic> toJson() => {'font': font.name, 'size': size, 'lineSpacing': lineSpacing,
      'margins': margins.name, 'colours': colours.name, 'align': align.name,
      'hyphenate': hyphenate, 'paragraphGap': paragraphGap.name, 'twoPages': twoPages.name,
      'chapterStart': chapterStart.name, 'gutter': gutter};

  /// What's synced: all but the font and the text size - this device's own (user, 2026-10-22: "ebook text size and
  /// font face should be per device"; [AppSettings.setEpub]).
  Map<String, dynamic> syncJson() => toJson()
    ..remove('font')
    ..remove('size');

  factory EpubPrefs.fromJson(Map<String, dynamic> j) {
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.firstWhere((v) => v.name == name, orElse: () => fallback);
    final size = (j['size'] as num?)?.toDouble();
    final spacing = (j['lineSpacing'] as num?)?.toDouble();
    return EpubPrefs(
      font: pick(EpubFont.values, j['font'], EpubFont.literata),
      size: size != null && size >= 10 && size <= 48 ? size : 19,
      lineSpacing: spacings.contains(spacing) ? spacing! : 1.5,
      margins: pick(EpubMargins.values, j['margins'], EpubMargins.normal),
      colours: pick(EpubColours.values, j['colours'], EpubColours.dark),
      align: pick(EpubAlign.values, j['align'], EpubAlign.justified),
      hyphenate: j['hyphenate'] != false,
      paragraphGap: pick(EpubParagraphGap.values, j['paragraphGap'], EpubParagraphGap.none),
      twoPages: pick(TwoPages.values, j['twoPages'], TwoPages.wideScreen),
      chapterStart: pick(ChapterStart.values, j['chapterStart'], ChapterStart.nextPage),
      gutter: gutters.contains((j['gutter'] as num?)?.toDouble()) ? (j['gutter'] as num).toDouble() : defaultGutter,
    );
  }

  @override
  bool operator ==(Object other) => other is EpubPrefs && jsonEncode(other.toJson()) == jsonEncode(toJson());
  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// The library's look that follows the account, synced through Komga (user, 2026-10-22: "i went too far with which
/// settings are per device" - quiz: posters' captions and Home's sections synced; they were this device's). New keys:
/// they start from the defaults (no migration).
@immutable
class LibraryPrefs {
  const LibraryPrefs({this.posterSeries = true, this.posterTitle = true, this.posterDate = true,
      this.ebookPosterTitle = true, this.ebookPosterAuthor = true, this.ebookPosterSeries = false,
      this.ebookPosterDate = false, this.homeShown = const {}, this.homeOrder = const []});

  /// Book posters' caption, any of three lines, always in this order (user, 2026-10-07): the series and number
  /// ("Saga #12"), the book's title, the release date ("13 Mar 2024").
  final bool posterSeries, posterTitle, posterDate;

  /// eBook posters' caption, their own (user, 2026-10-18: "make sure it's split between eBooks and comics"): any of
  /// the title, the author, the series and number, the release date, in this order - the first three of them shown.
  /// Title and author by default ("The option I'm going to want in the end is title, then author").
  final bool ebookPosterTitle, ebookPosterAuthor, ebookPosterSeries, ebookPosterDate;

  /// Home's sections switched on or off (a section not here: its default - [HomeSections]) and their order (the
  /// ones not here after these, in the default order).
  final Map<String, bool> homeShown;
  final List<String> homeOrder;

  LibraryPrefs copyWith({bool? posterSeries, bool? posterTitle, bool? posterDate, bool? ebookPosterTitle,
          bool? ebookPosterAuthor, bool? ebookPosterSeries, bool? ebookPosterDate, Map<String, bool>? homeShown,
          List<String>? homeOrder}) =>
      LibraryPrefs(
          posterSeries: posterSeries ?? this.posterSeries, posterTitle: posterTitle ?? this.posterTitle,
          posterDate: posterDate ?? this.posterDate, ebookPosterTitle: ebookPosterTitle ?? this.ebookPosterTitle,
          ebookPosterAuthor: ebookPosterAuthor ?? this.ebookPosterAuthor,
          ebookPosterSeries: ebookPosterSeries ?? this.ebookPosterSeries,
          ebookPosterDate: ebookPosterDate ?? this.ebookPosterDate, homeShown: homeShown ?? this.homeShown,
          homeOrder: homeOrder ?? this.homeOrder);

  Map<String, dynamic> toJson() => {
        'posterSeries': posterSeries, 'posterTitle': posterTitle, 'posterDate': posterDate,
        'ebookPosterTitle': ebookPosterTitle, 'ebookPosterAuthor': ebookPosterAuthor,
        'ebookPosterSeries': ebookPosterSeries, 'ebookPosterDate': ebookPosterDate,
        'homeShown': homeShown, 'homeOrder': homeOrder,
      };

  factory LibraryPrefs.fromJson(Map<String, dynamic> j) {
    final shown = j['homeShown'], order = j['homeOrder'];
    return LibraryPrefs(
      posterSeries: j['posterSeries'] != false,
      posterTitle: j['posterTitle'] != false,
      posterDate: j['posterDate'] != false,
      ebookPosterTitle: j['ebookPosterTitle'] != false,
      ebookPosterAuthor: j['ebookPosterAuthor'] != false,
      ebookPosterSeries: j['ebookPosterSeries'] == true,
      ebookPosterDate: j['ebookPosterDate'] == true,
      homeShown: shown is Map ? {for (final e in shown.entries) if (e.value is bool) '${e.key}': e.value as bool} : const {},
      homeOrder: order is List ? [for (final k in order) if (k is String) k] : const [],
    );
  }

  @override
  bool operator ==(Object other) => other is LibraryPrefs && jsonEncode(other.toJson()) == jsonEncode(toJson());
  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

class AppSettings extends ChangeNotifier {
  AppSettings._();
  static final AppSettings instance = AppSettings._();

  static const komgaKey = 'komgareader.readerprefs';
  static const _localReader = 'readerPrefs';
  // a local library's series' settings: this device's own (another device hasn't its folders) - never sent to Komga,
  // kept when its copy comes and through signing out (review, 2026-10-26: as the local pins are)
  static const _hereSeries = 'readerPrefs.here';
  static const _localDisplay = 'displayPrefs';

  BookSource? _api;
  ReaderPrefs defaults = const ReaderPrefs();

  /// Webtoons' own reading defaults (synced, key "webtoon" - user, 2026-10-22: "a clean split"): at their own size
  /// unless set otherwise. The series Komga says are webtoons ([webtoonSeries]) follow these, not [defaults].
  ReaderPrefs webtoonDefaults = webtoonStart;
  static const webtoonStart = ReaderPrefs(fit: FitMode.original);

  /// The series Komga says are webtoons, as the app comes across them (a series list, a series' page, the reader) -
  /// kept on this device ([noteDirection]): their settings start from [webtoonDefaults], their episodes' posters are
  /// the series' cover. A comic series set to Vertical scroll in the app isn't one (user, 2026-10-22: it "keeps its
  /// comic settings").
  final Set<String> webtoonSeries = {};
  static const _webtoonSeriesKey = 'webtoon.series';

  /// Komga's reading direction for [seriesId], seen: a webtoon, or not (any more). May be called mid-build. True: it
  /// changed.
  bool noteDirection(String seriesId, Object? direction) {
    final now = direction == 'WEBTOON';
    if (webtoonSeries.contains(seriesId) == now) return false;
    now ? webtoonSeries.add(seriesId) : webtoonSeries.remove(seriesId);
    SharedPreferences.getInstance().then((p) => p.setStringList(_webtoonSeriesKey, webtoonSeries.toList()));
    scheduleMicrotask(notifyListeners);
    return true;
  }

  /// The defaults [seriesId] follows: a webtoon's, or a comic's.
  ReaderPrefs defaultsFor(String? seriesId) =>
      seriesId != null && webtoonSeries.contains(seriesId) ? webtoonDefaults : defaults;
  final Map<String, ReaderPrefs> series = {};
  DisplayPrefs display = const DisplayPrefs();

  /// Tells only of changes to how posters look (size, title only, release date): poster grids listen to this, not to
  /// every setting - a brightness slider drag rebuilt every grid under the reader (code review 2026-10-05, #44).
  final posterLook = ValueNotifier<(PosterSize, bool, bool, bool, (bool, bool, bool, bool))>(
      (PosterSize.medium, true, true, true, (true, true, false, false)));

  void _posterLookFollows() => posterLook.value = (display.posterSize, library.posterSeries, library.posterTitle,
      library.posterDate, (library.ebookPosterTitle, library.ebookPosterAuthor, library.ebookPosterSeries,
          library.ebookPosterDate));
  // EPUB books: one set, synced with the reading defaults (key "epub") - but for the font and the text size, this
  // device's own ([EpubPrefs.syncJson], kept under [_localEpubOwn])
  EpubPrefs epub = const EpubPrefs();
  static const _localEpubOwn = 'epub.own';

  /// eBooks: a book's own settings, overriding the defaults ([epub]) - every one of them, font and size included
  /// (user, 2026-10-27: per book, as comics are per series; "all per-device": kept on this device only, never synced
  /// - what reads best differs from screen to screen. The defaults stay synced, but for the font and size).
  final Map<String, EpubPrefs> epubBooks = {};
  static const _epubBooksKey = 'epub.books';

  /// The eBook settings [bookId] is read with: its own, else the defaults.
  EpubPrefs epubFor(String? bookId) => (bookId == null ? null : epubBooks[bookId]) ?? epub;

  /// Whether [bookId] has its own eBook settings.
  bool ownsEpub(String bookId) => epubBooks.containsKey(bookId);

  /// [bookId]'s own eBook settings, from now on.
  void setEpubBook(String bookId, EpubPrefs prefs) {
    if (epubBooks[bookId] == prefs) return;
    epubBooks[bookId] = prefs;
    _epubBooksChanged();
  }

  /// The panel's "Override defaults": on, the book starts from the defaults' values (nothing on the page moves) and
  /// can then be set; off, it follows the defaults again.
  void setEpubOverride(String bookId, bool own) {
    if (own == ownsEpub(bookId)) return;
    own ? epubBooks[bookId] = epub : epubBooks.remove(bookId);
    _epubBooksChanged();
  }

  /// Every book back to the defaults (Settings > eBooks > Reset all).
  void clearEpubBooks() {
    if (epubBooks.isEmpty) return;
    epubBooks.clear();
    _epubBooksChanged();
  }

  /// Local books and series whose ids changed with their paths (Apply edits to files: old -> new): a series' reader
  /// settings and a book's eBook settings follow.
  void renameIds(Map<String, String> ids) {
    var reader = false, books = false;
    for (final MapEntry(key: from, value: to) in ids.entries) {
      if (series.remove(from) case final p?) (series[to] = p, reader = true);
      if (epubBooks.remove(from) case final p?) (epubBooks[to] = p, books = true);
    }
    if (reader) _changedReader();
    if (books) _epubBooksChanged();
  }

  void _epubBooksChanged() {
    notifyListeners();
    final json = jsonEncode({for (final MapEntry(:key, :value) in epubBooks.entries) key: value.toJson()});
    SharedPreferences.getInstance().then((p) => p.setString(_epubBooksKey, json)).then<void>((_) {},
        onError: (Object _) {});
  }

  void _loadEpubBooks(String? raw) {
    epubBooks.clear();
    if (raw == null) return; // (a new key: none until set here - no migration)
    try {
      for (final MapEntry(:key, :value) in (jsonDecode(raw) as Map<String, dynamic>).entries) {
        epubBooks[key] = EpubPrefs.fromJson(value as Map<String, dynamic>);
      }
    } catch (_) {
      epubBooks.clear(); // damaged: every book follows the defaults
    }
  }

  /// [p] with this device's font and text size (from [epub], which always has them).
  EpubPrefs _withOwn(EpubPrefs p) => p.copyWith(font: epub.font, size: epub.size);
  LibraryPrefs library = const LibraryPrefs(); // posters' captions, Home's sections: synced (key "library")
  String? syncError; // last Komga sync problem, shown at the bottom of the reader's panels

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
  bool _dirtyWebtoon = false;
  int _webtoonVersion = 0;
  bool _dirtyEpub = false;
  int _epubVersion = 0;
  bool _dirtyLibrary = false;
  int _libraryVersion = 0;
  // how many times each entry has changed: a send only clears the entries that didn't change again while it was on
  // its way (a change made mid-send used to be marked sent without being sent)
  final Map<String, int> _versions = {};
  int _defaultVersion = 0;
  bool _syncing = false, _syncAgain = false; // one sync at a time; one asked for meanwhile runs after it
  Timer? _syncTimer;

  /// Switch connection (online / offline) without reloading; a failed sync retries on its own.
  void useApi(BookSource api) {
    _api = api;
    if (_anyDirty) _syncSoon();
  }

  bool get _anyDirty => _dirtySeries.isNotEmpty || _dirtyDefault || _dirtyEpub || _dirtyLibrary || _dirtyWebtoon;

  void _syncSoon([Duration after = const Duration(seconds: 2)]) {
    _syncTimer?.cancel();
    _syncTimer = Timer(after, _sync);
  }

  Future<void> _saveUnsent() async {
    final p = await SharedPreferences.getInstance();
    if (!_anyDirty) {
      await p.remove(_unsentKey);
    } else {
      await p.setString(_unsentKey,
          jsonEncode({'series': _dirtySeries.toList(), 'default': _dirtyDefault, 'webtoon': _dirtyWebtoon,
            'epub': _dirtyEpub,
            'library': _dirtyLibrary}));
    }
  }

  /// Signed out: the account's synced settings go from this device (they come back from Komga on signing in again);
  /// this device's own display settings stay (code review, 2026-09-30: they carried over to the next account).
  Future<void> clearAccount() async {
    _syncTimer?.cancel();
    webtoonSeries.clear(); // (another account: other series)
    _api = null;
    _loaded = false;
    defaults = const ReaderPrefs();
    webtoonDefaults = webtoonStart;
    _dirtyWebtoon = false;
    epub = _withOwn(const EpubPrefs()); // (this device's font and size stay)
    library = const LibraryPrefs();
    _posterLookFollows();
    series.removeWhere((id, _) => !isLocalId(id)); // (this device's own stay)
    _dirtySeries.clear();
    _dirtyDefault = false;
    _dirtyEpub = false;
    _dirtyLibrary = false;
    _versions.clear();
    syncError = null;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.remove(_localReader);
    await p.remove(_unsentKey);
  }

  /// A series' settings as they apply: each part (page layout, image) its own when overridden, else the defaults'.
  ReaderPrefs prefsFor(String? seriesId) {
    final base = defaultsFor(seriesId); // (a webtoon's, or a comic's)
    final own = seriesId != null ? series[seriesId] : null;
    if (own == null) return base.copyWith(ownLayout: false, ownImage: false);
    final layout = own.ownLayout ? own : base;
    final image = own.ownImage ? own : base;
    return layout.withImageOf(image).copyWith(ownLayout: own.ownLayout, ownImage: own.ownImage);
  }

  bool ownsLayout(String seriesId) => series[seriesId]?.ownLayout ?? false;
  bool ownsImage(String seriesId) => series[seriesId]?.ownImage ?? false;

  /// The series' page layout (fit, direction, background) from [p] - overriding the defaults from now on.
  void setSeriesLayout(String seriesId, ReaderPrefs p) {
    final now = prefsFor(seriesId);
    setSeries(seriesId, now.copyWith(fit: p.fit, direction: p.direction, background: p.background,
        twoPages: p.twoPages, gutter: p.gutter, ownLayout: true,
        ownImage: now.ownImage));
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
  Future<void> load(BookSource api, {bool fetch = true}) async {
    _api = api;
    final p = await SharedPreferences.getInstance();
    final d = p.getString(_localDisplay);
    webtoonSeries
      ..clear()
      ..addAll(p.getStringList(_webtoonSeriesKey) ?? const []);
    final savedDisplay = d == null ? null : jsonDecode(d) as Map<String, dynamic>;
    if (savedDisplay != null) display = DisplayPrefs.fromJson(savedDisplay);
    _posterLookFollows();
    final own = p.getString(_localEpubOwn); // (a new key: from the defaults until set here - no migration)
    final ownPrefs = own == null ? const EpubPrefs() : EpubPrefs.fromJson(jsonDecode(own) as Map<String, dynamic>);
    epub = epub.copyWith(font: ownPrefs.font, size: ownPrefs.size);
    _loadEpubBooks(p.getString(_epubBooksKey));
    try {
      final u = jsonDecode(p.getString(_unsentKey) ?? '{}') as Map;
      _dirtySeries
        ..clear()
        ..addAll([for (final id in (u['series'] as List? ?? const [])) id as String]);
      _dirtyDefault = u['default'] == true;
      _dirtyWebtoon = u['webtoon'] == true;
      _dirtyEpub = u['epub'] == true;
      _dirtyLibrary = u['library'] == true;
    } catch (_) {
      // damaged: nothing counts as unsent
    }
    final r = p.getString(_localReader);
    final savedReader = r == null ? null : jsonDecode(r) as Map<String, dynamic>;
    if (savedReader != null) _applyBlob(savedReader, remote: false);
    _applyHere(p.getString(_hereSeries));
    _posterLookFollows();
    applyBacklight();
    notifyListeners();
    _loaded = true;
    if (!fetch) return; // offline mode: this device's copy; what's unsent goes once online (useApi)
    await _fetch(p);
  }

  /// Komga's copy over this one - except this device's unsent changes (they stay, and go). Never re-reads the
  /// device's copy, and a copy asked for before a change here is dropped (code review 2026-10-05, #12); nobody is
  /// told when nothing changed (#45: each Home reload re-ran the whole load - re-parse, backlight, two app rebuilds).
  Future<void> _fetch(SharedPreferences p) async {
    try {
      _gate.asked();
      final before = jsonEncode(_blob());
      final remote = await _fetchRemote();
      if (remote != null && jsonEncode(_blob()) == before) {
        _applyBlob(remote, remote: true);
        final after = jsonEncode(_blob());
        if (after != before) {
          await p.setString(_localReader, after);
          _posterLookFollows();
          notifyListeners();
        }
      }
      syncError = null;
    } catch (e) {
      _syncNote('Using the settings saved on this device: ${explain(e).reason}.', e);
    }
    if (_anyDirty) _syncSoon(); // what didn't reach Komga goes now
  }

  bool _loaded = false;

  /// The EPUB settings (the reader's Aa panel, Settings > eBooks). Synced - but for the font and the text size, kept
  /// on this device only.
  void setEpub(EpubPrefs prefs) {
    if (prefs == epub) return;
    final synced = jsonEncode(prefs.syncJson()) != jsonEncode(epub.syncJson());
    final own = prefs.font != epub.font || prefs.size != epub.size;
    epub = prefs;
    if (own) {
      SharedPreferences.getInstance()
          .then((p) => p.setString(_localEpubOwn, jsonEncode({'font': prefs.font.name, 'size': prefs.size})));
    }
    if (!synced) {
      notifyListeners();
      return;
    }
    _dirtyEpub = true;
    _epubVersion++;
    _changedReader();
  }

  /// Posters' captions and Home's sections ([LibraryPrefs]). Synced.
  void setLibrary(LibraryPrefs prefs) {
    if (prefs == library) return;
    library = prefs;
    _dirtyLibrary = true;
    _libraryVersion++;
    _posterLookFollows();
    _changedReader();
  }

  void setSeries(String seriesId, ReaderPrefs prefs) {
    series[seriesId] = prefs;
    _dirty(seriesId);
    _changedReader();
  }

  void _dirty(String seriesId) {
    if (isLocalId(seriesId)) return; // (this device's own: nothing to send)
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

  /// Webtoons' reading defaults ([webtoonDefaults]). Synced.
  void setWebtoonDefault(ReaderPrefs prefs) {
    webtoonDefaults = prefs;
    _dirtyWebtoon = true;
    _webtoonVersion++;
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
    _posterLookFollows();
    if (backlightChanged) applyBacklight();
    notifyListeners();
    SharedPreferences.getInstance().then((p) => p.setString(_localDisplay, jsonEncode(d.toJson())));
  }

  /// The reader settings from Komga again - Home calls it each time it reloads, so a change made on another device
  /// arrives without a restart (user, 2026-10-05). Several reloads in a row ask once ([RefreshGate]).
  Future<void> refresh({bool force = false}) async {
    if (_api == null || !_loaded) return;
    final p = await SharedPreferences.getInstance();
    await _gate.run(() => _fetch(p), force: force); // (force: Sync now)
  }

  final _gate = RefreshGate();

  // Screen brightness (and the extra dim below the screen's minimum) is the reader's: it applies while a book is open,
  // and everywhere else the screen follows the system (user, 2026-10-05: left at extra dim from reading in bed, the
  // app opened unreadably dark in daylight - Settings included, where it could be undone).
  int _readers = 0;
  bool get inReader => _readers > 0;

  /// A book opened / closed ([ReaderScreen]): the reader's brightness on, back to the system's. Called from its
  /// initState / dispose, where the overlay above can't be rebuilt there and then: it's told just after.
  void readerOpened() {
    if (_readers++ == 0) {
      applyBacklight();
      scheduleMicrotask(notifyListeners);
    }
  }

  void readerClosed() {
    if (_readers == 0) return;
    if (--_readers == 0) {
      applyBacklight();
      scheduleMicrotask(notifyListeners);
    }
  }

  /// The reader's brightness is shown: a book is open, or its slider in Settings is being used (dragged, or the
  /// remote on it) - the slider shows nothing otherwise, the reader being the only place it applies (user, 2026-10-07).
  bool get brightnessShown => inReader || _previewing.isNotEmpty;
  final _previewing = <Object>{};

  /// [who] (a slider) starts or stops previewing the reader's brightness.
  void previewBrightness(Object who, bool on) {
    final was = brightnessShown;
    on ? _previewing.add(who) : _previewing.remove(who);
    if (brightnessShown == was) return;
    applyBacklight();
    scheduleMicrotask(notifyListeners); // (it can come from a dispose, where the overlay can't be rebuilt there and then)
  }

  void applyBacklight() => setScreenBrightness(brightnessShown ? display.backlight : -1);

  void _changedReader() {
    notifyListeners();
    SharedPreferences.getInstance().then((p) async {
      await p.setString(_localReader, jsonEncode(_blob()));
      await p.setString(_hereSeries, jsonEncode(_hereBlob()));
    });
    _saveUnsent();
    if (_api != null) _syncSoon(); // not connected yet: it's unsent, and goes when Komga is (load / useApi)
  }

  Future<void> _sync() async {
    if (_syncing) { // one at a time: this one's turn comes after
      _syncAgain = true;
      return;
    }
    final api = _api;
    if (api == null || !_anyDirty) return;
    _syncing = true;
    final sending = {for (final id in _dirtySeries) id: _versions[id] ?? 0};
    final sendDefault = _dirtyDefault;
    final defaultVersion = _defaultVersion;
    final sendWebtoon = _dirtyWebtoon;
    final webtoonVersion = _webtoonVersion;
    final sendEpub = _dirtyEpub;
    final epubVersion = _epubVersion;
    final sendLibrary = _dirtyLibrary;
    final libraryVersion = _libraryVersion;
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
      if (sendWebtoon) merged['webtoon'] = webtoonDefaults.toJson();
      if (sendEpub) merged['epub'] = epub.syncJson();
      if (sendLibrary) merged['library'] = library.toJson();
      await api.putClientSetting(komgaKey, jsonEncode(merged));
      // sent - unless it changed again meanwhile: then it's still to send
      for (final e in sending.entries) {
        if ((_versions[e.key] ?? 0) == e.value) _dirtySeries.remove(e.key);
      }
      if (sendDefault && _defaultVersion == defaultVersion) _dirtyDefault = false;
      if (sendWebtoon && _webtoonVersion == webtoonVersion) _dirtyWebtoon = false;
      if (sendEpub && _epubVersion == epubVersion) _dirtyEpub = false;
      if (sendLibrary && _libraryVersion == libraryVersion) _dirtyLibrary = false;
      await _saveUnsent();
      syncError = null;
      if (_anyDirty) _syncAgain = true;
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
        'webtoon': webtoonDefaults.toJson(),
        'epub': epub.syncJson(),
        'library': library.toJson(),
        'series': {for (final e in series.entries) e.key: e.value.toJson()},
      };

  /// This device's own series' settings (a local library's).
  Map<String, dynamic> _hereBlob() => {for (final e in series.entries) if (isLocalId(e.key)) e.key: e.value.toJson()};

  void _applyHere(String? raw) {
    if (raw == null) return;
    try {
      (jsonDecode(raw) as Map).forEach((id, v) {
        if (isLocalId(id as String)) series[id] = ReaderPrefs.fromJson(Map<String, dynamic>.from(v as Map));
      });
    } catch (_) {
      // damaged: none
    }
  }

  /// A saved copy - this device's ([remote] false) or Komga's - replaces what's here, except this device's changes
  /// that haven't reached Komga yet: those stay as they are (changed, or removed). So a series whose own settings were
  /// removed on another device goes here too (code review, 2026-09-30: it used to stay for good).
  void _applyBlob(Map<String, dynamic> b, {required bool remote}) {
    final d = b['default'];
    if (d is Map<String, dynamic> && !(remote && _dirtyDefault)) defaults = ReaderPrefs.fromJson(d);
    final w = b['webtoon'];
    if (w is Map<String, dynamic> && !(remote && _dirtyWebtoon)) webtoonDefaults = ReaderPrefs.fromJson(w);
    final e = b['epub'];
    if (e is Map<String, dynamic> && !(remote && _dirtyEpub)) epub = _withOwn(EpubPrefs.fromJson(e));
    final l = b['library'];
    if (l is Map<String, dynamic> && !(remote && _dirtyLibrary)) library = LibraryPrefs.fromJson(l);
    final s = b['series'];
    if (s is! Map) return;
    final next = <String, ReaderPrefs>{
      for (final e in s.entries)
        if (!(remote && _dirtySeries.contains(e.key)))
          e.key as String: ReaderPrefs.fromJson(Map<String, dynamic>.from(e.value as Map)),
    };
    if (remote) {
      // (Komga's copy has none of this device's own: they stay)
      for (final e in series.entries) {
        if (isLocalId(e.key)) next[e.key] = e.value;
      }
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
