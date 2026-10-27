// A big library browsed from the store (offline_komga.dart): each series' books were looked for by walking every
// book, series x books - a library of 1,098 series and 8,843 books took 11 s to list on the tablet (the local
// libraries' tests, 2026-10-26). Counted here: how many times a call walks the books.
import 'dart:collection';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/offline/offline_komga.dart';
import 'package:komga_reader/offline/store.dart';
import 'package:komga_reader/view_filter.dart';

/// The books, counting each walk over them.
class _Walked extends MapBase<String, Map<String, dynamic>> {
  final _m = <String, Map<String, dynamic>>{};
  var walks = 0;

  @override
  Iterable<MapEntry<String, Map<String, dynamic>>> get entries {
    walks++;
    return _m.entries;
  }

  @override
  Iterable<Map<String, dynamic>> get values {
    walks++;
    return _m.values;
  }

  @override
  Map<String, dynamic>? operator [](Object? key) => _m[key];
  @override
  void operator []=(String key, Map<String, dynamic> value) => _m[key] = value;
  @override
  void clear() => _m.clear();
  @override
  Iterable<String> get keys => _m.keys;
  @override
  Map<String, dynamic>? remove(Object? key) => _m.remove(key);
}

class _Store extends OfflineStore {
  _Store() : super(Directory.systemTemp);
  final walked = _Walked();

  @override
  Map<String, Map<String, dynamic>> get books => walked;
}

void main() {
  test('a list of series walks the books once or twice, not once per series (series, On deck, search, filtered '
      'series)',
      () async {
    final store = _Store();
    const lib = {'id': 'L1', 'name': 'COMICS'};
    for (var s = 0; s < 40; s++) {
      final series = {'id': 'S$s', 'name': 'Series $s', 'metadata': {'title': 'Series $s', 'titleSort': 'Series $s',
          'genres': ['Action']}};
      for (var n = 1; n <= 3; n++) {
        store.books['B$s-$n'] = {
          'book': {'id': 'B$s-$n', 'seriesId': 'S$s', 'name': '$n', 'metadata': {'title': '$n', 'numberSort': n},
              'media': {'pagesCount': 1}},
          'series': series, 'library': lib, 'state': 'done',
        };
      }
      // started (its first book read): On deck offers its next
      store.progress['B$s-1'] = {'page': 1, 'completed': true};
    }
    final api = OfflineKomga(store);

    store.walked.walks = 0;
    final all = await api.series(libraryId: 'L1', size: 100);
    expect((all['content'] as List).length, 40);
    expect((all['content'] as List).first['booksCount'], 3);
    expect(store.walked.walks, lessThanOrEqualTo(3), reason: 'was 41: once for the list, once per series');

    store.walked.walks = 0;
    expect(((await api.onDeck())['content'] as List).length, 30); // (a page of 30)
    expect(store.walked.walks, lessThanOrEqualTo(3));

    // (search lists them all, then matches: 12.5 s on the tablet)
    store.walked.walks = 0;
    expect(((await api.searchSeries('series 1'))['content'] as List).length, 11); // 1, 10-19
    expect(store.walked.walks, lessThanOrEqualTo(3));

    store.walked.walks = 0;
    final filtered = await api.filteredSeries(filter: const ViewFilter(genres: ['Action']), size: 100);
    expect((filtered['content'] as List).length, 40);
    expect(store.walked.walks, lessThanOrEqualTo(5));
  });

  test("the read lists, and a read list's next book: the books walked once, not once per list (the downloads' "
      'catalogue, 2026-10-26)', () async {
    final store = _Store();
    const lib = {'id': 'L1', 'name': 'COMICS'}, series = {'id': 'S1', 'name': 'Events'};
    // 30 read lists of 4 books each
    for (var r = 0; r < 30; r++) {
      for (var i = 0; i < 4; i++) {
        store.books['B$r-$i'] = {
          'book': {'id': 'B$r-$i', 'seriesId': 'S1', 'name': '$i', 'metadata': {'title': '$i', 'numberSort': r * 4 + i}},
          'series': series, 'library': lib, 'state': 'done',
          'readLists': [{'id': 'R$r', 'name': 'List $r', 'index': i, 'count': 4}],
        };
      }
    }
    final api = OfflineKomga(store);

    store.walked.walks = 0;
    final lists = (await api.readLists())['content'] as List;
    expect(lists.length, 30);
    expect(lists.first['bookIds'], ['B0-0', 'B0-1', 'B0-2', 'B0-3']);
    expect(store.walked.walks, lessThanOrEqualTo(2), reason: 'was 61: once for the lists, twice per list');

    store.walked.walks = 0;
    expect((await api.nextBook('B7-1', readListId: 'R7'))?['id'], 'B7-2');
    expect(store.walked.walks, lessThanOrEqualTo(2));
  });
}
