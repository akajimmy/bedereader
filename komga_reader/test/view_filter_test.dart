import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/hidden_libraries.dart';
import 'package:komga_reader/pins.dart';
import 'package:komga_reader/view_filter.dart';
import 'package:komga_reader/view_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The filter engine (lib/view_filter.dart, Komga's filtered listings and value lists in api.dart): what is asked of
/// Komga for each filter and combination, that an unfiltered view asks exactly what it asked before, and that the
/// filters are saved with a view and a pin.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiddenLibraries.instance.load();
  });

  const libs = [
    {'id': 'L1', 'name': 'Ongoing'},
    {'id': 'L2', 'name': 'Archive'},
    {'id': 'L3', 'name': 'Demo Library'},
  ];

  /// A Komga whose requests are recorded; answers: the libraries, an empty page for the listings, [answers] by path.
  (Komga, List<http.Request>) recorded({Map<String, Object> answers = const {}}) {
    final asked = <http.Request>[];
    final client = MockClient((r) async {
      asked.add(r);
      final path = r.url.path;
      if (path == '/api/v1/libraries') return http.Response(jsonEncode(libs), 200);
      if (answers.containsKey(path)) return http.Response(jsonEncode(answers[path]), 200);
      return http.Response(jsonEncode({'content': [], 'totalElements': 0, 'last': true}), 200);
    });
    return (Komga('http://test', 'k', client: client), asked);
  }

  Map<String, dynamic> body(http.Request r) => jsonDecode(r.body) as Map<String, dynamic>;
  Map<String, dynamic> isCond(String field, Object value) => {field: {'operator': 'is', 'value': value}};
  Map<String, dynamic> author(String name, String role) => isCond('author', {'name': name, 'role': role});

  group('conditions', () {
    test('writers: any of them, role writer', () {
      expect(const ViewFilter(writers: ['Jonathan Hickman']).conditions(seriesView: false),
          [author('Jonathan Hickman', 'writer')]);
      expect(const ViewFilter(writers: ['Jonathan Hickman', 'Al Ewing']).conditions(seriesView: false), [
        {'anyOf': [author('Jonathan Hickman', 'writer'), author('Al Ewing', 'writer')]},
      ]);
    });

    test('artists: penciller, inker or cover', () {
      expect(const ViewFilter(artists: ['Esad Ribic']).conditions(seriesView: true), [
        {'anyOf': [author('Esad Ribic', 'penciller'), author('Esad Ribic', 'inker'), author('Esad Ribic', 'cover')]},
      ]);
    });

    test('years: in or after from (after the end of the year before), in or before to', () {
      expect(const ViewFilter(fromYear: 2015, toYear: 2026).conditions(seriesView: false), [
        {'releaseDate': {'operator': 'after', 'dateTime': '2014-12-31T23:59:59Z'}},
        {'releaseDate': {'operator': 'before', 'dateTime': '2027-01-01T00:00:00Z'}},
      ]);
      expect(const ViewFilter(toYear: 1999).conditions(seriesView: false), [
        {'releaseDate': {'operator': 'before', 'dateTime': '2000-01-01T00:00:00Z'}},
      ]);
    });

    test('series filters in series views only', () {
      const f = ViewFilter(publishers: ['Marvel', 'DC'], genres: ['Horror'], statuses: ['ONGOING', 'HIATUS']);
      expect(f.conditions(seriesView: true), [
        {'anyOf': [isCond('publisher', 'Marvel'), isCond('publisher', 'DC')]},
        isCond('genre', 'Horror'),
        {'anyOf': [isCond('seriesStatus', 'ONGOING'), isCond('seriesStatus', 'HIATUS')]},
      ]);
      expect(f.conditions(seriesView: false), isEmpty);
      expect(f.forView(seriesView: false).isEmpty, isTrue);
      expect(FilterField.values.where((x) => x.appliesTo(seriesView: false)),
          [FilterField.writer, FilterField.artist, FilterField.years]);
      expect(FilterField.values.where((x) => x.appliesTo(seriesView: true)), FilterField.values);
    });
  });

  group('filtered listings', () {
    test('series: library, read filter and filters all apply (allOf), POST series/list with sort and page', () async {
      final (api, asked) = recorded();
      await api.filteredSeries(libraryId: 'L1', read: ReadFilter.hideRead, sort: 'createdDate,desc', page: 2, size: 30,
          filter: const ViewFilter(writers: ['Al Ewing'], publishers: ['Marvel']));
      final r = asked.last;
      expect('${r.method} ${r.url.path}', 'POST /api/v1/series/list');
      expect(r.url.queryParameters, {'sort': 'createdDate,desc', 'page': '2', 'size': '30'});
      expect(body(r), {
        'condition': {
          'allOf': [
            isCond('libraryId', 'L1'),
            {'anyOf': [isCond('readStatus', 'UNREAD'), isCond('readStatus', 'IN_PROGRESS')]},
            author('Al Ewing', 'writer'),
            isCond('publisher', 'Marvel'),
          ],
        },
      });
    });

    test('series across libraries with some hidden: any of the shown ones; a collection', () async {
      await HiddenLibraries.instance.setHidden('L2', true);
      final (api, asked) = recorded();
      await api.filteredSeries(filter: const ViewFilter(statuses: ['ENDED']));
      expect(body(asked.last)['condition'], {
        'allOf': [
          {'anyOf': [isCond('libraryId', 'L1'), isCond('libraryId', 'L3')]},
          isCond('seriesStatus', 'ENDED'),
        ],
      });
      await api.filteredSeries(collectionId: 'C1', filter: const ViewFilter(genres: ['Horror']));
      expect(body(asked.last)['condition'], {
        'allOf': [
          {'anyOf': [isCond('libraryId', 'L1'), isCond('libraryId', 'L3')]},
          isCond('collectionId', 'C1'),
          isCond('genre', 'Horror'),
        ],
      });
    });

    test('books: series / read list / library scope; series filters left out', () async {
      final (api, asked) = recorded();
      const f = ViewFilter(fromYear: 2020, publishers: ['Marvel']);
      final year = {'releaseDate': {'operator': 'after', 'dateTime': '2019-12-31T23:59:59Z'}};

      await api.filteredBooks(seriesId: 'S1', filter: f);
      expect('${asked.last.method} ${asked.last.url.path}', 'POST /api/v1/books/list');
      expect(asked.last.url.queryParameters['sort'], 'metadata.numberSort,asc');
      expect(body(asked.last)['condition'], {'allOf': [isCond('seriesId', 'S1'), year]});

      await api.filteredBooks(readListId: 'RL1', read: ReadFilter.hideUnread, filter: f);
      expect(asked.last.url.queryParameters['sort'], 'readList.number,asc');
      expect(body(asked.last)['condition'], {'allOf': [isCond('readListId', 'RL1'), isCond('readStatus', 'READ'), year]});

      await api.filteredBooks(libraryId: 'L3', filter: f, sort: 'metadata.title,asc');
      expect(asked.last.url.queryParameters['sort'], 'metadata.title,asc');
      expect(body(asked.last)['condition'], {'allOf': [isCond('libraryId', 'L3'), year]});

      await api.filteredBooks(filter: f); // all libraries, none hidden: no library condition
      expect(body(asked.last)['condition'], year);
    });

    test('no filter: the same GET requests as before filters existed', () async {
      final (api, asked) = recorded();
      Future<String> request(Future<void> Function(Komga a) call) async {
        await call(api);
        return '${asked.last.method} ${asked.last.url}';
      }

      const seriesOnly = ViewFilter(publishers: ['Marvel']); // doesn't apply to books: no filter there
      expect(await request((a) => a.filteredSeries(libraryId: 'L1', read: ReadFilter.hideRead)),
          await request((a) => a.series(libraryId: 'L1', readStatus: ReadFilter.hideRead.api)));
      expect(await request((a) => a.filteredSeries(collectionId: 'C1', sort: 'createdDate,desc')),
          await request((a) => a.series(collectionId: 'C1', sort: 'createdDate,desc')));
      expect(await request((a) => a.filteredBooks(libraryId: 'L1', filter: seriesOnly)),
          await request((a) => a.books(libraryId: 'L1')));
      expect(await request((a) => a.filteredBooks(seriesId: 'S1', read: ReadFilter.hideUnread, filter: seriesOnly)),
          await request((a) => a.seriesBooks('S1', readStatus: const ['READ'])));
      expect(await request((a) => a.filteredBooks(readListId: 'RL1')), await request((a) => a.readListBooks('RL1')));
      expect(asked.where((r) => r.method != 'GET'), isEmpty);
    });
  });

  group('value lists', () {
    test('authors: one request per role, scoped, names merged A -> Z', () async {
      final (api, asked) = recorded(answers: {
        '/api/v2/authors': {
          'content': [
            {'name': 'Esad Ribic', 'role': 'penciller'},
            {'name': 'adam hughes', 'role': 'cover'},
          ],
        },
      });
      expect(await api.authorNames(artistRoles, collectionId: 'C1', search: 'a'), ['adam hughes', 'Esad Ribic']);
      expect([for (final r in asked) r.url.queryParameters['role']], artistRoles);
      expect(asked.last.url.queryParameters, containsPair('collection_id', 'C1'));
      expect(asked.last.url.queryParameters, containsPair('search', 'a'));

      await api.authorNames(writerRoles, readListId: 'RL1');
      expect(asked.last.url.queryParameters, containsPair('readlist_id', 'RL1'));
      await api.authorNames(writerRoles, seriesId: 'S1');
      expect(asked.last.url.queryParameters, containsPair('series_id', 'S1'));
      await HiddenLibraries.instance.setHidden('L2', true);
      await api.authorNames(writerRoles);
      expect(asked.last.url.queryParametersAll['library_id'], ['L1', 'L3']);
    });

    test('publishers, genres', () async {
      final (api, asked) = recorded(answers: {
        '/api/v1/publishers': ['Marvel', 'DC', 'boom'],
        '/api/v1/genres': ['Horror'],
      });
      expect(await api.publishers(libraryId: 'L1'), ['boom', 'DC', 'Marvel']);
      expect(asked.last.url.queryParametersAll['library_id'], ['L1']);
      expect(await api.genres(collectionId: 'C1'), ['Horror']);
      expect(asked.last.url.queryParameters, {'collection_id': 'C1'});
    });
  });

  group('saved', () {
    const f = ViewFilter(writers: ['Jonathan Hickman', 'Al Ewing'], artists: ['Esad Ribic'], fromYear: 2015,
        toYear: 2026, publishers: ['Marvel'], genres: ['Horror'], statuses: ['ONGOING']);

    test('JSON round trip; equality ignores the order values were picked in', () {
      expect(ViewFilter.fromJson(jsonDecode(jsonEncode(f.toJson()))), f);
      expect(ViewFilter.fromJson(null), ViewFilter.none);
      expect(ViewFilter.fromJson('junk').isEmpty, isTrue);
      expect(ViewFilter.none.toJson(), isEmpty);
      expect(const ViewFilter(writers: ['A', 'B']), const ViewFilter(writers: ['B', 'A']));
      expect(const ViewFilter(writers: ['A', 'B']).hashCode, const ViewFilter(writers: ['B', 'A']).hashCode);
      expect(const ViewFilter(writers: ['A']) == const ViewFilter(artists: ['A']), isFalse);
      expect(const ViewFilter(fromYear: 2015) == const ViewFilter(toYear: 2015), isFalse);
      expect(f.copyWith(years: (null, null)).fromYear, isNull);
      expect(f.copyWith(genres: []).genres, isEmpty);
      expect(f.summary(), hasLength(6)); // one line per filter set
    });

    test('a view keeps its filters next to the rest of what it saved', () async {
      await ViewPrefs.save('view.series.S1', {'filter': 'hideRead', 'newestFirst': true});
      await ViewPrefs.saveFilters('view.series.S1', f);
      expect(await ViewPrefs.loadFilters('view.series.S1'), f);
      expect(await ViewPrefs.load('view.series.S1'), containsPair('filter', 'hideRead'));
      await ViewPrefs.saveFilters('view.series.S1', ViewFilter.none);
      expect((await ViewPrefs.load('view.series.S1')).containsKey(ViewPrefs.filtersKey), isFalse);
      expect(ViewPrefs.filtersOf(ViewPrefs.withFilters({'mode': 'books'}, f)), f);
    });

    test('a pin keeps its filters, renamed too; they are part of which view it is', () {
      const pin = Pin(name: 'Hickman', kind: 'library', id: 'L1', title: 'Ongoing', mode: 'series', filters: f);
      final back = Pin.fromJson(jsonDecode(jsonEncode(pin.toJson())) as Map<String, dynamic>);
      expect(back.filters, f);
      expect(back.sameView(pin), isTrue);
      expect(pin.renamed('Other').filters, f);
      const unfiltered = Pin(name: 'Hickman', kind: 'library', id: 'L1', title: 'Ongoing', mode: 'series');
      expect(unfiltered.sameView(pin), isFalse);
      expect(unfiltered.toJson().containsKey('filters'), isFalse); // pins without filters saved as before
      expect(Pin.fromJson(unfiltered.toJson()).filters, ViewFilter.none);
    });
  });
}
