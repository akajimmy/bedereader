// Fewer requests to Komga, and no HTTP client left open (code review 2026-10-05: #35, #43, #50). Each test failed on
// the code before the fix.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/hidden_libraries.dart';
import 'package:komga_reader/offline/connection.dart';
import 'package:komga_reader/ondeck_hidden.dart';
import 'package:komga_reader/pins.dart';
import 'package:komga_reader/refresh_gate.dart';
import 'package:komga_reader/screens/login.dart';
import 'package:komga_reader/settings.dart';
import 'package:komga_reader/widgets/drawer.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A client that answers with [answer] and records each request ("GET /api/v1/libraries") and whether it was closed.
class SpyClient extends MockClient {
  SpyClient(this.requests, Future<http.Response> Function(http.Request) answer)
      : super((r) {
          requests.add('${r.method} ${r.url.path}');
          return answer(r);
        });
  final List<String> requests;
  bool closed = false;
  @override
  void close() => closed = true;
}

http.Response json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

const libs = [
  {'id': 'L1', 'name': 'Ongoing'},
  {'id': 'L2', 'name': 'Archive'},
];

/// A real [Komga] on a [SpyClient]: libraries, the client-settings store (with [settings] in it), /users/me.
(Komga, SpyClient) komga({Map<String, String> settings = const {}}) {
  final unexpected = <String>[];
  addTearDown(() => expect(unexpected, isEmpty, reason: 'requests no test here expects'));
  final client = SpyClient([], (r) async {
    final p = r.url.path;
    if (p == '/api/v1/libraries') return json(libs);
    if (p == '/api/v1/client-settings/user/list') return json({for (final e in settings.entries) e.key: {'value': e.value}});
    if (p == '/api/v2/users/me') return json({'id': 'U1'});
    if (r.method == 'PATCH' && p == '/api/v1/client-settings/user') return http.Response('', 204);
    unexpected.add('${r.method} ${r.url}');
    return http.Response('not in this test', 404);
  });
  return (Komga('http://test', 'k', client: client), client);
}

int count(List<String> requests, String request) => requests.where((r) => r == request).length;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiddenLibraries.instance.load();
  });

  testWidgets('#35: a Home reload - reader settings, pins and On deck hidden refreshed together - asks Komga for the '
      'client settings once, and each takes its part from that answer', (tester) async {
    final (api, client) = komga(settings: {
      Pins.komgaKey: jsonEncode([const Pin(name: 'Mine', kind: 'library', id: 'L1', title: 'Ongoing').toJson()]),
      OnDeckHidden.komgaKey: '{"series":["S1"],"books":[]}',
      AppSettings.komgaKey: jsonEncode({'v': 1, 'default': const ReaderPrefs().toJson(),
          'series': {'S7': const ReaderPrefs().toJson()}}),
    });
    RefreshGate.gap = Duration.zero;
    addTearDown(() async {
      RefreshGate.gap = const Duration(seconds: 10);
      await tester.runAsync(() async {
        await AppSettings.instance.clearAccount();
        await Pins.instance.clearAccount();
        await OnDeckHidden.instance.clearAccount();
      });
    });
    await tester.runAsync(() async {
      // the device's copies (nothing asked yet), as after a start
      await AppSettings.instance.load(api, fetch: false);
      await Pins.instance.load(api, fetch: false);
      await OnDeckHidden.instance.load(api, fetch: false);
      expect(client.requests, isEmpty);
      // what Home's load (and main.dart, back online) does
      await Future.wait([Pins.instance.refresh(), AppSettings.instance.refresh(), OnDeckHidden.instance.refresh()]);
    });
    expect(count(client.requests, 'GET /api/v1/client-settings/user/list'), 1, reason: '${client.requests}');
    expect(Pins.instance.items.single.name, 'Mine');
    expect(OnDeckHidden.instance.seriesHidden('S1'), isTrue);
    expect(AppSettings.instance.hasOwn('S7'), isTrue);
  });

  test('#35: shared only while on its way; a write in between starts afresh', () async {
    final (api, client) = komga();
    final before = api.clientSettings();
    expect(identical(api.clientSettings(), before), isTrue, reason: 'asked while on its way: the same answer');
    await before;
    await api.clientSettings(); // after the answer: asked again
    expect(count(client.requests, 'GET /api/v1/client-settings/user/list'), 2);

    final asked = api.clientSettings();
    final writing = api.putClientSetting('x', 'y');
    final after = api.clientSettings();
    expect(identical(after, asked), isFalse, reason: 'an answer asked for before the write is not shared after it');
    await Future.wait([asked, writing, after]);
    expect(count(client.requests, 'GET /api/v1/client-settings/user/list'), 4);
  });

  testWidgets('#43: the side menu keeps the library list - opened twice, one request; back in the app, the next '
      'opening asks again; hidden libraries stay out of the kept list', (tester) async {
    final (api, client) = komga();
    final conn = Connection.instance;
    addTearDown(conn.reset);
    conn.online = api;
    Future<void> openMenu() async {
      await tester.pumpWidget(const SizedBox()); // the menu closed: a slide-out menu is built anew each opening
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: AppDrawer(api: api, onSignOut: () {}, docked: true))));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }

    await openMenu();
    expect(find.text('Archive'), findsOneWidget);
    await openMenu();
    expect(find.text('Ongoing'), findsOneWidget);
    expect(count(client.requests, 'GET /api/v1/libraries'), 1, reason: 'the second opening used the kept list');

    await tester.runAsync(() => HiddenLibraries.instance.setHidden('L2', true));
    await openMenu();
    expect(find.text('Archive'), findsNothing, reason: 'hidden on this device');
    expect(find.text('Ongoing'), findsOneWidget);
    expect(count(client.requests, 'GET /api/v1/libraries'), 1);

    conn.didChangeAppLifecycleState(AppLifecycleState.resumed); // the app back in the foreground
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20))); // (its check of Komga)
    await openMenu();
    expect(count(client.requests, 'GET /api/v1/libraries'), 2, reason: 'asked again after coming back to the app');
    expect(find.text('Ongoing'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("#50: a failed sign-in closes that attempt's HTTP client; a successful one keeps it", (tester) async {
    final clients = <SpyClient>[];
    var refuse = true;
    Komga? signedIn;
    await tester.pumpWidget(MaterialApp(home: LoginScreen(
      onSignedIn: (api) async => signedIn = api,
      client: (server, key) {
        final c = SpyClient([], (r) async => refuse ? json({}, 401) : json({'id': 'U1'}));
        clients.add(c);
        return Komga(server, key, client: c);
      },
    )));
    await tester.pump();
    await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == 'Server'),
        'http://nas:25600');
    await tester.tap(find.text('API key')); // (the API key tab: Password is first)
    await tester.pump();
    await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == 'API key'),
        'wrong');
    await tester.tap(find.byType(FilledButton));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(clients, hasLength(1));
    expect(clients.single.requests, ['GET /api/v2/users/me']);
    expect(signedIn, isNull);
    expect(clients.single.closed, isTrue, reason: 'the failed attempt left nothing open');

    refuse = false;
    await tester.tap(find.byType(FilledButton));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(clients, hasLength(2));
    expect(signedIn, isNotNull);
    expect(clients.last.closed, isFalse, reason: 'the signed-in connection is in use');
  });

  test('#50: close waits for the requests on their way, then closes the client', () async {
    final (api, client) = komga();
    final asking = api.libraries();
    api.close();
    expect(client.closed, isFalse, reason: 'a request is on its way');
    await asking;
    expect(client.closed, isTrue);
  });
}
