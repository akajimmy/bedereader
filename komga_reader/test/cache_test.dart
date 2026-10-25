// The cache (user, 2026-10-24): "When I open a book, assuming it's not already downloaded, the app should, in addition
// to immediately opening the book, start downloading it in the background. The app should maintain a specific amount
// of hard drive space maximum for cached issues. And a book that is finished reading should immediately delete the
// cache. Aside from that, when maximum size is reached, delete the oldest cache book. ... 512 megabytes".
import 'dart:convert';
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

/// Komga's page sizes a tenth of the real ones (the room is judged by them before a book is cached).
class ShortSizes extends LibraryServer {
  ShortSizes([super.baseUrl]);
  @override
  Future<List<dynamic>> pages(String bookId) async =>
      [for (final p in await super.pages(bookId)) {...p as Map<String, dynamic>, 'sizeBytes': 10}];
}

void main() {
  late Directory dir;
  late LibraryServer server;
  final d = Downloads.instance;
  var now = DateTime(2026, 10, 24, 18);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    d.reset();
    dir = await Directory.systemTemp.createTemp('komga_cache_test');
    server = noNetwork(LibraryServer.new);
    await d.attach(server, root: dir);
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

  // code review, 2026-10-24: the room check took a resumed book's bytes so far off twice, and the check once a book
  // was in left its real size out - the cache went past its limit
  test('a book cached in two goes (paused partway): the cache stays within its limit', () async {
    Downloads.cacheCap = 550; // B1 and B2 (300 each) don't both fit
    await open('B1');
    server.onPage = (n) {
      if (n == 1) d.pauseAll(); // B2 stops after its first page
    };
    await withClock(Clock.fixed(now = now.add(const Duration(minutes: 1))), () => d.cacheBook(book('B2')));
    await waitUntil(() => !d.busy && d.jobFor('B2')?.state == JobState.paused);
    server.onPage = null;
    d.resumeAll();
    await waitUntil(() => !d.busy && d.isCached('B2'));
    expect((d.isCached('B1'), d.cacheBytes), (false, 300), reason: 'B1, the older, went to make room');
  });

  test("Komga's sizes short of the real ones: once the book is in, the cache is brought back within its limit",
      () async {
    await d.attach(noNetwork(ShortSizes.new), root: dir);
    Downloads.cacheCap = 500;
    await open('B1');
    await open('B2'); // judged 30 bytes, really 300
    await waitUntil(() => !d.busy);
    expect((d.isCached('B1'), d.isCached('B2'), d.cacheBytes), (false, true, 300));
  });

  test('a cached copy failing goes from the queue - the book is cached when next opened', () async {
    server.booksFail = true;
    await open('B1');
    await waitUntil(() => !d.busy);
    expect(d.jobFor('B1'), isNull, reason: 'not left in the queue, out of sight, as failed');
    server.booksFail = false;
    await open('B1');
    await waitUntil(() => !d.busy);
    expect(d.isCached('B1'), isTrue);
  });

  test('a book too big for the cache: its job is gone from the saved queue too (not back at the next start)',
      () async {
    Downloads.cacheCap = 200;
    await open('B1'); // 300 bytes
    await waitUntil(() => !d.busy);
    expect(d.jobFor('B1'), isNull);
    await d.store!.written;
    final saved = jsonDecode(await d.store!.file('queue.json').readAsString()) as List;
    expect([for (final j in saved) j['bookId']], isNot(contains('B1')));
  });

  test("making room never takes the book open in the reader (its pages are read from the cache's files)", () async {
    Downloads.cacheCap = 700; // two books
    d.readerOpened();
    await open('B1');
    await open('B2');
    d.reading('B1'); // back to B1 - read from the device
    await open('B3'); // B1 is the oldest opened...
    await waitUntil(() => !d.busy);
    expect([for (final id in ['B1', 'B2', 'B3']) d.isCached(id)], [true, false, true], reason: '...but open: B2 went');
    d.readerClosed();
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
