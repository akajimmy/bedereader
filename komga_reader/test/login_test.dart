import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/screens/login.dart';
import 'package:komga_reader/widgets/error_text.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/no_network.dart';

/// Sign-in: no server address filled in for a new user (just an example hint); the last address when signing in
/// again after Sign out.
void main() {
  TextField field(WidgetTester tester, String label) => tester.widget<TextField>(
      find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == label));

  testWidgets('first sign-in: the server field is empty, with an example hint', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(home: LoginScreen(onSignedIn: (_) async {})));
    await tester.pump();
    expect(field(tester, 'Server').controller!.text, isEmpty);
    expect(field(tester, 'Server').decoration!.hintText, 'http://192.168.1.10:25600');
  });

  testWidgets('signing in again: the last server address is filled in', (tester) async {
    SharedPreferences.setMockInitialValues({'server': 'http://nas.local:25600'});
    await tester.pumpWidget(MaterialApp(home: LoginScreen(onSignedIn: (_) async {})));
    await tester.pump();
    expect(field(tester, 'Server').controller!.text, 'http://nas.local:25600');
    expect(field(tester, 'API key').controller!.text, isEmpty); // never kept
  });

  test('the server address is tidied up: spaces out, http:// added, trailing slashes off', () {
    String? s(String typed) => serverAddress(typed);
    expect(s('192.168.1.10: 25600'), 'http://192.168.1.10:25600'); // as typed on the tablet (user's screenshot)
    expect(s(' http://nas.local:25600/ '), 'http://nas.local:25600');
    expect(s('https://komga.example.org'), 'https://komga.example.org');
    expect(s('HTTP://192.168.1.10:25600'), 'HTTP://192.168.1.10:25600');
    expect(s(''), isNull);
    expect(s('ftp://192.168.1.10'), isNull);
    expect(s('http://'), isNull);
  });

  testWidgets("not an address: a plain message with Details, not the raw FormatException", (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(home: LoginScreen(onSignedIn: (_) async {})));
    await tester.pump();
    await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == 'Server'),
        'ftp://nas');
    await tester.tap(find.text('Connect'));
    await tester.pump();
    expect(find.text("That isn't a server address. It should look like 192.168.1.10:25600."), findsOneWidget);
    expect(find.text('Details'), findsOneWidget);
    expect(find.textContaining('FormatException'), findsNothing);
  });

  testWidgets('an address typed without http:// is tidied: Komga is asked at the address used, the field shows it, '
      'and the sign-in goes on with that client', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final built = <_SignInKomga>[];
    Komga? signedIn;
    await tester.pumpWidget(MaterialApp(home: LoginScreen(
      onSignedIn: (api) async => signedIn = api,
      client: (server, key) {
        final api = noNetwork(() => _SignInKomga(server, key));
        built.add(api);
        return api;
      },
    )));
    await tester.pump();
    await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == 'Server'),
        '192.168.1.10: 25600');
    await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == 'API key'),
        ' key1 ');
    await tester.tap(find.text('Connect'));
    await tester.pump();
    expect(field(tester, 'Server').controller!.text, 'http://192.168.1.10:25600');
    expect(built, hasLength(1));
    expect(built.single.baseUrl, 'http://192.168.1.10:25600');
    expect(built.single.apiKey, 'key1', reason: 'the key trimmed');
    expect(built.single.meCalls, 1, reason: 'Komga asked who this key is');
    expect(signedIn, same(built.single));
    expect(find.byType(ErrorText), findsNothing);
  });

  testWidgets('Enter pressed again while connecting: Komga is asked once (code review 2026-10-05, #20)',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final built = <_SlowKomga>[];
    await tester.pumpWidget(MaterialApp(home: LoginScreen(
      onSignedIn: (_) async {},
      client: (server, key) {
        final api = noNetwork(() => _SlowKomga(server, key));
        built.add(api);
        return api;
      },
    )));
    await tester.pump();
    await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == 'Server'),
        'http://nas:25600');
    final key = find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == 'API key');
    await tester.enterText(key, 'key1');
    await tester.showKeyboard(key);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done); // again, while the first is still connecting
    await tester.pump();
    expect(built, hasLength(1), reason: 'one client, one question to Komga');
    expect(built.single.meCalls, 1);
    built.single.answer.complete({'id': 'U1'});
    await tester.pump();
  });

}

/// Komga at the address typed, answering /users/me (no network: anything else fails the test).
class _SignInKomga extends Komga {
  _SignInKomga(super.baseUrl, super.apiKey);
  int meCalls = 0;
  @override
  Future<Map<String, dynamic>?> me() async {
    meCalls++;
    return {'id': 'U1'};
  }
}

/// Komga that answers /users/me only when the test says.
class _SlowKomga extends Komga {
  _SlowKomga(super.baseUrl, super.apiKey);
  int meCalls = 0;
  final answer = Completer<Map<String, dynamic>?>();
  @override
  Future<Map<String, dynamic>?> me() {
    meCalls++;
    return answer.future;
  }
}

