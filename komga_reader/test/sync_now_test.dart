// Settings > Server & Sync > Sync (user, 2026-10-27): when this device last synced with Komga, and Sync now - for when
// something seems off. Last Sync is the last time Komga answered for the synced settings (read or written); Sync now
// reads them again at once, past the few seconds a refresh is otherwise held back for.
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/hidden_libraries.dart';
import 'package:komga_reader/pins.dart';
import 'package:komga_reader/refresh_gate.dart';
import 'package:komga_reader/screens/app_settings.dart';
import 'package:komga_reader/sync_status.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';

/// A real [Komga] whose requests are recorded ("GET /api/v1/client-settings/user/list"); [down]: every one fails.
class _Server {
  final requests = <String>[];
  bool down = false;
  late final Komga api = Komga('http://test', 'k', client: MockClient((r) async {
    requests.add('${r.method} ${r.url.path}');
    if (down) throw http.ClientException('Connection refused', r.url);
    final p = r.url.path;
    if (p == '/api/v1/client-settings/user/list') return _json({});
    if (p == '/api/v1/libraries') return _json([]);
    if (p == '/api/v2/users/me') return _json({'id': 'U1', 'email': 'nick@test'});
    if (r.method == 'PATCH') return http.Response('', 204);
    return _json({'content': [], 'totalElements': 0, 'last': true});
  }));
  int get settingsAsked => requests.where((r) => r == 'GET /api/v1/client-settings/user/list').length;
  static http.Response _json(Object body) =>
      http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiddenLibraries.instance.load();
    SyncStatus.instance.reset();
  });

  test('Last Sync says when: today, yesterday, else the date', () {
    final now = DateTime(2026, 10, 27, 15, 0);
    expect(syncTimeLabel(DateTime(2026, 10, 27, 9, 5), now), 'Today, 09:05');
    expect(syncTimeLabel(DateTime(2026, 10, 26, 23, 59), now), 'Yesterday, 23:59');
    expect(syncTimeLabel(DateTime(2026, 9, 3, 7, 30), now), '3 Sep 2026, 07:30');
  });

  test("Komga answering for the synced settings - read or written - is a sync, kept across restarts; Komga not "
      'answering is not', () async {
    final s = _Server();
    await withClock(Clock.fixed(DateTime(2026, 10, 27, 14, 5)), () => s.api.clientSettings());
    expect(SyncStatus.instance.last, DateTime(2026, 10, 27, 14, 5));
    await withClock(Clock.fixed(DateTime(2026, 10, 27, 14, 6)), () => s.api.putClientSetting('k', 'v'));
    expect(SyncStatus.instance.last, DateTime(2026, 10, 27, 14, 6));
    SyncStatus.instance.reset();
    await SyncStatus.instance.load();
    expect(SyncStatus.instance.last, DateTime(2026, 10, 27, 14, 6), reason: 'kept on the device');

    s.down = true;
    await expectLater(withClock(Clock.fixed(DateTime(2026, 10, 27, 15)), () => s.api.clientSettings()), throwsA(anything));
    expect(SyncStatus.instance.last, DateTime(2026, 10, 27, 14, 6));
  });

  test('a refresh held back for a few seconds after the last ask - not when forced (Sync now)', () async {
    final gate = RefreshGate();
    var runs = 0;
    Future<void> fetch() async => runs++;
    await gate.run(fetch);
    gate.asked();
    await gate.run(fetch);
    expect(runs, 1, reason: 'held back');
    await gate.run(fetch, force: true);
    expect(runs, 2);
  });

  testWidgets('Settings > Server & Sync: Last Sync as it was; Sync now asks Komga again at once - right after a refresh '
      'too - and Last Sync follows', (tester) async {
    setView(tester, const Size(1000, 2400));
    final s = _Server();
    await tester.runAsync(() async {
      await Pins.instance.load(s.api); // (Komga asked: a sync, just now)
    });
    addTearDown(() => tester.runAsync(Pins.instance.clearAccount));
    final first = SyncStatus.instance.last!;
    final asked = s.settingsAsked;
    await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(api: s.api, onSignOut: () {},
        initialPage: SettingsPage.server)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.text(syncTimeLabel(first, clock.now())), findsOneWidget);

    await tester.pump(const Duration(seconds: 2)); // (the test's clock on: still within the 10 s a refresh is held for)
    await tester.tap(find.byKey(AppSettingsScreen.syncNowKey));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    expect(s.settingsAsked, greaterThan(asked), reason: 'asked again, within the few seconds a refresh waits');
    expect(SyncStatus.instance.last!.isAfter(first), isTrue);
  });
}
