// EPUB files built in memory for the tests: a zip writer and a small EPUB 3 (moved out of epub_source_test,
// 2026-10-07: downloads_epub_test imported them from there).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
