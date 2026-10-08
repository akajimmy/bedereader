// The EPUB layout engine (lib/epub/): hyphenation, the XHTML reader, the CSS cascade, the paginator.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/epub/chapter.dart';
import 'package:komga_reader/epub/css.dart';
import 'package:komga_reader/epub/hyphenator.dart';
import 'package:komga_reader/epub/layout.dart';
import 'package:komga_reader/epub/source.dart';
import 'package:komga_reader/epub/xhtml.dart';

import 'support/epub_books.dart' show MemorySource, onePixelPng;

/// A blank picture [w] x [h].
Future<ui.Image> _image(int w, int h) {
  final rec = ui.PictureRecorder();
  Canvas(rec).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint());
  return rec.endRecording().toImage(w, h);
}

/// A [MemorySource] that counts how often each file is read.
class _CountingSource extends MemorySource {
  _CountingSource(super.files, super.infoValue, {super.binary});
  final fetched = <String, int>{};
  @override
  Future<Uint8List> resource(String path) {
    fetched[path] = (fetched[path] ?? 0) + 1;
    return super.resource(path);
  }
}

void main() {
  late Hyphenators hy;
  setUpAll(() async => hy = await Hyphenators.load((p) async => File(p).readAsStringSync()));
  String show(Hyphenator h, String w) => h.apply(w).replaceAll(Hyphenator.soft, '-');

  test('hyphenation points (Liang, US English)', () {
    final h = hy.forLang('en')!;
    expect(show(h, 'hyphenation'), 'hy-phen-ation');
    expect(show(h, 'computer'), 'com-puter'); // at least 3 letters after a break (the patterns' own minimum)
    expect(show(h, 'Dispossessed'), 'Dis-pos-sessed');
    expect(show(h, 'table'), 'ta-ble'); // 2 letters before, 3 after: allowed
    expect(show(h, 'wall'), 'wall'); // too short for English's minimums
    expect(show(h, 'disinfection'), 'dis-in-fec-tion');
  });

  test('French: its own patterns, 2 letters either side of a break', () {
    final h = hy.forLang('fr')!;
    expect(show(h, 'anticonstitutionnellement'), 'an-ti-cons-ti-tu-tion-nel-le-ment');
    expect(show(h, 'bibliothèque'), 'bi-blio-thèque');
  });

  test("patterns picked by the book's language; English when it doesn't say; none for other languages", () {
    expect(hy.forLang(null), same(hy.forLang('en')));
    expect(hy.forLang(''), same(hy.forLang('en')));
    expect(hy.forLang('en-GB'), same(hy.forLang('en')));
    expect(hy.forLang('fr-CA'), same(hy.forLang('fr')));
    expect(hy.forLang('FR'), same(hy.forLang('fr')));
    expect(hy.forLang('de'), isNull);
  });

  test("a chapter's language comes from <html> or <body>", () {
    ChapterReader read(String src) => ChapterReader(StyleSheet(), (h) => h)..read(parseXhtml(src));
    expect(read('<html lang="fr"><body><p>x</p></body></html>').lang, 'fr');
    expect(read('<html xml:lang="en-GB"><body><p>x</p></body></html>').lang, 'en-GB');
    expect(read('<html><body lang="fr-CA"><p>x</p></body></html>').lang, 'fr-CA');
    expect(read('<html><body><p>x</p></body></html>').lang, isNull);
  });

  test('XHTML: entities, nesting, self-closing tags', () {
    final r = parseXhtml('<?xml version="1.0"?><html><body><p class="a b">It&#8217;s <i>so</i>&nbsp;on<br/>next</p></body></html>');
    final p = r.find('p')!;
    expect(p.classes, ['a', 'b']);
    expect(p.children.whereType<XText>().first.text, 'It’s ');
    expect(p.find('i'), isNotNull);
    expect(p.find('br'), isNotNull);
  });

  test('CSS: specificity and order, margin shorthand', () {
    final s = StyleSheet()..add('p { text-indent: 1em; margin: 0 0 1em } .first { text-indent: 0 } p.x { margin-top: 2em }');
    final root = parseXhtml('<body><p class="first x">a</p></body>');
    final d = s.declsFor(root.find('p')!);
    expect(d['text-indent'], '0');
    expect(d['margin-top'], '2em');
    expect(d['margin-bottom'], '1em');
  });

  // a chapter of [n] paragraphs of [words] words each (distinct words, so positions can be checked)
  String chapter(int n, int words) => '<body>${[
        for (var p = 0; p < n; p++) '<p>${[for (var w = 0; w < words; w++) 'w${p}x$w'].join(' ')}</p>',
      ].join()}</body>';

  List<EpubPage> paginate(String src, {EpubTheme theme = const EpubTheme(), Size size = const Size(400, 600)}) {
    final blocks = ChapterReader(StyleSheet(), (h) => h).read(parseXhtml(src));
    return Paginator(theme, size, hy.forLang('en')).run(blocks);
  }

  test("own formatting keeps the book's gap between a picture and the paragraph under it (user, build 82, Small Gods' "
      'turtle: the text touched it; the gap that goes is the one between two paragraphs)', () async {
    Future<double> gapUnder({required bool own}) async {
      final blocks = ChapterReader(StyleSheet(), (h) => h)
          .read(parseXhtml('<body><center><img src="t.png"/></center><p>After the picture.</p><p>And on.</p></body>'));
      (blocks.first as ImageBlock).image = await _image(200, 200);
      final page = Paginator(EpubTheme(bookFormatting: !own), const Size(600, 900), null).run(blocks).single;
      return page.textOrigins.first.dy - page.pictures.single.$1.bottom;
    }

    final book = await gapUnder(own: false), own = await gapUnder(own: true);
    expect(book, greaterThan(10), reason: "the book's 1em");
    expect(own, closeTo(book, 0.5), reason: 'kept with own formatting');
  });

  test("a page never ends in a word broken by a hyphen when its paragraph goes on (user, build 82, Small Gods: "
      '"ea-" / "gle" across a page turn) - the line goes over to the next page', () {
    // ordinary sentences with some long words: a few lines end in a broken word, most don't
    const words = 'The old lighthouse keeper walked down to the harbour every morning before breakfast, '
        'counting the boats and remembering the extraordinary storms of his childhood. Nobody in the village '
        'understood his particular fascination with the weather, but everyone appreciated the recommendations '
        'he gave the fishermen about the temperature of the water and the uncomfortable winds from the north. ';
    final src = '<body><p>${List.filled(12, words).join()}</p><p>${List.filled(12, words).join()}</p></body>';
    var pagesChecked = 0, broken = 0;
    // many page heights, so page ends fall on many different lines
    for (var h = 300.0; h <= 700; h += 9) {
      final pages = paginate(src, size: Size(360, h));
      expect(pages.where((p) => p.hyphenMarks > 0), isNotEmpty, reason: 'the text is hyphenated at all');
      for (final p in pages) {
        pagesChecked++;
        if (p.endsInBrokenWord) broken++;
      }
    }
    expect(pagesChecked, greaterThan(300));
    expect(broken, 0, reason: 'pages ending "ea-"');
  });

  test("paginator: long text runs over several pages, none of them empty; pages know the chapter position they start "
      'at: rising, the first at 0; a position finds its page, at any text size', () {
    final src = chapter(30, 50);
    final blocks = ChapterReader(StyleSheet(), (h) => h)..read(parseXhtml(src));
    final total = blocks.length;
    for (final size in [16.0, 24.0]) {
      final pages = paginate(src, theme: EpubTheme(fontSize: size));
      expect(pages.length, greaterThan(5), reason: 'at $size px');
      expect(pages.every((p) => p.pieces.isNotEmpty), isTrue, reason: 'none empty at $size px');
      expect(pages.first.start, 0);
      for (var i = 1; i < pages.length; i++) {
        expect(pages[i].start, greaterThan(pages[i - 1].start), reason: 'page ${i + 1} at $size px');
        expect(pages[i].start, lessThan(total));
        expect(pageFor(pages, pages[i].start), i, reason: "a page's own start finds it");
        expect(pageFor(pages, pages[i].start - 1), i - 1, reason: 'the character before is on the page before');
      }
      expect(pageFor(pages, total + 10), pages.length - 1, reason: 'past the end: the last page');
    }
  });

  test('links on a page: where each sits, where it goes (in the book, fragment kept), its text - footnote markers '
      'like Discworld\'s', () {
    final blocks = ChapterReader(StyleSheet(), (h) => 'OEBPS/$h').read(parseXhtml(
        '<body><p>The Watch<a class="footnote-link" href="Footnotes.html#fn-1">*</a> arrived. '
        'See <a href="#ch2">chapter two</a>.</p></body>'));
    final pages = Paginator(const EpubTheme(), const Size(400, 600), hy.forLang('en')).run(blocks);
    final links = pages.single.links;
    // (a link across a line break: one tap area on each line)
    expect({for (final l in links) (l.href, l.text)}, {('OEBPS/Footnotes.html#fn-1', '*'), ('OEBPS/#ch2', 'chapter two')});
    expect(links.where((l) => l.text == '*').length, 1);
    for (final l in links) {
      expect(l.rect.width, greaterThan(0));
      // in page coordinates: inside the text area (the theme's margins: 36 at the sides, 40 top and bottom)
      expect(const Rect.fromLTRB(36, 40, 364, 560).contains(l.rect.center), isTrue,
          reason: '${l.text} at ${l.rect}: inside the text area');
    }
    expect(links[0].rect.right, lessThan(links[1].rect.left), reason: 'the marker comes before the later link');
  });

  test("note markers (Hogfather's *, Snuff's [**], a number) are told from other links (a contents page's INDEX, "
      'the "th" of 50th), and drawn bigger without making their line taller', () {
    for (final m in ['*', '**', '[**]', '†', '‡', '31', '³¹', '(7)', ' 12 ']) {
      expect(Paginator.noteMarker.hasMatch(m), isTrue, reason: m);
    }
    for (final m in ['INDEX', 'MAPS', 'TH', 'a', '1234', 'Chapter 1']) {
      expect(Paginator.noteMarker.hasMatch(m), isFalse, reason: m);
    }
    EpubPage page(String a) => Paginator(const EpubTheme(), const Size(400, 600), null).run(ChapterReader(StyleSheet(),
            (h) => h).read(parseXhtml('<body><p>Shed by the deserving$a, and then wondered where the stories went, and '
            'why, and where to.</p><p>Next.</p></body>'))).single;
    List<double> lines(EpubPage p) => p.textOrigins.map((o) => o.dy).toList();
    final marked = page('<a href="n.html#f1">*</a>');
    expect(lines(marked), lines(page('*')), reason: 'no line taller');
    final glyph = TextPainter(text: TextSpan(text: '*', style: TextStyle(fontSize: const EpubTheme().fontSize)),
        textDirection: TextDirection.ltr)..layout();
    final marker = marked.links.single.rect;
    expect(marker.width, greaterThan(glyph.width * 1.2), reason: 'drawn bigger than the same "*" in the text: $marker, '
        '${glyph.width} wide');
    glyph.dispose();
  });

  test('superscripts: digits become superscript characters (footnote numbers); other text stays itself', () {
    expect(superscript('12'), '¹²');
    final b = ChapterReader(StyleSheet(), (h) => h).read(parseXhtml('<body><p>x<sup>23</sup> 1<sup>st</sup></p></body>'))
        .single as TextBlock;
    expect(b.runs.map((r) => r.text).join(), 'x²³ 1st');
    expect(b.runs.firstWhere((r) => r.text == 'st').style.size, lessThan(1), reason: 'letters: smaller');
    expect(b.runs.firstWhere((r) => r.text == '²³').style.size, 1, reason: 'superscript digits: no smaller still');
  });

  test("tables: rows and cells (thead / tbody looked through), a cell's paragraphs become lines; laid out as a grid", () {
    final r = ChapterReader(StyleSheet(), (h) => h)..read(parseXhtml('<body><p>Kings:</p><table border="1"><tbody>'
        '<tr><td>1-37</td><td>Aegon I</td><td><p>Aegon the Conqueror,</p><p>the Dragon</p></td></tr>'
        '<tr><th>37-42</th><td>Aenys I</td></tr></tbody></table><p>After.</p></body>'));
    final t = r.blocks.whereType<TableBlock>().single;
    expect(t.rows.length, 2);
    expect(t.rows[0].length, 3);
    expect(t.rows[0][2].map((x) => x.text).join(), 'Aegon the Conqueror,\nthe Dragon');
    expect(t.rows[1][0].first.style.bold, isTrue, reason: 'a header cell is bold');
    expect(t.bordered, isTrue);
    expect(r.blocks.last.start, greaterThan(t.start), reason: 'positions count on past the table');
    final pages = Paginator(const EpubTheme(), const Size(500, 700), hy.forLang('en')).run(r.blocks);
    expect(pages.length, 1);
  });

  test('pictures at their own size, one picture pixel to one screen pixel (user, 2026-10-06): a chapter that is only '
      'a picture centred, never enlarged; one in the text centred on its line; too big for the page: shrunk to fit; '
      'only big ones open full screen', () async {
    final img = await _image(300, 500);
    final small = await _image(321, 96); // a chapter-head banner
    List<Block> read(String html) => ChapterReader(StyleSheet(), (h) => h).read(parseXhtml(html));
    // on a screen with 2 screen pixels to a layout pixel: 300 x 500 takes 150 x 250
    const theme = EpubTheme(pixelRatio: 2);
    final cover = read('<body><div><img src="c.jpg"/></div></body>');
    (cover.single as ImageBlock).image = img;
    var page = Paginator(theme, const Size(400, 600), null).run(cover).single;
    expect(page.imageRects.single.size, const Size(150, 250));
    expect(page.imageRects.single.center, const Offset(200, 300), reason: 'centred in the text area (36..364 x 40..560)');
    expect(page.pictures, hasLength(1), reason: 'big enough to open full screen');
    final inText = read('<body><p>Before.</p><p><img src="m.jpg"/></p><p><img src="b.jpg"/></p></body>');
    final pics = inText.whereType<ImageBlock>().toList();
    pics[0].image = img;
    pics[1].image = small;
    page = Paginator(theme, const Size(400, 900), null).run(inText).first;
    expect(page.imageRects[0].size, const Size(150, 250));
    expect(page.imageRects[0].center.dx, 200);
    expect(page.pictures.map((p) => p.$1), [page.imageRects[0]], reason: 'the banner (96 tall) does not open');
    // too big for the page (600 x 1000 on a 1:1 screen, the text area 328 x 520): shrunk to fit
    final big = await _image(600, 1000);
    (cover.single as ImageBlock).image = big;
    page = Paginator(const EpubTheme(), const Size(400, 600), null).run(cover).single;
    expect(page.imageRects.single.height, closeTo(520, 0.01));
    expect(page.imageRects.single.width, closeTo(312, 0.01));
  });

  test("a drop cap drawn as a picture (Homeland: <span float:left><img/></span> starting the paragraph, or just before "
      "it) is drawn at its own size, the paragraph's first lines beside it", () async {
    final sheet = StyleSheet()..add('.dropcaps { float: left; }');
    final words = List.filled(80, 'word').join(' ');
    for (final html in [
      '<body><p><span class="dropcaps"><img src="T.jpg"/></span>he $words</p></body>',
      '<body><div class="dropcaps"><img src="T.jpg"/></div><p>he $words</p></body>',
    ]) {
      final blocks = ChapterReader(sheet, (h) => h).read(parseXhtml(html));
      final para = blocks.whereType<TextBlock>().single;
      expect(para.floatImage, isNotNull, reason: html);
      expect(blocks.whereType<ImageBlock>(), isEmpty, reason: 'not a picture on its own line');
      para.floatImage!.image = await _image(30, 60);
      var page = Paginator(const EpubTheme(), const Size(400, 600), null).run(blocks).first;
      var r = page.imageRects.single;
      expect(r.size, const Size(30, 60)); // its own size - not enlarged to a text drop cap's
      expect(r.left, 36);
      expect(page.textOrigins.first.dx, greaterThan(r.right), reason: 'the first lines beside it');
      expect(page.textOrigins.last.dx, 36, reason: 'then the full width under it');
      // smaller than two lines of text (Homeland's are 17 x 36; lines here 19 x 1.45): raised to two lines, in shape
      // (user, 2026-10-06 survey: "native with a floor based on text")
      para.floatImage!.image = await _image(17, 36);
      page = Paginator(const EpubTheme(), const Size(400, 600), null).run(blocks).first;
      r = page.imageRects.single;
      expect(r.height, closeTo(2 * 19 * 1.45 - 8, 0.01));
      expect(r.width / r.height, closeTo(17 / 36, 0.001));
    }
  });

  test("right-aligned and centred lines line up on the text column, not on their paragraph's longest line (Homeland's "
      'list of other books: each group was flush left, its short lines right-aligned to its longest)', () {
    final blocks = ChapterReader(StyleSheet()..add('p.r { text-align: right } p.c { text-align: center }'), (h) => h)
        .read(parseXhtml('<body><p class="r"><a href="a.html">Homeland</a><br/><a href="b.html">The Halfling</a></p><p class="c"><a href="c.html">Exile</a></p></body>'));
    final links = Paginator(const EpubTheme(), const Size(400, 600), null).run(blocks).single.links;
    // the text column: 36..364 (the test font: 19 px a letter - The Halfling, 12, is the longest line)
    expect(links[0].rect.right, closeTo(364, 1), reason: 'Homeland: at the right edge');
    expect(links[1].rect.right, closeTo(364, 1), reason: 'the longer line too');
    expect(links[2].rect.center.dx, closeTo(200, 1), reason: 'centred on the column');
  });

  test("the book's own text size: a size set on most of its paragraphs is the book's (shown at the reader's size, "
      'the rest in proportion); a size on a few blocks (a prelude) is not', () {
    List<Block> read(String css, String html) => ChapterReader(StyleSheet()..add(css), (h) => h).read(parseXhtml(html));
    final words = List.filled(30, 'word').join(' ');
    // small all through, on its paragraphs (p { font-size: small }; a size on <body> is never taken - the reader's
    // size stands for it already): most paragraph text at 0.85
    final small = read('p { font-size: small }', '<body><p>$words</p><p>$words</p><p>$words</p></body>');
    expect(bookTextSize([small, small]), 0.85);
    // a prelude in a small wrapper, the chapters plain: the book's size is the reader's
    final prelude = read('div.preface { font-size: small }', '<body><div class="preface"><p>$words</p></div></body>');
    final chapter = read('', '<body><p>$words</p><p>$words</p><p>$words</p></body>');
    expect(bookTextSize([prelude, chapter, chapter]), 1);
    // laid out with it, the small-all-through book's paragraphs come out as a plain book's: the same pages, same lines
    List<Offset> lay(List<Block> b, double base) =>
        Paginator(const EpubTheme(), const Size(400, 600), null, baseSize: base).run(b).first.textOrigins;
    final plain = read('', '<body><p>$words</p><p>$words</p><p>$words</p></body>');
    expect(lay(small, 0.85), lay(plain, 1));
    expect(lay(small, 1), isNot(lay(plain, 1)), reason: 'without it, the small text lays out differently');
  });

  test('Paragraph spacing: the space added between one paragraph and the next, in ems of the text', () {
    final blocks = ChapterReader(StyleSheet()..add('p { margin: 0 }'), (h) => h)
        .read(parseXhtml('<body><p>One.</p><p>Two.</p></body>'));
    double second(double gap) =>
        Paginator(EpubTheme(paragraphGap: gap), const Size(400, 600), null).run(blocks).single.textOrigins[1].dy;
    expect(second(1) - second(0), closeTo(19, 0.01), reason: '1 em at 19 px');
    expect(second(0.5) - second(0), closeTo(9.5, 0.01));
  });

  test("Exile's page (user, build 73): a text-indent in pt is a small indent, not a third of the line; a border with "
      'width 0 draws nothing; a book bold all through shows in normal weight, its headings still bold', () {
    List<Block> read(String css, String html) => ChapterReader(StyleSheet()..add(css), (h) => h).read(parseXhtml(html));
    final words = List.filled(30, 'word').join(' ');
    // 8pt: 10.67 px - about two thirds of the book's em (it came out as 10.67 em)
    final indented = read('p { text-indent: 8pt }', '<body><p>$words</p></body>').single as TextBlock;
    expect(indented.indent, closeTo(10.67 / 16, 0.01));

    expect(showsBorder({'border-style': 'solid', 'border-width': '0', 'border-color': 'rgb(0, 0, 0)'}), isFalse);
    expect(showsBorder({'border-color': 'black'}), isFalse, reason: 'no style: no border');
    expect(showsBorder({'border-style': 'solid'}), isTrue, reason: 'no width given: medium');
    expect(showsBorder({'border': '1px solid black'}), isTrue);
    expect(showsBorder({'border': 'none'}), isFalse);
    expect(showsBorder({'border-top': '2px dotted grey'}), isTrue, reason: 'a side of its own');
    final boxed = read('.bs { border-style: solid; border-width: 0 }', '<body><div class="bs"><p>$words</p></div></body>');
    expect((boxed.single as TextBlock).box, isNull, reason: 'no box round it');

    final allBold = read('.bs2 { font-weight: bold } h1 { font-size: 1.5em }',
        '<body><h1>Chapter</h1><div class="bs2"><p>$words</p><p>$words</p></div></body>');
    expect(bookTextBold([allBold]), isTrue);
    expect(bookTextBold([read('', '<body><p>$words <b>and bold</b></p></body>')]), isFalse);
  });

  test('a bordered passage gets a border; the same text without one has none', () {
    int pieces(String css) {
      final blocks = ChapterReader(StyleSheet()..add(css), (h) => h)
          .read(parseXhtml('<body><div class="box"><p>A notice.</p><p>Signed.</p></div></body>'));
      return Paginator(const EpubTheme(), const Size(400, 600), null).run(blocks).single.pieces.length;
    }
    expect(pieces('.box { border: 1px solid black }'), pieces('.box { }') + 1);
    expect(pieces('.box { border: none }'), pieces('.box { }'));
  });

  test('hanging indents (text-indent below 0, as in glossaries - Ender\'s Game): the first line starts further left '
      'than the rest; a negative margin keeps text on the page', () {
    final blocks = ChapterReader(StyleSheet()..add('p.g { margin-left: 2em; text-indent: -2em } div.c { margin-left: -6px }'),
        (h) => h).read(parseXhtml('<body><p class="g">Battle School: the orbiting school where the children are '
        'trained.</p><div class="c"><p>Off the edge?</p></div></body>'));
    // (the test font's letters are as wide as they're tall: ~15 to a line here)
    final pages = Paginator(const EpubTheme(), const Size(400, 900), hy.forLang('en')).run(blocks);
    expect(pages.length, 1, reason: [for (final p in pages) p.textOrigins].toString());
    final o = pages.single.textOrigins;
    expect(o.length, 3, reason: 'the first line, the rest of the paragraph, the other paragraph');
    expect(o[0].dx, 36, reason: 'first line: out at the page margin');
    expect(o[1].dx, 36 + 2 * 19, reason: 'the rest: at the paragraph margin (2em at 19 px)');
    expect(o[1].dy, greaterThan(o[0].dy));
    expect(o[2].dx, 36, reason: 'a negative margin stops at the page margin');
  });

  test("margins in px are px (16 to the book's em), not em: Homeland's \"also by\" page (30px either side, 45px more "
      'on the right) keeps a full-width column', () {
    final blocks = ChapterReader(
        StyleSheet()..add('div.o { margin-left: 32px; margin-right: 32px } p.r { text-align: right; margin-right: 48px }'),
        (h) => h).read(parseXhtml('<body><div class="o"><p>Homeland</p><p class="r">The Crystal Shard</p></div></body>'));
    final t = blocks.whereType<TextBlock>().toList();
    expect(t[0].left, 2, reason: '32px = 2 em');
    expect(t[1].right, 2 + 3, reason: "the wrapper's 32px and its own 48px");
    final o = Paginator(const EpubTheme(), const Size(400, 600), null).run(blocks).single.textOrigins;
    expect(o[0].dx, 36 + 2 * 19, reason: '2 em at 19 px');
  });

  test('margins nest: a quotation or a wrapper indents the paragraphs inside it, wrappers inside wrappers add up',
      () {
    TextBlock para(List<Block> bs, String text) =>
        bs.whereType<TextBlock>().firstWhere((b) => b.runs.map((r) => r.text).join().contains(text));
    final bs = ChapterReader(StyleSheet()..add('div.a { margin-left: 2em } div.b { margin-left: 1em; margin-right: 3em }'),
        (h) => h).read(parseXhtml('<body><p>Body.</p><blockquote><p>Quoted.</p></blockquote>'
        '<div class="a"><p>Outer.</p><div class="b"><p>Inner.</p></div></div><p>After.</p></body>'));
    expect((para(bs, 'Body.').left, para(bs, 'Body.').right), (0.0, 0.0));
    expect((para(bs, 'Quoted.').left, para(bs, 'Quoted.').right), (1.5, 1.5), reason: "a blockquote's indent");
    expect(para(bs, 'Outer.').left, 2);
    expect((para(bs, 'Inner.').left, para(bs, 'Inner.').right), (3.0, 3.0), reason: '2 + 1 on the left, 3 on the right');
    expect((para(bs, 'After.').left, para(bs, 'After.').right), (0.0, 0.0), reason: 'outside again: none');
  });

  test("Mistborn's epigraph (a wrapper with a right margin and space after): its paragraphs inset on the right, and "
      'the space after it kept with the reader\'s own formatting on (only the gaps between paragraphs go)', () {
    const css = '.chapterEpigraph { display: block; margin-top: 0%; margin-bottom: 10%; margin-right: 5% } '
        '.chapterTitle { text-align: center }';
    final src = '<body><div class="chapterEpigraph"><p><i>Sometimes, I worry.</i></p><p><i>When they see me.</i></p>'
        '</div><h2 class="chapterTitle">PROLOGUE</h2><p>Ash fell from the sky.</p></body>';
    final bs = ChapterReader(StyleSheet()..add(css), (h) => h).read(parseXhtml(src));
    final epi = bs.whereType<TextBlock>().take(2).toList();
    expect(epi.map((b) => b.right), [1.5, 1.5], reason: '5% of the page, as about 30 em wide');
    expect(epi.last.wrapBottom, 3, reason: '10%: the space after the epigraph');
    double headingY(bool bookFormatting) {
      final page = Paginator(EpubTheme(bookFormatting: bookFormatting), const Size(600, 900), null).run(
          ChapterReader(StyleSheet()..add(css), (h) => h).read(parseXhtml(src))).single;
      return page.textOrigins[2].dy; // the third run of lines: PROLOGUE
    }
    final plainSrc = src.replaceAll(' class="chapterEpigraph"', '');
    final page = Paginator(const EpubTheme(bookFormatting: false), const Size(600, 900), null)
        .run(ChapterReader(StyleSheet()..add(css), (h) => h).read(parseXhtml(plainSrc))).single;
    // the gap before PROLOGUE: the larger of the epigraph's space after (3 em = 57 px) and the heading's own top margin
    // (~22 px, there in both) - so 35 px more than with no wrapper
    expect(headingY(false) - page.textOrigins[2].dy, closeTo(57 - 0.83 * 1.4 * 19, 1),
        reason: "own formatting keeps the epigraph's space after, not just the heading's own");
  });

  test("own formatting takes out only the book's usual gap between paragraphs: a paragraph that asks for its own "
      'spacing (a scene break) keeps it, and starts without an indent', () {
    const css = 'p { margin: 1em 0; text-indent: 1.5em } p.break { margin-top: 3em }';
    final src = '<body><p>One.</p><p>Two.</p><p>Three.</p><p class="break">After the break.</p><p>Five.</p></body>';
    final page = Paginator(const EpubTheme(bookFormatting: false), const Size(600, 900), null)
        .run(ChapterReader(StyleSheet()..add(css), (h) => h).read(parseXhtml(src))).single;
    final o = page.textOrigins;
    final line = o[1].dy - o[0].dy; // ordinary paragraphs: one line apart, no gap
    expect(o[2].dy - o[1].dy, closeTo(line, 0.5), reason: 'the usual 1em gap is gone');
    expect(o[3].dy - o[2].dy, closeTo(line + 3 * 19, 0.5), reason: "the break's own 3em above stays");
    expect(o[4].dy - o[3].dy, closeTo(line, 0.5), reason: "the break's usual 1em below goes like the others'");
  });

  test("alignment and paragraphs set apart (user, 2026-10-07: \"Book's formatting\" in three): the reader's own "
      "alignment keeps the book's paragraph gaps; the reader's paragraphs take them out whatever the alignment", () {
    const css = 'p { margin: 1em 0; text-indent: 1.5em }';
    List<Offset> lay(EpubTheme theme) => Paginator(theme, const Size(600, 900), null)
        .run(ChapterReader(StyleSheet()..add(css), (h) => h)
            .read(parseXhtml('<body><p>One.</p><p>Two.</p><p>Three.</p></body>')))
        .single
        .textOrigins;
    double gap(List<Offset> o) => o[2].dy - o[1].dy;
    final book = gap(lay(const EpubTheme())); // the book's alignment and paragraphs
    final leftOnly = gap(lay(const EpubTheme(ownAlign: TextAlign.left)));
    final mineOnly = gap(lay(const EpubTheme(ownParagraphs: true)));
    expect(leftOnly, closeTo(book, 0.5), reason: "the alignment alone leaves the book's gaps");
    expect(mineOnly, lessThan(book - 10), reason: "the reader's paragraphs take the usual gap out");
    expect(const EpubTheme(ownAlign: TextAlign.left).bookFormatting, isFalse);
    expect(const EpubTheme(bookFormatting: false).ownAlign, TextAlign.justify, reason: 'the old switch: both');
    expect(const EpubTheme(bookFormatting: false).ownParagraphs, isTrue);
  });

  test("own formatting invents no indent (user, 2026-10-07: only where the book calls for one): a book that doesn't "
      "indent its paragraphs keeps them unindented, with its gap between them - without either they ran together; "
      "one that indents keeps its own amount, not the reader's", () {
    EpubPage page(String css) => Paginator(const EpubTheme(bookFormatting: false), const Size(600, 900), null)
        .run(ChapterReader(StyleSheet()..add(css), (h) => h)
            .read(parseXhtml('<body><p>One.</p><p>Two.</p><p>Three.</p></body>')))
        .single;
    final plain = page('p { margin: 1em 0 }');
    expect(plain.textIndents, everyElement(lessThan(1)), reason: 'no indent the book did not ask for');
    final o = plain.textOrigins;
    final line = page('p { margin: 0 }').textOrigins;
    expect(o[2].dy - o[1].dy, greaterThan(line[2].dy - line[1].dy + 10), reason: "the book's gap stays");
    final indented = page('p { margin: 0; text-indent: 3em }');
    expect(indented.textIndents[1], closeTo(3 * 19, 1), reason: "the book's own 3 em, not the reader's 1.5");
    expect(indented.textIndents[0], lessThan(1), reason: 'not the first paragraph, after nothing');
  });

  // ---- the 2026-10-06 survey of 46 books on the tablet's page

  test("a div holding only text is a paragraph (Codex Alera's and Dune's every paragraph is a div.tx): Paragraph "
      "spacing reaches it, and its size counts as the book's; a div with blocks inside, or set larger, isn't", () {
    List<Block> read(String css, String html) => ChapterReader(StyleSheet()..add(css), (h) => h).read(parseXhtml(html));
    final dune = read('.tx { font-size: small; text-indent: 1em }',
        '<body><div class="tx">One line.</div><div class="tx">Two lines.</div></body>');
    expect(dune.cast<TextBlock>().every((b) => b.paragraph), isTrue);
    expect(bookTextSize([dune]), 0.85, reason: "Dune's text is small all through: shown at the reader's size");
    double second(double gap) =>
        Paginator(EpubTheme(paragraphGap: gap), const Size(400, 600), null).run(dune).single.textOrigins[1].dy;
    expect(second(1) - second(0), closeTo(19, 0.01), reason: 'Paragraph spacing: 1 em more');
    final others = read('.big { font-size: x-large } .b { font-weight: bold }',
        '<body><div class="big">Chapter One</div><div><p>Inside.</p></div><div class="b">Eleven<p>Text.</p></div>'
        '<div>They were nine days <p>a block</p></div></body>');
    expect(others.cast<TextBlock>().where((b) => b.paragraph).map((b) => b.runs.map((r) => r.text).join().trim()),
        ['Inside.', 'Text.', 'They were nine days', 'a block'],
        reason: "not the large title, nor the bold one opening its div; the text opening a plain div is (the "
            "Belgariad's chapters open so)");
  });

  test("a book's Windows dashes and quotes read as control characters (The Forever War's \"Sir\\u0097we\") are shown "
      'as what they stood for', () {
    final b = ChapterReader(StyleSheet(), (h) => h)
        .read(parseXhtml('<body><p>Sir\u0097we \u0093go\u0094 \u0085 it\u0092s</p></body>'))
        .single as TextBlock;
    expect(b.runs.map((r) => r.text).join(), 'Sir—we “go” … it’s');
    expect(fixC1('plain — text'), 'plain — text');
  });

  test('headings are not hyphenated ("DEMOS-THENES" - Ender\'s Game), the text under them is; bold divs count as '
      "headings (the Belgariad's chapter titles)", () {
    const word = 'Demosthenes extraordinary recriminations';
    int marks(String html, {String css = ''}) => Paginator(const EpubTheme(), const Size(260, 900), hy.forLang('en'))
        .run(ChapterReader(StyleSheet()..add(css), (h) => h).read(parseXhtml(html)))
        .fold(0, (n, p) => n + p.hyphenMarks);
    expect(marks('<body><p>$word $word</p></body>'), greaterThan(0), reason: 'running text: hyphenated');
    expect(marks('<body><h2>$word</h2></body>'), 0);
    expect(marks('<body><div class="bs2"><span>$word</span><p/></div></body>', css: '.bs2 { font-weight: bold }'), 0);
  });

  test('a heading gets half a line of space under it when the book leaves none (New Sun, Xanth, the Belgariad)', () {
    const css = 'h1 { margin: 0; font-size: 1em } p { margin: 0 }';
    List<Offset> lay(String html) => Paginator(const EpubTheme(), const Size(400, 600), null)
        .run(ChapterReader(StyleSheet()..add(css), (h) => h).read(parseXhtml(html)))
        .single
        .textOrigins;
    final heading = lay('<body><h1>Chapter 1: Xanth.</h1><p>A small lizard.</p></body>');
    final plain = lay('<body><p>Chapter 1: Xanth.</p><p>A small lizard.</p></body>');
    expect((heading[1].dy - heading[0].dy) - (plain[1].dy - plain[0].dy), closeTo(0.5 * 19 * 1.45, 0.01));
    // a heading that asks for more space keeps its own
    final spaced = Paginator(const EpubTheme(), const Size(400, 600), null)
        .run(ChapterReader(StyleSheet()..add('$css h1 { margin-bottom: 3em }'), (h) => h)
            .read(parseXhtml('<body><h1>Chapter 1: Xanth.</h1><p>A small lizard.</p></body>')))
        .single
        .textOrigins;
    expect(spaced[1].dy - spaced[0].dy, closeTo(heading[1].dy - heading[0].dy - 0.5 * 19 * 1.45 + 3 * 19, 0.01));
  });

  test("a note marker is a link in running text: a heading that is all link (Ender's chapter number, linking back to "
      'the contents) is plain text', () {
    List<EpubLink> links(String html) => Paginator(const EpubTheme(), const Size(400, 600), null)
        .run(ChapterReader(StyleSheet(), (h) => h).read(parseXhtml(html)))
        .single
        .links;
    expect(links('<body><h2><a href="contents.html#r10">8</a></h2></body>').single.text, '8');
    expect(links('<body><p>The Watch<a href="notes.html#n8">8</a> arrived.</p></body>').single.text, '⁸',
        reason: 'in running text: a marker, raised');
  });

  test("a table's columns are never narrower than their longest word (the Three-Body Problem's list of characters "
      'broke "Wenxu/e"); the room left is shared in proportion', () {
    final long = List.filled(60, 'word').join(' ');
    final r = ChapterReader(StyleSheet(), (h) => h)
      ..read(parseXhtml('<body><table><tr><td>Ye Wenxue</td><td>$long</td></tr></table></body>'));
    final page = Paginator(const EpubTheme(), const Size(400, 2000), null).run(r.blocks).single;
    // the test font: 19 px a letter - "Wenxue" is 114; the cells 14 apart
    final firstWidth = page.textOrigins[1].dx - page.textOrigins[0].dx - 14;
    expect(firstWidth, greaterThanOrEqualTo(114));
    expect(page.textOrigins[1].dx + 4 * 19, lessThanOrEqualTo(364 + 0.5), reason: 'the second still fits its words');
    // cells aren't hyphenated, as in a browser ("Yang Wein-ing" in a narrow column)
    final names = ChapterReader(StyleSheet(), (h) => h)
      ..read(parseXhtml('<body><table><tr><td>Yang Weining</td><td>$long recrimination</td></tr></table></body>'));
    expect(Paginator(const EpubTheme(), const Size(400, 2000), hy.forLang('en')).run(names.blocks).single.hyphenMarks, 0);
  });

  // ---- small black-and-white pictures on a light ground in the page's colours (The Dispossessed's chapter number,
  // a black "5" on a white box, glared on the dark page - Windows, build 79; user: "drop clashing backgrounds")

  Future<ui.Image> drawn(int w, int h, Color ground, Color ink) {
    final rec = ui.PictureRecorder();
    Canvas(rec)
      ..drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = ground)
      ..drawRect(Rect.fromLTWH(w * 0.3, h * 0.3, w * 0.4, h * 0.4), Paint()..color = ink);
    return rec.endRecording().toImage(w, h);
  }

  test('ink on a light ground: black on white is; a colour picture, or one on a dark ground, is not', () async {
    expect(await inkOnLight(await drawn(40, 60, const Color(0xFFFFFFFF), const Color(0xFF000000))), isTrue);
    expect(await inkOnLight(await drawn(40, 60, const Color(0xFFFFFFFF), const Color(0xFFD02020))), isFalse,
        reason: 'red ink: a colour picture');
    expect(await inkOnLight(await drawn(40, 60, const Color(0xFF101010), const Color(0xFFFFFFFF))), isFalse,
        reason: 'a dark ground: it sits on a dark page already');
  });

  test("a chapter number printed on white is drawn in the page's colours: its ground the page's, its ink the text's",
      () async {
    final blocks = ChapterReader(StyleSheet(), (h) => h).read(parseXhtml(
        '<body><p><img src="ch5.jpg" style="float:left"/>SHEVEK ended his career as a tourist with relief.</p></body>'));
    final img = (blocks.single as TextBlock).floatImage!;
    img.image = await drawn(40, 60, const Color(0xFFFFFFFF), const Color(0xFF000000));
    img.inkOnLight = await inkOnLight(img.image!);
    const theme = EpubTheme(); // dark: background 1B1B1D, text E4E0D8
    final page = Paginator(theme, const Size(400, 600), null).run(blocks).single;
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec)..drawColor(theme.background, BlendMode.src);
    for (final p in page.pieces) {
      p.paint(canvas);
    }
    final shot = await rec.endRecording().toImage(400, 600);
    final px = (await shot.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    Color at(Offset o) {
      final i = (o.dy.round() * 400 + o.dx.round()) * 4;
      return Color.fromARGB(255, px.getUint8(i), px.getUint8(i + 1), px.getUint8(i + 2));
    }
    final r = page.imageRects.single;
    bool near(Color a, Color b) =>
        (a.r - b.r).abs() < 0.03 && (a.g - b.g).abs() < 0.03 && (a.b - b.b).abs() < 0.03;
    expect(near(at(r.topLeft + const Offset(2, 2)), theme.background), isTrue,
        reason: 'its white ground is the page\'s background: ${at(r.topLeft + const Offset(2, 2))}');
    expect(near(at(r.center), theme.text), isTrue, reason: 'its black ink is the text\'s colour: ${at(r.center)}');
  });

  // ---- the EPUB code review, 2026-10-06 (E)

  test('E5: a rule after @charset / @namespace applies (it was skipped - every Calibre book starts with @namespace)',
      () {
    final sheet = StyleSheet()..add('@charset "UTF-8"; @namespace h "http://www.w3.org/1999/xhtml"; '
        '.body { text-indent: 2em } p { margin: 0 }');
    final body = parseXhtml('<body class="body"><p>x</p></body>').find('body')!;
    expect(sheet.declsFor(body)['text-indent'], '2em');
  });

  test("E1: a drop cap written as text inside its paragraph stays that paragraph's (it moved to the next one)", () {
    final blocks = ChapterReader(StyleSheet()..add('.drop { float: left }'), (h) => h)
        .read(parseXhtml('<body><p><span class="drop">T</span>he story begins.</p><p>Next.</p></body>'));
    final first = blocks[0] as TextBlock, second = blocks[1] as TextBlock;
    expect(first.drop?.text, 'T');
    expect(first.runs.map((r) => r.text).join(), 'he story begins.');
    expect(first.paragraph, isTrue);
    expect(second.drop, isNull);
  });

  test('E2: no room for even one line beside a float carried from the paragraph before - laid out below it, not a '
      'crash', () async {
    final blocks = ChapterReader(StyleSheet()..add('p { margin: 0 }'), (h) => h).read(parseXhtml(
        '<body><p><img src="a.png" style="float:left"/>x</p><p>${List.filled(30, 'word').join(' ')}</p></body>'));
    (blocks.first as TextBlock).floatImage!.image = await _image(30, 80);
    // the text area 54 px tall: one line (27.55) beside the float, then less than a line left beside it
    final pages = Paginator(const EpubTheme(), const Size(400, 134), null).run(blocks);
    expect(pages.length, greaterThan(1), reason: 'the second paragraph went on, below the float / on the next page');
  });

  test('E3: a floated picture in an otherwise empty wrapper goes beside the next paragraph (it was lost)', () {
    final blocks = ChapterReader(StyleSheet(), (h) => h)
        .read(parseXhtml('<body><div><img src="a.png" style="float:left"/></div><p>The text.</p></body>'));
    expect((blocks.single as TextBlock).floatImage?.src, 'a.png');
  });

  test('E4: a scene break written as <hr/> keeps a gap, and the paragraph after it starts without an indent (with '
      "the reader's own formatting)", () {
    // (a book whose paragraphs are indented: the indent is the book's, never the reader's - user, 2026-10-07)
    EpubPage page(String body) => Paginator(const EpubTheme(bookFormatting: false), const Size(600, 900), null)
        .run(ChapterReader(StyleSheet()..add('p { text-indent: 1.5em }'), (h) => h)
            .read(parseXhtml('<body>$body</body>')))
        .single;
    List<Offset> lay(String body) => page(body).textOrigins;
    const plainSrc = '<p>One.</p><p>Two.</p><p>Three.</p>', brokenSrc = '<p>One.</p><p>Two.</p><hr/><p>Three.</p>';
    final plain = lay(plainSrc), broken = lay(brokenSrc);
    expect(broken[2].dy - broken[1].dy, greaterThan(plain[2].dy - plain[1].dy + 10), reason: 'a gap at the break');
    expect(page(plainSrc).textIndents[2], greaterThan(10), reason: 'an ordinary paragraph is indented');
    expect(page(brokenSrc).textIndents[2], lessThan(1), reason: 'no indent after the break');
    // blank paragraphs between EVERY paragraph are a converted book's spacing, not breaks: own formatting evens them
    final spaced = lay(List.generate(8, (i) => '<p>P$i.</p><p>&nbsp;</p>').join());
    expect(spaced[2].dy - spaced[1].dy, closeTo(spaced[1].dy - spaced[0].dy, 0.5));
  });

  test('E10: named entities French books use; a numeric one past Unicode is left as written, not a failed chapter',
      () {
    expect(decodeEntities('&laquo;Oui&raquo;, dit-il, &agrave; l&rsquo;&eacute;cole'), '«Oui», dit-il, à l’école');
    expect(decodeEntities('a &#xFFFFFFFF; b &#99999999999999999999; c'), 'a &#xFFFFFFFF; b &#99999999999999999999; c');
  });

  test('E14: a picture used many times in a chapter (a scene-break ornament) is fetched and decoded once; each use '
      'gets its own handle, and freeing the chapter frees them all', () async {
    final source = _CountingSource({
      'c.xhtml': '<html><body><p>One.</p><p><img src="orn.png"/></p><p>Two.</p><p><img src="orn.png"/></p>'
          '<p>Three.</p><div><img src="lost.png" style="float:left"/></div></body></html>'
    }, const EpubInfo(spine: ['c.xhtml'], toc: []), binary: {'orn.png': onePixelPng, 'lost.png': onePixelPng});
    final ch = await ChapterLoader(source).load('c.xhtml');
    expect(source.fetched['orn.png'], 1);
    final pics = ch.blocks.whereType<ImageBlock>().toList();
    expect(pics, hasLength(2));
    expect(pics[0].image, isNotNull);
    expect(identical(pics[0].image, pics[1].image), isFalse, reason: 'each its own handle');
    final all = [...ch.images.map((i) => i.image!)];
    expect(all, hasLength(3), reason: 'the floated picture no paragraph took is kept with the chapter (E3)');
    ch.dispose();
    expect(all.every((i) => i.debugDisposed), isTrue, reason: 'every picture freed');
  });

  List<EpubPage> layOut(String body, {String css = '', Size size = const Size(400, 600)}) =>
      Paginator(const EpubTheme(), size, null)
          .run(ChapterReader(StyleSheet()..add(css), (h) => h).read(parseXhtml('<body>$body</body>')));

  test('E6: a table row taller than a page goes on over the next pages (what didn\'t fit was lost below the page)', () {
    final words = List.filled(400, 'word').join(' ');
    final pages = layOut('<table><tr><td>Name</td><td>$words</td></tr><tr><td>After</td><td>row</td></tr></table>');
    expect(pages.length, greaterThan(1));
    const theme = EpubTheme();
    for (final p in pages) {
      expect(p.textOrigins, isNotEmpty, reason: 'part of the row on every page');
    }
    // nothing drawn below a page's text area (a line taller than the page aside, none here)
    for (final p in pages) {
      for (final bottom in p.textBottoms) {
        expect(bottom, lessThanOrEqualTo(600 - theme.margins.bottom + 0.5));
      }
    }
  });

  test("E8: the text after an inline picture is still its paragraph (it lost the paragraph's formatting)", () {
    final blocks = ChapterReader(StyleSheet(), (h) => h)
        .read(parseXhtml('<body><p>Before the picture <img src="a.png"/> and after it.</p></body>'));
    expect(blocks, hasLength(3));
    expect((blocks[0] as TextBlock).paragraph, isTrue);
    expect(blocks[1], isA<ImageBlock>());
    final after = blocks[2] as TextBlock;
    expect(after.paragraph, isTrue);
    expect(after.indent, 0, reason: 'not a new paragraph');
  });

  test('E9: a big left margin (deep nesting) still leaves the line on the page', () {
    const theme = EpubTheme();
    final pages = layOut('<div style="margin-left: 40em"><p>Some text that wraps.</p></div>');
    final x = pages.single.textOrigins.single.dx;
    expect(x + theme.fontSize * 4, lessThanOrEqualTo(400 - theme.margins.right + 0.5));
  });

  test('E11: :first-child rules apply (the first paragraph without an indent); other pseudo-classes never do', () {
    final sheet = StyleSheet()
      ..add('p { text-indent: 1em } p:first-child { text-indent: 0 } p:hover { color: red } div p:last-child { x: y }');
    final body = parseXhtml('<body><div><p>a</p><p>b</p><p>c</p></div></body>').find('body')!;
    final ps = body.elements.single.elements.toList();
    expect(sheet.declsFor(ps[0])['text-indent'], '0');
    expect(sheet.declsFor(ps[1])['text-indent'], '1em');
    expect(sheet.declsFor(ps[1]).containsKey('color'), isFalse);
    expect(sheet.declsFor(ps[2]).containsKey('x'), isFalse, reason: 'only :first-child is understood');
  });

  test('E12: negative margins never draw text over the block before (the reader records margins at 0 or more)', () {
    final o = layOut('<p style="margin-bottom: -2em">One.</p><p style="margin-top: -3em">Two.</p>').single.textOrigins;
    final lineH = const EpubTheme().fontSize * const EpubTheme().lineHeight;
    expect(o[1].dy - o[0].dy, greaterThanOrEqualTo(lineH - 0.5));
  });

  test('E13: a table of very many columns keeps them in order across the page (the gaps alone were wider than the '
      'page: columns came out narrower than nothing, starting left of the one before)', () {
    final row = '<td>Supercalifragilistic</td>${List.filled(29, '<td>x</td>').join()}';
    final o = layOut('<table><tr>$row</tr></table>').single.textOrigins;
    for (var c = 1; c < o.length; c++) {
      expect(o[c].dx, greaterThan(o[c - 1].dx), reason: 'column $c starts after column ${c - 1}');
    }
    expect(o.last.dx, lessThan(400));
  });

  test('E15: ::first-letter takes the opening quote with the letter, not the quote alone', () {
    final blocks = ChapterReader(StyleSheet()..add('p::first-letter { float: left }'), (h) => h)
        .read(parseXhtml('<body><p>“It was a dark night.</p></body>'));
    expect((blocks.single as TextBlock).drop?.text, '“I');
  });
}
