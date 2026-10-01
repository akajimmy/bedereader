import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/main.dart';
import 'package:komga_reader/screens/login.dart';
import 'package:komga_reader/settings.dart';
import 'package:komga_reader/widgets/poster.dart' show HoldOkGuard;
import 'package:komga_reader/widgets/refresh_on_return.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The real app shell (main.dart's KomgaReaderApp), which no other test pumped (test audit, 2026-09-30): what it
/// puts around every screen - the return observer, the held-OK guard, this app's text size on top of the device's,
/// and the theme in the chosen accent colour. No server saved, so it opens on the sign-in screen.
void main() {
  final s = AppSettings.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({}); // no server: the sign-in screen
    s.setDisplay(const DisplayPrefs());
  });
  tearDown(() => s.setDisplay(const DisplayPrefs()));

  Future<BuildContext> app(WidgetTester tester) async {
    await tester.pumpWidget(const KomgaReaderApp());
    await tester.pump(); // the saved sign-in is read
    await tester.pump();
    expect(find.byType(LoginScreen), findsOneWidget);
    return tester.element(find.byType(LoginScreen));
  }

  testWidgets('library views refresh on return: the app reports navigation to ReturnObserver', (tester) async {
    await app(tester);
    final m = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(m.navigatorObservers, contains(ReturnObserver.instance));
  });

  testWidgets("a held OK's repeats don't press in its menu: HoldOkGuard is over every screen", (tester) async {
    await app(tester);
    expect(find.ancestor(of: find.byType(LoginScreen), matching: find.byType(HoldOkGuard)), findsOneWidget);
  });

  testWidgets("Settings > Display text size: this app's size, on top of the device's own", (tester) async {
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final ctx = await app(tester);
    expect(MediaQuery.textScalerOf(ctx).scale(10), closeTo(10, 0.001)); // 100%: as the device has it
    s.setDisplay(s.display.copyWith(textScale: 1.3));
    await tester.pump();
    expect(MediaQuery.textScalerOf(tester.element(find.byType(LoginScreen))).scale(10), closeTo(13, 0.001));
    tester.platformDispatcher.textScaleFactorTestValue = 1.2; // the device's own text size, larger
    await tester.pump();
    expect(MediaQuery.textScalerOf(tester.element(find.byType(LoginScreen))).scale(10), closeTo(15.6, 0.001));
  });

  testWidgets('Settings > Display accent colour: the theme follows it', (tester) async {
    final ctx = await app(tester);
    expect(Theme.of(ctx).colorScheme.primary, Accent.blue.colour); // the default
    s.setDisplay(s.display.copyWith(accent: Accent.teal));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500)); // MaterialApp animates a change of theme
    expect(Theme.of(tester.element(find.byType(LoginScreen))).colorScheme.primary, Accent.teal.colour);
  });
}
