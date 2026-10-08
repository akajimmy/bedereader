// Reading progress of downloaded books in its own small file (code review 2026-10-05, #36): a page settle wrote the
// whole index (every downloaded book), a few MB with hundreds of downloads. While progress.json can't be written,
// index.json carries the progress instead.
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
  Map indexProgress() => (jsonDecode(f('index.json').readAsStringSync()) as Map)['progress'] as Map? ?? {};

  test("progress.json can't be written: a page settle puts the progress in index.json, a restart reads it from there; "
      'the next save that can write it moves it to progress.json', () async {
    // its temporary file can't be created: a folder is in the way
    final blocker = await Directory('${dir.path}${Platform.pathSeparator}progress.json.tmp').create(recursive: true);
    final s = OfflineStore(dir);
    await s.put('B1', {'book': {'id': 'B1', 'seriesId': 'S1'}, 'pages': [], 'state': 'done'});
    await s.setProgress('B1', page: 7, completed: false);
    expect(await f('progress.json').exists(), isFalse);
    expect((indexProgress()['B1'] as Map)['page'], 7, reason: 'the page settle went to the index instead');

    await blocker.delete();
    final again = OfflineStore(dir);
    await again.load();
    expect(again.progress['B1']!['page'], 7, reason: 'progress read from the index');
    expect(again.unsynced, ['B1'], reason: 'still to send');
    expect(await f('progress.json').exists(), isFalse, reason: 'nothing written by a load');

    await again.save();
    final index = jsonDecode(await f('index.json').readAsString()) as Map;
    expect(index.containsKey('progress'), isFalse, reason: 'progress lives in progress.json once it can be written');
    expect((index['books'] as Map).keys, ['B1']);

    final third = OfflineStore(dir);
    await third.load();
    expect(third.progress['B1']!['page'], 7, reason: 'still there after a restart');
    expect(third.books.keys, ['B1']);
  });

  test("a page settle (an EPUB's place too) writes only the small progress file, not the index of every download "
      '(EPUB review 2026-10-06, S7)', () async {
    final s = OfflineStore(dir);
    await s.put('B1', {'book': {'id': 'B1'}, 'pages': [], 'state': 'done'});
    final index = await f('index.json').readAsString();
    final indexTime = await f('index.json').lastModified();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    const place = {'locator': {'href': 'OEBPS/c1.xhtml', 'locations': {'totalProgression': 0.6}}};
    await s.setProgress('B1', page: 4, completed: false, place: place);
    expect(await f('index.json').readAsString(), index, reason: 'the index untouched');
    expect(await f('index.json').lastModified(), indexTime);
    final saved = ((jsonDecode(await f('progress.json').readAsString()) as Map)['progress'] as Map)['B1'] as Map;
    expect(saved['page'], 4);
    expect(saved['place'], place);
  });
}
