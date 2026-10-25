// Local mode (experimental/sources): libraries that are folders, no server. The scan, the names, the pages, the
// progress kept on the device, and the sign-in screen's "No server".
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/local/folder_komga.dart';
import 'package:komga_reader/local/folder_scan.dart';
import 'package:komga_reader/screens/login.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/zip_writer.dart';

String _epub(String title, String author) => '<?xml version="1.0"?><package><metadata>'
    '<dc:title>$title</dc:title><dc:creator>$author</dc:creator><meta name="cover" content="c"/></metadata>'
    '<manifest><item id="c" href="cover.png" media-type="image/png"/></manifest></package>';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('names', () {
    test('the issue number: after #, else after the series\' own name, else the first number; a title after it', () {
      expect(parseBookName('Absolute Batman 010 (2025) (Digital) (Shan-Empire)', 'Absolute Batman (2024)'),
          (number: 10.0, title: null, year: 2025));
      expect(parseBookName('Spider-Island - Cloak & Dagger (2011) #002', 'Spider-Island - Cloak & Dagger (2011)'),
          (number: 2.0, title: null, year: 2011));
      expect(parseBookName('Dune 02 - Dune Messiah', 'Dune'), (number: 2.0, title: 'Dune Messiah', year: null));
      expect(parseBookName('Spider-Man 2099 #3', 'Spider-Man 2099').number, 3.0);
      expect(parseBookName('Spider-Man 2099 004', 'Spider-Man 2099').number, 4.0, reason: 'not 2099');
      expect(parseBookName('Saga #1.5', 'Saga').number, 1.5);
      expect(parseBookName('Frankenstein - Mary Shelley', '').number, isNull);
    });

    test('natural order: page 2 before page 10', () {
      expect(comicPages(['p10.jpg', 'p2.jpg', 'p1.JPG', 'notes.txt', '__MACOSX/p1.jpg', 'dir/']),
          ['p1.JPG', 'p2.jpg', 'p10.jpg']);
    });
  });

  group('a library folder', () {
    late Directory root, data;
    late List<int> png;

    setUpAll(() async => png = await solidPng(4, 6));
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      root = await Directory.systemTemp.createTemp('local_lib');
      data = await Directory.systemTemp.createTemp('local_data');
      Future<void> put(String rel, List<int> bytes) async {
        final f = File('${root.path}${Platform.pathSeparator}${rel.replaceAll('/', Platform.pathSeparator)}');
        await f.parent.create(recursive: true);
        await f.writeAsBytes(bytes);
      }

      // a series of two, in the wrong order by name; a one-shot folder; a book loose in the library; not a book
      await put('Saga (2012)/Saga #10 (2014).cbz', zipOf({'p2.jpg': png, 'p10.jpg': png, 'p1.jpg': png}));
      await put('Saga (2012)/Saga #2 (2012).cbz', zipOf({'01.png': png, '02.png': png}));
      await put('_oneshots/Frankenstein - Mary Shelley.epub', zipOf({
        'META-INF/container.xml': '<container><rootfile full-path="OPS/book.opf"/></container>',
        'OPS/book.opf': _epub('Frankenstein', 'Mary Shelley'),
        'OPS/cover.png': png,
      }));
      await put('Loose One-Shot (2020).cbz', zipOf({'a.jpg': png}));
      await put('Saga (2012)/notes.txt', [1, 2, 3]);
    });
    tearDown(() async {
      await deleteTemp(root);
      await deleteTemp(data);
    });

    Future<FolderKomga> open() => FolderKomga.open([LocalLibrary.at(root.path)], dataDir: data);

    test('series from its folders, a _oneshots folder and loose books each a series of their own; books in number '
        'order, their pages in natural order; an EPUB titled and credited from its own metadata', () async {
      final api = await open();
      final lib = (await api.libraries()).single;
      expect(lib['name'], root.path.split(Platform.pathSeparator).last);
      final series = (await api.series(libraryId: lib['id'] as String))['content'] as List;
      expect([for (final s in series) s['name']], ['Frankenstein - Mary Shelley', 'Loose One-Shot (2020)', 'Saga (2012)']);
      final saga = series.last as Map;
      final books = (await api.seriesBooks(saga['id'] as String))['content'] as List;
      expect([for (final b in books) b['metadata']['number']], ['2', '10']);
      expect([for (final b in books) b['media']['pagesCount']], [2, 3]);
      expect(books.last['metadata']['releaseDate'], '2014-01-01');
      final pages = await api.pages(books.last['id'] as String);
      expect([for (final p in pages) p['number']], [1, 2, 3]);
      expect(await api.pageBytes(books.last['id'] as String, 2), png, reason: "p2.jpg, out of the CBZ");
      final novel = ((await api.seriesBooks((series.first as Map)['id'] as String))['content'] as List).single as Map;
      expect((novel['metadata']['title'], novel['metadata']['authors'].single['name'], novel['media']['mediaProfile']),
          ('Frankenstein', 'Mary Shelley', 'EPUB'));
      expect(api.epubFile(novel['id'] as String)?.path, endsWith('Frankenstein - Mary Shelley.epub'));
      expect(await File(api.bookThumb(novel['id'] as String)).exists(), isTrue, reason: 'its cover, made small');
    });

    test('reading progress is kept on the device, and found again after the folders are scanned again (the same '
        'ids)', () async {
      var api = await open();
      final saga = ((await api.searchBooks('Saga'))['content'] as List).map((b) => b as Map).toList();
      final id = saga.first['id'] as String;
      await api.setProgress(id, 2);
      await api.markRead(saga.last['id'] as String);
      await api.store.written;
      api = await open(); // the next start
      final again = {for (final b in (await api.books(size: 100))['content'] as List) b['id']: b};
      expect(again[id]['readProgress']['page'], 2);
      expect(again[saga.last['id']]['readProgress']['completed'], isTrue);
      final read = (await api.series(readStatus: ['IN_PROGRESS']))['content'] as List;
      expect([for (final s in read) s['name']], ['Saga (2012)'], reason: 'one read, one started: in progress');
    });

    test('a library folder that isn\'t there: no books, nothing thrown', () async {
      final api = await FolderKomga.open([LocalLibrary.at(r'Z:\nowhere\at\all')], dataDir: data);
      expect(api.isEmpty, isTrue);
    });
  });

  group('signing in with no server', () {
    testWidgets('No server: the folders typed open local mode, and are kept for next time; none with books in them: '
        'said so, nothing opened', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final opened = <List<LocalLibrary>>[];
      FolderKomga? given;
      late FolderKomga empty, full;
      await tester.runAsync(() async {
        final data = await Directory.systemTemp.createTemp('local_signin');
        addTearDown(() => deleteTemp(data));
        empty = await FolderKomga.open(const [], dataDir: data);
        final root = await Directory.systemTemp.createTemp('local_signin_lib');
        addTearDown(() => deleteTemp(root));
        await Directory('${root.path}${Platform.pathSeparator}S').create();
        await File('${root.path}${Platform.pathSeparator}S${Platform.pathSeparator}S #1.cbz')
            .writeAsBytes(zipOf({'1.jpg': await solidPng(2, 3)}));
        full = await FolderKomga.open([LocalLibrary.at(root.path)], dataDir: data);
      });
      var books = false;
      await tester.pumpWidget(MaterialApp(home: LoginScreen(
        onSignedIn: (api) async => given = api as FolderKomga,
        openLocal: (libs) async {
          opened.add(libs);
          return books ? full : empty;
        },
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.text('No server'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'C:\\Comics\\Ongoing\n\nD:\\Golden Age\\');
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect([for (final l in opened.single) (l.name, l.path)], [('Ongoing', r'C:\Comics\Ongoing'),
        ('Golden Age', r'D:\Golden Age')], reason: 'one library per line, named after its folder');
      expect(given, isNull, reason: 'no books there: not opened');
      expect(find.textContaining('No CBZ or EPUB books found'), findsOneWidget);

      books = true;
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(given, same(full));
      expect([for (final l in await FolderKomga.savedLibraries()) l.path], [r'C:\Comics\Ongoing', r'D:\Golden Age']);
    });
  });
}
