import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/local/file_rar.dart';
import 'package:komga_reader/local/file_zip.dart';
import 'package:komga_reader/local/folder_komga.dart';
import 'package:komga_reader/local/folder_scan.dart';
import 'package:komga_reader/local/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/helpers.dart';
import 'support/rar_writer.dart';
import 'support/zip_writer.dart';

/// CBR comics (user, 2026-10-25: "komga should support CBR too"): RAR4 and RAR5, stored and compressed, read in
/// place like a CBZ - the scan lists them, their pages open, a page's size from its start.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  const fs = LocalFs();
  final sep = Platform.pathSeparator;
  // (koni_rar's own fixtures, made with rar: RAR5 compressed pages; RAR4 compressed with the x86 filter)
  final fixtures = '${Directory.current.path}${sep}test${sep}fixtures${sep}rar';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('file_rar');
  });
  tearDown(() => deleteTemp(dir));

  Future<String> write(String name, List<int> bytes) async {
    final f = File('${dir.path}$sep$name');
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes);
    return f.path;
  }

  test('a stored RAR4: its files listed, each read whole, or just its start', () async {
    final png = await solidPng(30, 20);
    final path = await write('a.cbr', rarOf({'01.png': png, 'ComicInfo.xml': '<ComicInfo><Title>Rar</Title></ComicInfo>'}));
    final a = await ComicArchive.open(fs, path);
    addTearDown(a.close);
    expect(a, isA<FileRar>());
    expect(a.names, ['01.png', 'ComicInfo.xml']);
    expect(a.find('comicinfo.XML'), 'ComicInfo.xml');
    expect(await a.read('01.png'), png);
    expect(await a.head('01.png', 24), png.sublist(0, 24));
    expect(imageSizeOf((await a.head('01.png', 64 * 1024))!), (30, 20));
    expect(await a.read('nothing.png'), isNull);
  });

  test('compressed: RAR5 pages, a RAR4 file through its filter, one in a solid RAR4 - the start alone is the same as the start of the '
      'whole', () async {
    for (final (name, entry, size) in [
      ('synthetic_comic.cbr', 'comic/page002.png', 1032),
      ('filter_e8.rar', 'x86call.bin', 12016),
      ('solid_rar4.rar', 'solidbig/part3.txt', 3305), // (solid: each file follows on from the one before)
    ]) {
      final a = await ComicArchive.open(fs, '$fixtures$sep$name');
      addTearDown(a.close);
      final whole = await a.read(entry);
      expect(whole, hasLength(size), reason: name);
      expect(await a.head(entry, 100), whole!.sublist(0, 100), reason: name);
    }
  });

  test('a CBR cut short (a copy that stopped part-way) is damaged - not opened with the pages it still lists (tablet, '
      '2026-10-25: one cut at 4 KB came in as a book whose page never loaded)', () async {
    final whole = rarOf({'1.png': await solidPng(30, 20), '2.png': await solidPng(20, 30)});
    final rar5 = await File('$fixtures${sep}synthetic_comic.cbr').readAsBytes();
    for (final (name, bytes) in [
      ('stored.cbr', whole.sublist(0, whole.length - 60)), // (the second page's data cut, its header there)
      ('rar5.cbr', rar5.sublist(0, 400)),
    ]) {
      final path = await write(name, bytes);
      final e = await ComicArchive.open(fs, path).then<Object?>((a) {
        a.close();
        return null;
      }, onError: (Object e) => e);
      expect(e, isA<FormatException>(), reason: name);
      expect(troubleOf(e!), FileTrouble.damaged, reason: name);
      expect('$e', isNot(contains('FormatException: FormatException')), reason: '$name: said once ($e)');
    }
  });

  test("a .cbr that's a zip inside is read as one (one on the NAS is)", () async {
    final png = await solidPng(2, 2);
    final a = await ComicArchive.open(fs, await write('zip.cbr', zipOf({'1.png': png})));
    expect(a, isA<FileZip>());
    expect(await a.read('1.png'), png);
  });

  test("a share that stops answering part-way: the read fails as the share's did (the scan keeps the book), not as "
      'a damaged file', () async {
    final path = await write('b.cbr', rarOf({'1.png': await solidPng(4, 4)}));
    final share = _Dropping();
    final a = await ComicArchive.open(share, path);
    addTearDown(a.close);
    share.down = true;
    final e = await a.read('1.png').then<Object?>((_) => null, onError: (Object e) => e);
    expect(e, isA<SocketException>());
    expect(troubleOf(e!), FileTrouble.noAnswer);
  });

  test('in a library: the CBRs are books - listed, their pages with their sizes, a page read', () async {
    final data = await Directory.systemTemp.createTemp('file_rar_data');
    addTearDown(() => deleteTemp(data));
    final lib = '${dir.path}${sep}lib';
    await write('lib${sep}Saga$sep#1.cbr', rarOf({'1.png': await solidPng(30, 20), '2.png': await solidPng(20, 30)}));
    await File('$fixtures${sep}synthetic_comic.cbr').copy((await write('lib${sep}Saga$sep#2.cbr', const [])));
    final api = await FolderKomga.open([LocalLibrary.at(lib)], dataDir: data);
    await api.rescan();
    final books = [for (final b in api.store.books.values) b['book'] as Map]..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
    expect([for (final b in books) (b['name'], b['media']['pagesCount'], b['media']['mediaType'])],
        [('#1', 2, 'application/x-rar-compressed'), ('#2', 3, 'application/x-rar-compressed')]);
    final pages = await api.pages(books.first['id'] as String);
    expect([for (final p in pages) (p['width'], p['height'])], [(30, 20), (20, 30)]);
    expect(imageSizeOf(await api.pageBytes(books.last['id'] as String, 2)), isNotNull);
  });
}

/// This device's files, until [down]: then a share that stopped answering.
class _Dropping implements LibraryFs {
  bool down = false;
  static const _real = LocalFs();
  @override
  Future<int> length(String path) => _real.length(path);
  @override
  Future<Uint8List> readRange(String path, int offset, int length) async =>
      down ? throw const SocketException('no answer') : _real.readRange(path, offset, length);
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
