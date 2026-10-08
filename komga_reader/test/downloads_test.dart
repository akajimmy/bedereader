import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/offline/downloads.dart';
import 'package:komga_reader/offline/offline_komga.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/library_server.dart';
import 'support/no_network.dart';

LibraryServer server() => noNetwork(LibraryServer.new);

Map<String, dynamic> book(String id, int n) =>
    {'id': id, 'seriesTitle': 'Silver Surfer', 'metadata': {'number': '$n'}};

/// Waits (on the real clock, 2 s at most) until nothing is queued or downloading. Fails the test if that never happens:
/// it used to return quietly, so the next expectation failed for the wrong reason (test audit, 2026-09-30).
Future<void> settle(Downloads d) async {
  bool working() => d.queue.any((j) => j.state == JobState.queued || j.state == JobState.downloading);
  try {
    await waitUntil(() => !working());
  } on TestFailure {
    fail('the queue never settled: ${[for (final j in d.queue) '${j.bookId} ${j.state.name}']}');
  }
}

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
    await deleteTemp(dir);
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
    expect(await d.store!.file('B1/thumb.jpg').exists(), isTrue);
    expect(await d.store!.file('series/S1.jpg').exists(), isTrue);
    expect(await d.store!.file('readlists/RL1.jpg').exists(), isTrue);

    final offline = OfflineKomga(d.store!);
    expect((await offline.libraries()).single['name'], 'Archive');
    expect(((await offline.readListBooks('RL1'))['content'] as List).single['id'], 'B1');
    expect(((await offline.collections())['content'] as List).single['name'], 'Marvel cosmic');
    expect(offline.store.readProgressOf('B1')!['page'], 2); // the server's progress came along
    // what comes next is recorded, so offline can say "the next book isn't downloaded" instead of skipping ahead
    expect(d.store!.books['B1']!['nextId'], 'B2');
    expect(((d.store!.books['B1']!['readLists'] as List).single as Map)['count'], 2);
    expect(() => offline.nextBook('B1'), throwsA(isA<NotAvailableOffline>())); // B2 not downloaded
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
    await d.attach(server(), root: dir);
    await d.add([book('B1', 1), book('B2', 2)]);
    await settle(d);
    final offline = OfflineKomga(d.store!);
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
    await d.setDeleteRead(DeleteRead.never);
  });

  test('Delete once read, Ask: finished books are kept and gathered, handed over once no book is open', () async {
    await d.attach(server(), root: dir);
    await d.add([book('B1', 1), book('B2', 2)]);
    await settle(d);
    await d.setDeleteRead(DeleteRead.ask);
    final offline = OfflineKomga(d.store!);
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
    await d.setDeleteRead(DeleteRead.never);
  });

  test("the old on/off switch isn't migrated (user, 2026-10-07): ignored, Never; the setting itself is kept",
      () async {
    SharedPreferences.setMockInitialValues({'downloads.deleteWhenRead': true});
    await d.attach(server(), root: dir);
    expect(d.deleteRead, DeleteRead.never);
    SharedPreferences.setMockInitialValues({'downloads.deleteRead': 'ask'});
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

  test("Komga out of reach: the books go back in the queue (not failed) and it carries on by itself once Komga answers "
      '(code review, 2026-09-30)', () async {
    Downloads.serverRecheck = const Duration(milliseconds: 30);
    addTearDown(() => Downloads.serverRecheck = const Duration(seconds: 30));
    final api = server()..pagesDown = true;
    await d.attach(api, root: dir);
    api.up = false; // its "are you there" check fails too
    await d.add([book('B1', 1), book('B2', 2)]);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(d.queue.map((j) => j.state), everyElement(JobState.queued), reason: 'waiting, not failed');
    expect(d.waitingForServer, isTrue);

    api
      ..pagesDown = false
      ..up = true; // back
    await waitUntil(() => d.isDownloaded('B1') && d.isDownloaded('B2'), timeout: const Duration(seconds: 1),
        reason: 'both downloaded once Komga is back');
    expect(d.isDownloaded('B1') && d.isDownloaded('B2'), isTrue);
    expect(d.waitingForServer, isFalse);
  });

  test('Pause all is kept across a restart (the queue stays paused, with Resume)', () async {
    await d.attach(server(), root: dir);
    d.pauseAll();
    await Future<void>.delayed(const Duration(milliseconds: 20));
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

  test('pages are written whole: no half-written page files are left behind', () async {
    await d.attach(server(), root: dir);
    await d.add([book('B1', 1)]);
    await settle(d);
    final files = Directory(d.store!.file('B1/pages').path).listSync().map((f) => f.path).toList();
    expect(files.where((p) => p.endsWith('.part')), isEmpty);
    expect(files.length, 3);
  });

  test('Wi-Fi only: on mobile data the queue waits and says so; back on Wi-Fi it carries on by itself', () async {
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
    await d.setWifiOnly(true);
    await d.add([book('B1', 1)]);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(api.pageRequests, 0, reason: 'nothing fetched on mobile data');
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

  test('Wi-Fi only off (the default): mobile data downloads as before', () async {
    Downloads.isOnWifi = () async => false;
    addTearDown(() => Downloads.isOnWifi = () async => true);
    await d.attach(server(), root: dir);
    expect(d.wifiOnly, isFalse);
    await d.add([book('B1', 1)]);
    await settle(d);
    expect(d.isDownloaded('B1'), isTrue);
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
}

