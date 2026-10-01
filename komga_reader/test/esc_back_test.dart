import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/offline/connection.dart';
import 'package:komga_reader/screens/app_settings.dart';
import 'package:komga_reader/screens/home.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_shell.dart';
import 'support/helpers.dart';

/// Esc on a full screen goes back one, like the remote's Back (user, 2026-09-30) - through the real app shell. What
/// takes Esc itself (a dialog, the side menu) still does, and only that closes; Home has nowhere to go back to.
void main() {
  testWidgets('Esc: closes a dialog only, then leaves Settings for Home; on Home it does nothing', (tester) async {
    appStorage(tester);
    SharedPreferences.setMockInitialValues({'server': 'http://komga.test:25600', 'apiKey': 'k'});
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
}
