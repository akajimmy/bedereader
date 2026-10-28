// Apply edits to files (user, 2026-10-27; reports\10-27-apply-edits-plan.md): a library's edits, kept alongside its
// books, put into the files when asked - written in, files and folders renamed, books moved - and the alongside files,
// reading progress and the rest following the books.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/local/apply_edits.dart';
import 'package:komga_reader/local/file_zip.dart';
import 'package:komga_reader/local/local_library.dart';
import 'package:komga_reader/local/local_source.dart';
import 'package:komga_reader/highlights.dart';
import 'package:komga_reader/ondeck_hidden.dart';
import 'package:komga_reader/pins.dart';
import 'package:komga_reader/reader/comic_renderer.dart' show StripPlaces;
import 'package:komga_reader/screens/apply_edits_dialog.dart';
import 'package:komga_reader/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_fs.dart';
import 'support/zip_writer.dart';

final _page = Uint8List.fromList([...pngHead(10, 10), 1, 2, 3]);
final _cbz = zipOf({'1.png': _page});
final _cbr = File('test/fixtures/rar/synthetic_comic.cbr').readAsBytesSync();
Uint8List _json(Object j) => Uint8List.fromList(utf8.encode(jsonEncode(j)));
Map _read(MemoryFs fs, String path) => jsonDecode(utf8.decode(fs.files[path]!)) as Map;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  late MemoryFs fs;
  late LocalSource local;
  const library = LocalLibrary('lib', 'lib');

  /// Saga (its title edited), its #1 (a CBZ: title, number, date edited) and #2 (a CBR: number edited); Paper Girls
  /// #1 moved to a series of its own, Saga Deluxe, whose publisher was edited; Paper Girls #2 not edited.
  Future<void> open({Map<String, Uint8List> also = const {}}) async {
    fs = MemoryFs({
      'lib/Saga/Saga 01.cbz': _cbz,
      'lib/Saga/Saga 02.cbr': _cbr,
      'lib/Saga/series.json': _json({'metadata': {'name': 'Saga (2012)'}}),
      'lib/Saga/.bedereader.json': _json({'books': {
        'Saga 01.cbz': {'title': 'Chapter One', 'number': '1', 'releaseDate': '2012-03-14'},
        'Saga 02.cbr': {'number': '2'},
      }}),
      'lib/Paper Girls/Paper Girls 01.cbz': _cbz,
      'lib/Paper Girls/Paper Girls 02.cbz': _cbz,
      'lib/Paper Girls/.bedereader.json': _json({'books': {'Paper Girls 01.cbz': {'series': 'Saga Deluxe'}}}),
      'lib/.bedereader.json': _json({'series': {'name:saga deluxe': {'publisher': 'Image'}}}),
      ...also,
    });
    final data = await Directory.systemTemp.createTemp('apply');
    local = await LocalSource.open(data, [library], fsFor: (_) => fs);
    addTearDown(() async {
      await local.closeFiles();
      await data.delete(recursive: true);
    });
    await local.rescan();
  }

  String idOf(String file) => local.entries.values
      .firstWhere((e) => (e['book'] as Map)['url'].toString().endsWith(file))['book']['id'] as String;

  test('the plan: the edited series\' folder renamed, its books renamed by the pattern, a moved book into a folder '
      'made for its new series; what goes into a file is only what was edited - nothing for a CBR, nor an unedited '
      'book', () async {
    await open();
    final plan = await local.planApply(library);
    expect([for (final f in plan.folders) (f.from, f.to)], [('lib/Saga', 'lib/Saga (2012)')]);
    final steps = {for (final b in plan.books) b.from: b};
    expect(steps.keys, unorderedEquals(['lib/Saga/Saga 01.cbz', 'lib/Saga/Saga 02.cbr', 'lib/Paper Girls/Paper Girls 01.cbz']));
    expect(steps['lib/Saga/Saga 01.cbz']!.to, 'lib/Saga (2012)/Saga (2012) 001.cbz', reason: 'its year in the series name');
    expect(steps['lib/Saga/Saga 02.cbr']!.to, 'lib/Saga (2012)/Saga (2012) 002.cbr');
    expect(steps['lib/Paper Girls/Paper Girls 01.cbz']!.to, 'lib/Saga Deluxe/Saga Deluxe 001.cbz');
    final one = steps['lib/Saga/Saga 01.cbz']!.write!;
    expect((one.title, one.number, one.releaseDate, one.series, one.summary), ('Chapter One', '1', '2012-03-14', 'Saga (2012)', null));
    expect(steps['lib/Saga/Saga 02.cbr']!.write, isNull);
    expect(steps['lib/Paper Girls/Paper Girls 01.cbz']!.write!.series, 'Saga Deluxe');
    expect(plan.carried, isEmpty);
    expect(plan.fieldsWritten, {'title', 'series', 'number', 'releaseDate'});
  });

  test("the confirmation's lines: one for each kind of change made; the fields written named only if edited; CBZ and "
      'CBR told apart only when both are there - and with only CBRs, nothing said about writing into files', () async {
    await open();
    final lines = applySummary(await local.planApply(library));
    expect(lines, hasLength(4)); // the folder, the move, the renames, the writing
    final writing = lines.last;
    expect(writing, allOf(contains('title'), contains('number'), contains('release date'), isNot(contains('summary')),
        isNot(contains('credits')), contains('CBR')));
    // only CBRs edited: no writing at all
    final cbrsOnly = applySummary(ApplyPlan(library, const [], [
      for (final b in (await local.planApply(library)).books) if (b.cbr) b,
    ], const []));
    expect(cbrsOnly, hasLength(1));
    expect(cbrsOnly.single, isNot(contains('written into')));
    // only CBZs written: no CBR said
    final cbzOnly = applySummary(ApplyPlan(library, const [], [
      for (final b in (await local.planApply(library)).books) if (!b.cbr) b,
    ], const []));
    expect(cbzOnly.last, isNot(contains('CBR')));
  });

  test('the run: written into, renamed and moved; the alongside files follow - entries under their new names, the new '
      "series' edits in its folder's series.json - reading progress follows the books; run again, nothing to do",
      () async {
    await open();
    await local.setProgress(idOf('Saga 01.cbz'), 5);
    await local.setProgress(idOf('Paper Girls 02.cbz'), 3); // (not edited: its id doesn't change)
    final before = idOf('Saga 01.cbz'), cbrBytes = fs.files['lib/Saga/Saga 02.cbr'];
    Map<String, String>? told;
    local.onMoved = (ids) => told = ids;
    final r = await local.applyEdits(await local.planApply(library));
    expect(r.failures, isEmpty);
    expect(fs.files.keys, containsAll([
      'lib/Saga (2012)/Saga (2012) 001.cbz', 'lib/Saga (2012)/Saga (2012) 002.cbr', 'lib/Saga (2012)/series.json',
      'lib/Saga Deluxe/Saga Deluxe 001.cbz', 'lib/Saga Deluxe/series.json', 'lib/Paper Girls/Paper Girls 02.cbz',
    ]));
    expect(fs.files.keys.where((k) => k.startsWith('lib/Saga/')), isEmpty);
    expect(fs.files['lib/Saga (2012)/Saga (2012) 002.cbr'], cbrBytes, reason: 'a CBR: renamed only');
    final z = await FileZip.open(await fs.open('lib/Saga (2012)/Saga (2012) 001.cbz'));
    final info = utf8.decode((await z.read('ComicInfo.xml'))!);
    await z.close();
    expect(info, allOf(contains('<Title>Chapter One</Title>'), contains('<Series>Saga (2012)</Series>'),
        contains('<Year>2012</Year>')));
    expect((_read(fs, 'lib/Saga (2012)/.bedereader.json')['books'] as Map).keys,
        unorderedEquals(['Saga (2012) 001.cbz', 'Saga (2012) 002.cbr']));
    expect((_read(fs, 'lib/Saga Deluxe/.bedereader.json')['books'] as Map).keys, ['Saga Deluxe 001.cbz']);
    expect(_read(fs, 'lib/Saga Deluxe/series.json')['metadata'], containsPair('publisher', 'Image'));
    expect(_read(fs, 'lib/.bedereader.json')['series'], isEmpty);
    // listed as before, under the new paths - and their progress with them
    final now = idOf('Saga (2012) 001.cbz');
    expect(told, containsPair(before, now));
    final b = (await local.book(now))!;
    expect([b['metadata']['title'], b['seriesTitle'], b['readProgress']?['page']], ['Chapter One', 'Saga (2012)', 5]);
    expect((await local.book(idOf('Saga Deluxe 001.cbz')))!['seriesTitle'], 'Saga Deluxe');
    expect((await local.book(idOf('Paper Girls 02.cbz')))!['readProgress']?['page'], 3);
    // repeatable: done already, nothing to do
    final again = await local.planApply(library);
    expect(again.isEmpty, isTrue, reason: '${[for (final s in again.books) '${s.from} -> ${s.to} ${s.write}']}');
  });

  test("a step that can't be done is said, and the rest go on; nothing is lost", () async {
    await open(also: {'lib/Saga (2012)/x.cbz': _cbz}); // (the folder name the series wants is taken)
    final plan = await local.planApply(library);
    expect(plan.folders, isEmpty);
    expect(plan.problems, hasLength(1));
    final r = await local.applyEdits(plan);
    expect(r.failures, isEmpty);
    expect(fs.files.keys, contains('lib/Saga/Saga (2012) 001.cbz'), reason: 'renamed where it is');
    expect(fs.files.keys.where((k) => k.endsWith('.cbz') || k.endsWith('.cbr')), hasLength(5));
  });

  test("what's kept under a book's or series' id elsewhere follows it to its new id: its pin, On deck hidden, a "
      "series' reader settings, a book's eBook settings, highlights, a webtoon's place", () async {
    const ids = {'lbOLD': 'lbNEW', 'lsOLD': 'lsNEW'};
    final s = AppSettings.instance, h = OnDeckHidden.instance, pins = Pins.instance;
    addTearDown(() {
      s.resetAllSeries();
      h.reset();
    });
    pins.add(const Pin(name: 'Saga #1', kind: 'book', id: 'lbOLD', title: 'Saga'));
    h.setBook('lbOLD', true);
    s.setSeries('lsOLD', s.prefsFor('lsOLD'));
    s.setEpubBook('lbOLD', s.epub);
    final p = await SharedPreferences.getInstance();
    await p.setString('highlights.lbOLD', '[]');
    await StripPlaces.save('lbOLD', 3, 0.5);

    pins.renameIds(ids);
    h.renameIds(ids);
    s.renameIds(ids);
    await BookHighlights.renameIds(ids);
    await StripPlaces.renameIds(ids);

    expect([for (final x in pins.items) x.id], contains('lbNEW'));
    expect([for (final x in pins.items) x.id], isNot(contains('lbOLD')));
    expect((h.bookHidden('lbNEW'), h.bookHidden('lbOLD')), (true, false));
    expect((s.series.containsKey('lsNEW'), s.series.containsKey('lsOLD')), (true, false));
    expect((s.epubBooks.containsKey('lbNEW'), s.epubBooks.containsKey('lbOLD')), (true, false));
    expect((p.getString('highlights.lbNEW'), p.getString('highlights.lbOLD')), ('[]', null));
    expect(await StripPlaces.load('lbNEW'), (3, 0.5));
    expect(await StripPlaces.load('lbOLD'), isNull);
  });
}
