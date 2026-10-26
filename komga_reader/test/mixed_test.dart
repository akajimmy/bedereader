// Local libraries beside Komga's (experimental/sources, lib/local/mixed_komga.dart): one list of libraries, views
// across every library merged in their order, and everything about a local book answered locally - never asked of
// Komga.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:komga_reader/local/folder_komga.dart';
import 'package:komga_reader/local/folder_scan.dart';
import 'package:komga_reader/local/mixed_komga.dart';
import 'package:komga_reader/local/storage.dart';
import 'package:komga_reader/offline/connection.dart';
import 'package:komga_reader/offline/downloads.dart';
import 'package:komga_reader/offline/offline_komga.dart';
import 'package:komga_reader/widgets/connection_prompt.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/zip_writer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root, data;
  late MixedKomga api;
  final asked = <String>[];

  // Komga: one library, two series, one book each
  Map<String, dynamic> series(String id, String name) =>
      {'id': id, 'name': name, 'libraryId': 'K1', 'metadata': {'title': name, 'titleSort': name}, 'booksCount': 1};
  Map<String, dynamic> book(String id, String series, String date) => {
        'id': id, 'seriesId': '${series}S', 'seriesTitle': series, 'name': series,
        'metadata': {'title': series, 'numberSort': 1, 'releaseDate': date}, 'media': {'mediaProfile': 'DIVINA'},
      };
  Map<String, dynamic> page(List<dynamic> items) => {'content': items, 'totalElements': items.length, 'last': true};

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    asked.clear();
    root = await Directory.systemTemp.createTemp('mixed_lib');
    data = await Directory.systemTemp.createTemp('mixed_data');
    final png = await solidPng(2, 3);
    final saga = Directory('${root.path}${Platform.pathSeparator}Saga (2012)');
    await saga.create();
    await File('${saga.path}${Platform.pathSeparator}Saga #1 (2012).cbz').writeAsBytes(zipOf({'1.png': png}));
    final client = MockClient((r) async {
      asked.add('${r.method} ${r.url.path}');
      final body = switch (r.url.path) {
        '/api/v1/libraries' => [{'id': 'K1', 'name': 'Comics'}],
        '/api/v1/series' => page([series('0A', 'Batman'), series('0B', 'Zatanna')]),
        '/api/v1/books' => page([book('0X', 'Batman', '2024-05-01'), book('0Y', 'Zatanna', '2010-01-01')]),
        _ => null,
      };
      return body == null ? http.Response('', 404) : http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json'});
    });
    api = MixedKomga('http://komga.test', 'key', client: client);
    api.local = await FolderKomga.open([LocalLibrary.at(root.path)], dataDir: data);
    await api.local!.rescan(); // (the start's own scan, done)
  });
  tearDown(() async {
    await deleteTemp(root);
    await deleteTemp(data);
  });

  test("one list of libraries: Komga's, then the local ones", () async {
    expect([for (final l in await api.visibleLibraries()) l['name']], ['Comics', root.path.split(Platform.pathSeparator).last]);
  });

  test("across every library, both merged in the order asked for; in a local library, the local ones only - Komga "
      'not asked', () async {
    expect([for (final s in (await api.series())['content'] as List) s['name']], ['Batman', 'Saga (2012)', 'Zatanna']);
    final newest = (await api.books(sort: 'metadata.releaseDate,desc'))['content'] as List;
    expect([for (final b in newest) b['seriesTitle']], ['Batman', 'Saga (2012)', 'Zatanna'], reason: '2024, 2012, 2010');
    asked.clear();
    final lib = api.local!.folders.single.id;
    expect([for (final s in (await api.series(libraryId: lib))['content'] as List) s['name']], ['Saga (2012)']);
    expect(asked, isEmpty);
  });

  test("a local book's series, pages, progress and next book: answered locally, never asked of Komga", () async {
    final saga = ((await api.series())['content'] as List).firstWhere((s) => s['name'] == 'Saga (2012)') as Map;
    asked.clear();
    final b = ((await api.seriesBooks(saga['id'] as String))['content'] as List).single as Map;
    expect(api.isLocal(b['id'] as String), isTrue);
    expect(await api.pages(b['id'] as String), hasLength(1));
    expect((await api.pageBytes(b['id'] as String, 1)).length, greaterThan(0));
    await api.setProgress(b['id'] as String, 1, completed: true);
    expect((await api.book(b['id'] as String))!['readProgress']['completed'], isTrue);
    expect(await api.nextBook(b['id'] as String), isNull);
    expect(asked, isEmpty);
  });

  test("signed in to Komga, the start doesn't wait for the local libraries' first scan (code review, 2026-10-25: Home "
      'waited for all of it - 11 s and more on the NAS): attached at once, the books come in when the scan is done',
      () async {
    final store = await Directory.systemTemp.createTemp('mixed_store');
    addTearDown(() => deleteTemp(store));
    const screen = MethodChannel('komga_reader/screen');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(screen, (c) async => c.method == 'storageDir' ? store.path : null);
    addTearDown(() => messenger.setMockMethodCallHandler(screen, null));
    await FolderKomga.saveLibraries([LocalLibrary.at(root.path)]); // (a library added, never scanned here)
    final gate = Completer<void>();
    Storage.fsFor = (_) => _Held(gate.future);
    addTearDown(() => Storage.fsFor = null);

    final fresh = MixedKomga('http://komga.test', 'key');
    await fresh.attachLocal().timeout(const Duration(seconds: 5)); // (it waited for the gate: timed out here)
    expect(fresh.local, isNotNull);
    expect(fresh.local!.isEmpty, isTrue, reason: 'not read yet');

    final read = Completer<void>();
    fresh.local!.changed.addListener(() { if (!read.isCompleted) read.complete(); });
    gate.complete();
    await read.future.timeout(const Duration(seconds: 5));
    expect(fresh.local!.isEmpty, isFalse, reason: 'the scan done: its books are in');
  });

  // user, 2026-10-25: "local library should always be available ... and Komga libraries should be available when
  // Komga is reachable. All of those should be independent of each other"
  group('offline (Komga out of reach, or offline by hand): the local libraries are still there', () {
    late Directory store;
    final conn = Connection.instance, d = Downloads.instance;
    setUp(() async {
      store = await Directory.systemTemp.createTemp('mixed_dl');
      d.reset();
      await d.attach(api, root: store, start: false);
      d.store!.books['0X'] = {'book': book('0X', 'Batman', '2024-05-01'), 'series': {...series('BatmanS', 'Batman')},
          'readLists': [], 'state': 'done'};
      await conn.load(api);
      await Future<void>.delayed(Duration.zero); // (the start-up check)
      await conn.setForcedOffline(true);
    });
    tearDown(() async {
      conn.reset();
      d.reset();
      await deleteTemp(store);
    });

    test('the downloads and the local books side by side; a local book read and its place saved, Komga not asked',
        () async {
      final offline = conn.api;
      expect(offline, isA<OfflineKomga>());
      asked.clear();
      expect([for (final s in (await offline.series())['content'] as List) s['name']], ['Batman', 'Saga (2012)']);
      final saga = ((await offline.series())['content'] as List).firstWhere((s) => s['name'] == 'Saga (2012)') as Map;
      final b = ((await offline.seriesBooks(saga['id'] as String))['content'] as List).single as Map;
      expect(await offline.pages(b['id'] as String), hasLength(1));
      expect((await offline.pageBytes(b['id'] as String, 1)).length, greaterThan(0));
      await offline.setProgress(b['id'] as String, 1, completed: true);
      expect((await api.local!.book(b['id'] as String))!['readProgress']['completed'], isTrue);
      expect(asked, isEmpty);
    });

    test('nothing downloaded, local books only: going offline is still offered', () {
      d.store!.books.clear();
      expect(conn.hasDownloads, isFalse);
      expect(conn.hasLocal, isTrue);
      expect(offlineBooks(conn), 'your local libraries');
    });
  });
}

/// This device's files, the first look at a folder held until [gate] (a slow first scan).
class _Held implements LibraryFs {
  _Held(this.gate);
  final Future<void> gate;
  static const _real = LocalFs();

  @override
  Future<bool> exists(String folder) async {
    await gate;
    return _real.exists(folder);
  }

  @override
  Future<bool> placeAnswers(String folder) => _real.placeAnswers(folder);
  @override
  Stream<FsEntry> list(String folder) => _real.list(folder);
  @override
  Future<FolderLook> look(String folder) => _real.look(folder);
  @override
  Future<int> length(String path) => _real.length(path);
  @override
  Future<Uint8List> readAll(String path) => _real.readAll(path);
  @override
  Future<Uint8List> readRange(String path, int offset, int length) => _real.readRange(path, offset, length);
}
