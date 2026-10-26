// What a library folder holds, said when it's added (user, 2026-10-26: "This library contains:"): one folder per
// series (as before), one series in all of it, or a read list - books of several series in an order, each book's
// series from its ComicInfo.xml, else its file name (reports\10-26-read-list-series.md).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:komga_reader/local/folder_browser.dart';
import 'package:komga_reader/local/folder_komga.dart';
import 'package:komga_reader/local/folder_scan.dart';
import 'package:komga_reader/local/mixed_komga.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/zip_writer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root, data;
  late List<int> png;

  setUpAll(() async => png = await solidPng(2, 3));
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('kinds_lib');
    data = await Directory.systemTemp.createTemp('kinds_data');
  });
  tearDown(() async {
    await deleteTemp(root);
    await deleteTemp(data);
  });

  Future<void> put(String rel, {String? series, String? number}) async {
    final f = File('${root.path}${Platform.pathSeparator}${rel.replaceAll('/', Platform.pathSeparator)}');
    await f.parent.create(recursive: true);
    await f.writeAsBytes(zipOf({
      '1.png': png,
      if (series != null || number != null)
        'ComicInfo.xml': '<ComicInfo>${series == null ? '' : '<Series>$series</Series>'}'
            '${number == null ? '' : '<Number>$number</Number>'}</ComicInfo>',
    }));
  }

  test("a book's series from its file name, in a read list: up to its number, without a reading order at the start "
      'or a "Vol." before the number', () {
    expect(seriesFromName('002 - Green Lantern 021(2007)(2 covers)(Digital)(TLK-EMPIRE-HD)'), 'Green Lantern');
    expect(seriesFromName('007 - Tales of the Sinestro Corps - Parallax (2007) (Minutemen-Ace of Scans)'),
        'Tales of the Sinestro Corps - Parallax', reason: 'no number: the whole name');
    expect(seriesFromName('Spider-Island - Cloak & Dagger (2011) #002'), 'Spider-Island - Cloak & Dagger');
    expect(seriesFromName('Fables (2002) Vol. 22 - Farewell'), 'Fables');
    expect(seriesFromName('White Sand (2016) v 3'), 'White Sand');
    // "v03" isn't a number of its own: taking it for one would put Green Lantern v3 and v5 in one series
    expect(seriesFromName('Brightest Day v01 (2010)'), 'Brightest Day v01');
    expect(seriesFromName('Absolute Batman 010 (2025) (Digital) (Shan-Empire)'), 'Absolute Batman');
  });

  test('one series: every book in the folder and its subfolders, one series named after the folder, folder by '
      'folder', () async {
    await put('Book 2.cbz');
    await put('Vol 1/Book 1.cbz');
    await put('Vol 1/Book 10.cbz');
    await put('Vol 2/Book 1.cbz');
    final api = await FolderKomga.open([LocalLibrary.at(root.path, kind: LibraryKind.oneSeries)], dataDir: data);
    final series = (await api.series(size: 50))['content'] as List;
    expect([for (final s in series) s['name']], [root.path.split(Platform.pathSeparator).last]);
    final books = (await api.seriesBooks(series.single['id'] as String))['content'] as List;
    String rel(Map b) => (b['url'] as String).substring(root.path.length + 1).replaceAll(r'\', '/');
    expect([for (final b in books) rel(b as Map)], ['Book 2.cbz', 'Vol 1/Book 1.cbz', 'Vol 1/Book 10.cbz', 'Vol 2/Book 1.cbz']);
  });

  group('a read list', () {
    late FolderKomga api;
    late LocalLibrary lib;

    setUp(() async {
      // the Sinestro Corps War's way: a reading order, then the book; one with ComicInfo, one with neither
      await put('001 - Green Lantern Sinestro Corps Special 001 (2006).cbz');
      await put('002 - Green Lantern 021 (2007).cbz');
      await put('003 - Green Lantern Corps 014 (2007).cbz');
      await put('004 - Green Lantern 022 (2007).cbz');
      await put('005 - GL C 015.cbz', series: 'Green Lantern Corps', number: '15');
      await put('006 - Tales of the Sinestro Corps - Parallax (2007).cbz');
      await put('Extras/007 - Green Lantern 023.cbz', series: 'Green Lantern'); // (a subfolder: after, by path)
      lib = LocalLibrary.at(root.path, kind: LibraryKind.readList);
      api = await FolderKomga.open([lib], dataDir: data);
    });

    List<String> names(List books) => [for (final b in books) (b as Map)['name'] as String];

    test("the library is a read list named after it, its books in the folder's order", () async {
      final lists = (await api.readLists())['content'] as List;
      expect([for (final l in lists) l['name']], [lib.name]);
      expect(lists.single['id'], lib.readListId);
      final books = (await api.readListBooks(lib.readListId))['content'] as List;
      expect(names(books), [
        '001 - Green Lantern Sinestro Corps Special 001 (2006)', '002 - Green Lantern 021 (2007)',
        '003 - Green Lantern Corps 014 (2007)', '004 - Green Lantern 022 (2007)', '005 - GL C 015',
        '006 - Tales of the Sinestro Corps - Parallax (2007)', '007 - Green Lantern 023',
      ]);
      // read on from the list: the next book, whatever its series
      final second = books[1] as Map;
      expect((await api.nextBook(second['id'] as String, readListId: lib.readListId))?['name'],
          '003 - Green Lantern Corps 014 (2007)');
      expect([for (final r in await api.bookReadLists(second['id'] as String)) r['id']], [lib.readListId]);
      expect(api.isLocal(lib.readListId), isTrue);
      expect(isLocalId(lib.readListId), isTrue, reason: "its pin stays on this device (pins.dart)");
      expect(api.readListThumb(lib.readListId), api.bookThumb(books.first['id'] as String));
    });

    test("each book's series from its ComicInfo, else its name - the reading order isn't the issue", () async {
      final series = {
        for (final s in (await api.series(size: 50))['content'] as List) s['name'] as String: s['id'] as String,
      };
      expect(series.keys.toSet(), {
        'Green Lantern Sinestro Corps Special', 'Green Lantern', 'Green Lantern Corps',
        'Tales of the Sinestro Corps - Parallax',
      });
      Future<List<String>> numbers(String name) async => [
            for (final b in (await api.seriesBooks(series[name]!))['content'] as List)
              ((b as Map)['metadata'] as Map)['number'] as String,
          ];
      expect(await numbers('Green Lantern'), ['21', '22', '23'],
          reason: "the subfolder's: its series from ComicInfo, which has no number - the name's");
      expect(await numbers('Green Lantern Corps'), ['14', '15'], reason: "one by its name, one by its ComicInfo");
    });

    test("removed: its read list's pin goes with it", () async {
      final removed = <String>{};
      FolderKomga.onRemoved = removed.addAll;
      addTearDown(() => FolderKomga.onRemoved = null);
      await api.setLibraries([]);
      expect(removed, contains(lib.readListId));
    });

    test("kept with the library: saved and loaded again as a read list; renamed, its read list's name follows",
        () async {
      await api.setLibraries([lib.renamed('Sinestro Corps War')]);
      expect((await FolderKomga.savedLibraries()).single.kind, LibraryKind.readList);
      expect([for (final l in (await api.readLists())['content'] as List) l['name']], ['Sinestro Corps War']);
    });

    test("beside Komga: Komga's read lists and this one in one list; the local one answered here, Komga not asked",
        () async {
      final asked = <String>[];
      final mixed = MixedKomga('http://komga.test', 'key', client: MockClient((r) async {
        asked.add(r.url.path);
        final body = r.url.path == '/api/v1/readlists'
            ? {'content': [{'id': '0RL', 'name': 'Civil War', 'bookIds': []}], 'totalElements': 1, 'last': true}
            : null;
        return body == null ? http.Response('', 404) : http.Response(jsonEncode(body), 200,
            headers: {'content-type': 'application/json'});
      }));
      mixed.local = api;
      expect([for (final l in (await mixed.readLists())['content'] as List) l['name']], ['Civil War', lib.name]);
      asked.clear();
      expect(names((await mixed.readListBooks(lib.readListId))['content'] as List), hasLength(7));
      expect((await mixed.readList(lib.readListId))?['name'], lib.name);
      final first = ((await mixed.readListBooks(lib.readListId))['content'] as List).first as Map;
      expect((await mixed.nextBook(first['id'] as String, readListId: lib.readListId))?['name'],
          '002 - Green Lantern 021 (2007)');
      expect(asked, isEmpty);
    });
  });

  testWidgets('adding a library asks what it holds; the answer is the library\'s, Cancel adds nothing', (t) async {
    LibraryKind? got = LibraryKind.seriesFolders;
    await t.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(
        onPressed: () async => got = await askLibraryKind(context), child: const Text('ask')))));
    await t.tap(find.text('ask'));
    await t.pumpAndSettle();
    await t.tap(find.byIcon(libraryKindIcon(LibraryKind.readList)));
    await t.pumpAndSettle();
    expect(got, LibraryKind.readList);
    await t.tap(find.text('ask'));
    await t.pumpAndSettle();
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(got, isNull);
  });
}
