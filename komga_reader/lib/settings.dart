import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'errors.dart';
import 'refresh_gate.dart';
import 'screen.dart';

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
      this.ownImage = true, this.background = ReaderBackground.black});

  /// A series' settings come in two parts, each overriding the defaults or not (the panels' "Override the
  /// defaults" toggles, user 2026-09-30): the page layout (fit, direction, background) and the image settings. A part
  /// not overridden follows the defaults. Series saved before this override both (unchanged). Unused on the defaults.
  final bool ownLayout, ownImage;

  final FitMode fit;
  final ReadingDirection direction; // auto = the series' reading direction in Komga
  // around the page - a reading default with a series' own (user, 2026-10-05; it was a setting of each device)
  final ReaderBackground background;
  final double brightness; // -0.5 .. 0.5, added to every channel
  final double contrast; // -0.5 .. 0.5, stretch around mid-grey
  final bool sharpen; // shown as "Enhance": denoise + Lanczos scaling + RCAS (lib/enhance.dart); key kept for sync
  final bool autoLevels; // shown as "Enhance colours": auto-levels + whiten paper + deepen ink (lib/enhance.dart)
  final double crop; // "Crop edges": this fraction of the page cut off every side (0 .. 0.1)

  static const maxCrop = 0.10;

  bool get neutralImage => brightness == 0 && contrast == 0 && !sharpen && !autoLevels && crop == 0;

  ReaderPrefs copyWith({FitMode? fit, double? brightness, double? contrast, bool? sharpen, bool? autoLevels,
          ReadingDirection? direction, double? crop, bool? ownLayout, bool? ownImage, ReaderBackground? background}) =>
      ReaderPrefs(fit: fit ?? this.fit, brightness: brightness ?? this.brightness, contrast: contrast ?? this.contrast,
          sharpen: sharpen ?? this.sharpen, autoLevels: autoLevels ?? this.autoLevels,
          direction: direction ?? this.direction, crop: crop ?? this.crop, ownLayout: ownLayout ?? this.ownLayout,
          ownImage: ownImage ?? this.ownImage, background: background ?? this.background);

  /// Same page layout (fit, direction, background), image settings back to neutral.
  ReaderPrefs imageReset() => ReaderPrefs(fit: fit, direction: direction, ownLayout: ownLayout, ownImage: ownImage,
      background: background);

  /// This one's page layout (fit, direction, background) with [image]'s image settings.
  ReaderPrefs withImageOf(ReaderPrefs image) => copyWith(brightness: image.brightness, contrast: image.contrast,
      sharpen: image.sharpen, autoLevels: image.autoLevels, crop: image.crop);

  Map<String, dynamic> toJson() => {
        'fit': fit.name, 'b': brightness, 'c': contrast, 's': sharpen, 'l': autoLevels, 'd': direction.name, 'x': crop,
        // written only when off, so everything saved before (and the defaults) reads exactly as it did
        if (!ownLayout) 'ol': false,
        if (!ownImage) 'oi': false,
        if (background != ReaderBackground.black) 'bg': background.name, // (likewise: black, as before, unwritten)
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
        background: ReaderBackground.values.firstWhere((b) => b.name == j['bg'], orElse: () => ReaderBackground.black),
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

/// The note in the page's corner while reading ([KindPrefs.pageNote]): always there, for a moment after each
/// turn, or not at all (user, 2026-10-06: option H, for EPUBs; both kinds since 2026-10-07).
enum PageNote { always, afterTurn, off }

/// The two kinds of book the one Reader reads (a renderer each).
enum BookKind { comics, ebooks }

/// The reading settings each kind of book has its own of (user, 2026-10-07, settings option A: the page corner,
/// rotation, clock, progress bar and the position text set apart for comics and for eBooks). This device.
@immutable
class KindPrefs {
  const KindPrefs({this.pageNote = PageNote.always, this.rotation = Rotation.auto, this.clock = ShowWhen.withControls,
      this.progressBar = false, this.hiddenSpots = const []});

  /// The note in the page's bottom-right corner, "12 / 36".
  final PageNote pageNote;
  final Rotation rotation; // follow the device, or hold portrait / landscape (Android)
  final ShowWhen clock; // the time and battery - top right, or on the top bar with the controls up
  final bool progressBar; // a thin line along the bottom while the controls are hidden (their slider shows it)
  /// The position text's spots not shown ('left', 'centre', 'right' - lib/reader/position_row.dart).
  final List<String> hiddenSpots;

  KindPrefs copyWith({PageNote? pageNote, Rotation? rotation, ShowWhen? clock, bool? progressBar,
          List<String>? hiddenSpots}) =>
      KindPrefs(pageNote: pageNote ?? this.pageNote, rotation: rotation ?? this.rotation, clock: clock ?? this.clock,
          progressBar: progressBar ?? this.progressBar, hiddenSpots: hiddenSpots ?? this.hiddenSpots);

  Map<String, dynamic> toJson() => {'pageNote': pageNote.name, 'rotation': rotation.name, 'clock': clock.name,
      'progressBar': progressBar, 'hiddenSpots': hiddenSpots};

  /// From [j]; anything it lacks, [fallback]'s (the kind's defaults).
  factory KindPrefs.fromJson(Map<String, dynamic> j, {KindPrefs fallback = const KindPrefs()}) {
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.firstWhere((v) => v.name == name, orElse: () => fallback);
    final spots = j['hiddenSpots'];
    return KindPrefs(
      pageNote: pick(PageNote.values, j['pageNote'], fallback.pageNote),
      rotation: pick(Rotation.values, j['rotation'], fallback.rotation),
      clock: pick(ShowWhen.values, j['clock'], fallback.clock),
      progressBar: j['progressBar'] is bool ? j['progressBar'] as bool : fallback.progressBar,
      hiddenSpots: spots is List ? [for (final v in spots) if (v is String) v] : fallback.hiddenSpots,
    );
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
      this.doubleTapZoom = true, this.midBook = MidBook.ask,
      this.screenOn = 0, this.posterSize = PosterSize.medium,
      this.posterSeries = true, this.posterTitle = true, this.posterDate = true,
      this.nightSchedule = false, this.nightFrom = 21 * 60, this.nightTo = 7 * 60,
      this.textScale = 1.0, this.accent = Accent.blue, this.pagePreviews = true, this.pageStrip = false,
      this.comics = const KindPrefs(pageNote: PageNote.afterTurn), this.ebooks = const KindPrefs()});
  final bool night;

  /// The reading settings set apart per kind of book ([KindPrefs]).
  final KindPrefs comics, ebooks;
  KindPrefs kind(BookKind k) => k == BookKind.comics ? comics : ebooks;

  /// Book posters' caption, any of three lines, always in this order (user, 2026-10-07): the series and number
  /// ("Saga #12"), the book's title, the release date ("13 Mar 2024").
  final bool posterSeries, posterTitle, posterDate;
  /// reader: the page strip (the Pages button) is open - it stays open, book after book, until closed with the
  /// button (user, 2026-10-02)
  final bool pageStrip;
  /// reader: a picture of the page over the slider's thumb while picking one. Komga makes each from the book file as
  /// it's asked, so on a slow link to the books they lag (user, 2026-09-30): off, just the page number.
  final bool pagePreviews;
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
  static const screenOnChoices = [0, 5, 10, 20, 30, alwaysOn];
  final PageTurn pageTurn; // comics' page-turn animation (this device)
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

  /// Each kind's own reading settings are changed with [withKind] (one kind) or [bothKinds].
  DisplayPrefs copyWith({bool? night, double? warmth, double? Function()? brightness, PageTurn? pageTurn,
          bool? doubleTapZoom, MidBook? midBook, int? screenOn, PosterSize? posterSize,
          bool? nightSchedule, int? nightFrom, int? nightTo, double? textScale, Accent? accent,
          bool? pagePreviews, bool? pageStrip, bool? posterSeries, bool? posterTitle, bool? posterDate,
          KindPrefs? comics, KindPrefs? ebooks}) =>
      DisplayPrefs(
        comics: comics ?? this.comics, ebooks: ebooks ?? this.ebooks,
        pagePreviews: pagePreviews ?? this.pagePreviews, pageStrip: pageStrip ?? this.pageStrip,
        posterSeries: posterSeries ?? this.posterSeries, posterTitle: posterTitle ?? this.posterTitle,
        posterDate: posterDate ?? this.posterDate,
        nightSchedule: nightSchedule ?? this.nightSchedule, nightFrom: nightFrom ?? this.nightFrom,
        nightTo: nightTo ?? this.nightTo, textScale: textScale ?? this.textScale, accent: accent ?? this.accent,
        night: night ?? this.night, warmth: warmth ?? this.warmth,
        brightness: brightness != null ? brightness() : this.brightness, pageTurn: pageTurn ?? this.pageTurn,
        doubleTapZoom: doubleTapZoom ?? this.doubleTapZoom, midBook: midBook ?? this.midBook,
        screenOn: screenOn ?? this.screenOn, posterSize: posterSize ?? this.posterSize);

  /// Kind [k]'s reading settings changed.
  DisplayPrefs withKind(BookKind k, KindPrefs p) =>
      k == BookKind.comics ? copyWith(comics: p) : copyWith(ebooks: p);

  /// Both kinds' reading settings changed the same way.
  DisplayPrefs bothKinds(KindPrefs Function(KindPrefs k) change) =>
      copyWith(comics: change(comics), ebooks: change(ebooks));

  Map<String, dynamic> toJson() => {'night': night, 'warmth': warmth, 'brightness': brightness,
      'pageTurn': pageTurn.name, 'doubleTapZoom': doubleTapZoom,
      'midBook': midBook.name, 'screenOn': screenOn, 'posterSize': posterSize.name,
      'posterSeries': posterSeries, 'posterTitle': posterTitle, 'posterDate': posterDate,
      'nightSchedule': nightSchedule, 'nightFrom': nightFrom, 'nightTo': nightTo, 'textScale': textScale,
      'accent': accent.name, 'pagePreviews': pagePreviews, 'pageStrip': pageStrip,
      'comics': comics.toJson(), 'ebooks': ebooks.toJson()};
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
        doubleTapZoom: j['doubleTapZoom'] != false,
        midBook: pick(MidBook.values, j['midBook'], MidBook.ask),
        // default Off (user, 2026-09-30): "always on" drained the tablet's battery overnight when they fell asleep reading
        screenOn: on is int && screenOnChoices.contains(on) ? on : 0,
        posterSize: pick(PosterSize.values, j['posterSize'], PosterSize.medium),
        posterSeries: j['posterSeries'] != false,
        posterTitle: j['posterTitle'] != false,
        posterDate: j['posterDate'] != false,
        nightSchedule: j['nightSchedule'] == true,
        nightFrom: minutes(j['nightFrom'], 21 * 60),
        nightTo: minutes(j['nightTo'], 7 * 60),
        textScale: textScales.contains(j['textScale']) ? (j['textScale'] as num).toDouble() : 1.0,
        accent: pick(Accent.values, j['accent'], Accent.blue),
        pagePreviews: j['pagePreviews'] != false, // on unless switched off
        pageStrip: j['pageStrip'] == true,
        comics: kind('comics', none.comics),
        ebooks: kind('ebooks', none.ebooks));
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
  dark(Color(0xFF1B1B1D), Color(0xFFE4E0D8), 'Dark'),
  sepia(Color(0xFFF4ECD8), Color(0xFF5B4636), 'Sepia'),
  light(Color(0xFFFFFFFF), Color(0xFF1A1A1A), 'Light');

  const EpubColours(this.background, this.text, this.label);
  final Color background, text;
  final String label;
}

enum EpubMargins {
  narrow(18, 28, 40, 'Narrow'),
  normal(36, 40, 34, 'Normal'),
  wide(64, 56, 28, 'Wide');

  const EpubMargins(this.side, this.topBottom, this.lineEms, this.label);
  final double side, topBottom;

  /// The longest a line gets, in ems: on a wide screen the rest goes to the margins - so on a tablet or the PC the
  /// margins are set by this, not [side] (user, 2026-10-06: the setting "doesn't seem to do anything").
  final double lineEms;
  final String label;
}

/// Space added between paragraphs, in ems of the text (user, 2026-10-06: "an option to increase the spacing between
/// paragraphs"): on top of the book's own spacing, or of none with the reader's own formatting.
enum EpubParagraphGap {
  none(0, 'None'),
  small(0.5, 'Small'),
  large(1, 'Large');

  const EpubParagraphGap(this.ems, this.label);
  final double ems;
  final String label;
}

enum EpubTurn { slide, none }

/// The text's alignment (user, 2026-10-07: "Book's formatting" split in three): the book's own, or every paragraph
/// justified or ragged-right.
enum EpubAlign {
  book("Book's"), justified('Justified'), left('Left');

  const EpubAlign(this.label);
  final String label;
}

/// Paragraphs' first-line indents and the gaps between them: the book's own, or the reader's (indents only where the
/// book indents, the usual gaps taken out).
enum EpubParagraphs {
  book("Book's"), mine('Mine');

  const EpubParagraphs(this.label);
  final String label;
}

@immutable
class EpubPrefs {
  const EpubPrefs({this.font = EpubFont.literata, this.size = 19, this.lineSpacing = 1.45,
      this.margins = EpubMargins.normal, this.colours = EpubColours.dark, this.align = EpubAlign.justified,
      this.paragraphs = EpubParagraphs.mine, this.hyphenate = true, this.turn = EpubTurn.slide,
      this.paragraphGap = EpubParagraphGap.none});
  final EpubFont font;
  /// px at the app's text size - kept on this device (user, 2026-10-07: the tablet and the PC want their own); the
  /// rest of the set is synced
  final double size;
  final double lineSpacing;
  final EpubMargins margins;
  final EpubColours colours;
  final EpubAlign align;
  final EpubParagraphs paragraphs;
  final bool hyphenate;
  final EpubTurn turn;
  final EpubParagraphGap paragraphGap;

  static const sizes = [14.0, 15.0, 16.0, 17.0, 18.0, 19.0, 20.0, 22.0, 24.0, 26.0, 28.0, 32.0];
  static const spacings = [1.25, 1.45, 1.7];

  EpubPrefs copyWith({EpubFont? font, double? size, double? lineSpacing, EpubMargins? margins, EpubColours? colours,
          EpubAlign? align, EpubParagraphs? paragraphs, bool? hyphenate, EpubTurn? turn,
          EpubParagraphGap? paragraphGap}) =>
      EpubPrefs(font: font ?? this.font, size: size ?? this.size, lineSpacing: lineSpacing ?? this.lineSpacing,
          margins: margins ?? this.margins, colours: colours ?? this.colours, align: align ?? this.align,
          paragraphs: paragraphs ?? this.paragraphs, hyphenate: hyphenate ?? this.hyphenate, turn: turn ?? this.turn,
          paragraphGap: paragraphGap ?? this.paragraphGap);

  Map<String, dynamic> toJson() => {'font': font.name, 'size': size, 'lineSpacing': lineSpacing,
      'margins': margins.name, 'colours': colours.name, 'align': align.name, 'paragraphs': paragraphs.name,
      'hyphenate': hyphenate, 'turn': turn.name, 'paragraphGap': paragraphGap.name};

  factory EpubPrefs.fromJson(Map<String, dynamic> j) {
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.firstWhere((v) => v.name == name, orElse: () => fallback);
    final size = (j['size'] as num?)?.toDouble();
    final spacing = (j['lineSpacing'] as num?)?.toDouble();
    return EpubPrefs(
      font: pick(EpubFont.values, j['font'], EpubFont.literata),
      size: size != null && size >= 10 && size <= 48 ? size : 19,
      lineSpacing: spacing != null && spacing >= 1 && spacing <= 2.5 ? spacing : 1.45,
      margins: pick(EpubMargins.values, j['margins'], EpubMargins.normal),
      colours: pick(EpubColours.values, j['colours'], EpubColours.dark),
      align: pick(EpubAlign.values, j['align'], EpubAlign.justified),
      paragraphs: pick(EpubParagraphs.values, j['paragraphs'], EpubParagraphs.mine),
      hyphenate: j['hyphenate'] != false,
      turn: pick(EpubTurn.values, j['turn'], EpubTurn.slide),
      paragraphGap: pick(EpubParagraphGap.values, j['paragraphGap'], EpubParagraphGap.none),
    );
  }

  @override
  bool operator ==(Object other) => other is EpubPrefs && jsonEncode(other.toJson()) == jsonEncode(toJson());
  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

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

  /// Tells only of changes to how posters look (size, title only, release date): poster grids listen to this, not to
  /// every setting - a brightness slider drag rebuilt every grid under the reader (code review 2026-10-05, #44).
  final posterLook = ValueNotifier<(PosterSize, bool, bool, bool)>((PosterSize.medium, true, true, true));

  void _posterLookFollows() =>
      posterLook.value = (display.posterSize, display.posterSeries, display.posterTitle, display.posterDate);
  EpubPrefs epub = const EpubPrefs(); // EPUB books: one set, synced with the reading defaults (key "epub")
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
  bool _dirtyEpub = false;
  int _epubVersion = 0;
  // how many times each entry has changed: a send only clears the entries that didn't change again while it was on
  // its way (a change made mid-send used to be marked sent without being sent)
  final Map<String, int> _versions = {};
  int _defaultVersion = 0;
  bool _syncing = false, _syncAgain = false; // one sync at a time; one asked for meanwhile runs after it
  Timer? _syncTimer;

  /// Switch connection (online / offline) without reloading; a failed sync retries on its own.
  void useApi(Komga api) {
    _api = api;
    if (_dirtySeries.isNotEmpty || _dirtyDefault || _dirtyEpub) _syncSoon();
  }

  void _syncSoon([Duration after = const Duration(seconds: 2)]) {
    _syncTimer?.cancel();
    _syncTimer = Timer(after, _sync);
  }

  Future<void> _saveUnsent() async {
    final p = await SharedPreferences.getInstance();
    if (_dirtySeries.isEmpty && !_dirtyDefault && !_dirtyEpub) {
      await p.remove(_unsentKey);
    } else {
      await p.setString(_unsentKey,
          jsonEncode({'series': _dirtySeries.toList(), 'default': _dirtyDefault, 'epub': _dirtyEpub}));
    }
  }

  /// Signed out: the account's synced settings go from this device (they come back from Komga on signing in again);
  /// this device's own display settings stay (code review, 2026-09-30: they carried over to the next account).
  Future<void> clearAccount() async {
    _syncTimer?.cancel();
    _api = null;
    _loaded = false;
    defaults = const ReaderPrefs();
    epub = const EpubPrefs();
    series.clear();
    _dirtySeries.clear();
    _dirtyDefault = false;
    _dirtyEpub = false;
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

  /// The series' page layout (fit, direction, background) from [p] - overriding the defaults from now on.
  void setSeriesLayout(String seriesId, ReaderPrefs p) {
    final now = prefsFor(seriesId);
    setSeries(seriesId, now.copyWith(fit: p.fit, direction: p.direction, background: p.background, ownLayout: true,
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
  Future<void> load(Komga api, {bool fetch = true}) async {
    _api = api;
    final p = await SharedPreferences.getInstance();
    final d = p.getString(_localDisplay);
    final savedDisplay = d == null ? null : jsonDecode(d) as Map<String, dynamic>;
    if (savedDisplay != null) display = DisplayPrefs.fromJson(savedDisplay);
    _posterLookFollows();
    try {
      final u = jsonDecode(p.getString(_unsentKey) ?? '{}') as Map;
      _dirtySeries
        ..clear()
        ..addAll([for (final id in (u['series'] as List? ?? const [])) id as String]);
      _dirtyDefault = u['default'] == true;
      _dirtyEpub = u['epub'] == true;
    } catch (_) {
      // damaged: nothing counts as unsent
    }
    final r = p.getString(_localReader);
    final savedReader = r == null ? null : jsonDecode(r) as Map<String, dynamic>;
    if (savedReader != null) _applyBlob(savedReader, remote: false);
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
          notifyListeners();
        }
      }
      syncError = null;
    } catch (e) {
      _syncNote('Using the settings saved on this device: ${explain(e).reason}.', e);
    }
    if (_dirtySeries.isNotEmpty || _dirtyDefault || _dirtyEpub) _syncSoon(); // what didn't reach Komga goes now
  }

  bool _loaded = false;

  /// The EPUB settings (the reader's Aa panel, Settings > eBooks). Synced.
  void setEpub(EpubPrefs prefs) {
    if (prefs == epub) return;
    epub = prefs;
    _dirtyEpub = true;
    _epubVersion++;
    _changedReader();
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
    _posterLookFollows();
    if (backlightChanged) applyBacklight();
    notifyListeners();
    SharedPreferences.getInstance().then((p) => p.setString(_localDisplay, jsonEncode(d.toJson())));
  }

  /// The reader settings from Komga again - Home calls it each time it reloads, so a change made on another device
  /// arrives without a restart (user, 2026-10-05). Several reloads in a row ask once ([RefreshGate]).
  Future<void> refresh() async {
    if (_api == null || !_loaded) return;
    final p = await SharedPreferences.getInstance();
    await _gate.run(() => _fetch(p));
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

  void applyBacklight() => setScreenBrightness(inReader ? display.backlight : -1);

  void _changedReader() {
    notifyListeners();
    SharedPreferences.getInstance().then((p) => p.setString(_localReader, jsonEncode(_blob())));
    _saveUnsent();
    if (_api != null) _syncSoon(); // not connected yet: it's unsent, and goes when Komga is (load / useApi)
  }

  Future<void> _sync() async {
    if (_syncing) { // one at a time: this one's turn comes after
      _syncAgain = true;
      return;
    }
    final api = _api;
    if (api == null || (_dirtySeries.isEmpty && !_dirtyDefault && !_dirtyEpub)) return;
    _syncing = true;
    final sending = {for (final id in _dirtySeries) id: _versions[id] ?? 0};
    final sendDefault = _dirtyDefault;
    final defaultVersion = _defaultVersion;
    final sendEpub = _dirtyEpub;
    final epubVersion = _epubVersion;
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
      if (sendEpub) merged['epub'] = epub.toJson();
      await api.putClientSetting(komgaKey, jsonEncode(merged));
      // sent - unless it changed again meanwhile: then it's still to send
      for (final e in sending.entries) {
        if ((_versions[e.key] ?? 0) == e.value) _dirtySeries.remove(e.key);
      }
      if (sendDefault && _defaultVersion == defaultVersion) _dirtyDefault = false;
      if (sendEpub && _epubVersion == epubVersion) _dirtyEpub = false;
      await _saveUnsent();
      syncError = null;
      if (_dirtySeries.isNotEmpty || _dirtyDefault || _dirtyEpub) _syncAgain = true;
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
        'epub': epub.toJson(),
        'series': {for (final e in series.entries) e.key: e.value.toJson()},
      };

  /// A saved copy - this device's ([remote] false) or Komga's - replaces what's here, except this device's changes
  /// that haven't reached Komga yet: those stay as they are (changed, or removed). So a series whose own settings were
  /// removed on another device goes here too (code review, 2026-09-30: it used to stay for good).
  void _applyBlob(Map<String, dynamic> b, {required bool remote}) {
    final d = b['default'];
    if (d is Map<String, dynamic> && !(remote && _dirtyDefault)) defaults = ReaderPrefs.fromJson(d);
    final e = b['epub'];
    // the size is this device's (user, 2026-10-07): Komga's copy brings the rest of the set, not that
    if (e is Map<String, dynamic> && !(remote && _dirtyEpub)) {
      final incoming = EpubPrefs.fromJson(e);
      epub = remote ? incoming.copyWith(size: epub.size) : incoming;
    }
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
