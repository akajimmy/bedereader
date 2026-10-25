// Local mode (experimental/sources): libraries that are folders, no server. The scan, the names, the pages, the
// progress kept on the device, and the sign-in screen's "No server".
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/local/folder_komga.dart';
import 'package:komga_reader/local/folder_scan.dart';
import 'package:komga_reader/screens/login.dart';
import 'package:komga_reader/widgets/server_status.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/no_network.dart';
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
      final poster = api.bookThumb(novel['id'] as String);
      expect(await File(poster).exists(), isFalse, reason: 'not made until a tile asks for it');
      expect(await api.thumbAt(poster), isTrue);
      expect(await File(poster).exists(), isTrue, reason: 'its cover, made small');
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
      await api.rescan(); // (the start's own, in the background, done first)
    });

    test('the next start shows the last scan at once, then scans again: a book added appears, one changed is read '
        'again, one deleted goes', () async {
      await (await open()).rescan(); // (the first start's scan, done)
      final saga = '${root.path}${Platform.pathSeparator}Saga (2012)${Platform.pathSeparator}';
      await File('${saga}Saga #2 (2012).cbz').delete();
      await File('${saga}Saga #11 (2014).cbz').writeAsBytes(zipOf({'1.jpg': png}));
      final ten = File('${saga}Saga #10 (2014).cbz');
      await ten.writeAsBytes(zipOf({'1.jpg': png, '2.jpg': png, '3.jpg': png, '4.jpg': png}));
      await ten.setLastModified(DateTime(2030));
      final api = await open();
      Future<List<String>> numbers() async => [
            for (final b in (await api.searchBooks('Saga'))['content'] as List) '${b['metadata']['number']}'
          ]..sort();
      expect(await numbers(), ['10', '2'], reason: 'the last scan, at once');
      await api.rescan();
      expect(await numbers(), ['10', '11']);
      final tenNow = ((await api.searchBooks('Saga #10'))['content'] as List).single as Map;
      expect(tenNow['media']['pagesCount'], 4, reason: 'changed: read again');
    });

    test('libraries renamed, added and removed in Settings: the books follow, reading progress stays with the '
        'folder', () async {
      final api = await open();
      final lib = api.folders.single;
      final sagaBook = ((await api.searchBooks('Saga'))['content'] as List).first as Map;
      await api.setProgress(sagaBook['id'] as String, 1);
      await api.setLibraries([LocalLibrary('Comics', lib.path)]);
      expect((await api.libraries()).single['name'], 'Comics');
      await api.setLibraries(const []);
      expect(api.isEmpty, isTrue);
      expect(await FolderKomga.savedLibraries(), isEmpty);
      await api.setLibraries([lib]);
      final again = ((await api.searchBooks('Saga'))['content'] as List).first as Map;
      expect(again['readProgress']?['page'], 1, reason: 'added back: its progress with it');
    });

    test("a comic's ComicInfo.xml: its title, number, release date, people and summary for the book; publisher, "
        'genres, book count and right to left for the series; its pages\' sizes', () async {
      final f = File('${root.path}${Platform.pathSeparator}Berserk (1990)${Platform.pathSeparator}Berserk v01.cbz');
      await f.parent.create();
      await f.writeAsBytes(zipOf({
        '01.png': png, '02.png': png, '03.png': png,
        'comicinfo.xml': '<?xml version="1.0"?><ComicInfo><Title>The Black Swordsman</Title><Number>1</Number>'
            '<Summary>Guts &amp; Puck.</Summary><Year>1990</Year><Month>11</Month><Day>26</Day>'
            '<Writer>Kentaro Miura</Writer><Penciller>Kentaro Miura, Studio Gaga</Penciller>'
            '<Publisher>Hakusensha</Publisher><Genre>Dark Fantasy, Seinen</Genre><Count>41</Count>'
            '<Manga>YesAndRightToLeft</Manga><Pages><Page Image="0" ImageWidth="1200" ImageHeight="1800"/>'
            '<Page Image="1" ImageWidth="2400" ImageHeight="1800"/><Page Image="2" ImageWidth="1200" ImageHeight="1800"/>'
            '</Pages></ComicInfo>',
      }));
      final api = await open();
      final book = ((await api.searchBooks('Black Swordsman'))['content'] as List).single as Map;
      final m = book['metadata'] as Map;
      expect((m['title'], m['number'], m['releaseDate'], m['summary']),
          ('The Black Swordsman', '1', '1990-11-26', 'Guts & Puck.'));
      expect([for (final a in m['authors'] as List) '${a['name']}/${a['role']}'],
          ['Kentaro Miura/writer', 'Kentaro Miura/penciller', 'Studio Gaga/penciller']);
      final s = (await api.oneSeries(book['seriesId'] as String))!['metadata'] as Map;
      expect((s['publisher'], s['totalBookCount'], s['readingDirection']), ('Hakusensha', 41, 'RIGHT_TO_LEFT'));
      expect(s['genres'], ['Dark Fantasy', 'Seinen']);
      expect([for (final p in await api.pages(book['id'] as String)) '${p['width']}x${p['height']}'],
          ['1200x1800', '2400x1800', '1200x1800'], reason: 'page 2 a spread');
    });

    test("pages with no sizes given: read from the pictures themselves when the book is opened, and kept", () async {
      var api = await open();
      final saga = ((await api.searchBooks('Saga #10'))['content'] as List).single as Map;
      expect((api.store.books[saga['id']]!['pages'] as List).first['width'], isNull, reason: 'not read by the scan');
      expect([for (final p in await api.pages(saga['id'] as String)) '${p['width']}x${p['height']}'],
          ['4x6', '4x6', '4x6'], reason: "the PNGs' own sizes");
      await api.rescan();
      api = await open(); // the next start: kept
      expect((api.store.books[saga['id']]!['pages'] as List).first['width'], 4);
      await api.rescan();
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

  testWidgets("Settings' server status: with no server, no Retry - nothing to check again; with Komga, Retry",
      (tester) async {
    late FolderKomga local;
    await tester.runAsync(() async {
      final data = await Directory.systemTemp.createTemp('local_status');
      addTearDown(() => deleteTemp(data));
      local = await FolderKomga.open(const [], dataDir: data);
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ServerStatus(api: local))));
    await tester.pump();
    expect(find.byIcon(Icons.refresh), findsNothing);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ServerStatus(api: plainKomga()))));
    await tester.pump();
    expect(find.byIcon(Icons.refresh), findsOneWidget);
  });
}
