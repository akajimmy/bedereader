// Local libraries beside Komga's (experimental/sources, lib/local/mixed_komga.dart): one list of libraries, views
// across every library merged in their order, and everything about a local book answered locally - never asked of
// Komga.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:komga_reader/local/folder_komga.dart';
import 'package:komga_reader/local/folder_scan.dart';
import 'package:komga_reader/local/mixed_komga.dart';
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
}
