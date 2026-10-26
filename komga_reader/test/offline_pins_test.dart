import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/local/folder_komga.dart';
import 'package:komga_reader/local/folder_scan.dart' show isLocalId;
import 'package:komga_reader/local/mixed_komga.dart';
import 'package:komga_reader/offline/connection.dart';
import 'package:komga_reader/offline/downloads.dart';
import 'package:komga_reader/offline/offline_komga.dart';
import 'package:komga_reader/pins.dart';
import 'package:komga_reader/screens/home.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/library_server.dart';
import 'support/home_server.dart';
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
    addTearDown(() => deleteTemp(dir));
    addTearDown(() => Downloads.instance.hold = false);
    Connection.instance
      ..online = noNetwork(LibraryServer.new)
      ..forcedOffline = true;
    addTearDown(Connection.instance.reset);
    addTearDown(() => Pins.instance.items = []);
    Pins.instance.items = const [
      Pin(name: 'Surfer', kind: 'series', id: 'S1', title: 'Silver Surfer'), // downloaded
      Pin(name: 'Hulk', kind: 'series', id: 'S9', title: 'Hulk'), // nothing downloaded
      Pin(name: 'Surfer unread', kind: 'series', id: 'S1', title: 'Silver Surfer', filter: 'hideRead'), // B2, B5
      // a single book (2026-10-16): downloaded, and not
      Pin(name: 'Book two', kind: 'book', id: 'B2', title: 'B2'),
      Pin(name: 'Book nine', kind: 'book', id: 'B9', title: 'B9'),
    ];
    final api = OfflineKomga(Downloads.instance.store!);
    await tester.pumpWidget(MaterialApp(home: HomeScreen(api: api, onSignOut: () {})));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Surfer'), findsOneWidget);
    expect(find.text('Surfer unread'), findsOneWidget);
    expect(find.text('Hulk'), findsNothing);
    expect(find.text('Book two'), findsOneWidget);
    expect(find.text('Book nine'), findsNothing, reason: 'a pinned book not downloaded: hidden');
    expect(find.text('Nothing downloaded on deck'), findsOneWidget); // S1 has a book in progress, so nothing on deck
  });

  // punch list 10: only No server mode hid them - signed in, a series pinned in a local library since removed showed
  // "0 books"
  testWidgets('signed in to Komga with local libraries: a pin to a local thing leading to nothing is hidden; '
      "Komga's pins are left as they are, even one leading to nothing", (tester) async {
    SharedPreferences.setMockInitialValues({});
    late FolderKomga local;
    await tester.runAsync(() async {
      final data = await Directory.systemTemp.createTemp('komga_local_pins');
      addTearDown(() => deleteTemp(data));
      local = await FolderKomga.open(const [], dataDir: data);
    });
    addTearDown(() => Pins.instance.items = []);
    Pins.instance.items = const [
      Pin(name: 'Surfer', kind: 'series', id: 'S1', title: 'Silver Surfer'), // Komga's
      Pin(name: 'Hulk', kind: 'series', id: 'S9', title: 'Hulk'), // Komga's, not there: left alone
      Pin(name: 'Gone local', kind: 'series', id: 'S3k9x2lq0aa', title: 'Saga'), // a local series since removed
    ];
    final api = noNetwork(_MixedServer.new)..local = local;
    await tester.pumpWidget(MaterialApp(home: HomeScreen(api: api, onSignOut: () {})));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Surfer'), findsOneWidget);
    expect(find.text('Hulk'), findsOneWidget, reason: "Komga's pins aren't hidden");
    expect(find.text('Gone local'), findsNothing);
  });

  test("a local id is told by its shape, Komga's never taken for one", () {
    expect(['L1x9q', 'S3k9x2lq0aa', 'Bzz'].every(isLocalId), isTrue);
    expect(['S1', '0FQ3MZW3XV4T7', 'K9', 'Sabc-1', null].any(isLocalId), isFalse);
  });
}

/// The test Komga, with local libraries beside it as the app's own client has them.
class _MixedServer extends HomeServer with LocalBeside {
  _MixedServer();

  // the pinned series' books (their tiles ask): none - what a pinned Komga series shows doesn't matter here
  @override
  Future<Map<String, dynamic>> seriesBooks(String seriesId, {List<String>? readStatus,
          String sort = 'metadata.numberSort,asc', int page = 0, int size = 500}) async =>
      {'content': const [], 'totalElements': 0, 'last': true};
}
