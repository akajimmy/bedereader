// What a library folder holds (rebuild step 11; lib/local/local_library.dart's LibraryKind, local_scan.dart): one
// folder per series, one series, or a read list - and a series' books titled without the start their names share.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/local/local_library.dart';
import 'package:komga_reader/local/local_scan.dart';
import 'package:komga_reader/local/local_source.dart';
import 'package:komga_reader/local/local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_fs.dart';
import 'support/zip_writer.dart';

final _page = Uint8List.fromList([...pngHead(10, 10), 1, 2, 3]);
Uint8List _cbz({String? info}) => zipOf({'1.png': _page, if (info != null) 'ComicInfo.xml': info});

/// The books of a scan, in their order, by what's asked of each.
List<T> _books<T>(ScanResult r, T Function(LocalBook b) f) =>
    [for (final b in r.index.books.values.toList()..sort((a, b) => a.numberSort.compareTo(b.numberSort))) f(b)];

void main() {
  test("one folder per series: a series' books titled without the start their names share (user, 2026-10-26: "
      '"Green Lantern Mosaic 012 (1993)" is "012 (1993)"); a title in its ComicInfo still wins', () async {
    final fs = MemoryFs({
      'lib/Green Lantern Mosaic/Green Lantern Mosaic 012 (1993).cbz': _cbz(),
      'lib/Green Lantern Mosaic/Green Lantern Mosaic 013 (1993).cbz':
          _cbz(info: '<ComicInfo><Title>The Last Stand</Title></ComicInfo>'),
      'lib/Loose One-Shot.cbz': _cbz(),
    });
    final r = await scanLibrary(fs, const LocalLibrary('lib', 'lib'), null);
    final titles = {for (final b in r.index.books.values) b.path.split('/').last: b.title};
    expect(titles['Green Lantern Mosaic 012 (1993).cbz'], '012 (1993)');
    expect(titles['Green Lantern Mosaic 013 (1993).cbz'], 'The Last Stand');
    expect(titles['Loose One-Shot.cbz'], 'Loose One-Shot', reason: 'a one-shot: its whole name');
  });

  test('one series: every book in the folder and its subfolders, one series named after the folder, folder by folder '
      '("Vol 2/Book 1" after "Vol 1/Book 10")', () async {
    final fs = MemoryFs({
      'Saga/Vol 2/Book 1.cbz': _cbz(),
      'Saga/Vol 1/Book 10.cbz': _cbz(),
      'Saga/Vol 1/Book 2.cbz': _cbz(),
      'Saga/Extra.cbz': _cbz(),
    });
    final r = await scanLibrary(fs, const LocalLibrary('Saga', 'Saga', kind: LibraryKind.oneSeries), null);
    expect([for (final s in r.index.series.values) s.name], ['Saga']);
    expect(_books(r, (b) => b.path), ['Saga/Extra.cbz', 'Saga/Vol 1/Book 2.cbz', 'Saga/Vol 1/Book 10.cbz',
        'Saga/Vol 2/Book 1.cbz']);
  });

  test("a read list: its books in one list by their names' order, each in its series - its ComicInfo's, else its "
      "name's (the \"001 - \" not its number); scanned again with one added, the places move up, the series stay",
      () async {
    final files = {
      'Order/001 - Green Lantern 021 (2007).cbz': _cbz(),
      'Order/002 - Batman 005.cbz': _cbz(info: '<ComicInfo><Series>Batman (2016)</Series><Number>5</Number></ComicInfo>'),
      'Order/003 - Green Lantern 022 (2007).cbz': _cbz(),
    };
    const library = LocalLibrary('Order', 'Order', kind: LibraryKind.readList);
    final r = await scanLibrary(MemoryFs(files), library, null);
    final series = {for (final s in r.index.series.values) s.id: s.name};
    expect(series.values.toSet(), {'Green Lantern', 'Batman (2016)'});
    final places = {
      for (final b in r.index.books.values) b.path.split('/').last: (b.readLists.single.index, series[b.seriesId], b.number),
    };
    expect(places, {
      '001 - Green Lantern 021 (2007).cbz': (0, 'Green Lantern', '21'),
      '002 - Batman 005.cbz': (1, 'Batman (2016)', '5'),
      '003 - Green Lantern 022 (2007).cbz': (2, 'Green Lantern', '22'),
    });
    expect(r.index.books.values.every((b) => b.readLists.single.id == library.readListId && b.readLists.single.count == 3),
        isTrue);

    final again = await scanLibrary(MemoryFs({...files, 'Order/000 - Prologue.cbz': _cbz()}), library, r.index);
    final moved = {for (final b in again.index.books.values) b.path.split('/').last: b.readLists.single.index};
    expect(moved['000 - Prologue.cbz'], 0);
    expect(moved['003 - Green Lantern 022 (2007).cbz'], 3);
    expect({for (final s in again.index.series.values) s.name}, {'Green Lantern', 'Batman (2016)', 'Prologue'});
  });

  test('the kind is kept with the library; one saved before kinds is one folder per series', () {
    const l = LocalLibrary('Order', 'Order', kind: LibraryKind.readList);
    expect(LocalLibrary.fromJson(l.toJson()).kind, LibraryKind.readList);
    expect(LocalLibrary.fromJson({'name': 'x', 'path': 'x'}).kind, LibraryKind.seriesFolders);
    expect(l.renamed('Reading order').kind, LibraryKind.readList);
  });

  test("a read-list library's list among the read lists, named after the library, its books in order; a book's "
      'read lists say it', () async {
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('kinds_lib');
    final data = await Directory.systemTemp.createTemp('kinds_data');
    for (final n in ['002 - Batman 005.cbz', '001 - Green Lantern 021.cbz']) {
      File('${root.path}${Platform.pathSeparator}$n').writeAsBytesSync(_cbz());
    }
    final local = await LocalSource.open(data, [LocalLibrary('Reading order', root.path, kind: LibraryKind.readList)]);
    addTearDown(() async {
      await local.closeFiles();
      await root.delete(recursive: true);
      await data.delete(recursive: true);
    });
    await local.rescan();
    final lists = (await local.readLists())['content'] as List;
    expect([for (final l in lists) l['name']], ['Reading order']);
    final books = (await local.readListBooks(lists.single['id'] as String))['content'] as List;
    expect([for (final b in books) (b['name'] as String).split(' - ').first], ['001', '002']);
    expect([for (final l in await local.bookReadLists(books.first['id'] as String)) l['name']], ['Reading order']);
  });
}
