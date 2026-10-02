import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/offline/offline_komga.dart';
import 'package:komga_reader/offline/store.dart';
import 'package:komga_reader/screens/library.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/offline_store.dart';

List<String> ids(Map<String, dynamic> page) => [for (final b in page['content'] as List) b['id'] as String];

/// The small downloaded library of support/offline_store.dart, browsed offline.
void main() {
  late Directory dir;
  late OfflineStore store;
  late OfflineKomga api;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('komga_offline_test');
    store = await buildStore(dir);
    api = OfflineKomga(store);
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

  testWidgets('the real library screen browses the offline tree unchanged', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: LibraryScreen(api: api, onSignOut: () {}, libraryId: 'L1')));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    expect(find.text('Silver Surfer'), findsOneWidget);
    expect(find.text('Spider-Man'), findsOneWidget);
    expect(find.text('2'), findsOneWidget); // header count: 2 series downloaded
  });
}
