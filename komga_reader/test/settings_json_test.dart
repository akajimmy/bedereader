import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/settings.dart';

/// The saved forms of the settings: a series' reader settings ([ReaderPrefs], synced through Komga) and this device's
/// settings ([DisplayPrefs]) come back as they were, and saves from older builds get the defaults.
///
/// One table for what was spread over reader_test (reader prefs, build-4 sharpen, page turn, rotation / clock /
/// progress bar, double-tap zoom / volume keys, direction), panel_test (the override flags), app_settings_test (the
/// device settings) and night_schedule_test (schedule, text size, accent) - test audit, 2026-09-30.
void main() {
  test('the Gutter (user, 2026-10-20): comics 2 px and eBooks 24 by default, saved and read back; the comic one left '
      'out of the saved form at its default, as the other layout settings; a value that isn\'t one of the steps '
      '(2026-10-21): the default', () {
    expect(ReaderPrefs.fromJson(const ReaderPrefs(gutter: 8).toJson()).gutter, 8);
    expect(const ReaderPrefs().toJson().containsKey('gut'), isFalse);
    expect(ReaderPrefs.fromJson(const {}).gutter, 2);
    expect(ReaderPrefs.fromJson(const {'gut': 10}).gutter, 2, reason: 'dialled in with the old slider: the default');
    expect(const ReaderPrefs(gutter: 8, sharpen: true).imageReset().gutter, 8, reason: 'part of the page layout');
    expect(EpubPrefs.fromJson(const EpubPrefs(gutter: 48).toJson()).gutter, 48);
    expect(EpubPrefs.fromJson(const {}).gutter, 24);
    expect(EpubPrefs.fromJson(const {'gutter': 60}).gutter, 24);
  });

  test('the settings review (user, 2026-10-21) - fewer steps; a saved value that is no longer a step reads as the '
      'default (no migration - user rule): crop, keep the screen on, line spacing, margins, paragraph spacing', () {
    expect([for (final c in [0, 0.02, 0.04, 0.06, 0.05, 0.1]) ReaderPrefs.fromJson({'x': c}).crop],
        [0, 0.02, 0.04, 0.06, 0, 0]);
    expect([for (final m in [0, 10, DisplayPrefs.alwaysOn, 5, 20, 30]) DisplayPrefs.fromJson({'screenOn': m}).screenOn],
        [0, 10, DisplayPrefs.alwaysOn, 0, 0, 0]);
    expect([for (final l in [1.25, 1.5, 1.75, 1.0, 2.0, 1.45]) EpubPrefs.fromJson({'lineSpacing': l}).lineSpacing],
        [1.25, 1.5, 1.75, 1.5, 1.5, 1.5]);
    expect(EpubPrefs.fromJson(const {'margins': 'widest'}).margins, EpubMargins.normal);
    expect(EpubPrefs.fromJson(const {'margins': 'wider'}).margins, EpubMargins.wider);
    // Medium and Extra large keep their gaps as Normal and Large; Small and the old Large went
    expect([for (final g in ['book', 'none', 'small', 'huge', 'tiny', 'large'])
      EpubPrefs.fromJson({'paragraphGap': g}).paragraphGap.ems], [null, 0, 0.5, 1.5, 0, 0]);
    // the image's brightness and contrast went: a save that has them reads without them
    expect(ReaderPrefs.fromJson(const {'b': 0.2, 'c': -0.1, 's': true}), const ReaderPrefs(sharpen: true));
  });
  test('reader settings (ReaderPrefs) survive the JSON used for Komga sync; older saves read as they meant', () {
    // round trips
    const p = ReaderPrefs(fit: FitMode.height, sharpen: true, autoLevels: true, crop: 0.04);
    expect(ReaderPrefs.fromJson(p.toJson()), p);
    expect(ReaderPrefs.fromJson(p.toJson()).crop, 0.04, reason: 'crop edges');
    for (final direction in ReadingDirection.values) {
      expect(ReaderPrefs.fromJson(ReaderPrefs(direction: direction).toJson()).direction, direction,
          reason: 'direction ${direction.name}');
    }
    // the background: a reading setting since 2026-10-05; black (as everything saved before) isn't written
    for (final bg in ReaderBackground.values) {
      expect(ReaderPrefs.fromJson(ReaderPrefs(background: bg).toJson()).background, bg, reason: 'background ${bg.name}');
    }
    expect(const ReaderPrefs().toJson().containsKey('bg'), isFalse);
    // dual page mode: part of the layout since 2026-10-16; the default (Wide screen) isn't written
    for (final t in TwoPages.values) {
      expect(ReaderPrefs.fromJson(ReaderPrefs(twoPages: t).toJson()).twoPages, t, reason: 'dual page mode ${t.name}');
    }
    expect(const ReaderPrefs().toJson().containsKey('tp'), isFalse);
    expect(ReaderPrefs.fromJson({'fit': 'width'}).twoPages, TwoPages.wideScreen, reason: 'saved before: Wide screen');
    expect(const ReaderPrefs(twoPages: TwoPages.off, sharpen: true).imageReset().twoPages, TwoPages.off,
        reason: 'part of the layout: kept by an image reset');
    expect(ReaderPrefs.fromJson({'fit': 'width'}).background, ReaderBackground.black, reason: 'saved before: black');
    expect(const ReaderPrefs(background: ReaderBackground.white, sharpen: true).imageReset().background,
        ReaderBackground.white, reason: 'part of the layout: kept by an image reset');
    final flags = ReaderPrefs.fromJson(const ReaderPrefs(ownLayout: false).toJson());
    expect([flags.ownLayout, flags.ownImage], [false, true], reason: 'the override flags');
    final image = ReaderPrefs.fromJson(const ReaderPrefs(ownImage: false).toJson());
    expect([image.ownLayout, image.ownImage], [true, false], reason: 'the override flags: the image one');
    expect(const ReaderPrefs().toJson().containsKey('ol'), isFalse); // unchanged form for everything saved before

    // older saves: (what was saved, what it reads as)
    for (final (saved, read, expected, why) in <(Map<String, dynamic>, Object? Function(ReaderPrefs), Object?, String)>[
      ({'fit': 'width'}, (p) => p.direction, ReadingDirection.auto, 'from before the direction: Auto'),
      ({'fit': 'width'}, (p) => p.ownLayout, true, 'from before the toggles: overrides the layout'),
      ({'fit': 'width'}, (p) => p.ownImage, true, 'from before the toggles: overrides the image'),
    ]) {
      expect(read(ReaderPrefs.fromJson(saved)), expected, reason: '$why ($saved)');
    }

    // resetting the image settings keeps the direction (part of the layout)
    expect(const ReaderPrefs(direction: ReadingDirection.rtl, sharpen: true).imageReset().direction, ReadingDirection.rtl);
  });

  test("this device's settings (DisplayPrefs) survive the saved form; a save without them gets the defaults; a value "
      "that isn't a choice gets the default", () {
    // every setting away from its default at once: (name, read it, the value set, its default)
    const changed = DisplayPrefs(night: true, warmth: 0.3, brightness: 0.4, pageTurn: PageTurn.curl, epubTurn: EpubTurn.curl,
        comics: KindPrefs(hiddenSpots: ['left']), ebooks: KindPrefs(hiddenSpots: ['right', 'centre']),
        webtoons: KindPrefs(hiddenSpots: ['centre']), webtoonTaps: WebtoonTaps.topBottom, autoScrollSpeed: 120, webtoonDoubleTap: false,
        rotation: Rotation.landscape, pageNote: PageNote.off, showClock: true, showBattery: true, progressBar: true,
        doubleTapZoom: false, midBook: MidBook.keep,
        screenOn: 10, posterSize: PosterSize.small,
        nightSchedule: true, nightFrom: 1320, nightTo: 360, textScale: 1.15, accent: Accent.green,
        pageStrip: true, insetPage: InsetPage.never, webtoonScroll: WebtoonScroll.page, sourceIcon: true,
        autoCropBorder: 0.03);
    final settings = <(String, Object? Function(DisplayPrefs), Object?, Object?)>[
      ('night', (d) => d.night, true, false),
      ('warmth', (d) => d.warmth, 0.3, 0.5),
      ('brightness', (d) => d.brightness, 0.4, null),
      ('pageTurn', (d) => d.pageTurn, PageTurn.curl, PageTurn.swipe),
      ('epubTurn', (d) => d.epubTurn, EpubTurn.curl, EpubTurn.slide), // eBooks' page turn: this device's (2026-10-21)
      // one set for both kinds (user, 2026-10-21), the comics' defaults
      ('rotation', (d) => d.rotation, Rotation.landscape, Rotation.auto),
      ('pageNote', (d) => d.pageNote, PageNote.off, PageNote.afterTurn),
      ('showClock', (d) => d.showClock, true, false),
      ('showBattery', (d) => d.showBattery, true, false),
      ('progressBar', (d) => d.progressBar, true, false),
      // each kind its own (user, 2026-10-07)
      ('comics hiddenSpots', (d) => d.comics.hiddenSpots.join(','), 'left', ''),
      ('ebooks hiddenSpots', (d) => d.ebooks.hiddenSpots.join(','), 'right,centre', ''),
      ('webtoons hiddenSpots', (d) => d.webtoons.hiddenSpots.join(','), 'centre', ''), // (their own - 2026-10-22)
      ('webtoonTaps', (d) => d.webtoonTaps, WebtoonTaps.topBottom, WebtoonTaps.sides),
      ('autoScrollSpeed', (d) => d.autoScrollSpeed, 120.0, DisplayPrefs.autoScrollStart),
      ('webtoonDoubleTap', (d) => d.webtoonDoubleTap, false, true), // (webtoons' own - 2026-10-22)
      ('doubleTapZoom', (d) => d.doubleTapZoom, false, true),
      ('midBook', (d) => d.midBook, MidBook.keep, MidBook.ask),
      ('screenOn', (d) => d.screenOn, 10, 0),
      ('posterSize', (d) => d.posterSize, PosterSize.small, PosterSize.medium),
      ('nightSchedule', (d) => d.nightSchedule, true, false),
      ('nightFrom', (d) => d.nightFrom, 1320, 21 * 60),
      ('nightTo', (d) => d.nightTo, 360, 7 * 60),
      ('textScale', (d) => d.textScale, 1.15, 1.0),
      ('accent', (d) => d.accent, Accent.green, Accent.royal),
      ('pageStrip', (d) => d.pageStrip, true, false), // the reader's page strip left open (user, 2026-10-02)
      ('insetPage', (d) => d.insetPage, InsetPage.never, InsetPage.wideScreen),
      ('webtoonScroll', (d) => d.webtoonScroll, WebtoonScroll.page, WebtoonScroll.smooth), // (2026-10-22) // eBooks' sheet, this device's (2026-10-12)
      ('sourceIcon', (d) => d.sourceIcon, true, false), // where books come from, on posters (2026-10-26)
      ('autoCropBorder', (d) => d.autoCropBorder, 0.03, 0.025), // Crop edges' Auto, temporary (2026-10-28)
    ];
    final back = DisplayPrefs.fromJson(changed.toJson());
    final none = DisplayPrefs.fromJson({}); // a save with none of them
    final onlyTurn = DisplayPrefs.fromJson({'pageTurn': 'flip'}); // ... with only the page turn
    for (final (name, read, set, byDefault) in settings) {
      expect(read(changed), set, reason: '$name: the table matches the settings above');
      expect(read(back), set, reason: '$name survives the saved form');
      expect(read(none), byDefault, reason: '$name: missing from a save, the default');
      expect(read(onlyTurn), name == 'pageTurn' ? PageTurn.flip : byDefault, reason: '$name, a save with only a turn');
    }
    // the table has every saved setting (a new one fails here until it has a row)
    expect(settings.length, changed.toJson().length - 3 + changed.comics.toJson().length * 3,
        reason: 'one row per setting (the two kinds a row per field)');
    for (final turn in PageTurn.values) {
      expect(DisplayPrefs.fromJson(DisplayPrefs(pageTurn: turn).toJson()).pageTurn, turn, reason: turn.name);
    }

    // not a choice: the default
    expect(DisplayPrefs.fromJson({'screenOn': 7}).screenOn, 0);
    expect(DisplayPrefs.fromJson({'textScale': 3.0}).textScale, 1.0);
  });

  test("the accent palette (user's worksheet, 2026-10-27): a colour saved under a name that's gone - Blue, the old "
      'default, among them - starts on the new default, Royal; one kept stays', () {
    for (final gone in ['blue', 'red', 'magenta', 'silver', 'slate']) {
      expect(DisplayPrefs.fromJson({'accent': gone}).accent, Accent.royal, reason: gone);
    }
    expect(DisplayPrefs.fromJson({'accent': 'yellow'}).accent, Accent.yellow);
    expect(const DisplayPrefs().accent, Accent.royal, reason: 'a fresh install');
    expect(Accent.values, hasLength(24));
  });

  test("the account's library look (LibraryPrefs, synced - user, 2026-10-22) survives the saved form; a save without "
      'it gets the defaults: comic posters series #, title and date; eBook posters title and author; Home as shipped',
      () {
    const changed = LibraryPrefs(posterSeries: false, posterTitle: false, posterDate: false, ebookPosterTitle: false,
        ebookPosterAuthor: false, ebookPosterSeries: true, ebookPosterDate: true, homeShown: {'ondeck': false},
        homeOrder: ['pinned', 'continue']);
    expect(LibraryPrefs.fromJson(changed.toJson()), changed);
    expect(LibraryPrefs.fromJson(jsonDecode(jsonEncode(changed.toJson())) as Map<String, dynamic>), changed,
        reason: 'through JSON text, as stored');
    expect(LibraryPrefs.fromJson({}), const LibraryPrefs());
    const d = LibraryPrefs();
    expect((d.posterSeries, d.posterTitle, d.posterDate), (true, true, true));
    expect((d.ebookPosterTitle, d.ebookPosterAuthor, d.ebookPosterSeries, d.ebookPosterDate), (true, true, false, false));
  });

  test("each kind's position text is its own: one changed, the other not", () {
    const none = DisplayPrefs();
    final apart = DisplayPrefs.fromJson(
        none.withKind(BookKind.ebooks, none.ebooks.copyWith(hiddenSpots: ['right'])).toJson());
    expect(apart.comics.hiddenSpots, isEmpty);
    expect(apart.ebooks.hiddenSpots, ['right']);
  });
}
