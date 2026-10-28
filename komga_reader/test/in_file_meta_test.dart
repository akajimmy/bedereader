// Metadata edits written into the book files (Apply edits to files - reports\10-27-apply-edits-plan.md): a CBZ's
// ComicInfo.xml, an EPUB's package file; the book rewritten with every other entry copied as it was, checked before
// it takes the old one's place.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/local/file_zip.dart';
import 'package:komga_reader/local/in_file_meta.dart';
import 'package:komga_reader/local/library_fs.dart';
import 'package:komga_reader/local/local_meta.dart';

import 'support/epub_files.dart' show epub3, zip;
import 'support/memory_fs.dart';
import 'support/zip_writer.dart';

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
  group("the text", () {
    test("ComicInfo.xml: the title replaced, the number and date added, everything else as it was; a date taken away "
        "takes Year, Month and Day; a book with none gets one; text escaped", () {
      const was = '<?xml version="1.0"?>\n<ComicInfo>\n  <Title>Old</Title>\n  <Writer>Brian K. Vaughan</Writer>\n'
          '  <Year>2011</Year>\n</ComicInfo>\n';
      final x = comicInfoWith(was, const BookEdits(title: 'Chapter <One> & more', number: '1', dateSet: true,
          releaseDate: '2012-03-14'));
      expect(x, contains('<Title>Chapter &lt;One&gt; &amp; more</Title>'));
      expect(x, contains('<Writer>Brian K. Vaughan</Writer>'));
      expect(x, isNot(contains('Old')));
      expect([for (final t in ['Number', 'Year', 'Month', 'Day']) RegExp('<$t>(.*?)</$t>').firstMatch(x)?[1]],
          ['1', '2012', '3', '14']);
      final cleared = comicInfoWith(x, const BookEdits(dateSet: true));
      expect(cleared, allOf(isNot(contains('<Year>')), isNot(contains('<Month>')), isNot(contains('<Day>')),
          contains('<Number>1</Number>')));
      expect(comicInfoWith(null, const BookEdits(title: 'New')), contains('<Title>New</Title>'));
    });

    test("an EPUB's package file: its title replaced (its attributes kept), its date set or taken away, its number as "
        "calibre's series index", () {
      const opf = '<package><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
          '    <dc:title id="t">Old</dc:title>\n    <dc:date>1999</dc:date>\n'
          '    <meta name="calibre:series_index" content="3"/>\n  </metadata><manifest/></package>';
      final x = opfWith(opf, const BookEdits(title: 'New', number: '4', dateSet: true, releaseDate: '2020-01-02'));
      expect(x, contains('<dc:title id="t">New</dc:title>'));
      expect(x, contains('<dc:date>2020-01-02</dc:date>'));
      expect('content="4"'.allMatches(x), hasLength(1));
      expect(x, isNot(contains('content="3"')));
      expect(opfWith(x, const BookEdits(dateSet: true)), isNot(contains('dc:date')));
    });
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
