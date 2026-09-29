import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/offline/connection.dart';
import 'package:komga_reader/offline/downloads.dart';
import 'package:komga_reader/offline/offline_komga.dart';
import 'package:komga_reader/offline/sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'downloads_test.dart' show FakeKomga;

/// Komga with reading progress kept in memory (bookId -> readProgress; absent = unread).
class ProgressServer extends FakeKomga {
  final Map<String, Map<String, dynamic>> rp = {};
  final writes = <String>[];
  final missing = <String>{};

  @override
  Future<Map<String, dynamic>?> book(String id) async {
    if (missing.contains(id)) return null;
    return {...(await super.book(id))!, 'readProgress': rp[id]};
  }

  @override
  Future<void> setProgress(String bookId, int page, {bool completed = false}) async {
    writes.add('$bookId page $page');
    rp[bookId] = {'page': page, 'completed': completed};
  }

  @override
  Future<void> markRead(String bookId) async {
    writes.add('$bookId read');
    rp[bookId] = {'page': 3, 'completed': true};
  }

  @override
  Future<void> markUnread(String bookId) async {
    writes.add('$bookId unread');
    rp.remove(bookId);
  }

  @override
  Future<Map<String, dynamic>> seriesBooks(String seriesId, {List<String>? readStatus,
      String sort = 'metadata.numberSort,asc', int page = 0, int size = 500}) async =>
      {'content': [for (final id in ['B1', 'B2']) {'id': id, 'readProgress': rp[id]}]};
}

/// Offline phase 5: progress made offline reaches Komga - as it is when only this device changed it, further-wins
/// with an alert entry when Komga changed too; downloaded copies follow Komga.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late ProgressServer server;
  final conn = Connection.instance;
  final sync = ProgressSync.instance;
  final d = Downloads.instance;

  Map<String, dynamic> entry(String id) => {
        'book': {'id': id, 'seriesId': 'S1', 'readProgress': server.rp[id]},
        'readLists': [], 'pages': [{}, {}, {}], 'state': 'done',
      };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('komga_sync_test');
    server = ProgressServer();
    server.rp['B1'] = {'page': 1, 'completed': false}; // B1 started on page 1, B2 unread, when downloaded
    await d.attach(server, root: dir);
    await d.store!.put('B1', entry('B1'));
    await d.store!.put('B2', entry('B2'));
    await conn.load(server);
    sync.reset();
    sync.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    sync.takeResult();
    server.writes.clear();
  });
  tearDown(() async {
    sync.reset();
    conn.reset();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await dir.delete(recursive: true);
  });

  OfflineKomga offlineApi() => OfflineKomga(d.store!, baseUrl: 'offline');

  test('only this device changed: sent as it is, including mark as unread', () async {
    final off = offlineApi();
    await off.setProgress('B2', 2); // read offline
    await off.markUnread('B1'); // and marked unread
    expect(sync.pending, 2);

    await sync.run();
    expect(server.writes, unorderedEquals(['B2 page 2', 'B1 unread']));
    expect(server.rp['B2'], {'page': 2, 'completed': false});
    expect(server.rp.containsKey('B1'), isFalse);
    expect(sync.pending, 0);
    final r = sync.takeResult()!;
    expect(r.sent, 2);
    expect(r.conflicts, isEmpty);
  });

  test('Komga changed too: further wins, both ways, and each is listed', () async {
    final off = offlineApi();
    await off.setProgress('B1', 3); // here: B1 on to page 3 ...
    server.rp['B1'] = {'page': 2, 'completed': false}; // ... Komga (the web) only got to page 2: here is further
    await off.setProgress('B2', 1); // here: B2 page 1 ...
    server.rp['B2'] = {'page': 3, 'completed': true}; // ... Komga: finished it: Komga is further

    await sync.run();
    expect(server.writes, ['B1 page 3']); // B2 is never un-finished
    expect(server.rp['B2']!['completed'], isTrue);
    expect(d.store!.readProgressOf('B2')!['completed'], isTrue); // the downloaded copy takes Komga's
    final r = sync.takeResult()!;
    expect(r.conflicts.map((c) => (c.here, c.komga, c.keptHere)), unorderedEquals([
      ('page 3', 'page 2', true),
      ('page 1', 'read', false),
    ]));
  });

  test('Komga changed to the same thing: not a clash', () async {
    await offlineApi().markRead('B1');
    server.rp['B1'] = {'page': 3, 'completed': true}; // read on the web as well
    await sync.run();
    expect(server.writes, isEmpty);
    expect(sync.takeResult()!.conflicts, isEmpty);
  });

  test('book gone from Komga: its queued progress is dropped and counted', () async {
    await offlineApi().setProgress('B2', 2);
    server.missing.add('B2');
    await sync.run();
    expect(sync.pending, 0);
    expect(sync.takeResult()!.gone, 1);
  });

  test('offline: nothing is sent; back online: sent', () async {
    await conn.setForcedOffline(true);
    await offlineApi().setProgress('B2', 2);
    await sync.run();
    expect(server.writes, isEmpty);
    await conn.setForcedOffline(false); // going back online runs it
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(server.writes, ['B2 page 2']);
  });

  test('downloaded copies follow Komga: reading elsewhere (refresh) and reading online here (mirror)', () async {
    server.rp['B2'] = {'page': 2, 'completed': false}; // read on the web
    await sync.run();
    expect(d.store!.readProgressOf('B2')!['page'], 2);

    Komga.onProgressWritten!(server, const ProgressWrite(bookId: 'B1', completed: true)); // read online here
    expect(d.store!.readProgressOf('B1')!['completed'], isTrue);
    Komga.onProgressWritten!(server, const ProgressWrite(seriesId: 'S1', unread: true)); // whole series unread
    expect(d.store!.readProgressOf('B1'), isNull);
    expect(d.store!.readProgressOf('B2'), isNull);
    expect(sync.pending, 0); // none of that needs sending
  });
}
