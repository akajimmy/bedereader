// Line-end hyphens in the real reading font (Literata - the tests' own font has square glyphs, where this doesn't
// show): in a book with a text size of its own, a paragraph's first line broken at a hyphenation point still shows
// its hyphen. It was drawn at the default size, sat above the line and was skipped (user, build 74: Exile's
// "power ful").
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/epub/css.dart';
import 'package:komga_reader/epub/hyphenator.dart';
import 'package:komga_reader/epub/layout.dart';
import 'package:komga_reader/epub/xhtml.dart';

void main() {
  late Hyphenators hy;
  setUpAll(() async {
    Future<ByteData> bytes(String f) async => ByteData.sublistView(File(f).readAsBytesSync());
    await (FontLoader('Literata')..addFont(bytes('assets/fonts/Literata.ttf'))).load();
    hy = await Hyphenators.load((p) async => File(p).readAsStringSync());
  });

  test("a book set at 85%: every hyphenated line end shows its hyphen, the paragraph's first line's too", () {
    const text = 'Briza, the eldest daughter, a large and powerful drow female, paced about the anteroom anxiously, '
        'a not uncommon sight, recriminatory and determined, considering extraordinary circumstances unceremoniously.';
    final blocks = ChapterReader(StyleSheet()..add('p { font-size: small }'), (h) => h)
        .read(parseXhtml('<body><p>$text</p><p>$text</p></body>'));
    var checked = 0;
    for (final width in [300.0, 330.0, 360.0, 390.0, 420.0, 450.0]) {
      final p = Paginator(const EpubTheme(fontFamily: 'Literata', fontSize: 24, bookFormatting: false),
          Size(width, 2000), hy.forLang('en'), baseSize: 0.85);
      final page = p.run(blocks).single;
      expect(page.hyphensShown, page.hyphenMarks, reason: 'at $width: every hyphen made is drawn');
      checked += page.hyphenMarks;
    }
    expect(checked, greaterThan(0), reason: 'the sample breaks words');
  });
}
