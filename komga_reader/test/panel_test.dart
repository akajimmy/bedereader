import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/screen.dart' show hasBacklightControl;
import 'package:komga_reader/screens/app_settings.dart';
import 'package:komga_reader/settings.dart';
import 'package:komga_reader/widgets/display_panel.dart';
import 'package:komga_reader/widgets/epub_settings.dart';
import 'package:komga_reader/widgets/setting_rows.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/no_network.dart';
import 'support/status_server.dart';

/// The reader's Comic settings panel: a side sheet on a wide screen, a bottom sheet on a narrow one.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => AppSettings.instance.series.clear());

  Future<void> openPanel(WidgetTester tester, Size size, {FitMode? bookFit}) async {
    setView(tester, size);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => Center(
      child: TextButton(
        onPressed: () => showReaderPanel(context, seriesId: 'S1', seriesTitle: 'Planet Comics',
            komgaDirection: 'RIGHT_TO_LEFT', bookFit: bookFit),
        child: const Text('open'),
      ),
    )))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('wide: a side sheet on the right, the page left in view', (tester) async {
    await openPanel(tester, const Size(1280, 800));
    final done = tester.getRect(find.text('Done'));
    expect(done.left, greaterThan(1280 - 400)); // at the right edge
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow: a bottom sheet', (tester) async {
    await openPanel(tester, const Size(400, 860));
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(tester.takeException(), isNull); // nothing overflows at phone width
  });

  testWidgets('Enhance and Enhance colours in the series group, under its one Override (user, 2026-10-23: "back to '
      'the per series override section"): off, greyed out showing the defaults; on, the layout and the image both the '
      "series' own, starting from the defaults; Make default takes them; off again follows the defaults", (tester) async {
    final s = AppSettings.instance;
    s.setDefault(const ReaderPrefs(sharpen: true)); // the defaults have Enhance on
    addTearDown(() => s.setDefault(const ReaderPrefs()));
    await openPanel(tester, const Size(1280, 1400));
    SwitchListTile row(String t) => tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, t));
    expect(row('Override defaults').value, isFalse);
    expect(row('Enhance').value, isTrue, reason: "shows the defaults' value");
    expect(row('Enhance').onChanged, isNull, reason: 'greyed out');
    expect(row('Enhance colours').onChanged, isNull, reason: 'greyed out');

    await tester.tap(find.widgetWithText(SwitchListTile, 'Override defaults'));
    await tester.pumpAndSettle();
    expect((s.ownsLayout('S1'), s.ownsImage('S1')), (true, true), reason: 'one override: both parts');
    expect(row('Enhance').value, isTrue, reason: 'starts from the defaults: nothing jumps');
    await tester.tap(find.widgetWithText(SwitchListTile, 'Enhance'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SwitchListTile, 'Enhance colours'));
    await tester.pumpAndSettle();
    expect((s.prefsFor('S1').sharpen, s.prefsFor('S1').autoLevels), (false, true), reason: "the series' own now");
    expect(s.defaults.sharpen, isTrue, reason: 'the defaults untouched');

    await tester.ensureVisible(find.text('Make default'));
    await tester.tap(find.text('Make default'));
    await tester.pumpAndSettle();
    expect((s.defaults.sharpen, s.defaults.autoLevels), (false, true), reason: 'Make default takes the image settings too');

    await tester.ensureVisible(find.widgetWithText(SwitchListTile, 'Override defaults'));
    await tester.tap(find.widgetWithText(SwitchListTile, 'Override defaults'));
    await tester.pumpAndSettle();
    expect(s.hasOwn('S1'), isFalse, reason: 'off: the series follows the defaults entirely');
    await tester.pump(const Duration(seconds: 5)); // the settings sync timer
  });

  testWidgets("a series that overrides only its layout (saved before the one switch): Override shows on, Enhance follows "
      "the defaults until it's changed - then it's the series' own", (tester) async {
    final s = AppSettings.instance;
    s.setDefault(const ReaderPrefs(sharpen: true));
    addTearDown(() => s.setDefault(const ReaderPrefs()));
    s.setOverride('S1', layout: true);
    expect(s.ownsImage('S1'), isFalse);
    await openPanel(tester, const Size(1280, 1400));
    SwitchListTile row(String t) => tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, t));
    expect(row('Override defaults').value, isTrue);
    expect(row('Enhance').value, isTrue, reason: "the defaults' - nothing changed for it");
    expect(row('Enhance').onChanged, isNotNull, reason: 'can be set');
    await tester.tap(find.widgetWithText(SwitchListTile, 'Enhance'));
    await tester.pumpAndSettle();
    expect(s.ownsImage('S1'), isTrue);
    expect(s.prefsFor('S1').sharpen, isFalse);
    await tester.pump(const Duration(seconds: 5)); // the settings sync timer
  });

  testWidgets("Comic settings: the background follows the defaults until Override is on; then it's this series' own "
      '(user, 2026-10-05)', (tester) async {
    final s = AppSettings.instance;
    addTearDown(() => s.series.remove('S1'));
    s.series.remove('S1');
    await openPanel(tester, const Size(1280, 1000));
    final grey = find.bySemanticsLabel('Dark grey background');
    await tester.ensureVisible(grey);
    await tester.tap(grey, warnIfMissed: false); // greyed out: following the defaults
    await tester.pumpAndSettle();
    expect(s.ownsLayout('S1'), isFalse);
    expect(s.prefsFor('S1').background, s.defaults.background, reason: 'still the defaults');
    final override = find.widgetWithText(SwitchRow, 'Override defaults').first;
    await tester.ensureVisible(override);
    await tester.pumpAndSettle();
    await tester.tap(override);
    await tester.pumpAndSettle();
    expect(s.ownsLayout('S1'), isTrue, reason: 'Override on');
    await tester.ensureVisible(grey);
    await tester.pumpAndSettle();
    await tester.tap(grey);
    await tester.pumpAndSettle();
    expect(s.prefsFor('S1').background, ReaderBackground.grey, reason: "the series' own");
    expect(s.defaults.background, isNot(ReaderBackground.grey), reason: 'the defaults untouched');
    await tester.pump(const Duration(seconds: 3)); // the settings sync timer
  });

  testWidgets('Comic settings: turning Override on with a fit picked for this book keeps that fit (nothing jumps)',
      (tester) async {
    final s = AppSettings.instance;
    await openPanel(tester, const Size(1280, 800), bookFit: FitMode.width); // the top bar: fit width, this book only
    await tester.tap(find.widgetWithText(SwitchListTile, 'Override defaults'));
    await tester.pumpAndSettle();
    expect(s.ownsLayout('S1'), isTrue);
    expect(s.prefsFor('S1').fit, FitMode.width, reason: 'the series starts from what was on screen');
    await tester.pump(const Duration(seconds: 5)); // the settings sync timer
  });

  testWidgets('side sheet 460 wide (user, 2026-10-21: at 380 most rows broke onto two lines): a slider sits beside its '
      'label, on one line, in directional navigation (the remote walk in settings_remote_test covers Up / Down off '
      'them)', (tester) async {
    await openPanel(tester, const Size(1280, 800));
    expect(tester.getSize(find.ancestor(of: find.text('Comic settings'), matching: find.byType(SizedBox)).first).width,
        460);
    final slider = tester.getRect(find.byType(Slider).first); // screen brightness
    final label = tester.getRect(find.text('Brightness'));
    expect(slider.top, lessThan(label.bottom), reason: 'beside its label, not under it');
    expect(slider.width, greaterThan(100)); // (in the test font, about twice as wide as a real one)
    final mq = tester.widget<MediaQuery>(find.ancestor(of: find.byType(Slider).first, matching: find.byType(MediaQuery)).first);
    expect(mq.data.navigationMode, NavigationMode.directional); // Up/Down leave the slider
  });

  testWidgets('screen brightness on one line (user, 2026-10-21: "keep the two, reconsider the layout for compactness"): '
      'Brightness, Auto, the slider - greyed while Auto is on - and its value; Auto off starts from a level, Auto on '
      'gives it back to the system', (tester) async {
    final was = DisplayPrefs.backlightControl;
    addTearDown(() {
      DisplayPrefs.backlightControl = was;
      AppSettings.instance.setDisplay(const DisplayPrefs());
    });
    DisplayPrefs.backlightControl = true; // (a tablet: the backlight and Auto)
    // the screen's level now, as the platform side reports it (lib/screen.dart: getBrightness)
    const channel = MethodChannel('komga_reader/screen');
    final messenger = tester.binding.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'getBrightness' ? 0.5 : null);
    AppSettings.instance.setDisplay(const DisplayPrefs()); // Auto
    await openPanel(tester, const Size(1280, 800));
    final auto = find.widgetWithText(SegmentedButton<bool>, 'Auto');
    expect(auto, findsOneWidget);
    await tester.ensureVisible(auto); // (below the series group's rows)
    await tester.pumpAndSettle();
    final slider = find.ancestor(of: find.byType(Slider), matching: find.byType(BrightnessPreview));
    final s = tester.widget<Slider>(find.descendant(of: slider, matching: find.byType(Slider)));
    expect(s.onChanged, isNull, reason: 'Auto: the slider greyed');
    final line = tester.getRect(find.text('Brightness')).center.dy;
    expect(tester.getRect(auto).center.dy, closeTo(line, 4), reason: 'one line');
    expect(tester.getRect(slider).center.dy, closeTo(line, 4));
    expect(tester.getRect(auto).left, lessThan(tester.getRect(slider).left), reason: 'Auto before the slider');

    await tester.tap(auto);
    await tester.pumpAndSettle();
    expect(AppSettings.instance.display.brightness, isNotNull, reason: 'Auto off: a level of its own');
    expect(tester.widget<Slider>(find.descendant(of: slider, matching: find.byType(Slider))).onChanged, isNotNull);
    await tester.tap(auto);
    await tester.pumpAndSettle();
    expect(AppSettings.instance.display.brightness, isNull, reason: 'Auto on: the system again');
  });

  testWidgets('a PC (no backlight to set): the same brightness row as Android (user, 2026-10-22) - Auto is no '
      'dimming; off, it starts from full, so nothing changes until the slider moves; the slider dims, with no '
      '"Extra dim" step', (tester) async {
    DisplayPrefs.backlightControl = false;
    addTearDown(() => DisplayPrefs.backlightControl = hasBacklightControl);
    AppSettings.instance.setDisplay(const DisplayPrefs()); // Auto
    await openPanel(tester, const Size(1280, 800));
    final auto = find.widgetWithText(SegmentedButton<bool>, 'Auto');
    expect(auto, findsOneWidget);
    await tester.ensureVisible(auto); // (below the series group's rows)
    await tester.pumpAndSettle();
    expect(AppSettings.instance.display.dimOverlay, 0, reason: 'Auto: no dimming');
    await tester.tap(auto);
    await tester.pumpAndSettle();
    expect(AppSettings.instance.display.brightness, 1.0, reason: 'from full');
    expect(AppSettings.instance.display.dimOverlay, 0, reason: 'nothing changed yet');
    AppSettings.instance.setDisplay(AppSettings.instance.display.copyWith(brightness: () => 0.1));
    await tester.pump();
    expect(AppSettings.instance.display.dimOverlay, greaterThan(0.5), reason: 'dimmed');
    expect(find.text('10%'), findsOneWidget, reason: 'a level, not "Extra dim"');
  });

  testWidgets('side sheet: every choice fits inside the sheet (none cut off at the right edge)', (tester) async {
    await openPanel(tester, const Size(1280, 800)); // Comic settings, side sheet
    final sheet = tester.getRect(find.byType(ListView).last);
    final choices = find.byWidgetPredicate((w) => w is SegmentedButton);
    expect(choices, findsWidgets);
    for (final c in choices.evaluate()) {
      expect(tester.getRect(find.byWidget(c.widget)).right, lessThanOrEqualTo(sheet.right + 0.5));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('More settings (user, 2026-10-21: the panels trimmed): the panel closes, and Settings opens on the '
      "book's kind with only it and Reading - nothing there leaves the book", (tester) async {
    setView(tester, const Size(1280, 800));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => Center(
      child: TextButton(
        onPressed: () => showReaderPanelFrame(context, title: 'eBook settings',
            children: (c, s) => epubPanelRows(c, s, api: noNetwork(StatusServer.new))),
        child: const Text('open'),
      ),
    )))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('More settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('More settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsGroup, skipOffstage: false).evaluate().where((e) => e.findAncestorWidgetOfExactType<AppSettingsScreen>() == null), isEmpty, reason: 'the panel closed');
    final screen = tester.widget<AppSettingsScreen>(find.byType(AppSettingsScreen));
    expect(screen.initialPage, SettingsPage.ebooks);
    expect(screen.only, unorderedEquals([SettingsPage.reading, SettingsPage.ebooks]));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget, reason: 'back to the book');
    expect(find.byType(SettingsGroup), findsNothing, reason: 'not to the panel: it closed');
  });

  testWidgets("eBooks' two-page rows (user, 2026-10-21): Chapters start on only with two pages up; the Gutter only "
      'with two pages up and an inset page', (tester) async {
    Future<(bool, bool)> shown(TwoPages two, InsetPage inset) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (c) => SingleChildScrollView(child: Column(
          children: epubSettingRows(c, EpubPrefs(twoPages: two), (_) {}, inset: inset)))))));
      int count<T>() => tester.widgetList(find.byType(SegmentedButton<T>)).length;
      return (count<ChapterStart>() == 1, count<double>() == 2); // (the other double: line spacing)
    }

    expect(await shown(TwoPages.off, InsetPage.wideScreen), (false, false), reason: 'one page');
    expect(await shown(TwoPages.wideScreen, InsetPage.wideScreen), (true, true));
    expect(await shown(TwoPages.always, InsetPage.always), (true, true));
    expect(await shown(TwoPages.always, InsetPage.never), (true, false), reason: 'no sheets, no gutter between them');
  });
}
