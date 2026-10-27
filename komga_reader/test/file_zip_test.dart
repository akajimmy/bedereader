// A comic's archive read in place (lib/local/file_zip.dart): a CBZ's pages in one read each, compressed or not; a
// picture's size from its first bytes; a CBR (not read yet) and a file that isn't a zip told apart.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/local/file_zip.dart';

import 'support/memory_fs.dart';
import 'support/zip_writer.dart';

void main() {
  test("a CBZ through any storage: its directory in one read, each page in one more - a share's round trips",
      () async {
    final pages = {for (var i = 1; i <= 5; i++) '$i.jpg': Uint8List.fromList(List.filled(5000 + i, i))};
    final fs = MemoryFs({'book.cbz': zipOf(pages)});
    final zip = await FileZip.open(fs, 'book.cbz');
    expect(fs.reads, 1, reason: 'the end of the file holds the directory');
    expect(zip.names, pages.keys);
    for (final MapEntry(key: name, value: bytes) in pages.entries) {
      expect(await zip.read(name), bytes);
    }
    expect(fs.reads, 1 + pages.length, reason: 'one read a page');
    expect((await zip.head('3.jpg', 100))!.length, 100);
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

  test('a CBR is told by its first bytes, whatever its name, and is not readable yet; a file that is no archive at '
      'all is damaged', () async {
    final rar = Uint8List.fromList([0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x01, 0x00, ...List.filled(40, 0)]);
    final fs = MemoryFs({'renamed.cbz': rar, 'text.cbz': Uint8List.fromList(List.filled(100, 0x41))});
    expect(() => ComicArchive.open(fs, 'renamed.cbz'), throwsA(isA<UnreadableArchive>()));
    expect(() => ComicArchive.open(fs, 'text.cbz'), throwsA(isA<FormatException>()));
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
