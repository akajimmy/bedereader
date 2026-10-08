import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/offline/offline_komga.dart';
import 'package:komga_reader/offline/store.dart';
import 'package:komga_reader/view_filter.dart';

import 'support/helpers.dart';
import 'support/offline_store.dart';

List<String> ids(Map<String, dynamic> page) => [for (final b in page['content'] as List) b['id'] as String];

/// The filters on downloaded books (offline_komga.dart): the store keeps Komga's book and series JSON, and the
/// filtered views and the panel's value lists are made from it.
void main() {
  late Directory dir;
  late OfflineStore store;
  late OfflineKomga api;

  /// support/offline_store.dart's library, with metadata:
  ///   Silver Surfer (S1, Marvel, Cosmic + Action, ENDED, released 2014): B1 2014 Slott (writer) / Allred (penciller),
  ///     B2 2015 Slott / Allred (cover), B5 2016 Slott / Ribic (inker)
  ///   Spider-Man (S2, Marvel Knights, Action, ONGOING, released 2020): B3 2020 Hickman (writer) / Ribic (penciller)
  Future<void> addMetadata() async {
    Future<void> book(String id, String date, List<Map<String, String>> authors) async {
      final e = Map<String, dynamic>.from(store.books[id]!);
      final b = Map<String, dynamic>.from(e['book'] as Map);
      b['metadata'] = {...(b['metadata'] as Map), 'releaseDate': date, 'authors': authors};
      e['book'] = b;
      e['series'] = series[b['seriesId']];
      await store.put(id, e);
    }

    await book('B1', '2014-05-01', [{'name': 'Dan Slott', 'role': 'writer'}, {'name': 'Mike Allred', 'role': 'penciller'}]);
    await book('B2', '2015-01-01', [{'name': 'Dan Slott', 'role': 'writer'}, {'name': 'Mike Allred', 'role': 'cover'}]);
    await book('B5', '2016-12-31', [{'name': 'Dan Slott', 'role': 'writer'}, {'name': 'Esad Ribic', 'role': 'inker'}]);
    await book('B3', '2020-02-02', [{'name': 'Jonathan Hickman', 'role': 'writer'}, {'name': 'Esad Ribic', 'role': 'penciller'}]);
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('komga_offline_filter_test');
    store = await buildStore(dir);
    await addMetadata();
    api = OfflineKomga(store);
  });
  tearDown(() => deleteTemp(dir));

  test('books: writer, artist (any of penciller / inker / cover), years; series filters ignored', () async {
    Future<List<String>> books(ViewFilter f, {String? seriesId, String? readListId}) async => ids(await api
        .filteredBooks(seriesId: seriesId, readListId: readListId, filter: f, sort: seriesId == null && readListId == null
            ? 'metadata.title,asc' : null));
    expect(await books(const ViewFilter(writers: ['Jonathan Hickman'])), ['B3']);
    expect(await books(const ViewFilter(writers: ['Jonathan Hickman', 'Dan Slott'])), ['B1', 'B2', 'B3', 'B5']);
    expect(await books(const ViewFilter(artists: ['Esad Ribic'])), ['B3', 'B5']); // penciller, inker
    expect(await books(const ViewFilter(artists: ['Mike Allred'])), ['B1', 'B2']); // penciller, cover
    expect(await books(const ViewFilter(writers: ['Mike Allred'])), isEmpty); // not a writer
    expect(await books(const ViewFilter(fromYear: 2015, toYear: 2016)), ['B2', 'B5']); // whole years, both ends
    expect(await books(const ViewFilter(toYear: 2015)), ['B1', 'B2']);
    expect(await books(const ViewFilter(writers: ['Dan Slott'], artists: ['Esad Ribic'])), ['B5']); // all apply
    expect(await books(const ViewFilter(publishers: ['Nobody'])), ['B1', 'B2', 'B3', 'B5']); // a series filter
    expect(await books(const ViewFilter(fromYear: 2015), seriesId: 'S1'), ['B2', 'B5']); // in number order
    expect(await books(const ViewFilter(artists: ['Esad Ribic']), readListId: 'RL1'), ['B3']); // list order
  });

  test('series: publisher, genre, status, authors of its books, its release year', () async {
    Future<List<String>> series(ViewFilter f, {String? collectionId}) async =>
        ids(await api.filteredSeries(collectionId: collectionId, filter: f));
    expect(await series(const ViewFilter(publishers: ['marvel'])), ['S1']); // case aside
    expect(await series(const ViewFilter(publishers: ['Marvel', 'Marvel Knights'])), ['S1', 'S2']);
    expect(await series(const ViewFilter(genres: ['Cosmic'])), ['S1']);
    expect(await series(const ViewFilter(genres: ['Action'])), ['S1', 'S2']);
    expect(await series(const ViewFilter(statuses: ['ONGOING'])), ['S2']);
    expect(await series(const ViewFilter(artists: ['Esad Ribic'])), ['S1', 'S2']);
    expect(await series(const ViewFilter(writers: ['Jonathan Hickman'])), ['S2']);
    expect(await series(const ViewFilter(fromYear: 2015)), ['S2']); // S1 released 2014
    expect(await series(const ViewFilter(statuses: ['ONGOING']), collectionId: 'C1'), isEmpty);
    expect(ids(await api.filteredSeries(read: ReadFilter.hideUnread, filter: const ViewFilter(genres: ['Action']))),
        isEmpty); // nothing all read
  });

  test('value lists from the downloads, scoped', () async {
    expect(await api.authorNames(writerRoles), ['Dan Slott', 'Jonathan Hickman']);
    expect(await api.authorNames(artistRoles, seriesId: 'S2'), ['Esad Ribic']);
    expect(await api.authorNames(artistRoles, collectionId: 'C1', search: 'all'), ['Mike Allred']);
    expect(await api.authorNames(writerRoles, readListId: 'RL1'), ['Dan Slott', 'Jonathan Hickman']);
    expect(await api.publishers(), ['Marvel', 'Marvel Knights']);
    expect(await api.publishers(collectionId: 'C1'), ['Marvel']);
    expect(await api.genres(libraryId: 'L1'), ['Action', 'Cosmic']);
  });
}

/// Komga's series JSON, as a download stores it.
const series = {
  'S1': {
    'id': 'S1', 'name': 'Silver Surfer',
    'metadata': {'title': 'Silver Surfer', 'titleSort': 'Silver Surfer', 'publisher': 'Marvel',
        'genres': ['Cosmic', 'Action'], 'status': 'ENDED'},
    'booksMetadata': {'releaseDate': '2014-05-01', 'authors': []},
  },
  'S2': {
    'id': 'S2', 'name': 'Spider-Man',
    'metadata': {'title': 'Spider-Man', 'titleSort': 'Spider-Man', 'publisher': 'Marvel Knights', 'genres': ['Action'],
        'status': 'ONGOING'},
    'booksMetadata': {'releaseDate': '2020-02-02', 'authors': []},
  },
};
