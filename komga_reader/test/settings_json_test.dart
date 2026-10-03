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
    const p = ReaderPrefs(fit: FitMode.height, brightness: 0.1, contrast: -0.2, sharpen: true, autoLevels: true);
    expect(ReaderPrefs.fromJson(p.toJson()), p);
    for (final direction in ReadingDirection.values) {
      expect(ReaderPrefs.fromJson(ReaderPrefs(direction: direction).toJson()).direction, direction,
          reason: 'direction ${direction.name}');
    }
    final flags = ReaderPrefs.fromJson(const ReaderPrefs(ownLayout: false).toJson());
    expect([flags.ownLayout, flags.ownImage], [false, true], reason: 'the override flags');
    expect(const ReaderPrefs().toJson().containsKey('ol'), isFalse); // unchanged form for everything saved before

    // older saves: (what was saved, what it reads as)
    for (final (saved, read, expected, why) in <(Map<String, dynamic>, Object? Function(ReaderPrefs), Object?, String)>[
      ({'s': 0.4}, (p) => p.sharpen, true, 'build-4 sharpen slider: on'),
      ({'s': 0}, (p) => p.sharpen, false, 'build-4 sharpen slider at 0: off'),
      ({'fit': 'width'}, (p) => p.direction, ReadingDirection.auto, 'from before the direction: Auto'),
      ({'fit': 'width'}, (p) => p.ownLayout, true, 'from before the toggles: overrides the layout'),
      ({'fit': 'width'}, (p) => p.ownImage, true, 'from before the toggles: overrides the image'),
    ]) {
      expect(read(ReaderPrefs.fromJson(saved)), expected, reason: '$why ($saved)');
    }

    // resetting the image settings keeps the direction (part of the layout)
    expect(const ReaderPrefs(direction: ReadingDirection.rtl, contrast: 0.2).imageReset().direction, ReadingDirection.rtl);
  });

  test("this device's settings (DisplayPrefs) survive the saved form; older saves get the defaults; a value that isn't "
      'a choice gets the default', () {
    // every setting away from its default at once: (name, read it, the value set, its default)
    const changed = DisplayPrefs(pageTurn: PageTurn.curl, rotation: Rotation.landscape, clock: ShowWhen.always,
        progressBar: true, doubleTapZoom: false, volumeKeys: false, midBook: MidBook.keep,
        background: ReaderBackground.grey, screenOn: 20, posterSize: PosterSize.small, posterTitleOnly: true,
        nightSchedule: true, nightFrom: 1320, nightTo: 360, textScale: 1.15, accent: Accent.teal,
        pagePreviews: false, pageStrip: true);
    final settings = <(String, Object? Function(DisplayPrefs), Object?, Object?)>[
      ('pageTurn', (d) => d.pageTurn, PageTurn.curl, PageTurn.swipe),
      ('rotation', (d) => d.rotation, Rotation.landscape, Rotation.auto),
      ('clock', (d) => d.clock, ShowWhen.always, ShowWhen.withControls),
      ('progressBar', (d) => d.progressBar, true, false),
      ('doubleTapZoom', (d) => d.doubleTapZoom, false, true),
      ('volumeKeys', (d) => d.volumeKeys, false, true),
      ('midBook', (d) => d.midBook, MidBook.keep, MidBook.ask),
      ('background', (d) => d.background, ReaderBackground.grey, ReaderBackground.black),
      ('screenOn', (d) => d.screenOn, 20, 0),
      ('posterSize', (d) => d.posterSize, PosterSize.small, PosterSize.medium),
      ('posterTitleOnly', (d) => d.posterTitleOnly, true, false),
      ('nightSchedule', (d) => d.nightSchedule, true, false),
      ('nightFrom', (d) => d.nightFrom, 1320, 21 * 60),
      ('nightTo', (d) => d.nightTo, 360, 7 * 60),
      ('textScale', (d) => d.textScale, 1.15, 1.0),
      ('accent', (d) => d.accent, Accent.teal, Accent.blue),
      ('pagePreviews', (d) => d.pagePreviews, false, true),
      ('pageStrip', (d) => d.pageStrip, true, false), // the reader's page strip left open (user, 2026-10-02)
    ];
    final back = DisplayPrefs.fromJson(changed.toJson());
    final old = DisplayPrefs.fromJson({'night': true}); // a save from before all of these
    final oldWithTurn = DisplayPrefs.fromJson({'night': true, 'pageTurn': 'flip'}); // ... with the page turn
    for (final (name, read, set, byDefault) in settings) {
      expect(read(changed), set, reason: '$name: the table matches the settings above');
      expect(read(back), set, reason: '$name survives the saved form');
      expect(read(old), byDefault, reason: '$name: an older save gets the default');
      expect(read(oldWithTurn), name == 'pageTurn' ? PageTurn.flip : byDefault, reason: '$name, older save with a turn');
    }
    for (final turn in PageTurn.values) {
      expect(DisplayPrefs.fromJson(DisplayPrefs(pageTurn: turn).toJson()).pageTurn, turn, reason: turn.name);
    }

    // not a choice: the default
    expect(DisplayPrefs.fromJson({'screenOn': 7}).screenOn, 0);
    expect(DisplayPrefs.fromJson({'textScale': 3.0}).textScale, 1.0);
  });
}
