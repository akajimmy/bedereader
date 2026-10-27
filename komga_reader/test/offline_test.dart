// offline (test audit, 2026-10-23: offline_filter_test.dart folded in).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/offline/downloads_source.dart';
import 'package:komga_reader/offline/store.dart';
import 'package:komga_reader/screens/library.dart';
import 'package:komga_reader/view_filter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/offline_store.dart';

List<String> ids(Map<String, dynamic> page) => [for (final b in page['content'] as List) b['id'] as String];

// The small downloaded library of support/offline_store.dart, browsed offline.

// ---- from offline_filter_test.dart

// The filters on downloaded books (downloads_source.dart): the store keeps Komga's book and series JSON, and the
// filtered views and the panel's value lists are made from it.

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

void main() {
  late Directory dir;
  late OfflineStore store;
  late DownloadsSource api;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('komga_offline_test');
    store = await buildStore(dir);
    api = DownloadsSource(store);
  });
  tearDown(() => deleteTemp(dir));

  test('libraries and series show only what is downloaded, with counts for the downloaded books', () async {
    expect((await api.libraries()).map((l) => l['name']), ['Events']);
    final series = (await api.series(libraryId: 'L1'))['content'] as List;
    expect(series.map((s) => s['name']), ['Silver Surfer', 'Spider-Man']);
    final s1 = series.first;
    expect([s1['booksCount'], s1['booksReadCount'], s1['booksInProgressCount'], s1['booksUnreadCount']], [3, 1, 1, 1]);
  });

  test('filters behave like Komga: hide read, collections', () async {
    const hideRead = ['UNREAD', 'IN_PROGRESS'];
    expect(ids(await api.series(readStatus: hideRead)), ['S1', 'S2']);
    await api.markSeriesRead('S1');
    expect(ids(await api.series(readStatus: hideRead)), ['S2']); // every downloaded S1 book read now
    expect(ids(await api.series(collectionId: 'C1')), ['S1']);
    expect(ids(await api.books(readStatus: hideRead, sort: 'metadata.title,asc')), ['B3']);
  });

  test('series books sort by number; read lists keep their own order', () async {
    expect(ids(await api.seriesBooks('S1', sort: 'metadata.numberSort,desc')), ['B5', 'B2', 'B1']);
    expect(ids(await api.readListBooks('RL1')), ['B3', 'B2']);
    final rl = (await api.readLists())['content'] as List;
    expect(rl.single['bookIds'], ['B3', 'B2']);
    expect(((await api.collections())['content'] as List).single['seriesIds'], ['S1']);
  });

  test('continue reading and on deck come from local progress', () async {
    expect(ids(await api.inProgress()), ['B2']);
    expect(ids(await api.onDeck()), isEmpty); // S1 has a book in progress
    await api.markRead('B2');
    expect(ids(await api.onDeck()), ['B5']); // next unread after the read ones
  });

  test('pages and posters come from disk', () async {
    expect((await api.pages('B1')).map((p) => p['number']), [1, 2]);
    expect(await api.pageBytes('B1', 2), Uint8List.fromList([1, 2, 3]));
    final thumb = api.thumbImage(api.bookThumb('B1'));
    expect(thumb, isA<FileImage>());
    expect((thumb as FileImage).file.path, endsWith('thumb.jpg'));
  });

  test('progress made offline is queued (unsynced) and survives a restart', () async {
    await api.setProgress('B3', 1);
    expect(store.progress['B3']!['synced'], false);
    final reopened = OfflineStore(dir);
    await reopened.load();
    expect(reopened.readProgressOf('B3')!['page'], 1);
    expect(reopened.progress['B1']!['synced'], true); // untouched downloads keep the server's progress
  });

  test('next / previous follow the read list it was opened from, else the series', () async {
    expect((await api.nextBook('B1'))!['id'], 'B2');
    expect(await api.nextBook('B2', readListId: 'RL1'), isNull);
    expect((await api.previousBook('B2', readListId: 'RL1'))!['id'], 'B3');
  });

  test("next book offline: never skips ahead - a next book that isn't downloaded says so", () async {
    Future<void> set(String id, Map<String, dynamic> changes) => store.put(id, {...store.books[id]!, ...changes});
    // series, recorded at download time: B1 -> B2 (downloaded), B5 -> B9 (not), B2 last
    await set('B1', {'nextId': 'B2'});
    await set('B5', {'nextId': 'B9'});
    await set('B2', {'nextId': null});
    expect((await api.nextBook('B1'))!['id'], 'B2');
    expect(() => api.nextBook('B5'), throwsA(isA<NotAvailableOffline>()));
    expect(await api.nextBook('B2'), isNull); // end of the series
    // read list RL1: B3 at 2, B2 at 5 - positions 3 and 4 aren't downloaded
    expect(() => api.nextBook('B3', readListId: 'RL1'), throwsA(isA<NotAvailableOffline>())); // not B2
    await set('B2', {'readLists': [{'id': 'RL1', 'name': 'Event', 'index': 5, 'count': 6}]});
    expect(await api.nextBook('B2', readListId: 'RL1'), isNull); // the list's last book
    await set('B2', {'readLists': [{'id': 'RL1', 'name': 'Event', 'index': 5, 'count': 9}]});
    expect(() => api.nextBook('B2', readListId: 'RL1'), throwsA(isA<NotAvailableOffline>()));
  });

  test('server-only actions refuse clearly; settings sync waits for the connection', () async {
    expect(() => api.deleteBookFile('B1'), throwsA(isA<NotAvailableOffline>()));
    expect(() => api.clientSettings(), throwsA(isA<KomgaUnreachable>()));
  });

  // the downloads answer these themselves since they stopped being a Komga that can't connect (2026-10-26): what only
  // the server has is "unreachable" as before - the EPUB reader, the sync and the download engine tell by it
  test("what only the server has is unreachable, as it was; the library list's own questions answered", () async {
    for (final call in <Future<Object?> Function()>[
      () => api.epubManifest('B1'), () => api.epubResource('B1', 'x.html'), () => api.bookFileBytes('B1'),
      () => api.thumbBytes('http://nas/thumb'), () => api.bookReadLists('B1'), () => api.seriesCollections('S1'),
      () => api.putClientSetting('k', 'v'),
    ]) {
      await expectLater(call(), throwsA(isA<KomgaUnreachable>()));
    }
    expect(await api.libraryName('L1'), 'Events');
    expect(await api.libraryName('nope'), isNull);
    expect([for (final l in await api.visibleLibraries()) l['id']], ['L1']);
    expect(await api.me(), {'email': 'offline'});
  });

  testWidgets('the real library screen browses the offline tree unchanged', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(
        () => tester.pumpWidget(MaterialApp(home: LibraryScreen(api: api, onSignOut: () {}, libraryId: 'L1'))));
    await waitUntil(() => shows(find.text('Spider-Man')), tester: tester, reason: 'the series loaded');
    expect(find.text('Silver Surfer'), findsOneWidget);
    expect(find.text('Spider-Man'), findsOneWidget);
    expect(find.text('2'), findsOneWidget); // header count: 2 series downloaded
  }, tags: 'slow');

  group('offline filter', () {
    late Directory dir;
    late OfflineStore store;
    late DownloadsSource api;

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
      api = DownloadsSource(store);
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
  });
}
