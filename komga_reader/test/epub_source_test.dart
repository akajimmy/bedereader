// The EPUB book as data (lib/epub/source.dart, chapter.dart): paths, the zip reader, the package and contents of an
// EPUB 3 and an EPUB 2 file, Komga's manifest, chapters loaded with their stylesheets.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/epub/chapter.dart';
import 'package:komga_reader/epub/layout.dart';
import 'package:komga_reader/epub/source.dart';

import 'support/no_network.dart';

/// A zip in memory: [deflate] files compressed, the rest stored (EPUBs have both).
Uint8List zip(Map<String, String> files, {Set<String> deflate = const {}}) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  void u16(BytesBuilder b, int v) => b.add([v & 0xff, v >> 8 & 0xff]);
  void u32(BytesBuilder b, int v) => b.add([v & 0xff, v >> 8 & 0xff, v >> 16 & 0xff, v >> 24 & 0xff]);
  for (final e in files.entries) {
    final name = utf8.encode(e.key);
    final raw = utf8.encode(e.value);
    final packed = deflate.contains(e.key) ? ZLibEncoder(raw: true).convert(raw) : raw;
    final method = deflate.contains(e.key) ? 8 : 0;
    final offset = out.length;
    u32(out, 0x04034b50); u16(out, 20); u16(out, 0); u16(out, method); u16(out, 0); u16(out, 0);
    u32(out, 0); u32(out, packed.length); u32(out, raw.length); u16(out, name.length); u16(out, 0);
    out.add(name);
    out.add(packed);
    u32(central, 0x02014b50); u16(central, 20); u16(central, 20); u16(central, 0); u16(central, method);
    u16(central, 0); u16(central, 0); u32(central, 0); u32(central, packed.length); u32(central, raw.length);
    u16(central, name.length); u16(central, 0); u16(central, 0); u16(central, 0); u16(central, 0); u32(central, 0);
    u32(central, offset);
    central.add(name);
  }
  final cdOffset = out.length, cd = central.takeBytes();
  out.add(cd);
  u32(out, 0x06054b50); u16(out, 0); u16(out, 0); u16(out, files.length); u16(out, files.length);
  u32(out, cd.length); u32(out, cdOffset); u16(out, 0);
  return out.takeBytes();
}

const container = '<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
    '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>'
    '</container>';

String chapter(String title, String body) => '<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml" '
    'lang="en"><head><title>$title</title><link rel="stylesheet" href="../Styles/book.css"/></head>'
    '<body>$body</body></html>';

Map<String, String> epub3() => {
      'mimetype': 'application/epub+zip',
      'META-INF/container.xml': container,
      'OEBPS/content.opf': '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0">'
          '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Sourcery</dc:title></metadata>'
          '<manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
          '<item id="c1" href="Text/Chapter%201.xhtml" media-type="application/xhtml+xml"/>'
          '<item id="c2" href="Text/ch2.xhtml" media-type="application/xhtml+xml"/>'
          '<item id="css" href="Styles/book.css" media-type="text/css"/></manifest>'
          '<spine><itemref idref="c1"/><itemref idref="nav" linear="no"/><itemref idref="c2"/></spine></package>',
      'OEBPS/nav.xhtml': '<html xmlns:epub="http://www.idpf.org/2007/ops"><body>'
          '<nav epub:type="landmarks"><ol><li><a href="Text/ch2.xhtml">Landmark</a></li></ol></nav>'
          '<nav epub:type="toc"><ol><li><a href="Text/Chapter%201.xhtml">One</a>'
          '<ol><li><a href="Text/Chapter%201.xhtml#part">One, part two</a></li></ol></li>'
          '<li><a href="Text/ch2.xhtml">Two</a></li></ol></nav></body></html>',
      'OEBPS/Text/Chapter 1.xhtml': chapter('One', '<p class="first">There was a wizard.</p><p id="part">Part.</p>'),
      'OEBPS/Text/ch2.xhtml': chapter('Two', '<p>Second chapter.</p>'),
      'OEBPS/Styles/book.css': 'p.first { text-indent: 0; font-style: italic }',
    };

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
