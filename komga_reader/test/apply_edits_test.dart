// Apply edits to files (user, 2026-10-27; reports\10-27-apply-edits-plan.md): a library's edits, kept alongside its
// books, put into the files when asked - written in, files and folders renamed, books moved - one step at a time, and
// the alongside files, reading progress and the rest following the books.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/highlights.dart';
import 'package:komga_reader/local/apply_edits.dart';
import 'package:komga_reader/local/file_zip.dart';
import 'package:komga_reader/local/local_library.dart';
import 'package:komga_reader/local/local_source.dart';
import 'package:komga_reader/ondeck_hidden.dart';
import 'package:komga_reader/pins.dart';
import 'package:komga_reader/reader/comic_renderer.dart' show StripPlaces;
import 'package:komga_reader/screens/apply_edits_dialog.dart';
import 'package:komga_reader/settings.dart';
import 'package:komga_reader/synced_ids.dart' show PairShift;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_fs.dart';
import 'support/zip_writer.dart';

final _page = Uint8List.fromList([...pngHead(10, 10), 1, 2, 3]);
final _cbz = zipOf({'1.png': _page});
final _cbr = File('test/fixtures/rar/synthetic_comic.cbr').readAsBytesSync();
Uint8List _json(Object j) => Uint8List.fromList(utf8.encode(jsonEncode(j)));
Map _read(MemoryFs fs, String path) => jsonDecode(utf8.decode(fs.files[path]!)) as Map;
Future<String> _comicInfo(MemoryFs fs, String path) async {
  final z = await FileZip.open(await fs.open(path));
  try {
    return utf8.decode((await z.read('ComicInfo.xml'))!);
  } finally {
    await z.close();
  }
}

/// Saga - its title edited - with #1 (a CBZ: title, number, date edited), #2 (a CBR: number edited) and #3 (not
/// edited); Paper Girls #1 moved to a series of its own, Saga Deluxe, whose publisher was edited; Paper Girls #2 not
/// edited.
Map<String, Uint8List> _library() => {
      'lib/Saga/Saga 01.cbz': _cbz,
      'lib/Saga/Saga 02.cbr': _cbr,
      'lib/Saga/Saga 03.cbz': _cbz,
      'lib/Saga/series.json': _json({'metadata': {'name': 'Saga (2012)'}}),
      'lib/Saga/.bedereader.json': _json({'books': {
        'Saga 01.cbz': {'title': 'Chapter One', 'number': '1', 'releaseDate': '2012-03-14'},
        'Saga 02.cbr': {'number': '2'},
      }}),
      'lib/Paper Girls/Paper Girls 01.cbz': _cbz,
      'lib/Paper Girls/Paper Girls 02.cbz': _cbz,
      'lib/Paper Girls/.bedereader.json': _json({'books': {'Paper Girls 01.cbz': {'series': 'Saga Deluxe'}}}),
      'lib/.bedereader.json': _json({'series': {'name:saga deluxe': {'publisher': 'Image'}}}),
    };

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  late MemoryFs fs;
  late LocalSource local;
  const library = LocalLibrary('lib', 'lib');

  Future<void> open(Map<String, Uint8List> files, {LocalLibrary on = library, bool caseInsensitive = false}) async {
    fs = MemoryFs(files, caseInsensitive: caseInsensitive);
    final data = await Directory.systemTemp.createTemp('apply');
    local = await LocalSource.open(data, [on], fsFor: (_) => fs);
    addTearDown(() async {
      await local.closeFiles();
      await data.delete(recursive: true);
    });
    await local.rescan();
  }

  String idOf(String file) => local.entries.values
      .firstWhere((e) => (e['book'] as Map)['url'].toString().endsWith(file))['book']['id'] as String;
  Map<String, String> told = {};
  Future<ApplyResult> apply({LocalLibrary on = library}) async {
    local.onMoved = (ids) => told = ids;
    return local.applyEdits(await local.planApply(on));
  }

  test("the plan: the retitled series' folder renamed and all its books renamed and given its name (an unedited one "
      "too); a moved book into a folder made for its new series; what goes into a file only what was edited - "
      'nothing for a CBR', () async {
    await open(_library());
    final plan = await local.planApply(library);
    expect([for (final f in plan.folders) (f.from, f.to)], [('lib/Saga', 'lib/Saga (2012)')]);
    expect(plan.folders.single.books, hasLength(3));
    final steps = {for (final b in plan.books) b.from: b};
    expect(steps.keys, unorderedEquals(['lib/Saga/Saga 01.cbz', 'lib/Saga/Saga 02.cbr', 'lib/Saga/Saga 03.cbz',
        'lib/Paper Girls/Paper Girls 01.cbz']));
    expect(steps['lib/Saga/Saga 01.cbz']!.to, 'lib/Saga (2012)/Saga (2012) 001.cbz', reason: 'its year in the series name');
    expect(steps['lib/Saga/Saga 02.cbr']!.to, 'lib/Saga (2012)/Saga (2012) 002.cbr');
    expect(steps['lib/Saga/Saga 03.cbz']!.to, 'lib/Saga (2012)/Saga (2012) 003.cbz');
    expect(steps['lib/Paper Girls/Paper Girls 01.cbz']!.to, 'lib/Saga Deluxe/Saga Deluxe 001.cbz');
    expect(steps['lib/Paper Girls/Paper Girls 01.cbz']!.makesSeries, 'Saga Deluxe');
    final one = steps['lib/Saga/Saga 01.cbz']!.write!;
    expect((one.title, one.number, one.releaseDate, one.series, one.summary), ('Chapter One', '1', '2012-03-14', 'Saga (2012)', null));
    expect((steps['lib/Saga/Saga 03.cbz']!.write!.title, steps['lib/Saga/Saga 03.cbz']!.write!.series), (null, 'Saga (2012)'));
    expect(steps['lib/Saga/Saga 02.cbr']!.write, isNull);
    expect(plan.fieldsWritten, {'title', 'series', 'number', 'releaseDate'});
  });

  test("the confirmation's lines: one for each kind of change made; the fields written named only if edited; CBZ and "
      'CBR told apart only when both are there - and with only CBRs, nothing said about writing into files', () async {
    await open(_library());
    final plan = await local.planApply(library);
    final lines = applySummary(plan);
    expect(lines, hasLength(4)); // the folder, the move, the renames, the writing
    expect(lines.last, allOf(contains('title'), contains('number'), contains('release date'), isNot(contains('summary')),
        isNot(contains('credits')), contains('CBR')));
    final cbrsOnly = applySummary(ApplyPlan(library, const [], [for (final b in plan.books) if (b.cbr) b], const []));
    expect(cbrsOnly, hasLength(1));
    expect(cbrsOnly.single, isNot(contains('written into')));
    final cbzOnly = applySummary(ApplyPlan(library, const [], [for (final b in plan.books) if (!b.cbr) b], const []));
    expect(cbzOnly.last, isNot(contains('CBR')));
  });

  test('the run: written into, renamed and moved; the alongside files follow - entries under their new names, the new '
      "series' edits in its folder's series.json - reading progress follows the books; run again, nothing to do",
      () async {
    await open(_library());
    await local.setProgress(idOf('Saga 01.cbz'), 5);
    await local.setProgress(idOf('Paper Girls 02.cbz'), 3); // (not edited: its id doesn't change)
    final before = idOf('Saga 01.cbz'), cbrBytes = fs.files['lib/Saga/Saga 02.cbr'];
    final r = await apply();
    expect(r.failures, isEmpty);
    expect(fs.files.keys, containsAll([
      'lib/Saga (2012)/Saga (2012) 001.cbz', 'lib/Saga (2012)/Saga (2012) 002.cbr', 'lib/Saga (2012)/Saga (2012) 003.cbz',
      'lib/Saga (2012)/series.json', 'lib/Saga Deluxe/Saga Deluxe 001.cbz', 'lib/Saga Deluxe/series.json',
      'lib/Paper Girls/Paper Girls 02.cbz',
    ]));
    expect(fs.files.keys.where((k) => k.startsWith('lib/Saga/')), isEmpty);
    expect(fs.files['lib/Saga (2012)/Saga (2012) 002.cbr'], cbrBytes, reason: 'a CBR: renamed only');
    expect(await _comicInfo(fs, 'lib/Saga (2012)/Saga (2012) 001.cbz'),
        allOf(contains('<Title>Chapter One</Title>'), contains('<Series>Saga (2012)</Series>'), contains('<Year>2012</Year>')));
    expect(await _comicInfo(fs, 'lib/Saga (2012)/Saga (2012) 003.cbz'),
        allOf(contains('<Series>Saga (2012)</Series>'), isNot(contains('<Title>'))));
    expect((_read(fs, 'lib/Saga (2012)/.bedereader.json')['books'] as Map).keys,
        unorderedEquals(['Saga (2012) 001.cbz', 'Saga (2012) 002.cbr']));
    expect((_read(fs, 'lib/Saga Deluxe/.bedereader.json')['books'] as Map).keys, ['Saga Deluxe 001.cbz']);
    expect(_read(fs, 'lib/Saga Deluxe/series.json')['metadata'],
        allOf(containsPair('name', 'Saga Deluxe'), containsPair('publisher', 'Image')));
    expect(_read(fs, 'lib/.bedereader.json')['series'], isEmpty);
    final now = idOf('Saga (2012) 001.cbz');
    expect(told, containsPair(before, now));
    expect(told.entries.where((e) => e.key == e.value), isEmpty, reason: 'no id "moved" to itself');
    final b = (await local.book(now))!;
    expect([b['metadata']['title'], b['seriesTitle'], b['readProgress']?['page']], ['Chapter One', 'Saga (2012)', 5]);
    expect((await local.book(idOf('Saga Deluxe 001.cbz')))!['seriesTitle'], 'Saga Deluxe');
    expect((await local.book(idOf('Paper Girls 02.cbz')))!['readProgress']?['page'], 3);
    final again = await local.planApply(library);
    expect(again.isEmpty, isTrue, reason: '${[for (final s in again.books) '${s.from} -> ${s.to} ${s.write}']}');
  });

  test("a folder renamed only in case (on a system that doesn't tell case apart): renamed, and the books' ids - the "
      'same in any case - left alone: a webtoon place kept under them stays (it was deleted)', () async {
    await open({
      'lib/saga/Saga 01.cbz': _cbz,
      'lib/saga/series.json': _json({'metadata': {'name': 'Saga'}}),
    }, caseInsensitive: true);
    final id = idOf('Saga 01.cbz');
    await StripPlaces.save(id, 4, 0.25);
    final r = await apply();
    await StripPlaces.renameIds(told);
    await BookHighlights.renameIds(told);
    expect(r.failures, isEmpty);
    expect(fs.files.keys, contains('lib/Saga/Saga 001.cbz'));
    expect(told.entries.where((e) => e.key == e.value), isEmpty);
    expect(await StripPlaces.load(idOf('Saga 001.cbz')), (4, 0.25));
  });

  test("a folder that can't be renamed when it comes to it: its books stay in it (renamed there), nothing split off "
      'into a folder of their own; said', () async {
    await open(_library());
    fs.failMoves.add('lib/Saga');
    final r = await apply();
    expect(r.failures, hasLength(1));
    expect(fs.files.keys.where((k) => k.startsWith('lib/Saga (2012)/')), isEmpty);
    expect(fs.files.keys, containsAll(['lib/Saga/Saga (2012) 001.cbz', 'lib/Saga/Saga (2012) 003.cbz', 'lib/Saga/series.json']));
  });

  test("a read list's books: written into, never renamed - its order is in their names", () async {
    const list = LocalLibrary('Order', 'Order', kind: LibraryKind.readList);
    await open({
      'Order/001 - Saga 01.cbz': _cbz,
      'Order/002 - Saga 02.cbz': _cbz,
      'Order/.bedereader.json': _json({'books': {'002 - Saga 02.cbz': {'title': 'The Edit'}}}),
    }, on: list);
    final plan = await local.planApply(list);
    expect([for (final b in plan.books) (b.from, b.to, b.write?.title)], [('Order/002 - Saga 02.cbz', 'Order/002 - Saga 02.cbz', 'The Edit')]);
    await apply(on: list);
    expect(fs.files.keys.where((k) => k.endsWith('.cbz')), ['Order/001 - Saga 01.cbz', 'Order/002 - Saga 02.cbz']);
  });

  test('a book moved to a series whose name a folder can\'t have ("What If?"): its folder is "What If-", and the '
      'series keeps its name - the book is in it after the scan, not adrift', () async {
    await open({
      'lib/Marvel/Marvel 01.cbz': _cbz,
      'lib/Marvel/.bedereader.json': _json({'books': {'Marvel 01.cbz': {'series': 'What If?'}}}),
    });
    await apply();
    expect(fs.files.keys, contains('lib/What If-/What If- 001.cbz'));
    expect(_read(fs, 'lib/What If-/series.json')['metadata'], containsPair('name', 'What If?'));
    final b = (await local.book(idOf('What If- 001.cbz')))!;
    expect(b['seriesTitle'], 'What If?');
    expect((await local.planApply(library)).isEmpty, isTrue);
  });

  test("a new series' folder that's there already isn't used: its books stay, said", () async {
    await open({
      'lib/Marvel/Marvel 01.cbz': _cbz,
      'lib/Marvel/.bedereader.json': _json({'books': {'Marvel 01.cbz': {'series': 'Extras'}}}),
      'lib/Extras/notes.txt': Uint8List.fromList([1]),
    });
    final plan = await local.planApply(library);
    expect(plan.books, isEmpty);
    expect(plan.problems, hasLength(1));
  });

  test('a one-shot renamed: its series - named by its file - gets the new id with it', () async {
    await open({
      'lib/Night.cbz': _cbz,
      'lib/.bedereader.json': _json({'books': {'Night.cbz': {'title': 'One Night'}}}),
    });
    final was = (await local.book(idOf('Night.cbz')))!['seriesId'] as String;
    await apply();
    final now = (await local.book(idOf('One Night.cbz')))!['seriesId'] as String;
    expect(told, containsPair(was, now));
  });

  test("a name the plan can't use isn't used: the folder the series wants is taken - said, the rest goes on", () async {
    await open({..._library(), 'lib/Saga (2012)/x.cbz': _cbz});
    final plan = await local.planApply(library);
    expect(plan.folders, isEmpty);
    expect(plan.problems, hasLength(1));
    final r = await local.applyEdits(plan);
    expect(r.failures, isEmpty);
    expect(fs.files.keys, contains('lib/Saga/Saga (2012) 001.cbz'), reason: 'renamed where it is');
    expect(fs.files.keys.where((k) => k.endsWith('.cbz') || k.endsWith('.cbr')), hasLength(6));
  });

  test("what's kept under a book's or series' id elsewhere follows it to its new id: its pin, On deck hidden, its "
      "pairing, a series' reader settings, a book's eBook settings, highlights, a webtoon's place", () async {
    const ids = {'lbOLD': 'lbNEW', 'lsOLD': 'lsNEW'};
    final s = AppSettings.instance, h = OnDeckHidden.instance, pins = Pins.instance, pair = PairShift.instance;
    addTearDown(() {
      s.resetAllSeries();
      h.reset();
      pair.reset();
    });
    pins.add(const Pin(name: 'Saga #1', kind: 'book', id: 'lbOLD', title: 'Saga'));
    h.setBook('lbOLD', true);
    pair.setShifted('lbOLD', true);
    s.setSeries('lsOLD', s.prefsFor('lsOLD'));
    s.setEpubBook('lbOLD', s.epub);
    final p = await SharedPreferences.getInstance();
    await p.setString('highlights.lbOLD', '[]');
    await StripPlaces.save('lbOLD', 3, 0.5);

    pins.renameIds(ids);
    h.renameIds(ids);
    pair.renameIds(ids);
    s.renameIds(ids);
    await BookHighlights.renameIds(ids);
    await StripPlaces.renameIds(ids);

    expect([for (final x in pins.items) x.id], allOf(contains('lbNEW'), isNot(contains('lbOLD'))));
    expect((h.bookHidden('lbNEW'), h.bookHidden('lbOLD')), (true, false));
    expect((pair.shifted('lbNEW'), pair.shifted('lbOLD')), (true, false));
    expect((s.series.containsKey('lsNEW'), s.series.containsKey('lsOLD')), (true, false));
    expect((s.epubBooks.containsKey('lbNEW'), s.epubBooks.containsKey('lbOLD')), (true, false));
    expect((p.getString('highlights.lbNEW'), p.getString('highlights.lbOLD')), ('[]', null));
    expect(await StripPlaces.load('lbNEW'), (3, 0.5));
    expect(await StripPlaces.load('lbOLD'), isNull);
  });
}
