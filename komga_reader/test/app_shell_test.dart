// app shell (test audit, 2026-10-23: esc_back_test.dart folded in).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/main.dart';
import 'package:komga_reader/offline/connection.dart';
import 'package:komga_reader/screens/app_settings.dart';
import 'package:komga_reader/screens/home.dart';
import 'package:komga_reader/screens/login.dart';
import 'package:komga_reader/settings.dart';
import 'package:komga_reader/widgets/poster.dart' show HoldOkGuard;
import 'package:komga_reader/widgets/refresh_on_return.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_shell.dart';
import 'support/helpers.dart';

// The real app shell (main.dart's KomgaReaderApp), which no other test pumped (test audit, 2026-09-30): what it
// puts around every screen - the return observer, the held-OK guard, this app's text size on top of the device's,
// and the theme in the chosen accent colour. No server saved, so it opens on the sign-in screen.

// ---- from esc_back_test.dart
// Esc on a full screen goes back one, like the remote's Back (user, 2026-09-30) - through the real app shell. What
// takes Esc itself (a dialog, the side menu) still does, and only that closes; Home has nowhere to go back to.

void main() {
  final s = AppSettings.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({}); // no server: the sign-in screen
    FlutterSecureStorage.setMockInitialValues({});
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

  testWidgets("Settings > Look text size: this app's size, on top of the device's own", (tester) async {
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

  testWidgets('Settings > Look accent colour: the theme follows it', (tester) async {
    final ctx = await app(tester);
    expect(Theme.of(ctx).colorScheme.primary, Accent.blue.colour); // the default
    s.setDisplay(s.display.copyWith(accent: Accent.green));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500)); // MaterialApp animates a change of theme
    expect(Theme.of(tester.element(find.byType(LoginScreen))).colorScheme.primary, Accent.green.colour);
  });

  group('esc back', () {
    testWidgets('Esc: closes a dialog only, then leaves Settings for Home; on Home it does nothing', (tester) async {
      appStorage(tester);
      SharedPreferences.setMockInitialValues({'server': 'http://komga.test:25600'});
      FlutterSecureStorage.setMockInitialValues({'apiKey': 'k'});
      await ShellKomga().pumpApp(tester);
      await waitUntil(() => shows(find.byType(HomeScreen)) && Connection.instance.online != null, tester: tester,
          timeout: const Duration(seconds: 5), reason: 'Home');
      Future<void> frames() async {
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 50)); // slide-outs and page transitions (no settle: spinners)
        }
      }

      Future<void> esc() async {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await frames();
        await tester.pump(const Duration(seconds: 1)); // a page's way out takes longer than a dialog's
      }

      await tester.tap(find.byTooltip('Open navigation menu'));
      await frames();
      await tester.tap(find.text('Settings'));
      await frames();
      expect(find.byType(AppSettingsScreen), findsOneWidget);
      await tester.tap(find.text('Server and sync')); // (Settings opens on Reading)
      await frames();

      await tester.ensureVisible(find.text('Sign out / change server'));
      await tester.tap(find.text('Sign out / change server'));
      await frames();
      expect(find.byType(AlertDialog), findsOneWidget);
      await esc();
      expect(find.byType(AlertDialog), findsNothing, reason: 'Esc closes the dialog');
      expect(find.byType(AppSettingsScreen), findsOneWidget, reason: '... and only the dialog');

      await esc();
      expect(find.byType(AppSettingsScreen), findsNothing, reason: 'Esc on Settings goes back');
      expect(find.byType(HomeScreen), findsOneWidget);

      await esc();
      expect(find.byType(HomeScreen), findsOneWidget, reason: 'nowhere to go back to from Home');
      expect(tester.takeException(), isNull);
    });
  });
}
