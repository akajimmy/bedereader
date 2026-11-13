import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/offline/downloads.dart';
import 'package:komga_reader/offline/smart_downloads.dart';
import 'package:komga_reader/pins.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/library_server.dart';
import 'support/no_network.dart';
import 'support/settle.dart';

/// Series S1 of six books, B1 to B6 (also read list RL1, in reverse order); [read] / [started] say which are read and
/// part way through, as Komga would report them.
class SeriesServer extends LibraryServer {
  final Set<String> read = {}, started = {};
  bool down = false; // Komga not answering the rules' questions
  int seriesAsks = 0;

  static const ids = ['B1', 'B2', 'B3', 'B4', 'B5', 'B6'];

  Map<String, dynamic> _b(String id) => {
        'id': id, 'seriesId': 'S1', 'seriesTitle': 'Silver Surfer', 'libraryId': 'L1', 'name': id,
        'metadata': {'title': 'T$id', 'number': id.substring(1), 'numberSort': int.parse(id.substring(1))},
        'media': {'pagesCount': 3}, 'sizeBytes': 300,
        'readProgress': read.contains(id)
            ? {'page': 3, 'completed': true}
            : started.contains(id) ? {'page': 1, 'completed': false} : null,
      };

  bool _unread(String id) => !read.contains(id);

  @override
  Future<Map<String, dynamic>?> book(String id) async {
    if (down) throw KomgaUnreachable(baseUrl);
    return _b(id);
  }

  @override
  Future<Map<String, dynamic>> seriesBooks(String seriesId,
      {List<String>? readStatus, String sort = 'metadata.numberSort,asc', int page = 0, int size = 500}) async {
    seriesAsks++;
    if (down) throw KomgaUnreachable(baseUrl);
    final all = [for (final id in ids) if (readStatus == null || _unread(id)) _b(id)];
    return {'content': all.take(size).toList(), 'totalElements': all.length};
  }

  @override
  Future<Map<String, dynamic>> readListBooks(String readListId,
      {List<String>? readStatus, int page = 0, int size = 1000}) async {
    if (down) throw KomgaUnreachable(baseUrl);
    final all = [for (final id in ids.reversed) if (readStatus == null || _unread(id)) _b(id)];
    return {'content': all.take(size).toList(), 'totalElements': all.length};
  }
}

/// Library L1 for pins: series S2 and S1 (in that order: the pin sorts them so), S2 of two unread books, S1 of
/// three; and the library's books, newest first. Records what each asks for.
class PinServer extends LibraryServer {
  final asked = <String>[];
  Map<String, dynamic> _b(String s, int n) =>
      {'id': '$s-$n', 'seriesId': s, 'seriesTitle': s, 'name': '$s-$n', 'metadata': {'number': '$n'}};

  @override
  Future<Map<String, dynamic>> series({String? libraryId, String? collectionId, List<String>? readStatus,
      String sort = 'metadata.titleSort,asc', int page = 0, int size = 60}) async {
    asked.add('series $libraryId ${readStatus?.join('+')} $sort');
    return {'content': [{'id': 'S2'}, {'id': 'S1'}], 'totalElements': 2};
  }

  @override
  Future<Map<String, dynamic>> seriesBooks(String seriesId,
      {List<String>? readStatus, String sort = 'metadata.numberSort,asc', int page = 0, int size = 500}) async {
    asked.add('books of $seriesId ${readStatus?.join('+')} $size');
    final all = [for (var n = 1; n <= (seriesId == 'S2' ? 2 : 3); n++) _b(seriesId, n)];
    return {'content': all.take(size).toList(), 'totalElements': all.length};
  }

  @override
  Future<Map<String, dynamic>> books({String? libraryId, List<String>? readStatus,
      String sort = 'metadata.releaseDate,desc', int page = 0, int size = 60}) async {
    asked.add('books $libraryId ${readStatus?.join('+')} $sort $size');
    final all = [for (var n = 9; n >= 1; n--) _b('S1', n)];
    return {'content': all.take(size).toList(), 'totalElements': all.length};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  final d = Downloads.instance, s = SmartDownloads.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    d.reset();
    s.reset();
    dir = await Directory.systemTemp.createTemp('komga_smart_test');
  });
  tearDown(() async {
    d.pauseAll();
    for (var i = 0; i < 300 && d.busy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    d.paused = false;
    await d.store?.written;
    await deleteTemp(dir);
  });

  Future<SeriesServer> start() async {
    final api = noNetwork(SeriesServer.new);
    await d.attach(api, root: dir);
    await s.start();
    return api;
  }

  List<String> downloaded() => [for (final id in SeriesServer.ids) if (d.isDownloaded(id)) id];

  test('a series rule keeps its next 3 unread downloaded, as the rule\'s; once read, a book goes at the next top-up '
      'and the next one comes in (user, 2026-11-12)', () async {
    final api = await start();
    api.read.add('B1');
    await s.setRule(RuleKind.series, 'S1', 'Silver Surfer', 3);
    await s.topUp();
    await settle(d);
    expect(downloaded(), ['B2', 'B3', 'B4']);
    expect([for (final id in downloaded()) s.isRuled(id)], everyElement(isTrue), reason: "the rule's mark");
    expect(s.keeping(s.rules.single), 3);

    api.read.add('B2'); // read to the end
    await s.topUp();
    await settle(d);
    expect(downloaded(), ['B3', 'B4', 'B5'], reason: 'B2 out once read, B5 in');
    expect(s.isRuled('B2'), isFalse);
  });

  test('the default is 3, and a read list keeps its next ones in its own order', () async {
    final api = await start();
    api.read.add('B6');
    await s.setRule(RuleKind.readList, 'RL1', 'Cosmic', SmartRule.defaultKeep);
    await s.topUp();
    await settle(d);
    expect(downloaded(), ['B3', 'B4', 'B5'], reason: 'the list runs B6, B5, B4, B3...: B6 read');
  });

  test("books you downloaded yourself are never a rule's, nor removed by it - nor is one of its books you then "
      'download yourself', () async {
    final api = await start();
    await d.add([{'id': 'B1', 'seriesTitle': 'Silver Surfer', 'metadata': {'number': '1'}}]);
    await settle(d);
    await s.setRule(RuleKind.series, 'S1', 'Silver Surfer', 2);
    await s.topUp();
    await settle(d);
    expect(downloaded(), ['B1', 'B2']);
    expect(s.isRuled('B1'), isFalse, reason: 'yours already');
    expect(s.isRuled('B2'), isTrue);

    await d.add([{'id': 'B2', 'seriesTitle': 'Silver Surfer', 'metadata': {'number': '2'}}]); // Download on it
    expect(s.isRuled('B2'), isFalse, reason: 'yours now');
    api.read.addAll(['B1', 'B2']);
    await s.topUp();
    await settle(d);
    expect(downloaded(), containsAll(['B1', 'B2']), reason: 'read, but yours');
    expect(downloaded(), containsAll(['B3', 'B4']));
  });

  test('a rule taken off: its books not started go, one part way through stays until it is read', () async {
    final api = await start();
    await s.setRule(RuleKind.series, 'S1', 'Silver Surfer', 3);
    await s.topUp();
    await settle(d);
    expect(downloaded(), ['B1', 'B2', 'B3']);
    api.started.add('B1');
    await s.setRule(RuleKind.series, 'S1', 'Silver Surfer', 0);
    await s.topUp();
    await settle(d);
    expect(downloaded(), ['B1'], reason: 'B1 started: kept');
    api
      ..started.remove('B1')
      ..read.add('B1');
    await s.topUp();
    expect(downloaded(), isEmpty, reason: 'read now: gone');
  });

  test("Komga not answering: nothing of a rule's is removed, and it tops up once it answers", () async {
    final api = await start();
    await s.setRule(RuleKind.series, 'S1', 'Silver Surfer', 2);
    await s.topUp();
    await settle(d);
    api
      ..read.addAll(['B1', 'B2'])
      ..down = true;
    await s.topUp();
    expect(downloaded(), ['B1', 'B2'], reason: "can't tell they're read: kept");
    api.down = false;
    await s.topUp();
    await settle(d);
    expect(downloaded(), ['B3', 'B4']);
  });

  test('Smart downloads off: no rule tops up, and nothing is removed', () async {
    final api = await start();
    await s.setRule(RuleKind.series, 'S1', 'Silver Surfer', 2);
    await s.topUp();
    await settle(d);
    await s.setOn(false);
    api.read.addAll(['B1', 'B2']);
    await s.topUp();
    expect(downloaded(), ['B1', 'B2']);
    expect(d.queue, isEmpty);
  });

  test('the download limit full: the rule\'s books wait in the queue, and Downloads can say the limit is reached',
      () async {
    await start();
    await d.setCap(500); // room for one 300-byte book
    await s.setRule(RuleKind.series, 'S1', 'Silver Surfer', 3);
    await s.topUp();
    await waitUntil(() => d.queue.isNotEmpty && d.queue.every((j) => j.state == JobState.failed));
    expect(downloaded(), ['B1']);
    expect(s.limitReached, isTrue);
  });

  test("a pin's next books are its first unread ones in its own order: a library of series, series by series in the "
      "pin's sort, each by number; a library's books, in the pin's sort (user, 2026-11-12: 'first 3 of the pin')",
      () async {
    final api = noNetwork(PinServer.new);
    const series = Pin(name: 'Events', kind: 'library', id: 'L1', title: 'Events', sort: 'title:desc');
    final r = SmartRule(kind: RuleKind.pin, id: SmartRule.pinKey(series), title: 'Events', pin: series);
    expect([for (final b in await SmartDownloads.nextBooks(api, r)) b['id']], ['S2-1', 'S2-2', 'S1-1']);
    expect(api.asked, [
      'series L1 UNREAD+IN_PROGRESS metadata.titleSort,desc', // (the pin's own sort; read series left out)
      'books of S2 UNREAD+IN_PROGRESS 3',
      'books of S1 UNREAD+IN_PROGRESS 1', // (only as many as are still wanted)
    ]);

    api.asked.clear();
    const books = Pin(name: 'New', kind: 'library', id: 'L1', title: 'Events', mode: 'books', sort: 'added');
    final rb = SmartRule(kind: RuleKind.pin, id: SmartRule.pinKey(books), title: 'New', keep: 2, pin: books);
    expect([for (final b in await SmartDownloads.nextBooks(api, rb)) b['id']], ['S1-9', 'S1-8']);
    expect(api.asked, ['books L1 UNREAD+IN_PROGRESS createdDate,desc 2']);
  });

  test("a pinned series or read list is that series' or list's rule; a pinned book, or a view of lists, has none",
      () async {
    await start();
    const pinned = Pin(name: 'Surfer', kind: 'series', id: 'S1', title: 'Silver Surfer');
    await s.setPinRule(pinned, 2);
    expect(s.ruleFor(RuleKind.series, 'S1')!.keep, 2);
    expect(s.ruleForPin(pinned)!.keep, 2);
    expect(SmartDownloads.pinCanKeep(const Pin(name: 'b', kind: 'book', id: 'B1', title: 'b')), isFalse);
    expect(SmartDownloads.pinCanKeep(const Pin(name: 'l', kind: 'library', mode: 'readLists', title: 'l')), isFalse);
    expect(SmartDownloads.pinCanKeep(const Pin(name: 'c', kind: 'collection', id: 'C1', title: 'c')), isTrue);
  });

  test("nothing tops up until it's started - the app starts it once offline mode is applied (code review, "
      '2026-11-12: the local libraries opening started a top-up before, asking Komga at a forced-offline start)',
      () async {
    final api = noNetwork(SeriesServer.new);
    await d.attach(api, root: dir);
    await s.load();
    await s.setRule(RuleKind.series, 'S1', 'Silver Surfer', 2);
    await s.topUp();
    expect(api.seriesAsks, 0, reason: 'Komga not asked');
    expect(d.queue, isEmpty);
    await s.start();
    await settle(d);
    expect(downloaded(), ['B1', 'B2']);
  });

  test("Delete once read: Ask doesn't ask about a rule's book - the rule removes it (code review, 2026-11-12: a Keep "
      'was then overridden by the top-up)', () async {
    final api = await start();
    await d.setDeleteRead(DeleteRead.ask);
    await s.setRule(RuleKind.series, 'S1', 'Silver Surfer', 2);
    await s.topUp();
    await settle(d);
    api.read.add('B1');
    d.bookFinished('B1');
    expect(d.askPending, isEmpty);
    await s.topUp();
    await settle(d);
    expect(downloaded(), ['B2', 'B3']);
  });

  test("a pin's rule is found again after its list is renamed (the pin retitled), and whatever its sort's spelling "
      '(code review, 2026-11-12)', () async {
    await start();
    s.on = false; // (the rules only: no top-up asks for these views)
    const pin = Pin(name: 'Cosmic', kind: 'collection', id: 'C1', title: 'Cosmic', sort: 'added');
    await s.setPinRule(pin, 2);
    expect(s.ruleForPin(pin.retitled('Cosmic', 'Cosmic tales'))?.keep, 2);
    // a library pin's sort, with its direction or without (Pin.fullSort - as Pins tells views apart)
    await s.setPinRule(const Pin(name: 'New', kind: 'library', id: 'L1', title: 'Events', sort: 'added'), 1);
    expect(s.ruleForPin(const Pin(name: 'x', kind: 'library', id: 'L1', title: 'Events', sort: 'added:desc'))?.keep,
        1);
    expect(s.ruleForPin(const Pin(name: 'x', kind: 'collection', id: 'C2', title: 'Cosmic')), isNull);
  });

  test("a top-up that fails part way doesn't throw out of topUp (its callers don't wait on it): logged, and the next "
      'one runs (code review, 2026-11-12)', () async {
    final api = await start();
    await s.setRule(RuleKind.series, 'S1', 'Silver Surfer', 1);
    SmartDownloads.beforeSave = () => throw const FileSystemException('disk full');
    addTearDown(() => SmartDownloads.beforeSave = null);
    await s.topUp(); // (it threw out of here)
    SmartDownloads.beforeSave = null;
    await settle(d);
    api.read.add('B1');
    await s.topUp();
    await settle(d);
    expect(downloaded(), ['B2']);
  });

  test('a top-up that changes nothing tells no one (every poster mark listens - code review, 2026-11-12)', () async {
    await start();
    await s.setRule(RuleKind.series, 'S1', 'Silver Surfer', 2);
    await s.topUp();
    await settle(d);
    var told = 0;
    void count() => told++;
    s.addListener(count);
    addTearDown(() => s.removeListener(count));
    await s.topUp();
    expect(told, 0);
  });

  test('rules and their books are kept on the device, across a restart', () async {
    await start();
    await s.setRule(RuleKind.series, 'S1', 'Silver Surfer', 2);
    await s.topUp();
    await settle(d);
    s.reset();
    await s.load();
    expect(s.ruleFor(RuleKind.series, 'S1')!.keep, 2);
    expect(s.isRuled('B1'), isTrue);
  });
}
