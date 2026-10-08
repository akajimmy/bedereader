// The requests behind the new sorts (top bar, 2026-10-08), online and offline.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/offline/offline_komga.dart';
import 'package:komga_reader/offline/store.dart';

import 'support/helpers.dart';

void main() {
  group('online', () {
    late List<http.Request> sent;
    Komga komga() => Komga('http://komga', 'k', client: MockClient((r) async {
          sent.add(r);
          return http.Response(jsonEncode({'content': [], 'totalElements': 0, 'last': true}), 200,
              headers: {'content-type': 'application/json'});
        }));
    setUp(() => sent = []);

    test("a collection's series in its own order: Komga's collection endpoint, with the read filter", () async {
      await komga().collectionSeries('C1', readStatus: const ['UNREAD', 'IN_PROGRESS'], page: 2, size: 30);
      final r = sent.single;
      expect((r.method, r.url.path), ('GET', '/api/v1/collections/C1/series'));
      expect(r.url.queryParametersAll, {'read_status': ['UNREAD', 'IN_PROGRESS'], 'page': ['2'], 'size': ['30']});
    });

    test("a read list's books by release date: Komga's book search with the list (and the read filter)", () async {
      await komga().readListBooksSorted('RL1', 'metadata.releaseDate,desc', readStatus: const ['READ'], page: 1,
          size: 50);
      final r = sent.single;
      expect((r.method, r.url.path), ('POST', '/api/v1/books/list'));
      expect(r.url.queryParameters, {'page': '1', 'size': '50', 'sort': 'metadata.releaseDate,desc'});
      expect(jsonDecode(r.body), {
        'condition': {
          'allOf': [
            {'readListId': {'operator': 'is', 'value': 'RL1'}},
            {'anyOf': [{'readStatus': {'operator': 'is', 'value': 'READ'}}]},
          ],
        },
      });

      sent.clear(); // no read filter: the list alone
      await komga().readListBooksSorted('RL1', 'metadata.releaseDate,asc');
      expect(jsonDecode(sent.single.body), {
        'condition': {'allOf': [{'readListId': {'operator': 'is', 'value': 'RL1'}}]},
      });
    });
  });

  group('offline', () {
    late Directory dir;
    late OfflineKomga api;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('komga_view_sort_test');
      final store = OfflineStore(dir);
      Map<String, dynamic> s(String id, String title, String release) => {
            'id': id, 'name': title, 'metadata': {'title': title, 'titleSort': title},
            'booksMetadata': {'releaseDate': release},
          };
      Future<void> put(String id, Map<String, dynamic> series, String release, int index, {Map? rp}) => store.put(id, {
            'book': {'id': id, 'seriesId': series['id'], 'name': id,
                'metadata': {'title': id, 'numberSort': 1, 'releaseDate': release}, 'readProgress': rp},
            'series': series, 'library': {'id': 'L1', 'name': 'Events'},
            'readLists': [{'id': 'RL1', 'name': 'Event', 'index': index}],
            'collections': [{'id': 'C1', 'name': 'Cosmic'}],
            'pages': [], 'bytes': 0, 'state': 'done',
          });
      await put('B1', s('S1', 'Alpha', '2001-01-01'), '2020-05-01', 0);
      await put('B2', s('S2', 'Beta', '1999-01-01'), '2010-05-01', 1, rp: {'page': 2, 'completed': true});
      await put('B3', s('S3', 'Gamma', '2005-01-01'), '2015-05-01', 2);
      api = OfflineKomga(store);
    });
    tearDown(() => deleteTemp(dir));

    List ids(Map<String, dynamic> page) => [for (final x in page['content'] as List) x['id']];

    test("a read list's downloaded books by release date, either way, with the read filter", () async {
      expect(ids(await api.readListBooksSorted('RL1', 'metadata.releaseDate,asc')), ['B2', 'B3', 'B1']);
      expect(ids(await api.readListBooksSorted('RL1', 'metadata.releaseDate,desc')), ['B1', 'B3', 'B2']);
      expect(ids(await api.readListBooksSorted('RL1', 'metadata.releaseDate,desc', readStatus: const ['UNREAD'])),
          ['B1', 'B3']);
    });

    test("a collection's downloaded series: by release date, and in its own order (by title: not kept offline)",
        () async {
      expect(ids(await api.series(collectionId: 'C1', sort: 'booksMetadata.releaseDate,desc')), ['S3', 'S1', 'S2']);
      expect(ids(await api.collectionSeries('C1')), ['S1', 'S2', 'S3']);
    });
  });
}
