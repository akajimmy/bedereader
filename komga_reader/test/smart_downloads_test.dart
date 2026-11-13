import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/api.dart';
import 'package:komga_reader/offline/downloads.dart';
import 'package:komga_reader/offline/smart_downloads.dart';
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
    await s.load();
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
