import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/screens/app_settings.dart';
import 'package:komga_reader/settings.dart';
import 'package:komga_reader/widgets/display_panel.dart';
import 'package:komga_reader/widgets/epub_settings.dart';
import 'package:komga_reader/widgets/setting_rows.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/no_network.dart';
import 'support/status_server.dart';

/// The reader's Comic settings and Image panels: side sheets on a wide screen, bottom sheets on a narrow one.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => AppSettings.instance.series.clear());

  Future<void> openPanel(WidgetTester tester, Size size, {bool image = false, FitMode? bookFit}) async {
    setView(tester, size);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => Center(
      child: TextButton(
        onPressed: () => image
            ? showImagePanel(context, seriesId: 'S1', seriesTitle: 'Planet Comics')
            : showReaderPanel(context, seriesId: 'S1', seriesTitle: 'Planet Comics', komgaDirection: 'RIGHT_TO_LEFT',
                bookFit: bookFit),
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
    expect(find.text('Settings for Series: Planet Comics'), findsOneWidget);
    expect(find.text('Override defaults'), findsOneWidget);
    expect(find.text('Auto follows Komga: right to left'), findsOneWidget);
    expect(find.byTooltip('Right to left'), findsOneWidget); // direction as icons
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow: a bottom sheet', (tester) async {
    await openPanel(tester, const Size(400, 860));
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(tester.takeException(), isNull); // nothing overflows at phone width
  });

  testWidgets('Image: off, the controls are greyed out showing the defaults; on, they can be set; off again follows '
      'the defaults', (tester) async {
    final s = AppSettings.instance;
    s.setDefault(const ReaderPrefs(sharpen: true)); // the defaults have Enhance on
    addTearDown(() => s.setDefault(const ReaderPrefs()));
    await openPanel(tester, const Size(1280, 800), image: true);
    expect(find.text('Settings for Series: Planet Comics'), findsOneWidget); // the heading (user, 2026-09-30)
    SwitchListTile row(String t) => tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, t));
    expect(row('Override defaults').value, isFalse);
    expect(row('Enhance').value, isTrue, reason: "shows the defaults' value");
    expect(row('Enhance').onChanged, isNull, reason: 'greyed out');
    expect(find.text('Reset to original'), findsNothing); // only with the override on

    await tester.tap(find.widgetWithText(SwitchListTile, 'Override defaults'));
    await tester.pumpAndSettle();
    expect(s.ownsImage('S1'), isTrue);
    expect(s.ownsLayout('S1'), isFalse, reason: 'the layout part is separate');
    expect(row('Enhance').value, isTrue, reason: 'starts from the defaults: nothing jumps');
    await tester.tap(find.widgetWithText(SwitchListTile, 'Enhance'));
    await tester.pumpAndSettle();
    expect(s.prefsFor('S1').sharpen, isFalse); // the series' own now

    await tester.tap(find.widgetWithText(SwitchListTile, 'Override defaults'));
    await tester.pumpAndSettle();
    expect(s.hasOwn('S1'), isFalse, reason: 'neither part overridden: the series follows the defaults entirely');
    expect(s.prefsFor('S1').sharpen, isTrue);
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
    expect(find.text('Automatic brightness'), findsNothing, reason: 'no switch row of its own');
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
    expect(find.text('eBook settings'), findsNothing, reason: 'the panel closed');
    final screen = tester.widget<AppSettingsScreen>(find.byType(AppSettingsScreen));
    expect(screen.initialPage, SettingsPage.ebooks);
    expect(screen.only, unorderedEquals([SettingsPage.reading, SettingsPage.ebooks]));
    // the side list: those two pages, no other
    for (final p in SettingsPage.values) {
      final listed = find.descendant(of: find.byType(ListView).first, matching: find.text(p.label));
      expect(listed, p == SettingsPage.reading || p == SettingsPage.ebooks ? findsWidgets : findsNothing,
          reason: p.name);
    }
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget, reason: 'back to the book');
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
