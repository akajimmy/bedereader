import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/settings.dart';
import 'package:komga_reader/widgets/display_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The reader's Reader and Image panels: side sheets on a wide screen, bottom sheets on a narrow one.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => AppSettings.instance.series.clear());

  Future<void> openPanel(WidgetTester tester, Size size, {bool image = false}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => Center(
      child: TextButton(
        onPressed: () => image
            ? showImagePanel(context, seriesId: 'S1', seriesTitle: 'Planet Comics')
            : showReaderPanel(context, seriesId: 'S1', seriesTitle: 'Planet Comics', komgaDirection: 'RIGHT_TO_LEFT'),
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
    expect(find.text('This device'), findsOneWidget);
    expect(find.text('Override the defaults'), findsOneWidget);
    expect(find.text('Using the defaults'), findsOneWidget);
    expect(find.text('Auto follows Komga: right to left'), findsOneWidget);
    expect(find.byTooltip('Right to left'), findsOneWidget); // direction as icons
    expect(find.text('Page number after a turn'), findsOneWidget); // mid-book toggles, here too
    expect(find.text('Double-tap to zoom'), findsOneWidget);
    expect(find.text('Keep the screen on'), findsOneWidget);
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
    expect(row('Override the defaults').value, isFalse);
    expect(row('Enhance').value, isTrue, reason: "shows the defaults' value");
    expect(row('Enhance').onChanged, isNull, reason: 'greyed out');
    expect(find.text('Reset to original'), findsNothing); // only with the override on

    await tester.tap(find.widgetWithText(SwitchListTile, 'Override the defaults'));
    await tester.pumpAndSettle();
    expect(s.ownsImage('S1'), isTrue);
    expect(s.ownsLayout('S1'), isFalse, reason: 'the layout part is separate');
    expect(row('Enhance').value, isTrue, reason: 'starts from the defaults: nothing jumps');
    await tester.tap(find.widgetWithText(SwitchListTile, 'Enhance'));
    await tester.pumpAndSettle();
    expect(s.prefsFor('S1').sharpen, isFalse); // the series' own now

    await tester.tap(find.widgetWithText(SwitchListTile, 'Override the defaults'));
    await tester.pumpAndSettle();
    expect(s.hasOwn('S1'), isFalse, reason: 'neither part overridden: the series follows the defaults entirely');
    expect(s.prefsFor('S1').sharpen, isTrue);
    await tester.pump(const Duration(seconds: 5)); // the settings sync timer
  });

  test('series settings saved before the toggles override both parts; the flags survive the saved form', () {
    expect(ReaderPrefs.fromJson({'fit': 'width'}).ownLayout, isTrue);
    expect(ReaderPrefs.fromJson({'fit': 'width'}).ownImage, isTrue);
    final p = ReaderPrefs.fromJson(const ReaderPrefs(ownLayout: false).toJson());
    expect([p.ownLayout, p.ownImage], [false, true]);
    expect(const ReaderPrefs().toJson().containsKey('ol'), isFalse); // unchanged form for everything saved before
  });

  testWidgets('narrow sheet: sliders go full width under their label and value; the remote can move off them',
      (tester) async {
    await openPanel(tester, const Size(1280, 800), image: true); // side sheet, 380 wide
    final slider = tester.getRect(find.byType(Slider).at(1)); // Brightness
    expect(slider.width, greaterThan(300)); // not squeezed beside the label any more
    final mq = tester.widget<MediaQuery>(find.ancestor(of: find.byType(Slider).at(1), matching: find.byType(MediaQuery)).first);
    expect(mq.data.navigationMode, NavigationMode.directional); // Up/Down leave the slider
  });

  testWidgets('narrow sheet: Keep the screen on fits inside the sheet (all six choices visible)', (tester) async {
    await openPanel(tester, const Size(1280, 800)); // Reader panel, side sheet
    await tester.scrollUntilVisible(find.text('Keep the screen on'), 200, scrollable: find.byType(Scrollable).last);
    final sheet = tester.getRect(find.byType(ListView).last);
    final choices = tester.getRect(find.byType(SegmentedButton<int>));
    expect(choices.right, lessThanOrEqualTo(sheet.right + 0.5)); // not cut off at the right edge
    expect(find.text('Always'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
