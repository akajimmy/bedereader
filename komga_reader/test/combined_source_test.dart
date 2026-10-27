// Komga (here: a downloads store standing in for it) and the local libraries as one source (lib/combined_source.dart):
// each item asked of the source it's in; grids, On deck and search put together.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/combined_source.dart';
import 'package:komga_reader/local/local_library.dart';
import 'package:komga_reader/local/local_source.dart';
import 'package:komga_reader/offline/downloads_source.dart';
import 'package:komga_reader/offline/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/zip_writer.dart';

/// Komga's side: a downloads store, counting the pages of series asked for.
class _Main extends DownloadsSource {
  _Main(super.store) : super(baseUrl: 'http://komga');
  final asked = <int>[];

  @override
  Future<Map<String, dynamic>> series({String? libraryId, String? collectionId, List<String>? readStatus,
      String sort = 'metadata.titleSort,asc', int page = 0, int size = 60}) {
    asked.add(page);
    return super.series(libraryId: libraryId, collectionId: collectionId, readStatus: readStatus, sort: sort,
        page: page, size: size);
  }
}

void main() {
  late Directory root, data, offline;
  late _Main komga;
  late LocalSource local;
  late CombinedSource api;
  final png = Uint8List.fromList([...pngHead(800, 1200), 1, 2, 3]);

  /// Komga's series: [names], one book each (the book read when [read]).
  void komgaSeries(List<String> names, {bool read = false}) {
    for (final n in names) {
      final s = {'id': 'S$n', 'name': n, 'metadata': {'title': n, 'titleSort': n}};
      komga.store.books['B$n'] = {
        'book': {'id': 'B$n', 'seriesId': 'S$n', 'name': n, 'metadata': {'title': n, 'numberSort': 1}},
        'series': s, 'library': {'id': 'L1', 'name': 'Comics'}, 'state': 'done',
      };
      if (read) komga.store.progress['B$n'] = {'page': 1, 'completed': true, 'at': '2026-10-01T00:00:00'};
    }
  }

  Future<void> localSeries(List<String> names, {int books = 1}) async {
    for (final n in names) {
      for (var i = 1; i <= books; i++) {
        final f = File('${root.path}/$n/$n $i.cbz');
        await f.parent.create(recursive: true);
        await f.writeAsBytes(zipOf({'p1.png': png}));
      }
    }
    await local.rescan();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('combined_lib');
    data = await Directory.systemTemp.createTemp('combined_data');
    offline = await Directory.systemTemp.createTemp('combined_offline');
    komga = _Main(OfflineStore(offline));
    local = await LocalSource.open(data, [LocalLibrary.at(root.path)]);
    api = CombinedSource(komga, local: local);
  });
  tearDown(() async {
    await local.closeFiles();
    for (final d in [root, data, offline]) {
      await d.delete(recursive: true);
    }
  });

  test('no local book: Komga answers, as it is', () async {
    komgaSeries(['Batman', 'Saga']);
    final r = await api.series(size: 1);
    expect([for (final s in r['content'] as List) s['name']], ['Batman']);
    expect(komga.asked, [0]);
  });

  test("a grid with no library chosen: both sources' series in one order, page by page, Komga asked for its pages "
      'only as far as needed - and each page is what the whole merged list says', () async {
    komgaSeries(['Batman', 'Daredevil', 'Hulk', 'Superman', 'X-Men']);
    await localSeries(['Akira', 'Elektra', 'Saga']);
    final whole = ['Akira', 'Batman', 'Daredevil', 'Elektra', 'Hulk', 'Saga', 'Superman', 'X-Men'];
    final seen = <String>[];
    for (var p = 0; p < 3; p++) {
      final r = await api.series(page: p, size: 3);
      seen.addAll([for (final s in r['content'] as List) s['name'] as String]);
      expect(r['totalElements'], 8);
      expect(r['last'], p == 2);
    }
    expect(seen, whole);
    expect(komga.asked, [0, 1], reason: 'two of Komga\'s pages of 3 cover the 5 it has');
  });

  test("two views of the same list: one's first page doesn't upset the other's next (the experiment's did)", () async {
    komgaSeries(['Batman', 'Daredevil', 'Hulk', 'Superman', 'X-Men']);
    await localSeries(['Akira', 'Elektra', 'Saga']);
    await api.series(page: 0, size: 3); // view A
    await api.series(page: 0, size: 3); // view B, from the start
    final a1 = await api.series(page: 1, size: 3); // view A, on
    expect([for (final s in a1['content'] as List) s['name']], ['Elektra', 'Hulk', 'Saga']);
  });

  test("each item asked of the source it's in: a local book's pages and progress, Komga's book", () async {
    komgaSeries(['Batman']);
    await localSeries(['Saga']);
    final localBook = ((await local.books())['content'] as List).single['id'] as String;
    expect((await api.book(localBook))?['seriesTitle'], 'Saga');
    expect((await api.book('BBatman'))?['name'], 'Batman');
    expect((await api.pages(localBook)).single['width'], 800);
    await api.markRead(localBook);
    expect(local.readProgressOf(localBook)?['completed'], isTrue);
    expect(komga.store.progress, isEmpty);
    expect(api.sourceOf(localBook), same(local));
    expect(api.sourceOf('BBatman'), same(komga));
  });

  test("On deck and search keep room for the local libraries: 30 of Komga's no longer hide every local one (the "
      "experiment's put Komga's first and cut)", () async {
    komgaSeries([for (var i = 0; i < 40; i++) 'Batman $i'], read: true);
    for (var i = 0; i < 40; i++) {
      final n = 'Batman $i';
      komga.store.books['B$n-2'] = {
        'book': {'id': 'B$n-2', 'seriesId': 'S$n', 'name': '$n 2', 'metadata': {'title': '$n 2', 'numberSort': 2}},
        'series': {'id': 'S$n', 'name': n}, 'library': {'id': 'L1', 'name': 'Comics'}, 'state': 'done',
      };
    }
    await localSeries(['Batman Beyond'], books: 2);
    final first = ((await local.seriesBooks(((await local.series())['content'] as List).single['id'] as String))
        ['content'] as List).first['id'] as String;
    await local.markRead(first);

    final deck = (await api.onDeck(size: 30))['content'] as List;
    expect(deck.length, 30);
    expect(deck.where((b) => (b['id'] as String).startsWith('lb')), hasLength(1), reason: 'the local one is there');
    final found = (await api.searchSeries('batman', size: 30))['content'] as List;
    expect(found.where((s) => s['name'] == 'Batman Beyond'), hasLength(1));
  });
}
