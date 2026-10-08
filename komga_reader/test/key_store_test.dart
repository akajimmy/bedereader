import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:komga_reader/key_store.dart';
import 'package:komga_reader/screens/home.dart';
import 'package:komga_reader/screens/login.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_shell.dart';
import 'support/helpers.dart';

/// The API key is kept encrypted (flutter_secure_storage: the Android Keystore, Windows DPAPI), never in the plain
/// settings file (backlog, done 2026-10-08), through the real app shell (main.dart _restore / _signIn).
void main() {
  const url = 'http://komga.test:25600';

  Future<void> frames(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('signing in keeps the key in the encrypted store, not in the settings file; the next start uses it',
      (tester) async {
    appStorage(tester);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final komga = ShellKomga();
    await komga.pumpApp(tester);
    await waitUntil(() => shows(find.byType(LoginScreen)), tester: tester, reason: 'the sign-in screen');

    await tester.enterText(find.widgetWithText(TextField, 'Server'), url);
    await tester.enterText(find.widgetWithText(TextField, 'API key'), 'secret-key');
    // the sign-in's connection is made as Connect is pressed: it gets the test's Komga
    await http.runWithClient(() => tester.tap(find.widgetWithText(FilledButton, 'Connect')), komga.client);
    await waitUntil(() => shows(find.byType(HomeScreen)), tester: tester, timeout: const Duration(seconds: 5),
        reason: 'signed in');
    await frames(tester);

    expect(await KeyStore.read(), 'secret-key', reason: 'kept encrypted');
    final p = await SharedPreferences.getInstance();
    expect(p.getKeys().where((k) => p.get(k) == 'secret-key'), isEmpty, reason: 'nowhere in the plain settings');
    expect(p.getString('server'), url);

    // the app started again: signed in from the encrypted store
    await tester.pumpWidget(const SizedBox());
    await komga.pumpApp(tester);
    await waitUntil(() => shows(find.byType(HomeScreen)), tester: tester, timeout: const Duration(seconds: 5),
        reason: 'still signed in');
    expect(komga.requests, isNotEmpty);
    await frames(tester);
  });

  testWidgets('a key left in plain text from before is not used, and is removed: the sign-in screen shows',
      (tester) async {
    appStorage(tester);
    SharedPreferences.setMockInitialValues({'server': url, 'apiKey': 'old-plain-key'});
    FlutterSecureStorage.setMockInitialValues({});
    await ShellKomga().pumpApp(tester);
    await waitUntil(() => shows(find.byType(LoginScreen)), tester: tester, reason: 'the sign-in screen');
    await frames(tester);

    final p = await SharedPreferences.getInstance();
    expect(p.containsKey('apiKey'), isFalse, reason: 'the plain-text key is gone from the device');
    expect(find.text(url), findsOneWidget, reason: 'the address is kept, filled in');
  });
}
