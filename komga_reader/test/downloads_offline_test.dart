import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/offline/connection.dart';
import 'package:komga_reader/offline/downloads.dart';
import 'package:komga_reader/offline/offline_komga.dart';
import 'package:komga_reader/offline/sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/library_server.dart';
import 'support/no_network.dart';

/// Another Komga (its own address) that has never heard of B1 - had it seen the first server's downloads, it would
/// have called B1 "gone" and dropped its unsent progress (the bug per-server folders fixed - code review, 2026-09-30).
class OtherServer extends LibraryServer {
  OtherServer() : super('http://other.example:25600');
  final asked = <String>[];
  @override
  Future<Map<String, dynamic>?> book(String id) async {
    asked.add(id);
    return id == 'B1' ? null : super.book(id);
  }
}

/// [LibraryServer] answering the progress sync's refresh too (going back online runs the sync - lib/offline/sync.dart).
class SyncingServer extends LibraryServer {
  @override
  Future<Map<String, dynamic>> seriesBooks(String seriesId, {List<String>? readStatus,
          String sort = 'metadata.numberSort,asc', int page = 0, int size = 500}) async =>
      onePage([(await this.book('B1'))!, (await this.book('B2'))!]);
}

Map<String, dynamic> book(String id, int n) => {'id': id, 'seriesTitle': 'Silver Surfer', 'metadata': {'number': '$n'}};

/// Downloads when things change under them: another server, offline mode, Wi-Fi or Komga going mid-book, a failure
/// and Retry (test audit, 2026-09-30: none of these had a test).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); // the connection and the sync watch the app's lifecycle
  late Directory dir, root;
  final d = Downloads.instance;
  final conn = Connection.instance;
  final sync = ProgressSync.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    d.reset();
    dir = await Directory.systemTemp.createTemp('komga_dl_offline_test');
    root = Directory('${dir.path}${Platform.pathSeparator}downloads'); // other servers' folders go beside it, inside dir
  });
  tearDown(() async {
    d.pauseAll(); // stop the worker before its folder goes
    await waitUntil(() => !d.busy, timeout: const Duration(seconds: 3), reason: 'the worker to stop');
    d.paused = false;
    await d.setWifiOnly(false);
    d.reset();
    sync.reset();
    conn.reset();
    await deleteTemp(dir);
  });

  Future<void> settle() => waitUntil(
      () => !d.busy && !d.queue.any((j) => j.state == JobState.queued || j.state == JobState.downloading),
      reason: 'the queue to settle');

  bool partFiles(String bookId) => Directory(d.store!.file('$bookId/pages').path)
      .listSync()
      .any((f) => f.path.endsWith('.part'));

  test("two servers: each has its own folder (recorded in server.json); signing in to the other neither shows nor "
      "touches the first one's downloads or unsent progress, and they're all there on coming back", () async {
    final a = noNetwork(LibraryServer.new);
    await d.attach(a, root: root);
    await d.add([book('B1', 1)]);
    await settle();
    await d.store!.setProgress('B1', page: 3, completed: false); // read offline, not sent yet
    final folderA = d.store!.root.path;

    // signed in to another server: the app attaches downloads, loads the connection, starts the sync (main.dart)
    final b = noNetwork(OtherServer.new);
    await d.attach(b, root: root);
    await conn.load(b);
    sync.start();
    await waitUntil(() => !sync.running, reason: "the sync on B's downloads");
    final folderB = d.store!.root.path;
    expect(folderB, isNot(folderA));
    expect(jsonDecode(File('$folderA${Platform.pathSeparator}server.json').readAsStringSync())['url'],
        'http://test');
    expect(jsonDecode(File('$folderB${Platform.pathSeparator}server.json').readAsStringSync())['url'],
        'http://other.example:25600');
    expect(d.isDownloaded('B1'), isFalse, reason: "A's book isn't shown on B");
    expect(conn.hasDownloads, isFalse);
    expect(await OfflineKomga(d.store!).libraries(), isEmpty, reason: 'offline on B: nothing of A');
    expect(b.asked, isEmpty, reason: "B's sync never saw A's unsent progress, so couldn't call it gone");

    await d.add([book('B2', 2)]); // B's own download
    await settle();
    expect(d.isDownloaded('B2'), isTrue);
    await d.remove('B2'); // and removing it touches only B's folder
    expect(Directory('$folderA${Platform.pathSeparator}B1').existsSync(), isTrue);

    sync.reset();
    conn.reset();
    await d.attach(noNetwork(LibraryServer.new), root: root); // back to A
    expect(d.store!.root.path, folderA);
    expect(d.isDownloaded('B1'), isTrue);
    expect(d.store!.unsynced, ['B1'], reason: "A's progress is still waiting to be sent");
    expect(d.store!.progress['B1']!['page'], 3);
  });

  test('offline mode switched on mid-download: the book stops after its page and waits (kept, not finished, no .part '
      'left); back online it carries on from there', () async {
    final api = noNetwork(SyncingServer.new);
    await d.attach(api, root: root);
    await conn.load(api);
    api.onPage = (n) {
      if (n == 1) unawaited(conn.setForcedOffline(true)); // the switch in the side menu, while page 1 comes in
    };
    await d.add([book('B1', 1)]);
    await waitUntil(() => !d.busy && d.jobFor('B1')?.state == JobState.queued && api.pageRequests > 0,
        reason: 'B1 held after page 1');
    await Future<void>.delayed(const Duration(milliseconds: 100)); // nothing more while offline
    expect(api.pageRequests, 1, reason: 'nothing fetched once offline');
    expect(d.hold, isTrue);
    expect(d.jobFor('B1')!.state, JobState.queued, reason: 'waiting, not failed or paused');
    expect(d.isDownloaded('B1'), isFalse, reason: 'not a finished book');
    expect(d.store!.books['B1']!['state'], 'partial');
    expect(partFiles('B1'), isFalse);
    expect(await d.store!.file('B1/pages/0001.jpg').length(), 100, reason: 'the page it had is kept');
    expect(await OfflineKomga(d.store!).book('B1'), isNull, reason: 'offline, a part-downloaded book is not offered');

    api.onPage = null;
    await conn.setForcedOffline(false);
    await settle();
    expect(d.isDownloaded('B1'), isTrue);
    expect(api.pageRequests, 3, reason: 'only the two missing pages fetched');
    expect(partFiles('B1'), isFalse);
  });

  test('Wi-Fi lost mid-book (a book of more than 5 pages): it stops at the next check, keeps its pages, waits for '
      'Wi-Fi and carries on from there', () async {
    var wifi = true;
    Downloads.isOnWifi = () async => wifi;
    Downloads.wifiRecheck = const Duration(milliseconds: 30);
    addTearDown(() {
      Downloads.isOnWifi = () async => true;
      Downloads.wifiRecheck = const Duration(seconds: 30);
    });
    final api = noNetwork(LibraryServer.new)..pageCount = 8;
    await d.attach(api, root: root);
    await d.setWifiOnly(true);
    api.onPage = (n) {
      if (n == 3) wifi = false; // on mobile data from page 3 on
    };
    await d.add([book('B1', 1)]);
    await waitUntil(() => d.waitingForWifi && !d.busy, reason: 'B1 stopped for Wi-Fi');
    await Future<void>.delayed(const Duration(milliseconds: 100)); // a few rechecks, still off Wi-Fi
    expect(api.pageRequests, 5, reason: 'pages 1-5, then the every-5-pages check stopped it');
    expect(d.jobFor('B1')!.state, JobState.queued);
    expect(d.isDownloaded('B1'), isFalse);
    expect(d.store!.books['B1']!['bytes'], 500, reason: 'what it had is recorded');
    expect(partFiles('B1'), isFalse);

    api.onPage = null;
    wifi = true;
    await settle();
    expect(d.isDownloaded('B1'), isTrue);
    expect(api.pageRequests, 8, reason: 'pages 6-8 only');
    expect(d.waitingForWifi, isFalse);
  });

  test("Komga gone mid-book: back in the queue with its pages kept, a look every serverRecheck (no hammering), and on "
      'from where it stopped once Komga answers', () async {
    Downloads.serverRecheck = const Duration(milliseconds: 30);
    addTearDown(() => Downloads.serverRecheck = const Duration(seconds: 30));
    final api = noNetwork(LibraryServer.new)..pageCount = 8;
    await d.attach(api, root: root);
    api.onPage = (n) {
      if (n == 4) {
        api
          ..pagesDown = true
          ..up = false;
      }
    };
    await d.add([book('B1', 1)]);
    await waitUntil(() => d.waitingForServer && !d.busy, reason: 'B1 waiting for Komga');
    final looks = api.meCalls;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(api.pageRequests, 4);
    expect(d.jobFor('B1')!.state, JobState.queued, reason: 'not failed');
    expect(api.meCalls - looks, inInclusiveRange(1, 9), reason: 'about one look per 30 ms recheck, not a spin');

    api
      ..onPage = null
      ..pagesDown = false
      ..up = true;
    await settle();
    expect(d.isDownloaded('B1'), isTrue);
    expect(api.pageRequests, 8, reason: 'pages 5-8 only: the four it had were kept');
    expect(d.waitingForServer, isFalse);
  });

  test('a failed download: Retry tries that book again; Retry all the rest - and they download', () async {
    final api = noNetwork(LibraryServer.new)..booksFail = true;
    await d.attach(api, root: root);
    await d.add([book('B1', 1), book('B2', 2)]);
    await settle();
    expect(d.queue.map((j) => j.state), [JobState.failed, JobState.failed]);
    expect(d.jobFor('B1')!.error, isNotEmpty, reason: 'says why');

    api.booksFail = false;
    d.retry('B1');
    await settle();
    expect(d.isDownloaded('B1'), isTrue);
    expect(d.jobFor('B2')!.state, JobState.failed, reason: 'Retry is for that book only');

    d.retryAll();
    await settle();
    expect(d.isDownloaded('B2'), isTrue);
    expect(d.queue, isEmpty);
  });
}
