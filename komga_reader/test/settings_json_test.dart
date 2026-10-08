import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/settings.dart';

/// The saved forms of the settings: a series' reader settings ([ReaderPrefs], synced through Komga) and this device's
/// settings ([DisplayPrefs]) come back as they were, and saves from older builds get the defaults.
///
/// One table for what was spread over reader_test (reader prefs, build-4 sharpen, page turn, rotation / clock /
/// progress bar, double-tap zoom / volume keys, direction), panel_test (the override flags), app_settings_test (the
/// device settings) and night_schedule_test (schedule, text size, accent) - test audit, 2026-09-30.
void main() {
  test('reader settings (ReaderPrefs) survive the JSON used for Komga sync; older saves read as they meant', () {
    // round trips
    const p = ReaderPrefs(fit: FitMode.height, brightness: 0.1, contrast: -0.2, sharpen: true, autoLevels: true,
        crop: 0.05);
    expect(ReaderPrefs.fromJson(p.toJson()), p);
    expect(ReaderPrefs.fromJson(p.toJson()).crop, 0.05, reason: 'crop edges');
    for (final direction in ReadingDirection.values) {
      expect(ReaderPrefs.fromJson(ReaderPrefs(direction: direction).toJson()).direction, direction,
          reason: 'direction ${direction.name}');
    }
    // the background: a reading setting since 2026-10-05; black (as everything saved before) isn't written
    for (final bg in ReaderBackground.values) {
      expect(ReaderPrefs.fromJson(ReaderPrefs(background: bg).toJson()).background, bg, reason: 'background ${bg.name}');
    }
    expect(const ReaderPrefs().toJson().containsKey('bg'), isFalse);
    expect(ReaderPrefs.fromJson({'fit': 'width'}).background, ReaderBackground.black, reason: 'saved before: black');
    expect(const ReaderPrefs(background: ReaderBackground.white, contrast: 0.2).imageReset().background,
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
    expect(const ReaderPrefs(direction: ReadingDirection.rtl, contrast: 0.2).imageReset().direction, ReadingDirection.rtl);
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
        screenOn: 20, posterSize: PosterSize.small, posterSeries: false, posterTitle: false,
        nightSchedule: true, nightFrom: 1320, nightTo: 360, textScale: 1.15, accent: Accent.green,
        pagePreviews: false, pageStrip: true, posterDate: false);
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
      ('screenOn', (d) => d.screenOn, 20, 0),
      ('posterSize', (d) => d.posterSize, PosterSize.small, PosterSize.medium),
      ('posterSeries', (d) => d.posterSeries, false, true),
      ('posterTitle', (d) => d.posterTitle, false, true),
      ('nightSchedule', (d) => d.nightSchedule, true, false),
      ('nightFrom', (d) => d.nightFrom, 1320, 21 * 60),
      ('nightTo', (d) => d.nightTo, 360, 7 * 60),
      ('textScale', (d) => d.textScale, 1.15, 1.0),
      ('accent', (d) => d.accent, Accent.green, Accent.blue),
      ('pagePreviews', (d) => d.pagePreviews, false, true),
      ('pageStrip', (d) => d.pageStrip, true, false), // the reader's page strip left open (user, 2026-10-02)
      ('posterDate', (d) => d.posterDate, false, true), // release dates on book posters (user, 2026-10-06)
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
