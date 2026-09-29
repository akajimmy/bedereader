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
    d.pauseAll();
    await Future<void>.delayed(const Duration(milliseconds: 50));
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
    final api = FakeKomga()..slow = true;
    await d.attach(api, root: dir);
    await d.add([book('B1', 1)]);
    await Future<void>.delayed(const Duration(milliseconds: 30)); // part-way through
    d.pauseAll();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final fetchedBefore = api.pageRequests;
    expect(fetchedBefore, inInclusiveRange(1, 2));

    d.paused = false;
    final again = FakeKomga();
    await d.attach(again, root: dir); // "next launch"
    expect(d.jobFor('B1'), isNotNull);
    d.resumeAll();
    await settle(d);
    expect(d.isDownloaded('B1'), isTrue);
    expect(again.pageRequests, 3 - fetchedBefore); // only the missing pages
  });
}
