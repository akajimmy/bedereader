import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/offline/connection.dart';
import 'package:komga_reader/offline/downloads.dart';
import 'package:komga_reader/offline/offline_komga.dart';
import 'package:komga_reader/pins.dart';
import 'package:komga_reader/screens/home.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/library_server.dart';
import 'support/no_network.dart';
import 'support/helpers.dart';
import 'support/offline_store.dart';

void main() {
  testWidgets('offline, pins whose view has nothing downloaded are hidden', (tester) async {
    SharedPreferences.setMockInitialValues({});
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('komga_offline_pins');
      await Downloads.instance.attach(noNetwork(LibraryServer.new), root: dir);
      Downloads.instance.store!.books.addAll((await buildStore(Directory('${dir.path}/built'))).books);
      Downloads.instance.hold = true;
    });
    Connection.instance
      ..online = noNetwork(LibraryServer.new)
      ..forcedOffline = true;
    Pins.instance.items = const [
      Pin(name: 'Surfer', kind: 'series', id: 'S1', title: 'Silver Surfer'), // downloaded
      Pin(name: 'Hulk', kind: 'series', id: 'S9', title: 'Hulk'), // nothing downloaded
      Pin(name: 'Surfer unread', kind: 'series', id: 'S1', title: 'Silver Surfer', filter: 'hideRead'), // B2, B5
    ];
    final api = OfflineKomga(Downloads.instance.store!);
    await tester.pumpWidget(MaterialApp(home: HomeScreen(api: api, onSignOut: () {})));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Surfer'), findsOneWidget);
    expect(find.text('Surfer unread'), findsOneWidget);
    expect(find.text('Hulk'), findsNothing);
    expect(find.text('Nothing downloaded on deck'), findsOneWidget); // S1 has a book in progress, so nothing on deck

    Connection.instance.forcedOffline = false;
    Pins.instance.items = [];
    await tester.runAsync(() => deleteTemp(dir));
  });
}
