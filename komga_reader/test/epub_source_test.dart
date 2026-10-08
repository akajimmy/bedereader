// The EPUB book as data (lib/epub/source.dart, chapter.dart): paths, the zip reader, the package and contents of an
// EPUB 3 and an EPUB 2 file, Komga's manifest, chapters loaded with their stylesheets.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/epub/chapter.dart';
import 'package:komga_reader/epub/layout.dart';
import 'package:komga_reader/epub/source.dart';

import 'support/epub_files.dart';
import 'support/no_network.dart';

void main() {
  test('paths: from the file they are written in, to the book root; ../ and %20 resolved; #fragment kept', () {
    expect(resolvePath('OEBPS/Text/ch1.xhtml', '../Styles/a.css'), 'OEBPS/Styles/a.css');
    expect(resolvePath('OEBPS/Text/ch1.xhtml', 'ch2.xhtml#n3'), 'OEBPS/Text/ch2.xhtml#n3');
    expect(resolvePath('OEBPS/Text/ch1.xhtml', '#n3'), 'OEBPS/Text/ch1.xhtml#n3');
    expect(resolvePath('OEBPS/content.opf', 'Text/Chapter%201.xhtml'), 'OEBPS/Text/Chapter 1.xhtml');
    expect(resolvePath('a.xhtml', './b/./c.xhtml'), 'b/c.xhtml');
  });

  test('zip: stored and deflated files read back; a missing one is null; a name matches ignoring case', () {
    final z = Zip(zip({'a.txt': 'stored text', 'b/c.txt': 'deflated ' * 50}, deflate: {'b/c.txt'}));
    expect(utf8.decode(z.read('a.txt')!), 'stored text');
    expect(utf8.decode(z.read('b/c.txt')!), 'deflated ' * 50);
    expect(z.read('B/C.TXT'), isNotNull);
    expect(z.read('nope.txt'), isNull);
    expect(() => Zip(Uint8List.fromList(utf8.encode('not a zip at all, just text'))), throwsFormatException);
  });

  Future<FileEpubSource> fileSource(Map<String, String> files, {Set<String> deflate = const {}}) async {
    final dir = await Directory.systemTemp.createTemp('epub_test');
    addTearDown(() => dir.delete(recursive: true));
    final f = File('${dir.path}/book.epub');
    await f.writeAsBytes(zip(files, deflate: deflate));
    return FileEpubSource(f);
  }

  test('an EPUB 3 file: title, the spine in order (non-linear items left out), the contents from its nav (the toc '
      'nav, not the landmarks), nested', () async {
    final s = await fileSource(epub3(), deflate: {'OEBPS/Text/ch2.xhtml', 'OEBPS/content.opf'});
    final info = await s.info();
    expect(info.title, 'Sourcery');
    expect(info.spine, ['OEBPS/Text/Chapter 1.xhtml', 'OEBPS/Text/ch2.xhtml']);
    expect([for (final t in info.toc) (t.title, t.href, t.depth)], [
      ('One', 'OEBPS/Text/Chapter 1.xhtml', 0),
      ('One, part two', 'OEBPS/Text/Chapter 1.xhtml#part', 1),
      ('Two', 'OEBPS/Text/ch2.xhtml', 0),
    ]);
    expect(utf8.decode(await s.resource('OEBPS/Text/ch2.xhtml')), contains('Second chapter.'));
  });

  test('an EPUB 2 file: the contents from its NCX', () async {
    final files = epub3()
      ..['OEBPS/content.opf'] = '<package version="2.0"><metadata><dc:title>Old</dc:title></metadata><manifest>'
          '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
          '<item id="c1" href="Text/Chapter%201.xhtml" media-type="application/xhtml+xml"/></manifest>'
          '<spine toc="ncx"><itemref idref="c1"/></spine></package>'
      ..['OEBPS/toc.ncx'] = '<ncx><navMap><navPoint id="n1"><navLabel><text>Chapter One</text></navLabel>'
          '<content src="Text/Chapter%201.xhtml"/><navPoint id="n2"><navLabel><text>Inside</text></navLabel>'
          '<content src="Text/Chapter%201.xhtml#part"/></navPoint></navPoint></navMap></ncx>';
    final info = await (await fileSource(files)).info();
    expect(info.title, 'Old');
    expect(info.spine, ['OEBPS/Text/Chapter 1.xhtml']);
    expect([for (final t in info.toc) (t.title, t.href, t.depth)], [
      ('Chapter One', 'OEBPS/Text/Chapter 1.xhtml', 0),
      ('Inside', 'OEBPS/Text/Chapter 1.xhtml#part', 1),
    ]);
  });

  test("a chapter loaded: its stylesheet applied (fetched once for the book), language, length", () async {
    final s = await fileSource(epub3());
    var cssFetches = 0;
    final counting = _Counting(s, onRead: (p) {
      if (p.endsWith('.css')) cssFetches++;
    });
    final loader = ChapterLoader(counting);
    final c1 = await loader.load('OEBPS/Text/Chapter 1.xhtml');
    expect(c1.lang, 'en');
    final first = c1.blocks.first as TextBlock;
    expect(first.runs.first.style.italic, isTrue, reason: 'p.first from ../Styles/book.css');
    expect(c1.length, 'There was a wizard.'.length + 'Part.'.length);
    await loader.load('OEBPS/Text/ch2.xhtml');
    expect(cssFetches, 1, reason: 'the stylesheet is fetched once for the whole book');
  });

  test("Komga's manifest: hrefs as full URLs become book paths; nested contents; the title", () async {
    final api = noNetwork(() => _ManifestKomga({
      'metadata': {'title': 'Snuff'},
      'readingOrder': [
        {'href': 'http://komga/api/v1/books/B1/resource/OEBPS/Begin_Reading.html'},
        {'href': 'http://komga/api/v1/books/B1/resource/OEBPS/Foot%20notes.html'},
      ],
      'toc': [
        {'href': 'http://komga/api/v1/books/B1/resource/OEBPS/Begin_Reading.html', 'title': ' Begin Reading ',
          'children': [{'href': 'http://komga/api/v1/books/B1/resource/OEBPS/Begin_Reading.html#p2', 'title': 'Two'}]},
      ],
    }));
    final info = await KomgaEpubSource(api, 'B1').info();
    expect(info.title, 'Snuff');
    expect(info.spine, ['OEBPS/Begin_Reading.html', 'OEBPS/Foot notes.html']);
    expect([for (final t in info.toc) (t.title, t.href, t.depth)], [
      ('Begin Reading', 'OEBPS/Begin_Reading.html', 0),
      ('Two', 'OEBPS/Begin_Reading.html#p2', 1),
    ]);
  });
}

class _Counting implements EpubSource {
  _Counting(this.inner, {required this.onRead});
  final EpubSource inner;
  final void Function(String) onRead;
  @override
  Future<EpubInfo> info() => inner.info();
  @override
  Future<Uint8List> resource(String path) {
    onRead(path);
    return inner.resource(path);
  }
}

class _ManifestKomga extends TestKomga {
  _ManifestKomga(this.manifest);
  final Map<String, dynamic> manifest;
  @override
  Future<Map<String, dynamic>?> epubManifest(String bookId) async => manifest;
}
