// A comic's archive read in place (lib/local/file_zip.dart): a CBZ opened once, its pages in one read each,
// compressed or not; a picture's size from its first bytes; a CBR (not read yet), a file that is no archive and a
// damaged or unusual zip told apart.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/local/file_rar.dart';
import 'package:komga_reader/local/file_zip.dart';

import 'support/memory_fs.dart';
import 'support/rar_writer.dart';
import 'support/zip_writer.dart';
import 'dart:io';
import 'package:komga_reader/local/library_fs.dart';
import 'support/epub_files.dart' show epub3, zip;

/// Every place [from] (ASCII) is in [zip], as [to] (the same length).
Uint8List swap(Uint8List zip, String from, List<int> to) {
  final f = ascii.encode(from), out = Uint8List.fromList(zip);
  for (var i = 0; i + f.length <= out.length; i++) {
    var hit = true;
    for (var k = 0; k < f.length && hit; k++) {
      hit = out[i + k] == f[k];
    }
    if (hit) out.setRange(i, i + f.length, to);
  }
  return out;
}

/// The offsets of the central directory's entries.
List<int> centralEntries(Uint8List zip) => [
      for (var i = 0; i + 4 <= zip.length; i++)
        if (zip[i] == 0x50 && zip[i + 1] == 0x4b && zip[i + 2] == 0x01 && zip[i + 3] == 0x02) i,
    ];

// ---- rewriteZip (Apply edits to files): the book written anew with its metadata in it
final _page1 = Uint8List.fromList([...pngHead(10, 10), ...List.filled(500, 7)]);
final _page2 = Uint8List.fromList([...pngHead(20, 10), ...List.generate(500, (i) => i % 251)]);
Uint8List _cbz({String? info, bool deflate = false}) =>
    zipOf({'001.png': _page1, '002.png': _page2, if (info != null) 'ComicInfo.xml': info}, deflate: deflate);

/// Writes cut short: the rewritten book doesn't check out.
class _CutFs extends MemoryFs {
  _CutFs(super.files);
  @override
  Future<LibraryOut> create(String path) async => _Cut(await super.create(path));
}

class _Cut implements LibraryOut {
  _Cut(this.inner);
  final LibraryOut inner;
  bool first = true;
  @override
  Future<void> add(Uint8List bytes) async {
    if (first) bytes = Uint8List.fromList([...bytes]..[40] ^= 0xff); // (a byte of the first page changed)
    first = false;
    await inner.add(bytes);
  }

  @override
  Future<void> close() => inner.close();
}

void main() {
  test("a CBZ through any storage: opened once, its directory in one read, each page in one more - a share's round "
      'trips', () async {
    final pages = {for (var i = 1; i <= 5; i++) '$i.jpg': Uint8List.fromList(List.filled(5000 + i, i))};
    final fs = MemoryFs({'book.cbz': zipOf(pages)});
    final zip = await ComicArchive.open(fs, 'book.cbz');
    expect(fs.reads, 2, reason: 'its first bytes (what kind), then the end of the file (the directory)');
    expect(zip.names, pages.keys);
    for (final MapEntry(key: name, value: bytes) in pages.entries) {
      expect(await zip.read(name), bytes);
    }
    expect(fs.reads, 2 + pages.length, reason: 'one read a page');
    expect(fs.opens, 1, reason: 'opened once (review, 2026-10-26: each read opened the file again)');
    expect((await zip.head('3.jpg', 100))!.length, 100);
    await zip.close();
  });

  test('compressed pages (as most CBZs are): read whole, and only the start of one for its size', () async {
    final page = Uint8List.fromList([...pngHead(1988, 3056), ...List.filled(20000, 7)]);
    final fs = MemoryFs({'book.cbz': zipOf({'01.png': page, 'ComicInfo.xml': '<ComicInfo/>'}, deflate: true)});
    final zip = await ComicArchive.open(fs, 'book.cbz');
    expect(await zip.read('01.png'), page);
    expect(imageSizeOf((await zip.head('01.png', 64))!), (1988, 3056), reason: 'its start, inflated');
    expect(zip.find('comicinfo.XML'), 'ComicInfo.xml', reason: 'any case');
    expect(await zip.read('02.png'), isNull);
  });

  test('a CBR is told by its first bytes, whatever its name - read as a RAR (file_rar_test.dart); a file that is no '
      'archive at all is damaged', () async {
    final fs = MemoryFs({'renamed.cbz': rarOf({'1.png': [1, 2, 3]}), 'text.cbz': Uint8List.fromList(List.filled(100, 0x41))});
    final rar = await ComicArchive.open(fs, 'renamed.cbz');
    addTearDown(rar.close);
    expect(rar, isA<FileRar>());
    expect(() => ComicArchive.open(fs, 'text.cbz'), throwsA(isA<FormatException>()));
  });

  // ---- review, 2026-10-26 --------------------------------------------------------------------------------------------
  test("names in the old DOS code page (no UTF-8 flag): two that differ only in an accent stay two pages - decoded as "
      'UTF-8 they were one, and a page was lost', () async {
    final zip = swap(swap(zipOf({'PXgina1.jpg': [1], 'PYgina1.jpg': [2]}), 'PXg', [0x50, 0x82, 0x67]), 'PYg',
        [0x50, 0x85, 0x67]);
    final a = await ComicArchive.open(MemoryFs({'b.cbz': zip}), 'b.cbz');
    expect(a.names, ['Pégina1.jpg', 'Pàgina1.jpg']);
    expect(await a.read('Pàgina1.jpg'), [2]);
  });

  test('a UTF-8 name (its flag set) is read as UTF-8; a folder entry is no file', () async {
    final a = await ComicArchive.open(MemoryFs({'b.cbz': zipOf({'dir/': <int>[], 'Página 1.jpg': [1]})}), 'b.cbz');
    expect(a.names, ['Página 1.jpg']);
  });

  test("an encrypted page isn't handed back as a picture: not readable", () async {
    final zip = zipOf({'1.jpg': [1, 2, 3]});
    zip[centralEntries(zip).single + 8] |= 1; // (the encrypted flag)
    final a = await ComicArchive.open(MemoryFs({'b.cbz': zip}), 'b.cbz');
    expect(() => a.read('1.jpg'), throwsA(isA<UnreadableArchive>()));
  });

  test("the end of a zip's directory is the record its comment runs to the end from - not the same four bytes "
      'inside the comment', () async {
    final base = zipOf({'1.jpg': [9]});
    final comment = [...ascii.encode('note '), 0x50, 0x4b, 0x05, 0x06, ...List.filled(30, 0x20)];
    final zip = Uint8List.fromList([...base.sublist(0, base.length - 2), comment.length & 0xff, comment.length >> 8,
        ...comment]);
    final a = await ComicArchive.open(MemoryFs({'b.cbz': zip}), 'b.cbz');
    expect(await a.read('1.jpg'), [9]);
  });

  test('a directory cut short, or a page cut short, is damaged - a FormatException, not a crash or a short picture',
      () async {
    final zip = zipOf({'1.jpg': [1, 2, 3]});
    final c = centralEntries(zip).single;
    final bigName = Uint8List.fromList(zip)..[c + 28] = 0xff; // its name running past the directory
    expect(() => ComicArchive.open(MemoryFs({'b.cbz': bigName}), 'b.cbz'), throwsA(isA<FormatException>()));

    final shortData = Uint8List.fromList(zip)
      ..[c + 20] = 200 // the stored size: more than there is
      ..[c + 24] = 200;
    final a = await ComicArchive.open(MemoryFs({'b.cbz': shortData}), 'b.cbz');
    expect(() => a.read('1.jpg'), throwsA(isA<FormatException>()));
  });

  test("a picture's size from its start: PNG, GIF, JPEG; null for anything else", () {
    expect(imageSizeOf(pngHead(800, 1200)), (800, 1200));
    final gif = Uint8List.fromList([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x20, 0x03, 0xb0, 0x04]);
    expect(imageSizeOf(gif), (800, 1200));
    // SOI, an APP0 segment of 4 bytes, then SOF0: height 1200, width 800
    final jpeg = Uint8List.fromList(
        [0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 0x00, 0x00, 0xff, 0xc0, 0x00, 0x11, 0x08, 0x04, 0xb0, 0x03, 0x20, 0x03]);
    expect(imageSizeOf(jpeg), (800, 1200));
    expect(imageSizeOf(Uint8List.fromList(List.filled(40, 1))), isNull);
  });

  group('the rewrite', () {
    test("a CBZ's ComicInfo.xml replaced: every page copied byte for byte (stored or deflated), the new one reading "
        "back; no copy left beside it", () async {
      for (final deflate in [false, true]) {
        final fs = MemoryFs({'lib/a.cbz': _cbz(info: '<ComicInfo><Title>Old</Title></ComicInfo>', deflate: deflate)});
        final before = await FileZip.open(await fs.open('lib/a.cbz'));
        final pages = [await before.read('001.png'), await before.read('002.png')];
        await before.close();
        final xml = Uint8List.fromList(utf8.encode('<ComicInfo><Title>New</Title></ComicInfo>'));
        await rewriteZip(fs, 'lib/a.cbz', replace: {'ComicInfo.xml': xml});
        final after = await FileZip.open(await fs.open('lib/a.cbz'));
        expect([await after.read('001.png'), await after.read('002.png')], pages, reason: 'deflate $deflate');
        expect(await after.read('ComicInfo.xml'), xml);
        expect(after.names.toList(), ['001.png', '002.png', 'ComicInfo.xml'], reason: 'in their places');
        await after.close();
        expect(fs.files.keys, ['lib/a.cbz']);
      }
    });

    test("a CBZ with no ComicInfo.xml gets one, after its pages; an EPUB's mimetype stays first, as it must", () async {
      final fs = MemoryFs({'lib/a.cbz': _cbz(), 'lib/b.epub': zip(epub3())});
      await rewriteZip(fs, 'lib/a.cbz', add: {'ComicInfo.xml': Uint8List.fromList(utf8.encode('<ComicInfo/>'))});
      final a = await FileZip.open(await fs.open('lib/a.cbz'));
      expect(a.names.last, 'ComicInfo.xml');
      await a.close();
      final opf = Uint8List.fromList(utf8.encode('<package/>'));
      await rewriteZip(fs, 'lib/b.epub', replace: {'OEBPS/content.opf': opf});
      final b = fs.files['lib/b.epub']!;
      expect(utf8.decode(b.sublist(30, 38)), 'mimetype', reason: 'the first entry');
    });

    test("a rewrite that doesn't check out (a page's bytes changed on the way): the book stays exactly as it was, "
        "and the new copy goes", () async {
      final book = _cbz(info: '<ComicInfo/>');
      final fs = _CutFs({'lib/a.cbz': book});
      await expectLater(rewriteZip(fs, 'lib/a.cbz', replace: {'ComicInfo.xml': Uint8List.fromList([1])}),
          throwsA(isA<FormatException>()));
      expect(fs.files['lib/a.cbz'], book);
      expect(fs.files.keys, ['lib/a.cbz']);
    });

    test("on this device's own files: rewritten in place, nothing left beside it", () async {
      final dir = await Directory.systemTemp.createTemp('rewrite');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}${Platform.pathSeparator}a.cbz';
      File(path).writeAsBytesSync(_cbz(deflate: true));
      final xml = Uint8List.fromList(utf8.encode('<ComicInfo><Title>T</Title></ComicInfo>'));
      await rewriteZip(LocalFs(), path, add: {'ComicInfo.xml': xml});
      final z = await FileZip.open(await LocalFs().open(path));
      expect([await z.read('002.png'), await z.read('ComicInfo.xml')], [_page2, xml]);
      await z.close();
      expect(dir.listSync(), hasLength(1));
    });

    test("a CBR isn't rewritten: refused, left as it was", () async {
      final rar = File('test/fixtures/rar/synthetic_comic.cbr');
      if (!rar.existsSync()) return markTestSkipped('no RAR fixture');
      final bytes = rar.readAsBytesSync();
      final fs = MemoryFs({'lib/a.cbr': bytes});
      await expectLater(rewriteZip(fs, 'lib/a.cbr', add: {'ComicInfo.xml': Uint8List(1)}), throwsA(anything));
      expect(fs.files['lib/a.cbr'], bytes);
      expect(fs.files.keys, ['lib/a.cbr']);
    });
  });
}
