// The cache (user, 2026-10-24): "When I open a book, assuming it's not already downloaded, the app should, in addition
// to immediately opening the book, start downloading it in the background. The app should maintain a specific amount
// of hard drive space maximum for cached issues. And a book that is finished reading should immediately delete the
// cache. Aside from that, when maximum size is reached, delete the oldest cache book. ... 512 megabytes".
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/offline/downloads.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/library_server.dart';
import 'support/no_network.dart';
import 'support/settle.dart';

Map<String, dynamic> book(String id) => {'id': id, 'seriesTitle': 'Silver Surfer', 'metadata': {'number': '1'}};

void main() {
  late Directory dir;
  final d = Downloads.instance;
  var now = DateTime(2026, 10, 24, 18);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    d.reset();
    dir = await Directory.systemTemp.createTemp('komga_cache_test');
    await d.attach(noNetwork(LibraryServer.new), root: dir);
  });
  tearDown(() async {
    Downloads.cacheCap = Downloads.defaultCacheCap;
    d.pauseAll();
    for (var i = 0; i < 300 && d.busy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    d.paused = false;
    await d.store?.written;
    await deleteTemp(dir);
  });

  /// Opens [id] in the reader, a minute after the last one (the order books were opened in decides what goes).
  Future<void> open(String id) => withClock(Clock(() => now = now.add(const Duration(minutes: 1))), () async {
        await d.cacheBook(book(id));
        await settle(d);
      });

  test('a book opened is kept on the device in the background - readable offline, but not a download: not on the '
      'Downloads screen, not in its limit', () async {
    await open('B1');
    expect(d.isCached('B1'), isTrue);
    expect(d.isDownloaded('B1'), isFalse, reason: 'not a download');
    expect(d.store!.books['B1']!['state'], 'done', reason: 'readable from the device (and offline)');
    expect((d.cacheBytes, d.usedBytes), (300, 0));
    expect(d.shownQueue, isEmpty);
    await open('B1'); // opened again: nothing downloaded again
    expect(d.cacheBytes, 300);
  });

  test('over the limit, the book opened longest ago goes - a book opened again counts from then', () async {
    Downloads.cacheCap = 700; // room for two of these 300-byte books
    await open('B1');
    await open('B2');
    await open('B3');
    expect([for (final id in ['B1', 'B2', 'B3']) d.isCached(id)], [false, true, true], reason: 'B1, the oldest, went');
    await open('B2'); // read again: the newest now
    await open('B4');
    expect([for (final id in ['B2', 'B3', 'B4']) d.isCached(id)], [true, false, true], reason: 'B3 went, not B2');
    expect(d.cacheBytes, lessThanOrEqualTo(700));
  });

  test('a cached book finished goes at once - once its reader closes if one is open; Delete once read set to '
      'Never makes no difference', () async {
    expect(d.deleteRead, DeleteRead.never);
    await open('B1');
    d.bookFinished('B1');
    await waitUntil(() => !d.store!.books.containsKey('B1'), reason: 'deleted');
    expect(await Directory(d.store!.file('B1').path).exists(), isFalse, reason: 'its files too');

    await open('B2');
    d.readerOpened();
    d.bookFinished('B2');
    expect(d.isCached('B2'), isTrue, reason: 'its pages may still be on screen');
    d.readerClosed();
    await waitUntil(() => !d.store!.books.containsKey('B2'), reason: 'deleted once the reader closed');
  });

  test('a cached book downloaded on purpose is a download from then on: kept when finished', () async {
    await open('B1');
    expect(await d.add([book('B1')]), 1);
    expect((d.isDownloaded('B1'), d.isCached('B1')), (true, false));
    expect((d.usedBytes, d.cacheBytes), (300, 0));
    d.bookFinished('B1');
    await Future<void>.delayed(Duration.zero);
    expect(d.isDownloaded('B1'), isTrue, reason: 'Delete once read is Never: kept');
  });
}
