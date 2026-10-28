// Metadata edits of local and network books, kept alongside them (reports\10-27-metadata-plan.md, step 2): series.json
// (Mylar's format, with the app's own key) and .bedereader.json, read by the scan and applied as the books are listed.
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

final _page = Uint8List.fromList([...pngHead(10, 10), 1, 2, 3]);
final _cbz = zipOf({'1.png': _page});
Uint8List _text(Object json) => Uint8List.fromList(utf8.encode(jsonEncode(json)));

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
}
