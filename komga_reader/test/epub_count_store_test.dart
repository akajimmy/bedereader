// Remembered page counts on the device (lib/epub/count_store.dart): one file per book, its last few layouts.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/epub/count_store.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('epub-counts-test'));
  tearDown(() => root.deleteSync(recursive: true));

  EpubCounts counts(int n) => EpubCounts([100 * n, 50], [[0, 40 * n], [0]]);

  test('kept per book and layout; a book keeps the six layouts saved most recently; another book is its own file',
      () async {
    final store = FileCountStore(root: root);
    expect(await store.load('B1', 'L0'), isNull, reason: 'nothing yet');
    for (var i = 0; i < 6; i++) {
      await store.save('B1', 'L$i', counts(i + 1));
    }
    await store.save('B1', 'L0', counts(8)); // the first saved again: now the newest
    await store.save('B1', 'L6', counts(7)); // a seventh
    expect(await store.load('B1', 'L1'), isNull, reason: 'the one saved longest ago let go of');
    expect((await store.load('B1', 'L0'))!.lengths, counts(8).lengths, reason: 'saved again: kept, its new counts');
    final last = (await store.load('B1', 'L6'))!;
    expect(last.lengths, counts(7).lengths);
    expect(last.starts, counts(7).starts);
    expect((await store.load('B1', 'L2'))!.lengths, counts(3).lengths);
    await store.save('B2', 'L0', counts(9));
    expect((await store.load('B2', 'L0'))!.lengths, counts(9).lengths);
    expect(await store.load('B2', 'L6'), isNull);
    // read again from the files (a new start of the app)
    expect((await FileCountStore(root: root).load('B1', 'L6'))!.starts, counts(7).starts);
  });

  test("a damaged file is no counts (the book is counted again), and it's written afresh", () async {
    final store = FileCountStore(root: root);
    await store.save('B1', 'L0', counts(1));
    final file = root.listSync().whereType<File>().single;
    file.writeAsStringSync('{"L0": {"lengths": [1], "starts": "nope"');
    expect(await store.load('B1', 'L0'), isNull);
    await store.save('B1', 'L1', counts(2));
    expect((await store.load('B1', 'L1'))!.lengths, counts(2).lengths);
  });
}
