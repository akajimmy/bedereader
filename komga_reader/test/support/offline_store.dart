import 'dart:io';

import 'package:komga_reader/offline/store.dart';

/// A small downloaded library, written to [dir]:
///   Events (L1)
///     Silver Surfer (S1): #1 B1 read, #2 B2 in progress (page 3), #3 B5 unread   - in collection C1
///     Spider-Man (S2):    #1 B3 unread
///   read list "Event" (RL1): B3 at position 2, B2 at position 5
///
/// Was offline_test's, imported from there by offline_pins_test and search_test (test audit, 2026-09-30).
Future<OfflineStore> buildStore(Directory dir) async {
  final store = OfflineStore(dir);
  const lib = {'id': 'L1', 'name': 'Events'};
  const s1 = {'id': 'S1', 'name': 'Silver Surfer', 'metadata': {'title': 'Silver Surfer', 'titleSort': 'Silver Surfer'}};
  const s2 = {'id': 'S2', 'name': 'Spider-Man', 'metadata': {'title': 'Spider-Man', 'titleSort': 'Spider-Man'}};
  Map<String, dynamic> book(String id, Map series, num n, {Map? rp}) => {
        'id': id, 'seriesId': series['id'], 'seriesTitle': series['name'], 'name': id,
        'metadata': {'title': 'Title $id', 'number': '$n', 'numberSort': n},
        'media': {'pagesCount': 2}, 'readProgress': rp,
      };
  Map<String, dynamic> entry(Map<String, dynamic> b, Map series, {List readLists = const [], List collections = const []}) => {
        'book': b, 'series': series, 'library': lib, 'readLists': readLists, 'collections': collections,
        'pages': [
          {'number': 1, 'file': 'pages/0001.jpg', 'mediaType': 'image/jpeg'},
          {'number': 2, 'file': 'pages/0002.jpg', 'mediaType': 'image/jpeg'},
        ],
        'bytes': 6, 'state': 'done',
      };
  const c1 = [{'id': 'C1', 'name': 'Cosmic'}];
  await store.put('B1', entry(book('B1', s1, 1, rp: {'page': 2, 'completed': true}), s1, collections: c1));
  await store.put('B2', entry(book('B2', s1, 2, rp: {'page': 3, 'completed': false}), s1,
      collections: c1, readLists: [{'id': 'RL1', 'name': 'Event', 'index': 5}]));
  await store.put('B5', entry(book('B5', s1, 3), s1, collections: c1));
  await store.put('B3', entry(book('B3', s2, 1), s2, readLists: [{'id': 'RL1', 'name': 'Event', 'index': 2}]));
  await store.file('B1/pages/0002.jpg').create(recursive: true);
  await store.file('B1/pages/0002.jpg').writeAsBytes([1, 2, 3]);
  return store;
}
