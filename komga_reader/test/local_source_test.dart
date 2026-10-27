// The local libraries as a source of books (lib/local/local_scan.dart, local_source.dart): a folder scanned into the
// local store, and the questions every source answers - from the library's own files, on this machine.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/combined_source.dart';
import 'package:komga_reader/local/book_names.dart';
import 'package:komga_reader/local/library_fs.dart';
import 'package:komga_reader/local/local_library.dart';
import 'package:komga_reader/local/local_scan.dart';
import 'package:komga_reader/local/local_source.dart';
import 'package:komga_reader/reader/epub_renderer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/zip_writer.dart';

/// This machine's files, counting the books opened - and a file that "doesn't answer", as a share away would.
class _Fs implements LibraryFs {
  final inner = LocalFs();
  final opened = <String>[];
  int held = 0; // files open now
  String? away;

  @override
  Future<bool> exists(String folder) => inner.exists(folder);
  @override
  Future<bool> placeAnswers(String folder) => inner.placeAnswers(folder);
  @override
  Stream<FsEntry> list(String folder, {void Function(String folder, Object error)? onUnreadable}) =>
      inner.list(folder, onUnreadable: onUnreadable);
  @override
  Future<LibraryFile> open(String path) async {
    if (away != null && path.endsWith(away!)) throw const _Away();
    opened.add(path.replaceAll('\\', '/').split('/').last);
    final f = await inner.open(path);
    held++;
    return _Held(f, this);
  }

  @override
  Future<FolderLook> look(String folder) => inner.look(folder);
  @override
  FileTrouble classify(Object error) => error is _Away ? FileTrouble.noAnswer : inner.classify(error);
}

class _Away implements Exception {
  const _Away();
}

/// A file of [_Fs], counted as held until it's closed.
class _Held implements LibraryFile {
  _Held(this.f, this.fs);
  final LibraryFile f;
  final _Fs fs;
  bool _closed = false;
  @override
  Future<int> length() => f.length();
  @override
  Future<Uint8List> readRange(int offset, int length) => f.readRange(offset, length);
  @override
  Future<void> close() async {
    if (!_closed) fs.held--;
    _closed = true;
    await f.close();
  }
}

void main() {
  late Directory root, data;
  late _Fs fs;
  final page = Uint8List.fromList([...pngHead(800, 1200), ...List.filled(100, 1)]);

  Future<void> put(String rel, List<int> bytes) async {
    final f = File('${root.path}/$rel');
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes);
  }

  Uint8List cbz({String? info, int pages = 2}) =>
      zipOf({for (var i = pages; i >= 1; i--) 'p$i.png': page, if (info != null) 'ComicInfo.xml': info});

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('local_lib');
    data = await Directory.systemTemp.createTemp('local_data');
    fs = _Fs();
    await put('Saga (2012)/Saga #10 (2014).cbz', cbz(pages: 3));
    await put('Saga (2012)/Saga #2 (2012).cbz', cbz(info: '<ComicInfo><Title>Chapter Two</Title></ComicInfo>'));
    await put('Saga (2012)/Saga Annual.cbz', cbz());
    await put('Loose One-Shot (2020).cbz', cbz());
    await put('_oneshots/Frankenstein - Mary Shelley.epub', zipOf({
      'META-INF/container.xml': '<container><rootfile full-path="OPS/book.opf"/></container>',
      'OPS/book.opf': '<package><metadata><dc:title>Frankenstein</dc:title><dc:creator>Mary Shelley</dc:creator>'
          '</metadata><manifest><item id="c" href="cover.png" media-type="image/png"/></manifest></package>',
      'OPS/cover.png': page,
    }));
    await put('Saga (2012)/notes.txt', [1]);
  });
  final sources = <LocalSource>[];
  tearDown(() async {
    for (final s in sources) {
      await s.closeFiles();
    }
    sources.clear();
    if (await root.exists()) await root.delete(recursive: true);
    await data.delete(recursive: true);
  });

  LocalLibrary library() => LocalLibrary.at(root.path);
  Future<LocalSource> open() async {
    final s = await LocalSource.open(data, [library()], fsFor: (_) => fs);
    sources.add(s);
    return s;
  }

  test('a scan: one folder per series, a book loose or in _oneshots a book of its own; numbers from the names, a '
      "title from ComicInfo, an EPUB's own title and author; a book with no number after the numbered ones", () async {
    final r = await scanLibrary(fs, library(), null);
    expect(r.report.clean, isTrue);
    final books = {for (final b in r.index.books.values) b.path.replaceAll('\\', '/').split('/').last: b};
    expect(books.keys, unorderedEquals(['Saga #10 (2014).cbz', 'Saga #2 (2012).cbz', 'Saga Annual.cbz',
        'Loose One-Shot (2020).cbz', 'Frankenstein - Mary Shelley.epub']));
    final saga10 = books['Saga #10 (2014).cbz']!, saga2 = books['Saga #2 (2012).cbz']!;
    expect((saga10.number, saga10.numberSort, saga10.pages, saga10.cover), ('10', 10, 3, 'p1.png'));
    expect((saga2.title, saga2.released), ('Chapter Two', DateTime.utc(2012)));
    expect(books['Saga Annual.cbz']!.numberSort, greaterThan(10), reason: 'no number: after the numbered ones');
    expect(saga10.seriesId, saga2.seriesId);
    final epub = books['Frankenstein - Mary Shelley.epub']!;
    expect((epub.title, epub.epub, epub.cover), ('Frankenstein', true, 'OPS/cover.png'));
    expect(epub.authors, [('Mary Shelley', 'writer')]);
    expect(epub.seriesId, isNot(books['Loose One-Shot (2020).cbz']!.seriesId), reason: 'one-shots: each its own');
    expect({for (final s in r.index.series.values) s.name}, {'Saga (2012)', 'Loose One-Shot (2020)',
        'Frankenstein - Mary Shelley'});
  });

  test('scanned again: a file unchanged since is not opened; one changed is', () async {
    final first = await scanLibrary(fs, library(), null);
    fs.opened.clear();
    var again = await scanLibrary(fs, library(), first.index);
    expect(fs.opened, isEmpty);
    await put('Saga (2012)/Saga #2 (2012).cbz', cbz(pages: 5));
    again = await scanLibrary(fs, library(), again.index);
    expect(fs.opened, ['Saga #2 (2012).cbz']);
    expect(again.index.books.values.firstWhere((b) => b.path.contains('Saga #2')).pages, 5);
  });

  test("a damaged file is left out and said; a file that doesn't answer keeps its book; a library whose folder "
      'looks deleted - or is out of reach - keeps all its books', () async {
    final first = await scanLibrary(fs, library(), null);
    await put('Saga (2012)/Broken.cbz', [1, 2, 3]);
    fs.away = 'Saga #10 (2014).cbz';
    await put('Saga (2012)/Saga #10 (2014).cbz', cbz(pages: 4)); // (changed - but it doesn't answer)
    final r = await scanLibrary(fs, library(), first.index);
    expect(r.report.leftOut.single, endsWith('Broken.cbz'));
    expect(r.report.count(FileTrouble.noAnswer), 1);
    expect(r.index.books.values.firstWhere((b) => b.path.contains('Saga #10')).pages, 3, reason: 'as it was');

    await root.delete(recursive: true);
    final gone = await scanLibrary(fs, library(), first.index);
    expect((gone.report.reached, gone.report.missing), (false, true));
    expect(gone.index.books.length, first.index.books.length);
  });

  test("the source answers from the scan: series and books as Komga's JSON, pages with their sizes (measured once, "
      'then kept), a page\'s bytes; progress kept on the device; On deck', () async {
    final s = await open();
    await s.rescan();
    final series = (await s.series())['content'] as List;
    expect([for (final x in series) x['name']], ['Frankenstein - Mary Shelley', 'Loose One-Shot (2020)', 'Saga (2012)']);
    final saga = series.last as Map;
    expect(saga['booksCount'], 3);
    final books = (await s.seriesBooks(saga['id'] as String))['content'] as List;
    expect([for (final b in books) b['metadata']['number']], ['2', '10', '']);
    final id = books.first['id'] as String;
    expect(isLocalId(id), isTrue);
    expect(await s.pages(id), [
      {'number': 1, 'mediaType': 'image/png', 'width': 800, 'height': 1200},
      {'number': 2, 'mediaType': 'image/png', 'width': 800, 'height': 1200},
    ]);
    await s.store.written;
    expect(s.store.sizes[id], [800, 1200, 800, 1200]);
    expect(await s.pageBytes(id, 2), page);

    await s.markRead(id);
    expect(s.readProgressOf(id)?['completed'], isTrue);
    expect([for (final b in (await s.onDeck())['content'] as List) b['metadata']['number']], ['10'],
        reason: 'the next one, its series started');
    await s.markUnread(id);
    expect(s.readProgressOf(id), isNull);
  });

  test('a comic asked for several times at once (the page strip and the reader) is opened once, and every file '
      'opened is closed with the source (two opens at once left one open - the experiment\'s review)', () async {
    final s = await open();
    await s.rescan();
    final id = ((await s.books(size: 100))['content'] as List)
        .firstWhere((b) => (b['name'] as String).startsWith('Saga #10'))['id'] as String;
    fs.opened.clear();
    await Future.wait([s.pages(id), s.pageBytes(id, 1), s.pageBytes(id, 2), s.pageBytes(id, 3)]);
    expect(fs.opened, ['Saga #10 (2014).cbz']);
    await s.closeFiles();
    expect(fs.held, 0);
  });

  test('a file replaced by one with as many pages: its pages are measured again (the old sizes made a spread show '
      "as one page - the experiment's review)", () async {
    final s = await open();
    await s.rescan();
    final id = ((await s.books(size: 100))['content'] as List)
        .firstWhere((b) => (b['name'] as String).startsWith('Saga #2'))['id'] as String;
    expect([for (final p in await s.pages(id)) p['width']], [800, 800]);
    final wide = Uint8List.fromList([...pngHead(1600, 1200), ...List.filled(100, 1)]);
    await put('Saga (2012)/Saga #2 (2012).cbz', zipOf({'p1.png': page, 'p2.png': wide, 'p3.txt': 'longer'}));
    await s.rescan();
    expect([for (final p in await s.pages(id)) p['width']], [800, 1600]);
  });

  test("a book's poster is named for its file as it is: replaced, it gets a new one (the experiment kept the first)",
      () async {
    final s = await open();
    await s.rescan();
    final id = ((await s.books(size: 100))['content'] as List)
        .firstWhere((b) => (b['name'] as String).startsWith('Saga #2'))['id'] as String;
    final before = s.bookThumb(id);
    await put('Saga (2012)/Saga #2 (2012).cbz', cbz(pages: 6));
    await s.rescan();
    expect(s.bookThumb(id), isNot(before));
  });

  test("the posters no book has now are deleted at the next scan - a replaced file's old one, a removed book's; the "
      "others stay (the folder only grew - the experiment's review)", () async {
    final s = await open();
    await s.rescan();
    final books = [for (final b in (await s.books(size: 100))['content'] as List) b as Map];
    final saga2 = books.firstWhere((b) => (b['name'] as String).startsWith('Saga #2'))['id'] as String;
    final annual = books.firstWhere((b) => (b['name'] as String).startsWith('Saga Annual'))['id'] as String;
    final posters = <String, File>{};
    for (final b in books) {
      final id = b['id'] as String;
      posters[id] = File(s.bookThumb(id));
      await posters[id]!.parent.create(recursive: true);
      await posters[id]!.writeAsBytes([1]);
    }
    await put('Saga (2012)/Saga #2 (2012).cbz', cbz(pages: 6));
    await File('${root.path}/Saga (2012)/Saga Annual.cbz').delete();
    await s.rescan();
    expect(await posters[saga2]!.exists(), isFalse, reason: "the replaced file's old poster");
    expect(await posters[annual]!.exists(), isFalse, reason: "the removed book's");
    expect([for (final MapEntry(:key, :value) in posters.entries) if (key != saga2 && key != annual) value.existsSync()],
        everyElement(isTrue));
  });

  test('libraries changed: one removed takes its books off - its progress stays; the screens are told only when '
      'something changed', () async {
    final s = await open();
    await s.rescan();
    final id = ((await s.books(size: 100))['content'] as List).first['id'] as String;
    await s.setProgress(id, 3);
    final told = s.changed.value;
    await s.rescan();
    expect(s.changed.value, told, reason: 'nothing changed');
    await s.setLibraries(const []);
    expect((await s.books())['content'], isEmpty);
    expect(s.changed.value, greaterThan(told));
    expect(s.store.progress.keys, contains(id));
    expect(await LocalLibraries.load(), isEmpty);
  });

  // the reader opened a local EPUB as a file by its path: a share's path (\\nas\comics\x.epub) isn't one on Android
  test("the reader reads a local EPUB through its library's own files (a share's too), not as a file by its path",
      () async {
    final s = await open();
    await s.rescan();
    final id = [
      for (final b in (await s.books(size: 100))['content'] as List)
        if ((b['metadata'] as Map)['title'] == 'Frankenstein') b['id'] as String,
    ].single;
    fs.opened.clear();
    final info = await EpubRenderer.sourceFor(CombinedSource(s), id).info();
    expect(info.title, 'Frankenstein');
    expect(fs.opened, ['Frankenstein - Mary Shelley.epub']);
  });

  test('a library removed: its id, its series\' and its books\' are told (the pins to them go)', () async {
    final s = await open();
    await s.rescan();
    final series = {for (final x in (await s.series(size: 100))['content'] as List) x['id'] as String};
    final books = {for (final x in (await s.books(size: 100))['content'] as List) x['id'] as String};
    final told = <Set<String>>[];
    s.onRemoved = told.add;
    await s.setLibraries([library()]); // (the same: nothing removed)
    expect(told, isEmpty);
    await s.setLibraries(const []);
    expect(told.single, {library().id, ...series, ...books});
  });
}
