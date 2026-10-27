// What the local libraries' scans found, kept on the device (lib/local/local_store.dart): a file each library, written
// only when it changed; progress and page sizes in small files of their own (the experiment rewrote one big index on
// every scan and on each book's first opening - local libraries' review, 2026-10-26).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/local/book_names.dart';
import 'package:komga_reader/local/local_store.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('local_store'));
  tearDown(() => dir.delete(recursive: true));

  final modified = DateTime.utc(2026, 10, 1, 12);
  LibraryIndex library(String id, {String title = 'Saga #1', int books = 2}) => LibraryIndex(id, [
        LocalSeries(id: 'ls-$id', libraryId: id, name: 'Saga'),
      ], [
        for (var i = 1; i <= books; i++)
          LocalBook(
            id: 'lb-$id-$i', libraryId: id, seriesId: 'ls-$id', path: '/books/$id/Saga #$i.cbz', size: 1000 + i,
            modified: modified, title: i == 1 ? title : 'Saga #$i', pages: 20, cover: '01.jpg', number: '$i',
            numberSort: i, released: DateTime.utc(2012, 3), precision: DatePrecision.month,
            authors: const [('Brian K. Vaughan', 'writer')], readLists: const [ReadListPlace('lr1', 0, 2)], inside: 1,
          ),
      ]);

  test('what was kept comes back as it was: the series once, each book with its file, numbers, date and people',
      () async {
    final store = LocalStore(dir);
    await store.putLibrary(library('ll1'));
    await store.setProgress('lb-ll1-1', page: 7, completed: false, at: modified);
    await store.setSizes('lb-ll1-1', [1988, 3056, 0, 0]);
    final again = LocalStore(dir);
    await again.load();
    final b = again.libraries['ll1']!.books['lb-ll1-1']!;
    expect((b.path, b.size, b.modified, b.pages, b.number, b.numberSort), ('/books/ll1/Saga #1.cbz', 1001, modified, 20, '1', 1));
    expect((b.released, b.precision), (DateTime.utc(2012, 3), DatePrecision.month));
    expect(b.authors, [('Brian K. Vaughan', 'writer')]);
    expect(b.readLists.single.id, 'lr1');
    expect(again.libraries['ll1']!.series['ls-ll1']!.name, 'Saga');
    expect(again.progress['lb-ll1-1'], {'page': 7, 'completed': false, 'at': modified.toIso8601String()});
    expect(again.sizes['lb-ll1-1'], [1988, 3056, 0, 0]);
    expect(b.sameFile(1001, modified), isTrue);
    expect(b.sameFile(1002, modified), isFalse, reason: 'changed: opened again');
  });

  test('a scan that found nothing new writes nothing; one library changed rewrites its file only - not after a '
      'restart either', () async {
    final store = LocalStore(dir);
    await store.putLibrary(library('ll1'));
    await store.putLibrary(library('ll2'));
    expect(store.writes, 2);
    await store.putLibrary(library('ll1'));
    await store.putLibrary(library('ll2'));
    expect(store.writes, 2, reason: 'nothing changed');
    await store.putLibrary(library('ll2', title: 'Saga #1 (renamed)'));
    expect(store.writes, 3, reason: 'one file');

    final again = LocalStore(dir);
    await again.load();
    await again.putLibrary(library('ll1'));
    expect(again.writes, 0, reason: 'the same as on disk');
  });

  test("reading progress and a book's page sizes are written to their own small files, not with the library",
      () async {
    final store = LocalStore(dir);
    await store.putLibrary(library('ll1', books: 300));
    final libraryFile = File('${dir.path}/library-ll1.json');
    final before = await libraryFile.lastModified();
    await store.setProgress('lb-ll1-1', page: 3, completed: false);
    await store.setSizes('lb-ll1-2', [800, 1200]);
    expect(await libraryFile.lastModified(), before);
    expect(await File('${dir.path}/progress.json').exists(), isTrue);
    expect(await File('${dir.path}/sizes.json').exists(), isTrue);
  });

  test('a damaged file, or one in another format, is read as nothing (its library scanned again) - never fatal; a '
      'library removed loses its file, not its progress', () async {
    final store = LocalStore(dir);
    await store.putLibrary(library('ll1'));
    await store.putLibrary(library('ll2'));
    await store.setProgress('lb-ll1-1', page: 3, completed: false);
    await File('${dir.path}/library-ll2.json').writeAsString('{"v": 1, "books": [{"id": ');
    await File('${dir.path}/library-ll3.json').writeAsString('{"v": 99, "books": []}');
    final again = LocalStore(dir);
    await again.load();
    expect(again.libraries.keys, ['ll1']);

    await again.removeLibrary('ll1');
    await again.written;
    expect(await File('${dir.path}/library-ll1.json').exists(), isFalse);
    expect(again.progress.keys, ['lb-ll1-1']);
  });
}
