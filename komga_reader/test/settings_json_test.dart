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
    const changed = DisplayPrefs(night: true, warmth: 0.3, brightness: 0.4, pageTurn: PageTurn.curl,
        comics: KindPrefs(rotation: Rotation.landscape, clock: ShowWhen.always, progressBar: true,
            pageNote: PageNote.off, hiddenSpots: ['left']),
        ebooks: KindPrefs(rotation: Rotation.portrait, clock: ShowWhen.off, pageNote: PageNote.afterTurn,
            progressBar: true, hiddenSpots: ['right', 'centre']),
        doubleTapZoom: false, midBook: MidBook.keep,
        screenOn: 10, posterSize: PosterSize.small, posterSeries: false, posterTitle: false,
        nightSchedule: true, nightFrom: 1320, nightTo: 360, textScale: 1.15, accent: Accent.green,
        pageStrip: true, posterDate: false, insetPage: InsetPage.never,
        ebookPosterTitle: false, ebookPosterAuthor: false, ebookPosterSeries: true, ebookPosterDate: true);
    final settings = <(String, Object? Function(DisplayPrefs), Object?, Object?)>[
      ('night', (d) => d.night, true, false),
      ('warmth', (d) => d.warmth, 0.3, 0.5),
      ('brightness', (d) => d.brightness, 0.4, null),
      ('pageTurn', (d) => d.pageTurn, PageTurn.curl, PageTurn.swipe),
      // each kind its own (user, 2026-10-07)
      ('comics pageNote', (d) => d.comics.pageNote, PageNote.off, PageNote.afterTurn),
      ('comics rotation', (d) => d.comics.rotation, Rotation.landscape, Rotation.auto),
      ('comics clock', (d) => d.comics.clock, ShowWhen.always, ShowWhen.withControls),
      ('comics progressBar', (d) => d.comics.progressBar, true, false),
      ('comics hiddenSpots', (d) => d.comics.hiddenSpots.join(','), 'left', ''),
      ('ebooks pageNote', (d) => d.ebooks.pageNote, PageNote.afterTurn, PageNote.always),
      ('ebooks rotation', (d) => d.ebooks.rotation, Rotation.portrait, Rotation.auto),
      ('ebooks clock', (d) => d.ebooks.clock, ShowWhen.off, ShowWhen.withControls),
      ('ebooks progressBar', (d) => d.ebooks.progressBar, true, false),
      ('ebooks hiddenSpots', (d) => d.ebooks.hiddenSpots.join(','), 'right,centre', ''),
      ('doubleTapZoom', (d) => d.doubleTapZoom, false, true),
      ('midBook', (d) => d.midBook, MidBook.keep, MidBook.ask),
      ('screenOn', (d) => d.screenOn, 10, 0),
      ('posterSize', (d) => d.posterSize, PosterSize.small, PosterSize.medium),
      ('posterSeries', (d) => d.posterSeries, false, true),
      ('posterTitle', (d) => d.posterTitle, false, true),
      ('nightSchedule', (d) => d.nightSchedule, true, false),
      ('nightFrom', (d) => d.nightFrom, 1320, 21 * 60),
      ('nightTo', (d) => d.nightTo, 360, 7 * 60),
      ('textScale', (d) => d.textScale, 1.15, 1.0),
      ('accent', (d) => d.accent, Accent.green, Accent.blue),
      ('pageStrip', (d) => d.pageStrip, true, false), // the reader's page strip left open (user, 2026-10-02)
      ('posterDate', (d) => d.posterDate, false, true), // release dates on book posters (user, 2026-10-06)
      // eBook posters' own lines (user, 2026-10-18): title and author unless changed
      ('ebookPosterTitle', (d) => d.ebookPosterTitle, false, true),
      ('ebookPosterAuthor', (d) => d.ebookPosterAuthor, false, true),
      ('ebookPosterSeries', (d) => d.ebookPosterSeries, true, false),
      ('ebookPosterDate', (d) => d.ebookPosterDate, true, false),
      ('insetPage', (d) => d.insetPage, InsetPage.never, InsetPage.wideScreen), // eBooks' sheet, this device's (2026-10-12)
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
    expect(settings.length, changed.toJson().length - 2 + changed.comics.toJson().length * 2,
        reason: 'one row per setting (the two kinds a row per field)');
    for (final turn in PageTurn.values) {
      expect(DisplayPrefs.fromJson(DisplayPrefs(pageTurn: turn).toJson()).pageTurn, turn, reason: turn.name);
    }

    // not a choice: the default
    expect(DisplayPrefs.fromJson({'screenOn': 7}).screenOn, 0);
    expect(DisplayPrefs.fromJson({'textScale': 3.0}).textScale, 1.0);
  });

  test("each kind's settings: one saved without some of them gets that kind's defaults for them; one kind changed "
      'leaves the other as it was', () {
    const none = DisplayPrefs();
    // a kind saved without some of its settings: that kind's defaults for them
    final part = DisplayPrefs.fromJson({'comics': {'clock': 'off'}, 'ebooks': {'clock': 'off'}});
    expect((part.comics.pageNote, part.ebooks.pageNote), (PageNote.afterTurn, PageNote.always));
    // each kind set apart: one changed, the other not
    final apart = DisplayPrefs.fromJson(
        none.withKind(BookKind.ebooks, none.ebooks.copyWith(pageNote: PageNote.off)).toJson());
    expect((apart.comics.pageNote, apart.ebooks.pageNote), (PageNote.afterTurn, PageNote.off));
  });
}
