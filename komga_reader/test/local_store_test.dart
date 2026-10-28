// What the local libraries' scans found, kept on the device (lib/local/local_store.dart): a file each library, written
// only when it changed; progress and page sizes in small files of their own (the experiment rewrote one big index on
// every scan and on each book's first opening - local libraries' review, 2026-10-26).
import 'dart:async';
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

  // ---- review, 2026-10-26 --------------------------------------------------------------------------------------------
  test('loading while a write is still waiting keeps it - in memory and on disk', () async {
    final store = LocalStore(dir);
    await store.setProgress('b', page: 1, completed: false);
    unawaited(store.setProgress('b', page: 9, completed: false)); // (not waited for)
    await store.load();
    expect(store.progress['b']?['page'], 9);
    final again = LocalStore(dir);
    await again.load();
    expect(again.progress['b']?['page'], 9);
  });

  test('a library kept, removed and kept again without waiting still has its file', () async {
    final store = LocalStore(dir);
    unawaited(store.putLibrary(library('ll1')));
    unawaited(store.removeLibrary('ll1'));
    unawaited(store.putLibrary(library('ll1')));
    await store.written;
    expect(await File('${dir.path}/library-ll1.json').exists(), isTrue);
  });

  test("a write that fails doesn't stop the ones after it", () async {
    await Directory('${dir.path}/library-ll1.json').create(recursive: true); // (a folder in the way: can't be written)
    final store = LocalStore(dir);
    await expectLater(store.putLibrary(library('ll1')), throwsA(anything));
    await store.setProgress('b', page: 2, completed: false);
    expect(await File('${dir.path}/progress.json').exists(), isTrue);
  });

  test("a progress file that can't be read is copied aside before anything replaces it; one with bad entries keeps "
      'the good ones - loading never fails for it', () async {
    await dir.create(recursive: true);
    await File('${dir.path}/progress.json').writeAsString('{"b1": {"page": 4, "comp');
    final store = LocalStore(dir);
    await store.load();
    await store.setProgress('b2', page: 1, completed: false);
    expect(await File('${dir.path}/progress.json.unreadable').readAsString(), '{"b1": {"page": 4, "comp');

    await File('${dir.path}/progress.json').writeAsString('{"b1": 5, "b2": {"page": 3, "completed": false}}');
    await File('${dir.path}/sizes.json').writeAsString('{"b1": [800, null], "b2": [800, 1200]}');
    await store.load();
    expect(store.progress.keys, ['b2']);
    expect(store.sizes, {'b2': [800, 1200]});
  });

  test("a file's date is kept as a moment in time: the same file whatever the device's time zone (kept as local time, "
      'every book looked changed after the iPad crossed one)', () async {
    final local = DateTime(2026, 10, 1, 12, 30);
    final store = LocalStore(dir);
    await store.putLibrary(LibraryIndex('ll1', const [], [
      LocalBook(id: 'b', libraryId: 'll1', seriesId: 's', path: '/b.cbz', size: 5, modified: local, title: 'b'),
    ]));
    expect(await File('${dir.path}/library-ll1.json').readAsString(), contains(local.toUtc().toIso8601String()));
    final again = LocalStore(dir);
    await again.load();
    final b = again.libraries['ll1']!.books['b']!;
    expect(b.sameFile(5, local), isTrue);
    expect(b.sameFile(5, local.toUtc()), isTrue, reason: 'the same moment, written either way');
  });

  test('page turns in a row are one write, of the last; a write cut short (*.tmp) is cleared at the next start; the '
      "series' fields ComicInfo gives are kept", () async {
    final store = LocalStore(dir);
    for (var p = 1; p <= 20; p++) {
      unawaited(store.setProgress('b', page: p, completed: false));
    }
    await store.written;
    expect(store.writes, lessThanOrEqualTo(2));
    final again = LocalStore(dir);
    await again.load();
    expect(again.progress['b']?['page'], 20);

    await File('${dir.path}/library-x.json.tmp').writeAsString('half');
    await again.putLibrary(LibraryIndex('ll1', const [], [
      LocalBook(id: 'b', libraryId: 'll1', seriesId: 's', path: '/b.cbz', size: 5, modified: modified, title: 'b',
          rightToLeft: true, publisher: 'Dark Horse', genres: const ['Fantasy'], count: 41),
    ]));
    final third = LocalStore(dir);
    await third.load();
    expect(await File('${dir.path}/library-x.json.tmp').exists(), isFalse);
    final b = third.libraries['ll1']!.books['b']!;
    expect((b.rightToLeft, b.publisher, b.count), (true, 'Dark Horse', 41));
    expect(b.genres, ['Fantasy']);
  });
}
