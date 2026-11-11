// Metadata edits of local and network books, kept alongside them (reports\10-27-metadata-plan.md): series.json
// (Mylar's format, with the app's own key) and .bedereader.json - read by the scan and applied as the books are listed,
// and saved: written whole, the files as they are kept.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/local/local_library.dart';
import 'package:komga_reader/local/local_meta.dart';
import 'package:komga_reader/local/local_scan.dart';
import 'package:komga_reader/local/local_source.dart';
import 'package:komga_reader/local/local_store.dart';

import 'support/memory_fs.dart';
import 'support/zip_writer.dart';
import 'dart:io';
import 'package:komga_reader/local/library_fs.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _page = Uint8List.fromList([...pngHead(10, 10), 1, 2, 3]);
final _cbz = zipOf({'1.png': _page});
Uint8List _text(Object json) => Uint8List.fromList(utf8.encode(jsonEncode(json)));
Uint8List _json(Object j) => Uint8List.fromList(utf8.encode(jsonEncode(j)));
Map _read(MemoryFs fs, String path) => jsonDecode(utf8.decode(fs.files[path]!)) as Map;
Uint8List _cbzWith([String? info]) => zipOf({'1.png': _page, if (info != null) 'ComicInfo.xml': info});

void main() {
  group('the files', () {
    test("series.json in Mylar's format: its name, publisher and status (Continuing is ongoing); the app's own key "
        'adds a sort title and reading direction, and its status wins (Mylar has no hiatus)', () {
      final m = FolderMeta.read(seriesJson: jsonEncode({
        'version': '1.0.2',
        'metadata': {'type': 'comicSeries', 'name': 'Saga', 'publisher': 'Image', 'status': 'Continuing'},
      }));
      expect((m.folderSeries!.title, m.folderSeries!.publisher, m.folderSeries!.status), ('Saga', 'Image', 'ONGOING'));
      final own = FolderMeta.read(seriesJson: jsonEncode({
        'metadata': {'name': 'Saga', 'status': 'Continuing'},
        'bedereader': {'status': 'HIATUS', 'titleSort': 'Saga, The', 'readingDirection': 'RIGHT_TO_LEFT'},
      }));
      expect((own.folderSeries!.status, own.folderSeries!.titleSort, own.folderSeries!.readingDirection),
          ('HIATUS', 'Saga, The', 'RIGHT_TO_LEFT'));
    });

    test(".bedereader.json: books by file name, a date taken away told from one not edited; what isn't JSON is no "
        'edits, not an error', () {
      final m = FolderMeta.read(editsJson: jsonEncode({
        'books': {
          'Saga 01.cbz': {'title': 'Chapter One', 'releaseDate': null},
          'Saga 02.cbz': {'number': '2.5', 'numberSort': 2.5},
        },
        'series': {'name:saga deluxe': {'publisher': 'Image'}},
      }));
      expect(m.books['Saga 01.cbz']!.dateSet, isTrue);
      expect(m.books['Saga 01.cbz']!.releaseDate, isNull);
      expect(m.books['Saga 02.cbz']!.dateSet, isFalse);
      expect(m.series['name:saga deluxe']!.publisher, 'Image');
      expect(FolderMeta.read(seriesJson: 'not json', editsJson: '[1, 2').isEmpty, isTrue);
    });
  });

  test("a series as the screens get it: its sort title, status, reading direction (the comic reader's) and publisher as "
      'edited; none edited, its name and ongoing', () {
    const s = LocalSeries(id: 'ls1', libraryId: 'll1', name: 'Saga');
    expect(LocalSource.seriesJson(s)['metadata'], allOf(containsPair('titleSort', 'Saga'), containsPair('status', 'ONGOING'),
        isNot(contains('readingDirection')), isNot(contains('publisher'))));
    final m = LocalSource.seriesJson(s.edited(const SeriesEdits(title: 'Saga (2012)', titleSort: 'Saga 2012',
        status: 'ENDED', readingDirection: 'RIGHT_TO_LEFT', publisher: 'Image')))['metadata'] as Map;
    expect([m['title'], m['titleSort'], m['status'], m['readingDirection'], m['publisher']],
        ['Saga (2012)', 'Saga 2012', 'ENDED', 'RIGHT_TO_LEFT', 'Image']);
  });

  group('a scan', () {
    const library = LocalLibrary('lib', 'lib');
    Map<String, Uint8List> files({Object? seriesJson, Object? edits}) => {
          'lib/Saga/Saga 01.cbz': _cbz,
          'lib/Saga/Saga 02.cbz': _cbz,
          'lib/Paper Girls/Paper Girls 01.cbz': _cbz,
          'lib/One Night.cbz': _cbz,
          if (seriesJson != null) 'lib/Saga/series.json': _text(seriesJson),
          if (edits != null) 'lib/Saga/.bedereader.json': _text(edits),
        };

    test("the files beside the books aren't books; their edits apply: a book's title, number and date, the series' "
        'fields', () async {
      final r = await scanLibrary(MemoryFs(files(
        seriesJson: {'metadata': {'name': 'Saga (2012)', 'publisher': 'Image', 'status': 'Ended'}},
        edits: {'books': {'Saga 01.cbz': {'title': 'Chapter One', 'number': '1', 'numberSort': 1,
            'releaseDate': '2012-03-14'}}},
      )), library, null);
      expect(r.index.books, hasLength(4), reason: 'the two metadata files are not books');
      final e = withEdits(r.index, library, r.index.meta);
      final one = e.books.values.firstWhere((b) => b.path.endsWith('Saga 01.cbz'));
      expect((one.title, one.number, one.released), ('Chapter One', '1', DateTime.utc(2012, 3, 14)));
      final saga = e.series[one.seriesId]!;
      expect((saga.name, saga.publisher, saga.status), ('Saga (2012)', 'Image', 'ENDED'));
      expect(r.index.books.values.firstWhere((b) => b.path.endsWith('Saga 01.cbz')).title, isNot('Chapter One'),
          reason: 'the scan itself keeps what the file says');
    });

    test('a book moved to a series by name: an existing one (any case) - else a new one in the library; a series '
        'left empty is gone', () async {
      final moved = await scanLibrary(MemoryFs(files(edits: {
        'books': {'Saga 01.cbz': {'series': 'paper girls'}, 'Saga 02.cbz': {'series': 'Saga Deluxe'}},
      })), library, null);
      final e = withEdits(moved.index, library, moved.index.meta);
      String seriesOf(String file) => e.series[e.books.values.firstWhere((b) => b.path.endsWith(file)).seriesId]!.name;
      expect(seriesOf('Saga 01.cbz'), 'Paper Girls');
      expect(seriesOf('Paper Girls 01.cbz'), 'Paper Girls');
      expect(seriesOf('Saga 02.cbz'), 'Saga Deluxe');
      expect(e.books.values.where((b) => e.series[b.seriesId]!.name == 'Saga'), isEmpty);
    });

    test("unchanged metadata files aren't read again; changed ones are; gone ones take their edits with them",
        () async {
      final fs = MemoryFs(files(edits: {'books': {'Saga 01.cbz': {'title': 'One'}}}));
      final first = await scanLibrary(fs, library, null);
      final reads = fs.opens;
      final again = await scanLibrary(fs, library, first.index);
      expect(fs.opens, reads, reason: 'nothing opened again: books and edits unchanged');
      expect(again.index.meta['lib/Saga']!.books['Saga 01.cbz']!.title, 'One');
      final changed = MemoryFs(files(edits: {'books': {'Saga 01.cbz': {'title': 'Uno', 'x': 1}}}));
      final third = await scanLibrary(changed, library, again.index);
      expect(third.index.meta['lib/Saga']!.books['Saga 01.cbz']!.title, 'Uno');
      final gone = await scanLibrary(MemoryFs(files()), library, third.index);
      expect(gone.index.meta, isEmpty);
    });

    test("a one-shot's series edits are kept by its file name in its folder's .bedereader.json", () async {
      final r = await scanLibrary(MemoryFs({
        ...files(),
        'lib/.bedereader.json': _text({'series': {'file:One Night.cbz': {'title': 'One Night Only'}}}),
      }), library, null);
      final e = withEdits(r.index, library, r.index.meta);
      final b = e.books.values.firstWhere((b) => b.path.endsWith('One Night.cbz'));
      expect(e.series[b.seriesId]!.name, 'One Night Only');
      expect(e.places[b.seriesId], (folder: 'lib', key: 'file:One Night.cbz'));
    });
  });

  group('saving', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    late MemoryFs fs;

    late LocalSource local;

    late Directory data;

    Future<void> open(Map<String, Uint8List> extra) async {
      fs = MemoryFs({
        'lib/Saga/Saga 01.cbz': _cbz,
        'lib/Saga/Saga 02.cbz': _cbz,
        'lib/Paper Girls/Paper Girls 01.cbz': _cbz,
        ...extra,
      });
      data = await Directory.systemTemp.createTemp('meta_write');
      local = await LocalSource.open(data, [const LocalLibrary('lib', 'lib')], fsFor: (_) => fs);
      addTearDown(() async {
        await local.closeFiles();
        await data.delete(recursive: true);
      });
      await local.rescan();
    }
  
    String idOf(String file) => local.entries.values
        .firstWhere((e) => (e['book'] as Map)['url'].toString().endsWith(file))['book']['id'] as String;
    Future<Map> book(String file) async => (await local.book(idOf(file)))!;

    test("a book's edit: in its folder's .bedereader.json, the file as it was kept (another book's edits, a key the app "
        "doesn't know); listed with it at once", () async {
      await open({
        'lib/Saga/.bedereader.json': _json({'books': {'Saga 02.cbz': {'title': 'Two'}}, 'note': 'mine'}),
      });
      expect(await local.canEditMetadata(idOf('Saga 01.cbz')), isTrue);
      await local.editBookMetadata(idOf('Saga 01.cbz'), {'title': 'Chapter One', 'releaseDate': '2012-03-14'});
      final file = _read(fs, 'lib/Saga/.bedereader.json');
      expect(file['books'], {
        'Saga 02.cbz': {'title': 'Two'},
        'Saga 01.cbz': {'title': 'Chapter One', 'releaseDate': '2012-03-14'},
      });
      expect(file['note'], 'mine');
      final b = await book('Saga 01.cbz');
      expect((b['metadata']['title'], b['metadata']['releaseDate']), ('Chapter One', '2012-03-14'));
      // and the next scan reads the same from the file
      await local.rescan();
      expect((await book('Saga 01.cbz'))['metadata']['title'], 'Chapter One');
    });

    test("a book moved to a new series, then back to its own: the move is taken out again", () async {
      await open({});
      await local.editBookMetadata(idOf('Saga 02.cbz'), {'seriesName': 'Saga Deluxe'});
      expect((await book('Saga 02.cbz'))['seriesTitle'], 'Saga Deluxe');
      await local.editBookMetadata(idOf('Saga 02.cbz'), {'seriesName': 'saga'});
      expect((await book('Saga 02.cbz'))['seriesTitle'], 'Saga');
      expect(_read(fs, 'lib/Saga/.bedereader.json')['books'], isEmpty);
    });

    test("a series' edit: its folder's series.json in Mylar's format - a Mylar file's own keys kept, its status as "
        "Mylar's, what Mylar has no place for under the app's key; listed with it", () async {
      await open({
        'lib/Saga/series.json': _json({'version': '1.0.2', 'metadata': {'type': 'comicSeries', 'name': 'Saga',
            'comicid': 123, 'status': 'Continuing'}}),
      });
      final seriesId = (await book('Saga 01.cbz'))['seriesId'] as String;
      expect(await local.canEditMetadata(seriesId), isTrue);
      await local.editSeriesMetadata(seriesId, {'title': 'Saga (2012)', 'status': 'HIATUS', 'titleSort': 'Saga 2012',
          'readingDirection': 'RIGHT_TO_LEFT'});
      final file = _read(fs, 'lib/Saga/series.json');
      expect(file['metadata'], {'type': 'comicSeries', 'name': 'Saga (2012)', 'comicid': 123, 'status': 'Continuing'});
      expect(file['bedereader'], {'titleSort': 'Saga 2012', 'readingDirection': 'RIGHT_TO_LEFT', 'status': 'HIATUS'});
      final s = (await local.oneSeries(seriesId))!;
      expect([s['metadata']['title'], s['metadata']['status'], s['metadata']['readingDirection']],
          ['Saga (2012)', 'HIATUS', 'RIGHT_TO_LEFT']);
    });

    test("a series with no series.json yet gets one, named; ended is Mylar's Ended", () async {
      await open({});
      final seriesId = (await book('Paper Girls 01.cbz'))['seriesId'] as String;
      await local.editSeriesMetadata(seriesId, {'status': 'ENDED', 'publisher': 'Image'});
      expect(_read(fs, 'lib/Paper Girls/series.json')['metadata'],
          {'type': 'comicSeries', 'name': 'Paper Girls', 'publisher': 'Image', 'status': 'Ended'});
    });

    test("a metadata file there but not readable isn't written over; a folder that can't be written changes nothing",
        () async {
      await open({'lib/Saga/.bedereader.json': Uint8List.fromList(utf8.encode('{broken'))});
      await expectLater(local.editBookMetadata(idOf('Saga 01.cbz'), {'title': 'X'}), throwsA(anything));
      expect(utf8.decode(fs.files['lib/Saga/.bedereader.json']!), '{broken');
      fs.readOnly = true;
      await expectLater(local.editBookMetadata(idOf('Paper Girls 01.cbz'), {'title': 'X'}), throwsA(anything));
      expect((await book('Paper Girls 01.cbz'))['metadata']['title'], isNot('X'));
    });

    test("this device's files: a file's contents replaced whole, through a new copy put in its place", () async {
      final dir = await Directory.systemTemp.createTemp('write_whole');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}${Platform.pathSeparator}.bedereader.json';
      await LocalFs().writeWhole(path, Uint8List.fromList(utf8.encode('first')));
      await LocalFs().writeWhole(path, Uint8List.fromList(utf8.encode('second')));
      expect(File(path).readAsStringSync(), 'second');
      expect(dir.listSync(), hasLength(1), reason: 'no copy left beside it');
    });
  });

  group('local and network books', () {
    late MemoryFs fs;
    late LocalSource local;
    Future<void> open() async {
      fs = MemoryFs({'lib/Saga/Saga 01.cbz': _cbzWith(), 'lib/Saga/Saga 02.cbz': _cbzWith()});
      final data = await Directory.systemTemp.createTemp('more_fields');
      local = await LocalSource.open(data, [const LocalLibrary('lib', 'lib')], fsFor: (_) => fs);
      addTearDown(() async {
        await local.closeFiles();
        await data.delete(recursive: true);
      });
      await local.rescan();
    }

    String idOf(String file) => local.entries.values
        .firstWhere((e) => (e['book'] as Map)['url'].toString().endsWith(file))['book']['id'] as String;
    Future<Map> meta(String file) async => (await local.book(idOf(file)))!['metadata'] as Map;
    final edit = <String, Object?>{
      'summary': 'A war.', 'numberSort': 0.5, 'tags': ['space'],
      'authors': [{'name': 'Brian K. Vaughan', 'role': 'writer'}],
    };

    test('alongside: a book\'s sort number, summary, credits and tags kept and listed - and again after a scan',
        () async {
      await open();
      await local.editBookMetadata(idOf('Saga 02.cbz'), edit);
      for (final pass in ['at once', 'after a scan']) {
        final m = await meta('Saga 02.cbz');
        expect([m['numberSort'], m['summary'], m['tags'], m['authors']],
            [0.5, 'A war.', ['space'], [{'name': 'Brian K. Vaughan', 'role': 'writer'}]], reason: pass);
        await local.rescan();
      }
      final books = (await local.seriesBooks((await local.book(idOf('Saga 02.cbz')))!['seriesId'] as String))['content'];
      expect([for (final b in books as List) b['name']], ['Saga 02', 'Saga 01'], reason: 'sorted by its sort number');
    });

    test("a series' summary in series.json as Mylar's description (Komga reads it), its genres and tags under the "
        "app's key; listed, and in the genre filter's list", () async {
      await open();
      final seriesId = (await local.book(idOf('Saga 01.cbz')))!['seriesId'] as String;
      await local.editSeriesMetadata(seriesId, {'summary': 'Star-crossed.', 'genres': ['Sci-fi'], 'tags': ['war']});
      final j = jsonDecode(utf8.decode(fs.files['lib/Saga/series.json']!)) as Map;
      expect(j['metadata']['description_text'], 'Star-crossed.');
      expect(j['bedereader'], {'genres': ['Sci-fi'], 'tags': ['war']});
      final s = (await local.oneSeries(seriesId))!['metadata'] as Map;
      expect([s['summary'], s['genres'], s['tags']], ['Star-crossed.', ['Sci-fi'], ['war']]);
      expect(await local.genres(), contains('Sci-fi'));
    });
  });
}
