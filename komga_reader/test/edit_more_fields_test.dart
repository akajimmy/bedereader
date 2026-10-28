// Metadata editing, more fields (user, 2026-10-27): a book's sort number, summary, credits and tags; a series'
// summary, genres and tags - on Komga, and kept alongside local and network books (and what goes into the files when
// edits are applied to them).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/local/in_file_meta.dart';
import 'package:komga_reader/local/local_library.dart';
import 'package:komga_reader/local/local_meta.dart';
import 'package:komga_reader/local/local_source.dart';
import 'package:komga_reader/screens/edit_metadata.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_fs.dart';
import 'support/no_network.dart';
import 'support/zip_writer.dart';

final _page = Uint8List.fromList([...pngHead(10, 10), 1, 2, 3]);
Uint8List _cbz([String? info]) => zipOf({'1.png': _page, if (info != null) 'ComicInfo.xml': info});

Map<String, dynamic> _book() => {
      'id': 'B1', 'seriesId': 'S1', 'seriesTitle': 'Saga', 'libraryId': 'L1',
      'metadata': {
        'title': 'Chapter One', 'number': '1', 'numberSort': 1, 'summary': 'Old.',
        'authors': [
          {'name': 'Brian K. Vaughan', 'role': 'writer'}, {'name': 'Fiona Staples', 'role': 'penciller'},
          {'name': 'Eric Stephenson', 'role': 'editor'},
        ],
        'tags': ['space', 'war'],
      },
    };

class _Saved extends TestKomga {
  final saved = <String, Map<String, Object?>>{};
  @override
  Future<bool> canEditMetadata(String id) async => true;
  @override
  Future<void> editBookMetadata(String bookId, Map<String, Object?> changes) async => saved[bookId] = changes;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the changes sent', () {
    Map<String, Object?> changes({String number = '1', String? sort, String? summary, Map<String, String>? credits,
            String? tags}) =>
        bookChanges(_book(), title: 'Chapter One', number: number, date: null, sort: sort, summary: summary,
            credits: credits, tags: tags);
    Map<String, String> creditsAsIs() => {for (final r in editedRoles.keys) r: creditsText(_book(), r)};

    test('nothing changed, nothing sent: the credits and tags as they were, in any order', () {
      expect(changes(sort: '1', summary: 'Old.', credits: creditsAsIs(), tags: 'war, space'), isEmpty);
    });

    test("a sort number apart from the number (an Annual between 12 and 13); one not typed follows the number", () {
      expect(changes(number: 'Annual', sort: '12.5'), {'number': 'Annual', 'numberSort': 12.5});
      expect(changes(number: '3'), {'number': '3', 'numberSort': 3});
      expect(changes(sort: '1.5'), {'numberSort': 1.5});
    });

    test("credits: all of them sent, the roles not edited (an editor) kept; summary and tags as typed", () {
      final c = changes(summary: ' New. ', credits: {...creditsAsIs(), 'penciller': 'Fiona Staples, Jim Lee'},
          tags: 'space, war, drama');
      expect(c['summary'], 'New.');
      expect(c['tags'], ['space', 'war', 'drama']);
      expect({for (final a in c['authors'] as List) '${a['role']}|${a['name']}'}, {
        'writer|Brian K. Vaughan', 'penciller|Fiona Staples', 'penciller|Jim Lee', 'editor|Eric Stephenson',
      });
    });

    test('a series: summary, genres and tags', () {
      final s = {'id': 'S1', 'metadata': {'title': 'Saga', 'summary': '', 'genres': ['Sci-fi'], 'tags': []}};
      expect(seriesChanges(s, title: 'Saga', titleSort: '', readingDirection: null, status: null, publisher: '',
          summary: 'Star-crossed.', genres: 'Sci-fi, Fantasy', tags: ''),
          {'summary': 'Star-crossed.', 'genres': ['Sci-fi', 'Fantasy']});
    });
  });

  testWidgets('the sort number follows the number as it is typed, until it is changed by hand', (tester) async {
    final api = noNetwork(_Saved.new);
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) => TextButton(
        onPressed: () => editBook(c, api, _book()), child: const Text('go')))));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    String sortShown() => tester.widget<TextField>(find.byKey(const ValueKey('edit-sort-number'))).controller!.text;
    expect(sortShown(), '1');
    await tester.enterText(find.byKey(const ValueKey('edit-number')), '7');
    expect(sortShown(), '7');
    await tester.enterText(find.byKey(const ValueKey('edit-sort-number')), '6.5');
    await tester.enterText(find.byKey(const ValueKey('edit-number')), 'Annual');
    expect(sortShown(), '6.5');
    await tester.ensureVisible(find.byKey(const ValueKey('edit-save')));
    await tester.tap(find.byKey(const ValueKey('edit-save')));
    await tester.pumpAndSettle();
    expect(api.saved['B1'], {'number': 'Annual', 'numberSort': 6.5});
  });

  group('the files', () {
    test('ComicInfo.xml: summary, each role its field (names by commas), tags; a role emptied is taken out', () {
      final x = comicInfoWith('<ComicInfo>\n  <Inker>Someone</Inker>\n</ComicInfo>', const BookEdits(
          summary: 'A war.', tags: ['space', 'war'],
          authors: [('Brian K. Vaughan', 'writer'), ('Fiona Staples', 'penciller'), ('Jim Lee', 'penciller')]));
      expect(x, allOf(contains('<Summary>A war.</Summary>'), contains('<Writer>Brian K. Vaughan</Writer>'),
          contains('<Penciller>Fiona Staples, Jim Lee</Penciller>'), contains('<Tags>space, war</Tags>'),
          isNot(contains('Inker'))));
    });

    test("an EPUB's package file: dc:description, dc:creator for writers and dc:contributor for the others, "
        'dc:subject for each tag - the old ones replaced', () {
      const opf = '<package><metadata>\n    <dc:creator>Old</dc:creator>\n    <dc:subject>x</dc:subject>\n'
          '  </metadata></package>';
      final x = opfWith(opf, const BookEdits(summary: 'S', authors: [('Frank Herbert', 'writer'), ('Jo', 'cover')],
          tags: ['sf', 'desert']));
      expect(x, allOf(contains('<dc:description>S</dc:description>'), contains('<dc:creator>Frank Herbert</dc:creator>'),
          contains('<dc:contributor>Jo</dc:contributor>'), contains('<dc:subject>sf</dc:subject>'),
          contains('<dc:subject>desert</dc:subject>'), isNot(contains('Old')), isNot(contains('>x<'))));
    });
  });

  group('local and network books', () {
    late MemoryFs fs;
    late LocalSource local;
    Future<void> open() async {
      fs = MemoryFs({'lib/Saga/Saga 01.cbz': _cbz(), 'lib/Saga/Saga 02.cbz': _cbz()});
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
