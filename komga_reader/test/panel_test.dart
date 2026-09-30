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
    expect(find.text('Planet Comics'), findsOneWidget);
    expect(find.text('Follows the defaults'), findsOneWidget);
    expect(find.text('Auto follows Komga: right to left'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow: a bottom sheet', (tester) async {
    await openPanel(tester, const Size(400, 860));
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(tester.takeException(), isNull); // nothing overflows at phone width
  });

  testWidgets('a change gives the series its own settings; ⋮ Use the defaults goes back to them', (tester) async {
    await openPanel(tester, const Size(1280, 800), image: true);
    await tester.tap(find.widgetWithText(SwitchListTile, 'Enhance'));
    await tester.pumpAndSettle();
    expect(AppSettings.instance.prefsFor('S1').sharpen, isTrue);
    expect(find.text('Own settings'), findsOneWidget);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use the defaults'));
    await tester.pumpAndSettle();
    expect(AppSettings.instance.hasOwn('S1'), isFalse);
    expect(find.text('Follows the defaults'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5)); // the snackbar and the settings sync timer
  });
}
