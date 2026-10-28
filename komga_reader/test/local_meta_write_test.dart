// Metadata edits of local and network books saved alongside them (reports\10-27-metadata-plan.md, step 3): a book's in
// its folder's .bedereader.json, a series' in its folder's series.json (Mylar's format) - written whole, safely, the
// files as they are now kept (edits made elsewhere, keys the app doesn't know), and the books listed with them at once.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/local/library_fs.dart';
import 'package:komga_reader/local/local_library.dart';
import 'package:komga_reader/local/local_source.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_fs.dart';
import 'support/zip_writer.dart';

final _page = Uint8List.fromList([...pngHead(10, 10), 1, 2, 3]);
final _cbz = zipOf({'1.png': _page});
Uint8List _json(Object j) => Uint8List.fromList(utf8.encode(jsonEncode(j)));
Map _read(MemoryFs fs, String path) => jsonDecode(utf8.decode(fs.files[path]!)) as Map;

void main() {
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
}
