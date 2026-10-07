import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/offline/connection.dart';
import 'package:komga_reader/offline/downloads.dart';
import 'package:komga_reader/offline/offline_komga.dart';
import 'package:komga_reader/offline/sync.dart';
import 'package:komga_reader/screens/downloads_screen.dart';
import 'package:komga_reader/widgets/sync_alert.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/library_server.dart';
import 'support/no_network.dart';

/// Komga with reading progress kept in memory (bookId -> readProgress; absent = unread).
class ProgressServer extends LibraryServer {
  final Map<String, Map<String, dynamic>> rp = {};
  final writes = <String>[];
  final missing = <String>{};
  final refused = <String>{}; // books Komga refuses progress for (403)
  final goneSeries = <String>{}; // series deleted on Komga
  bool down = false; // Komga (or the network) gone: every call "can't reach", reported as the real client does
  void Function(String id)? onBook; // called as each book is asked for (tests use it to drop Komga at an exact point)
  int bookCalls = 0, seriesCalls = 0;
  bool morePages = false; // the series' list says it has more pages ('last': false)
  void Function()? onSeriesAnswered;

  void _reach() {
    Komga.onReachability?.call(this, !down);
    if (down) throw KomgaUnreachable(baseUrl);
  }

  @override
  Future<Map<String, dynamic>?> book(String id) async {
    bookCalls++;
    onBook?.call(id);
    _reach();
    if (missing.contains(id)) return null;
    return {...(await super.book(id))!, 'readProgress': rp[id]};
  }

  @override
  Future<void> setProgress(String bookId, int page, {bool completed = false}) async {
    if (refused.contains(bookId)) throw KomgaError(403, '/api/v1/books/$bookId/read-progress');
    writes.add('$bookId page $page');
    rp[bookId] = {'page': page, 'completed': completed};
  }

  // EPUBs: the exact place (Readium progression); Komga makes the read progress page from it - how far through the
  // book times its page count (10 here), as the real one does
  final places = <String, Map<String, dynamic>>{};
  int placeAsks = 0;
  bool placeFails = false; // Komga answers, but with an error, when asked for a place

  @override
  Future<Map<String, dynamic>?> epubProgression(String bookId) async {
    _reach();
    placeAsks++;
    if (placeFails) throw KomgaError(500, '/api/v1/books/$bookId/progression');
    return places[bookId];
  }

  @override
  Future<void> setEpubProgression(String bookId, Map<String, dynamic> progression) async {
    final total = ((progression['locator'] as Map)['locations'] as Map)['totalProgression'] as num;
    writes.add('$bookId place $total');
    places[bookId] = progression;
    rp[bookId] = {'page': (total * 10).round().clamp(1, 10), 'completed': false};
  }

  @override
  Future<void> markRead(String bookId) async {
    writes.add('$bookId read');
    rp[bookId] = {'page': 3, 'completed': true};
  }

  @override
  Future<void> markUnread(String bookId) async {
    writes.add('$bookId unread');
    rp.remove(bookId);
  }

  @override
  Future<Map<String, dynamic>> seriesBooks(String seriesId, {List<String>? readStatus,
      String sort = 'metadata.numberSort,asc', int page = 0, int size = 500}) async {
    seriesCalls++;
    _reach();
    if (goneSeries.contains(seriesId)) throw KomgaError(404, '/api/v1/series/$seriesId/books');
    final ids = [for (final id in seriesId == 'S2' ? ['B3'] : ['B1', 'B2']) if (!missing.contains(id)) id];
    final answer = {'content': [for (final id in ids) {'id': id, 'readProgress': rp[id]}], if (morePages) 'last': false};
    onSeriesAnswered?.call(); // (tests: something happens here while the answer is on its way)
    return answer;
  }
}

/// Offline phase 5: progress made offline reaches Komga - as it is when only this device changed it, further-wins
/// with an alert entry when Komga changed too; downloaded copies follow Komga.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late ProgressServer server;
  final conn = Connection.instance;
  final sync = ProgressSync.instance;
  final d = Downloads.instance;

  Map<String, dynamic> entry(String id) => {
        'book': {'id': id, 'seriesId': 'S1', 'readProgress': server.rp[id]},
        'readLists': [], 'pages': [{}, {}, {}], 'state': 'done',
      };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('komga_sync_test');
    server = noNetwork(ProgressServer.new);
    server.rp['B1'] = {'page': 1, 'completed': false}; // B1 started on page 1, B2 unread, when downloaded
    await d.attach(server, root: dir);
    await d.store!.put('B1', entry('B1'));
    await d.store!.put('B2', entry('B2'));
    await conn.load(server);
    sync.reset();
    sync.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    sync.takeResult();
    server.writes.clear();
  });
  tearDown(() async {
    sync.reset();
    conn.reset();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await deleteTemp(dir);
  });

  OfflineKomga offlineApi() => OfflineKomga(d.store!, baseUrl: 'offline');

  test('one book Komga keeps refusing holds up nothing: the others are sent (code review, 2026-09-30)', () async {
    final off = offlineApi();
    await off.setProgress('B1', 2);
    await off.setProgress('B2', 2);
    server.refused.add('B1'); // first in the queue, and refused
    await sync.run();
    expect(server.writes, ['B2 page 2'], reason: 'B2 sent despite B1');
    expect(sync.pending, 1, reason: 'B1 waits for the next run');
  });

  test('a series deleted on Komga: its downloads are marked, and the series after it still refresh', () async {
    await d.store!.put('B3', {...entry('B3'), 'book': {'id': 'B3', 'seriesId': 'S2'}}); // another series, after S1
    server.goneSeries.add('S1');
    server.rp['B3'] = {'page': 2, 'completed': false}; // read on another device
    await sync.run();
    expect(d.store!.books['B1']!['gone'], isTrue);
    expect(d.store!.books['B2']!['gone'], isTrue);
    expect(d.store!.readProgressOf('B3')!['page'], 2, reason: 'S2 refreshed even though S1 failed before it');
  });

  test('only this device changed: sent as it is, including mark as unread', () async {
    final off = offlineApi();
    await off.setProgress('B2', 2); // read offline
    await off.markUnread('B1'); // and marked unread
    expect(sync.pending, 2);

    await sync.run();
    expect(server.writes, unorderedEquals(['B2 page 2', 'B1 unread']));
    expect(server.rp['B2'], {'page': 2, 'completed': false});
    expect(server.rp.containsKey('B1'), isFalse);
    expect(sync.pending, 0);
    final r = sync.takeResult()!;
    expect(r.sent, 2);
    expect(r.conflicts, isEmpty);
  });

  test('Komga changed too: further wins, both ways, and each is listed', () async {
    final off = offlineApi();
    await off.setProgress('B1', 3); // here: B1 on to page 3 ...
    server.rp['B1'] = {'page': 2, 'completed': false}; // ... Komga (the web) only got to page 2: here is further
    await off.setProgress('B2', 1); // here: B2 page 1 ...
    server.rp['B2'] = {'page': 3, 'completed': true}; // ... Komga: finished it: Komga is further

    await sync.run();
    expect(server.writes, ['B1 page 3']); // B2 is never un-finished
    expect(server.rp['B2']!['completed'], isTrue);
    expect(d.store!.readProgressOf('B2')!['completed'], isTrue); // the downloaded copy takes Komga's
    final r = sync.takeResult()!;
    expect(r.conflicts.map((c) => (c.here, c.komga, c.keptHere)), unorderedEquals([
      ('page 3', 'page 2', true),
      ('page 1', 'read', false),
    ]));
  });

  test('Komga changed to the same thing: not a clash', () async {
    await offlineApi().markRead('B1');
    server.rp['B1'] = {'page': 3, 'completed': true}; // read on the web as well
    await sync.run();
    expect(server.writes, isEmpty);
    expect(sync.takeResult()!.conflicts, isEmpty);
  });

  test('book gone from Komga: its queued progress is dropped and counted', () async {
    await offlineApi().setProgress('B2', 2);
    server.missing.add('B2');
    await sync.run();
    expect(sync.pending, 0);
    expect(sync.takeResult()!.gone, 1);
  });

  test('offline: nothing is sent; back online: sent', () async {
    await conn.setForcedOffline(true);
    await offlineApi().setProgress('B2', 2);
    await sync.run();
    expect(server.writes, isEmpty);
    await conn.setForcedOffline(false); // going back online runs it
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(server.writes, ['B2 page 2']);
  });

  test('downloaded copies follow Komga: reading elsewhere (refresh) and reading online here (mirror)', () async {
    server.rp['B2'] = {'page': 2, 'completed': false}; // read on the web
    await sync.run();
    expect(d.store!.readProgressOf('B2')!['page'], 2);

    Komga.onProgressWritten!(server, const ProgressWrite(bookId: 'B1', completed: true)); // read online here
    expect(d.store!.readProgressOf('B1')!['completed'], isTrue);
    Komga.onProgressWritten!(server, const ProgressWrite(seriesId: 'S1', unread: true)); // whole series unread
    expect(d.store!.readProgressOf('B1'), isNull);
    expect(d.store!.readProgressOf('B2'), isNull);
    expect(sync.pending, 0); // none of that needs sending
  });

  test('a page read online while the refresh is on its way stays: the refresh had asked Komga before, and put the '
      'page before back (code review 2026-10-05, #11)', () async {
    server.rp['B2'] = {'page': 2, 'completed': false};
    server.onSeriesAnswered = () {
      server.onSeriesAnswered = null;
      server.rp['B2'] = {'page': 3, 'completed': false};
      Komga.onProgressWritten!(server, const ProgressWrite(bookId: 'B2', page: 3)); // read online here, meanwhile
    };
    await sync.run();
    expect(d.store!.readProgressOf('B2')!['page'], 3, reason: "this device's newer page, not Komga's earlier answer");
  });

  test("Komga gone mid-sync: it stops at once - the rest stays queued, nothing asked again on its own - and it's all "
      'sent once Komga is back and the app goes online', () async {
    await d.store!.put('B3', {...entry('B3'), 'book': {'id': 'B3', 'seriesId': 'S2'}});
    final off = offlineApi();
    await off.setProgress('B1', 2);
    await off.setProgress('B2', 2);
    await off.setProgress('B3', 1);
    server.onBook = (id) {
      if (id == 'B2') server.down = true; // B1 sent, then Komga drops
    };
    final calls = server.bookCalls, refreshes = server.seriesCalls;
    await sync.run();
    expect(server.writes, ['B1 page 2']);
    expect(server.bookCalls - calls, 2, reason: "stopped at B2's \"can't reach\": B3 never asked");
    expect(server.seriesCalls, refreshes, reason: 'no refresh after it');
    expect(sync.running, isFalse);
    expect(sync.pending, 2, reason: 'B2 and B3 still queued');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(server.bookCalls - calls, 2, reason: 'no retrying on its own');

    expect(conn.askPending, isTrue, reason: "the call that failed raised \"can't reach Komga\"");
    conn.useDownloads(); // "Use downloaded books"
    server
      ..down = false
      ..onBook = null;
    await conn.check(); // the 30 s poll: Komga answers
    expect(conn.reachableAgain, isTrue);
    await conn.goOnline(); // "Go online": the sync runs again
    await waitUntil(() => sync.pending == 0 && !sync.running, reason: 'the rest sent once back online');
    expect(server.writes, ['B1 page 2', 'B2 page 2', 'B3 page 1']);
  });

  testWidgets("a downloaded book's series deleted on Komga: the sync marks it, the Downloads screen says so, it still "
      'reads offline; the series back, the mark goes', (tester) async {
    Map<String, dynamic> shown(String id, int n) => {
          ...entry(id), 'bytes': 300,
          'book': {'id': id, 'seriesId': 'S1', 'seriesTitle': 'Silver Surfer', 'metadata': {'number': '$n'}},
        };
    await tester.runAsync(() async {
      await d.store!.put('B1', shown('B1', 1));
      await d.store!.put('B2', shown('B2', 2));
      server.goneSeries.add('S1');
      await sync.run();
    });
    expect(d.store!.books['B1']!['gone'], isTrue);
    await tester.pumpWidget(const MaterialApp(home: DownloadsScreen()));
    expect(find.text('3 pages · 0.0 MB · no longer on Komga'), findsNWidgets(2));
    expect(find.text('Downloaded · 2'), findsOneWidget, reason: 'still downloaded, still listed');
    expect(await tester.runAsync(() => OfflineKomga(d.store!).book('B1')), isNotNull, reason: 'still readable offline');

    await tester.runAsync(() async {
      server.goneSeries.clear(); // there after all (restored on Komga)
      await sync.run();
    });
    await tester.pump();
    expect(find.textContaining('no longer on Komga'), findsNothing);
    expect(find.text('3 pages · 0.0 MB'), findsNWidgets(2));
  });

  test("a downloaded book deleted on Komga with its offline progress unsent: the progress is dropped, and the message "
      'says so', () async {
    await offlineApi().setProgress('B2', 2);
    server.missing.add('B2');
    await sync.run();
    final r = sync.takeResult()!;
    expect(syncSummary(r), '1 book is no longer on Komga');
    expect(d.store!.progress.containsKey('B2'), isFalse);
    expect(d.isDownloaded('B2'), isTrue, reason: 'the download itself stays until removed');
  });

  test('a single downloaded book deleted on Komga (its series still there) is marked "no longer on Komga" too',
      () async {
    server.missing.add('B2'); // B2 deleted on Komga; S1 still lists B1
    await sync.run();
    expect(d.store!.books['B2']!['gone'], isTrue);
    expect(d.store!.books['B1']!['gone'], isNull);
    server.missing.remove('B2'); // back (restored on Komga): the mark goes
    await sync.run();
    expect(d.store!.books['B2']!['gone'], isNull);
  }); // found 2026-09-30 (missing-tests audit): only a whole deleted series was marked; the user chose to mark books too

  test("a book not in a series' list that has more pages isn't marked: unlisted there proves nothing", () async {
    server
      ..missing.add('B2')
      ..morePages = true;
    await sync.run();
    expect(d.store!.books['B2']!['gone'], isNull);
  });

  // ---- an EPUB's place: Komga's page for it is how far through the book times its page count, not a position
  // number (Windows, build 79: a book left at 31% opened offline at 12%)

  Map<String, dynamic> place(String ch, double total, int position) => {
        'device': {'id': 'x', 'name': 'BeDeReader (Android)'},
        'modified': '2026-10-06T12:00:00Z',
        'locator': {'href': 'OEBPS/$ch.xhtml', 'type': 'application/xhtml+xml',
          'locations': {'progression': 0.5, 'position': position, 'totalProgression': total}},
      };

  Future<void> epubB1() async {
    await d.store!.put('B1', {
      ...entry('B1'),
      'book': {'id': 'B1', 'seriesId': 'S1', 'readProgress': server.rp['B1'], 'media': {'mediaProfile': 'EPUB', 'pagesCount': 10}},
      'pages': [],
      'positions': [for (var i = 0; i < 40; i++) {'href': 'OEBPS/c1.xhtml', 'locations': {'position': i + 1}}],
    });
  }

  test('an EPUB read offline: its read progress page is Komga\'s (60% of a 10-page count: 6, not position 24), and '
      'its exact place goes to Komga as it is', () async {
    await epubB1();
    final off = offlineApi();
    await off.setEpubProgression('B1', place('c1', 0.6, 24));
    expect(d.store!.readProgressOf('B1')!['page'], 6);
    await sync.run();
    expect(server.writes, ['B1 place 0.6'], reason: 'the place itself, not "page 24" (Komga: 24 of 10 - finished)');
    expect(server.rp['B1']!['page'], 6);
    await off.markRead('B1');
    expect(d.store!.readProgressOf('B1')!['page'], 10, reason: "read to the end: Komga's page count, not 40 positions");
  });

  test("an EPUB read online on this device, or on another one: the downloaded copy's place follows", () async {
    await epubB1();
    // read online here: the client tells the downloads what it saved
    Komga.onProgressWritten!(server, ProgressWrite(bookId: 'B1', place: place('c1', 0.3, 12)));
    expect(d.store!.placeOf('B1')!['locator'], place('c1', 0.3, 12)['locator']);
    expect(d.store!.readProgressOf('B1')!['page'], 3);
    // read on another device: the next refresh brings its place
    server.places['B1'] = place('c1', 0.8, 32);
    server.rp['B1'] = {'page': 8, 'completed': false};
    // (later: a refresh asked in the same clock tick as a save here takes the save for the newer - as designed)
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await sync.run();
    expect(d.store!.readProgressOf('B1')!['page'], 8, reason: 'the refresh brought Komga\'s page');
    expect((d.store!.placeOf('B1')!['locator'] as Map)['locations'],
        containsPair('totalProgression', 0.8));
  });

  // ---- the exact place kept with its page (EPUB review 2026-10-06, S1-S9)

  double? totalOf(Map<String, dynamic>? p) =>
      (((p?['locator'] as Map?)?['locations'] as Map?)?['totalProgression'] as num?)?.toDouble();

  test('S1: read here to 30% while another device read to 70% - Komga wins, and its PLACE comes with its page (the 30% '
      'place stayed, opened offline, and could later be sent back over the 70%)', () async {
    await epubB1();
    final off = offlineApi();
    await off.setEpubProgression('B1', place('c1', 0.3, 12));
    server.rp['B1'] = {'page': 7, 'completed': false}; // the other device
    server.places['B1'] = place('c1', 0.7, 28);
    await sync.run();
    expect(server.writes, isEmpty, reason: 'Komga is further: nothing sent');
    expect(totalOf(await off.epubProgression('B1')), 0.7, reason: "offline it now opens at Komga's place");
  });

  test('S2: marked unread here, it has no place left (it reopened mid-book)', () async {
    await epubB1();
    final off = offlineApi();
    await off.setEpubProgression('B1', place('c1', 0.5, 20));
    await off.markUnread('B1');
    expect(await off.epubProgression('B1'), isNull);
  });

  test('S4: the download removed with a place read here not sent yet - the place itself still goes to Komga, not '
      'just the page', () async {
    await epubB1();
    final off = offlineApi();
    await off.setEpubProgression('B1', place('c1', 0.6, 24));
    await d.remove('B1');
    await sync.run();
    expect(server.writes, ['B1 place 0.6']);
  });

  test("S7: a place saved offline writes only the small progress file, not the downloads' whole index", () async {
    await epubB1();
    final index = File('${dir.path}${Platform.pathSeparator}index.json');
    final before = await index.readAsString();
    await offlineApi().setEpubProgression('B1', place('c1', 0.6, 24));
    await d.store!.saveProgress(); // (waits for the writes queued so far)
    expect(await index.readAsString(), before);
  });

  test("S9: an EPUB marked read online: its read progress here is Komga's page count, not page 0", () async {
    await epubB1();
    Komga.onProgressWritten!(server, const ProgressWrite(bookId: 'B1', completed: true));
    expect(d.store!.readProgressOf('B1')!['page'], 10);
  });

  test("a refresh asks Komga for a downloaded EPUB's place only when Komga changed its progress (it asked for every "
      'one, every time); a place Komga can\'t give keeps the one here', () async {
    await epubB1();
    server.rp['B1'] = {'page': 3, 'completed': false, 'lastModified': '2026-10-06T12:00:00Z'};
    server.places['B1'] = place('c1', 0.3, 12);
    Future<void> refresh() async {
      await Future<void>.delayed(const Duration(milliseconds: 30)); // (a save here in the same tick is the newer)
      await sync.run();
    }

    await refresh();
    expect(totalOf(d.store!.placeOf('B1')), 0.3);
    final asked = server.placeAsks;
    await refresh();
    expect(server.placeAsks, asked, reason: 'nothing changed on Komga: not asked again');
    // moved on another device within the same page: Komga's progress changed
    server.places['B1'] = place('c2', 0.33, 13);
    server.rp['B1'] = {...server.rp['B1']!, 'lastModified': '2026-10-06T12:05:00Z'};
    await refresh();
    expect(totalOf(d.store!.placeOf('B1')), 0.33);
    // changed again, but the place can't be had: the one here stays (asked again next time)
    server.rp['B1'] = {...server.rp['B1']!, 'lastModified': '2026-10-06T12:10:00Z'};
    server.placeFails = true;
    await refresh();
    expect(totalOf(d.store!.placeOf('B1')), 0.33);
  });

  test("S1, Komga winning but not saying its place: the place read here isn't kept with Komga's further page (it "
      'would open there, and go back over it)', () async {
    await epubB1();
    final off = offlineApi();
    await off.setEpubProgression('B1', place('c1', 0.3, 12));
    server.rp['B1'] = {'page': 7, 'completed': false};
    server.placeFails = true;
    await sync.run();
    expect(d.store!.readProgressOf('B1')!['page'], 7);
    expect(d.store!.placeOf('B1'), isNull, reason: 'the page alone, not the 30% place');
  });
}
