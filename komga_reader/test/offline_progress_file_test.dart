// Reading progress of downloaded books in its own small file (code review 2026-10-05, #36): a page settle wrote the
// whole index (every downloaded book), a few MB with hundreds of downloads. A store from before is moved over once,
// its index backed up first.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/offline/store.dart';

import 'support/helpers.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('komga_progress_file_test'));
  tearDown(() => deleteTemp(dir));

  File f(String name) => File('${dir.path}${Platform.pathSeparator}$name');

  // a store as builds before this one wrote it: progress inside index.json
  const oldIndex = {
    'v': 1,
    'books': {'B1': {'book': {'id': 'B1', 'seriesId': 'S1'}, 'pages': [], 'state': 'done'}},
    'progress': {'B1': {'page': 7, 'completed': false, 'at': '2026-10-01T10:00:00.000', 'synced': false}},
  };

  test("progress only in index.json (progress.json couldn't be written): read from there, nothing moved or backed "
      'up at load (user, 2026-10-07: no migrations); the next save puts it in progress.json', () async {
    await f('index.json').writeAsString(jsonEncode(oldIndex));

    final s = OfflineStore(dir);
    await s.load();
    expect(s.progress['B1']!['page'], 7, reason: 'progress read from the index');
    expect(s.unsynced, ['B1'], reason: 'still to send');
    expect(await f('index.v1.json').exists(), isFalse, reason: 'no backup made');
    expect(await f('progress.json').exists(), isFalse, reason: 'nothing written by a load');

    await s.save();
    final index = jsonDecode(await f('index.json').readAsString()) as Map;
    expect(index.containsKey('progress'), isFalse, reason: 'progress lives in progress.json once it can be written');
    expect(index['books'], oldIndex['books']);

    final again = OfflineStore(dir);
    await again.load();
    expect(again.progress['B1']!['page'], 7, reason: 'still there after a restart');
    expect(again.books.keys, ['B1']);
  });

  test("a page settle writes only the small progress file, not the index of every download", () async {
    final s = OfflineStore(dir);
    await s.put('B1', {'book': {'id': 'B1'}, 'pages': [], 'state': 'done'});
    final index = await f('index.json').readAsString();
    final indexTime = await f('index.json').lastModified();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await s.setProgress('B1', page: 4, completed: false);
    expect(await f('index.json').readAsString(), index, reason: 'the index untouched');
    expect(await f('index.json').lastModified(), indexTime);
    expect(((jsonDecode(await f('progress.json').readAsString()) as Map)['progress'] as Map)['B1']['page'], 4);
  });
}
