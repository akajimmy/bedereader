import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
  });

  testWidgets('signing in again: the last server address is filled in', (tester) async {
    SharedPreferences.setMockInitialValues({'server': 'http://nas.local:25600'});
    await tester.pumpWidget(MaterialApp(home: LoginScreen(onSignedIn: (_) async {})));
    await tester.pump();
    expect(field(tester, 'Server').controller!.text, 'http://nas.local:25600');
    expect(field(tester, 'Password').controller!.text, isEmpty); // never kept
    await tester.tap(find.text('API key'));
    await tester.pump();
    expect(field(tester, 'API key').controller!.text, isEmpty); // never kept
  });

  testWidgets('signing in again: the email last signed in with is filled in too', (tester) async {
    SharedPreferences.setMockInitialValues({'server': 'http://nas.local:25600', 'email': 'nick@example.com'});
    await tester.pumpWidget(MaterialApp(home: LoginScreen(onSignedIn: (_) async {})));
    await tester.pump();
    expect(field(tester, 'Email').controller!.text, 'nick@example.com');
  });

  test('the API key in the clear (user, 2026-10-21: a note at sign-in): plain http to a host outside the home '
      'network; not https, not a home address or name, not Tailscale (its tunnel is encrypted)', () {
    for (final outside in ['http://komga.example.com:25600', 'komga.example.com', 'http://8.8.8.8:25600',
        'http://172.32.0.1', 'http://[2001:db8::1]:25600']) {
      expect(sendsKeyInTheClear(outside), isTrue, reason: outside);
    }
    for (final fine in ['https://komga.example.com', '10.0.0.226:25600', 'http://192.168.1.10:25600',
        'http://172.16.4.2', 'http://127.0.0.1:25600', 'localhost:25600', 'http://nick-nas:25600', 'nas.local',
        'http://nas.lan', 'http://box.home.arpa', 'http://100.101.102.103', 'http://nas.tail1234.ts.net',
        'http://[fd12::1]', 'http://[::1]:25600', 'http://169.254.1.2', 'not an address !!', '']) {
      expect(sendsKeyInTheClear(fine), isFalse, reason: fine);
    }
  });

  testWidgets('the note shows under the server field as an outside http address is typed, and goes for a home one',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: LoginScreen(onSignedIn: (_) async {})));
    await tester.pump();
    final note = find.byIcon(Icons.lock_open);
    expect(note, findsNothing);
    await tester.enterText(find.widgetWithText(TextField, 'Server'), 'http://komga.example.com:25600');
    await tester.pump();
    expect(note, findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Server'), 'http://192.168.1.10:25600');
    await tester.pump();
    expect(note, findsNothing);
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
    await tester.tap(find.text('API key'));
    await tester.pump();
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
    await tester.tap(find.text('API key'));
    await tester.pump();
    final key = find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == 'API key');
    await tester.enterText(key, 'key1');
    await tester.showKeyboard(key);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.showKeyboard(key); // (the first Enter put the keyboard away)
    await tester.testTextInput.receiveAction(TextInputAction.done); // again, while the first is still connecting
    await tester.pump();
    expect(built, hasLength(1), reason: 'one client, one question to Komga');
    expect(built.single.meCalls, 1);
    built.single.answer.complete({'id': 'U1'});
    await tester.pump();
  });

  // ---- password sign-in (user, 2026-10-24: "Password | API key" tabs, Password first; the password makes an API
  // key for this device and only the key is kept - the password kept only when the server won't make one)

  /// Signs in on the Password tab with [makeKey] as the server's answer to "an API key, please".
  Future<(List<_PasswordKomga>, Komga?)> signIn(WidgetTester tester, Future<String> Function() makeKey,
      {Map<String, dynamic>? me = const {'id': 'U1'}}) async {
    SharedPreferences.setMockInitialValues({});
    final built = <_PasswordKomga>[];
    Komga? signedIn;
    await tester.pumpWidget(MaterialApp(home: LoginScreen(
      onSignedIn: (api) async => signedIn = api,
      client: (server, credential) {
        final api = noNetwork(() => _PasswordKomga(server, credential, makeKey, me));
        built.add(api);
        return api;
      },
    )));
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'Server'), 'http://nas:25600');
    await tester.enterText(find.widgetWithText(TextField, 'Email'), ' nick@example.com ');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'p4ss word');
    await tester.tap(find.text('Connect'));
    await tester.pump();
    await tester.pump();
    return (built, signedIn);
  }

  testWidgets('a password sign-in makes an API key for this device and keeps only the key; the email is kept for '
      'next time', (tester) async {
    final (built, signedIn) = await signIn(tester, () async => 'made-key');
    expect(built, hasLength(2));
    final byPassword = built.first;
    expect(byPassword.apiKey, Komga.basic('nick@example.com', 'p4ss word'), reason: 'the email trimmed, not the password');
    expect(byPassword.usesPassword, isTrue);
    expect(byPassword.meCalls, 1, reason: 'Komga asked who this is');
    expect(byPassword.keyNames.single, startsWith('BeDeReader on '));
    expect(byPassword.closed, isTrue, reason: 'the password client is dropped');
    expect(signedIn, same(built.last));
    expect((signedIn!.apiKey, signedIn.usesPassword), ('made-key', false));
    expect((await SharedPreferences.getInstance()).getString('email'), 'nick@example.com');
  });

  testWidgets("a server that won't make a key (a restricted or demo account): the password is what's kept",
      (tester) async {
    final (built, signedIn) = await signIn(tester, () async => throw KomgaError(403, '/api/v2/users/me/api-keys'));
    expect(built, hasLength(1));
    expect(signedIn, same(built.single));
    expect(signedIn!.usesPassword, isTrue);
    expect(built.single.closed, isFalse);
  });

  testWidgets('a wrong password: no key asked for, nobody signed in, an error shown, the email not kept',
      (tester) async {
    final (built, signedIn) = await signIn(tester, () async => 'made-key', me: null);
    expect(built.single.keyNames, isEmpty);
    expect(signedIn, isNull);
    expect(built.single.closed, isTrue);
    expect(find.byType(ErrorText), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getString('email'), isNull);
  });

  test('the key name says which device and when - never the same twice on one device', () {
    final a = withClock(Clock.fixed(DateTime(2026, 10, 24, 9, 5, 7)), apiKeyName);
    final b = withClock(Clock.fixed(DateTime(2026, 10, 24, 9, 5, 8)), apiKeyName);
    expect(a, endsWith('2026-10-24 09:05:07'));
    expect(a, isNot(b));
  });

  test('a password credential goes to Komga as HTTP Basic, a key as X-API-Key - on every request, pages too',
      () async {
    final seen = <Map<String, String>>[];
    Komga client(String credential) => http.runWithClient(() => Komga('http://komga.test', credential),
        () => MockClient((r) async {
              seen.add(r.headers);
              return http.Response(r.url.path.endsWith('api-keys') ? '{"key":"k2"}' : '{"id":"U1"}', 200);
            }));
    final byPassword = client(Komga.basic('a@b.c', 'pw'));
    await byPassword.me();
    expect(await byPassword.createApiKey('BeDeReader on test'), 'k2');
    await byPassword.pageBytes('B1', 1).then((_) {}, onError: (_) {});
    for (final h in seen) {
      expect(h['Authorization'], 'Basic ${base64Encode(utf8.encode('a@b.c:pw'))}');
      expect(h.containsKey('X-API-Key'), isFalse);
    }
    seen.clear();
    await client('k1').me();
    expect((seen.single['X-API-Key'], seen.single.containsKey('Authorization')), ('k1', false));
  });
}

/// Komga signed in to by password: answers /users/me with [meAnswer] (null: wrong password, here as no user) and
/// "an API key, please" with [makeKey]; notes the key names asked for and whether it was closed.
class _PasswordKomga extends Komga {
  _PasswordKomga(super.baseUrl, super.apiKey, this.makeKey, this.meAnswer);
  final Future<String> Function() makeKey;
  final Map<String, dynamic>? meAnswer;
  int meCalls = 0;
  final keyNames = <String>[];
  bool closed = false;
  @override
  Future<Map<String, dynamic>?> me({via, Duration limit = Komga.timeout}) async {
    meCalls++;
    if (meAnswer == null) throw KomgaError(401, '/api/v2/users/me');
    return meAnswer;
  }

  @override
  Future<String> createApiKey(String comment) {
    keyNames.add(comment);
    return makeKey();
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}

/// Komga at the address typed, answering /users/me (no network: anything else fails the test).
class _SignInKomga extends Komga {
  _SignInKomga(super.baseUrl, super.apiKey);
  int meCalls = 0;
  @override
  Future<Map<String, dynamic>?> me({via, Duration limit = Komga.timeout}) async {
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
  Future<Map<String, dynamic>?> me({via, Duration limit = Komga.timeout}) {
    meCalls++;
    return answer.future;
  }
}

