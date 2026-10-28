import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/offline/downloads.dart';
import 'package:komga_reader/offline/downloads_source.dart';
import 'package:komga_reader/offline/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/library_server.dart';
import 'support/no_network.dart';
import 'support/settle.dart';

LibraryServer server() => noNetwork(LibraryServer.new);

/// Pages with their sizes, as Komga lists them: page 2 wide (a spread).
class SizedPages extends LibraryServer {
  @override
  Future<List<dynamic>> pages(String bookId) async => [
        for (final p in await super.pages(bookId))
          {...p as Map, 'width': p['number'] == 2 ? 2000 : 1000, 'height': 1500},
      ];
}

Map<String, dynamic> book(String id, int n) =>
    {'id': id, 'seriesTitle': 'Silver Surfer', 'metadata': {'number': '$n'}};

void main() {
  late Directory dir;
  final d = Downloads.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    d.reset(); // open readers, books waiting to go, timers: nothing carried over from the last test (test audit, 2026-09-30)
    dir = await Directory.systemTemp.createTemp('komga_downloads_test');
  });
  tearDown(() async {
    // stop the worker before deleting its folder (it may still be writing a page)
    d.pauseAll();
    for (var i = 0; i < 300 && d.busy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    d.paused = false;
    await d.store?.written; // an index save still on its way (a book deleted once read) loses its folder otherwise
    await deleteTemp(dir);
  });

  test("a local library's book isn't queued, nor cached as it's read - it's on the device, and Komga hasn't it",
      () async {
    final api = server();
    await d.attach(api, root: dir);
    expect(await d.add([book('lb0000000000001', 1)]), 0);
    await d.cacheBook(book('lb0000000000002', 2));
    expect(d.queue, isEmpty);
    expect(d.store!.books, isEmpty);
  });

  test('a queued book downloads page by page, with its place in the tree, and shows up offline', () async {
    final api = server();
    await d.attach(api, root: dir);
    expect(await d.add([book('B1', 1)]), 1);
    await settle(d);
    expect(d.queue, isEmpty);
    expect(d.isDownloaded('B1'), isTrue);
    expect(d.usedBytes, 300);
    for (var n = 1; n <= 3; n++) {
      expect(await d.store!.file('B1/pages/000$n.jpg').length(), 100);
    }
    final pageFiles = Directory(d.store!.file('B1/pages').path).listSync().map((f) => f.path).toList();
    expect(pageFiles.where((p) => p.endsWith('.part')), isEmpty, reason: 'pages written whole: no half-written ones');
    expect(pageFiles, hasLength(3));
    expect(await d.store!.file('B1/thumb.jpg').exists(), isTrue);
    expect(await d.store!.file('series/S1.jpg').exists(), isTrue);
    expect(await d.store!.file('readlists/RL1.jpg').exists(), isTrue);

    final offline = DownloadsSource(d.store!);
    expect((await offline.libraries()).single['name'], 'Archive');
    expect(((await offline.readListBooks('RL1'))['content'] as List).single['id'], 'B1');
    expect(((await offline.collections())['content'] as List).single['name'], 'Marvel cosmic');
    expect(offline.store.readProgressOf('B1')!['page'], 2); // the server's progress came along
    // what comes next is recorded, so offline can say "the next book isn't downloaded" instead of skipping ahead
    expect(d.store!.books['B1']!['nextId'], 'B2');
    expect(((d.store!.books['B1']!['readLists'] as List).single as Map)['count'], 2);
    expect(() => offline.nextBook('B1'), throwsA(isA<NotAvailableOffline>())); // B2 not downloaded
  });

  test('queueing several books of one series asks for the series, the library list and the collections once, not '
      'once per book (code review 2026-10-05, #42) - each book still gets them', () async {
    final api = server();
    await d.attach(api, root: dir);
    await d.add([book('B1', 1), book('B2', 2), book('B3', 3), book('B4', 4)]); // one run of the queue
    await settle(d);
    for (final id in ['B1', 'B2', 'B3', 'B4']) {
      expect(d.isDownloaded(id), isTrue, reason: id);
      final e = d.store!.books[id]!;
      expect((e['series'] as Map)['name'], 'Silver Surfer', reason: id);
      expect((e['library'] as Map)['name'], 'Archive', reason: id);
      expect(((e['collections'] as List).single as Map)['name'], 'Marvel cosmic', reason: id);
    }
    expect(api.seriesRequests, 1);
    expect(api.librariesRequests, 1);
    expect(api.collectionsRequests, 1);
  });

  test('signing in again to the same server keeps the one store for its folder: a second one, while a download from '
      'before was still writing through the first, had two writing index.json (code review 2026-10-05, #27)',
      () async {
    final api = server();
    await d.attach(api, root: dir);
    final first = d.store;
    d.detach();
    await d.attach(api, root: dir);
    expect(identical(d.store, first), isTrue);
  });

  test('signing out mid-book stops that book at once: no more pages asked for with the old key (it carried on to the '
      'last page - code review 2026-10-05, #14)', () async {
    final api = server()..pageCount = 20;
    api.onPage = (n) {
      if (n == 3) d.detach(); // signed out while page 3 comes
    };
    await d.attach(api, root: dir);
    await d.add([book('B1', 1)]);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(api.pageRequests, 3, reason: 'none after signing out');
    expect(d.queue.single.state, JobState.queued, reason: 'kept, to go on when this account is back - not failed');
  });

  test('Delete once read: Never, nothing goes; Always, a book read goes - after the reader closes if it was open',
      () async {
    addTearDown(() => d.setDeleteRead(DeleteRead.never));
    await d.attach(server(), root: dir);
    await d.add([book('B1', 1), book('B2', 2)]);
    await settle(d);
    final offline = DownloadsSource(d.store!);
    await offline.markRead('B1');
    expect(d.isDownloaded('B1'), isTrue); // Never (the default): stays
    await d.setDeleteRead(DeleteRead.always);
    d.readerOpened();
    await offline.setProgress('B2', 3, completed: true); // finished in the reader
    // still open: held back for the reader to close, not deleted - checked on what was scheduled rather than on a
    // short wait outrunning the delete (test audit, 2026-09-30)
    expect(d.waitingForReaderToClose, {'B2'});
    expect(d.isDownloaded('B2'), isTrue);
    d.readerClosed();
    await waitUntil(() => !d.isDownloaded('B2'), timeout: const Duration(seconds: 1), reason: 'B2 deleted');
    expect(d.isDownloaded('B2'), isFalse);
    expect(d.store!.unsynced, contains('B2')); // the read mark is still on its way to Komga
    expect(d.isDownloaded('B1'), isTrue); // read before it was switched on: not touched
  });

  test('Delete once read, Ask: finished books are kept and gathered, handed over once no book is open', () async {
    addTearDown(() => d.setDeleteRead(DeleteRead.never));
    await d.attach(server(), root: dir);
    await d.add([book('B1', 1), book('B2', 2)]);
    await settle(d);
    await d.setDeleteRead(DeleteRead.ask);
    final offline = DownloadsSource(d.store!);
    d.readerOpened();
    await offline.markRead('B1');
    await offline.markRead('B2');
    expect(d.isDownloaded('B1') && d.isDownloaded('B2'), isTrue); // nothing deleted without an answer
    expect(d.noBookOpen, isFalse); // not asked while reading
    d.readerClosed();
    expect(d.noBookOpen, isTrue);
    expect(d.takeAskPending(), ['B1', 'B2']);
    expect(d.takeAskPending(), isEmpty); // asked once
    await d.removeAll(['B1']); // the answer: delete (just one, say)
    expect(d.isDownloaded('B1'), isFalse);
    expect(d.isDownloaded('B2'), isTrue);
  });

  test('Delete once read is kept across a restart', () async {
    addTearDown(() => d.setDeleteRead(DeleteRead.never));
    await d.attach(server(), root: dir);
    await d.setDeleteRead(DeleteRead.ask);
    d.deleteRead = DeleteRead.never; // forgotten in memory: "the next start" has only what was saved
    await d.attach(server(), root: dir);
    expect(d.deleteRead, DeleteRead.ask);
  });

  test('queuing the same book twice, or one already downloaded, does nothing', () async {
    await d.attach(server(), root: dir);
    await d.add([book('B1', 1)]);
    await settle(d);
    expect(await d.add([book('B1', 1), book('B1', 1)]), 0);
    // one already in the queue (paused, so it stays there) - B1 above only reached the "downloaded" check (test
    // audit, 2026-09-30)
    d.pauseAll();
    expect(await d.add([book('B2', 2), book('B2', 2)]), 1);
    expect(await d.add([book('B2', 2)]), 0);
    expect(d.queue.map((j) => j.bookId), ['B2']);
  });

  test('the size limit stops a book that would not fit, with a clear reason; it carries on by itself once there is '
      'room - a download removed, or the limit lifted', () async {
    // one test for both ways of making room (they were two, with the same set-up - test audit, 2026-09-30)
    for (final (how, makeRoom) in [
      ('a download removed', () => d.remove('B1')),
      ('the limit lifted', () => d.setCap(null)),
    ]) {
      d.reset();
      await d.attach(server(), root: await Directory('${dir.path}${Platform.pathSeparator}${how.replaceAll(' ', '_')}').create());
      await d.setCap(500); // bytes: room for one book of 300
      await d.add([book('B1', 1), book('B2', 2)]);
      await settle(d);
      expect(d.isDownloaded('B1'), isTrue, reason: how);
      final failed = d.jobFor('B2')!;
      expect(failed.state, JobState.failed, reason: how);
      expect(failed.error, contains('not enough room'), reason: how);
      await makeRoom();
      await settle(d);
      expect(d.isDownloaded('B2'), isTrue, reason: '$how: carried on by itself - no Retry needed');
      await d.setCap(null);
    }
  });

  test('cancel removes a queued book; remove deletes a download but keeps progress not yet sent', () async {
    await d.attach(server(), root: dir);
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

  // (Komga out of reach before the books start: downloads_offline_test, with Komga gone mid-book)

  test('Pause all is kept across a restart (the queue stays paused, with Resume)', () async {
    await d.attach(server(), root: dir);
    d.pauseAll();
    final prefs = await SharedPreferences.getInstance();
    await waitUntil(() => prefs.getBool('downloads.paused') == true, reason: 'the pause saved');
    d.paused = false; // forgotten in memory: "the next start"
    final api = server();
    await d.attach(api, root: dir);
    expect(d.paused, isTrue);
    await d.add([book('B1', 1)]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(api.pageRequests, 0, reason: 'nothing downloads while paused');
    d.resumeAll();
    await settle(d);
    expect(d.isDownloaded('B1'), isTrue);
  });

  test('a downloaded book is read from the device, online too - its page list and its pages; a book not downloaded, '
      "or another server's, still from Komga (user, 2026-10-12)", () async {
    await d.attach(server(), root: dir); // http://test
    await d.add([book('B1', 1)]);
    await settle(d);
    expect(d.isDownloaded('B1'), isTrue);
    final asked = <String>[];
    Komga komga(String url) => Komga(url, 'k', client: MockClient((r) async {
          asked.add(r.url.path);
          return r.url.path.endsWith('/pages')
              ? http.Response('[{"number":1,"mediaType":"image/jpeg"}]', 200)
              : http.Response.bytes([9, 9, 9], 200);
        }));
    final online = komga('http://test');
    expect((await online.pages('B1')).map((p) => p['number']), [1, 2, 3], reason: 'its three downloaded pages');
    final bytes = await online.pageBytes('B1', 2);
    expect(bytes, isNot([9, 9, 9]), reason: 'the page from the device');
    await online.pageThumbBytes('B1', 1);
    expect(asked, isEmpty, reason: 'nothing asked of Komga for a downloaded book');
    await online.pageBytes('B7', 1);
    await online.pages('B7');
    expect(asked, ['/api/v1/books/B7/pages/1', '/api/v1/books/B7/pages'], reason: 'not downloaded: Komga');
    asked.clear();
    await komga('http://elsewhere:25600').pageBytes('B1', 1);
    expect(asked, ['/api/v1/books/B1/pages/1'], reason: "another server's B1 isn't this one");
  });

  test("each server's downloads in a folder of their own; today's folder belongs to the first server that uses it",
      () async {
    await File('${dir.path}${Platform.pathSeparator}index.json').writeAsString('{}'); // downloads from before
    final a = await Downloads.serverFolder(dir, 'http://10.0.0.23:25600');
    expect(a.path, dir.path, reason: 'the folder there already: claimed by this server, nothing moved');
    final b = await Downloads.serverFolder(dir, 'https://komga.example.org/');
    expect(b.path, isNot(dir.path));
    expect(await File('${dir.path}${Platform.pathSeparator}index.json').exists(), isTrue);
    expect((await Downloads.serverFolder(dir, 'http://10.0.0.23:25600/')).path, dir.path, reason: 'A again');
    expect((await Downloads.serverFolder(dir, 'https://komga.example.org')).path, b.path, reason: 'B again');
    await Directory(b.path).delete(recursive: true);
  });

  test('the same Komga at a new address (user, 2026-10-12: moved to the NAS, its database with it): its downloads, '
      "filed under the old address, become the new one's - unsent reading progress with them; the empty folder made "
      'for the new address goes', () async {
    String p(Directory d, String f) => '${d.path}${Platform.pathSeparator}$f';
    Future<void> books(Directory d, String url, List<String> ids) async {
      await d.create(recursive: true);
      await File(p(d, 'server.json')).writeAsString(jsonEncode({'url': url}));
      await File(p(d, 'index.json')).writeAsString(jsonEncode({
        'v': 2,
        'books': {for (final id in ids) id: {'book': {'id': id}, 'state': 'done'}},
      }));
      await File(p(d, 'progress.json')).writeAsString(jsonEncode({
        'v': 1,
        'progress': {ids.first: {'page': 7, 'completed': false, 'synced': false}},
      }));
    }

    await books(dir, 'http://10.0.0.23:25600', ['B1', 'B2', 'B3']);
    const nas = 'http://10.0.0.226:25600';
    final fresh = await Downloads.serverFolder(dir, nas); // what signing in at the new address made: empty
    expect(fresh.path, isNot(dir.path));
    final asked = <String>[];
    final moved = await Downloads.movedFrom(dir, fresh, nas, (id) async {
      asked.add(id);
      return id != 'B3'; // one book re-ingested since (a new id): most are still there
    });
    expect(moved?.path, dir.path, reason: "the old address's downloads: this server's now");
    expect(asked, hasLength(3), reason: 'a few of its books asked about');
    expect(await Directory(fresh.path).exists(), isFalse, reason: 'the empty folder for the new address removed');
    expect((await Downloads.serverFolder(dir, nas)).path, dir.path, reason: 'and found there from now on');
    final store = OfflineStore(dir);
    await store.load();
    expect(store.books.keys, ['B1', 'B2', 'B3']);
    expect(store.progress['B1']?['synced'], isFalse, reason: 'progress not yet sent goes with it - to the same database');
  });

  test('signed in to the same Komga at its new address: the books downloaded at the old one are still downloaded',
      () async {
    await d.attach(server(), root: dir); // http://test
    await d.add([book('B1', 1), book('B2', 2)]);
    await settle(d);
    expect(d.isDownloaded('B1'), isTrue);
    await d.attach(noNetwork(() => LibraryServer('http://nas.test:25600')), root: dir); // the same books, moved
    expect(d.isDownloaded('B1'), isTrue, reason: 'they came along to the new address');
    expect(d.isDownloaded('B2'), isTrue);
  });

  test("another library's downloads aren't taken over; nor is anything when this address has books of its own or "
      'downloads queued, or Komga can\'t be asked', () async {
    String p(Directory d, String f) => '${d.path}${Platform.pathSeparator}$f';
    await dir.create(recursive: true);
    await File(p(dir, 'server.json')).writeAsString(jsonEncode({'url': 'https://other.example.org'}));
    await File(p(dir, 'index.json')).writeAsString(jsonEncode({'v': 2, 'books': {'X1': {}, 'X2': {}}}));
    const me = 'http://10.0.0.226:25600';
    final mine = await Downloads.serverFolder(dir, me);
    expect(await Downloads.movedFrom(dir, mine, me, (_) async => false), isNull, reason: 'not on this server');
    expect(await Downloads.movedFrom(dir, mine, me, (_) async => throw const SocketException('off')), isNull,
        reason: "Komga can't be asked: next time");
    await File(p(mine, 'queue.json')).writeAsString(jsonEncode([{'bookId': 'Q1', 'title': 'Q', 'state': 'queued'}]));
    expect(await Downloads.movedFrom(dir, mine, me, (_) async => true), isNull, reason: 'downloads queued here');
    await File(p(mine, 'queue.json')).delete();
    await File(p(mine, 'index.json')).writeAsString(jsonEncode({'v': 2, 'books': {'M1': {}}}));
    expect(await Downloads.movedFrom(dir, mine, me, (_) async => true), isNull, reason: 'books here already');
    expect(jsonDecode(await File(p(dir, 'server.json')).readAsString())['url'], 'https://other.example.org',
        reason: "the other library's folder untouched");
    expect(await Directory(mine.path).exists(), isTrue);
    await Directory(mine.path).delete(recursive: true);
  });

  test("Delete once read = Ask, answered Keep: that book isn't asked about again", () async {
    await d.attach(server(), root: dir);
    await d.add([book('B1', 1)]);
    await settle(d);
    await d.setDeleteRead(DeleteRead.ask);
    addTearDown(() => d.setDeleteRead(DeleteRead.never));
    d.bookFinished('B1');
    expect(d.takeAskPending(), ['B1']);
    await d.keep(['B1']); // the answer
    d.bookFinished('B1'); // the read reaching Komga later says so again
    expect(d.askPending, isEmpty);
  });

  test('Wi-Fi only: off (the default), mobile data downloads as before; on, on mobile data the queue waits and says '
      'so; back on Wi-Fi it carries on by itself', () async {
    var wifi = false;
    Downloads.isOnWifi = () async => wifi;
    Downloads.wifiRecheck = const Duration(milliseconds: 30);
    addTearDown(() async {
      Downloads.isOnWifi = () async => true;
      Downloads.wifiRecheck = const Duration(seconds: 30);
      await d.setWifiOnly(false);
    });
    final api = server();
    await d.attach(api, root: dir);
    expect(d.wifiOnly, isFalse);
    await d.add([book('B2', 2)]); // on mobile data, Wi-Fi only off
    await settle(d);
    expect(d.isDownloaded('B2'), isTrue);

    await d.setWifiOnly(true);
    final before = api.pageRequests;
    await d.add([book('B1', 1)]);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(api.pageRequests, before, reason: 'nothing fetched on mobile data');
    expect(d.waitingForWifi, isTrue);
    expect(d.jobFor('B1')!.state, JobState.queued);

    wifi = true; // back on Wi-Fi: the next look carries on
    await settle(d);
    expect(d.isDownloaded('B1'), isTrue);
    expect(d.waitingForWifi, isFalse);

    d.wifiOnly = false; // forgotten in memory: "the next launch" has only what was saved (test audit, 2026-09-30)
    await d.attach(server(), root: dir);
    expect(d.wifiOnly, isTrue, reason: 'the choice is kept');
  });

  test('the queue survives a restart, and pages already on disk are not fetched again', () async {
    // pause exactly after page 1 (deterministic, whatever the machine's speed)
    final api = server()..onPage = (n) { if (n == 1) d.pauseAll(); };
    await d.attach(api, root: dir);
    await d.add([book('B1', 1)]);
    await waitUntil(() => d.jobFor('B1')?.state == JobState.paused && !d.busy, timeout: const Duration(seconds: 3),
        reason: 'B1 paused and saved');
    final fetchedBefore = api.pageRequests;
    expect(fetchedBefore, 1);

    d.paused = false;
    final again = server();
    await d.attach(again, root: dir); // "next launch"
    expect(d.jobFor('B1'), isNotNull);
    d.resumeAll();
    await settle(d);
    expect(d.isDownloaded('B1'), isTrue);
    expect(again.pageRequests, 3 - fetchedBefore); // only the missing pages
  });

  test('cancel all empties the queue (the downloading book stops and is cleaned up); finished downloads stay', () async {
    final api = server();
    await d.attach(api, root: dir);
    await d.add([book('B1', 1)]);
    await settle(d);
    expect(d.isDownloaded('B1'), isTrue);

    // cancel exactly while B2's first page comes in, so B2 is certainly the book downloading (it used to be a 5 ms
    // wait, which never checked that - test audit, 2026-09-30)
    JobState? b2WhenCancelled;
    api.onPage = (n) {
      api.onPage = null; // once
      b2WhenCancelled = d.jobFor('B2')?.state;
      unawaited(d.cancelAll());
    };
    await d.add([book('B2', 2), book('B3', 3)]);
    await waitUntil(() => !d.busy && d.queue.isEmpty, timeout: const Duration(seconds: 3), reason: 'the queue emptied');
    expect(b2WhenCancelled, JobState.downloading);
    expect(d.queue, isEmpty);
    expect(api.pageRequests, 3 + 1, reason: "B1's pages, then B2 stopped after the page it was on; B3 never started");
    expect(d.isDownloaded('B1'), isTrue); // finished download untouched
    expect(d.store!.books.containsKey('B2'), isFalse); // partial download cleaned up
    expect(await Directory(d.store!.file('B2').path).exists(), isFalse);
  });


  test("a download keeps its pages' sizes (2026-10-16: two pages side by side pair on them - a wide page alone); "
      'listed so online and offline', () async {
    await d.attach(noNetwork(SizedPages.new), root: dir);
    await d.add([book('B1', 1)]);
    await settle(d);
    final sizes = [for (final p in d.pagesOf('http://test', 'B1')!) (p['width'], p['height'])];
    expect(sizes, [(1000, 1500), (2000, 1500), (1000, 1500)]);
    final offline = await DownloadsSource(d.store!).pages('B1');
    expect([for (final p in offline) (p['number'], p['width'], p['height'])],
        [(1, 1000, 1500), (2, 2000, 1500), (3, 1000, 1500)]);
  });
}
