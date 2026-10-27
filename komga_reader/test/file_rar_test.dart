// CBR comics (rebuild step 10; user, 2026-10-25: "komga should support CBR too"): RAR4 and RAR5, stored and
// compressed, read in place like a CBZ (lib/local/file_rar.dart) - the scan lists them, their pages open, a page's
// size from its start.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/local/file_rar.dart';
import 'package:komga_reader/local/file_zip.dart';
import 'package:komga_reader/local/library_fs.dart';
import 'package:komga_reader/local/local_library.dart';
import 'package:komga_reader/local/local_source.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_fs.dart';
import 'support/rar_writer.dart';
import 'support/zip_writer.dart';

/// A page: a PNG's head (its size) and some bytes.
Uint8List _png(int w, int h) => Uint8List.fromList([...pngHead(w, h), ...List.generate(200, (i) => i & 0xff)]);

void main() {
  final sep = Platform.pathSeparator;
  // (koni_rar's own fixtures, made with rar: RAR5 compressed pages; RAR4 compressed with the x86 filter; a solid one)
  final fixtures = '${Directory.current.path}${sep}test${sep}fixtures${sep}rar';
  Uint8List fixture(String name) => File('$fixtures$sep$name').readAsBytesSync();

  test('a stored RAR4: its files listed, each read whole, or just its start; closing it lets its file go', () async {
    final png = _png(30, 20);
    final fs = MemoryFs({'a.cbr': rarOf({'01.png': png, 'ComicInfo.xml': '<ComicInfo><Title>Rar</Title></ComicInfo>'})});
    final a = await ComicArchive.open(fs, 'a.cbr');
    expect(a, isA<FileRar>());
    expect(a.mediaType, 'application/x-rar-compressed');
    expect(a.names, ['01.png', 'ComicInfo.xml']);
    expect(a.find('comicinfo.XML'), 'ComicInfo.xml');
    expect(await a.read('01.png'), png);
    expect(await a.head('01.png', 24), png.sublist(0, 24));
    expect(imageSizeOf((await a.head('01.png', 64 * 1024))!), (30, 20));
    expect(await a.read('nothing.png'), isNull);
    await a.close();
    expect(() => a.read('01.png'), throwsStateError);
  });

  test('compressed: RAR5 pages, a RAR4 file through its filter, one in a solid RAR4 - the start alone is the same '
      'as the start of the whole', () async {
    final fs = MemoryFs({
      for (final n in ['synthetic_comic.cbr', 'filter_e8.rar', 'solid_rar4.rar']) n: fixture(n),
    });
    for (final (name, entry, size) in [
      ('synthetic_comic.cbr', 'comic/page002.png', 1032),
      ('filter_e8.rar', 'x86call.bin', 12016),
      ('solid_rar4.rar', 'solidbig/part3.txt', 3305), // (solid: each file follows on from the one before)
    ]) {
      final a = await ComicArchive.open(fs, name);
      addTearDown(a.close);
      final whole = await a.read(entry);
      expect(whole, hasLength(size), reason: name);
      expect(await a.head(entry, 100), whole!.sublist(0, 100), reason: name);
    }
  });

  test('a CBR cut short (a copy that stopped part-way) is damaged - not opened with the pages it still lists (tablet, '
      '2026-10-25: one cut at 4 KB came in as a book whose page never loaded); a RAR head and nothing after, too',
      () async {
    final whole = rarOf({'1.png': _png(30, 20), '2.png': _png(20, 30)});
    final fs = MemoryFs({
      'stored.cbr': whole.sublist(0, whole.length - 60), // (the second page's data cut, its header there)
      'rar5.cbr': fixture('synthetic_comic.cbr').sublist(0, 400),
      'head.cbr': Uint8List.fromList([0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x01, 0x00, ...List.filled(40, 0)]),
    });
    for (final name in fs.files.keys) {
      final e = await ComicArchive.open(fs, name).then<Object?>((a) {
        a.close();
        return null;
      }, onError: (Object e) => e);
      expect(e, isA<FormatException>(), reason: name);
      expect(LocalFs().classify(e!), FileTrouble.damaged, reason: name);
      expect('$e', isNot(contains('FormatException: FormatException')), reason: '$name: said once ($e)');
    }
  });

  test("a .cbr that's a zip inside is read as one (one on the NAS is)", () async {
    final png = _png(2, 2);
    final a = await ComicArchive.open(MemoryFs({'zip.cbr': zipOf({'1.png': png})}), 'zip.cbr');
    expect(a, isA<FileZip>());
    expect(await a.read('1.png'), png);
  });

  test("a share that stops answering part-way: the read fails as the share's did (the scan keeps the book), not as "
      'a damaged file', () async {
    final fs = _Dropping({'b.cbr': rarOf({'1.png': _png(4, 4)})});
    final a = await ComicArchive.open(fs, 'b.cbr');
    addTearDown(a.close);
    fs.down = true;
    final e = await a.read('1.png').then<Object?>((_) => null, onError: (Object e) => e);
    expect(e, isA<FileSystemException>());
    expect(LocalFs(platform: FsPlatform.windows).classify(e!), FileTrouble.noAnswer);
  });

  test('in a library: the CBRs are books - listed, their pages with their sizes, a page read', () async {
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('file_rar_lib');
    final data = await Directory.systemTemp.createTemp('file_rar_data');
    final saga = Directory('${root.path}${sep}Saga')..createSync();
    File('${saga.path}$sep#1.cbr').writeAsBytesSync(rarOf({'1.png': _png(30, 20), '2.png': _png(20, 30)}));
    File('${saga.path}$sep#2.cbr').writeAsBytesSync(fixture('synthetic_comic.cbr'));
    final local = await LocalSource.open(data, [LocalLibrary.at(root.path)]);
    addTearDown(() async {
      await local.closeFiles();
      await root.delete(recursive: true);
      await data.delete(recursive: true);
    });
    await local.rescan();
    final books = [for (final b in (await local.books(size: 10))['content'] as List) b as Map]
      ..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
    expect([for (final b in books) (b['media']['pagesCount'], b['media']['mediaType'])],
        [(2, 'application/x-rar-compressed'), (3, 'application/x-rar-compressed')]);
    final pages = await local.pages(books.first['id'] as String);
    expect([for (final p in pages) (p['width'], p['height'])], [(30, 20), (20, 30)]);
    expect(imageSizeOf(await local.pageBytes(books.last['id'] as String, 2)), isNotNull);
  });
}

/// Files in memory, until [down]: then a share that stopped answering.
class _Dropping extends MemoryFs {
  _Dropping(super.files);
  bool down = false;

  @override
  Future<LibraryFile> open(String path) async => _DroppingFile(this, await super.open(path));
}

class _DroppingFile implements LibraryFile {
  _DroppingFile(this.fs, this.inner);
  final _Dropping fs;
  final LibraryFile inner;
  @override
  Future<int> length() => inner.length();
  @override
  Future<Uint8List> readRange(int offset, int length) async =>
      fs.down
          ? throw const FileSystemException('no answer', 'b.cbr', OSError('The specified network name is no longer available', 64))
          : inner.readRange(offset, length);
  @override
  Future<void> close() => inner.close();
}
