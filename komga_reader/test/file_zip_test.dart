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
}
