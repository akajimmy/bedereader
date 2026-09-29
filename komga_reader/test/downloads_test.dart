import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/offline/downloads.dart';
import 'package:komga_reader/offline/offline_komga.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A server with two books of 3 pages (100 bytes each) in series S1, library L1, read list RL1, collection C1.
class FakeKomga extends Komga {
  FakeKomga() : super('http://test', 'k');
  int pageRequests = 0;
  bool slow = false;
  void Function(int number)? onPage; // called after serving a page (tests use it to pause at an exact point)

  Map<String, dynamic> _book(String id, int n) => {
        'id': id, 'seriesId': 'S1', 'seriesTitle': 'Silver Surfer', 'libraryId': 'L1', 'name': id,
        'metadata': {'title': 'T$id', 'number': '$n', 'numberSort': n}, 'media': {'pagesCount': 3}, 'sizeBytes': 300,
        'readProgress': id == 'B1' ? {'page': 2, 'completed': false} : null,
      };

  @override
  Future<Map<String, dynamic>?> book(String id) async => _book(id, id == 'B1' ? 1 : 2);
  @override
  Future<List<dynamic>> pages(String bookId) async =>
      [for (var n = 1; n <= 3; n++) {'number': n, 'mediaType': 'image/jpeg', 'sizeBytes': 100}];
  @override
  Future<Uint8List> pageBytes(String bookId, int number) async {
    pageRequests++;
    if (slow) await Future<void>.delayed(const Duration(milliseconds: 20));
    onPage?.call(number);
    return Uint8List(100);
  }

  @override
  Future<Map<String, dynamic>?> oneSeries(String id) async => {'id': id, 'name': 'Silver Surfer', 'metadata': {'title': 'Silver Surfer'}};
  @override
  Future<List<dynamic>> libraries() async => [{'id': 'L1', 'name': 'Archive'}];
  @override
  Future<List<dynamic>> bookReadLists(String bookId) async => [{'id': 'RL1', 'name': 'Cosmic', 'bookIds': ['B0', bookId]}];
  @override
  Future<List<dynamic>> seriesCollections(String seriesId) async => [{'id': 'C1', 'name': 'Marvel cosmic'}];
  @override
  Future<Uint8List?> thumbBytes(String url) async => Uint8List(10);
  @override
  Future<Map<String, dynamic>?> nextBook(String bookId, {String? readListId}) async =>
      bookId == 'B1' ? _book('B2', 2) : null; // B2 is the series' last

  /// Reachability check: answers while [up], else "can't reach" - reported like every real server call.
  bool up = true;
  @override
  Future<Map<String, dynamic>?> me() async {
    Komga.onReachability?.call(this, up);
    if (!up) throw KomgaUnreachable(baseUrl);
    return {'id': 'U1'};
  }
}

Map<String, dynamic> book(String id, int n) =>
    {'id': id, 'seriesTitle': 'Silver Surfer', 'metadata': {'number': '$n'}};

Future<void> settle(Downloads d) async {
  for (var i = 0; i < 200 && d.queue.any((j) => j.state == JobState.queued || j.state == JobState.downloading); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late Directory dir;
  final d = Downloads.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('komga_downloads_test');
  });
  tearDown(() async {
    // stop the worker before deleting its folder (it may still be writing a page)
    d.pauseAll();
    for (var i = 0; i < 300 && d.busy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    d.paused = false;
    await dir.delete(recursive: true);
  });

  test('a queued book downloads page by page, with its place in the tree, and shows up offline', () async {
    final api = FakeKomga();
    await d.attach(api, root: dir);
    expect(await d.add([book('B1', 1)]), 1);
    await settle(d);
    expect(d.queue, isEmpty);
    expect(d.isDownloaded('B1'), isTrue);
    expect(d.usedBytes, 300);
    for (var n = 1; n <= 3; n++) {
      expect(await d.store!.file('B1/pages/000$n.jpg').length(), 100);
    }
    expect(await d.store!.file('B1/thumb.jpg').exists(), isTrue);
    expect(await d.store!.file('series/S1.jpg').exists(), isTrue);
    expect(await d.store!.file('readlists/RL1.jpg').exists(), isTrue);

    final offline = OfflineKomga(d.store!);
    expect((await offline.libraries()).single['name'], 'Archive');
    expect(((await offline.readListBooks('RL1'))['content'] as List).single['id'], 'B1');
    expect(((await offline.collections())['content'] as List).single['name'], 'Marvel cosmic');
    expect(offline.store.readProgressOf('B1')!['page'], 2); // the server's progress came along
    expect(d.recentlyDone.first, 'Silver Surfer #1');
    // what comes next is recorded, so offline can say "the next book isn't downloaded" instead of skipping ahead
    expect(d.store!.books['B1']!['nextId'], 'B2');
    expect(((d.store!.books['B1']!['readLists'] as List).single as Map)['count'], 2);
    expect(() => offline.nextBook('B1'), throwsA(isA<NotAvailableOffline>())); // B2 not downloaded
  });

  test('queuing the same book twice, or one already downloaded, does nothing', () async {
    await d.attach(FakeKomga(), root: dir);
    await d.add([book('B1', 1)]);
    await settle(d);
    expect(await d.add([book('B1', 1), book('B1', 1)]), 0);
  });

  test('the size limit stops a book that would not fit, with a clear reason', () async {
    await d.attach(FakeKomga(), root: dir);
    await d.setCap(500); // bytes
    await d.add([book('B1', 1), book('B2', 2)]);
    await settle(d);
    expect(d.isDownloaded('B1'), isTrue);
    final failed = d.jobFor('B2')!;
    expect(failed.state, JobState.failed);
    expect(failed.error, contains('not enough room'));
    await d.setCap(null); // no limit: the book carries on by itself
    await settle(d);
    expect(d.isDownloaded('B2'), isTrue);
  });

  test('cancel removes a queued book; remove deletes a download but keeps progress not yet sent', () async {
    await d.attach(FakeKomga(), root: dir);
    d.pauseAll();
    await d.add([book('B1', 1)]);
    await d.cancel('B1');
    expect(d.queue, isEmpty);
    d.resumeAll();

    await d.add([book('B2', 2)]);
    await settle(d);
    await d.store!.setProgress('B2', page: 2, completed: false); // read offline, not synced yet
    await d.remove('B2');
    expect(d.isDownloaded('B2'), isFalse);
    expect(await Directory(d.store!.file('B2').path).exists(), isFalse);
    expect(d.store!.progress['B2']!['synced'], false);
  });

  test('the queue survives a restart, and pages already on disk are not fetched again', () async {
    // pause exactly after page 1 (deterministic, whatever the machine's speed)
    final api = FakeKomga()..onPage = (n) { if (n == 1) d.pauseAll(); };
    await d.attach(api, root: dir);
    await d.add([book('B1', 1)]);
    for (var i = 0; i < 300 && (d.jobFor('B1')?.state != JobState.paused || d.busy); i++) { // paused and saved
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final fetchedBefore = api.pageRequests;
    expect(fetchedBefore, 1);

    d.paused = false;
    final again = FakeKomga();
    await d.attach(again, root: dir); // "next launch"
    expect(d.jobFor('B1'), isNotNull);
    d.resumeAll();
    await settle(d);
    expect(d.isDownloaded('B1'), isTrue);
    expect(again.pageRequests, 3 - fetchedBefore); // only the missing pages
  });

  test('cancel all empties the queue (the downloading book stops and is cleaned up); finished downloads stay', () async {
    final api = FakeKomga();
    await d.attach(api, root: dir);
    await d.add([book('B1', 1)]);
    await settle(d);
    expect(d.isDownloaded('B1'), isTrue);

    api.onPage = (n) {}; // B2 downloading while we cancel
    api.slow = true;
    await d.add([book('B2', 2), book('B3', 3)]);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await d.cancelAll();
    for (var i = 0; i < 300 && (d.busy || d.queue.isNotEmpty); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(d.queue, isEmpty);
    expect(d.isDownloaded('B1'), isTrue); // finished download untouched
    expect(d.store!.books.containsKey('B2'), isFalse); // partial download cleaned up
    expect(await Directory(d.store!.file('B2').path).exists(), isFalse);
  });
}

