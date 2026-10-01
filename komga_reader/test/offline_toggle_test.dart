import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/offline/connection.dart';
import 'package:komga_reader/offline/downloads.dart';
import 'package:komga_reader/offline/offline_komga.dart';
import 'package:komga_reader/screens/home.dart';
import 'package:komga_reader/widgets/drawer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/library_server.dart';
import 'support/no_network.dart';

void main() {
  late Directory dir;
  final conn = Connection.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('komga_toggle_test');
  });
  tearDown(() async {
    await conn.setForcedOffline(false);
    await dir.delete(recursive: true);
  });

  test('offline mode switches every screen to the downloaded books, holds downloads, and is remembered', () async {
    final online = noNetwork(LibraryServer.new);
    await Downloads.instance.attach(online, root: dir);
    await conn.load(online);
    expect(conn.api, same(online));

    await conn.setForcedOffline(true);
    expect(conn.api, isA<OfflineKomga>());
    expect(Downloads.instance.hold, isTrue); // nothing talks to the server
    expect((await SharedPreferences.getInstance()).getBool('offline.forced'), isTrue);

    conn.reset(); // "restart": memory gone, only what was saved is left (test audit, 2026-09-30)
    await conn.load(online);
    expect(conn.offline, isTrue, reason: 'still offline after the restart');

    await conn.setForcedOffline(false);
    expect(conn.api, same(online));
    expect(Downloads.instance.hold, isFalse);
  });

  testWidgets('Home offline shows the banner; Go online switches back', (tester) async {
    final online = noNetwork(LibraryServer.new);
    await tester.runAsync(() async {
      await Downloads.instance.attach(online, root: dir);
      await conn.load(online);
      await conn.setForcedOffline(true);
    });
    await tester.pumpWidget(MaterialApp(home: HomeScreen(api: conn.api, onSignOut: () {})));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    expect(find.text('Offline mode - showing downloaded books'), findsOneWidget);
    await tester.tap(find.text('Go online'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(conn.offline, isFalse);
  });

  testWidgets('side menu has the Offline mode switch', (tester) async {
    final online = noNetwork(LibraryServer.new);
    await tester.runAsync(() async {
      await Downloads.instance.attach(online, root: dir);
      await conn.load(online);
    });
    final scaffold = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(MaterialApp(home: Scaffold(key: scaffold,
        drawer: AppDrawer(api: online, onSignOut: () {}), body: const SizedBox())));
    scaffold.currentState!.openDrawer();
    await tester.pumpAndSettle();
    final sw = find.widgetWithText(SwitchListTile, 'Offline mode');
    expect(tester.widget<SwitchListTile>(sw).value, isFalse);
    expect(find.text('Connected to Komga'), findsNothing); // the label says it all (user)
    await tester.tap(find.widgetWithText(SwitchListTile, 'Offline mode'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(conn.offline, isTrue);
    expect(tester.widget<SwitchListTile>(sw).value, isTrue);
  });
}
